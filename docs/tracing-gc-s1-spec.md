# TGC S1 规格：Shape / Realm / BigInt 去 rc

状态：v0.1（driver 规格，2026-09-03）；上游计划 `docs/tracing-gc-completion-plan.md` §3 S1。
基线：main（S0 e5115fd4 + 消融 gc/ablation-20260903 合入后）。分支 `gc/tgc-s1-20260903`。

## 0. 目标与拆批

三种 kind 的活性改由 tracer 的 mark 决定，死亡只走 doomed pass；`refCountRemoved` 对 `.shape/.realm_context/.big_int` 恒 true，`headerRefCount` 三臂删除。分三批各自过门，顺序 a→b→c：

| 批 | 内容 | 净删（估） |
|---|---|---|
| S1-a | Shape：`shared` 位替代 rc==1 判定；删 retain/release/eager-zero 路径 | −250 |
| S1-b | Realm：`RealmRef` 变裸指针；5 个无根持有者补根；teardown 改 full major | −300 |
| S1-c | BigInt：入 `addInitialized*` 漏斗、cycleMarkHeader/doomed pass 各加臂；parser 字面量 BigInt 由编译期 root provider 保活 | −80 |

每批门：`zig build test` 全绿；`zig build test-gc-stress`；test262 script 0/49778；`-Dzjs_gc_roots_diag` 单测绿；Stage 0 记账（不裁决，cycles-only 不阻塞——owner 09-03 裁决沿用）；`gc-representation-trace-snapshot.txt` 按新 catalog 重生成。

## 1. S1-a Shape

### 1.1 事实（已对 HEAD 核实）

- Shape 已被 tracer 追踪：`Object.traceChildEdges` 经 `visitShape` 访问 `shape_ref`；三处 `shape_ref` 写点已有 `generationalBarrier`（object.zig 7960/8979/10429）；unmarked shape 已被 `destroyDoomedSlice`（gc_trace_stw.zig:1398）与 `destroyCondemned` 终臂（:2597）销毁。**rc 现在只做两件事**：rc→0 即时释放；`refCount()==1` 作 COW 唯一性判定。
- 哈希表（`registry_hash_next` 链）不计数：`createObjectRoot*` 命中即 `retain()`，rc==1 ⇔ 恰一个 Object/Realm 持有。
- 持有者增加的全部入口 = `Shape.retain()` 的 9 个调用点：shape.zig 384/402/419/436（hash 命中）、565（cached transition 命中）；object.zig 1068/1410（realm 初始 shape 被对象采用）、1505/1608（template shape 被新对象采用）。

### 1.2 `shared` 位

```zig
pub const ShapeOwnership = extern struct {
    /// 0 = 自创建起只有一个持有者（可原地变异）；1 = 曾被第二个持有者采用（变异前须克隆）。
    /// 只置位不清零：持有者死亡不回退，代价是「曾共享后来唯一」的 shape 多克隆一次，之后克隆体 shared=0。
    shared: u32 = 0,
};
```

- 布局不变（4B，对齐 i32，offset 0 pin 改名）；`FinalizingShapeStorage`（object.zig:63）初始化 `.shared = 1`。
- `Shape.retain()` → `Shape.markShared()`；`Shape.refCount()` → `Shape.isShared()`；上述 9 个调用点逐一改名。
- 6 个判定点：shape.zig 581 `parent.refCount() != 1` → `parent.isShared()`；660 `isHashed() and refCount()==1` → `isHashed() and !isShared()`；667 `refCount()==1` → `!isShared()`；709/826/934 `assert(refCount()==1)` → `assert(!old.isShared())`；object.zig 11134 `shapeNeedsMutationCopy` → `isShared()`。
- `cloneShape` 产物 shared=0（默认值）；`createShape*` 同。

### 1.3 删除

