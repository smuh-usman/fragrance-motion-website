#!/usr/bin/env bash
# Live view of what the team is doing. Run it in a second terminal.
#
#   aiteam/bin/watch.sh              refresh the board + newest transcript
#   aiteam/bin/watch.sh TASK-0001    only that task
#   aiteam/bin/watch.sh --log        just follow the newest agent transcript
#
# Dispatches run for many minutes. Without a window onto them a working harness
# is indistinguishable from a hung one, which is its own kind of failure.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
need_bin jq
ensure_state_dirs

only=""; logonly=0
for a in "$@"; do
  case "$a" in
    --log) logonly=1 ;;
    TASK-*) only="$a" ;;
  esac
done

newest_log() { ls -t "$RUNS_DIR"/*.log 2>/dev/null | head -1; }

if [ "$logonly" -eq 1 ]; then
  f="$(newest_log)"
  [ -n "$f" ] || die "no agent transcript yet — nothing has been dispatched"
  info "following $(basename "$f")  (Ctrl-C to stop)"
  exec tail -n 40 -f "$f"
fi

paint_status() {
  case "$1" in
    DONE|VERIFIED|MERGED)       printf '\033[32m%-18s\033[0m' "$1" ;;
    IN_PROGRESS|TESTING|REVIEW) printf '\033[36m%-18s\033[0m' "$1" ;;
    CHANGES_REQUESTED|BLOCKED)  printf '\033[31m%-18s\033[0m' "$1" ;;
    *)                          printf '%-18s' "$1" ;;
  esac
}

trap 'printf "\n"; exit 0' INT TERM

while :; do
  printf '\033[H\033[2J'                       # home, clear
  printf '\033[1mAI engineering team — %s\033[0m   (Ctrl-C to stop)\n\n' "$(date -u +%H:%M:%SZ)"
  printf '\033[1m%-11s %-18s %-8s %-7s %s\033[0m\n' ID STATUS ATTEMPT REJECT TITLE

  found=0
  for f in "$TASKS_DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(jq -r .id "$f")"
    [ -n "$only" ] && [ "$id" != "$only" ] && continue
    found=1
    printf '%-11s ' "$id"
    paint_status "$(jq -r .status "$f")"
    printf ' %-8s %-7s %s\n' \
      "$(jq -r '.attempts // 0' "$f")" \
      "$(jq -r '.review.rejections // 0' "$f")" \
      "$(jq -r .title "$f" | cut -c1-48)"
  done
  [ "$found" -eq 1 ] || printf '  (no tasks yet)\n'

  # What is actually executing right now, as opposed to what the board records.
  printf '\n\033[1mRunning\033[0m\n'
  live="$(ps -Ao pid,etime,command 2>/dev/null \
        | grep -E '[c]md -p|[c]odex exec|[r]un\.sh TASK' \
        | sed 's/  */ /g' | cut -c1-100)"
  if [ -n "$live" ]; then
    printf '%s\n' "$live" | sed 's/^/  /'
  else
    printf '  nothing dispatched\n'
  fi

  f="$(newest_log)"
  if [ -n "$f" ]; then
    printf '\n\033[1m── %s ──\033[0m\n' "$(basename "$f")"
    tail -n 18 "$f" 2>/dev/null | sed 's/^/  /'
  fi

  sleep 3
done
