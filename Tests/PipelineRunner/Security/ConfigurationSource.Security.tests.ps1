<#
Security regression suite: the way a configuration is fetched and the way actions are located
cannot be turned against the runner.

Covers the controls SECURITY.md promises for the clone (transport, revision pinning, argument
hygiene), the action loader's confinement to Actions/<Hook>/, and the temporary-directory
cleanup that must never touch a caller-owned path.
#>
Describe "Security: configuration source and action loading" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'Assert-SecureGitUrl.ps1').FullName
        . (Get-FunctionPath 'Register-RunnerTemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'New-TemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'Remove-RunnerTemporaryDirectory.ps1').FullName
        . (Get-FunctionPath 'Clone-Repository.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
    }

    Context "remote URL" {

        It "rejects an unencrypted or unauthenticated transport (<Url>)" -TestCases @(
            @{ Url = 'http://example.com/org/repo.git' }
            @{ Url = 'git://example.com/org/repo.git' }
            @{ Url = 'ftp://example.com/org/repo.git' }
            @{ Url = 'file:///srv/git/repo.git' }
            @{ Url = 'HTTP://example.com/org/repo.git' }
        ) {
            param($Url)
            { Assert-SecureGitUrl -Url $Url } | Should -Throw
        }

        It "rejects a URL shaped to inject an option or an ssh ProxyCommand (<Url>)" -TestCases @(
            @{ Url = '--upload-pack=touch /tmp/pwned' }
            @{ Url = '-oProxyCommand=touch /tmp/pwned' }
            @{ Url = 'ssh://-oProxyCommand=touch%20/tmp/pwned/repo.git' }
            @{ Url = '-oProxyCommand=evil@example.com:org/repo.git' }
            @{ Url = 'ext::sh -c touch% /tmp/pwned' }
        ) {
            param($Url)
            { Assert-SecureGitUrl -Url $Url } | Should -Throw
        }

        It "never invokes git for a rejected URL" {
            $script:gitCalls = [System.Collections.Generic.List[object]]::new()
            Mock git { $script:gitCalls.Add(@($args)); $global:LASTEXITCODE = 0 }

            foreach ($url in 'http://example.com/repo.git', 'git://example.com/repo.git', '--upload-pack=x') {
                { Clone-Repository -DatumURLConfig $url } | Should -Throw
            }

            $script:gitCalls.Count | Should -Be 0
        }
    }

    Context "revision pinning" {

        BeforeAll {
            $script:mockClonePath = New-MockDirectoryPath
            Mock New-TemporaryDirectory { return $script:mockClonePath }
        }

        BeforeEach {
            $script:gitCalls = [System.Collections.Generic.List[object]]::new()
            Mock git {
                $script:gitCalls.Add(@($args))
                $global:LASTEXITCODE = 0
                if ($args -contains 'rev-parse') { return '0123456789abcdef0123456789abcdef01234567' }
            }
        }

        It "rejects an option-shaped revision before any git call (<Revision>)" -TestCases @(
            @{ Revision = '--orphan' }
            @{ Revision = '-b evil' }
            @{ Revision = ' --force' }
            @{ Revision = '-' }
            @{ Revision = '--' }
        ) {
            param($Revision)
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision $Revision } |
                Should -Throw -ExpectedMessage "*may not begin with '-'*"
            $script:gitCalls.Count | Should -Be 0
        }

        It "always terminates the checkout argument list with -- so the revision is parsed as a ref" {
            Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision 'feature/x'

            $checkout = @($script:gitCalls | Where-Object { $_ -contains 'checkout' })[0]
            $checkout[-1] | Should -Be '--'
            $checkout[-2] | Should -Be 'feature/x'
        }

        It "fails the run when a pinned full SHA does not match the resolved HEAD" {
            { Clone-Repository -DatumURLConfig 'https://example.com/repo.git' -Revision ('f' * 40) } |
                Should -Throw -ExpectedMessage '*Revision verification failed*'
        }
    }

    Context "action loader confinement" {

        BeforeAll {
            Mock -CommandName Get-Module -MockWith { return @{ moduleBase = $TestDrive } }

            # A script OUTSIDE Actions/ that flips a canary if it is ever executed.
            $script:escapePath = Join-Path $TestDrive 'Escaped.ps1'
            @'
param([hashtable]$Context = @{})
$Global:ActionEscapeCanary = 'EXECUTED'
return 'escaped'
'@ | Set-Content -Path $script:escapePath

            $null = New-Item -Path (Join-Path $TestDrive 'Actions/Credential') -ItemType Directory -Force
        }

        AfterEach { Remove-Variable -Name ActionEscapeCanary -Scope Global -ErrorAction SilentlyContinue }

        It "never executes a script outside Actions/<Hook>/ for name '<Name>' on hook <Hook>" -TestCases @(
            @{ Hook = 'Credential'; Name = '../../Escaped' }
            @{ Hook = 'Credential'; Name = '..\..\Escaped' }
            @{ Hook = 'Target';     Name = '../../Escaped' }
            @{ Hook = 'Source';     Name = '/Escaped' }
            @{ Hook = 'Engine';     Name = 'Sub/../../Escaped' }
            @{ Hook = 'Connect';    Name = '.Escaped' }
        ) {
            param($Hook, $Name)
            $Global:ActionEscapeCanary = $null

            { Invoke-Action -Hook $Hook -Name $Name -Context @{} } | Should -Throw '*not valid*'

            $Global:ActionEscapeCanary | Should -BeNullOrEmpty
        }

        It "resolves to a file strictly under Actions/<Hook>/ for an accepted name" {
            $good = Join-Path $TestDrive 'Actions/Credential/Fixture.ps1'
            "param([hashtable]`$Context = @{}); return 'ok'" | Set-Content -Path $good

            Invoke-Action -Hook Credential -Name 'Fixture' -Context @{} | Should -Be 'ok'
            $Global:ActionEscapeCanary | Should -BeNullOrEmpty
        }
    }

    Context "temporary-directory cleanup" {

        It "never deletes a caller-owned directory, even when asked to" {
            $callerOwned = Join-Path $TestDrive 'caller-owned-config'
            $null = New-Item -ItemType Directory -Path $callerOwned -Force
            'keep me' | Set-Content -Path (Join-Path $callerOwned 'Datum.yml')

            Remove-RunnerTemporaryDirectory -Path $callerOwned

            Test-Path -LiteralPath (Join-Path $callerOwned 'Datum.yml') | Should -BeTrue
        }

        It "deletes only a directory the runner itself registered" {
            $runnerOwned = Join-Path $TestDrive 'runner-owned'
            $null = New-Item -ItemType Directory -Path $runnerOwned -Force
            Register-RunnerTemporaryDirectory -Path $runnerOwned

            Remove-RunnerTemporaryDirectory -Path $runnerOwned

            Test-Path -LiteralPath $runnerOwned | Should -BeFalse
        }
    }
}
