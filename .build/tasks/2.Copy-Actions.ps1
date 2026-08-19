
task Copy_Actions {

    $sourcePath = "$PSScriptRoot\..\..\Actions"
    $destinationPath = "$PSScriptRoot\..\..\Output\Dsc.PipelineRunner\"
    $fullVersionPath = Get-ChildItem -Path $destinationPath

    Copy-Item -Path $sourcePath -Destination $fullVersionPath.FullName -Recurse -Force

}
