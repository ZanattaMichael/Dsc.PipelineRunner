<#
.SYNOPSIS
Orders pipeline resources into dependency order using a topological sort.

.DESCRIPTION
Sort-DependsOn returns the supplied pipeline resources ordered so that every resource
appears after all of the resources named in its DependsOn property. It implements Kahn's
algorithm (a proper topological sort), which is O(V + E), resolves transitive and diamond
dependencies correctly, and detects problems the previous heuristic silently mis-ordered:

  * a circular DependsOn chain throws a terminating error naming the resources in the cycle,
  * a self-referential DependsOn throws (a resource cannot depend on itself), and
  * a DependsOn that points at a resource which is not present in the configuration throws.

A resource's identity is its "Type/Name" pair, and a DependsOn entry is that same
"Type/Name" string, so references are matched directly without re-parsing.

.PARAMETER PipelineResources
An array of pipeline resources to order. Each resource is expected to have a Type, a Name,
and optionally a DependsOn property (a string or an array of "Type/Name" strings).

.OUTPUTS
The resources, emitted in a valid dependency order (resources with no dependencies first).

.EXAMPLE
$resources = @(
    [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task1'; DependsOn = @() },
    [PSCustomObject]@{ Type = 'Module/Resource'; Name = 'Task2'; DependsOn = @('Module/Resource/Task1') }
)
.\Sort-DependsOn.ps1 -PipelineResources $resources
#>
[CmdletBinding()]
[OutputType([System.Collections.Generic.List[object]])]
param(
    [Object[]]$PipelineResources
)

# Nothing to order.
if ($null -eq $PipelineResources -or $PipelineResources.Count -eq 0) {
    Write-Verbose "[Sort-DependsOn] No resources supplied; returning an empty ordering."
    return
}

# The identity of a resource is "Type/Name"; a DependsOn entry is the same string, so a
# reference can be matched directly against a resource key with no re-parsing.
function Get-ResourceKey {
    param($Resource)
    return ('{0}/{1}' -f $Resource.Type, $Resource.Name)
}

Write-Verbose "[Sort-DependsOn] Building the dependency graph for $($PipelineResources.Count) resource(s)."

# Node table (key -> resource), in-degree map (key -> unresolved dependency count) and
# adjacency list (key -> the resources that depend on it). Ordinal, case-sensitive keys so
# resource identity matches how DSC treats Type/Name.
$nodes      = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$inDegree   = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
$dependents = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)

# Preserve the input order so independent resources keep a stable, predictable ordering.
$order = [System.Collections.Generic.List[string]]::new()

foreach ($resource in $PipelineResources) {
    $key = Get-ResourceKey -Resource $resource
    if (-not $nodes.ContainsKey($key)) {
        $nodes[$key]      = $resource
        $inDegree[$key]   = 0
        $dependents[$key] = [System.Collections.Generic.List[string]]::new()
        $order.Add($key)
    }
    else {
        Write-Verbose "[Sort-DependsOn] Duplicate resource key '$key'; keeping the first occurrence."
    }
}

# Wire up the edges. For a resource N that DependsOn D, D must be applied before N, so the
# edge runs D -> N and N's in-degree is incremented for each dependency it carries.
foreach ($resource in $PipelineResources) {
    $key = Get-ResourceKey -Resource $resource

    foreach ($dependency in $resource.DependsOn) {
        if ([string]::IsNullOrWhiteSpace($dependency)) { continue }
        $dependencyKey = $dependency.Trim()

        if ($dependencyKey -eq $key) {
            throw "[Sort-DependsOn] Resource [$key] cannot depend on itself."
        }
        if (-not $nodes.ContainsKey($dependencyKey)) {
            throw "[Sort-DependsOn] Resource [$key] depends on [$dependencyKey], which is not present in the configuration."
        }

        $dependents[$dependencyKey].Add($key)
        $inDegree[$key] = $inDegree[$key] + 1
    }
}

# Seed the queue with every resource that has no outstanding dependencies, in input order.
$queue  = [System.Collections.Generic.Queue[string]]::new()
foreach ($key in $order) {
    if ($inDegree[$key] -eq 0) { $queue.Enqueue($key) }
}

# Drain the queue: emit a node, then relax each dependent's in-degree, enqueuing any that
# become free. The result is a valid topological order.
$sorted = [System.Collections.Generic.List[object]]::new()
while ($queue.Count -gt 0) {
    $key = $queue.Dequeue()
    $sorted.Add($nodes[$key])

    foreach ($dependentKey in $dependents[$key]) {
        $inDegree[$dependentKey] = $inDegree[$dependentKey] - 1
        if ($inDegree[$dependentKey] -eq 0) { $queue.Enqueue($dependentKey) }
    }
}

# If not every resource was emitted, the unemitted ones sit on (or feed into) a cycle.
if ($sorted.Count -ne $nodes.Count) {
    $cycleMembers = $order | Where-Object { $inDegree[$_] -gt 0 }
    throw "[Sort-DependsOn] Circular dependency detected among resources: $($cycleMembers -join ', ')."
}

Write-Verbose "[Sort-DependsOn] Ordered $($sorted.Count) resource(s)."

# Emit the ordered resources onto the pipeline (matching the historical unrolled output).
return $sorted
