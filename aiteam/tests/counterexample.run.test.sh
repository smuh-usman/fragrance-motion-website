#!/usr/bin/env bash
# The counterexample runner applies a finding's counterexample, runs the named
# test, records CONFIRMED/REFUTED/INCONCLUSIVE, restores the worktree, and proves
# the tree actually changed before drawing any conclusion from the test result.
#
#   counterexample.run.test.sh                       self-contained (no node)
#   counterexample.run.test.sh --vitest              also run the real vitest integration
#   counterexample.run.test.sh -t <name>             run one named case (mutation mode)
#
# The self-contained half builds a throwaway repository and copies the harness
# into it, so it runs in a clean checkout with nothing installed and exercises
# the portability claim. A fake runner produces vitest-shaped output so the
# runner's own guards — a filter matching no test is INCONCLUSIVE, a run counts
# only when a test actually passed or failed — are exercised exactly as they
# would be against a real test runner.
#
# The -t mode exists for the mutation gate. The AC3 mutation of the harness
# breaks the invariant that a finding must start with the change flag clear; the
# mutation gate then runs this script with `-t <name>` and requires the named
# case to FAIL. Each case emits vitest-shaped output so testcount.mjs and
# mutate.sh's "did a test actually run" guard can read it.
#
# The --vitest half runs in THIS repository's worktree, which already has vitest
# and node_modules, and proves the runner works against the real test runner the
# harness uses.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --------------------------------------------------------------- mutation mode
# Run exactly one named case. The mutation gate runs
# `bash counterexample.run.test.sh -t "<name>"` from the worktree, after it has
# applied the AC3 mutation to the worktree's copy of counterexample.sh. This
# mode must therefore build its own throwaway repo, copy the CURRENT aiteam/
# (which is the mutated one under the gate) into it, and drive the case-3
# scenario against it: a non-matching anchor must be reported INCONCLUSIVE,
# never REFUTED, and the worktree must end clean. Under the mutation the
# harness's change flag is forced to 1, so it dies at the first finding instead
# of running — the named case then fails, which is the kill the gate requires.
# Output is vitest-shaped so testcount.mjs and mutate.sh's "did a test actually
# run" guard can read it.
run_case() {
  local name="$1"
  case "$name" in
    "a counterexample whose anchor does not match is INCONCLUSIVE, not REFUTED")
      local s="$sandbox/mutation"
      mkdir -p "$s"
      cp -R "$AITEAM_SRC" "$s/aiteam"
      mkdir -p "$s/.aiteam/tasks" "$s/src"
      printf 'def guard():\n    return True\n' > "$s/src/sut.py"
      cat > "$s/.aiteam/tasks/TASK-CX.json" <<'JSON'
{
  "id": "TASK-CX",
  "title": "mutation fixture",
  "objective": "exercise the change-flag guard",
  "risk": "low",
  "status": "IN_PROGRESS",
  "attempts": 1,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 0},
  "findings": [
    {"severity":"high","file":"src/sut.py","line":1,
     "claim":"the guard is missing","failure_scenario":"a scenario","remediation":"a fix",
     "counterexample":{
       "files":[{"path":"src/sut.py","find":"def guard():\n    return NOT_PRESENT","replace":"def guard():\n    return False"}],
       "test":"the test fails","expect":"FAIL"}}
  ],
  "history": [],
  "isolation": {"worktree": ".git/wt", "branch": "task/counterexample"}
}
JSON
      cat > "$s/fake-runner.sh" <<'SH'
