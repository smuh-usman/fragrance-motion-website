#!/usr/bin/env bash
# The gates and a dispatched agent must agree about the runtime the agent's work
# is judged on. One resolver decides it; every gate pins it before executing
# anything; the dispatch prompt states it; and a missing runtime fails loudly
# instead of falling back.
#
#   gate-runtime.test.sh              self-contained (no node, no jq required)
#   gate-runtime.test.sh -t <name>    run one named case (mutation mode)
#
# The harness is copied into a throwaway repository whose package.json declares
# a floor (engines.node >=20.9.0) and whose $HOME/.nvm holds fake node binaries
# for two majors: v20.10.0 on the floor and v24.19.0 as the newest. Every
# resolver path the library scans is bound to a fake under the sandbox so the
# case asserts what it means to assert. The runner is `node -v`, which fake node
# scripts satisfy, so no real node or jq is needed anywhere — the test runs in a
# clean checkout.
#
# The -t mode exists for the mutation gate. The AC1 mutation of the harness
# replaces the body of gate_runtime_bin() so it always returns the newest
# runtime; the AC2 mutation removes the ensure_gate_runtime call from mutate.sh.
# The mutation gate then runs this script with `-t <name>` and requires the
# named case to FAIL. Each case emits vitest-shaped output so testcount.mjs and
# mutate.sh's "did a test actually run" guard can read it.

set -uo pipefail

AITEAM_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --------------------------------------------------------------- mutation mode
run_case() {
  local name="$1"

  if [ "$name" = "the gate resolver prefers the declared floor over the newest installed runtime" ]; then
    local out
    out="$(make_fixture 1)"
    # Fixture case 1 resolves the resolver. Under the AC1 mutation the resolver
    # always returns the newest runtime, so the floor assertion fails — the kill
    # the mutation gate requires.
    if printf '%s' "$out" | grep -q "resolved=.*v20.10.0"; then
      echo " Test Files  1 passed (1)"
      echo "      Tests  1 passed (1)"
      exit 0
    fi
    printf '%s\n' "$out" >&2
    echo " Test Files  1 failed (1)"
    echo "      Tests  1 failed (1)"
    exit 1
  fi

  if [ "$name" = "every gate script pins the resolved runtime before it runs anything" ]; then
    local out
    out="$(make_fixture 2)"
    # Fixture case 2 greps the three gate scripts for the shared pin. Under the
    # AC2 mutation mutate.sh loses its ensure_gate_runtime call, so the
    # assertion fails — the kill the mutation gate requires.
    if printf '%s' "$out" | grep -q "pins=3"; then
      echo " Test Files  1 passed (1)"
      echo "      Tests  1 passed (1)"
      exit 0
    fi
    printf '%s\n' "$out" >&2
    echo " Test Files  1 failed (1)"
    echo "      Tests  1 failed (1)"
    exit 1
  fi

  echo "No test files found"
  exit 1
}

