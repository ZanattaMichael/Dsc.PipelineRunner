Describe "reference Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'reference.ps1').FullName

        . $preParseFilePath

        $parameters = @{
            Key1 = "Value1"
            Key2 = "Value2"
            Key3 = "Value3"
        }

        $global:references = @{
            "exampleReference" = "ExampleValue"
            "anotherReference" = "AnotherValue"
            "yetAnotherReference" = "YetAnotherValue"
        }

    }

    It "should return 'ExampleValue' for input 'exampleReference'" {
        $result = reference -Name "exampleReference"
        $result | Should -Be "ExampleValue"
    }

    It "should return 'AnotherValue' for input 'anotherReference'" {
        $result = reference -Name "anotherReference"
        $result | Should -Be "AnotherValue"
    }

    It "should return 'YetAnotherValue' for input 'yetAnotherReference'" {
        $result = reference -Name "yetAnotherReference"
        $result | Should -Be "YetAnotherValue"
    }

    It "should return $null for a non-existent key" {
        $result = reference -Name "nonExistentReference"
        $result | Should -Be $null
    }
}
