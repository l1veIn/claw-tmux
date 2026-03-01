#!/usr/bin/env bash
# session.sh — core session management functions for claw-tmux

# ──────────────────────────────────────────────
# cmd_new — create a new managed tmux session
# ──────────────────────────────────────────────
cmd_new() {
  local agent_id="" claw_session="" chat_id="" tool="$CLAW_TMUX_DEFAULT_TOOL" custom_cmd=""
  local cwd="" cols="$CLAW_TMUX_COLS" rows="$CLAW_TMUX_ROWS" no_hooks=false
  local prompt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent)   agent_id="$2";      shift 2 ;;
      -s|--session) claw_session="$2";  shift 2 ;;
      --chat-id)    chat_id="$2";       shift 2 ;;
      -t|--tool)    tool="$2";          shift 2 ;;
      --command)    custom_cmd="$2";    shift 2 ;;
      -c|--cwd)     cwd="$2";          shift 2 ;;
      --cols)       cols="$2";          shift 2 ;;
      --rows)       rows="$2";          shift 2 ;;
      --no-hooks)   no_hooks=true;      shift ;;
      -h|--help)    _help_new; return 0 ;;
      -*)           die "Unknown option: $1" ;;
      *)            prompt="$1";        shift ;;
    esac
  done

  [[ -z "$agent_id" ]] && die "Missing required --agent <id>"

  # Resolve session ID: --session takes priority, otherwise use --chat-id
  if [[ -z "$claw_session" ]]; then
    [[ -z "$chat_id" ]] && die "Either --session or --chat-id is required"

    local get_session_script="$SCRIPT_DIR/lib/get-session.sh"
    if [[ ! -x "$get_session_script" ]]; then
      die "get-session.sh not found at $get_session_script"
    fi

    local session_json
    session_json=$("$get_session_script" "$chat_id" "$agent_id" 2>/dev/null) \
      || die "Failed to resolve session for chat_id=$chat_id agent=$agent_id"

    claw_session=$(echo "$session_json" | jq -r '.sessionId // empty')
    [[ -z "$claw_session" ]] && die "Could not resolve sessionId from chat_id=$chat_id"
  fi

  # Build the command to run
  local tool_cmd
  if [[ -n "$custom_cmd" ]]; then
    tool_cmd="$custom_cmd"
  else
    case "$tool" in
      codex)   tool_cmd="codex --full-auto" ;;
      claude)  tool_cmd="claude --dangerously-skip-permissions" ;;
      gemini)  tool_cmd="gemini --approval-mode=yolo" ;;
      *)       tool_cmd="$tool" ;;
    esac
  fi

  # Generate unique session ID
  local pty_id="pty-$(date +%s)-$$"

  # Build tmux new-session command
  local -a tmux_args=(new-session -d -s "$pty_id" -x "$cols" -y "$rows")
  [[ -n "$cwd" ]] && tmux_args+=(-c "$cwd")

  # If prompt given, append it to tool command
  if [[ -n "$prompt" ]]; then
    tool_cmd="$tool_cmd $(printf '%q' "$prompt")"
  fi
  tmux_args+=("$tool_cmd")

  # Create the session
  tmux "${tmux_args[@]}" || die "Failed to create tmux session"

  # Increase scrollback
  tmux set-option -t "$pty_id" history-limit 10000 2>/dev/null

  # Register hooks (unless --no-hooks)
  if [[ "$no_hooks" == false ]]; then
    local notify_script="$SCRIPT_DIR/lib/notify.sh"

    # Enable silence monitoring
    tmux set-option -w -t "$pty_id" monitor-silence "$CLAW_TMUX_IDLE_SEC"
    tmux set-option -t "$pty_id" silence-action any

    # Hook: silence detected
    tmux set-hook -t "$pty_id" alert-silence \
      "run-shell '\"$notify_script\" \"$pty_id\" idle'"

    # Hook: process exited
    tmux set-hook -t "$pty_id" pane-exited \
      "run-shell '\"$notify_script\" \"$pty_id\" exited'"
  fi

  # Write session binding to state.json (with flock for concurrency safety)
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local real_cwd="${cwd:-$(pwd)}"

  _state_write "$pty_id" "$agent_id" "$claw_session" "$tool" "$tool_cmd" "$now" "$real_cwd"

  # Output the session ID
  echo "$pty_id"
}

