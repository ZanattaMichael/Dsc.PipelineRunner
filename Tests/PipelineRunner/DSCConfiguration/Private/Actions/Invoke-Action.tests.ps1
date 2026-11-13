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

    Context "Target and Credential hooks (#57 §4/§5)" {

        It "Accepts 'Target' as a valid hook" {
            $result = Invoke-Action -Hook Target -ScriptBlock { param($Context) 'target-ran' } -Context @{}
            $result | Should -Be 'target-ran'
        }

        It "Accepts 'Credential' as a valid hook" {
            $result = Invoke-Action -Hook Credential -ScriptBlock { param($Context) 'credential-ran' } -Context @{}
            $result | Should -Be 'credential-ran'
        }

        It "Resolves a named Target action from Actions/Target/<Name>.ps1" {
            $actionPath = Join-Path $TestDrive 'Actions\Target\Fixture.ps1'
            $null = New-Item -Path (Split-Path $actionPath) -ItemType Directory -Force
            @'
param([hashtable]$Context = @{})
return "target:$($Context.ComputerName)"
'@ | Set-Content -Path $actionPath

            $result = Invoke-Action -Hook Target -Name 'Fixture' -Context @{ ComputerName = 'node01' }
            $result | Should -Be 'target:node01'
        }
    }

    Context "Action name validation" {

        BeforeAll {
            # A script OUTSIDE the Actions tree that a traversal name would otherwise reach.
            $escapePath = Join-Path $TestDrive 'Escaped.ps1'
            @'
param([hashtable]$Context = @{})
return 'escaped-the-actions-tree'
'@ | Set-Content -Path $escapePath
        }

        It "Rejects a name that traverses out of Actions/<Hook>/ with forward slashes" {
            { Invoke-Action -Hook Source -Name '../../Escaped' -Context @{} } | Should -Throw '*not valid*'
        }

        It "Rejects a name that traverses out of Actions/<Hook>/ with backslashes" {
            { Invoke-Action -Hook Source -Name '..\..\Escaped' -Context @{} } | Should -Throw '*not valid*'
        }

        It "Rejects an absolute path as a name" {
            { Invoke-Action -Hook Credential -Name (Join-Path $TestDrive 'Escaped') -Context @{} } | Should -Throw '*not valid*'
        }

        It "Rejects a name that starts with a dot" {
            { Invoke-Action -Hook Source -Name '.hidden' -Context @{} } | Should -Throw '*not valid*'
        }

        It "Still accepts the shipped action names" {
            foreach ($name in 'Local', 'Git', 'DscV2', 'DscV3', 'AzureDevOps', 'SecretManagement', 'My-Custom_Action.v2') {
                # Validation passes; the lookup then fails only because the fixture does not exist.
                { Invoke-Action -Hook Source -Name $name -Context @{} } | Should -Throw '*was not found*'
            }
        }
    }

}
