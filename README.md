# Dsc.PipelineRunner

## Overview

`Dsc.PipelineRunner` is a platform-agnostic DSC pipeline runner designed to execute DSC configurations within any CI/CD pipeline (GitHub Actions, GitLab, Jenkins, Azure DevOps, and more). It utilizes Datum to merge configuration stubs into larger pieces of configuration, which are then parsed and applied by the runner.

## Datum

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
      condition: $ProjectWorkBoardsStatus -eq 'enabled'
      type: AzureDevOpsDsc/AzDoProjectGroup
      dependsOn:
        - AzureDevOpsDsc/AzDoProject/Project
      properties:
        ProjectName: $ProjectName
        GroupName: $GroupName
    ```

1. __Modular Pipeline Formatting and Validation Rules__: Incorporate modular scripts stored in the `\Pipeline Rules\` directory into the module build process. These scripts are responsible for validating and formatting configuration resources to meet specific requirements. They can be modified and extended as needed. The current set of scripts includes:

    - `Pipeline Rules\PreParse\Test-CircularReferences.ps1`: Checks for circular references within resources. If this script detects an error, the runner will not apply any changes.
    - `Pipeline Rules\PreParse\Test-ResourcesForIncorrectProperties.ps1`: Validates resource properties against documented specifications. Errors prevent the runner from applying changes.
    - `Pipeline Rules\Custom\Sort-DependsOn.ps1`: Orders resources based on their `dependsOn` property. This script is mandatory and cannot be bypassed.
    - `Pipeline Rules\Format\`: Directory reserved for format rules that pre-process task properties before execution.

1. __Versioned Configuration__: Ensure all versions are managed by the pipeline runner to avoid unforeseen issues as new features are introduced.

    __Datum.yml__

    ```yaml
    PipelineRunnerSettings:
      ConfigurationVersion: 0.1
      PipelineRunnerVersion: 0.1
      DSCResourceVersion: 2.0
    ```

    The runner enforces the following version constraints (defined in `source\Public\VersionConfiguration.ps1`):

    | Setting | Minimum | Maximum |
    |---|---|---|
    | `ConfigurationVersion` | `0.1` | `0.9` |
    | `PSDesiredStateConfiguration` module | `2.0` | `2.9` |
    | DSC Resource module | `1.0` | `1.9` |

### Enhanced Pipeline Runner Resource Features

The pipeline runner provides a set of features applicable to all Desired State Configuration (DSC) resources, enhancing their flexibility and control. These features include:

- __condition__: This feature allows conditional execution of resources. The condition is evaluated as a PowerShell expression before the resource runs. If the condition evaluates to `$true`, the resource executes; if it evaluates to `$false`, the resource is skipped. This is useful for dynamically controlling resource execution based on specific criteria.

    __Example:__

    ```yaml
    - name: CON Board Administrators
      condition: $ProjectWorkBoardsStatus -eq 'enabled'
      type: AzureDevOpsDsc/AzDoProjectGroup
    ```

- __postExecutionScript__: This feature triggers a script after the resource has been executed. It can be used to perform additional operations or clean-up tasks following the resource's execution. This is helpful for managing state changes or handling post-execution logic.

    __Example:__

    ```yaml
    - name: Project
      type: AzureDevOpsDsc/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

- __dependsOn__: This feature establishes a dependency chain, ensuring that resources are executed in a specific order. By defining dependencies, you can create a structured sequence of resource execution, where a resource will only run after its dependencies have successfully completed. This is particularly useful in complex configurations where the order of operations is critical.

    __Example:__

    ```yaml
    - name: Default Git Configuration Permissions
      type: AzureDevOpsDsc/AzDoGitPermission
      dependsOn:
        - AzureDevOpsDsc/AzDoProject/Project
        - AzureDevOpsDsc/AzDoProjectGroup/CON Readers
        - AzureDevOpsDsc/AzDoProjectGroup/CON Board Administrators
    ```

These features collectively enhance the robustness and adaptability of DSC resources managed by the pipeline runner, allowing for more precise and context-sensitive configuration management.

### Configuration Specific Commands

In the realm of configuration, there are specialized commands designed to modify the pipeline runner execution process. These commands provide greater control over how configurations are applied and managed. The key commands include:

