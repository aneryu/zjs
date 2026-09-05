# Tracing GC 完成计划（对象模型全面适配）v0.1

Status: **APPROVED — owner 2026-09-03「全部同意」：方向、分期、§8 决策点 D1-D6 全部按 driver 建议批准**（driver，2026-09-03）

批准即授权 S0 开工与 R3 并行开工；每期仍按 §3 规则先出函数级规格再派发。

前置：`docs/gc-v2-completion-and-pivot-2026-09-03.md`（GC v2 完成对账）、本日 GC 评审（会话记录，要点见 §1）。
owner 裁决（2026-09-03）：**先不管性能，把 tracing GC 做到底，把对象模型改造成完全适配。**

本文取代以下已批准文档中的相应条款（见 §7 supersede 表）：
`tracing-gc-header-v2-design.md` O1 中「Shape/Realm 保留 body RC、BigInt 保留 rc 前缀」；
`tracing-gc-design.md` §1.4 中「string 可保留独立 rc 描述符」的容忍；
`gc-v2-completion-and-pivot-2026-09-03.md` §4 的转向（TS/AOT）顺延到本计划完成后。

## 0. 一句话目标

**所有 JS 可达的堆分配都由 tracing 管理；普通对象的死亡零成本（位图 sweep，不跑析构）；引用计数机器整体删除；根集精确、保守扫描降级为校验臂。**

完成判据是正确性与结构，不是 cycles。性能只记账不裁决（§6）。

## 1. 现状事实（勘察结论，均已对 HEAD 0dbf7d86 核实）

| # | 事实 | 证据 |
|---|---|---|
| F1 | 八个 GC kind 中只有 object / function_bytecode / var_ref / module 由 tracer 拥有；shape / realm_context / string / big_int 标 `.retained`，仍是 rc | gc.zig:746-757 `representation_kind_catalog`；value.zig:480-493 `isTracerOwned` 范围 [-3,-1] |
| F2 | string 家族（flat / rope / symbol 描述串）4B rc 前缀，不进 block heap、不进 gc_obj_list、不进 address_registry；tracer 对 string 值不做任何事 | string.zig:244/848；gc_trace_stw.zig:103 `.string => {}` |
| F3 | BigInt 甚至不被 mark：`cycleMarkHeader` 对 tag −9 返回 null，无列表成员，纯 rc | value.zig:480；gc.zig:3253 |
| F4 | Shape 的 rc 不是活性而是 **COW 唯一性判定**（`refCount()==1`）；shape hash 表已是弱表，transition 靠全局 hash 无父→子指针；tracer 已能回收未标记 shape | shape.zig:73-75/1047/1361；gc_trace_stw.zig:1306 |
| F5 | Realm 的 rc 只承担「host destroy 即时释放」+ runtime.deinit 断言；堆内活性已由 RealmRef 边与 root provider 承载 | context.zig:460-471/906-935；runtime.zig:1671 |
| F6 | 对象死亡必须逐对象析构：释放属性里的 string/bigint rc、shape rc、堆外 `prop_values`、数组元素、21 种 class payload；EB 上 minor 的 sweep+destroy 占 minor 总时长 69%，splay 上 destroy 比 marking 还贵 | object.zig:2437-2600；`--gc-stats` 实测 |
| F7 | `JSValue.dup/free` 全仓 1190 / 7826 处；对 object 类 tag 已是 no-op，只对 string/bigint 起作用 | value.zig:495-505 |
| F8 | **生产二进制没有标量精确根**：`value_root_link_containers_only = !is_test`，134 个 `rootValues/rootObjects` 站点在 CLI 中被编译成空壳；`host_quiescent` 仅在 runtime 析构时为真，即生产每次 GC 都靠保守扫描兜底 | runtime.zig:501；runtime.zig:1643-1650 |
| F9 | 保守扫描也有覆盖不到的洞：解释器 fast handler 只推进 `reg_sp` 不提交 `stack.len`，操作数 arena 在堆上不在原生栈；`pending_call_region` threadlocal 是被 TypedArray 回收事故逼出的单窗口补丁 | tailcall_dispatch.zig:2396-2404 |
| F10 | `prop_values` 在 object.zig 之外没有任何裸 `Entry` 指针缓存；数组元素裸 slice 跨分配仅 4 处 | 勘察 lane 结论（object.zig:517/377 及 exec 层 grep） |
| F11 | `RefKind` 是 `enum(u3)` 已满 8 值；`ObjectFlags` 16 位已满 | gc.zig:660；object.zig:283-305 |
| F12 | block heap 的 medium / large 空间与 `Heap.alloc/free` 在生产中零调用者 | gc_block_heap.zig:721/2437/2489 |

## 2. 目标态

### 2.1 所有权矩阵（目标）

