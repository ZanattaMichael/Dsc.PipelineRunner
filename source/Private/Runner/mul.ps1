<#
.SYNOPSIS
Multiplies two numbers, from a resource property or a condition.

.DESCRIPTION
`mul` is the function-language spelling of `*` over two numeric operands. Both are coerced
through ConvertTo-ConditionNumber, which preserves integrality and throws on a non-numeric
operand rather than treating it as 0.

.PARAMETER Left
The first factor.

.PARAMETER Right
The second factor.

.EXAMPLE
PS> mul (variables 'WorkerCount') 4
Returns four threads per configured worker.

.EXAMPLE
PS> (mul (variables 'SizeGb') 1024) -lt 8192
A condition expressed in megabytes over a value configured in gigabytes.
#>
function invoke-mul {
    [CmdletBinding()]
    [Alias('mul')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Left,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Right
    )

    return (ConvertTo-ConditionNumber -Value $Left -Accessor 'mul') * (ConvertTo-ConditionNumber -Value $Right -Accessor 'mul')
}
