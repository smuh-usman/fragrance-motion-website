# Workflow: Release

```
FREEZE → VERIFY CLEAN BUILD → MIGRATIONS → SMOKE CRITICAL PATHS → DEPLOY → OBSERVE → ROLLBACK PLAN
```

## Verify from a clean state

Not "it works on the machine where it was built". Clone fresh, install, migrate,
build and start using only the documented commands. Anything undocumented that
turns out to be required is a release blocker, because the next person to deploy
will not have it.

## Migrations

Run against a copy of production-shaped data, not an empty database. Confirm the
ordering is safe in both directions: schema before the code that needs it, and
the old code still working against the new schema for as long as both are live.

## Smoke the critical paths

Enumerate the flows that must work for the product to be worth deploying, and
exercise them end to end against the built artifact. This is the last point where
a broken critical path is cheap.

## Observe after deploying

A deploy is not finished when it completes; it is finished when you have watched
error rates and the critical paths for long enough to believe it. Deploying and
walking away converts a five-minute rollback into an incident.

## Rollback is written down before you need it

The rollback procedure is tested and documented before the deploy, including what
happens to data written by the new version. "We would roll back" is not a plan if
nobody has established that the previous version can read what the new one wrote.
