Describe "Invoke-DscPipelineRunner Function Tests" {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Invoke-DscPipelineRunner.ps1').FullName

        @(
            (Get-FunctionPath 'Start-DscRunner.ps1')
            (Get-FunctionPath 'Merge-DscRunnerResult.ps1')
            (Get-FunctionPath 'Build-DatumConfiguration.ps1')
            (Get-FunctionPath 'Assert-SecureGitUrl.ps1')
            (Get-FunctionPath 'Clone-Repository.ps1')
            (Get-FunctionPath 'Register-RunnerTemporaryDirectory.ps1')
            (Get-FunctionPath 'Remove-RunnerTemporaryDirectory.ps1')
            (Get-FunctionPath 'Get-PipelineAuthToken.ps1')
            (Get-FunctionPath 'Resolve-CacheDirectory.ps1')
            (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1')
        ) | ForEach-Object {
            . $_.FullName
        }

        . $preParseFilePath

        # Mock Authentication Provider Function
        Function New-AzDoAuthenticationProvider {
            param($OrganizationName, $PersonalAccessToken, [switch]$useManagedIdentity)
        }


        # Mock necessary commands to prevent actual execution during tests
        Mock -CommandName Get-DSCResource -MockWith { @{ Version = @{ Major = 2 } } }
        Mock -CommandName Get-Module -MockWith { @{ Name = 'AzureDevOpsDscNative' } }
        Mock -CommandName Import-Module
        Mock -CommandName New-AzDoAuthenticationProvider
        Mock -CommandName Start-DscRunner
        Mock -CommandName Build-DatumConfiguration
        # Get-PipelineRunnerSetting is loaded so it can be mocked to feed controlled settings.
        Mock -CommandName Get-PipelineRunnerSetting -MockWith { return $null }
        Mock -CommandName Get-ChildItem -MockWith { @() }
        Mock -CommandName Split-Path -MockWith {
            "$TestDrive\MockPath\"
        }
        Mock -CommandName Test-Path -MockWith { return $true }
        Mock -CommandName Remove-RunnerTemporaryDirectory

        $exportConfigDir = New-MockDirectoryPath
        $ConfigurationSourcePath = New-MockDirectoryPath

        function Get-MockPATToken {
            param(
                [int]$Length = 52
            )

            # Define characters allowed in a PAT token
            $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

            # Generate a random token of specified length
            -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
        }
    }

    Context "Environment Variable Check" {

            BeforeAll {
                Mock -CommandName Test-Path -MockWith { return $true }
            }

            AfterEach {
                # Clear both the generic name and the back-compat alias between cases.
                Remove-Item Env:PIPELINERUNNER_CACHE_DIRECTORY -ErrorAction SilentlyContinue
                Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
            }

        It "Should throw an error if no cache directory environment variable is set" {
            Remove-Item Env:PIPELINERUNNER_CACHE_DIRECTORY -ErrorAction SilentlyContinue
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Throw "*No cache directory is set*"
        }

        It "Should not throw when the legacy AZDODSC_CACHE_DIRECTORY alias is set" {
            $env:AZDODSC_CACHE_DIRECTORY = "SomePath"
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
        }

        It "Should not throw when the generic PIPELINERUNNER_CACHE_DIRECTORY is set" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = "SomePath"
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
        }
    }

    Context "Parameter contract" {

        BeforeAll {
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
        }

        AfterAll {
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        }

        It "Should expose -ExportConfigDir, not the old lowercase -exportConfigDir alias" {
            # PowerShell parameter binding is case-insensitive, so the rename is observable
            # through the declared parameter name rather than through binding behaviour (#17).
            $parameter = (Get-Command Invoke-DscPipelineRunner).Parameters.Values |
                Where-Object { $_.Name -eq 'ExportConfigDir' }

            $parameter | Should -Not -BeNullOrEmpty
            $parameter.Name | Should -BeExactly 'ExportConfigDir'
            $parameter.Aliases | Should -BeNullOrEmpty
        }

        It "Should no longer expose -AuthenticationType" {
            (Get-Command Invoke-DscPipelineRunner).Parameters.Keys | Should -Not -Contain 'AuthenticationType'
        }

        It "Should default -Mode to Test when it is omitted" {
            (Get-Command Invoke-DscPipelineRunner).Parameters['Mode'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Not -Contain $true

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It
        }

        It "Should not require -JITToken" {
            (Get-Command Invoke-DscPipelineRunner).Parameters['JITToken'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Not -Contain $true
        }

        It "Should default to the ManagedIdentity parameter set" {
            (Get-Command Invoke-DscPipelineRunner).DefaultParameterSet | Should -Be 'ManagedIdentity'
        }

        It "Should accept a <Length>-character PAT" -TestCases @(
            @{ Length = 52 }
            @{ Length = 84 }
        ) {
            $PAT = Get-MockPATToken -Length $Length
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath -PATToken $PAT } | Should -Not -Throw
        }

        It "Should reject a PAT containing invalid characters" {
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath -PATToken ('!' * 52) } | Should -Throw
        }

        It "Should reject an implausibly short PAT" {
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath -PATToken 'abc' } | Should -Throw
        }
    }

    Context "Execution Logic" {

        BeforeAll {
            Mock -CommandName Test-Path -MockWith { return $true }
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
        }

        AfterAll {
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        }

       It "Should create authentication provider with ManagedIdentity" {
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName New-AzDoAuthenticationProvider -Exactly 1 -Scope It -ParameterFilter { $useManagedIdentity }
       }

       It "Should create authentication provider with PAT" {
            $PAT = Get-MockPATToken
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -PATToken $PAT -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName New-AzDoAuthenticationProvider -Exactly 1 -Scope It -ParameterFilter { $PersonalAccessToken -eq $PAT }
       }

       It "Should not fall back to managed identity when a PAT is supplied" {
            # -AuthenticationType used to default to ManagedIdentity independently of the
            # parameter set, so a caller passing -PATToken silently got managed identity (#17).
            $PAT = Get-MockPATToken
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -PATToken $PAT -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName New-AzDoAuthenticationProvider -Exactly 0 -Scope It -ParameterFilter { $useManagedIdentity }
       }

       It "Should build datum configuration" {
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It
       }
    }

    Context "When testing -ConfigurationSourcePath" {

        BeforeAll {
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
        }

        AfterAll {
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        }

        it "should call Clone-Repository with a valid URL" {
            Mock -CommandName 'Clone-Repository' -Verifiable -MockWith {
                return 'C:\mockPath'
            }
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo"} | Should -Not -Throw
            Should -InvokeVerifiable
        }

        it "should pass -ConfigurationRevision through to Clone-Repository" {
            Mock -CommandName 'Clone-Repository' -MockWith { return 'C:\mockPath' }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo" -ConfigurationRevision 'v1.2.3'

            Should -Invoke 'Clone-Repository' -Exactly 1 -ParameterFilter { $Revision -eq 'v1.2.3' }
        }

        it "should not pass a revision when none was supplied" {
            Mock -CommandName 'Clone-Repository' -MockWith { return 'C:\mockPath' }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo"

            Should -Invoke 'Clone-Repository' -Exactly 1 -ParameterFilter { -not $PSBoundParameters.ContainsKey('Revision') }
        }

        it "should reject an http:// configuration URL" {
            # #31: the configuration is executed as trusted code, so it must not be fetched
            # over an unencrypted transport. The rejection comes from Clone-Repository, which
            # is deliberately NOT mocked here.
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "http://mockGitRepo.com/repo" } |
                Should -Throw "*not permitted*"
        }

        it "should parse a valid file path if it isn't a valid URL" {
            Mock -CommandName 'Clone-Repository'
            Mock -CommandName 'Test-Path' -ParameterFilter {
                $path -eq $exportConfigDir
            } -Verifiable -MockWith { return $true }

            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
            Should -Invoke 'Clone-Repository' -Exactly 0
            Should -InvokeVerifiable
            Should -Invoke 'Start-DscRunner' -Exactly 0

        }

        it "should throw an error if it's neither a valid URL or FilePath" {

            Mock -CommandName 'Clone-Repository'
            Mock -CommandName 'Test-Path' -ParameterFilter {
                $path -eq $ConfigurationSourcePath
            } -Verifiable -MockWith { return $false }

            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Throw "*Invalid ConfigurationSourcePath*"
            Should -Invoke 'Clone-Repository' -Exactly 0
            Should -InvokeVerifiable
            Should -Invoke 'Start-DscRunner' -Exactly 0            

        }
    }

    Context "-RunnerSettings forwarding (#57 §2/§3/§4)" {

        BeforeAll {
            Mock -CommandName Test-Path -MockWith { return $true }
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
            Mock -CommandName Get-ChildItem -MockWith { @([pscustomobject]@{ FullName = "$TestDrive\node1.yml" }) }
        }

        AfterAll {
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        }

        It "resolves PipelineRunnerSettings from the configuration source directory" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ AllowExecutionScripts = $true } }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath

            Assert-MockCalled -CommandName Get-PipelineRunnerSetting -Exactly 1 -Scope It -ParameterFilter {
                $ConfigurationDirectory -eq $ConfigurationSourcePath
            }
        }

        It "forwards the resolved settings to Start-DscRunner as -RunnerSettings" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return @{ AllowExecutionScripts = $true } }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath

            Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                $RunnerSettings -and $RunnerSettings['AllowExecutionScripts'] -eq $true
            }
        }

        It "does not pass -RunnerSettings when no PipelineRunnerSettings block is found" {
            Mock -CommandName Get-PipelineRunnerSetting -MockWith { return $null }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath $ConfigurationSourcePath

            Assert-MockCalled -CommandName Start-DscRunner -Exactly 1 -Scope It -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('RunnerSettings')
            }
        }
    }

    Context "Clone lifecycle" {

        BeforeAll {
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
        }

        AfterAll {
            Remove-Item Env:AZDODSC_CACHE_DIRECTORY -ErrorAction SilentlyContinue
        }

        it "should clean up the clone after a successful run" {
            Mock -CommandName 'Clone-Repository' -MockWith { return 'C:\mockPath' }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo"

            Should -Invoke 'Remove-RunnerTemporaryDirectory' -Exactly 1 -ParameterFilter { $Path -eq 'C:\mockPath' }
        }

        it "should clean up the clone even when the run throws" {
            Mock -CommandName 'Clone-Repository' -MockWith { return 'C:\mockPath' }
            Mock -CommandName 'Build-DatumConfiguration' -MockWith { throw 'compile failed' }

            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo" } | Should -Throw

            Should -Invoke 'Remove-RunnerTemporaryDirectory' -Exactly 1 -ParameterFilter { $Path -eq 'C:\mockPath' }
        }

        it "should leave the clone in place with -KeepTemporaryDirectory" {
            Mock -CommandName 'Clone-Repository' -MockWith { return 'C:\mockPath' }

            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir $exportConfigDir -ConfigurationSourcePath "https://mockGitRepo.com/repo" -KeepTemporaryDirectory

            Should -Invoke 'Remove-RunnerTemporaryDirectory' -Exactly 0
        }
    }

}
