
<#
.SYNOPSIS
Clones a Git repository into a private temporary directory.

.DESCRIPTION
Clone-Repository clones a Git repository into a freshly created, owner-only temporary
directory (see New-TemporaryDirectory) and returns that directory's path.

Only transport-encrypted remotes are accepted (#31). A plain `http://` URL is rejected
outright: the runner executes the cloned configuration as trusted code in its own
security context, so fetching it over a channel an attacker can tamper with is a remote
code execution path, not a convenience. Accepted forms are:

  * https://host/path
  * ssh://host/path  and  git://... is NOT accepted
  * SCP-style git@host:path

When -Revision is supplied the clone is checked out at that branch, tag, or commit. If a
full 40-character commit SHA is given, the resulting HEAD is verified against it and a
mismatch is a terminating error, so a pinned configuration cannot silently drift.

The resolved HEAD SHA is written to the information stream (tag 'Dsc.PipelineRunner') so
a pipeline log records exactly which commit was executed.

.PARAMETER DatumURLConfig
The URL of the Git repository to clone.

.PARAMETER Revision
Optional branch, tag, or commit to check out after cloning.

.PARAMETER DestinationPath
Optional destination directory. When omitted a new private temporary directory is created.

.EXAMPLE
Clone-Repository -DatumURLConfig "https://github.com/example/repo.git"

.EXAMPLE
Clone-Repository -DatumURLConfig "https://github.com/example/repo.git" -Revision 'v1.2.3'

.OUTPUTS
[string] The local directory the repository was cloned into.

.NOTES
Requires Git to be installed and available in the system's PATH. Authentication is
handled by the module's `git` wrapper, which reads $JITToken from the calling scope.
#>
function Clone-Repository
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory=$true)]
        [string]$DatumURLConfig,

        [Parameter()]
        [string]$Revision,

        [Parameter()]
        [string]$DestinationPath
    )

    Assert-SecureGitUrl -Url $DatumURLConfig

    # A revision is handed to `git checkout` as a positional argument. One that begins with '-'
    # would be parsed as a git option instead (for example '--orphan' or '-b'), turning a
    # pipeline parameter into argument injection, so refuse it before any git call is made.
    if ((-not [string]::IsNullOrWhiteSpace($Revision)) -and ($Revision.Trim().StartsWith('-'))) {
        throw "[Clone-Repository] Revision '$Revision' is not a valid branch, tag or commit: a revision may not begin with '-'."
    }

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $DestinationPath = New-TemporaryDirectory
    }

    # Clone the repository into the destination directory. Pass the URL *string* - an
    # earlier revision passed the boolean result of a URL validity check, so git received
    # the literal 'True' as its remote (#9). --single-branch keeps the fetch minimal.
    $cloneOutput = git clone --single-branch $DatumURLConfig $DestinationPath
    if ($LASTEXITCODE -ne 0) {
        throw "[Clone-Repository] git clone of '$DatumURLConfig' failed with exit code $LASTEXITCODE. $cloneOutput"
    }

    # Pin to the requested revision, if any. This lives here (rather than in each Source
    # action) so every caller gets the same pinning and verification behaviour.
    if (-not [string]::IsNullOrWhiteSpace($Revision)) {
        # The trailing '--' tells git the revision is a ref, never a pathspec or an option. It is
        # quoted because a bare -- is PowerShell's own end-of-parameters token, which the wrapper
        # function would consume instead of forwarding to git.
        $checkoutOutput = git -C $DestinationPath checkout --quiet $Revision '--'
        if ($LASTEXITCODE -ne 0) {
            throw "[Clone-Repository] Could not check out revision '$Revision' from '$DatumURLConfig'. $checkoutOutput"
        }
    }

    $headSha = (git -C $DestinationPath rev-parse HEAD) -join ''
    $headSha = "$headSha".Trim()

    # A full SHA is an exact pin: verify the clone actually landed on it.
    if ((-not [string]::IsNullOrWhiteSpace($Revision)) -and ($Revision -match '^[0-9a-fA-F]{40}$')) {
        if ($headSha -ne $Revision.ToLowerInvariant() -and $headSha -ne $Revision) {
            throw "[Clone-Repository] Revision verification failed for '$DatumURLConfig': expected HEAD '$Revision' but the clone is at '$headSha'."
        }
    }

    Write-Information -MessageData "[Clone-Repository] Cloned '$DatumURLConfig' at commit '$headSha' into '$DestinationPath'." -Tags 'Dsc.PipelineRunner'

    return $DestinationPath
}
