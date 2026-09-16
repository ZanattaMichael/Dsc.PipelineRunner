# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

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

- **The WinRM remoting suite now has a listener to connect to.** The self-hosted workflow ran
  `WinRMTarget.Integration.tests.ps1` but nothing configured a WSMan listener on the runner, so
  `Get-WinRMSkipReason` reported `Test-WSMan` failing and five of the six tests skipped with a
  warning on a green job - the coverage the suite exists to provide silently did not happen. A new
  `scripts/Enable-SelfHostedWinRM.ps1`, wired in as the `Ensure WinRM is enabled` step before the
  suite, configures one. It is deliberately conservative about a long-lived runner: it probes first
  and makes no changes when the listener already answers, appends this computer to `TrustedHosts`
  rather than replacing the list (and only when the runner is not domain-joined, where NTLM needs
  it), reports a non-elevated runner process as a warning instead of an access error, and always
  exits 0 so an environment problem on the runner cannot turn an unrelated pull request red. The
  outcome - enabled, already enabled, or not enabled and why - is written to the job's step summary
  so a green run cannot hide a skipped suite.

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
