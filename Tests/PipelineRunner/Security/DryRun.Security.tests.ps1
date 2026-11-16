<#
Security regression suite: a dry run (-Mode DryRun) validates a configuration and produces its
resultant configuration (RSOP) without doing anything.

A dry run is meant for a pipeline stage that runs before the real one, often on a pull request
and without credentials. So it must be safe to run on a configuration nobody has reviewed yet:

  * it never calls an engine, a Target action or a Credential action, and never runs an
    execution script,
  * it still catches what can be caught statically: unsafe or malformed expressions, undeclared
    parameters, unknown target/credential/engine actions, a malformed target, scripts that do
    not parse,
  * an expression that reads run-time state (reference(), using(), result()) is validated and
    reported as deferred, not failed and not evaluated,
  * the resultant configuration it writes and returns has secrets redacted,
  * a Test or Set run is unchanged: it returns no RSOP.

Dummy values only.
#>
Describe "Security: a dry run validates and reports without doing anything" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        . (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        . (Get-FunctionPath 'Resolve-PipelineParameter.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-scope state the runner reads and resets (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

        Mock -CommandName Get-Module -MockWith { return @{ moduleBase = $Global:RepositoryRoot } }
        Mock -CommandName Write-Host

        Mock -CommandName Invoke-CustomTask -MockWith {
            param([Parameter(Mandatory = $true)] [Object[]]$Tasks, [Parameter(Mandatory = $true)] [String]$CustomTaskName)
            if ($CustomTaskName -eq 'Sort-DependsOn') { return (& $script:SortDependsOnPath -PipelineResources $Tasks) }
            return $Tasks
        }
        Mock -CommandName Invoke-PreParseRules -MockWith { param([Object[]]$Tasks, [hashtable]$Settings) }
        Mock -CommandName Invoke-FormatTasks -MockWith { param([Object[]]$Tasks) return $Tasks }

        function New-ConfigFile {
            param([string]$Name, [string]$Json)
            $path = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
            return $path
        }

        function New-ReportDirectory {
            $dir = Join-Path $TestDrive ("rep-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $dir
            return $dir
        }

        # The function-language accessors the expressions below call.
        foreach ($accessor in 'variables', 'parameters', 'reference', 'using', 'equals', 'not', 'result') {
            . (Get-FunctionPath "$accessor.ps1").FullName
        }

        # An engine that records that it was called. A dry run must never reach it.
        $script:engine = { param($Context) $Global:DryRunEngineCalls++; return @{ InDesiredState = $true; Message = 'ok'; Raw = @{} } }

        function Invoke-DryRun {
            param([object[]]$Resources, [hashtable]$Extra = @{}, [string]$Name = 'dry.json', [string]$ReportPath, [hashtable]$Settings = @{})
            $document = @{ resources = $Resources } + $Extra
            $file = New-ConfigFile -Name $Name -Json ($document | ConvertTo-Json -Depth 10)
            $arguments = @{ FilePath = $file; Mode = 'DryRun'; EngineAction = $script:engine; RunnerSettings = $Settings }
            if ($ReportPath) { $arguments.ReportPath = $ReportPath }
            return (Start-DscRunner @arguments)
        }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
        $Global:DryRunEngineCalls = 0
        $Global:DryRunActionCalls = 0
        $Global:DryRunScriptRan = $false
        $Global:DryRunLog = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Information -MockWith { param($MessageData) $Global:DryRunLog.Add([string]$MessageData) }
        Mock -CommandName Write-Error -MockWith { param($Message) $Global:DryRunLog.Add([string]$Message) }
        Mock -CommandName Invoke-Action -ParameterFilter { $Hook -in 'Target', 'Credential' } -MockWith { $Global:DryRunActionCalls++ }
    }

    AfterAll {
        Remove-Variable -Name DryRunEngineCalls, DryRunActionCalls, DryRunScriptRan, DryRunLog -Scope Global -ErrorAction SilentlyContinue
    }

    Context "it does nothing" {

        It "never calls the engine, a Target action or a Credential action, and never runs an execution script" {
            $result = Invoke-DryRun -Settings @{ AllowExecutionScripts = $true } -Resources @(
                @{ name = 'local'; type = 'Test/Res'; properties = @{ a = 1 } }
                @{ name = 'remote'; type = 'Test/Res'; properties = @{ a = 2 }
                    target = @{ action = 'WinRM'; computerName = 'web-01'; credential = @{ UserNameVariable = 'U'; PasswordVariable = 'P' } }
                    resourceCredential = @{ action = 'Environment'; UserNameVariable = 'U'; PasswordVariable = 'P' }
                    preExecutionScript = '$Global:DryRunScriptRan = $true'
                    postExecutionScript = '$Global:DryRunScriptRan = $true' }
            )

            $result.Status | Should -Be 'Completed'
            $result.PassCount | Should -Be 2
            $Global:DryRunEngineCalls | Should -Be 0
            $Global:DryRunActionCalls | Should -Be 0
            $Global:DryRunScriptRan | Should -BeFalse
            $remote = $result.Rsop.Resources | Where-Object { $_.Name -eq 'remote' }
            $remote.Target | Should -Be 'WinRM'
            $remote.ComputerName | Should -Be 'web-01'
            $remote.CredentialActions | Should -Be @('Environment')
            $remote.HasExecutionScripts | Should -BeTrue
        }

        It "leaves a Test run unchanged: the engine runs and no RSOP is returned" {
            $file = New-ConfigFile -Name 'test-mode.json' -Json (@{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6)

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine

            $Global:DryRunEngineCalls | Should -BeGreaterThan 0
            $result.PSObject.Properties.Name | Should -Not -Contain 'Rsop'
        }
    }

    Context "the resultant configuration" {

        It "resolves parameters and variables, and lists resources in dependency order" {
            $result = Invoke-DryRun -Extra @{ parameters = @{ Port = @{ defaultValue = 8443 } }; variables = @{ Site = 'intranet' } } -Resources @(
                @{ name = 'second'; type = 'Test/Res'; dependsOn = @('Test/Res/first'); properties = @{ Port = '<params=Port>'; Url = 'https://$(variables ''Site'').example' } }
                @{ name = 'first'; type = 'Test/Res'; properties = @{ a = 1 }; notify = @('Test/Res/second') }
            )

            $result.Rsop.SchemaVersion | Should -Be '1.0'
            @($result.Rsop.Resources | ForEach-Object { $_.Name }) | Should -Be @('first', 'second')
            $second = $result.Rsop.Resources[1]
            $second.Properties.Port | Should -Be 8443
            $second.Properties.Url | Should -Be 'https://intranet.example'
            $second.DependsOn | Should -Contain 'Test/Res/first'
            $second.WouldRun | Should -BeTrue
            $result.Rsop.Variables.Site | Should -Be 'intranet'
        }

        It "reports a resource whose preCondition is false as one that would be skipped" {
            $result = Invoke-DryRun -Extra @{ variables = @{ Feature = 'off' } } -Resources @(
                @{ name = 'gated'; type = 'Test/Res'; preCondition = "equals (variables 'Feature') 'on'"; properties = @{ a = 1 } }
            )

            $result.SkipCount | Should -Be 1
            $result.Rsop.Resources[0].WouldRun | Should -BeFalse
            $result.Rsop.Resources[0].PreCondition | Should -Be 'False'
        }

        It "defers, without failing or evaluating, an expression that reads run-time state: <Label>" -ForEach @(
            @{ Label = 'preCondition with reference()'; Resource = @{ name = 'r'; type = 'Test/Res'; preCondition = "equals (reference 'other').State 'ok'"; properties = @{ a = 1 } }; Expected = 'preCondition' }
            @{ Label = 'property with reference()';     Resource = @{ name = 'r'; type = 'Test/Res'; properties = @{ Id = '$((reference ''other'').Id)' } }; Expected = 'properties' }
            @{ Label = 'property with using()';         Resource = @{ name = 'r'; type = 'Test/Res'; properties = @{ Id = '$((using ''Test/Res/other'').Id)' } }; Expected = 'properties' }
            @{ Label = 'postCondition with result()';   Resource = @{ name = 'r'; type = 'Test/Res'; postCondition = 'result().InDesiredState'; properties = @{ a = 1 } }; Expected = 'postCondition' }
        ) {
            $result = Invoke-DryRun -Resources @($Resource)

            $result.FailCount | Should -Be 0
            $result.Rsop.Resources[0].Deferred | Should -Contain $Expected
            $result.Rsop.Resources[0].Status | Should -Be 'OK'
        }

        It "writes the RSOP next to the report files, and hands it to reporters" {
            $rep = New-ReportDirectory
            $file = New-ConfigFile -Name 'files.json' -Json (@{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6)
            $Global:DryRunDocument = $null

            $null = Start-DscRunner -FilePath $file -Mode DryRun -ReportPath $rep -EngineAction $script:engine -ReportAction { param($Context) $Global:DryRunDocument = $Context.Document }

            (Get-ChildItem -LiteralPath $rep).Name | Sort-Object | Should -Be @('files.csv', 'files.report.json', 'files.rsop.json')
            (Get-Content -LiteralPath (Join-Path $rep 'files.rsop.json') -Raw | ConvertFrom-Json).Resources[0].Name | Should -Be 'one'
            $Global:DryRunDocument.Mode | Should -Be 'DryRun'
            $Global:DryRunDocument.Rsop.Resources[0].Name | Should -Be 'one'
            Remove-Variable -Name DryRunDocument -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context "what it catches" {

        It "fails a resource for <Label>" -ForEach @(
            @{ Label = 'a command in a property expression';        Resource = @{ name = 'r'; type = 'Test/Res'; properties = @{ x = '$(Remove-Item /tmp/x)' } };                                           Expected = 'properties' }
            @{ Label = 'a command hidden beside a reference()';     Resource = @{ name = 'r'; type = 'Test/Res'; properties = @{ x = '$((reference ''o'').Id)'; y = '$(Remove-Item /tmp/x)' } };           Expected = 'properties' }
            @{ Label = 'an undeclared parameter';                   Resource = @{ name = 'r'; type = 'Test/Res'; properties = @{ x = '<params=NotDeclared>' } };                                            Expected = 'properties' }
            @{ Label = 'a command in a preCondition';               Resource = @{ name = 'r'; type = 'Test/Res'; preCondition = 'Remove-Item /tmp/x'; properties = @{ a = 1 } };                             Expected = 'preCondition' }
            @{ Label = 'a command in a postCondition';              Resource = @{ name = 'r'; type = 'Test/Res'; postCondition = 'Remove-Item /tmp/x'; properties = @{ a = 1 } };                            Expected = 'postCondition' }
            @{ Label = 'a scalar target';                           Resource = @{ name = 'r'; type = 'Test/Res'; target = 'WinRM'; properties = @{ a = 1 } };                                                Expected = 'target' }
            @{ Label = 'a target action that does not exist';       Resource = @{ name = 'r'; type = 'Test/Res'; target = @{ action = 'Telnet'; computerName = 'h' }; properties = @{ a = 1 } };             Expected = 'target' }
            @{ Label = 'a target action that is a path';            Resource = @{ name = 'r'; type = 'Test/Res'; target = @{ action = '../Engine/DscV2'; computerName = 'h' }; properties = @{ a = 1 } };    Expected = 'target' }
            @{ Label = 'a credential action that does not exist';   Resource = @{ name = 'r'; type = 'Test/Res'; resourceCredential = @{ action = 'Nowhere'; name = 'x' }; properties = @{ a = 1 } };        Expected = 'credential' }
            @{ Label = 'an execution script that does not parse';   Resource = @{ name = 'r'; type = 'Test/Res'; postExecutionScript = 'if ($x) {'; properties = @{ a = 1 } };                               Expected = 'postExecutionScript' }
        ) {
            $result = Invoke-DryRun -Settings @{ AllowExecutionScripts = $true } -Resources @($Resource)

            $result.FailCount | Should -Be 1
            $result.Rsop.Resources[0].WouldRun | Should -BeFalse
            ($result.Rsop.Resources[0].Problems -join ' ') | Should -Match $Expected
            $result.FailedResources[0].ErrorMessage | Should -Match $Expected
            $Global:DryRunEngineCalls | Should -Be 0
        }

        It "reports every problem with a resource, and still checks the resources after it" {
            $result = Invoke-DryRun -Resources @(
                @{ name = 'bad'; type = 'Test/Res'; target = 'WinRM'; preCondition = 'Remove-Item x'; properties = @{ x = '<params=Missing>' } }
                @{ name = 'good'; type = 'Test/Res'; properties = @{ a = 1 } }
            )

            @($result.Rsop.Resources[0].Problems).Count | Should -Be 3
            $result.PassCount | Should -Be 1
            $result.FailCount | Should -Be 1
        }

        It "records a malformed resource as a failure" {
            $result = Invoke-DryRun -Resources @(@{ name = 'x'; type = 'NoSlash'; properties = @{ a = 1 } })

            $result.FailCount | Should -Be 1
        }

        It "stops with a clear error when the engine does not exist" {
            $file = New-ConfigFile -Name 'engine.json' -Json (@{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6)

            $result = Start-DscRunner -FilePath $file -Mode DryRun -Engine 'NoSuchEngine'

            $result.Status | Should -Be 'AbortedByException'
            $result.ErrorMessage | Should -Match "engine 'NoSuchEngine' does not exist"
        }
    }

    Context "secrets" {

        It "keeps secrets out of the RSOP file, the returned RSOP and the log" {
            $rep = New-ReportDirectory
            $result = Invoke-DryRun -ReportPath $rep -Name 'secrets.json' -Extra @{ variables = @{ ApiToken = 'var-token-3c9d'; Region = 'west' } } -Resources @(
                @{ name = 'one'; type = 'Test/Res'; properties = @{
                        adminPassword = 'prop-pw-11aa'
                        users         = @(@{ login = 'a'; password = 'list-pw-22bb' }, @{ login = 'b'; password = 'list-pw-33cc' })
                        Banner        = 'the password is prop-pw-11aa'
                        Region        = '$(variables ''Region'')' } }
            )

            $surfaces = @(
                (Get-Content -LiteralPath (Join-Path $rep 'secrets.rsop.json') -Raw),
                ($result.Rsop | ConvertTo-Json -Depth 20),
                ($Global:DryRunLog -join "`n"),
                (Get-Content -LiteralPath (Join-Path $rep 'secrets.report.json') -Raw)
            )
            foreach ($surface in $surfaces) {
                foreach ($secret in 'prop-pw-11aa', 'list-pw-22bb', 'list-pw-33cc', 'var-token-3c9d') { $surface | Should -Not -Match $secret }
            }
            $properties = $result.Rsop.Resources[0].Properties
            $properties.adminPassword | Should -Be '[REDACTED]'
            $properties.Banner | Should -Be 'the password is [REDACTED]'
            $properties.Region | Should -Be 'west'
            $result.Rsop.Variables.ApiToken | Should -Be '[REDACTED]'
            $result.Rsop.Variables.Region | Should -Be 'west'
        }
    }
}
