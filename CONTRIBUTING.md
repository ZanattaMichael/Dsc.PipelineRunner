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
./scripts/Install-PinnedModule.ps1 -Name Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration, PSScriptAnalyzer
```

This installs the exact versions pinned in `scripts/module-versions.json`, the ones CI uses. Do not
add a bare `Install-Module` to a workflow, script or the Dockerfile (a test fails if you do): add the
module to the lock file and install it through that script. To move the pins forward, run the
**Update module versions** workflow and commit the lock file it proposes in a pull request.

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
| `.github/workflows/DscV2-SelfHosted.yml` | **DSC v2 Self-Hosted Agent** | Drives a real class-based resource through `Invoke-DscResource` on a Windows self-hosted runner. |
| `.github/workflows/AzureDevOps-SelfHosted.yml` | **Azure DevOps Real Lifecycle Self-Hosted** | End-to-end Azure DevOps lifecycle against a real organization, DSC v2 engine. |
| `.github/workflows/AzureDevOpsV3-SelfHosted.yml` | **Azure DevOps Real Lifecycle DSC v3 Self-Hosted** | The same lifecycle through the DSC v3 engine. |
| `.github/workflows/Wiki.yml` | **Build wiki content** | Compiles `WikiSource/` and the command reference, so wiki drift fails the pull request. |
| `.github/workflows/Docs-Site.yml` | **Build documentation site** | Unit-tests `tools/build-site.js` and builds the documentation site in strict mode, so a broken link fails the pull request. |

A pull request should be green on all of the above before it is reviewed.

### Which tests run where

`tests.ps1` — the hosted `build` gate — excludes the `Integration`, `DscV2SelfHosted`,
`AzureDevOpsSelfHosted` and `AzureDevOpsV3SelfHosted` tags. Those suites need a real DSC
engine, a real resource, or a real Azure DevOps organization, so they run only on the
self-hosted workflows above, which select them by tag or by path.

This split matters when you touch anything `Start-DscRunner` calls. The integration suites
**dot-source the runner's collaborators individually rather than importing the built
module**, so a new helper in that call chain has to be added to each suite's `BeforeAll` as
well — otherwise the hosted gate stays green and the self-hosted jobs fail with
`CommandNotFoundException`.

## Documentation site

The README, `docs/` and `WikiSource/` are published as one site,
<https://zanattamichael.github.io/Dsc.PipelineRunner/>, by `.github/workflows/Pages.yml` on every
push to `main` that touches them. `tools/build-site.js` assembles the site source and rewrites the
links, and `mkdocs build --strict` renders it with Material for MkDocs (`mkdocs.yml`), so a broken
link fails the build. [docs/documentation-site.md](docs/documentation-site.md) describes how it is
built, how to build it locally, and the one-time repository setting it needs (**Settings > Pages >
Source: GitHub Actions**); the wiki is still published to the GitHub wiki by the Release workflow,
unchanged.

## Releasing

To cut a release, run **Actions → Create release tag → Run workflow** from `main`
(`.github/workflows/Create-ReleaseTag.yml`). Choose `preview` or `release`, and a `bump`
(patch, minor or major) or an explicit `version`; tick `dry_run` first to see the tag it would
create. It works out the next tag from the existing ones
(`scripts/Get-NextReleaseTag.ps1`), refuses to continue unless every check on `main` is passing,
creates an annotated tag and starts the Release workflow on it. The same script runs locally:
`./scripts/Get-NextReleaseTag.ps1 -Tag (git tag --list) -Bump patch -Prerelease`.

Releases are tag-driven (`.github/workflows/Release.yml`). Pushing a `vX.Y.Z` tag — or
`vX.Y.Z-preview0001` for a prerelease — validates that the tag is well-formed and points at
a commit contained in `main`, runs the full CI suite as a release gate by reusing the
workflows above, and publishes to the GitHub Release and the PowerShell Gallery. The version
comes from the tag and is baked into the manifest at build time, so **do not hand-edit
`ModuleVersion`** in `source/Dsc.PipelineRunner.psd1`. Record user-visible changes under
`[Unreleased]` in `CHANGELOG.md` instead, and note there when a change requires a major bump.

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