| kind | 承载 | 活性 | 死亡 |
|---|---|---|---|
| object | block cell（现状） | mark 位图 | 位图 sweep；仅 `needs_finalizer` 位为 1 的走 finalizer |
| string（flat / rope / symbol body） | **block cell**（≤120B 载荷）或 medium / large extent | mark 位图 / extent 标记 | 位图 sweep，无析构 |
| big_int | block cell / medium | 同上 | 同上 |
| property_storage（新 kind） | block cell / medium | 由 owner Object 的边标记 | 位图 sweep |
| array_storage（新 kind） | block cell / medium / large | 同上 | 同上 |
| payload（新 kind，a 类 class payload） | block cell / medium | 同上 | 同上；b/c 类保留 finalizer |
| shape | 现状（非块 carrier） | mark | 保留析构（atom 退引 / hash 表 unlink），rc 删除 |
| realm_context / module / function_bytecode / var_ref | 现状 | mark | 保留析构（现状） |

**rc 归零**：`RefCountHeader`、`retain/release`、`headerRefCount`、`ZeroRefScratch`、`beginDecrefPhase`、`Phase.decref/.cycle`、`destroyZeroRef*`、`DeferredFreeStack`/Pass B 停尸链、`JSValue.dup/free` 全部删除。

### 2.2 头部（目标，S4 前出函数级规格）

保持 8B `Metadata` 一个前缀，Object 与所有块 cell kind 一致（body offset 0，沿用 M-cut 结论）；非块 kind 保留 `TraceHeader.next_non_object`。flags 字节重排（S4 落地，S1-S3 不动位）：

```
BlockFlags(u8): kind:u4 | young:1 | needs_finalizer:1 | finalizing:1 | reserved:1
```

去掉 `mark`（块 cell 的 mark 权威早已是块位图；非块 kind 用 `mark_epoch`）、`is_pinned`（pin_entries 表是权威）、`cycle_visited`（由 doomed 位图 / lifecycle 替代）。这三项都是 rc 时代残留被 tracer 借用，S4 的规格里逐一给替代物。

### 2.3 根集（目标）

- 精确根 = 现有精确根 + **生产链入标量 ValueRootFrame**（翻转 runtime.zig:501）+ 解释器 `reg_sp` 作 windowed 根（`ValueRootSlice.windowed` 已有形态）。
- 保守扫描保留为 `-Dzjs_gc_verify_roots` 校验臂：生产不开；校验构建中 `computeFullReachable` 按来源归因 conservative-only 命中，目标读数 = 0。
- 移动（copying nursery）**不在本计划内**（§8 D1）。

## 3. 分期

> **进度（2026-09-05 14:00）**：S0/S1 已合入；S2（含 S2-e/f/g/h1/i）与 S3（a/b/c/d + 阶段末修复）已在 main 落地并过阶段末门（test262 0/49778、leak-census 绿、oom tier 21/0）；S4-a/b/c 已合入，S4-d（sweep 只遍历 finalizer / 块级计账 / 删析构机器）与 T-R R3 诊断进行中，S4-e 待派；S2-h2（nursery 按字节）KILLED。规格与执行记录：`docs/tracing-gc-s2-spec.md` §7、`docs/tracing-gc-s3-spec.md` §7、`docs/tracing-gc-s4-spec.md` §7。`JSValue.dup/free` 与调用点已在 owner 的消融裁剪中删除（原 S3 步 4/5 提前完成）。Stage 0（S2-i 后）：pdfjs 0.83/0.82 PASS，splay 1.22/1.33 待 S4-d。


两条并行 track：**T-M 对象模型**（S1→S4 串行）与 **T-R 根集**（R3→R1，与 T-M 并行）。S0 与 S5 是公共首尾。每期开工前 driver 出函数/偏移级规格（先例 `gc-v2-m-cut-object-layout.md`），codex 实现，对抗 ≤1 轮，driver 亲读关键 diff。

### S0 止血与安全网（1-2 lane-week）

1. 删僵尸：gc_candidate.zig / gc_snapshot.zig / gc_marker.zig 及其测试；object_gc.zig 测试专用 mark 臂与 `MarkMode`；`Phase.cycle`；41 行恒真门死臂与 15 个 `else void` 字段类型；gc.zig:29 失实注释。
2. 文档对账：gc-invariants.md 重写为「混合所有权 → 目标全 tracing」；gc-inventory.md 删不存在符号；tracing-gc-design.md 标 rc 已删；gc-v2-systemic-design.md 状态改 DONE。
3. 安全网入门禁：`ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=1 ZJS_MINOR_AUDIT=1` 跑单测进 checkpoint-gate；test262 全量在 `ZJS_GC_STRESS` 下跑一次并归档产物为基线；`liveBytes/committedLiveMilli` 挂到 `--gc-stats` 门后。
4. 三处静态可疑无屏障写（object.zig:10141、src/exec/array_ops.zig:6115、call_runtime.zig:3362）加插桩审计：在 `ZJS_MINOR_AUDIT` 下记录「老 owner 无屏障写入年轻 target」，跑 Octane 全套，出结论后关闭或修复。

门：全测绿 + test262 双模式 0 回归 + stress 基线产物在案。

### S1 Shape / Realm / BigInt 去 rc（1-2 lane-week，~600 行）