- `Registry.release`、`releaseForRealmTeardown`、`recordRealmTeardownShapeAdmissionForTest`、`recordRealmTeardownShapeFifoDestroyForTest`、`RealmTeardownRouteProbeStorage`/`begin…/end…ForTest`（gc.zig 1490-1515、4848-4900）及其唯一测试（tests/core.zig:1261-1280 段）。
- 所有 `self.release(parent)`/`self.release(current)`（shape.zig 567/600/609/670）与 `errdefer … shapes.release(x)`：已发布 shape 直接丢弃（等 sweep）；**未发布**（`createObjectRootReserved`/`createShapeReserved` 产物，object 构造失败路径 object.zig 1070/1412/1507 的 errdefer）改调 `Registry.discardReserved(shape)`：`if (!heap_accounted) destroyShape(shape)`（未发布不在 gc 列表也未 hash，直接释放）。
- gc.zig：`headerRefCount`/`setHeaderRefCount`/`resetHeaderLifetimeForPublication`/`assertInitialHeaderLifetime` 的 `.shape` 臂删除（并入 unreachable/tracer 臂）；`destroyZeroRef` 的 `kind == .shape` 分支；`destroyEagerZeroDirect`/`enqueueEagerZeroDirect` 收窄为仅 `.realm_context`（S1-b 整体删除）；`generationalBarrier` 4124-4126 特例中的 shape 半边；`gc_trace_stw.zig:1688` shade 守卫允许 `.shape` 入队（`frontierEpochSafe(.shape)=true`，comptime 断言 559 同步）。
- `ref_kind_catalog`/`representation_kind_catalog` `.shape .ref_count = .retained` → `.none`（与 object 同）；快照文本重生成。
- context.zig `releaseInitialShape`：只清槽（`phaseIsTwoPassTeardown`/`cycle_visited` 判定一并删）；803-811 五个 errdefer 删除；tests/core.zig:8613 循环删除。
- `trace_list_previous` backlink：仍承载 `is_hashed` 位且 morgue unlink 用它，本批不动，S4 头部重排时处理。

### 1.4 测试改写（tests/core.zig）

1261 `initial_shape.refCount()==1` → `!isShared()`；3887 `unique = !isShared()`；5484/5486/5573（rc 2→1 回落）改为断言「第二持有者死亡后 `isShared()` 仍为 true 且变异走克隆」；6556-6591（操作前后 rc 不变）改为 `isShared()` 不变；11438/11546 → `!isShared()`。

## 2. S1-b Realm

### 2.1 事实

- 持有者 15 类（勘察表见附录 A）；已有 traced 边的：FunctionBytecode.realm、FinalizationRegistry/RealmRecord/Native FunctionPayload、AUTOINIT 槽、Job（**受 `value_root_frames_enabled` 门控**）。**无根的 5 个**：`ModuleContinuation.realm`（module_graph.zig:123）、`ModuleEvaluationWaiter.realm`（:145）、`EventLoop.realm`（event_loop.zig:57）、`AtomicsWaiter.realm`（atomics_ops.zig:143，未入队时）、`OwnedBinding.realm`（binding.zig:145）。
- 宿主 create-ref 是 realm 的根：`traceRootProvider` 在 `host_api_release_consumed` 后不再上报（context.zig:1085）。

### 2.2 改法

