#!/usr/bin/env bash
# Exercises the harness's own guards without dispatching any model.
#
# Every case here corresponds to a bug that actually occurred while building the
# harness. They are cheap to run and they are the reason those bugs stay fixed.
#
#   ./aiteam/selfcheck.sh

source "$(dirname "${BASH_SOURCE[0]}")/bin/_lib.sh"

pass_n=0; fail_n=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

check() {  # check <description> <expect-pass|expect-fail> <command...>
  local desc="$1" expect="$2"; shift 2
  local out code
  # errexit is inherited from _lib.sh and would abort the run on the first
  # expected failure, which is most of what this script deliberately triggers.
  set +e
  out="$("$@" 2>&1)"; code=$?
  set -e
  if { [ "$expect" = "expect-pass" ] && [ $code -eq 0 ]; } || \
     { [ "$expect" = "expect-fail" ] && [ $code -ne 0 ]; }; then
    printf '  \033[32m✓\033[0m %s\n' "$desc"; pass_n=$((pass_n + 1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$desc"
    printf '      expected %s, got exit %d\n' "$expect" "$code"
    printf '%s\n' "$out" | head -4 | sed 's/^/      /'
    fail_n=$((fail_n + 1))
  fi
}

echo "Task contract rejects unverifiable work"

cat > "$SANDBOX/vague.json" <<'EOF'
{ "title": "Build authentication.", "objective": "Add auth.", "risk": "low",
  "acceptance_criteria": [], "files": {"expected": ["src/**"]},
  "assigned_role": "backend", "assigned_model": "deepseek-v4-flash",
  "verification": [], "review": {"required": false}, "status": "READY" }
EOF
check "a task with no acceptance criteria or verification is refused" expect-fail \
  node "$AITEAM_DIR/bin/validate.mjs" "$AITEAM_DIR/contracts/task.schema.json" "$SANDBOX/vague.json"

cat > "$SANDBOX/nocrit.json" <<'EOF'
{ "id": "TASK-9999", "title": "Implement a thing that is specific enough to name",
  "objective": "An objective long enough to satisfy the minimum length requirement here.",
  "risk": "low",
  "acceptance_criteria": [{"id": "AC1", "statement": "Something observable happens"}],
  "files": {"expected": ["src/**"]}, "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash", "verification": ["npm test"],
  "review": {"required": false}, "status": "READY" }
EOF
check "a criterion without 'verified_by' is refused" expect-fail \
  node "$AITEAM_DIR/bin/validate.mjs" "$AITEAM_DIR/contracts/task.schema.json" "$SANDBOX/nocrit.json"

echo
echo "Risk classification cannot be downgraded"

cat > "$SANDBOX/auth.json" <<'EOF'
{ "title": "Implement session token validation on the API boundary",
  "objective": "Validate the session token on every authenticated request before any handler runs.",
  "risk": "low",
  "acceptance_criteria": [{"id":"AC1","statement":"An invalid token is rejected with 401","verified_by":"test:a.spec.ts::rejects"}],
  "files": {"expected": ["src/auth/**"]}, "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash", "verification": ["npm test"],
  "review": {"required": false}, "status": "READY" }
EOF
computed="$(node "$AITEAM_DIR/bin/classify.mjs" "$POLICY_CFG" "$SANDBOX/auth.json" | cut -d' ' -f1)"
check "auth work classifies as high regardless of what it declares" expect-pass \
  test "$computed" = "high"

cat > "$SANDBOX/css.json" <<'EOF'
{ "title": "Adjust the spacing on the settings page header",
  "objective": "Tighten the vertical rhythm of the settings header to match the rest of the app.",
  "risk": "low",
  "acceptance_criteria": [{"id":"AC1","statement":"Header spacing matches the scale","verified_by":"manual:visual check"}],
  "files": {"expected": ["src/styles/settings.css"]}, "assigned_role": "frontend",
  "assigned_model": "deepseek-v4-flash", "verification": ["npm run lint"],
  "review": {"required": false}, "status": "READY" }
EOF
computed="$(node "$AITEAM_DIR/bin/classify.mjs" "$POLICY_CFG" "$SANDBOX/css.json" | cut -d' ' -f1)"
check "styling work does not get escalated to high" expect-pass \
  test "$computed" = "low"

echo
echo "Review independence"

reviewer="$(model_for review)"
w="$(jq -r --arg m "$reviewer" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")"
check "the routed reviewer cannot write files" expect-pass test "$w" = "false"

echo
echo "Escalation ladder is dispatchable and can write"

ladder_ok=0
while IFS= read -r m; do
  d="$(jq -r --arg m "$m" '.models[$m].dispatchable // false' "$PROVIDERS_CFG")"
  [ "$d" = "true" ] || continue   # non-dispatchable tiers are the stop condition
  w="$(jq -r --arg m "$m" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")"
  [ "$w" = "true" ] || ladder_ok=1
done < <(jq -r '.escalation.implementation[].model' "$MODELS_CFG")
check "no implementation tier is a read-only model" expect-pass test "$ladder_ok" = "0"

echo
echo "Verification refuses to produce misleading evidence"

