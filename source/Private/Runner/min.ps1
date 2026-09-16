<#
.SYNOPSIS
Returns the smallest of the supplied numbers.

.DESCRIPTION
`min` accepts either a list of numbers written out (`min 3 1 2`) or a single array operand
(`min (variables 'Ports')`), because a configuration value that is conceptually a list arrives
as an array while a hand-written comparison arrives as separate arguments. Nested arrays are
flattened, so both spellings - and a mixture of them - behave the same.

Every operand goes through ConvertTo-ConditionNumber, so string operands read out of YAML are
compared numerically rather than lexically: `min '9' '10'` is 9, not '10'.

Calling it with no operands throws; there is no meaningful minimum of nothing, and returning
$null would put an empty value into a resource property.

.PARAMETER Value
One or more numbers, or arrays of numbers.

.EXAMPLE
PS> min (variables 'RequestedWorkers') 8
Caps a configured worker count at eight.

.EXAMPLE
PS> (min (variables 'ReplicaCounts')) -ge 2
A condition asserting that every replica count in a configured list is at least two.
#>
function invoke-min {
    [CmdletBinding()]
    [Alias('min')]
    param (
        [Parameter(ValueFromRemainingArguments)]
        [AllowNull()]
        [object[]] $Value
    )

    $numbers = @(Expand-ConditionArgumentList -Value $Value | ForEach-Object { ConvertTo-ConditionNumber -Value $_ -Accessor 'min' })

    if ($numbers.Count -eq 0) {
        throw '[min] Expected at least one number.'
    }

    # Compared by hand rather than with Measure-Object, which returns a [double] for every input
    # and would turn a whole-number operand list into a real result.
    $selected = $numbers[0]
    foreach ($number in $numbers) {
        if ($number -lt $selected) { $selected = $number }
    }

    return $selected
}
