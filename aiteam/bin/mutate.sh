#!/usr/bin/env bash
# Prove that a task's tests are capable of failing.
#
#   mutate.sh <id>
#
# Verification tells you the suite is green. It cannot tell you the suite would
# have gone red had the work been wrong, and that distinction is where this
# project has actually lost time: a pruning test that passed with pruning
# deleted, and before it a test that issued its own DELETE and then asserted the
# row was gone. Both were green, both were sincere, both proved nothing.
#
# The reviewer cannot close that gap. It runs read-only by design, and the
# sandbox denies the Docker socket, so every container-backed test — which is
# most of the ones that matter — is unrunnable for it. This is the automated
# substitute: for each acceptance criterion that declares a `mutation`, break
# that guard in the worktree, run the criterion's own test, and require it to
# FAIL. Then restore. A test that still passes is reported as a defect in the
# test, not in the code.
#
# Restoration is via git checkout of the touched path, and the working tree is
# verified clean afterwards, so a crash mid-run cannot leave a mutated guard
# behind to be committed.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
# The mutation check runs the same suite the gates judge, so it must run on the
# same resolved gate runtime — never on whatever the shell happens to have.
ensure_gate_runtime
ensure_state_dirs

id="${1:?usage: mutate.sh <id>}"
wt="$(task_get "$id" '.isolation.worktree // empty')"
[ -n "$wt" ] || die "$id has no worktree recorded"
workdir="$REPO_ROOT/$wt"
[ -d "$workdir" ] || die "$id declares worktree '$wt' but it does not exist"

log="$EVIDENCE_DIR/$id/mutation.log"
mkdir -p "$EVIDENCE_DIR/$id"
: > "$log"

runner="$(task_get "$id" '.mutation_runner // empty')"
[ -n "$runner" ] || runner="./node_modules/.bin/vitest run"

total=0; survived=0; checked=0

# A dirty worktree would make "restore" ambiguous: we could not tell our own
# mutation from work that was already uncommitted.
if [ -n "$(git -C "$workdir" status --porcelain)" ]; then
  die "$id: the worktree has uncommitted changes, so a mutation could not be
     safely distinguished from them. Commit or discard first."
fi

while IFS= read -r c; do
  [ -n "$c" ] || continue
  total=$((total + 1))
  ac="$(printf '%s' "$c" | jq -r '.id')"
  file="$(printf '%s' "$c" | jq -r '.mutation.file')"
  find_s="$(printf '%s' "$c" | jq -r '.mutation.find')"
  repl_s="$(printf '%s' "$c" | jq -r '.mutation.replace // ""')"
  test_f="$(printf '%s' "$c" | jq -r '.mutation.test')"

  {
    echo "=============================================================="
    echo "$ac  mutating $file"
    echo "   guard: $(printf '%s' "$find_s" | head -c 120)"
    echo "   test:  $test_f"
  } >> "$log"

  if [ ! -f "$workdir/$file" ]; then
    echo "   RESULT: file not found — cannot verify this criterion" >> "$log"
    warn "$ac: $file not found"; survived=$((survived + 1)); continue
  fi

  # A criterion verified by a SHELL test runs that script as the mutation
  # runner. vitest cannot discover `aiteam/tests/*.sh`, and a mutation whose
  # named test lives in one would otherwise report "filter matched nothing" —
  # INVALID, scored as survived, and the gate refuses on a criterion the
  # harness simply cannot express. The verified_by format is test:<file>::<name>;
  # when <file> ends in .sh, the mutation is executed as `bash <file> -t <name>`
  # inside the worktree, which is where the mutation was applied. The script is
  # expected to accept `-t <name>` and emit vitest-shaped output, exactly as
  # aiteam/tests/counterexample.run.test.sh does.
  verified_by="$(printf '%s' "$c" | jq -r '.verified_by // ""')"
  shell_test=""
  case "$verified_by" in
    test:*.sh::*)
      shell_test="${verified_by#test:}"
      shell_test="${shell_test%%::*}"
      test_f="${verified_by##*::}"
      ;;
  esac

  # Exactly one occurrence, or the mutation is ambiguous and proves nothing.
  n="$(FIND="$find_s" python3 - "$workdir/$file" <<'PY'
