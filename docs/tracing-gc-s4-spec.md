# TGC S4 规格：零成本 sweep（存储与 payload 入 tracer，普通对象死亡不进析构）

状态：v0.1 草案（driver，2026-09-05 凌晨）；上游 `docs/tracing-gc-completion-plan.md` §3 S4、§2.1/§2.2 目标态、§8 D2（owner 批：属性/数组存储做独立 GC kind）。
基线：main（S3 落地后，≥ 13c68700；S3-d 清理与 pdfjs 回归修复合入后起步）。分支 `gc/tgc-s4-*`。
勘察：只读报告一份（2026-09-05，Opus，main@13c68700，行号为现值）；本文只引用其结论与位置。

## 0. 目标

普通对象（`class_id == object`、a 类 payload）死亡时**不进入任何析构函数**：`prop_values`、数组元素缓冲、a 类 payload 变成 GC cell（kind `.property_storage / .array_storage / .payload`），由 owner 的 trace 边标记、位图 sweep 直接回收；只有 b/c 类（外部资源 / 弱语义 / 游标 / 借用身份）在构造时置 `needs_finalizer`，sweep 只遍历 `doomed ∧ finalizer` 的 cell；计账块级化（`popcount(alloc ∧ ¬mark) × cell_size`）；删 `destroyPlainObjectFast/Slow` 主体、Pass-A settle、Pass-B 停尸链、corpse census、`DeferredFreeStack`（净删 ~800-900 行）。弱语义（WeakRef / WeakMap / FR）改按 mark 位清槽，删 husk 与两遍 park。

## 1. 事实（勘察摘录，行号为 main@13c68700）

### 1.1 析构路径
`destroyDoomedSlice`（gc_trace_stw.zig:1336，唯一驱动）→ 块 cell 按 kind 分派（`.object → Object.destroyFromHeader` :2280；`.string → string.destroyCellFromHeader` :1330）→ 非块 object → `doomed_by_kind` 分桶。`destroyFromHeader` 快臂门（:2291-2317：`class_id==object ∧ payload none ∧ weakref==0 ∧ !has_weak_id ∧ !borrowed_holder`）→ `destroyPlainObjectFast`（:2329-2367）；否则 `destroyFromHeaderSlow`（:2369-2571）。两臂尾部共享 Pass A `trySettleTracerBlockCorpse`（object_gc.zig:68-108）→ 失败 `deferCycleStructFree`（gc.zig:1687）→ `DeferredFreeStack`（gc.zig:1114-1150/1548）→ Pass B `drainCycleDeferredFreesBudgeted`（object_gc.zig:111-185）。
析构步骤分类：**纯内存归还** = 释放外挂 `prop_values`（:2339/:2433）、`destroyArrayElements`（:4383）、`freeObjectAllocation`（:2537）、a 类 payload switch 臂；**必须保留** = `unregisterWeakReferenceHolder`（:2419）、`clearBorrowedReferencesForDestroyedObject`（:2431）、`enqueueDeferredStdFileClose`（:2432）、`finalizeClassPayload`（:2447，嵌入回调）、weak husk（:2528）、`takeWeakObjectIdentity`（:2536）、`releaseObjectDefinition`（dynamic class pin）、`shapes.dropUnshared`（:2343/:2438，shape 仍非块 carrier）、`clearCachedIteratorNext`（:2345，IC 侧表）。

### 1.2 属性存储
`prop_values: [*]property.Entry`（object.zig:504，`@offsetOf == 16`），三种表示共用一指针：empty 哨兵（:10153）、内联 tail slots2（`self + @sizeOf(Object)`，仅 `class.ids.object`，容量 2）、外挂（`rt.allocRuntime(Entry, cap)`）；唯一外挂谓词 `propertyStoragePointerIsExternal`（:10170）；容量 = `shape_ref.prop_size`。站点：构造分配 4（:1073-1112 / :1344-1372 / :1407-1439 / :1500-1635）、内联构造 :1206-1257、增长 2（`appendPreparedPropertyEntry` :9974-10074、`ensurePropertyCapacity` :10123-10146）、压缩 shape.zig:840-909（`compactPropertyLayout`，含压回内联分支）、释放 5（:2339/:2436/:10074/:10146/shape.zig:909）、errdefer 回滚 :10062-10073。**F10 成立且更强**：object.zig 之外没有任何 `[*]property.Entry` 变量，外部读点全经 `propertyEntry(index)`（:10206）每次重载指针 → 非移动下读点零改动；需改的只有 shape.zig:857 压缩与 gc.zig:3068-3098 布局审计。

