# OPT-R13 计划 — 自底向上优化战役（用户方向指示）

## 📊 2026-08-15 全日战果结算（六波验收，五合一拒一挂）

合入 main（时序）：wave-3（L1+S1R1+G1，raytrace ×1.34）→ wave-4（B+C，EB +0.5%）→
wave-5（L-1 布局，pdfjs +1~2%）→ **wave-8（S2 资格位，EB +7.5%/raytrace +7%=战役最大单刀）**→
wave-6b（L1.2 去税，DB/richards/TS +0.8~1.6%）。现 main@82bea336。
拒收：wave-7（nexec 铺开=native 重基准通用税，退回逐域立据）；wave-7b（R17 单包=**R17×S2
交互反转**，EB insn +431M 铁证）。挂起：R16 四刀（zoo≈0 且分支体积机制链 zoo 判决失败）。
**追记：wave-10（nexec-slim 帧肥已修版）仍三 pad 全同号负（geomean −0.7~0.9%）→
nexec 计划关闭（0/3 zoo）**：insn 战果无法兑换周期，native 入口周期账不在指令数。
**错案更正（深夜，pW 查明）**：R17「EB insn +431M」系我方基线件混污（base-cur 含 wave-6b，
建件未核 commit→合同补『记 git rev』条款）。净判：T1-T4=insn −62M/cyc +34M，
**T'=T4 单刀采纳入下捆包**，T1-T3 归档。B2 第一刀验尺 FAIL（richards insn +88%=
Simple 判疑似永假全走回退臂，功能级 bug 退回 pV 修复）。
K1 shape 谓词对齐反噬（insn +2.1%）=谓词不可跨 shape 体系直译，归档。
pdfjs 结构阻塞定格（string 表示层+native 入口周期形态）。
今日新范式：**独占符号周期≠可回收周期**（v1 壳/K2 壳/nexec 三案）——桶顶今后标 insn/cyc 双口径。

## DB 残账 mini 图（2026-08-15 深夜，driver 亲测 perf report）

DB 0.952 残余=分布式 per-op：z 六符号 76%（get_field 20.3/get_field2 18.9/call_method 15.7/
return 9.2/pushExact 6.6/opLoc 5.3）vs q JS_CallInternal 93.45% 单体。属性读双 op 39%=DB 形。
**裁定：不立 DB 专项**——搭三把在飞架构刀的便车（B2 吃 pushExact 份额、fusion 吃分派密度、
L-1.5 吃 I 足迹）。与 R15 判决一致（richards/DB 挂架构线）。

## pdfjs 表示层范围界定（2026-08-15 深夜，driver 亲勘 string.zig:222）

事实修正：zjs 平 String **已逐位镜像 qjs JSString**（12B 双 u32 位域 LenMeta/HashMeta、
rc 前缀 −4 = JSRefCountHeader 对位）。真分歧=**rope 层的存在**（StringRope 独立对象/独立 Tag）
vs qjs 无 rope（concat 即平铺 + JS_ConcatStringInPlace 的 usable_size 松弛就地追加）。
完全对齐=删除 rope 全层（Tag 空间/GC/全部消费者）=**完整实现型**（13 项清单同类），
且收益顶只把 pdfjs ≈0.86→0.90（native 入口周期形态仍挡最后一段）。
**裁定修订（同夜）**：①rope 删层否决——rope 是 regexp/crypto/code-load 反超的承重墙
（rope 门透传战功在案），删层救 pdfjs 会赔达标项；②**增量刀入队：ConcatStringInPlace 镜像**
（qjs:4671，flat∧rc==1∧malloc_usable_size 松弛→就地追加）——**不违 H2**（qjs 也无 capacity
字段，靠分配器松弛）、不删 rope，pdfjs FW ~16M+concat 体连带，全场 string 追加受益。
排队：现役六线首个空闲 lane 接设计简报。pdfjs 全达标仍需入口形态段，明牌保留但路径列全。
15/15 归属矩阵完整。

## compute 之谜闭案（2026-08-15 深夜，STALL-TAXONOMY §6）

zlib/mandreel/box2d = **architectural-with-mechanism：fetch fragmentation via 条件分支密度**
（br/insn +29%、间接跳密度与 qjs 同、mis 率同、I-cache 不 miss、FE stall 79%——五假设四证伪后
唯一与全部现象相容者；无 taken 细分 PMU 事件，不再量）。**faithful 刀不可达。**
宪法级观察：此墙**并非绝路**——08-14 通用性原则设立的 PERF-MECHANISM-LEDGER 四条件通道
（通用机制/用户码必执行/可观察等价/zoo 验收）原则上容纳「通用取指密度改良」类机制
（如高频相邻 opcode 融合=JSC/V8 均有先例），与「形态特判禁止」不冲突。
是否开启此通道打 compute 墙+EB ⑤，**留待用户裁决**（涉及路线级别取舍，不自行启动）。
**→ 用户已裁（当日）：通道开启，opcode-fusion 为条目 #2 首个申报**（四条件文入 LEDGER；
设计简报 pQ：全 zoo 并集融合对/emit 期 peephole 选型/槽位预算/poll 边界清单）。
gbemu 图同日收档（1.063/+114M，zlib 同病）→ 碎片化墙圈定四项+EB ⑤，全部划归本通道战场。
方法论沉淀：①第 14 条分层 pad+并行测量（8 核同测，验收吞吐 ×5）；②insn 差分=语义/布局定谳器
（regexp −2.75% 洗清、R17 +431M 定罪同一把尺）；③包基线必须同 commit+同构建目录；
④「组件 FW 冒烟全绿≠包级 zoo 通过」两次实证（wave-7/wave-6）。

日期：2026-08-15。状态：**Phase 0 立即启动；Phase 1 各梯级在 wave-2 合入后的新基线开工**。
指示原文：「从低层向上优化」。与 R8（自底向上**定价**）衔接：R8 量了每层的价，
R13 按层**修**——从最低付费层向上，每梯级 FAITHFUL（qjs 结构/布局镜像），修完一层重定上层价。

## 0. 底层付费点清单（R8/R9/r12 已知，待 Phase 0 真基线重定价）

| 层 | 付费点 | 已知量 | 状态 |
|---|---|---|---|
| L7 帧 | **Entry 256B vs qjs JSStackFrame 72B**（10·§1.1/§16.1；r12 判「12.1 cyc 地板=Entry 填充+memset」） | 每次调用固定填充/拆除 | **R13 第一刀候选**（原「不要动」标记因自底向上指示解除，须独立设计简报） |
| L7 调用 | 空调用 Δ+18（wave-2 pushExact 后重测残余） | ~18→? | Phase 0 重测 |
| L8 构造 | N0 残余（R9 后 1.425） | +70 级 | Phase 0 重测→分解 |
| L7 拆帧 | teardown（旧锚 19.26vs1.93 已废，真值未测） | ? | Phase 0 重测 |
| L1 分派 | 前端涌现税（fe_stall 46-85%，compute 四基准） | ~2pp | 布局批 PAUSED 等用户；非布局缓解=pushExact §c（已在 wave-2） |
| L4/L9 | RC/GC 残余（wave-2 GC 刀后重定价） | ? | Phase 0 |

## 1. Phase 0 —— 真基线价目重定（pS，立即，诊断）

R8 全套价目是**旧世界**（带 bypass、无 R10/wave-2）数字。在 true 二进制上重跑
R8-V/M/P/C 阶梯（案例与工装全在 /tmp/r8-*），产出「真价目表 v2」：
每层 z/q + 与 R8 旧值对照 + wave-2 合入后再跑一遍增量列。
交 /tmp/lanes/r13-PRICES.md。合同：CPU 16、ABBA≥8、数字非裁决、指纹验证二进制。

## 2. Phase 1 —— 梯级刀（wave-2 后逐个设计简报→批→实施）

1. **Entry 几何对齐**：qjs JSStackFrame 九字段（qjs:407-420）vs zjs Entry 256B 逐字段
   映射（r12-KNIFE 已列 ownership/cold/arena_mark/teardown/return_action/planned_stack_bytes/
   Stack 整对象为 zjs 多出）；设计简报必答：每个多出字段的承载理由/能否并位/
   能否迁移到 Machine 级或 comptime；**帧生命周期红线全程**（ReleaseSafe+全量 gate）。
2. N0 构造残余分解（R9 未尽段）。
3. teardown 真值重测后视数字立项。
4. 每落一刀→上层重定价→下一刀。布局批始终 PAUSED 等用户裁决。

## 3. 结果表（滚动）

| 梯级 | 状态 |
|---|---|
| Phase 0 重定价 | v3 已交：pushExact 落点=DB at/size 1.15→1.03；空调用 Δ+18 未压（归 R13-B 域）；N3f 无回收 |

## R13-B B1 计划终局（2026-08-15 深夜）

B1（192 单池）三轮定谳：几何增益真（TS +0.4~0.5%/raytrace +0.8~1.5% 三 pad 同号）但
**打包税无解**——richards insn +1.30%（packed）→+0.90%（热字段平）→全平下限 208 仍 +0.50%，
±0.2% 无税尺不可达。B1/B1'/B1'' 终止归档；产出=打包税定价+冷字段清单+几何增益实证，
全部转为 **B2 双槽设计输入**（128 平字段 simple + 256 Wide 原样、comptime 选槽零分支，
简报已派 pV）。教训入册：**Entry 几何收缩的可行域=按调用形分槽，不是单池压缩**。

## R13-B 裁决（2026-08-15 driver 批设计）

pV 简报结论采纳：256B 中 ~72B 对位 qjs 九字段；目标=双槽 **热 simple 128 + Wide 256**
（S1 拉回 open_var_refs → 128 须留 8B；L1 native_caller/ctor completion/tail overlay 钉 Wide；
G1 停写纪律保持）。预期热 method 1–3 cyc（非 A_direct −18）。
**批 B1（单池 192 验证几何税）→ 3-pad 过 → B2（拆 128/256，选槽必须 comptime 定死）。240 禁入。**
帧改动铁律：每刀全量 gate + ReleaseSafe。分支 grok/r13b-stride 基 wave-3b 树。

## R15 冲刺区判决（pS 守恒图，driver 采纳）

richards 0.9817 / DB 0.9553 的剩余超出中 L1/S1/R1 空靶、G1 仅两笔空 slice 停写
→ **wave-3b/wave-4 带不过线，不立专项，全挂 R13-B（Entry 几何）与布局批 L-1**。
战略含义：R13-B + L-1 两条架构线现在承载 richards/DB 过线 + TS 段 + EB ⑤ 段 + compute 四件套。

## Wave-3 终裁（2026-08-15，main@3a8bc79e 合入）

包=v2-L1（rebase 版 5 commits）+ r14 S1/R1 + R13-A G1。gate 0/49775、test-exec 465、SAFE 绿、
lint 同位。3-pad pkg/wave2：geomean **+1.60/+1.81/+1.82% 同号**；
**raytrace ×1.3349/1.3446/1.3510 = 绝对 ≈0.997 到追平线**；EB +0.82~0.84% 三 pad 极窄。
**五负项消融归因（5 binary×5 bench×8 样交错 FW）：税全在 L1**——noL1 列五基准齐归零（±0.2%），
L1 多执行 insn DB +2.5%/richards +2.0%/TS +1.2%（非 apply 调用点付分析/改写钩子税）；
noG1 反常放大按单建布局伪影记。裁决=全量合入+**L1.2 去税立项 pV（最高优先）**：
非 apply 调用点零边际成本，验尺=消融同款 insn 归零 ±0.3% 且 take≈2.45M 不丢。
临时凹陷记账：DB ≈0.940 / richards ≈0.966 / TS ≈0.868（恢复线=L1.2+R13-B+R16）。
合入后推算站位：geomean ≈0.947、raytrace ≈0.997、EB ≈0.718。
队列：wave-4（B+C）3-pad 已上 CPU 19 → wave-5（L-1 单包）→ B1 3-pad → thin-entry 视 v1b。

## splay 守恒图裁决（2026-08-15，图=/tmp/lanes/SPLAY-MAP.md）

