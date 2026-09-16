# Reporting and Exit Codes

Every run produces a structured object. With `-ReportPath` it also produces files. With
`-FailOnError` it also sets a process exit code. This page documents all three.

## The three levels

```
Run summary            ← Merge-DscRunnerResult, returned by Invoke-DscRunner
 └─ Configuration      ← one per compiled *.yml, returned by Start-DscRunner
     └─ Resource       ← one per resource, deduplicated
```

## The resource record

One record per resource, keyed on `(ConfigurationFile, ResourceType, InstanceName)` — so a
resource is never double-counted, however many times it is recorded during evaluation.

| Field | Meaning |
| --- | --- |
| `NodeName` | The compiled file's name without its extension. |
| `ResourceType` | The resource's `type`, e.g. `PSDscResources/File`. |
| `InstanceName` | The resource's `name`. |
| `ConfigurationFile` | Full path to the compiled file. |
| `Status` | `OK`, `FAIL` or `SKIP`. |
| `DurationMs` | Milliseconds spent on this resource. |
| `ErrorMessage` | The failure or skip reason. `$null` on success. |
| `Target` | The resolved target action, e.g. `Local` or `WinRM`. |
| `ComputerName` | The remote host, or `$null` for a local target. |
| `RebootRequired` | Whether the engine reported a pending reboot. |

### What each status means

| Status | Cause |
| --- | --- |
| `OK` | Evaluated with no failure. |
| `FAIL` | Drift in `Test` mode; a failed `Set`; a rejected or throwing condition; a `$false` `postCondition`; a failed property expansion or credential resolution; an unreachable target; a blocked reboot. |
| `SKIP` | A `$false` `preCondition`, or the stop flag was already set. |

**`Test` mode drift is `FAIL`.** A `Test` run over a configuration that has never been applied
reports failures, and that is the drift report — not a runner error. This is what makes a
`Test` run usable as a compliance gate: `-FailOnError` turns drift into a red build.

### Common `ErrorMessage` values

```
Resource skipped due to 'Stop-TaskProcessing' cmdlet.
Resource skipped due to preCondition {equals (variables 'Role') 'Web'}.
Resource failed postCondition {result().InDesiredState}.
Resource [M/R/N] requires a reboot to complete, and the local host cannot safely restart itself mid-run. ...
```

Anything else is an exception message passed through verbatim.

## The configuration result

Returned by `Start-DscRunner`, one per compiled file:

| Field | Meaning |
| --- | --- |
| `ConfigurationFile` | Full path. |
| `NodeName` | The file's name without its extension. |
| `Status` | `Completed`, `StoppedByRequest` or `AbortedByException`. |
| `TotalResources` | Count of records. |
| `PassCount` / `FailCount` / `SkipCount` | Per-status counts. |
| `DurationSeconds` | Wall clock for this file, to three decimals. |
| `ErrorMessage` | The aborting exception, when there was one. |
| `FailedResources` | Just the `FAIL` records. |
| `Results` | Every record. |

| File status | Cause |
| --- | --- |
| `Completed` | The loop ran to the end. |
| `StoppedByRequest` | `Stop-TaskProcessing` or `stopProcessing()` — including the local reboot-policy stop. |
| `AbortedByException` | An unexpected exception escaped the loop. |

Note that `Completed` says nothing about failures: a file where every resource failed still
completed. Read `FailCount`.

## The run summary

Returned by `Invoke-DscRunner` and `Invoke-DscPipelineRunner`:

| Field | Meaning |
| --- | --- |
| `Status` | `Completed`, `PartialSuccess`, `Failed` or `Aborted`. |
| `TotalConfigurations` | How many compiled files ran. |
| `TotalResources` | Across every file. |
| `PassCount` / `FailCount` / `SkipCount` | Summed. |
| `DurationSeconds` | Summed, to three decimals. |
| `FailedResources` | Every `FAIL` record from every file, flattened. |
| `Configurations` | The per-file results. |

Status is decided most-severe first:

| Status | Condition |
| --- | --- |
| `Aborted` | Any file was `AbortedByException`. |
| `Failed` | Any resource failed. |
| `PartialSuccess` | Nothing failed, but something was stopped early or skipped. |
| `Completed` | Every file finished and nothing failed or skipped. |

An **empty** run — no compiled files at all — yields a well-formed `Completed` summary with
zero counts. Check `TotalConfigurations` if "nothing to do" and "nothing found" need to be
distinguished:

```powershell
$result = Invoke-DscRunner -ConfigurationSourcePath 'C:\config'
if ($result.TotalConfigurations -eq 0) {
    throw 'The configuration compiled to no node files — check ResolutionPrecedence.'
}
```

## Report files

`-ReportPath` must be an existing directory.

```powershell
New-Item -ItemType Directory -Path .\reports -Force | Out-Null
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Set -ReportPath .\reports
```

