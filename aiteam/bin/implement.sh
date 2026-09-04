#!/usr/bin/env bash
# Dispatch a task to the implementation model inside its own worktree.
#
#   implement.sh <id> [--model M] [--attempt N] [--dry-run]
#
# The prompt is assembled from three layers that never mix:
#   roles/_common.md + roles/<role>.md   generic, portable, domain-free
#   lenses/<lens>.md                     specialist attention, still generic
#   the task contract + its context refs  the only place project knowledge enters
#
# That layering is what keeps the reusable team reusable: a role file that never
# mentions the domain cannot carry assumptions about it into the next project.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
ensure_state_dirs

id="${1:?usage: implement.sh <id> [--model M]}"; shift || true
model_override=""; attempt=""; dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model)   model_override="$2"; shift 2 ;;
    --attempt) attempt="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

role="$(task_get "$id" '.assigned_role')"
model="${model_override:-$(task_get "$id" '.assigned_model')}"
[ -n "$model" ] && [ "$model" != "null" ] || model="$(model_for implementation)"

dispatchable="$(jq -r --arg m "$model" '.models[$m].dispatchable // false' "$PROVIDERS_CFG")"
[ "$dispatchable" = "true" ] || die "model '$model' is not dispatchable as a subprocess (see providers.json)"

# The mirror of the reviewer guard. A read-only model routed to implementation
# burns a full attempt producing nothing, and the failure looks like the model
# being incapable rather than the routing being wrong.
writes="$(jq -r --arg m "$model" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")"
[ "$writes" = "true" ] || die "model '$model' cannot write files, so it cannot implement anything.
     Route implementation to a writing model, or use the *-write variant if the
     provider needs a different sandbox mode to edit files."

# --- worktree ---------------------------------------------------------------
workdir="$("$AITEAM_DIR/bin/worktree.sh" create "$id")"

# A git worktree is a fresh checkout: tracked files only. Dependency directories
# are gitignored, so they do not come across, and every verification command in
# a new worktree exits 127 ("tsc: command not found") until something installs
# them. That failure is indistinguishable from a real one in the log, so it both
# poisons the baseline below and can burn the whole retry ladder on an
# environment problem that no amount of re-implementing will fix.
#
# Installing here rather than leaving it to the agent keeps the baseline honest:
# it is meant to measure the tests that existed before this task, and it cannot
# do that if the runner itself is missing.
ensure_workspace_ready "$workdir" "$EVIDENCE_DIR/$id/install.log" \
  || warn "dependency install failed — see $EVIDENCE_DIR/$id/install.log"

# Record the pre-implementation test count, so a drop later is detectable.
if [ ! -f "$EVIDENCE_DIR/$id/test_count_baseline" ]; then
  info "recording test baseline (failures here are expected before implementation)"
  "$AITEAM_DIR/bin/verify.sh" "$id" --baseline >/dev/null 2>&1 || true
fi

# --- prompt -----------------------------------------------------------------
# The gate runtime is resolved HERE, before the prompt is built, so the prompt
# can name it. The agent's own shell inherits the PATH raised for the provider
# CLI, which is the NEWEST runtime that satisfies the provider's minimum — not
# the floor the gates verify on — so the agent literally cannot see the gate's
# runtime by default. Telling it both keeps "the tests passed for me" from
# becoming possible again. This call must not fail the dispatch: the gates
# re-resolve and fail loudly on their own when the runtime is missing.
gate_runtime_dir="$(gate_runtime_bin 2>/dev/null || true)"
gate_node_bin="${gate_runtime_dir:+$gate_runtime_dir/node}"

