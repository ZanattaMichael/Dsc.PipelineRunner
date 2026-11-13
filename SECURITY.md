# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the repository owner via a
[GitHub security advisory](https://github.com/ZanattaMichael/Dsc.PipelineRunner/security/advisories/new)
rather than opening a public issue. Include the affected version, a description of the
issue, and a reproduction if you have one.

## Trust model

**The configuration repository is executed as fully-trusted code.**

`Dsc.PipelineRunner` compiles a Datum/DSC configuration by executing it as PowerShell.
A DSC `Configuration` block is *code*, not merely data: it can contain arbitrary
PowerShell in addition to resource declarations, and it runs in the same process and
security context as the runner. The runner does **not** sandbox, allow-list, or otherwise
validate the content of a configuration before running it.

Concretely:

- `Build-DatumConfiguration` retrieves and invokes the `DatumConfigurationScriptBlock`
  compile step, which executes the configuration.
- `Invoke-DscPipelineRunner` and `Invoke-DscRunner` accept a **remote URL** as the
  configuration source, clone it, and compile it — so code from the remote repository
  runs on the build agent and, through the applied resources, on every managed node.
- Resource `preCondition` (formerly `condition`, still accepted as a deprecated alias),
  `postCondition`, `preExecutionScript` and `postExecutionScript` fields are also evaluated
  as PowerShell.
  - `preCondition` and `postCondition` are constrained to side-effect-free predicates: they
    may not invoke commands, assign or increment variables, call methods, redirect output to
    a file, or use `exit`, `break` or `continue` (each of which has an effect outside the
    predicate: a file write, terminating the runner, or escaping the runner's own resource
    loop), other than through the allow-listed function-language accessors such as
    `parameters()`, `variables()`, `reference()`, `equals()` and `not()` (see issue #35). `postCondition` additionally allows `result()` (the just-applied resource's
    `[DscMethodResult]`) and `stopProcessing()` (requests that the remaining resources in
    the file be skipped) — these two are allow-listed **only** for `postCondition`, never
    for `preCondition`, so a pre-check can never mutate run state (see issue #57).
  - `preExecutionScript` and `postExecutionScript` are imperative by design and are **not**
    constrained to a predicate grammar. Because of that, they only run when
    `PipelineRunnerSettings.AllowExecutionScripts: true` is set; a configuration that
    declares either field with the gate off (or unset) fails compilation with a
    pre-parse error naming every offending resource, rather than silently skipping the
    script or running it anyway. This is an explicit opt-in, not a sandbox — once enabled,
    these scripts run with the same trust and privileges as the rest of the configuration.

### What this means for operators

Anyone who can push to the configuration repository can execute arbitrary code on the
build agent and on the managed nodes. This is inherent to running DSC configurations and
cannot be patched away inside `Dsc.PipelineRunner`; it must be mitigated
**operationally**:

- Protect the configuration repository with the **same controls as the runner's own
  source**: branch protection, required reviews, and — where available — signed commits.
- Restrict who can trigger the pipeline and which branches it runs from.
- Pin the configuration to a reviewed revision with `-ConfigurationRevision`, ideally a full
  commit SHA, so a push to the tracked branch cannot change what a run applies.
- Run the agent with the least privilege the target resources require.

When the configuration source is a remote URL, the runner emits a `Write-Warning` at the
start of compilation restating this trust requirement.

### What the runner enforces

Fetching the configuration is the one part of this the runner *can* protect, and it does so
unconditionally:

- **Transport.** Only `https`, `ssh` and SCP-style `git@host:path` remotes are accepted. A
  plain `http://` URL is rejected with a terminating error naming the scheme, because a
  configuration fetched over a transport an attacker can rewrite is a remote code-execution
  path into the runner's own security context.
- **Revision pinning.** `-ConfigurationRevision` checks out a branch, tag or commit after the
  clone; a full 40-character SHA is verified against the clone's resolved `HEAD` and a
  mismatch fails the run. The resolved `HEAD` SHA is always written to the information
  stream, so the pipeline log records the exact commit that ran.
- **Credential handling.** Clone tokens are held as `[SecureString]` and injected as an HTTP
  `Authorization` header through git's environment-based configuration — never on the
  process command line. The header is scoped to the origin of the configured remote
  (`http.https://host/.extraHeader`), so git does not present it to any other host a redirect
  might land on, and it is only sent at all by a call that names an https remote. Every line
  git returns, stderr included, is scrubbed of both the raw token and the encoded credential
  before it can reach an error message or the log.
- **Revision pinning cannot inject options.** A `-ConfigurationRevision` that begins with `-`
  is rejected before any git call, and the checkout terminates its argument list with `--`,
  so a revision is only ever read as a ref.
- **Temporary directories.** Clones and fallback cache directories are created owner-only
  (`0700` on Unix, a single full-control ACE on Windows) and removed when the run ends,
  including when it ends by throwing. Only directories the runner created are removed; a
  caller-supplied path is never deleted.

None of this makes an untrusted configuration safe to run. It removes the ways the
*transport* could be turned against a configuration you have already decided to trust.

### Remote targets and credential handling

`Target` (`Local`, `WinRM`, `SSH`) and `Credential` (`Environment`, `Static`,
`SecretManagement`) actions extend the trust boundary from the build agent to whatever
they connect to:

- **Remote targets are a new trust boundary.** A resource with a non-`Local` `target`
  opens a `CimSession`/`PSSession` to the named `ComputerName` and applies the resource
  there. Anyone who can edit the configuration can point a resource at an arbitrary
  reachable host and run resources against it with whatever credential is resolved for
  that connection — the same "configuration repo is fully-trusted code" boundary above,
  now extended over the network. Restrict which hosts are reachable from the build agent
  and which credentials are available to it accordingly.
- **`Credential: Static` is a development/test convenience, not a production pattern.**
  It takes a plain-text or securestring password inline in the configuration and emits a
  `Write-Warning` every time it is used, so its use is visible in pipeline logs. A
  plain-text credential committed to the configuration repository is exposed to everyone
  with read access to that repository's history.
- **`Credential: Environment`** (the default) reads a username/password pair from two
  named environment variables on the build agent, keeping the secret value out of the
  configuration repository itself — but it is only as safe as the pipeline's own
  environment-variable handling (masking, log redaction) already is.
- **`Credential: SecretManagement`** resolves a secret by name from a registered
  `Microsoft.PowerShell.SecretManagement` vault (`Get-Secret`), so the secret's lifecycle,
  access control and rotation are delegated entirely to that vault backend. The runner
  does not cache, log or persist the resolved secret beyond the in-memory `[PSCredential]`
  used for the connection or resource.
- **`resourceCredential`** resolves a credential the same way and injects it into the
  named resource property (`Credential` by default) before the resource is applied. As
  with any DSC `[PSCredential]` property, PowerShell's own `SensitiveData`/argument
  redaction applies when the module (or `Write-Verbose`/tracing) formats it — the runner
  does not print resolved credential values itself.
- **The DSC v3 engine never puts a secret on a command line.** `dsc.exe` has no credential
  type, so a resolved `[PSCredential]`/`[SecureString]` is serialised into the instance JSON
  in plaintext. That JSON is written to `dsc`'s standard input (`--file -`), never passed as
  an `--input` argument: a command-line argument is readable by every local user through the
  process table and is captured by process-creation auditing. The same applies on a remote
  target, where the JSON crosses the already-encrypted `Invoke-Command` channel and is piped
  to `dsc` on the far side. If `dsc` fails, the plaintext values are scrubbed from its output
  before the failure is surfaced, because `dsc` echoes the offending input on a schema error.
- **Target sessions are cached per identity.** A session opened for a `target` is reused only
  by resources whose target action, computer name, endpoint and complete credential settings
  (user name, vault, variable names — everything except the password value) match, so two
  resources aimed at one host with different credentials never share a session.
- Sessions opened for a `target` are cached per `(target action, computer name,
  credential)` for the duration of a single run and are always closed in the run's
  `finally` block, including on failure, so a compromised or misbehaving resource cannot
  leave a remote session open past the run that created it.

### Regression tests for these guarantees

Every control above is pinned by an explicit, security-tagged test, so a change that weakens
one fails the ordinary unit gate rather than waiting for the next audit:

- `Tests/PipelineRunner/Security/SecretExposure.Security.tests.ps1` — no secret value (any
  shape: `[PSCredential]`, `[SecureString]`, sensitive-named plaintext, nested) ever appears in
  the `dsc` argument vector, the verbose stream, or a thrown error; the git wrapper never
  returns a token (raw or Basic-encoded) on any stream, never sets an unscoped
  `http.extraHeader`, never sends the header to a non-https remote, and never leaves it in the
  environment.
- `Tests/PipelineRunner/Security/ConditionSideEffects.Security.tests.ps1` — a corpus of every
  side-effecting PowerShell shape (commands, obfuscated invocation, assignment, `++`/`--`,
  method and static calls, redirection, `exit`, `break`, `continue`) is rejected by the
  condition validator in both `preCondition` and `postCondition`, while the documented pure
  predicates still pass. The end-to-end proofs through the real resource loop (the redirection
  target is never created, `break`/`continue` never escape the loop, `exit` never ends the
  process) live in the `Security` contexts of
  `Tests/PipelineRunner/DSCConfiguration/Public/Start-DscRunner.tests.ps1`.
- `Tests/PipelineRunner/Security/ConfigurationSource.Security.tests.ps1` — insecure or
  option-shaped remote URLs and option-shaped revisions are rejected before git is invoked,
  the checkout always terminates its ref with `--`, a pinned SHA mismatch fails the run, an
  action name can never resolve outside `Actions/<Hook>/`, and cleanup never deletes a
  caller-owned directory.
- `Tests/PipelineRunner/Security/Workflows.Security.tests.ps1` — every workflow declares token
  permissions, none uses `pull_request_target`, every self-hosted job reachable from
  `pull_request` is guarded against fork PRs, no `run:` step interpolates attacker-controlled
  event data, and every action is pinned to a version or SHA.

Run them on their own with `Invoke-Pester -Path ./Tests/PipelineRunner -TagFilter Security`;
they also run as part of the default unit gate (`./tests.ps1`).

### Future hardening

Constrained-language execution and AST-based allow-listing of permitted resource types
are tracked as follow-on work. They would narrow, but not eliminate, the trust boundary
described here.

See the companion page [docs/trust-model.md](docs/trust-model.md) for a longer discussion.
