# AzDO-DSC-LCM — LLM Context File

PowerShell Local Configuration Manager (LCM) that orchestrates Azure DevOps Desired State Configuration using the AzureDevOpsDsc DSC module with Datum-based configuration merging and validation.

---

## Repository Layout

```
C:\Git\AzDO-DSC-LCM\
├── source\
│   ├── Public\                          # Public LCM cmdlets
│   │   ├── Build-DatumConfiguration.ps1
│   │   ├── Invoke-AZDoLCM.ps1
│   │   ├── Resolve-AzDoDatumProject.ps1
│   │   ├── Stop-TaskProcessing.ps1
│   │   └── Test-DatumConfiguration.ps1
│   ├── azdo-dsc-lcm.psd1               # Module manifest
│   ├── azdo-dsc-lcm.psm1               # Root module file
│   └── prefix.ps1                      # Module initialization
├── Tests\
│   ├── Unit\                           # Unit tests
│   └── Integration\                    # Integration tests
├── LCM Rules\
│   ├── PreParse\                       # Pre-parsing validation rules
│   │   ├── Test-CircularReferences.ps1
│   │   └── Test-ResourceForIncorrectProperties.ps1
│   └── Custom\                         # Custom formatting rules
│       └── Sort-DependsOn.ps1
├── Example Configuration\              # Sample configuration structure
│   ├── Datum.yml                       # Datum configuration
│   ├── OrganizationPolicies\           # Organization-level policies
│   └── ProjectPolicies\                # Project-level policies
├── Build.ps1                           # Build entry point
├── Resolve-Dependency.ps1              # Dependency resolution script
├── README.md                           # User documentation
└── CLAUDE.md                           # This file (LLM context)
```

---

## Key Modules and Dependencies

The LCM requires the following modules (see `source\azdo-dsc-lcm.psd1`):

| Module | Version | Purpose |
|--------|---------|---------|
| `PSDesiredStateConfiguration` | 2.0.0+ | DSC framework |
| `powershell-yaml` | ≤ 1.0.0 | YAML parsing for configuration |
| `AzureDevOpsDsc.Common` | ≤ 1.0.0 | Common helpers (authentication, caching) |
| `AzureDevOpsDsc` | ≤ 1.0.0 | DSC resources for Azure DevOps |
| `Datum` | ≤ 1.0.0 | Configuration merging engine |
| `Datum.InvokeCommand` | ≤ 1.0.0 | Command invocation support in Datum |

---

## Public Cmdlets

The LCM exports these commands:

| Cmdlet | Purpose |
|--------|---------|
| `Build-DatumConfiguration` | Merges YAML configuration via Datum |
| `Invoke-AZDoLCM` | Orchestrates DSC resource execution |
| `Resolve-AzDoDatumProject` | Resolves project-specific Datum configuration |
| `Stop-TaskProcessing` | Halts further resource execution in the pipeline |
| `Test-DatumConfiguration` | Validates configuration structure and syntax |

---

## LCM Validation Rules

LCM Rules are modular scripts that validate and transform configuration during the build process. They live in `LCM Rules\`:

### Pre-Parse Rules (in `PreParse\`)
Run before DSC resource execution to validate the entire configuration.

- **`Test-CircularReferences.ps1`**: Detects circular dependencies in `dependsOn` chains. If violations are found, the LCM aborts with an error.
- **`Test-ResourceForIncorrectProperties.ps1`**: Validates that each resource has only documented properties. Invalid properties are rejected before execution.

### Custom Rules (in `Custom\`)
Apply custom transformations or ordering.

- **`Sort-DependsOn.ps1`**: Reorders resources in the YAML file according to their `dependsOn` declarations. **This script is mandatory and cannot be bypassed.**

---

## Configuration Structure and Processing

### Datum Configuration (Datum.yml)

The `Example Configuration\Datum.yml` file defines:

1. **ResolutionPrecedence**: Order in which configuration layers are merged (lower-level configs override higher-level ones)
2. **LCMConfigSettings**: Version constraints for LCM, DSC module, and AzureDevOpsDsc compatibility

Example:
```yaml
LCMConfigSettings:
  ConfigurationVersion: 1.0
  AZDOLCMVersion: 1.0
  DSCResourceVersion: 1.0

