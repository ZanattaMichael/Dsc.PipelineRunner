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
 It relies on other functions such as Expand-ParameterInArray and Resolve-PipelineParameter.
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

        if ($null -eq $InputHashTable[$key]) {
            # Preserve nulls rather than calling .GetType() on them (which throws)
            $inputValue = $null
        }
        elseif ($InputHashTable[$key] -is [bool]) {
            # Keep the boolean value as is; -match would coerce it to the string 'True'
            $inputValue = $InputHashTable[$key]
        }
        elseif ($InputHashTable[$key] -is [hashtable]) {
            # Recursively expand the hashtable
            $inputValue = Expand-Parameters -InputHashTable $InputHashTable[$key]
        }
        elseif (($InputHashTable[$key].GetType().Name -eq 'List`1') -or ($InputHashTable[$key] -is [array])) {
            # Expand the parameters in the list/array, reading from this hashtable rather than
            # the caller's $task (a caller-scope read expanded a nested hashtable against the
            # wrong values, or none at all outside the runner). Every list is expanded
            # element-wise and keeps its shape: a one-entry list must not fall through to the
            # scalar branch below, where -match stringifies its element (a lone hashtable never
            # had its tokens expanded, and a lone token collapsed the list to a scalar).
            $inputValue = Expand-ParameterInArray $InputHashTable[$key]
        }
        elseif ($InputHashTable[$key] -match '^\<params\=(?<name>.+)\>$') {
            # Whole-scalar substitution: the value is exactly one parameter token, so it is
            # replaced by the parameter's value with its type intact.
            $inputValue = Resolve-PipelineParameter -Name $Matches['name']
        } else {
            # If the value is a string, expand the parameter
            $inputValue = $InputHashTable[$key]
        }

        # Add the property to the hashtable
        $Property[$key] = $inputValue
    }

    return $Property

}
