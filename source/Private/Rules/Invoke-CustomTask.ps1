<#
.SYNOPSIS
Invokes a custom task script with the specified task name and tasks.

.DESCRIPTION
The `Invoke-CustomTask` function processes and invokes a custom task script located in the CustomTasks directory. 
It takes an array of tasks and a custom task name as parameters, constructs the path to the custom task script, 
and then executes the script with the provided tasks.

.PARAMETER Tasks
An array of tasks to be passed to the custom task script. This parameter is mandatory.

.PARAMETER CustomTaskName
The name of the custom task script to be invoked. This parameter is mandatory.

.EXAMPLE
PS> Invoke-CustomTask -Tasks $tasksArray -CustomTaskName "MyCustomTask"
This example invokes the custom task script named "MyCustomTask.ps1" with the tasks specified in `$tasksArray`.

.NOTES
The custom task scripts are expected to be located in the "Rules\CustomTasks" directory relative to the current location.
#>

Function Invoke-CustomTask {
    param(
        [Parameter(Mandatory=$true)]
        [Object[]]$Tasks,
        [Parameter(Mandatory=$true)]
        [String]$CustomTaskName
    )

    # Write-Verbose
    Write-Verbose "[Invoke-CustomTask] Processing Custom Task: $CustomTaskName"

    # Get the path to the CustomTasks directory
    $currentPath = (Get-Module 'Dsc.PipelineRunner').ModuleBase
    $CustomTasksDirectoryPath = "{0}\Pipeline Rules\Custom\" -f $currentPath

    # Get the path to the Custom Task File
    $CustomTaskFilePath = "{0}\{1}.ps1" -f $CustomTasksDirectoryPath, $CustomTaskName

    # Invoke the Custom Task
    return (. $CustomTaskFilePath -PipelineResources $Tasks)

}