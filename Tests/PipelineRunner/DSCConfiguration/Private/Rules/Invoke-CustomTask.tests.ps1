# Skip these tests by default
Describe "Invoke-CustomTask Function Tests" -Tag Unit, Runner, Configuration {

    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . $preParseFilePath

        # Setup a temp powershell file to be dot sourced
        $rulePath = Join-Path $TestDrive '\Pipeline Rules\Custom\MyCustomTask.ps1'
        # Create the folderpath
        $null = New-Item -Path (Split-Path $rulePath) -ItemType Directory -Force
        
        '
        param(
            [Object[]]$PipelineResources
        )
        return $PipelineResources
        ' | Set-Content -Path $rulePath

        Mock -CommandName Get-Module -MockWith { return (
            @{
                moduleBase = $TestDrive 
            })
        }
        
    }

    It "Should trigger the custom task script" {
        $tasks = @("Task1", "Task2")
        $customTaskName = "MyCustomTask"

        $result = Invoke-CustomTask -Tasks $tasks -CustomTaskName $customTaskName

        $result | Should -Be $tasks
    }

    It "Should throw an error if the custom task script does not exist" {
        $tasks = @("Task1", "Task2")
        $customTaskName = "NonExistentTask"

        { Invoke-CustomTask -Tasks $tasks -CustomTaskName $customTaskName } | Should -Throw
    }

    AfterAll {
        # Remove the temp powershell file
        Remove-Item -Path $rulePath -Force
    }


}
