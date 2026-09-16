# Function Language

The function language is a small set of accessors usable inside a resource's `properties`,
`preCondition` and `postCondition`. There are eight of them:

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`variables('Name')`](#variablesname) | 1 | properties, conditions | The resolved variable, or `$null`. |
| [`parameters('Name')`](#parametersname) | 1 | properties, conditions | The parameter. **Throws** if undefined. |
| [`reference('Name')`](#referencename) | 1 | properties, conditions | An earlier resource's output, by bare name. |
| [`using('Type/Name')`](#usingtypename) | 1 | properties only | Another resource's `Get()` output. Gated by `notify`. |
| [`equals(a, b)`](#equals-and-not) | 2 | properties, conditions | `[bool]` string equality. |
| [`not(b)`](#equals-and-not) | 1 | properties, conditions | `[bool]` negation. |
| [`result()`](#result) | 0 | **postCondition only** | This resource's engine result. |
| [`stopProcessing()`](#stopprocessing) | 0 | **postCondition only** | `$true`, and skips the rest of the file. |

## Two rules that catch everyone

### 1. Arguments are space-separated

These are PowerShell commands, not C# functions. Inside a condition, write:

```yaml
    preCondition: equals (variables 'Environment') 'Production'
```

Not `equals(variables('Environment'), 'Production')` — that binds the whole parenthesised
expression to the first parameter and fails with a parameter-binding error.

Inside `properties`, the value is already wrapped in `$( )`, so the single-argument accessors
read naturally either way:

```yaml
    properties:
      Name: $(variables('AppName'))        # fine — one argument, parens are just grouping
      Path: $(variables 'AppRoot')         # also fine
```

### 2. `$(...)` and `[x={ }=]` happen at different times

`[x={ $Node.Project }=]` is a **Datum** handler. It runs during compilation and bakes a literal
value into the compiled file.

`$(variables('Project'))` is the **runner's** expansion. It runs at execution time, when the
compiled file is read.

```yaml
variables:
  ProjectName: '[x={ $Node.Project }=]'    # compile time: becomes e.g. "Magenta"

resources:
  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      projectName: $(variables('ProjectName'))   # execution time: reads "Magenta"
```

If a value is wrong, compile the configuration and read the per-node YAML to see which of the
two stages produced it.

---

## `variables('Name')`

Reads a variable resolved by Datum for this node.

```yaml
variables:
  AppRoot: C:\App
  Environment: Production

resources:

  - name: App Directory
    type: PSDscResources/File
    properties:
      DestinationPath: $(variables('AppRoot'))
      Type: Directory
      Ensure: Present
```

Composed into a larger string:

```yaml
    properties:
      DestinationPath: $(variables('AppRoot'))\logs\$(variables('Environment')).log
```

In a condition:

```yaml
    preCondition: (variables 'Environment') -eq 'Production'
```

An **undefined** variable returns `$null` rather than throwing. That is deliberate — a
configuration layer may legitimately leave a variable unset — but it means a typo produces an
empty value instead of an error. Guard values you rely on:

```yaml
    properties:
      Ensure: $( if ([string]::IsNullOrEmpty((variables 'Project_Ensure'))) { 'Present' } else { variables 'Project_Ensure' } )
```

The same values are also available as plain PowerShell variables (`$AppRoot`), because the
runner sets both. `variables()` is the preferred spelling: it keeps `properties`,
`preCondition` and `postCondition` all using one accessor rather than two syntaxes for the same
lookup, and it is what the condition allow-list permits.

## `parameters('Name')`

Reads a run-scoped parameter — and **throws** if the name is not defined.

```yaml
parameters:
  Environment: Production
  ConfigJson: '{"level":"info"}'

resources:

  - name: App Config
    type: PSDscResources/File
    properties:
      Contents: $(parameters('ConfigJson'))
      DestinationPath: C:\App\appsettings.json
      Ensure: Present
```

In a condition:

```yaml
    preCondition: equals (parameters 'Environment') 'Production'
```

The throw is the point of difference from `variables()`. An undefined parameter used to resolve
silently to `$null`, which meant the wrong value landed in a resource property and the run
applied the wrong configuration instead of reporting the mistake. Presence is a key lookup, so
a parameter explicitly set to an empty string is defined and returns `""`.

```
[parameters] Parameter 'Enviroment' not found in the parameters hashtable.
```

Use `parameters()` for values the run must not proceed without, and `variables()` for values
with a sensible absent case.

## `reference('Name')`

Reads an earlier resource's recorded output, addressed by its **bare instance name**:

```yaml
resources:

  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      projectName: Magenta

  - name: Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      ProjectId: $((reference 'Project').Id)
      Name: Default Repository
```

`reference()` is an open lookup: any resource may read any earlier resource's output. It
returns `$null` for a name that has not run yet, so ordering is on you — pair it with
`dependsOn` as above.

When you want the lookup to be *declared* rather than implicit, and to fail loudly when it is
not, use `using()` instead.

## `using('Type/Name')`

Reads another resource's `Get()` output — the same object `reference()` exposes — addressed by
its full `Type/Name` identity, and **only** from a resource that the source resource's own
`notify` list names:

```yaml
resources:

  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    notify:
      - AzureDevOpsDscNative/AzDoGitRepository/Default Repository
    properties:
      projectName: Magenta

  - name: Default Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    properties:
      ProjectId: $((using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
```

The gate means a data dependency is always paired with the ordering guarantee that `notify`
provides. Three distinct errors, all thrown rather than resolved to `$null`:

```
[using] Resource [X] has no 'notify' declaration, or does not exist.
[using] Resource [X] does not notify [Y].
[using] Resource [X] has not produced Get() output yet.
```

### `using` must be nested

`using` is a PowerShell reserved word whenever it is the first token of a statement (the
`using namespace` / `using module` directive). A bare, unwrapped call is a **parse** error, not
a runtime one:

```yaml
    properties:
      ProjectId: $(using 'Module/Type/Name')                  # parse error
      ProjectId: $((using 'Module/Type/Name').Id)             # correct
      ProjectId: $( $p = using 'Module/Type/Name'; $p.Id )    # also correct — not the first token
```

Always nest it inside an outer expression, exactly as the `.Property` form above does
naturally.

### `using()` is for `properties`

It is not on the condition allow-list. It is designed for property expansion, which is where
`reference()`, `variables()` and `parameters()` are used, not for `preCondition` /
`postCondition`.

### `using()` is intra-file

Both halves of the relationship live in one compiled configuration file. A resource in one
file cannot `using()` a resource in another — it hits the first guard and reports that the
resource "has no `notify` declaration, or does not exist", because that file's declaration map
is empty. See
[notify and using()](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/notify-and-using.md).

## `equals` and `not`

Two helpers that exist mainly so a condition can express a comparison using only allow-listed
commands.

`equals` is `[System.String]::Equals` on two strings — ordinal, case-**sensitive**:

```yaml
    preCondition: equals (variables 'Environment') 'Production'
```

`not` negates a boolean:

```yaml
    preCondition: not (equals (variables 'Project_Ensure') 'Absent')
```

Composed:

```yaml
    postCondition: result().InDesiredState -or (not (equals (variables 'Project_Ensure') 'Present'))
```

You are not obliged to use them — `-eq`, `-ne`, `-and`, `-or` and `-not` are all permitted in a
condition, because operators are not command invocations:

```yaml
    preCondition: (variables 'Environment') -eq 'Production' -and (variables 'Role') -ne 'Sandbox'
```

Reach for `equals` when you want ordinal, case-sensitive string comparison specifically;
PowerShell's `-eq` on strings is case-insensitive.

## `result()`

Returns this resource's normalized engine result, in a `postCondition` only.

```yaml
    postCondition: result().InDesiredState
```

```yaml
    postCondition: result().InDesiredState -or (parameters 'Environment') -eq 'Sandbox'
```

```yaml
    postCondition: result().Message -notmatch 'deprecated'
```

It is a pure read of an already-computed value: it never re-runs the engine. Outside a
`postCondition` it returns `$null`, and in a `preCondition` it is rejected outright as a
disallowed command invocation.

## `stopProcessing()`

Sets the run-control flag that makes the runner skip every remaining resource in this file.
`postCondition` only.

```yaml
  - name: Prerequisite Check
    type: PSDscResources/Script
    postCondition: result().InDesiredState -or stopProcessing()
    properties:
      GetScript: '@{ Result = "" }'
      TestScript: Test-Path C:\prereq.marker
      SetScript: 'throw "Prerequisite missing."'
```

Because it returns `$true`, the `-or` above means the resource is **not** marked `FAIL` — the
file stops cleanly. Every remaining resource is recorded `SKIP`, and the file's run status
becomes `StoppedByRequest`, which aggregates to `PartialSuccess` rather than `Failed`.

A single `postCondition` cannot both fail the resource and stop the file — whatever the
expression evaluates to decides one or the other. To get both, let the `postCondition` fail the
resource and stop the file from a `postExecutionScript` (which needs
`AllowExecutionScripts: true`):

```yaml
    postCondition: result().InDesiredState
    postExecutionScript: if (-not (Test-Path C:\prereq.marker)) { Stop-TaskProcessing }
```

`stopProcessing()` is the one accessor with a deliberate side effect, which is exactly why it
is reachable only from `postCondition` — a `preCondition` must stay a pure predicate.

Its cmdlet equivalent, `Stop-TaskProcessing`, is callable only from a `preExecutionScript` /
`postExecutionScript`, which require `AllowExecutionScripts: true`. `stopProcessing()` needs no
such opt-in, because it is validated as an expression rather than executed as free-form script.

## Zero-argument calls are rewritten

`identifier()` with nothing between the parentheses is not valid PowerShell, so `result()` and
`stopProcessing()` — the only zero-argument accessors — are rewritten before parsing:

- `result()` → `(result)`, which keeps `result().InDesiredState` working as
  `(result).InDesiredState`.
- `stopProcessing()` → `stopProcessing`, a bare command invocation.

The rewrite is applied to the same text that is both validated and executed, so the AST that
passes the safety check is the AST that runs. You can write either spelling; `result()` is the
documented one.

## What a condition may not do

`Assert-SafeConditionExpression` parses the expression and rejects:

- any command invocation outside the allow-list — including one nested inside an allowed call,
  such as `equals (Get-Item C:\) 'x'`;
- any variable assignment, such as `$FailCounter = 0`;
- any method or member **invocation**, such as `$reporting.Clear()`.

Permitted: comparisons, logical operators, variable reads, and property access
(`$Node.Project -eq 'X'`, `result().InDesiredState`).

The check runs before the expression is executed, so a rejected condition never runs — the
resource is recorded `FAIL` with a message naming the offending construct and the permitted
command set.

Execution scripts are **not** subject to any of this. They are arbitrary PowerShell, which is
why they sit behind `AllowExecutionScripts`.
