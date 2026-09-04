#!/usr/bin/env bash
# Git isolation. Writing agents run under --yolo, which bypasses every permission
# prompt — the worktree is the containment boundary that makes that acceptable.
#
#   worktree.sh create <id>          isolated checkout + branch cut from the base
#   worktree.sh handoff <id>         rebase, re-verify, prepare the branch for a PR
#   worktree.sh confirm-merged <id>  record that a human merged it (verified)
#   worktree.sh destroy <id>         remove the worktree (branch is kept)
#   worktree.sh list
#
# The harness never merges. Integration is a human decision; a machine that merges
# its own work removes the last checkpoint a person actually reads.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin git; need_bin jq
ensure_state_dirs

slug() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40; }

cmd_create() {
  local id="${1:?}" title branch path
  title="$(task_get "$id" '.title')"
  branch="$(jq -r '.isolation.branch_prefix // "task/"' "$POLICY_CFG" 2>/dev/null || echo task/)"
  branch="task/$(echo "$id" | tr '[:upper:]' '[:lower:]')-$(slug "$title")"
  # Relative to the repo root so `$REPO_ROOT/$wt` keeps working, but inside .git/
  # so no editor treats it as a nested repository. See the note in _lib.sh.
  path=".git/aiteam-worktrees/$id"

  if [ -d "$REPO_ROOT/$path" ]; then
    info "worktree already exists for $id — reusing it"
  elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    # The branch survives a destroyed worktree (destroy keeps it for history), and
    # a retry of the same task must resume that branch rather than failing.
    info "branch $branch already exists — checking it out into a fresh worktree"
    git -C "$REPO_ROOT" worktree add "$path" "$branch" >&2 \
      || die "branch '$branch' exists but could not be checked out into $path.
     If it is checked out elsewhere, remove that worktree first: git worktree list"
    ok "worktree $path on existing branch $branch"
  else
    git -C "$REPO_ROOT" worktree add -b "$branch" "$path" "$(default_branch)" >&2 \
      || die "could not create worktree for $id"
    ok "worktree $path on branch $branch"
  fi

  task_set "$id" ".isolation = {worktree: \"$path\", branch: \"$branch\"}"
  echo "$REPO_ROOT/$path"
}

# Prepare a branch for a human-reviewed pull request. The harness deliberately
# does not merge: integration is a human decision, and a machine that merges its
# own work removes the last checkpoint a person actually reads.
cmd_handoff() {
  local id="${1:?}" wt branch db
  wt="$(task_get "$id" '.isolation.worktree')"
  branch="$(task_get "$id" '.isolation.branch')"
  db="$(default_branch)"
  [ -d "$REPO_ROOT/$wt" ] || die "no worktree for $id"

  # Commit anything the agent left uncommitted, so the diff is a real commit range.
  if [ -n "$(git -C "$REPO_ROOT/$wt" status --porcelain)" ]; then
    info "committing agent's uncommitted changes on $branch"
    git -C "$REPO_ROOT/$wt" add -A
    git -C "$REPO_ROOT/$wt" commit -q -m "$id: $(task_get "$id" '.title')" || true
  fi

  info "rebasing $branch onto $db"
  if ! git -C "$REPO_ROOT/$wt" rebase "$db" >&2; then
    git -C "$REPO_ROOT/$wt" rebase --abort 2>/dev/null || true
    die "rebase conflict on $id — the orchestrator resolves this, never the implementer.
     An agent resolving a conflict without understanding the other side's intent is
     exactly the silent overwrite the isolation model exists to prevent."
  fi

  info "re-running verification after rebase (code that passed in isolation can break once integrated)"
  "$AITEAM_DIR/bin/verify.sh" "$id" --postrebase || die "$id fails verification after rebase"

  {
    echo "branch:   $branch"
    echo "base:     $db"
    echo "prepared: $(now_iso)"
    echo "head:     $(git -C "$REPO_ROOT/$wt" log -1 --format=%H)"
    echo "commits:"
    git -C "$REPO_ROOT/$wt" log "$db..HEAD" --format='  %h %s'
  } > "$EVIDENCE_DIR/$id/handoff.log"
  task_set "$id" '.evidence.handoff = ".aiteam/evidence/'"$id"'/handoff.log"'

  ok "$id is ready for review on branch '$branch' (rebased onto $db, verification re-run)"
  info "  push and open a PR when you want it:"
  info "    git push -u origin $branch"
  local remote_url
  remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$remote_url" in
    *github.com*)
      remote_url="${remote_url%.git}"
      remote_url="${remote_url/git@github.com:/https://github.com/}"
      info "    $remote_url/compare/$db...$branch?expand=1" ;;
  esac
}

# Record that a human merged the branch. Refuses unless the merge really happened,
# so DONE still means integrated rather than intended.
cmd_confirm_merged() {
  local id="${1:?}" branch db
  branch="$(task_get "$id" '.isolation.branch')"
  db="$(default_branch)"
  git -C "$REPO_ROOT" fetch --quiet origin "$db" 2>/dev/null || true
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$db" 2>/dev/null; then
    echo "confirmed $branch merged into $db at $(now_iso)" > "$EVIDENCE_DIR/$id/merge.log"
    task_set "$id" '.evidence.merge = ".aiteam/evidence/'"$id"'/merge.log"'
    ok "$id: $branch is merged into $db"
  else
    die "$branch is not an ancestor of $db — it has not been merged yet.
     DONE means integrated, not intended, so this stays where it is."
  fi
}

cmd_destroy() {
  local id="${1:?}" wt; wt="$(task_get "$id" '.isolation.worktree // empty')"
  [ -n "$wt" ] && [ -d "$REPO_ROOT/$wt" ] || { info "nothing to remove for $id"; return 0; }
  git -C "$REPO_ROOT" worktree remove "$wt" --force >&2 && ok "removed $wt (branch kept for history)"
}

case "${1:-}" in
  create)         shift; cmd_create "$@" ;;
  handoff)        shift; cmd_handoff "$@" ;;
  confirm-merged) shift; cmd_confirm_merged "$@" ;;
  destroy)        shift; cmd_destroy "$@" ;;
  list)           git -C "$REPO_ROOT" worktree list ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
