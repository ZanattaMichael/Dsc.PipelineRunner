<#
.SYNOPSIS
Finds where one DSC v3 resource's manifest is, so dsc can be told to look only there.

.DESCRIPTION
Every `dsc resource get|test|set` starts with resource discovery: dsc reads every directory on
PATH for manifests and runs every discover extension it finds. dsc 3.3 ships one,
Microsoft.PowerShell/Discover, which starts a second PowerShell to look through PSModulePath.
It runs whether or not the resource is a PowerShell one, so a native resource such as
Microsoft.Windows/Registry pays for a PowerShell start on every call - seconds per call on a
Windows agent, and the runner makes two or three calls per resource.

This function runs the full discovery once per run (one unfiltered `dsc resource list`, indexed
by type, however many types a configuration uses), and when a type is a plain command resource
it copies that one manifest into a directory of its own. The directories are created under an
unguessable, owner-only staging root in the temp directory, so another local user cannot
pre-create or swap one: the manifest decides which executable dsc runs. The DscV3 engine then calls dsc with DSC_RESOURCE_PATH set to that
directory, and the resource's own directory first on PATH so its executable is still found.
dsc then discovers exactly one manifest and starts nothing else.

A resource is left to full discovery (the function returns $null) when it is anything but a
plain command resource: an adapted resource (requireAdapter is set, for example a PowerShell
class resource behind Microsoft.DSC/PowerShell), an adapter, a group, a manifest that names
a script beside it (which dsc resolves from the manifest's own directory), a type dsc lists more than once, or when `dsc resource list` fails. It is also
left alone when the operator has set DSC_RESOURCE_PATH, or set
PIPELINERUNNER_DSC_FULL_DISCOVERY to 1 or true to turn this off.

The listing is cached per executable and PATH, and the answer per type, for the life of the
process, so the full discovery runs once per run; Clear-DscV3ResourcePath removes the copies and
the cache. The listing is also saved on disk for later runs (see Get-DscV3ResourceListing), so
a run whose dsc, PATH and PSModulePath have not changed since the last one skips the full
discovery altogether.

.PARAMETER ResourceType
The DSC v3 type, for example 'Microsoft.Windows/Registry'.

.PARAMETER Executable
The dsc executable. Defaults to 'dsc' (resolved on PATH).

.OUTPUTS
$null, or [pscustomobject] @{ ResourcePath = <directory holding the one manifest>;
ExecutableDirectory = <the manifest's own directory> }.
#>
function Resolve-DscV3ResourcePath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [string]$Executable = 'dsc'
    )

    if ([string]$env:PIPELINERUNNER_DSC_FULL_DISCOVERY -in '1', 'true') {
        return $null
    }
    # The operator chose where dsc looks; that choice is theirs to keep.
    if (-not [string]::IsNullOrEmpty($env:DSC_RESOURCE_PATH)) {
        return $null
    }

    $store = Get-DscV3ResourcePathStore
    if ($store.FullDiscovery.ContainsKey($ResourceType)) {
        return $null
    }
    $cacheKey = '{0}|{1}|{2}' -f $Executable, $ResourceType, $env:PATH
    if ($store.Cache.ContainsKey($cacheKey)) {
        return $store.Cache[$cacheKey]
    }

    $resolved = $null
    try {
        # One unfiltered list per executable and PATH: `dsc resource list <type>` is itself a
        # full discovery, so listing per type would pay the cost being removed once per type.
        # The list is also kept on disk between runs (Get-DscV3ResourceListing).
        $listingKey = '{0}|{1}' -f $Executable, $env:PATH
        if (-not $store.Listings.ContainsKey($listingKey)) {
            $store.Listings[$listingKey] = Get-DscV3ResourceListing -Executable $Executable
        }
        $listing = $store.Listings[$listingKey]

        # A list read from disk is checked against the manifest it names: if that file has
        # gone or changed since, or sits somewhere dsc would not look, the list is not used -
        # it is dropped and dsc lists again. The second check matters because the saved file
        # says which manifest to copy, and a manifest says which executable dsc runs: a list
        # that points outside dsc's own search path is not one this run should act on, and
        # what dsc itself reports is taken instead.
        if ($null -ne $listing -and $listing.FromDisk -and $listing.Index.ContainsKey($ResourceType)) {
            $reason = $null
            foreach ($item in $listing.Index[$ResourceType]) {
                $file = [System.IO.FileInfo]::new([string]$item.path)
                if (-not $file.Exists -or [string]$file.LastWriteTimeUtc.Ticks -ne [string]$item.manifestTicks -or [string]$file.Length -ne [string]$item.manifestLength) {
                    $reason = 'the manifest it names has gone or changed'
                    break
                }
                if (-not (Test-DscV3ManifestLocation -Path $file.FullName -Executable $Executable)) {
                    $reason = "the manifest it names is outside the directories dsc searches ($($file.FullName))"
                    break
                }
            }
            if ($reason) {
                Write-Verbose "[Resolve-DscV3ResourcePath] Not using the saved resource list for '$ResourceType': $reason; listing again."
                Remove-DscV3PersistedListing -Executable $Executable
                $listing = Get-DscV3ResourceListing -Executable $Executable -Refresh
                $store.Listings[$listingKey] = $listing
            }
        }

        if ($null -ne $listing) {
            $entries = @(if ($listing.Index.ContainsKey($ResourceType)) { $listing.Index[$ResourceType] })

            if ($entries.Count -ne 1) {
                Write-Verbose "[Resolve-DscV3ResourcePath] dsc lists $($entries.Count) resources of type '$ResourceType'; using full discovery."
            }
            else {
                $entry = $entries[0]
                $manifestPath = [string]$entry.path
                if ([string]$entry.kind -ne 'resource' -or $entry.requireAdapter -or
                    [string]::IsNullOrEmpty($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    Write-Verbose "[Resolve-DscV3ResourcePath] '$ResourceType' is not a plain command resource (kind '$($entry.kind)', adapter '$($entry.requireAdapter)'); using full discovery."
                }
                else {
                    $manifestDirectory = Split-Path -Path $manifestPath -Parent
                    $manifestName = Split-Path -Path $manifestPath -Leaf
                    $manifestText = Get-Content -LiteralPath $manifestPath -Raw

                    # A manifest that names a script beside it needs its own directory, which a
                    # copy elsewhere would not have. An executable is found on PATH, where the
                    # manifest's directory is put first, so only scripts count here. File names
                    # compare without regard to case: a Windows manifest may name Setup.PS1 for
                    # setup.ps1.
                    $scriptExtensions = '.ps1', '.psm1', '.psd1', '.sh', '.py', '.rb', '.js', '.cmd', '.bat'
                    $namesSibling = Get-ChildItem -LiteralPath $manifestDirectory -File |
                        Where-Object { $_.Extension -in $scriptExtensions -and $manifestText.IndexOf($_.Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } |
                        Select-Object -First 1
                    if ($namesSibling) {
                        Write-Verbose "[Resolve-DscV3ResourcePath] The manifest of '$ResourceType' names '$($namesSibling.Name)' beside it; using full discovery."
                    }
                    else {
                        if (-not $store.Root) {
                            $store.Root = New-DscV3StagingRoot
                        }
                        $directory = Join-Path -Path $store.Root -ChildPath ('{0:D3}' -f $store.Cache.Count)
                        $null = New-Item -ItemType Directory -Path $directory -Force
                        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $directory $manifestName) -Force
                        $resolved = [pscustomobject]@{
                            ResourcePath        = $directory
                            ExecutableDirectory = $manifestDirectory
                        }
                        Write-Verbose "[Resolve-DscV3ResourcePath] '$ResourceType' is discovered from its own manifest only: $manifestPath"
                    }
                }
            }
        }
    }
    catch {
        Write-Verbose "[Resolve-DscV3ResourcePath] Could not narrow discovery for '$ResourceType': $($_.Exception.Message); using full discovery."
        $resolved = $null
    }

    $store.Cache[$cacheKey] = $resolved
    return $resolved
}

<#
.SYNOPSIS
Creates the staging root for the copied manifests, under a name no one can guess, for the owner only.

.DESCRIPTION
The manifest in a staging directory decides which executable dsc runs, so the directory must not
be one another local user can create first or write into. The name carries a random GUID rather
than the process id, creation fails when the directory already exists (an existing one is not
ours), and on Linux and macOS the directory is restricted to its owner (mode 0700). The Windows
temp directory is per-user already.
#>
function New-DscV3StagingRoot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()

    $root = Get-DscV3StagingRootPath
    if ([System.IO.Directory]::Exists($root) -or [System.IO.File]::Exists($root)) {
        throw "The staging directory '$root' already exists; refusing to use it."
    }
    if (-not $PSCmdlet.ShouldProcess($root, 'Create the staging directory')) {
        return $null
    }
    $null = [System.IO.Directory]::CreateDirectory($root)

    try {
        Set-DscV3OwnerOnly -Path $root
    }
    catch {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return $root
}

<#
.SYNOPSIS
A new, unguessable path for the staging root. Separate so a test can point it at a directory that exists.
#>
function Get-DscV3StagingRootPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('Dsc.PipelineRunner-dsc-{0}' -f [guid]::NewGuid().ToString('N'))
}