#!/usr/bin/env bash
# The named test: "the test fails" must FAIL for the counterexample to be
# CONFIRMED. The fake runner emits vitest-shaped output and exits 1.
echo " Test Files  1 failed (1)"
echo "      Tests  1 failed (1)"
exit 1
SH
      chmod +x "$s/fake-runner.sh"
      jq --arg r "$s/fake-runner.sh" '.counterexample_runner = $r' \
        "$s/.aiteam/tasks/TASK-CX.json" > "$s/.aiteam/tasks/TASK-CX.tmp" \
        && mv "$s/.aiteam/tasks/TASK-CX.tmp" "$s/.aiteam/tasks/TASK-CX.json"
      git -C "$s" init -q -b dev
      git -C "$s" config user.email harness@test.local
      git -C "$s" config user.name  "harness test"
      git -C "$s" add -A && git -C "$s" commit -qm init
      git -C "$s" worktree add -q -b task/counterexample .git/wt dev

      out="$("$s/aiteam/bin/counterexample.sh" TASK-CX 2>&1)"; code=$?
      results="$s/.aiteam/evidence/TASK-CX/counterexample.results"
      clean=1
      [ -n "$(git -C "$s/.git/wt" status --porcelain)" ] && clean=0

      # Pass exactly when the scenario behaved as a correct harness makes it:
      # exit 0, the result recorded as INCONCLUSIVE, nothing recorded as REFUTED,
      # and the worktree clean.
      if [ "$code" -eq 0 ] \
         && grep -q "^1 INCONCLUSIVE" "$results" 2>/dev/null \
         && ! grep -q "^1 REFUTED" "$results" 2>/dev/null \
         && [ "$clean" -eq 1 ]; then
        echo " Test Files  1 passed (1)"
        echo "      Tests  1 passed (1)"
        exit 0
      fi
      echo "$out" >&2
      echo " Test Files  1 failed (1)"
      echo "      Tests  1 failed (1)"
      exit 1
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
fi

# ------------------------------------------------------------------- full run
# The full self-contained run builds the fake harness once, then drives it
# through six scenarios. It runs from any checkout (including a worktree whose
# aiteam/ is the real harness), so it exercises the real runner against the fake
# runner.

# ---------------------------------------------------------------- setup: fake
mkdir -p "$sandbox/fake"
cp -R "$AITEAM_SRC" "$sandbox/fake/aiteam"
mkdir -p "$sandbox/fake/.aiteam/tasks"
mkdir -p "$sandbox/fake/src"
printf 'def guard():\n    return True\n' > "$sandbox/fake/src/sut.py"
FAKE_TASK="$(cat <<'EOF'
{
  "id": "TASK-CX",
  "title": "counterexample runner fixture",
  "objective": "exercise the counterexample runner against a fake test runner",
  "risk": "low",
  "status": "IN_PROGRESS",
  "attempts": 1,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 0},
  "findings": [],
  "history": [],
  "isolation": {"worktree": ".git/wt", "branch": "task/counterexample"}
}
EOF
)"
printf '%s\n' "$FAKE_TASK" > "$sandbox/fake/.aiteam/tasks/TASK-CX.json"
git -C "$sandbox/fake" init -q -b dev
git -C "$sandbox/fake" config user.email harness@test.local
git -C "$sandbox/fake" config user.name  "harness test"
git -C "$sandbox/fake" add -A && git -C "$sandbox/fake" commit -qm init
git -C "$sandbox/fake" worktree add -q -b task/counterexample .git/wt dev
echo "setup: fake repo ready"

# -------------------------------------------------------------------- harness
HARNESS() { "$sandbox/fake/aiteam/bin/counterexample.sh" "$@"; }
REAL_HARNESS() { "$sandbox/real/aiteam/bin/counterexample.sh" "$@"; }

# ----------------------------------------------------------- fixture: fake
# The runner is a fake test runner emitting vitest-shaped output. When run with
# -t it executes exactly the counterexample's expectation against a flag file.
FAKE_RUNNER="$sandbox/fake/fake-runner.sh"
cat > "$FAKE_RUNNER" <<'SH'
#!/usr/bin/env bash
# fake vitest: vitest run -t "<name>"   -> emits vitest-shaped output
set -uo pipefail
run_vitest() {
  local name="$1"
  case "$name" in
    "stays green"|"the test passes")
      echo " Test Files  1 passed (1)"
      echo "      Tests  1 passed (1)"
      exit 0 ;;
    "now fails"|"the test fails")
      echo " Test Files  1 failed (1)"
      echo "      Tests  1 failed (1)"
      exit 1 ;;
    "does not exist")
      echo " Test Files  1 passed (1)"
      echo "      Tests  0 skipped (0)"
      exit 0 ;;
    *) echo "No test files found"; exit 1 ;;
  esac
}
if [ "${1:-}" = "run" ]; then shift; fi
if [ "${1:-}" = "-t" ]; then
  shift
  # The harness passes the filter as ONE argument, so it may contain spaces.
  run_vitest "$1"
