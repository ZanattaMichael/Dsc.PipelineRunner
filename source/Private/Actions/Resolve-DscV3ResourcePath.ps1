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

This function runs the full discovery once per resource type for the run (`dsc resource list
<type>`), and when the type is a plain command resource it copies that one manifest into a
directory of its own. The DscV3 engine then calls dsc with DSC_RESOURCE_PATH set to that
directory, and the resource's own directory first on PATH so its executable is still found.
dsc then discovers exactly one manifest and starts nothing else.

A resource is left to full discovery (the function returns $null) when it is anything but a
plain command resource: an adapted resource (requireAdapter is set, for example a PowerShell
class resource behind Microsoft.DSC/PowerShell), an adapter, a group, a manifest that names
a script beside it (which dsc resolves from the manifest's own directory), a type dsc lists more than once, or when `dsc resource list` fails. It is also
left alone when the operator has set DSC_RESOURCE_PATH, or set
PIPELINERUNNER_DSC_FULL_DISCOVERY to 1 or true to turn this off.

The answer is cached per executable, type and PATH for the life of the process, so the full
discovery runs once per type; Clear-DscV3ResourcePath removes the copies and the cache.

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
    $cacheKey = '{0}|{1}|{2}' -f $Executable, $ResourceType, $env:PATH
    if ($store.Cache.ContainsKey($cacheKey)) {
        return $store.Cache[$cacheKey]
    }

    $resolved = $null
    try {
        $listed = Invoke-DscExecutable -Executable $Executable -Arguments @('resource', 'list', $ResourceType, '--output-format', 'json')
        if ($listed.ExitCode -ne 0) {
            Write-Verbose "[Resolve-DscV3ResourcePath] 'dsc resource list $ResourceType' exited $($listed.ExitCode); using full discovery."
        }
        else {
            # One JSON object per line, one line per resource.
            $entries = @([string]$listed.Output -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { [string]$_.type -eq $ResourceType })

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
                    # manifest's directory is put first, so only scripts count here.
                    $scriptExtensions = '.ps1', '.psm1', '.psd1', '.sh', '.py', '.rb', '.js', '.cmd', '.bat'
                    $namesSibling = Get-ChildItem -LiteralPath $manifestDirectory -File |
                        Where-Object { $_.Extension -in $scriptExtensions -and $manifestText.Contains($_.Name) } |
                        Select-Object -First 1
                    if ($namesSibling) {
                        Write-Verbose "[Resolve-DscV3ResourcePath] The manifest of '$ResourceType' names '$($namesSibling.Name)' beside it; using full discovery."
                    }
                    else {
                        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('Dsc.PipelineRunner-dsc-{0}' -f $PID)
                        $directory = Join-Path -Path $root -ChildPath ('{0:D3}' -f $store.Cache.Count)
                        $null = New-Item -ItemType Directory -Path $directory -Force
                        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $directory $manifestName) -Force
                        $store.Root = $root
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
The process-wide store behind Resolve-DscV3ResourcePath: @{ Cache = @{}; Root = <dir> }.

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
        $store = @{ Cache = @{}; Root = $null }
        [System.AppDomain]::CurrentDomain.SetData($name, $store)
    }
    return $store
}

<#
.SYNOPSIS
Forgets what Resolve-DscV3ResourcePath found, or that one type must use full discovery.

.PARAMETER ResourceType
Forget only this type and mark it for full discovery for the rest of the run (the DscV3
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
        foreach ($key in @($store.Cache.Keys)) {
            if ($key.Split('|')[1] -eq $ResourceType) {
                $store.Cache[$key] = $null
            }
        }
        return
    }

    $store.Cache = @{}
    if ($store.Root -and (Test-Path -LiteralPath $store.Root)) {
        Remove-Item -LiteralPath $store.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $store.Root = $null
}
