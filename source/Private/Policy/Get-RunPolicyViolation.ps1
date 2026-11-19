<#
.SYNOPSIS
Checks a compiled configuration file against the capability policy before any resource runs
(issue #86, Part B).

.DESCRIPTION
Reads the provenance record the compile step wrote beside the file (<node>.provenance.json) and
returns every violation, so a run that is not allowed stops before it starts and names all of its
problems in one pass:

  * the engine the run resolved to must be allowed for every layer that has a resource in the file;
  * each resource's type ('Module/Resource') must be allowed by the Resources capability;
  * each resource's Target action must be allowed for the layers that contributed to the resource;
  * a non-Local Target's target.computerName must be allowed by the RemoteTargets capability;
  * every Credential action the resource names (target.credential, resourceCredential) must be
    allowed by the Credentials capability;
  * a resource with preExecutionScript or postExecutionScript needs the ExecutionScripts capability;
  * a resource that declares 'notify' needs the Notify capability, because a notify makes another
    resource run Set() whether it had drifted or not.

A Target action written as an expression cannot be known yet. It is checked when the resource is
reached (Test-ResourceTargetPolicy), against every layer that contributed anything to the node,
because the expression's value may come from any of them.

Everything else here is checked on the literal text of the compiled file, which is what the runner
uses: the runner expands expressions in a resource's *properties* only, never in its 'target' block
or its credential blocks. An expression-looking computer name or Credential action is therefore
matched as the literal text it is, which no hostname or action pattern will allow.

Fails closed: no provenance record, an unreadable one, or one written under a different policy is
itself a violation.

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.PARAMETER FilePath
The compiled configuration file.

.PARAMETER Task
The file's resources, as the runner will run them.

.PARAMETER DefaultTargetAction
The file-level default Target action (PipelineRunnerSettings.Target, or 'Local').

.PARAMETER Engine
The engine this run resolved to.

.PARAMETER HasEngineAction
The run supplies an inline engine script block, which counts as an engine of its own.

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

    # One message shape for every per-resource violation: what was refused, which layers refused
    # it, who contributed to the resource, and where in this node those layers live. A reader
    # should not have to open the code (or the record) to know what to change.
    $deny = {
        param([string] $Key, [string[]] $Layers, [object] $Decision, [string] $What)
        $message = "Resource [$Key] $What, which is not allowed for layer(s) $($Decision.DeniedBy -join ', ')"
        $message += " (contributors to this resource: $($Layers -join ', '))"
        $message += (Get-PolicyLayerOrigin -Provenance $provenance -Layer $Decision.DeniedBy)
        $violations.Add($message + '.')
    }

    # Engine: one engine runs the whole file, so every layer with a resource in it must be allowed it.
    $layersWithResources = [string[]]@($resourceLayers.Values | ForEach-Object { $_ } | Select-Object -Unique)
    if ($layersWithResources.Count -gt 0) {
        $engineName = if ($HasEngineAction) { '(inline engine script block)' } else { $Engine }
        $decision = Test-PolicyCapability -Policy $Policy -Layer $layersWithResources -Capability 'Engines' -Value $engineName
        if (-not $decision.Allowed) {
            $violations.Add("The engine '$engineName' is not allowed for layer(s) $($decision.DeniedBy -join ', '), which have resources in this file$(Get-PolicyLayerOrigin -Provenance $provenance -Layer $decision.DeniedBy).")
        }
    }

    foreach ($resource in @($Task)) {
        if ($null -eq $resource -or $resource -is [string] -or $resource -is [ValueType]) { continue }
        $key = "$($resource.type)/$($resource.name)"
        $layers = & $layersOf $key

        # Resource type: what the resource may *be*, not only what it may use. A layer allowed to
        # declare 'PSDesiredStateConfiguration/Script' can run arbitrary code through the engine,
        # so this is the capability that decides how much the other ones are worth.
        $resourceType = [string]$resource.type
        $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Resources' -Value $resourceType
        if (-not $decision.Allowed) {
            & $deny $key $layers $decision "is of the resource type '$resourceType'"
        }

        # Target: a per-resource action, or the file's default.
        $action = $null
        if ($resource.target -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$resource.target.action)) { $action = [string]$resource.target.action }
        $effective = if ($null -ne $action) { $action } else { $DefaultTargetAction }
        if ($null -ne $action -and $action -match '\$\(|\$\{|\[x=') {
            $expressionTargets[$key] = $true
            $effective = $null              # not knowable yet; checked at the point of use
        }
        else {
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Targets' -Value $effective
            if (-not $decision.Allowed) {
                & $deny $key $layers $decision "uses the Target '$effective'"
            }
        }

        # RemoteTargets: which machine a non-Local Target may be aimed at. 'Targets' says which
        # mechanism may be used; this says where it may reach. A Target whose action is still an
        # expression is treated as remote, because it may turn out to be: the computer name is
        # checked either way, and the action itself is checked again at the point of use.
        if ($resource.target -is [System.Collections.IDictionary] -and ($null -eq $effective -or $effective -ne 'Local')) {
            $computerName = [string]$resource.target.computerName
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'RemoteTargets' -Value $computerName
            if (-not $decision.Allowed) {
                $described = if ([string]::IsNullOrWhiteSpace($computerName)) { 'a remote Target with no computerName' } else { "the remote Target computer '$computerName'" }
                & $deny $key $layers $decision "uses $described"
            }
        }

        # Credentials: every Credential action this resource would resolve. A layer with no
        # Credentials capability cannot use a credential at all - it can neither reach a remote
        # target that needs one nor have one injected into a resource property.
        foreach ($credentialUse in @(
                @{ Block = $resource.target.credential; Where = 'target.credential' }
                @{ Block = $resource.resourceCredential; Where = 'resourceCredential' }
            )) {
            if ($null -eq $credentialUse.Block) { continue }
            $credentialAction = if ($credentialUse.Block -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$credentialUse.Block.action)) { [string]$credentialUse.Block.action } else { 'Environment' }
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Credentials' -Value $credentialAction
            if (-not $decision.Allowed) {
                & $deny $key $layers $decision "resolves a credential through the '$credentialAction' Credential action ($($credentialUse.Where))"
            }
        }

        if ($null -ne $resource.preExecutionScript -or $null -ne $resource.postExecutionScript) {
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'ExecutionScripts'
            if (-not $decision.Allowed) {
                & $deny $key $layers $decision 'has an execution script'
            }
        }

        # Notify: a notify is not ordering, it is a command. A notified resource runs Set() even
        # though its own Test() said it was in the desired state, so a layer that may notify can
        # make another layer's resource apply itself. dependsOn is deliberately not governed: it
        # only orders resources that were going to run anyway.
        $notifyTargets = @($resource.notify | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        if ($notifyTargets.Count -gt 0) {
            $decision = Test-PolicyCapability -Policy $Policy -Layer $layers -Capability 'Notify'
            if (-not $decision.Allowed) {
                & $deny $key $layers $decision "notifies $($notifyTargets.Count) resource(s) ($($notifyTargets -join ', ')), forcing them to re-run Set()"
            }
        }
    }

    return [pscustomobject]@{ Violations = [string[]]$violations.ToArray(); Provenance = $provenance; ExpressionTargets = $expressionTargets }
}

<#
.SYNOPSIS
Checks one resource's resolved Target action against the capability policy, at the point of use
(issue #86, Part B).

.DESCRIPTION
Defence in depth for the check Get-RunPolicyViolation made before the run, and the only check for
a Target action that was written as an expression. For such a resource the layers are widened to
every layer that contributed anything to the node, since any of them may have supplied the value.
See Test-ResourceCapabilityPolicy, which this wraps.

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

    return Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $Provenance -ResourceKey $ResourceKey `
        -Capability 'Targets' -Value $TargetAction -Subject 'the Target' -FromExpression:$FromExpression
}
