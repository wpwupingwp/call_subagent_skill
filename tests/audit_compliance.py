#!/usr/bin/env python3
"""审计父模型：第一次派发前，有没有先在交付范围内动手。

用途：跑对照测试时判断某次会话是否"合规"。合规的定义见 SKILL.md 硬规则 7：
派发前只读，不得修改交付范围内的文件，也不得在临时副本里预先做出交付物。

用法：
  python3 tests/audit_compliance.py --session <会话日志> --scope code,static
  python3 tests/audit_compliance.py --session <日志> --scope code --json

日志可以是 .zst 压缩的会话日志，也可以是纯文本（便于构造用例）。

退出码：0 合规 / 2 存在违规 / 3 无法判定（没有派发记录等）
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

WRITE_TOOLS = {"write", "edit", "apply_patch"}
COPY_HINTS = ("cp -a", "cp -r", "rsync", "git worktree")
REDIRECT = re.compile(r">>?\s*([^\s;&|]+)")
TEE = re.compile(r"\btee\b\s+([^;&|]+)")
DEVNULL = {"/dev/null", "/dev/stdout", "/dev/stderr"}
OPS = {";", "&&", "||", "|", "&"}


def read_log(path: str) -> str:
    if not path.endswith((".zst", ".zstd")):
        return Path(path).read_text(encoding="utf-8", errors="replace")
    proc = subprocess.run(["zstd", "-dc", path], capture_output=True)
    if proc.returncode != 0:
        sys.exit(f"audit: 无法解压 {path}")
    return proc.stdout.decode("utf-8", errors="replace")


def parts(path: str) -> list[str]:
    return [p for p in re.split(r"[/\\]", path) if p not in ("", ".", "..")]


def in_scope(target: str, scopes: list[str]) -> bool:
    """目标路径的任一级目录名落在 scope 里即视为交付范围（不含文件名本身，精确匹配）。"""
    return any(p in scopes for p in parts(target)[:-1])


def _tokens(cmd: str) -> list[str]:
    try:
        return shlex.split(cmd, posix=True)
    except ValueError:
        return cmd.split()


def _args_after(tokens: list[str], name: str) -> list[str]:
    for i, tok in enumerate(tokens):
        if tok != name:
            continue
        args: list[str] = []
        for t in tokens[i + 1:]:
            if t in OPS:
                break
            args.append(t)
        return args
    return []


def _write_targets(target: str, scopes: list[str]) -> bool:
    """写入目标本身是 scope 目录，或位于 scope 目录下。"""
    return any(p in scopes for p in parts(target))


def _sed_targets(tokens: list[str]) -> list[str]:
    """sed -i 的输入文件；脚本表达式本身不算目标。"""
    targets: list[str] = []
    i = 0
    while i < len(tokens):
        if tokens[i] != "sed":
            i += 1
            continue
        j = i + 1
        inplace = False
        have_script = False
        files: list[str] = []
        while j < len(tokens):
            t = tokens[j]
            if t in OPS:
                break
            if not have_script:
                if t in ("-e", "--expression", "-f", "--file"):
                    j += 2
                    have_script = True
                    continue
                if t.startswith("-") and t != "-":
                    if t.startswith("--in-place") or (not t.startswith("--") and "i" in t[1:]):
                        inplace = True
                    j += 1
                    continue
                have_script = True
                j += 1
                continue
            files.append(t)
            j += 1
        if inplace:
            targets.extend(files)
        i = j
    return targets


def _copy_targets(args: list[str]) -> list[str]:
    for i, t in enumerate(args):
        if t == "-t" and i + 1 < len(args):
            return [args[i + 1]]
        if t.startswith("--target-directory="):
            return [t.split("=", 1)[1]]
    rest = [t for t in args if not t.startswith("-")]
    return rest[-1:] if rest else []


def bash_findings(cmd: str, scopes: list[str]) -> tuple[list[str], list[str]]:
    """返回 (违规, 警告)。只把真正写到交付范围的命令算违规。"""
    bad: list[str] = []
    warn: list[str] = []
    for m in REDIRECT.finditer(cmd):
        target = m.group(1).strip("'\"")
        if target in DEVNULL or target.startswith("&"):
            continue
        if target.startswith("$"):
            warn.append(f"重定向目标含变量，未静态判定: {target}")
            continue
        if in_scope(target, scopes):
            bad.append(f"重定向到 {target}")
    toks = _tokens(cmd)
    for target in _sed_targets(toks):
        if _write_targets(target, scopes):
            bad.append(f"sed -i {target}")
    for name in ("cp", "install"):
        for target in _copy_targets(_args_after(toks, name)):
            if _write_targets(target, scopes):
                bad.append(f"{name} 到 {target}")
    for t in _args_after(toks, "dd"):
        if t.startswith("of=") and _write_targets(t[3:], scopes):
            bad.append(f"dd 到 {t[3:]}")
    for t in _args_after(toks, "touch"):
        if not t.startswith("-") and _write_targets(t, scopes):
            bad.append(f"touch {t}")
    for m in TEE.finditer(cmd):
        for tok in re.findall(r"[^\s]+", m.group(1)):
            tok = tok.strip("'\"")
            if tok.startswith("-"):
                continue
            if any(p in scopes for p in parts(tok)):
                bad.append(f"tee 到 {tok}")
                break
    for m in re.finditer(r"\b(?:mv|rm)\b\s+([^;&|]+)", cmd):
        for tok in re.findall(r"[^\s]+", m.group(1)):
            tok = tok.strip("'\"")
            if tok.startswith("-"):
                continue
            if any(p in scopes for p in parts(tok)):
                bad.append(f"mv/rm 涉及 {tok}")
                break
    if re.search(r"write_text\s*\(|open\s*\([^)]*['\"]w", cmd):
        targets = re.findall(r"Path\(\s*['\"]([^'\"]+)['\"]\s*\)", cmd)
        targets += re.findall(r"open\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"][wa]", cmd)
        for t in targets:
            if in_scope(t, scopes):
                bad.append(f"内联脚本写 {t}")
                break
    if any(h in cmd for h in COPY_HINTS) and any(sc in cmd for sc in scopes):
        warn.append("派发前把交付范围复制到别处，可能在临时副本里预演")
    return bad, warn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True, help="会话日志路径（.zst 或纯文本）")
    ap.add_argument("--scope", required=True, help="交付范围的目录名（精确匹配），逗号分隔，例如 code,static")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出")
    args = ap.parse_args()

    scopes = [s.strip() for s in args.scope.split(",") if s.strip()]
    raw = read_log(args.session)

    steps = []
    for line in raw.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get("type") != "assistant/message":
            continue
        data = ev.get("data") or {}
        calls = []
        for block in (data.get("message") or {}).get("content", []):
            if block.get("type") != "tool-call":
                continue
            try:
                cargs = json.loads(block.get("arguments") or "{}")
            except Exception:
                cargs = {}
            calls.append((block.get("name"), cargs))
        steps.append((data.get("turn"), calls))

    dispatch_at = None
    for idx, (_, calls) in enumerate(steps):
        if any(name in ("subagent", "subagent_fork") for name, _ in calls):
            dispatch_at = idx
            break

    violations, warnings = [], []
    for idx, (turn, calls) in enumerate(steps):
        if dispatch_at is not None and idx >= dispatch_at:
            break
        for name, cargs in calls:
            if name in WRITE_TOOLS:
                target = cargs.get("file_path") or cargs.get("path") or ""
                if in_scope(str(target), scopes):
                    violations.append({"step": idx + 1, "turn": turn, "tool": name, "target": str(target)})
            elif name == "bash":
                cmd = str(cargs.get("command") or "")
                bad, warn = bash_findings(cmd, scopes)
                for why in bad:
                    violations.append({"step": idx + 1, "turn": turn, "tool": "bash",
                                       "command": cmd[:160], "reason": why})
                for why in warn:
                    warnings.append({"step": idx + 1, "turn": turn, "command": cmd[:160], "note": why})

    result = {
        "session": args.session,
        "scope": scopes,
        "dispatch_step": None if dispatch_at is None else dispatch_at + 1,
        "violations": violations,
        "warnings": warnings,
    }

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"派发步: {result['dispatch_step'] or '无'}")
        print(f"范围: {', '.join(scopes)}")
        for v in violations:
            print(f"  违规 step {v['step']}: {v.get('tool')} {v.get('target') or v.get('command', '')[:100]}")
        for w in warnings:
            print(f"  警告 step {w['step']}: {w['command'][:100]}")

    if dispatch_at is None:
        print("判定: 无派发记录，不适用", file=sys.stderr)
        return 3
    if violations:
        print("判定: 违规", file=sys.stderr)
        return 2
    print("判定: 合规", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
