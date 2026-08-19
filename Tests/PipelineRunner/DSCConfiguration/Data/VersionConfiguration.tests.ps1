Describe "Test-CircularReferences" -Tag Unit, Runner, Rules, PreParse {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'VersionConfiguration.ps1').FullName

        . $preParseFilePath

    }

    Context "YAML Configuration Versioning" {

        It "should have a valid minimum version" {
            [Version]$minVersion = $ModuleConfigurationData.YAMLConfigurationMinimumVersion
            $minVersion | Should -BeOfType 'Version'
            $minVersion | Should -BeGreaterOrEqual ([Version]"0.0")
        }

        It "should have a valid maximum version" {
            [Version]$maxVersion = $ModuleConfigurationData.YAMLConfigurationMaximumVersion
            $maxVersion | Should -BeOfType 'Version'
            $maxVersion | Should -BeGreaterOrEqual $minVersion
        }
    }

    Context "PSDesiredStateConfiguration Versioning" {
        It "should have a valid minimum version" {
            [Version]$minVersion = $ModuleConfigurationData.PSDesiredStateConfigurationMinimumVersion
            $minVersion | Should -BeOfType 'Version'
            $minVersion | Should -BeGreaterOrEqual ([Version]"1.0")
        }

        It "should have a valid maximum version" {
            [Version]$maxVersion = $ModuleConfigurationData.PSDesiredStateConfigurationMaximumVersion
            $maxVersion | Should -BeOfType 'Version'
            $maxVersion | Should -BeGreaterOrEqual $minVersion
        }
    }

    Context "DSC Resource Versioning" {
        It "should have a valid minimum version" {
            [Version]$minVersion = $ModuleConfigurationData.DSCResourceMinimumVersion
            $minVersion | Should -BeOfType 'Version'
            $minVersion | Should -BeGreaterOrEqual ([Version]"1.0")
        }

        It "should have a valid maximum version" {
            [Version]$maxVersion = $ModuleConfigurationData.DSCResourceMaximumVersion
            $maxVersion | Should -BeOfType 'Version'
            $maxVersion | Should -BeGreaterOrEqual $minVersion
        }
    }

}