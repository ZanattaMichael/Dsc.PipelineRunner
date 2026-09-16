<#
.SYNOPSIS
Subtracts the second number from the first, from a resource property or a condition.

.DESCRIPTION
`sub` is the function-language spelling of `-` over two numeric operands. Both are coerced
through ConvertTo-ConditionNumber, which preserves integrality and throws on a non-numeric
operand rather than treating it as 0.

Note that the operand order is the written one: `sub 10 3` is 7, not -7.

.PARAMETER Left
The minuend - the value subtracted from.

.PARAMETER Right
The subtrahend - the value subtracted.

.EXAMPLE
PS> sub (variables 'MaxConnections') 1
Returns one fewer than the configured maximum.

.EXAMPLE
PS> (sub (variables 'DiskTotalGb') (variables 'DiskUsedGb')) -gt 20
A condition that gates a resource on at least 20 GB of free space.
#>
function invoke-sub {
    [CmdletBinding()]
    [Alias('sub')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Left,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Right
    )

    return (ConvertTo-ConditionNumber -Value $Left -Accessor 'sub') - (ConvertTo-ConditionNumber -Value $Right -Accessor 'sub')
}
