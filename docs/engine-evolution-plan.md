# zjs 高性能执行引擎演进方案

Version: 0.6(正文归一化,roadmap v1.7 对齐)
Date: 2026-08-26
Status: approved-with-conditions — **Phase 0 批准立即执行**;
Phase 0.5 不再「立即执行」,经 **PERF-DYN-SPIKE→G1-FEEDBACK** 裁决
通过后方立项 PERF-P05(立项方式/四态输出/全部前置见 §六 状态框);
Phase 1-Z 已搁置归档(§7.0);Phase 1A/1B 为 incubator 项(§7.1);
Phase 2(baseline JIT)由独立 **PERF-JIT-SPIKE→G1-JIT** 裁决,硬
输入 = canonical bytecode + PERF-VMABI,动态反馈与 typed metadata 均
仅为可选增强,与原生 AOT 为两个 backend 的分叉、不共享 emitter
(§8.1)。批准条件见 §5.6 与 §14。
前版:0.1-0.3;0.4(评审定稿,2026-08-24);0.5(roadmap v1.5 治理
对齐,2026-08-26)

Review note(0.5 → 0.6):正文归一化——页首裁决吸收进正文,删除被
覆盖的旧结论;无新设计。gate/里程碑表述对齐 roadmap v1.7:动态反馈
gate 定名 **G1-FEEDBACK**(0.5 沿用旧名 G1-JIT),输出四态
disabled/collect-only/monomorphic/PIC2;JIT 硬输入收窄为 canonical
bytecode+PERF-VMABI(动态反馈降为可选增强);FNABI M1 拆分
M1A/M1B/M1C(§9.1)。落点:§六 状态框、§8.1、§3.4、§9.1、§7.1。

Review note(0.3 → 0.4):吸收 2026-08-24 dispatch 重验战役的四组实测
证据与源码核查,三项实质修正。其一,**§2.1 立项事实勘误**:热 JS→JS
调用不往返 driver(warm 家族域内进入 callee;`.tail` 仅冷形态),
§2.2 增量④从"结构性余量"降级为"已收割,残余=冷形态+①的 bl 溅射税";
1-Z 立项理由相应重写、预期下调。其二,**免测清单入文**(§2.4):lean
dispatch 三骨架打平、asm 纯 dispatch 头顶空间=0、冷壳 dispatch 全
corpus 0.000%、helper-dense 单体 ~3.5% cyc 等已有冻结二进制 PMU 结论,
1-Z/1A 不得重测。其三,治理修正:Phase 0.5 前置宪章退役记录;1-Z 增加
预门槛(Phase 0 频率数据算术投影)与布局彩票验收条款;1A 撤销 `.text`
单独过门;§7.0"取指软流水"论述删除(asm toy 实测证伪)。

评审基线:`main` @ 2026-08-24 工作区;dispatch 重验证据见 §2.4,原始
产物在 `.scratch/dispatch-reeval-2026-08-24/`(会话本地,关键数字已
全部内联本文,不依赖该目录存续)。

目标:解决当前 tail-call opcode handler 的编译器依赖与布局防御税,并为
baseline JIT 与 optimizing JIT 建立统一底座;同时不与进行中的 tracing GC
迁移计划([tracing-gc-design.md](tracing-gc-design.md))互相锁死。

关联方案(2026-08-25 注,总纲双向引用):

- **静态轴姊妹方案**:
  [type-directed-optimization-plan.md](type-directed-optimization-plan.md)
  (v0.8,DRAFT)——TS 类型驱动的 typed bytecode 与 AOT 路线,与本
  方案的动态轴互补;FNABI 里程碑已拆分(roadmap v1.7):M1A 不依赖
  本计划,M1B←F1,M1C←F2(不再整体挂 S1 全就绪)。
- **原生插件 ABI**:
  [fun-native-plugin-design.md](fun-native-plugin-design.md)
  (FNABI v0.3,2026-08-25 采纳)——§9.1 的 NativeCallDescriptor 与
  FNABI 的 `NativeCallPlan` 统一为单一 schema;runtime-plugin-abi.md
  已 deprecated。

---

## 一、结论

总路线(0.1→0.3 谱系,0.6 按 roadmap v1.7 治理归一):

> 先把执行状态协议正式化为统一 VM ABI;其上的动态反馈与 baseline
> JIT 各由独立 spike/gate 裁决(PERF-DYN-SPIKE→G1-FEEDBACK、
> PERF-JIT-SPIKE→G1-JIT),不链式绑定;IC/native direct call →
> optimizing tier 按层递进;解释器骨架重造(labeled switch / asm)
> 降级为条件项与平台保险单,由算术预门槛与 iOS 排期驱动,不再是
> 主线前置。

0.4 相对 0.3 的三项核心修正(依据见 §2.4、§7.0):

1. **增量④已收割。** 源码核查:热调用经
   `pushWarmExactArgsLeafAndEnter`/`pushAndEnter` 家族域内雕帧并直接
   进入 callee;`return .tail` → driver 仅存于 generic `execCall`
   兜底、apply、spread 构造器等冷形态(在册普查先例:padded-leaf 家族
   3273 hits / 221.9M calls = 0.0015% 被删)。定量旁证:call_const 对
   qjs 的总 insn 差仅 28/iter,装不下一次 driver 往返(~30–60 insn)。
   真实 call 差距(cyc 1.18–1.29)在进出帧语义机器(几何定价、poll
   次序、budget 记账、内存流量),**换骨架删不掉**。
2. **解释器轨已在微架构地板上。** 三骨架(tail-call / labeled switch /
   手写 asm)同臂体同程序实测同坐 ~20.7 cyc/iter(§2.4);asm 省 16%
   insn 兑现 0.0% 时间。解释器骨架的可测余量收敛为:①helper `bl`
   溅射税(~0.7 cyc/bl,权重待 Phase 0 频率数据)与 ③LLVM 布局防御税
   (双向,见 §7.0 风险)。
3. **1-Z 增设算术预门槛。** Phase 0 的 helper 频率报告出来后先做投影:
   call-heavy 切片上 (warm-path bl/iter × 0.7c + Vm 载荷提升项) 的
   上界 < 2% → 1-Z 搁置,ABI 按 tail-call 骨架定稿(Phase 2 由其
   独立 gate 裁决,§8.1);
   ≥ 2% → 1-Z 以 time-box 形式执行。1-Z 是保险单,不是主菜,不得
   挤占 Phase 2 窗口。

保留自 0.3 的核心修正(第 1–7 项,依据见 §2、§3):RC 语义补全、
tracing GC 排序前置、IC/反馈线(0.6 修订:立项经 PERF-DYN-SPIKE→
G1-FEEDBACK 裁决,不再默认前置,§六)、call/return 入域(范围要求保留,
理由按上文修正)、收益叙事对齐现状、labeled switch 先行于 asm、iOS
确认为未来目标(asm AArch64-only)。

修订后的阶段序列:

```text
Phase 0    测量补全 + 执行状态 ABI 冻结(立即,治理门要求的证据)
  ├─ 前置裁决:asm 路线 vs tracing GC 迁移排序(已裁决:A,§3.1)
  ├─ 前置裁决:qjs-faithful 宪章退役记录(Phase 0.5 前置之一,§3.4)
Phase 0.5  解释器级 property/call 反馈槽(纯 Zig;经 PERF-DYN-SPIKE
           →G1-FEEDBACK 裁决后启动,全部前置见 §六 状态框)
  ├─ 并行轨:NativeCallDescriptor 正式化(扩展 src/binding/ffi.zig)
Phase 1-Z  labeled switch 解释器原型(条件项:预门槛 ≥2% 才启动;
           time-box;含 call/return 入域)
Phase 1A   asm microkernel 原型(AArch64-only;启动 = 1-Z 未达标且
           iOS 排期进入执行窗口;门槛见 §14)
Phase 1B   完整汇编解释器(1A 过门后;x86-64 asm port 已撤销)
Phase 2    低延迟 baseline JIT(独立 PERF-JIT-SPIKE→G1-JIT 裁决;
           硬输入=canonical bytecode+PERF-VMABI;反馈为可选增强)
Phase 3    OSR + 完整 IC 状态机 + native direct call 融合
Phase 4    Guard + Snapshot + Deoptimization
Phase 5    Trace 或 Region Optimizing JIT(profile 后决定)
```

