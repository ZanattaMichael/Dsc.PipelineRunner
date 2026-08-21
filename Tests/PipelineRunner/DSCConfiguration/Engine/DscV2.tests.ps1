Describe "Actions/Engine/DscV2 Tests" -Tag Unit, Engine {

    BeforeAll {
        $script:DscV2Path = (Get-FunctionPath 'DscV2.ps1').FullName

        # The engine runs via '& $DscV2Path' (a child script scope). Assert-MockCalled
        # cannot attribute an Invoke-DscResource call (a module cmdlet) made across that
        # boundary directly from an It, so instead of counting we capture the bound
        # parameters into a global list from the mock body and assert on them. The mock
        # body is proven to execute (the return value flows back in the tests below), and
        # a $Global: list is writable from any session state, so this is scope-proof.
        $Global:DscV2CapturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Invoke-DscResource -MockWith {
            param($Name, $ModuleName, $Method, $Property)
            $Global:DscV2CapturedCalls.Add([pscustomobject]@{
                Name = $Name; ModuleName = $ModuleName; Method = $Method; Property = $Property
            })
            return [pscustomobject]@{ InDesiredState = $true; Message = 'default' }
        }
    }

    AfterAll {
        Remove-Variable -Name DscV2CapturedCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It "Calls Invoke-DscResource with the context's method and property" {
        $Global:DscV2CapturedCalls.Clear()

        $null = & $script:DscV2Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ p = 1 } }

        $Global:DscV2CapturedCalls.Count | Should -Be 1
        $call = $Global:DscV2CapturedCalls[0]
        $call.Method     | Should -Be 'Test'
        $call.ModuleName | Should -Be 'Mod'
        $call.Name       | Should -Be 'Res'
        $call.Property.p | Should -Be 1
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
