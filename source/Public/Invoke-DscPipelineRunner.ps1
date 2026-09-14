<#
.SYNOPSIS
Invokes the DSC Pipeline Runner against an Azure DevOps organization.

.DESCRIPTION
The Invoke-DscPipelineRunner function is the Azure DevOps entry point to the runner. It
resolves a configuration source (a local directory or a git URL), compiles it with Datum,
establishes an Azure DevOps authentication provider, and runs each compiled configuration.

Authentication is selected by parameter set, not by a separate switch:

  * ManagedIdentity (default) - authenticates with the agent's managed identity.
  * PAT                       - supply -PATToken; the PAT parameter set is chosen implicitly.

New callers should prefer Invoke-DscRunner, which is provider-agnostic and exposes the
Source/Connect/Engine action seams directly.

.PARAMETER AzureDevopsOrganizationName
Specifies the name of the Azure DevOps organization. This parameter is mandatory.

.PARAMETER ExportConfigDir
Specifies the directory where configuration files are exported by Datum. This parameter is
mandatory and must be an existing directory.

.PARAMETER ConfigurationSourcePath
Specifies the URL or directory path for the configuration source. This parameter is mandatory.

Only https and ssh remotes are accepted; a plain http:// URL is rejected.

SECURITY: the configuration is executed as arbitrary PowerShell — a Datum/DSC Configuration
block is code, not just data — in the runner's own process and security context. There is no
sandbox or content validation. Treat the configuration repository (or the cloned URL) as
fully-trusted code and protect it with the same controls as the runner's own source: branch
protection, required reviews, and (ideally) signed commits. See SECURITY.md, "Trust model".

.PARAMETER ConfigurationRevision
Optional branch, tag, or commit to pin a cloned configuration to. A full 40-character commit
SHA makes the pin exact: the clone's HEAD is verified against it and a mismatch is an error.
Ignored when -ConfigurationSourcePath is a local directory.

.PARAMETER JITToken
Optional Just-In-Time access token used to authenticate the git clone. Accepts a
[SecureString] (preferred) or a plain string. When omitted, $env:SYSTEM_ACCESSTOKEN is used
if it is set; a public repository needs neither.

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' and 'Set'. The default value is 'Test'.

.PARAMETER PATToken
Specifies the Personal Access Token. Supplying it selects the PAT parameter set, so the PAT is
always the credential actually used for the Azure DevOps connection.

.PARAMETER ReportPath
Specifies the directory to write the run report into. Optional; must be an existing directory.

.PARAMETER FailOnError
Set a non-zero process exit code when the run reports a failure, so a pipeline step fails
loudly instead of silently succeeding.

.PARAMETER KeepTemporaryDirectory
Leave a cloned configuration directory on disk after the run instead of deleting it. A
caller-supplied local configuration directory is never deleted, with or without this switch.

.EXAMPLE
Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir "C:\Configs" `
                         -ConfigurationSourcePath "https://dev.azure.com/MyOrg/Project/_git/config" `
                         -Mode Set -PATToken $pat

Runs in Set mode against a cloned configuration, authenticating with a Personal Access Token.

