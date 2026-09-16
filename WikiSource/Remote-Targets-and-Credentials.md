# Remote Targets and Credentials

Two independent seams, usually used together:

- A **Target** action decides *where* a resource is evaluated.
- A **Credential** action decides *how a secret is fetched*, so it never appears in the
  configuration.

## The identity the runner runs as

Everything on this page happens **as the account the runner process is running under** — the
pipeline agent's service account on a self-hosted agent, or your own account when you run
`Invoke-DscRunner` by hand. A `target` block names a computer; it does not name who connects to
it. Unless `target.credential` supplies one explicitly, the runner's own identity is what
authenticates to the remote host, and the run can do only what that identity is permitted to do.

So the agent must run as a **real account that already holds the rights the configuration
needs** — not the identity an agent service is installed with by default.

### On the machine the runner runs on

| Default service identity | Why remoting fails under it |
| --- | --- |
| `NT AUTHORITY\LocalService` | Presents as an anonymous session off-box. It cannot authenticate to a remote host at all. |
| `NT AUTHORITY\NetworkService`, `LocalSystem` | Present the *computer* account (`DOMAIN\MACHINE$`). A valid identity, but it is almost never a member of anything on the target, so the connection is refused. |

The Azure Pipelines agent installs as `NT AUTHORITY\NETWORK SERVICE` unless you choose
otherwise, which is why a pipeline that works from an interactive session can fail as soon as it
runs unattended. Reconfigure the agent service to run as a domain (or, for a workgroup target, a
matching local) account and grant *that* account the rights below.

Two more things are decided by the runner's own identity:

- **Registering the WinRM endpoint.** `Enable-PSRemoting` — including registering the
  `PowerShell.7` endpoint described below — needs an elevated process.
  `scripts/Enable-SelfHostedWinRM.ps1` checks for elevation and reports a warning instead of
  configuring anything when the service is not elevated.
- **Where per-user state lives.** A `Microsoft.PowerShell.SecretStore` vault, an SSH key in
  `~/.ssh`, and `WSMan:\localhost\Client\TrustedHosts` are all read as the running account.
  Register the vault and install the key *while signed in as the service account* (or in a
  process running as it); a vault registered under your own profile is invisible to the agent.

### On each target

| The run needs to… | The identity must be… |
| --- | --- |
| Open a `PSSession` / `CimSession` over WinRM | A member of the target's local `Remote Management Users` group, or of local `Administrators`. WinRM's default endpoint SDDL grants those two. |
| Apply DSC with the `DscV2` engine | A member of the target's local `Administrators`. `Invoke-DscResource` drives the CIM/DSC subsystem, and most resources change machine-wide state — `Remote Management Users` is enough to *open* a session but not to *configure* the machine. |
| Apply DSC with the `DscV3` engine | Whatever `dsc` and the resource need on the far side — in practice local `Administrators` for machine-scoped resources. |
| Restart a target after `RebootRequired` | Holder of *Force shutdown from a remote system* on the target, which local `Administrators` has by default. Without it the restart fails after the `Set()` has already run. |

Across a domain boundary — or with no domain at all — there is no Kerberos ticket to present.
Either add the target to the runner's `TrustedHosts` and pass an explicit `target.credential`
(NTLM), or configure an HTTPS WinRM listener with a certificate the runner trusts. Using
`TrustedHosts` with a blanket `*` disables the server-identity check for every connection; name
the hosts.

### The second hop

A resource evaluating on a remote target holds the session's credentials but cannot forward
them to a *third* machine — the standard second-hop restriction, and it applies just as much to
a resource reaching a file share or a SQL instance as to the runner itself. Give such a resource
its own `resourceCredential` rather than expecting the connecting identity to flow onward.

### When the service account cannot be granted those rights

Supply `target.credential`. The session is then opened as the resolved credential and the
runner's own identity only has to be able to *fetch* the secret:

```yaml
    target:
      action: WinRM
      computerName: web01.contoso.com
      credential:
        action: SecretManagement
        name: DeployAccount
        vault: DeploymentVault
```

This is the better arrangement in production regardless: the account that applies configuration
is scoped and rotated independently of the account the build agent happens to run as.

## Targets

### Selecting one

The file-level default comes from `PipelineRunnerSettings.Target` and defaults to `Local`. Any
resource may override it with its own `target` block:

```yaml
PipelineRunnerSettings:
  Target: WinRM
```

```yaml
resources:

  - name: Web Feature
    type: PSDscResources/WindowsFeature
    target:
      computerName: web01.contoso.com
    properties:
      Name: Web-Server
      Ensure: Present
```

The `target` block reads exactly four keys — `action`, `computerName`, `credential` and
`configurationName`. No other key in the block is used.

| Action | Transport | Works with |
| --- | --- | --- |
| `Local` | none | both engines |
| `WinRM` | `CimSession` + `PSSession` | both engines |
| `SSH` | `PSSession` over SSH | `DscV3` only |

`Local` is special: it never invokes the Target hook at all, so a configuration that says
nothing about targets takes exactly the local path it always did.

### `WinRM`

