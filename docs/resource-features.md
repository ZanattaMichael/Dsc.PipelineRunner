# Resource features

Every resource in a configuration can carry the keys below, whatever its DSC type. This is the full
reference; the [README](../README.md#resource-features) has the one-line summary of each.

The pipeline runner provides a set of features applicable to all Desired State Configuration (DSC) resources, enhancing their flexibility and control. These features include:

- __preCondition__ (formerly `condition`, which is still accepted as a deprecated alias):
  This feature allows conditional execution of resources. The expression is evaluated as a
  PowerShell predicate before the resource runs. If it evaluates to `$true`, the resource
  executes; if it evaluates to `$false`, the resource is skipped. This is useful for
  dynamically controlling resource execution based on specific criteria.

    __Example:__

    ```yaml
    - name: CON Board Administrators
      preCondition: equals (variables 'ProjectWorkBoardsStatus') 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
    ```

    A preCondition may also call the function-language accessors — an explicit allow-list
    covering lookups (`parameters()`, `variables()`, `reference()`, `using()`), run context
    (`nodeName()`, `configurationFile()`), logic (`equals()`, `not()`), strings and collections
    (`concat()`, `empty()`, `coalesce()`, `toLower()`, `toUpper()`, `startsWith()`,
    `contains()`) and arithmetic (`add()`, `sub()`, `mul()`, `div()`, `mod()`, `min()`,
    `max()`, `int()`, `float()`). Any other command invocation, a variable assignment, or a
    method call is still rejected. There is deliberately no `secret()` accessor: a condition is
    recorded verbatim in the audit record and in every SKIP message it produces, so secrets
    reach a resource through its `resourceCredential` block instead. Unlike a bare
    comparison, `parameters()`/`reference()` throw on a missing key or reference rather than
    silently resolving to `$null`, so a typo fails just that resource instead of skipping it
    unnoticed. These are ordinary PowerShell commands, so multi-argument calls take
    space-separated arguments — `equals (parameters 'Environment') 'Prod'`, not
    `equals(parameters('Environment'), 'Prod')` — the comma-in-parens form parses as a single
    array argument and silently mis-binds:

    ```yaml
    - name: CON Board Administrators
      preCondition: (parameters('Environment')) -eq 'Prod' -and (variables('ProjectWorkBoardsStatus')) -eq 'enabled'
      type: AzureDevOpsDscNative/AzDoProjectGroup
    ```

- __postCondition__: evaluated after the resource's `Test`/`Set`, before `postExecutionScript`.
  A `$false` result marks the resource `FAIL` regardless of what the engine itself reported —
  it asserts something about the *outcome*, where `preCondition` decides whether the resource
  runs at all. It is parsed by the same predicate allow-list as `preCondition`, plus two
  accessors reserved for `postCondition` only: `result()` (the resource's normalized engine
  result — `InDesiredState` / `RebootRequired` / `Message` / `Raw`) and `stopProcessing()` (see
  below).

    __Example:__

    ```yaml
    - name: Print Spooler
      type: PSDscResources/Service
      postCondition: result().InDesiredState -or (not (equals (parameters 'Environment') 'Prod'))
    ```

- __preExecutionScript__ / __postExecutionScript__: run arbitrary PowerShell immediately
  before, or after, the resource's `Test`/`Set` evaluation. Useful for preparing state a
  resource depends on, or for clean-up/state-change logic afterwards. Unlike a condition,
  these are not restricted to a predicate — see `AllowExecutionScripts` below, which gates
  their use. Unlike `properties`/`preCondition`/`postCondition`, these are not parsed through
  `ExpandString` or `Assert-SafeConditionExpression` — they run as plain PowerShell, with
  direct read access to the script-scope variable `Set-Variables` already created for each
  Datum variable, so there is no need to go through the `variables()` accessor here.

    __Example:__

    ```yaml
    - name: Project
      type: AzureDevOpsDscNative/AzDoProject
      postExecutionScript: if ($Project_Ensure -eq 'Absent') { Stop-TaskProcessing }
    ```

- __AllowExecutionScripts__ (`PipelineRunnerSettings.AllowExecutionScripts`, default `false`):
  a configuration-level gate on `preExecutionScript`/`postExecutionScript`. Because an
  execution script runs unrestricted code in the runner's own process, a configuration must
  opt in explicitly before any resource may carry one; otherwise the run fails at PreParse
  time, naming every offending resource in one pass, before any resource is evaluated.

    ```yaml
    PipelineRunnerSettings:
      AllowExecutionScripts: true
    ```

- __resourceCredential__: a declarative way to inject a resolved credential into a resource's
  own properties (for example a resource's `-Credential` parameter) without the credential
  ever appearing in the configuration file. It resolves through the `Credential` action hook
  (see below) and, unlike `preExecutionScript`/`postExecutionScript`, works even when
  `AllowExecutionScripts` is off — it is declarative, not a script.

    __Example:__

    ```yaml
    - name: SQL Login
      type: SqlServerDsc/SqlLogin
      properties:
        InstanceName: MSSQLSERVER
      resourceCredential:
        action: SecretManagement   # a file in Actions/Credential/ (default: Environment)
        name: sql-service-account  # the secret name
        propertyName: Credential   # the properties key the resolved PSCredential is written to (default: Credential)
    ```

- __dependsOn__: This feature establishes a dependency chain, ensuring that resources are executed in a specific order. By defining dependencies, you can create a structured sequence of resource execution, where a resource will only run after its dependencies have successfully completed. This is particularly useful in complex configurations where the order of operations is critical.

    __Example:__

    ```yaml
    - name: Default Git Configuration Permissions
      type: AzureDevOpsDscNative/AzDoGitPermission
      dependsOn:
        - AzureDevOpsDscNative/AzDoProject/Project
        - AzureDevOpsDscNative/AzDoProjectGroup/CON Readers
        - AzureDevOpsDscNative/AzDoProjectGroup/CON Board Administrators
    ```

- __notify__ / __using()__: a Puppet/Chef-style relationship between two resources, combining an
  ordering guarantee with a data link. `notify` is a string or array of strings on the
  *notifying* resource, each naming a target resource by the same `Type/Name` identity
  `dependsOn` uses. It means two things:

    1. **Ordering** — the notifying resource is guaranteed to run before every resource it
       notifies. This is implemented as an implicit `dependsOn` on the target (folded in before
       the dependency sort runs), so a `notify` cycle is rejected exactly the way a `dependsOn`
       cycle already is.
    2. **Forced re-run** — in `Set` mode, if the notifying resource's own `Test()` reported it
       was *not* in the desired state, and its `Set()` then completed successfully, every
       resource it notifies is forced to re-run its own `Set()` this pass, even if that
       resource's `Test()` reports it is already in the desired state. In `Test` mode there is
       no `Set()` to force, so `notify` only contributes its ordering guarantee.

    A resource named in another resource's `notify` list may read that resource's `Get()`
    output with the `using('Type/Name')` accessor, addressed by the same full `Type/Name`
    identity (not the bare `name` that `reference()` uses). Unlike `reference()`, `using()` is
    gated: it only succeeds when the resource being read has actually declared the calling
    resource as a `notify` target — a data dependency is always paired with the ordering
    guarantee that makes it safe to read. `using()` is callable from anywhere within the
    notified resource's own expressions (typically `properties`), and, like `reference()`,
    ordinary PowerShell property-path chaining works on the result.

    `using` is a reserved PowerShell word (the `using module`/`using namespace` directive) when
    it is the first token of a statement, so `using(...)` must always sit inside an outer
    expression — never as a bare, unwrapped call. A property value's `$(...)` already provides
    that wrapping, so the example below (`$((using '...').Id)`) is the pattern to follow; a
    bare `using 'Type/Name'` with nothing enclosing it fails to parse.

    Both halves are **scoped to a single configuration file**. The runner processes one compiled
    configuration at a time and resets its notify state per file, so a `notify` target must be a
    resource declared in the same file, and `using()` cannot read a resource from another file
    (it throws the same "has no `notify` declaration, or does not exist" error as an undeclared
    read). A genuine change in one file never forces a `Set()` in another. This matches
    `dependsOn`, which is file-scoped for the same reason — see
    [docs/notify-and-using.md](notify-and-using.md) for why the boundary exists.

    __Example:__

    ```yaml
    resources:
      - name: Project
        type: AzureDevOpsDscNative/AzDoProject
        properties:
          ProjectName: Magenta
        notify:
          - AzureDevOpsDscNative/AzDoGitRepository/Default Repository

      - name: Default Repository
        type: AzureDevOpsDscNative/AzDoGitRepository
        properties:
          # Only readable here because 'Project' names this resource in its own notify list.
          ProjectId: $((using 'AzureDevOpsDscNative/AzDoProject/Project').Id)
    ```

- __parameter tokens__: A resource property whose value is exactly `<params=Name>` is replaced
  by the value of that pipeline parameter, with its type intact — a number stays a number, a
  hashtable stays a hashtable. Parameters resolve first, before string interpolation, so a
  parameter value that itself contains `$(...)` or a `$variable` reference still expands.
  Referencing a parameter that is not declared fails that resource and records it in the run
  report; it does not silently resolve to `$null`.

    The same substitution works inside a list, and `parameters('Name')` reads a parameter
    from a `condition` or a `postExecutionScript`.

    Values come from the configuration's own `parameters` section and nowhere else — each
    parameter's `defaultValue` is the value, and there is no invocation-time override on
    `Invoke-DscRunner`. A parameter declared *without* a `defaultValue` has no value to
    resolve to, so it is ignored with a warning and referencing it fails exactly as an
    undeclared name does. Give every parameter a `defaultValue`; an empty string is a
    legitimate one, and resolves to `''` rather than failing.

    __Example:__

    ```yaml
    parameters:
      ServiceName:
        defaultValue: Spooler
      RetryCount:
        defaultValue: 3

    resources:
      - name: Print Spooler
        type: PSDscResources/Service
        properties:
          Name: <params=ServiceName>
          RetryCount: <params=RetryCount>
    ```

These features collectively enhance the robustness and adaptability of DSC resources managed by the pipeline runner, allowing for more precise and context-sensitive configuration management.
