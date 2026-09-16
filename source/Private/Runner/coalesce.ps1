<#
.SYNOPSIS
Returns the first operand that is not $null.

.DESCRIPTION
`coalesce` supplies a fallback for a value that a configuration layer may legitimately leave
unset. It returns its first operand that is not $null, and $null when every operand is null.

Only $null counts as absent, matching the ARM template language: an empty string, an empty
array and an empty hashtable are all values, and `coalesce '' 'fallback'` returns the empty
string. That is the behaviour to want when a layer deliberately blanks a value, and the wrong
one when a blank means "not supplied" - for that case, pair it with `empty`:

    preCondition: not (empty (coalesce (variables 'Owner') (variables 'DefaultOwner')))

Operands are evaluated by PowerShell before `coalesce` is called - it is an accessor, not a
short-circuiting operator - so `coalesce (variables 'A') (parameters 'B')` still throws when
parameter B is undefined, even if variable A has a value.

.PARAMETER Value
The operands, in priority order. May be written out or supplied as an array.

.EXAMPLE
PS> coalesce (variables 'NodeOwner') (variables 'TeamOwner') 'platform@example.com'
Returns the most specific owner that a configuration layer actually set.

.EXAMPLE
PS> equals (coalesce (variables 'Ensure') 'Present') 'Present'
A condition with a default for an unset variable.
#>
function invoke-coalesce {
    [CmdletBinding()]
    [Alias('coalesce')]
    param (
        [Parameter(ValueFromRemainingArguments)]
        [AllowNull()]
        [object[]] $Value
    )

    foreach ($operand in (Expand-ConditionArgumentList -Value $Value)) {
        if ($null -ne $operand) { return $operand }
    }

    return $null
}
