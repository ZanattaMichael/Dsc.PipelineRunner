<#
.SYNOPSIS
Detects circular dependencies between resources.

.DESCRIPTION
This script detects circular dependencies between resources by iterating through each resource and checking if there are any circular references in the dependencies.

.PARAMETER PipelineResources
An array of pipeline resources.

.EXAMPLE
$PipelineResources = @(
    [PSCustomObject]@{
        Type = "ResourceType1"
        Name = "ResourceName1"
        DependsOn = @("ResourceType2/ResourceName2")
    },
    [PSCustomObject]@{
        Type = "ResourceType2"
        Name = "ResourceName2"
        DependsOn = @("ResourceType1/ResourceName1")
    }
)

Detect-CircularDependency -PipelineResources $PipelineResources

.NOTES
This script assumes that the pipeline resources are provided as an array of objects with the following properties:
- Type: The type of the resource.
- Name: The name of the resource.
- DependsOn: An array of dependencies for the resource in the format "Type/Name".
#>
[CmdletBinding()]
param(
    [Object[]]$PipelineResources
)

# Function to detect circular dependencies
function Detect-CircularDependency {
    param (
        [Object]$Resource,
        [System.Collections.ArrayList]$Stack
    )

    Write-Verbose ("[Test-CircularReferences][Detect-CircularDependency] Checking resource: {0}/{1}" -f $Resource.Type, $Resource.Name)

    # If the ResourceObject is a PSCustomObject, convert it to a Hashtable
    if ($ResourceObject -is [PSCustomObject]) {

        Write-Verbose "[Test-CircularReferences][Detect-CircularDependency] Converting PSCustomObject to Hashtable"

        $ht = @{}
        $ResourceObject.PSObject.Properties | ForEach-Object {
            $ht[$_.Name] = $_.Value
        }
        $ResourceObject = $ht
    }

    # Iterate through each of the Dependencies
    ForEach ($DependingResource in $Resource.DependsOn) {

        Write-Verbose "[Test-CircularReferences][Detect-CircularDependency] Checking dependency: $DependingResource"
        [Array]$circularDependency = $Stack | Where-Object { 
            ("{0}/{1}" -f $_.Type, $_.Name) -eq $DependingResource
        }
        if ($circularDependency.Count -ne 0) {
            $ResourceStack = ($Stack | ForEach-Object { "{0}/{1} ->" -f $_.Type, $_.Name }) -join ''
            throw ("[Test-CircularReferences][Detect-CircularDependency] Circular dependency detected with Resource: $ResourceStack $("{0}/{1}" -f $Resource.Type, $Resource.Name)")
        }

    }

    Write-Verbose ("[Test-CircularReferences][Detect-CircularDependency] Adding resource to stack: {0}/{1}" -f $Resource.Type, $Resource.Name)
    $Stack.Add($Resource)

    foreach ($Dep in $Resource.DependsOn) {
        Write-Verbose "[Test-CircularReferences][Detect-CircularDependency] Processing dependency: $Dep"

        # Locate the Resource within ResourceConfiguration
        $Split = $Dep.Split("/")
        $Name = $Split[1]
        $Type = $Split[0]

        $DepResource = $PipelineResources | Where-Object { $_.Type -eq $Type -and $_.Name -eq $Name }
        if ($DepResource) {
            Detect-CircularDependency -Resource $DepResource -Visited $Visited -Stack $Stack
        } else {
            Write-Verbose "[Test-CircularReferences][Detect-CircularDependency] Dependency not found: $Dep"
        }
    }
        
}

#
# Iterate through each resource and detect circular dependencies
ForEach ($ResourceObject in $PipelineResources) {
    Write-Verbose ("[Test-CircularReferences] Starting detection for resource: {0}/{1}" -f $ResourceObject.Type, $ResourceObject.Name)

    $params = @{
        Resource = $ResourceObject
        Stack = [System.Collections.ArrayList]@()
    }
    
    # Detect circular dependencies
    try {
        $null = Detect-CircularDependency @params
    } catch {
        Throw $_.Exception.Message
        return
    }
}
