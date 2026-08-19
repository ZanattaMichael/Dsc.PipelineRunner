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
Directory Datum compiles into. Defaults to a new temporary directory. Replaces the
old AZDODSC_CACHE_DIRECTORY hard requirement.

.PARAMETER Mode
'Test' (default) or 'Set'.

.PARAMETER ReportPath
Optional directory to write the per-configuration CSV report into.

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
        [string]$ReportPath
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
    # 2. Connect — establish any required auth/session (default: None).
    $null = Invoke-Action -Hook Connect -Name $Connect -ScriptBlock $ConnectAction -Context $ConnectContext

    #
    # 3. Determine the compile/cache directory (generic; no AZDODSC_* requirement).
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $CacheDirectory = (New-TemporaryDirectory).Path
        Write-Verbose "[Invoke-DscRunner] Using temporary cache directory: $CacheDirectory"
    }

    #
    # 4. Compile Datum and run the core loop over each compiled configuration file.
    Build-DatumConfiguration -OutputPath $CacheDirectory -ConfigurationPath $configurationDirectory

    $params = @{ Mode = $Mode }
    if ($ReportPath) { $params.ReportPath = $ReportPath }

    Get-ChildItem -LiteralPath $CacheDirectory -File -Filter '*.yml' | ForEach-Object {
        Start-DscRunner -FilePath $_.FullName @params
    }
}