### 1.3 数组元素
`arrayArm()`（values/count/capacity/length）仅 `array / arguments / mapped_arguments` 三 class 激活（:4388-4390 硬约束）。增长 `ensureArrayBufferCapacity`（:4419-4456，remap 臂 :4442）；入口 :4460/:4473/:9760 均含 `rememberOwnerForBulkWrite`；adopt 2（:4336/:4353）；`mapped_arguments` 表 :4101-4117 同一缓冲按 `?*VarRef` 解释（:4154/:4162）；释放 4（:4383-4409 / :4411 / :4436 / :4455）；裸 slice 读点均即时重取。TypedArray/ArrayBuffer 数据不属此类（inline / 堆 / `SharedBufferStore` 原子 rc / 宿主 external + view 双链）→ b 类。

### 1.4 payload 分类（PayloadKind 21 值，class.zig:142-164；大小除 Function 56B / RegExp 16B 外为估算，规格前打 `@sizeOf` 快照）
- **a**（纯内存）：ordinary（≈360B，slots2 时须先消 `rt.slots2_payloads` 侧表 :6010）、arguments 16、object_data 24、bound_function 64、proxy 48、var_ref 32、promise ≈112、disposable_stack ≈112、global ≈16、regexp 16（destroy 已 no-op）、function 的 bytecode 臂（rare ≈300 + aux）。
- **b**（外部资源）：buffer（unlinkAllViews + releaseStorage）、typed_array（view 双链）、std_file（FILE*）、realm_record（realm host ref）、function native 臂（realm.deinit、borrowed_holder 索引、dispatch atom）、嵌入/插件 dynamic class（`has_payload_finalizer`，`releaseObjectDefinition` 退 pin）。
- **c**（弱语义/游标）：iterator（`releaseIteratorCollectionCursor`）、collection（weak_entries 逐条 `releaseWeakIdentity`、live_cursors、weak_holder_link）、weak_ref、finalization_registry（cells + job 预留 + realm.deinit）、generator（挂起帧/栈/open VarRef）。

### 1.5 头部位
`BlockFlags(u8)`（gc.zig:576-600，位序 :691-696 断言）：kind:u3（**8 值已满**）| mark | young | finalizing | is_pinned | cycle_visited。
- `mark`：仅 10 处读写，块 cell 权威已是位图；**但 S2 把它重用为 rope 判别位**（`metaIsRope` string.zig:1297-1300，`allocRopeNode` :1238 置位）。
- `is_pinned`：sweep 侧 11 个读点（gc_trace_stw.zig:489/1101/1130/2120/2126/2136/2149/2170/2259/2291/2317）+ 4 写点；权威 `pin_entries`（gc.zig:1525，线性查找 :2547）。
- `cycle_visited`：写 5 处（condemn/detach 三函数 + husk 复位），读 ~24 处；语义「已从活性结构摘除、跳过 unlink」（gc.zig:2561-2576、runtime.zig:1935）。
- `needs_finalizer`：全仓 0 处，纯新增。
- 前缀裸字节写点：memory.zig `initGcPrefix` / `createStringExtent`（:1867 直接 `<<8` 拼 kind 字节）；catalog `representation_kind_catalog`（gc.zig:444-453）、`gc_representation_constants.zig`、快照 `gc-representation-trace-snapshot.txt`。

### 1.6 计账
逐对象 `creditAlloc`（memory.zig:719）/ `debitAlloc`（:724）/ `debitBlockCellPayload`（:1902，Pass A 唯一入口）；`unregisterObjectWithBytes`（runtime.zig:1917-1941）按 `cycle_visited` 选 `recordDetachedHeapFreeWithBytes` 或 `unlinkObjectWithBytes`。**块级原料已齐**：`Block.snapshotDoomed` 返回 `dead = Σpopcount(alloc ∧ ¬mark)`（gc_block_heap.zig:541-557）、`recordDoomedBlock` 已算 `bytes = dead × cell_size`（:170-186）、`snapshotAllDoomed/YoungDoomed`、`Heap.stats.live_bytes`、`verifyBlockAllocCount`（:1561）。阈值逻辑全部只依赖 `allocated_bytes` 标量（runtime.zig:3158/3250/3316、memory.zig:1946/1960、gc.zig:3532）→ 块级化后阈值逻辑不改；校验臂 gc.zig:4819-4884（`HeapLiveBytesMismatch`）需同步口径。

