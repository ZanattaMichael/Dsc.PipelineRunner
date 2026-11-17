<#
.SYNOPSIS
Names the policy layer that owns a configuration file (issue #86, Part B; preview).

.DESCRIPTION
Provenance is derived from where a file is in the configuration repository, which a contributor
cannot choose for someone else's files, never from anything written inside the file. The first
layer (in policy order) with a matching path pattern owns the file. A file no layer claims is
returned as '(unclaimed)', which has no capabilities.

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.PARAMETER RelativePath
The file's path relative to the configuration root, without its extension (the definition file is
'Datum.yml'). Either separator is accepted.

.OUTPUTS
[string] The layer name, or '(unclaimed)'.
#>
function Get-PolicyLayer {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $RelativePath
    )

    $normalized = ($RelativePath -replace '\\', '/').Trim('/')

    # A path that climbs out of the configuration root is nobody's.
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -match '(^|/)\.\.(/|$)') { return '(unclaimed)' }

    foreach ($layer in $Policy.Layers) {
        foreach ($pattern in $layer.Paths) {
            # '**' and '*' both mean "anything, including further folders".
            $wildcard = [System.Management.Automation.WildcardPattern]::new(($pattern -replace '\*+', '*'), [System.Management.Automation.WildcardOptions]::IgnoreCase)
            if ($wildcard.IsMatch($normalized)) { return [string]$layer.Name }
        }
    }

    return '(unclaimed)'
}
