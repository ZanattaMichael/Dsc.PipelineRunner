Describe "Invoke-DscRunner Function Tests" -Tag Unit, Runner {

    BeforeAll {

        # Load the function under test plus the loader it delegates to.
        @(
            (Get-FunctionPath 'Invoke-Action.ps1')
            (Get-FunctionPath 'Build-DatumConfiguration.ps1')
            (Get-FunctionPath 'Start-DscRunner.ps1')
            (Get-FunctionPath 'New-TemporaryDirectory.ps1')
        ) | ForEach-Object { . $_.FullName }

        . (Get-FunctionPath 'Invoke-DscRunner.ps1').FullName

        $configDir = Join-Path $TestDrive 'config'
        $cacheDir  = Join-Path $TestDrive 'cache'
        $null = New-Item -Path $configDir -ItemType Directory -Force
        $null = New-Item -Path $cacheDir  -ItemType Directory -Force

        # Isolate the entry point from the real lifecycle machinery.
        Mock -CommandName Invoke-Action -MockWith {
            if ($Hook -eq 'Source') { return $configDir }
            return $null
        }
        Mock -CommandName Build-DatumConfiguration
        Mock -CommandName Start-DscRunner
        Mock -CommandName New-TemporaryDirectory -MockWith { return @{ Path = $cacheDir } }
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
            Invoke-DscRunner -ConfigurationSourcePath $configDir
            Assert-MockCalled -CommandName New-TemporaryDirectory -Exactly 1 -Scope It
        }

        It "Forwards the report path to Start-DscRunner when supplied" {
            Invoke-DscRunner -ConfigurationSourcePath $configDir -CacheDirectory $cacheDir -ReportPath $cacheDir
            Assert-MockCalled -CommandName Start-DscRunner -Scope It -ParameterFilter {
                $ReportPath -eq $cacheDir
            }
        }
    }

}