站位 0.9334（FW 0.8555=R4-T 折差，setup 8000 在 FW 内）。超出 +226M 十四桶守恒 100%：
**⑦ RC teardown +121M=54% 是唯一大洞**（destroyFromHeader 219 vs free_property 85=2.6×/对象）；
GC 环已平（+1.8M，wave-2 sentinel 后无环超额，**drain/C 刀在 splay 无可吃**）；
R16 可吃仅 ≤11M；nexec 空靶；创建路径已对位（+11M）。
裁决：**不为 splay 立专项**；⑦ 的「禁区」复核令已发 pS——代码级对位审计（只析不改），
产出「可忠实镜像 vs ownership 固有」判决：镜像→R17 teardown 刀提案；固有→splay 顶 ≈0.93
与 pdfjs 同列结构阻塞诚实入账。
**审计裁定（当日）**：桶级实为 1.78×（276/155）；可镜像 **T1 游标 pr++/T2 推迟 plan/
T3 瘦 unlink/T4 freeAssumePhaseNone** 顶 50–85M → splay ≈0.94–0.96；1.0 仍固有阻塞
（空终止链+每对象记账+tagged 16B+对象图体积）。**R17 已批派 pQ**（基 4290f89b，
全场拆毁单价刀非 splay 专项，T3 弱引用/FR 交叉测试强制）。结构阻塞名单定格：
pdfjs（string 表示层）、splay（teardown 固有段）——两项现刀程序顶 ≈0.86/≈0.95。

## 主干家务（不阻验收，待批处理）

1. fmt 尘埃：`src/exec/small_inline.zig`、`src/exec/standard_globals.zig` 两文件 main 上即不合
   `zig fmt --check`（wave-3b 验收时发现，未混入包）。
2. ⚠️构建首建漂移（wave-6/7 两见）：worktree 分支切换后**首次** RF 构建的 sha 与其后一切复建不同，
   复建即收敛稳定（wave-6 f93ab→229252×3；wave-7 29253d→13b8be=pad0）。机理未查（疑生成文件
   路径依赖）。协议：**验收指纹一律取复建后 pads 族，首建 sha 不作指纹**。待查根因。
3. X-01 RS 口径：单测「RegExp compiler stack overflow」期望钉 Debug/RF 窄递归预算；
   ReleaseSafe 在 v-mode ×1000 合法偏向 qjs（v-no throw，qjs ×5000 才爆）→ main-RS 该测预存 FAIL
   （pV 亲验 main/B1 同文）。修法：按 optimize 模式分口径或放宽。

## pdfjs 守恒图裁决（2026-08-15 driver，图=/tmp/r11/PDFJS-MAP.md）

站位 0.7884=runtime 比（FW 1.1885/+209.5M；compile zjs 反赢 43M 被时间盒摊没）。
四桶：① op 分派 +84（L-1 顶 15–40M）/①′ 碎符号 +73/**② native 前言 +121（最大单口，
nativeMethodFastDispatch 77+stringCall 23+record 30=134M vs js_call_c_function 13M）**/
③ string 体 +53 钉死（intern 不成立=qjs 无单字符驻留、append 归 H2 禁区）。
裁定：**② 立通用刀 native-thin-entry**（全 native 对齐 js_call_c_function 薄入口，
非 pdfjs 专项——raytrace/DB/richards/regexp 边界横向受益），设计简报已派 pQ；
L-1 范围不扩（native stub 同页=L-1.5 候选等页数仪表）。
诚实结论：L-1+② 乐观全兑现后 pdfjs ≈0.88–0.92，**到 1.0 还差 string 表示层的
完整实现型对齐**（rope vs qjs flat+usable_size），归档待议。

## 布局批 L-1 机制交付（2026-08-15，pT 3b238c2d 基 665e1468）

源序单一 `.text.zjs.op_handlers`（含 get_arg*）+撤 1MB pin；**musttail 305 臂 0 破链**；
**zlib 27-op 跨页 269→6.05（qjs 5.5，机制层打平）**。单机 FW 近零=布局刀单 binary
不可裁（宪法）。fe_stall PMU 确证已令补（fe 份额不掉→L-2 预期下调）。
**包队列：wave-3b（zoo 中）→ wave-4（B+C，合规绿+pads 就绪）→ wave-5（L-1 单独成包，
不与语义刀混归因）。**

## Wave-13 L-1.5 终裁 = 布局计划全线终局（2026-08-15 深夜）

L-1.5（183 函数并集宽聚簇，apply-set 906→104 页）三 pad：geomean −0.16~0.32% 同号负、
mandreel −1.2~1.5%/zlib/TS 同号负、EB ≈0。**REJECTED**。
死因=**容量现实**：热核 426KB ≫ L1I 64KB——页聚齐但装不下就无命中收益，重排反扰动偶然局部性。
布局计划总账：L-1 合入（确定性+pdfjs +1~2%）／L-1.5 拒／L-2 闭。
EB L1I 22× 定格 **architectural-capacity**（唯一理论出路=缩码体积）。
R17/T4/concat/L-1.5 同夜四线收档：负结果都是地图。存活工事=fusion v1（压轴）+B2（修复中）。

## Wave-5 终裁 = 布局批两阶段收官（2026-08-15）

L-1 三 pad：geomean 1.0001/1.0003/0.9996 中性；**pdfjs +1.51/+2.03/+0.82 三 pad 同号**
（① op 分派桶 15-40M 预估兑现）；box2d 混号（L1I 0.821 未兑现进分数）。
**ACCEPTED 合入 main**：pdfjs 单项收益+零代价+布局确定性（压全场彩票方差）。
**L-2 频次版正式关闭**：机制（页几何→fe）已证伪、L-1 其余全平——两阶段裁决的
「后评估」结论=不做。compute 战线全部押注 R16 guard 批（zoo 判决在 wave-6）。

## L-1 fe_stall 确证 ⚠️ 机制链证伪（2026-08-15，pT layout-L1-FE）

跨页 269→6.05 页后 **fe 不掉**（zlib 1.005/mandreel 1.111/box2d 0.964；Δcyc 噪声内），
L1I 仅 box2d 真掉 0.821×（原 10× 那条）。**「页几何→fe_stall」＝候选 a 机制链证伪；
L-2 频次版预期正式下调。** wave-5 三 pad 照跑（布局确定性价值 + box2d 一线希望 + zoo 终裁）。
compute 前端税重开归因：新假设=分派形态 BTB（zlib brmiss 1.24/IPC 0.870 旧账；
305 处 handler 尾独立间接跳 vs qjs 单函数），pT 已派 site 级 brmiss 三方归因，
须与 monolith no-go（91 臂 PMU 4/4 回退）合读——裁「可修 vs 真 09 地板」。

## ⭐ compute 前端税真相（2026-08-15，pT zlib-BRMISS，三方 site 级）

**mis 率三方同 0.054% → 税=分支体积 1.20×，非可预测性、非 BTB 形态、非布局。**
miss 落 51 个热 handler 体（前 6 吃 50%，入口窗 28%），非 305 尾 br；
qjs 83% miss 在 JS_CallInternal 体（set_value/NewInt32）非 goto；L-1/W2 miss 1.005（布局无关再证）。
与 insn 0.933 合读：zjs 指令更少但 branch-heavy=**分散 per-op guard 乘数**（旧账复活，
qjs switch(class_id) 臂序免费 vs zjs 顺序链）。
改判：「09 地板」一大截→可命名 per-op guard 超量。**R16 guard 瘦身批**立项前置：
pT 在做 per-op 分支体积账（超量分支×频次预算表，逐条注来源与 qjs 为何不需要）。
monolith no-go 结论不变（全单体仍禁）；可修域=handler 体内 guard 链，非分派形态。

## 布局批裁决（2026-08-15 用户）

**两阶段：先结构性聚簇，3-pad 验收后视残差再议频次版。**
Phase L-1（开工）：全部 op handler 进单一命名 section、确定性排序（结构序非频次序），
`get_arg*` 家族随 section 自然归位。忠实性论证=镜像 qjs 单函数解释器「热码同页」结构性质。
硬门：musttail 链 disasm 逐臂验证（noinline 破 musttail 前科）；gate+ReleaseSafe；
3-pad 同号裁决。频次版（Phase L-2）待 L-1 残差评估，若上，剖面语料必须中性（非 zoo）。

## R10 官方真定损（2026-08-15，指纹验证三 pad，替代此前全部幻影数字）

geomean **0.9863/0.9864/0.9866**（三 pad 离散 0.0003，真损 −1.36%，账面 geomean ≈0.9166）。
EB 0.8969/0.8916/0.8863；**raytrace 0.9275/0.9212/0.9162**（第二大洞，三 pad 同号）；
splay −1.7~2.4%；zlib −1.2~1.6%；TS **+0.9~1.0%**（v1.5 在 TS 的小赢显影）；资产无损。
回收对位：EB←wave-2（终审接力中）；raytrace←wave-3 v2-L1（合规已全绿，方向 +37%）；
splay←wave-2 微刀覆盖面。

## Wave-2 判决（2026-08-15，@665e1468 合入，gate 0/49775）

3-pad **+1.85%/+1.93%/+1.78% 同号 ACCEPTED**。账面 geomean ≈ **0.9336**（超越 R10 前 0.929）。
DB **+9.5~9.9%**（→~0.96）/richards **+8.4~9.5%**（→~0.985）/TS +3.2~3.9%（→~0.86）/
box2d·gbemu·splay·mandreel·pdfjs 小正/raytrace +1.7%（仍 ~0.73 等 wave-3）。
资产：crypto pad3 单翻号=布局、regexp 混号轻负挂观察、code-load/navier 中性。
**EB 三 pad ≈0——分桶冒烟有效但分数未动（尸检已派 pQ）**，EB ~0.71 现为最差项。
pushExact 刀=本波最大功臣（DB/richards/TS 三兑现）。
Wave-3（v2-L1+G1）组装完毕 @77b70583，全链验证在途——raytrace 的关键一战。

## 终夜三闭案（2026-08-15）

- **R13-B 全案收档**：B1（打包税 +0.9~1.3%）+ B2（双池双重安装 +58 insn/叶=命中叶 186 vs 128）
  双路实证 Entry 几何在 ±0.2% 无税尺下不可收缩。256B 维持。
  **v3 终审（b4c8f9d4）**：return 直打 128+grown/cold 逃逸臂全绿仍 richards insn +14.88%——
  设计自由度用尽，三振终止，负定理定案。
- **EB ② attach 收档**：幻觉（创建微案 z 反赢 0.89-0.91、insn 对 q 持平）。
- **EB ①′ TAKE window 收档**：insn-实但 IPC 8 已榨干、无收形（valueReplace 已内联、倒序更差）。
**EB 命名缝全部勘毕。存活杠杆=fusion v1（⑤ 段）+ hotcore 缩码勘察（capacity 段）。**

## Wave-14 fusion v1 首战判决（2026-08-15 午后）

三 pad：**mandreel +1.4/+2.7/+1.9%、navier +0.8~1.3% 同号正=通道 #2 机制首次实弹兑现**；
code-load −2.0~2.2% 同号负=**emit 期 peephole 编译税（insn +11M 定罪）**；
zlib pad3 0.7884 单 pad 灾变=**insn −463M（省的）纯布局洗清**（取指脆弱极端彩票）；
geomean −0.1~1.0% 同号负 → **REJECTED-REWORK**。
v1.1 指令：融合判定并进 emit 单遍（qjs 形，禁二次扫描），验尺 code-load insn ±2M；
三对/硬门不动。zlib 彩票随 v1.1 布局重掷。
同时段：!T W2=中性不入包（insn 持平）；W3（setup 暖臂）放行；wave-15 池=W1（−560M）±W3。

## 矿脉战役判决群（2026-08-15 晚，用户两次纠偏后的正面解答）

用户命题「底优上劣未解释」的穷尽式分解结果：
- 密度案：**z 执行 op 反而更少**（indir 全 <1，EB 0.905/splay 0.807）→ 发射器无罪
  （peephole 清单证 faithful 对齐已完成，唯余 X-89 tail_call=282M 全场动态、实施中）；
- 每 op 1.33×：热臂总 insn 更短 ✓、musttail 胶水更短 ✓ → **税在肥 op/慢道**；
- 命中率普查：qjs 自己 EB get_field2 也仅 25.2% 快 → **钱在慢 helper 单价**
  （zjs property tail vs JS_GetPropertyInternal，对比令已发）；
  唯一真谓词窄点=add 溢出掉 cold（刀已派）；DB 非命中率洞（FW 已平）；
  **zjs 热体零容忍实证**：+24B BSS 即 DB 翻倍——物理约束非教条。