ResolutionPrecedence:
  - Projects\$($Node.ProjectPresence)\$($Node.Project)           # Project-specific (highest precedence)
  - ProjectPolicies\$($Node.ProjectArea)\GitPermissions          # Project area policies
  - ProjectPolicies\$($Node.ProjectArea)\GitRepositories
  - ProjectPolicies\$($Node.ProjectArea)\ProjectGroups
  - ProjectPolicies\Project                                       # General project policies
  - OrganizationPolicies\OrganizationGroups                       # Organization-wide policies
  - OrganizationPolicies\Organization                             # (lowest precedence)
```

### Configuration Processing Pipeline

1. **Datum Merges** YAML files in reverse-precedence order (lowest → highest)
2. **Variable Interpolation**: Datum executes `[x={ $Node.ProjectPresence }=]` script blocks
3. **LCM Loads** merged configuration, expanding all variables and parameters
4. **Pre-Parse Rules** validate the configuration
5. **DependsOn Sort** reorders resources according to dependencies
6. **Resource Execution**:
   - Check `Stop-TaskProcessing` flag (skip if set)
   - Evaluate `condition` property (skip if `$false`)
   - Interpolate calculated properties (e.g., `$( if ($x) { 'Yes' } else { 'No' } )`)
   - Execute the DSC resource via `Invoke-DscResource`
   - Execute `postExecutionScript` (even if resource failed)

### Resource-Level Features

Each resource in the YAML can use:

- **`condition`**: Boolean expression; resource skips if `$false`
  ```yaml
  - name: Enable CI/CD
    condition: $ProjectServices.BuildPipelines -eq 'enabled'
    type: AzureDevOpsDsc/AzDoProject
  ```

- **`dependsOn`**: Dependency chain (array of `Type/Name` references)
  ```yaml
  - name: Permissions
    type: AzureDevOpsDsc/AzDoGitPermission
    dependsOn:
      - AzureDevOpsDsc/AzDoProject/MyProject
      - AzureDevOpsDsc/AzDoProjectGroup/Admins
  ```

- **`postExecutionScript`**: Script block executed after the resource (even on failure)
  ```yaml
  - name: MyProject
    type: AzureDevOpsDsc/AzDoProject
    postExecutionScript: |
      if ($MyProject_Ensure -eq 'Absent') {
        Stop-TaskProcessing
      }
  ```

### Variables and Custom Properties

Define reusable values in the YAML:

```yaml
variables:
  ProjectName: 'MyProject'
  GroupName: 'Admins'
  AdminEmails:
    - 'admin1@example.com'
    - 'admin2@example.com'
```

Reference in resources:
```yaml
- name: Create Admin Group
  type: AzureDevOpsDsc/AzDoProjectGroup
  properties:
    ProjectName: $ProjectName
    GroupName: $GroupName
```

---

## Integration with AzureDevOpsDsc

The LCM orchestrates resources from the AzureDevOpsDsc module. Key considerations:

### Authentication

AzureDevOpsDsc resources require authentication tokens. The token is set by the deployed `AzureDevOpsDsc` module during resource execution via `$Global:DSCAZDO_AuthenticationToken`.

**Important**: The LCM does not directly call `Add-AuthenticationHTTPHeader` or `Invoke-AzDevOpsApiRestMethod`. Those are internal to the DSC resource implementations and are guarded by call-stack checks.

### Organization Name

The organization name is read from `ModuleSettings.clixml` (stored in `$ENV:AZDODSC_CACHE_DIRECTORY`) and passed as the `OrganizationName` property in resources.

### DSC Resource Classes

All DSC resources inherit from `AzDevOpsDscResourceBase`, which provides:
- Standard `Get()`, `Set()`, `Test()` methods
- Authentication token injection
- Cache management
- Global variable setup

Key resource classes available:
- `AzDoProject`: Creates/manages projects
- `AzDoProjectGroup`: Creates/manages project groups
- `AzDoGitPermission`: Sets Git repository permissions
- `AzDoPipelinePermission`: Sets pipeline permissions
- `AzDoAreaPermission`, `AzDoIterationPermission`: CSS namespace permissions
- `AzDoCheckConfiguration`: Approval checks on environments

See `AzureDevOpsDsc/CLAUDE.md` for the complete resource reference.

---

## Running Tests

### Unit Tests

```powershell
# Run all unit tests
$config = New-PesterConfiguration
$config.Run.Path = 'C:\Git\AzDO-DSC-LCM\Tests\Unit'
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
```

### Integration Tests

Integration tests execute against a live Azure DevOps organization. They validate the LCM's configuration parsing, Datum merging, and DSC resource orchestration.

```powershell
# Run integration tests
$config = New-PesterConfiguration
$config.Run.Path = 'C:\Git\AzDO-DSC-LCM\Tests\Integration'
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
```

**Requirements**:
- The AzureDevOpsDsc module must be deployed
- `ModuleSettings.clixml` must be present in `$ENV:AZDODSC_CACHE_DIRECTORY`
- Administrator privileges (for module path access)

---

## Build and Deploy

```powershell
# Build the module
.\Build.ps1 -Tasks build

