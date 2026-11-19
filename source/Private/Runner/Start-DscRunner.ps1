<#
.SYNOPSIS
Invokes the Desired State Configuration (DSC) based on a provided configuration file.

.DESCRIPTION
The Start-DscRunner function processes a DSC configuration file (YAML or JSON) and executes the tasks defined within it.
It supports both 'Test' and 'Set' modes to either validate the current state or apply changes to achieve the desired state.

Each resource is evaluated through the selected engine (DscV2 / DscV3 / custom), which returns a normalized
[DscMethodResult]. The runner records one structured result per resource, keyed by
(ConfigurationFile, ResourceType, InstanceName), so a resource is never double-counted. The report is written from a
finally block, so it is produced even when the run is stopped early (Stop-TaskProcessing) or aborted by an exception.

All human-readable output is emitted on the information stream (Write-Information, tag 'Dsc.PipelineRunner') rather
than Write-Host, so a caller can capture it with -InformationVariable or redirect it. DSC's native progress UI is
suppressed for the duration of the run so it does not flood the pipeline log.

.PARAMETER FilePath
The path to the configuration file (.yaml/.yml or .json).

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' (default) and 'Set'.
'Test' mode validates the current state, while 'Set' mode applies changes to achieve the desired state.

.PARAMETER ReportPath
Optional directory for saving the report. When provided, a CSV and a JSON report are written for the configuration.

