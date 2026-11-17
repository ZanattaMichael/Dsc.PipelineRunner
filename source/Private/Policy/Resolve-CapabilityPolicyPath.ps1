<#
.SYNOPSIS
Finds the capability policy file for a configuration (issue #86, Part B; preview).

.DESCRIPTION
The policy is a file of its own at the root of the configuration, beside Datum.yml: Policy.yml
(or Policy.yaml). When it is there it applies; nothing has to be passed. It is separate from
Datum.yml and outside the Datum hierarchy, so it is never merged with anything.

An explicit -PolicyPath wins over the file in the configuration, so a pipeline can impose its own
policy. -Require makes a missing policy an error, for a pipeline that must not run a configuration
that has (or has been stripped of) no policy.

.OUTPUTS
[string] The policy file path, or $null when there is no policy.
#>
function Resolve-CapabilityPolicyPath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [string] $PolicyPath,

        [switch] $Require
    )

    if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
        if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { throw "[Capability policy] The policy file '$PolicyPath' does not exist." }
        return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PolicyPath).ProviderPath)
    }

    foreach ($name in 'Policy.yml', 'Policy.yaml') {
        $candidate = [System.IO.Path]::Combine($ConfigurationPath, $name)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).ProviderPath)
        }
    }

    if ($Require) {
        throw "[Capability policy] A policy is required for this run, but the configuration has no Policy.yml beside its Datum.yml and no -PolicyPath was given."
    }
    return $null
}
