
<#
.SYNOPSIS
Validates that a git remote URL uses a transport-encrypted scheme.

.DESCRIPTION
The runner executes the configuration it clones as trusted PowerShell in its own security
context. Fetching that configuration over an unauthenticated, unencrypted transport lets
anyone on the network path substitute the code that will be executed, so Assert-SecureGitUrl
rejects everything except:

  * https://host/path        - TLS-protected HTTP
  * ssh://[user@]host/path   - SSH
  * user@host:path           - SCP-style SSH shorthand (for example git@github.com:org/repo.git)

Notably rejected: http:// and git:// (both plaintext and unauthenticated), and file://
(not a remote at all). See issue #31.

.PARAMETER Url
The remote URL to validate.

.EXAMPLE
Assert-SecureGitUrl -Url 'https://github.com/example/repo.git'

.EXAMPLE
Assert-SecureGitUrl -Url 'http://github.com/example/repo.git'
Throws: the http scheme is not permitted.

.OUTPUTS
None. Throws a terminating error when the URL is not acceptable.
#>
# Returns a URL that is safe to print: credentials embedded in the URL (https://user:token@host,
# https://token@host, ssh://user:password@host) are replaced with ***. The URL handed to git is
# never changed - this is only for messages, logs and exception text. SCP-style git@host:path
# and ssh://git@host/path carry no secret in the user part, so they are left as written.
function Hide-GitUrlCredential {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url
    )

    if ([string]::IsNullOrEmpty($Url)) { return $Url }

    $masked = $Url -replace '^(?i)(https?://)[^/@\s]+@', '$1***@'
    return ($masked -replace '^(?i)([a-z][a-z0-9+.-]*://[^/@:\s]+):[^/@\s]*@', '$1:***@')
}

function Assert-SecureGitUrl {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "[Assert-SecureGitUrl] No repository URL was supplied."
    }

    $candidate = $Url.Trim()

    # A leading '-' would be read by git as an option (--upload-pack=..., -oProxyCommand=...)
    # rather than as a repository, whatever follows it.
    if ($candidate.StartsWith('-')) {
        throw "[Assert-SecureGitUrl] The specified Git URL is invalid: it may not begin with '-'."
    }

    # SCP-style shorthand (git@host:path) is not a URI, so match it before parsing. The user part
    # and host must begin with an alphanumeric: '-u@host:path' and 'git@-host:x' satisfy a
    # looser pattern but are option-shaped.
    if ($candidate -match '^[A-Za-z0-9_][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*:(?!//).+$') {
        return
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "[Assert-SecureGitUrl] The specified Git URL is invalid: '$(Hide-GitUrlCredential -Url $Url)'."
    }

    $allowedSchemes = @('https', 'ssh')
    if ($uri.Scheme -notin $allowedSchemes) {
        throw "[Assert-SecureGitUrl] The '$($uri.Scheme)' scheme is not permitted for a configuration repository; use https or ssh. The configuration is executed as trusted code, so it must not be fetched over an unencrypted or unauthenticated transport. URL: '$(Hide-GitUrlCredential -Url $Url)'."
    }
}
