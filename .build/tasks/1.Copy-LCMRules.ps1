<#
    .SYNOPSIS
        Stages the 'LCM Rules' directory into the built module.

    .DESCRIPTION
        At runtime the LCM discovers and dot-sources its PreParse, Format and Custom rules
        from an 'LCM Rules' directory beneath the module base. ModuleBuilder does not copy
        that directory, so it is staged here after the module has been built.

        This task must run after Build_Module_ModuleBuilder and before the module is packaged
        or published. A built module missing this directory fails at runtime rather than at
        build time - both Invoke-PreParseRules and Invoke-FormatTasks throw when their rule
        directory is absent - so the copy is verified explicitly below.
#>
task Copy_LCM_Rules {

    $repositoryRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    $sourcePath = Join-Path -Path $repositoryRoot -ChildPath 'LCM Rules'

    if (-not (Test-Path -LiteralPath $sourcePath))
    {
        throw "[Copy_LCM_Rules] Source directory not found: $sourcePath"
    }

    # Prefer the output path Sampler resolved; fall back to the conventional location.
    $moduleOutputRoot = if ($BuildModuleOutput)
    {
        Join-Path -Path $BuildModuleOutput -ChildPath 'azdo-dsc-lcm'
    }
    else
    {
        Join-Path -Path $repositoryRoot -ChildPath 'output' -AdditionalChildPath 'azdo-dsc-lcm'
    }

    if (-not (Test-Path -LiteralPath $moduleOutputRoot))
    {
        throw "[Copy_LCM_Rules] Built module directory not found: $moduleOutputRoot. Run the Build_Module_ModuleBuilder task first."
    }

    # VersionedOutputDirectory is enabled in build.yaml, so the module sits in a version
    # subdirectory. Select it explicitly - enumerating everything returns an array when more
    # than one build is present, which silently sends the copy to the wrong destination.
    $versionDirectory = Get-ChildItem -LiteralPath $moduleOutputRoot -Directory |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $versionDirectory)
    {
        throw "[Copy_LCM_Rules] No versioned module directory found beneath: $moduleOutputRoot"
    }

    Write-Build DarkGray "  Source:      $sourcePath"
    Write-Build DarkGray "  Destination: $($versionDirectory.FullName)"

    Copy-Item -Path $sourcePath -Destination $versionDirectory.FullName -Recurse -Force

    #
    # Verify the copy. Shipping a module without its rules is a runtime failure for every
    # consumer, so it must fail the build here instead.

    $destinationPath = Join-Path -Path $versionDirectory.FullName -ChildPath 'LCM Rules'

    if (-not (Test-Path -LiteralPath $destinationPath))
    {
        throw "[Copy_LCM_Rules] Copy completed but '$destinationPath' does not exist."
    }

    $expectedCount = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File).Count
    $actualCount = @(Get-ChildItem -LiteralPath $destinationPath -Recurse -File).Count

    if ($actualCount -ne $expectedCount)
    {
        throw "[Copy_LCM_Rules] Expected $expectedCount file(s) beneath '$destinationPath' but found $actualCount."
    }

    Write-Build Green "  Staged $actualCount LCM rule file(s) into the built module."
}
