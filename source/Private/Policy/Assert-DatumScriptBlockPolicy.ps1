<#
.SYNOPSIS
Stops the compile when a layer that may not use Datum script blocks contains one
(issue #86, Part B; preview).

.DESCRIPTION
A Datum.InvokeCommand block, written [x={ ... }=], is PowerShell that Datum evaluates during the
merge, in the same runspace that stamps provenance. A layer that could run one could do anything
there, including defeating the policy. So this check runs on the raw files BEFORE Datum loads
them: every data file in the configuration is attributed to its layer by path, and a block in a
file whose layer lacks the DatumScriptBlocks capability is a violation.

The check is on the text, not the parsed data, so it cannot be dodged with YAML tricks; the cost
is that the marker inside an ordinary string is also refused. Every violation is reported in one
pass.

.PARAMETER ConfigurationPath
The configuration root (the folder that holds Datum.yml).

.PARAMETER Policy
The policy from Import-CapabilityPolicy.
#>
function Assert-DatumScriptBlockPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [Parameter(Mandatory)]
        [hashtable] $Policy
    )

    $root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ConfigurationPath).ProviderPath).TrimEnd('\', '/')
    $violations = [System.Collections.Generic.List[string]]::new()

    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -in '.yml', '.yaml', '.json', '.psd1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf('[x=', [System.StringComparison]::Ordinal) -lt 0) { continue }

        $relative = $file.FullName.Substring($root.Length + 1) -replace '\\', '/'
        # Layers are matched on the path without the extension; the definition file keeps its name.
        $layerPath = if ($relative -ieq 'Datum.yml' -or $relative -ieq 'Datum.yaml') { 'Datum.yml' } else { $relative -replace '\.[^./]+$', '' }
        $layer = Get-PolicyLayer -Policy $Policy -RelativePath $layerPath

        $decision = Test-PolicyCapability -Policy $Policy -Layer $layer -Capability 'DatumScriptBlocks'
        if (-not $decision.Allowed) {
            $violations.Add("'$relative' (layer $layer) contains a Datum script block ([x={ ... }=]), which that layer is not allowed.")
        }
    }

    if ($violations.Count -gt 0) {
        throw "[Capability policy] $($violations.Count) violation(s); nothing was compiled or run:`n  - $($violations -join "`n  - ")"
    }
}
