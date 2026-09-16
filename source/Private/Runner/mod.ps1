<#
.SYNOPSIS
Returns the remainder of dividing the first number by the second.

.DESCRIPTION
`mod` is the function-language spelling of `%`. Both operands are coerced through
ConvertTo-ConditionNumber, and as with `div` a zero divisor throws rather than producing NaN.

The sign of the result follows PowerShell's own `%` operator, which takes the sign of the
dividend: `mod -7 3` is -1.

.PARAMETER Left
The dividend.

.PARAMETER Right
The divisor. Zero is a terminating error.

.EXAMPLE
PS> mod (variables 'NodeIndex') 2
Returns 0 for an even node index and 1 for an odd one.

.EXAMPLE
PS> (mod (variables 'NodeIndex') 2) -eq 0
A condition that applies a resource only to even-numbered nodes.
#>
function invoke-mod {
    [CmdletBinding()]
    [Alias('mod')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Left,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Right
    )

    $dividend = ConvertTo-ConditionNumber -Value $Left -Accessor 'mod'
    $divisor  = ConvertTo-ConditionNumber -Value $Right -Accessor 'mod'

    if ($divisor -eq 0) {
        throw "[mod] Division by zero: cannot take [$dividend] modulo [$divisor]."
    }

    return $dividend % $divisor
}
