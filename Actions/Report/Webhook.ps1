<#
.SYNOPSIS
Report action: POST a file's report document to an HTTPS endpoint (#85).

.DESCRIPTION
Sends the report document as JSON to a third-party service. Selected by naming it in
PipelineRunnerSettings.Report.Reporters, with its settings under PipelineRunnerSettings.Report.Webhook:

    PipelineRunnerSettings:
      Report:
        Reporters: [ Webhook ]
        Webhook:
          Uri: https://reports.example.com/dsc
          Credential:                       # optional
            action: Environment             # a Credential action (default: Environment)
            UserNameVariable: REPORT_USER
            PasswordVariable: REPORT_TOKEN

What it guarantees:
  * https only. A plain http endpoint, a relative URL, or a URL carrying user:password@ is refused
    before anything is sent.
  * The token comes from a Credential action and is sent in a header (Authorization: Bearer by
    default), never in the URL and never on a command line.
  * Redirects are not followed, so the token and the report are never handed to a different host.
  * An error names the host and the HTTP status only. The response body is never included (a
    service can echo the request, and so the token, back in an error page), and neither is the
    token or the URL's path and query.
  * A failed attempt is retried with a growing pause; the last failure is thrown for the runner
    to report. The runner's result does not depend on this action.

.PARAMETER Context
Hashtable with:
  Document [IDictionary] - required, the report document.
  Settings [IDictionary] - required:
      Uri            [string] - required, absolute https URL.
      Credential     [map]    - optional Credential-action context; its password is the token.
      Header         [string] - header to carry the token (default 'Authorization').
      Scheme         [string] - word before the token (default 'Bearer'; empty for none).
      TimeoutSeconds [int]    - per attempt (default 30).
      MaxAttempts    [int]    - default 3.

.OUTPUTS
[pscustomobject] Reporter, Host, StatusCode, Attempts.
#>
param(
    [hashtable]$Context = @{}
)

$settings = $Context.Settings
if ($settings -isnot [System.Collections.IDictionary]) {
    throw "[Actions/Report/Webhook] No settings were supplied. Add PipelineRunnerSettings.Report.Webhook with a Uri."
}
if ($null -eq $Context.Document) {
    throw "[Actions/Report/Webhook] No report document was supplied."
}

$uriText = [string]$settings['Uri']
$uri = $null
if ([string]::IsNullOrWhiteSpace($uriText) -or -not [uri]::TryCreate($uriText, [System.UriKind]::Absolute, [ref]$uri)) {
    throw "[Actions/Report/Webhook] 'Uri' is required and must be an absolute https URL."
}
if ($uri.Scheme -ne 'https') {
    throw "[Actions/Report/Webhook] The '$($uri.Scheme)' scheme is not permitted for a report endpoint; use https."
}
if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
    throw "[Actions/Report/Webhook] The report endpoint URL must not carry a user name or password. Supply the token through 'Credential' instead."
}
$endpointHost = $uri.Host

$timeoutSeconds = if ($settings['TimeoutSeconds']) { [int]$settings['TimeoutSeconds'] } else { 30 }
$maxAttempts = if ($settings['MaxAttempts']) { [int]$settings['MaxAttempts'] } else { 3 }
if ($timeoutSeconds -lt 1 -or $timeoutSeconds -gt 300) { throw "[Actions/Report/Webhook] 'TimeoutSeconds' must be between 1 and 300." }
if ($maxAttempts -lt 1 -or $maxAttempts -gt 10) { throw "[Actions/Report/Webhook] 'MaxAttempts' must be between 1 and 10." }

$headers = @{ 'User-Agent' = 'Dsc.PipelineRunner' }

if ($null -ne $settings['Credential']) {
    $credentialContext = $settings['Credential']
    if ($credentialContext -isnot [System.Collections.IDictionary]) {
        throw "[Actions/Report/Webhook] 'Credential' must be a mapping (a Credential-action context)."
    }
    $credentialAction = if (-not [string]::IsNullOrWhiteSpace([string]$credentialContext['action'])) { [string]$credentialContext['action'] } else { 'Environment' }
    $resolved = Invoke-Action -Hook Credential -Name $credentialAction -Context ([hashtable]$credentialContext)

    $token = if ($resolved -is [System.Management.Automation.PSCredential]) { $resolved.GetNetworkCredential().Password }
             elseif ($resolved -is [securestring]) { [System.Net.NetworkCredential]::new('', $resolved).Password }
             else { $null }
    if ([string]::IsNullOrEmpty($token)) {
        throw "[Actions/Report/Webhook] The Credential action '$credentialAction' did not return a credential with a password to use as the token."
    }

    $headerName = if (-not [string]::IsNullOrWhiteSpace([string]$settings['Header'])) { [string]$settings['Header'] } else { 'Authorization' }
    if ($headerName -notmatch '\A[A-Za-z0-9-]{1,64}\z') { throw "[Actions/Report/Webhook] 'Header' is not a valid header name." }
    $scheme = if ($settings.Contains('Scheme')) { [string]$settings['Scheme'] } else { 'Bearer' }
    if ($scheme -and $scheme -notmatch '\A[A-Za-z0-9-]{1,32}\z') { throw "[Actions/Report/Webhook] 'Scheme' is not valid." }
    $headers[$headerName] = if ($scheme) { "$scheme $token" } else { $token }
}

$body = $Context.Document | ConvertTo-Json -Depth 20 -Compress

$lastProblem = $null
$attemptsMade = 0
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $statusCode = $null
    $attemptsMade = $attempt
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Body $body -ContentType 'application/json; charset=utf-8' `
            -Headers $headers -TimeoutSec $timeoutSeconds -MaximumRedirection 0 -SkipHttpErrorCheck -UseBasicParsing -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
    }
    catch {
        # Deliberately not the exception's message: it can carry the URL (path and query) and a
        # response body. The type is enough to tell a timeout from a name-resolution failure.
        $lastProblem = "the request failed ($($_.Exception.GetType().Name))"
    }

    if ($null -ne $statusCode) {
        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            return [pscustomobject]@{ Reporter = 'Webhook'; Host = $endpointHost; StatusCode = $statusCode; Attempts = $attempt }
        }
        $lastProblem = "the endpoint answered HTTP $statusCode"
        # A redirect or a client error will not improve on a retry.
        if ($statusCode -lt 500 -and $statusCode -ne 429) { break }
    }

    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds ([Math]::Min(30, 2 * $attempt)) }
}

throw "[Actions/Report/Webhook] The report could not be delivered to '$endpointHost' after $attemptsMade attempt(s): $lastProblem."
