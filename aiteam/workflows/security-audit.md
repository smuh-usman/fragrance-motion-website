# Workflow: Security audit

An audit is review with no diff to anchor it, so it needs its own structure or it
becomes a checklist someone ticks.

```
SCOPE → THREAT MODEL → SWEEP → VERIFY EACH FINDING → TRIAGE → REMEDIATION TASKS
```

## Scope

Name what is in scope and what is not. An audit of "the application" produces
generalities; an audit of "everything reachable by an authenticated non-admin
user" produces findings.

## Threat model

Before reading code, write down who the attackers are, what they want, and what
they already have — an account, a link someone forwarded them, a stolen session,
an intercepted request. Findings that do not connect to one of these are noise.

## Sweep

Dispatch the reviewer under the security lens across the scope. Multiple passes
with different questions find more than one pass asking everything at once:
authorization on every path; identity and session handling; state transitions
that must be impossible; time and expiry; concurrency as an attack; injection and
output encoding; what each response actually serializes.

Run passes in parallel — they are read-only and cannot collide.

## Verify each finding independently

Every finding gets a second opinion before it becomes work. Ask a fresh agent to
*refute* it: construct the reason it is not exploitable. Findings that survive an
attempt to disprove them are real; the rest were pattern-matching.

This matters more in an audit than anywhere else, because unverified security
findings are expensive — they consume remediation effort and they train everyone
to discount the next report.

## Triage and remediate

Rank by consequence, not by how easy the fix is. Each surviving finding becomes a
task with the attack in its objective and a test asserting the attack fails in its
acceptance criteria. A security fix without a test proving the exploit no longer
works is not a fix; it is a hope.
