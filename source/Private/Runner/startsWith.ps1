<#
.SYNOPSIS
Reports whether a string begins with a given prefix.

.DESCRIPTION
`startsWith` is a prefix test over two strings. It is case-INSENSITIVE by default, matching the
ARM template language's startsWith() and the fact that the values it is normally applied to -
resource names, environment names, paths - are not meaningfully case-distinct. Pass
-CaseSensitive for an ordinal comparison.

A $null value is treated as an empty string, so the only prefix an unset variable starts with
is the empty one. An empty prefix is always $true, which is what [String]::StartsWith does and
what makes `startsWith (variables 'Name') (variables 'OptionalPrefix')` degrade to "no filter"
rather than "matches nothing".

.PARAMETER Value
The string being tested.

.PARAMETER Prefix
The prefix to look for.

.PARAMETER CaseSensitive
Compare ordinally rather than case-insensitively.

.EXAMPLE
PS> startsWith (variables 'ProjectName') 'Internal-'
Returns $true for 'Internal-Billing' and for 'internal-billing'.

.EXAMPLE
PS> not (startsWith (variables 'ComputerName') 'TEST')
A condition that keeps a resource off the test fleet.
#>
function invoke-startswith {
    [CmdletBinding()]
    [Alias('startsWith')]
    param (
        [Parameter(Mandatory, Position = 0)] [AllowNull()] [object] $Value,
        [Parameter(Mandatory, Position = 1)] [AllowNull()] [object] $Prefix,

        [switch] $CaseSensitive
    )

    $text   = if ($null -eq $Value)  { '' } else { [string] $Value }
    $needle = if ($null -eq $Prefix) { '' } else { [string] $Prefix }

    $comparison = if ($CaseSensitive) { [System.StringComparison]::Ordinal }
                  else                { [System.StringComparison]::OrdinalIgnoreCase }

    return $text.StartsWith($needle, $comparison)
}