### 1.7 弱语义
`Object.weakref_count: u32` 与 `slots2_layout_bit` **同字**（object.zig:457-497）；husk：`setHeaderWeakHusk` gc.zig:894-910 / `headerIsHusk` :882，生成 object.zig:2528、object_gc.zig:37，消费 object.zig:2377、runtime.zig:2756/2800、`destroyDeadWeakHusk` :2619。`keyIsMarked`（gc_trace_stw.zig:2729-2740）骨架完整（symbol 走 S3 的 body mark，object 走 `headerMarked`）；`processWeak` :2005-2021 → `sweepHolder` :2023-2091 已按 mark 清 WeakRef 槽 / WeakMap entries / FR cells；`ephemeronFixedPoint` :1978-2003 按 mark。**差**：① `releaseWeakIdentity` 身份侧表仍计数式；② 未被 mark 的 holder 的 cells 由 `FinalizationRegistryPayload.destroy` 兜底——删析构后要在 sweep 期显式处理。

## 2. 设计

### 2.1 头部（S4-a）

`BlockFlags(u8)` → `kind: RefKind(u4) | young | needs_finalizer | finalizing | reserved`。
- `RefKind(u4)`：0 object, 1 function_bytecode, 2 var_ref, 3 realm_context, 4 module, 5 shape, 6 string, 7 big_int（不变），**新增 8 property_storage, 9 array_storage, 10 payload, 11 rope**。rope 从 `flags.mark` 借位改为独立 kind（D-S4-1）：`metaIsRope` → `kind == .rope`；`allocRopeNode` 写 kind；S2 的「块 cell ⇒ object|string」守卫改为 `kindIsBlockCellKind()`（object/string/rope/property_storage/array_storage/payload）；`traceHeaderEdges` 的 `.string` 臂拆成 `.string`（无边）与 `.rope`（left/right）；`liveCountKind(.string)`/`heapByteSizeFromHeader`/`--gc-stats` string 行按 `isStringFamily(kind)` 合并统计。catalog（gc.zig:444-453）、`gc_representation_constants.zig`、memory.zig 三处裸字节前缀写（`initGcPrefix`、`createStringExtent :1867` 改为通用 `createExtent(kind)`）、`gc-representation-trace-snapshot.txt` 重生成、`gc.zig:691-696` 位序断言同步。
- `mark` 位删除：块 cell 权威已是位图，非块 kind 用 `mark_epoch`（gc.zig:3323），extent 表 `mark_epoch`；10 处读写点改：object.zig:2330/2389/2530/2622 与 object_gc.zig:32 随析构删除，gc.zig:1349/2325 断言改位图查询，gc_representation.zig:139 改。
- `is_pinned` 与 `cycle_visited` 的删除**推迟到 S4-e**（依赖 S4-d 删掉 unlink/park 机器后读点自然消失）；S4-a 只把 `needs_finalizer` 放进原 `mark` 位的位置，`reserved` 留 1 位。
- **块级第 4 张位图** `Block.finalizer_bits`（与 alloc/mark/doomed 同宽）：`Registry.setNeedsFinalizer(header)` 置 Metadata 位 + 块位图位；cell 释放时清。extent：表项 `needs_finalizer: bool`。非块 kind（shape/module/realm/FB/var_ref/big_int）保持现有析构路径（它们本就非块，不在本期目标）。

### 2.2 存储 cell（S4-b）

- 分配漏斗：`memory.createStorageCell(kind, byte_count)`：`gc_block_heap.canAllocCellSize(8 + bytes)` → 块 cell（S2-f 后小类到 3760B，即 ≈230 个 `Entry`/`JSValue`）；否则 → `createExtent(kind, bytes)`（把 `createStringExtent` 泛化：前缀 kind 字节参数化、`young_extents` 与 `extent_pages` 逻辑不变、`Heap.sweepStringExtents` 泛化为 `sweepExtents(epoch, ctx, destroy_by_kind)`：`.string` 走现有握手回调，存储 kind 走纯 `Heap.free` + `recordHeapFreeWithBytes`）。返回 body 指针（Metadata 在 body−8，与 Object/string 同约定）；发布 `addInitializedWithSizeNoFail`（cold arm 对 standalone 进地址注册表；`publishInitialized` 对非 object kind 跳过链表——S2 已有 `kind != .string` 判断改为 `!kindHasTraceHeaderLink(kind)`）。
- **属性存储**：`prop_values` 指向 cell body（`[*]property.Entry` 语义不变，`@offsetOf == 16` 不变）。改点：构造 4 处 `allocRuntime(Entry, cap)` → `createStorageCell(.property_storage, cap*@sizeOf(Entry))`；增长 2 处同（新 cell 拷贝后**不 free 老 cell**——老 cell 无引用后由 sweep 回收；errdefer 回滚只需恢复指针，不再需要 :10062-10073 的内联回拷？——仍需：回滚要把 `prop_values` 指回内联 tail，保留但去掉 free）；释放 5 处删除（`compactPropertyLayout` shape.zig:909 的 free 删除；压回内联分支不变）；`propertyStoragePointerIsExternal` 语义不变。**owner 边**：`Object.traceChildEdgesFallible`（object.zig:6839）在遍历属性值之前 `visitor.storageCell(prop_values)` = `shadeExactNoPush(header)`（cell 无自有边，内容由 owner 的属性遍历覆盖；`markOrdinaryObjectHot`/`markFastArrayHot` 热臂同步——热臂/权威/comptime 列表三处同步的守卫已有）。**屏障**：新 cell 安装进已发布 owner 的两处增长点与压缩点调用 `rt.gc.rememberOwnerForBulkWrite(owner)`（老 owner → 年轻 cell）；owner 上的值屏障不变（remembered owner 重追时连带标记 cell）。**保守根**：native 局部 `[*]Entry` 经块几何 `cellIndexInterior`/extent 探测解析到 cell 自身（只保活 cell 不保活 owner，语义足够）。gc.zig:3068-3098 布局审计改按 kind 读 cell 头。
- **数组元素**：`arrayArm().values` 指向 `.array_storage` cell body；`ensureArrayBufferCapacity` 的 remap 臂删除（新 cell + memcpy，老 cell 留给 sweep）；adopt 2 处：外部已分配 slice 来自 `rt.memory.alloc`（string_ops 的 match 数组、arguments 建立）→ 改为调用方直接 `createStorageCell` 分配再 adopt（adopt 只改指针 + `rememberOwnerForBulkWrite` 保持）；`mapped_arguments` 的 `?*VarRef` 表：同一 `.array_storage` cell，owner 的 trace 按 class 分派解释（现状逻辑不变）；释放 4 处删除，`destroyArrayElements` 只剩 fast_array 位清零→随析构删除。TypedArray/ArrayBuffer 不动（b 类）。

