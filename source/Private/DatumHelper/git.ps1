<#
.SYNOPSIS
    Executes the git command with additional arguments and error handling.

.DESCRIPTION
    This function wraps the git command, allowing it to be called with additional arguments using splatting.
    When an authentication token is present in the calling scope ($JITToken), it is injected as an HTTP
    Authorization header through git's environment-based configuration (GIT_CONFIG_COUNT/KEY/VALUE) rather
    than a command-line argument, so the token never appears on the process command line where another
    process could read it. The token may be supplied as a [SecureString] (preferred) or a plain string.

    The header is scoped to the origin (scheme://host[:port]/) of the https remote named on the call -
    `http.https://host/.extraHeader` - rather than the global `http.extraHeader`. git sends a global
    extraHeader to every HTTP host it contacts, so an unscoped header would also be forwarded to whatever
    host a redirect from the configured remote lands on, handing the pipeline token to a third party. A
    call that names no https remote (for example `git -C <dir> checkout` or `rev-parse`, which are local
    operations) gets no header at all.

    git's stderr is merged into the returned output, and every returned line is scrubbed of both the raw
    token and the base64 Basic credential derived from it before it leaves this function, so a verbose or
    failing git run cannot echo the credential into a thrown error or the pipeline log.

    HTTP Basic requires a base64-encoded "user:password" pair. Get-PipelineAuthToken returns a *raw*
    PAT (or $env:SYSTEM_ACCESSTOKEN), so passing it through verbatim produced a malformed header and
    every authenticated clone failed (#9). ConvertTo-BasicAuthCredential now normalises whichever form
    the caller supplied into a correctly encoded credential.

.PARAMETER args
    The arguments to pass to the git command.

.PARAMETER JITToken
    The token used for authorization (read from the calling scope). Optional — when absent or empty the
    git call is made unauthenticated. Accepts a [SecureString] or a plain string.

.EXAMPLE
    git clone https://example.com/repo.git

.NOTES
    Ensure that the git executable is available in the system's PATH.
#>
function git {

    # Resolve any auth token from the calling scope. A [SecureString] is revealed only
    # here, at the point of use; a plain string is accepted for back-compat. An empty or
    # absent token means an unauthenticated git call.
    $plainToken = $null
    if ($JITToken) {
        $plainToken = if ($JITToken -is [securestring]) {
            Unprotect-SecureString -SecureString $JITToken
        }
        else {
            [string]$JITToken
        }
    }

    $configVarsSet = $false
    $encodedCredential = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($plainToken)) {
            # Only authenticate a call that actually talks to an https remote, and scope the
            # header to that remote's origin so git never presents it to any other host.
            $remoteOrigin = Get-GitHttpsRemoteOrigin -Arguments $args
            if ($remoteOrigin) {
                $encodedCredential = ConvertTo-BasicAuthCredential -Token $plainToken

                # Pass the Authorization header via git's environment-based config so the token
                # stays off the process command line (argv). git reads these on start-up.
                $env:GIT_CONFIG_COUNT = '1'
                $env:GIT_CONFIG_KEY_0 = "http.$remoteOrigin.extraHeader"
                $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $encodedCredential"
                $configVarsSet = $true
            }
            else {
                Write-Verbose "[git] No https remote on this call; running it without the Authorization header."
            }
        }

        # Call git with splatting. stderr is merged in so a caller sees git's diagnostics,
        # which is exactly why each line has to be scrubbed before it is returned.
        $output = & (Get-Command git -commandType Application) @args 2>&1
        foreach ($line in @($output)) {
            if ($null -eq $line) { continue }
            Protect-GitOutputLine -Line ([string]$line) -Secret @($plainToken, $encodedCredential)
        }
    }
    catch {
        # Never surface the token: redact it from any error text before returning.
        Protect-GitOutputLine -Line ([string]$_) -Secret @($plainToken, $encodedCredential)
    }
    finally {
        # Always remove the injected variables so the token does not linger in the
        # parent environment after the call returns.
        if ($configVarsSet) {
            Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
Returns the origin ("https://host[:port]/") of the first https remote in a git argument list.

.DESCRIPTION
Used by the git wrapper to scope the injected Authorization header to the remote actually being
contacted. Returns $null when the arguments name no https URL, which is the signal to send no
credential at all.

.PARAMETER Arguments
The argument vector the git wrapper was called with.

.OUTPUTS
[string] The origin in the form git's http.<url>.* configuration matches on, or $null.
#>
function Get-GitHttpsRemoteOrigin {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Arguments
    )

    foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) { continue }

        # A caller may hand the wrapper a whole argument array as one positional value
        # (`git @('clone', $url)` passes the array itself, not its elements). PowerShell
        # expands that array into separate argv entries for the native git, so look inside
        # it here as well, or the remote would be missed and the call left unauthenticated.
        if (($argument -isnot [string]) -and ($argument -is [System.Collections.IEnumerable])) {
            $nested = Get-GitHttpsRemoteOrigin -Arguments @($argument)
            if ($nested) { return $nested }
            continue
        }

        $candidate = [string]$argument
        if ($candidate -notmatch '^(?i)https://') { continue }

        $uri = $null
        if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
            return ('{0}://{1}/' -f $uri.Scheme, $uri.Authority)
        }
    }

    return $null
}

<#
.SYNOPSIS
Replaces every occurrence of the supplied secrets in a line of git output with '***'.

.PARAMETER Line
The output line to scrub.

.PARAMETER Secret
The secret values to redact. Null or empty entries are ignored.

.OUTPUTS
[string] The scrubbed line.
#>
function Protect-GitOutputLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Secret
    )

    $scrubbed = $Line
    foreach ($value in @($Secret)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $scrubbed = $scrubbed.Replace($value, '***')
    }
    return $scrubbed
}
