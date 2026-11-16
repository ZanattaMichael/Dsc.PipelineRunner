<#
.SYNOPSIS
    Resolves the newest PowerShell Gallery version of every module in scripts/module-versions.json
    and checks that every version currently pinned there still exists.

.DESCRIPTION
    The lock file is the single list of Gallery modules CI, the container image and the build
    install, each at one exact version. Dependabot does not understand the PowerShell Gallery, so
    this script is how the pins are moved forward, on purpose, with a reviewable diff:

      * It always reports, per module, the pinned version, the newest stable version the Gallery
        offers (within the module's optional 'maxVersion'), and whether the pinned version is
        still published.
      * It fails if a pinned version has been removed from the Gallery (a pin that can no longer
        be installed is a broken build waiting to happen, and an unlisted version is worth a look).
      * With -Write it also writes a lock file holding the newest versions to -OutputPath
        (default: the lock file itself). Nothing is installed.

    Only stable versions are considered; prereleases are never proposed.

.PARAMETER LockFile
    The lock file to read. Defaults to module-versions.json next to this script.

.PARAMETER Write
    Write the newest versions to -OutputPath.

.PARAMETER OutputPath
    Where -Write puts the result. Defaults to -LockFile.

.PARAMETER MaxAttempts
    How many times a Gallery query is tried before it is reported as failed.

.PARAMETER RetryDelaySeconds
    Pause between attempts, multiplied by the attempt number.

.EXAMPLE
    ./scripts/Update-ModuleVersions.ps1                       # report only
    ./scripts/Update-ModuleVersions.ps1 -Write                # update the lock file in place
#>
[CmdletBinding()]
param(
    [string]$LockFile = (Join-Path $PSScriptRoot 'module-versions.json'),
    [switch]$Write,
    [string]$OutputPath,
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,
    [ValidateRange(0, 120)]
    [int]$RetryDelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $LockFile }

function Find-GalleryModule {
    # One Gallery query, retried: the Gallery drops a request now and then and that should not
    # fail the report. Returns $null when the Gallery answers but has no such version.
    param(
        [hashtable]$Query,
        [int]$Attempts,
        [int]$DelaySeconds
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return Find-Module @Query -Repository PSGallery -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchFound*') { return $null }
            if ($attempt -eq $Attempts) { throw }
            Write-Warning "Gallery query for '$($Query.Name)' failed (attempt $attempt of ${Attempts}): $($_.Exception.Message)"
            Start-Sleep -Seconds ($DelaySeconds * $attempt)
        }
    }
}

$lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
$results = [System.Collections.Generic.List[object]]::new()
$updated = [ordered]@{}

foreach ($property in $lock.modules.PSObject.Properties) {
    $name = $property.Name
    $entry = $property.Value
    $pinned = [string]$entry.version

    $latestQuery = @{ Name = $name }
    $maxVersion = if ($entry.PSObject.Properties['maxVersion']) { [string]$entry.maxVersion } else { $null }
    if ($maxVersion) { $latestQuery['MaximumVersion'] = $maxVersion }
    $latest = Find-GalleryModule -Query $latestQuery -Attempts $MaxAttempts -DelaySeconds $RetryDelaySeconds
    if ($null -eq $latest) { throw "Module '$name' was not found on the PowerShell Gallery." }

    # '0.0.0' is the placeholder a brand-new entry carries before its first resolution.
    $pinnedExists = $true
    if ($pinned -ne '0.0.0') {
        $pinnedExists = $null -ne (Find-GalleryModule -Query @{ Name = $name; RequiredVersion = $pinned } -Attempts $MaxAttempts -DelaySeconds $RetryDelaySeconds)
    }

    $results.Add([pscustomobject]@{
            Module  = $name
            Pinned  = $pinned
            Latest  = [string]$latest.Version
            Status  = if (-not $pinnedExists) { 'PIN-MISSING' } elseif ($pinned -eq [string]$latest.Version) { 'current' } else { 'update-available' }
        })

    $newEntry = [ordered]@{ version = [string]$latest.Version }
    if ($maxVersion) { $newEntry['maxVersion'] = $maxVersion }
    $updated[$name] = $newEntry
}

$table = $results | Format-Table -AutoSize | Out-String
Write-Information $table -InformationAction Continue

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('### PowerShell Gallery module versions', '', '| Module | Pinned | Newest | Status |', '| --- | --- | --- | --- |')
    $lines += $results | ForEach-Object { '| {0} | {1} | {2} | {3} |' -f $_.Module, $_.Pinned, $_.Latest, $_.Status }
    $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}

if ($Write) {
    $document = [ordered]@{ _comment = [string]$lock._comment; modules = $updated }
    $json = $document | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
    Write-Information "Wrote $OutputPath" -InformationAction Continue
    Write-Information $json -InformationAction Continue
}

$missing = @($results | Where-Object Status -eq 'PIN-MISSING')
if ($missing.Count -gt 0) {
    throw ("These pinned versions are no longer on the PowerShell Gallery: {0}" -f (($missing | ForEach-Object { "$($_.Module) $($_.Pinned)" }) -join ', '))
}
