<#
.SYNOPSIS
Reports what a configuration's capability policy permits, and which layer each file and each
resource declaration falls in, without compiling or running anything.

.DESCRIPTION
A capability policy (see docs/capability-policy.md) says what each layer of a configuration may
use. It is enforced against a compiled configuration, which means the first time most people see
a policy work is when it stops a run. This command is the other way round: it reads the policy and
the configuration's files and prints what the policy means, before it bites.

It answers three questions:

  * **What does the policy permit?** Every layer, its path patterns, and the effective rule for
    every capability - including the ones the layer does not list, where the policy's `Default`
    decides. A capability a layer leaves out is shown as what it actually resolves to, not as a
    blank.
  * **Which layer owns what?** Every data file in the configuration with the layer the policy
    attributes it to, the entries of `Datum.yml`'s `ResolutionPrecedence` with their layers, and
    every resource the files declare with the layer(s) that declare it.
  * **Is the policy doing anything?** Findings for the ways a policy ends up quietly ineffective
    or quietly total: a layer whose `Paths` match no file, a file no layer claims, a layer that
    may use a remote Target but is allowed no remote computer to reach, a layer that may declare
    no resource type at all, `Default: Allow`, and any declaration the policy would refuse.

Nothing is compiled, no node is resolved and no resource is run, so this is safe to run in a pull
request, in a pre-commit hook or against a configuration that does not yet work.

**It is advisory.** The report reads the layer files; it does not perform Datum's merge. It does
not know the resolution precedence, the lookup options, conditions or composite expansion, so a
resource it shows as allowed can still be refused at run time - most often because a second layer
also declares it and least privilege then applies both layers' permissions. The authoritative
check is the run (`Invoke-DscRunner`), which judges the compiled file against the provenance
record. Treat a clean report as "nothing obviously wrong", not as "this will run".

.PARAMETER ConfigurationPath
The configuration root: the folder that holds `Datum.yml`, and `Policy.yml` beside it.

.PARAMETER PolicyPath
A policy file to report on instead of the configuration's own `Policy.yml`, as a pipeline that
imposes its own policy would supply with `Invoke-DscRunner -PolicyPath`.

.PARAMETER RequirePolicy
Fail when the configuration has no policy, instead of reporting that it has none.

.PARAMETER AsText
Return the report as lines of text for a person to read, instead of an object.

.EXAMPLE
Get-DscCapabilityPolicyReport -ConfigurationPath ./config -AsText

Prints the layers, their capabilities, the file-to-layer mapping and the findings.

.EXAMPLE
$report = Get-DscCapabilityPolicyReport -ConfigurationPath ./config
if ($report.HasError) { $report.Findings | Where-Object Severity -EQ 'Error' }

Fails a pull-request pipeline on a policy that denies something the configuration declares, or on
a file that belongs to no layer.

.EXAMPLE
(Get-DscCapabilityPolicyReport -ConfigurationPath ./config).Layers |
    Select-Object Name, FileCount -ExpandProperty Capabilities

What each layer may use, and how many files it owns.

