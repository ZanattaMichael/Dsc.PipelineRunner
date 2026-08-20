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
        [scriptblock]$EngineAction
    )

    $ErrorActionPreference = 'Stop'

    # Fold the convenience path into the Source context under the keys the built-in
    # Source actions understand (Local reads Path; Git reads Url, falling back to Path).
    if (-not [string]::IsNullOrWhiteSpace($ConfigurationSourcePath)) {
        if (-not $SourceContext.ContainsKey('Path')) { $SourceContext['Path'] = $ConfigurationSourcePath }
        if (-not $SourceContext.ContainsKey('Url'))  { $SourceContext['Url']  = $ConfigurationSourcePath }
    }

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
    if (-not $EngineAction -and -not $PSBoundParameters.ContainsKey('Engine')) {
        $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $configurationDirectory
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
        $resolvedCacheDirectory = (New-TemporaryDirectory).Path
        Write-Verbose "[Invoke-DscRunner] Using temporary cache directory: $resolvedCacheDirectory"
    }
    else {
        Write-Verbose "[Invoke-DscRunner] Using cache directory: $resolvedCacheDirectory"
    }

    #
    # 4. Compile Datum and run the core loop over each compiled configuration file.
    Build-DatumConfiguration -OutputPath $resolvedCacheDirectory -ConfigurationPath $configurationDirectory

    $params = @{ Mode = $Mode; Engine = $Engine }
    if ($ReportPath)    { $params.ReportPath    = $ReportPath }
    if ($EngineVersion) { $params.EngineVersion = $EngineVersion }
    if ($EngineAction)  { $params.EngineAction  = $EngineAction }

    Get-ChildItem -LiteralPath $resolvedCacheDirectory -File -Filter '*.yml' | ForEach-Object {
        Start-DscRunner -FilePath $_.FullName @params
    }
}
