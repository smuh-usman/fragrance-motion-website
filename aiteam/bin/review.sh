#!/usr/bin/env bash
# Independent review. The reviewer runs read-only and returns a schema-constrained
# JSON verdict, so PASS/FAIL is a parsed field rather than prose to interpret
# charitably — and the reviewer physically cannot edit what it judges.
#
#   review.sh <id> [--model M]

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
# The fault classifier is what turns a failed run into operator advice, and the
# advice spends money when it says "credit". It must therefore run on the same
# resolved gate runtime the gates judge on — never on whatever the shell happens
# to have, which is how a classifier that only parses under a newer node once
# passed every test an agent could run and failed the gate.
ensure_gate_runtime
ensure_state_dirs

model_override=""
classify_fixture=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model_override="$2"; shift 2 ;;
    --classify-fixture) classify_fixture="${2:?usage: review.sh --classify-fixture <log>}"; shift 2 ;;
    *) break ;;
  esac
done
# Everything else is <id> [--model M]; the loop above consumed the flags so the
# remaining positional arguments are the id, or none at all.
id="${1:-}"

[ -n "$id" ] || [ -n "$classify_fixture" ] || die "usage: review.sh <id> [--model M]"
model="${model_override:-$(model_for review)}"

# A reviewer that never ran has not rejected anything. An unreachable or
# unentitled model produces no verdict, and counting that as a rejection spends
# the rejection budget on the provider — which is what happened when the codex
# quota ran out and the replacement returned 403 MODEL_NOT_IN_PLAN twice,
# stopping the task as though a reviewer had twice found it wanting.
#
# The failure is classified from the PROVIDER's OWN RESPONSE, never from words
# in the log. The run log contains the prompt, and the prompt contains the
# reviewed project's verification output — so a grep for billing or status
# words matches a passing test named for an HTTP status as easily as it matches
# a real provider error. That exact confusion once produced a credit diagnosis
# from a passing test, telling the operator to top up a healthy account and
# re-run a request that could never succeed. Only the structured error objects
# the runner itself emits are read: codex prints "ERROR: {json}" blocks
# carrying an HTTP status and an error type, and Command Code ends with a
# {"type":"result","subtype":"error",...} line or a run_error event. A log with
# no such response is reported as the generic unreachable fault, never as a
# billing problem.
#
# The classifier is invoked as a .mjs file by path, on the resolved gate
# runtime — never piped into `node -`. `node -` reads stdin as CommonJS unless
# node detects module syntax, and that detection is version-dependent, so an ESM
# program invoked that way works or fails according to which node is on PATH. A
# .mjs filename states the module type instead of leaving it to be inferred,
# and a classifier that cannot run fails loudly (a non-zero exit and a message
# on stderr) rather than returning an empty string that a case statement would
# read as "no provider error".
review_fault_class() {
  local mjs
  mjs="$(mktemp "${TMPDIR:-/tmp}/review-fault-class-XXXXXX.mjs")"
  cat > "$mjs" <<'EOF'
import { readFileSync } from "node:fs";
const logPath = process.argv[2];
if (!logPath) {
  console.error("usage: review-fault-classify.mjs <run-log>");
  process.exit(2);
}
let text;
try {
  text = readFileSync(logPath, "utf8");
} catch (e) {
  console.error(`review-fault-classify.mjs: cannot read ${logPath}: ${e.message}`);
  process.exit(2);
}
const lines = text.split("\n");
const errors = [];

// codex: multi-line "ERROR: {json}" blocks carrying the provider's response.
// The block is pretty-printed JSON: one object that starts on the ERROR: line
// and continues until its braces balance. Newlines appear only BETWEEN tokens
// (string values never span lines in this output), so joining the block with
// spaces yields valid JSON.
const PREFIX = "ERROR: ";
for (let i = 0; i < lines.length; i++) {
  if (!lines[i].startsWith(PREFIX)) continue;
  let json = lines[i].slice(PREFIX.length);
  // "ERROR: {" on its own line means the block's first line carried no token
  // that would open or close a brace; the object starts on the next line.
  if (!json.includes("{")) continue;
  let depth = 0;
  for (const ch of json) { if (ch === "{") depth++; if (ch === "}") depth--; }
  while (depth > 0 && i + 1 < lines.length) {
    const more = lines[++i];
    json += " " + more.trim();
    for (const ch of more) { if (ch === "{") depth++; if (ch === "}") depth--; }
  }
  try {
    const parsed = JSON.parse(json);
    // Normalise the codex error shape: {status, error:{type,code,message}}.
    errors.push({
      status: parsed.status ?? null,
      code: parsed.error?.code ?? null,
      message: parsed.error?.message ?? parsed.message ?? JSON.stringify(parsed),
    });
  } catch { /* not a provider error object */ }
}

// Command Code: NDJSON result/event error lines.
for (const raw of lines) {
  const s = raw.trim();
  if (!s.startsWith("{")) continue;
  let o; try { o = JSON.parse(s); } catch { continue; }
  if (o.type === "result" && o.subtype === "error" && typeof o.error === "string") {
    errors.push({ status: o.status ?? null, message: o.error });
  }
  if (o.type === "event" && o.event?.type === "run_error" && o.event?.error) {
    errors.push({ status: o.event.error?.status ?? null, message: JSON.stringify(o.event.error) });
  }
}

if (!errors.length) {
  // No structured error attributable to the provider: the honest outcome is
  // the generic unreachable fault, never the billing one, whose remedy costs
  // the operator money.
  console.log("unreachable");
  process.exit(0);
}

const last = errors[errors.length - 1];
const status = Number(last.status) || null;
const hay = String(last.message ?? "").toLowerCase();
const code = String(last.code ?? "").toLowerCase();

// The harness sent something the provider would not accept: an invalid schema
// or a bad parameter. The remedy is to fix the request in this repository;
// re-running unchanged can never succeed, and topping up the account fixes
// nothing. This must never be reported as a credit problem.
if (status === 400 || status === 422
    || /invalid_json_schema|invalid_request_error|invalid schema|bad request|bad parameter|invalid parameter/.test(hay)) {
  console.log("malformed-request");
  process.exit(0);
}

// The account or the plan refused the work: a rate limit, an entitlement
// error, a spent quota. The remedy costs money, so this classification is
// only ever made from the provider's own response. A bare 403 is NOT enough —
// only one whose body names an entitlement or quota reason belongs here;
// anything ambiguous falls through to the generic unreachable fault.
if (status === 429 || status === 402
    || /model_not_in_plan|not entitled|not available on|quota|credit|billing|insufficient|usage limit|rate limit|too many requests|payment required/.test(hay)
    || code.includes("model_not_in_plan") || code.includes("insufficient_quota") || code.includes("rate_limit")) {
  console.log("credit");
  process.exit(0);
}

console.log("unreachable");
EOF
  "$GATE_NODE_BIN" "$mjs" "$1"
  local code=$?
  rm -f "$mjs"
  return "$code"
}