### 2.3 a 类 payload cell（S4-c）

11 种 a 类 payload → `.payload` cell（D-S4-2：**不内联**进 64B Object——ordinary ≈360B 内联会毁 M 终态；regexp 16B 已内联进 `regexpArm`，保持）。改点：各 payload 的 `create*Payload` 由 `allocRuntime` 改 `createStorageCell(.payload, @sizeOf(T))`，`destroy*Payload` 删除（`ordinary` 的 `slots2_payloads` 侧表先消：侧表存在是为了 slots2 对象析构时找 payload——无析构后不需要；查其读点是否只在析构/审计）。owner 边：`Object.traceChildEdgesFallible` 的 payload 分派前 `visitor.storageCell(payload_ptr)`，payload 内容的 `traceChildEdges` 不变（含 S3 的 `callVisitAtom`：owner 仍是 Object，挂载点不变）。payload 内的从属分配（promise reactions slice、bound args、disposable resources、arguments var_refs、FunctionRare aux）：**同批**改成从属 `.payload` cell（各自由 payload 的 trace 边 `storageCell` 标记）或内联 FAM 进 payload cell（尺寸小且定长者内联；规格执行时按 `@sizeOf` 快照定）。b/c 类 payload 不动（仍 `allocRuntime`，由 finalizer 释放）。

### 2.4 `needs_finalizer` 与 sweep（S4-d）

