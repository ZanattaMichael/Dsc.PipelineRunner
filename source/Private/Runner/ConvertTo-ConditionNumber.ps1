<#
.SYNOPSIS
Converts a function-language argument into the numeric type the arithmetic accessors operate on.

.DESCRIPTION
The arithmetic accessors (`add`, `sub`, `mul`, `div`, `mod`, `min`, `max`) are reachable from a
configuration file, where every value has already passed through YAML/JSON parsing and, more
often, through string interpolation - so an operand that is conceptually a number routinely
arrives as the string '7'. Converting per-accessor would mean seven copies of the same coercion
and seven different failure messages, so the coercion lives here.

The conversion deliberately preserves the operand's own integrality: an integer, or a string
that parses as one, comes back as [long]; a real value, or a string with a decimal point, comes
back as [double]. That is what makes `add 1 2` return 3 rather than 3.0, and what lets `div`
decide between whole-number and real division without a separate type hint.

A [double] is NOT collapsed to [long] even when its value is whole, which is what makes `float`
meaningful: `div (float 7) 2` has to be 3.5, and it can only be if `float 7` stays a double all
the way into `div`.

A value that is not a number at all is a terminating error rather than a silent 0 - the same
reasoning as parameters(): a mistyped operand must stop the resource, not quietly apply the
wrong configuration.

This is an internal helper, not a function-language accessor: it is called from inside the
arithmetic accessors' bodies and is not on the condition allow-list, so a configuration cannot
name it.

.PARAMETER Value
The raw operand, typically a string, an integer or a double.

.PARAMETER Accessor
The name of the calling accessor, used only to prefix the error message.

.EXAMPLE
ConvertTo-ConditionNumber -Value '7' -Accessor 'add'
Returns [long] 7.

.EXAMPLE
ConvertTo-ConditionNumber -Value 2.5 -Accessor 'mul'
Returns [double] 2.5.

.EXAMPLE
ConvertTo-ConditionNumber -Value 7.0 -Accessor 'div'
Returns [double] 7.0 - a real operand stays real even when its value is whole.
#>
function ConvertTo-ConditionNumber {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Accessor
    )

    if ($null -eq $Value) {
        throw "[$Accessor] Expected a number but received `$null."
    }

    # An already-numeric operand keeps its own integrality; only a string needs parsing, and
    # it is parsed with the invariant culture so a configuration behaves the same on a machine
    # whose locale uses ',' as the decimal separator.
    if ($Value -is [bool]) {
        throw "[$Accessor] Expected a number but received a boolean [$Value]."
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long]) {
        return [long] $Value
    }

    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [double] $Value
    }

    $text = [string] $Value
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    $parsedLong = [long] 0
    if ([long]::TryParse($text, [System.Globalization.NumberStyles]::Integer, $culture, [ref] $parsedLong)) {
        return $parsedLong
    }

    $parsedDouble = [double] 0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $culture, [ref] $parsedDouble)) {
        return $parsedDouble
    }

    throw "[$Accessor] Expected a number but received [$text], which is not numeric."
}
