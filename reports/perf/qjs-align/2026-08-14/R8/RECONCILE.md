# R8 RECONCILE — 15 基准自底向上对账

日期：2026-08-14。  
预测 = Σ(R5 census 频次 × R8 原语 Δ单价)。  
实测超出 = R4 fixed-work PMU 中位 cycles（z−q，divisor=16，8-sample）。  
ctor 默认按 **N3g +74**（未知是否 bypass）。

## 判据

- 闭合 ≥80%：弥散地板被单价解释完，修头部原语。
- 欠账大：涌现成本（I-cache / 状态耦合 / 未分形的 ctor）。数字本身是产物。

## 15 行

| benchmark | 实测超出 | 自底向上预测 | 闭合% | 欠账（涌现） | 头部原语 top3 |
|---|---:|---:|---:|---:|---|
| raytrace | +934.3M | +46.5M | **5.0%** | +887.8M | ctor +188, get_field −124, call_method +109 |
| pdfjs | +216.5M | −21.6M | −10% | +238.1M | call_method +44, get_field2 −10, get_loc8 −9 |
| earley-boyer | +1327.0M | +234.3M | 17.7% | +1092.6M | ctor +351, call2 +113, get_field −108 |
| typescript | +131.6M | −150.1M | −114% | +281.7M | call_method +237, get_field −220, get_field2 −65 |
| deltablue | +722.1M | +65.7M | 9.1% | +656.4M | call_method +575, get_field −225, get_field2 −131 |
| richards | +448.3M | −357.1M | −80% | +805.3M | call_method +376, get_field −329, get_field2 −96 |
| zlib | +1336.5M | −1183.4M | −89% | **+2519.9M** | get_loc8 −368, push_0 −351, or +171 |
| box2d | +76.0M | −160.2M | −211% | +236.1M | get_field −129, call_method +32 |
| mandreel | +420.7M | −851.4M | −202% | +1272.1M | get_var −577*, call1 +237, get_loc8 −131 |
| splay | +235.3M | −17.7M | −8% | +253.1M | call2 +17, define_field −17, get_field −13 |
| gbemu | +126.2M | −238.5M | −189% | +364.6M | get_field −123, call_method +54 |
| crypto | −262.6M | −544.9M | （优势低估） | +282.3M | cheap 层预测赢更多 |
| navier-stokes | −95.8M | −210.7M | （优势低估） | +115.0M | 同上 |
| code-load | −42.0M | ≈0 | — | −42.0M | 前端/加载，不在 opcode 价目 |
| regexp | −199.4M | −3.0M | — | −196.4M | 引擎在 regexp 库，不在 opcode |

\* mandreel `get_var` 借用了 get_field −4.1 单价，可能高估优势。不当结论。

**没有任何赤字基准闭合 ≥80%。** 06-26「L1–L6 ~2× 地板加得拢」今天加不拢——因为地板已经不在那些层。

## 例外：raytrace 若按 G 形 ctor 定价

census：`call_constructor` 2.531M = `special_object` 2.531M（每次 new 都造 arguments）。  
单价改用 G 的 Δ +306：2.531M × 306 ≈ **+774M**，闭合 **83%**。  
与 R7 s8（拿掉 apply/`new Vector` → 1.00）和 R8-C 路径核证一致。  
**这是唯一能用「头部原语 × 频次」讲完的赤字基准。**

## 涌现最大的三个

| bench | 欠账 | 交叉验证 |
|---|---:|---|
| **zlib** | +2.52G | R6-F fe_stall 46–85% of Δcyc；单价说 cheap op zjs 该快 1.18G，实测反亏 1.34G。I-cache/工作集把 L0–L3 优势吃光还倒欠 |
| **mandreel** | +1.27G | 同体制 compute；get_var 单价不稳 |
| **earley-boyer** | +1.09G | fclosure 本批未定价（禁区只禁当修复，账上仍空）；ctor 即使用 N0 也只到 24% |

TS / richards：单价预测为负，实测为正。这就是 R7「删到空仍保持比」的定量版——**不是某条 JS 构造，是组合后的分派/帧涌现**。

## 层还剩地板吗（对照 06-26 ~2×）

| 层 | 06-26 | 2026-08-14 | 还剩？ |
|---|---|---|---|
| L0–L3 分派/loc/int | ~2× | **0.78–0.88**（or/sar 0.86） | **否** |
| L4–L5 RC/alloc | ~2× | 0.78–1.06（空 `{}` 1.06） | **否** |
| L6 属性读/写 | ~2× | 读 0.78 / 写 0.85 / miss 0.88 | **否**（P9 转形 1.11 残留） |
| L7 空调用 | — | **1.23，Δ +18** | 小地板 |
| L8 N3 simple new | — | **0.87** | **否**（bypass 有效） |
| L8 N0 空 new / G apply | — | **1.55 / 1.42** | **是**，且只在 G 形宏观上够大 |

## 对 R9 的排序建议

1. **R8-C1 / 修订 R7-R1**：G/initialize 转发 → N3 bypass。唯一闭合可达 80% 的原语×频次项。
2. R6-F 候选 a（`get_arg*` 回热段）：吃 zlib 涌现，不是单价项。
3. R6-K 两刀：AWAIT-MEASURE，预期 <MDE。
4. 不要按单价去瘦 `get_loc`/`get_field`/`add_loc`。

原文：`/tmp/r8/reconcile.json`、`/tmp/r8/reconcile.py`。
