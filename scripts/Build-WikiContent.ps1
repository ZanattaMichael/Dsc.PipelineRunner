<#
.SYNOPSIS
Compiles the GitHub Wiki content for Dsc.PipelineRunner into a publishable folder.

.DESCRIPTION
Produces the folder that the Publish_Wiki_Content build task pushes to the repository wiki. The wiki
has two halves and this script is what joins them:

  * Hand-written conceptual pages live in WikiSource/ and are copied verbatim. They are the
    authored documentation - layout, examples, explanation.
  * The command reference under Commands/ is GENERATED from each exported function's
    comment-based help, so it cannot drift from the code. Never hand-edit those pages; edit
    the help in source/Public/<Name>.ps1 and rebuild.

The command reference is produced by parsing each source file's AST and reading its
CommentHelpInfo, rather than by importing the built module and calling Get-Help. That keeps the
wiki buildable on a clean agent with no module dependencies resolved, which is what lets the
Wiki CI job run on every pull request instead of only at release time.

A _Sidebar.md is generated from the page order declared in WikiSource/.pageorder, so adding a
page is a one-line change and the navigation can never silently omit one.

.PARAMETER SourcePath
The repository root. Defaults to the parent of this script's directory.

.PARAMETER OutputPath
Where the compiled wiki is written. Defaults to <SourcePath>/output/WikiContent - the location
the Publish_Wiki_Content build task (.build/wiki.build.ps1) reads from.

.PARAMETER ModuleVersion
Version stamped into the generated pages. Defaults to the ModuleVersion in the source manifest.

.EXAMPLE
./scripts/Build-WikiContent.ps1 -Verbose

Compiles the wiki into ./output/WikiContent.

.EXAMPLE
./scripts/Build-WikiContent.ps1 -OutputPath /tmp/wiki

Compiles into an arbitrary folder, e.g. to preview the result locally.
#>
[CmdletBinding()]
param(
    [string] $SourcePath,
    [string] $OutputPath,
    [string] $ModuleVersion
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Split-Path -Path $PSScriptRoot -Parent
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = [System.IO.Path]::Combine($SourcePath, 'output', 'WikiContent')
}

$wikiSourcePath = [System.IO.Path]::Combine($SourcePath, 'WikiSource')
$publicPath     = [System.IO.Path]::Combine($SourcePath, 'source', 'Public')
$manifestPath   = [System.IO.Path]::Combine($SourcePath, 'source', 'Dsc.PipelineRunner.psd1')

if (-not (Test-Path -LiteralPath $wikiSourcePath)) {
    throw "[Build-WikiContent] WikiSource folder not found at '$wikiSourcePath'. The wiki's conceptual pages live there; without it there is nothing to publish."
}

if ([string]::IsNullOrWhiteSpace($ModuleVersion)) {
    if (Test-Path -LiteralPath $manifestPath) {
        # Import-PowerShellDataFile rather than Test-ModuleManifest: the latter validates
        # RequiredModules and fails on an agent that has not resolved dependencies.
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        $ModuleVersion = [string]$manifest.ModuleVersion
    }
    if ([string]::IsNullOrWhiteSpace($ModuleVersion)) { $ModuleVersion = '0.0.0' }
}

Write-Verbose "[Build-WikiContent] Source '$SourcePath', output '$OutputPath', version '$ModuleVersion'."

# Rebuild from scratch so a page deleted from WikiSource does not linger in the output and get
# republished to the wiki forever.
if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Recurse -Force
}
$null = New-Item -Path $OutputPath -ItemType Directory -Force

#region Conceptual pages

$conceptualPages = @(Get-ChildItem -LiteralPath $wikiSourcePath -Filter '*.md' -File | Sort-Object Name)
if ($conceptualPages.Count -eq 0) {
    throw "[Build-WikiContent] WikiSource contains no .md pages."
}

