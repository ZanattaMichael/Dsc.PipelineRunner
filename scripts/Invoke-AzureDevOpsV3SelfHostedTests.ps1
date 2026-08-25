<#
.SYNOPSIS
Run the self-hosted Azure DevOps real-lifecycle integration suite on the DSC v3 engine
(tag 'AzureDevOpsV3SelfHosted').

.DESCRIPTION
Drives the AzureDevOps-RealLifecycle-DscV3 integration tests, which compile the real Datum
Example Configuration through the runner and drive a genuine build/teardown against a live
Azure DevOps organization -- through Microsoft's DSC v3 command-line engine (dsc.exe) rather
than Invoke-DscResource. Authentication is performed with managed identity via the
AzureDevOpsDscNative resource module (no engine or auth mocks). Kept separate from the default
tests.ps1 run because it requires a real `dsc` executable, the IMDS metadata endpoint, a real
Azure DevOps org, and the AzureDevOpsDscNative module -- none of which exist on the hosted
Linux 'build' agent. This is what the Azure DevOps DSC v3 self-hosted workflow invokes; it can
also be run by hand on the runner.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.OUTPUTS
None. Sets a non-zero exit code (via throw) when any test fails, so a CI step turns red.
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

# Write the run's results to output/testResults so the workflow can publish them as a build
# artifact (the record of the real DSC v3 build/teardown invocation against the live org).
$resultDir = Join-Path $RepositoryRoot 'output/testResults'
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null

$config = New-PesterConfiguration
$config.Run.Path            = Join-Path $RepositoryRoot 'Tests/PipelineRunner/DSCConfiguration/Integration/AzureDevOps-RealLifecycle-DscV3.Integration.tests.ps1'
$config.Filter.Tag         = @('AzureDevOpsV3SelfHosted')
$config.Output.Verbosity   = 'Detailed'
$config.TestResult.Enabled      = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath   = Join-Path $resultDir 'AzureDevOps-RealLifecycle-DscV3.TestResults.xml'
# Emit the exit code from the invocation ourselves (below) so the results file is always
# written even when a test fails -- Run.Exit would exit the host before the upload step.
$config.Run.Exit           = $false

$result = Invoke-Pester -Configuration $config

# Turn the CI step red on any failure, after the results file has been written.
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
    throw "Azure DevOps DSC v3 real-lifecycle suite failed: $($result.FailedCount) failed / $($result.PassedCount) passed."
}
