# Capability Policy (preview)

A capability policy says **what each layer of a configuration is allowed to use**, so several
teams can contribute to one configuration without each of them being trusted with everything the
runner can do. It is a preview: the format and behaviour may change.

Without a policy nothing changes.

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
      ExecutionScripts: true
      DatumScriptBlocks: true
  - Name: Teams
    Paths: [ 'Projects/**' ]
    Capabilities:
      Targets: [ Local, WinRM ]
      Engines: [ DscV2, DscV3 ]
```

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

| Capability | Value | Governs |
| --- | --- | --- |
| `Targets` | list, wildcards allowed | The [Target action](Remote-Targets-and-Credentials) a resource runs through, including the file's default. |
| `Engines` | list, wildcards allowed | The [engine](Engines) that runs the file. |
| `ExecutionScripts` | `true` / `false` | `preExecutionScript` and `postExecutionScript`. `AllowExecutionScripts` must also be on. |
| `DatumScriptBlocks` | `true` / `false` | `[x={ ... }=]` blocks evaluated during the Datum merge. |

A file that no layer claims may do nothing at all, whatever `Default` says.

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
Capability policy: 2 violation(s); no resource was run.
  - Resource [Module/Resource/Team over SSH] uses the Target 'SSH', which is not allowed for
    layer(s) Teams (contributors to this resource: Teams).
  - Resource [Module/Resource/Team with a script] has an execution script, which is not allowed
    for layer(s) Teams (contributors to this resource: Teams).
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

## Limits of the preview

- It is not a sandbox. The Datum merge still runs as ordinary PowerShell; the `DatumScriptBlocks`
  check removes the documented way to run code there, nothing more.
- A layer allowed to declare resources can declare any resource type. Restricting resource types,
  methods, credentials, sources and Connect actions is planned, not implemented.
- A composite instantiated by a team gets the team's permissions, even when the platform wrote the
  composite.

The design, the reasoning and the follow-up list are in
[docs/capability-policy.md](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/capability-policy.md).

## Troubleshooting

| Message | Cause |
| --- | --- |
| `There is no provenance record for '<file>'` | The file was compiled without the policy (for example by an earlier run into a cache directory). Compile and run in the same invocation. |
| `was written under a different policy` | The compiled files in the cache directory come from another version of the policy. Clear the cache directory. |
| `… not allowed for layer(s) (unclaimed)` | The file is in a folder no layer's `Paths` match. Add the folder to a layer. |
| `The policy file is in a sub-folder of the configuration` | The policy must be at the root, beside `Datum.yml`, or outside the configuration. |
| `A policy is required for this run` | `-RequirePolicy` was given and there is no `Policy.yml` and no `-PolicyPath`. |
| `Unknown key(s) …`, `unknown capability …` | The policy file is read strictly. Fix the spelling; nothing is guessed. |
