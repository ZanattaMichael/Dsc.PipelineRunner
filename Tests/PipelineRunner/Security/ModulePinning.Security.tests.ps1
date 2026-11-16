<#
Security regression suite: PowerShell Gallery modules are installed at exact, reviewed versions.

CI, the container image and the build install modules from the PowerShell Gallery. Taking
"whatever is newest" lets an upstream release (or a bad download) change what runs without any
change in this repository. These tests pin the controls:

  * scripts/module-versions.json lists every module at one exact version,
  * Install-PinnedModule.ps1 installs exactly that version, skips one already present, retries a
    failed download, verifies the result, and refuses a module that is not pinned,
  * RequiredModules.psd1 (the build tools) carries no 'latest' and agrees with the lock file,
  * no workflow, script or the Dockerfile runs a bare Install-Module.

The installer tests run the real script; only Install-Module, Get-Module and Start-Sleep are
mocked. Dummy module names only.
#>
Describe "Security: Gallery modules are installed at pinned versions" -Tag Unit, Security {

    BeforeAll {
        $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
        $script:installer = Join-Path $script:root 'scripts/Install-PinnedModule.ps1'
        $script:realLock = Join-Path $script:root 'scripts/module-versions.json'

        # The command is mocked below; this stub only guarantees there is something to mock on a
        # machine where PowerShellGet is not loaded.
        function Install-Module { param($Name, $RequiredVersion, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, [switch]$SkipPublisherCheck) }

        $script:fixtureLock = Join-Path $TestDrive 'module-versions.json'
        Set-Content -LiteralPath $script:fixtureLock -Value (@{
                modules = [ordered]@{
                    Alpha       = @{ version = '1.2.3' }
                    Beta        = @{ version = '4.5.6'; maxVersion = '4.9.9' }
                    Placeholder = @{ version = '0.0.0' }
                    Loose       = @{ version = '1.*' }
                }
            } | ConvertTo-Json -Depth 5)
    }

    BeforeEach {
        $Global:PinningInstalled = @()
        $Global:PinningInstallCalls = [System.Collections.Generic.List[hashtable]]::new()
        $Global:PinningFailFirst = 0
        Mock Start-Sleep { }
        Mock Get-Module {
            foreach ($entry in $Global:PinningInstalled) {
                if ($entry.Name -eq $Name) { [pscustomobject]@{ Name = $entry.Name; Version = [version]$entry.Version } }
            }
        }
        Mock Install-Module {
            $Global:PinningInstallCalls.Add(@{ Name = $Name; RequiredVersion = $RequiredVersion; Scope = $Scope })
            if ($Global:PinningFailFirst -gt 0) { $Global:PinningFailFirst--; throw 'End of Central Directory record could not be found.' }
            $Global:PinningInstalled += [pscustomobject]@{ Name = $Name; Version = $RequiredVersion }
        }
    }

    AfterAll {
        Remove-Variable -Name PinningInstalled, PinningInstallCalls, PinningFailFirst -Scope Global -ErrorAction SilentlyContinue
    }

    Context "the lock file" {

        BeforeAll { $script:lock = Get-Content -LiteralPath $script:realLock -Raw | ConvertFrom-Json }

        It "lists modules" {
            @($script:lock.modules.PSObject.Properties).Count | Should -BeGreaterThan 5
        }

        It "pins <Module> to one exact version" -ForEach @(
            (Get-Content -LiteralPath (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path 'scripts/module-versions.json') -Raw |
                ConvertFrom-Json).modules.PSObject.Properties | ForEach-Object { @{ Module = $_.Name; Version = [string]$_.Value.version } }
        ) {
            $Version | Should -Match '\A\d+\.\d+\.\d+(\.\d+)?\z' -Because 'a range, wildcard or "latest" is not a pin'
            $Version | Should -Not -Be '0.0.0' -Because 'that is the placeholder a new entry carries until it is resolved'
        }
    }

    Context "Install-PinnedModule.ps1" {

        It "installs the exact pinned version" {
            & $script:installer -Name Alpha -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $Name -eq 'Alpha' -and $RequiredVersion -eq '1.2.3' }
        }

        It "installs every module it is given, each at its own version" {
            & $script:installer -Name Alpha, Beta -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $Name -eq 'Alpha' -and $RequiredVersion -eq '1.2.3' }
            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $Name -eq 'Beta' -and $RequiredVersion -eq '4.5.6' }
        }

        It "passes the requested scope" {
            & $script:installer -Name Alpha -Scope AllUsers -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $Scope -eq 'AllUsers' }
        }

        It "matches the module name without regard to case" {
            & $script:installer -Name alpha -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $RequiredVersion -eq '1.2.3' }
        }

        It "leaves a module alone when that exact version is already installed" {
            $Global:PinningInstalled = @([pscustomobject]@{ Name = 'Alpha'; Version = '1.2.3' })

            & $script:installer -Name Alpha -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 0
        }

        It "installs the pinned version when only a different version is installed" {
            $Global:PinningInstalled = @([pscustomobject]@{ Name = 'Alpha'; Version = '9.9.9' })

            & $script:installer -Name Alpha -LockFile $script:fixtureLock -InformationAction SilentlyContinue

            Should -Invoke Install-Module -Exactly 1 -ParameterFilter { $RequiredVersion -eq '1.2.3' }
        }

        It "retries a failed download and then succeeds" {
            $Global:PinningFailFirst = 2

            { & $script:installer -Name Alpha -LockFile $script:fixtureLock -RetryDelaySeconds 0 -WarningAction SilentlyContinue -InformationAction SilentlyContinue } | Should -Not -Throw

            Should -Invoke Install-Module -Exactly 3
        }

        It "gives up after the maximum number of attempts, naming the module and version" {
            $Global:PinningFailFirst = 99

            { & $script:installer -Name Alpha -LockFile $script:fixtureLock -MaxAttempts 3 -RetryDelaySeconds 0 -WarningAction SilentlyContinue -InformationAction SilentlyContinue } |
                Should -Throw '*Alpha 1.2.3 after 3 attempts*'

            Should -Invoke Install-Module -Exactly 3
        }

        It "does not accept an install that left the module missing" {
            Mock Install-Module { }

            { & $script:installer -Name Alpha -LockFile $script:fixtureLock -MaxAttempts 2 -RetryDelaySeconds 0 -WarningAction SilentlyContinue -InformationAction SilentlyContinue } |
                Should -Throw '*not available afterwards*'
        }

        It "refuses a module that is not in the lock file, installing nothing" {
            { & $script:installer -Name Stranger -LockFile $script:fixtureLock -InformationAction SilentlyContinue } | Should -Throw '*not pinned*'

            Should -Invoke Install-Module -Exactly 0
        }

        It "refuses a module whose pin is the placeholder or is not an exact version: <Module>" -ForEach @(
            @{ Module = 'Placeholder' }
            @{ Module = 'Loose' }
        ) {
            { & $script:installer -Name $Module -LockFile $script:fixtureLock -InformationAction SilentlyContinue } | Should -Throw '*no usable pinned version*'

            Should -Invoke Install-Module -Exactly 0
        }

        It "refuses to run without a lock file" {
            { & $script:installer -Name Alpha -LockFile (Join-Path $TestDrive 'missing.json') } | Should -Throw '*was not found*'
        }
    }

    Context "the build tools in RequiredModules.psd1" {

        BeforeAll {
            $script:required = Import-PowerShellDataFile -LiteralPath (Join-Path $script:root 'RequiredModules.psd1')
            $script:lockModules = (Get-Content -LiteralPath $script:realLock -Raw | ConvertFrom-Json).modules
        }

        It "uses no moving version ('latest', a range or a wildcard)" {
            $moving = $script:required.GetEnumerator() |
                Where-Object { $_.Key -ne 'PSDependOptions' -and ([string]$_.Value) -notmatch '\A\d+\.\d+\.\d+(\.\d+)?\z' } |
                ForEach-Object { "$($_.Key) = $($_.Value)" }
            @($moving) | Should -BeNullOrEmpty
        }

        It "agrees with the lock file for every module they share" {
            $disagree = foreach ($entry in $script:required.GetEnumerator()) {
                if ($entry.Key -eq 'PSDependOptions') { continue }
                $pinned = $script:lockModules.PSObject.Properties | Where-Object { $_.Name -ieq $entry.Key } | Select-Object -First 1
                if ($pinned -and [string]$pinned.Value.version -ne [string]$entry.Value) { "$($entry.Key): RequiredModules=$($entry.Value) lock=$($pinned.Value.version)" }
            }
            @($disagree) | Should -BeNullOrEmpty
        }
    }

    Context "no bare Install-Module" {

        BeforeAll {
            # AzureDevOpsDscNative is the one deliberate exception: the Azure DevOps integration jobs
            # exist to test against the newest release the Gallery publishes, prereleases included.
            # Resolve-Dependency.ps1 is the Sampler-generated bootstrap that fetches PSDepend itself.
            $files = @(Get-ChildItem -LiteralPath (Join-Path $script:root '.github/workflows') -Filter *.yml -File) +
                @(Get-Item -LiteralPath (Join-Path $script:root 'containers/dsc-agent/Dockerfile')) +
                @(Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter *.ps1 -File)
            $script:offences = foreach ($file in $files) {
                if ($file.Name -in 'Install-PinnedModule.ps1') { continue }
                $number = 0
                foreach ($line in Get-Content -LiteralPath $file.FullName) {
                    $number++
                    $code = $line.Trim()
                    if ($code.StartsWith('#')) { continue }
                    if ($code -match '\bInstall-Module\b' -and $code -notmatch 'AzureDevOpsDscNative' -and $code -notmatch 'Install-PinnedModule') {
                        '{0}:{1}: {2}' -f $file.Name, $number, $code
                    }
                }
            }
        }

        It "runs every Gallery install through Install-PinnedModule.ps1" {
            @($script:offences) | Should -BeNullOrEmpty -Because 'a bare Install-Module takes whatever is newest'
        }

        It "starts the installer in the image with -Command, because -File cannot bind a module list" {
            $dockerfile = Get-Content -LiteralPath (Join-Path $script:root 'containers/dsc-agent/Dockerfile') -Raw
            $dockerfile | Should -Not -Match '-File\s+\S*Install-PinnedModule\.ps1' -Because 'pwsh -File passes each token as a literal string, so "-Name A, B" fails to bind'
            $dockerfile | Should -Match "-Command\s+`"&\s+'[^']*Install-PinnedModule\.ps1'"
        }

        It "gives the container image the helper and the lock file" {
            $dockerfile = Get-Content -LiteralPath (Join-Path $script:root 'containers/dsc-agent/Dockerfile') -Raw
            $dockerfile | Should -Match 'Install-PinnedModule\.ps1'
            $dockerfile | Should -Match 'module-versions\.json'
        }
    }
}