# Everything the prompt's shape depends on, resolved once. `prior_attempts` is the
# count of dispatches that already happened — .attempts is incremented after the
# prompt is built, so zero here means this is the first.
prior_attempts="$(task_get "$id" '.attempts // 0')"
open_findings="$(jq '[.findings[]? | select((.status // "open") == "open")] | length' "$(require_task "$id")")"
closed_findings="$(jq '[.findings[]? | select((.status // "open") == "closed")] | length' "$(require_task "$id")")"
# Every word of every open finding, so a context document is quoted when a
# finding MENTIONS it, not only when the reviewer happened to file the finding
# against it. A finding whose remediation named a second file to correct was
# acted on for the first file only: the second was listed by path, not quoted,
# and the agent fixed what it could see.
finding_text="$(jq -r '[.findings[]? | select((.status // "open") == "open")
                        | "\(.file) \(.claim) \(.failure_scenario) \(.remediation)"] | join(" ")' \
                "$(require_task "$id")")"

prompt="$(mktemp)"
{
  cat "$AITEAM_DIR/roles/_common.md"
  echo; echo "---"; echo
  cat "$AITEAM_DIR/roles/$role.md" 2>/dev/null || die "no role file: roles/$role.md"

  while IFS= read -r lens; do
    [ -n "$lens" ] || continue
    echo; echo "---"; echo
    cat "$AITEAM_DIR/lenses/$lens.md" 2>/dev/null || warn "no lens file: lenses/$lens.md"
  done < <(task_get "$id" '.lens[]?')

  echo; echo "---"; echo
  echo "# Your task"; echo
  jq '{id, title, objective, acceptance_criteria, files, required_tests, verification, risk}' \
     "$(require_task "$id")"

  # Context files are pasted in rather than merely referenced: a headless agent
  # that has to go hunting often doesn't, and then invents the contract instead.
  #
  # That reasoning holds for the FIRST attempt, when no implementation exists and
  # the documents are the only statement of the contract. It stops holding on a
  # remediation attempt, where the contract is already embodied in code the agent
  # can read, and re-pasting every document instead spends the budget that the
  # outstanding work needs. Measured on one task: the context block was 66KB of a
  # 92KB prompt, and the attempt was killed by the wall clock still reading,
  # having written nothing. So a retry is given the paths, plus the full text of
  # only those documents an open finding actually points at.
  local_ctx="$(task_get "$id" '.context[]?' || true)"
  if [ -n "$local_ctx" ]; then
    echo; echo "## Required reading"; echo
    if [ "$prior_attempts" -gt 0 ]; then
      echo "You have implemented against these already and the code is in your"
      echo "worktree. They are quoted below only where an open finding points at"
      echo "them; the rest are listed by path — open one if you need it."; echo
    fi
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      file="${ref%%#*}"
      if [ ! -f "$REPO_ROOT/$file" ]; then
        echo "- $ref (not found in repo — ask rather than assume)"
      elif [ "$prior_attempts" -eq 0 ] || printf '%s' "$finding_text" | grep -Fq "$file"; then
        echo "### $file"; echo '```'; cat "$REPO_ROOT/$file"; echo '```'; echo
      else
        echo "- $file (in the repo, not quoted here)"
      fi
    done <<< "$local_ctx"
  fi

  # Prior review findings, verbatim. Summarising them loses the detail that made
  # them actionable, which is why the remediation loop carries the originals.
  #
  # Only the OPEN ones. A finding closed by a later attempt is named but not
  # restated: the harness previously had no notion of a finding being resolved,
  # so every retry received the whole review round and had to work out for itself
  # which items still stood. That cost grew with each round — the longer a task
  # survived remediation, the more of its budget went on rediscovering settled
  # ground, and the less remained for the work actually outstanding.
  if [ "$open_findings" -gt 0 ]; then
    echo; echo "## Review findings you must address"; echo
    echo "A previous attempt was rejected. Each finding below is still OPEN and"
    echo "must be fixed. There are $open_findings of them; that is the whole list."; echo
    jq -r '.findings[] | select((.status // "open") == "open")
           | "- [\(.severity)] \(.file)\(if .line then ":\(.line)" else "" end)\n  Defect: \(.claim)\n  Fails when: \(.failure_scenario)\n  Fix: \(.remediation)\n"' \
       "$(require_task "$id")"

    # Counterexample results are executed evidence, not claims. The reviewer
    # cannot run the suite in its read-only sandbox, so the harness applied each
    # counterexample, ran the named test and recorded what happened. A CONFIRMED
    # counterexample has been demonstrated on this tree — treat it as a
    # reproduction, not as a suggestion. A REFUTED or INCONCLUSIVE one has not,
    # and must not be treated as a proven defect; the reviewer's prediction did
    # not hold, or never ran. The finding list above stays as the reviewer wrote
    # it; this block only says what executing the counterexample showed.
    if [ -f "$EVIDENCE_DIR/$id/counterexample.results" ]; then
      echo; echo "### Counterexample executions"; echo
      echo "The harness applied each open finding's counterexample and ran its test."
      echo "The result is recorded evidence, not the reviewer's claim."; echo
      while IFS=' ' read -r n result; do
        [ -n "$n" ] || continue
        case "$result" in
          CONFIRMED)
            echo "- finding $n: CONFIRMED — the counterexample was applied and the named"
            echo "  test behaved exactly as the reviewer predicted. Treat this finding as"
            echo "  a reproduced defect on this tree."
            ;;
          REFUTED)
            echo "- finding $n: REFUTED — the counterexample was applied but the named"
            echo "  test did not behave as the reviewer predicted. This finding has not"
            echo "  been demonstrated; satisfy it on its merits if you believe it, but do"
            echo "  not treat it as proven."
            ;;
          INCONCLUSIVE)
            echo "- finding $n: INCONCLUSIVE — the counterexample could not be applied"
            echo "  (an anchor did not match, a file collided, or the test filter matched"
            echo "  nothing), so no conclusion was drawn. Check the finding's own text."
            ;;
        esac
      done < "$EVIDENCE_DIR/$id/counterexample.results"
      echo
    fi
  fi

  if [ "$closed_findings" -gt 0 ]; then
    echo; echo "## Findings already closed — do not rework these"; echo
    echo "Earlier attempts fixed these and verification passed afterwards. They are"
    echo "listed so you recognise the code as deliberate. Do not revisit, re-fix or"
    echo "refactor them; if you believe one is still broken, say so and leave it."; echo
    jq -r '.findings[] | select((.status // "open") == "closed")
           | "- [\(.severity)] \(.file)\(if .line then ":\(.line)" else "" end) — \(.claim | .[0:120])"' \
       "$(require_task "$id")"
  fi

  # The verification output from the previous attempt, verbatim. The escalation
  # ladder has always claimed the retry "carries the raw failure log, not a
  # summary of it" — and nothing implemented that. A retry was told only which
  # files had changed, so it had to rediscover what was broken by running the
  # suite itself, which is the most expensive way to learn something the harness
  # already knew and had written to disk.
  #
  # Only the commands that actually FAILED are included, each capped, because a
  # passing test suite's output is thousands of lines that teach the agent
  # nothing and crowd out the contract.
  if [ -f "$EVIDENCE_DIR/$id/verify.exit" ] \
     && [ "$(cat "$EVIDENCE_DIR/$id/verify.exit" 2>/dev/null)" != "0" ] \
     && [ -f "$EVIDENCE_DIR/$id/verify.log" ]; then
    echo; echo "## The last verification run FAILED"; echo
    echo "This is its real output. Fix what it reports before anything else — a"
    echo "criterion cannot be met while the suite is red, and a test that USED to"
    echo "pass and now does not is a regression you introduced, not a test to edit."
    echo
    echo '```'
    awk -v cap=180 '
      /^\$ / { cmd = $0; n = 0; delete buf; next }
      /^--- exit / {
        if ($3 != 0) {
          print cmd
          start = (n > cap) ? n - cap : 0
          if (start > 0) print "... (" start " earlier lines omitted)"
          for (i = start; i < n; i++) print buf[i]
          print $0; print ""
        }
        next
      }
      { buf[n++] = $0 }
    ' "$EVIDENCE_DIR/$id/verify.log"
    echo '```'
  fi

  # An attempt cut short by a turn limit or a wall-clock kill leaves real work
  # committed on the branch. Without being told, the next agent reads a worktree
  # it believes it wrote and either duplicates the finished half or contradicts
  # it. The findings block above covers rejection; this covers truncation, which
  # is a different thing and was previously invisible.
  if [ "$open_findings" -eq 0 ]; then
    prior="$(git -C "$workdir" log --oneline "$(default_branch)..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${prior:-0}" -gt 0 ]; then
      echo; echo "## Unfinished work already on this branch"; echo
      echo "An earlier attempt at THIS task ran out of time and was cut off mid-flight."
      echo "Its work is already committed here — it was not reviewed and not rejected,"
      echo "it is simply incomplete. Read it before you write anything."; echo
      echo "Continue it. Do not start again, do not duplicate what is already correct,"
      echo "and do not assume it is right either — it stopped wherever the clock ran out,"
      echo "so the last thing it touched may be half-written."; echo
      echo "Files it has already changed:"; echo '```'
      git -C "$workdir" diff --stat "$(default_branch)...HEAD" 2>/dev/null
      echo '```'; echo
      echo "Work through the acceptance criteria above and finish the ones not yet met."
    fi
  fi

  # The gate runtime, stated as a fact about the environment rather than as an
  # instruction. The gates re-resolve it themselves and die loudly when it is
  # missing, so the agent can trust the number in the prompt.
  echo; echo "## The runtime your work is judged on"; echo
  if [ -n "$gate_node_bin" ]; then
    echo "The gates verify on this Node runtime, resolved from the project's"
    echo "declared engines.node floor (or the newest installed when none is"
    echo "declared):"
    echo
    echo '```'
    echo "$gate_node_bin"
    echo '```'
    echo
    echo "To run a test exactly as the gates will, call Node through that path"
    echo "rather than relying on PATH — your shell inherits the newer runtime"
    echo "the provider CLI needs, so a bare \`node\` here is not the runtime the"
    echo "gates use:"
    echo
    echo '```'
    echo "PATH=$gate_runtime_dir:\$PATH npm test"
    echo '```'
    echo
    echo "or directly:"
    echo
    echo '```'
    echo "$gate_node_bin \$(command -v npm)"
    echo '```'
    echo
    echo "Verify on this runtime. A test that passes only on a newer Node is a"
    echo "defect, not a pass."
  else
    echo "The gates could not resolve a Node runtime when this prompt was built;"
    echo "they will fail loudly at verify time. Read the gate output if that"
    echo "happens and install the declared runtime."
  fi

  echo; echo "---"; echo
  echo "Work only inside: $workdir"
  echo "Run the verification commands above and report their real output before you finish."
} > "$prompt"

