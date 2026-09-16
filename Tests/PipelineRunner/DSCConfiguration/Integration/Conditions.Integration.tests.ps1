Describe "preCondition/postCondition through a real runner pass" -Tag Integration, HostedIntegration {

    # preCondition and postCondition are well covered in isolation: Assert-SafeConditionExpression.tests.ps1
    # drives the predicate allow-list against raw strings, and Start-DscRunner.tests.ps1 asserts the
    # skip/fail semantics with ConvertFrom-Yaml and the configuration file itself mocked away.
    #
    # What no unit test proves is that a condition AUTHORED IN A CONFIGURATION FILE works. That is a
    # different claim, and it depends on a chain the unit suites substitute:
    #
    #   * the condition string surviving the real file parse            (Start-DscRunner:~270)
    #   * `variables()` reading what the real Set-Variables rule wrote
    #     from the file's own `variables` block                         (Start-DscRunner:249)
    #   * Assert-SafeConditionExpression + ConvertTo-NormalizedConditionExpression
    #     validating and rewriting the same text that is then executed  (Start-DscRunner:348/354)
    #   * `result()` returning the real [DscMethodResult] the engine seam built
    #     from the engine's own output                                  (Start-DscRunner:572)
    #   * `stopProcessing()` setting the flag the runner reads one resource later,
    #     in the order the real Sort-DependsOn produced                 (Start-DscRunner:315)
    #
    # As in NotifyUsing.Integration.tests.ps1, only the rule LOADERS are substituted (their production
    # path resolves Windows-style "ModuleBase\Pipeline Rules\..." paths and calls Get-DscResource
    # against resources that are not installed in CI); the stub runs the REAL rule scripts, so
    # ordering is genuinely exercised. The engine is an inline -EngineAction, so this suite is
    # hermetic and cross-platform - no Invoke-DscResource, no dsc.exe.

    BeforeAll {

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
        . (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        . (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        . (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName

        # The validator and the normalizer are the two halves of the condition gate, and the
        # accessors below are what an allow-listed condition may call. Dot-sourcing each defines
        # its alias in this scope, which is what the script block built from a condition resolves.
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'variables.ps1').FullName
        . (Get-FunctionPath 'parameters.ps1').FullName
        . (Get-FunctionPath 'reference.ps1').FullName
        . (Get-FunctionPath 'equals.ps1').FullName
        . (Get-FunctionPath 'not.ps1').FullName
        . (Get-FunctionPath 'result.ps1').FullName
        . (Get-FunctionPath 'stopProcessing.ps1').FullName
        . (Get-FunctionPath 'using.ps1').FullName

        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Start-DscRunner clears and repopulates all three per run (Start-DscRunner:228-230), so
        # one set here is safe across every test in the file.
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName
        $script:ExpandNotifyPath  = (Get-FunctionPath 'Expand-NotifyDependsOn.ps1').FullName

        Mock -CommandName Get-Module -MockWith { return @{ moduleBase = $Global:RepositoryRoot } }
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory = $true)] [Object[]]$Tasks,
                [Parameter(Mandatory = $true)] [String]$CustomTaskName
            )
            switch ($CustomTaskName) {
                'Expand-NotifyDependsOn' { return (& $script:ExpandNotifyPath -PipelineResources $Tasks) }
                'Sort-DependsOn'         { return (& $script:SortDependsOnPath -PipelineResources $Tasks) }
                default                  { return $Tasks }
            }
        }

        Mock -CommandName Invoke-PreParseRules -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks, [hashtable]$Settings)
        }

        Mock -CommandName Invoke-FormatTasks -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks)
            return $Tasks
        }

        # Records every engine call so a test can assert that a skipped resource never reached the
        # engine at all - the difference between "skipped" and "ran and passed" is invisible in the
        # report's Status alone for a resource that would have passed anyway.
        #
        # -InDesiredState drives what the real ConvertTo-DscMethodResult hands back to result(),
        # which is the value a postCondition is asserting over.
        function New-ConditionEngine {
            param(
                [System.Collections.Generic.List[object]]$Calls,
                [bool]$InDesiredState = $true
            )

            return {
                param($Context)
                $Calls.Add([pscustomobject]@{
                    Method = $Context.Method
                    Name   = $Context.Name
                })
                return @{
                    InDesiredState = $InDesiredState
                    Message        = "engine-$($Context.Method)-$($Context.Name)"
                }
            }.GetNewClosure()
        }

        function New-ConfigFile {
            param([string]$Name, [string]$Json)
            $path = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            return $path
        }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
    }

    Context "preCondition decides whether a resource is evaluated at all" {

        It "skips the resource and records SKIP when a preCondition over a configuration variable is false" {

            # The variable is read by the real Set-Variables rule out of the file's own `variables`
            # block, so this asserts the whole path from authored YAML/JSON key to predicate result,
            # not just that a $false predicate skips.
            $json = @'
{
  "parameters": {},
  "variables": { "Environment": "Dev" },
  "resources": [
    { "type": "Module/Gated", "name": "Gated", "preCondition": "(variables 'Environment') -eq 'Prod'", "properties": {} },
    { "type": "Module/Always", "name": "Always", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'precondition-false.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            $result.Status    | Should -Be 'Completed'
            $result.FailCount | Should -Be 0

            $gated = @($result.Results | Where-Object { $_.InstanceName -eq 'Gated' })
            $gated.Status       | Should -Be 'SKIP'
            $gated.ErrorMessage | Should -BeLike '*skipped due to preCondition*'

            # A skip is a skip: the engine was never asked about this resource.
            @($calls | Where-Object { $_.Name -eq 'Gated' }).Count | Should -Be 0

            # And the skip is scoped to its own resource.
            @($result.Results | Where-Object { $_.InstanceName -eq 'Always' }).Status | Should -Be 'OK'
        }

        It "evaluates the resource when the preCondition holds, through the equals() accessor" {

            # Same file shape, but the predicate is written with the function-language accessors
            # rather than a PowerShell comparison, so the allow-listed call path is exercised too.
            #
            # Note the space-separated argument form. The accessors are ordinary PowerShell
            # commands, so `equals (variables 'X') 'Y'` binds two parameters while the call-style
            # `equals(variables('X'), 'Y')` binds ONE array argument and mis-binds silently - the
            # trap the README calls out, and one no unit test pins down, because every unit
            # fixture passes a condition string that was hand-written to parse.
            $json = @'
{
  "parameters": {},
  "variables": { "Environment": "Dev" },
  "resources": [
    { "type": "Module/Gated", "name": "Gated", "preCondition": "equals (variables 'Environment') 'Dev'", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'precondition-true.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            $result.FailCount | Should -Be 0
            @($result.Results | Where-Object { $_.InstanceName -eq 'Gated' }).Status | Should -Be 'OK'
            @($calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Gated' }).Count | Should -Be 1
        }

        It "fails only the resource whose preCondition is rejected as unsafe, and still runs the rest" {

            # Assert-SafeConditionExpression runs before the condition does, so the command never
            # executes; the resource is failed and the file continues. Written as a command
            # invocation because that is the class of expression the gate exists to refuse.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Unsafe", "name": "Unsafe", "preCondition": "Get-ChildItem -Path . | Out-Null", "properties": {} },
    { "type": "Module/Always", "name": "Always", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'precondition-unsafe.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $result = Start-DscRunner -FilePath $config -EngineAction $engine -ErrorAction SilentlyContinue

            $result.FailCount | Should -Be 1
            $failed = @($result.Results | Where-Object { $_.Status -eq 'FAIL' })
            $failed.InstanceName | Should -Be 'Unsafe'
            $failed.ErrorMessage | Should -BeLike '*side-effect-free predicate*'

            @($calls | Where-Object { $_.Name -eq 'Unsafe' }).Count | Should -Be 0
            @($result.Results | Where-Object { $_.InstanceName -eq 'Always' }).Status | Should -Be 'OK'
        }

        It "fails only the resource whose preCondition calls the postCondition-only result() accessor" {

            # The accessor boundary (#57 §2) from the configuration side: preCondition is validated
            # without -AllowStopProcessing, so result() is just another disallowed command there.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Boundary", "name": "Boundary", "preCondition": "result().InDesiredState", "properties": {} },
    { "type": "Module/Always", "name": "Always", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'precondition-result.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $result = Start-DscRunner -FilePath $config -EngineAction $engine -ErrorAction SilentlyContinue

            $failed = @($result.Results | Where-Object { $_.Status -eq 'FAIL' })
            $failed.InstanceName | Should -Be 'Boundary'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Always' }).Status | Should -Be 'OK'
        }
    }

    Context "postCondition asserts over the engine's own result" {

        It "marks the resource FAIL when a postCondition reading result() returns false, though the engine reported InDesiredState" {

            # The whole point of postCondition: the engine is content, the configuration is not.
            # result() must carry the real [DscMethodResult] the engine seam built - the Message
            # asserted here is the one New-ConditionEngine returned for this resource's own call.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Checked", "name": "Checked", "postCondition": "result().Message -eq 'never-matches'", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'postcondition-false.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls -InDesiredState $true

            $result = Start-DscRunner -FilePath $config -EngineAction $engine -ErrorAction SilentlyContinue

            $result.FailCount | Should -Be 1
            $checked = @($result.Results | Where-Object { $_.InstanceName -eq 'Checked' })
            $checked.Status       | Should -Be 'FAIL'
            $checked.ErrorMessage | Should -BeLike '*failed postCondition*'

            # The engine did run - this is a verdict on the outcome, not a skip.
            @($calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Checked' }).Count | Should -Be 1
        }

        It "passes the resource when the postCondition's assertion over result() holds" {

            # The contrast case, and the one that proves result() is genuinely wired to the engine's
            # output rather than returning $null (which would make the previous test pass for the
            # wrong reason - $null -eq 'never-matches' is also false).
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Checked", "name": "Checked", "postCondition": "result().Message -eq 'engine-Test-Checked'", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'postcondition-true.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls -InDesiredState $true

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            $result.FailCount | Should -Be 0
            @($result.Results | Where-Object { $_.InstanceName -eq 'Checked' }).Status | Should -Be 'OK'
        }

        It "stops the remaining resources when a postCondition calls stopProcessing()" {

            # stopProcessing() is the one accessor with a deliberate side effect, and the only one
            # whose effect is invisible until the NEXT resource is reached. dependsOn fixes the
            # order through the real Sort-DependsOn, so 'Last' is genuinely after 'Stopper'.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Last", "name": "Last", "dependsOn": [ "Module/Stopper/Stopper" ], "properties": {} },
    { "type": "Module/Stopper", "name": "Stopper", "dependsOn": [ "Module/First/First" ], "postCondition": "stopProcessing()", "properties": {} },
    { "type": "Module/First", "name": "First", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'postcondition-stop.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            $result.Status | Should -Be 'StoppedByRequest'

            # Everything up to and including the stopper ran; the resource after it did not.
            @($result.Results | Where-Object { $_.InstanceName -eq 'First' }).Status   | Should -Be 'OK'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Stopper' }).Status | Should -Be 'OK'

            $last = @($result.Results | Where-Object { $_.InstanceName -eq 'Last' })
            $last.Status       | Should -Be 'SKIP'
            $last.ErrorMessage | Should -BeLike "*Stop-TaskProcessing*"

            @($calls | Where-Object { $_.Name -eq 'Last' }).Count | Should -Be 0
        }

        It "does not leak a stopProcessing() request from one run into the next" {

            # $script:StopTaskProcessing is module-scope state that outlives a single run, so the
            # reset at the top of Start-DscRunner is load-bearing: without it the run above would
            # skip every resource of the run below. Asserted here rather than relying on the
            # BeforeEach, which would hide a missing reset in the product.
            $stopJson = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Stopper", "name": "Stopper", "postCondition": "stopProcessing()", "properties": {} }
  ]
}
'@
            $plainJson = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Plain", "name": "Plain", "properties": {} }
  ]
}
'@
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-ConditionEngine -Calls $calls

            $null = Start-DscRunner -FilePath (New-ConfigFile -Name 'stop-leak-first.json' -Json $stopJson) -EngineAction $engine
            $script:StopTaskProcessing | Should -BeTrue

            $second = Start-DscRunner -FilePath (New-ConfigFile -Name 'stop-leak-second.json' -Json $plainJson) -EngineAction $engine

            $second.Status | Should -Be 'Completed'
            @($second.Results | Where-Object { $_.InstanceName -eq 'Plain' }).Status | Should -Be 'OK'
            @($calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Plain' }).Count | Should -Be 1
        }
    }
}
