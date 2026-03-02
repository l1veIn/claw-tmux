# 全自动状态循环方案（monitor-activity）

> 状态：**已实现** ✅

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

**只有 Idle 状态才需要处理**（`.idle` flag 存在 = `monitor-activity on`）。Running 状态下 `monitor-activity` 是 off，人类操作不会触发任何东西。

```bash
cmd_attach() {
  local session_id="${1:?Missing session-id}"
  tmux has-session -t "$session_id" 2>/dev/null || die "Session not found"
  
  if [[ -f "$CLAW_TMUX_HOME/${session_id}.idle" ]]; then
    # Idle 状态：暂停 activity 监控，防止人类操作误触
    tmux set-option -w -t "$session_id" monitor-activity off 2>/dev/null
    tmux attach-session -t "$session_id"
    # detach 后恢复
    tmux set-option -w -t "$session_id" monitor-activity on 2>/dev/null
  else
    # Running 状态：直接 attach，无需处理
    tmux attach-session -t "$session_id"
  fi
}
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

### 4. 修改 `cmd_attach` — Idle 状态下隔离 activity

```bash
cmd_attach() {
  local session_id="${1:?Missing session-id}"
  tmux has-session -t "$session_id" 2>/dev/null || die "Session not found"
  
  if [[ -f "$CLAW_TMUX_HOME/${session_id}.idle" ]]; then
    # Idle 状态：暂停 activity 监控
    tmux set-option -w -t "$session_id" monitor-activity off 2>/dev/null
    tmux attach-session -t "$session_id"
    # detach 后恢复
    tmux set-option -w -t "$session_id" monitor-activity on 2>/dev/null
  else
    tmux attach-session -t "$session_id"
  fi
}
```

### 5. 简化 `cmd_write` — 移除监控逻辑

`write` 不再管监控状态，只负责发送文本。状态切换完全托管给 hooks：

```
write 发送文本 → pane 有输出 → alert-activity 自动触发 → reactivate.sh 恢复监控
```

移除 `cmd_write` 中的以下代码：

```diff
-  tmux set-option -w -t "$session_id" monitor-silence "$CLAW_TMUX_IDLE_SEC" 2>/dev/null || true
-  rm -f "$CLAW_TMUX_HOME/${session_id}.idle"
```

## 限流：指数退避

防止状态机抖动时高频推送。连续 idle 时倍增 `monitor-silence` 值，`alert-activity` 重置。

### 行为

| 连续第几次 idle | monitor-silence | 累计等待 |
|---------------|-----------------|---------|
| 1 | 30s | 30s |
| 2 | 60s | 1.5min |
| 3 | 120s | 3.5min |
| 4 | 240s | 7.5min |
| 5+ | 300s（封顶） | … |

### 实现

用 `.idle` flag 文件记录当前退避级别（替换原来的空文件）：

**notify.sh**（idle 时写入退避级别）：

```bash
idle_flag="$CLAW_TMUX_HOME/${pty_id}.idle"
CLAW_TMUX_IDLE_MAX=300  # 封顶 5 分钟

# 读取当前退避级别
if [[ -f "$idle_flag" ]]; then
  level=$(cat "$idle_flag" 2>/dev/null || echo 0)
else
  level=0
fi
level=$((level + 1))
echo "$level" > "$idle_flag"

# 计算下一次 silence 阈值（指数退避）
next_silence=$((CLAW_TMUX_IDLE_SEC * (2 ** (level - 1))))
(( next_silence > CLAW_TMUX_IDLE_MAX )) && next_silence=$CLAW_TMUX_IDLE_MAX
```

**reactivate.sh**（activity 时重置）：

```bash
# 清除 idle flag（重置退避级别）
rm -f "$CLAW_TMUX_HOME/${pty_id}.idle"

# 恢复默认 silence 阈值
tmux set-option -w -t "$pty_id" monitor-silence "$CLAW_TMUX_IDLE_SEC" 2>/dev/null || true
```

### 关键点

- **正常流程不受影响**：工具完成 → idle(30s) → 通知 → write/activity → 重置为 30s
- **抖动自动降频**：快速 idle↔activity 切换时，silence 阈值 30→60→120→240→300s
- **无额外文件**：复用 `.idle` flag，从空文件升级为记录退避级别
- `write` 发送文本后 activity 触发 reactivate.sh，退避级别自动归零

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
                    │    重置退避级别               │
                    └──────────────────────────────┘
                    
                    idle 通知后 silence 阈值指数退避
                    activity 触发后重置为默认值
                    attach 时暂停 activity
                    kill / exit 退出循环
```
