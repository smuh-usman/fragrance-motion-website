#!/usr/bin/env bash
# Shared helpers. Sourced by every other script in bin/.
set -euo pipefail

AITEAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the MAIN repository, not whatever worktree we happen to be standing in.
# Task state lives in one place; a worktree carries a stale committed copy of it,
# and resolving to that copy makes the harness read and write the wrong state
# while appearing to work. `--git-common-dir` points at the shared .git for every
# worktree, so its parent is always the real root.
_common_git="$(git -C "$AITEAM_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$_common_git" ]; then
  case "$_common_git" in
    /*) REPO_ROOT="$(cd "$_common_git/.." && pwd)" ;;
    *)  REPO_ROOT="$(cd "$AITEAM_DIR" && cd "$(dirname "$_common_git")" && pwd)" ;;
  esac
else
  REPO_ROOT="$(cd "$AITEAM_DIR/.." && pwd)"
fi
unset _common_git
STATE_DIR="$REPO_ROOT/.aiteam"
TASKS_DIR="$STATE_DIR/tasks"
EVIDENCE_DIR="$STATE_DIR/evidence"
RUNS_DIR="$STATE_DIR/runs"

# Worktrees live inside .git/ rather than in the project tree. A worktree carries
# its own .git pointer file, so anything nested in the project is detected by
# VS Code and GitHub Desktop as a SEPARATE repository — it appears in the source
# control panel sitting on the task branch, which reads as "these changes are
# still pending" long after the branch was merged. Nothing scans .git/, so this
# keeps the harness invisible to editors, and `git worktree prune` still cleans up.
WT_DIR="$REPO_ROOT/.git/aiteam-worktrees"
PROJECT_CFG="$STATE_DIR/project.json"

MODELS_CFG="$AITEAM_DIR/config/models.json"
PROVIDERS_CFG="$AITEAM_DIR/config/providers.json"
POLICY_CFG="$AITEAM_DIR/config/policy.json"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m %s\n'  "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*" >&2; }

need_bin() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

task_file() { echo "$TASKS_DIR/$1.json"; }

require_task() {
  local f; f="$(task_file "$1")"
  [ -f "$f" ] || die "no such task: $1"
  echo "$f"
}

task_get() { jq -r "$2" "$(require_task "$1")"; }

# Atomically rewrite a task file with a jq expression.
# Atomic because a crash mid-write would otherwise leave the task graph corrupt.
task_set() {
  local id="$1" expr="$2" f tmp
  f="$(require_task "$id")"
  tmp="$(mktemp)"
  jq "$expr | .updated_at = \"$(now_iso)\"" "$f" > "$tmp" || { rm -f "$tmp"; die "jq failed updating $id"; }
  mv "$tmp" "$f"
}

default_branch() {
  [ -f "$PROJECT_CFG" ] && jq -r '.default_branch // "main"' "$PROJECT_CFG" || echo main
}

model_for() { jq -r --arg k "$1" '.routing[$k].model // empty' "$MODELS_CFG"; }

# Resolve the argv template for a model, substituting {PLACEHOLDERS}.
# Emits one argument per line so callers can read it into an array safely —
# splitting on spaces would break any argument containing one.
provider_argv() {
  local model="$1"; shift
  local argv; argv="$(jq -r --arg m "$model" '.models[$m].argv // empty | .[]' "$PROVIDERS_CFG")"
  [ -n "$argv" ] || die "model '$model' has no argv in providers.json"
  while IFS= read -r arg; do
    for sub in "$@"; do
      local key="${sub%%=*}" val="${sub#*=}"
      arg="${arg//\{$key\}/$val}"
    done
    printf '%s\n' "$arg"
  done <<< "$argv"
}

ensure_state_dirs() { mkdir -p "$TASKS_DIR" "$EVIDENCE_DIR" "$RUNS_DIR" "$WT_DIR"; }

# --- tamper evidence -------------------------------------------------------
# A dispatched agent must not be able to alter the contract it is judged against.
# The fingerprint covers the fields that define acceptance; `status`, `history`,
# `attempts` and `evidence` are excluded because the harness legitimately moves
# those while the agent is running.
task_fingerprint() {
  jq -S 'del(.status, .history, .attempts, .evidence, .updated_at)' "$(require_task "$1")" \
    | shasum -a 256 | cut -d' ' -f1
}

# Make a worktree's dependencies actually usable, and return non-zero if they
# cannot be made so.
#
# Two distinct failures land here. A git worktree checks out tracked files only,
# and dependency directories are gitignored, so a fresh worktree has none and
# every verification command exits 127 — a failure indistinguishable in the log
# from a real one. Separately, an agent interrupted part-way through its own
# install (a turn limit, a timeout, a kill) leaves a half-written tree behind
# that `git clean -fd` will not remove because it is ignored.
#
# The presence of node_modules therefore proves nothing. npm writes
# node_modules/.package-lock.json only once an install completes, so that marker
# and its age against the lockfile are the honest question. This has to be
# callable from verification as well as from dispatch: the install being intact
# when the agent started says nothing about whether it still is when the tests run.
ensure_workspace_ready() {
  local wd="$1" logf="${2:-/dev/null}"
  local marker="$wd/node_modules/.package-lock.json"
  [ -f "$wd/package.json" ] || return 0
  if [ -f "$marker" ] && [ ! "$wd/package-lock.json" -nt "$marker" ]; then return 0; fi

  info "installing dependencies in $wd (absent, incomplete, or older than the lockfile)"
  rm -rf "$wd/node_modules"
  if [ -f "$wd/package-lock.json" ] \
     && ( cd "$wd" && npm ci --no-audit --no-fund ) >>"$logf" 2>&1; then
    return 0
  fi
  # npm ci refuses to run when the lockfile is out of sync with package.json,
  # which is the normal state once an agent has added a dependency mid-task.
  ( cd "$wd" && npm install --no-audit --no-fund ) >>"$logf" 2>&1
}

# Find a bin directory whose `node` is at least major version $1, preferring the
# newest available. Prints the directory; returns non-zero if there is none.
#
# A provider CLI is a Node program, so the runtime it gets is whatever happens to
# be first on PATH — and with nvm that is a per-shell setting the harness does not
# control. A background dispatch inherited an older default than the interactive
# shell used, so `cmd` refused to start, exited non-zero, and the attempt produced
# nothing. Resolving the runtime explicitly makes dispatch independent of which
# node a particular terminal happened to have active.
node_bin_at_least() {
  local want="$1" cand v best="" best_v=0
  for cand in "$(command -v node 2>/dev/null || true)" \
              "$HOME"/.nvm/versions/node/*/bin/node \
              /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    v="$("$cand" -v 2>/dev/null | sed 's/^v//; s/\..*//')"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ "$v" -ge "$want" ] && [ "$v" -gt "$best_v" ]; then best_v="$v"; best="$cand"; fi
  done
  [ -n "$best" ] || return 1
  dirname "$best"
}

