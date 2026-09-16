# Engines

An **engine** is what actually evaluates a resource. The runner's core loop is engine-agnostic:
it hands the engine a method, a module, a resource name and a property table, and expects a
normalized result back.

Two engines ship with the module, and the seam is open.

| Engine | Backed by | Platform | Default |
| --- | --- | --- | --- |
| `DscV2` | `Invoke-DscResource` | Windows / PowerShell DSC | yes |
| `DscV3` | `dsc` (the DSC v3 CLI) | Windows, Linux, macOS | no |

## Selecting one

First match wins:

1. `-EngineAction` — an inline scriptblock.
2. `-Engine` passed explicitly to the cmdlet.
3. `PipelineRunnerSettings.Engine`.
4. `PipelineRunnerSettings.DSCResourceVersion` — major `2` ⇒ `DscV2`, major `3` ⇒ `DscV3`.
5. `DscV2`.

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Engine DscV3
```

```yaml
PipelineRunnerSettings:
  Engine: DscV3
```

```yaml
PipelineRunnerSettings:
  DSCResourceVersion: 3.0     # back-compat spelling; selects DscV3
```

### `Auto`

`Auto` is the only value that triggers detection:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Engine Auto
```

- With a version hint (`-EngineVersion`, or `DSCResourceVersion`), the major version decides:
  `>= 3` ⇒ `DscV3`, `2` ⇒ `DscV2`.
- Without a decisive version, `DscV3` is chosen only when the `dsc` executable is actually
  resolvable on `PATH`; otherwise `DscV2`.
- When the version asks for `DscV3` but `dsc` is not on `PATH`, a warning is emitted and
  `DscV3` is still returned — so the engine surfaces the concrete failure rather than selection
  silently rewriting your intent.

An explicitly named engine is **never** probed or overridden. Naming an engine gets you that
engine.

Selection happens **once per file**, not per resource, so a `dsc.exe` probe or an
auto-selection warning appears once rather than repeating for every resource.

## `DscV2`

The original path, and the default. One `Invoke-DscResource` call per method:

```powershell
Invoke-DscResource -Name File -ModuleName PSDscResources -Method Test -Property @{ ... }
```

Resource types are the familiar `Module/ResourceName`:

```yaml
  - name: Log Directory
    type: PSDscResources/File
    properties:
      DestinationPath: C:\Logs
      Type: Directory
      Ensure: Present
```

Remote execution runs the same `Invoke-DscResource` call **on the far side**, over the target's
`PSSession`. It does not add `-CimSession`: `PSDesiredStateConfiguration` 2.x, the module
PowerShell 7 uses, has no such parameter, and passing one fails the call outright. A target that
resolves a `CimSession` and no `PSSession` still uses `-CimSession`, where the host's
`Invoke-DscResource` provides it.
`[pscredential]` properties marshal natively as `MSFT_Credential` over the encrypted WinRM
transport, so a credential never needs to be converted to plaintext.

## `DscV3`

Drives Microsoft's cross-platform DSC v3 CLI. This is what makes hosted Linux and macOS agents
useful, since `Invoke-DscResource` is Windows-first.

Each method becomes one process invocation:

```
dsc resource test --resource Microsoft.Windows/Registry --input '{"keyPath":"...","valueName":"..."}'
dsc resource set  --resource Microsoft.Windows/Registry --input '{...}'
dsc resource get  --resource Microsoft.Windows/Registry --input '{...}'
```

### Resource types must be DSC v3 identifiers

DSC v3 types are namespaced `namespace/name`, where each half may be dotted:

```yaml
  - name: App Key
    type: Microsoft.Windows/Registry
    properties:
      keyPath: HKCU\Software\Contoso
      valueName: Installed
      valueData:
        String: 'true'
```

The engine checks the shape before invoking anything, so a configuration written for `DscV2`
and pointed at `DscV3` fails with a message that names the problem rather than an opaque
"resource not found" exit:

```
[Actions/Engine/DscV3] Resource type 'PSDscResources/File' is not a DSC v3 identifier.
DSC v3 types are 'namespace/name' (for example 'Microsoft.Windows/Registry'); a compiled
configuration targeting the DscV3 engine must use DSC v3 resource types.
```

The structural check is not an existence check — whether the type really exists is still
confirmed by `dsc` itself.

### Credentials become JSON

JSON has no credential type, so a `[pscredential]` property is resolved to
`{ username, password }` and a bare `[securestring]` to its plaintext value, immediately before
the `--input` payload is built. That payload goes either to the local `dsc` process or, for a
remote target, over the already-encrypted `Invoke-Command -Session` channel. It is never
written to disk via `--file`.

