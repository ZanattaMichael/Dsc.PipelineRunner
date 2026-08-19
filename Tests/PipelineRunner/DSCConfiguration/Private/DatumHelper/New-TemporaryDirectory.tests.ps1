
Describe 'New-TemporaryDirectory Function Tests' {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'New-TemporaryDirectory.ps1').FullName
        . $preParseFilePath

        Mock -CommandName New-Item -MockWith {
            param($ItemType, $Path)
            $path = New-MockDirectoryPath
            return @{
                PSPath = "Microsoft.PowerShell.Core\FileSystem::$(New-MockDirectoryPath)"
                PSParentPath = "Microsoft.PowerShell.Core\FileSystem::$(New-MockDirectoryPath)"
                PSChildName = "SomeRandomDir"
                PSDrive = @{ Name = "C" }
                PSProvider = @{ Name = "FileSystem" }
                PSIsContainer = $true
                BaseName = "SomeRandomDir"
                Mode = "d----"
                Name = "SomeRandomDir"
                FullName = "$path\SomeRandomDir"
                Parent = $path
            }
        }

    }

    Context 'When creating a new temporary directory' {
        It 'Should create a directory in the temp path' {
            # Arrange
            $tempPath = [System.IO.Path]::GetTempPath()

            # Act
            $result = New-TemporaryDirectory

            # Assert
            $result | Should -Not -BeNullOrEmpty
            Assert-MockCalled New-Item -Exactly 1 -Scope It
        }
    }

}
