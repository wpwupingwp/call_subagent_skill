# git-task-bus

用 git 仓库作为父代理与子代理之间的协作介质。父代理冻结 `BASE` 与路径白名单，
子代理在 `work/<task>` 分支上工作并提交，父代理用 diff、路径核对与测试退出码做机械验收，
产出 patch 与 `MANIFEST.json`。

给**人**看的说明。给模型看的规范在同目录的 `skill/SKILL.md`。

## 安装

技能本体在 `skill/`。二选一：

```bash
# 仅本工作区可用
cp -r skill <workspace>/.dsh/skills/git-task-bus

# 本机所有会话可用（会影响全局 catalog，按需选择）
cp -r skill ~/.dsh/skills/git-task-bus
```

放好后模型会按 `description` 自动匹配并按需加载；也可以不安装，直接让模型读 `skill/SKILL.md`。

## 结构

```
skill/SKILL.md              规范与流程（模型读这个）
skill/references/probe.md   三层探测：首次换环境/换模型时读
skill/scripts/              doctor / envcheck / preflight / postflight
skill/templates/            brief / probe / review
subagent_test.md            实测记录与设计决策
```

## 前提

| 前提 | 要求 | 缺了会怎样 |
|---|---|---|
| **git** | 可执行，版本 >= 2.23（需要 `git switch`） | 无法建仓、分支、diff、patch |
| **可写工作区** | 能建目录、复制源文件、导出 patch | 建仓即失败 |
| **依赖命令** | `sed grep cp tar date tr dirname basename head tail` | 脚本中途报错，信息晦涩 |

脚本只允许 POSIX 基本工具：不得引入 `sort -V`、`date -Iseconds`、`sha256sum`（BSD/macOS 没有）。
内容哈希用 `git hash-object`，字段名 `contentHash`，仅用于相等性比对。

## 平台

| 平台 | 所需 | 说明 |
|---|---|---|
| Linux | bash + git + coreutils | 开箱可用 |
| macOS | 系统自带 bash 3.2 + git | 需确认 `git`（Xcode CLT）已装 |
| Windows | **Git Bash**（Git for Windows 自带）或 WSL | PowerShell / cmd 不能直接运行 |

不提供 PowerShell 版本（理由见 `subagent_test.md` 9.2）。Windows 上还有两个坑：

- **换行符**：脚本必须以 LF 保存。用 git 分发时加 `.gitattributes`（`*.sh text eol=lf`），或设 `core.autocrlf=false`。
- **路径**：Git Bash 下用 POSIX 风格（`/c/work/...`）；`--root`、`--import` 按相对路径解析，不要传 `C:\...`。

## 适用与不适用

**这个 skill 值不值得用**，取决于任务是不是“需要提交的代码改动、且能靠测试判定”。理由：

| 情形 | 为什么不要派 |
|---|---|
| 查状态、读文件、跑一条命令看输出、网络探测 | 产出是信息，没有可验收的改动；验收环节无物可验，只剩开销 |
| 改一行、改配置、加个常量 | 一次派发的固定开销（派发 + 验收 + 审查）约 500 加权单位，约等于直接跑 3–5 条命令 |
| 选型、评审、文案、架构取舍 | 验收靠判断而非测试，派出去父代理仍要重做一遍 |

反过来，只有“需要提交的代码改动，且靠反复跑测试才能收敛”时才划算——这正是本技能唯一能机械验收的场景。

规模判断只看请求措辞，不要先去看代码：单个表达式、常量、一行替换算小；新增函数、跨文件改动算需要迭代。
**从请求看不出规模时，直接自己做**——去勘察等于已经开工。

数值依据见 `subagent_test.md`；判据为什么用「请求特征」而不是「成本估算」，见该文件 9.9。

## 选模型

skill **不判断模型价格，也不代为选择**——价格信息不在它的可见范围内，让它猜只会制造一个无法验证的假设。

可用模型由 profile 的 `allowedModels` 决定，调用方用 `--model <provider/model>` 显式指定最便宜的那个：

- `--model` 会写进 `dispatch.env` 与 `MANIFEST.json`；
- `preflight --quiet` 的输出里会多一行 `MODEL=...`，派发时把它原样填进 `subagent` 的 `provider` / `model`。

推荐在 profile 里只保留确实需要的模型，每次任务显式指定。这样成本可按模型归因。

## 环境检查

| 工具 | 问的问题 | 频次 |
|---|---|---|
| `scripts/doctor.sh` | 本技能能否工作（git / 权限 / 依赖命令） | 每环境一次 |
| `scripts/envcheck.sh` | 这个任务的验收命令能否运行（解释器 / 依赖 / 基线） | 每任务一次 |
| `probe`（走一次真任务） | 子代理是否守约（提交 / 白名单 / 回合结束） | 每模型一次 |

`doctor.sh` **不检查**：磁盘剩余空间、网络、全局 git 配置（`preflight` 会在仓库内设置 `user.name`/`user.email`）、git hook 干扰。

三者不合并：`doctor` 只读探测，`envcheck` 会执行用户提供的命令（可能有副作用、可能很慢），失败语义也不同。理由见 `subagent_test.md` 9.1。

## 其他限制

- **纯产出型任务可用**：无 `--import` 时 bootstrap 走空提交，仓库从零开始。
- **子代理步数方差与编排无关**：同任务 7 次实测为 11–86 步，成本尾部由「首版是否一次写对」决定，无法通过编排消除。

## 测试与成本记录

见 `subagent_test.md`：各轮实测 token、方差、缓存成本、以及 9 条设计决策记录。
