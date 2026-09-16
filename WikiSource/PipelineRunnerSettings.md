# PipelineRunnerSettings

`PipelineRunnerSettings` is a block in the configuration's `Datum.yml`. It is the
configuration's own say in how the runner behaves — which engine to use, whether lifecycle
scripts are allowed, what to do about a reboot, and where resources run by default.

It is read from the **source** directory, before compilation. A compiled per-node YAML file
does not carry the block, so settings cannot be varied per node today.

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  DSCResourceVersion: 2.0
  Engine: DscV3
  AllowExecutionScripts: true
  Reboot: Ignore
  Target: WinRM
```

Every key is optional except the two version keys that `Test-DatumConfiguration` validates.

## The keys

| Key | Default | Effect |
| --- | --- | --- |
| `ConfigurationVersion` | *(required)* | The configuration schema version. Must parse as a `[Version]`. |
| `PipelineRunnerVersion` | *(required)* | The module version this configuration targets. Must parse as a `[Version]`. |
| `DSCResourceVersion` | — | Back-compat engine hint. Major `2` selects `DscV2`, major `3` selects `DscV3`. |
| `Engine` | `DscV2` | Names the engine action directly. Wins over `DSCResourceVersion`. |
| `AllowExecutionScripts` | `false` | Whether `preExecutionScript` / `postExecutionScript` are permitted at all. |
| `Reboot` | `Fail` | What to do when a local `Set()` reports `RebootRequired`. `Fail` or `Ignore`. |
| `Target` | `Local` | The file-level default execution target for every resource. |

## `ConfigurationVersion` / `PipelineRunnerVersion`

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
```

`Test-DatumConfiguration` throws if the block is absent, if either value fails to cast to
`[Version]`, or if the declared configuration version falls outside the module's supported
range. It also warns when the configuration version trails the installed
`PSDesiredStateConfiguration` by two or more minor versions.

Because this runs during `Build-DatumConfiguration`, a configuration pinned to an older runner
fails at compile time with a version message, not halfway through a `Set` run.

## `Engine` and `DSCResourceVersion`

Engine selection resolves in this order, first match wins:

1. `-EngineAction` (an inline scriptblock passed to the cmdlet).
2. An explicitly passed `-Engine` parameter.
3. `PipelineRunnerSettings.Engine`.
4. `PipelineRunnerSettings.DSCResourceVersion` major version.
5. The `DscV2` default.

Naming the engine directly:

```yaml
PipelineRunnerSettings:
  Engine: DscV3
```

Letting the resource version decide — `2.0` maps to `DscV2`, `3.0` to `DscV3`:

```yaml
PipelineRunnerSettings:
  DSCResourceVersion: 3.0
```

Opting into detection, which picks `DscV3` when the `dsc` executable is on `PATH`:

```yaml
PipelineRunnerSettings:
  Engine: Auto
```

Note the interaction with the cmdlet: passing `-Engine` **explicitly** overrides the
configuration. Leaving it off lets the configuration decide. See [Engines](Engines).

## `AllowExecutionScripts`

`preExecutionScript` and `postExecutionScript` run arbitrary PowerShell in the runner's own
security context. They are off by default. A configuration must opt in:

```yaml
PipelineRunnerSettings:
  AllowExecutionScripts: true
```

With the setting absent or false, the `Test-ExecutionScriptsAllowed` pre-parse rule fails the
run once, before any resource is evaluated, naming every resource that carries a script:

```
[Test-ExecutionScriptsAllowed] preExecutionScript/postExecutionScript are used by 2 resource(s)
([AzureDevOpsDscNative/AzDoProject/Project], [PSDscResources/Script/Bootstrap]) but
PipelineRunnerSettings.AllowExecutionScripts is not enabled. Add 'AllowExecutionScripts: true'
to the PipelineRunnerSettings block in Datum.yml to allow lifecycle scripts, or remove
preExecutionScript/postExecutionScript from these resources.
```

The gate is on the *presence* of the key, not on whether the script would have run — a
configuration cannot carry a dormant script under a false setting. `resourceCredential` is
declarative rather than a script, so it is **not** gated by this setting.

## `Reboot`

A resource's `Set()` can report that a reboot is required. The default policy refuses to
continue, because a local runner cannot safely restart the machine it is running on and then
resume the file:

```yaml
PipelineRunnerSettings:
  Reboot: Fail      # default
```

The resource is marked `FAIL` with a message naming both escape hatches, and the rest of the
file is skipped. To continue without restarting:

```yaml
PipelineRunnerSettings:
  Reboot: Ignore
```

A resource aimed at a **remote** target is different: the runner is not what needs to come
back up, so it restarts the target and waits (`Restart-Computer -Wait`) regardless of this
setting. See [Remote Targets and Credentials](Remote-Targets-and-Credentials).

## `Target`

The file-level default execution target. `Local` (the default) never invokes the Target hook
at all, so a configuration that says nothing about targets runs exactly as it always has.

Making WinRM the default for every resource in the configuration:

```yaml
PipelineRunnerSettings:
  Target: WinRM
```

Each resource then supplies the computer name (and, if needed, a credential) in its own
`target` block, and any resource may override the action outright:

```yaml
resources:

  - name: Web Feature
    type: PSDscResources/WindowsFeature
    target:
      computerName: web01.contoso.com
      credential:
        action: SecretManagement
        name: DeployAccount
    properties:
      Name: Web-Server
      Ensure: Present

  - name: Local Marker
    type: PSDscResources/File
    target:
      action: Local           # overrides the WinRM default for this one resource
    properties:
      DestinationPath: C:\deploy\marker.txt
      Contents: done
      Ensure: Present
```

## Worked examples

### A DSC v2, local-only configuration with no scripts

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  DSCResourceVersion: 2.0
```

Everything else takes its default: `DscV2`, no execution scripts, `Reboot: Fail`,
`Target: Local`.

### A DSC v3 configuration that provisions remote servers

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  Engine: DscV3
  Target: WinRM
  Reboot: Ignore
```

`Reboot: Ignore` is safe here in the sense that the reboot decision moves to the target: a
remote resource restarts and waits anyway, and a local one continues without restarting.

### A configuration that uses teardown scripting

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.2
  PipelineRunnerVersion: 1.0.0
  DSCResourceVersion: 2.0
  AllowExecutionScripts: true
```

Required by any configuration whose resources carry `postExecutionScript:
if ($Ensure -eq 'Absent') { Stop-TaskProcessing }` or similar. Consider whether a
`postCondition` using `stopProcessing()` does the job instead — it needs no opt-in, because it
is validated as an expression rather than executed as free-form script. See
[Function Language](Function-Language).

## Reading the settings yourself

```powershell
$settings = & (Get-Module Dsc.PipelineRunner) { Get-PipelineRunnerSetting -ConfigurationDirectory 'C:\config' }
$settings['Engine']
```

`Get-PipelineRunnerSetting` is module-private. It returns `$null` — rather than throwing —
when the directory has no definition file or the file has no `PipelineRunnerSettings` block,
so every caller falls back to defaults.
