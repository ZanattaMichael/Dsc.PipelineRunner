<#
.SYNOPSIS
Invokes the Desired State Configuration (DSC) based on a provided configuration file.

.DESCRIPTION
The Start-DscRunner function processes a DSC configuration file (YAML or JSON) and executes the tasks defined within it.
It supports both 'Test' and 'Set' modes to either validate the current state or apply changes to achieve the desired state.

Each resource is evaluated through the selected engine (DscV2 / DscV3 / custom), which returns a normalized
[DscMethodResult]. The runner records one structured result per resource, keyed by
(ConfigurationFile, ResourceType, InstanceName), so a resource is never double-counted. The report is written from a
finally block, so it is produced even when the run is stopped early (Stop-TaskProcessing) or aborted by an exception.

All human-readable output is emitted on the information stream (Write-Information, tag 'Dsc.PipelineRunner') rather
than Write-Host, so a caller can capture it with -InformationVariable or redirect it. DSC's native progress UI is
suppressed for the duration of the run so it does not flood the pipeline log.

.PARAMETER FilePath
The path to the configuration file (.yaml/.yml or .json).

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' (default) and 'Set'.
'Test' mode validates the current state, while 'Set' mode applies changes to achieve the desired state.

.PARAMETER ReportPath
Optional directory for saving the report. When provided, a CSV and a JSON report are written for the configuration.

.PARAMETER Engine
Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource (DscV2).

.PARAMETER EngineVersion
Optional resource version hint that biases 'Auto' engine selection by major version.

.PARAMETER EngineAction
Optional inline engine override; takes precedence over -Engine.

