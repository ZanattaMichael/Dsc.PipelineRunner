# Configuration Repository Layout

A configuration is a [Datum](https://github.com/gaelcolas/Datum) repository: a tree of YAML
files plus a `Datum.yml` that says how a value is resolved when more than one file supplies it.
The runner compiles that tree into one flat YAML file per node, then executes each compiled
file independently.

## The three-layer shape

```
config/
├── Datum.yml                       # resolution precedence, lookup options, PipelineRunnerSettings
├── Projects/
│   ├── Present/
│   │   └── Magenta.yml             # node-specific: the most specific layer
│   └── Absent/
│       └── Blue.yml
├── ProjectPolicies/
│   ├── Project.yml                 # role/policy layer
│   ├── ProjectGroups.yml
│   └── ProjectGitRepositories.yml
└── OrganizationPolicies/
    ├── Organization.yml            # baseline layer: applies to everything
    └── OrganizationGroups.yml
```

That is the shape of the repository's own `Example Configuration/` directory, and it is the
shape the rest of this wiki's examples assume.

## `Datum.yml`

```yaml
# Lower entries in ResolutionPrecedence lose to higher entries.
ResolutionPrecedence:
  - Projects\$($Node.ProjectPresence)\$($Node.Project)
  - ProjectPolicies\ProjectGitRepositories
  - ProjectPolicies\ProjectGroups
  - ProjectPolicies\Project
  - OrganizationPolicies\OrganizationGroups
  - OrganizationPolicies\Organization

DatumHandlersThrowOnError: true
default_lookup_options: MostSpecific

PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  DSCResourceVersion: 2.0
  AllowExecutionScripts: true

DatumHandlers:
  Datum.InvokeCommand::InvokeCommand:
    SkipDuringLoad: true

lookup_options:

  variables:
    merge_hash_array: deep

  resources:
    merge_hash_array: UniqueKeyValTuples
    merge_options:
      tuple_keys:
        - name
```

Two lookup options carry most of the weight:

- **`variables: merge_hash_array: deep`** — variables from every layer are merged, so a
  baseline can set a default and a node can override one key without restating the rest.
- **`resources: merge_hash_array: UniqueKeyValTuples` keyed on `name`** — resource lists from
  every layer are concatenated, and two entries with the same `name` merge into one instead of
  producing a duplicate. This is what lets a policy layer declare a resource and a node layer
  adjust one of its properties.

`PipelineRunnerSettings` is documented in full on [PipelineRunnerSettings](PipelineRunnerSettings).
It is read **before** compilation, because a compiled per-node file does not carry it.

## The three top-level keys in a layer file

Every YAML file that contributes to a node has the same shape:

```yaml
parameters: {}     # run-scoped inputs, read with parameters('Name'); missing name throws
variables: {}      # resolved values, read with variables('Name')
resources: []      # the ordered list of things to evaluate
```

`parameters` and `variables` are dictionaries. `resources` is a list; each entry is documented
on [Resource Properties](Resource-Properties).

### A baseline layer

`OrganizationPolicies/Organization.yml`:

```yaml
parameters: {}

variables:
  OrganizationName: Contoso
  Project_Service_GitRepositories: enabled

resources: []
```

### A policy layer

`ProjectPolicies/Project.yml`:

```yaml
parameters: {}

variables:
  ProjectName: '[x={ $Node.Project }=]'
  Project_Ensure: '[x={ $Node.ProjectPresence }=]'

resources:

  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      projectName: $(variables('ProjectName'))
      visibility: private
      SourceControlType: Git
      ProcessTemplate: Agile
      Ensure: $(variables('Project_Ensure'))
```

`[x={ ... }=]` is Datum's own `InvokeCommand` handler — it runs at **compile** time and puts a
literal value into the compiled file. `$(...)` is the runner's own expansion and runs at
**execution** time. They are two different stages; see [Function Language](Function-Language).

### A node layer

`Projects/Present/Magenta.yml`:

```yaml
parameters: {}

variables:
  ProjectDescription: The Magenta project.

resources:

  - name: Project
    properties:
      visibility: public
```

Because `resources` merges on `name`, this does not declare a second `Project` resource — it
overrides `visibility` on the one the policy layer already declared.

## What compilation produces

`Build-DatumConfiguration` writes one `*.yml` per node into the cache directory. That file is
flat: precedence has been applied, `[x={ }=]` handlers have run, and there is no
`PipelineRunnerSettings` block left. `Invoke-DscRunner` then enumerates those files and calls
the runner once per file.

```powershell
Build-DatumConfiguration -OutputPath .\cache -ConfigurationPath 'C:\config' -AllowedRoot .\cache
Get-ChildItem .\cache -Filter *.yml
```

Inspect the compiled output whenever a value is not what you expected — it is the exact input
the runner sees.

## One file is one scope

The compiled file is the unit of execution and the unit of scope:

- `dependsOn` and `notify` may only name resources **in the same compiled file**.
- `using()` may only read a resource in the same compiled file.
- `Stop-TaskProcessing` / `stopProcessing()` skip the rest of **this** file, not the run.

A relationship that needs to cross node boundaries is not expressible today. See
[notify and using()](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/notify-and-using.md)
for why the boundary exists and what widening it would require.

## Validating the layout

`Build-DatumConfiguration` calls `Test-DatumConfiguration` on the Datum structure it builds,
and `Resolve-DscDatumProject` once per node, so a compile is itself the validation pass:

```powershell
New-Item -ItemType Directory -Path .\cache -Force | Out-Null
Build-DatumConfiguration -OutputPath .\cache -ConfigurationPath 'C:\config' -AllowedRoot .\cache -Verbose
```

`Test-DatumConfiguration` throws when `Datum.yml` has no `PipelineRunnerSettings` block, and
checks the declared versions against the module's own. Compiling in CI against the
configuration repository makes a version drift fail there rather than mid-deployment.

`OutputPath` must already exist and must sit inside `AllowedRoot` (the system temp directory
when `-AllowedRoot` is omitted) — a path-traversal guard, so an ad-hoc call cannot be steered
into writing outside a trusted scratch root.
