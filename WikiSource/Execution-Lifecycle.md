# Execution Lifecycle

This page is the order of operations: what happens to a run, to a file, and to a single
resource — and where each key on a resource takes effect.

## The run

```
Invoke-DscRunner
 ├─ 1. Source action      → a local configuration directory (Local / Git / custom)
 ├─ 2. Read settings      → PipelineRunnerSettings from the source Datum.yml
 ├─ 3. Engine selection   → EngineAction > -Engine > settings.Engine > DSCResourceVersion > DscV2
 ├─ 4. Connect action     → auth / session (None / AzureDevOps / custom)
 ├─ 5. Cache directory    → -CacheDirectory > PIPELINERUNNER_CACHE_DIRECTORY > a temp directory
 ├─ 6. Build-DatumConfiguration → one compiled *.yml per node
 ├─ 7. For each compiled file:  Start-DscRunner
 ├─ 8. Merge-DscRunnerResult    → one summary object, optional report.json, optional exit code
 └─ 9. finally: delete directories the runner itself created
```

Step 9 never touches a directory you supplied. `-KeepTemporaryDirectory` leaves the runner's
own temporary directories in place for inspection.

## One file

`Start-DscRunner` is called once per compiled `*.yml`, and each call is independent:

```
 ├─ Reset per-file state: StopTaskProcessing, notifyDeclarations, resourceOutputs,
 │                        pendingNotifyRefresh, currentResourceKey
 ├─ Resolve the reboot policy and the default target action from the settings
 ├─ Parse the file (.yaml / .yml / .json — anything else throws)
 ├─ Expand-NotifyDependsOn   → fold notify into implicit dependsOn; build the declaration map
 ├─ Sort-DependsOn           → topological sort; cycles and unresolvable targets fail here
 ├─ Invoke-PreParseRules     → Test-CircularReferences, Test-ExecutionScriptsAllowed,
 │                             Test-ResourcesForIncorrectProperties
 ├─ For each resource, in sorted order:  (see below)
 └─ finally: close cached sessions, write the report, print the summary
```

The `finally` matters: a report is produced even when the run was stopped early or aborted by
an exception.

The reset at the top is what makes the compiled file the unit of scope. `notify`, `using()`,
`dependsOn` and `Stop-TaskProcessing` all operate within one file and never reach the next.

## One resource

Every step below is skipped or short-circuited under the conditions noted. Where a step
records `FAIL` and continues, the run moves to the next resource — it does not abort.

```
 1. Stop flag?            → if set, record SKIP and continue
 2. preCondition          → validate, evaluate; $false ⇒ SKIP; throws ⇒ FAIL
 3. Expand properties     → parameters, then ExpandString ($( ), the function language)
 4. resourceCredential    → resolve via the Credential hook, inject into properties
 5. Resolve target        → per-resource target block, else the file default; session cached
 6. preExecutionScript    → arbitrary PowerShell (gated by AllowExecutionScripts)
 7. Test()                → via the selected engine
 8. Set()                 → Set mode only, when Test reported drift OR a notify refresh is pending
 9. Reboot check          → local: policy decides; remote: restart and wait
10. Propagate notify      → only when this resource genuinely changed AND status is OK
11. postCondition         → result() / stopProcessing() available; $false ⇒ FAIL
12. postExecutionScript   → arbitrary PowerShell (gated by AllowExecutionScripts)
13. Get()                 → recorded for reference() and using(); a failure records $null
14. Record the outcome    → OK / FAIL / SKIP, duration, error message
```

### 1. The stop flag

`Stop-TaskProcessing` or `stopProcessing()` sets a flag checked before each resource. Once set,
every remaining resource in the file is recorded:

```
Resource skipped due to 'Stop-TaskProcessing' cmdlet.
```

and the file's run status becomes `StoppedByRequest`.

### 2. `preCondition`

`preCondition` is used when present; the older `condition` key is the fallback. The expression
is validated by `Assert-SafeConditionExpression` **before** it runs, so a rejected expression
never executes. A `$false` result records:

```
Resource skipped due to preCondition {<the expression>}.
```

### 3. Property expansion

Parameter substitution runs first, then `ExpandString` over the whole (possibly nested)
property map. This is where `variables()`, `parameters()`, `reference()` and `using()` resolve.
`$script:currentResourceKey` is set just before this step, which is how `using()` knows who is
calling it.

An exception here — an undefined `parameters()` name, an ungated `using()`, a syntax error —
records `FAIL` and moves on.

### 4. `resourceCredential`

