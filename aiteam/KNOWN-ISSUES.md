# Known issues in the harness

Defects and gaps in the team machinery itself, recorded when found and removed
when fixed. This file is about the harness only; it must stay free of any
particular project's domain, like everything else under `aiteam/`.

An issue earns a place here when it can produce a *wrong gate result* — evidence
that misrepresents what happened. Ordinary roughness does not.

---

## H-001 — Authorship is only recorded when a writing agent produced the code

**Severity:** medium. Open.

`implement.sh` writes a history note naming the model that made an attempt
(`attempt N failed verification with <model>`). Nothing records authorship when
the orchestrator writes the code itself, which happens legitimately — after the
rejection cap is reached, or when the owner asks for it directly.

The result is a task history where some attempts name their author and others
name nobody, and the silence is ambiguous: it could mean the orchestrator wrote
it, or that a note was simply never written. Provenance of a diff should never be
inferred from an absence.

**Fix shape.** Make authorship an explicit field on each attempt rather than a
free-text note, and require it — including a value for the orchestrator. A task
that cannot say who wrote an attempt should fail its own schema.

---

## H-002 — `isolation.branch` was observed disagreeing with the worktree

**Severity:** low. Open, mechanism unconfirmed.

On one task the recorded `isolation.branch` no longer matched the branch actually
checked out in the worktree, after the task's title changed mid-flight. It was
corrected by hand and the task completed normally.

`worktree.sh create` derives the branch from the title and records both fields
together (`worktree.sh:23-45`); no other path recomputes it from the title, so a
later title change should not have moved it. The likely explanation is that
`create` ran a second time after the rename, but that was not confirmed at the
time and I will not record a cause I did not verify.

**Why it matters despite being low.** `confirm-merged` and the MERGED gate both
resolve the branch from this field. A stale value asks git about the wrong branch
— and git will answer, truthfully, about a branch nobody cares about.

**Fix shape.** Derive the branch from the worktree's actual HEAD at use time and
treat the recorded field as a check rather than a source, or refuse to proceed
when the two disagree.

---

## H-003 — A retry prompt re-litigates review findings that are already closed

**Severity:** medium. Open.

`implement.sh` builds a retry prompt from the task's review findings and the last
failed verification run. Neither input has any notion of a finding being *closed*.
A task that has survived several rounds therefore receives every finding the
reviewer ever raised, including the ones fixed two attempts ago, with nothing
distinguishing them from the outstanding ones.

Observed on TASK-0013. Five of seven findings were closed across attempts 4 and 5,
leaving one medium and one low. Attempt 6 received all seven in a 103KB prompt,
spent its entire 2700s wall-clock budget re-deriving which were still open — 82
file reads, 20 greps, zero edits — and was killed by the watchdog immediately
after emitting "I now have a complete understanding. Let me verify a few final
details before implementing". It produced nothing. The attempt was charged.

**Why it matters.** The cost scales the wrong way: the more remediation rounds a
task survives, the larger its prompt grows and the less budget remains for the
work still outstanding. A task can starve on findings it has already fixed. It
also silently inverts the escalation ladder's meaning — a rung spent on
re-reading is indistinguishable, in the task file, from a rung spent failing.

**Fix shape.** Let a finding carry a status, set when a later verification or
review round demonstrates it closed, and have the prompt builder either omit
closed findings or mark them explicitly as closed-and-not-to-be-reworked. Failing
that, the orchestrator must be able to hand a retry a narrowed finding list.
Related: the watchdog should distinguish "killed while still reading" from
"killed mid-edit" — only the second is a truncation worth verifying.

---

## H-004 — The reviewer cannot run the test suite it is asked to judge

**Severity:** medium. Open.

`review.sh` gives the reviewer a read-only checkout, which is deliberate: a
reviewer that can write is not independent, and this is the guard that stops one
from "fixing" what it was asked to judge. The cost was not anticipated. The test
runner needs to write into the checkout — it creates a timestamped config file
next to the project config — so it cannot start at all. The reviewer reported
this itself: typecheck and lint ran, the suite did not.

Every review to date has therefore judged the code by reading it, and the recorded
test results in the evidence directory are the ORCHESTRATOR's execution, quoted
into the review prompt. That is a materially weaker claim than it looks. A test
that passes for the wrong reason, or a test whose name promises more than its body
asserts, is exactly what an independent execution would expose, and nothing in the
pipeline currently performs one.

**Why it matters.** The mutation gate partly compensates — it proves a declared
guard has a test that fails without it — but it only covers criteria that declare
a mutation, and it too runs under the orchestrator. Two of the three parties that
could catch a fabricated green are the same party.

**Root cause, verified 2026-08-23.** Two independent blocks, not one. The config
write was confirmed by watching the directory during a config load: the loader
emits `vitest.config.ts.timestamp-<n>.mjs` beside the config and unlinks it
immediately. A `.cjs` config avoids the write entirely (also confirmed) because
the CJS load path compiles in memory. But fixing that only moves the failure one
step: the test config declares an unconditional `globalSetup` that starts a real
database container, so any invocation needs the container socket and the network,
both denied by the read-only sandbox. The split at the time of writing was 27
container-backed test files to 19 plain ones, and every sweep under review was in
the first group. A reviewer that could start the runner still could not run the
tests it was asked to judge.