# Regression for the worst bug found during construction: verification falling
# back to the repository root and passing against a tree the task never touched.
if [ -d "$TASKS_DIR" ] && ls "$TASKS_DIR"/*.json >/dev/null 2>&1; then
  # `|| true` because the loop's last test legitimately fails when every task
  # already has a worktree, and errexit would otherwise abort the whole run.
  orphan="$(for f in "$TASKS_DIR"/*.json; do
    if [ "$(jq -r '.isolation.worktree // "none"' "$f")" = "none" ]; then jq -r .id "$f"; break; fi
  done || true)"
  if [ -n "$orphan" ]; then
    check "verify.sh refuses a task with no worktree" expect-fail \
      "$AITEAM_DIR/bin/verify.sh" "$orphan"
  else
    printf '  \033[2m—\033[0m no worktree-less task available to test against\n'
  fi
fi

check "verify.sh treats a zero-test run as failure" expect-pass \
  grep -q "zero tests executed" "$AITEAM_DIR/bin/verify.sh"
check "the test count is parsed by testcount.mjs, not by a loose regex" expect-pass \
  grep -q 'testcount.mjs' "$AITEAM_DIR/bin/verify.sh"

# A loose regex once matched the "0 test" inside npm's banner (`> proj@0.1.0 test`)
# and discarded two correct implementations, so assert both directions.
printf '> proj@0.1.0 test\n> vitest run\n\n Test Files  2 passed (2)\n      Tests  7 passed (7)\n' > "$SANDBOX/pass.log"
printf '> proj@0.1.0 test\n> vitest run\n\nNo test files found, exiting with code 1\n' > "$SANDBOX/empty.log"
printf 'some unfamiliar output\n' > "$SANDBOX/odd.log"
check "an npm banner containing a version number is not read as zero tests" expect-pass \
  test "$(node "$AITEAM_DIR/bin/testcount.mjs" "$SANDBOX/pass.log")" = "passed 7"
check "a run with no test files is read as zero" expect-pass \
  test "$(node "$AITEAM_DIR/bin/testcount.mjs" "$SANDBOX/empty.log")" = "zero"
check "an unrecognised runner reports unknown rather than zero" expect-pass \
  test "$(node "$AITEAM_DIR/bin/testcount.mjs" "$SANDBOX/odd.log")" = "unknown"

echo
echo "Agents cannot rewrite their own acceptance machinery"

# Regression for the most serious bug found during construction: an implementer
# reset its own rejection counter, drove its own lifecycle transitions and edited
# the review schema that judges it, because the scope gate exempted .aiteam/*.
check "the scope gate treats .aiteam/ as a violation, with no exemption" expect-fail \
  grep -qE 'case "\$f" in \.aiteam/\*\) continue' "$AITEAM_DIR/bin/task.sh"
check "the scope gate names harness paths as violations" expect-pass \
  grep -q 'harness state or harness code' "$AITEAM_DIR/bin/task.sh"
check "the task contract is fingerprinted before dispatch" expect-pass \
  grep -q 'fingerprint_before=' "$AITEAM_DIR/bin/implement.sh"
check "a changed contract voids the attempt" expect-pass \
  grep -q 'the task contract changed while the agent was running' "$AITEAM_DIR/bin/implement.sh"
check "agents are told the harness is off limits" expect-pass \
  grep -q 'Never touch the harness' "$AITEAM_DIR/roles/_common.md"
check "the fingerprint ignores fields the harness legitimately moves" expect-pass \
  grep -q 'del(.status, .history, .attempts, .evidence' "$AITEAM_DIR/bin/_lib.sh"

echo
echo "A too-narrow contract is not a failed model"

# Behavioural, not textual. Each case builds a throwaway repo, copies the harness
# into it and runs the real transition, so it also exercises the portability claim.
# Every scope violation seen on this project was an under-specified contract, and
# escalating the model for that answers a question nobody asked — but an agent
# editing the harness that judges it must stay unforgivable.
check "work inside the declared scope passes the gate" expect-pass \
  "$AITEAM_DIR/tests/scope-gate.sh" clean
check "an undeclared ordinary file stops for a decision rather than failing outright" expect-pass \
  "$AITEAM_DIR/tests/scope-gate.sh" soft
check "an agent editing the harness is still a hard, unforgivable failure" expect-pass \
  "$AITEAM_DIR/tests/scope-gate.sh" hard
check "the driver stops on a soft violation instead of spending an attempt" expect-pass \
  grep -q 'gate_code" -eq 76' "$AITEAM_DIR/bin/run.sh"

echo
echo "You can watch what an agent is actually doing"

# watch.sh reports which processes are alive and which commands ran. It never
# showed the agent's own reasoning, tool calls or results — and Command Code
# buffers plain text in headless mode, so tailing the log showed nothing at all
# until the run ended. Asking for JSON makes the same run stream event by event.
check "the implementer is asked for a streaming event format" expect-pass \
  jq -e '.models["deepseek-v4-flash"].argv | index("--output-format") != null' \
  "$AITEAM_DIR/config/providers.json"
check "there is a viewer for a running agent" expect-pass \
  test -x "$AITEAM_DIR/bin/follow.sh"
check "dispatch opens a window on the run" expect-pass \
  grep -q 'open_follow_window' "$AITEAM_DIR/bin/implement.sh"
check "review opens one too — the reviewer is an agent as well" expect-pass \
  grep -q 'open_follow_window' "$AITEAM_DIR/bin/review.sh"
check "opening a window can be disabled for headless runs" expect-pass \
  grep -q 'AITEAM_NO_TERMINAL' "$AITEAM_DIR/bin/_lib.sh"

# The renderer has to serve both providers: one streams JSON events, the other
# writes plain text. A viewer that only understood one would go blank on the other.
printf '{"type":"event","event":{"type":"tool_queued","toolName":"read_file","input":{"file_path":"/x/y.ts"}}}\n' \
  > "$SANDBOX/events.ndjson"
printf 'a plain codex line\n' > "$SANDBOX/plain.log"
check "the renderer renders a JSON tool event" expect-pass \
  sh -c 'node "$1" < "$2" | grep -q read_file' sh "$AITEAM_DIR/bin/render-events.mjs" "$SANDBOX/events.ndjson"
check "the renderer passes plain-text output through untouched" expect-pass \
  sh -c 'node "$1" < "$2" | grep -q "a plain codex line"' sh "$AITEAM_DIR/bin/render-events.mjs" "$SANDBOX/plain.log"

echo
echo "Concurrency"
check "run.sh takes a per-task lock" expect-pass \
  grep -q 'task_lock "\$id"' "$AITEAM_DIR/bin/run.sh"

echo
echo "Implementation reaches the reviewer"
# Untracked files are invisible to `git diff`, so uncommitted work reached the
# reviewer as an empty diff and read as "nothing was done".
check "the agent's work is committed before review" expect-pass \
  grep -q 'committed the agent.s work' "$AITEAM_DIR/bin/implement.sh"

echo
echo "State resolves to the main repository"
# A worktree carries a stale committed copy of .aiteam/. Resolving to it makes the
# harness read and write the wrong state while appearing to work perfectly.
check "REPO_ROOT is derived from git's common dir, not the script's parent" expect-pass \
  grep -q 'rev-parse --git-common-dir' "$AITEAM_DIR/bin/_lib.sh"
if [ -d "$WT_DIR" ] && [ -n "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
  some_wt="$(ls -d "$WT_DIR"/*/ 2>/dev/null | head -1)"
  from_root="$("$AITEAM_DIR/bin/task.sh" list | wc -l)"
  from_wt="$(cd "$some_wt" && "$AITEAM_DIR/bin/task.sh" list | wc -l)"
  check "the same task list is seen from inside a worktree" expect-pass \
    test "$from_root" = "$from_wt"
