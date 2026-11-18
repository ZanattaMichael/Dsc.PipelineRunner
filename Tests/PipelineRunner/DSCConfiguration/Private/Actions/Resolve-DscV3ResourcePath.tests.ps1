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
        $script:SavedDiscoveryCache = $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE
        $env:DSC_RESOURCE_PATH = $null
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = $null
        # These tests count dsc calls within one run; the saved list has its own context below.
        $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE = '0'
    }

    AfterEach {
        Clear-DscV3ResourcePath
        $env:DSC_RESOURCE_PATH = $script:SavedResourcePath
        $env:PIPELINERUNNER_DSC_FULL_DISCOVERY = $script:SavedFullDiscovery
        $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE = $script:SavedDiscoveryCache
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

    Context "The resource list saved between runs" {
        BeforeEach {
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE = $null
            $script:SavedCachePath = $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH
            $script:SavedCacheHours = $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS
            $script:CacheDirectory = Join-Path $TestDrive ('cache-{0}' -f [guid]::NewGuid().ToString('N'))
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH = $script:CacheDirectory
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS = $null
            $script:Fingerprint = 'aaaa'
            Mock -CommandName Get-DscV3DiscoveryFingerprint -MockWith { $script:Fingerprint }
            Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }
            # A list read from disk is only acted on when the manifest it names is somewhere
            # dsc looks, which for a command resource is a directory on PATH. The fixture puts
            # the resource directory there, as an installed resource would be.
            $script:SavedListPath = $env:PATH
            $env:PATH = '{0}{1}{2}' -f $script:ResourceDirectory, [System.IO.Path]::PathSeparator, $env:PATH
            # A new run: the process-wide store starts empty, the directory on disk does not.
            $script:NewRun = { Clear-DscV3ResourcePath }
        }

        AfterEach {
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH = $script:SavedCachePath
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS = $script:SavedCacheHours
            $env:PATH = $script:SavedListPath
        }

        It "Lets a later run narrow without running dsc's full discovery" {
            $first = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            & $script:NewRun
            $second = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            $second.ExecutableDirectory | Should -Be $first.ExecutableDirectory
            @(Get-ChildItem -LiteralPath $second.ResourcePath).Name | Should -Be @('registry.dsc.resource.json')
            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It
            Test-Path -LiteralPath (Join-Path $script:CacheDirectory 'aaaa.json') | Should -BeTrue
        }

        It "Lists again when what discovery depends on has changed" {
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            & $script:NewRun
            $script:Fingerprint = 'bbbb'
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 2 -Scope It
        }

        It "Lists again when the manifest it names has changed since" {
            $manifest = Join-Path $script:ResourceDirectory 'changing.dsc.resource.json'
            Set-Content -LiteralPath $manifest -Value '{"type":"Mod/Changing","get":{"executable":"changing"}}'
            Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Mod/Changing' $manifest }
            $null = Resolve-DscV3ResourcePath -ResourceType 'Mod/Changing'
            & $script:NewRun
            Set-Content -LiteralPath $manifest -Value '{"type":"Mod/Changing","get":{"executable":"changed","args":["now"]}}'

            $resolved = Resolve-DscV3ResourcePath -ResourceType 'Mod/Changing'

            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 2 -Scope It
            Get-Content -LiteralPath (Join-Path $resolved.ResourcePath 'changing.dsc.resource.json') -Raw | Should -Match 'changed'
        }

        It "Lists again when the saved list is older than PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS" {
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            & $script:NewRun
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS = '0'
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 2 -Scope It
        }

        It "Is removed when a type has to go back to full discovery" {
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            Clear-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Test-Path -LiteralPath (Join-Path $script:CacheDirectory 'aaaa.json') | Should -BeFalse
        }

        It "Is not saved when PIPELINERUNNER_DSC_DISCOVERY_CACHE is 0" {
            $env:PIPELINERUNNER_DSC_DISCOVERY_CACHE = '0'
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Test-Path -LiteralPath $script:CacheDirectory | Should -BeFalse
        }

        It "Is not saved where other users could write" -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Unix) {
            $null = New-Item -ItemType Directory -Path $script:CacheDirectory
            & chmod 777 $script:CacheDirectory

            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            @(Get-ChildItem -LiteralPath $script:CacheDirectory).Count | Should -Be 0
        }

        It "Creates its directory for its owner only (mode 0700) on Linux" -Skip:([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Unix) {
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            (& stat -c '%a' $script:CacheDirectory) | Should -Be '700'
        }

        It "Lists again when the saved list names a manifest dsc would not find" {
            # The saved file says which manifest to copy, and a manifest says which executable
            # dsc runs. One pointing outside dsc's own search path is not acted on: dsc is
            # asked again, and this run narrows from what it says.
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            & $script:NewRun
            $env:PATH = $script:SavedListPath

            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 2 -Scope It
        }

        It "Removes a saved list nothing will read again when it writes a new one" {
            $stale = Join-Path $script:CacheDirectory 'bbbb.json'
            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
            Set-Content -LiteralPath $stale -Value '{"resources":[]}'
            [System.IO.File]::SetLastWriteTimeUtc($stale, [datetime]::UtcNow.AddHours(-48))
            & $script:NewRun
            $script:Fingerprint = 'cccc'

            $null = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            Test-Path -LiteralPath $stale | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:CacheDirectory 'cccc.json') | Should -BeTrue
        }

        It "Reads a corrupt saved list as no list" {
            $null = New-Item -ItemType Directory -Path $script:CacheDirectory
            Set-Content -LiteralPath (Join-Path $script:CacheDirectory 'aaaa.json') -Value '{ not json'

            $resolved = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'

            $resolved | Should -Not -BeNullOrEmpty
            Assert-MockCalled -CommandName Invoke-DscExecutable -Exactly 1 -Scope It
        }
    }

    It "Removes the copied manifests when cleared" {
        Mock -CommandName Invoke-DscExecutable -MockWith { & $script:Listed 'Microsoft.Windows/Registry' $script:ManifestPath }

        $resolved = Resolve-DscV3ResourcePath -ResourceType 'Microsoft.Windows/Registry'
        Clear-DscV3ResourcePath

        Test-Path -LiteralPath $resolved.ResourcePath | Should -BeFalse
    }
}

