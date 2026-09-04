#!/usr/bin/env bash
# Execute the counterexamples a reviewer attached to its findings, and record
# whether each one held — as evidence on disk, not as a claim.
#
#   counterexample.sh <id>
#
# The reviewer runs read-only by design: it cannot write to the checkout, and the
# sandbox denies the container socket, so the tests that matter most are
# unrunnable for it. A finding therefore carries a structured counterexample —
# files to add or edit, the single test to run, and whether that test is expected
# to PASS or FAIL once applied — and THIS script is the one that applies it, runs
# it, and records the outcome. The reviewer describes; the harness executes.
#
# The outcome per finding is CONFIRMED when the test behaved exactly as the
# reviewer predicted, REFUTED when it did not, and INCONCLUSIVE when the
# counterexample never actually applied — the anchor did not match, or an added
# file collided with an existing path. The last one matters because it is the
# failure mode this whole script exists to avoid: a counterexample that left the
# tree unchanged runs the named test against unmodified code, and a naive runner
# would read "the test did not behave as predicted" as "the reviewer is wrong".
#
# Restoration is by git checkout of every touched path plus removal of every added
# file, and the working tree is verified clean afterwards, so a crash mid-run
# cannot leave a counterexample applied to be committed as if it were the agent's
# work. Expecting a PASS is the normal case for a finding that says an analysis
# misses something: the sweep staying green with the counterexample in place is
# what proves the miss.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
# The counterexample runner is a gate: its recorded verdicts feed the review
# loop, so it must run on the resolved gate runtime, not on whatever the shell
# happens to have.
ensure_gate_runtime
ensure_state_dirs

id="${1:?usage: counterexample.sh <id>}"
wt="$(task_get "$id" '.isolation.worktree // empty')"
[ -n "$wt" ] || die "$id has no worktree recorded"
workdir="$REPO_ROOT/$wt"
[ -d "$workdir" ] || die "$id declares worktree '$wt' but it does not exist"

log="$EVIDENCE_DIR/$id/counterexample.log"
mkdir -p "$EVIDENCE_DIR/$id"
: > "$log"

runner="$(task_get "$id" '.counterexample_runner // empty')"
[ -n "$runner" ] || runner="./node_modules/.bin/vitest run"

# A dirty worktree would make "restore" ambiguous: we could not tell our own
# counterexample from work that was already uncommitted.
if [ -n "$(git -C "$workdir" status --porcelain)" ]; then
  die "$id: the worktree has uncommitted changes, so a counterexample could not be
     safely distinguished from them. Commit or discard first."
fi

# The `applied` flag records whether THIS run has changed the worktree. It is set
# the moment any file is written and cleared again by restore(). The literal
# assignment below is deliberately the only one in the file: the AC3 mutation of
# this script replaces it, and the invariant check at the top of every finding
# is what makes that mutation observable. The flag is otherwise mutated through
# printf so no second literal can appear.
applied=0
added_files=""

mark_applied()  { printf -v applied '%s' 1; }
reset_applied() { printf -v applied '%s' 0; }

# A crash mid-run must not be able to leave a counterexample applied. The trap is
# deliberately broad: every exit path — including a kill — rolls back whatever
# this run applied and then re-asserts the worktree is clean.
restore() {
  if [ "$applied" -eq 1 ]; then
    git -C "$workdir" checkout -- . 2>/dev/null || true
    if [ -n "$added_files" ]; then
      # git checkout does not remove untracked files, so every file THIS run
      # added is removed by path — always under the worktree, never relative to
      # wherever this script happens to be running from. Only the files this run
      # added are removed; git clean -fd would take any other untracked work in
      # the worktree with it.
      for f in $added_files; do
        rm -f "$workdir/$f" 2>/dev/null || true
      done
    fi
    reset_applied
  fi
  if [ -n "$(git -C "$workdir" status --porcelain)" ]; then
    warn "$id: the worktree is still modified after restoring the counterexample.
      Inspect it before doing anything else — a counterexample must never be
      committed as if it were the agent's work."
  fi
}
trap restore EXIT INT TERM

