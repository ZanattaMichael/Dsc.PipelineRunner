# Import the Test Helper Module
$TestHelper = Import-Module -Name ".\Tests\TestHelpers\CommonTestFunctions.psm1" -PassThru

# Unload the $Global:RepositoryRoot and $Global:TestPaths variables
Remove-Variable -Name RepositoryRoot -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name TestPaths -Scope Global -ErrorAction SilentlyContinue

$config = New-PesterConfiguration

$config.Run.Path = ".\Tests\LCM"
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = @( ".\source\Private", ".\source\Public", ".\Pipeline Rules\" )
$config.Output.Verbosity = "Detailed"
$config.CodeCoverage.OutputPath = ".\output\testResults\codeCoverage.xml"

# Get the path to the function being tested

Invoke-Pester -Configuration $config
