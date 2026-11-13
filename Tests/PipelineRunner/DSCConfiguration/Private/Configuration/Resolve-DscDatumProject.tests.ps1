Describe "Resolve-DscDatumProject Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName

        . $preParseFilePath

        # Composite expansion runs inside Resolve-DscDatumProject; load the real implementation.
        . (Get-FunctionPath 'Get-CompositeDefinition.ps1').FullName
        . (Get-FunctionPath 'Expand-CompositeResource.ps1').FullName


        function ConvertTo-Yaml {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
                $InputObject
            )
            return "---\nkey: value"
        }


        # Mock necessary commands to isolate the function's behavior
        Mock -CommandName Write-Host
        Mock -CommandName Write-Verbose
        Mock -CommandName Resolve-Datum -MockWith { return @{} }
        Mock -CommandName Test-InvokeCommandFilter -MockWith { return $false }
        Mock -CommandName Invoke-InvokeCommandAction -MockWith { return $_ }
        Mock -CommandName ConvertTo-Yaml -MockWith { return "---\nkey: value" }
        Mock -CommandName Out-File

    }

    Context "Configuration Data Processing" {

        It "Should create configuration data hashtable" {
            $mockNodeName = @{ Name = 'Node1' }
            $mockAllNodes = @{ 'Node1' = @{} }
            
            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Assert-MockCalled -CommandName Write-Verbose -Times 3 -Scope It
        }

        It "Should resolve resources, parameters, conditions, and variables" {
            $mockNodeName = @{ Name = 'Node1' }
            $mockAllNodes = @{ 'Node1' = @{} }
            
            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Assert-MockCalled -CommandName Resolve-Datum -Exactly 4 -Scope It
        }
    }

    Context "Variable Handling" {

        It "Should execute script blocks for variables if present" {
            Mock -CommandName Test-InvokeCommandFilter -MockWith { return $true }
            Mock -CommandName Invoke-InvokeCommandAction -MockWith { return "ExecutedValue" }

            Mock -CommandName Resolve-Datum -MockWith {
                @{
                    variable1 = '[x={ mock data }=]'
                    variable2 = '[x={ mock data }=]'

                }
            } -ParameterFilter { $PropertyPath -eq 'variables' }

            $mockNodeName = @{ Name = 'Node1' }
            $mockAllNodes = @{ 'Node1' = @{} }
            
            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Assert-MockCalled -CommandName Invoke-InvokeCommandAction -Times 1 -Scope It
        }
    }

    Context "YAML Conversion" {

        It "Should convert configuration to YAML and save it to a file" {
            $mockNodeName = @{ Name = 'Node1' }
            $mockAllNodes = @{ 'Node1' = @{} }
            
            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Assert-MockCalled -CommandName ConvertTo-Yaml -Exactly 1 -Scope It
            Assert-MockCalled -CommandName Out-File -Exactly 1 -Scope It
        }
    }

    Context "Composite resources" {

        BeforeAll {
            # Read by Resolve-DscDatumProject through the scope chain, as in production where it
            # is a global of the compile runspace.
            $Datum = @{
                Composites = @{
                    Pair = [ordered]@{
                        parameters = [ordered]@{ Label = $null }
                        resources  = @(
                            [ordered]@{ name = 'First'; type = 'Stub/T'; properties = [ordered]@{ Label = '<composite=Label>' } }
                            [ordered]@{ name = 'Second'; type = 'Stub/T'; dependsOn = @('Stub/T/First') }
                        )
                    }
                }
            }
            $mockNodeName = @{ Name = 'Node1' }
            $mockAllNodes = @{ 'Node1' = @{} }
        }

        It "writes the expanded members, not the instance, to the compiled configuration" {
            Mock -CommandName Resolve-Datum -ParameterFilter { $PropertyPath -eq 'resources' } -MockWith {
                , @(
                    [ordered]@{ name = 'Org'; type = 'Stub/Org' }
                    [ordered]@{ name = 'P'; type = 'Composite/Pair'; properties = [ordered]@{ Label = 'L' }; dependsOn = @('Stub/Org/Org') }
                )
            }

            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Should -Invoke -CommandName ConvertTo-Yaml -Exactly 1 -Scope It -ParameterFilter {
                $names = @($InputObject.resources | ForEach-Object { $_['name'] })
                ($names -join ',') -eq 'Org,P::First,P::Second' -and
                $InputObject.resources[1]['properties']['Label'] -eq 'L' -and
                (@($InputObject.resources[2]['dependsOn']) -join ',') -eq 'Stub/T/P::First,Stub/Org/Org'
            }
        }

        It "writes a single resolved resource as a list" {
            Mock -CommandName Resolve-Datum -ParameterFilter { $PropertyPath -eq 'resources' } -MockWith {
                [ordered]@{ name = 'Only'; type = 'Stub/Only' }
            }

            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Should -Invoke -CommandName ConvertTo-Yaml -Exactly 1 -Scope It -ParameterFilter {
                $InputObject.resources -is [object[]] -and $InputObject.resources.Count -eq 1 -and $InputObject.resources[0]['name'] -eq 'Only'
            }
        }

        It "does not expand when the node resolves no resources" {
            Mock -CommandName Resolve-Datum -ParameterFilter { $PropertyPath -eq 'resources' } -MockWith { $null }
            Mock -CommandName Expand-CompositeResource

            Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes

            Should -Invoke -CommandName Expand-CompositeResource -Exactly 0 -Scope It
            Should -Invoke -CommandName Out-File -Exactly 1 -Scope It
        }

        It "fails the compile, writing nothing, when an instance is invalid" {
            Mock -CommandName Resolve-Datum -ParameterFilter { $PropertyPath -eq 'resources' } -MockWith {
                , @([ordered]@{ name = 'P'; type = 'Composite/Pair' })
            }

            { Resolve-DscDatumProject -NodeName $mockNodeName -AllNodes $mockAllNodes } |
                Should -Throw "*required parameter(s) 'Label'*"
            Should -Invoke -CommandName Out-File -Exactly 0 -Scope It
        }
    }

}
