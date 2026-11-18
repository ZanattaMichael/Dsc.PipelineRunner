# DSC v3 performance

A DSC v3 run spends its time in two places: the resources themselves, and everything `dsc` does
before it reaches them. This page is about the second part — why a run used to be slow, what the
runner does about it, and the switches that turn each piece off.

For the engine itself, see [Engines](Engines). For the full detail, including what the runner
stores and where, see
[DSC v3 support](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/dsc-v3.md#how-many-dsc-processes-a-run-starts).

## Where the time went

Every `dsc resource get|test|set` begins with **resource discovery**: `dsc` reads every directory
on `PATH` looking for manifests, and runs every *discover extension* it finds. dsc 3.3 ships one,
`Microsoft.PowerShell/Discover`, which starts a second PowerShell to walk `PSModulePath`. It runs
on every call, even for a native resource such as `Microsoft.Windows/Registry`, which has nothing
to do with PowerShell.

On a hosted Windows agent that is roughly two seconds per call, and the runner made two or three
calls per resource. Applying a single registry value took about 35 seconds, nearly none of it the
registry.

## What the runner does now

| | Before | Now |
|---|---|---|
| Calls per resource | `test`, then `set`, then always `get` | `test`, and `set` only when the resource has drifted |
| Discovery per call | full | the resource's own manifest only |
| Discovery per run | once per call | once, and reused by the next run |

### Fewer calls

`test` already reports `actualState` and `set` already reports `afterState`, so the runner keeps
that as the resource's current state for `reference()`, `using()` and the report instead of asking
again with `get`. It still calls `get` when the resource has a `postExecutionScript`, when a `set`
failed, and when the engine reported no state at all (`DscV2` and custom engines always do).

### Narrower discovery

The runner lists dsc's resources once, and for a plain command resource copies that one manifest
into a directory of its own. Each later call runs with `DSC_RESOURCE_PATH` pointing there and the
resource's own directory first on `PATH`, so `dsc` finds exactly one manifest and starts no
discover extension. A call drops to about 80 ms.

Some types always keep full discovery, because narrowing them would change what runs: adapted
resources (anything with `requireAdapter`, such as a PowerShell class resource behind
`Microsoft.DSC/PowerShell`), adapters, groups, a manifest that names a script beside it, a type
`dsc` lists more than once, and every call to a remote target. Setting `DSC_RESOURCE_PATH`
yourself also leaves discovery alone — that choice is yours.

### The list reused by the next run

A pipeline usually runs the runner more than once — plan, apply, plan again — and each run paid
for that one listing. The list is saved under your own account and a later run reads it, so only
the first run of the day pays. It is keyed on the `dsc` executable, `PATH`, `PSModulePath` and the
timestamps of the directories those name, so installing or removing a resource makes the next run
list again, and it is checked against the manifest it is about to use before anything is copied.

## Switches

| Variable | What it does |
|---|---|
| `PIPELINERUNNER_DSC_FULL_DISCOVERY=1` | Every call runs dsc's full discovery, as before. Turns the narrowing and the saved list off together. |
| `PIPELINERUNNER_DSC_DISCOVERY_CACHE=0` | Keeps the narrowing, but each run lists for itself and saves nothing. |
| `PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH` | Save lists somewhere else (a directory only you can write to). |
| `PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS` | How long a saved list may be used. Default 24; `0` never uses one. |

Deleting the directory a list was saved in is always safe: the next run lists again.

## When to reach for them

- **A resource behaves as though the wrong provider ran it.** Set
  `PIPELINERUNNER_DSC_FULL_DISCOVERY=1` and run again. If that changes the outcome, say so in an
  issue with the resource's type — the narrowing is meant to be invisible.
- **You install resources during the pipeline, in the same run that uses them.** The saved list
  is keyed on directory timestamps, which catches almost every install, but
  `PIPELINERUNNER_DSC_DISCOVERY_CACHE=0` removes the question.
- **A self-hosted agent where several pipelines run as one account.** A saved list names the
  manifests a later run will copy, and a manifest decides which executable `dsc` runs, so it is
  worth exactly as much trust as that account's own `PATH`. Where pipelines of differing trust
  share an account, turn it off
  ([trust model](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/trust-model.md)).
- **A container that is thrown away after every run.** Nothing is lost by leaving the saved list
  on: there is simply nothing to reuse, and the narrowing still applies.

## Measuring it yourself

`scripts/Measure-DscV3Calls.ps1` times the real engine against a real `dsc` three ways — full
discovery, narrowed, and narrowed reading a saved list — and prints a table. The **DSC v3 engine
on Ubuntu** and **DSC v3 engine on Windows** CI jobs run it and write the table to the job
summary, so every pull request shows what a call costs.

```powershell
./scripts/Measure-DscV3Calls.ps1 -ResourceType 'Microsoft/OSInfo' -Verbose
```
