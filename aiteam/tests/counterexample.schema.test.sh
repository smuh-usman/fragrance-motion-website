#!/usr/bin/env bash
# The review verdict schema accepts a structured counterexample on a finding, and
# rejects one missing any of its required fields.
#
#   counterexample.schema.test.sh
#
# The reviewer runs read-only and cannot run the suite, so a finding's
# counterexample is how the harness executes what the reviewer could only
# describe. A counterexample that misses its test or its expectation must be
# rejected by schema validation rather than accepted and skipped — an accepted
# counterexample that the runner then cannot interpret is the silent no-op this
# check exists to prevent. It validates against the real review.schema.json, so
# the fixture and the contract cannot drift apart.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# A well-formed verdict carrying a full counterexample.
cat > "$sandbox/full.json" <<'EOF'
{
  "verdict": "FAIL",
  "summary": "fixture",
  "independently_inspected": ["x"],
  "criteria": [],
  "findings": [
    {
      "severity": "high",
      "file": "a.ts",
      "line": 1,
      "claim": "something is wrong",
      "failure_scenario": "a concrete scenario",
      "remediation": "a fix",
      "counterexample": {
        "files": [
          { "path": "src/extra.py", "content": "def extra():\n    return 42\n", "find": null, "replace": null }
        ],
        "test": "the suite stays green",
        "expect": "PASS"
      }
    }
  ]
}
EOF

# Each of the three rejects drops exactly one required field.
jq 'del(.findings[0].counterexample.test)'   "$sandbox/full.json" > "$sandbox/missing-test.json"
jq 'del(.findings[0].counterexample.expect)' "$sandbox/full.json" > "$sandbox/missing-expect.json"
jq 'del(.findings[0].counterexample.files)'  "$sandbox/full.json" > "$sandbox/missing-files.json"

node "$AITEAM_SRC/bin/validate.mjs" "$AITEAM_SRC/contracts/review.schema.json" "$sandbox/full.json" \
  || { echo "a well-formed counterexample was rejected by the schema" >&2; exit 1; }

for bad in missing-test missing-expect missing-files; do
  if node "$AITEAM_SRC/bin/validate.mjs" "$AITEAM_SRC/contracts/review.schema.json" "$sandbox/$bad.json" 2>/dev/null; then
    echo "a counterexample missing its ${bad#missing-} was accepted by the schema" >&2
    exit 1
  fi
done

echo "a finding counterexample missing its test or its expectation is rejected"
exit 0
