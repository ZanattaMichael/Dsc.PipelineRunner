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

<#
.SYNOPSIS
Turns a configuration file's path into the path a policy's Paths patterns are matched against
(issue #86, Part B).

.DESCRIPTION
Layers are matched on a file's path relative to the configuration root, with forward slashes and
without the file extension - except the Datum definition file, which is written with its name
('Datum.yml') because that is how a policy author refers to it. Kept in one place so every caller
that attributes a file to a layer (the pre-compile script-block scan, the coverage report) agrees
on what a path means.

.PARAMETER Root
The configuration root.

.PARAMETER FullName
The file's full path, inside that root.

.OUTPUTS
[string] The relative layer path, or $null when the file is not inside the root.
#>
function ConvertTo-PolicyLayerPath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $FullName
    )

    $normalizedRoot = $Root.TrimEnd('\', '/')
    if ($FullName.Length -le $normalizedRoot.Length + 1) { return $null }

    $relative = $FullName.Substring($normalizedRoot.Length + 1) -replace '\\', '/'
    if ($relative -ieq 'Datum.yml' -or $relative -ieq 'Datum.yaml') { return 'Datum.yml' }
    return ($relative -replace '\.[^./]+$', '')
}
