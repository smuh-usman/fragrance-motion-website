#!/usr/bin/env bash
# Counterexample results reach the next implementation prompt as executed
# evidence, and REFUTED or INCONCLUSIVE results are labelled so they are not
# treated as proven defects.
#
#   counterexample.prompt.test.sh
#
# The findings block in the implementation prompt is extended, not replaced: the
# reviewer's findings are still carried verbatim, and the counterexample results
# are rendered alongside them. The test drives implement.sh --dry-run against a
# throwaway task whose findings carry counterexample results in every state, and
# asserts the prompt says the right thing about each.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/repo"
cp -R "$AITEAM_SRC" "$sandbox/repo/aiteam"
cp -R "$AITEAM_SRC" "$sandbox/repo/aiteam-test"   # second copy so the prompt never bleeds

# implement.sh --dry-run still resolves and creates the task's worktree, so the
# fixture repo needs the real layout: a .aiteam/project.json naming the default
# branch, a committed tree on that branch, and a worktree created by the harness
# itself. The worktree content never matters — the prompt is built before any
# dispatch and never runs tests.
mkdir -p "$sandbox/repo/.aiteam"
printf '{"default_branch":"dev"}\n' > "$sandbox/repo/.aiteam/project.json"
mkdir -p "$sandbox/repo/src"
printf 'code\n' > "$sandbox/repo/src/a.ts"
printf 'readme\n' > "$sandbox/repo/README.md"
git -C "$sandbox/repo" init -q -b dev
git -C "$sandbox/repo" config user.email harness@test.local
git -C "$sandbox/repo" config user.name  "harness test"
git -C "$sandbox/repo" add -A && git -C "$sandbox/repo" commit -qm init

mkdir -p "$sandbox/repo/.aiteam/tasks"
cat > "$sandbox/repo/.aiteam/tasks/TASK-CX.json" <<EOF
{
  "id": "TASK-CX",
  "title": "counterexample prompt fixture",
  "objective": "exercise the counterexample rendering in the implementation prompt",
  "risk": "low",
  "status": "CHANGES_REQUESTED",
  "attempts": 2,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 1},
  "findings": [
    {
      "severity": "high",
      "file": "src/a.ts",
      "line": 1,
      "claim": "the analysis misses a case",
      "failure_scenario": "a concrete scenario",
      "remediation": "a fix",
      "status": "open",
      "counterexample": {
        "files": [{"path": "src/extra.ts", "content": "export const extra = 42;\n"}],
        "test": "the suite stays green",
        "expect": "PASS"
      }
    },
    {
      "severity": "medium",
      "file": "src/a.ts",
      "line": 2,
      "claim": "a second claim",
      "failure_scenario": "a concrete scenario",
      "remediation": "a fix",
      "status": "open",
      "counterexample": {
        "files": [{"path": "src/extra.ts", "content": "export const extra = 42;\n"}],
        "test": "the suite stays green",
        "expect": "PASS"
      }
    },
    {
      "severity": "low",
      "file": "src/a.ts",
      "line": 3,
      "claim": "a third claim",
      "failure_scenario": "a concrete scenario",
      "remediation": "a fix",
      "status": "open",
      "counterexample": {
        "files": [{"path": "src/extra.ts", "content": "export const extra = 42;\n"}],
        "test": "the suite stays green",
        "expect": "PASS"
      }
    }
  ],
  "history": [],
  "isolation": {"worktree": "", "branch": ""}
}
EOF

mkdir -p "$sandbox/repo/.aiteam/evidence/TASK-CX"
printf '1 CONFIRMED\n2 REFUTED\n3 INCONCLUSIVE\n' > "$sandbox/repo/.aiteam/evidence/TASK-CX/counterexample.results"

# The prompt is what the next implementer receives; it is written to the task's
# evidence dir and that is the artifact under test. implement.sh's own stdout is
# informational, so the assertions read prompt.md, not the terminal.
set +e
( cd "$sandbox/repo" && ./aiteam/bin/implement.sh TASK-CX --dry-run ) > "$sandbox/out" 2>&1
code=$?
set -e
[ "$code" -eq 0 ] || { echo "implement.sh --dry-run failed (exit $code)" >&2; cat "$sandbox/out" >&2; exit 1; }
PROMPT="$sandbox/repo/.aiteam/evidence/TASK-CX/prompt.md"
[ -f "$PROMPT" ] || { echo "no prompt.md was written" >&2; cat "$sandbox/out" >&2; exit 1; }

# The findings block is extended, not replaced: the reviewer's verbatim findings
# are still in the prompt.
grep -q "Review findings you must address" "$PROMPT" \
  || { echo "the findings block is missing" >&2; exit 1; }
grep -q "the analysis misses a case" "$PROMPT" \
  || { echo "the reviewer's verbatim finding is missing" >&2; exit 1; }

# CONFIRMED is executed evidence.
grep -q "finding 1: CONFIRMED" "$PROMPT" \
  || { echo "a CONFIRMED counterexample is not rendered as executed evidence" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q "reproduced defect" "$PROMPT" \
  || { echo "CONFIRMED does not say what it means" >&2; cat "$PROMPT" >&2; exit 1; }

# REFUTED is labelled as not proven.
grep -q "finding 2: REFUTED" "$PROMPT" \
  || { echo "a REFUTED counterexample is not labelled" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q "not treat it as proven" "$PROMPT" \
  || { echo "REFUTED does not say what it means" >&2; cat "$PROMPT" >&2; exit 1; }

# INCONCLUSIVE is labelled as no conclusion.
grep -q "finding 3: INCONCLUSIVE" "$PROMPT" \
  || { echo "an INCONCLUSIVE counterexample is not labelled" >&2; cat "$PROMPT" >&2; exit 1; }
grep -q "no conclusion was drawn" "$PROMPT" \
  || { echo "INCONCLUSIVE does not say what it means" >&2; cat "$PROMPT" >&2; exit 1; }

# The counterexample block is not emitted when there is no results file.
rm "$sandbox/repo/.aiteam/evidence/TASK-CX/counterexample.results"
rm -f "$sandbox/repo/.aiteam/evidence/TASK-CX/prompt.md"
set +e
( cd "$sandbox/repo" && ./aiteam/bin/implement.sh TASK-CX --dry-run ) > "$sandbox/out2" 2>&1
code2=$?
set -e
[ "$code2" -eq 0 ] || { echo "second dry-run failed (exit $code2)" >&2; cat "$sandbox/out2" >&2; exit 1; }
grep -q "Counterexample executions" "$sandbox/repo/.aiteam/evidence/TASK-CX/prompt.md" \
  && { echo "counterexample block appears with no results file" >&2; exit 1; }

echo "a CONFIRMED counterexample is rendered as executed evidence in the implementation prompt"
exit 0
