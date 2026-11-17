<#
.SYNOPSIS
Report action: write a file's results as JUnit XML, so a CI system shows them natively (#85).

.DESCRIPTION
Writes <NodeName>.junit.xml: one test suite per compiled file, one test case per resource.
A FAIL becomes a <failure>, a SKIP becomes <skipped>. GitHub Actions, Azure Pipelines, GitLab and
Jenkins all read this format with their standard "publish test results" step.

    PipelineRunnerSettings:
      Report:
        Reporters: [ JUnit ]
        JUnit:
          Path: ./reports        # optional; defaults to -ReportPath

Resource names and error messages are not trusted text: they are written through an XML writer
(so they cannot add elements or attributes), and characters XML does not allow are removed. The
file name is built from the node name's last path segment only, so it cannot be written outside
the report directory.

.PARAMETER Context
Hashtable with Document (required), Settings (optional: Path), NodeName, ReportPath.

.OUTPUTS
[pscustomobject] Reporter, Path.
#>
param(
    [hashtable]$Context = @{}
)

# With Report.Stream the runner also calls a reporter once per resource. A JUnit file describes a
# whole file, so a resource event is ignored; the end-of-file document is what gets written.
if ([string]$Context.Event -eq 'Resource') { return }

$document = $Context.Document
if ($null -eq $document) { throw "[Actions/Report/JUnit] No report document was supplied." }

$settings = if ($Context.Settings -is [System.Collections.IDictionary]) { $Context.Settings } else { @{} }
$directory = if (-not [string]::IsNullOrWhiteSpace([string]$settings['Path'])) { [string]$settings['Path'] } else { [string]$Context.ReportPath }
if ([string]::IsNullOrWhiteSpace($directory)) {
    throw "[Actions/Report/JUnit] No directory to write to. Set PipelineRunnerSettings.Report.JUnit.Path or pass -ReportPath."
}
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "[Actions/Report/JUnit] The report directory does not exist."
}

# Only the last path segment of the node name is used, so the file stays in the directory.
$nodeName = [System.IO.Path]::GetFileName([string]$document['NodeName'])
if ([string]::IsNullOrWhiteSpace($nodeName) -or $nodeName -in '.', '..') { $nodeName = 'node' }
$path = [System.IO.Path]::Combine($directory, ("{0}.junit.xml" -f $nodeName))

# XML 1.0 forbids most control characters outright; an XML writer throws on them.
$clean = {
    param($Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace([string]$Text, '[^\x09\x0A\x0D\x20-퟿-�]', '')
}

$results = @($document['Results'])
$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.Indent = $true
$writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)

$stream = [System.IO.File]::Create($path)
try {
    $writer = [System.Xml.XmlWriter]::Create($stream, $writerSettings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('testsuites')
        $writer.WriteStartElement('testsuite')
        $writer.WriteAttributeString('name', (& $clean $nodeName))
        $writer.WriteAttributeString('tests', [string]$results.Count)
        $writer.WriteAttributeString('failures', [string]@($results | Where-Object { $_['Status'] -eq 'FAIL' }).Count)
        $writer.WriteAttributeString('skipped', [string]@($results | Where-Object { $_['Status'] -eq 'SKIP' }).Count)
        $writer.WriteAttributeString('errors', $(if ($document['Status'] -eq 'AbortedByException') { '1' } else { '0' }))
        $writer.WriteAttributeString('time', ([double]$document['DurationSeconds']).ToString('0.###', [cultureinfo]::InvariantCulture))

        foreach ($result in $results) {
            $writer.WriteStartElement('testcase')
            $writer.WriteAttributeString('classname', (& $clean $nodeName))
            $writer.WriteAttributeString('name', (& $clean ("{0}/{1}" -f $result['ResourceType'], $result['InstanceName'])))
            $writer.WriteAttributeString('time', ([double]$result['DurationMs'] / 1000).ToString('0.###', [cultureinfo]::InvariantCulture))
            if ($result['Status'] -eq 'FAIL') {
                $writer.WriteStartElement('failure')
                $writer.WriteAttributeString('message', (& $clean $result['ErrorMessage']))
                $writer.WriteEndElement()
            }
            elseif ($result['Status'] -eq 'SKIP') {
                $writer.WriteStartElement('skipped')
                $writer.WriteAttributeString('message', (& $clean $result['ErrorMessage']))
                $writer.WriteEndElement()
            }
            $writer.WriteEndElement()
        }

        if ($document['Status'] -eq 'AbortedByException') {
            $writer.WriteStartElement('system-err')
            $writer.WriteString((& $clean $document['ErrorMessage']))
            $writer.WriteEndElement()
        }

        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally { $writer.Dispose() }
}
finally { $stream.Dispose() }

return [pscustomobject]@{ Reporter = 'JUnit'; Path = $path }
