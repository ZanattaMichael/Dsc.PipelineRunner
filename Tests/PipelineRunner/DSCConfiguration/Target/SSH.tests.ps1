<#
Mocked only (#57 §4 scope note): mocks New-PSSession, so this validates dispatch/parameter
logic and the DscV2 fail-fast guard, not a live SSH connection.

The live connection is covered separately by
Tests/PipelineRunner/DSCConfiguration/Integration/SSHTarget.Integration.tests.ps1 (tag
HostedIntegration), which opens a real session against an sshd with a PowerShell subsystem.
#>
Describe "Actions/Target/SSH Tests" -Tag Unit, Target {

    BeforeAll {
        $script:SSHPath = (Get-FunctionPath 'SSH.ps1').FullName

        Mock -CommandName New-PSSession -MockWith {
            param($HostName, $UserName, $KeyFilePath)
            return [pscustomobject]@{ Marker = 'ssh'; HostName = $HostName }
        }
    }

    It "Throws when ComputerName is not supplied" {
        { & $script:SSHPath -Context @{} } | Should -Throw "*ComputerName*"
    }

    It "Fails fast when paired with the DscV2 engine, before opening a connection" {
        { & $script:SSHPath -Context @{ ComputerName = 'node01'; Engine = 'DscV2' } } | Should -Throw "*DscV3*"
        Assert-MockCalled -CommandName New-PSSession -Exactly 0 -Scope It
    }

    It "Opens a PSSession over SSH for the DscV3 engine" {
        $result = & $script:SSHPath -Context @{ ComputerName = 'node01'; Engine = 'DscV3' }

        $result.IsRemote | Should -BeTrue
        $result.ComputerName | Should -Be 'node01'
        $result.CimSession | Should -BeNullOrEmpty
        $result.PSSession.Marker | Should -Be 'ssh'

        Assert-MockCalled -CommandName New-PSSession -ParameterFilter { $HostName -eq 'node01' } -Exactly 1 -Scope It
    }

    It "Forwards UserName and KeyFilePath through to New-PSSession" {
        $null = & $script:SSHPath -Context @{ ComputerName = 'node01'; Engine = 'DscV3'; UserName = 'deploy'; KeyFilePath = '/home/deploy/.ssh/id_rsa' }

        Assert-MockCalled -CommandName New-PSSession -ParameterFilter {
            $UserName -eq 'deploy' -and $KeyFilePath -eq '/home/deploy/.ssh/id_rsa'
        } -Exactly 1 -Scope It
    }
}
