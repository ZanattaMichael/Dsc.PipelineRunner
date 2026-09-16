# Pipeline Rules

Pipeline rules run **before** any resource is evaluated. They are ordinary `.ps1` files under
the module's `Pipeline Rules/` directory, and they exist so a configuration problem is reported
once, up front, rather than discovered halfway through a `Set` run.

There are two kinds.

```
Pipeline Rules/
├── Custom/                                 # invoked by name, order controlled by the runner
│   ├── Expand-NotifyDependsOn.ps1
│   └── Sort-DependsOn.ps1
└── PreParse/                               # every file in the directory runs, alphabetically
    ├── Test-CircularReferences.ps1
    ├── Test-ExecutionScriptsAllowed.ps1
    └── Test-ResourcesForIncorrectProperties.ps1
```

## When they run

```
Parse the compiled file
 ├─ Custom:   Expand-NotifyDependsOn      → fold notify into dependsOn
 ├─ Custom:   Sort-DependsOn              → topological sort; this produces the execution order
 ├─ PreParse: every *.ps1 in the directory
 └─ Evaluate the resources, in sorted order
```

Custom tasks are invoked by name and **transform** the resource list. Pre-parse rules receive
the list and **validate** it — the standard behaviour is to collect problems, then throw once.

Any rule that throws aborts the file before a single resource runs.

## Custom tasks

### `Expand-NotifyDependsOn`

Folds each resource's `notify` entries into an implicit `dependsOn` on the target, so the
existing ordering and cycle-detection machinery governs `notify` without having to learn a
second relationship. It also builds the declaration map that gates `using()`.

```yaml
resources:

  - name: App Config
    type: PSDscResources/File
    notify:
      - PSDscResources/Service/AppService
    properties:
      DestinationPath: C:\app\appsettings.json
      Ensure: Present

  - name: AppService
    type: PSDscResources/Service
    properties:
      Name: AppService
      State: Running
```

After expansion, `AppService` carries `dependsOn: PSDscResources/File/App Config` — exactly as
if it had been written by hand.

Two failures are raised here, both naming the offending resource:

```
[Expand-NotifyDependsOn] Resource [X] cannot notify itself.
[Expand-NotifyDependsOn] Resource [X] notifies [Y], which is not present in the configuration.
```

The second is what makes `notify` **intra-file**: a target in another compiled file is simply
not present, so it fails here.

### `Sort-DependsOn`

Topologically sorts the resources on their `dependsOn` edges — including the implicit ones just
added — and returns the execution order. The sorted list is what the runner iterates.

```yaml
resources:

  - name: Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      Name: Default Repository

  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      projectName: Magenta
```

`Project` runs first, despite being declared second. Declaration order in the YAML is not
execution order; the graph is.

A dependency naming a resource that is not in the same compiled file is unresolvable and fails
here. This is why `dependsOn` is file-scoped.

## Pre-parse rules

### `Test-CircularReferences`

Depth-first walk of the `dependsOn` graph, throwing when a resource is reachable from itself
and naming the cycle in path order.

This one distinguishes two graph shapes that look similar:

```yaml
# A cycle — rejected.
  - name: A
    type: M/R
    dependsOn: [M/R/B]
    properties: {}
  - name: B
    type: M/R
    dependsOn: [M/R/A]
    properties: {}
```

```yaml
# A diamond — perfectly valid. C is reached by two branches, and explored once.
  - name: A
    type: M/R
    dependsOn: [M/R/B, M/R/C]
    properties: {}
  - name: B
    type: M/R
    dependsOn: [M/R/D]
    properties: {}
  - name: C
    type: M/R
    dependsOn: [M/R/D]
    properties: {}
  - name: D
    type: M/R
    properties: {}
```

A resource counts as a cycle only while it is still on the current path, so the shared tail of
a diamond is not reported.

A `dependsOn` naming a resource that is not present is **skipped** here with a verbose message
— an unresolved dependency is a different problem, and the ordering rules report it.

### `Test-ExecutionScriptsAllowed`

Gates `preExecutionScript` / `postExecutionScript` behind
`PipelineRunnerSettings.AllowExecutionScripts`. Absent or false, the rule collects every
resource carrying either key and throws once, naming all of them:

