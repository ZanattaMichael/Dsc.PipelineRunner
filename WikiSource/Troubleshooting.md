# Troubleshooting

Symptoms, grouped by what the runner tells you. Start with the two commands that answer most
questions:

```powershell
# What does the runner actually see?
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -KeepTemporaryDirectory -Verbose
```

```powershell
# Compile only, and read the per-node YAML.
New-Item -ItemType Directory -Path .\cache -Force | Out-Null
Build-DatumConfiguration -OutputPath .\cache -ConfigurationPath 'C:\config' -AllowedRoot .\cache -Verbose
Get-ChildItem .\cache -Filter *.yml | ForEach-Object { Write-Host "--- $($_.Name)"; Get-Content $_.FullName }
```

The compiled file is the exact input the runner evaluates. Most "the value is wrong" questions
are answered by reading it.

---

## The run does nothing

### `TotalConfigurations` is 0

Datum produced no node files. Check `ResolutionPrecedence` in `Datum.yml` against the actual
directory layout — a precedence entry naming a directory that does not exist yields nothing,
silently.

```powershell
$result = Invoke-DscRunner -ConfigurationSourcePath 'C:\config'
$result.TotalConfigurations
```

### Every resource is `SKIP`

Either a `preCondition` is `$false` across the board, or something set the stop flag on the
very first resource. The `ErrorMessage` on each record distinguishes them:

```
Resource skipped due to preCondition {...}
Resource skipped due to 'Stop-TaskProcessing' cmdlet.
```

The classic case of the second is a `postExecutionScript` calling `Stop-TaskProcessing`
unguarded — it runs in `Test` mode too, where a not-yet-existing resource is ordinary drift
rather than a reason to stop. Guard it:

```yaml
    postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
```

---

## The run fails before any resource runs

These are pre-parse failures. Every one of them aborts the file.

### `Resource [X] was not found in module [Y]`

`Test-ResourcesForIncorrectProperties` calls `Get-DscResource` against the real, installed
module. The rule needs the DSC resource modules present on the runner, so:

```powershell
Get-DscResource -Module AzureDevOpsDscNative | Select-Object Name, Version
```

Check the `type` spelling, and that the module is installed where the runner can see it.

### `Property [X] does not exist in resource [Y]`

A typo, or a property from a different version of the resource. Compare against the schema:

```powershell
(Get-DscResource -Name File -Module PSDscResources).Properties |
    Select-Object Name, PropertyType, IsMandatory
```

Every problem is collected and reported together, so one run shows you all of them.

### `Property [X] does not match the selected values`

The value is outside the resource's `ValidateSet`. The message names the permitted set; the
offending value is deliberately **not** logged, because property values routinely carry
secrets. Add `-Verbose` to see it, redacted for sensitive-looking property names.

Note that a value containing `$` is skipped by this check — `Ensure: $(variables('X'))` is
never rejected here, and a bad value surfaces at execution instead.

### `preExecutionScript/postExecutionScript are used by N resource(s) ... AllowExecutionScripts is not enabled`

Add the opt-in to `Datum.yml`:

```yaml
PipelineRunnerSettings:
  AllowExecutionScripts: true
```

Or replace the script with a `postCondition` using `stopProcessing()`, which needs no opt-in.
The gate is on the *presence* of the key, so commenting the script body out is not enough —
remove the key.

### `Resource [X] cannot notify itself` / `notifies [Y], which is not present in the configuration`

`Expand-NotifyDependsOn`. The second message is also what you get when the target is in a
**different** compiled file — `notify` is intra-file.

Check the identity spelling: `notify` takes the full `Module/ResourceName/InstanceName`, not
the bare instance name that `reference()` uses.

### A circular dependency

`Test-CircularReferences` names the cycle in path order. A diamond (two branches converging on
one resource) is **not** a cycle and is not reported — if you are seeing this message, there is
a real loop.

Remember that `notify` becomes an implicit `dependsOn`, so a cycle can be formed across the
two: `A dependsOn B` plus `B notify A`.

---

## A resource fails

### `[parameters] Parameter 'X' not found in the parameters hashtable`

