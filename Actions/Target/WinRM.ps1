<#
.SYNOPSIS
Target action: evaluate resources against a remote computer over WinRM (#57 §4).

.DESCRIPTION
Builds both a CimSession (consumed by the DscV2 engine action, Invoke-DscResource -CimSession)
and a PSSession (consumed by the DscV3 engine action, which runs dsc.exe on the far side via
Invoke-Command) for the same remote computer, so either engine can use whichever session shape
it needs without the caller having to know which one in advance.

Validated at two levels: the unit suite mocks New-CimSession/New-PSSession to assert dispatch and
parameter passing, and Tests/.../Integration/WinRMTarget.Integration.tests.ps1 opens real sessions
against a live WinRM listener on the self-hosted Windows runner (DscV2-SelfHosted.yml) and proves
the CimSession is accepted by Invoke-DscResource and the PSSession by Invoke-Command.

.PARAMETER Context
Hashtable with:
  ComputerName [string]        - required, the remote computer name or IP.
  Credential   [PSCredential]  - optional, resolved beforehand via the Credential hook (#57 §5).

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
$psSession  = New-PSSession @sessionParams

return @{
    ComputerName = [string]$Context.ComputerName
    IsRemote     = $true
    CimSession   = $cimSession
    PSSession    = $psSession
}
