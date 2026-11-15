<#
.SYNOPSIS
Download and install the DSC v3 command-line engine (dsc / dsc.exe) cross-platform.

.DESCRIPTION
Bootstraps a hosted agent (or a local box, or a container image) with Microsoft's DSC v3
executable so the runner's DscV3 engine has a `dsc` to drive. It resolves a release from
the PowerShell/DSC GitHub project, selects the archive that matches the current OS and
CPU architecture, extracts it into -InstallDirectory, and — when running inside GitHub
Actions — appends that directory to the job PATH via $GITHUB_PATH.

The asset is chosen by matching architecture/OS keywords rather than a hard-coded file
name, so minor changes to the release naming do not break the bootstrap.

.PARAMETER Version
The release to install. When omitted, the 'defaultVersion' recorded in the checksum lock file
(scripts/dsc-checksums.json) is used, so an unattended install is reproducible; if there is no
lock file it falls back to 'latest'. 'latest' resolves the newest non-prerelease release from
the GitHub API. Otherwise pass a tag such as 'v3.0.0' (a leading 'v' is optional).

.PARAMETER Sha256
The expected SHA-256 of the archive. Overrides both the lock file and GitHub's published
digest. Use it to install a release that is not in the lock file with a hash you obtained and
checked yourself.

.PARAMETER ChecksumFile
The lock file of known-good SHA-256 hashes. Defaults to dsc-checksums.json next to this script.
Update it with scripts/Update-DscChecksums.ps1.

.PARAMETER AllowUnverified
Install even when no SHA-256 is available to check the download against. Off by default: the
download is a program that will be executed, so an archive that cannot be verified is refused.

.PARAMETER InstallDirectory
Directory to extract the executable into. Created if it does not exist. Defaults to
a 'dsc' folder under the user's local application data / home.

.PARAMETER IncludePrerelease
When resolving 'latest', consider prerelease releases too (DSC v3 shipped previews for
a long time). Ignored when an explicit -Version tag is supplied.

.PARAMETER GitHubToken
Optional token used only to raise the GitHub API rate limit for the release lookup.
Defaults to $env:GITHUB_TOKEN when present. Never written to disk or logged.

.OUTPUTS
[string] The full path to the installed dsc executable.

.EXAMPLE
./scripts/Install-DscV3.ps1 -Version v3.0.0 -InstallDirectory /usr/local/dsc

.EXAMPLE
$dsc = ./scripts/Install-DscV3.ps1   # latest stable, into the default location
& $dsc --version
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [string]$Version,

    [string]$InstallDirectory,

    [switch]$IncludePrerelease,

    [string]$GitHubToken = $env:GITHUB_TOKEN,

    [ValidatePattern('\A[0-9a-fA-F]{64}\z', ErrorMessage = '-Sha256 must be 64 hexadecimal characters.')]
    [string]$Sha256,

    [string]$ChecksumFile = (Join-Path $PSScriptRoot 'dsc-checksums.json'),

    [switch]$AllowUnverified
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------------
# The checksum lock file: known-good SHA-256 hashes per release and asset, plus the version
# an unattended install should use. Read before anything is downloaded.
# ------------------------------------------------------------------------------------
$lock = $null
if (Test-Path -LiteralPath $ChecksumFile) {
    $lock = Get-Content -LiteralPath $ChecksumFile -Raw | ConvertFrom-Json
}

if (-not $PSBoundParameters.ContainsKey('Version') -or [string]::IsNullOrWhiteSpace($Version)) {
    $Version = if ($null -ne $lock -and -not [string]::IsNullOrWhiteSpace([string]$lock.defaultVersion)) { [string]$lock.defaultVersion } else { 'latest' }
    Write-Verbose "[Install-DscV3] No -Version given; using '$Version'."
}

