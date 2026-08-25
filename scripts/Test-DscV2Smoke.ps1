<#
.SYNOPSIS
Smoke-test the DSC v2 engine path end-to-end against a real Invoke-DscResource.

.DESCRIPTION
Proves that, on this host, the runner's DscV2 engine can actually drive Invoke-DscResource
and return a contract-valid result. It exercises the *real* module code -- no mocks -- the
same way Invoke-EngineAction does: it runs Actions/Engine/DscV2.ps1 against a live,
dependency-free class-based resource (the PipelineRunnerFile test fixture) and asserts the
normalized engine-contract fields.

Invoke-DscResource (DSC v2) is the Windows / PowerShell-DSC path, so this is intended to run
on the self-hosted Windows + PowerShell 7 runner. It throws on any failure so a CI step
fails loudly, mirroring scripts/Test-DscV3Smoke.ps1.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.OUTPUTS
None. Throws on any failure.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# 1. The DSC v2 engine must be usable on this host.
if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
    Import-Module -Name PSDesiredStateConfiguration -ErrorAction Stop
}
if (-not (Get-Command -Name Invoke-DscResource -ErrorAction SilentlyContinue)) {
    throw "[Test-DscV2Smoke] Invoke-DscResource is not available on this host. DSC v2 requires PowerShell DSC (PSDesiredStateConfiguration)."
}
Write-Host "[Test-DscV2Smoke] PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())"

# 2. Make the dependency-free test resource discoverable by putting its parent directory on
#    PSModulePath, then confirm DSC can actually see it.
$fixtureRoot = Join-Path $RepositoryRoot 'Tests/Fixtures/DscV2'
if (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'PipelineRunnerTestResource'))) {
    throw "[Test-DscV2Smoke] Test fixture module not found under: $fixtureRoot"
}
if (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $fixtureRoot) {
    $env:PSModulePath = $fixtureRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
}

$discovered = Get-DscResource -Name 'PipelineRunnerFile' -Module 'PipelineRunnerTestResource' -ErrorAction SilentlyContinue
if (-not $discovered) {
    throw "[Test-DscV2Smoke] DSC could not discover the PipelineRunnerFile resource. PSModulePath: $env:PSModulePath"
}
Write-Host "[Test-DscV2Smoke] Discovered resource: $($discovered.ResourceType) (module $($discovered.ModuleName) $($discovered.Version))."

# 3. Load the DSC v2 engine action exactly as Invoke-Action would run it (& the file with a
#    -Context hashtable). Nothing about Invoke-DscResource is faked.
$engineActionPath = Join-Path $RepositoryRoot 'Actions/Engine/DscV2.ps1'
if (-not (Test-Path -LiteralPath $engineActionPath)) {
    throw "[Test-DscV2Smoke] DSC v2 engine action not found at: $engineActionPath"
}

$stateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dscv2smoke_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

try {
    $baseProperty = @{ Name = 'smoke'; Path = $stateDir }

    # 3a. Test with Ensure = Absent over an empty directory: the marker does not exist, so the
    #     resource is already in its desired (absent) state.
    $testContext = @{ Method = 'Test'; ModuleName = 'PipelineRunnerTestResource'; Name = 'PipelineRunnerFile'; Property = ($baseProperty + @{ Ensure = 'Absent' }) }
    $testResult = & $engineActionPath -Context $testContext
    if ($null -eq $testResult -or $null -eq $testResult.PSObject.Properties['InDesiredState']) {
        throw "[Test-DscV2Smoke] The engine result is missing the 'InDesiredState' contract field. Got: $($testResult | ConvertTo-Json -Depth 8)"
    }
    if (-not $testResult.InDesiredState) {
        throw "[Test-DscV2Smoke] Expected InDesiredState = true for an Absent resource over an empty directory."
    }

    # 3b. Set with Ensure = Present: the engine must actually create the marker on disk.
    $setContext = @{ Method = 'Set'; ModuleName = 'PipelineRunnerTestResource'; Name = 'PipelineRunnerFile'; Property = ($baseProperty + @{ Ensure = 'Present' }) }
    $null = & $engineActionPath -Context $setContext
    if (-not (Test-Path -LiteralPath (Join-Path $stateDir 'smoke.marker'))) {
        throw "[Test-DscV2Smoke] Set(Present) did not create the marker file -- Invoke-DscResource did not run the resource's Set()."
    }

    # 3c. Test again with Ensure = Present: now the marker exists, so it is in desired state.
    $testContext2 = @{ Method = 'Test'; ModuleName = 'PipelineRunnerTestResource'; Name = 'PipelineRunnerFile'; Property = ($baseProperty + @{ Ensure = 'Present' }) }
    $testResult2 = & $engineActionPath -Context $testContext2
    if (-not $testResult2.InDesiredState) {
        throw "[Test-DscV2Smoke] Expected InDesiredState = true after creating the marker with Set(Present)."
    }

    Write-Host "[Test-DscV2Smoke] PASS - the DscV2 engine drove Invoke-DscResource through a real Test/Set/Test cycle and returned contract-valid results."
}
finally {
    Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
}
