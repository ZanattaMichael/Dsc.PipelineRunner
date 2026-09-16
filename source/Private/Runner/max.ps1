<#
.SYNOPSIS
Returns the largest of the supplied numbers.

.DESCRIPTION
`max` is `min`'s counterpart and takes the same operand shapes: a list of numbers written out
(`max 3 1 2`), a single array operand (`max (variables 'Ports')`), or a mixture. Nested arrays
are flattened and every operand goes through ConvertTo-ConditionNumber, so string operands are
compared numerically rather than lexically.

Calling it with no operands throws, for the same reason `min` does.

.PARAMETER Value
One or more numbers, or arrays of numbers.

.EXAMPLE
PS> max (variables 'ConfiguredTimeoutSeconds') 30
Enforces a floor of thirty seconds on a configured timeout.

.EXAMPLE
PS> (max (variables 'DiskUsagePercentages')) -lt 90
A condition asserting that no disk in a configured list has passed ninety percent.
#>
function invoke-max {
    [CmdletBinding()]
    [Alias('max')]
    param (
        [Parameter(ValueFromRemainingArguments)]
        [AllowNull()]
        [object[]] $Value
    )

    $numbers = @(Expand-ConditionArgumentList -Value $Value | ForEach-Object { ConvertTo-ConditionNumber -Value $_ -Accessor 'max' })

    if ($numbers.Count -eq 0) {
        throw '[max] Expected at least one number.'
    }

    # Compared by hand rather than with Measure-Object, which returns a [double] for every input
    # and would turn a whole-number operand list into a real result.
    $selected = $numbers[0]
    foreach ($number in $numbers) {
        if ($number -gt $selected) { $selected = $number }
    }

    return $selected
}
