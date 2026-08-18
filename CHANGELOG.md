# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Release workflow (`.github/workflows/release.yml`) that builds, tests and validates the
  module, then publishes to the PowerShell Gallery and creates a GitHub release. Supports a
  dry run so a release can be rehearsed without publishing.
- Preflight validation in the release workflow: the built manifest is checked with
  `Test-ModuleManifest`, exported commands are asserted to be non-empty, the `LCM Rules`
  directory is asserted to be present in the built artefact, and every entry in
  `RequiredModules` is confirmed to be resolvable on the PowerShell Gallery before publishing.
- This changelog.

### Changed

- `Copy_LCM_Rules` build task now resolves paths with `Join-Path` instead of hardcoded
  backslashes, selects the versioned output directory explicitly rather than enumerating all
  children, and verifies the copy succeeded. Previously the task could not locate its source
  on Linux or macOS, and a partial or missing copy produced a module that failed at runtime
  rather than at build time.
- `publish` build workflow no longer runs `Publish_GitHub_Wiki_Content`. That task comes from
  `DscResource.DocGenerator`, which is not a declared dependency, and it publishes content
  that no task in this build generates. See issue #37.

### Fixed

- Module manifest exported its public commands via `CmdletsToExport` with an empty
  `FunctionsToExport`. These are script functions, not compiled cmdlets, so importing the
  manifest exported no commands at all. The two lists have been swapped.
- Module manifest set `VariablesToExport = '*'`, publishing the internal `$references`,
  `$variables` and `$parameters` LCM state into the caller's session. Now `@()`.
- `LicenseUri`, `ProjectUri` and `IconUri` in the module manifest pointed at a different
  repository (`AzDoDSCDatum`) and returned 404. `IconUri` now uses a raw content URL so it
  resolves to the image rather than an HTML page.
- Module manifest declared `ClrVersion`, which applies only to PowerShell Desktop and is
  meaningless alongside the PowerShell 7.0 requirement. Removed, and
  `CompatiblePSEditions = @('Core')` declared instead.

[Unreleased]: https://github.com/ZanattaMichael/AzDO-DSC-LCM/compare/main...HEAD