# Deploy to local PowerShell modules directory
# (Uses output from ./build.ps1)
```

The deployed module lands at:
```
C:\Users\<user>\Documents\PowerShell\Modules\azdo-dsc-lcm\0.1\
```

After editing source files, rebuild before running integration tests — the tests execute the **deployed** module, not the source files.

---

## Configuration Best Practices

### 1. Minimize Project-Level Overrides

Project YAML files should contain only project-specific values. Keep the configuration DRY by using higher-level policies for common settings.

```yaml
# Good: Only override what's specific to this project
ProjectArea: 'CustomArea'
variables:
  ProjectDescription: 'MyProject by John Doe'
  Project_Service_BuildPipelines: 'enabled'
```

```yaml
# Bad: Repeating values that should be in organizational policies
variables:
  CommonRepoName: 'repo'         # Belongs in ProjectPolicies
  AdminEmails: [...]             # Belongs in OrganizationPolicies
```

### 2. Respect the Resolution Precedence

Lower-level (project-specific) configurations override higher-level ones. Design your hierarchy from the bottom up: organizational policies first, then project-area policies, then project-specific overrides.

### 3. Avoid Modifying `lookup_options`

Unless you fully understand Datum's lookup behavior, do not modify `lookup_options` in `Datum.yml`. Incorrect settings can cause unexpected configuration merges.

### 4. Use Conditions for Optional Features

Instead of separate configurations, use `condition` to enable/disable features:

```yaml
- name: Azure Artifacts
  condition: $ProjectServices.AzureArtifacts -eq 'enabled'
  type: AzureDevOpsDsc/AzDoArtifactPermission
  # ...
```

---

## Debugging and Troubleshooting

### Enable Verbose Output

```powershell
# Build with verbose logging
.\Build.ps1 -Tasks build -Verbose

# Test configuration parsing
Test-DatumConfiguration -Path 'Example Configuration' -Verbose
```

### Inspect Merged Configuration

```powershell
# Build the merged Datum configuration without executing resources
$config = Build-DatumConfiguration -Path 'Example Configuration'
$config | ConvertTo-Json -Depth 10 | Out-File 'merged-config.json'
```

### Check for Circular Dependencies

```powershell
# This runs automatically during LCM execution, but you can validate manually
Test-DatumConfiguration -Path 'Example Configuration'
```

### Validate Resource Properties

If resources are rejected, check `Test-ResourceForIncorrectProperties.ps1` output. It identifies properties that don't match documented resource specs.

---

## Related Repositories

- **[AzureDevOpsDsc](https://github.com/ZanattaMichael/AzureDevOpsDsc)**: The DSC resource module that AzDO-DSC-LCM orchestrates. Contains class-based resources, authentication helpers, API wrappers, and unit/integration tests.

- **[Datum](https://github.com/gaelcolas/Datum)**: Configuration merging engine used to compose YAML policies into a single configuration document.

---

## Branch

Active development branch: `claude/azdo-dsc-lcm-docs-jrrpom`

This branch tracks documentation and integration updates to reflect changes in the AzureDevOpsDsc repository.

---

## See Also

- `README.md`: User-facing documentation
- `Example Configuration/Datum.yml`: Configuration schema and settings
- `source/azdo-dsc-lcm.psd1`: Module manifest and dependencies
- `LCM Rules/`: Validation and formatting rules
