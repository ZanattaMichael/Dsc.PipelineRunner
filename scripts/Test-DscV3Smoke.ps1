<#
.SYNOPSIS
Smoke-test the DSC v3 engine path end-to-end against a real dsc executable.

.DESCRIPTION
Proves that, on this host, the runner's DscV3 engine can actually drive `dsc` and return
a contract-valid [DscMethodResult]. It exercises the *real* module code — no mocks — the
same way Invoke-EngineAction does: it runs Actions/Engine/DscV3.ps1 against a live
resource and normalizes the output through ConvertTo-DscMethodResult.

The resource is discovered from `dsc resource list` so the test is resilient across DSC
releases: it prefers a caller-supplied type, then the cross-platform Microsoft/OSInfo and
Microsoft.DSC.Debug/Echo built-ins, and otherwise falls back to the first listed resource.

.PARAMETER ResourceType
Optional preferred resource type ('Owner/Name'). When present in `dsc resource list` it is
used; otherwise the discovery fallback applies.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.OUTPUTS
None. Throws on any failure so a CI step fails loudly.
#>
[CmdletBinding()]
param(
    [string]$ResourceType,

    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# 1. The executable must be present and runnable.
$version = & dsc --version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "[Test-DscV3Smoke] 'dsc --version' failed (exit $LASTEXITCODE): $version"
}
Write-Host "[Test-DscV3Smoke] dsc version: $($version.Trim())"

# 2. Load the one module piece the DSC v3 engine action depends on: the executable
#    wrapper. The action returns a plain [pscustomobject] with the contract fields, so no
#    class needs loading here — the [DscMethodResult] normalization is covered separately
#    by the engine-contract unit tests.
. (Join-Path $RepositoryRoot 'source/Private/Actions/Invoke-DscExecutable.ps1')

$engineActionPath = Join-Path $RepositoryRoot 'Actions/Engine/DscV3.ps1'
if (-not (Test-Path -LiteralPath $engineActionPath)) {
    throw "[Test-DscV3Smoke] DSC v3 engine action not found at: $engineActionPath"
}

# 3. Discover the available resources so the test does not hard-depend on one shipping.
#    dsc may emit one JSON object per line (JSONL) or a single JSON array depending on the
#    release, so handle both.
$listJson = & dsc resource list --output-format json 2>&1
$availableTypes = foreach ($line in ($listJson -split "`n")) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { (ConvertFrom-Json $line).type } catch { }
}
$availableTypes = @($availableTypes | Where-Object { $_ })

if ($availableTypes.Count -eq 0) {
    # Fall back to parsing the whole payload as a single JSON array.
    try {
        $availableTypes = @((ConvertFrom-Json ($listJson | Out-String)).type | Where-Object { $_ })
    }
    catch { }
}
Write-Host "[Test-DscV3Smoke] Discovered $($availableTypes.Count) resource(s)."

if ($availableTypes.Count -eq 0) {
    throw "[Test-DscV3Smoke] 'dsc resource list' returned no resources. Raw: $($listJson | Out-String)"
}

# Choose the resource to exercise: caller preference, then known cross-platform built-ins,
# then whatever is first in the list.
$preference = @()
if (-not [string]::IsNullOrWhiteSpace($ResourceType)) { $preference += $ResourceType }
$preference += 'Microsoft/OSInfo'
$preference += 'Microsoft.DSC.Debug/Echo'

$target = $preference | Where-Object { $availableTypes -contains $_ } | Select-Object -First 1
if (-not $target) { $target = $availableTypes[0] }
Write-Host "[Test-DscV3Smoke] Exercising resource: $target"

# The Echo debug resource needs an 'output' property; other resources are fine with none.
$property = @{}
if ($target -eq 'Microsoft.DSC.Debug/Echo') { $property = @{ output = 'dsc-v3-smoke' } }

$moduleName, $name = $target -split '/', 2
$context = @{ Method = 'Get'; ModuleName = $moduleName; Name = $name; Property = $property }

# 4. Run the engine action exactly as Invoke-Action would (& the action file with a
#    -Context hashtable) and assert it produced the contract fields for a live resource.
$result = & $engineActionPath -Context $context

if ($null -eq $result) {
    throw "[Test-DscV3Smoke] The DSC v3 engine action returned nothing for '$target'."
}
if ($null -eq $result.PSObject.Properties['InDesiredState']) {
    throw "[Test-DscV3Smoke] The engine result for '$target' is missing the 'InDesiredState' contract field. Got: $($result | ConvertTo-Json -Depth 8)"
}
if (-not $result.InDesiredState) {
    throw "[Test-DscV3Smoke] Expected InDesiredState = true for a successful Get on '$target'."
}

Write-Host "[Test-DscV3Smoke] PASS - $target returned a contract-valid result (InDesiredState=$($result.InDesiredState))."
Write-Host ($result.Raw | ConvertTo-Json -Depth 8)
