# Configuration Repository Layout

A configuration is a [Datum](https://github.com/gaelcolas/Datum) repository: a tree of YAML
files plus a `Datum.yml` that says how a value is resolved when more than one file supplies it.
The runner compiles that tree into one flat YAML file per node, then executes each compiled
file independently.

## The three-layer shape

```
config/
├── Datum.yml                       # resolution precedence, lookup options, PipelineRunnerSettings
├── Policy.yml                      # optional: capability policy (preview). Its own file, never merged
├── Composites/                     # optional: composite resource definitions (not in ResolutionPrecedence)
│   └── StandardProject.yml
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

`Policy.yml` is optional. It sits beside `Datum.yml` but is not part of the hierarchy: Datum builds
its tree from the sub-folders, so a root file is never merged. See [Capability policy](Capability-Policy).

That is the shape of the repository's own `Example Configuration/` directory, and it is the
shape the rest of this wiki's examples assume. The `Composites/` folder is optional and is
**not** part of `ResolutionPrecedence`. It holds reusable groups of resources, which are
documented on [Composite Resources](Composite-Resources).

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
  ConfigurationVersion: 0.6
  PipelineRunnerVersion: 1.2.0
  Engine: DscV2
  AllowExecutionScripts: true
  Reboot: Fail
  Target: Local

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

### Reusing a group of resources

A resource with `type: Composite/<Name>` is an instance of a composite resource. It is defined
once in `Composites/<Name>.yml` and expanded into its member resources when the configuration is
compiled:

```yaml
resources:

  - name: Magenta
    type: Composite/StandardProject
    properties:
      ProjectName: Magenta
```

An instance merges and overrides by `name` like any other resource. See
[Composite Resources](Composite-Resources).

## What compilation produces

`Build-DatumConfiguration` writes one `*.yml` per node into the cache directory. That file is
flat: precedence has been applied, `[x={ }=]` handlers have run, composite resource instances
have been expanded into their members, and there is no `PipelineRunnerSettings` block left. `Invoke-DscRunner` then enumerates those files and calls
the runner once per file.

```powershell
Build-DatumConfiguration -OutputPath .\cache -ConfigurationPath 'C:\config' -AllowedRoot .\cache
Get-ChildItem .\cache -Filter *.yml
```

Inspect the compiled output whenever a value is not what you expected — it is the exact input
the runner sees.

## Running a configuration you compiled yourself

A caller that builds its per-node documents somewhere else does not have to write a Datum
repository to get at the runner. `-ConfigurationFile` names one or more documents, and
`-ConfigurationDirectory` a directory of them; either skips the compile and runs the documents
as they are. Both are mutually exclusive with the `Source` parameters.

```powershell
Invoke-DscRunner -ConfigurationFile .\out\SRV-APP-01.yml -BypassDatumPolicy -Mode Test
Invoke-DscRunner -ConfigurationDirectory .\out -BypassDatumPolicy -RunnerSettings @{ Engine = 'DscV3' } -Mode Set
```

`-BypassDatumPolicy` is required, and is explained under the capability policy below.

A document must be what the compile would have produced: flat, composites already expanded
(an unexpanded `Composite/` instance is refused), and `.yml`, `.yaml` or `.json`. Everything in
["How a run executes"](Execution-Lifecycle) is unchanged — the pre-parse
[Pipeline Rules](Pipeline-Rules), conditions, `dependsOn`/`notify` ordering, lifecycle scripts,
`reference()`/`using()`, the report and the exit code. Three things follow from not having a
hierarchy:

- **The node name is the document's file name**, without its extension — the same rule the
  compiled path uses, since the compile names each file after its node. It is what `nodeName()`
  returns, what each result row records and what the report files are named after, so two
  documents in one run may not share a file name. When the file is not named after its node,
  `-NodeName` says what the node is:

  ```powershell
  Invoke-DscRunner -ConfigurationFile .\tmp\rendered.yml -NodeName SRV-APP-01
  ```

  A node name belongs to one node, so `-NodeName` cannot be combined with
  `-ConfigurationDirectory` or with several `-ConfigurationFile` paths — name those files after
  their nodes instead. It is written into the report file names, so it is validated as a plain
  file name by the same rule the compile applies to a Datum node name: a path separator, a
  wildcard, `..` or a leading dot is refused before anything runs.
- **`PipelineRunnerSettings` come from `-RunnerSettings`**, a hashtable of the same keys
  [Datum.yml would carry](PipelineRunnerSettings). There is no `Datum.yml` to read them from, and
  they are deliberately *not* read out of the document: whether a configuration may run
  unconstrained lifecycle scripts (`AllowExecutionScripts`) is a decision for whoever starts the
  run, and a document that could grant it to itself would not be a decision at all. Omit the
  parameter and the runner's defaults apply.

  A `PipelineRunnerSettings` block left in a document is therefore **inert**, and the runner says
  so: one warning per document naming the file, because silence would let someone believe those
  settings took effect. It is not an error — the document is otherwise valid.
- **The [capability policy](Capability-Policy) does not apply, and that has to be declared.** A
  policy says what each *layer* of a configuration may use, and a layer is decided by where a
  file sits in the hierarchy; a passthrough document has no layers, so no policy can be enforced
  over it. That would make choosing passthrough a quiet way out of the policy, so the runner will
  not infer it from the absence of layers — `-BypassDatumPolicy` is **required** for a
  passthrough run. A run that takes it warns that the policy is bypassed and records
  `PolicyBypassed` on every node's result and report document, so the step is visible afterwards
  and not only in the console. `-PolicyPath` and `-RequirePolicy` remain refused: there is no
  layer for them to decide a capability from.

  The switch grants no exception. Precedence:

  | Behind the documents | Without `-BypassDatumPolicy` | With it |
  |---|---|---|
  | A `Datum.yml` **and** a `Policy.yml` | Refused | **Refused** — run it through the Datum path |
  | No policy | Refused, naming the switch | Runs, warns, records the bypass |

  **Where the runner looks.** The two files sit at the configuration *root* while a node file sits
  two levels below it, so looking only beside the document would miss the case worth catching.
  For each document the runner walks from the document's own directory upward through its parents
  — the way `git` finds a `.git` — and takes the first directory holding a `Datum.yml` as the
  configuration behind it. A policy counts only when it sits *beside* that file, which is the only
  place a policy is ever read from; a `Policy.yml` in a sub-folder is a file a constrained layer
  could have written. One governed document refuses the whole run.

  **What that cannot do.** It recognises a configuration by its `Datum.yml`. It cannot tell that a
  document was *copied out* of a governed repository and left somewhere else — nothing in a flat
  document records where it came from, which is the whole reason a policy cannot apply to it. So
  the check closes the "pointed passthrough at the repository" case, and the switch remains a
  declaration by the caller rather than a proof. A `Policy.yml` with no `Datum.yml` above the
  documents is the ambiguous case: it governs nothing the runner can resolve layers for, so it
  draws a warning rather than a refusal.

  `-BypassDatumPolicy` is refused on the Datum path, where every resource has a layer and the
  policy applies, so it can never be a way to switch enforcement off for a configuration that
  has one.

A passthrough document is code in exactly the same sense a compiled one is — see the
[trust model](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/trust-model.md).
Supplying it directly removes the compile, not the trust requirement.

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
