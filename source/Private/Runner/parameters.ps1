<#
.SYNOPSIS
Retrieves the value of a specified parameter from the $parameters hashtable.

.PARAMETER Name
The name of the parameter whose value is to be retrieved.

.RETURNS
The value of the specified parameter.

.EXAMPLE
$paramValue = parameters -Name 'ParameterName'
#>

function invoke-parameters {
    [CmdletBinding()]
    [Alias('parameters')]
    param ([string] $Name)

    $value = $parameters[$Name]
    return $value
}
