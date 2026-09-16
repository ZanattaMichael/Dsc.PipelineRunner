<#
.SYNOPSIS
Target action: evaluate resources against a remote computer over WinRM (#57 §4).

.DESCRIPTION
Builds both a CimSession and a PSSession for the same remote computer, so either engine can use
whichever session shape it needs without the caller having to know which one in advance.

The PSSession is what both engine actions use to reach the far side today - DscV2 runs
Invoke-DscResource there and DscV3 runs dsc.exe there, both via Invoke-Command. The CimSession is
kept because it is the only remote shape Windows PowerShell 5.1's Invoke-DscResource accepts
(-CimSession), and because a CIM query against the target is useful in its own right; PowerShell
7's PSDesiredStateConfiguration 2.x dropped that parameter, so it is a fallback rather than the
primary path (Actions/Engine/DscV2.ps1).

'ConfigurationName' selects which WinRM endpoint the PSSession lands on, and it matters for DSC
v2. New-PSSession without it connects to the host's default endpoint, which on Windows is Windows
PowerShell 5.1 - and a current Windows build no longer carries an in-box Invoke-DscResource there,
so a remote DSC v2 evaluation has nothing to run (the self-hosted runner, Windows 10.0.26100,
reports exactly that). Naming the PowerShell 7 endpoint - 'PowerShell.7', registered by
Enable-PSRemoting under pwsh - lands the session where PSDesiredStateConfiguration 2.x is
installed. It is passed to New-PSSession only: a CimSession is a WS-Man/CIM connection with no
PowerShell endpoint to choose.

The identity matters as much as the endpoint. New-CimSession/New-PSSession authenticate as the
credential when the Target context carries one, and otherwise as the account the runner process
itself runs as - on a self-hosted agent that is the agent service account, which installs as
NT AUTHORITY\NETWORK SERVICE and reaches a target as the computer account. That account has to
be a member of the target's Remote Management Users group to connect at all, and of local
Administrators to apply DSC (Invoke-DscResource drives the CIM/DSC subsystem) or to be restarted
after a RebootRequired. WikiSource/Remote-Targets-and-Credentials.md documents the full set.

Validated at two levels: the unit suite mocks New-CimSession/New-PSSession to assert dispatch and
parameter passing, and Tests/.../Integration/WinRMTarget.Integration.tests.ps1 opens real sessions
against a live WinRM listener on the self-hosted Windows runner (DscV2-SelfHosted.yml) and proves
the shipped DscV2 engine action completes a real evaluation over the session.

.PARAMETER Context
Hashtable with:
  ComputerName      [string]        - required, the remote computer name or IP.
  Credential        [PSCredential]  - optional, resolved beforehand via the Credential hook (#57 §5).
  ConfigurationName [string]        - optional, the remote WinRM endpoint for the PSSession.

.OUTPUTS
[hashtable] @{ ComputerName; IsRemote = $true; CimSession; PSSession }
#>
param(
    [hashtable]$Context = @{}
)

if ([string]::IsNullOrWhiteSpace([string]$Context.ComputerName)) {
    throw "[Actions/Target/WinRM] 'ComputerName' is required in the Target context."
}

$sessionParams = @{ ComputerName = [string]$Context.ComputerName }
if ($Context.Credential) {
    $sessionParams.Credential = $Context.Credential
}

$cimSession = New-CimSession @sessionParams

# Only the PSSession takes an endpoint name, so it is added to a copy rather than to the shared
# hashtable - New-CimSession has no -ConfigurationName and would fail to bind it.
$psSessionParams = @{} + $sessionParams
if (-not [string]::IsNullOrWhiteSpace([string]$Context.ConfigurationName)) {
    $psSessionParams.ConfigurationName = [string]$Context.ConfigurationName
}

$psSession = New-PSSession @psSessionParams

return @{
    ComputerName = [string]$Context.ComputerName
    IsRemote     = $true
    CimSession   = $cimSession
    PSSession    = $psSession
}
