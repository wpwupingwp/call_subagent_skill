#!/usr/bin/env bash
# postflight.sh — 对子代理的产物做机械验收：变更清单、越界违规、历史改写、
# 测试退出码，并产出 patch 与 MANIFEST.json。
#
# 退出码：0 通过 / 1 测试失败 / 2 违规 / 3 环境或用法错误
set -uo pipefail

usage() {
  cat <<'EOF'
用法: postflight.sh --task <id> --child <id|auto> [--stop <reason>] [--usage <用量>]
                   [--root <工作区>] [--quiet]

判定不通过时自动丢弃：归档 patch → 还原工作区（丢弃前的 patch 存为 deliveries/<task>.abandoned.patch）。

说明:
  --stop         子代理的 stopReason。子代理非正常结束时请显式传入
                 （aborted/error/max-tokens/refusal）；日志不可读且未传时按 completed 处理。
  --root         工作区根目录（默认当前目录），用于定位 <root>/<session>/repo。
  --child        子代理会话 id（或 auto）。必填；从 DSH 会话日志读取 stop 与用量。
  --usage        手工指定用量（覆盖 --child 的自动读取）。
  依赖 preflight.sh 写出的 <任务目录>/dispatch.env。
EOF
  exit "${1:-3}"
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
    -h|--help) usage 0 ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done
[ -n "$TASK" ] || { echo "postflight: 必须指定 --task" >&2; usage; }
[ -n "${CHILD:-}" ] || { echo "postflight: 必须指定 --child <子代理 id|auto>" >&2; usage; }

ROOT="${TASK_ROOT:-$PWD}"
SESSION="${DSH_SESSION_ID:-unknown}"
[ -n "${DSH_SESSION_ID:-}" ] || printf 'postflight: 警告 —— DSH_SESSION_ID 未设置，会话目录退化为 unknown/\n' >&2
REPO="$ROOT/$SESSION/repo"
TDIR="$REPO/tasks/$TASK"

TMPD="$TDIR/tmp"
[ -f "$TDIR/dispatch.env" ] || { echo "postflight: 缺少 $TDIR/dispatch.env，先跑 preflight.sh" >&2; exit 3; }
# shellcheck disable=SC1090
. "$TDIR/dispatch.env"

# 兼容旧 dispatch.env 里的相对路径：先归一化，再 cd；之后的输出路径都是绝对的。
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { echo "postflight: 仓库不存在: $REPO" >&2; exit 3; }
TDIR="$REPO/tasks/$TASK"
TMPD="$TDIR/tmp"

[ -d "$REPO/.git" ] || { echo "postflight: $REPO 不是 git 仓库" >&2; exit 3; }
cd "$REPO" || exit 3
mkdir -p "$TMPD"

if [ -f "$REPO/.git/index.lock" ]; then
  printf 'postflight: 仓库存在 .git/index.lock（可能是子代理中断留下的）。\n' >&2
  printf '确认没有 git 进程在跑之后删除它，再重跑：rm %s/.git/index.lock\n' "$REPO" >&2
  exit 3
fi

if [ -z "$STOP" ]; then
  STOP="completed"
fi

# 同一任务已判定过就拒绝重跑：产物已进历史，重跑会把它们当成越界改动，
# 并覆盖上一次的归档（审计链断裂）。要重新判定请用新的任务 id。
if git cat-file -e "HEAD:tasks/$TASK/MANIFEST.json" 2>/dev/null; then
  printf 'postflight: 任务 %s 已有判定结果（HEAD:tasks/%s/MANIFEST.json），拒绝重跑；如需重新判定请换新任务 id\n' "$TASK" "$TASK" >&2
  exit 3
fi

# --child 读 DSH 会话日志；压缩工具由 DSH 环境保证。
child_log() {
  local id="$1"
  find "${DSH_HOME:-$HOME/.dsh}/sessions" -type f -path "*/$id/session.v4.jsonl.zstd" 2>/dev/null | head -1
}

