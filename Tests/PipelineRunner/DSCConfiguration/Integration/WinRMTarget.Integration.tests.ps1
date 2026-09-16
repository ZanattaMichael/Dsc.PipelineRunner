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
    #   * a session from this action carries a real remote DSC v2 evaluation through the
    #     shipped engine action (Actions/Engine/DscV2.ps1) - which is how this suite found that
    #     the engine's -CimSession call shape does not exist on PowerShell 7 at all
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

    It "drives the DscV2 engine action through a real remote session" -Skip:(-not $script:WinRMAvailable) {

        # The reason the action builds sessions at all. This runs the SHIPPED engine action
        # (Actions/Engine/DscV2.ps1) against the session this target action just opened, so
        # what is asserted is the whole remote DSC v2 path, not a hand-written call.
        #
        # It replaces an assertion that Invoke-DscResource accepts -CimSession. It does not:
        # PSDesiredStateConfiguration 2.x, which PowerShell 7 uses and which this module
        # requires, removed that parameter, and the call fails with "A parameter cannot be
        # found that matches parameter name 'CimSession'". That failure here is what found the
        # defect - the engine added -CimSession unconditionally, so every remote DSC v2
        # evaluation threw. The engine now carries the evaluation over the PSSession instead.
        if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-DscResource is not available on this host.'
            return
        }

        # Which endpoint the PSSession lands on decides whether there is an Invoke-DscResource on
        # the far side at all. New-PSSession without -ConfigurationName connects to the host's
        # DEFAULT endpoint - Windows PowerShell 5.1 - and a current Windows build no longer
        # carries an in-box Invoke-DscResource there, so the evaluation has nothing to run. The
        # PowerShell 7 endpoint is where PSDesiredStateConfiguration 2.x is installed, so prefer
        # it when the host has one registered (Enable-PSRemoting under pwsh registers it; the
        # runner's Enable-SelfHostedWinRM.ps1 step does that).
        #
        # Probed with a throwaway session rather than Get-PSSessionConfiguration, which needs
        # elevation - the question here is only whether a session can be opened on it.
        $endpointName = $null
        $endpointProbe = New-PSSession -ComputerName $script:Target -ConfigurationName 'PowerShell.7' -ErrorAction SilentlyContinue
        if ($endpointProbe) {
            $endpointName = 'PowerShell.7'
            Remove-PSSession -Session $endpointProbe -ErrorAction SilentlyContinue
        }

        $targetContext = @{ ComputerName = $script:Target }
        if ($endpointName) { $targetContext.ConfigurationName = $endpointName }

        $session = & $script:WinRMPath -Context $targetContext
        $script:OpenedSessions.Add($session)

        # The dependency-free fixture resource the DSC v2 smoke test uses, rather than an in-box
        # resource: PSDesiredStateConfiguration 2.x ships none, and the point of the assertion is
        # the remote call shape, not the resource. The far side is this same machine over a
        # loopback WinRM connection, so the fixture path resolves there too - but PSModulePath is
        # per-runspace, so the REMOTE runspace has to be told about it. PSModulePath also differs
        # per endpoint - the PowerShell 7 endpoint does not inherit Windows PowerShell's.
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
        $fixtureRoot    = Join-Path $repositoryRoot 'Tests/Fixtures/DscV2'

        # What the far side can actually do is a property of the remote runspace, not of this
        # one: New-PSSession -ComputerName lands on the host's default WinRM endpoint, whose
        # PowerShell version and DSC support are a machine setup decision. Probe it and skip
        # with the reason rather than failing - the engine-path assertion is the point, and a
        # runner that cannot host DSC at all is not a defect in this repository.
        $remoteReadiness = Invoke-Command -Session $session.PSSession -ArgumentList $fixtureRoot -ScriptBlock {
            param([string]$FixtureRoot)

            if (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $FixtureRoot) {
                $env:PSModulePath = $FixtureRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
            }

            if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
                Import-Module -Name PSDesiredStateConfiguration -ErrorAction SilentlyContinue
            }

            if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
                return 'the remote runspace has no Invoke-DscResource'
            }

            if (-not (Get-DscResource -Name 'PipelineRunnerFile' -Module 'PipelineRunnerTestResource' -ErrorAction SilentlyContinue)) {
                return 'the remote runspace cannot discover the PipelineRunnerFile fixture resource'
            }

            return ''
        }

        if (-not [string]::IsNullOrEmpty([string]$remoteReadiness)) {
            $endpointDescription = if ($endpointName) { "the [$endpointName] endpoint" } else { 'the default WinRM endpoint (no PowerShell 7 endpoint is registered)' }
            Set-ItResult -Skipped -Because "$remoteReadiness on $endpointDescription."
            return
        }

        $stateDir = Join-Path $env:TEMP ("pr-winrm-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        try {
            $engineActionPath = Join-Path $repositoryRoot 'Actions/Engine/DscV2.ps1'

            # Ensure = Absent over an empty directory: the marker does not exist, so the resource
            # is already in its desired state. The assertion is that the evaluation completed on
            # the far side and came back carrying the engine contract's state signal.
            $result = & $engineActionPath -Context @{
                Method     = 'Test'
                ModuleName = 'PipelineRunnerTestResource'
                Name       = 'PipelineRunnerFile'
                Property   = @{ Name = 'winrm-remote'; Path = $stateDir; Ensure = 'Absent' }
                Session    = $session
            }

            $result                | Should -Not -BeNullOrEmpty
            $result.InDesiredState | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        }
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
