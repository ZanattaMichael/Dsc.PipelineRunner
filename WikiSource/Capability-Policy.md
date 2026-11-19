# Capability Policy

A capability policy says **what each layer of a configuration is allowed to use**, so several
teams can contribute to one configuration without each of them being trusted with everything the
runner can do.

Without a policy nothing changes.

## Version requirements

The capability policy needs:

- `Dsc.PipelineRunner` **1.3.0 or later** (the `Settings` block: **1.5.1 or later**). An older
  module does not look for `Policy.yml`, so the policy is **silently ignored**.
- `PipelineRunnerSettings` in `Datum.yml` at **`ConfigurationVersion: 0.6`** and
  **`PipelineRunnerVersion: 1.2.0`** or later. Older values (for example `0.5` / `1.1.0`) still
  run, and the policy is still enforced, but the run warns and names the fix.

`Policy.yml` stays optional: a configuration without one is not affected. To upgrade, see
[Upgrading](PipelineRunnerSettings#upgrading).

## Set one up

Put a file called `Policy.yml` at the root of the configuration, **beside `Datum.yml`**:

```
config/
├── Datum.yml
├── Policy.yml        ← here
├── Platform/
└── Projects/
```

```yaml
PolicyVersion: 1
Default: Deny
Layers:
  - Name: Platform
    Paths: [ 'Datum.yml', 'Platform/**', 'Composites/**' ]
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

List every capability for your most trusted layer, even the ones you would grant anyway. A
capability a layer does not list follows `Default`, so with `Default: Deny` a capability added in a
later version of the runner is denied until you grant it — which is the behaviour you want for a
team's layer and usually not for the platform's.

Then run as usual. The policy is picked up because it is there:

```powershell
Invoke-DscRunner -ConfigurationSourcePath ./config -Mode DryRun
```

`Policy.yml` is a file of its own. It is not a block in `Datum.yml`, it is not in
`ResolutionPrecedence`, and Datum never loads it, so **it cannot be merged**: no layer can add to
it or override it.

A complete example you can copy is in the repository under
[`Example Policy Configuration`](https://github.com/ZanattaMichael/Dsc.PipelineRunner/tree/main/Example%20Policy%20Configuration).

## The file

| Key | Meaning |
| --- | --- |
| `PolicyVersion` | `1`. |
| `Default` | `Deny` or `Allow`: what a layer may do with a capability it does not list. Use `Deny`. |
| `Layers` | Ordered. The first layer whose `Paths` match a file owns it. |
| `Name` | A label for messages. |
| `Paths` | Patterns on a file's path from the configuration root: forward slashes, no file extension, not case-sensitive. `*` and `**` match across folders. Write the definition file as `Datum.yml`. |
| `Capabilities` | See the next table. |
| `Settings` | Optional. The `PipelineRunnerSettings` values `Datum.yml` may hold; see [Settings](#settings). |

| Capability | Value | Governs |
| --- | --- | --- |
| `Targets` | list, wildcards allowed | The [Target action](Remote-Targets-and-Credentials) a resource runs through, including the file's default. |
| `Engines` | list, wildcards allowed | The [engine](Engines) that runs the file. |
| `Resources` | list of `Module/Resource` patterns | What a resource may **be**: `'PSDscResources/*'`, `'*'`. A pattern with no `/` is refused, because it would name no [resource type](Resource-Properties) and so allow nothing. |
| `Credentials` | list of Credential action names | Every credential a resource resolves: `target.credential` and [`resourceCredential`](Remote-Targets-and-Credentials). A block with no `action` counts as `Environment`. An empty list means no credentials at all. |
| `RemoteTargets` | list of computer-name patterns | `target.computerName`, for any Target other than `Local`. `Targets` is the mechanism; this is the destination. A non-`Local` Target naming no computer is refused. |
| `ExecutionScripts` | `true` / `false` | `preExecutionScript` and `postExecutionScript`. `AllowExecutionScripts` must also be on. |
| `DatumScriptBlocks` | `true` / `false` | `[x={ ... }=]` blocks evaluated during the Datum merge. |
| `Notify` | `true` / `false` | [`notify`](Resource-Properties), which makes another resource run `Set()` even when its own `Test()` said it was already in the desired state. `dependsOn` is **not** restricted: it only orders resources that were going to run anyway. |
| `Reboot` | `true` / `false` | Restarting a remote target after a `Set()` reports `RebootRequired`. Without it the resource fails and the machine is left running. |

A file that no layer claims may do nothing at all, whatever `Default` says.

### Settings

Limits what [`PipelineRunnerSettings`](PipelineRunnerSettings) in `Datum.yml` may say. Policy-wide,
because `Datum.yml` has one owner.

```yaml
Settings:
  AllowExecutionScripts: [ false ]
  Reboot: [ Fail ]
  Target: [ Local, WinRM ]
  Engine: [ DscV2, DscV3 ]
```

A value outside its list stops the run before compile. A key `Datum.yml` leaves out is judged by
the runner's default (`false`, `Fail`, `Local`). `Engine` is judged only when `Datum.yml` chose
it, not when the pipeline passed `-Engine`. An unlisted key is not governed.

Three things are deliberately outside a policy, because they come from the pipeline or the module
rather than from the configuration: the [`Source` and `Connect` actions](Execution-Lifecycle) and
the reporters (`Invoke-DscRunner -Source`, `-Connect`, `-ReportAction`), and the module's own
[Pipeline Rules](Pipeline-Rules). The person who writes the policy is the person who passes those,
so a policy clause about them would only constrain its author against themselves.

## How a layer is decided

By **where a file is**, never by what it says. `Projects/Present/Magenta.yml` belongs to the layer
whose `Paths` match `Projects/Present/Magenta`. Your repository's own controls (CODEOWNERS, branch
protection per folder) are what tie a folder to a team; the policy mirrors them.

When several layers contribute to one resource, it is allowed only what **every one of them** is
allowed. With the usual merge of `resources` by `name`, a team that redeclares a platform resource
replaces it whole, and its version is held to the team's permissions.

## What a violation looks like

A file that breaks the policy does not start. Every violation is listed:

```
Capability policy: 2 violation(s) in node 'App'; no resource was run.
Policy: '/config/Policy.yml' (9b1c4e2a7f05).
  - Resource [Module/Resource/Team over SSH] uses the Target 'SSH', which is not allowed for
    layer(s) Teams (contributors to this resource: Teams) (in this node, layer Teams owns
    Projects/Present/App).
  - Resource [Module/Resource/Team with a script] has an execution script, which is not allowed
    for layer(s) Teams (contributors to this resource: Teams) (in this node, layer Teams owns
    Projects/Present/App).
```

A Datum script block in a layer that may not use one stops earlier still, before anything is
compiled:

```
[Capability policy] 1 violation(s); nothing was compiled or run:
  - 'Projects/Present/App.yml' (layer Teams) contains a Datum script block ([x={ ... }=]),
    which that layer is not allowed.
```

A dry run (`-Mode DryRun`) reports the same, so a pull-request pipeline can catch a violation
before the change is merged.

## See what the policy means, before it bites

```powershell
Get-DscCapabilityPolicyReport -ConfigurationPath ./config -AsText
```

Prints every layer with the **effective** rule for every capability — the ones a layer does not
list shown as `Deny (not listed; from Default)` rather than left blank — which layer owns each file
and each `ResolutionPrecedence` entry, every resource the files declare with the layers that
declare it, and findings for the ways a policy ends up quietly ineffective:

| Finding | Meaning |
| --- | --- |
| `LayerMatchesNothing` | A layer's `Paths` match no file. Almost always a typo — and a typo in `Paths` puts files in `(unclaimed)`, which may do nothing. |
| `UnclaimedFile` | A file no layer claims. |
| `RemoteTargetWithoutComputer` | The layer may use a remote Target but `RemoteTargets` allows it no computer, so every remote resource it declares is refused. |
| `LayerDeclaresNothing` | The layer owns files but may declare no resource type at all. |
| `DefaultAllow` | `Default: Allow`, so a capability a later version adds is allowed to every layer. |
| `DeclarationRefused` | A declaration the policy would refuse. |
| `PreCompileRefusal` | What the pre-compile check would refuse (a Datum script block in the wrong layer). |

It compiles nothing and runs nothing, so it is safe in a pull request or a pre-commit hook. Without
`-AsText` you get an object, and `$report.HasError` is what a pipeline gates on.

It reads the files, not Datum's merge, so it is **advisory**: a resource it shows as allowed can
still be refused at run time, usually because a second layer also declares it. The run is what
enforces the policy.

## See what the policy was applied to

Beside each compiled file the runner writes `<node>.provenance.json`. It lists the layers of the
node and, for every resource that will run, the layers that contributed to it. Keep the compiled
directory with `-KeepTemporaryDirectory`, or point `-CacheDirectory` somewhere you can read.

## Parameters

| Parameter | Use |
| --- | --- |
| *(none)* | `Policy.yml` beside `Datum.yml` is used when it exists. |
| `-PolicyPath <file>` | Use this file instead. It wins over the one in the configuration. |
| `-RequirePolicy` | Fail when there is no policy, so removing `Policy.yml` cannot switch enforcement off unnoticed. |

Both are on `Invoke-DscRunner` and `Invoke-DscPipelineRunner`.

## Protect the policy file

`Policy.yml` is in the configuration repository, so whoever can change it decides what every layer
may do. Give `Policy.yml` and `Datum.yml` to your most trusted owners with CODEOWNERS and branch
protection. If that is not enough for you, keep the policy somewhere contributors cannot write and
pass it with `-PolicyPath`, or at least use `-RequirePolicy`.

## Upgrading a policy written for v1.3.0

The first release had four capabilities. A policy written then still loads, but under
`Default: Deny` the five that were added — `Resources`, `Credentials`, `RemoteTargets`, `Notify`
and `Reboot` — now resolve to `Deny` for every layer that does not list them. **A layer with no
`Resources` rule may declare no resource at all**, so a configuration that ran before can stop
running until its policy is updated. That is fail-closed working as intended.

Run `Get-DscCapabilityPolicyReport -ConfigurationPath <config> -AsText` and read the `Layers`
section: every capability shown as `Deny (not listed; from Default)` is a decision the policy has
not made yet. Grant each layer what it needs — `Resources` at least — and leave the rest denied.

## Limits

- It is not a sandbox. The Datum merge still runs as ordinary PowerShell; the `DatumScriptBlocks`
  check removes the documented way to run code there, nothing more.
- `Resources` restricts which resource *types* a layer may declare, not the properties it passes
  them, and not which *methods* it may use (there is no "`Test` and `Get` but not `Set`" yet).
- `Credentials` restricts which Credential *actions* a layer may use, not which individual
  secrets. Two layers allowed `SecretManagement` can read each other's secrets; that boundary
  belongs to the vault.
- A composite instantiated by a team gets the team's permissions, even when the platform wrote the
  composite.
- It governs a configuration compiled from a hierarchy, not one handed to the runner directly. A
  document supplied with `Invoke-DscRunner -ConfigurationFile` / `-ConfigurationDirectory` has no
  layers, so no capability can be decided for it; such a run must declare the step outside the
  policy with `-BypassDatumPolicy`, and is refused outright when a `Datum.yml` and a `Policy.yml`
  sit together above the documents. See [Bypassing Datum](Bypassing-Datum).

The design, the reasoning and the follow-up list are in
[docs/capability-policy.md](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/capability-policy.md).

## Troubleshooting

| Message | Cause |
| --- | --- |
| `There is no provenance record for '<file>'` | The file was compiled without the policy (for example by an earlier run into a cache directory). Compile and run in the same invocation. |
| `was written under a different policy` | The compiled files in the cache directory come from another version of the policy. Clear the cache directory. |
| `is for node '<other>', not for '<node>'` | The provenance record beside the compiled file was written for a different node, so it is not this file's record. A compiled file was renamed, or a record was copied from another output directory. Compile the configuration again instead. |
| `… not allowed for layer(s) (unclaimed)` | The file is in a folder no layer's `Paths` match. Add the folder to a layer. |
| `The policy file is in a sub-folder of the configuration` | The policy must be at the root, beside `Datum.yml`, or outside the configuration. |
| `A policy is required for this run` | `-RequirePolicy` was given and there is no `Policy.yml` and no `-PolicyPath`. |
| `Unknown key(s) …`, `unknown capability …` | The policy file is read strictly. Fix the spelling; nothing is guessed. |
| `is of the resource type '…', which is not allowed` | Add the type to the layer's `Resources`, as `Module/Resource` or `Module/*`. |
| `uses the remote Target computer '…', which is not allowed` | The Target action is allowed but the machine is not. Add it to the layer's `RemoteTargets`. |
| `uses a remote Target with no computerName` | A Target other than `Local` has to name a machine; there is nothing for the policy to allow. |
| `does not name a resource type` | A `Resources` pattern has no `/`. Write `PSDscResources/*`, not `PSDscResources`. |
| `resolves a credential through the '…' Credential action` | Add the action to the layer's `Credentials`, or have the layer use one it already has. |
| `notifies N resource(s) …, forcing them to re-run Set()` | Set `Notify: true` for the layer, or use `dependsOn` if ordering is all that was wanted. |
| `uses a restart of its remote Target` | The resource's `Set()` has run and asked for a reboot. Set `Reboot: true` for the layer, or restart the machine yourself. |
| `refuses N PipelineRunnerSettings value(s) of Datum.yml` | A `Datum.yml` setting (or the default for one it leaves out) is not in the policy's `Settings`. Change `Datum.yml`, or have the policy allow the value. |
| `Settings: '…' is not a setting a policy can govern` | `Settings` accepts `AllowExecutionScripts`, `Engine`, `Reboot` and `Target`. |
| `layer '…' matches no file` (a warning) | A path pattern is wrong. The files you meant it to own are in `(unclaimed)` and may do nothing. |
