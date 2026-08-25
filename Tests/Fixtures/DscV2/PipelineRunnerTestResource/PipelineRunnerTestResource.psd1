@{
    # Test-only class-based DSC v2 resource module. Consumed by the self-hosted DSC v2
    # integration tests to give Invoke-DscResource a real, dependency-free resource to drive.
    RootModule           = 'PipelineRunnerTestResource.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '1bbc503c-ea9e-46e6-a798-722598328bd5'
    Author               = 'Dsc.PipelineRunner'
    CompanyName          = 'Dsc.PipelineRunner'
    Copyright            = '(c) Dsc.PipelineRunner. All rights reserved.'
    Description          = 'Test-only class-based DSC v2 resource used by the self-hosted DSC v2 integration tests.'
    PowerShellVersion    = '7.2'

    # The class-based resource the fixture exports. Required so Invoke-DscResource /
    # Get-DscResource can discover it once the module directory is on $env:PSModulePath.
    DscResourcesToExport = @('PipelineRunnerFile')
}
