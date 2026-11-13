Describe "Expand-HashTable Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        # Expand-HashTable / Expand-StringInArray expand strings through Expand-SafeString,
        # which validates embedded expressions with the condition allow-list.
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName
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

    Context "With Plain Array Values" {
        It "should expand a plain array without flattening it to a string" {
            $inputHashTable = @{ ArrayKey = @('value1', 'value2') }
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.ArrayKey -is [array] | Should -Be $true
            $result.ArrayKey | Should -Be @('value1', 'value2')
        }

        It "should keep an array of hashtables assignable to a hashtable[] property" {
            # Expand-Parameters runs ahead of this function and returns a plain object[]
            # where Datum supplied a List`1. Matching on the List`1 type name alone sent
            # that value to ExpandString, which flattened it to
            # "System.Collections.Hashtable System.Collections.Hashtable" and made every
            # array-typed resource property fail to bind.
            $inputHashTable = @{
                Permissions = @(
                    @{ Identity = 'Project Administrators'; Permission = 'Allow' },
                    @{ Identity = 'Project Valid Users'; Permission = 'Allow' }
                )
            }
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.Permissions -is [string] | Should -Be $false
            { [hashtable[]]$result.Permissions } | Should -Not -Throw
            ([hashtable[]]$result.Permissions).Count | Should -Be 2
            $result.Permissions[0].Identity | Should -Be 'Project Administrators'
            $result.Permissions[1].Identity | Should -Be 'Project Valid Users'
        }

        It "should expand the element of a single-element array" {
            # PowerShell unrolls a one-element collection on return, so the value arrives as
            # a scalar. That is long-standing behaviour of these helpers and harmless - a
            # scalar coerces back to a one-element array on property assignment - but the
            # element still has to come through expanded.
            $inputHashTable = @{ ArrayKey = @('Hello $env:USERNAME') }
            $expected = $ExecutionContext.InvokeCommand.ExpandString('Hello $env:USERNAME')
            $result = Expand-HashTable -InputHashTable $inputHashTable
            $result.ArrayKey | Should -Be $expected
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
