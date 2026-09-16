# Lifecycle scripting extensions and reboot handling — plan

Two related follow-on design questions against the resource lifecycle described in
`Start-DscRunner.ps1` and the function language covered in
[`docs/dsc-v3-config-functions.md`](./dsc-v3-config-functions.md):

1. Broaden the runner's own function language (`parameters()`, `variables()`, `reference()`,
   `equals()`, `not()`) to more of the lifecycle — rename `condition` to `preCondition`, add a
   `postCondition`, add a symmetrical `preExecutionScript`, and add `stopProcessing()` as a
   callable function — with `postExecutionScript`/`preExecutionScript` staying the deliberate
   exception (full imperative script, not the constrained function language).
2. A plan for "wait until a reboot has completed, then continue" for configurations that target
   computers — genuinely open, because the runner has no remote-execution story today, which
   changes what "wait" can mean.

Both have since shipped, so this document is kept as the design record rather than as a current
description of the code. The first landed as designed: `preCondition`/`postCondition`/
`preExecutionScript`, plus the `result()` and `stopProcessing()` accessors. The second landed in a
simpler form than §3 plans below — fail-and-stop, or `PipelineRunnerSettings.Reboot: Ignore`, for
local targets rather than §3.3's checkpoint/resume, and an in-process `Restart-Computer -Wait` for
remote targets along the lines of §3.4, now that remoting support exists. Read
`Start-DscRunner.ps1` and `README.md` for what the runner does today; the line references below
point at the code as it stood when this was written.

## 1. Current lifecycle shape (baseline)

From `Start-DscRunner.ps1`, per resource, in order:

1. `condition` — a predicate. Parsed as PowerShell, gated by `Assert-SafeConditionExpression`,
   which rejects any `CommandAst` (command invocation), `AssignmentStatementAst`, or
   `InvokeMemberExpressionAst` (`Assert-SafeConditionExpression.ps1`). Because it forbids **all**
   command invocations, today's real condition usage is limited to bare comparisons —
   `condition: $ProjectWorkBoardsStatus -eq 'enabled'`
   (`Example Configuration/ProjectPolicies/ProjectGroups.yml:24`) — **not** the function-language
   style (`equals(...)`, `parameters(...)`) documented for property expansion, because
   `parameters('Name')` parses as a `CommandAst` and would be rejected outright. That's the gap
   §2 closes: the function language exists, but it's unusable from `condition` today.
2. `properties` resolution (`Expand-Parameters` → `Expand-HashTable`) — this is where
   `parameters()`/`variables()`/`reference()`/`equals()`/`not()` are actually usable today, since
   `ExpandString` has no safety gate.
3. Engine `Test` (`Invoke-EngineAction -Method Test`).
4. Engine `Set` (if not in desired state and `Mode -eq 'Set'`).
5. `postExecutionScript` — a `[scriptblock]`, invoked with `&` (child scope), completely
   unrestricted: it may call commands, including `Stop-TaskProcessing`
   (`Start-DscRunner.ps1:353-363`).
6. Engine `Get`, result stored into `$references`.

