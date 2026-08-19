<#
.SYNOPSIS
Invokes the Desired State Configuration (DSC) based on a provided configuration file.

.DESCRIPTION
The Start-DscRunner function processes a DSC configuration file (YAML or JSON) and executes the tasks defined within it.
It supports both 'Test' and 'Set' modes to either validate the current state or apply changes to achieve the desired state.

.PARAMETER FilePath
The path to the configuration file (.yaml/.yml or .json).

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' (default) and 'Set'.
'Test' mode validates the current state, while 'Set' mode applies changes to achieve the desired state.

.PARAMETER ReportPath
Optional parameter to specify a path for saving the report. If provided, the report will be saved as a CSV file at the specified location.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.yaml" -Mode "Test"
Invokes the DSC configuration in 'Test' mode using the specified YAML configuration file.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.json" -Mode "Set" -ReportPath "C:\Reports"
Invokes the DSC configuration in 'Set' mode using the specified JSON configuration file and saves the report to the specified path.

.NOTES
- The function supports both YAML and JSON configuration files.
- The function processes tasks in the order of their dependencies.
- The function generates a detailed report of the execution, which can be saved to a specified path.

#>
#
# Function to Invoke the DSC Configuration
function Start-DscRunner {
    # Declare parameters for the function with default values and validation where needed
    param (
        [string] $FilePath, # The path to the configuration file (.yaml/.yml or .json)
        [ValidateSet("Test", "Set")] # Ensures that Mode can only be 'Test' or 'Set'
        [string] $Mode = "Test", # Default mode is 'Test', can be set to 'Set' for applying changes,
        [String] $ReportPath = $null # Optional parameter for specifying a report path
    )

    # Clear StopTaskProcessing variable
    $script:StopTaskProcessing = $false

    $reporting = [System.Collections.Generic.List[PSCustomObject]]::New()

    # Determine the file extension of the provided FilePath
    $fileExtension = [System.IO.Path]::GetExtension($FilePath)
    Write-Verbose "File extension determined: $fileExtension"

    # Load the configuration from the YAML or JSON file into the $pipeline variable
    if ($fileExtension -eq ".yaml" -or $fileExtension -eq ".yml") {
        $pipeline = Get-Content $FilePath | ConvertFrom-Yaml
        Write-Verbose "Loaded YAML configuration from file: $FilePath"
    }
    elseif ($fileExtension -eq ".json") {
        $pipeline = Get-Content $FilePath | ConvertFrom-Json -AsHashtable
        Write-Verbose "Loaded JSON configuration from file: $FilePath"
    }

    # Clear any existing data in these hashtables before populating them
    $parameters.Clear()
    $variables.Clear()
    $references.Clear()
    Write-Verbose "Cleared existing data in parameters, variables, and references hashtables"

    Write-Host "---------------------------------------------------------------------" -ForegroundColor Green
    Write-Host "Processing configuration file: $FilePath" -ForegroundColor Green
    Write-Host "Mode: $Mode" -ForegroundColor Green
    Write-Host "Report Path: $ReportPath" -ForegroundColor Green
    Write-Host "---------------------------------------------------------------------" -ForegroundColor Green
    Write-Host "--> Setting Variables:" -ForegroundColor Green

    # Retrieve default values for parameters and set variables based on the pipeline's content
    #$defaultValues = GetDefaultValues -Source $pipeline.parameters
    $parameterizedProperties = GetDefaultValues -Source $pipeline.parameters

    SetVariables -Source $pipeline.variables -Target $variables
    SetVariables -Source $defaultValues -Target $parameters

    Write-Verbose "Retrieved default values for parameters and set variables based on pipeline content"

    Write-Host "--> Sorting tasks based on dependencies:" -ForegroundColor Green

    # Sort the tasks based on their dependencies to ensure correct execution order
    $tasks = Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Sort-DependsOn"
    Write-Verbose "Sorted tasks based on dependencies"

    # Invoke the PreParse the rules to process the tasks before formatting them
    Write-Host "--> Processing PreParse Rules:" -ForegroundColor Green

    # Invoke the PreParse the rules to process the tasks before formatting them
    Invoke-PreParseRules -Tasks $pipeline.resources

    # Invoke the Format Tasks Rules
    Write-Host "--> Processing Formatting Tasks:" -ForegroundColor Green

    # Format the tasks based on the configuration rules
    $tasks = Invoke-FormatTasks -Tasks $tasks

    # Report Task Counter
    $TaskCounter = 0

    # Loop through each task/resource and process it according to its configuration
    foreach ($task in $tasks) {

        # Increment the task counter
        $TaskCounter++

        Write-Verbose "Processing resource: [$($task.type)/$($task.name)]"

        # If the StopTaskProcessing variable is set to true, stop processing the tasks
        if ($Script:StopTaskProcessing) {
            Write-Verbose "Skipping resource due to 'Stop-TaskProcessing' being called:"
            # Add a reporting entry for the skipped resource
            $null = $reporting.Add([PSCustomObject]@{
                Counter = $TaskCounter
                Name = $task.name
                Type = $task.type
                Status = "Skipped"
                Method = 'TEST'
                Result = "SKIPPED"
                Message = "Resource skipped due to 'Stop-TaskProcessing' cmdlet."
            })

            # Skip to the next task
            continue
        }

        # Evaluate the Condition script block if it exists, and skip the task if the condition returns false
        if ($null -ne $task.Condition) {

            # Create a script block from th econdition property
            $sbCondition = [scriptblock]::Create($task.Condition)

            if ((. $sbCondition) -eq $false) {

                Write-Verbose "Skipping resource due to condition: [$($task.type)/$($task.name)]"
                # Add a reporting entry for the skipped resource
                $null = $reporting.Add([PSCustomObject]@{
                    Counter = $TaskCounter
                    Name = $task.name
                    Type = $task.type
                    Status = "Skipped"
                    Method = 'TEST'
                    Result = "SKIPPED"
                    Message = "Resource skipped due to condition {$($task.Condition)}."
                })

                # Skip to the next task
                continue

            }
        }

        # Extract the module name and resource type from the task's type property
        $module = $task.type.Split("/")[0]
        $resourceType = $task.type.Split("/")[1]
        Write-Verbose "Extracted module name: $module and resource type: $resourceType"

        # Iterate through the properties of the task and interpolate parameterized values
        #$Property = Expand-ParameterInArray -InputArray $task.properties

        # Replace any variables in the properties with their actual values
        $Property = Expand-HashTable -InputHashTable $task.properties

        Write-Verbose "Replaced variables in properties with actual values"

        # Prepare parameters for invoking the DSC resource using the 'Test' method
        $resourceParameters = @{
            Name = $resourceType
            ModuleName = $module
            Method = "Test"
            Property = $Property
        }

        Write-Verbose "Prepared parameters for 'Test' invocation of DSC resource"

        # Execute the 'Test' method to determine if the state is as desired.
        # A single resource that throws must not abort the entire run, so trap the
        # error, record it as a failed resource, and move on to the next task.
        try {
            $result = Invoke-DscResource @resourceParameters
            Write-Verbose "Executed 'Test' method for DSC resource: [$($task.type)/$($task.name)]"
        }
        catch {
            Write-Error "[Start-DscRunner] 'Test' method failed for resource [$($task.type)/$($task.name)]: $($_.Exception.Message)" -ErrorAction Continue
            $null = $reporting.Add([PSCustomObject]@{
                Counter = $TaskCounter
                Name    = $task.name
                Type    = $task.type
                Method  = 'TEST'
                Status  = "Error"
                Result  = "FAIL"
                Message = $_.Exception.Message
            })
            # Skip Set/Get for this resource and continue with the remaining tasks
            continue
        }

        # Update the reporting list with the result of the 'Test' operation
        $null = $reporting.Add([PSCustomObject]@{
            Counter = $TaskCounter
            Name    = $task.name
            Type    = $task.type
            Method  = 'TEST'
            Status  = $result.InDesiredState ? "InDesiredState" : "NotInDesiredState"
            Result  = $result.InDesiredState ? "PASS" : "FAIL"
            Message = $result.Message
        })

        # If not in the desired state and Mode is 'Set', execute the 'Set' method to apply changes
        if ($result.InDesiredState) {
            Write-Verbose "Resource is in the desired state: [$($task.type)/$($task.name)]"
        }
        elseif ($Mode -eq "Set") {

            $resourceParameters.Method = "Set"

            try {
                $setResult = Invoke-DscResource @resourceParameters
                Write-Verbose "Executed 'Set' method to make changes: [$($task.type)/$($task.name)]"
                $Message = "Resource set to desired state"
                $Result = "PASS"
            }
            catch {
                # -ErrorAction Continue keeps this non-terminating even when a caller
                # runs under $ErrorActionPreference='Stop' (e.g. an advanced-function
                # wrapper), so one failed 'Set' does not abort the whole run.
                Write-Error "[Start-DscRunner] Failed to apply changes with 'Set' method: [$($task.type)/$($task.name)]: $($_.Exception.Message)" -ErrorAction Continue
                $Message = $_.Exception.Message
                $Result = "FAIL"
            }
            finally {
                # Update the reporting list with the result of the 'Set' operation
                $null = $reporting.Add([PSCustomObject]@{
                    Counter     = $TaskCounter
                    Name        = $task.name
                    Type        = $task.type
                    Status      = "Set"
                    Method      = "SET"
                    Result      = $Result
                    Message     = $Message
                })

            }
        }
        else {
            Write-Verbose "Change needed, but mode is not set to 'Set': [$($task.type)/$($task.name)]"
        }

        #
        # Test if the postCondition property exists and execute the script block if it does.
        if ($null -ne $task.postExecutionScript) {
            # Create a script block from the postCondition property
            $sbPostExecutionScript = [scriptblock]::Create($task.postExecutionScript)

            # Dot-Source the postCondition script block
            . $sbPostExecutionScript
        }

        # Execute the 'Get' method to retrieve the current state of the resource.
        # A failed 'Get' should not abort the run; record $null and continue.
        $resourceParameters.Method = 'get'
        try {
            $output_var = Invoke-DscResource @resourceParameters
            Write-Verbose "Retrieved current state with 'Get' method for DSC resource: [$($task.type)/$($task.name)]"
        }
        catch {
            Write-Error "[Start-DscRunner] 'Get' method failed for resource [$($task.type)/$($task.name)]: $($_.Exception.Message)" -ErrorAction Continue
            $output_var = $null
        }

        # Store the output of the 'Get' operation in a reference table for later use
        $references.Add($task.name, $output_var)
        Write-Verbose "Stored output of 'Get' operation in references table for resource: [$($task.type)/$($task.name)]"

    }


    #
    # Report the results of the DSC Configuration
    #

    $PassCounter = 0
    $FailCounter = 0
    $SkippedCounter = 0

    # Group by the task name and status to provide a summary of the results
    $reportSummary = $reporting | Group-Object -Property Name | Sort-Object -Property {$_.Group.Counter}

    # If the reporting path is specified, print the report to the console and save it to the specified path
    if ($ReportPath) {

        Write-Verbose "[Start-DscRunner] FilePath $FilePath"

        # Construct the full path for the report file. Use GetFileNameWithoutExtension
        # (TrimEnd('.yml') stripped any trailing y/m/l characters, not the extension) and
        # Join-Path so the report path is correct on every platform, not just Windows.
        $reportFileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $FilePath = Join-Path -Path $ReportPath -ChildPath ("{0}.csv" -f $reportFileName)

        # Convert the reporting data to CSV format and write it to the specified path
        $reporting | Export-Csv -Path $FilePath -NoTypeInformation

    }

    # Print the output of the report to the console.

    Write-Host "DSC Configuration Report: $FilePath" -ForegroundColor Green
    Write-Host "Results Summary:" -ForegroundColor Green

    # Iterate through the grouped report data and display the results
    foreach ($GroupReport in $reportSummary) {

        # Test the status of the task and set the colour accordingly

        # If the count is greater than 1, then the task has been executed multiple times meaning it has failed the test
        # but could of passed the set
        $Counter = $GroupReport.Group.Counter | Select-Object -First 1

        if ($GroupReport.Count -gt 1) {

            # Filter the results to see if the task has set the resource to the desired state
            $setResult = $GroupReport.Group | Where-Object { ($_.Method -eq 'SET') }

            if ($setResult.Result -contains "PASS") {
                $Colour = "Green"
                $Result = "PASS"
                $PassCounter++
            } else {
                $Colour = "Red"
                $Result = "FAIL"
                $FailCounter++
            }

        #
        # If the count is less than 1, then the task has only been executed once, meaning the test functionality has been tested.

        } else {
            if ($GroupReport.Group.Result -contains "PASS") {
                $Colour = "Green"
                $Result = "PASS"
                $PassCounter++
            } elseif ($GroupReport.Group.Result -contains "FAIL") {
                $Colour = "Red"
                $Result = "FAIL"
                $FailCounter++
            } elseif ($GroupReport.Group.Result -contains "SKIPPED") {
                $Colour = "Yellow"
                $Result = "SKIPPED"
                $SkippedCounter++
            } else {
                $Colour = "Magenta"
                $Result = "UNKNOWN"
            }
        }

        # Print the task name and result with the appropriate colour
        Write-Host "[$($Counter)]    Task: $($GroupReport.Name) - Result: [$($Result)]" -ForegroundColor $Colour
    }

    $OutputColour = ($FailCounter -eq 0) ? "Green" : "Red"

    # Print the total number of tasks executed
    Write-Host "Total Tasks Executed: $($reportSummary.Count)" -ForegroundColor $OutputColour
    Write-Host "Tasks Passed:  $PassCounter" -ForegroundColor $OutputColour
    Write-Host "Tasks Failed:  $FailCounter" -ForegroundColor $OutputColour
    Write-Host "Tasks Skipped: $SkippedCounter" -ForegroundColor $OutputColour
    Write-Host "Total Tasks: $($reportSummary.Count)" -ForegroundColor $OutputColour

}