cp "$prompt" "$EVIDENCE_DIR/$id/prompt.md"

# Prompt size is recorded on every dispatch, not just when someone thinks to
# look. It is the one input to a run that is fully under the harness's control
# and it drifted for six attempts without anyone noticing, because nothing ever
# printed it. A number in the evidence directory makes growth visible across
# attempts instead of discoverable only after a budget has been burnt.
prompt_bytes="$(wc -c < "$prompt" | tr -d ' ')"
printf '%s\n' "$prompt_bytes" > "$EVIDENCE_DIR/$id/prompt_bytes"

prompt_budget="$(jq -r --arg m "$model" '.models[$m].prompt_budget_bytes // 60000' "$PROVIDERS_CFG")"
if [ "$prompt_bytes" -gt "$prompt_budget" ]; then
  warn "$id: the prompt is ${prompt_bytes} bytes against a ${prompt_budget}-byte budget.
      An agent that spends its wall clock reading has none left to write. The
      largest quoted sections are below — consider narrowing .context, or closing
      findings that are already fixed (task.sh close-finding)."
  awk '/^### /{name=$2; next} name!=""{bytes[name]+=length($0)+1}
       END{for (n in bytes) printf "      %8d  %s\n", bytes[n], n}' "$prompt" \
    | sort -rn | head -5 >&2
