# Capability policy (preview)

> **Status: preview.** This is the design for the layered capability policy of
> [issue #86](https://github.com/ZanattaMichael/Dsc.PipelineRunner/issues/86) (Part B), together
> with a working prototype. The file format and behaviour may change before it is declared stable.
> Read [What it does not protect against](#what-it-does-not-protect-against) before relying on it.

A capability policy lets the owner of a pipeline say **what each layer of a configuration is
allowed to use**. Several teams can then contribute configuration to one repository without each of
them being trusted with everything the runner can do.

Without a policy nothing changes: the configuration repository is fully trusted, as described in
the [trust model](trust-model.md).

## The idea in one example

A platform team owns the baseline and the composites. Application teams own their own node files.
The platform team may use any Target and engine. Application teams may only use `Local` and
`WinRM`, the two built-in engines, no execution scripts and no Datum script blocks.

`Policy.yml`, at the root of the configuration, **beside `Datum.yml`**:

```yaml
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'OrganizationPolicies/**', 'ProjectPolicies/**', 'Composites/**' ]
    Capabilities:
      Targets: [ '*' ]
      Engines: [ '*' ]
      ExecutionScripts: true
      DatumScriptBlocks: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local, WinRM ]
      Engines: [ DscV2, DscV3 ]
```

```
config/
├── Datum.yml        the hierarchy
├── Policy.yml       the capability policy: its own file, never merged
├── OrganizationPolicies/ …
└── Projects/ …
```

```powershell
Invoke-DscRunner -ConfigurationSourcePath ./config -Mode Test
```

Nothing has to be passed: when `Policy.yml` is there, it applies. A complete, tested example is in
[`Example Policy Configuration`](../Example%20Policy%20Configuration).

What then happens:

| A team's node file ... | Result |
| --- | --- |
| declares a resource with `target: { action: SSH }` | The file does not start. The violation names the resource and the layer. |
| changes a property of a platform resource that uses SSH | The same: a resource a team touched runs with the team's permissions. |
| adds a `postExecutionScript` | The file does not start. |
| contains a Datum script block `[x={ ... }=]` | Nothing is compiled at all. |
| declares a resource on `WinRM` | Runs. |

and a platform resource that no team touched keeps using SSH.

## Where the policy lives

The policy is **a file of its own, `Policy.yml`, at the same level as `Datum.yml`**. It is not a
block inside `Datum.yml`, and it is **never merged**:

- Datum builds its tree from the configuration root's **sub-folders**. A file at the root is not
  in the tree, so it is not in `ResolutionPrecedence`, no layer can contribute to it, and no layer
  can override it. There is exactly one policy and it says what it says.
- A `Datum.yml` that declares a store for the policy file (which would pull it into the merge) is
  refused.
- A `Policy.yml` in a sub-folder is not the policy. It is not discovered, and naming it explicitly
  is refused, because sub-folders are the layers the policy constrains.

| How the policy is chosen | |
| --- | --- |
| `Policy.yml` (or `Policy.yaml`) beside `Datum.yml` | Used automatically. |
| `-PolicyPath <file>` | Wins over the file in the configuration. For a pipeline that imposes its own policy, kept anywhere outside the configuration's sub-folders. |
| `-RequirePolicy` | Fails the run when neither exists, so removing `Policy.yml` cannot quietly switch enforcement off. |
| None of these | No policy: the runner behaves as it always has. |

**Protect `Policy.yml` like `Datum.yml`.** Whoever can change it decides what every layer may do.
Give both files to the top layer with CODEOWNERS and branch protection. A pipeline that does not
want to depend on that uses `-PolicyPath` with a file from somewhere the contributors cannot
write, or at least `-RequirePolicy`.

## The policy file

| Key | Meaning |
| --- | --- |
| `PolicyVersion` | Must be `1`. |
| `Default` | `Deny` or `Allow`: what a layer may do with a capability it **does not list**. `Deny` is recommended. |
| `Layers` | An ordered list. The **first** layer whose `Paths` match a file owns that file. |
| `Layers[].Name` | A label used in messages and in the provenance record. |
| `Layers[].Paths` | Wildcard patterns on a file's path relative to the configuration root: forward slashes, **no file extension**, not case-sensitive. `*` and `**` both match across folders. The definition file is written `Datum.yml`. |
| `Layers[].Capabilities` | What the layer may use; see below. |

### Capabilities in the preview

| Capability | Value | Governs |
| --- | --- | --- |
| `Targets` | list of names, wildcards allowed | The Target action a resource runs through (`Local`, `WinRM`, `SSH`, ...), including the file's default. An empty list allows none. |
| `Engines` | list of names, wildcards allowed | The engine that runs the file. An inline engine script block is its own name, `(inline engine script block)`, so only `'*'` allows it. |
| `ExecutionScripts` | `true` / `false` | `preExecutionScript` and `postExecutionScript` on a resource. This is in addition to `AllowExecutionScripts`: both must allow it. |
| `DatumScriptBlocks` | `true` / `false` | `[x={ ... }=]` blocks, which Datum evaluates as PowerShell during the merge. |

The file is read strictly. An unknown key, a wrong type or a missing field is an error. A policy
that was silently misread would be worse than none.

### A file no layer claims

It belongs to the layer `(unclaimed)`, which has **no capabilities at all**, whatever `Default`
says. Adding a new top-level folder to the configuration therefore needs a policy change before
anything in it can run. That is deliberate.

## How it works

### 1. Provenance is stamped by the runner, from file paths

A layer is decided by **where a file is** in the repository, never by anything written inside the
file. A contributor can choose what to write in their own files; they cannot choose the path of
somebody else's. Repository controls (CODEOWNERS, branch protection per folder) are what tie a path
to a team, and the policy's `Paths` mirror them.

Datum merges a node's layers into one result and does not report which layer each part came from.
The runner finds out by asking Datum for **each layer on its own**: `Resolve-Datum` is called once
per entry of `ResolutionPrecedence`, restricted to that entry. A layer is a contributor to a
resource when its own result contains a resource of that name.

*This answers the first open question of the issue:* Datum does not expose provenance during the
merge, but the runner does not have to parse the layer files itself either. Datum's own
per-path lookup is enough, so the stamp reflects exactly what Datum merged.

The result is written beside each compiled file as `<node>.provenance.json`:

```json
{
  "SchemaVersion": "1.0",
  "PolicySha256": "…",
  "Node": "Magenta",
  "SettingsLayer": "Platform",
  "Layers": [
    { "Path": "Projects/Present/Magenta", "Layer": "Teams" },
    { "Path": "OrganizationPolicies/Organization", "Layer": "Platform" }
  ],
  "ContributingLayers": [ "Teams", "Platform" ],
  "Resources": {
    "Module/Resource/Platform only": [ "Platform" ],
    "Module/Resource/Shared": [ "Platform", "Teams" ]
  }
}
```

A stamp a contributor writes into a source file (`layer: Platform`) is just an unknown key. It is
never read.

### 2. Least privilege

Something several layers contributed to is allowed only if **every one of them** is allowed it.
So a resource the platform declares and a team redeclares runs with the team's permissions.

With the usual merge rule for `resources` (`UniqueKeyValTuples` on `name`), the more specific
layer's item **replaces** the other one whole; it is not merged key by key. A team that wants to
change one property of a platform resource therefore has to restate the resource, and what runs is
the team's version, held to the team's permissions. It cannot keep the platform's `target`.

One engine runs a whole file, so the engine must be allowed for every layer that has a resource in
that file.

### 3. Where it is enforced

| When | What | On a violation |
| --- | --- | --- |
| Before the compile, on the raw files | Datum script blocks, per file | Nothing is compiled or run; every offending file is named. |
| Before the first resource of a file | Engine; each resource's Target (or the file's default); execution scripts | The file does not start; every violation is named in one pass. |
| When a resource is reached | The Target that is really about to be used | That resource fails without the target being contacted; the run continues. |

A dry run (`-Mode DryRun`) performs the same checks, so a pull-request pipeline can report policy
violations before the change is merged.

**Targets written as expressions.** `target: { action: $(variables('Hop')) }` has no value until
the resource is reached. It is checked then, against every layer that contributed **anything** to
the node, because the value may have come from any of them. Otherwise a team could steer a
platform resource onto a Target the team may not use by setting a variable.

### 4. It fails closed

- No provenance record, an unreadable one, or one written under a different policy: the file does
  not start.
- A resource in the compiled file that is not in the record has no capabilities.
- A policy file in a sub-folder of the configuration is refused.
- With `-RequirePolicy`, a configuration without a policy does not run.

## Composites

The design (from the issue) is that a composite carries two identities: its **definition** belongs
to the layer that wrote it, an **instance** to the layer that inserted it. Members would run with
the definition's permissions, while the parameters the instantiating team passes are checked
against that team's permissions. That lets a platform team hand out building blocks that do more
than the instantiating team could do directly.

**The preview does not implement that yet.** A composite member (named `<instance>::<member>` in
the compiled file) is attributed to the layers that declared its instance *and* to every layer
that owns a composite definition. That can only narrow what a member may do, so it is safe, but a
platform composite instantiated by a team currently gets the team's permissions. Implementing the
two identities needs the expansion step to record, per member, which definition it came from and
which values were substituted from the instance's parameters.

## What it does not protect against

Be clear about these before depending on the policy.

1. **The compile still runs in full language mode.** The `DatumScriptBlocks` check removes the
   documented way to run code during the merge, by refusing the `[x=` marker in the text of a
   layer's files. It is not a sandbox. Part A of the issue (Constrained Language Mode for the
   compile) is the real containment and is not implemented. Other Datum handlers configured in
   `Datum.yml` are not covered, which is one reason `Datum.yml` must belong to the most trusted
   layer.
