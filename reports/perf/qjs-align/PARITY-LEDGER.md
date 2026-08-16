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

## 2026-08-15 战役日汇总（官方站位更新）

实测 main@c2519a55（8 样 CPU19，absolute-c2519a55.json）：
```
geomean 0.9641（日初 0.9311 → +3.3pp）   达标 5/15
```
| 达标 | regexp 1.148 / code-load 1.115 / crypto 1.069 / **raytrace 1.068**（0.742→越线）/ navier 1.065 |
|---|---|
| 攻坚 | richards 0.981 / gbemu 0.974 / DB 0.952 / splay 0.944 / box2d 0.946 |
| 深洞 | TS 0.886 / pdfjs 0.782 / EB 0.765 |
| compute | zlib 0.925 / mandreel 0.933 |

八包合入（w3 L1 群/w4 B+C/w5 L-1/w8 **S2=战役最大单刀**/w6b L1.2/w11 F1+K2/w12 F2+GC-mark）；
七+包拒收皆有 insn 级归因（w7/w7b/w10/R16/B1/K1/w13）。
机制定谳：compute=fetch fragmentation（architectural-with-mechanism，通道 #2 对症）；
EB L1I=architectural-capacity（缩码勘察中）；⑦ teardown=architectural-final；
pdfjs=rope 承重+入口形态双阻塞。
**通道 #2 已开（用户裁）**：opcode-fusion v1 实施中（3 对，249-251）。
现役工事：fusion v1／B2（终诊）／EB 三缝审计（hotcore-size/attach/TAKE-window）。

## 2026-08-15 收官（终版实测 main@d9236521）

```
geomean 0.9711（日初 0.9311，单日 +4.0pp）   达标 6/15
```
达标：regexp 1.125 / code-load 1.109 / **raytrace 1.077**（0.742→越线带余量）/ navier 1.074 /
crypto 1.067 / **richards 1.005**（v1b 送过线）。
贴线：**DB 0.994**（差 0.6pp，明日第一目标）。
全日 11 包合入 / 13 线拒收或收档（全程 insn 级归因）。
通道 #2 opcode-fusion 两连胜（五对落袋：mandreel +2.5/DB +3.8/richards +2.4 三 pad 铁证）；
!T 战役收官（W1+W3）；负定理群定案（Entry 几何/布局/teardown/capacity）。
**明日纲要**：①DB 过线小刀；②融合扩展（槽位政策先裁：254-255 储备 vs using_* 回收）；
③对冲模型续航评估（融合干涸后再议 IC——追平型 vs 超越型之辨已明确，IC 非必需品）；
④明牌天花板三项（EB/pdfjs/splay）待完整实现型路线裁决。

## 2026-08-15 夜间矿脉战役追账（终版 main@b784d81c）

```
geomean 0.9734（全日 0.9311→0.9734 = +4.2pp，十三包）  达标 6/15
```
夜间新增：wave-19（普查双刀：get_array_el2+putarr-append→gbemu +1.5/pdfjs +0.35）、
wave-18b（shape 常量+add 溢出族→**splay +2.9/EB +2.2/TS +1.5**）。
矿脉方法论定案：用户两次纠偏（挖 qjs 策略/真因）→穷尽分解（密度证伪/热臂更短/胶水更短/
慢道单价平）→**命中率普查=产刀机**（5 刀 2 破案 1 排除）。
X-89 REJECTED-REWORK 在途（折叠正确但 tail handler 未接现代快叶→7M 调用改道减速——
接好即赢，明日头号）。冲刺带 DB 0.989/gbemu 0.987/splay 0.975 = 明日三过线候选。
- wave-20 X-89 v2（7aacae4d）：接线修复成功（DB/richards 减速归零）、折叠零增益
  （性能假设证伪：282M 收益系 qjs 形态自有）→ **按对齐价值合入，发射器 parity 100% 收官**。

## 2026-08-15 最终收官（main@6a61951e，十五包）

