<#
    .SYNOPSIS
        Build task that compiles the wiki from WikiSource/ and the module's comment-based help.

    .DESCRIPTION
        Wraps scripts/Build-WikiContent.ps1 so the wiki can be built by the ordinary build
        pipeline, and so Sampler.GitHubTasks' Publish_GitHub_Wiki_Content finds content in the
        folder it expects ($OutputDirectory/WikiContent).

        The script is deliberately AST-based and never imports the module, so this task runs on
        a clean agent with no resolved dependencies - which is what makes it usable as a
        per-pull-request check rather than only a release step.
#>
# All four parameters below are read inside the task's script block, not in the script body.
# PSScriptAnalyzer's PSReviewUnusedParameter does not traverse a script block passed as an
# argument to a command, so it reports every InvokeBuild task parameter as unused. Same false
# positive already suppressed for $Context in Actions/Connect/None.ps1.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputDirectory',
    Justification = 'Read inside the Build_Wiki_Content task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectPath',
    Justification = 'Read inside the Build_Wiki_Content task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'WikiContentFolderName',
    Justification = 'Read inside the Build_Wiki_Content task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ModuleVersion',
    Justification = 'Read inside the Build_Wiki_Content task script block, which PSReviewUnusedParameter does not traverse.')]
param(
    # Output directory, supplied by Build.ps1.
    [Parameter()]
    [string]
    $OutputDirectory = (property OutputDirectory 'output'),

    [Parameter()]
    [string]
    $ProjectPath = (property ProjectPath $BuildRoot),

    # The folder name Sampler.GitHubTasks' Publish_GitHub_Wiki_Content pushes to the wiki.
    [Parameter()]
    [string]
    $WikiContentFolderName = (property WikiContentFolderName 'WikiContent'),

    [Parameter()]
    [string]
    $ModuleVersion = (property ModuleVersion '')
)

task Build_Wiki_Content {

    if (-not (Split-Path -IsAbsolute -Path $OutputDirectory))
    {
        $OutputDirectory = Join-Path -Path $ProjectPath -ChildPath $OutputDirectory
    }

    $wikiOutputPath = Join-Path -Path $OutputDirectory -ChildPath $WikiContentFolderName
    $buildScript = Join-Path -Path $ProjectPath -ChildPath 'scripts/Build-WikiContent.ps1'

    if (-not (Test-Path -LiteralPath $buildScript))
    {
        throw "The wiki build script was not found at '$buildScript'."
    }

    $scriptArgs = @{
        SourcePath = $ProjectPath
        OutputPath = $wikiOutputPath
    }

    # Let the script read the version from the manifest when the build has not resolved one.
    if (-not [string]::IsNullOrWhiteSpace($ModuleVersion))
    {
        $scriptArgs.ModuleVersion = $ModuleVersion
    }

    $result = & $buildScript @scriptArgs

    Write-Build Green ("Wiki content built: {0} conceptual page(s), {1} command page(s), {2} total, in '{3}'." -f `
        $result.ConceptualPages, $result.CommandPages, $result.TotalPages, $result.OutputPath)
}
