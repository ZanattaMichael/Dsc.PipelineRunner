<#
.SYNOPSIS
    Executes the git command with additional arguments and error handling.

.DESCRIPTION
    This function wraps the git command, allowing it to be called with additional arguments using splatting.
    When an authentication token is present in the calling scope ($JITToken), it is injected as an HTTP
    Authorization header through git's environment-based configuration (GIT_CONFIG_COUNT/KEY/VALUE) rather
    than a command-line argument, so the token never appears on the process command line where another
    process could read it. The token may be supplied as a [SecureString] (preferred) or a plain string.
    Any error text is scrubbed of the token before being returned.

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
    try {
        if (-not [string]::IsNullOrWhiteSpace($plainToken)) {
            # Pass the Authorization header via git's environment-based config so the token
            # stays off the process command line (argv). git reads these on start-up.
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'http.extraHeader'
            $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $plainToken"
            $configVarsSet = $true
        }

        # Call git with splatting
        & (Get-Command git -commandType Application) @args 2>&1
    }
    catch {
        # Never surface the token: redact it from any error text before returning.
        $message = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($plainToken)) {
            $message = $message.Replace($plainToken, '***')
        }
        $message
    }
    finally {
        # Always remove the injected variables so the token does not linger in the
        # parent environment after the call returns.
        if ($configVarsSet) {
            Remove-Item -Path Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
        }
    }
}
