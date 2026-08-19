Data ModuleConfigurationData {

    # Minor Version changes must not break backwards compatibility.
    # Major Version changes can break backwards compatibility.
    @{
        # Define the minimum and maximum versions for the YAML Configuration.
        YAMLConfigurationMinimumVersion = '0.1'
        YAMLConfigurationMaximumVersion = '0.9' # 
        # Define the minimum and maximum versions for the PSDesiredStateConfiguration Module.
        PSDesiredStateConfigurationMinimumVersion = '2.0'
        PSDesiredStateConfigurationMaximumVersion = '2.9'
        # Define the minimum and maximum versions for the Dsc.PipelineRunner Module.
        DSCResourceMinimumVersion = '1.0'
        DSCResourceMaximumVersion = '1.9'
    }

}