| 步 | 改什么 | 文件 |
|---|---|---|
| 1 | Shape COW 唯一性：用 `shared` 位（发布进 hash 表或被第二个对象引用时置位）替代 `refCount()==1`；6 个判定点改读该位 | shape.zig:581/660/667/709/826/934；object.zig:11355 |
| 2 | 删 `ShapeOwnership.trace_ref_count`、`Shape.retain/release/releaseForRealmTeardown`、`destroyEagerZeroDirect` shape 臂；shape 死亡只走 doomed pass | shape.zig；object.zig 16 处；context.zig 5 处；gc.zig headerRefCount 分支 |
| 3 | Realm：`RealmRef` 变裸指针 + 现有 traced 边；`JSContext.destroy` 只撤 root provider；runtime.deinit 断言改为「无未消费 host ref」并在 gc.deinit 前跑一次 full major | context.zig:1429-1460 及 ≈65 处 retain/clone/deinit |
| 4 | BigInt 入 tracer：`Tag.big_int` 纳入 `isTracerOwned/cycleMarkHeader`（范围改双比较，不重排 tag）；分配走 `addInitialized*`；`heapByteSizeFromHeader` 补尺寸；memory.zig:1471 去 rc=1 特判；`traceRememberedCacheEligible` 放宽；doomed pass 加 `.big_int` 臂；删 `destroyBigIntZeroRef` | value.zig；bigint.zig；gc.zig；memory.zig；gc_trace_stw.zig |
| 5 | parser 字面量 BigInt（parser.zig:3787，function 持久分配器）改为常量池内的普通堆 BigInt，由 FunctionBytecode 边持有 | parser.zig；bytecode.zig |
| 6 | 收 `ZeroRefScratch/beginDecrefPhase`：仅剩 weak 批处理用途 → 改名 `WeakSweepScratch` 或内联到 processWeak | gc.zig:1727/5424；gc_trace_stw.zig:2248 |

疑点先判：object.zig:1635 `template.shape_ref.retain()` 是否让未 hashed shape 被多对象共享（决定 `shared` 位的置位点）。

门：全测绿；test262 双模式；stress 三开关绿；`refCountRemoved` 对 shape/realm/big_int 为 true。

### S2 string 家族入 tracer（3-4 lane-week，~1200 行）

原则：**string 走 Object 同款路径**——block cell + 位图权威 + body offset 0，不进 `gc_obj_list` 链；超过 cell 上限的走 medium / large extent（F12 的零调用者空间由此启用）。atom 表在 S2 **保持 rc**，作为其缓存串的强根，S3 再弱化。

| 步 | 改什么 | 文件 |
|---|---|---|
| 1 | 前缀：`String`/`StringRope` 改 8B Metadata 前缀（kind=.string，rope 用 `alloc_info` 或 metadata 备用位区分 flat/rope/symbol）；`header()/fromHeader/value()`、`inlineAllocationLayout`、`freeRopeNode` 改偏移；分配改走 block heap（`allocCell` 或 medium/large） | string.zig；gc.zig:1218-1270 catalog 断言；memory.zig |
| 2 | JSValue 边界：`Tag.string/symbol/string_rope` 纳入 `isTracerOwned/cycleMarkHeader`（双比较 [-9,-6]∪[-3,-1]）；`dup/free` 对 string 变 no-op；`destroyZeroRef` 去 string 臂 | value.zig:480-505/688-698 |
| 3 | 标记：`.string` 臂改为 rope `left/right` 子边遍历；`markOrdinaryObjectHot/markFastArrayHot` 对 string 值调用 mark（热臂 + 权威 + comptime 列表三处同步，守卫已有） | object_gc.zig:227；gc_trace_stw.zig:103；object.zig |
| 4 | sweep：block 位图 sweep 对 string cell 无析构；medium/large extent 按标记释放 | gc_trace_stw.zig；gc_block_heap.zig |
| 5 | rc==1 独占优化处置：value_ops.zig:892/994/1139、string.zig:1414 `appendRopeTail` 改为「仅当 rope 未发布」或删除 | value_ops.zig；string.zig |
| 6 | 根：runtime 缓存数组（runtime.zig:1355-1375）、`RegExpPayload.source/compiled_bytecode`（改为 traced 边）、`atom.predefined_str/entries[].str`（S2 内为强根，由 atom 表 root provider 提供） | runtime.zig；object_payloads.zig:718；atom.zig |
| 7 | 保守扫描：string cell 自动被 block 解析器识别；medium/large 走 extent 记录 | gc_address_registry.zig（`.string/.rope` 占位启用） |
| 8 | 测试：property_direct.zig:645-729 等 rc 断言 ~20 处改写 | tests |

门：同 S1 + 一条新守卫「任意 string 值出现在已标记对象的边里必被标记」（deletion-probe 验证）。

### S3 atom 表弱化 + dup/free 删除（3-4 lane-week）

