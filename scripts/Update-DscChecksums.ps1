<#
.SYNOPSIS
Record the SHA-256 of every DSC v3 archive in a release into scripts/dsc-checksums.json.

.DESCRIPTION
scripts/Install-DscV3.ps1 refuses a download whose SHA-256 it cannot check. This script is how
a release becomes pinned: it resolves the release from the PowerShell/DSC GitHub project,
downloads each .tar.gz / .zip archive, computes its SHA-256, cross-checks it against the digest
GitHub publishes for the asset (a mismatch aborts), and writes the result into the lock file.

Review the resulting change to dsc-checksums.json like any dependency update: the point of the
file is that a human looked at it. To check an entry independently, download the asset yourself
and compare `Get-FileHash` with the recorded value.

.PARAMETER Version
The release tag to pin, for example 'v3.3.0'. Defaults to the lock file's defaultVersion.

.PARAMETER ChecksumFile
The lock file to read and update. Defaults to dsc-checksums.json next to this script.

.PARAMETER OutputPath
Where to write the updated JSON. Defaults to -ChecksumFile. Pass a different path to leave the
lock file untouched (the manual workflow does this and prints the result).

.PARAMETER SetDefault
Also make this release the lock file's defaultVersion.

.PARAMETER GitHubToken
Optional token used only to raise the GitHub API rate limit. Defaults to $env:GITHUB_TOKEN.

.EXAMPLE
./scripts/Update-DscChecksums.ps1 -Version v3.3.0 -SetDefault
#>
[CmdletBinding()]
param(
    [string]$Version,

    [string]$ChecksumFile = (Join-Path $PSScriptRoot 'dsc-checksums.json'),

    [string]$OutputPath,

    [switch]$SetDefault,

    [string]$GitHubToken = $env:GITHUB_TOKEN
)

$ErrorActionPreference = 'Stop'

$lock = [ordered]@{ defaultVersion = $null; releases = [ordered]@{} }
if (Test-Path -LiteralPath $ChecksumFile) {
    $existing = Get-Content -LiteralPath $ChecksumFile -Raw | ConvertFrom-Json
    $lock.defaultVersion = [string]$existing.defaultVersion
    if ($null -ne $existing.releases) {
        foreach ($property in $existing.releases.PSObject.Properties) {
            $assets = [ordered]@{}
            foreach ($assetProperty in $property.Value.PSObject.Properties) { $assets[$assetProperty.Name] = [string]$assetProperty.Value }
            $lock.releases[$property.Name] = $assets
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $lock.defaultVersion }
if ([string]::IsNullOrWhiteSpace($Version)) { throw "[Update-DscChecksums] No -Version given and the lock file has no defaultVersion." }
$tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }

$headers = @{ 'User-Agent' = 'Dsc.PipelineRunner-Update-DscChecksums'; 'Accept' = 'application/vnd.github+json' }
if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) { $headers['Authorization'] = "Bearer $GitHubToken" }

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/DSC/releases/tags/$tag" -Headers $headers
if ($null -eq $release -or $release.tag_name -ne $tag) { throw "[Update-DscChecksums] Could not resolve release '$tag'." }

$archives = @($release.assets | Where-Object { $_.name -match '\.(tar\.gz|zip)$' -and $_.name -match '(x86_64|aarch64)' })
if ($archives.Count -eq 0) { throw "[Update-DscChecksums] Release '$tag' has no x86_64/aarch64 .tar.gz or .zip assets." }

$hashes = [ordered]@{}
$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("dsc-checksums-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDirectory
try {
    foreach ($asset in ($archives | Sort-Object -Property name)) {
        $file = Join-Path $workDirectory $asset.name
        Write-Verbose "[Update-DscChecksums] Downloading $($asset.name)."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -Headers @{ 'User-Agent' = $headers['User-Agent'] }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()

        # GitHub publishes its own digest for each asset. A disagreement means the download was
        # corrupted or tampered with in transit, so it must stop the pin, not be recorded.
        if ($null -ne $asset.PSObject.Properties['digest'] -and "$($asset.digest)" -match '\Asha256:([0-9a-fA-F]{64})\z') {
            if ($Matches[1].ToLowerInvariant() -ne $hash) {
                throw "[Update-DscChecksums] '$($asset.name)': computed $hash but GitHub publishes $($Matches[1].ToLowerInvariant()). Not recording either."
            }
        }
        else {
            Write-Warning "[Update-DscChecksums] GitHub published no digest for '$($asset.name)'; the recorded hash is the one computed from this download only."
        }

        $hashes[$asset.name] = $hash
        Remove-Item -LiteralPath $file -Force
    }
}
finally {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$lock.releases[$tag] = $hashes
if ($SetDefault -or [string]::IsNullOrWhiteSpace($lock.defaultVersion)) { $lock.defaultVersion = $tag }

$json = $lock | ConvertTo-Json -Depth 5
$destination = if ([string]::IsNullOrWhiteSpace($OutputPath)) { $ChecksumFile } else { $OutputPath }
Set-Content -LiteralPath $destination -Value $json -Encoding UTF8

Write-Host "[Update-DscChecksums] Recorded $($hashes.Count) archive hash(es) for $tag in $destination"
Write-Host $json
