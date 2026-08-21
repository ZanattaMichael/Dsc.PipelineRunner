<#
.SYNOPSIS
Resolves and invokes a loader-driven lifecycle action.

.DESCRIPTION
Invoke-Action generalizes the pattern the module already uses for rules
(Invoke-CustomTask / Invoke-PreParseRules): it dispatches a named lifecycle hook
to a script file that lives under the module's `Actions/<Hook>/<Name>.ps1`, passing
a single `-Context` hashtable, and returns whatever the action returns.

Three hooks are supported:

- Source  — resolve a configuration source to a local directory (Local, Git, ...)
- Connect — establish an auth/session before evaluation (None, AzureDevOps, ...)
- Engine  — drive resource Test/Set/Get (DscV2, DscV3, ...)

A caller may instead pass an inline [scriptblock] via -ScriptBlock, which takes
precedence over -Name and requires no file on disk — this is the "bring your own
custom solution" escape hatch described in the decoupling plan.

.PARAMETER Hook
The lifecycle hook to run. One of 'Source', 'Connect', 'Engine'.

.PARAMETER Name
The action name — the base filename (without .ps1) under Actions/<Hook>/.
Ignored when -ScriptBlock is supplied.

.PARAMETER ScriptBlock
An inline action. Receives the $Context hashtable as its single argument. Takes
precedence over -Name.

.PARAMETER Context
A hashtable passed to the action as -Context (files) or as the first argument
(scriptblocks). Defaults to an empty hashtable.

.EXAMPLE
$dir = Invoke-Action -Hook Source -Name Git -Context @{ Url = $repoUrl }

.EXAMPLE
Invoke-Action -Hook Connect -ScriptBlock { param($Context) Connect-MyPlatform -Token $Context.Token }
#>
function Invoke-Action {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Connect', 'Engine')]
        [string]$Hook,

        [string]$Name,

        [scriptblock]$ScriptBlock,

        [hashtable]$Context = @{}
    )

    # An inline scriptblock override needs no file on disk and wins over a name.
    if ($ScriptBlock) {
        Write-Verbose "[Invoke-Action] Running inline '$Hook' action."
        return (& $ScriptBlock $Context)
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "[Invoke-Action] No action name or -ScriptBlock supplied for hook '$Hook'."
    }

    # Resolve Actions/<Hook>/<Name>.ps1 relative to the installed module, mirroring
    # how Invoke-PreParseRules / Invoke-CustomTask locate the Pipeline Rules.
    $moduleBase = (Get-Module 'Dsc.PipelineRunner').ModuleBase
    $actionPath = Join-Path -Path $moduleBase -ChildPath (Join-Path 'Actions' (Join-Path $Hook ("{0}.ps1" -f $Name)))

    if (-not (Test-Path -LiteralPath $actionPath)) {
        throw "[Invoke-Action] Action '$Name' for hook '$Hook' was not found at: $actionPath"
    }

    Write-Verbose "[Invoke-Action] Running '$Hook' action '$Name' from: $actionPath"
    return (& $actionPath -Context $Context)
}