| 步 | 改什么 |
|---|---|
| 1 | `DynamicAtom.str` 变弱；atom 活性 = 所属 string body 被标记 ∨ 有裸 Atom 持有者边。GC kind（FunctionBytecode / Shape / Module / JSContext 帧 / class）加 `visitAtom` 边（shape.zig:292 等）；编译期临时（parser / compiler ~130 字段）用一个 **编译作用域 root provider** 整体持有，不逐个建边 |
| 2 | major 末扫 `entries[]`，清未标记且无边的 atom（`finalizeDeadEntry` 改由 sweep 驱动）；预定义 atom 永久 pin；symbol 的 `weakref_count` / WeakMap 键改用 body mark |
| 3 | 删 `atoms.dup/free`（228 / 1467 处）与 `ref_count` 转移逻辑（atom.zig:1594-1720） |
| 4 | `JSValue.dup/free` 此时对所有 tag 均为 no-op → codex 机械删除 1190 / 7826 处及 `defer x.free(rt)` 样板；`ValueRootFrame` 与 dup/free 正交，不受影响 |
| 5 | 删 `RefCountHeader`、`gc.retain/release`、`headerRefCount*`、`refCountRemoved`（恒 true 后删门） |

门：同上 + leak census 0 + 「atom 表条目数在 major 后回落」测试。

### S4 零成本 sweep（4-6 lane-week）

| 步 | 改什么 |
|---|---|
| 1 | `RefKind` 扩为 u4，新增 `.property_storage / .array_storage / .payload`；flags 字节按 §2.2 重排，出偏移级规格 + representation snapshot |
| 2 | `prop_values` → GC cell（block ≤128B / medium），Object 的 trace 边加一次 cell 标记；改点 object.zig 4 构造 + 2 增长 + 3 释放 + shape.zig:850-921 压缩 + `propertyStorageCapacity`（F10：无外部裸指针缓存，非移动下读点不改） |
| 3 | 数组元素 → GC cell（`ensureArrayBufferCapacity` 4892 的 remap 路径消失；adopt 4765/4781；4 释放点） |
| 4 | a 类 payload（ordinary / arguments / object_data / var_ref / proxy / bound / promise / disposable / global / iterator 主体 / regexp / function rare+aux）→ traced cell 或内联，无析构 |
| 5 | `needs_finalizer`：b/c 类（ArrayBuffer 非 inline、TypedArray/DataView view 链、WeakRef、WeakMap/WeakSet、FinalizationRegistry、std_file、Generator open VarRef、插件/嵌入类、有活游标的 Map/Set、has_weak_id / borrowed holder）在构造时置位；sweep 只遍历 `doomed & finalizer`（块级第 4 位图或 metadata 位） |
| 6 | 弱语义改 sweep 期清槽：WeakRef / WeakMap / FR 目标由 `weakref_count` / husk 改为按 mark 位清（`keyIsMarked` 骨架已有）；删 husk 与两遍 park |
| 7 | 计账块级化：sweep 按 `popcount(alloc & ~mark) × cell_size` 减账；阈值改用 block live_bytes + 非块池残余（memory.zig:1622/1862/1901 逐对象减账删除） |
| 8 | 删 `destroyPlainObjectFast/Slow` 主体、Pass-A settle、Pass-B 停尸链、corpse census、`DeferredFreeStack`（净删 ~800 行） |

门：同上 + 「普通对象死亡不进入任何析构函数」的 deletion-probe（在 destroy 入口放计数器，Octane 全套普通对象计数 = 0）+ 弱语义 test262 子集（WeakRef / FR）绿。

### T-R 根集（与 T-M 并行）

**R3 诊断（3-5 lane-week，S0 后即开）**：翻转 runtime.zig:501 做诊断构建；`computeFullReachable` 扩为按来源（帧 / 原生栈 word / 寄存器）归因 conservative-only 命中；test262 + Octane 跑 `ZJS_GC_VERIFY`，产出「保守扫描到底救了谁」的清单，把 F9 的 D 类洞逼出来。

**R3 结果（2026-09-05，`r3-diag-20260905`，原始数据 `/tmp/r3-attrib/`）**：诊断构建（ReleaseFast + `-Dzjs_gc_roots_diag`，帧指针保留，`value_root_link_containers_only` 已关 = 全部标量精确根已链）在 7 个 test262 目录（`ZJS_GC_STRESS=1`，零错）与 6 个固定负载（earley-boyer 用 divisor=16 替代）上归因 120,956 次探针 / 525,217 次 direct 命中：来源 stack<4k 57.4%、**寄存器 26.4%**、stack<16k 10.6%；`operand_window` **= 0**（证伪：保守扫描一个字都不落在操作数窗口，`pending_call_region` 是唯一覆盖它的机制，R1 后不能删）；指针形状 interior 38% / exact 35% / prefix 27%；kind：string 家族 28.7%（**S2 已固化 tracer-owned，是真依赖**）、property/array/payload 存储 38.2%（S4 才进 tracer，责任面扩大约四成）、object 19.6%。帧级：`pollGC` 49.5%、`collectMinor` 13.8%、`computeFullReachable` 11.2%（探针自污染）、`op_call_method` 6.1%、`pollRetreatedCallRegion` 4.3%、蹦床 `next` 2.3%……**可识别 mutator 帧仅 6.6%**：callee-saved 溢出槽只说明「谁保存了它」不说明「谁拥有它」，帧查表无法把 85% 变成站点清单。**裁决**：R1 不能按清单补 rooting 驱动，只能走计划原路线——解释器每个可分配 cold 出口前 `publish(pc, sp)` + `reg_sp` windowed 精确根 + 翻 `value_root_link_containers_only`（F8 的 134 站点）；可逐点修的干净窗口只有 `op_call_method` 的 NMFD 调用（>5%）、`pollRetreatedCallRegion` 的 callee/captures 纳入窗口、`tryFusedConstructor`、`initRegExpMatchArrayDenseElementsFromValue`（S4-b 明记例外，本次独立复现）、string/regexp 内建族的 replace/split/slice 局部。未决：`-Dzjs_gc_roots_diag=true` 单测在 R3 树不绿（待主树核实）；splay conservative-only young ≈2.4/minor 与 §D1 记的 1/12 口径不符需复核；全量 earley-boyer 未跑完；要再收窄需 GC 入口 fp 阈值分离 collector 帧 + 寄存器活性信息。