else
  echo " Test Files  2 passed (2)"
  echo "      Tests  7 passed (7)"
  exit 0
fi
SH
chmod +x "$FAKE_RUNNER"
jq --arg r "$FAKE_RUNNER" '.counterexample_runner = $r' \
  "$sandbox/fake/.aiteam/tasks/TASK-CX.json" > "$sandbox/fake/.aiteam/tasks/TASK-CX.tmp" \
  && mv "$sandbox/fake/.aiteam/tasks/TASK-CX.tmp" "$sandbox/fake/.aiteam/tasks/TASK-CX.json"

# ---------------------------------------------------------------- fixture: 1
# CONFIRMED with an added file. content += adds a file whose text ends in a
# newline, so the tree changes and the added file carries the newline.
set_findings() {  # set_findings <repo-dir> <findings-json>
  local d="$1"
  jq --argjson f "$2" '.findings = $f' "$d/.aiteam/tasks/TASK-CX.json" \
    > "$d/.aiteam/tasks/TASK-CX.tmp" && mv "$d/.aiteam/tasks/TASK-CX.tmp" "$d/.aiteam/tasks/TASK-CX.json"
  # Evidence accumulates per task; clear the previous run's results file so
  # each case asserts only what its own run recorded.
  rm -f "$d/.aiteam/evidence/TASK-CX/counterexample.results"
}

# finding 1: add a file, test "stays green" (expect PASS)  -> CONFIRMED
CX1_BODY="$(jq -nc \
  --argjson f1 '[{"path":"src/extra.py","content":"def extra():\n    return 42\n"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the analysis misses a case",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f1,test:"stays green",expect:"PASS"}}')"
set_findings "$sandbox/fake" "[$CX1_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
printf '%s\n' "$out" | grep -q "counterexample 1 CONFIRMED" || { echo "case 1: no CONFIRMED for a pass-expecting counterexample" >&2; echo "$out" >&2; exit 1; }
grep -q "^1 CONFIRMED" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "case 1: results file missing" >&2; exit 1; }
[ -f "$sandbox/fake/.git/wt/src/extra.py" ] && { echo "case 1: added file left behind" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 1: worktree not clean after run" >&2; exit 1; }
echo "case 1: CONFIRMED applied then fully restored"

# finding 2: edit with an anchor, test "now fails" (expect FAIL)  -> CONFIRMED
CX2_BODY="$(jq -nc \
  --argjson f2 '[{"path":"src/sut.py","find":"def guard():\n    return True","replace":"def guard():\n    return False"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the guard is missing",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f2,test:"now fails",expect:"FAIL"}}')"
set_findings "$sandbox/fake" "[$CX2_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
printf '%s\n' "$out" | grep -q "counterexample 1 CONFIRMED" || { echo "case 2: no CONFIRMED for a fail-expecting counterexample" >&2; echo "$out" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 2: worktree not clean after run" >&2; exit 1; }
echo "case 2: CONFIRMED when the test fails as predicted"

# finding 3: anchor that does not match -> INCONCLUSIVE, never REFUTED
CX3_BODY="$(jq -nc \
  --argjson f3 '[{"path":"src/sut.py","find":"def guard():\n    return NOT_PRESENT","replace":"def guard():\n    return False"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the guard is missing",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f3,test:"the test fails",expect:"FAIL"}}')"
