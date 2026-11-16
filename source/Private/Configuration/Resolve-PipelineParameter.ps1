<#
.SYNOPSIS
Resolves a named pipeline parameter to its value.

.DESCRIPTION
Looks a parameter name up in the module-scope $parameters hashtable, which Start-DscRunner
populates from the configuration's `parameters` section and its default values.

Presence is tested with a key lookup rather than by inspecting the value. A parameter
legitimately declared as an empty string is defined, and must resolve to '' rather than be
reported as missing - which is what the previous [String]::IsNullOrEmpty check did.

.PARAMETER Name
The parameter name, as written inside a `<params=Name>` token or passed to `parameters()`.

.EXAMPLE
Resolve-PipelineParameter -Name 'Environment'

.NOTES
Throws a terminating error naming the parameter when it is not defined. A silently $null
result is worse than a failure: it lands in a resource property and the run applies the
wrong configuration.
#>
function Resolve-PipelineParameter {
    [CmdletBinding()]
    [OutputType([System.Object[]], [System.Object])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    # Read $parameters through the scope chain, the same way `parameters('Name')` and the
    # string-expansion path do, so the table resolves whether this runs inside the built
    # module or dot-sourced into a test scope.
    $parameterTable = $parameters
    if ($null -eq $parameterTable) { $parameterTable = $Script:parameters }

    # IDictionary.Contains covers both the plain hashtable used by the module and the ordered
    # dictionary a JSON-loaded configuration can produce.
    if (($null -eq $parameterTable) -or -not ($parameterTable -is [System.Collections.IDictionary]) -or
        -not $parameterTable.Contains($Name)) {

        throw "[Resolve-PipelineParameter] Parameter '$Name' not found in the parameters hashtable."
    }

    $value = $parameterTable[$Name]

    # A list-valued parameter is returned as an object[] behind a unary comma. A plain
    # `return` unrolls it, which turned a one-entry list parameter into a scalar and an empty
    # one into $null.
    if (($value -is [System.Collections.IList]) -and ($value -isnot [System.Collections.IDictionary])) {
        return , @($value)
    }

    return $value
}