解释器轨道的决策规则(0.4)——**已走完(2026-08-24)**:

- 预门槛 < 2% → 1-Z 搁置归档 ✅ **此分支成立**(owner 决议 D5-A,
  依据 §2.4(g)):tail-call 为常青生产解释器,ABI 按其定稿;
  Phase 2(baseline JIT)由独立 PERF-JIT-SPIKE→G1-JIT 裁决,
  不与 0.5 链式绑定(0.6 修订,§8.1);
- ~~预门槛 ≥ 2% 且 1-Z 达标 → lswitch 转生产~~(未触发);
- 1A 仅当 iOS 窗口开启时按 §7.1 评估重启,否则同搁置;
- 最终退路即现实:现役 tail-call 解释器 + baseline JIT 原型路线。

---

## 二、现状基线

本节是所有后续设计决策的地基。§2.1–2.3 承自 0.3(已对照源码核实),
§2.4 为 0.4 新增的 dispatch 重验证据基线。

### 2.1 仓库事实(0.4 勘误后)

| 事实 | 出处 |
| --- | --- |
| bench-v8 composite **1.0464×QuickJS**(zjs 2706 / qjs 2586,7/8 ≥ 1.0);唯一落后 EarleyBoyer 0.879。**历史口径注(2026-08-25)**:此数为 V8 suite v7 / GCC-13 参考二进制口径;套件已于 2026-08-25 换为 Octane 2.0(v9),跨套件/跨参考二进制的 ratio 不可比,现行快照与官方 yardstick 归属(owner 待裁决)见 [perf/bench-v8-status.md](perf/bench-v8-status.md) | [perf/bench-v8-status.md](perf/bench-v8-status.md) |
| zoo 内部诊断:geomean 1.0304;落后项 pdfjs 0.849、earley-boyer 0.886、box2d 0.955、typescript 0.958,均以分配/调用密集为主。**历史口径注(2026-08-25)**:同为 GCC-13 参考口径的冻结基线,基线文档已移出树(git history 可回溯) | 工具见 `tools/perf/zoo/README.md` |
| test262:44,584 pass / 0 unexpected failures,语义已稳定 | `STATUS.md` |
| dispatch 现状:每 opcode 一个 `callconv(.c)` handler,`@call(.always_tail)` 经 256 表尾跳;pc/sp/var_buf 驻参数寄存器,其余挂 `*Vm`(x3);热 handler 帧 ~80–150B,叶级热臂零 prologue | `src/exec/tailcall_dispatch.zig` |
| **热 JS→JS 调用不往返 driver(0.4 勘误)**:warm exact-args / capture-leaf / plain 家族经 `pushWarmExactArgsLeafAndEnter`/`pushAndEnter` 域内进入 callee;`return .tail` → driver 仅存于 generic `execCall` 兜底、`op_apply`、spread 构造器等冷形态 | 同上 opCall 段;冷形态频次先例:padded-leaf 0.0015% 普查删除(在册注释) |
| 3504B 帧问题已被 tail-call 拆分解决(comptime-delete bisection 证明),不是现役痛点 | 同上头注 |
| 现役布局防御税:section 钉扎、源码顺序布局约定、"handler 零非尾调用"铁律、retired-slot 复用;合并 handler 需冻结二进制+反汇编+多构建 PMU 证据 | 同上;[architecture.md](architecture.md)(Stack Bytecode VM Status 章)§3 |
| `JSValue` = 16 字节 extern tagged + 引用计数;VM 存活协议 = refcount-on-push + 确定性 teardown | `src/core/value.zig`、[gc-invariants.md](gc-invariants.md) |
| tracing GC 迁移是已过评审的并行大工程,分阶段 gate,RC 迁移期间保持权威。**状态注(2026-08-25)**:实现在分支 `gc/tracing`(未合 main);08-25 缺陷批次(major 从不触发,`f10855c6`)作废此前全部吞吐证据,合入前须重新过门 | [tracing-gc-design.md](tracing-gc-design.md) v0.5 |
| 今天没有任何 IC:`FunctionBytecode` 无 site/slot 表;`property_direct.zig` 为非缓存直通 fast path(probe-first、实测链长 1.0、命中率 100%) | [architecture.md](architecture.md)(Stack Bytecode VM Status 章)§4 |
| ES2015 PTC 已实现(strict 平调用尾折叠为 `tail_call`,常量栈),文档化分歧 | 同上 §5;`LIMITATIONS.md` |
| opcode 级 profiling 构建已存在(`zig build zjs-profile`) | 同上 §7 |
| 中断/停点机制:`active_dispatch_tbl` 换表实现 L0 stop seam | `src/exec/tailcall_dispatch.zig` |
| 测量契约已冻结:单机、钉核、ABBA 交错、偶数样本 | [perf/bench-v8-status.md](perf/bench-v8-status.md) |
| 治理门:仅当 PMU 证据显示 operand traffic / dispatch 为主瓶颈时才重估字节码架构 | [architecture.md](architecture.md)(Stack Bytecode VM Status 章)§8 |

### 2.2 边际收益校准(0.4 修订)

现状 tail-call 解释器已经是 replicated direct-threading:每 handler
独立间接尾跳(独立 BTB 站点),热状态驻寄存器,叶臂零帧。汇编/单体
相对现状的候选增量四项,0.4 按重验证据逐项标定:

1. **callee-saved 钉扎(helper `bl` 不溅射 pc/sp/var_buf)**——真实,
   实测 ~0.7 cyc/bl(§2.4 bl_qjs 对照);**权重未知**,取决于热路径
   bl 频次,Phase 0 §5.2 测量后由预门槛算术裁决;
2. 镜像常驻寄存器(code_base/表基/rt 从 Vm 载荷升级)——常数项,
   现役已有 vm.tbl 驻留等部分收割,残余小;
3. 摆脱 LLVM 布局博弈及其防御税——真实但**双向**:单体/asm 免除
   per-handler 防御,换来全函数布局彩票(单臂编辑=全解释器重抽签,
   实测单 pad 字段 ±2.1–2.4% cyc 量级)与手工维护税;
4. ~~call/return 入域消除 per-call driver 往返~~——**已收割**
   (§2.1 勘误);残余仅冷形态,频次 ≈0。

合理预期收益(0.4 下调):call-heavy 切片低个位数(①主导,待频率
数据);dispatch-heavy ≈0(§2.4 三骨架打平);分配/GC 主导 ≈0。
`.text`:op_handler section 实测 163 KiB = text 段(3.74 MiB)的
4.3%(qjs `JS_CallInternal` 对照 43 KiB);全部压缩到 LuaJIT 密度也
只回收 ~2.7% 二进制,不构成独立立项理由。

### 2.3 由基线导出的决策

1. microkernel/1-Z 不含 call/return 则测不出 ① 的真实权重(bl 密集
   点在 warm 构造器),call 必须入域(§7.6)——范围要求保留,理由按
   0.4 修正;
2. 落后项与 GUI runtime 目标都指向 property/call 语义成本 → 动态
   反馈立项证据由 PERF-DYN-SPIKE 购买、经 G1-FEEDBACK 裁决(§6),
   NativeCallDescriptor 轨见 §9.1;
3. "打败 QuickJS"已完成;本方案按"逼近 JIT 级引擎"目标立项,Phase 1+
   批准以 Phase 0 PMU 证据为条件,满足治理门。

### 2.4 dispatch 重验证据基线(0.4 新增,免测清单)

2026-08-24 四组实验,冻结二进制、CPU19 钉核、ABBA 交错偶数样本、
insn/cyc 同测、min 口径。**以下结论 1-Z/1A 立项与验收直接引用,
不得重测**;原始脚本与数据 `.scratch/dispatch-reeval-2026-08-24/`。

**(a) 今日探针 vs qjs(8 样本)**——dispatch-bound 已反超,残差在
调用机器:

| 探针 | insn | cyc |
| --- | --- | --- |
| L0 空循环 | 0.877 | 0.842 |
| accum_var | 0.629 | 0.911 |
| accum_let | 0.981 | 0.923 |
| call_const | 1.072 | 1.184 |
| fib | 1.134 | 1.292 |

**(b) 同臂体三骨架 toy(91 臂,4 carrier,lean 程序,每迭代)**:

| 骨架 | insn/iter | cyc/iter |
| --- | --- | --- |
| 手写 asm(LuaJIT 式,寄存器全钉、每臂手排) | 58.07 | 20.77 |
| labeled switch(单函数,threading 保持,帧 64B 平坦) | 67.07 | 20.68 |
| tail-call(现役形态,叶臂零 prologue) | 69.07 | 20.66 |

三骨架同坐 ~20.7 cyc/iter 微架构地板(≈3 cyc/dispatch,间接跳转
taken 吞吐+依赖链);asm 省 16% insn 兑现 0.0% 时间。**"取指软流水"
(臂尾预载下一 opcode)在宽乱序核上无效**——asm toy 未做预载仍打平,
0.3 §7.0 的该论述删除。

**(c) helper-bl 形态对照(toy,bl_qjs=裸 C 契约 / bl_zjs=现役
publish→错误联合→重建契约)**:

| 程序 | labeled cyc/iter | tailcall cyc/iter |
| --- | --- | --- |
| bl_qjs | 20.28 | 20.98(单体赢 ~3.4%,即增量①) |
| bl_zjs | 30.30 | 28.76(单体反输 5.4%) |

现役冷契约 +10 cyc/冷事件(30.3 vs 20.3),且单体承载它比 tail-call
更差——单体化若不同时改写冷契约,冷路径反而回退。

**(d) 冷壳 dispatch 动态普查(zjs-profile,bench-v8 全套六基准 +
三微探针)**:冷壳占比 **0.000%**(唯一非零 navier-stokes
get_array_el3 0.334%)。仪器先以构造的 10% 冷负载验证检出能力。
边界税在本 corpus 上无频次。

**(e) 规模与体积静态事实**:91 臂单体帧 64B 与 16 臂逐字节同(悬崖
变量是 carrier 数不是臂数;07-14 在册:5-carrier 91 臂 pinned、
6-carrier 60 臂崩);op_handler section 163 KiB / text 4.3%;qjs
`JS_CallInternal` 43 KiB。

**(f) 历史对照**:2026-07-14 真实臂体单体实验(混合形态,三轮
workflow)PMU 4/4 基准回退 +2~26%,结构假设全过仍败——toy 通过
不能外推真机,该教训对 1-Z 同样生效(§7.0 风险)。

**(g) 增量① 频次侦察(同日,scouting 级:br_return_retired 代理、
min-of-4、CPU19)**:热路径原生调用频次 ≈ 零——l0_empty 0.001、
accum_let 0.002、**call_const 0.007、fib 0.006 returns/iter**。
预门槛投影 = 0.007 × 0.7c ≈ 0.005c/iter ≈ **0.0% « 2%**,低估一个
数量级仍不过线。方向性结论:臂级工程(零 prologue 叶+tail 路由)已把
热路径 bl 消灭,增量① 的动态权重为零;Phase 0 正式仪器仅需确认,
1-Z 预门槛预判**搁置**。

---

## 三、前置裁决(owner decision)

### 3.1 与 tracing GC 迁移的排序 —— 已裁决:A

GC 迁移推进到值表示定型(shadow tracer + Slot 决议)后再动 Phase 1B;
Phase 1-Z/1A 原型可先行,但值移动必须走生成宏(§7.4),表示切换时改
生成器不改 handler,重写成本计价在裁决记录。shadow-tracer 阶段(非
搬移、RC 仍权威)与解释器轨共存;冲突集中在 Slot/两字表示及其
barrier。

### 3.2 平台矩阵 —— 已部分裁决(iOS)

**iOS 为未来目标(owner,2026-08-24)。** 直接后果:

- asm 解释器范围收缩为 **AArch64-only**;x86-64 asm port 撤销,x86
  平台由 lswitch/tail-call 解释器覆盖(§7.8);
- iOS 禁 JIT → 该平台解释器即产品上限(**限定注 2026-08-25**:此
  上限仅指动态轴;静态轴的 typed AOT 路线见
  [type-directed-optimization-plan.md](type-directed-optimization-plan.md)
  §5.1,该计划仍 DRAFT);该平台候选性能杠杆为解释器级动态反馈
  (Phase 0.5,价值待 PERF-DYN-SPIKE 实证,§六)与增量①;
  asm-vs-lswitch 差额在 Apple 大核
  (超宽乱序、大 L1I/BTB)上取区间下沿——§2.4(b) 在 X925 上已为
  零,Apple 大核只会更低;
- 手写 `.S` 须满足 arm64e:PAC 与 BTI(§7.2);解释器无运行时代码
  生成,W^X 硬执行下天然合规;iOS 构建 `-Djit=off` 常青。

仍开放:Windows x64 是否在目标内(只影响 baseline JIT 的 x86-64
后端);无汇编/无 JIT 平台由 Zig 解释器覆盖(§7.8)。

### 3.3 "first-class Zig project" 例外

手写 `.S` 是对 Zig 纪律的显式例外,需 owner 认可并写入
[architecture.md](architecture.md)。1A 优先尝试构建期由 Zig 生成
`.S`(§7.4 值移动宏同源),手写仅作 fallback。**注(0.4):预门槛与
1-Z 若走通,此例外根本不必开启——这是 1-Z 路线被低估的收益。**

### 3.4 qjs-faithful 宪章退役记录(0.4 新增,Phase 0.5 前置)

Phase 0.5 的反馈槽与三条现役裁决正面冲突:"qjs 没有的 fast path 必须
删"、IC 移除决议(对齐 qjs 的运行时结构)、"IC/fusion=换赛道"判。
本方案以"打败 QuickJS 已完成、目标改为逼近 JIT 级引擎"立新宪章,
**必须在 Phase 0.5 落地前按 [qcp1_switch_decision.md](qcp1_switch_decision.md)
体例出具显式退役/接替记录**。**已完成并批准**:
[qjs_alignment_charter_transition.md](qjs_alignment_charter_transition.md)
(退役 R1-R3 / 保留 K1-K5 / 接替对标制度 / 历史地位声明),状态
RATIFIED(owner,2026-08-24)。注(0.6):本记录仍是 Phase 0.5 前置
之一,但不再是唯一前置——另有 PERF-DYN-SPIKE→G1-FEEDBACK 裁决、
SidecarCore 容器协议 spec、08-17 IC 否证对账(全清单见 §六 状态框);
「已解锁」仅指本条前置。

---

## 四、目标架构

```text
                       JavaScript / TypeScript
                                │
                                ▼
                    QuickJS-compatible bytecode
                                │
               ┌────────────────┴────────────────┐
               │                                 │
               ▼                                 ▼
      Interpreter(tail-call 常青;             Baseline JIT
      lswitch/asm 条件项)                     linear compiler
               │                                 │
               ├───────────┬─────────────────────┤
               │           │                     │
               ▼           ▼                     ▼
        Zig slow helpers   Feedback/IC 槽    Native direct calls
               │           │                     │
               └───────────┴──────────┬──────────┘
                                      ▼
                               zjs Runtime
              object / RC+GC / regexp / proxy / exception
                                      │
                                      ▼
                         Future optimizing tier
                    SSA + guards + snapshots + deopt
```

边界原则:hot mechanics 归执行域(含值生命周期语义:RC inc/dec/zero
路径必须域内正确表达),完整 JavaScript semantics 归 Zig runtime。
解释器与 baseline JIT 共享 VM register convention、frame layout、
JSValue 表示、slow-helper ABI、opcode metadata、GC/RC 边界规则、
exception/interrupt 规则、patching 与 code metadata 约定;**不**共享
emitter。

---

## 五、Phase 0:测量补全与执行状态 ABI

### 5.1 已存在,不重复建设

opcode 频率计数与 delta 计时(`zig build zjs-profile`);冻结基准协议
([perf/bench-v8-status.md](perf/bench-v8-status.md));差分 oracle
文化;**§2.4 免测清单**。

### 5.2 新增量

- **helper 调用频率与形态普查(0.4 提为首位)**:热路径每迭代 bl
  次数、被调 helper 分类(value/stateful)、publish/reload 命中率。
  这是增量①权重与 1-Z 预门槛的唯一裁决数据——opcode 计数看不见
  臂内 bl,必须新增仪器;
