@{
    PSDependOptions             = @{
        AddToPath  = $true
        Target     = 'output\RequiredModules'
        Parameters = @{}
    }

    InvokeBuild                 = 'latest'
    PSScriptAnalyzer            = 'latest'
    Pester                      = 'latest'
    ModuleBuilder               = 'latest'
    ChangelogManagement         = 'latest'
    Sampler                     = 'latest'
    'Sampler.GitHubTasks'       = 'latest'
    MarkdownLinkCheck           = 'latest'


}
