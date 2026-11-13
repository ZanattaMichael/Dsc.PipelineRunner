<#
Security regression suite: secrets never reach a process command line or an output stream.

Each test here pins an invariant that was broken once and fixed in the 2026-10 security audit
(PR #70). They are deliberately broader than the per-fix unit tests next to the code: they
exercise several secret shapes at once and assert over the WHOLE argument vector / output /
error, so a future refactor that re-introduces any variant of the leak fails loudly here.
#>
Describe "Security: secrets never reach argv or an output stream" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-BasicAuthCredential.ps1').FullName
        . (Get-FunctionPath 'git.ps1').FullName
        $script:DscV3Path = (Get-FunctionPath 'DscV3.ps1').FullName

        # One property bag with every secret shape the engine can meet: a [PSCredential], a bare
        # [SecureString], a plaintext value under a conventionally sensitive name, a credential
        # under a name the heuristic would never catch, and a credential nested in a sub-table.
        $script:secrets = @{
            CredPassword   = 'Cr3d-P@ss!"\quoted'
            ApiKeyValue    = 'api-key-7f3a'
            PlainPassword  = 'plain-pw-9c2d'
            UnnamedSecret  = 'unnamed-5e1b'
            NestedPassword = 'nested-0a4f'
        }
        $script:secretProperty = {
            $cred = [System.Management.Automation.PSCredential]::new('svc', (ConvertTo-SecureString $script:secrets.CredPassword -AsPlainText -Force))
            $unnamed = [System.Management.Automation.PSCredential]::new('svc2', (ConvertTo-SecureString $script:secrets.UnnamedSecret -AsPlainText -Force))
            $nested = [System.Management.Automation.PSCredential]::new('svc3', (ConvertTo-SecureString $script:secrets.NestedPassword -AsPlainText -Force))
            @{
                Name             = 'svc'
                Credential       = $cred
                ApiKey           = (ConvertTo-SecureString $script:secrets.ApiKeyValue -AsPlainText -Force)
                Password         = $script:secrets.PlainPassword
                SomeUnnamedThing = $unnamed
                Connection       = @{ Server = 'sql01'; Login = $nested }
            }
        }
    }

    Context "DscV3 engine" {

        It "never places any secret value in the dsc argument vector" {
            $Global:SecArgs = $null; $Global:SecStdin = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:SecArgs = $Arguments; $Global:SecStdin = $StandardInput
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:secretProperty) }

            $argv = $Global:SecArgs -join ' '
            foreach ($secret in $script:secrets.Values) {
                $argv | Should -Not -Match ([regex]::Escape($secret))
                # Every secret still reaches dsc, over standard input.
                $Global:SecStdin | Should -Match ([regex]::Escape(([string](ConvertTo-Json $secret -Compress)).Trim('"')))
            }
            Remove-Variable -Name SecArgs, SecStdin -Scope Global -ErrorAction SilentlyContinue
        }

        It "keeps the argument vector to the fixed, secret-free shape: resource <verb> --resource <type> --file -" {
            $Global:SecArgs = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:SecArgs = $Arguments
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:secretProperty) }

            @($Global:SecArgs) | Should -Be @('resource', 'test', '--resource', 'Mod/Res', '--file', '-')
            @($Global:SecArgs) | Should -Not -Contain '--input'
            Remove-Variable -Name SecArgs -Scope Global -ErrorAction SilentlyContinue
        }

        It "never writes any secret value to the verbose stream" {
            Mock -CommandName Invoke-DscExecutable -MockWith { return @{ ExitCode = 0; Output = '{"inDesiredState":true}' } }
            $Global:SecVerbose = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Write-Verbose -MockWith { param($Message) $Global:SecVerbose.Add([string]$Message) }

            $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:secretProperty) } -Verbose

            $joined = $Global:SecVerbose -join "`n"
            $joined | Should -Match 'dsc resource set'
            foreach ($secret in $script:secrets.Values) { $joined | Should -Not -Match ([regex]::Escape($secret)) }
            Remove-Variable -Name SecVerbose -Scope Global -ErrorAction SilentlyContinue
        }

        It "never echoes a resolved secret in the error thrown when dsc fails, even JSON-escaped" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                # Simulate dsc echoing the whole offending input back on a schema failure.
                return @{ ExitCode = 2; Output = "ERROR: invalid input: $StandardInput" }
            }

            $thrown = $null
            try { $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:secretProperty) } }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match 'exit 2'
            foreach ($secret in 'CredPassword', 'ApiKeyValue', 'UnnamedSecret', 'NestedPassword') {
                $thrown | Should -Not -Match ([regex]::Escape($script:secrets[$secret]))
                $thrown | Should -Not -Match ([regex]::Escape(([string](ConvertTo-Json $script:secrets[$secret] -Compress)).Trim('"')))
            }
        }

        It "never echoes a resolved secret in a JSON parse failure" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                return @{ ExitCode = 0; Output = "garbage $StandardInput" }
            }
            Mock -CommandName ConvertFrom-Json -MockWith { param([Parameter(ValueFromPipeline)]$InputObject) throw "Unexpected token: $InputObject" }

            $thrown = $null
            try { $null = & $script:DscV3Path -Context @{ Method = 'Get'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:secretProperty) } }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match 'Could not parse'
            foreach ($secret in 'CredPassword', 'ApiKeyValue', 'UnnamedSecret', 'NestedPassword') {
                $thrown | Should -Not -Match ([regex]::Escape($script:secrets[$secret]))
            }
        }

        It "static guard: the engine source never passes --input to dsc" {
            # The whole point of the stdin transport is that the instance JSON is never an argv
            # entry. Fail fast if someone re-introduces the flag anywhere in the engine action.
            (Get-Content -LiteralPath $script:DscV3Path -Raw) | Should -Not -Match "'--input'"
        }
    }

    Context "Invoke-DscExecutable transport" {

        It "delivers -StandardInput on the child's stdin and never on its command line" {
            # The child prints its own argv and its stdin, so this is a direct observation of
            # what an attacker reading the process table would see.
            $marker = 'stdin-secret-3b9e'
            $result = Invoke-DscExecutable -Executable (Get-Process -Id $PID).Path `
                -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output ("ARGV=" + ([Environment]::GetCommandLineArgs() -join " ")); Write-Output ("STDIN=" + ($input -join ""))') `
                -StandardInput $marker

            $result.ExitCode | Should -Be 0
            $argvLine  = ($result.Output -split "`n" | Where-Object { $_ -like 'ARGV=*' }) -join ''
            $stdinLine = ($result.Output -split "`n" | Where-Object { $_ -like 'STDIN=*' }) -join ''
            $argvLine  | Should -Not -Match $marker
            $stdinLine | Should -Match $marker
        }
    }

    Context "git wrapper" {

        AfterEach {
            Remove-Variable -Name JITToken -Scope Global -ErrorAction SilentlyContinue
            Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
        }

        $tokenForms = @(
            @{ Form = 'raw PAT';        Token = { 'raw-pat-secret-11aa' };                                                                 Plain = 'raw-pat-secret-11aa' }
            @{ Form = 'SecureString';   Token = { ConvertTo-SecureString 'secure-pat-22bb' -AsPlainText -Force };                          Plain = 'secure-pat-22bb' }
            @{ Form = 'encoded pair';   Token = { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('user:pair-secret-33cc')) };    Plain = 'pair-secret-33cc' }
        )

        It "never returns the <Form> token, raw or encoded, in stdout, merged stderr or a thrown error" -TestCases $tokenForms {
            param($Form, $Token, $Plain)
            $global:JITToken = & $Token
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$Plain"))

            # stdout + stderr path
            Mock Get-Command { return { "out: $env:GIT_CONFIG_VALUE_0"; Write-Error "err: $env:GIT_CONFIG_VALUE_0" } }
            $output = (git @('clone', 'https://example.com/org/repo.git')) -join "`n"
            $output | Should -Not -Match ([regex]::Escape($Plain))
            $output | Should -Not -Match ([regex]::Escape($encoded))
            if ($Form -eq 'encoded pair') { $output | Should -Not -Match ([regex]::Escape([string]$global:JITToken)) }

            # thrown-error path
            Mock Get-Command { throw "spawn failed: $env:GIT_CONFIG_VALUE_0" }
            $output = (git @('clone', 'https://example.com/org/repo.git')) -join "`n"
            $output | Should -Not -Match ([regex]::Escape($Plain))
            $output | Should -Not -Match ([regex]::Escape($encoded))
        }

        It "never leaves the credential in the environment after the call, including when git throws" {
            $global:JITToken = 'linger-check-44dd'

            Mock Get-Command { return { 'ok' } }
            $null = git @('clone', 'https://example.com/org/repo.git')
            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
            $env:GIT_CONFIG_VALUE_0 | Should -BeNullOrEmpty

            Mock Get-Command { throw 'boom' }
            $null = git @('clone', 'https://example.com/org/repo.git')
            $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
            $env:GIT_CONFIG_VALUE_0 | Should -BeNullOrEmpty
        }

        It "never configures an unscoped http.extraHeader" {
            $global:JITToken = 'scope-check-55ee'
            $script:capturedKey = 'unset'
            Mock Get-Command { $script:capturedKey = $env:GIT_CONFIG_KEY_0; return { 'ok' } }

            $null = git @('clone', 'https://dev.azure.com/org/project/_git/config')

            $script:capturedKey | Should -Not -Be 'http.extraHeader'
            $script:capturedKey | Should -Be 'http.https://dev.azure.com/.extraHeader'
        }

        It "never presents the credential to a remote that is not https (<Remote>)" -TestCases @(
            @{ Remote = 'ssh://git@example.com/org/repo.git' }
            @{ Remote = 'git@example.com:org/repo.git' }
            @{ Remote = 'http://example.com/org/repo.git' }
            @{ Remote = 'git://example.com/org/repo.git' }
        ) {
            param($Remote)
            $global:JITToken = 'non-https-66ff'
            $script:capturedKey = 'unset'
            Mock Get-Command { $script:capturedKey = $env:GIT_CONFIG_KEY_0; return { 'ok' } }

            $null = git @('clone', $Remote)

            $script:capturedKey | Should -BeNullOrEmpty
        }

        It "never puts the token on git's own command line" {
            $global:JITToken = 'argv-check-77aa'
            $script:capturedArgs = $null
            Mock Get-Command { return { $script:capturedArgs = $args } }

            $null = git @('clone', 'https://example.com/org/repo.git')

            ($script:capturedArgs -join ' ') | Should -Not -Match 'argv-check-77aa'
            ($script:capturedArgs -join ' ') | Should -Not -Match 'Authorization'
        }

        It "static guard: the wrapper source never sets the global http.extraHeader key" {
            (Get-Content -LiteralPath (Get-FunctionPath 'git.ps1').FullName -Raw) | Should -Not -Match "=\s*'http\.extraHeader'"
        }
    }
}
