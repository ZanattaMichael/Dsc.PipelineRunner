
Describe 'git Function Tests' {

    BeforeAll {

        # Load the functions to test. Unprotect-SecureString backs the SecureString token
        # branch of the wrapper, so it is dot-sourced alongside git itself.
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        . (Get-FunctionPath 'git.ps1').FullName

        Mock Get-Command {

            return @{
                Name = 'git'
                CommandType = 'Application'
                Definition = New-MockFilePath 'git.exe'
            }
        }

    }

    AfterEach {
        # Keep token state and any injected git config out of sibling tests.
        Remove-Variable -Name JITToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    }

    Context 'When called with valid arguments' {
        It 'Should call git with the correct parameters' {
            # Arrange
            $global:JITToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))
            $args = @('clone', 'https://example.com/repo.git')

            # Act
            git @args

            # Assert
            Assert-MockCalled Get-Command -Exactly 1 -Scope It
        }
    }

    Context 'When git command fails' {
        It 'Should catch and return the error' {
            # Arrange
            $global:JITToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))
            $args = @('invalid-command')

            Mock Get-Command { throw "git command not found" }

            # Act
            $result = git @args

            # Assert
            $result | Should -Be "git command not found"
        }
    }

    Context 'Token handling' {

        It 'Removes the injected GIT_CONFIG_* variables after the call' {
            $global:JITToken = 'some-token'

            git @('status')

            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
            $env:GIT_CONFIG_KEY_0 | Should -BeNullOrEmpty
            $env:GIT_CONFIG_VALUE_0 | Should -BeNullOrEmpty
        }

        It 'Accepts a SecureString token and never returns it in the output' {
            $global:JITToken = ConvertTo-SecureString -String 'secret-xyz' -AsPlainText -Force

            $result = git @('clone', 'https://example.com/repo.git')

            ($result | Out-String) | Should -Not -Match 'secret-xyz'
            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
        }

        It 'Injects no git config when no token is present' {
            Remove-Variable -Name JITToken -Scope Global -ErrorAction SilentlyContinue

            git @('status')

            Assert-MockCalled Get-Command -Exactly 1 -Scope It
            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
        }
    }
}
