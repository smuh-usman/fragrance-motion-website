#!/usr/bin/env bash
# Fails if the reusable layer has learned anything about this specific product.
#
# The failure mode this catches is gradual and quiet: someone adds a
# project-specific rule to a generic role file because it was convenient once,
# and the harness silently carries one product's assumptions into the next.
#
#   lint-generic.sh [--fix-hint]

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TERMS_FILE="$STATE_DIR/domain-terms.txt"

if [ ! -f "$TERMS_FILE" ]; then
  mkdir -p "$STATE_DIR"
  cat > "$TERMS_FILE" <<'EOF'
# Words specific to this project. If any appears in aiteam/, the reusable layer
# has absorbed domain knowledge and is no longer portable.
# One term per line, case-insensitive. Lines starting with # are ignored.
EOF
  info "created $TERMS_FILE — add this project's nouns to it"
fi

terms="$(grep -vE '^\s*(#|$)' "$TERMS_FILE" || true)"
[ -n "$terms" ] || { ok "no domain terms configured yet — nothing to check"; exit 0; }

# Scan only the parts meant to stay generic. bin/ and contracts/ are mechanism;
# README.md necessarily names the project it ships in.
scan_dirs="roles lenses workflows config"
violations=0

while IFS= read -r term; do
  [ -n "$term" ] || continue
  hits="$(cd "$AITEAM_DIR" && grep -rniw --include='*.md' --include='*.json' "$term" $scan_dirs 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    printf '\033[31m✗ "%s" appears in the reusable layer:\033[0m\n' "$term"
    printf '%s\n' "$hits" | sed 's/^/    /'
    violations=$((violations + 1))
  fi
done <<< "$terms"

if [ "$violations" -gt 0 ]; then
  cat >&2 <<'EOF'

The reusable layer must not know what this product is.

Move the knowledge to docs/ and reference it from the task contract's `context`
array — that is per-task and per-project, so it travels with the work instead of
with the team. Generic roles stay generic because they never learn what the
product is; they learn what good engineering is and read the product from a file.
EOF
  exit 1
fi

ok "reusable layer is free of project vocabulary"
