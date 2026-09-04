#!/usr/bin/env bash
# The review schema must satisfy the provider's strict structured-output mode.
#
#   review-schema-strict.test.sh                  full run
#   review-schema-strict.test.sh -t <name>        run one named case (mutation mode)
#
# The reviewer runs under a strict JSON-schema output constraint: every key in an
# object's 'properties' must also appear in its 'required' array, and a field is
# made optional by widening its type to include null, never by omission. The
# provider rejects the whole request with HTTP 400 when a schema violates this —
# no review can run against such a schema at all, for any task.
#
# This test walks the WHOLE schema tree, not the two nodes that violated it once:
# the point is that the next field someone adds cannot silently reintroduce the
# defect. The walk runs against the real schema file, and against a mutated copy
# with a key removed from a 'required' array, to prove the walk can actually
# fail.
#
# It also asserts the sibling invariant that TASK-0017 fixed in the task schema:
# every task field the harness reads through task_get is declared in
# task.schema.json. A reader added without a contract entry is a silently dead
# field — the harness reads it, gets nothing, and falls back to a default that
# may not be what the task intended.
#
# The -t mode exists for the mutation gate. The AC2 mutation renames the schema
# path so the walk reads a missing file; the gate then runs this script with
# `-t <name>` and requires the named case to FAIL. Each case emits vitest-shaped
# output so testcount.mjs and mutate.sh's "did a test actually run" guard can
# read it.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AITEAM_SRC/bin/_lib.sh"
# The walk is part of what the gates judge, so it runs on the same resolved
# gate runtime the gates use — never on whatever node happens to be first on
# this shell's PATH. A verdict produced by a different runtime than the one
# the gates use is evidence about a run that did not happen.
ensure_gate_runtime
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

REVIEW_SCHEMA="$AITEAM_SRC/contracts/review.schema.json"
TASK_SCHEMA="$AITEAM_SRC/contracts/task.schema.json"

# --------------------------------------------------------------------------
# walk-strict.mjs reads a schema and walks every object node. A node that
# declares 'properties' must list every one of them in 'required'. Exit 0 when
# the whole tree complies; exit 1 naming the first violation otherwise.
cat > "$sandbox/walk-strict.mjs" <<'EOF'
import { readFileSync } from "node:fs";
const schemaPath = process.argv[2];
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const violations = [];