2. **`Datum.yml` controls everything.** It sets the resolution precedence, the merge rules and the
   handlers. Whoever can edit it can reshape the merge. Give it to the top layer only.
3. **Resources are not constrained.** A layer allowed to declare resources can declare any
   resource type with any properties; a `Script`-style resource is arbitrary code. Restricting
   resource types and methods is designed (below) but not in the preview.
4. **Credentials, sources and Connect actions** are not governed yet.
5. **The policy is only as good as the repository controls behind it.** If a team can push to
   another team's folder, path-based provenance says nothing useful. The same goes for
   `Policy.yml` itself: it is in the configuration repository, so a contributor who can change it
   (or delete it) controls the policy. Protect it with CODEOWNERS, and use `-RequirePolicy` or an
   external `-PolicyPath` in the pipeline if that protection is not enough.
6. **The compiled directory is trusted.** The provenance record is written there. A caller-supplied
   `-CacheDirectory` that others can write to defeats it.

## Decisions on the issue's open questions

| Question | Decision |
| --- | --- |
| How is provenance stamped? | By the runner, per precedence entry, through Datum's own lookup. Verified against a real Datum compile by the integration suite. |
| Where does the policy live? | In its own file, `Policy.yml`, at the root of the configuration beside `Datum.yml` (maintainer direction), outside the Datum hierarchy. A pipeline may instead name a file with `-PolicyPath`, and may insist on one with `-RequirePolicy`. A policy in a sub-folder is refused. The path-to-layer mapping is part of the policy. |
| Merge semantics of the policy | There are none: the policy cannot be merged. It is one file that Datum never loads, so lower layers cannot contribute to it at all, which is stronger than "may only narrow". If per-team narrowing is wanted later, it is an intersection applied after this policy. |
| Enforcement points | Before compile (script blocks), before the first resource (everything knowable), and at the point of use (Target). |
| Default | No policy: today's behaviour. With a policy: `Default` is explicit and required, and unclaimed files are always denied. |
| Stamps in the compiled file | A separate `<node>.provenance.json`, not inside the compiled YAML, so the compiled file stays what it was and the record is clearly runner output. |
| Auditing | The record names the policy by SHA-256 and lists every resource's layers. Violations appear in the run's error or as failed resources. Putting decisions into the report document (#85) is a follow-up. |
| Relationship to CLM (Part A) | Complementary and not yet joined. A future `RequireConstrainedLanguage` policy key should make the compile refuse to run without it. |

## Follow-up work

- Composite definition and instance identities (above).
- More capabilities: resource types and methods (`Test`/`Get` only for a read-only team),
  Credential actions, Source and Connect, function-language accessors, `stopProcessing`, and which
  `PipelineRunnerSettings` keys a layer may set.
- Per-key provenance for the sensitive keys, so a policy can allow a team to change a property of a
  platform resource without taking over its Target.
- Policy decisions in the report document and the JUnit and summary reporters.
- Constrained Language Mode for the compile (Part A), and a policy key that requires it.
- Signing or pinning the policy (a pipeline-supplied SHA-256 the file must match), for
  configurations whose repository controls cannot be relied on.
