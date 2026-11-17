# 简报：ranges-1118

## 目标

让 `demo/ranges.py` 中的 `merge_ranges(intervals)` 按下方验收测试的期望工作：合并重叠或相邻的闭区间，返回按起点升序的新列表；空输入返回空列表；任一线间 `start > end` 抛 `ValueError`。

## 范围

- 白名单：只允许改动 `demo/ranges.py`
- 不得触碰：`demo/test_merge.py`（已冻结的验收测试）、`.git/`、本简报、其他任何文件
- 新增文件仅限：无

## 验收

```bash
python3 demo/test_merge.py
```

通过标准：命令退出码为 0。测试文件在派发时已冻结，修改它即视为违规。

## 禁止

- `git amend` / `reset` / `rebase` / `stash` / `worktree` / `push`
- 修改白名单外任何文件
- 以「测试通过」以外的理由宣称完成

## 交付

1. 改动**提交**到当前分支 `main`（工作树必须干净，`git status` 为空）
2. 完整测试输出写入 `tasks/ranges-1118/test.log`
3. 回报一行 stop 结论：`completed` 或未完成的具体原因

## 备注

返回值必须是 `list[tuple]`，不要返回 list of list 或生成器；不要修改测试。
