# claw-tmux

CLI AI session manager for Claw agents. Manage CLI AI tools (Codex, Claude Code, Gemini, etc.) like tmux sessions, with automatic idle detection and OpenClaw agent notification.

## Features

- **Session Management** — Create, write, read, attach, list, and kill AI tool sessions
- **Zero-Daemon Architecture** — Uses tmux native `monitor-silence` + hooks for event-driven completion detection
- **OpenClaw Integration** — Automatic notification to Claw agents when sessions go idle or exit

## Requirements

- **tmux 3.2+** (for `silence-action` support)
- **jq** (for JSON state management)
- **Bash 4+**

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/l1veIn/claw-tmux/main/install.sh | bash
```

Re-run to update.

## Quick Start

```bash
# Start a Codex session
claw-tmux new --agent agent-fe --session sess-123 --tool codex "fix the login bug"
# Returns: pty-1740000000-12345

# Send follow-up input
claw-tmux write pty-1740000000-12345 "now add unit tests"

# Read output
claw-tmux read pty-1740000000-12345 --json

# List all sessions
claw-tmux list

# Kill a session
claw-tmux kill pty-1740000000-12345 -f
```

## Commands

| Command | Description |
|---------|-------------|
| `new` | Create a new CLI AI session |
| `write` | Send input to a session |
| `read` | Capture output from a session |
| `attach` | Attach to a session interactively |
| `list` | List all managed sessions |
| `kill` | Terminate a session |

Run `claw-tmux <command> --help` for detailed usage.

## How It Works

1. `claw-tmux new` creates a tmux session and registers hooks:
   - `alert-silence` — fires when the pane has no output for N seconds
   - `pane-exited` — fires when the process exits
2. Hooks call `lib/notify.sh`, which reads `~/.claw-tmux/state.json` and sends a notification via `openclaw agent`
3. The Claw agent receives the notification and can `read` the output, `write` new input, or `kill` the session

## Configuration

Create `~/.claw-tmux/config` to override defaults:

```bash
# Idle detection threshold (seconds)
CLAW_TMUX_IDLE_SEC=5

# Default CLI tool
CLAW_TMUX_DEFAULT_TOOL=codex

# Terminal size
CLAW_TMUX_COLS=200
CLAW_TMUX_ROWS=50
```

Environment variables (`CLAW_TMUX_IDLE_SEC`, etc.) take highest priority.

## File Structure

```
claw-tmux/
├── claw-tmux              # Main entry script
├── lib/
│   ├── session.sh         # Session management (new/write/read/list/kill/attach)
│   └── notify.sh          # Hook callback script (openclaw notification)
├── config/
│   └── default.conf       # Default configuration
├── docs/
│   ├── claw-tmux-cli-design.md
│   └── claw-tmux-implementation-plan.md
└── README.md
```

Runtime files (`~/.claw-tmux/`):
- `state.json` — Session bindings
- `state.lock` — flock concurrency protection
- `config` — User configuration overrides
- `notify.log` — Notification failure log

## License

MIT
