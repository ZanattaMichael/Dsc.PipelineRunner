<#
.SYNOPSIS
Retrieves a reference value from a predefined collection.

.DESCRIPTION
The `reference` function takes a string parameter `Name` and retrieves the corresponding value from the `$references` collection.

.PARAMETER Name
The name of the reference to retrieve from the `$references` collection.

.RETURNS
The value associated with the specified reference name.

.EXAMPLE
PS> reference -Name "exampleReference"
This will return the value associated with "exampleReference" from the `$references` collection.
#>

function invoke-reference {
    [CmdletBinding()]
    [Alias('reference')]
    param ([string] $Name)

    $value = $references[$Name]
    return $value
}
