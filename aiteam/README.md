# The AI engineering team

A portable multi-model engineering harness. Copy `aiteam/` into any repository,
run `install.sh`, and you have an orchestrator, an implementation workforce, an
independent reviewer, and a lifecycle that will not let work reach DONE without
evidence.

Nothing in this directory knows anything about any particular product. That is
the point, and there is a check that enforces it.

---

## 1. What is reusable and what is not

**Reusable — this directory. Copy all of it.**

| Path | What it is |
|---|---|
| `config/models.json` | Which model handles which kind of work, and the escalation ladder |
| `config/providers.json` | How each model is actually invoked, verified against real CLIs |
| `config/policy.json` | Risk tiers, review triggers, evidence gates, secret patterns |
| `roles/` | Ten role prompts. Model-agnostic and domain-free |
| `lenses/` | Overlays that add specialist attention to any role |
| `workflows/` | Generic lifecycles for the orchestrator |
| `contracts/` | Task and review schemas |
| `bin/` | The scripts that enforce everything above |
| `claude/` | Native Claude Code subagents, skills and hooks |
| `install.sh`, `doctor.sh` | Setup and health check |

**Project-specific — do not copy.**

| Path | What it is |
|---|---|
| `CLAUDE.md` | Instructions for this product |
| `docs/` | Requirements, domain model, architecture, decisions |
| `.aiteam/project.json` | Verification commands and branch name for this repo |
| `.aiteam/tasks/`, `.aiteam/evidence/` | This project's task graph and its proof |
| application source | Obviously |

The entire coupling between the two layers is one generated file,
`.aiteam/project.json`. That is what makes the harness portable: the generic side
knows how to run *a* test command, never *this* test command.

---

## 2. Using it in a new repository

```bash
cp -r aiteam/ /path/to/new-project/
cd /path/to/new-project
git init && git commit --allow-empty -m "initial"   # worktrees need one commit
./aiteam/install.sh
```

`install.sh` creates `.aiteam/`, guesses this project's verification commands into
`project.json`, installs the Claude subagents and skills, allowlists the provider
CLIs so dispatch does not prompt on every call, and runs `doctor.sh`.

**Then edit `.aiteam/project.json` by hand.** The guessed commands decide what
"passing" means for every task in the project, so they are worth five minutes of
attention. A wrong test command means every gate passes vacuously.

---

## 3. The team

| Agent | Model | Runner | Does |
|---|---|---|---|
| Orchestrator | Opus 5 | the Claude Code session | Plans, decomposes, routes, adjudicates, accepts |
| Implementer | DeepSeek V4 Flash | `cmd` (Command Code) | Writes code and tests in an isolated worktree |
| Reviewer | GPT 5.6 Sol | `codex` read-only | Independent verdict on high-risk work |
| Researcher | GPT 5.6 Terra | `codex` read-only | Read-only investigation |
| Chore | Haiku 4.5 | native subagent | Mechanical edits with no decisions in them |

Roles (`roles/*.md`) are separate from models. A role is a description of how an
engineer behaves; a model is who executes it. Any role can run on any dispatchable
model, which is why re-routing is a config edit rather than a rewrite.

**Claude Code cannot run non-Claude models as native subagents.** DeepSeek and Sol
are separate processes launched over the shell. The harness is built around that
fact rather than pretending otherwise.

---

## 4. Configuring model providers

`config/providers.json` holds an `argv` template per model with placeholders the
dispatcher substitutes: `{WORKDIR}`, `{SCHEMA_FILE}`, `{OUTPUT_FILE}`,
`{MAX_TURNS}`, `{PROMPT_FILE_STDIN}`.

To add a provider, add an entry under `providers` and one under `models`:

```json
"models": {
  "my-model": {
    "provider": "myprovider",
    "role_class": "implementer",
    "dispatchable": true,
    "writes_files": true,
    "requires_isolation": true,
    "argv": ["mycli", "--headless", "{PROMPT_FILE_STDIN}", "--dir", "{WORKDIR}"],
    "timeout_seconds": 2700
  }
}
```

`writes_files` is enforced, not documentation: `review.sh` refuses to run a review
with a model that can write, because a reviewer able to edit the code it judges
can quietly fix instead of reporting, which destroys the independence the step
exists to provide.

Two environment findings worth preserving if you swap CLIs. Command Code needs
`--yolo` to write files headlessly — `--permission-mode auto-accept` silently
isn't enough — which is why writing agents are confined to worktrees. And Codex
defaults `model_reasoning_effort` to `none`, so the reviewer forces it to `high`;
without that it skims.

---

## 5. Changing model routing

Edit `config/models.json`. The `routing` block maps work types to models; the
`escalation` block is the ladder followed when a task keeps failing.

```json
"routing": { "implementation": { "model": "deepseek-v4-flash" } }
```

