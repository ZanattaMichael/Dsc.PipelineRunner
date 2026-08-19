Describe "Stop-TaskProcessing Function Tests" -Tag Unit {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName
        . $preParseFilePath
        
    }

    BeforeEach {
        # Reset the script-scoped variable before each test
        $script:StopTaskProcessing = $false
    }

    Context "when called within Invoke-DscConfiguration" {

        It "should set the script:StopTaskProcessing to true" {

            Mock -CommandName Get-PSCallStack -MockWith {
                @(
                    [PSCustomObject]@{ Command = 'Start-LCM' }
                    [PSCustomObject]@{ Command = 'SomeOtherFunction' }
                )
            }
            Mock -CommandName Write-Error

            # Assert that the script:StopTaskProcessing is set to true
            { Stop-TaskProcessing } | Should -Not -Throw
            $script:StopTaskProcessing | Should -Be $true
            
        }

    } 

    Context "when called outside Invoke-DscConfiguration" {

        It "should write an error" {

            Mock -CommandName Get-PSCallStack -MockWith {
                @(
                    [PSCustomObject]@{ Command = 'SomeOtherFunction' }
                )
            }
            Mock -CommandName Write-Error

            { Stop-TaskProcessing } | Should -Not -Throw
            Assert-MockCalled -CommandName Write-Error -Exactly 1 -Scope It
            $script:StopTaskProcessing | Should -Be $false
        }

    }

}
