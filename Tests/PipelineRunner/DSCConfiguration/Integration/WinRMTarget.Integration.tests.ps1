# Whether this host can service a WinRM connection is decided HERE, at file scope, because Pester
# evaluates an It's -Skip: argument during DISCOVERY - a value assigned in BeforeAll (execution)
# would still be $null at that point and every test would skip silently. The probe itself lives in
# the test-helper module (Get-WinRMSkipReason) so it is callable from either phase.
$script:WinRMSkipReason = Get-WinRMSkipReason
$script:WinRMAvailable  = [string]::IsNullOrEmpty($script:WinRMSkipReason)

if (-not $script:WinRMAvailable) {
    Write-Warning "[WinRMTarget.Integration] Skipping the live-connection tests: $($script:WinRMSkipReason)"
}

Describe "Target/WinRM against a live WinRM listener" -Tag Integration, RemotingSelfHosted {

    # Target/WinRM.ps1's own header records that it is "only unit-tested with New-CimSession/
    # New-PSSession mocked ... validating a real connection needs a reachable Windows remote
    # target". This suite is that validation. It runs on the self-hosted Windows + PowerShell 7
    # runner (the same host DscV2-SelfHosted.yml uses) and connects over WinRM to the runner
    # itself, so it needs no second machine while still going through the genuine WSMan stack:
    # a loopback WinRM connection is a real remote connection as far as CIM/PowerShell
    # remoting is concerned - the sessions are built by the real New-CimSession/New-PSSession,
    # carried over HTTP(S) to the WinRM service, and serviced by a separate wsmprovhost process.
    #
    # What the mocked unit suite cannot tell us, and this does:
    #   * the parameter hashtable the action builds is actually accepted by the real cmdlets
    #   * both session objects come back open and usable, not merely non-null
    #   * a CimSession from this action is accepted by Invoke-DscResource -CimSession, which is
    #     the whole point of building one (Actions/Engine/DscV2.ps1:33-35)
    #   * a PSSession from this action carries Invoke-Command, which is how the DSC v3 engine
    #     reaches the far side (Actions/Engine/DscV3.ps1:129-134)
    #   * an unreachable ComputerName surfaces as a throw rather than a silent $null session

    BeforeAll {
        $script:WinRMPath = (Get-FunctionPath 'WinRM.ps1').FullName
        $script:Target    = $env:COMPUTERNAME

        # Sessions opened by the tests, torn down in AfterAll. The action deliberately does not
        # own session lifetime (the runner does), so the tests must close what they open or the
        # self-hosted runner accumulates wsmprovhost processes across builds.
        $script:OpenedSessions = [System.Collections.Generic.List[object]]::new()
    }

    AfterAll {
        foreach ($session in $script:OpenedSessions) {
            if ($null -ne $session.CimSession) {
                Remove-CimSession -CimSession $session.CimSession -ErrorAction SilentlyContinue
            }
            if ($null -ne $session.PSSession) {
                Remove-PSSession -Session $session.PSSession -ErrorAction SilentlyContinue
            }
        }
    }

    It "opens a real CimSession and PSSession for the target computer" -Skip:(-not $script:WinRMAvailable) {

        $session = & $script:WinRMPath -Context @{ ComputerName = $script:Target }
        $script:OpenedSessions.Add($session)

        $session.IsRemote     | Should -BeTrue
        $session.ComputerName | Should -Be $script:Target

        # Real types, not the marker objects the unit suite's mocks return.
        $session.CimSession | Should -BeOfType [Microsoft.Management.Infrastructure.CimSession]
        $session.PSSession  | Should -BeOfType [System.Management.Automation.Runspaces.PSSession]

        # And genuinely connected.
        $session.PSSession.State        | Should -Be 'Opened'
        $session.PSSession.Availability | Should -Be 'Available'
        $session.CimSession.TestConnection() | Should -Not -BeNullOrEmpty
    }

    It "returns a CimSession that carries a real CIM query to the far side" -Skip:(-not $script:WinRMAvailable) {

        $session = & $script:WinRMPath -Context @{ ComputerName = $script:Target }
        $script:OpenedSessions.Add($session)

        $os = Get-CimInstance -CimSession $session.CimSession -ClassName Win32_OperatingSystem -ErrorAction Stop

        $os              | Should -Not -BeNullOrEmpty
        $os.CSName       | Should -Be $script:Target
        # The instance came back over the session, not from a local call.
        $os.PSComputerName | Should -Be $script:Target
    }

    It "returns a PSSession that executes a command on the far side" -Skip:(-not $script:WinRMAvailable) {

        $session = & $script:WinRMPath -Context @{ ComputerName = $script:Target }
        $script:OpenedSessions.Add($session)

        # $PID differs from this process's because the command runs in the remote runspace's
        # wsmprovhost - proof the PSSession is a real remoting channel rather than a local shim.
        $remote = Invoke-Command -Session $session.PSSession -ScriptBlock {
            [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; ProcessId = $PID }
        }

        $remote.ComputerName | Should -Be $script:Target
        $remote.ProcessId    | Should -Not -Be $PID
    }

    It "produces a CimSession that Invoke-DscResource accepts for a remote evaluation" -Skip:(-not $script:WinRMAvailable) {

        # The reason the action builds a CimSession at all (Actions/Engine/DscV2.ps1:33-35).
        # Uses the in-box File resource so the suite carries no resource-module dependency of
        # its own; the assertion is that the CIM-session call shape works end to end, not
        # anything about the File resource.
        if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-DscResource is not available on this host.'
            return
        }

        $session = & $script:WinRMPath -Context @{ ComputerName = $script:Target }
        $script:OpenedSessions.Add($session)

        $probePath = Join-Path $env:TEMP ("pr-winrm-{0}.txt" -f [guid]::NewGuid())

        $result = Invoke-DscResource -Name File -ModuleName PSDesiredStateConfiguration -Method Test -CimSession $session.CimSession -Property @{
            DestinationPath = $probePath
            Ensure          = 'Absent'
        } -ErrorAction Stop

        # The file was never created, so 'Absent' is satisfied. The point of the assertion is
        # that the call completed over the session and returned the engine contract's state
        # signal rather than throwing on the -CimSession parameter.
        $result.InDesiredState | Should -BeTrue
    }

    It "throws rather than returning a half-built session when the computer is unreachable" -Skip:(-not $script:WinRMAvailable) {

        # A name that cannot resolve. New-CimSession is lazy about connecting, so the failure may
        # surface from either constructor; the contract this asserts is only that the action does
        # not hand the runner a session object it cannot use.
        $unreachable = 'pipelinerunner-no-such-host-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

        { & $script:WinRMPath -Context @{ ComputerName = $unreachable } } | Should -Throw
    }

    It "still rejects a missing ComputerName before touching the network" {
        # Not skipped with the rest: the guard fires before any network call, so this holds on
        # any host and keeps the suite from reporting "all skipped" when there is no listener.
        { & $script:WinRMPath -Context @{} } | Should -Throw "*ComputerName*"
    }
}