现役：X-89（282M）、add-overflow 刀、慢道单价对比、shape 常量（wave-18 池）。

## 命中率普查终判（17:46 定稿+S2 探针形补测）

zjs 运行时快% 拿到（S2 sie/dgr 探针形绕开热体零容忍）：**谓词全景 zjs 大胜一处大败**——
get_field2 EB +66pp/put_field EB +96pp/get_array_el zlib +100pp（zjs 宽臂吃掉 qjs 的 CASE 慢）；
**唯一 S2 类漏斗=put_array_el**（pdfjs 1.4% vs 26% =−25pp、EB −12/TS −10/gbemu −8 连坐，
98.6% 掉 op_put_array_el_cold）。追凶令已发（拒因分布计数→状态位维护分歧点名）。
sie=0 全场（S2 修复域干净）。**pdfjs 阻塞区外首把候选真刀。**

## splay 重归因 v2 裁决（2026-08-15 夜，pW，图=/tmp/r11/SPLAY-REATTR.md）

main@6a61951e：FW 1.223/+308M 闭合 100%（cyc+insn 双口径）。
- ⑦ teardown +159M=52%（insn 1.54× 实）：**墙定格不动**，R17 收档结论维持。
- **⭐⑥ GC 桶爆点：+122M cyc/+222M insn（旧图 wave-3 时 +1.8M 已平）**——z 侧绝对量涨
  ~120M，insn-实。两种可能：当日包回归（嫌疑窗 wave-4 C 刀..18b）或旧图分桶伪影。
  **断代令已发 pW**（三现成件 b784d81c/8235ae42/6a61951e 免费三分 + 中间点二分）。
- 18b 战功改记：⑪ alloc +31→−16 与 ⑧ create（shape 初值对齐），**非 teardown**。
- ⑫ 分派已是负桶（−11c/−62i）：L-1+融合六对在 splay 全兑现。
主干家务①落地：fmt 尘合入 **main@d679dd6a**（test-exec 473 绿）。
R13 Phase 0 v4 重定价开跑（48 case@d679dd6a，CPU 19，对照 v2 价目）。

## R13 Phase 0 v4 重定价 + 18b 暴露税统一案（2026-08-15 深夜，driver 亲测）

价目表=/tmp/r13v4/PRICES-v4.md（main@d679dd6a，48 case，对照 v2）。
- 🏆 N3f Δ+59→**+7.4 到平**：S2+融合+构造刀群在最底层兑现。空调用 Δ+17.7 逐位同=架构常数。
- 🚨 **P6 add-tail 1.015→1.599（Δ+200/obj，insn 语义实）**：断代（四现成件）→窗口=18b shape
  常量刀（4→2/hash 6→4）。qjs 同初值同扩容只付 +14。perf 付款人=relocateShape 7.5%+FAM
  create/destroy ~15%+adoptShape 11% = **每对象「新建 shape+拷贝+销毁」整活 vs qjs 共享
  transition 命中+摊销 realloc**。
- **pW splay ⑥ 断代三角闭合**：GC 桶 +74M 大跳同在 18b（W3 381→现 472-477；20/21d/C 刀无辜）。
  统一假设：扩容路径共享复用 MISS→每对象克隆 shape→P6 重建价+GC 多 shape 可追+teardown 连带。
  **P6-GROW 刀已派 pS**（简报 /tmp/lanes/BRIEF-P6-GROW.md；第一步=transition 命中率+存活 Shape
  计数双探针定刀形；⛔禁回常量——18b 三连涨保持，只修单价）。
- zoo 未塌原因：ctor 走条目 #1 profile、字面量走 define_field；裸 {}+加属性形态独付。
  刀价值=退 18b 资产税（crypto/raytrace/navier −1.5~2%）+splay/EB GC 段+全场扩展对象。

## !T 战役收官（W5 干涸，2026-08-15 深夜）

W5 三刀：W5-1 −6.8M 交叠/W5-2 +48.7M 不交叠负/W5-3 +2.4M 交叠（test-oom 21/21）。
裁决：全部不入包，lane-w5 封存；战役以 W1（−560M）/W3 两刀在产收官。
负定理入册：**「TS 0.913 弥散不是 error-union ABI 能切的」**（W2/W4/W5 三轮实证）。

## 家务进展

②X-01：pV 诊断（test-exec 无视 -Doptimize 钉 Debug；v×1000 是 Debug 胖帧校准物，RS 992B/帧
吃得下且 qjs 本来 accept）→ driver 修测例=v 深 1000→4000 恒溢+新增 ×200 accept 哨；
Debug 473 绿，RS 复验排队（w22 建件后）。①fmt 已合入 d679dd6a。③首建漂移 pV 在查。

## wave-22 终裁（2026-08-16 凌晨）＝REJECT-REWORK（放置）

fusion v3（240 get_field_field2/242 get_var_field/243 get_loc2_field2 + using sub 3-5 腾槽）
@2c70c471，整合 45c3af94，gate 0/49775 绿。3-pad：geomean +0.07/+0.16/+0.29 全正、
**DB +0.36/+0.69/+0.25、gbemu +0.47×3 兑现**；但 **splay −1.25% 三 pad 逐位同幅**→
driver insn 判别器 splay FW **平（−0.019%）**=非语义，**新 handler 挤动 L-1 岛存量几何的
取指外部性**（R6-K 第四证据；w21d 加 handler splay 反 +0.5%=放置彩票对照）。
返工令：新 handler 移岛尾保存量偏移。若立功→融合硬门第八条「新 handler 一律岛尾追加」。
regexp +2.8~4.6 三 pad 正未究（非裁决关键）；code-load −0.14~0.33 观察。

## CONCAT-INPLACE 预备 REJECT（2026-08-16 凌晨，pW feb079c3）

落地忠实（qjs:4671 全谓词+新单测 6 项）但 pdfjs insn **+149M**（预期 −16M 反向）、资产哨平。
pW 自证机制：GPA 大块无 usable-size 松弛→长累加器仍走 rope；短串白付准入检查。
待命中计数闭案（第 9 条频次立据）。预定档案定性：**qjs:4671=copy-concat 基线专属优化，
zjs rope 基线+slab 精确分配无松弛生态位→deliberate non-align 首例**（rope 经济学优先）。

## CONCAT-INPLACE 终裁（2026-08-16 凌晨）＝REJECT-ARCHIVE + deliberate non-align 首例

第 9 条频次立据：pdfjs admit 12.5M/hit 58k（0.47%）/rc 拒 91.6%；crypto hit=1。
定性：qjs:4671 在 zjs 生态双重不成立——①rope 基线已 O(1) 优于 copy-concat；②pdfjs 左串
rc>1 占 91.6%（qjs 同谓词也无从就地）。**qjs:4671 记 deliberate non-align #1**（rope 承重墙
战功在案）。分支 feb079c3 封存，6 项单测+谓词镜像留档。教训：镜像刀立项前先问
「qjs 这优化赢的是它自己哪个基线」——基线不同优化不可移植。

## R16-F/G 终表裁决 + 「边界去帧」刀族立项（2026-08-16 晨）

pT 表（只析未改，新口径「dispatch 落点→被调第一条用户指令」）：
- **F 桶点名毕**（F1 信任指针/F2 atom#31/F3 无哈希短接=box2d 94M 分支）但 box2d insn 平
  （1.003）/cyc 1.049 → 分支体积不是 insn 账，wave-6 灭链前科 → **F 刀挂档不开**。
- **G 桶换口径成立**：op_call_method 落点即建 0x3f0（1008B）帧，叶路径进被调前又拆
  =「帧为承认而建」，Δ≈+40 insn/次 ×1.76M。
- **H 桶（下一 ≥50M）**：mandreel call1 13.07M×0x1d0 同病；mandreel insn 反赢 −689M 而
  cyc 1.041=入场帧压 IPC。
- 裁决：**G+H 合并立项「call 入场去帧」→ pT**（模板=K-ret-slim cold_table 拆法）；
  与 pV 的 op_return 同族=**边界去帧刀族**（返回边已落地待裁，调用边在制）。

## wave-23（K-ret-slim @de8449b0）上裁决台（2026-08-16 晨）

op_return 10016B/0x160→880B 无帧、unusual 走 cold_table 间接（noinline 破 musttail 规避法）、
teardown 只搬不改、gate 全绿。3-pad 流水线在跑。lane FW 时间分口径瑕疵已训（终裁以 zoo）。

## splay ⑥ 快讯：访问量 +18.6%（多走对象）单访平；gc_rounds 1vs2 拆分在途定刀形。
## P6 刀 B @18853c55：两腿落地但官方案 2→4 跨 slab 类就地不命中——driver 复测排队
（w23 流水线后）；concat 同款「无松弛生态位」阴影，验后定夺。

## P6 刀 B 终裁（2026-08-16）＝REJECT-ARCHIVE + 松弛定理升宪

driver 三点复测（eab53524733a vs e7d4c5bb5748，CPU 19 n=8）：官方 1.605→**1.669**、
保活 1.050→**1.066**、keep2 无扩容 0.947→**0.958** 全负。死因=slab 精确类几何：
2→4 即 40→72 永跨类，就地臂零命中。**宪法级定理（concat+P6 两案实证）：qjs 靠
malloc bin 松弛吃就地红利的优化，在 zjs slab 生态一律不可移植。**
P6 +200/obj 真税残余改判「shape 生命周期单位成本」（z 建/毁 ≈130 cyc/obj vs qjs 数十），
挂分析队列非在制。18853c55 封存（实现与探针链留档）。

## wave-23（K-ret-slim）终裁（2026-08-16）＝REJECT-REWORK

3-pad（收敛族 pad3/7 为准；base pad0 现首建漂移 4ff6556d，协议生效）：geomean
−0.42~0.52%、DB −0.99~1.33%、richards/gbemu/splay 同号负。**driver 判别器：DB insn
−2.4G（−0.64%）真赢**——「指令赢周期输」＝微架构，两嫌疑：①op_return 缩 9KB 岛几何
移位（w22 同病）；②cold_table 表载+br x4 间接跳 BTB（每个非 simple 返回）。
返工：pV 先量 unusual 路频次→若高改直跳单一冷入口；放置随 pQ 岛尾纪律 rebase。
pT 模板警告已发（call 入场去帧冷臂改直跳形）。**刀族方向经 insn 判别器实证为正**
（DB −2.4G/mandreel −689M），是形不是族的问题。

## TS 新鲜符号快照（2026-08-16，driver，main 件 CPU 19，占比非超额）

get_field 21.74%/call_method 6.70%/get_field2 4.86%/traceChildren×2 7.52%/put_field 3.90%/
return+return_undef 5.79%/nativeMethodFastDispatch 2.98%/setOrDefine 2.90%/cycles 2.51%/
**get_field2_call_method 2.34%（融合对在 TS 热榜生效实证）**。
战略读法：TS 覆盖=边界去帧族 ~12.5% 面 + ⑥ GC 刀（若成）~10% 面 + 融合延伸；
get_field 巨鲸待 qjs 对位定超额（box2d F 刀前科：占比高≠超额）。TS 非孤儿项。

## splay ⑥ 直方图收口（2026-08-16，pW）

+19.5k/轮=**几乎全是普通活 JS Object**（slab 72；max 轮 +105,324）。值数组假设否决
（block=40 在 list 零上榜——2 槽 Entry[] 走 allocRuntime 裸内存 owner 持有，同 qjs p->prop）
→ **⑥ 不并入 P6-GROW**。刀形收敛到「扫描集合对齐（更多活 Object）」。
最后悬点=qjs 侧 list 长度从未测过（18b 把初值对齐 qjs=2，字节 profile 更像 qjs 反而 list 更长）：
pW 已派 qjs 拷贝件加计数器对照（⛔不动裁决 qjs）——qjs 短→js_trigger_gc/gc_threshold
公式分歧清单=刀口；qjs 同长→⑥ 改归每访 cyc +5.6% 重新究因。
pS 激活队列项=shape 生命周期单位成本分段账（P6 残余真刀口，四段：create/destroy/hash/记账）。

## pQ 实例重启（2026-08-16，漂移第四案终局）+ 刀族合流点