fi

# A prompt is the most expensive thing this harness produces: a bad one is not
# discovered until an attempt has been spent on it. --dry-run builds it, writes
# it where a real dispatch would, and stops — so it can be read first, and so the
# size of what is being sent is a fact rather than an assumption.
if [ "$dry_run" -eq 1 ]; then
  ok "$id: prompt built, not dispatched — $(wc -c < "$prompt" | tr -d ' ') bytes at $EVIDENCE_DIR/$id/prompt.md
     open findings: $open_findings   closed: $closed_findings   prior attempts: $prior_attempts"
  exit 0
fi

# --- dispatch ---------------------------------------------------------------
max_turns="$(jq -r --arg m "$model" '.models[$m].default_max_turns // 60' "$PROVIDERS_CFG")"
timeout_s="$(jq -r --arg m "$model" '.models[$m].timeout_seconds // 2700' "$PROVIDERS_CFG")"

# Built with a read loop rather than mapfile: macOS ships bash 3.2, and this
# harness has to run wherever it is copied.
argv=()
while IFS= read -r a; do
  # The prompt goes over stdin; a contract of this size does not belong in argv.
  # The placeholder is omitted rather than replaced with "-": commandcode's
  # `-p` treats "-" as a literal query string, so an agent would receive a bare
  # dash instead of the contract. With no query argument, `cmd -p` reads stdin.
  [ "$a" = "{PROMPT_FILE_STDIN}" ] && continue
  argv[${#argv[@]}]="$a"
done < <(provider_argv "$model" "MAX_TURNS=$max_turns" "WORKDIR=$workdir")

# Resolve the provider's runtime BEFORE anything is dispatched or recorded, so a
# missing one costs a clear message rather than an attempt.
ensure_provider_runtime "$model"

runlog="$RUNS_DIR/$id-$(date -u +%Y%m%dT%H%M%SZ).log"
info "dispatching $id to $model as '$role' in $workdir"
info "  log: $runlog"

# Route the task to IN_PROGRESS along legal edges, from whichever state it
# re-enters in — a fresh task starts at BACKLOG, a remediation re-enters at
# CHANGES_REQUESTED, a retry at TESTING. Every one of those has a legal path
# back to IN_PROGRESS; the lifecycle simply does not allow jumping straight
# there. Getting this wrong is expensive and silent: the transitions were once
# `|| true` with stderr discarded, so a task stayed where it was, the agent did
# the whole job, and the gate refused IN_PROGRESS->TESTING long afterwards —
# which the driver charged to the model as a failed attempt.
for _hop in 1 2 3 4; do
  current="$(task_get "$id" '.status')"
  [ "$current" = "IN_PROGRESS" ] && break
  case "$current" in
    BACKLOG)  next=READY ;;
    READY)    next=ASSIGNED ;;
    REVIEW)   next=CHANGES_REQUESTED ;;   # a failed verdict re-enters here
    ASSIGNED|CHANGES_REQUESTED|BLOCKED|TESTING) next=IN_PROGRESS ;;
    *)        next="" ;;
  esac
  [ -n "$next" ] || break
  "$AITEAM_DIR/bin/task.sh" transition "$id" "$next" >/dev/null 2>&1 || break
