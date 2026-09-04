#!/usr/bin/env bash
# Runs a task's verification commands and records tamper-evident evidence.
#
# The recorded exit code is what the gates read. Nothing an agent says about its
# own verification is consulted anywhere in this harness.
#
#   verify.sh <id> [--postrebase] [--baseline]
#
# --baseline  record the current test count before implementation begins, so a
#             later drop reveals tests that were deleted or skipped to go green.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
# The recorded exit code is what the gates read, so verification must run on the
# resolved gate runtime — never on whatever the shell happens to have. A pass
# produced by a different runtime than the one reported is evidence about a run
# that did not happen.
ensure_gate_runtime
ensure_state_dirs

id="${1:?usage: verify.sh <id> [--postrebase] [--baseline]}"; shift || true
mode="run"
for arg in "$@"; do
  case "$arg" in
    --postrebase) mode="postrebase" ;;
    --baseline)   mode="baseline" ;;
    # An unrecognised argument is fatal, never ignored. Silently falling back to
    # the default mode makes `verify.sh <id> postrebase` overwrite verify.log —
    # the pre-review evidence — with a post-merge run, which forges the record
    # the review gate reads.
    *) die "verify.sh: unknown argument '$arg' (expected --postrebase or --baseline)" ;;
  esac
done

# Verification MUST run inside the task's own worktree. There is deliberately no
# fallback to the repository root: a verification that runs against the wrong tree
# can pass while the task's actual code does not exist, which is the one failure
# this harness cannot tolerate — it manufactures evidence for a green gate.
wt="$(task_get "$id" '.isolation.worktree // empty')"
[ -n "$wt" ] || die "$id has no worktree recorded. Verification will not run against
     the repository root, because a pass there would be evidence about the wrong tree.
     Create the worktree first: aiteam/bin/worktree.sh create $id"
workdir="$REPO_ROOT/$wt"
[ -d "$workdir" ] || die "$id declares worktree '$wt' but it does not exist"

mkdir -p "$EVIDENCE_DIR/$id"
case "$mode" in
  postrebase) log="$EVIDENCE_DIR/$id/verify_postrebase.log"; exitf="$EVIDENCE_DIR/$id/verify_postrebase.exit" ;;
  baseline)   log="$EVIDENCE_DIR/$id/verify_baseline.log";   exitf="$EVIDENCE_DIR/$id/verify_baseline.exit" ;;
  *)          log="$EVIDENCE_DIR/$id/verify.log";            exitf="$EVIDENCE_DIR/$id/verify.exit" ;;
esac

# An agent interrupted mid-install leaves the workspace unusable, and every
# command below then exits 127. That reads in the log exactly like a real
# failure, so it burns an attempt, escalates the model, and poisons the test
# count — all for an environment fault that no amount of re-implementing fixes.
# Verification owns the environment it measures.
ensure_workspace_ready "$workdir" "$EVIDENCE_DIR/$id/install.log" \
  || warn "dependency install failed — see $EVIDENCE_DIR/$id/install.log"

: > "$log"
overall=0
env_fault=0
env_reason=""

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  {
    echo "=============================================================="
    echo "\$ $cmd"
    echo "--- started $(now_iso) in $workdir"
  } >> "$log"
  set +e
  ( cd "$workdir" && eval "$cmd" ) >> "$log" 2>&1
  code=$?
  set -e
  echo "--- exit $code" >> "$log"
  # 127 is "command not found", which here means the toolchain is missing rather
  # than the code being wrong. Naming it keeps a broken environment from being
  # read as a failed implementation.
  if [ "$code" -eq 127 ]; then env_fault=1; fi
  if [ "$code" -ne 0 ]; then overall=$code; warn "FAILED ($code): $cmd"; else ok "passed: $cmd"; fi
done < <(task_get "$id" '.verification[]')

# How many tests actually ran. Parsed from the runner's own summary line rather
# than sniffed out of arbitrary text: a loose regex here matched the "0 test"
# inside npm's banner (`> project@0.1.0 test`) and discarded two correct
# implementations before anyone noticed the version number was the culprit.
tc="$(node "$AITEAM_DIR/bin/testcount.mjs" "$log" 2>/dev/null || echo unknown)"
count=""
case "$tc" in
  "passed "*) count="${tc#passed }" ;;
esac

# A run that executed no tests is not a pass. Several runners exit 0 when their
# path or glob matches nothing, so a mistyped verification command would sail
# through every gate having asserted nothing at all. "unknown" is not "zero":
# an unrecognised runner gets a warning, never a failure.
if [ "$mode" != "baseline" ] && [ "$overall" -eq 0 ]; then
  if [ "$tc" = "zero" ]; then
    echo "--- harness: zero tests executed; treating as failure" >> "$log"
    warn "verification ran no tests — check the verification command's path or glob"
    overall=1
  elif [ "$tc" = "unknown" ]; then
    warn "could not read a test count from this runner's output — not blocking, but the
      deleted-test check cannot run. Add the runner to aiteam/bin/testcount.mjs."
  fi
fi

# A suite can fail without saying anything about the code. Vitest reports a setup
# hook that timed out as a failed FILE, and every integration file here starts a
# database container inside that hook — so a machine that cannot service the
# container starts reports a dozen failed files and not one failed assertion.
# That is an outage wearing a verdict's clothes. It already cost an attempt on
# the assessment slice, where thirteen simultaneous container starts exceeded
# what Docker would service inside the hook timeout and the code under test was
# never executed at all.
#
# The test is deliberately conjunctive: hooks died AND the runner's own summary
# reports no failing test. A genuine assertion failure alongside a flaky
# container is still a verdict, and must stay one.
if [ "$overall" -ne 0 ] && [ "$env_fault" -eq 0 ] \
   && grep -qE 'Hook timed out in|Could not find a working container runtime|Cannot connect to the Docker daemon|docker: .*Cannot connect' "$log" \
   && ! grep -qE '^[[:space:]]*Tests[[:space:]].*[0-9]+ failed' "$log"; then
  env_fault=1
  env_reason="every failing test file died in a setup hook and the runner reported no
      failing assertion, so the code under test was never reached. This machine could
      not start what the suite needs (most often a container runtime under load)"
fi

echo "$overall" > "$exitf"
if [ -n "$count" ]; then
  case "$mode" in
    baseline) echo "$count" > "$EVIDENCE_DIR/$id/test_count_baseline" ;;
    run)      echo "$count" > "$EVIDENCE_DIR/$id/test_count" ;;
  esac
fi

[ "$mode" = "run" ] && task_set "$id" '.evidence.verification = ".aiteam/evidence/'"$id"'/verify.log"'

if [ "$overall" -eq 0 ]; then
  ok "verification passed for $id"
elif [ "$env_fault" -eq 1 ]; then
  echo "--- harness: environment fault, not a verdict on the code" >> "$log"
  warn "verification could not run for $id: ${env_reason:-a command was not found (exit 127),
      which means the toolchain is missing rather than the implementation being wrong}.
      Do not read this as a failed attempt — see $log and $EVIDENCE_DIR/$id/install.log"
  # Distinct from a failed verification so the driver stops instead of climbing
  # the escalation ladder. Escalating here would answer "is this model good
  # enough" with evidence about the machine, and the ladder ends at the most
  # expensive model available — which would also fail, for the same reason.
  exit 75
else
  warn "verification failed for $id — see $log"
fi
exit "$overall"