**R3 修正（同日深夜，`r3-diag-20260905` = 5d64af9d）**：首版仪器有自污染——普查表内嵌在 `JSRuntime`（+112KiB）挪动了 collection 时机、扫描范围含扫描器自身帧；表搬进 `gc_conservative` 的 `.bss`（诊断构建 `JSRuntime` 34,240B，与生产同构）、帧走查惰性化到扫描窗口之外、撤掉操作数窗口探针（实测 0 命中，按构造在窗口外）后重跑：direct 664,777，来源 stack<4k 51.7% / <16k 36.4% / **寄存器 7.6%**（首版 26.4% 是伪残留）；kind：object 28.9%、property_storage 27.9%、string 家族 20.7%、array_storage 14.5%、var_ref 6.4%、shape 1.1%。**可归因到 mutator 帧的份额 6.6% → 29.0%**，其中 **84% 集中在 `exec/eval_entry.zig:196`**——`runWithCallEnv` 的调用环境结构体（root_object / root_function / realm global / captures）整段脚本期间只在 `eval` 的栈帧上；同函数 230-234 行已有 `completion_values` 的 `ValueRootFrame` 模式 → **R1 第一刀 = 把 :196 的 env 套进 `ValueRootFrame`，一条改动吃掉清单八成**。其余：`tryFusedConstructor` 1.1%、`pollRetreatedCallRegion` 1.1%、`op_call_method` 0.7%、`collectBeforeObjectAllocationPublishingShape` 2,992 次（精确根已开仍命中 → 帧里另有东西）、`initRegExpMatchArrayDenseElementsFromValue` 复现。**顺带挖出先存在真缺陷**：诊断构建与生产同布局后，`language/{expressions,statements}/class/elements` 在 `ZJS_GC_STRESS=1` 下确定性 SIGSEGV——minor 年轻集合里的对象其 shape 已被回收（回溯 `traceHeader → callVisitShape → metaConst` 于 `collectMinor`），Registry 塞 25KB 惰性 padding 即不崩 = shape 年轻路径存活性依赖保守钉住；未修，已并入 s4-fix 诊断线。

**R1-a（2026-09-06，`r1-a-20260906`，六窗口逐条实证）**：R3 清单**大部分不可兑现**——(1) `eval_entry.zig:196` 套 `ValueRootFrame`（值/cells/headers 三类）后普查 158,240→158,214 纹丝不动：该帧命中 100% 是成对 `c_function`+`property_storage` interior 指针落在固定槽 fp-272/fp-320，反汇编证明是编译/诊断阶段 `Io.Writer` 缓冲指针槽的 **LLVM 栈槽复用残渣**（指向被回收复用的 cell），精确根治不了，只能擦栈/缩帧；(2) `tryFusedConstructor` 加 `rootObjects` 无下降（溢出从调用方行搬到本行）；(3)(4) `pollRetreatedCallRegion`/`op_call_method` 前提证伪：NMFD 前 `setTopPtr(sp)` 已把 receiver/method/args 纳入窗口、pending region 确被追踪、命中是 tailcall 帧区复用残渣 + native 切片指针，未改热路径（objdump 1648→1648）；(5) `collectBeforeObjectAllocationPublishingShape` **真 bug**：`ValueRootFrame` 声明在 `if (comptime …)` 块内而 `collectBeforeObjectAllocation` 在块外，`defer deactivate` 先跑——Shape 在唯一要保护的窗口无根（已修，生产 codegen 零变化）；该帧 757 条命中是调用方 callee-saved 溢出，内联后原封搬到 `object.zig:1579`；(6) `initRegExpMatchArrayDenseElementsFromValue` 改为先铸 `.array_storage` cell、`@memset` undefined、`.headers`+`.slices` 根、原地填充 + `generationalBarrierValue`——**唯一有量**：regexp direct 218,390→201,427（−7.8%），`pollGC` 帧 −12.5%、`op_call_method` 帧 −17.8%，.text −1,888B。**R1 规划修正**：owner-frame 排名把「调用方 callee-saved 溢出」与「LLVM 复用栈槽残渣」都算进被调用者帧，R1 不能照 R3 清单干 12-20 lane-week；普查需加 `word-header` 偏移与帧内槽位两列以分辨残渣；eval 帧 39% 靠缩帧/擦栈（把编译阶段大局部限定到独立作用域）而非根；pdfjs transitive −87.5% 未归因（可能时序假象）。

