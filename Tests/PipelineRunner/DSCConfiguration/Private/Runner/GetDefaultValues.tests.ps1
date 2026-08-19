
Describe "GetDefaultValues Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'GetDefaultValues.ps1').FullName

        . $preParseFilePath

    }

    It "should return an empty hashtable when given an empty source" {
        $source = @{}
        $result = GetDefaultValues -Source $source
        $result.Count | Should -Be 0
    }

    It "should extract default values from the source hashtable" {
        $source = @{
            Key1 = @{ defaultValue = "Value1" }
            Key2 = @{ defaultValue = "Value2" }
            Key3 = @{ defaultValue = "Value3" }
        }

        $result = GetDefaultValues -Source $source

        $result.Key1 | Should -Be "Value1"
        $result.Key2 | Should -Be "Value2"
        $result.Key3 | Should -Be "Value3"

    }

    It "should handle missing defaultValue keys gracefully" {
        $source = @{
            Key1 = @{ otherProperty = "Other1" }
            Key2 = @{ defaultValue = "Value2" }
        }
        $expected = @{
            Key1 = $null
            Key2 = "Value2"
        }
        $result = GetDefaultValues -Source $source
        $result.Key1 | Should -Be $null
        $result.Key2 | Should -Be "Value2"

    }

    It "should return null for keys without defaultValue" {
        $source = @{
            Key1 = @{ anotherProperty = "SomeValue" }
        }

        $result = GetDefaultValues -Source $source
        $result.Key1 | Should -Be $null

    }

    It "should work with nested hashtables" {
        $source = @{
            Key1 = @{ defaultValue = @{ NestedKey = "NestedValue" } }
        }

        $result = GetDefaultValues -Source $source
        $result.Key1.NestedKey | Should -Be "NestedValue"

    }
}    