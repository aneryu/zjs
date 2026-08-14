# R4-T LEDGER — 时间盒折差

lane: R4-T / CPU 5（迭代曲线与 GC dump 在 CPU 8，CPU 5 当时跑折差 PMU）  
日期：2026-08-14。诊断批，非裁决。src/ 生产路径未改。  
zjs pad0 `/tmp/r3-bins/prod/bin/zjs` sha256 `12bc8b8a3cb3b3c6feea8a1bea61f254caf6fde32fddc5b808d789170cf3309d`  
qjs `/home/aneryu/quickjs/qjs` sha256 `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`  
GC dump 二进制（仅 `-d` 多打 GC 行，不合 main）`3967bac3…`  
PMU：`run_zoo_fixed_pmu.py --iteration-divisor 16 --samples 8 --cpu 5 --pmu armv8_pmuv3_1`  
原始：`/tmp/r4-t/fixed-pmu-8.json`

## 闭合声明

**闭合。** 折差表覆盖 15 个基准。TS 10–17% 折差已命名，不是 GC 相位。

## 折差表

`fold = (1/zoo_ratio) / fw_cyc_ratio − 1`。zoo 分数用 PARITY-LEDGER（现成）。  
`***` = |fold| > 3%。

| bench | zoo | 1/zoo | fw cyc | fold | 注 |
|---|---:|---:|---:|---:|---|
| raytrace | 0.777 | 1.287 | 1.2908 | −0.29% | 与 HANDOFF「EB/RT 无此签名」一致 |
| pdfjs | 0.785 | 1.274 | 1.1955 | **+6.56%** | 次大；与 R4-P 对账 |
| earley-boyer | 0.799 | 1.252 | 1.2464 | +0.41% | 与 HANDOFF 1.2435 vs 1.253 一致 |
| **typescript** | 0.830 | 1.205 | **1.0291** | **+17.08%** | **头号。D6 的 1.0817x 已过时** |
| deltablue | 0.870 | 1.149 | 1.1453 | +0.36% | |
| richards | 0.904 | 1.106 | 1.1039 | +0.21% | |
| zlib | 0.920 | 1.087 | 1.0862 | +0.07% | |
| box2d | 0.922 | 1.085 | 1.0641 | +1.93% | |
| mandreel | 0.941 | 1.063 | 1.0664 | −0.35% | |
| splay | 0.943 | 1.060 | 1.1634 | **−8.85%** | FW 比 zoo 更差：时间盒帮 zjs |
| gbemu | 0.968 | 1.033 | 1.0701 | −3.46% | 同向弱 |
| crypto | 1.058 | 0.945 | 0.9521 | −0.73% | 对照 |
| navier-stokes | 1.061 | 0.943 | 0.9408 | +0.18% | 对照 |
| code-load | 1.104 | 0.906 | 0.8629 | +4.97% | 领先基准，frontend 摊销反向 |
| regexp | 1.130 | 0.885 | 0.9133 | −3.10% | 对照 |

落后基准里 **只有 TS 和 pdfjs** 的正折差 >3%。TS 是独特的 17%。

## TS 迭代曲线（进程内，deterministic 5 轮）

| 引擎 | n | 每轮 ms | med | 形态 |
|---|---:|---|---:|---|
| zjs | 5 | 1195, 1329, 1339, 1361, 1314 | 1329 | 首轮更快，随后平台 |
| qjs | 5 | 1054, 1094, 1119, 1078, 1094 | 1094 | 平台 |

med 比 1329/1094 = **1.215** = 1/0.823，与 zoo 0.830 对齐。  
**无线性上漂、无台阶。** 堆老化 / GC 周期假设否决。

## GC / 堆体积（VERIFIED-LEDGER §4.2 预注册假设）

| | zjs FW | zjs timebox | qjs FW | qjs timebox |
|---|---:|---:|---:|---:|
| objects | 380558 | 380558 | 380544 | 380544 |
| allocated/used | 97.89 MB | 97.89 MB | used 85.66 MB | 85.66 MB |
| major_gc_count | **21** | **21** | DUMP_GC 行 **19** | — |
| malloc_gc_threshold | 118.0 MB | 118.0 MB | — | — |

- FW 与 timebox **堆完全相同**，GC 次数相同。
- 对象数两侧几乎相等（380558 vs 380544）。**不是 20–40% live heap 膨胀。**
- GC 动态阈值公式两侧相同：`allocated + allocated>>1`（`runtime.zig:2708` ≡ `quickjs.c:1795-1796`）。VERIFIED-LEDGER §4.2 初始 256KB ✅ 同；**动态公式也同**。
- 数组/属性容量增长 ❌ 异（§4.2）在 TS 上**没有**表现为 live object 数差。

预注册「容量策略 → 堆大 → 每轮 GC 扫更多」**在 TS 上被证伪**。

## 机制命名

**TS 折差 = 整进程 PMU 把 2.5MB TypeScript 前端/编译摊进去，而 Octane 分数只量内层 `benchmark.run()` 循环。**

证据链：

1. 整进程 FW cycles **1.029x**（zjs 前端是优势，HANDOFF pdfjs frontend −17M 同构）。
2. 内层 5 轮 wall **1.215x** = zoo 分数。
3. 同一份 deterministic 源码，分数比 0.84、cycle 比 1.029——折差发生在 **度量口径**，不是跨轮漂移。
4. code-load 正折差 +5% 是同一机制的反向（分数含编译，PMU 也含，zjs 更快）。

pdfjs +6.56% 是同类、更弱（语料也大，但热循环占比更高）。

splay −8.85%：FW 比 zoo 更亏。splay 是分配/GC 基准；时间盒下 qjs 多跑的迭代更吃 GC。不叫 TS 那种折差。

## 台账（TS 折差分解）

| 桶 | 量 | 占 17.08% 折差 |
|---|---|---|
| 内层循环单位成本（iter med） | 1.215x | 这就是 zoo |
| 整进程 FW 多出来的 zjs 前端优势 | 1.215/1.029 − 1 = 18.1% 相对 | **命名：compile/frontend 摊销** |
| 跨轮 GC/堆老化 | 0 | 否决 |
| 残差 | <3%（1.215 vs 1.205 ledger） | 闭合 |

## R5 含义

这 **不是**「修 GC 阈值就能收 0.7pp」。0.7pp 是把 zoo 当成 FW 的错觉。真赤字在内层 1.215x。R4-C 管那 1.215x 的单轮账。

## [PROGRESS]

```
[PROGRESS] R4-T fold-pmu 15 benches × 8 samples DONE
[PROGRESS] R4-T TS fold +17.08% named frontend-amortization
[PROGRESS] R4-T GC/heap hypothesis FALSIFIED (21=21, objects equal)
[PROGRESS] R4-T iter-curve flat 1.215x
[PROGRESS] R4-T DONE closed
```
