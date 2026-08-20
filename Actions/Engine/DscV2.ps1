<#
.SYNOPSIS
Engine action: evaluate a resource through Invoke-DscResource (DSC v2 — default).

.DESCRIPTION
The default execution engine. It reproduces the runner's original behavior exactly —
a single Invoke-DscResource call per method — but returns the normalized engine
contract shape so the loop stays engine-agnostic. This is the Windows / PowerShell-DSC
path and remains the default when no engine is selected.

.PARAMETER Context
A hashtable with keys: Method ('Test'|'Set'|'Get'), ModuleName, Name, Property.

.OUTPUTS
An object exposing InDesiredState, RebootRequired, Message and Raw (normalized by the
runner into a [DscMethodResult]).
#>
param(
    [hashtable]$Context = @{}
)

$resourceParameters = @{
    Name       = $Context.Name
    ModuleName = $Context.ModuleName
    Method     = $Context.Method
    Property   = $Context.Property
}

Write-Verbose "[Actions/Engine/DscV2] Invoke-DscResource '$($Context.Method)' for [$($Context.ModuleName)/$($Context.Name)]."
$raw = Invoke-DscResource @resourceParameters

# Invoke-DscResource returns different shapes per method:
#   Test -> object with .InDesiredState
#   Set  -> object with .RebootRequired
#   Get  -> the current-state object (no state flags)
# Direct member access returns $null for an absent property on both a [hashtable]
# and a [pscustomobject], so it reads every shape without inspecting the type.
$inDesiredState = $true
if ($null -ne $raw) {
    $stateValue = $raw.InDesiredState
    if ($null -ne $stateValue) { $inDesiredState = [bool]$stateValue }
}

$rebootRequired = $false
if ($null -ne $raw) {
    $rebootValue = $raw.RebootRequired
    if ($null -ne $rebootValue) { $rebootRequired = [bool]$rebootValue }
}

$message = $null
if ($null -ne $raw) { $message = $raw.Message }

return [pscustomobject]@{
    InDesiredState = $inDesiredState
    RebootRequired = $rebootRequired
    Message        = $message
    Raw            = $raw
}
