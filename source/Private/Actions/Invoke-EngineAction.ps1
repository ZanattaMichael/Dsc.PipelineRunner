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

        [scriptblock]$EngineAction
    )

    $context = @{
        Method     = $Method
        ModuleName = $ModuleName
        Name       = $Name
        Property   = $Property
    }

    $raw = Invoke-Action -Hook Engine -Name $Engine -ScriptBlock $EngineAction -Context $context

    return (ConvertTo-DscMethodResult -InputObject $raw -Method $Method)
}
