# Parity Ledger

**用户终局目标（2026-08-14 裁定）：zoo 每一项 ≥1.0**——不是 geomean 追平；
四个反超项是资产要守住。路线指示：以 quickjs.c 代码对照为主要分析手段。

**通用性原则（2026-08-14 用户裁定，机制准入宪法）**：
- **形态特判禁止**：按源码模式匹配收窄适用面、有悬崖效应的机制
  （如 `classifySimpleFieldConstructor`——三字段纯写体 0.871、多一个 local 即 1.161）
  一律禁止，存量按 R10 删除；
- **通用机制允许**：对同类全形态一致适用、无悬崖、**用户代码照常执行**、
  可观察面等价的机制（如 JSC 式构造分配画像、解释器 store IC），
  须登记 `PERF-MECHANISM-LEDGER.md` + 逐机制等价证明后准入。
- 本原则收编原路径 A/B 之争：B 简报的问题由此原则按机制逐个裁决，不再整体裁。

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
| raytrace | 0.777 | 0.2517 | 22.4% | **1.68 pp** | **R7 提纯钉死：`new Vector/Color`+`initialize.apply` 成对税 = 1.00G = 全部宏观超出**（z 构造税 1.41G vs q 0.42G = **3.39x**）；case 1.296→三刀后 1.002（三 pad 稳，driver CPU19 亲验 1.298/1.007） | 属性读 −24M、RC 销毁 −45M | **R7-R1 上限 +1.7pp**（simple new 的忠实路径成本对齐——⚠️不得重建已删 bypass，问题仍是「qjs 全体+帧 150cyc、zjs 194」）；R7-R2 apply（~20%，或被 R1 吸收） |
| pdfjs | 0.785 | 0.2415 | 21.5% | **1.61 pp** | dispatch +150M / string+regexp +70M / call +62M | arith −31M, alloc −19M, frontend −17M, RC −15M | backtrace 发布 14.07M；rope strict-eq 9.62M |
| earley-boyer | 0.799 | 0.2242 | 20.0% | **1.49 pp** | **R10 后诚实基线 ≈0.79**（bypass 删除 −9.08% 被 v1+v1.5 收回 ~9 成，包净损 ≤1.2%）。两桶新价：closure/var_ref +235M、GC 环 +200M——r11c 证明**两桶绑在 deriv_trees 互捕获闭包**（压扁 −631M=超额一半）| 属性读/发布依旧领先；GC 扫描节点少 35% | GC sentinel 三刀（wave-1 验收中）+ keyatom 13.5M/iterator 空扫（wave-1）+ closure 三刀（回退 13% bisect 中） |
| typescript | 0.830 | 0.1864 | 16.6% | 1.24 pp | **r12 定稿（08-14）**：GC 实为 zjs 优势（少扫 35%、trace 单价 232≈qjs 224；R4-C 的 destroy 4.19% 是长 profile 份额误乘 d16 基数=**同窗原则违例**）；**唯一命名税=`pushExactSimpleFrame` 8.4M×17.1cyc≈144M 独占**（99.87% method sloppy；符号本体 `sub sp,#0x140`+7×stp）+ A.7#6 keyatom 空循环 ~15M | 前端/编译、GC 扫描（cycle-list 少 35%） | X-10 +1.71%；pushExact 原地瘦身（r12-KNIFE 设计中） |
| deltablue | 0.870 | 0.1391 | 12.4% | 0.93 pp | 调用/帧/构造同边界 595.6M（占其赤字 80.4%） | 属性读 0.450–0.576x、allocator 0.787x | `tail_call_method` 缺失 7.06M 次 |
| richards | 0.904 | 0.1009 | 9.0% | 0.67 pp | — 未归因 | — | — |
| zlib | 0.920 | 0.0835 | 7.4% | 0.56 pp | **R5 改写：R4-U 的「dispatch+call=111%」是桶伪影**（handler 全住 tailcall_dispatch.zig，正常 opcode 工作被计入 dispatch 桶）。真相（driver CPU19 亲验）：**insn z/q=0.933（zjs 更少）、IPC 比 0.870、brmiss 1.241**——差距=分派结构的前端微架构（256-way 间接 br 的 I-cache/BTB），不是指令数 | 热体全线更短（get_loc0 12 vs 18、int add/or/sar 都更短） | 前端微架构税（R6 诊断中） |
| box2d | 0.922 | 0.0817 | 7.3% | 0.54 pp | — 未归因 | — | — |
| mandreel | 0.941 | 0.0607 | 5.4% | 0.40 pp | **audit-exec G2 −1.33%**（lane 级三 pad 同号坐实）。**H1 梯子已拆完（08-14）**：条目级分解**布局主导**——X-07 孤立 +0.21% / 叠加 −0.51% 符号翻转，X-02 孤立 −0.93% / 叠加 +0.05%；无单条语义税可回滚 | — | **登记为损失收案**：回收需对 object.zig 做逐条目 3-pad lineage（~18 构建换 ≤0.09pp，ROI 不成立）；正确性修复不回滚 |
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
| tail_call/tail_call_method 发射 | **实测上界为负**：emission+reuse 在 deltablue **−4.46%**、richards **−4.52%**（16 samples，CV 还放大 ~9x） | **CLOSED（2026-08-14 OPT-R2 H3）**。reuse handler 有两个 T0 可观察分歧（Error.stack 丢帧、深尾递归不溢出=zjs-only TCO），语义不合格；嵌套 handler 每 tail 重进 Machine（1→3-12 inits）；忠实形态（同机 pushCall+return stub）按 qjs 收益（省一次 dispatch）至多中性。**不是追平杠杆**，分支 `grok/opt-r2-h3` 不合并留档 |
| audit-exec 17 条正确性批次（`192a097d`，含 X-10 Get-miss 兜底删除） | 3-pad 中位 **+0.17 pp**（1.0018 / 0.9998 / 1.0019） | **NEUTRAL** — 正确性通道落地；低于 MDE 0.278 pp，**不登记为性能候选**。产物 `2026-08-14/zoo-ab-audit-exec-pack.json` |