Describe "Get-DscV3DiscoveryFingerprint" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-DscV3ResourcePath.ps1').FullName
    }

    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:Directory = Join-Path $TestDrive ('path-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Directory
        $script:Shell = (Get-Process -Id $PID).Path
        $env:PATH = '{0}{1}{2}' -f $script:Directory, [System.IO.Path]::PathSeparator, (Split-Path -Path $script:Shell -Parent)
    }

    AfterEach {
        $env:PATH = $script:SavedPath
    }

    It "Is the same while nothing changes" {
        Get-DscV3DiscoveryFingerprint -Executable $script:Shell | Should -Be (Get-DscV3DiscoveryFingerprint -Executable $script:Shell)
    }

    It "Changes when a manifest is added to a directory on PATH" {
        $before = Get-DscV3DiscoveryFingerprint -Executable $script:Shell
        Set-Content -LiteralPath (Join-Path $script:Directory 'new.dsc.resource.json') -Value '{}'
        # Adding a file moves the directory's time; set it ahead as well, so the test does not
        # depend on how finely a file system records that time.
        [System.IO.Directory]::SetLastWriteTimeUtc($script:Directory, [datetime]::UtcNow.AddMinutes(1))

        Get-DscV3DiscoveryFingerprint -Executable $script:Shell | Should -Not -Be $before
    }

    It "Changes when a module version is added beside one already there" {
        # PSModulePath names the Modules directory, and adding Modules/Foo/2.0.0 moves only
        # Foo's time. The fingerprint covers each module directory for exactly this case.
        $modules = Join-Path $TestDrive ('modules-{0}' -f [guid]::NewGuid().ToString('N'))
        $module = Join-Path $modules 'Foo'
        $null = New-Item -ItemType Directory -Path (Join-Path $module '1.0.0') -Force
        $savedModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $modules
            $before = Get-DscV3DiscoveryFingerprint -Executable $script:Shell
            $null = New-Item -ItemType Directory -Path (Join-Path $module '2.0.0') -Force
            [System.IO.Directory]::SetLastWriteTimeUtc($module, [datetime]::UtcNow.AddMinutes(1))

            Get-DscV3DiscoveryFingerprint -Executable $script:Shell | Should -Not -Be $before
        }
        finally {
            $env:PSModulePath = $savedModulePath
        }
    }

    It "Changes when PATH changes" {
        $before = Get-DscV3DiscoveryFingerprint -Executable $script:Shell
        $env:PATH = '{0}{1}{2}' -f $env:PATH, [System.IO.Path]::PathSeparator, $TestDrive

        Get-DscV3DiscoveryFingerprint -Executable $script:Shell | Should -Not -Be $before
    }

    It "Is null when the executable is not found" {
        Get-DscV3DiscoveryFingerprint -Executable 'no-such-dsc-executable' | Should -BeNullOrEmpty
    }
}

