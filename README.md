# git-task-bus

**中文** · [English](README.en.md)

把会改文件的活派给便宜的子代理：父代理冻结 `BASE` 与路径白名单，子代理在独立的 git 仓库里
干活并提交，父代理只做机械验收（diff + 白名单 + 测试退出码），最后收下可回滚的 patch。

- 子代理读的文件、失败的尝试、测试日志都留在它自己的会话里
- 不通过就自动丢弃，仓库回到派发前，不留半成品
- 每次判定都写进 `MANIFEST.json` 和 patch，事后能复查

给**人**看的说明。给模型读的规范在 [`git-task-bus/SKILL.md`](git-task-bus/SKILL.md)。

## 安装

技能本体就是 `git-task-bus/` 目录，拷到 skills 目录即可：

```bash
cp -r git-task-bus <workspace>/.dsh/skills/   # 仅本工作区
cp -r git-task-bus ~/.dsh/skills/             # 本机所有会话（会影响全局 catalog）
```

放好后模型会按 `description` 自动匹配并使用。没有安装时，`skill` 工具里不会出现它——
这时可以直接读 `SKILL.md`，把文中的 `<本技能目录>` 换成实际路径。

## 快速开始

```bash
SKILL=/path/to/git-task-bus

# 1. 每台机器一次：确认 git、权限、依赖命令
bash "$SKILL/scripts/doctor.sh"

# 2. 写简报 tasks/t1/brief.md（目标、允许改动的范围、验收命令、交付要求）
#    写完用 "$SKILL/scripts/envcheck.sh" --tests '<命令>' 确认命令能跑：
#    0 或 1 都正常（基线红是预期的），3 表示命令根本不存在

# 3. 建仓库、冻结 BASE 与白名单
bash "$SKILL/scripts/preflight.sh" \
  --task t1 \
  --import src,test_src.py \
  --allow src \
  --tests 'python3 -m pytest -q test_src.py' \
  --model llama/LLaMA --quiet
```

```
PROMPT=.../repo/tasks/t1/dispatch.prompt
POINTER=读 .../repo/tasks/t1/dispatch.prompt 并按其执行
MODEL=llama/LLaMA
```

测试文件用 `--import` 拷进仓库，但**不要放进 `--allow`**：子代理改了它，白名单比对就会判越界。

评审/文档类如果没有可机械检查的结构，用 `--allow-no-tests` 显式声明，并在简报里写「人工核对」；
否则 `preflight` 以 exit 3 拒绝。这样“没有验收命令”会成为 MANIFEST 里可见的状态（`testsRun=false`），
而不是静默通过。

4. 把 `POINTER` 那一行原样交给子代理（`cwd` = 仓库路径），然后结束回合。
5. 子代理提交后验收：

```bash
bash "$SKILL/scripts/postflight.sh" --task t1 --child auto --quiet
# verdict=pass changed=1 violations=0 history=no dirty=0 testexit=0 patch=.../deliveries/t1.patch
```

通过就把 `deliveries/t1.patch` 合回主树；不通过时仓库已经回到 `BASE`，改动存为
`deliveries/t1.abandoned.patch` 供事后查看。

## 工作原理

![协作时序](docs/flow-zh.png)

图上一条横向箭头是一次交互，纵轴是时间。关键的三段都画出来了：父代理先向 Harness 要可用模型、
再问人用哪个，`preflight` 冻结 `BASE` 与白名单，`subagent` 派发后由 Harness 创建子会话，
子代理在 `main` 上提交，Harness 把结果与结束原因交回父代理，父代理跑 `postflight` 验收，
最后 patch 交给**人**——合并、push、丢弃都由人执行，技能不写回主树。

[交互版 HTML](docs/flow-zh.html)：自包含单文件，可在本地打开，或在仓库设置里开启 GitHub Pages 后直接访问。

每对话一个仓库，从头到尾只有 `main` 一条分支；任务不建分支，靠 `BASE` 划分。

## 目录结构

```
<工作区>/
└── <会话 id>/
    └── repo/               # 会话仓库，单分支 main
        ├── <源码>          # 子代理可改（白名单内）
        ├── model           # 会话级模型选择
        └── tasks/<task>/
            ├── brief.md        # 规格唯一来源，preflight 提交
            ├── MANIFEST.json   # 判定与证据
            └── deliveries/<task>.patch
```

工作区在别的 git 仓库内时，`preflight` 把 `/session-*/` 追加进该仓库的 `.git/info/exclude`
（工作区是子目录时是 `/子目录/session-*/`）。那是 git 的本地忽略文件：不进版本控制、不改你的
`.gitignore`、`git status` 也不会多出任何条目。`.git` 不可写时退回在会话目录里放一个 `*`。

仓库清单：