1. `RealmRef`：保留类型名与 `.ptr`，`retain/clone/takeOwned/deinit` 改为 no-op 内联（先机械保留调用，本批末尾删除 25 处 `.deinit()`/35 处 retain）。`traceRefCountPtr*`、offset 2164 pin、`initConstructing` 的 rc=1 种子删除；backlink 2168 保留（morgue unlink）。
2. 补根：`ContinuationRoots.traceRoots`、`WaiterRoots.traceRoots`、`EventLoop.traceRoots` 各加 `visitor.constHeader(&realm.ptr.header)`；`AtomicsWaiter` 链表补一个 root provider（waiter 列表所属结构注册，`traceRoots` 遍历链表上报 realm + 已有 value）；`OwnedBinding` 在创建时 `rt.gc.pin(&realm.header)`、销毁时 unpin。`Job.realm` 上报去掉 `value_root_frames_enabled` 门。
3. `JSContext.destroy/tryDestroy`：`consumeHostApiRelease()`（撤 root provider）后不再 `gc.release`；realm 由下一次 major 回收。
4. `runtime.deinit`：删 `context_head == null` 四断言，改为断言「每个仍在列表上的 realm 都已 `host_api_release_consumed`」；`releaseNativeFunctionRealmsForTeardown` 的 retain 保护删除（列表在 deinit 期间不被 mutator 改动）；`gc.deinit` 前先跑一次 full major（让 realm 走正常 `destroyFromHeader` 而非 deinit 特例），deinit 特例分支保留作兜底。
5. gc.zig：`enqueueEagerZeroDirect`/`destroyEagerZeroDirect`/`ZeroRefScratch` 的 eager 用途、`headerRefCount` `.realm_context` 臂、`resetHeaderLifetimeForPublication`/`assertInitialHeaderLifetime` realm 臂、barrier 4124 特例、shade 守卫 1688 全部删除；`refCountRemoved(.realm_context)=true`、`frontierEpochSafe` 同步；catalog `.retained → .none`。
6. `ZeroRefScratch`/`beginDecrefPhase`（计划步 6）：仅剩 weak 批处理用途时改名 `WeakSweepScratch`，在 S1-c 收尾一起做。

## 3. S1-c BigInt

### 3.1 事实

- `Tag.big_int = -9`（=`Tag.first`），tracer 区间 `[Tag.module=-3, Tag.object=-1]`；`cycleMarkHeader`/`isTracerOwned` 均排除。
- 分配：`rt.memory.create(BigInt)` / `createWithFam` / `createMulInline`，**从不调 `addInitialized*`**：不在 gc 列表、不在地址注册表（保守解析器解析不到）、`heap_accounted=false`、`heapByteSizeFromHeader` 记 0 字节。
- memory.zig:1400 `if (T.gc_kind_tag != 7) 0 else 1` 是唯一 rc=1 初始化；`traceRememberedCacheEligible` 排除 big_int 的理由是 byte 6 是 rc 的第三字节。
- 块堆空 cell 毒值（gc_block_heap.zig:63）故意伪装成 `.big_int`「因为它不被追踪」。
- parser 字面量：parser.zig:3783-3790 用 `function.memory.persistent_allocator` 解析 + `initExternalFromOwned` + `pushConstOwned`；FB 追踪 cpool 走 `visitValue`（对 big_int 目前是静默 no-op）。

### 3.2 改法

1. value.zig：`isTracerOwned`/`cycleMarkHeader` 区间改双比较 `(tag >= Tag.module and tag <= Tag.object) or tag == Tag.big_int`；`requiresRefCount` 排除 big_int；`destroyZeroRef` 的 `.big_int` 臂删除；`dup/free` 家族的 big_int 路径变 no-op（与 object 同）。
2. bigint.zig：`createFromOwned`/`createInlineUninitialized`/`createMulInline` 末尾走 `rt.gc.addInitialized*(header, bytes)`（bytes = 结构 + FAM 或 结构 + 外部 limbs 字节；`heapByteSizeFromHeader` 补 `.big_int` 臂读同一函数 `accountedAllocationSize`）；`destroyFromHeader` 不变。
3. gc.zig：`prefixRefCount*` 删除（`LifetimeWord` 文档同步）；`headerRefCount`/`setHeaderRefCount` big_int 臂删；`resetHeaderLifetimeForPublication`/`assertInitialHeaderLifetime` big_int 臂并入普通臂；`isCycleCandidate(.big_int)=true`；`traceRememberedCacheEligible` 含 big_int（comptime 表 736-751 同步）；catalog `cycle_candidate=true, ref_count=.none`；memory.zig:1400 特判删除。
4. gc_trace_stw.zig：`doomed_phase_kinds` 加 `.big_int`（在 `.var_ref` 后）；`destroyDoomedSlice`/`destroyCondemned` 各加臂 `unlinkObjectWithBytes + BigInt.destroyFromHeader`；gc.zig deinit 阶段 switch 加臂；`traceHeaderEdges` `.big_int => return` 保留。
5. 块堆毒值 kind 改为 `.string`（S2 前仍不被追踪），并在 gc_block_heap.zig 注释里登记「S2 需换毒值」。
6. parser：`emitBigIntLiteral` 改为普通堆分配（`BigInt.createFromOwned(rt, parsed)`，limbs 用 `accountedAllocator`），由 `FunctionBuilder` 在编译期注册的 root provider `CompileConstantRoots`（`traceRoots` 遍历 `cpool.items` 调 `visitValue`）保活；builder 创建时 `registerRootProvider`、FB 发布或 builder 失败 teardown 时 unregister。bytecode.zig FB teardown 对 cpool 的 `value.free` 对 big_int 自动 no-op。
7. 保守解析器无需改：入漏斗后 `Table.insert` 自动登记。

