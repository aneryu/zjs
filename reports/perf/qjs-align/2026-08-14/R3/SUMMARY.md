# OPT-R3 四 lane 汇总（诊断，非裁决）

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R3.md` @ `93e465c3`。  
src/ 未改。修复候选只登记。CPU 19 未碰。

zjs pad0 `12bc8b8a3cb3b3c6feea8a1bea61f254caf6fde32fddc5b808d789170cf3309d`  
qjs `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`

## 结果表

| lane | phase | 状态 | 头部发现 |
|---|---|---|---|
| R3-P pdfjs | 3 | **JS 级干净** | apply / transform.apply / isSeparator 三条超额 +0.035 / +0.022 / +0.038pp。D11 getCode 已否决。60% 残差不在 JS 函数。 |
| R3-T typescript | 3 | **JS 级干净** | peek/next/innerScan/Verify 三条 +0.008 / −0.013 / +0.003pp。Verify sink 两侧同价（各 +4.4%）。teardown 可指向、禁区仍有效。 |
| R3-E earley-boyer | 3 | **JS 级干净** | 真内联 assq/number 三条 +0.010 / −0.018 / +0.026pp。IIFE 假阳性 +0.174pp 已作废。ctor/GC 在 `new sc_Pair` 算法体。 |
| R3-D deltablue | 3 | **形状已命名 / 价值未过门槛** | 短 accessor 链占 71% opcode。v3 三 pad +0.161 / +0.155 / +0.138pp 零翻转，最坏 <0.15。共同成本 +85%，追平只剩 0.14pp。无 apply 包装体。 |

## 对路径 A/B 的证据

四个合计 70% 净赤字的基准，用唯一成功过一次的方法（JS 函数级归因）扫完：

- **0 条** 通过「路径 A 可修、三 pad 最坏 ≥0.15pp」的正式命中。
- 最接近的一条（deltablue 短方法链）把 71% opcode 的胶水拿掉后，赤字只收了 0.14pp；z/q 0.868→0.880。
- pdfjs / typescript / earley-boyer 的热函数与胶水写法在两侧同价。

含义：路径 A 在 **JS 函数 / 胶水形态** 这一层已经扫空。剩下的赤字是引擎级单位成本（dispatch、GC、ctor、teardown），不能再指望再找到一个 `initialize.apply` 式的单点。这就是账本要的 A/B 裁决证据。

## R4 候选清单（只登记）

| 候选 | 来源 | 建议 |
|---|---|---|
| 编译期内联 ≤3 opcode 的 JS 访问器 | R3-D | 新机制。会让 zjs **超** qjs（独享 +85%），不是追平。若做，按「超 qjs」立项，不要写进 parity。 |
| pdfjs 60% 残差 | R3-P + D11 | 离开 JS 函数粒度。 |
| TS teardown | R3-T 指向 | 禁区 IMPL-TEARDOWN；须全新机制。 |
| EB `new sc_Pair` ctor/GC | R3-E 定位到函数 | 已有引擎级三桶；⛔ fclosure。 |

## 交付

- `/tmp/r3-pdfjs/REPORT.md` + `cases/` + `ab/`
- `/tmp/r3-typescript/REPORT.md` + `cases/` + `ab/`
- `/tmp/r3-earley-boyer/REPORT.md` + `cases/` + `ab/`（`ab/iife-invalid/` 是作废对照）
- `/tmp/r3-deltablue/REPORT.md` + `cases/` + `ab/`
- 普查原始：各目录 `census.txt`
- 消融 runner：`/tmp/r3/run_ablation.py`
