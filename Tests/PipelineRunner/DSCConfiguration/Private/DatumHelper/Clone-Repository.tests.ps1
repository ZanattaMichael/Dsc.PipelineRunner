
Describe 'Clone-Repository Function Tests' {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Clone-Repository.ps1').FullName
        $newTempDir = (Get-FunctionPath 'New-TemporaryDirectory.ps1').FullName

        . $preParseFilePath
        . $newTempDir

   

        Mock New-TemporaryDirectory { return (New-MockDirectoryPath) }
        Mock git

    }

    Context 'When called with valid parameters' {
        It 'Should clone the repository to the temporary directory' {
            # Arrange
            $DatumURLConfig = 'https://example.com/repo.git'

            # Act
            Clone-Repository -DatumURLConfig $DatumURLConfig

            # Assert
            Assert-MockCalled git -Exactly 1 -Scope It
        }
    }

    Context 'When called with invalid URL' {
        It 'Should handle the error when the Git URL is invalid' {
            # Arrange
            $DatumURLConfig = 'invalid-url'

            # Act & Assert
            { Clone-Repository -DatumURLConfig $DatumURLConfig } | Should -Throw
        }
    }
}
