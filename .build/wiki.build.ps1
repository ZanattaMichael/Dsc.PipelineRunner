<#
    .SYNOPSIS
        Build tasks that compile the wiki from WikiSource/ and the module's comment-based
        help, and publish the result to this repository's GitHub wiki.

    .DESCRIPTION
        Build_Wiki_Content wraps scripts/Build-WikiContent.ps1 so the wiki can be built by the
        ordinary build pipeline into $OutputDirectory/WikiContent.

        Publish_Wiki_Content pushes that folder to <owner>/<repo>.wiki.git. It is a local task
        on purpose. The task of the same shape upstream (Publish_GitHub_Wiki_Content) lives in
        DscResource.DocGenerator, which this module does not depend on and which brings a whole
        conceptual-help/markdown toolchain with it; the publish itself is a clone, a copy, a
        commit and a push, so it is written here rather than taking that dependency.

        Build-WikiContent.ps1 is deliberately AST-based and never imports the module, so
        Build_Wiki_Content runs on a clean agent with no resolved dependencies - which is what
        lets .github/workflows/Wiki.yml call the script directly as a per-pull-request drift
        check. Publishing, by contrast, runs only on a full (non-preview) release; see the
        'Publish wiki content' step in .github/workflows/Release.yml.
#>
# Every parameter below is read inside a task's script block, not in the script body.
# PSScriptAnalyzer's PSReviewUnusedParameter does not traverse a script block passed as an
# argument to a command, so it reports every InvokeBuild task parameter as unused. Same false
# positive already suppressed for $Context in Actions/Connect/None.ps1.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputDirectory',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectPath',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'WikiContentFolderName',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ModuleVersion',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GitHubToken',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GitHubConfigUserName',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GitHubConfigUserEmail',
    Justification = 'Read inside a task script block, which PSReviewUnusedParameter does not traverse.')]
