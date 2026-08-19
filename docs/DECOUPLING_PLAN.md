# Dsc.PipelineRunner — Azure DevOps Decoupling & DSC v3 Plan

Status: proposed
Owner: @ZanattaMichael
Tracking epic: [#20](https://github.com/ZanattaMichael/Dsc.PipelineRunner/issues/20)

## 1. Goal

Turn `Dsc.PipelineRunner` into a **platform-agnostic DSC orchestrator** that can drive
any DSC resource from any CI/CD system, with Azure DevOps demoted from a hard
dependency to one optional provider among several.

Three outcomes define "done":

1. **Decoupling** — the core runner imports, loads, and executes with **no**
   dependency on `AzureDevOpsDsc`, no `New-AzDoAuthenticationProvider`, no
   `AZDODSC_*` environment variables, and no Azure-DevOps-specific parameters.
2. **DSC v3 support** — the runner can evaluate resources through **`dsc.exe`**
   (DSC v3, cross-platform) in addition to the legacy `Invoke-DscResource` path,
   selected by configuration/capability rather than hard-coded.
3. **No "LCM"** — the term *LCM* (Windows DSC v2 Local Configuration Manager)
   appears nowhere in the codebase, docs, manifest URIs, or history-facing text.
   The tool is a pipeline runner, not an LCM.

Code-signing (#38) and supply-chain hardening (#36) are explicitly **last** — they
gate a release, not the architecture, and should not block the decoupling work.

## 2. Current coupling — verified

| Coupling point | File | Detail |
|---|---|---|
| Requires `AzureDevOpsDsc` + `.Common` | `source/Dsc.PipelineRunner.psd1` (RequiredModules, lines 63–70) | Loaded for every consumer even when not on AzDO |
| AzDO auth call | `source/Public/Invoke-DscPipelineRunner.ps1:136–139` | `New-AzDoAuthenticationProvider` (PAT / ManagedIdentity) |
| AzDO-named cache var | `Invoke-DscPipelineRunner.ps1:108` | Throws unless `$env:AZDODSC_CACHE_DIRECTORY` is set |
| AzDO-specific params | `Invoke-DscPipelineRunner.ps1:47–68` | `AzureDevopsOrganizationName`, `JITToken`, PAT validator |
| Clone over plaintext, JIT helper | `source/Private/DatumHelper/Clone-Repository.ps1`, `git.ps1` | AzDO PAT credential helper; #9, #31 |
| DSC v2 only | `source/Private/Runner/Start-DscRunner.ps1:182,205,245` | `Invoke-DscResource` — Windows-first, PS 5.1 / DSC-v2 semantics |
| Manifest URIs | `Dsc.PipelineRunner.psd1:134,137,140` | Point at old `AzDO-DSC-LCM` repo (404) — also the last live "LCM" strings |
| Historical "LCM" text | `CHANGELOG.md` | Migration table still spells out `AZDO-DSC-LCM`, `Invoke-AZDoLCM`, `LCMConfigSettings` |

The good news the epic already notes: the **core evaluation loop
(`Start-DscRunner`) has no AzDO dependency** — it is only *unreachable* because
`Invoke-DscPipelineRunner` gates it behind AzDO setup. The work is mostly
re-layering, not rewriting.

## 3. Target architecture

Two-layer split, mirroring `Datum` (core) + build-system adapters:

```
Dsc.PipelineRunner                      (core — provider-agnostic)
├─ Start-DscRunner                      resource evaluation loop
├─ Build-DatumConfiguration             Datum compilation
├─ Stop-TaskProcessing                  run control
├─ Pipeline Rules/                      provider-agnostic rules (already loader-driven)
├─ Actions/                             NEW loader-driven lifecycle hooks (§4A)
│   ├─ Source/                          resolve config → local dir
│   │   ├─ Local.ps1                    local directory passthrough (default)
│   │   └─ Git.ps1                      clone any git remote (HTTPS/SSH)
│   ├─ Connect/                         establish auth/session before Test/Set/Get
│   │   ├─ None.ps1                     no auth (default)
│   │   └─ AzureDevOps.ps1              New-AzDoAuthenticationProvider — opt-in, soft dep
│   └─ Engine/                          drive Test/Set/Get — action + typed contract (§4B, §5)
│       ├─ DscV2.ps1                    wraps Invoke-DscResource (default)
│       └─ DscV3.ps1                    wraps dsc.exe (DSC v3)
└─ RequiredModules: NO AzureDevOpsDsc   (AzDO is an optional action, not a dependency)
```

**Single module.** There is no separate `Dsc.PipelineRunner.AzureDevOps` package.
The Azure-DevOps-specific surface in the source is one command —
`New-AzDoAuthenticationProvider` (`Invoke-DscPipelineRunner.ps1:136–139`) — and it
isn't even the runner's logic: it establishes an ambient session that the
`AzureDevOpsDsc` *resource module* consumes during Test/Set/Get, exactly like a
cloud resource would need its own session. Everything else read as "AzDO" is
generic: `Clone-Repository` is a plain `git clone`; the `git` wrapper's
`http.extraHeader="Authorization: Basic …"` is standard git-over-HTTPS auth that
GitHub/GitLab/Bitbucket all accept. A whole second published module to hold one
optional pre-step is unjustified — it becomes a drop-in **action** instead.

### Two seams introduced

**A. Actions — loader-driven lifecycle hooks.** This generalizes the pattern the
module *already uses for rules*: `Invoke-PreParseRules` enumerates and dot-sources
every `.ps1` in `Pipeline Rules/PreParse/`, and `Invoke-CustomTask` dispatches to a
named file (`Sort-DependsOn.ps1`) passing a known contract (`-PipelineResources`).
Actions apply the same idiom to the lifecycle hooks the runner must not hard-code:

- `Actions/Source/` — resolve a config source to a local directory
  (`Local`, `Git`, or a user drop-in)
- `Actions/Connect/` — establish auth/session before evaluation
  (`None`, `AzureDevOps`, or a user drop-in)
- `Actions/Engine/` — drive resource Test/Set/Get
  (`DscV2`, `DscV3`, or a user drop-in) — see seam B for its stricter contract

Every action file exposes the same shape as the existing rules — `param($Context)`
— returning its result (a local path for Source; a credential/`$null` for Connect;
a normalized result for Engine). Selection is config-driven and consistent with
existing keys:

```yaml
PipelineRunnerSettings:
  Source: Git            # a file in Actions/Source/  (default: Local)
  Connect: AzureDevOps   # a file in Actions/Connect/ (default: None)
  Engine: DscV3          # a file in Actions/Engine/  (default: DscV2)
```

**Runtime scriptblock override — no file required.** For bespoke, one-off cases the
caller instantiates the runner with a custom action inline:

```powershell
Invoke-DscRunner -Source $localDir -ConnectAction {
    param($Context)
    Connect-MyPlatform -Token $Context.Credential   # any custom solution
}
```

`AzureDevOps.ps1` calls `New-AzDoAuthenticationProvider` only if
`AzureDevOpsDsc.Common` is importable; the core never loads it and never lists it in
`RequiredModules`. AzDO thus becomes opt-in by *naming its action* (or shipping an
optional "actions pack"), never a hard dependency and never a separate module.

**B. Execution engine — an action *and* a typed seam.** `Start-DscRunner` currently
calls `Invoke-DscResource` directly three times (Test/Set/Get). Engines are loaded
through the same `Actions/` mechanism as Source and Connect — drop a file in
`Actions/Engine/`, select it by name (`Engine: DscV3`), or pass an inline
`-EngineAction` scriptblock — so third parties can add engines without forking.

Unlike Source/Connect, the engine also carries a **strict, typed contract**, because
it runs once per resource per method on the hot path and its result feeds the report
and the exit code:

- input: `$Context` = `{ Method = 'Test'|'Set'|'Get'; ModuleName; Name; Property }`
- output: a normalized `[DscMethodResult]`
  `{ InDesiredState:[bool]; RebootRequired:[bool]; Message:[string]; Raw }`

The loader validates that a selected engine returns this shape (a Pester contract
test every engine must pass), so the loop stays engine-agnostic while the boundary
stays type-checked. Net: the pluggability of an action with the guarantees of a typed
interface — `DscV2` and `DscV3` ship in the box, custom engines are first-class.

## 4. Phased delivery

Ordered so each phase is independently shippable and the runner stays green
throughout. Numbers in brackets are the GitHub issues each phase closes/advances.

### Phase 0 — Stabilize the core loop (prerequisite bug-fixes) [7, 8, 10, 11, 12, 13, 14, 18, 28]

Decoupling is pointless on top of a loop that miscomputes paths and swallows
errors. These are self-contained and unblock everything:

- Report filename `TrimEnd('.yml')` → `GetFileNameWithoutExtension`; `Join-Path`
  instead of `\` — `Start-DscRunner.ps1:272` [7, 18]
- `SetVariables` literal `varName` env var [10]
- `Test-DatumConfiguration` permanent no-op version gate [11]
- `Build-DatumConfiguration` swallows runspace errors [12]
- `Expand-HashTable` null props / caller-scope `$task` read [13]
- One throwing resource aborts the whole run; `Write-Error` terminates under the
  advanced-function caller — `Start-DscRunner.ps1:210–214` [14, 28]
- `Test-ResourcesForIncorrectProperties` stops after first failure [8]

Exit criterion: full Pester suite green on Linux and Windows hosted agents.

### Phase 1 — Core decoupling via the Actions loader (single module) [20]

1. Remove `AzureDevOpsDsc` and `AzureDevOpsDsc.Common` from core
   `RequiredModules` (`Dsc.PipelineRunner.psd1:63–70`).
2. Add the **`Actions/` loader** (§3A), reusing the `Invoke-CustomTask` /
   `Invoke-PreParseRules` idiom: a resolver that, given a hook (`Source`/`Connect`)
   and a name, dot-sources `Actions/<Hook>/<Name>.ps1` with `-Context`, and a
   registration path for an inline `[scriptblock]` override.
3. Introduce a provider-agnostic `Invoke-DscRunner` core entry point that:
   - runs the configured **Source** action to obtain a local config dir
     (or accepts one directly),
   - runs the configured **Connect** action (default `None`) to establish
     auth/session,
   - accepts a generic `-CacheDirectory` (default `$(Agent.TempDirectory)` /
     `[System.IO.Path]::GetTempPath()`), replacing the `AZDODSC_CACHE_DIRECTORY`
     hard requirement [21],
   - compiles Datum and calls `Start-DscRunner` per file,
   - accepts `-SourceAction` / `-ConnectAction` scriptblocks for custom solutions.
4. Ship **`Actions/Source/Local.ps1`**, **`Actions/Source/Git.ps1`** (generic clone
   replacing the AzDO-only path — HTTPS/SSH, revision pinning, scoped temp dir with
   cleanup [31, 32]), and **`Actions/Connect/None.ps1`**.
5. Ship **`Actions/Connect/AzureDevOps.ps1`** — wraps `New-AzDoAuthenticationProvider`,
   imports `AzureDevOpsDsc.Common` only if present, otherwise throws a clear
   "install the AzureDevOpsDsc actions pack" error. No new module, no hard dependency.
6. Keep `Invoke-DscPipelineRunner` as a thin **back-compat shim** in the same module:
   it maps its AzDO-flavored parameters (`AzureDevopsOrganizationName`, `JITToken`,
   PAT) onto `Invoke-DscRunner -Source Git -Connect AzureDevOps`, so existing callers
   migrate with no functional change.

Exit criteria (from #20): `Start-DscRunner` + `Build-DatumConfiguration` import and
run with `AzureDevOpsDsc` absent; an integration test runs the core against a local
directory with `Connect: None` and no AzDO connection; a third party can add a
`Connect` action or pass a `-ConnectAction` scriptblock without forking.

### Phase 2 — DSC v3 (`dsc.exe`) execution engine [21]

See §5. Add the `Actions/Engine/` hook with its typed `[DscMethodResult]` contract
(§3B), extract today's `Invoke-DscResource` calls into `DscV2.ps1` (default), and add
`DscV3.ps1` driving `dsc.exe`. Both must pass the shared engine contract test. This is
what makes Linux/macOS hosted agents genuinely useful, since `Invoke-DscResource` is
Windows/PS-DSC-v2-first.

### Phase 3 — Pipeline-native auth & hosted-agent story [21, 22]

- `-JITToken` / `-PATToken` → `[SecureString]`; no token in any output stream [22]
- Auto-detect `$env:SYSTEM_ACCESSTOKEN`; document workload-identity federation [22]
- Bootstrap script + container image; one hosted-agent CI job [21]
- Generic env var names; `AZDODSC_CACHE_DIRECTORY` honored only inside the AzDO
  provider as a documented back-compat alias.

### Phase 4 — Runner exit contract & reporting [19, 23, 29, 30]

- Machine-readable result + non-zero exit code on failure [19]
- Real topological `Sort-DependsOn` [23]
- Rebuilt reporting subsystem; legible pipeline-log output (not all `Write-Host`)
  [29, 30]

### Phase 5 — Docs, CI, cleanup [24, 25, 26, 27, 33, 34, 35, 37]

- README/`condition` correctness, trust-boundary docs, Wiki [24, 27, 37]
- CI builds/lints/enforces coverage; drop CodeQL for absent languages [25]
- Dead code / cross-scope deps [26]
- Config-format hardening: dot-sourced scriptblocks, log redaction, safe export
  dir [33, 34, 35]

### Phase 6 — Release hardening (LAST) [36, 38]

- Pin & verify dependency resolution; supply-chain controls [36]
- Authenticode code-signing for module + Pipeline Rules [38]

PR #39 (release workflow) already exists and stays open; wire signing into it here.

## 5. DSC v3 / `dsc.exe` support (detail)

`Start-DscRunner` calls `Invoke-DscResource` for **Test**, **Set**, and **Get**
(`Start-DscRunner.ps1:182, 205, 245`). That API is the DSC **v2** path
(PSDesiredStateConfiguration, Windows-first). DSC **v3** is a standalone
cross-platform CLI (`dsc.exe` / `dsc`) that operates on resource manifests and
JSON over stdin/stdout.

### Approach — engine as an action with a typed contract

Engines load through the `Actions/` loader (§3A) but honor a strict typed contract
(§3B), so they are both drop-in-pluggable and type-checked.

1. Route the three call sites through the loader, e.g. `Invoke-EngineAction -Context
   @{ Method='Test'; ModuleName=…; Name=…; Property=… }`, which resolves the selected
   `Actions/Engine/<Name>.ps1` (or an inline `-EngineAction` scriptblock) and requires
   a **normalized `[DscMethodResult]`** back
   (`{ InDesiredState, RebootRequired, Message, Raw }`) so reporting is engine-independent.
2. **`Actions/Engine/DscV2.ps1`** (default) — today's behavior, `Invoke-DscResource`,
   unchanged apart from returning the normalized shape.
3. **`Actions/Engine/DscV3.ps1`** — shells out to `dsc.exe`:
   - map `Test`/`Set`/`Get` to `dsc resource test|set|get`,
   - pass the resource type and property JSON on stdin,
   - parse the JSON result into the normalized shape,
   - surface `dsc.exe` non-zero exit as a failed resource (feeds Phase 4 exit
     contract).
4. **Contract test** — a single shared Pester suite runs against every engine in
   `Actions/Engine/` (and any custom one) asserting the input/output contract, so a
   third-party engine is a first-class citizen the moment it passes.
5. **Engine selection** — the `PipelineRunnerSettings.Engine` key names the file
   (`DscV2`/`DscV3`/custom). Keep the existing
   `PipelineRunnerSettings.DSCResourceVersion` (`Example Configuration/Datum.yml:21`)
   as a back-compat default mapping (`2.x`→`DscV2`, `3.x`→`DscV3`) when `Engine` is
   unset; allow a per-invocation `-EngineAction` override and auto-detect (`dsc.exe`
   on PATH) with a clear error when the requested engine is unavailable.
6. **Docs & CI** — a "Getting started on a hosted Linux agent with DSC v3" page,
   and a CI job that runs a real v3 resource through `dsc.exe` on Linux.

This keeps the loop, rules, reporting, and connect/source actions identical across
engines — only the selected `Actions/Engine/` file changes.

## 6. Eradicating "LCM"

Every remaining live occurrence (verified by `grep -rniI LCM`) plus the intent:

| Location | Action |
|---|---|
| `Dsc.PipelineRunner.psd1:134,137,140` (`LicenseUri`/`ProjectUri`/`IconUri` → `AzDO-DSC-LCM`) | Repoint to `ZanattaMichael/Dsc.PipelineRunner`; fixes the 404s and removes the last executable "LCM" strings |
| `CHANGELOG.md` migration table (`AZDO-DSC-LCM`, `Invoke-AZDoLCM`, `LCMConfigSettings`, `AZDOLCMVersion`, `LCM Rules\`) | Rewrite the migration guide to describe the rename **without** re-introducing the term as living config — frame historical names as *former* names in prose only, or move the mapping to a one-time `docs/MIGRATION.md` note. The rationale line ("`LCM` referred to the deprecated v2 Local Configuration Manager") is retained as the *reason* the term is gone, phrased in the past tense. |
| Any code comments / rule text referencing LCM concepts | Sweep and reword to "pipeline runner" / "runner" terminology |

Acceptance: `grep -rniI 'LCM' .` (excluding `.git/`) returns **zero** matches in
source, manifest, and config; the only permissible residue is a clearly past-tense
migration note, and even that avoids the acronym where a plain phrase works. A CI
grep-guard enforces "no new LCM" going forward.

## 7. Acceptance criteria (roll-up)

- [ ] Core imports and runs with `AzureDevOpsDsc` absent (#20)
- [ ] `AzureDevOpsDsc*` removed from core `RequiredModules` (#20)
- [ ] AzDO logic lives in an opt-in `Actions/Connect/AzureDevOps.ps1` — single module, no separate package, no hard dependency (#20)
- [ ] A custom `Source`/`Connect`/`Engine` action (drop-in file or inline scriptblock) works without forking (#20)
- [ ] Integration test: core runs against a local dir with `Connect: None`, no AzDO connection (#20)
- [ ] Engines load via `Actions/Engine/` and every engine passes the shared typed-contract Pester test (#21)
- [ ] `dsc.exe` (DSC v3) engine selectable (`Engine: DscV3`) and green in CI on Linux (#21)
- [ ] Pipeline-native auth: SecureString tokens, `System.AccessToken`, no token in logs (#22)
- [ ] Runner returns a machine-readable result and a non-zero exit on failure (#19)
- [ ] Phase-0 correctness bugs fixed with Pester coverage (#7–#14, #18, #28)
- [ ] Zero "LCM" occurrences in source/manifest/config; CI grep-guard in place
- [ ] Code-signing & supply-chain (#38, #36) landed **after** the above

## 8. Sequencing summary

```
Phase 0  bug-fixes ─────────────┐
Phase 1  core/provider split ───┼──> Phase 2  DSC v3 engine ──> Phase 4  exit/report
                                └──> Phase 3  auth/hosted agent
Phase 5  docs/CI/hardening  (parallel, continuous)
Phase 6  signing + supply-chain  (LAST)
```

Decoupling (Phases 0–1) is the critical path; DSC v3 and pipeline-native auth build
directly on the seams it introduces; code-signing deliberately comes last.