import os,sys
print(open(sys.argv[1]).read().count(os.environ['FIND']))
PY
)"
  if [ "$n" != "1" ]; then
    echo "   RESULT: guard text appears $n times; expected exactly 1" >> "$log"
    warn "$ac: guard text appears $n times in $file — mutation is ambiguous"
    survived=$((survived + 1)); continue
  fi

  FIND="$find_s" REPL="$repl_s" python3 - "$workdir/$file" <<'PY'
import os,sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace(os.environ['FIND'], os.environ['REPL'], 1))
PY

  # Captured separately so this criterion's run can be inspected on its own.
  out="$(mktemp)"
  set +e
  # The runner is word-split deliberately (it is a plain command such as
  # "./node_modules/.bin/vitest run"), but the filter must survive as ONE
  # argument. Passing it through `eval` split "concurrent redemptions" into a
  # flag value and a stray path, so the filter matched nothing and the resulting
  # non-zero exit looked exactly like a killed mutation.
  # shellcheck disable=SC2206
  if [ -n "$shell_test" ]; then
    runner_argv=(bash "$shell_test")
  else
    runner_argv=($runner)
  fi
  ( cd "$workdir" && "${runner_argv[@]}" -t "$test_f" ) > "$out" 2>&1
  code=$?
  set -e
  cat "$out" >> "$log"

  git -C "$workdir" checkout -- "$file"

  # A filter that matches nothing also exits non-zero, which would otherwise be
  # scored as a kill — the strongest possible result from the weakest possible
  # check. The run only counts if the runner reports having executed something.
  ran_nothing=0
  grep -q "No test files found" "$out" && ran_nothing=1
  grep -q "Test Files" "$out" || ran_nothing=1
  # The commoner failure by far is a filter that matches no test NAME. The files
  # are found and reported, every test in them is skipped, and the summary reads
  # "Tests  337 skipped (337)" — so the checks above are satisfied while nothing
  # ran. Both scores are then wrong: a clean exit reads as SURVIVED (a false
  # alarm) and a mutation that breaks parsing reads as killed (false confidence,
  # the dangerous direction). A run counts only if the summary reports at least
  # one test that actually passed or failed.
  grep -qE "^ *Tests +.*(passed|failed)" "$out" || ran_nothing=1
  rm -f "$out"

  checked=$((checked + 1))
  if [ "$ran_nothing" -eq 1 ]; then
    echo "   RESULT: INVALID — the filter '$test_f' matched no test" >> "$log"
    warn "$ac: test filter '$test_f' matched nothing, so nothing was proved"
    survived=$((survived + 1)); continue
  fi
  if [ "$code" -eq 0 ]; then
    echo "   RESULT: SURVIVED — the test passed with the guard removed" >> "$log"
    warn "$ac: its test passes even with the guard removed, so it proves nothing"
    survived=$((survived + 1))
  else
    echo "   RESULT: killed — the test failed as it must" >> "$log"
    ok "$ac: test fails when the guard is removed"
  fi
done < <(task_get "$id" '.acceptance_criteria[] | select(.mutation != null) | @json')

# Restoration must be provable, not assumed.
if [ -n "$(git -C "$workdir" status --porcelain)" ]; then
  git -C "$workdir" checkout -- . 2>/dev/null || true
  [ -n "$(git -C "$workdir" status --porcelain)" ] \
    && die "$id: the worktree is still modified after restoring mutations. Inspect it before doing anything else."
fi

echo "$survived" > "$EVIDENCE_DIR/$id/mutation.survivors"
{ echo; echo "checked $checked of $total declared mutations; $survived survived"; } >> "$log"

if [ "$survived" -gt 0 ]; then
  warn "$id: $survived criterion test(s) cannot fail — see $log"
  exit 1
fi
if [ "$total" -eq 0 ]; then
  info "$id: no criterion declares a mutation, so test honesty was not checked"
  exit 0
fi
ok "$id: every declared guard is covered by a test that fails without it"