# Test hook: classify a fixture run log with the real classifier and print the
# operator-facing advice for that outcome. Only the classifier and the advice
# branches run — no task state, no provider, no verdict file — so the tests can
# assert behaviour (what the operator is told) without parsing review.sh's
# source, and without pretending a review happened. A reworded warning does not
# break the test; a broken classification cannot hide behind prose.
if [ -n "$classify_fixture" ]; then
  model="${model_override:-unset}"
  fault="$(review_fault_class "$classify_fixture")"
  case "$fault" in
    malformed-request)
      echo "$id: the provider rejected the review REQUEST as malformed — an invalid
      schema or a bad parameter that this repository sent. NO REVIEW HAPPENED and
      no rejection was recorded — the work is unjudged and stays at REVIEW with
      its branch intact. The fix belongs in this repository (aiteam/contracts/
      review.schema.json or the review invocation), and re-running unchanged will
      fail identically every time. Nothing is wrong with the account; do not top
      it up."
      ;;
    credit)
      echo "$id: the reviewer '$model' is out of credit or not entitled on this account.
      NO REVIEW HAPPENED and no rejection was recorded — the work is unjudged and
      stays at REVIEW with its branch intact. Top up the reviewer's account, then
      re-run this task unchanged. Do not substitute a weaker reviewer to get past
      this: a reader returns a verdict that reads exactly like a reviewer's."
      ;;
    unreachable)
      echo "$id: the reviewer '$model' could not be reached, so no review happened.
      This is a provider fault, not a rejection — the work has not been judged.
      Check the provider, then re-run this task unchanged."
      ;;
  esac
  exit 0
