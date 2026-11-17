#!/usr/bin/env bash
# postflight.sh — 对子代理的产物做机械验收：变更清单、越界违规、历史改写、
# 测试退出码，并产出 patch 与 MANIFEST.json。
#
# 退出码：0 通过 / 1 测试失败 / 2 违规 / 3 环境或用法错误
set -uo pipefail

usage() {
  cat <<'EOF'
用法: postflight.sh --task <id> [--stop <reason>] [--child <id|auto>] [--usage <用量>]
                   [--root <工作区>] [--quiet]

判定不通过时自动丢弃：归档 patch → 还原工作区（丢弃前的 patch 存为 deliveries/<task>.abandoned.patch）。

说明:
  --stop         子代理的 stopReason，默认 completed。子代理非正常结束时必须显式传入
                   （aborted/error/max-tokens/refusal），否则按 completed 处理。
  --root         工作区根目录（默认当前目录），用于定位 <root>/<session>/repo。
  --child        子代理会话 id（或 auto）。给出后从会话日志读取用量并写入 tasks/usage.tsv；
                  不给则 MANIFEST.childSession 为 null、不记录用量。
  --usage        手工指定用量（覆盖 --child 的自动读取）。
  依赖 preflight.sh 写出的 <任务目录>/dispatch.env。
EOF
  exit 3
}

TASK="" STOP="" QUIET=0 USAGE="" CHILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --stop) STOP="${2:-}"; STOP_GIVEN=1; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --root)  TASK_ROOT="${2:-}"; shift 2 ;;
    --usage) USAGE="${2:-}"; shift 2 ;;
    --child) CHILD="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done
[ -n "$TASK" ] || { echo "postflight: 必须指定 --task" >&2; usage; }

ROOT="${TASK_ROOT:-$PWD}"
SESSION="${DSH_SESSION_ID:-unknown}"
REPO="$ROOT/$SESSION/repo"
TDIR="$REPO/tasks/$TASK"

TMPD="$TDIR/tmp"
[ -f "$TDIR/dispatch.env" ] || { echo "postflight: 缺少 $TDIR/dispatch.env，先跑 preflight.sh" >&2; exit 3; }
# shellcheck disable=SC1090
. "$TDIR/dispatch.env"

[ -d "$REPO/.git" ] || { echo "postflight: $REPO 不是 git 仓库" >&2; exit 3; }
cd "$REPO" || exit 3
mkdir -p "$TMPD"

if [ -z "$STOP" ]; then
  STOP="completed"
  [ -n "${STOP_GIVEN:-}" ] || printf 'postflight: 未提供 --stop，按 completed 处理；子代理非正常结束时请显式传入\n' >&2
fi

# 同一任务已判定过就拒绝重跑：产物已进历史，重跑会把它们当成越界改动，
# 并覆盖上一次的归档（审计链断裂）。要重新判定请用新的任务 id。
if git cat-file -e "HEAD:tasks/$TASK/MANIFEST.json" 2>/dev/null; then
  printf 'postflight: 任务 %s 已有判定结果（HEAD:tasks/%s/MANIFEST.json），拒绝重跑；如需重新判定请换新任务 id\n' "$TASK" "$TASK" >&2
  exit 3
fi

# --child auto：按 parentSession + createdAt 找本次派发的子会话
resolve_child() {
  [ "$CHILD" = "auto" ] || return 0
  local parent="${DSH_SESSION_ID:-}" best="" best_t=0
  [ -n "$parent" ] || return 1
  local home="${DSH_HOME:-$HOME/.dsh}"
  local since
  since=$(sed -n 's/^CREATED=//p' "$TDIR/dispatch.env" | tr -d "'\"" )
  since=$(date -d "$since" +%s000 2>/dev/null || echo 0)
  while IFS= read -r f; do
    local first t
    first=$(zstd -dc "$f" 2>/dev/null | head -1)
    case "$first" in *"\"parentSession\":\"$parent\""*) ;; *) continue ;; esac
    t=$(printf '%s' "$first" | sed -n 's/.*"createdAt":\([0-9]*\).*/\1/p')
    [ -n "$t" ] && [ "$t" -ge "$since" ] && [ "$t" -gt "$best_t" ] && { best_t=$t; best=$f; }
  done < <(find "$home/sessions" -type f -name 'session.v4.jsonl.zstd' -newermt "@$((since/1000))" 2>/dev/null)
  [ -n "$best" ] || return 1
  CHILD=$(basename "$(dirname "$best")")
  echo "postflight: 自动匹配到子代理会话 $CHILD" >&2
}

