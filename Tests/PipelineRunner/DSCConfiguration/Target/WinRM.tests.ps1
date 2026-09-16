<#
Mocked by design: this suite mocks New-CimSession/New-PSSession so it can assert the action's
dispatch/parameter-passing logic on any host, including the hosted Linux agents that have no WSMan
stack at all. The live connection is covered separately by
../Integration/WinRMTarget.Integration.tests.ps1, which runs on the self-hosted Windows runner.
#>
Describe "Actions/Target/WinRM Tests" -Tag Unit, Target {

    BeforeAll {
        $script:WinRMPath = (Get-FunctionPath 'WinRM.ps1').FullName

        # New-CimSession comes from the CimCmdlets module, which ships with Windows PowerShell
        # but is not present on the Linux/macOS PowerShell used by this CI job. Define a stub so
        # it resolves for Get-Command / Mock to attach to.
        function New-CimSession {
            param($ComputerName, $Credential)
        }

        # New-PSSession IS present on this CI image (it's core PowerShell remoting), but its real
        # -Credential parameter is typed [pscredential] - a sealed class the fake credential object
        # used below cannot satisfy. Pester's Mock inherits the target command's real parameter
        # metadata, so shadow it too, loosely typed, before mocking it.
        function New-PSSession {
            param($ComputerName, $Credential)
        }

        Mock -CommandName New-CimSession -MockWith {
            param($ComputerName, $Credential)
            return [pscustomobject]@{ Marker = 'cim'; ComputerName = $ComputerName }
        }
        Mock -CommandName New-PSSession -MockWith {
            param($ComputerName, $Credential)
            return [pscustomobject]@{ Marker = 'ps'; ComputerName = $ComputerName }
        }
    }

    It "Throws when ComputerName is not supplied" {
        { & $script:WinRMPath -Context @{} } | Should -Throw "*ComputerName*"
    }

    It "Opens both a CimSession and a PSSession for the target computer" {
        $result = & $script:WinRMPath -Context @{ ComputerName = 'node01' }

        $result.IsRemote | Should -BeTrue
        $result.ComputerName | Should -Be 'node01'
        $result.CimSession.Marker | Should -Be 'cim'
        $result.PSSession.Marker | Should -Be 'ps'

        Assert-MockCalled -CommandName New-CimSession -ParameterFilter { $ComputerName -eq 'node01' } -Exactly 1 -Scope It
        Assert-MockCalled -CommandName New-PSSession -ParameterFilter { $ComputerName -eq 'node01' } -Exactly 1 -Scope It
    }

    It "Forwards a supplied Credential to both session constructors" {
        $cred = [pscustomobject]@{ Marker = 'fake-credential' }

        $null = & $script:WinRMPath -Context @{ ComputerName = 'node01'; Credential = $cred }

        Assert-MockCalled -CommandName New-CimSession -ParameterFilter { $Credential -eq $cred } -Exactly 1 -Scope It
        Assert-MockCalled -CommandName New-PSSession -ParameterFilter { $Credential -eq $cred } -Exactly 1 -Scope It
    }
}
