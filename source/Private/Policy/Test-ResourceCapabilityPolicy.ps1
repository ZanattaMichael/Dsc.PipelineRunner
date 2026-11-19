<#
.SYNOPSIS
Checks one capability of one resource against the policy, at the point of use
(issue #86, Part B).

.DESCRIPTION
The pre-run check (Get-RunPolicyViolation) judges everything that can be known from the compiled
file before any resource runs. This is the second gate: the same question asked again with the
value the runner is really about to use, immediately before it is used. It is defence in depth for
values the pre-run check already saw, and it is the only gate for a value that was not knowable
then (a Target or a computerName written as an expression).

Which layers are asked:

  * normally, the layers the provenance record attributes to this resource;
  * with -FromExpression, those layers *plus* every layer that contributed anything to the node,
    because the expression's value could have come from any of them.

Nothing in the compiled file or in a layer's data can widen this: the layer list comes from the
provenance record the runner stamped from file paths, and a resource that is not in the record is
treated as '(unclaimed)', which has no capabilities.

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.PARAMETER Provenance
The provenance record read by Get-RunPolicyViolation.

.PARAMETER ResourceKey
The resource's 'Type/Name' key.

.PARAMETER Capability
The capability to check.

.PARAMETER Value
The name being used, for a list capability (the Target action, the computer name, the Credential
action, the resource type). Omitted for a switch capability.

.PARAMETER Subject
How the value is described in the violation message, e.g. "the Target" or "the computer".

.PARAMETER FromExpression
The value was written as an expression, so widen the layers to every contributor to the node.

.OUTPUTS
[string] The violation message, or $null when it is allowed.
#>
function Test-ResourceCapabilityPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance,

        [Parameter(Mandatory)]
        [string] $ResourceKey,

        [Parameter(Mandatory)]
        [ValidateSet('Targets', 'Engines', 'Resources', 'Credentials', 'RemoteTargets',
            'ExecutionScripts', 'DatumScriptBlocks', 'Notify', 'Reboot')]
        [string] $Capability,

        [string] $Value,

        [string] $Subject,

        [switch] $FromExpression
    )

    $resourceLayers = $Provenance['Resources']
    $layers = if ($null -ne $resourceLayers -and $resourceLayers.ContainsKey($ResourceKey)) { [string[]]@($resourceLayers[$ResourceKey]) } else { [string[]]@('(unclaimed)') }
    if ($FromExpression) {
        $layers = [string[]]@(@($layers) + @($Provenance['ContributingLayers']) | Where-Object { $_ } | Select-Object -Unique)
    }

    $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability $Capability -Value $Value
    if ($decision.Allowed) { return $null }

    # The message has to be enough to act on without reading the code: what was refused, for which
    # resource, which layers refused it, and where those layers are in the configuration.
    $what = if ([string]::IsNullOrWhiteSpace($Subject)) {
        if ([string]::IsNullOrWhiteSpace($Value)) { "the $Capability capability" } else { "$Capability '$Value'" }
    }
    elseif ([string]::IsNullOrWhiteSpace($Value)) { $Subject }
    else { "$Subject '$Value'" }

    $where = Get-PolicyLayerOrigin -Provenance $Provenance -Layer $decision.DeniedBy
    return "Capability policy: resource [$ResourceKey] uses $what, which is not allowed for layer(s) $($decision.DeniedBy -join ', ')$where."
}

<#
.SYNOPSIS
Describes where a denied layer is in the configuration, for a violation message (issue #86, Part B).

.DESCRIPTION
A violation that names only a layer leaves the reader hunting for the files that layer owns. The
provenance record already lists each of the node's precedence entries with the layer it mapped to,
so the message can name them. Returns an empty string when the record says nothing useful, so
callers can always append it.

.OUTPUTS
[string] ' (layer Teams owns Projects/Present/App)', or ''.
#>
function Get-PolicyLayerOrigin {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [System.Collections.IDictionary] $Provenance,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Layer = @()
    )

    if ($null -eq $Provenance -or @($Layer).Count -eq 0) { return '' }

    $entries = @($Provenance['Layers'])
    if ($entries.Count -eq 0) { return '' }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Layer | Where-Object { $_ } | Select-Object -Unique)) {
        $paths = @(
            foreach ($entry in $entries) {
                $entryLayer = if ($entry -is [System.Collections.IDictionary]) { [string]$entry['Layer'] } elseif ($null -ne $entry) { [string]$entry.Layer } else { $null }
                if ($entryLayer -eq $name) {
                    if ($entry -is [System.Collections.IDictionary]) { [string]$entry['Path'] } else { [string]$entry.Path }
                }
            }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        if ($paths.Count -gt 0) { $parts.Add("$name owns $($paths -join ', ')") }
    }

    if ($parts.Count -eq 0) { return '' }
    return " (in this node, layer $($parts -join '; '))"
}