- opcode 转移矩阵(A→B 频率):供 §7.7 布局与 hybrid dispatch;
- call-heavy(Richards/DeltaBlue 类)与 dispatch-heavy 微基准切片,
  作为 1-Z/1A 门槛的分层证据。

### 5.3 VmExecState

把隐含在 handler 参数与 `Vm.publish()/syncPc()/syncSp()/reloadSp()/
reloadPc()` 中的执行状态正式化(写成 ABI,不是新发明):

```zig
pub const VmExecState = extern struct {
    vm: *Vm,

    pc: [*]const u8,
    sp: [*]JSValue,
    fp: [*]JSValue,
    var_base: [*]JSValue,

    function: *const FunctionBytecode,

    exit_reason: VmExitReason,
    exit_value: JSValue,
};
```

约束:

1. 汇编/生成物使用的 offset 一律由 Zig 生成
   (`tools/gen_vm_offsets.zig` → `vm_offsets.inc` /
   `vm_registers.inc` / `opcode_ids.inc`),禁止手写;
2. `VmExecState` 是解释器、baseline JIT、slow helper 的共同状态接口,
   **对骨架中立**(tail-call 常青时同样定稿,不等 1-Z);
3. ABI 版本挂接编译配置签名(`layout=short/plain`、`repr=tagged` 等):

```zig
pub const VM_ABI_VERSION: u32 = 1;
// 生成物中嵌入 zjs-config 签名;不匹配 = 构建期错误。
```

### 5.4 Outcome 协议映射

现役 `Outcome`(`returned/threw/tail/suspended/reenter/native_returned`,
含 `TailMode` 三态与 native fence 语义)与 `VmHelperStatus` 的对应关系
Phase 0 冻结,不留双轨:

```zig
pub const VmHelperStatus = enum(u8) {
    continue_execution,
    exception,
    function_return,
    suspended,
    interrupted,
    bailout,
};
```

`tail`/`reenter`/`native_returned` 属解释器域内控制流(0.4 注:`.tail`
现役仅冷形态触发,见 §2.1),不进入 helper 状态字。

### 5.5 HelperDescriptor

```zig
pub const HelperDescriptor = struct {
    can_gc: bool,          // 可能分配 / 触发 cycle collection
    can_throw: bool,
    can_reenter_js: bool,

    reads_pc: bool,
    writes_pc: bool,
    writes_sp: bool,
    writes_fp: bool,

    returns_jsvalue: bool,
};
```

生成器据此决定 helper 前后 publish/reload、exception check 与
safepoint。交叉校验:Debug/ReleaseSafe 在 helper 入口断言声明与实际
一致(沿用 `var_refs_base` 双活断言文化)。既有 seam 不变量逐条移入
descriptor 语义,特别是**用户可观察 coercion 前必须先 `syncPc`**
(单列 `requires_pc_before_observable`)。

### 5.6 交付与验收

交付:helper 频率与形态报告(§5.2 首位)、转移矩阵、`VmExecState` +
版本/签名、`HelperDescriptor` 全 helper 覆盖、Outcome 映射决议、差分
harness 就绪。

验收:基准可重复;所有 VM state transition 有唯一书面约定;PMU 报告
能回答"dispatch/operand traffic 占比"与"热路径 bl/iter"(治理门
证据);**1-Z 预门槛算术(§7.0)与 1A 门槛数值在此报告后定稿**。

---

## 六、Phase 0.5:解释器级反馈槽

**现行状态(0.6,roadmap v1.7)**:本章是**若 G1-FEEDBACK 裁决实施
时的规范**,不是已批准执行项。动态反馈的立项证据由
**PERF-DYN-SPIKE** 购买(最小 per-site feedback/单态臂/二态 PIC 臂,
disposable 侧表),经 **G1-FEEDBACK** gate 裁决——输出四态:
disabled / collect-only / monomorphic / PIC2——裁决通过后才建
PERF-P05。开工前置(全部):①§3.4 宪章退役记录(已完成);
②SidecarCore 容器协议 spec(四方评审);③**08-17 IC 否证对账**
(「快臂已 2-3 cyc、旁挂缓存付不起 miss 税」与 08-25 op_get_field
哈希探测归因两轮证据的显式和解——回答反馈槽+侧车形态为何不重蹈
否证),对账未完成前不得开工。本章的反馈形态
(monomorphic→溢出→megamorphic,不做链式 PIC)可能被 G1-FEEDBACK
的输出 profile 修正:若 spike 证明只有 PIC2 赢,本章须先修订再实施。

不依赖任何解释器骨架工作,纯 Zig,在现役解释器落地;价值待
PERF-DYN-SPIKE 实证,预期主值 = Phase 2 的可选反馈输入(§6.2)。

### 6.1 形态

- `FunctionBytecode` **外部** side table(canonical bytecode 不改,
  与 §8.5 JitMeta 同一挂载策略):per-site 槽,按 bytecode pc 索引;
- property load/store 槽:monomorphic shape cache 起步(shape 指针 +
  槽偏移 + 版本),miss 走现有 `property_direct.zig` 路径并回填;
- call 槽:callee identity + 内部 builtin ID 反馈;
- 溢出即标记 megamorphic,不做链式 PIC(Phase 3 的事)。

### 6.2 消费者与收益校准(0.4 修订)

1. 现有解释器:**own-property 单态站点上赢面接近零**——现役
   probe-first 直通已是链长 1.0、命中率 100%、0.90x qjs 量级;解释器
   级的真赢面在**原型链命中缓存**(直通路径每次重走链)与多态站点。
   验收锚定 pdfjs/typescript/box2d,不得用单态微基准立收益;
2. Phase 2 baseline JIT:编译时读取反馈直接发射 monomorphic 快路
   (Sparkplug 之所以薄,因 feedback vector 已存在)——这是 0.5 的
   主要预期价值,解释器级收益是顺带;注(0.6):对 baseline JIT
   反馈只是**可选增强**而非硬输入(硬输入=canonical bytecode+
   PERF-VMABI,§8.1),Phase 2 立项不以 0.5 为前提;
3. Phase 5 optimizing tier:类型反馈采集起点。

### 6.3 失效纪律

shape transition / prototype mutation / builtin 替换必须失效;first 版
版本号验证(读时比对),dependency registry 留给 Phase 3。受既有审计
条款约束([architecture.md](architecture.md) Stack Bytecode VM Status 章
§6:可观察边界 + 受控 A/B + 门禁)。

---

## 七、Phase 1:解释器骨架(条件项)

### 7.0 Phase 1-Z:labeled switch 原型

**预门槛——已判定(owner 决议 D5-A,2026-08-24)**:依据 §2.4(g)
侦察数据(投影 ≈ 0.0% « 2%,低估一个数量级仍不过线),owner 接受
侦察为终判:**Phase 1-Z 正式搁置归档**。ABI 按 tail-call 骨架定稿;
Phase 0 的 bl 频率仪器降级为可选项;Phase 2(baseline JIT)由独立
PERF-JIT-SPIKE→G1-JIT 裁决,不与 0.5 链式绑定(0.6 修订,§8.1)。
本节其余内容(范围/风险/验收)保留为档案——若未来前提翻转
(如 iOS 窗口开启触发 1A 评估)按此重启。

立项理由(0.4 重写):**唯一开放问题是增量①与③的净值**。lean
dispatch 平局、纯 dispatch 无余量、冷壳无频次均已实测(§2.4 免测
清单,禁止重测)。1-Z 测的是:单函数内跨 `bl` 存活的 pc/sp/var_buf
被 LLVM 分到 callee-saved 后,真实 warm-call 路径(含 warm 构造器
bl)能否兑现 ①;以及全函数布局彩票与帧回涨风险是否可控(③ 的
负项)。

对照 §2.2 增量(0.4 修订):

| 增量 | tail-call 现状 | labeled switch | asm |
| --- | --- | --- | --- |
| ① helper `bl` 不溅射热状态 | ✗(驻 caller-saved x0–x2) | 大概率 ✓(LLVM 自然分到 callee-saved);toy 实测该形态 ~3.4% cyc | ✓ 契约化 |
| ② 镜像常驻寄存器 | 部分(vm.tbl 等已收割) | 部分 ✓(LLVM 决定) | ✓ |
| ③ 摆脱 LLVM 布局/帧博弈 | ✗ | ✗(且引入全函数布局彩票,负项) | ✓(换手工维护税) |
| ④ call/return 不出域 | **✓ 已收割**(热路径域内,§2.1) | ✓(等价) | ✓(等价) |

