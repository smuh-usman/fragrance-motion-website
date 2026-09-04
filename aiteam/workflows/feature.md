# Workflow: Feature development

For the orchestrator. Generic — nothing here assumes a domain.

```
DISCOVER → PLAN → DECOMPOSE → ASSIGN → IMPLEMENT → TEST → REVIEW → FIX → VERIFY → COMPLETE
```

## Discover

Read what exists before designing what doesn't. Dispatch the researcher role for
anything that would take you more than a few minutes to establish yourself.

Write down what is ambiguous. Anything that would change the data model, a trust
boundary, the user-visible behaviour, or cost belongs to the human with your
recommendation attached — not to your own judgement. Everything else you decide
and record.

## Plan

State the acceptance criteria for the feature as a whole, in terms of observable
behaviour, before decomposing. If you cannot say how the finished feature would
be demonstrated, you are not ready to break it up.

Decide the vertical slice. A slice that leaves the application runnable is worth
more than a horizontal layer that leaves it broken until the next task lands.

## Decompose

One task per coherent unit of work. Each must state its objective, its file
scope, its acceptance criteria with the test that proves each one, and the
commands that verify it. A task you could not hand to a stranger is not finished
being written.

Order by dependency. Mark which tasks are genuinely independent — meaning their
file globs do not intersect — so they can be scheduled together.

Create them with `task.sh new`. The contract schema rejects vague tasks, and the
risk classifier will refuse a task that declares less risk than its paths imply.

## Assign, implement and test

`run.sh <id>` drives implementation, verification, review and integration for one
task. `schedule.sh <id>...` runs several, deferring any whose file scopes collide.

Do not intervene while a task is running. Read its evidence afterward.

## Review

Risk-based, and the classifier already decided. High-risk work gets independent
review whatever anyone thinks of it. Low-risk work still gets your eyes on the
diff — "no independent review" never means "unreviewed".

## Fix

Failures create work, not exceptions. A failed verification retries with an
escalated model; a failed review produces a remediation attempt carrying the
findings verbatim. When either loop exhausts itself, the answer is usually that
the task was specified wrongly — re-scope it rather than running it again.

## Complete

The feature is done when every task is DONE, the application still runs, the
documentation reflects what was built, and you have looked at the integrated
result rather than only the individual diffs. Passing tasks can still compose
into a broken whole.
