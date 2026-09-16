<#
.SYNOPSIS
Reports whether a value is null, an empty string, or an empty collection.

.DESCRIPTION
`empty` is the guard that `variables()` needs. An undefined variable resolves to $null rather
than throwing, which is deliberate - a configuration layer may legitimately leave a variable
unset - but it means a condition that simply compares the value cannot tell "unset" from
"set to something that happens not to match". `empty` makes that check expressible without a
method call, which the condition validator rejects.

It returns $true for:

  - $null;
  - an empty string (a string of only whitespace is NOT empty, matching the ARM template
    language's empty() - use a trim in a property expression if you need that);
  - an empty array or other collection;
  - an empty hashtable or dictionary.

Everything else, including $false and 0, is not empty: `empty` asks whether a value is present,
not whether it is truthy.

.PARAMETER Value
The value to test.

.EXAMPLE
PS> empty (variables 'OptionalOwner')
Returns $true when the variable was never defined by any configuration layer.

.EXAMPLE
PS> not (empty (variables 'ProjectId'))
A condition that runs the resource only once an upstream value has been supplied.
#>
function invoke-empty {
    [CmdletBinding()]
    [Alias('empty')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value
    )

    if ($null -eq $Value) { return $true }

    if ($Value -is [string]) { return [string]::IsNullOrEmpty($Value) }

    if ($Value -is [System.Collections.IDictionary]) { return ($Value.Count -eq 0) }

    if ($Value -is [System.Collections.ICollection]) { return ($Value.Count -eq 0) }

    if ($Value -is [System.Collections.IEnumerable]) {
        # No Count to read, so emptiness is "does the enumerator yield anything at all".
        return -not $Value.GetEnumerator().MoveNext()
    }

    return $false
}
