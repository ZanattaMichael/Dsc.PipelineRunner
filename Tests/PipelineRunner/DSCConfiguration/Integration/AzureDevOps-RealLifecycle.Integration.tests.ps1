Describe "Azure DevOps environment lifecycle against the Example Configuration (real AzureDevOpsDscNative + managed identity)" -Tag Integration, AzureDevOpsSelfHosted {

    # This suite stands up ("build") and tears down a REAL Azure DevOps environment end-to-end, with
    # NOTHING faked below the runner:
    #
    #   * The shipped Example Configuration is compiled through the REAL Datum pipeline
    #     (New-DatumStructure over the real Datum.yml ResolutionPrecedence, Resolve-Datum merging the
    #     Projects\<Presence>\<Project> node with the ProjectPolicies/OrganizationPolicies fragments,
    #     and the Datum.InvokeCommand handlers resolving the [x={ $Node.* }=] expressions).
    #   * Authentication runs through the REAL Connect seam (Invoke-Action -Hook Connect) into the real
    #     Actions/Connect/AzureDevOps.ps1, which calls New-AzDoAuthenticationProvider -useManagedIdentity
    #     from AzureDevOpsDsc.Common -- a real Azure Instance Metadata Service (IMDS) managed-identity
    #     token. No auth is mocked.
    #   * Each resource is evaluated through the REAL DscV2 engine (Actions/Engine/DscV2.ps1 ->
    #     Invoke-DscResource) against the REAL class-based AzureDevOpsDscNative resources, which call
    #     the live Azure DevOps REST API. No engine or provider is mocked.
    #
    # Because that requires the AzureDevOpsDscNative module, a managed identity with access to the
    # target organization, and live Azure DevOps, the suite is tagged 'AzureDevOpsSelfHosted' and runs
    # ONLY on the self-hosted runner (see .github/workflows/AzureDevOps-SelfHosted.yml). The default
    # run (tests.ps1) excludes that tag so it never runs on the hosted Linux agent, where none of that
    # is available; the mocked AzureDevOps-Lifecycle suite provides the cross-platform coverage there.
    #
    # The lifecycle builds and tears down the SAME project so it is a genuine round trip:
    #
    #   * BUILD    -> compile { Project = Magenta; ProjectPresence = Present } and apply it (Set): the
    #                 Magenta project, its git repository, groups and permissions are created.
    #   * TEARDOWN -> compile { Project = Magenta; ProjectPresence = Absent } (the Projects\Absent
    #                 layer has no Magenta file, so Datum resolves the policy Project resource alone
    #                 with Ensure = Absent) and apply it (Set): the project is removed and the
    #                 Project resource's postExecutionScript calls Stop-TaskProcessing, halting the run
    #                 -- the real "delete the project, everything under it cascades" teardown model.
    #
    # The only boundary pointed at the repository (rather than an installed module) is the
    # engine/connect-file loader (Invoke-Action's Get-Module 'Dsc.PipelineRunner'); it is aimed at the
    # repository root so the real Actions/<Hook>/<Name>.ps1 files resolve without installing this
    # module. That filtered mock leaves AzureDevOpsDscNative's / Datum's own Get-Module calls untouched.

    BeforeAll {

        # --- Compile dependencies (installed by the self-hosted workflow). Hard imports so a missing
        # compile stack fails loudly rather than silently skipping. ----------------------------------
        foreach ($module in 'powershell-yaml', 'datum', 'datum.invokecommand') {
            Import-Module -Name $module -ErrorAction Stop
        }

        # --- The real Azure DevOps resource module. New-AzDoAuthenticationProvider lives in the
        # bundled AzureDevOpsDsc.Common companion, which sits under the installed module tree and is
        # NOT on PSModulePath, so import it by path after the native module resolves. -----------------
        $native = Get-Module -ListAvailable -Name AzureDevOpsDscNative |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $native) {
            throw "AzureDevOpsDscNative is not installed. Install it on the self-hosted runner (Install-Module AzureDevOpsDscNative -AllowPrerelease)."
        }
        Import-Module -Name $native.Path -Force -ErrorAction Stop
        $commonManifest = Join-Path (Split-Path -Parent $native.Path) 'Modules/AzureDevOpsDsc.Common/AzureDevOpsDsc.Common.psd1'
        if (Test-Path -LiteralPath $commonManifest) {
            Import-Module -Name $commonManifest -Force -ErrorAction Stop
        }
        if (-not (Get-Command -Name New-AzDoAuthenticationProvider -ErrorAction SilentlyContinue)) {
            throw "New-AzDoAuthenticationProvider is not available after importing AzureDevOpsDscNative / AzureDevOpsDsc.Common."
        }

        # New-AzDoAuthenticationProvider requires a writable cache directory. The workflow sets this;
        # fall back to a per-run TestDrive path so the suite is also runnable by hand.
        if ([string]::IsNullOrWhiteSpace($env:AZDODSC_CACHE_DIRECTORY)) {
            $env:AZDODSC_CACHE_DIRECTORY = Join-Path $TestDrive 'azdodsc-cache'
        }
        New-Item -ItemType Directory -Path $env:AZDODSC_CACHE_DIRECTORY -Force -ErrorAction SilentlyContinue | Out-Null

        # --- Load the real dependency graph (class first, then the runner chain and engine seam) ----
        . (Get-FunctionPath 'DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-Action.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-DscMethodResult.ps1').FullName
        . (Get-FunctionPath 'Invoke-EngineAction.ps1').FullName

        . (Get-FunctionPath 'Start-DscRunner.ps1').FullName
        . (Get-FunctionPath 'GetDefaultValues.ps1').FullName
        . (Get-FunctionPath 'SetVariables.ps1').FullName
        . (Get-FunctionPath 'ConvertTo-CaseInsensitiveHashtable.ps1').FullName
        . (Get-FunctionPath 'Expand-HashTable.ps1').FullName
        . (Get-FunctionPath 'Expand-StringInArray.ps1').FullName
        . (Get-FunctionPath 'Assert-SafeConditionExpression.ps1').FullName
        . (Get-FunctionPath 'Stop-TaskProcessing.ps1').FullName

        # Dot-sourced so Pester has real commands to Mock; the mocks below replace their bodies.
        . (Get-FunctionPath 'Invoke-CustomTask.ps1').FullName
        . (Get-FunctionPath 'Invoke-PreParseRules.ps1').FullName
        . (Get-FunctionPath 'Invoke-FormatTasks.ps1').FullName

        # Module-script-scope state the runner reads/mutates (mirrors source/prefix.ps1).
        $references = @{}
        $variables  = @{}
        $parameters = @{}

        $script:SortDependsOnPath = (Get-FunctionPath 'Sort-DependsOn.ps1').FullName

        # ------------------------------------------------------------------------------------------
        # Compile the REAL Example Configuration through the REAL Datum pipeline (no mocks active yet).
        # This is the same New-DatumStructure + Resolve-Datum merge production runs; performed inline
        # so it works dot-sourced without a by-name module install.
        # ------------------------------------------------------------------------------------------
        $script:ExampleConfigPath = Join-Path $Global:RepositoryRoot 'Example Configuration'
        $script:CompiledDir       = Join-Path $TestDrive 'compiled'
        New-Item -ItemType Directory -Path $script:CompiledDir -Force | Out-Null

        function Build-CompiledNode {
            param($Datum, [string]$ProjectPresence, [string]$ProjectName, [string]$OutputDirectory)

            $node = @{ Project = $ProjectName; ProjectPresence = $ProjectPresence }

            $resolved = @{
                resources  = Resolve-Datum -PropertyPath 'resources'  -DatumStructure $Datum -Variable $node
                parameters = Resolve-Datum -PropertyPath 'parameters' -DatumStructure $Datum -Variable $node
                conditions = Resolve-Datum -PropertyPath 'conditions' -DatumStructure $Datum -Variable $node
                variables  = Resolve-Datum -PropertyPath 'variables'  -DatumStructure $Datum -Variable $node
            }

            $variablesOut = @{}
            foreach ($key in $resolved.variables.Keys) {
                $value = $resolved.variables[$key]
                if ($value | Test-InvokeCommandFilter) {
                    $variablesOut[$key] = $value | Invoke-InvokeCommandAction -Node $node
                }
                else {
                    $variablesOut[$key] = $value
                }
            }

            $compiled = @{
                resources  = $resolved.resources
                parameters = $resolved.parameters
                conditions = $resolved.conditions
                variables  = $variablesOut
            }

            $outputPath = Join-Path $OutputDirectory ("{0}.{1}.yml" -f $ProjectName, $ProjectPresence)
            $compiled | ConvertTo-Yaml | Set-Content -LiteralPath $outputPath -Encoding UTF8
            return $outputPath
        }

        Push-Location $script:ExampleConfigPath
        try {
            $datum = New-DatumStructure -DefinitionFile 'Datum.yml'

            # The project the lifecycle turns on (the shipped Present example node).
            $script:ProjectName = 'Magenta'

            # The organization: an AZDO_ORGANIZATION_NAME override wins, else the shipped
            # OrganizationPolicies/Organization.yml value.
            $configOrganization = [string](Resolve-Datum -PropertyPath 'variables' -DatumStructure $datum `
                    -Variable @{ Project = $script:ProjectName; ProjectPresence = 'Present' })['Organization_Name']
            $script:OrganizationName = if (-not [string]::IsNullOrWhiteSpace($env:AZDO_ORGANIZATION_NAME)) {
                $env:AZDO_ORGANIZATION_NAME
            }
            else {
                $configOrganization
            }

            # BUILD node (Magenta Present) and TEARDOWN node (Magenta Absent -- policy Project resource
            # only, resolved with Ensure = Absent because the Projects\Absent layer has no Magenta file).
            $script:BuildConfigPath    = Build-CompiledNode -Datum $datum -ProjectPresence 'Present' -ProjectName $script:ProjectName -OutputDirectory $script:CompiledDir
            $script:TeardownConfigPath = Build-CompiledNode -Datum $datum -ProjectPresence 'Absent'  -ProjectName $script:ProjectName -OutputDirectory $script:CompiledDir
        }
        finally {
            Pop-Location
        }

        # ------------------------------------------------------------------------------------------
        # Point ONLY the engine/connect-file loader at the repository root so it resolves the real
        # Actions/<Hook>/<Name>.ps1 without an installed Dsc.PipelineRunner module. The parameter
        # filter keeps AzureDevOpsDscNative's / Datum's own Get-Module calls untouched.
        # ------------------------------------------------------------------------------------------
        Mock -CommandName Get-Module -ParameterFilter { $Name -eq 'Dsc.PipelineRunner' } -MockWith {
            return @{ ModuleBase = $Global:RepositoryRoot }
        }

        Mock -CommandName Write-Host
        Mock -CommandName Write-Information

        # Loader stand-ins. Invoke-CustomTask runs the REAL Sort-DependsOn so dependency ordering is
        # genuinely exercised over the compiled Example Configuration resources.
        Mock -CommandName Invoke-CustomTask -MockWith {
            param(
                [Parameter(Mandatory = $true)] [Object[]]$Tasks,
                [Parameter(Mandatory = $true)] [String]$CustomTaskName
            )
            if ($CustomTaskName -eq 'Sort-DependsOn') {
                return (& $script:SortDependsOnPath -PipelineResources $Tasks)
            }
            return $Tasks
        }
        Mock -CommandName Invoke-PreParseRules -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) }
        Mock -CommandName Invoke-FormatTasks   -MockWith { param([Parameter(Mandatory = $true)] [Object[]]$Tasks) return $Tasks }

        # Establish the ambient Azure DevOps session exactly as the provider-agnostic runner does:
        # Invoke-Action -Hook Connect runs the real Actions/Connect/AzureDevOps.ps1, which calls
        # New-AzDoAuthenticationProvider -useManagedIdentity for real.
        function Connect-AzureDevOps {
            $context = @{ OrganizationName = $script:OrganizationName; AuthenticationType = 'ManagedIdentity' }
            $null = Invoke-Action -Hook Connect -Name 'AzureDevOps' -Context $context
        }
    }

    AfterAll {
        # Best-effort cleanup: make sure the Magenta project is not left behind if an assertion failed
        # between build and teardown. Ignore all errors -- this is a safety net, not an assertion.
        try {
            if ($script:TeardownConfigPath -and (Test-Path -LiteralPath $script:TeardownConfigPath)) {
                $script:StopTaskProcessing = $false
                $null = Start-DscRunner -FilePath $script:TeardownConfigPath -Mode 'Set' -Engine 'DscV2'
            }
        }
        catch {
            Write-Verbose "[AfterAll] Best-effort teardown failed: $_"
        }
    }

    BeforeEach {
        $script:StopTaskProcessing = $false
    }

    Context "the Datum compile of the shipped Example Configuration" {

        It "resolves the Present node (Magenta) to a Project marked Present with its own git repository" {
            $build = Get-Content -LiteralPath $script:BuildConfigPath -Raw | ConvertFrom-Yaml

            $build.variables.ProjectName    | Should -Be 'Magenta'
            $build.variables.Project_Ensure | Should -Be 'Present'

            $names = @($build.resources | ForEach-Object { $_.name })
            $names | Should -Contain 'Project'
            $names | Should -Contain 'Configuration Git Repository'
        }

        It "resolves the same project at Absent presence to a Project marked Absent (teardown)" {
            $teardown = Get-Content -LiteralPath $script:TeardownConfigPath -Raw | ConvertFrom-Yaml

            $teardown.variables.ProjectName    | Should -Be 'Magenta'
            $teardown.variables.Project_Ensure | Should -Be 'Absent'

            $names = @($teardown.resources | ForEach-Object { $_.name })
            $names | Should -Contain 'Project'
            # No Present-only project resource should appear in the teardown compile.
            $names | Should -Not -Contain 'Configuration Git Repository'
        }
    }

    Context "real Azure DevOps lifecycle (managed identity)" {

        It "authenticates to the target organization with a managed identity" {
            Connect-AzureDevOps

            # New-AzDoAuthenticationProvider records the session in these globals on success.
            $Global:DSCAZDO_OrganizationName    | Should -Be $script:OrganizationName
            $Global:DSCAZDO_AuthenticationToken | Should -Not -BeNullOrEmpty
        }

        It "builds the Magenta environment, is idempotent, then tears it down" {

            # 1. Authenticate.
            Connect-AzureDevOps

            # 2. BUILD: apply the Present node. Over convergence every resource reaches desired state.
            $build = Start-DscRunner -FilePath $script:BuildConfigPath -Mode 'Set' -Engine 'DscV2'
            $build.Status    | Should -Be 'Completed'
            $build.FailCount | Should -Be 0

            # 3. IDEMPOTENT: a Test pass over the just-built environment reports no drift.
            $script:StopTaskProcessing = $false
            $verify = Start-DscRunner -FilePath $script:BuildConfigPath -Mode 'Test' -Engine 'DscV2'
            $verify.Status    | Should -Be 'Completed'
            $verify.FailCount | Should -Be 0

            # 4. TEARDOWN: apply the Absent node. The Project's postExecutionScript calls
            #    Stop-TaskProcessing, so removing the project halts the rest of the run.
            $script:StopTaskProcessing = $false
            $teardown = Start-DscRunner -FilePath $script:TeardownConfigPath -Mode 'Set' -Engine 'DscV2'
            $teardown.Status    | Should -Be 'StoppedByRequest'
            $teardown.SkipCount | Should -BeGreaterThan 0
        }
    }
}