done
current="$(task_get "$id" '.status')"
if [ "$current" != "IN_PROGRESS" ]; then
  # Exit 78, not 1. A generic failure here is read by the driver as a failed
  # attempt and spends a rung of the escalation ladder; this refusal is the
  # harness being unable to move its own task, which no model can fix and which
  # re-dispatching cannot change. It cost two rungs before it exited 1.
  printf '\033[31merror:\033[0m %s\n' "$id: could not move the task to IN_PROGRESS — it is
     stuck at $current. This is a lifecycle fault in the harness, not a failed
     implementation, so no attempt has been spent. Dispatching would do the work
     and then be refused at the gate." >&2
  exit 78
fi
task_set "$id" ".assigned_model = \"$model\" | .attempts = (.attempts + 1)"

# Fingerprint the contract before dispatch. An agent must not be able to change
# what it is judged against — including its own rejection counter or review
# requirement — and this is what makes such a change detectable rather than
# merely forbidden.
fingerprint_before="$(task_fingerprint "$id")"

# caffeinate -i holds off *idle* sleep for the life of the dispatch. It cannot
# stop a lid close, which is why the wall-clock deadline below is still the real
# guarantee rather than a backstop.
launcher=""
command -v caffeinate >/dev/null 2>&1 && launcher="caffeinate -i"

