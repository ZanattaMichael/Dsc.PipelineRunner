# Import the Test Helper Module
$TestHelper = Import-Module -Name ".\Tests\TestHelpers\CommonTestFunctions.psm1" -PassThru

# Unload the $Global:RepositoryRoot and $Global:TestPaths variables
Remove-Variable -Name RepositoryRoot -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name TestPaths -Scope Global -ErrorAction SilentlyContinue

$config = New-PesterConfiguration

$config.Run.Path = ".\Tests\PipelineRunner"
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = @( ".\source\Private", ".\source\Public", ".\Pipeline Rules\" )
$config.Output.Verbosity = "Detailed"
$config.CodeCoverage.OutputPath = ".\output\testResults\codeCoverage.xml"

# CI build gate (#25). Make the test run authoritative:
#  - Run.Exit makes Invoke-Pester set a non-zero exit code (and exit the host) when any
#    test fails or the coverage target is missed, so the CI 'build' check turns red instead
#    of reporting green on a failed compile/test.
#  - CoveragePercentTarget enforces a minimum line-coverage floor. The suite currently
#    measures ~95% against the source under CodeCoverage.Path; the floor is set well below
#    that so genuine regressions trip it without flagging normal churn.
$config.CodeCoverage.CoveragePercentTarget = 85
$config.Run.Exit = $true

# The default gate is unit-only. Every integration suite is tagged 'Integration' (the
# self-hosted ones additionally carry 'DscV2SelfHosted' / 'AzureDevOpsSelfHosted'), so excluding
# 'Integration' keeps all of them out of this run:
#  - The mocked integration suites (AzureDevOps-Lifecycle, Start-DscRunner) are cross-platform
#    but belong to the integration layer, not the unit gate.
#  - DscV2SelfHosted drives a real Invoke-DscResource (the Windows / PowerShell-DSC engine path)
#    against a live DSC resource.
#  - AzureDevOpsSelfHosted compiles the real Datum Example Configuration and drives a genuine
#    build/teardown against a live Azure DevOps organization via managed identity.
# The integration suites are run on demand and by their own workflows (DscV2-SelfHosted.yml,
# AzureDevOps-SelfHosted.yml). The self-hosted tags are listed explicitly as well so intent is
# clear even if an integration suite is ever added without the base 'Integration' tag.
$config.Filter.ExcludeTag = @('Integration', 'DscV2SelfHosted', 'AzureDevOpsSelfHosted')

# Get the path to the function being tested

Invoke-Pester -Configuration $config