asm 相对成功态 lswitch 的净余量 = ③ + `.text` 下界 + 免疫编译器回退;
~~取指软流水~~(已被 §2.4(b) 证伪,删除);量级低个位数,Apple 大核
取下沿。

范围(达标口径与 1A 对齐):

- dispatch 脊柱单函数化;call/call_method/return 与 frame 切换入域
  (§7.6 语义清单:TailMode 三态、PTC 逐位对齐、budget 记账);
- 冷臂保持现有 outline 纪律:`@branchHint(.cold)` + publish + helper +
  `continue`;禁止把冷工作搬回臂内(帧回涨第一诱因);**冷契约不改写
  ——§2.4(c) 表明单体承载现役冷契约更差,该项算入 1-Z 的净账**;
- L0 stop seam 重设计:双循环切换(fast/instrumented,frame 边界
  切换)或模式检查;
- per-opcode profiling seam 从表包裹改为臂前言(comptime);
- 构建选项:`-Dvm=tailcall | lswitch`(§7.8)。

风险与对策:

- **全函数布局彩票(0.4 提为头号)**:单臂编辑 = 全解释器布局重抽签
  (在册实测单 pad 字段 ±2.1–2.4% cyc)。这不止是 1-Z 自身测量噪声
  问题,而是**转生产后每把后续刀的分辨率税**。对策与验收条款:
  §14 1-Z 验收含"单臂编辑扰动实验"(改一个非热臂,无关基准摆动
  ≤ 噪声带),不满足则即使 geomean 达标也须 owner 显式接受刀分辨率
  下降后才可转生产;
- 单体帧回涨(3504B/4256B 教训):旧单体是胖臂+多 carrier;现役瘦臂
  + 4 carrier 在 toy 上帧 64B 平坦(§2.4(e)),但真实富臂的活值并集
  更大,07-14 真机 4/4 回退在册(§2.4(f))。对策:反汇编帧测量 +
  comptime-delete bisection,满足证据门(冻结二进制+反汇编+多构建
  PMU);
- LLVM 寄存器分配失控(pc/sp 被挤下寄存器):反汇编验证驻留;失败即
  1A 的实测立项证据;
- 大函数编译时间;profile 不可分辨(臂前言计数补偿)。

外部教训(校准预期):CPython 3.14 tail-call 解释器最初宣称的 10-15%
后证实大半来自 LLVM 19 对 computed-goto 基线的编译退化,修正后余低
个位数。两种 replicated indirect dispatch 之间,可持久差异只来自
帧/寄存器控制(①③),不是 dispatch 形式本身——§2.4(b) 的三骨架
平局是本仓库的同型实证。

### 7.1 范围(1A 原型)

**状态注(0.6,roadmap v1.7)**:1A/1B 为 incubator 项,不在现行
active DAG;启动前置 = PERF-ASM-1A 通过 + GC 表示定型 + iOS 执行
窗口打开。

**AArch64-only**(§3.2);启动条件 = 1-Z 未达标 **且** iOS 排期进入
执行窗口(0.4 收紧:两条件同时满足;iOS 窗口未开时 1-Z 失败仅归档)。

- VM entry/exit trampoline;固定寄存器约定;direct threaded dispatch
  (central/replicated/hybrid 三版本);
- 25~45 个最高频 opcode,**必须含 call/call_method/return 与 frame
  切换**;
- 其余 opcode 统一走 Zig slow handler;checked 构建(§7.9)。

只有 1A 过门(§14)才扩大覆盖(1B)。失败退路:保留现解释器;
baseline JIT 按其独立 gate(§8.1)推进。

### 7.2 固定寄存器约定

AArch64(callee-saved,helper 天然保留):

```text
x19 = pc
x20 = sp
x21 = fp / frame base
x22 = var_base
x23 = Vm*
x24 = dispatch table
x25 = FunctionBytecode* / code_base(实测定夺)
```

**16 字节 JSValue**:一值两 GPR(LDP/STP 成对或 q 寄存器整体搬运);
值传递 scratch 预留寄存器对;TOS 缓存每档成本按 16B 折算(§8.3)。

**arm64e 约束(iOS)**:每个 handler label 是间接跳转目标,需 BTI
landing pad(`bti j`);trampoline 与保存 LR 路径按 PAC 成对
(`paciasp`/`autiasp`);解释器无运行时代码生成,W^X 硬执行天然合规;
该平台 `-Djit=off` 常青。

注:x86-64 asm port 已撤销;x86 平台由 lswitch/tailcall 覆盖。

### 7.3 状态权威模型

```text
Running    VM registers 权威;VmExecState 可能过期
Published  关键寄存器已写回;GC、异常、调试器可观察
Exited     完整写回;控制权归 Zig runtime
```

publish 只发生在:can_gc/can_throw helper、可 re-enter JS 的 native
call、interrupt/safepoint、debugger/profiler、interpreter exit、tier
transition。现役 publish/reload 机制即此关系的手工形态。

### 7.4 RC 语义规则(核心)

zjs 值移动带引用计数副作用,与 LuaJIT/JSC 式 asm VM 的本质差异:

1. **复制即 incref**:load local → 栈顶是 dup;tag 范围判定 + rc++
   必须内联(现役 `value.zig` inline 快径即模板);
2. **覆盖即 decref**:put_loc/put_field/drop 旧值 rc--;**zero 路径
   一律出域**到 outlined stub(调 Zig `destroyZeroRef` 链);stub
   边界按 `can_gc` 对待;
3. **借用协议保留**:现役 borrowed-holder / value_slot 惯例原样迁移,
   禁止全部改 dup;
4. **值移动不手写**:全部 inc/dec/copy/zero-branch 序列由生成宏
   (`.inc`,Zig 构建期生成)展开——§3.1 裁决 A 的兼容条款:两字值
   协议落地时改生成器,不改 handler。

```asm
BC_GET_LOC:
    VAL_LOAD   v0, [var_base + slot*16]   ; LDP 对
    VAL_INCREF v0, .Lgl_store             ; 宏展开
.Lgl_store:
    VAL_STORE  [sp], v0
    NEXT

BC_PUT_LOC:
    VAL_LOAD   v0, [sp - 16]              ; 新值(所有权转移,不 inc)
    VAL_LOAD   v1, [var_base + slot*16]
    VAL_STORE  [var_base + slot*16], v0
    VAL_DECREF v1, BC_PUT_LOC_ZERO_STUB   ; zero → 出域
    NEXT
```

### 7.5 Handler 结构与 slow helper 分类

opcode 之间只有跳转,无 calling convention;ABI 边界只在 entry、slow
helper、exit。helper 二分:

- **Value helper**:`fn(vm, lhs, rhs) callconv(.c) JSValue` 型;
- **Stateful helper**:`fn(state: *VmExecState, opcode) VmHelperStatus`
  型(generator/async、unwind、eval、with、Proxy、罕见复杂 bytecode)。

现有 `vm_*.zig` outlined helper 即雏形,签名收敛,不重写语义。

### 7.6 call/return 入域

0.4 勘误后的准确表述:现役热调用**已在域内**;1-Z/1A 必须**等价保持**
这一点并覆盖:

- 普通 push 调用与 `TailMode` 三态(push / reuse_chain /
  reuse_release)域内完成 frame 雕刻与 pc/sp/var_base 切换;
- **PTC 语义保全**:strict `tail_call` 常量栈行为逐位对齐现役
  `Machine.tailCallReuse`;
- 逻辑 budget / overflow 记账保留;
- 冷 callee(native / generator / class-ctor / cross-realm)仍出域走
  现役 cold call 路径(含 `.tail` → driver 等价物);
- generator/async park/unpark 整体出域(stateful helper),1B 再评估。

这是 1-Z/1A 实现难度的主体;省略它的原型没有决策价值(测不出 ① 的
真实权重)。

### 7.7 Dispatch 三版本 A/B 与布局

central / replicated / hybrid 三版本同做;**现状基线已是 replicated**,
central 是回归风险项而非默认赢家。指标:cycles、instructions、
branches、branch-misses、L1I/iTLB misses、frontend stalls、`.text`。
布局按频率+转移矩阵分 `.hot.vm`/`.cold.vm`;L0 stop seam 换表机制
原样继承(asm)或双循环重设计(lswitch)。

