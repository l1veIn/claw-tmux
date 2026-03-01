#!/usr/bin/env bash
# notify.sh — tmux hook callback script
# Called by tmux run-shell when alert-silence or pane-exited fires.
# Usage: notify.sh <pty_id> <event>
#   event: idle | exited

set -euo pipefail

pty_id="${1:?missing pty_id}"
event="${2:?missing event}"

CLAW_TMUX_HOME="${CLAW_TMUX_HOME:-$HOME/.claw-tmux}"
STATE_FILE="$CLAW_TMUX_HOME/state.json"
LOG_FILE="$CLAW_TMUX_HOME/notify.log"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "$(date -Iseconds) ERROR state.json not found pty=$pty_id event=$event" >> "$LOG_FILE"
  exit 1
fi

session_id=$(jq -r ".sessions[\"$pty_id\"].claw_session_id // empty" "$STATE_FILE")
agent_id=$(jq -r ".sessions[\"$pty_id\"].agent_id // empty" "$STATE_FILE")

if [[ -z "$session_id" || -z "$agent_id" ]]; then
  echo "$(date -Iseconds) ERROR no binding found pty=$pty_id event=$event" >> "$LOG_FILE"
  exit 1
fi

# Capture last 5 lines as preview
preview=""
if tmux has-session -t "$pty_id" 2>/dev/null; then
  preview=$(tmux capture-pane -t "$pty_id" -p 2>/dev/null | tail -5)
fi

# Send notification via openclaw
if ! openclaw agent \
  --session-id "$session_id" \
  --agent "$agent_id" \
  --message "[claw-tmux] $pty_id $event. Preview: $preview" 2>/dev/null; then
  echo "$(date -Iseconds) NOTIFY_FAIL pty=$pty_id event=$event session=$session_id agent=$agent_id" >> "$LOG_FILE"
fi
