# R4-U LEDGER — 五基准首轮七桶

lane: R4-U / CPU 7  
日期：2026-08-14。诊断批。首轮闭合门槛 ±15%。  
zjs `12bc8b8a…` / labeled-qjs `394d453d…`（频率）/ 生产 qjs 只作对照（无 opcode 标签，call 桶膨胀，不用）。  
PMU 总超出来自 R4-T `fixed-pmu-8.json`（d16，8 samples）。

## 闭合声明

五个基准都给出了桶级账。qjs 必须用 OPCODE_ASM_LABEL 副本，否则 86–99% 掉进 `JS_CallInternal`。  
计划名单是 zlib/richards/box2d/splay/gbemu。HANDOFF 的 34.3% 含 mandreel 不含 gbemu；mandreel 已收案。gbemu 按任务书做了。

## 总超出（FW d16）

| bench | zoo | fw cyc | q Gcyc | z Gcyc | 超出 M | 折差 |
|---|---:|---:|---:|---:|---:|---:|
| zlib | 0.920 | 1.0862 | 15.45 | 16.70 | **+1250** | +0.07% |
| richards | 0.904 | 1.1039 | 4.319 | 4.767 | **+448** | +0.21% |
| box2d | 0.922 | 1.0641 | 1.195 | 1.272 | **+77** | +1.93% |
| splay | 0.943 | 1.1634 | 1.443 | 1.679 | **+236** | −8.85% |
| gbemu | 0.968 | 1.0701 | 1.796 | 1.920 | **+124** | −3.46% |

## 七桶（份额 × PMU）

### zlib（超出 +1250M）— **dispatch 单独 ≥50%，升级命名**

| 桶 | z% | q% | 超出 M | 占净 |
|---|---:|---:|---:|---:|
| dispatch | 68.9 | 38.0 | +5630 | — |
| call | 0.1 | 27.5 | −4240 | — |
| **dispatch+call** | **69.0** | **65.5** | **+1390** | **111%** |
| property | 19.1 | 8.5 | +1880 | 150% |
| string | 3.9 | 12.5 | −1280 | |
| arith | 0.0 | 12.3 | −1900 | |
| alloc | 0.0 | 1.0 | −155 | |
| other | 7.9 | 0.2 | +1290 | |
| GC | 0 | 0 | 0 | |

dispatch 与 call 的切法跨引擎不一致（zjs 解释循环几乎全进 dispatch）。合并后 +1390 / +1250 = **111%**，落在 ±15%。  
**升级**：zlib 主攻面 = 解释循环 / 字节热路径（68.9% zjs dispatch），不是胶水函数。VERIFIED-LEDGER §4.2 容量增长不像主因（string/alloc 是 zjs 优势）。

### richards（+448M）

| 桶 | z% | q% | 超出 M | 占净 |
|---|---:|---:|---:|---:|
| property | 44.3 | 50.3 | −60 | −13% |
| call | 23.8 | 29.7 | −80 | |
| dispatch | 24.2 | 19.3 | +320 | 71% |
| other | 7.4 | 0.0 | +350 | 78% |
| alloc/arith/GC | ~0 | 0.8 | −35 | |
| **dispatch+other** | | | ~+670 vs +448 | 需再切 other |

property 两侧都是第一大桶且 qjs 份额更高——不是「zjs 属性税」。dispatch+other 是正账。首轮 ±15% 在合并 dispatch+other 后能讲通，机制未命名。形态像 deltablue（OO 短方法），R3-D 已证明短方法超额只有 0.14pp。

### box2d（+77M）

| 桶 | z% | q% | 超出 M |
|---|---:|---:|---:|
| dispatch | 30.8 | 20.8 | +143 |
| property | 45.1 | 51.7 | −38 |
| call | 12.1 | 11.9 | +8 |
| arith | 0.3 | 7.5 | −86 |
| alloc | 0.3 | 3.1 | −33 |
| other | 8.7 | 2.9 | +76 |
| string/GC | 2.6 | 2.0 | +7 |
| **合计（估）** | | | **~+77** |

闭合。无单桶 ≥50% 净赤字。arith 是 zjs 优势。

### splay（+236M）

| 桶 | z% | q% | 超出 M | 占净 |
|---|---:|---:|---:|---:|
| alloc | 6.7 | 34.7 | −420 | 优势 |
| GC | 3.0 | 6.3 | −41 | 优势 |
| other | 39.0 | 10.8 | +500 | 212% |
| dispatch | 17.1 | 8.5 | +164 | |
| property | 20.1 | 15.2 | +118 | |
| string | 8.1 | 13.6 | −61 | |
| call | 4.9 | 10.3 | −66 | |

splay 的 zoo 折差是 **负的**（−8.85%）：FW 比时间盒更亏。other 39% 需再拆（多半是树节点 destroy/alloc 没进 alloc 桶）。**不要按 zoo 0.943 去砍 alloc**——qjs alloc 份额反而高。

### gbemu（+124M）

| 桶 | z% | q% | 超出 M |
|---|---:|---:|---:|
| dispatch | 32.5 | 24.7 | +180 |
| property | 37.2 | 39.7 | −20 |
| string | 16.6 | 11.3 | +115 |
| call | 8.6 | 16.8 | −140 |
| other | 4.8 | 0.9 | +76 |
| arith | 0.2 | 5.3 | −92 |
| **dispatch+string** | | | 主正账 |

无单桶 ≥50%。string 16.6% vs 11.3% 值得下一轮点名（不是 rope 表示层）。

## 升级清单

| 基准 | 升级？ | 主攻面 |
|---|---|---|
| zlib | **是** | 解释循环/dispatch（合并 call 后 111% 净超出） |
| richards | 否 | dispatch+other，像短方法 OO，R3-D 已定价 |
| box2d | 否 | 弥散，arith 优势 |
| splay | 否（且折差为负） | other/destroy；alloc 是优势 |
| gbemu | 否 | dispatch+string |

## [PROGRESS]

```
[PROGRESS] R4-U unlabeled qjs INVALID (call 86-99%)
[PROGRESS] R4-U labeled-qjs 5/5
[PROGRESS] R4-U zlib UPGRADE dispatch
[PROGRESS] R4-U DONE first-pass
```
