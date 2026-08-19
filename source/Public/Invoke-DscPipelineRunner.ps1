<#
.SYNOPSIS
Invokes the DSC Pipeline Runner process using specified configurations and authentication methods.

.DESCRIPTION
The Invoke-DscPipelineRunner function is designed to manage DSC configurations in any CI/CD pipeline environment. It supports advanced function features similar to cmdlets and allows for different authentication methods, including Managed Identity and Personal Access Token (PAT). The function handles the cloning of configuration repositories, compilation of configurations, and invocation of resources based on the provided parameters.

.PARAMETER AzureDevopsOrganizationName
Specifies the name of the Azure DevOps organization. This parameter is mandatory.

.PARAMETER exportConfigDir
Specifies the directory where configuration files are exported by Datum. This parameter is mandatory and must be a valid directory path.

.PARAMETER ConfigurationSourcePath
Specifies the URL or directory path for the configuration source. This parameter is mandatory.

.PARAMETER JITToken
Specifies the Just-In-Time (JIT) access token. This parameter is mandatory.

.PARAMETER Mode
Specifies the mode of operation. Valid values are 'Test' and 'Set'. The default value is 'Test'.

.PARAMETER AuthenticationType
Specifies the authentication type to use. Valid values are 'ManagedIdentity' and 'PAT'. The default value is 'ManagedIdentity'.

.PARAMETER PATToken
Specifies the Personal Access Token (PAT). This parameter is mandatory when AuthenticationType is set to 'PAT' and must be a valid 52-character alphanumeric string.

.PARAMETER ReportPath
Specifies the path to the report file. This parameter is optional and must be a valid file path.

.EXAMPLE
Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" -exportConfigDir "C:\Configs" -ConfigurationSourcePath "https://repo.url" -JITToken "token" -Mode "Set" -AuthenticationType "PAT" -PATToken "pat_token"

This example invokes the DSC Pipeline Runner process using a PAT for authentication.

.NOTES
Ensure that the environment variable AZDODSC_CACHE_DIRECTORY is set before running this function. The function will throw an error if this environment variable is not set.

#>


