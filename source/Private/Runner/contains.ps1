<#
.SYNOPSIS
Reports whether a string contains a substring, an array contains an element, or a dictionary
contains a key.

.DESCRIPTION
`contains` is one accessor over three containers, dispatching on the type of its first operand
exactly as the ARM template language's contains() does:

  - a DICTIONARY (hashtable, the shape a `variables` block of key/value pairs produces): does it
    have this KEY;
  - an ARRAY or other collection: does it have an element equal to this value;
  - anything else, including a string: does its string form contain this SUBSTRING.

Comparison is case-INSENSITIVE in all three modes, for the same reason `startsWith` is. Pass
-CaseSensitive for ordinal comparison throughout.

A $null container is never considered to contain anything, and returns $false rather than
throwing - so it composes with an optional variable without a preceding `empty` guard.

Note that this is the accessor `contains`, not PowerShell's `-contains` operator. The operator
is also permitted in a condition (operators are not command invocations), but it only handles
the array case and it is not available inside a `properties` expression in the same form.

.PARAMETER Container
The string, array or dictionary to search.

.PARAMETER Value
The substring, element or key to look for.

.PARAMETER CaseSensitive
Compare ordinally rather than case-insensitively.

.EXAMPLE
PS> contains (variables 'FeatureFlags') 'Boards'
Returns $true when the configured array of flags includes 'Boards' or 'boards'.

.EXAMPLE
PS> contains (variables 'ConnectionString') 'Encrypt=True'
A substring test over a configured string.

.EXAMPLE
PS> not (contains (variables 'ExcludedNodes') (nodeName))
A condition that skips a resource on the nodes a configuration lists as excluded.
#>
function invoke-contains {
    [CmdletBinding()]
    [Alias('contains')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Container,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Value,

        [switch] $CaseSensitive
    )

    if ($null -eq $Container) { return $false }

    $comparison = if ($CaseSensitive) { [System.StringComparison]::Ordinal }
                  else                { [System.StringComparison]::OrdinalIgnoreCase }

    if ($Container -is [System.Collections.IDictionary]) {

        $needle = if ($null -eq $Value) { '' } else { [string] $Value }

        foreach ($key in $Container.Keys) {
            if ([string]::Equals([string] $key, $needle, $comparison)) { return $true }
        }
        return $false
    }

    if (-not ($Container -is [string]) -and ($Container -is [System.Collections.IEnumerable])) {

        foreach ($element in $Container) {

            if ($null -eq $element) {
                if ($null -eq $Value) { return $true }
                continue
            }

            # Strings compare with the requested casing; anything else falls back to the type's
            # own equality, so an array of integers matches an integer operand.
            if (($element -is [string]) -or ($Value -is [string])) {
                if ([string]::Equals([string] $element, [string] $Value, $comparison)) { return $true }
            }
            elseif ($element -eq $Value) {
                return $true
            }
        }
        return $false
    }

    $haystack = [string] $Container
    $needle   = if ($null -eq $Value) { '' } else { [string] $Value }

    return $haystack.Contains($needle, $comparison)
}
