<#
.SYNOPSIS
Works out which policy layers contributed to each resource of a node
(issue #86, Part B; preview).

.DESCRIPTION
Datum merges the layers of a node into one result and does not say where each part came from. The
runner finds out by asking Datum for each layer on its own: Resolve-Datum is called once per entry
of the resolution precedence, restricted to that entry (-PathPrefixes), and a layer is a
contributor to a resource when its own result contains a resource of that name.

The stamp is therefore written by the runner from the layer files' paths. Nothing a contributor
writes inside a file can change it.

Composite members (resources that only exist after composite expansion) are named
'<instance>::<member>'. A member is attributed to the layers that declared its instance and, in
this preview, to every layer that owns a composite definition (the expansion does not yet record
which definition a member came from). That can only narrow what a member may do. A member whose
instance cannot be identified falls back to every layer that instantiated a composite in the node.

.PARAMETER Datum
The Datum structure.

.PARAMETER Node
The node variable used for the merge (Project, ProjectPresence and the node file's own keys).

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.PARAMETER MergedResource
The node's merged resources, before composite expansion.

.PARAMETER ExpandedResource
The node's resources after composite expansion: what will run.

.OUTPUTS
[System.Collections.Specialized.OrderedDictionary] The provenance record written beside the
compiled file as <node>.provenance.json.
#>
function Get-ResourceProvenance {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param (
        [Parameter(Mandatory)]
        [object] $Datum,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Node,

        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $MergedResource = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $ExpandedResource = @()
    )

    $nameOf = {
        param($resource)
        if ($resource -is [System.Collections.IDictionary]) { foreach ($key in $resource.Keys) { if ([string]$key -ieq 'name') { return [string]$resource[$key] } } }
        elseif ($null -ne $resource -and $resource.PSObject.Properties['name']) { return [string]$resource.name }
        return $null
    }
    $typeOf = {
        param($resource)
        if ($resource -is [System.Collections.IDictionary]) { foreach ($key in $resource.Keys) { if ([string]$key -ieq 'type') { return [string]$resource[$key] } } }
        elseif ($null -ne $resource -and $resource.PSObject.Properties['type']) { return [string]$resource.type }
        return $null
    }

    $layerEntries = [System.Collections.Generic.List[object]]::new()
    $byResource = @{}                                   # resource name -> layers that declared or changed it
    $contributing = [System.Collections.Generic.List[string]]::new()   # layers that contributed anything to this node

    foreach ($prefix in @($Datum.__Definition.ResolutionPrecedence)) {
        # The same expansion Datum performs: $Node is the only variable a precedence entry uses.
        $expanded = $ExecutionContext.InvokeCommand.ExpandString([string]$prefix)
        $layer = Get-PolicyLayer -Policy $Policy -RelativePath $expanded
        $layerEntries.Add([ordered]@{ Path = ($expanded -replace '\\', '/'); Layer = $layer })

        $contributed = $false
        foreach ($property in 'resources', 'variables', 'parameters', 'conditions') {
            $value = $null
            try { $value = Resolve-Datum -PropertyPath $property -DatumStructure $Datum -Variable $Node -PathPrefixes @([string]$prefix) -WarningAction SilentlyContinue }
            catch { $value = $null }
            if ($null -eq $value) { continue }
            $contributed = $true

            if ($property -eq 'resources') {
                foreach ($resource in @($value)) {
                    $name = & $nameOf $resource
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    if (-not $byResource.ContainsKey($name)) { $byResource[$name] = [System.Collections.Generic.List[string]]::new() }
                    if ($layer -notin $byResource[$name]) { $byResource[$name].Add($layer) }
                }
            }
        }
        if ($contributed -and $layer -notin $contributing) { $contributing.Add($layer) }
    }

    # Composites: who instantiated one in this node, and who owns the definitions.
    $compositeLayers = [System.Collections.Generic.List[string]]::new()     # instance layers + definition layers
    $definitionLayers = [System.Collections.Generic.List[string]]::new()
    $instanceLayers = @{}                                                    # instance name -> its layers
    $mergedNames = @{}
    foreach ($resource in @($MergedResource)) {
        $name = & $nameOf $resource
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $type = & $typeOf $resource
        $mergedNames[$name] = $type
        if ($type -match '^Composite/') {
            $instanceLayers[$name] = @($byResource[$name] | Where-Object { $_ })
            foreach ($layer in $instanceLayers[$name]) { if ($layer -notin $compositeLayers) { $compositeLayers.Add($layer) } }
        }
    }
    if ($compositeLayers.Count -gt 0) {
        $store = $null
        if ($Datum -is [System.Collections.IDictionary]) { if ($Datum.Contains('Composites')) { $store = $Datum['Composites'] } }
        elseif ($Datum.PSObject.Properties['Composites']) { $store = $Datum.Composites }
        $definitionNames = if ($store -is [System.Collections.IDictionary]) { @($store.Keys) } elseif ($null -ne $store) { @($store.PSObject.Properties.Name) } else { @() }
        foreach ($definitionName in $definitionNames) {
            $layer = Get-PolicyLayer -Policy $Policy -RelativePath "Composites/$definitionName"
            if ($layer -notin $definitionLayers) { $definitionLayers.Add($layer) }
            if ($layer -notin $compositeLayers) { $compositeLayers.Add($layer) }
        }
    }

    $resources = [ordered]@{}
    foreach ($resource in @($ExpandedResource)) {
        $name = & $nameOf $resource
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $type = & $typeOf $resource

        $layers = if ($mergedNames.ContainsKey($name) -and $mergedNames[$name] -notmatch '^Composite/' -and $byResource.ContainsKey($name)) {
            @($byResource[$name])
        }
        elseif ($compositeLayers.Count -gt 0) {
            # A composite member, named '<instance>::<member>' (nested: '<outer>::<inner>::<member>').
            $instanceName = if ($name -match '^(.+?)::') { $Matches[1] } else { $null }
            if ($null -ne $instanceName -and $instanceLayers.ContainsKey($instanceName) -and $instanceLayers[$instanceName].Count -gt 0) {
                @(@($instanceLayers[$instanceName]) + @($definitionLayers) | Select-Object -Unique)
            }
            else {
                @($compositeLayers)
            }
        }
        else {
            @('(unclaimed)')          # cannot be attributed: no capabilities
        }
        $resources["$type/$name"] = [string[]]$layers
    }

    return [ordered]@{
        SchemaVersion      = '1.0'
        PolicySha256       = [string]$Policy.Sha256
        SettingsLayer      = Get-PolicyLayer -Policy $Policy -RelativePath 'Datum.yml'
        Layers             = $layerEntries.ToArray()
        ContributingLayers = [string[]]$contributing.ToArray()
        Resources          = $resources
    }
}
