# OPT-R13 计划 — 自底向上优化战役（用户方向指示）

日期：2026-08-15。状态：**Phase 0 立即启动；Phase 1 各梯级在 wave-2 合入后的新基线开工**。
指示原文：「从低层向上优化」。与 R8（自底向上**定价**）衔接：R8 量了每层的价，
R13 按层**修**——从最低付费层向上，每梯级 FAITHFUL（qjs 结构/布局镜像），修完一层重定上层价。

## 0. 底层付费点清单（R8/R9/r12 已知，待 Phase 0 真基线重定价）

| 层 | 付费点 | 已知量 | 状态 |
|---|---|---|---|
| L7 帧 | **Entry 256B vs qjs JSStackFrame 72B**（10·§1.1/§16.1；r12 判「12.1 cyc 地板=Entry 填充+memset」） | 每次调用固定填充/拆除 | **R13 第一刀候选**（原「不要动」标记因自底向上指示解除，须独立设计简报） |
| L7 调用 | 空调用 Δ+18（wave-2 pushExact 后重测残余） | ~18→? | Phase 0 重测 |
| L8 构造 | N0 残余（R9 后 1.425） | +70 级 | Phase 0 重测→分解 |
| L7 拆帧 | teardown（旧锚 19.26vs1.93 已废，真值未测） | ? | Phase 0 重测 |
| L1 分派 | 前端涌现税（fe_stall 46-85%，compute 四基准） | ~2pp | 布局批 PAUSED 等用户；非布局缓解=pushExact §c（已在 wave-2） |
| L4/L9 | RC/GC 残余（wave-2 GC 刀后重定价） | ? | Phase 0 |

## 1. Phase 0 —— 真基线价目重定（pS，立即，诊断）

R8 全套价目是**旧世界**（带 bypass、无 R10/wave-2）数字。在 true 二进制上重跑
R8-V/M/P/C 阶梯（案例与工装全在 /tmp/r8-*），产出「真价目表 v2」：
每层 z/q + 与 R8 旧值对照 + wave-2 合入后再跑一遍增量列。
交 /tmp/lanes/r13-PRICES.md。合同：CPU 16、ABBA≥8、数字非裁决、指纹验证二进制。

## 2. Phase 1 —— 梯级刀（wave-2 后逐个设计简报→批→实施）

1. **Entry 几何对齐**：qjs JSStackFrame 九字段（qjs:407-420）vs zjs Entry 256B 逐字段
   映射（r12-KNIFE 已列 ownership/cold/arena_mark/teardown/return_action/planned_stack_bytes/
   Stack 整对象为 zjs 多出）；设计简报必答：每个多出字段的承载理由/能否并位/
   能否迁移到 Machine 级或 comptime；**帧生命周期红线全程**（ReleaseSafe+全量 gate）。
2. N0 构造残余分解（R9 未尽段）。
3. teardown 真值重测后视数字立项。
4. 每落一刀→上层重定价→下一刀。布局批始终 PAUSED 等用户裁决。

## 3. 结果表（滚动）

| 梯级 | 状态 |
|---|---|
| Phase 0 重定价 | pS 执行中 |

## R10 官方真定损（2026-08-15，指纹验证三 pad，替代此前全部幻影数字）

geomean **0.9863/0.9864/0.9866**（三 pad 离散 0.0003，真损 −1.36%，账面 geomean ≈0.9166）。
EB 0.8969/0.8916/0.8863；**raytrace 0.9275/0.9212/0.9162**（第二大洞，三 pad 同号）；
splay −1.7~2.4%；zlib −1.2~1.6%；TS **+0.9~1.0%**（v1.5 在 TS 的小赢显影）；资产无损。
回收对位：EB←wave-2（终审接力中）；raytrace←wave-3 v2-L1（合规已全绿，方向 +37%）；
splay←wave-2 微刀覆盖面。
