#!/usr/bin/env bash
# envcheck.sh — 环境自检：由父代理直接执行，验证任务所需命令"能否运行"。
# 与子代理无关：子代理与父代理同 uid、同文件系统、同环境变量，因此这里的结果即它的结果。
set -uo pipefail

usage() {
  cat <<'EOF'
用法: envcheck.sh --tests '<命令>' [--cwd <目录>]

退出码：
  0  命令可执行（退出码为 0）
  1  命令可执行但基线是红的（退出码非 0，且不是命令缺失）
  3  环境缺失：命令不存在 / 无执行权限 / 目录不可用
EOF
  exit 3
}

TESTS="" CWD="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --tests) TESTS="${2:-}"; shift 2 ;;
    --cwd)   CWD="${2:-}";   shift 2 ;;
    -h|--help) usage ;;
    *) echo "envcheck: 未知参数 $1" >&2; usage ;;
  esac
done

[ -n "$TESTS" ] || { echo "envcheck: 必须指定 --tests" >&2; usage; }
[ -d "$CWD" ] || { echo "envcheck: 目录不存在: $CWD" >&2; exit 3; }

cd "$CWD" || exit 3

# 直接执行，用 126/127 区分"命令缺失"与"测试失败"。
# 不预检首个词：`PYTHONPATH=. python3 x.py` 这类带环境变量前缀的命令会把首个词误当成命令。
bash -c "$TESTS" >/tmp/envcheck.$$.log 2>&1
RC=$?
tail -20 /tmp/envcheck.$$.log
rm -f /tmp/envcheck.$$.log

case "$RC" in
  0)   echo "envcheck: OK —— 命令可执行且基线为绿"; exit 0 ;;
  126|127)
    CMD_WORD=$(printf '%s\n' "$TESTS" | awk '{for(i=1;i<=NF;i++){if($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/){print $i; exit}}}')
    echo "envcheck: ENV_MISSING —— 命令不可执行（退出码 $RC，命令: ${CMD_WORD:-未知}）" >&2
    exit 3 ;;
  *)   echo "envcheck: BASELINE_RED —— 命令可执行，但基线退出码为 $RC（不一定是环境问题）" >&2; exit 1 ;;
esac