fi

# Not `// true`: jq treats false as absent under the alternative operator, which
# would turn a correctly-declared read-only reviewer into an apparent writer and
# make this guard reject exactly the models it is meant to allow.
writes="$(jq -r --arg m "$model" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")"
[ "$writes" = "false" ] \
  || die "refusing to review with '$model': it can write files. A reviewer that can
     edit the code it judges can quietly fix instead of reporting, which destroys
     the independence the whole review step exists to provide."

wt="$(task_get "$id" '.isolation.worktree // empty')"
workdir="$REPO_ROOT/${wt:-.}"
[ -d "$workdir" ] || die "no worktree for $id"

db="$(default_branch)"
diff_file="$EVIDENCE_DIR/$id/diff.patch"
mkdir -p "$EVIDENCE_DIR/$id"

# Capture committed and uncommitted work, so review sees everything the agent did.
( cd "$workdir" && { git diff "$db"...HEAD; git diff; git diff --cached; } ) > "$diff_file" 2>/dev/null || true
[ -s "$diff_file" ] || die "$id has an empty diff — nothing to review"

prompt="$(mktemp)"
{
  cat "$AITEAM_DIR/roles/reviewer.md"
  while IFS= read -r lens; do
    [ -n "$lens" ] || continue
    echo; echo "---"; echo
    cat "$AITEAM_DIR/lenses/$lens.md" 2>/dev/null || true
  done < <(task_get "$id" '.lens[]?')

  echo; echo "---"; echo
  echo "# What you are reviewing"; echo
  jq '{id, title, objective, acceptance_criteria, risk, risk_reason, files}' "$(require_task "$id")"

  echo; echo "## The working tree"; echo
  echo "You are in a checkout at: $workdir"
  echo "The branch is '$(task_get "$id" '.isolation.branch')', based on '$db'."
  echo "You have read access to every file. Open whatever you need — do not review"
  echo "from the diff alone when the surrounding code determines whether it is correct."
  echo
  echo "Reproduce the diff yourself with:  git diff $db...HEAD"
  echo

  # A re-review is not a first review. Without this block the reviewer sees the
  # current contract and the current code and cannot tell which of its own
  # findings were addressed, which were closed by argument rather than by a fix,
  # or — the one that matters most — whether a criterion it previously judged
  # against has since been REWRITTEN to match the code. A criterion quietly
  # reshaped to fit the implementation passes every gate and means nothing.
  if [ "$(jq '.findings | length' "$(require_task "$id")")" -gt 0 ]; then
    echo; echo "## What happened since your last review"; echo
    echo "You reviewed this branch before and raised the findings below. Each is"
    echo "shown with what was recorded about it. Nothing here is evidence — it is"
    echo "a claim to check against the code, and a finding marked closed that is"
    echo "not actually fixed is a more serious result than the original finding."
    echo
    jq -r '.findings[] | "- [\((.status // "open") | ascii_upcase)] [\(.severity)] \(.file)\(if .line then ":\(.line)" else "" end)\n  \(.claim)"' \
       "$(require_task "$id")"
    echo
    echo "Notes recorded by the orchestrator since that review:"; echo
    jq -r '[.history[] | select((.note // "") != "")] | .[-6:][] | "- \(.at): \(.note)"' \
       "$(require_task "$id")"
    echo
    echo "Read those notes adversarially. If an acceptance criterion was AMENDED"
    echo "after you reviewed against it, judge whether the contract was genuinely"
    echo "wrong or whether it was bent to fit what the code already did, and say"
    echo "which. You are not bound by the orchestrator's account of either."
    echo
  fi

  if [ -f "$EVIDENCE_DIR/$id/verify.log" ]; then
    echo "## Recorded verification output"; echo
    echo "Exit code: $(cat "$EVIDENCE_DIR/$id/verify.exit" 2>/dev/null || echo unknown)"
    echo '```'; tail -100 "$EVIDENCE_DIR/$id/verify.log"; echo '```'
    echo
    echo "Passing tests do not establish that the criteria are met. Check that the"
    echo "tests assert what the criteria require, and that they would fail if the"
    echo "behaviour were wrong."
    echo
  fi

  echo "## Output"; echo
  echo "Return ONE JSON object and nothing else — no prose before or after it, no"
  echo "markdown fence. Populate 'independently_inspected' with the files you"
  echo "actually opened. For every acceptance criterion, cite the specific evidence."
  echo "Every finding needs a concrete failure scenario; if you cannot construct"
  echo "one, leave it out."
  echo
  # Some runners impose the schema on the model; others cannot, and a reviewer
  # that renames a key wastes an entire review. Spelling the keys out costs a few
  # lines and removes the most common way a good verdict becomes unusable — the
  # first run on this runner returned a correct review under 'acceptance_criteria'
  # instead of 'criteria' and was rejected for it.
  echo "The object must use exactly these top-level keys:"
  echo '  verdict                  "PASS" or "FAIL"'
  echo '  summary                  one paragraph'
  echo '  criteria                 array — NOT "acceptance_criteria"'
  echo '  findings                 array (empty when there are none)'
  echo '  independently_inspected  array of file paths you opened'
  echo
  echo "The full schema follows. Match it exactly."; echo
  echo '```json'; cat "$AITEAM_DIR/contracts/review.schema.json"; echo '```'
} > "$prompt"

