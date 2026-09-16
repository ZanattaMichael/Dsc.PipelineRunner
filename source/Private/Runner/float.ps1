<#
.SYNOPSIS
Converts a value to a real number.

.DESCRIPTION
`float` turns a string or whole number into a [double]. Its main use is forcing real division:
`div` performs whole-number division when both operands are whole, so `div (float 7) 2` is 3.5
where `div 7 2` is 3.

A non-numeric value throws rather than becoming 0.

.PARAMETER Value
The value to convert.

.EXAMPLE
PS> float (variables 'ThresholdPercent')
Returns the configured threshold as a real number, even when YAML supplied it as a string.

.EXAMPLE
PS> (div (float (variables 'UsedBytes')) (variables 'TotalBytes')) -lt 0.9
A condition that needs the ratio rather than its truncated whole part.
#>
function invoke-float {
    [CmdletBinding()]
    [Alias('float')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value
    )

    return [double] (ConvertTo-ConditionNumber -Value $Value -Accessor 'float')
}
