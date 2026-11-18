<#
.SYNOPSIS
Times the DscV3 engine against a real dsc, with full and with narrowed resource discovery.

.DESCRIPTION
Runs Actions/Engine/DscV3.ps1 - the real engine code, no mocks - the way the runner does: as a
script the module runs for each call. Each resource method is timed several times, first with
PIPELINERUNNER_DSC_FULL_DISCOVERY=1 (every call runs dsc's full resource discovery, including
the PowerShell discover extension), then with the narrowing on (the first call lists the
resource once; the rest are told where its manifest is). The timings are printed as a table
and, on GitHub Actions, written to the job summary.

It also checks what the narrowing must not change: the same InDesiredState from both, and a
CurrentState that carries the resource's state.

.PARAMETER ResourceType
The DSC v3 resource to time. Microsoft/OSInfo is the default: it ships with dsc on every
platform and only reads.

.PARAMETER Property
The desired state to test, as a hashtable.

.PARAMETER Repeat
How many calls to time in each mode.

.PARAMETER RepositoryRoot
Repository root. Defaults to the parent of this script's folder.

.PARAMETER MaximumNarrowedMilliseconds
When set, fail if the median narrowed call (after the first) takes longer than this. Off by
default: hosted agents vary too much for a hard limit to be fair to every pull request.
#>
[CmdletBinding()]
param(
    [string]$ResourceType = 'Microsoft/OSInfo',
    [hashtable]$Property = @{},
    [int]$Repeat = 5,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$MaximumNarrowedMilliseconds = 0
)

$ErrorActionPreference = 'Stop'

# The engine calls these as module functions; load them into one dynamic module so they behave
# as they do inside Dsc.PipelineRunner, and run the engine script from inside it.
$functionFiles = 'Invoke-DscExecutable', 'Resolve-DscV3ResourcePath', 'Protect-SensitiveValue', 'Unprotect-SecureString'
$code = foreach ($name in $functionFiles) {
    $file = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'source') -Recurse -Filter "$name.ps1" | Select-Object -First 1
    if ($file) { Get-Content -LiteralPath $file.FullName -Raw }
}
$enginePath = Join-Path $RepositoryRoot 'Actions/Engine/DscV3.ps1'
$moduleCode = ($code -join "`n") + @'

function Invoke-MeasuredEngine {
    param([string]$EnginePath, [hashtable]$Context)
    & $EnginePath -Context $Context
}
'@
$null = New-Module -Name Measure-DscV3Calls -ScriptBlock ([scriptblock]::Create($moduleCode))

$owner, $name = $ResourceType.Split('/', 2)
$median = {
    param([long[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

$rows = [System.Collections.Generic.List[object]]::new()
$verdicts = @{}
$saved = $env:PIPELINERUNNER_DSC_FULL_DISCOVERY
try {
    foreach ($mode in 'full', 'narrowed') {
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = if ($mode -eq 'full') { '1' } else { $null }
        Clear-DscV3ResourcePath
        foreach ($method in 'Test', 'Get') {
            $times = foreach ($i in 1..$Repeat) {
                $context = @{ Method = $method; ModuleName = $owner; Name = $name; Property = $Property }
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $result = Invoke-MeasuredEngine -EnginePath $enginePath -Context $context
                $watch.Stop()
                if ($method -eq 'Test') {
                    $verdicts[$mode] = $result.InDesiredState
                    if ($null -eq $result.CurrentState) {
                        throw "[Measure-DscV3Calls] The $mode test of $ResourceType returned no CurrentState."
                    }
                }
                $watch.ElapsedMilliseconds
            }
            $times = @($times)
            $rows.Add([pscustomobject]@{
                Discovery     = $mode
                Method        = $method
                FirstMs       = $times[0]
                MedianAfterMs = (& $median ($times | Select-Object -Skip 1))
                AllMs         = ($times -join ', ')
            })
        }
    }
}
finally {
    $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = $saved
    Clear-DscV3ResourcePath
}

$rows | Format-Table -AutoSize | Out-Host

if ($verdicts['full'] -ne $verdicts['narrowed']) {
    throw "[Measure-DscV3Calls] Full discovery said InDesiredState=$($verdicts['full']) and narrowed discovery said $($verdicts['narrowed'])."
}

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
        "### dsc calls for $ResourceType on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
        ''
        '| Discovery | Method | First call (ms) | Median of the rest (ms) | All (ms) |'
        '|---|---|---|---|---|'
    ) + ($rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.Discovery, $_.Method, $_.FirstMs, $_.MedianAfterMs, $_.AllMs })
    $lines -join "`n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}

if ($MaximumNarrowedMilliseconds -gt 0) {
    $narrowedTest = $rows | Where-Object { $_.Discovery -eq 'narrowed' -and $_.Method -eq 'Test' }
    if ($narrowedTest.MedianAfterMs -gt $MaximumNarrowedMilliseconds) {
        throw "[Measure-DscV3Calls] A narrowed test call took $($narrowedTest.MedianAfterMs) ms (median), over the $MaximumNarrowedMilliseconds ms limit."
    }
}
