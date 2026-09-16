# Remote-target execution and credential handling — plan

Follow-on design for §4/§5 of [issue #57](https://github.com/ZanattaMichael/Dsc.PipelineRunner/issues/57),
extending [`docs/lifecycle-scripting-and-reboot-handling.md`](./lifecycle-scripting-and-reboot-handling.md)
(§3.4's remote reboot story is contingent on this landing first) and following the same
`Actions/<Hook>/<Name>.ps1` pattern already used for `Source`, `Connect` and `Engine`
(`Invoke-Action.ps1`, `Invoke-DscRunner.ps1`).

Nothing here is implemented yet.

## 1. Why credential handling needs its own hook

The original sketch in issue #57 §5 had the caller pass the actual secret straight into
`-TargetContext @{ Credentials = @{ <name> = $cred } }`, mirroring `-ConnectContext`/
`-SourceContext` today. That's workable for a single hardcoded PAT (`Actions/Connect/AzureDevOps.ps1`
today), but a remote target's connection credential needs to come from *wherever the operator's
secret actually lives* — an environment variable on a hosted agent, a secret store
(`Microsoft.PowerShell.SecretManagement`), a cloud key vault, a file-based credential on a
self-hosted box — and the runner has no business knowing which. That's exactly the shape of
problem `Source`/`Connect`/`Engine` already solve by being pluggable actions rather than
hardcoded logic in `Start-DscRunner.ps1`. Credential *retrieval* should be the same: a `Credential`
hook, resolved by name, that the agent (the runner process) calls at the point a target needs
authenticating — not a value the caller pre-fetches and threads through parameters by hand.

This also keeps the existing, deliberate boundary from issue #57 §5 intact: the compiled Datum
YAML (`Build-DatumConfiguration`) still only ever carries a `credentialRef` **name**, never
material. The difference is *how* that name resolves to a `[PSCredential]`/`[SecureString]` at run
time — via a handler the runner invokes, not a hashtable the caller pre-populated.

## 2. The `Credential` hook

Add `Credential` to `Invoke-Action`'s `ValidateSet` (`Source`, `Connect`, `Engine`, and — once §4
of issue #57 lands — `Target`), following the file exactly as written today:
`Actions/Credential/<Name>.ps1`, invoked as `& $actionPath -Context $Context`, returning whatever
the handler returns.

### 2.1 Handler contract

- **Input** — a `-Context` hashtable. Always carries:
  - `Name` — the `credentialRef` string from the compiled configuration (the logical name an
    author wrote in YAML, e.g. `svcAccount`), the only thing that ever reaches disk.
  - `Purpose` — `'Connection'` or `'ResourceProperty'` (§4), so a handler can apply a different
    policy per use if it wants to (e.g. require MFA-backed retrieval for connection auth but not
    for a low-privilege resource-property secret) — optional to act on, always supplied.
  - Whatever handler-specific configuration the caller supplied via the new `-CredentialContext`
    parameter on `Invoke-DscRunner`/`Start-DscRunner` (mirrors `-SourceContext`/`-ConnectContext`
    exactly: a hashtable merged with per-call defaults, passed through unchanged).
- **Output** — a `[PSCredential]` when the target needs a username and secret (the common case —
  WinRM/SSH connection auth, a service-logon resource property), or a bare `[SecureString]` when
  only a secret is meaningful (a PAT-style token, mirroring `Get-PipelineAuthToken`'s existing
  return shape). Never a plain `[string]` — same rule `Get-PipelineAuthToken`/
  `Unprotect-SecureString` already enforce for the git-auth path.
- Resolution happens **once per `(TargetAction, computerName, credentialRef)` tuple per file**,
  cached alongside the session-reuse cache §4 of issue #57 already specifies for `Target` sessions
  — a handler backed by a network call (key vault, secret store) shouldn't be invoked once per
  resource.

### 2.2 Built-in handlers to ship

- **`Environment`** (default) — mirrors `Get-PipelineAuthToken`'s existing environment-variable
  convention rather than inventing a new one. `Name` is upper-cased and prefixed
  (`DSCRUNNER_CREDENTIAL_<NAME>_USERNAME` / `..._PASSWORD`, or just `..._SECRET` for the
  `[SecureString]`-only case), read via `[Environment]::GetEnvironmentVariable`, wrapped with
  `ConvertTo-SecureString -AsPlainText -Force` at the point of construction (same, already-reviewed
  pattern `Get-PipelineAuthToken` uses, same `PSAvoidUsingConvertToSecureStringWithPlainText`
  justification). Zero external dependencies — works out of the box on any hosted or self-hosted
  agent that can set job-scoped environment variables (Azure Pipelines secret variables, GitHub
  Actions secrets, etc. all surface as env vars).
- **`SecretManagement`** — soft dependency on `Microsoft.PowerShell.SecretManagement`, following
  the exact soft-dependency shape `Actions/Connect/AzureDevOps.ps1` already uses (`Get-Module
  -ListAvailable` check, clear actionable error if absent, no hard `RequiredModules` entry). Calls
  `Get-Secret -Name $Context.Name -Vault $Context.VaultName`. This is the recommended answer for
  "I already have a vault" (Key Vault, CyberArk, etc. all ship `SecretManagement` extension
  vaults) without the runner needing a bespoke integration per provider.
- **`Static`** (opt-in, non-production) — accepts a `[PSCredential]`/`[SecureString]` placed
  directly in `-CredentialContext` by the caller, e.g. `@{ Credentials = @{ svcAccount = $cred } }`
  (this is the shape issue #57 §5 originally proposed). Kept as a named handler rather than the
  only option, explicitly documented as "for local dev / unit tests / a caller that already has an
  in-memory secret from its own vetted source" — not a channel for YAML-supplied secrets, since
  nothing stops a caller from populating it however it likes, but the docs steer authors toward
  `Environment`/`SecretManagement` for anything checked into a pipeline definition.

A custom handler is just another `Actions/Credential/<Name>.ps1` file (or an inline `-ScriptBlock`,
same escape hatch `Invoke-Action` already offers) — a bespoke internal vault integration doesn't
need a PR against this module.

## 3. Where the two consumers from issue #57 §5 call the handler

Issue #57 §5 already separates two problems; both become "call `Invoke-Action -Hook Credential`",
just at different points in the loop:

- **Connection credential** (§4's `Target` hook, WinRM/SSH session construction) — resolved once
  when the session is built, `Purpose = 'Connection'`, result fed to
  `New-CimSession -Credential`/`New-PSSession -Credential` (WinRM) or the SSH session constructor.
  Cached with the session per `(TargetAction, computerName, credentialRef)`, so re-resolving on
  every resource against the same override machine doesn't happen.
- **Resource-property credential** (DscV3, per issue #57 §5) — resolved per-resource,
  `Purpose = 'ResourceProperty'`, immediately before building the `--input` JSON payload for that
  resource's `dsc resource set`. The plaintext produced by `Unprotect-SecureString` at that point
  must only ever be interpolated into the JSON sent over the already-encrypted
  `Invoke-Command -Session` channel — never written via `--file` to disk on either the controller
  or the target — and the resulting `arguments`/JSON must be routed through the existing
  `Test-SensitivePropertyName`/`Protect-SensitiveValue` helpers before any `Write-Verbose`, fixing
  the pre-existing unredacted-logging bug `Actions/Engine/DscV3.ps1` has today independent of any
  of this. `DscV2` keeps using native `MSFT_Credential` marshaling once a remote session is
  threaded through (§4) — no handler involvement needed there beyond the connection-credential use
  above, since CIM already carries a typed `[PSCredential]` property end-to-end over the encrypted
  transport.

## 4. What stays out of scope here

- The `Target` hook itself (`Actions/Target/<Name>.ps1`, `WinRM`/`SSH`/`Local`, session reuse) is
  issue #57 §4's own chunk of work — this document only adds the `Credential` hook it depends on
  and describes where the two hooks meet. `Credential` has no dependency on `Target` existing yet:
  `Environment`/`SecretManagement`/`Static` can all be built and unit-tested standalone (feeding a
  `[PSCredential]` to, say, a test double) before `Target` lands, same way `Connect` shipped ahead
  of any engine consuming its session today.
- Fan-out (resolving one `credentialRef` across a list of target machines) is explicitly out of
  scope, same call issue #57 §4 already makes for `Target` fan-out generally.
- Credential *rotation*/expiry handling is not addressed — a handler is called fresh per
  `(TargetAction, computerName, credentialRef)` cache miss, so a vault-backed handler naturally
  picks up a rotated secret on the next file/run; there's no in-run refresh of a cached session's
  credential if it expires mid-file.

## 5. Sequencing

Slots into issue #57's suggested sequencing as an elaboration of item 7 ("§5's DscV3
remote-credential handling — depends on §4"):

1. `Credential` hook + `Invoke-Action` `ValidateSet` update + `-CredentialContext` parameter —
   self-contained, no dependency on `Target`.
2. `Environment` handler (default, zero external dependency) — ships first so `Target`'s own
   development/testing has something to resolve against.
3. `Static` handler — for unit tests exercising `Target`/`Credential` together without real
   secrets.
4. `SecretManagement` handler — soft dependency, same pattern as `Actions/Connect/AzureDevOps.ps1`.
5. Wire connection-credential resolution into `Target`'s `WinRM`/`SSH` session construction, once
   §4 lands.
6. Wire resource-property credential resolution into `Actions/Engine/DscV3.ps1`'s `--input`
   construction, alongside the pre-existing unredacted-logging fix from issue #57 §5 (that fix
   ships independently and first, per issue #57's own sequencing item 2 — this step is the
   credential-specific follow-on against the same file).
7. Docs: `README.md` action-hook table gains `Credential`; `docs/trust-model.md` gains a section
   on what a `Credential` handler is trusted to do (resolve a name to a secret in memory) and is
   not trusted to do (persist it, log it, or receive it from YAML).

## 6. Worked example (illustrative — not yet implemented)

Shape of the config surface once §4 (`Target`) and this document both land, following the same
`Example Configuration/` conventions used elsewhere in the repo.

`Datum.yml` — file-level defaults, same table `PipelineRunnerSettings.Source`/`Connect`/`Engine`
already use:

```yaml
PipelineRunnerSettings:
  ConfigurationVersion: 0.1
  PipelineRunnerVersion: 0.1
  DSCResourceVersion: 3.0
  Engine: DscV3           # a file in Actions/Engine/      (default: DscV2)
  Target: WinRM            # a file in Actions/Target/      (default: Local)
  Credential: Environment   # a file in Actions/Credential/  (default: Environment)
```

`Datum.yml` only ever selects *which action files run* — `Target: WinRM` names
`Actions/Target/WinRM.ps1`, same as `Engine`/`Source`/`Connect` today. The connection details
themselves (`computerName`, `credentialRef`) are configuration data, not settings, so — per issue
#57 §4 — they live in the *compiled* configuration YAML alongside `parameters`/`variables`/
`resources`, resolved per node the same way `ProjectName` already is via Datum's own lookup.

A resource file — a file-level `target:` block every resource in the file runs against by
default, one resource overriding it to run against a different machine, and one DscV3 resource
whose *property* (not the connection) needs its own credential:

```yaml
parameters: {}

variables: {
  ServiceName: 'MyApp',
  DomainAccount: 'CONTOSO\\svc-myapp'
}

# Connection details for the WinRM target every resource below runs against,
# unless a resource's own `target:` block overrides it (mixed-target files).
# `computerName` is resolved per node the same way `$ProjectName` already is;
# `credentialRef` is a *name*, resolved by the Credential handler at run time —
# never the secret itself.
target:
  computerName: $NodeName
  credentialRef: svcDeploy

resources:

  - name: Ensure MyApp service is running
    type: PSDesiredStateConfiguration/Service
    properties:
      Name: $ServiceName
      State: Running

  - name: Ensure MyApp service runs as a domain account
    type: PSDesiredStateConfiguration/Service
    target:                       # per-resource override — same shape as `dependsOn`/`preCondition`
      computerName: 'app02.contoso.com'
      credentialRef: svcDeploy
    properties:
      Name: $ServiceName
      State: Running
      Credential:                 # resource-property credential (§3) — DscV2/CIM marshals this
        credentialRef: svcMyAppLogon   # natively; DscV3 resolves it via the Credential handler
                                        # immediately before building --input.
```

The corresponding `Invoke-DscRunner` call — `-CredentialContext` is handler-specific config only
(here, nothing beyond the default `Environment` handler's own env-var convention needs supplying);
the secrets themselves live in the agent's environment, never in the call or the YAML above:

```powershell
Invoke-DscRunner -Source Git -SourceContext @{ Url = $repo; Token = $pat } `
                  -Target WinRM `
                  -Credential Environment
# Resolves credentialRef 'svcDeploy' from $env:DSCRUNNER_CREDENTIAL_SVCDEPLOY_USERNAME /
# ..._PASSWORD, and 'svcMyAppLogon' the same way, both set as job-scoped secret variables
# by the calling pipeline — never written into the compiled configuration on disk.
```

Swapping the file-level default to `Credential: SecretManagement` (with a vault named in
`-CredentialContext @{ VaultName = 'CorpVault' }`) resolves the same two `credentialRef` names
against `Get-Secret -Vault CorpVault` instead, with no change to the YAML above — the whole point
of the handler being pluggable is that `credentialRef` names stay stable across environments while
the retrieval mechanism behind them changes per agent.
