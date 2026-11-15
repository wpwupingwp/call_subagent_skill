---
name: git-task-bus
description: 用 git 仓库作为父代理与子代理之间的协作介质：每个任务建立专属仓库，父代理冻结 BASE 与路径白名单，子代理在 work/<task> 分支工作并提交，父代理用 diff、路径核对与测试退出码做机械验收并产出 patch。当需要把编码或改文件类任务派给子代理、要求过程可归因、结果可回滚、交付可复现时使用。仅适用于一次只派一个子代理的串行任务；需要多个子代理并发协作时不适用。要求子代理模型廉价且能稳定遵守提交与白名单约定，首次使用前先跑 probe。
whenToUse: 需要派发会写文件/写代码的子任务，且希望验收不依赖子代理自述时；需要为某次对话建立可回滚、可审查的任务工作区时。不适用于并发编排（本技能无并发能力）。
---

# git-task-bus

父代理与子代理通过**同一个 git 仓库**交换信息。仓库是协作介质，不是沙箱：它承载任务上下文、分支分工、审查单元（diff）和历史记忆。

> `<本技能目录>` 指本文件所在目录。常规任务只需本文件；换环境或换模型时读 `references/probe.md`。

## 核心分工

| 角色 | 只写 | 职责 |
|---|---|---|
| 子代理 | `ALLOWED` 白名单内的路径，分支 `work/<task>` | 实现并提交 |
| 父代理 | 任务目录里的 `briefs/`、`reviews/`（不在仓库内） | 冻结 BASE、核对、验收、产出 patch |

## 约束的分工

每种机制约束的对象不同，别把它们混着记：

| 机制 | 约束谁 | 性质 | 靠什么生效 |
|---|---|---|---|
| **回合边界** | 父代理 | 流程纪律 | 派发后结束回合，不与子代理并发写 |
| **白名单 `ALLOWED`** | 子代理 | 事后判据 | `postflight` 用 `--name-only` 比对，不依赖它配合 |
| **必须已提交** | 子代理 | 交付前提 | `postflight` 只读 `BASE..HEAD`，不碰索引 |
| **只追加** | 子代理 | 可探测 | patch 副本使历史改写失去意义 |

### 白名单是判据，不是纪律

简报里的「只允许改动 X」是给子代理的**指令**——它需要配合才能生效。真正的约束在 `postflight`：把 `BASE..HEAD` 的每个文件名与白名单比对，越界即拒绝。**这一步不依赖子代理是否听话。**

### 交付必须已提交，否则自动丢弃

`postflight` 只读 `BASE..HEAD`，不执行 `git add`（那会改动被审对象的索引）。工作树脏即交付未完成，退出码 2。规则无例外：

> **判定不通过 → 自动丢弃。**

丢弃顺序不可调换：`git add -A` → 导出 patch → `git reset --hard <BASE>` → `git clean -fd` → 写 `ABANDONED`（释放路径占用）。裸手 `reset --hard` 不会保留未跟踪文件。

## 流程

### 0. 首次使用：跑一次探测

换机器、换环境、或第一次用某个子代理模型时，先按 `references/probe.md` 跑三层探测（doctor / envcheck / probe）。环境不合格时，任何编排都不会成功。

### 1. 先写测试，再写简报（父代理）

验收完全依赖测试，所以**测试由父代理先写、并在派发前冻结**：

- 测试文件用 `--import` 复制进仓库，但**不放进 `--allow`**；
- 子代理改它，`postflight` 的文件名比对就判越界、拒绝交付——冻结靠白名单，不靠嘱咐。

测试要满足两点：

- **能跑起来**：派发前 `envcheck.sh` 返回 `0` 或 `1`。基线为红是正常的（实现还不存在），只要不是 `3`（命令跑不起来）。
- **能判定需求**：断言具体行为与边界，不要只断言「不抛异常」。

简报写清四件事：目标、允许改动的范围、验收命令（与 `--tests` **完全一致**）、交付要求。

```bash
mkdir -p .tasks/<task>/briefs
$EDITOR .tasks/<task>/briefs/brief.md
```

### 2. preflight（父代理执行，一次）

```bash
SKILL=<本技能目录>
bash "$SKILL/scripts/preflight.sh" \
  --task   <task-id> \
  --import <要放进仓库的文件：源文件或测试> \
  --allow  <允许子代理改动的路径> \
  --tests  '<验收命令，与简报里的一致>' \
  --model  <provider/model> \
  --quiet
```

`--import` 把源文件复制进仓库并记录内容哈希（源不在版本控制下时用）；源本身是 git 仓库时，改用 `git worktree` 更优。

脚本会：校验简报 → 建仓、导入、提交 bootstrap（提交信息记录 `brief=<简报内容哈希>`）→ 要求工作树干净 → 记录 `BASE` → 切到 `work/<task>` → 写 `dispatch.env` 与 `dispatch.prompt`。

`--quiet` 让 stdout 只剩两行；给了 `--model` 则三行（诊断信息走 stderr）：

```
PROMPT=/path/to/.tasks/<task>/dispatch.prompt
POINTER=读 /path/to/.tasks/<task>/dispatch.prompt 并按其执行
MODEL=llama/LLaMA
```

`--model` 记录本次使用的模型（写进 `dispatch.env` 与 `MANIFEST.json`），派发时原样填进 `provider` / `model`。

**首次使用要问用户，不是替用户决定**：

1. 若能列举可用模型（例如 `list_subagent_models`），把候选交给用户选；
2. 把选择写进 `<任务根>/model`（一行，如 `llama/LLaMA`）；
3. 之后 `--model` 可省略，`preflight` 会自动读取它；显式 `--model` 仍可覆盖。

