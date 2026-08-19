<#
.SYNOPSIS
    Negates a boolean statement.

.DESCRIPTION
    The 'not' function takes a boolean input and returns the negation of that input.
    If the input is $true, it returns $false. If the input is $false, it returns $true.

.PARAMETER Statement
    The boolean statement to be negated.

.RETURNS
    [Boolean] The negated value of the input statement.

.EXAMPLE
    PS C:\> not -Statement $true
    False

.EXAMPLE
    PS C:\> not -Statement $false
    True
#>

function invoke-not {
    [CmdletBinding()]
    [Alias('not')]
    param ([Boolean] $Statement)

    return $Statement -ne $true
}