**Fix shape.** The earlier suggestion here — a writable scratch location, or a
disposable writable copy — was written before the container dependency was
understood, and it does not survive it. Weakening the sandbox is also the wrong
trade: the read-only guarantee is the only thing making the review independent,
and a reviewer that patched a throwaway copy, ran it green and reported PASS
would be indistinguishable from one that read carefully.

The direction taken instead is TASK-0016: the reviewer already writes a concrete
failure scenario for every finding, and the harness already applies patches and
runs named tests for the mutation gate. Connecting them makes the reviewer's
counterexamples executable by the harness while its sandbox stays exactly as it
is — it describes, the harness runs. That does not give the reviewer a general
ability to run the suite, and this entry stays open for that reason; it removes
the specific dependency that mattered, which is settling whether a finding is
real without one agent hand-building the counterexample from prose.

**Observed cost before that fix.** Four consecutive review rounds on TASK-0014
returned diff-reading-only verdicts. Across those rounds the orchestrator built
counterexamples by hand and found six defects in one file that the reviewer had
not raised, four of them after the reviewer's own findings were closed and the
suite was green. Whether a seventh existed was bounded by one agent's
imagination, which is precisely the property this entry describes.

**Update 2026-08-24 — the direction taken is TASK-0016.** Two independent blocks
were verified as the root cause: the loader emits a timestamped config beside the
project config (a `.cjs` config avoids the write entirely), and the test config's
unconditional `globalSetup` starts a real database container, which needs the
container socket the sandbox denies. A writable scratch location does not survive
the container dependency, and weakening the sandbox is the wrong trade — the
read-only guarantee is the only thing making the review independent, and a
reviewer that patched a throwaway copy, ran it green and reported PASS would be
indistinguishable from one that read carefully.

TASK-0016 connects the two existing pieces instead: the reviewer already writes a
concrete failure scenario for every finding, and the harness already applies
patches and runs named tests for the mutation gate. A finding may now carry a
structured **counterexample** — files to add or edit, the single test to run, and
whether that test is expected to PASS or FAIL once applied — and
`bin/counterexample.sh <id>` applies it, runs it, and records CONFIRMED,
REFUTED or INCONCLUSIVE per finding in the evidence directory. The reviewer's
sandbox stays exactly as it is: it describes, the harness runs. The results reach
the next implementation prompt as executed evidence.

That removes the specific dependency that mattered — settling whether a finding
is real without one agent hand-building the counterexample from prose — but it
does not give the reviewer a general ability to run the suite, so this entry
stays open for that reason.

---

## H-005 — `task.sh findings` reports success when the findings file is unreadable

**Severity.** Medium.

**What happens.** `cmd_findings` pipes the file through `jq --slurpfile`. When the
path does not exist, jq writes `Bad JSON in --slurpfile ... Could not open` to
stderr and exits non-zero, but the surrounding `&& mv` chain leaves the task file
untouched and the command still prints
`attached 0 open finding(s), carrying N already closed` in green and exits 0.

**Observed.** 2026-08-21 on TASK-0013, attaching the round-4 findings with a
mistyped scratchpad path. The success line was indistinguishable from a genuine
zero-finding attach.

**Why it matters.** A silent zero-attach is the most dangerous possible outcome
here: the next `implement.sh` dispatch builds its prompt from `.findings`, so a
retry would be sent out carrying no findings at all while the operator has just
been told the attach succeeded. The agent would then re-run a task it believes is
already clean, and the orchestrator would have no signal that anything was lost.
This is the same family as the mutation-score defect — the harness reporting an
outcome it did not achieve.

**Fix shape.** Validate the file before the jq pipeline: require it to exist, to
parse, and to contain a `.findings` array. Then make the success message report
what was actually written by re-reading the task file rather than by assuming the
pipeline ran. A zero-finding attach should be a warning, not a green line.

---

## H-006 — Orchestrator-side commands trust the caller's working directory

**Severity.** Medium.

**What happens.** `mutate.sh`, `verify.sh` and the evidence writers operate on
whatever directory the shell happens to be in. They do not resolve the task's
worktree from `isolation.branch` in the contract and do not refuse to run
outside it.

**Observed.** Three times on 2026-08-21 during TASK-0013. Once benignly — a
`mutate.sh` invocation fired from the main checkout and died at `cp` with "No
such file or directory", changing nothing. Once harmfully — orchestrator edits
intended for `aiteam/` in the main checkout landed in the worktree's copy
instead, and were only caught because `selfcheck.sh` reported 104 checks where
117 were expected.

**Why it matters.** `task.sh` enforces a scope gate that treats writing outside
the declared files as a violation when a WRITING AGENT does it. The orchestrator
running the same commands has no equivalent guard, so the one actor trusted to
verify everyone else's work is the one actor whose file writes are unchecked.
The benign failure mode is a crash; the dangerous one is evidence written
against the wrong tree and then read back as if it described the right one.

**Fix shape.** Resolve the worktree path from the task contract at the top of
each script, `cd` there explicitly, and fail loudly if the resolved path is not
a git worktree whose HEAD is the task branch. The property to preserve is that a
command about a task can only ever act on that task's checkout, regardless of
where it was invoked from.

---

## Fixed

**`verify.sh` silently ignored unknown arguments** (fixed 2026-08-20). The
argument loop had no default arm, so `verify.sh <id> postrebase` — the `--`
omitted — ran in default mode and overwrote `verify.log`, the pre-review
evidence, with a post-merge run. A typo could forge the record the review gate
reads. Unknown arguments are now fatal.

