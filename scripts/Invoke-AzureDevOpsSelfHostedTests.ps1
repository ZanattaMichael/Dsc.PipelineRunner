<#
.SYNOPSIS
Run the self-hosted Azure DevOps real-lifecycle integration suite (tag 'AzureDevOpsSelfHosted').

.DESCRIPTION
Drives the AzureDevOps-RealLifecycle integration tests, which compile the real Datum
Example Configuration through the runner and drive a genuine build/teardown against a live
Azure DevOps organization. Authentication is performed with managed identity via the
AzureDevOpsDscNative resource module (no engine or auth mocks). Kept separate from the default
tests.ps1 run because it requires the IMDS metadata endpoint, a real Azure DevOps org, and the
AzureDevOpsDscNative module — none of which exist on the hosted Linux 'build' agent. This is
what the Azure DevOps self-hosted workflow invokes; it can also be run by hand on the runner.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.OUTPUTS
None. Sets a non-zero exit code (Run.Exit) when any test fails, so a CI step turns red.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $RepositoryRoot

# Use Pester v5 explicitly; a stale built-in Pester (v3/v4 on Windows) would break
# New-PesterConfiguration if it auto-loaded first.
Import-Module -Name Pester -MinimumVersion '5.0.0' -MaximumVersion '5.9999.9999' -Force -ErrorAction Stop

# Provides Get-FunctionPath and (re)initializes $Global:RepositoryRoot for the test bootstrap.
Import-Module -Name (Join-Path $RepositoryRoot 'Tests/TestHelpers/CommonTestFunctions.psm1') -Force
Remove-Variable -Name RepositoryRoot -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name TestPaths      -Scope Global -ErrorAction SilentlyContinue

$config = New-PesterConfiguration
$config.Run.Path         = Join-Path $RepositoryRoot 'Tests/PipelineRunner/DSCConfiguration/Integration/AzureDevOps-RealLifecycle.Integration.tests.ps1'
$config.Filter.Tag       = @('AzureDevOpsSelfHosted')
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit         = $true

Invoke-Pester -Configuration $config
