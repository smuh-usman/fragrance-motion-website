# Lens: Performance

Layered onto your role for this task.

- Does this issue one query per item in a loop? That is the defect that appears
  fine with ten rows in a test and fails at ten thousand in production.
- Does every query in this change have an index supporting it? Say which.
- Does anything load an unbounded collection into memory? Paginate or stream.
- Is work being repeated per request that could be computed once?
- Does the response grow without limit as data grows?

Measure rather than assume. If you claim something is faster, say what you
compared and what the numbers were. An unmeasured optimization is a guess that
also cost readability.

Do not optimize what has not been shown to be slow — but do not ship a shape that
obviously cannot scale, because those are different mistakes.
