Describe "Start-LCM Function Tests" -Tag Unit {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Build-DatumConfiguration.ps1').FullName

        . $preParseFilePath

        # Mock the DatumConfigurationScriptBlock function. This function is not available in the test environment.
        function DatumConfigurationScriptBlock { param($outputPath, $configurationPath) }

    }

    Context "When OutputPath and ConfigurationPath are valid" {

        BeforeAll {
            Mock -CommandName Test-Path -MockWith { return $false }
        }

        BeforeEach {
            $outputPath = Join-Path $TestDrive "TestOutput"
            $configurationPath = Join-Path $TestDrive "TestConfiguration"

            # Setup: Create test directories and files
            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
            New-Item -ItemType File -Path "$outputPath\TestFile.txt" -Force | Out-Null
            New-Item -ItemType Directory -Path $configurationPath -Force | Out-Null

            # Mock Test-Path to return true for valid paths
            Mock -CommandName Test-Path -MockWith { return $true }
        }

        It "Should clear the output directory" {

            # Capture the filecount before the function is executed
            $fileCountBefore = (Get-ChildItem -Path $outputPath).Count

            # Execute the function
            Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath


            # Assert: Check that the output directory is cleared
            (Get-ChildItem -Path $outputPath).Count | Should -Be 0
            $fileCountBefore | Should -BeGreaterThan 0

        }

        It "Should invoke the script block asynchronously" {

            # Mock the Get-Command function
            Mock -CommandName Get-Command -MockWith { 
                return [PSCustomObject]@{ 
                    ScriptBlock = { 
                        param($outputPath, $configurationPath)
    
                            @{
                                OutputPath = $outputPath
                                ConfigurationPath = $configurationPath
                            }
                    }
                }
            }

            # Execute the function
            $result = Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath

            # Assert: Verify that the mocked script block was executed
            $result.OutputPath | Should -Be $outputPath
            $result.ConfigurationPath | Should -Be $configurationPath

        }
    }

    Context "When parameters are invalid" {

        It "Should throw an error if OutputPath does not exist" {
            $invalidPath = Join-Path $TestDrive "NonExistentPath"
            $configurationPath = Join-Path $TestDrive "TestConfiguration"

            New-Item -ItemType Directory -Path $configurationPath -Force | Out-Null

            { Build-DatumConfiguration -OutputPath $invalidPath -ConfigurationPath $configurationPath } | 
            Should -Throw -ErrorId "ParameterArgumentValidationError,Build-DatumConfiguration"
        }

        It "Should throw an error if ConfigurationPath does not exist" {
            $outputPath = Join-Path $TestDrive "TestOutput"
            $invalidPath = New-MockDirectoryPath

            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

            { Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $invalidPath } | 
            Should -Throw -ErrorId "ParameterArgumentValidationError,Build-DatumConfiguration"
        }
    }    
 

}