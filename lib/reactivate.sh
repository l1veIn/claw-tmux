#!/usr/bin/env bash
# reactivate.sh — called by tmux alert-activity hook
# When pane produces new output after being idle, reactivate silence monitoring.
# This completes the auto state cycle: Idle → Running

pty_id="${1:?missing pty_id}"
CLAW_TMUX_HOME="${CLAW_TMUX_HOME:-$HOME/.claw-tmux}"

# Resolve script directory and load config
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
[[ -f "$(dirname "$SCRIPT_DIR")/config/default.conf" ]] && source "$(dirname "$SCRIPT_DIR")/config/default.conf"
[[ -f "$CLAW_TMUX_HOME/config" ]] && source "$CLAW_TMUX_HOME/config"
CLAW_TMUX_IDLE_SEC="${CLAW_TMUX_IDLE_SEC:-30}"

# Disable activity monitoring (one-shot, prevent loop)
tmux set-option -w -t "$pty_id" monitor-activity off 2>/dev/null || true

# Re-enable silence monitoring with default threshold
tmux set-option -w -t "$pty_id" monitor-silence "$CLAW_TMUX_IDLE_SEC" 2>/dev/null || true

# Clear idle flag (resets backoff level)
rm -f "$CLAW_TMUX_HOME/${pty_id}.idle"
