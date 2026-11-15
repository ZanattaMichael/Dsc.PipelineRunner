function Invoke-PreParseRules {
    param(
        [Parameter(Mandatory=$true)]
        [Object[]]$Tasks,

        # Resolved PipelineRunnerSettings (#57 §2), forwarded to every PreParse rule so rules
        # like Test-ExecutionScriptsAllowed.ps1 can gate on configuration-level settings.
        # Optional and defaulted so existing callers that don't pass it keep working unchanged.
        [hashtable]$Settings = @{}
    )

    # Get the path to the PreParseRules directory
    $currentPath = (Get-Module 'Dsc.PipelineRunner').ModuleBase
    $PreParseDirectoryPath = "{0}\Pipeline Rules\PreParse" -f $currentPath

    #
    # Iterate through each of the PreParse Rules

    if (-not (Test-Path -Path $PreParseDirectoryPath)) {
        Throw "[Invoke-PreParseRules] No Tasks to Process in Directory: $PreParseDirectoryPath"
    }

    Write-Verbose "[Invoke-PreParseRules] Processing PreParse Rules in Directory: $PreParseDirectoryPath"

    $PreParseFiles = Get-ChildItem -Path $PreParseDirectoryPath -Filter "*.ps1"

    # Iterate through each of the PreParse Rules
    foreach ($File in $PreParseFiles) {
        Write-Verbose "[Invoke-PreParseRules] Processing PreParse Rule: $($File.FullName)"
        # Execute the PreParse Rule
        # -Settings is forwarded only when the rule script actually declares that parameter
        # (#57 §2), so a third-party/custom PreParse rule written against the pre-#57 contract
        # (-PipelineResources only) keeps working unchanged instead of failing to bind an
        # unrecognized named parameter.
        $ruleParams = @{ PipelineResources = $Tasks }
        $ruleCommand = Get-Command -Name $File.FullName -ErrorAction SilentlyContinue
        if ($ruleCommand -and $ruleCommand.Parameters.ContainsKey('Settings')) {
            $ruleParams.Settings = $Settings
        }
        . $File.FullName @ruleParams
    }
}