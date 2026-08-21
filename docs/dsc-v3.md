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
    condition: "1 -eq 1"                  # pipeline-only
    postExecutionScript: "..."           # pipeline-only
    dependsOn: [ ... ]                    # pipeline-only (runner orders execution)
parameters: { ... }                      # pipeline-only
variables:  { ... }                      # pipeline-only
conditions: { ... }                      # pipeline-only
```

Start-DscRunner consumes this one resource at a time: it sorts by `dependsOn`, evaluates
`condition`, expands `variables` into `properties`, and calls the selected engine per resource.
The `DscV3` engine turns each resource into `dsc resource test|set|get --resource <type>
--input <json>`.

A **DSC v3 configuration document** — what `dsc config get|test|set` consumes — is a different,
schema-governed shape. It carries a top-level `$schema` and resources limited to `name`, `type`
and `properties`; it has no concept of the runner's `condition`, `postExecutionScript`,
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

# Hand it to dsc.exe:
$doc | ConvertTo-Json -Depth 32 | dsc config get
```

Two things the runner keeps as its own responsibility, by design:

- **Ordering.** `dependsOn` is not carried into the document — the runner has already ordered
  the resources (Sort-DependsOn). Pass them in the order you want them evaluated.
- **Resolution.** `properties` are emitted verbatim. Expand any runner variables
  (`Expand-HashTable`) before converting if you want a fully-resolved document.

### Resource types must be DSC v3 types

The most common cause of a "compliant-looking but unusable" configuration is a resource `type`
that is a DSC **v2** module/resource pair (for example `PSDscResources/Service`) rather than a
DSC **v3** resource type. Both are `namespace/name` shaped, so a structural check cannot tell
them apart — only `dsc resource list` can. That is why `ConvertTo-DscV3ConfigurationDocument`
accepts `-AvailableResourceType`, and why the `DscV3` engine surfaces a clear error when a type
is not a DSC v3 identifier instead of leaving you with an opaque non-zero exit from `dsc.exe`.

## CI proof

`scripts/Test-DscV3ConfigDocument.ps1` (run by the **DSC v3 engine on Ubuntu** job) builds a
document with `ConvertTo-DscV3ConfigurationDocument` from a compiled-style resource list and
feeds it to a real `dsc config get`. A non-zero exit fails the build, so DSC v3 compliance is
verified against the actual engine on every push and pull request.
