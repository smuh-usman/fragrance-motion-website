#!/usr/bin/env bash
# Behavioural tests for the harness_task exemption in the scope gate and the
# lifecycle. The exemption is the only hole ever punched in the rule that a
# dispatched agent may not touch the harness that judges it, so it gets the same
# treatment the rule itself refused to accept on trust: exercised against a real
# discardable repository, with the failing-closed, never-state and never-skipped
# sides asserted separately.
#
#   harness-task-scope.test.sh                  run every case (the harness's
#                                                verification command)
#   harness-task-scope.test.sh -t "<name>"      run one named case and emit
#                                                vitest-shaped output (mutation
#                                                mode, invoked by the mutation
#                                                gate)
#
# Each case builds a throwaway repository, copies the CURRENT aiteam/ into it and
# drives the real task.sh transition, exactly like scope-gate.sh. In mutation mode
# the current aiteam/ is the one the gate just modified, so the named case runs
# against the guard removed and fails as the mutation requires.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ------------------------------------------------------------------ fixtures
# Spin up a throwaway repo with the current aiteam copied in, a worktree, one
# task (the JSON passed in), one edit at the worktree path, committed, then the
# named transition run for real. On return:
#   SBX   sandbox repo dir   TASK   task id   OUT   transition output   EXIT
run_fixture() {  # run_fixture <task-json> <edit-relpath> <to-state>
  local task_json="$1" edit="$2" to="$3" to_state
  SBX="$(mktemp -d)"
  cp -R "$AITEAM_SRC" "$SBX/aiteam"
  mkdir -p "$SBX/.aiteam/tasks" "$SBX/src"
  printf '{"default_branch":"dev"}\n' > "$SBX/.aiteam/project.json"
  printf 'base\n' > "$SBX/src/a.txt"
  TASK="$(printf '%s' "$task_json" | jq -r .id)"
  printf '%s\n' "$task_json" > "$SBX/.aiteam/tasks/$TASK.json"

  ( cd "$SBX" \
      && git init -q -b dev \
      && git config user.email harness@test.local \
      && git config user.name  "harness test" \
      && git add -A \
      && git commit -qm init \
      && git worktree add -q -b task/fx .git/wt dev \
      && printf 'edited\n' >> ".git/wt/$edit" \
      && git -C .git/wt add -A \
      && git -C .git/wt commit -qm "fixture change" )

  to_state="$(printf '%s' "$task_json" | jq -r .status)"
  OUT="$("$SBX/aiteam/bin/task.sh" transition "$TASK" "$to" 2>&1)"; EXIT=$?
  printf '\n[%s -> %s exited %s]\n' "$to_state" "$to" "$EXIT" >&2
  printf '%s\n' "$OUT" >&2
}

# A valid task scaffold for the fixture repo. Individual cases override fields.
FIXTURE='{
  "title": "harness task scope fixture",
  "objective": "exercise the scope gate and lifecycle for declared harness tasks",
  "risk": "low",
  "status": "IN_PROGRESS",
  "attempts": 1,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "devops",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 0},
  "findings": [],
  "history": [],
  "isolation": {"worktree": ".git/wt", "branch": "task/fx"}
}'

declared_fixture() {  # declared_fixture <id> <status>
  printf '%s' "$FIXTURE" | jq --arg id "$1" --arg st "$2" \
    '.id = $id | .status = $st | .harness_task = true | .files.expected = ["aiteam/**", "src/**"]'
}
plain_fixture() {  # plain_fixture <id>   (does NOT declare the exemption)
  printf '%s' "$FIXTURE" | jq --arg id "$1" '.id = $id'
}

# -------------------------------------------------------------------- cases

case_1_undeclared_refused() {
  # A task that does not declare the exemption must still be refused when it
  # edits harness CODE — absence means false, the historical rule is unchanged.
  run_fixture "$(plain_fixture TASK-A1)" "aiteam/README.md" TESTING
  [ "$EXIT" -eq 1 ] || { echo "undeclared harness-code edit: expected hard refusal (exit 1), got $EXIT"; return 1; }
  printf '%s' "$OUT" | grep -q "only a declared harness task" \
    || { echo "the refusal did not name harness code written by a non-harness task"; return 1; }

  # The contrast that proves the refusal is CONDITIONAL: the identical edit is
  # let through when the exact same contract declares the exemption. The AC2
  # mutation removes the single field lookup, which removes the distinction too —
  # a declared task is then refused, so this contrast fails under the mutation.
  run_fixture "$(declared_fixture TASK-A2 IN_PROGRESS)" "aiteam/README.md" TESTING
  [ "$EXIT" -eq 0 ] || { echo "declared harness-code edit: expected the exemption to allow it (exit 0), got $EXIT"; return 1; }
  return 0
}

