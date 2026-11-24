#!/usr/bin/env bash
# preflight.sh — 为一个任务建立专属 git 仓库，冻结 BASE 与白名单，打印派发块。
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  preflight.sh --task <id> --allow <path[,path...]> [--import <path[,path...]>]
               [--tests '<命令>'] [--root <工作区根目录>]
               [--brief <路径>] [--model <provider/model>] [--save-model] [--quiet]
               [--clear <path[,path...]>]

说明:
  --task         任务标识，作为 tasks/<id>/ 目录名（不建分支）
  --allow        仓库相对路径白名单，文件或目录前缀，必填
  --import       从当前目录复制进仓库的路径，逗号分隔；以 git hash-object 记录内容哈希
  --tests           验收命令，postflight 原样执行并记录退出码
  --allow-no-tests  声明本次不需要验收命令（评审/文档类）；简报必须写明人工核对方式
  --brief           简报路径，默认 <任务目录>/brief.md（该默认仅适用于目录已存在
                    的复用场景，首次任务必须显式指定）；必须存在且含
                    验收命令、白名单、交付要求，否则拒绝派发
  --clear           派发前从会话仓库删掉已跟踪的上一轮交付物（如 findings.md），
                    删除并入 plan 提交；只接受仓库内相对路径，不允许 tasks/、.git 与 model
  --model           子代理模型（provider/model），记录进 dispatch.env 与 MANIFEST，
                    并在 --quiet 输出里给出 MODEL= 行，避免派发时临时决定
  --save-model      把本次解析到的模型写进会话仓库 <root>/<session>/repo/model
  --quiet           只打印 PROMPT/POINTER/MODEL，不打印 prompt 内容
EOF
  exit "${1:-3}"
}

TASK="" ALLOW="" IMPORT="" TESTS="" ROOT="${PWD}" BRIEF="" MODEL="" SAVE_MODEL=0 ALLOW_NO_TESTS=0 QUIET=0 CLEAR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --task)        TASK="${2:-}"; shift 2 ;;
    --allow)       ALLOW="${2:-}"; shift 2 ;;
    --import)      IMPORT="${2:-}"; shift 2 ;;
    --tests)       TESTS="${2:-}"; shift 2 ;;
    --root)        ROOT="${2:-}"; shift 2 ;;
    --allow-no-tests) ALLOW_NO_TESTS=1; shift ;;
    --brief)          BRIEF="${2:-}"; shift 2 ;;
    --model)         MODEL="${2:-}"; shift 2 ;;
    --save-model)    SAVE_MODEL=1; shift ;;
    --clear)         CLEAR="${2:-}"; shift 2 ;;
    --quiet)         QUIET=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

die() { echo "preflight: $*" >&2; exit 3; }

# 统一用绝对路径：相对 --root 会让 REPO/输出路径在 cd 后失真。
ROOT=$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$ROOT") \
  || die "无法解析根目录: $ROOT"

