<#
Security regression suite: the runner treats configuration content and engine output as
untrusted data.

A configuration, and the text a remote target returns, are not trusted to be inert. These tests
drive the real Start-DscRunner against JSON configurations (no powershell-yaml needed) with an
inline -EngineAction, and pin that:

  * a resource name or an engine/remote error cannot inject CI log commands (##vso[, ::) or
    extra log lines,
  * report cells cannot carry spreadsheet formulas, and a node file name containing wildcard
    characters still produces a report,
  * a malformed resource, a duplicate name or a scalar `target` is a recorded failure for that
    resource, never an aborted file or a silent local run,
  * a secret that an engine echoes back in an error never reaches the log, CSV or JSON report,
  * structural mistakes fail closed with a clear message.

Dummy values only.
#>
Describe "Security: the runner treats configuration and engine output as untrusted" -Tag Unit, Security {

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

        # An engine that reports every resource in the desired state, counting its calls.
        $script:okEngine = { param($Context) $Global:RunnerSecCalls++; return @{ InDesiredState = $true; Message = 'ok' } }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
        $Global:RunnerSecCalls = 0
        $Global:RunnerSecLog = [System.Collections.Generic.List[string]]::new()
        # Capture everything the runner writes to the log and error streams.
        Mock -CommandName Write-Information -MockWith { param($MessageData) $Global:RunnerSecLog.Add([string]$MessageData) }
        Mock -CommandName Write-Error -MockWith { param($Message) $Global:RunnerSecLog.Add([string]$Message) }
    }

    AfterAll {
        Remove-Variable -Name RunnerSecCalls, RunnerSecLog -Scope Global -ErrorAction SilentlyContinue
    }

    Context "log injection" {

        It "does not let a resource name start a new log line or carry a CI log command" {
            $json = @{ resources = @(@{ name = "web`n##vso[task.setvariable variable=PWNED]1"; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'inject-name.json' -Json $json

            $null = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:okEngine

            $lines = foreach ($entry in $Global:RunnerSecLog) { $entry -split "`r?`n" }
            @($lines | Where-Object { $_ -match '^\s*##vso\[' -or $_ -match '^::' }).Count | Should -Be 0
            ($Global:RunnerSecLog -join "`n") | Should -Match 'web'
        }

        It "does not let an engine error start a new log line or carry a CI log command" {
            $json = @{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'inject-error.json' -Json $json
            $engine = { param($Context) throw "boom`n##vso[task.complete result=Succeeded]`n::set-output name=x::y" }

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $engine

            $lines = foreach ($entry in $Global:RunnerSecLog) { $entry -split "`r?`n" }
            @($lines | Where-Object { $_ -match '^\s*##vso\[' -or $_ -match '^::' }).Count | Should -Be 0
            # The recorded message is a single line too, so it cannot split a CSV row or a log.
            $result.FailedResources[0].ErrorMessage | Should -Not -Match "[`r`n]"
            $result.FailedResources[0].ErrorMessage | Should -Match 'boom'
        }
    }

    Context "report files" {

        It "neutralises spreadsheet formulas in the CSV but keeps the raw text in the JSON report" -ForEach @(
            @{ Name = '=1+1' }, @{ Name = '+cmd' }, @{ Name = '-cmd' }, @{ Name = '@SUM(A1)' }
        ) {
            $json = @{ resources = @(@{ name = $Name; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'formula.json' -Json $json
            $rep = New-ReportDirectory

            $null = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:okEngine

            $row = Import-Csv -LiteralPath (Join-Path $rep 'formula.csv')
            $row.InstanceName | Should -Be ("'" + $Name)
            $report = Get-Content -LiteralPath (Join-Path $rep 'formula.report.json') -Raw | ConvertFrom-Json
            $report.Results[0].InstanceName | Should -Be $Name
        }

        It "leaves an ordinary name untouched in the CSV" {
            $json = @{ resources = @(@{ name = 'plain-name'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'plain.json' -Json $json
            $rep = New-ReportDirectory

            $null = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:okEngine

            (Import-Csv -LiteralPath (Join-Path $rep 'plain.csv')).InstanceName | Should -Be 'plain-name'
        }

        It "writes both reports for a node file whose name contains wildcard characters, even under ErrorActionPreference=Stop" {
            $json = @{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'node[1].json' -Json $json
            $rep = New-ReportDirectory

            $result = & {
                $ErrorActionPreference = 'Stop'
                Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:okEngine
            }

            $result.Status | Should -Be 'Completed'
            Test-Path -LiteralPath (Join-Path $rep 'node[1].csv') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $rep 'node[1].report.json') | Should -BeTrue
        }

        It "still returns the run result when the report cannot be written" {
            $json = @{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'noreport.json' -Json $json
            $missingDirectory = Join-Path $TestDrive 'does-not-exist'

            $result = & {
                $ErrorActionPreference = 'Stop'
                Start-DscRunner -FilePath $file -Mode Test -ReportPath $missingDirectory -EngineAction $script:okEngine
            }

            $result.Status | Should -Be 'Completed'
            $result.PassCount | Should -Be 1
        }
    }

    Context "secrets echoed by an engine" {

        It "keeps a plain-string secret out of the log, the CSV and the JSON report" {
            $secret = 'echoed-pw-4f9e2c'
            $json = @{ resources = @(@{ name = 'one'; type = 'Test/Res'; properties = @{ adminPassword = $secret; users = @(@{ login = 'a'; password = 'list-pw-71ab' }) } }) } | ConvertTo-Json -Depth 8
            $file = New-ConfigFile -Name 'echo.json' -Json $json
            $rep = New-ReportDirectory
            # An engine that, like dsc, echoes the offending input back in its error.
            $engine = { param($Context) throw "schema failure for input: $($Context.Property | ConvertTo-Json -Depth 6 -Compress)" }

            $result = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $engine

            $result.Status | Should -Be 'Completed'
            $result.FailCount | Should -Be 1
            $surfaces = @(
                ($Global:RunnerSecLog -join "`n"),
                (Get-Content -LiteralPath (Join-Path $rep 'echo.csv') -Raw),
                (Get-Content -LiteralPath (Join-Path $rep 'echo.report.json') -Raw),
                ($result | ConvertTo-Json -Depth 6)
            )
            foreach ($surface in $surfaces) {
                $surface | Should -Not -Match ([regex]::Escape($secret))
                $surface | Should -Not -Match 'list-pw-71ab'
            }
            $surfaces[2] | Should -Match 'schema failure'
        }
    }

    Context "malformed resources" {

        It "records a failure for a resource with a bad type and still runs the resources around it" -ForEach @(
            @{ Label = 'no slash';    Type = 'NoSlash' }
            @{ Label = 'null';        Type = $null }
            @{ Label = 'a number';    Type = 12345 }
            @{ Label = 'an array';    Type = @('X/Y', 'Z/W') }
        ) {
            $json = @{ resources = @(
                @{ name = 'first';  type = 'Test/Res'; properties = @{ a = 1 } },
                @{ name = 'broken'; type = $Type;      properties = @{ a = 1 } },
                @{ name = 'last';   type = 'Test/Res'; properties = @{ a = 1 } }
            ) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'bad-type.json' -Json $json

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:okEngine

            $result.Status | Should -Not -Be 'AbortedByException'
            $result.PassCount | Should -Be 2
            $result.FailCount | Should -Be 1
        }

        It "does not abort the file when two resources share a name across different types" {
            $json = @{ resources = @(
                @{ name = 'same'; type = 'Test/One'; properties = @{ a = 1 } },
                @{ name = 'same'; type = 'Test/Two'; properties = @{ a = 1 } },
                @{ name = 'after'; type = 'Test/Res'; properties = @{ a = 1 } }
            ) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'dup-name.json' -Json $json

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:okEngine

            $result.Status | Should -Be 'Completed'
            $result.TotalResources | Should -Be 3
            $result.PassCount | Should -Be 3
        }

        It "fails a resource whose target is a scalar instead of silently running it locally" {
            $json = @{ resources = @(@{ name = 'remote'; type = 'Test/Res'; target = 'WinRM'; properties = @{ a = 1 } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'bad-target.json' -Json $json

            $result = Start-DscRunner -FilePath $file -Mode Set -EngineAction $script:okEngine

            $result.FailCount | Should -Be 1
            $result.FailedResources[0].ErrorMessage | Should -Match "'target'"
            $Global:RunnerSecCalls | Should -Be 0
        }
    }

    Context "structural mistakes fail closed, by name" {

        It "rejects a configuration with no resources section" {
            $file = New-ConfigFile -Name 'no-resources.json' -Json '{ "variables": { "a": "b" } }'
            { Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:okEngine } | Should -Throw "*no 'resources' section*"
            $Global:RunnerSecCalls | Should -Be 0
        }

        It "rejects a variables section that is not a mapping" {
            $file = New-ConfigFile -Name 'vars-list.json' -Json '{ "variables": ["a", "b"], "resources": [ { "name": "one", "type": "Test/Res" } ] }'
            { Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:okEngine } | Should -Throw "*'variables' section*must be a mapping*"
        }
    }
}
