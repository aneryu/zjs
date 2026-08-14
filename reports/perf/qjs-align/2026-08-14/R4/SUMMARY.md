# OPT-R4 汇总 — 解释台账守恒闭合

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R4.md` @ `7ebde5b5`。  
src/ 生产路径未改。CPU 19 未碰。候选只登记。

## 结果表

| lane | 状态 | 闭合度 | 头部发现 |
|---|---|---|---|
| R4-T | **闭合** | 折差表 15/15；TS 命名 | TS 折差 **+17.08%** = 前端摊销（整进程 1.029x vs 内层 1.215x）。GC/堆老化否决（21=21，对象数相等）。§4.2 容量→堆膨胀在 TS 上证伪。pdfjs +6.56% 同类。splay −8.85%。 |
| R4-P | **闭合** | 7 桶 +215 / PMU +216 = **0.5%** | G2「60% / 137M」**SUPERSEDED**。现净 +216M。无 ≥10% 单机制。 |
| R4-C | **闭合** | 7 桶 +135 / PMU +132 = **2%** | **782M 过时**。现净 +132M。other=+570M 实为 RC destroy/trace + `pushExactSimpleFrame`。property 两侧 37%=37%，X-10 后慢路径不再是 +180M。 |
| R4-U | **首轮闭合** | 五基准已分桶 | zlib **升级**（dispatch+call = 111% 净超出）。其余无单桶 ≥50%。 |

## 对四块缺口

| # | 原缺口 | 本批 |
|---|---|---|
| G1 | TS 折差 10.16%、≈0.7pp | **命名**：不是 GC，是 PMU 含编译 / 分数只量循环。0.7pp 不能当「修 GC 就回来」。真循环税 1.215x 归 R4-C/内层。 |
| G2 | pdfjs 60% | **已废除**。现账 97%+ 闭合，净 216M，无主导机制。 |
| G3 | TS 782M | **已废除**。现净 132M，other 已点名到 RC/frame。 |
| G4 | 五基准从未看 | **已分桶**。zlib 升主攻；splay 不要砍 alloc。 |

## A/B

解释台账这四块不再是「没找到的问题」。路径 A 在 JS 胶水（R3）和这四块账上已经扫过。剩下的是 zlib 解释循环、TS 内层 1.215x 的 RC/teardown 记账、pdfjs 弥散单位成本。架构裁决可以带着这四张表重新上呈——**不是**「再去找第二个 initialize.apply」。

## 交付

- `/tmp/r4-t/LEDGER.md` + `fixed-pmu-8.json` + `ts-iter-*.txt`
- `/tmp/r4-p/LEDGER.md` + `prof/`
- `/tmp/r4-c/LEDGER.md` + `prof/` + memory dumps
- `/tmp/r4-u/LEDGER.md` + `prof/`
