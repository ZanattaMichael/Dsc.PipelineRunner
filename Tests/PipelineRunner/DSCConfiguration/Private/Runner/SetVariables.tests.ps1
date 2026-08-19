
Describe "SetVariables Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {
         # Load the functions to test
         $preParseFilePath = (Get-FunctionPath 'SetVariables.ps1').FullName

         . $preParseFilePath
    }

    BeforeEach {
        # Initialize empty target hashtable
        $global:target = @{}
    }

    It "should copy key-value pairs from Source to Target hashtable" {
        $source = @{
            "Key1" = "Value1"
            "Key2" = "Value2"
        }
        
        SetVariables -Source $source -Target $target
        
        $target["Key1"] | Should -Be "Value1"
        $target["Key2"] | Should -Be "Value2"
    }

    It "should create script-level variables with underscores replacing dots" {
        $source = @{
            "Key.With.Dot" = "DotValue"
        }
        
        SetVariables -Source $source -Target $target
        
        $script:Key_With_Dot | Should -Be "DotValue"
    }


    AfterEach {
        # Clean up environment variables and script variables
        Remove-Item -Path env:EnvVar -ErrorAction SilentlyContinue
        Remove-Variable -Name Key_With_Dot -Scope Script -ErrorAction SilentlyContinue
    }
}
