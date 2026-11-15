#!/usr/bin/env bash
# doctor.sh — 检查本技能赖以成立的前置条件：git 可用、工作区可读写、依赖命令齐全。
# 这些条件不满足时，preflight/postflight 会以令人困惑的方式失败，所以先单独体检。
set -uo pipefail

usage() {
  cat <<'EOF'
用法: doctor.sh [--root <任务根目录>] [--src <路径[,路径...]>]

检查项：
  git 是否可用、版本是否 >= 2.23（需要 git switch）
  依赖命令：sed grep cp tar date tr dirname basename head tail
  （以上均为 POSIX 基本工具；内容哈希改用 git hash-object，无需外部哈希工具）
  任务根目录是否可创建、可写
  --src 列出的源路径是否可读

退出码：0 全部通过 / 3 存在不满足项
EOF
  exit 3
}

ROOT="${PWD}/.tasks"
SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --src)  SRC="${2:-}";  shift 2 ;;
    -h|--help) usage ;;
    *) echo "doctor: 未知参数 $1" >&2; usage ;;
  esac
done


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

FAIL=0
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1" >&2; FAIL=1; }

echo "──── doctor ────"

# 1. git 可用性与版本
if ! command -v git >/dev/null 2>&1; then
  bad "git 不可用（PATH 中找不到）—— 本技能无法工作"
else
  V=$(git --version 2>/dev/null); V=${V#git version }
  if version_ge "$V" 2.23; then
    ok "git $V（>= 2.23，支持 git switch）"
  else
    bad "git 版本过低: ${V:-未知}，需要 >= 2.23（git switch）"
  fi
fi

# 2. 依赖命令
MISSING=""
for c in sed grep cp tar date tr dirname basename head tail; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -z "$MISSING" ]; then ok "依赖命令齐全（POSIX 基本工具，Windows 下由 Git Bash 提供）"
else bad "缺少依赖命令:$MISSING"; fi

# 3. 任务根目录可创建、可写
PROBE_DIR="$ROOT/.doctor-$$"
if mkdir -p "$PROBE_DIR" 2>/dev/null; then
  if : > "$PROBE_DIR/w" 2>/dev/null; then
    ok "任务根目录可写: $ROOT"
  else
    bad "任务根目录不可写: $ROOT"
  fi
  rm -rf "$PROBE_DIR" 2>/dev/null
else
  bad "任务根目录无法创建（权限或路径问题）: $ROOT"
fi

# 4. 源路径可读
if [ -n "$SRC" ]; then
  local_ok=1
  IFS=',' read -ra items <<< "$SRC"
  for it in "${items[@]}"; do
    it="${it#./}"
    [ -z "$it" ] && continue
    if [ -r "$it" ]; then ok "源路径可读: $it"; else bad "源路径不可读: $it"; local_ok=0; fi
  done
  [ "$local_ok" -eq 1 ] || true
fi

echo "────────────────"

if [ "$FAIL" -ne 0 ]; then
  echo "doctor: 前置条件不满足。这不是模型问题——先修环境，再谈派发。" >&2
  exit 3
fi
echo "doctor: 前置条件全部满足"
exit 0
