#!/usr/bin/env bash
# The review fault classifier reads the PROVIDER's OWN RESPONSE, never the words
# in the run log. The run log embeds the prompt, and the prompt embeds the
# reviewed project's verification output — so a passing test named for an HTTP
# status or containing the word "quota" used to be read as a provider failure.
# That produced a credit diagnosis from a green test and told the operator to
# top up a healthy account, re-run unchanged, and fail identically forever.
#
#   review-fault-classification.test.sh                  full run
#   review-fault-classification.test.sh -t <name>        run one named case
#
# The classifier is read OUT of aiteam/bin/review.sh rather than copied, so the
# test exercises the exact code the review path runs. Three outcomes must be
# distinguishable in what the operator is told:
#
#   malformed-request  a 4xx meaning the harness sent an invalid schema or a
#                      bad parameter: fix belongs in this repository, never
#                      top up the account, never re-run unchanged.
#   credit             a genuine 429 rate limit or MODEL_NOT_IN_PLAN in the
#                      provider's own response: top up and re-run unchanged.
#   unreachable        everything else that prevented a verdict, including
#                      any log whose failure cannot be attributed to the
#                      provider with confidence.
#
# The classifier is a .mjs program that review.sh writes to a temp file and
# invokes by path — never piped into `node -`, whose CommonJS default would
# make the same ESM program run or fail according to which node happens to be
# on PATH. This test runs the classifier the same way: extracted to a .mjs file
# and executed with the RESOLVED GATE RUNTIME (the one the gates judge on),
# never with whatever node this shell happens to have.
#
# The -t mode exists for the mutation gate. The AC4 mutation rewrites the credit
# branch's advice in review.sh so malformed-request cases fall back to it; the
# gate then runs `bash review-fault-classification.test.sh -t "<name>"` and
# requires the named case to FAIL. Each case emits vitest-shaped output so
# testcount.mjs and mutate.sh's "did a test actually run" guard can read it.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AITEAM_SRC/bin/_lib.sh"
# The classifier decides what the operator is told, and the credit advice sends
# them to spend money — so this test runs the classifier on the same resolved
# gate runtime the gates judge on, never on whatever node happens to be first
# on this shell's PATH. A verdict produced by a different runtime than the one
# the gates use is evidence about a run that did not happen.
ensure_gate_runtime
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --------------------------------------------------------------------------
# Extract the classifier's node body from review.sh. Reading it out of the
# script (rather than keeping a copy here) is what makes the test exercise the
# real code: a classifier that drifted from this test would fail it. The
# classifier is the heredoc that review_fault_class() writes to a temp .mjs
# file; the same body is extracted here and run identically (by path, on the
# gate runtime).
extract_classifier() {
  sed -n "/cat > \"\$mjs\" <<'EOF'/,/^EOF$/p" "$AITEAM_SRC/bin/review.sh" \
    | sed '1d;$d'
}

classify() {  # classify <log-file> -> prints malformed-request|credit|unreachable
  local log="$1"
  extract_classifier > "$sandbox/classifier.mjs"
  "$GATE_NODE_BIN" "$sandbox/classifier.mjs" "$log" 2>/dev/null
}

emit() {  # vitest-shaped summary; exit code matches the verdict
  local code="$1" name="$2"
  if [ "$code" -eq 0 ]; then
    echo " Test Files  1 passed (1)"
    echo "      Tests  1 passed (1)"
  else
    echo " Test Files  1 failed (1)"
    echo "      Tests  1 failed (1)"
  fi
  return "$code"
}

# ---------------------------------------------------------------- mutation mode
run_case() {
  local name="$1"
  case "$name" in
    "a passing project test named for an HTTP status is not classified as a provider fault")
      local out
      cat > "$sandbox/passing-test.log" <<'EOF'
Reading prompt from stdin...
OpenAI Codex v0.147.0
user
# Role: Independent Review Engineer
You review work you did not do.
## Recorded verification output
Exit code: 0
```
  ✓ login rate limiting against real postgres > 429 carries Retry-After, and the window recovers 1771ms
  ✓ api/src/errors.test.ts (6 tests) 285ms
```
Passing tests do not establish that the criteria are met.
EOF
      out="$(classify "$sandbox/passing-test.log")"
      # The green test's name must not be readable as a billing signal. With no
      # provider response attributable to the runner, the honest outcome is the
      # generic unreachable fault — never credit, whose remedy costs money.
      if [ "$out" != "unreachable" ] && [ "$out" != "" ]; then
        emit 1 "$name"
        return
      fi
      emit 0 "$name"
      ;;
    "a 400 invalid-schema response is reported as a malformed request, not as a credit problem")
      local out
      cat > "$sandbox/400.log" <<'EOF'