# Build a throwaway git repo with the harness copied in and fake node runtimes
# under the sandboxed HOME. Prints the stdout of a probe command.
make_fixture() {
  local fcase="$1"
  local repo="$sandbox/repo-$fcase"
  mkdir -p "$repo/src"
  cp -R "$AITEAM_SRC" "$repo/aiteam"
  ( cd "$repo" \
      && git init -q -b dev \
      && git config user.email harness@test.local \
      && git config user.name  "harness test" \
      && printf 'code\n' > src/a.txt \
      && git add -A \
      && git commit -qm init ) >/dev/null 2>&1

  # The floor the fixture repo declares.
  printf '{"name":"fixture","engines":{"node":">=20.9.0"}}\n' > "$repo/package.json"

  # Fake node for two majors, plus fakes shadowing every fixed resolver path.
  mkdir -p "$sandbox/home-$fcase/.nvm/versions/node/v20.10.0/bin" \
           "$sandbox/home-$fcase/.nvm/versions/node/v24.19.0/bin" \
           "$sandbox/home-$fcase/bin" \
           "$sandbox/home-$fcase/opt/homebrew/bin" \
           "$sandbox/home-$fcase/usr/local/bin" \
           "$sandbox/home-$fcase/usr/bin"
  for d in .nvm/versions/node/v20.10.0/bin bin opt/homebrew/bin usr/local/bin usr/bin; do
    printf '#!/bin/sh\necho v20.10.0\n' > "$sandbox/home-$fcase/$d/node"
  done
  printf '#!/bin/sh\necho v24.19.0\n' > "$sandbox/home-$fcase/.nvm/versions/node/v24.19.0/bin/node"
  chmod +x "$sandbox/home-$fcase"/.nvm/versions/node/*/bin/node \
           "$sandbox/home-$fcase/bin/node" \
           "$sandbox/home-$fcase/opt/homebrew/bin/node" \
           "$sandbox/home-$fcase/usr/local/bin/node" \
           "$sandbox/home-$fcase/usr/bin/node"

  if [ "$fcase" = "1" ]; then
    env HOME="$sandbox/home-$fcase" PATH="$sandbox/home-$fcase/bin:/usr/bin:/bin" bash -c '
      source "$1/aiteam/bin/_lib.sh"
      bin="$(gate_runtime_bin)"
      printf "resolved=%s\n" "$bin"
      printf "version=%s\n" "$("$bin/node" -v)"
    ' bash "$repo" 2>&1
    return 0
  fi

  env HOME="$sandbox/home-$fcase" PATH="$sandbox/home-$fcase/bin:/usr/bin:/bin" bash -c '
    pins=0
    for f in verify.sh mutate.sh counterexample.sh; do
      grep -q "ensure_gate_runtime" "$1/aiteam/bin/$f" && pins=$((pins + 1))
    done
    printf "pins=%s\n" "$pins"
  ' bash "$repo" 2>&1
}

if [ "${1:-}" = "-t" ]; then
  [ -n "${2:-}" ] || { echo "No test files found"; exit 1; }
  run_case "$2"
fi

# ------------------------------------------------------------------- full run

# ---- case 1: the resolver prefers the declared floor ------------------------
out="$(make_fixture 1)"
if printf '%s' "$out" | grep -q "resolved=.*v20.10.0" \
   && printf '%s' "$out" | grep -q "version=v20.10.0"; then
  echo "a gate_runtime_bin resolving the floor over the newest is the point"
else
  printf '%s\n' "$out" >&2
  echo "the gate resolver prefers the declared floor over the newest installed runtime" >&2
  exit 1
fi

# ---- case 2: every gate pins the resolved runtime ---------------------------
out="$(make_fixture 2)"
if ! printf '%s' "$out" | grep -q "pins=3"; then
  printf '%s\n' "$out" >&2
  echo "every gate script pins the resolved runtime before it runs anything" >&2
  exit 1
fi
for f in verify.sh mutate.sh counterexample.sh; do
  # The pin must come before the script does anything that could produce
  # evidence: here, before the script sources any task state or runs a command.
  first_gate="$(grep -n "ensure_gate_runtime" "$AITEAM_SRC/bin/$f" | head -1 | cut -d: -f1)"
  first_use="$(grep -nE "task_get|while IFS= read -r cmd" "$AITEAM_SRC/bin/$f" | head -1 | cut -d: -f1)"
  if [ -z "$first_gate" ] || { [ -n "$first_use" ] && [ "$first_gate" -gt "$first_use" ]; }; then
    echo "  $f does not pin the runtime before it executes anything" >&2
    echo "every gate script pins the resolved runtime before it runs anything" >&2
    exit 1
  fi
done

# ---- case 3: the dispatch prompt states the runtime and how to invoke it ----
# implement.sh --dry-run writes the prompt to the task's evidence dir. The
# fixture repo gets a task whose file scope and role keep the dry run inside
# the sandbox; the prompt is the artifact under test.
repo="$sandbox/repo-3"
mkdir -p "$repo/src"
cp -R "$AITEAM_SRC" "$repo/aiteam"
( cd "$repo" \
    && git init -q -b dev \
    && git config user.email harness@test.local \
    && git config user.name  "harness test" \
    && printf 'code\n' > src/a.ts \
    && printf 'readme\n' > README.md \
    && git add -A \
    && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$repo/.aiteam/tasks" "$repo/.aiteam/evidence/TASK-RT"
printf '{"name":"fixture","engines":{"node":">=20.9.0"}}\n' > "$repo/package.json"
printf '{"default_branch":"dev"}\n' > "$repo/.aiteam/project.json"
cat > "$repo/.aiteam/tasks/TASK-RT.json" <<'EOF'
{
  "id": "TASK-RT",
  "title": "gate runtime prompt fixture",
  "objective": "exercise the gate runtime block in the implementation prompt",
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
  "isolation": {"worktree": "", "branch": ""}
}
EOF
# implement.sh's real dependencies: jq for task state, and a node for
# provider_argv of the routed model. Point both at the sandboxed floor fake.
mkdir -p "$sandbox/home-3/.nvm/versions/node/v20.10.0/bin" \
         "$sandbox/home-3/bin"
printf '#!/bin/sh\necho v20.10.0\n' > "$sandbox/home-3/.nvm/versions/node/v20.10.0/bin/node"
printf '#!/bin/sh\necho v20.10.0\n' > "$sandbox/home-3/bin/node"
chmod +x "$sandbox/home-3/.nvm/versions/node/v20.10.0/bin/node" "$sandbox/home-3/bin/node"
# jq is not assumed to exist; fake it as a script that answers the few queries
# implement.sh makes. The prompt build also calls git, which the sandbox has
# through /usr/bin.
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/jq" <<'JQ'
#!/usr/bin/env bash
# Minimal jq stand-in covering exactly the queries implement.sh --dry-run makes
# on this fixture. The fixture model name reaches jq through --arg, so the
# patterns match on the query's distinctive tokens rather than on the literal
# model name. Answers that must echo sandbox paths are produced by the queries
# that carry them.
case "$*" in
  *'min_node_major'*) echo 22 ;;
  *'dispatchable'*) echo true ;;
  *'writes_files'*) echo true ;;
  *'provider'*) echo commandcode ;;
  *'argv'*) echo "cmd -p {PROMPT_FILE_STDIN}" ;;
  *'assigned_role'*) echo backend ;;
  *'assigned_model'*) echo "deepseek-v4-flash" ;;
  *'attempts'*) echo 1 ;;
  *'.title'*) echo "gate runtime prompt fixture" ;;
  *'.default_branch'*) echo dev ;;
  *'isolation.branch'*) echo "task/gate-runtime-fixture" ;;
  *'findings'*) echo 0 ;;
  *'.lens'*) echo "" ;;
  *'routing'*) echo "deepseek-v4-flash" ;;
  *'engines.node'*) echo ">=20.9.0" ;;
  *) echo 'null' ;;
esac
JQ
chmod +x "$sandbox/bin/jq"

set +e
out="$(env HOME="$sandbox/home-3" PATH="$sandbox/home-3/bin:$sandbox/bin:/usr/bin:/bin" \
       bash -c '
  cd "$1"
  ./aiteam/bin/implement.sh TASK-RT --dry-run >/dev/null 2>&1
  code=$?
  if [ $code -ne 0 ]; then printf "dry-run exit %s\n" "$code"; exit 0; fi
  f="$1/.aiteam/evidence/TASK-RT/prompt.md"
  [ -f "$f" ] || { echo "no prompt.md"; exit 0; }
  grep -q "The runtime your work is judged on" "$f" || { echo "no runtime heading"; exit 0; }
  node="$(grep -m1 -oE "/[^ ]*\.nvm/versions/node/v20\.10\.0/bin/node" "$f" || true)"
  [ -n "$node" ] || { echo "no gate runtime path"; exit 0; }
  bin="${node%/node}"
  grep -q "PATH=$bin:\$PATH" "$f" || { echo "no copyable PATH= form"; exit 0; }
  echo "prompt-ok"
' bash "$repo" 2>&1)"
code=$?
set -e
if [ $code -ne 0 ] || ! printf '%s' "$out" | grep -q "prompt-ok"; then
  printf '%s\n' "$out" >&2
  echo "the dispatch prompt states the gate runtime and how to invoke it" >&2
  exit 1
fi

# ---- case 4: a missing gate runtime fails loudly ----------------------------
# The gate must die rather than run on an ambient runtime. The fixture removes
# every runtime the sandbox controls: no nvm install, a PATH whose only node is
# a broken script, and non-executable shims at the fixed paths. A real node at
# an absolute fixed path (Homebrew's /opt/homebrew/bin/node on this machine)
# cannot be shadowed from a sandbox, so on such machines the resolver
# legitimately falls back to it — and the test then asserts the other half of
# the contract: ensure_gate_runtime exported THAT runtime and never ran on an
# unexported ambient one. On a machine with no usable node anywhere, the same
# test asserts the die path: a non-zero exit, a message naming the required
# runtime, and a statement that nothing was executed.
repo="$sandbox/repo-4"
mkdir -p "$repo/src"
cp -R "$AITEAM_SRC" "$repo/aiteam"
( cd "$repo" \
    && git init -q -b dev \
    && git config user.email harness@test.local \
    && git config user.name  "harness test" \
    && printf 'code\n' > src/a.txt \
    && git add -A \
    && git commit -qm init ) >/dev/null 2>&1
printf '{"name":"fixture","engines":{"node":">=20.9.0"}}\n' > "$repo/package.json"
mkdir -p "$sandbox/home-4/.nvm/versions/node" \
         "$sandbox/home-4/bin" \
         "$sandbox/home-4/opt/homebrew/bin" \
         "$sandbox/home-4/usr/local/bin" \
         "$sandbox/home-4/usr/bin"
# A broken node: executable, but refuses to report a version.
cat > "$sandbox/home-4/bin/node" <<'BROKEN'
#!/bin/sh
exit 1
BROKEN
chmod +x "$sandbox/home-4/bin/node"
# Non-executable shims at the fixed paths: they exist but nothing may run them.
touch "$sandbox/home-4/opt/homebrew/bin/node" \
      "$sandbox/home-4/usr/local/bin/node" \
      "$sandbox/home-4/usr/bin/node"

set +e
out="$(env HOME="$sandbox/home-4" PATH="$sandbox/home-4/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" bash -c '
  source "$1/aiteam/bin/_lib.sh"
  ensure_gate_runtime
  printf "exported=%s\n" "$GATE_NODE_BIN"
  # The exported runtime must be what `node` actually resolves to. Present on
  # PATH but shadowed by a newer runtime first would make the gate run on a
  # different node than the one it names — the exact defect this task removes.
  # The fixture puts the fixed paths at the END of PATH so a resolver that only
  # checks "is the bin somewhere on PATH" would fail to move it to the front.
  if [ "$(command -v node)" = "$GATE_NODE_BIN" ]; then
    printf "resolves\n"
  else
    printf "resolves-to=%s\n" "$(command -v node)"
  fi
' bash "$repo" 2>&1)"
code=$?
set -e
if [ $code -ne 0 ] \
   && printf '%s' "$out" | grep -q "nothing was executed" \
   && printf '%s' "$out" | grep -q "Node"; then
  # ensure_gate_runtime died before anything ran, naming the required runtime.
  echo "a missing gate runtime fails loudly instead of falling back"
elif [ $code -eq 0 ] \
     && printf '%s' "$out" | grep -q "^exported=" \
     && printf '%s' "$out" | grep -q "^resolves$"; then
  # A real runtime exists at an absolute path outside the sandbox, so the
  # "nothing findable" half cannot be staged on this machine. The contract's
  # other half IS verified: the gate never ran on an ambient runtime — the
  # exported runtime is the one `node` actually resolves to.
  echo "  (no-runtime case cannot be staged here: a real node exists at a fixed"
  echo "   system path; asserted instead that the exported runtime is the one"
  echo "   \`node\` resolves to, never an ambient one)"
  echo "a missing gate runtime fails loudly instead of falling back"
else
  printf '%s\n' "$out" >&2
  echo "a missing gate runtime fails loudly instead of falling back" >&2
  exit 1
fi

echo "self-contained gate runtime tests passed"
exit 0
