# `notify` and `using()`

A Puppet/Chef-style relationship between two resources: `notify` on the notifying resource
pairs an ordering guarantee with a gated data link, and `using()` is the accessor that reads
across that link.

## `notify`

A resource-level property, a string or array of strings, each in the same `Type/Name` identity
format `dependsOn` already uses:

```yaml
- name: Project
  type: AzureDevOpsDscNative/AzDoProject
  properties:
    ProjectName: Magenta
  notify:
    - AzureDevOpsDscNative/AzDoGitRepository/Default Repository
```

`notify` means two things:

1. **Ordering.** The notifying resource must run before every resource it notifies.
   `Pipeline Rules/Custom/Expand-NotifyDependsOn.ps1` runs before the existing
   `Sort-DependsOn.ps1` topological sort and folds each `notify` entry into an implicit
   `DependsOn` on the target resource, so the same sort — and the same cycle/self-reference/
   missing-target validation it already performs for `dependsOn` — governs `notify` too. A
   resource that notifies itself, or notifies a resource that does not exist in the
   configuration, fails fast at this step with the same style of error `Sort-DependsOn` already
   produces for a bad `dependsOn`.

2. **Forced re-run (`Set` mode only).** If the notifying resource's own `Test()` reported it was
   *not* in the desired state, and its `Set()` then completed successfully, every resource it
   notifies is forced to run `Set()` this pass, even if that resource's own `Test()` reports it
   is already in the desired state. This mirrors Puppet/Chef `notify`: a genuine change upstream
   forces a downstream refresh. A forced re-run that was itself a no-op (the resource's `Set()`
   finds nothing to change) does **not** by itself propagate further — only a resource whose own
   `Test()` originally reported drift propagates a forced re-run to what it, in turn, notifies.
   In `Test` mode there is no `Set()` to force, so `notify` only contributes its ordering
   guarantee.

## `using()`

A function-language accessor, usable anywhere in a resource's own expressions (typically
`properties`), that reads another resource's `Get()` output — the same raw object `reference()`
exposes — addressed by the source resource's full `Type/Name` identity:

```yaml
- name: Default Repository
  type: AzureDevOpsDscNative/AzDoGitRepository
  properties:
    ProjectId: $((using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
```

Unlike `reference()`, `using()` is gated: `using('X')` only succeeds when `X`'s own `notify`
list names the calling resource as a target. Reading a resource that has not declared the
caller via `notify`, or a resource that has not produced `Get()` output yet, throws a
descriptive error rather than silently resolving to `$null` — the same fail-loud precedent
`parameters()` already sets for a similarly load-bearing accessor. This keeps the data link and
the ordering guarantee paired: a resource can only be read once `notify` has already guaranteed
it ran first.

`using` is a reserved word in PowerShell (the `using module`/`using namespace`/`using assembly`
directive) whenever it is the first token of a statement or script block, so `using(...)` must
always be nested inside an outer expression — `$((using 'Type/Name').Property)`, exactly as
`ExpandString`'s `$(...)` wrapping already requires for a property value. A bare, unwrapped
`using 'Type/Name'` with nothing enclosing it is a parse error, not a runtime error.

`using()` is not added to `Assert-SafeConditionExpression`'s allow-list — it is designed for
`properties` expansion (`Expand-HashTable`'s `ExpandString`, which has no such gate), the same
place `reference()`/`variables()`/`parameters()` are used today, not for `preCondition`/
`postCondition`.

## Scope: one configuration file

`notify` and `using()` are **intra-file**. Both the relationship and the data it carries live
entirely within a single compiled configuration file, and neither crosses into the next one.

`Invoke-DscRunner` enumerates the compiled `*.yml` configurations and calls `Start-DscRunner`
once per file. `Start-DscRunner` resets all four pieces of notify state at the top of every
call, alongside `$script:StopTaskProcessing`:

```powershell
$script:notifyDeclarations   = @{}
$script:resourceOutputs      = @{}
$script:pendingNotifyRefresh = @{}
$script:currentResourceKey   = $null
```

Two consequences follow, both by design:

- **`using()` cannot read across files.** A resource in file B calling
  `using('Type/Name')` on a resource declared in file A hits the first guard in `using.ps1`
  and throws *"has no `notify` declaration, or does not exist"* — file B's declaration map is
  empty, so from its point of view the source resource does not exist. The error names the
  gate rather than the file boundary, which is worth knowing when diagnosing it.
- **A forced refresh cannot cross files.** A genuine change in file A never forces a `Set()`
  on a resource in file B, even if file A names it in a `notify` list. The name is unresolvable
  at expansion time in file A too: `Expand-NotifyDependsOn` rejects a `notify` target that is
  not present in the same configuration, the same way `Sort-DependsOn` rejects an unresolvable
  `dependsOn`.

The reset is what keeps one file's run from leaking into the next — compiled files are
per-node, and `$resourceOutputs` in particular holds live state read from real infrastructure,
which must not be attributed to a different node. Widening the scope is therefore not a matter
of deleting the reset: the outputs would need to be keyed per node and their lifetime raised to
the `Invoke-DscRunner` loop, with an explicit answer for what a downstream file should do when
the file it depends on failed or stopped early. That is tracked separately; for now, a
`notify`/`using()` relationship must be expressed between resources in the same file.

`dependsOn` has the same file-scoped boundary, for the same reason — `notify` inherits it by
being expanded into `dependsOn`.

## Implementation

- `Pipeline Rules/Custom/Expand-NotifyDependsOn.ps1` — expands `notify` into implicit
  `DependsOn` entries, invoked via `Invoke-CustomTask` immediately before `Sort-DependsOn`.
- `source/Private/Runner/using.ps1` — the `using()` accessor.
- `source/Dsc.PipelineRunner.psm1` — new module-scope state: `$notifyDeclarations` (source key
  → notify targets, gates `using()`), `$resourceOutputs` (source key → `Get()` output, what
  `using()` returns), `$pendingNotifyRefresh` (targets forced to re-run `Set()` this pass), and
  `$currentResourceKey` (identifies the calling resource to `using()`).
- `source/Private/Runner/Start-DscRunner.ps1` — resets the state above per run; expands
  `notify` and builds the declaration map before sorting; sets `$currentResourceKey` per
  resource before property expansion; forces `Set()` for a resource in
  `$pendingNotifyRefresh`; propagates a forced refresh to `notify` targets after a genuine,
  successful change; and records each resource's `Get()` output into `$resourceOutputs` keyed
  by its full identity.