Reading prompt from stdin...
ERROR: {
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "invalid_json_schema",
    "message": "Invalid schema for response_format 'codex_output_schema': 'required' is required to be supplied and to be an array including every key in properties. Missing 'content'.",
    "param": "text.format.schema"
  },
  "status": 400
}
EOF
      out="$(classify "$sandbox/400.log")"
      [ "$out" = "malformed-request" ] || { emit 1 "$name"; return; }
      # The advice for a malformed request is behaviour, not source prose: it
      # names this repository as the fix location and never sends the operator
      # to top up. The classifier token above is the behavioural core — under
      # the AC4 mutation it flips to "credit", and this case must fail. The
      # advice string is exercised through review.sh's own case branches, so a
      # reworded warning does not break the test and a broken behaviour cannot
      # hide behind one.
      if ! bash "$AITEAM_SRC/bin/review.sh" --classify-fixture "$sandbox/400.log" 2>/dev/null \
           | grep -q 'fix belongs in this repository'; then
        emit 1 "$name"; return
      fi
      emit 0 "$name"
      ;;
    "a genuine entitlement failure in the provider response is still reported as a credit problem")
      local out
      cat > "$sandbox/entitlement.log" <<'EOF'
ERROR: {
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "MODEL_NOT_IN_PLAN",
    "message": "MODEL_NOT_IN_PLAN: model available in GOAT and above plans or extra on demand usage"
  },
  "status": 403
}
EOF
      out="$(classify "$sandbox/entitlement.log")"
      [ "$out" = "credit" ] || { emit 1 "$name"; return; }
      cat > "$sandbox/ratelimit.log" <<'EOF'
ERROR: {
  "type": "error",
  "error": {
    "type": "rate_limit_error",
    "code": "rate_limit_exceeded",
    "message": "You have exceeded your rate limit. Please retry after 60 seconds."
  },
  "status": 429
}
EOF
      out="$(classify "$sandbox/ratelimit.log")"
      [ "$out" = "credit" ] || { emit 1 "$name"; return; }
      emit 0 "$name"
      ;;
    *)
      echo "No test files found"
      exit 1
      ;;
  esac
}

if [ "${1:-}" = "-t" ]; then
  [ -n "${2:-}" ] || { echo "No test files found"; exit 1; }
  run_case "$2"
  exit $?
fi

# ------------------------------------------------------------------- full run
# The classifier is present in review.sh and reads the provider response only.
if ! grep -q '^review_fault_class()' "$AITEAM_SRC/bin/review.sh"; then
  echo "the fault classifier is missing from review.sh" >&2
  exit 1
fi
echo "the fault classifier is read out of review.sh, not copied"

