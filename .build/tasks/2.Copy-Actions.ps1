
task Copy_Actions {

    # 'output' is lower case because that is what the build creates (Build.ps1 -OutputDirectory),
    # and the path is composed with Join-Path so this also runs on a case-sensitive file system
    # (a Linux build agent).
    $repositoryRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..'
    $sourcePath = Join-Path -Path $repositoryRoot -ChildPath 'Actions'
    $destinationPath = Join-Path -Path $repositoryRoot -ChildPath 'output' -AdditionalChildPath 'Dsc.PipelineRunner'
    $fullVersionPath = Get-ChildItem -Path $destinationPath

    Copy-Item -Path $sourcePath -Destination $fullVersionPath.FullName -Recurse -Force

}
