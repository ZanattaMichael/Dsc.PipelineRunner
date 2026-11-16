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

## Captured state and reporters

Everything above is unchanged by this section: the CSV and `*.report.json` files keep their
shape. `PipelineRunnerSettings.Report` adds two opt-in things on top.

```yaml
PipelineRunnerSettings:
  Report:
    State: Drift            # None (default) | Drift | Full
    OnError: Warn           # Warn (default) | Fail - what a failing reporter does to the result
    Reporters: [ Webhook, JUnit, Summary ]  # extra destinations; the -ReportPath files need no entry
    Webhook:
      Uri: https://reports.example.com/dsc
      Credential:           # optional; resolved by a Credential action, its password is the token
        action: Environment
        UserNameVariable: REPORT_USER
        PasswordVariable: REPORT_TOKEN
```

### The report document

One document per compiled file, with `SchemaVersion` `1.0`. It is what a reporter receives, and
what `<node>.state.json` contains.

| Field | Meaning |
| --- | --- |
| `SchemaVersion` | `1.0`. A breaking change to this document changes the major number. |
| `NodeName`, `ConfigurationFile` | The compiled file. |
| `Mode`, `Engine` | `Test` or `Set`, and the engine that ran. |
| `Status`, `TotalResources`, `PassCount`, `FailCount`, `SkipCount`, `DurationSeconds`, `ErrorMessage` | As in `*.report.json`. |
| `StateCapture` | `None`, `Drift` or `Full`. |
| `Results` | One entry per resource: every field of the resource record above, plus the four below. |
| `Results[].Drifted` | Whether the resource's own `Test` found it out of the desired state. `null` if it never reached `Test`. |
| `Results[].SetInvoked` | Whether `Set` was called. |
| `Results[].ForcedByNotify` | Whether a `notify` from a changed resource forced the re-run. |
| `Results[].State` | `{ Desired, Actual }` when state was captured for this resource, otherwise `null`. |

### State capture

`State: Drift` captures state for resources that drifted; `Full` captures it for every resource
that was evaluated. `Desired` is the resource's properties after parameters and variables were
resolved; `Actual` is what the engine's `Get` returned. With `-ReportPath`, the document is also
written to `<node>.state.json`.

Captured state is redacted before it is stored, because `Get` output can hold secrets the
configuration never declared:

- a value under a sensitive key name (`password`, `secret`, `token`, `key`, `credential`,
  `connectionstring`, `passphrase`) becomes `[REDACTED]`, including a whole list or mapping
  under that key, at any depth;
- a `[PSCredential]` or `[SecureString]` becomes `[REDACTED]`;
- any secret the runner already knows for that resource is replaced wherever it appears inside
  another string;
- depth, list length and string length are bounded, and a resource whose captured state exceeds
  65,536 characters is reported as `{ Truncated: true }` instead.

Name matching is a heuristic. A secret stored under an innocuous name, that the runner was never
told about, is not recognised. Leave `State` at `None` (the default) where that matters, and
treat a state report with the same care as the system it describes.

A resource's `Get` output is held in memory only while its file is being evaluated (for
`reference()` and `using()`), and is released as soon as the file has been reported.

### Reporters

A reporter is an action under `Actions/Report/<Name>.ps1`, or an inline scriptblock passed as
`Invoke-DscRunner -ReportAction`. It receives a context with `Document` (above), its own
`Settings` block, `NodeName` and `ReportPath`, once per compiled file.

A reporter runs after the file's result has been decided. If it throws, the error is reported
and the report files and the other reporters are unaffected. What happens to the result is set
by `Report.OnError`:

| `OnError` | A reporter fails |
| --- | --- |
| `Warn` (default) | The error is reported; the result is unchanged. |
| `Fail` | A file that otherwise completed gets the status `ReportFailed`, which makes the run summary `Failed` (and, with `-FailOnError`, the exit code 1). Resource results are never altered, and an abort or early stop is not overwritten. Use it where an undelivered report must fail the pipeline, such as an audit trail. |

The built-in reporters:

| Reporter | Writes | Settings |
| --- | --- | --- |
| `Webhook` | The document as JSON, to an https endpoint. | `Uri`, `Credential`, `Header`, `Scheme`, `TimeoutSeconds`, `MaxAttempts` |
| `JUnit` | `<node>.junit.xml`: one test case per resource, for a CI system's "publish test results" step. | `Path` (defaults to `-ReportPath`) |
| `Summary` | A Markdown summary: appended to the GitHub Actions job summary when there is one, and written to `<node>.summary.md` when there is a directory. | `ListAll` (default: only `FAIL` and `SKIP`), `Path` |

