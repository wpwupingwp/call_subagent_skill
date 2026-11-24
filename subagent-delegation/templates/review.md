# 审查记录：<TASK_ID>

## 事实（机械核对，来自 postflight）

| 项 | 值 |
|---|---|
| BASE | `<sha>` |
| HEAD | `<sha>` |
| stopReason | `completed` / `max-tokens` / … |
| 变更文件数 | |
| 越界违规 | |
| 历史改写 | 是 / 否 |
| 测试退出码 | |
| patch sha1（git hash-object） | |

## 证据

- 测试日志：`test.log`
- 净 diff：`deliveries/<TASK_ID>.patch`
- 出处：`provenance.tsv`（导入源与 sha1）

## 判断

- 层级 1（`--stat` 体量是否与需求匹配）：
- 层级 2（是否触发细读，触发原因）：
- 未覆盖风险：

## 结论

- [ ] 通过 —— patch 交用户；已验收的提交就是 main 的最新状态，无需其他操作
- [ ] 拒绝 —— 原因：<越界 / 改写历史 / 测试失败 / stopReason 异常>
- [ ] 打回重派 —— 需要补充的上下文：
