# Home

`Dsc.PipelineRunner` applies Desired State Configuration from a CI/CD pipeline. It compiles a
[Datum](https://github.com/gaelcolas/Datum) YAML hierarchy into one configuration file per node,
then walks each file resource by resource, deciding per resource whether to test it, change it,
skip it, or stop the run.

It is not a DSC LCM replacement and it does not hand a compiled document to an engine wholesale.
It keeps the loop, which is what makes per-resource conditions, lifecycle scripts, resource
relationships and early termination possible.

## Where to start

| If you want to… | Read |
|---|---|
| Run the thing for the first time | [Getting started](Getting-Started) |
| Lay out a configuration repository | [Configuration repository layout](Configuration-Repository-Layout) |
| Know every legal key on a resource | [Resource properties](Resource-Properties) |
| Know every run-level setting | [PipelineRunnerSettings](PipelineRunnerSettings) |
| Read a value from a variable, parameter or another resource | [Function language](Function-Language) |
| Understand exactly what happens per resource, in order | [Execution lifecycle](Execution-Lifecycle) |
| Add or override a validation rule | [Pipeline rules](Pipeline-Rules) |
| Choose between DSC v2 and DSC v3 | [Engines](Engines) |
| Apply configuration to a remote machine | [Remote targets and credentials](Remote-Targets-and-Credentials) |
| Work out which account the pipeline must run as | [The identity the runner runs as](Remote-Targets-and-Credentials#the-identity-the-runner-runs-as) |
| Fail the build when a resource fails | [Reporting and exit codes](Reporting-and-Exit-Codes) |
| Work out why something broke | [Troubleshooting](Troubleshooting) |
| Change the runner itself | [Contributing](Contributing) |

## The shape of a run

```
Invoke-DscRunner
  │
  ├─ Source hook ........ fetch the configuration (Local, Git)
  ├─ Connect hook ....... authenticate to the target platform (None, AzureDevOps)
  ├─ Build-DatumConfiguration ... compile the Datum hierarchy to one *.yml per node
  │
  └─ for each compiled file:
       Start-DscRunner
         ├─ PreParse rules ..... validate the whole file before anything runs
         ├─ Expand-NotifyDependsOn + Sort-DependsOn ... decide the order
         └─ for each resource, in order:
              preCondition → preExecutionScript → Test → (Set) →
              postCondition → postExecutionScript → Get
```

Every resource produces exactly one record. Those records become the run report, the structured
return object, and — with `-FailOnError` — the process exit code.

## A minimal example

`Datum.yml` in the configuration repository:

```yaml
PipelineRunnerSettings:
  Engine: DscV2
```

A compiled configuration file:

```yaml
parameters: {}

variables: {
  ServiceName: 'MyApp'
}

resources:

  - name: MyApp service
    type: PSDesiredStateConfiguration/Service
    properties:
      Name: $(variables('ServiceName'))
      State: Running
```

Applying it:

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Set -FailOnError
```

## About this wiki

Conceptual pages are authored in [`WikiSource/`](https://github.com/ZanattaMichael/Dsc.PipelineRunner/tree/main/WikiSource).
The [command reference](Command-Reference) is generated from each command's comment-based help.
Both are compiled by `scripts/Build-WikiContent.ps1` and published on release.

**Do not edit pages in the wiki UI** — the whole wiki is overwritten on every release. Edit the
repository and open a pull request.
