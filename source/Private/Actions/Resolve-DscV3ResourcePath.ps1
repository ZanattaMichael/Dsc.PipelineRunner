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
the cache.

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
        $listingKey = '{0}|{1}' -f $Executable, $env:PATH
        if (-not $store.Listings.ContainsKey($listingKey)) {
            $store.Listings[$listingKey] = $null
            $listed = Invoke-DscExecutable -Executable $Executable -Arguments @('resource', 'list', '--output-format', 'json')
            if ($listed.ExitCode -ne 0) {
                Write-Verbose "[Resolve-DscV3ResourcePath] 'dsc resource list' exited $($listed.ExitCode); using full discovery."
            }
            else {
                # One JSON object per line, one line per resource.
                $index = @{}
                foreach ($line in ([string]$listed.Output -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $item = $line | ConvertFrom-Json
                    $itemType = [string]$item.type
                    if (-not $index.ContainsKey($itemType)) { $index[$itemType] = [System.Collections.Generic.List[object]]::new() }
                    $index[$itemType].Add($item)
                }
                $store.Listings[$listingKey] = $index
            }
        }
        $listing = $store.Listings[$listingKey]

        if ($null -ne $listing) {
            $entries = @(if ($listing.ContainsKey($ResourceType)) { $listing[$ResourceType] })

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

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
        if ([System.IO.File].GetMethods() | Where-Object { $_.Name -eq 'SetUnixFileMode' -and $_.GetParameters()[0].ParameterType -eq [string] }) {
            [System.IO.File]::SetUnixFileMode($root, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        else {
            & chmod 700 $root
            if ($LASTEXITCODE -ne 0) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                throw "Could not restrict the staging directory '$root' to its owner."
            }
        }
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
