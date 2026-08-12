# AzDO-DSC-LCM

## Overview

`AzDO-DSC-LCM` is the Local Configuration Manager (LCM) component for the `AzureDevOpsDsc` DSC Module. This module helps manage Azure DevOps resources through Desired State Configuration (DSC). Utilizes Datum to merge configuration stubs into larger pieces of configuration which is parsed into the LCM.

> **For developers and LLM context**: See [`CLAUDE.md`](CLAUDE.md) for an in-depth guide to the codebase, configuration processing pipeline, validation rules, and integration points with AzureDevOpsDsc.

## Authentication and Integration with AzureDevOpsDsc

The LCM depends on the `AzureDevOpsDsc` module for DSC resource execution. Before running the LCM, ensure:

1. **AzureDevOpsDsc is deployed** to the agent pool in `C:\Users\<user>\Documents\PowerShell\Modules\AzureDevOpsDsc\0.0.2\`
2. **ModuleSettings.clixml exists** at `$ENV:AZDODSC_CACHE_DIRECTORY\ModuleSettings.clixml`
   - This file stores the Azure DevOps organization name and authentication token (DPAPI-encrypted)
   - Created during AzureDevOpsDsc initialization
3. **Authentication credentials are configured**:
   - Personal Access Token (PAT): Store in `ModuleSettings.clixml` via `AzureDevOpsDsc` setup
   - Managed Identity: Ensure the agent service account has Azure AD permissions
   - Service Principal: Configure via AzureDevOpsDsc authentication helpers

The LCM automatically reads `ModuleSettings.clixml` and passes the organization name and token to each DSC resource during execution. **Do not call authentication helpers directly from the LCM** — they are internal to AzureDevOpsDsc resource classes.

For authentication details, see the [AzureDevOpsDsc documentation](https://github.com/ZanattaMichael/AzureDevOpsDsc/blob/main/CLAUDE.md).

## Datum

This LCM utilizes Datum from Gael Colas to streamline configuration. For more information on how to implement and use it, please refer to the [official documentation or Gael Colas' resources.](https://github.com/gaelcolas/Datum)

### Key Functions

1. __Custom Datum Variable Interpolation__: Perform custom datum variable interpolation before LCM initialization using the format `[x={ $Node.Project }=]`.
1. __LCM-Based Calculated Properties__: Utilize PowerShell subexpressions for calculated properties, such as `$( (1 -eq 2 )? $true: $false )`, to dynamically determine values.
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

1. __Modular LCM Formatting and Validation Rules__: Incorporate modular scripts stored in the `\LCM Rules\` directory into the module build process. These scripts are responsible for validating and formatting configuration resources to meet specific requirements. They can be modified and extended as needed. The current set of scripts includes:

    - `LCM Rules\PreParse\Test-CircularReferences.ps1`: Checks for circular references within resources. If this script detects an error, the LCM will not apply any changes.
    - `LCM Rules\PreParse\Test-ResourceForIncorrectProperties`: Validates resource properties against documented specifications. Errors prevent LCM from applying changes.
    - `LCM Rules\Custom\Sort-DependsOn.ps1`: Orders resources in the YAML file based on their `dependsOn` property. This script is mandatory and cannot be bypassed.

1. __Versioned Configuration__: Ensure all versions are managed by the LCM to avoid unforeseen issues as new features are introduced.

    __Datum.yml__

    ```yaml
    LCMConfigSettings:
      ConfigurationVersion: 1.0
      AZDOLCMVersion: 1.0
      DSCResourceVersion: 1.0
    ```

### Enhanced LCM Resource Features

The Local Configuration Manager (LCM) provides a set of features applicable to all Desired State Configuration (DSC) resources, enhancing their flexibility and control. These features include:

- __condition__: This feature allows conditional execution of resources. The condition is evaluated before the resource runs, and if it evaluates to `$true`, the resource is skipped. This is useful for dynamically controlling resource execution based on specific criteria.

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

These features collectively enhance the robustness and adaptability of DSC resources managed by the LCM, allowing for more precise and context-sensitive configuration management.

### Configuration Specific Commands

In the realm of configuration, there are specialized commands designed to modify the Local Configuration Manager (LCM) execution process. These commands provide greater control over how configurations are applied and managed. The key commands include:

- _Stop-TaskProcessing_: This command halts the processing of tasks. When executed, any resources scheduled to run after this command will be bypassed, effectively skipping their execution. This can be useful for scenarios where you need to prevent certain operations from taking place without altering the entire configuration. For Example:

    ```yaml
    - name: Project
        type: AzureDevOpsDsc/AzDoProject
        postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

    In this scenario, when the project is set for deletion, it will remove the project and subsequently halt any further tasks from executing within the pipeline.

