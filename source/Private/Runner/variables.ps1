<#
.SYNOPSIS
Retrieves the value of a specified variable from a predefined collection.

.DESCRIPTION
The `variables` function takes a variable name as input and returns the corresponding value from a predefined collection of variables.

.PARAMETER Name
The name of the variable whose value is to be retrieved.

.RETURNS
The value of the specified variable.

.EXAMPLE
PS> variables -Name 'MyVariable'
This command retrieves the value of 'MyVariable' from the collection of variables.

.NOTES
Ensure that the collection of variables is defined and accessible within the scope where this function is called.
#>

function invoke-variables {
    [CmdletBinding()]
    [Alias('variables')]
    param ([string] $Name)

    $value = $variables[$Name]
    return $value
}