**R1-b（2026-09-05，`r1-b-20260906`，普查判别列 + eval 缩帧）**：普查每条 direct 命中新增三列并给出 **verdict 三分类**——(a) `word - header` 偏移桶（exact=+0 / prefix=-8 / interior 按 8B 到 ≥256）；(b) 帧内槽位 `frame_base - word`（`diagOwnerPcs` 现返回 owner 帧的 `fp`，8B 粒度进 key）；(c) `.bss` 站点表 `(owner pc, slot, thread) → last header`，记稳定次数 + 该槽历史命中过的 GC kind 位图。**线程维度是必需的不是可选的**：run-test262 八个 worker 跑同一批原生帧，(pc, slot) 单独作 key 会把八个互不相干的槽混成一个，实测把已知的 `eval` 残渣读成 10% 稳定；按线程分开后同两个槽是 92%/98%。**kind churn 是第二条残渣特征、也是更锐的一条**：Zig 局部有静态类型，真根槽永远解析到同一个 kind，而死槽解析到"此刻占着这个地址的随便什么 cell"；它能抓住那些每个脚本被改写一次、因而 header 稳定性天然被稀释掉的残渣。判据：非 exact 为主 ∧（稳定率>90% ∨ distinct kind ≥3）→ `likely_residue`；exact/prefix 为主 ∧ 槽位在 AAPCS64 序言保存带（`fp-16*k`，取 ≤160B）→ `likely_spill`；其余 → `candidate_root`。单测两端各一：故意留的陈旧 interior 槽判 residue，深槽里的裸 header 指针判 candidate。默认构建 comptime 全门，零成本。

**eval 缩帧**：R3 榜首 `exec.eval_entry.eval`（158,186 命中 = 全进程 40%）的两个槽 `fp-272`/`fp-320` 既不是调用环境也不只是 `Io.Writer` 缓冲——它们是 **编译阶段的溢出被 LLVM 叠在"VM 跑完之后"才用的完成值根帧槽位上**，整个脚本期间是死的、指向被回收复用的 cell。三个 `noinline` 外提（`resolveModuleName` 拿走 64B 名字缓冲与 `bufPrint` 内联出来的 `Io.Writer`；`prepareRootFunction` 拿走 parse result / link diagnostic / 语法错误面 / 根函数对象发布，并在此处而非 eval 末尾释放 parse result——两条所有权转移都已把它清空所以是安全的；`drainAndFinish` 拿走完成值根帧与 job drain）后，语料 A 上该帧 **158,186 → 372（−99.8%）**，全进程 direct **396,979 → 236,453（−40.4%）**，residue 占比 68%→51%、candidate 占比 26%→39%。运行期零成本（每脚本一次、本就被 parse 压住）。

**R1-b 修正后候选清单（语料 A，只列 `candidate_root` 命中数）**：`pollGC` 44,151 / `collectMinor` 14,234 / `op_call_method`(tailcall_dispatch:1806) 11,402 / `pollRetreatedCallRegion`(:581) 8,499+1,037+134+131 / `computeFullReachable` 3,105 / `stringCall` 687 / `regexpCall` 585 / `invokeExecDirectRecord` 584 / `callTypedInternalRecordDirect` 571 / `next` 蹦床 493 / `gcSafepoint` 489 / `createInternal`(object.zig:1584) 406 / `invokeResolvedInternalRecord` 401 / `eval`(prepareRootFunction 调用点) 372 / `op_call_method`(:1855) 309。⚠️前四条里 `pollGC`/`collectMinor`/`computeFullReachable` 是**收集器自身帧**，其 candidate 份额按 R3 已知机制是调用方 callee-saved 溢出（序言保存带之外的槽也会落在这里），不是它们自己的局部——按帧查表仍无法把这部分翻译成站点，需要 R1 主线的 `publish(pc, sp)` + windowed 精确根。`/tmp/regexp.fixed.js`（618 probe / direct 10,457，residue 33% / spill 20% / candidate 46%）上的干净 mutator 窗口反而更清楚：`stringCall` 609、`callTypedInternalRecordDirect` 307、`stringReplace`(string_ops:396) 217、`invokeResolvedInternalRecord` 205、`callStringReplaceMethod`(:613) 173、`regExpSymbolSplitGeneric`(:1090) 164、`regExpExecCompiledResult`(regexp_fastpath:792) 159、`stringSplit`(:2238) 156、`initRegExpMatchArrayDenseElementsFromValue` 69（S4-b 记的例外再次复现）；同一批帧里 `regExpExecGeneric` 270 与 `regexpSymbolSplitCall` 152 是 **100% `likely_spill`**，即调用方的寄存器被被调用方序言存下来，在这两行加根是无效功。