# --child auto：按 parentSession + createdAt 找本次派发的子会话
resolve_child() {
  [ "$CHILD" = "auto" ] || return 0
  local parent="${DSH_SESSION_ID:-}" best="" best_t=0
  [ -n "$parent" ] || return 1
  local home="${DSH_HOME:-$HOME/.dsh}"
  local since
  since=$(sed -n 's/^CREATED=//p' "$TDIR/dispatch.env" | tr -d "'\"" )
  since=$(python3 -c 'import sys, datetime
try:
    print(int(datetime.datetime.fromisoformat(sys.argv[1].strip().replace("Z", "+00:00")).timestamp() * 1000))
except Exception:
    print(0)' "$since" 2>/dev/null || echo 0)
  while IFS= read -r f; do
    local first t
    # head 读到首行就关闭管道；sed -n 1p 会把整份日志读完，成本高一个数量级。
    first=$(zstd -dc "$f" 2>/dev/null | head -n 1 || true)
    case "$first" in *"\"parentSession\":\"$parent\""*) ;; *) continue ;; esac
    t=$(printf '%s' "$first" | sed -n 's/.*"createdAt":\([0-9]*\).*/\1/p')
    [ -n "$t" ] && [ "$t" -ge "$since" ] && [ "$t" -gt "$best_t" ] && { best_t=$t; best=$f; }
  done < <(find "$home/sessions" -type f -name 'session.v4.jsonl.zstd' 2>/dev/null)
  [ -n "$best" ] || return 1
  CHILD=$(basename "$(dirname "$best")")
  echo "postflight: 自动匹配到子代理会话 $CHILD" >&2
}

