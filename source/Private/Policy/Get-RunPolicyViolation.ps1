<#
.SYNOPSIS
Checks a compiled configuration file against the capability policy before any resource runs
(issue #86, Part B; preview).

.DESCRIPTION
Reads the provenance record the compile step wrote beside the file (<node>.provenance.json) and
returns every violation, so a run that is not allowed stops before it starts and names all of its
problems in one pass:

  * the engine the run resolved to must be allowed for every layer that has a resource in the file;
  * each resource's Target action must be allowed for the layers that contributed to the resource;
  * a resource with preExecutionScript or postExecutionScript needs the ExecutionScripts capability.

A Target action written as an expression cannot be known yet. It is checked when the resource is
reached (Test-ResourceTargetPolicy), against every layer that contributed anything to the node,
because the expression's value may come from any of them.

Fails closed: no provenance record, an unreadable one, or one written under a different policy is
itself a violation.

.OUTPUTS
[pscustomobject] Violations ([string[]]), Provenance (the record, or $null) and ExpressionTargets
(the resource keys whose Target action is an expression).
#>
function Get-RunPolicyViolation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Task = @(),

        [Parameter(Mandatory)]
        [string] $DefaultTargetAction,

        [Parameter(Mandatory)]
        [string] $Engine,

        [switch] $HasEngineAction
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    $expressionTargets = @{}

    $recordPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($FilePath), ([System.IO.Path]::GetFileNameWithoutExtension($FilePath) + '.provenance.json'))
    $provenance = $null
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        $violations.Add("There is no provenance record for '$([System.IO.Path]::GetFileName($FilePath))'. A policy can only be enforced on a file compiled with the same policy (Invoke-DscRunner -PolicyPath, or Build-DatumConfiguration -PolicyPath).")
    }
    else {
        try { $provenance = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable }
        catch { $violations.Add("The provenance record '$([System.IO.Path]::GetFileName($recordPath))' cannot be read: $($_.Exception.Message)") }
        if ($null -ne $provenance -and [string]$provenance['PolicySha256'] -ne [string]$Policy.Sha256) {
            $violations.Add("The provenance record '$([System.IO.Path]::GetFileName($recordPath))' was written under a different policy than the one supplied for this run. Compile and run with the same policy file.")
            $provenance = $null
        }
    }
    if ($null -eq $provenance) {
        return [pscustomobject]@{ Violations = [string[]]$violations.ToArray(); Provenance = $null; ExpressionTargets = $expressionTargets }
    }

    $resourceLayers = $provenance['Resources']
    if ($null -eq $resourceLayers) { $resourceLayers = @{} }
    $layersOf = {
        param([string] $Key)
        if ($resourceLayers.ContainsKey($Key)) { return [string[]]@($resourceLayers[$Key]) }
        return [string[]]@('(unclaimed)')     # in the compiled file but not in the record: no capabilities
    }

    # Engine: one engine runs the whole file, so every layer with a resource in it must be allowed it.
    $layersWithResources = [string[]]@($resourceLayers.Values | ForEach-Object { $_ } | Select-Object -Unique)
    if ($layersWithResources.Count -gt 0) {
        $engineName = if ($HasEngineAction) { '(inline engine script block)' } else { $Engine }
        $decision = Test-PolicyCapability -Policy $Policy -Layer $layersWithResources -Capability 'Engines' -Value $engineName
        if (-not $decision.Allowed) {
            $violations.Add("The engine '$engineName' is not allowed for layer(s) $($decision.DeniedBy -join ', '), which have resources in this file.")
        }
    }

    foreach ($resource in @($Task)) {
        if ($null -eq $resource -or $resource -is [string] -or $resource -is [ValueType]) { continue }
        $key = "$($resource.type)/$($resource.name)"
        $layers = & $layersOf $key

        # Target: a per-resource action, or the file's default.
        $action = $null
        if ($resource.target -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$resource.target.action)) { $action = [string]$resource.target.action }
        if ($null -ne $action -and $action -match '\$\(|\$\{|\[x=') {
            $expressionTargets[$key] = $true
        }
        else {
            $effective = if ($null -ne $action) { $action } else { $DefaultTargetAction }
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Targets' -Value $effective
            if (-not $decision.Allowed) {
                $violations.Add("Resource [$key] uses the Target '$effective', which is not allowed for layer(s) $($decision.DeniedBy -join ', ') (contributors to this resource: $($layers -join ', ')).")
            }
        }

        if ($null -ne $resource.preExecutionScript -or $null -ne $resource.postExecutionScript) {
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'ExecutionScripts'
            if (-not $decision.Allowed) {
                $violations.Add("Resource [$key] has an execution script, which is not allowed for layer(s) $($decision.DeniedBy -join ', ') (contributors to this resource: $($layers -join ', ')).")
            }
        }
    }

    return [pscustomobject]@{ Violations = [string[]]$violations.ToArray(); Provenance = $provenance; ExpressionTargets = $expressionTargets }
}

<#
.SYNOPSIS
Checks one resource's resolved Target action against the capability policy, at the point of use
(issue #86, Part B; preview).

.DESCRIPTION
Defence in depth for the check Get-RunPolicyViolation made before the run, and the only check for
a Target action that was written as an expression. For such a resource the layers are widened to
every layer that contributed anything to the node, since any of them may have supplied the value.

.OUTPUTS
[string] The violation message, or $null when the Target is allowed.
#>
function Test-ResourceTargetPolicy {
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
        [string] $TargetAction,

        [switch] $FromExpression
    )

    $resourceLayers = $Provenance['Resources']
    $layers = if ($null -ne $resourceLayers -and $resourceLayers.ContainsKey($ResourceKey)) { [string[]]@($resourceLayers[$ResourceKey]) } else { [string[]]@('(unclaimed)') }
    if ($FromExpression) {
        $layers = [string[]]@(@($layers) + @($Provenance['ContributingLayers']) | Where-Object { $_ } | Select-Object -Unique)
    }

    $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Targets' -Value $TargetAction
    if ($decision.Allowed) { return $null }
    return "Capability policy: resource [$ResourceKey] uses the Target '$TargetAction', which is not allowed for layer(s) $($decision.DeniedBy -join ', ')."
}
