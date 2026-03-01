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
  claw-tmux new --agent main --chat-id "user:U0AFYM84RB9" --tool codex "fix the login bug"
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
      --chat-id <id>    OpenClaw chat_id from inbound meta (e.g., "user:U0AFYM84RB9")
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
  Otherwise, use --chat-id to resolve sessionId via:
    ~/.agents/skills/get-session/lib/get-session.sh <chat_id> <agent_id>

  Either --session or --chat-id must be provided.

Returns:
  Session ID (e.g., pty-001) printed to stdout.

Examples:
  # Recommended: use --chat-id (agent provides chat_id from inbound meta)
  claw-tmux new --agent main --chat-id "user:U0AFYM84RB9" --tool codex "fix auth.ts login bug"

  # Alternative: directly specify session ID
  claw-tmux new --agent main --session "e08484d6-7310-4957-9d21-156f87d352ed" --tool codex "fix bug"

  # Claude Code in a specific directory
  claw-tmux new -a main --chat-id "user:U0AFYM84RB9" -t claude -c /path/to/project "refactor"

  # Custom command
  claw-tmux new -a main --chat-id "user:U0AFYM84RB9" --command "aider --model gpt-4" "add logging"

  # No initial prompt (just launch the tool)
  claw-tmux new -a main --chat-id "user:U0AFYM84RB9" -t codex
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
  -s, --status <s>      Filter by status: alive, dead
  -h, --help            Show this help

Table output:
  ID            AGENT           TOOL     STATUS    CWD
  pty-001       main            codex    alive     /app/src
  pty-002       main            claude   alive     /api
  pty-003       main            gemini   dead      /infra

Examples:
  claw-tmux list
  claw-tmux list --agent main
  claw-tmux list --status dead --json
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
  claw-tmux kill --agent main
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

---

## Session ID 自动解析

claw-tmux 使用 `get-session.sh` 脚本自动解析 OpenClaw session ID：

**脚本路径**: `~/.agents/skills/get-session/lib/get-session.sh`

**用法**:
```bash
get-session.sh <chat_id> <agent_id>
```

**示例**:
```bash
# 输入
get-session.sh "user:U0AFYM84RB9" "main"

# 输出
{"key":"agent:main:main","sessionId":"e08484d6-7310-4957-9d21-156f87d352ed","agentId":"main"}
```

**匹配逻辑**:
1. 调用 `openclaw sessions --agent <agent_id> --json`
2. 对于 DM: key 固定为 `agent:<agentId>:main`
3. 对于 Group: key 包含 channel 信息，通过 `deliveryContext.to` 匹配

**Agent 调用示例**:
```bash
# Agent 从 Runtime 获取 agentId，从 Inbound Meta 获取 chat_id
# 直接传给 claw-tmux，无需自己解析 sessionId
claw-tmux new --agent main --chat-id "user:U0AFYM84RB9" --tool codex "fix the bug"
```
