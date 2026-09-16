# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

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
