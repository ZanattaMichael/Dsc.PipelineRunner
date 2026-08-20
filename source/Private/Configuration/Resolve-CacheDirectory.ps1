<#
.SYNOPSIS
Resolve the directory Datum compiles into, from an explicit value or the environment.

.DESCRIPTION
Central resolution for the cache/compile directory so the core stops hard-coding the
Azure-DevOps-era AZDODSC_CACHE_DIRECTORY variable. Resolution order:

  1. An explicit -CacheDirectory value (a caller's -CacheDirectory parameter).
  2. The environment variables named in -EnvironmentVariableName, in order. The default
     list prefers the generic PIPELINERUNNER_CACHE_DIRECTORY and keeps the legacy
     AZDODSC_CACHE_DIRECTORY as a back-compat alias.

Returns $null when nothing is set, leaving the temp-directory fallback (or a hard
requirement, depending on the caller) to the caller.

.PARAMETER CacheDirectory
An explicit cache directory. When non-empty it wins and is returned unchanged.

.PARAMETER EnvironmentVariableName
Ordered list of environment variable names to consult when -CacheDirectory is empty.
Defaults to the generic name first, then the AzDO back-compat alias.

.OUTPUTS
[string] The resolved directory, or $null when neither the parameter nor any of the
named environment variables is set.
#>
function Resolve-CacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$CacheDirectory,

        [string[]]$EnvironmentVariableName = @('PIPELINERUNNER_CACHE_DIRECTORY', 'AZDODSC_CACHE_DIRECTORY')
    )

    # 1. An explicit value always wins.
    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) {
        return $CacheDirectory
    }

    # 2. Environment variables, in preference order (generic first, AzDO alias last).
    foreach ($name in $EnvironmentVariableName) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Verbose "[Resolve-CacheDirectory] Using cache directory from `$env:$name."
            return $value
        }
    }

    # 3. Nothing set — let the caller decide (temp dir, or a hard requirement).
    return $null
}
