<#
.SYNOPSIS
Connect action: establish an Azure DevOps authentication session (opt-in).

.DESCRIPTION
Wraps New-AzDoAuthenticationProvider from AzureDevOpsDsc.Common to set up the
ambient session that the AzureDevOpsDscNative resource module consumes during Test/Set/Get.

This is a soft dependency: the module is imported on demand and only if present. The
core runner never lists AzureDevOpsDscNative in RequiredModules, so Azure DevOps support is
opt-in by naming this action (Connect: AzureDevOps) rather than a hard dependency for
every consumer. If the module is not installed a clear, actionable error is thrown.

.PARAMETER Context
A hashtable. Recognized keys:
  OrganizationName   - the Azure DevOps organization (required).
  AuthenticationType - 'ManagedIdentity' (default) or 'PAT'.
  PATToken           - the Personal Access Token, required when AuthenticationType = 'PAT'.
                       A [SecureString] (preferred) or a plain string. It is always handed to
                       the provider as a SecureString: AzureDevOpsDsc 2.0 removed the plain-text
                       -PersonalAccessToken parameter.

.OUTPUTS
$null (the provider registers an ambient session as a side effect).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'A PATToken supplied as a plain string already arrives as plaintext in the action context; the provider only accepts a SecureString, so the conversion is required and the plaintext is never written to any output stream.')]
param(
    [hashtable]$Context = @{}
)

$organizationName = $Context.OrganizationName
if ([string]::IsNullOrWhiteSpace($organizationName)) {
    throw "[Actions/Connect/AzureDevOps] No 'OrganizationName' supplied in the action context."
}

$authenticationType = $Context.AuthenticationType
if ([string]::IsNullOrWhiteSpace($authenticationType)) {
    $authenticationType = 'ManagedIdentity'
}

# Soft dependency: import AzureDevOpsDsc.Common on demand, fail clearly if absent.
if (-not (Get-Command -Name New-AzDoAuthenticationProvider -ErrorAction SilentlyContinue)) {
    if (Get-Module -ListAvailable -Name AzureDevOpsDsc.Common) {
        Import-Module -Name AzureDevOpsDsc.Common -ErrorAction Stop
    }
    else {
        throw "[Actions/Connect/AzureDevOps] Azure DevOps support requires the 'AzureDevOpsDsc.Common' module. Install the Azure DevOps actions pack, or use a different Connect action."
    }
}

switch ($authenticationType) {
    'PAT' {
        # AzureDevOpsDsc 2.0 removed the plain-text -PersonalAccessToken parameter, so the token
        # is always passed as a SecureString (a parameter the 1.x provider accepts as well). A
        # caller may supply either form.
        $patToken = $Context.PATToken
        if ($patToken -is [securestring]) {
            if ($patToken.Length -eq 0) {
                throw "[Actions/Connect/AzureDevOps] AuthenticationType 'PAT' requires a 'PATToken' in the action context."
            }
            $securePatToken = $patToken
        }
        elseif ([string]::IsNullOrWhiteSpace($patToken)) {
            throw "[Actions/Connect/AzureDevOps] AuthenticationType 'PAT' requires a 'PATToken' in the action context."
        }
        else {
            $securePatToken = ConvertTo-SecureString -String ([string]$patToken) -AsPlainText -Force
        }
        Write-Verbose "[Actions/Connect/AzureDevOps] Authenticating to '$organizationName' with a Personal Access Token."
        New-AzDoAuthenticationProvider -OrganizationName $organizationName -SecureStringPersonalAccessToken $securePatToken
    }
    'ManagedIdentity' {
        Write-Verbose "[Actions/Connect/AzureDevOps] Authenticating to '$organizationName' with a Managed Identity."
        New-AzDoAuthenticationProvider -OrganizationName $organizationName -useManagedIdentity
    }
    default {
        throw "[Actions/Connect/AzureDevOps] Unsupported AuthenticationType '$authenticationType'. Use 'ManagedIdentity' or 'PAT'."
    }
}

return $null
