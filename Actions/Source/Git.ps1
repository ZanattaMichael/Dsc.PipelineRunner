<#
.SYNOPSIS
Source action: clone a git repository and use it as the configuration source.

.DESCRIPTION
Clones any git remote (HTTPS or SSH) into a scoped temporary directory and returns
that path. This is the generic, provider-agnostic replacement for the old
Azure-DevOps-only clone path — GitHub, GitLab, Bitbucket and Azure DevOps all speak
the same git-over-HTTPS/SSH protocol.

Authentication, when needed, is resolved through Get-PipelineAuthToken: an explicit
context token (SecureString or string) takes precedence, otherwise the pipeline-provided
$env:SYSTEM_ACCESSTOKEN is used. The module's `git` wrapper injects the resolved token
as an HTTP Authorization header without exposing it on the process command line.

.PARAMETER Context
A hashtable. Recognized keys:
  Url      - the git remote to clone (required).
  Token    - optional credential (PAT / JIT) for git-over-HTTPS auth; a [SecureString]
             or a plain string. When omitted, $env:SYSTEM_ACCESSTOKEN is used if present.
  Revision - optional branch, tag, or commit to check out after cloning.

.OUTPUTS
[string] The local directory the repository was cloned into.
#>
param(
    [hashtable]$Context = @{}
)

$url = $Context.Url
if ([string]::IsNullOrWhiteSpace($url)) {
    # Fall back to Path for callers that pass a source location under a single key.
    $url = $Context.Path
}

if ([string]::IsNullOrWhiteSpace($url)) {
    throw "[Actions/Source/Git] No 'Url' supplied in the action context."
}

# Resolve the credential into a SecureString: an explicit Context.Token, else the
# pipeline-provided $env:SYSTEM_ACCESSTOKEN. The `git` wrapper reads $JITToken from
# this scope to build the HTTP Authorization header. $null means an unauthenticated
# clone (public remote / local path).
$JITToken = Get-PipelineAuthToken -Token $Context.Token

Write-Verbose "[Actions/Source/Git] Cloning '$url'."
$clonePath = Clone-Repository -DatumURLConfig $url

# Optionally pin to a specific revision.
if (-not [string]::IsNullOrWhiteSpace($Context.Revision)) {
    Write-Verbose "[Actions/Source/Git] Checking out revision '$($Context.Revision)'."
    $null = git -C $clonePath checkout $Context.Revision
}

return $clonePath
