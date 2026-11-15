# git-task-bus

用 git 仓库作为父代理与子代理之间的协作介质。父代理冻结 `BASE` 与路径白名单，
子代理在 `work/<task>` 分支上工作并提交，父代理用 diff、路径核对与测试退出码做机械验收，
产出 patch 与 `MANIFEST.json`。

给**人**看的安装说明。给模型看的规范在同目录的 `SKILL.md`。

## 安装

技能本体在 `skill/`。二选一：

```bash
# 仅本工作区可用
cp -r skill <workspace>/.dsh/skills/git-task-bus

# 本机所有会话可用（会影响全局 catalog，按需选择）
cp -r skill ~/.dsh/skills/git-task-bus
```

放好后模型会按 `description` 自动匹配并按需加载；也可以不安装，直接让模型读 `SKILL.md`。

## 结构

```
skill/SKILL.md              规范与流程（模型读这个）
skill/references/probe.md   三层探测：首次换环境/换模型时读
skill/scripts/              doctor / envcheck / preflight / postflight
skill/templates/            brief / probe / review
subagent_test.md            实测记录与设计决策
```

## 前提

`git >= 2.23`、可写工作区、POSIX 基本工具。Windows 用 Git Bash 或 WSL。
首次使用先跑 `scripts/doctor.sh`，再按 `references/probe.md` 探测子代理模型。

## 测试与成本记录

不随技能分发，见工作区的 `subagent_test.md`：各轮实测 token、方差、设计决策记录。
