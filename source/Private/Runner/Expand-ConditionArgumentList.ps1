<#
.SYNOPSIS
Flattens the operand list of a variadic function-language accessor.

.DESCRIPTION
The variadic accessors (`concat`, `coalesce`, `min`, `max`) are called two different ways from a
configuration, and both have to mean the same thing:

    concat 'a' 'b' 'c'              # operands written out - binds as @('a','b','c')
    concat (variables 'Parts')      # one array operand  - binds as @(@('a','b','c'))

PowerShell's ValueFromRemainingArguments binding does not collapse the second shape, so without
this helper `min (variables 'Ports')` would try to convert an entire array to a single number.
Flattening once, here, keeps that difference out of every accessor.

Flattening is recursive over arrays and other non-string enumerables, and deliberately stops at
[string] (which is enumerable as characters) and at [System.Collections.IDictionary] (a
hashtable operand is a single value, not a list of its entries). $null operands are preserved
rather than dropped, because `coalesce` has to be able to see them.

This is an internal helper, not an accessor: it is not on the condition allow-list and a
configuration cannot name it.

.PARAMETER Value
The raw operand list as bound by the calling accessor.

.EXAMPLE
Expand-ConditionArgumentList -Value @(@(1, 2), 3)
Returns 1, 2, 3.
#>
function Expand-ConditionArgumentList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Value
    )

    $flattened = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $Value) { return @() }

    foreach ($item in $Value) {

        if ($null -eq $item) {
            $flattened.Add($null)
            continue
        }

        if (($item -is [string]) -or ($item -is [System.Collections.IDictionary]) -or
            -not ($item -is [System.Collections.IEnumerable])) {
            $flattened.Add($item)
            continue
        }

        foreach ($nested in (Expand-ConditionArgumentList -Value @($item))) {
            $flattened.Add($nested)
        }
    }

    return $flattened.ToArray()
}
