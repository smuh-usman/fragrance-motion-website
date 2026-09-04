# Workflow: Bug fixing

```
REPRODUCE → DIAGNOSE → REGRESSION TEST → FIX → VERIFY → REVIEW (if risk warrants) → COMPLETE
```

## Reproduce first, always

No fix is dispatched before the bug is reproducible. A fix for a bug nobody can
reproduce cannot be verified, and "it seems better now" is how bugs come back.

If reproduction fails, that is the result: record what was tried and what was
ruled out, and stop. Guessing at a fix from a description wastes an agent and
adds an unexplained change to the codebase.

## Diagnose before fixing

Diagnosis is orchestrator work, or the debugger role — not routine implementation.
The mechanism must be explained before anyone edits anything: which value was
wrong, where it came from, why the code produced it.

Be suspicious of a fix nobody can explain. Added null checks, swallowed exceptions
and retry loops usually move a bug rather than remove it.

## The regression test comes before the fix

Write the test, watch it fail against the unfixed code, then fix. Confirming the
failure first is what proves the test captures this bug rather than something
adjacent. A regression test that never failed protects nothing.

## Scope discipline

Fix the cause and nothing else. A debugging task that grows into a refactor
becomes impossible to review, and reviewability is what makes the fix
trustworthy. Note the refactor as a separate task.

## Look for siblings

Once the mechanism is understood, search for the same shape elsewhere. Defects
that came from a pattern usually have copies. Report what you find even when
fixing it belongs to another task.

## Risk

Inherit the risk of the code being changed, not the size of the diff. A one-line
change to an authorization check is high risk; a hundred-line change to a
stylesheet is not.
