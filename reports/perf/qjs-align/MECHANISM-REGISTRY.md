# 机制登记册

已通过因果验证、但**尚未获准成为生产候选**的机制。
新增条目必须已完成阳性放大 + 阴性消融，并给出定价。

判据参照：D10 定的 zoo MDE = **0.278 pp**（7 pad × 8 samples）。
按当前粗换算，达到 MDE 约需 **110M cycles 等价值**；
组包目标应取 **0.35–0.40 pp** 以留余量，而不是刚好卡在 0.278。

---

## `native-backtrace-publication`

```
CAUSALITY:            proven（阳性放大 + 阴性消融 + 宏观路径检测器）
PERFORMANCE VALUE:    14.074M cycles，PdfJS 赤字的 6.42%
PRODUCTION CANDIDATE: BLOCKED
BLOCKER:              语义资格未核实
```

来源：`2026-08-13/PDFJS-DIAG-P3-INTERVENTIONS.md`。

**这不是效应量问题，是语义资格问题。** 解锁前必须回答：

- zjs 是否比 QuickJS **多做**了发布或恢复？
- 这些状态是否影响 **observable backtrace**？
- 能否在**不改变异常时序、栈帧位置、source location** 的前提下消除？
- 它是否只是 musttail 架构**必需**的额外 publication？
- 是否存在 **QJS-aligned 的状态承载方式**？

⚠️ 若只是「跳过发布所以更快」，但会改变用户代码在 native callback 内构造 `Error`
时看到的堆栈，**就不是合法候选**。

仅在下列之一成立时解锁：
1. 证明现有工作是 **zjs-only 冗余**，移除后仍与 QuickJS observable behavior 对齐；
2. 找到新的状态承载方式，使 backtrace 信息**完全等价**。

---

## `rope-strict-equality`

```
CAUSALITY:            proven（下游成本已验证）
PERFORMANCE VALUE:    9.615M cycles，PdfJS 赤字的 4.38%
PRODUCTION CANDIDATE: BLOCKED（2026-08-14 起改为价值/表示层理由）
BLOCKER:              上游已命名（OPT-R2 H2 侦察），但修复=表示层决策，0.06pp 不值得
```

**2026-08-14 H2 侦察收案**（`/tmp/h2-bins/RECON.md`，计数器分支 `grok/opt-r2-h2-recon` 不合并）：
pdfjs 一整轮 3.83M 次 concat 分桶 = **lhs 共享（rc>1）65.5% / lhs=rope 30.6% / lhs=flat·rc==1 仅 0.63%**。
「flat·rc==1 本可原地增长」假设被证伪（24k << 545k 闸门）；rope 盈余来自
**共享 lhs 上的惰性 concat 策略本身**——qjs 在该桶同样无法 inplace（全新分配+双拷贝），
差异是「懒 rope vs 急拷贝」的表示层选择。`memory.zig` 侧指针→槽类基础设施已存在
（`headerClassIndex`/`rawFree` 读头），残余绑定只在 `destroyFlat`/`allocated_bytes`/assert——
但频次闸门未过，**不立项**。若未来走路径 B 重审表示层，本段是起点。

来源：同上。证据显示 **zjs 在选定热操作数上比 QuickJS 多产生 1.090M 个 rope**。

⚠️ **不得直接把「优化 strict equality 遍历」当作候选**——根因更可能在上游：

- 为什么 zjs 多形成 rope？
- concat 策略是否不同？
- flatten 时机是否不同？
- substring / slice 是否保留了不同表示？
- QuickJS 是否在更早阶段已经 materialize？
- rope depth、长度、引用模式是否不同？

若直接给 equality 加新的快捷判断，很可能是在**补偿上游 representation mismatch**，
也可能长成 QuickJS 没有的特化路径。**上游原因未命名前不得进入生产候选。**

---

## `leaf-call-frame-zero`（R5-C 登记，2026-08-14）

```
来源:      R5-C 反汇编对照——qjs CASE(OP_call*) 在 bl JS_CallInternal 之前零额外帧
           （label_OP_call0 0x254ec，qjs:18175-18192）；zjs op_call* 无条件开 96B+0x220 帧
性质:      FAITHFUL（对齐 qjs 的帧形状）
候选形态:  op_call*_leaf / op_call_method_leaf 克隆：只 resolve + enterEntry + br
状态:      REGISTERED，单条 <0.3pp，进 R6 组包 + 三 pad
```

## `get-array-el-frame-zero`（R5-P 登记，2026-08-14）

```
来源:      R5-P——get_array_el 快数组臂因 bl destroyZeroRef 无条件开 0x50 帧
候选形态:  outline 零 RC 路径，热臂 frame-zero
性质:      FAITHFUL（qjs 快臂无帧）
状态:      REGISTERED，单条 <0.3pp，进 R6 组包 + 三 pad
```

## 组包规则（当前：`candidate-package` NOT AUTHORIZED）

上述两项合计 23.689M ≈ **+0.06 pp**，仅为 MDE 的约五分之一。
**不得把它们单独打包**——包信号会被构建布局噪声淹没，留一法的每个差值更不可测，
且两者分属不同子系统，组合缺乏工程与因果上的内聚性。

组包必须**同时**满足：

1. 每个组件已有**局部固定工作量**的因果验证；
2. 组件之间**没有互相遮蔽或重复计价**；
3. 合计效应预计**超过测量门槛**（目标 0.35–0.40 pp）；
4. package 全 zoo 通过后，再用**目标微基准 + 区域 PMU** 做组件归因；
5. **不得**依赖 full-zoo leave-one-out 去测量远低于 MDE 的单组件差异。

**唯一例外**：某项被证明属于 **QuickJS alignment / correctness 修复**——
那按忠实性规则评审，而不是伪装成性能候选。