<#
.SYNOPSIS
The process-wide store behind Resolve-DscV3ResourcePath: @{ Cache = @{}; Listings = @{}; FullDiscovery = @{}; Root = <dir> }.

.DESCRIPTION
The DscV3 engine is a script file that Invoke-Action runs for every call, and a variable a
function sets in $script: scope from inside it lives only as long as that script runs. The
store is kept on the AppDomain instead, so it lasts for the process - one Invoke-DscRunner -
and is the same whether the functions are loaded as the module or dot-sourced by a test.
#>
function Get-DscV3ResourcePathStore {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $name = 'Dsc.PipelineRunner.DscV3ResourcePath'
    $store = [System.AppDomain]::CurrentDomain.GetData($name)
    if ($null -eq $store) {
        $store = @{ Cache = @{}; Listings = @{}; FullDiscovery = @{}; Root = $null }
        [System.AppDomain]::CurrentDomain.SetData($name, $store)
    }
    return $store
}

<#
.SYNOPSIS
Forgets what Resolve-DscV3ResourcePath found, or marks one type as needing full discovery.

.PARAMETER ResourceType
Mark only this type for full discovery for the rest of the run (the DscV3
engine does this when a narrowed call reports that dsc could not find the resource or its
executable). Without it, every entry is forgotten and the copied manifests are removed.
#>
function Clear-DscV3ResourcePath {
    [CmdletBinding()]
    param(
        [string]$ResourceType
    )

    $store = Get-DscV3ResourcePathStore

    if ($PSBoundParameters.ContainsKey('ResourceType')) {
        $store.FullDiscovery[$ResourceType] = $true
        # The saved list led to a manifest dsc could not use, so the next run lists again.
        Remove-DscV3PersistedListing
        return
    }

    $store.Cache = @{}
    $store.Listings = @{}
    $store.FullDiscovery = @{}
    if ($store.Root -and (Test-Path -LiteralPath $store.Root)) {
        Remove-Item -LiteralPath $store.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $store.Root = $null
}

<#
.SYNOPSIS
Restricts a directory to its owner (mode 0700) on Linux and macOS. Does nothing on Windows,
where the per-user profile and temp directories are already private.
#>
function Set-DscV3OwnerOnly {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Unix) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict to its owner')) {
        return
    }
    if ([System.IO.File].GetMethods() | Where-Object { $_.Name -eq 'SetUnixFileMode' -and $_.GetParameters()[0].ParameterType -eq [string] }) {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
    else {
        & chmod 700 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restrict '$Path' to its owner."
        }
    }
}