set_findings "$sandbox/fake" "[$CX3_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
printf '%s\n' "$out" | grep -q "anchor appears 0 times" || { echo "case 3: the non-matching anchor was not reported" >&2; echo "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q "REFUTED" && { echo "case 3: a non-applying counterexample was reported REFUTED" >&2; echo "$out" >&2; exit 1; }
grep -q "^1 INCONCLUSIVE" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "case 3: results file missing INCONCLUSIVE" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 3: worktree not clean after run" >&2; exit 1; }
echo "a counterexample whose anchor does not match is INCONCLUSIVE, not REFUTED"

# finding 4: added file collides with an existing path -> INCONCLUSIVE
CX4_BODY="$(jq -nc \
  --argjson f4 '[{"path":"src/sut.py","content":"print(\"overwrite\")\n"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the analysis misses a case",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f4,test:"stays green",expect:"PASS"}}')"
set_findings "$sandbox/fake" "[$CX4_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
grep -q "^1 INCONCLUSIVE" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "case 4: results file missing INCONCLUSIVE" >&2; echo "$out" >&2; exit 1; }
grep -q "print(\"overwrite\")" "$sandbox/fake/.git/wt/src/sut.py" && { echo "case 4: collision wrote over an existing file" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 4: worktree not clean after run" >&2; exit 1; }
echo "case 4: a colliding addition is INCONCLUSIVE and overwrites nothing"

# finding 5: test filter matches no test -> INCONCLUSIVE (not REFUTED, not CONFIRMED)
CX5_BODY="$(jq -nc \
  --argjson f5 '[{"path":"src/extra.py","content":"def extra():\n    return 42\n"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the analysis misses a case",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f5,test:"does not exist",expect:"FAIL"}}')"
set_findings "$sandbox/fake" "[$CX5_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
grep -q "^1 INCONCLUSIVE" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "case 5: results file missing INCONCLUSIVE" >&2; echo "$out" >&2; exit 1; }
grep -q "^1 CONFIRMED" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" && { echo "case 5: a filter matching nothing was reported CONFIRMED" >&2; exit 1; }
grep -q "^1 REFUTED" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" && { echo "case 5: a filter matching nothing was reported REFUTED" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 5: worktree not clean after run" >&2; exit 1; }
echo "case 5: a test filter matching no test is INCONCLUSIVE"

# finding 6: REFUTED when the test does not behave as predicted
CX6_BODY="$(jq -nc \
  --argjson f6 '[{"path":"src/extra.py","content":"def extra():\n    return 42\n"}]' \
  '{severity:"high",file:"src/sut.py",line:1,
    claim:"the analysis misses a case",failure_scenario:"a scenario",remediation:"a fix",
    counterexample:{files:$f6,test:"stays green",expect:"FAIL"}}')"
set_findings "$sandbox/fake" "[$CX6_BODY]"
out="$(HARNESS TASK-CX 2>&1)"; code=$?
printf '%s\n' "$out" | grep -q "REFUTED" || { echo "case 6: no REFUTED when the prediction does not hold" >&2; echo "$out" >&2; exit 1; }
grep -q "^1 REFUTED" "$sandbox/fake/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "case 6: results file missing REFUTED" >&2; exit 1; }
[ -n "$(git -C "$sandbox/fake/.git/wt" status --porcelain)" ] && { echo "case 6: worktree not clean after run" >&2; exit 1; }
echo "case 6: REFUTED when the test does not behave as predicted"

echo "self-contained counterexample tests passed"

