Describe "DSC v2 environment lifecycle through a real Invoke-DscResource" -Tag Integration, DscV2SelfHosted {

    # This suite proves the runner can stand up ("build") and tear down an environment end-to-end
    # through the REAL DSC v2 engine -- Actions/Engine/DscV2.ps1 -> Invoke-DscResource -- with NO
    # engine mock. Invoke-DscResource genuinely runs a live, dependency-free class-based resource
    # (the PipelineRunnerFile test fixture), so this exercises actual PowerShell DSC on the host.
    #
    # Because Invoke-DscResource is the Windows / PowerShell-DSC path, this suite is tagged
    # 'DscV2SelfHosted' and is intended to run only on the self-hosted Windows + PowerShell 7
    # runner. The default test run (tests.ps1) excludes that tag so it never runs on the hosted
    # Linux agent, where the DSC v2 engine is not the target platform.
    #
    # The fixture resource maps a marker file's presence on disk to a cloud object "existing", so
    # the lifecycle mirrors the Example Configuration's build/teardown shape:
    #
    #   * BUILD    -> a Project marker plus resources that depend on it are created (Ensure=Present).
    #   * TEARDOWN -> the Project is removed (Ensure=Absent) and its postExecutionScript calls
    #                 Stop-TaskProcessing, so removing the project halts the rest of the run -- the
    #                 real "delete the project, everything under it cascades" model.
    #
    # Everything is real: the Datum-shaped compiled configuration, dependency ordering
    # (Sort-DependsOn), variable seeding/expansion, per-resource conditions, the engine seam and
    # its [DscMethodResult] contract, Invoke-DscResource itself, and the postExecutionScript /
    # Stop-TaskProcessing teardown control flow. Only the file/engine-loader boundary
    # (Get-Module 'Dsc.PipelineRunner') is pointed at the repository root so the real engine
    # action file resolves without an installed module.

    BeforeAll {

        # The DSC v2 engine must be usable on this host.
        if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
            Import-Module -Name PSDesiredStateConfiguration -ErrorAction Stop
        }

        # --- Load the real dependency graph (class first, then the runner chain and engine seam).
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName

        # Dot-sourced so Pester has real commands to Mock; the mocks below replace their bodies.
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-script-scope state the runner reads/mutates (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        # Calling Get-FunctionPath also initializes $Global:RepositoryRoot.
        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

        # Make the dependency-free class-based DSC resource discoverable by Invoke-DscResource.
        $script:FixtureRoot = Join-Path $Global:RepositoryRoot 'Tests/Fixtures/DscV2'
        if (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $script:FixtureRoot) {
            $env:PSModulePath = $script:FixtureRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
        }

        # The resource type the whole lifecycle turns on.
        $script:ResourceType = 'PipelineRunnerTestResource/PipelineRunnerFile'
        $script:ProjectMarker = 'Blue'

        # Point ONLY the engine-file loader (Invoke-Action's Get-Module 'Dsc.PipelineRunner') at
        # the repository root so it resolves the real Actions/Engine/DscV2.ps1 on a runner with no
        # installed module. The parameter filter leaves every other Get-Module call untouched --
        # notably the ones DSC makes internally while resolving the resource.
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith {
            return @{ ModuleBase = $Global:RepositoryRoot }
        }

        # Keep the runner's log off the test output; all real logic stays intact.
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # Loader stand-ins. Invoke-CustomTask runs the REAL Sort-DependsOn so dependency ordering
        # is genuinely exercised: the Project (no dependsOn) must be scheduled ahead of the
        # resources that depend on it.
        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory = $true)] [Object[]]$Tasks,
                [Parameter(Mandatory = $true)] [String]$CustomTaskName
            )
            if ($CustomTaskName -eq 'Sort-DependsOn') {
                return (& $script:SortDependsOnPath -PipelineResources $Tasks)
            }
            return $Tasks
        }
        Mock -CommandName Invoke-PreParseRules -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) }
        Mock -CommandName Invoke-FormatTasks   -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }

        # NOTE: Invoke-DscResource is deliberately NOT mocked -- exercising it for real is the
        # entire point of this suite.

        # Writes a build (Ensure=Present) and a teardown (Ensure=Absent) JSON configuration whose
        # resources target the fixture resource under $StateDir. JSON is used so the runner's own
        # load path needs no powershell-yaml on the self-hosted runner. Mirrors the Example
        # Configuration: a Project the others depend on, and a teardown whose Absent Project halts
        # the run via Stop-TaskProcessing.
        function New-LifecycleConfigs {
            param([string]$StateDir, [string]$OutputDir)

            $buildResources = @(
                [ordered]@{
                    type       = $script:ResourceType
                    name       = 'Project'
                    properties = [ordered]@{ Name = '$ProjectName'; Path = '$StatePath'; Ensure = 'Present' }
                }
                [ordered]@{
                    type       = $script:ResourceType
                    name       = 'Repository'
                    dependsOn  = @("$($script:ResourceType)/Project")
                    properties = [ordered]@{ Name = 'Repository'; Path = '$StatePath'; Ensure = 'Present' }
                }
                [ordered]@{
                    type       = $script:ResourceType
                    name       = 'Group'
                    dependsOn  = @("$($script:ResourceType)/Project")
                    properties = [ordered]@{ Name = 'Group'; Path = '$StatePath'; Ensure = 'Present' }
                }
            )

            $teardownResources = @(
                [ordered]@{
                    type                = $script:ResourceType
                    name                = 'Project'
                    postExecutionScript = "if (`$Project_Ensure -eq 'Absent') { Stop-TaskProcessing }"
                    properties          = [ordered]@{ Name = '$ProjectName'; Path = '$StatePath'; Ensure = 'Absent' }
                }
                [ordered]@{
                    type       = $script:ResourceType
                    name       = 'Repository'
                    dependsOn  = @("$($script:ResourceType)/Project")
                    properties = [ordered]@{ Name = 'Repository'; Path = '$StatePath'; Ensure = 'Absent' }
                }
                [ordered]@{
                    type       = $script:ResourceType
                    name       = 'Group'
                    dependsOn  = @("$($script:ResourceType)/Project")
                    properties = [ordered]@{ Name = 'Group'; Path = '$StatePath'; Ensure = 'Absent' }
                }
            )

            $buildConfig = [ordered]@{
                parameters = @{}
                variables  = [ordered]@{ StatePath = $StateDir; ProjectName = $script:ProjectMarker }
                resources  = $buildResources
            }
            $teardownConfig = [ordered]@{
                parameters = @{}
                variables  = [ordered]@{ StatePath = $StateDir; ProjectName = $script:ProjectMarker; Project_Ensure = 'Absent' }
                resources  = $teardownResources
            }

            $buildPath    = Join-Path $OutputDir 'build.json'
            $teardownPath = Join-Path $OutputDir 'teardown.json'
            $buildConfig    | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $buildPath -Encoding UTF8
            $teardownConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $teardownPath -Encoding UTF8

            return [pscustomobject]@{ Build = $buildPath; Teardown = $teardownPath }
        }

        function Test-MarkerExists {
            param([string]$StateDir, [string]$Name)
            return (Test-Path -LiteralPath (Join-Path $StateDir ('{0}.marker' -f $Name)))
        }
    }

    BeforeEach {
        # A fresh, empty environment (its own state directory + freshly written configs) per test.
        $script:StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        $configDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $script:Configs = New-LifecycleConfigs -StateDir $script:StateDir -OutputDir $configDir
        $script:StopTaskProcessing = $false
    }

    It "builds the environment: real Invoke-DscResource creates every marker" {
        $build = Start-DscRunner -FilePath $script:Configs.Build -Mode 'Set' -Engine 'DscV2'

        # A Present Project never triggers Stop-TaskProcessing, so the whole file runs to the end.
        $build.Status     | Should -Be 'Completed'
        $build.FailCount  | Should -Be 0
        $build.PassCount  | Should -Be 3

        # The engine really ran the resource's Set() through Invoke-DscResource: every marker
        # exists on disk.
        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeTrue
        Test-MarkerExists -StateDir $script:StateDir -Name 'Repository'          | Should -BeTrue
        Test-MarkerExists -StateDir $script:StateDir -Name 'Group'               | Should -BeTrue
    }

    It "tears the environment down: the Absent Project halts the run via Stop-TaskProcessing" {
        # Start from an already-provisioned environment.
        $null = Start-DscRunner -FilePath $script:Configs.Build -Mode 'Set' -Engine 'DscV2'
        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeTrue

        $teardown = Start-DscRunner -FilePath $script:Configs.Teardown -Mode 'Set' -Engine 'DscV2'

        # The Absent Project's postExecutionScript calls Stop-TaskProcessing, so the run halts.
        $teardown.Status    | Should -Be 'StoppedByRequest'
        $teardown.SkipCount | Should -BeGreaterThan 0

        # The project marker was really deleted by Invoke-DscResource; the dependent resources
        # never ran (the run stopped right after the project), so their markers still exist.
        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeFalse
        Test-MarkerExists -StateDir $script:StateDir -Name 'Repository'          | Should -BeTrue
        Test-MarkerExists -StateDir $script:StateDir -Name 'Group'               | Should -BeTrue
    }

    It "completes a full build -> teardown cycle" {
        $build = Start-DscRunner -FilePath $script:Configs.Build -Mode 'Set' -Engine 'DscV2'
        $build.Status | Should -Be 'Completed'
        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeTrue

        $teardown = Start-DscRunner -FilePath $script:Configs.Teardown -Mode 'Set' -Engine 'DscV2'
        $teardown.Status | Should -Be 'StoppedByRequest'
        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeFalse
    }

    It "reports drift as failures in Test mode without provisioning anything" {
        # Test mode over an empty environment: every resource is drift, and the runner must not
        # call Set -- so no marker is created.
        $test = Start-DscRunner -FilePath $script:Configs.Build -Mode 'Test' -Engine 'DscV2'

        $test.Status    | Should -Be 'Completed'
        $test.FailCount | Should -BeGreaterThan 0

        Test-MarkerExists -StateDir $script:StateDir -Name $script:ProjectMarker | Should -BeFalse
        Test-MarkerExists -StateDir $script:StateDir -Name 'Repository'          | Should -BeFalse
        Test-MarkerExists -StateDir $script:StateDir -Name 'Group'               | Should -BeFalse
    }
}