<#
.SYNOPSIS
Where saved resource lists are kept, created owner-only; $null when there is no safe place.

.DESCRIPTION
A saved list decides which manifest is copied, and a manifest decides which executable dsc
runs, so the directory is the user's own: under LOCALAPPDATA on Windows, and under
XDG_CACHE_HOME or ~/.cache elsewhere, mode 0700. An existing directory that its group or
other users can write to is not used. PIPELINERUNNER_DSC_DISCOVERY_CACHE set to 0 or false
turns saving off, and PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH names another directory.
#>
function Get-DscV3DiscoveryCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]$env:PIPELINERUNNER_DSC_DISCOVERY_CACHE -in '0', 'false') {
        return $null
    }

    $directory = [string]$env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_PATH
    if ([string]::IsNullOrEmpty($directory)) {
        $isUnix = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix
        $base = if (-not $isUnix) { $env:LOCALAPPDATA }
        elseif (-not [string]::IsNullOrEmpty($env:XDG_CACHE_HOME)) { $env:XDG_CACHE_HOME }
        elseif (-not [string]::IsNullOrEmpty($HOME)) { Join-Path -Path $HOME -ChildPath '.cache' }
        if ([string]::IsNullOrEmpty($base)) {
            return $null
        }
        $directory = Join-Path -Path (Join-Path -Path $base -ChildPath 'Dsc.PipelineRunner') -ChildPath 'dsc-discovery'
    }

    try {
        if (-not [System.IO.Directory]::Exists($directory)) {
            $null = [System.IO.Directory]::CreateDirectory($directory)
            Set-DscV3OwnerOnly -Path $directory
        }
        elseif ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix -and
            ([System.IO.File].GetMethods() | Where-Object { $_.Name -eq 'GetUnixFileMode' -and $_.GetParameters()[0].ParameterType -eq [string] })) {
            $mode = [System.IO.File]::GetUnixFileMode($directory)
            $shared = [System.IO.UnixFileMode]'GroupWrite, OtherWrite'
            if (($mode -band $shared) -ne 0) {
                Write-Verbose "[Get-DscV3DiscoveryCacheDirectory] '$directory' can be written by other users; not saving the resource list."
                return $null
            }
        }
    }
    catch {
        Write-Verbose "[Get-DscV3DiscoveryCacheDirectory] Could not prepare '$directory': $($_.Exception.Message); not saving the resource list."
        return $null
    }
    return $directory
}