## H-015 — Harness maintenance was impossible on the front door, so it happened behind it

**Status:** fixed 2026-08-25 by a `harness_task` contract exemption.

The scope gate treated any write under `aiteam/` or `.aiteam/` by a dispatched
agent as a hard violation. The rule was justified — an implementer once used a
`.aiteam/` opening to reset its own rejection counter, drive its own lifecycle
transitions and edit the review schema — but the harness also needs maintenance,
and the only implementer available was a dispatched agent. One harness task
reached the trunk while still IN_PROGRESS because it was routed around the gate,
never passing it and never reviewed, and it carried three defects, one of which
disabled the reviewer for every task in the repository (H-012, H-013, H-014).

The fix makes the exemption explicit, narrow and reviewed instead of something a
determined operator routes around. A contract that declares `harness_task: true`
may write harness CODE under `aiteam/**`, judged by the same `files.expected`
globs as anything else; `.aiteam/**` (harness STATE) stays a hard violation no
contract field lifts, a harness task cannot skip independent review, and every
use of the exemption is recorded in the task's history. The distinction that
matters is between harness code, which a reviewer and the gates still judge, and
harness state, which is the machinery of judgement and stays untouchable.
## H-016 — The gates and the dispatched agent disagreed about the runtime

**Status:** fixed 2026-08-24 by TASK-0018. Originating defect recorded as
H-009 above.

`implement.sh` and `review.sh` raised PATH to the newest Node satisfying the
provider CLI's minimum (because the CLI needs it to start), and the agent's
shell inherited that PATH. `verify.sh`, `mutate.sh` and `counterexample.sh`
raised nothing and ran on whatever Node the operator's shell had, and the
project declared its own supported floor. Three different answers to "which
runtime must this code work on", none of them told to the agent. The cost was
real: a classifier that only parses under a newer Node passed every test the
agent could run and failed the gate, and three consecutive dispatches made zero
edits because the failure was invisible to the agent asked to fix it.

**Mechanism of the fix.** `_lib.sh` now has a single resolver,
`gate_runtime_bin`, that reads the repository's `package.json` `engines.node`
and prefers a runtime on that declared floor over any newer install; when no
floor is declared it keeps the existing newest-wins behaviour. One shared entry
point, `ensure_gate_runtime`, pins that runtime on PATH for every gate —
`verify.sh`, `mutate.sh` and `counterexample.sh` all call it before executing
anything, and it dies loudly (naming the required runtime and stating that
nothing was executed) rather than falling back when the runtime is missing.
`implement.sh` resolves the gate runtime at prompt-build time and states its
path plus a copyable invocation form in the dispatch prompt, so the agent can
reproduce the gates' runs even though its own shell inherits the newer provider
PATH. The provider CLI's minimum and the project's floor are separate concerns
and no longer share one PATH. Verified by `aiteam/tests/gate-runtime.test.sh`.

**The runtime the gates now use:** the project's declared floor — here Node 20
(v20.10.0, from `engines.node` `">=20.9.0"`). If a future disagreement appears,
check whether a gate is running on something other than the floor.

## H-007 — `doctor.sh` reports a false authentication failure on the wrong runtime

**Status:** open. Found 2026-08-22 while checking provider reachability before
dispatching TASK-0014.

`doctor.sh` reports `✗ Command Code not authenticated — run 'cmd login'` while
`cmd status` in the same repository answers `Authentication verified`. The
credentials are fine. The check runs `cmd` on whatever `node` happens to be
first on PATH; when that is older than the provider's `min_node_major`, the CLI
refuses to start, and doctor reads the refusal as an auth failure rather than as
a runtime failure.

`_lib.sh` already solves exactly this for dispatch — `ensure_provider_runtime`
resolves a new-enough runtime before invoking a provider — and `doctor.sh` never
calls it. Dispatch is therefore unaffected; only the diagnostic lies.

The cost is misdirection at the worst moment: doctor's own advice is `cmd login`,
which would send someone to re-authenticate a working account, and its closing
line is `Harness has problems above. Fix them before dispatching work.` A
diagnostic that names the wrong cause is worse than one that stays quiet, because
it is believed.

**Fix belongs in** `aiteam/doctor.sh`: apply the same runtime resolution before
the auth probe, and distinguish "CLI would not start" from "CLI started and
reported no credentials" so the two never again print the same message.

## H-008 — A dispatch that dies before the model is contacted still spends an attempt

**Status:** open. Found 2026-08-22 dispatching TASK-0014.

The provider CLI rejected an invalid `--effort` value, printed `Unknown effort
"high". Supported: low, medium, xhigh.` and exited 1. The model was never
contacted. It read no prompt, wrote no file, and left the worktree clean —
`implement.sh` said so itself: *"the agent exited 1 without changing anything, so
this attempt implemented nothing."*

It incremented `attempts` to 1 anyway.

The harness therefore already knows the difference and does not act on it. That
matters because `attempts` is not a log line, it is a budget: the escalation
ladder reads it to decide when to move a task to a stronger model, and a task
owner reads it to decide whether a model is struggling. Both are misled by a
count that includes runs the model never saw. Spend three of these on a
mistyped flag and a perfectly capable model looks like it failed three times.

The distinction is cheap to draw: an attempt should count when the prompt
reached the model, not when the subprocess was launched. A CLI that exits
non-zero having produced no session and touched no file has not attempted
anything.