cp "$prompt" "$EVIDENCE_DIR/$id/review-prompt.md"

out="$EVIDENCE_DIR/$id/review.json"
rm -f "$out"

argv=()
while IFS= read -r a; do argv[${#argv[@]}]="$a"; done < <(
  provider_argv "$model" \
    "WORKDIR=$workdir" \
    "SCHEMA_FILE=$AITEAM_DIR/contracts/review.schema.json" \
    "OUTPUT_FILE=$out"
)

runlog="$RUNS_DIR/$id-review-$(date -u +%Y%m%dT%H%M%SZ).log"
ensure_provider_runtime "$model"
info "reviewing $id with $model (read-only)"
: > "$runlog"                 # exists before the viewer attaches, so it follows this run
open_follow_window "$id" "$runlog"

set +e
"${argv[@]}" < "$prompt" > "$runlog" 2>&1
code=$?
set -e

# Runners that cannot write the final message to a file (Command Code has no
# --output-last-message) declare verdict_from_log, and the harness recovers the
# verdict from the NDJSON stream instead. validate_schema below is unchanged, so
# an unusable verdict still fails loudly rather than passing as prose.
if [ ! -s "$out" ] && [ "$(jq -r --arg m "$model" '.models[$m].verdict_from_log // false' "$PROVIDERS_CFG")" = "true" ]; then
  node "$AITEAM_DIR/bin/extract-verdict.mjs" "$runlog" "$out" >&2 || true
fi

if [ ! -s "$out" ]; then
  fault="$(review_fault_class "$runlog" || true)"
  tail -5 "$runlog" >&2
  case "$fault" in
    malformed-request)
      warn "$id: the provider rejected the review REQUEST as malformed — an invalid
      schema or a bad parameter that this repository sent. NO REVIEW HAPPENED and
      no rejection was recorded — the work is unjudged and stays at REVIEW with
      its branch intact. The fix belongs in this repository (aiteam/contracts/
      review.schema.json or the review invocation), and re-running unchanged will
      fail identically every time. Nothing is wrong with the account; do not top
      it up."
      exit 75
      ;;
    credit)
      warn "$id: the reviewer '$model' is out of credit or not entitled on this account.
      NO REVIEW HAPPENED and no rejection was recorded — the work is unjudged and
      stays at REVIEW with its branch intact. Top up the reviewer's account, then
      re-run this task unchanged. Do not substitute a weaker reviewer to get past
      this: a reader returns a verdict that reads exactly like a reviewer's."
      exit 75
      ;;
    unreachable)
      warn "$id: the reviewer '$model' could not be reached, so no review happened.
      This is a provider fault, not a rejection — the work has not been judged.
      Check the provider, then re-run this task unchanged."
      exit 75
      ;;
    *)
      # No response attributable to the provider. A failed run with no verdict
      # has still judged nothing, so it is a generic reachability fault rather
      # than a rejection — the credit diagnosis is never the fallback, because
      # its remedy costs the operator money.
      if [ "$code" -ne 0 ]; then
        warn "$id: the reviewer '$model' could not be reached, so no review happened.
        This is a provider fault, not a rejection — the work has not been judged.
        Check the provider, then re-run this task unchanged."
        exit 75
      fi
      ;;
  esac
