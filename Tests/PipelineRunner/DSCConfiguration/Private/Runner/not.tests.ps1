
Describe "not Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'not.ps1').FullName

        . $preParseFilePath

    }

    It "should return true when the input is false" {
        $result = not -Statement $false
        $result | Should -Be $true
    }

    It "should return false when the input is true" {
        $result = not -Statement $true
        $result | Should -Be $false
    }
        
    It "should return true when the input is 0 (interpreted as false)" {
        $result = not -Statement 0
        $result | Should -Be $true
    }

    It "should return false when the input is 1 (interpreted as true)" {
        $result = not -Statement 1
        $result | Should -Be $false
    }
}    