### 7.8 Zig reference interpreter

现役 tail-call 解释器**常青,不删除**:bring-up 差分 oracle、新 opcode
首个参考实现、ASAN/UBSAN 构建、未支持架构、禁 JIT 平台、fuzzing、
bailout fallback。

```text
-Dvm=tailcall | -Dvm=lswitch | -Dvm=asm      -Djit=off | -Djit=baseline
```

### 7.9 checked 构建

现役热路径正确性依赖 Debug **与 ReleaseSafe 双活**断言网;asm 化使最
热代码脱离该网与 sanitizer,补偿是 Phase 1 交付物而非事后补:

- asm VM checked 变体:handler 边界镜像一致性、栈深、RC 非负;
- helper 入口 descriptor 交叉断言(§5.5);
- 差分 harness:同种子同输入,`-Dvm=tailcall` 与 `-Dvm=lswitch|asm`
  全量对照。

---

## 八、Phase 2:Baseline JIT

### 8.1 定位

**立项方式(0.6,roadmap v1.7)**:Phase 2 由独立 **PERF-JIT-SPIKE→
G1-JIT** 裁决,不与 Phase 0.5 链式绑定。硬输入 = canonical bytecode
+ **PERF-VMABI**(Phase 0 执行状态 ABI);动态反馈(§六)与 typed
metadata(type-directed 计划)均为**可选增强**。baseline JIT 与原生
AOT 为**两个 backend 的分叉**:共享上游 IR/lowering/helper ABI/GC
slot 抽象,不共享 emitter,先后由 roadmap Gate(G1-JIT/G1-AOT)
裁决。

只解决确定成本:dispatch、decode、stack traffic、重复 tag check、通用
call glue、native wrapper glue、monomorphic property access(消费
动态反馈槽——可选增强,若 G1-FEEDBACK 裁决建设)、循环回边。不做:SSA、全局寄存器分配、LICM、GVN、
aggressive inlining、投机循环变换、通用 deoptimization。准确称谓
**linear baseline compiler**。

### 8.2 编译单元与流程

以整个 `FunctionBytecode` 为单元;轻量 prepass(边界/栈深验证、branch
target 与 exception region 标记、native label 分配)→ 线性发射 →
forward-branch fixup → PC map / safepoint / relocation → finalize。
预留 function entry / loop OSR entry / exception resume entry,第一版
只启用 function entry。复杂 opcode 走 helper continuation,不因单个
复杂 op 拒编整个函数。

### 8.3 栈映射(RC 计价)

- **v0**:所有 JS value 固定内存 home;RC inc/dec 按 §7.4 宏展开
  (v0 代码体积的主要构成,预算按此估);
- **v1**:basic block 内缓存 TOS/top-2(16B/档,收益折算);branch
  target、helper call、safepoint 前 flush;不做跨块分配。

### 8.4 fast path 原则

int32 算术、number 比较、local load/store、常量、分支、简单 indexed
load、稳定 internal builtin call、return、反馈槽命中的 monomorphic
property load/store。guard 失败优先进 slow helper 并回到 compiled
continuation,不整函数 deopt——snapshot 复杂度推迟到 Phase 4。

### 8.5 JitMeta 与 code block

`JitMeta` side table(cold → warm → compiling → ready → invalidated;
失败 → disabled),canonical bytecode 不改;JIT entry 只在 function
call、loop backedge、interpreter resume 三处检查。

```zig
pub const JitMeta = struct {
    state: JitState,
    call_counter: u32,
    backedge_counters: []u16,
    baseline_entry: ?*const anyopaque,
    loop_entries: []?*const anyopaque,
    code_block: ?*JitCodeBlock,
};

pub const JitCodeBlock = struct {
    rx_start: [*]const u8,
    size: usize,
    function: *const FunctionBytecode,
    pc_map: []PcMapEntry,
    safepoints: []Safepoint,
    relocations: []Relocation,
    dependencies: []JitDependency,
    ic_slots: []InlineCacheSlot,
};
```

必须解决:RW→RX、W^X(macOS: MAP_JIT +
`pthread_jit_write_protect_np` + entitlement;iOS 无 JIT)、icache
flush、eviction、JIT code 对 GC object 的引用、function/realm 销毁
失效、native PC → bytecode PC 映射。JS 异常显式状态返回,不依赖系统
unwind。

---

## 九、Phase 3:Native Direct Call 与完整 IC

### 9.1 NativeCallDescriptor(并行轨,可自 Phase 1 起)

基于 `src/binding/ffi.zig` 既有描述符扩展。**对齐目标修订
(2026-08-25)**:原对齐对象 runtime-plugin-abi.md 已 deprecated
(2026-08-25),改对齐
[fun-native-plugin-design.md](fun-native-plugin-design.md) §15.2;
FNABI 裁决(2026-08-25)要求 `NativeCallPlan` 与本描述符统一为
**单一 schema**;FNABI 里程碑已拆分(roadmap v1.7):M1A 不依赖
本计划,M1B←F1,M1C←F2,本轨与 M1B/M1C 按该拆分关系耦合,不再是
自由并行轨:

```zig
pub const NativeCallDescriptor = struct {
    target: *const anyopaque,
    argc_min: u16,
    argc_max: u16,
    argument_kinds: []const NativeValueKind,
    result_kind: NativeValueKind,

    can_gc: bool,
    can_throw: bool,
    can_reenter_js: bool,
    can_suspend: bool,
    reads_heap: bool,
    writes_heap: bool,

    realm_sensitive: bool,
    thread_policy: NativeThreadPolicy,
};
```

直接调用成立条件:callee identity 稳定、descriptor 稳定、argc 合法、
类型 guard 通过、realm 满足。GUI runtime(Canvas/WebGPU/FS/网络)下
这条轨的价值不低于早期 optimizing JIT,与解释器骨架工作解耦、允许
并行。

### 9.2 Call IC / Property IC 完整状态机

```text
Uninitialized → Monomorphic → Polymorphic(2~4)→ Megamorphic
```

Phase 0.5 反馈槽升级为可 patch 的 IC stub;失效从版本号升级为
dependency registry:shape transition、prototype mutation、accessor
替换、builtin 替换、Realm 销毁、module reload、属性 attribute 变更。
禁止 machine code 长期裸持 shape 指针而无依赖登记。Property fast
store 不得绕开 §12.2 barrier 挂钩位。

---

## 十、Phase 4:Guard、Snapshot 与 Deoptimization

- Guard 类型:tag / int32/double / shape / prototype-chain / callee
  identity / builtin identity / element-kind / typed-array detach /
  Realm;
- Snapshot:bytecode PC、frame chain、逻辑栈深、live slots、slot→SSA
  映射、materialization actions、异常状态、inlined frame;
- Guard 失败:machine registers / spill slots → snapshot
  materialization → 恢复 JS frame 与栈 → baseline 或 interpreter;
- Deopt target 优先级:optimizing → baseline continuation →
  interpreter;
- Guard + snapshot 是 optimizing tier 硬前置。

---

## 十一、Phase 5:Optimizing Tier

不预锁 trace / region / hybrid;以 baseline 运行数据裁决。倾向候选:

```text
Region SSA compiler + profile-selected hot paths + side exits
```

backend 不接 LLVM(编译延迟、patching、IC/deopt 耦合、寄存器约定控制
不匹配);演进阶梯:MacroAssembler → baseline emitter → 简单
virtual-register allocator → SSA lowering → cost-based RA。

---

## 十二、GC、异常与中断集成(RC 现实)

### 12.1 现役规则(RC + trial deletion 权威期)

- "safepoint" 现役含义:中断 poll 点 + 分配点 + cycle-collection
  触发点;无全局根枚举暂停;
- 执行域内 live JS values 存活由 §7.4 RC 规则保证,外加 publish seam
  可观察性;
- `HelperDescriptor.can_gc` = 可能分配 / 触发 trial deletion;
  decref-zero stub 边界按 can_gc 对待;
- 中断:loop backedge 与 call boundary poll(对齐 qjs 入口 poll);
  沿用换表机制,不逐 opcode 检查;保留 termination、timeout、debugger
  interrupt、GC request、scheduler yield 全部语义。

### 12.2 tracing GC 迁移兼容条款

