#!/usr/bin/env bash
# preflight.sh — 为一个任务建立专属 git 仓库，冻结 BASE 与白名单，打印派发块。
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  preflight.sh --task <id> --allow <path[,path...]> [--import <path[,path...]>]
               [--tests '<命令>'] [--title '<标题>'] [--root <任务根目录>]
               [--brief <路径>] [--model <provider/model>]
               [--allow-dirty] [--allow-overlap] [--quiet]

说明:
  --task         任务标识，会成为分支名 work/<id> 与目录名
  --allow        仓库相对路径白名单，文件或目录前缀，必填
  --import       从当前目录复制进仓库的路径，逗号分隔；记录 sha256
  --tests           验收命令，postflight 原样执行并记录退出码
  --allow-dirty     允许工作树不干净（会把脏文件清单记录进 dispatch.env）
  --brief           简报路径，默认 <任务目录>/briefs/brief.md；必须存在且含
                    验收命令、白名单、交付要求，否则拒绝派发
  --allow-overlap   允许与其他未合并任务的白名单重叠（默认拒绝）
  --model           子代理模型（provider/model），记录进 dispatch.env 与 MANIFEST，
                    并在 --quiet 输出里给出 MODEL= 行，避免派发时临时决定
  --quiet           只打印 PROMPT/POINTER/MODEL，不打印 prompt 内容
EOF
  exit 3
}

TASK="" ALLOW="" IMPORT="" TESTS="" TITLE="" ROOT="${PWD}/.tasks" BRIEF="" MODEL="" ALLOW_DIRTY=0 ALLOW_OVERLAP=0 QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --task)        TASK="${2:-}"; shift 2 ;;
    --allow)       ALLOW="${2:-}"; shift 2 ;;
    --import)      IMPORT="${2:-}"; shift 2 ;;
    --tests)       TESTS="${2:-}"; shift 2 ;;
    --title)       TITLE="${2:-}"; shift 2 ;;
    --root)        ROOT="${2:-}"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --brief)         BRIEF="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --quiet)         QUIET=1; shift ;;
    --allow-overlap) ALLOW_OVERLAP=1; shift ;;
    -h|--help)     usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

die() { echo "preflight: $*" >&2; exit 3; }

version_ge() {  # version_ge A B —— A >= B 时为真；纯 bash，不依赖 sort -V
  local re='^([0-9]+)\.([0-9]+)(\.([0-9]+))?'
  local a1 a2 a3 b1 b2 b3
  [[ $1 =~ $re ]] || return 1
  a1=${BASH_REMATCH[1]}; a2=${BASH_REMATCH[2]}; a3=${BASH_REMATCH[4]:-0}
  [[ $2 =~ $re ]] || return 1
  b1=${BASH_REMATCH[1]}; b2=${BASH_REMATCH[2]}; b3=${BASH_REMATCH[4]:-0}
  if (( a1 != b1 )); then (( a1 > b1 )); return $?; fi
  if (( a2 != b2 )); then (( a2 > b2 )); return $?; fi
  (( a3 >= b3 ))
}

hash_stdin() { git hash-object --stdin; }   # 内容哈希：git 已在前提内，免去 sha256sum
hash_file()  { git hash-object -- "$1"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # POSIX date，BSD/GNU 通用


[ -n "$TASK" ] || { echo "preflight: 必须指定 --task" >&2; usage; }
[ -n "$ALLOW" ] || die "--allow 不能为空。白名单是硬约束，不允许默认全量。"

# 任务 id 只允许安全字符，因为它进入分支名与路径
case "$TASK" in
  *[!A-Za-z0-9._-]*) die "任务 id 只允许字母数字与 . _ -，实际: $TASK" ;;
esac

TDIR="$ROOT/$TASK"
REPO="$TDIR/repo"
CONV="${DSH_SESSION_ID:-unknown}"

