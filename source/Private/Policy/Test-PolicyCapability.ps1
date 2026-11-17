<#
.SYNOPSIS
Decides whether a set of layers may use a capability (issue #86, Part B; preview).

.DESCRIPTION
Least privilege: something that several layers contributed to is allowed only if EVERY one of
those layers is allowed it. So a resource a platform layer declares and an application layer
overrides runs with the application layer's permissions.

For a list capability (Targets, Engines) -Value is the name being used, matched against the
layer's patterns. For a switch capability (ExecutionScripts, DatumScriptBlocks) -Value is omitted.
A capability a layer does not list falls back to the policy's Default. The '(unclaimed)' layer is
denied everything.

.OUTPUTS
[pscustomobject] Allowed ([bool]) and DeniedBy ([string[]], the layers that refused).
#>
function Test-PolicyCapability {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Policy,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Layer,

        [Parameter(Mandatory)]
        [ValidateSet('Targets', 'Engines', 'ExecutionScripts', 'DatumScriptBlocks')]
        [string] $Capability,

        [string] $Value
    )

    $deniedBy = [System.Collections.Generic.List[string]]::new()

    # Nothing contributed by any known layer cannot be attributed, so it cannot be allowed.
    $layers = @($Layer | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($layers.Count -eq 0) { $layers = @('(unclaimed)') }

    foreach ($name in $layers) {
        $definition = $Policy.Layers | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($null -eq $definition) { $deniedBy.Add($name); continue }

        $allowed = $false
        if ($definition.Capabilities.ContainsKey($Capability)) {
            $rule = $definition.Capabilities[$Capability]
            if ($rule -is [bool]) {
                $allowed = $rule
            }
            else {
                foreach ($pattern in @($rule)) {
                    if ([System.Management.Automation.WildcardPattern]::new([string]$pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Value)) { $allowed = $true; break }
                }
            }
        }
        else {
            $allowed = $Policy.Default -eq 'Allow'
        }

        if (-not $allowed) { $deniedBy.Add($name) }
    }

    return [pscustomobject]@{ Allowed = ($deniedBy.Count -eq 0); DeniedBy = [string[]]$deniedBy.ToArray() }
}
