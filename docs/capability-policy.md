# Capability policy

> This is the layered capability policy of
> [issue #86](https://github.com/ZanattaMichael/Dsc.PipelineRunner/issues/86) (Part B). Read
> [What it does not protect against](#what-it-does-not-protect-against) before relying on it, and
> [Upgrading a policy written for v1.3.0](#upgrading-a-policy-written-for-v130)
> if you wrote one then: five capabilities have been added, and under `Default: Deny`
> they are denied until the policy grants them.

A capability policy lets the owner of a pipeline say **what each layer of a configuration is
allowed to use**. Several teams can then contribute configuration to one repository without each of
them being trusted with everything the runner can do.

Without a policy nothing changes: the configuration repository is fully trusted, as described in
the [trust model](trust-model.md).

## The idea in one example

A platform team owns the baseline and the composites. Application teams own their own node files.
The platform team may use anything. Application teams may use `Local` and `WinRM`, the two built-in
engines, the resources of one module, a credential out of the agent's environment and the machines
in their own subnet — and nothing else.

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
      Resources: [ '*' ]
      Credentials: [ '*' ]
      RemoteTargets: [ '*' ]
      ExecutionScripts: true
      DatumScriptBlocks: true
      Notify: true
      Reboot: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local, WinRM ]
      Engines: [ DscV2, DscV3 ]
      Resources: [ 'PSDscResources/*' ]
      Credentials: [ Environment ]
      RemoteTargets: [ '*.app.contoso.example' ]
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
| declares a resource with `target: { action: SSH }` | The file does not start. The violation names the resource, the layer and the files that layer owns. |
| changes a property of a platform resource that uses SSH | The same: a resource a team touched runs with the team's permissions. |
| adds a `postExecutionScript` | The file does not start. |
| contains a Datum script block `[x={ ... }=]` | Nothing is compiled at all. |
| declares a `PSDesiredStateConfiguration/Script` resource | The file does not start: that type is not in the layer's `Resources`. |
| aims a `WinRM` resource at a machine outside `*.app.contoso.example` | The file does not start. The mechanism was allowed; the destination was not. |
| asks for a credential from the platform's vault, or writes one into the configuration | The file does not start: `SecretManagement` and `Static` are not in the layer's `Credentials`. |
| `notify`s a platform resource, forcing it to re-apply | The file does not start. `dependsOn` is unaffected. |
| has a resource whose `Set()` asks for a reboot of a remote machine | That resource fails and the machine is **not** restarted. |
| declares a resource on `WinRM`, in its own subnet, with an `Environment` credential | Runs. |

and a platform resource that no team touched keeps using SSH, the vault and the bastion.

To see all of that before it bites:

```powershell
Get-DscCapabilityPolicyReport -ConfigurationPath ./config -AsText
```

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
| `Settings` | Optional. The `PipelineRunnerSettings` values `Datum.yml` may hold; see [Settings](#settings-what-datumyml-may-say). |

### Capabilities

| Capability | Value | Governs |
| --- | --- | --- |
| `Targets` | list of names, wildcards allowed | The Target action a resource runs through (`Local`, `WinRM`, `SSH`, ...), including the file's default. An empty list allows none. |
| `Engines` | list of names, wildcards allowed | The engine that runs the file. An inline engine script block is its own name, `(inline engine script block)`, so only `'*'` allows it. |
| `Resources` | list of `Module/Resource` patterns | What a resource may **be**. `'PSDscResources/*'` allows every resource of one module; `'*'` allows any. A pattern with no `/` is refused at load, because it would name no resource type and so allow nothing while reading as though it allowed a module. |
| `Credentials` | list of Credential action names | Every credential the resource resolves: `target.credential.action` and `resourceCredential.action` (a block with no `action` is `Environment`, which is what the runner uses). An empty list means the layer may use no credential at all. |
| `RemoteTargets` | list of computer-name patterns | `target.computerName`, for any Target other than `Local`. `Targets` says which mechanism a layer may use; this says where it may reach. A non-`Local` Target that names no computer is refused — there is nothing to allow, and the built-in Target actions refuse it too. |
| `ExecutionScripts` | `true` / `false` | `preExecutionScript` and `postExecutionScript` on a resource. This is in addition to `AllowExecutionScripts`: both must allow it. |
| `DatumScriptBlocks` | `true` / `false` | `[x={ ... }=]` blocks, which Datum evaluates as PowerShell during the merge. |
| `Notify` | `true` / `false` | `notify` on a resource. A notified resource runs `Set()` even though its own `Test()` reported it already in the desired state, so a layer that may notify can make another layer's resource apply itself. |
| `Reboot` | `true` / `false` | Restarting a remote target when a resource's `Set()` reports `RebootRequired`. It is the most disruptive thing the runner does and the only one it does on its own initiative. |

### Settings: what Datum.yml may say

`PipelineRunnerSettings` in `Datum.yml` set how the runner behaves for the whole configuration.
The optional `Settings` block lists the values each one may take. It is policy-wide, not per
layer, because `Datum.yml` is one file owned by one layer.

```yaml
Settings:
  AllowExecutionScripts: [ false ]
  Reboot: [ Fail ]
  Target: [ Local, WinRM ]   # wildcards allowed
  Engine: [ DscV2, DscV3 ]
```

| Key | Judged value |
| --- | --- |
| `AllowExecutionScripts` | As the runner reads it (a boolean). Default when unset: `false`. |
| `Reboot` | Default when unset: `Fail`. |
| `Target` | The file-level default Target. Default when unset: `Local`. |
| `Engine` | The engine `Datum.yml` selects (`Engine`, or `DSCResourceVersion`). Not judged when the pipeline chose it with `-Engine` or `-EngineAction`. |

- A value outside its list stops the run **before compile**, naming every refused key, its value,
  the layer that owns `Datum.yml` and the policy. `Get-DscCapabilityPolicyReport` reports the same
  as a `SettingsRefusal` finding.
- A key `Datum.yml` leaves out is judged by the runner's default, so a policy that does not allow
  the default makes that key mandatory.
- A key the policy does not list is not governed. Other keys (`ConfigurationVersion`,
  `PipelineRunnerVersion`, `Report`) are refused at load.
- The pipeline is not governed: its owner is the policy's owner. That includes a passthrough run's
  `-RunnerSettings`; a passthrough run below a governed configuration is refused anyway.

The file is read strictly. An unknown key, a wrong type or a missing field is an error. A policy
that was silently misread would be worse than none.

### What is deliberately not a capability

| Not governed | Why |
| --- | --- |
| `dependsOn` | It only orders resources that were going to run anyway. It cannot make another resource change state, which is what separates it from `notify`. |
| `Source`, `Connect` and `Report` actions | These come from the pipeline (`Invoke-DscRunner -Source`, `-Connect`, `-ReportAction`), not from the configuration. The pipeline's owner is the same person who owns the policy, so a policy clause about them would only constrain the author against themselves — and the `Source` action is what fetches the configuration the policy lives in. |
| Pipeline Rules | They ship with the module (`Pipeline Rules/`), not with the configuration, so no layer can add one. |
| Which layer may set `PipelineRunnerSettings` | They are set in `Datum.yml`, which is one file owned by one layer. The report says which layer that is. What values they may hold is governed, by [Settings](#settings-what-datumyml-may-say). |
| Resource **properties** | A policy that tried to constrain property values would be a schema, not a capability. `Resources` is the lever: a layer that may not declare a `Script` resource cannot smuggle code through a property. |

### Making the policy legible: `Get-DscCapabilityPolicyReport`

A policy is enforced against a *compiled* configuration, so the first time most people see one
work is when it stops a run. `Get-DscCapabilityPolicyReport` is the other way round. It reads the
policy and the configuration's files and reports:

- every layer with the **effective** rule for every capability — the ones the layer does not list
  resolved through `Default`, shown as `Deny (not listed; from Default)` rather than left blank;
- which layer owns each data file, and each entry of `Datum.yml`'s `ResolutionPrecedence`;
- every resource the files declare, with the layer(s) that declare it and whether the policy would
  allow what it asks for;
- **findings**, the ways a policy ends up quietly ineffective or quietly total:

| Finding | Severity | Meaning |
| --- | --- | --- |
| `LayerMatchesNothing` | Warning | A layer's `Paths` match no file. Almost always a typo, and a typo in `Paths` moves files into `(unclaimed)`, which may do nothing. |
| `UnclaimedFile` | Error | A file no layer claims. Nothing in it may do anything, whatever `Default` says. |
| `RemoteTargetWithoutComputer` | Warning | The layer may use a Target other than `Local`, but `RemoteTargets` allows it no computer, so every remote resource it declares is refused. |
| `LayerDeclaresNothing` | Warning | The layer owns files but `Resources` resolves to `Deny`, so every resource in them is refused. |
| `DefaultAllow` | Warning | With `Default: Allow` a capability a later version of the runner adds is allowed to every layer that has not been updated. |
| `DeclarationRefused` | Error | A declaration in the configuration that the policy would refuse. |
| `PreCompileRefusal` | Error | What the pre-compile check would refuse: a Datum script block in a layer without the capability, or a `Datum.yml` that would pull the policy into the merge. Produced by running the real check, so the report cannot drift from it. |
| `DefinitionFileOwner` | Information | Which layer owns `Datum.yml`. |
| `NoPolicy` | Information | The configuration has no policy at all. |

It compiles nothing, resolves no node and runs no resource, so it is safe in a pull request, in a
pre-commit hook or against a configuration that does not work yet. `-AsText` renders it for a
person; without it you get an object, and `$report.HasError` is what a pipeline gates on.

**It is advisory.** The report reads the layer files; it does not perform Datum's merge, so it does
not know the resolution precedence, the lookup options, conditions or composite expansion. A
resource it shows as allowed can still be refused at run time — most often because a second layer
also declares it and least privilege then applies both layers' permissions. The run is
authoritative. Treat a clean report as "nothing obviously wrong", not as "this will run".

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
| Before the compile | `PipelineRunnerSettings` against `Settings` | Nothing is compiled or run; every refused value is named. |
| Before the compile, on the raw files | Datum script blocks, per file; a `Datum.yml` that would pull the policy into the merge | Nothing is compiled or run; every offending file is named. Separately, a layer whose `Paths` match no file, and any file no layer claims, are warned about here. |
| Before the first resource of a file | Engine; each resource's type, Target (or the file's default), remote computer, Credential actions, execution scripts and `notify` | The file does not start; every violation is named in one pass, with the node, the policy, the layer and the files that layer owns. |
| When a resource is reached | The Target, the remote computer and the Credential actions that are really about to be used | That resource fails without the target being contacted or the credential resolved; the run continues. |
| After a `Set()` that asks for a reboot | Whether this resource's layers may have a remote target restarted | The resource fails and the machine is left running; the message says the `Set()` has already been applied. |

The last two are mostly defence in depth: the pre-run gate judged the same text in the same task
object. Two things only the point-of-use gate can catch:

- a **Target action written as an expression**, which is not a Target name the pre-run gate can
  judge (see below) — and therefore the computer beside it, which is then judged against every
  layer that contributed to the node rather than only the resource's own layers;
- a **reboot**, which nothing in the compiled file announces: the engine asks for one after
  `Set()` has already run.

A dry run (`-Mode DryRun`) performs the whole pre-run check, so a pull-request pipeline can report
policy violations before the change is merged, without an engine, a target or a credential being
touched.

**Expressions inside a `target` block.** The runner expands expressions in a resource's
*properties* only. Nothing inside `target` is expanded — not `action`, not `computerName`:
`target: { action: $(variables('Hop')) }` stays that literal text, which is not the name of any
Target. So a team cannot steer a platform resource onto another Target, or at another machine, by
setting a variable; the integration suite pins this. The policy still treats such a resource
defensively: an expression `action` is not judged before the run, and when the resource is reached
the text is checked against every layer that contributed **anything** to the node, so it is refused
unless all of them allow any Target. The computer name beside it is judged the same way, which is
how a machine the platform may reach but a team may not is refused on a resource whose Target was
only knowable at run time.

### 4. It fails closed

- No provenance record, an unreadable one, one written under a different policy, or one written
  for another node: the file does not start. The record is found beside the compiled file by name,
  so it must also say which node it is for; moving or renaming a compiled file cannot make another
  node's record stand in for it.
- A resource in the compiled file that is not in the record has no capabilities.
- A policy file in a sub-folder of the configuration is refused.
- With `-RequirePolicy`, a configuration without a policy does not run.
- A capability a layer does not list resolves through `Default`, so under `Default: Deny` a
  capability added to the runner in a later version is denied to every layer until the policy
  grants it. That is why `Default: Deny` is recommended and why `Default: Allow` is a reported
  finding.
- A list capability with nothing to match is denied, not allowed: an empty computer name is
  refused even against `RemoteTargets: [ '*' ]`.

### Upgrading a policy written for v1.3.0

The first release (v1.3.0) had four capabilities. A policy written then still loads, but under
`Default: Deny` the five that were added — `Resources`, `Credentials`, `RemoteTargets`, `Notify`
and `Reboot` — now resolve to `Deny` for every layer that does not list them. **A layer with no
`Resources` rule may declare no resource at all**, so a configuration that ran under v1.3.0
can stop running until its policy is updated. That is the fail-closed behaviour working as
intended, and it is the whole reason `Default` exists.

What to do: run `Get-DscCapabilityPolicyReport -ConfigurationPath <config> -AsText` and read the
`Layers` section. Every capability shown as `Deny (not listed; from Default)` is a decision the
policy has not made yet. Grant each layer what it genuinely needs — `Resources` at least — and
leave the rest denied. The `LayerDeclaresNothing` and `RemoteTargetWithoutComputer` findings name
the two combinations that otherwise look fine and refuse everything.

## Composites

The design (from the issue) is that a composite carries two identities: its **definition** belongs
to the layer that wrote it, an **instance** to the layer that inserted it. Members would run with
the definition's permissions, while the parameters the instantiating team passes are checked
against that team's permissions. That lets a platform team hand out building blocks that do more
than the instantiating team could do directly.

**The runner does not implement that yet.** A composite member (named `<instance>::<member>` in
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
3. **A resource's properties are not constrained.** `Resources` decides which resource *types* a
   layer may declare, which is the lever that matters: a layer that may not declare
   `PSDesiredStateConfiguration/Script` cannot run arbitrary code through the engine. But a layer
   allowed a resource type may pass it any properties, and some resource types are more powerful
   than they look. Choose the allowed list by what the module can do, not by what the team
   currently writes. Which *methods* a layer may use — a read-only team allowed `Test` and `Get`
   but not `Set` — is not implemented.
4. **`Source` and `Connect` actions are not governed**, by design: they come from the pipeline, not
   from the configuration (see [What is deliberately not a
   capability](#what-is-deliberately-not-a-capability)). Credentials *are* governed, by Credential
   action name: `Credentials` says which actions a layer may use, not which individual secrets.
   Two layers allowed `SecretManagement` can read each other's secrets out of the vault — that
   boundary belongs to the vault's own access control.
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
| Auditing | The record names the policy by SHA-256 and lists every resource's layers. Violations appear in the run's error or as failed resources, naming the node, the policy, the layer and the files that layer owns. `Get-DscCapabilityPolicyReport` describes a policy without running it. Putting decisions into the report document (#85) is a follow-up. |
| Which capabilities? | Everything the *configuration* decides: the Target, the engine, the resource type, the remote computer, the Credential action, execution scripts, Datum script blocks, `notify` and a reboot. Not what the *pipeline* decides (`Source`, `Connect`, `Report`, `-Engine`), and not the module's own Pipeline Rules: the pipeline's owner and the policy's owner are the same person. |
| Relationship to CLM (Part A) | Complementary and not yet joined. A future `RequireConstrainedLanguage` policy key should make the compile refuse to run without it. |

## Follow-up work

- Composite definition and instance identities (above). This is the largest remaining gap: a
  platform composite instantiated by a team is held to the team's permissions, so a composite
  cannot yet be used to hand out a capability the instantiating layer does not have.
- A `Methods` capability: `Test` and `Get` but not `Set`, for a layer that may describe state but
  not apply it.
- Per-key provenance for the sensitive keys, so a policy can allow a team to change a property of a
  platform resource without taking over its `target`, its credential or its scripts. Today the
  merge replaces the resource whole, so a team that wants one property restates all of it and the
  whole resource is held to the team's permissions.
- Function-language accessors and `stopProcessing`; governing `PipelineRunnerSettings.Report`.
- Policy decisions in the report document and the JUnit and summary reporters.
- Constrained Language Mode for the compile (Part A), and a policy key that requires it.
- Signing or pinning the policy (a pipeline-supplied SHA-256 the file must match), for
  configurations whose repository controls cannot be relied on.