**Fix belongs in** `aiteam/bin/implement.sh`, at the same place it already
detects "exited without changing anything": treat a pre-contact failure as a
dispatch fault rather than an attempt, and surface it as an outage the way a
provider fault is surfaced — loudly, and without consuming budget.

**Related:** the value that triggered this was valid on every other model in
`providers.json`. Reasoning-effort ladders are per-model and must be probed
before they are configured, not assumed from a sibling entry.

**Recurrence 2026-08-23, a different cause with the same accounting.** Attempt 16
of TASK-0014 ran for 2,231 seconds and was then killed by the provider:
`Error: Unable to connect to the API.` The model had already written its fix; the
harness committed the work and warned, correctly, that a truncated run can still
have landed complete work — verification passed afterwards and an independent
probe confirmed the fix was complete. So the attempt was spent on a run that
succeeded, and would have been charged against the escalation budget identically
had the connection dropped in the first second.

That widens this entry rather than repeating it. The original case was a dispatch
dying BEFORE the model was contacted, where "nothing happened" is easy to detect
from a clean worktree. This case is a dispatch dying AFTER useful work landed,
where the run looks failed and the work is fine. Both are counted the same way,
and neither counter reflects what the model actually did.

**Recurrence 2026-08-24, the same accounting with a third cause: the harness's
own budget.** Attempt 25 of TASK-0014 was killed by `implement.sh` itself at its
2,700-second `timeout_seconds`. It had landed the substantive half of the work —
a 317-line resolver rewrite that typechecks and lints clean — and had not
started the half that proves it: five negative fixtures the task contract
required, of which it wrote zero. The suite went red on real repository code.

This is the most misleading of the three. A pre-contact failure leaves a clean
worktree and a provider outage leaves complete work; a budget kill leaves work
that is *half* done and looks whole, because the part an agent writes first is
the implementation and the part it writes last is the evidence. The commit is
large, the typecheck is green, and nothing in the run record distinguishes
"finished" from "ran out of time before writing the proof". Only counting `it(`
blocks against the contract's list caught it here.

That points at a fix beyond the counter: a truncated run should be reported
against what the contract asked for, not merely that files changed. The harness
already parses `acceptance_criteria` and `verified_by`; a kill that leaves a
named test absent is knowable at kill time and should be said out loud rather
than left for a reader to notice.

## H-011 — Attaching findings from an unreadable file silently empties them

**Status:** open. Found 2026-08-24 dispatching TASK-0014 round-6 slice B.

`task.sh findings <id> <file>` builds the new findings array with
`jq --slurpfile r "$src"`. When `$src` cannot be read, jq prints
`Bad JSON in --slurpfile` to stderr, substitutes nothing, and the pipeline
still writes a task file whose open findings are gone. The command then reports
success:

```
jq: Bad JSON in --slurpfile r .../r6-sliceB.json: Could not open ...
attached 0 open finding(s) to TASK-0014, carrying 33 already closed
```

Exit status 0. The next `implement.sh` dispatched a full run with nothing to
fix, the agent correctly found the tree already green, reported the work
complete, and an attempt was spent. The orchestrator had just written two
review findings into that file path and would have had no reason to re-read the
task state before dispatching.

The failure is that "attach these findings" and "clear all findings" are the
same code path, distinguished only by whether an input file parsed. Attaching
zero findings from a file that named two is never what the caller meant, and
this harness exists to disbelieve exactly this kind of silent substitution.

**Fix belongs in** `aiteam/bin/task.sh`, `cmd_findings`: validate the source
file parses and read its findings count BEFORE writing anything; refuse when the
file is missing or malformed; and refuse a write that would reduce the open
count to zero unless the caller asked for that explicitly. A jq failure inside a
command that rewrites task state must abort the command, not be absorbed by it.

**Related:** the caller error that triggered it was a relative path resolved
against a shell working directory that had been changed to a git worktree
earlier in the session. Harness commands take repo-relative paths and are run
from many directories; that is a standing hazard rather than a one-off slip.

## H-009 — The agent and the harness verify on different runtimes

**Status:** open. Found 2026-08-22 on TASK-0014 attempt 8.

`implement.sh` resolves a runtime new enough for the provider CLI before
dispatching (`ensure_provider_runtime`, line 271). `verify.sh` resolves nothing
and runs the project's verification commands on whatever `node` the caller
happens to have. On this machine that is Node 24 for the agent and Node 20 for
the harness.

An agent therefore writes code, runs the suite, watches it pass, and reports
success truthfully — while the same suite fails when the harness runs it. Here
the agent used `fs.globSync`, which needs Node 22, in a project whose
`package.json` declares `"node": ">=20.9.0"`. Both the agent's report and the
harness's refusal were correct about their own runtime.

The damage is not the failed gate — that worked. It is that "it passed for me"
becomes structurally possible, which is the exact class of claim this harness
exists to disbelieve. It also means an agent can be sent back to fix something
it cannot reproduce, and a defect can hide in the gap in the other direction:
code that passes on the harness's older runtime and fails on a developer's newer
one would never be caught either.

**Fix belongs in** `aiteam/bin/verify.sh`: resolve the runtime the same way
dispatch does, from a single declared source — preferably the project's own
`engines.node` floor rather than the provider's minimum, since the question the
gate answers is "does this work on the runtimes this project claims to support",
not "does this work on the newest one installed". Verifying on the floor is what
catches this defect; verifying on the newest hides it.