- 置位点（构造时）：b/c 类 payload 的 `create*Payload`（buffer/typed_array/std_file/realm_record/function native 臂/iterator/collection/weak_ref/finalization_registry/generator）；dynamic class 且 `has_payload_finalizer`（class.zig:288-292）或 `class_id >= init_count`（需 `releaseObjectDefinition`）；`registerBorrowedReferenceHolder`（借用身份）；`assignWeakObjectIdentity`（`has_weak_id`，S4-e 前）；`registerWeakReferenceHolder`；string cell 绑定 atom（`cacheString`/`ensureSymbolBody`/`createAtomBacked` 写 `atom_id` 时）——未绑定的 flat/rope 走位图直回收，rope 的 tail 缓冲随 S2 已删。**规则**：位只增不减（一次置位终身有效，简单且安全；解绑后多付一次析构调用而已）。
- sweep：`destroyDoomedSlice` 块段改为 `for block in doomed_blocks: fin = doomed ∧ finalizer_bits; for cell in fin: destroyByKind(header)`；`doomed ∧ ¬finalizer` 的 cell **不摸头**，由 `Block.reclaimDoomed()` 批量 `alloc &= ¬doomed`（S2 的 `takeDoomedCell` 保留给 fin 集合）。`.object` 的 `destroyFromHeader` 收缩为只剩 1.1 里「必须保留」的步骤（weak holder / borrowed / std_file / class finalizer / husk（S4-e 前）/ weak id / releaseObjectDefinition / `shapes.dropUnshared` / `clearCachedIteratorNext`）+ b/c payload destroy；快臂 `destroyPlainObjectFast` 整体删除（普通对象永远不进 fin 集合）。extent：`sweepExtents` 对 `needs_finalizer` 表项走回调，否则直接 free。
- 计账：`Registry` 在 `snapshotAllDoomed/YoungDoomed` 后用 `DoomedSnapshot.bytes` 直接 `allocated_bytes -= bytes`（memory.zig 新 `debitBlockBytes`），删 `debitBlockCellPayload`（Pass A）与 `unregisterObjectWithBytes` 的逐对象 debit；fin 集合的析构不再单独减账（已含在块级）；extent 释放仍逐条 `recordHeapFreeWithBytes`（稀少）。校验臂 gc.zig:4819-4884 按块级口径重写。`shapes.dropUnshared` 仍逐对象——但只对 fin 集合调用 → **普通对象死亡不再 drop shape**：shape 的活性改由 shape 自身的 mark 决定（S1 已是 tracer-owned，`dropUnshared` 只是 COW 唯一性提示 + hash 表 unlink 的提前量；查 `dropUnshared` 在无析构下是否有正确性依赖——若 shape hash 表 unlink 只在 shape 自己的析构做，则可删）。
- 删除：object.zig:2280-2617 中的快臂、Pass A 调用、husk 生成（S4-e 前保留）；object_gc.zig 的 settle/drain（:68-185）；gc.zig `DeferredFreeStack`（:1114-1150/:1548/:1687-1730/:3033-3050）；gc_block_heap.zig settle 路径（:1498-1560、`passa_settled_cells`）；gc_trace_stw.zig `doomedStateSnapshot`（:1258-1305）；corpse census；`--gc-stats` 相关行与 `gc_stats_snapshot.py` 解析（可选正则）。**deletion-probe**：`destroyFromHeader` 入口计数器 `gc.stats.object_destructor_calls`，`--gc-stats` 输出；门要求 Octane 全套上「class_id==object 且无 fin 位」计数 = 0。

### 2.5 弱语义按 mark（S4-e）

- `weakref_count` 删除（与 `slots2_layout_bit` 同字：先把 layout 位搬到 `Object.flags` 的空位，一次布局裁决）；WeakRef 目标不再计数，`weak_ref` payload 持 `weak_target_identity`（现状）；`processWeak/sweepHolder` 已按 mark 清槽；husk 全链删除（gc.zig:882-910、object.zig:2377/2528-2532/2619、object_gc.zig:25-41、runtime.zig:2756/2800）：目标死亡后其 identity 在 sweep 期由 `takeWeakObjectIdentity` 归还（fin 集合，`has_weak_id` 置 fin 位），WeakRef 侧只持 identity token，不再需要尸体。
- FR：未被 mark 的 registry 自身进 fin 集合（c 类），其 cells 的 `releaseWeakIdentity` + job 预留归还在 finalizer 做（现状）；被 mark 的 registry 的 cells 在 `processWeak` 按 mark 清（现状）。
- `is_pinned` → `pin_entries` 表：条件 condemnation 前构建一次 `pinned_set`（hash，m 条），11 个读点改 `pinned_set.contains(header)`；`cycle_visited` → 块 cell 用 doomed 位图，非块 object 用 `nonblock_objects.doomed`；`unlinkObjectWithBytes`/`recordDetachedHeapFreeWithBytes` 随 S4-d 删除后读点消失。位序最终 `kind:u4 | young | needs_finalizer | finalizing | reserved`。

## 3. owner 决策点

| ID | 决策 | driver 建议 |
|---|---|---|
| D-S4-1 | rope 判别：独立 kind `.rope` / 保留 flags 借位 | **独立 kind**（u4 有余量；`traceHeaderEdges` 直接分派；去掉 mark 位借用） |
| D-S4-2 | a 类 payload：cell / 内联进 Object | **cell**（ordinary ≈360B，内联毁 64B 终态；regexp 16B 已内联维持） |
| D-S4-3 | 大存储（>3760B）载体：复用 string extent 路径泛化 / 新建 | **泛化 extent**（表已有 kind 字节，`young_extents`/页索引/sweep 全复用） |
| D-S4-4 | `needs_finalizer` 一次置位终身有效 / 可清 | **终身有效**（解绑场景稀少，可清需要精确配对，得不偿失） |
| D-S4-5 | 弱语义（S4-e）时序：与 S4-d 同批 / 之后 | **之后**（husk 依赖析构存在；先让普通对象零析构并出 Stage 0，再动弱链） |

## 4. 分批与门

