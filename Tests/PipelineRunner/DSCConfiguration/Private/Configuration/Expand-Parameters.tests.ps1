Describe "Expand-Parameters Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-Parameters.ps1').FullName
        $expandExpandHashTableFilePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        $expandParameterInArrayFilePath = (Get-FunctionPath 'Expand-ParameterInArray.ps1').FullName
        
        . $preParseFilePath
        . $expandExpandHashTableFilePath
        . $expandParameterInArrayFilePath

        # Define the script-scoped parameters hashtable
        $Script:parameters = @{
            example = 'ExpandedValue'
            anotherExample = 'AnotherExpandedValue'
        }

    }

    Context "With Nested Hashtables" {
        It "should recursively expand nested hashtables" {
            $inputObj = @{
                outerKey = @{
                    innerKey = '<params=example>'
                }
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.outerKey.innerKey | Should -Be 'ExpandedValue'

        }
    }

    Context "With Arrays Containing Strings" {
        It "should expand strings in arrays correctly" {
            $inputObj = @{
                listKey = @('<params=example>', 'RegularString')
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.listKey | Should -BeExactly @('ExpandedValue', 'RegularString')
        }
    }

    Context "With String Placeholders" {
        It "should replace placeholders with actual values" {
            $inputObj = @{
                key = '<params=example>'
            }

            $result = Expand-Parameters -InputHashTable $inputObj
            $result.key | Should -Be 'ExpandedValue'

        }

        It "should throw an error if placeholder is not found" {
            $inputObj = @{
                key = '<params=nonExistent>'
            }
            { Expand-Parameters -InputHashTable $inputObj } | Should -Throw "*Parameter 'nonExistent' not found in the parameters hashtable*"
        }
    }

    Context "With Mixed Types in Hashtable" {
        It "should handle mixed types correctly" {
            $inputObj = @{
                boolKey = $true
                stringKey = 'JustAString'
                paramKey = '<params=example>'
                listKey = @('<params=anotherExample>', 'String')
                hashKey = @{
                    nestedParam = '<params=example>'
                }
            }

            $result = Expand-Parameters -InputHashTable $inputObj

            $result.boolKey | Should -Be $true
            $result.stringKey | Should -Be 'JustAString'
            $result.paramKey | Should -Be 'ExpandedValue'
            $result.listKey | Should -BeExactly @('AnotherExpandedValue', 'String')
            $result.hashKey.nestedParam | Should -BeExactly 'ExpandedValue'

        }
    }
}