Declarative, so it is not gated by `AllowExecutionScripts`. The block's `action` (default
`Environment`) selects a file under `Actions/Credential/`, the whole block is passed to it as
context, and the result is written into the property named by `propertyName` (default
`Credential`).

### 5. Target resolution

`Local` — the default — never invokes the Target hook, so a local-only configuration takes
exactly the path it always did. Otherwise a session is opened and cached on
`(action, computerName, configurationName, credential)`, so several resources aimed at one host share one
connection. Every cached session is closed in the file's `finally`.

A failure to establish the target records `FAIL` and moves on.

### 6 and 12. Execution scripts

`preExecutionScript` runs after the target is resolved and before Test/Set;
`postExecutionScript` runs after `postCondition`. Both are `[scriptblock]::Create` plus `&` —
invoked, not dot-sourced, so they cannot rewrite the runner's locals or its report. Neither is
parsed through `ExpandString` or the condition allow-list, so both read script-scope variables
directly.

Both require `PipelineRunnerSettings.AllowExecutionScripts: true`, enforced at step 3 of the
file (`Test-ExecutionScriptsAllowed`) rather than here — so a configuration carrying a script
under a false setting fails before any resource is evaluated.

### 7 and 8. Test and Set

`Test()` always runs. In `Test` mode that is the whole evaluation: a resource already in the
desired state is `OK`, and **drift is recorded as `FAIL`** with the engine's message. A `Test`
run over a configuration that has never been applied therefore reports failures — that is the
drift report, not an error in the runner.

In `Set` mode, `Set()` runs when either:

- the resource's own `Test()` reported it is not in the desired state, or
- a resource that notifies it genuinely changed earlier in this file — the forced refresh.

A `Set()` that throws records `FAIL`, and evaluation continues to `postCondition` rather than
skipping ahead — a failed `Set` can still be caught and described by a `postCondition`.

### 9. Reboot

When a local `Set()` reports `RebootRequired`:

- `Reboot: Fail` (the default) records `FAIL` with a message naming both escape hatches, **and
  sets the stop flag** — so the rest of the file is skipped. The runner cannot safely restart
  the host it is running on and resume mid-file.
- `Reboot: Ignore` logs and continues without restarting.

A resource on a **remote** target restarts the target and waits, regardless of the policy — the
runner itself is not what needs to come back up.

### 10. Notify propagation

A forced refresh is queued for this resource's `notify` targets only when **both** hold: this
resource's own `Test()` reported drift (so it genuinely changed), and its status is still `OK`.

Two consequences worth stating plainly:

- A resource that was forced to `Set()` and found nothing to change does **not** cascade the
  refresh onward.
- A resource whose `Set()` **failed** does not propagate a refresh, because the status is no
  longer `OK`.

### 11. `postCondition`

Evaluated after Test/Set, with `result()` and `stopProcessing()` allow-listed.
`$script:currentResourceResult` is set immediately beforehand, which is what `result()` reads.
A `$false` result records:

```
Resource failed postCondition {<the expression>}.
```

and marks the resource `FAIL` regardless of what the engine reported.

### 13. `Get`

Always attempted. The raw output is stored twice: under the bare instance name for
`reference()`, and under the full `Type/Name` identity for `using()`. A `Get()` that throws is
recorded as `$null` and does not fail the resource — but a later `using()` on it will throw
its "has not produced Get() output yet" error.

## Status, and how it aggregates

Each resource ends as exactly one of:

| Status | Meaning |
| --- | --- |
| `OK` | Evaluated with no failure. |
| `FAIL` | An error, a failed `Set`, a rejected or `$false` condition, or a blocked reboot. |
| `SKIP` | A `$false` `preCondition`, or the stop flag was already set. |

Each file ends as one of `Completed`, `StoppedByRequest`, or `AbortedByException`, and those
fold into a run status — `Completed`, `PartialSuccess`, `Failed`, `Aborted`. See
[Reporting and Exit Codes](Reporting-and-Exit-Codes).

## Output streams

Everything human-readable goes to the **information** stream tagged `Dsc.PipelineRunner`, not
`Write-Host`, so a caller can capture or redirect it:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -InformationVariable log
$log | Where-Object { $_.Tags -contains 'Dsc.PipelineRunner' }
```

`$InformationPreference` is set to `Continue` for the duration of a file so the log is visible
by default, and DSC's own progress UI is suppressed so it does not flood a pipeline log. Both
are restored on return.

Per-resource diagnostics go to the verbose stream; add `-Verbose` when you need them.
