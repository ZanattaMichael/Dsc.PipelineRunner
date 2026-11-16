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
AZDODSC_CACHE_DIRECTORY hard requirement.

.PARAMETER Mode
'Test' (default) or 'Set'.

.PARAMETER ReportPath
Optional directory to write the per-configuration CSV report into.

.PARAMETER Engine
Name of the execution engine action (a file under Actions/Engine/). 'DscV2' (default)
wraps Invoke-DscResource; 'DscV3' drives dsc.exe. 'Auto' opts in to detection, choosing
DscV3 when the dsc executable is present (or the version hint asks for it) and DscV2
otherwise. When -Engine is not passed explicitly, the configuration's
PipelineRunnerSettings drive selection: an 'Engine' key names the engine, otherwise the
back-compat 'DSCResourceVersion' major version maps (2.x -> DscV2, 3.x -> DscV3).

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
#>
function Invoke-DscRunner {
    [CmdletBinding()]
    param(
        [string]$Source = 'Local',
        [scriptblock]$SourceAction,
        [hashtable]$SourceContext = @{},

        [string]$ConfigurationSourcePath,
        [string]$ConfigurationRevision,

        [string]$Connect = 'None',
        [scriptblock]$ConnectAction,
        [hashtable]$ConnectContext = @{},

        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$CacheDirectory,

        [ValidateSet('Test', 'Set')]
        [string]$Mode = 'Test',

        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [string]$ReportPath,

        [string]$Engine = 'DscV2',
        [string]$EngineVersion,
        [scriptblock]$EngineAction,

        [scriptblock]$ReportAction,

        [switch]$FailOnError,

        [switch]$KeepTemporaryDirectory
    )

    $ErrorActionPreference = 'Stop'

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
    $configurationDirectory = $null
    $resolvedCacheDirectory = $null

    try {

        #
        # 1. Source — resolve the configuration to a local directory.
        $configurationDirectory = Invoke-Action -Hook Source -Name $Source -ScriptBlock $SourceAction -Context $SourceContext
        if ([string]::IsNullOrWhiteSpace($configurationDirectory)) {
            throw "[Invoke-DscRunner] The Source action returned no configuration directory."
        }
        Write-Verbose "[Invoke-DscRunner] Configuration directory: $configurationDirectory"

        #
        # 1b. Engine selection. An inline -EngineAction or an explicit -Engine always wins.
        # Otherwise the configuration decides: PipelineRunnerSettings.Engine names the engine,
        # and failing that the back-compat DSCResourceVersion major maps through Resolve-DscEngine
        # (2.x -> DscV2, 3.x -> DscV3, otherwise dsc.exe auto-detection). This keeps the version
        # gate out of the core loop while honouring the field configs already carry.
        # Resolved once, regardless of -Engine, so its other keys (AllowExecutionScripts,
        # Reboot, Target - #57 §2/§3/§4) are available to pass down to Start-DscRunner even
        # when the engine itself was chosen explicitly. Only available pre-compile, here -
        # Start-DscRunner receives compiled per-node YAML which does not carry this block.
        $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $configurationDirectory

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
        # 2. Connect — establish any required auth/session (default: None).
        $null = Invoke-Action -Hook Connect -Name $Connect -ScriptBlock $ConnectAction -Context $ConnectContext

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
        # 4. Compile Datum and run the core loop over each compiled configuration file.
        # The resolved cache directory is the trusted scratch root; pass it as -AllowedRoot so the
        # compile step's path-traversal guard (#33) permits it while still rejecting an escaping path.
        # A Git source resolves the configuration from a remote clone, so flag it for the compile
        # step's trust-boundary warning (#27). Inline/custom Source actions that fetch remotely are
        # opaque here; the SECURITY.md trust model documents the requirement for those.
        $sourceIsRemote = ($Source -eq 'Git') -or ($SourceContext.ContainsKey('Url') -and -not [string]::IsNullOrWhiteSpace([string]$SourceContext['Url']) -and ([string]$SourceContext['Url'] -match '^(http|https|git|ssh):'))
        Build-DatumConfiguration -OutputPath $resolvedCacheDirectory -ConfigurationPath $configurationDirectory -AllowedRoot $resolvedCacheDirectory -SourceIsRemote:$sourceIsRemote

        $params = @{ Mode = $Mode; Engine = $Engine }
        if ($ReportPath)    { $params.ReportPath    = $ReportPath }
        if ($EngineVersion) { $params.EngineVersion = $EngineVersion }
        if ($EngineAction)  { $params.EngineAction  = $EngineAction }
        if ($ReportAction)  { $params.ReportAction  = $ReportAction }
        if ($settings)      { $params.RunnerSettings = $settings }

        # Collect each configuration's structured result so the run can be summarized as a single
        # machine-readable object and, with -FailOnError, surface a non-zero exit code (#19).
        $runResults = Get-ChildItem -LiteralPath $resolvedCacheDirectory -File -Filter '*.yml' | ForEach-Object {
            Start-DscRunner -FilePath $_.FullName @params
        }

        $summaryArgs = @{ Result = $runResults }
        if ($ReportPath)  { $summaryArgs.ReportPath  = $ReportPath }
        if ($FailOnError) { $summaryArgs.FailOnError = $true }

        return Merge-DscRunnerResult @summaryArgs

    }
    finally {
        if ($KeepTemporaryDirectory) {
            Write-Verbose "[Invoke-DscRunner] -KeepTemporaryDirectory was supplied; leaving any temporary directories in place."
        }
        else {
            # No-ops for a caller-supplied path; deletes only what the runner created.
            Remove-RunnerTemporaryDirectory -Path $configurationDirectory
            Remove-RunnerTemporaryDirectory -Path $resolvedCacheDirectory
        }
    }
}