function walk(node, path) {
  if (!node || typeof node !== "object" || Array.isArray(node)) return;
  if (node.properties) {
    const props = Object.keys(node.properties);
    const req = node.required || [];
    for (const p of props) {
      if (!req.includes(p)) violations.push(`${path}: property "${p}" is not listed in "required"`);
    }
  }
  for (const [k, v] of Object.entries(node.properties || {})) walk(v, `${path}.${k}`);
  if (node.items) walk(node.items, `${path}.items`);
}
walk(schema, "root");
if (violations.length) {
  for (const v of violations) console.error(v);
  process.exit(1);
}
EOF

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
    "every object in the review schema lists all of its properties as required")
      # The AC2 mutation renames the schema path so the walk reads a missing
      # file. A walk that passes vacuously on a missing schema is exactly the
      # failure this case must catch, so a missing or unreadable schema is a
      # FAIL, not a silent pass.
      if ! "$GATE_NODE_BIN" "$sandbox/walk-strict.mjs" "$REVIEW_SCHEMA" 2>/dev/null; then
        emit 1 "$name"; return
      fi
      emit 0 "$name"
      ;;
    "a schema with any property missing from required is rejected")
      # The case AC2's mutation gate targets: the walker's reporting is
      # neutralised (`if (violations.length)` -> `if (false)`), so a broken
      # schema must be accepted as clean. Fixture copy of the real schema with
      # one key removed from a 'required' array; PASS only when the walk
      # rejects it.
      jq 'del(.properties.findings.items.required[6])' "$REVIEW_SCHEMA" > "$sandbox/broken-case.json"
      if "$GATE_NODE_BIN" "$sandbox/walk-strict.mjs" "$sandbox/broken-case.json" 2>/dev/null; then
        emit 1 "$name"; return
      fi
      emit 0 "$name"
      ;;
    "every task field the harness reads is declared in the task schema")
      local missing="" field
      while IFS= read -r field; do
        [ -n "$field" ] || continue
        if ! jq -e --arg f "$field" '.properties | has($f)' "$TASK_SCHEMA" >/dev/null 2>&1; then
          missing="$missing $field"
        fi
      done < <(grep -ahoE "task_get \"\\\$id\" '\.[A-Za-z_]+" "$AITEAM_SRC"/bin/*.sh \
                | sed -E "s/.*'\.//" | sort -u)
      if [ -n "$missing" ]; then
        emit 1 "$name"; return
      fi
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
# The real schema must comply.
if ! "$GATE_NODE_BIN" "$sandbox/walk-strict.mjs" "$REVIEW_SCHEMA"; then
  echo "the review schema violates strict structured-output mode" >&2
  exit 1
fi
echo "every object in the review schema lists all of its properties as required"

# The walk must be capable of failing. A copy of the schema with one key removed
# from a 'required' array has to be rejected — otherwise the check proves
# nothing, because a future schema that reintroduces the defect would pass.
jq 'del(.properties.findings.items.required[6])' "$REVIEW_SCHEMA" > "$sandbox/broken.json"
if "$GATE_NODE_BIN" "$sandbox/walk-strict.mjs" "$sandbox/broken.json" 2>/dev/null; then
  echo "a schema with a property missing from required was accepted by the walk" >&2
  exit 1
fi
echo "a schema with any property missing from required is rejected"

# The mutation gate for AC2 renames the schema path so the walk reads a missing
# file. The walk must fail loudly rather than pass vacuously.
if "$GATE_NODE_BIN" "$sandbox/walk-strict.mjs" "$REVIEW_SCHEMA.nonexistent" 2>/dev/null; then
  echo "a missing schema file was accepted by the walk" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Every task field the harness reads through task_get is declared in the task
# schema. Fields are read as '.field' expressions; collect them all and check
# each one against the schema's top-level properties.
#
# task.sh new rejects unknown top-level properties (additionalProperties:
# false), so a field the harness reads but the schema does not declare can never
# be set — it is a silently dead reader falling back to a default. The
# counterexample_runner field was exactly that: counterexample.sh read it, the
# schema did not declare it, and every counterexample ran under the vitest
# default no matter what a task set.
missing=""
while IFS= read -r field; do
  [ -n "$field" ] || continue
  if ! jq -e --arg f "$field" '.properties | has($f)' "$TASK_SCHEMA" >/dev/null 2>&1; then
    missing="$missing $field"
  fi
done < <(grep -ahoE "task_get \"\\\$id\" '\.[A-Za-z_]+" "$AITEAM_SRC"/bin/*.sh \
          | sed -E "s/.*'\.//" | sort -u)

if [ -n "$missing" ]; then
  echo "task field(s) read by the harness but not declared in the task schema:$missing" >&2
  exit 1
fi
echo "every task field the harness reads is declared in the task schema"

# --------------------------------------------------------------------------
# AC7 end to end: a task contract that sets counterexample_runner must be
# ACCEPTED by task.sh new, not merely declared in the schema. The schema test
# above proves the field is declared; this proves the declaration is live — a
# schema entry that task.sh new still rejected would make the field as
# unreachable as no entry at all. The fixture repo mirrors how task.sh new is
# used: a contract carrying the override, validated and accepted.
repo="$sandbox/tasknew"
mkdir -p "$repo/docs"
cp -R "$AITEAM_SRC" "$repo/aiteam"
( cd "$repo" \
    && git init -q -b dev \
    && git config user.email harness@test.local \
    && git config user.name  "harness test" \
    && printf '# docs\n' > docs/readme.md \
    && mkdir -p .aiteam \
    && printf '{"default_branch":"dev"}\n' > .aiteam/project.json \
    && git add -A \
    && git commit -qm init ) >/dev/null 2>&1
cat > "$repo/task.json" <<'EOF'
{
  "title": "Prove the counterexample runner override is accepted at creation",
  "objective": "A task contract that sets counterexample_runner must be accepted by task.sh new and the value must reach counterexample.sh.",
  "risk": "low",
  "acceptance_criteria": [{"id":"AC1","statement":"the override is accepted and used","verified_by":"manual:inspection"}],
  "files": {"expected": ["**/*.md"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "counterexample_runner": "bash ./aiteam/tests/run-counterexample.sh",
  "verification": ["node -e \"console.log('ok')\""],
  "review": {"required": false}
}
EOF
if ! ( cd "$repo" && ./aiteam/bin/task.sh new task.json ) >/dev/null 2>&1; then
  echo "a task contract that sets counterexample_runner was rejected by task.sh new" >&2
  exit 1
fi
if [ "$(jq -r '.counterexample_runner' "$repo/.aiteam/tasks/"*.json 2>/dev/null)" != "bash ./aiteam/tests/run-counterexample.sh" ]; then
  echo "task.sh new did not record the counterexample_runner value" >&2
  exit 1
fi
echo "a task contract that sets counterexample_runner is accepted by task.sh new"

echo "the review schema satisfies strict structured-output mode across its whole tree"
exit 0
