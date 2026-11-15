#!/usr/bin/env bash
# usage_of.sh — 读取某个子代理会话的 token 用量，输出可直接传给 postflight --usage 的字符串
#
# 与 skill 同级，不属于技能本体：它知道 DSH 的会话日志布局，而技能本身不该知道。
set -u

usage() {
  cat <<'EOF'
用法: usage_of.sh <子代理 session id> [--latest]
      usage_of.sh --latest            # 取最近修改的会话（调试用，可能选错）
      usage_of.sh <id> --raw          # 输出 JSON 而非 --usage 字符串

输出示例（可直接用）：
  steps=12,in=2689,out=1926,cache=143545
EOF
  exit 0
}

ID=""; LATEST=0; RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --latest) LATEST=1; shift ;;
    --raw)    RAW=1; shift ;;
    -h|--help) usage ;;
    *) ID="$1"; shift ;;
  esac
done

SESS_ROOT="${DSH_HOME:-$HOME/.dsh}/sessions"
[ -d "$SESS_ROOT" ] || { echo "usage_of: 找不到会话目录 $SESS_ROOT" >&2; exit 3; }

if [ "$LATEST" -eq 1 ] || [ -z "$ID" ]; then
  LOG=$(find "$SESS_ROOT" -type f -name 'session.v4.jsonl.zstd' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
else
  LOG=$(find "$SESS_ROOT" -type f -path "*/$ID/session.v4.jsonl.zstd" 2>/dev/null | head -1)
fi

[ -n "${LOG:-}" ] || { echo "usage_of: 找不到会话日志（id=$ID）" >&2; exit 3; }
command -v zstd >/dev/null 2>&1 || { echo "usage_of: 需要 zstd 解压会话日志" >&2; exit 3; }

zstd -dc "$LOG" 2>/dev/null | python3 -c '
import json, sys
steps = tin = tout = tcache = 0
for line in sys.stdin:
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("type") != "assistant/message":
        continue
    u = (ev.get("data") or {}).get("usage") or {}
    if not u:
        continue
    steps += 1
    tin += u.get("inputTokens", 0)
    tout += u.get("outputTokens", 0)
    tcache += u.get("cacheReadTokens", 0)
if steps == 0:
    sys.stderr.write("usage_of: 该会话没有 usage 记录\n")
    raise SystemExit(2)
raw = "--raw" in sys.argv
if raw:
    print(json.dumps({"steps": steps, "in": tin, "out": tout, "cache": tcache}))
else:
    print(f"steps={steps},in={tin},out={tout},cache={tcache}")
' "$([ "$RAW" -eq 1 ] && echo --raw || echo '')"
