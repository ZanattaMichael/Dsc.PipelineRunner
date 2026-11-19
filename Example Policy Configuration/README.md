# Example: a configuration with a capability policy (preview)

A small configuration that two kinds of contributor share, with a policy that says what each may
use. It is the worked example for [docs/capability-policy.md](../docs/capability-policy.md).

```
Example Policy Configuration/
├── Datum.yml                     the hierarchy (platform team)
├── Policy.yml                    the capability policy: beside Datum.yml, never merged
├── Platform/
│   └── Baseline.yml              platform team: applies to every node
└── Projects/
    └── Present/
        └── WebTeam.yml           an application team's node
```

## Who may do what

| Capability | Platform (`Datum.yml`, `Platform/**`, `Composites/**`) | Teams (`Projects/**`) |
| --- | --- | --- |
| `Targets` | any | `Local`, `WinRM` — no SSH |
| `Engines` | any | `DscV2`, `DscV3` |
| `Resources` | any resource type | `PSDscResources/*` — no `Script` resource |
| `Credentials` | any Credential action | `Environment` only — no vault, no password in the file |
| `RemoteTargets` | any machine | `*.app.contoso.example` — not the bastion |
| `ExecutionScripts` | yes | no (`Default: Deny`) |
| `DatumScriptBlocks` | yes | no (`Default: Deny`) |
| `Notify` | yes | no (`Default: Deny`) |
| `Reboot` | yes | no (`Default: Deny`) |

Its `Settings` block also limits `Datum.yml`'s `PipelineRunnerSettings`: `Engine` must be `DscV2`
or `DscV3`, the default `Target` must be `Local`, and `Reboot` must be `Fail` (the default).
Setting `Reboot: Ignore` in `Datum.yml` stops the run before compile.

`Policy.yml` is a file of its own at the root. Datum builds its tree from the root's sub-folders,
so the policy is outside the hierarchy: no layer can add to it or override it, and it is not in
`ResolutionPrecedence`.

## See what it means, before it bites

```powershell
Get-DscCapabilityPolicyReport -ConfigurationPath './Example Policy Configuration' -AsText
```

Prints every layer with the effective rule for every capability (including the ones a layer does
not list, resolved through `Default`), which layer owns each file and each `ResolutionPrecedence`
entry, every resource the files declare with the layers that declare it, and findings for the ways
a policy ends up quietly ineffective. It compiles nothing and runs nothing.

## Try it

Validate the configuration without touching anything:

```powershell
Invoke-DscRunner -ConfigurationSourcePath './Example Policy Configuration' -Mode DryRun
```

The run reports that the policy was found and that the file complies. Beside the compiled file the
runner writes `WebTeam.provenance.json`, which shows what the policy was applied to:

| Resource | Contributed by | Why it is allowed |
| --- | --- | --- |
| `Platform marker` | Platform | SSH, the bastion, the vault credential, the script and the `notify` are all the platform's own. |
| `Log level` | Platform, Teams | The team replaced it; it uses the default `Local` target. |
| `Site name` | Teams | `Local`, and `PSDscResources/Environment` is in the team's `Resources`. |
| `Site name on the web server` | Teams | `WinRM`, a computer in `*.app.contoso.example`, and the `Environment` Credential action. |

## See it refuse

Each of these changes to `Projects/Present/WebTeam.yml` makes the run stop before any resource is
evaluated, naming the resource, the layer and the files that layer owns:

1. **A Target the team may not use.** Change `action: WinRM` to `action: SSH`.
2. **Taking over a platform resource.** Copy the platform's `Platform marker` into the team file
   (same `name`), keeping its `target: { action: SSH }`. The team's copy is what would run, so it
   is held to the team's permissions.
3. **An execution script.** Add `postExecutionScript: Write-Verbose hi` to any of the team's
   resources.
4. **A Datum script block.** Set a variable to `'[x={ Get-Date }=]'`. This one stops even earlier:
   nothing is compiled.
5. **A resource type the team may not declare.** Change a resource's `type` to
   `PSDesiredStateConfiguration/Script`. A `Script` resource is arbitrary code, so it is the one
   thing a constrained layer must not be able to reach for.
6. **Another machine.** Change `computerName: web01.app.contoso.example` to
   `bastion.contoso.example`. `WinRM` is still allowed; the destination is not.
7. **A credential the team may not use.** Change the WinRM resource's `credential.action` to
   `SecretManagement` (the platform's vault) or `Static` (a password in the configuration).
8. **Forcing a platform resource to re-apply.** Add
   `notify: [ 'PSDscResources/Environment/Log level' ]` to one of the team's resources. `notify`
   makes the notified resource run `Set()` even when its own `Test()` says it is already in the
   desired state, so it is a capability of its own. `dependsOn` is not restricted: it only orders
   resources that were going to run anyway.

`Tests/PipelineRunner/DSCConfiguration/Integration/CapabilityPolicy.Integration.tests.ps1` makes
exactly these changes to a copy of this folder and checks each refusal, so this page cannot drift
from what the runner does.

## Notes

- The resources use `PSDscResources/Environment` so the example needs nothing unusual installed.
  The SSH and WinRM hosts are placeholders; a `Test` or `Set` run would try to reach them.
- The runner does not expand expressions inside a `target` block — not `action`, not
  `computerName`. Both are written out in full in this example. That is what stops one layer
  steering another layer's resource onto a different machine by setting a variable.
- `Datum.yml` uses `\` in `ResolutionPrecedence`, like the main example. Datum splits those entries
  on the platform's own separator, so on Linux or macOS write them with `/`.
- A pipeline that must never run a configuration without a policy adds `-RequirePolicy`.