**R1-b（2026-09-06，`r1-b-20260906` = eec97463 / 95e77411 / …，已合入）**：普查每条命中加 `word-header` 偏移桶、帧内槽位（`fp-N`）、按线程的站点稳定率与 kind 位图（`.bss` 65,536 站点表）；verdict：非 exact ∧（稳定率>90% ∨ distinct kind ≥3）→ `likely_residue`，exact/prefix ∧ 槽位在 AAPCS64 保存带（≤160B）→ `likely_spill`，其余 `candidate_root`（线程维度必需：不分线程时已知残渣读成 10% 稳定，分开后 92%/98%；kind churn 是更锐的残渣特征——真根槽静态类型恒定）。eval 缩帧：`fp-272/fp-320` 是 LLVM 把编译阶段溢出叠在「VM 跑完后才用」的完成值根帧槽上（外提 `resolveModuleName` 帧 2176→1472B 命中不动即证），三个 `noinline` 外提（`resolveModuleName`/`prepareRootFunction`/`drainAndFinish`）后 **eval 帧命中 158,186 → 372（−99.8%），全进程 direct −40.4%**，residue/spill/candidate 68/5/26% → 51/9/39%。修正后候选根（语料 A）前列仍是 `pollGC`/`collectMinor`/`computeFullReachable` 的 callee-saved 溢出（67%，帧查表不可归因）；regexp 负载的干净 mutator 窗口：`stringCall`、`callTypedInternalRecordDirect`、`stringReplace`、`invokeResolvedInternalRecord`、`callStringReplaceMethod`、`regExpSymbolSplitGeneric`、`regExpExecCompiledResult`、`stringSplit`、`initRegExpMatchArrayDenseElementsFromValue`；`regExpExecGeneric`/`regexpSymbolSplitCall` 100% spill（加根无效）。R1 下一批 = 这九个 string/regexp 内建窗口 + 主线（cold 出口 publish / windowed 根）。

**R1-c（2026-09-06，`r1-c-20260906`，已合入 5c6f177d）**：普查 owner 帧是**内联后**的真实帧（`stringSplit`/`stringReplace` 同属 `stringPrototypeMethod` 帧且共用槽 fp-912 → 残渣）。保留两处真根：`regExpSymbolSplit`（结果数组 `out` exact/young 5,222 命中 + 借用 flat body + splitter + exec result；candidate 5,910→1,113）与 `regExpExecCompiledResult`（`compiled.bytecode` + 输入串 flat payload，只能经 `regexp_value/string_value` 命名；进程 candidate 67,362→57,964，−14%，连带 `stringSplit` −63%、`stringCall` −44%）。回退/不改：`split_args`（被调方 `callValueOrBytecodeRoot` 先拷进 `inline_args`，本数组已非权威，加根反升 +2,879）、`callStringReplaceMethod`（上一帧 `.slices = .{ .borrowed = args }` 已根住；唯一无第二 owner 的是 getter 现铸 callable 的 `replacer`）、两个分派壳（`receiver`/`args` 已是根；残余为编译器复用深槽与调用方寄存器）。进程 candidate **75,925 → 57,964（−23.6%）**；生产 codegen 零变化（标量帧在 `value_root_link_containers_only` 下擦除——这些根今天在生产不存在，价值兑现于打开标量帧那一刻）。**两条真发现（R1-d 处理）**：`callValueOrBytecodeRoot`（call_runtime.zig:207）建 `ValueRootBuffer` 却从不 activate，>8 参数时 `initCopy` 的 alloc 是收集点且源数组无根；verdict 规则的 kind-churn 签名被 `non_exact*2 > hits` 门卡住，exact 且 kinds≥5 的死槽永远判 candidate（`stringCall` fp-488）。

**R1-d（2026-09-06，`r1-d-20260906`，已合入）**：`callValueOrBytecodeRoot` 在拷贝后对 `rooted_args`（`.mutable` 切片）+ `this`/`func` 建帧并 activate，>8 分支在 `initCopy` 前先根住源 `args`；函数 119→184 insn，定向微基准 +0.35%（远低于 5% 回退线）。普查：`stringSplit` candidate 7,208→2,450，**unlocated 18,914 → 8**（寄存器 x10 那批 conservative-only string 全部变声明根）。verdict：kind-churn 签名移出 `non_exact*2 > hits` 门（exact 且 kinds≥3 的死槽判 residue），全局 residue/spill/candidate 45/14/39 → 63/5/31%。余：`call.zig:130` `callValueWithThisGlobalsAndGlobal` 有同一个 >8 缺口（未动）。

**R1 全精确非移动（12-20 lane-week，R3 后 owner 二次裁决量级）**：≈740 个候选函数按 R3 清单收窄后补 rooting；解释器每个可分配 cold 出口前 `publish(pc, sp)`（tailcall_dispatch 审计）或 `reg_sp` windowed 根；保守扫描降为 `-Dzjs_gc_verify_roots` 校验臂，生产关闭。

### S5 收尾（1 lane-week）

删 gc_conservative 生产路径的门、`concurrent` 改名 `incremental`、Registry 拆 Scheduler / Heap / Lists / IncrementalMajor / Diagnostics 五个子结构、header-v2 文档标 superseded、写完成对账。

## 4. 依赖图

```
S0 ─┬─ S1 ── S2 ── S3 ── S4 ── S5
    └─ R3 ─────────── R1 ─────┘
```