```
[Test-ExecutionScriptsAllowed] preExecutionScript/postExecutionScript are used by 2 resource(s)
([AzureDevOpsDscNative/AzDoProject/Project], [PSDscResources/Script/Bootstrap]) but
PipelineRunnerSettings.AllowExecutionScripts is not enabled. Add 'AllowExecutionScripts: true'
to the PipelineRunnerSettings block in Datum.yml to allow lifecycle scripts, or remove
preExecutionScript/postExecutionScript from these resources.
```

The gate is on the **presence** of the key, not on whether the script would have run. A
configuration cannot carry a dormant script under a false setting.

### `Test-ResourcesForIncorrectProperties`

The heaviest rule, and the one that catches most configuration mistakes. For each resource it:

1. Requires `name` and `properties` to be present. A resource missing either is reported and
   its deeper checks are skipped — the rule moves to the next resource rather than aborting.
2. Looks the resource up with `Get-DscResource -Name <ResourceName> -Module <Module>`, and
   reports it when the module or resource is not installed.
3. Checks every key in `properties` against the resource's real property list.
4. Reports a mandatory property left null.
5. Reports a value outside the resource's `ValidateSet`, naming the permitted set.

Every problem is collected, then the rule throws once with the total count — so one pass shows
you every offending resource instead of fix-and-rerun.

```
[Dsc.PipelineRunner] Property [visibilty] does not exist in resource [AzDoProject] in module [AzureDevOpsDscNative]
[Dsc.PipelineRunner] Property [Ensure] does not match the selected values in resource [File][Ensure]. Permitted values: Present, Absent
[Test-ResourcesForIncorrectProperties] Tests Failed (2 issue(s)). Stopping runner.
```

Two behaviours worth knowing:

- **Computed values are skipped.** A property value containing `$` is not known until execution,
  so the `ValidateSet` and type checks skip it with a yellow note. `Ensure: $(variables('X'))`
  is never rejected here, and a bad value surfaces at execution instead.
- **Offending values are not logged.** Property values routinely carry secrets, and the
  pre-parse log is readable by a wider audience than the configuration repository. The message
  names the property, the resource and the permitted set; the value itself goes only to the
  verbose stream, redacted for sensitive-looking property names.

This rule requires the DSC resource modules to be **installed on the runner**, because it
inspects their real schemas. A configuration referencing a module that is not present fails
here rather than at execution.

## Writing your own rule

A pre-parse rule is a `.ps1` file with a `param` block, dropped into `Pipeline Rules/PreParse/`.
Every file in the directory runs, alphabetically, on every compiled file.

```powershell
<#
.SYNOPSIS
Requires every resource to carry a non-empty 'name'.
#>
[CmdletBinding()]
param(
    [Object[]]$PipelineResources,

    # Optional. The resolved PipelineRunnerSettings block.
    [hashtable]$Settings
)

$offenders = [System.Collections.Generic.List[string]]::new()

foreach ($task in $PipelineResources) {
    if ([string]::IsNullOrWhiteSpace([string]$task.name)) {
        $offenders.Add("[$($task.type)]")
    }
}

if ($offenders.Count -gt 0) {
    throw "[Test-NamesPresent] $($offenders.Count) resource(s) have no name: $($offenders -join ', ')"
}
```

Two contract notes:

- **`-Settings` is optional.** The loader inspects the script's parameters and forwards
  `-Settings` only when the rule declares it, so a rule written against the older
  `-PipelineResources`-only contract keeps working unchanged.
- **Collect, then throw once.** Throwing on the first offender means an operator fixes one
  problem, re-runs, and finds the next. Every built-in rule collects and reports together;
  yours should too.

Rules are dot-sourced from the module's own directory, so a custom rule has to be deployed
alongside the module rather than living in the configuration repository.

## Rules and scope

Every rule sees exactly one compiled file's resources. There is no rule stage that sees the
whole run, which is the mechanical reason `dependsOn`, `notify` and `using()` cannot cross
files: by the time a rule could observe a cross-file edge, the other file's resources are not
in the list it was handed.
