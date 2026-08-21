# Contributing to Dsc.PipelineRunner

Thanks for contributing. This document describes the checks a change must pass and how to
run them locally before opening a pull request.

## Repository layout

- `source/` — the module source. `Private/`, `Public/`, and `Classes/` are merged into the
  built module by [Sampler](https://github.com/gaelcolas/Sampler)/ModuleBuilder; the compiled
  output lands under `Output/`.
- `Pipeline Rules/` and `Actions/` — pipeline-rule and action scripts that ship alongside the
  module and are covered by the same tests and lint gate.
- `Tests/PipelineRunner/` — the Pester suite. `Tests/TestHelpers/CommonTestFunctions.psm1`
  provides `Get-FunctionPath` and sets `$Global:RepositoryRoot` / `$Global:TestPaths`.

## Running the checks locally

You need PowerShell 7+ with the module dependencies installed:

```powershell
Install-Module Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration, PSScriptAnalyzer -Force
```

### Tests and code coverage

```powershell
. .\tests.ps1
```

`tests.ps1` runs the full Pester suite with code coverage enabled. It sets
`Run.Exit = $true`, so the process exits non-zero when any test fails, and enforces a minimum
line-coverage floor via `CodeCoverage.CoveragePercentTarget`. Keep new code covered — a drop
below the floor fails the build.

### Static analysis (lint)

```powershell
Invoke-ScriptAnalyzer -Path source, 'Pipeline Rules', Actions -Recurse
```

The CI lint gate fails only on **Error**-severity findings (the parse/correctness class).
Warnings are surfaced for review but do not block. All findings are uploaded to the
repository's **Security → Code scanning** tab as SARIF.

## Continuous integration

Every push and pull request runs these GitHub Actions workflows:

| Workflow | Check | What it enforces |
| --- | --- | --- |
| `.github/workflows/CodeCoverage.yml` | **build** | Guards against reintroduced `LCM` naming, then runs `tests.ps1` (tests + coverage floor). |
| `.github/workflows/Lint.yml` | **Lint (PSScriptAnalyzer)** | Static analysis; fails on Error-severity findings; uploads SARIF. |
| `.github/workflows/DscV3-HostedAgent.yml` | **DSC v3 engine on Ubuntu**, **Build DSC v3 agent image** | Exercises the DSC v3 engine path and image build. |

A pull request should be green on all of the above before it is reviewed.

## Not enforced in this repository

Two items commonly associated with a CI hardening pass are intentionally **not** part of this
repo's code:

- **Branch protection / required status checks.** These are configured by a repository
  administrator under *Settings → Branches*, not in version-controlled files. Maintainers
  should require the `build` and `Lint (PSScriptAnalyzer)` checks on the default branch and
  require pull-request review before merge.
- **A `build.ps1` bootstrap.** The project drives CI directly through `tests.ps1` rather than a
  full Sampler `build.ps1` bootstrap. Introducing the Sampler build pipeline is a larger change
  tracked separately; until then, `tests.ps1` is the entry point CI and contributors use.

## Security

Configuration content executed by the runner is **trusted code** — there is no sandbox. Before
changing anything that loads or evaluates configuration, read [`SECURITY.md`](SECURITY.md) and
[`docs/trust-model.md`](docs/trust-model.md).
