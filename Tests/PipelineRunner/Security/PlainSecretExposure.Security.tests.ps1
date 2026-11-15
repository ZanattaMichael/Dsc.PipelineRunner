<#
Security regression suite: plain-string secrets, and secrets nested in lists, never reach an
output stream.

SecretExposure.Security.tests.ps1 pins the [PSCredential] / [SecureString] cases, where the
engine knows for certain that a value is a secret. A secret is just as often a plain string
under a conventionally sensitive name (adminPassword: 'x'), or sits inside a list of mappings
(users: [{login, password}]). dsc echoes its input back on a schema failure, and the runner
copies error text into the log, the CSV and the JSON report, so each of these shapes has to be
scrubbed as well. Dummy values only.
#>
Describe "Security: plain-string and list-nested secrets never reach an output stream" -Tag Unit, Security {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        $script:DscV3Path = (Get-FunctionPath 'DscV3.ps1').FullName

        $script:plainPassword = 'plain-pw-9c2d'
        $script:listPasswords = @('arr-pw-1a2b', 'arr-pw-3c4d')
        $script:buildProperty = {
            @{
                Name          = 'svc'
                adminPassword = $script:plainPassword
                users         = @(
                    @{ login = 'a'; password = $script:listPasswords[0] },
                    @{ login = 'b'; password = $script:listPasswords[1] }
                )
            }
        }
        $script:invokeFailing = {
            param($Property)
            $thrown = $null
            try { $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = $Property } }
            catch { $thrown = $_.Exception.Message }
            return $thrown
        }
    }

    BeforeEach {
        $Global:PlainSecStdin = $null
        Mock -CommandName Invoke-DscExecutable -MockWith {
            param($Arguments, $Executable, $Session, $StandardInput)
            $Global:PlainSecStdin = $StandardInput
            # dsc echoing the whole offending input back on a schema failure.
            return @{ ExitCode = 2; Output = "ERROR: invalid input: $StandardInput" }
        }
    }

    AfterAll {
        Remove-Variable -Name PlainSecStdin -Scope Global -ErrorAction SilentlyContinue
    }

    It "scrubs a plain-string secret under a sensitive name from the thrown error" {
        $thrown = & $script:invokeFailing (& $script:buildProperty)

        $thrown | Should -Match 'exit 2'
        $thrown | Should -Not -Match ([regex]::Escape($script:plainPassword))
    }

    It "scrubs every secret held in a list of mappings from the thrown error" {
        $thrown = & $script:invokeFailing (& $script:buildProperty)

        $thrown | Should -Match 'exit 2'
        foreach ($secret in $script:listPasswords) {
            $thrown | Should -Not -Match ([regex]::Escape($secret))
        }
    }

    It "still delivers every plaintext secret to dsc over standard input" {
        $null = & $script:invokeFailing (& $script:buildProperty)

        $Global:PlainSecStdin | Should -Match ([regex]::Escape($script:plainPassword))
        foreach ($secret in $script:listPasswords) {
            $Global:PlainSecStdin | Should -Match ([regex]::Escape($secret))
        }
    }

    It "scrubs a plain-string list under a sensitive name" {
        $property = @{ Name = 'svc'; passwords = @('list-pw-77aa', 'list-pw-88bb') }
        $thrown = & $script:invokeFailing $property

        $thrown | Should -Not -Match 'list-pw-77aa'
        $thrown | Should -Not -Match 'list-pw-88bb'
    }

    It "replaces a secret that contains another secret whole, leaving no tail behind" {
        # 'pw-abcd' is a prefix of the longer secret. Replaced shortest-first, the longer one
        # would come out as '[REDACTED]-extended-tail'.
        $property = @{ Name = 'svc'; shortPassword = 'pw-abcd'; longPassword = 'pw-abcd-extended-tail' }
        $thrown = & $script:invokeFailing $property

        $thrown | Should -Not -Match 'extended-tail'
        $thrown | Should -Not -Match 'pw-abcd'
    }

    It "does not scrub values that are not under a sensitive name" {
        # Guards against over-redaction: ordinary values stay readable in dsc's error text.
        $property = @{ Name = 'svc-readable-name'; adminPassword = $script:plainPassword }
        $thrown = & $script:invokeFailing $property

        $thrown | Should -Match 'svc-readable-name'
        $thrown | Should -Not -Match ([regex]::Escape($script:plainPassword))
    }

    It "never writes a list-nested secret to the verbose stream" {
        Mock -CommandName Invoke-DscExecutable -MockWith { return @{ ExitCode = 0; Output = '{"inDesiredState":true}' } }
        $Global:PlainSecVerbose = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Verbose -MockWith { param($Message) $Global:PlainSecVerbose.Add([string]$Message) }

        $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = (& $script:buildProperty) } -Verbose

        $joined = $Global:PlainSecVerbose -join "`n"
        $joined | Should -Match 'dsc resource set'
        $joined | Should -Not -Match ([regex]::Escape($script:plainPassword))
        foreach ($secret in $script:listPasswords) {
            $joined | Should -Not -Match ([regex]::Escape($secret))
        }
        # The non-secret members of the list are still logged, so the breadcrumb stays useful.
        $joined | Should -Match 'login'
        Remove-Variable -Name PlainSecVerbose -Scope Global -ErrorAction SilentlyContinue
    }
}
