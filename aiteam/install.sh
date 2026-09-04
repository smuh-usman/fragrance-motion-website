#!/usr/bin/env bash
# Wire the harness into a repository. Safe to re-run.
#
#   cp -r aiteam/ /path/to/new-project/
#   cd /path/to/new-project && ./aiteam/install.sh
#
# Creates .aiteam/ state, writes project.json with this project's verification
# commands, links the Claude-visible assets into .claude/, and allowlists the
# provider CLIs so dispatch does not prompt on every call.

set -euo pipefail
AITEAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AITEAM_DIR/.." && pwd)"
STATE_DIR="$REPO_ROOT/.aiteam"

info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }

info "Installing the AI engineering harness into $REPO_ROOT"

mkdir -p "$STATE_DIR"/{tasks,evidence,runs,wt}
ok "state directories under .aiteam/"

# ---- project.json: the ONLY coupling between the generic harness and this repo
if [ -f "$STATE_DIR/project.json" ]; then
  ok "project.json already exists (left untouched)"
else
  name="$(basename "$REPO_ROOT")"
  branch="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)"

  # Guess the verification commands from what the project looks like. These are
  # a starting point and are meant to be edited — they decide what "passing"
  # means for every task, so they are worth getting right by hand.
  if [ -f "$REPO_ROOT/package.json" ]; then
    test_cmd="npm test"; type_cmd="npm run typecheck"; lint_cmd="npm run lint"; build_cmd="npm run build"
  elif [ -f "$REPO_ROOT/go.mod" ]; then
    test_cmd="go test ./..."; type_cmd="go vet ./..."; lint_cmd="gofmt -l ."; build_cmd="go build ./..."
  elif [ -f "$REPO_ROOT/pyproject.toml" ]; then
    test_cmd="pytest"; type_cmd="mypy ."; lint_cmd="ruff check ."; build_cmd="python -m build"
  else
    test_cmd="echo 'no test command configured'; false"; type_cmd=""; lint_cmd=""; build_cmd=""
  fi

  cat > "$STATE_DIR/project.json" <<EOF
{
  "\$comment": "The only file coupling the generic harness to this project. Edit the commands below — they define what 'passing' means for every task.",
  "project": "$name",
  "default_branch": "$branch",
  "verification": {
    "test": "$test_cmd",
    "typecheck": "$type_cmd",
    "lint": "$lint_cmd",
    "build": "$build_cmd"
  }
}
EOF
  ok "project.json written (review its verification commands before dispatching work)"
fi

# ---- gitignore
if ! grep -qs '^\.aiteam/' "$REPO_ROOT/.gitignore" 2>/dev/null; then
  cat >> "$REPO_ROOT/.gitignore" <<'EOF'

# AI engineering harness runtime state.
# Task definitions and evidence are tracked (they are the project's record of
# what was built and how it was proven); worktrees and raw transcripts are not.
.aiteam/wt/
.aiteam/runs/
EOF
  ok ".gitignore updated"
fi

# ---- Claude Code native assets
mkdir -p "$REPO_ROOT/.claude/agents" "$REPO_ROOT/.claude/skills"
for f in "$AITEAM_DIR"/claude/agents/*.md; do
  [ -e "$f" ] || continue
  cp "$f" "$REPO_ROOT/.claude/agents/$(basename "$f")"
done
if [ -d "$AITEAM_DIR/claude/skills" ]; then
  cp -R "$AITEAM_DIR/claude/skills/." "$REPO_ROOT/.claude/skills/" 2>/dev/null || true
fi
ok "Claude subagents and skills installed into .claude/"

# ---- permissions: dispatch must not prompt on every call
SETTINGS="$REPO_ROOT/.claude/settings.json"
if command -v jq >/dev/null 2>&1; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$(mktemp)"
  jq '
    .permissions //= {} |
    .permissions.allow = ((.permissions.allow // []) + [
      "Bash(./aiteam/bin/*)",
      "Bash(aiteam/bin/*)",
      "Bash(cmd -p:*)",
      "Bash(codex exec:*)",
      "Bash(git worktree:*)"
    ] | unique)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ok "provider CLIs allowlisted in .claude/settings.json"
fi

chmod +x "$AITEAM_DIR"/bin/*.sh "$AITEAM_DIR"/*.sh 2>/dev/null || true
ok "scripts made executable"

echo
info "Checking the installation…"
"$AITEAM_DIR/doctor.sh" || true

echo
info "Next: edit .aiteam/project.json so its verification commands are right for this repo."
info "Then read aiteam/README.md for how to author a task and dispatch it."
