#!/usr/bin/env bash
# Task lifecycle. Every state change goes through here, because this is where the
# evidence gates live. An agent asserting completion satisfies none of them.
#
#   task.sh new <file.json|->        create and validate a task
#   task.sh show <id>                print a task
#   task.sh list [STATUS]            list tasks, optionally filtered
#   task.sh next                     tasks whose dependencies are all DONE
#   task.sh transition <id> <STATE>  move a task, enforcing gates
#   task.sh note <id> <text>         append a history note
#   task.sh findings <id> <file>     attach review findings verbatim
#   task.sh close-finding <id> <n..>  mark findings resolved so retries skip them

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq; need_bin git; need_bin node
ensure_state_dirs

# ---------------------------------------------------------------- transitions

# Patterns are quoted because an unquoted '->' is parsed as a redirection.
legal_transition() {
  case "$1->$2" in
    "BACKLOG->READY"|"BACKLOG->ABANDONED") return 0 ;;
    "READY->ASSIGNED"|"READY->BLOCKED"|"READY->ABANDONED") return 0 ;;
    "ASSIGNED->IN_PROGRESS"|"ASSIGNED->BLOCKED"|"ASSIGNED->ABANDONED") return 0 ;;
    "IN_PROGRESS->TESTING"|"IN_PROGRESS->BLOCKED"|"IN_PROGRESS->ABANDONED") return 0 ;;
    "TESTING->REVIEW"|"TESTING->VERIFIED"|"TESTING->IN_PROGRESS"|"TESTING->BLOCKED") return 0 ;;
    "REVIEW->VERIFIED"|"REVIEW->CHANGES_REQUESTED"|"REVIEW->BLOCKED") return 0 ;;
    "CHANGES_REQUESTED->IN_PROGRESS"|"CHANGES_REQUESTED->ABANDONED") return 0 ;;
    "VERIFIED->MERGED"|"VERIFIED->CHANGES_REQUESTED") return 0 ;;
    "MERGED->DONE"|"MERGED->CHANGES_REQUESTED") return 0 ;;
    "BLOCKED->READY"|"BLOCKED->ASSIGNED"|"BLOCKED->IN_PROGRESS"|"BLOCKED->ABANDONED") return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------- gates
# Each gate reads evidence from disk. None of them ask an agent anything.

gate_diff_not_empty() {
  local id="$1" wt; wt="$(task_get "$id" '.isolation.worktree // empty')"
  [ -n "$wt" ] && [ -d "$REPO_ROOT/$wt" ] || { echo "no worktree recorded for $id"; return 1; }
  if [ -z "$(git -C "$REPO_ROOT/$wt" status --porcelain)" ] && \
     [ -z "$(git -C "$REPO_ROOT/$wt" diff "$(default_branch)"...HEAD --name-only 2>/dev/null)" ]; then
    echo "worktree has no changes — nothing was implemented"; return 1
  fi
  return 0
}

# Whether a task has declared the harness-code exemption. Absence means false: a
# task that has not declared it is treated exactly as every task is today, so
# every path under aiteam/ stays a hard scope violation. The exemption is never
# inferred from the file list or the title — only this explicit field, referenced
# once here, opens harness code to an agent, and nothing else may.
is_harness_maintainer() {
  [ "$(task_get "$1" '.harness_task // false')" = "true" ]
}

