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
├─ Pipeline Rules/                      provider-agnostic rules
├─ Execution engines/                   NEW abstraction (§5)
│   ├─ Invoke-DscV2Engine               wraps Invoke-DscResource
│   └─ Invoke-DscV3Engine               wraps dsc.exe (DSC v3)
├─ Providers/                           NEW pluggable source + auth contract
│   ├─ Local (default)                  local directory, no auth
│   └─ Git (generic)                    clone any git remote (HTTPS/SSH)
└─ RequiredModules: NO AzureDevOpsDsc

Dsc.PipelineRunner.AzureDevOps          (optional provider module — separate)
├─ Invoke-DscPipelineRunner             AzDO entry point (back-compat shim)
├─ AzDO source/auth provider            New-AzDoAuthenticationProvider wrapper
└─ RequiredModules: Dsc.PipelineRunner, AzureDevOpsDsc
```

### Two seams introduced

**A. Source/auth provider contract.** The core takes a *resolved local
configuration directory* plus an opaque *credential*, and knows nothing about how
either was obtained. A provider is a small object/hashtable implementing:

- `Resolve-Configuration` → returns a local path (local dir passthrough, or clone)
- `Get-Credential` → returns a `[SecureString]`/token object, or `$null`

The generic core ships a **Local** provider (passthrough) and a **Git** provider
(clone any remote, pinned to a revision, over HTTPS/SSH). The AzDO module ships an
**AzureDevOps** provider that adds `System.AccessToken`, workload-identity
federation, and managed identity.

**B. Execution-engine contract.** `Start-DscRunner` currently calls
`Invoke-DscResource` directly three times (Test/Set/Get). Extract an engine
interface `Invoke-DscMethod -Engine <v2|v3> -Method <Test|Set|Get> -Resource …`
so the loop is engine-agnostic (§5).

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

### Phase 1 — Core / provider layering [20]

1. Remove `AzureDevOpsDsc` and `AzureDevOpsDsc.Common` from core
   `RequiredModules` (`Dsc.PipelineRunner.psd1:63–70`).
2. Introduce the **source/auth provider contract** (§3A) and a public
   `Invoke-DscRunner` (provider-agnostic) core entry point that:
   - accepts a resolved config dir *or* a provider descriptor,
   - accepts a generic `-CacheDirectory` (default `$(Agent.TempDirectory)` /
     `[System.IO.Path]::GetTempPath()`), replacing the `AZDODSC_CACHE_DIRECTORY`
     hard requirement [21],
   - compiles Datum and calls `Start-DscRunner` per file.
3. Ship **Local** and **Git** providers in core. Generic Git clone replaces the
   AzDO-only path; pin to a reviewed revision and clean up the temp clone
   [31, 32] — HTTP→HTTPS/SSH, revision pinning, scoped temp dir with cleanup.
4. Move `Invoke-DscPipelineRunner`, the AzDO auth wrapper, and the AzDO
   credential-helper clone into a **new `Dsc.PipelineRunner.AzureDevOps`**
   module directory (built/published separately). Keep `Invoke-DscPipelineRunner`
   as a thin back-compat shim that constructs the AzDO provider and calls the core
   `Invoke-DscRunner` — existing callers migrate with no functional change.

Exit criteria (from #20): `Start-DscRunner` + `Build-DatumConfiguration` import and
run with `AzureDevOpsDsc` absent; an integration test runs the core against a local
directory with no AzDO connection.

### Phase 2 — DSC v3 (`dsc.exe`) execution engine [21]

See §5. Add the v2/v3 engine seam and the v3 `dsc.exe` implementation. This is what
makes Linux/macOS hosted agents genuinely useful, since `Invoke-DscResource` is
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

### Approach — engine abstraction, config-selected

1. Extract the three call sites behind one internal function, e.g.
   `Invoke-DscMethod -Engine <DscV2|DscV3> -Method <Test|Set|Get> -ModuleName …
   -Name … -Property …`, returning a **normalized result**
   (`{ InDesiredState, RebootRequired, Message, Raw }`) so the reporting code is
   engine-independent.
2. **`Invoke-DscV2Engine`** — today's behavior, `Invoke-DscResource`, unchanged.
3. **`Invoke-DscV3Engine`** — shells out to `dsc.exe`:
   - map `Test`/`Set`/`Get` to `dsc resource test|set|get`,
   - pass the resource type and property JSON on stdin,
   - parse the JSON result into the normalized shape,
   - surface `dsc.exe` non-zero exit as a failed resource (feeds Phase 4 exit
     contract).
4. **Engine selection** — a config key drives it. The existing
   `PipelineRunnerSettings.DSCResourceVersion` (`Example Configuration/Datum.yml:21`)
   is the natural switch: `2.x` → v2 engine, `3.x` → v3 engine. Allow a
   per-invocation `-Engine` override and auto-detect (`dsc.exe` on PATH, resource
   type shape) with a clear error when the requested engine is unavailable.
5. **Docs & CI** — a "Getting started on a hosted Linux agent with DSC v3" page,
   and a CI job that runs a real v3 resource through `dsc.exe` on Linux.

This keeps the loop, rules, reporting, and providers identical across engines —
only the three DSC calls change.

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
- [ ] `Dsc.PipelineRunner.AzureDevOps` provider module wraps all AzDO logic (#20)
- [ ] Integration test: core runs against a local dir, no AzDO connection (#20)
- [ ] `dsc.exe` (DSC v3) engine selectable and green in CI on Linux (#21)
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
