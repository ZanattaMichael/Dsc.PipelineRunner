# DSC v3 support

Dsc.PipelineRunner can drive Microsoft's [DSC v3](https://learn.microsoft.com/powershell/dsc/)
engine (`dsc` / `dsc.exe`), the cross-platform successor to the Windows-first
`Invoke-DscResource` (DSC v2) path. This page covers how to select the engine and — the part
that trips people up — how to make sure a compiled Datum configuration is actually something
`dsc.exe` will accept.

## Selecting the engine

The execution engine is a pluggable action (`Actions/Engine/<Engine>.ps1`):

| Engine  | Backing tool           | Platforms            |
| ------- | ---------------------- | -------------------- |
| `DscV2` | `Invoke-DscResource`   | Windows (PowerShell) |
| `DscV3` | `dsc` / `dsc.exe`      | Windows, Linux, macOS |

Pass `-Engine DscV3` (or `-Engine Auto` to detect a `dsc` on `PATH`). Bootstrap the executable
on a hosted agent with `scripts/Install-DscV3.ps1`.

## Compiled configuration vs. a DSC v3 configuration document

The runner's compiled Datum output is a **runner-specific** shape — a list of resources plus
pipeline-only keys the runner interprets itself:

```yaml
resources:
  - type: Microsoft.Windows/Registry     # namespace/name
    name: SetKey
    properties: { keyPath: '...', valueName: '...', valueData: { String: 'x' } }
    preCondition: "1 -eq 1"                # pipeline-only
    postExecutionScript: "..."           # pipeline-only
    dependsOn: [ ... ]                    # pipeline-only (runner orders execution)
parameters: { ... }                      # pipeline-only
variables:  { ... }                      # pipeline-only
conditions: { ... }                      # pipeline-only
```

Start-DscRunner consumes this one resource at a time: it sorts by `dependsOn`, evaluates
`preCondition`, resolves `properties` (parameter tokens first, then `variables` and calculated
properties), and calls the selected engine per resource.
The `DscV3` engine turns each resource into `dsc resource test|set|get --resource <type>
--file -`, with the resource's `properties` serialised as JSON on `dsc`'s standard input (not as
an `--input` argument, which would expose a resolved credential in the process table).

A **DSC v3 configuration document** — what `dsc config get|test|set` consumes — is a different,
schema-governed shape. It carries a top-level `$schema` and resources limited to `name`, `type`
and `properties`; it has no concept of the runner's `preCondition`, `postExecutionScript`,
`variables`, or the runner's `parameters`/`conditions`:

```yaml
$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json
resources:
  - name: SetKey
    type: Microsoft.Windows/Registry
    properties: { keyPath: '...', valueName: '...', valueData: { String: 'x' } }
```

## Making a compiled configuration DSC v3-compliant

Use **`ConvertTo-DscV3ConfigurationDocument`** to turn compiled resources into a document that
`dsc.exe` accepts. It:

- stamps the DSC v3 `$schema`,
- keeps only `name`, `type` and `properties`, dropping every pipeline-only key,
- validates that each resource has a non-empty `name` and a `type` shaped like a DSC v3
  identifier (`namespace/name`, e.g. `Microsoft.Windows/Registry`),
- optionally verifies each `type` actually exists on the box when you pass the set from
  `dsc resource list`,
- aggregates all problems and throws a single itemized error.

```powershell
# From an in-memory compiled configuration (properties already resolved):
$types = (dsc resource list --output-format json | ConvertFrom-Json).type
$doc   = ConvertTo-DscV3ConfigurationDocument -Resource $compiled.resources -AvailableResourceType $types

# Hand it to dsc.exe (write to a file and use --file; the config subcommands read a path):
$doc | ConvertTo-Json -Depth 32 | Set-Content ./config.dsc.json -Encoding utf8
dsc config get --file ./config.dsc.json
```

Two things the runner keeps as its own responsibility, by design:

- **Ordering.** `dependsOn` is not carried into the document — the runner has already ordered
  the resources (Sort-DependsOn). Pass them in the order you want them evaluated.