- 值移动全部走生成宏(§7.4-4):两字值协议落地时改生成器;
- fast store 预留 barrier 挂钩位(patchable nop sled 或恒跳 stub 槽),
  设计预留、不实现;RC 期该位为空;
- baseline JIT safepoint metadata 从 v0 起记录(§8.5);
- shadow-tracer 阶段与解释器轨共存;Slot 表示切换是重生成事件,费用
  已在裁决记录计价。

### 12.3 异常

统一走 `VmHelperStatus`(§5.4);backtrace 正确性依赖
`requires_pc_before_observable`(§5.5);不依赖系统级 unwind。

---

## 十三、代码组织(不做目录大迁移)

在既有布局内生长([refactor-policy.md](refactor-policy.md) 约束):

```text
src/exec/
    tailcall_dispatch.zig        # 现役解释器,常青参考(-Dvm=tailcall)
    lswitch_dispatch.zig         # Phase 1-Z(条件项)
    exec_state.zig               # VmExecState + VM_ABI_VERSION(P0)
    helper_descriptor.zig        # HelperDescriptor + 校验(P0)
    feedback.zig                 # Phase 0.5 反馈槽
    asm/                         # AArch64-only(条件项)
        entry.zig
        aarch64/vm.S             # 或构建期生成物
        aarch64/*.inc            # 生成:offsets/registers/value-move 宏
    jit/
        metadata.zig  code_cache.zig  patching.zig  safepoint.zig
        macro_assembler/{aarch64,x86_64}.zig
        baseline/{compiler,prepass,frame_layout,emitter,bailout}.zig
        ic/{call_ic,property_ic,dependencies}.zig
        optimizing/{ir,snapshot,deopt}.zig    # Phase 4+
src/binding/
    ffi.zig                      # NativeCallDescriptor 在此扩展
tools/
    gen_vm_offsets.zig  gen_opcode_tables.zig  dump_jit_code.zig
```

Opcode 元数据单一 canonical source,从现有 `bytecode.opcode` 表收敛
生成,解释器表 / 汇编 include / disassembler / baseline compiler 共用:

```zig
pub const OpcodeInfo = struct {
    id: Opcode,
    name: []const u8,
    size: u8,
    stack_pop: i8,
    stack_push: i8,
    hot_class: HotClass,
    may_throw: bool,
    may_gc: bool,
    rc_effect: RcEffect,        // 值移动宏选择器
    slow_helper: ?HelperId,
};
```

文档义务:[architecture.md](architecture.md)(含 Stack Bytecode VM
Status 章)各阶段同步更新;§3 裁决记录(含 §3.4 宪章退役)入 `docs/`,参照
[qcp1_switch_decision.md](qcp1_switch_decision.md) 体例。

---

## 十四、分阶段交付与验收

### Phase 0

交付:§5.2 测量增量(helper 频率首位)、`VmExecState`+签名、
HelperDescriptor 全覆盖、Outcome 映射、差分 harness。
验收:测量可重复;state transition 唯一书面约定;PMU 报告能回答
dispatch/operand traffic 占比与热路径 bl/iter;**1-Z 预门槛算术与
1A 门槛数值在此报告后定稿**。

### Phase 0.5

前置:PERF-DYN-SPIKE→G1-FEEDBACK 裁决通过并立项 PERF-P05(全部
前置含 SidecarCore spec 与 08-17 IC 否证对账,见 §六 状态框);
§3.4 宪章退役记录已入库(前置之一)。
交付:反馈槽 side table、解释器命中路径、失效版本号、A/B 数据。
验收:test262 无回归;zoo property/call 密集项(pdfjs/typescript/
box2d)有可归因提升(单态微基准不作为收益证据);审计条款(§6.3)
满足。

### Phase 1-Z(条件项,go/no-go)

启动条件:预门槛投影 ≥ 2%(§7.0);time-box(建议 ≤ 2 周原型窗,
到期未达标即按未达标归档)。
交付:lswitch dispatch 脊柱(**含 call/return 入域**)、L0 stop seam
重设计、帧/寄存器驻留反汇编报告、per-opcode profiling seam。
验收:

- test262 与 tail-call 解释器差分一致;PTC / generator / 异常语义
  无回归;
- 帧测量:单体帧不回涨(具体预算按 Phase 0 定),pc/sp/var_buf 跨
  bl 驻 callee-saved 有反汇编证据;
- geomean 不低于现役,且 call-heavy 切片兑现 ≥ 预门槛投影的一半
  (投影全兑现不作硬门,防高估;dispatch-heavy 免测,引 §2.4);
- **单臂编辑扰动实验**:修改一个非热臂后,无关基准摆动 ≤ 噪声带;
  不满足则转生产需 owner 显式接受刀分辨率税;
- 满足证据门(冻结二进制 + 反汇编 + 多构建 PMU;沿用 pad 谱系协议)。

决策:达标 → `-Dvm=lswitch` 转生产默认,1A 转 iOS 排期项;未达标 →
证据归档,回 tail-call;Phase 2 按其独立 gate(§8.1)推进,不受此
绑定。

### Phase 1A(条件项)

状态注(0.6):1A/1B 为 incubator 项,不在现行 active DAG;启动
前置 = PERF-ASM-1A 通过 + GC 表示定型 + iOS 执行窗口打开
(roadmap v1.7)。
启动条件:1-Z 未达标 **且** iOS 排期进入执行窗口(两条件同时满足);
AArch64-only。
交付:§7.1 范围(**含 call/return**)、三 dispatch 版本、checked
构建、RC 宏生成器。
验收:

- test262 与 reference interpreter 差分一致;GC stress / 随机
  interrupt / RC 平衡审计无错;
- 分层测量:call-heavy 与 dispatch-heavy 切片分别报告(后者预期 ≈0,
  引 §2.4(b),不作失败依据);
- 门槛(0.4 修订):

```text
bench-v8 geomean ≥ 1.05 × 当时生产解释器
(预注记:按 §2.4 地板数据,此线预判大概率不可达;若不可达属预期
 正确,不作为执行失败论据。)
且必须同时满足:iOS 战略窗内、维护成本评审通过。
.text 缩减单独不构成过门理由(上界 ~2.7% 二进制,§2.2)。
```

- 维护成本评审:asm 行数、生成器占比、双人可读性(bus factor)。

未过门:归档数据,保留当时生产解释器;Phase 2 按其独立 gate
(§8.1)推进。

### Phase 1B

状态注(0.6):incubator 项,不在现行 active DAG(前置同 Phase 1A,
roadmap v1.7)。

全 opcode 覆盖(复杂域保持 helper 出域)、hot/cold 布局、arm64e 合规
(BTI/PAC)、profiler/disassembler 支持。前置:§3.1 裁决 A 的值表示
定型条件。验收:test262 全通过;bench-v8 无未解释回归;dispatch 选择
有 PMU 依据;build size / link time 可接受。

### Phase 2

前置:独立 PERF-JIT-SPIKE→G1-JIT 裁决通过(§8.1,不与 0.5 链式
绑定)。
交付:MacroAssembler、code cache、function-entry 编译、v0 栈映射、
PC map、safepoint、helper continuation、反馈槽消费(可选项,视
G1-FEEDBACK 裁决)。
验收:JIT on/off 语义一致;编译失败可安全永久回退;异常栈可映射回
bytecode;warmed workload 明显优于当时生产解释器;compile latency /
code bytes / bailout 可观测。

### Phase 3

loop hot counter、OSR、NativeCallDescriptor 融合、完整 IC 状态机、
dependency invalidation。验收:mutation 后不执行失效代码;direct
call 与 generic wrapper 结果一致;native crossing 基准显示分层成本。

### Phase 4

SSA IR、guard、snapshot、materialization、baseline/interpreter deopt
target。验收:随机 guard failure 恢复正确 PC;异常、inlined frame、
live slots 恢复正确;fuzzing 覆盖 deopt 边界。

### Phase 5

profile 后立项,验收随选型定义。

---

## 十五、基准与观测

四类测试(挂接现有基建):

1. **Correctness**:test262、zjs tests、QuickJS differential、
   `-Dvm=*` 与 baseline 差分、GC/RC stress、exception stress、
   interrupt stress;
2. **Interpreter microbench**:dispatch-only、local load/store、
   branch-heavy、算术快/慢径、call/return、helper call;
