<#
.SYNOPSIS
Rebuilds a parsed configuration tree using case-insensitive hashtables.

.DESCRIPTION
On PowerShell 7.3+ `ConvertFrom-Json -AsHashtable` returns a case-SENSITIVE
[System.Management.Automation.OrderedHashtable], so a lookup such as $resource.Type
or $task.Condition returns $null whenever the JSON key was written in a different
case (e.g. "type" / "condition"). The runner and the pipeline rules access resource
members with mixed casing (Sort-DependsOn reads $Resource.Type / $Resource.Name /
$Resource.DependsOn, Start-DscRunner reads $task.Condition), so the case-sensitive
map silently collapses every resource to the same empty key and drops all but the
first, and never evaluates a condition.

The YAML loader (ConvertFrom-Yaml) already returns case-insensitive [hashtable]
values, so JSON and YAML configurations are meant to behave identically once loaded.
ConvertTo-CaseInsensitiveHashtable restores that invariant for the JSON path by
deep-copying the parsed structure into default PowerShell hashtables (which compare
string keys case-insensitively), preserving array order for the resource list.

.PARAMETER InputObject
The value to normalize. Dictionaries are rebuilt as case-insensitive hashtables,
enumerable values (except strings) are rebuilt element by element, and scalars are
returned unchanged.

.OUTPUTS
A structure mirroring the input with every dictionary replaced by a case-insensitive
[hashtable].
#>
function ConvertTo-CaseInsensitiveHashtable {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable], [System.Object[]], [System.Object])]
    param(
        [Parameter(Position = 0)]
        $InputObject
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        # @{} is case-insensitive for string keys; copy every entry across, recursing
        # so nested objects (a resource's properties, for example) are normalized too.
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-CaseInsensitiveHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    # Strings are IEnumerable; treat them (and any non-collection scalar) as a leaf.
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        # Wrap in @() so an array is always returned, keeping the resource list's order
        # and its count stable even for a single-element collection.
        return @(foreach ($item in $InputObject) { ConvertTo-CaseInsensitiveHashtable -InputObject $item })
    }

    return $InputObject
}
