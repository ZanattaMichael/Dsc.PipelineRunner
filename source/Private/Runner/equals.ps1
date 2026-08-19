<#
.SYNOPSIS
    Compares two strings for equality.

.PARAMETER Left
    The first string to compare.

.PARAMETER Right
    The second string to compare.

.RETURNS
    [bool] True if the strings are equal; otherwise, False.

.EXAMPLE
    $result = equals -Left "Hello" -Right "Hello"
    if ($result) {
        Write-Output "Strings are equal"
    } else {
        Write-Output "Strings are not equal"
    }

.NOTES
    This function uses the [System.String]::Equals method to perform the comparison.
#>

function invoke-equals {
    [Alias('equals')]
    [CmdletBinding()]
    param ([string] $Left, [string] $Right)

    return [System.String]::Equals($Left, $Right)
}