gate_files_within_declared_scope() {
  local id="$1" wt changed
  wt="$(task_get "$id" '.isolation.worktree // empty')"
  [ -d "$REPO_ROOT/$wt" ] || { echo "worktree missing"; return 1; }
  changed="$(cd "$REPO_ROOT/$wt" && { git diff "$(default_branch)"...HEAD --name-only 2>/dev/null; git status --porcelain | awk '{print $2}'; } | sort -u)"
  [ -n "$changed" ] || return 0

  # harness state or harness code — these are the two kinds of harness file, and
  # they are deliberately kept apart rather than lumped together, because a
  # declared harness task may write CODE and never STATE.
  #
  # A HARD violation is an agent touching the harness that judges it. That is
  # never forgivable and never a contract problem — see the comment below.
  #
  # A SOFT violation is an ordinary repo file outside the declared list. Every
  # instance of this so far has been an under-specified contract rather than an
  # agent overreaching: a task that legitimately needed a build-config or ignore
  # entry the contract failed to anticipate. Escalating the model for that is
  # answering the wrong question — the ladder exists to ask "is this model good
  # enough", and a file list I wrote too narrowly says nothing about the model.
  # So a soft violation still stops the task, but it costs a decision rather than
  # an attempt. Nothing auto-approves; the orchestrator widens the contract or
  # rejects the work as genuine overreach.
  #
  # The one privilege, and the reason the two kinds of harness file are split: a
  # task that declares the exemption may write harness CODE (never state), but
  # only inside its declared files.expected list — the exemption widens WHICH
  # paths may be listed, never the list itself — and every such write is recorded
  # in the task's history so a rare privilege leaves a trace.
  local violations="" hard=0 harness_writes=""
  local htask=0; is_harness_maintainer "$id" && htask=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Harness STATE — findings, rejection counts, lifecycle transitions, recorded
    # verdicts — is the machinery of judgement itself. No contract field may lift
    # this, because an agent that can write there can retire its own findings and
    # drive its own transitions, which is the exact incident this gate was written
    # after. It keeps its own branch so the exemption below cannot open it.
    case "$f" in
      .aiteam/*)
        hard=1
        violations="$violations  $f  (harness state — never writable by an agent)\n"
        continue ;;
    esac
    # Harness CODE is a hard violation for any task that has not declared the
    # exemption. A declared harness task is judged by files.expected from here on
    # like any other path, and the pass below leaves a record that it wrote under
    # the exemption.
    case "$f" in
      aiteam/*)
        if [ "$htask" -eq 0 ]; then
          hard=1
          violations="$violations  $f  (harness code — only a declared harness task may write this)\n"
          continue
        fi
        harness_writes="$harness_writes  $f\n"
        ;;
    esac
    local allowed=1
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254
      case "$f" in $glob) allowed=0; break ;; esac
    done < <(task_get "$id" '.files.expected[]')
    [ "$allowed" -eq 0 ] || violations="$violations  $f\n"
  done <<< "$changed"

  if [ -n "$violations" ]; then
    if [ "$hard" -eq 1 ]; then
      echo "changes to the harness that judges this task — this attempt is void:"
      printf "$violations"
      rm -f "$EVIDENCE_DIR/$id/scope_violation"
      return 1
    fi
    # Recorded so the driver can tell this apart from a failed implementation,
    # and so the file list survives for whoever decides what to do about it.
    mkdir -p "$EVIDENCE_DIR/$id"
    printf "$violations" > "$EVIDENCE_DIR/$id/scope_violation"
    echo "changes outside declared scope (another task may own these):"
    printf "$violations"
    return 76
  fi
  rm -f "$EVIDENCE_DIR/$id/scope_violation"

  # A privilege that leaves no trace cannot be audited afterwards. The exemption
  # is meant to be rare enough that every use is visible: when a harness task
  # passes this gate with harness code written under a declared exemption, the
  # record of that pass names the files, in the task's own history.
  if [ "$htask" -eq 1 ] && [ -n "$harness_writes" ]; then
    local files; files="$(printf "$harness_writes" | tr '\n' ' ')"
    task_set "$id" ".history += [{at: \"$(now_iso)\", from: .status, to: .status,
      note: \"passed scope gate writing harness code under declared exemption:${files}\"}]"
  fi
  return 0
}

gate_tests_can_fail() {
  local id="$1" f="$EVIDENCE_DIR/$1/mutation.survivors"
  # Absent means the check never ran, which is not the same as passing. A task
  # whose criteria declare no mutation records 0 and passes with a warning from
  # mutate.sh itself; silence here would let the gate be skipped by omission.
  [ -f "$f" ] || { echo "no mutation evidence — run mutate.sh $id"; return 1; }
  local n; n="$(cat "$f" 2>/dev/null || echo 1)"
  [ "$n" = "0" ] || {
    echo "$n criterion test(s) still pass with their guard removed (see $EVIDENCE_DIR/$id/mutation.log)"
    return 1
  }
}

gate_verification_log_exists() {
  [ -f "$EVIDENCE_DIR/$1/verify.exit" ] || { echo "no verification evidence — run verify.sh $1"; return 1; }
}

gate_verification_exit_zero() {
  local code; code="$(cat "$EVIDENCE_DIR/$1/verify.exit" 2>/dev/null || echo 1)"
  [ "$code" = "0" ] || { echo "verification exited $code (see $EVIDENCE_DIR/$1/verify.log)"; return 1; }
}

gate_test_count_not_regressed() {
  local id="$1" cur base
  cur="$(cat "$EVIDENCE_DIR/$id/test_count" 2>/dev/null || echo "")"
  base="$(cat "$EVIDENCE_DIR/$id/test_count_baseline" 2>/dev/null || echo "")"
  # Absent counts mean the runner's output wasn't parseable, not that cheating occurred.
  if [ -z "$cur" ] || [ -z "$base" ]; then
    warn "test counts unavailable for $id — cannot check for deleted or skipped tests"
    return 0
  fi
  if [ "$cur" -lt "$base" ]; then
    echo "test count fell from $base to $cur — tests were removed or skipped"; return 1
  fi
  return 0
}

# A waiver is the owner's recorded decision to accept work over a failing
# review. It is NOT a way to make a verdict say PASS: the verdict, the findings
# and the unmet criteria all stay exactly as the reviewer wrote them, and every
# gate that consults a waiver announces it. Without this the only ways past a
# real refusal are to edit the evidence or to delete the gate, and a harness
# that makes dishonesty the easiest route will eventually get it.
#
# It is deliberately expensive to grant: it requires a named decider, a reason,
# and a successor task that carries the findings forward, so "accepted" can
# never quietly mean "forgotten". `waived_to` is verified to exist and to be
# unfinished — a waiver pointing at a DONE task or at nothing is refused.
gate_waiver() {
  local id="$1" who why to
  who="$(task_get "$id" '.waiver.accepted_by // empty')"
  why="$(task_get "$id" '.waiver.reason // empty')"
  to="$(task_get "$id" '.waiver.waived_to // empty')"
  [ -n "$who" ] && [ -n "$why" ] && [ -n "$to" ] || return 1
  [ -f "$TASKS_DIR/$to.json" ] || { echo "waiver names $to, which does not exist"; return 1; }
  local dest; dest="$(jq -r '.status' "$TASKS_DIR/$to.json")"
  [ "$dest" != "DONE" ] && [ "$dest" != "ABANDONED" ] \
    || { echo "waiver names $to, which is already $dest — the findings have no home"; return 1; }
  printf '\033[33m      waived by %s -> carried to %s: %s\033[0m\n' "$who" "$to" "$why"
  return 0
}

gate_review_verdict_pass() {
  local f="$EVIDENCE_DIR/$1/review.json"
  [ -f "$f" ] || { echo "no review verdict — run review.sh $1"; return 1; }
  local v; v="$(jq -r '.verdict // "MISSING"' "$f")"
  [ "$v" = "PASS" ] && return 0
  echo "review verdict is $v"
  gate_waiver "$1"
}

gate_all_acceptance_criteria_met() {
  local f="$EVIDENCE_DIR/$1/review.json"
  [ -f "$f" ] || { echo "no review verdict to read criteria from"; return 1; }
  local unmet; unmet="$(jq -r '[.criteria[]? | select(.met == false) | .id] | join(", ")' "$f")"
  [ -z "$unmet" ] && return 0
  echo "acceptance criteria not met: $unmet"
  gate_waiver "$1"
}

# The harness does not merge, so MERGED means a human's pull request landed.
# Asked of git rather than of anyone's recollection: the branch must be an
# ancestor of the base. Works whether the PR was squashed, rebased or a merge
# commit, because all three leave the base containing the work.
gate_merged_into_default_branch() {
  local id="$1" branch db; branch="$(task_get "$id" '.isolation.branch // empty')"; db="$(default_branch)"
  [ -n "$branch" ] || { echo "no branch recorded for $id"; return 1; }

  git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$db" 2>/dev/null && return 0

  # A squash merge rewrites history, so ancestry fails even though the work
  # landed. Fall back to the handoff record's confirmation.
  if [ -f "$EVIDENCE_DIR/$id/merge.log" ] && grep -q "merged into $db" "$EVIDENCE_DIR/$id/merge.log"; then
    return 0
  fi
  echo "'$branch' is not in $db — merge the pull request, then run: aiteam/bin/worktree.sh confirm-merged $id"
  return 1
}

gate_rebased_on_default_branch() {
  local id="$1" wt db; wt="$(task_get "$id" '.isolation.worktree')"; db="$(default_branch)"
  git -C "$REPO_ROOT/$wt" merge-base --is-ancestor "$db" HEAD 2>/dev/null \
    || { echo "branch is behind $db — rebase before merging"; return 1; }
}

gate_verification_rerun_after_rebase() {
  local id="$1"
  [ -f "$EVIDENCE_DIR/$id/verify_postrebase.exit" ] \
    || { echo "verification has not been re-run since rebase"; return 1; }
  local code; code="$(cat "$EVIDENCE_DIR/$id/verify_postrebase.exit")"
  [ "$code" = "0" ] || { echo "post-rebase verification exited $code"; return 1; }
}

gate_docs_updated_if_required() {
  local id="$1" risk; risk="$(task_get "$id" '.risk')"
  [ "$risk" = "high" ] || return 0

  # This runs at MERGED->DONE, by which point the two things the old version
  # relied on are both gone: the worktree has been destroyed, and `base...HEAD`
  # is empty because the branch has been absorbed into the base. It therefore
  # reported "changed no documentation" for a task that did write documentation —
  # a gate that fails only after the work is correct and merged is worse than no
  # gate, because the obvious fix is to stop believing it.
  #
  # The recorded diff is the durable answer: captured before review, tamper-
  # evident, and unaffected by anything that happens to the branch afterwards.
  local changed="" patch="$EVIDENCE_DIR/$id/diff.patch"
  if [ -s "$patch" ]; then
    changed="$(sed -n 's|^+++ b/||p' "$patch")"
  else
    local branch; branch="$(task_get "$id" '.isolation.branch // empty')"
    if [ -n "$branch" ] && git -C "$REPO_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
      changed="$(git -C "$REPO_ROOT" diff "$(default_branch)...$branch" --name-only 2>/dev/null || true)"
    fi
  fi

  [ -n "$changed" ] || { echo "no recorded diff for $id — cannot tell whether docs changed"; return 1; }
  echo "$changed" | grep -qE '(^|/)docs/|\.md$' \
    || { echo "high-risk task changed no documentation"; return 1; }
}

run_gates() {
  local id="$1" from="$2" to="$3" key="$from->$to" failed=0
  local checks; checks="$(jq -r --arg k "$key" '.gates[$k][]?.check // empty' "$POLICY_CFG")"
  [ -n "$checks" ] || return 0
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    local out code
    set +e
    out="$("gate_$check" "$id" 2>&1)"; code=$?
    set -e
    if [ "$code" -eq 0 ]; then
      ok "  ✓ $check"
    else
      printf '\033[31m  ✗ %s\033[0m\n' "$check" >&2
      [ -n "$out" ] && printf '      %s\n' "$out" >&2
      # 76 means "the contract was too narrow", not "the work is wrong". It is
      # carried out rather than flattened into a generic failure so the driver can
      # stop for a decision instead of spending an escalation rung on it. A hard
      # failure anywhere still wins: correctness outranks the diagnosis.
      if [ "$code" -eq 76 ] && [ "$failed" -eq 0 ]; then failed=76; else failed=1; fi
    fi
  done <<< "$checks"
  return $failed
}

# ------------------------------------------------------------------ commands

cmd_new() {
  local src="${1:?usage: task.sh new <file.json|->}" tmp id
  tmp="$(mktemp)"
  if [ "$src" = "-" ]; then cat > "$tmp"; else cp "$src" "$tmp"; fi

  id="$(jq -r '.id // empty' "$tmp")"
  if [ -z "$id" ]; then
    local n=1
    while [ -f "$TASKS_DIR/$(printf 'TASK-%04d' "$n").json" ]; do n=$((n+1)); done
    id="$(printf 'TASK-%04d' "$n")"
    jq --arg id "$id" '.id = $id' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  fi
  [ -f "$TASKS_DIR/$id.json" ] && die "task $id already exists"

  jq --arg now "$(now_iso)" '
    .status //= "BACKLOG" | .attempts //= 0 | .findings //= [] |
    .evidence //= {} | .history //= [] | .created_at //= $now | .updated_at = $now
  ' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"

  validate_schema "$tmp" "$AITEAM_DIR/contracts/task.schema.json" \
    || die "task rejected by contract — a task that cannot say how it will be proven correct is not a task"

  # Risk is computed from declared paths and tags, never taken on trust. A task
  # may claim a higher tier than computed; claiming a lower one is refused, which
  # is what stops anyone from quietly downgrading the review of their own work.
  local cls computed needs_review lenses declared rank_c rank_d
  cls="$(node "$AITEAM_DIR/bin/classify.mjs" "$POLICY_CFG" "$tmp")"
  computed="$(echo "$cls" | cut -d' ' -f1)"
  needs_review="$(echo "$cls" | cut -d' ' -f2)"
  lenses="$(echo "$cls" | cut -d' ' -f3)"
  declared="$(jq -r '.risk' "$tmp")"

  rank() { case "$1" in low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; *) echo 0 ;; esac; }
  rank_c="$(rank "$computed")"; rank_d="$(rank "$declared")"
  if [ "$rank_d" -lt "$rank_c" ]; then
    die "task declares risk '$declared' but its paths and tags compute to '$computed'.
     Raise it, or narrow the scope so the higher tier no longer applies."
  fi

  # Review requirement and lenses follow the computed tier rather than the author.
  if [ "$needs_review" = "true" ]; then
    jq '.review.required = true | .review.reviewer //= "reviewer" | .review.rejections //= 0' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  fi
  if [ -n "$lenses" ]; then
    jq --arg l "$lenses" '.lens = ((.lens // []) + ($l | split(","))) | .lens |= unique' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  fi

  mv "$tmp" "$TASKS_DIR/$id.json"
  mkdir -p "$EVIDENCE_DIR/$id"
  ok "created $id"
  echo "$id"
}

cmd_show() { jq . "$(require_task "$1")"; }

cmd_list() {
  local filter="${1:-}"
  printf '%-12s %-18s %-8s %-22s %s\n' ID STATUS RISK MODEL TITLE
  for f in "$TASKS_DIR"/*.json; do
    [ -e "$f" ] || continue
    local s; s="$(jq -r '.status' "$f")"
    [ -n "$filter" ] && [ "$s" != "$filter" ] && continue
    jq -r '[.id, .status, .risk, .assigned_model, .title] | @tsv' "$f" \
      | awk -F'\t' '{printf "%-12s %-18s %-8s %-22s %s\n", $1,$2,$3,$4,$5}'
  done
}

cmd_next() {
  for f in "$TASKS_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status' "$f")" = "READY" ] || continue
    local blocked=0
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ "$(jq -r '.status' "$TASKS_DIR/$dep.json" 2>/dev/null || echo MISSING)" = "DONE" ] || blocked=1
    done < <(jq -r '.depends_on[]?' "$f")
    [ "$blocked" -eq 0 ] && jq -r '[.id, .title] | @tsv' "$f"
  done
}

cmd_transition() {
  local id="${1:?}" to="${2:?}" from
  from="$(task_get "$id" '.status')"
  [ "$from" = "$to" ] && { info "$id already $to"; return 0; }

  # Exit 78 (EX_CONFIG), distinct from a gate refusal. A gate refusing means the
  # WORK is not good enough and retrying may fix it. An illegal transition means
  # the HARNESS asked for something the lifecycle does not allow, and no amount
  # of re-implementing changes that — the driver must stop rather than read it as
  # a bad attempt. It did read it as one: a remediation whose status sat at
  # CHANGES_REQUESTED passed verification twice, was refused here both times, and
  # burned two rungs before escalation stopped it.
  if ! legal_transition "$from" "$to"; then
    printf '\033[31merror:\033[0m %s\n' "illegal transition $from -> $to (see the lifecycle in aiteam/README.md).
     This is a harness fault, not a verdict on the work." >&2
    exit 78
  fi

  # Skipping review is only legal when the risk policy said none was required.
  if [ "$from" = "TESTING" ] && [ "$to" = "VERIFIED" ]; then
    # A task maintaining the harness is the one case a blanket prohibition was
    # traded for a reviewer, so review cannot be switched off for it. Enforced
    # here, as a gate, rather than trusted to the contract's author to have set
    # review.required: a harness task with review disabled is strictly worse than
    # the rule it replaces.
    if is_harness_maintainer "$id"; then
      die "$id edits the harness — independent review is mandatory; transition to REVIEW instead"
    fi
    [ "$(task_get "$id" '.review.required')" = "false" ] \
      || die "$id requires independent review; transition to REVIEW instead"
  fi

  info "gates for $from -> $to:"
  set +e
  run_gates "$id" "$from" "$to"; gate_code=$?
  set -e
  if [ "$gate_code" -eq 76 ]; then
    warn "$id stays $from — the work touched files the contract did not declare.
     This is usually the contract being too narrow rather than the agent
     overreaching, so it is not counted as a failed attempt. Inspect the diff for
     those files, then either widen .files.expected (recording why) and re-run
     this transition, or reject the work as genuine overreach."
    exit 76
  fi
  [ "$gate_code" -eq 0 ] || die "$id stays $from — gates failed. Fix the work, not the gate."

  task_set "$id" "
    .status = \"$to\" |
    .history += [{at: \"$(now_iso)\", from: \"$from\", to: \"$to\"}]
  "
  ok "$id: $from -> $to"
}

cmd_note() {
  local id="${1:?}" text="${2:?}" quoted
  quoted="$(jq -Rn --arg t "$text" '$t')"   # JSON-escape so quotes in the note can't break the expression
  task_set "$id" ".history += [{at: \"$(now_iso)\", from: .status, to: .status, note: $quoted}]"
  ok "noted on $id"
}

# Rebuild a task's status from the evidence on disk and the state of git.
#
# Task files are tracked in git because they are the project's record of what was
# built. The cost is that `git restore` or a branch switch rewinds the LIVE task
# graph while the evidence directory — untracked — stays put, so the record and
# reality silently disagree. This reconstructs the record from the evidence
# rather than from anyone's memory, and refuses to claim more than the evidence
# supports.
cmd_reconcile() {
  local id="${1:?}" f ev branch st
  f="$(require_task "$id")"
  ev="$EVIDENCE_DIR/$id"
  st="BACKLOG"

  [ -d "$ev" ] || die "$id has no evidence directory — nothing to reconcile from"

  # Recover the branch from the handoff record if the task file lost it.
  branch="$(task_get "$id" '.isolation.branch // empty')"
  if [ -z "$branch" ] && [ -f "$ev/handoff.log" ]; then
    branch="$(sed -n 's/^branch: *//p' "$ev/handoff.log" | head -1)"
    [ -n "$branch" ] && info "recovered branch '$branch' from the handoff record"
  fi

  [ -s "$ev/diff.patch" ]                                  && st="IN_PROGRESS"
  [ "$(cat "$ev/verify.exit" 2>/dev/null)" = "0" ]          && st="TESTING"
  [ -f "$ev/review.json" ]                                  && st="REVIEW"
  [ "$(jq -r '.verdict // empty' "$ev/review.json" 2>/dev/null)" = "PASS" ] && st="VERIFIED"

  # MERGED is only claimed when git agrees the branch really landed.
  if [ -n "$branch" ] && [ "$st" = "VERIFIED" ]; then
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$(default_branch)" 2>/dev/null; then
      st="DONE"
    fi
  fi

  local tmp; tmp="$(mktemp)"
  jq --arg st "$st" --arg br "$branch" --arg at "$(now_iso)" '
    .status = $st |
    (if $br != "" then .isolation = {worktree: (.isolation.worktree // ""), branch: $br} else . end) |
    .evidence.verification = ".aiteam/evidence/'"$id"'/verify.log" |
    .evidence.review       = ".aiteam/evidence/'"$id"'/review.json" |
    .history += [{at: $at, from: "RECONCILED", to: $st,
                  note: "status rebuilt from evidence on disk after the tracked task file was rewound"}]
  ' "$f" > "$tmp" && mv "$tmp" "$f"

  ok "$id reconciled to $st"
  jq -r '"  branch:   \(.isolation.branch // "none")\n  evidence: \(.evidence.review // "none")"' "$f" >&2
}

cmd_findings() {
  local id="${1:?}" src="${2:?}" f tmp
  f="$(require_task "$id")"; tmp="$(mktemp)"
  # Findings CLOSED in an earlier round are carried forward; only the open ones
  # are replaced. Attaching used to overwrite the array wholesale, which threw
  # away every record of what a previous round had raised and what was done about
  # it — so the next implementer lost the list of settled ground it must not
  # rework, and the next reviewer lost the history it should read adversarially.
  # A genuinely unresolved finding comes back as a new open one, which is the
  # reviewer's judgement to make and not something this carry-forward can hide.
  jq --slurpfile r "$src" \
     '.findings = ([.findings[]? | select((.status // "open") == "closed")]
                   + ($r[0].findings // []))' "$f" > "$tmp" && mv "$tmp" "$f"
  ok "attached $(jq '[.findings[] | select((.status // "open") == "open")] | length' "$f") open finding(s) to $id, carrying $(jq '[.findings[] | select((.status // "open") == "closed")] | length' "$f") already closed"
}

cmd_close_finding() {
  local id="${1:?}" f tmp n total
  shift
  [ "$#" -gt 0 ] || die "close-finding: name at least one finding number"
  f="$(require_task "$id")"
  total="$(jq '.findings | length' "$f")"
  [ "$total" -gt 0 ] || die "close-finding: $id has no findings attached"

  # Closing a finding is a claim about the repository, so it is recorded with a
  # timestamp and left in place rather than deleted. The next reviewer sees what
  # a previous round raised and what was said to have been done about it; a
  # finding that quietly vanished would be indistinguishable from one that was
  # never raised.
  for n in "$@"; do
    case "$n" in
      ''|*[!0-9]*) die "close-finding: '$n' is not a finding number" ;;
    esac
    [ "$n" -ge 1 ] && [ "$n" -le "$total" ] \
      || die "close-finding: $id has findings 1..$total, not $n"
    tmp="$(mktemp)"
    jq --argjson i "$((n - 1))" --arg at "$(now_iso)" \
       '.findings[$i].status = "closed" | .findings[$i].closed_at = $at' \
       "$f" > "$tmp" && mv "$tmp" "$f"
  done

  task_set "$id" '.'   # refresh updated_at through the one path that owns it
  ok "$id: $(jq '[.findings[] | select((.status // "open") == "closed")] | length' "$f") of $total finding(s) closed, $(jq '[.findings[] | select((.status // "open") == "open")] | length' "$f") still open"
}

case "${1:-}" in
  new)        shift; cmd_new "$@" ;;
  show)       shift; cmd_show "$@" ;;
  list)       shift; cmd_list "$@" ;;
  next)       shift; cmd_next "$@" ;;
  transition) shift; cmd_transition "$@" ;;
  note)       shift; cmd_note "$@" ;;
  findings)   shift; cmd_findings "$@" ;;
  close-finding) shift; cmd_close_finding "$@" ;;
  reconcile)  shift; cmd_reconcile "$@" ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