# `set -m` puts the dispatch in its own process group. Without it, killing $pid
# kills the subshell and orphans the agent's actual process — the CLI is a child
# of that subshell, so it keeps running, keeps its lock, and keeps its slot.
set +e
set -m
( cd "$workdir" && exec $launcher "${argv[@]}" < "$prompt" ) > "$runlog" 2>&1 &
pid=$!
set +m

# Stream the agent's output while it works. Writing only to a file made a long
# dispatch indistinguishable from a hung terminal. Tailing rather than piping
# keeps $pid the agent's own pid, which the watchdog below needs to kill the
# right process. AITEAM_QUIET=1 suppresses it.
tailpid=""
if [ "${AITEAM_QUIET:-0}" != "1" ]; then
  ( tail -n +1 -f "$runlog" | node "$AITEAM_DIR/bin/render-events.mjs" >&2 ) 2>/dev/null &
  tailpid=$!
fi

open_follow_window "$id" "$runlog"

# Bound the run: a stalled agent otherwise holds a worktree and a slot forever.
#
# This was `( sleep "$timeout_s"; kill ... ) &` and that is wrong on a laptop.
# sleep(1) runs on a monotonic clock which does not advance while the system is
# suspended, so a 45-minute bound sat unfired through a two-hour wall-clock
# window: the machine slept, the agent's socket died under it, and on wake the
# agent held the worktree indefinitely while producing nothing. Comparing
# `date +%s` against a deadline counts suspended time, because it asks what time
# it is now rather than how long we have been waiting.
#
# The stall check catches the same failure earlier, but it has to measure the
# right thing. Log growth is NOT it: these CLIs buffer their output in headless
# mode, so a perfectly healthy agent can write nothing for its entire run —
# a stall check reading bytes would kill the work it exists to protect.
# Consumed CPU is the honest signal, because a process wedged on a dead socket
# burns none of it. Output still counts as liveness when it happens; either one
# advancing means the agent is working.
group_cpu_seconds() {   # total CPU seconds burned by every process in the group
  ps -eo pgid=,time= 2>/dev/null | awk -v g="$1" '
    $1 == g {
      n = split($2, a, ":")
      s = (n == 3) ? a[1]*3600 + a[2]*60 + a[3] : (n == 2) ? a[1]*60 + a[2] : a[1]
      t += s
    }
    END { printf "%d", t + 0 }'
}

stall_s="$(jq -r --arg m "$model" '.models[$m].stall_seconds // 1200' "$PROVIDERS_CFG")"
deadline=$(( $(date +%s) + timeout_s ))
last_sig=""
last_progress="$(date +%s)"
kill_reason=""

