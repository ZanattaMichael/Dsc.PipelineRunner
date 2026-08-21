Describe "ConvertTo-DscMethodResult Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
    }

    Context "Normalization" {

        It "Builds a [DscMethodResult] from a pscustomobject" {
            $raw = [pscustomobject]@{
                InDesiredState = $false
                RebootRequired = $true
                Message        = 'needs work'
                Raw            = @{ some = 'state' }
            }
            $result = ConvertTo-DscMethodResult -InputObject $raw -Method 'Test'

            $result | Should -BeOfType ([DscMethodResult])
            $result.InDesiredState | Should -BeFalse
            $result.RebootRequired | Should -BeTrue
            $result.Message | Should -Be 'needs work'
            $result.Raw.some | Should -Be 'state'
        }

        It "Builds a [DscMethodResult] from a hashtable" {
            $result = ConvertTo-DscMethodResult -InputObject @{ InDesiredState = $true } -Method 'Test'
            $result | Should -BeOfType ([DscMethodResult])
            $result.InDesiredState | Should -BeTrue
        }

        It "Passes an existing [DscMethodResult] through unchanged" {
            $existing = [DscMethodResult]@{ InDesiredState = $true; Message = 'ok' }
            $result = ConvertTo-DscMethodResult -InputObject $existing -Method 'Get'
            $result | Should -Be $existing
        }

        It "Defaults Raw to the input object when the field is absent" {
            $raw = [pscustomobject]@{ InDesiredState = $true }
            $result = ConvertTo-DscMethodResult -InputObject $raw -Method 'Test'
            $result.Raw | Should -Be $raw
        }
    }

    Context "Contract enforcement" {

        It "Throws when the engine returns nothing" {
            { ConvertTo-DscMethodResult -InputObject $null -Method 'Test' } |
                Should -Throw "*returned no result*"
        }

        It "Throws when a Test result omits InDesiredState" {
            { ConvertTo-DscMethodResult -InputObject ([pscustomobject]@{ Message = 'x' }) -Method 'Test' } |
                Should -Throw "*did not include an 'InDesiredState'*"
        }

        It "Defaults Set/Get to InDesiredState = true when the state signal is absent" {
            $result = ConvertTo-DscMethodResult -InputObject ([pscustomobject]@{ Message = 'applied' }) -Method 'Set'
            $result.InDesiredState | Should -BeTrue
        }
    }

}
