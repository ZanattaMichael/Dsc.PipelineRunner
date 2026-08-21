Describe "Get-PipelineRunnerSetting Function Tests" -Tag Unit, Configuration {

    BeforeAll {
        . (Get-FunctionPath 'Get-PipelineRunnerSetting.ps1').FullName

        # The file read is faked so the tests never depend on a real Datum.yml on disk.
        Mock -CommandName Get-Content -MockWith { return 'yaml-text' }
    }

    Context "Definition file resolution" {

        It "Returns null when the definition file is absent" {
            Mock -CommandName Test-Path -MockWith { return $false }

            Get-PipelineRunnerSetting -ConfigurationDirectory 'TestDir' | Should -BeNullOrEmpty

            Assert-MockCalled -CommandName Get-Content -Exactly 0 -Scope It
        }

        It "Reads a custom definition file name when supplied" {
            Mock -CommandName Test-Path -MockWith { return $true }
            Mock -CommandName ConvertFrom-Yaml -MockWith {
                return @{ PipelineRunnerSettings = @{ Engine = 'DscV2' } }
            }

            $null = Get-PipelineRunnerSetting -ConfigurationDirectory 'TestDir' -DefinitionFileName 'Custom.yml'

            Assert-MockCalled -CommandName Test-Path -Exactly 1 -Scope It -ParameterFilter {
                $LiteralPath -like '*Custom.yml'
            }
        }
    }

    Context "Settings extraction" {

        BeforeEach {
            Mock -CommandName Test-Path -MockWith { return $true }
        }

        It "Returns the PipelineRunnerSettings block when present" {
            Mock -CommandName ConvertFrom-Yaml -MockWith {
                return @{
                    PipelineRunnerSettings = @{ Engine = 'DscV3'; DSCResourceVersion = '3.0' }
                }
            }

            $settings = Get-PipelineRunnerSetting -ConfigurationDirectory 'TestDir'

            $settings.Engine | Should -Be 'DscV3'
            $settings.DSCResourceVersion | Should -Be '3.0'
        }

        It "Returns null when the document has no PipelineRunnerSettings block" {
            Mock -CommandName ConvertFrom-Yaml -MockWith { return @{ SomethingElse = 1 } }

            Get-PipelineRunnerSetting -ConfigurationDirectory 'TestDir' | Should -BeNullOrEmpty
        }

        It "Returns null when the document is not a mapping" {
            Mock -CommandName ConvertFrom-Yaml -MockWith { return $null }

            Get-PipelineRunnerSetting -ConfigurationDirectory 'TestDir' | Should -BeNullOrEmpty
        }
    }
}