while kill -0 "$pid" 2>/dev/null; do
  now="$(date +%s)"
  size="$(wc -c < "$runlog" 2>/dev/null | tr -d ' ')"; : "${size:=0}"
  sig="$size:$(group_cpu_seconds "$pid")"
  [ "$sig" != "$last_sig" ] && { last_sig="$sig"; last_progress="$now"; }

  if [ "$now" -ge "$deadline" ]; then
    kill_reason="exceeded its ${timeout_s}s wall-clock budget"
  elif [ $(( now - last_progress )) -ge "$stall_s" ]; then
    kill_reason="burned no CPU and produced no output for ${stall_s}s (wedged, most likely a dead connection)"
  fi

  if [ -n "$kill_reason" ]; then
    warn "$id: killing the agent — it $kill_reason"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    break
  fi
  sleep 5
done

wait $pid; code=$?
sleep 1                                    # let the tail flush the final lines
[ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null
set -e

if [ "$(task_fingerprint "$id")" != "$fingerprint_before" ]; then
  die "$id: the task contract changed while the agent was running.
     A dispatched agent must never modify the contract it is judged against.
     This attempt is void. Inspect $runlog, restore the contract from git, and
     re-dispatch. Do not accept work whose acceptance criteria may have moved."
fi

# The agent's work is committed here rather than left loose. Untracked files are
# invisible to `git diff`, so an uncommitted implementation reaches the reviewer
# as an empty diff — which reads as "nothing was done" rather than as a bug.
produced=0
if [ -n "$(git -C "$workdir" status --porcelain)" ]; then
  git -C "$workdir" add -A
  git -C "$workdir" commit -q -m "$id (attempt $(task_get "$id" '.attempts')): $(task_get "$id" '.title')" || true
  info "committed the agent's work to $(task_get "$id" '.isolation.branch')"
  produced=1
fi

# Distinguish "this provider could not be reached" from "this model did the work
# badly". They look identical from outside — an attempt that produced nothing —
# but they call for opposite responses. A weak result should escalate the model
# up the ladder; an unreachable provider should be re-dispatched to a different
# provider without spending a rung, because the ladder exists to answer "is this
# model good enough", and an API that never answered has not been asked.
# The agent's session id, recorded so an interrupted run can be resumed rather
# than restarted. The provider CLI persists a transcript per session; a run that
# dies to a provider fault has usually done real orientation work — reading the
# task's files and locating the code — and throwing that away is why a fault
# costs as much as a failure. Recorded for every run, because which run turns out
# to be worth resuming is only knowable afterwards.
session_id="$(grep -o '"sessionId":"[^"]*"' "$runlog" 2>/dev/null | tail -1 | cut -d'"' -f4)"
if [ -n "$session_id" ]; then
  mkdir -p "$EVIDENCE_DIR/$id"
  printf '%s\n' "$session_id" > "$EVIDENCE_DIR/$id/session"
fi

provider_fault=0
case "$kill_reason" in
  *"burned no CPU"*) provider_fault=1 ;;    # wedged on a socket that never answered
esac
# Connectivity failures the CLI reports itself. Matched against the agent's log
# rather than inferred from the exit code, because these CLIs reuse generic codes
# for everything — the database slice saw exit 6 for a dead network and exit 8
# for a turn limit, and only the log distinguishes them.
#
# Only the TAIL is scanned, and the patterns are anchored to phrasing a CLI emits
# rather than to words a program might contain. The earlier version grepped the
# whole transcript for 'rate limit', which the agent quoted fourteen times while
# reading this repository's own login rate limiter — three quarters of an hour of
# finished, committed work was discarded as an outage. An agent's transcript
# contains the source it read, so anything matched loosely there is matched
# against the codebase, not against the provider.
if [ $code -ne 0 ] && tail -n 80 "$runlog" 2>/dev/null | grep -qiE \
   'unable to connect to the api|check your network|fetch failed|ECONNRESET|ETIMEDOUT|ENOTFOUND|socket hang up|502 bad gateway|503 service unavailable|error sending request for url|transport channel closed|stream (disconnected|closed) before completion|http status (429|5[0-9][0-9])'; then
  provider_fault=1
fi

# Some CLIs report the outage in their own structured result rather than in prose
# the patterns above would catch. commandcode's JSON stream ends with a single
# result object carrying the provider's message in `.error`; a DeepSeek 5xx
# arrives there as "The API server encountered an error. Please try again later."
# and matches none of the connectivity phrasings, so a 37-minute outage was
# charged to the model as a failed attempt.
#
# Matching that FIELD is exact where grepping the transcript is not: the
# transcript contains the source the agent read, this field contains only what
# the CLI itself concluded. The result line is located by its type rather than
# by position, because a killed run has no result line at all.
if [ $code -ne 0 ] && [ "$provider_fault" -eq 0 ]; then
  final_err="$(grep '"type":"result"' "$runlog" 2>/dev/null | tail -1 \
               | jq -r 'select(.subtype == "error") | .error // empty' 2>/dev/null || true)"
  case "$(printf '%s' "$final_err" | tr '[:upper:]' '[:lower:]')" in
    *"api server encountered an error"*|*"please try again later"*|\
    *"service unavailable"*|*"overloaded"*|*"internal server error"*)
      provider_fault=1 ;;
  esac
