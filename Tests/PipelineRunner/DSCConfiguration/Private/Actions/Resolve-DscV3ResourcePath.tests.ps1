Describe "Resolve-DscV3ResourcePath Function Tests" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
        . (Get-FunctionPath 'Resolve-DscV3ResourcePath.ps1').FullName

        # A resource directory as dsc installs one: a manifest, its executable, and the
        # PowerShell discover extension beside them.
        $script:ResourceDirectory = Join-Path $TestDrive 'dsc'
        $null = New-Item -ItemType Directory -Path $script:ResourceDirectory -Force
        $script:ManifestPath = Join-Path $script:ResourceDirectory 'registry.dsc.resource.json'
        Set-Content -LiteralPath $script:ManifestPath -Value '{"type":"Microsoft.Windows/Registry","get":{"executable":"registry","args":["config","get"]}}'
        Set-Content -LiteralPath (Join-Path $script:ResourceDirectory 'registry.exe') -Value ''
        Set-Content -LiteralPath (Join-Path $script:ResourceDirectory 'powershell.dsc.extension.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:ResourceDirectory 'powershell.discover.ps1') -Value ''

        $script:Listed = {
            param([string]$Type, [string]$Path, [string]$Kind = 'resource', [string]$Adapter = $null)
            $entry = [ordered]@{ type = $Type; kind = $Kind; path = $Path; directory = (Split-Path $Path -Parent); requireAdapter = $Adapter }
            @{ ExitCode = 0; Output = ($entry | ConvertTo-Json -Compress); ErrorOutput = '' }
        }
    }

    BeforeEach {
        Clear-DscV3ResourcePath
        $script:SavedResourcePath = $env:DSC_RESOURCE_PATH
        $script:SavedFullDiscovery = $env:PIPELINERUNNER_DSC_FULL_DISCOVERY
        $env:DSC_RESOURCE_PATH = $null
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = $null
    }

    AfterEach {
        Clear-DscV3ResourcePath
        $env:DSC_RESOURCE_PATH = $script:SavedResourcePath
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = $script:SavedFullDiscovery
    }

    It "Copies a command resource's manifest, and only it, into a directory of its own" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        $resolved = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

        $resolved.ExecutableDirectory | Should -Be $script:ResourceDirectory
        @(Get-ChildItem -LiteralPath $resolved.ResourcePath).Name | Should -Be @('registry.dsc.resource.json')
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It -ParameterFilter {
            ($Arguments -join ' ') -eq 'resource list --output-format json'
        }
    }

    It "Runs the full discovery once per run, however many types are asked for" {
        $other = Join-Path $script:ResourceDirectory 'other.dsc.resource.json'
        Set-Content -LiteralPath $other -Value '{"type":"Mod/Other","get":{"executable":"other"}}'
        Mock -CommandName Invoke-DscExecutable -MockWith {
            $a = & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath
            $b = & $script:Listed 'Mod/Other' $other
            @{ ExitCode = 0; Output = ($a.Output + "`n" + $b.Output); ErrorOutput = '' }
        }

        $first = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
        $second = Resolve-DscV3ResourcePath -ResourceType 'Mod/Other'

        $first.ResourcePath | Should -Not -Be $second.ResourcePath
        @(Get-ChildItem -LiteralPath $second.ResourcePath).Name | Should -Be @('other.dsc.resource.json')
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It
    }

    It "Leaves a type dsc lists more than once to full discovery" {
        Mock -CommandName Invoke-DscExecutable -MockWith {
            $a = & $script:Listed 'Mod/Res' $script:ManifestPath
            @{ ExitCode = 0; Output = ($a.Output + "`n" + $a.Output); ErrorOutput = '' }
        }

        Resolve-DscV3ResourcePath -ResourceType 'Mod/Res' | Should -BeNullOrEmpty
    }

    It "Leaves a type dsc does not list to full discovery" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        Resolve-DscV3ResourcePath -ResourceType 'Mod/Missing' | Should -BeNullOrEmpty
    }

    It "Runs the full discovery once per type" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        $first = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
        $second = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

        $second.ResourcePath | Should -Be $first.ResourcePath
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It
    }

    It "Leaves an adapted resource to full discovery" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Mod/Res' $script:ManifestPath 'resource' 'Microsoft.DSC/PowerShell' }

        Resolve-DscV3ResourcePath -ResourceType 'Mod/Res' | Should -BeNullOrEmpty
    }

    It "Leaves an adapter or a group to full discovery" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.DSC/PowerShell' $script:ManifestPath 'adapter' }

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.DSC/PowerShell' | Should -BeNullOrEmpty
    }

    It "Leaves a resource whose manifest names a script beside it to full discovery" {
        $scripted = Join-Path $script:ResourceDirectory 'psscript.dsc.resource.json'
        Set-Content -LiteralPath $scripted -Value '{"type":"Microsoft.DSC.Transitional/PowerShellScript","get":{"executable":"pwsh","args":["-File","powershell.discover.ps1"]}}'
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.DSC.Transitional/PowerShellScript' $scripted }

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.DSC.Transitional/PowerShellScript' | Should -BeNullOrEmpty
    }

    It "Leaves the type to full discovery when dsc resource list fails" {
        Mock -CommandName Invoke-DscExecutable -MockWith { @{ ExitCode = 2; Output = ''; ErrorOutput = 'boom' } }

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry' | Should -BeNullOrEmpty
    }

    It "Keeps the operator's own DSC_RESOURCE_PATH" {
        $env:DSC_RESOURCE_PATH = $script:ResourceDirectory
        Mock -CommandName Invoke-DscExecutable

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry' | Should -BeNullOrEmpty
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 0 -Scope It
    }

    It "Is turned off by PIPELINERUNNER_DSC_FULL_DISCOVERY" {
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = '1'
        Mock -CommandName Invoke-DscExecutable

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry' | Should -BeNullOrEmpty
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 0 -Scope It
    }

    It "Puts one type back to full discovery without listing it again" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
        Clear-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

        Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry' | Should -BeNullOrEmpty
        Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It
    }

    It "Catches a manifest that names a sibling script in another letter case" {
        $scripted = Join-Path $script:ResourceDirectory 'cased.dsc.resource.json'
        Set-Content -LiteralPath $scripted -Value '{"type":"Mod/Cased","get":{"executable":"pwsh","args":["-File","Setup.PS1"]}}'
        Set-Content -LiteralPath (Join-Path $script:ResourceDirectory 'setup.ps1') -Value ''
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Mod/Cased' $scripted }

        Resolve-DscV3ResourcePath -ResourceType 'Mod/Cased' | Should -BeNullOrEmpty
    }

    Context "The staging directory" {
        It "Is rooted at a name that does not carry the process id and differs per run" {
            Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            $firstRoot = (Get-DscV3ResourcePathStore).Root
            Clear-DscV3ResourcePath
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            $secondRoot = (Get-DscV3ResourcePathStore).Root

            (Split-Path $firstRoot -Leaf) | Should -Match '^Dsc\.PipelineRunner-dsc-[0-9a-f]{32}$'
            (Split-Path $firstRoot -Leaf) | Should -Not -Match ('-{0}$' -f $PID)
            $secondRoot | Should -Not -Be $firstRoot
        }

        It "Is not used, and discovery stays full, when the directory already exists" {
            $existing = Join-Path $TestDrive 'planted'
            $null = New-Item -ItemType Directory -Path $existing
            Mock -CommandName Get-DscV3StagingRootPath -MockWith { $existing }
            Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

            Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry' | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $existing).Count | Should -Be 0
        }

        It "Is restricted to its owner (mode 0700) on Linux" -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Unix) {
            Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            $root = (Get-DscV3ResourcePathStore).Root

            (& stat -c '%a' $root) | Should -Be '700'
        }
    }

    It "Removes the copied manifests when cleared" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        $resolved = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
        Clear-DscV3ResourcePath

        Test-Path -LiteralPath $resolved.ResourcePath | Should -BeFalse
    }
}

