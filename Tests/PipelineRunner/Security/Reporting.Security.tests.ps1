<#
Security regression suite: reports, captured state and reporters (#85).

A report can leave the machine: as files, or sent to a third party by a reporter. With state
capture on it also carries each resource's desired properties and its Get() output, and Get()
output can hold secrets the configuration never declared. These tests drive the real
Start-DscRunner (JSON configurations, an inline -EngineAction) and the real Webhook action, and
pin that:

  * the CSV and JSON files keep their existing shape, and no state is captured unless asked for,
  * captured state is redacted: credentials, sensitive-named values (also nested in lists and in
    Get() output), and any known secret echoed inside another string,
  * captured state is bounded,
  * a reporter receives the same redacted document, and a reporter that fails cannot change the
    run's result or stop the other reporters,
  * the Webhook reporter is https only, refuses credentials in the URL, sends the token in a
    header, does not follow redirects, and never puts the token, the URL path or a response body
    in an error.

Dummy values only.
#>
Describe "Security: reports, captured state and reporters" -Tag Unit, Security {

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

        $script:webhook = Join-Path $Global:RepositoryRoot 'Actions/Report/Webhook.ps1'

        # Test reports drift for 'drifted' resources; Get returns state that carries secrets the
        # configuration never declared.
        $script:engine = {
            param($Context)
            if ($Context.Method -eq 'Get') {
                return @{ InDesiredState = $true; Raw = @{
                        Path             = 'C:\\app'
                        ConnectionString = 'Server=db;Password=get-only-secret-9c1;'
                        Accounts         = @(@{ Login = 'svc'; Password = 'nested-get-pw-55' })
                        Note             = "echo of $($Context.Property.adminPassword)"
                    }
                }
            }
            return @{ InDesiredState = ($Context.Property.kind -ne 'drifted'); Message = 'drift' }
        }

        function New-TwoResourceConfig {
            param([string]$Name = 'state.json')
            $json = @{ resources = @(
                    @{ name = 'steady';  type = 'Test/Res'; properties = @{ kind = 'steady';  adminPassword = 'declared-pw-aa11' } }
                    @{ name = 'changed'; type = 'Test/Res'; properties = @{ kind = 'drifted'; adminPassword = 'declared-pw-bb22'; users = @(@{ login = 'a'; password = 'list-pw-cc33' }) } }
                ) } | ConvertTo-Json -Depth 8
            return (New-ConfigFile -Name $Name -Json $json)
        }

        $script:allSecrets = 'declared-pw-aa11', 'declared-pw-bb22', 'list-pw-cc33', 'get-only-secret-9c1', 'nested-get-pw-55'
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
        $Global:ReportSecLog = [System.Collections.Generic.List[string]]::new()
        $Global:ReportSecDocuments = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Write-Information -MockWith { param($MessageData) $Global:ReportSecLog.Add([string]$MessageData) }
        Mock -CommandName Write-Error -MockWith { param($Message) $Global:ReportSecLog.Add([string]$Message) }
    }

    AfterAll {
        Remove-Variable -Name ReportSecLog, ReportSecDocuments, ReportSecRequests -Scope Global -ErrorAction SilentlyContinue
    }

    Context "state capture is opt-in and the existing files are unchanged" {

        It "writes only the CSV and JSON report, with their existing fields, by default" {
            $file = New-TwoResourceConfig
            $rep = New-ReportDirectory

            $null = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:engine

            (Get-ChildItem -LiteralPath $rep).Name | Sort-Object | Should -Be @('state.csv', 'state.report.json')
            $report = Get-Content -LiteralPath (Join-Path $rep 'state.report.json') -Raw | ConvertFrom-Json
            $report.PSObject.Properties.Name | Should -Be @('ConfigurationFile', 'Status', 'TotalResources', 'PassCount', 'FailCount', 'SkipCount', 'DurationSeconds', 'ErrorMessage', 'Results')
            $report.Results[0].PSObject.Properties.Name | Should -Be @('NodeName', 'ResourceType', 'InstanceName', 'ConfigurationFile', 'Status', 'DurationMs', 'ErrorMessage', 'Target', 'ComputerName', 'RebootRequired')
            (Get-Content -LiteralPath (Join-Path $rep 'state.csv') -TotalCount 1) | Should -Be '"NodeName","ResourceType","InstanceName","ConfigurationFile","Status","DurationMs","ErrorMessage","Target","ComputerName","RebootRequired"'
        }

        It "captures no state in the document a reporter receives by default" {
            $file = New-TwoResourceConfig
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $null = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction $reporter

            $document = $Global:ReportSecDocuments[0]
            $document.SchemaVersion | Should -Be '1.0'
            $document.StateCapture | Should -Be 'None'
            @($document.Results | Where-Object { $null -ne $_.State }).Count | Should -Be 0
            ($document | ConvertTo-Json -Depth 20) | Should -Not -Match 'get-only-secret'
        }

        It "rejects an unknown State setting instead of silently capturing nothing" {
            $file = New-TwoResourceConfig
            { Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -RunnerSettings @{ Report = @{ State = 'Everything' } } } |
                Should -Throw '*expected None, Drift or Full*'
        }
    }

    Context "captured state is redacted and bounded" {

        It "captures state only for resources that drifted when State is Drift" {
            $file = New-TwoResourceConfig
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $null = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction $reporter -RunnerSettings @{ Report = @{ State = 'Drift' } }

            $results = $Global:ReportSecDocuments[0].Results
            ($results | Where-Object InstanceName -eq 'steady').State | Should -BeNullOrEmpty
            ($results | Where-Object InstanceName -eq 'changed').State | Should -Not -BeNullOrEmpty
            ($results | Where-Object InstanceName -eq 'changed').Drifted | Should -BeTrue
            ($results | Where-Object InstanceName -eq 'steady').Drifted | Should -BeFalse
        }

        It "keeps every secret out of the state file, the reporter's document, the log and the result when State is Full" {
            $file = New-TwoResourceConfig
            $rep = New-ReportDirectory
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $result = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:engine -ReportAction $reporter -RunnerSettings @{ Report = @{ State = 'Full' } }

            $stateFile = Get-Content -LiteralPath (Join-Path $rep 'state.state.json') -Raw
            $surfaces = @(
                $stateFile,
                ($Global:ReportSecDocuments[0] | ConvertTo-Json -Depth 20),
                (Get-Content -LiteralPath (Join-Path $rep 'state.report.json') -Raw),
                (Get-Content -LiteralPath (Join-Path $rep 'state.csv') -Raw),
                ($Global:ReportSecLog -join "`n"),
                ($result | ConvertTo-Json -Depth 8)
            )
            foreach ($surface in $surfaces) {
                foreach ($secret in $script:allSecrets) { $surface | Should -Not -Match ([regex]::Escape($secret)) }
            }

            # ...while the non-secret state is really there.
            $state = ($stateFile | ConvertFrom-Json).Results | Where-Object InstanceName -eq 'changed' | ForEach-Object State
            $state.Desired.kind | Should -Be 'drifted'
            $state.Desired.adminPassword | Should -Be '[REDACTED]'
            $state.Desired.users[0].login | Should -Be 'a'
            $state.Desired.users[0].password | Should -Be '[REDACTED]'
            $state.Actual.Path | Should -Be 'C:\\app'
            $state.Actual.ConnectionString | Should -Be '[REDACTED]'
            $state.Actual.Accounts[0].Login | Should -Be 'svc'
            $state.Actual.Accounts[0].Password | Should -Be '[REDACTED]'
            $state.Actual.Note | Should -Be 'echo of [REDACTED]'
        }

        It "replaces state that is too large with a marker instead of reporting it" {
            $json = @{ resources = @(@{ name = 'big'; type = 'Test/Res'; properties = @{ kind = 'drifted' } }) } | ConvertTo-Json -Depth 6
            $file = New-ConfigFile -Name 'big.json' -Json $json
            $engine = {
                param($Context)
                if ($Context.Method -eq 'Get') { return @{ InDesiredState = $true; Raw = @{ Items = @(1..150 | ForEach-Object { 'x' * 4000 }) } } }
                return @{ InDesiredState = $false; Message = 'drift' }
            }
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $null = Start-DscRunner -FilePath $file -Mode Test -EngineAction $engine -ReportAction $reporter -RunnerSettings @{ Report = @{ State = 'Full' } }

            $state = $Global:ReportSecDocuments[0].Results[0].State
            $state.Truncated | Should -BeTrue
            ($Global:ReportSecDocuments[0] | ConvertTo-Json -Depth 20).Length | Should -BeLessThan 20000
        }
    }

    Context "reporters cannot change or lose the result" {

        It "returns the same result when a reporter throws, and reports the failure" {
            $file = New-TwoResourceConfig
            $failing = { param($Context) throw "reporter exploded`n##vso[task.complete result=Succeeded]" }

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction $failing

            $result.Status | Should -Be 'Completed'
            $result.FailCount | Should -Be 1
            $result.PassCount | Should -Be 1
            ($Global:ReportSecLog -join "`n") | Should -Match "Reporter '\(inline\)' failed"
            $lines = foreach ($entry in $Global:ReportSecLog) { $entry -split "`r?`n" }
            @($lines | Where-Object { $_ -match '^\s*##vso\[' }).Count | Should -Be 0
        }

        It "still runs the remaining reporters, and still writes the files, when a named reporter is missing" {
            $file = New-TwoResourceConfig
            $rep = New-ReportDirectory
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $result = Start-DscRunner -FilePath $file -Mode Test -ReportPath $rep -EngineAction $script:engine -ReportAction $reporter -RunnerSettings @{ Report = @{ Reporters = @('NoSuchReporter') } }

            $result.Status | Should -Be 'Completed'
            $Global:ReportSecDocuments.Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $rep 'state.report.json') | Should -BeTrue
            ($Global:ReportSecLog -join "`n") | Should -Match "Reporter 'NoSuchReporter' failed"
        }

        It "does not let a reporter name select a script outside Actions/Report" {
            $file = New-TwoResourceConfig

            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -RunnerSettings @{ Report = @{ Reporters = @('../Engine/DscV2') } }

            $result.Status | Should -Be 'Completed'
            ($Global:ReportSecLog -join "`n") | Should -Match 'is not valid'
        }
    }

    Context "the Webhook reporter" {

        BeforeEach {
            $Global:ReportSecRequests = [System.Collections.Generic.List[hashtable]]::new()
            $Global:ReportSecResponses = [System.Collections.Generic.Queue[object]]::new()
            Mock -CommandName Start-Sleep
            Mock -CommandName Invoke-WebRequest -MockWith {
                $Global:ReportSecRequests.Add(@{ Uri = [string]$Uri; Method = [string]$Method; Body = $Body; Headers = $Headers; MaximumRedirection = $MaximumRedirection })
                $next = if ($Global:ReportSecResponses.Count -gt 0) { $Global:ReportSecResponses.Dequeue() } else { 200 }
                if ($next -is [string]) { throw $next }
                return [pscustomobject]@{ StatusCode = $next; Content = 'server said: token=echoed-by-server' }
            }
            Mock -CommandName Invoke-Action -ParameterFilter { $Hook -eq 'Credential' } -MockWith {
                return [pscredential]::new('reporter', (ConvertTo-SecureString 'webhook-token-7d2f' -AsPlainText -Force))
            }
            $script:document = [ordered]@{ SchemaVersion = '1.0'; NodeName = 'n'; Results = @() }
        }

        It "refuses the endpoint <Uri> before sending anything" -ForEach @(
            @{ Uri = 'http://reports.example.com/dsc';              Expected = '*not permitted*' }
            @{ Uri = 'ftp://reports.example.com/dsc';               Expected = '*not permitted*' }
            @{ Uri = '/relative/path';                              Expected = '*https*' }
            @{ Uri = '';                                            Expected = '*absolute https URL*' }
            @{ Uri = 'https://user:pw-in-url@reports.example.com/'; Expected = '*must not carry a user name or password*' }
        ) {
            { & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = $Uri } } } | Should -Throw $Expected

            $Global:ReportSecRequests.Count | Should -Be 0
        }

        It "posts the document as JSON, with the token in a header and not in the URL" {
            $outcome = & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/dsc'; Credential = @{ UserNameVariable = 'U'; PasswordVariable = 'P' } } }

            $outcome.StatusCode | Should -Be 200
            $request = $Global:ReportSecRequests[0]
            $request.Method | Should -Be 'Post'
            $request.Uri | Should -Be 'https://reports.example.com/dsc'
            $request.Uri | Should -Not -Match 'webhook-token'
            $request.Headers['Authorization'] | Should -Be 'Bearer webhook-token-7d2f'
            ($request.Body | ConvertFrom-Json).SchemaVersion | Should -Be '1.0'
        }

        It "does not follow redirects, so the token is never sent to another host" {
            $null = & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/dsc' } }

            $Global:ReportSecRequests[0].MaximumRedirection | Should -Be 0
        }

        It "treats a redirect as a failure rather than success" {
            $Global:ReportSecResponses.Enqueue(302)

            { & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/dsc' } } } | Should -Throw '*HTTP 302*'
            $Global:ReportSecRequests.Count | Should -Be 1
        }

        It "retries a server error and then succeeds" {
            $Global:ReportSecResponses.Enqueue(503); $Global:ReportSecResponses.Enqueue('connection reset'); $Global:ReportSecResponses.Enqueue(200)

            $outcome = & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/dsc' } }

            $outcome.Attempts | Should -Be 3
        }

        It "names only the host and the status when it gives up: no token, no path, no response body" {
            1..3 | ForEach-Object { $Global:ReportSecResponses.Enqueue(500) }
            $thrown = $null

            try { & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/private/path?sig=query-secret-1'; Credential = @{ UserNameVariable = 'U'; PasswordVariable = 'P' } } } }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match "reports\.example\.com"
            $thrown | Should -Match 'HTTP 500'
            $thrown | Should -Match '3 attempt'
            $thrown | Should -Not -Match 'webhook-token'
            $thrown | Should -Not -Match 'private/path'
            $thrown | Should -Not -Match 'query-secret'
            $thrown | Should -Not -Match 'echoed-by-server'
        }

        It "does not include the underlying error text when the request itself fails" {
            1..3 | ForEach-Object { $Global:ReportSecResponses.Enqueue('could not reach https://reports.example.com/private/path?sig=query-secret-1') }
            $thrown = $null

            try { & $script:webhook -Context @{ Document = $script:document; Settings = @{ Uri = 'https://reports.example.com/private/path?sig=query-secret-1' } } }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match 'the request failed'
            $thrown | Should -Not -Match 'query-secret'
            $thrown | Should -Not -Match 'private/path'
        }
    }

    Context "a failing reporter and Report.OnError" {

        It "leaves the result alone by default (Warn)" {
            $file = New-TwoResourceConfig
            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction { throw 'nope' }

            $result.Status | Should -Be 'Completed'
        }

        It "marks an otherwise-complete file ReportFailed when OnError is Fail, without altering resource results" {
            $file = New-TwoResourceConfig
            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction { throw 'nope' } -RunnerSettings @{ Report = @{ OnError = 'Fail' } }

            $result.Status | Should -Be 'ReportFailed'
            $result.ErrorMessage | Should -Match "Reporter '\(inline\)' failed"
            $result.PassCount | Should -Be 1
            $result.FailCount | Should -Be 1
        }

        It "does not mark the file when every reporter succeeds" {
            $file = New-TwoResourceConfig
            $result = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction { } -RunnerSettings @{ Report = @{ OnError = 'Fail' } }

            $result.Status | Should -Be 'Completed'
        }

        It "rejects an unknown OnError setting" {
            $file = New-TwoResourceConfig
            { Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -RunnerSettings @{ Report = @{ OnError = 'Ignore' } } } |
                Should -Throw '*expected Warn or Fail*'
        }

        It "makes the run summary Failed when a file is ReportFailed" {
            . (Get-FunctionPath 'Merge-DscRunnerResult.ps1').FullName
            $clean = [pscustomobject]@{ Status = 'Completed'; TotalResources = 1; PassCount = 1; FailCount = 0; SkipCount = 0; DurationSeconds = 0; FailedResources = @() }
            $undelivered = [pscustomobject]@{ Status = 'ReportFailed'; TotalResources = 1; PassCount = 1; FailCount = 0; SkipCount = 0; DurationSeconds = 0; FailedResources = @() }

            (Merge-DscRunnerResult -Result @($clean, $undelivered)).Status | Should -Be 'Failed'
            (Merge-DscRunnerResult -Result @($clean)).Status | Should -Be 'Completed'
        }
    }

    Context "Get() output is released when the file is finished" {

        It "does not keep resource state in memory after the run returns" {
            $file = New-TwoResourceConfig
            $seen = @{ Count = 0 }
            $reporter = { param($Context) $Global:ReportSecDocuments.Add($Context.Document) }

            $null = Start-DscRunner -FilePath $file -Mode Test -EngineAction $script:engine -ReportAction $reporter -RunnerSettings @{ Report = @{ State = 'Full' } }

            # The state was available to the report...
            ($Global:ReportSecDocuments[0].Results | Where-Object InstanceName -eq 'changed').State.Actual.Path | Should -Not -BeNullOrEmpty
            # ...and is gone afterwards.
            $references.Count | Should -Be 0
            $script:resourceOutputs.Count | Should -Be 0
        }
    }

    Context "the JUnit and Summary reporters treat names and messages as untrusted text" {

        BeforeAll {
            $script:junit = Join-Path $Global:RepositoryRoot 'Actions/Report/JUnit.ps1'
            $script:summary = Join-Path $Global:RepositoryRoot 'Actions/Report/Summary.ps1'

            function New-HostileDocument {
                param([string]$NodeName = 'node1')
                return [ordered]@{
                    SchemaVersion = '1.0'; NodeName = $NodeName; Mode = 'Test'; Engine = 'DscV2'; Status = 'Completed'
                    TotalResources = 3; PassCount = 1; FailCount = 1; SkipCount = 1; DurationSeconds = 1.5; ErrorMessage = $null
                    Results = @(
                        [ordered]@{ ResourceType = 'Test/Res'; InstanceName = 'fine'; Status = 'OK'; DurationMs = 10; ErrorMessage = $null; Drifted = $false; SetInvoked = $false }
                        [ordered]@{ ResourceType = 'Test/Res'; InstanceName = "evil`"/><testcase name=`"forged"; Status = 'FAIL'; DurationMs = 20
                            ErrorMessage = "boom </failure><system-out>x</system-out> | col | <script>alert(1)</script> ![img](http://x/y) `u{0}`u{1}`u{8}"; Drifted = $true; SetInvoked = $false }
                        [ordered]@{ ResourceType = 'Test/Res'; InstanceName = "multi`nline | pipe"; Status = 'SKIP'; DurationMs = 0; ErrorMessage = 'skipped'; Drifted = $null; SetInvoked = $false }
                    )
                }
            }
        }

        BeforeEach {
            $script:savedStepSummary = $env:GITHUB_STEP_SUMMARY
            $env:GITHUB_STEP_SUMMARY = $null
        }

        AfterEach {
            $env:GITHUB_STEP_SUMMARY = $script:savedStepSummary
        }

        It "writes well-formed JUnit XML that a hostile name or message cannot add elements to" {
            $rep = New-ReportDirectory
            $outcome = & $script:junit -Context @{ Document = (New-HostileDocument); ReportPath = $rep }

            $xml = [xml](Get-Content -LiteralPath $outcome.Path -Raw)
            $suite = $xml.testsuites.testsuite
            $suite.tests | Should -Be '3'
            $suite.failures | Should -Be '1'
            $suite.skipped | Should -Be '1'
            @($suite.testcase).Count | Should -Be 3
            @($suite.SelectNodes('.//system-out')).Count | Should -Be 0
            @($suite.testcase | Where-Object { $_.name -eq 'forged' }).Count | Should -Be 0
            @($suite.SelectNodes('testcase/failure')).Count | Should -Be 1
            $suite.SelectSingleNode('testcase/failure').message | Should -Match 'boom'
        }

        It "keeps the JUnit file inside the report directory whatever the node name is: <NodeName>" -ForEach @(
            @{ NodeName = '../../outside' }
            @{ NodeName = '..' }
            @{ NodeName = 'sub/dir/node' }
        ) {
            $rep = New-ReportDirectory
            $outcome = & $script:junit -Context @{ Document = (New-HostileDocument -NodeName $NodeName); ReportPath = $rep }

            (Split-Path -Parent $outcome.Path) | Should -Be $rep
            @(Get-ChildItem -LiteralPath $rep -File).Count | Should -Be 1
        }

        It "refuses to write JUnit XML with nowhere to put it" {
            { & $script:junit -Context @{ Document = (New-HostileDocument) } } | Should -Throw '*No directory*'
        }

        It "writes a Markdown summary whose table a hostile name or message cannot break" {
            $rep = New-ReportDirectory
            $outcome = & $script:summary -Context @{ Document = (New-HostileDocument); ReportPath = $rep }

            $text = Get-Content -LiteralPath $outcome.Path -Raw
            $text | Should -Not -Match '<script'
            $text | Should -Not -Match '<testcase'
            $text | Should -Not -Match '(?<!\\)!\[img\]'
            # Two listed rows (FAIL and SKIP), each still exactly one line with five cells.
            $rows = @($text -split "`n" | Where-Object { $_ -match '^\| (FAIL|SKIP) ' })
            $rows.Count | Should -Be 2
            foreach ($row in $rows) { @([regex]::Matches($row, '(?<!\\)\|')).Count | Should -Be 6 }
            $outcome.JobSummary | Should -BeFalse
        }

        It "appends the summary to the GitHub job summary when there is one" {
            $jobSummary = Join-Path $TestDrive ("step-" + [guid]::NewGuid().ToString('N') + '.md')
            Set-Content -LiteralPath $jobSummary -Value 'earlier step'
            $env:GITHUB_STEP_SUMMARY = $jobSummary

            $outcome = & $script:summary -Context @{ Document = (New-HostileDocument) }

            $outcome.JobSummary | Should -BeTrue
            $written = Get-Content -LiteralPath $jobSummary -Raw
            $written | Should -Match 'earlier step'
            $written | Should -Match 'DSC run: node1'
        }

        It "refuses to write a summary with nowhere to put it" {
            { & $script:summary -Context @{ Document = (New-HostileDocument) } } | Should -Throw '*Nowhere to write*'
        }

        It "caps the summary table so one configuration cannot flood a job summary" {
            $rep = New-ReportDirectory
            $document = New-HostileDocument
            $document.Results = @(1..450 | ForEach-Object { [ordered]@{ ResourceType = 'Test/Res'; InstanceName = "r$_"; Status = 'FAIL'; DurationMs = 1; ErrorMessage = ('m' * 2000); Drifted = $true; SetInvoked = $false } })

            $outcome = & $script:summary -Context @{ Document = $document; ReportPath = $rep }

            $text = Get-Content -LiteralPath $outcome.Path -Raw
            @($text -split "`n" | Where-Object { $_ -match '^\| FAIL ' }).Count | Should -Be 200
            $text | Should -Match '250 more not shown'
            $text.Length | Should -BeLessThan 100000
        }
    }
}