function Invoke-DscPipelineRunner {
    # Utilizes the CmdletBinding attribute to enable advanced function features similar to cmdlets.
    [CmdletBinding(defaultParameterSetName='Default')]
    param(
        # Declares a mandatory parameter that specifies the name of the Azure DevOps organization.
        [Parameter(Mandatory, ParameterSetName='Default')]
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [String]$AzureDevopsOrganizationName,

        # Declares a mandatory parameter that specifies the directory where configuration files are exported by datum to:
        [Parameter(Mandatory, ParameterSetName='Default')]
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [String]$exportConfigDir,

        # Declares a mandatory parameter that specifies the URL for the configuration.
        # This can be a directory path of a URL
        [Parameter(Mandatory, ParameterSetName='Default')]
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [String]$ConfigurationSourcePath,

        # Declares a mandatory parameter named JITToken which must be provided when the function is called.
        # This parameter expects a string value, typically representing a "Just-In-Time" access token.
        [Parameter(Mandatory, ParameterSetName='Default')]
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [String]$JITToken,

        # Declares an optional parameter with a ValidateSet attribute to restrict the value to either 'Test' or 'Set'.
        # The default value for this parameter is 'Set'.
        [Parameter(Mandatory, ParameterSetName='Default')]
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [ValidateSet('Test', 'Set')]
        [String]$Mode='Test',

        # Declare the AuthenticationType parameter with a ValidateSet attribute to restrict the value to 'ManagedIdentity' or 'PAT'.
        # The default value for this parameter is 'ManagedIdentity'.
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='PAT')]
        [ValidateSet('ManagedIdentity', 'PAT')]
        [String]$AuthenticationType='ManagedIdentity',

        # Declare the PATToken parameter with a ValidateScript attribute to ensure the provided value is a valid Personal Access Token.
        # This parameter is mandatory when the AuthenticationType parameter is set to 'PAT'.
        [Parameter(Mandatory, ParameterSetName='PAT')]
        [ValidateScript({$_ -match '^[a-zA-Z0-9]{52}$'})]
        [String]$PATToken,

        # The following commented-out parameters could be used to specify a report path.
        # It includes a validation script to ensure the provided path points to a file (leaf) and not a directory.
        [Parameter()]
        [ValidateScript({Test-Path -Path $_ -PathType Container})]
        [String]$ReportPath

    )

    # Set the Error Action Preference
    $ErrorActionPreference = "Stop"

    #
    # Get the Execution Path
    #$ExecutionPath = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

    #
    # Test to make sure that the Enviroment Variable is Set

    if (-not $ENV:AZDODSC_CACHE_DIRECTORY) {
        throw "The Environment Variable AZDODSC_CACHE_DIRECTORY is not set. Please set the environment variable before running this script."
    }

    #
    # Clone the Datum Configuration from the Configuration URL

    # Test ConfigurationSourcePath if it is a URL. If URL attempt to clone.
    if ($ConfigurationSourcePath -match '^(http|https):\/\/') {
        # Cone from URL
        $DatumConfigurationPath = Clone-Repository -DatumURLConfig $ConfigurationSourcePath
    }
    # Test if ConfigurationSourcePath is a directory path that exists.
    elseif (Test-Path -Path $ConfigurationSourcePath -PathType Container) {
        $DatumConfigurationPath = $ConfigurationSourcePath
    } 
    # Else. Throw an error for bad data.
    else {
        throw "[Invoke-DscPipelineRunner] Invalid ConfigurationSourcePath: $ConfigurationSourcePath"
    }

    #
    # Compile the Datum Configuration
    Build-DatumConfiguration -OutputPath $exportConfigDir -ConfigurationPath $DatumConfigurationPath

    #
    # Determine the Authentication Type and create the Authentication Provider

    if ($AuthenticationType -eq 'PAT') {
        New-AzDoAuthenticationProvider -OrganizationName $AzureDevopsOrganizationName -PersonalAccessToken $PATToken
    } elseif ($AuthenticationType -eq 'ManagedIdentity') {
        New-AzDoAuthenticationProvider -OrganizationName $AzureDevopsOrganizationName -useManagedIdentity
    } #else {
    #    throw "The Authentication Type $AuthenticationType is not supported. Please use either 'PAT' or 'ManagedIdentity'."
    #}

    #
    # Invoke the Resources

    # Create a hashtable to store the parameters
    $params = @{
        Mode = $Mode
    }

    # If the ReportPath is provided, add it to the parameters
    if ($ReportPath) {
        $params.ReportPath = $ReportPath
    }

    Get-ChildItem -LiteralPath $exportConfigDir -File -Filter "*.yml" | ForEach-Object { 
        Start-DscRunner -FilePath $_.Fullname @params
    }

    <#
    return

    $postExecutionConfiguration = [System.Collections.Generic.List[HashTable]]::new()
    # Once Completed, Iterate through the Output Directory and run the post execution tasks.
    Get-ChildItem -LiteralPath $DatumConfigurationPath -File -Filter "*.yml" | ForEach-Object {

        # Load the Configuration Files
        $configuration = Get-Content $_.FullName | ConvertFrom-Yaml
        
        # Create a Hash Table to store the Post Execution Tasks.
        # Include the Post Execution Tasks and Variables.
        # The Variables are used to pass the variables to the Post Execution Tasks.

        $hashTable = @{
            postExecution = $configuration.resources
            variables = $configuration.variables
        }

        # Add the Post Execution Tasks to the Configuration Files
        if ($configuration.resources) {
            $postExecutionConfiguration.Add($hashTable)
        }

        # ^\{(.+)\}$

    }

    <#
    postExecutionTask:

    - name: Org Group Members
        type: AzureDevOpsDsc/AzDoProject
        properties:
        projectName: CON_$ProjectName
        projectDescription: $ProjectDescription
        visibility: private
        SourceControlType: Git
        ProcessTemplate: { scriptblock }     


    #

    #
    # Flatten the Post Execution Tasks By Caculated Property
    # Group the Post Execution Tasks by the Name and Type

    $Configuration = $postExecutionConfiguration | ForEach-Object {
        $_.postExecution | ForEach-Object {
            $_
        }
    } | Group-Object -Property {
        ("{0}/{1}" -f $_.type, $_.Name)
    }

    # Once the Post Execution Tasks are collected, iterate through the Post Execution Tasks and group them according to the Task Type.
    # Iterate thorugh the Grouped Tasks and add the associated variables to the Post Execution Task.

    $groupedPostExecutionTasks = [System.Collections.Generic.List[HashTable]]::new()

    $Configuration | ForEach-Object {

        $currentObject = $_.Group[0]
        $name = $_.Name
        $obj = @{
            name = $name
            postExecution = $currentObject
            variables = [System.Collections.Generic.List[hashtable]]::new()
        }

        # Test if name exists within the postExecutionConfiguration
        $postExecutionConfiguration | ForEach-Object {
            $currentObj = $_
            $matched = $currentObj.postExecution | Where-Object { "$($_.type)/$($_.name)" -eq $name } 

            if ($matched) {
                $obj.variables.Add($currentObj.variables)
            }

        }

        $groupedPostExecutionTasks.Add($obj)

    }

    #>

}