<#
Security regression suite: what the project downloads and runs is pinned and verified.

The runner installs a program (dsc) from the internet, builds a container image, and runs
third-party GitHub Actions. Each is a place where a moved tag or a swapped download would change
what executes. These tests pin the controls:

  * Install-DscV3.ps1 checks the SHA-256 of the archive BEFORE extracting it, from the lock file
    first, then GitHub's published digest, and refuses to install when it has nothing to check
    against (unless explicitly told not to),
  * every third-party action is pinned to a commit SHA,
  * the container base image is pinned by digest and the image runs as a non-root user,
  * Dependabot keeps those pins current,
  * the release records a build provenance attestation.

The installer tests run the real script against a real archive built on the fly; only the two
network calls are mocked. Dummy data only.
#>
Describe "Security: downloads, actions and images are pinned and verified" -Tag Unit, Security {

    BeforeAll {
        $script:root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
        $script:installer = Join-Path $script:root 'scripts/Install-DscV3.ps1'

        # --- A real archive, named the way the installer's asset selection expects ----------------
        $script:onWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }
        $script:onMac = [bool]$IsMacOS
        $cpu = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        $script:arch = switch ($cpu) { 'x64' { 'x86_64' } 'arm64' { 'aarch64' } default { $null } }
        $script:canRun = $null -ne $script:arch

        if ($script:canRun) {
            $script:assetName = if ($script:onWindows) { "DSC-3.9.9-$($script:arch)-pc-windows-msvc.zip" }
                                elseif ($script:onMac) { "DSC-3.9.9-$($script:arch)-apple-darwin.tar.gz" }
                                else { "DSC-3.9.9-$($script:arch)-unknown-linux-gnu.tar.gz" }
            $staging = Join-Path $TestDrive 'staging'
            $null = New-Item -ItemType Directory -Path $staging
            $exeName = if ($script:onWindows) { 'dsc.exe' } else { 'dsc' }
            Set-Content -LiteralPath (Join-Path $staging $exeName) -Value 'fake dsc'
            $script:archive = Join-Path $TestDrive $script:assetName
            if ($script:onWindows) { Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $script:archive }
            else { & tar -czf $script:archive -C $staging $exeName }
            $Global:SupplyChainArchive = $script:archive
            $script:archiveHash = (Get-FileHash -LiteralPath $script:archive -Algorithm SHA256).Hash.ToLowerInvariant()
            $script:downloadedCopy = Join-Path ([System.IO.Path]::GetTempPath()) $script:assetName
        }

        $script:otherHash = ('0' * 64)

        Mock -CommandName Write-Host
        Mock -CommandName Write-Information
        Mock -CommandName Write-Verbose

        # Builds the fake GitHub release the installer resolves.
        function New-FakeRelease {
            param([string]$Digest)
            $asset = [pscustomobject]@{ name = $script:assetName; browser_download_url = 'https://example.invalid/asset' }
            if ($Digest) { $asset | Add-Member -NotePropertyName digest -NotePropertyValue $Digest }
            [pscustomobject]@{ tag_name = 'v3.9.9'; assets = @($asset) }
        }

        function New-LockFile {
            param([hashtable]$Releases = @{}, [string]$DefaultVersion = 'v3.9.9')
            $path = Join-Path $TestDrive ("lock-" + [guid]::NewGuid().ToString('N') + '.json')
            @{ defaultVersion = $DefaultVersion; releases = $Releases } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
            return $path
        }

        # Runs the installer into a fresh directory and reports what happened.
        function Invoke-Installer {
            param([hashtable]$Arguments, [string]$Digest)
            $Global:SupplyChainRelease = New-FakeRelease -Digest $Digest
            $target = Join-Path $TestDrive ("install-" + [guid]::NewGuid().ToString('N'))
            $savedPath = $env:PATH; $savedGitHubPath = $env:GITHUB_PATH
            $env:GITHUB_PATH = $null
            $thrown = $null; $result = $null
            try {
                $result = & $script:installer -InstallDirectory $target @Arguments 3>&1
            }
            catch { $thrown = $_.Exception.Message }
            finally { $env:PATH = $savedPath; $env:GITHUB_PATH = $savedGitHubPath }
            [pscustomobject]@{ Thrown = $thrown; Output = @($result); Target = $target }
        }
    }

    BeforeEach {
        if ($script:canRun) {
            Remove-Item -LiteralPath $script:downloadedCopy -Force -ErrorAction SilentlyContinue
            $Global:SupplyChainUris = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Invoke-RestMethod -MockWith {
                param($Uri, $Headers)
                $Global:SupplyChainUris.Add([string]$Uri)
                return $Global:SupplyChainRelease
            }
            Mock -CommandName Invoke-WebRequest -MockWith {
                param($Uri, $OutFile, $Headers)
                Copy-Item -LiteralPath $Global:SupplyChainArchive -Destination $OutFile -Force
            }
        }
    }

    AfterAll {
        Remove-Variable -Name SupplyChainUris, SupplyChainRelease, SupplyChainArchive -Scope Global -ErrorAction SilentlyContinue
    }

    Context "Install-DscV3.ps1 verifies the archive before it is extracted" {
        # -Skip is evaluated during Pester discovery, before BeforeAll runs, so it cannot use the
        # variables set above; it asks the same question (is this a CPU the installer supports?)
        # directly. Skipping only ever happens on an architecture the installer itself rejects.

        It "installs when the archive matches the hash pinned in the lock file" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{ 'v3.9.9' = @{ $script:assetName = $script:archiveHash } }

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest "sha256:$($script:archiveHash)"

            $run.Thrown | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $run.Target -Recurse -File).Count | Should -BeGreaterThan 0
        }

        It "refuses, discards the download and installs nothing when the pinned hash does not match" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{ 'v3.9.9' = @{ $script:assetName = $script:otherHash } }

            # GitHub's own digest agrees with the real archive: the PIN is what must win.
            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest "sha256:$($script:archiveHash)"

            $run.Thrown | Should -Match 'SHA-256 mismatch'
            $run.Thrown | Should -Match 'nothing was installed'
            @(Get-ChildItem -LiteralPath $run.Target -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            Test-Path -LiteralPath $script:downloadedCopy | Should -BeFalse
        }

        It "refuses an asset that is missing from a pinned release" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{ 'v3.9.9' = @{ 'some-other-asset.tar.gz' = $script:archiveHash } }

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest "sha256:$($script:archiveHash)"

            $run.Thrown | Should -Match 'is not listed'
            @(Get-ChildItem -LiteralPath $run.Target -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It "falls back to GitHub's published digest for a release that is not pinned, and warns" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{}

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest "sha256:$($script:archiveHash)"

            $run.Thrown | Should -BeNullOrEmpty
            ($run.Output | Out-String) | Should -Match 'not pinned'
        }

        It "refuses an unpinned release whose archive does not match GitHub's digest" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{}

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest "sha256:$($script:otherHash)"

            $run.Thrown | Should -Match 'SHA-256 mismatch'
            @(Get-ChildItem -LiteralPath $run.Target -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It "refuses to install when there is nothing to verify the archive against" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{}

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock } -Digest $null

            $run.Thrown | Should -Match 'No SHA-256 is available'
            @(Get-ChildItem -LiteralPath $run.Target -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It "installs an unverifiable archive only with -AllowUnverified, and says so" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{}

            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock; AllowUnverified = $true } -Digest $null

            $run.Thrown | Should -BeNullOrEmpty
            ($run.Output | Out-String) | Should -Match 'WITHOUT verification'
        }

        It "lets an explicit -Sha256 override both the lock file and GitHub's digest" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{ 'v3.9.9' = @{ $script:assetName = $script:otherHash } }

            $accepted = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock; Sha256 = $script:archiveHash } -Digest "sha256:$($script:otherHash)"
            $rejected = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; ChecksumFile = $lock; Sha256 = $script:otherHash } -Digest "sha256:$($script:archiveHash)"

            $accepted.Thrown | Should -BeNullOrEmpty
            $rejected.Thrown | Should -Match 'SHA-256 mismatch'
        }

        It "rejects a malformed -Sha256 before downloading anything" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $run = Invoke-Installer -Arguments @{ Version = 'v3.9.9'; Sha256 = 'not-a-hash' } -Digest $null

            $run.Thrown | Should -Match 'Sha256'
            $Global:SupplyChainUris.Count | Should -Be 0
        }

        It "uses the lock file's defaultVersion when no -Version is given" -Skip:([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -notin 'X64', 'Arm64') {
            $lock = New-LockFile -Releases @{ 'v3.9.9' = @{ $script:assetName = $script:archiveHash } } -DefaultVersion 'v3.9.9'

            $run = Invoke-Installer -Arguments @{ ChecksumFile = $lock } -Digest "sha256:$($script:archiveHash)"

            $run.Thrown | Should -BeNullOrEmpty
            ($Global:SupplyChainUris -join "`n") | Should -Match '/tags/v3\.9\.9'
        }
    }

    Context "the checksum lock file" {

        It "is valid JSON with a default version" {
            $lock = Get-Content -LiteralPath (Join-Path $script:root 'scripts/dsc-checksums.json') -Raw | ConvertFrom-Json
            $lock.defaultVersion | Should -Match '\Av\d+\.\d+\.\d+\z'
            $null -ne $lock.PSObject.Properties['releases'] | Should -BeTrue
        }

        It "records only well-formed SHA-256 values" {
            $lock = Get-Content -LiteralPath (Join-Path $script:root 'scripts/dsc-checksums.json') -Raw | ConvertFrom-Json
            foreach ($release in $lock.releases.PSObject.Properties) {
                foreach ($asset in $release.Value.PSObject.Properties) {
                    $asset.Value | Should -Match '\A[0-9a-f]{64}\z' -Because "'$($release.Name)/$($asset.Name)' must be a lowercase SHA-256"
                }
            }
        }

        It "pins the release it names as the default" {
            $lock = Get-Content -LiteralPath (Join-Path $script:root 'scripts/dsc-checksums.json') -Raw | ConvertFrom-Json
            $pinned = $lock.releases.PSObject.Properties[[string]$lock.defaultVersion]
            $pinned | Should -Not -BeNullOrEmpty -Because "the default dsc version '$($lock.defaultVersion)' has no hashes in scripts/dsc-checksums.json; run scripts/Update-DscChecksums.ps1"
        }
    }

    Context "third-party GitHub Actions" {

        It "pins every action in <Name> to a full commit SHA, with the version in a comment" -ForEach @(
            Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../../.github/workflows') -Filter '*.yml' |
                ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
        ) {
            $uses = Select-String -LiteralPath $Path -Pattern '^\s*(?:-\s+)?uses:\s*(?<ref>\S+)(?<rest>.*)$' |
                ForEach-Object { [pscustomobject]@{ Ref = $_.Matches[0].Groups['ref'].Value; Rest = $_.Matches[0].Groups['rest'].Value } } |
                Where-Object { -not $_.Ref.StartsWith('./') }

            foreach ($entry in $uses) {
                $entry.Ref | Should -Match '@[0-9a-f]{40}\z' -Because "'$($entry.Ref)' in $Name must be pinned to a commit SHA, not a tag a maintainer can move"
                $entry.Rest | Should -Match '#\s*v\d' -Because "'$($entry.Ref)' in $Name should record which version the SHA is"
            }
        }

        It "has Dependabot keep the actions and the container image current" {
            $dependabot = Get-Content -LiteralPath (Join-Path $script:root '.github/dependabot.yml') -Raw
            $dependabot | Should -Match 'package-ecosystem:\s*github-actions'
            $dependabot | Should -Match 'package-ecosystem:\s*docker'
            $dependabot | Should -Match 'containers/dsc-agent'
        }
    }

    Context "the container image" {

        BeforeAll { $script:dockerfile = Get-Content -LiteralPath (Join-Path $script:root 'containers/dsc-agent/Dockerfile') -Raw }

        It "pins the base image by digest" {
            $script:dockerfile | Should -Match '(?m)^FROM\s+\S+@sha256:[0-9a-f]{64}\s*$'
        }

        It "runs as a non-root user" {
            $users = [regex]::Matches($script:dockerfile, '(?m)^USER\s+(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value }
            $users | Should -Not -BeNullOrEmpty
            @($users)[-1] | Should -Not -BeIn @('root', '0')
        }

        It "does not default to the moving 'latest' dsc release" {
            $script:dockerfile | Should -Not -Match '(?m)^ARG\s+DSC_VERSION=latest'
        }

        It "takes a GitHub token only as a BuildKit secret, never as a build argument or ENV" {
            $script:dockerfile | Should -Match '--mount=type=secret,id=github_token'
            $script:dockerfile | Should -Not -Match '(?mi)^\s*(ARG|ENV)\s+\w*(TOKEN|SECRET|PASSWORD)'
        }

        It "copies the lock file next to the installer, so the build verifies against it" {
            $script:dockerfile | Should -Match 'dsc-checksums\.json'
        }
    }

    Context "release provenance" {

        BeforeAll { $script:releaseWorkflow = Get-Content -LiteralPath (Join-Path $script:root '.github/workflows/Release.yml') -Raw }

        It "attests the packaged module with a pinned attestation action" {
            $script:releaseWorkflow | Should -Match 'actions/attest-build-provenance@[0-9a-f]{40}'
            $script:releaseWorkflow | Should -Match 'subject-path:\s*output/\*\.nupkg'
        }

        It "grants the publish job the permissions an attestation needs" {
            $script:releaseWorkflow | Should -Match 'id-token:\s*write'
            $script:releaseWorkflow | Should -Match 'attestations:\s*write'
        }
    }
}
