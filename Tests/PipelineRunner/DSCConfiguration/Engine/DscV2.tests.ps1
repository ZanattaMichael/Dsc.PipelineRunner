Describe "Actions/Engine/DscV2 Tests" -Tag Unit, Engine {

    BeforeAll {
        $script:DscV2Path = (Get-FunctionPath 'DscV2.ps1').FullName

        # The engine runs via '& $DscV2Path' (a child script scope). Assert-MockCalled
        # cannot attribute an Invoke-DscResource call (a module cmdlet) made across that
        # boundary directly from an It, so instead of counting we capture the bound
        # parameters into a global list from the mock body and assert on them. The mock
        # body is proven to execute (the return value flows back in the tests below), and
        # a $Global: list is writable from any session state, so this is scope-proof.
        # The real Invoke-DscResource exposes no -CimSession parameter here - PowerShell 7's
        # PSDesiredStateConfiguration 2.x removed it, which is precisely the defect the remote
        # path now works around - but the CimSession FALLBACK in the "Remote-target execution"
        # Context below has to mock a call that passes one, and the engine probes the resolved
        # command's parameters before using it. Pester's Mock inherits the *original* target
        # command's parameter metadata at the time it is first mocked, so this stub must be
        # defined - and the first Mock call made against it - before that first Mock call, not
        # just before the later one.
        function Invoke-DscResource {
            param($Name, $ModuleName, $Method, $Property, $CimSession)
        }

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

    Context "Remote-target execution (#57 §4)" {

        It "Runs the evaluation over the PSSession when the target resolved one" {
            # The preferred remote path. PSDesiredStateConfiguration 2.x (PowerShell 7) has no
            # -CimSession parameter, so the evaluation is carried to the far side and
            # Invoke-DscResource runs locally there. A live WinRM listener proved the old
            # -CimSession call shape fails outright on the supported PowerShell version
            # (WinRMTarget.Integration.tests.ps1).
            $Global:DscV2CapturedCalls.Clear()

            $fakePSSession  = [pscustomobject]@{ Marker = 'fake-ps-session' }
            $fakeCimSession = [pscustomobject]@{ Marker = 'fake-cim-session' }

            Mock -CommandName Invoke-Command -MockWith {
                param($Session, $ArgumentList)
                $Global:DscV2CapturedCalls.Add([pscustomobject]@{
                    Session = $Session; Parameters = $ArgumentList
                })
                return [pscustomobject]@{ InDesiredState = $false; Message = 'remote-drift' }
            }

            $result = & $script:DscV2Path -Context @{
                Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{ p = 1 }
                # Both sessions are present, as Target/WinRM.ps1 returns them; the PSSession wins.
                Session = [pscustomobject]@{ CimSession = $fakeCimSession; PSSession = $fakePSSession }
            }

            $Global:DscV2CapturedCalls.Count | Should -Be 1
            $call = $Global:DscV2CapturedCalls[0]
            $call.Session            | Should -Be $fakePSSession
            $call.Parameters.Name    | Should -Be 'Res'
            $call.Parameters.Method  | Should -Be 'Test'
            $call.Parameters.Property.p | Should -Be 1
            # Nothing is sent over the wire that the far side's Invoke-DscResource cannot bind.
            $call.Parameters.ContainsKey('CimSession') | Should -BeFalse

            # The remote result is normalized exactly like a local one.
            $result.InDesiredState | Should -BeFalse
            $result.Message        | Should -Be 'remote-drift'
        }

        It "Falls back to -CimSession when the target resolved one and no PSSession" {
            $Global:DscV2CapturedCalls.Clear()
            Mock -CommandName Invoke-DscResource -MockWith {
                param($Name, $ModuleName, $Method, $Property, $CimSession)
                $Global:DscV2CapturedCalls.Add([pscustomobject]@{ CimSession = $CimSession })
                return [pscustomobject]@{ InDesiredState = $true }
            }

            $fakeCimSession = [pscustomobject]@{ Marker = 'fake-cim-session' }
            $null = & $script:DscV2Path -Context @{
                Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{}
                Session = [pscustomobject]@{ CimSession = $fakeCimSession }
            }

            $Global:DscV2CapturedCalls[0].CimSession | Should -Be $fakeCimSession
        }

        It "Does not add -CimSession when no Session is supplied (local execution, today's default)" {
            $Global:DscV2CapturedCalls.Clear()
            Mock -CommandName Invoke-DscResource -MockWith {
                param($Name, $ModuleName, $Method, $Property, $CimSession)
                $Global:DscV2CapturedCalls.Add([pscustomobject]@{ CimSession = $CimSession })
                return [pscustomobject]@{ InDesiredState = $true }
            }

            $null = & $script:DscV2Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

            $Global:DscV2CapturedCalls[0].CimSession | Should -BeNullOrEmpty
        }

        It "Never calls Invoke-Command for a local evaluation" {
            $Global:DscV2CapturedCalls.Clear()
            Mock -CommandName Invoke-Command -MockWith {
                $Global:DscV2CapturedCalls.Add([pscustomobject]@{ Unexpected = $true })
                return [pscustomobject]@{ InDesiredState = $true }
            }
            Mock -CommandName Invoke-DscResource -MockWith {
                return [pscustomobject]@{ InDesiredState = $true }
            }

            $null = & $script:DscV2Path -Context @{ Method = 'Test'; ModuleName = 'Mod'; Name = 'Res'; Property = @{} }

            $Global:DscV2CapturedCalls.Count | Should -Be 0
        }
    }
}