# Resolve the ONE Node runtime the gates execute under: the project's declared
# floor when it declares one, else the newest available. Prints the bin directory.
#
# The floor is read from the repository's package.json engines.node, and it is
# preferred over any newer install. Verifying on the newest installed runtime
# hides version-dependent defects; verifying on the floor is what catches them.
# This resolver is what makes the harness's gates and a dispatched agent agree
# about the runtime the agent's work is judged on.
#
# A single quoted string, so a wildcard range like ">=20.9.0" or "20.x" resolves
# to its lowest bound: ">=20.9.0" picks the newest of 20.x (20.10.0 if that is
# what is installed) because 20 is already a compatible major and every candidate
# below the floor is rejected.
gate_runtime_bin() {
  local floor="" major="" v cand best="" best_v=0
  floor="$(jq -r '.engines.node // empty' "$REPO_ROOT/package.json" 2>/dev/null || true)"
  case "$floor" in
    *[0-9]*) ;;
    *) floor="" ;;
  esac
  [ -n "$floor" ] || floor="$(command -v node 2>/dev/null || true)"
  major="$(printf '%s' "$floor" | sed 's/^[^0-9]*//; s/[^0-9].*//')"
  case "$major" in
    ''|*[!0-9]*) major="" ;;
  esac
  if [ -n "$major" ]; then
    for cand in "$HOME"/.nvm/versions/node/*/bin/node \
                "$(command -v node 2>/dev/null || true)" \
                /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
      [ -n "$cand" ] && [ -x "$cand" ] || continue
      v="$("$cand" -v 2>/dev/null | sed 's/^v//; s/\..*//')"
      case "$v" in ''|*[!0-9]*) continue ;; esac
      if [ "$v" -eq "$major" ] && [ "$v" -gt "$best_v" ]; then best_v="$v"; best="$cand"; fi
    done
    [ -n "$best" ] && dirname "$best" && return 0
  fi
  node_bin_at_least 0
}

