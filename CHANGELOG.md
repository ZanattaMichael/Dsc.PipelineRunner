# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- **`target: configurationName` — the WinRM endpoint a `PSSession` lands on.** Optional, and
  applied to the `PSSession` only: a `CimSession` is a CIM connection with no PowerShell endpoint
  to choose. It exists because fixing the `-CimSession` defect below moved the remote DSC v2
  evaluation onto the far side, where it then needs an `Invoke-DscResource` to run — and
  `New-PSSession` without `-ConfigurationName` lands on the target's *default* endpoint, Windows
  PowerShell 5.1, which on a current Windows build no longer carries one. The live remoting suite
  reported exactly that on the self-hosted runner (Windows 10.0.26100): *the remote runspace has
  no Invoke-DscResource*. Naming `PowerShell.7` — the endpoint `Enable-PSRemoting` registers when
  run under `pwsh` — lands the session where `PSDesiredStateConfiguration` 2.x is installed.
  Sessions are cached per endpoint as well as per computer. Omitted, the behaviour is unchanged.

  `scripts/Enable-SelfHostedWinRM.ps1` now also makes sure that endpoint is registered, on the
  already-configured path as well, and the remoting suite prefers it — so the remote DSC v2 test
  runs instead of skipping. Both remain non-fatal: an endpoint that cannot be registered is a
  warning and a skip with the reason, not a build break.

