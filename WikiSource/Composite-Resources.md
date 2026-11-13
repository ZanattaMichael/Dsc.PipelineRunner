# Composite Resources

A **composite resource** is a named, parameterised group of ordinary resources. You define it
once and use it from any layer of the configuration with a single `type: Composite/<Name>`
entry. When the configuration is compiled, each use (an **instance**) is replaced by the
resources in the definition (its **members**). The compiled per-node file, the runner, the
pipeline rules, the engines and the report only ever see ordinary resources.

Use one when the same handful of resources is declared over and over with only a few values
changing. Examples are "a project, its readers group and its default repositories", or "a
directory, the file in it and the service that reads it".

## At a glance

`Composites/StandardProject.yml` holds the definition:

```yaml
description: A project with its readers group.

parameters:
  ProjectName:                      # no defaultValue: the instance must set it
    description: The Azure DevOps project name.
  Visibility:
    defaultValue: private

resources:

  - name: Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      ProjectName: <composite=ProjectName>
      Visibility: <composite=Visibility>

  - name: Readers
    type: AzureDevOpsDscNative/AzDoProjectGroup
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      ProjectName: <composite=ProjectName>
      GroupName: <composite=ProjectName> Readers
```

An instance goes in any layer file, for example `Projects/Present/Magenta.yml`:

```yaml
resources:

  - name: Magenta
    type: Composite/StandardProject
    properties:
      ProjectName: Magenta
```

The compiled `Magenta.yml` contains:

```yaml
resources:

  - name: Magenta::Project
    type: AzureDevOpsDscNative/AzDoProject
    properties:
      ProjectName: Magenta
      Visibility: private

  - name: Magenta::Readers
    type: AzureDevOpsDscNative/AzDoProjectGroup
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Magenta::Project
    properties:
      ProjectName: Magenta
      GroupName: Magenta Readers
```

## Where definitions live

Put each definition in its own file directly under a `Composites/` folder at the root of the
configuration repository. The file name, without `.yml`, is the composite's name.

```
config/
├── Datum.yml
├── Composites/
│   ├── StandardProject.yml         # type: Composite/StandardProject
│   └── RepoSet.yml                 # type: Composite/RepoSet
├── Projects/
└── ...
```

You do not need to change `Datum.yml`. Datum creates one store per root folder, so the
definitions are available to the compile as soon as the folder exists.

Do **not** add `Composites` to `ResolutionPrecedence`. A definition is a template, not
configuration for a node. If it were in the precedence list, its `resources` would be merged
into every node as if they were real resources.

Only `<Name>.yml` files at the root of `Composites/` are definitions. A sub-folder, or a file
that does not contain a YAML mapping, is skipped with a warning, so you can keep drafts in
`Composites/Drafts/` without breaking the compile.

Composite names are matched without regard to case.

## The definition file

A definition has three top-level keys. Any other key is a compile error.

| Key | Required | Summary |
| --- | --- | --- |
| `description` | no | Free text for the reader. Ignored by the compile. |
| `parameters` | no | A map of parameter name to specification. |
| `resources` | yes | The member resources, as a list. It must contain at least one resource. |

### `parameters`

Each parameter is one of the following:

```yaml
parameters:

  ProjectName:                      # null: required, and the instance must set it

  Visibility:                       # a map with defaultValue: optional
    defaultValue: private
    description: Who can see the project.

  Owner:                            # a mapping with only a description: still required
    description: The owning team.

  Retries: 3                        # a scalar: shorthand for defaultValue: 3
```

`defaultValue` and `description` are the only keys a specification may have. A default may be
any YAML value, including a list or a map. To give a list as the default, put it under
`defaultValue:`. A bare list is ambiguous, so it is rejected.

### `resources`

Members are written exactly like ordinary resources: `name`, `type`, `properties`,
`dependsOn`, `notify`, `preCondition`, `postCondition`, execution scripts, `target`,
`resourceCredential` and so on. See [Resource Properties](Resource-Properties).

Two rules apply inside a definition:

- Member names must be unique within the definition. Their `type`/`name` pairs are what
  `dependsOn` and `overrides` refer to.
- A `dependsOn` or `notify` entry that names **another member of the same definition** uses the
  member's own name (`AzureDevOpsDscNative/AzDoProject/Project`). The compile rewrites it to
  the instance's name. An entry that names anything else is left exactly as written, so a member
  can depend on a resource outside the composite.