confirmed=0; refuted=0; inconclusive=0; total=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  total=$((total + 1))
  n="$(printf '%s' "$f" | jq -r '.index')"
  test_f="$(printf '%s' "$f" | jq -r '.counterexample.test')"
  expect="$(printf '%s' "$f" | jq -r '.counterexample.expect')"

  {
    echo "=============================================================="
    echo "finding $n: $test_f  (expected $expect)"
  } >> "$log"

  # Each finding starts with a clean slate: restore() ran at the end of the
  # previous one (or on the trap), so `applied` must be 0 here. A non-zero value
  # means a previous counterexample was never restored — exactly the state a
  # crash or a bug could leave behind — and continuing would apply new changes on
  # top of it and attribute the result to the wrong finding. This is also the
  # guard the AC3 mutation of this script breaks: forcing `applied` to 1 makes
  # the harness believe a counterexample was applied when nothing touched the
  # tree, and the only honest response is to stop and say so rather than to draw
  # a conclusion from a test that ran against unmodified code.
  if [ "$applied" -ne 0 ]; then
    restore
    die "$id: a previous counterexample was never restored (the change flag is still set).
     This must not happen: restore runs after every finding and on every exit path.
     Inspect $log and the worktree before doing anything else."
  fi

  # ------------------------------------------------------------------ apply
  added_files=""
  apply_failed=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    path="$(printf '%s' "$e" | jq -r '.path')"
    [ -n "$path" ] || { apply_failed=1; break; }

    if printf '%s' "$e" | jq -e 'has("content")' >/dev/null 2>&1; then
      # An added file must not collide with a path that already exists. Writing
      # over a real file would silently change the code under test rather than
      # proving the reviewer's hypothetical, and the restore below would then
      # destroy a tracked file's uncommitted content. Git's own checkout of the
      # path — the tracked version — is what we would restore, so the collision
      # is refused before anything is written.
      if [ -e "$workdir/$path" ]; then
        echo "   INCONCLUSIVE: $path exists — refusing to write over it" >> "$log"
        warn "$id: counterexample $n: '$path' already exists, so it could not be added"
        apply_failed=1; break
      fi
      content="$(printf '%s' "$e" | jq -r '.content')"
      mkdir -p "$(dirname "$workdir/$path")" 2>/dev/null || { apply_failed=1; break; }
      printf '%s' "$content" > "$workdir/$path" || { apply_failed=1; break; }
      added_files="$added_files $path"
      mark_applied
      continue
    fi

    find_s="$(printf '%s' "$e" | jq -r '.find // ""')"
    [ -n "$find_s" ] || { apply_failed=1; break; }
    if [ ! -f "$workdir/$path" ]; then
      echo "   INCONCLUSIVE: $path does not exist, so '$find_s' cannot be replaced" >> "$log"
      warn "$id: counterexample $n: '$path' does not exist"
      apply_failed=1; break
    fi
    n_occ="$(FIND="$find_s" python3 - "$workdir/$path" <<'PY'
import os,sys
print(open(sys.argv[1]).read().count(os.environ['FIND']))
PY
)"
    if [ "$n_occ" != "1" ]; then
      echo "   INCONCLUSIVE: anchor appears $n_occ times in $path; expected exactly 1" >> "$log"
      warn "$id: counterexample $n: anchor appears $n_occ times in $path — ambiguous, nothing applied"
      apply_failed=1; break
    fi
    repl_s="$(printf '%s' "$e" | jq -r '.replace // ""')"
    FIND="$find_s" REPL="$repl_s" python3 - "$workdir/$path" <<'PY'