fi

echo
echo "The harness does not merge its own work"
check "run.sh has no merge step" expect-fail \
  grep -qE 'worktree\.sh" (integrate|merge)' "$AITEAM_DIR/bin/run.sh"
check "schedule.sh has no merge step" expect-fail \
  grep -qE 'worktree\.sh" (integrate|merge)' "$AITEAM_DIR/bin/schedule.sh"
check "no script performs a git merge" expect-fail \
  grep -rqE 'git .*merge --ff-only|git .*\bmerge\b [^-]' "$AITEAM_DIR/bin/"
check "MERGED can only be recorded against a real ancestor check" expect-pass \
  grep -q 'merge-base --is-ancestor' "$AITEAM_DIR/bin/worktree.sh"

echo
echo "A stalled dispatch is actually bounded"

# A 45-minute `sleep` watchdog sat unfired through a two-hour window because the
# laptop suspended: sleep(1) runs on a monotonic clock that does not advance
# while the system is asleep. The bound has to be a wall-clock deadline.
check "the watchdog is a wall-clock deadline, not a monotonic sleep" expect-pass \
  grep -q 'deadline=$(( $(date +%s) + timeout_s ))' "$AITEAM_DIR/bin/implement.sh"

# Matched against non-comment lines only: the fix documents the old shape in a
# comment, and a check that cannot tell code from prose about code is worthless.
check "the old sleep-then-kill watchdog is gone" expect-fail \
  sh -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "\(\s*sleep \"\\\$timeout_s\";\s*kill"' \
  sh "$AITEAM_DIR/bin/implement.sh"

# Killing the subshell orphaned the CLI, which is a child of it — the agent kept
# running, kept its worktree and kept its slot.
check "the timeout kills the whole process group, not just the subshell" expect-pass \
  grep -q 'kill -TERM -"$pid"' "$AITEAM_DIR/bin/implement.sh"

check "the dispatch gets its own process group so that kill can work" expect-pass \
  grep -q '^set -m' "$AITEAM_DIR/bin/implement.sh"

check "a wedged dispatch is detected as stalled" expect-pass \
  grep -q 'stall_s' "$AITEAM_DIR/bin/implement.sh"

# Liveness was first written as "the log grew", which is wrong: these CLIs buffer
# output in headless mode, so a healthy agent is silent for its whole run and the
# check would have killed the work it exists to protect. A wedged process burns
# no CPU; a working one does, whether or not it has printed anything yet.
check "liveness is measured by consumed CPU, not by log growth alone" expect-pass \
  grep -q 'group_cpu_seconds' "$AITEAM_DIR/bin/implement.sh"

check "every dispatchable model declares a stall budget" expect-pass \
  jq -e '[.models[] | select(.dispatchable == true)]
         | all((.stall_seconds | type) == "number")' \
  "$AITEAM_DIR/config/providers.json"

echo
echo "Verification runs against a real workspace"

# A git worktree is tracked files only. Without an install, every verification
# command exits 127 and the failure is indistinguishable from a real one, which
# poisons the baseline and burns the retry ladder on an environment problem.
check "a fresh worktree gets its dependencies before the baseline is recorded" expect-pass \
  grep -q 'ensure_workspace_ready "$workdir"' "$AITEAM_DIR/bin/implement.sh"

# The 127s never showed up at dispatch — they showed up at verification, after an
# agent had been interrupted part-way through its own install.
check "verification installs dependencies rather than assuming them" expect-pass \
  grep -q 'ensure_workspace_ready "$workdir"' "$AITEAM_DIR/bin/verify.sh"

check "a missing toolchain is reported as an environment fault, not a failed attempt" expect-pass \
  grep -q 'env_fault' "$AITEAM_DIR/bin/verify.sh"

# A half-written node_modules survives `git clean -fd` because it is gitignored,
# so directory existence is not evidence of a usable install.
check "an incomplete install is detected by npm's completion marker" expect-pass \
  grep -q 'node_modules/.package-lock.json' "$AITEAM_DIR/bin/_lib.sh"

# Attempt 1 of the database slice died mid-work at 60 turns, and the CLI's own
# advice was to double it. A turn budget too small for the task looks exactly
# like a model that cannot do the task.
#
# Not every CLI HAS a turn budget — Claude Code 2.1.74 exposes no --max-turns —
# so the rule is that a writing model is bounded, by turns where the runner
# supports them and by the wall clock regardless. An unbounded writing agent is
# the thing being prevented, not a specific flag.
check "an implementing model that supports turns gets a budget larger than the one that truncated a slice" expect-pass \
  jq -e '[.models[] | select(.dispatchable == true and .writes_files == true and has("default_max_turns"))]
         | all(.default_max_turns >= 140)' "$AITEAM_DIR/config/providers.json"

