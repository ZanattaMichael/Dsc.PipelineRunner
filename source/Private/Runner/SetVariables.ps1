
<#
.SYNOPSIS
    Sets variables from a source hashtable to a target hashtable and creates corresponding environment variables.

.DESCRIPTION
    The SetVariables function takes two hashtable parameters: $Source and $Target. It iterates through each key in the $Source hashtable, adds the key-value pair to the $Target hashtable, and creates a new variable in the script scope with the key name (dots replaced by underscores). Additionally, it creates an environment variable with the same name.

.PARAMETER Source
    The source hashtable containing the variables to be set.

.PARAMETER Target
    The target hashtable where the variables from the source hashtable will be added.

.EXAMPLE
    $source = @{ "key1" = "value1"; "key2" = "value2" }
    $target = @{}
    SetVariables -Source $source -Target $target

    This example sets the variables from the $source hashtable to the $target hashtable and creates corresponding script scope and environment variables.
#>
function Set-Variables {
    [CmdletBinding()]
    [Alias('SetVariables')]
    param (
        [hashtable] $Source,
        [hashtable] $Target
    )

    foreach ($key in $Source.Keys) {
        $Target.Add($key, $Source[$key])

        $varName = $key.Replace(".", "_")
        New-Variable -Name $varName -Value $Source[$key] -Scope Script -Force | Out-Null
        New-Item -Path env:varName -Value $Source[$key] -ErrorAction SilentlyContinue
    }
}