- _Stop-TaskProcessing_: This command halts the processing of tasks. When executed, any resources scheduled to run after this command will be bypassed, effectively skipping their execution. This is useful for scenarios where you need to prevent certain operations from taking place without altering the entire configuration. For Example:

    ```yaml
    - name: Project
      type: AzureDevOpsDsc/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

    In this scenario, when the project is set for deletion, it will remove the project and subsequently halt any further tasks from executing within the pipeline.

### Deep Dive: Configuration Merging and Executing Process

1. Datum merges the example configuration based on the resolution precedence.
1. Once the YAML file for the project has been generated, Datum will execute any `[x={ $Node.ProjectPresence }=]` script blocks within the `_variables` property.
1. The pipeline runner ingests the configuration, loading and interpolating all variables and parameters into memory.
1. The runner executes the `Pre-Parse` and `Format` rules.
1. The `Resources` are ordered according to the `dependsOn` property.
1. The runner iterates through each of the Resources and performs the following steps:
    1. Checks if `Stop-TaskProcessing` has been executed; if so, the resource will be skipped.
    1. Checks for the `condition` property and evaluates the expression. The resource executes when the condition is `$true`; a `$false` result skips the resource.
    1. Iterates through all the properties within the resource and executes any calculated properties. This includes subexpressions such as:

    ```yaml
    Ensure: $( if ([string]::IsNullOrEmpty($Project_Ensure)) { 'Present' } else { $Project_Ensure } )
    ```

    1. Executes the resource using `Invoke-DscResource`.
    1. Upon completion (even in case of an error), the runner checks for the `postExecutionScript` property and invokes the code if present.
    1. The runner calls the DSC `Get` method on the resource and stores the result in a references table, making it available to subsequent resources via the `reference` function.

## Public Commands

| Command | Description |
|---|---|
| `Invoke-DscPipelineRunner` | Entry point. Clones or reads the Datum configuration, compiles it, authenticates, and invokes the runner for each compiled YAML file. |
| `Build-DatumConfiguration` | Compiles the Datum configuration by resolving all nodes and writing per-project YAML files to the output directory. Runs in a separate runspace. |
| `Test-DatumConfiguration` | Validates a Datum configuration object: checks for `PipelineRunnerSettings`, enforces version constraints, and warns when the configuration version is near the maximum supported version. |
| `Resolve-DscDatumProject` | Resolves a single Datum project node, evaluating variables and converting the result to YAML. Called internally by `Build-DatumConfiguration`. |
| `Stop-TaskProcessing` | Signals the runner to skip all remaining resources in the current YAML file. Must be called from within `postExecutionScript`. |

### `Invoke-DscPipelineRunner` Parameters

| Parameter | Required | Description |
|---|---|---|
| `AzureDevopsOrganizationName` | Yes | Name of the Azure DevOps organization. |
| `exportConfigDir` | Yes | Directory where Datum writes compiled per-project YAML files. Must exist. |
| `ConfigurationSourcePath` | Yes | URL (cloned via git) or local directory path for the Datum configuration. |
| `JITToken` | Yes | Just-In-Time access token. |
| `Mode` | Yes | `Test` (validate only) or `Set` (validate and apply changes). Default: `Test`. |
| `AuthenticationType` | No | `ManagedIdentity` (default) or `PAT`. |
| `PATToken` | When using PAT | 52-character alphanumeric Personal Access Token. |
| `ReportPath` | No | Directory path where a per-project CSV report is written after execution. |

> A cache directory environment variable must be set before calling `Invoke-DscPipelineRunner`. Prefer the generic `PIPELINERUNNER_CACHE_DIRECTORY`; the legacy `AZDODSC_CACHE_DIRECTORY` is still honoured as a back-compat alias. `Invoke-DscRunner` needs neither — pass `-CacheDirectory`, set one of those variables, or let it use a temporary directory.

## Getting Started

1. Clone the repository: `git clone 'https://github.com/ZanattaMichael/Dsc.PipelineRunner' C:\Your-Path`

   > **Note:** The repository will be renamed to `Dsc.PipelineRunner` in a future update.
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

1. __Setup Dsc.PipelineRunner using a Self-Hosted Agent within the CI/CD Pipeline:__

   - Follow the detailed instructions provided in the [Azure DevOps Agents Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents?view=azure-devops) to configure your self-hosted agent.
   - __If Using Managed Identity within Azure Arc:__
     - Verify that the Agent Pool service is executed under an administrator account to ensure proper permissions and functionality.
   - __Grant Permissions for Identity within Azure DevOps (AZDO):__
     - __Using Managed Identity (Virtual Machine):__  
       Refer to the [Managed Identities Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview) for steps on enabling managed identity on virtual machines.
     - __Using Managed Identity for Azure Arc:__  
       Managed identity is already configured. Add the computer account into the Project Collection Administrators group to grant necessary permissions.
     - __If Using Personal Access Token (PAT):__  
       Add the custom identity to Azure DevOps and generate a PAT to authenticate and authorize actions within the pipeline.

1. __Ensure that the Agent Pools have required dependencies__

    Ensure that the Agent Pool is equipped with all necessary PowerShell module dependencies as specified in the module manifest file [`source\Dsc.PipelineRunner.psd1`](.\source\Dsc.PipelineRunner.psd1). The required modules are:

    | Module | Version Constraint |
    |---|---|
    | `PSDesiredStateConfiguration` | `>= 2.0.0` |
    | `powershell-yaml` | `<= 1.0.0` |
    | `AzureDevOpsDsc.Common` | `<= 1.0.0` |
    | `AzureDevOpsDsc` | `<= 1.0.0` |
    | `datum` | `<= 1.0.0` |
    | `Datum.InvokeCommand` | `<= 1.0.0` |

    To install these required modules, execute the following command for each module listed above:

    ```powershell
    Install-Module -Name ModuleName
    ```

    __Process:__

    1. __Review the Module Manifest:__
    - Open the `source\Dsc.PipelineRunner.psd1` file to identify all modules listed under the `RequiredModules` section.
    - Take note of each module name and version specified.

    1. __Install Each Module:__
    - For every module identified, run the `Install-Module` command in a PowerShell session with administrative privileges. Replace `ModuleName` with the actual name of the module you wish to install.
    - Example:

        ```powershell
        Install-Module -Name ModuleName
        ```

    1. __Verify Installation:__
    - After installing each module, confirm its presence by running:

        ```powershell
        Get-Module -ListAvailable -Name ModuleName
        ```

    - This command will list the installed modules and their versions, ensuring they match those required by the manifest.

    1. __Update Modules if Necessary:__
    - If any module is outdated, update it using:

        ```powershell
        Update-Module -Name ModuleName
        ```

    1. __Check Compatibility:__
    - Ensure that the installed modules are compatible with your system and other installed software to prevent conflicts or errors during execution.

    By following these steps, you will ensure that your Agent Pool is fully prepared with all necessary PowerShell dependencies, facilitating seamless operation of your Azure DevOps pipelines.

    > Please Note: Maintaining the correct versioning is crucial to prevent pipeline runner compilation errors. Before proceeding with any updates, always verify that the `PipelineRunnerSettings` within `Datum.yml` are within the ranges enforced by the module. The pipeline runner will reject any configuration that does not meet the specified versioning criteria.

1. __Setup the CI/CD Pipeline:__

    Create a pipeline that calls `Invoke-DscPipelineRunner` on your self-hosted agent. A minimal pipeline looks like:

    ```yaml
    trigger:
      - main

    pool:
      name: SelfHosted

    steps:
      - pwsh: |
          $env:PIPELINERUNNER_CACHE_DIRECTORY = "$(Agent.TempDirectory)\PipelineRunnerCache"
          New-Item -Path $env:PIPELINERUNNER_CACHE_DIRECTORY -ItemType Directory -Force | Out-Null

          Import-Module Dsc.PipelineRunner

          Invoke-DscPipelineRunner `
            -AzureDevopsOrganizationName "$(OrganizationName)" `
            -exportConfigDir "$(Agent.TempDirectory)\ExportedConfig" `
            -ConfigurationSourcePath "$(ConfigurationRepoUrl)" `
            -JITToken "$(System.AccessToken)" `
            -Mode "Set" `
            -AuthenticationType ManagedIdentity
        displayName: 'Apply DSC Configuration'
    ```

    The exported config directory must exist before calling `Invoke-DscPipelineRunner`:

    ```powershell
    New-Item -Path "$(Agent.TempDirectory)\ExportedConfig" -ItemType Directory -Force
    ```

    1. __Test to Ensure the Pipeline Runner is Running Correctly:__

    - __Set the Pipeline Runner Mode to Test:__
        - Pass `-Mode Test` to validate configuration changes without applying them immediately.
    - __Look for Runtime Errors:__
        - Monitor pipeline logs for any runtime errors or warnings that could indicate misconfigurations or issues needing resolution.
    - __Verify Expected Outcomes:__
        - Conduct thorough testing to confirm that the pipeline runner behaves as expected, making adjustments as necessary to address any discrepancies or failures.
    - __Review the CSV Report:__
        - If `-ReportPath` is specified, a per-project CSV report is generated containing the pass/fail/skipped status for every resource. Review this output to verify all resources reached their desired state.
