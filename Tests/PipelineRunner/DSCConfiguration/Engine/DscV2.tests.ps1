Describe "Actions/Engine/DscV2 Tests" -Tag Unit, Engine {

    BeforeAll {
        $script:DscV2Path = (Get-FunctionPath 'DscV2.ps1').FullName

        # Establish the Invoke-DscResource mock at the Describe scope. The engine is run
        # via '& $DscV2Path' (a child script scope); an It-only mock of a module cmdlet
        # applies its behavior there but Assert-MockCalled cannot count the deeper call.
        # A Describe-scoped mock (as Start-DscRunner's tests do) makes the count visible.
        Mock -CommandName Invoke-DscResource -MockWith {
            return [pscustomobject]@{ InDesiredState = $true; Message = 'default' }
        }
    }

    It "Calls Invoke-DscResource with the context's method and property" {
        Mock -CommandName Invoke-DscResource -MockWith {
            param($Name, $ModuleName, $Method, $Property)
            return [pscustomobject]@{ InDesiredState = $true; Message = 'ok' }
        }

        $null = & $script:DscV2Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ p = 1 } }

        Assert-MockCalled -CommandName Invoke-DscResource -Exactly 1 -ParameterFilter {
            $Method -eq 'Test' -and $ModuleName -eq 'Mod' -and $Name -eq 'Res' -and $Property.p -eq 1
        }
    }

    It "Surfaces InDesiredState and keeps the raw Invoke-DscResource output" {
        Mock -CommandName Invoke-DscResource -MockWith {
            return [pscustomobject]@{ InDesiredState = $false; Message = 'drift' }
        }

        $result = & $script:DscV2Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        $result.InDesiredState | Should -BeFalse
        $result.Message | Should -Be 'drift'
        $result.Raw.InDesiredState | Should -BeFalse
    }

    It "Defaults InDesiredState to true for a Get with no state flags" {
        Mock -CommandName Invoke-DscResource -MockWith {
            return [pscustomobject]@{ Prop = 'current-value' }
        }

        $result = & $script:DscV2Path -Context @{ Method = 'Get'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

        $result.InDesiredState | Should -BeTrue
        $result.Raw.Prop | Should -Be 'current-value'
    }
}
