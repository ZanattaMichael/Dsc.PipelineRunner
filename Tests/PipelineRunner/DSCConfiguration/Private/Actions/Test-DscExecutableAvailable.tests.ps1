Describe "Test-DscExecutableAvailable Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Test-DscExecutableAvailable.ps1').FullName
    }

    Context "Executable discovery" {

        It "Returns true when the executable resolves as an application command" {
            Mock -CommandName Get-Command -MockWith {
                return [pscustomobject]@{ Name = 'dsc'; CommandType = 'Application' }
            }

            Test-DscExecutableAvailable | Should -BeTrue

            Assert-MockCalled -CommandName Get-Command -Exactly 1 -Scope It -ParameterFilter {
                $Name -eq 'dsc' -and $CommandType -eq 'Application'
            }
        }

        It "Returns false when the executable cannot be resolved" {
            Mock -CommandName Get-Command -MockWith { return $null }

            Test-DscExecutableAvailable | Should -BeFalse
        }

        It "Probes for a custom executable name when supplied" {
            Mock -CommandName Get-Command -MockWith {
                return [pscustomobject]@{ Name = 'dsc.exe'; CommandType = 'Application' }
            }

            Test-DscExecutableAvailable -Executable 'dsc.exe' | Should -BeTrue

            Assert-MockCalled -CommandName Get-Command -Exactly 1 -Scope It -ParameterFilter {
                $Name -eq 'dsc.exe'
            }
        }
    }
}
