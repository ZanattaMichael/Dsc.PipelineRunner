
Describe 'Clone-Repository Function Tests' {

    BeforeAll {

        # Load the functions to test.
        . (Get-FunctionPath 'Assert-SecureGitUrl.ps1').FullName
        . (Get-FunctionPath 'Register-RunnerTemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'New-TemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'Clone-Repository.ps1').FullName

        $script:mockClonePath = New-MockDirectoryPath

        Mock New-TemporaryDirectory { return $script:mockClonePath }

        # Record every git invocation so the arguments can be asserted - the original
        # suite only counted calls, which is how `git clone True <dir>` survived (#9).
        $script:gitCalls = [System.Collections.Generic.List[object]]::new()
        Mock git {
            $script:gitCalls.Add(@($args))
            $global:LASTEXITCODE = 0
            if ($args -contains 'rev-parse') {
                return '0123456789abcdef0123456789abcdef01234567'
            }
        }
    }

    BeforeEach {
        $script:gitCalls.Clear()
    }

    Context 'When called with valid parameters' {

        It 'Should return the clone directory as a string' {
            $result = Clone-Repository -DatumURLConfig 'https://example.com/repo.git'

            $result | Should -Be $script:mockClonePath
        }

        It 'Should pass the repository URL and destination path to git clone' {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git'

            $cloneCall = $script:gitCalls | Where-Object { $_[0] -eq 'clone' }
            $cloneCall | Should -Not -BeNullOrEmpty
            $cloneCall | Should -Contain 'https://example.com/repo.git'
            $cloneCall | Should -Contain $script:mockClonePath
            $cloneCall | Should -Contain '--single-branch'
        }

        It 'Should never pass a boolean in place of the URL' {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git'

            $cloneCall = $script:gitCalls | Where-Object { $_[0] -eq 'clone' }
            $cloneCall | Should -Not -Contain $true
            $cloneCall | Should -Not -Contain 'True'
        }

        It 'Should clone into an explicit -DestinationPath when supplied' {
            $destination = Join-Path $TestDrive 'explicit-destination'

            $result = Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -DestinationPath $destination

            $result | Should -Be $destination
            Assert-MockCalled New-TemporaryDirectory -Exactly 0 -Scope It
        }

        It 'Should log the resolved HEAD commit on the information stream' {
            $information = @()
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -InformationVariable information

            ($information | Out-String) | Should -Match '0123456789abcdef0123456789abcdef01234567'
        }
    }

    Context 'When the URL uses an insecure or invalid scheme' {

        It 'Should throw for an http:// URL' {
            { Clone-Repository -DatumURLConfig 'http://example.com/repo.git' } |
                Should -Throw -ExpectedMessage "*http*not permitted*"
        }

        It 'Should throw for a git:// URL' {
            { Clone-Repository -DatumURLConfig 'git://example.com/repo.git' } |
                Should -Throw -ExpectedMessage "*not permitted*"
        }

        It 'Should throw for a malformed URL' {
            { Clone-Repository -DatumURLConfig 'invalid-url' } | Should -Throw
        }

        It 'Should not invoke git when the URL is rejected' {
            { Clone-Repository -DatumURLConfig 'http://example.com/repo.git' } | Should -Throw
            $script:gitCalls.Count | Should -Be 0
        }

        It 'Should accept an ssh:// URL' {
            { Clone-Repository -DatumURLConfig 'ssh://git@example.com/repo.git' } | Should -Not -Throw
        }

        It 'Should accept an SCP-style git@host:path URL' {
            { Clone-Repository -DatumURLConfig 'git@example.com:org/repo.git' } | Should -Not -Throw
        }
    }

    Context 'When a revision is supplied' {

        It 'Should check out the requested revision' {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision 'v1.2.3'

            $checkout = $script:gitCalls | Where-Object { $_ -contains 'checkout' }
            $checkout | Should -Not -BeNullOrEmpty
            $checkout | Should -Contain 'v1.2.3'
        }

        It 'Should not check out anything when no revision is supplied' {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git'

            $checkout = $script:gitCalls | Where-Object { $_ -contains 'checkout' }
            $checkout | Should -BeNullOrEmpty
        }

        It 'Should accept a matching full commit SHA' {
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' `
                               -Revision '0123456789abcdef0123456789abcdef01234567' } | Should -Not -Throw
        }

        It 'Should throw when the resolved HEAD does not match the pinned SHA' {
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' `
                               -Revision 'ffffffffffffffffffffffffffffffffffffffff' } |
                Should -Throw -ExpectedMessage "*Revision verification failed*"
        }

        It 'Should throw when the checkout fails' {
            Mock git {
                $script:gitCalls.Add(@($args))
                if ($args -contains 'checkout') { $global:LASTEXITCODE = 1; return 'pathspec not found' }
                $global:LASTEXITCODE = 0
                if ($args -contains 'rev-parse') { return '0123456789abcdef0123456789abcdef01234567' }
            }

            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision 'no-such-branch' } |
                Should -Throw -ExpectedMessage "*Could not check out revision*"
        }

        It 'Should refuse a revision that begins with a dash before calling git' {
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision '--orphan' } |
                Should -Throw -ExpectedMessage "*may not begin with '-'*"
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision ' -b' } |
                Should -Throw -ExpectedMessage "*may not begin with '-'*"

            $script:gitCalls.Count | Should -Be 0
        }

        It 'Should terminate the checkout argument list with -- so the revision is never read as an option or path' {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision 'v1.2.3'

            $checkout = @($script:gitCalls | Where-Object { $_ -contains 'checkout' })[0]
            $checkout[-1] | Should -Be '--'
            $checkout[-2] | Should -Be 'v1.2.3'
        }
    }

    Context 'When git clone fails' {

        It 'Should throw with the git exit code' {
            Mock git {
                $script:gitCalls.Add(@($args))
                $global:LASTEXITCODE = 128
                return 'repository not found'
            }

            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' } |
                Should -Throw -ExpectedMessage "*exit code 128*"
        }
    }
}
