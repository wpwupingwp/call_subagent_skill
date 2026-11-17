# git-task-bus

用 git 仓库作为父代理与子代理之间的协作介质。父代理冻结 `BASE` 与路径白名单，
子代理直接在 `main` 上工作并提交（单分支线性历史，不建任务分支），
父代理用 diff、路径核对与测试退出码做机械验收，产出 patch 与 `MANIFEST.json`。

给**人**看的说明。给模型看的规范在同目录的 `git-task-bus/SKILL.md`。

## 安装

技能本体在 `git-task-bus/`。二选一：

```bash
# 仅本工作区可用
cp -r git-task-bus <workspace>/.dsh/skills/

# 本机所有会话可用（会影响全局 catalog，按需选择）
cp -r git-task-bus ~/.dsh/skills/
```

放好后模型会按 `description` 自动匹配并按需加载。

**未安装时 `skill` 工具调用里不会出现这个技能**——那是预期行为，不是缺陷。此时模型只能直接读
`git-task-bus/SKILL.md`，并把文档里的 `<本技能目录>` 换成该仓库的实际路径。

## 结构

```
git-task-bus/SKILL.md            规范与流程（模型读这个）
git-task-bus/references/probe.md 三层探测：首次换环境/换模型时读
git-task-bus/scripts/            doctor / envcheck / preflight / postflight
git-task-bus/templates/          brief / probe / review
usage_of.sh                      读取子代理会话用量（环境相关）
usage_stats.sh                   汇总消耗记录（不属于技能本体）
subagent_test.md                 实测记录与设计决策
tests/run.sh                     自检（56 项断言，不需要网络或子代理）
```

**产出归属**：子代理改的是仓库里的源码（白名单内）；`tasks/<task>/` 是父代理的文书（简报、MANIFEST、patch），子代理只读不写。

## 前提

| 前提 | 要求 | 缺了会怎样 |
|---|---|---|
| **git** | 可执行，版本 >= 2.23（需要 `git switch`） | 无法建仓、切换回 main、diff、patch |
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

可用模型由 profile 的 `allowedModels` 决定。首次使用时由父代理列出候选、**询问用户选哪个**，然后用 `--save-model` 落盘：

```bash
preflight.sh ... --model llama/LLaMA --save-model
```

选择写入**会话仓库** `<工作区>/<会话 id>/repo/model` 并提交一次。之后 `preflight` 自动读取它，`--model` 可省略。

解析顺序：`--model` > 会话仓库内的 `repo/model` > `<工作区>/model`。

**影响范围**：不同对话各用各的 `<session>/repo`；不写 `~/.dsh`、不改 profile、不设环境变量；用 `--root` 指定别的目录则完全隔离。
一个对话只有一个仓库，从 `session init` 到每个任务的提交连成一条线性历史；任务不另建仓库或分支。
任务产物（简报、MANIFEST、patch）也在同一个仓库的 `tasks/<task>/` 下，随历史版本化。

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

## 记录子代理消耗（可选）

`postflight --usage 'steps=12,in=2689,out=1926,cache=143545'` 会把一行追加到 `tasks/usage.tsv`，并随结果提交：

```
time  task  model  verdict  steps  in  out  cache
```

**skill 不负责采集这些数字**：子代理的 token 用量怎么拿，取决于运行环境（会话日志、API 返回、网关统计等），不属于本技能职责。父代理在调用时把已知值传进来即可；不传就完全不记录，也没有额外开销。

### 自动读取（本环境可用）

子代理的用量就在磁盘上的会话日志里，`usage_of.sh` 能直接读出来：

```bash
postflight.sh --task t1 --stop completed --child auto
```

`auto` 会按子代理会话头里的 `parentSession`（等于本会话 id）与创建时间，自动匹配本次派发产生的那个子会话；
匹配成功则 `MANIFEST.json` 记录真实 id 并自动读用量。也可以直接给 id：

