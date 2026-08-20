# Public Function to Stop the Processing of the Script for the current yaml file
<#
.SYNOPSIS
Stops the processing of the script when called within the Start-DscRunner function.

.DESCRIPTION
The Stop-TaskProcessing function is designed to halt the execution of a script. It ensures that it is only called within the context of the Start-DscRunner function by checking the call stack. If called outside of this context, it will throw an error.

.PARAMETERS
None.

.EXAMPLES
Example 1:
#>
Function Stop-TaskProcessing {
    # Check to make sure that Stop-TaskProcessing is being called within Start-DscRunner
    # Get the call-stack
    $callStack = Get-PSCallStack
    if ($callStack.Command -notcontains 'Start-DscRunner') {
        Write-Error "[Dsc.PipelineRunner\Stop-TaskProcessing] Stop-TaskProcessing can only be called within the Start-DscRunner function."
        return
    }

    Write-Verbose "Stopping the processing of the script"

    # Cross-file script-scope contract (#26): $script:StopTaskProcessing is the single flag
    # that signals "skip all remaining resources in the current file". Start-DscRunner OWNS it —
    # it resets the flag to $false at the top of each file and reads it once per resource. This
    # function is the only other writer, and only ever sets it to $true. The flag works across the
    # file boundary because, in the built module, every function shares one module script scope;
    # the call-stack guard above guarantees this writer only runs while Start-DscRunner is the
    # active reader, so the two files are never loaded/used independently of that contract.
    $script:StopTaskProcessing = $true
}