# Put the resolved gate runtime at the front of PATH, or die before anything
# runs. A gate that falls back to whatever runtime the shell happens to have
# would report passes produced by a runtime other than the one it names, and
# evidence that describes a run which did not happen is worse than no evidence.
# GATE_NODE_BIN is exported so the agent's own shell — which inherits the PATH
# raised for the provider CLI and therefore cannot see the gate's runtime by
# default — can be told exactly how the gates ran.
ensure_gate_runtime() {
  local bin node
  bin="$(gate_runtime_bin)" || die "no Node runtime found for the gates: nothing was executed.
     The gates need Node $(jq -r '.engines.node // "0 (no floor declared)"' "$REPO_ROOT/package.json" 2>/dev/null || echo unknown) as declared by this repository's package.json.
     Install it (nvm install --lts, or brew install node), then re-run."
  node="$bin/node"
  # The resolved runtime must be the one `node` resolves to, not merely present
  # somewhere on PATH. A PATH that already contains the bin but with a newer
  # runtime first would otherwise leave the gate running on the wrong node while
  # naming the right one. Remove every existing occurrence, then put the bin
  # first.
  case ":$PATH:" in
    *":$bin:"*) PATH="$(printf '%s' "$PATH" | sed "s|:$bin:|:|g")" ;;
  esac
  PATH="$bin:$PATH"
  export PATH
  export GATE_NODE_BIN="$node"
  export GATE_NODE_PREFIX="$bin"
}

# Put a runtime new enough for this model's provider at the front of PATH, or die
# before dispatching. Failing here costs nothing; failing after dispatch burns an
# attempt and looks like the model was incapable.
ensure_provider_runtime() {
  local model="$1" provider want bin
  provider="$(jq -r --arg m "$model" '.models[$m].provider // empty' "$PROVIDERS_CFG")"
  [ -n "$provider" ] || return 0
  want="$(jq -r --arg p "$provider" '.providers[$p].min_node_major // empty' "$PROVIDERS_CFG")"
  [ -n "$want" ] || return 0

  if ! bin="$(node_bin_at_least "$want")"; then
    die "provider '$provider' needs Node $want or newer and no such runtime was found.
     Install it (nvm install --lts, or brew install node), then re-run. Nothing was
     dispatched, so no attempt has been spent."
  fi
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) PATH="$bin:$PATH"; export PATH ;;
  esac
  info "  runtime: node $("$bin/node" -v) from $bin"
}

# Open a separate window showing what a dispatched agent is actually doing.
#
# The driver's own output reports which commands ran and which gates passed; it
# never showed the agent's reasoning, tool calls or their results, which is the
# part worth watching when a dispatch runs for half an hour. This is a viewer
# over the same log file: closing it affects nothing, and opening it late loses
# nothing because the log is replayed from the top.
#
# AITEAM_NO_TERMINAL=1 turns it off, which is required for CI, cron, or any run
# with no desktop session to open a window into.
open_follow_window() {
  local id="$1" logpath="${2:-}"
  [ "${AITEAM_NO_TERMINAL:-0}" != "1" ] || return 0
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  if osascript \
       -e "tell application \"Terminal\" to do script \"cd $(printf '%q' "$REPO_ROOT") && ./aiteam/bin/follow.sh ${logpath:-$id}\"" \
       -e 'tell application "Terminal" to activate' >/dev/null 2>&1; then
    info "  opened a Terminal window following this run (AITEAM_NO_TERMINAL=1 to disable)"
  else
    warn "could not open a Terminal window; run ./aiteam/bin/follow.sh $id yourself"
  fi
}

# Serialize work on one task. Two concurrent drivers produce interleaved
# transitions and evidence that describes neither run.
task_lock() {
  local id="$1" lock="$STATE_DIR/$id.lock"
  if mkdir "$lock" 2>/dev/null; then
    # shellcheck disable=SC2064
    trap "rmdir '$lock' 2>/dev/null || true" EXIT INT TERM
    return 0
  fi
  die "$id is already being driven by another process (lock: $lock).
     Wait for it, or remove the lock directory if that process is gone."
}

# Validate a JSON file against a schema. Uses node with no external deps:
# a minimal checker covering the constraints the task contract actually relies on.
validate_schema() {
  local instance="$1" schema="$2"
  node "$AITEAM_DIR/bin/validate.mjs" "$schema" "$instance"
}
