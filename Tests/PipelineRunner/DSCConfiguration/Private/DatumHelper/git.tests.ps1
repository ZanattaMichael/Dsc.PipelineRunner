
Describe 'git Function Tests' {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'git.ps1').FullName
        . $preParseFilePath

        Mock Get-Command {
            
            return @{
                Name = 'git'
                CommandType = 'Application'
                Definition = New-MockFilePath 'git.exe'
            }
        }

    }

    Context 'When called with valid arguments' {
        It 'Should call git with the correct parameters' {
            # Arrange
            $global:JITToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))
            $args = @('clone', 'https://example.com/repo.git')

            # Act
            git @args

            # Assert
            Assert-MockCalled Get-Command -Exactly 1 -Scope It
        }
    }

    Context 'When git command fails' {
        It 'Should catch and return the error' {
            # Arrange
            $global:JITToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))
            $args = @('invalid-command')

            Mock Get-Command { throw "git command not found" }

            # Act
            $result = git @args

            # Assert
            $result | Should -Be "git command not found"
        }
    }
}
