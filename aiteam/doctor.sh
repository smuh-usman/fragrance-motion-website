#!/usr/bin/env bash
# Checks that the harness can actually do what it claims, before you rely on it.
# Run this after copying aiteam/ into a new repository, and whenever a dispatch
# fails for reasons that look environmental.

source "$(dirname "${BASH_SOURCE[0]}")/bin/_lib.sh"

fail=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
note() { printf '    \033[2m%s\033[0m\n' "$*"; }

echo "Tooling"
for b in git jq node bash; do
  if command -v "$b" >/dev/null 2>&1; then pass "$b ($($b --version 2>&1 | head -1 | cut -c1-40))"
  else bad "$b not found — the harness needs it"; fi
done

echo
echo "Repository"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  pass "git repository at $REPO_ROOT"
  if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    pass "has at least one commit (worktrees need one)"
  else
    bad "no commits yet — 'git worktree add' fails on an empty repository"
    note "make an initial commit before dispatching any task"
  fi
  pass "default branch: $(default_branch)"
else
  bad "not a git repository — task isolation cannot work"
fi

echo
echo "Configuration"
for f in "$MODELS_CFG" "$PROVIDERS_CFG" "$POLICY_CFG"; do
  if jq empty "$f" 2>/dev/null; then pass "$(basename "$f") parses"
  else bad "$(basename "$f") is missing or malformed"; fi
done
if [ -f "$PROJECT_CFG" ]; then pass "project.json present"
else bad ".aiteam/project.json missing — run aiteam/install.sh"; fi

echo
echo "Routed models resolve to a provider"
while IFS= read -r key; do
  m="$(model_for "$key")"
  if [ -z "$m" ]; then bad "routing '$key' names no model"; continue; fi
  if jq -e --arg m "$m" '.models[$m]' "$PROVIDERS_CFG" >/dev/null 2>&1; then pass "$key -> $m"
  else bad "$key -> $m, which is absent from providers.json"; fi
done < <(jq -r '.routing | keys[]' "$MODELS_CFG")

echo
echo "Provider CLIs"
while IFS= read -r p; do
  bin="$(jq -r --arg p "$p" '.providers[$p].bin' "$PROVIDERS_CFG")"
  if command -v "$bin" >/dev/null 2>&1; then pass "$p: '$bin' on PATH"
  else bad "$p: '$bin' not found — models on this provider cannot be dispatched"; fi
done < <(jq -r '.providers | keys[]' "$PROVIDERS_CFG")

echo
echo "Authentication"
if command -v cmd >/dev/null 2>&1; then
  if cmd status 2>&1 | grep -q "Authentication verified"; then pass "Command Code authenticated"
  else bad "Command Code not authenticated — run 'cmd login'"; fi
  note "credits are checked at dispatch time; an exhausted balance fails the first call"
fi
if command -v codex >/dev/null 2>&1; then
  if [ -f "$HOME/.codex/auth.json" ]; then pass "Codex credentials present"
  else bad "Codex not authenticated — run 'codex login'"; fi
fi

echo
echo "Escalation ladder can actually implement"
while IFS= read -r m; do
  disp="$(jq -r --arg m "$m" '.models[$m].dispatchable // false' "$PROVIDERS_CFG")"
  if [ "$disp" != "true" ]; then
    # A non-dispatchable tier is the ladder's stop condition, not a fault.
    pass "$m: stop condition (orchestrator re-scopes rather than retrying)"
    continue
  fi
  w="$(jq -r --arg m "$m" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")"
  if [ "$w" = "true" ]; then pass "$m: can write"
  else
    bad "$m is an implementation tier but cannot write files"
    note "it would burn a full attempt producing nothing; use a writing variant"
  fi
done < <(jq -r '.escalation.implementation[].model' "$MODELS_CFG")

echo
echo "Reviewer independence"
rm="$(model_for review)"
# Not `// true`: jq's alternative operator treats false as absent, so a correctly
# configured read-only reviewer would read back as writable.
if [ "$(jq -r --arg m "$rm" '.models[$m] | if has("writes_files") then .writes_files else true end' "$PROVIDERS_CFG")" = "false" ]; then
  pass "reviewer '$rm' cannot write files"
else
  bad "reviewer '$rm' can write files — review would not be independent"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mHarness looks healthy.\033[0m\n'
else
  printf '\033[31mHarness has problems above. Fix them before dispatching work.\033[0m\n'
fi
exit "$fail"
