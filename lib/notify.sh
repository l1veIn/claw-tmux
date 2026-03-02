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
tool=$(jq -r ".sessions[\"$pty_id\"].cli_tool // \"unknown\"" "$STATE_FILE")
cwd=$(jq -r ".sessions[\"$pty_id\"].cwd // \"\"" "$STATE_FILE")
created_at=$(jq -r ".sessions[\"$pty_id\"].created_at // \"\"" "$STATE_FILE")

# Calculate elapsed time
elapsed=""
if [[ -n "$created_at" ]]; then
  start_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || date -d "$created_at" +%s 2>/dev/null || echo "")
  if [[ -n "$start_epoch" ]]; then
    now_epoch=$(date +%s)
    diff=$((now_epoch - start_epoch))
    if [[ $diff -ge 3600 ]]; then
      elapsed="$((diff / 3600))h$((diff % 3600 / 60))m"
    elif [[ $diff -ge 60 ]]; then
      elapsed="$((diff / 60))m$((diff % 60))s"
    else
      elapsed="${diff}s"
    fi
  fi
fi

if [[ -z "$session_id" || -z "$agent_id" ]]; then
  echo "$(date -Iseconds) ERROR no binding found pty=$pty_id event=$event" >> "$LOG_FILE"
  exit 1
fi

# Deduplicate idle notifications and implement exponential backoff.
# The flag file stores the backoff level (1, 2, 3...).
# Cleared by reactivate.sh (alert-activity) when pane becomes active again.
CLAW_TMUX_IDLE_MAX="${CLAW_TMUX_IDLE_MAX:-300}"

if [[ "$event" == "idle" ]]; then
  idle_flag="$CLAW_TMUX_HOME/${pty_id}.idle"

  # Read current backoff level
  if [[ -f "$idle_flag" ]]; then
    level=$(cat "$idle_flag" 2>/dev/null || echo 0)
    if [[ "$level" -gt 0 ]]; then
      # Already notified for this idle period, skip
      exit 0
    fi
  fi
  level=1
  echo "$level" > "$idle_flag"
fi

# State transition: Running → Idle
if [[ "$event" == "idle" ]] && tmux has-session -t "$pty_id" 2>/dev/null; then
  # Disable silence monitoring
  tmux set-option -w -t "$pty_id" monitor-silence 0 2>/dev/null || true
  # Enable activity monitoring (triggers reactivate.sh when pane has output)
  tmux set-option -w -t "$pty_id" monitor-activity on 2>/dev/null || true
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

# Build rich notification message
msg="[claw-tmux] $tool $event"
[[ -n "$elapsed" ]] && msg+=" ($elapsed)"
msg+=" | cwd: ${cwd:-unknown} | pty: $pty_id"
msg+=$'\n'
msg+="Preview: $preview"

for i in $(seq 1 $max_attempts); do
  if openclaw agent \
    --session-id "$session_id" \
    --agent "$agent_id" \
    --message "$msg" \
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
