<#
.SYNOPSIS
Target action: evaluate resources against a remote computer over SSH (#57 §4).

.DESCRIPTION
Opens a PSSession over SSH (PowerShell 7+ SSH remoting). SSH has no CIM-over-SSH transport, so
this target is only usable with the DscV3 engine (which reaches its remote target through
Invoke-Command over a PSSession, not a CimSession) - fails fast, before opening a connection,
when paired with the DscV2 engine so the mismatch is reported clearly rather than as a
mysterious later failure.

Proved against a real sshd by Tests/PipelineRunner/DSCConfiguration/Integration/
SSHTarget.Integration.tests.ps1, which runs on the hosted Ubuntu agent: it registers a
'powershell' subsystem in sshd_config, authorises the agent account's own key, and connects the
agent to itself, so the parameter hashtable below is accepted by the real New-PSSession and the
session it returns carries the shipped DscV3 engine action to the far side. The unit suite beside
it still mocks New-PSSession and covers dispatch and the DscV2 fail-fast guard.

The target's sshd must have that subsystem registered - a host that accepts an ssh login but has
no 'powershell' subsystem refuses the subsystem request, and New-PSSession fails on a machine that
is plainly reachable.

Authentication is the runner account's own: the runner passes only ComputerName, Engine and
Credential to a Target action, so UserName/KeyFilePath above are never populated from a 'target'
block today and SSH falls back to the running account's ~/.ssh configuration. On an agent that is
the service account's profile, not the profile of whoever configured the machine, and that
account's public key has to be authorised on the target.

.PARAMETER Context
Hashtable with:
  ComputerName [string] - required, the remote computer name or IP (passed as -HostName).
  Engine       [string] - the resolved engine name, used only for the DscV2 fail-fast check.
  UserName     [string] - optional SSH username.
  KeyFilePath  [string] - optional path to an SSH private key.

.OUTPUTS
[hashtable] @{ ComputerName; IsRemote = $true; CimSession = $null; PSSession }
#>
param(
    [hashtable]$Context = @{}
)

if ([string]::IsNullOrWhiteSpace([string]$Context.ComputerName)) {
    throw "[Actions/Target/SSH] 'ComputerName' is required in the Target context."
}

if ([string]$Context.Engine -eq 'DscV2') {
    throw "[Actions/Target/SSH] SSH remoting requires the DscV3 engine (there is no CIM-over-SSH transport for DscV2/Invoke-DscResource); the resolved engine was 'DscV2'."
}

$sessionParams = @{ HostName = [string]$Context.ComputerName; SSHTransport = $true }
if ($Context.UserName)    { $sessionParams.UserName = [string]$Context.UserName }
if ($Context.KeyFilePath) { $sessionParams.KeyFilePath = [string]$Context.KeyFilePath }

$psSession = New-PSSession @sessionParams

return @{
    ComputerName = [string]$Context.ComputerName
    IsRemote     = $true
    CimSession   = $null
    PSSession    = $psSession
}
