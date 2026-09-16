<#
.SYNOPSIS
Joins values into a single string.

.DESCRIPTION
`concat` is the function-language spelling of string concatenation. Inside `properties` it is
rarely needed - `$(variables('Root'))\logs` already interpolates - but a `preCondition` has no
interpolation available to it, so building a comparison value there needs an accessor.

Every operand is converted to a string and the results are joined with no separator. A $null
operand contributes an empty string rather than the literal text 'null', so an optional variable
composes without a guard.

Unlike the ARM template language's concat(), this does NOT have a second array-merging mode.
PowerShell binds a variadic parameter by unrolling an array operand into separate arguments, so
`concat (variables 'Parts')` and `concat 'a' 'b'` arrive here indistinguishable - an array mode
could not be told apart from the string one, and guessing would make the result depend on a
variable's runtime shape. An array operand is therefore flattened and its elements joined. To
merge two arrays, use `+`, which is an operator rather than a command invocation and so is
permitted in a condition as well as in a property:

    preCondition: ((variables 'CoreTags') + (variables 'NodeTags')).Count -gt 2

Calling it with no operands returns an empty string, the identity for concatenation.

.PARAMETER Value
The operands to join. May be written out (`concat 'a' 'b'`) or supplied as an array, which is
flattened.

.EXAMPLE
PS> concat (variables 'Environment') '-' (variables 'Region')
Returns e.g. 'Production-westeurope'.

.EXAMPLE
PS> equals (concat (variables 'Prefix') '-db') (variables 'ServerName')
A condition comparing a configured name against one assembled from its parts.

.EXAMPLE
PS> concat 'v' (variables 'Major') '.' (variables 'Minor')
Returns e.g. 'v1.4' - numeric operands are converted to their string form.
#>
function invoke-concat {
    [CmdletBinding()]
    [Alias('concat')]
    param (
        [Parameter(ValueFromRemainingArguments)]
        [AllowNull()]
        [object[]] $Value
    )

    if ($null -eq $Value -or $Value.Count -eq 0) { return '' }

    $operands = Expand-ConditionArgumentList -Value $Value

    return -join ($operands | ForEach-Object { if ($null -eq $_) { '' } else { [string] $_ } })
}
