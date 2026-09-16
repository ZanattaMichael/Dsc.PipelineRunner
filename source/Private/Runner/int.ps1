<#
.SYNOPSIS
Converts a value to a whole number, truncating toward zero.

.DESCRIPTION
`int` turns a string or fractional value into a [long]. It is the accessor to reach for when a
resource property must be a number rather than the string a YAML scalar would otherwise supply,
or when a real-valued computation has to land on a whole number: `int (div 7.0 2)` is 3.

Truncation is toward zero, not rounding, which is what the ARM template language's int() does
as well: `int 2.9` is 2 and `int -2.9` is -2.

A non-numeric value throws rather than becoming 0.

.PARAMETER Value
The value to convert.

.EXAMPLE
PS> int (variables 'PortNumber')
Returns the configured port as a number, even when YAML supplied it as the string '8080'.

.EXAMPLE
PS> (int (variables 'RetryCount')) -gt 0
A condition that compares numerically rather than lexically.
#>
function invoke-int {
    [CmdletBinding()]
    [Alias('int')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value
    )

    $number = ConvertTo-ConditionNumber -Value $Value -Accessor 'int'

    # ConvertTo-ConditionNumber already returns [long] for a whole number; only a genuinely
    # fractional value still needs truncating here.
    if ($number -is [long]) { return $number }

    return [long] [System.Math]::Truncate($number)
}