Model names must exist in `providers.json`. `doctor.sh` verifies every routed name
resolves, so a typo is caught before it wastes a dispatch.

The escalation ladder promotes the model on repeated failure and ends at the
orchestrator, which stops rather than dispatching again. Repeated failure usually
means the task contract was wrong, and running it a fifth time does not fix a
specification.

---

## 6. Adding a new agent

1. Write `roles/<name>.md`. Describe how that engineer thinks and what they are
   accountable for. Do not mention any product, and do not mention a model.
2. Add the name to `assigned_role`'s enum in `contracts/task.schema.json`.
3. Route it in `config/models.json` if it needs a model other than the default.

That is the whole procedure. `implement.sh` composes
`roles/_common.md` + `roles/<role>.md` + any lenses + the task contract, so a new
role is picked up with no code change.

For a **lens** instead — an overlay adding specialist attention to existing roles
— write `lenses/<name>.md` and add it to the `lens` enum in the task schema.

---

## 7. Adding a new workflow

Write `workflows/<name>.md` describing the sequence the orchestrator should
follow. Workflows are instructions to the orchestrator, not executable code —
they exist so a lifecycle is written down once instead of improvised each time.

If the workflow needs a new *mechanism* rather than a new sequence, that is a
script in `bin/`. Follow the existing shape: source `_lib.sh`, read state from
`.aiteam/`, and write evidence rather than returning claims.

---

## 8. Adding project-specific instructions

Three places, in order of preference:

**`CLAUDE.md`** at the repository root, for things that apply to all work in this
project — its architecture, conventions, and the rules the orchestrator must
respect.

**`docs/`** for the substance: requirements, domain model, security model,
decisions. Tasks reference these by path in their `context` array, and
`implement.sh` pastes them into the agent's prompt. A headless agent that has to
go hunting for context often doesn't, and invents the contract instead.

**The task contract itself** for anything that applies to one task only.

Never edit a file under `aiteam/` to add project knowledge. That is the exact
mistake this structure exists to prevent, and there is a check for it.

---

## 9. Keeping domain assumptions out of the generic layer

The rule: **files under `aiteam/` may not contain project vocabulary.**

Project knowledge reaches an agent through the task contract's `context` array,
which is per-task and per-project. Generic roles stay generic because they never
learn what the product is; they learn what good engineering is, and read the
product from a document.

Enforced by:

```bash
./aiteam/bin/lint-generic.sh
```

which greps `roles/`, `lenses/`, `workflows/` and `config/` for the terms in
`.aiteam/domain-terms.txt` and fails if any appear. Add your project's nouns to
that file when you start a project. Run it in CI, or before copying the harness
onward.

The failure mode it catches is gradual and quiet: someone adds "remember that
attempts are immutable" to `roles/backend.md` because it was convenient once, and
six months later the harness silently carries an assessment platform's assumptions
into an accounting system.

---

## 10. The lifecycle

```
BACKLOG → READY → ASSIGNED → IN_PROGRESS → TESTING → REVIEW → VERIFIED → MERGED → DONE
                                  ↑                     ↓
                                  └─── CHANGES_REQUESTED ┘
```

Transitions are gated by evidence on disk, defined in `config/policy.json` and
enforced in `bin/task.sh`:

| Transition | Requires |
|---|---|
| `IN_PROGRESS → TESTING` | A non-empty diff, entirely inside the declared file scope |
| `TESTING → REVIEW` | A verification log with exit 0, and no drop in test count |
| `REVIEW → VERIFIED` | A schema-valid `PASS` verdict with every criterion met, or a waiver |
| `VERIFIED → MERGED` | Rebased onto the default branch and re-verified afterwards |
| `MERGED → DONE` | Documentation updated when the risk tier requires it |

None of these ask an agent anything. The test-count check exists because the
cheapest way to make a suite green is to delete the test that fails.

### Maintaining the harness itself

An ordinary task may never write under `aiteam/` or `.aiteam/` — the scope gate
treats either as a hard violation that voids the attempt, because the harness is
what judges the task and an agent that can rewrite its acceptance machinery
invalidates every guarantee. That rule made the harness impossible to maintain by
an agent, and the only maintainer available was an agent, so the rule got routed
around rather than respected. The exemption is the explicit, narrow, reviewed
replacement for routing around it.

It is a contract field, declared only in the schema, and it is never inferred
from the file list, the title, or anything else:

```json
"harness_task": true
```

Its absence means `false` — a task that does not declare it is treated exactly as
every task is today. Declaring it makes writes under `aiteam/**` (harness
*code*) a normal path, judged by the same `files.expected` globs as anything
else: the exemption widens **which paths may be listed, never the list itself**,
and a harness task that edits a file it did not declare is still a violation.

What it never permits, because both are the machinery of judgement rather than
code:

- **`.aiteam/**` is harness state** — findings, rejection counts, lifecycle
  transitions, recorded verdicts. No contract field lifts this, because an agent
  that can write there can retire its own findings and drive its own transitions.
