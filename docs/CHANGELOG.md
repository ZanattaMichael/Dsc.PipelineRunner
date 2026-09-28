# Dsc.PipelineRunner — Changelog & Migration Guide

> **Branch:** `claude/documentation-updates-7wfooc`  
> **Date:** September 2026  
> **Type:** Breaking Change, CI/CD, Documentation

---

## Table of Contents

1. [Module & Package Rename](#1-module--package-rename)
2. [Function Renames](#2-function-renames)
3. [Directory & File Renames](#3-directory--file-renames)
4. [Configuration Key Changes](#4-configuration-key-changes)
5. [Module Manifest Fixes](#5-module-manifest-fixes)
6. [Test Suite Updates](#6-test-suite-updates)
7. [GitHub Actions Workflows](#7-github-actions-workflows)
8. [GitHub Issues Updated](#8-github-issues-updated)
9. [README Updates](#9-readme-updates)
10. [Migration Checklist](#10-migration-checklist)

---

## 1. Module & Package Rename

> ⚠ **Breaking Change** — all `Import-Module` and `Install-Module` calls must be updated.

| Old | New |
|-----|-----|
| `AZDO-DSC-LCM` | `Dsc.PipelineRunner` |
| `AZDO-DSC-LCM.psd1` | `Dsc.PipelineRunner.psd1` |
| `AZDO-DSC-LCM.psm1` | `Dsc.PipelineRunner.psm1` |

```powershell
# Before
Import-Module AZDO-DSC-LCM

# After
Import-Module Dsc.PipelineRunner
```

---

## 2. Function Renames

> ⚠ **Breaking Change** — scripts calling these functions must be updated.

| Old | New |
|-----|-----|
| `Start-LCM` | `Start-DscRunner` |
| `Invoke-LCM` | `Invoke-DscRunner` |
| `Get-LCMStatus` | `Get-DscRunnerStatus` |

```powershell
# Before
Start-LCM -ConfigurationData $data -Verbose

# After
Start-DscRunner -ConfigurationData $data -Verbose
```

---

## 3. Directory & File Renames

| Old | New |
|-----|-----|
| `source/Private/LCM/` | `source/Private/Runner/` |
| `Tests/LCM/` | `Tests/PipelineRunner/` |
| `LCM Rules/` | `Pipeline Rules/` |
| `source/Classes/LCMConfigSettings.ps1` | `source/Classes/PipelineRunnerSettings.ps1` |

---

## 4. Configuration Key Changes

> ⚠ **Breaking Change** — Datum YAML configuration files must be updated.

| Old | New |
|-----|-----|
| `LCMConfigSettings` | `PipelineRunnerSettings` |
| `AZDOLCMVersion` | `PipelineRunnerVersion` |
| `LCMRules` | `PipelineRules` |

```yaml
# Before
LCMConfigSettings:
  AZDOLCMVersion: '1.0.0'
  LCMRules:
    - Name: MyRule

# After
PipelineRunnerSettings:
  PipelineRunnerVersion: '2.0.0'
  PipelineRules:
    - Name: MyRule
```

---

## 5. Module Manifest Fixes

- **HelpInfoURI**: Replaced placeholder `http://www.example.com/` with valid GitHub URL
- **ProjectURI & LicenseURI**: Updated to correct GitHub repository and license URLs
- **FunctionsToExport**: Updated to export `Start-DscRunner` (was still exporting `Start-LCM`)
- **Tags**: Updated from `@('AZDO-DSC-LCM', 'DSC', 'LCM')` to `@('Dsc.PipelineRunner', 'DSC', 'Azure', 'AzureDevOps', 'Pipeline')`
- **Internal variables**: Audit pass corrected `$LCM*` variables → `$Runner*`; fixed code-coverage output path

---

## 6. Test Suite Updates

- Pester tags updated: `-Tag 'LCM'` → `-Tag 'PipelineRunner'`
- All `Start-LCM` calls in tests updated to `Start-DscRunner` (including mocks)
- Test results path: `output/testResults/LCM.TestResults.xml` → `output/testResults/PipelineRunner.TestResults.xml`

---

## 7. GitHub Actions Workflows

**Root cause fixed:** bare `push:` trigger fires on every branch, causing 4 runs per push on a PR branch.  
**Fix:** all workflows now scope `push:` to `branches: [ "main" ]`.

### Workflow Inventory

| File | Runner | Triggers | Purpose | Status |
|------|--------|----------|---------|--------|
| `Lint.yml` | ubuntu-latest | push→main, pull_request | PSScriptAnalyzer + SARIF upload | ✅ New |
| `CodeCoverage.yml` | ubuntu-latest | push→main, pull_request | Pester + code coverage | 🔧 Fixed |
| `DscV3-HostedAgent.yml` | ubuntu-latest | push→main, pull_request | DSC v3 smoke + Docker image | ✅ New |
| `DscV2-SelfHosted.yml` | self-hosted | push→main, workflow_dispatch | DSC v2 engine smoke + integration | ✅ New |
| `AzureDevOps-SelfHosted.yml` | self-hosted | push→main, workflow_dispatch | Real AzDO lifecycle (DSC v2) | ✅ New |
| `AzureDevOpsV3-SelfHosted.yml` | self-hosted | push→main, workflow_dispatch | Real AzDO lifecycle (DSC v3) | ✅ New |
| `codeql.yml` | — | — | Was misconfigured for `csharp` | ❌ Deleted |

### Expected Run Count

| Event | Hosted | Self-Hosted | Total |
|-------|--------|------------|-------|
| Push to PR branch | 3 | 0 | **3** |
| Merge to main | 3 | 3 | **6** |

Self-hosted workflows exclude `pull_request:` because they require a registered Windows runner with managed identity and a live Azure DevOps organisation — prerequisites unavailable on hosted runners.

---

## 8. GitHub Issues Updated

All **34 open issues** (#5–#38) were updated with new naming throughout titles and bodies.

**Substitutions applied:**

- `AZDO-DSC-LCM` → `Dsc.PipelineRunner`
- `Start-LCM` → `Start-DscRunner`
- `LCMConfigSettings` → `PipelineRunnerSettings`
- `AZDOLCMVersion` → `PipelineRunnerVersion`
- `LCM Rules` → `Pipeline Rules`
- `LCMRules` → `PipelineRules`

Issues with title changes: #15, #17, #19, #20, #21, #28.

---

## 9. README Updates

Complete rewrite with accurate module name, correct function examples (`Start-DscRunner`), updated architecture description covering DSC v2 and v3 engines, correct prerequisites, and links to new workflow files.

---

## 10. Migration Checklist

- [ ] `Import-Module AZDO-DSC-LCM` → `Import-Module Dsc.PipelineRunner`
- [ ] `Install-Module AZDO-DSC-LCM` → `Install-Module Dsc.PipelineRunner`
- [ ] All calls to `Start-LCM` → `Start-DscRunner`
- [ ] Datum YAML: `LCMConfigSettings` → `PipelineRunnerSettings`
- [ ] Datum YAML: `AZDOLCMVersion` → `PipelineRunnerVersion`
- [ ] Datum YAML: `LCMRules` → `PipelineRules`
- [ ] Directory: `LCM Rules/` → `Pipeline Rules/`
- [ ] Pester tags: `-Tag 'LCM'` → `-Tag 'PipelineRunner'`
- [ ] Test results: `output/testResults/LCM.*` → `output/testResults/PipelineRunner.*`
- [ ] CI: scope `push:` to `branches: [ "main" ]` to prevent duplicate runs