version_ge() {  # version_ge A B —— A >= B 时为真；按数字段逐段比较，缺段补 0
  local -a a b
  local i x y n
  a=($(printf '%s' "$1" | grep -oE '[0-9]+'))
  b=($(printf '%s' "$2" | grep -oE '[0-9]+'))
  n=${#a[@]}; (( ${#b[@]} > n )) && n=${#b[@]}
  (( n > 0 )) || return 1
  for (( i=0; i<n; i++ )); do
    x=${a[i]:-0}; y=${b[i]:-0}
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

hash_stdin() { git hash-object --stdin; }
hash_source() {  # 文件或目录的内容哈希；目录只算「相对路径 + 文件内容」，与 mtime/mode 无关
  if [ -d "$1" ]; then
    ( cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r _f; do
        printf '%s\t%s\n' "$_f" "$(hash_file "$_f")"
      done ) | hash_stdin
  else hash_file "$1"; fi
}   # 内容哈希：git 已在前提内，免去 sha256sum
hash_file()  { git hash-object -- "$1"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # POSIX date，BSD/GNU 通用


[ -n "$TASK" ] || { echo "preflight: 必须指定 --task" >&2; usage; }

[ -n "${DSH_SESSION_ID:-}" ] || die "DSH_SESSION_ID 未设置；本技能必须在 DSH 会话里运行"
case "$DSH_SESSION_ID" in *[!A-Za-z0-9._-]*) die "DSH_SESSION_ID 含不允许的字符（只允许字母、数字、点、下划线、连字符）: $DSH_SESSION_ID" ;; esac
SESSION="$DSH_SESSION_ID"
SESS_DIR="$ROOT/$SESSION"
REPO="$SESS_DIR/repo"
IMPORTS="$REPO/tasks/imports.tsv"
TDIR="$REPO/tasks/$TASK"        # 任务产物与源码同仓

# 模型解析顺序：--model > 会话仓库根的 model（--save-model 的唯一落盘点）
resolve_model() {
  [ -n "$MODEL" ] && return 0
  if [ -f "$REPO/model" ]; then MODEL=$(head -1 "$REPO/model" | tr -d '[:space:]'); fi
  return 0
}
resolve_model
[ -n "$MODEL" ] || die "未指定子代理模型：用 --model <provider/model> 指定，或先 --model … --save-model 落盘。"

[ -n "$ALLOW" ] || die "--allow 不能为空。白名单是硬约束，不允许默认全量。"

# 白名单规范化：去空白、前导 ./、尾随 /。git diff 给出的是仓库相对路径，
# 绝对路径永远匹配不上，必须当场拒绝而不是留到 postflight 判成越界。
IFS=',' read -ra _allow_raw <<< "$ALLOW"
ALLOW=""
for _a in "${_allow_raw[@]}"; do
  _a="${_a#"${_a%%[![:space:]]*}"}"; _a="${_a%"${_a##*[![:space:]]}"}"
  while [ "${_a#./}" != "$_a" ]; do _a="${_a#./}"; done
  _a="${_a%/}"
  [ -z "$_a" ] && continue
  case "$_a" in
    /*) die "--allow 只接受仓库内相对路径（不要以 / 开头）: $_a" ;;
  esac
  ALLOW="${ALLOW:+$ALLOW,}$_a"
done
[ -n "$ALLOW" ] || die "--allow 不能为空。白名单是硬约束，不允许默认全量。"

# 任务 id 只允许安全字符，因为它进入路径
case "$TASK" in
  *[!A-Za-z0-9._-]*) die "任务 id 只允许字母数字与 . _ -，实际: $TASK" ;;
esac


# 前置条件：本技能全部机制都依赖 git 与可写目录，缺任一项立即给出明确原因
command -v git >/dev/null 2>&1 || die "git 不可用（PATH 中找不到）。本技能无法工作，先跑 doctor.sh。"
GV=$(git --version 2>/dev/null); GV=${GV#git version }
version_ge "$GV" 2.28 || die "git 版本过低: ${GV:-未知}，需要 >= 2.28。先跑 doctor.sh。"

# ---- 简报：先校验，再落盘（校验失败不留任何状态）----
SRC_BRIEF="$BRIEF"
[ -n "$SRC_BRIEF" ] || SRC_BRIEF="$TDIR/brief.md"
[ -f "$SRC_BRIEF" ] || die "缺少简报: $SRC_BRIEF。首次任务请用 --brief 指定简报路径（含验收命令/白名单/交付要求）。"
if [ -z "$TESTS" ]; then
  [ "$ALLOW_NO_TESTS" -eq 1 ] || die "缺少 --tests。行为类交付必须有验收命令；评审/文档类请显式 --allow-no-tests 并在简报写明人工核对方式。"
  grep -qE "人工核对|manual review" "$SRC_BRIEF" || die "使用 --allow-no-tests 时，简报必须写明人工核对方式（例如「人工核对」）。"
elif ! grep -qF -- "$TESTS" "$SRC_BRIEF"; then
  die "简报未逐字节包含 --tests 的值「$TESTS」（含空格与引号）。请把命令原样贴进简报；多行命令先连成一行（用 ; 或去掉 \\ 折行）再贴。"
fi
grep -qF -- "提交" "$SRC_BRIEF" || die "简报未写明提交要求（交付必须已提交），拒绝派发。"
grep -qE "白名单|只允许改动|允许改动" "$SRC_BRIEF" || die "简报未写明允许改动的范围，拒绝派发。"

# 导入路径一次校验完（绝对路径、..、存在性）：这些都必须发生在建目录之前，
# 否则被拒的派发会在会话目录或仓库里留下未跟踪的残缺状态。
IMPORT_ITEMS=()
if [ -n "$IMPORT" ]; then
  IFS=',' read -ra _items <<< "$IMPORT"
  for _it in "${_items[@]}"; do
    _it="${_it#"${_it%%[![:space:]]*}"}"; _it="${_it%"${_it##*[![:space:]]}"}"
    _it="${_it#./}"
    [ -z "$_it" ] && continue
    case "$_it" in
      /*) die "导入路径必须是相对当前目录的路径（不要以 / 开头）: $_it" ;;
      ..|../*|*/..|*/../*) die "导入路径不能含「..」: $_it" ;;
    esac
    [ -e "$_it" ] || die "导入源不存在: $_it"
    IMPORT_ITEMS+=("$_it")
  done
fi

mkdir -p "$SESS_DIR" 2>/dev/null || die "无法创建会话目录: $SESS_DIR（权限或路径问题）。先跑 doctor.sh。"

# 让外层 git 仓库看不见这个目录。优先写 git 的本地忽略文件 .git/info/exclude：
# 它不进版本控制、不会让 git status 变脏，也不会动用户的 .gitignore。
TOP=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$TOP" ]; then
  REL=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$SESS_DIR" "$TOP" 2>/dev/null || true)
  if [ -n "$REL" ]; then
    PAT="/$REL/"
    EXCL=$(git -C "$TOP" rev-parse --git-path info/exclude 2>/dev/null || true)
    case "$EXCL" in
      "") ;;
      /*) ;;
      *) EXCL="$TOP/$EXCL" ;;
    esac
    if [ -n "$EXCL" ] && [ -f "$EXCL" ] && ! grep -qxF "$PAT" "$EXCL" 2>/dev/null; then
      [ -n "$(tail -c 1 "$EXCL" 2>/dev/null)" ] && printf '\n' >> "$EXCL" 2>/dev/null
      printf '# subagent-delegation session workspaces\n%s\n' "$PAT" >> "$EXCL" 2>/dev/null || true
    fi
    # 兜底：本地忽略没写成（或不在 git 仓库可写范围）时，用会话目录内的 *
    if ! grep -qxF "$PAT" "$EXCL" 2>/dev/null; then
      printf '*\n' > "$SESS_DIR/.gitignore" 2>/dev/null || true
    fi
  fi
fi

CREATED=0
if [ -f "$REPO/.git" ]; then
  die "会话仓库 $REPO 是 git 工作树（.git 是文件）：丢弃时的 reset --hard 会影响到外层仓库。请换一个独立目录当工作区。"
fi
if [ ! -d "$REPO/.git" ]; then
  # .git 不见了但目录里已有运行态产物：这是损坏的会话仓库，不能当新仓库重建（会覆盖历史）
  if [ -d "$REPO/tasks" ] || [ -f "$REPO/model" ]; then
    die "会话仓库 $REPO 缺少 .git，但已有 tasks/ 或 model：拒绝重建（历史会丢）。请人工检查后清理该目录。"
  fi
  CREATED=1
  mkdir -p "$REPO"
else
  # 复用仓库：先确认树干净，否则 BASE 不等于子代理实际看到的树
  DIRTY=$(git -C "$REPO" status --porcelain)
  if [ -n "$DIRTY" ]; then
    echo "preflight: 工作树不干净，拒绝派发（BASE 将不等于实际树）。脏文件：" >&2
    printf '%s\n' "$DIRTY" >&2
    echo "preflight: 先提交/清理。" >&2
    exit 3
  fi
fi

# 仓库不存在时现在才初始化（此前只做了只读校验）
if [ "$CREATED" -eq 1 ]; then
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name  "subagent-delegation"
  git -C "$REPO" config user.email "subagent-delegation@localhost"
  printf '%s\n' '__pycache__/' '*.pyc' '.pytest_cache/' '.venv/' \
    'tasks/*/dispatch.env' 'tasks/*/dispatch.prompt' 'tasks/*/test.log' 'tasks/*/tmp/' \
    > "$REPO/.gitignore"
fi

# 非 ASCII 路径在 git diff/status 里保持原样，否则白名单比对会误判越界
git -C "$REPO" config core.quotepath false 2>/dev/null || true

# 单分支线性历史：先回到 main，再写 plan 提交；不能先提交再切分支。
CUR=$(git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null || echo "")
case "$CUR" in
  main) ;;
  "") die "会话仓库不在分支上（detached HEAD），无法继续" ;;
  *)  git -C "$REPO" switch -q main 2>/dev/null \
        || die "会话仓库不在 main 分支（当前 $CUR），无法继续" ;;
esac

# --clear 的语法校验必须是纯字符串的，且放在建目录之前：被拒的派发不能在仓库里留下未跟踪的 tasks/<task>/
_clear_paths=()
if [ -n "$CLEAR" ] && [ "$CREATED" -eq 0 ]; then
  IFS=',' read -ra _clear_items <<< "$CLEAR"
  for _c in "${_clear_items[@]}"; do
    _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
    while [ "${_c#./}" != "$_c" ]; do _c="${_c#./}"; done
    _c="${_c%/}"
    [ -z "$_c" ] && continue
    case "$_c" in
      /*) die "--clear 只接受仓库内相对路径（不要以 / 开头）: $_c" ;;
    esac
    case "/$_c/" in
      */../*) die "--clear 不接受包含 .. 的路径: $_c" ;;
    esac
    case "$_c" in
      tasks|tasks/*|.git|.git/*) die "--clear 不能清理审计目录: $_c" ;;
      model) die "--clear 不能清理会话仓库的 model 配置（它会作为下一轮的模型来源）: $_c" ;;
    esac
    _clear_paths+=("$_c")
  done
fi

# 建任务目录放在分支校验之后：校验失败时不能在仓库里留下未跟踪的 tasks/，否则下一次会被脏树拦下
mkdir -p "$TDIR" "$SESS_DIR/reviews" 2>/dev/null || die "无法创建任务目录: $TDIR"
if [ "$SRC_BRIEF" != "$TDIR/brief.md" ]; then cp "$SRC_BRIEF" "$TDIR/brief.md"; fi
BRIEF="$TDIR/brief.md"

: > "$TDIR/provenance.tsv"
printf 'source\tcontentHash\timported_at\n' >> "$TDIR/provenance.tsv"

ADDED=()
if [ "${#IMPORT_ITEMS[@]}" -gt 0 ]; then
  for it in "${IMPORT_ITEMS[@]}"; do
    cur=$(hash_source "$it")
    if [ -e "$REPO/$it" ]; then
      if [ "$CREATED" -eq 0 ]; then
        old=$(P="$it" awk -F'\t' '$1==ENVIRON["P"]{print $2}' "$IMPORTS" 2>/dev/null | tail -1)
        if [ -n "$old" ] && [ "$old" != "$cur" ]; then
          echo "preflight: 警告 —— 源 $it 已变（与上次导入不同），仓库内仍是旧版本" >&2
        else
          echo "preflight: 跳过已存在的导入路径 $it" >&2
        fi
      fi
      # 跳过的导入也要记一行：provenance 是「本次任务用了哪些导入」的账，不是「这次复制了什么」
      printf '%s\t%s\t%s\n' "$it" "$(hash_source "$REPO/$it")" "$(now_utc)" >> "$TDIR/provenance.tsv"
      continue
    fi
    mkdir -p "$REPO/$(dirname "$it")" || die "无法创建导入目录: $it"
    cp -a "$it" "$REPO/$it" || die "导入失败: $it"
    printf '%s\t%s\t%s\n' "$it" "$cur" "$(now_utc)" >> "$TDIR/provenance.tsv"
    if [ -f "$IMPORTS" ]; then
      P="$it" awk -F'\t' '$1!=ENVIRON["P"]' "$IMPORTS" > "$IMPORTS.tmp"
    else
      : > "$IMPORTS.tmp"
    fi
    printf '%s\t%s\t%s\n' "$it" "$cur" "$(now_utc)" >> "$IMPORTS.tmp"
    mv "$IMPORTS.tmp" "$IMPORTS"
    ADDED+=("$it")
  done
fi

if [ "$CREATED" -eq 1 ]; then
  git -C "$REPO" commit -q --allow-empty -m "session init ($SESSION)"
  echo "preflight: 已创建会话仓库 $REPO（分支 main）" >&2
  # 工作区若在别的 git 仓库内，确认会话目录没有污染它的 git status
  if TOP=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null); then
    REL=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$SESS_DIR" "$TOP" 2>/dev/null || true)
    if [ -n "$REL" ] && [ -n "$(git -C "$TOP" status --porcelain --untracked-files=all -- "$REL" 2>/dev/null)" ]; then
      echo "preflight: 工作区在 git 仓库内（$TOP），且 $REL 仍出现在 git status 里；建议把 $REL/ 加进 .gitignore" >&2
    fi
  fi
fi

# 上一轮交付物（如评审的 findings.md）：删除并入 plan 提交，使 BASE 不再包含它。
# 白名单只约束写，不约束读；清掉工作树副本挡的是顺手读到，git 历史里仍有原文。
CLEARED=""
if [ -n "$CLEAR" ]; then
  if [ "$CREATED" -eq 1 ]; then
    echo "preflight: 提示 —— 新建的会话仓库没有可清理的交付物，忽略 --clear" >&2
  else
    _kept=()
    for _c in "${_clear_paths[@]}"; do
      if [ -z "$(git -C "$REPO" ls-files -- "$_c" 2>/dev/null)" ]; then
        # 上一轮被丢弃（reject/fail）时交付物已经不在了：跳过即可，否则多轮评审第二轮就派不出去
        echo "preflight: 提示 —— $_c 不在仓库里（上一轮没留下它），跳过清理" >&2
        continue
      fi
      _kept+=("$_c")
    done
    if [ "${#_kept[@]}" -eq 0 ]; then
      echo "preflight: 提示 —— --clear 没有可清理的路径" >&2
    else
      git -C "$REPO" rm -r -q -- "${_kept[@]}" || die "清理失败: $CLEAR"
      CLEARED=$(IFS=,; printf '%s' "${_kept[*]}")
      echo "preflight: 已清理上一轮交付物: $CLEARED" >&2
    fi
  fi
fi

# 只提交本次任务产物与导入，不把工作树其他文件写进 plan 提交。
git -C "$REPO" add -A -- tasks
[ "$CREATED" -eq 1 ] && git -C "$REPO" add -- .gitignore 2>/dev/null || true
if [ "${#ADDED[@]}" -gt 0 ]; then
  git -C "$REPO" add -- "${ADDED[@]}" 2>/dev/null || true
fi
if ! git -C "$REPO" diff --cached --quiet; then
  git -C "$REPO" commit -q \
    -m "task $TASK: plan (brief=$(hash_file "$BRIEF"))"
fi

# 模型落盘：写进会话仓库并提交，先于 BASE
if [ "$SAVE_MODEL" -eq 1 ]; then
  printf '%s\n' "$MODEL" > "$REPO/model"
  git -C "$REPO" add model
  git -C "$REPO" diff --cached --quiet || git -C "$REPO" commit -q -m "model=$MODEL"
  echo "preflight: 已写入会话配置 $REPO/model = $MODEL" >&2
fi
resolve_model

BASE=$(git -C "$REPO" rev-parse HEAD)

# 白名单里的路径不存在时给出警告（新建文件的任务属正常）
IFS=',' read -ra allow_items <<< "$ALLOW"
for a in "${allow_items[@]}"; do
  a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
  a="${a%/}"
  [ -z "$a" ] && continue
  [ -e "$REPO/$a" ] || echo "preflight: 提示 —— 白名单路径在仓库中尚不存在: $a" >&2
done

{
  printf 'TASK=%q\n'    "$TASK"
  printf 'SESSION=%q\n' "$SESSION"
  printf 'REPO=%q\n'    "$REPO"
  printf 'TDIR=%q\n'    "$TDIR"
  printf 'BASE=%q\n'    "$BASE"
  printf 'ALLOW=%q\n'   "$ALLOW"
  printf 'TESTS=%q\n'   "$TESTS"
  printf 'MODEL=%q\n'   "$MODEL"
  printf 'CREATED=%q\n' "$(now_utc)"
  [ -n "$CLEARED" ] && printf 'CLEARED=%q\n' "$CLEARED"
} > "$TDIR/dispatch.env"

# ---- 指针式派发 prompt：只给引用，不复述规格 ----
PROMPT_FILE="$TDIR/dispatch.prompt"
{
  printf '仓库 %s（cwd 已给，直接在 main 上提交，勿切分支）· BASE %s\n' "$REPO" "$BASE"
  printf '白名单（路径按原样，逗号分隔；权威值见 dispatch.env 的 ALLOW=）：\n'
  IFS=',' read -ra _prompt_allow <<< "$ALLOW"
  for _pe in "${_prompt_allow[@]}"; do
    _pe="${_pe#"${_pe%%[![:space:]]*}"}"; _pe="${_pe%"${_pe##*[![:space:]]}"}"
    [ -n "$_pe" ] && printf '  - %s\n' "$_pe"
  done
  printf '先读简报：%s\n' "$BRIEF"
  printf '交付：提交 + 回报 stop（completed / 未完成原因）\n'
} > "$PROMPT_FILE"

if [ "$QUIET" -eq 1 ]; then
  printf 'PROMPT=%s\n' "$PROMPT_FILE"
  printf 'POINTER=读 %s 并按其执行\n' "$PROMPT_FILE"
  if [ -n "$MODEL" ]; then printf 'MODEL=%s\n' "$MODEL"; fi
else
  printf '\n──────── 派发 prompt（已写入 %s，复制即用）────────\n' "$PROMPT_FILE"
  cat "$PROMPT_FILE"
  printf '────────────────────────────────────────\n\n'
fi