check "every implementing model is bounded by a wall clock whatever its runner supports" expect-pass \
  jq -e '[.models[] | select(.dispatchable == true and .writes_files == true)]
         | length > 0 and all(.timeout_seconds >= 1200)' "$AITEAM_DIR/config/providers.json"

echo
echo "An unreachable provider is not a failed model"

# The escalation ladder answers "is this model good enough". An API that never
# answered has not been asked, so spending a rung on it promotes the task toward
# the orchestrator for a reason that has nothing to do with the work.
#
# WHETHER a model declares a fallback is the task owner's call — substituting a
# different model changes what produced the code, and some owners want that
# decision made by a person rather than by a retry loop. What the harness must
# guarantee either way is that the absence of a fallback STOPS the run instead
# of quietly carrying on, and that failover never happens unless one was named.
failover_requires_a_declared_fallback() {
  grep -q 'if \[ -n "$fallback" \] && \[ "$failovers" -lt "$max_failovers" \]' \
    "$AITEAM_DIR/bin/run.sh"
}

check "failover happens only when a fallback is explicitly declared" expect-pass \
  failover_requires_a_declared_fallback

check "a provider fault with no fallback stops rather than substituting a model" expect-pass \
  grep -q 'is unreachable and there is no fallback left' "$AITEAM_DIR/bin/run.sh"

