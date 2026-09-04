#!/usr/bin/env bash
# Behavioural test for the scope gate's hard/soft split.
#
#   scope-gate.sh hard   expect the gate to fail outright (exit 1)
#   scope-gate.sh soft   expect the gate to stop for a decision (exit 76)
#   scope-gate.sh clean  expect the gate to pass (exit 0)
#
# Grepping the source proves the code contains a string. This proves the gate
# reaches the intended verdict, which is the only thing that matters when the
# distinction decides whether an attempt is spent.
#
# It builds a throwaway repository and copies the harness into it, so it also
# exercises the portability claim: the harness has to work when pasted into a
# project it has never seen.

set -uo pipefail
mode="${1:?usage: scope-gate.sh <hard|soft|clean>}"

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

repo="$sandbox/repo"
mkdir -p "$repo/src"
cp -R "$AITEAM_SRC" "$repo/aiteam"

cd "$repo"
git init -q -b dev
git config user.email harness@test.local
git config user.name  "harness test"
mkdir -p .aiteam/tasks
printf '{"default_branch":"dev"}\n' > .aiteam/project.json
printf 'code\n'   > src/a.txt
printf 'readme\n' > README.md
git add -A && git commit -qm init

wt=".git/wt-test"
git worktree add -q -b task/test "$wt" dev

cat > .aiteam/tasks/TASK-TEST.json <<EOF
{
  "id": "TASK-TEST",
  "title": "scope gate fixture",
  "objective": "exercise the scope gate",
  "risk": "low",
  "status": "IN_PROGRESS",
  "attempts": 1,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 0},
  "findings": [],
  "history": [],
  "isolation": {"worktree": "$wt", "branch": "task/test"}
}
EOF

# Every case changes a file inside scope, so `diff_not_empty` passes and the
# scope gate is the only thing under test.
printf 'changed\n' >> "$wt/src/a.txt"
case "$mode" in
  clean) ;;
  soft)  printf 'edited by the agent\n' >> "$wt/README.md" ;;                    # ordinary repo file
  hard)  mkdir -p "$wt/.aiteam" && printf '{}' > "$wt/.aiteam/tampered.json" ;;  # the harness itself
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac

git -C "$wt" add -A
git -C "$wt" commit -qm "fixture change"

out="$("$repo/aiteam/bin/task.sh" transition TASK-TEST TESTING 2>&1)"
code=$?
printf '%s\n' "$out"
echo "GATE_EXIT=$code"

case "$mode" in
  clean) [ "$code" -eq 0 ]  || { echo "expected 0, got $code" >&2; exit 1; } ;;
  soft)  [ "$code" -eq 76 ] || { echo "expected 76 (stop for a decision), got $code" >&2; exit 1; } ;;
  hard)  [ "$code" -eq 1 ]  || { echo "expected 1 (hard failure), got $code" >&2; exit 1; }
         # A harness edit must never be recorded as the forgivable kind.
         [ -f ".aiteam/evidence/TASK-TEST/scope_violation" ] \
           && { echo "hard violation was recorded as a soft one" >&2; exit 1; }
         printf '%s' "$out" | grep -q 'never writable by an agent' \
           || { echo "hard violation was not named as a harness edit" >&2; exit 1; } ;;
esac
exit 0
