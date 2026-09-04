#!/usr/bin/env bash
# Follow a dispatched agent's actual output, live and readable.
#
#   follow.sh              newest run log for any task
#   follow.sh TASK-0003    newest run log for that task, then any later one
#
# watch.sh answers "what is the harness doing" — which task is in which state,
# which processes are alive. This answers the other question: what is the agent
# actually saying and doing right now. Both read shared state from disk, so
# either can run in any terminal regardless of who started the task.
#
# The log keeps being written whether or not anyone is watching, so attaching
# late loses nothing: this replays the run from the top, then follows.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

arg="${1:-}"
render="$AITEAM_DIR/bin/render-events.mjs"

# An explicit path is what dispatch passes, because "newest log for this task" is
# ambiguous at the moment a run starts: the file does not exist yet, so the newest
# match is the *previous* attempt and the window would follow the wrong run.
explicit=""
case "$arg" in
  */*|*.log) explicit="$arg"; id="" ;;
  *)         explicit="";     id="$arg" ;;
esac

newest_log() {
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] && printf '%s\n' "$explicit"
  elif [ -n "$id" ]; then
    ls -t "$RUNS_DIR/$id"-*.log 2>/dev/null | head -1
  else
    ls -t "$RUNS_DIR"/*.log 2>/dev/null | head -1
  fi
}

log="$(newest_log)"

# Dispatch opens this viewer at the same moment it creates the log, so a race
# here is normal rather than exceptional. Wait for one instead of exiting.
if [ -z "$log" ]; then
  printf '\033[2mwaiting for the run to start%s…\033[0m\n' "${id:+ ($id)}" >&2
  while [ -z "$log" ]; do sleep 1; log="$(newest_log)"; done
fi

printf '\033[1m── following %s ──\033[0m\n' "$(basename "$log")" >&2
printf '\033[2mCtrl-C to stop watching; this does not affect the agent.\033[0m\n\n' >&2

# --follow=name --retry survives the log being rotated to a new attempt's file.
tail -n +1 -f "$log" | node "$render"
