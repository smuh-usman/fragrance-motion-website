# Lens: Concurrency

Layered onto your role for this task.

Assume every operation you write executes twice, simultaneously, on the same row.

- Is there a read, then a decision, then a write? That sequence is unsafe unless
  the database enforces the invariant — through a transaction with the right
  isolation, a conditional update that fails when the state moved, a lock, or a
  unique constraint that makes the loser fail loudly.
- What does the losing caller see? "Both succeeded and one silently overwrote the
  other" is the failure to design against.
- Is the operation idempotent when retried? Network retries are automatic and
  invisible; the same request will arrive again.
- Does anything depend on operations completing in the order they were sent? They
  will not always.
- Is any state held in process memory that two instances of this service would
  each hold separately? That state must live in the database.

Write a test that runs the operation concurrently and asserts exactly one
succeeded, or that both succeeded with a correct combined outcome. Sequential
tests cannot detect any of this.