<#
.SYNOPSIS
A fingerprint of everything dsc's full discovery depends on, or $null when dsc is not found.

.DESCRIPTION
dsc finds manifests in the directories on PATH, and its PowerShell discover extension finds
resources in the module directories on PSModulePath. The fingerprint covers the dsc
executable (path, size and time), both variables, the last-write time of every directory they
name, and - for PSModulePath only - the name and time of each module directory inside them.
Installing or removing a resource adds or removes a file or folder in one of those places,
which changes a time the fingerprint covers, so the saved list is not used after it. The
module level matters because installing a second version of a module that is already there
adds Modules/<module>/<version>, which moves <module>'s time but not the Modules directory's.
#>
function Get-DscV3DiscoveryFingerprint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Executable = 'dsc'
    )

    $command = Get-Command -Name $Executable -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    $exe = [System.IO.FileInfo]::new($command.Source)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('Dsc.PipelineRunner discovery 1')
    $parts.Add(('{0}|{1}|{2}' -f $exe.FullName, $exe.Length, $exe.LastWriteTimeUtc.Ticks))
    foreach ($variable in 'PATH', 'PSModulePath') {
        $value = [string][System.Environment]::GetEnvironmentVariable($variable)
        $parts.Add("$variable=$value")
        foreach ($directory in ($value -split [regex]::Escape([string][System.IO.Path]::PathSeparator))) {
            if ([string]::IsNullOrWhiteSpace($directory) -or -not [System.IO.Directory]::Exists($directory)) {
                continue
            }
            $parts.Add(('{0}|{1}' -f $directory, [System.IO.Directory]::GetLastWriteTimeUtc($directory).Ticks))

            # A manifest sits directly in a directory on PATH, so that directory's own time
            # moves when one is added or removed. A module does not: PSModulePath names the
            # Modules directory, and installing a second version of a module already there
            # adds Modules/<module>/<version>, which moves only <module>'s time. So each
            # module directory counts too - one level, by name and time, not a walk of the
            # tree.
            if ($variable -ne 'PSModulePath') {
                continue
            }
            try {
                foreach ($module in ([System.IO.Directory]::GetDirectories($directory) | Sort-Object)) {
                    $parts.Add(('{0}|{1}' -f $module, [System.IO.Directory]::GetLastWriteTimeUtc($module).Ticks))
                }
            }
            catch {
                # A directory that cannot be read now is one dsc cannot read either; the name
                # and time already recorded are enough to notice it changing.
                $parts.Add(('{0}|unreadable' -f $directory))
            }
        }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

<#
.SYNOPSIS
dsc's full resource list, indexed by type: from disk when a run with the same fingerprint saved
it, otherwise from one `dsc resource list`, which is then saved.

.DESCRIPTION
`dsc resource list` is a full discovery: on a hosted Windows agent about three seconds, most
of it the PowerShell discover extension. Every Invoke-DscRunner pays it once, so a pipeline
that runs the runner several times (a test, then a set, then a test) pays it each time. The
list is saved to Get-DscV3DiscoveryCacheDirectory under the fingerprint of what discovery
depends on (Get-DscV3DiscoveryFingerprint), with each manifest's size and time, and a later
run with the same fingerprint reads it instead. Resolve-DscV3ResourcePath checks the manifest
it is about to use against the saved size and time, and lists again when they differ. A list
older than PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS (default 24) is not used.

.PARAMETER Refresh
Ignore a saved list and run `dsc resource list`.

.OUTPUTS
$null when dsc could not list, or @{ Index = @{ <type> = List[object] }; FromDisk = <bool> }.
Each entry has type, kind, path, requireAdapter, manifestTicks and manifestLength.
#>
function Get-DscV3ResourceListing {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Executable = 'dsc',

        [switch]$Refresh
    )

    $file = $null
    $directory = Get-DscV3DiscoveryCacheDirectory
    if ($directory) {
        $fingerprint = Get-DscV3DiscoveryFingerprint -Executable $Executable
        if ($fingerprint) {
            $file = Join-Path -Path $directory -ChildPath "$fingerprint.json"
        }
    }

    $hours = 24
    if (-not [string]::IsNullOrEmpty($env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS)) {
        $parsedHours = 0
        if ([int]::TryParse([string]$env:PIPELINERUNNER_DSC_DISCOVERY_CACHE_HOURS, [ref]$parsedHours) -and $parsedHours -ge 0) {
            $hours = $parsedHours
        }
    }

    if ($file -and -not $Refresh -and [System.IO.File]::Exists($file)) {
        $age = [datetime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($file)
        if ($age.TotalHours -lt $hours) {
            try {
                $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                $index = @{}
                foreach ($item in @($saved.resources)) {
                    $itemType = [string]$item.type
                    if (-not $index.ContainsKey($itemType)) { $index[$itemType] = [System.Collections.Generic.List[object]]::new() }
                    $index[$itemType].Add($item)
                }
                Write-Verbose "[Get-DscV3ResourceListing] Using the resource list saved at $file."
                return @{ Index = $index; FromDisk = $true }
            }
            catch {
                Write-Verbose "[Get-DscV3ResourceListing] Could not read '$file': $($_.Exception.Message); listing again."
            }
        }
    }

    $listed = Invoke-DscExecutable -Executable $Executable -Arguments @('resource', 'list', '--output-format', 'json')
    if ($listed.ExitCode -ne 0) {
        Write-Verbose "[Get-DscV3ResourceListing] 'dsc resource list' exited $($listed.ExitCode); using full discovery."
        return $null
    }

    # One JSON object per line, one line per resource. Only what the narrowing reads is kept.
    $index = @{}
    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ([string]$listed.Output -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $item = $line | ConvertFrom-Json
        $manifest = [System.IO.FileInfo]::new([string]$item.path)
        $entry = [pscustomobject]@{
            type           = [string]$item.type
            kind           = [string]$item.kind
            path           = [string]$item.path
            requireAdapter = [string]$item.requireAdapter
            manifestTicks  = if ($manifest.Exists) { [string]$manifest.LastWriteTimeUtc.Ticks } else { '' }
            manifestLength = if ($manifest.Exists) { [string]$manifest.Length } else { '' }
        }
        $resources.Add($entry)
        if (-not $index.ContainsKey($entry.type)) { $index[$entry.type] = [System.Collections.Generic.List[object]]::new() }
        $index[$entry.type].Add($entry)
    }

    if ($file) {
        $partial = '{0}.{1}.tmp' -f $file, [guid]::NewGuid().ToString('N')
        try {
            # Written beside the final name and moved over it, so a reader never sees half a file.
            Set-Content -LiteralPath $partial -Value (@{ resources = $resources } | ConvertTo-Json -Depth 4 -Compress) -Encoding utf8
            Move-Item -LiteralPath $partial -Destination $file -Force
        }
        catch {
            Write-Verbose "[Get-DscV3ResourceListing] Could not save the resource list to '$file': $($_.Exception.Message)."
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
        Remove-DscV3StaleListing -Directory (Split-Path -Path $file -Parent) -Keep $file -Hours $hours
    }
    return @{ Index = $index; FromDisk = $false }
}

<#
.SYNOPSIS
Is this manifest somewhere dsc looks: a directory on PATH, beside dsc itself, or under a
directory on PSModulePath?

.DESCRIPTION
Only a list read from disk is checked this way. A fresh list came from dsc a moment ago, so
wherever it points is where dsc found it; a saved one is a file from an earlier run, and it
decides which manifest the engine copies and therefore which executable dsc runs. Requiring
the manifest to be somewhere dsc searches keeps a saved list from sending the engine
anywhere dsc would not have gone by itself. A manifest that is genuinely somewhere else
still works: the saved list is dropped, dsc lists again, and this run narrows from that.

.PARAMETER Path
The manifest's full path.

.PARAMETER Executable
The dsc executable, whose own directory counts as one dsc looks in.
#>
function Test-DscV3ManifestLocation {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Executable = 'dsc'
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($variable in 'PATH', 'PSModulePath', 'DSC_RESOURCE_PATH') {
        $value = [string][System.Environment]::GetEnvironmentVariable($variable)
        foreach ($directory in ($value -split [regex]::Escape([string][System.IO.Path]::PathSeparator))) {
            if (-not [string]::IsNullOrWhiteSpace($directory)) { $roots.Add($directory) }
        }
    }
    $command = Get-Command -Name $Executable -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($command) { $roots.Add((Split-Path -Path $command.Source -Parent)) }

    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
        [System.StringComparison]::Ordinal
    }
    else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    $full = $null
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    foreach ($root in $roots) {
        $rootFull = $null
        try {
            $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }
        catch {
            continue
        }
        if ([string]::IsNullOrEmpty($rootFull)) { continue }
        # Under the directory, not merely sharing its first characters: /usr/bin-other is not
        # inside /usr/bin.
        $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, $comparison)) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Removes saved lists no run will use again, so the cache directory does not grow for ever.

.DESCRIPTION
A list is saved under the fingerprint of what discovery depends on, and a new fingerprint
means a new file: a PATH change, an installed module, a touched directory. Nothing ever reads
the old one again, so after a list is written the ones past their useful age are deleted,
along with any temporary file an interrupted write left behind. Only this module's own files
are considered: <64 hex characters>.json and its .tmp files.

.PARAMETER Directory
The cache directory.

.PARAMETER Keep
The file just written, which is never removed however the clock behaves.

.PARAMETER Hours
How long a saved list may be used. 0 means a list is never used, in which case a day's worth
is still kept, so that turning the age limit off does not turn pruning into deleting
everything another run may be part-way through reading.
#>
function Remove-DscV3StaleListing {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [string]$Keep,

        [int]$Hours = 24
    )

    $window = if ($Hours -gt 0) { $Hours } else { 24 }
    $cutoff = [datetime]::UtcNow.AddHours(-$window)
    try {
        $files = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop |
                Where-Object { $_.Name -match '^[0-9a-f]{64}\.json(\.[0-9a-f]{32}\.tmp)?$' })
    }
    catch {
        Write-Verbose "[Remove-DscV3StaleListing] Could not read '$Directory': $($_.Exception.Message)."
        return
    }

    foreach ($file in $files) {
        if ($Keep -and $file.FullName -eq $Keep) { continue }
        if ($file.LastWriteTimeUtc -ge $cutoff) { continue }
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove the saved resource list')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
Removes the saved resource list for the current fingerprint, so the next run lists again.
#>
function Remove-DscV3PersistedListing {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Executable = 'dsc'
    )

    $directory = Get-DscV3DiscoveryCacheDirectory
    if (-not $directory) { return }
    $fingerprint = Get-DscV3DiscoveryFingerprint -Executable $Executable
    if (-not $fingerprint) { return }
    $file = Join-Path -Path $directory -ChildPath "$fingerprint.json"
    if ([System.IO.File]::Exists($file) -and $PSCmdlet.ShouldProcess($file, 'Remove the saved resource list')) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
