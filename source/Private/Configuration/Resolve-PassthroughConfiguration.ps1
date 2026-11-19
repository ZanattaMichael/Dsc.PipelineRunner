<#
.SYNOPSIS
Resolves the configuration documents of a passthrough run - one the caller compiled
themselves (issue #106).

.DESCRIPTION
A passthrough run hands the runner documents it did not compile, so there is no cache
directory to enumerate and no Datum hierarchy to derive names from. This helper turns
-ConfigurationFile / -ConfigurationDirectory into the list of full paths Start-DscRunner is
called with, and refuses the inputs that would otherwise fail later or fail confusingly:

  * a path that does not exist, or that is not of the kind the parameter names;
  * an extension no loader understands (.yml, .yaml and .json are the three Start-DscRunner
    accepts);
  * a directory with no documents in it, which would otherwise be a clean run of nothing;
  * two documents whose file names match, because the file name IS the node name - the report
    files are written as <node>.csv / <node>.report.json, so a duplicate would silently
    overwrite the first node's report and give two result rows the same NodeName.

Every bad path is named in one message rather than one at a time, matching the
collect-all-then-throw-once pattern the pre-parse rules use.

The file system is asked directly ([System.IO.File] / [System.IO.Directory]) rather than
through Test-Path / Get-ChildItem. A configuration path is data: a '[' in a directory name is
a wildcard to the provider cmdlets, and the answer here decides what code the runner executes,
so it must be about a real path on disk. This is the same reason Resolve-CapabilityPolicyPath
reads the file system directly.

.PARAMETER ConfigurationFile
One or more compiled configuration documents. Order is preserved: the runner processes them in
the order the caller listed them.

.PARAMETER ConfigurationDirectory
A directory of compiled configuration documents. Every *.yml, *.yaml and *.json file directly
in it is run, in name order, except two kinds of file that are never node documents: the sidecars
the runner itself writes (<node>.report.json, <node>.state.json, <node>.rsop.json,
<node>.provenance.json) - a caller who points this at a directory that has also been used as a
-ReportPath should not have last run's report fed back in as a configuration - and a
configuration root's own Datum.yml / Policy.yml. The directory is not searched recursively.

.OUTPUTS
[string[]] The full path of each document, in the order it should be run.
#>
function Resolve-PassthroughConfiguration {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ConfigurationFile,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ConfigurationDirectory
    )

    # Extensions Start-DscRunner can load. Kept here as well so a directory of documents is
    # filtered by the same rule the file form is validated against.
    $supportedExtension = @('.yml', '.yaml', '.json')

    # Sidecars the runner writes beside a node's output. Excluded from a directory listing
    # only - a caller who names one explicitly has said what they meant.
    $sidecarSuffix = @('.report.json', '.state.json', '.rsop.json', '.provenance.json')

    # A configuration root's own two files are never node documents, and both are *.yml. Without
    # this, pointing -ConfigurationDirectory at a configuration repository would try to run
    # Datum.yml as a configuration and fail with 'no resources section' instead of saying what is
    # actually wrong. Excluded from a directory listing only, like the sidecars above.
    $rootFileName = @('Datum.yml', 'Datum.yaml', 'Policy.yml', 'Policy.yaml')

    $hasFile = @($ConfigurationFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    $hasDirectory = -not [string]::IsNullOrWhiteSpace($ConfigurationDirectory)

    if ($hasFile -and $hasDirectory) {
        throw "[Resolve-PassthroughConfiguration] -ConfigurationFile and -ConfigurationDirectory cannot both be supplied; name the documents or the directory that holds them, not both."
    }
    if (-not $hasFile -and -not $hasDirectory) {
        throw "[Resolve-PassthroughConfiguration] Supply either -ConfigurationFile or -ConfigurationDirectory."
    }

    # Resolve relative paths against the caller's current directory the way the rest of the
    # module does, and collapse any '..' segments without touching the file system.
    $currentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath

    $resolved = [System.Collections.Generic.List[string]]::new()

    if ($hasFile) {
        $problems = [System.Collections.Generic.List[string]]::new()

        foreach ($path in @($ConfigurationFile)) {
            if ([string]::IsNullOrWhiteSpace($path)) { continue }

            $full = $null
            try { $full = [System.IO.Path]::GetFullPath($path, $currentDirectory) }
            catch { $problems.Add("'$path' is not a usable path: $($_.Exception.Message)"); continue }

            if (-not [System.IO.File]::Exists($full)) {
                # Named a directory by mistake: say which parameter they wanted.
                if ([System.IO.Directory]::Exists($full)) {
                    $problems.Add("'$path' is a directory; use -ConfigurationDirectory for a directory of documents.")
                }
                else {
                    $problems.Add("'$path' does not exist.")
                }
                continue
            }

            $extension = [System.IO.Path]::GetExtension($full)
            if ($extension -notin $supportedExtension) {
                $problems.Add("'$path' has the extension '$extension'; a configuration document must be $($supportedExtension -join ', ').")
                continue
            }

            $resolved.Add($full)
        }

        if ($problems.Count -gt 0) {
            throw "[Resolve-PassthroughConfiguration] $($problems.Count) problem(s) with -ConfigurationFile:`n  - $($problems -join "`n  - ")"
        }
    }
    else {
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($ConfigurationDirectory, $currentDirectory) }
        catch { throw "[Resolve-PassthroughConfiguration] -ConfigurationDirectory '$ConfigurationDirectory' is not a usable path: $($_.Exception.Message)" }

        if (-not [System.IO.Directory]::Exists($full)) {
            if ([System.IO.File]::Exists($full)) {
                throw "[Resolve-PassthroughConfiguration] -ConfigurationDirectory '$ConfigurationDirectory' is a file; use -ConfigurationFile to run a single document."
            }
            throw "[Resolve-PassthroughConfiguration] -ConfigurationDirectory '$ConfigurationDirectory' does not exist."
        }

        $candidates = [System.IO.Directory]::GetFiles($full) | Where-Object {
            $name = [System.IO.Path]::GetFileName($_)
            ([System.IO.Path]::GetExtension($name) -in $supportedExtension) -and
            ($name -notin $rootFileName) -and
            -not ($sidecarSuffix | Where-Object { $name.EndsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })
        } | Sort-Object -Property { [System.IO.Path]::GetFileName($_) }

        if (@($candidates).Count -eq 0) {
            throw "[Resolve-PassthroughConfiguration] -ConfigurationDirectory '$ConfigurationDirectory' contains no configuration document ($($supportedExtension -join ', ')). A run of no documents would otherwise report success."
        }

        foreach ($candidate in @($candidates)) { $resolved.Add([string]$candidate) }
    }

    # The file name is the node name (Start-DscRunner derives it with
    # GetFileNameWithoutExtension), and the node name names the report files and every result
    # row. Two documents that share one are a mistake worth naming rather than a run whose
    # second node quietly overwrites the first node's report.
    $byNode = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $resolved) {
        $node = [System.IO.Path]::GetFileNameWithoutExtension($path)
        if (-not $byNode.ContainsKey($node)) { $byNode[$node] = [System.Collections.Generic.List[string]]::new() }
        $byNode[$node].Add($path)
    }

    $duplicates = @($byNode.Keys | Where-Object { $byNode[$_].Count -gt 1 } | Sort-Object)
    if ($duplicates.Count -gt 0) {
        $detail = $duplicates | ForEach-Object { "$_ ($($byNode[$_] -join ', '))" }
        throw "[Resolve-PassthroughConfiguration] $($duplicates.Count) node name(s) are used by more than one document: $($detail -join '; '). A document's file name is its node name, so each one must be unique within a run."
    }

    return [string[]]$resolved.ToArray()
}
