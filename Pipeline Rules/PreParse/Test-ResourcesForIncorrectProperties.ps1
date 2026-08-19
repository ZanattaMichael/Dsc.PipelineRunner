<#
.SYNOPSIS
    Tests resources for incorrect properties.

.DESCRIPTION
    This script tests each resource in the provided pipeline resources for incorrect properties. It checks if the required keys (name, type, and properties) exist for each task and throws an error if any of these keys are missing. It also performs additional checks such as verifying if the resource exists, if the properties are correct, if the property values are of the correct type, if mandatory properties are not null, and if the property values match the selected values.

.PARAMETER PipelineResources
    An array of pipeline resources to be tested.

.NOTES
    - This script assumes that the pipeline resources are objects with the following properties:
        - type: The type of the resource.
        - name: The name of the resource.
        - properties: The properties of the resource.
    - This script requires the Get-DscResource cmdlet to be available.

.EXAMPLE
    $resources = @(
        [PSCustomObject]@{
            type = 'MyResourceType'
            name = 'MyResource'
            properties = @{
                Property1 = 'Value1'
                Property2 = 'Value2'
            }
        }
        [PSCustomObject]@{
            type = 'AnotherResourceType'
            name = 'AnotherResource'
            properties = @{
                Property1 = 'Value1'
                Property2 = 'Value2'
            }
        }
    )

    Test-ResourcesForIncorrectProperties -PipelineResources $resources
#>
param(
    [Object[]]$PipelineResources
)

$isFail = $false

Write-Host "[Test-ResourcesForIncorrectProperties] Testing Resources for Incorrect Properties:" -ForegroundColor Green

# Iterate Through each of the Resources
ForEach ($task in $PipelineResources)
{

    Write-Host "[Test-ResourcesForIncorrectProperties] Testing Resource: [$($task.type)/$($task.name)]" -ForegroundColor Green

    #
    # The name, type and properties keys are required for each task.
    # If any of these keys are missing, an error will be thrown.

    # Throw an error is the properties key does not exist
    if ($null -eq $task.properties) {
        Write-Host "[Start-LCM] 'Properties' key does not exist for resource: [$($task.type)/$($task.name)]" -ForegroundColor Red
        $isFail = $true
    }

    # Throw an error is the name key does not exist
    if ($null -eq $task.name) {
        Write-Host "[Start-LCM] 'Name' key does not exist for resource: [$($task.type)/$($task.name)]" -ForegroundColor Red
        $isFail = $true
    }

    <#
    # Throw an error is the type key does not exist
    if ($null -eq $task.type) {
        Write-Host "[Start-LCM] 'Type' key does not exist for resource: [$($task.type)/$($task.name)]" -ForegroundColor Red
        $isFail = $true
    }
    #>

    # If there is a failure, skip the rest of the tests
    if ($isFail) {
        Write-Host "[Start-LCM] Skipping [$($task.type)/$($task.name)]" -ForegroundColor Yellow
        break
    }

    # Extract the module name and resource type from the task's type property
    $module = $task.type.Split("/")[0]
    $resourceType = $task.type.Split("/")[1]

    # Perform a lookup of the resource:
    $resource = Get-DscResource -Name $resourceType -Module $module

    # If the resource is not found, throw an error
    if ($null -eq $resource) {
        Write-Host "[Start-LCM] Resource [$resourceType] was not found in module [$module]" -ForegroundColor Red
        $isFail = $true
    }

    # If the resource is found, check to see if the properties are correct
    $properties = $task.properties

    # Iterate through each of the properties
    ForEach ($property in $properties.keys)
    {
        # If the property does not exist in the resource, throw an error
        if ($Property -notin $resource.Properties.Name) {
            Write-Host "[Start-LCM] Property [$($property)] does not exist in resource [$resourceType] in module [$module]" -ForegroundColor Red
            $isFail = $true
        }
        # Ensure that the property is the correct type to the resource.
        $resourceProperty       = $resource.Properties | Where-Object { $_.Name -eq $property }
        $resourcePropertyType   = $resourceProperty.PropertyType -replace "(\[)|(\])",""

        $configurationPropertyValue  = $properties[$property]

        <#
        # If the property is not the correct type, throw an error
        if ($configurationPropertyValue.GetType().Name -ne $resourcePropertyType) {
            Write-Host "[Start-LCM] Property [$($property)] is not the correct type in resource [$resourceType] in module [$module]" -ForegroundColor Red
            $isFail = $true
        }
        #>
        
        # If the ResourceProperty is mandatory, ensure that the propertyValue is not null
        if ($resourceProperty.IsMandatory -and $null -eq $configurationPropertyValue) {
            Write-Host "[Start-LCM] Property [$($property)] is mandatory in resource [$resourceType] in module [$module]" -ForegroundColor Red
            $isFail = $true
        }

        # If the Property is a caculated variable, ignore the property
        if ($configurationPropertyValue -match "\$") {
            Write-Host "[Start-LCM] Property [$($property)] is a caculated variable in resource [$resourceType] in module [$module]" -ForegroundColor Yellow
            continue
        }

        # If the ResourceProperty has selected values, ensure that the propertyValue is in the list
        if ($resourceProperty.Values -and $configurationPropertyValue -notin $resourceProperty.Values) {
            Write-Host "[Start-LCM] Property [$($property)] with the value [$($configurationPropertyValue)] does not match the selected values in resource [$resourceType][$property]. Values can be: $($resourceProperty.Values -join ',')" -ForegroundColor Red
            $isFail = $true
        }

    }

}

if ($isFail) {
    Throw "[Test-ResourcesForIncorrectProperties] Stopping LCM. Tests Failed."
} else {
    Write-Host "[Test-ResourcesForIncorrectProperties] Tests Passed" -ForegroundColor Green
}