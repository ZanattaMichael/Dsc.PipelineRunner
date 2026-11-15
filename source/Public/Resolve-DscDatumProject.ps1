<#
.SYNOPSIS
    Resolves and processes a Datum project configuration for a given node.

.DESCRIPTION
    The Resolve-DscDatumProject function processes the configuration for a specified node in a Datum project.
    It retrieves node groups, creates a configuration data hashtable, accesses properties, resolves resources, parameters,
    conditions, and variables, expands composite resource instances (type: Composite/<Name>) into their member resources,
    and finally converts the configuration to YAML format and saves it to an output file.

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
    # The node name becomes a file name under the output directory. It comes from the file name
    # of a node definition in the configuration repository, which on Linux may legally contain a
    # backslash, so '..\..\outside' would write the compiled file outside the cache directory.
    # Refuse anything that is not a plain file name before doing any work.
    $nodeFileName = [string]$NodeName.Name
    if ([string]::IsNullOrWhiteSpace($nodeFileName) -or
        $nodeFileName -notmatch '^[^/\\:*?"<>|\x00-\x1F]+$' -or
        $nodeFileName.StartsWith('.') -or $nodeFileName -match '\.\.' -or
        $nodeFileName -ne $nodeFileName.Trim()) {
        throw "[Resolve-DscDatumProject] The node name '$($nodeFileName -replace '[\x00-\x1F]', '?')' is not a valid file name (path separators, wildcard characters, '..' and a leading '.' are not allowed)."
    }

    Write-Information "Processing node: $($NodeName.Name)" -Tags 'Dsc.PipelineRunner'

    Write-Verbose "Retrieved NodeGroups for node: $($NodeName.Name)"

    Write-Verbose "Configuration data hashtable created for node: $($NodeName.Name)"

    # The node as the Datum handlers see it: its project, plus every AllNodes entry other than
    # the three configuration sections.
    $Node = @{ 
        Project = $NodeName.Name
        ProjectPresence = $ProjectType.name
    }
    
    $AllNodes.Keys | Where-Object {$_ -notin ('parameters','variables','resources')} | ForEach-Object {
        $Node."$($_)" = $AllNodes[$_]
    }

    Write-Verbose "Accessed AllNodes and Baseline properties for node: $($NodeName.Name)"

    # Resolve and store the resources, parameters, conditions, and variables using the Resolve-Datum function
    $configuration = @{
        resources   = Resolve-Datum -PropertyPath 'resources'  -DatumStructure $Datum -Variable $Node
        parameters  = Resolve-Datum -PropertyPath 'parameters' -DatumStructure $Datum -Variable $Node
        conditions  = Resolve-Datum -PropertyPath 'conditions' -DatumStructure $Datum -Variable $Node
        variables   = Resolve-Datum -PropertyPath 'variables'  -DatumStructure $Datum -Variable $Node
    }

    Write-Verbose "Resolved resources, parameters, conditions, and variables for node: $($NodeName.Name)"

    # Composite resources: replace every `type: Composite/<Name>` instance with the members of
    # its definition (Composites/<Name>.yml), so the compiled file only ever carries ordinary
    # resources. Runs after hierarchy resolution, so an instance is merged and overridden by
    # name like any other resource first. See Expand-CompositeResource.
    if ($null -ne $configuration.resources) {
        $compositeDefinitions = Get-CompositeDefinition -Datum $Datum
        $configuration.resources = @(Expand-CompositeResource -Resources @($configuration.resources) -Definitions $compositeDefinitions)
        Write-Verbose "Expanded composite resources for node: $($NodeName.Name)"
    }
    
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

    # Convert the configuration to YAML format and save it to the output file
    $configuration | ConvertTo-Yaml | Out-File -LiteralPath ([System.IO.Path]::Combine($OutputPath, "$nodeFileName.yml"))
    Write-Verbose "Configuration for node: $($NodeName.Name) has been converted to YAML and saved to file"
    

}
