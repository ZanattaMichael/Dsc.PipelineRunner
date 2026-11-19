<#
.SYNOPSIS
Works out whether a passthrough document has a governed Datum configuration behind it
(issue #106).

.DESCRIPTION
A capability policy says what each LAYER of a configuration may use, and a layer is decided by
where a file sits in the Datum hierarchy. A passthrough document has no layers, so the policy
cannot be enforced over it - which makes choosing passthrough a way to step outside the policy
mechanism. -BypassDatumPolicy makes that step explicit, but it must not become a way around a
policy that exists: a caller who points passthrough at a governed configuration should run it
through the Datum path, where the policy applies.

This helper answers the question that decision needs: is there a Datum configuration behind
these documents, and does it have a policy?

  Where it looks. In the documented layout the two files sit at the configuration ROOT while a
  node file sits two levels below it (Projects/<presence>/<node>.yml), so looking only beside the
  document would miss the case worth catching. For each document, this walks from the document's
  own directory upward through its parents - the same way git finds a '.git' - and takes the
  first directory that holds a Datum definition file as the configuration root behind it. A
  policy counts only when it sits BESIDE that definition file, which is the only place
  Resolve-CapabilityPolicyPath accepts one: a Policy.yml in a sub-folder is a file a constrained
  layer could have written and is not a policy.

  What it cannot do. This recognises a configuration repository by its Datum.yml. It cannot tell
  that a document was COPIED out of a governed repository and left somewhere else - nothing in a
  flat document records where it came from, which is the whole reason the policy cannot apply to
  it. So this closes the "pointed passthrough at the repository" hole, and the switch remains a
  declaration by the caller rather than a proof. Say so wherever it is documented.

The file system is read directly ([System.IO.File] / [System.IO.Directory]) rather than through
the provider cmdlets: the answer decides whether a run is refused, so it must be about real files
on disk, and a '[' in a directory name must not be read as a wildcard.

.PARAMETER ConfigurationFile
The resolved full paths of the documents the run was given (from Resolve-PassthroughConfiguration).

.OUTPUTS
[pscustomobject] with
  GovernedRoot: the configuration root that holds BOTH a Datum definition file and a policy
                beside it, or $null. Non-null means the run must be refused, switch or no switch.
  GovernedPolicyPath / GovernedDatumPath: the two files found there, for the error message.
  DatumRoot:    a configuration root found with no policy beside it, or $null.
  StrayPolicyPath: a policy file sitting beside a document with no Datum definition file above
                it - the ambiguous case, worth a warning rather than a refusal.
#>
function Resolve-PassthroughPolicyContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ConfigurationFile
    )

    $definitionName = @('Datum.yml', 'Datum.yaml')
    $policyName     = @('Policy.yml', 'Policy.yaml')

    $firstIn = {
        param([string] $Directory, [string[]] $Names)
        foreach ($name in $Names) {
            $candidate = [System.IO.Path]::Combine($Directory, $name)
            if ([System.IO.File]::Exists($candidate)) { return $candidate }
        }
        return $null
    }

    $governedRoot = $null; $governedPolicy = $null; $governedDatum = $null
    $datumRoot = $null
    $strayPolicy = $null

    $directories = @($ConfigurationFile |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetDirectoryName($_) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)

    foreach ($directory in $directories) {

        # Walk upward to the filesystem root. GetDirectoryName returns $null at the root, so the
        # loop ends there; the step bound is belt-and-braces against a pathological path.
        $current = $directory
        $foundDatum = $null
        for ($step = 0; $step -lt 64 -and -not [string]::IsNullOrWhiteSpace($current); $step++) {
            $foundDatum = & $firstIn $current $definitionName
            if ($foundDatum) { break }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ($parent -eq $current) { break }
            $current = $parent
        }

        if ($foundDatum) {
            # A policy counts only beside the definition file (see the description).
            $foundPolicy = & $firstIn $current $policyName
            if ($foundPolicy) {
                # The strictest answer across all documents wins: one governed document refuses
                # the run.
                if (-not $governedRoot) {
                    $governedRoot = $current
                    $governedDatum = $foundDatum
                    $governedPolicy = $foundPolicy
                }
            }
            elseif (-not $datumRoot) {
                $datumRoot = $current
            }
        }
        else {
            # No configuration behind it. A policy file sitting beside the documents is then
            # ambiguous - it governs nothing this runner can resolve layers for - so it is
            # reported for a warning, not a refusal.
            if (-not $strayPolicy) {
                $strayPolicy = & $firstIn $directory $policyName
            }
        }
    }

    return [pscustomobject]@{
        GovernedRoot       = $governedRoot
        GovernedDatumPath  = $governedDatum
        GovernedPolicyPath = $governedPolicy
        DatumRoot          = $datumRoot
        StrayPolicyPath    = $strayPolicy
    }
}
