# Bypassing Datum

The runner normally compiles a [Datum](https://github.com/gaelcolas/Datum) hierarchy into one
document per node and runs those. If you already have the per-node documents, because you built
them yourself or with another tool, you can skip Datum and hand them to the runner directly. This
is the **passthrough** run.

Everything after the compile is unchanged: [Pipeline Rules](Pipeline-Rules), conditions,
`dependsOn`/`notify` ordering, lifecycle scripts, `reference()`/`using()`, the report and the exit
code (see [Execution lifecycle](Execution-Lifecycle)).

## Run it

```powershell
# One document.
Invoke-DscRunner -ConfigurationFile .\out\SRV-APP-01.yml -BypassDatumPolicy -Mode Test

# A directory of documents, with the run settings Datum.yml would otherwise supply.
Invoke-DscRunner -ConfigurationDirectory .\out -BypassDatumPolicy -RunnerSettings @{ Engine = 'DscV3' } -Mode Set
```

| Parameter | What it does |
|---|---|
| `-ConfigurationFile` | One or more documents to run. Mutually exclusive with the `Source` parameters. |
| `-ConfigurationDirectory` | A directory of documents to run. Mutually exclusive with the `Source` parameters. |
| `-BypassDatumPolicy` | **Required.** Declares that the run steps outside the [capability policy](Capability-Policy). |
| `-RunnerSettings` | The [PipelineRunnerSettings](PipelineRunnerSettings) for the run, as a hashtable. Omit it to use the runner's defaults. |
| `-NodeName` | The node name, when a single document's file is not named after its node. |

## Version requirements

Bypassing Datum needs `Dsc.PipelineRunner` **1.5.1 or later**. An older module does not know
`-BypassDatumPolicy`, `-ConfigurationFile` or `-ConfigurationDirectory`, and fails with a
parameter error. A bypass run has no `Datum.yml`, so `ConfigurationVersion` and
`PipelineRunnerVersion` are not checked. Keep them at `0.6` / `1.2.0` in the configurations you
still compile with Datum. See [Upgrading](PipelineRunnerSettings#upgrading).

## What a document must look like

A document is what the compile would have produced: flat, with composites already expanded (an
unexpanded `Composite/` instance is refused), saved as `.yml`, `.yaml` or `.json`.

**The node name is the file name** without its extension, the same rule the compiled path uses.
It is what `nodeName()` returns and what the report files are named after, so two documents in one
run may not share a file name. `-NodeName` overrides it for a single document only; it is
validated as a plain file name, so a path separator, a wildcard, `..` or a leading dot is refused.

## Settings come from `-RunnerSettings`, not the document

There is no `Datum.yml`, so the run settings come from `-RunnerSettings`. They are deliberately
**not** read from the document: whether a run may execute unconstrained lifecycle scripts
(`AllowExecutionScripts`) is for whoever starts the run to decide, not the document itself.

A `PipelineRunnerSettings` block left in a document is **ignored**. The runner warns once per
document and names the file, so nobody believes those settings took effect. It is a warning, not
an error; the rest of the document runs.

## The capability policy cannot apply

A [capability policy](Capability-Policy) decides what each *layer* of a configuration may use, and
a layer is decided by where a file sits in the Datum hierarchy. A passthrough document has no
layers, so no policy can be enforced over it. So that passthrough is never a quiet way round a
policy, the run must say so with `-BypassDatumPolicy`. A run that takes it warns that the policy
is bypassed and records `PolicyBypassed` on every node's result and report document.

The switch grants no exception:

| What sits above the documents | Without `-BypassDatumPolicy` | With it |
|---|---|---|
| A `Datum.yml` **and** a `Policy.yml` beside it | Refused | **Refused.** Run it through Datum instead. |
| A `Datum.yml` with no policy, or no `Datum.yml` | Refused, naming the switch | Runs, warns and records the bypass |
| A `Policy.yml` with no `Datum.yml` | Refused, naming the switch | Runs with a warning: the policy governs nothing the runner can resolve |

For each document the runner walks up from the document's folder, the way `git` finds `.git`,
and stops at the first folder holding a `Datum.yml`. A `Policy.yml` counts only beside that file.
One governed document refuses the whole run.

Also refused:

- `-PolicyPath` and `-RequirePolicy` on a passthrough run, because there are no layers to judge.
- `-BypassDatumPolicy` on a normal Datum run, so it can never switch a policy off.

This check catches passthrough pointed at a governed repository. It cannot tell that a document
was *copied out* of one, because a flat document does not record where it came from. The switch
is the caller's declaration, not a proof.

## Trust

A passthrough document is code in the same sense a compiled one is. Supplying it directly removes
the compile, not the need to trust whoever wrote it. See the
[trust model](https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/docs/trust-model.md).
