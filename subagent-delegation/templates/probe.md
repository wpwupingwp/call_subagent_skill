# Probe 简报：验证子代理的**行为**是否适合本流程

> 本 probe 只测行为，不测环境。

## 任务

1. 新建文件 `probe.txt`，内容为一行：`ok`
2. **提交**到 `main`（不要新建或切换分支），提交信息任意

## 硬性要求

- 只允许改动 `probe.txt`，不得新建或修改其他任何文件
- 必须提交（`git status` 必须为空）
- 不得执行 `amend` / `reset` / `rebase` / `stash` / `worktree`
- 不需要、也不得调用任何解释器或外部依赖

## 通过标准

`postflight` 判定为 `pass`。验收命令用 `test -f probe.txt`。