### 3.3 门

`tests/helpers.zig:109-125` 文档与 `expectRefCount` 语义更新；value.zig:850 `cycleMarkHeader` pin 测试改为断言 big_int 被纳入；`--gc-stats` 的 `destroyed counted objects` 语义注明含 big_int。

## 4. 记账

- Stage 0 三批各记一次 vs `shared-h_pre0/main-d944f26d`；S1-a 关注 splay/raytrace insn（shape 克隆次数变化：`--gc-stats` 无 shape 行，用 `perf stat` insn 对比即可）。
- 预期风险：S1-a 曾共享 shape 的多克隆一次（有界）；S1-b realm 延迟回收导致 `$262.createRealm` 密集测试 RSS 上升（test262 stress 观察 maxrss）；S1-c 大 BigInt 运算的中间体从「rc 即时释放」变「等 minor」——bigint 微基准 RSS 与 minor 频次记账。

## 附录 A：Realm 持有者表（勘察 2026-09-03，只读子代理，路径为消融 worktree）

| # | 站点 | 持有者 | 已有 traced 边 |
|---|---|---|---|
| 1 | bytecode.zig:3657 | FunctionBytecode.realm | 是（gc_trace_stw.zig:76） |
| 2 | object_payloads.zig:838 | FinalizationRegistryPayload.realm | 是（:858） |
| 3 | object_payloads.zig:976 | RealmRecordPayload.realm | 是（:985） |
| 4 | object_payloads.zig:1132 | FunctionPayload.NativeFields.realm | 是（:1178） |
| 5 | property.zig:226 | AUTOINIT 槽 RealmAndAutoInitId | 是（object.zig:7433） |
| 6 | jobs.zig:144 | Job.realm | 是但门控（jobs.zig:388） |
| 8 | exec/module_graph.zig:123 | ModuleContinuation.realm | 否（:63-70） |
| 9 | exec/module_graph.zig:145 | ModuleEvaluationWaiter.realm | 否（:96-102） |
| 10 | runtime/event_loop.zig:57 | EventLoop.realm | 否（:143-153） |
| 11 | exec/atomics_ops.zig:143 | AtomicsWaiter.realm | 否（无 traceRoots） |
| 12 | binding/binding.zig:145 | OwnedBinding.realm | 否 |
| 13-15 | binding/context.zig:127、cli、runtime.zig:2226 | 宿主 create-ref / 列表遍历守卫 | 宿主根 / 栈临时 |

## 执行记录

### S1-a（2026-09-03）

规格 §1 落地，两处与规格不同，均为实现时发现：

