# Resource Properties

Every entry under `resources:` is one resource. This page documents **every** key the runner
reads from a resource, in the order the runner reads them, with worked examples for each.

## The complete key set

| Key | Required | Type | Summary |
| --- | --- | --- | --- |
| [`type`](#type) | yes | string | `Module/ResourceName` — which DSC resource to invoke. |
| [`name`](#name) | yes | string | The instance name. Unique within the file. |
| [`properties`](#properties) | yes | map | The DSC resource's own properties. Expanded before use. |
| [`dependsOn`](#dependson) | no | string or list | Ordering only. `Module/ResourceName/Instance`. |
| [`notify`](#notify) | no | string or list | Ordering **and** a gated data link plus forced refresh. |
| [`preCondition`](#precondition) | no | string | A side-effect-free predicate. False ⇒ `SKIP`. |
| [`condition`](#condition) | no | string | Deprecated alias for `preCondition`. |
| [`postCondition`](#postcondition) | no | string | Evaluated after Test/Set. False ⇒ `FAIL`. |
| [`preExecutionScript`](#preexecutionscript) | no | string | PowerShell run before Test/Set. Gated. |
| [`postExecutionScript`](#postexecutionscript) | no | string | PowerShell run after Test/Set. Gated. |
| [`target`](#target) | no | map | Where this resource executes. |
| [`resourceCredential`](#resourcecredential) | no | map | Resolves a credential into a property. |

A resource carrying every one of them:

```yaml
resources:

  - name: Web Server
    type: PSDscResources/WindowsFeature
    dependsOn:
      - PSDscResources/File/Deploy Directory
    notify:
      - PSDscResources/Service/W3SVC
    preCondition: equals (variables 'Role') 'Web'
    postCondition: result().InDesiredState
    preExecutionScript: Write-Verbose "About to evaluate the web feature." -Verbose
    postExecutionScript: Write-Verbose "Web feature evaluated." -Verbose
    target:
      action: WinRM
      computerName: web01.contoso.com
      credential:
        action: SecretManagement
        name: DeployAccount
    resourceCredential:
      action: Environment
      propertyName: Credential
      UserNameVariable: DEPLOY_USER
      PasswordVariable: DEPLOY_PASSWORD
    properties:
      Name: Web-Server
      Ensure: Present
```

---

## `type`

`Module/ResourceName`. The runner splits on the first `/`: the left half is the module, the
right half is the resource name handed to the engine.

```yaml
  - name: Log Directory
    type: PSDscResources/File
```

Together with `name`, this forms the resource's **identity** — `Module/ResourceName/Instance`
— which is what `dependsOn`, `notify` and `using()` address, and what the report keys on.
The identity of the resource above is `PSDscResources/File/Log Directory`.

`type` is also validated at pre-parse time: `Test-ResourcesForIncorrectProperties` calls
`Get-DscResource -Name <ResourceName> -Module <Module>` and fails the run if the resource is
not installed.

## `name`

The instance name. It must be unique within the compiled file, because the report is keyed on
`(ConfigurationFile, ResourceType, InstanceName)` and because `reference()` looks up by bare
name.

Names may contain spaces, and every reference to them must match exactly:

```yaml
  - name: Default Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
```

Remember that the Datum `resources` merge is keyed on `name`: two layers declaring the same
`name` produce one merged resource, not two. That is how a node layer overrides one property
of a policy-declared resource — see
[Configuration Repository Layout](Configuration-Repository-Layout).

## `properties`

The DSC resource's own properties. This is the only part of the resource the engine sees.

Every value is run through parameter expansion and then `ExpandString`, so `$(...)`
sub-expressions and the [function language](Function-Language) work anywhere in the map,
including nested maps and lists:

```yaml
  - name: App Config
    type: PSDscResources/File
    properties:
      DestinationPath: $(variables('AppRoot'))\appsettings.json
      Contents: $(parameters('ConfigJson'))
      Ensure: Present
```

Conditional values are ordinary PowerShell inside `$( )`:

```yaml
    properties:
      Ensure: $( if ([string]::IsNullOrEmpty((variables 'Project_Ensure'))) { 'Present' } else { variables 'Project_Ensure' } )
```

Nested structures expand too:

```yaml
    properties:
      ProjectName: $(variables('ProjectName'))
      Permissions:
        - Identity: $(variables('AdminGroup'))
          Access: Allow
        - Identity: $(variables('ReaderGroup'))
          Access: Deny
```

If expansion throws — an undefined `parameters()` name, a `using()` that is not permitted, a
syntax error in a `$( )` block — the resource is recorded `FAIL` with the exception message and
the run moves to the next resource.

`Test-ResourcesForIncorrectProperties` checks each key against the installed resource's real
property list: an unknown property, a mandatory property left null, or a value outside a
`ValidateSet` all fail the run before anything is evaluated. Values containing `$` are skipped
by that check, since they are not known until execution.

## `dependsOn`

Ordering, and nothing else. A string or a list of strings, each a full
`Module/ResourceName/Instance` identity:

```yaml
  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      projectName: Magenta

  - name: Project Services
    type: AzureDevOpsDscNative/AzDoProjectServices
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      projectName: Magenta
```

Multiple dependencies:

```yaml
    dependsOn:
      - PSDscResources/File/Deploy Directory
      - PSDscResources/WindowsFeature/Web Server
```

`Sort-DependsOn` topologically sorts the file on these edges. A cycle, a self-reference, or a
dependency on a resource that is not in the **same compiled file** fails the run before any
resource runs. `dependsOn` does not cross files.

`dependsOn` says nothing about *whether* the dependency succeeded — it only fixes the order. A
resource whose dependency failed still runs. Use `preCondition` if you need to gate on state.

## `notify`

Ordering **plus** two things `dependsOn` does not do: a forced refresh, and a data link.

```yaml
  - name: App Config
    type: PSDscResources/File
    notify:
      - PSDscResources/Service/AppService
    properties:
      DestinationPath: C:\app\appsettings.json
      Contents: $(parameters('ConfigJson'))
      Ensure: Present

  - name: AppService
    type: PSDscResources/Service
    properties:
      Name: AppService
      State: Running
```

1. **Ordering.** `Expand-NotifyDependsOn` folds each `notify` entry into an implicit
   `dependsOn` on the target, so the same sort and the same cycle detection govern it.

2. **Forced re-run — `Set` mode only.** If `App Config`'s own `Test()` reported drift and its
   `Set()` then succeeded, `AppService` runs `Set()` this pass even if its own `Test()` says it
   is already in the desired state. A forced re-run that was itself a no-op does *not*
   propagate further; only a resource whose own `Test()` reported drift propagates onward. In
   `Test` mode there is no `Set()` to force, so `notify` contributes ordering only.

3. **Data link.** `notify` is the gate for `using()` — see below and
   [Function Language](Function-Language).

Notifying several resources:

```yaml
    notify:
      - PSDscResources/Service/AppService
      - PSDscResources/Service/NotificationWorker
```

Reading across the link:

```yaml
  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    notify:
      - AzureDevOpsDscNative/AzDoGitRepository/Default Repository
    properties:
      projectName: Magenta

  - name: Default Repository
    type: AzureDevOpsDscNative/AzDoGitRepository
    properties:
      ProjectId: $((using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
```

`notify` and `using()` are **intra-file**, like `dependsOn`. A notify target that is not in the
same compiled file fails the run at expansion time.

## `preCondition`

A side-effect-free predicate evaluated **before** the resource. `$false` records the resource
`SKIP` and moves on; the resource is never evaluated.

```yaml
  - name: Web Server
    type: PSDscResources/WindowsFeature
    preCondition: equals (variables 'Role') 'Web'
    properties:
      Name: Web-Server
      Ensure: Present
```

Comparing a parameter:

```yaml
    preCondition: (parameters 'Environment') -eq 'Production'
```

Negating:

```yaml
    preCondition: not (equals (variables 'Project_Ensure') 'Absent')
```

Combining with ordinary operators:

```yaml
    preCondition: (equals (variables 'Role') 'Web') -and ((parameters 'Environment') -ne 'Sandbox')
```

`Assert-SafeConditionExpression` parses the expression first and rejects it if it contains a
command invocation outside the allow-list (`parameters`, `variables`, `reference`, `equals`,
`not`), a variable assignment, or a method call. The check walks the whole tree, so a
disallowed call nested inside an allowed one is rejected too. A rejected condition never runs —
the resource is recorded `FAIL`.

> **Argument style.** These are PowerShell commands, so arguments are space-separated:
> `equals (variables 'X') 'Y'`. Writing `equals(X, 'Y')` binds the whole parenthesised list to
> the first parameter and fails.

## `condition`

The original spelling of `preCondition`, kept for back-compatibility. It behaves identically
and goes through the same validation. `preCondition` wins when both are present.

```yaml
  - name: Legacy Gate
    type: PSDscResources/File
    condition: equals (variables 'Role') 'Web'
    properties:
      DestinationPath: C:\web\marker.txt
      Ensure: Present
```

Prefer `preCondition` in new configurations — the pairing with `postCondition` is what makes
the name meaningful.

## `postCondition`

Evaluated **after** Test/Set, with two extra accessors available: `result()` and
`stopProcessing()`. A `$false` result marks the resource `FAIL` regardless of what the engine
itself reported.

Asserting convergence:

```yaml
  - name: Project Services
    type: AzureDevOpsDscNative/AzDoProjectServices
    postCondition: result().InDesiredState
    properties:
      projectName: Magenta
```

Accepting non-convergence under a condition:

```yaml
    postCondition: result().InDesiredState -or (not (equals (variables 'Project_Ensure') 'Present'))
```

Halting the rest of the file when this resource did not converge:

```yaml
  - name: Prerequisite Check
    type: PSDscResources/Script
    postCondition: result().InDesiredState -or stopProcessing()
    properties:
      GetScript: '@{ Result = "" }'
      TestScript: Test-Path C:\prereq.marker
      SetScript: 'throw "Prerequisite missing."'
```

`stopProcessing()` returns `$true`, so the resource above is **not** marked `FAIL` — it stops
the file cleanly. Every remaining resource is recorded `SKIP` and the run status for the file
becomes `StoppedByRequest`. Reverse the clauses if you want both a `FAIL` and a stop.

Reading the engine's message:

```yaml
    postCondition: result().Message -notmatch 'deprecated'
```

`postCondition` is the only place `result()` and `stopProcessing()` are permitted. Using either
in a `preCondition` is rejected as a disallowed command invocation.

## `preExecutionScript`

Free-form PowerShell run immediately **before** Test/Set, after properties have been expanded
and the target session resolved. Requires `PipelineRunnerSettings.AllowExecutionScripts: true`
— see [PipelineRunnerSettings](PipelineRunnerSettings).

```yaml
  - name: Deployment Package
    type: PSDscResources/Archive
    preExecutionScript: New-Item -ItemType Directory -Path C:\staging -Force | Out-Null
    properties:
      Path: C:\packages\app.zip
      Destination: C:\staging
```

Multi-line, using YAML's block scalar:

```yaml
    preExecutionScript: |
      $stagingPath = 'C:\staging'
      if (-not (Test-Path $stagingPath)) {
          New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
      }
      Write-Verbose "Staging prepared at $stagingPath" -Verbose
```

Unlike `properties` and the conditions, an execution script is **not** parsed through
`ExpandString` or the safety allow-list — it is `[scriptblock]::Create` plus `&`. It therefore
reads script-scope variables directly (`$ProjectName`, not `variables('ProjectName')`), and
because it is invoked rather than dot-sourced it cannot rewrite the runner's own locals.

A script that throws records the resource `FAIL` and moves to the next resource.

## `postExecutionScript`

The same, run **after** Test/Set and after `postCondition`. Same gate, same execution model.

```yaml
  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    properties:
      projectName: $(variables('ProjectName'))
      Ensure: $(variables('Project_Ensure'))
```

This is the canonical teardown pattern: when the project is being removed, everything beneath
it is moot, so the rest of the file is skipped. The `if` guard matters — the resource is also
evaluated in `Test` mode, where a project that does not yet exist is ordinary drift rather than
a reason to stop.

Logging:

```yaml
    postExecutionScript: |
      Add-Content -Path C:\Logs\deploy.log -Value "$(Get-Date -Format o) evaluated web feature."
```

`Stop-TaskProcessing` is only callable from here — it is not on the condition allow-list.
`stopProcessing()` in a `postCondition` is the equivalent that needs no opt-in.

## `target`

Where this resource executes. Overrides `PipelineRunnerSettings.Target` for this resource only.

```yaml
  - name: Web Feature
    type: PSDscResources/WindowsFeature
    target:
      action: WinRM
      computerName: web01.contoso.com
    properties:
      Name: Web-Server
      Ensure: Present
```

| Key | Meaning |
| --- | --- |
| `action` | `Local`, `WinRM`, `SSH`, or the name of any file under `Actions/Target/`. Defaults to the file-level setting, itself defaulting to `Local`. |
| `computerName` | The target host. Required by `WinRM` and `SSH`. |
| `credential` | A credential block, resolved through the Credential hook. |

No other key in the `target` block is read.

With a credential:

```yaml
    target:
      action: WinRM
      computerName: web01.contoso.com
      credential:
        action: SecretManagement
        name: DeployAccount
        vault: DeploymentVault
```

Over SSH (requires the `DscV3` engine — the SSH target action rejects `DscV2` outright, because
there is no CIM-over-SSH transport for `Invoke-DscResource`):

```yaml
    target:
      action: SSH
      computerName: app01.contoso.com
```

> The runner passes only `ComputerName`, the resolved engine, and the resolved credential to a
> Target action. The SSH action *can* use a `UserName` and a `KeyFilePath`, but there is no
> `target` key that reaches them today — SSH authentication falls back to the runner account's
> own `~/.ssh` configuration. Put the user and identity file in an SSH `Host` block for the
> target instead.

Explicitly pinning one resource back to the runner itself, under a remote file-level default:

```yaml
    target:
      action: Local
```

Sessions are cached per `(action, computerName, credential)`, so several resources aimed at one
host share a connection, and every session is closed when the file finishes — however it
finishes. `Local` never invokes the Target hook at all.

See [Remote Targets and Credentials](Remote-Targets-and-Credentials) for the full picture,
including reboot behaviour on a remote target.

## `resourceCredential`

Resolves a credential through the Credential hook and injects it into the resource's **own**
properties, so the credential never appears in the configuration.

```yaml
  - name: Database
    type: SqlServerDsc/SqlDatabase
    resourceCredential:
      action: Environment
      propertyName: Credential
      UserNameVariable: SQL_USER
      PasswordVariable: SQL_PASSWORD
    properties:
      ServerName: sql01
      InstanceName: MSSQLSERVER
      Name: AppDatabase
      Ensure: Present
```

| Key | Default | Meaning |
| --- | --- | --- |
| `action` | `Environment` | Which file under `Actions/Credential/` resolves it. |
| `propertyName` | `Credential` | The property on the resource the resolved credential is written to. |

All remaining keys are passed to the action as its context. Each built-in action reads
different ones:

From environment variables:

```yaml
    resourceCredential:
      action: Environment
      UserNameVariable: SQL_USER
      PasswordVariable: SQL_PASSWORD
```

From a SecretManagement vault:

```yaml
    resourceCredential:
      action: SecretManagement
      name: SqlDeployAccount
      vault: DeploymentVault
```

Into a non-default property name:

```yaml
    resourceCredential:
      action: SecretManagement
      name: SqlDeployAccount
      propertyName: PsDscRunAsCredential
```

`resourceCredential` is declarative, not a script, so it is **not** gated by
`AllowExecutionScripts`. It resolves during property expansion, which means a failure to
resolve — a missing environment variable, a secret that is not in the vault — records the
resource `FAIL` with that message and moves on.

## What the runner ignores

Keys the runner does not recognise are carried through the compiled file and never read. They
are not an error, which makes them usable for comments and for tooling of your own — but note
that a typo (`propeties:`) is therefore silently ignored rather than rejected. The pre-parse
property check catches wrong keys *inside* `properties`, not wrong keys on the resource itself.
