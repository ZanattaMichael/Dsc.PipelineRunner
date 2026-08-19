
Describe "equals Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'equals.ps1').FullName

        . $preParseFilePath

    }

    It "should return true when both strings are identical" {
        $result = equals -Left "Hello" -Right "Hello"
        $result | Should -Be $true
    }

    It "should return false when strings are different" {
        $result = equals -Left "Hello" -Right "World"
        $result | Should -Be $false
    }

    It "should return true for empty strings" {
        $result = equals -Left "" -Right ""
        $result | Should -Be $true
    }

    It "should return false when only one string is empty" {
        $result = equals -Left "Hello" -Right ""
        $result | Should -Be $false
    }

    It "should be case-sensitive and return false for different cases" {
        $result = equals -Left "hello" -Right "Hello"
        $result | Should -Be $false
    }

    It "should return true for strings with special characters" {
        $result = equals -Left "Hello@123!" -Right "Hello@123!"
        $result | Should -Be $true
    }
}
