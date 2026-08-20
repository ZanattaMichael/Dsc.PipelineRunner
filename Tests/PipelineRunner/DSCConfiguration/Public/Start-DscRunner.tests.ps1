Describe "Start-DscRunner Function Tests" -Tag Unit {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        $getDefaultValuesPath = (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        $SetVariablesPath = (Get-FunctionPath 'SetVariables.ps1').FullName
        $InvokeCustomTaskPath = (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        $InvokePreParseRulesPath = (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        $InvokeFormatTasksPath = (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName
        $InvokeExpandHashTablePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        $StopTaskProcessingPath = (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName
        # Engine seam: Start-DscRunner now routes Test/Set/Get through Invoke-EngineAction,
        # which dispatches to Actions/Engine/DscV2.ps1 (the default engine that wraps
        # Invoke-DscResource). Load the loader, the wrapper, the normalizer and the
        # DscMethodResult class so the real engine path runs against the mocks below.
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . $preParseFilePath
        . $getDefaultValuesPath
        . $SetVariablesPath
        . $InvokeCustomTaskPath
        . $InvokePreParseRulesPath
        . $InvokeFormatTasksPath
        . $InvokeExpandHashTablePath
        . $StopTaskProcessingPath

        $references = @{}
        $variables = @{}
        $parameters = @{}

        # Invoke-Action resolves Actions/<Hook>/<Name>.ps1 from the module base; in the
        # test there is no imported module, so point it at the repository root where the
        # real Actions/ tree lives.
        Mock -CommandName Get-Module -MockWith { return @{ moduleBase = $Global:RepositoryRoot } }

        # #30: the runner must not use Write-Host at all; all human-readable output goes
        # through Write-Information (tag 'Dsc.PipelineRunner'). Mock both so we can assert
        # Write-Host never fires and the information stream carries the expected tag.
        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        Mock -CommandName ConvertFrom-Yaml -MockWith {
            param ($content)
            return @{
                parameters = @{
                    param1 = "value1"
                }
                variables = @{
                    var1 = "value1"
                }
                resources = @(
                    @{
                        type = "Module/Resource"
                        name = "Resource1"
                        properties = @{
                            prop1 = "value1"
                        }
                    }
                )
            }
        }

        Mock -CommandName ConvertFrom-Json -MockWith {
            param ($content)
            return @{
                parameters = @{
                    param1 = "value1"
                }
                variables = @{
                    var1 = "value1"
                }
                resources = @(
                    @{
                        type = "Module/Resource"
                        name = "Resource1"
                        properties = @{
                            prop1 = "value1"
                        }
                    }
                )
            }
        }

        Mock -CommandName Invoke-DscResource -MockWith {
            param ($Name, $ModuleName, $Method, $Property)
            return @{
                InDesiredState = $Method -eq "Test"
                Message = "Mocked message"
            }
        }

        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory=$true)]
                [Object[]]$Tasks,
                [Parameter(Mandatory=$true)]
                [String]$CustomTaskName
            )

            return $pipeline.resources

        }

        Mock -CommandName Invoke-PreParseRules -MockWith {
            param(
                [Parameter(Mandatory=$true)]
                [Object[]]$Tasks
            )

        }

        Mock -CommandName Invoke-FormatTasks -MockWith {
            param(
                [Parameter(Mandatory=$true)]
                [Object[]]$Tasks
            )

            return $Tasks
        }

        Mock -CommandName Expand-HashTable -MockWith {
            param(
                [Parameter(Mandatory=$true)]
                [Hashtable]$InputHashTable
            )

            return $InputHashTable
        }

        Mock -CommandName Export-Csv
        Mock -CommandName Set-Content

    }

    BeforeEach {
        # Reset the script-scoped variable before each test
        $script:StopTaskProcessing = $false
    }

    Context "when processing configuration files" {

        It "should correctly load YAML configuration" {
            Mock -CommandName Get-Content -MockWith { "---\nparameters: {}\nvariables: {}\nresources: []" }
            Start-DscRunner -FilePath "test.yaml"
            Assert-MockCalled -CommandName ConvertFrom-Yaml -Exactly 1
        }

        It "should correctly load JSON configuration" {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
            Start-DscRunner -FilePath "test.json"
            Assert-MockCalled -CommandName ConvertFrom-Json -Exactly 1
        }

        It "should throw error for unsupported file extension" {
            { Start-DscRunner -FilePath "test.txt" } | Should -Throw
        }
    }

    Context "output stream hygiene (#30)" {

        BeforeAll {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
        }

        It "should never call Write-Host" {
            Start-DscRunner -FilePath "test.json" | Out-Null
            Assert-MockCalled -CommandName Write-Host -Exactly 0
        }

        It "should emit informational output tagged 'Dsc.PipelineRunner'" {
            Start-DscRunner -FilePath "test.json" | Out-Null
            Assert-MockCalled -CommandName Write-Information -ParameterFilter { $Tags -contains 'Dsc.PipelineRunner' } -Times 1
        }
    }

    Context "structured run result (#19, #29)" {

        It "should return a structured result object describing the run" {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }

            $result = Start-DscRunner -FilePath "test.json"

            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be 'Completed'
            $result.ConfigurationFile | Should -Be 'test.json'
            $result.PSObject.Properties.Name | Should -Contain 'PassCount'
            $result.PSObject.Properties.Name | Should -Contain 'FailCount'
            $result.PSObject.Properties.Name | Should -Contain 'SkipCount'
            $result.PSObject.Properties.Name | Should -Contain 'FailedResources'
        }

        It "should report a single passing resource in Test mode" {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
            Mock -CommandName Invoke-DscResource -MockWith {
                [PSCustomObject]@{ InDesiredState = $true; Message = "Tested successfully." }
            }

            $result = Start-DscRunner -FilePath "test.json"

            $result.PassCount | Should -Be 1
            $result.FailCount | Should -Be 0
            $result.TotalResources | Should -Be 1
        }

        It "should mark a resource FAIL and record it when drift is detected in Test mode" {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
            Mock -CommandName Invoke-DscResource -MockWith {
                [PSCustomObject]@{ InDesiredState = $false; Message = "Not in desired state." }
            }

            $result = Start-DscRunner -FilePath "test.json"

            $result.FailCount | Should -Be 1
            $result.FailedResources.Count | Should -Be 1
            $result.FailedResources[0].InstanceName | Should -Be 'Resource1'
        }
    }

    Context "when operating in different modes" {

        BeforeAll {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
        }

        It "should operate in 'Test' mode by default" {
            Mock -CommandName Invoke-DscResource -MockWith {
                [PSCustomObject]@{ InDesiredState = $true; Message = "Tested successfully." }
            }

            Start-DscRunner -FilePath "test.json" | Out-Null

            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Test" } -Exactly 1
        }

        It "should apply changes in 'Set' mode" {
            Mock -CommandName Invoke-DscResource -MockWith {
                [PSCustomObject]@{ InDesiredState = $false; Message = "Not in desired state." }
            }

            Start-DscRunner -FilePath "test.json" -Mode "Set" | Out-Null

            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Test" } -Exactly 1
            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Set" } -Exactly 1
        }

        It "should skip tasks when StopTaskProcessing is true" {

            Mock -CommandName ConvertFrom-Json -MockWith {
                param ($content)
                return @{
                    parameters = @{
                        param1 = "value1"
                    }
                    variables = @{
                        var1 = "value1"
                    }
                    resources = @(
                        @{
                            type = "Module/Resource"
                            name = "Resource1"
                            postExecutionScript = 'Stop-TaskProcessing'
                            properties = @{
                                prop1 = "value1"
                            }
                        }
                        @{
                            type = "Module/Resource"
                            name = "Resource2"
                            properties = @{
                                prop1 = "value1"
                            }
                        }
                    )
                }
            }

            $result = Start-DscRunner -FilePath "test.json"

            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Test" } -Exactly 1
            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Get" } -Exactly 1
            $result.SkipCount | Should -Be 1
            $result.Status | Should -Be 'StoppedByRequest'

        }

        It "should skip resources if the condition is met" {

            Mock -CommandName ConvertFrom-Json -MockWith {
                param ($content)
                return @{
                    parameters = @{
                        param1 = "value1"
                    }
                    variables = @{
                        var1 = "value1"
                    }
                    resources = @(
                        @{
                            type = "Module/Resource"
                            name = "Resource1"
                            properties = @{
                                prop1 = "value1"
                            }
                            condition = '1 -ne 1'
                        }
                        @{
                            type = "Module/Resource"
                            name = "Resource2"
                            properties = @{
                                prop2 = "value2"
                            }
                            condition = '1 -eq 1'
                        }
                    )
                }
            }

            Start-DscRunner -FilePath "test.json" | Out-Null

            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Property.prop1 -eq "value1" } -Exactly 0
            Assert-MockCalled -CommandName Invoke-DscResource -ParameterFilter { $Property.prop2 -eq "value2" } -Exactly 2

        }

    }

    Context "when handling report paths" {

        BeforeAll {
            Mock -CommandName Get-Content -MockWith { '{"parameters": {}, "variables": {}, "resources": []}' }
        }

        It "should generate a CSV and a JSON report if ReportPath is specified" {
            Start-DscRunner -FilePath "test.json" -ReportPath "C:\Reports" | Out-Null

            Assert-MockCalled -CommandName Export-Csv -Exactly 1
            Assert-MockCalled -CommandName Set-Content -Exactly 1
        }

        It "should not generate a report if ReportPath is not specified" {
            Start-DscRunner -FilePath "test.json" | Out-Null

            Assert-MockCalled -CommandName Export-Csv -Exactly 0
            Assert-MockCalled -CommandName Set-Content -Exactly 0
        }
    }

    Context "error handling and edge cases" {

        It "should handle missing FilePath parameter" {
            { Start-DscRunner -Mode "Test" } | Should -Throw
        }

        It "should handle invalid Mode parameter" {
            { Start-DscRunner -FilePath "test.json" -Mode "Invalid" } | Should -Throw
        }

        It "should print a non-terminating error when the runner fails to set a resource" {

            Mock -CommandName Write-Error -ParameterFilter { $Message -like "*Failed to apply changes with 'Set' method*" } -Verifiable
            Mock -CommandName Invoke-DscResource -ParameterFilter { $Method -eq "Set" } -Verifiable -MockWith {
                throw "mock error"
            }
            Mock -CommandName Invoke-DscResource -ParameterFilter { $Method -eq 'Test' } -MockWith {
                @{
                    InDesiredState = $false
                }
            } -Verifiable
            Mock -CommandName Get-Content -MockWith { "---\nparameters: {}\nvariables: {}\nresources: []" }

            $result = $null
            { $result = Start-DscRunner -FilePath "test.json" -Mode "Set" } | Should -Not -Throw
            Should -InvokeVerifiable
            $result.FailCount | Should -Be 1

        }
    }

}