The verbose log is built from a **separately redacted** copy: any property that started life as
a credential or secure string is force-redacted regardless of its name, and a name-based
heuristic catches the rest.

```
[Actions/Engine/DscV3] dsc resource set --resource Contoso/SqlDatabase --input {"ServerName":"sql01","Credential":"[REDACTED]"}
```

### Result shapes

The engine normalizes the three DSC v3 result shapes:

| Method | DSC v3 returns | Normalized to |
| --- | --- | --- |
| `test` | `desiredState`, `actualState`, `inDesiredState`, `differingProperties` | `InDesiredState`, and a `Message` listing the differing properties |
| `set` | `beforeState`, `afterState`, `changedProperties` | a `Message` listing the changed properties |
| `get` | `actualState`, or the state object directly | `Raw` |

A non-zero exit from `dsc` is thrown, so the resource is recorded `FAIL` with the CLI's own
output. Output that is not parseable JSON is likewise a thrown error naming the resource.

### Reboot signalling

`dsc`'s exact shape for a reboot-pending signal is not confirmed against a real resource that
sets it, so the engine reads tolerantly from either observed shape: a top-level
`rebootRequired` boolean, or a nested `metadata.'Microsoft.DSC'.rebootRequired`. Absent either,
it reports `$false`.

## `dsc config` is not used

The runner invokes `dsc resource <verb>` **per resource, per method**. It never calls
`dsc config`, and the decision is forced by the design rather than by convenience: the runner
makes decisions *between* resources — a `preCondition`, a `postExecutionScript`, a
`Stop-TaskProcessing`, a reboot policy, a notify-forced refresh — based on what the previous
resource returned. Handing a whole document to `dsc config` would surrender exactly those
decision points.

`ConvertTo-DscV3ConfigurationDocument` is available if you want a v3 configuration document for
some other purpose. It is an exported helper with no internal caller: it builds a fresh
document containing only `name`, `type` and `properties` per resource, so every pipeline-only
key — `dependsOn`, `notify`, `preCondition`, `postCondition`, the execution scripts, `target`,
`resourceCredential` — is dropped by construction.

```powershell
$doc = ConvertTo-DscV3ConfigurationDocument -Resource $resources
$doc | ConvertTo-Json -Depth 10
```

Those keys are pipeline-runner concepts, not DSC concepts. DSC receives a flat, compiled
artifact; the relationships have already been discharged into the *order* the runner evaluates
things in.

## The engine contract

An engine action is a `.ps1` under `Actions/Engine/` taking a single `-Context` hashtable:

| Context key | Meaning |
| --- | --- |
| `Method` | `Test`, `Set` or `Get`. |
| `ModuleName` | The left half of the resource's `type`. |
| `Name` | The right half of the resource's `type`. |
| `Property` | The fully expanded property table. |
| `Session` | The target session, or `$null` for local. |

It must return an object exposing:

| Property | Meaning |
| --- | --- |
| `InDesiredState` | `[bool]`. Default `$true` when the method does not report one. |
| `RebootRequired` | `[bool]`. Default `$false`. |
| `Message` | A human-readable detail, or `$null`. |
| `Raw` | The underlying result, unmodified — this is what `reference()` and `using()` expose. |

The runner normalizes that into a `[DscMethodResult]`, so the loop, the report and the exit
code stay engine-agnostic.

## Bringing your own

Pass a scriptblock, no file required:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -EngineAction {
    param($Context)

    $raw = Invoke-MyPlatformResource -Type "$($Context.ModuleName)/$($Context.Name)" `
                                     -Verb $Context.Method `
                                     -Body $Context.Property

    [pscustomobject]@{
        InDesiredState = [bool]$raw.converged
        RebootRequired = $false
        Message        = $raw.detail
        Raw            = $raw
    }
}
```

An inline `-EngineAction` takes precedence over `-Engine` and bypasses selection entirely.

Alternatively, drop `Actions/Engine/MyEngine.ps1` into the module and select it by name:

```yaml
PipelineRunnerSettings:
  Engine: MyEngine
```

## Choosing between them

- **Windows, existing PSDesiredStateConfiguration resource modules** ⇒ `DscV2`. It is the
  default for a reason: credentials marshal natively, remoting is CIM, and resource schemas are
  inspectable by the pre-parse property rule.
- **Linux or macOS agents, or DSC v3 resources** ⇒ `DscV3`. Note that SSH targets *require* it —
  there is no CIM-over-SSH transport for `Invoke-DscResource`.
- **Migrating** ⇒ the two engines need different `type` spellings, so a configuration cannot
  straddle both. Move a whole configuration at a time.