Describe "Remove-DscV3StaleListing" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-DscV3ResourcePath.ps1').FullName
        $script:Hex = { param([int]$Length) -join (1..$Length | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }
    }

    BeforeEach {
        $script:Directory = Join-Path $TestDrive ('prune-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Directory
        $script:Age = {
            param([string]$Path, [double]$Hours)
            Set-Content -LiteralPath $Path -Value '{}'
            [System.IO.File]::SetLastWriteTimeUtc($Path, [datetime]::UtcNow.AddHours(-$Hours))
            $Path
        }
        $script:Listing = { Join-Path $script:Directory ('{0}.json' -f (& $script:Hex 64)) }
    }

    It "Removes a saved list nothing will read again" {
        $old = & $script:Age (& $script:Listing) 48

        Remove-DscV3StaleListing -Directory $script:Directory -Hours 24

        Test-Path -LiteralPath $old | Should -BeFalse
    }

    It "Keeps one that is still within the age limit" {
        $recent = & $script:Age (& $script:Listing) 1

        Remove-DscV3StaleListing -Directory $script:Directory -Hours 24

        Test-Path -LiteralPath $recent | Should -BeTrue
    }

    It "Keeps the file just written, whatever its recorded time" {
        $mine = & $script:Age (& $script:Listing) 48

        Remove-DscV3StaleListing -Directory $script:Directory -Keep $mine -Hours 24

        Test-Path -LiteralPath $mine | Should -BeTrue
    }

    It "Removes a temporary file an interrupted write left behind" {
        $partial = & $script:Age (Join-Path $script:Directory ('{0}.json.{1}.tmp' -f (& $script:Hex 64), (& $script:Hex 32))) 48

        Remove-DscV3StaleListing -Directory $script:Directory -Hours 24

        Test-Path -LiteralPath $partial | Should -BeFalse
    }

    It "Leaves a file that is not one of ours" {
        $foreign = & $script:Age (Join-Path $script:Directory 'notes.txt') 48

        Remove-DscV3StaleListing -Directory $script:Directory -Hours 24

        Test-Path -LiteralPath $foreign | Should -BeTrue
    }

    It "Keeps a day's worth when the age limit is 0, which means a list is never used" {
        $old = & $script:Age (& $script:Listing) 48
        $recent = & $script:Age (& $script:Listing) 1

        Remove-DscV3StaleListing -Directory $script:Directory -Hours 0

        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
    }

    It "Says nothing and does nothing when the directory is not there" {
        { Remove-DscV3StaleListing -Directory (Join-Path $script:Directory 'missing') -Hours 24 } | Should -Not -Throw
    }
}

Describe "Test-DscV3ManifestLocation" -Tag Unit, Actions, Engine {

    BeforeAll {
        . (Get-FunctionPath 'Resolve-DscV3ResourcePath.ps1').FullName
    }

    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:SavedModulePath = $env:PSModulePath
        $script:Root = Join-Path $TestDrive ('where-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:OnPath = Join-Path $script:Root 'bin'
        $script:Modules = Join-Path $script:Root 'Modules'
        $script:Elsewhere = Join-Path $script:Root 'elsewhere'
        # A directory whose name begins with one on PATH, which must not count as inside it.
        $script:LookAlike = Join-Path $script:Root 'bin-other'
        foreach ($directory in $script:OnPath, (Join-Path $script:Modules 'Foo'), $script:Elsewhere, $script:LookAlike) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $script:Shell = (Get-Process -Id $PID).Path
        $env:PATH = '{0}{1}{2}' -f $script:OnPath, [System.IO.Path]::PathSeparator, (Split-Path -Path $script:Shell -Parent)
        $env:PSModulePath = $script:Modules
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        $env:PSModulePath = $script:SavedModulePath
    }

    It "Accepts a manifest in a directory on PATH" {
        Test-DscV3ManifestLocation -Path (Join-Path $script:OnPath 'x.dsc.resource.json') -Executable $script:Shell | Should -BeTrue
    }

    It "Accepts a manifest under a directory on PSModulePath" {
        Test-DscV3ManifestLocation -Path (Join-Path $script:Modules 'Foo/x.dsc.resource.json') -Executable $script:Shell | Should -BeTrue
    }

    It "Accepts a manifest beside the executable itself" {
        Test-DscV3ManifestLocation -Path (Join-Path (Split-Path -Path $script:Shell -Parent) 'x.dsc.resource.json') -Executable $script:Shell | Should -BeTrue
    }

    It "Refuses a manifest dsc would not find" {
        Test-DscV3ManifestLocation -Path (Join-Path $script:Elsewhere 'x.dsc.resource.json') -Executable $script:Shell | Should -BeFalse
    }

    It "Refuses a directory that merely starts with one on PATH" {
        Test-DscV3ManifestLocation -Path (Join-Path $script:LookAlike 'x.dsc.resource.json') -Executable $script:Shell | Should -BeFalse
    }

    It "Resolves a path that walks back out of a directory before deciding" {
        Test-DscV3ManifestLocation -Path (Join-Path $script:Elsewhere '../bin/x.dsc.resource.json') -Executable $script:Shell | Should -BeTrue
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
