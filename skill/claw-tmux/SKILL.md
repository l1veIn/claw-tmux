---
name: claw-tmux
description: Manage CLI AI tools (Codex, Claude Code, Gemini) via tmux sessions with automatic idle detection and OpenClaw agent notification. Use when: (1) Running long coding tasks that need monitoring, (2) Multi-round iterative development with codex/claude, (3) Background task execution with completion notifications, (4) Need to inspect or interact with running AI tool sessions.
---

# claw-tmux

Manage CLI AI tools in tmux sessions with automatic completion notification.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/l1veIn/claw-tmux/main/install.sh | bash
```

Re-run to update.

## Quick Start

```bash
# Create session (use --chat-id from Inbound Meta)
claw-tmux new --agent main --chat-id "user:U0AFYM84RB9" --tool codex "implement feature X"

# Returns: pty-1740000000-12345
```

## Core Commands

### Create Session

```bash
claw-tmux new --agent <id> --chat-id <id> --tool <name> [prompt]
```

| Parameter | Source | Required |
|-----------|--------|----------|
| `--agent` | Runtime (agent ID) | ✅ |
| `--chat-id` | Inbound Meta | ✅ (or --session) |
| `--tool` | codex, claude, gemini | Default: codex |
| `--cwd` | Working directory | Optional |

### Read Output

```bash
claw-tmux read <pty-id>           # Plain text
claw-tmux read <pty-id> --json    # JSON format
claw-tmux read <pty-id> --full    # Include scrollback
```

### Send Input

```bash
claw-tmux write <pty-id> "next prompt"
claw-tmux write <pty-id> --keys "C-c"  # Send Ctrl-C
```

### Manage Sessions

```bash
claw-tmux list              # List all sessions
claw-tmux attach <pty-id>   # Interactive attach
claw-tmux kill <pty-id> -f  # Terminate session
```

## Notification Flow

```
Task completes → tmux hook fires → openclaw agent notification
                                    ↓
                              [claw-tmux] pty-xxx idle. Preview: ...
```

Agent receives notification via Slack/Telegram and can then:
1. `claw-tmux read` to inspect results
2. `claw-tmux write` to continue iteration

## Multi-Round Workflow

```bash
# Round 1
claw-tmux new --agent main --chat-id "user:xxx" --tool codex "fix bug in auth"
# → Notification: [claw-tmux] pty-001 idle. Preview: Bug fixed...

# Agent reviews and continues
claw-tmux read pty-001 --json
claw-tmux write pty-001 "now add tests"

# → Notification: [claw-tmux] pty-001 idle. Preview: Tests added...
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `--chat-id` | Chat ID from Inbound Meta (auto-resolves sessionId) |
| `--session` | Direct session ID (UUID) as alternative to --chat-id |
| `--tool` | CLI tool: codex, claude, gemini |
| `--command` | Custom command instead of preset tool |
| `--cwd` | Working directory |
| `--no-hooks` | Disable automatic notifications |

## Troubleshooting

```bash
# View notification logs
cat ~/.claw-tmux/notify.log

# Kill a stuck session
claw-tmux kill <pty-id> -f

# Kill all sessions
claw-tmux kill all -f

# List tmux sessions (including unmanaged ones)
tmux list-sessions
```

## Runtime Files

- `~/.claw-tmux/state.json` — session bindings
- `~/.claw-tmux/notify.log` — notification log
