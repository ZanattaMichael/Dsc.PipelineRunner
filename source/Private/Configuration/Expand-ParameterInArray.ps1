<#
.SYNOPSIS
Expands parameters within an array.

.DESCRIPTION
The `Expand-ParameterInArray` function processes each element in the input array and expands any parameters found within the array. 
It handles boolean values, strings that match a specific pattern, and hashtables.

.PARAMETER InputArray
The array of input elements to be processed and expanded.

.EXAMPLE
$input = @('<params=example>', $true, @{ key = 'value' })
$expanded = Expand-ParameterInArray -InputArray $input
# This will expand the parameters within the input array.

.NOTES
If a parameter within the array is not found in the `$Script:parameters` hashtable, an error will be thrown.
#>
# Function to Expand the Parameters in the Array
function Expand-ParameterInArray {
    param (
        [Parameter(Mandatory=$true)]
        # An empty list is a valid value (`tags: []`) and must come back as an empty list.
        [AllowEmptyCollection()]
        [array]$InputArray
    )

    # Process each element in the array
    $expandedArray = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $InputArray) {
        if ($item -is [bool]) {
            # Keep the boolean value as is
            $expandedArray.Add($item)
        }       
        elseif (($item -is [string]) -and ($item -match '^\<params\=(?<name>.+)\>$')) {

            # Substitute the parameter with the parameter value. Presence is a key lookup, so
            # a parameter defined as an empty string resolves rather than being reported
            # missing (see Resolve-PipelineParameter).
            $resolved = Resolve-PipelineParameter -Name $Matches['name']
            # `+=` flattened an array-valued parameter into the output; keep that behaviour.
            if ($resolved -is [array]) { $expandedArray.AddRange($resolved) } else { $expandedArray.Add($resolved) }
        }
        elseif ($item -is [hashtable]) {
            $expandedArray.Add((Expand-Parameters -InputHashTable $item))
        } 
        elseif (($item -is [System.Collections.IList]) -and ($item -isnot [System.Collections.IDictionary])) {
            # `+=` flattened a nested array one level; AddRange keeps that behaviour. A YAML
            # configuration nests a List[object] rather than an object[], so both are matched
            # and a nested list behaves the same whichever format the configuration is in.
            $expandedArray.AddRange(@($item))
        }
        else {
            $expandedArray.Add($item)
        }
    }

    # The unary comma stops PowerShell unrolling the result on its way out: a plain
    # `return $expandedArray` handed the caller a scalar for a one-entry list and $null for
    # an empty one, so a resource property declared as a list reached the engine as a single
    # value. The result is always an object[], whatever its length.
    return , $expandedArray.ToArray()
}
