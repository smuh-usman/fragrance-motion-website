# Workflow: Refactoring

```
ESTABLISH SAFETY NET → REFACTOR IN STEPS → VERIFY EACH STEP → REVIEW → COMPLETE
```

## The safety net comes first

Refactoring means changing structure without changing behaviour, which is only
checkable if behaviour is already covered. If the code being restructured has no
tests, the first task is writing characterization tests that capture what it
currently does — including the parts that look wrong. Preserve the behaviour
first; fix it in a separate, visible change afterwards.

Refactoring untested code is not refactoring. It is rewriting and hoping.

## Behaviour changes are not allowed here

If a behaviour change is needed, it is a different task with its own acceptance
criteria. Mixing the two produces a diff where the reviewer cannot tell which
changes were meant to be invisible, which is exactly when regressions slip past.

## Small steps, verified

Each step keeps the suite green. A refactor that leaves the codebase broken
between steps cannot be interrupted, reviewed or abandoned safely.

## Scope

Declare the file scope tightly. Refactors sprawl by nature, and a sprawling diff
is one nobody reviews properly.

## Review

The reviewer's question here is narrow and specific: does this change behaviour
anywhere? Not "is this nicer" — that was the premise. Point them at the parts
where structure changed enough that equivalence is not obvious.