# 一次完整解压同时拿 stop 与 usage；两者来自同一份事件流，没必要解两遍。
read_child_meta() {
  [ -n "$CHILD" ] || return 1
  local log out
  log=$(child_log "$CHILD")
  [ -n "$log" ] || return 1
  out=$(zstd -dc "$log" 2>/dev/null | python3 -c '
import json, sys
steps=ti=to=tc=0
kind=""
for line in sys.stdin:
    try: ev=json.loads(line)
    except Exception: continue
    t=ev.get("type")
    if t=="assistant/message":
        u=(ev.get("data") or {}).get("usage") or {}
        if u:
            steps+=1; ti+=u.get("inputTokens",0); to+=u.get("outputTokens",0); tc+=u.get("cacheReadTokens",0)
    elif t=="turn/end":
        kind=((ev.get("data") or {}).get("reason") or {}).get("kind") or kind
print(kind)
print(f"steps={steps},in={ti},out={to},cache={tc}" if steps else "")
' 2>/dev/null) || return 1
  CHILD_STOP=$(printf '%s\n' "$out" | sed -n '1p')
  CHILD_USAGE=$(printf '%s\n' "$out" | sed -n '2p')
  CHILD_META_OK=1
}

# 日志/子会话不可得时 stop 只能按 --stop 或默认值判定；把这件事说清楚。
warn_stop_skipped() {
  if [ -n "${STOP_GIVEN:-}" ]; then
    printf 'postflight: %s，stop 校正已跳过；按 --stop=%s 判定\n' "$1" "$STOP" >&2
  else
    printf 'postflight: %s，stop 校正已跳过；按默认 completed 判定（非正常结束请显式传 --stop）\n' "$1" >&2
  fi
}

# 尽量早解析 --child auto：MANIFEST 也要记录解析后的 id
if [ "$CHILD" = "auto" ]; then
  if ! resolve_child; then
    printf 'postflight: --child auto 未匹配到子会话，childSession 记为 null\n' >&2
    warn_stop_skipped "子会话日志不可读"
    CHILD=""
  fi
fi

CHILD_META_OK=0; CHILD_STOP=""; CHILD_USAGE=""
if [ -n "${CHILD:-}" ]; then
  if ! read_child_meta; then
    warn_stop_skipped "子会话日志不可读"
  fi
fi

# 用子会话日志的结束原因校正 --stop：日志是事实，命令行是转述
if [ "$CHILD_META_OK" -eq 1 ] && [ -n "$CHILD_STOP" ]; then
  if [ -z "${STOP_GIVEN:-}" ]; then
    STOP="$CHILD_STOP"
    printf 'postflight: stopReason 取自子会话日志: %s\n' "$STOP" >&2
  elif [ "$CHILD_STOP" != "$STOP" ]; then
    printf 'postflight: 警告 —— --stop=%s 与子会话日志的 %s 不一致，以日志为准\n' "$STOP" "$CHILD_STOP" >&2
    STOP="$CHILD_STOP"
  fi
fi

# now_utc：usage.tsv 时间戳
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 统计非空行（grep -c .）
count_lines() {
  local n
  n=$(grep -c . "$1" 2>/dev/null) && printf '%s' "$n" || printf '0'
}


is_allowed() {
  local f="$1" e
  local -a _al
  f="${f#./}"
  IFS=',' read -ra _al <<< "$ALLOW"
  for e in "${_al[@]}"; do
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
    while [ "${e#./}" != "$e" ]; do e="${e#./}"; done
    e="${e%/}"
    [ -z "$e" ] && continue
    case "$e" in /*) continue ;; esac   # 旧 dispatch.env 里的绝对路径不匹配任何仓库相对路径
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
HEAD_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
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
TEST_EXIT=""
if [ -n "${TESTS:-}" ]; then
  ( bash -c "$TESTS" ) > "$TDIR/test.log" 2>&1
  TEST_EXIT=$?
else
  printf '（未配置验收命令：判定只覆盖白名单、历史与工作树）\n' > "$TDIR/test.log"
fi
TEST_DISPLAY="${TEST_EXIT:-skipped}"

# ---- 7. 判定 ----
VERDICT="pass"; EXIT=0
if [ "$VIOLATION_COUNT" -gt 0 ] || [ "$REWRITTEN" = yes ] || [ "$PROTO_VIOLATION" = yes ] || [ "$HEAD_BRANCH" != "main" ]; then
  VERDICT="reject"; EXIT=2
elif [ "$STOP" != "completed" ]; then
  VERDICT="fail"; EXIT=1
elif [ "$CHANGED_COUNT" -eq 0 ]; then
  VERDICT="fail"; EXIT=1
elif [ -n "$TEST_EXIT" ] && [ "$TEST_EXIT" -ne 0 ]; then
  VERDICT="fail"; EXIT=1
fi

# 丢弃/生成失败时也要留下判定：否则仓库停在半还原态且没有 MANIFEST/patch 可查。
error_patch() {
  local src="${1:-}" dest="$TDIR/deliveries/$TASK.error.patch"
  [ -n "$src" ] && [ -s "$src" ] || return 0
  mkdir -p "$TDIR/deliveries" 2>/dev/null || true
  if [ "$src" != "$dest" ]; then
    mv "$src" "$dest" 2>/dev/null || cp "$src" "$dest" 2>/dev/null || return 0
  fi
  printf '%s' "$dest"
}

write_error_manifest() {
  local reason="$1" patch="${2:-}"
  printf '{\n  "task": "%s",\n  "session": "%s",\n  "base": "%s",\n  "head": "%s",\n  "verdict": "error",\n  "error": "%s",\n  "patch": {"file": "%s"}\n}\n' \
    "$TASK" "$SESSION" "$BASE" "$HEAD_SHA" "$reason" "$patch" > "$TDIR/MANIFEST.json" 2>/dev/null || true
}

# ---- 8. 未通过则丢弃：先归档到仓库外，再还原 ----
ARCHIVE=""
if [ "$VERDICT" != "pass" ]; then
  ARCHIVE=$(mktemp)
  if ! git add -A >/dev/null 2>&1; then
    printf 'postflight: 丢弃失败 —— git add 出错（仓库可能仍在被占用）\n' >&2
    write_error_manifest "git add failed"
    exit 3
  fi
  if ! git diff --cached --binary --no-renames "$BASE" > "$ARCHIVE"; then
    printf 'postflight: 丢弃失败 —— 导出 patch 出错\n' >&2
    write_error_manifest "patch export failed" "$(error_patch "$ARCHIVE")"
    exit 3
  fi
  if ! git reset -q --hard "$BASE"; then
    printf 'postflight: 丢弃失败 —— git reset --hard 出错，仓库未还原\n' >&2
    write_error_manifest "git reset --hard failed" "$(error_patch "$ARCHIVE")"
    exit 3
  fi
  if ! git clean -qfd; then
    printf 'postflight: 丢弃失败 —— git clean 出错\n' >&2
    write_error_manifest "git clean failed" "$(error_patch "$ARCHIVE")"
    exit 3
  fi
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
MANIFEST_OK=0
if python3 - "$TDIR" "$TASK" "$SESSION" "$BASE" "$HEAD_SHA" "$HEAD_BRANCH" "$ALLOW" \
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
    "allow": [a.strip() for a in allow.split(",") if a.strip()],
    "model": os.environ.get("MODEL") or None,
    "childSession": child or None,
    "stopReason": stop,
    "tests": tests or None,
    "testsRun": bool(tests),
    "testExitCode": int(texit) if texit.strip().isdigit() else None,
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
then
  MANIFEST_OK=1
fi

# 生成成功不代表内容有效：python 中途失败可能留下非空残缺文件。
if [ "$MANIFEST_OK" -eq 1 ] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TDIR/MANIFEST.json" >/dev/null 2>&1; then
  MANIFEST_OK=0
fi
if [ "$MANIFEST_OK" -ne 1 ]; then
  printf 'postflight: MANIFEST.json 生成失败，判定降级为 error\n' >&2
  rm -f "$TDIR/MANIFEST.json"
  # patch 改名，避免 error 判定留下一个看起来像 pass 的 <task>.patch
  if [ "${PATCH##*/}" = "$TASK.patch" ]; then
    PATCH=$(error_patch "$PATCH")
    PATCH_SHA=$(git hash-object -- "$PATCH")
    PATCH_LINES=$(count_lines "$PATCH")
  fi
  write_error_manifest "MANIFEST generation failed" "$PATCH"
  VERDICT="error"; EXIT=3
fi

# ---- 10. 消耗记录（可选）：--child 时尽力从会话日志读取，--usage 可覆盖 ----

if [ -z "$USAGE" ] && [ -n "$CHILD" ]; then
  if [ "$CHILD_META_OK" -ne 1 ]; then
    read_child_meta || true
  fi
  if [ "$CHILD_META_OK" -eq 1 ]; then
    [ -n "$CHILD_USAGE" ] && USAGE="$CHILD_USAGE"
  else
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
    pair="${pair#"${pair%%[![:space:]]*}"}"; pair="${pair%"${pair##*[![:space:]]}"}"
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
if ! git -C "$REPO" add -A -- tasks >/dev/null 2>&1; then
  printf 'postflight: 记录入历史失败 —— git add 出错\n' >&2
  VERDICT="error"; EXIT=3
fi
if ! git -C "$REPO" diff --cached --quiet; then
  case "$VERDICT" in
    pass)  SUBJ="result (pass)" ;;
    error) SUBJ="error" ;;
    *)     SUBJ="discarded ($VERDICT)" ;;
  esac
  if ! git -C "$REPO" commit -q -m "task $TASK: $SUBJ"; then
    printf 'postflight: 记录入历史失败 —— git commit 出错\n' >&2
    VERDICT="error"; EXIT=3
  fi
