Describe "the extended function language through a real runner pass" -Tag Integration, HostedIntegration {

    # Arithmetic.tests.ps1, StringFunctions.tests.ps1 and RunContext.tests.ps1 drive each accessor
    # directly, and Assert-SafeConditionExpression.tests.ps1 drives the allow-list against raw
    # strings. Neither proves that an accessor AUTHORED IN A CONFIGURATION FILE reaches a decision,
    # because an accessor can be correct and still be unusable - rejected by the validator, broken
    # by the zero-argument rewrite, or handed a value the file's own `variables` block never
    # produced. Those are exactly the failures a unit test cannot see.
    #
    # So this suite runs the genuine Start-DscRunner loop over real files on disk and asserts on
    # the decisions the accessors produced:
    #
    #   * the allow-list admitting each new accessor in a condition read from a file (Start-DscRunner:~348)
    #   * `variables()` feeding them what the real Set-Variables wrote                (Start-DscRunner:249)
    #   * `using()` gated by the real notify map, from a preCondition rather than
    #     from property expansion                                                     (Start-DscRunner:~266/311)
    #   * `nodeName()` / `configurationFile()` surviving the zero-argument rewrite and
    #     being CLEARED when the file is finished                                     (Start-DscRunner finally)
    #   * the documented `result() -or stopProcessing()` composition parsing at all
    #
    # As in NotifyUsing/Conditions.Integration.tests.ps1, only the rule LOADERS are substituted
    # (their production path resolves Windows-style "ModuleBase\Pipeline Rules\..." paths and calls
    # Get-DscResource against resources that are not installed in CI); the stub runs the REAL rule
    # scripts, so notify expansion and the topological sort are genuinely exercised. The engine is
    # an inline -EngineAction, so this suite is hermetic and cross-platform.

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

        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName

        # Dot-sourcing each accessor defines its alias in this scope, which is what the script
        # block built from a condition resolves. The two internal helpers are what the variadic
        # and arithmetic accessors call in turn.
        . (Get-FunctionPath 'ConvertTo-ConditionNumber.ps1').FullName
        . (Get-FunctionPath 'Expand-ConditionArgumentList.ps1').FullName
        . (Get-FunctionPath 'variables.ps1').FullName
        . (Get-FunctionPath 'parameters.ps1').FullName
        . (Get-FunctionPath 'reference.ps1').FullName
        . (Get-FunctionPath 'equals.ps1').FullName
        . (Get-FunctionPath 'not.ps1').FullName
        . (Get-FunctionPath 'result.ps1').FullName
        . (Get-FunctionPath 'stopProcessing.ps1').FullName
        . (Get-FunctionPath 'using.ps1').FullName
        . (Get-FunctionPath 'nodeName.ps1').FullName
        . (Get-FunctionPath 'configurationFile.ps1').FullName
        . (Get-FunctionPath 'concat.ps1').FullName
        . (Get-FunctionPath 'empty.ps1').FullName
        . (Get-FunctionPath 'coalesce.ps1').FullName
        . (Get-FunctionPath 'toLower.ps1').FullName
        . (Get-FunctionPath 'toUpper.ps1').FullName
        . (Get-FunctionPath 'startsWith.ps1').FullName
        . (Get-FunctionPath 'contains.ps1').FullName
        . (Get-FunctionPath 'add.ps1').FullName
        . (Get-FunctionPath 'sub.ps1').FullName
        . (Get-FunctionPath 'mul.ps1').FullName
        . (Get-FunctionPath 'div.ps1').FullName
        . (Get-FunctionPath 'mod.ps1').FullName
        . (Get-FunctionPath 'min.ps1').FullName
        . (Get-FunctionPath 'max.ps1').FullName
        . (Get-FunctionPath 'int.ps1').FullName
        . (Get-FunctionPath 'float.ps1').FullName

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

        # Records the properties each engine call was handed, so a test can assert what an
        # accessor actually resolved to rather than only that the resource passed.
        function New-RecordingEngine {
            param(
                [System.Collections.Generic.List[object]]$Calls,
                [hashtable]$GetOutputs = @{}
            )

            return {
                param($Context)
                $Calls.Add([pscustomobject]@{
                    Method   = $Context.Method
                    Name     = $Context.Name
                    Property = $Context.Property
                })
                $result = @{ InDesiredState = $true; Message = "engine-$($Context.Method)-$($Context.Name)" }
                if ($Context.Method -eq 'Get' -and $GetOutputs.ContainsKey($Context.Name)) {
                    $result.Raw = $GetOutputs[$Context.Name]
                }
                return $result
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

    Context "arithmetic and string accessors decide a preCondition" {

        It "gates resources on arithmetic, case folding, membership and emptiness read from the file's own variables" {

            # One file rather than six, deliberately: every resource here reads the SAME
            # `variables` block, so a failure isolates to the accessor rather than to whether
            # Set-Variables ran. NodeIndex is quoted in the file - a YAML/JSON scalar reaching a
            # condition as a string is the normal case, and int() is what makes it comparable.
            $json = @'
{
  "parameters": {},
  "variables": { "NodeIndex": "4", "Environment": "Production", "Flags": [ "Boards", "Repos" ] },
  "resources": [
    { "type": "Module/Even",    "name": "Even",    "preCondition": "(mod (int (variables 'NodeIndex')) 2) -eq 0",                        "properties": { "port": "$(add 8000 (int (variables 'NodeIndex')))" } },
    { "type": "Module/Odd",     "name": "Odd",     "preCondition": "(mod (int (variables 'NodeIndex')) 2) -eq 1",                        "properties": {} },
    { "type": "Module/Prod",    "name": "Prod",    "preCondition": "equals (toLower (variables 'Environment')) 'production'",            "properties": {} },
    { "type": "Module/Flagged", "name": "Flagged", "preCondition": "contains (variables 'Flags') 'boards'",                              "properties": {} },
    { "type": "Module/Fallback","name": "Fallback","preCondition": "not (empty (coalesce (variables 'Owner') (variables 'Environment')))","properties": {} },
    { "type": "Module/Unset",   "name": "Unset",   "preCondition": "not (empty (variables 'Owner'))",                                    "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-conditions.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            $result.Status    | Should -Be 'Completed'
            $result.FailCount | Should -Be 0

            # mod/int: node 4 is even.
            @($result.Results | Where-Object { $_.InstanceName -eq 'Even' }).Status | Should -Be 'OK'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Odd'  }).Status | Should -Be 'SKIP'

            # toLower composed with the ordinal, case-SENSITIVE equals - the pairing that makes
            # toLower worth having.
            @($result.Results | Where-Object { $_.InstanceName -eq 'Prod' }).Status | Should -Be 'OK'

            # contains over an array variable, case-insensitively.
            @($result.Results | Where-Object { $_.InstanceName -eq 'Flagged' }).Status | Should -Be 'OK'

            # coalesce falling through an undefined variable, and empty() seeing that same
            # undefined variable as absent. The pair matters: 'Fallback' alone would pass even if
            # coalesce returned the wrong operand.
            @($result.Results | Where-Object { $_.InstanceName -eq 'Fallback' }).Status | Should -Be 'OK'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Unset'    }).Status | Should -Be 'SKIP'

            # A skipped resource must never have reached the engine.
            @($calls | Where-Object { $_.Name -eq 'Odd' }).Count | Should -Be 0

            # And an arithmetic accessor used in a PROPERTY resolved to a value, not to the
            # literal expression text.
            $evenTest = $calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Even' } | Select-Object -First 1
            $evenTest.Property.port | Should -Be '8004'
        }

        It "fails only the offending resource when an accessor is handed a value it cannot use" {

            # The failure mode that motivates throwing rather than resolving to 0: a typo in a
            # variable name must stop THIS resource and leave the rest of the file alone.
            $json = @'
{
  "parameters": {},
  "variables": { "NodeIndex": "4" },
  "resources": [
    { "type": "Module/Typo",  "name": "Typo",  "preCondition": "(mod (int (variables 'NodeIndx')) 2) -eq 0", "properties": {} },
    { "type": "Module/Sound", "name": "Sound", "preCondition": "(mod (int (variables 'NodeIndex')) 2) -eq 0", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-bad-operand.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls) -ErrorAction SilentlyContinue

            $result.FailCount | Should -Be 1
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).InstanceName | Should -Be 'Typo'
            # An undefined variable reaches int() as $null; the accessor throws rather than
            # treating it as 0. ('*[int]*' would be a wildcard character class, not the literal
            # accessor name, so the message body is what to match on.)
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).ErrorMessage | Should -BeLike '*Expected a number*'

            @($result.Results | Where-Object { $_.InstanceName -eq 'Sound' }).Status | Should -Be 'OK'
        }
    }

    Context "using() inside a preCondition" {

        It "reads the notifying resource's Get() output, in the order notify forces" {

            # Source is written second in the file and still runs first, because
            # Expand-NotifyDependsOn turned its notify into ordering for Sort-DependsOn. That
            # ordering is what makes the read meaningful: $script:resourceOutputs must already
            # hold Source's payload when Gated's preCondition is evaluated, which happens
            # EARLIER in the loop than property expansion does.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Gated",  "name": "Gated",  "preCondition": "(using 'Module/Source/Source').Enabled -eq 'yes'", "properties": {} },
    { "type": "Module/Source", "name": "Source", "properties": {}, "notify": [ "Module/Gated/Gated" ] }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-using-precondition.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-RecordingEngine -Calls $calls -GetOutputs @{ Source = [pscustomobject]@{ Enabled = 'yes' } }

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            $result.Status    | Should -Be 'Completed'
            $result.FailCount | Should -Be 0

            $testOrder = @($calls | Where-Object { $_.Method -eq 'Test' } | ForEach-Object { $_.Name })
            $testOrder | Should -Be @('Source', 'Gated')

            @($result.Results | Where-Object { $_.InstanceName -eq 'Gated' }).Status | Should -Be 'OK'
        }

        It "skips the resource when the notified value does not satisfy the preCondition" {

            # The other half of the previous test: a using() wired to nothing would satisfy the
            # passing case alone, since a $null read would also not throw.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Gated",  "name": "Gated",  "preCondition": "(using 'Module/Source/Source').Enabled -eq 'yes'", "properties": {} },
    { "type": "Module/Source", "name": "Source", "properties": {}, "notify": [ "Module/Gated/Gated" ] }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-using-precondition-false.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-RecordingEngine -Calls $calls -GetOutputs @{ Source = [pscustomobject]@{ Enabled = 'no' } }

            $result = Start-DscRunner -FilePath $config -EngineAction $engine

            @($result.Results | Where-Object { $_.InstanceName -eq 'Gated' }).Status       | Should -Be 'SKIP'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Gated' }).ErrorMessage | Should -BeLike '*skipped due to preCondition*'
            @($calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'Gated' }).Count | Should -Be 0
        }

        It "fails the reading resource when no notify declaration permits the read" {

            # The gate is the same one property expansion enforces - allow-listing using() for
            # preCondition did not widen it.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Source", "name": "Source", "properties": {} },
    { "type": "Module/Gated",  "name": "Gated",  "dependsOn": [ "Module/Source/Source" ], "preCondition": "(using 'Module/Source/Source').Enabled -eq 'yes'", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-using-precondition-ungated.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()
            $engine = New-RecordingEngine -Calls $calls -GetOutputs @{ Source = [pscustomobject]@{ Enabled = 'yes' } }

            $result = Start-DscRunner -FilePath $config -EngineAction $engine -ErrorAction SilentlyContinue

            $result.FailCount | Should -Be 1
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).InstanceName | Should -Be 'Gated'
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).ErrorMessage | Should -BeLike "*no 'notify' declaration*"

            @($result.Results | Where-Object { $_.InstanceName -eq 'Source' }).Status | Should -Be 'OK'
        }
    }

    Context "nodeName() and configurationFile()" {

        It "answer for the file being processed, in a preCondition and in a property" {

            # The node name is derived from the file name, so naming the file is what sets up
            # the assertion. The zero-argument spellings differ by position on purpose:
            # nodeName() in a condition (the normalizer rewrites it), bare $(nodeName) in a
            # property (where $( ) already supplies the grouping and the empty parens would be
            # a parse error).
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/OnNode",    "name": "OnNode",    "preCondition": "startsWith (nodeName()) 'fl-node'", "properties": { "who": "$(nodeName)", "file": "$(configurationFile)" } },
    { "type": "Module/OtherNode", "name": "OtherNode", "preCondition": "startsWith (nodeName()) 'some-other-node'", "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'fl-node-01.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls)

            $result.Status | Should -Be 'Completed'
            @($result.Results | Where-Object { $_.InstanceName -eq 'OnNode'    }).Status | Should -Be 'OK'
            @($result.Results | Where-Object { $_.InstanceName -eq 'OtherNode' }).Status | Should -Be 'SKIP'

            $onNodeTest = $calls | Where-Object { $_.Method -eq 'Test' -and $_.Name -eq 'OnNode' } | Select-Object -First 1
            $onNodeTest.Property.who  | Should -Be 'fl-node-01'
            $onNodeTest.Property.file | Should -Be $config

            # And the run context agrees with what the report recorded for the same resource.
            @($result.Results | Where-Object { $_.InstanceName -eq 'OnNode' }).NodeName | Should -Be 'fl-node-01'
        }

        It "stop answering once the file is finished, so nothing leaks into the next run" {

            # Without the clear in Start-DscRunner's finally block, a condition evaluated between
            # two runs - or a second file whose own run threw before the context was set - would
            # read the previous file's node name and silently decide for the wrong node.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [ { "type": "Module/Plain", "name": "Plain", "properties": {} } ]
}
'@
            $config = New-ConfigFile -Name 'fl-node-02.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls) | Out-Null

            nodeName          | Should -BeNullOrEmpty
            configurationFile | Should -BeNullOrEmpty
        }
    }

    Context "the documented stopProcessing() composition" {

        It "parses and stops the file, without failing the resource that requested it" {

            # `result().InDesiredState -or stopProcessing()` is the spelling the README and the
            # wiki lead with, and it used to be rejected outright: stopProcessing() was rewritten
            # to a bare `stopProcessing`, which PowerShell will not accept as an operand of -or.
            # The Message here never matches, so the -or must fall through to stopProcessing().
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/First",   "name": "First",   "properties": {} },
    { "type": "Module/Stopper", "name": "Stopper", "dependsOn": [ "Module/First/First" ],     "postCondition": "result().Message -eq 'never-matches' -or stopProcessing()", "properties": {} },
    { "type": "Module/Last",    "name": "Last",    "dependsOn": [ "Module/Stopper/Stopper" ], "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-stop.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls) -ErrorAction SilentlyContinue

            $result.Status    | Should -Be 'StoppedByRequest'
            $result.FailCount | Should -Be 0

            # Because stopProcessing() returns $true, the -or is satisfied and the resource is
            # NOT marked FAIL - the file stops cleanly.
            @($result.Results | Where-Object { $_.InstanceName -eq 'First'   }).Status | Should -Be 'OK'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Stopper' }).Status | Should -Be 'OK'

            @($result.Results | Where-Object { $_.InstanceName -eq 'Last' }).Status       | Should -Be 'SKIP'
            @($result.Results | Where-Object { $_.InstanceName -eq 'Last' }).ErrorMessage | Should -BeLike '*Stop-TaskProcessing*'
            @($calls | Where-Object { $_.Name -eq 'Last' }).Count | Should -Be 0
        }
    }

    Context "the allow-list still holds for a condition read from a file" {

        It "fails a resource whose preCondition calls something outside the allow-list" {

            # secret() is the specific omission worth pinning: a condition is recorded verbatim
            # in the report and in every SKIP message it produces, so a secret lookup must not be
            # expressible in one no matter how many other accessors were added.
            $json = @'
{
  "parameters": {},
  "variables": {},
  "resources": [
    { "type": "Module/Sneaky", "name": "Sneaky", "preCondition": "equals (secret 'ApiKey') 'x'", "properties": {} },
    { "type": "Module/Plain",  "name": "Plain",  "properties": {} }
  ]
}
'@
            $config = New-ConfigFile -Name 'function-language-allow-list.json' -Json $json
            $calls  = [System.Collections.Generic.List[object]]::new()

            $result = Start-DscRunner -FilePath $config -EngineAction (New-RecordingEngine -Calls $calls) -ErrorAction SilentlyContinue

            $result.FailCount | Should -Be 1
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).InstanceName | Should -Be 'Sneaky'
            @($result.Results | Where-Object { $_.Status -eq 'FAIL' }).ErrorMessage | Should -BeLike '*side-effect-free predicate*'

            @($calls | Where-Object { $_.Name -eq 'Sneaky' }).Count | Should -Be 0
            @($result.Results | Where-Object { $_.InstanceName -eq 'Plain' }).Status | Should -Be 'OK'
        }
    }
}
