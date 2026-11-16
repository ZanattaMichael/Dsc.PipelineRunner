# Azure DevOps: self-hosted agent and pipeline setup

These steps are only needed if you run the runner from Azure DevOps with `Invoke-DscPipelineRunner`,
or with the `AzureDevOps` `Connect` action. They follow on from steps 1 to 3 of
[Getting Started](../README.md#getting-started), which build the configuration itself and apply to any
CI/CD system.

> **Prefer a pipeline task?** The [Dsc.PipelineRunnerActions](https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions)
> extension provides `DscPipelineRunner@1`, which installs the module and calls the runner for you;
> see its [Azure DevOps guide](https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions/blob/main/docs/azure-devops.md).
> The agent identity and permissions described below still apply.

1. __(Azure DevOps only) Setup Dsc.PipelineRunner using a Self-Hosted Agent within the CI/CD Pipeline:__

   - Follow the detailed instructions provided in the [Azure DevOps Agents Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents?view=azure-devops) to configure your self-hosted agent.
   - __Run the agent service as an identity that is permitted to do the work:__

     Unless a resource's `target` block supplies its own `credential`, the runner reaches every
     remote machine — and reads every per-user secret store — as the account the agent service
     runs as. The agent installs as `NT AUTHORITY\NETWORK SERVICE` by default, which presents
     the *computer* account off-box and is almost never a member of anything on the target, so
     remoting fails the moment the pipeline runs unattended even though it worked from an
     interactive session.

     Reconfigure the agent service to run as a domain (or, for workgroup targets, matching
     local) account, and grant that account:

     | Where | What it needs |
     |---|---|
     | On each target | Local `Remote Management Users` to open a WinRM session, and local `Administrators` to apply DSC — `Invoke-DscResource` drives the CIM/DSC subsystem and most resources change machine-wide state. |
     | On each target | *Force shutdown from a remote system*, if any resource can report `RebootRequired` — the runner restarts remote targets itself. Local `Administrators` holds it by default. |
     | On the agent | Local administrator on the agent host itself, if the pipeline is to run `Enable-PSRemoting` (including registering the `PowerShell.7` endpoint) rather than have it configured by hand beforehand. |
     | On the agent | Ownership of the per-user state the run depends on — a `Microsoft.PowerShell.SecretStore` vault, an SSH key under `~/.ssh`, `TrustedHosts` entries. These live in the service account's profile, not in yours. |

     Where that account cannot be granted those rights, leave it unprivileged and give each
     remote resource an explicit `target.credential` instead. Full detail, including
     cross-domain and second-hop cases, is in
     [Remote Targets and Credentials](https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki/Remote-Targets-and-Credentials#the-identity-the-runner-runs-as).
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

    Ensure that the Agent Pool is equipped with all necessary PowerShell module dependencies as specified in the module manifest file [`source\Dsc.PipelineRunner.psd1`](../source/Dsc.PipelineRunner.psd1). The core module's required modules are:

    | Module | Version Constraint |
    |---|---|
    | `PSDesiredStateConfiguration` | `>= 2.0.0` |
    | `powershell-yaml` | `<= 1.0.0` |
    | `datum` | `<= 1.0.0` |
    | `Datum.InvokeCommand` | `<= 1.0.0` |

    Azure DevOps support is **not** a core dependency — it is an opt-in `Connect` action
    (`Actions/Connect/AzureDevOps.ps1`) that imports the following modules on demand.
    Install them only if you use `Invoke-DscPipelineRunner`, or `Invoke-DscRunner -Connect AzureDevOps`:

    | Module | Version Constraint |
    |---|---|
    | `AzureDevOpsDsc.Common` | `<= 1.0.0` |
    | `AzureDevOpsDscNative` | `<= 1.0.0` |

    The module versions this repository is built and tested with are pinned in
    [`scripts/module-versions.json`](../scripts/module-versions.json). On a CI agent, install exactly those:

    ```powershell
    ./scripts/Install-PinnedModule.ps1 -Name Datum, Datum.InvokeCommand, powershell-yaml, PSDesiredStateConfiguration
    ```

    To install any of these modules by hand instead, execute the following command for each module listed above:

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
            -ExportConfigDir "$(Agent.TempDirectory)\ExportedConfig" `
            -ConfigurationSourcePath "$(ConfigurationRepoUrl)" `
            -JITToken "$(System.AccessToken)" `
            -Mode "Set"
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