foreach ($page in $conceptualPages) {
    $destination = [System.IO.Path]::Combine($OutputPath, $page.Name)
    Copy-Item -LiteralPath $page.FullName -Destination $destination -Force
    Write-Verbose "[Build-WikiContent] Copied conceptual page '$($page.Name)'."
}

#endregion

#region Generated command reference

# Pull the exported surface from the manifest rather than from the file listing, so a helper
# that happens to live in source/Public but is not exported never appears in the reference.
$exportedFunction = @()
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $exportedFunction = @($manifest.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' })
}

function Get-WikiHelpContent {
    <#
        Returns the comment-based help and parameter metadata for the single function defined in
        a source file, read from the AST. Returns $null when the file defines no function.
    #>
    param([string] $Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "[Build-WikiContent] '$Path' failed to parse: $($parseErrors[0].Message)"
    }

    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    if ($null -eq $functionAst) { return $null }

    $help = $functionAst.GetHelpContent()

    # Parameter types come from the AST, not from the help block, so the documented type is
    # always the declared one.
    $parameterAst = @()
    if ($functionAst.Body.ParamBlock) {
        $parameterAst = @($functionAst.Body.ParamBlock.Parameters)
    }

    $parameters = foreach ($parameter in $parameterAst) {
        $parameterName = $parameter.Name.VariablePath.UserPath

        $typeName = 'Object'
        if ($parameter.StaticType) { $typeName = $parameter.StaticType.Name }

        $isMandatory = $false
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
            if ($attribute.TypeName.GetReflectionType() -ne [System.Management.Automation.ParameterAttribute] -and
                $attribute.TypeName.Name -ne 'Parameter') { continue }
            foreach ($namedArgument in $attribute.NamedArguments) {
                if ($namedArgument.ArgumentName -eq 'Mandatory') {
                    # 'Mandatory' on its own (no '= $true') is an implicit $true.
                    $isMandatory = $namedArgument.ExpressionOmitted -or "$($namedArgument.Argument)" -match 'true'
                }
            }
        }

        $description = ''
        if ($help -and $help.Parameters -and $help.Parameters.ContainsKey($parameterName.ToUpperInvariant())) {
            $description = $help.Parameters[$parameterName.ToUpperInvariant()]
        }

        [pscustomobject]@{
            Name        = $parameterName
            Type        = $typeName
            Mandatory   = $isMandatory
            Description = ($description -replace '\s*\r?\n\s*', ' ').Trim()
        }
    }

    return [pscustomobject]@{
        Name       = $functionAst.Name
        Help       = $help
        Parameters = @($parameters)
    }
}

$commandPages = [System.Collections.Generic.List[string]]::new()