# ──────────────────────────────────────────────
# cmd_write — send input to a running session
# ──────────────────────────────────────────────
cmd_write() {
  local raw=false delay="" keys="" session_id="" text=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --raw)     raw=true;    shift ;;
      --delay)   delay="$2";  shift 2 ;;
      --keys)    keys="$2";   shift 2 ;;
      -h|--help) _help_write; return 0 ;;
      -*)        die "Unknown option: $1" ;;
      *)
        if [[ -z "$session_id" ]]; then
          session_id="$1"
        else
          text="$1"
        fi
        shift
        ;;
    esac
  done

  [[ -z "$session_id" ]] && die "Missing session-id"

  # Verify session exists
  tmux has-session -t "$session_id" 2>/dev/null || die "Session '$session_id' not found"

  # Send tmux key names directly (e.g., C-c, Escape)
  if [[ -n "$keys" ]]; then
    tmux send-keys -t "$session_id" "$keys"
    return 0
  fi

  # Read from stdin if text is "-"
  if [[ "$text" == "-" ]]; then
    text=$(cat)
  fi

  [[ -z "$text" ]] && die "Missing text to send"

  if [[ -n "$delay" ]]; then
    # Send character by character with delay
    for (( i=0; i<${#text}; i++ )); do
      tmux send-keys -t "$session_id" -l "${text:$i:1}"
      sleep "$(echo "scale=3; $delay/1000" | bc)"
    done
    [[ "$raw" == false ]] && tmux send-keys -t "$session_id" Enter
  else
    tmux send-keys -t "$session_id" -l "$text"
    [[ "$raw" == false ]] && tmux send-keys -t "$session_id" Enter
  fi
}

# ──────────────────────────────────────────────
# cmd_read — capture output from a session
# ──────────────────────────────────────────────
cmd_read() {
  local full=false lines="" json=false strip_ansi=true session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--full)       full=true;        shift ;;
      -n|--lines)      lines="$2";       shift 2 ;;
      -j|--json)       json=true;        shift ;;
      --strip-ansi)    strip_ansi=true;  shift ;;
      --no-strip)      strip_ansi=false; shift ;;
      -h|--help)       _help_read;       return 0 ;;
      -*)              die "Unknown option: $1" ;;
      *)               session_id="$1";  shift ;;
    esac
  done

  [[ -z "$session_id" ]] && die "Missing session-id"

  # Check session status
  local status="alive"
  tmux has-session -t "$session_id" 2>/dev/null || status="dead"

  # Build capture-pane arguments
  local -a cap_args=(capture-pane -t "$session_id" -p)
  if [[ "$full" == true ]]; then
    cap_args+=(-S -10000)
  fi

  local content
  if [[ "$status" == "alive" ]]; then
    content=$(tmux "${cap_args[@]}" 2>/dev/null) || content=""
  else
    content="[session dead]"
  fi

  # Apply line limit
  if [[ -n "$lines" ]]; then
    content=$(echo "$content" | tail -n "$lines")
  fi

  # Strip ANSI escape codes
  if [[ "$strip_ansi" == true ]]; then
    content=$(echo "$content" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')
  fi

  # Output
  if [[ "$json" == true ]]; then
    local agent_id tool
    agent_id=$(_state_get "$session_id" "agent_id")
    tool=$(_state_get "$session_id" "cli_tool")
    local line_count
    line_count=$(echo "$content" | wc -l | tr -d ' ')

    jq -n \
      --arg sid "$session_id" \
      --arg agent "$agent_id" \
      --arg status "$status" \
      --arg content "$content" \
      --argjson lines "$line_count" \
      --arg tool "$tool" \
      '{session_id:$sid, agent_id:$agent, status:$status, content:$content, lines:$lines, tool:$tool}'
  else
    echo "$content"
  fi
}

