# 三层探测

> 按需读取。首次使用某个子代理模型、或换机器/换环境时执行一遍。

三项检查回答三个不同的问题，不能互相替代：

| 检查 | 问题 | 工具 |
|---|---|---|
| 环境 | 本技能能否工作 | `doctor.sh` |
| 任务 | 这个任务的验收命令能否运行 | `envcheck.sh` |
| 模型 | 子代理是否守约 | `probe`（走一次真任务） |

## doctor：本技能能否工作

```bash
bash <本技能目录>/scripts/doctor.sh --root <可写工作区>
```

`--root` 默认当前目录。在沙箱或只读目录里它会报「根目录不可写」——那不是环境坏，是没指对地方；
改成工作区或 `/tmp` 再跑。环境不合格时，后续任何步骤都不必尝试。

## envcheck：验收命令能否运行

```bash
bash <本技能目录>/scripts/envcheck.sh --tests '<任务验收命令>' --cwd <目标目录>
```

| 退出码 | 含义 | 处置 |
|---|---|---|
| 0 | 命令可执行，基线为绿 | 继续 |
| 1 | 命令可执行，但基线是红的 | 新实现任务里红是预期；其他情况先弄清原因再派 |
| 3 | **环境缺失**：命令不存在 / 不可执行 / 目录不可用 | 换模型无用，需修环境 |

退出码 3 必须报告为「环境缺依赖」，不要报告成「模型不行」。

## probe：子代理是否守约

```bash
bash <本技能目录>/scripts/preflight.sh --task probe-$(date +%m%d) \
  --allow probe.txt --tests 'test -f probe.txt' \
  --brief <本技能目录>/templates/probe.md \
  --model <provider/model> --quiet
```

派发 `POINTER` 那一行，完成后 `postflight --stop completed --quiet`。四项判据：

| 检查 | 判据 |
|---|---|
| 守白名单 | 越界清单为空 |
| 会提交 | `git status` 为空（否则退出码 2） |
| 完成回合 | `stopReason = completed`（不是 `max-tokens`） |
| 能产出可验证结果 | 验收命令退出 0 |

**判定**：一次失败可疑；**连续两次失败 → 停止使用该子代理模型**，并明确报告：

> 该模型不适配 git-task-bus（具体失败项：…），建议换模型或由父代理直接完成。

不试第三次。probe 走同一套自动丢弃逻辑，成本可忽略。
