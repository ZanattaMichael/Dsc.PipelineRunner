Describe 'DatumConfigurationScriptBlock Function Tests' {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'DatumConfigurationScriptBlock.ps1').FullName
        $testDatumConfigurationFilePath = (Get-FunctionPath 'Test-DatumConfiguration.ps1').FullName
        $resolveAzDoDatumProjectFilePath = (Get-FunctionPath 'Resolve-DscDatumProject.ps1').FullName

        . $preParseFilePath
        . $testDatumConfigurationFilePath
        . $resolveAzDoDatumProjectFilePath

        # Mock necessary commands to isolate the function's behavior
        Mock -CommandName New-DatumStructure -MockWith { @{Projects = @{}} }
        Mock -CommandName Test-DatumConfiguration
        Mock -CommandName Resolve-DscDatumProject
        Mock -CommandName Set-Location
        Mock -CommandName Import-Module

    }

    Context "Function Invocation Check" {

        It "Should throw an error when executed directly" {
            # Simulate direct execution
            $MyInvocation = [PSCustomObject]@{ MyCommand = [PSCustomObject]@{ Name = 'DatumConfigurationScriptBlock' } }
            
            { DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -ConfigurationPath (New-MockDirectoryPath) } | Should -Throw  "This function is intended to be used as a script block in a separate thread using the Build-DatumConfiguration function."

        }
    }

    Context "Module Import Verification" {

        It "Should import all necessary modules" {
            # Execute the function in a simulated environment
            DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -configurationPath (New-MockDirectoryPath) -isTest

            # Verify that Import-Module was called with expected parameters
            Assert-MockCalled -CommandName Import-Module -Exactly 1 -Scope It -ParameterFilter { 
                ($Name -eq 'Dsc.PipelineRunner') -or
                ($Name -eq 'powershell-yaml') -or
                ($Name -eq 'datum') -or
                ($Name -eq 'datum.invokecommand')
            }
        }
    }

    Context "Directory Change Verification" {

        It "Should change the current directory to the specified configuration path" {

            $ConfigurationPath = New-MockDirectoryPath
            DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -ConfigurationPath $ConfigurationPath -isTest

            Assert-MockCalled -CommandName Set-Location -Exactly 1 -ParameterFilter { $Path -eq $ConfigurationPath }
        }
    }

    Context "Datum Structure Creation" {

        It "Should create a new Datum structure from the definition file" {
            DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -ConfigurationPath (New-MockDirectoryPath) -isTest

            Assert-MockCalled -CommandName New-DatumStructure -Times 1
        }
    }

    Context "Configuration Testing" {

        It "Should test the Datum configuration" {
            DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -ConfigurationPath (New-MockDirectoryPath) -isTest

            Assert-MockCalled -CommandName Test-DatumConfiguration -Exactly 1
        }
    }

    Context "Project Node Resolution" {

        It "Should resolve each project node correctly" {
            # Mock the return value of New-DatumStructure to simulate projects
            Mock -CommandName New-DatumStructure -MockWith {
                @{
                    Projects = [PSCustomObject]@{
                        ProjectType1 = [PSCustomObject]@{
                            ProjectNode1 = @{ Name = 'Node1' }
                            ProjectNode2 = @{ Name = 'Node2' }
                        }
                    }
                }
            }

            DatumConfigurationScriptBlock -OutputPath (New-MockDirectoryPath) -ConfigurationPath (New-MockDirectoryPath) -isTest

            Assert-MockCalled -CommandName Resolve-DscDatumProject -Exactly 2 -Scope It
        }
    }

}