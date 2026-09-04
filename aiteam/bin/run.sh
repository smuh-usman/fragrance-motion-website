#!/usr/bin/env bash
# Drive one task through the full lifecycle, including the failure and review loops.
#
#   run.sh <id> [--no-handoff]
#
#   IMPLEMENT -> VERIFY -> (retry with escalation on failure)
#             -> REVIEW  -> (remediate on FAIL, carrying findings verbatim)
#             -> HANDOFF (rebase, re-verify, branch ready for a human PR)
#
# Failures are never suppressed to reach DONE. When the loop gives up it says so
# and leaves the task in a state that shows why.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
ensure_state_dirs

id="${1:?usage: run.sh <id> [--no-handoff]}"; shift || true
do_handoff=1
for a in "$@"; do
  case "$a" in
    --no-handoff|--no-merge) do_handoff=0 ;;   # --no-merge kept as an alias
  esac
done

# One driver per task. Two concurrent runs interleave their transitions and
# produce evidence describing neither, which is how a completed task ends up
# with attempts recorded after it was already DONE.
task_lock "$id"

max_attempts="$(jq -r '.escalation.max_attempts // 4' "$MODELS_CFG")"
max_rejections="$(jq -r '.escalation.max_review_rejections // 2' "$MODELS_CFG")"

model_for_attempt() {
  local n="$1" m
  m="$(jq -r --argjson n "$n" '.escalation.implementation[] | select(.attempt == $n) | .model' "$MODELS_CFG")"
  [ -n "$m" ] && [ "$m" != "null" ] || m="$(model_for implementation)"
  echo "$m"
}

banner() { printf '\n\033[1m── %s ─────────────────────────────────────\033[0m\n' "$*" >&2; }

# Once a provider has proved unreachable, stay off it for the rest of this task.
# Flapping back to it on the next rung just spends attempts rediscovering that
# the API is still down. Bounded, so a total outage stops rather than spinning.
forced_model=""
failovers=0
max_failovers="$(jq -r '.escalation.max_provider_failovers // 2' "$MODELS_CFG")"