`Stop-TaskProcessing` is a public cmdlet, callable only from `postExecutionScript` today (its own
call-stack guard requires `Start-DscRunner` to be an ancestor frame, but nothing currently stops
it being wired into a condition — except that a condition can't invoke *any* command, `condition`
included, so in practice it's `postExecutionScript`-only).

## 2. Extending the function language into conditions

### 2.1 Rename `condition` → `preCondition`

Straightforward rename, `condition` kept as a back-compat alias (both read into the same
evaluation path in `Start-DscRunner`, with a one-time deprecation `Write-Warning` when the old key
is seen — same pattern as `AZDODSC_CACHE_DIRECTORY` in `Resolve-CacheDirectory.ps1`). No other
file in the repo reads `condition` (`Sort-DependsOn.ps1`, `Invoke-FormatTasks.ps1`,
`Test-CircularReferences.ps1` don't touch it), so this is contained entirely to
`Start-DscRunner.ps1`'s condition-evaluation block. Semantics are unchanged: evaluated before
`Test`; `$false` skips (`SKIP`) the resource and moves to the next.

### 2.2 Add `postCondition`

A second predicate, evaluated **after** `Test`/`Set` resolve for this resource but **before**
`postExecutionScript` runs (so `postExecutionScript` can still see/react to whatever
`postCondition` decided). Unlike `preCondition`, a `postCondition` cannot skip the resource — it
already ran — so its effect is: a `$false` result marks the resource `FAIL` in the report
regardless of what the engine reported (a post-hoc verification gate, e.g. "the engine says this
succeeded, but does the *combination* of this resource's outcome and an earlier resource's
`reference()` output actually make sense"). This is genuinely new expressive power — nothing
today lets a condition read *this resource's own* engine result.

To make that useful, the function language needs one more read-only accessor:

- **`result()`** — with no argument, returns the current resource's `[DscMethodResult]` from the
  most recent `Test`/`Set` call (so `postCondition` can write
  `not (equals (result().InDesiredState) $true)` or, once §2.3 lands,
  `$(result().RebootRequired)`). Scoped to `postCondition` only — `preCondition` runs before any
  engine call exists for this resource, so `result()` there is a defined error ("no result yet"),
  not `$null`, to avoid a silently-always-false condition.

### 2.3 Add `preExecutionScript`

Symmetrical to `postExecutionScript`: an unrestricted `[scriptblock]`, invoked with `&` before
`Test`, for imperative pre-flight work (logging, environment prep, calling
`Stop-TaskProcessing` to bail before even attempting a resource). Same trust level and same
child-scope invocation as `postExecutionScript` today — no new safety mechanism needed here, it's
explicitly the non-function-language, "just PowerShell" escape hatch, deliberately kept as-is per
the ask. Position in the loop: immediately after `preCondition` passes, before property expansion,
so it can also observe/react to `$task` before properties are resolved.

### 2.4 `stopProcessing()` as a function-language extension

This is the one piece that needs a real security decision, not just plumbing, because
`Stop-TaskProcessing` is a *side effect* (it mutates `$script:StopTaskProcessing`), and the entire
point of `Assert-SafeConditionExpression` (#35) is that a condition must not be able to mutate
runner state.

Proposed design — a narrow, explicit whitelist rather than loosening the ban generally:

- `Assert-SafeConditionExpression` changes from "reject every `CommandAst`" to "reject every
  `CommandAst` whose command name is not in an explicit allow-list", where the allow-list is
  exactly the runner's function-language surface: `parameters`, `variables`, `reference`,
  `equals`, `not`, `result` (§2.2), and `stopProcessing`. `AssignmentStatementAst` and
  `InvokeMemberExpressionAst` stay unconditionally forbidden — the whitelist only widens which
  *named, reviewed* functions can be invoked, not what kind of AST node is allowed. Because
  `FindAll` already walks nested nodes, an arbitrary command nested inside, say, an argument to
  `equals(...)` is still caught — only the outer call itself needs to match the whitelist, and
  every `CommandAst` in the tree (nested or not) is checked individually.
- **`stopProcessing()` is only permitted inside `postCondition`, not `preCondition`.** Rationale:
  `preCondition` runs before the resource has been evaluated at all, so a
  `preCondition: $(stopProcessing())`-style expression would halt the whole remaining run based on
  something that hasn't happened yet — surprising, and arguably the wrong tool (an author who
  wants to stop before a resource runs can already do that via `preExecutionScript`, which is
  unrestricted). `postCondition` is the natural fit: "given what actually happened, stop here." A
  parameter on `Assert-SafeConditionExpression` (`-AllowStopProcessing`) gates this, so
  `preCondition` calls it with the flag off and `postCondition` with it on — one function, one
  security check, context-dependent policy.
- `invoke-stopProcessing` (new `source/Private/Runner/stopProcessing.ps1`, alias `stopProcessing`)
  is a thin wrapper that calls the existing `Stop-TaskProcessing` (reusing its call-stack guard
  unchanged) and returns `$true`, so it composes into a boolean expression:
  `postCondition: not(result().InDesiredState) -and stopProcessing()` reads naturally as "if this
  resource ended up wrong, stop the run" while still yielding a boolean for the `postCondition`
  result itself (`FAIL`, in this example, since the expression as a whole is the negation).

This is a deliberate, reviewed carve-out from "conditions are side-effect free" — call it out
explicitly in the eventual PR description and in `Assert-SafeConditionExpression`'s doc comment
(update the `.DESCRIPTION` to name the exception and why it's safe: it's not "any side effect,"
it's exactly one reviewed, single-purpose, already-guarded function).

### 2.5 What stays out of scope here

- DSC v3's own native `[functionName(...)]` syntax (`docs/dsc-v3-config-functions.md`) is a
  *property*-only concept — it has no notion of a runner-level `preCondition`/`postCondition`, so
  it is not part of this extension. The two function languages stay where they already apply:
  runner functions in `preCondition`/`postCondition`/`properties`, DSC v3 native functions in
  `properties` only (when `Native` mode ships).
- `preExecutionScript`/`postExecutionScript` stay fully imperative, as asked — no attempt to fold
  them into the constrained grammar. They remain the place for anything the function language
  can't express.

### 2.6 Sequencing

1. Rename `condition` → `preCondition` with back-compat alias (isolated, no behavior change).
2. Whitelist-based `Assert-SafeConditionExpression` (still only gates `preCondition`,
   `-AllowStopProcessing:$false`) — unlocks `parameters()`/`variables()`/`equals()`/`not()` in
   `preCondition` on its own, independent of `postCondition`/`stopProcessing()` landing.
3. `postCondition` + `result()` + `stopProcessing()` (`-AllowStopProcessing:$true` for this call
   site only) together, since `postCondition`'s main motivating use case is exactly the
   stop-on-bad-outcome pattern above.
4. `preExecutionScript` (independent, can land any time — it's additive and unrestricted).
5. Update `README.md`'s `Stop-TaskProcessing` row ("Must be called from within
   `postExecutionScript`" → "...from within `postExecutionScript`, `preExecutionScript`, or a
   `postCondition`") and `docs/trust-model.md` (condition safety guarantees change from
   "no command invocation" to "no command invocation outside the reviewed function-language
   whitelist").

## 3. Reboot handling

### 3.1 Why this is harder than it looks: no remote-execution story today

Both engines run **locally**, against whatever machine the runner process itself is on:
`Invoke-DscResource` (`Actions/Engine/DscV2.ps1`) is called with no `-CimSession`, and
`dsc resource <verb>` (`Actions/Engine/DscV3.ps1`) is a local CLI invocation — there is no
`-ComputerName`/`-CimSession`/remote-target parameter anywhere in `source/` or `Actions/`
(confirmed by search). That matters directly for "wait for reboot": if the machine that reboots
is the same machine running the runner process, the process (and the CI/agent job hosting it) is
killed by the reboot. There is no in-process way to "wait" through your own machine's restart —
you're not there to observe it.

This means the two sub-cases genuinely need different solutions, and the answer depends on
whether the runner ever gains remote-target execution (an orthogonal decoupling question, not
addressed by this plan):

- **Local target (today's reality)**: reboot ends the current run. The only thing the runner can
  do is checkpoint cleanly and let something *outside* the current process resume it after boot.
- **Remote target (future, contingent on a remoting story)**: the runner's own process, running on
  a controller that is not the node being configured, survives the target's reboot. This is the
  case `Restart-Computer -Wait -For WinRM|SSH|PowerShell -Timeout <n>` — a stock PowerShell
  cmdlet — already solves directly, because it's designed to restart a computer and block the
  *calling* session until it's reachable again. It only helps once there's a remote session to
  point it at.

### 3.2 First, a concrete bug: `RebootRequired` is already modeled but discarded

`[DscMethodResult]` already has a `RebootRequired` field (`source/Classes/DscMethodResult.ps1`),
populated correctly by `Actions/Engine/DscV2.ps1` from `Invoke-DscResource`'s `Set` output. But:

- `Start-DscRunner.ps1:331` calls `Set` as `$null = Invoke-EngineAction -Method 'Set' ...` —
  **the result, reboot flag included, is thrown away.** Nothing downstream ever sees it.
- `Actions/Engine/DscV3.ps1:94` hardcodes `RebootRequired = $false` unconditionally — it never
  inspects `dsc.exe`'s actual output for a reboot signal (needs verification against a real
  `dsc resource set` payload; DSC v3's reboot-pending signaling for a resource that needs one is
  not yet confirmed against the runner's current CI fixtures and should be checked before wiring
  it in).

Fixing this — capturing `Set`'s result, adding `RebootRequired` to the per-resource report record
and JSON report, and correcting `DscV3.ps1` to parse it — is useful on its own (an operator can at
least *see* "this run needed a reboot" in the report) independent of any wait/resume mechanism,
and should ship first regardless of which option below is chosen.

### 3.3 Local-target plan: checkpoint + externally-orchestrated resume

Since the runner cannot wait through its own machine's reboot, split the responsibility:

1. **New `Actions/Reboot/<Name>.ps1` hook**, following the existing `Source`/`Connect`/`Engine`
   pattern (`PipelineRunnerSettings.Reboot`, default `None`):
   - `None` (default) — today's behavior, made visible: a `RebootRequired` result is recorded in
     the report but the run continues onward without stopping. Matches current behavior exactly,
     just no longer silently discarding the flag.
   - `StopAndCheckpoint` — on the first resource in a file whose `Set` reports
     `RebootRequired: $true`, the runner (a) writes a checkpoint file — the file path, the mode,
     the ordered list of resources already completed with their results, and
     `$parameters`/`$variables`/`$references` as they stood — via an atomic write (write to a temp
     path, then rename, so a reboot racing the write can't leave a half-written checkpoint), (b)
     sets a new run `Status` value `PendingReboot` (alongside today's `Completed` /
     `StoppedByRequest` / `AbortedByException`), (c) stops processing remaining resources in the
     file (reuses the existing `$script:StopTaskProcessing` skip machinery), and (d) returns/exits
     with a distinguishable, conventional code — **3010** is the Windows convention for
     "success, restart required" (used by MSI and Windows Update), which lets a calling pipeline
     branch on it directly (`if ($LASTEXITCODE -eq 3010) { ... }`) without inventing a new
     signal.
2. **New `-ResumeFrom <checkpointPath>` parameter** on `Start-DscRunner`/`Invoke-DscRunner`: loads
   the checkpoint, re-seeds `$parameters`/`$variables`/`$references` from it, skips every resource
   already recorded as completed, and resumes the loop from the next one. Idempotency is not a new
   requirement this introduces — DSC resources are already expected to be safely re-testable
   (that's the point of `Test`), so even a resource whose completion wasn't durably recorded before
   an unexpected reboot is simply re-evaluated and is a no-op if it's already in the desired
   state.
3. **The reboot itself, and re-invoking the runner after it, stay outside the module** — exactly
   the same boundary this project already draws for auth/source/engine via `Actions/`, and
   consistent with the "no LCM" goal (`docs/DECOUPLING_PLAN.md` §1/§6): actually restarting Windows
   and guaranteeing something re-launches the process afterward is a privileged, OS-specific
   concern (`RunOnce` registry keys, a Windows service, a scheduled task, a self-hosted agent's own
   restart/reconnect behavior, a systemd unit). Ship **one documented example per platform** (a
   short PowerShell scheduled-task snippet for Windows, a systemd-unit snippet for Linux) in
   `docs/`, alongside the exit-code contract, rather than building reboot orchestration into the
   module. A hosted-agent pipeline (Azure DevOps, GitHub Actions) may instead prefer to *not*
   reboot the agent at all and treat `PendingReboot` as "fail this job, file a follow-up job after
   an agent-level restart" — both are legitimate, and it's a pipeline-authoring decision the module
   shouldn't presume.
4. **`LocalRestartAndResume`** (opt-in, higher-risk variant of the above) — same checkpoint, but
   the runner itself calls `Restart-Computer -Force` before exiting, instead of leaving the reboot
   to the caller. Still requires an external supervisor to relaunch with `-ResumeFrom` after boot
   (the module still can't guarantee its own relaunch), so it only removes one step, not the
   dependency — worth offering as a convenience, but default off given it reboots the box the
   pipeline's own agent may be running on, with no built-in confirmation step.

### 3.4 Remote-target plan (future, contingent on remoting support)

If/when the runner gains a remote-execution story (a `-ComputerName`/`-CimSession`/`-PSSession`
context threaded through the `Engine` action, which is a separate, larger design than this
document), the reboot-wait problem gets much simpler and doesn't need checkpointing at all: add a
`RemoteWaitAndContinue` `Actions/Reboot/` action that calls
`Restart-Computer -CimSession $target -Wait -For WinRM -Timeout <n>` (or `-For SSH` for a Linux
target) directly, then simply falls through to the next resource in the same loop, same process —
because the *runner's* process, on the controller, never went down. This is the cleanest version
of "wait until reboot completes, then continue" and matches what most remote-config tools do, but
it is explicitly gated on remote-target execution existing first; noted here as the reason not to
over-invest in the local checkpoint/resume plumbing being anything more than "good enough for the
architecture as it stands today."

### 3.5 Open questions

- Should `PendingReboot` count as a "clean" outcome for `-FailOnError` (today's non-zero-exit-on-
  failure switch), or does it need its own opt-in flag (`-FailOnPendingReboot`) so a pipeline can
  distinguish "needs a reboot and a resume" from "actually failed"? Recommend the latter — treating
  a reboot-pending run as a failure by default would make a normal, successful-so-far apply look
  identical to a real error in dashboards/alerts.
- Does the checkpoint file need the same secret-redaction treatment `Protect-SensitiveValue`
  already applies to verbose logging (§ `Test-ResourcesForIncorrectProperties.ps1`)? It carries
  `$references`/`$parameters`, which routinely include resolved secrets — recommend yes, and that
  it's written with the same owner-only permission tightening `Set-PrivateDirectoryPermission.ps1`
  already applies to cloned repos.
- Exact `dsc.exe` reboot-pending JSON shape for §3.2's `DscV3.ps1` fix needs confirming against a
  real DSC v3 resource that sets it (most built-in Microsoft DSC v3 resources don't reboot; this
  may need a purpose-built test resource, mirroring how `scripts/Test-DscV3ConfigDocument.ps1`
  already proves the document-conversion path against real `dsc.exe`).
