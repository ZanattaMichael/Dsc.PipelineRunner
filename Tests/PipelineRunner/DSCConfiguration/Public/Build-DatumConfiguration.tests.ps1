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

            # Assert: the pre-existing TestFile.txt was cleared before compilation.
            # Test-Path is mocked to $true in this context, so query the real filesystem
            # directly to confirm the clear actually happened.
            [System.IO.File]::Exists((Join-Path $outputPath 'TestFile.txt')) | Should -BeFalse
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

    Context "Path-traversal guard (#33)" {

        # The guard runs before any file is touched, so a rejected OutputPath must throw
        # without ever reaching the clear/compile machinery. These tests assert the refusal
        # message and, on the happy path, that a permitted OutputPath is still processed.

        It "Should refuse an OutputPath that escapes an explicit -AllowedRoot" {
            # Two real sibling directories: the output path is NOT beneath the allowed root.
            $allowedRoot = Join-Path $TestDrive "root"
            $configurationPath = Join-Path $TestDrive "config"
            $escapingOutput = Join-Path $TestDrive "escape"
            New-Item -ItemType Directory -Path $allowedRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $configurationPath -Force | Out-Null
            New-Item -ItemType Directory -Path $escapingOutput -Force | Out-Null

            { Build-DatumConfiguration -OutputPath $escapingOutput -ConfigurationPath $configurationPath -AllowedRoot $allowedRoot } |
                Should -Throw -ExpectedMessage "*outside the permitted working-directory root*"
        }

        It "Should refuse an OutputPath outside the system temp directory when -AllowedRoot is omitted" {
            # With no -AllowedRoot, the guard defaults to the system temp directory. Build a
            # path that resolves to a sibling of temp (via '..') so it lands outside it. The
            # directories do not need to exist — Test-Path is mocked so the ValidateScript
            # passes and the guard, not the filesystem, is what rejects the path.
            Mock -CommandName Test-Path -MockWith { $true }

            $tempRoot = [System.IO.Path]::GetTempPath()
            $escapingOutput = Join-Path $tempRoot ('..' + [System.IO.Path]::DirectorySeparatorChar + "pipelinerunner-escape-$([guid]::NewGuid())")
            $configurationPath = Join-Path $TestDrive "config-temp"

            { Build-DatumConfiguration -OutputPath $escapingOutput -ConfigurationPath $configurationPath } |
                Should -Throw -ExpectedMessage "*outside the permitted working-directory root*"
        }

        It "Should permit an OutputPath that sits beneath -AllowedRoot" {
            # OutputPath nested inside the allowed root must be accepted and compiled.
            $allowedRoot = Join-Path $TestDrive "permitted-root"
            $outputPath = Join-Path $allowedRoot "output"
            $configurationPath = Join-Path $TestDrive "permitted-config"
            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
            New-Item -ItemType Directory -Path $configurationPath -Force | Out-Null

            # The compile step writes a file so the empty-output guard passes.
            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)
                        New-Item -ItemType File -Path (Join-Path $outputPath 'compiled.mof') -Force | Out-Null
                    }
                }
            }

            { Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath -AllowedRoot $allowedRoot } |
                Should -Not -Throw
        }
    }

    Context "Trust-boundary warning (#27)" {

        BeforeEach {
            $outputPath = Join-Path $TestDrive "warn-output"
            $configurationPath = Join-Path $TestDrive "warn-config"
            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
            New-Item -ItemType Directory -Path $configurationPath -Force | Out-Null

            # A minimal compile that writes an output file so the empty-output guard passes.
            Mock -CommandName Get-Command -MockWith {
                return [PSCustomObject]@{
                    ScriptBlock = {
                        param($outputPath, $configurationPath)
                        New-Item -ItemType File -Path (Join-Path $outputPath 'compiled.mof') -Force | Out-Null
                    }
                }
            }
        }

        It "warns that remote configuration executes as trusted code when -SourceIsRemote is set" {
            Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath `
                -AllowedRoot $outputPath -SourceIsRemote -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            ($warnings -join "`n") | Should -Match 'executed as trusted PowerShell code'
        }

        It "does not warn for a local (non-remote) configuration source" {
            Build-DatumConfiguration -OutputPath $outputPath -ConfigurationPath $configurationPath `
                -AllowedRoot $outputPath -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

            $warnings | Should -BeNullOrEmpty
        }
    }

}