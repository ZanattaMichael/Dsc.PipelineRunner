
<#
.SYNOPSIS
Expands strings in an array by performing expansion logic (e.g., expanding environment variables).

.DESCRIPTION
The Expand-StringInArray function takes an array of strings as input and expands each string by performing expansion logic. If an element in the array is a string, it will be expanded using the ExpandString method of the ExecutionContext object. If an element is not a string, it will be added to the expanded array as is.

.PARAMETER InputArray
The array of strings to be expanded.

.EXAMPLE
$strings = @("Hello, $env:USERNAME!", "Today is $((Get-Date).ToString('dddd'))")
$expandedStrings = Expand-StringInArray -InputArray $strings
$expandedStrings
# Output:
# Hello, John!
# Today is Monday

.NOTES
This function is useful when you need to expand strings in an array, such as when working with configuration files or templates.
#>
function Expand-StringInArray {
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
        elseif ($item -is [string]) {
            # Perform expansion logic here (example: expanding environment variables)
            $expandedArray.Add((Expand-SafeString -Value $item))
        }
        elseif ($item -is [hashtable]) {
            $expandedArray.Add((Expand-HashTable -InputHashTable $item))
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