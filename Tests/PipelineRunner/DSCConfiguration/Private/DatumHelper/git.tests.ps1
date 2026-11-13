
Describe 'git Function Tests' {

    BeforeAll {

        # Load the functions to test. Unprotect-SecureString backs the SecureString token
        # branch of the wrapper, so it is dot-sourced alongside git itself.
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-BasicAuthCredential.ps1').FullName
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

    Context 'Authorization header encoding' {

        # The wrapper clears GIT_CONFIG_* in its finally block, so capture the header from
        # inside the mocked git invocation instead of reading it after the call returns.
        BeforeEach {
            $script:capturedHeader = $null
            Mock Get-Command {
                $script:capturedHeader = $env:GIT_CONFIG_VALUE_0
                return @{
                    Name        = 'git'
                    CommandType = 'Application'
                    Definition  = New-MockFilePath 'git.exe'
                }
            }
        }

        It 'Base64-encodes a raw token into a Basic credential' {
            # A raw PAT was previously placed into the header verbatim, producing a
            # malformed Authorization value and failing every authenticated clone (#9).
            $global:JITToken = 'a-raw-personal-access-token'

            git @('clone', 'https://example.com/repo.git')

            $script:capturedHeader | Should -Match '^Authorization: Basic '
            $credential = $script:capturedHeader -replace '^Authorization: Basic ', ''
            $credential | Should -Not -Be 'a-raw-personal-access-token'
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($credential)) |
                Should -Be 'x-access-token:a-raw-personal-access-token'
        }

        It 'Passes an already-encoded credential through unchanged' {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('username:password'))
            $global:JITToken = $encoded

            git @('clone', 'https://example.com/repo.git')

            $script:capturedHeader | Should -Be "Authorization: Basic $encoded"
        }

        It 'Encodes a SecureString token' {
            $global:JITToken = ConvertTo-SecureString -String 'secure-pat-value' -AsPlainText -Force

            git @('clone', 'https://example.com/repo.git')

            $credential = $script:capturedHeader -replace '^Authorization: Basic ', ''
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($credential)) |
                Should -Be 'x-access-token:secure-pat-value'
        }
    }

    Context 'Authorization header scoping' {

        BeforeEach {
            $script:capturedKey = 'unset'
            Mock Get-Command {
                $script:capturedKey = $env:GIT_CONFIG_KEY_0
                return @{
                    Name        = 'git'
                    CommandType = 'Application'
                    Definition  = New-MockFilePath 'git.exe'
                }
            }
        }

        It 'Scopes the header to the origin of the https remote instead of every host git contacts' {
            $global:JITToken = 'a-raw-personal-access-token'

            git @('clone', '--single-branch', 'https://dev.azure.com/org/project/_git/config', '/tmp/dest')

            $script:capturedKey | Should -Be 'http.https://dev.azure.com/.extraHeader'
        }

        It 'Keeps a non-default port in the scope' {
            $global:JITToken = 'a-raw-personal-access-token'

            git @('clone', 'https://git.internal:8443/org/repo.git')

            $script:capturedKey | Should -Be 'http.https://git.internal:8443/.extraHeader'
        }

        It 'Injects no header at all for a call that names no https remote' {
            $global:JITToken = 'a-raw-personal-access-token'

            git @('-C', '/tmp/dest', 'checkout', '--quiet', 'main', '--')

            $script:capturedKey | Should -BeNullOrEmpty
            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
        }

        It 'Does not treat an ssh remote as a reason to send the HTTP credential' {
            $global:JITToken = 'a-raw-personal-access-token'

            git @('clone', 'git@github.com:org/repo.git')

            $script:capturedKey | Should -BeNullOrEmpty
        }
    }

    Context 'Output redaction' {

        BeforeAll {
            $script:rawToken = 'secret-xyz-token'
            $script:encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$script:rawToken"))
        }

        It 'Scrubs the raw token and the encoded credential from stdout' {
            $global:JITToken = $script:rawToken
            # Stand a script block in for git.exe: `& $command @args` invokes it like the application.
            Mock Get-Command { return { "trace: sending '$env:GIT_CONFIG_VALUE_0' for secret-xyz-token" } }

            $result = (git @('clone', 'https://example.com/repo.git')) -join "`n"

            $result | Should -Not -Match 'secret-xyz-token'
            $result | Should -Not -Match ([regex]::Escape($script:encoded))
            $result | Should -Match '\*\*\*'
        }

        It 'Scrubs stderr that is merged into the returned output' {
            $global:JITToken = $script:rawToken
            Mock Get-Command { return { Write-Error "fatal: Authorization: Basic $($env:GIT_CONFIG_VALUE_0 -replace '^Authorization: Basic ','') rejected" } }

            $result = (git @('clone', 'https://example.com/repo.git')) -join "`n"

            $result | Should -Not -Match ([regex]::Escape($script:encoded))
            $result | Should -Match '\*\*\*'
        }

        It 'Scrubs the encoded credential from a thrown error' {
            $global:JITToken = $script:rawToken
            Mock Get-Command { throw "spawn failed; header was $script:encoded" }

            $result = (git @('clone', 'https://example.com/repo.git')) -join "`n"

            $result | Should -Not -Match ([regex]::Escape($script:encoded))
            $result | Should -Be 'spawn failed; header was ***'
        }
    }
}