`parameters()` throws on an undefined name — deliberately, so a typo does not silently put
`$null` into a property and apply the wrong configuration. Either define the parameter or
switch to `variables()`, which returns `$null` for an absent name.

### A property resolved to an empty string

Almost always `variables()` on a name that is not defined for this node, since it returns
`$null` rather than throwing. Read the compiled file to confirm, then either fix the name or
guard it:

```yaml
    properties:
      Ensure: $( if ([string]::IsNullOrEmpty((variables 'Project_Ensure'))) { 'Present' } else { variables 'Project_Ensure' } )
```

### `A 'condition' must be a side-effect-free predicate`

The expression contains a command outside the allow-list, a variable assignment, or a method
call. The message names the offending construct and the permitted commands.

A condition may call only `parameters`, `variables`, `reference`, `equals` and `not` — plus
`result` and `stopProcessing` in a `postCondition`. The check walks the whole tree, so a
disallowed call nested inside an allowed one is caught too.

Operators are fine: `-eq`, `-and`, `-or`, `-not`, and property access such as
`$Node.Project -eq 'X'`.

### A parameter-binding error in a condition

```yaml
    preCondition: equals(variables('Env'), 'Prod')     # wrong
    preCondition: equals (variables 'Env') 'Prod'      # right
```

These are PowerShell commands. Arguments are space-separated; the parenthesised, comma-separated
form binds the whole list to the first parameter.

### `An expression was expected after '('`

You wrote a zero-argument accessor somewhere the rewrite does not reach, or `using` as the
first token of an expression. `result()` and `stopProcessing()` are rewritten before parsing;
`using` must always be nested:

```yaml
      ProjectId: $(using 'M/T/N')            # parse error — using is a reserved word here
      ProjectId: $((using 'M/T/N').Id)       # correct
```

### `[using] Resource [X] has no 'notify' declaration, or does not exist`

Three distinct causes behind one message:

1. `X` does not exist in this compiled file — including the case where it exists in a
   **different** file. `using()` is intra-file.
2. `X` exists but declares no `notify` at all.
3. The identity is misspelled. `using()` takes the full `Module/ResourceName/InstanceName`.

### `[using] Resource [X] does not notify [Y]`

`X` has a `notify` list, but the calling resource is not on it. Add it:

```yaml
  - name: Project
    type: M/AzDoProject
    notify:
      - M/AzDoGitRepository/Default Repository
```

The gate is deliberate: a data dependency is always paired with the ordering guarantee.

### `[using] Resource [X] has not produced Get() output yet`

`X` ran but its `Get()` threw, so `$null` was recorded. Run with `-Verbose` and look for the
`'Get' method failed for resource [X]` error. A failed `Get` does not fail the resource, which
is why this only surfaces at the reader.

### `Resource failed postCondition {...}`

The expression returned `$false`, which marks the resource `FAIL` regardless of what the engine
reported. Check what `result()` actually holds:

```powershell
$result.Configurations.Results |
    Where-Object InstanceName -eq 'Project Services' |
    Select-Object Status, ErrorMessage
```

### A reboot blocks the file

```
Resource [X] requires a reboot to complete, and the local host cannot safely restart itself
mid-run. Set PipelineRunnerSettings.Reboot: Ignore to continue without restarting, or target
this resource at a remote computer to have the runner restart it and wait automatically.
```

Three options: `Reboot: Ignore`, aim the resource at a remote target (where the runner restarts
and waits automatically), or split the configuration so the reboot is the last thing in the
file. Note that the default policy also **stops the rest of the file**.

---

## Ordering and notify

### A resource ran in the wrong order

Declaration order in the YAML is not execution order — the `dependsOn` graph is. Add the edge
explicitly rather than reordering the file.

A cross-layer surprise: because Datum merges `resources` on `name`, a resource declared in two
layers is one resource. Adding what you think is a second instance gives you a merge instead.

### A notified resource did not re-run

The forced refresh only fires when the notifier's **own** `Test()` reported drift **and** its
`Set()` succeeded. It does not fire when:

- the run is in `Test` mode — there is no `Set()` to force;
- the notifier was itself only forced to run and found nothing to change (a no-op does not
  cascade onward);
