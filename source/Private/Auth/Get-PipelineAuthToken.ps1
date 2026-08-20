<#
.SYNOPSIS
Resolves a pipeline authentication token into a SecureString.

.DESCRIPTION
Get-PipelineAuthToken normalizes credential input for the runner's git-over-HTTPS
auth. It accepts a token as a [SecureString] (returned as-is) or a plain [string]
(wrapped into a SecureString), and — when neither is supplied — falls back to a
pipeline-provided environment variable (default SYSTEM_ACCESSTOKEN, the token Azure
Pipelines exposes to a job). This lets a hosted agent authenticate without the caller
ever passing a token in the clear.

The plaintext is never written to any output stream; only the SecureString (or $null
when no credential is available) is returned.

.PARAMETER Token
An explicit token: a [SecureString] or a plain [string]. Takes precedence over the
environment fallback.

.PARAMETER FallbackEnvName
Name of the environment variable to read when -Token is empty. Defaults to
'SYSTEM_ACCESSTOKEN'.

.OUTPUTS
[securestring] The resolved token, or $null when no credential could be resolved.
#>
function Get-PipelineAuthToken {
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [object]$Token,
        [string]$FallbackEnvName = 'SYSTEM_ACCESSTOKEN'
    )

    # An explicit SecureString is already in the desired form.
    if ($Token -is [securestring]) {
        return $Token
    }

    # A non-empty plain string is wrapped without ever being emitted.
    if (($Token -is [string]) -and -not [string]::IsNullOrWhiteSpace($Token)) {
        return (ConvertTo-SecureString -String $Token -AsPlainText -Force)
    }

    # Fall back to the pipeline-provided environment token (e.g. $env:SYSTEM_ACCESSTOKEN).
    if (-not [string]::IsNullOrWhiteSpace($FallbackEnvName)) {
        $envValue = [Environment]::GetEnvironmentVariable($FallbackEnvName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            Write-Verbose "[Get-PipelineAuthToken] Using token from `$env:$FallbackEnvName."
            return (ConvertTo-SecureString -String $envValue -AsPlainText -Force)
        }
    }

    return $null
}
