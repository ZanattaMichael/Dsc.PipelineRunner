<#
.SYNOPSIS
Helpers for keeping sensitive configuration values out of the pipeline log.

.DESCRIPTION
DSC resource properties routinely carry secrets — passwords, tokens, keys, connection
strings. Pipeline logs are readable by a wider audience than the configuration repository
and are retained and forwarded (see issue #34), so a value that fails validation must not
be echoed verbatim. Test-SensitivePropertyName recognises conventionally-named sensitive
properties, and Protect-SensitiveValue returns a redacted placeholder for them so callers
can log a breadcrumb without leaking the secret.

.NOTES
Name matching is a heuristic, not a guarantee: the authoritative control is simply not to
print property values (the validation diagnostics name the property and resource only).
These helpers redact the opt-in, verbose breadcrumbs that remain.
#>

function Test-SensitivePropertyName {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name
    )

    # Substring, case-insensitive match against conventional secret-bearing names. Erring
    # toward redaction is deliberate: a false positive hides an innocuous value; a false
    # negative leaks a secret.
    $patterns = @(
        'password'
        'passphrase'
        'secret'
        'token'
        'key'
        'credential'
        'connectionstring'
    )

    foreach ($pattern in $patterns) {
        if ($Name -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Protect-SensitiveValue {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if (Test-SensitivePropertyName -Name $Name) {
        return '[REDACTED]'
    }

    if ($null -eq $Value) {
        return ''
    }

    return [string]$Value
}
