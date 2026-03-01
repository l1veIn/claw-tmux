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

# Capture last 20 lines as preview (more context for agent to understand status)
preview=""
if tmux has-session -t "$pty_id" 2>/dev/null; then
  preview=$(tmux capture-pane -t "$pty_id:0.0" -p -S -500 2>/dev/null | grep -v '^$' | tail -20 | tr '\n' ' ')
  if [[ -z "$preview" ]]; then
    preview=$(tmux capture-pane -t "$pty_id" -p -S -500 2>/dev/null | grep -v '^$' | tail -20 | tr '\n' ' ')
  fi
fi

# Friendly message when preview unavailable
if [[ -z "$preview" ]]; then
  preview="(session output unavailable - session may have exited)"
fi

# Send notification with retry (session may be locked during agent turn)
# --deliver: agent's reply should be sent back to Slack so user can see progress
max_attempts=5
delay=2
success=false

for i in $(seq 1 $max_attempts); do
  if openclaw agent \
    --session-id "$session_id" \
    --agent "$agent_id" \
    --message "[claw-tmux] $pty_id $event. Preview: $preview" \
    --deliver \
    --timeout 10 \
    2>/dev/null; then
    success=true
    break
  fi
  
  if [[ $i -lt $max_attempts ]]; then
    sleep $delay
  fi
done

if [[ "$success" == false ]]; then
  echo "$(date -Iseconds) NOTIFY_FAIL pty=$pty_id event=$event session=$session_id agent=$agent_id attempts=$max_attempts" >> "$LOG_FILE"
else
  echo "$(date -Iseconds) OK pty=$pty_id event=$event attempts=$i preview_len=${#preview}" >> "$LOG_FILE"
fi
