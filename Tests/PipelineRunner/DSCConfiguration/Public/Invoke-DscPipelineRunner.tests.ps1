
Describe "Invoke-DscPipelineRunner Function Tests" {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Invoke-DscPipelineRunner.ps1').FullName

        @(
            (Get-FunctionPath 'Start-DscRunner.ps1')
            (Get-FunctionPath 'Merge-DscRunnerResult.ps1')
            (Get-FunctionPath 'Build-DatumConfiguration.ps1')
            (Get-FunctionPath 'Clone-Repository.ps1')
            (Get-FunctionPath 'Resolve-CacheDirectory.ps1')
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
        Mock -CommandName Get-Module -MockWith { @{ Name = 'AzureDevOpsDsc' } }
        Mock -CommandName Import-Module
        Mock -CommandName New-AzDoAuthenticationProvider
        Mock -CommandName Start-DscRunner
        Mock -CommandName Build-DatumConfiguration
        Mock -CommandName Get-ChildItem -MockWith { @() }
        Mock -CommandName Split-Path -MockWith {
            "$TestDrive\MockPath\"
        }
        Mock -CommandName Test-Path -MockWith { return $true }

        $exportConfigDir = New-MockDirectoryPath
        $ConfigurationSourcePath = New-MockDirectoryPath

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
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Throw "*No cache directory is set*"
        }

        It "Should not throw when the legacy AZDODSC_CACHE_DIRECTORY alias is set" {
            $env:AZDODSC_CACHE_DIRECTORY = "SomePath"
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
        }

        It "Should not throw when the generic PIPELINERUNNER_CACHE_DIRECTORY is set" {
            $env:PIPELINERUNNER_CACHE_DIRECTORY = "SomePath"
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
        }
    }

    Context "Execution Logic" {

        BeforeAll {
            Mock -CommandName Test-Path -MockWith { return $true }
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"

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

       It "Should create authentication provider with ManagedIdentity" {
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName New-AzDoAuthenticationProvider -Exactly 1 -Scope It -ParameterFilter { $useManagedIdentity }
       }

       It "Should create authentication provider with PAT" {
            $PAT = Get-MockPATToken
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken $PAT -AuthenticationType "PAT" -PATToken $PAT -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName New-AzDoAuthenticationProvider -Exactly 1 -Scope It -ParameterFilter { $PersonalAccessToken -eq $PAT }
       }

       It "Should build datum configuration" {
            Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath
            Assert-MockCalled -CommandName Build-DatumConfiguration -Exactly 1 -Scope It
       }
    }

    Context "When testing -ConfigurationSourcePath" {

        BeforeAll {
            $Env:AZDODSC_CACHE_DIRECTORY = "mocked"
        }

        AfterAll {
            $Env:AZDODSC_CACHE_DIRECTORY = $null
        }

        it "should call Clone-Repository with a valid URL" {
            Mock -CommandName 'Clone-Repository' -Verifiable -MockWith {
                return 'C:\mockPath'
            }
            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath "http://mockGitRepo.com/repo"} | Should -Not -Throw
            Should -InvokeVerifiable
        }

        it "should parse a valid file path if it isn't a valid URL" {
            Mock -CommandName 'Clone-Repository'
            Mock -CommandName 'Test-Path' -ParameterFilter {
                $path -eq $exportConfigDir
            } -Verifiable -MockWith { return $true }

            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Not -Throw
            Should -Invoke 'Clone-Repository' -Exactly 0
            Should -InvokeVerifiable
            Should -Invoke 'Start-DscRunner' -Exactly 0

        }

        it "should throw an error if it's neither a valid URL or FilePath" {

            Mock -CommandName 'Clone-Repository'
            Mock -CommandName 'Test-Path' -ParameterFilter {
                $path -eq $ConfigurationSourcePath
            } -Verifiable -MockWith { return $false }

            { Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir $exportConfigDir -JITToken "abc123" -Mode "test" -ConfigurationSourcePath $ConfigurationSourcePath } | Should -Throw "*Invalid ConfigurationSourcePath*"
            Should -Invoke 'Clone-Repository' -Exactly 0
            Should -InvokeVerifiable
            Should -Invoke 'Start-DscRunner' -Exactly 0            

        }



    }

}
