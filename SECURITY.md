# Security Policy

## Supported versions

Security fixes are made on `main` and released as a new patch version. Only the **latest
release** is supported: if you are on an older release, upgrade before reporting, or say so in
the report and we will check whether the issue still reproduces on the latest.

| Version | Supported for security fixes |
|---|---|
| Latest release (currently `1.2.x`) and `main` | Yes |
| Anything older | No - upgrade to the latest release |

## Reporting a vulnerability

**Please report suspected vulnerabilities privately.** Use a
[GitHub security advisory](https://github.com/ZanattaMichael/Dsc.PipelineRunner/security/advisories/new)
("Report a vulnerability" on the repository's Security tab). Please do **not** open a public
issue, pull request or discussion, and do not post a proof of concept anywhere public, until a
fix is released.

A useful report contains:

- the affected version (`(Get-Module Dsc.PipelineRunner).Version`) and engine
  (`DscV2` / `DscV3`), and whether it also reproduces on `main`;
- what an attacker can do, and what they need first (access to the configuration repository, a
  pull request, a managed node, the pipeline logs...);
- the smallest configuration or command that reproduces it;
- the output you saw, **with any real secret replaced by a dummy value**. Never send a live
  credential; if one has already been exposed, rotate it now, then report.

## What to expect

This is a small, maintainer-run project, so these are **targets**, not guarantees. We will tell
you if we cannot meet one.

| Step | Target |
|---|---|
| Acknowledge the report | within 5 business days |
| Confirm it, or explain why not, and give an initial severity | within 10 business days |
| Status update while the issue is open | at least every 14 days |
| Fix released (from confirmation) | Critical 14 days, High 30 days, Medium 60 days, Low in the next release |
| Public disclosure | when the fix is released; at the latest 90 days after the report, unless we agree a different date with you |

Fixes are released as a normal tagged release (the tag-driven Release workflow), published
together with a GitHub security advisory that credits the reporter (unless you prefer to stay
anonymous) and, where it applies, a CVE. The CHANGELOG records the fix under **Security**. How we
handle a report internally is described in
[docs/security-response-process.md](docs/security-response-process.md).

## Severity

We rate a report by what it lets an attacker do **beyond what the trust model below already
grants**, using these guidelines.

| Severity | Examples in this project |
|---|---|
| **Critical** | Code execution on the build agent or a managed node by someone who is *not* the author of the trusted configuration repository; a credential sent to a party that should not receive it by default. |
| **High** | A secret reaching a log, report, command line or error message; a bypass of `AllowExecutionScripts`, the condition allow-list or the property-expansion allow-list; a compiled file written outside the cache directory; a workflow flaw that exposes secrets or a self-hosted runner to a fork pull request. |
| **Medium** | Needs unusual configuration or privileges; disclosure of non-secret internal data; log or report injection; unbounded resource use triggered by input the runner treats as untrusted. |
| **Low** | Hardening and defence-in-depth gaps; a security document that no longer matches the behaviour. |

## Scope

**In scope:** the module (`source/`), the Actions (`Actions/`), the Pipeline Rules
(`Pipeline Rules/`), the helper scripts (`scripts/`), the container definition, the GitHub
workflows, and the release process.

**Out of scope:**

- **By-design behaviour documented in the [trust model](#trust-model).** The configuration
  repository is executed as trusted code, so "a malicious configuration can run PowerShell" is
  not a vulnerability. A way for a configuration to get *past a control we document* - for
  example running a `preExecutionScript` without `AllowExecutionScripts`, or running a command
  from a `preCondition` - **is** in scope.
- Weaknesses in third-party components (Datum, `powershell-yaml`, DSC resources, `dsc.exe`,
  PowerShell itself). Please report those upstream. If our *use* of one makes it exploitable,
  tell us as well.
- Attacks that need prior control of the build agent, the managed node or the configuration
  repository's write access.
- Social engineering, and denial of service by a trusted configuration.

## Disclosure and safe harbor

We follow **coordinated disclosure**: you report privately, we fix, and we publish together. If
you act in good faith - you stay within the scope above, avoid privacy violations and service
disruption, use dummy data, and give us a reasonable time to fix before disclosing - we will not
pursue or support any action against you for the research.

## How the module ensures security

A summary of the controls; the sections below describe each in detail, and every one is pinned
by a security-tagged test (see [Regression tests](#regression-tests-for-these-guarantees)).

| Concern | How it is addressed |
|---|---|
| **Trust boundary** | The configuration repository is the one trusted input, and this is documented rather than hidden. `preExecutionScript` / `postExecutionScript` are off unless `PipelineRunnerSettings.AllowExecutionScripts` is explicitly enabled. |
| **Code in configuration values** | `preCondition` / `postCondition` are parsed and checked against an allow-list of side-effect-free accessors before they run. Every `$(...)` in a property value is checked against the same allow-list before it is expanded. Neither can call commands, assign, call methods, redirect, or `exit`. |
| **Fetching configuration** | Only `https`, `ssh` and `git@host:path` remotes; plaintext schemes and option-shaped URLs are rejected before git runs; a pinned revision is checked out with a `--` terminator and a full SHA is verified. |
| **Secrets on the command line** | Tokens are `[SecureString]`, and git authentication is passed through scoped environment configuration, never argv. The `dsc` instance JSON is sent on standard input, never `--input`. |
| **Secrets in output** | Known secrets (credentials, sensitive-named values, list-nested values) are scrubbed from every logged and recorded message; credentials embedded in git URLs and a rejected `-PATToken` are never echoed; secret-named properties are redacted in verbose output. |
| **Untrusted text** | Resource names and engine/remote output cannot inject CI log commands or extra log lines; CSV cells cannot carry spreadsheet formulas; files are written with `-LiteralPath`. |
| **Malformed or hostile input** | A malformed resource or a scalar `target` is a recorded failure for that resource, never a crash or a silent local run; structural mistakes fail closed; `variables` cannot overwrite runner state or steer child processes; node file names, composite fan-out and SSH host names are bounded. |
| **Local files** | Clone and cache directories are created owner-only; cleanup only ever removes directories the runner registered; action names cannot resolve outside `Actions/<Hook>/`. |
| **Remote targets and credentials** | Credentials come from a Credential action (`Environment`, `SecretManagement`, `Static` for development only), sessions are cached per identity, and the plaintext never reaches a target's command line. |
| **Downloads and build inputs** | The `dsc` archive is verified by SHA-256 *before* it is extracted: against `scripts/dsc-checksums.json` (reviewed pins), else GitHub's published digest, and it is refused if neither exists. Every third-party Action is pinned to a commit SHA, the container base image to a digest, and the image runs as a non-root user. Dependabot proposes updates to those pins as reviewed pull requests. PowerShell Gallery modules are installed at exact versions from `scripts/module-versions.json` through `scripts/Install-PinnedModule.ps1` (a failed download is retried, the installed version is checked), and a test fails on a bare `Install-Module`. |
| **CI and release** | Workflows declare minimal token permissions, avoid `pull_request_target`, guard self-hosted jobs against fork pull requests, keep untrusted event data out of `run:` steps, and pin actions. PSScriptAnalyzer results are published to code scanning. |
| **Staying honest** | Each guarantee has a regression test under `Tests/PipelineRunner/Security/`, and a test checks that this document lists them. |

**Known limits** (so that the summary above is not read as more than it is): opt-in state capture redacts by key name and by the secrets the runner knows, so a secret that `Get()` returns under an innocuous name is not recognised; the configuration
is trusted code and is not sandboxed; `preExecutionScript` / `postExecutionScript` are
unconstrained once enabled; the module is not Authenticode-signed (releases carry a build
provenance attestation instead, see below; #38); the Gallery modules CI and the container image install
are pinned to exact versions but the Gallery publishes no checksum to verify them against, and
modules that a pinned module pulls in as its own dependencies are not pinned; constrained-language compilation is not implemented (#46);
and the runner sets no input-size or alias-expansion limit on YAML parsing.

### Verifying a release

Each release's `.nupkg` is published with a **build provenance attestation**: a statement, signed
with the release workflow's own identity and recorded in a public transparency log, of which
workflow run built the file from which commit. It needs no certificate and costs nothing. Check a
download with the GitHub CLI:

```bash
gh attestation verify Dsc.PipelineRunner.<version>.nupkg --repo ZanattaMichael/Dsc.PipelineRunner
```

The attestation covers every `.nupkg` the release build produced, which includes the bundled
dependency packages as well as `Dsc.PipelineRunner` itself; verify the file you downloaded.

The package's SHA-256 is also written to the release run's summary. This proves where a package
came from; it is **not** an Authenticode signature, so PowerShell's `AllSigned` execution policy
does not use it.

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

### Trusting the layers of one configuration differently (preview)

The statement above — the configuration repository is one unit of trust — is the default and
remains true when no policy is present. A
[**capability policy**](docs/capability-policy.md) (`Policy.yml` beside `Datum.yml`) narrows it per
layer. A layer is decided by where a file is in the repository, never by anything written inside
the file, so the policy's path patterns mirror the repository controls (CODEOWNERS, per-folder
branch protection) that tie a folder to a team.

Per layer, a policy decides: which Target actions and engines may be used; which **resource types**
may be declared; which **machines** a non-`Local` Target may reach; which **Credential actions** may
be resolved, so a team can be allowed the build agent's environment variables and denied the
platform's vault and inline passwords; whether `preExecutionScript`/`postExecutionScript` and Datum
script blocks are allowed; whether a resource may `notify` another into re-applying itself; and
whether the runner may **restart a remote target**. A capability a layer does not list follows the
policy's `Default`, so with `Default: Deny` a capability added in a later version of the runner is
denied until the policy grants it.

Enforcement is in three places: a raw-text scan of the layer files before Datum loads anything;
every knowable violation before the first resource of a compiled file runs, reported in one pass;
and again at the point of use, immediately before a target is contacted, a credential is resolved
or a machine is restarted. It fails closed — a provenance record that is missing, unreadable, from
another policy or written for another node, a file no layer claims, a resource not in the record,
and `-RequirePolicy` without a policy all stop the run. `Get-DscCapabilityPolicyReport` describes what a policy permits without compiling or
running anything.

What a policy does **not** do: it is not a sandbox for the compile step (the Datum merge still runs
as ordinary PowerShell; Part A of issue #86 is the containment work), it does not constrain the
properties passed to an allowed resource type or which methods a layer may use, it restricts
Credential *actions* rather than individual secrets, and `Datum.yml` still controls the merge, so it
must belong to the most trusted layer and be protected like `Policy.yml` itself. A contributor who
can change or delete `Policy.yml` controls the policy; a pipeline that cannot rely on repository
controls should supply its own with `-PolicyPath` from somewhere contributors cannot write, or at
minimum pass `-RequirePolicy`.

### What this means for operators

Without a capability policy, anyone who can push to the configuration repository can execute
arbitrary code on the build agent and on the managed nodes. This is inherent to running DSC
configurations and cannot be patched away inside `Dsc.PipelineRunner`; it must be mitigated
**operationally**:

- Protect the configuration repository with the **same controls as the runner's own
  source**: branch protection, required reviews, and — where available — signed commits.
- Restrict who can trigger the pipeline and which branches it runs from.
- Pin the configuration to a reviewed revision with `-ConfigurationRevision`, ideally a full
  commit SHA, so a push to the tracked branch cannot change what a run applies.
- Run the agent with the least privilege the target resources require.
- Where several teams contribute to one configuration, add a
  [capability policy](docs/capability-policy.md) so each layer is limited to what it needs, and
  pass `-RequirePolicy` so removing the file cannot switch enforcement off unnoticed.

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
- `Tests/PipelineRunner/Security/SecurityPolicy.Security.tests.ps1` — this policy keeps its
  required sections, points reporters at a private channel, links the maintainers' response
  process, and lists every security test file, so a guarantee cannot exist without being
  documented.
- `Tests/PipelineRunner/Security/SupplyChain.Security.tests.ps1` — `Install-DscV3.ps1` checks the
  archive's SHA-256 before extracting it (a pinned mismatch, an unlisted asset, a GitHub-digest
  mismatch and "nothing to verify against" are all refused and install nothing; the override is
  explicit), the lock file is well formed and pins its default release, every action is pinned to
  a commit SHA, the container base is pinned by digest and runs non-root, Dependabot covers both,
  and the release records a provenance attestation.
- `Tests/PipelineRunner/Security/Workflows.Security.tests.ps1` — every workflow declares token
  permissions, none uses `pull_request_target`, every self-hosted job reachable from
  `pull_request` is guarded against fork PRs, no `run:` step interpolates attacker-controlled
  event data, and every action is pinned to a version or SHA.

- `Tests/PipelineRunner/Security/ReleaseTagging.Security.tests.ps1` — the release tag is computed by
  `scripts/Get-NextReleaseTag.ps1`, which only produces `vX.Y.Z` or `vX.Y.Z-<letters><digits>`, never
  goes to a version at or below the latest stable release, rejects malformed versions and
  Gallery-invalid labels, and refuses a preview counter that would sort out of order; the "Create
  release tag" workflow is manual-only, runs from `main` only, requires every check on `main` to be
  passing, reads its inputs through `env:`, asks for no more than `contents`/`actions` write and
  `checks` read, and stores no personal access token.

- `Tests/PipelineRunner/Security/ModulePinning.Security.tests.ps1` — every Gallery module is pinned to
  one exact version in `scripts/module-versions.json`; `Install-PinnedModule.ps1` installs exactly
  that version, leaves one already present alone, retries a failed download, verifies the result and
  refuses a module that is not pinned; `RequiredModules.psd1` has no `latest` and agrees with the
  lock file; no workflow, script or the Dockerfile runs a bare `Install-Module`.
- `Tests/PipelineRunner/Security/Reporting.Security.tests.ps1` — the CSV and JSON report files keep
  their shape and no state is captured unless `Report.State` asks for it; captured desired and actual
  state is redacted (credentials, sensitive-named values at any depth including in `Get()` output,
  known secrets echoed inside other strings) and bounded; a reporter receives the same redacted
  document and, if it fails, cannot change the result or stop the other reporters; a reporter name
  cannot select a script outside `Actions/Report/`; the `Webhook` reporter is https only, refuses
  credentials in the URL, sends the token in a header, does not follow redirects, and names only the
  host and status in an error. The `JUnit` and `Summary` reporters cannot be made to emit extra XML
  elements, table cells, HTML, links or images by a resource name or message, and cannot write outside
  the report directory. `Report.OnError: Fail` marks a file `ReportFailed` without altering resource
  results, and `Get()` output is released from memory when its file is finished.
- `Tests/PipelineRunner/Security/DryRun.Security.tests.ps1` — a dry run (`-Mode DryRun`) never calls an
  engine, a Target action or a Credential action and never runs an execution script; it still fails a
  resource for an unsafe or malformed expression, an undeclared parameter, an unknown or path-shaped
  target/credential action, a scalar target or a script that does not parse; an expression that reads
  run-time state is validated and deferred, not evaluated; the resultant configuration it writes and
  returns has secrets redacted; and a Test or Set run returns no RSOP.
- `Tests/PipelineRunner/Security/CapabilityPolicy.Security.tests.ps1` — the capability policy
  (preview, `Policy.yml` beside `Datum.yml`, see [docs/capability-policy.md](docs/capability-policy.md)):
  the policy is a file of its own that Datum never loads, so it cannot be merged or overridden; a
  policy in a layer's sub-folder is neither discovered nor accepted, a `Datum.yml` that declares a
  store for the policy file is refused, and `-RequirePolicy` fails a configuration that has none; a
  policy that cannot be read exactly is an error; a layer is
  decided by a file's path, a path that climbs out of the configuration belongs to no layer, and an
  unclaimed file has no capabilities whatever the default; what several layers contributed to is
  allowed only if every one of them is; a Datum script block in a layer that may not use one stops
  the compile before Datum loads it and cannot be hidden with YAML; a file that breaks the policy
  does not start and every violation is named, with the node, the policy, the layer and the files
  that layer owns; a resource type, the machine a remote Target reaches, every Credential action a
  resource resolves, a `notify` that would force another layer's resource to re-apply, and a
  restart of a remote target are each denied by default and each refused at the point of use as
  well as before the run; `dependsOn` is deliberately not restricted; a list capability with
  nothing to match is denied even against `'*'`; a Target written as an expression is checked when
  it is known, against every layer that could have supplied it, and so is the computer beside it;
  a missing, unreadable or foreign provenance record fails closed; and
  `Get-DscCapabilityPolicyReport` describes a policy, and finds the ways one is silently
  ineffective, without compiling or running anything.
- `Tests/PipelineRunner/Security/PlainSecretExposure.Security.tests.ps1` — plain-string secrets
  under sensitive names, and secrets inside lists of mappings, are scrubbed from the thrown error
  and redacted from the verbose breadcrumb, an overlapping secret is replaced whole, and
  ordinary values are not over-redacted.
- `Tests/PipelineRunner/Security/RunnerInputHardening.Security.tests.ps1` — a resource name or
  an engine error cannot inject CI log commands or extra log lines, CSV cells cannot carry
  formulas, a `node[1].yml` file still produces both reports (even under
  `ErrorActionPreference=Stop`), a report failure does not lose the run result, an engine-echoed
  secret never reaches the log, CSV or JSON report, a malformed resource or scalar `target` is a
  recorded failure, and structural mistakes fail closed by name.
- `Tests/PipelineRunner/Security/VariableInjection.Security.tests.ps1` — configuration
  `variables` cannot take a reserved runner or PowerShell name, cannot overwrite an existing
  environment variable or export one that steers a child process, and a rejected configuration
  writes nothing.
- `Tests/PipelineRunner/Security/GitUrlCredential.Security.tests.ps1` — credentials embedded in
  a git URL never appear in log lines or exceptions (including git's echoed output) while git
  still receives the real URL, and option-shaped scp-style URLs are rejected.
- `Tests/PipelineRunner/Security/TokenHandling.Security.tests.ps1` — a rejected `-PATToken` is
  never echoed, and a token with a trailing newline is rejected.
- `Tests/PipelineRunner/Security/InputLimits.Security.tests.ps1` — a compiled node file name
  cannot leave the output directory, composite expansion stops at `-MaxResources`, and an SSH
  host name cannot be read as an option.

Run them on their own with `Invoke-Pester -Path ./Tests/PipelineRunner -TagFilter Security`;
they also run as part of the default unit gate (`./tests.ps1`).

### Future hardening

Constrained-language execution and AST-based allow-listing of permitted resource types
are tracked as follow-on work. They would narrow, but not eliminate, the trust boundary
described here.

See the companion page [docs/trust-model.md](docs/trust-model.md) for a longer discussion.
