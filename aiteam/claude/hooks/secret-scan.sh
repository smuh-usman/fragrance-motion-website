#!/usr/bin/env bash
# PreToolUse hook: refuse a commit that would introduce a secret.
#
# Reads the tool call on stdin. Exits 2 to block with a message the model sees.
# Deliberately conservative: it inspects staged content rather than filenames,
# because the usual way a credential lands in a repository is inside a file whose
# name looks innocuous.

set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)"

case "$cmd" in *"git commit"*) ;; *) exit 0 ;; esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
policy="$repo_root/aiteam/config/policy.json"
[ -f "$policy" ] || exit 0

staged="$(git diff --cached -U0 2>/dev/null | grep '^+' | grep -v '^+++' || true)"
[ -n "$staged" ] || exit 0

hits=""
while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  match="$(printf '%s' "$staged" | grep -nE "$pattern" | head -3 || true)"
  [ -n "$match" ] && hits="$hits
  pattern: $pattern
$match"
done < <(/usr/bin/python3 -c \
  'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["secrets"]["forbidden_patterns"]))' \
  "$policy" 2>/dev/null || true)

if [ -n "$hits" ]; then
  cat >&2 <<EOF
Blocked: the staged changes appear to contain a credential.
$hits

Secrets belong in the environment. Put the name and an obviously fake value in
.env.example instead. If this is a false positive — a test fixture or an example
string — rename it so it does not read as a live credential, rather than
disabling this check.
EOF
  exit 2
fi
exit 0
