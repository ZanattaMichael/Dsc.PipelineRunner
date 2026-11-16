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
    - This script uses Get-DscResource. Under the DSC v3 engine a resource it cannot look up is
      left for dsc to validate at run time (see the note below the parameters).

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
# Write-Host is used deliberately for the operator-facing pass/fail banner (colored,
# always visible on the host running the pre-parse check). It is not diagnostic output.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Intentional colored operator-facing pass/fail banner, not redirectable diagnostic output.')]
param(
    [Object[]]$PipelineResources,

    # Resolved PipelineRunnerSettings, forwarded by Invoke-PreParseRules to every rule (#57 §2).
    # This rule reads the engine from it: ResolvedEngine (set by Start-DscRunner, and reflecting
    # an explicit -Engine) or else the configuration's own Engine.
    [hashtable]$Settings
)

# Which engine will run these resources. Under the DSC v3 engine a resource can be one that
# PowerShell's Get-DscResource cannot see (a native DSC v3 resource such as Microsoft.DSC.Debug/Echo),
# and on Linux and macOS Get-DscResource itself cannot load (it needs the OMI library). dsc
# validates each resource's properties against that resource's own schema when it runs, so for
# DSC v3 a resource this rule cannot look up is left to dsc rather than reported as an error.
$engineName = ''
if ($Settings) {
    $engineName = [string]$Settings['ResolvedEngine']
    if (-not $engineName) { $engineName = [string]$Settings['Engine'] }
}
$isDscV3 = $engineName -eq 'DscV3'

# Collect every validation error across all resources, then fail once at the end.
# Previously $isFail persisted across iterations and a `break` aborted the loop, so
# only the first offending resource was ever reported.
$allErrors = [System.Collections.Generic.List[string]]::new()

# Get-DscResource is by far the most expensive call in this rule, and a configuration usually has
# many resources of a handful of types. Look each module/resource pair up once per invocation. The
# cache is local to this run of the rule (one configuration file), so it can never serve another
# node's or another run's answer, and a lookup that finds nothing is not cached, so the
# not-found diagnostic is produced exactly as before.
$dscResourceLookup = @{}

Write-Host "[Test-ResourcesForIncorrectProperties] Testing Resources for Incorrect Properties:" -ForegroundColor Green

# Iterate Through each of the Resources
ForEach ($task in $PipelineResources)
{

    Write-Host "[Test-ResourcesForIncorrectProperties] Testing Resource: [$($task.type)/$($task.name)]" -ForegroundColor Green

    # Track failures for this resource only, so a missing key skips the deeper
    # checks for this resource without aborting validation of the remaining ones.
    $resourceHasError = $false

    #
    # The name, type and properties keys are required for each task.

    # Report an error if the properties key does not exist
    if ($null -eq $task.properties) {
        $allErrors.Add("[Dsc.PipelineRunner] 'Properties' key does not exist for resource: [$($task.type)/$($task.name)]")
        $resourceHasError = $true
    }

    # Report an error if the name key does not exist
    if ($null -eq $task.name) {
        $allErrors.Add("[Dsc.PipelineRunner] 'Name' key does not exist for resource: [$($task.type)/$($task.name)]")
        $resourceHasError = $true
    }

    # If a required key is missing, skip the deeper checks for THIS resource only
    # (continue to the next resource rather than break out of the whole loop).
    if ($resourceHasError) {
        Write-Host "[Dsc.PipelineRunner] Skipping [$($task.type)/$($task.name)]" -ForegroundColor Yellow
        continue
    }

    # Extract the module name and resource type from the task's type property
    $module = $task.type.Split("/")[0]
    $resourceType = $task.type.Split("/")[1]

    # Perform a lookup of the resource (once per distinct module/resource pair):
    $lookupKey = "$module/$resourceType"
    if ($dscResourceLookup.ContainsKey($lookupKey)) {
        $resource = $dscResourceLookup[$lookupKey]
    }
    else {
        if ($isDscV3) {
            # Best effort under DSC v3 (see the note at the top): a lookup that fails, or finds
            # nothing, is not an error.
            try { $resource = Get-DscResource -Name $resourceType -Module $module -ErrorAction Stop -WarningAction SilentlyContinue }
            catch { $resource = $null }
        }
        else {
            $resource = Get-DscResource -Name $resourceType -Module $module
        }
        if ($null -ne $resource) { $dscResourceLookup[$lookupKey] = $resource }
    }

    if ($null -eq $resource -and $isDscV3) {
        Write-Verbose "[Test-ResourcesForIncorrectProperties] [$($task.type)/$($task.name)] is not a resource PowerShell can describe; under the DSC v3 engine dsc validates its properties when it runs."
        continue
    }

    # If the resource is not found, report an error and skip its property checks
    if ($null -eq $resource) {
        $allErrors.Add("[Dsc.PipelineRunner] Resource [$resourceType] was not found in module [$module]")
        continue
    }

    # If the resource is found, check to see if the properties are correct
    $properties = $task.properties

    # Iterate through each of the properties
    ForEach ($property in $properties.keys)
    {
        # If the property does not exist in the resource, report an error
        if ($Property -notin $resource.Properties.Name) {
            $allErrors.Add("[Dsc.PipelineRunner] Property [$($property)] does not exist in resource [$resourceType] in module [$module]")
        }
        # Find the schema entry for this property. A plain loop: a Where-Object pipeline per
        # configured property is measurably slower on a resource with a large schema.
        $resourceProperty = foreach ($candidate in $resource.Properties) { if ($candidate.Name -eq $property) { $candidate } }

        $configurationPropertyValue  = $properties[$property]

        # If the ResourceProperty is mandatory, ensure that the propertyValue is not null
        if ($resourceProperty.IsMandatory -and $null -eq $configurationPropertyValue) {
            $allErrors.Add("[Dsc.PipelineRunner] Property [$($property)] is mandatory in resource [$resourceType] in module [$module]")
        }

        # If the Property is a caculated variable, ignore the property
        if ($configurationPropertyValue -match "\$") {
            Write-Host "[Dsc.PipelineRunner] Property [$($property)] is a caculated variable in resource [$resourceType] in module [$module]" -ForegroundColor Yellow
            continue
        }

        # If the ResourceProperty has selected values, ensure that the propertyValue is in the list.
        # The offending value is deliberately NOT interpolated into the diagnostic: property
        # values routinely carry secrets, and this log is readable by a wider audience than the
        # configuration repository (#34). Name the property, the resource and the permitted set;
        # an operator who needs the value can read the configuration they already have access to.
        if ($resourceProperty.Values -and $configurationPropertyValue -notin $resourceProperty.Values) {
            $allErrors.Add("[Dsc.PipelineRunner] Property [$($property)] does not match the selected values in resource [$resourceType][$property]. Permitted values: $($resourceProperty.Values -join ', ')")
            # Opt-in breadcrumb on the verbose stream only, redacted for sensitive property names.
            Write-Verbose "[Dsc.PipelineRunner] Property [$property] provided value: $(Protect-SensitiveValue -Name $property -Value $configurationPropertyValue)"
        }

    }

}

# Emit every collected error, then stop the run once — so an operator sees all
# offending resources/properties in a single pass instead of fix-and-rerun.
if ($allErrors.Count -gt 0) {
    foreach ($validationError in $allErrors) {
        Write-Host $validationError -ForegroundColor Red
    }
    Throw "[Test-ResourcesForIncorrectProperties] Tests Failed ($($allErrors.Count) issue(s)). Stopping runner."
} else {
    Write-Host "[Test-ResourcesForIncorrectProperties] Tests Passed" -ForegroundColor Green
}