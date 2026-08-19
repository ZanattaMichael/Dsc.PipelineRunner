
task Copy_Pipeline_Rules {

    $sourcePath = "$PSScriptRoot\..\..\Pipeline Rules"
    $destinationPath = "$PSScriptRoot\..\..\Output\Dsc.PipelineRunner\"
    $fullVersionPath = Get-ChildItem -Path $destinationPath

    Copy-Item -Path $sourcePath -Destination $fullVersionPath.FullName -Recurse -Force

}