S2 依赖 S1（bigint 先走一遍「入 tracer」的全套改点，作为 string 的小规模排练）。S4 依赖 S3（dup/free 删掉后 destroy 路径才能整段删）。R1 与 S4 无代码依赖，但 R1 完成前 string / storage cell 的活性同样靠保守扫描兜底，因此 **S2 起 string 必须对保守解析器可见**（S2 步 7）。

## 5. 不变量（每期必须保持）

1. 精确根 + 保守扫描的并集在每期都覆盖该期新增的 tracer-owned kind（string / bigint / storage 在保守解析器里可解析）。
2. 三色不变量：新 kind 的写入点都经 `generationalBarrierValue` 或 `rememberOwnerForBulkWrite`；每个新 kind 加入热臂 / 权威 / comptime 列表三处守卫。
3. `refCountRemoved(kind)` 恒 true 的 kind 不得有任何 `retain/release` 路径残留（comptime 断言）。
4. 弱语义只在 sweep 期由 mark 位决定，不由计数决定。
5. 每期结束时 `--gc-stats` 的 `destroyed counted objects` 语义清楚（S4 后普通对象不再计入）。

## 6. 门禁与记账

- **裁决门（每期）**：`zig build test` 全绿；test262 双模式 0 回归；`ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=1 ZJS_MINOR_AUDIT=1` 单测绿；leak census 0；本期 deletion-probe 守卫。
- **记账不裁决**：Stage 0 七指标 + cycles(u+k) + maxrss + minflt 对 `shared-h_pre0/main-d944f26d` 记录，写进各期报告，不设线。S5 结束后一次正式 2×2 出「完成态 vs v2 终态」总账，作为下一阶段（性能再定价）的起点。
- 并行 lane 同机测量污染规则沿用（parallel-lane 教训）：记账跑单独安静窗口。

## 7. Supersede 表

| 被取代条款 | 取代为 |
|---|---|
| header-v2 O1：Shape/Realm 保留 body RC | S1：删除；COW 唯一性用 `shared` 位 |
| header-v2 O1：BigInt 8B 前缀含 rc 字 | S1：BigInt 普通 tracer kind |
| header-v2 §6.1「BigInt never placed on trace-live」 | S1 步 4 |
| tracing-gc-design §4.5「Strings/ropes… retain a separately registered leaf/rope descriptor」 | S2：string 即块 cell kind |
| tracing-gc-design §1.4 非目标保持不变（移动 / 并发 minor / 并发 sweep 仍非目标） | — |
| gc-v2-completion §4 转向 TS/AOT | 顺延至 S5 后 |
| header-v2 O2 mark-frontier 契约（四 kind 限定） | S2 后扩为全部 tracer-owned kind，O2 的 epoch-exemption 证明需重做 |

## 8. owner 决策点

| ID | 决策 | driver 建议 |
|---|---|---|
| D1 | 根集终态：R1 全精确非移动 / R2 再加 copying nursery / 维持保守 | **R1**。R2 需 ≥9 个以地址为身份的结构 + IC ABA + FNABI pin，且 splay 实测 conservative-only young 仅 1/12 minor，收益无法在 R1 前定价；先 R3 拿清单再定 R1 量级 |
| D2 | 属性 / 数组存储形态：独立 GC kind（JSC butterfly 式）/ 仅内联 | **独立 GC kind**，走 block 小类 + medium，F10 证明改点 ≈12 处 |
| D3 | `JSValue.dup/free` 处置：no-op 保留（qjs 源码对齐可读性）/ 机械删除 | **删除**（S3 步 4）。7826 处 no-op 是最大的一块阅读噪音，且保留会诱发新代码继续「配对」 |
| D4 | atom 表：S3 全弱化 / 长期保留 atom rc 只弱化 string body | **全弱化**，但分两步（S2 保留 rc 作强根，S3 弱化），编译期临时用作用域 root provider 避免 130 处逐字段建边 |
| D5 | S2 中 string 的载体：块 cell 位图权威（同 Object）/ 非块链表 carrier（同 shape） | **块 cell**。链表 carrier 在百万级 string 上 sweep 是指针追逐，且与 S4 的 storage kind 路径不一致 |
| D6 | 本计划期间 T-spike / TS 类型导向线是否并行 | **不并行**。两线都改 Object 布局与解释器热路径，合并冲突与测量污染都不可控 |

## 9. 风险

- **R1 量级不确定**（12-20 lw 是上界估算，R3 后收窄）；若 owner 不接受，退路是 R3 + 永久保守（JSC 路线），本计划其余部分不受影响。
- **S2 的 rope 原地 flatten 与并行标记**：并行标记默认关，S2 期间保持关，S5 前补「flatten 只在 mutator 期」断言。
- **S4 的 Generator open VarRef**：若不 close 会指向已死栈；需在规格里决定「sweep 前统一 close」或「VarRef 仅 close 时持值」。
- **FNABI**：插件持有的 JSValue 若含 string，S2 后其活性由 handle 表承担；对照 `docs/runtime-plugin-abi.md` 的 persistent handle 条款，S2 规格内确认无裸 string 借用跨调用。
