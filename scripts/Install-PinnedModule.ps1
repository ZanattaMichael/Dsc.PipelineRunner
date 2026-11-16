<#
.SYNOPSIS
    Installs PowerShell Gallery modules at the exact versions pinned in scripts/module-versions.json.

.DESCRIPTION
    Every Gallery module CI, the container image and the build rely on goes through this script, so
    the version that runs is the version that was reviewed, not whatever the Gallery offers today.

      * Each module is installed with -RequiredVersion taken from the lock file. A module that is
        not in the lock file is an error: nothing is installed "at latest" by accident.
      * A module whose exact version is already available is left alone, so a warm runner is not
        re-provisioned on every run.
      * A failed or truncated download is retried with a growing pause. The Gallery drops a request
        now and then (a corrupt download once failed a release gate); a retry is the fix, not a
        re-run of the whole pipeline.
      * After each install the exact version is checked to be present, so a silent partial install
        cannot pass.

    What this does not do: the Gallery publishes no checksum this script can verify, so pinning
    stops a new version arriving unannounced but does not prove the bytes are genuine. Modules
    that a pinned module pulls in as its own dependencies are resolved by PowerShellGet and are
    not pinned here.

.PARAMETER Name
    The modules to install. Each must be listed in the lock file.

.PARAMETER Scope
    CurrentUser (default) or AllUsers (needs elevation; used by the container image).

.PARAMETER LockFile
    The lock file. Defaults to module-versions.json next to this script.

.PARAMETER MaxAttempts
    How many times one install is tried.

.PARAMETER RetryDelaySeconds
    Pause between attempts, multiplied by the attempt number.

.EXAMPLE
    ./scripts/Install-PinnedModule.ps1 -Name Datum, Datum.InvokeCommand, powershell-yaml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name,

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [string]$LockFile = (Join-Path $PSScriptRoot 'module-versions.json'),

    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 4,

    [ValidateRange(0, 120)]
    [int]$RetryDelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
    throw "Module lock file '$LockFile' was not found."
}
$lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json

foreach ($moduleName in $Name) {
    $entry = $lock.modules.PSObject.Properties | Where-Object { $_.Name -ieq $moduleName } | Select-Object -First 1
    if ($null -eq $entry) {
        throw "Module '$moduleName' is not pinned in $LockFile. Add it there (and run the 'Update module versions' workflow) instead of installing it unpinned."
    }

    $version = [string]$entry.Value.version
    if ($version -notmatch '\A\d+\.\d+\.\d+(\.\d+)?\z' -or $version -eq '0.0.0') {
        throw "Module '$moduleName' has no usable pinned version ('$version') in $LockFile."
    }

    $present = Get-Module -ListAvailable -Name $entry.Name | Where-Object { [string]$_.Version -eq $version }
    if ($present) {
        Write-Information "$($entry.Name) $version is already installed." -InformationAction Continue
        continue
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Information "Installing $($entry.Name) $version (attempt $attempt of $MaxAttempts) ..." -InformationAction Continue
            Install-Module -Name $entry.Name -RequiredVersion $version -Repository PSGallery -Scope $Scope `
                -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop

            if (-not (Get-Module -ListAvailable -Name $entry.Name | Where-Object { [string]$_.Version -eq $version })) {
                throw "Install-Module returned, but $($entry.Name) $version is not available afterwards."
            }
            break
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw "Could not install $($entry.Name) $version after $MaxAttempts attempts: $($_.Exception.Message)"
            }
            Write-Warning "Installing $($entry.Name) $version failed: $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds ($RetryDelaySeconds * $attempt)
        }
    }
}
