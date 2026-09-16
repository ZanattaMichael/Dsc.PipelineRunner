<#
.SYNOPSIS
Converts a string to upper case.

.DESCRIPTION
`toUpper` is `toLower`'s counterpart and behaves the same way: it uses the INVARIANT culture so
the result does not depend on the machine's locale, returns an empty string for $null rather
than throwing, and converts a non-string value to its string form first.

.PARAMETER Value
The value to upper-case.

.EXAMPLE
PS> toUpper (variables 'RegionCode')
Returns 'WEU' for a variable set to 'weu'.

.EXAMPLE
PS> equals (toUpper (variables 'Ensure')) 'PRESENT'
A case-insensitive comparison written with the ordinal, case-sensitive `equals`.
#>
function invoke-toupper {
    [CmdletBinding()]
    [Alias('toUpper')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value
    )

    if ($null -eq $Value) { return '' }

    return ([string] $Value).ToUpperInvariant()
}
