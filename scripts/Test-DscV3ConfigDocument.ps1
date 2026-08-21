<#
.SYNOPSIS
Prove that a document produced by ConvertTo-DscV3ConfigurationDocument is accepted by a real dsc.exe.

.DESCRIPTION
The runner's compiled configuration is a pipeline-specific shape, not a DSC v3 configuration
document. ConvertTo-DscV3ConfigurationDocument bridges that gap. This script closes the loop
against the actual engine: it builds a document from a compiled-style resource list (complete
with pipeline-only keys, to prove they are stripped) and feeds it to `dsc config get`. A
non-zero exit or unparseable result fails the step — so "the compiled configuration is
DSC v3-compliant and usable by dsc.exe" is verified end-to-end, not merely asserted in unit tests.

The resource is discovered from `dsc resource list` so the proof is resilient across DSC
releases: it prefers the cross-platform Microsoft/OSInfo, then Microsoft.DSC.Debug/Echo, and
otherwise the first listed resource.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.OUTPUTS
None. Throws on any failure so a CI step fails loudly.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# 1. The executable must be present.
$version = & dsc --version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "[Test-DscV3ConfigDocument] 'dsc --version' failed (exit $LASTEXITCODE): $version"
}
Write-Host "[Test-DscV3ConfigDocument] dsc version: $($version.Trim())"

# 2. Load the two module functions under test (no module import / YAML dependency needed).
. (Join-Path $RepositoryRoot 'source/Private/Actions/Test-DscV3ResourceType.ps1')
. (Join-Path $RepositoryRoot 'source/Public/ConvertTo-DscV3ConfigurationDocument.ps1')

# 3. Discover the resources dsc.exe actually offers (JSONL or a single JSON array).
$listJson = & dsc resource list --output-format json 2>&1
$availableTypes = foreach ($line in ($listJson -split "`n")) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { (ConvertFrom-Json $line).type } catch { }
}
$availableTypes = @($availableTypes | Where-Object { $_ })
if ($availableTypes.Count -eq 0) {
    try { $availableTypes = @((ConvertFrom-Json ($listJson | Out-String)).type | Where-Object { $_ }) } catch { }
}
if ($availableTypes.Count -eq 0) {
    throw "[Test-DscV3ConfigDocument] 'dsc resource list' returned no resources. Raw: $($listJson | Out-String)"
}
Write-Host "[Test-DscV3ConfigDocument] Discovered $($availableTypes.Count) resource(s)."

$preference = @('Microsoft/OSInfo', 'Microsoft.DSC.Debug/Echo')
$target = $preference | Where-Object { $availableTypes -contains $_ } | Select-Object -First 1
if (-not $target) { $target = $availableTypes[0] }
Write-Host "[Test-DscV3ConfigDocument] Building a document around: $target"

# The Echo debug resource needs an 'output' property; others are fine with none.
$properties = @{}
if ($target -eq 'Microsoft.DSC.Debug/Echo') { $properties = @{ output = 'dsc-v3-config-doc' } }

# 4. A compiled-style resource list, deliberately carrying pipeline-only keys that must not
#    leak into the DSC v3 document.
$compiledResources = @(
    [ordered]@{
        type                = $target
        name                = 'compliance-probe'
        properties          = $properties
        condition           = '1 -eq 1'
        postExecutionScript = 'Write-Verbose "noop"'
        dependsOn           = @()
    }
)

$document = ConvertTo-DscV3ConfigurationDocument -Resource $compiledResources -AvailableResourceType $availableTypes

# Belt-and-braces: the emitted resource must expose only the DSC v3 keys.
$emittedKeys = @($document.resources[0].Keys)
foreach ($forbidden in 'condition', 'postExecutionScript', 'dependsOn') {
    if ($emittedKeys -contains $forbidden) {
        throw "[Test-DscV3ConfigDocument] Pipeline-only key '$forbidden' leaked into the DSC v3 document."
    }
}

$json = $document | ConvertTo-Json -Depth 32
Write-Host "[Test-DscV3ConfigDocument] Document:"
Write-Host $json

# 5. The real proof: dsc.exe must accept and evaluate the document. Write it to a temp file and
#    pass it with --file, which every DSC v3 release accepts for `dsc config` subcommands and
#    avoids stdin-delivery quirks under pwsh.
$configPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dsc-v3-config-{0}.json" -f ([guid]::NewGuid()))
Set-Content -LiteralPath $configPath -Value $json -Encoding utf8
try {
    $configOutput = & dsc config get --file $configPath 2>&1 | Out-String
    $configExit = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $configPath -ErrorAction SilentlyContinue
}
if ($configExit -ne 0) {
    throw "[Test-DscV3ConfigDocument] 'dsc config get' rejected the generated document (exit $configExit): $configOutput"
}
if ([string]::IsNullOrWhiteSpace($configOutput)) {
    throw "[Test-DscV3ConfigDocument] 'dsc config get' returned no output for the generated document."
}

Write-Host "[Test-DscV3ConfigDocument] PASS - dsc.exe accepted and evaluated the generated configuration document."
Write-Host $configOutput
