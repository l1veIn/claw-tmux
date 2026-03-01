# claw-tmux CLI 接口设计

以下是 `claw-tmux` 所有命令的完整 help 输出设计。

---

## `claw-tmux --help`

```
claw-tmux — CLI AI session manager for Claw agents.

Manage CLI AI tools (Codex, Claude Code, Gemini, etc.) like tmux sessions,
with automatic idle detection and OpenClaw agent notification.

Usage:
  claw-tmux <command> [options]

Session Commands:
  new         Create a new CLI AI session
  write       Send input to a session
  read        Capture output from a session
  attach      Attach to a session interactively (like tmux attach)
  list        List all managed sessions
  kill        Terminate a session

Other:
  help        Show help for a command
  version     Print version

Examples:
  claw-tmux new --agent a1 --session sess-123 --tool codex "fix the login bug"
  claw-tmux write pty-001 "now add unit tests"
  claw-tmux read pty-001 --json
  claw-tmux list

Environment:
  CLAW_TMUX_HOME       State directory (default: ~/.claw-tmux)
  CLAW_TMUX_IDLE_SEC   Idle threshold in seconds (default: 5)
  TMUX                Detected automatically; tmux must be installed
```

---

## `claw-tmux new --help`

```
Create a new CLI AI session.

Starts a CLI AI tool in a managed tmux session, binds it to a Claw agent and
session, and registers tmux hooks (alert-silence / pane-exited) for
automatic completion detection via OpenClaw notification.

Usage:
  claw-tmux new [options] [prompt]

Arguments:
  prompt                Initial prompt to send to the CLI tool (optional)

Options:
  -a, --agent <id>      OpenClaw agent ID to bind (required)
  -s, --session <id>    OpenClaw session ID for notification routing (required)
  -t, --tool <name>     CLI tool to launch: codex, claude, gemini (default: codex)
      --command <cmd>   Custom command instead of preset tool name
  -c, --cwd <path>      Working directory for the session
      --cols <n>        Terminal width (default: 200)
      --rows <n>        Terminal height (default: 50)
      --no-hooks        Don't register tmux hooks (manual monitoring)
  -h, --help            Show this help

Returns:
  Session ID (e.g., pty-001) printed to stdout.

Examples:
  # Basic: start codex with a prompt
  claw-tmux new --agent agent-fe --session sess-123 --tool codex "fix auth.ts login bug"

  # Claude Code in a specific directory
  claw-tmux new -a agent-be -s sess-456 -t claude -c /path/to/project "refactor the API layer"

  # Custom command
  claw-tmux new -a agent-ops -s sess-789 --command "aider --model gpt-4" "add logging"

  # No initial prompt (just launch the tool)
  claw-tmux new -a agent-fe -t codex
```

---

## `claw-tmux write --help`

```
Send input to a running session.

Writes text to the session's terminal, simulating keyboard input.
A newline (Enter) is appended automatically unless --raw is specified.

Usage:
  claw-tmux write [options] <session-id> <text>
  echo "text" | claw-tmux write <session-id> -

Arguments:
  session-id            Target session ID (e.g., pty-001)
  text                  Text to send; use "-" to read from stdin

Options:
      --raw             Don't append Enter after the text
      --delay <ms>      Delay between characters in ms (for slow tools)
      --keys <keys>     Send tmux key names (e.g., "C-c", "Enter", "Escape")
  -h, --help            Show this help

Examples:
  # Send a follow-up prompt
  claw-tmux write pty-001 "now add unit tests for the fix"

  # Send Ctrl-C to interrupt
  claw-tmux write pty-001 --keys "C-c"

  # Pipe content from file
  cat instructions.md | claw-tmux write pty-001 -

  # Accept a Y/n confirmation
  claw-tmux write pty-001 --raw "y"
```

---

## `claw-tmux read --help`

```
Capture output from a session.

Reads the current terminal content of a session. By default, returns only
the visible pane. Use --full for scrollback history.

Usage:
  claw-tmux read [options] <session-id>

Arguments:
  session-id            Target session ID

Options:
  -f, --full            Include scrollback buffer (up to 10000 lines)
  -n, --lines <n>       Capture last N lines only
  -j, --json            Output as JSON with metadata
      --strip-ansi      Remove ANSI escape codes (default: true)
      --no-strip        Keep raw ANSI escape codes
  -h, --help            Show this help

JSON output fields:
  session_id            Session identifier
  agent_id              Bound Claw agent ID
  status                alive | dead (via tmux has-session)
  content               Terminal text content
  lines                 Total line count
  tool                  CLI tool name

Examples:
  # Read visible content
  claw-tmux read pty-001

  # Read as JSON (for programmatic consumption by Claw agent)
  claw-tmux read pty-001 --json

  # Read last 50 lines of scrollback
  claw-tmux read pty-001 --full -n 50

  # Keep ANSI codes (for re-rendering)
  claw-tmux read pty-001 --no-strip
```

---

## `claw-tmux list --help`

```
List all managed sessions.

Usage:
  claw-tmux list [options]

Options:
  -j, --json            Output as JSON array
  -a, --agent <id>      Filter by agent ID
  -s, --status <s>      Filter by status: running, idle, dead
  -h, --help            Show this help

Table output:
  ID            AGENT           TOOL     STATUS    IDLE     CWD
  pty-001       agent-fe        codex    idle      12s      /app/src
  pty-002       agent-be        claude   running   -        /api
  pty-003       agent-ops       gemini   dead      -        /infra

Examples:
  claw-tmux list
  claw-tmux list --agent agent-fe
  claw-tmux list --status idle --json
```

---

## `claw-tmux attach --help`

```
Attach to a session interactively.

Opens the tmux session in your terminal. Detach with Ctrl-b d.

Usage:
  claw-tmux attach <session-id>

Arguments:
  session-id            Target session ID

Examples:
  claw-tmux attach pty-001
```

---

## `claw-tmux kill --help`

```
Terminate a session.

Kills the tmux session, sends a "session_dead" notification via OpenClaw,
and removes it from state.json.

Usage:
  claw-tmux kill [options] <session-id>

Arguments:
  session-id            Session to kill, or "all" to kill everything

Options:
      --agent <id>      Kill all sessions for a specific agent
  -f, --force           Skip confirmation
  -h, --help            Show this help

Examples:
  claw-tmux kill pty-001
  claw-tmux kill --agent agent-fe
  claw-tmux kill all -f
```

---

## 配置文件 `~/.claw-tmux/config`

```bash
# Idle detection threshold (seconds, used by tmux monitor-silence)
CLAW_TMUX_IDLE_SEC=5

# Default CLI tool
CLAW_TMUX_DEFAULT_TOOL=codex

# Terminal size
CLAW_TMUX_COLS=200
CLAW_TMUX_ROWS=50
```
