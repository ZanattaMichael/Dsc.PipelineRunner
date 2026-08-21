<#
.SYNOPSIS
Tests whether a resource type string is shaped like a DSC v3 resource type identifier.

.DESCRIPTION
DSC v3 (dsc.exe) addresses every resource by a fully-qualified type of the form
`<owner>[.<segment>...]/<name>` — for example `Microsoft.Windows/Registry`,
`Microsoft/OSInfo`, or `Microsoft.DSC.Debug/Echo`. The owner/namespace segment may contain
dots; the whole identifier contains exactly one forward slash separating a non-empty
namespace from a non-empty name.

This function performs the *structural* check only — it validates the shape, not that the
resource actually exists on the box. Existence can only be confirmed by `dsc resource list`,
so callers that need a true compliance guarantee pass the discovered type set separately
(see ConvertTo-DscV3ConfigurationDocument -AvailableResourceType).

A DSC v2 module/resource pair (e.g. `PSDscResources/Service`) is also `namespace/name`
shaped and therefore passes this structural test; only a live `dsc resource list` lookup can
tell the two apart. What this test *does* reject is the clearly non-compliant: a bare name
with no slash, empty segments, embedded whitespace, or more than one slash.

.PARAMETER Type
The resource type string to test.

.OUTPUTS
[bool] $true when the string is a structurally valid DSC v3 resource type identifier.
#>
function Test-DscV3ResourceType {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Type
    )

    if ([string]::IsNullOrWhiteSpace($Type)) {
        return $false
    }

    # Exactly one '/', a non-empty namespace and name on either side. Each dot-separated
    # segment must start with a letter and continue with word characters (letters, digits,
    # underscore). This matches every built-in DSC v3 type while rejecting bare names,
    # whitespace, empty segments and multi-slash strings.
    $segment = '[A-Za-z][A-Za-z0-9_]*'
    $namePart = '{0}(\.{0})*' -f $segment
    $pattern = '^{0}/{0}$' -f $namePart

    return [bool]([regex]::IsMatch($Type, $pattern))
}
