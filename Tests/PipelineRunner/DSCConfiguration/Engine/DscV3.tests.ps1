Describe "Actions/Engine/DscV3 Tests" -Tag Unit, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName
        $script:DscV3Path = (Get-FunctionPath 'DscV3.ps1').FullName
    }

    It "Maps the method to the dsc resource sub-command and namespaces the resource type" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            param($Arguments, $Executable)
            return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
        }

        $null = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'test' -and
            $Arguments -contains 'Mod/Res'
        }
    }

    It "Returns inDesiredState from the parsed test output" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 0; Output = '{"inDesiredState":false,"differingProperties":["Ensure"]}' }
        }

        $result = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        $result.InDesiredState | Should -BeFalse
        $result.Message | Should -BeLike '*Ensure*'
    }

    It "Throws when dsc.exe exits non-zero" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 2; Output = 'boom' }
        }

        { & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} } } |
            Should -Throw "*exit 2*"
    }

    It "Throws when dsc.exe output is not valid JSON" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            return @{ ExitCode = 0; Output = 'not-json' }
        }

        { & $script:DscV3Path -Context @{ Method = 'Get'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} } } |
            Should -Throw "*Could not parse*"
    }

    Context "Reboot-pending signal (#57 §3)" {

        It "Defaults RebootRequired to false when dsc.exe does not signal it" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $result = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }
            $result.RebootRequired | Should -BeFalse
        }

        It "Reads a top-level rebootRequired flag" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = '{"rebootRequired":true}' }
            }

            $result = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }
            $result.RebootRequired | Should -BeTrue
        }

        It "Reads a nested metadata.Microsoft.DSC.rebootRequired flag" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = '{"metadata":{"Microsoft.DSC":{"rebootRequired":true}}}' }
            }

            $result = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }
            $result.RebootRequired | Should -BeTrue
        }
    }

    Context "Unredacted --input logging fix (#57 §5)" {

        It "Never passes a raw secret value to Write-Verbose" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }
            Mock -CommandName Write-Verbose

            $null = & $script:DscV3Path -Context @{
                Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'
                Property = @{ Name = 'svc'; Password = 'SuperSecretValue123' }
            } -Verbose

            Assert-MockCalled -CommandName Write-Verbose -ParameterFilter {
                $Message -match 'dsc resource' -and $Message -notmatch 'SuperSecretValue123'
            }
        }

        It "Still sends the real, unredacted secret to Invoke-DscExecutable - on standard input, never in argv" {
            $Global:DscV3CapturedArguments = $null
            $Global:DscV3CapturedStandardInput = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:DscV3CapturedArguments = $Arguments
                $Global:DscV3CapturedStandardInput = $StandardInput
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{
                Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'
                Property = @{ Password = 'SuperSecretValue123' }
            }

            $Global:DscV3CapturedStandardInput | Should -Match 'SuperSecretValue123'
            ($Global:DscV3CapturedArguments -join ' ') | Should -Not -Match 'SuperSecretValue123'
            Remove-Variable -Name DscV3CapturedArguments, DscV3CapturedStandardInput -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context "Instance JSON travels over stdin, not the command line" {

        It "Passes --file - and never --input" {
            $Global:DscV3CapturedArguments = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:DscV3CapturedArguments = $Arguments
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{
                Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ Name = 'svc' }
            }

            $Global:DscV3CapturedArguments | Should -Not -Contain '--input'
            $fileIndex = [array]::IndexOf($Global:DscV3CapturedArguments, '--file')
            $fileIndex | Should -BeGreaterOrEqual 0
            $Global:DscV3CapturedArguments[$fileIndex + 1] | Should -Be '-'
            Remove-Variable -Name DscV3CapturedArguments -Scope Global -ErrorAction SilentlyContinue
        }

        It "Sends the serialized properties as the standard input" {
            $Global:DscV3CapturedStandardInput = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:DscV3CapturedStandardInput = $StandardInput
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{
                Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ Name = 'svc'; Port = 8080 }
            }

            $parsed = $Global:DscV3CapturedStandardInput | ConvertFrom-Json
            $parsed.Name | Should -Be 'svc'
            $parsed.Port | Should -Be 8080
            Remove-Variable -Name DscV3CapturedStandardInput -Scope Global -ErrorAction SilentlyContinue
        }

        It "Scrubs a resolved secret out of dsc's error output before throwing" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 2; Output = 'ERROR: schema validation failed for input {"Credential":{"password":"p@ssw0rd"}}' }
            }
            $securePassword = ConvertTo-SecureString -String 'p@ssw0rd' -AsPlainText -Force
            $cred = [System.Management.Automation.PSCredential]::new('svc-account', $securePassword)

            $thrown = $null
            try {
                $null = & $script:DscV3Path -Context @{ Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ Credential = $cred } }
            }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Not -BeNullOrEmpty
            $thrown | Should -Not -Match 'p@ssw0rd'
            $thrown | Should -Match '\[REDACTED\]'
            $thrown | Should -Match 'exit 2'
        }

        It "Scrubs a resolved SecureString out of a JSON parse failure before throwing" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = 'not-json token=hunter2' }
            }
            Mock -CommandName ConvertFrom-Json -MockWith { throw "Unexpected token 'hunter2'" }

            $thrown = $null
            try {
                $null = & $script:DscV3Path -Context @{
                    Method = 'Get'; ModuleName = 'Mod'; Name = 'Res'
                    Property = @{ ApiKey = (ConvertTo-SecureString -String 'hunter2' -AsPlainText -Force) }
                }
            }
            catch { $thrown = $_.Exception.Message }

            $thrown | Should -Match 'Could not parse'
            $thrown | Should -Not -Match 'hunter2'
        }
    }

    Context "Resource-property credential resolution (#57 §5)" {

        It "Converts a PSCredential property into a {username, password} object in the stdin JSON" {
            $Global:DscV3CapturedArguments = $null
            $Global:DscV3CapturedStandardInput = $null
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session, $StandardInput)
                $Global:DscV3CapturedArguments = $Arguments
                $Global:DscV3CapturedStandardInput = $StandardInput
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $securePassword = ConvertTo-SecureString -String 'p@ssw0rd' -AsPlainText -Force
            $cred = [System.Management.Automation.PSCredential]::new('svc-account', $securePassword)

            $null = & $script:DscV3Path -Context @{
                Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'
                Property = @{ Credential = $cred }
            }

            $Global:DscV3CapturedStandardInput | Should -Match 'svc-account'
            $Global:DscV3CapturedStandardInput | Should -Match 'p@ssw0rd'
            ($Global:DscV3CapturedArguments -join ' ') | Should -Not -Match 'p@ssw0rd'
            Remove-Variable -Name DscV3CapturedArguments, DscV3CapturedStandardInput -Scope Global -ErrorAction SilentlyContinue
        }

        It "Force-redacts a resolved credential property from the verbose log regardless of its name" {
            Mock -CommandName Invoke-DscExecutable -MockWith {
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }
            $Global:DscV3VerboseMessages = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Write-Verbose -MockWith {
                param($Message)
                $Global:DscV3VerboseMessages.Add($Message)
            }

            $securePassword = ConvertTo-SecureString -String 'p@ssw0rd' -AsPlainText -Force
            $cred = [System.Management.Automation.PSCredential]::new('svc-account', $securePassword)

            # 'SomeUnnamedThing' deliberately does not match the Test-SensitivePropertyName
            # heuristic (no 'password'/'secret'/'credential'/... substring) - only the fact
            # that it was originally a PSCredential/SecureString should force redaction.
            $null = & $script:DscV3Path -Context @{
                Method = 'Set'; ModuleName = 'Mod'; Name = 'Res'
                Property = @{ SomeUnnamedThing = $cred }
            } -Verbose

            ($Global:DscV3VerboseMessages -join "`n") | Should -Not -Match 'p@ssw0rd'
            Remove-Variable -Name DscV3VerboseMessages -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context "Remote-target execution (#57 §4)" {

        It "Passes the PSSession from Context.Session through to Invoke-DscExecutable" {
            $Global:DscV3CapturedSession = 'unset'
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session)
                $Global:DscV3CapturedSession = $Session
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $fakeSession = [pscustomobject]@{ Marker = 'fake-session' }
            $null = & $script:DscV3Path -Context @{
                Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{}
                Session = [pscustomobject]@{ PSSession = $fakeSession }
            }

            $Global:DscV3CapturedSession | Should -Be $fakeSession
            Remove-Variable -Name DscV3CapturedSession -Scope Global -ErrorAction SilentlyContinue
        }

        It "Passes $null when no Session is supplied (local execution, today's default)" {
            $Global:DscV3CapturedSession = 'unset'
            Mock -CommandName Invoke-DscExecutable -MockWith {
                param($Arguments, $Executable, $Session)
                $Global:DscV3CapturedSession = $Session
                return @{ ExitCode = 0; Output = '{"inDesiredState":true}' }
            }

            $null = & $script:DscV3Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

            $Global:DscV3CapturedSession | Should -BeNullOrEmpty
            Remove-Variable -Name DscV3CapturedSession -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
