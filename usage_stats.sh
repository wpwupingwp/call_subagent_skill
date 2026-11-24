#!/usr/bin/env bash
# usage_stats.sh — 汇总 subagent-delegation 的 tasks/usage.tsv
#
# 与 skill 同级，不属于技能本体：技能只负责按行记录，统计是使用方的选择。
set -u

usage() {
  cat <<'EOF'
用法: usage_stats.sh [--root <工作区>] [文件...]

  不给文件时，在 --root（默认当前目录）下查找 */repo/tasks/usage.tsv；
  默认会汇总该工作区下所有会话，只看一个会话请把 --root 指到 <工作区>/<会话 id>
  加权成本口径：未缓存输入 1、输出 4（推理按输出计）、缓存读 0.02
EOF
  exit 0
}

ROOT="$PWD"
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(
    find "$ROOT" -type f -path '*/repo/tasks/usage.tsv' 2>/dev/null | sort
  )
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "usage_stats: 没有找到 usage.tsv（用 postflight --usage 记录后才会产生）" >&2
  exit 1
fi

awk -F'\t' '
  FNR == 1 && $1 == "time" { next }          # 表头
  NF >= 8 {
    tasks++
    steps += $5; tin += $6; tout += $7; tcache += $8
    key = ($3 == "" ? "(未记录)" : $3)
    n[key]++
    i[key] += $6; o[key] += $7; c[key] += $8
  }
  END {
    if (tasks == 0) { print "usage_stats: 没有数据行" > "/dev/stderr"; exit 1 }
    printf "合计: %d 个任务, %d 步\n", tasks, steps
    printf "  in=%d  out=%d  cache=%d\n", tin, tout, tcache
    printf "  加权成本=%.0f  （in + 4*out + 0.02*cache）\n", tin + 4*tout + 0.02*tcache
    printf "\n按模型:\n"
    for (k in n) {
      printf "  %-26s 任务=%d  加权=%.0f\n", k, n[k], i[k] + 4*o[k] + 0.02*c[k]
    }
  }
' "${FILES[@]}"