Describe "Invoke-DscExecutable -Environment" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Invoke-DscExecutable.ps1').FullName
    }

    It "Gives the child the variables and puts the parent's back afterwards" {
        $env:PIPELINERUNNER_TEST_MARKER = 'before'
        try {
            $result = Invoke-DscExecutable -Executable (Get-Process -Id $PID).Path `
                -Arguments @('-NoProfile', '-NonInteractive', '-Command', '$env:PIPELINERUNNER_TEST_MARKER') `
                -Environment @{ PIPELINERUNNER_TEST_MARKER = 'during' }

            $result.Output.Trim() | Should -Be 'during'
            $env:PIPELINERUNNER_TEST_MARKER | Should -Be 'before'
        }
        finally {
            $env:PIPELINERUNNER_TEST_MARKER = $null
        }
    }

    It "Removes a variable that did not exist before" {
        $env:PIPELINERUNNER_TEST_MARKER = $null
        $null = Invoke-DscExecutable -Executable (Get-Process -Id $PID).Path `
            -Arguments @('-NoProfile', '-NonInteractive', '-Command', '1') `
            -Environment @{ PIPELINERUNNER_TEST_MARKER = 'during' }

        Test-Path -LiteralPath 'Env:PIPELINERUNNER_TEST_MARKER' | Should -BeFalse
    }
}

Describe "The module provides the discovery functions the engine guards on" -Tag Unit, Actions, Engine {

    # The engine and Invoke-DscRunner call these behind Get-Command -ErrorAction SilentlyContinue,
    # so a packaging slip would silently turn the narrowing off. ModuleBuilder compiles every
    # file under source/Private into the module; check each function is defined there once.
    BeforeDiscovery {
        $names = 'Resolve-DscV3ResourcePath', 'Clear-DscV3ResourcePath'
    }

    It "Defines <_> once under source/Private" -ForEach $names {
        $name = $_
        $repoRoot = $PSScriptRoot
        1..5 | ForEach-Object { $repoRoot = Split-Path -Path $repoRoot -Parent }
        $definitions = foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'source/Private') -Recurse -File -Filter '*.ps1')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        }
        @($definitions).Count | Should -Be 1
    }
}