# ------------------------------------------------------------ vitest reality
# The --vitest half proves the runner against the REAL test runner, end to end:
# the sandbox repo is a copy of THIS repository (with its own vitest, its own
# api/src/foundation.test.ts, its own vitest.config.ts), the harness creates a
# worktree from it, and the counterexample edits a real test file and adds a
# real new test file. This is the configuration the mutation check for AC3
# depends on: the added file is discoverable by vitest, so breaking the
# change-flag guard makes the run report the added file as absent and the case
# flips from CONFIRMED to something else.
if [ "${1:-}" = "--vitest" ]; then
  mkdir -p "$sandbox/real"
  REPO_ROOT_ABS="$(cd "$(pwd)" && pwd)"
  echo "setup: copying this repository into the vitest sandbox (this can take a while)"
  # Copy the CURRENT working tree (including uncommitted harness changes the
  # test must exercise), excluding node_modules and .git so the sandbox stays a
  # clean fixture. The dependency directory is then copied from this worktree's
  # install, which is guaranteed present because the harness itself ran here.
  # BSD tar has no --null, so the exclusion list is a plain tar pattern.
  ( cd "$REPO_ROOT_ABS" \
      && tar -cf - --exclude='./.git' --exclude='./node_modules' --exclude='./.aiteam' . \
      | ( cd "$sandbox/real" && tar -xf - ) )
  [ -d "$REPO_ROOT_ABS/node_modules" ] || { echo "  this worktree has no node_modules — vitest half skipped" >&2; echo "self-contained counterexample tests passed"; exit 0; }
  mkdir -p "$sandbox/real/node_modules"
  cp -R "$REPO_ROOT_ABS/node_modules/." "$sandbox/real/node_modules/"

  # The copied repo has no .aiteam yet; give it the minimal harness state and a
  # task whose counterexample edits an existing test and adds a new one.
  mkdir -p "$sandbox/real/.aiteam/tasks" "$sandbox/real/.aiteam/evidence"
  printf '{"default_branch":"dev"}\n' > "$sandbox/real/.aiteam/project.json"
  git -C "$sandbox/real" init -q -b dev
  git -C "$sandbox/real" config user.email harness@test.local
  git -C "$sandbox/real" config user.name  "harness test"
  git -C "$sandbox/real" add -A
  git -C "$sandbox/real" commit -qm "fixture snapshot"
  git -C "$sandbox/real" worktree add -q -b task/counterexample .git/wt dev
  # A git worktree is tracked files only; the harness's runner (vitest) runs
  # FROM the worktree, so it needs the same dependency directory there.
  mkdir -p "$sandbox/real/.git/wt/node_modules"
  cp -R "$sandbox/real/node_modules/." "$sandbox/real/.git/wt/node_modules/"
  cat > "$sandbox/real/.aiteam/tasks/TASK-CX.json" <<'JSON'
{
  "id": "TASK-CX",
  "title": "counterexample runner vitest fixture",
  "objective": "exercise the counterexample runner against the real vitest runner",
  "risk": "low",
  "status": "IN_PROGRESS",
  "attempts": 1,
  "acceptance_criteria": [{"id":"AC1","statement":"n/a","verified_by":"manual:n/a"}],
  "files": {"expected": ["src/**"], "forbidden": []},
  "assigned_role": "backend",
  "assigned_model": "deepseek-v4-flash",
  "verification": [],
  "review": {"required": false, "rejections": 0},
  "findings": [
    {
      "severity": "high",
      "file": "api/src/foundation.test.ts",
      "line": null,
      "claim": "the suite misses a regression",
      "failure_scenario": "a concrete scenario",
      "remediation": "a fix",
      "counterexample": {
        "files": [
          { "path": "api/src/foundation.test.ts",
            "find": "describe('arithmetic sanity', () => {",
            "replace": "describe('arithmetic sanity', () => { // counterexample" },
          { "path": "api/src/counterexample.evidence.test.ts",
            "content": "import { test, expect } from 'vitest';\n\ntest('the counterexample fixture is discoverable', () => {\n  expect(1).toBe(1);\n});\n" }
        ],
        "test": "adds two numbers",
        "expect": "PASS"
      }
    }
  ],
  "history": [],
  "isolation": {"worktree": ".git/wt", "branch": "task/counterexample"}
}
JSON
  echo "setup: real repo ready"

  findings="$(jq -c '.findings' "$sandbox/real/.aiteam/tasks/TASK-CX.json")"
  set_findings "$sandbox/real" "$findings"
  out="$(REAL_HARNESS TASK-CX 2>&1)"; code=$?
  printf '%s\n' "$out" | grep -q "counterexample 1 CONFIRMED" || { echo "vitest: no CONFIRMED from the real runner" >&2; echo "$out" >&2; exit 1; }
  grep -q "^1 CONFIRMED" "$sandbox/real/.aiteam/evidence/TASK-CX/counterexample.results" || { echo "vitest: results file missing CONFIRMED" >&2; exit 1; }
  [ -f "$sandbox/real/.git/wt/api/src/counterexample.evidence.test.ts" ] && { echo "vitest: added test file left behind" >&2; exit 1; }
  git -C "$sandbox/real/.git/wt" status --porcelain | grep -q "api/src/foundation.test.ts" && { echo "vitest: edited test file not restored" >&2; exit 1; }
  [ -n "$(git -C "$sandbox/real/.git/wt" status --porcelain)" ] && { echo "vitest: worktree not clean after run" >&2; exit 1; }
  echo "vitest: CONFIRMED and fully restored against the real test runner"
fi

echo "an applied counterexample is fully restored and the worktree is clean afterwards"
exit 0
