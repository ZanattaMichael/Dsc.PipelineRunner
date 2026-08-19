# Public Function to Stop the Processing of the Script for the current yaml file
<#
.SYNOPSIS
Stops the processing of the script when called within the Start-LCM function.

.DESCRIPTION
The Stop-TaskProcessing function is designed to halt the execution of a script. It ensures that it is only called within the context of the Start-LCM function by checking the call stack. If called outside of this context, it will throw an error.

.PARAMETERS
None.

.EXAMPLES
Example 1:
#>
Function Stop-TaskProcessing {
    # Check to make sure that Stop-TaskProcessing is being called within Start-LCM
    # Get the call-stack
    $callStack = Get-PSCallStack
    if ($callStack.Command -notcontains 'Start-LCM') {
        Write-Error "[Dsc.PipelineRunner\Stop-TaskProcessing] Stop-TaskProcessing can only be called within the Start-LCM function."
        return
    }

    Write-Verbose "Stopping the processing of the script"
    $script:StopTaskProcessing = $true
}
