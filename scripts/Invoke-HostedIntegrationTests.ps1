<#
.SYNOPSIS
Run the hosted-agent integration suites (tag 'HostedIntegration').

.DESCRIPTION
Drives the integration suites that need a real dependency but not a real Windows host:

  * NotifyUsing.Integration.tests.ps1 - notify/using() gated reads through a genuine
    Start-DscRunner pass over a configuration file on disk.
  * SecretManagementCredential.Integration.tests.ps1 - the Credential/SecretManagement action
    against a live Microsoft.PowerShell.SecretStore vault.

Kept out of the default tests.ps1 run, which excludes the 'Integration' tag because the unit
gate must stay hermetic and fast. This is what the hosted integration workflow invokes; it can
also be run by hand.

The SecretManagement suite refuses to run unless PIPELINERUNNER_ALLOW_SECRETSTORE_RESET is
'true', because configuring SecretStore for unattended use erases the current user's existing
secrets. This script sets it only when -AllowSecretStoreReset is passed, so running the script
by hand on a workstation skips that suite instead of destroying a real vault.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.PARAMETER AllowSecretStoreReset
Opt in to resetting the current user's SecretStore so the live-vault suite can run. Intended
for ephemeral CI agents.

.PARAMETER SkipModuleInstall
Do not attempt to install the SecretManagement modules; use whatever is already present.

.OUTPUTS
None. Sets a non-zero exit code (Run.Exit) when any test fails, so a CI step turns red.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$AllowSecretStoreReset,
    [switch]$SkipModuleInstall
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $RepositoryRoot

# SecretManagement plus the cross-platform SecretStore extension. Installed only when missing so
# a warm runner is not re-provisioned on every run. A failure here is not fatal: the live-vault
# suite detects the missing module and skips itself with a warning.
if (-not $SkipModuleInstall) {
    foreach ($moduleName in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            # Write-Information over Write-Host: this still shows in the CI log with
            # -InformationAction Continue, but stays capturable/redirectable (PSAvoidUsingWriteHost).
            Write-Information "Installing $moduleName ..." -InformationAction Continue
            try {
                Install-Module -Name $moduleName -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not install ${moduleName}: $($_.Exception.Message). The live-vault suite will skip."
            }
        }
    }
}

if ($AllowSecretStoreReset) {
    $env:PIPELINERUNNER_ALLOW_SECRETSTORE_RESET = 'true'
}

# Use Pester v5 explicitly; a stale built-in Pester would break New-PesterConfiguration.
Import-Module -Name Pester -MinimumVersion '5.0.0' -MaximumVersion '5.9999.9999' -Force -ErrorAction Stop

# Provides Get-FunctionPath and (re)initializes $Global:RepositoryRoot for the test bootstrap.
Import-Module -Name (Join-Path $RepositoryRoot 'Tests/TestHelpers/CommonTestFunctions.psm1') -Force
Remove-Variable -Name RepositoryRoot -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name TestPaths      -Scope Global -ErrorAction SilentlyContinue

$config = New-PesterConfiguration
$config.Run.Path         = Join-Path $RepositoryRoot 'Tests/PipelineRunner/DSCConfiguration/Integration'
$config.Filter.Tag       = @('HostedIntegration')
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit         = $true

Invoke-Pester -Configuration $config