fi

# A run that changed files was answered by its provider, whatever else went
# wrong. This overrides every heuristic above because it is not a heuristic: the
# work on disk is proof the connection was live. Without it a mid-run transport
# error, or a stall after the last edit, sends a finished attempt down the
# failover path and throws the diff away.
if [ "$produced" -eq 1 ] && [ "$provider_fault" -eq 1 ]; then
  info "$id: the run ended badly but it did change files, so the provider plainly
      answered — treating this as the model's work, not as an outage"
  provider_fault=0
fi

if [ "$provider_fault" -eq 1 ]; then
  fallback="$(jq -r --arg m "$model" '.models[$m].fallback_model // empty' "$PROVIDERS_CFG")"
  printf '%s\n' "$model" > "$EVIDENCE_DIR/$id/provider_fault"
  # The counter was incremented before dispatch, when this still looked like an
  # attempt. It was not one. run.sh rolls back its own loop variable on this
  # path, but the number persisted on the task kept climbing — so the history
  # read "attempt 3" for work that had been tried once, and the commit messages
  # said so too. Roll it back here, where the fault is actually known.
  task_set "$id" '.attempts = (if (.attempts // 0) > 0 then .attempts - 1 else 0 end)'
  warn "$id: '$model' was unreachable or never answered — a provider fault, not a
      verdict on the model's work (full log: $runlog)"
  [ -n "$fallback" ] && info "  providers.json declares a fallback: $fallback"
  echo "$runlog"
  exit 75          # EX_TEMPFAIL: re-dispatch elsewhere, do not spend a ladder rung
fi
rm -f "$EVIDENCE_DIR/$id/provider_fault"

# An agent that failed AND changed nothing has not made an attempt at the task,
# and the driver must not proceed as though it had. This exact case produced the
# worst kind of evidence: `cmd` refused to start on an old Node, exited in
# seconds, and verification then ran against the PREVIOUS attempt's code, passed,
# and sent stale work to the reviewer as if it were a remediation. Verification
# passing says nothing when nothing was verified.
#
# A non-zero exit WITH changes is different and must not fail here: a turn limit
# truncates the run after real work has landed, and discarding that work would
# throw away the whole attempt over its final step.
if [ $code -ne 0 ] && [ "$produced" -eq 0 ]; then
  warn "$id: the agent exited $code without changing anything, so this attempt
      implemented nothing. Not verifying — a pass here would describe the previous
      attempt's code. Full log: $runlog"
  echo "$runlog"
  exit 1
fi

if [ $code -ne 0 ]; then
  warn "$id: agent exited $code but did change files — its work is committed and
      kept (a truncated run can still have landed complete work). Nothing is
      accepted until verify.sh runs, and this script does NOT run it: run.sh
      does that next, a direct implement.sh call leaves it to you. Log: $runlog"
else
  ok "$id: agent finished — nothing is accepted until verify.sh and the gates agree"
fi
echo "$runlog"
