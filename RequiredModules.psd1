@{
    PSDependOptions             = @{
        AddToPath  = $true
        Target     = 'output\RequiredModules'
        Parameters = @{}
    }

    # Exact versions, kept in step with scripts/module-versions.json (a test checks they agree). Move
    # them with the 'Update module versions' workflow, not by editing here.
    InvokeBuild                 = '5.14.23'
    PSScriptAnalyzer            = '1.25.0'
    Pester                      = '5.9.1'
    ModuleBuilder               = '3.2.18'
    ChangelogManagement         = '3.1.0'
    Sampler                     = '0.120.1'
    'Sampler.GitHubTasks'       = '0.5.0'
    MarkdownLinkCheck           = '0.2.0'


}
