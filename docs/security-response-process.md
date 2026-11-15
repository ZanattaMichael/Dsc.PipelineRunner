# Responding to a vulnerability report

This is the maintainers' runbook behind the public policy in [SECURITY.md](../SECURITY.md). It
says what to do, in order, from the moment a report arrives to the moment the advisory is
published, so that the targets in the policy are met and nothing is disclosed early.

The targets below are the ones the policy promises. If one cannot be met, tell the reporter, say
why, and give a new date. Silence is the failure to avoid.

## 1. Receive (target: acknowledge within 5 business days)

1. Reports arrive as a **GitHub security advisory** (Security tab, "Report a vulnerability").
   That keeps the discussion private and gives a place to work on a fix. If a report arrives
   anywhere public (an issue, a pull request, a discussion, a comment), **move it**: ask the
   reporter to resubmit privately, then edit or delete the public text and say nothing about its
   content in the public thread.
2. Reply to the reporter: thank them, confirm you have it, and say when they will hear next.
3. Do not discuss it in public channels, public commits, public CI logs, or a pull request title
   or description until the fix is released.

## 2. Triage (target: confirm and rate within 10 business days)

1. **Reproduce** it on the latest release and on `main`, with dummy data, in a throwaway
   environment. Record the exact version, engine (`DscV2` / `DscV3`) and steps.
2. **Decide whether it is in scope** (see "Scope" in SECURITY.md). The usual non-vulnerabilities:
   - the trusted configuration repository doing what the trust model says it can do;
   - a third-party flaw (Datum, `powershell-yaml`, a DSC resource, `dsc.exe`): report it
     upstream, and treat it here only if our use makes it exploitable.
   A *bypass of a documented control* is always in scope.
3. **Rate it** with the severity table in SECURITY.md. Ask: what can an attacker do that the
   trust model does not already allow them, and what must they control first?
4. Tell the reporter the outcome and the severity. If you disagree with their rating, explain
   why; severity is a conversation, not a verdict.
5. If the report shows that a **real secret was exposed** (in a log, a report, or a repository),
   tell whoever owns it to **rotate it now**, independently of the fix.

## 3. Fix (target: Critical 14 days, High 30, Medium 60, Low next release)

1. Use the advisory's **temporary private fork** so the work stays private. Do not push a fix
   branch to the public repository.
2. Fix the **cause**, not just the reported instance. Search for the same pattern elsewhere
   (every log or report sink for a leak, every path for a traversal, every call site for a missing
   check).
3. Add a **regression test** under `Tests/PipelineRunner/Security/` in a file named
   `<Topic>.Security.tests.ps1`, tagged `Unit, Security`, written to **fail on the old code** and
   pass on the new. Use dummy values only.
4. Keep the change small and behaviour-preserving for legitimate use. If it changes behaviour
   (a value that used to be accepted is now refused), say so in the CHANGELOG under
   "Behaviour changes".
5. List the new test in SECURITY.md under "Regression tests for these guarantees" and, if it is a
   new guarantee, in the "How the module ensures security" table. The security policy test fails
   if a security test file is not listed.
6. Have someone other than the author review it where possible, and run the full CI, including
   the self-hosted jobs, on the private fork.

## 4. Release and disclose

1. Add a **Security** entry to the CHANGELOG describing the issue and the fix. Do not include a
   working exploit; do say who is affected and what to do.
2. Merge, bump the version, and push a `v*` tag; the Release workflow publishes the GitHub
   release and the module.
3. **Publish the advisory** at the same time: affected and patched versions, severity, a CVE if
   one applies, credit for the reporter (unless they asked to stay anonymous), and any
   mitigation for people who cannot upgrade.
4. Tell the reporter the release is out before the advisory is public.
5. If the 90-day limit in the policy is reached with no fix, publish what can safely be said
   (the affected versions and a mitigation) rather than staying silent, and tell the reporter
   first.

## 5. After

1. Note what class of bug it was and whether a **guard** can stop the class (a lint rule, a
   shared helper, a test that scans for the pattern).
2. Check that the policy, the trust model and the summary table still describe the product.
3. Thank the reporter publicly if they agreed to it.

## Quick reference

| If the report says... | Do this first |
|---|---|
| "a secret appears in a log / report / command line" | Reproduce with a dummy; tell the reporter to rotate the real one; trace every sink for the same value; add a leak test. |
| "I can run code without `AllowExecutionScripts`" or "a condition ran a command" | This is a bypass of a documented control: High. Reproduce through the real runner, not just the validator. |
| "a file was written outside the cache directory" | Check every place a name becomes a path; add a traversal test with the exact hostile name. |
| "a pull request can reach a secret or a self-hosted runner" | Treat as High; disable the workflow trigger first, fix second. |
| "this is just how the configuration repo works" | Likely out of scope; point to the trust model and ask whether a *documented control* is bypassed. |