.PARAMETER NodeName
The node name for this run. Defaults to the configuration file's base name, which is what the
Datum compile produces. Supplied only by a passthrough caller (issue #106) whose file is not
named after its node. It is written into the report file names, so it is validated as a file name.

.PARAMETER PolicyBypassed
Set by Invoke-DscRunner when a passthrough run declared -BypassDatumPolicy (issue #106). It does
not change what runs; it records on the result and in the report document that the capability
policy was stepped outside for this run.

.PARAMETER Engine
Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource (DscV2).

.PARAMETER EngineVersion
Optional resource version hint that biases 'Auto' engine selection by major version.

.PARAMETER EngineAction
Optional inline engine override; takes precedence over -Engine.

.OUTPUTS
[pscustomobject] describing the run: ConfigurationFile, Status (Completed / StoppedByRequest / AbortedByException),
TotalResources, PassCount, FailCount, SkipCount, DurationSeconds, ErrorMessage, FailedResources and the per-resource Results.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.yaml" -Mode "Test"
Invokes the DSC configuration in 'Test' mode using the specified YAML configuration file.

.EXAMPLE
Start-DscRunner -FilePath "C:\Configs\MyConfig.json" -Mode "Set" -ReportPath "C:\Reports"
Invokes the DSC configuration in 'Set' mode using the specified JSON configuration file and saves the report to the specified path.

.NOTES
- The function supports both YAML and JSON configuration files.
- The function processes tasks in the order of their dependencies.
- The function generates a detailed report of the execution, which can be saved to a specified path.

#>
#
# Function to Invoke the DSC Configuration
function Start-DscRunner {
    # Declare parameters for the function with default values and validation where needed
    param (
        [string] $FilePath, # The path to the configuration file (.yaml/.yml or .json)
        # 'Test' evaluates each resource and reports drift; 'Set' also applies changes. 'DryRun'
        # validates the configuration and works out what would run, without calling an engine,
        # opening a connection or resolving a credential.
        [ValidateSet("Test", "Set", "DryRun")]
        [string] $Mode = "Test",
        [String] $ReportPath = $null, # Optional parameter for specifying a report path
        [string] $Engine = 'DscV2', # Execution engine action (Actions/Engine/<Engine>.ps1). 'Auto' opts in to detection; default is Invoke-DscResource.
        [string] $EngineVersion, # Optional resource version hint that biases 'Auto' engine selection by major version.
        [scriptblock] $EngineAction, # Optional inline engine override; takes precedence over -Engine.
        [scriptblock] $ReportAction, # Optional inline reporter; receives the report document for this file.
        [hashtable] $Policy, # Optional capability policy (Import-CapabilityPolicy); issue #86 Part B.

        # Resolved PipelineRunnerSettings (#57 §2/§3/§4), e.g. AllowExecutionScripts, Reboot,
        # Target. Invoke-DscRunner resolves this once from Datum.yml (pre-compile, since it is
        # not present in a compiled per-node YAML file) and passes it through; a direct caller
        # of Start-DscRunner may also supply it. Defaults are applied throughout when absent, so
        # every key stays optional and today's behavior is unchanged when this is not supplied.
        [hashtable] $RunnerSettings = @{},

        # The node name for this run (#106). Optional: when omitted it is the configuration
        # file's base name, which is what the Datum compile produces (one <node>.yml per node,
        # named for the node) and what every caller got before this parameter existed. A
        # passthrough caller whose file is not named after its node supplies it here.
        [string] $NodeName,

        # Set when this run declared -BypassDatumPolicy (#106): a passthrough document, which has
        # no layers for a capability policy to be decided over, running with the caller's explicit
        # say-so. Recorded on the result and in the report document so the bypass is visible to
        # someone auditing the run afterwards, not only in the console.
        [switch] $PolicyBypassed
    )

    # Informational output is the pipeline log's signal channel; make it visible by default
    # for the duration of the run, and keep DSC's native progress UI out of the log. Both are
    # local to this scope, so the caller's preferences are left untouched on return.
    $InformationPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'

    $infoTag = 'Dsc.PipelineRunner'

    # Resolve the engine once so any dsc.exe probe / auto-selection warning happens a
    # single time per file rather than per resource. An inline EngineAction override
    # bypasses selection entirely (it takes precedence over -Engine); an explicit engine
    # name is honoured verbatim, and only 'Auto' triggers detection.
    $resolvedEngine = $Engine
    if (-not $EngineAction -and $Engine -eq 'Auto') {
        $resolvedEngine = Resolve-DscEngine -Engine $Engine -Version $EngineVersion
        Write-Verbose "Auto-selected DSC engine: $resolvedEngine"
    }

    # Build the engine selector once; every Test/Set/Get for this file runs through it.
    $engineArgs = @{ Engine = $resolvedEngine }
    if ($EngineAction) { $engineArgs.EngineAction = $EngineAction }

    # Reset the run-control flag for this file. $script:StopTaskProcessing is a documented
    # cross-file, module-script-scope contract (#26): Start-DscRunner owns it (resets here,
    # reads it once per resource below), and Stop-TaskProcessing is the only other writer,
    # setting it $true to skip the rest of the file. See Stop-TaskProcessing.ps1 for the guard
    # that keeps the two in lock-step.
    $script:StopTaskProcessing = $false

    # notify/using(): reset the per-run state that ties notify declarations, Get() output and
    # forced-refresh requests to this file. Owned by Start-DscRunner the same way
    # $script:StopTaskProcessing is above.
    $script:notifyDeclarations = @{}
    $script:resourceOutputs = @{}
    $script:pendingNotifyRefresh = @{}
    $script:currentResourceKey = $null

    # #57 §4: sessions opened by a Target action, cached per (TargetAction, ComputerName,
    # CredentialKey) so multiple resources aimed at the same remote target reuse one
    # connection instead of opening a fresh CimSession/PSSession per resource. Closed in the
    # finally block below regardless of how the run ends.
    $sessionCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # #57 §3: reboot policy. 'Fail' (default) stops the run when a local Set reports
    # RebootRequired; 'Ignore' continues without restarting. A remote target always restarts
    # and waits (Restart-Computer -Wait) regardless of this setting, since the runner is not
    # itself what needs to come back up.
    $rebootPolicy = if ($RunnerSettings -and -not [string]::IsNullOrWhiteSpace([string]$RunnerSettings['Reboot'])) { [string]$RunnerSettings['Reboot'] } else { 'Fail' }

    # #57 §4: the file-level default Target action; a resource may override it with its own
    # 'target' block. 'Local' (today's only behavior) is the default so an unmodified
    # configuration's execution is unchanged.
    $defaultTargetAction = if ($RunnerSettings -and -not [string]::IsNullOrWhiteSpace([string]$RunnerSettings['Target'])) { [string]$RunnerSettings['Target'] } else { 'Local' }

    # Reporting (#85). PipelineRunnerSettings.Report selects what a report contains and where it
    # goes, beyond the CSV/JSON files -ReportPath has always written:
    #   State:     None (default) | Drift | Full - capture each resource's desired and actual
    #              state (redacted) for resources that drifted, or for all of them.
    #   Reporters: names of Actions/Report/<Name>.ps1 actions to send the report document to.
    #              'File' is the built-in writer below and needs no entry.
    #   OnError:   Warn (default) | Fail - what a failing reporter does to the result.
    # An unknown State is an error rather than a silent 'None': someone who asked for state and
    # did not get it would not find out until they needed it.
    $reportSettings = if ($RunnerSettings -and $RunnerSettings['Report'] -is [System.Collections.IDictionary]) { $RunnerSettings['Report'] } else { @{} }
    $reportState = if (-not [string]::IsNullOrWhiteSpace([string]$reportSettings['State'])) { [string]$reportSettings['State'] } else { 'None' }
    if ($reportState -notin 'None', 'Drift', 'Full') {
        throw "[Start-DscRunner] PipelineRunnerSettings.Report.State is '$reportState'; expected None, Drift or Full."
    }
    $reportState = (Get-Culture).TextInfo.ToTitleCase($reportState.ToLowerInvariant())
    # OnError: Warn (default) reports a failed reporter as an error and leaves the result alone.
    # Fail marks an otherwise-clean file 'ReportFailed', for runs where an undelivered report
    # must fail the pipeline (an audit trail, for example).
    $reportOnError = if (-not [string]::IsNullOrWhiteSpace([string]$reportSettings['OnError'])) { [string]$reportSettings['OnError'] } else { 'Warn' }
    if ($reportOnError -notin 'Warn', 'Fail') {
        throw "[Start-DscRunner] PipelineRunnerSettings.Report.OnError is '$reportOnError'; expected Warn or Fail."
    }
    $reporterNames = @($reportSettings['Reporters'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -ne 'File' } | ForEach-Object { [string]$_ })
    # Per-resource detail that is reported but is not part of the result record (whose shape,
    # and so the CSV's columns, is unchanged): drift, whether Set ran, and captured state.
    $resourceDetails = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::Ordinal)
    # One resource's captured state is bounded, so a resource returning a very large object
    # cannot exhaust memory or flood a third party.
    $maxStateCharacters = 65536

    # Determine the file extension of the provided FilePath
    $fileExtension = [System.IO.Path]::GetExtension($FilePath)
    Write-Verbose "File extension determined: $fileExtension"

    if ($fileExtension -notin '.yaml', '.yml', '.json') {
        throw "[Start-DscRunner] Unsupported configuration file extension '$fileExtension'. Expected .yaml, .yml or .json."
    }

    # Reject unsupported inputs up front, before any reporting state is set up (#15). A
    # missing file used to make Get-Content emit a *non-terminating* error, leaving $pipeline
    # $null; the run then completed with zero resources and reported 'Completed', so a typo
    # in a path looked exactly like a successful no-op run.
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            "[Start-DscRunner] Configuration file not found: '$FilePath'.", $FilePath)
    }

    # Run-level bookkeeping. Results are structured records, deduplicated by the
    # (ConfigurationFile, ResourceType, InstanceName) tuple so a resource is counted once.
    # The node name. NOTE: $NodeName (the parameter above) and $nodeName are the SAME variable,
    # because PowerShell variable names are case-insensitive. That is deliberate here: resolving
    # it once at the top means every use below - the result records, the nodeName() accessor, the
    # report file names and the reporter context - reads the resolved value with no second path.
    if ([string]::IsNullOrWhiteSpace($NodeName)) {
        $nodeName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    }
    elseif ($NodeName -notmatch '^[^/\\:*?"<>|\x00-\x1F]+$' -or $NodeName.StartsWith('.') -or
            $NodeName -match '\.\.' -or $NodeName -ne $NodeName.Trim()) {
        # A node name becomes a file name: the report is written as <node>.csv, <node>.report.json,
        # <node>.state.json and <node>.rsop.json under -ReportPath. Held to the same rule
        # Resolve-DscDatumProject applies to a node name, for the same reason - a path separator,
        # a wildcard, '..' or a leading '.' must not be able to steer a report write out of the
        # report directory.
        throw "[Start-DscRunner] The node name '$($NodeName -replace '[\x00-\x1F]', '?')' is not a valid file name (path separators, wildcard characters, '..' and a leading '.' are not allowed); the node name is written into this run's report file names."
    }
    $results     = [System.Collections.Generic.List[pscustomobject]]::new()
    $resultIndex = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new([System.StringComparer]::Ordinal)
    $runStatus   = 'Completed'
    $runError    = $null
    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Secrets resolved for the resource currently being evaluated: credential passwords and any
    # plain-string value under a sensitive property name. Engines and remote targets can echo
    # their input back in an error, and an error message ends up in the log, the CSV and the
    # JSON report, so every message passes through $safeText below before it is surfaced.
    $secretValues = [System.Collections.Generic.List[string]]::new()

    $collectSecrets = {
        param($Table)
        foreach ($entryKey in @($Table.Keys)) {
            $entryValue = $Table[$entryKey]
            if ($entryValue -is [System.Management.Automation.PSCredential]) {
                $plain = $entryValue.GetNetworkCredential().Password
                if ($plain.Length -ge 4) { $secretValues.Add($plain) }
            }
            elseif ($entryValue -is [securestring]) {
                $plain = [System.Net.NetworkCredential]::new('', $entryValue).Password
                if ($plain.Length -ge 4) { $secretValues.Add($plain) }
            }
            elseif ($entryValue -is [System.Collections.IDictionary]) {
                & $collectSecrets $entryValue
            }
            elseif ($entryValue -is [System.Collections.IEnumerable] -and $entryValue -isnot [string]) {
                $sensitiveList = Test-SensitivePropertyName -Name ([string]$entryKey)
                foreach ($item in $entryValue) {
                    if ($item -is [System.Collections.IDictionary]) { & $collectSecrets $item }
                    elseif ($sensitiveList -and $item -is [string] -and $item.Length -ge 4) { $secretValues.Add($item) }
                }
            }
            elseif ($entryValue -is [string] -and $entryValue.Length -ge 4 -and (Test-SensitivePropertyName -Name ([string]$entryKey))) {
                $secretValues.Add($entryValue)
            }
        }
    }

    # Makes text safe to log and to record: known secrets are replaced (longest first, so a
    # secret that contains another is replaced whole), control characters are escaped so one
    # message cannot become several log lines, and the CI log-command prefixes (##vso[ and
    # ##[ for Azure Pipelines, :: for GitHub Actions) are defused, since a resource name or a
    # remote target's output is not trusted to be inert.
    $safeText = {
        param([AllowNull()][string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $clean = $Text
        if ($secretValues.Count -gt 0) {
            foreach ($secret in ($secretValues | Sort-Object -Property Length -Descending)) {
                $clean = $clean.Replace($secret, '[REDACTED]')
                $jsonEscaped = ([string](ConvertTo-Json -InputObject $secret -Compress)).Trim('"')
                if ($jsonEscaped -ne $secret) { $clean = $clean.Replace($jsonEscaped, '[REDACTED]') }
            }
        }
        $clean = [regex]::Replace($clean, '[\x00-\x1F\x7F\u0085\u2028\u2029]', {
            param($m)
            switch ([int][char]$m.Value) { 10 { '\n' } 13 { '\r' } 9 { '\t' } default { '\x{0:X2}' -f [int][char]$m.Value } }
        })
        $clean = $clean -replace '##(?=vso\[|\[)', '#\#'
        return ($clean -replace '^::', '\::')
    }

    # Records a single resource outcome, replacing any earlier record for the same tuple so a
    # resource re-observed within a file does not double-count.
    $recordResult = {
        param($ResourceType, $InstanceName, $Status, $DurationMs, $ErrorMessage)

        # #57 §3/§4: Target/ComputerName/RebootRequired are read from the enclosing loop's
        # variables (this scriptblock is invoked with & from inside the loop, same as
        # $FilePath/$nodeName above, so it sees them by the same dynamic-scoping rule) rather
        # than as parameters, so every existing call site keeps working unchanged. They may be
        # unset at call sites that record a result before target resolution runs (e.g. a
        # preCondition failure) - PowerShell reads an unset variable as $null, handled below.
        $recordedTarget       = $targetAction
        $recordedComputerName = if ($session) { $session.ComputerName } else { $null }
        $recordedReboot       = if ($result) { [bool]$result.RebootRequired } else { $false }

        $record = [pscustomobject]@{
            NodeName          = $nodeName
            ResourceType      = $ResourceType
            InstanceName      = $InstanceName
            ConfigurationFile = $FilePath
            Status            = $Status
            DurationMs        = $DurationMs
            ErrorMessage      = (& $safeText $ErrorMessage)
            Target            = $recordedTarget
            ComputerName      = $recordedComputerName
            RebootRequired    = $recordedReboot
        }

        $key = '{0}|{1}|{2}' -f $FilePath, $ResourceType, $InstanceName
        if ($resultIndex.ContainsKey($key)) {
            $existing = $resultIndex[$key]
            $results[$results.IndexOf($existing)] = $record
        }
        else {
            $results.Add($record)
        }
        $resultIndex[$key] = $record
    }

    # Load the configuration from the YAML or JSON file into the $pipeline variable.
    # -LiteralPath throughout: a configuration path is data, and a bracket in a directory
    # name would otherwise be read as a wildcard.
    if ($fileExtension -eq ".yaml" -or $fileExtension -eq ".yml") {
        $pipeline = Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Yaml
        Write-Verbose "Loaded YAML configuration from file: $FilePath"
    }
    else {
        # ConvertFrom-Json -AsHashtable returns a case-SENSITIVE OrderedHashtable on
        # PowerShell 7.3+, which breaks the runner's and the rules' mixed-case member access
        # (e.g. Sort-DependsOn's $Resource.Type, Start-DscRunner's $task.Condition) and would
        # silently collapse every resource onto the same empty key. Normalize to case-insensitive
        # hashtables so a JSON configuration behaves exactly like the YAML loader's output.
        $pipeline = ConvertTo-CaseInsensitiveHashtable -InputObject (Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Json -AsHashtable)
        Write-Verbose "Loaded JSON configuration from file: $FilePath"
    }

    # An empty or content-free configuration file must not report a clean 'Completed' run
    # with zero resources - that is indistinguishable from a successful run and hides the
    # real problem (#15).
    if ($null -eq $pipeline) {
        throw "[Start-DscRunner] The configuration file '$FilePath' is empty or contains no readable content."
    }

    $pipelineKeyCount = if ($pipeline -is [System.Collections.IDictionary]) { $pipeline.Keys.Count }
                        else { @($pipeline.PSObject.Properties).Count }

    if ($pipelineKeyCount -eq 0) {
        throw "[Start-DscRunner] The configuration file '$FilePath' parsed to an empty document; expected at least a 'resources' section."
    }

    # Structural problems are reported by name, before any resource is touched, rather than as
    # a binder error from deep inside a helper.
    if ($null -eq $pipeline.resources) {
        throw "[Start-DscRunner] The configuration file '$FilePath' has no 'resources' section (or it is empty); expected a list of resources."
    }
    foreach ($mappingSection in 'variables', 'parameters') {
        $sectionValue = $pipeline.$mappingSection
        if ($null -ne $sectionValue -and $sectionValue -isnot [System.Collections.IDictionary]) {
            throw "[Start-DscRunner] The '$mappingSection' section of '$FilePath' must be a mapping of names to values, not a $($sectionValue.GetType().Name)."
        }
    }

    # A PipelineRunnerSettings block in a configuration file is INERT: the runner's settings come
    # from -RunnerSettings, which Invoke-DscRunner resolves from Datum.yml before the compile or
    # takes from a passthrough caller. The compile strips the block by design, so finding one here
    # means someone handed the runner a hierarchy file instead of a compiled one, or left the block
    # in a document they wrote - and silence would let them believe those settings took effect.
    # Warned once per document (this runs once per file), and not an error: the document is
    # otherwise valid.
    $settingsBlock = $null
    if ($pipeline -is [System.Collections.IDictionary]) {
        foreach ($pipelineKey in @($pipeline.Keys)) {
            if ([string]$pipelineKey -ieq 'PipelineRunnerSettings') { $settingsBlock = $pipeline[$pipelineKey]; break }
        }
    }
    elseif ($null -ne $pipeline -and $pipeline.PSObject.Properties['PipelineRunnerSettings']) {
        $settingsBlock = $pipeline.PipelineRunnerSettings
    }
    if ($null -ne $settingsBlock) {
        Write-Warning "[Start-DscRunner] '$([System.IO.Path]::GetFileName($FilePath))' carries a PipelineRunnerSettings block. It is IGNORED: a configuration file's settings are never read from the file itself. A compiled configuration has no such block (the compile strips it), and a run's settings come from Datum.yml for a compiled run or from Invoke-DscRunner -RunnerSettings for a passthrough one. Move these settings to -RunnerSettings, or compile this configuration through Datum, or remove the block."
    }

    # Clear any existing data in these hashtables before populating them
    $parameters.Clear()
    $variables.Clear()
    $references.Clear()
    Write-Verbose "Cleared existing data in parameters, variables, and references hashtables"

    # Run preamble — a single legible block at the top of the log (#30).
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "Processing configuration file: $FilePath" -Tags $infoTag
    Write-Information "Mode: $Mode" -Tags $infoTag
    Write-Information "Engine: $resolvedEngine" -Tags $infoTag
    Write-Information "Report Path: $ReportPath" -Tags $infoTag
    Write-Information "---------------------------------------------------------------------" -Tags $infoTag
    Write-Information "--> Setting Variables:" -Tags $infoTag

    # Retrieve default values for parameters and set variables based on the pipeline's content.
    # The pipeline's parameter default values must land in $parameters so that later
    # property/variable expansion (Expand-HashTable) and conditions can resolve them; a prior
    # refactor left the result bound to an unused local and fed a $null source to $parameters,
    # so parameter defaults never took effect. Bind the defaults to $parameters directly.
    $defaultValues = GetDefaultValues -Source $pipeline.parameters

    SetVariables -Source $pipeline.variables -Target $variables
    SetVariables -Source $defaultValues -Target $parameters

    Write-Verbose "Retrieved default values for parameters and set variables based on pipeline content"

    Write-Information "--> Expanding notify declarations:" -Tags $infoTag

    # notify/using(): fold each resource's `notify` into its target's DependsOn *before* the
    # dependency sort runs, so the same topological sort (and its cycle detection) also governs
    # notify-induced ordering. Must run before Sort-DependsOn below.
    Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Expand-NotifyDependsOn" | Out-Null

    # Build the source-resource-key -> notify-targets map that using() consults to gate access.
    # Built from the unsorted resources - identity, not order, is what matters here.
    foreach ($notifySource in $pipeline.resources) {
        if (-not $notifySource.Notify) { continue }
        $notifySourceKey = "$($notifySource.type)/$($notifySource.name)"
        $script:notifyDeclarations[$notifySourceKey] = @($notifySource.Notify | ForEach-Object { $_.Trim() })
    }
    Write-Verbose "Built notify declaration map for $($script:notifyDeclarations.Count) resource(s)"

    Write-Information "--> Sorting tasks based on dependencies:" -Tags $infoTag

    # Sort the tasks based on their dependencies to ensure correct execution order
    $tasks = Invoke-CustomTask -Tasks $pipeline.resources -CustomTaskName "Sort-DependsOn"
    Write-Verbose "Sorted tasks based on dependencies"

    # Invoke the PreParse the rules to process the tasks before formatting them
    Write-Information "--> Processing PreParse Rules:" -Tags $infoTag

    # Invoke the PreParse the rules to process the tasks before formatting them. The rules get the
    # configuration's settings plus the engine this run resolved to (an explicit -Engine overrides
    # the configuration's own Engine), so a rule can validate for the engine that will really run.
    $preParseSettings = @{}
    if ($RunnerSettings) { foreach ($settingKey in $RunnerSettings.Keys) { $preParseSettings[$settingKey] = $RunnerSettings[$settingKey] } }
    $preParseSettings['ResolvedEngine'] = [string]$resolvedEngine
    Invoke-PreParseRules -Tasks $pipeline.resources -Settings $preParseSettings

    # Invoke the Format Tasks Rules
    Write-Information "--> Processing Formatting Tasks:" -Tags $infoTag

    # Format the tasks based on the configuration rules
    $tasks = Invoke-FormatTasks -Tasks $tasks

    $totalTasks = @($tasks).Count

    # Report Task Counter
    $TaskCounter = 0

    # Run context for the nodeName() / configurationFile() accessors. Held in module-script
    # scope for the same reason $script:currentResourceKey is: the accessors are called from a
    # script block created by [scriptblock]::Create, which does not see this function's locals.
    # Set here, immediately before the try whose finally clears it, so a run that throws while
    # loading the file never leaves stale context behind for the next one.
    $script:currentNodeName          = $nodeName
    $script:currentConfigurationFile = $FilePath

    # Dry run (-Mode DryRun): the resultant configuration (RSOP) for this file, built up as each
    # resource is checked. Nothing in a dry run calls an engine, a Target or a Credential action.
    $rsopResources = [System.Collections.Generic.List[object]]::new()
    # Accessors that read state which only exists once resources have run. A dry run cannot
    # evaluate an expression that uses one; it validates it and reports it as deferred.
    $runtimeAccessorPattern = '\b(reference|using|result|stopProcessing)\s*(\(|''|")'
    # Whether Actions/<Hook>/<Name>.ps1 exists, by the same naming rule Invoke-Action enforces.
    $actionExists = {
        param($Hook, $Name)
        if ([string]$Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or [string]$Name -match '\.\.') { return $false }
        $actionsBase = (Get-Module 'Dsc.PipelineRunner').ModuleBase
        if ([string]::IsNullOrWhiteSpace([string]$actionsBase)) { return $false }
        return (Test-Path -LiteralPath ([System.IO.Path]::Combine([string]$actionsBase, 'Actions', [string]$Hook, ("{0}.ps1" -f $Name))) -PathType Leaf)
    }
    # Every string inside a property tree, at any depth.
    $collectStrings = {
        param($Value)
        if ($Value -is [string]) { $Value }
        elseif ($Value -is [System.Collections.IDictionary]) { foreach ($entryValue in @($Value.Values)) { & $collectStrings $entryValue } }
        elseif ($Value -is [System.Collections.IEnumerable]) { foreach ($item in $Value) { & $collectStrings $item } }
    }

    # Capability policy (#86 Part B). $policyProvenance stays $null when no policy is set.
    $policyProvenance = $null
    $policyExpressionTargets = @{}
    # A short identifier for the policy, for messages. Defensive about the length: a direct caller
    # may hand over a hashtable this module did not build.
    $policyFingerprint = if ($Policy) {
        $sha = [string]$Policy.Sha256
        if ($sha.Length -ge 12) { $sha.Substring(0, 12) } elseif ($sha) { $sha } else { 'unknown' }
    }
    else { 'unknown' }

    try {
        # Before anything runs: every policy violation in this file, in one pass. A file that
        # breaks the policy does not start. This applies to a dry run too; it is validation.
        if ($Policy) {
            $policyCheck = Get-RunPolicyViolation -Policy $Policy -FilePath $FilePath -Task @($tasks) -DefaultTargetAction $defaultTargetAction -Engine ([string]$resolvedEngine) -HasEngineAction:([bool]$EngineAction)
            if ($policyCheck.Violations.Count -gt 0) {
                # Name the node and the policy that refused it: a pipeline log shows this message
                # on its own, often for one of several nodes, and 'which policy, which node' is
                # the first thing the reader needs.
                throw "Capability policy: $($policyCheck.Violations.Count) violation(s) in node '$nodeName'; no resource was run. Policy: '$($Policy.Path)' ($policyFingerprint).`n  - $($policyCheck.Violations -join "`n  - ")"
            }
            $policyProvenance = $policyCheck.Provenance
            $policyExpressionTargets = $policyCheck.ExpressionTargets
            Write-Information "Capability policy: the file complies (policy $policyFingerprint)." -Tags $infoTag
        }

        if ($Mode -eq 'DryRun' -and -not $EngineAction -and -not (& $actionExists 'Engine' $resolvedEngine)) {
            throw "The engine '$resolvedEngine' does not exist (no Actions/Engine/$resolvedEngine.ps1)."
        }

        # Loop through each task/resource and process it according to its configuration
        foreach ($task in $tasks) {

            # Increment the task counter
            $TaskCounter++

            # A resource that is not a mapping with a 'Module/Resource' type and a scalar name
            # cannot be identified, ordered or reported. Record it as a failure and carry on,
            # rather than letting it abort the file mid-run (after earlier resources may already
            # have been applied) or run as something other than what was written.
            $taskIsMalformed = ($null -eq $task) -or ($task -is [string]) -or ($task -is [ValueType]) -or
                ($task.type -isnot [string]) -or ($task.type -notmatch '^[^/\s]+/[^/\s]+') -or
                ($null -eq $task.name) -or ($task.name -is [System.Collections.IDictionary]) -or
                (($task.name -is [System.Collections.IEnumerable]) -and ($task.name -isnot [string])) -or
                [string]::IsNullOrWhiteSpace([string]$task.name)
            if ($taskIsMalformed) {
                $secretValues.Clear()
                $malformedMessage = "Resource #$TaskCounter is malformed: 'type' must be a 'Module/Resource' string and 'name' a non-empty scalar."
                & $recordResult ([string]$task.type) "<malformed resource #$TaskCounter>" 'FAIL' 0 $malformedMessage
                Write-Error "[Start-DscRunner] $malformedMessage" -ErrorAction Continue
                Write-Information ("[{0}/{1}] FAIL resource #{0} (malformed)" -f $TaskCounter, $totalTasks) -Tags $infoTag
                continue
            }

            $secretValues.Clear()
            $resourceKey = "$($task.type)/$($task.name)"
            # $resourceKey stays raw: it is the identity used by notify/using(). $logKey is the
            # same text made safe to print.
            $logKey = & $safeText $resourceKey
            $resourceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            # Reset per-resource state so a value from a previous iteration is never
            # misattributed to this one (#57 §3/§4 - read by $recordResult above).
            $targetAction = $defaultTargetAction
            $session = $null
            $result = $null

            # notify/using(): identify the resource currently being evaluated so using() knows
            # who is calling it once properties are expanded below.
            $script:currentResourceKey = $resourceKey

            Write-Verbose "Processing resource: [$logKey]"

            # Dry run: check everything about this resource that can be checked without touching
            # an engine, a target or a secret, record what would happen, and move on.
            if ($Mode -eq 'DryRun') {
                $dryProblems = [System.Collections.Generic.List[string]]::new()
                $dryDeferred = [System.Collections.Generic.List[string]]::new()
                $wouldRun = $true
                $preConditionOutcome = $null

                # preCondition: validated always; evaluated unless it reads run-time state.
                $dryPreCondition = if ($null -ne $task.preCondition) { $task.preCondition } elseif ($null -ne $task.Condition) { $task.Condition } else { $null }
                if ($null -ne $dryPreCondition) {
                    try {
                        Assert-SafeConditionExpression -Expression $dryPreCondition
                        if ([string]$dryPreCondition -match $runtimeAccessorPattern) {
                            $dryDeferred.Add('preCondition')
                            $preConditionOutcome = 'Deferred'
                        }
                        else {
                            $dryConditionResult = & ([scriptblock]::Create((ConvertTo-NormalizedConditionExpression -Expression $dryPreCondition)))
                            if ($dryConditionResult -eq $false) { $wouldRun = $false; $preConditionOutcome = 'False' } else { $preConditionOutcome = 'True' }
                        }
                    }
                    catch { $dryProblems.Add("preCondition: $((& $safeText $_.Exception.Message))") }
                }

                # Properties: parameter tokens are always resolved. Expressions are evaluated
                # unless one reads run-time state, in which case each is validated instead.
                $dryProperties = $null
                try {
                    $dryParameterised = Expand-Parameters -InputHashTable $task.properties
                    $dryStrings = @(& $collectStrings $dryParameterised)
                    if (@($dryStrings | Where-Object { $_ -match $runtimeAccessorPattern }).Count -gt 0) {
                        $dryDeferred.Add('properties')
                        foreach ($dryString in $dryStrings) { $null = Expand-SafeString -Value $dryString -ValidateOnly }
                        $dryProperties = ConvertTo-ReportState -InputObject $dryParameterised
                    }
                    else {
                        $dryExpanded = Expand-HashTable -InputHashTable $dryParameterised
                        & $collectSecrets $dryExpanded
                        $dryProperties = ConvertTo-ReportState -InputObject $dryExpanded -SecretValue $secretValues.ToArray()
                    }
                }
                catch { $dryProblems.Add("properties: $((& $safeText $_.Exception.Message))") }

                # postCondition reads result(), so it can only be validated.
                if ($null -ne $task.postCondition) {
                    try {
                        Assert-SafeConditionExpression -Expression $task.postCondition -AllowStopProcessing
                        $dryDeferred.Add('postCondition')
                    }
                    catch { $dryProblems.Add("postCondition: $((& $safeText $_.Exception.Message))") }
                }

                # Execution scripts are not run; a script that does not parse is reported.
                foreach ($scriptKey in 'preExecutionScript', 'postExecutionScript') {
                    if ($null -ne $task.$scriptKey) {
                        $scriptParseErrors = $null
                        $null = [System.Management.Automation.Language.Parser]::ParseInput([string]$task.$scriptKey, [ref]$null, [ref]$scriptParseErrors)
                        if ($scriptParseErrors -and $scriptParseErrors.Count -gt 0) { $dryProblems.Add("${scriptKey}: does not parse ($((& $safeText $scriptParseErrors[0].Message)))") }
                    }
                }

                # Target and credentials: shape and action names are checked. Nothing is
                # connected to and no secret is fetched.
                $dryTargetAction = $defaultTargetAction
                $dryComputerName = $null
                $dryCredentialActions = [System.Collections.Generic.List[string]]::new()
                if ($null -ne $task.target) {
                    if ($task.target -isnot [System.Collections.IDictionary]) {
                        $dryProblems.Add("target: must be a mapping (action, computerName, credential), not a $($task.target.GetType().Name)")
                    }
                    else {
                        if (-not [string]::IsNullOrWhiteSpace([string]$task.target.action)) { $dryTargetAction = [string]$task.target.action }
                        $dryComputerName = if ($null -ne $task.target.computerName) { & $safeText ([string]$task.target.computerName) } else { $null }
                        if ($null -ne $task.target.credential) {
                            if ($task.target.credential -isnot [System.Collections.IDictionary]) { $dryProblems.Add('target.credential: must be a mapping') }
                            else { $dryCredentialActions.Add($(if (-not [string]::IsNullOrWhiteSpace([string]$task.target.credential.action)) { [string]$task.target.credential.action } else { 'Environment' })) }
                        }
                    }
                }
                if (-not (& $actionExists 'Target' $dryTargetAction)) { $dryProblems.Add("target: the action '$((& $safeText $dryTargetAction))' does not exist") }
                if ($null -ne $task.resourceCredential) {
                    if ($task.resourceCredential -isnot [System.Collections.IDictionary]) { $dryProblems.Add('resourceCredential: must be a mapping') }
                    else { $dryCredentialActions.Add($(if (-not [string]::IsNullOrWhiteSpace([string]$task.resourceCredential.action)) { [string]$task.resourceCredential.action } else { 'Environment' })) }
                }
                foreach ($dryCredentialAction in $dryCredentialActions) {
                    if (-not (& $actionExists 'Credential' $dryCredentialAction)) { $dryProblems.Add("credential: the action '$((& $safeText $dryCredentialAction))' does not exist") }
                }

                $targetAction = $dryTargetAction
                $dryStatus = if ($dryProblems.Count -gt 0) { 'FAIL' } elseif (-not $wouldRun) { 'SKIP' } else { 'OK' }
                $dryMessage = if ($dryProblems.Count -gt 0) { $dryProblems -join '; ' } elseif (-not $wouldRun) { "Would be skipped by preCondition {$dryPreCondition}." } else { $null }

                $rsopResources.Add([ordered]@{
                        Order               = $TaskCounter
                        Type                = [string]$task.type
                        Name                = [string]$task.name
                        Status              = $dryStatus
                        WouldRun            = ($wouldRun -and $dryProblems.Count -eq 0)
                        PreCondition        = $preConditionOutcome
                        Deferred            = @($dryDeferred)
                        Problems            = @($dryProblems)
                        Target              = $dryTargetAction
                        ComputerName        = $dryComputerName
                        CredentialActions   = @($dryCredentialActions | Select-Object -Unique)
                        DependsOn           = @($task.dependsOn | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                        Notify              = @($task.notify | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                        HasExecutionScripts = ($null -ne $task.preExecutionScript -or $null -ne $task.postExecutionScript)
                        Properties          = $dryProperties
                    })

                $resourceStopwatch.Stop()
                & $recordResult $task.type $task.name $dryStatus $resourceStopwatch.ElapsedMilliseconds $dryMessage
                if ($dryStatus -eq 'FAIL') { Write-Error "[Start-DscRunner] Dry run: resource [$logKey] is not valid: $dryMessage" -ErrorAction Continue }
                Write-Information ("[{0}/{1}] {2} {3} (dry run{4})" -f $TaskCounter, $totalTasks, $dryStatus, $logKey, $(if ($dryDeferred.Count -gt 0) { '; deferred: ' + ($dryDeferred -join ', ') } else { '' })) -Tags $infoTag
                continue
            }

            # If the StopTaskProcessing variable is set to true, stop processing the tasks
            if ($Script:StopTaskProcessing) {
                Write-Verbose "Skipping resource due to 'Stop-TaskProcessing' being called:"
                $runStatus = 'StoppedByRequest'
                & $recordResult $task.type $task.name 'SKIP' 0 "Resource skipped due to 'Stop-TaskProcessing' cmdlet."
                Write-Information ("[{0}/{1}] SKIP {2} (stopped by request)" -f $TaskCounter, $totalTasks, $logKey) -Tags $infoTag
                continue
            }

            # Evaluate the Condition script block if it exists, and skip the task if the condition returns false.
            # The function-language accessors permitted by Assert-SafeConditionExpression
            # (parameters()/variables()/reference()) are designed to throw on a missing
            # key/reference; wrap evaluation in the same per-resource try/catch used elsewhere in
            # this loop so a throwing condition fails only this resource instead of aborting the
            # rest of the file.
            # #57 §2: 'preCondition' is the current name; 'condition' is kept as a back-compat
            # alias (with a one-line deprecation warning) so an existing configuration keeps
            # working unchanged. preCondition wins when a resource somehow carries both.
            $preConditionExpression = $null
            if ($null -ne $task.preCondition) {
                $preConditionExpression = $task.preCondition
            }
            elseif ($null -ne $task.Condition) {
                Write-Warning "[Start-DscRunner] Resource [$logKey] uses the deprecated 'condition' key; rename it to 'preCondition'."
                $preConditionExpression = $task.Condition
            }

            if ($null -ne $preConditionExpression) {

                try {
                    # A preCondition is a predicate, not a program: reject any command, assignment
                    # or method call before it runs, so configuration code cannot use it to mutate
                    # the runner's state or its audit record (#35).
                    Assert-SafeConditionExpression -Expression $preConditionExpression

                    # Create a script block from the preCondition property. Normalized the same
                    # way it was validated (#57 §2 - see ConvertTo-NormalizedConditionExpression);
                    # a no-op for anything that isn't the result()/stopProcessing() syntax, which
                    # is rejected for preCondition anyway.
                    $sbCondition = [scriptblock]::Create((ConvertTo-NormalizedConditionExpression -Expression $preConditionExpression))

                    # Invoke with the call operator (&), not dot-sourcing (.), so the block runs in a
                    # child scope. It can still read the runner's variables through dynamic scoping
                    # (which is all the example configurations need), but any assignment it makes stays
                    # local instead of overwriting Start-DscRunner's own state (#35).
                    $conditionResult = & $sbCondition
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not evaluate the preCondition of resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds (& $safeText $_.Exception.Message)
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $_.Exception.Message)) -Tags $infoTag
                    continue
                }

                if ($conditionResult -eq $false) {

                    Write-Verbose "Skipping resource due to preCondition: [$logKey]"
                    & $recordResult $task.type $task.name 'SKIP' $resourceStopwatch.ElapsedMilliseconds "Resource skipped due to preCondition {$preConditionExpression}."
                    Write-Information ("[{0}/{1}] SKIP {2} (preCondition)" -f $TaskCounter, $totalTasks, $logKey) -Tags $infoTag
                    continue

                }
            }

            # Extract the module name and resource type from the task's type property
            $typeParts = $task.type.Split("/")
            $module = $typeParts[0]
            $resourceType = $typeParts[1]
            Write-Verbose "Extracted module name: $module and resource type: $resourceType"

            $resourceStatus = 'OK'
            $resourceError = $null

            # Capability policy, at the point of use: a resourceCredential resolves a secret out
            # of a vault, an environment variable or the configuration and injects it into the
            # resource's properties. Checked before the properties are touched, so nothing is read
            # for a resource whose layers may not use that Credential action.
            if ($Policy -and $policyProvenance -and $null -ne $task.resourceCredential) {
                $policyCredentialAction = if ($task.resourceCredential -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$task.resourceCredential.action)) { [string]$task.resourceCredential.action } else { 'Environment' }
                $policyCredentialMessage = Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $policyProvenance -ResourceKey $resourceKey -Capability 'Credentials' -Value $policyCredentialAction -Subject 'the Credential action'
                if ($policyCredentialMessage) {
                    Write-Error "[Start-DscRunner] $policyCredentialMessage" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $policyCredentialMessage
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $policyCredentialMessage)) -Tags $infoTag
                    continue
                }
            }

            # Resolve the properties in two passes. Expand-Parameters runs first and does
            # whole-scalar substitution of `<params=Name>` tokens, so a parameter keeps its
            # type (a number stays a number, a hashtable stays a hashtable). Expand-HashTable
            # then runs string interpolation over the result, so a parameter value that
            # itself contains $(...) or a $variable reference still expands.
            #
            # An unresolvable token is this resource's failure, not the run's: expansion is
            # inside the same guard as the engine call so one bad property does not abort the
            # remaining tasks.
            try {
                $Property = Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable $task.properties)
                Write-Verbose "Replaced parameters and variables in properties with actual values"

                # #57 §7: a declarative 'resourceCredential' block resolves a credential through
                # the Credential hook and injects it into the resource's own properties (e.g. a
                # SqlServerDsc resource's -Credential), so the credential never needs to appear in
                # the configuration itself. Runs even when AllowExecutionScripts is off - it is
                # declarative, not a script, so the execution-scripts gate does not apply to it.
                if ($null -ne $task.resourceCredential) {
                    $credentialContext = $task.resourceCredential
                    $credentialActionName = if (-not [string]::IsNullOrWhiteSpace([string]$credentialContext.action)) { [string]$credentialContext.action } else { 'Environment' }
                    $resolvedResourceCredential = Invoke-Action -Hook Credential -Name $credentialActionName -Context $credentialContext
                    $targetPropertyName = if (-not [string]::IsNullOrWhiteSpace([string]$credentialContext.propertyName)) { [string]$credentialContext.propertyName } else { 'Credential' }
                    $Property[$targetPropertyName] = $resolvedResourceCredential
                    Write-Verbose "Resolved resourceCredential via Credential action '$credentialActionName' into property '$targetPropertyName' for resource: [$logKey]"
                }

                # Everything secret about this resource is now known; from here on, any message
                # that mentions it is scrubbed by $safeText.
                & $collectSecrets $Property
            }
            catch {
                Write-Error "[Start-DscRunner] Could not resolve the properties of resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds (& $safeText $_.Exception.Message)
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $_.Exception.Message)) -Tags $infoTag
                continue
            }

            # #57 §4: resolve this resource's execution target. A per-resource 'target' block
            # overrides the file-level default (PipelineRunnerSettings.Target / 'Local'). Session
            # objects are cached per (action, computer, credential) so resources sharing a target
            # reuse one connection; 'Local' never invokes the Target hook at all, so an
            # unmodified configuration's local-only execution path is untouched.
            # 'target' must be a mapping (action / computerName / credential). A scalar such as
            # `target: WinRM` has no .action, which would silently fall back to Local and apply a
            # resource meant for a remote host to the machine running the pipeline.
            if ($null -ne $task.target -and ($task.target -is [string] -or $task.target -is [ValueType] -or $task.target -is [System.Collections.IList])) {
                $targetShapeMessage = "The 'target' of resource [$logKey] must be a mapping (action, computerName, credential), not a $($task.target.GetType().Name)."
                Write-Error "[Start-DscRunner] $targetShapeMessage" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $targetShapeMessage
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $targetShapeMessage)) -Tags $infoTag
                continue
            }

            $targetAction = if ($task.target -and -not [string]::IsNullOrWhiteSpace([string]$task.target.action)) { [string]$task.target.action } else { $defaultTargetAction }

            # Capability policy, at the point of use: the Target that is really about to be used.
            if ($Policy -and $policyProvenance) {
                $policyTargetMessage = Test-ResourceTargetPolicy -Policy $Policy -Provenance $policyProvenance -ResourceKey $resourceKey -TargetAction $targetAction -FromExpression:([bool]$policyExpressionTargets[$resourceKey])
                if ($policyTargetMessage) {
                    Write-Error "[Start-DscRunner] $policyTargetMessage" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $policyTargetMessage
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $policyTargetMessage)) -Tags $infoTag
                    continue
                }
            }

            # Capability policy, at the point of use: the machine this resource is about to reach
            # and the Credential action it is about to resolve. The pre-run check saw the same
            # literal text - the runner expands expressions in a resource's properties only,
            # never inside its 'target' block - so this is mostly defence in depth. It is the
            # only gate for a resource whose Target action was not knowable before the run: that
            # widens the question to every layer that contributed to the node, any of which could
            # have supplied the value, and a machine one of them may not reach is refused here.
            if ($Policy -and $policyProvenance -and $targetAction -ne 'Local') {
                $policyUseMessage = Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $policyProvenance -ResourceKey $resourceKey `
                    -Capability 'RemoteTargets' -Value ([string]$task.target.computerName) -Subject 'the remote Target computer' `
                    -FromExpression:([bool]$policyExpressionTargets[$resourceKey])

                if (-not $policyUseMessage -and $task.target.credential) {
                    $policyTargetCredentialAction = if ($task.target.credential -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$task.target.credential.action)) { [string]$task.target.credential.action } else { 'Environment' }
                    $policyUseMessage = Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $policyProvenance -ResourceKey $resourceKey `
                        -Capability 'Credentials' -Value $policyTargetCredentialAction -Subject 'the Credential action'
                }

                if ($policyUseMessage) {
                    Write-Error "[Start-DscRunner] $policyUseMessage" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds $policyUseMessage
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $policyUseMessage)) -Tags $infoTag
                    continue
                }
            }

            if ($targetAction -ne 'Local') {
                try {
                    $targetCredential = $null
                    $credentialCacheKey = ''
                    if ($task.target.credential) {
                        $tCred = $task.target.credential
                        $tCredAction = if (-not [string]::IsNullOrWhiteSpace([string]$tCred.action)) { [string]$tCred.action } else { 'Environment' }
                        $targetCredential = Invoke-Action -Hook Credential -Name $tCredAction -Context $tCred
                        if ($targetCredential -is [System.Management.Automation.PSCredential]) { & $collectSecrets @{ TargetCredential = $targetCredential } }
                        # Key the session cache on every non-secret credential setting (user name,
                        # vault, variable names...), not just Name/UserNameVariable: two resources
                        # on one host with different Static or SecretManagement identities must not
                        # share a session, or the second would run as the first's identity. The
                        # Password itself is left out so a plaintext Static value never becomes part
                        # of an in-memory key.
                        $credentialKeyParts = foreach ($credentialKey in @($tCred.Keys | Sort-Object)) {
                            if ([string]$credentialKey -ne 'Password') { '{0}={1}' -f $credentialKey, $tCred[$credentialKey] }
                        }
                        $credentialCacheKey = "$tCredAction|$($credentialKeyParts -join ';')"
                    }

                    # configurationName selects the remote endpoint a WinRM PSSession lands on.
                    # It is part of the cache key because two resources naming the same computer
                    # but different endpoints need different sessions.
                    $targetContext = @{
                        ComputerName      = [string]$task.target.computerName
                        Engine            = $resolvedEngine
                        Credential        = $targetCredential
                        ConfigurationName = [string]$task.target.configurationName
                    }

                    $sessionCacheKey = "$targetAction|$($targetContext.ComputerName)|$($targetContext.ConfigurationName)|$credentialCacheKey"
                    if (-not $sessionCache.ContainsKey($sessionCacheKey)) {
                        Write-Verbose "Opening new '$targetAction' session for target: [$($targetContext.ComputerName)]"
                        $sessionCache[$sessionCacheKey] = Invoke-Action -Hook Target -Name $targetAction -Context $targetContext
                    }
                    $session = $sessionCache[$sessionCacheKey]
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not establish the '$targetAction' target for resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                    & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds (& $safeText $_.Exception.Message)
                    Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $_.Exception.Message)) -Tags $infoTag
                    continue
                }
            }
            if ($session) { $engineArgs.Session = $session } else { $engineArgs.Remove('Session') }

            # #57 §2: preExecutionScript runs immediately before the Test/Set evaluation.
            # Mirrors postExecutionScript's execution model (invoked with &, not dot-sourced, so
            # it cannot rewrite Start-DscRunner's own locals - #35) but runs first, so it can
            # prepare state the resource's Test/Set depends on. Gated by PipelineRunnerSettings.
            # AllowExecutionScripts at PreParse time (Test-ExecutionScriptsAllowed.ps1); if the
            # run got this far with a preExecutionScript present, execution scripts are allowed.
            if ($null -ne $task.preExecutionScript) {
                $sbPreExecutionScript = [scriptblock]::Create($task.preExecutionScript)
                & $sbPreExecutionScript
            }

            # Execute the 'Test' method to determine if the state is as desired.
            # The resource is evaluated through the selected engine (DscV2 / DscV3 / custom),
            # which returns a normalized [DscMethodResult] regardless of the underlying tool.
            # A single resource that throws must not abort the entire run, so trap the
            # error, record it as a failed resource, and move on to the next task.
            try {
                $result = Invoke-EngineAction -Method 'Test' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                Write-Verbose "Executed 'Test' method for DSC resource: [$logKey]"
            }
            catch {
                Write-Error "[Start-DscRunner] 'Test' method failed for resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                & $recordResult $task.type $task.name 'FAIL' $resourceStopwatch.ElapsedMilliseconds (& $safeText $_.Exception.Message)
                Write-Information ("[{0}/{1}] FAIL {2} ({3}ms) - {4}" -f $TaskCounter, $totalTasks, $logKey, $resourceStopwatch.ElapsedMilliseconds, (& $safeText $_.Exception.Message)) -Tags $infoTag
                # Skip Set/Get for this resource and continue with the remaining tasks
                continue
            }

            # notify/using(): a resource that a genuinely-changed notifier notifies is forced to
            # re-run Set() this pass even if its own Test() reports it is already in the desired
            # state (Puppet/Chef notify semantics). $neededChange records the engine's own
            # verdict before any forcing is applied, since that (not the forced re-run) is what
            # determines whether this resource's own notify targets should in turn be forced.
            $neededChange = -not $result.InDesiredState
            $setInvoked = $false
            $forcedByNotify = ($Mode -eq "Set") -and $script:pendingNotifyRefresh.Contains($resourceKey)
            if ($forcedByNotify -and -not $neededChange) {
                Write-Verbose "Resource forced to re-run Set() by a notify from a changed resource: [$logKey]"
            }

            # If not in the desired state and Mode is 'Set', execute the 'Set' method to apply changes
            if ($result.InDesiredState -and -not $forcedByNotify) {
                Write-Verbose "Resource is in the desired state: [$logKey]"
                $resourceStatus = 'OK'
            }
            elseif ($Mode -eq "Set") {

                try {
                    $setInvoked = $true
                    $result = Invoke-EngineAction -Method 'Set' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                    Write-Verbose "Executed 'Set' method to make changes: [$logKey]"
                    $resourceStatus = 'OK'

                    # #57 §3: reboot handling. A remote target restarts itself and waits for
                    # PowerShell to come back before the run continues, regardless of the reboot
                    # policy - it is the target, not the runner's own host, that comes back up.
                    # A local target cannot safely do this in-process (restarting the machine the
                    # runner itself is on would kill the run mid-file), so it fails the resource
                    # and stops the rest of the file unless the policy explicitly says to ignore it.
                    if ($result.RebootRequired) {
                        # Capability policy: restarting a machine is the most disruptive thing the
                        # runner does, and the only one it does on its own initiative. A layer
                        # without the Reboot capability gets a failed resource instead, with the
                        # target left running and its Set() already applied.
                        $policyRebootMessage = $null
                        if ($Policy -and $policyProvenance -and $session -and $session.IsRemote) {
                            $policyRebootMessage = Test-ResourceCapabilityPolicy -Policy $Policy -Provenance $policyProvenance -ResourceKey $resourceKey -Capability 'Reboot' -Subject 'a restart of its remote Target'
                        }
                        if ($policyRebootMessage) {
                            $resourceStatus = 'FAIL'
                            $resourceError = "$policyRebootMessage The resource's Set() has already been applied; the target was not restarted, so it may need one before it is in the desired state."
                            Write-Error "[Start-DscRunner] $resourceError" -ErrorAction Continue
                        }
                        elseif ($session -and $session.IsRemote) {
                            Write-Information "Reboot required on remote target [$($session.ComputerName)] after resource [$logKey]; restarting and waiting..." -Tags $infoTag
                            $restartParams = @{ ComputerName = $session.ComputerName; Wait = $true; Force = $true; ErrorAction = 'Stop' }
                            if ($task.target.credential -and $session.PSSession -and $session.PSSession.Credential) {
                                $restartParams.Credential = $session.PSSession.Credential
                            }
                            Restart-Computer @restartParams
                            Write-Verbose "Remote target [$($session.ComputerName)] is back; continuing."
                        }
                        elseif ($rebootPolicy -eq 'Ignore') {
                            Write-Information "Resource [$logKey] requires a reboot; PipelineRunnerSettings.Reboot is 'Ignore', continuing without restarting." -Tags $infoTag
                        }
                        else {
                            $resourceStatus = 'FAIL'
                            $resourceError = "Resource [$logKey] requires a reboot to complete, and the local host cannot safely restart itself mid-run. Set PipelineRunnerSettings.Reboot: Ignore to continue without restarting, or target this resource at a remote computer (#57 §4) to have the runner restart it and wait automatically."
                            Write-Error "[Start-DscRunner] $resourceError" -ErrorAction Continue
                            $script:StopTaskProcessing = $true
                        }
                    }
                }
                catch {
                    # -ErrorAction Continue keeps this non-terminating even when a caller
                    # runs under $ErrorActionPreference='Stop' (e.g. an advanced-function
                    # wrapper), so one failed 'Set' does not abort the whole run.
                    Write-Error "[Start-DscRunner] Failed to apply changes with 'Set' method: [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                    $resourceStatus = 'FAIL'
                    $resourceError = (& $safeText $_.Exception.Message)
                }
            }
            else {
                # Drift detected in Test mode: the resource is not in the desired state.
                Write-Verbose "Change needed, but mode is not set to 'Set': [$logKey]"
                $resourceStatus = 'FAIL'
                $resourceError = $result.Message
            }

            # notify/using(): only a genuine change (this resource's own Test() originally
            # reported drift, not merely a forced-by-notify re-run) that completed successfully
            # propagates a forced refresh onward to whatever this resource itself notifies.
            if ($neededChange -and $resourceStatus -eq 'OK' -and $script:notifyDeclarations.Contains($resourceKey)) {
                foreach ($notifyTarget in $script:notifyDeclarations[$resourceKey]) {
                    Write-Verbose "Resource [$logKey] changed; forcing re-run of notified resource [$notifyTarget]"
                    $script:pendingNotifyRefresh[$notifyTarget] = $true
                }
            }

            # #57 §2: postCondition runs after Test/Set (before postExecutionScript). Unlike
            # preCondition it is not a skip - a $false postCondition marks the resource FAIL
            # regardless of what the engine itself reported, since it is meant to assert
            # something about the outcome (e.g. via result()) that the engine's own
            # InDesiredState does not capture. -AllowStopProcessing permits it (and only it) to
            # call stopProcessing() as well as read result().
            if ($null -ne $task.postCondition) {
                $script:currentResourceResult = $result
                try {
                    Assert-SafeConditionExpression -Expression $task.postCondition -AllowStopProcessing
                    # result()/stopProcessing() do not parse as written - normalize the same text
                    # that was just validated (#57 §2 - see ConvertTo-NormalizedConditionExpression).
                    $sbPostCondition = [scriptblock]::Create((ConvertTo-NormalizedConditionExpression -Expression $task.postCondition))
                    $postConditionResult = & $sbPostCondition
                }
                catch {
                    Write-Error "[Start-DscRunner] Could not evaluate the postCondition of resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                    $resourceStatus = 'FAIL'
                    $resourceError = (& $safeText $_.Exception.Message)
                    $postConditionResult = $null
                }
                finally {
                    $script:currentResourceResult = $null
                }

                if ($postConditionResult -eq $false) {
                    Write-Verbose "Resource failed postCondition: [$logKey]"
                    $resourceStatus = 'FAIL'
                    $resourceError = "Resource failed postCondition {$($task.postCondition)}."
                }
            }

            #
            # Test if the postExecutionScript property exists and execute the script block if it does.
            if ($null -ne $task.postExecutionScript) {
                # Create a script block from the postExecutionScript property
                $sbPostExecutionScript = [scriptblock]::Create($task.postExecutionScript)

                # Invoke in a child scope with the call operator (&) rather than dot-sourcing (.).
                # postExecutionScript is imperative by design and may still read runner variables
                # and call control verbs such as Stop-TaskProcessing (which sets module-scope
                # state, so it keeps working across the scope boundary), but it can no longer
                # reach in and rewrite Start-DscRunner's locals or its report (#35).
                & $sbPostExecutionScript
            }

            # The resource's current state, for reference(), using() and the report. An engine
            # whose Test or Set already reported it (dsc.exe does, in the shape its 'Get'
            # returns) hands it over as CurrentState, and a separate 'Get' would only ask the
            # same question again - one more engine call per resource, which for DSC v3 is one
            # more dsc process. A postExecutionScript may have changed the resource after the
            # engine reported, and a Set that failed may have changed part of it after the Test
            # that $result still holds, so in either case 'Get' still runs.
            $setFailed = $setInvoked -and $resourceStatus -eq 'FAIL'
            if ($null -ne $result.CurrentState -and $null -eq $task.postExecutionScript -and -not $setFailed) {
                $output_var = $result.CurrentState
                Write-Verbose "Took the current state from the '$(if ($setInvoked) { 'Set' } else { 'Test' })' result for DSC resource: [$logKey]"
            }
            else {
                # Execute the 'Get' method to retrieve the current state of the resource.
                # A failed 'Get' should not abort the run; record $null and continue.
                try {
                    $getResult = Invoke-EngineAction -Method 'Get' -ModuleName $module -Name $resourceType -Property $Property @engineArgs
                    # Store the engine's raw current-state output so downstream reference
                    # expansion sees exactly the same shape it did before the engine seam.
                    $output_var = $getResult.Raw
                    Write-Verbose "Retrieved current state with 'Get' method for DSC resource: [$logKey]"
                }
                catch {
                    Write-Error "[Start-DscRunner] 'Get' method failed for resource [$logKey]: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
                    $output_var = $null
                }
            }

            # Store the output of the 'Get' operation in a reference table for later use
            # Indexer, not Add(): two resources may share a name across different types, and a
            # duplicate key must not abort the rest of the file.
            $references[$task.name] = $output_var
            Write-Verbose "Stored output of 'Get' operation in references table for resource: [$logKey]"

            # notify/using(): store the same output keyed by the full "Type/Name" identity, so
            # using() can read it from a resource this one notifies.
            $script:resourceOutputs[$resourceKey] = $output_var

            # Reporting (#85): what happened to this resource beyond its status and, when state
            # capture is on, its desired and actual state. Captured here, while this resource's
            # secrets are still known, and redacted before it is stored: Get() output can hold
            # secrets the configuration never declared. A failure to capture must not fail the
            # resource.
            $resourceDetail = @{ Drifted = [bool]$neededChange; SetInvoked = [bool]$setInvoked; ForcedByNotify = [bool]$forcedByNotify; State = $null }
            if ($reportState -eq 'Full' -or ($reportState -eq 'Drift' -and $neededChange)) {
                try {
                    $capturedState = [ordered]@{
                        Desired = ConvertTo-ReportState -InputObject $Property -SecretValue $secretValues.ToArray()
                        Actual  = ConvertTo-ReportState -InputObject $output_var -SecretValue $secretValues.ToArray()
                    }
                    $capturedLength = ([string]($capturedState | ConvertTo-Json -Depth 20 -Compress)).Length
                    if ($capturedLength -gt $maxStateCharacters) {
                        $capturedState = [ordered]@{ Truncated = $true; Reason = "The captured state was $capturedLength characters; the limit is $maxStateCharacters." }
                    }
                    $resourceDetail.State = $capturedState
                }
                catch {
                    $resourceDetail.State = [ordered]@{ Error = 'The state of this resource could not be captured.' }
                    Write-Verbose "[Start-DscRunner] State capture failed for [$logKey]: $((& $safeText $_.Exception.Message))"
                }
            }
            $resourceDetails[('{0}|{1}|{2}' -f $FilePath, $task.type, $task.name)] = $resourceDetail

            # Record the single, deduplicated outcome for this resource and log one line.
            $resourceStopwatch.Stop()
            & $recordResult $task.type $task.name $resourceStatus $resourceStopwatch.ElapsedMilliseconds $resourceError
            Write-Information ("[{0}/{1}] {2} {3} ({4}ms)" -f $TaskCounter, $totalTasks, $resourceStatus, $logKey, $resourceStopwatch.ElapsedMilliseconds) -Tags $infoTag

        }
    }
    catch {
        # An unexpected exception aborted the loop. Record the run status so the report,
        # written from the finally block below, reflects the partial results.
        $runStatus = 'AbortedByException'
        $runError = (& $safeText $_.Exception.Message)
        Write-Error "[Start-DscRunner] Run aborted by an unexpected error: $((& $safeText $_.Exception.Message))" -ErrorAction Continue
    }
    finally {

        $runStopwatch.Stop()

        # This file is finished, so nodeName() / configurationFile() must stop answering for it.
        $script:currentNodeName          = $null
        $script:currentConfigurationFile = $null

        # Variables exported to the process environment for this file's resources must not
        # outlive it: they would be inherited by every later child process, and by the next file.
        foreach ($exportedName in @($script:RunnerExportedEnv)) {
            Remove-Item -Path "env:$exportedName" -ErrorAction SilentlyContinue
        }
        if ($script:RunnerExportedEnv) { $script:RunnerExportedEnv.Clear() }

        # #57 §4: close every session this run opened, regardless of how the run ended.
        foreach ($cachedSession in $sessionCache.Values) {
            if ($cachedSession.CimSession) {
                Remove-CimSession -CimSession $cachedSession.CimSession -ErrorAction SilentlyContinue
            }
            if ($cachedSession.PSSession) {
                Remove-PSSession -Session $cachedSession.PSSession -ErrorAction SilentlyContinue
            }
        }

        # Summarize from the deduplicated records.
        # One pass over the results instead of four Where-Object pipelines.
        $passCount = 0
        $failCount = 0
        $skipCount = 0
        $failedList = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($record in $results) {
            switch ($record.Status) {
                'OK'   { $passCount++ }
                'FAIL' { $failCount++; $failedList.Add($record) }
                'SKIP' { $skipCount++ }
            }
        }
        $failedResources = $failedList.ToArray()

        # Reporting (#85): the versioned report document. It carries everything the JSON file
        # below has always had, plus the mode, the engine, and per resource whether it drifted,
        # whether Set ran, whether a notify forced it, and (when state capture is on) its
        # redacted desired and actual state. Reporters receive this document; the CSV and JSON
        # files keep their existing shape.
        $reportResults = foreach ($record in $results) {
            $entry = [ordered]@{}
            foreach ($column in $record.PSObject.Properties) { $entry[$column.Name] = $column.Value }
            $detail = $null
            $null = $resourceDetails.TryGetValue(('{0}|{1}|{2}' -f $record.ConfigurationFile, $record.ResourceType, $record.InstanceName), [ref]$detail)
            $entry['Drifted']        = if ($detail) { $detail.Drifted } else { $null }
            $entry['SetInvoked']     = if ($detail) { $detail.SetInvoked } else { $false }
            $entry['ForcedByNotify'] = if ($detail) { $detail.ForcedByNotify } else { $false }
            $entry['State']          = if ($detail) { $detail.State } else { $null }
            $entry
        }
        $reportContract = [ordered]@{
            SchemaVersion     = '1.0'
            NodeName          = $nodeName
            ConfigurationFile = $FilePath
            Mode              = $Mode
            Engine            = $resolvedEngine
            Status            = $runStatus
            TotalResources    = $results.Count
            PassCount         = $passCount
            FailCount         = $failCount
            SkipCount         = $skipCount
            DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
            ErrorMessage      = $runError
            StateCapture      = $reportState
            Results           = @($reportResults)
        }
        # #106: added only when the bypass is in effect, so a compiled run's report document is
        # exactly what it has always been and the two cannot be confused.
        if ($PolicyBypassed) { $reportContract['PolicyBypassed'] = $true }

        # Dry run: the resultant configuration (RSOP). What this file resolves to after the
        # Datum merge, composite expansion, ordering and (where it does not need run-time
        # state) expression evaluation, with secrets redacted. It is part of the report
        # document, is written to <node>.rsop.json, and is returned to the caller.
        $rsopDocument = $null
        if ($Mode -eq 'DryRun') {
            $rsopDocument = [ordered]@{
                SchemaVersion     = '1.0'
                NodeName          = $nodeName
                ConfigurationFile = $FilePath
                Engine            = $resolvedEngine
                DefaultTarget     = $defaultTargetAction
                Settings          = ConvertTo-ReportState -InputObject $RunnerSettings
                Parameters        = ConvertTo-ReportState -InputObject $parameters
                Variables         = ConvertTo-ReportState -InputObject $variables
                Resources         = @($rsopResources)
            }
            $reportContract['Rsop'] = $rsopDocument
        }

        # Always write the report (even on early stop / abort), when a path is supplied.
        if ($ReportPath) {

            Write-Verbose "[Start-DscRunner] Writing report for $FilePath to $ReportPath"

            # [System.IO.Path]::Combine composes the path without resolving a drive
            # qualifier, so a Windows-style ReportPath (e.g. 'C:\Reports') does not throw
            # DriveNotFoundException on a Linux runner.
            $csvPath  = [System.IO.Path]::Combine($ReportPath, ("{0}.csv" -f $nodeName))
            $jsonPath = [System.IO.Path]::Combine($ReportPath, ("{0}.report.json" -f $nodeName))

            # The report is written from this finally block, so a failure to write it must never
            # replace or lose the run result (a throw from here would discard the returned
            # object and skip every remaining node, after resources may already have been
            # applied). Report the problem and carry on.
            try {
                # CSV cells that begin with = + - @ (or a tab / carriage return) are executed as
                # formulas by spreadsheet applications, and a resource name or an error message
                # relayed from a remote target is not trusted. Neutralise them in the CSV only;
                # the JSON report and the returned objects keep the original text. -LiteralPath
                # because a node file name such as 'node[1].yml' is otherwise read as a wildcard.
                $csvRows = foreach ($record in $results) {
                    $row = [ordered]@{}
                    foreach ($column in $record.PSObject.Properties) {
                        $cell = $column.Value
                        if ($cell -is [string] -and $cell -match '^[=+\-@\t\r]') { $cell = "'" + $cell }
                        $row[$column.Name] = $cell
                    }
                    [pscustomobject]$row
                }
                $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation

                $reportDocument = [pscustomobject]@{
                    ConfigurationFile = $FilePath
                    Status            = $runStatus
                    TotalResources    = $results.Count
                    PassCount         = $passCount
                    FailCount         = $failCount
                    SkipCount         = $skipCount
                    DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
                    ErrorMessage      = $runError
                    Results           = $results
                }
                $reportDocument | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath

                # With state capture on, the full report document is written next to them. The
                # two files above are unchanged either way.
                if ($reportState -ne 'None') {
                    $statePath = [System.IO.Path]::Combine($ReportPath, ("{0}.state.json" -f $nodeName))
                    $reportContract | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
                }

                if ($null -ne $rsopDocument) {
                    $rsopPath = [System.IO.Path]::Combine($ReportPath, ("{0}.rsop.json" -f $nodeName))
                    $rsopDocument | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rsopPath
                }
            }
            catch {
                Write-Error "[Start-DscRunner] Could not write the report for '$FilePath' to '$ReportPath': $((& $safeText $_.Exception.Message))" -ErrorAction Continue
            }
        }

        # Reporting (#85): hand the document to each configured reporter. The run's outcome was
        # decided above, so a reporter that fails is reported as its own error and can neither
        # change the result nor stop the remaining reporters or nodes.
        $reporterCalls = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($reporterName in $reporterNames) {
            $reporterSettings = if ($reportSettings[$reporterName] -is [System.Collections.IDictionary]) { $reportSettings[$reporterName] } else { @{} }
            $reporterCalls.Add(@{ Label = $reporterName; Arguments = @{ Hook = 'Report'; Name = $reporterName; Context = @{ Document = $reportContract; Settings = $reporterSettings; NodeName = $nodeName; ReportPath = $ReportPath } } })
        }
        if ($ReportAction) {
            $reporterCalls.Add(@{ Label = '(inline)'; Arguments = @{ Hook = 'Report'; ScriptBlock = $ReportAction; Context = @{ Document = $reportContract; Settings = @{}; NodeName = $nodeName; ReportPath = $ReportPath } } })
        }
        foreach ($reporterCall in $reporterCalls) {
            try {
                $reporterArguments = $reporterCall.Arguments
                $null = Invoke-Action @reporterArguments
                Write-Verbose "[Start-DscRunner] Reporter '$($reporterCall.Label)' completed for $FilePath"
            }
            catch {
                $reporterProblem = "Reporter '$($reporterCall.Label)' failed for '$FilePath': $((& $safeText $_.Exception.Message))"
                Write-Error "[Start-DscRunner] $reporterProblem" -ErrorAction Continue
                # Only a run that otherwise completed is re-marked: an abort or an early stop is
                # the more important thing to report, and resource results are never altered.
                if ($reportOnError -ieq 'Fail' -and $runStatus -eq 'Completed') {
                    $runStatus = 'ReportFailed'
                    $runError = $reporterProblem
                }
            }
        }

        # The Get() output held for reference()/using() is not needed once the file is finished
        # and reported. Release it rather than keep every resource's state (which can include
        # secrets) in module memory until the next run starts.
        $references.Clear()
        $script:resourceOutputs = @{}

        # Print the summary block.
        $outcomeIsClean = ($failCount -eq 0) -and ($runStatus -eq 'Completed')

        Write-Information "DSC Configuration Report: $FilePath" -Tags $infoTag
        Write-Information "Run Status: $runStatus" -Tags $infoTag
        Write-Information "Results Summary:" -Tags $infoTag

        foreach ($record in $results) {
            Write-Information ("[{0}] {1}/{2} - Result: [{3}]" -f (& $safeText $record.NodeName), (& $safeText $record.ResourceType), (& $safeText $record.InstanceName), $record.Status) -Tags $infoTag
        }

        Write-Information "Total Tasks Executed: $($results.Count)" -Tags $infoTag
        Write-Information "Tasks Passed:  $passCount" -Tags $infoTag
        Write-Information "Tasks Failed:  $failCount" -Tags $infoTag
        Write-Information "Tasks Skipped: $skipCount" -Tags $infoTag
        Write-Information "Total Tasks: $($results.Count)" -Tags $infoTag

        # Failure detail block — a deduplicated list of every failed resource (#30).
        if ($failedResources.Count -gt 0) {
            Write-Information "Failed Resources:" -Tags $infoTag
            foreach ($failed in $failedResources) {
                Write-Information ("  {0}/{1} [{2}] - {3}" -f (& $safeText $failed.ResourceType), (& $safeText $failed.InstanceName), (& $safeText $failed.ConfigurationFile), $failed.ErrorMessage) -Tags $infoTag
            }
        }

        if (-not $outcomeIsClean) {
            Write-Verbose "[Start-DscRunner] Run completed with failures or interruption (status: $runStatus)."
        }
    }

    # Each returned record also says whether the resource had drifted and whether Set ran, so a
    # caller that applies (Set) learns what changed from this one run instead of running Test
    # first to find out. Added after the CSV and JSON files are written, so their columns are
    # unchanged; the report document has carried the same two values since #85.
    foreach ($record in $results) {
        $detail = $null
        $null = $resourceDetails.TryGetValue(('{0}|{1}|{2}' -f $record.ConfigurationFile, $record.ResourceType, $record.InstanceName), [ref]$detail)
        $record | Add-Member -NotePropertyName Drifted -NotePropertyValue $(if ($detail) { [bool]$detail.Drifted } else { $null }) -Force
        $record | Add-Member -NotePropertyName SetInvoked -NotePropertyValue $(if ($detail) { [bool]$detail.SetInvoked } else { $false }) -Force
    }

    # Emit the structured run result so callers (Invoke-DscRunner / Invoke-DscPipelineRunner)
    # can aggregate outcomes across configuration files, surface a machine-readable report and
    # set a non-zero exit code on failure.
    $runResult = [pscustomobject]@{
        ConfigurationFile = $FilePath
        NodeName          = $nodeName
        Status            = $runStatus
        TotalResources    = $results.Count
        PassCount         = $passCount
        FailCount         = $failCount
        SkipCount         = $skipCount
        DurationSeconds   = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 3)
        ErrorMessage      = $runError
        FailedResources   = $failedResources
        Results           = $results
    }

    # A dry run also returns the resultant configuration. Added only then, so the result of a
    # Test or Set run keeps exactly the properties it has always had.
    if ($Mode -eq 'DryRun') {
        $runResult | Add-Member -NotePropertyName Rsop -NotePropertyValue $rsopDocument
    }

    # #106: likewise added only when the capability policy was bypassed, so a compiled run's
    # result keeps exactly the properties it has always had and an auditor can tell them apart.
    if ($PolicyBypassed) {
        $runResult | Add-Member -NotePropertyName PolicyBypassed -NotePropertyValue $true
    }

    return $runResult

}
