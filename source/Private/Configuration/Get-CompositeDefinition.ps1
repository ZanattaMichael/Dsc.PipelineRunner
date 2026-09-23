<#
.SYNOPSIS
Collects the composite resource definitions from the Datum 'Composites' store.

.DESCRIPTION
A composite resource is a named, parameterised group of ordinary resources, defined once in
a file under the configuration's Composites/ folder (Composites/<Name>.yml) and instantiated
from any layer of the hierarchy with `type: Composite/<Name>`. Expand-CompositeResource turns
each instance into its member resources at compile time; this function supplies it with the
definitions.

New-DatumStructure creates one store per root folder of the configuration, so a Composites/
folder is reachable as $Datum.Composites without any Datum.yml change. It is deliberately NOT
listed in ResolutionPrecedence: a definition is a template, not configuration for a node, so it
must never be merged into a node's resources by the hierarchy.

The store is read the way Datum exposes it - a FileProvider whose files are ScriptProperty
members returning an ordered dictionary - and a plain IDictionary (which is what the unit
tests pass) is accepted as well. A member whose value is not a dictionary (a sub-folder,
which Datum exposes as a nested FileProvider, or a file that did not parse to a mapping) is
skipped with a warning rather than failing the compile, because only <Name>.yml files at the
root of Composites/ are definitions.

.PARAMETER Datum
The Datum structure returned by New-DatumStructure (or any object exposing a 'Composites'
member). $null, or a structure with no Composites store, yields an empty table.

.OUTPUTS
[hashtable] A case-insensitive table of composite name -> definition dictionary. The
definitions are the store's own objects (Datum caches them per file); Expand-CompositeResource
deep-copies anything it changes.

.EXAMPLE
$definitions = Get-CompositeDefinition -Datum $Datum
#>
function Get-CompositeDefinition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter()]
        [AllowNull()]
        [Object] $Datum
    )

    # A plain @{} is already case-insensitive, matching how a `Composite/<Name>` type is matched.
    $definitions = @{}

    if ($null -eq $Datum) {
        return $definitions
    }

    $store = $null
    if ($Datum -is [System.Collections.IDictionary]) {
        if ($Datum.Contains('Composites')) { $store = $Datum['Composites'] }
    }
    elseif ($Datum.PSObject.Properties['Composites']) {
        $store = $Datum.Composites
    }

    if ($null -eq $store) {
        Write-Verbose "[Get-CompositeDefinition] No Composites store found; no composite resources are defined."
        return $definitions
    }

    # Enumerate the store as name/value pairs. A Datum FileProvider carries hidden class
    # properties (Path, Store, ...) alongside the per-file ScriptProperty members; only the
    # latter (and NoteProperty, for a hand-built object) are definitions.
    $entries = if ($store -is [System.Collections.IDictionary]) {
        foreach ($key in @($store.Keys)) {
            [pscustomobject]@{ Name = [string]$key; Value = $store[$key] }
        }
    }
    else {
        foreach ($property in $store.PSObject.Properties) {
            if ($property.MemberType -notin 'ScriptProperty', 'NoteProperty') { continue }
            [pscustomobject]@{ Name = $property.Name; Value = $property.Value }
        }
    }

    foreach ($entry in $entries) {
        if ($entry.Value -isnot [System.Collections.IDictionary]) {
            Write-Warning "[Get-CompositeDefinition] Composites/$($entry.Name) is not a composite definition (expected a <Name>.yml file containing a mapping); it is ignored."
            continue
        }

        Write-Verbose "[Get-CompositeDefinition] Found composite definition '$($entry.Name)'."
        $definitions[$entry.Name] = $entry.Value
    }

    return $definitions
}
