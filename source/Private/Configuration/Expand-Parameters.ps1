<#
 .SYNOPSIS
 Expands the parameters in the provided hashtable.

 .DESCRIPTION
 The Expand-Parameters function takes a hashtable as input and iterates through each key in the hashtable.
 It recursively expands nested hashtables, expands strings in lists, and replaces placeholders with actual values from a parameters hashtable.

 .PARAMETER InputHashTable
 The hashtable containing parameters to be expanded.

 .EXAMPLE
 $expandedParams = Expand-Parameters -InputHashTable $myHashtable
 This example demonstrates how to call the Expand-Parameters function with a hashtable.

 .NOTES
 This function is part of the Dsc.PipelineRunner module and is intended for internal use.
 It relies on other functions such as Expand-HashTable and Expand-ParameterInArray.
 If a placeholder parameter is not found in the parameters hashtable, an error is thrown.
#>

# Function to Expand the Parameters in the Hashtable
Function Expand-Parameters {
    param(
        [Parameter(Mandatory=$true)]
        [HashTable]$InputHashTable
    )

    $Property = @{}

    # Iterate through each key in the hashtable
    foreach ($key in $InputHashTable.Keys) {
            
        if ($InputHashTable[$key] -is [hashtable]) {
            # Recursively expand the hashtable
            $inputValue = Expand-Parameters -InputHashTable $InputHashTable[$key]
        }
        elseif ($InputHashTable[$key].GetType().Name -eq 'List`1') {
            # Expand the string in the list
            $inputValue = Expand-ParameterInArray $task.properties[$key]
        }
        elseif (($InputHashTable[$key] -is [array]) -and ($InputHashTable[$key].Count -ne 1)) {
            # If the value is a string, expand the parameter
            $inputValue = Expand-ParameterInArray $InputHashTable[$key]
        }
        elseif ($InputHashTable[$key] -match '^\<params\=(?<name>.+)\>$') {
            # If the parameter is not found, throw an error
            $propertyName = $Matches['name']
            if ([String]::IsNullOrEmpty($Script:parameters."$propertyName")) {
                throw "[Expand-Parameters] Parameter '$propertyName' not found in the parameters hashtable."
            }
            # Replace the Properties with the value
            $inputValue = $Script:parameters."$propertyName"

        } else {
            # If the value is a string, expand the parameter
            $inputValue = $InputHashTable[$key]
        }

        # Add the property to the hashtable
        $Property[$key] = $inputValue
    }

    return $Property

}
