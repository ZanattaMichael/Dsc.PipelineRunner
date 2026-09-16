# Getting Started

This page takes you from an empty folder to a run that reports its results, using nothing but
the module and a configuration directory on disk.

## Install the module

```powershell
Install-Module Dsc.PipelineRunner -Scope CurrentUser
Import-Module Dsc.PipelineRunner
```

The module exports seven commands. Every one of them has its own generated page under
[Command Reference](Command-Reference):

| Command | What it is for |
| --- | --- |
| `Invoke-DscRunner` | The provider-agnostic entry point. Start here. |
| `Invoke-DscPipelineRunner` | The Azure DevOps-flavoured entry point (PAT/JIT token handling). |
| `Build-DatumConfiguration` | Compiles a Datum configuration directory into per-node YAML. |
| `Test-DatumConfiguration` | Validates a configuration's `PipelineRunnerSettings` version block. |
| `Resolve-DscDatumProject` | Resolves the Datum project root from a path. |
| `ConvertTo-DscV3ConfigurationDocument` | Converts pipeline resources to a DSC v3 configuration document. |
| `Stop-TaskProcessing` | Called from a `postExecutionScript` to skip the rest of the file. |

## The smallest configuration that runs

A configuration is a [Datum](https://github.com/gaelcolas/Datum) repository. The minimum is a
`Datum.yml` that declares resolution precedence and a `PipelineRunnerSettings` block, plus at
least one YAML file containing a `resources:` list.

`C:\config\Datum.yml`:

```yaml
ResolutionPrecedence:
  - Nodes\$($Node.NodeName)
  - Roles\$($Node.Role)
  - Baseline

default_lookup_options: MostSpecific

PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  Engine: DscV2
```

`C:\config\Baseline.yml`:

```yaml
parameters: {}

variables:
  LogRoot: C:\Logs

resources:

  - name: Log Directory
    type: PSDscResources/File
    properties:
      DestinationPath: $(variables('LogRoot'))
      Type: Directory
      Ensure: Present
```

## Run it in Test mode

`Test` is the default mode. Nothing is changed; every resource is evaluated and reported.

```powershell
$result = Invoke-DscRunner -ConfigurationSourcePath 'C:\config'
$result.Status          # Completed / PartialSuccess / Failed / Aborted
$result.PassCount
$result.FailCount
```

## Run it in Set mode

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -Mode Set
```

## Write reports and fail the build

`-ReportPath` writes a CSV and a `.report.json` per configuration file, plus an aggregate
`report.json`. `-FailOnError` sets process exit code `1` when the overall status is `Failed`
or `Aborted`, so a CI step fails loudly.

```powershell
New-Item -ItemType Directory -Path .\reports -Force | Out-Null

Invoke-DscRunner -ConfigurationSourcePath 'C:\config' `
                 -Mode Set `
                 -ReportPath .\reports `
                 -FailOnError
```

See [Reporting and Exit Codes](Reporting-and-Exit-Codes) for the exact shape of every report.

## Run against a Git configuration

The `Git` source action clones the repository first, and `-ConfigurationRevision` pins it.
A full 40-character SHA is verified against the clone's `HEAD`.

```powershell
Invoke-DscRunner -Source Git `
                 -SourceContext @{ Url = 'https://github.com/contoso/config.git'; Token = $pat } `
                 -ConfigurationRevision '3f1c9a0e5b7d2148ab6c0f39e7d5412ca8b09e6f' `
                 -Mode Test
```

## Run against Azure DevOps

```powershell
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repoUrl; Token = $pat } `
                 -Connect AzureDevOps `
                 -ConnectContext @{
                     OrganizationName   = 'Contoso'
                     AuthenticationType = 'PAT'
                     PATToken           = $pat
                 } `
                 -Mode Set
```

`Invoke-DscPipelineRunner` is the same run with the Azure DevOps arguments hoisted into
first-class parameters:

```powershell
Invoke-DscPipelineRunner -AzureDevopsOrganizationName 'Contoso' `
                         -ConfigurationSourcePath $repoUrl `
                         -PATToken $pat `
                         -Mode Set `
                         -ReportPath .\reports `
                         -FailOnError
```

## Debug a compile failure

The runner deletes any temporary directory it created. `-KeepTemporaryDirectory` leaves the
clone and the compiled cache on disk so you can look at the per-node YAML Datum produced.

```powershell
Invoke-DscRunner -ConfigurationSourcePath 'C:\config' -KeepTemporaryDirectory -Verbose
```

Directories you supply yourself (`-CacheDirectory`) are never deleted, switch or no switch.

## Where to next

- [Configuration Repository Layout](Configuration-Repository-Layout) — how a Datum repository is shaped.
- [Resource Properties](Resource-Properties) — every key you can put on a resource.
- [Function Language](Function-Language) — `variables()`, `parameters()`, `reference()`, `using()` and friends.
- [Execution Lifecycle](Execution-Lifecycle) — exactly what happens to one resource, in order.
