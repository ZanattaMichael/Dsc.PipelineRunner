Describe "Expand-HashTable Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        $expandStringInArrayFilePath = (Get-FunctionPath 'Expand-StringInArray.ps1').FullName

        . $preParseFilePath
        . $expandStringInArrayFilePath

        # Mock the Task Object Properties
        $task = @{
            properties = @{
                ListKey = [System.Collections.Generic.List[Object]]@('value1', 'value2')
                Key1 = 'Value1'
                Key2 = 'Value2'
            }
        }

    }


    Context "With Boolean Values" {
        It "should keep boolean values unchanged" {
            $inputHashTable = @{ BoolKey = $true }
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.BoolKey | Should -Be $true
        }
    }

    Context "With List Values" {
        It "should expand list values correctly" {
            $inputHashTable = @{ ListKey = [System.Collections.Generic.List[Object]]@('value1', 'value2') }
            $expected = @('value1','value2')
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.ListKey | Should -Be $expected
        }
    }

    Context "With Nested Hashtable" {
        It "should recursively expand nested hashtables" {
            $inputHashTable = @{ NestedKey = @{ InnerKey = 'InnerValue' } }
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.NestedKey.InnerKey | Should -Be 'InnerValue'
        }
    }

    Context "With String Values" {
        It "should expand string values using the ExecutionContext" {
            $inputHashTable = @{ StringKey = 'Hello $env:USERNAME' }
            $expandedString = $ExecutionContext.InvokeCommand.ExpandString($inputHashTable.StringKey)
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.StringKey | Should -Be $expandedString
        }
    }

    Context "With Null Values" {
        It "should preserve null values without throwing" {
            $inputHashTable = @{ NullKey = $null }
            { Expand-HashTable -InputHashTable $inputHashTable } | Should -Not -Throw
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.ContainsKey('NullKey') | Should -Be $true
            $result.NullKey | Should -Be $null
        }
    }

    Context "With Mixed Types" {
        It "should handle mixed types correctly" {
            $inputHashTable = @{
                BoolKey = $false
                ListKey = [System.Collections.Generic.List[Object]]@('value1', 'value2')
                NestedKey = @{ SubKey = 'SubValue' }
                StringKey = 'StaticString'
            }
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.BoolKey | Should -Be $false
            $result.ListKey | Should -Be @('value1','value2')
            $result.NestedKey.SubKey | Should -Be 'SubValue'
            $result.StringKey | Should -Be 'StaticString'
        }
    }
}
