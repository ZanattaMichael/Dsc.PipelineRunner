Describe "Expand-ParameterInArray Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        $expandParametersFilePath = (Get-FunctionPath 'Expand-Parameters.ps1').FullName

        . $preParseFilePath
        . $expandParametersFilePath

        # Define the script-scoped parameters hashtable
        $Script:parameters = @{
            example = 'ExpandedValue'
            anotherExample = 'AnotherExpandedValue'
        }

    }

    Context "With Boolean Values" {
        It "should keep boolean values unchanged" {
            $inputObj = @($true, $false)
            $result = Expand-ParameterInArray -InputArray $inputObj
            $result | Should -BeExactly $inputObj
        }
    }

    Context "With String Parameters" {
        It "should expand string parameters correctly" {
            $inputObj = @('<params=example>', '<params=anotherExample>')
            $expected = @('ExpandedValue', 'AnotherExpandedValue')
            $result = Expand-ParameterInArray -InputArray $inputObj
            $result | Should -BeExactly $expected
        }

        It "should throw an error if parameter is not found" {
            $inputObj = @('<params=nonExistent>')
            { Expand-ParameterInArray -InputArray $inputObj } | Should -Throw "*not found in the parameters hashtable*"
        }
    }

    Context "With Hashtable Values" {
        It "should process hashtable values using Expand-Parameters" {
            $inputObj = @{ key = 'value' }
            $result = Expand-ParameterInArray -InputArray @($inputObj)
            $result.key | Should -Be 'value'
        }
    }

    Context "With Mixed Types" {
        It "should handle mixed types correctly" {
            $inputObj = @(
                '<params=example>',
                $true,
                @{ key = 'value' },
                'RegularString'
            )

            $result = Expand-ParameterInArray -InputArray $inputObj
            $result | Should -Not -BeNullOrEmpty
            
            $result[0] | Should -Be 'ExpandedValue'
            $result[1] | Should -Be $true
            $result[2].key | Should -Be 'value'
            $result[3] | Should -Be 'RegularString'

        }
    }
}
