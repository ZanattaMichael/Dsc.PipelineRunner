Describe "Resolve-DscDatumProject Function Tests" -Tag Unit, LCM, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName

        . $preParseFilePath


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

}