# ──────────────────────────────────────────────
# cmd_list — list all managed sessions
# ──────────────────────────────────────────────
cmd_list() {
  local json=false filter_agent="" filter_status=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -j|--json)    json=true;           shift ;;
      -a|--agent)   filter_agent="$2";   shift 2 ;;
      -s|--status)  filter_status="$2";  shift 2 ;;
      -h|--help)    _help_list;          return 0 ;;
      -*)           die "Unknown option: $1" ;;
      *)            shift ;;
    esac
  done

  _ensure_state

  local ids
  ids=$(jq -r '.sessions | keys[]' "$STATE_FILE" 2>/dev/null)

  if [[ -z "$ids" ]]; then
    [[ "$json" == true ]] && echo "[]" || echo "No managed sessions."
    return 0
  fi

  local json_arr="["
  local first=true

  if [[ "$json" != true ]]; then
    printf "%-28s %-16s %-10s %-10s %s\n" "ID" "AGENT" "TOOL" "STATUS" "CWD"
    printf "%-28s %-16s %-10s %-10s %s\n" "---" "---" "---" "---" "---"
  fi

  while IFS= read -r pty_id; do
    [[ -z "$pty_id" ]] && continue

    local agent tool cwd status
    agent=$(_state_get "$pty_id" "agent_id")
    tool=$(_state_get "$pty_id" "cli_tool")
    cwd=$(_state_get "$pty_id" "cwd")

    # Determine status: alive or dead
    if tmux has-session -t "$pty_id" 2>/dev/null; then
      status="alive"
    else
      status="dead"
    fi

    # Apply filters
    [[ -n "$filter_agent" && "$agent" != "$filter_agent" ]] && continue
    [[ -n "$filter_status" && "$status" != "$filter_status" ]] && continue

    if [[ "$json" == true ]]; then
      [[ "$first" == true ]] && first=false || json_arr+=","
      json_arr+=$(jq -n \
        --arg id "$pty_id" \
        --arg agent "$agent" \
        --arg tool "$tool" \
        --arg status "$status" \
        --arg cwd "$cwd" \
        '{id:$id, agent:$agent, tool:$tool, status:$status, cwd:$cwd}')
    else
      printf "%-28s %-16s %-10s %-10s %s\n" "$pty_id" "$agent" "$tool" "$status" "$cwd"
    fi
  done <<< "$ids"

  [[ "$json" == true ]] && echo "${json_arr}]"
}

# ──────────────────────────────────────────────
# cmd_kill — terminate a session
# ──────────────────────────────────────────────
cmd_kill() {
  local force=false kill_agent="" session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)   force=true;        shift ;;
      --agent)      kill_agent="$2";   shift 2 ;;
      -h|--help)    _help_kill;        return 0 ;;
      -*)           die "Unknown option: $1" ;;
      *)            session_id="$1";   shift ;;
    esac
  done

  # Kill all sessions for a specific agent
  if [[ -n "$kill_agent" ]]; then
    _ensure_state
    local ids
    ids=$(jq -r ".sessions | to_entries[] | select(.value.agent_id == \"$kill_agent\") | .key" "$STATE_FILE" 2>/dev/null)
    if [[ -z "$ids" ]]; then
      echo "No sessions found for agent '$kill_agent'"
      return 0
    fi
    while IFS= read -r id; do
      _kill_one "$id" "$force"
    done <<< "$ids"
    return 0
  fi

  [[ -z "$session_id" ]] && die "Missing session-id (or use 'all')"

  if [[ "$session_id" == "all" ]]; then
    _ensure_state
    local ids
    ids=$(jq -r '.sessions | keys[]' "$STATE_FILE" 2>/dev/null)
    if [[ -z "$ids" ]]; then
      echo "No managed sessions."
      return 0
    fi
    while IFS= read -r id; do
      _kill_one "$id" "$force"
    done <<< "$ids"
  else
    _kill_one "$session_id" "$force"
  fi
}

# ──────────────────────────────────────────────
# cmd_attach — attach to a session interactively
# ──────────────────────────────────────────────
cmd_attach() {
  local session_id="${1:?Missing session-id}"

  tmux has-session -t "$session_id" 2>/dev/null || die "Session '$session_id' not found"
  tmux attach-session -t "$session_id"
}

# ══════════════════════════════════════════════
# Internal helpers
# ══════════════════════════════════════════════

_kill_one() {
  local id="$1" force="$2"

  if [[ "$force" != true ]]; then
    printf "Kill session '%s'? [y/N] " "$id"
    read -r answer
    [[ "$answer" != "y" && "$answer" != "Y" ]] && return 0
  fi

  # Kill tmux session FIRST (fast, synchronous)
  tmux kill-session -t "$id" 2>/dev/null || true

  # Remove from state.json
  _state_remove "$id"

  # Send notification in background (don't block kill)
  local notify_script="$SCRIPT_DIR/lib/notify.sh"
  if [[ -x "$notify_script" ]]; then
    "$notify_script" "$id" "exited" &>/dev/null &
  fi

  echo "Killed: $id"
}

# ── state.json helpers ──