```yaml
    target:
      action: WinRM
      computerName: web01.contoso.com
      credential:
        action: SecretManagement
        name: DeployAccount
        vault: DeploymentVault
```

The action builds **both** a `CimSession` and a `PSSession` for the same computer, so either
engine can take the shape it needs without the configuration having to know which:

- `DscV2` runs its `Invoke-DscResource` call on the far side over the `PSSession`. (It does not
  pass `-CimSession`: `PSDesiredStateConfiguration` 2.x, which PowerShell 7 uses, removed that
  parameter.) Credentials marshal natively as
  `MSFT_Credential` over the encrypted WinRM transport.
- `DscV3` runs `dsc` on the far side via `Invoke-Command -Session`.

`computerName` is required; omitting it throws before any session is opened.

#### `configurationName` — which endpoint the `PSSession` lands on

```yaml
    target:
      action: WinRM
      computerName: web01.contoso.com
      configurationName: PowerShell.7
```

Optional, and applied to the `PSSession` only — a `CimSession` is a CIM connection with no
PowerShell endpoint to choose.

Omitted, the session lands on the target's **default** WinRM endpoint, which on Windows is
Windows PowerShell 5.1. That matters for `DscV2`: a current Windows build no longer carries an
in-box `Invoke-DscResource` there, so the remote evaluation has nothing to run on the far side.
`PowerShell.7` is the endpoint `Enable-PSRemoting` registers when it is run under `pwsh`, and it
is where `PSDesiredStateConfiguration` 2.x lives. Name it when the target runs PowerShell 7 —
which is what the self-hosted runner's remoting suite does.

Sessions are cached per endpoint as well as per computer, so two resources naming the same host
with different `configurationName` values get different sessions.

### `SSH`

```yaml
    target:
      action: SSH
      computerName: app01.contoso.com
```

SSH requires `DscV3`. The action rejects `DscV2` outright, with a message saying why — there is
no CIM-over-SSH transport for `Invoke-DscResource`:

```
[Actions/Target/SSH] SSH remoting requires the DscV3 engine (there is no CIM-over-SSH
transport for DscV2/Invoke-DscResource); the resolved engine was 'DscV2'.
```

> **Authentication.** The runner passes only `ComputerName`, the resolved engine and the
> resolved credential to a Target action. The SSH action *can* use a `UserName` and a
> `KeyFilePath`, but no `target` key reaches them today — SSH authentication falls back to the
> runner account's own SSH configuration. Put the user and identity file in a `Host` block in
> `~/.ssh/config` for the target instead — in the **service account's** profile, which is not
> the one you edit when you configure SSH interactively, and make sure that account's key is
> authorised on the target.

### Session caching

Sessions are cached on `(action, computerName, configurationName, credential)`. Several resources aimed at one
host share one connection rather than opening a fresh session each:

```yaml
resources:

  - name: Web Feature
    type: PSDscResources/WindowsFeature
    target: { action: WinRM, computerName: web01.contoso.com }
    properties: { Name: Web-Server, Ensure: Present }

  - name: Site Directory
    type: PSDscResources/File
    target: { action: WinRM, computerName: web01.contoso.com }
    properties: { DestinationPath: C:\inetpub\app, Type: Directory, Ensure: Present }

  - name: Db Feature
    type: PSDscResources/WindowsFeature
    target: { action: WinRM, computerName: sql01.contoso.com }
    properties: { Name: NET-Framework-45-Core, Ensure: Present }
```

Two sessions are opened, not three. Every cached session is closed in the file's `finally`
block — however the file ends.

The cache key is per **file**, so two compiled node files targeting the same host each open
their own session.

### Reboots on a remote target

A resource whose `Set()` reports `RebootRequired` behaves differently depending on where it
ran:

- **Remote**: the runner restarts the target and waits for it
  (`Restart-Computer -Wait -Force`), then continues — **regardless** of
  `PipelineRunnerSettings.Reboot`. The runner's own host is not what needs to come back up. The
  target's credential is reused for the restart when one was supplied.
- **Local**: the policy decides. `Ignore` continues without restarting; the default `Fail`
  records the resource `FAIL` and skips the rest of the file, because the runner cannot restart
  the machine it is running on and resume mid-file.

Aiming a reboot-requiring resource at a remote target is therefore the clean way to handle it.

### Mixing local and remote in one file

```yaml
PipelineRunnerSettings:
  Target: WinRM

resources:

  - name: Web Feature
    type: PSDscResources/WindowsFeature
    target:
      computerName: web01.contoso.com
    properties:
      Name: Web-Server
      Ensure: Present

  - name: Deployment Record
    type: PSDscResources/File
    target:
      action: Local          # back to the runner itself
    properties:
      DestinationPath: C:\deploy\web01.done
      Contents: deployed
      Ensure: Present
```

### Writing a Target action

A `.ps1` under `Actions/Target/`, taking a `-Context` hashtable with `ComputerName`, `Engine`
and `Credential`, returning:

```powershell
@{
    ComputerName = 'host'
    IsRemote     = $true
    CimSession   = $cimSession    # or $null
    PSSession    = $psSession     # or $null
}
```

