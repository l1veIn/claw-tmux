# 全自动状态循环方案（monitor-activity）

> 状态：**草案** — 待实现

## 背景

当前实现中，idle 通知发送后 `monitor-silence` 被禁用，**只有 `claw-tmux write` 才能重新启用**。这意味着如果 agent 收到 idle 通知后不适合立即 write（例如需要先分析、或等待用户指令），工具自行恢复工作时不会被检测到。

## 方案

利用 tmux 的 `monitor-activity` + `alert-activity` hook，实现**全自动**的 idle ↔ active 状态循环：

```
Running              →  idle 触发     →  Idle
(monitor-silence=30)                    (monitor-silence=0, monitor-activity=on)
                                             ↓
                                       有新输出 → alert-activity 触发
                                             ↓
                                        Running
                                        (monitor-activity=off, monitor-silence=30, 清除 .idle flag)
```

### 对比当前方案

| | 当前（write 触发） | 新方案（activity 触发） |
|---|---|---|
| 重新启用监控 | 仅 `claw-tmux write` | **任何 pane 输出** |
| 工具自行恢复 | ❌ 不会重新监控 | ✅ 自动重新监控 |
| 依赖 agent 行为 | 必须先 write | 无需 write |
| 误触风险 | 无 | 需要处理 attach 场景 |

## attach 隔离

### 问题

用户 `claw-tmux attach` 进入 session 后不小心碰了键盘：
1. pane 产生输出 → `alert-activity` 触发
2. 重新启用 `monitor-silence`
3. 用户 detach 后 30 秒 → **多余的 idle 通知**

### 解决

在 `claw-tmux attach` 中管理 `monitor-activity` 的生命周期：

```bash
cmd_attach() {
  local session_id="${1:?Missing session-id}"
  
  # 进入前：禁用 activity 监控，防止人类操作误触
  tmux set-option -w -t "$session_id" monitor-activity off 2>/dev/null
  
  # attach（阻塞，直到用户 Ctrl-b d detach）
  tmux attach-session -t "$session_id"
  
  # detach 后：重新启用 activity 监控
  tmux set-option -w -t "$session_id" monitor-activity on 2>/dev/null
}
```

也可以用 tmux 的 `client-detached` hook 自动恢复：

```bash
tmux set-hook -t "$session_id" client-detached \
  "set-option -w monitor-activity on"
```

## 实现步骤

### 1. 新建 `lib/reactivate.sh`

`alert-activity` hook 调用的回调脚本：

```bash
#!/usr/bin/env bash
# reactivate.sh — called by alert-activity hook
pty_id="${1:?missing pty_id}"
CLAW_TMUX_HOME="${CLAW_TMUX_HOME:-$HOME/.claw-tmux}"
CLAW_TMUX_IDLE_SEC="${CLAW_TMUX_IDLE_SEC:-30}"

# Load config
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
[[ -f "$(dirname "$SCRIPT_DIR")/config/default.conf" ]] && source "$(dirname "$SCRIPT_DIR")/config/default.conf"
[[ -f "$CLAW_TMUX_HOME/config" ]] && source "$CLAW_TMUX_HOME/config"

# Disable activity monitoring (one-shot, prevent loop)
tmux set-option -w -t "$pty_id" monitor-activity off 2>/dev/null || true

# Re-enable silence monitoring
tmux set-option -w -t "$pty_id" monitor-silence "$CLAW_TMUX_IDLE_SEC" 2>/dev/null || true

# Clear idle dedup flag
rm -f "$CLAW_TMUX_HOME/${pty_id}.idle"
```

### 2. 修改 `cmd_new` — 注册 activity hook

```bash
# Hook: activity detected → reactivate silence monitoring
tmux set-hook -t "$pty_id" alert-activity \
  "run-shell '\"$reactivate_script\" \"$pty_id\"'"
```

初始状态 `monitor-activity off`，由 `notify.sh` 在 idle 时启用。

### 3. 修改 `notify.sh` — idle 时启用 activity 监控

```bash
if [[ "$event" == "idle" ]] && tmux has-session -t "$pty_id" 2>/dev/null; then
  tmux set-option -w -t "$pty_id" monitor-silence 0 2>/dev/null || true
  tmux set-option -w -t "$pty_id" monitor-activity on 2>/dev/null || true
fi
```

### 4. 修改 `cmd_attach` — attach 时隔离 activity

```bash
cmd_attach() {
  local session_id="${1:?Missing session-id}"
  tmux has-session -t "$session_id" 2>/dev/null || die "Session not found"
  
  # Pause activity monitoring during human interaction
  tmux set-option -w -t "$session_id" monitor-activity off 2>/dev/null
  
  tmux attach-session -t "$session_id"
  
  # Resume after detach (only if idle flag exists, meaning we're in Idle state)
  if [[ -f "$CLAW_TMUX_HOME/${session_id}.idle" ]]; then
    tmux set-option -w -t "$session_id" monitor-activity on 2>/dev/null
  fi
}
```

### 5. `cmd_write` 保持不变

`write` 仍然手动重新启用 `monitor-silence` + 清除 flag，作为显式触发路径。与 activity 自动路径共存，互不冲突。

## 状态机总结

```
                    ┌──────────────────────────────┐
                    │                              │
                    ▼                              │
              ┌──────────┐                   ┌──────────┐
              │ Running  │──── silence N秒 ──▶│  Idle    │
              │          │                   │          │
              │ silence=N│                   │ silence=0│
              │ activity=│                   │ activity=│
              │   off    │                   │   on     │
              └──────────┘                   └──────────┘
                    ▲                              │
                    │                              │
                    │    pane 有新输出              │
                    │    (alert-activity)           │
                    └──────────────────────────────┘
                    
                    attach 时暂停 activity
                    detach 后恢复 activity
                    write 直接跳回 Running
                    kill / exit 退出循环
```
