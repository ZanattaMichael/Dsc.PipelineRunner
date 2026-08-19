Describe "Invoke-Action Function Tests" -Tag Unit, Actions {

    BeforeAll {

        # Load the function under test
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName

        # Point the loader's module-base resolution at the TestDrive so that
        # Actions/<Hook>/<Name>.ps1 resolves to files we create below.
        Mock -CommandName Get-Module -MockWith {
            return @{ moduleBase = $TestDrive }
        }

        # Drop a named Source action on disk that echoes back a value from its context.
        $actionPath = Join-Path $TestDrive 'Actions\Source\Fixture.ps1'
        $null = New-Item -Path (Split-Path $actionPath) -ItemType Directory -Force
        @'
param([hashtable]$Context = @{})
return "resolved:$($Context.Path)"
'@ | Set-Content -Path $actionPath

    }

    Context "Inline scriptblock override" {

        It "Runs the inline scriptblock and returns its result" {
            $result = Invoke-Action -Hook Source -ScriptBlock {
                param($Context)
                return "inline:$($Context.Value)"
            } -Context @{ Value = 'abc' }

            $result | Should -Be 'inline:abc'
        }

        It "Prefers the inline scriptblock over a -Name" {
            $result = Invoke-Action -Hook Source -Name 'Fixture' -ScriptBlock {
                param($Context)
                return 'from-scriptblock'
            } -Context @{ Path = 'ignored' }

            $result | Should -Be 'from-scriptblock'
        }
    }

    Context "Named action resolution" {

        It "Resolves and runs Actions/<Hook>/<Name>.ps1 passing the context" {
            $result = Invoke-Action -Hook Source -Name 'Fixture' -Context @{ Path = 'C:\config' }
            $result | Should -Be 'resolved:C:\config'
        }

        It "Throws when the named action file does not exist" {
            { Invoke-Action -Hook Source -Name 'DoesNotExist' -Context @{} } |
                Should -Throw "*was not found*"
        }
    }

    Context "Input validation" {

        It "Throws when neither -Name nor -ScriptBlock is supplied" {
            { Invoke-Action -Hook Connect -Context @{} } |
                Should -Throw "*No action name or -ScriptBlock supplied*"
        }

        It "Rejects an unknown hook" {
            { Invoke-Action -Hook 'Bogus' -Name 'Fixture' } | Should -Throw
        }
    }

}