## Parameter tokens

`<composite=Name>` substitutes the value of parameter `Name`. It works in any value of a member:
properties, conditions, `dependsOn` entries, `target` fields and nested maps and lists. It does
not work in keys.

- **A value that is exactly one token** is replaced by the parameter's value, and the value
  keeps its type. A list stays a list, a map stays a map and a boolean stays a boolean.

  ```yaml
  properties:
    Members: <composite=Members>        # Members: [alice, bob] -> a real list
  ```

- **A token inside a longer string** is inserted as text.

  ```yaml
  properties:
    GroupName: <composite=ProjectName> Readers
    Path: C:\Sites\<composite=SiteName>\wwwroot
  ```

  A list or map cannot be inserted into a string. Doing so is a compile error that tells you to
  use the token as the whole value.

- **A token naming a parameter the definition does not declare** is a compile error, and the
  error lists the parameters that are declared.

Tokens are substituted at **compile** time, so the compiled file contains the final value. The
runner's own function language, such as `$(variables('X'))` and `$(parameters('Y'))`, is left
untouched and still runs at execution time as usual. You can pass one of those expressions as a
parameter value:

```yaml
  - name: Magenta
    type: Composite/StandardProject
    properties:
      ProjectName: $(variables('ProjectName'))
```

Datum's own handlers (`[x={ ... }=]`) are **not** evaluated inside a definition, because a
definition is never resolved through the hierarchy. Use a handler in the instance's
`properties` instead. The instance is resolved like any other resource, so the handler runs
before expansion.

## The instance

An instance is a resource entry whose `type` is `Composite/<Name>`. It may carry these keys:

| Key | Summary |
| --- | --- |
| `name` | Required. The instance name, which becomes the prefix of every member's name. |
| `type` | Required. Exactly `Composite/<Name>`. |
| `properties` | The parameter values. Every key must be a declared parameter. |
| `dependsOn` | Added to **every** member. |
| `notify` | Added to **every** member. |
| `preCondition` | Combined with each member's own `preCondition` using `-and`. |
| `condition` | Deprecated alias for `preCondition`, as on any resource. |
| `target` | Applied to every member that does not set its own. |
| `resourceCredential` | Applied to every member that does not set its own. |
| `overrides` | Per-member changes. See [Overrides](#overrides). |
| `description` | Free text for the reader. |

`postCondition`, `preExecutionScript` and `postExecutionScript` are **rejected** on an instance.
Each one describes how a single resource is evaluated, and a group has no single result to
check or single evaluation to wrap. Set them on the member in the definition, or on one instance
through `overrides`.

Any other key is a compile error that lists the supported keys.

### Naming

Each member is renamed `<instance>::<member>`. Its `type` is unchanged. The member `Project`
of the instance `Magenta` becomes `AzureDevOpsDscNative/AzDoProject/Magenta::Project`.

This means two instances of the same composite never collide, and every line of the report
shows the instance a resource came from.

### Inheritance

```yaml
  - name: Magenta
    type: Composite/StandardProject
    dependsOn:
      - AzureDevOpsDscNative/AzDoOrganization/Contoso
    preCondition: equals (variables 'Environment') 'Prod'
    target:
      action: WinRM
      computerName: build01.contoso.com
    properties:
      ProjectName: Magenta
```

- `dependsOn` and `notify`: each member keeps its own entries, and the instance's entries are
  added after them.
- `preCondition`: a member with no `preCondition` of its own gets the instance's. A member that
  already has one gets `(<instance>) -and (<member>)`, so the member runs only when **both** are
  true. When a member uses the deprecated `condition` key, it is folded into the combined
  `preCondition`.
- `target` and `resourceCredential`: a member that sets its own keeps it. Every other member
  gets the instance's value.

### Overrides

`overrides` is for a difference that only one instance needs and that the definition has no
parameter for. It is keyed by **member name**, with case ignored:

```yaml
  - name: Magenta
    type: Composite/StandardProject
    properties:
      ProjectName: Magenta
    overrides:
      Readers:
        properties:
          GroupName: Magenta Viewers      # merged: other properties are kept
        postCondition: result().InDesiredState
```

- `properties` are **merged** key by key. Keys you name replace the member's values, and every
  other property is kept.
- Any other key, such as `dependsOn`, `postCondition` or `target`, **replaces** the member's own
  value.
- `name` and `type` cannot be overridden.
- Naming a member that the composite does not have is a compile error that lists its members.

Overrides are applied after tokens are substituted and before instance inheritance, so an
overridden `preCondition` is still combined with the instance's.

## Referring to a composite

Refer to an instance like any other resource: `Composite/<Name>/<instance>`.

```yaml
  - name: Audit
    type: Custom/AuditLog
    dependsOn:
      - Composite/StandardProject/Magenta
```

A `dependsOn` or `notify` entry that names an instance is replaced by the names of **all** of
its members. `Audit` therefore runs after every resource in `Magenta`, and a `notify` on an
instance refreshes every member.

You can also refer to a single member directly by its expanded name:
`AzureDevOpsDscNative/AzDoProject/Magenta::Project`.

A reference in the `Composite/` form that matches no instance in the node is a compile error. A
typo is not silently ignored.

`using()` and `reference()` read single resources. Use the member's expanded name, for example
`reference('Magenta::Project')`.

## Hierarchy and merging

An instance is an ordinary entry in `resources` until the hierarchy is resolved. It merges and
overrides by `name` exactly like any other resource:

```yaml
# Baseline/Common.yml - every node gets a Shared project.
resources:
  - name: Shared
    type: Composite/StandardProject
    properties:
      ProjectName: Shared
```

```yaml
# Projects/Present/Magenta.yml - this node changes one parameter of it.
resources:
  - name: Shared
    properties:
      Visibility: public
```

Expansion happens **after** the merge, so `Magenta` gets one `Shared` instance with
`ProjectName: Shared` and `Visibility: public`. Its members stay in the position where the
instance ended up in the merged list, in the order the definition lists them.

## Nesting

A member can itself be a composite instance:

```yaml
# Composites/RepoSet.yml
parameters:
  Prefix:
resources:
  - name: Main
    type: AzureDevOpsDscNative/AzDoGitRepository
    properties:
      RepositoryName: <composite=Prefix>-main
  - name: Docs
    type: AzureDevOpsDscNative/AzDoGitRepository
    properties:
      RepositoryName: <composite=Prefix>-docs
```

```yaml
# Composites/StandardProject.yml (extract)
resources:
  - name: Repos
    type: Composite/RepoSet
    dependsOn:
      - AzureDevOpsDscNative/AzDoProject/Project
    properties:
      Prefix: <composite=ProjectName>
```

Names nest (`Magenta::Repos::Main`), inherited settings flow down through each level, and
`Composite/RepoSet/Magenta::Repos` is itself a valid reference.

A composite that contains itself, directly or through another composite, is a compile error that
shows the cycle (`A -> B -> A`). So is nesting more than 10 levels deep.

## What fails, and when

Every mistake fails the **compile** and names the instance involved. Nothing is written for that
node, so a broken composite never reaches a target.

| Mistake | Message contains |
| --- | --- |
| No such composite | `refers to composite 'X', which is not defined. Defined composites: ...` |
| A required parameter is not set | `does not set the required parameter(s) 'X'` |
| A property the composite does not declare | `sets 'X', which composite 'Y' does not declare` |
| A token for an undeclared parameter | `uses the token '<composite=X>', but the composite declares no parameter named 'X'` |
| A list or map inserted into a string | `embeds '<composite=X>' inside a longer string` |
| `postCondition` or an execution script on an instance | `which is not supported on a composite instance` |
| An override for a member that does not exist | `overrides 'X', which is not a resource of composite 'Y'` |
| A reference to an instance that does not exist | `which is not a composite instance in this configuration` |
| A composite that contains itself | `is recursive: A -> B -> A` |
| Two resources end up with the same type and name | `produced the resource [...] more than once` |

At run time, the [`Test-CompositeResourcesExpanded`](Pipeline-Rules#test-compositeresourcesexpanded)
pre-parse rule stops a file that still contains a `Composite/` type. That can happen with a
hand-written file, or one compiled by an older module version. The run stops before any
resource is evaluated, instead of failing later on a resource that does not exist.

## Tips

- Inspect the compiled per-node YAML to see exactly what a composite produced. See
  [Troubleshooting](Troubleshooting).
- Give each parameter a `description`. The definition file is the only documentation a composite
  has.
- Prefer a parameter over `overrides` for any difference that more than one instance needs.
- Composite members are validated by the pre-parse rules like any hand-written resource, so a
  wrong property name in a definition is reported with the member's expanded name.
