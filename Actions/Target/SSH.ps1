<#
.SYNOPSIS
Target action: evaluate resources against a remote computer over SSH (#57 §4).

.DESCRIPTION
Opens a PSSession over SSH (PowerShell 7+ SSH remoting). SSH has no CIM-over-SSH transport, so
this target is only usable with the DscV3 engine (which reaches its remote target through
Invoke-Command over a PSSession, not a CimSession) - fails fast, before opening a connection,
when paired with the DscV2 engine so the mismatch is reported clearly rather than as a
mysterious later failure. Only unit-tested with New-PSSession mocked (#57 scope note) - this
module cannot open a live SSH connection in this environment, and no CI job opens one either, so
unlike the WinRM target there is no live proof of the SSH path.

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
