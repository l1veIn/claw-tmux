#!/bin/bash
# get-session.sh - 获取当前活跃的 OpenClaw session 信息
# 
# 用法：
#   get-session.sh <chat_id> [agent_id]
#
# 参数：
#   chat_id  - 从 inbound meta 获取的 chat_id (如 "user:U0AFYM84RB9")
#   agent_id - 可选，指定 agent (默认 "main")
#
# 输出：
#   JSON 格式：{"key": "...", "sessionId": "...", "agentId": "..."}

set -e

CHAT_ID="${1:-}"
AGENT_ID="${2:-main}"

if [ -z "$CHAT_ID" ]; then
    echo '{"error": "chat_id is required"}' >&2
    exit 1
fi

# 获取 sessions JSON
SESSIONS_JSON=$(openclaw sessions --agent "$AGENT_ID" --json 2>/dev/null)

if [ -z "$SESSIONS_JSON" ]; then
    echo '{"error": "failed to get sessions"}' >&2
    exit 1
fi

# 匹配 deliveryContext.to 或 lastTo 等于 chat_id 的 session
# CLI 输出没有 deliveryContext，需要用其他字段匹配
# 
# 对于 DM: key 是 "agent:<agentId>:main"
# 对于 group: key 包含 channel 信息

# 简化逻辑：如果是 direct chat，key 固定为 agent:<agentId>:main
if [[ "$CHAT_ID" == user:* ]]; then
    # Direct message
    SESSION_KEY="agent:${AGENT_ID}:main"
else
    # Group/channel - 需要从 key 中提取
    # 格式: agent:<agentId>:<channel>:channel:<id>
    SESSION_KEY=$(echo "$SESSIONS_JSON" | jq -r --arg chatId "$CHAT_ID" '
        .sessions[] | select(.key | contains($chatId)) | .key' | head -1)
fi

if [ -z "$SESSION_KEY" ]; then
    echo '{"error": "session not found"}' >&2
    exit 1
fi

# 获取 sessionId
SESSION_ID=$(echo "$SESSIONS_JSON" | jq -r --arg key "$SESSION_KEY" '
    .sessions[] | select(.key == $key) | .sessionId')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
    echo '{"error": "sessionId not found"}' >&2
    exit 1
fi

# 输出 JSON
jq -n \
    --arg key "$SESSION_KEY" \
    --arg sessionId "$SESSION_ID" \
    --arg agentId "$AGENT_ID" \
    '{key: $key, sessionId: $sessionId, agentId: $agentId}'
