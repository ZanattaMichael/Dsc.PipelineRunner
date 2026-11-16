<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/header-dark.svg">
    <img src="assets/header-light.svg" alt="Dsc.PipelineRunner: Desired State Configuration in any CI/CD pipeline" height="120">
  </picture>
</h1>

[![Tests](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/CodeCoverage.yml/badge.svg?branch=main)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/CodeCoverage.yml)
[![Lint](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Lint.yml)
[![DSC v3 hosted agent](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/DscV3-HostedAgent.yml/badge.svg?branch=main)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/DscV3-HostedAgent.yml)
[![Integration](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Integration-HostedAgent.yml/badge.svg?branch=main)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Integration-HostedAgent.yml)
[![Release](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Release.yml/badge.svg)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/actions/workflows/Release.yml)

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/Dsc.PipelineRunner?include_prereleases&label=PowerShell%20Gallery&logo=powershell&logoColor=white)](https://www.powershellgallery.com/packages/Dsc.PipelineRunner)
[![Downloads](https://img.shields.io/powershellgallery/dt/Dsc.PipelineRunner?label=downloads)](https://www.powershellgallery.com/packages/Dsc.PipelineRunner)
[![GitHub release](https://img.shields.io/github/v/release/ZanattaMichael/Dsc.PipelineRunner?include_prereleases&label=release)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/releases)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![License: MIT](https://img.shields.io/github/license/ZanattaMichael/Dsc.PipelineRunner)](LICENSE)

[![Security policy](https://img.shields.io/badge/security-policy-blue?logo=github)](SECURITY.md)
[![Build provenance](https://img.shields.io/badge/provenance-attested-success?logo=github)](https://github.com/ZanattaMichael/Dsc.PipelineRunner/attestations)
[![Dependabot](https://img.shields.io/badge/dependabot-enabled-025e8c?logo=dependabot)](.github/dependabot.yml)

## Overview

`Dsc.PipelineRunner` is a platform-agnostic DSC pipeline runner designed to execute DSC configurations within any CI/CD pipeline (GitHub Actions, GitLab, Jenkins, Azure DevOps, and more). It utilizes Datum to merge configuration stubs into larger pieces of configuration, which are then parsed and applied by the runner.

The core module has **no hard dependency on Azure DevOps**. Configuration source
(local directory or git clone), authentication/session setup, and the resource
execution engine (DSC v2's `Invoke-DscResource` or cross-platform DSC v3's `dsc.exe`)
are all pluggable **Actions** — see [Architecture: Actions](#architecture-actions).
Azure DevOps support is one opt-in `Connect` action among several, not a required
module.

> ⚠️ **Security — read this first.** The runner executes your configuration repository as
> **fully-trusted code** (a DSC `Configuration` block is code, not just data). There is no
> sandbox. Protect the configuration repository with the same controls as the runner's own
> source. The runner enforces what it can on the way in — the clone transport must be
> `https`/`ssh`, the revision can be pinned to a verified commit, and clones live in
> owner-only directories that are removed when the run ends (see
> [Configuration source security](#configuration-source-security)) — but none of that
> substitutes for trusting the repository itself. See [SECURITY.md](SECURITY.md) and
> [docs/trust-model.md](docs/trust-model.md).

## How it works

<p align="center">
  <img src="assets/how-it-works.gif" alt="Animation: Datum merges the configuration layers into one file per node; rules check it; each resource is tested and then set; Actions plug in at every step; guard rails and a report with secrets scrubbed" width="800">
</p>

1. **Datum merges your layers** into one compiled file per node, expanding composites.
1. **Rules check it first.** Pre-Parse and Format rules run, and unsafe expressions are refused, before anything changes.
1. **Each resource is tested, then set.** `Test` runs first; `Set` runs only when the resource drifted and the run is in `Set` mode.
1. **Resources declare their own behaviour** in YAML: conditions, ordering, `notify`, targets, credentials and typed parameters.
1. **Actions plug in at every step:** where the configuration comes from, how to authenticate, which engine and which target.
1. **You get a report** (OK, SKIPPED or FAIL per resource) with secrets scrubbed from logs, errors and output.

## Contents

- [Getting Started](#getting-started): install, quick start, and building a configuration
- [Writing a configuration](#writing-a-configuration): Datum, [resource features](#resource-features), composites and run-control commands
- [How a run executes](#how-a-run-executes): the step-by-step lifecycle
- [Architecture: Actions](#architecture-actions): the pluggable Source, Connect, Engine, Target and Credential hooks
- [Public Commands](#public-commands): `Invoke-DscRunner`, `Invoke-DscPipelineRunner` and their parameters
- [Security](#security): [configuration source security](#configuration-source-security) and [supply chain and releases](#supply-chain-and-releases)
- [More documentation](#more-documentation)

## Getting Started

> **Running on a hosted Linux agent with DSC v3?** See
> [docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md) for bootstrapping the `dsc`
> engine, pipeline-native authentication, and workload-identity federation (no stored PAT).

### Install

```powershell
Install-Module Dsc.PipelineRunner -Scope CurrentUser
```

Releases are published to the [PowerShell Gallery](https://www.powershellgallery.com/packages/Dsc.PipelineRunner)
and as [GitHub releases](https://github.com/ZanattaMichael/Dsc.PipelineRunner/releases) with a build
provenance attestation (see [Supply chain and releases](#supply-chain-and-releases)). Add
`-AllowPrerelease` to install a preview.

### Quick start (provider-agnostic)

No Azure DevOps setup required — point `Invoke-DscRunner` at a local directory built
from the `Example Configuration` structure below:

```powershell
Import-Module Dsc.PipelineRunner
Invoke-DscRunner -ConfigurationSourcePath 'C:\Your-Path\Example Configuration' -Mode Test
```

The steps below walk through building that configuration; they apply to any CI/CD system.
Running from Azure DevOps on a self-hosted agent (`Invoke-DscPipelineRunner`, or the
`AzureDevOps` `Connect` action) needs a few more steps, covered in
[docs/azure-devops-self-hosted-agent.md](docs/azure-devops-self-hosted-agent.md).

1. Clone the repository: `git clone 'https://github.com/ZanattaMichael/Dsc.PipelineRunner' C:\Your-Path`
1. Using the `Example Configuration` Directory, create a custom datum directory structure following these guidelines:
   1. __Lower-Level Rules__ should be implemented first, such as organizational policies.
   1. __Intermediate-Level Rules__ apply to groups of projects. For example:

      _datum.yml_

      ```yaml
      ResolutionPrecedence:
          # This is a High-Level Policy
          - Projects\$($Node.ProjectPresence)\$($Node.Project)
          # This is an intermediate level policy. Note that $Node.ProjectArea dictates that there potentially are multiple projects that fall under a "Project Area"
          # These can be specified under a higher level policy.
          - ProjectPolicies\$(Node.ProjectArea)\GitPermissions            
          - ProjectPolicies\$(Node.ProjectArea)\GitRepositories
          - ProjectPolicies\$(Node.ProjectArea)\ProjectGroups
          # This is a Low-Level policy.
          - ProjectPolicies\Project
          - OrganizationPolicies\OrganizationGroups
          - OrganizationPolicies\Organization
      ```

      > __Please Note:__ Lower-level configurations take precedence over higher-level configurations. In the event of a conflict, datum will default to the lower-level settings.

      _`($Node.Project).yaml`_

      ```yaml
      # The Project Area can be specified within the end user yaml file.
      ProjectArea: CustomProjectArea

      parameters: {}

      variables: {
          ProjectDescription: 'Custom Magenta Project. Contact Name: John Doe.',
          ProjectRepositoryName: 'CON_Configuration',
          Project_Service_GitRepositories: 'enabled',
          Project_Service_BuildPipelines: 'enabled',
          Project_Service_AzureArtifact: 'enabled'
      }
      ```

   1. __Higher-Level Rules__ describe lower-level areas and project-specific settings.

      > __Note:__ Please keep changes within the project YAML configuration to a minimum. This ensures that the project does not become a 'snowflake' and remains consistent with established standards and practices. By minimizing deviations, we maintain uniformity across projects, facilitating easier maintenance, scalability, and collaboration among team members. This approach also reduces the risk of introducing unique complexities that could complicate future updates or integrations.

   1. Please note that any adjustments should adhere to the established hierarchy and rules.
   1. As a general guideline, __AVOID__ altering `lookup_options` unless you are fully aware of the implications.

1. __Store the Configuration within the Respective Code Environment:__

   - Ensure that all configuration files and settings are securely stored within the appropriate code environment to maintain consistency and security.
   - Use environment-specific directories or repositories to manage configurations, ensuring easy access and version control.

### Requirements

PowerShell 7 or later, and these modules (installed with the module from the PowerShell Gallery):

| Module | Version Constraint |
|---|---|
| `PSDesiredStateConfiguration` | `>= 2.0.0` |
| `powershell-yaml` | `<= 1.0.0` |
| `datum` | `<= 1.0.0` |
| `Datum.InvokeCommand` | `<= 1.0.0` |

The DSC v3 engine also needs the `dsc` executable: see
[docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md). Azure DevOps support is opt-in and
needs two more modules: see
[docs/azure-devops-self-hosted-agent.md](docs/azure-devops-self-hosted-agent.md).

## Writing a configuration

This module utilizes Datum from Gael Colas to streamline configuration. For more information on how to implement and use it, please refer to the [official documentation or Gael Colas' resources.](https://github.com/gaelcolas/Datum)

### Key Functions

1. __Custom Datum Variable Interpolation__: Perform custom datum variable interpolation before runner initialization using the format `[x={ $Node.Project }=]`.
1. __Calculated Properties__: Utilize PowerShell subexpressions for calculated properties, such as `$( (1 -eq 2 )? $true: $false )`, to dynamically determine values.
1. __Custom Variables__: Define and reference custom variables within resource properties.

    __Variable Configuration__

    ```yaml
    variables:
      ProjectName: 'Test_Project'
      GroupName: 'Custom_Group_Name'
    ```

    __Resource Variable Reference__

    ```yaml
    - name: CON Board Administrators
      preCondition: equals (variables 'ProjectWorkBoardsStatus') 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
      dependsOn:
        - AzureDevOpsDscNative/AzDoProject/Project
      properties:
        ProjectName: $(variables('ProjectName'))
        GroupName: $(variables('GroupName'))
    ```

1. __Modular Pipeline Formatting and Validation Rules__: Incorporate modular scripts stored in the `\Pipeline Rules\` directory into the module build process. These scripts are responsible for validating and formatting configuration resources to meet specific requirements. They can be modified and extended as needed. The current set of scripts includes:

    - `Pipeline Rules\PreParse\Test-CircularReferences.ps1`: Walks the `dependsOn` graph and
      rejects genuine cycles, including a resource that depends on itself. A resource reached
      by more than one branch — a diamond, or any other shared dependency — is not a cycle and
      is allowed. If this script detects an error, the runner will not apply any changes.
    - `Pipeline Rules\PreParse\Test-ResourcesForIncorrectProperties.ps1`: Validates resource properties against documented specifications. Errors prevent the runner from applying changes.
    - `Pipeline Rules\Custom\Sort-DependsOn.ps1`: Orders resources based on their `dependsOn` property. This script is mandatory and cannot be bypassed.
    - `Pipeline Rules\Format\`: Directory reserved for format rules that pre-process task properties before execution.

1. __Versioned Configuration__: Ensure all versions are managed by the pipeline runner to avoid unforeseen issues as new features are introduced.

    __Datum.yml__

    ```yaml
    PipelineRunnerSettings:
      ConfigurationVersion: 0.5
      PipelineRunnerVersion: 1.1.0
      Engine: DscV2
    ```

    `ConfigurationVersion` tracks the configuration's own YAML shape and must be bumped
    whenever the configuration's structure changes; `PipelineRunnerVersion` should reflect
    the `Dsc.PipelineRunner` module version the configuration was authored/tested against
    (`ModuleVersion` in `source/Dsc.PipelineRunner.psd1`).

    The runner enforces the following version constraints (defined in `source\Public\VersionConfiguration.ps1`):

    | Setting | Minimum | Maximum |
    |---|---|---|
    | `ConfigurationVersion` | `0.1` | `0.9` |
    | `PSDesiredStateConfiguration` module | `2.0` | `2.9` |
    | DSC Resource module | `1.0` | `1.9` |

### Resource features

Every resource can carry these keys, whatever its DSC type. Each has examples and the exact rules in
[docs/resource-features.md](docs/resource-features.md).

| Key | What it does |
|---|---|
| `preCondition` | Runs the resource only when the expression is `$true`; otherwise it is skipped. (`condition` is a deprecated alias.) |
| `postCondition` | Asserts the outcome after `Test`/`Set`; a `$false` result marks the resource `FAIL`. Can read `result()` and call `stopProcessing()`. |
| `preExecutionScript` / `postExecutionScript` | Run PowerShell before or after the resource. Off unless `AllowExecutionScripts` is enabled. |
| `PipelineRunnerSettings.AllowExecutionScripts` | The configuration-level opt-in for execution scripts (default `false`). |
| `resourceCredential` | Injects a credential resolved by a `Credential` action into the resource's properties, so it never appears in the file. |
| `dependsOn` | Orders resources: the named resources run first. |
| `notify` / `using()` | Runs this resource before the ones it names, forces them to re-apply when this one changed, and lets them read its output. |
| `<params=Name>` | Replaced by a pipeline parameter with its type intact. |

Conditions and property expressions are restricted to an allow-list of side-effect-free accessors
(`parameters()`, `variables()`, `reference()`, `equals()`, and so on); anything else is rejected.

### Composite Resources

A composite resource is a named, parameterised group of ordinary resources. It is defined once
in `Composites/<Name>.yml` at the root of the configuration repository, and used from any
layer with a single `type: Composite/<Name>` entry. At compile time each instance is expanded
into its member resources, so the runner only ever sees ordinary resources.

```yaml
# Composites/StandardProject.yml
parameters:
  ProjectName:                      # required
  Visibility:
    defaultValue: private
resources:
  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      ProjectName: <composite=ProjectName>
      Visibility: <composite=Visibility>
  - name: Readers
    type: AzureDevOpsDscNative/AzDoProjectGroup
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      ProjectName: <composite=ProjectName>
      GroupName: <composite=ProjectName> Readers
```

```yaml
# Projects/Present/Magenta.yml
resources:
  - name: Magenta
    type: Composite/StandardProject
    properties:
      ProjectName: Magenta
```

This compiles to `AzureDevOpsDscNative/AzDoProject/Magenta::Project` and
`AzureDevOpsDscNative/AzDoProjectGroup/Magenta::Readers`. The instance's `dependsOn`,
`notify`, `preCondition`, `target` and `resourceCredential` are passed on to every member. A
per-instance `overrides` block adjusts individual members. Composites can be nested, and a
`dependsOn` on `Composite/StandardProject/Magenta` waits for the whole group. Every mistake,
such as an unknown composite or a missing parameter, fails the compile and names the instance.
See the [Composite Resources](https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki/Composite-Resources)
wiki page and [docs/composite-resources.md](docs/composite-resources.md).

### Configuration Specific Commands

In the realm of configuration, there are specialized commands designed to modify the pipeline runner execution process. These commands provide greater control over how configurations are applied and managed. The key commands include:

- _Stop-TaskProcessing_: This command halts the processing of tasks. When executed, any resources scheduled to run after this command will be bypassed, effectively skipping their execution. This is useful for scenarios where you need to prevent certain operations from taking place without altering the entire configuration. For Example:

    ```yaml
    - name: Project
      type: AzureDevOpsDscNative/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

    In this scenario, when the project is set for deletion, it will remove the project and subsequently halt any further tasks from executing within the pipeline.

- _stopProcessing()_: the `postCondition`-only counterpart of `Stop-TaskProcessing`. It sets
  the same run-control flag, so the remaining resources in the file are skipped, but it is
  reachable from a `postCondition` expression (which cannot call arbitrary commands) rather
  than only from `preExecutionScript`/`postExecutionScript`:

    ```yaml
    - name: Print Spooler
      type: PSDscResources/Service
      postCondition: result().InDesiredState -or stopProcessing()
    ```

## How a run executes

1. Datum merges the example configuration based on the resolution precedence.
1. Every `type: Composite/<Name>` resource is expanded into the members of its definition
   (`Composites/<Name>.yml`), so the compiled file contains only ordinary resources.
1. Once the YAML file for the project has been generated, Datum will execute any `[x={ $Node.ProjectPresence }=]` script blocks within the `_variables` property.
1. The pipeline runner ingests the configuration, loading and interpolating all variables and parameters into memory.
1. The runner executes the `Pre-Parse` and `Format` rules.
1. Each resource's `notify` property is expanded into an implicit `dependsOn` entry on every
   resource it names, so the notifying resource is guaranteed to run first.
1. The `Resources` are ordered according to the `dependsOn` property (including the implicit
   entries `notify` just added).
1. The runner iterates through each of the Resources and performs the following steps:
    1. Checks if `Stop-TaskProcessing`/`stopProcessing()` has been called; if so, the resource will be skipped.
    1. Checks for the `preCondition` property (the `condition` key still works, as a
       deprecated alias) and evaluates the expression. The resource executes when it is
       `$true`; a `$false` result skips the resource.
    1. Resolves the resource's properties in two passes. The first pass substitutes whole-value
       parameter tokens (`<params=Name>`), which keeps the parameter's type intact; the second
       pass interpolates variables and evaluates any calculated properties. Running them in that
       order means a parameter value that itself contains a subexpression still expands. A property
       may therefore use either form:

       ```yaml
       ServiceName: <params=ServiceName>
       Ensure: $( if ([string]::IsNullOrEmpty((variables 'Project_Ensure'))) { 'Present' } else { variables 'Project_Ensure' } )
       ```

       A token naming an undeclared parameter fails that one resource and is recorded in the run
       report; it is not silently resolved to `$null`, and it does not abort the rest of the file.

    1. Resolves the resource's execution `target` (a per-resource override, falling back to
       `PipelineRunnerSettings.Target`, default `Local`) and its `resourceCredential`, if any,
       through the `Target`/`Credential` action hooks.
    1. If present, runs `preExecutionScript` before the engine call (gated by
       `AllowExecutionScripts`).
    1. Runs the engine's `Test` method. If the resource is already in the desired state **and**
       it was not forced to refresh by a `notify` from a resource that changed on this pass (see
       above), it is marked `OK` and Set is skipped. Otherwise, in `Mode -eq 'Set'`, it runs the
       engine's `Set` method — this covers both genuine drift and a forced-by-notify re-run; in
       `Test` mode, drift with no forcing possible marks the resource `FAIL` instead.
       `Invoke-DscResource` drives `DscV2` (the default), `dsc.exe` drives `DscV3` — passing the
       resolved target session when the resource is not running against `Local`.
    1. If `Set` reports `RebootRequired`: a remote target is restarted (`Restart-Computer
       -Wait`) and the run continues once it is back; a local target fails the resource and
       stops the rest of the file, unless `PipelineRunnerSettings.Reboot: Ignore` is set.
    1. If this resource's own `Test` originally reported it needed a change (not merely a
       forced-by-notify re-run) and it completed successfully, every resource named in its
       `notify` list is marked to be forced through `Set()` on its own turn, once the runner
       reaches it.
    1. Checks for the `postCondition` property and evaluates it; a `$false` result marks the
       resource `FAIL` regardless of the engine's own outcome.
    1. Upon completion (even in case of an error), the runner checks for the `postExecutionScript` property and invokes the code if present.
    1. The runner calls the engine's `Get` method on the resource and stores the result in a references table, making it available to subsequent resources via the `reference` function. It is
       also stored under the resource's full `Type/Name` identity, making it available to any
       resource this one notifies via the `using()` function.

## Architecture: Actions

The runner's lifecycle is split into three pluggable seams, each resolved from a
named file under `Actions/<Hook>/<Name>.ps1` (or overridden inline with a
`[scriptblock]`) — the same loader idiom already used for Pipeline Rules:

| Hook | Purpose | Built-in actions | Config key |
|---|---|---|---|
| `Source` | Resolve the configuration to a local directory | `Local` (default), `Git` | `Source` |
| `Connect` | Establish auth/session before evaluation | `None` (default), `AzureDevOps` | `Connect` |
| `Engine` | Drive resource `Test`/`Set`/`Get` | `DscV2` (default, `Invoke-DscResource`), `DscV3` (`dsc.exe`) | `Engine` |
| `Target` | Resolve the session a resource evaluates against | `Local` (default, no-op), `WinRM` (CimSession + PSSession), `SSH` (PSSession over SSH, DscV3 only) | `PipelineRunnerSettings.Target` / per-resource `target.action` |
| `Credential` | Resolve a `[PSCredential]` for a target connection or a `resourceCredential` | `Environment` (default, from env vars), `Static` (inline, dev/test only), `SecretManagement` (`Get-Secret` from a registered vault) | per-use `action` key (a `target.credential` or `resourceCredential` block) |

Select an action by name in `Datum.yml`:

```yaml
PipelineRunnerSettings:
  Source: Git            # a file in Actions/Source/  (default: Local)
  Connect: AzureDevOps   # a file in Actions/Connect/ (default: None)
  Engine: DscV3          # a file in Actions/Engine/  (default: DscV2)
```

...or per-invocation, or with an inline scriptblock for a bespoke, one-off
solution that doesn't warrant a file:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Engine DscV3 -ConnectAction {
    param($Context)
    Connect-MyPlatform -Token $Context.Token   # any custom auth/session logic
}
```

`Actions/Connect/AzureDevOps.ps1` calls `New-AzDoAuthenticationProvider` only if
`AzureDevOpsDsc.Common` is importable — the core module never loads it and never
lists it in `RequiredModules`. Azure DevOps support is therefore opt-in by naming
the action, not a hard dependency.

The `Engine` hook additionally carries a strict, typed contract: it accepts
`{ Method; ModuleName; Name; Property }` and must return a normalized
`[DscMethodResult]` (`{ InDesiredState; RebootRequired; Message; Raw }`), so
reporting stays engine-independent regardless of which engine ran. See
[docs/dsc-v3.md](docs/dsc-v3.md) for the DSC v3 engine, and
[docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md) for running it on a
hosted Linux agent (bootstrap, engine selection, pipeline-native auth).
[docs/lifecycle-scripting-and-reboot-handling.md](docs/lifecycle-scripting-and-reboot-handling.md)
covers the design behind `preCondition`/`postCondition`/`preExecutionScript`/
`postExecutionScript`, the `stopProcessing()` function-language extension, and
reboot handling for resources that report `RebootRequired` — implemented here
with a simplified fail-and-stop (or `Reboot: Ignore`) policy for local targets
and an in-process `Restart-Computer -Wait` for remote targets, rather than a
full checkpoint/resume across separate runs.
[docs/remote-target-credential-handling.md](docs/remote-target-credential-handling.md)
covers the `Target` and `Credential` action design used for remote-target
execution and `resourceCredential` resolution.
[docs/notify-and-using.md](docs/notify-and-using.md) covers the `notify`/`using()`
resource relationship: the implicit ordering it adds on top of `dependsOn`, the
forced-refresh semantics in `Set` mode, and the declaration-gated visibility
`using()` enforces.

## Public Commands

| Command | Description |
|---|---|
| `Invoke-DscRunner` | Provider-agnostic entry point. Resolves the configured `Source` and `Connect` actions, compiles the Datum configuration, and invokes the runner for each compiled YAML file with the selected `Engine`. |
| `Invoke-DscPipelineRunner` | Azure DevOps back-compat shim. Maps its AzDO-flavored parameters onto `Invoke-DscRunner -Source Git -Connect AzureDevOps` with no functional change for existing callers. |
| `Build-DatumConfiguration` | Compiles the Datum configuration by resolving all nodes and writing per-project YAML files to the output directory. Runs in a separate runspace. |
| `ConvertTo-DscV3ConfigurationDocument` | Converts compiled, runner-specific resources into a schema-compliant DSC v3 configuration document (`$schema` + `name`/`type`/`properties` only) that `dsc config get\|test\|set` accepts. |
| `Test-DatumConfiguration` | Validates a Datum configuration object: checks for `PipelineRunnerSettings`, enforces version constraints, and warns when the configuration version is near the maximum supported version. |
| `Resolve-DscDatumProject` | Resolves a single Datum project node, evaluating variables and converting the result to YAML. Called internally by `Build-DatumConfiguration`. |
| `Stop-TaskProcessing` | Signals the runner to skip all remaining resources in the current YAML file. Must be called from within `preExecutionScript` or `postExecutionScript`; from a `postCondition`, use the `stopProcessing()` function instead. |

### `Invoke-DscRunner` Parameters

| Parameter | Description |
|---|---|
| `ConfigurationSourcePath` | Convenience: a local directory or git URL. Populates the `Source` action's context (`Path` for `Local`, `Url` for `Git`). |
| `Source` / `SourceAction` / `SourceContext` | Name of the `Source` action (default `Local`), an inline scriptblock override, and the hashtable context passed to it. |
| `Connect` / `ConnectAction` / `ConnectContext` | Name of the `Connect` action (default `None`), an inline scriptblock override, and the hashtable context passed to it. |
| `Engine` / `EngineAction` / `EngineVersion` | Name of the execution engine action (default `DscV2`; `DscV3` drives `dsc.exe`; `Auto` detects `dsc` on `PATH`), an inline scriptblock override, and a version hint used to bias `Auto` selection. When `-Engine` is not passed, `PipelineRunnerSettings.Engine` (or the back-compat `DSCResourceVersion` major version) decides. |
| `CacheDirectory` | Directory Datum compiles into. Falls back to `PIPELINERUNNER_CACHE_DIRECTORY` (or the legacy `AZDODSC_CACHE_DIRECTORY` alias), then a fresh temporary directory — no environment variable is required. |
| `ConfigurationRevision` | Branch, tag or commit to check out after cloning a git source. Folded into the `Source` action's context as `Revision`. A full 40-character SHA is verified against the clone's resolved HEAD. |
| `Mode` | `Test` (default, validate only) or `Set` (validate and apply changes). |
| `ReportPath` | Optional directory where a per-project CSV report is written after execution. |
| `FailOnError` | Switch. Sets a non-zero process exit code when the run reports a failure. |
| `KeepTemporaryDirectory` | Switch. Leaves any directory the runner created (a clone, a temporary cache) in place instead of removing it when the run ends. A caller-supplied local path is never removed. |

```powershell
# Local directory, no authentication, DSC v2 engine (all defaults).
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Test

# Git source, Azure DevOps auth, DSC v3 engine.
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repoUrl } `
                 -Connect AzureDevOps -ConnectContext @{ OrganizationName = 'MyOrg'; AuthenticationType = 'PAT'; PATToken = $pat } `
                 -Engine DscV3
```

### `Invoke-DscPipelineRunner` Parameters

> New integrations should prefer `Invoke-DscRunner`. `Invoke-DscPipelineRunner` remains
> as a back-compat shim for existing Azure DevOps pipelines and requires the
> `AzureDevOpsDsc.Common` module to be installed separately (it is no longer a
> `RequiredModules` dependency of the core module).

| Parameter | Required | Description |
|---|---|---|
| `AzureDevopsOrganizationName` | Yes | Name of the Azure DevOps organization. |
| `ExportConfigDir` | Yes | Directory where Datum writes compiled per-project YAML files. Must exist. |
| `ConfigurationSourcePath` | Yes | `https`/`ssh` URL (cloned via git) or local directory path for the Datum configuration. |
| `ConfigurationRevision` | No | Branch, tag or commit to check out after cloning. A full 40-character SHA is verified against the clone's resolved HEAD. |
| `JITToken` | No | Just-In-Time access token used for the clone. A `[SecureString]` or a plain string; falls back to `$env:SYSTEM_ACCESSTOKEN`. |
| `Mode` | No | `Test` (default, validate only) or `Set` (validate and apply changes). |
| `PATToken` | Only for PAT auth | Personal Access Token, 20–120 alphanumeric characters. Supplying it selects the PAT parameter set; omit it to authenticate with a managed identity. |
| `ReportPath` | No | Directory path where a per-project CSV report is written after execution. |
| `FailOnError` | No | Switch. Sets a non-zero process exit code when the run reports a failure. |
| `KeepTemporaryDirectory` | No | Switch. Leaves a cloned configuration in place instead of removing it when the run ends. |

> **Breaking change.** `-exportConfigDir` is now `-ExportConfigDir`, and
> `-AuthenticationType` has been removed: supplying `-PATToken` selects PAT
> authentication and omitting it uses the managed identity. Previously
> `-AuthenticationType` defaulted independently of the token, so a caller who passed
> `-PATToken` still went down the managed-identity path. `-Mode` and `-JITToken` are no
> longer mandatory.

> A cache directory environment variable must be set before calling `Invoke-DscPipelineRunner`. Prefer the generic `PIPELINERUNNER_CACHE_DIRECTORY`; the legacy `AZDODSC_CACHE_DIRECTORY` is still honoured as a back-compat alias. `Invoke-DscRunner` needs neither — pass `-CacheDirectory`, set one of those variables, or let it use a temporary directory.

## Security

The configuration repository is executed as trusted code: see the note in the [Overview](#overview),
[SECURITY.md](SECURITY.md) and [docs/trust-model.md](docs/trust-model.md).

### Configuration source security

Both entry points harden the path between the configuration repository and the runner. None
of it is optional, and none of it needs configuring:

- **The clone transport is enforced, not recommended.** Only `https`, `ssh` and SCP-style
  `git@host:path` remotes are accepted. A plain `http://` URL is rejected with a terminating
  error naming the scheme — the configuration runs as trusted code in the runner's own
  security context, so fetching it over a transport that can be tampered with is a remote
  code-execution path, not a style preference.
- **Pin the revision.** `-ConfigurationRevision` checks out a branch, tag or commit after the
  clone. Supply a full 40-character commit SHA and the pin is exact: the clone's resolved
  `HEAD` is verified against it and a mismatch fails the run. Whatever you pass, the resolved
  `HEAD` SHA is written to the information stream, so the pipeline log records the commit that
  actually ran.
- **Credentials never reach the command line.** The token is injected as an HTTP
  `Authorization` header through git's environment-based configuration, scoped to the origin
  of the configured remote so git never presents it to another host, and scrubbed from
  everything git prints. Pass a `[SecureString]` or a plain string; with neither,
  `$env:SYSTEM_ACCESSTOKEN` is used when it is set. The same rule holds for the DSC v3 engine:
  resolved credentials reach `dsc` on standard input, not as an argument.
- **Temporary directories are owner-only and removed.** A clone (or a fallback cache
  directory) is created with owner-only permissions — `0700` on Unix, a single full-control ACE
  on Windows — and deleted when the run ends, including when it ends by throwing. Only a
  directory the runner itself created is ever deleted; a path you supplied is left alone. Pass
  `-KeepTemporaryDirectory` to keep a clone for debugging.

### Supply chain and releases

What the runner installs, downloads and publishes is pinned and checked, so a moved tag, a bad
download or a new upstream release cannot change what runs without a change in this repository.
[SECURITY.md](SECURITY.md) has the full summary and the tests that hold each point.

| What | How it is controlled |
|---|---|
| **PowerShell Gallery modules** | CI, the container image and the build install each module at one exact version, listed in [`scripts/module-versions.json`](scripts/module-versions.json) and installed through [`scripts/Install-PinnedModule.ps1`](scripts/Install-PinnedModule.ps1), which retries a failed download and checks the version it installed. A test fails if a bare `Install-Module` is added. |
| **The `dsc` engine (DSC v3)** | [`scripts/Install-DscV3.ps1`](scripts/Install-DscV3.ps1) checks the archive's SHA-256 against [`scripts/dsc-checksums.json`](scripts/dsc-checksums.json) *before* extracting it, and refuses to install when it has nothing to check against. |
| **GitHub Actions** | Every third-party action is pinned to a commit SHA, and Dependabot proposes updates. |
| **Container image** | The base image is pinned by digest, the `dsc` install is verified as above, and the image runs as a non-root user. |
| **Releases** | A release is a tag. The package is built from that tag, tested by the full CI suite, published, and recorded with a signed build provenance attestation. |

**Updating the pinned Gallery modules.** Dependabot does not read the PowerShell Gallery, so run
**Actions → Update module versions → Run workflow**. It lists the pinned and newest version of every
module and uploads a proposed `module-versions.json`; review the difference, commit it in a pull
request, and CI runs the whole suite against the new versions before they merge. The same check runs
on any pull request that touches the lock file and fails if a pinned version has left the Gallery.
To install the pinned versions yourself (for example on an agent pool):

```powershell
./scripts/Install-PinnedModule.ps1 -Name Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration
```

**Verifying a release.** Download the `.nupkg` from the GitHub release and check where it came from:

```bash
gh attestation verify Dsc.PipelineRunner.<version>.nupkg --repo ZanattaMichael/Dsc.PipelineRunner
```

This proves which workflow run built the file from which commit. It is not an Authenticode
signature, so PowerShell's `AllSigned` execution policy does not use it.

**Cutting a release** (maintainers). Run **Actions → Create release tag → Run workflow** from `main`,
choose `preview` or `release` and a `bump` (or an explicit `version`), and tick `dry_run` first to see
the tag it would create. It refuses to continue unless every check on `main` is passing, creates the
annotated tag and starts the Release workflow on it. See [CONTRIBUTING.md](CONTRIBUTING.md#releasing).

## More documentation

| Topic | Where |
|---|---|
| Every resource key, with examples | [docs/resource-features.md](docs/resource-features.md) |
| Composite resources | [docs/composite-resources.md](docs/composite-resources.md) |
| `notify` and `using()` | [docs/notify-and-using.md](docs/notify-and-using.md) |
| Conditions, execution scripts and reboot handling | [docs/lifecycle-scripting-and-reboot-handling.md](docs/lifecycle-scripting-and-reboot-handling.md) |
| Remote targets and credentials | [docs/remote-target-credential-handling.md](docs/remote-target-credential-handling.md) |
| The DSC v3 engine | [docs/dsc-v3.md](docs/dsc-v3.md), [docs/dsc-v3-config-functions.md](docs/dsc-v3-config-functions.md) |
| Hosted Linux agents with DSC v3 | [docs/hosted-agent-dsc-v3.md](docs/hosted-agent-dsc-v3.md) |
| Azure DevOps self-hosted agent and pipeline | [docs/azure-devops-self-hosted-agent.md](docs/azure-devops-self-hosted-agent.md) |
| Trust model and security policy | [docs/trust-model.md](docs/trust-model.md), [SECURITY.md](SECURITY.md) |
| Contributing and releasing | [CONTRIBUTING.md](CONTRIBUTING.md) |
