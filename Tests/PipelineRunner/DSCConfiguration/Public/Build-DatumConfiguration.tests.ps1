Describe "Build-DatumConfiguration Function Tests" -Tag Unit {

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

            # The compile step writes a fresh output file, so the empty-output guard
            # passes and we can verify the pre-existing file was cleared beforehand.
            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)
                        New-Item -ItemType File -Path (Join-Path $outputPath 'compiled.mof') -Force | Out-Null
                    }
                }
            }

            # Capture the filecount before the function is executed
            $fileCountBefore = (Get-ChildItem -Path $outputPath).Count

            # Execute the function
            Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath

            # Assert: the pre-existing TestFile.txt was cleared before compilation
            Test-Path (Join-Path $outputPath 'TestFile.txt') | Should -Be $false
            $fileCountBefore | Should -BeGreaterThan 0

        }

        It "Should invoke the script block asynchronously" {

            # Mock the Get-Command function; the script block writes an output file
            # (so the empty-output guard passes) and returns a result object.
            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)

                            New-Item -ItemType File -Path (Join-Path $outputPath 'compiled.mof') -Force | Out-Null
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

        It "Should throw if the compilation script block raises an error" {

            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)
                        Write-Error "simulated Datum compile failure"
                    }
                }
            }

            { Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath } |
                Should -Throw -ErrorId "*failed in the script block*"
        }

        It "Should throw if the compilation produces no output" {

            # Script block succeeds but writes nothing to the output directory
            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)
                    }
                }
            }

            { Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath } |
                Should -Throw -ErrorId "*produced no output*"
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