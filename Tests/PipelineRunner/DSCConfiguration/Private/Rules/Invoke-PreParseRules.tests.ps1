Describe "Invoke-PreParseRules Function Tests" -Tag Unit, Runner, Configuration {


    BeforeAll {

        # Load the functions to test
        $preParseFilePath = (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . $preParseFilePath

        # Setup a temp powershell file to be dot sourced
        $rulePath = Join-Path $TestDrive '\Pipeline Rules\PreParse\MyCustomRule.ps1'
        $rulePath2 = Join-Path $TestDrive '\Pipeline Rules\PreParse\MyCustomRule2.ps1'

        # Create the folderpath
        $null = New-Item -Path (Split-Path $rulePath) -ItemType Directory -Force
        
        $file = '
        param(
            [Object[]]$PipelineResources
        )
        '
        
        $file | Set-Content -Path $rulePath
        $file | Set-Content -Path $rulePath2

        Mock -CommandName Get-Module -MockWith { return (
            @{
                moduleBase = $TestDrive 
            })
        } -Verifiable
        
        
    }

    It "Should trigger the custom task scripts" {
        $tasks = @("Task1", "Task2")

        $result = Invoke-PreParseRules -Tasks $tasks
        Assert-MockCalled -CommandName Get-Module
        
    }

    It "Should throw an error if the custom task script does not exist" {
        Mock -CommandName Get-Module -MockWith { return (
            @{
                moduleBase = 'fakepath' 
            })
        }

        $tasks = @("Task1", "Task2")
        $customTaskName = "NonExistentTask"

        { Invoke-PreParseRules -Tasks $tasks } | Should -Throw '*No Tasks to Process in Directory*'
    }

    AfterAll {
        # Remove the temp powershell file
        Remove-Item -Path $rulePath -Force
    }

}