# ------------------------------------------------------------------------------------
# Platform detection. $IsWindows/$IsLinux/$IsMacOS exist on PowerShell 6+; on Windows
# PowerShell 5.1 they are undefined, in which case the host is Windows by definition.
# ------------------------------------------------------------------------------------
$onWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }
$onLinux   = [bool]$IsLinux
$onMacOS   = [bool]$IsMacOS

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
# Map the .NET architecture name onto the Rust target triples the DSC assets use.
$archKeywords = switch ($arch) {
    'x64'   { @('x86_64') }
    'arm64' { @('aarch64') }
    default { throw "[Install-DscV3] Unsupported CPU architecture '$arch'." }
}

if ($onWindows)  { $osKeywords = @('windows', 'pc-windows'); $isZip = $true }
elseif ($onMacOS) { $osKeywords = @('apple', 'darwin', 'macos'); $isZip = $false }
elseif ($onLinux) { $osKeywords = @('linux'); $isZip = $false }
else { throw "[Install-DscV3] Could not determine the host operating system." }

# ------------------------------------------------------------------------------------
# Default install location when the caller does not name one.
# ------------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $base = if ($onWindows) {
        [Environment]::GetFolderPath('LocalApplicationData')
    }
    else {
        Join-Path $HOME '.local/share'
    }
    $InstallDirectory = Join-Path $base 'dsc'
}

# ------------------------------------------------------------------------------------
# Resolve the release and pick the matching archive asset.
# ------------------------------------------------------------------------------------
$headers = @{ 'User-Agent' = 'Dsc.PipelineRunner-Install-DscV3'; 'Accept' = 'application/vnd.github+json' }
if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $headers['Authorization'] = "Bearer $GitHubToken"
}

$apiBase = 'https://api.github.com/repos/PowerShell/DSC/releases'

if ($Version -eq 'latest' -and -not $IncludePrerelease) {
    Write-Verbose "[Install-DscV3] Resolving the latest stable DSC release."
    $release = Invoke-RestMethod -Uri "$apiBase/latest" -Headers $headers
}
elseif ($Version -eq 'latest') {
    Write-Verbose "[Install-DscV3] Resolving the newest release (prereleases included)."
    $release = (Invoke-RestMethod -Uri $apiBase -Headers $headers) | Select-Object -First 1
}
else {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    Write-Verbose "[Install-DscV3] Resolving DSC release '$tag'."
    $release = Invoke-RestMethod -Uri "$apiBase/tags/$tag" -Headers $headers
}

if ($null -eq $release) {
    throw "[Install-DscV3] Could not resolve a DSC release for version '$Version'."
}

$extension = if ($isZip) { '.zip' } else { '.tar.gz' }
$asset = $release.assets |
    Where-Object { $_.name.ToLowerInvariant().EndsWith($extension) } |
    Where-Object { $name = $_.name.ToLowerInvariant(); ($archKeywords | Where-Object { $name.Contains($_) }) } |
    Where-Object { $name = $_.name.ToLowerInvariant(); ($osKeywords | Where-Object { $name.Contains($_) }) } |
    Select-Object -First 1

if ($null -eq $asset) {
    $available = ($release.assets.name -join ', ')
    throw "[Install-DscV3] No DSC asset for arch '$arch' / os keywords '$($osKeywords -join ",")' in release '$($release.tag_name)'. Available assets: $available"
}

Write-Verbose "[Install-DscV3] Selected asset: $($asset.name) from release $($release.tag_name)."

# ------------------------------------------------------------------------------------
# Download and extract.
# ------------------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path $InstallDirectory -Force
$downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) $asset.name

Write-Verbose "[Install-DscV3] Downloading $($asset.browser_download_url)."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -Headers @{ 'User-Agent' = $headers['User-Agent'] }

# ------------------------------------------------------------------------------------
# Verify the download BEFORE it is extracted or executed. The expected hash comes, in order of
# trust, from: an explicit -Sha256; the reviewed lock file; GitHub's own published digest for
# the asset (which guards against a corrupted or swapped download, but is not an independent
# pin, so it warns). With none of those the archive is refused unless -AllowUnverified.
# ------------------------------------------------------------------------------------
$actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()

