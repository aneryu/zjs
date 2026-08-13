# Parity Ledger

**所有新任务在开工前必须先报「预计 full-Zoo geomean 贡献」，并按下表的价值分级处置。**
不再按「哪个现象有趣」排序。

基准数据：zjs `fb680e41` vs qjs `04be2460`，15 基准 × 每侧 24 samples，3 车道并行。

```
geomean 0.9137     总 log deficit 1.3539     追平需相对提升 9.45%
```

追平追的不是某份报告里的 cycles，而是 `total log deficit = -Σ ln(ratio_i)`。

## 量纲校准（务必内化）

| 动作 | geomean 贡献 |
|---|---:|
| 单个 benchmark 提升 **1%** | **+0.066 pp** |
| 单个 benchmark 提升 **10%** | **+0.637 pp** |
| **PdfJS 从 0.778 完整修到 1.0** | **+1.69 pp** |
| 追平所需 | **+9.45%**（约 1.354 log deficit） |

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
| pdfjs | 0.778 | 0.2516 | 18.6% | **1.69 pp** | dispatch +150M / string+regexp +70M / call +62M | arith −31M, alloc −19M, frontend −17M, RC −15M | backtrace 发布 14.07M；rope strict-eq 9.62M |
| raytrace | 0.783 | 0.2449 | 18.1% | **1.65 pp** | 调用机制合计 +515M（49.2%）、apply/arguments +249M | 属性读 −24M、RC 销毁 −45M | apply length 前缀（已落地 fb680e41） |
| earley-boyer | 0.798 | 0.2253 | 16.6% | **1.51 pp** | 闭包+var_ref +223M、GC 环收集 +193M、构造 bypass 准入税 +182M | 属性读 −216M、属性发布 −222M | fclosure 常驻 handler（已落地，zoo 效应零） |
| typescript | 0.827 | 0.1898 | 14.0% | 1.27 pp | return teardown 10.10x +189M、slow property resolver 3.24x +180M | resident 属性读 0.770x | — |
| deltablue | 0.871 | 0.1377 | 10.2% | 0.92 pp | 调用/帧/构造同边界 595.6M（占其赤字 80.4%） | 属性读 0.450–0.576x、allocator 0.787x | `tail_call_method` 缺失 7.06M 次 |
| zlib | 0.903 | 0.1022 | 7.6% | 0.68 pp | — 未归因 | — | — |
| richards | 0.908 | 0.0970 | 7.2% | 0.65 pp | — 未归因 | — | — |
| mandreel | 0.910 | 0.0943 | 7.0% | 0.63 pp | — 未归因 | — | — |
| box2d | 0.913 | 0.0909 | 6.7% | 0.61 pp | — 未归因 | — | — |
| gbemu | 0.917 | 0.0869 | 6.4% | 0.58 pp | — 未归因 | — | — |
| splay | 0.945 | 0.0566 | 4.2% | 0.38 pp | — 未归因 | — | — |
| navier-stokes | 0.971 | 0.0296 | 2.2% | 0.20 pp | 非访存后端停顿 +205.8M（浮点串行链） | 指令数 0.9645（少干活） | — |
| **crypto** | **1.057** | −0.0552 | −4.1% | — | — | 反超，**资产需守住** | — |
| **code-load** | **1.094** | −0.0898 | −6.6% | — | — | 反超，**资产需守住** | — |
| **regexp** | **1.114** | −0.1080 | −8.0% | — | — | 反超，**资产需守住** | — |

前 5 名占总赤字 **77.5%**；三个反超基准倒贴回 **18.7%**。
**六个基准（zlib/richards/mandreel/box2d/gbemu/splay）合计占 39.1% 但从未被归因过。**

## 机制账本

见 `MECHANISM-REGISTRY.md`。当前状态：

| 机制 | 预计 Zoo 价值 | 状态 |
|---|---:|---|
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
