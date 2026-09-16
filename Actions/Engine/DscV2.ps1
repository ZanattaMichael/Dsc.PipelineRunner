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

# Remote-target execution (#57 §4): the Target action resolves a session once per
# file/resource and threads it through Invoke-EngineAction's Session context. Local
# (the default; $Context.Session is $null) is unaffected and keeps the original call shape.
#
# A remote evaluation used to be "just add -CimSession", on the strength of Windows
# PowerShell 5.1's in-box Invoke-DscResource, which takes one. PSDesiredStateConfiguration
# 2.x - the module PowerShell 7 uses, and this module requires PowerShell 7.0 - DROPPED that
# parameter, and it does not degrade gracefully: the call fails with "A parameter cannot be
# found that matches parameter name 'CimSession'" before the resource is ever reached. So
# every remote DSC v2 evaluation threw on the only PowerShell version this module supports.
# WinRMTarget.Integration.tests.ps1, against a live WinRM listener on the self-hosted runner,
# is what surfaced it; the mocked unit suite could not, because its mock DEFINED -CimSession.
#
# The PSSession is therefore the preferred remote path: the evaluation is carried to the far
# side and Invoke-DscResource runs LOCALLY there, which is the one arrangement both PowerShell
# versions support. It is also how the DSC v3 engine reaches a remote target
# (Actions/Engine/DscV3.ps1), so the two engines now remote the same way.
#
# -CimSession remains as a fallback for a target that resolves a CimSession and no PSSession,
# and it is probed for rather than assumed, so a host without it gets a diagnosable error
# naming the missing piece instead of a parameter-binding failure.
$remoteCimSession = $null
$remotePSSession  = $null

if ($null -ne $Context.Session) {
    $remoteCimSession = $Context.Session.CimSession
    $remotePSSession  = $Context.Session.PSSession
}

Write-Verbose "[Actions/Engine/DscV2] Invoke-DscResource '$($Context.Method)' for [$($Context.ModuleName)/$($Context.Name)]."

if ($null -ne $remotePSSession) {
    # The parameter hashtable and the result cross the session boundary as serialized objects,
    # which is why the result is read through member access below rather than by type - a
    # deserialized result is a PSObject, never the original type.
    Write-Verbose "[Actions/Engine/DscV2] Using remote PSSession for [$($Context.ModuleName)/$($Context.Name)]."

    $raw = Invoke-Command -Session $remotePSSession -ArgumentList $resourceParameters -ErrorAction Stop -ScriptBlock {
        param([hashtable]$Parameters)

        Import-Module -Name PSDesiredStateConfiguration -ErrorAction SilentlyContinue

        Invoke-DscResource @Parameters
    }
}
elseif ($null -ne $remoteCimSession) {
    $invokeDscResource = Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue

    if ($null -eq $invokeDscResource -or -not $invokeDscResource.Parameters.ContainsKey('CimSession')) {
        throw "[Actions/Engine/DscV2] A remote target was resolved for [$($Context.ModuleName)/$($Context.Name)] with a CimSession but no PSSession, and this host's Invoke-DscResource has no -CimSession parameter (PSDesiredStateConfiguration 2.x, which PowerShell 7 uses, removed it). Use a target action that also opens a PSSession, or select the DscV3 engine."
    }

    $resourceParameters.CimSession = $remoteCimSession
    Write-Verbose "[Actions/Engine/DscV2] Using remote CimSession for [$($Context.ModuleName)/$($Context.Name)]."

    $raw = Invoke-DscResource @resourceParameters
}
else {
    $raw = Invoke-DscResource @resourceParameters
}

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
