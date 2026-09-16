<#
.SYNOPSIS
Converts a string to lower case.

.DESCRIPTION
`toLower` lower-cases a value using the INVARIANT culture, so a configuration produces the same
result on a machine whose locale would otherwise apply its own casing rules (the Turkish
dotless-i being the usual example). That is the reason to use it rather than a `.ToLower()`
method call, quite apart from the condition validator rejecting method invocations outright.

A $null value returns an empty string rather than throwing, so it composes with an optional
variable. A non-string value is converted to its string form first.

.PARAMETER Value
The value to lower-case.

.EXAMPLE
PS> toLower (variables 'Environment')
Returns 'production' for a variable set to 'Production'.

.EXAMPLE
PS> equals (toLower (variables 'Environment')) 'production'
A case-insensitive comparison written with the ordinal, case-sensitive `equals`.
#>
function invoke-tolower {
    [CmdletBinding()]
    [Alias('toLower')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value
    )

    if ($null -eq $Value) { return '' }

    return ([string] $Value).ToLowerInvariant()
}
