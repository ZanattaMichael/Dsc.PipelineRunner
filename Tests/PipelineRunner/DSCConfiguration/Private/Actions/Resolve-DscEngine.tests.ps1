Describe "Resolve-DscEngine Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        # The availability probe is dot-sourced so Resolve-DscEngine can call it and so
        # the tests can Mock it to simulate a box with or without dsc.exe present.
        . (Get-FunctionPath 'Test-DscExecutableAvailable.ps1').FullName
        . (Get-FunctionPath 'Resolve-DscEngine.ps1').FullName
    }

    Context "Explicit engine selection" {

        It "Returns an explicitly named engine verbatim without probing" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $true }

            Resolve-DscEngine -Engine 'DscV2' | Should -Be 'DscV2'
            Resolve-DscEngine -Engine 'DscV3' | Should -Be 'DscV3'

            Assert-MockCalled -CommandName Test-DscExecutableAvailable -Exactly 0 -Scope It
        }
    }

    Context "Auto selection by version hint" {

        It "Selects DscV3 for a version with major >= 3" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $true }

            Resolve-DscEngine -Engine 'Auto' -Version '3.0' | Should -Be 'DscV3'
        }

        It "Selects DscV2 for a version with major 2" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $true }

            Resolve-DscEngine -Engine 'Auto' -Version '2.5' | Should -Be 'DscV2'
        }

        It "Warns but still selects DscV3 when the version asks for v3 and dsc is absent" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $false }
            Mock -CommandName Write-Warning

            Resolve-DscEngine -Engine 'Auto' -Version '3.1' | Should -Be 'DscV3'

            Assert-MockCalled -CommandName Write-Warning -Exactly 1 -Scope It
        }
    }

    Context "Auto selection without a decisive version" {

        It "Prefers DscV3 when the dsc executable is present" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $true }

            Resolve-DscEngine -Engine 'Auto' | Should -Be 'DscV3'
        }

        It "Falls back to DscV2 when the dsc executable is absent" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $false }

            Resolve-DscEngine -Engine 'Auto' | Should -Be 'DscV2'
        }

        It "Ignores an unparseable version hint and probes instead" {
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $false }

            Resolve-DscEngine -Engine 'Auto' -Version 'not-a-version' | Should -Be 'DscV2'

            Assert-MockCalled -CommandName Test-DscExecutableAvailable -Exactly 1 -Scope It
        }
    }
}