**Related:** H-007, where a stale runtime made `doctor.sh` report a false
authentication failure. Same root — the harness has one runtime resolver and
does not apply it everywhere it matters.

**Fixed 2026-08-24 by TASK-0018.** `_lib.sh` now has a single resolver,
`gate_runtime_bin`, which reads the declared floor from the repository's
`package.json` `engines.node` and prefers a runtime on that floor over any
newer install; with no declared floor it keeps the existing newest-wins
behaviour. One shared entry point, `ensure_gate_runtime`, pins that runtime on
PATH for every gate — `verify.sh`, `mutate.sh` and `counterexample.sh` all call
it before they execute anything, and it dies loudly (naming the required
runtime and stating that nothing was executed) when the runtime is missing
rather than falling back. The gates now run on the floor the project declares:
here, Node 20 (v20.10.0 from `engines.node` `>=20.9.0`), while dispatch still
raises PATH to the newest runtime the provider CLI needs. The two are separate,
and `implement.sh`'s prompt states the gate runtime's path and a copyable
invocation form so an agent can reproduce the gates' runs even though its own
shell inherits the newer provider PATH. Verified by
`aiteam/tests/gate-runtime.test.sh`.

## H-010 — The failed-verification excerpt is mostly passing-test output

**Status:** open, low severity. Observed 2026-08-22 on TASK-0014 attempt 9.

`implement.sh` carries the previous run's real failure output into the retry
prompt, capped at the last 180 lines per failed command. That design is right —
a retry that has to rediscover the failure by running the suite itself is the
most expensive way to learn something already written to disk.

The cap is measured in lines, though, and Vitest prints one line per passing
test before it prints the failure. On this run the failure block was 120 lines
and 7,932 bytes, of which 72 lines were `✓` successes. The single useful fact —
a TypeError naming the symbol and its line — was three lines.

Nothing is broken; the agent does receive what it needs. The cost is prompt
budget spent on noise on exactly the runs that can least afford it, since a
retry already carries findings, closed findings and the contract.

**Fix belongs in** `aiteam/bin/implement.sh`, in the awk that builds the block:
prefer the failure-bearing lines over a fixed line count — keep the reporter's
failure sections and the summary, drop runs of passing-test lines. Trimming the
evidence file itself is not an option: `verify.log` is what the gates read, and
editing it to slim a prompt would falsify the record.

## H-012 — The review schema is invalid under the provider's strict mode

**Status:** fixed 2026-08-25 by TASK-0017. Severity was HIGH: it blocked every
review on `gpt-5.6-sol`. Observed 2026-08-24 dispatching TASK-0014 round 7.

TASK-0016 added the `counterexample` object to `contracts/review.schema.json`.
The provider rejects the whole request with HTTP 400:

    Invalid schema for response_format 'codex_output_schema': ... 'required' is
    required to be supplied and to be an array including every key in properties.
    Missing 'content'.

Strict structured-output mode requires that EVERY key in an object's
`properties` also appear in its `required` array; a field is made optional by
widening its type to include `null`, never by omitting it from `required`. Two
places violate this, both added by TASK-0016 and nowhere else in the file:

  - `properties/findings/items` — `counterexample` is not in `required`
  - `properties/findings/items/properties/counterexample/properties/files/items`
    — `content`, `find` and `replace` are not in `required`

Rounds 1-6 worked because the rest of the schema already complied.

What makes this worth recording beyond the fix: TASK-0016's own test
`counterexample.schema.test.sh` passed. It validates the schema's SHAPE — that
the fields exist and that a malformed counterexample is rejected — and never
asks whether the provider will accept the schema. A contract that the consumer
refuses is not a valid contract, and shape-checking it locally cannot discover
that. This is the same lesson as TASK-0016's own contract correction: a gate
that cannot exercise the real path is not a gate.

TASK-0016 is merged to `dev`, is still IN_PROGRESS, and has never been
independently reviewed — and the reason it cannot be reviewed now is the defect
it introduced. It disabled the mechanism that would have caught it.

**Fix mechanism (TASK-0017).** The two nodes now list every property in their
`required` arrays, and genuinely optional fields (`counterexample` on a finding;
`content`, `find`, `replace` on a file entry) are optional by a nullable type,
never by omission — the meaning is unchanged: a finding may still carry no
counterexample, and a file entry still supplies either full content or a
find/replace pair. A new test (`aiteam/tests/review-schema-strict.test.sh`)
walks the WHOLE schema tree and fails if any object's `required` does not cover
its `properties`, so the next field someone adds cannot silently reintroduce
this. The walk is proven capable of failing: a fixture copy of the schema with a
key removed from a `required` array is rejected by the same check.

## H-013 — Project test names are matched as provider-fault signals

**Status:** fixed 2026-08-25 by TASK-0017. Severity was HIGH. Observed
2026-08-24 on the same run as H-012.

The 400 above was reported to the operator as:

    the reviewer 'gpt-5.6-sol' is out of credit or not entitled on this account.
    ... Top up the reviewer's account, then re-run this task unchanged.

Nothing was wrong with the account. `review.sh:164` classifies provider faults by
grepping the RUN LOG for `401|403|429|quota|credit|billing|insufficient|...`. The
run log contains the prompt; the prompt contains the last 100 lines of
`verify.log`; and this project has a passing test named:

    ✓ login rate limiting against real postgres > 429 carries Retry-After