pQ 压缩后上下文毁（opt-r9-n 复活 52min→prompt/esc/enter/ctrl+c 四级挽救全败→编辑
worktree-r10 旧码）→ **杀实例+原 pane 重启+自包含单** 成功入轨（r10 树净无损）。
⭐运维新则：上下文级漂移不可 prompt 救，直接 kill+restart+自包含简报（含仓库/分支/文件/完成定义）。
**w23 频次归因（pV）**：DB unusual 4.0%（return_undef 11.5%）/richards 0.04% → ②间接跳
否决为主因（richards 不付 br 却同号负）→ **①岛几何=w22/w23 同号负共同主犯坐实**，
全刀族兑现系于 pQ 岛尾纪律一点。pV 直跳形+insn −2.4G 已保，待 rebase。
**pS shape 四刀批**（不清 props/信 header/comptime 类/专用 add_gc+双账修，~25-30 cyc/obj 诚实）。

## splay ⑥ 全案闭 → GC-ACCT 刀立项（2026-08-16，pW qjs 对照）

qjs 侧计数器对照（拷贝件，裁决 qjs 未动）：轮数同 16，**qjs 每轮均 list 113,810 vs
zjs 125,186（zjs 多扫 +10%）**。刀口=记账口径：zjs 触发记账用请求长（allocated_bytes）
vs qjs js_malloc 记 malloc_usable_size(+8 头)→qjs 每笔多记→阈值早触→list 短。
**GC-ACCT 刀批 pW**（逐行镜像 js_trigger_gc/gc_threshold，slab 下 usable=块类大小照实记；
全场 GC 节奏变化由 zoo 判；双模态前科 ≥8 样）。⑥ 残差 5.6%/访不追。
18b 暴露税三案终局：P6 扩容单价（松弛定理封死）/⑥ 扫描集合（GC-ACCT 刀）/teardown（固有）。

## w22 返工预验（2026-08-16，driver objdump 双建比对）

e7b817e5（岛尾追加）vs base：存量 149 handler 一致 −0x3c0 位移——源头=**腾槽移除**
（旧 240/242/243 type-test 体撤出原位），非插入位移；岛尾纪律只能消「插入」消不掉「移除」。
⭐硬门 #8 措辞修正候补：「新 handler 岛尾追加**且腾槽移除位移不可避免时 3-pad 重抽签裁决**；
偏移钉死需求走墓碑（原位留死体）」。w22 重掷的 splay=新抽签非保证回平。

## call-entry-slim 首试回退 + 边界去帧族改统一施工（2026-08-16）

pT G/H 首实现自测 FAIL：box2d insn +0.73%（不交叠）/cyc +2.1%/IPC −1.4%——族内第三次
撞编译器阻力（inline 强展开/Handler 类型禁 noinline/LLVM 折回，pV return 侧同款）。
裁决：patch 存档+回退+学案；**族改统一施工**：先 return 侧证形（pV「去 inline+单份 unusual
停岛尾」，候 pQ 岛尾纪律），证形过再复制 call 侧。insn 账仍在（DB −2.4G）——形未找到，族未死。

## 边界去帧族设计律三条（pT 学案 call-entry-slim-LESSONS.md，2026-08-16）

1. **热函数零 bl**：任一 bl（含 miss 冷臂）→LR 保存→整 stub 入口建帧（「帧为承认而建」小号壳）。
2. **双付承认账**：stub 前缀×全流量 vs 省帧×命中率——box2d method 85% native/mandreel call1
   几乎全 simple→按 leaf 去帧=主路赶进 miss（v3 三层 hop +653M 实证）。
3. **同文件 always_tail 同类型 Handler 会被 LLVM 折回**；仅运行时下标（BTB 嫌）或
   去 inline 停岛尾（正道）能拆。⛔call 侧禁再造第三张表。
复制序：pQ 岛尾→pV return 证形（unusual 去 inline 单份停岛尾+岛内 stub 只留首测）→
带流量约束复制 call（H 必须盖 simple）。pT 转 TS get_field 对位（TS 覆盖缺口）。

## shape-lifecycle 四刀快筛通过（2026-08-16，driver CPU 19）

90e14f18（建不清 props）+195006b6（毁信 header）+7839abf8（comptime 类）+f63de118
（专用 add_gc+likely）@ f63de118：P6 官方 1.605→1.577（insn −2.6%）、保活 1.050→1.042、
**splay FW insn −23.3M=预测账吻合**。门全绿（473/oom 21/RS 预存 3 项无关）。
→ wave-24 候池（拟捆 GC-ACCT，正交双刀各持独立 FW 立据）。

## TS get_field 巨鲸判死（2026-08-16，pT 对位）

21.74% 独占=**占用非超额**：热臂 47 vs qjs 51（z 反短 −4/次=−0.21G 帮账）、F1/F2/F3 三跳
TS 上从不采取（161M 退役分支=insn 0.16G 仅占洞 2%）、IPC z 更高（1.014）。F 刀维持挂档。
TS 真洞=FW insn **1.096（+7.4G=+24/opcode 弥散）**、cyc 1.081 与分数 0.912 同向。
⭐共享符号陷阱再拦截：qjs get_field ⊂ JS_CallInternal 38KB 单符号，「z 独占%−q 0%」禁用，
换算必须 n×每发 Δ。追单=TS 守恒图（pT，Σ桶=+7.4G 闭合）；现有刀池已对 TS 实洞
（GC 13%→GC-ACCT+shape；call_method 13.1M→族复制；put/扩容→shape 域）。

## 运维拦截：pW 脏树警报（2026-08-16）

GC-ACCT 实施发现 pW worktree 仍在 concat 封存枝+三文件残改未清（string/value_ops/root）——
提交夹带风险。已令：残改丢弃→daf1707d 干净起 grok/gc-acct→重放 memory.zig→
diff --stat 核对（08-08 静默丢失+夹带双防）。⭐封存枝的 worktree 必须立即归位干净基线，
封存≠留脏现场。

## w22R 裁决窗冻结令（2026-08-16）

pQ 在裁决窗内叠 dbaebc42（撤墓碑）——依据 splay FW insn 平，但 insn 尺看不见几何风险
（w22 原案 insn 也平）。裁定：3-pad 钉 **7d861ccf 墓碑版**；dbaebc42 不候审，欲撤墓碑
须合入后独立成包 zoo 证明。⭐冻结令制度化：裁决窗内候审枝禁新 commit（wave-21 判例）。

## wave-22R 终裁（2026-08-16）＝ACCEPTED main@c10149a7（第十六包）

7d861ccf（岛尾+墓碑+单遍 fuse）3-pad：geomean +0.11/+0.20/+0.18、DB +0.49~0.60 同号、
**splay −1.25→+0.45~0.60 完全反转=放置纪律实弹验证**、gbemu 同号正、code-load ≤0.2%
（insn +1.56M≤4M）、gate 0/49775。richards 微混（−0.3~+0.06）在线上无虞。
**融合硬门 #8/#9 入宪**：新 handler 岛尾+腾槽墓碑（撤须独立包 zoo 证）；冷臂直跳禁表载。
dbaebc42（撤墓碑）未候审存档。fusion v4（zlib 定向）已派 pQ。
**w24（shape 四刀+GC-ACCT）流水线接力上台。**

## w24 捆包冲突裁决（2026-08-16，driver 亲解）

shape ②（毁信 header）×GC-ACCT 在 memory.zig 自由函数 free 撞头。取 eacd 侧
（debitAlloc(payload, slab_class)）：header 取类在 RF 保留 shape ② 意图（assert 仅 Debug）
且与 alloc 侧 usable 记账对称。integration/wave24@2e784342，流水线续跑。
验收 key 集=splay/EB/TS（受益主张）+DB/raytrace/crypto（资产哨+18b 退税观察）。

## w24 首掷作废（2026-08-16）：合规链吞错+记账不对称

⚠️续跑脚本 gate 步管道吞错（第三犯，driver 自犯）：test262-gate exit 1 被 tail 吞、zoo 照跑
→ 全部 zoo 数字作废（账面 EB +3.1~3.7/TS +1.2~1.6 诱人但无效）。真因=两刀记账不对称：
shape ③④ 专用 alloc 按请求长入账 × GC-ACCT free 按 usable 出账 → runtime.zig:1283
拆机守恒断言炸。各自全绿≠捆包绿（「组件绿≠包绿」第三实证，这次是语义级）。
联合枝 grok/w24-combined 已派 pS（③④ 全径改 usable 口径），pW 支援 API 口径。
⭐流水线模板修正：gate 步一律 `>log 2>&1` 落盘再显示，禁管道直连。

## fusion v4 打回（2026-08-16）：储备槽违令 + mandreel insn 红旗

d608ae51 账面 zlib −1.85B 亮眼但：①254/255 被扩用（驳回令未执行）→撤、归还储备；
②mandreel +1.39B/DB +33.8M insn 涨=融合不该有的方向（疑 fused-B miss 落冷重付=双付模式）
→逐对隔离矩阵（v2.1 判例）定税主修形或弃对。两项齐再候审。
⭐lane 报文「观察」标签不豁免红旗数字——insn 方向异常必须命名后才可上 3-pad。

## fusion v4R 收口候审（2026-08-16，b6fd3ee6）

矩阵翻案：none +2.03B > all +1.39B → 税=get_array_el_push_0 **克隆热体几何**（原体 −84B
滑动 put/get_field 段）非对上双付——岛几何家族第五证据。弃该对（mandreel 量 278）归还
swap2@28；四对+链式 musttail（push_2_sar leftover→sar_get_array_el）在产。
FW vs c10149a7：**zlib −7.50B/mandreel −606M/DB −1.0M/code-load +2.1M**；none 残 +10M。
门 202/473/493。w25 流水线备妥候 w24R 让核；冻结令生效。

## wave-24R 终裁（2026-08-16）＝ACCEPTED 第十七包

联合枝 6769e6d2（shape 四刀+GC-ACCT usable 记账）3-pad：geomean +0.37/+0.44/+0.39、
EB +0.57~1.21、TS +0.62~0.95、**raytrace +1.05~1.23=18b 资产税退还兑现**、crypto/code-load
同号正、DB 微正。splay 混号近零（shape −23M+list −12% 的 insn 战果未折周期——⑥ cyc 尾巴
挂观察）。gate 0/49775。合入 main。**w25（fusion v4R b6fd3ee6）接力上台。**

## wave-25 终裁（2026-08-16）＝ACCEPTED 第十八包

b6fd3ee6（四对+链式 musttail，槽合宪）3-pad：**zlib +3.96/+5.04/+5.28（战役级）**、
mandreel +1.26~2.00、box2d +0.34×3、geomean +0.46~0.53。splay −0.24~0.93/code-load −0.4
经判别器=几何非语义（splay insn +0.046% 平）booked（回收线在飞：⑥ cyc 尾+去帧族）。
融合通道 v1/v1b/v2.1/v3R/v4R 五包在产。绝对计分板在跑。

## 下一轮布阵（2026-08-16 晨，站位 0.9801/8 达标后）

pQ=fusion v5 选对（box2d/mandreel/gbemu+槽预算）；pT=TS +7.4G 守恒图（催报）；
pV=去帧族 return 证形开工（k-ret-slim-v2：去 inline 单份岛尾+ctor 首测 stub，硬门 #8 形）；
pW=splay cyc 尾案（ACCT insn 兑现未折周期：OoO 吸收 vs 新段吃掉，二裁）；
pS=EB 守恒轻刷（五桶现值+新暴露段，裁专刀价值）。
gbemu 0.9990=噪声距离，v5 一对即回线。

## splay ⑥ cyc 尾案终闭（2026-08-16，pW）

GC-ACCT 在 splay 实兑≈零：traceChildren insn 仅 −0.5%（探针期 list −12% 未折入总访问），
cyc −6.3M 被 ⑦ destroy 密度+alloc 边角盖住。非 OoO 非每访差。刀合宪保留（语义对齐零成本，
EB/TS 侧战果在 w24 已兑）。splay 残差定格：⑦ 固有段+去帧族候（k-ret-slim-v2 在制）。
⭐探针外推≠终件实测——list 长度探针与总访问量之间隔着触发时序，两者必须分别验。
pW 转 box2d 守恒快照（整夜唯一原地项，五包全绕过）。