- **Skipping review.** A harness task cannot reach a merged state without
  independent review. The transition gate refuses the skip path even when
  `review.required` reads false; it is not trusted to the contract author to
  have switched review on.

Every use of the exemption is recorded: when a harness task passes the scope gate
with `harness_task: true`, its history notes that harness code was written under
the declared exemption, naming the files. The privilege is rare by design, so
every use is visible and auditable afterwards.

### Waivers

Sometimes the owner accepts work a reviewer failed. Without a way to record
that, the only routes past the review gates are to edit the verdict or to delete
the gate — and a harness whose easiest escape is dishonesty will eventually be
escaped dishonestly. A waiver is that decision, recorded:

```json
"waiver": {
  "accepted_by": "who decided",
  "reason": "why the remaining findings are acceptable now",
  "waived_to": "TASK-0042"
}
```

It never touches the verdict, the findings or the unmet criteria — those stay
exactly as the reviewer wrote them, and the gate prints the waiver every time it
consults one. All three fields are required, and `waived_to` must name a task
that exists and is not yet finished, because a waiver without a destination is
how "deferred" quietly becomes "dropped".

---

## 11. Risk and review

Risk is computed by `bin/classify.mjs` from the paths a task declares and the tags
it carries — including words in its title and objective, so a task about tokens is
high risk whether or not anyone remembered to tag it. A task declaring lower risk
than computed is rejected at creation. Higher is always allowed.

High risk means mandatory independent review under the security lens: anything
touching authentication, authorization, sessions, tokens, crypto, migrations,
concurrency, state machines, scoring, timers, submissions or exports.

Low risk means automated verification plus the orchestrator reading the diff. It
never means unreviewed.

### Counterexamples: the reviewer describes, the harness runs

The reviewer is read-only by design, and the sandbox denies the container socket,
so most of the tests it judges are unrunnable for it. Every review therefore has
been a diff-reading judgement. A finding can carry a structured **counterexample**
to close most of that gap: the files to add or edit, the single test to run, and
whether that test is expected to PASS or FAIL once applied.

`bin/counterexample.sh <id>` applies each open finding's counterexample in the
task's worktree, runs only the named test, and records the outcome per finding in
the evidence directory:

- **CONFIRMED** — the test behaved exactly as the reviewer predicted. Expecting a
  PASS is the normal case for a finding that says an analysis misses something:
  the sweep staying green with the counterexample in place is what proves the
  miss.
- **REFUTED** — the counterexample applied but the test did not behave as
  predicted.
- **INCONCLUSIVE** — the counterexample never applied: an anchor did not match, an
  added file collided with an existing path, or the test filter matched nothing.
  A counterexample that leaves the tree unchanged must never read as the reviewer
  being wrong, so the tree is proven changed before any conclusion is drawn.

Restoration is by `git checkout` of every touched path plus removal of every
added file, and the worktree is asserted clean before the script exits — a crash
mid-run cannot leave a counterexample applied to be committed as if it were the
agent's work.

The runner defaults to the project's vitest (`./node_modules/.bin/vitest run`).
A task whose tests need a different runner — a finding against the harness
itself, whose tests are shell scripts — names it in the task contract's
`counterexample_runner` field (a string, or null), and `bin/counterexample.sh`
uses that instead of the default.

The results reach the next implementation prompt as executed evidence: a
CONFIRMED finding is presented as a reproduced defect, a REFUTED or INCONCLUSIVE
one as explicitly not proven. The reviewer's sandbox is untouched throughout — it
describes, the harness executes.

---

## 12. Isolation

Every writing task gets its own worktree and branch. Implementers run under
`--yolo`, which bypasses every permission prompt including shell execution — the
worktree is the containment boundary that makes that acceptable, not a tidiness
measure.

`schedule.sh` refuses to run two tasks concurrently when their declared file
globs intersect. Integration is serial and always the orchestrator's: each branch
rebases onto the current default branch and re-runs verification before merging.

Merge conflicts are never handed back to an implementer. An agent resolving a
conflict without understanding the other side's intent is precisely the silent
overwrite the isolation model exists to prevent.

---

## 13. Known issues

Defects in the harness itself are recorded in `KNOWN-ISSUES.md`, with the ones
that can produce a misleading gate result called out as such. A harness that
hides its own weak points is asking to be trusted on its word, which is the
single thing it exists to stop doing.

---

## 14. What this harness will not do

It will not tell you work is finished because an agent said so. Every gate reads
a file that a process wrote, and when a loop exhausts itself it stops and says
why rather than degrading into a pass.

It will not stop you writing a bad task. The schema catches vagueness — a missing
acceptance criterion, an absent verification command — but a task with precise
criteria describing the wrong thing will be implemented, verified and merged
exactly as specified. Task quality is the orchestrator's job, and it is the part
of this system with no automated check.