# A rung naming a model nobody may dispatch fails at the moment it is reached —
# after two real failures, when the task is already in trouble. Turning a model
# off should be caught here instead, by the check that runs before any dispatch.
every_ladder_rung_is_dispatchable() {
  jq -e --slurpfile p "$AITEAM_DIR/config/providers.json" '
    [ .escalation.implementation[]
      | select(.model != "opus-5")
      | select(($p[0].models[.model].dispatchable // false) != true)
    ] | length == 0
  ' "$AITEAM_DIR/config/models.json" >/dev/null
}

check "every model on the escalation ladder can actually be dispatched" expect-pass \
  every_ladder_rung_is_dispatchable

check "a provider fault exits with a distinct code rather than a generic failure" expect-pass \
  grep -q 'exit 75' "$AITEAM_DIR/bin/implement.sh"

check "failing over does not consume an escalation rung" expect-pass \
  grep -q 'attempt=$((attempt - 1))' "$AITEAM_DIR/bin/run.sh"

check "failover is bounded so a total outage stops instead of spinning" expect-pass \
  jq -e '.escalation.max_provider_failovers | type == "number"' "$AITEAM_DIR/config/models.json"

# Fixtures taken verbatim from the real logs this rule was written against. These
# CLIs reuse generic exit codes — the same slice saw one code for a dead network
# and another for a turn limit — so the log text is what separates them.
#
# The pattern is READ OUT OF implement.sh rather than copied here. It was copied
# once, the two drifted, and the copy kept passing while the original was wrong.
FAULT_PAT="$(sed -n "s/^   '\(unable to connect.*\)'; then\$/\1/p" "$AITEAM_DIR/bin/implement.sh")"
check "the connectivity pattern is still extractable from dispatch" expect-pass \
  test -n "$FAULT_PAT"

printf 'Error: Unable to connect to the API. Please check your network connection.\n' > "$SANDBOX/outage.log"
printf 'Warning: Reached maximum conversation turns (60). The response may be incomplete.\n' > "$SANDBOX/turns.log"
# An agent's transcript contains the source it read. This one quotes a login rate
# limiter, which is a thing this repository actually implements — and the earlier
# pattern matched it fourteen times, discarding forty-five minutes of finished,
# committed work as an outage. A transcript is not a diagnostic channel.
printf 'reading api/src/auth/rateLimit.ts\n' > "$SANDBOX/quoted.log"
printf '// the login rate limit survives horizontal scaling\n' >> "$SANDBOX/quoted.log"
printf 'test: refuses the 429 too many requests case\n' >> "$SANDBOX/quoted.log"

check "a real connection failure is classified as a provider fault" expect-pass \
  grep -qiE "$FAULT_PAT" "$SANDBOX/outage.log"

check "a turn limit is NOT classified as a provider fault" expect-fail \
  grep -qiE "$FAULT_PAT" "$SANDBOX/turns.log"

check "an agent quoting rate-limiting source is NOT a provider fault" expect-fail \
  grep -qiE "$FAULT_PAT" "$SANDBOX/quoted.log"

# A provider's own structured result is the one channel in a run log that
# contains only what the CLI concluded, never what the agent read. A 5xx from
# the model provider arrives there and matches none of the connectivity prose
# above, which once charged a 37-minute outage to the model as a failed attempt.
printf '{"type":"event","event":{"type":"thinking_delta","delta":"clock"}}\n' \
  > "$SANDBOX/apierror.log"
printf '{"type":"result","subtype":"error","error":"Error: The API server encountered an error. Please try again later."}\n' \
  >> "$SANDBOX/apierror.log"
# A run that ended cleanly reports success in the same place and must not match.
printf '{"type":"result","subtype":"success","finalText":"done"}\n' \
  > "$SANDBOX/apiok.log"

check "a provider 5xx in the CLI's structured result is a provider fault" expect-pass \
  sh -c 'grep "\"type\":\"result\"" "$1" | tail -1 \
           | jq -r "select(.subtype == \"error\") | .error // empty" \
           | grep -qi "api server encountered an error"' sh "$SANDBOX/apierror.log"

check "a successful run's result line is NOT a provider fault" expect-fail \
  sh -c 'grep "\"type\":\"result\"" "$1" | tail -1 \
           | jq -r "select(.subtype == \"error\") | .error // empty" \
           | grep -q .' sh "$SANDBOX/apiok.log"

check "implement.sh reads the structured result, not just the transcript prose" expect-pass \
  grep -q 'select(.subtype == "error")' "$AITEAM_DIR/bin/implement.sh"

# The counter is incremented before dispatch, when the run still looks like an
# attempt. On the fault path it was not one, and a counter that keeps climbing
# through outages misreports the history and the commit messages built from it.
rollback_precedes_exit_75() {
  awk '
    /provider_fault" -eq 1 \]; then/ { in_block = 1 }
    in_block && /attempts = \(if/     { rolled_back = 1 }
    in_block && /exit 75/             { exit rolled_back ? 0 : 1 }
    END                               { if (!in_block) exit 1 }
  ' "$AITEAM_DIR/bin/implement.sh"
}

check "a provider fault rolls back the attempt counter it already incremented" expect-pass \
  rollback_precedes_exit_75

# A fatal CLI error kills the run, so it is at the end. Scanning the whole
# transcript means scanning the codebase the agent read on its way there.
check "only the tail of a run log is scanned for connectivity failures" expect-pass \
  grep -q 'tail -n 80 "$runlog"' "$AITEAM_DIR/bin/implement.sh"

# Not a heuristic: files on disk prove the connection was live. Whatever went
# wrong afterwards, this was the model's work and must be judged as such.
check "a run that changed files is never classified as an outage" expect-pass \
  sh -c 'grep -A6 "the run ended badly but it did change files" \
           "$1/bin/implement.sh" | grep -q "^  provider_fault=0$"' \
  sh "$AITEAM_DIR"

# The ladder has always claimed a retry "carries the raw failure log, not a
# summary of it". Nothing implemented that: a retry was told which files had
# changed and left to rediscover what was broken by running the suite itself.
prompt_carries_the_failure_output() {
  grep -q 'The last verification run FAILED' "$AITEAM_DIR/bin/implement.sh"
}

# A passing suite's output is thousands of lines that teach nothing and crowd
# out the contract, so only the commands that actually failed may be included.
only_failed_commands_are_included() {
  grep -q 'if ($3 != 0)' "$AITEAM_DIR/bin/implement.sh"
}

check "a retry prompt carries the previous verification failure verbatim" expect-pass \
  prompt_carries_the_failure_output

check "only the verification commands that failed are pasted into the prompt" expect-pass \
  only_failed_commands_are_included

# vitest -t takes a REGEX, and test names here routinely contain parentheses.
# A filter copied verbatim from such a name matches nothing: the files are found
# and every test in them is skipped, so "Test Files" is present and the older
# guards were satisfied while zero tests ran. The mutation then scores on the
# process exit code alone — clean exit reads SURVIVED, a mutation that breaks
# parsing reads killed. That second one is false confidence, which is worse.
mutation_requires_a_test_to_have_run() {
  grep -q 'Tests +.*(passed|failed)' "$AITEAM_DIR/bin/mutate.sh"
}

check "a mutation run counts only if a test actually passed or failed" expect-pass \
  mutation_requires_a_test_to_have_run

# A remediation prompt grows with every round it survives. The findings block
# carried every item the reviewer had ever raised, closed or not, and the context
# block re-pasted every document in full — measured at 66KB of a 92KB prompt on a
# task in its sixth attempt. That attempt spent its entire wall-clock budget
# reading and was killed having written nothing. The cost scaled the wrong way:
# the more rounds a task survived, the less budget remained for the work still
# outstanding. Both halves are guarded here.
retry_prompt_carries_only_open_findings() {
  grep -q 'select((.status // "open") == "open")' "$AITEAM_DIR/bin/implement.sh"
}

closed_findings_are_named_not_restated() {
  grep -q 'do not rework these' "$AITEAM_DIR/bin/implement.sh"
}

a_retry_is_not_re_pasted_every_document() {
  grep -q 'prior_attempts" -eq 0 \] || printf' "$AITEAM_DIR/bin/implement.sh"
}

a_finding_can_be_recorded_as_closed() {
  grep -q 'close-finding' "$AITEAM_DIR/bin/task.sh"
}

prompt_size_is_recorded_every_dispatch() {
  grep -q 'prompt_bytes' "$AITEAM_DIR/bin/implement.sh"
}

prompt_size_has_a_budget() {
  grep -q 'prompt_budget_bytes' "$AITEAM_DIR/bin/implement.sh"
}

check "the size of every dispatched prompt is recorded as evidence" expect-pass \
  prompt_size_is_recorded_every_dispatch
check "a prompt over budget says so rather than growing silently" expect-pass \
  prompt_size_has_a_budget

check "a retry is given the open findings, not every finding ever raised" expect-pass \
  retry_prompt_carries_only_open_findings
check "findings already closed are named so they are not reworked" expect-pass \
  closed_findings_are_named_not_restated
check "a retry is not re-sent the full text of every context document" expect-pass \
  a_retry_is_not_re_pasted_every_document
check "closing a finding is a recorded state change, not a deletion" expect-pass \
  a_finding_can_be_recorded_as_closed

# Narrowing the context has a failure mode of its own. A finding is filed against
# ONE file, but its remediation may name others — and a document listed by path
# rather than quoted is a document the agent did not read. One such finding was
# actioned for its filed file and missed the second the remediation named. The
# match is against the finding's whole text, not its .file field.
context_is_matched_against_the_whole_finding() {
  grep -q 'finding_text' "$AITEAM_DIR/bin/implement.sh"
}
check "a document any open finding mentions is quoted, not just listed" expect-pass \
  context_is_matched_against_the_whole_finding

echo
echo "A dispatch that produced nothing is not evidence"

# The worst evidence bug since the vacuous-green fallback: `cmd` refused to start
# on an old Node, exited in seconds having changed nothing, and the driver then
# verified the PREVIOUS attempt's code, passed, and sent stale work to the
# reviewer as a remediation. Verification passing means nothing when nothing ran.
check "a failed dispatch that changed nothing is not verified" expect-pass \
  grep -q 'implemented nothing' "$AITEAM_DIR/bin/implement.sh"
# The complement: a turn limit truncates a run after real work has landed, and
# failing on exit code alone would throw that whole attempt away.
truncated_work_is_kept_not_discarded() {
  grep -q 'its work is committed and' "$AITEAM_DIR/bin/implement.sh"
}
# implement.sh dispatches; it does not verify. The warning on this path used to
# say "verifying what it produced", which is true of the driver and false of the
# script printing it — so a direct implement.sh call left work sitting unverified
# while the operator had been told otherwise. The claim now names who verifies.
the_driver_verifies_after_dispatch() {
  grep -q 'bin/verify.sh" "$id"' "$AITEAM_DIR/bin/run.sh"
}
check "a failed dispatch that DID change files keeps its work" expect-pass \
  truncated_work_is_kept_not_discarded
check "the driver verifies after every dispatch" expect-pass \
  the_driver_verifies_after_dispatch

# A provider CLI is a Node program, so nvm's per-shell default silently decides
# whether it can start at all. Resolving it explicitly makes dispatch independent
# of which node a given terminal happened to have active.
check "the provider's runtime requirement is declared" expect-pass \
  jq -e '.providers.commandcode.min_node_major | type == "number"' \
  "$AITEAM_DIR/config/providers.json"
check "dispatch resolves the runtime before spending an attempt" expect-pass \
  grep -q 'ensure_provider_runtime' "$AITEAM_DIR/bin/implement.sh"
check "review resolves it too" expect-pass \
  grep -q 'ensure_provider_runtime' "$AITEAM_DIR/bin/review.sh"
check "a runtime new enough for the provider is actually findable here" expect-pass \
  sh -c '. "$1/bin/_lib.sh"; node_bin_at_least "$(jq -r ".providers.commandcode.min_node_major" "$1/config/providers.json")" >/dev/null' \
  sh "$AITEAM_DIR"

echo
echo "Who reviewed it is part of the evidence"

# Reviewers became substitutable when the codex quota ran out. They are not
# equally independent: a sandboxed separate-vendor model, the same model reached
# through a different CLI with only permission-mode isolation, and the
# orchestrating session reviewing its own contracts are three different things.
check "the reviewer's identity is recorded on the task" expect-pass \
  grep -q 'review.reviewer = ' "$AITEAM_DIR/bin/review.sh"
# A runner that cannot impose the schema still cannot smuggle prose past the gate.
check "a verdict recovered from a log is still schema-validated" expect-pass \
  sh -c 'grep -A6 "verdict_from_log" "$1/bin/review.sh" | grep -q "validate_schema" \
         || grep -q "validate_schema" "$1/bin/review.sh"' sh "$AITEAM_DIR"
check "a reviewer model may never be one that writes files" expect-pass \
  jq -e '[.models | to_entries[] | select(.value.role_class == "reviewer")]
         | length > 0 and all(.value.writes_files == false)' "$AITEAM_DIR/config/providers.json"

echo
echo "A passing review can still have found something"

# A PASS judges the acceptance criteria; it does not assert that nothing is
# wrong. This reviewer passed work while reporting a medium-severity race in it,
# and attaching findings only on FAIL printed them to a terminal and lost them.
check "findings are attached regardless of the verdict" expect-pass \
  sh -c 'grep -B6 "if \[ \"\$verdict\" = \"PASS\" \]" "$1/bin/review.sh" | grep -q "task.sh\" findings"' \
  sh "$AITEAM_DIR"
check "a pass carrying findings says so rather than reporting a clean bill" expect-pass \
  grep -q 'Passing the criteria is not the same as nothing being wrong' "$AITEAM_DIR/bin/review.sh"

echo
echo "A task the harness cannot advance is a harness fault"

# A task is created at BACKLOG, and BACKLOG->ASSIGNED is not a legal transition.
# Dispatch used to attempt it silenced and `|| true`, so the status never moved,
# the work ran to completion, and the gate refused IN_PROGRESS->TESTING forty
# minutes later — which the driver read as a failed attempt and re-dispatched.
check "dispatch routes to IN_PROGRESS from whatever state the task re-enters in" expect-pass \
  grep -q 'ASSIGNED|CHANGES_REQUESTED|BLOCKED|TESTING) next=IN_PROGRESS' "$AITEAM_DIR/bin/implement.sh"
# Remediation re-enters at CHANGES_REQUESTED. Treating that as "already past
# IN_PROGRESS" is what let a fixed, verified remediation be refused at the gate
# twice and charged to the model both times.
check "a remediation at CHANGES_REQUESTED has a legal route to IN_PROGRESS" expect-pass \
  grep -q '"CHANGES_REQUESTED->IN_PROGRESS"' "$AITEAM_DIR/bin/task.sh"
check "an illegal transition is a distinct exit code, not a gate refusal" expect-pass \
  grep -q 'exit 78' "$AITEAM_DIR/bin/task.sh"
check "the driver stops on it rather than re-implementing" expect-pass \
  grep -q 'gate_code" -eq 78' "$AITEAM_DIR/bin/run.sh"
check "a task that will not reach IN_PROGRESS stops dispatch instead of running" expect-pass \
  grep -q 'could not move the task to IN_PROGRESS' "$AITEAM_DIR/bin/implement.sh"
# A failed verdict leaves the task at REVIEW when review.sh is run on its own
# rather than through the driver. Without a route out, dispatch refused —
# correctly — but the refusal exited 1, which the driver charged to the model,
# spending two rungs before escalation stopped it.
check "a task sitting at REVIEW has a route back to IN_PROGRESS" expect-pass \
  grep -q 'REVIEW)   next=CHANGES_REQUESTED' "$AITEAM_DIR/bin/implement.sh"
check "a lifecycle fault before dispatch is a distinct exit code" expect-pass \
  sh -c 'grep -A9 "could not move the task to IN_PROGRESS" "$1/bin/implement.sh" | grep -q "exit 78"' \
  sh "$AITEAM_DIR"
check "the driver stops on it rather than spending a rung" expect-pass \
  grep -q 'dispatch_code" -eq 78' "$AITEAM_DIR/bin/run.sh"
# BACKLOG->READY really is the only way out of BACKLOG, which is what made the
# silenced jump fail. If that ever changes, this check should be revisited.
check "BACKLOG still has exactly one non-terminal exit" expect-pass \
  grep -q '"BACKLOG->READY"' "$AITEAM_DIR/bin/task.sh"

echo
echo "A broken machine is not a failed implementation"

# Vitest reports a setup hook that timed out as a failed FILE. Every integration
# file in this project starts a database container in that hook, so a machine
# that cannot service the container starts reports a dozen failures and zero
# failing assertions — the code under test never ran. Escalating on that answers
# "is this model good enough" with evidence about Docker.
SANDBOX_ENVLOG="$SANDBOX/hooktimeout.log"
printf ' FAIL  api/src/jobs/jobs.int.test.ts > campaigns\n' > "$SANDBOX_ENVLOG"
printf 'Error: Hook timed out in 120000ms.\n'              >> "$SANDBOX_ENVLOG"
printf ' Test Files  11 failed | 22 passed (34)\n'         >> "$SANDBOX_ENVLOG"
printf '      Tests  122 passed | 77 skipped (202)\n'      >> "$SANDBOX_ENVLOG"
# The same shape, but with a real assertion failure mixed in. Still a verdict.
SANDBOX_REALLOG="$SANDBOX/realfailure.log"
cp "$SANDBOX_ENVLOG" "$SANDBOX_REALLOG"
printf '      Tests  3 failed | 119 passed (202)\n'        >> "$SANDBOX_REALLOG"

check "a hook timeout with no failing assertion is an environment fault" expect-pass \
  sh -c 'grep -qE "Hook timed out in|Could not find a working container runtime" "$1" \
         && ! grep -qE "^[[:space:]]*Tests[[:space:]].*[0-9]+ failed" "$1"' sh "$SANDBOX_ENVLOG"

check "a real assertion failure is still a verdict even beside a dead hook" expect-fail \
  sh -c 'grep -qE "Hook timed out in|Could not find a working container runtime" "$1" \
         && ! grep -qE "^[[:space:]]*Tests[[:space:]].*[0-9]+ failed" "$1"' sh "$SANDBOX_REALLOG"

check "verification signals an environment fault with a distinct exit code" expect-pass \
  grep -q 'exit 75' "$AITEAM_DIR/bin/verify.sh"
check "the driver stops on that code instead of escalating the model" expect-pass \
  grep -q 'verify_code -eq 75' "$AITEAM_DIR/bin/run.sh"
# The whole point: an unrunnable suite must not consume the ladder and arrive at
# the orchestrator looking like four models that could not do the work.
check "an environment fault does not mark the task failed" expect-pass \
  grep -q 'has not been' "$AITEAM_DIR/bin/run.sh"

echo
echo "A truncated attempt is resumed, not restarted"

# A wall-clock kill leaves finished work committed on the branch. The next agent
# opens a worktree it did not write and, told nothing, either redoes the finished
# half or contradicts it. Rejection was already carried forward through findings;
# truncation was not carried forward at all.
check "dispatch tells a resumed agent that prior work is unfinished, not wrong" expect-pass \
  grep -q 'Unfinished work already on this branch' "$AITEAM_DIR/bin/implement.sh"
check "it shows which files the truncated attempt already touched" expect-pass \
  grep -q 'Files it has already changed' "$AITEAM_DIR/bin/implement.sh"
# An OPEN finding means a rejected attempt, which needs the opposite instruction,
# so the two blocks must not both fire. Closed findings do not suppress it: a task
# whose findings are all resolved but whose last attempt was cut off mid-flight
# has unfinished work and nothing outstanding to remediate, which is exactly the
# case this notice exists for.
truncation_notice_yields_to_open_findings() {
  grep -q '\$open_findings" -eq 0' "$AITEAM_DIR/bin/implement.sh"
}
check "the truncation notice is suppressed when findings are still open" expect-pass \
  truncation_notice_yields_to_open_findings

echo
echo "A green test must be capable of going red"

# Two green tests in this project proved nothing: one deleted the row it then
# asserted was absent, another let an upsert mask a missing prune. The reviewer
# cannot catch that class — it runs read-only and the sandbox denies the Docker
# socket, so container-backed tests are unrunnable for it. Measured, not assumed:
# `codex exec --sandbox read-only` refused a write even with --add-dir, and with
# workspace-write the suite still failed with "Could not find a working container
# runtime strategy". Hence a harness-side mutation check.
check "there is a mutation checker" expect-pass \
  test -x "$AITEAM_DIR/bin/mutate.sh"
check "the pipeline runs it after verification" expect-pass \
  grep -q 'mutate.sh' "$AITEAM_DIR/bin/run.sh"
check "a surviving mutation blocks the transition to review" expect-pass \
  jq -e '[.gates["TESTING->REVIEW"][].check] | index("tests_can_fail") != null' "$POLICY_CFG"
check "missing mutation evidence is a gate failure, not a silent pass" expect-pass \
  grep -q 'no mutation evidence' "$AITEAM_DIR/bin/task.sh"

# A filter matching no test also exits non-zero, which scored as a kill — the
# strongest result from the weakest check. It hid a real quoting bug: `eval`
# split "concurrent redemptions" into a flag value and a stray path.
check "a filter that matches no test is rejected rather than counted as a kill" expect-pass \
  grep -q 'matched no test' "$AITEAM_DIR/bin/mutate.sh"
check "the test-name filter is passed as a single argument" expect-pass \
  grep -q 'runner_argv=' "$AITEAM_DIR/bin/mutate.sh"
check "a mutation whose guard text is ambiguous is refused" expect-pass \
  grep -q 'expected exactly 1' "$AITEAM_DIR/bin/mutate.sh"
check "the worktree is proven restored after mutating" expect-pass \
  grep -q 'still modified after restoring mutations' "$AITEAM_DIR/bin/mutate.sh"

echo
echo "Gates still work after the branch has landed"

# The docs gate ran at MERGED->DONE against the worktree and `base...HEAD`. By
# then the worktree is destroyed and the branch is already contained in the base,
# so the diff is empty and it reported "changed no documentation" for a task that
# had written documentation. A gate that only fails after the work is correct and
# merged teaches people to ignore it.
check "the docs gate reads the recorded diff, not a worktree that may be gone" expect-pass \
  grep -q 'diff.patch' "$AITEAM_DIR/bin/task.sh"
# Scoped to this one function: the other gates run before the merge, while the
# worktree still exists, so diffing it there is correct.
check "the docs gate no longer diffs against a worktree that may be gone" expect-fail \
  sh -c 'awk "/^gate_docs_updated_if_required\(\)/,/^}/" "$1" | grep -q "REPO_ROOT/\$wt"' \
  sh "$AITEAM_DIR/bin/task.sh"

echo
echo "Accepting work over a failing review is possible, expensive and loud"

# Two gates stood between a failing review and a merged branch, and there was no
# honest way past either. When the owner accepts known findings — which happens,
# and did — the only routes were to edit the reviewer's verdict or to delete the
# gate. A harness whose easiest escape is dishonesty will eventually be escaped
# dishonestly, and the evidence trail is the only thing this harness sells.
#
# So a waiver is a first-class, recorded decision that leaves the verdict, the
# findings and the unmet criteria exactly as the reviewer wrote them. These
# checks exist because a waiver is the one mechanism that can let failing work
# through: if it is ever loosened by accident, nothing else will catch it.
check "a failing verdict alone still refuses the gate" expect-pass \
  sh -c 'awk "/^gate_review_verdict_pass\(\)/,/^}/" "$1" | grep -q "gate_waiver"' \
  sh "$AITEAM_DIR/bin/task.sh"
check "a waiver missing its decider, reason or successor is refused" expect-pass \
  sh -c 'awk "/^gate_waiver\(\)/,/^}/" "$1" | grep -q "\[ -n \"\$who\" \] && \[ -n \"\$why\" \] && \[ -n \"\$to\" \]"' \
  sh "$AITEAM_DIR/bin/task.sh"
# A waiver pointing at finished or missing work is how "deferred" becomes
# "dropped" without anyone deciding to drop it.
check "a waiver whose successor is finished or absent is refused" expect-pass \
  sh -c 'awk "/^gate_waiver\(\)/,/^}/" "$1" | grep -q "have no home"' \
  sh "$AITEAM_DIR/bin/task.sh"
check "a waiver announces itself rather than passing silently" expect-pass \
  sh -c 'awk "/^gate_waiver\(\)/,/^}/" "$1" | grep -q "waived by"' \
  sh "$AITEAM_DIR/bin/task.sh"
# The verdict is the reviewer's word and stays theirs. If a waiver ever rewrites
# it, the evidence stops being evidence.
check "no gate rewrites the recorded verdict to obtain a pass" expect-fail \
  sh -c 'awk "/^gate_waiver\(\)/,/^}/" "$1" | grep -qE "verdict.*=.*PASS|jq .*review.json"' \
  sh "$AITEAM_DIR/bin/task.sh"

# A rejection recorded only by the driver is a rejection lost whenever review.sh
# is invoked directly — which is the normal way to re-review after the
# orchestrator has remediated by hand. The count gates the "stop and read the
# diff yourself" rule, so an undercount quietly raises that ceiling.
a_rejection_is_recorded_with_the_verdict() {
  grep -q 'review.rejections = ((.review.rejections // 0) + 1)' "$AITEAM_DIR/bin/review.sh"
}
the_driver_does_not_count_a_rejection_twice() {
  ! grep -q 'rejections=$((rejections + 1))' "$AITEAM_DIR/bin/run.sh"
}
# Attaching a new review round used to overwrite the findings array, discarding
# every closed finding with it — so the settled ground an implementer must not
# rework, and the history a re-reviewer should read adversarially, both vanished
# at exactly the moment they became useful.
closed_findings_survive_a_new_review_round() {
  grep -q 'select((.status // "open") == "closed")\]$' "$AITEAM_DIR/bin/task.sh" \
    || grep -q 'closed")\]' "$AITEAM_DIR/bin/task.sh"
}
check "a new review round does not erase previously closed findings" expect-pass \
  closed_findings_survive_a_new_review_round

check "a review rejection is recorded by the reviewer, not only by the driver" expect-pass \
  a_rejection_is_recorded_with_the_verdict
check "a driven run does not count the same rejection twice" expect-pass \
  the_driver_does_not_count_a_rejection_twice

echo
echo "Recorded history stays valid against its own schema"

# Orchestrator decisions were hand-written with an {at, by, note} shape while the
# schema — and task.sh note — use {at, from, to, note}. Four completed contracts
# silently stopped validating, because nothing re-validates a task after creation.
check "every task contract still validates" expect-pass \
  sh -c 'for f in "$1"/tasks/TASK-*.json; do node "$2/bin/validate.mjs" "$2/contracts/task.schema.json" "$f" >/dev/null || exit 1; done' \
  sh "$STATE_DIR" "$AITEAM_DIR"

echo
echo "Layer separation"
check "the reusable layer carries no project vocabulary" expect-pass \
  "$AITEAM_DIR/bin/lint-generic.sh"

echo
if [ "$fail_n" -eq 0 ]; then
  printf '\033[32m%d checks passed.\033[0m\n' "$pass_n"
else
  printf '\033[31m%d passed, %d failed.\033[0m\n' "$pass_n" "$fail_n"
fi
exit "$fail_n"
