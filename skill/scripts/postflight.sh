#!/usr/bin/env bash
# postflight.sh — 对子代理的产物做机械验收：变更清单、越界违规、历史改写、
# 测试退出码，并产出 patch 与 MANIFEST.json。
#
# 退出码：0 通过 / 1 测试失败 / 2 违规 / 3 环境或用法错误
set -uo pipefail

usage() {
  cat <<'EOF'
用法: postflight.sh --task <id> [--stop completed|aborted|error|max-tokens|refusal|unknown] [--quiet]

判定不通过时自动丢弃：归档 patch → 还原工作区 → 写 ABANDONED（释放路径占用）。

说明:
  --stop         子代理的 stopReason。非 completed 一律判未完成（max-tokens 尤其要警惕）。
  依赖 preflight.sh 写出的 <任务目录>/dispatch.env。
EOF
  exit 3
}

TASK="" STOP="unknown" QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --stop) STOP="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --root)  TASK_ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done
[ -n "$TASK" ] || { echo "postflight: 必须指定 --task" >&2; usage; }

ROOT="${TASK_ROOT:-$PWD/.tasks}"
TDIR="$ROOT/$TASK"

[ -f "$TDIR/dispatch.env" ] || { echo "postflight: 缺少 $TDIR/dispatch.env，先跑 preflight.sh" >&2; exit 3; }
# shellcheck disable=SC1090
. "$TDIR/dispatch.env"

[ -d "$REPO/.git" ] || { echo "postflight: $REPO 不是 git 仓库" >&2; exit 3; }
cd "$REPO" || exit 3

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
git status --porcelain > "$TDIR/dirty-before.txt"
DIRTY_COUNT=$(count_lines "$TDIR/dirty-before.txt")
DISCARDED=no
PROTO_VIOLATION=no
if [ "$DIRTY_COUNT" -gt 0 ]; then
  PROTO_VIOLATION=yes
fi

# ---- 2. 变更清单：只读提交历史，不碰索引 ----
HEAD_SHA=$(git rev-parse HEAD)
git diff --no-renames --name-only "$BASE" "$HEAD_SHA" > "$TDIR/changed.txt"
CHANGED_COUNT=$(count_lines "$TDIR/changed.txt")

# ---- 3. 历史是否被改写：BASE 必须是 HEAD 的祖先 ----
REWRITTEN=no
if [ "$HEAD_SHA" != "$BASE" ]; then
  git merge-base --is-ancestor "$BASE" "$HEAD_SHA" 2>/dev/null || REWRITTEN=yes
fi

# ---- 4. 白名单核对 ----
: > "$TDIR/violations.txt"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_allowed "$f" || printf '%s\n' "$f" >> "$TDIR/violations.txt"
done < "$TDIR/changed.txt"
VIOLATION_COUNT=$(count_lines "$TDIR/violations.txt")

# ---- 5. 附加可疑线索（不直接判违规，但要看得见）----
git stash list > "$TDIR/stash.txt" 2>/dev/null || true
git worktree list > "$TDIR/worktrees.txt" 2>/dev/null || true
STASH_COUNT=$(count_lines "$TDIR/stash.txt")
WORKTREE_COUNT=$(count_lines "$TDIR/worktrees.txt"); WORKTREE_COUNT=$(( WORKTREE_COUNT > 0 ? WORKTREE_COUNT - 1 : 0 ))

# ---- 6. 测试：父代理自己跑一次，不采信子代理的自述 ----
TEST_EXIT=0
if [ -n "${TESTS:-}" ]; then
  ( bash -c "$TESTS" ) > "$TDIR/test.log" 2>&1
  TEST_EXIT=$?
else
  printf '（未配置验收命令，未执行测试）\n' > "$TDIR/test.log"
  TEST_EXIT=127
fi

# ---- 7. patch：审查时刻的防篡改副本 ----
mkdir -p "$TDIR/deliveries"
PATCH="$TDIR/deliveries/$TASK.patch"
git diff --binary --no-renames "$BASE" "$HEAD_SHA" > "$PATCH"
PATCH_SHA=$(git hash-object -- "$PATCH")
PATCH_LINES=$(count_lines "$PATCH")

# ---- 8. 判定 ----
VERDICT="pass"; EXIT=0
if [ "$VIOLATION_COUNT" -gt 0 ] || [ "$REWRITTEN" = yes ] || [ "$PROTO_VIOLATION" = yes ]; then
  VERDICT="reject"; EXIT=2
elif [ "$TEST_EXIT" -ne 0 ] || [ "$STOP" != "completed" ]; then
  VERDICT="fail"; EXIT=1
fi

# ---- 9. manifest ----
export MODEL
python3 - "$TDIR" "$TASK" "$SESSION" "$BASE" "$HEAD_SHA" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" "$ALLOW" \
         "$STOP" "$TEST_EXIT" "$VERDICT" "$PATCH_SHA" "$PATCH_LINES" \
         "$CHANGED_COUNT" "$VIOLATION_COUNT" "$REWRITTEN" "$DIRTY_COUNT" \
         "$PROTO_VIOLATION" "$DISCARDED" \
         "$STASH_COUNT" "$WORKTREE_COUNT" "${TESTS:-}" <<'PY'
import json, sys, os
if len(sys.argv) != 22:
    sys.stderr.write("manifest: 参数个数错误 %d\n" % len(sys.argv))
    raise SystemExit(2)
(tdir, task, conv, base, head, branch, allow, stop, texit, verdict,
 psha, plines, nchanged, nviol, rewritten, ndirty,
 proto, discarded, nstash, nwt, tests) = sys.argv[1:22]

def lines(name):
    p = os.path.join(tdir, name)
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8", errors="replace") as fh:
        return [l.rstrip("\n") for l in fh if l.strip()]

doc = {
    "task": task,
    "conversation": conv,
    "base": base,
    "head": head,
    "branch": branch,
    "allow": allow.split(","),
    "stopReason": stop,
    "model": os.environ.get("MODEL") or None,
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
    "patch": {"file": os.path.join(tdir, "deliveries", task + ".patch"),
              "contentHash": psha, "lines": int(plines)},
}
with open(os.path.join(tdir, "MANIFEST.json"), "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

# 判定不通过 → 自动丢弃。仓库是任务的临时产物，preflight 已保证起点干净，
# 期间的写入只可能来自子代理，因此这里销毁不会伤及父代理的任何东西。
if [ "$VERDICT" != "pass" ]; then
  mkdir -p "$TDIR/deliveries"
  # 先归档再还原：reset --hard 不会保留未跟踪文件
  git add -A >/dev/null 2>&1
  git diff --cached --binary --no-renames "$BASE" \
    > "$TDIR/deliveries/$TASK.abandoned.patch"
  git reset -q --hard "$BASE"
  git clean -qfd
  DISCARDED=yes
fi

# MANIFEST 缺失意味着出处与判定无法留痕，不能当作通过
if [ ! -s "$TDIR/MANIFEST.json" ]; then
  echo "postflight: MANIFEST.json 生成失败，判定降级为 error" >&2
  VERDICT="error"; EXIT=3
fi

# ---- 10. 摘要 ----
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
printf '判定        %s%s\n' "$VERDICT" "$([ "$DISCARDED" = yes ] && echo '  → 已归档并还原，标记 ABANDONED' || echo '')"
if [ "$VIOLATION_COUNT" -gt 0 ]; then
  echo "── 越界文件 ──"
  sed 's/^/  /' "$TDIR/violations.txt"
fi
echo "────────────────────────────────────"
exit "$EXIT"