# AC8: the classifier is never piped into a bare `node -` from a heredoc or a
# pipe — it is a .mjs file invoked by path. `node -` reads stdin as CommonJS
# unless node detects module syntax, and that detection is version-dependent,
# so the same program works or fails according to which node is on PATH. The
# invocation form is checked deliberately, not the behaviour: the classifier is
# extracted to a .mjs file and run by path, which is exactly the form review.sh
# uses.
if grep -nE '(^|[^[:alnum:]_])node -([[:space:]]|$)' "$AITEAM_SRC"/bin/*.sh; then
  echo "a harness script pipes a node program into a bare stdin invocation" >&2
  exit 1
fi
echo "no harness script pipes an ESM program into a bare node stdin invocation"

# AC9: the classifier runs on the resolved gate runtime, never on whatever node
# happens to be on PATH. ensure_gate_runtime above exported GATE_NODE_BIN; the
# runtime it resolved must be the one actually executing the classifier.
if [ -z "${GATE_NODE_BIN:-}" ] || [ ! -x "$GATE_NODE_BIN" ]; then
  echo "the fault-classification test could not resolve the gate runtime" >&2
  exit 1
fi
echo "the fault-classification test runs the classifier on the gate runtime"

# AC3: a PASSING test named for an HTTP status must not become a credit or
# provider-fault diagnosis. The log embeds the prompt, which embeds the reviewed
# project's verification output; the test name is the only mention of 429 in the
# log. With no provider response, the outcome must be the generic unreachable
# fault — never credit.
cat > "$sandbox/passing-test.log" <<'EOF'
Reading prompt from stdin...
OpenAI Codex v0.147.0
user
# Role: Independent Review Engineer
You review work you did not do.
## Recorded verification output
Exit code: 0
```
  ✓ login rate limiting against real postgres > 429 carries Retry-After, and the window recovers 1771ms
  ✓ api/src/errors.test.ts (6 tests) 285ms
```
Passing tests do not establish that the criteria are met.
EOF
out="$(classify "$sandbox/passing-test.log")"
if [ "$out" = "credit" ] || [ "$out" = "malformed-request" ]; then
  echo "a passing test named for an HTTP status produced a '$out' diagnosis" >&2
  exit 1
fi
echo "a passing project test named for an HTTP status is not classified as a provider fault"

# AC3 complement: the same log with a real 400 invalid-schema response must be
# classified as a malformed request even though the green test's name appears
# in the same log. The response, not the incidental text, decides.
cat > "$sandbox/400.log" <<'EOF'
Reading prompt from stdin...
  ✓ login rate limiting against real postgres > 429 carries Retry-After, and the window recovers 1771ms
ERROR: {
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "invalid_json_schema",
    "message": "Invalid schema for response_format 'codex_output_schema': 'required' is required to be supplied and to be an array including every key in properties. Missing 'content'.",
    "param": "text.format.schema"
  },
  "status": 400
}
EOF
out="$(classify "$sandbox/400.log")"
if [ "$out" != "malformed-request" ]; then
  echo "a 400 invalid-schema response was classified as '$out', expected malformed-request" >&2
  exit 1
fi
echo "a 400 invalid-schema response is reported as a malformed request, not as a credit problem"

# AC5: a genuine credit or entitlement failure in the provider's OWN response is
# still a credit problem, with its existing remedy intact. Assert both a real
# rate limit (429) and a real entitlement refusal (403 MODEL_NOT_IN_PLAN).
cat > "$sandbox/entitlement.log" <<'EOF'
ERROR: {
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "MODEL_NOT_IN_PLAN",
    "message": "MODEL_NOT_IN_PLAN: model available in GOAT and above plans or extra on demand usage"
  },
  "status": 403
}
EOF
out="$(classify "$sandbox/entitlement.log")"
if [ "$out" != "credit" ]; then
  echo "a MODEL_NOT_IN_PLAN response was classified as '$out', expected credit" >&2
  exit 1
fi
cat > "$sandbox/ratelimit.log" <<'EOF'
ERROR: {
  "type": "error",
  "error": {
    "type": "rate_limit_error",
    "code": "rate_limit_exceeded",
    "message": "You have exceeded your rate limit. Please retry after 60 seconds."
  },
  "status": 429
}
EOF
out="$(classify "$sandbox/ratelimit.log")"
if [ "$out" != "credit" ]; then
  echo "a 429 rate-limit response was classified as '$out', expected credit" >&2
  exit 1
fi
echo "a genuine entitlement failure in the provider response is still reported as a credit problem"

# AC4 behaviour: the malformed-request advice is exercised through review.sh's
# own case branches (not by grepping its source), and it never tells the
# operator to top up. The classifier token was asserted above; this asserts the
# operator-facing advice is distinct for each outcome.
if ! bash "$AITEAM_SRC/bin/review.sh" --classify-fixture "$sandbox/400.log" 2>/dev/null \
     | grep -q 'fix belongs in this repository'; then
  echo "the malformed-request advice does not name this repository as the fix" >&2
  exit 1
fi
if bash "$AITEAM_SRC/bin/review.sh" --classify-fixture "$sandbox/400.log" 2>/dev/null \
     | grep -qE 'top up|re-run this task unchanged'; then
  echo "the malformed-request advice tells the operator to top up or re-run unchanged" >&2
  exit 1
fi
echo "the malformed-request advice names this repository and never says to top up"

echo "provider-fault classification reads the provider's own response"
exit 0
