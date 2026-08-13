# Parity Ledger

**所有新任务在开工前必须先报「预计 full-Zoo geomean 贡献」，并按下表的价值分级处置。**
不再按「哪个现象有趣」排序。

基准数据：zjs `42b6160f`（工作树 `18d66826`）vs qjs `04be2460`，15 基准 × 每侧 24 samples，3 车道并行。产物 `2026-08-13/zoo-absolute-42b6160f.json`。

```
geomean 0.9278     总 log deficit 1.1233     追平需相对提升 7.78%
```

追平追的不是某份报告里的 cycles，而是 `total log deficit = -Σ ln(ratio_i)`。

## 量纲校准（务必内化）

| 动作 | geomean 贡献 |
|---|---:|
| 单个 benchmark 提升 **1%** | **+0.066 pp** |
| 单个 benchmark 提升 **10%** | **+0.637 pp** |
| **PdfJS 从 0.785 完整修到 1.0** | **+1.61 pp** |
| 追平所需 | **+7.78%**（约 1.123 log deficit） |

⇒ 「找到 PdfJS 的 20M cycles」「消掉某条 handler 的 2 cycles」这类结果，
**除非能跨很多 benchmark 复用，否则从一开始就不足以承担追平目标。**

## 价值分级（任务准入）

| 预计 Zoo 价值 | 处理方式 |
|---:|---|
| `< 0.3 pp` | **只登记，不实施** |
| `0.3 – 0.5 pp` | 进入机制银行，**等待同子系统组包** |
| `0.5 – 1.0 pp` | 正式候选 |
| `≥ 1.0 pp` | 可成为主线方向 |

⚠️ 参照：D10 实测的 zoo MDE = **0.278 pp**（7 pad × 8 samples）。
低于 MDE 的候选在验收时不可分辨，组包目标应取 **0.35–0.40 pp** 以留余量。

## Benchmark 账本

| benchmark | ratio | log 赤字 | 占比 | 修到 1.0 的贡献 | 主要正赤字区域 | zjs 已领先区域 | 已命名机制 |
|---|---:|---:|---:|---:|---|---|---|
| raytrace | 0.777 | 0.2517 | 22.4% | **1.68 pp** | 调用机制合计 +515M（49.2%）、apply/arguments +249M | 属性读 −24M、RC 销毁 −45M | apply length 前缀（已落地 fb680e41） |
| pdfjs | 0.785 | 0.2415 | 21.5% | **1.61 pp** | dispatch +150M / string+regexp +70M / call +62M | arith −31M, alloc −19M, frontend −17M, RC −15M | backtrace 发布 14.07M；rope strict-eq 9.62M |
| earley-boyer | 0.799 | 0.2242 | 20.0% | **1.49 pp** | 闭包+var_ref +223M、GC 环收集 +193M、构造 bypass 准入税 +182M | 属性读 −216M、属性发布 −222M | fclosure 常驻 handler（已落地，zoo 效应零） |
| typescript | 0.830 | 0.1864 | 16.6% | 1.24 pp | return teardown 10.10x +189M、slow property resolver 3.24x +180M | resident 属性读 0.770x | — |
| deltablue | 0.870 | 0.1391 | 12.4% | 0.93 pp | 调用/帧/构造同边界 595.6M（占其赤字 80.4%） | 属性读 0.450–0.576x、allocator 0.787x | `tail_call_method` 缺失 7.06M 次 |
| richards | 0.904 | 0.1009 | 9.0% | 0.67 pp | — 未归因 | — | — |
| zlib | 0.920 | 0.0835 | 7.4% | 0.56 pp | — 未归因 | — | — |
| box2d | 0.922 | 0.0817 | 7.3% | 0.54 pp | — 未归因 | — | — |
| mandreel | 0.941 | 0.0607 | 5.4% | 0.40 pp | — 未归因 | — | — |
| splay | 0.943 | 0.0582 | 5.2% | 0.39 pp | — 未归因 | — | — |
| gbemu | 0.968 | 0.0322 | 2.9% | 0.21 pp | — 未归因 | — | — |
| **crypto** | **1.058** | −0.0564 | −5.0% | — | — | 反超，**资产需守住** | — |
| **navier-stokes** | **1.061** | −0.0592 | −5.3% | — | 旧归因是非访存后端停顿；现已反超 | 反超，**资产需守住** | stack3+typed-int 主收益 |
| **code-load** | **1.104** | −0.0987 | −8.8% | — | — | 反超，**资产需守住** | — |
| **regexp** | **1.130** | −0.1225 | −10.9% | — | — | 反超，**资产需守住** | — |

前 5 名占净赤字 **92.8%**；四个反超基准倒贴回 **30.0%**。
**五个仍落后且从未归因的基准（zlib/richards/mandreel/box2d/splay）合计占 34.3%。** gbemu 已收到 stack3 包的大部分收益，不再算未归因主项。

## 机制账本

见 `MECHANISM-REGISTRY.md`。当前状态：

| 机制 | 预计 Zoo 价值 | 状态 |
|---|---:|---|
| stack3 + int typed store（`42b6160f`） | 正式 7-lineage 中位 **+1.384 pp** | **PASS**，已落地；最坏 pad +1.070 |
| native-backtrace-publication | ~+0.04 pp | CANDIDATE BLOCKED（语义资格） |
| rope-strict-equality | ~+0.03 pp | CANDIDATE BLOCKED（上游未命名） |
| tail_call/tail_call_method 发射 | 未定价，DeltaBlue −0.484% 方向有利 | INCONCLUSIVE（新判据下未达精度） |

⚠️ 前两项合计 **+0.06 pp**，远低于 0.3 pp 的登记线以上门槛，**不得单独打包**。

## 已封板的方向（不要重启）

- **调用边界的 12.46 cyc/call 无主后端停顿**：六条独立诊断（D1 删指令 +0.234% / D2 cache 假信号 /
  D7 首分派链 0.000% / D8 SPE 0.000% 弥散 / D9 帧复用 −0.27% / IMPL-TEARDOWN 负），
  结论是几十条短链重叠、无单点。
- **浮点表示与调度**：NaN boxing 恶化（串行惩罚 2.986→9.998）、operand 前置加载拿延迟换吞吐、
  tag-before-payload 无收益、16B 宽度不是病因、C ABI 边界已被编译器消除。
- **布局彩票**：7-pad zoo 极差仅 0.380pp，最好 pad +0.268%，且源码一改排名重排——**不是杠杆**。

## 存活假设（2026-08-13 更新：只剩一个）

1. ~~跨 benchmark 的 call/frame 固定税~~ —— **CLOSED**。三个继续条件全不满足：
   PdfJS backtrace 税 14.074M < 20M；跨 Zoo 暴露 132.237M raw → 校准后仅 **0.1355 pp** < 0.20 pp；
   return 区域虽 13/15 基准 8/8 同向但仍是未具名区域、且与已封板的弥散调用税重叠。
2. **2-slot read-forwarding**（`A1/A2 codegen harness`，机器码可行性完全未知）

**目前没有已验证的追平方向。** 若这两条都死亡，需要做一次架构边界决策
（路径 A：严格 QuickJS-faithful 的累积式收敛；路径 B：扩大允许的实现机制），
**而不是继续寻找第九个微机制。**
