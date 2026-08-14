# OPT-R7 汇总 — zoo 提纯 + 微基准定位

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R7.md`。  
诊断批。src 只读。CPU 19 未碰。未合 main。未改 PARITY-LEDGER。R6-K 未合。

config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a3cb3b3c6…cf3309d` / pad3 `542965de865afe97…e3d95693` / pad7 `e9fe8f66450ae584…6c8a34c9`  
qjs `b76d154265e829e6…1171364d`

## 结果表

| lane | case 比值 / 宏观比值 | 定位构造 | 机制裁决 |
|---|---|---|---|
| **R7-R** raytrace | **1.2964 / 1.2908**（8s pad0；pad3 1.293 pad7 1.288） | `Class.create` apply + 热路径 `new Color`/`new Vector`。三刀之后 **1.0019**（pad3 1.011 pad7 1.009） | **R7-R1 FAITHFUL**：3 字段 simple `new` 逼近字面量。上限 raytrace 追平 ≈ **+1.7pp** geomean。R7-R2 apply 次要 |
| **R7-T** TS 内层 | **inner 1.2006 / 1.215**（三 pad 1.201/1.200/1.201） | **无**。去 emit 保持；只 parse 1.228 仍保持；截输入漂移 | 与 R3-T JS 级干净一致。税在引擎跑完整 parse。无新 FAITHFUL |
| **R7-H** richards | **1.1092 / 1.1039**（三 pad 1.109/1.111/1.111） | **无**。内联 TCB.run / addTo / schedule / kind-switch 全保持 | 弥散 OO。insn 1.176 + IPC 1.06。无新 FAITHFUL |
| **R7-Z** zlib | **1.07–1.09 / 1.073–1.086**（pad7 inner 1.075） | **无**（emscripten 不可再删） | 前端实验：小集可翻成 zjs 优势，IPC 不单调消失。维持 R6-F 候选 a |

## 头条

**四条赤字基准里，只有 raytrace 被提纯成可修构造。**  
另外三条的 case 都过了 ±0.02 门，但删到空仍保持比 —— 机制不在 JS 胶水，在已经命名的引擎层（帧 / 分派 I-cache / 禁区 teardown）。

这是 splay 方法（比值不变量 + 逐步删减）第一次在 raytrace 上复现「100% 在构造」：  
`new Vector`/`new Color` + `initialize.apply` 的成对税 = 1.00G extra cycles = 全部宏观超出。

## 交付

| 路径 | 内容 |
|---|---|
| [`/tmp/r7-r/REPORT.md`](/tmp/r7-r/REPORT.md) + `case-pure.js` + `s8-vec-literal.js` | 轨迹、8-sample、三 pad、成对定价 |
| [`/tmp/r7-t/REPORT.md`](/tmp/r7-t/REPORT.md) + `case-pure.js` | 内层口径、emit/parse 二分 |
| [`/tmp/r7-h/REPORT.md`](/tmp/r7-h/REPORT.md) + `case-pure.js` | OO 调度器删不塌 |
| [`/tmp/r7-z/REPORT.md`](/tmp/r7-z/REPORT.md) + `case-pure.js` | 前端假设判决 |
| [`/tmp/r7/all-ratios.json`](/tmp/r7/all-ratios.json) | 40 条测数 |
| [`/tmp/r7/measure.py`](/tmp/r7/measure.py) | ABBA perf-stat runner |

## 登记候选（只登记）

| id | 来源 | 分类 | 预计量纲 |
|---|---|---|---|
| **R7-R1** | raytrace `new Vector`/`new Color` | FAITHFUL-FIXABLE | 单基准 0.777→~1.00，geomean **~+1.7pp**（上限） |
| **R7-R2** | `initialize.apply(this, arguments)` | FAITHFUL-FIXABLE | ~20% raytrace 缺口；R1 可能吸收 |
| （已有）R6-K 两刀 | leaf-call / `get_array_el` | AWAIT-MEASURE | 0.2–0.4pp，可能 <MDE |
| （已有）R6-F 候选 a | `get_arg*` 回热段 | 未实施 | zlib I-cache |

## Driver 抽验建议（CPU 19）

1. `/tmp/r7-r/case-pure.js` 应 ≈1.29 cyc；`/tmp/r7-r/s8-vec-literal.js` 应 ≈1.00。差一个数量级，不易看走眼。
2. `/tmp/r7-t/case-pure.js` 看 stdout `R7_WALL`，不要看整进程。
3. 不要把 increment / tiny-or 当 zlib 证据。

## 不要做

- 不要把 s8 字面量写法合进 zoo 或引擎「假对齐」。
- 不要为 TS/richards/zlib 新开 JS 胶水修复。
- 不要重开 H3 / readfwd / IMPL-TEARDOWN / 给 String 加 capacity。
- 不要合 `grok/opt-r6-k`（仍 AWAIT-MEASURE）。
- 不要把本批写进 PARITY-LEDGER，除非 driver 抽验后授权。