fi

# ---- 12. 摘要 ----
if [ "$QUIET" -eq 1 ]; then
  if [ "$STOP" = "completed" ]; then
    printf 'verdict=%s changed=%s violations=%s history=%s dirty=%s testexit=%s patch=%s\n' \
      "$VERDICT" "$CHANGED_COUNT" "$VIOLATION_COUNT" "$REWRITTEN" "$DIRTY_COUNT" "$TEST_DISPLAY" "$PATCH"
  else
    printf 'verdict=%s stop=%s changed=%s violations=%s history=%s dirty=%s testexit=%s patch=%s\n' \
      "$VERDICT" "$STOP" "$CHANGED_COUNT" "$VIOLATION_COUNT" "$REWRITTEN" "$DIRTY_COUNT" "$TEST_DISPLAY" "$PATCH"
  fi
  exit "$EXIT"
fi

echo "──────── postflight: $TASK ────────"
printf 'BASE        %s\n' "${BASE:0:12}"
printf 'HEAD        %s (%s)\n' "${HEAD_SHA:0:12}" "$HEAD_BRANCH"
printf 'stopReason  %s\n' "$STOP"
printf '变更文件    %s\n' "$CHANGED_COUNT"
printf '越界违规    %s\n' "$VIOLATION_COUNT"
printf '历史改写    %s\n' "$REWRITTEN"
printf '交付时未提交 %s 项（%s）/ stash %s / 额外 worktree %s\n' "$DIRTY_COUNT" \
  "$([ "$PROTO_VIOLATION" = yes ] && echo 判违规 || echo 无)" \
  "$STASH_COUNT" "$WORKTREE_COUNT"
printf '测试退出码  %s（日志 %s/test.log）\n' "$TEST_DISPLAY" "$TDIR"
printf 'patch       %s（%s 行, sha %s）\n' "$PATCH" "$PATCH_LINES" "${PATCH_SHA:0:12}"
printf '判定        %s%s\n' "$VERDICT" "$([ "$DISCARDED" = yes ] && echo '  → 已归档并还原' || echo '')"
if [ "$VIOLATION_COUNT" -gt 0 ]; then
  echo "── 越界文件 ──"
  sed 's/^/  /' "$TMPD/violations.txt"
fi
echo "────────────────────────────────────"
exit "$EXIT"