1. **Shape 不进 mark frontier**（规格 §1.3 说 `frontierEpochSafe(.shape)=true`）。首轮 `zig build test` 触发 `FRONTIER SAFETY: reclaim began with live frontier`：`relocateShape` 在 inline FAM 增长时释放并重建 Shape 结构体，队列里的裸指针会悬空。改为保持 `frontierEpochSafe(.shape)=false`（同步 shade：标记后立即追 proto），comptime 断言放宽为 `frontierEpochSafe ⇒ refCountRemoved`。
2. **未共享 shape 由唯一持有者即时释放**（`Registry.dropUnshared`）。首轮 22 个失败里 14 个是 OOM 重试类测试：失败路径留下的垃圾 shape 被「达限先收集」回收后让本应 OOM 的分配成功。规则：`shared==0 ⇔ 恰一个持有者`，持有者放手即 `destroyShape`（deinit 阶段与 `cycle_visited` 已判死的除外，交给 morgue）；shared 的等 sweep。这恢复了 qjs 对唯一 shape 的即时释放，只有「曾共享」的 shape 多活到下一次 sweep。调用点：object destroy 两处、`setPrototype` 旧 shape、`tryCachedTransition` 的 parent、六个构造失败 errdefer、`createInitialShape` errdefer、realm `releaseInitialShape`。

测试改动：`closed_property_cycle_reclaimed_count` 4→5、两处 `expectCycleReclaimedIncludingShapes` 5→6（曾共享的空根 shape 现在由 sweep 回收并计数）；gc_stress 基线在一次 major 之后取；快照 `rc=trace_removed`；删除 eager-zero FIFO 路由测试与 deep Shape eager-zero 测试（路径已不存在）。

### S1-b（2026-09-03）

规格 §2 落地，偏离/补充：

1. **Realm 仍不进 mark frontier**（同 shape 的同步 shade 路径保留；`frontierEpochSafe(.realm_context)=false`），barrier 4124 特例与 shade 守卫因此保留，待 S4 统一处理。
2. **`RealmRef` 先保留 API**：`retain/clone` 返回裸指针、`deinit` 只清指针，65 处调用未机械删除（留给 S3 dup/free 大扫除一起做，避免本批 diff 混入纯机械改动）。
3. **无根持有者补根**：`ContinuationRoots`/`WaiterRoots` 的 `traceRoots` 上报 realm；`Job.traceRoots` 去掉 `value_root_frames_enabled` 门（该常量恒 true）；`traceWaitAsyncRoots` 在锁外逐个上报 waiter realm；`OwnedBinding.retain` 变 fallible（`pinHeader`），`deinit` unpin；`EventLoop.realm` 视为向宿主 `JSContext` 借用，不另加根。
4. **teardown**：删 `releaseNativeFunctionRealmsForTeardown`/`…ForContext`/`Object.releaseNativeFunctionRealmForRuntimeTeardown`；`runtime.deinit` 的四个 `context_head == null` 断言改为 `assertNoHostRealmRefsForTeardown`（每个仍在列表的 realm 都已 `host_api_release_consumed`），存活 realm 由 `gc.deinit` 阶段 1 现有 `.realm_context` 臂销毁（deinit 前已有两次 `runObjectCycleRemoval`）。
5. **eager-zero 路由整体删除**：`enqueueEagerZeroDirect`/`destroyEagerZeroDirect`/`drainZeroRefScratch`；`ZeroRefScratch`+`begin/endDecrefPhase` 保留为 processWeak 的相位括号（`endDecrefPhase` 断言 scratch 为空），S1-c 收尾时改名。
6. 测试：三处「destroy 后 realm 立即消失」改为 destroy 后 `forceMajorGC`（realm 记录/模块注册表 teardown 测试两处；OwnedBinding 测试改为「pin 下 major 后仍存活」+ 释放后不断言，靠 runtime 泄漏检查证明）；trace-carrier 测试删除 realm rc 断言；`forgetNativeFunctionRealmForTest` 替代已删的 teardown 释放助手。

### S1-c（2026-09-03）

规格 §3 落地，偏离/补充：

