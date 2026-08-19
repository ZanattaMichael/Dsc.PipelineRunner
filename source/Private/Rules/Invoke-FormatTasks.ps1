
Function Invoke-FormatTasks {
    param(
        [Parameter(Mandatory=$true)]
        [Object[]]$Tasks
    )

    # Get the path to the PreParseRules directory
    $currentPath = (Get-Module 'Dsc.PipelineRunner').ModuleBase
    $TasksDirectoryPath = "{0}\Pipeline Rules\Format" -f $currentPath

    #
    # Iterate through each of the Configuration Tasks 
    
    Write-Verbose "[Format-Tasks] Processing Tasks in Directory: $TasksDirectoryPath"

    if (-not (Test-Path -Path $TasksDirectoryPath)) {
        Throw "[Format-Tasks] No Tasks to Process in Directory: $TasksDirectoryPath"
        return $Tasks
    }

    $ScriptFiles = Get-ChildItem -Path $TasksDirectoryPath -Filter "*.ps1"

    # Iterate through each of the Script Files
    foreach ($ScriptFile in $ScriptFiles) {
        # Write a Verbose message
        Write-Verbose "[Invoke-ScriptFiles] Processing Script File: $($ScriptFile.FullName)"

        # Execute the Script File
        $Tasks = . $ScriptFile.FullName -PipelineResources $Tasks
    }

    return $Tasks

}

