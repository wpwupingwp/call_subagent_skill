#!/usr/bin/env python3
"""评审交付的结构验收：每条发现字段齐全，且 `路径:行号` 引用真实存在。

用法：python3 check_findings.py [findings.md]
退出码 0 通过 / 1 有问题（逐条列出）。
"""
import re
import sys
from pathlib import Path

REQUIRED = ("位置", "证据", "建议")
HEAD = re.compile(r"^##\s+F(\d+)\s*级别：\s*(高|中|低|意见)\s*$")
REF = re.compile(r"([A-Za-z0-9_./\-]+/[A-Za-z0-9_.\-]+):(\d+)(?:-(\d+))?")


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "findings.md")
    if not path.is_file():
        print(f"FAIL 找不到 {path}")
        return 1
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    heads = [(i, m) for i, m in ((i, HEAD.match(l)) for i, l in enumerate(lines)) if m]
    errors: list[str] = []
    if not heads:
        errors.append("没有任何 `## F<n> 级别：高|中|低|意见` 小节")
    nums = [int(m.group(1)) for _, m in heads]
    if nums and nums != list(range(1, len(nums) + 1)):
        errors.append(f"编号应为 1..{len(nums)} 连续：{nums}")
    for idx, (start, m) in enumerate(heads):
        end = heads[idx + 1][0] if idx + 1 < len(heads) else len(lines)
        body = "\n".join(lines[start + 1:end])
        label = f"F{m.group(1)}"
        for field in REQUIRED:
            if not re.search(rf"^\s*[-*]\s*{field}：", body, flags=re.M):
                errors.append(f"{label} 缺字段「{field}：」")
        refs = 0
        for ref in REF.finditer(body):
            file, first, last = ref.group(1), int(ref.group(2)), ref.group(3)
            refs += 1
            target = Path(file)
            if not target.is_file():
                errors.append(f"{label} 引用不存在的文件：{file}")
                continue
            total = len(target.read_text(encoding="utf-8", errors="replace").splitlines())
            hi = int(last) if last else first
            if first < 1 or hi > total:
                errors.append(f"{label} 行号越界：{file}:{first}（文件 {total} 行）")
        if refs == 0:
            errors.append(f"{label} 的「位置」里没有可核对的 `仓库相对路径:行号`")
    total_refs = len(REF.findall(text))
    if errors:
        for e in errors:
            print(f"FAIL {e}")
        return 1
    print(f"OK {len(heads)} 条发现，{total_refs} 处引用全部可解析")
    return 0


if __name__ == "__main__":
    sys.exit(main())
