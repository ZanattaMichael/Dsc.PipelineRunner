<#
.SYNOPSIS
Ensures the self-hosted runner has a WinRM listener the remoting integration suite can reach.

.DESCRIPTION
WinRMTarget.Integration.tests.ps1 connects over WinRM to the runner itself. Where no listener is
accepting requests, Get-WinRMSkipReason reports that and the suite skips its five live-connection
tests with a warning rather than failing - which keeps the job green while the coverage it exists
to provide silently does not happen. This script closes that gap by configuring the listener
before the suite runs.

It is deliberately conservative, because a self-hosted runner is a long-lived machine rather than
an ephemeral agent:

  * It probes first and makes NO changes when a listener is already reachable, so a runner that is
    already configured is untouched on every subsequent build.
  * It never clobbers an existing TrustedHosts list. The entry for this computer is appended to
    whatever is already there, and a list already set to '*' is left alone.
  * It is non-fatal. Anything that prevents configuration (most often: the runner service is not
    elevated) is reported as a warning and the script still exits 0, so an environment problem on
    the runner does not turn an unrelated pull request red. The suite then skips exactly as it did
    before, and the step summary says why.

Enabling PowerShell remoting opens a listener on a persistent host, so this is intended for a
dedicated CI runner - not for a developer workstation.

.PARAMETER ComputerName
The name the suite connects to, which is what gets probed. Defaults to $env:COMPUTERNAME, matching
WinRMTarget.Integration.tests.ps1.

.OUTPUTS
None. Always exits 0: a failure to configure is a warning, not a build break.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ComputerName = $env:COMPUTERNAME
)

# Not 'Stop': every failure here is handled and downgraded to a warning on purpose.
$ErrorActionPreference = 'Continue'

function Write-StepSummary {
    <#
    .SYNOPSIS
    Appends a line to the GitHub Actions run summary, so the WinRM outcome is visible without
    opening the job log - the point being that a green job should not hide a skipped suite.
    #>
    param([Parameter(Mandatory)][string]$Line)

    Write-Information $Line -InformationAction Continue

    if ($env:GITHUB_STEP_SUMMARY) {
        try {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Line -ErrorAction Stop
        }
        catch {
            # The summary file is a convenience; losing it must not affect the run.
            Write-Warning "Could not write to GITHUB_STEP_SUMMARY: $($_.Exception.Message)"
        }
    }
}

function Test-WinRMReachable {
    <#
    .SYNOPSIS
    Answers the only question that matters here: can the remoting suite open a session to $Target?

    .DESCRIPTION
    -Authentication Negotiate is load-bearing. A bare Test-WSMan sends an ANONYMOUS WS-Man
    Identify, which succeeds as soon as a listener exists - without authenticating anybody. The
    suite's New-CimSession/New-PSSession authenticate as the current user, so a host can answer a
    bare Test-WSMan and still refuse every session with "Access is denied". Probing anonymously
    would make this script report a host as already configured, skip the configuration below, and
    leave the suite failing on a machine this step was written to fix.

    Get-WinRMSkipReason (Tests/TestHelpers/CommonTestFunctions.psm1) probes the same way, so what
    this script reports and what the suite decides cannot disagree.
    #>
    param([Parameter(Mandatory)][string]$Target)

    try {
        $null = Test-WSMan -ComputerName $Target -Authentication Negotiate -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

if (-not $IsWindows) {
    Write-StepSummary "WinRM: skipped - not a Windows host, so there is no WSMan stack to configure."
    return
}

# 1. Probe first. A runner that is already configured must not be reconfigured on every build.
if (Test-WinRMReachable -Target $ComputerName) {
    Write-StepSummary "WinRM: already usable - [$ComputerName] answered an authenticated Test-WSMan. No changes made."
    return
}

Write-Information "WinRM: [$ComputerName] did not answer an authenticated Test-WSMan; attempting to configure the listener." -InformationAction Continue

# 2. Everything below needs elevation. Say so plainly rather than failing with an access error:
#    whether the runner service runs elevated is a machine setup decision, not something to
#    silently work around.
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)

if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Cannot configure WinRM: this process is not elevated (running as [$($identity.Name)]). Configure the listener once by hand on the runner, or run the runner service as an administrator. The remoting suite will skip."
    Write-StepSummary "WinRM: **not enabled** - the runner process is not elevated, so the live remoting tests will skip."
    return
}

try {
    # -SkipNetworkProfileCheck: a CI runner frequently sits on a network Windows classifies as
    # Public, where Enable-PSRemoting otherwise refuses. The firewall rule it creates is still
    # scoped to the local subnet.
    if ($PSCmdlet.ShouldProcess($ComputerName, 'Enable-PSRemoting')) {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
    }

    # Enable-PSRemoting normally handles both, but a runner whose service was disabled by policy
    # needs them set explicitly, and doing so is idempotent.
    $winRMService = Get-Service -Name WinRM -ErrorAction Stop
    if ($winRMService.StartType -ne 'Automatic') {
        Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
    }
    if ($winRMService.Status -ne 'Running') {
        Start-Service -Name WinRM -ErrorAction Stop
    }

    # 3. A workgroup machine connecting to itself BY NAME authenticates with NTLM, which requires
    #    the name to be trusted. A domain-joined runner uses Kerberos and needs none of this.
    #    Append only - TrustedHosts is machine-wide and may already carry entries this repository
    #    knows nothing about.
    $isDomainJoined = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain

    if (-not $isDomainJoined) {
        $trustedHostsItem = Get-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop
        $currentTrusted   = [string] $trustedHostsItem.Value
        $existingEntries  = @($currentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        if ($existingEntries -contains '*') {
            Write-Information "WinRM: TrustedHosts is already '*'; leaving it unchanged." -InformationAction Continue
        }
        elseif ($existingEntries -contains $ComputerName) {
            Write-Information "WinRM: TrustedHosts already lists [$ComputerName]; leaving it unchanged." -InformationAction Continue
        }
        else {
            $updatedTrusted = (@($existingEntries) + $ComputerName) -join ','
            if ($PSCmdlet.ShouldProcess('WSMan:\localhost\Client\TrustedHosts', "Append [$ComputerName]")) {
                Set-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -Value $updatedTrusted -Force -ErrorAction Stop
            }
            Write-Information "WinRM: appended [$ComputerName] to TrustedHosts (was [$currentTrusted])." -InformationAction Continue
        }
    }
}
catch {
    Write-Warning "Could not configure WinRM: $($_.Exception.Message). The remoting suite will skip."
    Write-StepSummary "WinRM: **not enabled** - configuration failed ($($_.Exception.Message)). The live remoting tests will skip."
    return
}

# 4. Re-probe. Enable-PSRemoting reporting success is not the same as the suite being able to
#    connect, and the suite's probe is the only thing that decides whether the tests run.
if (Test-WinRMReachable -Target $ComputerName) {
    Write-StepSummary "WinRM: enabled - [$ComputerName] now answers an authenticated Test-WSMan. The live remoting tests will run."
}
else {
    Write-Warning "WinRM was configured but [$ComputerName] still does not answer an authenticated Test-WSMan. The remoting suite will skip. Where the message is an access denial rather than a connection failure, the listener is up and the refusal is an authentication/authorization decision on the runner - see the CHANGELOG entry for the remaining machine-level causes."
    Write-StepSummary "WinRM: **not usable** - configured, but [$ComputerName] still does not answer an authenticated Test-WSMan. The live remoting tests will skip."
}