`IsRemote` is what the reboot logic keys on. Supply whichever session shape the engine you
expect will use, or both.

## Credentials

A credential block appears in two places, and both go through the same hook:

- `target.credential` — the credential used to *reach* the remote host.
- `resourceCredential` — a credential injected into the resource's **own** properties.

Three actions ship with the module.

### `Environment`

Reads a username and a password from two environment variables. This is the CI-friendly
default: the pipeline supplies the secret, and the configuration names only the variables.

```yaml
    resourceCredential:
      action: Environment
      UserNameVariable: SQL_USER
      PasswordVariable: SQL_PASSWORD
```

Both keys are required. A missing variable throws, naming both:

```
[Actions/Credential/Environment] Environment variable(s) 'SQL_USER'/'SQL_PASSWORD' are not set.
```

### `SecretManagement`

Reads from a Microsoft.PowerShell.SecretManagement vault. The vault is resolved **as the runner's
own identity**: a `Microsoft.PowerShell.SecretStore` vault lives in the registering user's
profile, so it has to be registered and unlocked for the service account the agent runs as, not
for the account that set the machine up. See
[The identity the runner runs as](#the-identity-the-runner-runs-as).

```yaml
    resourceCredential:
      action: SecretManagement
      name: SqlDeployAccount
      vault: DeploymentVault
```

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | yes | The secret name. |
| `vault` | no | The vault. Omitted, the default vault is used. |
| `userName` | no | Used when the secret is a bare `SecureString`; defaults to `name`. |

A `PSCredential` secret is returned as-is. A `SecureString` secret is wrapped into a
`PSCredential` using `userName` (or the secret's own name). Any other secret type throws rather
than guessing:

```
[Actions/Credential/SecretManagement] Secret 'X' is a 'String', not a PSCredential or
SecureString - cannot resolve it to a credential.
```

### `Static`

The escape hatch for local development. It warns on **every** use.

```yaml
    resourceCredential:
      action: Static
      UserName: contoso\deploy
      Password: NotForProduction
```

```
WARNING: [Actions/Credential/Static] Using a statically-configured credential. Prefer the
'Environment' or 'SecretManagement' Credential actions in production.
```

`Password` may be a plaintext string or an existing `SecureString`. Do not put a real secret in
a configuration repository — a static credential means the plaintext already exists somewhere
the runner could read directly.

### `resourceCredential` in full

```yaml
  - name: Database
    type: SqlServerDsc/SqlDatabase
    resourceCredential:
      action: SecretManagement
      name: SqlDeployAccount
      vault: DeploymentVault
      propertyName: PsDscRunAsCredential
    properties:
      ServerName: sql01
      InstanceName: MSSQLSERVER
      Name: AppDatabase
      Ensure: Present
```

| Key | Default | Meaning |
| --- | --- | --- |
| `action` | `Environment` | The file under `Actions/Credential/`. |
| `propertyName` | `Credential` | Which property the resolved credential is written to. |

Everything else in the block is the action's context. The resolved credential is written into
the expanded property table just before the target is resolved, so the resource sees it as if
it had been declared inline.

`resourceCredential` is **declarative**, not a script, so it is not gated by
`AllowExecutionScripts`. A resolution failure records the resource `FAIL` with the action's
message and the run continues to the next resource.

### Writing a Credential action

A `.ps1` under `Actions/Credential/` taking `-Context` and returning a `[PSCredential]` (or a
`[SecureString]`). Everything in the YAML block is handed to it, so a custom action defines its
own keys:

```powershell
param([hashtable]$Context = @{})

if ([string]::IsNullOrWhiteSpace([string]$Context.RoleArn)) {
    throw "[Actions/Credential/MyVault] 'RoleArn' is required in the Credential context."
}

$secret = Get-MyVaultSecret -RoleArn $Context.RoleArn -Name $Context.Name
[System.Management.Automation.PSCredential]::new(
    $secret.UserName,
    (ConvertTo-SecureString $secret.Password -AsPlainText -Force))
```

```yaml
    resourceCredential:
      action: MyVault
      RoleArn: arn:aws:iam::123456789012:role/deploy
      name: sql-deploy
```

Throw on a missing input rather than returning `$null` — the built-in actions all do, so a
misconfiguration is reported against the resource instead of producing a silent null
credential.

## Where a secret can appear

| Path | Plaintext exposure |
| --- | --- |
| `DscV2`, local or WinRM | None. `[pscredential]` marshals as `MSFT_Credential` over the encrypted transport. |
| `DscV3`, local | Resolved to plaintext in the `--input` JSON handed to the `dsc` process. Never written to disk. |
| `DscV3`, remote | The same JSON, sent over the already-encrypted `Invoke-Command -Session` channel. |

Logs are redacted on two grounds: any property that started life as a `[pscredential]` or
`[securestring]` is force-redacted regardless of its name, and a name-based heuristic catches
the rest. The pre-parse property rule likewise names an offending property and its permitted
values, never the value itself — that goes only to the verbose stream, redacted.