```
reports/
├── web01.csv            # every resource record for web01.yml, flat
├── web01.report.json    # the configuration result for web01.yml
├── sql01.csv
├── sql01.report.json
└── report.json          # the run summary
```

Per-file names come from the compiled file's own name, so a Datum repository that compiles one
file per node gives one report per node.

The per-file reports are written from a `finally` block, so they exist even when the file was
stopped early or aborted by an exception. The aggregate `report.json` is written by
`Merge-DscRunnerResult` after every file has run.

Both JSON documents serialize to a depth of 6. A deeply nested `Raw` engine result may be
truncated there; the console log and the returned object are not.

A Windows-style `ReportPath` such as `C:\Reports` is composed without resolving a drive
qualifier, so it does not throw on a Linux runner — though the directory still has to exist.

### Reading a report

```powershell
$summary = Get-Content .\reports\report.json -Raw | ConvertFrom-Json

$summary.Status
$summary.FailedResources |
    Select-Object NodeName, ResourceType, InstanceName, ErrorMessage |
    Format-Table -AutoSize
```

```powershell
Import-Csv .\reports\web01.csv |
    Where-Object Status -ne 'OK' |
    Select-Object ResourceType, InstanceName, Status, DurationMs, ErrorMessage
```

The slowest resources across a run:

```powershell
$summary.Configurations.Results |
    Sort-Object DurationMs -Descending |
    Select-Object -First 10 NodeName, InstanceName, DurationMs
```

## Exit codes

`-FailOnError` sets `[System.Environment]::ExitCode = 1` when the run status is `Failed` or
`Aborted`. It is opt-in, so the default behaviour is unchanged for callers that do not want a
runner failure to fail their step.

| Run status | Exit code with `-FailOnError` |
| --- | --- |
| `Completed` | 0 |
| `PartialSuccess` | 0 |
| `Failed` | 1 |
| `Aborted` | 1 |

`PartialSuccess` deliberately does **not** fail the step: a file that stopped early via
`Stop-TaskProcessing` did so because the configuration asked it to — an `Absent` teardown, for
instance — and that is a successful outcome, not an error.

If you want a stricter gate, decide it yourself from the summary:

```powershell
$result = Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Set -ReportPath .\reports

if ($result.Status -ne 'Completed') {
    Write-Host "##vso[task.logissue type=error]Run status: $($result.Status)"
    exit 1
}
```

> `[System.Environment]::ExitCode` is the *process* exit code, applied when PowerShell exits.
> A run inside a longer-lived host — an interactive session, or a script that keeps going —
> sets the value without terminating anything. In CI, where the script is the process, it
> behaves as expected.

## Console output

Everything human-readable goes to the information stream tagged `Dsc.PipelineRunner`, never
`Write-Host`, so it can be captured or redirected:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -InformationVariable log
$log | Where-Object { $_.Tags -contains 'Dsc.PipelineRunner' } | ForEach-Object { $_.MessageData }
```

Per resource, one line:

```
[3/12] OK PSDscResources/File/Log Directory (84ms)
[4/12] FAIL PSDscResources/Service/AppService (1203ms) - Cannot find service 'AppService'.
[5/12] SKIP AzureDevOpsDscNative/AzDoProject/Project (preCondition)
```

Then a summary block per file, ending with a deduplicated failure list:

```
DSC Configuration Report: /tmp/cache/web01.yml
Run Status: Completed
Results Summary:
[web01] PSDscResources/File/Log Directory - Result: [OK]
[web01] PSDscResources/Service/AppService - Result: [FAIL]
Total Tasks Executed: 12
Tasks Passed:  10
Tasks Failed:  1
Tasks Skipped: 1
Total Tasks: 12
Failed Resources:
  PSDscResources/Service/AppService [/tmp/cache/web01.yml] - Cannot find service 'AppService'.
```

And one line for the whole run:

```
Run summary: Failed — 2 configuration(s), 20 passed, 1 failed, 1 skipped.
```

The pre-parse rules are the exception: `Test-ResourcesForIncorrectProperties` uses `Write-Host`
deliberately, for a coloured operator-facing pass/fail banner on the host running the check.

## A CI pattern

```powershell
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY/reports -Force | Out-Null

$result = Invoke-DscRunner -Source Git `
                           -SourceContext @{ Url = $env:CONFIG_REPO; Token = $env:CONFIG_PAT } `
                           -ConfigurationRevision $env:CONFIG_SHA `
                           -Mode Test `
                           -ReportPath $env:BUILD_ARTIFACTSTAGINGDIRECTORY/reports `
                           -FailOnError

foreach ($failure in $result.FailedResources) {
    Write-Host "##vso[task.logissue type=error]$($failure.NodeName): $($failure.ResourceType)/$($failure.InstanceName) — $($failure.ErrorMessage)"
}
```

`Test` mode plus `-FailOnError` is a drift gate: the build goes red when the estate no longer
matches the configuration, and the published reports say exactly which resources moved.