该文件在任务根目录内（默认 `<工作区>/.tasks/model`），只影响该目录下的任务，不写全局配置。

skill 不猜价格——价格不在它的可见范围内，猜就是一个无法验证的假设。

#### 简报必须通过三项机械校验

缺任一项直接退出 3，不建仓：

| 校验 | 判据 |
|---|---|
| 含验收命令 | 简报正文包含 `--tests` 的字面文本 |
| 含交付要求 | 出现「提交」 |
| 含改动范围 | 出现「白名单」或「只允许改动」 |

### 3. dispatch（父代理 → 子代理）

`subagent` 的 `prompt` 参数**只填 `POINTER` 那一行**，不要再粘贴或改写：

```
读 /path/to/.tasks/<task>/dispatch.prompt 并按其执行
```

配上 `provider` / `model` / `cwd`（`cwd` = 仓库路径）即可。子代理会自己读 `dispatch.prompt`，再顺着它读简报。

**派发后结束回合**：等待期间不写任何文件，否则与子代理并发写同一棵树。


### 4. postflight（父代理执行）

```bash
bash "$SKILL/scripts/postflight.sh" --task 2026-11-16-arg-validation --quiet
```

`--quiet` 只输出一行，用于常规验收：

```
verdict=pass changed=1 violations=0 history=no dirty=0 testexit=0 patch=<path>
```

需要细节（变更清单、越界文件、测试摘要）时去掉 `--quiet` 重跑即可——它不改变任何判定，只改变输出量。

非 quiet 模式依次产出：

- `git status` 快照（工作树脏则判交付违规，退出码 2）
- 变更文件清单与**越界违规清单**
- 测试执行结果（完整日志落盘，不占父代理上下文）
- 净 diff 生成的 patch：`deliveries/<task>.patch`
- `MANIFEST.json`：BASE、head、文件与 contentHash、测试退出码、verdict

退出码：`0` 通过 · `1` 测试失败或 stopReason 异常 · `2` 违规（越界/改写历史/未提交交付）· `3` 配置或环境错误（含 MANIFEST 生成失败）。

### 5. 验收（父代理）

- 层级 0：退出码 + 违规清单（近零成本，每次）
- 层级 1：`git diff --stat`（体量是否与需求匹配）
- 层级 2：仅在触发时读净 diff——测试红、越界、体量失衡、触及权限/并发/IO/exec、新增依赖、断言明显弱于改动
- 层级 3：安全与数据破坏类任务全量细读

**父代理必须自己重跑一次测试**：子代理的报告是自述，重跑是唯一不经过转述的事实。重跑一次，不重复跑。

不通过时任务已被自动丢弃，仓库回到 `BASE`。重派之前先看失败类型：**连续两次同类失败通常说明简报不清，应当改简报，而不是再派第三次**。

### 6. 交付

`deliveries/<task>.patch` 与 `MANIFEST.json` 交给用户，由用户合并回主树。父代理不自动回写源文件。

**父代理不在任务仓库里提交任何东西**——它的文件（简报、审查记录）都在任务目录，位于仓库之外。仓库只有一个分支 `work/<task>`，`BASE` 是它的起始提交；交付物是 patch，不是一次合并。

合并确认后在任务目录执行 `touch MERGED`，否则该任务的路径会一直占着，阻塞后续同路径任务。

验收结论写进 `reviews/<task>.md`（模板 `templates/review.md`），一行即可——下次接手的人靠它判断当时为什么放行。

## 关键判定

- **历史被改写不是“细读代码”的触发条件**，是“拒绝交付”的触发条件。patch 副本在手，重建即可。
- 真正需要细读的是“机械检查全绿但测试覆盖不到”的改动。
- `ALLOWED` 为空时脚本拒绝执行：大工作区上默认全量会变成事故。

## 目录布局

```
.tasks/<task>/
  dispatch.env          # BASE / BRANCH / ALLOW / TESTS
  dispatch.prompt       # 三行任务卡，由 POINTER 一行引用（勿粘贴正文）
  briefs/brief.md       # 规格唯一来源，preflight 校验
  reviews/              # 父代理的审查记录
  allow.txt             # 白名单原文，供重叠检测读取
  MERGED                # 已落地标记（手工创建，释放路径占用）
  ABANDONED             # 已废弃标记（postflight 判定不通过时自动写入）
  provenance.tsv        # 导入来源与 contentHash
  test.log              # 完整测试输出
  MANIFEST.json
  deliveries/<task>.patch
  repo/                 # 任务专属仓库，diff 里只有子代理的改动
```

## 环境与限制

首次使用跑 `scripts/doctor.sh`（`0` 通过 · `3` 不满足）。环境失败要报告为**环境问题**，不是模型问题。

限制：

- **一次只派一个子代理**：无并发编排，多任务串行，前一个必须先合并或废弃。
- **无任务依赖**：不能声明「B 依赖 A 的产出」，只能人工安排顺序。
- **`ALLOW` 用逗号分隔**：路径本身含逗号无法表达。

## 何时用、何时不用

**只有当任务产出需要提交的代码改动，且改动要靠反复跑测试才能收敛时，才派。** 其余一律自己做：

| 自己做的情况 |
|---|
| 查状态、读文件、跑一条命令看输出、网络探测 |
| 改一行、改配置、加个常量 |
| 选型、评审、文案、架构取舍 |

**规模只看请求的措辞，不看代码**：单个表达式、常量、一行替换算小；新增函数、跨文件改动算需要迭代。
从请求看不出规模时，自己做——去勘察等于已经开工。