.OUTPUTS
[pscustomobject] The report, or [string[]] with -AsText.
#>
function Get-DscCapabilityPolicyReport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType 'Container' })]
        [string] $ConfigurationPath,

        [Parameter()]
        [string] $PolicyPath,

        [Parameter()]
        [switch] $RequirePolicy,

        [Parameter()]
        [switch] $AsText
    )

    $root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ConfigurationPath).ProviderPath).TrimEnd('\', '/')
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $Severity, [string] $Code, [string] $Message)
        $findings.Add([pscustomobject]@{ Severity = $Severity; Code = $Code; Message = $Message })
    }

    $resolvedPolicyPath = Resolve-CapabilityPolicyPath -ConfigurationPath $root -PolicyPath $PolicyPath -Require:$RequirePolicy
    if (-not $resolvedPolicyPath) {
        & $add 'Information' 'NoPolicy' "This configuration has no capability policy: there is no Policy.yml beside its Datum.yml and no -PolicyPath was given. Every layer may use everything the runner can do. See docs/capability-policy.md."
        $report = [pscustomobject]@{
            ConfigurationPath    = $root
            PolicyPath           = $null
            PolicySha256         = $null
            PolicyVersion        = $null
            Default              = $null
            Layers               = @()
            Files                = @()
            ResolutionPrecedence = @()
            Resources            = @()
            Findings             = @($findings)
            HasError             = $false
        }
        if ($AsText) { return (Format-CapabilityPolicyReport -Report $report) }
        return $report
    }

    $policy = Import-CapabilityPolicy -Path $resolvedPolicyPath -ConfigurationPath $root
    $coverage = Get-CapabilityPolicyCoverage -ConfigurationPath $root -Policy $policy

    #
    # What the policy permits: the effective rule for every capability of every layer, with the
    # ones the layer does not list resolved through Default rather than left blank.
    $listCapabilities = 'Targets', 'Engines', 'Resources', 'Credentials', 'RemoteTargets'
    $switchCapabilities = 'ExecutionScripts', 'DatumScriptBlocks', 'Notify', 'Reboot'

    $layers = foreach ($layer in $policy.Layers) {
        $capabilities = [ordered]@{}
        foreach ($capability in ($listCapabilities + $switchCapabilities)) {
            if ($layer.Capabilities.ContainsKey($capability)) {
                $rule = $layer.Capabilities[$capability]
                $capabilities[$capability] = if ($rule -is [bool]) { if ($rule) { 'Allow' } else { 'Deny' } }
                elseif (@($rule).Count -eq 0) { 'Deny (empty list)' }
                else { ($rule -join ', ') }
            }
            else {
                $capabilities[$capability] = "$($policy.Default) (not listed; from Default)"
            }
        }
        $summary = @($coverage.Layers | Where-Object { $_.Name -eq [string]$layer.Name } | Select-Object -First 1)
        [pscustomobject]@{
            Name         = [string]$layer.Name
            Paths        = [string[]]$layer.Paths
            FileCount    = if ($summary.Count -gt 0) { [int]$summary[0].FileCount } else { 0 }
            Capabilities = $capabilities
        }
    }
    $layers = @($layers)

    #
    # Which layer owns the hierarchy itself. Each ResolutionPrecedence entry keeps its $Node
    # placeholders: it is a pattern over node names, and the policy matches it as written.
    $precedence = @()
    $definitionFile = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -in 'Datum.yml', 'Datum.yaml' } | Select-Object -First 1)
    if ($definitionFile.Count -gt 0) {
        $definition = $null
        try { $definition = Get-Content -LiteralPath $definitionFile[0].FullName -Raw | ConvertFrom-Yaml }
        catch { & $add 'Warning' 'UnreadableDefinition' "The Datum definition file '$($definitionFile[0].Name)' cannot be read, so the resolution precedence is not in this report: $($_.Exception.Message)" }
        if ($definition -is [System.Collections.IDictionary] -and $definition.Contains('ResolutionPrecedence')) {
            $precedence = @(
                foreach ($entry in @($definition['ResolutionPrecedence'])) {
                    $path = ([string]$entry -replace '\\', '/')
                    [pscustomobject]@{ Path = $path; Layer = (Get-PolicyLayer -Policy $policy -RelativePath $path) }
                }
            )
        }
    }

    #
    # Which layer each resource declaration falls in, and what the policy makes of it. Least
    # privilege is reproduced the only way it can be without the merge: a resource several files
    # declare is judged against every layer that declares it.
    $layersByName = @{}
    foreach ($declaration in $coverage.Declarations) {
        $name = [string]$declaration.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $layersByName.ContainsKey($name)) { $layersByName[$name] = [System.Collections.Generic.List[string]]::new() }
        if ($declaration.Layer -notin $layersByName[$name]) { $layersByName[$name].Add([string]$declaration.Layer) }
    }

    # The file-level default Target, which a resource with no 'target' block of its own would use.
    # A definition file this cannot read is reported above, not thrown: the point of the report is
    # to describe a configuration somebody is still working on.
    $defaultTarget = 'Local'
    $settings = $null
    $settingsReadable = $true
    try {
        $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $root
        if ($settings -and -not [string]::IsNullOrWhiteSpace([string]$settings['Target'])) { $defaultTarget = [string]$settings['Target'] }
    }
    catch {
        $settingsReadable = $false
        & $add 'Warning' 'UnreadableSettings' "The PipelineRunnerSettings block of the Datum definition file cannot be read, so this report assumes the default Target is 'Local': $($_.Exception.Message)"
    }

    $resources = foreach ($declaration in $coverage.Declarations) {
        $name = [string]$declaration.Name
        $declaringLayers = if ($layersByName.ContainsKey($name)) { [string[]]@($layersByName[$name]) } else { [string[]]@($declaration.Layer) }
        $refusals = [System.Collections.Generic.List[string]]::new()

        $checks = [System.Collections.Generic.List[object]]::new()
        $checks.Add(@{ Capability = 'Resources'; Value = [string]$declaration.Type; What = "the resource type '$($declaration.Type)'" })

        $targetAction = if ([string]::IsNullOrWhiteSpace([string]$declaration.TargetAction)) { $defaultTarget } else { [string]$declaration.TargetAction }
        $targetIsExpression = $targetAction -match '\$\(|\$\{|\[x='
        if (-not $targetIsExpression) { $checks.Add(@{ Capability = 'Targets'; Value = $targetAction; What = "the Target '$targetAction'" }) }

        if ($null -ne $declaration.TargetAction -and ($targetIsExpression -or $targetAction -ne 'Local')) {
            $checks.Add(@{ Capability = 'RemoteTargets'; Value = [string]$declaration.ComputerName; What = "the remote Target computer '$($declaration.ComputerName)'" })
        }
        foreach ($credentialAction in @($declaration.CredentialActions)) {
            $checks.Add(@{ Capability = 'Credentials'; Value = $credentialAction; What = "the '$credentialAction' Credential action" })
        }
        if ($declaration.ExecutionScript) { $checks.Add(@{ Capability = 'ExecutionScripts'; Value = $null; What = 'an execution script' }) }
        if (@($declaration.Notify).Count -gt 0) { $checks.Add(@{ Capability = 'Notify'; Value = $null; What = 'a notify' }) }

        foreach ($check in $checks) {
            $arguments = @{ Policy = $policy; Layer = $declaringLayers; Capability = $check.Capability }
            if ($null -ne $check.Value) { $arguments.Value = $check.Value }
            $decision = Test-PolicyCapability @arguments
            if (-not $decision.Allowed) { $refusals.Add("$($check.What) is not allowed for layer(s) $($decision.DeniedBy -join ', ')") }
        }

        [pscustomobject]@{
            Name            = $name
            Type            = [string]$declaration.Type
            DeclaredIn      = [string]$declaration.Path
            Layer           = [string]$declaration.Layer
            DeclaringLayers = $declaringLayers
            TargetAction    = $targetAction
            Allowed         = ($refusals.Count -eq 0)
            Refusals        = [string[]]$refusals.ToArray()
        }
    }
    $resources = @($resources)

    #
    # Findings: the ways a policy is quietly ineffective, quietly total, or already refusing
    # something that is in the configuration today.
    if ($policy.Default -eq 'Allow') {
        & $add 'Warning' 'DefaultAllow' "Default is Allow: a capability a layer does not list is permitted. Only the capabilities a layer lists restrict it, so a capability added to the runner in a later version is allowed to every layer that has not been updated. Default: Deny is recommended."
    }

    foreach ($unmatched in @($coverage.UnmatchedLayers)) {
        $definitionOf = @($policy.Layers | Where-Object { [string]$_.Name -eq $unmatched } | Select-Object -First 1)
        $patterns = if ($definitionOf.Count -gt 0) { ($definitionOf[0].Paths -join ', ') } else { '' }
        & $add 'Warning' 'LayerMatchesNothing' "Layer '$unmatched' matches no file in this configuration (Paths: $patterns). Its capabilities grant nothing. If that is not deliberate, a path pattern is wrong and the files you meant it to own are in '(unclaimed)', which may do nothing at all."
    }

    foreach ($unclaimed in @($coverage.UnclaimedFiles)) {
        & $add 'Error' 'UnclaimedFile' "'$unclaimed' belongs to no layer, so nothing it declares may do anything, whatever Default says. Add a layer whose Paths cover it, or remove it."
    }

    foreach ($unreadable in @($coverage.UnreadableFiles)) {
        & $add 'Warning' 'UnreadableFile' "This report could not read '$unreadable', so nothing it declares is in the report."
    }

    foreach ($layer in $layers) {
        $remote = @($policy.Layers | Where-Object { [string]$_.Name -eq $layer.Name } | Select-Object -First 1)
        if ($remote.Count -eq 0) { continue }
        $capabilities = $remote[0].Capabilities

        $mayUseRemoteTarget = $false
        if ($capabilities.ContainsKey('Targets')) {
            $mayUseRemoteTarget = @($capabilities['Targets'] | Where-Object { [string]$_ -ne 'Local' }).Count -gt 0
        }
        elseif ($policy.Default -eq 'Allow') { $mayUseRemoteTarget = $true }

        $mayReachAnyComputer = if ($capabilities.ContainsKey('RemoteTargets')) { @($capabilities['RemoteTargets']).Count -gt 0 } else { $policy.Default -eq 'Allow' }
        if ($mayUseRemoteTarget -and -not $mayReachAnyComputer) {
            & $add 'Warning' 'RemoteTargetWithoutComputer' "Layer '$($layer.Name)' may use a Target other than Local, but RemoteTargets allows it no computer, so every remote resource it declares is refused. Add the computers it may reach to RemoteTargets, or drop the remote Target from its Targets."
        }

        $mayDeclareNothing = if ($capabilities.ContainsKey('Resources')) { @($capabilities['Resources']).Count -eq 0 } else { $policy.Default -eq 'Deny' }
        if ($mayDeclareNothing -and $layer.FileCount -gt 0) {
            & $add 'Warning' 'LayerDeclaresNothing' "Layer '$($layer.Name)' owns $($layer.FileCount) file(s) but may declare no resource type at all (Resources resolves to Deny), so every resource in those files is refused. List the resource types it may use, for example Resources: [ 'PSDscResources/*' ]."
        }
    }

    foreach ($resource in ($resources | Where-Object { -not $_.Allowed })) {
        & $add 'Error' 'DeclarationRefused' "Resource [$($resource.Type)/$($resource.Name)], declared in '$($resource.DeclaredIn)' (layer(s) $($resource.DeclaringLayers -join ', ')): $($resource.Refusals -join '; ')."
    }

    # The real pre-compile check, run for its findings instead of for its throw: a Datum script
    # block in a layer that may not use one, and a Datum.yml that would pull the policy into the
    # merge. Reusing it means the report cannot drift from what the compile refuses.
    try { Assert-DatumScriptBlockPolicy -ConfigurationPath $root -Policy $policy }
    catch { & $add 'Error' 'PreCompileRefusal' ([string]$_.Exception.Message) }

    # The policy's Settings block against Datum.yml's PipelineRunnerSettings, through the same
    # check the run uses. The engine is judged as Datum.yml names it; a pipeline that passes
    # -Engine is not governed.
    if ($settingsReadable) {
        try { Assert-RunnerSettingsPolicy -Policy $policy -Settings $settings }
        catch { & $add 'Error' 'SettingsRefusal' ([string]$_.Exception.Message) }
    }

    $settingsLayer = Get-PolicyLayer -Policy $policy -RelativePath 'Datum.yml'
    & $add 'Information' 'DefinitionFileOwner' "The Datum definition file belongs to layer '$settingsLayer'. It sets the resolution precedence, the merge rules, the Datum handlers and PipelineRunnerSettings, so whoever can change it can reshape the merge whatever this policy says. It should belong to the most trusted layer, and be protected like Policy.yml."

    $report = [pscustomobject]@{
        ConfigurationPath    = $root
        PolicyPath           = [string]$policy.Path
        PolicySha256         = [string]$policy.Sha256
        PolicyVersion        = $policy.PolicyVersion
        Default              = [string]$policy.Default
        Layers               = $layers
        Settings             = $policy.Settings
        Files                = @($coverage.Files)
        ResolutionPrecedence = @($precedence)
        Resources            = $resources
        Findings             = @($findings)
        HasError             = (@($findings | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0)
    }

    if ($AsText) { return (Format-CapabilityPolicyReport -Report $report) }
    return $report
}
