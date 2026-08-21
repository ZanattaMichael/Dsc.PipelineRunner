Describe "Start-DscRunner pipeline integration" -Tag Integration {

    # These tests deliberately exercise the real runner end-to-end rather than mocking the
    # pipeline apart. The unit suite (../Public/Start-DscRunner.tests.ps1) stubs out ordering,
    # property expansion and the engine so it can assert one behaviour in isolation. Here we
    # drive the genuine collaboration between the runner loop and the components it orchestrates:
    #
    #   * real dependency ordering        (Pipeline Rules/Custom/Sort-DependsOn.ps1)
    #   * real property/variable expansion (Expand-HashTable / Expand-StringInArray)
    #   * real parameter/variable seeding  (GetDefaultValues / SetVariables)
    #   * the real engine seam + contract  (Invoke-EngineAction -> Invoke-Action ->
    #                                       ConvertTo-DscMethodResult -> [DscMethodResult])
    #   * real condition sandboxing        (Assert-SafeConditionExpression)
    #   * real early-stop control          (Stop-TaskProcessing)
    #   * the real structured run report and its on-disk CSV/JSON output
    #
    # Only three collaborators are substituted, and each is stood in for by something that
    # preserves the real contract on a CI runner: the rule LOADERS (Invoke-CustomTask,
    # Invoke-PreParseRules, Invoke-FormatTasks) are replaced because their production path
    # resolves Windows-style "ModuleBase\Pipeline Rules\..." paths and, for PreParse, calls
    # Get-DscResource against DSC resources that are not installed in CI. The Invoke-CustomTask
    # stub still runs the *real* Sort-DependsOn script, so ordering is genuinely exercised.
    #
    # Configurations are written to $TestDrive as JSON so they load through the built-in
    # ConvertFrom-Json (no powershell-yaml dependency), and every resource is evaluated by an
    # inline -EngineAction stub that records what the runner asked of it. That stub is a plain
    # engine: no Invoke-DscResource, no dsc.exe, so the tests are hermetic and cross-platform.

    BeforeAll {

        # --- Load the real dependency graph -------------------------------------------------
        # The DscMethodResult class must be defined before ConvertTo-DscMethodResult constructs
        # one, so dot-source it first.
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName

        # The rule loaders are dot-sourced so Pester has real commands to Mock, but their
        # bodies are never run — the mocks below replace them entirely.
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # The module-script-scope state the runner reads and mutates. Declaring them here mirrors
        # source/prefix.ps1 in the built module; the runner clears them at the top of every run.
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        # Path to the real topological sort, driven by the Invoke-CustomTask stub below.
        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

        # Some collaborators call Get-Module to locate the module base; there is no imported
        # module in the test, so point it at the repository root. (The engine path never reaches
        # this because every run supplies an inline -EngineAction.)
        Mock -CommandName Get-Module -MockWith { return @{ moduleBase = $Global:RepositoryRoot } }

        # Keep the runner's human-readable log off the test output while leaving every piece of
        # real logic intact.
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # Loader stand-ins (see the header comment). Invoke-CustomTask runs the REAL Sort-DependsOn
        # so dependency ordering is genuinely exercised; the other two are the identity/no-op that
        # the real rules reduce to when there are no PreParse/Format rule files to apply.
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

        Mock -CommandName Invoke-PreParseRules -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks)
        }

        Mock -CommandName Invoke-FormatTasks -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks)
            return $Tasks
        }

        # Helpers are defined in BeforeAll (run-time scope) so they are visible to the It blocks;
        # a function declared directly in the Describe body would run only at Pester discovery.

        # Records every engine call the runner makes and answers each method. Any resource whose
        # type ends in '/Drift' reports drift on Test so the Set/FAIL paths can be exercised;
        # everything else is reported in the desired state. GetNewClosure captures $Calls so the
        # scriptblock keeps writing to the caller's list when the engine seam invokes it.
        function New-RecordingEngine {
            param([System.Collections.Generic.List[object]]$Calls)

            return {
                param($Context)
                $Calls.Add([pscustomobject]@{
                    Method   = $Context.Method
                    Name     = $Context.Name
                    Property = $Context.Property
                })
                $inDesiredState = -not ($Context.Method -eq 'Test' -and $Context.Name -eq 'Drift')
                return @{ InDesiredState = [bool]$inDesiredState; Message = "stub-$($Context.Method)" }
            }.GetNewClosure()
        }

        # Writes a config to $TestDrive and returns its path.
        function New-ConfigFile {
            param([string]$Name, [string]$Json)
            $path = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            return $path
        }
    }

    BeforeEach {
        # Belt-and-braces; Start-DscRunner also resets this at the top of every run.
        $script:StopTaskProcessing = $false
    }

    Context "dependency ordering (Sort-DependsOn drives execution order)" {

        It "executes resources in topological order regardless of their order in the file" {

            # Listed C, A, B; A has no dependency, B depends on A, C depends on B.
            # A valid topological order is therefore A, B, C.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/C", "name": "C", "dependsOn": [ "Test/B" ], "properties": {} },
    { "type": "Test/A", "name": "A", "properties": {} },
    { "type": "Test/B", "name": "B", "dependsOn": [ "Test/A" ], "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'ordering.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            $testOrder = @($calls | Where-Object { $_.Method -eq 'Test' } | ForEach-Object { $_.Name })
            $testOrder | Should -Be @('A', 'B', 'C')

            $result.Status         | Should -Be 'Completed'
            $result.TotalResources | Should -Be 3
            $result.PassCount      | Should -Be 3
            $result.FailCount      | Should -Be 0
        }
    }

    Context "parameter defaults and variable expansion reach resource properties" {

        It "expands parameter defaults and variables into a resource's properties" {

            $json = @'
{
  "parameters": { "environmentName": { "defaultValue": "Production" } },
  "variables": { "greeting": "hello" },
  "resources": [
    { "type": "Test/App", "name": "App", "properties": { "env": "$environmentName", "msg": "$greeting-world" } }
  ]
}
'@
            $config = New-ConfigFile -Name 'expansion.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            # The default landed in $parameters and the variable in $variables (real GetDefaultValues
            # + SetVariables), and both were expanded into the property hashtable the engine received
            # (real Expand-HashTable).
            $parameters['environmentName'] | Should -Be 'Production'
            $variables['greeting']         | Should -Be 'hello'

            $testCall = $calls | Where-Object { $_.Method -eq 'Test' } | Select-Object -First 1
            $testCall.Property.env | Should -Be 'Production'
            $testCall.Property.msg | Should -Be 'hello-world'

            $result.PassCount | Should -Be 1
        }
    }

    Context "conditions gate whether a resource runs (#35 sandbox)" {

        It "skips a resource whose condition is false and runs one whose condition is true" {

            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/Skipped", "name": "Skipped", "condition": "1 -ne 1", "properties": {} },
    { "type": "Test/Ran", "name": "Ran", "condition": "1 -eq 1", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'condition.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            $evaluated = @($calls | Where-Object { $_.Method -eq 'Test' } | ForEach-Object { $_.Name })
            $evaluated | Should -Be @('Ran')

            $result.SkipCount | Should -Be 1
            $result.PassCount | Should -Be 1
        }
    }

    Context "drift handling differs between Test and Set mode" {

        It "records drift as a FAIL in Test mode without invoking Set" {

            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/Drift", "name": "Drift", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'drift-test.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            @($calls | Where-Object { $_.Method -eq 'Set' }).Count | Should -Be 0
            $result.FailCount                    | Should -Be 1
            $result.FailedResources.Count        | Should -Be 1
            $result.FailedResources[0].InstanceName | Should -Be 'Drift'
        }

        It "invokes Set to remediate drift in Set mode and reports the resource as passing" {

            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/Drift", "name": "Drift", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'drift-set.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -Mode 'Set' -EngineAction (New-RecordingEngine -Calls $calls)

            $methods = @($calls | ForEach-Object { $_.Method })
            $methods | Should -Contain 'Test'
            $methods | Should -Contain 'Set'

            $result.PassCount | Should -Be 1
            $result.FailCount | Should -Be 0
        }
    }

    Context "Stop-TaskProcessing halts the remaining resources" {

        It "runs up to the resource that calls Stop-TaskProcessing then skips the rest" {

            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/First", "name": "First", "postExecutionScript": "Stop-TaskProcessing", "properties": {} },
    { "type": "Test/Second", "name": "Second", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'stop.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            # Only the first resource was ever evaluated; the second was skipped before Test.
            $evaluated = @($calls | Where-Object { $_.Method -eq 'Test' } | ForEach-Object { $_.Name })
            $evaluated | Should -Be @('First')

            $result.Status    | Should -Be 'StoppedByRequest'
            $result.SkipCount | Should -Be 1
            $result.PassCount | Should -Be 1
        }
    }

    Context "structured report is written to disk" {

        It "produces a CSV and a JSON report matching the run summary" {

            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Test/One", "name": "One", "properties": {} },
    { "type": "Test/Two", "name": "Two", "properties": {} }
  ]
}
'@
            $config    = New-ConfigFile -Name 'report.json' -Json $json
            $reportDir = Join-Path $TestDrive 'reports'
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $calls = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -ReportPath $reportDir -EngineAction (New-RecordingEngine -Calls $calls)

            $csvPath  = Join-Path $reportDir 'report.csv'
            $jsonPath = Join-Path $reportDir 'report.report.json'
            Test-Path -LiteralPath $csvPath  | Should -BeTrue
            Test-Path -LiteralPath $jsonPath | Should -BeTrue

            $document = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            $document.Status         | Should -Be 'Completed'
            $document.TotalResources | Should -Be 2
            $document.PassCount      | Should -Be 2
            $document.FailCount      | Should -Be 0

            # The in-memory run summary and the on-disk report agree.
            $document.PassCount | Should -Be $result.PassCount
        }
    }
}
