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

| Layer | Files | Targets | Engines | Execution scripts | Datum script blocks |
| --- | --- | --- | --- | --- | --- |
| Platform | `Datum.yml`, `Platform/**`, `Composites/**` | any | any | yes | yes |
| Teams | `Projects/**` | `Local`, `WinRM` | `DscV2`, `DscV3` | no | no |

`Policy.yml` is a file of its own at the root. Datum builds its tree from the root's sub-folders,
so the policy is outside the hierarchy: no layer can add to it or override it, and it is not in
`ResolutionPrecedence`.

## Try it

Validate the configuration without touching anything (needs a module version with `DryRun`):

```powershell
Invoke-DscRunner -ConfigurationSourcePath './Example Policy Configuration' -Mode DryRun
```

The run reports that the policy was found and that the file complies. Beside the compiled file the
runner writes `WebTeam.provenance.json`, which shows what the policy was applied to:

| Resource | Contributed by | Why it is allowed |
| --- | --- | --- |
| `Platform marker` | Platform | SSH and the script are the platform's own. |
| `Log level` | Platform, Teams | The team replaced it; it uses the default `Local` target. |
| `Site name` | Teams | `Local`. |
| `Site name on the web server` | Teams | `WinRM` is in the team's list. |

## See it refuse

Each of these changes to `Projects/Present/WebTeam.yml` makes the run stop before any resource is
evaluated, naming the resource and the layer:

1. **A Target the team may not use.** Change `action: WinRM` to `action: SSH`.
2. **Taking over a platform resource.** Copy the platform's `Platform marker` into the team file
   (same `name`), keeping its `target: { action: SSH }`. The team's copy is what would run, so it
   is held to the team's permissions.
3. **An execution script.** Add `postExecutionScript: Write-Verbose hi` to any of the team's
   resources.
4. **A Datum script block.** Set a variable to `'[x={ Get-Date }=]'`. This one stops even earlier:
   nothing is compiled.

`Tests/PipelineRunner/DSCConfiguration/Integration/CapabilityPolicy.Integration.tests.ps1` makes
exactly these four changes to a copy of this folder and checks each refusal, so this page cannot
drift from what the runner does.

## Notes

- The resources use `PSDscResources/Environment` so the example needs nothing unusual installed.
  The SSH and WinRM hosts are placeholders; a `Test` or `Set` run would try to reach them.
- `Datum.yml` uses `\` in `ResolutionPrecedence`, like the main example. Datum splits those entries
  on the platform's own separator, so on Linux or macOS write them with `/`.
- A pipeline that must never run a configuration without a policy adds `-RequirePolicy`.