```
git-task-bus/SKILL.md        模型读的规范与流程
git-task-bus/references/     probe：首次换环境或换模型时的三层探测
git-task-bus/scripts/        doctor / envcheck / preflight / postflight
git-task-bus/templates/      brief / probe / review / findings
tests/run.sh                 自检（无需网络或子代理）
tests/audit_compliance.py    合规审计：派发前有没有先动手
usage_of.sh, usage_stats.sh  用量读取与汇总（不属于技能本体）
subagent_test.md             实测记录与设计决策
HISTORY.md                   开发史与角色记录
docs/flow-zh.png             协作时序图（中文）
docs/flow-zh.html            同一张图的交互版（自包含单文件）
README.en.md                 English version
```

## 为什么值得用

一句话：**把读代码、试错和失败日志留在子会话里，父代理只收结论，再让一个没被带偏的读者复核一遍。**

- **上下文干净**：子代理读的文件、走过的弯路、测试日志都在它自己的会话里；父代理只看
  `postflight` 的一行结论，需要时再看 `git diff --stat` 或净 diff。长会话的开销主要来自上下文
  重读，父上下文保持短小，后续每一步都更便宜。
- **独立复核**：子代理只拿到冻结的简报和 `BASE`，看不到前面的假设与结论，不会被「我们已经
  确定 X」带偏。父模型在长上下文里容易陷进思维定势，无人值守时这份复核最有用。
- **可回滚、可追溯**：`BASE..HEAD` 就是本次改动，不多不少；白名单事后比对；不通过自动丢弃；
  判定和证据落在 `MANIFEST.json` 与 patch 里，事后能复现。

代价也要算进去：父代理仍要付简报与验收的编排费（约 2,100），派发越零碎越不划算；子代理的
复核会漏，结论仍要逐条核对；「独立」是上下文独立，不是权限隔离。

## 什么时候用

四个条件同时满足才派：

1. 交付是**文件改动**（代码、数据、配置，或结构可校验的文档）；
2. 验收能**机械核对**（测试或脚本能判对错，不靠人读）；
3. 改动要靠**迭代收敛**（一次写不对，要多轮）；
4. 子代理比父代理便宜 3 倍以上（`r ≤ 0.3`）；本地部署（`r = 0`）自动满足。

| ✅ 适合 | ❌ 不适合 |
|---|---|
| 100 行以上新实现、单文件重构 | 查状态、读文件、跑一条命令 |
| 30–50 行改动，或 10 行小改攒批 | 改一行、加个常量（编排成本约 2,100） |
| 有复现测试的 bug 修复 | 选型、文案、架构取舍、调研 |
| 批量机械改动（改名、迁移、格式化） | 需要中途给方向的任务（简报冻结是前提） |
| 无人值守的批处理 | 交互式调试（串行 + 异步，来回很慢） |
| 第二意见评审（干净上下文的复核） | 评审只为省 token（结论仍要逐条核对） |
| | 需要并发（技能本身是串行的） |

**评审类**只能机械核对报告的结构与引用（字段、锚点、链接），拦不住错误结论，派发后结论仍要
父代理逐条核对；没有可检查的结构时用 `--allow-no-tests` 声明并在简报写明人工核对。
**文档/报告类**同理：可以派，但换来的是第二遍独立阅读，不是省 token。

节省幅度是外推模型的估计，不是每个场景的实测：

| 场景 | `r = 0.1`（便宜 10 倍） | `r = 0`（本地免费） |
|---|---|---|
| 100 行以上新实现 | 省 73% | 省 79% |
| 500 行级任务 | 省 64% | 省 96% |
| 30–50 行改动 | 省 35–64% | 省 44–73% |
| 10 行小改，攒批派 | 省 36% | 省 51% |
| 批量机械改动 | ✅ | ✅ |
| 评审（第二意见） | 更贵（实测 10.9–14.7 万/次） | 只付编排费 |
| 一次性脚本 | 太小则亏 | 只付编排费 |

`r` 是子代理价格与父代理价格之比。实测门槛 `r*` 落在 17–38%：子代理要比父代理便宜 3–6 倍才
可能省。`r = 0` 也不免费——它免掉的是子代理 token，免不掉父侧的回合：

```
10 行小改：自己做 2,400
一任务一回合：编排 2,100 + 摊销 ≈ 2,443 → 亏
攒 10 个成一批：每次约 210 → 省 51%
```

**省钱靠攒批，不靠换更便宜的模型。**

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Linux · macOS · Windows（Git Bash 或 WSL） |
| git | ≥ 2.28（2020-07 发布） |
| 命令 | bash、POSIX 基本工具、`python3`（硬依赖） |
| 工作区 | 可写；不要求是 git 仓库 |

脚本只用 POSIX 工具和 `python3`（生成 `MANIFEST.json`、解析用量），不依赖 `sort -V`、
`date -Iseconds`、`sha256sum` 这些 BSD/macOS 上没有的东西。内容哈希用 `git hash-object`。
git 侧直接用 2.28 的命令：`git init -b`、`git switch`、`git worktree list`，不再为老版本保留
兼容分支。

Windows 上注意两点：脚本必须是 LF 换行（加 `.gitattributes` 或设 `core.autocrlf=false`）；
路径用 POSIX 风格（`/c/work/...`），不要传 `C:\...`。