- **Live SSH remoting coverage.** `Tests/PipelineRunner/DSCConfiguration/Integration/
  SSHTarget.Integration.tests.ps1` (tag `HostedIntegration`) opens a real session against a real
  `sshd`, closing the last remote path that had no live proof at all — the SSH Target action was
  unit-tested only with `New-PSSession` mocked, which validates dispatch and the `DscV2`
  fail-fast guard but cannot tell whether the parameters it builds are accepted, whether the
  session comes back usable, or whether it carries the engine to the far side. The same gap in
  the WinRM path is what hid two remote DSC v2 defects until the live WinRM suite went in.

  `.github/workflows/Integration-HostedAgent.yml` provisions it on the hosted Ubuntu agent:
  `openssh-server`, a `powershell` subsystem in `sshd_config`, the agent account's own key
  authorised against itself, and `dsc` copied into `/usr/local/bin` so the *remote* account can
  find it (`$GITHUB_PATH` reaches this job's steps, not the shell `sshd` starts). The suite
  connects the agent to itself — a real remote connection, serviced by a separate `pwsh` process,
  needing no second machine — and drives the shipped `Actions/Engine/DscV3.ps1` over the session.

  `Get-SshRemotingSkipReason` (`Tests/TestHelpers`) decides whether it can run, distinguishing no
  `ssh` client, a host that cannot be authenticated to non-interactively, and one reachable by
  `ssh` whose `sshd` has no `powershell` subsystem. Anywhere those do not hold — a workstation
  running the script by hand — the suite skips with the reason instead of failing.

### Documentation

- **The identity the pipeline runs as is now documented as a requirement, not an assumption.**
  With no `target.credential`, every remote session — and every per-user secret store — is opened
  as the account the runner process runs as. On a self-hosted agent that is the agent service
  account, which installs as `NT AUTHORITY\NETWORK SERVICE` and reaches a target as the computer
  account, so remoting fails unattended even where it worked from an interactive session. A new
  *The identity the runner runs as* section in
  `WikiSource/Remote-Targets-and-Credentials.md` states what that account must hold: local
  `Remote Management Users` on the target to open a session, local `Administrators` to apply DSC
  (`Invoke-DscResource` drives the CIM/DSC subsystem), *Force shutdown from a remote system* for
  the reboot path, elevation on the agent itself to register the WinRM/`PowerShell.7` endpoint,
  and ownership of the SecretStore vault, SSH key and `TrustedHosts` entries the run depends on —
  plus the cross-domain and second-hop cases, and using `target.credential` where the service
  account cannot be granted those rights.

  Carried into `README.md`'s self-hosted agent setup, `WikiSource/Resource-Properties.md`
  (`target`), `WikiSource/Engines.md` (`DscV2`), `WikiSource/Getting-Started.md`,
  `WikiSource/Home.md`, six new `WikiSource/Troubleshooting.md` entries (WinRM `Access is
  denied`, Kerberos/`TrustedHosts`, no `Invoke-DscResource` on the far side, a failed remote
  reboot, a vault that resolves only interactively, and SSH keys under the wrong profile), and
  the comment-based help of both Target actions.

- **The `powershell` subsystem an SSH target needs.** `sshd` refuses the subsystem request
  PowerShell makes once the connection is up unless one is registered, so `New-PSSession` fails
  against a host `ssh` reaches perfectly well. Now stated in the `SSH` section of
  `WikiSource/Remote-Targets-and-Credentials.md`, with a new
  `WikiSource/Troubleshooting.md` entry (*`ssh` works, but the SSH target never opens a
  session*) and the `sshd_config` line to add.

### Fixed

- **Every release gate was cancelled before a runner was assigned.** The seven suites
  `.github/workflows/Release.yml` reuses via `workflow_call` each declared
  `concurrency: group: ${{ github.workflow }}-${{ github.ref }}`. Inside a called workflow
  `github.workflow` resolves to the *caller's* name, so all seven computed the one group
  `Release-refs/tags/<tag>`, and the four carrying `cancel-in-progress: true` cancelled their
  siblings as each entered it. In release run 35149112946 (`v1.1.0-preview3`) all eight gate
  jobs ended `cancelled` roughly a second after starting with no `runner_name` — never
  dispatched, so the tag shipped with nothing linted or tested. Each reusable workflow now
  names its own group (`lint-`, `code-coverage-`, `integration-hosted-`, …), which keeps the
  per-workflow de-duplication on `push` and `pull_request` while letting the gates run
  independently under `workflow_call`.

  The preview publish itself was not a defect: `Release.yml` deliberately lets a prerelease
  publish regardless of the gate results. A *full* release requires every gate to report
  `success`, and a cancelled gate does not, so this would have blocked `vX.Y.Z` outright.

- **Every remote DSC v2 evaluation threw before reaching the resource.**
  `Actions/Engine/DscV2.ps1` added `-CimSession` to its `Invoke-DscResource` call whenever a
  target had resolved a session. That parameter exists only on Windows PowerShell 5.1's in-box
  `Invoke-DscResource`; `PSDesiredStateConfiguration` 2.x — the module PowerShell 7 loads, and
  this module requires PowerShell 7.0 — removed it, and the call fails with `A parameter cannot
  be found that matches parameter name 'CimSession'` before the resource is ever reached. So the
  remote DSC v2 path could not work on any supported PowerShell version. The engine now carries
  the evaluation to the far side over the target's `PSSession` and runs `Invoke-DscResource`
  locally there — the one arrangement both PowerShell versions support, and the same way the DSC
  v3 engine already reached a remote target. `-CimSession` remains a fallback for a target that
  resolves a `CimSession` and no `PSSession`, and is now probed for rather than assumed, so a
  host without it reports which piece is missing instead of a parameter-binding failure.

  The mocked unit suite could not have caught this: its mock *defined* `-CimSession`, so the
  call it asserted was one the real cmdlet cannot bind. `WinRMTarget.Integration.tests.ps1`,
  running against a live WinRM listener on the self-hosted runner, is what surfaced it, and now
  drives the shipped engine action through a real session rather than hand-writing the call.

- **The documented `postCondition: result().InDesiredState -or stopProcessing()` did not
  parse.** `stopProcessing()` was normalized to a bare `stopProcessing`, and PowerShell rejects a
  bare command as an operand ("You must provide a value expression following the '-or'
  operator") — so the one spelling the documentation leads with was the one that could not run.
  Zero-argument accessors now normalize to a parenthesised sub-expression (`(stopProcessing)`,
  `(result)`, `(nodeName)`, `(configurationFile)`), which parses both on its own and as an
  operand.

Every issue in the repository carrying the `bug` label.

- **#9 — Git clone was passing a boolean instead of the repository URL.**
  `Clone-Repository` assigned `[System.Uri]::IsWellFormedUriString(...)` to the URL
  variable, so every clone ran as `git clone True <destination>`. The function also
  returned `$null`, because `New-TemporaryDirectory` emitted a `[DirectoryInfo]` and both
  call sites read a `.Path` property that type does not have. `New-TemporaryDirectory` now
  returns the path as a string, and the clone returns the directory it cloned into.
- **#9 — Authenticated clones were sending a malformed Authorization header.** The `git`
  wrapper placed the raw token into `Authorization: Basic <token>` without base64-encoding
  it. A raw token is now encoded as `x-access-token:<token>`, which Azure DevOps and GitHub
  both accept; a credential that is already base64-encoded is passed through unchanged.
- **#31 — `Invoke-DscPipelineRunner` cloned `http://` URLs.** Configuration is now fetched
  over `https` or `ssh` only (SCP-style `git@host:path` included); any other scheme is
  rejected before git runs. The resolved HEAD commit is logged on the information stream so
  a run records exactly what it applied.
- **#32 — Clone directories were world-readable and never cleaned up.** Temporary
  directories are created owner-only (0700 on Unix, a single-identity DACL on Windows) and
  removed in a `finally` block at both entry points. Only directories the runner itself
  created are removed - a caller-supplied local path is never deleted. Pass
  `-KeepTemporaryDirectory` to leave them in place for debugging.
- **#15 — A missing or empty configuration file reported a successful run.** `Get-Content`
  raised a non-terminating error, the parsed document stayed `$null`, and the run reported
  `Completed` with zero resources. `Start-DscRunner` now rejects an unsupported extension, a
  path that does not exist, and a document that parses to nothing, each with a terminating
  error naming the file.
- **#6 — Valid dependency graphs were rejected as circular.** The depth-first walk pushed
  each resource onto a shared stack and never popped it, so any resource reached by two
  branches - the shared tail of a diamond, for instance - looked like a cycle. The walk now
  backtracks correctly, resolves each resource through an index rather than a per-dependency
  scan, and reports the cycle members in path order.
- **#5 — The `<params=Name>` token was never expanded.** `Expand-Parameters` had no
  production caller, read its list values from the caller's scope, and reported a parameter
  defined as an empty string as missing. Resource properties now resolve parameter tokens
  before string interpolation, so a token keeps the parameter's type. An unresolvable token
  fails that one resource rather than aborting the run. A one-entry list is expanded
  element-wise too, where it was previously routed to the scalar branch and stringified.
- **Array-typed resource properties were flattened into a string.** `Expand-HashTable`
  recognised a collection only by the ``List`1`` type name, so a plain array reached
  `ExpandString` and collapsed into `"System.Collections.Hashtable ..."`. Any array now
  expands element-wise, and a property such as `AzDoGitPermission`'s `Permissions` binds
  again.
- **A parameter declared without a `defaultValue` resolved to `$null` instead of failing.**
  `Get-DefaultValues` added every key in the `parameters` section to the parameter table,
  taking `.defaultValue` even when the declaration had none. The key was then present, so
  the presence check backing `<params=Name>` and `parameters('Name')` succeeded and the
  token resolved to `$null` — indistinguishable from a parameter legitimately defaulted to
  an empty string, and exactly the silent wrong value the throw added for #5 was meant to
  prevent. Such a declaration is now skipped with a warning naming it, so referencing it
  fails the same way an undeclared name does. An empty string or an explicit null is still
  a declared default and still resolves.
- **#16 — The built module exported nothing.** The seven public commands are advanced
  functions but were listed under `CmdletsToExport` with `FunctionsToExport` empty, so no
  entry point was available after `Import-Module`. `VariablesToExport = '*'` also leaked the
  module's internal `$references`, `$variables` and `$parameters` into the caller's session,
  and `IconUri` pointed at a GitHub `/blob/` page rather than the image. All four are fixed.
- **#17 — `Invoke-DscPipelineRunner` ignored `-PATToken`.** `-AuthenticationType` defaulted
  to `ManagedIdentity` independently of the token supplied, so a caller who passed a PAT
  still went down the managed-identity path. See the breaking changes below.

### Added

- **Twenty new function-language accessors, usable in `properties`, `preCondition` and
  `postCondition`.** Strings and collections: `concat()` (string concatenation; use `+` for
  arrays), `empty()`, `coalesce()`, `toLower()`, `toUpper()`, `startsWith()` and `contains()`
  (which dispatches on the container — substring for a string, element for a collection, and
  **key** for a dictionary). Arithmetic: `add()`, `sub()`, `mul()`, `div()`, `mod()`, `min()`,
  `max()`, `int()` and `float()`. Run context: `nodeName()` and `configurationFile()`, which
  report the node and file currently being processed and are cleared when the runner finishes
  the file. Every one is on the condition allow-list.
- **Arithmetic preserves an operand's own integrality.** An operand that is a whole number, or a
  string that parses as one (the `"4"` a YAML file typically yields), stays a whole number
  through the operation; a real number is never silently collapsed back. `div` therefore divides
  as whole numbers only when both operands are whole, so `div 7 2` is `3` and
  `div (float 7) 2` is `3.5`. Strings are parsed with the invariant culture, so a configuration
  behaves identically on an agent in any locale. `$null`, a boolean and a non-numeric string all
  throw, naming the accessor and the value, and fail only the resource whose expression contained
  them.
- **`using()` is now allowed in a `preCondition`,** not only in `properties`, so a resource can be
  gated on what another resource's `Get()` actually returned. The `notify` gate applies exactly as
  it does in a property — the runner sets the current resource key before the `preCondition` is
  evaluated — and the same three errors are thrown when it is not declared. Because `using` is a
  PowerShell reserved word as the first token of a statement, it must be written nested, e.g.
  `equals (using 'Mod/Type/Name').Visibility 'Private'`.
- There is deliberately **no `secret()` accessor**, and one will not be added. A condition is
  recorded verbatim in the run's audit record and in the `SKIP` message of every resource it
  gates, so reading a secret from one would put the lookup — and, with a careless expression, its
  value — into a report that is routinely attached to a pipeline run. Secrets reach a resource
  through its `resourceCredential` block.

- `-ConfigurationRevision` on `Invoke-DscRunner` and `Invoke-DscPipelineRunner`, pinning the
  configuration repository to a branch, tag or commit. A full 40-character SHA is verified
  against the clone's resolved HEAD.
- `-KeepTemporaryDirectory` on both entry points, leaving a cloned configuration in place
  for debugging instead of removing it when the run ends.
- Tag-driven release automation (`.github/workflows/Release.yml`). Pushing a `vX.Y.Z`
  tag (or `vX.Y.Z-preview0001` for a prerelease) validates the tag, runs the full CI
  test suite as a release gate, and publishes the module to the GitHub Release and the
  PowerShell Gallery. A prerelease still runs the full suite but the deployment is not
  stopped by test failures. The version is taken from the tag and baked into the
  manifest at build time. The existing CI workflows gained a `workflow_call` trigger so
  the release reuses them as its gate instead of duplicating them.

### Testing

- **The WinRM remoting suite now has a listener to connect to, and a skip probe that tells the
  truth about it.** The self-hosted workflow ran `WinRMTarget.Integration.tests.ps1` but nothing
  configured a WSMan listener on the runner, so five of the six tests skipped with a warning on a
  green job - the coverage the suite exists to provide silently did not happen. A new
  `scripts/Enable-SelfHostedWinRM.ps1`, wired in as the `Ensure WinRM is enabled` step before the
  suite, configures one. It is deliberately conservative about a long-lived runner: it probes first
  and makes no changes when the listener is already usable, appends this computer to `TrustedHosts`
  rather than replacing the list (and only when the runner is not domain-joined, where NTLM needs
  it), reports a non-elevated runner process as a warning instead of an access error, and always
  exits 0 so an environment problem on the runner cannot turn an unrelated pull request red. The
  outcome - usable, already usable, or not usable and why - is written to the job's step summary so
  a green run cannot hide a skipped suite.

- **`Get-WinRMSkipReason` passed hosts the suite cannot actually connect to.** It probed with a
  bare `Test-WSMan`, which sends an ANONYMOUS WS-Man Identify and answers as soon as a listener
  exists, without authenticating anybody. The suite opens `New-CimSession`/`New-PSSession` as the
  current user, so a host that answers the anonymous probe can still refuse every session with
  "Access is denied" - a skip condition arriving as four test failures. Both the helper and
  `Enable-SelfHostedWinRM.ps1` now add `-Authentication Negotiate`, so the probe goes through the
  same authentication the sessions do and the two cannot disagree. Where the listener is up but
  authentication is refused, the remaining causes are machine-level rather than repository-level
  (NTLM loopback protection when connecting to the host by its own name, the runner's account not
  being in Administrators or Remote Management Users, or a restrictive WinRM `RootSDDL`); the suite
  skips with that message rather than failing, and the step summary says so.

- **The new accessors are unit and integration tested.** `Arithmetic.tests.ps1` covers all nine
  arithmetic accessors and the shared numeric coercion, pinning the whole-number contract and
  `div (float 7) 2 -eq 3.5`; `StringFunctions.tests.ps1` covers the seven string/collection
  accessors and the variadic argument flattening, including that `contains` tests a dictionary's
  keys rather than its values; `RunContext.tests.ps1` covers `nodeName()`/`configurationFile()`
  and asserts the normalizer's rewrite both matches the expected text and actually parses.
  `FunctionLanguage.Integration.tests.ps1` (tag `HostedIntegration`) drives real configuration
  files through `Start-DscRunner`: accessors deciding a `preCondition`, a bad operand failing only
  its own resource, `using()` in a `preCondition` under the `notify` gate, the run-context
  accessors in both a condition and a property plus the clear-on-finish, the fixed
  `stopProcessing()` composition, and `secret()` still being rejected from a file.

- **WinRM remoting, secret vaults, `using()` and the condition keys are now integration tested.** All were
  covered only by mocked unit tests, and `Actions/Target/WinRM.ps1` and
  `Actions/Credential/SecretManagement.ps1` said so in their own headers. Four new suites
  exercise the real thing:
  - `WinRMTarget.Integration.tests.ps1` (tag `RemotingSelfHosted`) opens real `CimSession`
    and `PSSession` objects against a live WinRM listener, proves a CIM query and an
    `Invoke-Command` reach the far side, and proves the resulting `CimSession` is accepted by
    `Invoke-DscResource -CimSession` - the reason the action builds one. It connects to the
    self-hosted Windows runner itself, so no second machine is needed, and skips itself with a
    warning on a host with no listener. Run from `DscV2-SelfHosted.yml`.
  - `SecretManagementCredential.Integration.tests.ps1` (tag `HostedIntegration`) registers a
    real `Microsoft.PowerShell.SecretStore` vault and resolves a `PSCredential` secret, a bare
    `SecureString` secret (with and without an explicit `UserName`), a default-vault lookup,
    an unsupported secret type and a missing secret. Configuring SecretStore for unattended
    use erases the current user's secrets, so the suite refuses to run unless
    `PIPELINERUNNER_ALLOW_SECRETSTORE_RESET` is `true`; only CI sets it.
  - `NotifyUsing.Integration.tests.ps1` (tag `HostedIntegration`) drives a genuine
    `Start-DscRunner` pass over a configuration file on disk and proves a value from one
    resource's `Get()` reaches another resource's properties through
    `$((using 'Type/Name').Property)` - the documented syntax, which only an end-to-end run
    can validate because the accessor is reached through `ExpandString`. Both arms of the
    notify gate (no declaration, and a declaration naming someone else) are asserted to fail
    only the reading resource, not the run.
  - `Conditions.Integration.tests.ps1` (tag `HostedIntegration`) covers `preCondition` and
    `postCondition` as they are actually authored - in a configuration file on disk. It proves
    a `preCondition` reading `variables()` skips its resource without ever reaching the engine
    while the rest of the file runs; that an unsafe predicate and the postCondition-only
    `result()` accessor each fail only their own resource; that a `postCondition` reading
    `result()` fails a resource the engine itself reported in the desired state, and passes
    when its assertion holds; and that `stopProcessing()` skips everything after it in the
    real `Sort-DependsOn` order without leaking into the next run. The unit suites cover these
    semantics with the configuration file and the parser mocked away, so none of them proves a
    condition authored in a file reaches the predicate that decides its resource.
- New `Integration Hosted Agent` workflow running the `HostedIntegration` suites on
  `ubuntu-latest`, added to the release gates in `Release.yml`; a WinRM step added to
  `DscV2-SelfHosted.yml`. `tests.ps1` excludes both new tags so the unit gate stays hermetic.

### Changed

- **The release workflow called a task that does not exist.**
  `.github/workflows/Release.yml` ran `./build.ps1 -Tasks Build_Wiki_Content,
  Publish_GitHub_Wiki_Content`, but nothing in this repository provides
  `Publish_GitHub_Wiki_Content` — it is a `DscResource.DocGenerator` task, and that module is
  not a dependency. `Sampler.GitHubTasks`, which `build.yaml` credited for it, exports only
  `Publish_release_to_GitHub` and `Create_ChangeLog_GitHub_PR`. The step was
  `continue-on-error: true`, so every release since v1.0.0 reported a green check over an
  `exit code 1` and published no wiki at all.

  Publishing is now `Publish_Wiki_Content`, a local task in `.build/wiki.build.ps1`: it clones
  `<owner>/<repo>.wiki.git` (owner and repository read from the checkout's `origin`, so a fork
  publishes to its own wiki), mirrors `output/WikiContent` into it, commits and pushes. It adds
  no new module dependency. The token is passed through git's `http.<host>.extraheader` rather
  than embedded in the remote URL, so it cannot reach `.git/config` or a git error message.

  `continue-on-error` is gone with it. The task itself never throws — no token, wiki not yet
  initialised, nothing to publish, push rejected are all reported to `$GITHUB_STEP_SUMMARY` and
  exit clean — so a wiki problem still cannot fail a release whose Gallery package is already
  published, but it can no longer be invisible.

- **The wiki is published on full releases only.** The publish step is gated on
  `IsPrerelease == 'false'`, the same gate the changelog roll-over already used, so a preview
  tag ships to the Gallery without moving the wiki and the published wiki always describes the
  latest released version. `Build_Wiki_Content` is no longer chained into `build.yaml`'s `build`
  workflow — it runs at release time, next to the publish it feeds. Wiki drift still fails a
  pull request: `.github/workflows/Wiki.yml` runs `scripts/Build-WikiContent.ps1` directly on
  every PR and throws on a page missing from `.pageorder`, a `.pageorder` entry with no page, or
  an exported command with no `.SYNOPSIS`.

- A dead `Generate_Conceptual_Help:` block has been removed from `build.yaml`'s `GitHubConfig:`.
  It configured a `DscResource.DocGenerator` task, was nested under the wrong top-level key, and
  nothing read it.

- `ModuleVersion` in `source/Dsc.PipelineRunner.psd1` bumped to `1.1.0`, matching the
  `PipelineRunnerVersion: 1.1.0` the shipped `Example Configuration/Datum.yml` declares.
  The value stays inside the `1.0`-`1.9` DSC resource module range enforced by
  `source/Public/VersionConfiguration.ps1`, so existing configurations are unaffected.
  A tagged release still overrides this value from the tag at build time.

### Documentation

- `WikiSource/Function-Language.md` now documents the full accessor set grouped by category,
  with examples for each of the new string, collection, arithmetic and run-context accessors,
  the `using()`-in-a-`preCondition` rules, why `secret()` is deliberately absent, and the
  `$(nodeName)` property spelling — property expansion does not go through the condition
  normalizer, so a property uses the bare form while a condition uses `nodeName()`. `README.md`,
  `WikiSource/Resource-Properties.md` and `docs/notify-and-using.md` were reconciled with the
  extended allow-list.

- `Assert-SafeConditionExpression`'s comment-based help showed the accessors being called with
  the comma-in-parens form (`equals(variables('Env'), 'Prod')`), which is exactly the form the
  README warns against: the accessors are ordinary PowerShell commands, so that syntax binds a
  single array argument and mis-binds silently. Both examples now use the space-separated form
  the shipped `Example Configuration` uses. Help text only; the validator is unchanged.
- `README.md`: the execution walkthrough now describes the two-pass property resolution
  (parameter tokens first, then variable interpolation and calculated properties) and refers
  to the selected `Engine` action rather than naming `Invoke-DscResource` as the only path. A
  new **Configuration source security** section covers the enforced clone transport, revision
  pinning, credential handling and temporary-directory lifecycle, and the circular-reference
  rule is described accurately: shared dependencies and diamonds are allowed, only genuine
  cycles are rejected. The parameter-token section now states where parameter values come
  from — a `defaultValue` in the configuration's own `parameters` section, with no
  invocation-time override — and that a declaration carrying no `defaultValue` is ignored,
  so referencing it fails as an undeclared name does.
- `SECURITY.md` and `docs/trust-model.md`: plaintext `http://` interception is no longer
  listed as an open risk to mitigate operationally — it is refused. Both pages gained a
  "what the runner enforces" section covering transport, revision pinning, `HEAD` logging,
  credential handling and owner-only temporary directories, while keeping the point that
  none of it makes an untrusted configuration safe to run.
- `docs/DECOUPLING_PLAN.md`: marked as in progress rather than proposed, with the resolved
  rows of the coupling snapshot annotated and the acceptance criteria that have shipped
  ticked off against what is actually in the repository.

### Breaking Changes — Public Parameter Contract and Parameter Resolution

The next release should be a **major** version bump. The release workflow takes the version
from the git tag, so tag accordingly.

#### `Invoke-DscPipelineRunner`

| Before | After |
|---|---|
| `-exportConfigDir` | `-ExportConfigDir` (no alias; update existing pipelines) |
| `-AuthenticationType 'ManagedIdentity'\|'PAT'` | Removed. Supplying `-PATToken` selects the PAT parameter set; omitting it uses managed identity. |
| `-Mode` mandatory | Optional, defaulting to `Test` |
| `-JITToken` mandatory in the managed-identity path | Optional in both parameter sets |
| `-PATToken` validated as `^[a-zA-Z0-9]{52}$` | Validated as `^[A-Za-z0-9]{20,120}$`, which admits the newer 84-character Azure DevOps tokens |

#### `parameters('Name')`

An undefined parameter now throws a terminating error naming the parameter, where it
previously returned `$null` silently. A configuration that relied on the silent `$null` -
so that the missing value landed in a resource property and the run applied the wrong
configuration - must declare the parameter or stop referencing it.

This now covers a parameter *declared without a `defaultValue`* as well. Such a declaration
used to be added to the parameter table with a `$null` value, which made the presence check
succeed and the reference resolve silently; it is now skipped with a warning, so referencing
it fails like any undeclared name. Give the parameter a `defaultValue` - an empty string is
a legitimate one - or stop referencing it.

### Breaking Changes — Module Renamed to `Dsc.PipelineRunner`

The module has been renamed from `AZDO-DSC-LCM` to `Dsc.PipelineRunner` to better reflect its purpose as a platform-agnostic DSC pipeline runner that works with GitHub Actions, GitLab CI, Jenkins, Azure DevOps, and any other CI/CD environment.

#### What Changed

| Before | After |
|---|---|
| Module name: `azdo-dsc-lcm` | Module name: `Dsc.PipelineRunner` |
| Manifest: `source/azdo-dsc-lcm.psd1` | Manifest: `source/Dsc.PipelineRunner.psd1` |
| Root module: `azdo-dsc-lcm.psm1` | Root module: `Dsc.PipelineRunner.psm1` |
| Command: `Invoke-AZDoLCM` | Command: `Invoke-DscPipelineRunner` |
| Command: `Resolve-AzDoDatumProject` | Command: `Resolve-DscDatumProject` |
| Rules directory: `LCM Rules\` | Rules directory: `Pipeline Rules\` |
| Config key: `LCMConfigSettings` | Config key: `PipelineRunnerSettings` |
| Config key: `AZDOLCMVersion` | Config key: `PipelineRunnerVersion` |

#### Migration Guide

##### 1. Update `Import-Module`

```powershell
# Before
Import-Module azdo-dsc-lcm

# After
Import-Module Dsc.PipelineRunner
```

##### 2. Update Command Calls

```powershell
# Before
Invoke-AZDoLCM -AzureDevopsOrganizationName "MyOrg" ...

# After
Invoke-DscPipelineRunner -AzureDevopsOrganizationName "MyOrg" ...
```

```powershell
# Before
Resolve-AzDoDatumProject -NodeName $node -AllNodes $allNodes

# After
Resolve-DscDatumProject -NodeName $node -AllNodes $allNodes
```

##### 3. Update `Datum.yml`

```yaml
# Before
LCMConfigSettings:
  ConfigurationVersion: 0.1
  AZDOLCMVersion: 0.1
  DSCResourceVersion: 2.0

# After
PipelineRunnerSettings:
  ConfigurationVersion: 0.1
  PipelineRunnerVersion: 0.1
  DSCResourceVersion: 2.0
```

##### 4. Rename Custom Rules Directory

If you have extended the module with custom rules, rename your local copy of `LCM Rules\` to `Pipeline Rules\`. The subdirectory structure (`Custom\`, `Format\`, `PreParse\`) remains unchanged.

#### Motivation

- **Decoupling**: The `AZDO` prefix falsely implied an exclusive dependency on Azure DevOps. The module works with any CI/CD platform.
- **Architectural accuracy**: `LCM` referred to the deprecated Windows DSC Local Configuration Manager (v2). This tool is an external orchestrator aligned with DSC v3's CLI-driven model, making `Runner` the technically correct term.
- **Ecosystem alignment**: The `Dsc.` prefix follows modern community conventions (e.g., `Dsc.ResourceKit`), improving discoverability in the PowerShell Gallery.
