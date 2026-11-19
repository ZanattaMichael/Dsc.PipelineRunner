<#
.SYNOPSIS
Reads a configuration's data files and says which policy layer owns each of them, and what each
one declares (issue #86, Part B).

.DESCRIPTION
A policy is enforced against a *compiled* configuration, which needs Datum, a node and a run. This
is the static view: every data file in the configuration, the layer the policy attributes it to,
and the resource declarations it contains. It is what makes a policy legible before it bites, and
it is how a policy that is silently ineffective is found - a layer whose Paths match no file at
all is almost always a typo, and a typo in Paths moves files into '(unclaimed)', which may run
nothing.

It is deliberately tolerant: a file that cannot be parsed is reported, not thrown, because the
point of the report is to describe a configuration an operator is still working on.

What it is *not*: the merge. It does not know Datum's resolution precedence, lookup options,
conditions or composite expansion, so what it says about a resource is what the files declare, not
necessarily what will run. Callers must present it as advisory; the run is authoritative.

.PARAMETER ConfigurationPath
The configuration root (the folder that holds Datum.yml).

.PARAMETER Policy
The policy from Import-CapabilityPolicy.

.OUTPUTS
[pscustomobject] Files, Layers, UnmatchedLayers, UnclaimedFiles, Declarations and UnreadableFiles.
#>
function Get-CapabilityPolicyCoverage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [Parameter(Mandatory)]
        [hashtable] $Policy
    )

    $root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ConfigurationPath).ProviderPath).TrimEnd('\', '/')

    $files = [System.Collections.Generic.List[object]]::new()
    $declarations = [System.Collections.Generic.List[object]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    $matchedLayers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $dataFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -in '.yml', '.yaml', '.json', '.psd1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        Sort-Object FullName

    foreach ($file in $dataFiles) {
        $layerPath = ConvertTo-PolicyLayerPath -Root $root -FullName $file.FullName
        if ([string]::IsNullOrWhiteSpace($layerPath)) { continue }

        # The policy file is at the root, outside the Datum tree. It is not a layer file and must
        # not be reported as an unclaimed one.
        $isPolicyFile = ($file.DirectoryName.TrimEnd('\', '/') -eq $root -and $file.Name -in 'Policy.yml', 'Policy.yaml')
        if ($isPolicyFile) { continue }

        $layer = Get-PolicyLayer -Policy $Policy -RelativePath $layerPath
        if ($layer -ne '(unclaimed)') { $null = $matchedLayers.Add($layer) }
        $files.Add([pscustomobject]@{ Path = $layerPath; File = ($file.FullName.Substring($root.Length + 1) -replace '\\', '/'); Layer = $layer })

        $document = $null
        try {
            $document = switch ($file.Extension) {
                '.json' { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable }
                '.psd1' { Import-PowerShellDataFile -LiteralPath $file.FullName }
                default { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Yaml }
            }
        }
        catch {
            $unreadable.Add("$($file.FullName.Substring($root.Length + 1) -replace '\\', '/'): $($_.Exception.Message)")
            continue
        }
        if ($document -isnot [System.Collections.IDictionary]) { continue }

        $resourceList = $null
        foreach ($key in @($document.Keys)) { if ([string]$key -ieq 'resources') { $resourceList = $document[$key] } }
        foreach ($resource in @($resourceList)) {
            if ($resource -isnot [System.Collections.IDictionary]) { continue }
            $read = { param([string] $Name) foreach ($key in @($resource.Keys)) { if ([string]$key -ieq $Name) { return $resource[$key] } } return $null }

            $target = & $read 'target'
            $targetAction = $null
            $computerName = $null
            $targetCredential = $null
            if ($target -is [System.Collections.IDictionary]) {
                foreach ($key in @($target.Keys)) {
                    switch -Regex ([string]$key) {
                        '^(?i)action$'       { $targetAction = [string]$target[$key] }
                        '^(?i)computerName$' { $computerName = [string]$target[$key] }
                        '^(?i)credential$'   { $targetCredential = $target[$key] }
                    }
                }
            }

            $credentialActions = [System.Collections.Generic.List[string]]::new()
            foreach ($block in @($targetCredential, (& $read 'resourceCredential'))) {
                if ($null -eq $block) { continue }
                $action = 'Environment'
                if ($block -is [System.Collections.IDictionary]) {
                    foreach ($key in @($block.Keys)) { if ([string]$key -ieq 'action' -and -not [string]::IsNullOrWhiteSpace([string]$block[$key])) { $action = [string]$block[$key] } }
                }
                if ($action -notin $credentialActions) { $credentialActions.Add($action) }
            }

            $declarations.Add([pscustomobject]@{
                Path              = $layerPath
                Layer             = $layer
                Name              = [string](& $read 'name')
                Type              = [string](& $read 'type')
                TargetAction      = $targetAction
                ComputerName      = $computerName
                CredentialActions = [string[]]$credentialActions.ToArray()
                ExecutionScript   = ($null -ne (& $read 'preExecutionScript') -or $null -ne (& $read 'postExecutionScript'))
                Notify            = [string[]]@(@(& $read 'notify') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            })
        }
    }

    $layerSummary = foreach ($layer in $Policy.Layers) {
        [pscustomobject]@{
            Name      = [string]$layer.Name
            Paths     = [string[]]$layer.Paths
            FileCount = @($files | Where-Object { $_.Layer -eq [string]$layer.Name }).Count
        }
    }

    return [pscustomobject]@{
        ConfigurationPath = $root
        Files             = @($files)
        Layers            = @($layerSummary)
        UnmatchedLayers   = [string[]]@($Policy.Layers | Where-Object { -not $matchedLayers.Contains([string]$_.Name) } | ForEach-Object { [string]$_.Name })
        UnclaimedFiles    = [string[]]@($files | Where-Object { $_.Layer -eq '(unclaimed)' } | ForEach-Object { $_.File })
        Declarations      = @($declarations)
        UnreadableFiles   = [string[]]$unreadable.ToArray()
    }
}