_ensure_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"sessions":{}}' > "$STATE_FILE"
  fi
}

# Cross-platform file locking using mkdir (atomic on all POSIX systems)
_lock() {
  local retries=30
  while ! mkdir "$LOCK_FILE" 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      # Force remove stale lock (e.g., from a crashed process)
      rmdir "$LOCK_FILE" 2>/dev/null || true
      mkdir "$LOCK_FILE" 2>/dev/null || die "Failed to acquire lock"
      break
    fi
    sleep 0.1
  done
  trap '_unlock' EXIT
}

_unlock() {
  rmdir "$LOCK_FILE" 2>/dev/null || true
  trap - EXIT
}

_state_write() {
  local pty_id="$1" agent_id="$2" claw_session="$3" tool="$4" command="$5" created="$6" cwd="$7"
  _ensure_state

  _lock
  local tmp_file
  tmp_file=$(mktemp)

  jq \
    --arg id "$pty_id" \
    --arg agent "$agent_id" \
    --arg sess "$claw_session" \
    --arg tool "$tool" \
    --arg cmd "$command" \
    --arg ts "$created" \
    --arg cwd "$cwd" \
    '.sessions[$id] = {agent_id:$agent, claw_session_id:$sess, cli_tool:$tool, command:$cmd, created_at:$ts, cwd:$cwd}' \
    "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
  _unlock
}

_state_get() {
  local pty_id="$1" field="$2"
  jq -r ".sessions[\"$pty_id\"].$field // \"\"" "$STATE_FILE" 2>/dev/null
}

_state_remove() {
  local pty_id="$1"
  _ensure_state

  _lock
  local tmp_file
  tmp_file=$(mktemp)

  jq \
    --arg id "$pty_id" \
    'del(.sessions[$id])' \
    "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
  _unlock
}

# ── Help texts ──

_help_new() {
  cat <<'EOF'
Create a new CLI AI session.

Usage:
  claw-tmux new [options] [prompt]

Options:
  -a, --agent <id>      OpenClaw agent ID to bind (required)
      --chat-id <id>    Chat ID from inbound meta (e.g., "user:U0AFYM84RB9")
                        Used to auto-resolve sessionId via get-session.sh
  -s, --session <id>    OpenClaw session ID (UUID) for notification routing
                        If omitted, uses --chat-id to auto-resolve
  -t, --tool <name>     CLI tool to launch: codex, claude, gemini (default: codex)
      --command <cmd>   Custom command instead of preset tool name
  -c, --cwd <path>      Working directory for the session
      --cols <n>        Terminal width (default: 200)
      --rows <n>        Terminal height (default: 50)
      --no-hooks        Don't register tmux hooks (manual monitoring)
  -h, --help            Show this help

Session Resolution:
  If --session is provided, use it directly.
  Otherwise, use --chat-id + --agent to resolve via get-session.sh.
  Either --session or --chat-id must be provided.
EOF
}

_help_write() {
  cat <<'EOF'
Send input to a running session.

Usage:
  claw-tmux write [options] <session-id> <text>
  echo "text" | claw-tmux write <session-id> -

Options:
      --raw             Don't append Enter after the text
      --delay <ms>      Delay between characters in ms (for slow tools)
      --keys <keys>     Send tmux key names (e.g., "C-c", "Enter", "Escape")
  -h, --help            Show this help
EOF
}

_help_read() {
  cat <<'EOF'
Capture output from a session.

Usage:
  claw-tmux read [options] <session-id>

Options:
  -f, --full            Include scrollback buffer (up to 10000 lines)
  -n, --lines <n>       Capture last N lines only
  -j, --json            Output as JSON with metadata
      --strip-ansi      Remove ANSI escape codes (default: true)
      --no-strip        Keep raw ANSI escape codes
  -h, --help            Show this help
EOF
}

_help_list() {
  cat <<'EOF'
List all managed sessions.

Usage:
  claw-tmux list [options]

Options:
  -j, --json            Output as JSON array
  -a, --agent <id>      Filter by agent ID
  -s, --status <s>      Filter by status: alive, dead
  -h, --help            Show this help
EOF
}

_help_kill() {
  cat <<'EOF'
Terminate a session.

Usage:
  claw-tmux kill [options] <session-id>

Arguments:
  session-id            Session to kill, or "all" to kill everything

Options:
      --agent <id>      Kill all sessions for a specific agent
  -f, --force           Skip confirmation
  -h, --help            Show this help
EOF
}
