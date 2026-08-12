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

## Module Overview

The AzDO-DSC-LCM module exports five public cmdlets for configuration management and testing:

| Cmdlet | Purpose |
|--------|---------|
| `Build-DatumConfiguration` | Merge YAML configuration files via Datum into a single configuration object |
| `Invoke-AZDoLCM` | Orchestrate DSC resource execution against merged configuration |
| `Resolve-AzDoDatumProject` | Resolve project-specific Datum configuration based on node properties |
| `Stop-TaskProcessing` | Halt execution of remaining resources in the pipeline |
| `Test-DatumConfiguration` | Validate configuration syntax and structure without executing resources |

For detailed information about module structure, dependencies, and integration points, see [`CLAUDE.md`](CLAUDE.md).

## Datum Configuration Engine

The LCM uses Datum from Gael Colas to merge hierarchical YAML configuration files. For more information, refer to the [official Datum documentation](https://github.com/gaelcolas/Datum).

### Key Features and Functions

1. **Custom Datum Variable Interpolation**: Execute Datum script blocks during configuration merge using the format `[x={ $Node.Project }=]` to inject dynamic values.

1. **LCM-Based Calculated Properties**: Use PowerShell expressions in resource properties to dynamically compute values, e.g., `$( (1 -eq 2 ) ? $true : $false )`.

1. **Custom Variables**: Define reusable variables in YAML and reference them across resource properties:

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

1. __Modular LCM Validation and Formatting Rules__: Modular scripts stored in the `LCM Rules\` directory validate and transform configuration during the build process. These scripts can be modified and extended as needed:

    **Pre-Parse Validation Rules** (`LCM Rules\PreParse\`):
    - `Test-CircularReferences.ps1`: Detects circular dependencies in `dependsOn` chains. Aborts with error if violations found.
    - `Test-ResourceForIncorrectProperties.ps1`: Validates resource properties against documented specifications. Rejects invalid properties before execution.

    **Custom Formatting Rules** (`LCM Rules\Custom\`):
    - `Sort-DependsOn.ps1`: Reorders resources in YAML according to `dependsOn` declarations. **Mandatory and cannot be bypassed.**

1. __Versioned Configuration__: Ensure all versions are managed by the LCM to avoid unforeseen issues as new features are introduced.

    __Datum.yml__

    ```yaml
    LCMConfigSettings:
      ConfigurationVersion: 1.0
      AZDOLCMVersion: 1.0
      DSCResourceVersion: 1.0
    ```

### Resource-Level Features

The LCM provides powerful features for controlling resource execution and managing dependencies:

- __condition__: This feature allows conditional execution of resources. The condition is evaluated before the resource runs, and if it evaluates to `$false`, the resource is skipped. This is useful for dynamically controlling resource execution based on specific criteria.

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

#### Halting Execution with Stop-TaskProcessing

Use the `Stop-TaskProcessing` cmdlet in `postExecutionScript` to prevent downstream resources from executing:

```yaml
- name: Project Deletion
  type: AzureDevOpsDsc/AzDoProject
  properties:
    ProjectName: MyProject
    Ensure: Absent
  postExecutionScript: |
    if ($MyProject_Ensure -eq 'Absent') {
      Stop-TaskProcessing  # Skip all remaining resources
    }
```

This is useful when earlier resource actions make later resources unnecessary or when cleanup operations should terminate the pipeline.

### Configuration Processing Pipeline

The LCM follows a specific sequence when applying configuration:

1. **Datum Merges** configuration files in reverse-precedence order (lowest → highest priority)
2. **Variable Interpolation** executes Datum script blocks (e.g., `[x={ $Node.ProjectPresence }=]`)
3. **LCM Loads** merged configuration and interpolates all variables into memory
4. **Pre-Parse Rules** validate circular dependencies and resource properties
5. **DependsOn Sort** reorders resources according to their dependency declarations
6. **Resource Execution** processes each resource in order:
   - Checks if `Stop-TaskProcessing` has been invoked (skips remaining resources if true)
   - Evaluates the `condition` property (skips resource if `$false`)
   - Interpolates calculated properties using PowerShell expressions
   - Executes the DSC resource via `Invoke-DscResource`
   - Runs `postExecutionScript` if present (even if resource failed)

## Getting Started

### Step 1: Clone the Repository

```bash
git clone 'https://github.com/ZanattaMichael/AzDO-DSC-LCM' C:\Your-Path
```

### Step 2: Create Configuration Hierarchy

Using the `Example Configuration` directory as a template, create a custom Datum structure. The `ResolutionPrecedence` in `Datum.yml` determines merge order — configurations listed first have highest priority (lowest level overrides highest level):

**Example Datum.yml ResolutionPrecedence:**
```yaml
ResolutionPrecedence:
  - Projects\$($Node.ProjectPresence)\$($Node.Project)           # Project-specific (highest priority)
  - ProjectPolicies\$($Node.ProjectArea)\GitPermissions          # Project area policies
  - ProjectPolicies\$($Node.ProjectArea)\GitRepositories
  - ProjectPolicies\$($Node.ProjectArea)\ProjectGroups
  - ProjectPolicies\Project                                       # General project policies
  - OrganizationPolicies\OrganizationGroups                       # Organization-wide policies
  - OrganizationPolicies\Organization                             # (lowest priority)
```

**Example Project Configuration (`ProjectArea/Project.yaml`):**
```yaml
ProjectArea: CustomProjectArea
parameters: {}
variables:
  ProjectDescription: 'Custom Project. Contact: John Doe.'
  ProjectRepositoryName: 'Configuration'
  Project_Service_GitRepositories: 'enabled'
  Project_Service_BuildPipelines: 'enabled'
```

**Configuration Design Principles:**
- Project YAML files should contain only project-specific values
- Avoid "snowflake" configurations by minimizing project-level overrides
- Keep common settings in organizational or project-area policies
- Do not modify `lookup_options` unless you fully understand Datum's behavior

### Step 3: Store Configuration in Code Repository

Ensure all configuration files are stored securely in a code repository for version control and consistency:
- Use separate directories for environment-specific configurations
- Maintain clear separation between organizational, project-area, and project-level policies
- Document configuration changes through commits

### Step 4: Configure Self-Hosted Agent Pool

Follow the [Azure DevOps Agents Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents?view=azure-devops) to set up your self-hosted agent pool.

**Identity and Permissions:**
- **Managed Identity (VM):** Refer to [Managed Identities Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- **Managed Identity (Azure Arc):** Already configured; add computer account to Project Collection Administrators group
- **Personal Access Token (PAT):** Generate in Azure DevOps and store securely; agent service account needs `[Project Collection] Administrators` permissions

### Step 5: Install Required Modules

Install PowerShell modules on the agent pool. See [`source\azdo-dsc-lcm.psd1`](source/azdo-dsc-lcm.psd1) for the complete dependency list:

```powershell
# Example: Install each required module
Install-Module -Name PSDesiredStateConfiguration -RequiredVersion 2.0.0
Install-Module -Name powershell-yaml -MaximumVersion 1.0.0
Install-Module -Name AzureDevOpsDsc -MaximumVersion 1.0.0
Install-Module -Name Datum -MaximumVersion 1.0.0
Install-Module -Name Datum.InvokeCommand -MaximumVersion 1.0.0

# Verify installation
Get-Module -ListAvailable -Name PSDesiredStateConfiguration, powershell-yaml, Datum
```

**Important:** Module versions must match `LCMConfigSettings` in your `Datum.yml`. Version mismatches cause LCM compilation errors.

### Step 6: Deploy Modules and Create Pipeline

**Module Deployment:**
1. Build the LCM module: `.\Build.ps1 -Tasks build`
2. Deploy to `C:\Users\<user>\Documents\PowerShell\Modules\azdo-dsc-lcm\0.1\`
3. Deploy AzureDevOpsDsc to `C:\Users\<user>\Documents\PowerShell\Modules\AzureDevOpsDsc\0.0.2\`
4. Verify `ModuleSettings.clixml` exists at `$ENV:AZDODSC_CACHE_DIRECTORY`

**Create Azure DevOps Pipeline:**

Create a pipeline YAML that calls `Invoke-AZDoLCM`:

```yaml
trigger:
  - main

pool:
  name: YourSelfHostedAgentPool

steps:
  - task: PowerShell@2
    displayName: 'Apply LCM Configuration'
    inputs:
      targetType: 'inline'
      script: |
        Invoke-AZDoLCM -ConfigurationPath '$(System.DefaultWorkingDirectory)\Configuration' -Verbose
      pwsh: true
```

The LCM will:
1. Merge all configuration policies via Datum
2. Validate circular dependencies and resource properties  
3. Orchestrate DSC resource execution against your Azure DevOps organization

### Step 7: Test Configuration

- **Validate Syntax:** Use `Test-DatumConfiguration` to validate YAML structure
- **Test Mode:** Apply configuration in test mode to validate changes without execution
- **Monitor Logs:** Check for runtime errors or misconfigurations
- **Verify Results:** Confirm resources are created/modified as expected

For detailed LCM architecture and configuration processing steps, see [`CLAUDE.md`](CLAUDE.md).

---

## Troubleshooting and Debugging

### Common Issues

**Circular Dependencies Detected**
- Error message: "Circular dependency detected in dependsOn chain"
- Solution: Review `dependsOn` declarations and ensure no resource chains back to themselves
- Tool: Use `Test-DatumConfiguration` to validate configuration before execution

**Resource Property Validation Failures**
- Error: "Invalid property 'PropertyName' for resource type"
- Solution: Verify resource properties match documented specifications in CLAUDE.md
- Tool: Check `Test-ResourceForIncorrectProperties.ps1` output for property mismatches

**Module Version Incompatibility**
- Error: "LCM compilation error: Version mismatch"
- Solution: Ensure `LCMConfigSettings` in `Datum.yml` matches deployed module versions
- Check: Compare versions in module manifest against installed modules

**Authentication Token Failures**
- Error: "Failed to read authentication token from ModuleSettings.clixml"
- Solution: Verify `$ENV:AZDODSC_CACHE_DIRECTORY\ModuleSettings.clixml` exists and is readable
- Check: Ensure AzureDevOpsDsc module initialization completed successfully
- Verify: Agent service account has proper permissions for the cache directory

### Enable Verbose Diagnostics

```powershell
# Test configuration syntax without execution
Test-DatumConfiguration -Path 'Configuration' -Verbose

# Build module with detailed output
.\Build.ps1 -Tasks build -Verbose

# Execute LCM with full diagnostic logging
Invoke-AZDoLCM -ConfigurationPath 'Configuration' -Verbose -DebugPreference Continue
```

For detailed debugging procedures, configuration inspection, and advanced troubleshooting, see the [Debugging and Troubleshooting section in CLAUDE.md](CLAUDE.md#debugging-and-troubleshooting).

---

## Additional Resources

- **CLAUDE.md** - Comprehensive LLM context and architecture documentation
- **AzureDevOpsDsc Documentation** - DSC resource reference and authentication details
- **Datum Project** - Configuration merging engine documentation
- **Example Configuration** - Sample configuration files demonstrating best practices