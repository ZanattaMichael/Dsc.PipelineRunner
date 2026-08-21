<#
.SYNOPSIS
Source action: use a local directory as the configuration source.

.DESCRIPTION
The default Source action. It validates that the supplied path is an existing
directory and returns it unchanged, so the runner can compile Datum straight from
a local checkout with no clone and no remote provider.

.PARAMETER Context
A hashtable. Recognized key:
  Path - the local configuration directory (required).

.OUTPUTS
[string] The resolved local configuration directory.
#>
param(
    [hashtable]$Context = @{}
)

$path = $Context.Path

if ([string]::IsNullOrWhiteSpace($path)) {
    throw "[Actions/Source/Local] No 'Path' supplied in the action context."
}

if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    throw "[Actions/Source/Local] The configuration path '$path' does not exist or is not a directory."
}

Write-Verbose "[Actions/Source/Local] Using local configuration directory: $path"
return $path
