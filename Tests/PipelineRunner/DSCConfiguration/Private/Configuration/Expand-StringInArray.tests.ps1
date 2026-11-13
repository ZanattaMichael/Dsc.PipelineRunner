Describe "Expand-StringInArray Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        $expandExpandHashTableFilePath = (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        # Expand-HashTable / Expand-StringInArray expand strings through Expand-SafeString,
        # which validates embedded expressions with the condition allow-list.
        . (Get-FunctionPath 'Expand-SafeString.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-NormalizedConditionExpression.ps1').FullName

        . $preParseFilePath
        . $expandExpandHashTableFilePath

    }

    Context "With String Expansion" {
        It "should expand strings with environment variables" {
            $inputObj = @("Hello, $env:USERNAME!")
            $expected = @("Hello, $($env:USERNAME)!")
            $result = Expand-StringInArray -InputArray $inputObj
            $result | Should -BeExactly $expected
        }

        It "should expand side-effect-free sub-expressions" {
            $result = Expand-StringInArray -InputArray @('Value $(if ($true) { ''yes'' } else { ''no'' })')
            $result | Should -BeExactly @('Value yes')
        }

        It "should refuse a sub-expression that runs a command or method" {
            { Expand-StringInArray -InputArray @('Today is $((Get-Date).ToString("dddd"))') } |
                Should -Throw '*Refusing to expand*'
        }
    }

    Context "With Non-String Elements" {
        It "should keep boolean values as is" {
            $inputObj = @(1, $true, 3)
            $expected = @(1, $true, 3)
            $result = Expand-StringInArray -InputArray $inputObj
            $result | Should -BeExactly $expected
        }

        It "should handle hashtables correctly" {
            $inputObj = @(@{ key = 'value' })

            $result = Expand-StringInArray -InputArray $inputObj
            $result.key | Should -BeExactly 'value'
        }

        it "should handle multiple hashtables correctly" {
            $inputObj = @(@{ key1 = 'value1' }, @{ key2 = 'value2' })

            $result = Expand-StringInArray -InputArray $inputObj
            $result.key1 | Should -BeExactly 'value1'
            $result.key2 | Should -BeExactly 'value2'
        }

        It "should add non-string, non-hashtable items unchanged" {
            $inputObj = @(42, [datetime]::Now, [pscustomobject]@{ prop = 'value' })

            $result = Expand-StringInArray -InputArray $inputObj
            $result[0] | Should -BeExactly 42
            $result[1] | Should -BeExactly $inputObj[1]
            $result[2] | Should -BeExactly $inputObj[2]

        }
    }
}    