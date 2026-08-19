
Describe "parameters Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'parameters.ps1').FullName

        . $preParseFilePath

        $parameters = @{
            Key1 = "Value1"
            Key2 = "Value2"
            Key3 = "Value3"
        }

    }
    
    It "should return 'Value1' for input 'Key1'" {
        $result = parameters -Name "Key1"
        $result | Should -Be "Value1"
    }

    It "should return 'Value2' for input 'Key2'" {
        $result = parameters -Name "Key2"
        $result | Should -Be "Value2"
    }

    It "should return 'Value3' for input 'Key3'" {
        $result = parameters -Name "Key3"
        $result | Should -Be "Value3"
    }

    It "should return $null for a non-existent key" {
        $result = parameters -Name "NonExistentKey"
        $result | Should -Be $null
    }
}
