# Whether this host can service an SSH remoting connection is decided HERE, at file scope,
# because Pester evaluates an It's -Skip: argument during DISCOVERY - a value assigned in
# BeforeAll (execution) would still be $null at that point and every test would skip silently.
# The probe itself lives in the test-helper module (Get-SshRemotingSkipReason) so it is callable
# from either phase.
$script:SshTarget = if ([string]::IsNullOrWhiteSpace($env:PIPELINERUNNER_SSH_TARGET)) { 'localhost' } else { $env:PIPELINERUNNER_SSH_TARGET }

$script:SshSkipReason = Get-SshRemotingSkipReason -ComputerName $script:SshTarget
$script:SshAvailable  = [string]::IsNullOrEmpty($script:SshSkipReason)

if (-not $script:SshAvailable) {
    Write-Warning "[SSHTarget.Integration] Skipping the live-connection tests: $($script:SshSkipReason)"
}

Describe "Target/SSH against a live sshd with a PowerShell subsystem" -Tag Integration, HostedIntegration {

    # Target/SSH.ps1's own header recorded that it was "only unit-tested with New-PSSession
    # mocked". This suite is that validation. It runs on the hosted Ubuntu agent, which installs
    # openssh-server, registers 'Subsystem powershell' in sshd_config and authorises the agent
    # user's own key, then connects over SSH to the agent itself. That needs no second machine
    # and is still a real remote connection: the session is built by the real New-PSSession over
    # the real ssh client, and serviced by a separate pwsh process started by sshd.
    #
    # What the mocked unit suite cannot tell us, and this does:
    #   * the parameter hashtable the action builds (HostName/SSHTransport, plus UserName and
    #     KeyFilePath when present) is actually accepted by the real New-PSSession
    #   * the session comes back open and usable, not merely non-null
    #   * SSH really has no CIM transport - the action's $null CimSession is the only option, and
    #     the DscV2 fail-fast guard is therefore load-bearing rather than decorative
    #   * a PSSession from this action carries Invoke-Command, which is how the DSC v3 engine
    #     reaches the far side (Actions/Engine/DscV3.ps1), driven here through the SHIPPED engine
    #     action rather than a hand-written call

    BeforeAll {
        $script:SSHPath   = (Get-FunctionPath 'SSH.ps1').FullName
        $script:SshTarget = if ([string]::IsNullOrWhiteSpace($env:PIPELINERUNNER_SSH_TARGET)) { 'localhost' } else { $env:PIPELINERUNNER_SSH_TARGET }

        # Re-probed here for the execution scope (see the file header): the discovery-phase value
        # above drove the -Skip: decisions but is not visible from inside BeforeAll.
        $script:SshAvailable = [string]::IsNullOrEmpty((Get-SshRemotingSkipReason -ComputerName $script:SshTarget))

        # Sessions opened by the tests, torn down in AfterAll. The action deliberately does not
        # own session lifetime (the runner does), so the tests must close what they open or each
        # one leaves an sshd child process behind.
        $script:OpenedSessions = [System.Collections.Generic.List[object]]::new()
    }

    AfterAll {
        foreach ($session in $script:OpenedSessions) {
            if ($null -ne $session.PSSession) {
                Remove-PSSession -Session $session.PSSession -ErrorAction SilentlyContinue
            }
        }
    }

    It "opens a real PSSession over SSH, and no CimSession" -Skip:(-not $script:SshAvailable) {

        $session = & $script:SSHPath -Context @{ ComputerName = $script:SshTarget; Engine = 'DscV3' }
        $script:OpenedSessions.Add($session)

        $session.IsRemote     | Should -BeTrue
        $session.ComputerName | Should -Be $script:SshTarget

        # A real type, not the marker object the unit suite's mock returns.
        $session.PSSession | Should -BeOfType [System.Management.Automation.Runspaces.PSSession]

        # There is no CIM-over-SSH transport, so this is $null by necessity rather than by
        # omission - which is what the action's DscV2 guard exists to protect.
        $session.CimSession | Should -BeNullOrEmpty

        # And genuinely connected.
        $session.PSSession.State        | Should -Be 'Opened'
        $session.PSSession.Availability | Should -Be 'Available'

        # The transport really is SSH, not WinRM: SSH-transport sessions carry an SSHConnection
        # runspace connection info rather than a WSMan one.
        $session.PSSession.Runspace.ConnectionInfo.GetType().Name | Should -Be 'SSHConnectionInfo'
    }

    It "returns a PSSession that executes a command on the far side" -Skip:(-not $script:SshAvailable) {

        $session = & $script:SSHPath -Context @{ ComputerName = $script:SshTarget; Engine = 'DscV3' }
        $script:OpenedSessions.Add($session)

        # $PID differs from this process's because the command runs in the pwsh process sshd
        # started for the subsystem - proof the PSSession is a real remoting channel rather than
        # a local shim.
        $remote = Invoke-Command -Session $session.PSSession -ScriptBlock {
            [pscustomobject]@{ ProcessId = $PID; Edition = $PSVersionTable.PSEdition }
        }

        $remote.ProcessId | Should -Not -Be $PID
        $remote.Edition   | Should -Be 'Core'
    }

    It "opens a session under an explicit UserName from the Target context" -Skip:(-not $script:SshAvailable) {

        # The unit suite proves UserName is forwarded to New-PSSession; this proves the real
        # cmdlet accepts it and that the far side genuinely runs as that account. The current
        # user is the only account whose key is authorised on the agent, so it is the one that
        # can be asserted without provisioning a second one.
        $userName = & whoami
        $userName = ([string]$userName).Trim()

        $session = & $script:SSHPath -Context @{
            ComputerName = $script:SshTarget
            Engine       = 'DscV3'
            UserName     = $userName
        }
        $script:OpenedSessions.Add($session)

        $session.PSSession.State | Should -Be 'Opened'

        $remoteUser = Invoke-Command -Session $session.PSSession -ScriptBlock { (& whoami) }
        ([string]$remoteUser).Trim() | Should -Be $userName
    }

    It "opens a session with an explicit KeyFilePath from the Target context" -Skip:(-not $script:SshAvailable) {

        # KeyFilePath is the parameter an operator reaches for when the runner's account has no
        # usable ~/.ssh/config - so what matters is that New-PSSession accepts the path the
        # action hands it and authenticates with THAT key. PIPELINERUNNER_SSH_KEY names the key
        # the environment authorised; without it there is nothing to point at, so skip with the
        # reason rather than guessing at a path.
        if ([string]::IsNullOrWhiteSpace($env:PIPELINERUNNER_SSH_KEY)) {
            Set-ItResult -Skipped -Because 'PIPELINERUNNER_SSH_KEY does not name an authorised private key on this host.'
            return
        }

        if (-not (Test-Path -LiteralPath $env:PIPELINERUNNER_SSH_KEY)) {
            Set-ItResult -Skipped -Because "PIPELINERUNNER_SSH_KEY points at [$env:PIPELINERUNNER_SSH_KEY], which does not exist."
            return
        }

        $session = & $script:SSHPath -Context @{
            ComputerName = $script:SshTarget
            Engine       = 'DscV3'
            KeyFilePath  = $env:PIPELINERUNNER_SSH_KEY
        }
        $script:OpenedSessions.Add($session)

        $session.PSSession.State | Should -Be 'Opened'
        Invoke-Command -Session $session.PSSession -ScriptBlock { 1 + 1 } | Should -Be 2
    }

    It "drives the DscV3 engine action through a real remote SSH session" -Skip:(-not $script:SshAvailable) {

        # The reason the action builds a session at all. This runs the SHIPPED engine action
        # (Actions/Engine/DscV3.ps1) against the session this target action just opened, so what
        # is asserted is the whole remote DSC v3 path - Invoke-DscExecutable's -Session branch
        # included - rather than a hand-written Invoke-Command.
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        . (Get-FunctionPath 'Protect-SensitiveValue.ps1').FullName
        . (Get-FunctionPath 'Unprotect-SecureString.ps1').FullName

        $session = & $script:SSHPath -Context @{ ComputerName = $script:SshTarget; Engine = 'DscV3' }
        $script:OpenedSessions.Add($session)

        # dsc has no remoting of its own: it must be installed ON THE TARGET, and the session's
        # PATH is the remote account's non-interactive login PATH, which is not the caller's.
        # Whether the far side has one is a machine-setup fact, so probe and skip with the reason
        # rather than failing - the engine-path assertion is the point.
        $availableTypes = Invoke-Command -Session $session.PSSession -ScriptBlock {
            if (-not (Get-Command -Name dsc -CommandType Application -ErrorAction SilentlyContinue)) {
                return @()
            }

            # dsc emits either one JSON object per line (JSONL) or a single JSON array depending
            # on the release; handle both, exactly as scripts/Test-DscV3Smoke.ps1 does.
            $listJson = & dsc resource list --output-format json 2>&1
            $types = foreach ($line in (($listJson | Out-String) -split "`n")) {
                $line = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { (ConvertFrom-Json $line).type } catch { }
            }

            $types = @($types | Where-Object { $_ })
            if ($types.Count -eq 0) {
                try { $types = @((ConvertFrom-Json ($listJson | Out-String)).type | Where-Object { $_ }) } catch { }
            }

            return @($types)
        }

        $availableTypes = @($availableTypes)
        if ($availableTypes.Count -eq 0) {
            Set-ItResult -Skipped -Because "no dsc executable with discoverable resources is on [$script:SshTarget]'s remote PATH."
            return
        }

        # Prefer the cross-platform built-ins the DSC v3 smoke test uses, then whatever is first,
        # so the assertion does not hard-depend on one resource shipping in a given dsc release.
        $preference = @('Microsoft/OSInfo', 'Microsoft.DSC.Debug/Echo')
        $targetType = $preference | Where-Object { $availableTypes -contains $_ } | Select-Object -First 1
        if (-not $targetType) { $targetType = $availableTypes[0] }

        $property = @{}
        if ($targetType -eq 'Microsoft.DSC.Debug/Echo') { $property = @{ output = 'ssh-remote' } }

        $moduleName, $name = $targetType -split '/', 2

        $result = & (Get-FunctionPath 'DscV3.ps1').FullName -Context @{
            Method     = 'Get'
            ModuleName = $moduleName
            Name       = $name
            Property   = $property
            Session    = $session
        }

        $result                | Should -Not -BeNullOrEmpty
        $result.InDesiredState | Should -BeTrue
    }

    It "does not hand back a usable session when the host is unreachable" -Skip:(-not $script:SshAvailable) {

        # A name that cannot resolve. Asserted as "nothing usable comes back" rather than
        # "it throws" because New-PSSession's SSH transport reports a failed connection as a
        # non-terminating error, so the action can also return normally with a $null PSSession -
        # either is acceptable, handing the runner an unusable session object is not.
        $unreachable = 'pipelinerunner-no-such-host-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

        $session = $null
        $threw   = $false
        try {
            # No -ErrorAction here: the action is a plain script, not an advanced function, so
            # it takes no common parameters. A stray error record is exactly what this is
            # tolerating anyway.
            $session = & $script:SSHPath -Context @{ ComputerName = $unreachable; Engine = 'DscV3' }
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            $session.PSSession | Where-Object { $_.State -eq 'Opened' } | Should -BeNullOrEmpty
        }
    }

    It "still rejects a missing ComputerName before touching the network" {
        # Not skipped with the rest: the guard fires before any connection, so this holds on any
        # host and keeps the suite from reporting "all skipped" where there is no sshd.
        { & $script:SSHPath -Context @{} } | Should -Throw "*ComputerName*"
    }

    It "still fails fast on the DscV2 engine before opening a connection" {
        # Also unskipped, and the reason the suite exists in this shape: there is no CIM-over-SSH
        # transport, so pairing SSH with DscV2 can only ever fail - the action says so up front
        # instead of handing the engine a $null CimSession.
        { & $script:SSHPath -Context @{ ComputerName = $script:SshTarget; Engine = 'DscV2' } } | Should -Throw "*DscV3*"
    }
}