```bash
postflight.sh --task t1 --stop completed --child <子代理 session id>
```

**一个 task 通常对应一次派发，但失败重派会产生新的 child 会话。** `usage.tsv` 按每次 postflight
调用逐行记录，所以同一个 task 可能出现多行——那正是重派的历史，不是重复计数。

`--child` 做两件事：把 id 记进 `MANIFEST.json`（字段 `childSession`），并**尽力从会话日志读取用量**
追加到 `tasks/usage.tsv`。读取失败（换环境、没有日志、没有 zstd）时只警告、不记录，不影响判定。

需要覆盖时显式给数字：

```bash
--usage 'steps=11,in=2231,out=1794,cache=122922'
```

> 读取逻辑依赖 DSH 的会话目录（`$DSH_HOME/sessions`）与 zstd。这是**唯一一处环境相关**的代码，
> 因此写成“尽力而为”：读不到就跳过，技能在没有这些日志的环境里仍能正常工作。脚本输出形如
`steps=11,in=2231,out=1794,cache=122922`，正好是 `--usage` 接受的格式。

它**依赖 DSH 的会话目录与 zstd 解压**，所以放在技能之外——技能本身只接受一个字符串，不关心它从哪来。
换个运行环境（没有这些日志）时，手工传数字或跳过即可。

### 汇总

```bash
./usage_stats.sh --root <工作区>          # 自动发现 */repo/tasks/usage.tsv
./usage_stats.sh a.tsv b.tsv             # 或直接给文件
```

输出任务数、总步数、in/out/cache 与加权成本（`in + 4*out + 0.02*cache`，推理按输出计），并按模型分组。

传参本身约 20 tokens；**贵的是取数**（读会话日志、跑统计，一次工具调用 200–400 tokens）。所以统计适合攒几轮做一次，而不是每个任务都做。

## 测试与成本记录

见 `subagent_test.md`：各轮实测 token、方差、缓存成本、以及 9 条设计决策记录。

## 自检

```bash
bash tests/run.sh            # 56 项断言
bash tests/run.sh --keep     # 保留临时目录以便排查
SKIP_USAGE_TESTS=1 bash tests/run.sh   # 没有 zstd 时只跑 33 项
```

覆盖：建仓与提交、越界拒绝、测试失败回滚、历史改写检测、丢弃与归档、简报校验、
最小模式、可移植性、`--child auto` 与用量记录、`--stop` 默认值、重跑守卫、patch 路径。

## 开发统计（本仓库自身）

截至提交 `25dee4c`，本次开发与验证是在**同一个父会话**里完成的：

| 项 | 值 |
|---|---|
| 父模型 | `deepseek-official/deepseek-flash` |
| 轮次 | 163 轮 |
| 步数 | 684 步 |
| 未缓存输入 | 914,242 tok |
| 缓存读取 | 254,908,032 tok |
| 输出 | 637,025 tok |
| 合计 | 256,459,299 tok |
| **缓存命中率** | **99.64%** |
| 加权成本（输入 1 / 缓存 0.02 / 输出 4） | **8,560,503** |

### 这组数字说明什么

1. **99.64% 的 token 是缓存读**，即 684 步里每一步都在重读同一段不断变长的上下文。
   平均每步重读约 **372,672 tok**，而每步新增输入只有约 1,337 tok。
2. **真正的创作量**是输出 637,025 tok（推理 + 代码 + 命令），换算成加权占 **30%**。
3. 这是**造工具与做实验的成本**，不是使用 skill 的成本。用它来评估 skill 的收益会得出
   “省 0.1%”的错误结论——因为对话本身不是任务执行。

### 对使用者的意义

- 如果你只是想用这个 skill，**不需要为这 800 万付费**；
- 它反映的是：**长会话里，成本主要由上下文重读驱动，而不是由你写了多少字驱动**；
- 这也解释了为什么 skill 的价值必须按“多次任务”评估——单次任务的收益会被这段固定上下文淹没。