That test NAME was the only match in the entire log — one occurrence, from
output proving the code works. A passing test made a schema rejection read as a
billing problem.

The advice it produced is actively harmful in both directions: it tells the
operator to spend money fixing an account that is fine, and to "re-run this task
unchanged", which will fail identically forever because the cause is a static
schema. It also violates this harness's own rule that a provider fault must be
distinguishable from a verdict — here a THIRD category, a malformed request, was
folded into the fault bucket and given the wrong remedy.

Note the coupling this reveals: `aiteam/` is meant to be domain-free, but its
fault classifier reads project test output as if it were provider diagnostics.
Any repository with a test named for an HTTP status or the word `quota` inherits
this.

**Fix mechanism (TASK-0017).** `review.sh` now classifies failures from the
PROVIDER'S OWN RESPONSE only — the structured error objects the runner itself
emits (codex's `ERROR: {json}` blocks carrying an HTTP status and error type;
Command Code's `{"type":"result","subtype":"error",...}` and `run_error`
events) — never from words elsewhere in the log. A log whose failure cannot be
attributed to the provider is reported as the generic "could not be reached"
fault, never as a billing problem, because that is the one whose remedy costs
the operator money. Three outcomes are now distinguishable in what the operator
is told to do next: a **malformed request** (a 4xx invalid-schema or bad
parameter response — the fix belongs in this repository and re-running
unchanged cannot succeed), a **credit or entitlement failure** (a real 429 or a
`MODEL_NOT_IN_PLAN` in the provider's own response — top up and re-run
unchanged), and **unreachable** (check the provider). The classifier is covered
by `aiteam/tests/review-fault-classification.test.sh`, which asserts the green
test-name case is not a provider fault, the 400 invalid-schema case is a
malformed request, and a genuine entitlement failure is still a credit problem.
The 429 test-name case is described only in generic terms — a project test
named for an HTTP status — because a fault classifier that knows anything about
the reviewed project is the coupling this entry records.

## H-014 — The counterexample runner override cannot be set

**Status:** fixed 2026-08-25 by TASK-0017. Severity was medium. Observed
2026-08-24 creating TASK-0017.

`aiteam/bin/counterexample.sh:43` reads the per-task runner override:

    runner="$(task_get "$id" '.counterexample_runner // empty')"
    [ -n "$runner" ] || runner="./node_modules/.bin/vitest run"

`aiteam/contracts/task.schema.json` declares `additionalProperties: false` and
does not list `counterexample_runner`, so a task that sets it is REJECTED at
creation:

    - : unexpected property "counterexample_runner"

The field is unreachable. Every counterexample therefore runs under the vitest
default, which is correct for the application's tests and wrong for the
harness's own, which are shell scripts — so a finding against `aiteam/**` can
never have its counterexample executed. That is the reverse of what TASK-0016
was built for: the tasks whose reviewer most needs executable evidence are the
ones that cannot get it.

Third defect from TASK-0016 found without a review, after H-012 and H-013. All
three are the same shape: a piece was added and the thing that VALIDATES it was
not, so the addition passed its own tests while being unusable in the real path.

**Fix mechanism (TASK-0017).** `aiteam/contracts/task.schema.json` now declares
`counterexample_runner` (a string or null) alongside `mutation_runner`, which
`bin/mutate.sh` reads with the same shape and which had the same unreachability
defect. A task contract that sets the field is accepted by `task.sh new`, and
`bin/counterexample.sh` uses the value it sets instead of the vitest default.
`aiteam/tests/review-schema-strict.test.sh` asserts that every task field the
harness reads through `task_get` is declared in the schema, so the next reader
added without a contract entry is caught rather than silently dead.

## H-017 — A re-run counterexample cannot say why it was refuted

**Status:** open, medium severity. Observed 2026-08-25 remediating TASK-0014
round 7.

`counterexample.sh` records CONFIRMED when a test behaves as the reviewer
predicted and REFUTED when it does not. That reading is correct exactly once —
on the tree the reviewer judged. Re-run the same counterexample after the
finding is FIXED and the outcome necessarily inverts: the escape no longer
stays green, so the prediction no longer holds, and the tool reports

    2 counterexample(s) were REFUTED — the reviewer's prediction did not hold
    on this tree

which reads as "the reviewer was wrong" when it means "the reviewer was right
and the defect is now closed". Both readings produce identical output, and the
difference between them is the entire question the run was asked.

Re-running after remediation is the natural check, and the strongest one
available: the escape that proved the defect is the same escape that proves the
fix. So this is not a misuse to be discouraged — it is the tool's best use, with
no way to record which phase it is in.

**Fix belongs in** `aiteam/bin/counterexample.sh`: take the phase explicitly
(the tree being judged versus the tree after remediation) and report the second
as something like CLOSED rather than REFUTED, or record against each finding the
outcome observed when it was first attached, so a later inversion can be
reported as the fix landing rather than as the reviewer being contradicted.

## H-018 — Every find/replace counterexample is misread as a file addition

**Status:** open, HIGH severity. Observed 2026-08-25 reviewing TASK-0019.

`counterexample.sh:133` decides whether an entry adds a file or edits one with

    if printf '%s' "$e" | jq -e 'has("content")'

