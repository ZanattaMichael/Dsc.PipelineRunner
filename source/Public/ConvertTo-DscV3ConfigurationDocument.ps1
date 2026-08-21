<#
.SYNOPSIS
Converts compiled pipeline resources into a DSC v3 configuration document that `dsc.exe` can consume.

.DESCRIPTION
The runner's compiled Datum output is a *runner-specific* shape: a list of resources with
`type`, `name` and `properties`, alongside pipeline-only keys such as `condition`,
`postExecutionScript`, `dependsOn`, `parameters`, `conditions` and `variables`. That shape is
consumed one resource at a time by Start-DscRunner; it is **not** a DSC v3 configuration
document and cannot be handed to `dsc config get|test|set` as-is.

ConvertTo-DscV3ConfigurationDocument produces a schema-valid DSC v3 configuration document
from those resources:

  - emits the document `$schema` so `dsc.exe` validates the payload,
  - keeps only the DSC v3 resource keys (`name`, `type`, `properties`) and drops every
    pipeline-only key, since DSC v3 has no notion of them,
  - validates that every resource has a non-empty `name`, a non-empty `type`, and that the
    `type` is structurally a DSC v3 identifier (`namespace/name`); when the caller supplies
    the set of types reported by `dsc resource list`, it additionally rejects any `type` that
    does not actually exist on the box,
  - aggregates every problem and throws a single, itemized error so an operator can fix all
    non-compliant resources in one pass rather than fix-and-rerun.

Resource **ordering** is intentionally the runner's responsibility (Sort-DependsOn), so
`dependsOn` is not carried into the document — pass resources already in the order you want
them evaluated. Likewise, `properties` are emitted verbatim: expand any runner variables
(Expand-HashTable) before conversion if you want a fully-resolved document.

.PARAMETER Resource
The compiled resources to convert. Each may be a [hashtable] (as produced by ConvertFrom-Yaml
/ ConvertFrom-Json -AsHashtable) or a [pscustomobject], and must expose `type` and `name`;
`properties` defaults to an empty object when absent.

.PARAMETER AvailableResourceType
Optional set of resource types known to the target `dsc.exe` (e.g. the `type` values from
`dsc resource list`). When supplied, a resource whose `type` is not in this set is reported as
non-compliant — turning the structural check into a true existence check.

.PARAMETER SchemaUri
The `$schema` value to stamp on the document. Defaults to the DSC v3 configuration-document
schema. Override only to target a specific pinned schema version.

.OUTPUTS
[System.Collections.Specialized.OrderedDictionary] The DSC v3 configuration document, ready to
serialize to YAML or JSON (ConvertTo-Yaml / ConvertTo-Json) and pass to `dsc config`.

.EXAMPLE
$doc = ConvertTo-DscV3ConfigurationDocument -Resource $pipeline.resources
$doc | ConvertTo-Json -Depth 32 | Set-Content ./config.dsc.json -Encoding utf8
dsc config get --file ./config.dsc.json

.EXAMPLE
$types = (dsc resource list --output-format json | ConvertFrom-Json).type
$doc = ConvertTo-DscV3ConfigurationDocument -Resource $compiled.resources -AvailableResourceType $types
#>
function ConvertTo-DscV3ConfigurationDocument {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Resource,

        [Parameter()]
        [string[]]$AvailableResourceType,

        [Parameter()]
        [string]$SchemaUri = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
    )

    # Reads a key/property from either a hashtable or a pscustomobject (both are case-insensitive).
    $getMember = {
        param($InputObject, $Name)
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
            return $null
        }
        $prop = $InputObject.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $documentResources = [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $index = 0

    foreach ($item in $Resource) {
        $index++

        $type = [string](& $getMember $item 'type')
        $name = [string](& $getMember $item 'name')

        $label = if (-not [string]::IsNullOrWhiteSpace($name)) { "'$name'" } else { "#$index" }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $errors.Add("Resource $label is missing a non-empty 'name'.")
        }

        if ([string]::IsNullOrWhiteSpace($type)) {
            $errors.Add("Resource $label is missing a non-empty 'type'.")
        }
        elseif (-not (Test-DscV3ResourceType -Type $type)) {
            $errors.Add("Resource $label has type '$type', which is not a DSC v3 resource identifier. DSC v3 types are 'namespace/name' (for example 'Microsoft.Windows/Registry').")
        }
        elseif ($PSBoundParameters.ContainsKey('AvailableResourceType') -and $AvailableResourceType.Count -gt 0 -and ($AvailableResourceType -notcontains $type)) {
            $errors.Add("Resource $label has type '$type', which is not available to dsc.exe on this host (not present in 'dsc resource list').")
        }

        $properties = & $getMember $item 'properties'
        if ($null -eq $properties) { $properties = @{} }

        # Only the DSC v3 resource keys survive; pipeline-only keys are intentionally dropped.
        $documentResources.Add([ordered]@{
            name       = $name
            type       = $type
            properties = $properties
        })
    }

    if ($errors.Count -gt 0) {
        $detail = ($errors | ForEach-Object { "  - $_" }) -join [System.Environment]::NewLine
        throw "[ConvertTo-DscV3ConfigurationDocument] $($errors.Count) resource(s) are not DSC v3 compliant:$([System.Environment]::NewLine)$detail"
    }

    return [ordered]@{
        '$schema'  = $SchemaUri
        resources  = $documentResources.ToArray()
    }
}