| 批 | 内容 | 门 |
|---|---|---|
| S4-a | 2.1：kind u4 + `.rope` + `needs_finalizer` 位 + 块级 finalizer 位图 + mark 位删除 + catalog/快照/前缀写点；行为零变化 | test；快照重生成；`zig build test-gc-stress` 一次 |
| S4-b | 2.2：`createStorageCell`/`createExtent(kind)`/`sweepExtents` 泛化；prop_values 与数组元素入 cell（释放点先保留为 no-op 以便分步）；owner `storageCell` 边 + 热臂同步 + 屏障 | test；Stage 0 快筛（对象分配路径 codegen 对照 `allocCellFixedPtr` 反汇编） |
| S4-c | 2.3：a 类 payload cell + 从属分配 | test |
| S4-d | 2.4：fin 位置位点、sweep 只遍历 fin、块级计账、删除析构机器与 Pass A/B、deletion-probe | test / stress / test262 / **Octane deletion-probe = 0** / Stage 0 |
| S4-e | 2.5：弱语义按 mark、husk 删除、`weakref_count` 与 layout 位裁决、`is_pinned`/`cycle_visited` 删除、位序终态 | test / stress / test262（WeakRef/FR 子集重点）/ Stage 0 |

规模（勘察估计）：S4-a ~150 行 + 全仓断言；S4-b ~350；S4-c ~300；S4-d ~120 新增 + 净删 ~800-900；S4-e ~250。

## 5. 与 S2/S3 的耦合（执行时必核）

1. rope 判别位搬家（2.1）先于删 mark 位。
2. string cell 的「轻析构」（atom 握手）用 fin 位表达：只有 `atom_id` 绑定的 body 进 fin 集合，其余 flat/rope 位图直回收。
3. extent 泛化后 `young_extents`、`extent_pages`、one-past-end 双访问、`extentIsMarked` 哨兵（S2-e）逻辑对所有 kind 一致。
4. `ValueRootFrame`：构造中的裸 cell 指针（新 cell 已分配、尚未装进 owner）靠保守扫描解析到 cell 自身即可（cell 无出边，内容尚未有效）；不需要 `headers` 根。
5. `slots2_layout_bit` 与 `weakref_count` 同字：S4-b（内联 tail 判定不变，不动该字）与 S4-e（删计数）分开，S4-e 一次裁决。
6. 阈值与 S2-g 的「越线先 minor」：块级计账让 `allocated_bytes` 在 minor 后立即反映位图回收量，二次判定更准确；`minor_crossing_young_floor` 重新记账。

## 6. 风险

- fin 位漏置 = 外部资源泄漏或弱语义错误（不是 UAF）：用 Debug 断言「进入任何 b/c destroy 的对象必带 fin 位」+ 反向「fin 集合里 `class_id==object` 且无 payload 的对象 = 0」双向审计。
- 存储 cell 与 owner 的年龄错配：老 owner 持年轻 cell 只靠增长/压缩三处屏障；`ZJS_MINOR_AUDIT` 已能报未记忆边（S2-g 回归的经验），S4-b 门必须带 stress。
- 块级计账与 extent/非块 kind 的逐条计账并存，`HeapLiveBytesMismatch` 校验臂重写要覆盖三种口径。

## 7. 执行记录