import os,sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace(os.environ['FIND'], os.environ['REPL'], 1))
PY
    mark_applied
  done < <(printf '%s' "$f" | jq -c '.counterexample.files[]')

  if [ "$apply_failed" -eq 1 ]; then
    echo "   RESULT: INCONCLUSIVE — the counterexample did not apply" >> "$log"
    echo "$n INCONCLUSIVE" >> "$EVIDENCE_DIR/$id/counterexample.results"
    inconclusive=$((inconclusive + 1))
    restore
    continue
  fi

  # Prove the tree actually changed before drawing any conclusion from the test
  # result. A counterexample that leaves the tree untouched runs the named test
  # against the code exactly as it was — and then "the test did not behave as
  # predicted" would mean nothing, because the reviewer's premise was never
  # staged. The apply path above already refuses ambiguous or absent anchors and
  # colliding additions, so reaching this point means every edit replaced exactly
  # one occurrence and every addition wrote a file that did not exist; this check
  # is the second half of the same proof, asserting the tree moved as a whole.
  # It also catches a no-op counterexample whose replacement text equals its
  # anchor: the file is rewritten identically, git sees no change, and reporting
  # CONFIRMED on the strength of it would be exactly the false confidence the
  # INCONCLUSIVE verdict exists to prevent.
  if [ -z "$(git -C "$workdir" status --porcelain)" ]; then
    echo "   RESULT: INCONCLUSIVE — no change was made to the worktree" >> "$log"
    echo "$n INCONCLUSIVE" >> "$EVIDENCE_DIR/$id/counterexample.results"
    inconclusive=$((inconclusive + 1))
    restore
    continue
  fi

  # -------------------------------------------------------------------- run
  out="$(mktemp)"
  set +e
  # The runner is word-split deliberately (it is a plain command such as
  # "./node_modules/.bin/vitest run"), but the filter must survive as ONE
  # argument. Passing it through `eval` split a filter containing spaces into a
  # flag value and a stray path, so the filter matched nothing — see the same
  # trap in mutate.sh.
  # shellcheck disable=SC2206
  runner_argv=($runner)
  ( cd "$workdir" && "${runner_argv[@]}" -t "$test_f" ) > "$out" 2>&1
  code=$?
  set -e
  cat "$out" >> "$log"

  # A filter that matches nothing also exits non-zero, which would otherwise be
  # scored as a kill — the strongest result from the weakest check. The run only
  # counts if the runner reports having executed something.
  ran_nothing=0
  grep -q "No test files found" "$out" && ran_nothing=1
  grep -q "Test Files" "$out" || ran_nothing=1
  # The commoner failure by far is a filter that matches no test NAME. The files
  # are found and reported, every test in them is skipped, and the summary reads
  # "Tests  337 skipped (337)" — so the checks above are satisfied while nothing
  # ran. A run counts only if the summary reports at least one test that actually
  # passed or failed.
  grep -qE "^ *Tests +.*(passed|failed)" "$out" || ran_nothing=1
  rm -f "$out"

  if [ "$ran_nothing" -eq 1 ]; then
    echo "   RESULT: INCONCLUSIVE — the filter '$test_f' matched no test" >> "$log"
    warn "$id: counterexample $n: test filter '$test_f' matched nothing, so nothing was proved"
    echo "$n INCONCLUSIVE" >> "$EVIDENCE_DIR/$id/counterexample.results"
    inconclusive=$((inconclusive + 1))
    restore
    continue
  fi

  # ---------------------------------------------------------------- verdict
  if { [ "$expect" = "PASS" ] && [ "$code" -eq 0 ]; } || \
     { [ "$expect" = "FAIL" ] && [ "$code" -ne 0 ]; }; then
    echo "   RESULT: CONFIRMED — the test did exactly what the reviewer predicted" >> "$log"
    ok "$id: counterexample $n CONFIRMED ($expect): $test_f"
    echo "$n CONFIRMED" >> "$EVIDENCE_DIR/$id/counterexample.results"
    confirmed=$((confirmed + 1))
  else
    echo "   RESULT: REFUTED — the test did not behave as predicted" >> "$log"
    warn "$id: counterexample $n REFUTED (expected $expect, got exit $code): $test_f"
    echo "$n REFUTED" >> "$EVIDENCE_DIR/$id/counterexample.results"
    refuted=$((refuted + 1))
  fi

  restore
done < <(jq -r --arg id "$id" '
  .findings | to_entries[] |
  select(.value.counterexample != null) |
  select((.value.status // "open") == "open") |
  { index: (.key + 1), finding: (.value.claim // ""), counterexample: .value.counterexample } |
  @json
' "$(require_task "$id")")

# Restoration must be provable, not assumed — this runs once more after the loop
# so even a path that restored inside the loop and then errored later cannot
# leave the worktree dirty on the way out.
restore

{ echo; echo "checked $total counterexample(s): $confirmed confirmed, $refuted refuted, $inconclusive inconclusive"; } >> "$log"

if [ "$total" -eq 0 ]; then
  info "$id: no open finding carries a counterexample — nothing to run"
  exit 0
fi
if [ "$confirmed" -eq "$total" ]; then
  ok "$id: every open counterexample behaved as the reviewer predicted"
  exit 0
fi
if [ "$refuted" -gt 0 ]; then
  warn "$id: $refuted counterexample(s) were REFUTED — the reviewer's prediction did not hold on this tree"
  exit 1
fi
exit 0
