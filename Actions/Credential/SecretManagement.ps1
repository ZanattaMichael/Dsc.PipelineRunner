<#
.SYNOPSIS
Credential action: resolve a secret from a Microsoft.PowerShell.SecretManagement vault (#57 §5/§6).

.DESCRIPTION
Soft dependency on the Microsoft.PowerShell.SecretManagement module, following the same
pattern as Actions/Connect/AzureDevOps.ps1's AzureDevOpsDsc.Common dependency: the runner does
not require SecretManagement (or any particular vault extension) to be installed unless a
configuration actually asks for this Credential action, and a clear, actionable error is
thrown when it is missing rather than an opaque "command not found".

This is the runner's secret-vault backend for #57 §6: any vault registered with
Register-SecretVault (a local vault, Azure Key Vault, HashiCorp Vault, etc. via their
respective SecretManagement extension modules) works here unchanged, since SecretManagement
itself is the abstraction over the vault backend - this action does not talk to a specific
vault product directly.

Validated at two levels: the unit suite mocks Get-Secret to assert dispatch and result-shape
handling, and Tests/.../Integration/SecretManagementCredential.Integration.tests.ps1 resolves
real secrets out of a live Microsoft.PowerShell.SecretStore vault (Integration-HostedAgent.yml).

.PARAMETER Context
Hashtable with:
  Name     [string] - required, the secret name to look up.
  Vault    [string] - optional, the registered vault name (Get-Secret's -Vault).
  UserName [string] - optional; when the secret is a bare SecureString, used as the
                       PSCredential's username (defaults to Name).

.OUTPUTS
[PSCredential]
#>
param(
    [hashtable]$Context = @{}
)

if ([string]::IsNullOrWhiteSpace([string]$Context.Name)) {
    throw "[Actions/Credential/SecretManagement] 'Name' (the secret name) is required in the Credential context."
}

if (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement) {
    Import-Module -Name Microsoft.PowerShell.SecretManagement -ErrorAction Stop
}
else {
    throw "[Actions/Credential/SecretManagement] Secret vault support requires the 'Microsoft.PowerShell.SecretManagement' module (plus a registered vault extension). Install it with: Install-Module Microsoft.PowerShell.SecretManagement"
}

$secretParams = @{ Name = [string]$Context.Name; ErrorAction = 'Stop' }
if (-not [string]::IsNullOrWhiteSpace([string]$Context.Vault)) {
    $secretParams.Vault = [string]$Context.Vault
}

$secret = Get-Secret @secretParams

if ($null -eq $secret) {
    throw "[Actions/Credential/SecretManagement] Secret '$($Context.Name)' was not found in vault '$($Context.Vault)'."
}

if ($secret -is [System.Management.Automation.PSCredential]) {
    return $secret
}

if ($secret -is [securestring]) {
    $userName = if (-not [string]::IsNullOrWhiteSpace([string]$Context.UserName)) { [string]$Context.UserName } else { [string]$Context.Name }
    return [System.Management.Automation.PSCredential]::new($userName, $secret)
}

throw "[Actions/Credential/SecretManagement] Secret '$($Context.Name)' is a '$($secret.GetType().Name)', not a PSCredential or SecureString - cannot resolve it to a credential."