- **S4-a（2026-09-05 凌晨，`s4-a-20260905` = 48c4181a / df9acf73 / 2700de37）**：`RefKind` u3→u4（+ property_storage 8 / array_storage 9 / payload 10 / rope 11），`BlockFlags` 删 `mark`（young/finalizing/is_pinned/cycle_visited 位置不变），新增 `isStringFamily`/`kindIsBlockCellKind`，`metaIsRope → kind == .rope`，`createStringCell(comptime kind_tag, …)` 参数化裸前缀字节，`traceHeaderEdges` 拆 `.string`（叶）/`.rope`（left/right），`--gc-stats` 把 rope 折进 string 项；第四张位图 `Block.finalizerBits`（偏移派生，`Block` 仍 112B；64B 类 1016→1014 cell）+ extent `needs_finalizer` 列 + `Registry.setNeedsFinalizer/headerNeedsFinalizer`。`kind == .string` 逐点分类：家族判定 6 处、块 cell 集合 5 处、extent 臂 5 处保持 `== .string`（rope 永远是 cell）。反汇编：`allocCellFixedPtr` 278→278 逐条相同；`shadeExact`/`destroyDoomedSlice` 仅掩码常量 `0x7→0xf`；`traceHeader` 少 15 条（块 cell 的 object 判定变 `ands #0xf` 单指令）。门 test 2534/0、stress 2530/0、快照重生成。**偏离**：`needs_finalizer` 暂放 `Metadata.lifetime.flags`（byte 7，`reserved u7→u6`），因 `is_pinned/cycle_visited` 未删、flags 字节 9 位装不下——S4-e 删两位后搬回 flags 字节；kind 加宽/rope kind/mark 删除三者原子（一个 commit）。未决：`setNeedsFinalizer` 的 extent 分支只认 string 家族（S4-b 开放 storage extent 时扩）；`tools/perf/verify/test_gc_stats_snapshot.py` 7 个先存在的失败。
- **S4-b（2026-09-05 上午，`s4-b-20260905` 三 commit，已 apply 进主树）**：kind 8/9 tag 常量；`Registry.createStorageCellPublished`（唯一漏斗）/ `destroyStorageCell`（块 cell 字节数取 `Block.cell_size`，storage cell 不自描述）；`heapByteSizeFromHeader` 8/9 臂；两处块 cell 析构 switch 加 storage 臂（纯归还）；`string.destroyCellFromHeader/destroyDeadStringExtent` 加纯内存臂（teardown 走 `kindIsPrefixCarrier`）。属性：`Object.createPropertyStorageCell`，构造 4 处（**铸造点移到对象 `allocCell` 紧邻之前**）、增长 2 处（新 cell 不 free 老 cell，`ensurePropertyCapacity` 把 install 提到会分配的 `reserveProperties` 之前）、释放 5 处删（析构只剩 `setPropertyStorageEmptyForDestroy`）、`shape.compactProperties` 用漏斗 + `rememberOwnerForBulkWrite`；owner 边 `tracePropertyEdgesFallible` 顶部 `storageCell(prop_values)`（唯一分派，无独立热臂）；`verifyObjectPropertyStorageLayouts` 按 kind 审计。数组：`createArrayStorageCell/Slice`，`ensureArrayBufferCapacity` 删 remap 臂，adopt 7 调用点中 6 改调用方铸 cell，**例外** `initRegExpMatchArrayDenseElementsFromValue` 保留 native 暂存（填充循环每步分配，裸 cell 无精确根）；`allocateMappedArgumentsVarRefsAssumingEmpty` 同 kind。**规格外真缺陷**：§5(4)「构造中裸 cell 靠保守扫描即可」在 `forcePreciseRootScanForTest` 下不成立（属性 cell 铸在 `collectBeforeObjectAllocation` 之前即被回收）→ **铸造与安装必须相邻**（写进 `createPropertyStorageCell` 文档）。期望值搬迁两类：回收计数含 buffer（常量 5→7 等，gc-stats 快照加 `externalPropertyStorageBytes`）；11 个内存上限测试因 `allocated_bytes` 在两次 GC 之间携带可回收垃圾而改用保守口径先扫——**语义变化**：缓冲参与压力回收但抬高水位，阈值逻辑只看标量未改（S4-d 块级计账消解）。门 test 2549/0、stress 2545/0（含 `ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal`）。未触及 `slots2_payloads`/`weakref_count` 同字（S4-c/e）；`setNeedsFinalizer` extent 分支经 `kindIsExtentCapable` 自动含 8/9（S4-a 未决闭合）；`.payload` 仍 unreachable（S4-c）。
- **S4-c（2026-09-05 下午，`s4-c-20260905` 四 commit `bf20b77b` / `f5a1334c` / `e38de5fc` / `a447cc8e`）**：`@sizeOf` 快照（Debug/aarch64）ordinary **360** / arguments 16 / object_data 24 / bound_function 64 / proxy 48 / var_ref 32 / promise **104** / disposable_stack **104** / global **8** / regexp 16 / FunctionRare **328** / BytecodeFunctionAux **336**（b/c 参照：function 56、iterator 240、collection 104、buffer 128、typed_array 88、weak_ref 40、FR 80、std_file 16）——§1.4 的 promise≈112 / global≈16 / rare≈300 三处估算修正，全部远低于 3760B 小类上限，**没有 extent 臂**。`payload_kind_tag = 10`；`heapByteSizeFromHeader` 与 8/9 同臂；两处块 cell 析构 switch + `verifyCellsAllowing` 前缀白名单加 10。铸造漏斗 `Object.mintPayloadCell / createPayloadCell / allocClassPayloadCell`；`createInternal` 把 a 类 payload 的铸造推迟到属性 cell 之后、`allocCell` 之前，并**把两个 cell 的 `requestGCForAllocation` 全部提到第一次铸造之前**（两个裸 cell 同时在手时，第二次压力请求会扫掉第一个）；`allocClassPayload` 的 a 类臂改 `unreachable`。owner 边=`traceChildEdgesFallible` 在 payload 分派前一次 `storageCell(payload)`（bytecode 臂另加 `storageCell(aux)`），cell 本身仍是叶。释放：析构 switch / `freeClassPayloadAllocation` / `destroyDetachedClassPayload` 的 a 类臂不再归还分配（内容释放暂留，S4-d 删）；`destroyFromHeader` 快臂门 `.none → .none ∨ a 类`。从属分配四条（promise reactions、bound args、disposable resources、arguments var_refs）改从属 `.payload` cell + payload 自身 `storageCell` 边 + 增长点 `rememberOwnerForBulkWrite`，老 cell 留给 sweep。**侧表**：`rt.slots2_payloads` 不是只在析构用（`payloadSlot`/`payloadValueConst` 是活读点），故按 brief 的备选方案执行——slots2 对象挂 payload 前先把两个内联属性槽**溢出**到 `.property_storage` cell，body+24 的臂字恢复为统一 payload 槽；新不变式「slots2 ∧ payload ⇒ 属性非内联」由 `verifyObjectPropertyStorageLayouts` 审计，`Shape.compactProperties` 拒绝把带 payload 的对象压回内联；侧表与三个审计错误删除，`slots2_payload_attach_count` 留作溢出观测量；21 个只转发 `rt` 的 error-stack/promise 访问器随之去参。测试四条（每类 a payload 的 major 回落 / bytecode aux / 老 promise 的 reactions minor 屏障 / 三条从属切片跨 major），首条已用删除探针验证（去掉 owner 边即红）。收尾补丁（`f2249516`）：`string.destroyCellFromHeader`（teardown 前缀载体漏斗）与 `destroyDeadStringExtent`（extent sweep 回调）都缺 `.payload` 臂——`kindIsPrefixCarrier` 自 S4-a 起就含 10，缺臂不是泄漏而是**把 payload 当 `String` 读**；实测门看不见是因为 teardown 前的 major 已把 payload cell 随 owner 收走，但漏斗契约不能靠这个时序论证。同批加 extent 路径测试（payload 结构最大 360B 永远进块 cell，**只有从属切片**能越 3760B 上限，用 400 个 bound arg 触发）。门：`zig build test` **2554/0**、`zig build test-gc-stress` **2550/0**（含 `ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal`）、ReleaseFast 构建通过。**未做（S4-d 前置）**：bytecode capture 数组 `bytecodeArm().var_refs` 仍是裸分配、仍由 `destroyFunctionPayload` 归还（`.function` 的 native 臂是 b 类，析构还在，故不漏）；`ArgumentsPayload.var_refs` 生产侧无写点（只有测试夹具）；`weakref_count`/`slots2_layout_bit` 同字**未触及**（本批只读 `hasSlots2Layout`，S4-e 一次裁决）。
- **S4-c（2026-09-05 中午，`s4-c-20260905` = bf20b77b..58c06158 六 commit，已 apply 进主树）**：`@sizeOf` 快照修正 §1.4（promise 104、global 8、rare 328、aux 336；ordinary 360）——**没有 payload 结构走 extent**，只有从属切片能触发（400 个 bound arg 测试）。处置：ordinary/arguments/object_data/bound_function/proxy/var_ref/promise/disposable_stack/global/function-bytecode 臂 → `.payload` cell；regexp 内联维持（动态类外挂臂 → cell）；b/c 类不动；从属 promise reactions / bound args / disposable resources / arguments var_refs → 从属 `.payload` cell + payload 自身 `storageCell` 边 + 增长点 `rememberOwnerForBulkWrite`（内联 FAM 一个没用，四条全变长）。**约束**：`createInternal` 两裸 cell 同时在手 → 两次 `requestGCForAllocation` 全部提到首次铸造之前；`allocClassPayload` a 类臂 `unreachable`。**侧表方案**：`slots2_payloads` 有活读点（`payloadSlot/payloadValueConst`）不能删 → slots2 对象挂 payload 前先把两个内联属性槽溢出到 `.property_storage` cell（`spillInlinePropertyStorageForPayload`），body+24 恢复为统一 payload 槽；新不变式「slots2 ∧ payload ⇒ 属性非内联」入 `verifyObjectPropertyStorageLayouts`，`Shape.compactProperties` 拒绝把带 payload 的对象压回内联；侧表与三个审计错误删除，21 个转发 `rt` 的访问器去参。**规格外真缺陷**：`string.destroyCellFromHeader`（teardown 漏斗）与 `destroyDeadStringExtent` 缺 `.payload` 臂——把 payload 当 `String` 读（门看不见是因为 teardown 前 major 已收走，时序论证不成立），已修。门 test 2554/0、stress 2550/0。未决：**bytecode capture 数组 `bytecodeArm().var_refs` 未转 cell（S4-d 删 `destroyFunctionPayload` 前必须先转）**；`ArgumentsPayload.var_refs` 生产无写点（死字段）；a 类 `destroy*Payload` 只剩清值（S4-d 删）；`weakref_count/slots2_layout_bit` 同字未触及。
