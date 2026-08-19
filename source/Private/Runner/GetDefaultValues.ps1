<#
.SYNOPSIS
    Retrieves default values from a hashtable.

.DESCRIPTION
    The GetDefaultValues function takes a hashtable as input and returns a new hashtable containing the default values for each key in the input hashtable.

.PARAMETER Source
    The hashtable containing keys and their associated values. Each value is expected to have a 'defaultValue' property.

.RETURNS
    [hashtable] A hashtable containing the default values for each key in the input hashtable.

.EXAMPLE
    $source = @{
        Key1 = @{ defaultValue = 'Value1' }
        Key2 = @{ defaultValue = 'Value2' }
    }
    $defaultValues = GetDefaultValues -Source $source
    # $defaultValues will be @{ Key1 = 'Value1'; Key2 = 'Value2' }

.NOTES
    Author: Your Name
    Date: YYYY-MM-DD
#>

function Get-DefaultValues {
    [CmdletBinding()]
    [Alias('GetDefaultValues')]
    param (
        [hashtable] $Source
    )

    $values = @{}
    foreach ($key in $Source.Keys) {
        $values.Add($key, $Source[$key].defaultValue)
    }

    return $values
}