### Deep Dive: Configuration Merging and Executing Process

1. Datum merges the example configuration based on the resolution precedence.
1. Once the YAML file for the project has been generated, Datum will execute any `[x={ $Node.ProjectPresence }=]` script blocks within the `_variables` property.
1. The LCM (Local Configuration Manager) ingests the configuration, loading and interpolating all variables and parameters into memory.
1. The LCM runs the `Pre-Parse` and `Format` rules.
1. The `Resources` are ordered according to the `dependsOn` property.
1. The LCM iterates through each of the Resources and performs the following steps:
    1. Checks if `Stop-TaskProcessing` has been executed; if so, the resource will be skipped.
    1. Checks for the `condition` property and executes the statement. The resource will execute on a `$true` response.
    1. Iterates through all the properties within the resource and executes any calculated properties. This includes variables such as:

    ```yaml
    Ensure: $( if ([string]::IsNullOrEmpty($Project_Ensure)) { 'Present' } else { $Project_Ensure } )
    ```

    1. Executes the resource.
    1. Upon completion (even in case of an error), the LCM checks for the `postExecutionScript` property and invokes the code if present.

    ``` YAML
    Ensure: $( if ([string]::IsNullOrEmpty($Project_Ensure)) { 'Present' } else { $Project_Ensure } )
    ```

    1. The resource is executed.
    1. Once completed (_even on error_). The LCM will check for the `postExecutionScript` property. It will invoke the code.

## Getting Started

1. Clone the repository: `git clone 'https://github.com/ZanattaMichael/AzDO-DSC-LCM' C:\Your-Path`
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

1. __Setup the Local Configuration Manager (LCM) using a Self-Hosted Agent within the Azure DevOps Pipeline:__

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

    Ensure that the Agent Pool is equipped with all necessary PowerShell module dependencies as specified in the module manifest file [`source\azdo-dsc-lcm.psd1`](.\source\azdo-dsc-lcm.psd1). These dependencies are crucial for the proper functioning of the Local Configuration Manager (LCM) within your Azure DevOps environment.

    To install these required modules, execute the following command for each module listed in the manifest:

    ```powershell
    Install-Module -Name ModuleName
    ```

    __Process:__

    1. __Review the Module Manifest:__
    - Open the `source\azdo-dsc-lcm.psd1` file to identify all modules listed under the `RequiredModules` section.
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

    > Please Note: Maintaining the correct versioning is crucial to prevent LCM compilation errors. Before proceeding with any updates, always verify that the LCMConfigSettings within Datum.yml are compatible. The Local Configuration Manager will reject any configuration that does not meet the specified versioning criteria.

1. __Setup the Azure DevOps Pipeline:__

    - The self-hosted agent pool must have the `azdo-dsc-lcm` module deployed and the `AzureDevOpsDsc` module configured with authentication credentials stored in `ModuleSettings.clixml`.
    - Create a pipeline YAML that calls `Invoke-AZDoLCM` with the path to your Datum configuration:
      ```powershell
      Invoke-AZDoLCM -ConfigurationPath '$(System.DefaultWorkingDirectory)\Configuration' -Verbose
      ```
    - The LCM will merge all configuration policies via Datum, validate rules, and orchestrate DSC resource execution against your Azure DevOps organization.
    - For detailed LCM architecture and configuration processing, see [`CLAUDE.md`](CLAUDE.md).

    1. __Test to Ensure the LCM is Running Correctly:__

    - __Set the LCM Mode to Test:__
        - Switch the LCM to test mode to validate configuration changes without applying them immediately.
    - __Look for Runtime Errors:__
        - Monitor logs and outputs for any runtime errors or warnings that could indicate misconfigurations or issues needing resolution.
    - __Verify Expected Outcomes:__
        - Conduct thorough testing to confirm that the LCM behaves as expected, making adjustments as necessary to address any discrepancies or failures.