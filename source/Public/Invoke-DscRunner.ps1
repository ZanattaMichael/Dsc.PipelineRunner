<#
.SYNOPSIS
Provider-agnostic entry point for the DSC pipeline runner.

.DESCRIPTION
Invoke-DscRunner drives the runner without any hard dependency on Azure DevOps. It
composes three loader-driven lifecycle actions (see Invoke-Action):

  1. Source  — resolve the configuration to a local directory (Local, Git, or a
               custom drop-in / inline scriptblock).
  2. Connect — establish any auth/session before evaluation (None by default,
               AzureDevOps, or a custom drop-in / inline scriptblock).
  3. Compile Datum and run Start-DscRunner over each compiled configuration file.

Every seam is selectable by name (a file under Actions/<Hook>/) or overridden with an
inline [scriptblock], so third parties can plug in bespoke sources and auth providers
without forking the module.

A caller that already has the compiled documents — it builds its per-node configuration
somewhere else — can skip steps 1 and 3 with -ConfigurationFile or -ConfigurationDirectory
(issue #106). The documents are run exactly as a compiled one is: the same pre-parse Pipeline
Rules, the same per-resource loop, conditions, dependsOn/notify ordering, lifecycle scripts,
reference()/using(), report and exit code. Three things differ, and all three are properties
of not having a hierarchy rather than of the runner:

  * The node name is the document's file name, without its extension — the same rule the
    compiled path uses, since the compile names each file after its node. -NodeName overrides
    it for a single document.
  * PipelineRunnerSettings come from -RunnerSettings. There is no Datum.yml to read them
    from, and they are deliberately not read out of the document itself.
  * The capability policy does not apply: it decides what a resource may do from the layer its
    file sits in, and a passthrough document has no layers. That has to be declared, not
    inferred, so -BypassDatumPolicy is REQUIRED for a passthrough run - and it is refused
    outright, switch or no switch, when the documents have a governed configuration behind them.

A passthrough document is code in exactly the same sense a compiled one is — see
docs/trust-model.md. It must come from somewhere reviewed.

.PARAMETER Source
Name of the Source action (a file under Actions/Source/). Default: 'Local'.

.PARAMETER SourceAction
Inline Source action scriptblock. Takes precedence over -Source.

.PARAMETER SourceContext
Hashtable passed to the Source action (for example @{ Url = ... } for Git or
@{ Path = ... } for Local). If -ConfigurationSourcePath is supplied it is merged in
as the 'Path' (and, for Git, 'Url') key.

.PARAMETER ConfigurationSourcePath
Convenience: a local directory or git URL. Populates the Source context.

.PARAMETER ConfigurationRevision
Convenience: the branch, tag, or commit to pin a remote configuration to. Populates the
Source context's 'Revision' key, which the Git source action passes to Clone-Repository.
Supplying a full 40-character commit SHA makes the pin exact - the clone's HEAD is verified
against it. Ignored by source actions that do not clone.

.PARAMETER ConfigurationFile
One or more configuration documents to run as they are, skipping the Datum compile (#106).
Each must be a .yml, .yaml or .json document of the shape the compile produces: flat, with
composites already expanded and no PipelineRunnerSettings block. They are run in the order
given, and each document's file name (without its extension) is its node name. Mutually
exclusive with the Source parameters and with -ConfigurationDirectory.

.PARAMETER ConfigurationDirectory
A directory of configuration documents to run as they are, skipping the Datum compile (#106).
Every .yml, .yaml and .json file directly in it is run, in name order; the directory is not
searched recursively, and the sidecar files the runner itself writes (<node>.report.json,
<node>.state.json, <node>.rsop.json, <node>.provenance.json) are skipped so a directory that
has also been used as a -ReportPath does not feed last run's report back in. Mutually
exclusive with the Source parameters and with -ConfigurationFile.

.PARAMETER RunnerSettings
Passthrough runs only. The PipelineRunnerSettings a compiled run would have taken from
Datum.yml: Engine, DSCResourceVersion, AllowExecutionScripts, Reboot, Target and Report.
Every key is optional and the runner's defaults apply when it is omitted, so a passthrough
run with no settings behaves exactly as a compiled run whose configuration declared none.

The settings are not read from the document. A compiled document has no PipelineRunnerSettings
block by design, and whether a configuration may run unconstrained lifecycle scripts
(AllowExecutionScripts) is a decision for whoever starts the run — a document that could grant
it to itself would not be a decision at all.

.PARAMETER NodeName
Passthrough runs only, and only for a single document. The node name, when the document's file
is not named after its node. It is the NodeName on every result row, what nodeName() returns,
and what the report files are named after (<node>.csv, <node>.report.json), so it is validated
as a file name by the same rule the compile applies to a Datum node name.

Omit it and the node name is the document's file name without its extension - the same rule the
compiled path uses. It cannot be combined with -ConfigurationDirectory, or with several
-ConfigurationFile paths, because a node name belongs to one node: name those files after their
nodes instead.

.PARAMETER BypassDatumPolicy
Passthrough runs only, and required for them. Declares that this run steps outside the capability
policy mechanism. A policy says what each LAYER of a configuration may use and a layer is decided
by where a file sits in the Datum hierarchy, so a passthrough document cannot be held to one.
Rather than let that be inferred from the absence of layers - which would make choosing
passthrough a quiet way out of the policy - the caller declares it, and the run records it: a
warning naming the bypass, and PolicyBypassed on every node's result and report document.

It grants no exception. When a Datum definition file and a policy sit together above the
documents, the configuration is governed and the run is refused with or without this switch; run
it through the Datum path instead, where the policy applies. The switch declares that there is no
policy to step outside of, not permission to step outside one that exists.

It is refused on the Datum path, where every resource has a layer and the policy applies.

.PARAMETER Connect
Name of the Connect action (a file under Actions/Connect/). Default: 'None'.

.PARAMETER ConnectAction
Inline Connect action scriptblock. Takes precedence over -Connect.

.PARAMETER ConnectContext
Hashtable passed to the Connect action.

.PARAMETER CacheDirectory
Directory Datum compiles into. When omitted, the generic PIPELINERUNNER_CACHE_DIRECTORY
environment variable is used (with AZDODSC_CACHE_DIRECTORY honoured as a back-compat
alias); failing that, a new temporary directory is created. Replaces the old
AZDODSC_CACHE_DIRECTORY hard requirement. A passthrough run compiles nothing, so it neither
needs nor accepts one.

.PARAMETER Mode
'Test' (default) evaluates each resource and reports drift. 'Set' also applies changes.
'DryRun' validates the configuration and works out what would run without calling an engine,
connecting to a target, resolving a credential or running the Connect action; it returns (and,
with -ReportPath, writes to <node>.rsop.json) the resultant configuration for each node.

.PARAMETER ReportPath
Optional directory to write the per-configuration CSV report into.

.PARAMETER Engine
Name of the execution engine action (a file under Actions/Engine/). 'DscV2' (default)
wraps Invoke-DscResource; 'DscV3' drives dsc.exe. 'Auto' opts in to detection, choosing
DscV3 when the dsc executable is present (or the version hint asks for it) and DscV2
otherwise. When -Engine is not passed explicitly, the configuration's
PipelineRunnerSettings drive selection: an 'Engine' key names the engine, otherwise the
back-compat 'DSCResourceVersion' major version maps (2.x -> DscV2, 3.x -> DscV3). For a
passthrough run those settings are the ones given in -RunnerSettings.

.PARAMETER EngineVersion
Optional resource version hint used to bias 'Auto' engine selection by major version
(major >= 3 selects DscV3, major 2 selects DscV2). Ignored unless -Engine is 'Auto'.

.PARAMETER EngineAction
Inline engine scriptblock. Takes precedence over -Engine.

.PARAMETER ReportAction
Inline reporter scriptblock. After each compiled file it receives a context hashtable whose
Document key holds that file's report document (schema version, counts, and one entry per
resource), in addition to any reporters named in PipelineRunnerSettings.Report.Reporters. A
reporter that throws is reported as an error and does not change the run's result.

.PARAMETER KeepTemporaryDirectory
Leave any temporary directory the runner created (a clone, or a fallback cache directory)
on disk after the run instead of deleting it. Useful when debugging a compile failure.
Directories supplied by the caller are never deleted, with or without this switch.

.PARAMETER PolicyPath
Preview. A capability policy file that says what each layer of the configuration may use (Target
actions, engines, execution scripts, Datum script blocks). A layer is decided by a file's path in
the configuration. Normally this is not needed: the policy is the file Policy.yml at the root of
the configuration, beside Datum.yml, and is used when it is there. -PolicyPath names a different
file, which then wins. A configuration file that breaks the policy does not start, and every
violation is named. See docs/capability-policy.md.

A passthrough configuration (-ConfigurationFile / -ConfigurationDirectory) has no layers for a
policy to be decided over, so supplying this with one is an error rather than a policy that
quietly enforces nothing. Such a run declares the step outside the policy with
-BypassDatumPolicy instead.

.PARAMETER RequirePolicy
Preview. Fail when there is no capability policy: no Policy.yml in the configuration and no
-PolicyPath. Refused for a passthrough configuration, for the reason given under -PolicyPath.
A pipeline that sets this is saying every run must be governed, which a passthrough run cannot
be - so the two are deliberately incompatible.

.EXAMPLE
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Test
Runs against a local directory with no authentication (Source: Local, Connect: None).

.EXAMPLE
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repo; Token = $pat } `
                 -Connect AzureDevOps -ConnectContext @{ OrganizationName = 'MyOrg'; AuthenticationType = 'PAT'; PATToken = $pat }

.EXAMPLE
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -ConnectAction {
    param($Context) Connect-MyPlatform -Token $Context.Token
}

.EXAMPLE
Invoke-DscRunner -ConfigurationFile 'C:\out\SRV-APP-01.yml' -BypassDatumPolicy -Mode Test
Runs one document the caller already has, with no Datum compile. The node is 'SRV-APP-01'.
-BypassDatumPolicy is required: it declares that this run steps outside the capability policy.

.EXAMPLE
Invoke-DscRunner -ConfigurationFile 'C:\tmp\rendered.yml' -NodeName 'SRV-APP-01' -BypassDatumPolicy -Mode Test
Runs a document whose file is not named after its node - the run, its results and its report
are all for 'SRV-APP-01'.

.EXAMPLE
Invoke-DscRunner -ConfigurationDirectory 'C:\out' -BypassDatumPolicy -RunnerSettings @{ Engine = 'DscV3'; Reboot = 'Ignore' } -Mode Set
Runs every document in a directory, with the settings a compiled run would have read from
Datum.yml's PipelineRunnerSettings block.
#>
function Invoke-DscRunner {
    [CmdletBinding(DefaultParameterSetName = 'Datum')]
    param(
        [Parameter(ParameterSetName = 'Datum')]
        [string]$Source = 'Local',
        [Parameter(ParameterSetName = 'Datum')]
        [scriptblock]$SourceAction,
        [Parameter(ParameterSetName = 'Datum')]
        [hashtable]$SourceContext = @{},

        [Parameter(ParameterSetName = 'Datum')]
        [string]$ConfigurationSourcePath,
        [Parameter(ParameterSetName = 'Datum')]
        [string]$ConfigurationRevision,

        # Passthrough (#106): documents the caller compiled themselves. Validation lives in
        # Resolve-PassthroughConfiguration so every bad path is named in one message rather
        # than a ValidateScript failing on the first one without saying which parameter it was.
        [Parameter(Mandatory, ParameterSetName = 'PassthroughFile')]
        [string[]]$ConfigurationFile,

        [Parameter(Mandatory, ParameterSetName = 'PassthroughDirectory')]
        [string]$ConfigurationDirectory,

        # The PipelineRunnerSettings a compiled run reads from Datum.yml. Passthrough only:
        # the Datum path's settings come from the hierarchy and are not overridable here.
        [Parameter(ParameterSetName = 'PassthroughFile')]
        [Parameter(ParameterSetName = 'PassthroughDirectory')]
        [hashtable]$RunnerSettings = @{},

        # The node name for a single passthrough document, when its file is not named after its
        # node. Declared in both passthrough sets so supplying it with -ConfigurationDirectory is
        # answered with the reason it cannot work there, rather than a parameter-set error.
        [Parameter(ParameterSetName = 'PassthroughFile')]
        [Parameter(ParameterSetName = 'PassthroughDirectory')]
        [string]$NodeName,

        [string]$Connect = 'None',
        [scriptblock]$ConnectAction,
        [hashtable]$ConnectContext = @{},

        [Parameter(ParameterSetName = 'Datum')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$CacheDirectory,

        [ValidateSet('Test', 'Set', 'DryRun')]
        [string]$Mode = 'Test',

        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [string]$ReportPath,

        [string]$Engine = 'DscV2',
        [string]$EngineVersion,
        [scriptblock]$EngineAction,

        [scriptblock]$ReportAction,

        [switch]$FailOnError,

        [switch]$KeepTemporaryDirectory,

        # Preview (issue #86, Part B): a capability policy says what each layer of the
        # configuration may use (Targets, Engines, execution scripts, Datum script blocks). By
        # default it is the file Policy.yml at the root of the configuration, beside Datum.yml;
        # -PolicyPath names another file, which then wins. See docs/capability-policy.md.
        # Declared in every parameter set so that supplying it with a passthrough configuration
        # is answered with the reason it cannot apply, rather than with PowerShell's
        # "parameter set cannot be resolved".
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$PolicyPath,

        # Preview: fail when there is no capability policy (no Policy.yml in the configuration and
        # no -PolicyPath), for a pipeline that must never run an unconstrained configuration.
        [switch]$RequirePolicy,

        # Passthrough only (#106). Declares that this run steps outside the capability policy
        # mechanism, which a passthrough document cannot be held to because it has no layers.
        # Required for a passthrough run, so that choosing passthrough is never a quiet way out of
        # the policy. It grants no exception: a document with a governed configuration behind it is
        # refused with or without it. Declared in every parameter set so that supplying it on the
        # Datum path is answered with the reason it cannot apply there, rather than with
        # PowerShell's "parameter set cannot be resolved" - it must never look like a way to turn
        # enforcement off for a configuration that does have a policy.
        [switch]$BypassDatumPolicy
    )

    $ErrorActionPreference = 'Stop'

    # Passthrough (#106): the caller supplies the documents, so there is no source to resolve
    # and nothing to compile. Everything from the Connect action onwards is the path a compiled
    # run takes, unchanged.
    $isPassthrough = $PSCmdlet.ParameterSetName -in 'PassthroughFile', 'PassthroughDirectory'

    # -BypassDatumPolicy is meaningless on the Datum path and must never be a way to switch
    # enforcement off for a configuration that has a policy: there, a layer IS known for every
    # resource, so the policy applies and is the thing being asked about. Refused before the
    # source is resolved, so it cannot have any effect at all.
    if ($BypassDatumPolicy -and -not $isPassthrough) {
        throw "[Invoke-DscRunner] -BypassDatumPolicy applies only to a passthrough configuration (-ConfigurationFile / -ConfigurationDirectory). A configuration compiled from a Datum hierarchy has a layer for every resource, so its capability policy applies and cannot be bypassed; remove -BypassDatumPolicy, or remove the policy from the configuration if it should not be enforced."
    }

    # Fold the convenience path into the Source context under the keys the built-in
    # Source actions understand (Local reads Path; Git reads Url, falling back to Path).
    if (-not [string]::IsNullOrWhiteSpace($ConfigurationSourcePath)) {
        if (-not $SourceContext.ContainsKey('Path')) { $SourceContext['Path'] = $ConfigurationSourcePath }
        if (-not $SourceContext.ContainsKey('Url'))  { $SourceContext['Url']  = $ConfigurationSourcePath }
    }

    # Revision pinning (#31): the Git source action reads 'Revision' and hands it to
    # Clone-Repository, which checks it out and verifies a full SHA against the clone's HEAD.
    if (-not [string]::IsNullOrWhiteSpace($ConfigurationRevision)) {
        if (-not $SourceContext.ContainsKey('Revision')) { $SourceContext['Revision'] = $ConfigurationRevision }
    }

    # Everything from the source resolve onwards runs inside a try/finally so that any
    # directory the runner created for this run (a clone, or the fallback cache directory)
    # is removed even when the run throws (#32). Caller-owned directories are never touched:
    # Remove-RunnerTemporaryDirectory only deletes paths New-TemporaryDirectory registered.
    # A passthrough run creates neither, so both stay $null and the cleanup is a no-op.
    #
    # The source directory is held in $sourceDirectory and NOT in $configurationDirectory:
    # PowerShell variable names are case-insensitive, so the latter would be the very same
    # variable as the -ConfigurationDirectory parameter, and assigning $null here would
    # silently discard a passthrough caller's path.
    $sourceDirectory = $null
    $resolvedCacheDirectory = $null

    try {

        # The configuration documents Start-DscRunner is called for: one per node, compiled
        # into the cache directory below, or supplied by the caller for a passthrough run.
        $documentPaths = @()
        $settings = $null

        if ($isPassthrough) {

            #
            # 1p. The documents the caller supplied, validated and in run order.
            $documentPaths = @(Resolve-PassthroughConfiguration -ConfigurationFile $ConfigurationFile -ConfigurationDirectory $ConfigurationDirectory)
            Write-Verbose "[Invoke-DscRunner] Passthrough: $($documentPaths.Count) configuration document(s), no Datum compile."

            #
            # 1q. -NodeName names ONE document's node. The node name is per node: it is the
            # NodeName on every result row, what nodeName() returns, and what the report files
            # are named after. There is no sound way to spread one value over several documents,
            # and silently applying it to the first (or to all, colliding their reports) would be
            # worse than refusing.
            if ($PSBoundParameters.ContainsKey('NodeName')) {
                if ($PSCmdlet.ParameterSetName -eq 'PassthroughDirectory') {
                    throw "[Invoke-DscRunner] -NodeName names one document's node, so it cannot be used with -ConfigurationDirectory: each document in a directory is its own node. Name the files after their nodes, or run the one document with -ConfigurationFile and -NodeName."
                }
                if ($documentPaths.Count -gt 1) {
                    throw "[Invoke-DscRunner] -NodeName names one document's node, but $($documentPaths.Count) documents were supplied. Pass a single -ConfigurationFile with -NodeName, or name each file after its node."
                }
            }

            #
            # 2p. PipelineRunnerSettings. There is no Datum.yml to read them from, and a
            # compiled document carries no PipelineRunnerSettings block by design, so they come
            # from -RunnerSettings or not at all. Not read from the document: see the parameter's
            # help for why AllowExecutionScripts in particular must not be self-granted.
            if ($RunnerSettings -and $RunnerSettings.Count -gt 0) { $settings = $RunnerSettings }

            #
            # 3p. Capability policy (preview, #86 Part B). The policy decides what a resource may
            # do from the LAYER its file sits in, and a passthrough document has no layers, so
            # there is nothing to decide one from. That makes choosing passthrough a way to step
            # outside the policy mechanism, so the step has to be declared by the caller and
            # visible afterwards - never inferred from the absence of layers. Three rules, in
            # this order:
            #
            #   1. A governed configuration behind the documents refuses the run, with or without
            #      -BypassDatumPolicy. The switch is not an escalation path.
            #   2. No policy behind them and no switch: refused, naming the switch.
            #   3. No policy behind them and the switch given: runs, says so loudly once, and
            #      records the bypass on every node's result and report document.
            $policyContext = Resolve-PassthroughPolicyContext -ConfigurationFile $documentPaths

            # Rule 1. A Datum definition file with a policy beside it means the caller has a
            # governed configuration in front of them, and its resources have layers - so they
            # belong on the Datum path, where the policy applies. Checked before -PolicyPath and
            # before the switch, because neither makes any difference to it.
            if ($policyContext.GovernedRoot) {
                throw "[Invoke-DscRunner] This passthrough run is refused: the configuration behind these documents is governed by a capability policy. '$($policyContext.GovernedRoot)' holds both '$([System.IO.Path]::GetFileName($policyContext.GovernedDatumPath))' and '$([System.IO.Path]::GetFileName($policyContext.GovernedPolicyPath))', so every resource in it has a layer and the policy written for them applies. Run it through the Datum path (-ConfigurationSourcePath '$($policyContext.GovernedRoot)'), where it is enforced. -BypassDatumPolicy does not override this - it declares that there is no policy to step outside of, not permission to step outside one that exists."
            }

            # -PolicyPath / -RequirePolicy still cannot be honoured: there is no layer to decide
            # a capability from. Point at the supported way through.
            if ($PSBoundParameters.ContainsKey('PolicyPath') -or $RequirePolicy) {
                throw "[Invoke-DscRunner] A capability policy cannot be applied to a passthrough configuration. The policy decides what a resource may do from the layer its file sits in, and a document supplied with -ConfigurationFile/-ConfigurationDirectory has no layers. Either compile through Datum (-ConfigurationSourcePath) so every resource's layer is known, or drop -PolicyPath/-RequirePolicy and declare the step outside the policy with -BypassDatumPolicy. See issue #106."
            }

            # Rule 2. Not declared: refuse, and name the switch.
            if (-not $BypassDatumPolicy) {
                throw "[Invoke-DscRunner] A passthrough configuration cannot be held to a capability policy: the policy decides what a resource may do from the layer its file sits in the Datum hierarchy, and a document supplied with -ConfigurationFile/-ConfigurationDirectory has no layers. Running one therefore steps outside the policy mechanism, which must be declared rather than assumed: pass -BypassDatumPolicy to say so, or compile the configuration through Datum (-ConfigurationSourcePath) so the policy applies. See issue #106."
            }

            # Rule 3. Declared. Said once per run on the warning stream, which is visible without
            # the caller opting in, so the step is in the log of every run that takes it; the
            # information-stream line is kept for a caller already reading that stream; and
            # Start-DscRunner records it on each node's result and report document below.
            Write-Warning "[Invoke-DscRunner] -BypassDatumPolicy: the capability policy is BYPASSED for this run. $($documentPaths.Count) passthrough document(s) will run with no layer-based constraint on their Targets, engines or execution scripts. Nothing in this run is checked against a policy."
            Write-Information "Capability policy: bypassed by -BypassDatumPolicy - a passthrough configuration has no layers to decide one from." -Tags 'Dsc.PipelineRunner'

            # A policy file sitting beside the documents with no Datum definition file above them
            # is the ambiguous case: it governs nothing this runner can resolve layers for, so it
            # is not rule 1. Named rather than ignored, because it is the single most likely thing
            # to make someone believe a policy is in force.
            if ($policyContext.StrayPolicyPath) {
                Write-Warning "[Invoke-DscRunner] '$($policyContext.StrayPolicyPath)' sits beside the passthrough configuration and is NOT being applied: a capability policy needs the Datum hierarchy its layers are defined over, and there is no Datum definition file above these documents. If this is a governed configuration, run it through the Datum path instead."
            }
            elseif ($policyContext.DatumRoot) {
                Write-Verbose "[Invoke-DscRunner] A Datum definition file was found at '$($policyContext.DatumRoot)' with no policy beside it; nothing to enforce."
            }
        }
        else {

            #
            # 1. Source — resolve the configuration to a local directory.
            $sourceDirectory = Invoke-Action -Hook Source -Name $Source -ScriptBlock $SourceAction -Context $SourceContext
            if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
                throw "[Invoke-DscRunner] The Source action returned no configuration directory."
            }
            Write-Verbose "[Invoke-DscRunner] Configuration directory: $sourceDirectory"

            #
            # 1b. The configuration's PipelineRunnerSettings. Resolved here, pre-compile, because
            # the compiled per-node YAML does not carry this block. Resolved regardless of
            # -Engine so its other keys (AllowExecutionScripts, Reboot, Target - #57 §2/§3/§4)
            # are available to pass down to Start-DscRunner even when the engine itself was
            # chosen explicitly.
            $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $sourceDirectory
        }

        #
        # 1c. Engine selection. An inline -EngineAction or an explicit -Engine always wins.
        # Otherwise the configuration decides: PipelineRunnerSettings.Engine names the engine,
        # and failing that the back-compat DSCResourceVersion major maps through Resolve-DscEngine
        # (2.x -> DscV2, 3.x -> DscV3, otherwise dsc.exe auto-detection). This keeps the version
        # gate out of the core loop while honouring the field configs already carry. For a
        # passthrough run the same rule is applied to the settings the caller supplied.
        if (-not $EngineAction -and -not $PSBoundParameters.ContainsKey('Engine')) {
            if ($settings) {
                if (-not [string]::IsNullOrWhiteSpace([string]$settings['Engine'])) {
                    $Engine = [string]$settings['Engine']
                    Write-Verbose "[Invoke-DscRunner] Engine from PipelineRunnerSettings.Engine: $Engine"
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$settings['DSCResourceVersion'])) {
                    $Engine = Resolve-DscEngine -Engine 'Auto' -Version ([string]$settings['DSCResourceVersion'])
                    Write-Verbose "[Invoke-DscRunner] Engine auto-selected from DSCResourceVersion '$($settings['DSCResourceVersion'])': $Engine"
                }
            }
        }

        #
        # 2. Connect — establish any required auth/session (default: None). A passthrough run
        # still applies resources to real targets, so it connects on the same terms.
        # A dry run validates the configuration without credentials, so it does not connect.
        if ($Mode -eq 'DryRun') {
            Write-Verbose "[Invoke-DscRunner] Dry run: skipping the Connect action."
        }
        else {
            $null = Invoke-Action -Hook Connect -Name $Connect -ScriptBlock $ConnectAction -Context $ConnectContext
        }

        $capabilityPolicy = $null

        if (-not $isPassthrough) {

            #
            # 3. Determine the compile/cache directory. An explicit -CacheDirectory wins, then the
            # generic PIPELINERUNNER_CACHE_DIRECTORY (with AZDODSC_CACHE_DIRECTORY kept as a
            # back-compat alias), and finally a fresh temporary directory — no env var is required.
            # Resolve into a local: the -CacheDirectory parameter carries a ValidateScript that
            # re-fires on every assignment, so writing an unresolved ($null) value back to it would
            # throw before the temp-dir fallback ever runs.
            $resolvedCacheDirectory = Resolve-CacheDirectory -CacheDirectory $CacheDirectory
            if ([string]::IsNullOrWhiteSpace($resolvedCacheDirectory)) {
                $resolvedCacheDirectory = New-TemporaryDirectory
                Write-Verbose "[Invoke-DscRunner] Using temporary cache directory: $resolvedCacheDirectory"
            }
            else {
                Write-Verbose "[Invoke-DscRunner] Using cache directory: $resolvedCacheDirectory"
            }

            #
            # 4. Compile Datum into the cache directory.
            # The resolved cache directory is the trusted scratch root; pass it as -AllowedRoot so the
            # compile step's path-traversal guard (#33) permits it while still rejecting an escaping path.
            # A Git source resolves the configuration from a remote clone, so flag it for the compile
            # step's trust-boundary warning (#27). Inline/custom Source actions that fetch remotely are
            # opaque here; the SECURITY.md trust model documents the requirement for those.
            $sourceIsRemote = ($Source -eq 'Git') -or ($SourceContext.ContainsKey('Url') -and -not [string]::IsNullOrWhiteSpace([string]$SourceContext['Url']) -and ([string]$SourceContext['Url'] -match '^(http|https|git|ssh):'))
            $buildArguments = @{ OutputPath = $resolvedCacheDirectory; ConfigurationPath = $sourceDirectory; AllowedRoot = $resolvedCacheDirectory; SourceIsRemote = $sourceIsRemote }
            $resolvedPolicyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $sourceDirectory -PolicyPath $PolicyPath -Require:$RequirePolicy
            if ($resolvedPolicyPath) {
                # Policy.yml beside Datum.yml, or the file the pipeline named. Refused if it sits in a
                # sub-folder of the configuration, where a constrained layer could change it.
                $capabilityPolicy = Import-CapabilityPolicy -Path $resolvedPolicyPath -ConfigurationPath $sourceDirectory
                $buildArguments.PolicyPath = $capabilityPolicy.Path
                Write-Information "Capability policy (preview): $($capabilityPolicy.Layers.Count) layer(s) from '$($capabilityPolicy.Path)', default $($capabilityPolicy.Default)." -Tags 'Dsc.PipelineRunner'
            }
            Build-DatumConfiguration @buildArguments

            $documentPaths = @(Get-ChildItem -LiteralPath $resolvedCacheDirectory -File -Filter '*.yml' | ForEach-Object { $_.FullName })
        }

        #
        # 5. Run the core loop once per configuration document.
        $params = @{ Mode = $Mode; Engine = $Engine }
        if ($capabilityPolicy) { $params.Policy = $capabilityPolicy }
        if ($ReportPath)    { $params.ReportPath    = $ReportPath }
        if ($EngineVersion) { $params.EngineVersion = $EngineVersion }
        if ($EngineAction)  { $params.EngineAction  = $EngineAction }
        if ($ReportAction)  { $params.ReportAction  = $ReportAction }
        if ($settings)      { $params.RunnerSettings = $settings }
        # Passthrough only (#106); unbound on the Datum path, whose node name is always the
        # compiled file's name.
        if (-not [string]::IsNullOrWhiteSpace($NodeName)) { $params.NodeName = $NodeName }
        # #106: recorded per node on the result and in the report document, so the bypass is
        # visible to an audit and not only in the console. Only ever set on a passthrough run.
        if ($isPassthrough -and $BypassDatumPolicy) { $params.PolicyBypassed = $true }

        # Collect each configuration's structured result so the run can be summarized as a single
        # machine-readable object and, with -FailOnError, surface a non-zero exit code (#19).
        $runResults = $documentPaths | ForEach-Object {
            Start-DscRunner -FilePath $_ @params
        }

        $summaryArgs = @{ Result = $runResults }
        if ($ReportPath)  { $summaryArgs.ReportPath  = $ReportPath }
        if ($FailOnError) { $summaryArgs.FailOnError = $true }

        return Merge-DscRunnerResult @summaryArgs

    }
    finally {
        # The DscV3 engine's per-type discovery answers and the manifest copies they made.
        # (Tests that load the entry point on its own may not load this helper.)
        if (Get-Command -Name Clear-DscV3ResourcePath -ErrorAction SilentlyContinue) {
            Clear-DscV3ResourcePath
        }

        if ($KeepTemporaryDirectory) {
            Write-Verbose "[Invoke-DscRunner] -KeepTemporaryDirectory was supplied; leaving any temporary directories in place."
        }
        else {
            # No-ops for a caller-supplied path; deletes only what the runner created.
            Remove-RunnerTemporaryDirectory -Path $sourceDirectory
            Remove-RunnerTemporaryDirectory -Path $resolvedCacheDirectory
        }
    }
}