`has()` is true whenever the KEY EXISTS, regardless of its value. TASK-0017 fixed
H-012 by making the schema strict-mode compliant, which requires every declared
property to appear in `required`; optional fields became nullable rather than
absent. So `content` is now present as `null` on every file entry, `has("content")`
is always true, and every entry takes the ADD path.

The result: an edit whose target exists — which is what an edit means — is
rejected with "already exists, so it could not be added" and the finding is
recorded INCONCLUSIVE. **The edit path is dead. Only counterexamples that add
new files work at all.**

Two harness changes, each correct alone, combining into a defect neither could
show on its own. H-012's fix was right; this discrimination was written against
a schema where absence meant optional, and nothing re-checked it.

Already miscounted once: TASK-0014 round 7 recorded finding 38 INCONCLUSIVE with
`api/src/jobs/routes.ts already exists, so it could not be added`. The reviewer's
counterexample was well formed — one find/replace entry on an existing file plus
two added probe files — and the runner misclassified it. The orchestrator
reported that as the reviewer's counterexample being inapplicable, which was
wrong, and said so in the pull request for that task. The finding was verified by
hand instead and did hold.

This also means the INCONCLUSIVE outcome is doing double duty: it currently means
both "the counterexample genuinely did not apply" and "the runner could not tell
an edit from an addition", and the operator cannot distinguish them.

**Fix belongs in** `aiteam/bin/counterexample.sh`: choose the path by VALUE, not
key presence — an entry is an addition when `content` is a non-null string, an
edit when `find` is a non-null string, and malformed when both or neither are
set. A test should assert an edit against an existing file applies, since the
current tests pass while the edit path cannot run.

## H-019 — A counterexample may write outside the worktree

**Status:** open, HIGH severity. Found 2026-08-25 by review of TASK-0020; the
defect is older and is present in the merged code.

`counterexample.sh` reads a counterexample entry's `path` and uses it directly:

    path="$(printf '%s' "$e" | jq -r '.path')"
    ...
    printf '%s' "$content" > "$workdir/$path"

Nothing constrains it to the worktree. `../../` sequences walk out of the tree,
and the harness applies whatever the entry names, so a counterexample can create
or edit files anywhere the harness account can reach — including the main
checkout, another task's worktree, or `.aiteam/` state that no agent is ever
allowed to write.

The path is authored by the REVIEWER. The reviewer is deliberately sandboxed
read-only precisely so it cannot edit what it judges, and this hands its output
straight to a writer with no boundary check. Restoration is by `git checkout`
of touched paths plus removal of added files inside the worktree, so a write
that landed outside is not restored either — it persists after the run reports
a clean tree.

Nothing has exploited this. It is recorded because the property the whole
sandbox exists to guarantee is not actually enforced at the point it matters.

Related, and found in the same review: an edit whose `replace` is null writes
the four characters `null` rather than deleting the anchor, because `jq -r`
renders JSON null as that text. That is the SAME interaction as H-018 one field
over — the strict-mode schema made optional fields present-and-null, and more
than one consumer was written against a schema where absence meant optional.
Whoever fixes this should look for the third.

**Fix belongs in** `aiteam/bin/counterexample.sh`: reject any entry whose path is
absolute, contains a `..` component, or whose resolved location is not inside the
worktree — before anything is written, and as a refusal rather than a skip.

## H-020 — TASK-0020 is parked unmerged; H-018 and H-019 remain open

**Status:** open. Decided 2026-08-25 after seven attempts and five review rounds.

TASK-0020 set out to fix H-018 (every find/replace counterexample misread as an
addition) and grew to cover H-019 (a counterexample may write outside the
worktree) plus fifteen review findings. Its branch is NOT merged and should not
be merged as it stands.

**Why it is parked.** The rollback journal added to make restoration safer
introduced a data-loss defect: it records every parent component of an added
path as if this run created it. An addition under `.git/` therefore records the
worktree's existing gitfile as created-by-this-run, `os.mkdir` raises on it, and
cleanup unlinks it — after which git cannot read the worktree, every restore and
status command returns empty, and the run reports success over a destroyed
checkout. Three consecutive attempts to fix that one block edited test files
instead and left it untouched, including one attempt given the defective code
verbatim alongside the replacement shape.

**What this means for the trunk.** `dev` does not carry the journal, so the
`.git` defect is not live anywhere. What IS live on `dev` is what was live
before: H-018, so only add-style counterexamples work and every find/replace one
returns INCONCLUSIVE; and H-019, so a counterexample path is not confined to the
worktree. Both are recorded above and neither blocks product work — the tool is
a convenience for reviewing, and the counterexamples that mattered most so far
were add-style and ran correctly.

**The judgement, recorded so it can be disagreed with.** This work was stopped
because it stopped paying. Fifteen findings in five rounds, three of those
rounds closing part of one property and leaving another part, and two rounds
whose own fixes introduced the next round's findings. The task's five acceptance
criteria were independently confirmed met; what could not be reached was a
rollback path that is safe under hostile input. A convenience tool is the wrong
place to spend that.

**If it is resumed:** take the branch's classifier, confinement and decoders,
which are correct and independently reviewed, and drop the journal. Record a
created component only after the mkdir that created it succeeded, never by
pre-walking the path, and never unlink a path this run did not create.

## H-021 — Provider streams truncate mid-response and exhaust the retry budget

**Seen:** TASK-0022 attempts 3, 4, 5, 6, 7 and 9, 2026-08-27, against
deepseek-v4-flash.

