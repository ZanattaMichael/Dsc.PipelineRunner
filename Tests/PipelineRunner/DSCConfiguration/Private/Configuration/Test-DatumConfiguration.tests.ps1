Describe "Test-DatumConfiguration Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Test-DatumConfiguration.ps1').FullName

        . $preParseFilePath

        # Load the module's REAL version bounds rather than restating them here. Every test
        # below that is not deliberately exercising an out-of-range case uses these, so the
        # suite tracks source/Public/VersionConfiguration.ps1 instead of asserting against
        # invented bounds that no shipped configuration is ever measured against.
        . (Get-FunctionPath 'VersionConfiguration.ps1').FullName
        $script:ShippedConfigurationData = $ModuleConfigurationData

        # The repository's own Example Configuration is the reference configuration: the
        # versions it declares are the ones every test fixture below uses, so a fixture
        # cannot drift away from what the product actually ships.
        $script:RepositoryRoot = $Global:RepositoryRoot
        $script:ExampleDatumPath = Join-Path $script:RepositoryRoot 'Example Configuration/Datum.yml'
        $script:ExampleSettings = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $script:ExampleDatumPath -Raw)).PipelineRunnerSettings

        $script:ConfigurationVersion  = $script:ExampleSettings.ConfigurationVersion   # 0.2
        $script:PipelineRunnerVersion = $script:ExampleSettings.PipelineRunnerVersion  # 1.0.0

        # Builds the smallest Datum object Test-DatumConfiguration accepts, defaulting to the
        # versions the shipped Example Configuration declares.
        function New-TestDatum {
            param(
                $ConfigurationVersion = $script:ConfigurationVersion,
                $PipelineRunnerVersion = $script:PipelineRunnerVersion
            )

            @{
                '__Definition' = @{
                    PipelineRunnerSettings = @{
                        ConfigurationVersion  = $ConfigurationVersion
                        PipelineRunnerVersion = $PipelineRunnerVersion
                        Engine                = 'DscV2'
                    }
                }
            }
        }

        # Mocking Get-Module to return controlled version information. Both versions sit
        # inside the shipped bounds (PSDesiredStateConfiguration 2.0-2.9, Dsc.PipelineRunner
        # 1.0-1.9), and the runner version matches the manifest's own ModuleVersion.
        Mock -CommandName Get-Module -MockWith {
            param($name)
            switch ($name) {
                'PSDesiredStateConfiguration' { @{ Version = [version]"2.0.0" } }
                'Dsc.PipelineRunner' { @{ Version = [version]"1.0.0" } }
                default { $null }
            }
        }


        Mock -CommandName Write-Warning

    }

    Context "When Datum Configuration is Valid" {
        It "should pass without errors" {
            $datumConfig = New-TestDatum

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Not -Throw
            Assert-MockCalled Write-Warning -Exactly 0
        }
    }

    Context "When PipelineRunnerSettings is Missing" {
        It "should throw an error" {
            $datumConfig = @{}
            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*PipelineRunnerSettings*"
            Assert-MockCalled Write-Warning -Exactly 0
        }
    }

    Context "When Versions are Invalid" {
        It "should throw an error if ConfigurationVersion is not a valid version" {
            $datumConfig = New-TestDatum -ConfigurationVersion "invalid"

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*valid version*"
            Assert-MockCalled Write-Warning -Exactly 0
        }

        It "should throw an error if PipelineRunnerVersion is not a valid version" {
            $datumConfig = New-TestDatum -PipelineRunnerVersion "not-a-version"

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*valid version*"
            Assert-MockCalled Write-Warning -Exactly 0
        }
    }

    Context "When Datum Configuration Version is Out of Range" {

        # The shipped range is 0.1 to 0.9, so these are the two versions immediately
        # outside it rather than arbitrary far-away numbers.
        It "should throw an error if the version is below the supported minimum" {
            $datumConfig = New-TestDatum -ConfigurationVersion "0.0"

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*outside the valid range*"
            Assert-MockCalled Write-Warning -Exactly 0
        }

        It "should throw an error if the version is above the supported maximum" {
            $datumConfig = New-TestDatum -ConfigurationVersion "1.0"

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*outside the valid range*"
            Assert-MockCalled Write-Warning -Exactly 0
        }
    }

    Context "When Datum Configuration Version is Outdated" {
        It "should issue a warning if within two minor versions of the supported maximum" {

            # Warns at (maximum - 0.2) and above; the shipped maximum is 0.9, so 0.8 warns
            # and the Example Configuration's own 0.2 does not.
            $datumConfig = New-TestDatum -ConfigurationVersion "0.8"

            $ModuleConfigurationData = $script:ShippedConfigurationData

            Test-DatumConfiguration -Datum $datumConfig
            Assert-MockCalled Write-Warning -Exactly 1

        }
    }

    Context "When the Dsc.PipelineRunner version is out of range" {

        It "should throw if the installed version is below the configured minimum" {
            $datumConfig = New-TestDatum

            # Installed Dsc.PipelineRunner is 1.0.0 (mocked Get-Module). The bounds are
            # raised above it deliberately - the shipped 1.0 minimum admits the installed
            # version, so the check can only be exercised by overriding it.
            $ModuleConfigurationData = @{
                YAMLConfigurationMinimumVersion = $script:ShippedConfigurationData.YAMLConfigurationMinimumVersion
                YAMLConfigurationMaximumVersion = $script:ShippedConfigurationData.YAMLConfigurationMaximumVersion
                PSDesiredStateConfigurationMinimumVersion = $script:ShippedConfigurationData.PSDesiredStateConfigurationMinimumVersion
                PSDesiredStateConfigurationMaximumVersion = $script:ShippedConfigurationData.PSDesiredStateConfigurationMaximumVersion
                DSCResourceMinimumVersion = "1.5"
                DSCResourceMaximumVersion = "1.9"
            }

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*outside the valid range*"
        }

        It "should warn and skip when the version bounds are not configured" {
            $datumConfig = New-TestDatum

            # DSCResourceMinimumVersion / DSCResourceMaximumVersion intentionally omitted
            $ModuleConfigurationData = @{
                YAMLConfigurationMinimumVersion = $script:ShippedConfigurationData.YAMLConfigurationMinimumVersion
                YAMLConfigurationMaximumVersion = $script:ShippedConfigurationData.YAMLConfigurationMaximumVersion
                PSDesiredStateConfigurationMinimumVersion = $script:ShippedConfigurationData.PSDesiredStateConfigurationMinimumVersion
                PSDesiredStateConfigurationMaximumVersion = $script:ShippedConfigurationData.PSDesiredStateConfigurationMaximumVersion
            }

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Not -Throw
            Assert-MockCalled Write-Warning -Exactly 1
        }
    }

    Context "When the PSDesiredStateConfiguration is Outdated" {

        It "Should pass when the installed version is inside the shipped range" {
            $datumConfig = New-TestDatum

            # Mocked PSDesiredStateConfiguration is 2.0.0; the shipped range is 2.0 to 2.9.
            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Not -Throw
            Assert-MockCalled Write-Warning -Exactly 0
        }

        It "Should throw an error if outside the valid range" {
            $datumConfig = New-TestDatum

            # Bounds raised above the mocked installed 2.0.0 so the check actually fires.
            # Previously this test used in-range bounds and asserted nothing about the
            # throw it is named for, so the branch was never covered.
            $ModuleConfigurationData = @{
                YAMLConfigurationMinimumVersion = $script:ShippedConfigurationData.YAMLConfigurationMinimumVersion
                YAMLConfigurationMaximumVersion = $script:ShippedConfigurationData.YAMLConfigurationMaximumVersion
                PSDesiredStateConfigurationMinimumVersion = "2.5"
                PSDesiredStateConfigurationMaximumVersion = "2.9"
                DSCResourceMinimumVersion = $script:ShippedConfigurationData.DSCResourceMinimumVersion
                DSCResourceMaximumVersion = $script:ShippedConfigurationData.DSCResourceMaximumVersion
            }

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Throw -ErrorId "*outside the valid range*"
        }

    }

    Context "When validating the repository's own Example Configuration" {

        # These are the drift guards. The Example Configuration is what every consumer copies
        # and what both self-hosted lifecycle suites compile, so its declared versions must
        # keep reflecting the module that ships alongside it.

        It "declares a ConfigurationVersion inside the module's supported range" {
            $declared = $script:ConfigurationVersion -as [Version]
            $declared | Should -Not -BeNullOrEmpty

            $minimum = $script:ShippedConfigurationData.YAMLConfigurationMinimumVersion -as [Version]
            $maximum = $script:ShippedConfigurationData.YAMLConfigurationMaximumVersion -as [Version]

            [decimal]::Parse("$($declared.Major).$($declared.Minor)") |
                Should -BeGreaterOrEqual ([decimal]::Parse("$($minimum.Major).$($minimum.Minor)"))
            [decimal]::Parse("$($declared.Major).$($declared.Minor)") |
                Should -BeLessOrEqual ([decimal]::Parse("$($maximum.Major).$($maximum.Minor)"))
        }

        It "declares the PipelineRunnerVersion that the module manifest ships" {
            $manifestPath = Join-Path $script:RepositoryRoot 'source/Dsc.PipelineRunner.psd1'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion -as [Version]

            ($script:PipelineRunnerVersion -as [Version]) | Should -Be $manifestVersion
        }

        It "declares a PipelineRunnerVersion inside the module's supported range" {
            $declared = $script:PipelineRunnerVersion -as [Version]

            $declared | Should -BeGreaterOrEqual ($script:ShippedConfigurationData.DSCResourceMinimumVersion -as [Version])
            $declared | Should -BeLessOrEqual ([Version]"$($script:ShippedConfigurationData.DSCResourceMaximumVersion).9999")
        }

        It "passes Test-DatumConfiguration against the module's real version bounds" {
            $datumConfig = @{
                '__Definition' = @{
                    PipelineRunnerSettings = $script:ExampleSettings
                }
            }

            $ModuleConfigurationData = $script:ShippedConfigurationData

            { Test-DatumConfiguration -Datum $datumConfig } | Should -Not -Throw
            Assert-MockCalled Write-Warning -Exactly 0
        }
    }
}