param(
    # Output directory, supplied by Build.ps1.
    [Parameter()]
    [string]
    $OutputDirectory = (property OutputDirectory 'output'),

    [Parameter()]
    [string]
    $ProjectPath = (property ProjectPath $BuildRoot),

    # The folder under $OutputDirectory that Build_Wiki_Content writes and
    # Publish_Wiki_Content pushes to the wiki.
    [Parameter()]
    [string]
    $WikiContentFolderName = (property WikiContentFolderName 'WikiContent'),

    [Parameter()]
    [string]
    $ModuleVersion = (property ModuleVersion ''),

    # Set by the release workflow from secrets.GITHUB_TOKEN. Publish_Wiki_Content self-guards
    # on this being present, so running the task locally is a no-op rather than an error.
    [Parameter()]
    [string]
    $GitHubToken = (property GitHubToken ''),

    [Parameter()]
    [string]
    $GitHubConfigUserName = (property GitHubConfigUserName 'github-actions[bot]'),

    [Parameter()]
    [string]
    $GitHubConfigUserEmail = (property GitHubConfigUserEmail '41898282+github-actions[bot]@users.noreply.github.com')
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

task Publish_Wiki_Content {

    # Every exit path below writes one line here and none of them throw. The release workflow
    # runs this after the Gallery package and the GitHub Release already exist, so a wiki that
    # has never been initialised - or a token without wiki scope - must not turn a successful
    # release red. Reporting to the step summary is what keeps that from being silent, which is
    # the failure mode the previous continue-on-error step had.
    $summary = {
        param([string]$Message)

        Write-Build Yellow $Message

        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY))
        {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Message -Encoding utf8
        }
    }

    if (-not (Split-Path -IsAbsolute -Path $OutputDirectory))
    {
        $OutputDirectory = Join-Path -Path $ProjectPath -ChildPath $OutputDirectory
    }

    $wikiOutputPath = Join-Path -Path $OutputDirectory -ChildPath $WikiContentFolderName

    if (-not (Test-Path -LiteralPath $wikiOutputPath))
    {
        & $summary "Wiki: **not published** - '$wikiOutputPath' does not exist. Run Build_Wiki_Content first."
        return
    }

    $pages = @(Get-ChildItem -LiteralPath $wikiOutputPath -File -Recurse)

    if ($pages.Count -eq 0)
    {
        & $summary "Wiki: **not published** - '$wikiOutputPath' is empty."
        return
    }

    if ([string]::IsNullOrWhiteSpace($GitHubToken))
    {
        & $summary 'Wiki: not published - no GitHubToken was supplied. This is expected outside the release workflow.'
        return
    }

    # Derive owner/repo from the checkout rather than hard-coding it, so a fork publishes to
    # the fork's own wiki.
    $originUrl = (& git -C $ProjectPath remote get-url origin 2>$null)

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl))
    {
        & $summary "Wiki: **not published** - could not read the 'origin' remote of '$ProjectPath'."
        return
    }

    if ($originUrl -notmatch '(?:github\.com[:/])(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?\s*$')
    {
        & $summary "Wiki: **not published** - the 'origin' remote is not a recognisable GitHub URL."
        return
    }

    $owner = $Matches.owner
    $repo = $Matches.repo
    $wikiUrl = "https://github.com/$owner/$repo.wiki.git"

    # The token is passed through git's credential-less header form instead of being embedded
    # in the remote URL, so it cannot end up in .git/config, in `git remote -v`, or in an error
    # message that git prints with the URL.
    $authHeader = 'AUTHORIZATION: basic ' +
        [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("x-access-token:$GitHubToken"))

    # Same config key actions/checkout uses. Scoped to the host rather than to the single wiki
    # URL because git matches this key by URL prefix.
    $authConfigKey = 'http.https://github.com/.extraheader'

    $clonePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wiki-$([System.Guid]::NewGuid().ToString('n'))")

    try
    {
        $null = & git -c "$authConfigKey=$authHeader" clone --quiet $wikiUrl $clonePath 2>&1

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $clonePath))
        {
            & $summary ("Wiki: **not published** - could not clone $owner/$repo.wiki.git. " +
                'The wiki has to be enabled and given its first page in the repository settings before it can be pushed to.')
            return
        }

        # Mirror rather than merge: a page deleted from WikiSource/ or a command removed from
        # the module has to disappear from the wiki too, otherwise the wiki accumulates pages
        # that nothing in this repository still describes.
        Get-ChildItem -LiteralPath $clonePath -Force |
            Where-Object -FilterScript { $_.Name -ne '.git' } |
            Remove-Item -Recurse -Force

        Copy-Item -Path (Join-Path -Path $wikiOutputPath -ChildPath '*') -Destination $clonePath -Recurse -Force

        $null = & git -C $clonePath config user.name $GitHubConfigUserName
        $null = & git -C $clonePath config user.email $GitHubConfigUserEmail
        $null = & git -C $clonePath add --all

        if (-not (& git -C $clonePath status --porcelain))
        {
            & $summary "Wiki: already up to date - $($pages.Count) page(s) match $owner/$repo.wiki."
            return
        }

        $commitMessage = if ([string]::IsNullOrWhiteSpace($ModuleVersion))
        {
            'Update wiki content'
        }
        else
        {
            "Update wiki content for v$ModuleVersion"
        }

        $null = & git -C $clonePath commit --quiet --message $commitMessage 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            & $summary 'Wiki: **not published** - the wiki commit failed.'
            return
        }

        $null = & git -C $clonePath -c "$authConfigKey=$authHeader" push --quiet origin HEAD 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            & $summary ("Wiki: **not published** - the push to $owner/$repo.wiki.git failed. " +
                'Check that the workflow token has write access to the wiki.')
            return
        }

        Write-Build Green "Wiki: published $($pages.Count) page(s) to $owner/$repo.wiki."

        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY))
        {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8 `
                -Value "Wiki: published $($pages.Count) page(s) to [$owner/$repo.wiki](https://github.com/$owner/$repo/wiki)."
        }
    }
    catch
    {
        & $summary "Wiki: **not published** - $($_.Exception.Message)"
    }
    finally
    {
        if (Test-Path -LiteralPath $clonePath)
        {
            Remove-Item -LiteralPath $clonePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
