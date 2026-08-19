
Describe "variables Function Tests" -Tag Unit, Runner, Configuration -skip {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'variables.ps1').FullName

        . $preParseFilePath

    }


    BeforeEach {
        # Set up some variables in the current scope
        $global:testVariable1 = "TestValue1"
        $global:testVariable2 = "TestValue2"
    }

    It "should return the correct value for an existing variable" {
        $result = variables -Name 'testVariable1'
        $result | Should -Be "TestValue1"

        $result = variables -Name 'testVariable2'
        $result | Should -Be "TestValue2"
    }

    It "should return $null for a non-existing variable" {
        $result = variables -Name 'nonExistingVariable'
        $result | Should -Be $null
    }

    AfterEach {
        # Clean up the variables
        Remove-Variable -Name testVariable1 -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name testVariable2 -Scope Global -ErrorAction SilentlyContinue
    }
}
