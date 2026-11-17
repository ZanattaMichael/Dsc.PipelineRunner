<#
.SYNOPSIS
Report action: write a readable Markdown summary of a file's results (#85).

.DESCRIPTION
Writes a short Markdown summary: the totals, then a table of the resources that failed or were
skipped (and, with ListAll, every resource). On GitHub Actions it is appended to the job summary
($env:GITHUB_STEP_SUMMARY); with a directory (Settings.Path or -ReportPath) it is also written to
<NodeName>.summary.md, which Azure Pipelines can show with the task.uploadsummary command.

    PipelineRunnerSettings:
      Report:
        Reporters: [ Summary ]
        Summary:
          ListAll: true          # optional; default lists only FAIL and SKIP
          Path: ./reports        # optional; defaults to -ReportPath

Resource names and error messages are not trusted text. Every cell is escaped so it cannot add
table columns or rows, HTML, links or images to the page it is shown on, and the table is capped
so one configuration cannot flood a job summary.

.PARAMETER Context
Hashtable with Document (required), Settings (optional: ListAll, Path), NodeName, ReportPath.

.OUTPUTS
[pscustomobject] Reporter, Path, JobSummary.
#>
param(
    [hashtable]$Context = @{}
)

# With Report.Stream the runner also calls a reporter once per resource. A summary describes a
# whole file, so a resource event is ignored; the end-of-file document is what gets written.
if ([string]$Context.Event -eq 'Resource') { return }

$document = $Context.Document
if ($null -eq $document) { throw "[Actions/Report/Summary] No report document was supplied." }
$settings = if ($Context.Settings -is [System.Collections.IDictionary]) { $Context.Settings } else { @{} }

$maxRows = 200
$maxCell = 300

# One table cell of untrusted text: a single line, length-limited, with every character that
# Markdown or HTML gives meaning to escaped.
$cell = {
    param($Text)
    if ($null -eq $Text) { return '' }
    $value = [regex]::Replace([string]$Text, '[\x00-\x1F\x7F\u0085  ]+', ' ')
    if ($value.Length -gt $maxCell) { $value = $value.Substring(0, $maxCell) + '...' }
    $value = $value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    return [regex]::Replace($value, '([\\`*_{}\[\]()#+!|~-])', '\$1')
}

$results = @($document['Results'])
$listAll = [bool]$settings['ListAll']
$listed = @(if ($listAll) { $results } else { $results | Where-Object { $_['Status'] -in 'FAIL', 'SKIP' } })

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("### DSC run: $(& $cell $document['NodeName'])")
$lines.Add('')
$lines.Add("**$(& $cell $document['Status'])** in $(& $cell $document['Mode']) mode, engine $(& $cell $document['Engine']).")
$lines.Add('')
$lines.Add('| Total | Passed | Failed | Skipped | Seconds |')
$lines.Add('| ---: | ---: | ---: | ---: | ---: |')
$lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f [int]$document['TotalResources'], [int]$document['PassCount'], [int]$document['FailCount'], [int]$document['SkipCount'], ([double]$document['DurationSeconds']).ToString('0.###', [cultureinfo]::InvariantCulture)))

if (-not [string]::IsNullOrEmpty([string]$document['ErrorMessage'])) {
    $lines.Add('')
    $lines.Add("Run error: $(& $cell $document['ErrorMessage'])")
}

if ($listed.Count -gt 0) {
    $lines.Add('')
    $lines.Add('| Status | Resource | Drifted | Set ran | Message |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($result in ($listed | Select-Object -First $maxRows)) {
        $drifted = if ($null -eq $result['Drifted']) { '' } elseif ($result['Drifted']) { 'yes' } else { 'no' }
        $setRan = if ($result['SetInvoked']) { 'yes' } else { 'no' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f (& $cell $result['Status']), (& $cell ("{0}/{1}" -f $result['ResourceType'], $result['InstanceName'])), $drifted, $setRan, (& $cell $result['ErrorMessage'])))
    }
    if ($listed.Count -gt $maxRows) {
        $lines.Add('')
        $lines.Add("$($listed.Count - $maxRows) more not shown.")
    }
}
$lines.Add('')

$text = $lines -join "`n"
$wroteJobSummary = $false
$path = $null

$jobSummary = [string]$env:GITHUB_STEP_SUMMARY
if (-not [string]::IsNullOrWhiteSpace($jobSummary)) {
    Add-Content -LiteralPath $jobSummary -Value $text -Encoding utf8
    $wroteJobSummary = $true
}

$directory = if (-not [string]::IsNullOrWhiteSpace([string]$settings['Path'])) { [string]$settings['Path'] } else { [string]$Context.ReportPath }
if (-not [string]::IsNullOrWhiteSpace($directory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "[Actions/Report/Summary] The report directory does not exist."
    }
    # Only the last path segment of the node name is used, so the file stays in the directory.
    $nodeName = [System.IO.Path]::GetFileName([string]$document['NodeName'])
    if ([string]::IsNullOrWhiteSpace($nodeName) -or $nodeName -in '.', '..') { $nodeName = 'node' }
    $path = [System.IO.Path]::Combine($directory, ("{0}.summary.md" -f $nodeName))
    Set-Content -LiteralPath $path -Value $text -Encoding utf8
}

if (-not $wroteJobSummary -and $null -eq $path) {
    throw "[Actions/Report/Summary] Nowhere to write the summary: this is not a GitHub Actions job, and no directory was given (PipelineRunnerSettings.Report.Summary.Path or -ReportPath)."
}

return [pscustomobject]@{ Reporter = 'Summary'; Path = $path; JobSummary = $wroteJobSummary }