# 前置条件：本技能全部机制都依赖 git 与可写目录，缺任一项立即给出明确原因
command -v git >/dev/null 2>&1 || die "git 不可用（PATH 中找不到）。本技能无法工作，先跑 doctor.sh。"
GV=$(git --version 2>/dev/null); GV=${GV#git version }
version_ge "$GV" 2.23 || die "git 版本过低: ${GV:-未知}，需要 >= 2.23（git switch）。先跑 doctor.sh。"

overlaps() {
  local a="${1%/}" b="${2%/}"
  [ -z "$a" ] || [ -z "$b" ] && return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"/*) return 0 ;; esac
  case "$b" in "$a"/*) return 0 ;; esac
  return 1
}

# 路径重叠检测：同一路径被两个未合并任务同时占用，会产生无法三方合并的 patch
if [ "$ALLOW_OVERLAP" -eq 0 ] && [ -d "$ROOT" ]; then
  CONFLICTS=""
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    other=$(basename "$d")
    [ "$other" = "$TASK" ] && continue
    { [ -f "$d/MERGED" ] || [ -f "$d/ABANDONED" ]; } && continue
    [ -f "$d/allow.txt" ] || continue
    while IFS= read -r mine; do
      [ -z "$mine" ] && continue
      while IFS= read -r theirs; do
        [ -z "$theirs" ] && continue
        if overlaps "$mine" "$theirs"; then
          CONFLICTS="${CONFLICTS}  路径 ${mine} 与任务 ${other} 的 ${theirs} 重叠\n"
        fi
      done < "$d/allow.txt"
    done < <(printf '%s\n' "$ALLOW" | tr ',' '\n')
  done
  if [ -n "$CONFLICTS" ]; then
    echo "preflight: 白名单与其他未合并任务重叠，拒绝派发：" >&2
    printf '%b' "$CONFLICTS" >&2
    echo "preflight: 先合并前一个任务的 patch 并在其任务目录创建 MERGED 标记，" >&2
    echo "           或显式 --allow-overlap 承担手工合并的代价。" >&2
    exit 3
  fi
fi

mkdir -p "$TDIR" 2>/dev/null || die "无法创建任务目录: $TDIR（权限或路径问题）。先跑 doctor.sh。"
mkdir -p "$TDIR/briefs" "$TDIR/reviews"   # 父代理文件放在任务目录，不进仓库
if [ -f "$TDIR/ABANDONED" ]; then
  rm -f "$TDIR/ABANDONED"
  echo "preflight: 清除旧的 ABANDONED 标记，重新开始该任务" >&2
fi

if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name  "task-bus"
  git -C "$REPO" config user.email "task-bus@localhost"
  : > "$TDIR/provenance.tsv"
  printf 'source\tcontentHash\timported_at\n' >> "$TDIR/provenance.tsv"

  if [ -n "$IMPORT" ]; then
    IFS=',' read -ra items <<< "$IMPORT"
    for it in "${items[@]}"; do
      it="${it#./}"
      [ -z "$it" ] && continue
      [ -e "$it" ] || die "导入源不存在: $it"
      mkdir -p "$REPO/$(dirname "$it")"
      cp -a "$it" "$REPO/$it"
      if [ -d "$it" ]; then
        h=$(tar -C "$it" -cf - . 2>/dev/null | hash_stdin)
      else
        h=$(hash_file "$it")
      fi
      printf '%s\t%s\t%s\n' "$it" "$h" "$(now_utc)" >> "$TDIR/provenance.tsv"
    done
  fi

  git -C "$REPO" add -A
  # --allow-empty：纯产出型任务（无 --import）也需要一个 BASE 提交
  git -C "$REPO" commit -q --allow-empty -m "bootstrap task=$TASK conv=$CONV title=${TITLE:-（无）}"
  echo "preflight: 已创建仓库 $REPO " >&2
else
  echo "preflight: 复用已有仓库 $REPO " >&2
fi

# 干净性检查：BASE 必须等于子代理实际看到的树
DIRTY=$(git -C "$REPO" status --porcelain)
if [ -n "$DIRTY" ]; then
  if [ "$ALLOW_DIRTY" -eq 1 ]; then
    echo "preflight: 警告 —— 工作树不干净，已按 --allow-dirty 放行：" >&2
    printf '%s\n' "$DIRTY" >&2
  else
    echo "preflight: 工作树不干净，拒绝派发（BASE 将不等于实际树）。脏文件：" >&2
    printf '%s\n' "$DIRTY" >&2
    echo "preflight: 先提交/清理，或显式 --allow-dirty。" >&2
    exit 3
  fi
fi

BASE=$(git -C "$REPO" rev-parse HEAD)
BRANCH="work/$TASK"

# 分支已存在则复用（幂等），否则从 BASE 创建
if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" switch -q "$BRANCH"
  echo "preflight: 复用分支 $BRANCH " >&2
else
  git -C "$REPO" switch -q -c "$BRANCH" "$BASE"
  echo "preflight: 创建分支 $BRANCH @ ${BASE:0:12} " >&2
fi

# 白名单里的路径不存在时给出警告（新建文件的任务属正常）
IFS=',' read -ra allow_items <<< "$ALLOW"
for a in "${allow_items[@]}"; do
  a="${a%/}"
  [ -z "$a" ] && continue
  [ -e "$REPO/$a" ] || echo "preflight: 提示 —— 白名单路径在仓库中尚不存在: $a" >&2
done

{
  printf 'TASK=%q\n'    "$TASK"
  printf 'CONV=%q\n'    "$CONV"
  printf 'REPO=%q\n'    "$REPO"
  printf 'TDIR=%q\n'    "$TDIR"
  printf 'BRANCH=%q\n'  "$BRANCH"
  printf 'BASE=%q\n'    "$BASE"
  printf 'ALLOW=%q\n'   "$ALLOW"
  printf 'TESTS=%q\n'   "$TESTS"
  printf 'MODEL=%q\n'   "$MODEL"
  printf 'DIRTY=%q\n'   "$([ -n "$DIRTY" ] && echo yes || echo no)"
  printf 'CREATED=%q\n' "$(now_utc)"
} > "$TDIR/dispatch.env"

# ---- 简报校验：规格只有一份，缺项即拒绝，用校验替代 prompt 里的复述 ----
BRIEF="${BRIEF:-$TDIR/briefs/brief.md}"
[ -f "$BRIEF" ] || die "缺少简报: $BRIEF。先写简报（含验收命令/白名单/交付要求）再派发。"
if [ -n "$TESTS" ] && ! grep -qF -- "$TESTS" "$BRIEF"; then
  die "简报未包含验收命令「$TESTS」。子代理将无法知道如何自检，拒绝派发。"
fi
grep -qF -- "提交" "$BRIEF" || die "简报未写明提交要求（交付必须已提交），拒绝派发。"
grep -qE "白名单|只允许改动|允许改动" "$BRIEF" || die "简报未写明允许改动的范围，拒绝派发。"

# 校验全部通过才占用路径：被拒的任务不该堵住后续任务
printf '%s\n' "$ALLOW" | tr ',' '\n' | sed '/^$/d' > "$TDIR/allow.txt"

# ---- 指针式派发 prompt：只给引用，不复述规格 ----
PROMPT_FILE="$TDIR/dispatch.prompt"
{
  printf '仓库 %s（cwd 已给，勿切分支）· BASE %s · 白名单 %s\n' "$REPO" "$BASE" "$ALLOW"
  printf '先读简报：%s\n' "$BRIEF"
  printf '交付：提交 + 测试输出写 %s/test.log + 回报 stop（completed / 未完成原因）\n' "$TDIR"
} > "$PROMPT_FILE"

if [ "$QUIET" -eq 1 ]; then
  printf 'PROMPT=%s\n' "$PROMPT_FILE"
  printf 'POINTER=读 %s 并按其执行\n' "$PROMPT_FILE"
  [ -n "$MODEL" ] && printf 'MODEL=%s\n' "$MODEL"
else
  printf '\n──────── 派发 prompt（已写入 %s，复制即用）────────\n' "$PROMPT_FILE"
  cat "$PROMPT_FILE"
  printf '────────────────────────────────────────\n\n'
fi