```
geomean 0.9737（全日 0.9311→0.9737 = +4.3pp）   达标 7/15
```
三项当日越线：raytrace 1.056（晨 0.742）/richards 1.009/**gbemu 1.0015**（wave-21d 送线）。
贴线：DB 0.9927。融合通道三连胜收官（六对在产：249-253+245/246/247）；
wave-21 系列=归因互纠范本（driver 判 245、pQ 隔离矩阵翻案 247、v2.1b 修复 richards
−3.1%→+0.7% 完全反转）。
夜間追账：15 包合入/9 线拒收档（每案 insn 级归因）。
明日：DB 0.7pp 过线（第 8 项）→splay/box2d/mandreel 融合延伸→EB/TS 守恒残段→
pdfjs/zlib 结构裁决（用户）。

## 2026-08-16 用户路线裁决（pdfjs / EB 两深沟）

- **pdfjs 0.788：先 scoping spike**（3-5 天，只设计不动产线；必答四题=qjs 赢钱来源/
  rope 消费者清单/资产哨矩阵/分段方案；负方案书也是合格产出）。简报
  /tmp/lanes/BRIEF-PDFJS-SPIKE.md，首个空闲 lane 接。spike 报告回来用户终拍全面动工与否。
- **EB 0.783：不开缩码战役**。容量墙（热体 426KB vs L1I 64KB，diet 天花板 50-70KB 不可闭）
  诚实入账为结构阻塞；融合通道+通用刀群（P6-GROW/K-ret-slim 等）连带啃食，顶预估 ~0.85；
  其余项清完后复盘。
15/15 语义澄清：EB 现无已知 faithful 路线到 1.0——此项挂「结构阻塞待复盘」，
战线主力转 DB/splay/box2d/mandreel/zlib/TS 六项可达段。

## 2026-08-16 用户终拍：pdfjs 负方案书批准

spike（pV）四题答案链采信：qjs 在 pdfjs 赢钱=native 前言 +121M（周期型，nexec 0/3 已证
insn 不兑现）+分派地板；表示层仅部分解释 +53M；删绳/推迟建绳损 crypto、停 P1 反伤 pdfjs。
**裁定：不存在资产安全的表示层全面对齐——pdfjs 与 EB 同列结构阻塞档**
（预估顶 pdfjs ~0.79 / EB ~0.85）。资源全押六项可达段：DB/splay/box2d/mandreel/zlib/TS。
通用刀（边界去帧族等）连带收益继续惠及两档案项。附：松弛定理升宪（concat+P6 两案）——
qjs 靠 malloc bin 松弛的就地优化在 zjs slab 生态一律不可移植。

## 2026-08-16 夜战收官（main@40e83160，十八包）

```
geomean 0.9801（0.9737→0.9801 = +0.64pp）   达标 8/15（DB 1.0018 越线）
```
三包连击：w22R fusion v3R（DB/splay 放置纪律）→ w24 shape 四刀+GC-ACCT（EB/TS/raytrace
退税）→ w25 fusion v4R（**zlib +4.2pp 单夜最大**、mandreel +1.3）。gbemu 0.9990 擦线滑出
（噪声距离，两次读数均在 ±0.15pp 带内）。融合通道五包在产；矩阵审判法两连功；
「岛几何家族」五证据定形（放置/墓碑/克隆三防线入宪 #8/#9）。
七攻坚位次：gbemu 0.10pp→splay 2.2→zlib 2.9→mandreel 3.7→box2d 4.7→TS 8.0→档案两项。

## 2026-08-16 战役阶段收官（main@e17517f8，十九包）

```
geomean 0.9863（两夜 0.9737→0.9863 = +1.26pp）   达标 8/15（gbemu 回线归队）
```
本轮四包：w22R/w24/w25/w28 合入，w23/w26/w26R/w27 拒案全数入册。
**两大终局裁决**：①融合通道六包收官（zlib 累计 +6pp 峰值，通道 #2 全程零违宪）；
②去帧族负定理定案（四形证据链：边界 unusual 内联体=局部性承重墙）→
**TS call+return 10.6G、box2d cyc 税正式归架构层**。
七攻坚终分类：可达段=zlib 1.1pp/splay 1.7pp/mandreel 2.2pp；
架构段=box2d/TS（faithful 刀不可达，需通道 #3 级新机制申报才可再攻）；
档案段=EB/pdfjs（用户已裁）。15/15 需用户重定义或新机制通道。

## 2026-08-16 用户裁决：目标重定义

**新目标=可达段全过线：geomean ≥1.0 且 zlib/splay/mandreel 过线（含现有 8 项=11/15）。**
架构段（box2d/TS）负定理封档长线保留；档案段（EB/pdfjs）维持原裁。
终段部署：三项各派残差审计（zlib→pQ/splay→pW/mandreel→pT），审计→刀→wave 节奏。

## 2026-08-16 用户终裁：战役收官

三审计终局采信（splay 固有/mandreel IPC 弥散/zlib 半刀）：**faithful 域已开采至极限**，
三项共同病根=分派密度弥散（musttail 每 op 一跳预测正确分支税，外提路负定理已封）。
**裁定：zlib 末刀（leftover 链扩展）3-pad 合入后跑终版计分板定稿归档**；
战役以 geomean ≈0.988、8-9/15 达标收官；负定理群/档案/审计全册留存；
舰队转维护态；通道 #3（分派密度机制）保留重启权。

## 🏁 2026-08-16 战役定稿（main@296a8c89，第二十包，faithful 战役收官）

```
终版：geomean 0.9852   达标 8/15
deltablue 1.0024 / gbemu 1.0045 / richards 1.0061 / crypto 1.0593 / navier 1.0615 /
raytrace 1.0757 / code-load 1.1102 / regexp 1.1218
攻坚终位：zlib 0.9943（距线 0.57pp 历史最近）/ splay 0.9806 / mandreel 0.9801 /
box2d 0.9471 / TS 0.9217 / EB 0.7929 / pdfjs 0.7926
```
全役跨度：0.9311/4 项（08-15 晨）→ 0.9852/8 项，**二十包合入、十余案拒收全数 insn 级归因**。
资产：融合通道六包（zlib +6.6pp 累计）、shape/GC/put 刀群、放置纪律+墓碑宪法、
负定理群（局部性承重墙四形/松弛定理两案/融合物理下限）、三终审计（splay 固有/
mandreel IPC 弥散/zlib 半刀兑现）、deliberate non-align 首例、cyc 级守恒范式。
**faithful 前沿宣告到达。** 重启点：通道 #3（分派密度机制）申报权保留。舰队维护态。

## 2026-08-16 用户令：TAILCALL-DEEP 战役开启（深挖 tail-call，以此往上）

触发=用户质疑「tail call 不应比单体差」+文献支持（CPython3.14/upb/wasm3 tail-call ≥
computed-goto）+自有疑点（zlib 2.762G 分派 vs 2.576G 多余 br≈每 op 一条，仅 23% 点名）。
**「架构段」三判（box2d/TS/mandreel+zlib 残）暂缓生效，待逐跳普查裁决翻案与否。**
四线：pQ 预算模型（静态跳数×频次 vs 实测差）/pT 逐 op 双侧 disasm 走账/
pW qjs 无跳惯用式审计（csel/ccmp）/pV 分派胶水解剖+musttail 寄存器预算。

## 2026-08-16 TAILCALL-DEEP 首胜入账（main@fc29648d，第廿一包）

```
geomean 0.9874   达标 9/15（zlib 1.0273 过线=第 9 项）
```
用户「tail call 不应比单体差」质疑开启的翻案战役：胶水/repr 双洗清、preserve_none 缺口
双实证收档（toolchain 前沿）、预算模型点名 gae/TA 主块→TA-GET 刀过线兑现。
「zlib 残差=架构」原判部分推翻：class 分发缺失是可对齐项。wave-31（TA-PUT 三合一：
写侧+GET 同形+navier 回收）候裁中——预计 zlib 冲 1.05/gbemu 加厚/navier 归位。

## 2026-08-16 TAILCALL-DEEP 两连胜（main@8d6ae58c，第廿二包）

```
geomean 0.9994（距 1.0 = 0.06pp）   达标 9/15（DB 0.9990 抖动带）
zlib 1.0817 / gbemu 1.0507 / mandreel 1.0471（新越线）
```
TA-GET+TA-PUT 两刀：class 分发对齐把三个「架构段」项打成厚资产——原「zlib/mandreel 残差
=分派密度地板」判决大面积翻案（真相=数组 class 分发形未对齐）。用户质疑「tail call 不应
比单体差」全面兑现。TA 残余普查在途（破 1.0 之刀候选）。

## 🏆 2026-08-16 里程碑：10/15（main@c7770616，第廿四包）

```
geomean 0.9962（0.996-0.999 噪声带）   达标 10/15（DB 1.0045 回线）
TAILCALL-DEEP 四刀四中：TA-GET（zlib 过线）/TA-PUT（mandreel 过线+本役最大单包）/
ALIGN-ENTRIES（box2d/gbemu）/F-RETRIAL（box2d +2/TS +0.8/DB 回线，wave-6 灭链推翻）
```
用户四次纠偏全部兑现（挖 qjs 策略/真因非取巧/底优上劣/tail-call 不应更差）。
战役自 0.9311/4 项起：**廿四包、达标 4→10、geomean +6.5pp**。
剩余：box2d 4.3pp（G 帧域）/splay 2.3pp（⑦ 固有）/TS 7.4pp（call/return）/档案两项。
守卫族卫星（add join +1×215M/get_var_ref0 TDZ+1×152M/put_array_el+2×71M）=下一捆候选。

## 2026-08-16 用户令：三期 TAILCALL-COMPLETE（tail-call 彻底化）

论点（用户「实现不彻底」）：zjs 仅 op 分派层 tail-call，调用边界仍原生递归
（op_call bl 嵌套/op_return ret 回卷）+热径 bl→ret helper 往返——「架构段」全部命名税
（G 0x3f0/TS call+return 10.6G/空调用 +17.7/call1 0x1c0）皆源于此。
彻底形=全迭代：调用/返回=musttail 续行，VM 帧承载深度语义，原生递归仅留 native↔JS 边界。
负定理不阻此路（非外提 unusual 体，是拆递归结构）。
三线：P1 bl/ret 违纪普查（pS）；P2 平坦调用设计 spike（pQ，帧生命周期硬门全程）；
P3 helper 续行形 spike（pV，upb fallback 链）。pT box2d 账/pW DB 账继续作输入。

## 🏆 2026-08-16 历史性里程碑：geomean 首破 1.0（main@0778ca47，第廿九包）

```
geomean 1.0011   达标 9/15（DB 0.9969 抖动带）
EB 0.806（hasinst +1.5pp）/pdfjs 0.813（K 捆 +0.7pp）——档案两项被正面刀撬动
```
全役自 0.9311 至今：廿九包、geomean +7.0pp、达标 4→9(10)。四期三包连落
（w36 钉线捆/w37 EB 主矿/w38 pdfjs 首刀）。w39 捆池（trace+array+cmp-eq）候齐——
TS/DB 双标的。

## 2026-08-16 第三十包（main@45f8af29）：geomean 1.0050 新高

w39 TS 三刀捆广谱兑现（navier 1.105/zlib 1.101 新高、richards 1.021、TS+DB 回升）。
攻坚终位：DB 0.9993 抖动带/splay 1.85pp/box2d 4pp/TS 7.6pp/档案 EB 0.798+pdfjs 0.801。
四期机器持续：L 捆（pdfjs ②二刀）候立、EB 几何回吐待收、TS 残段续走。

## 2026-08-17 用户裁决：五期路线＝AB 并行

A=通道 #3 分派形态机制（热路径超块/特化类通用机制，spike 先行、四条件逐审）——
最大杠杆（box2d/TS/EB/残项同标的），负定理群为设计约束；
B=native 协议瘦层（simple builtin ABI 分层重设计，设计书先行、分段落地）——pdfjs 心脏。
C（preserve_none）维持封存；D 不采。w42 双尾刀并行收官 faithful 域。

## 2026-08-17 用户裁决：EB 容量墙 = S3-B 关墙

pS 材料（EB-CAPACITY-SCOPING）判明「容量墙」本体=L1I 工作集墙（handler 岛 185.7KB+助手 vs
qjs JS_CallInternal 38.5KB 单体；refill 21.6×=139.8M vs 6.5M；FE +339M 为本墙周期上限）。
布局三轮（L-1 合/L-1.5 拒/L-2 闭)已证只重排不缩体积无效。诚实预期：S3-A 密度战役满打
+3~5pp（0.83–0.85），叠形税残余 faithful 硬顶 ~0.87。
**用户裁：S3-B 关墙**——architectural-capacity 入档，不立项、不平行刀、不把 22× 再当
handler-section 缺口；EB 过线问题并入稍后「目标可达性」总裁决（候肥 op scoping 材料齐）。
H2/P6 禁区重申：完整实现不得借 String capacity 字段或 adopt/reloc 就地扩当本墙刀形。
