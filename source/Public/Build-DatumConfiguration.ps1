
#
# .SYNOPSIS
# Function to compile the Datum configuration.
#
# .DESCRIPTION
# The Build-DatumConfiguration function clears the specified output directory, imports necessary modules,
# changes the current directory to the configuration path, creates a new Datum structure from a definition file,
# tests the configuration, and resolves each project node using the Resolve-DscDatumProject function.
# The function runs the script block in a separate thread.
#
# .PARAMETER OutputPath
# The path to the output directory where the compiled configuration will be stored.
# This parameter is mandatory and must be a valid directory path.
#
# .PARAMETER ConfigurationPath
# The path to the configuration directory containing the Datum definition file.
# This parameter is mandatory and must be a valid directory path.
#
# .EXAMPLE
# Build-DatumConfiguration -OutputPath "C:\Output" -ConfigurationPath "C:\Configuration"
# This example clears the output directory at "C:\Output", imports necessary modules, changes the directory to "C:\Configuration",
# creates a new Datum structure from the Datum.yml file, tests the configuration, and resolves each project node.
#
# .NOTES
# The function uses runspaces to run the script block in a separate thread.
# Ensure that the 'powershell-yaml', 'datum', and 'datum.invokecommand' modules are available.

Function Build-DatumConfiguration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType 'Container' })]
        [String]
        $OutputPath,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType 'Container' })]
        [String]
        $ConfigurationPath
    )

    # Clear the output directory
    Get-ChildItem -LiteralPath $OutputPath -File | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Verbose "Cleared the output directory at path: $OutputPath"

    # Load the DatumConfigurationScriptBlock function from the DatumConfigurationScriptBlock.ps1 file
    $scriptBlock = (Get-Command DatumConfigurationScriptBlock).ScriptBlock

    #
    # Run the following powershell in a seperate thread

    # Create a runspace (thread) for the script block to run in
    $runspace = [runspacefactory]::CreateRunspace()

    # Open the runspace
    $runspace.Open()

    # Create a PowerShell instance and attach the script block and runspace
    $powerShellInstance = [powershell]::Create().AddScript($scriptBlock).AddArgument($OutputPath).AddArgument($ConfigurationPath)

    # Run the PowerShell script asynchronously
    $asyncResult = $powerShellInstance.BeginInvoke()

    # Optionally, you can handle the output of the script after it has completed
    $scriptOutput = $powerShellInstance.EndInvoke($asyncResult)

    # Output the results from the script block
    foreach ($output in $scriptOutput) {
        Write-Output $output
    }

    # Close the runspace when done
    $runspace.Close()

}