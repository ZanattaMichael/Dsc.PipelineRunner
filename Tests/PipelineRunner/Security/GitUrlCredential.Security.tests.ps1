<#
Security regression suite: a credential embedded in a git URL is never printed, and a URL can
never be read by git as an option.

`https://user:token@host/repo.git` is a common way to pass a token, and it passes the scheme
check. The URL then appears in the "Cloned ..." log line, in exception text, and (git being
git) in git's own error output, all of which end up in pipeline logs. The URL given to git is
unchanged; only what is printed is masked. Dummy values only.
#>
Describe "Security: git URL credentials and option-shaped URLs" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'Assert-SecureGitUrl.ps1').FullName
        . (Get-FunctionPath 'Register-RunnerTemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'New-TemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'Remove-RunnerTemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'Clone-Repository.ps1').FullName

        $script:mockClonePath = New-MockDirectoryPath
        Mock New-TemporaryDirectory { return $script:mockClonePath }
        $script:sha = '0123456789abcdef0123456789abcdef01234567'
        $script:token = 'dummy-pat-1a2b3c'
    }

    BeforeEach {
        $script:gitCalls = [System.Collections.Generic.List[object]]::new()
        $script:cloneExit = 0
        $script:cloneOutput = $null
        Mock git {
            $script:gitCalls.Add(@($args))
            if ($args -contains 'clone') { $global:LASTEXITCODE = $script:cloneExit; return $script:cloneOutput }
            $global:LASTEXITCODE = 0
            if ($args -contains 'rev-parse') { return $script:sha }
        }
    }

    Context "Hide-GitUrlCredential" {

        It "masks <Label>" -ForEach @(
            @{ Label = 'user and token';          Url = 'https://svc:dummy-pat-1a2b3c@example.com/org/repo.git'; Expected = 'https://***@example.com/org/repo.git' }
            @{ Label = 'a token used as the user'; Url = 'https://dummy-pat-1a2b3c@example.com/org/repo.git';     Expected = 'https://***@example.com/org/repo.git' }
            @{ Label = 'an ssh password';          Url = 'ssh://svc:dummy-pat-1a2b3c@example.com/org/repo.git';   Expected = 'ssh://svc:***@example.com/org/repo.git' }
        ) {
            Hide-GitUrlCredential -Url $Url | Should -Be $Expected
        }

        It "leaves <Label> as written" -ForEach @(
            @{ Label = 'a plain https URL';   Url = 'https://example.com/org/repo.git' }
            @{ Label = 'an scp-style URL';    Url = 'git@github.com:org/repo.git' }
            @{ Label = 'an ssh URL with a user and no password'; Url = 'ssh://git@example.com/org/repo.git' }
        ) {
            Hide-GitUrlCredential -Url $Url | Should -Be $Url
        }

        It "accepts null and empty input" {
            Hide-GitUrlCredential -Url '' | Should -Be ''
            Hide-GitUrlCredential -Url $null | Should -BeNullOrEmpty
        }
    }

    Context "Clone-Repository" {

        It "does not print the credential on success, but still gives git the real URL" {
            $url = "https://svc:$($script:token)@example.com/org/repo.git"

            $info = Clone-Repository -DatumURLConfig $url 6>&1 | Out-String

            $info | Should -Not -Match ([regex]::Escape($script:token))
            $info | Should -Match 'example.com/org/repo.git'
            $cloneCall = $script:gitCalls | Where-Object { $_[0] -eq 'clone' }
            $cloneCall | Should -Contain $url
        }

        It "does not put the credential in the error when the clone fails, even if git echoes the URL" {
            $script:cloneExit = 128
            $script:cloneOutput = "fatal: unable to access 'https://svc:$($script:token)@example.com/org/repo.git/': The requested URL returned error: 403"
            $thrown = $null

            try { $null = Clone-Repository -DatumURLConfig "https://svc:$($script:token)@example.com/org/repo.git" }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match 'failed with exit code 128'
            $thrown | Should -Not -Match ([regex]::Escape($script:token))
        }

        It "does not put the credential in the revision-verification error" {
            $script:sha = ('f' * 40)
            $thrown = $null

            try { $null = Clone-Repository -DatumURLConfig "https://svc:$($script:token)@example.com/org/repo.git" -Revision ('a' * 40) }
            catch { $thrown = $_.Exception.Message }
            $script:sha = '0123456789abcdef0123456789abcdef01234567'

            $thrown | Should -Match 'Revision verification failed'
            $thrown | Should -Not -Match ([regex]::Escape($script:token))
        }

        It "ends git's option parsing with '--' immediately before the URL" {
            $url = 'https://example.com/org/repo.git'

            $null = Clone-Repository -DatumURLConfig $url

            $cloneCall = @($script:gitCalls | Where-Object { $_[0] -eq 'clone' })[0]
            $position = [array]::IndexOf($cloneCall, '--')
            $position | Should -BeGreaterThan 0
            $cloneCall[$position + 1] | Should -Be $url
        }
    }

    Context "Assert-SecureGitUrl" {

        It "does not echo a credential in the scheme error" {
            $thrown = $null
            try { Assert-SecureGitUrl -Url "http://svc:$($script:token)@example.com/org/repo.git" } catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match "'http' scheme is not permitted"
            $thrown | Should -Not -Match ([regex]::Escape($script:token))
        }

        It "rejects the option-shaped scp-style URL <Url>" -ForEach @(
            @{ Url = '-u@host:path' }
            @{ Url = '--bare@host:x' }
            @{ Url = '-b@host:x' }
            @{ Url = 'git@-oProxyCommand:x' }
            @{ Url = ' -oProxyCommand=evil' }
        ) {
            { Assert-SecureGitUrl -Url $Url } | Should -Throw
        }

        It "still accepts the ordinary scp-style and ssh forms" -ForEach @(
            @{ Url = 'git@github.com:org/repo.git' }
            @{ Url = 'deploy_user@git.example.com:team/config.git' }
            @{ Url = 'ssh://git@example.com/org/repo.git' }
            @{ Url = 'https://example.com/org/repo.git' }
        ) {
            { Assert-SecureGitUrl -Url $Url } | Should -Not -Throw
        }
    }
}