read_child_usage() {
  [ -n "$CHILD" ] || return 1
  command -v zstd >/dev/null 2>&1 || return 1
  local home="${DSH_HOME:-$HOME/.dsh}"
  local log
  log=$(find "$home/sessions" -type f -path "*/$CHILD/session.v4.jsonl.zstd" 2>/dev/null | head -1)
  [ -n "$log" ] || return 1
  local out
  out=$(zstd -dc "$log" 2>/dev/null | python3 -c '
import json, sys
steps=ti=to=tc=0
for line in sys.stdin:
    try: ev=json.loads(line)
    except Exception: continue
    if ev.get("type")!="assistant/message": continue
    u=(ev.get("data") or {}).get("usage") or {}
    if not u: continue
    steps+=1; ti+=u.get("inputTokens",0); to+=u.get("outputTokens",0); tc+=u.get("cacheReadTokens",0)
if steps==0: raise SystemExit(2)
print(f"steps={steps},in={ti},out={to},cache={tc}")
' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  USAGE="$out"
  return 0
}


read_child_stop() {
  [ -n "$CHILD" ] || return 1
  command -v zstd >/dev/null 2>&1 || return 1
  local home="${DSH_HOME:-$HOME/.dsh}"
  local log kind
  log=$(find "$home/sessions" -type f -path "*/$CHILD/session.v4.jsonl.zstd" 2>/dev/null | head -1)
  [ -n "$log" ] || return 1
  kind=$(zstd -dc "$log" 2>/dev/null | python3 -c '
import json, sys
kind = None
for line in sys.stdin:
    try: ev = json.loads(line)
    except Exception: continue
    if ev.get("type") == "turn/end":
        kind = ((ev.get("data") or {}).get("reason") or {}).get("kind") or kind
if kind: print(kind)
' 2>/dev/null) || return 1
  [ -n "$kind" ] || return 1
  printf '%s' "$kind"
}

# 尽量早解析 --child auto：MANIFEST 也要记录解析后的 id
resolve_child || true

# 用子会话日志的结束原因校正 --stop：日志是事实，命令行是转述
if CHILD_KIND=$(read_child_stop); then
  if [ -z "${STOP_GIVEN:-}" ]; then
    STOP="$CHILD_KIND"
    printf 'postflight: stopReason 取自子会话日志: %s\n' "$STOP" >&2
  elif [ "$CHILD_KIND" != "$STOP" ]; then
    printf 'postflight: 警告 —— --stop=%s 与子会话日志的 %s 不一致，以日志为准\n' "$STOP" "$CHILD_KIND" >&2
    STOP="$CHILD_KIND"
  fi
fi

# 读子会话最后一个 turn/end 的结束原因，用于校验 --stop
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

count_lines() {
  local n
  n=$(grep -c . "$1" 2>/dev/null) && printf '%s' "$n" || printf '0'
}


is_allowed() {
  local f="$1" e
  local IFS=','
  for e in $ALLOW; do
    e="${e%/}"
    [ -z "$e" ] && continue
    [ "$f" = "$e" ] && return 0
    case "$f" in "$e"/*) return 0 ;; esac
  done
  return 1
}

# ---- 1. 交付状态：子代理应当已提交；脏树默认判违规 ----
git status --porcelain > "$TMPD/dirty-before.txt"
DIRTY_COUNT=$(count_lines "$TMPD/dirty-before.txt")
DISCARDED=no
PROTO_VIOLATION=no
if [ "$DIRTY_COUNT" -gt 0 ]; then
  PROTO_VIOLATION=yes
fi

# ---- 2. 变更清单：只读提交历史，不碰索引 ----
HEAD_SHA=$(git rev-parse HEAD)
git diff --no-renames --name-only "$BASE" "$HEAD_SHA" > "$TMPD/changed.txt"
CHANGED_COUNT=$(count_lines "$TMPD/changed.txt")

# ---- 3. 历史是否被改写：BASE 必须是 HEAD 的祖先 ----
REWRITTEN=no
if [ "$HEAD_SHA" != "$BASE" ]; then
  git merge-base --is-ancestor "$BASE" "$HEAD_SHA" 2>/dev/null || REWRITTEN=yes
fi

# ---- 4. 白名单核对 ----
: > "$TMPD/violations.txt"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_allowed "$f" || printf '%s\n' "$f" >> "$TMPD/violations.txt"
done < "$TMPD/changed.txt"
VIOLATION_COUNT=$(count_lines "$TMPD/violations.txt")

# ---- 5. 附加可疑线索（不直接判违规，但要看得见）----
git stash list > "$TMPD/stash.txt" 2>/dev/null || true
git worktree list > "$TMPD/worktrees.txt" 2>/dev/null || true
STASH_COUNT=$(count_lines "$TMPD/stash.txt")
WORKTREE_COUNT=$(count_lines "$TMPD/worktrees.txt"); WORKTREE_COUNT=$(( WORKTREE_COUNT > 0 ? WORKTREE_COUNT - 1 : 0 ))

# ---- 6. 测试：父代理自己跑一次，不采信子代理的自述 ----
TEST_EXIT=0
if [ -n "${TESTS:-}" ]; then
  ( bash -c "$TESTS" ) > "$TDIR/test.log" 2>&1
  TEST_EXIT=$?
else
  printf '（未配置验收命令，未执行测试）\n' > "$TDIR/test.log"
  TEST_EXIT=127
fi

# ---- 7. 判定 ----
VERDICT="pass"; EXIT=0
if [ "$VIOLATION_COUNT" -gt 0 ] || [ "$REWRITTEN" = yes ] || [ "$PROTO_VIOLATION" = yes ]; then
  VERDICT="reject"; EXIT=2
elif [ "$TEST_EXIT" -ne 0 ] || [ "$STOP" != "completed" ]; then
  VERDICT="fail"; EXIT=1
fi

# ---- 8. 未通过则丢弃：先归档到仓库外，再还原 ----
ARCHIVE=""
if [ "$VERDICT" != "pass" ]; then
  ARCHIVE=$(mktemp)
  git add -A >/dev/null 2>&1
  git diff --cached --binary --no-renames "$BASE" > "$ARCHIVE"
  git reset -q --hard "$BASE"
  git clean -qfd
  DISCARDED=yes
fi

# ---- 9. 产物：patch 与 MANIFEST（在还原之后写，才不会被 clean 抹掉）----
mkdir -p "$TDIR/deliveries"
if [ -n "$ARCHIVE" ]; then
  PATCH="$TDIR/deliveries/$TASK.abandoned.patch"
  cp "$ARCHIVE" "$PATCH"
  rm -f "$ARCHIVE"
else
  PATCH="$TDIR/deliveries/$TASK.patch"
  git diff --binary --no-renames "$BASE" "$HEAD_SHA" > "$PATCH"
fi
PATCH_SHA=$(git hash-object -- "$PATCH")
PATCH_LINES=$(count_lines "$PATCH")

export MODEL
python3 - "$TDIR" "$TASK" "$SESSION" "$BASE" "$HEAD_SHA" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" "$ALLOW" \
         "$STOP" "$TEST_EXIT" "$VERDICT" "$PATCH_SHA" "$PATCH_LINES" \
         "$CHANGED_COUNT" "$VIOLATION_COUNT" "$REWRITTEN" "$DIRTY_COUNT" \
         "$PROTO_VIOLATION" "$DISCARDED" \
         "$STASH_COUNT" "$WORKTREE_COUNT" "${TESTS:-}" "${CHILD:-}" "$PATCH" <<'PYEOF'
import json, sys, os
if len(sys.argv) != 24:
    sys.stderr.write("manifest: 参数个数错误 %d\n" % len(sys.argv))
    raise SystemExit(2)
(tdir, task, session, base, head, branch, allow, stop, texit, verdict,
 psha, plines, nchanged, nviol, rewritten, ndirty,
 proto, discarded, nstash, nwt, tests, child, patch) = sys.argv[1:24]

def lines(name):
    p = os.path.join(tdir, "tmp", name)
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8", errors="replace") as fh:
        return [l.rstrip("\n") for l in fh if l.strip()]

doc = {
    "task": task,
    "session": session,
    "base": base,
    "head": head,
    "branch": branch,
    "allow": allow.split(","),
    "model": os.environ.get("MODEL") or None,
    "childSession": child or None,
    "stopReason": stop,
    "tests": tests or None,
    "testExitCode": int(texit),
    "verdict": verdict,
    "changedFiles": lines("changed.txt"),
    "violations": lines("violations.txt"),
    "historyRewritten": rewritten == "yes",
    "dirtyAtDelivery": int(ndirty),
    "dirtyIsViolation": proto == "yes",
    "discarded": discarded == "yes",
    "stashEntries": int(nstash),
    "extraWorktrees": int(nwt),
    "patch": {"file": patch,
              "contentHash": psha, "lines": int(plines)},
}
with open(os.path.join(tdir, "MANIFEST.json"), "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF

# ---- 10. 消耗记录（可选）：--child 时尽力从会话日志读取，--usage 可覆盖 ----

if [ -z "$USAGE" ] && [ -n "$CHILD" ]; then
  if ! read_child_usage; then
    echo "postflight: 无法从会话日志读取 $CHILD 的用量（环境不同或日志缺失），本次不记录" >&2
  fi
fi

if [ -n "$USAGE" ]; then
  USAGE_FILE="$REPO/tasks/usage.tsv"
  mkdir -p "$REPO/tasks"
  [ -f "$USAGE_FILE" ] || \
    printf 'time\ttask\tmodel\tverdict\tsteps\tin\tout\tcache\n' > "$USAGE_FILE"
  u_steps=""; u_in=""; u_out=""; u_cache=""
  IFS=',' read -ra kv <<< "$USAGE"
  for pair in "${kv[@]}"; do
    case "$pair" in
      steps=*) u_steps="${pair#steps=}" ;;
      in=*)    u_in="${pair#in=}" ;;
      out=*)   u_out="${pair#out=}" ;;
      cache=*) u_cache="${pair#cache=}" ;;
    esac
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now_utc)" "$TASK" "${MODEL:-}" "$VERDICT" \
    "$u_steps" "$u_in" "$u_out" "$u_cache" >> "$USAGE_FILE"
fi

# ---- 11. 记录物入历史（无论判定如何）----
git -C "$REPO" add -A -- tasks 2>/dev/null || true
git -C "$REPO" diff --cached --quiet || \
  git -C "$REPO" commit -q -m "task $TASK: $([ "$VERDICT" = pass ] && echo result || echo discarded) ($VERDICT)"

# MANIFEST 缺失意味着出处与判定无法留痕，不能当作通过
if [ ! -s "$TDIR/MANIFEST.json" ]; then
  echo "postflight: MANIFEST.json 生成失败，判定降级为 error" >&2
  VERDICT="error"; EXIT=3
fi

# ---- 12. 摘要 ----
if [ "$QUIET" -eq 1 ]; then
  printf 'verdict=%s changed=%s violations=%s history=%s dirty=%s testexit=%s patch=%s\n' \
    "$VERDICT" "$CHANGED_COUNT" "$VIOLATION_COUNT" "$REWRITTEN" "$DIRTY_COUNT" "$TEST_EXIT" "$PATCH"
  exit "$EXIT"
fi

echo "──────── postflight: $TASK ────────"
printf 'BASE        %s\n' "${BASE:0:12}"
printf 'HEAD        %s (%s)\n' "${HEAD_SHA:0:12}" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
printf 'stopReason  %s\n' "$STOP"
printf '变更文件    %s\n' "$CHANGED_COUNT"
printf '越界违规    %s\n' "$VIOLATION_COUNT"
printf '历史改写    %s\n' "$REWRITTEN"
printf '交付时未提交 %s 项（%s）/ stash %s / 额外 worktree %s\n' "$DIRTY_COUNT" \
  "$([ "$PROTO_VIOLATION" = yes ] && echo 判违规 || echo 无)" \
  "$STASH_COUNT" "$WORKTREE_COUNT"
printf '测试退出码  %s（日志 %s/test.log）\n' "$TEST_EXIT" "$TDIR"
printf 'patch       %s（%s 行, sha %s）\n' "$PATCH" "$PATCH_LINES" "${PATCH_SHA:0:12}"
printf '判定        %s%s\n' "$VERDICT" "$([ "$DISCARDED" = yes ] && echo '  → 已归档并还原' || echo '')"
if [ "$VIOLATION_COUNT" -gt 0 ]; then
  echo "── 越界文件 ──"
  sed 's/^/  /' "$TMPD/violations.txt"
fi
echo "────────────────────────────────────"
exit "$EXIT"