## 常见问题

**会动我自己的仓库吗？**
不会。所有 git 操作都在 `<工作区>/<会话 id>/repo` 里；你自己的仓库只被读（`--import` 拷文件）。
丢弃用的是 `git reset --hard` + `git clean -fd`，这两条如果作用在你的仓库上会抹掉未提交的改动
和未跟踪文件，所以技能只在自己建的仓库里回滚。工作区本身是 git 仓库时，`preflight` 会让它看不到 `<会话 id>/`：把 `/session-*/` 追加进
`.git/info/exclude`（git 的本地忽略文件，不进版本控制）。你的 `.gitignore` 不会被改，也不会出现
`M .gitignore`；工作区是仓库子目录时为 `/子目录/session-*/`。

**任务完成后要自己删目录吗？**
需要的话删掉 `<工作区>/<会话 id>/` 即可，技能不会自动删：那里留着 patch、`MANIFEST.json` 和提交
历史，是事后审计和回滚的依据。已被外层仓库忽略，放着不会弄脏 `git status`。

**怎么撤销这条忽略？**
删掉 `.git/info/exclude` 里由 `preflight` 追加的两行（`# git-task-bus session workspaces` 和
`/session-*/`）即可；删掉后已有会话目录会重新出现在 `git status` 里。

**子代理说测试通过，能信吗？**
不能。`postflight` 会自己跑验收命令拿退出码，父代理还要再重跑一次。自述不是证据。

**子代理中途挂了或超预算？**
把真实结束原因传给 `--stop`（`aborted` / `error` / `max-tokens` / `refusal`）；给了 `--child`
时 `postflight` 还会从子会话日志校正。`max-tokens` 说明任务太大，缩小范围或拆开，别原样重派。

**验收失败了怎么办？**
看退出码：`0` 通过 · `1` 测试失败或结束原因异常 · `2` 违规（越界 / 改写历史 / 未提交）·
`3` 配置或环境错误。连续两次同类失败通常说明简报不清，该改简报而不是再派第三次。

**怎么选模型？**
技能不判断模型价格，也不替用户决定。首次派发时列出候选、问用户选哪个，用
`--model <provider/model> --save-model` 落盘到会话仓库的 `model`；之后 `--model` 可省。
解析顺序：`--model` > 会话仓库的 `model` > `<工作区>/model`。

**怎么记录子代理用量？**
`--child auto` 会按 `parentSession` 匹配本次派发的子会话，读日志并记进 `tasks/usage.tsv`；
也可以手填 `--usage 'steps=12,in=2689,out=1926,cache=143545'`。读取依赖 DSH 会话日志和
zstd，读不到只警告、不影响判定。`usage_stats.sh` 按模型汇总。

**换环境或换模型前要做什么？**
按 [`git-task-bus/references/probe.md`](git-task-bus/references/probe.md) 跑一次三层探测
（doctor / envcheck / probe），确认子代理会提交、守白名单、按时结束。技能更新后重跑一次。

## 自检与实测

```bash
bash tests/run.sh                    # 97 项断言，不需要网络或子代理
SKIP_USAGE_TESTS=1 bash tests/run.sh # 没有 zstd 时只跑 67 项
```

覆盖建仓与提交、越界拒绝、测试失败回滚、历史改写检测、丢弃与归档、简报校验、最小模式、
可移植性、`--child auto` 与用量记录、重跑守卫、patch 路径。

用 `tests/audit_compliance.py` 检查某次会话在第一次派发前有没有先动手：

```bash
python3 tests/audit_compliance.py --session <会话日志> --scope code,static
```

退出码 `0` 合规 · `2` 违规（列出步骤与命令）· `3` 没有派发记录。

实测结论（详见 [`subagent_test.md`](subagent_test.md)）：

- 同一任务派 7 次，子代理走了 11–86 步；成本尾部取决于首版是否写对，编排消不掉；
- 唯一一次 A/B 是 16 行改动：自己做 213k，派发 671k（含一次失败重派）/ 466k（不含）；
- 两次真实项目评审：子代理 10.9 万与 14.7 万，19 条发现里 12 条有效，漏掉两个高影响问题。

## 开发成本（本仓库自身）

本仓库的开发和验证都在同一个父会话里完成。快照（2026-11-23 读取，此后还会增长）：

| 项 | 值 |
|---|---|
| 步数 | 1,406 |
| 轮次 | 317（人类输入 295 条） |
| 未缓存输入 | 1,911,413 tok |
| 缓存读取 | 513,640,320 tok |
| 输出 | 1,227,313 tok |
| 缓存命中率 | 99.63% |
| 加权成本（输入 1 / 缓存 0.02 / 输出 4） | 17,093,471 |
| 使用本技能自举（派发改它自己） | **0 次** |
| 其中子代理审查自身（普通 subagent，未走技能） | 1 次，加权约 600,656 |

## License

[AGPL-3.0](LICENSE)

---

[中文](README.md) · [English](README.en.md)