- the notifier's `Set()` failed.

### A notify relationship across files does nothing

It is rejected, not ignored — `Expand-NotifyDependsOn` throws that the target "is not present
in the configuration". `notify`, `using()` and `dependsOn` are all scoped to one compiled file,
which is one node. See
[notify and using()](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/notify-and-using.md).

---

## Engines

### `Resource type 'X' is not a DSC v3 identifier`

The configuration is written for `DscV2` but the `DscV3` engine was selected. Either fix the
engine, or convert the types — DSC v3 types are `namespace/name`, e.g.
`Microsoft.Windows/Registry`.

Check which engine was chosen:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Verbose 4>&1 |
    Select-String 'engine'
```

### `'dsc resource set' failed for [X] (exit N)`

`dsc` itself failed. The CLI's own output is included in the message. Reproduce it directly —
the engine builds exactly this call:

```
dsc resource test --resource Microsoft.Windows/Registry --input '{"keyPath":"..."}'
```

### The wrong engine was selected

Selection order is: `-EngineAction`, then an explicitly passed `-Engine`, then
`PipelineRunnerSettings.Engine`, then `DSCResourceVersion`, then `DscV2`. Passing `-Engine`
explicitly **overrides** the configuration; leaving it off lets the configuration decide.

A warning on `Auto`:

```
Resource version '3.0' selects the DSC v3 engine, but the 'dsc' executable was not found on
PATH. The DSC v3 engine will surface the failure when it runs.
```

Selection is deliberate here — it reports the mismatch rather than silently rewriting your
intent.

---

## Targets and credentials

### `'ComputerName' is required in the Target context`

A `target` block with a non-`Local` action needs `computerName` — including when the action is
inherited from `PipelineRunnerSettings.Target`. A file-level `Target: WinRM` with a resource
carrying no `target` block at all fails here.

### `SSH remoting requires the DscV3 engine`

There is no CIM-over-SSH transport for `Invoke-DscResource`. Use `DscV3` for SSH targets.

### SSH cannot authenticate

The runner passes only `ComputerName`, the engine and the credential to a Target action. There
is no `target` key that supplies an SSH user or identity file today — put them in a `Host`
block in the runner account's `~/.ssh/config`.

### `Environment variable(s) 'X'/'Y' are not set`

Both `UserNameVariable` and `PasswordVariable` must name variables that are set **in the
runner's process**. A CI variable marked secret is often not exported to the step by default.

```powershell
[System.Environment]::GetEnvironmentVariable('SQL_USER')
```

### `Secret 'X' is a 'String', not a PSCredential or SecureString`

The `SecretManagement` action resolves a `PSCredential` directly, and wraps a `SecureString`
using `userName` (defaulting to the secret's name). Any other type throws rather than guessing.
Store the secret as one of those two types.

---

## Reports

### No report files were written

`-ReportPath` must be an **existing** directory — it is validated, not created:

```powershell
New-Item -ItemType Directory -Path .\reports -Force | Out-Null
```

### A nested value is missing from the JSON

Both JSON documents serialize to depth 6. A deeply nested `Raw` engine result can be truncated
there. The returned object is not truncated — work with it in-process, or re-serialize what you
need at a greater depth.

### The build passed despite a stopped run

`PartialSuccess` does not set an exit code, by design: a file that stopped via
`Stop-TaskProcessing` did so because the configuration asked it to. For a stricter gate, decide
it yourself:

```powershell
if ($result.Status -ne 'Completed') { exit 1 }
```

---

## Getting more detail

```powershell
# Everything, including per-resource diagnostics.
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Verbose

# Capture the information stream instead of printing it.
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -InformationVariable log
$log.MessageData

# Keep the clone and the compiled cache for inspection.
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -KeepTemporaryDirectory -Verbose

# Compile into a directory you control — never deleted, switch or no switch.
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -CacheDirectory .\cache
```

Verbose output names the engine selection, the sort order, every session opened, and each
accessor resolution — which is usually enough to see which of the two expansion stages,
Datum's or the runner's, produced a wrong value.