- **Resolution.** `properties` are emitted verbatim. Run the runner's own two-pass
  resolution — `Expand-HashTable -InputHashTable (Expand-Parameters -InputHashTable $properties)`
  — before converting if you want a fully-resolved document; parameter tokens first, then
  variables and calculated properties.

### Resource types must be DSC v3 types

The most common cause of a "compliant-looking but unusable" configuration is a resource `type`
that is a DSC **v2** module/resource pair (for example `PSDscResources/Service`) rather than a
DSC **v3** resource type. Both are `namespace/name` shaped, so a structural check cannot tell
them apart — only `dsc resource list` can. That is why `ConvertTo-DscV3ConfigurationDocument`
accepts `-AvailableResourceType`, and why the `DscV3` engine surfaces a clear error when a type
is not a DSC v3 identifier instead of leaving you with an opaque non-zero exit from `dsc.exe`.

## How many dsc processes a run starts

The engine runs one `dsc resource <verb>` process per engine call. For each resource the runner
calls `test`, and in `Set` mode `set` when the resource has drifted. It does not call `get`
afterwards: `test` reports `actualState` and `set` reports `afterState`, and the runner stores
that, in the shape `dsc resource get` returns (`{ actualState: ... }`), for `reference()`,
`using()` and the report. It still calls `get` when the resource has a `postExecutionScript`
(which may change the resource after the engine reported), when a `set` failed, and when the
output carries no state (a group or an adapter result, for example).

### Resource discovery

Every `dsc` call starts with resource discovery. dsc reads every directory on `PATH` for
manifests and runs every *discover extension* it finds. dsc 3.3 ships one,
`Microsoft.PowerShell/Discover`, which starts a second PowerShell to look through
`PSModulePath`. It runs on every call, including a call to a native resource such as
`Microsoft.Windows/Registry` that PowerShell has nothing to do with. On a hosted Windows agent
that costs seconds per call. A single-resource apply used to spend more than 20 seconds of its
time in it.

So the engine runs the full discovery once per resource type and run (`dsc resource list
<type>`). When the type is a plain command resource, it copies that one manifest into a
directory of its own. Every later call for the type then runs with `DSC_RESOURCE_PATH` set to
that directory, and the resource's own directory first on `PATH` so its executable is still
found. dsc then discovers one manifest and starts nothing else.

A type keeps full discovery on every call when it is:

- an adapted resource (`requireAdapter` is set, such as a PowerShell class resource behind
  `Microsoft.DSC/PowerShell`), an adapter or a group;
- a resource whose manifest names a script beside it, which dsc runs from the manifest's own
  directory;
- a type `dsc resource list` lists more than once, or cannot list.

It also keeps full discovery when a call to a remote target is made (the target has its own
dsc), and when you set `DSC_RESOURCE_PATH` yourself. If dsc reports `Resource not found` or a
missing executable for a narrowed call, the type goes back to full discovery for the rest of
the run and the call is made again. Both are reported before the resource runs, so a `set` is
never repeated.

Set `PIPELINERUNNER_DSC_FULL_DISCOVERY=1` to turn the narrowing off.

## CI proof

`scripts/Test-DscV3ConfigDocument.ps1` (run by the **DSC v3 engine on Ubuntu** job) builds a
document with `ConvertTo-DscV3ConfigurationDocument` from a compiled-style resource list and
feeds it to a real `dsc config get`. A non-zero exit fails the build, so DSC v3 compliance is
verified against the actual engine on every push and pull request.

## Configuration functions (planned)

DSC v3 configuration documents have their own native function language
(`[functionName(arg1, arg2)]` — `envvar()`, `resourceId()`, `concat()`, its own document-scoped
`parameters()`/`variables()`, and more), separate from the runner's own `$(parameters(...))`
function surface described in `Assert-SafeConditionExpression.ps1` and
`source/Private/Runner/*.ps1`. Handling that syntax, and the whole-document
(`dsc config get|test|set`) apply path it requires, is not yet implemented — see
[`docs/dsc-v3-config-functions.md`](./dsc-v3-config-functions.md) for the design plan and the
research into whether a combined multi-resource configuration can be applied as a unit under
DSC v2 (it cannot, by this project's "no LCM" design) versus DSC v3 (`dsc config`, additive to
today's per-resource engine).
