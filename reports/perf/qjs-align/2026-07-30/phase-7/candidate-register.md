# Phase 7 候选登记表

登记那些**在别条线里被意外撞到、但尚未具备立项条件**的信号。登记不等于排期；
每条都写明缺什么，避免后来者把它当成已就绪的目标直接下刀。

## P7-60 logical-not opcode attribution

**登记日期**：2026-07-30
**来源**：P7-41 的一处对照缺陷修正（见 `P7-41-builtin-bridge.md` §2.4）

首轮 `every` 的 direct-loop 对照写成 `if (!cb_true(…))`，净差异常偏低。专门探针显示
**一次逻辑 NOT 在 zjs 约 18.17 cycles，qjs 约 3.06 cycles**，符号
`exec.vm_value.logicalNot`，**没有快速 op handler**。改成无取反的对照后，`every` 的
`zjs_specific_bridge_tax` 从 +10.29 移到 +25.99，与其余三个干净 rung 一致。

信号质量高：量级大、形状孤立、与 Array builtin 语义无关。但**当前只有一个意外 probe**，
立项前至少还缺四项：

- **JS 类型语义矩阵**。`!x` 的成本可能强依赖操作数类型（boolean / int / double / string /
  object / undefined / null）。单点探针无法区分「`ToBoolean` 本身贵」与「只对某些类型贵」。
- **same-runtime 的 P0/P1 稳定基线**。现有数字来自 P7-41 的诊断探针，不是按本战役采样纪律
  （偶数样本、ABBA、每侧两个冷缓存构建、全组合）测出来的。
- **实际 Pareto 总贡献**。18.17 vs 3.06 是**每次操作**的差；在真实脚本里 `!` 出现多少次未知。
  按当前排序规则，必须用**绝对 cycles 总贡献**（每次差 × 实际次数）而不是比值来排。
- **归因边界**。尚未区分这笔成本是**函数调用边界**（缺快速 handler 导致落到通用路径）
  还是 **`ToBoolean` 语义本身**昂贵。两者对应完全不同的一刀。

**当前状态**：不抢占 P7-50 / P7-41 的顺序，也不在两条画像完成前启动。

## 已从候选转为结论或关闭的条目

- **SmallObjectSlab empty-arena retention** → P7-00 裁决 `does not generalise → permanently close`，
  机制与 qjs 逐项相同，不开 P7-01。
- **进程内存快照固定税** → 已由 P7-31 落地（`e94649c9`），gbemu +8.49%～+8.97%。
- **TypedArray 构造残余约 2x** → P7-30 判为分散（view wrapper 2.57x / zero fill 4.28x /
  plain construct 2.03x / out-of-line buffer 1.99x），本轮不追。
- **`array_map_callback = 2.618x`** → P7-40 证明不复现（过期二进制 + 非绑核采样两项混杂），
  权威值 cycles 1.364x；P7-20 的第 1 名与 17.2% 份额已作废。