⚠️ 前两项合计 **+0.06 pp**，远低于 0.3 pp 的登记线以上门槛，**不得单独打包**。

## 已封板的方向（不要重启）

- **调用边界的 12.46 cyc/call 无主后端停顿**：六条独立诊断（D1 删指令 +0.234% / D2 cache 假信号 /
  D7 首分派链 0.000% / D8 SPE 0.000% 弥散 / D9 帧复用 −0.27% / IMPL-TEARDOWN 负），
  结论是几十条短链重叠、无单点。
- **浮点表示与调度**：NaN boxing 恶化（串行惩罚 2.986→9.998）、operand 前置加载拿延迟换吞吐、
  tag-before-payload 无收益、16B 宽度不是病因、C ABI 边界已被编译器消除。
- **布局彩票**：7-pad zoo 极差仅 0.380pp，最好 pad +0.268%，且源码一改排名重排——**不是杠杆**。

## 存活假设（2026-08-14 更新：**零存活**）

1. ~~跨 benchmark 的 call/frame 固定税~~ —— **CLOSED**（08-13）。三个继续条件全不满足：
   PdfJS backtrace 税 14.074M < 20M；跨 Zoo 暴露 132.237M raw → 校准后仅 **0.1355 pp** < 0.20 pp；
   return 区域虽 13/15 基准 8/8 同向但仍是未具名区域、且与已封板的弥散调用税重叠。
2. ~~2-slot read-forwarding~~ —— **CLOSED（08-13 harness NO-GO）**。死在预注册汇编硬门：
   A2 消掉消费者内存载入，但 16B JSValue 走 GP 通道，依赖边变成 **FP→GP→FP 串行跨域链**
   （+1 条 fmov，两个冷构建一致）＝登记的 hard stop，未获 PMU 授权。
   `2026-08-13/READFWD-HARNESS-OUTCOME.md`。
3. OPT-R2 的两条新尝试同轮死亡：tail_call 发射（上界 −4.5%）、
   字符串 concat 对齐（rope 盈余在共享 lhs 的惰性 concat 本身，qjs 同样无法 inplace）。

**追平假设清零，架构边界决策（路径 A：严格 faithful 累积收敛 / 路径 B：扩大允许机制）到期。**

**OPT-R3 扫荡已完成（08-14）**：四大赤字基准（70% 净赤字）JS 函数级归因全扫，
**0 条通过「路径 A 可修、三 pad ≥0.15pp」**——pdfjs/TS/EB 热函数两侧同价；
deltablue 短 accessor 链（71% opcode）拿掉后两侧同 +85%，追平空间仅 ~0.1pp
（driver CPU 19 复测 +1.58%≈+0.104pp）。**路径 A 在 JS/胶水层扫空，残差=引擎级弥散单位成本。**
产物 `2026-08-14/R3/`。用户质疑「残差不可解释」后 A/B 曾 DEFERRED，
**R4 守恒闭合战役已把四块缺口全部关掉**（`2026-08-14/R4/`）：
- G1 TS 折差 = **前端摊销记账口径**（PMU 含 2.5MB 编译、分数只量内层；driver CPU19 亲验
  5 轮曲线平台 1.195-1.215x，GC 21=21，堆老化死）——「修 GC 回 0.7pp」不存在，
  **真内层税 1.215x 归单位成本账**；§4.2 容量→堆膨胀假设在 TS 上证伪；
- G2 pdfjs：7 桶 +215M vs PMU +216M = **0.5% 闭合**，无 ≥10% 单机制，dispatch 最大桶；
- G3 TS 782M 是旧账，现净 +132M 已点名（RC destroy/trace + pushExactSimpleFrame）；
- G4 五基准已分桶：**zlib 升级**（dispatch+call=111%），richards/box2d/gbemu 无 ≥50% 单桶，
  splay 的 alloc 是 zjs 优势勿砍、时间盒反帮 zjs −8.85%。
**解释台账已守恒闭合：赤字=分布式 dispatch/call 单位成本，无隐藏单点。**
裁决材料 `DECISION-BRIEF-path-A-B.md` **携 R4 四表重呈（RE-SUBMITTED）**；
裁决前唯一剩余路径 A 探针 = zlib per-opcode 分解（≤0.56pp，可选）。
