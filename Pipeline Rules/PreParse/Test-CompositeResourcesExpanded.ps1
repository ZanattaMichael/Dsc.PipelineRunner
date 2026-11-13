<#
.SYNOPSIS
Fails the run when a composite resource instance reaches the runner unexpanded.

.DESCRIPTION
A composite resource (`type: Composite/<Name>`) is a compile-time construct: Resolve-DscDatumProject
replaces every instance with the member resources of its definition (Composites/<Name>.yml)
before the per-node file is written, so a compiled configuration never contains one. No engine
can evaluate a 'Composite' type - DSC v2's Invoke-DscResource does not support composite
resources, and dsc.exe has no such resource either.

An instance can still arrive here when a configuration file was written by hand, produced by
another tool, or compiled by an older runner that did not expand composites. Without this rule
the failure would surface resource by resource, as an engine error about a module named
'Composite' that does not exist. This rule collects every instance and fails the run once,
before any resource is evaluated, naming each one and saying what to do - following the same
collect-all-then-throw-once pattern as Test-ResourcesForIncorrectProperties.ps1.

It is named so that it sorts ahead of Test-ResourcesForIncorrectProperties.ps1 (PreParse rules
run in alphabetical order), which would otherwise report the same resources as an unknown DSC
resource first.

.PARAMETER PipelineResources
An array of pipeline resources to be tested.

.EXAMPLE
Test-CompositeResourcesExpanded -PipelineResources $resources
#>
param(
    [Object[]]$PipelineResources
)

$offenders = [System.Collections.Generic.List[string]]::new()
foreach ($task in $PipelineResources) {
    if ($null -eq $task) { continue }
    if ([string]$task.type -match '^Composite/') {
        $offenders.Add("[$($task.type)/$($task.name)]")
    }
}

if ($offenders.Count -gt 0) {
    throw "[Test-CompositeResourcesExpanded] $($offenders.Count) composite resource instance(s) reached the runner unexpanded: $($offenders -join ', '). Composite resources are expanded when the configuration is compiled (Build-DatumConfiguration / Invoke-DscPipelineRunner) from its Composites/<Name>.yml definitions; run the configuration through the compiler instead of supplying this file directly."
}

Write-Verbose "[Test-CompositeResourcesExpanded] No unexpanded composite resource instances found."
