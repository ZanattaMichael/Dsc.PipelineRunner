<#
.SYNOPSIS
Reveals the plaintext of a SecureString at the point of use.

.DESCRIPTION
Unprotect-SecureString converts a [SecureString] back to a plain [string] using
System.Net.NetworkCredential, which works identically on Windows, Linux and macOS
(unlike the DPAPI-based ConvertFrom-SecureString round-trip). Callers should invoke
this only at the moment the plaintext is needed (for example, when composing an HTTP
Authorization header) and never store or log the result.

.PARAMETER SecureString
The SecureString to reveal.

.OUTPUTS
[string] The plaintext value.
#>
function Unprotect-SecureString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}