$expectedHash = $null
$hashSource = $null
$pinnedRelease = $null
if ($null -ne $lock -and $null -ne $lock.releases) {
    $pinnedProperty = $lock.releases.PSObject.Properties[[string]$release.tag_name]
    if ($null -ne $pinnedProperty) { $pinnedRelease = $pinnedProperty.Value }
}

if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
    $expectedHash = $Sha256
    $hashSource = '-Sha256'
}
elseif ($null -ne $pinnedRelease) {
    $pinnedAsset = $pinnedRelease.PSObject.Properties[[string]$asset.name]
    if ($null -eq $pinnedAsset) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        throw "[Install-DscV3] Release '$($release.tag_name)' is pinned in '$ChecksumFile' but the asset '$($asset.name)' is not listed. Refusing to install an asset that was never reviewed; run scripts/Update-DscChecksums.ps1."
    }
    $expectedHash = [string]$pinnedAsset.Value
    $hashSource = (Split-Path -Leaf $ChecksumFile)
}
elseif ($null -ne $asset.PSObject.Properties['digest'] -and "$($asset.digest)" -match '\Asha256:([0-9a-fA-F]{64})\z') {
    $expectedHash = $Matches[1]
    $hashSource = "GitHub's published digest"
    Write-Warning "[Install-DscV3] Release '$($release.tag_name)' is not pinned in '$(Split-Path -Leaf $ChecksumFile)'; verifying against GitHub's published digest only. Pin it with scripts/Update-DscChecksums.ps1."
}

if ([string]::IsNullOrWhiteSpace($expectedHash)) {
    if (-not $AllowUnverified) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        throw "[Install-DscV3] No SHA-256 is available to verify '$($asset.name)' ($($release.tag_name)) against, so it was not installed. Add it to '$(Split-Path -Leaf $ChecksumFile)', pass -Sha256, or (not recommended) pass -AllowUnverified."
    }
    Write-Warning "[Install-DscV3] Installing '$($asset.name)' WITHOUT verification (-AllowUnverified). sha256=$actualHash"
}
elseif ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    throw "[Install-DscV3] SHA-256 mismatch for '$($asset.name)' ($($release.tag_name)): expected $($expectedHash.ToLowerInvariant()) from $hashSource, got $actualHash. The download was discarded and nothing was installed."
}
else {
    Write-Host "[Install-DscV3] Verified $($asset.name): sha256=$actualHash (source: $hashSource)"
}

if ($isZip) {
    Expand-Archive -Path $downloadPath -DestinationPath $InstallDirectory -Force
}
else {
    # tar ships with modern Windows, Linux and macOS runners.
    & tar -xzf $downloadPath -C $InstallDirectory
    if ($LASTEXITCODE -ne 0) { throw "[Install-DscV3] tar extraction failed (exit $LASTEXITCODE)." }
}
Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------
# Locate the executable and make it runnable.
# ------------------------------------------------------------------------------------
$executableName = if ($onWindows) { 'dsc.exe' } else { 'dsc' }
$executable = Get-ChildItem -Path $InstallDirectory -Recurse -Filter $executableName -File |
    Select-Object -First 1

if ($null -eq $executable) {
    throw "[Install-DscV3] '$executableName' was not found under '$InstallDirectory' after extraction."
}

if (-not $onWindows) {
    & chmod +x $executable.FullName
    # Resource binaries shipped alongside dsc need the execute bit too.
    Get-ChildItem -Path $executable.DirectoryName -File | ForEach-Object { & chmod +x $_.FullName 2>$null }
}

# ------------------------------------------------------------------------------------
# Make dsc discoverable: prepend to this process PATH, and to the GitHub Actions job
# PATH when running inside a workflow.
# ------------------------------------------------------------------------------------
$binDir = $executable.DirectoryName
$separator = [System.IO.Path]::PathSeparator
if (($env:PATH -split [regex]::Escape($separator)) -notcontains $binDir) {
    $env:PATH = "$binDir$separator$env:PATH"
}
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    Add-Content -Path $env:GITHUB_PATH -Value $binDir
}

Write-Host "[Install-DscV3] Installed DSC $($release.tag_name) to: $($executable.FullName)"
return $executable.FullName
