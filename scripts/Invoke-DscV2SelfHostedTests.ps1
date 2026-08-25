<#
.SYNOPSIS
Run the self-hosted DSC v2 real-engine integration suite (tag 'DscV2SelfHosted').

.DESCRIPTION
Drives the DscV2Engine-RealInvokeDscResource integration tests, which exercise the runner's
DSC v2 engine against a real Invoke-DscResource (no engine mock). Kept separate from the
default tests.ps1 run because that path is Windows / PowerShell-DSC specific and belongs on
the self-hosted runner. This is what the DSC v2 self-hosted workflow invokes; it can also be
run by hand on the runner.

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

# Use Pester v5 explicitly; a stale built-in Pester (v3 on Windows) would break
# New-PesterConfiguration if it auto-loaded first.
Import-Module -Name Pester -MinimumVersion '5.0.0' -MaximumVersion '5.9999.9999' -Force -ErrorAction Stop

# Provides Get-FunctionPath and (re)initializes $Global:RepositoryRoot for the test bootstrap.
Import-Module -Name (Join-Path $RepositoryRoot 'Tests/TestHelpers/CommonTestFunctions.psm1') -Force
Remove-Variable -Name RepositoryRoot -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name TestPaths      -Scope Global -ErrorAction SilentlyContinue

$config = New-PesterConfiguration
$config.Run.Path        = Join-Path $RepositoryRoot 'Tests/PipelineRunner/DSCConfiguration/Integration/DscV2Engine-RealInvokeDscResource.Integration.tests.ps1'
$config.Filter.Tag      = @('DscV2SelfHosted')
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit        = $true

Invoke-Pester -Configuration $config