## TS 守恒图 v2（2026-08-16，pT，main@40e83160）＝战线质押判决

**+7.37G insn 残差整夜未动**（五包实吃 0.03-0.2G；0.920 抬升=周期/IPC 非 insn）。
桶序：**call 入场 +6.34G（86%）/return +4.30G（58%）**→边界去帧族质押（pV 证形=单点）；
put 壳 +1.58G（setOrDefine 3.67G 大头，shape 只吃 0.18G）=唯一独立正桶→pT 分解；
compare +1.72/GC +1.40（ACCT 在 TS 实吃 0.03G）/array +1.35 卫星；
**get_field +0.03G≈0（融合把独占差抹平）**、get_field2 负禁开。
「帧仍为 native 流量而建」三度实证（call_method 6.79G+native 2.81G+pushExact 2.25G）。
⭐已合入刀的战果≠残差缩小——insn 账与周期账必须分开验（0.920 换的是周期衣服）。

## EB 刷新终裁（2026-08-16，pS）＝专刀不立（负确认）

main@40e83160：FW 1.264/+1413M 闭合 100%（0.791≈官方 0.792 互证）。
①巢/④仍 0；**融合五包在 EB 具名 9.5M=空靶**；⑤ 窄 −49M 噪声级、宽口径仍占近半；
shape 余量 ≤40M（w24 已咬 createObjectRoot 101→74）；GC 环可吃 ≈0（drain 已齐、余为禁区）。
无新 ≥100M 段。0.768→0.792 的付款人=18b（+2.2%）与 w24 档案咬动，非融合非 ⑤。
**裁：EB 下一把 FAITHFUL 专刀=空砍，不立**；「不要做」九条照准。档案定位维持。

## box2d 快照（2026-08-16，pW）＝并入去帧族抵押品

main@40e83160：cyc 1.041/**insn 0.999 已平**/分 0.951——4.7pp 全周期税。
F（get_field 11 跳 393M 分支）+G（call_method 0x3f0 45M）=热核守卫+入场帧，五包绕过原因
=其付款面不在此。三桶归去帧族。**战线集中度顶点：六项（TS insn 10.6G/box2d/mandreel 周期/
DB/splay/richards 加厚）全押 pV 证形一点。**

## put 壳分解（2026-08-16，pT）＝PUT-PROTO-WALK 刀立项

+28/次拆账：**查找税**=原型走 +12（+0.66G 主因）+热哈希哨兵 +9（shape 全局 ABI 禁动）
−写侧 9（z 已便宜，P6 区勿开）+跳板 +2。3.67G vs 2.68G 之差 +0.99G=贴标缝
（inlined append 熔账），公平 miss 栈 z 4.90 vs q 4.75。W1 枚举确认收完（tbz 1 bit）。
唯一 ≥0.5G 忠实刀=**miss 原型走对齐 q**（cbz 空桶/先 find 后 exotic/exotic 不甩 slow）
→ 批 pS 实施（grok/put-proto-walk）。「不要开」五条照准。

## 去帧族证形交付→wave-26 上台（2026-08-16，pV @84cf0f9c）