1. **BigInt 进 mark frontier**（`frontierEpochSafe(.big_int)=true`）：结构体发布后不再移动，队列裸指针安全；`traceHeaderEdges` 的 `.big_int => return` 保留（叶子）。
2. **parser 字面量走「预留 → FB 发布时注册」而非编译期 root provider**：`createFromOwnedReserved` 分配但不入列（既不标记也不清扫），`pipeline_finalize` 在 `addInitializedWithSizeNoFail(fb)` 前一行对 cpool 逐槽 `registerReservedValue`；builder 失败 teardown 走 `freeOwnedValue → destroyIfReservedValue`。与 `createObjectRootReserved` 同构，少一个 root provider 和它的注册/注销时机问题。
3. **qjs rc==1 原地 BigInt 加法删除**（value_ops.zig）：无计数无唯一性证据；bigint 密集代码若显著再议。
4. `refCountHeader` 只剩 object/module/fb（全部 tracer-owned，仅 husk 判定用）；`headerRefCount/setHeaderRefCount` 变 `unreachable`（所有调用点都在 `refCountRemoved` 门后）；`prefixRefCount*`/`destroyBigIntZeroRef` 删除；memory.zig 生命周期字初始化不再对 kind 7 特判。
5. 块堆空 cell 毒值 0x8700_0000 → 0x8600_0000（kind 读作 `.string`，S2 须再换）。
6. 测试：BigInt 单测直接持有的值用 `releaseForTest`（已注册则先 unlink 再 destroy）替代 `valueRef().free`（对 tracer-owned 值是 no-op，之前造成 deinit 记账 oracle 断言）；value.zig 的 `cycleMarkHeader` pin 反转。

### S1 整期门（2026-09-03）

- test262 script：0/49778（passed 44584）。
- `zig build test -Dzjs_gc_roots_diag=true`：2501/0。
- 子批门（每批）：`zig build test` 2501/0、`test-gc-stress` 2497/0。
- Stage 0 记账：见下方补记（工具修正两次：`gc_stats_snapshot.py` 的 refcount-removed 分区改为全 kind 求和且对 `big-int` 列可选；引擎 `marked-set kinds` 行追加 `big-int`；快照 JSON schema 保持不变以便与 S1 前基线比对）。

#### Stage 0 第一读数与修正（2026-09-03 夜）

首次 Stage 0（S1-c 后）：**insn deltablue 1.106 / earley-boyer 1.071 / raytrace 1.059 / pdfjs 1.038 / splay 1.027 / regexp 1.011**，STOP。指令级符号 A/B（`perf record -e instructions:u`，去 anon 编号）：增量分散在 `op_return`/`op_get_loc0_field`/`opLoc`/`op_return_undef` 等做 `dup/free` 的 handler，`adoptShapeForNewProperty`/`allocCellFixedPtr` 反而略降——**不是 sticky-shared 克隆风暴，是 `isTracerOwned`/`cycleMarkHeader` 的双比较**（`[module..object] ∪ {big_int=-9}`）落在每次 `dup/free` 上。修正：`Tag.big_int` 从 −9 移到原空洞 −4，tracer-owned 区间 `[big_int, object]` 连续，恢复单次无符号比较（`Tag.first` 变 −8；与 qjs 编号偏离，已在 value.zig `Tag` 注释登记）。deltablue `perf stat instructions:u` 复测：356.93G → 356.60G（**0.9991**）。gc-stats 侧 deltablue major 30→21、promoted 582k→380k、blockHeap.live 1.45M→1.14M（garbage shape 即时释放规则与 realm/bigint 延迟死亡的净效果，记账不裁决）。

#### Stage 0 终读（tag 修正后，2026-09-03，产物 .scratch/stage0/20260903T130530Z-2323050）

**PASS**。insn / cycles（vs `shared-h_pre0/main-d944f26d`）：deltablue 0.9993/0.9922、earley-boyer 0.9965/1.0055（cycles 待正式）、pdfjs 0.9963/0.9861、raytrace 0.9916/0.9940、regexp 0.9991/0.9932、splay 0.9889/0.9938。gc-stats：deltablue major 30→21、earley-boyer major 212→244（+15%，phase-sensitive 诊断项）、minor/deferred block runs 均在 ±3% 内。S1 三批净效果：全部 gc.Header kind 去 rc，指令数持平略降。