3. **JIT benchmark**:cold/warm、短函数/大函数/长循环、多态调用、
   property access、exception-heavy;
4. **Native crossing**:generic wrapper / descriptor / mono call IC /
   property IC + direct call / batched API 分层。

统一输出:wall time、cycles、instructions、branch misses、L1I/iTLB
misses、helper calls、compiled functions、compile time、JIT code
bytes、bailout/deopt counts、IC 状态分布。公开口径以
[perf/bench-v8-status.md](perf/bench-v8-status.md) 契约为准。

---

## 十六、主要风险

| 风险 | 控制方式 |
| --- | --- |
| **与 tracing GC 迁移相撞**(最高) | §3.1 裁决 A;值移动生成宏;barrier 挂钩预留;重写成本入裁决记录 |
| **宪章双轨**(0.4 新增) | §3.4 退役记录先于 Phase 0.5;新对标尺显式化 |
| **RC 语义在 asm 中出错/低估** | §7.4 四规则;RC 宏生成器;checked 构建 RC 平衡审计;差分 + GC stress |
| **lswitch 全函数布局彩票**(0.4 升格) | §14 单臂编辑扰动实验为验收硬项;转生产需 owner 显式接受刀分辨率税 |
| lswitch 单体帧回涨 | 1-Z 隔离实验;冷臂 outline 纪律;反汇编帧测量 + bisection 复核 |
| **1-Z/1A 挤占 Phase 2 窗口**(0.4 新增) | 预门槛算术前置;time-box;"保险单非主菜"定位入文 |
| 汇编与 Zig 语义漂移 | reference interpreter 常青;复杂语义集中共享 helper |
| state 未 publish 致 GC/异常错误 | HelperDescriptor 生成 publish;descriptor 交叉断言;随机 interrupt |
| 断言网/sanitizer 损失 | §7.9 checked 构建为 Phase 1 交付物 |
| replicated dispatch 恶化 I-cache | 三版本 A/B;基线已是 replicated,central 是回归风险项 |
| 多架构维护成本 | asm 收缩 AArch64-only;共享 ABI/metadata/测试;生成优先于手写 |
| 单维护者 bus factor | 1A 验收含可读性评审;生成器占比指标;文档义务(§13) |
| baseline 实际覆盖率低 | helper continuation;反馈槽(若 G1-FEEDBACK 裁决建设)保证 property 快路存在 |
| native direct call 绕过 JS 语义 | callee/realm/descriptor/argument guards;effects 显式 |
| IC 失效不完整 | 版本号(0.5)→ dependency registry(P3)分级 |
| JIT 过早复杂化 | baseline 禁 SSA/全局 RA/通用投机 deopt |
| 无 JIT/无汇编平台 | `-Dvm=tailcall`/`lswitch` 与 `-Djit=off` 常青;Apple/iOS 约束见 §3.2 |

---

## 十七、优先级

| 优先级 | 工作项 | 结论 |
| --- | --- | --- |
| P0 | Phase 0 测量增量(helper 频率首位)+ VmExecState ABI | 立即;治理门证据;ABI 对骨架中立 |
| P0 | 宪章退役记录(§3.4) | 已完成(RATIFIED 2026-08-24);Phase 0.5 前置之一(非唯一,§六) |
| P0 | GC 排序(已裁决 A)/ 平台矩阵 / Zig 例外 | 已裁决项记录入库 |
| P0.5 | 解释器级 property/call 反馈槽 | 经 PERF-DYN-SPIKE→G1-FEEDBACK 裁决后立项 PERF-P05(§六 状态框);价值待 spike 实证,对 Phase 2 为可选增强 |
| P1 | NativeCallDescriptor(扩展 ffi.zig) | 并行轨,不依赖解释器骨架;**注(2026-08-25)**:FNABI 裁决后与 `NativeCallPlan` 统一为单一 schema;里程碑拆分:M1A 不依赖本计划/M1B←F1/M1C←F2(§9.1) |
| P1 | GC/exception/helper contract | 不可后补 |
| P1(条件) | labeled switch 原型 1-Z | 预门槛 ≥2% 才启动;time-box;保险单非主菜 |
| P1(条件) | asm microkernel 1A(AArch64-only) | incubator 项;启动前置 = PERF-ASM-1A 通过+GC 表示定型+iOS 窗口打开(§7.1 状态注);摸禁 JIT 平台上限 |
| P2 | Zig MacroAssembler + linear baseline compiler | 独立 PERF-JIT-SPIKE→G1-JIT 裁决(§8.1);硬输入=canonical bytecode+PERF-VMABI;不等 1-Z,不与 0.5 链式绑定 |
| P2 | hot counter + JitMeta | baseline tiering |
| P2 | 完整 Call/Property IC 状态机 + dependency registry | baseline specialization |
| P3 | OSR | baseline 稳定后 |
| P3 | guard/snapshot/deopt | optimizing 前置 |
| P4 | trace/region optimizing JIT | profile 后决定 |
| 不做 | 重写 register bytecode | 维持既有裁决 |
| 不做 | 复制 LuaJIT GC | 与目标无关,GC 已有独立 roadmap |
| 不做 | 第一版 JIT 接 LLVM | 延迟与控制性不匹配 |
| 不做 | 解释器与 JIT 共享同一 emitter | 只共享 ABI 与 metadata |
| 不做 | 解释器骨架重测已测项 | §2.4 免测清单具约束力 |

---

## 附录 A3:0.4 相对 0.3 的差异清单

1. **§2.1 立项事实勘误**:热 JS→JS 调用不往返 driver(warm 家族域内
   进入;`.tail` 仅冷形态,padded-leaf 0.0015% 普查先例;call_const
   总差 28 insn/iter 定量旁证);§2.2④ 改判"已收割";§7.6 表述改为
   "等价保持"。
2. **§2.4 新增 dispatch 重验证据基线**(2026-08-24 四组实验:今日
   探针、三骨架 toy、bl 形态对照、冷壳普查、体积静态、07-14 历史
   对照),并设免测清单条款(§17"不做"表)。
3. **1-Z 预门槛**:Phase 0 helper 频率数据 → 投影算术 <2% 即搁置;
   time-box;验收增加单臂编辑扰动实验(布局彩票条款)与"call-heavy
   兑现 ≥ 投影一半"的现实门;立项理由重写为 ①③ 净值。
4. **1A 门槛修订**:`.text` 单独过门撤销(上界 ~2.7% 二进制);
   geomean ≥1.05× 附预注记(按地板数据预判大概率不可达,不作执行
   失败论据);启动条件收紧为"1-Z 未达标 **且** iOS 窗口"。
5. **§7.0"取指软流水"论述删除**(asm toy 实测证伪:未预载仍打平,
   宽乱序前端即软流水);asm 净余量改为 ③ + `.text` 下界 + 免疫
   编译器回退。
6. **§3.4 新增宪章退役记录**为 Phase 0.5 前置;§3.1 GC 排序记为已
   裁决(A);§3.3 增注 1-Z 走通则 Zig 例外不必开启。
7. **§6.2 收益校准**:解释器级单态站点赢面≈0(probe-first 直通已
   0.90x),真赢面在原型链缓存与多态站点;0.5 主要价值改述为
   Phase 2 的反馈输入。
8. **优先级表**:Phase 2 明确"不等 1-Z";1-Z/1A 标注条件项与保险单
   定位;新增免测条款。
9. 风险表:新增宪章双轨、1-Z/1A 挤占 Phase 2 窗口;布局彩票升格并
   绑定验收硬项。

## 附录 B:维持不变的结论(0.1→0.4 谱系)

- 目标架构与边界原则(hot mechanics 归执行域,语义归 Zig runtime;
  RC 值生命周期属 hot mechanics);
- 先原型后铺开;解释器与 JIT 不共享 emitter,只共享 ABI/metadata;
- direct threaded 为正式方向,replicated 为现状基线;
- linear baseline compiler 定位与禁做清单;
- native direct call 与通用 property call 直调分阶段;
- guard/snapshot/deopt 作为 optimizing 硬前置,deopt 优先落 baseline;
- 不预锁 trace/region;backend 不接 LLVM;
- 不做 register bytecode(与
  [architecture.md](architecture.md) Stack Bytecode VM Status 章 §1 一致)。