foreach ($commandName in ($exportedFunction | Sort-Object)) {

    $commandPath = [System.IO.Path]::Combine($publicPath, "$commandName.ps1")
    if (-not (Test-Path -LiteralPath $commandPath)) {
        throw "[Build-WikiContent] Exported command '$commandName' has no source file at '$commandPath'. Either the manifest exports something that no longer exists, or the file was renamed."
    }

    $command = Get-WikiHelpContent -Path $commandPath
    if ($null -eq $command) {
        throw "[Build-WikiContent] '$commandPath' defines no function, so no reference page can be generated for exported command '$commandName'."
    }
    if ($null -eq $command.Help -or [string]::IsNullOrWhiteSpace($command.Help.Synopsis)) {
        throw "[Build-WikiContent] Command '$commandName' has no .SYNOPSIS in its comment-based help. Every exported command must be documented; add help to '$commandPath'."
    }

    $markdown = [System.Text.StringBuilder]::new()
    $null = $markdown.AppendLine("# $commandName")
    $null = $markdown.AppendLine()
    $null = $markdown.AppendLine('<!-- GENERATED FILE - do not edit here. This page is built from the comment-based')
    $null = $markdown.AppendLine("     help in source/Public/$commandName.ps1 by scripts/Build-WikiContent.ps1. -->")
    $null = $markdown.AppendLine()
    $null = $markdown.AppendLine('## Synopsis')
    $null = $markdown.AppendLine()
    $null = $markdown.AppendLine($command.Help.Synopsis.Trim())
    $null = $markdown.AppendLine()

    if (-not [string]::IsNullOrWhiteSpace($command.Help.Description)) {
        $null = $markdown.AppendLine('## Description')
        $null = $markdown.AppendLine()
        $null = $markdown.AppendLine($command.Help.Description.Trim())
        $null = $markdown.AppendLine()
    }

    if ($command.Parameters.Count -gt 0) {
        $null = $markdown.AppendLine('## Parameters')
        $null = $markdown.AppendLine()
        $null = $markdown.AppendLine('| Name | Type | Required | Description |')
        $null = $markdown.AppendLine('|---|---|---|---|')
        foreach ($parameter in $command.Parameters) {
            $required = if ($parameter.Mandatory) { 'Yes' } else { 'No' }
            $description = if ([string]::IsNullOrWhiteSpace($parameter.Description)) { '_Undocumented._' } else { $parameter.Description }
            $null = $markdown.AppendLine("| ``$($parameter.Name)`` | ``$($parameter.Type)`` | $required | $description |")
        }
        $null = $markdown.AppendLine()
    }

    $examples = @($command.Help.Examples)
    if ($examples.Count -gt 0) {
        $null = $markdown.AppendLine('## Examples')
        $null = $markdown.AppendLine()
        $exampleNumber = 0
        foreach ($example in $examples) {
            $exampleNumber++
            $null = $markdown.AppendLine("### Example $exampleNumber")
            $null = $markdown.AppendLine()
            $null = $markdown.AppendLine('```powershell')
            $null = $markdown.AppendLine($example.Trim())
            $null = $markdown.AppendLine('```')
            $null = $markdown.AppendLine()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($command.Help.Notes)) {
        $null = $markdown.AppendLine('## Notes')
        $null = $markdown.AppendLine()
        $null = $markdown.AppendLine($command.Help.Notes.Trim())
        $null = $markdown.AppendLine()
    }

    $pageName = "Command-$commandName.md"
    $pagePath = [System.IO.Path]::Combine($OutputPath, $pageName)
    Set-Content -LiteralPath $pagePath -Value $markdown.ToString() -Encoding utf8NoBOM
    $commandPages.Add($commandName)
    Write-Verbose "[Build-WikiContent] Generated command reference for '$commandName'."
}

if ($commandPages.Count -eq 0) {
    throw "[Build-WikiContent] No command reference pages were generated. The manifest's FunctionsToExport appears to be empty."
}

# The command index is generated too, so a newly exported command appears in the wiki without
# anyone remembering to link it.
$indexMarkdown = [System.Text.StringBuilder]::new()
$null = $indexMarkdown.AppendLine('# Command reference')
$null = $indexMarkdown.AppendLine()
$null = $indexMarkdown.AppendLine('<!-- GENERATED FILE - do not edit here. See scripts/Build-WikiContent.ps1. -->')
$null = $indexMarkdown.AppendLine()
$null = $indexMarkdown.AppendLine('Every command exported by `Dsc.PipelineRunner`. These pages are generated from each')
$null = $indexMarkdown.AppendLine('command''s comment-based help, so they always match the shipped code.')
$null = $indexMarkdown.AppendLine()
foreach ($commandName in $commandPages) {
    $commandPath = [System.IO.Path]::Combine($publicPath, "$commandName.ps1")
    $synopsis = (Get-WikiHelpContent -Path $commandPath).Help.Synopsis.Trim() -replace '\s*\r?\n\s*', ' '
    $null = $indexMarkdown.AppendLine("- **[$commandName](Command-$commandName)** — $synopsis")
}
$null = $indexMarkdown.AppendLine()
Set-Content -LiteralPath ([System.IO.Path]::Combine($OutputPath, 'Command-Reference.md')) -Value $indexMarkdown.ToString() -Encoding utf8NoBOM

#endregion

#region Sidebar and footer

# Navigation order is declared, not inferred from filenames, so the sidebar reads in a sensible
# teaching order rather than alphabetically.
$pageOrderPath = [System.IO.Path]::Combine($wikiSourcePath, '.pageorder')
if (-not (Test-Path -LiteralPath $pageOrderPath)) {
    throw "[Build-WikiContent] '$pageOrderPath' not found. It declares the sidebar order; every page in WikiSource must be listed in it."
}

$declaredOrder = @(Get-Content -LiteralPath $pageOrderPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') })

$availablePages = @($conceptualPages | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })

# Fail on either kind of drift: a page nobody can navigate to, or a sidebar entry pointing at
# a page that no longer exists.
$missingFromOrder = @($availablePages | Where-Object { $_ -notin $declaredOrder -and $_ -ne '_Footer' })
if ($missingFromOrder.Count -gt 0) {
    throw "[Build-WikiContent] These WikiSource pages are not listed in .pageorder, so nothing would link to them: $($missingFromOrder -join ', ')."
}
$missingPages = @($declaredOrder | Where-Object { $_ -notin $availablePages })
if ($missingPages.Count -gt 0) {
    throw "[Build-WikiContent] .pageorder lists pages that do not exist in WikiSource: $($missingPages -join ', ')."
}

$sidebar = [System.Text.StringBuilder]::new()
$null = $sidebar.AppendLine('<!-- GENERATED FILE - edit WikiSource/.pageorder instead. -->')
$null = $sidebar.AppendLine()
$null = $sidebar.AppendLine('### Dsc.PipelineRunner')
$null = $sidebar.AppendLine()
foreach ($pageName in $declaredOrder) {
    # The H1 of each page is its display name, so the sidebar cannot drift from the page title.
    $pageFile = [System.IO.Path]::Combine($wikiSourcePath, "$pageName.md")
    $heading = (Get-Content -LiteralPath $pageFile -TotalCount 20 | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1)
    $title = if ($heading) { ($heading -replace '^#\s+', '').Trim() } else { $pageName -replace '-', ' ' }
    $null = $sidebar.AppendLine("- [$title]($pageName)")
}
$null = $sidebar.AppendLine("- [Command reference](Command-Reference)")
foreach ($commandName in $commandPages) {
    $null = $sidebar.AppendLine("  - [$commandName](Command-$commandName)")
}
$null = $sidebar.AppendLine()
Set-Content -LiteralPath ([System.IO.Path]::Combine($OutputPath, '_Sidebar.md')) -Value $sidebar.ToString() -Encoding utf8NoBOM

$footer = @"
<!-- GENERATED FILE - edit scripts/Build-WikiContent.ps1 instead. -->

---
Dsc.PipelineRunner $ModuleVersion — generated from
[the repository](https://github.com/ZanattaMichael/Dsc.PipelineRunner) on $([datetime]::UtcNow.ToString('yyyy-MM-dd')).
Conceptual pages are authored in ``WikiSource/``; command pages are generated from
comment-based help. Edit those, not the wiki: **the wiki is overwritten on every release.**
"@
Set-Content -LiteralPath ([System.IO.Path]::Combine($OutputPath, '_Footer.md')) -Value $footer -Encoding utf8NoBOM

#endregion

$written = @(Get-ChildItem -LiteralPath $OutputPath -Filter '*.md' -File)
Write-Verbose "[Build-WikiContent] Wrote $($written.Count) page(s) to '$OutputPath'."

[pscustomobject]@{
    OutputPath       = $OutputPath
    ModuleVersion    = $ModuleVersion
    ConceptualPages  = $conceptualPages.Count
    CommandPages     = $commandPages.Count
    TotalPages       = $written.Count
}