`JUnit` and `Summary` treat resource names and messages as untrusted text: a name cannot add
XML elements, table columns, HTML, links or images, and neither file can be written outside the
report directory. The summary table is capped at 200 rows.

On Azure Pipelines, show the summary with
`##vso[task.uploadsummary]<path to node.summary.md>` from a later step.

**`Webhook`** posts the document as JSON:

- `https` only; a URL with `user:password@` is refused;
- the token comes from a `Credential` action and is sent in a header (`Authorization: Bearer`
  by default; `Header` and `Scheme` change that), never in the URL;
- redirects are not followed, so neither the token nor the report reaches another host;
- a failed attempt is retried (`MaxAttempts`, default 3; `TimeoutSeconds`, default 30);
- an error names the host and the HTTP status only: not the token, the URL's path or query, or
  the response body.

## Dry runs and the resultant configuration (RSOP)

`Invoke-DscRunner -Mode DryRun` validates a configuration and works out what a real run would
do, without doing any of it. It is meant for a pipeline stage that runs before the real one,
for example on a pull request, and it needs no credentials.

```powershell
$dry = Invoke-DscRunner -ConfigurationSourcePath ./config -Mode DryRun -ReportPath ./reports -FailOnError
```

### What a dry run does and does not do

| Step | Dry run |
| --- | --- |
| Resolve the source, compile Datum, expand composites | Yes, exactly as a real run. |
| `Connect` action | Skipped. |
| Order resources (`dependsOn`, `notify`), Pre-Parse and Format rules | Yes. |
| `preCondition` | Validated. Evaluated, unless it reads run-time state. |
| Properties: `<params=...>` and `$(...)` | Parameters resolved; expressions validated and evaluated, unless one reads run-time state. |
| `postCondition` | Validated only (it reads the resource's result). |
| `target`, `resourceCredential` | Shape checked, and the named action must exist. No connection is made and no secret is fetched. |
| `preExecutionScript` / `postExecutionScript` | Parsed for syntax errors. Never run. |
| Engine `Test`, `Set`, `Get` | Never called. |

An expression that calls `reference()`, `using()`, `result()` or `stopProcessing()` depends on
state that only exists once resources have run. A dry run checks it against the same allow-list
as a real run and lists it under `Deferred`; it is neither evaluated nor counted as a failure.

Because the compile step still runs, the configuration repository is still executed as code
(see the trust model). A dry run removes the engine, the targets and the credentials from the
picture; it does not sandbox the Datum merge.

### Results

Each resource gets the usual status: `OK` (valid, would be evaluated), `SKIP` (its
`preCondition` is false) or `FAIL` (something is wrong, with every problem listed). The run
summary, `-FailOnError`, the CSV and `*.report.json` all work as they do for a real run, so a
dry-run stage fails the pipeline the same way.

### The RSOP document

The resultant configuration of each node, after the Datum merge, composite expansion, ordering
and expression evaluation. It is returned as the `Rsop` property of each configuration's
result, written to `<node>.rsop.json` with `-ReportPath`, and included in the report document
reporters receive (`Document.Rsop`, with `Mode` `DryRun`).

| Field | Meaning |
| --- | --- |
| `SchemaVersion` | `1.0`. |
| `NodeName`, `ConfigurationFile`, `Engine`, `DefaultTarget` | The file and the engine and target it would use. |
| `Settings` | The `PipelineRunnerSettings` in effect. |
| `Parameters`, `Variables` | Their resolved values. |
| `Resources` | One entry per resource, in the order they would run. |
| `Resources[].Type`, `Name`, `Order` | Identity and position. |
| `Resources[].Status`, `WouldRun`, `Problems` | The verdict and every problem found. |
| `Resources[].PreCondition` | `True`, `False`, `Deferred`, or `null` when there is none. |
| `Resources[].Deferred` | Which of `preCondition`, `properties`, `postCondition` could not be evaluated yet. |
| `Resources[].Properties` | The resolved properties (unexpanded where deferred). |
| `Resources[].Target`, `ComputerName`, `CredentialActions` | Where it would run and which credential actions it would call. |
| `Resources[].DependsOn`, `Notify`, `HasExecutionScripts` | Its declared relationships and whether it carries scripts. |

Secrets are redacted the same way as captured state: by sensitive key name at any depth, for
`[PSCredential]` and `[SecureString]` values, and for any known secret echoed inside another
string. The same limit applies: a secret stored under an innocuous name is not recognised.

