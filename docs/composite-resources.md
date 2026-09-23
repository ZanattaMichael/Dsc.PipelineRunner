# Composite resources: design

The user-facing reference is the
[Composite Resources](https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki/Composite-Resources)
wiki page (`WikiSource/Composite-Resources.md`). This document records **why** the feature is
built the way it is. The research that preceded it is
[issue #65](https://github.com/ZanattaMichael/Dsc.PipelineRunner/issues/65).

## The problem

A configuration often declares the same few resources again and again with only a few values
changed. One example is a project, its groups and its default repositories. Without a way to
name that group, every copy has to be written and maintained by hand, and the copies drift
apart.

## The decision: expand at compile time, as data

Composite definitions are plain YAML in `Composites/<Name>.yml`. An instance
(`type: Composite/<Name>`) is expanded into its member resources inside
`Resolve-DscDatumProject`. That happens after `Resolve-Datum` has merged the hierarchy and
before the per-node file is written.

### Why not let Datum do it

Datum has no concept of a template.

- **A handler** (`[x={ ... }=]`) runs on one value while that value is being resolved. It can
  replace a value, but it cannot turn one list entry into several, rename them, or rewrite
  references elsewhere in the list.
- **`ResolutionPrecedence`** merges layers. It does not instantiate them. A `Composites` entry
  in the precedence list would merge the definition's resources into every node once, with no
  parameters and no names specific to an instance.
- **`UniqueKeyValTuples`** merges entries that share a `name`. That is how an instance is
  overridden, but it is not a way to create more entries.

So Datum is used for what it does well. It finds the definitions, because
`New-DatumStructure` exposes every root folder as a store, which makes
`$Datum.Composites.<Name>` available without any `Datum.yml` change. It also resolves the
instance like any other resource. The expansion itself is ordinary PowerShell over the
resolved list.

### Why not expand at run time

If the runner expanded composites instead, every consumer of the compiled file would need to
understand them: the pipeline rules, `Sort-DependsOn`, `Expand-NotifyDependsOn`, `reference()`,
`using()` and the report. Expanding before the file is written means:

- **Nothing downstream changes.** Members are ordinary resources. They are validated by
  `Test-ResourcesForIncorrectProperties`, ordered by `Sort-DependsOn`, evaluated by any engine
  and reported under their own names.
- **The compiled file is the truth.** "What will this run do?" is still answered by reading one
  flat YAML file. This is the debugging workflow the wiki already recommends.
- **Errors fail early.** A missing parameter or an unknown composite fails the compile, before
  anything is sent to a target.

`Test-CompositeResourcesExpanded` is the only run-time part. It is a pre-parse rule that stops
a file still containing a `Composite/` type, such as a hand-written file or one compiled by an
older module. Without it, that file would fail later as a resource that is not found.

### Why definitions are not in the hierarchy

Definitions are templates, not configuration. If they took part in precedence, a node layer
could accidentally override part of a definition for every instance on that node, with no
visible link between the two. The deliberate way to vary one instance is the instance's own
`properties` and `overrides`. Keeping definitions out of the precedence list also means one
definition is shared by every node.

## Semantics, and the reasons for them

| Choice | Reason |
| --- | --- |
| Members are renamed `<instance>::<member>` | Two instances of one composite must not collide on the `Type/Name` identity that `dependsOn`, `notify`, the report and `UniqueKeyValTuples` all key on. `::` cannot appear in a Datum precedence path and reads as scoping. |
| The type is kept unchanged | The type is what the engine invokes and what the pre-parse rules validate. |
| `<composite=Name>` tokens | This is the same shape as the runner's existing `<params=Name>`, and distinct from it so neither can be mistaken for the other. A value that is only a token keeps its YAML type, so lists and booleans pass through intact. |
| An undeclared token, or an undeclared instance property, is an error | A typo must not produce a resource with a literal `<composite=Nmae>` in it, or silently drop a value. |
| The instance's `dependsOn`/`notify` are added to every member | The group as a whole waits for, or notifies, what the instance names. |
| The instance's `preCondition` is combined with each member's using `-and` | Gating a group means gating every member. It never un-gates a member that has its own condition. |
| `target`/`resourceCredential` apply to members that have none | One place to say where the group runs, while a member can still opt out. |
| `postCondition` and execution scripts are rejected on an instance | Each describes the evaluation of one resource. A group has no single `result()`, and running a script once per member is rarely what the author meant. They remain available on members and through `overrides`. |
| `overrides` merges `properties` and replaces other keys | This matches how a resource is overridden through the hierarchy, and it is the escape hatch for differences that apply to one instance only. |
| A reference to `Composite/<Name>/<instance>` means every member | Ordering against a group works like ordering against one resource. A reference that matches no instance is an error, as a bad `dependsOn` is elsewhere. |
| Nesting is supported, with a depth limit of 10 and cycle detection | Composites compose. A self-referencing definition must fail clearly rather than recurse forever. |
| Definitions are deep-copied before any change | Datum caches each file's parsed data, so the same definition objects are shared by every instance and every node. |
| The whole feature is a no-op when no resource is a composite | Existing configurations compile to the same resources, because the input objects are passed through untouched. The only visible difference is that a node that resolves exactly one resource now writes it as a one-item list, which the runner already accepted. |

## Code map

| File | Role |
| --- | --- |
| `source/Private/Configuration/Get-CompositeDefinition.ps1` | Reads `$Datum.Composites`. It accepts a Datum FileProvider or a plain dictionary, and skips anything that is not a mapping, with a warning. |
| `source/Private/Configuration/Expand-CompositeResource.ps1` | Performs the expansion: binding, tokens, renaming, overrides, inheritance, nesting and reference rewriting. |
| `source/Public/Resolve-DscDatumProject.ps1` | Calls the two functions above after `Resolve-Datum`, and before variables are processed and the file is written. |
| `Pipeline Rules/PreParse/Test-CompositeResourcesExpanded.ps1` | The run-time safety net. |

## Tests

- `Tests/.../Private/Configuration/Expand-CompositeResource.tests.ps1` covers every rule in the
  table above, and every error, against hand-built dictionaries.
- `Tests/.../Private/Configuration/Get-CompositeDefinition.tests.ps1` covers store shapes
  (dictionary, FileProvider-like object, sub-folders, missing store).
- `Tests/.../Private/Configuration/Resolve-DscDatumProject.tests.ps1` covers the wiring: the
  expanded output is what gets written, and an invalid instance writes nothing.
- `Tests/PipelineRunner/Rules/Test-CompositeResourcesExpanded.tests.ps1` covers the pre-parse
  rule.
- `Tests/.../Integration/CompositeResources.Integration.tests.ps1` (tag `HostedIntegration`)
  runs a real `New-DatumStructure` compile of a configuration tree that has a `Composites/`
  folder, a baseline instance overridden by a node, a nested composite and a reference to an
  instance. It then runs a real `Start-DscRunner` pass over the result with the real ordering
  rules.

## Not in scope

- **Composites across nodes.** A composite expands within one compiled file. The
  [one-file scope](https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki/Configuration-Repository-Layout#one-file-is-one-scope)
  is unchanged.
- **Outputs from a composite.** A composite has no result of its own. Read a member with
  `reference()`/`using()` by its expanded name.
- **Conditional members inside a definition.** Use a `preCondition` on the member, evaluated at
  run time, perhaps built from a parameter token.
