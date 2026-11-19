Describe "Invoke-DscRunner Function Tests" -Tag Unit, Runner {

    BeforeAll {

        # Load the function under test plus the loader it delegates to. Resolve-DscEngine and
        # its dsc.exe probe are loaded so the config-driven DSCResourceVersion mapping runs;
        # Get-PipelineRunnerSetting is loaded so it can be mocked to feed controlled settings.
        @(
            (Get-FunctionPath 'Invoke-Action.ps1')
            (Get-FunctionPath 'Build-DatumConfiguration.ps1')
            (Get-FunctionPath 'Start-DscRunner.ps1')
            (Get-FunctionPath 'Protect-SensitiveValue.ps1')
            (Get-FunctionPath 'Merge-DscRunnerResult.ps1')
            (Get-FunctionPath 'New-TemporaryDirectory.ps1')
            (Get-FunctionPath 'Register-RunnerTemporaryDirectory.ps1')
            (Get-FunctionPath 'Remove-RunnerTemporaryDirectory.ps1')
            (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1')
            (Get-FunctionPath 'Test-DscExecutableAvailable.ps1')
            (Get-FunctionPath 'Resolve-DscEngine.ps1')
            (Get-FunctionPath 'Resolve-CacheDirectory.ps1')
            (Get-FunctionPath 'Resolve-PassthroughConfiguration.ps1')
            (Get-FunctionPath 'Resolve-PassthroughPolicyContext.ps1')
            (Get-FunctionPath 'Resolve-CapabilityPolicyPath.ps1')
            (Get-FunctionPath 'Import-CapabilityPolicy.ps1')
            (Get-FunctionPath 'Assert-RunnerSettingsPolicy.ps1')
            (Get-FunctionPath 'Get-PolicyLayer.ps1')
            (Get-FunctionPath 'Resolve-DscV3ResourcePath.ps1')
        ) | ForEach-Object { . $_.FullName }

        . (Get-FunctionPath 'Invoke-DscRunner.ps1').FullName

        $configDir = Join-Path $TestDrive 'config'
        $cacheDir  = Join-Path $TestDrive 'cache'
        $null = New-Item -Path $configDir -ItemType Directory -Force
        $null = New-Item -Path $cacheDir  -ItemType Directory -Force

        # Passthrough documents (#106): real files, because Resolve-PassthroughConfiguration
        # reads the file system directly rather than through the mocked Get-ChildItem below.
        $passthroughDir = Join-Path $TestDrive 'passthrough'
        $null = New-Item -Path $passthroughDir -ItemType Directory -Force
        $nodeOne = Join-Path $passthroughDir 'node-one.yml'
        $nodeTwo = Join-Path $passthroughDir 'node-two.yml'
        [System.IO.File]::WriteAllText($nodeOne, 'resources: []')
        [System.IO.File]::WriteAllText($nodeTwo, 'resources: []')
        $policyFile = Join-Path $TestDrive 'Policy.yml'
        [System.IO.File]::WriteAllText($policyFile, "Default: Deny`nLayers: []")

        # Isolate the entry point from the real lifecycle machinery.
        Mock -CommandName Invoke-Action -MockWith {
            if ($Hook -eq 'Source') { return $configDir }
            return $null
        }
        Mock -CommandName Build-DatumConfiguration
        Mock -CommandName Start-DscRunner
        # New-TemporaryDirectory now returns the path as a string (#9).
        Mock -CommandName New-TemporaryDirectory -MockWith { return $cacheDir }
        Mock -CommandName Remove-RunnerTemporaryDirectory
        # No engine signal by default so the existing tests keep the DscV2 default and never
        # touch the filesystem for a Datum.yml. Engine-selection tests override this per-It.
        Mock -CommandName Get-PipelineRunnerSetting -MockWith { return $null }
        Mock -CommandName Get-ChildItem -MockWith {
            @(
                [pscustomobject]@{ FullName = (Join-Path $cacheDir 'a.yml') }
                [pscustomobject]@{ FullName = (Join-Path $cacheDir 'b.yml') }
            )
        }
    }

    Context "Source resolution" {

        It "Invokes the Source hook with the requested action name" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and $Name -eq 'Local'
            }
        }

        It "Folds -ConfigurationSourcePath into the Source context Path and Url keys" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and $Context.Path -eq $configDir -and $Context.Url -eq $configDir
            }
        }

        It "Passes an inline Source scriptblock through to the loader" {
            $sb = { param($Context) $configDir }
            Invoke-DscRunner -SourceAction $sb -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and $null -ne $ScriptBlock
            }
        }

        It "Throws when the Source action returns no directory" {
            Mock -CommandName Invoke-Action -MockWith { return $null }
            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir } |
                Should -Throw "*returned no configuration directory*"
        }
    }

    Context "Connect resolution" {

        It "Invokes the Connect hook with None by default" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Connect' -and $Name -eq 'None'
            }
        }

        It "Invokes the Connect hook with the requested action name" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -Connect 'AzureDevOps' -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Connect' -and $Name -eq 'AzureDevOps'
            }
        }
    }

    Context "Compilation and execution" {

        It "Compiles Datum into the cache directory" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It -ParameterFilter {
                $OutputPath -eq $cacheDir -and $ConfigurationPath -eq $configDir
            }
        }

        It "Runs Start-DscRunner once per compiled configuration file" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It
        }

        It "Defaults the cache directory to a temporary directory when none is supplied" {
            # No cache env var set, so the resolver returns nothing and the temp dir is used.
            Remove-Item Env:PIPELINERUNNER_CACHE_DIRECTORY -ErrorAction SilentlyContinue
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue

            Invoke-DscRunner -ConfigurationSourcePath $configDir
            Assert-MockCalled -CommandName New-TemporaryDirectory -Exactly 1 -Scope It
        }

        It "Uses the cache directory environment variable instead of a temp dir when set" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = $cacheDir
            try {
                Invoke-DscRunner -ConfigurationSourcePath $configDir
            }
            finally {
                Remove-Item Env:PIPELINERUNNER_CACHE_DIRECTORY -ErrorAction SilentlyContinue
            }

            Assert-MockCalled -CommandName New-TemporaryDirectory -Exactly 0 -Scope It
            Assert-MockCalled -CommandName Build-DatumConfiguration -Scope It -ParameterFilter {
                $OutputPath -eq $cacheDir
            }
        }

        It "Forwards the report path to Start-DscRunner when supplied" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -ReportPath $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $ReportPath -eq $cacheDir
            }
        }
    }

    Context "Engine selection" {

        It "Defaults to DscV2 when the configuration carries no engine signal" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $Engine -eq 'DscV2'
            }
        }

        It "Selects the engine named in PipelineRunnerSettings.Engine" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ Engine = 'DscV3' } }

            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $Engine -eq 'DscV3'
            }
        }

        It "Maps a 3.x DSCResourceVersion to DscV3 when Engine is unset" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ DSCResourceVersion = '3.0' } }
            Mock -CommandName Test-DscExecutableAvailable -MockWith { return $true }

            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $Engine -eq 'DscV3'
            }
        }

        It "Maps a 2.x DSCResourceVersion to DscV2 when Engine is unset" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ DSCResourceVersion = '2.0' } }

            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $Engine -eq 'DscV2'
            }
        }

        It "Honours an explicit -Engine over the configuration's Engine setting" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ Engine = 'DscV3' } }

            # The config is still read once even with an explicit -Engine (#57 §2/§3: its other
            # keys - AllowExecutionScripts, Reboot, etc. - must still reach Start-DscRunner), but
            # its Engine key is ignored in favor of the explicit parameter.
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -Engine 'DscV2'
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $Engine -eq 'DscV2'
            }
            Assert-MockCalled -CommandName Get-PipelineRunnerSetting -Exactly 1 -Scope It
        }
    }

    Context "Capability policy Settings: what Datum.yml's PipelineRunnerSettings may say (#86)" {

        BeforeAll {
            Import-Module -Name 'powershell-yaml' -ErrorAction Stop
            $script:SettingsPolicyPath = Join-Path $TestDrive 'settings-policy.yml'
            Set-Content -LiteralPath $SettingsPolicyPath -Value "PolicyVersion: 1`nDefault: Deny`nLayers:`n  - Name: Platform`n    Paths: [ 'Datum.yml' ]`nSettings:`n  Engine: [ DscV3 ]`n  Reboot: [ Fail ]"
        }

        It "Stops before compile when Datum.yml holds a value the policy does not allow" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ Engine = 'DscV3'; Reboot = 'Ignore' } }

            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -PolicyPath $SettingsPolicyPath } |
                Should -Throw "*layer 'Platform'*PipelineRunnerSettings.Reboot is 'Ignore'*"
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 0 -Scope It
        }

        It "Judges the engine the configuration selected" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ DSCResourceVersion = '2.0' } }

            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -PolicyPath $SettingsPolicyPath } |
                Should -Throw "*PipelineRunnerSettings.Engine is 'DscV2'*"
        }

        It "Does not govern an engine the pipeline chose" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ Engine = 'DscV3' } }

            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -PolicyPath $SettingsPolicyPath -Engine 'DscV2' } | Should -Not -Throw
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It
        }
    }

    Context "Run summary and exit contract (#19)" {

        It "Returns an aggregate summary across every configuration" {
            Mock -CommandName Start-DscRunner -MockWith {
                [pscustomobject]@{
                    ConfigurationFile = $FilePath
                    Status            = 'Completed'
                    TotalResources    = 1
                    PassCount         = 1
                    FailCount         = 0
                    SkipCount         = 0
                    DurationSeconds   = 0.1
                    FailedResources   = @()
                    Results           = @()
                }
            }

            $summary = Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir

            $summary.Status | Should -Be 'Completed'
            $summary.TotalConfigurations | Should -Be 2
            $summary.PassCount | Should -Be 2
            $summary.FailCount | Should -Be 0
        }

        It "Reports a Failed status and collects the failed resources when a configuration fails" {
            Mock -CommandName Start-DscRunner -MockWith {
                [pscustomobject]@{
                    ConfigurationFile = $FilePath
                    Status            = 'Completed'
                    TotalResources    = 1
                    PassCount         = 0
                    FailCount         = 1
                    SkipCount         = 0
                    DurationSeconds   = 0.1
                    FailedResources   = @([pscustomobject]@{ InstanceName = 'Resource1' })
                    Results           = @()
                }
            }

            $summary = Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir

            $summary.Status | Should -Be 'Failed'
            $summary.FailCount | Should -Be 2
            $summary.FailedResources.Count | Should -Be 2
        }

        It "Sets a non-zero process exit code with -FailOnError when the run fails" {
            Mock -CommandName Start-DscRunner -MockWith {
                [pscustomobject]@{
                    ConfigurationFile = $FilePath
                    Status            = 'Completed'
                    TotalResources    = 1
                    PassCount         = 0
                    FailCount         = 1
                    SkipCount         = 0
                    DurationSeconds   = 0.1
                    FailedResources   = @([pscustomobject]@{ InstanceName = 'Resource1' })
                    Results           = @()
                }
            }

            # Save and restore the process exit code so a deliberately-failing run in this test
            # does not leak a red exit code into the CI process.
            $previousExitCode = [System.Environment]::ExitCode
            try {
                [System.Environment]::ExitCode = 0
                Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -FailOnError | Out-Null
                [System.Environment]::ExitCode | Should -Be 1
            }
            finally {
                [System.Environment]::ExitCode = $previousExitCode
            }
        }

        It "Leaves the exit code unchanged on failure when -FailOnError is not supplied" {
            Mock -CommandName Start-DscRunner -MockWith {
                [pscustomobject]@{
                    ConfigurationFile = $FilePath
                    Status            = 'Completed'
                    TotalResources    = 1
                    PassCount         = 0
                    FailCount         = 1
                    SkipCount         = 0
                    DurationSeconds   = 0.1
                    FailedResources   = @([pscustomobject]@{ InstanceName = 'Resource1' })
                    Results           = @()
                }
            }

            $previousExitCode = [System.Environment]::ExitCode
            try {
                [System.Environment]::ExitCode = 0
                Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir | Out-Null
                [System.Environment]::ExitCode | Should -Be 0
            }
            finally {
                [System.Environment]::ExitCode = $previousExitCode
            }
        }
    }

    Context "Configuration revision pinning (#31)" {

        It "Folds -ConfigurationRevision into the Source context" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -ConfigurationRevision 'v1.2.3'
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and $Context.Revision -eq 'v1.2.3'
            }
        }

        It "Leaves the Source context without a Revision key when none is supplied" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and -not $Context.ContainsKey('Revision')
            }
        }

        It "Does not override a Revision already present in -SourceContext" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir `
                             -SourceContext @{ Revision = 'explicit' } -ConfigurationRevision 'v1.2.3'
            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Source' -and $Context.Revision -eq 'explicit'
            }
        }
    }

    Context "Temporary directory lifecycle (#32)" {

        It "Cleans up the configuration and cache directories after a successful run" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir

            Assert-MockCalled -CommandName Remove-RunnerTemporaryDirectory -Exactly 1 -Scope It -ParameterFilter { $Path -eq $configDir }
            Assert-MockCalled -CommandName Remove-RunnerTemporaryDirectory -Exactly 1 -Scope It -ParameterFilter { $Path -eq $cacheDir }
        }

        It "Cleans up even when the run throws" {
            Mock -CommandName Build-DatumConfiguration -MockWith { throw 'compile failed' }

            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir } | Should -Throw

            Assert-MockCalled -CommandName Remove-RunnerTemporaryDirectory -Exactly 1 -Scope It -ParameterFilter { $Path -eq $configDir }
        }

        It "Cleans up when the Source action returns nothing" {
            Mock -CommandName Invoke-Action -MockWith { return $null }

            { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir } | Should -Throw

            Assert-MockCalled -CommandName Remove-RunnerTemporaryDirectory -Scope It
        }

        It "Leaves the directories in place with -KeepTemporaryDirectory" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -KeepTemporaryDirectory

            Assert-MockCalled -CommandName Remove-RunnerTemporaryDirectory -Exactly 0 -Scope It
        }

        It "Uses the string returned by New-TemporaryDirectory as the fallback cache directory" {
            # The old code read a .Path property off a DirectoryInfo, which is always $null (#9).
            Invoke-DscRunner -ConfigurationSourcePath $configDir

            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It -ParameterFilter {
                $OutputPath -eq $cacheDir
            }
        }
    }

    Context "Direct passthrough: running a configuration the caller already has (#106)" {

        It "Runs Start-DscRunner once per document in -ConfigurationDirectory, in name order" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy

            Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It
            Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $FilePath -eq $nodeOne }
            Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $FilePath -eq $nodeTwo }
        }

        It "Runs the documents named in -ConfigurationFile" {
            Invoke-DscRunner -ConfigurationFile $nodeTwo -BypassDatumPolicy

            Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $FilePath -eq $nodeTwo }
        }

        It "Does not compile Datum" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy

            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 0 -Scope It
        }

        It "Does not resolve a source: there is nothing to resolve" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy

            Assert-MockCalled -CommandName Invoke-Action -Exactly 0 -Scope It -ParameterFilter { $Hook -eq 'Source' }
        }

        It "Does not create a cache directory for a run that compiles nothing" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy

            Assert-MockCalled -CommandName New-TemporaryDirectory -Exactly 0 -Scope It
        }

        It "Does not read PipelineRunnerSettings from a Datum definition file" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy

            Assert-MockCalled -CommandName Get-PipelineRunnerSetting -Exactly 0 -Scope It
        }

        It "Still runs the Connect action: a passthrough run applies resources to real targets" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -Connect 'AzureDevOps'

            Assert-MockCalled -CommandName Invoke-Action -Exactly 1 -Scope It -ParameterFilter {
                $Hook -eq 'Connect' -and $Name -eq 'AzureDevOps'
            }
        }

        It "Still skips the Connect action on a dry run" {
            Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -Mode DryRun

            Assert-MockCalled -CommandName Invoke-Action -Exactly 0 -Scope It -ParameterFilter { $Hook -eq 'Connect' }
        }

        It "Fails before connecting when a named document does not exist" {
            { Invoke-DscRunner -ConfigurationFile (Join-Path $passthroughDir 'absent.yml')  -BypassDatumPolicy} |
                Should -Throw "*does not exist*"

            Assert-MockCalled -CommandName Invoke-Action -Exactly 0 -Scope It -ParameterFilter { $Hook -eq 'Connect' }
            Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
        }

        Context "PipelineRunnerSettings come from the caller" {

            It "Passes -RunnerSettings through to the runner" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy -RunnerSettings @{ AllowExecutionScripts = $true; Reboot = 'Ignore' }

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                    $RunnerSettings['AllowExecutionScripts'] -eq $true -and $RunnerSettings['Reboot'] -eq 'Ignore'
                }
            }

            It "Passes no settings at all when none are supplied, so the runner's defaults apply" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                    -not $PSBoundParameters.ContainsKey('RunnerSettings')
                }
            }

            It "Selects the engine from RunnerSettings.Engine" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy -RunnerSettings @{ Engine = 'DscV3' }

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $Engine -eq 'DscV3' }
            }

            It "Maps the back-compat RunnerSettings.DSCResourceVersion to an engine" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy -RunnerSettings @{ DSCResourceVersion = '2.9.0' }

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $Engine -eq 'DscV2' }
            }

            It "Honours an explicit -Engine over RunnerSettings.Engine" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy -RunnerSettings @{ Engine = 'DscV3' } -Engine 'DscV2'

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter { $Engine -eq 'DscV2' }
            }
        }

        Context "The node name" {

            It "Is the document's file name when no override is given" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy

                # Start-DscRunner derives it from the file name, so the entry point passes nothing.
                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                    -not $PSBoundParameters.ContainsKey('NodeName')
                }
            }

            It "Passes -NodeName through for a single document" {
                Invoke-DscRunner -ConfigurationFile $nodeOne -BypassDatumPolicy -NodeName 'SRV-APP-01'

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                    $NodeName -eq 'SRV-APP-01' -and $FilePath -eq $nodeOne
                }
            }

            It "Refuses -NodeName with -ConfigurationDirectory, because each document is its own node" {
                { Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -NodeName 'SRV-APP-01' } |
                    Should -Throw "*cannot be used with -ConfigurationDirectory*"

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
            }

            It "Refuses -NodeName when several documents are named" {
                { Invoke-DscRunner -ConfigurationFile @($nodeOne, $nodeTwo) -BypassDatumPolicy -NodeName 'SRV-APP-01' } |
                    Should -Throw "*2 documents were supplied*"

                Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
            }

            It "Is not accepted on the Datum path, whose node name is always the compiled file's name" {
                { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -NodeName 'SRV-APP-01' } |
                    Should -Throw
            }
        }

        Context "The capability policy: declared, never inferred (#106)" {

            # A passthrough document has no layers, so a policy cannot be enforced over it. That
            # makes choosing passthrough a way out of the policy mechanism, so it must be
            # DECLARED. Three rules, and the order matters:
            #   1. a governed configuration behind the documents refuses the run, switch or no
            #      switch - the switch is not an escalation path;
            #   2. no policy behind them and no switch: refused, naming the switch;
            #   3. no policy behind them and the switch given: runs, says so, records it.

            BeforeAll {
                # Mocked so the Datum path's policy resolution can be asserted *not* to run.
                Mock -CommandName Resolve-CapabilityPolicyPath -MockWith { return $null }
                Mock -CommandName Import-CapabilityPolicy -MockWith { return @{ Path = 'p'; Layers = @(); Default = 'Deny'; Sha256 = ('0' * 64) } }

                # A governed configuration: a Datum definition file and a policy at its root, with
                # the document two levels below, as the documented layout puts them.
                $script:governedRoot = Join-Path $TestDrive 'governed'
                $script:governedNodeDir = [System.IO.Path]::Combine($script:governedRoot, 'Projects', 'Present')
                $null = New-Item -Path $script:governedNodeDir -ItemType Directory -Force
                [System.IO.File]::WriteAllText((Join-Path $script:governedRoot 'Datum.yml'), 'ResolutionPrecedence: []')
                [System.IO.File]::WriteAllText((Join-Path $script:governedRoot 'Policy.yml'), "Default: Deny`nLayers: []")
                $script:governedNode = [System.IO.Path]::Combine($script:governedNodeDir, 'Magenta.yml')
                [System.IO.File]::WriteAllText($script:governedNode, 'resources: []')
            }

            Context "rule 2: not declared" {

                It "Refuses a passthrough run that does not declare the bypass, naming the switch" {
                    { Invoke-DscRunner -ConfigurationDirectory $passthroughDir } |
                        Should -Throw "*-BypassDatumPolicy*"

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
                }

                It "Says why, not only what: the document has no layers" {
                    { Invoke-DscRunner -ConfigurationFile $nodeOne } |
                        Should -Throw "*has no layers*"
                }
            }

            Context "rule 3: declared" {

                It "Runs with -BypassDatumPolicy" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -WarningAction SilentlyContinue

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It
                }

                It "Records the bypass on every node, so an audit can see it" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -WarningAction SilentlyContinue

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It -ParameterFilter {
                        $PolicyBypassed -eq $true
                    }
                }

                It "Warns once per run that the policy is bypassed" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -WarningVariable bypassWarning -WarningAction SilentlyContinue

                    @($bypassWarning | Where-Object { [string]$_ -like '*BYPASSED*' }).Count | Should -Be 1
                }

                It "Still says it on the information stream" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -InformationVariable info -WarningAction SilentlyContinue

                    @($info | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'bypassed by -BypassDatumPolicy'
                }

                It "Never hands a policy to the runner, so it can never half-enforce one" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -WarningAction SilentlyContinue

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It -ParameterFilter {
                        -not $PSBoundParameters.ContainsKey('Policy')
                    }
                }

                It "Never looks for a policy file of its own" {
                    Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -WarningAction SilentlyContinue

                    Assert-MockCalled -CommandName Resolve-CapabilityPolicyPath -Exactly 0 -Scope It
                    Assert-MockCalled -CommandName Import-CapabilityPolicy -Exactly 0 -Scope It
                }
            }

            Context "rule 1: a governed configuration is refused either way" {

                # This is the test that stops a later change quietly turning the switch into an
                # escalation path: the SAME governed configuration, with and without it, refused
                # both times and for the same reason.
                It "Refuses a governed configuration <When> the switch" -ForEach @(
                    @{ When = 'without'; Bypass = $false }
                    @{ When = 'with';    Bypass = $true }
                ) {
                    $splat = @{ ConfigurationFile = $script:governedNode }
                    if ($Bypass) { $splat.BypassDatumPolicy = $true }

                    { Invoke-DscRunner @splat -WarningAction SilentlyContinue } |
                        Should -Throw "*governed by a capability policy*"

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
                }

                It "Refuses the directory form too, with the switch" {
                    { Invoke-DscRunner -ConfigurationDirectory $script:governedNodeDir -BypassDatumPolicy -WarningAction SilentlyContinue } |
                        Should -Throw "*governed by a capability policy*"
                }

                It "Points at the Datum path, and says the switch grants no exception" {
                    { Invoke-DscRunner -ConfigurationFile $script:governedNode -BypassDatumPolicy -WarningAction SilentlyContinue } |
                        Should -Throw "*does not override this*"
                }

                It "Does not refuse a configuration that has no policy beside its Datum.yml" {
                    $ungoverned = Join-Path $TestDrive 'ungoverned'
                    $null = New-Item -Path $ungoverned -ItemType Directory -Force
                    [System.IO.File]::WriteAllText((Join-Path $ungoverned 'Datum.yml'), 'ResolutionPrecedence: []')
                    $node = Join-Path $ungoverned 'n.yml'
                    [System.IO.File]::WriteAllText($node, 'resources: []')

                    Invoke-DscRunner -ConfigurationFile $node -BypassDatumPolicy -WarningAction SilentlyContinue

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It
                }
            }

            Context "-PolicyPath and -RequirePolicy stay refused" {

                It "Refuses -PolicyPath and points at the switch" {
                    { Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -PolicyPath $policyFile -WarningAction SilentlyContinue } |
                        Should -Throw "*-BypassDatumPolicy*"
                }

                It "Refuses -RequirePolicy: a pipeline that requires a policy cannot use passthrough" {
                    { Invoke-DscRunner -ConfigurationDirectory $passthroughDir -BypassDatumPolicy -RequirePolicy -WarningAction SilentlyContinue } |
                        Should -Throw "*cannot be applied to a passthrough configuration*"
                }

                It "Runs nothing when a policy was asked for" -ForEach @(
                    @{ Arguments = @{ PolicyPath = 'POLICY' } }
                    @{ Arguments = @{ RequirePolicy = $true } }
                ) {
                    $splat = @{ ConfigurationDirectory = $passthroughDir; BypassDatumPolicy = $true }
                    foreach ($key in $Arguments.Keys) {
                        $value = $Arguments[$key]
                        if ($value -is [string] -and $value -eq 'POLICY') { $value = $policyFile }
                        $splat[$key] = $value
                    }

                    { Invoke-DscRunner @splat -WarningAction SilentlyContinue } | Should -Throw

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 0 -Scope It
                    Assert-MockCalled -CommandName Invoke-Action -Exactly 0 -Scope It -ParameterFilter { $Hook -eq 'Connect' }
                }
            }

            Context "a stray policy beside the documents is the ambiguous case" {

                It "Warns rather than refuses when a Policy.yml has no Datum.yml above it" {
                    $withPolicy = Join-Path $TestDrive 'straypolicy'
                    $null = New-Item -Path $withPolicy -ItemType Directory -Force
                    [System.IO.File]::WriteAllText((Join-Path $withPolicy 'n.yml'), 'resources: []')
                    [System.IO.File]::WriteAllText((Join-Path $withPolicy 'Policy.yml'), "Default: Deny`nLayers: []")

                    Invoke-DscRunner -ConfigurationDirectory $withPolicy -BypassDatumPolicy -WarningVariable policyWarning -WarningAction SilentlyContinue

                    @($policyWarning | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'is NOT being applied'
                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It
                }
            }

            Context "the switch is meaningless on the Datum path" {

                It "Refuses -BypassDatumPolicy for a compiled run" {
                    { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -BypassDatumPolicy } |
                        Should -Throw "*applies only to a passthrough configuration*"
                }

                It "Refuses it before the source is even resolved, so it can have no effect" {
                    { Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -BypassDatumPolicy } | Should -Throw

                    Assert-MockCalled -CommandName Invoke-Action -Exactly 0 -Scope It
                    Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 0 -Scope It
                }

                It "Never records a bypass on a compiled run" {
                    Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir

                    Assert-MockCalled -CommandName Start-DscRunner -Exactly 2 -Scope It -ParameterFilter {
                        -not $PSBoundParameters.ContainsKey('PolicyBypassed')
                    }
                }
            }
        }

        Context "A passthrough input and a Datum source are alternatives" {

            It "Rejects <Name>" -ForEach @(
                @{ Name = '-ConfigurationSourcePath with -ConfigurationFile';      Splat = @{ ConfigurationSourcePath = 'CONFIG'; ConfigurationFile = 'NODE' } }
                @{ Name = '-ConfigurationSourcePath with -ConfigurationDirectory'; Splat = @{ ConfigurationSourcePath = 'CONFIG'; ConfigurationDirectory = 'DIR' } }
                @{ Name = '-ConfigurationFile with -ConfigurationDirectory';       Splat = @{ ConfigurationFile = 'NODE'; ConfigurationDirectory = 'DIR' } }
                @{ Name = '-ConfigurationFile with -CacheDirectory';               Splat = @{ ConfigurationFile = 'NODE'; CacheDirectory = 'CACHE' } }
                @{ Name = '-ConfigurationFile with -ConfigurationRevision';        Splat = @{ ConfigurationFile = 'NODE'; ConfigurationRevision = 'v1' } }
                @{ Name = '-ConfigurationDirectory with -RunnerSettings on the Datum path'; Splat = @{ ConfigurationSourcePath = 'CONFIG'; RunnerSettings = @{} } }
            ) {
                $placeholder = @{ CONFIG = $configDir; NODE = $nodeOne; DIR = $passthroughDir; CACHE = $cacheDir }
                $arguments = @{}
                foreach ($key in $Splat.Keys) {
                    $value = $Splat[$key]
                    if ($value -is [string] -and $placeholder.ContainsKey($value)) { $value = $placeholder[$value] }
                    $arguments[$key] = $value
                }

                { Invoke-DscRunner @arguments } | Should -Throw
            }
        }
    }
}