.EXAMPLE
Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -ExportConfigDir "C:\Configs" `
                         -ConfigurationSourcePath "C:\config"

Runs in the default Test mode against a local directory, authenticating with the agent's
managed identity.

.NOTES
Ensure that a cache directory environment variable is set before running this function. The
generic PIPELINERUNNER_CACHE_DIRECTORY is preferred; the legacy AZDODSC_CACHE_DIRECTORY is
still honoured as a back-compat alias. The function will throw an error if neither is set.

BREAKING CHANGE (#17): -exportConfigDir is now -ExportConfigDir, and -AuthenticationType has
been removed in favour of the parameter set implied by -PATToken. -Mode is no longer mandatory
and defaults to 'Test'. -JITToken is no longer mandatory.
#>


function Invoke-DscPipelineRunner {
    # Utilizes the CmdletBinding attribute to enable advanced function features similar to cmdlets.
    [CmdletBinding(DefaultParameterSetName='ManagedIdentity')]
    param(
        # Declares a mandatory parameter that specifies the name of the Azure DevOps organization.
        [Parameter(Mandatory)]
        [String]$AzureDevopsOrganizationName,

        # The directory Datum exports the compiled configuration files into.
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [String]$ExportConfigDir,

        # The configuration source: a local directory path, or an https/ssh git URL.
        [Parameter(Mandatory)]
        [String]$ConfigurationSourcePath,

        # Optional revision to pin a cloned configuration to (#31).
        [Parameter()]
        [String]$ConfigurationRevision,

        # Optional credential for the git clone. [object] so a SecureString or a plain string
        # are both accepted; Get-PipelineAuthToken normalises it.
        [Parameter()]
        [object]$JITToken,

        # Optional: 'Test' (default) reports drift, 'Set' remediates it. Previously declared
        # Mandatory alongside a default, which meant the default was unreachable (#17).
        [Parameter()]
        [ValidateSet('Test', 'Set')]
        [String]$Mode = 'Test',

        # Supplying a PAT selects the PAT parameter set, so the credential a caller passes is
        # always the one used. The old -AuthenticationType switch defaulted independently of
        # the parameter set, so -PATToken was silently ignored (#17).
        #
        # The pattern is deliberately permissive: Azure DevOps has issued 52-character tokens
        # and, more recently, longer (84-character) ones, and the exact format is not a
        # documented contract. Reject only obviously malformed input.
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [ValidatePattern('^[A-Za-z0-9]{20,120}$')]
        [String]$PATToken,

        # Optional directory to write the run report into.
        [Parameter()]
        [ValidateScript({Test-Path -Path $_ -PathType Container})]
        [String]$ReportPath,

        # Opt-in: set a non-zero process exit code when the run reports a failure, so a
        # pipeline step fails loudly instead of silently succeeding.
        [Parameter()]
        [switch]$FailOnError,

        # Opt-in: keep a cloned configuration directory after the run, for debugging.
        [Parameter()]
        [switch]$KeepTemporaryDirectory
    )

    # Set the Error Action Preference
    $ErrorActionPreference = "Stop"

    #
    # Test to make sure a cache directory is configured. The generic
    # PIPELINERUNNER_CACHE_DIRECTORY is preferred; the legacy AZDODSC_CACHE_DIRECTORY is
    # still honoured as a back-compat alias for existing Azure DevOps pipelines.

    if (-not (Resolve-CacheDirectory)) {
        throw "No cache directory is set. Set the PIPELINERUNNER_CACHE_DIRECTORY environment variable (AZDODSC_CACHE_DIRECTORY is also accepted) before running this script."
    }

    # Track whether the configuration came from a remote URL so the compile step can warn that
    # remote content executes as trusted code in this process (#27).
    $sourceIsRemote = $false
    $DatumConfigurationPath = $null

    # From the clone onwards everything runs inside a try/finally so a cloned configuration is
    # removed even when the run throws (#32). Remove-RunnerTemporaryDirectory only deletes
    # directories New-TemporaryDirectory created, so a caller-supplied local path is safe.
    try {

        #
        # Clone the Datum Configuration from the Configuration URL.
        #
        # Anything that parses as an absolute URI is treated as a remote and validated by
        # Clone-Repository, which rejects every scheme except https and ssh (#31). Matching
        # only '^https?://' here would silently fall through to the "not a directory" branch
        # for, say, a git:// URL, hiding the real reason it was refused.
        $uri = $null
        $isAbsoluteUri = [System.Uri]::TryCreate($ConfigurationSourcePath, [System.UriKind]::Absolute, [ref]$uri) -and
                         $uri.Scheme -in @('http', 'https', 'ssh', 'git', 'ftp')

        if ($isAbsoluteUri -or $ConfigurationSourcePath -match '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+:(?!//).+$') {

            # $JITToken is read from this scope by the module's `git` wrapper (dynamic scoping)
            # to build the HTTP Authorization header. Normalise it to a SecureString first, and
            # fall back to $env:SYSTEM_ACCESSTOKEN when the caller supplied nothing.
            $JITToken = Get-PipelineAuthToken -Token $JITToken

            $cloneArgs = @{ DatumURLConfig = $ConfigurationSourcePath }
            if (-not [string]::IsNullOrWhiteSpace($ConfigurationRevision)) {
                $cloneArgs.Revision = $ConfigurationRevision
            }

            $DatumConfigurationPath = Clone-Repository @cloneArgs
            $sourceIsRemote = $true
        }
        # Test if ConfigurationSourcePath is a directory path that exists.
        elseif (Test-Path -Path $ConfigurationSourcePath -PathType Container) {
            $DatumConfigurationPath = $ConfigurationSourcePath
        }
        # Else. Throw an error for bad data.
        else {
            throw "[Invoke-DscPipelineRunner] Invalid ConfigurationSourcePath: $ConfigurationSourcePath"
        }

        #
        # Compile the Datum Configuration. The caller-supplied export directory is the trusted
        # scratch root; pass it as -AllowedRoot so the compile step's path-traversal guard (#33)
        # permits it while still rejecting a path that escapes it.
        Build-DatumConfiguration -OutputPath $ExportConfigDir -ConfigurationPath $DatumConfigurationPath -AllowedRoot $ExportConfigDir -SourceIsRemote:$sourceIsRemote

        #
        # Resolve PipelineRunnerSettings (#57 §2/§3/§4) from the (pre-compile) Datum source
        # directory, mirroring Invoke-DscRunner. Without this, AllowExecutionScripts/Reboot/
        # Target never reach Start-DscRunner and every configuration is evaluated against the
        # unmodified defaults (AllowExecutionScripts effectively always false), regardless of
        # what the Datum.yml PipelineRunnerSettings block actually specifies.
        $settings = Get-PipelineRunnerSetting -ConfigurationDirectory $DatumConfigurationPath

        #
        # Create the Azure DevOps Authentication Provider.
        #
        # Azure DevOps is no longer a hard dependency of the module (it is not listed in
        # RequiredModules). This back-compat entry point therefore imports the provider on
        # demand and fails clearly if it is absent — new callers should prefer
        # Invoke-DscRunner with `-Connect AzureDevOps` (or a custom Connect action).
        if (-not (Get-Command -Name New-AzDoAuthenticationProvider -ErrorAction SilentlyContinue)) {
            if (Get-Module -ListAvailable -Name AzureDevOpsDsc.Common) {
                Import-Module -Name AzureDevOpsDsc.Common -ErrorAction Stop
            }
            else {
                throw "[Invoke-DscPipelineRunner] Azure DevOps support requires the 'AzureDevOpsDsc.Common' module. Install it, or use Invoke-DscRunner with a custom Connect action."
            }
        }

        # The parameter set is the single source of truth for how to authenticate.
        if ($PSCmdlet.ParameterSetName -eq 'PAT') {
            New-AzDoAuthenticationProvider -OrganizationName $AzureDevopsOrganizationName -PersonalAccessToken $PATToken
        }
        else {
            New-AzDoAuthenticationProvider -OrganizationName $AzureDevopsOrganizationName -useManagedIdentity
        }

        #
        # Invoke the Resources

        # Create a hashtable to store the parameters
        $params = @{
            Mode = $Mode
        }

        # If the ReportPath is provided, add it to the parameters
        if ($ReportPath) {
            $params.ReportPath = $ReportPath
        }

        # Forward the resolved PipelineRunnerSettings down to Start-DscRunner (#57 §2/§3/§4).
        if ($settings) {
            $params.RunnerSettings = $settings
        }

        # Collect each configuration's structured result so the run can be summarized as a single
        # machine-readable object and, with -FailOnError, surface a non-zero exit code (#19).
        $runResults = Get-ChildItem -LiteralPath $ExportConfigDir -File -Filter "*.yml" | ForEach-Object {
            Start-DscRunner -FilePath $_.Fullname @params
        }

        $summaryArgs = @{ Result = $runResults }
        if ($ReportPath)  { $summaryArgs.ReportPath  = $ReportPath }
        if ($FailOnError) { $summaryArgs.FailOnError = $true }

        return Merge-DscRunnerResult @summaryArgs

    }
    finally {
        if ($KeepTemporaryDirectory) {
            Write-Verbose "[Invoke-DscPipelineRunner] -KeepTemporaryDirectory was supplied; leaving the cloned configuration in place."
        }
        else {
            # No-op for a caller-supplied directory; deletes only what the runner cloned.
            Remove-RunnerTemporaryDirectory -Path $DatumConfigurationPath
        }
    }

}
