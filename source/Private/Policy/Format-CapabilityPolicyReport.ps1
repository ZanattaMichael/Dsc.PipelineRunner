<#
.SYNOPSIS
Renders a capability policy report as lines of text for a person to read
(Get-DscCapabilityPolicyReport -AsText; issue #86, Part B).

.DESCRIPTION
Plain text rather than a formatted object, so the same output is readable in a terminal, in a
pipeline log and in a pull-request comment. Returns an array of lines; the caller decides what to
do with them.

.PARAMETER Report
The report object from Get-DscCapabilityPolicyReport.

.OUTPUTS
[string[]] The report as lines of text.
#>
function Format-CapabilityPolicyReport {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Report
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Capability policy report for '$($Report.ConfigurationPath)'")

    if (-not $Report.PolicyPath) {
        $lines.Add('')
        $lines.Add('  No policy. Every layer may use everything the runner can do.')
        foreach ($finding in $Report.Findings) { $lines.Add("  [$($finding.Severity)] $($finding.Message)") }
        return [string[]]$lines.ToArray()
    }

    $lines.Add("  Policy:  $($Report.PolicyPath)")
    $lines.Add("  SHA-256: $($Report.PolicySha256)")
    $lines.Add("  Default: $($Report.Default)")

    $lines.Add('')
    $lines.Add('What the policy permits')
    foreach ($layer in $Report.Layers) {
        $lines.Add('')
        $lines.Add("  Layer '$($layer.Name)' - $($layer.FileCount) file(s)")
        $lines.Add("    Paths: $($layer.Paths -join ', ')")
        foreach ($capability in $layer.Capabilities.Keys) {
            $lines.Add(('    {0,-18} {1}' -f $capability, $layer.Capabilities[$capability]))
        }
    }

    $lines.Add('')
    $lines.Add('PipelineRunnerSettings Datum.yml may hold (Settings)')
    if ($null -eq $Report.Settings -or $Report.Settings.Count -eq 0) {
        $lines.Add('  Not governed: the policy has no Settings block.')
    }
    else {
        foreach ($key in ($Report.Settings.Keys | Sort-Object)) {
            $values = @($Report.Settings[$key] | ForEach-Object { if ($_ -is [bool]) { "$_".ToLowerInvariant() } else { $_ } })
            $lines.Add(('  {0,-22} {1}' -f $key, ($values -join ', ')))
        }
    }

    if (@($Report.ResolutionPrecedence).Count -gt 0) {
        $lines.Add('')
        $lines.Add('The hierarchy, by layer (Datum.yml ResolutionPrecedence)')
        foreach ($entry in $Report.ResolutionPrecedence) {
            $lines.Add(('  {0,-14} {1}' -f $entry.Layer, $entry.Path))
        }
    }

    if (@($Report.Files).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Files, by layer')
        foreach ($file in $Report.Files) {
            $lines.Add(('  {0,-14} {1}' -f $file.Layer, $file.File))
        }
    }

    if (@($Report.Resources).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Resource declarations (advisory: the files, not the merge)')
        foreach ($resource in $Report.Resources) {
            $verdict = if ($resource.Allowed) { 'allowed' } else { 'REFUSED' }
            $lines.Add(('  {0,-8} {1,-14} {2} [{3}] in {4}' -f $verdict, ($resource.DeclaringLayers -join '+'), $resource.Name, $resource.Type, $resource.DeclaredIn))
            foreach ($refusal in @($resource.Refusals)) { $lines.Add("             - $refusal") }
        }
    }

    $lines.Add('')
    $lines.Add('Findings')
    if (@($Report.Findings).Count -eq 0) {
        $lines.Add('  None.')
    }
    else {
        foreach ($severity in 'Error', 'Warning', 'Information') {
            foreach ($finding in @($Report.Findings | Where-Object { $_.Severity -eq $severity })) {
                $lines.Add("  [$severity] $($finding.Code): $($finding.Message)")
            }
        }
    }

    $lines.Add('')
    $lines.Add('This report reads the configuration''s files; it does not perform Datum''s merge. A run')
    $lines.Add('(Invoke-DscRunner) is what enforces the policy, against the compiled file and the')
    $lines.Add('provenance record, and it can refuse something this report shows as allowed.')

    return [string[]]$lines.ToArray()
}
