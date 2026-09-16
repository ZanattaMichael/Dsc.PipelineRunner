# Function Language

The function language is a small set of accessors usable inside a resource's `properties`,
`preCondition` and `postCondition`.

**Lookups**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`variables('Name')`](#variablesname) | 1 | properties, conditions | The resolved variable, or `$null`. |
| [`parameters('Name')`](#parametersname) | 1 | properties, conditions | The parameter. **Throws** if undefined. |
| [`reference('Name')`](#referencename) | 1 | properties, conditions | An earlier resource's output, by bare name. |
| [`using('Type/Name')`](#usingtypename) | 1 | properties, conditions | Another resource's `Get()` output. Gated by `notify`. |

**Run context**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`nodeName()`](#nodename-and-configurationfile) | 0 | properties, conditions | The node name of the file being processed. |
| [`configurationFile()`](#nodename-and-configurationfile) | 0 | properties, conditions | That file's full path. |

**Logic**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`equals(a, b)`](#equals-and-not) | 2 | properties, conditions | `[bool]` string equality. |
| [`not(b)`](#equals-and-not) | 1 | properties, conditions | `[bool]` negation. |

**Strings and collections**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`concat(a, b, ...)`](#concat) | 1+ | properties, conditions | The arguments joined as one string. |
| [`empty(v)`](#empty) | 1 | properties, conditions | `[bool]` — `$null`, `''` or an empty collection. |
| [`coalesce(a, b, ...)`](#coalesce) | 1+ | properties, conditions | The first argument that is not `$null`. |
| [`toLower(s)`](#tolower-and-toupper) | 1 | properties, conditions | Invariant lower-case. |
| [`toUpper(s)`](#tolower-and-toupper) | 1 | properties, conditions | Invariant upper-case. |
| [`startsWith(s, prefix)`](#startswith) | 2 | properties, conditions | `[bool]`, case-insensitive by default. |
| [`contains(container, item)`](#contains) | 2 | properties, conditions | `[bool]` — substring, element, or dictionary **key**. |

**Arithmetic**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`add(a, b, ...)`](#arithmetic) | 1+ | properties, conditions | Sum. |
| [`sub(a, b)`](#arithmetic) | 2 | properties, conditions | Difference. |
| [`mul(a, b, ...)`](#arithmetic) | 1+ | properties, conditions | Product. |
| [`div(a, b)`](#arithmetic) | 2 | properties, conditions | Quotient. Whole-number when both operands are. |
| [`mod(a, b)`](#arithmetic) | 2 | properties, conditions | Remainder. |
| [`min(a, b, ...)`](#arithmetic) | 1+ | properties, conditions | Smallest, keeping the operand's own type. |
| [`max(a, b, ...)`](#arithmetic) | 1+ | properties, conditions | Largest, keeping the operand's own type. |
| [`int(v)`](#arithmetic) | 1 | properties, conditions | A whole number, truncated toward zero. |
| [`float(v)`](#arithmetic) | 1 | properties, conditions | A real number. |

**postCondition only**

| Accessor | Arguments | Where it may be used | Returns |
| --- | --- | --- | --- |
| [`result()`](#result) | 0 | **postCondition only** | This resource's engine result. |
| [`stopProcessing()`](#stopprocessing) | 0 | **postCondition only** | `$true`, and skips the rest of the file. |

There is deliberately no `secret()` accessor — see
[Why there is no `secret()`](#why-there-is-no-secret).

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

### `using()` in a `preCondition`

`using()` is on the condition allow-list, so a `preCondition` may gate a resource on what
another resource's `Get()` actually returned:

```yaml
  - name: Default Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    preCondition: equals (using 'AzureDevOpsDscNative/AzDoProject/Project').Visibility 'Private'
```

The `notify` gate applies exactly as it does in `properties`: the runner sets the current
resource key before the `preCondition` is evaluated, so the same declaration that makes the read
legal in a property makes it legal here, and the same three errors are thrown when it is not. A
resource whose `preCondition` reads a resource that does not notify it is recorded `FAIL` — it
is not silently skipped.

Because `using` is a reserved word as the first token of a statement, it must be nested in a
condition too. `preCondition: using 'Mod/Type/Name'` is a parse error; wrap it as above, or in
parentheses on its own:

```yaml
    preCondition: not (empty (using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
```

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

## `nodeName()` and `configurationFile()`

Two zero-argument reads of the run context. `nodeName()` returns the node name derived from the
compiled configuration file currently being processed; `configurationFile()` returns that file's
full path.

```yaml
    preCondition: startsWith (nodeName()) 'SRV-PROD'
```

```yaml
    preCondition: not (contains (configurationFile()) 'Sandbox')
```

Both are `$null` outside a run, and both are cleared as soon as the runner finishes the file, so
they never answer for a file that is no longer being processed.

### The property spelling is bare

In a condition, write `nodeName()`. In `properties`, write `$(nodeName)` — **without** the
parentheses:

```yaml
    properties:
      DestinationPath: C:\logs\$(nodeName).log       # correct
      DestinationPath: C:\logs\$(nodeName()).log     # parse error
```

Property expansion and condition evaluation take different paths through the runner. A condition
is normalized first (see [Zero-argument calls are rewritten](#zero-argument-calls-are-rewritten)),
which is what turns `nodeName()` into something PowerShell can parse. A property is expanded
directly, with no normalization step — but `$( )` is already a sub-expression, so the bare
`$(nodeName)` form needs no rewrite and works as written.

## `concat`

Joins its arguments into a single string. `$null` contributes an empty string.

```yaml
    properties:
      DestinationPath: $(concat (variables 'AppRoot') '\logs\' (nodeName) '.log')
```

```yaml
    preCondition: equals (concat (variables 'Env') '-' (variables 'Region')) 'prod-eastus'
```

`concat` is **string concatenation only**. It does not merge arrays: PowerShell unrolls an array
argument into the accessor's parameter list, so `concat $someArray` and `concat 'a' 'b'` are
indistinguishable by the time the function is entered, and a dual-mode accessor would make the
result depend on a variable's runtime shape. Use `+` for arrays — it is an operator, not a
command invocation, so it is permitted in a condition:

```yaml
    properties:
      Members: $((variables 'BaseAdmins') + (variables 'ExtraAdmins'))
```

## `empty`

`$true` for `$null`, an empty string, an empty collection or an empty dictionary; `$false` for
everything else.

```yaml
    preCondition: not (empty (variables 'Project_Ensure'))
```

Note what is **not** empty: whitespace (`' '`), the number `0`, and `$false`. `empty` reports
absence, not falsiness.

## `coalesce`

Returns the first argument that is not `$null` — the usual way to supply a default for a
variable a configuration layer may legitimately leave unset:

```yaml
    properties:
      Ensure: $(coalesce (variables 'Project_Ensure') 'Present')
```

It tests for `$null` only, matching ARM's semantics. An empty string is a value, so
`coalesce (variables 'X') 'fallback'` returns `''` when `X` is defined as `''`. Combine with
`empty` when you want the blank to fall through too:

```yaml
    properties:
      Ensure: $( if (empty (variables 'Project_Ensure')) { 'Present' } else { variables 'Project_Ensure' } )
```

## `toLower` and `toUpper`

Invariant-culture case conversion. `$null` becomes `''`.

```yaml
    preCondition: equals (toLower (variables 'Environment')) 'production'
```

Invariant, not current-culture, so the same configuration produces the same result on an agent
with any regional settings — the Turkish dotless-i problem does not appear.

## `startsWith`

`[bool]`, case-**insensitive** by default:

```yaml
    preCondition: startsWith (nodeName()) 'SRV'
```

Pass `-CaseSensitive` when case matters:

```yaml
    preCondition: startsWith (variables 'Sku') 'Std' -CaseSensitive
```

## `contains`

Dispatches on what the container is:

| Container | Meaning |
| --- | --- |
| A string | Substring test. |
| A dictionary / hashtable | Does it have this **key**? |
| Any other collection | Does it have this element? |

```yaml
    preCondition: contains (configurationFile()) 'Production'          # substring
    preCondition: contains (variables 'EnabledFeatures') 'Boards'      # array element
    preCondition: contains (variables 'FeatureMap') 'Boards'           # dictionary KEY
```

The dictionary case is the one that surprises people: `contains @{ Boards = 'enabled' } 'enabled'`
is `$false`, because `enabled` is a value, not a key. A `$null` container is `$false` rather than
an error. `-CaseSensitive` applies to the string and collection cases.

## Arithmetic

Nine accessors, all operating on numbers: `add`, `sub`, `mul`, `div`, `mod`, `min`, `max`, `int`
and `float`. `add`, `mul`, `min` and `max` take one or more operands; `sub`, `div` and `mod` take
exactly two; `int` and `float` take one.

```yaml
    properties:
      Port: $(add 8000 (int (variables 'NodeIndex')))
```

```yaml
    preCondition: (mod (variables 'NodeIndex') 2) -eq 0
```

```yaml
    properties:
      Workers: $(max 2 (min 16 (int (variables 'CpuCount'))))
```

### Whole numbers stay whole

An operand's own integrality is preserved. An operand that is already a whole number — or a
string that parses as one, like the `"4"` a YAML file so often yields — stays a whole number
through the operation, so `add 8000 '4'` is `8004`, not `8004.0`.

`div` follows from that: when **both** operands are whole numbers it divides as whole numbers,
truncating toward zero, and otherwise it divides as real numbers.

```yaml
    properties:
      Half: $(div 7 2)            # 3
      Half: $(div (float 7) 2)    # 3.5
```

`float()` is how you opt into real division; `int()` truncates back toward zero. A value that is
already a real number is never silently collapsed back to a whole one, which is what makes
`float()` meaningful rather than a no-op.

`min` and `max` return the operand itself rather than a converted copy, so a whole-number operand
list yields a whole-number result.

### Bad operands throw

Every arithmetic accessor throws on `$null`, on a boolean, and on a string that is not numeric,
naming the accessor and the offending value:

```
[add] Expected a number but received [prod], which is not numeric.
```

That failure is scoped to the resource whose expression contained it — the resource is recorded
`FAIL` and the rest of the file continues. Strings are parsed with the invariant culture, so a
configuration behaves identically on an agent in any locale.

`div` and `mod` throw on a zero divisor rather than producing infinity or `NaN`.

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

`identifier()` with nothing between the parentheses is not valid PowerShell — `()` alone is not
a sub-expression — so the four zero-argument accessors are rewritten before the expression is
parsed:

| Written | Rewritten to |
| --- | --- |
| `result()` | `(result)` |
| `stopProcessing()` | `(stopProcessing)` |
| `nodeName()` | `(nodeName)` |
| `configurationFile()` | `(configurationFile)` |

Each rewrite produces a parenthesised sub-expression rather than a bare command, because member
access needs one (`result().InDesiredState` becomes `(result).InDesiredState`) and because **a
bare command is not a valid operand**. PowerShell rejects `... -or stopProcessing` with "You must
provide a value expression following the '-or' operator", so the documented composition

```yaml
    postCondition: result().InDesiredState -or stopProcessing()
```

only works with the parenthesised form. Earlier versions rewrote `stopProcessing()` to a bare
`stopProcessing`, which meant that exact spelling — the one the documentation leads with — failed
to parse; it now runs as written.

The rewrite is applied to the same text that is both validated and executed, so the AST that
passes the safety check is the AST that runs. You can write either spelling; the `()` form is the
documented one.

This applies to **conditions only**. Property expansion does not go through the rewrite, which is
why a property is written `$(nodeName)` rather than `$(nodeName())` — see
[The property spelling is bare](#the-property-spelling-is-bare).

## Why there is no `secret()`

There is deliberately no accessor for reading a secret from an expression, and one will not be
added.

A `condition`, `preCondition` and `postCondition` is recorded **verbatim** in the run's audit
record, and again in the `SKIP` message of every resource it gates. An accessor that read a
secret would therefore put the shape of that lookup — and, with a careless expression such as
one that interpolated the result, its value — into the report, which is written to disk and
routinely attached to a pipeline run as an artifact.

Secrets reach a resource through its `resourceCredential` block, which the runner resolves
without ever placing the value in an expression. `secret` is not on the allow-list, so a
configuration that tries it is rejected before the condition runs:

```
[Dsc.PipelineRunner] A 'condition' must be a side-effect-free predicate. Rejected condition
[equals (secret 'ApiKey') 'x'] because it contains a command invocation [secret 'ApiKey'].
```

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
