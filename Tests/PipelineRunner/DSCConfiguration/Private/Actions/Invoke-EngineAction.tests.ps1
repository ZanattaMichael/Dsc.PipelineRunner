Describe "Invoke-EngineAction Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName
    }

    Context "Dispatch and normalization" {

        It "Passes the built context to the Engine hook and returns a normalized [DscMethodResult]" {
            Mock -CommandName Invoke-Action -MockWith {
                return [pscustomobject]@{ InDesiredState = $true; Message = 'ok'; Raw = 'raw-state' }
            }

            $result = Invoke-EngineAction -Method 'Test' -ModuleName 'Mod' -Name 'Res' -Property @{ p = 1 } -Engine 'DscV2'

            $result | Should -BeOfType ([DscMethodResult])
            $result.InDesiredState | Should -BeTrue
            $result.Raw | Should -Be 'raw-state'

            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Engine' -and $Name -eq 'DscV2' -and
                $Context.Method -eq 'Test' -and $Context.ModuleName -eq 'Mod' -and
                $Context.Name -eq 'Res' -and $Context.Property.p -eq 1
            }
        }

        It "Forwards an inline -EngineAction scriptblock to the loader" {
            Mock -CommandName Invoke-Action -MockWith {
                return [pscustomobject]@{ InDesiredState = $true }
            }
            $sb = { param($Context) [pscustomobject]@{ InDesiredState = $true } }

            $null = Invoke-EngineAction -Method 'Test' -ModuleName 'Mod' -Name 'Res' -EngineAction $sb

            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Engine' -and $null -ne $ScriptBlock
            }
        }

        It "Surfaces a contract violation from the engine" {
            Mock -CommandName Invoke-Action -MockWith { return $null }
            { Invoke-EngineAction -Method 'Test' -ModuleName 'Mod' -Name 'Res' } |
                Should -Throw "*returned no result*"
        }
    }

}
