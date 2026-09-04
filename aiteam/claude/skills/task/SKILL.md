---
name: task
description: Author, inspect and drive engineering tasks through the AI team harness. Use when creating a task contract, checking task status, dispatching implementation to the external workforce, requesting independent review, or integrating finished work.
---

# Working the task harness

The harness lives in `aiteam/`. Its runtime state lives in `.aiteam/`. Every
command below is run from the repository root.

## Before anything else

```bash
./aiteam/doctor.sh
```

Confirms the CLIs are present and authenticated, the routed models resolve, and
the reviewer is genuinely read-only. Run it after copying the harness into a new
repo, and whenever a dispatch fails for reasons that smell environmental.

## Authoring a task

Write the contract to a file, then create it:

```bash
./aiteam/bin/task.sh new /tmp/task.json
```

The schema rejects a task that cannot state how it will be proven correct: it
needs at least one acceptance criterion carrying `verified_by`, explicit
`verification` commands, and a `files.expected` scope.

The risk classifier then recomputes risk from the declared paths, tags, title and
objective. A task declaring less risk than computed is refused — this is what
stops the review of sensitive work being quietly downgraded. Declaring more is
always allowed.

A minimal contract:

```json
{
  "title": "Implement <specific behaviour, not a subsystem>",
  "objective": "What must be true when this is finished.",
  "context": ["docs/relevant.md"],
  "risk": "medium",
  "acceptance_criteria": [
    { "id": "AC1", "statement": "Observable behaviour, stated precisely",
      "verified_by": "test:path/to/file.spec.ts::name of the test" }
  ],
  "files": { "expected": ["src/module/**"], "forbidden": ["src/other/**"] },
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": ["npm test -- module", "npm run typecheck"],
  "review": { "required": true },
  "status": "READY"
}
```

## Running work

```bash
./aiteam/bin/run.sh TASK-0001              # full lifecycle for one task
./aiteam/bin/run.sh TASK-0001 --no-handoff # stop before preparing the branch
./aiteam/bin/schedule.sh TASK-0001 TASK-0002 TASK-0003
```

`run.sh` implements, verifies, retries with an escalated model on failure,
reviews when the risk tier requires it, remediates on a failed review carrying
the findings verbatim, then rebases and re-verifies the branch.

It stops at VERIFIED. The harness never merges — integration is a human
decision. Open the pull request yourself; once it is merged, record it with
`worktree.sh confirm-merged`, which refuses unless the branch really is an
ancestor of the base branch.

`schedule.sh` runs several tasks concurrently, deferring any whose file scopes
overlap, then prepares each branch for its own pull request.

## Inspecting

```bash
./aiteam/bin/task.sh list            # everything
./aiteam/bin/task.sh list REVIEW     # by state
./aiteam/bin/task.sh next            # READY tasks whose dependencies are DONE
./aiteam/bin/task.sh show TASK-0001
```

Evidence for a task is under `.aiteam/evidence/<id>/`: the prompt it was given,
the diff, the verification log and exit code, and the review verdict. Raw agent
transcripts are in `.aiteam/runs/`.

## When something fails

Read the evidence rather than re-running. `verify.log` holds real output;
`review.json` holds the verdict with per-criterion evidence and findings.

A task that exhausts its attempts or is rejected twice stops and stays in a state
showing why. That is the design — the loop refuses to reach DONE by suppression.
The usual correct response is to re-scope the task, not to run it again.

## Individual steps

```bash
./aiteam/bin/worktree.sh create TASK-0001
./aiteam/bin/implement.sh TASK-0001 [--model M]
./aiteam/bin/verify.sh TASK-0001
./aiteam/bin/review.sh TASK-0001
./aiteam/bin/task.sh transition TASK-0001 TESTING
./aiteam/bin/worktree.sh handoff TASK-0001
./aiteam/bin/worktree.sh confirm-merged TASK-0001   # after you merge the PR
```
