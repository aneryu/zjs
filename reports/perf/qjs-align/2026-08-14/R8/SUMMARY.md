# OPT-R8 汇总 — 自底向上价目表 + 三账对账

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R8.md`。  
诊断批。src 只读。CPU 19 未碰。未合 main。未改账本。

config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a…cf3309d` / pad3 `542965de…` / pad7 `e9fe8f66…`  
qjs `b76d1542…1171364d`

## 结果表

| lane | 价目条数 | 头部发现 | 对账闭合 |
|---|---:|---|---|
| **R8-V** L0–L3 | 8 | 分派地板 **0.78×**（Δ −0.68 cyc/cheap-op）。or/sar +0.44 | 预测 TS/richards 为**负**，实测为正 |
| **R8-M** L4–L5 | 8 | `new Pair` 即丢 0.97；空 `{}` 1.06；`get_array_el` +0.37 | 解释不了 TS destroy 宏观 |
| **R8-P** L6 | 9 | own 读 **0.777**；转形 **1.114** | get_field 负单价，帮 zjs |
| **R8-C** L7–L8 | 16 | **N3 bypass 0.871 / N0 1.553 / G 1.419**。空调用 Δ +18 | raytrace 按 G 定价闭合 **83%**；默认 N3g 只 5% |

## 头条

1. **06-26 的 L1–L6 ~2× 地板已清零。** 今天的 2× 只活在 L8 的 *错误 ctor 形*（空 `new` / `initialize.apply`）。
2. **Σ(频次×单价) 对 14/15 个基准加不拢。** 欠账 = 涌现。zlib 欠 +2.52G，与 R6-F fe_stall 同向。
3. **R7-R1 必须改写：** 不要让 N3 去追字面量（已经 0.87×）。要让 raytrace 的 G 形（2.53M 次 `special_object`≡ctor）打上 N3 bypass。三 pad 零翻转。

## 路径核证（抽查）

| case | 预期 | 实测 |
|---|---|---|
| V1 ctrl | 6 cheap op ×N | `inc_loc if_false8 get_arg0 get_loc0 lt goto8` |
| V3 add | 融合 add | **`add_loc`** 不是 generic `add` |
| N3 new3 | simple-field bypass | **`call_frames=2`** |
| N0 / N3g / G | 真帧 | `call_frames=N`；G 另有 `special_object`=N |
| P1 / M6 | get_field / get_array_el ×N | 是 |

## 交付

| 路径 | 内容 |
|---|---|
| [`/tmp/r8-v/PRICES.md`](/tmp/r8-v/PRICES.md) | L0–L3 |
| [`/tmp/r8-m/PRICES.md`](/tmp/r8-m/PRICES.md) | L4–L5 |
| [`/tmp/r8-p/PRICES.md`](/tmp/r8-p/PRICES.md) | L6 |
| [`/tmp/r8-c/PRICES.md`](/tmp/r8-c/PRICES.md) | L7–L8 + R7-R1 修订 |
| [`/tmp/r8/RECONCILE.md`](/tmp/r8/RECONCILE.md) | 15 行对账 |
| [`/tmp/r8/verify.json`](/tmp/r8/verify.json) | 46 case 路径核证 |
| [`/tmp/r8-*/raw.json`](/tmp/r8-v/raw.json) | 8-sample 原文 |

## 登记候选

| id | 方向 | 分类 | 上限 |
|---|---|---|---|
| **R8-C1**（修订 R7-R1） | initialize/apply 转发 ctor → N3 bypass | FAITHFUL-FIXABLE | raytrace 追平 ≈ +1.7pp geomean（上限） |
| （已有）R6-F a | `get_arg*` 回热段 | 未实施 | zlib 涌现 |
| （已有）R6-K | leaf-call / get_array_el 帧 | AWAIT-MEASURE | 0.2–0.4pp |

## Driver 抽验（CPU 19）

1. `/tmp/r8-c/cases/N3_new3.js` ≈ 0.87  
2. `/tmp/r8-c/cases/N0_new0.js` ≈ 1.55  
3. `/tmp/r8-c/cases/C_G_apply_ctor.js` ≈ 1.42  

三条同号即本批头部成立。

## 不要做

- 不要按单价去瘦 loc / get_field / add_loc。
- 不要删 simple-field bypass。
- 不要把 R7-R1 理解成「N3 字面量化」。
- 不要合 R6-K / 改 PARITY-LEDGER。
