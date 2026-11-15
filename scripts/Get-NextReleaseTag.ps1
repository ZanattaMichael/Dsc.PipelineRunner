<#
.SYNOPSIS
    Works out the next release tag (vX.Y.Z or vX.Y.Z-previewNNNN) from the tags that already exist.

.DESCRIPTION
    Used by the "Create release tag" workflow, and safe to run by hand: it only reads the tag
    names it is given and writes the next one to the pipeline. It never touches git.

    Full release:   -Bump patch|minor|major   moves the highest stable tag (vX.Y.Z) up one step.
    Preview:        -Prerelease               tags the version that bump would produce, as
                                              vX.Y.Z-<label>NNNN, counting up from any previews
                                              of that same version.
    Explicit:       -Version X.Y.Z            tags exactly that core version instead of bumping.

    Refused rather than guessed: a version that is not above the highest stable release, anything that is not a plain X.Y.Z, a label that is not letters, and a
    preview counter that has run out of digits (the PowerShell Gallery orders prerelease labels
    as text, so preview10 would sort below preview2).

.PARAMETER Tag
    The existing tag names (for example the output of `git tag --list`). Names that are not
    release tags are ignored.

.PARAMETER Bump
    Which part of the highest stable version to increase. Ignored when -Version is given.

.PARAMETER Version
    An explicit X.Y.Z core version, without the leading 'v'.

.PARAMETER Prerelease
    Produce a preview tag instead of a full release.

.PARAMETER PreviewLabel
    The prerelease label. Letters only. Defaults to 'preview'.

.EXAMPLE
    ./scripts/Get-NextReleaseTag.ps1 -Tag (git tag --list) -Bump patch
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [AllowEmptyCollection()]
    [string[]]$Tag = @(),

    [ValidateSet('major', 'minor', 'patch')]
    [string]$Bump = 'patch',

    [string]$Version,

    [switch]$Prerelease,

    [string]$PreviewLabel = 'preview'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PreviewLabel -notmatch '\A[A-Za-z]{1,20}\z') {
    throw "Preview label '$PreviewLabel' is not valid. Use 1 to 20 letters (the PowerShell Gallery does not allow dots, hyphens or other characters in a prerelease label)."
}

# Tuples compare as [int[]] via this helper; a version is "above" another when the first
# differing part is larger.
function Compare-Core {
    param([int[]]$Left, [int[]]$Right)
    for ($i = 0; $i -lt 3; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return [Math]::Sign($Left[$i] - $Right[$i]) }
    }
    return 0
}

$stable = [System.Collections.Generic.List[int[]]]::new()
$existingPreviews = [System.Collections.Generic.List[object]]::new()

foreach ($name in $Tag) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ($name.Trim() -match '\Av(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-([A-Za-z]+)(\d+))?\z') {
        $core = [int[]]@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        if ($null -eq $Matches[4] -or $Matches[4] -eq '') {
            $stable.Add($core)
        }
        else {
            $existingPreviews.Add([pscustomobject]@{ Core = $core; Label = $Matches[4]; Number = [int]$Matches[5]; Width = $Matches[5].Length })
        }
    }
}

$latestStable = $null
foreach ($candidate in $stable) {
    if ($null -eq $latestStable -or (Compare-Core $candidate $latestStable) -gt 0) { $latestStable = $candidate }
}

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    if ($Version -notmatch '\A(\d{1,6})\.(\d{1,6})\.(\d{1,6})\z') {
        throw "Version '$Version' is not valid. Use X.Y.Z with no leading 'v' and no suffix."
    }
    $target = [int[]]@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}
else {
    if ($null -eq $latestStable) {
        throw "No stable release tag (vX.Y.Z) exists to bump from. Pass -Version to choose the first one."
    }
    $target = switch ($Bump) {
        'major' { [int[]]@(($latestStable[0] + 1), 0, 0) }
        'minor' { [int[]]@($latestStable[0], ($latestStable[1] + 1), 0) }
        'patch' { [int[]]@($latestStable[0], $latestStable[1], ($latestStable[2] + 1)) }
    }
}

if ($null -ne $latestStable -and (Compare-Core $target $latestStable) -le 0) {
    throw ("Version {0}.{1}.{2} is not above the latest stable release v{3}.{4}.{5}; refusing to tag it." -f `
            $target[0], $target[1], $target[2], $latestStable[0], $latestStable[1], $latestStable[2])
}

$core = '{0}.{1}.{2}' -f $target[0], $target[1], $target[2]

if (-not $Prerelease) {
    $result = "v$core"
}
else {
    $sameVersion = @($existingPreviews | Where-Object { $_.Label -eq $PreviewLabel -and (Compare-Core $_.Core $target) -eq 0 })
    $next = 1
    $width = 4
    if ($sameVersion.Count -gt 0) {
        $next = ($sameVersion | Measure-Object -Property Number -Maximum).Maximum + 1
        # Keep the width the version already uses, so the labels keep sorting in order.
        $width = ($sameVersion | Measure-Object -Property Width -Maximum).Maximum
    }
    if ("$next".Length -gt $width) {
        throw "Preview number $next no longer fits in $width digit(s) for v$core, and the PowerShell Gallery would sort it out of order. Release v$core, or choose a new version with -Version."
    }
    $result = 'v{0}-{1}{2}' -f $core, $PreviewLabel, "$next".PadLeft($width, '0')
}

$result