.OUTPUTS
[pscustomobject] describing the run: ConfigurationFile, Status (Completed / StoppedByRequest / AbortedByException),
TotalResources, PassCount, FailCount, SkipCount, DurationSeconds, ErrorMessage, FailedResources and the per-resource Results.

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
        [String] $ReportPath = $null, # Optional parameter for specifying a report path
        [string] $Engine = 'DscV2', # Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource.
        [string] $EngineVersion, # Optional resource version hint that biases 'Auto' engine selection by major version.
        [scriptblock] $EngineAction # Optional inline engine override; takes precedence over -Engine.
    )

    # Informational output is the pipeline log's signal channel; make it visible by default
    # for the duration of the run, and keep DSC's native progress UI out of the log. Both are
    # local to this scope, so the caller's preferences are left untouched on return.
    $InformationPreference = 'Continue'
    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $infoTag = 'Dsc.PipelineRunner'

    # Resolve the engine once so any dsc.exe probe / auto-selection warning happens a
    # single time per file rather than per resource. An inline EngineAction override
    # bypasses selection entirely (it takes precedence over -Engine); an explicit engine
    # name is honoured verbatim, and only 'Auto' triggers detection.
    $resolvedEngine = $Engine
    if (-not $EngineAction -and $Engine -eq 'Auto') {
        $resolvedEngine = Resolve-DscEngine -Engine $Engine -Version $EngineVersion
        Write-Verbose "Auto-selected DSC engine: $resolvedEngine"
    }

    # Build the engine selector once; every Test/Set/Get for this file runs through it.
    $engineArgs = @{ Engine = $resolvedEngine }
    if ($EngineAction) { $engineArgs.EngineAction = $EngineAction }

    # Reset the run-control flag for this file. $script:StopTaskProcessing is a documented
    # cross-file, module-script-scope contract (#26): Start-DscRunner owns it (resets here,
    # reads it once per resource below), and Stop-TaskProcessing is the only other writer,
    # setting it $true to skip the rest of the file. See Stop-TaskProcessing.ps1 for the guard
    # that keeps the two in lock-step.
    $script:StopTaskProcessing = $false

    # Determine the file extension of the provided FilePath
    $fileExtension = [System.IO.Path]::GetExtension($FilePath)
    Write-Verbose "File extension determined: $fileExtension"

    # Reject unsupported inputs up front, before any reporting state is set up.
    if ($fileExtension -notin '.yaml', '.yml', '.json') {
        throw "[Start-DscRunner] Unsupported configuration file extension '$fileExtension'. Expected .yaml, .yml or .json."
    }

    # Run-level bookkeeping. Results are structured records, deduplicated by the
    # (ConfigurationFile, ResourceType, InstanceName) tuple so a resource is counted once.
    $nodeName    = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $results     = [System.Collections.Generic.List[pscustomobject]]::new()
    $resultIndex = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new([System.StringComparer]::Ordinal)
    $runStatus   = 'Completed'
    $runError    = $null
    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Records a single resource outcome, replacing any earlier record for the same tuple so a
    # resource re-observed within a file does not double-count.
    $recordResult = {
        param($ResourceType, $InstanceName, $Status, $DurationMs, $ErrorMessage)

        $record = [pscustomobject]@{
            NodeName          = $nodeName
            ResourceType      = $ResourceType
            InstanceName      = $InstanceName
            ConfigurationFile = $FilePath
            Status            = $Status
            DurationMs        = $DurationMs
            ErrorMessage      = $ErrorMessage
        }

        $key = '{0}|{1}|{2}' -f $FilePath, $ResourceType, $InstanceName
        if ($resultIndex.ContainsKey($key)) {
            $existing = $resultIndex[$key]
            $results[$results.IndexOf($existing)] = $record
        }
        else {
            $results.Add($record)
        }
        $resultIndex[$key] = $record
    }

    # Load the configuration from the YAML or JSON file into the $pipeline variable
    if ($fileExtension -eq ".yaml" -or $fileExtension -eq ".yml") {
        $pipeline = Get-Content $FilePath | ConvertFrom-Yaml
        Write-Verbose "Loaded YAML configuration from file: $FilePath"
    }
    else {
        $pipeline = Get-Content $FilePath | ConvertFrom-Json -AsHashtable
        Write-Verbose "Loaded JSON configuration from file: $FilePath"
    }

    # Clear any existing data in these hashtables before populating them
    $parameters.Clear()
    $variables.Clear()
    $references.Clear()
    Write-Verbose "Cleared existing data in parameters, variables, and references hashtables"

    # Run preamble — a single legible block at the top of the log (#30).
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "Processing configuration file: $FilePath" -Tags $infoTag
    Write-Information "Mode: $Mode" -Tags $infoTag
    Write-Information "Engine: $resolvedEngine" -Tags $infoTag
    Write-Information "Report Path: $ReportPath" -Tags $infoTag
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "--> Setting Variables:" -Tags $infoTag

    # Retrieve default values for parameters and set variables based on the pipeline's content
    #$defaultValues = GetDefaultValues -Source $pipeline.parameters
    $parameterizedProperties = GetDefaultValues -Source $pipeline.parameters

    SetVariables -Source $pipeline.variables -Target $variables
    SetVariables -Source $defaultValues -Target $parameters

    Write-Verbose "Retrieved default values for parameters and set variables based on pipeline content"

    Write-Information "--> Sorting tasks based on dependencies:" -Tags $infoTag

    # Sort the tasks based on their dependencies to ensure correct execution order
    $tasks = Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Sort-DependsOn"
    Write-Verbose "Sorted tasks based on dependencies"

    # Invoke the PreParse the rules to process the tasks before formatting them
    Write-Information "--> Processing PreParse Rules:" -Tags $infoTag

    # Invoke the PreParse the rules to process the tasks before formatting them
    Invoke-PreParseRules -Tasks $pipeline.resources

    # Invoke the Format Tasks Rules
    Write-Information "--> Processing Formatting Tasks:" -Tags $infoTag

    # Format the tasks based on the configuration rules
    $tasks = Invoke-FormatTasks -Tasks $tasks

    $totalTasks = @($tasks).Count

    # Report Task Counter
    $TaskCounter = 0

    try {
        # Loop through each task/resource and process it according to its configuration
        foreach ($task in $tasks) {

            # Increment the task counter
            $TaskCounter++

            $resourceKey = "$($task.type)/$($task.name)"
            $resourceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Verbose "Processing resource: [$resourceKey]"

            # If the StopTaskProcessing variable is set to true, stop processing the tasks
            if ($Script:StopTaskProcessing) {
                Write-Verbose "Skipping resource due to 'Stop-TaskProcessing' being called:"
                $runStatus = 'StoppedByRequest'
                & $recordResult $task.type $task.name 'SKIP' 0 "Resource skipped due to 'Stop-TaskProcessing' cmdlet."
                Write-Information ("[{0}/{1}] SKIP {2} (stopped by request)" -f $TaskCounter, $totalTasks, $resourceKey) -Tags $infoTag
                continue
            }

            # Evaluate the Condition script block if it exists, and skip the task if the condition returns false
            if ($null -ne $task.Condition) {

                # A condition is a predicate, not a program: reject any command, assignment or
                # method call before it runs, so configuration code cannot use a condition to
                # mutate the runner's state or its audit record (#35).
                Assert-SafeConditionExpression -Expression $task.Condition

                # Create a script block from the condition property
                $sbCondition = [scriptblock]::Create($task.Condition)

                # Invoke with the call operator (&), not dot-sourcing (.), so the block runs in a
                # child scope. It can still read the runner's variables through dynamic scoping
                # (which is all the example configurations need), but any assignment it makes stays
                # local instead of overwriting Start-DscRunner's own state (#35).
                if ((& $sbCondition) -eq $false) {

                    Write-Verbose "Skipping resource due to condition: [$resourceKey]"
                    & $recordResult $task.type $task.name 'SKIP' $resourceStopwatch.ElapsedMilliseconds "Resource skipped due to condition {$($task.Condition)}."
                    Write-Information ("[{0}/{1}] SKIP {2} (condition)" -f $TaskCounter, $totalTasks, $resourceKey) -Tags $infoTag
                    continue

                }
            }

            # Extract the module name and resource type from the task's type property
            $module = $task.type.Split("/")[0]
            $resourceType = $task.type.Split("/")[1]
            Write-Verbose "Extracted module name: $module and resource type: $resourceType"

            # Replace any variables in the properties with their actual values
            $Property = Expand-HashTable -InputHashTable $task.properties
            Write-Verbose "Replaced variables in properties with actual values"

            $resourceStatus = 'OK'
            $resourceError = $null

            # Execute the 'Test' method to determine if the state is as desired.
            # The resource is evaluated through the selected engine (DscV2 / DscV3 / custom),
            # which returns a normalized [DscMethodResult] regardless of the underlying tool.
            # A single resource that throws must not abort the entire run, so trap the
            # error, record it as a failed resource, and move on to the next task.
            try {
                $result = Invoke-EngineAction -Method 'Test' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                Write-Verbose "Executed 'Test' method for DSC resource: [$resourceKey]"
            }
            catch {
                Write-Error "[Start-DscRunner] 'Test' method failed for resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $_.Exception.Message
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $resourceKey, $resourceStopwatch.ElapsedMilliseconds, $_.Exception.Message) -Tags $infoTag
                # Skip Set/Get for this resource and continue with the remaining tasks
                continue
            }

            # If not in the desired state and Mode is 'Set', execute the 'Set' method to apply changes
            if ($result.InDesiredState) {
                Write-Verbose "Resource is in the desired state: [$resourceKey]"
                $resourceStatus = 'OK'
            }
            elseif ($Mode -eq "Set") {

                try {
                    $null = Invoke-EngineAction -Method 'Set' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                    Write-Verbose "Executed 'Set' method to make changes: [$resourceKey]"
                    $resourceStatus = 'OK'
                }
                catch {
                    # -ErrorAction Continue keeps this non-terminating even when a caller
                    # runs under $ErrorActionPreference='Stop' (e.g. an advanced-function
                    # wrapper), so one failed 'Set' does not abort the whole run.
                    Write-Error "[Start-DscRunner] Failed to apply changes with 'Set' method: [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                    $resourceStatus = 'FAIL'
                    $resourceError = $_.Exception.Message
                }
            }
            else {
                # Drift detected in Test mode: the resource is not in the desired state.
                Write-Verbose "Change needed, but mode is not set to 'Set': [$resourceKey]"
                $resourceStatus = 'FAIL'
                $resourceError = $result.Message
            }

            #
            # Test if the postExecutionScript property exists and execute the script block if it does.
            if ($null -ne $task.postExecutionScript) {
                # Create a script block from the postExecutionScript property
                $sbPostExecutionScript = [scriptblock]::Create($task.postExecutionScript)

                # Invoke in a child scope with the call operator (&) rather than dot-sourcing (.).
                # postExecutionScript is imperative by design and may still read runner variables
                # and call control verbs such as Stop-TaskProcessing (which sets module-scope
                # state, so it keeps working across the scope boundary), but it can no longer
                # reach in and rewrite Start-DscRunner's locals or its report (#35).
                & $sbPostExecutionScript
            }

            # Execute the 'Get' method to retrieve the current state of the resource.
            # A failed 'Get' should not abort the run; record $null and continue.
            try {
                $getResult = Invoke-EngineAction -Method 'Get' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                # Store the engine's raw current-state output so downstream reference
                # expansion sees exactly the same shape it did before the engine seam.
                $output_var = $getResult.Raw
                Write-Verbose "Retrieved current state with 'Get' method for DSC resource: [$resourceKey]"
            }
            catch {
                Write-Error "[Start-DscRunner] 'Get' method failed for resource [$resourceKey]: $($_.Exception.Message)" -ErrorAction Continue
                $output_var = $null
            }

            # Store the output of the 'Get' operation in a reference table for later use
            $references.Add($task.name, $output_var)
            Write-Verbose "Stored output of 'Get' operation in references table for resource: [$resourceKey]"

            # Record the single, deduplicated outcome for this resource and log one line.
            $resourceStopwatch.Stop()
            & $recordResult $task.type $task.name $resourceStatus $resourceStopwatch.ElapsedMilliseconds $resourceError
            Write-Information ("[{0}/{1}] {2} {3} ({4}ms)" -f $TaskCounter, $totalTasks, $resourceStatus, $resourceKey, $resourceStopwatch.ElapsedMilliseconds) -Tags $infoTag

        }
    }
    catch {
        # An unexpected exception aborted the loop. Record the run status so the report,
        # written from the finally block below, reflects the partial results.
        $runStatus = 'AbortedByException'
        $runError = $_.Exception.Message
        Write-Error "[Start-DscRunner] Run aborted by an unexpected error: $($_.Exception.Message)" -ErrorAction Continue
    }
    finally {

        $runStopwatch.Stop()
        $ProgressPreference = $previousProgressPreference

        # Summarize from the deduplicated records.
        $passCount = @($results | Where-Object { $_.Status -eq 'OK' }).Count
        $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
        $failedResources = @($results | Where-Object { $_.Status -eq 'FAIL' })

        # Always write the report (even on early stop / abort), when a path is supplied.
        if ($ReportPath) {

            Write-Verbose "[Start-DscRunner] Writing report for $FilePath to $ReportPath"

            # [System.IO.Path]::Combine composes the path without resolving a drive
            # qualifier, so a Windows-style ReportPath (e.g. 'C:\Reports') does not throw
            # DriveNotFoundException on a Linux runner.
            $csvPath  = [System.IO.Path]::Combine($ReportPath, ("{0}.csv" -f $nodeName))
            $jsonPath = [System.IO.Path]::Combine($ReportPath, ("{0}.report.json" -f $nodeName))

            $results | Export-Csv -Path $csvPath -NoTypeInformation

            $reportDocument = [pscustomobject]@{
                ConfigurationFile = $FilePath
                Status            = $runStatus
                TotalResources    = $results.Count
                PassCount         = $passCount
                FailCount         = $failCount
                SkipCount         = $skipCount
                DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
                ErrorMessage      = $runError
                Results           = $results
            }
            $reportDocument | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath
        }

        # Print the summary block.
        $outcomeIsClean = ($failCount -eq 0) -and ($runStatus -eq 'Completed')

        Write-Information "DSC Configuration Report: $FilePath" -Tags $infoTag
        Write-Information "Run Status: $runStatus" -Tags $infoTag
        Write-Information "Results Summary:" -Tags $infoTag

        foreach ($record in $results) {
            Write-Information ("[{0}] {1}/{2} - Result: [{3}]" -f $record.NodeName, $record.ResourceType, $record.InstanceName, $record.Status) -Tags $infoTag
        }

        Write-Information "Total Tasks Executed: $($results.Count)" -Tags $infoTag
        Write-Information "Tasks Passed:  $passCount" -Tags $infoTag
        Write-Information "Tasks Failed:  $failCount" -Tags $infoTag
        Write-Information "Tasks Skipped: $skipCount" -Tags $infoTag
        Write-Information "Total Tasks: $($results.Count)" -Tags $infoTag

        # Failure detail block — a deduplicated list of every failed resource (#30).
        if ($failedResources.Count -gt 0) {
            Write-Information "Failed Resources:" -Tags $infoTag
            foreach ($failed in $failedResources) {
                Write-Information ("  {0}/{1} [{2}] - {3}" -f $failed.ResourceType, $failed.InstanceName, $failed.ConfigurationFile, $failed.ErrorMessage) -Tags $infoTag
            }
        }

        if (-not $outcomeIsClean) {
            Write-Verbose "[Start-DscRunner] Run completed with failures or interruption (status: $runStatus)."
        }
    }

    # Emit the structured run result so callers (Invoke-DscRunner / Invoke-DscPipelineRunner)
    # can aggregate outcomes across configuration files, surface a machine-readable report and
    # set a non-zero exit code on failure.
    return [pscustomobject]@{
        ConfigurationFile = $FilePath
        NodeName          = $nodeName
        Status            = $runStatus
        TotalResources    = $results.Count
        PassCount         = $passCount
        FailCount         = $failCount
        SkipCount         = $skipCount
        DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
        ErrorMessage      = $runError
        FailedResources   = $failedResources
        Results           = $results
    }

}