case_2_declared_allowed() {
  run_fixture "$(declared_fixture TASK-B1 IN_PROGRESS)" "aiteam/README.md" TESTING
  [ "$EXIT" -eq 0 ] || { echo "declared harness task was refused editing harness code inside its list (exit $EXIT)"; return 1; }
  return 0
}

case_3_state_refused() {
  # .aiteam/ is harness STATE — the machinery of judgement. The exemption must
  # not open it; the write stays a hard void (exit 1), never a soft scope decision.
  run_fixture "$(declared_fixture TASK-C1 IN_PROGRESS)" ".aiteam/state.json" TESTING
  [ "$EXIT" -eq 1 ] || { echo "a declared harness task writing harness state: expected hard refusal (exit 1), got $EXIT"; return 1; }
  printf '%s' "$OUT" | grep -q "harness state" \
    || { echo "the .aiteam write was not named as harness state"; return 1; }
  return 0
}

case_4_review_required() {
  # A harness task cannot skip review. review.required is published false here,
  # and the gate must still refuse the skip path — it is not trusted to the
  # contract author to have switched review on.
  run_fixture "$(declared_fixture TASK-D1 TESTING | jq '.review.required = false')" "aiteam/README.md" VERIFIED
  [ "$EXIT" -ne 0 ] || { echo "a declared harness task with review disabled reached VERIFIED"; return 1; }
  printf '%s' "$OUT" | grep -q "independent review is mandatory" \
    || { echo "the refusal did not name mandatory independent review"; return 1; }
  return 0
}

case_5_history_recorded() {
  run_fixture "$(declared_fixture TASK-E1 IN_PROGRESS)" "aiteam/README.md" TESTING
  [ "$EXIT" -eq 0 ] || { echo "declared harness task refused (exit $EXIT)"; return 1; }
  jq -e '.history[] | select((.note // "") | contains("aiteam/README.md") and contains("harness code"))' \
      "$SBX/.aiteam/tasks/$TASK.json" >/dev/null \
    || { echo "the scope-gate pass was not recorded naming the harness file and the exemption"; return 1; }
  return 0
}

# ------------------------------------------------------------- mutation mode
# The mutation gate runs `bash <this> -t "<name>"` after editing this worktree's
# task.sh, and requires the named case to fail. Output must be vitest-shaped so
# testcount.mjs and mutate.sh's "did a test actually run" guard can read it.
if [ "${1:-}" = "-t" ]; then
  name="${2:-}"
  case "$name" in
    "a task that does not declare harness_task is still refused when it edits harness code")
      case_1_undeclared_refused ;;
    "a declared harness task may edit the harness code inside its declared file list")
      case_2_declared_allowed ;;
    "a declared harness task is still refused when it writes harness state")
      case_3_state_refused ;;
    "a harness task with review disabled is refused")
      case_4_review_required ;;
    "passing the scope gate under the exemption is recorded in the task history")
      case_5_history_recorded ;;
    *)
      echo "No test files found"
      exit 1 ;;
  esac
  if [ "$?" -eq 0 ]; then
    echo " Test Files  1 passed (1)"
    echo "      Tests  1 passed (1)"
    exit 0
  fi
  echo " Test Files  1 failed (1)"
  echo "      Tests  1 failed (1)"
  exit 1
fi

# ------------------------------------------------------------------ full run
fail=0
check() {  # check <name> <fn>
  local name="$1" fn="$2"
  if "$fn"; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"; fail=1
  fi
}

echo "The harness_task exemption closes on absence, state and review"
check "a task that does not declare harness_task is still refused when it edits harness code" case_1_undeclared_refused
check "a declared harness task may edit the harness code inside its declared file list" case_2_declared_allowed
check "a declared harness task is still refused when it writes harness state" case_3_state_refused
check "a harness task with review disabled is refused" case_4_review_required
check "passing the scope gate under the exemption is recorded in the task history" case_5_history_recorded

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mall harness-task scope checks passed.\033[0m\n'
else
  printf '\033[31msome harness-task scope checks failed.\033[0m\n'
fi
exit "$fail"