fi

[ -s "$out" ] || { tail -30 "$runlog" >&2; die "reviewer produced no verdict (exit $code) — see $runlog"; }
validate_schema "$out" "$AITEAM_DIR/contracts/review.schema.json" \
  || die "reviewer output did not match the verdict schema — see $out"

verdict="$(jq -r '.verdict' "$out")"
task_set "$id" '.evidence.review = ".aiteam/evidence/'"$id"'/review.json"'
# Record WHICH reviewer produced this verdict. Reviewers are now substitutable —
# codex, Command Code, and in the worst case the orchestrating session itself —
# and those are not equally independent. A task reviewed by the same session that
# wrote its contract must never be mistaken later for one that was reviewed
# independently, so the identity travels with the verdict.
task_set "$id" ".review.reviewer = \"$model\""

echo >&2
jq -r '"VERDICT: \(.verdict)\n\(.summary)\n\nInspected: \(.independently_inspected | join(", "))"' "$out" >&2
echo >&2
jq -r '.criteria[]? | "  \(if .met then "✓" else "✗" end) \(.id): \(.evidence)"' "$out" >&2
if [ "$(jq '.findings | length' "$out")" -gt 0 ]; then
  echo >&2; echo "Findings:" >&2
  jq -r '.findings[] | "  [\(.severity)] \(.file)\(if .line then ":\(.line)" else "" end)\n    \(.claim)\n    Fails when: \(.failure_scenario)\n    Fix: \(.remediation)"' "$out" >&2
fi

# Findings are attached whatever the verdict. A PASS is a judgement on the
# acceptance criteria, not a statement that nothing is wrong — this reviewer has
# passed work while reporting a medium-severity defect in it, and attaching only
# on FAIL meant those findings were printed once to a terminal and then lost. The
# orchestrator decides what a passing finding is worth; it cannot decide about
# something the task file never recorded.
if [ "$(jq '.findings | length' "$out")" -gt 0 ]; then
  "$AITEAM_DIR/bin/task.sh" findings "$id" "$out" >/dev/null
fi

if [ "$verdict" = "PASS" ]; then
  if [ "$(jq '.findings | length' "$out")" -gt 0 ]; then
    ok "$id: review PASSED — with $(jq '.findings | length' "$out") finding(s) recorded on the task.
     Passing the criteria is not the same as nothing being wrong. Read them and
     decide: remediate now, or carry them deliberately."
  else
    ok "$id: review PASSED"
  fi
  exit 0
else
  # The rejection is recorded HERE, with the verdict, not by the driver. It used
  # to be incremented only in run.sh, so a review invoked directly — which is how
  # a re-review after hand-remediation is usually run — was a rejection the task
  # file never heard about. The count is the input to the "stop and read the diff
  # yourself" rule, and an undercount silently raises the ceiling on how many
  # times the same work can be pushed back through the same loop.
  task_set "$id" '.review.rejections = ((.review.rejections // 0) + 1)'
  warn "$id: review FAILED — findings attached for the remediation attempt
     (rejection $(task_get "$id" '.review.rejections') recorded)"
  exit 1
fi
