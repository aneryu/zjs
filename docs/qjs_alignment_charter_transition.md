# qjs-faithful 宪章过渡记录(退役与接替)

Date: 2026-08-24
Status: **RATIFIED**(owner 批准,2026-08-24,决议 D1-A)。自本时刻起
§2 所列条款退役、§4 接替制度生效;
[engine-evolution-plan.md](engine-evolution-plan.md) Phase 0.5 解锁。
体例参照 [qcp1_switch_decision.md](qcp1_switch_decision.md)。

## 1. 触发与依据

"对齐并打败 QuickJS"阶段目标已完成:bench-v8 composite
**1.0464×QuickJS**(zjs 2706 / qjs 2586,7/8 基准 ≥ 1.0,
[perf/bench-v8-status.md](perf/bench-v8-status.md));test262 44,584
pass / 0 unexpected failures。项目目标改立为"逼近 JIT 级引擎 +
native-heavy GUI runtime"(engine-evolution-plan §2.3)。原宪章中以
"忠实于 qjs 实现形态"为**约束**的条款,与新目标下的反馈槽/IC/JIT 工作
直接冲突,须显式退役——否则后续工作在双轨规则下进行,测量与审计的
裁决依据失去唯一性。

## 2. 退役条款(自批准时刻起不再约束)

| # | 条款 | 原始出处/时点 | 退役理由 |
| --- | --- | --- | --- |
| R1 | 「qjs 没有的 fast path 必须删,不开例外口子」 | 2026-08-11 owner 裁决(constructSimpleFieldConstructor bypass 触发) | 该条的正当性前提是"分数落后时,zjs-only 快径掩盖每-opcode 成本差距"。对齐已完成,前提消失;反馈槽/IC 本质上就是 qjs 没有的机制 |
| R2 | property IC 移除决议(运行时结构对齐 qjs) | `adbc688a`(旧谱系)"align runtime structs to qjs layout + remove inline cache" | 当时移除的是恒 null 的 ABI 残桩,且服务于结构对齐目标;新反馈槽是不同设计(外挂 side table,canonical 结构不动),不受该决议约束 |
| R3 | 「IC/fusion = 换赛道作弊」判 | call-machinery 忠实前沿裁决(2026-07;08-14 已注记待定) | "赛道"的定义随目标变更:比较对象不再是 qjs 解释器,作弊概念不再适用。08-14 的待定注记就此了结 |

## 3. 保留条款(明示不受本过渡影响)

| # | 条款 | 状态 |
| --- | --- | --- |
| K1 | 测量合同全部条款(ABBA/绑核/insn+cyc 同测/pad 谱系/频次裁决/驱动亲验产物指纹等) | **不变**。合同约束的是测量有效性,与对标对象无关 |
| K2 | 通用性原则(形态特判禁止;通用机制走 PERF-MECHANISM-LEDGER) | **不变且升格**:反馈槽/IC 必须作为通用机制落地并过同一审计门——benchmark 特化仍然禁止 |
| K3 | QuickJS differential oracle(正确性差分) | **不变**。qjs 仍是语义正确性的参照实现 |
| K4 | 治理门([stack_bytecode_vm_design.md](stack_bytecode_vm_design.md) §8:字节码架构重估须 PMU 证据) | **不变** |
| K5 | ES2015 PTC 等已文档化分歧(`LIMITATIONS.md`) | **不变**,维持既有记录方式 |

## 4. 接替:性能对标制度

- **公开记分口径**:bench-v8 composite 契约延续
  ([perf/bench-v8-status.md](perf/bench-v8-status.md)),qjs 作为
  **历史锚点与回归哨兵**保留在套件中——分数不得跌破已达成的
  1.0464× 无解释;
- **新参照系**:反馈槽/JIT 各阶段的验收以**自身冻结基线**的受控
  A/B 为准(engine-evolution-plan §14 各门);JIT-class 引擎
  (JSC/V8 解释器+baseline 层)对照作为**方向性参考**引入,不作
  gate——引入时须为其建立与测量合同同等级的采集契约,禁止引用
  未受契约约束的外部数字作裁决;
- zoo 内部诊断口径([perf/zoo-status.md](perf/zoo-status.md))继续
  作为归因工具。

## 5. 历史地位声明

2026-06→08 的 qjs 代码级忠实对齐(commit 注 `qjs:N` 惯例、逐机制
镜像)是把 zjs 从多倍差距带到反超的**方法**,其产出(对齐的字节码
形态、成本模型、差分基建)是新阶段的地基,不因约束退役而贬值。
`qjs:N` 注释保留原样——它们记录的是机制出处,不是持续义务。今后
引用 qjs 实现仍是**诊断与设计参考的推荐做法**,只是不再是变更的
合法性条件。

## 6. 批准

- [x] Owner 批准:Aneryu,2026-08-24(会话内决议 D1-A,现稿无修订)
- 生效动作已执行:状态行 **RATIFIED**;engine-evolution-plan §3.4
  标记满足;Phase 0.5 解锁。
