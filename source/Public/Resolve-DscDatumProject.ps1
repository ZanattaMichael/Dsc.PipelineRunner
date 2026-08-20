<#
.SYNOPSIS
    Resolves and processes a Datum project configuration for a given node.

.DESCRIPTION
    The Resolve-DscDatumProject function processes the configuration for a specified node in a Datum project.
    It retrieves node groups, creates a configuration data hashtable, accesses properties, resolves resources, parameters,
    conditions, and variables, and finally converts the configuration to YAML format and saves it to an output file.

.PARAMETER NodeName
    The name of the node to process. This parameter is mandatory.

.PARAMETER AllNodes
    A collection of all nodes in the configuration. This parameter is mandatory.

.EXAMPLE
    PS> Resolve-DscDatumProject -NodeName $node -AllNodes $allNodes

    This example processes the configuration for the specified node and all nodes in the configuration.

.NOTES
    The function uses several helper functions such as Resolve-Datum, Test-InvokeCommandFilter, and Invoke-InvokeCommandAction
    to resolve and process the configuration data.

#>
Function Resolve-DscDatumProject {
    param(
        [Parameter(Mandatory=$true)]
        [Object]$NodeName,
        [Parameter(Mandatory=$true)]
        [Object]$AllNodes
    )
    Write-Information "Processing node: $($NodeName.Name)" -Tags 'Dsc.PipelineRunner'

    # Retrieve the NodeGroups for the current node and store them in an array

    Write-Verbose "Retrieved NodeGroups for node: $($NodeName.Name)"

    # Create a hashtable to hold configuration data, including all nodes and the Datum structure itself
    $ConfigurationData = @{
        AllNodes = $AllNodes
        Datum    = $Datum
    }
    Write-Verbose "Configuration data hashtable created for node: $($NodeName.Name)"

    # Access the AllNodes and Baseline properties from the configuration data
    $Node = @{ 
        Project = $NodeName.Name
        ProjectPresence = $ProjectType.name
    }
    
    $AllNodes.Keys | Where-Object {$_ -notin ('parameters','variables','resources')} | ForEach-Object {
        $Node."$($_)" = $AllNodes[$_]
    }
    $Baseline = $ConfigurationData.Datum.Baselines

    Write-Verbose "Accessed AllNodes and Baseline properties for node: $($NodeName.Name)"

    # Resolve and store the resources, parameters, conditions, and variables using the Resolve-Datum function
    $configuration = @{
        resources   = Resolve-Datum -PropertyPath 'resources'  -DatumStructure $Datum -Variable $Node
        parameters  = Resolve-Datum -PropertyPath 'parameters' -DatumStructure $Datum -Variable $Node
        conditions  = Resolve-Datum -PropertyPath 'conditions' -DatumStructure $Datum -Variable $Node
        variables   = Resolve-Datum -PropertyPath 'variables'  -DatumStructure $Datum -Variable $Node
    }

    Write-Verbose "Resolved resources, parameters, conditions, and variables for node: $($NodeName.Name)"
    
    # Iterate through the top-level node and execute the datum script blocks

    $hashTable = @{}
    # Iterate through each of the variables. If the resource value has a datum script block, execute it.
    $configuration.variables.keys | ForEach-Object {
        
        $variable = $_
        $value = $configuration.variables."$variable"
        
        # Test if the value is a script block and execute it if it is
        if ($Value | Test-InvokeCommandFilter) {
            $hashTable."$variable" = $Value | Invoke-InvokeCommandAction -Node $Node
        } else {
            $hashTable."$variable" = $Value
        }

    }
    
    # Set the variables in the configuration
    $configuration.variables = $hashTable

    <#
    $configuration.resources | ForEach-Object {
        $Resource = $_
        $Resource.properties = $Resource.properties | ForEach-Object {
            if ($_.Value | Test-InvokeCommandFilter) {
                $_.Value | Invoke-ProtectedDatumAction
            } else {
                $_.Value
            }
        }
    }
    #>
    # Convert the configuration to YAML format and save it to the output file
    $configuration | ConvertTo-Yaml | Out-File "$OutputPath\$($NodeName.Name).yml"
    Write-Verbose "Configuration for node: $($NodeName.Name) has been converted to YAML and saved to file"
    

}
