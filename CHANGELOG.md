# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Breaking Changes — Module Renamed to `Dsc.PipelineRunner`

The module has been renamed from `AZDO-DSC-LCM` to `Dsc.PipelineRunner` to better reflect its purpose as a platform-agnostic DSC pipeline runner that works with GitHub Actions, GitLab CI, Jenkins, Azure DevOps, and any other CI/CD environment.

#### What Changed

| Before | After |
|---|---|
| Module name: `azdo-dsc-lcm` | Module name: `Dsc.PipelineRunner` |
| Manifest: `source/azdo-dsc-lcm.psd1` | Manifest: `source/Dsc.PipelineRunner.psd1` |
| Root module: `azdo-dsc-lcm.psm1` | Root module: `Dsc.PipelineRunner.psm1` |
| Command: `Invoke-AZDoLCM` | Command: `Invoke-DscPipelineRunner` |
| Command: `Resolve-AzDoDatumProject` | Command: `Resolve-DscDatumProject` |
| Rules directory: `LCM Rules\` | Rules directory: `Pipeline Rules\` |
| Config key: `LCMConfigSettings` | Config key: `PipelineRunnerSettings` |
| Config key: `AZDOLCMVersion` | Config key: `PipelineRunnerVersion` |

#### Migration Guide

##### 1. Update `Import-Module`

```powershell
# Before
Import-Module azdo-dsc-lcm

# After
Import-Module Dsc.PipelineRunner
```

##### 2. Update Command Calls

```powershell
# Before
Invoke-AZDoLCM -AzureDevopsOrganizationName "MyOrg" ...

# After
Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" ...
```

```powershell
# Before
Resolve-AzDoDatumProject -NodeName $node -AllNodes $allNodes

# After
Resolve-DscDatumProject -NodeName $node -AllNodes $allNodes
```

##### 3. Update `Datum.yml`

```yaml
# Before
LCMConfigSettings:
  ConfigurationVersion: 0.1
  AZDOLCMVersion: 0.1
  DSCResourceVersion: 2.0

# After
PipelineRunnerSettings:
  ConfigurationVersion: 0.1
  PipelineRunnerVersion: 0.1
  DSCResourceVersion: 2.0
```

##### 4. Rename Custom Rules Directory

If you have extended the module with custom rules, rename your local copy of `LCM Rules\` to `Pipeline Rules\`. The subdirectory structure (`Custom\`, `Format\`, `PreParse\`) remains unchanged.

#### Motivation

- **Decoupling**: The `AZDO` prefix falsely implied an exclusive dependency on Azure DevOps. The module works with any CI/CD platform.
- **Architectural accuracy**: `LCM` referred to the deprecated Windows DSC Local Configuration Manager (v2). This tool is an external orchestrator aligned with DSC v3's CLI-driven model, making `Runner` the technically correct term.
- **Ecosystem alignment**: The `Dsc.` prefix follows modern community conventions (e.g., `Dsc.ResourceKit`), improving discoverability in the PowerShell Gallery.
