<#
.SYNOPSIS
Divides the first number by the second, from a resource property or a condition.

.DESCRIPTION
`div` is the function-language spelling of `/` over two numeric operands, with one deliberate
difference from PowerShell's own operator: when BOTH operands are whole numbers the result is
whole-number division truncated toward zero, so `div 7 2` is 3, not 3.5. That matches the ARM
template language the function language is modelled on, and it is what makes `div` usable for
the sizing arithmetic it is normally reached for (nodes per rack, shards per host) without a
cast at every call site.

When either operand is fractional the division is ordinary real division: `div 7.5 2` is 3.75.

Division by zero throws rather than producing infinity, because an infinite value landing in a
resource property is a far harder failure to diagnose than a message naming the accessor.

.PARAMETER Left
The dividend.

.PARAMETER Right
The divisor. Zero is a terminating error.

.EXAMPLE
PS> div (variables 'TotalNodes') 3
Returns the whole number of nodes per group.

.EXAMPLE
PS> (div (variables 'MemoryMb') 1024) -ge 8
A condition expressed in gigabytes over a value configured in megabytes.
#>
function invoke-div {
    [CmdletBinding()]
    [Alias('div')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Left,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Right
    )

    $dividend = ConvertTo-ConditionNumber -Value $Left -Accessor 'div'
    $divisor  = ConvertTo-ConditionNumber -Value $Right -Accessor 'div'

    if ($divisor -eq 0) {
        throw "[div] Division by zero: cannot divide [$dividend] by [$divisor]."
    }

    # ConvertTo-ConditionNumber returns [long] for a whole number and [double] otherwise, so
    # the operand types alone decide which division was meant - no separate type hint needed.
    if (($dividend -is [long]) -and ($divisor -is [long])) {
        return [long] [System.Math]::Truncate($dividend / $divisor)
    }

    return $dividend / $divisor
}
