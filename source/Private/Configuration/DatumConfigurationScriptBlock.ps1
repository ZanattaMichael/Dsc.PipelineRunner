<#
.SYNOPSIS
    Creates and tests a Datum configuration structure from a YAML definition file.

    Please note that this function is intended to be used as a script block in a separate thread using the Build-DatumConfiguration function.
    Not intended to be run directly.

.DESCRIPTION
    The DatumConfigurationScriptBlock function imports necessary modules, changes the current directory to the specified configuration path,
    creates a Datum structure from a YAML definition file, tests the configuration, and resolves each project node using the Resolve-DscDatumProject function.

.PARAMETER OutputPath
    The path where the output will be stored.

.PARAMETER ConfigurationPath
    The path to the configuration directory containing the Datum.yml file.

.EXAMPLE
    DatumConfigurationScriptBlock -OutputPath "C:\Output" -ConfigurationPath "C:\Configuration"

.NOTES
    This function requires the 'Dsc.PipelineRunner', 'powershell-yaml', 'datum', and 'datum.invokecommand' modules to be installed and available.
#>
Function DatumConfigurationScriptBlock {
    param($OutputPath, $configurationPath, [switch]$isTest)

    # Prevent the script from running if the DatumConfigurationScriptBlock function is not being run in a separate thread
    if (($MyInvocation.MyCommand.Name -eq 'DatumConfigurationScriptBlock') -and (-not $isTest)) {
        Throw "This function is intended to be used as a script block in a separate thread using the Build-DatumConfiguration function."
    }

    # Import the YAML module for handling YAML files
    # Import the Datum module for configuration data management
    Import-Module 'Dsc.PipelineRunner','powershell-yaml','datum','datum.invokecommand'

    Write-Verbose "Modules for Dsc.PipelineRunner, YAML, Datum and Datum.InvokeCommand have been imported"

    # Change the current directory to the Example Configuration directory
    Set-Location $ConfigurationPath
    Write-Verbose "Changed directory to Example Configuration"

    # Create a new Datum structure based on the provided definition file 'Datum.yml'
    $Datum = New-DatumStructure -DefinitionFile Datum.yml
    Write-Verbose "Datum structure created from definition file 'Datum.yml'"

    # Test the Configuration to Ensure that the Versioning is Correct
    Test-DatumConfiguration $Datum

    # Iterate through each of the Example Configuration projects
    ForEach ($ProjectType in $Datum.Projects.psobject.properties) {
        # Iterate through each of the projects in the current project type
        ForEach ($ProjectNode in $Datum.Projects."$($ProjectType.name)".psobject.properties) {
            # Resolve the project node using the Resolve-DscDatumProject function
            Resolve-DscDatumProject -NodeName $ProjectNode -AllNodes $Datum.Projects."$($ProjectType.name)"."$($ProjectNode.Name)"
        }
    }
}