形全达标：popAndResume 去 inline 单份 5856B 停岛尾（94% 位）、岛内 unusual stub 620/700B
（≪1KB）、热叶 864/852B 无帧 miss 直跳、**岛净瘦 −9.8KB**、473 绿。
FW vs 40e83160：DB −2.81G（−0.75%）/richards −1.81G/**EB −5.07G（−1.05%）**——三案全优于
w23 旧形。3-pad 在跑：此裁=六项抵押（TS 10.6G/box2d/mandreel 周期/DB/splay/richards）
的族命运判决。通过→call 侧复制立即开工。

## wave-26 终裁（2026-08-16）＝REJECT-REWORK（族最后一轮）

84cf0f9c 3-pad 全谱同号负：geomean −0.55/−0.81/−0.86、DB −1.5~1.9（自标的！）、
raytrace −1.6~2.2/crypto −1.7/mandreel −1.6~1.8/splay/gbemu/TS/EB 全挫；regexp 彩票正。
⭐driver 验收失察自查：「岛瘦 −9.8KB」与硬门 #8 不可共存——op_return 10016→864 中岛移除
后方全滑 −18KB=w22 级几何复活。两候因：①中岛滑移（修法=洞内墓碑垫回足迹）；
②unusual 远跳局部性（不可修→族负定理：「边界 unusual 内联体=局部性承重，外提任何形均输周期」
三形三败候证）。pV 最后一轮：洞墓碑+nm 逐地址过门→FW→3-pad 分离裁决。
**w27（fusion v5）独立上台**（其 nm 热体同址已验）。

## PUT-PROTO-WALK 收池（2026-08-16，pS @90f3609f）

三点落地（哨兵本环提升/先 find 后 exotic/exotic 具名 fallthrough 非无条件 slow）。
TS insn **−228M**（预期 0.5-0.7G 差额=qjs 真 cbz 空=0 是 ABI 级，现 ABI 只可齐门序）。
门全绿、P6/热 CASE 零接触、splay 平。→ **w28 捆包池**（单独 3-pad 不经济）。

## wave-27 终裁（2026-08-16）＝REJECT + 通道余量求证

616e5b44 3-pad：geomean 净零、**gbemu −0.20×3 同号负**（补刀反伤）、box2d 平、mandreel 微正。
**融合物理下限实证：<10M 次的对省不回外部性**（省 5-9/次×7M=0.03% vs 几何/emit 风险非零）。
封存不返工。pQ 求证 tsv 余量（≥50M 未融合对）：有→最后一轮；无→通道五包收官。
w26R（族终审）上台。

## wave-26R 终裁（2026-08-16）＝去帧族收档（负定理定案）

37d770f4（315/315 同址钉死）3-pad 仍全谱负：geomean −0.48/−0.91/−0.92、gbemu −2.4~2.8、
box2d −1.8~2.2、DB −1.4~1.7、splay/EB/TS/mandreel 齐挫→候因①排除、**②远跳局部性定罪**。
**负定理（四形证据链：w23 表载/attempt1 call/w26 缩岛/w26R 钉几何）：边界 unusual 内联体=
局部性承重墙——qjs 单函数解释器的近距离性是边界性能的构成性成分，外提必输周期。**
推论：TS call+return +10.6G 命名段正式归架构层；box2d cyc 税（守卫+帧）同归；
compute 系「insn 赢 cyc 输」的最终机理=同一堵墙。pV 四形工作入册为定理证据。
**w28（fusion-LAST+PUT-PROTO-WALK 捆包）上台。**

## wave-28 终裁（2026-08-16）＝ACCEPTED 第十九包 + 融合通道收官

df357327+90f3609f 捆包 3-pad：**zlib +1.54/+1.95/+2.20、mandreel +1.33/+1.44/+1.55**、
TS +0.26×3（原型走兑现）、gbemu +0.1~0.2 无伤、geomean +0.48~0.56。
**融合通道六包收官**（v1/v1b/v2.1/v3R/v4R/LAST；zlib 累计 +6pp 峰值战果；
通道 #2 从 PERF-MECHANISM-LEDGER 申报到收官全程零违宪）。绝对计分板在跑。

## splay 1.7pp 审计（2026-08-16，pW）＝无刀（固有段定性）

e17517f8：cyc 1.158/+217M 闭合 99%。⑦ teardown +150M 仍墙（空终止链+每对象记账+tagged
16B=固有地板）；⑥ GC 已被今夜刀群收到 +40M；T1-T4 不复活（splay 周期史≈0，249vs93 游标
可镜像但兑不成 1.7pp）。**splay 过线在 faithful 域内无已知路径**——候 zlib/mandreel 审计
齐后重报可达段构成。

## mandreel 2.2pp 审计（2026-08-16，pT）＝无刀（架构段定性）

e17517f8：insn 0.960（反超 4%）、cyc +165M=IPC 墙（5.48 vs 5.85）。
**+1.75G predicted-br（mis 仅 +7%）=musttail 每 op 一跳+承认/RC 弥散**——若有 q 的 IPC
反赢 257M。call1 0x1c0 帧内=承认+inline exact-leaf 热构造（97% 流量，R16「simple」过时），
原地可减仅 ~12M；fetch 2.83×=编译期（Emscripten 5MB 过 Zig 编译器），内环仅 13M。
可开刀清单=空。**mandreel 归架构段**（分派密度弥散，负定理同根）。
可达段构成待 zlib 审计终定。

## zlib 1.1pp 审计（2026-08-16，pQ）＝半刀 + 三审计终局

e17517f8：insn 0.836×（−14.66B 大胜）cyc 1.014×（+211M）。⭐cyc 级守恒新范式：
Δcyc=−2500M（insn 赢折 qIPC）+2711M（IPC 税=2576M 多余 br×1.05），命名守卫仅 602M=23.4%，
余 1974M=09 分派地板。融合密度反向证据：fusion 删 insn 快于删 br→br 密度 0.186→0.207 更差。
可开=leftover 链扩展（0.2-0.3pp，已批末刀）；R16 非本系祖先且 wave-6 分≈0 前科，重登须 cyc 尺。
**三审计终局：splay 固有/mandreel 架构/zlib 半刀——重定义目标 11/15 在 faithful 域不可达**：
zlib 0.99+彩票有机会、splay/mandreel 顶 0.978-0.983。faithful geomean 顶 ≈0.987-0.989。

## TAILCALL-DEEP 首轮改写（2026-08-16，pV 胶水解剖+pW 惯用式审计）

**胶水无罪**：cont 5 insn/1 间接（比 qjs BREAK 6-7 还短）、直线 op 两侧零 poll/异常；
**repr 无罪**：qjs 热 CASE 无 csel/ccmp（orr 区间/溢出旗各 1 跳），NaN-box vs tagged Δbr=0。
**已点名新税=寄存器约定**：活态 ~16 指针 ABI 只携 4 vs qjs 钉 6 常驻；handler 0-2 次入口
重载=load-use 气泡（insn 账不显、IPC 直接吃）。文献定论：CPython3.14/upb=musttail+
preserve_none+5-6 参（头条 10-15% 系 LLVM19 bug，官方 3-5%）；缺的是约定非 musttail。
→ **ABI-WIDEN 刀派 pV**（ctx 优先上参）。余下 ~1 br/op 待 pT 守卫走账归位。

## TAILCALL-DEEP 预算模型（2026-08-16，pQ）＝最大税源点名

zlib br 预算闭合 90.9%（热臂 9116+gae 密度 1918+TA helper 1958+cold 1152=14144/15564M）。
**主块=get_array_el 不走密数组臂：本体 2560M vs 模型 642M + readNumeric 1271M**
（zlib=TypedArray 负载，TA 臂分支密）——约 30% 的多余 br 一名俱名。
命名守卫族 Δ×q 频 ≈821M（put_array_el+3/var_ref TDZ/add+1/put_arg）。get_loc8/or Δ0。
抽样钉递 pT 对序。**下一刀=gae/TypedArray 臂瘦身**（qjs TA 惯用式镜像）。
「均匀 ~1 br/op」假设修正：非均匀，头部集中（gae 16.5%/push_0_or 11.3%/readNumeric 8.2%）。

## TA-GET 刀立项（2026-08-16，pQ 预研）

qjs [i] 惯用式=CASE class!=ARRAY→JS_GetPropertyValue 按 class_id 内联 bounds+ldrb
（u8 命中 11-13 跳）；zjs 18-20 跳：①密数组+own-int 两次白探在 TA 前 ②detach/kind 再守卫
③noinline readNumeric 跳表；float/u32 另付装箱扫描。刀=探序 class 先分发+零跳解码+
detach 折 live_length+直标 tag。⛔getfun 表非 [i] 主路径。预测=gae 桶 2560→~800M 级。

## ABI-WIDEN 8 参形 REJECT（2026-08-16，pV 自 FW）＝preserve_none 缺口本树实证

8 参（pc/sp/var_buf/Vm/ctx/rt/table/arg_buf）：cont 缩到 3 insn、热叶零 bl、
**zlib insn −26.2G/mandreel −10.9G**——但 cyc 全负（zlib +3.94G，IPC 4.95→4.65）：
AAPCS64 下 8 跨 handler 活参勒死体内分配器+每 musttail 点重整参。Ken Jin 论断坐实。
（混杂：if_false8 滑岛未钉。）→ 最小形（+ctx 一参、几何钉死）复验一轮；
preserve_none/ghccc 列 toolchain 前沿项。翻案主力转 TA-GET+守卫族（pT 走账中）。

## ABI 方向收档（2026-08-16，pV 5 参复验）＝负定理+前沿条目

5 参（+ctx）钉岛复验：zlib cyc 仍 +2.62G/IPC −0.061，mandreel/DB 平。
**负定理：Zig 0.16 musttail+callconv(.c) 下活状态入参（5 或 8）换不来周期**——
体内分配器约束>重载节省，需 preserve_none 级约定（toolchain 前沿条目成文，
/tmp/lanes/TOOLCHAIN-FRONTIER-musttail-preserve-none.md=Zig issue 素材）。
翻案战役余两线：TA-GET（gae 桶 −1.7G 预测）+守卫族走账。

## TA-GET 候审→wave-30（2026-08-16，pQ @60595414）

四点全落（class_id 先分发撤白探/u8-i32 零跳/detach=live_length/直标 tag），几何守纪
（gae 同址、ta 臂岛尾、export var 挡内联）。FW：**zlib cyc −399M（−2.57%）主尺兑现**、
insn −2729M、**br −1876M=预算模型 gae 桶预测逐位对账**；gbemu/box2d 哨平。门全绿。
3-pad 在跑——过则 zlib 过线在望+「架构段」判决部分翻案（class 分发缺失≠地板）。

## wave-30 终裁（2026-08-16）＝ACCEPTED 第廿一包：zlib 过线之裁

TA-GET 3-pad：**zlib +2.72/+3.36/+2.76**（0.9943→≈1.022 带余量过线=第 9 项）；
navier −1.7~1.9×3（Float64 主场，float 臂税）1.0615→~1.043 余量内 booked（原则第三适用）；
box2d/mandreel 微负哨内、余平。**翻案战役首胜：「zlib 残差=架构地板」判决部分推翻**——
class 分发缺失是可对齐项。用户「tail call 不应更差」直觉三度兑现（守卫可名/TA 臂可齐/胶水无罪）。
续刀：TA-PUT 姊妹（写侧）+navier float 臂回收。

## TA-PUT 候审→wave-31（2026-08-16，pQ @14fe7a34）

写侧 class 先分发（cmp #2）+TA 岛尾 int32 写无帧+GET 改同形（bitmask 税消）。
⭐navier 诊断更正：fixture=new Array 非 Float64Array，−1.8% 是 GET bitmask 税非④直标——
lane 自纠归因错案。FW vs TA-GET tip：**zlib cyc 再 −800.9M（0.9470，分 +5.8%）**、
gbemu −46.6M（−2.5%）、navier −16.3M（回收 ~1pp）、box2d 平。门绿（475）。3-pad 在跑。

## wave-31 终裁（2026-08-16）＝ACCEPTED 第廿二包：本役最大单包

TA-PUT 三合一 3-pad：**mandreel +6.84/+6.85/+7.03（0.980→~1.048 过线=第 10 项）**、
zlib +4.9~5.1（→~1.077）、gbemu +4.3~4.7（→~1.05）、navier +0.8~1.3 回收、geomean +1.2×3。
Emscripten 堆写=TA 写侧镜像的爆发面。TAILCALL-DEEP 两连胜。

## TAILCALL 续挖：入口对齐矿（2026-08-16，driver 亲查）

BTI 嫌疑 2 分钟排除（zjs 零 bti）。新矿：**78/129 handler 入口非 16B 齐**（get_field mod16=4/
get_array_el mod16=8/add_loc mod16=4；call_method/return/if_false8 已齐）。qjs CASE 也不齐
（0x294ac mod16=12）→ **超越型机会**，宪法归布局批（L-1 先例）。ALIGN-ENTRIES 实验派 pV
（align16 全岛+align32 热点变体，几何重掷=布局类改动）。
续挖队列：操作数寻址惯用式走查（样本初看干净）、分派流水化实验、直接线索化（通道 #3 候批）。

## SUPERCHAIN 普查（2026-08-16，pS）＝空清单关闭

全 zoo 无三连 ≥50M（最近 crypto 38.8M 非主尺）；LAST/END 已收尾对拆前缀。
通道关闭，工装留档（A→B→C 记账钩）。

## DT-SPIKE 挂起（2026-08-16，pW 设计书）

直接线索化：诚实赚头≈0（BTB 藏 br 延迟，8 参 −26G insn/+3.94G cyc 同轴实证）+
地址流内存反噬（mandreel BC 2.01MB×8=16.1MB 出 L2/L3）+真 ldr+br 形改动面大
（跳转/leftover/pc2line 重写）。**挂起入档**，preserve_none 落地后可重开。
延迟轴三案齐（5 参/8 参/DT）：好预测下分派延迟不是税——税在分支退役吞吐与取指质量。

## wave-33 终裁（2026-08-16）＝ACCEPTED 第廿四包：F 刀翻案完胜

F-RETRIAL（11→8 跳+洞墓碑）3-pad：**box2d +1.86/+1.90/+2.10（占用上界兑现！）**、
TS +0.72~0.80、DB +0.28~0.35（收复 w32 回线在望）、geomean +0.39~0.55；zlib −0.4 booked。
**wave-6「分支体积→分数」灭链正式推翻**：cyc 主尺下从不采取守卫=真税。
TAILCALL-DEEP 四刀四中。计分板在跑。

## 二期残差账两笔（2026-08-16）

pS TS 账：F 连带 −2.2G（insn 比 1.095→1.067、findWritable F3 掉）；setOrDefine 不掉=
miss 原型走已被 put-proto-walk 收；call/return 原地不够格、native 零帧兄弟默认关（双付前科）。
pW splay ⑦：**固有终验不翻案**（钳零跳/deleted 对称/phase 2-4M/kind 6-12M，无 ≥30M F 族）
——固有裁定两范式齐证铁案化。

## 二期收尾启动（2026-08-16，用户令「先收尾，进入下一轮」）

二期战果：w34 守卫捆（zlib +1.2）+w35 对齐二期（mandreel +2.0）两包落袋（廿五/廿六），
TS/splay 残差账收口（F 连带 −2.2G/固有铁案化）、pS 搭车账（EB +0.7/pdfjs +1.8 FW）。
收尾件：pQ 哈希哨兵 spike **不立已裁**。在途：pT box2d 账（压缩重锚后）、pW DB 钉线账。
**三轮开局侦察：pW DB 钉线账**（抖动带 0.999~1.005，旧图 08-15 版过期）。
三轮候选池：box2d G 域原地（候 pT）/ DB 钉线刀（候 pW）/ TS call 边原地走账。
**哨兵 ABI 已踢出池。** 待命候三轮组包（pT/pW 账出后）。

## HASH-SENTINEL spike＝不立（2026-08-16，pQ；driver 采纳）

负确认。全文 `/tmp/lanes/HASH-SENTINEL-SPIKE.md`。

| | |
|---|---|
| 上限 | 单案峰 **−26M cyc**（richards）；box2d −8 / DB −19 / TS −17；zlib/mandreel **≈0** |
| 跳 | **Δbr=0**（`mov+cmp` → `cbz` 仍一条空测跳；省的是 insn） |
| 面 | 全局 ABI：`no_property_index` + 全部 memset/link/unlink + `findOwn*`/`findProperty*`/原型走 + 测试钉。空=0 且 0-based 会把每个 shape 首属性当空桶；齐 qjs 必须 1-based（`i+1` / 偏 `props_base`） |
| 裁 | **不立。** 评估省下一次空刀。不进三轮组包。 |

热 CASE 仍 `mov #0x3ffffff; cmp`（`get_field@107396c` / `put_field@10731d0`）。原型走已提升哨兵，再改 ABI 每环 0 insn。TS CASE +0.53G 不是这条 `mov`。

## 三期首轮双澄清（2026-08-16，pS BL 普查+pQ FLAT-CALL 设计）

①BL 普查：**热 CASE 入口→分派零 bl**（1511 静态 bl 几乎全冷臂/必须 call）——handler 层
tail-call 纪律本已清白；destroy 尾 0.22% 唯一 upb 形候选挂 F 族。
②FLAT-CALL：**现状已半平坦**（enterEntry/popAndResume musttail）——彻底化收敛=
「收成唯一 JS→JS 激活+溢出改 VM 累计 planned bytes（删每调原生 FP 测）」。
分期 P0 尺→P1 叶证形→P2 泛化收 .tail；X-89 正交（平坦≠reuse）。**P0 已批**：
非平坦流量占比+溢出记账现价（疑 +17.7 常数一截）+P1 准入清单。

## box2d 后 F 账（2026-08-16，pT）＝并入 FLAT-CALL 抵押品

c7770616：insn −162M 反超、cyc +43.4M=纯 IPC 税（Δcyc=Δinsn/IPC_q+z_insn·Δ(1/IPC) 闭合）。
F 吃掉 ~1.3pp cyc/+2pp 分。禁外提下原地不够立项；最大单名=call_method 0x3f0（85% native
进门即付）→ FLAT-CALL 标的。三期抵押品定格：box2d/TS/DB 常数/空调用 +17.7/（EB ⑤/pdfjs ②
随 15/15 新目标回栈）。

## FALLBACK 链闭卷（2026-08-16，pV spike）

upb 续行形：仅终结型可改（0.22% 面）、append 微原型 +0.33% cyc 不赢、noinline 类型不能
musttail/体必须 .TEXT 的工程约束在案。不上台入档。三期收敛：主线=FLAT-CALL P0→P1→P2，
辅线=C1 对齐修（DB 钉线）。

## FLAT-CALL P0 定价（2026-08-16，pQ）＝彻底性三审盖章

①zoo JS→JS **100% enterEntry**（driver_tail 0；嵌套仅 C→JS：box2d 248k/raytrace 82k）
——双路径假设消解；②exact-leaf 准入 ~23 insn（栈限检 6 条现算），A_direct 头 Δ+13.9 cyc，
记账仅一截非整格 +17.7；③P1 不当分数刀。**三期三假设（双路径/bl 违纪/续行缺失）全消解
=tail-call 实现本已彻底（用户假设证伪但审计增值：四刀+三负定理+对齐两矿全是本轮副产）。**
微刀合包批：P1 证形锁+栈限检预计算瘦身（钉线级）→与 C1 同 wave 捆。

## C1 更正+收捆（2026-08-16，pV @b737de32）

**pW DB-PIN 的 mod16=12 系旧二进制伪影**（18:12 合入前陈件——⚠️账基指纹纪律逃逸：
lane 归因测量必须验件 sha 对 HEAD）。声明级 align 本已盖泛型实例；C1 真实增量=
Slow/Leaf 补齐 12/12 mod32=0，FW richards −38M/DB +17M 混号小效→**并入 w36 捆**
（与限检瘦身同 wave）不单独上台。DB 钉线回归「靠任意干净包带过」策略。

## 四期首账：pdfjs native 走账→K 捆立刀（2026-08-16，pW）

新范式重走：前言 980M vs q 134M（7.3×）实锤。三刀：K1 重复承认 2-3×~30M 跳/
K2 forwards tbnz（NMFD 最热从不采取=F 族式）/K3 fromCharCode 升 exec_direct
（charCodeAt 判例）。0x3f0 记账不立。→ pW 自实施 grok/pdfjs-native-k。
**「旧地图重走必出刀」第三次验证**（F/TA/pdfjs-K）。

## 四期第二账：TS compare 走账→CMP-EQ-UNFRAME 立刀（2026-08-16，pT）

④d +1.72G 拆穿：一半假独占（q CASE 采不到+leftover 已瘦）；真洞=eq/neq/strict_* 独立
handler 折回混型庙，both-int 每发 0x70+双 b（R16-C 原案，leftover 52B 瘦叶=目标形活证）。
关系算子快叶达标（仅 +1 cbz）。刀=庙钉间接尾后+热臂收 leftover 形，**~0.60G insn**
（cyc ~0.16G），REL-ORR 搭车。pT 自实施。「旧地图重走必出刀」第四证。

## 四期第三账：EB ctor 走账＝无过线刀（2026-08-16，pV）

258M 分解：TAKE+poll 54/proto 55/进体外壳 65/窗 install+consumed 79 vs qjs 熔账 74M。
二次 find 试刀 −19M<30 撤。EB 攻坚收敛于 pS instanceof 账（497M 最后主矿）。

## 四期第四账：EB instanceof 走账→K-HASINST-DIRECT 立刀（2026-08-16，pS）

497 vs 65 走通：非原型链环单价（ohi 环 8.5 vs 6M）；**旧账漏 DINM 180M（唯一调用方=
op_instanceof）**。族独占 698M vs q 109M。刀=默认 @@hasInstance 直呼 ordinaryHasInstance
（js_operator_instanceof 形，Get 保留禁 bypass），保守 −180M 上沿 −224M。
哈希哨兵命中臂 63M 不可及（F3 短接吃不到命中形）确认。「重走必出刀」第五证。

## PDFJS-K 捆打回（2026-08-16，pW @9a2fc82a）

刀体立（br −82M/insn −206M/raytrace −637M cyc/regexp −158M）但主尺 pdfjs cyc +71M
（+0.57%）=NMFD 体缩（0x1c0→0xc0）滑动岛外邻居几何（w35 对齐 13 员被挤）+call_method
+16B。REWORK：洞墓碑/重齐+0x3f0 还原+三案 re-FW。⭐岛外 helper 的体缩同样触发墓碑义务
——几何纪律从岛内扩展到全部热符号邻域。

## 四期第六账：TS GC 走账→K-TRACE-ORDINARY 立刀（2026-08-16，pS）

旧 +1.40G 半数分桶错（漏 q free_property 0.50G）；公平后 ⑥ +0.52/⑦ +0.11。
值 tag 加载=repr 固有（两边体）。可砍=F 式从不及：kind 三臂 ~80M+进环四探 ~30-50M
（dest 0%）→ 刀=普通对象 trace 对齐 qjs 6568-6611（shape+数据槽），80-130M，禁区全守。
「重走必出刀」第六证。

## K-TRACE-ORDINARY 收池（2026-08-16，pS @116b994f）

普通对象 mark 收 qjs 形：TS insn −225M（超预算）/cyc −149/br −151、splay/EB 微正、
双模态自检单峰、RC/环/destroy 禁区全守。→ w39 捆池（cmp-eq+array 墓碑版候齐）。

## TS 重图 45（2026-08-16，pT）＝交互缩水定律

三刀合并树实吃 0.17G FW（孤立 sit 相加 0.65G）——**⭐捆包收益≠孤立 sit 之和，合并树交互
缩水显著**。残差 +5.00G/1.065 付款人仍 call+return。新露头：混型 eq export 0.55G
（pT 接续账）；put 壳 3.60G 维持最大正桶。

## ⚠️w36 空合并事故（2026-08-16，pQ DB 账挖出）

8aea93e0「wave-36 limit-slim+C1」名实不符：流水线启动时 grok/limit-slim 未提交
（竞态），实测=C1-only（zoo 平度诚实）。limit-slim 真身 e7cdcaac 从未入主干。
**wave-40 补裁上台**（e7cdcaac vs 45f8af29，DB −80M/mandreel −34M/A_direct −330M 预估）。
⭐制度化：流水线启动前 driver 必 verify 候审枝 tip≠base（空枝=空包）。

## EB 回吐勘察闭卷（2026-08-16，pS）

w39 EB −0.9=cmp-eq 四叶缩簇（−0xA80）后的 IPC 谱系变化（4.575→4.511），非滑址本身；
墓碑试验受 align 粒度限制（最好 +128B）不能精确还原、FW 未收回→不立刀。booked 维持。
⭐滑移外部性的边界案例：有些几何回吐墓碑救不了（IPC 谱系级）——收益方净大时如实 booked。

## wave-40 终裁（2026-08-17）＝REJECT-ARCHIVE

limit-slim 真身 3-pad：geomean +0.12~0.17 但**分布反噬**——DB −0.42~0.63×3（钉线标的
反付）、box2d/zlib 付，gbemu +1.3/mandreel +0.65 资产收。线下项买单违余量原则。
⭐微基准→真混合不迁移律再证（A_direct −330M vs DB zoo 负）。e7cdcaac 封存。
w41（pdfjs L1）接力。

## wave-41 终裁（2026-08-17）＝ACCEPTED 第卅一包

pdfjs L1（charCodeAt exec_direct）3-pad：pdfjs +0.68/+0.83/+0.69、regexp 顺风、
raytrace −0.5 余量内 booked。pdfjs 三刀累计（K+L1）~0.79→~0.81。

## EB get_field 混合账＝无刀（2026-08-17，pW）

555M=62M 发×8.8cyc 自身首探 data（car/cdr、原型深 0），vs q ~10cyc/发同跳同采取——
合法占用。EB 三大符号（get_field/ctor/instanceof）全走毕：faithful 残矿见底，
EB 剩余=形态税+容量墙+固有段三件套（核心问题清单 #1/#3/#5）。

## put 形账闭卷（2026-08-17，pV）＝容器合法+尾刀

0xe0=E 原型走+G/H inlined append 的合法容器（qjs 外提到 add_property=我们禁学），
重排/早分流/transition 前置三路皆不立。3.60G 大头=贴标+热叶哈希 ABI（越权）+哨兵残。
尾刀=atomIsArrayIndex 守卫砍 ~0.14G（批 pV，w42 池）。①c 正桶宣告收割完毕。

## splay 叶账＝无刀（2026-08-17，pQ）：splay 残矿见底

⑨ 叶=两发 flat+flat 短串 copy-concat，q InPlace 同 miss（const rc≠1/松弛 1B<14B），
两侧同价。30M 门下不立。splay 与 EB 同列残矿见底——faithful 域的可命名机制殊全部收割，
剩余（splay 1.9pp/EB ~20pp）归核心问题清单 #1/#3/#5。

## gbemu-TA 账＝停放（2026-08-17，pS）

7.54% br=TA .length 经 OP_get_length（非 [i]/byteLength/DataView）。车体过 30M 但
gbemu 资产+无第二热消费件→刀停放候泛化。w42 池余两刀（MIXED-EQ/atomIdx）在制。

## 五期 A 线：CH3-DISPATCH-SPIKE review（2026-08-17，driver 裁）

**判定：设计 APPROVED，附两修正；P0 普查（只读）即刻开工；P1 占 254 槽候用户终裁。**

设计=区域 opcode 超块（首字节改写、窗内字节保留=融合 leftover 同构、3-4 原子小组件窗、
目录≤2 形、体长≤0x100、miss musttail 现成 handler）。四条件自证与负定理群相容性论证均成立。
诚实预期已立：v1 奖金在 compute 直线段（zlib/mandreel），box2d/TS 肥 hop 不可达需另案。

修正 R1：冷表/L0 项禁止另写「按形解释慢体」（双维护危险）——区域 id 的冷表项必须直接指
首原子的原 handler：形静态已知→首原子 opcode 已知，操作数字节未动，原 handler 逐字可用。
依赖 pc 偷看的 fused 首原子形本就被 §3 排除，故恒成立。
修正 R2：P0 杀门执行为硬门（小组件冠军 hop 诚实上限 <30M cyc → REJECT-ARCHIVE 入档，
不进 P1、不试探性占槽）。

分工（用户 08-17 指示：执行全下放 grok，driver 只方案+review）：P0 由 pQ 执行，产物
/tmp/lanes/CH3-P0-CENSUS.md，driver 只读裁决。

## 五期 B 线：NATIVE-THIN-TIER review（2026-08-17，driver 裁）

**判定：设计 APPROVED；P0（旗+comptime 拒绝+post-L1 NMFD callee 普查，零行为）即刻开工；
P1 金丝雀凭 P0 普查 ≥30M 份额放行（driver 门）；P3 几何变更届时另审。**

设计=第三臂 thin_leaf（与 exec_direct 并列可审计），v1 档=thin-noalloc、保留
NativeBacktraceScope（K3，栈迹语义不赌）、金丝雀=charCodeAt 热路径、comptime denylist
（forwards_call/construct/无孪生全拒）+Debug/RS 运行时 assert 兜底。诚实处=承认可寻址上限
未测，P0 普查前不开刀。

修正 B-R1：P1 单独 FW 可能吃不满 30M（assume 0x1c0 壳在 P1 仍在路径上，大头在 P3 短路）——
若 P1 单测 <30M，允许以 P1+P3 探针支（measurement-only、不合入）合并测量裁决整层去留，
避免在分段台阶上误杀好层。P3 产品化仍须独立几何审（0x7b4 墓碑垫回义务）。

## 五期 A 线：CH3-P0 普查裁决（2026-08-17，driver 裁）

**判定：REJECT-ARCHIVE（R2 硬门执行）。** zoo 并集、融合后、§1.3 切窗：小组件 3 冠军
get_loc8→mul→get_loc8 39.17M hop（98.6% crypto）×0.2–0.4 = 7.8–15.7M cyc < 30M；
4 原子冠军 23.90M 更矮；两槽并集乐观端 29.96M 仍不过线；全形列同头（肥窗未另开矿）。
与 SUPERCHAIN（08-16）逐形吻合——wave-41 未改 compute 窗分布。254/255 保全未占。
机制设计（CH3-DISPATCH-SPIKE）合宪入档；重开条件=肥 op「共享热臂、LLVM 保证不克隆」新证据。
工装钩子不入库。

**A 线后继：** 分派形态税的残余矿脉在肥 hop（box2d/TS 的 get_field 链，分案 6.6M 级并集、
单案数十 M），v1 合同禁入。派 scoping spike（只设计）探「肥 op 窗合法形态」是否存在。

## wave-42 裁决（2026-08-17，driver）：MERGED @9adaba7f

双刀=MIXED-EQ-SPLIT@0193dc6d（mixed 相等臂无帧化，last-ref/string 归带帧兄弟，int 叶 64B 不动）
+ put-atomidx@8ba9cd61（普通类具名 put 砍 atomIsArrayIndex 守卫）。
gate 全绿（478/478+GATE-OK+SAFE-OK）。三 pad 同号：geomean +0.47/+0.77/+0.47%，
TS 1.0184–1.0228、box2d 1.0098–1.0115、DB 1.0025–1.0053、splay 0.9982–1.0013、
richards 三 pad 齐 +2.8%（eq 密集意外受益）。regexp pad7 0.9882 孤 pad 翻号=惯常噪声。
**w42 为「执行全下放」新模式首例：pV 执行官全程跑批，driver 仅亲读产物裁决。**
官方分数榜候 zoo-par 出数另记。

## 五期 B 线：P0 交付裁决 + B-R1 探针放行（2026-08-17，driver）

NATIVE-THIN-P0 ACCEPT：thin_leaf 旗+comptime 四拒+单测（offset#32 钉死），零行为，
grok/native-thin-p0。普查（无 tracefs，CG 样本不当 call count）：② 壳 Σ656M（NMFD 338+assume 318）
由全部 n≈28M 调用共付；金丝雀 charCodeAt Direct 58M 是③体非②壳；P1 协议单独可退役 <30M 确认
（7 参 marshall ~6M + Direct 帧瘦身）。裁：**P1 不当刀立**；按 B-R1 开 P1+P3 探针支
（measurement-only）钉金丝雀份额 f 并量整层去留。P0 待 P1 裁决后同波合入。

## 五期收束双裁（2026-08-17，driver）

**1. CH3-FAT 不可达定理 ACCEPT，通道 #3 整体收案。** 共享不克隆⇒只能跳唯一热臂⇒musttail
不返回/返回即外提/同函数多出口即 monolith——4 参 musttail 机器上无第四种控制转移。矿证：
gf→gf 对 hop 并集仅 22.5M（TS 10.2/box2d 6.7），架构段残差不在字段 hop（box2d=BIN-MUL +30M；
TS get_field 热臂已短于 qjs CASE）。254/255 永续保全。未来 toolchain 新能力的收件四门已存档。

**2. B 线瘦层探针 NO-GO ACCEPT，thin-tier 归档。** f≈0.27，P1+P3 合并金丝雀本地仅 −22M，
pdfjs FW 主尺 +32.7M（去离群 −17M）均 <30M；raytrace 哨 +275M。根因=v1 保 sf 语义下瘦终端
0x190 与 assume 0x1c0 换房东；税打在 1−f=73% 非金丝雀上。探针支 ad4d275b 封存为反证。
P0 旗支不合入。真问题改写：② 壳是单价密度差（z ~23 cyc/call vs q ~5），非层次差。

**五期总账：** faithful 域五落后项全部持签字封条——pdfjs（壳密度+string 表示层）、
EB（L1I 墙 S3-B）、TS（call/return architectural+残刀见底中）、box2d（BIN 族 IPC）、
splay（⑦ RC 固有）。对冲模型前提「融合通道先干涸」已成立（#2 收官、#3 归档）。

## 六期首裁包（2026-08-17，driver）

**1. IC-SPIKE APPROVED + P1 金丝雀放行**，附三修正：IC-R1=delete 同位语义测试（Property 字
确实改变=guard 承重假设）必须在任何 zoo 跑批前以 difftest+单测证成；IC-R2=get_field_field2
去克隆（musttail 回正本）在 P1 内独立 commit+nm 几何门（可二分）；IC-R3=vm.ic_base 若致摊帧
即删（spike 自含，升为硬门）。P1 主尺 TS cyc 3-pad 同号、box2d/EB/四资产哨、28 insn 硬顶。
**2. pdfjs 壳封条 ACCEPT**（22.0 vs 4.6 cyc/call 对账；三大块=RC 收栈贴标/sret repr/0x3f0
红线皆非宪内可删；B-R1 探针已证切 hop 是换房东）。pdfjs 残余=壳封条+string 表示层，IC 覆盖其
get_field 段（mono 90.8%）。
**3. splay 分布 ACCEPT**：真落后 1.3%（中位 0.987，P(≥1.0)=0），非双模态。IC 受益标的
（2 槽 poly 吃 81%，P4 议题）。
**4. TS-RESID-W42 ACCEPT**：+5.00→+3.58G，闭合 96.3%，残全系 call/return architectural——
IC 对冲 TS get_field 占用 18.26G 为唯一翻案路径。

## IC-P1 首发裁决（2026-08-17，driver）：未过门，批准唯一一次瘦身迭代

首发：命中臂 48 insn（硬顶 28）、自测 FW TS 1.681/box2d 1.360/EB 1.025 同号差、
3 条 Proxy [[Set]] test262 新红（诚实披露未藏）。已成件：IC-R1 delete 语义证成 PASS、
IC-R2 field2 去克隆（0x20c→0x4）、7B 编码全链、岛几何全过（0x340 钉满/if_false8 同址/0 bl/0 帧）。
裁：**非「加形再试」而是「按已批目标形完成实施」**——首版多付=热扩三载寻址+state/count/magic
五比（spike §3.2 目标形只有 shape*+Property 字两比+ic_base 单载）。瘦身令：①先修 3 条 Proxy
[[Set]]（语义先于性能）；②vm.ic_base 单载（IC-R3 边界：摊帧即删）；③热路径只留两比
（site_id 有效性由 emit 保证信任之，对齐 main 现行「trust bytecode atom roots」先例）；
④objdump 复验 ≤28。终门：TS FW cyc 同号降，否则 **整通道 REJECT-ARCHIVE**，回滚至只留
IC-R1 测试资产（7B 编码与 R2 去克隆无 IC 则无收益，一并回滚）。D-cache 风险（spike §7.4）
由瘦身后 FW 判定。

## IC-P1-V2 终裁（2026-08-17，driver）：通道 REJECT-ARCHIVE，抢救件走链

V2 按令执行完整：目标形接到、终门跑满 ABBA n=4、FAIL 即回滚（tip=e1a7432f 仅留
Proxy 修复+IC-R1 测试；产品 IC 全剥；试验树另存 archive 支）。V2 产品曾见 test262 RF
7775-7800 窗 SIGSEGV（终门已死未深挖，产品已剥无此路径）。抢救件=object.zig +4 行
proto.isProxy() 拒走（对齐兄弟函数既有 proxyTarget 检查）+3 条 test262 转绿+单测，
派执行官走 gate 链合入。六期对冲实验闭幕：五封条+IC 否证=全 15≥1.0 无已知路径，递用户终裁。

## w43 抢救件合入（2026-08-17，driver）

grok/ic-p1@e1a7432f 合入 main：Proxy [[Set]] proto 拒走修复（main 既有语义洞，
setOrDefine 原型走对 Proxy proto 缺 isProxy 检查）+IC-R1 delete 语义测试两条。
全 gate 绿：480/480、夹具 7/7 IDENTICAL、Proxy 三案转 PASS、test262 0/49775
（passed 44581=+3）、RS 绿。语义件无 3-pad。IC 战役物质遗产至此全部处置完毕。

## 七期 L1 裁决（2026-08-17，driver）：repr 无缺口 + NATIVE-RET-ABI 刀立项

L1-REPR-DIVERGENCE ACCEPT：04be2460 引用件=16B tagged（DWARF line229/ldp×381/lsr#32×0/
FreeValue tag@x2 四签名），z tagged 已镜像引用件——repr 忠实缺口不存在；nanbox 属新偏离
且杀门预判全红（dup 16>12/get_field 0x344 址漂/D12 串惩 10>3/sret 不灭），永闭。
**更正 PDFJS-SHELL-UNITCOST §0 一处归因**：「q 是 NaN-boxing uint64 走 x0」误——实为
x0+x1 双寄存器 16B 返回；107M sret 税真身=z 的 Zig HostError!JSValue 错误联合逼 sret，
vs q 的 JSValue 直返+JS_EXCEPTION 哨兵 tag。壳封条该行改判为**可攻**：镜像 qjs 错误
模型=忠实域。立刀 NATIVE-RET-ABI（pW）：native 调用链（NMFD↔assume↔终端）返回值改
JSValue 直返+异常哨兵 tag，设计先行分期落地，预算 107M（≥30M 门宽裕），0x1c0/0x7b4/
0x3f0 几何宪照守。

## 七期五层收官（2026-08-17，driver 裁）

自底向上忠实差异审计全梯完成，五层封条：
**L0 局部性**：z 堆图不劣于 q（splay walk z≤q、TS L2/LL 更好），无 d-side 税。
**L1 值表示**：引用件=16B tagged，z 已镜像；nanbox 永闭；产出 NATIVE-RET-ABI 刀（107M）。
**L2 属性几何**：唯一分叉（FAM 段序）实测翻序 REJECT（TS insn +1.3G/EB 哨同号差）——
z 的 props-first 序对 z 访问构成经济正确，分叉=合理适配非缺陷。刀支归档。
**L3 RC 纪律**：十四惯用法全镜像（12 条税 0/I12 q 多付/I13-14 噪声级）；五案 RC 次数比
0.82–1.03；splay ⑦/TS ④a=帧字段占用非 RC 对盈余。emit 借用消除停（q 无对应形）。
**L4 算术**：int 门/overflow/−0/规范化同构；box2d +30M=符号边界记账不对称+IPC 弥散。
**梯子总结论：z 在 L0-L4 与 qjs 实现级已齐平或更优；全部候选净收窄至 NATIVE-RET-ABI 一刀。**

## NATIVE-RET-ABI PR-1 裁决（2026-08-17，driver）：立刀 ACCEPT

pdfjs FW Δcyc −180.2M（门 −30M，全样本 P1<全样本 BASE）；汇合口 str q0,[x19] 消失；
NMFD 帧 0xd0→0xa0、assume 体 0x320→0x2d8、0x7b4 墓碑垫回（0x2a8→0x294）、0x3f0 不涨；
test-exec 480/480（Interrupted 金丝雀首轮 3 红已修=nativeHostError 还原）。NativeBits=
u128 bitcast 破 Zig 16B extern sret，AAPCS64 合同内。raytrace 哨 +129.5M cyc/−130M br
分数重叠记噪声，w44 三 pad 终判。批 PR-2 叶面（五叶去 mov x19,x8）。

## wave-44 裁决（2026-08-17，driver）：MERGED

NATIVE-RET-ABI 两段（P1 链内三环 a65ed5c9+P2 五叶 7f905d35）合入 main（与已测 rev
00302c38 引擎码逐字节同，base 差仅 docs）。gate 全绿（480/480+test262 0/49775+RS 不扩）。
三 pad 同号：geomean +0.35/+0.41/+0.43%，pdfjs 1.0113–1.0158 主标的兑现，raytrace
0.9989–1.0055 哨清白，DB/regexp/mandreel 皆正，资产零负。七期唯一存活刀落袋：
sret 汇合口 196M 忠实回收（镜像 qjs JS_EXCEPTION 错误模型）。

## EB-S1-HYGIENE 裁决（2026-08-17，driver）：刀 REJECT，负结果入归因账

塌副本实测（grok/eb-s1-hygiene@bc2e9ddb，未合，留作反证）：traceChildren 2→1（−20.6KB）
+MemoryAccount 28/13→1，正确性全绿，但 EB Δcyc +72.2M、refill **+22%**（预期反向）、
TS +249M/splay +79M insn 双哨回退。根因=单态副本内含常量折叠+直跳，合一后付间接 visit
+共享 malloc 参数税。**定理追加：单态副本=定价资产非免费膨胀**（与热体外提四连败/
FAM 翻序 REJECT 同族——「特化是承重」第三证）。瘦身工程 A3 最廉子刀死；主路径收窄为
A1 冷叶出岛（纯迁冷体不动热形）。

## EB-HOT-RESIDENCY 归因（2026-08-17，driver 收）：墙形改写

计分窗取指账（l1i 110702 样本）：岛 182KB 仅 55KB/83 符热（113KB 零样本）；岛外助手
30.9% 取指散落 286KB 并集；GC-RC 仅 16% 取指/3.8% refill。90% 取指=68 符/125KB≈2×L1I
但碎。冷迁账：either=0 共 249 符/112.7KB，搬完岛剩 ~69KB。
**三个改写：①墙形=65KB 热叶+岛外碎片，非整岛过大；②L-1.5 失败可能系聚错集合
（426KB 并集 vs 本窗 125KB——按 68 符号聚未做过，方案讨论时重审）；③GC/RC 在取指侧
几乎不承重（refill 3.8%），三分账边界待重画。** 材料候 pQ/pV 函数账齐后合并讨论。

## RET-ABI-TYPED（2026-08-17，driver 收）：刀冻结候议，壳新账入归因

pW 改令前在途件：typed TLS 臂 NativeBits 延伸实测 pdfjs −48M（过 30M 门）。按「只归因
不优化」阶段令：**分支冻结不合**，列归因后方案讨论首位候选。归因交付=post-w44 壳新账：
② 壳残 NMFD 288M+assume 175M+typed 28M≈491M（656M 起点已收 196M）。

## EB 分侧驻留（2026-08-17，driver 收）：容量墙=Earley 墙

Earley refill/cyc 0.0224 vs Boyer 0.00338（6.6×），周期近对半。Earley 90% 热集
79 符/131KB 且碎（岛 37%+助手 37%+GC 23%，traceChildren×2/destroyRuntimeCycles/
capture*/arguments/get_array_el 独有热）；Boyer 90%=30 符/44KB 岛 67%，**进 1×L1I，
取指无病**，get_field 占用 14%（Earley 仅 2.5%）。Jaccard 0.37。
**改写：瘦身工程若立项，标的收窄为 Earley 工作集；Boyer 差距属执行侧账（候 pQ 分侧
z/q 比值定量）。GC 机器在 Earley 取指热（23%）——S1 反证的两份 traceChildren 正是
Earley 热叶，特化承重再获交叉印证。**

## EB-HOT-RESIDENCY 收口（2026-08-17，driver 收）：A1 也救不了 Earley

冷迁账终版：两侧都冷 239 符/108KB、纯冷页 88KB、搬完岛剩 61KB；但 **Earley 独热岛叶
仅 7KB——冷叶出岛清的是岛，吃不到 Earley 的 miss 源**（岛外构图助手 37%+GC 机器 23%
取指，散 286KB 并集）。墙叙事三改：整岛过大→Earley 独墙→Earley 岛外助手碎片墙。
原 S3-A（岛密度）方案的立项理由被本普查逐段拆除；可能的替代假设（候函数账后议）：
①按 Earley 79 符/131KB 真热集聚簇（修正版 L-1.5，聚对集合）；②Earley 构图/GC 助手
的工作量本身（allocation 压力→GC 取指热）。全部候 pQ/pV 函数级账定量后合并讨论。
