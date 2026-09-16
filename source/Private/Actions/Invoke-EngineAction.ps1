<#
.SYNOPSIS
Runs a resource method (Test/Set/Get) through the selected execution engine and returns
a normalized [DscMethodResult].

.DESCRIPTION
Invoke-EngineAction is the single seam the runner loop uses to evaluate a resource. It
builds the engine context, dispatches to Actions/Engine/<Engine>.ps1 (or an inline
-EngineAction scriptblock) via the shared Invoke-Action loader, and normalizes whatever
the engine returns into the typed [DscMethodResult] contract. The loop therefore never
depends on whether the resource ran through Invoke-DscResource (DSC v2), dsc.exe
(DSC v3), or a bespoke engine.

.PARAMETER Method
The DSC method to run: 'Test', 'Set', or 'Get'.

.PARAMETER ModuleName
The resource's owning module (the part before '/' in a task type).

.PARAMETER Name
The resource name (the part after '/' in a task type).

.PARAMETER Property
The desired-state property hashtable for the resource.

.PARAMETER Engine
The engine action name (a file under Actions/Engine/). Default: 'DscV2'.

.PARAMETER EngineAction
An inline engine scriptblock. Takes precedence over -Engine.

.PARAMETER Session
Optional remote-target session context (#57 §4), resolved once per file/resource by the
Target action (Actions/Target/<Name>.ps1) and threaded through unchanged. Shape is
engine-specific: DscV2.ps1 reads .PSSession (Invoke-DscResource is run on the far side) and
falls back to .CimSession only where the host's Invoke-DscResource still takes one;
DscV3.ps1 reads .PSSession (used to wrap the dsc.exe call in Invoke-Command -Session).
$null (the default) means "run against the local machine", today's behavior.

.OUTPUTS
[DscMethodResult]
#>
function Invoke-EngineAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Test', 'Set', 'Get')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$ModuleName,

        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$Property = @{},

        [string]$Engine = 'DscV2',

        [scriptblock]$EngineAction,

        [AllowNull()]
        [object]$Session = $null
    )

    $context = @{
        Method     = $Method
        ModuleName = $ModuleName
        Name       = $Name
        Property   = $Property
        Session    = $Session
    }

    $raw = Invoke-Action -Hook Engine -Name $Engine -ScriptBlock $EngineAction -Context $context

    return (ConvertTo-DscMethodResult -InputObject $raw -Method $Method)
}