attempt=0
while :; do
  attempt=$((attempt + 1))
  [ "$attempt" -le "$max_attempts" ] || die "$id exhausted $max_attempts attempts.
     Repeated failure usually means the task contract was wrong rather than the
     model being weak. Re-scope or split it before running again."

  model="${forced_model:-$(model_for_attempt "$attempt")}"
  banner "$id attempt $attempt/$max_attempts — implementing with $model"

  if [ "$model" = "opus-5" ]; then
    warn "escalation reached the orchestrator. Stopping: the next step is a human
     or the orchestrating session re-scoping this task, not another dispatch."
    "$AITEAM_DIR/bin/task.sh" note "$id" "escalated to orchestrator after $((attempt-1)) failed attempts"
    exit 2
  fi

  # A failed dispatch ends the attempt. Verifying afterwards is meaningless at
  # best and dangerous at worst: if the worktree was never created, verification
  # would run somewhere else and could pass against a tree the task never touched.
  set +e
  "$AITEAM_DIR/bin/implement.sh" "$id" --model "$model" >/dev/null
  dispatch_code=$?
  set -e

  # 75 (EX_TEMPFAIL) means the provider never answered — a dead socket, a refused
  # connection, a rate limit. That is not evidence about the model's ability, so
  # it must not consume a rung of the escalation ladder: hand the same contract to
  # the declared fallback provider and re-run this attempt number.
  if [ "$dispatch_code" -eq 75 ]; then
    fallback="$(jq -r --arg m "$model" '.models[$m].fallback_model // empty' "$PROVIDERS_CFG")"
    if [ -n "$fallback" ] && [ "$failovers" -lt "$max_failovers" ]; then
      failovers=$((failovers + 1))
      forced_model="$fallback"
      warn "provider fault on '$model' — failing over to '$fallback' and retrying
      attempt $attempt (this does not count against the escalation ladder)"
      "$AITEAM_DIR/bin/task.sh" note "$id" \
        "attempt $attempt: '$model' unreachable (provider fault); failed over to '$fallback' without spending a ladder rung"
      attempt=$((attempt - 1))
      continue
    fi
    die "$id: provider '$model' is unreachable and there is no fallback left
     (${failovers}/${max_failovers} failovers used). This is an outage, not a
     failed implementation — nothing about the task has been disproved. Check
     the provider, then re-run this task unchanged."
  fi

  # 78 is a lifecycle fault raised before anything was dispatched. Retrying runs
  # the identical refusal against the identical state, so looping here spends the
  # ladder on a harness bug and arrives at the orchestrator looking like four
  # models that could not do the work. It did exactly that, twice.
  if [ "$dispatch_code" -eq 78 ]; then
    "$AITEAM_DIR/bin/task.sh" note "$id" "attempt $attempt: dispatch refused — lifecycle fault in the harness, no attempt spent"
    die "$id: the harness could not move this task into IN_PROGRESS, so nothing was
     dispatched and nothing about the work has been judged. Fix the lifecycle
     handling, then re-run this task unchanged."
  fi

  if [ "$dispatch_code" -ne 0 ]; then
    warn "dispatch failed on attempt $attempt — not verifying"
    "$AITEAM_DIR/bin/task.sh" note "$id" "attempt $attempt: dispatch to $model failed"
    continue
  fi

  banner "$id — verifying"
  set +e
  "$AITEAM_DIR/bin/verify.sh" "$id"
  verify_code=$?
  set -e
  if [ $verify_code -eq 75 ]; then
    # The machine could not run the suite, so nothing about the code has been
    # disproved. Retrying would climb the ladder to the most expensive model
    # available and fail there for the same reason, having learned nothing.
    "$AITEAM_DIR/bin/task.sh" note "$id" "attempt $attempt: verification could not run — environment fault, not a verdict on the code"
    die "$id: verification could not run on this machine. This is an environment
     fault, not a failed implementation — the work on the branch has not been
     judged. Fix the environment, then re-run this task unchanged.
     See $EVIDENCE_DIR/$id/verify.log"
  elif [ $verify_code -ne 0 ]; then
    warn "verification failed on attempt $attempt"
    "$AITEAM_DIR/bin/task.sh" note "$id" "attempt $attempt failed verification with $model"
    continue    # retry, escalating the model per the ladder
  fi

  # Mutation check between verification and the gates: verification says the
  # suite is green, this says the suite would have gone red. Failures here are
  # defects in the TESTS, so they are reported and the attempt continues to the
  # gate, which refuses the transition — the work is not discarded, because the
  # implementation may be correct while its proof is not.
  banner "$id — checking that the tests can fail"
  set +e
  "$AITEAM_DIR/bin/mutate.sh" "$id"
  set -e

  banner "$id — gates: IN_PROGRESS -> TESTING"
  set +e
  "$AITEAM_DIR/bin/task.sh" transition "$id" TESTING
  gate_code=$?
  set -e

  # 76 is a soft scope violation: the work is verified, but it touched files the
  # contract did not declare. Retrying cannot fix that — the next attempt has the
  # same contract and will need the same files — so looping here would burn the
  # whole ladder and escalate the model for something the model did not do wrong.
  # Stop and hand the file list to whoever can widen the contract or reject it.
  if [ "$gate_code" -eq 76 ]; then
    warn "$id: verified work touched undeclared files — stopping for a decision.
      No attempt has been spent and nothing has been discarded; the work is
      committed on the task branch. The files are listed above and recorded in
      $EVIDENCE_DIR/$id/scope_violation."
    exit 76
  fi

  # 78 is an illegal transition: the harness asked the lifecycle for something it
  # does not permit. Re-implementing cannot fix a bookkeeping fault, and looping
  # here spends the ladder on it.
  if [ "$gate_code" -eq 78 ]; then
    "$AITEAM_DIR/bin/task.sh" note "$id" "attempt $attempt: verified work could not be advanced — illegal lifecycle transition, a harness fault rather than a verdict on the code"
    die "$id: the work passed verification but the harness could not advance the
     task through its own lifecycle. Nothing about the implementation has been
     disproved and the work is committed on the task branch. Fix the lifecycle
     handling, then re-run this task unchanged."
  fi

  if [ "$gate_code" -ne 0 ]; then
    warn "gate failure after a passing verification"
    continue
  fi

  # ---- review ---------------------------------------------------------------
  if [ "$(task_get "$id" '.review.required')" = "true" ]; then
    "$AITEAM_DIR/bin/task.sh" transition "$id" REVIEW

    rejections="$(task_get "$id" '.review.rejections // 0')"
    banner "$id — independent review (rejection $rejections/$max_rejections)"

    set +e
    "$AITEAM_DIR/bin/review.sh" "$id"
    review_code=$?
    set -e

    # 75: the reviewer never ran. Not a rejection — nothing has been judged, and
    # spending the rejection budget on an unreachable provider stops the task as
    # though a reviewer had found it wanting twice. That is exactly what a 403
    # MODEL_NOT_IN_PLAN did after the codex quota ran out.
    if [ "$review_code" -eq 75 ]; then
      "$AITEAM_DIR/bin/task.sh" note "$id" "review could not run — reviewer unreachable or not entitled on this plan; no rejection recorded"
      die "$id: no review happened, so the work is unjudged and stays at REVIEW.
     Route review to a model this account can actually reach, then re-run."
    fi

    if [ "$review_code" -eq 0 ]; then
      "$AITEAM_DIR/bin/task.sh" transition "$id" VERIFIED
    else
      # review.sh records the rejection alongside the verdict; read it back
      # rather than incrementing again, or a driven run counts each twice.
      rejections="$(task_get "$id" '.review.rejections // 0')"
      "$AITEAM_DIR/bin/task.sh" transition "$id" CHANGES_REQUESTED

      if [ "$rejections" -ge "$max_rejections" ]; then
        warn "$id rejected $rejections times. Stopping.
     At this point the disagreement is usually about the specification rather
     than the code, so the orchestrator reads the diff instead of re-dispatching."
        exit 3
      fi

      # Execute the reviewer's counterexamples BEFORE dispatching the
      # remediation. The reviewer runs read-only and cannot run the suite, so
      # its findings are claims; the harness applying each counterexample and
      # recording CONFIRMED/REFUTED/INCONCLUSIVE turns those claims into
      # evidence the next implementer's prompt carries verbatim. A REFUTED or
      # INCONCLUSIVE result is a disagreement, not a proven defect — the prompt
      # labels it as such. The run never blocks remediation: an INCONCLUSIVE
      # counterexample (an anchor that did not match) is a finding about the
      # counterexample, not a verdict on the work, and the findings themselves
      # are carried either way.
      banner "$id — executing reviewer counterexamples"
      set +e
      "$AITEAM_DIR/bin/counterexample.sh" "$id"
      set -e

      "$AITEAM_DIR/bin/task.sh" transition "$id" IN_PROGRESS
      continue   # remediation attempt; implement.sh injects the findings verbatim
    fi
  else
    banner "$id — no independent review required (low risk); orchestrator reads the diff"
    "$AITEAM_DIR/bin/task.sh" transition "$id" VERIFIED
  fi

  break
done

# ---- handoff ----------------------------------------------------------------
# The lifecycle stops at VERIFIED. MERGED and DONE are reached only after a human
# has merged the pull request, recorded with `worktree.sh confirm-merged`, which
# refuses unless the branch really is an ancestor of the base.
if [ "$do_handoff" -eq 1 ]; then
  banner "$id — preparing branch for review"
  "$AITEAM_DIR/bin/worktree.sh" handoff "$id"
  ok "$id is VERIFIED and ready for a pull request."
  info "  after you merge it:  aiteam/bin/worktree.sh confirm-merged $id"
  info "                       aiteam/bin/task.sh transition $id MERGED"
  info "                       aiteam/bin/task.sh transition $id DONE"
else
  ok "$id is VERIFIED; branch left as-is (--no-handoff)"
fi