Runs end with the agent process exiting 130 partway through the work. The run
log records the real cause in the provider's own events:

    {"type":"api_retry","error":"Stream ended unexpectedly before completion
     (no finish event) — response was truncated"}

The CLI retries — up to 3 `stream_restart`s and several `api_retry`s with
exponential backoff (1000ms, 1600ms, 3200ms) — and exits when they exhaust.
`discardedVisibleContent: true` on a restart means the partial response is
thrown away, so a restart late in a turn loses that turn's reasoning.

**What it is not.** Not the watchdog: that sends SIGTERM (143) and logs
`killing the agent`, neither of which appears. Not the follow window: attempts
ran with it both enabled and disabled and failed identically. Not credit
exhaustion or rate limiting: no 429, quota, balance or rate-limit error appears
in any log.

**It degrades within a session.** Successive runs on the same task were cut off
progressively earlier — 46MB, 8.4MB, 6.8MB, 2.8MB, 1.9MB of run log — which
suggests provider-side load rather than anything local. A run that completes
once is not evidence the next one will.

**Why it costs more than the run.** An interrupted agent that changed nothing
leaves the attempt void, correctly, since verifying it would describe the
previous attempt's code. Six interruptions across nine attempts produced four
usable commits.

**The workaround that works.** Instruct the agent to implement and commit the
first independent tranche BEFORE anything else, and forbid exploratory work at
the start of a run. Attempts 5, 6 and 8 survived because they had banked a
commit; attempt 7 opened with an environment investigation, was cut off, and
committed only a useless probe. Long remediations should be ordered into
independently committable steps, smallest first, and say so explicitly.

**Where the fix belongs.** Nothing here is fixable in the harness — the stream
dies upstream. What the harness could do better is surface the provider's own
error to the operator instead of only the exit code: the truncation message is
in the run log, but the dispatch reports a bare `exited 130`, which reads as a
local signal and sent this investigation the wrong way twice.

---

## H-022 — `max_turns` exhaustion is misreported as a provider outage

**Seen on:** TASK-0023 attempt 6 (`.aiteam/runs/TASK-0023-20260828T105718Z.log`).

The dispatch reported `'deepseek-v4-flash' was unreachable or never answered —
a provider fault`. The provider had answered continuously for 24 minutes. The
log's own final record says otherwise:

```
"type":"result","subtype":"max_turns","stopReason":"max_turns",
"usage":{"inputTokens":47182339,...},"durationMs":1447307
Warning: Reached maximum conversation turns (280).
```

**Why it is misclassified.** `implement.sh:565-590` decides a run was a provider
fault from the exit status plus "did it change files". An agent that spends its
whole budget exploring and never edits anything satisfies both conditions, so a
budget exhaustion is indistinguishable from an outage — and the code then rolls
back the attempt counter and offers a fallback model, both of which are the
right response to an outage and the wrong response to this.

**Why the distinction matters.** They call for opposite actions. An outage
should be retried unchanged. An exhausted turn budget should never be retried
unchanged: the same prompt will explore the same way and exhaust the same
budget, costing another 24 minutes and 47M input tokens to learn nothing. The
correct response is to make the task prescriptive, raise `default_max_turns`, or
split it.

**How to tell them apart.** The last line of the run log carries
`"subtype":"max_turns"` or `"stopReason":"max_turns"`. A genuine transport
failure carries the H-021 truncation message instead. Both are already on disk;
neither reaches the operator.

**What provoked it.** The finding asked the agent to establish how Next.js
behaves when an instrumentation hook throws — a diagnostic task. This is the
H-021 exploration pattern in a second guise: prescriptive findings land work,
diagnostic ones burn the run. The reviewer had ALREADY done that investigation
and cited the file and line numbers in its finding; the orchestrator passed the
question along instead of passing the answer.

**Where the fix belongs.** `implement.sh`, in the same block that decides
`provider_fault`: read the result record's `subtype`/`stopReason` and report
budget exhaustion as its own outcome — no fallback model, no attempt-counter
rollback, and a message naming the turn limit.

---

## H-023 — A consulted waiver announces itself only on the failure path

**Seen on:** TASK-0023, `REVIEW -> VERIFIED`.

`gate_review_verdict_pass` (`task.sh:217-224`) falls through to `gate_waiver`
when the verdict is not PASS, and `gate_waiver` prints
`waived by <who> -> carried to <task>: <reason>`. But the gate runner shows a
gate's captured output only when it FAILS. On success it prints a bare green
tick, so the transition read:

```
  ✓ review_verdict_pass
  ✓ all_acceptance_criteria_met
TASK-0023: REVIEW -> VERIFIED
```

Nothing on screen distinguishes that from a genuine PASS. The recorded verdict
in `review.json` was `FAIL` with an open high-severity finding.

**Why it matters.** The waiver's stated purpose is that "accepted" can never
quietly mean "forgotten" — it is deliberately expensive to grant for exactly
that reason. An announcement that is visible only when the waiver is absent
inverts that: the one moment the operator most needs to see it is the moment it
is suppressed. An operator scrolling a long run has no signal that a task
reached VERIFIED over a failing review.

**Where the fix belongs.** `task.sh`, in the gate runner: print a gate's output
on success too when a waiver was consulted, or have `gate_waiver` write to
stderr so it bypasses the capture. The tick should read differently — e.g.
`✓ review_verdict_pass (WAIVED)` — so the transition line cannot be mistaken
for a clean pass.
