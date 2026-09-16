<#
.SYNOPSIS
Adds two numbers, from a resource property or a condition.

.DESCRIPTION
`add` is the function-language spelling of `+` over two numeric operands. It exists because a
condition may only invoke allow-listed commands, and because an operand read out of a
configuration file is routinely a string ('7') rather than a number - both operands are coerced
through ConvertTo-ConditionNumber, which preserves integrality, so `add 1 2` returns 3 and not
3.0.

A non-numeric operand throws rather than resolving to 0, so a mistyped value fails the resource
instead of quietly applying arithmetic on nothing.

.PARAMETER Left
The first addend.

.PARAMETER Right
The second addend.

.EXAMPLE
PS> add (variables 'BasePort') 10
Returns the configured base port offset by ten.

.EXAMPLE
PS> (add (variables 'Retries') 1) -le 5
A condition that allows one more attempt than the configured retry count.
#>
function invoke-add {
    [CmdletBinding()]
    [Alias('add')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Left,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Right
    )

    return (ConvertTo-ConditionNumber -Value $Left -Accessor 'add') + (ConvertTo-ConditionNumber -Value $Right -Accessor 'add')
}
