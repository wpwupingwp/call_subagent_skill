# Probe 简报：验证子代理行为是否适配 git-task-bus

> 本 probe 只测行为，不测环境。环境能力由父代理用 `envcheck.sh` 单独验证。

## 任务

1. 在仓库根目录新建 `probe.txt`，内容为一行：`ok`
2. 提交到当前分支 `main`（不要新建分支、不要切分支），提交信息任意
3. 把下面命令的输出写入 `tasks/probe-1118/test.log`：
   `printf ok > /dev/null`

## 范围

- 白名单：只允许改动 `probe.txt`
- 不得新建或修改其他任何文件（`tasks/probe-1118/test.log` 是唯一例外，且已被 .gitignore 忽略）
- 不得修改 `.git/`、本简报、测试文件

## 验收

```bash
test -f probe.txt
```

通过标准：命令退出码为 0。测试文件在派发时已冻结，修改它即视为违规。

## 禁止

- `git amend` / `reset` / `rebase` / `stash` / `worktree` / `push`
- 修改白名单外任何文件
- 以「测试通过」以外的理由宣称完成

## 交付

1. 改动**提交**到 `main`（工作树必须干净，`git status` 为空）
2. 测试输出写入 `tasks/probe-1118/test.log`
3. 回报一行 stop 结论：`completed` 或未完成的具体原因
