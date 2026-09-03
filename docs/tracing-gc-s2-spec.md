# TGC S2 规格：string 家族入 tracer

状态：v0.1 草案（driver，2026-09-03 夜，S1 整期门通过后起草）；上游 `docs/tracing-gc-completion-plan.md` §3 S2、§8 D5（owner 批：块 cell 载体）。
基线：main（S1 合入后）。分支 `gc/tgc-s2-*`。

## 0. 目标

flat string / rope / symbol body 三种载体由 tracer 持有：块 cell（≤120B 载荷）或 medium/large extent，mark 位图活性，位图 sweep，**无析构**（symbol body 的 atom 表握手改为 sweep 期弱处理，见 §4）。`JSValue.dup/free` 对 string tag 变 no-op（S3 再删）。

## 1. 事实（只读勘察 2026-09-03，均已对当时 HEAD 核实）

### 1.1 表示

- flat `String`（string.zig:245）：`[rc 4B][String 12B][char FAM]`，`@sizeOf(String)=12/@alignOf=4`；`len_meta{len:u31,is_wide}`、`hash_meta{hash:u30,atom_type:u2}`、`atom_id:u32`（弱回指 atom 表）；latin1 尾随 NUL；总大小 = 16+len（latin1）或 16+2·len（utf16）→ ≤111 latin1 / ≤55 utf16 单元可进 128B 小类。`header()`=ptr−4（:283）。
- `StringRope`（:44）：`left/right: JSValue @0/@16, rt @32, len:u32 @40, depth:u8, wide, flags`，`@sizeOf=48/@alignOf=8`；**rc 前缀已是 8B**（:90，rc 在后 4B）；可选尾槽 `?*RopeTailState`（flags&1）；节点 56B / 累加器 64B，均可进小类。
- symbol body = flat `String` 经 `Tag.symbol`；`AtomTable.ensureSymbolBody`（atom.zig:1678）用 `createUtf8`/`createSymbolNoDescription`（string.zig:369）。
- gc.zig：`RefCountHeader{rc:i32}`（:957）、`StringHeader = RefCountHeader`（:971）、`string_rc_prefix_size=4`；`Metadata` 8B 的 `lifetime` 字恰在 payload−4（:986-990 断言）——**换 8B 前缀后 rope 只改解释，flat string 前缀 4→8**。
- 三种载体今天只靠 JSValue tag 区分；`GcKind.string` 不分 flat/rope（gc.zig:460）。

### 1.2 分配

- flat 单漏斗 `String.createUninitialized`（string.zig:849）→ `rt.allocStringAlignedBytes`（runtime.zig:1819）→ `MemoryAccount.allocAlignedBytesNoTrigger`（memory.zig:1072）：裸 slab，无前缀、无发布、无地址注册；释放 `destroyFlat`（:872）→ `freeAlignedBytes`。**字符串分配绕过 GC 触发阈值**（runtime.zig:1812-1818，测试/force 模式除外）。
- rope：`allocRopeNode`（:1481）同一路径，对齐 8；`freeRopeNode`（:1491）；rope tail 缓冲走 `allocRuntime`。
- 无 size class；块堆小类 {16..128 步 16}（gc_space.zig:105），载荷上限 120B；`large_min_bytes=64KiB`，medium=(128,64Ki)；`Heap.alloc`（gc_block_heap.zig:711）可分 medium（:2411 页段位图）/large（:2463），**medium 目前零调用者**。
- 非 Object kind 不能进块 cell 的三处守卫：memory.zig:1432/1657（comptime kind==object）、gc_trace_stw.zig:70-71（block cell ⇒ object）、gc.zig:485/508-509（catalog：block 载体 iff object，string_family iff string）。

### 1.3 rc 站点

string.zig 内 14；atom.zig **19**（含 symbol body rc 与 atom entry 计数互转：`strongRefCount` :896、`ensureSymbolBody` 转移 :1712、`retainValueSymbolEntry` :1876、`free` :1359、`symbolBodyIfLive` 用 `rc==0` 作弱活性 :1664、`onSymbolBodyZeroRef` :1642、`finalizeDeadEntry` :1835）；exec/value_ops.zig 5（**:883/:985 用 `rc==1` 做 rope 原地追加/累加器**，:1130 `rc>max` bail）；value.zig 7（dup/free/destroyZeroRef :702-703 等）；tailcall_dispatch.zig 2（:5901/:5940）；测试 15。通用 `JSValue.dup/free`：1190/7826 处。

### 1.4 追踪现状

`cycleMarkHeader`/`isTracerOwned` 排除 string tag；`traceHeaderEdges` `.string => return`；`visitValue` 静默丢弃 string；**rope 的 left/right 无人访问**；保守解析器对 string 分配一无所知（地址注册表零 string 记录，arena 走查以 `heap_accounted` 为门）。`refCountRemoved(.string)=false` 是唯一 false；`frontierEpochSafe(.string)=false`；`traceRememberedCacheEligible = kind != .string`。

### 1.5 atom 耦合

- `DynamicAtom.str` 强引用（atom.zig:877）；`predefined_str[]` 各持 1 ref（:1062）；shape 只持 atom（`atoms.dup/free`，shape.zig 8 处），**string atom 的 body 由 entry.str 保活，symbol atom 由 body rc 承载 entry 计数**。
- runtime.deinit：`releaseCachedStrings`（runtime.zig:1367）在 gc.deinit 前；`releaseValueSymbolBodiesAfterGc`（:1383）在后（强制 `rc=1` 再 release）。
- 转换函数：`AtomTable.dup/free/name/refCount/replace/internString/toStringValue/toStringValueForPush/cachedString/cacheString/symbolValue/takeSymbolValue/symbolValueIfLive/symbolBodyIfLive/ensureSymbolBody/onSymbolBodyZeroRef/symbolDescription/internDynamic/finalizeDeadEntry/freeAtomList`；`String.internAtom`（string.zig:410）、`createAtomBacked`（:377）。`atoms.dup` 228 / `atoms.free` 1458 处。

### 1.6 缓存与身份

runtime.zig 六个 +1 缓存（`single_byte_strings[128]` :1362、`empty_string` :1365、`recent_two_unit_string` :1371、`recent_atom_strings[4]` :1375、`percent_hex_strings[256]` :1380、`small_int_strings[256]` :1382）= S2 根集；atom 表 `atom_hash` 链 + `predefined_string_hash_table`；`DynamicAtom.weakref_count`（WeakRef/WeakMap on symbol）；指针身份比较：property_direct.zig 15 处 fast path、tailcall_dispatch.zig 4678/4724、atom.zig 1648/1841、tests 2 处。GC 对象内裸 `*String`：仅 `RegExpPayload.source/compiled_bytecode`（object_payloads.zig:718-719，`traceChildEdges` 为 no-op）。

## 2. 分批（草案，待 S1 合入后细化到函数级）

| 批 | 内容 |
|---|---|
| S2-a | 载体：flat/rope 前缀改 `gc.Metadata`（flat 4→8B；`header()/fromHeader()/inlineAllocationLayout/destroyFlat/freeRopeNode` 五处），`BlockFlags` 借一位区分 rope；三处「非 object 不进块 cell」守卫放开为 `.object/.string`；分配漏斗改 `Heap.allocCell`（≤128B）/ `allocMedium` / `allocLarge`（首个 medium 调用者），发布进位图与地址注册表；`heapByteSizeFromHeader` string 臂 |
| S2-b | 追踪：`cycleMarkHeader/isTracerOwned` 区间扩到 `[symbol..object] ∪ big_int`（tag −8..−1 连续！只需一次比较 `tag >= Tag.symbol`）；`traceHeaderEdges` rope 臂访问 left/right；`RegExpPayload.traceChildEdges` 访问两个 `*String`；六个 runtime 缓存 + atom 表 `str`/`predefined_str` 作 root provider（S3 前 atom 表保持强根）；`JSValue.dup/free` string 臂 no-op；value_ops `rc==1` 原地 rope 追加改用「young 且未共享」判据或删除（记账决定） |
| S2-c | 死亡：位图 sweep；symbol body 的 atom 握手改为 sweep 期弱处理（`symbolBodyIfLive` 读 mark 位；`onSymbolBodyZeroRef` 由 `processWeak` 阶段对未标记 body 调用）；runtime.deinit 两处 release 改为 deinit 清扫；`--gc-stats` string 行 |
| S2-d | 删除：`RefCountHeader/StringHeader/string_rc_prefix_size/refCountHeaderFromPayload`、`gc.release` 的 StringHeader 臂、`String.retain/releaseFromHeader/destroyFromHeader` 与 `destroyRope` 的 rc 部分、`refCountRemoved` 恒 true → 删函数；测试 15 处 |

门：每批 test+stress；整期 test262 script、roots_diag、Stage 0（string 密集：regexp/splay/pdfjs 重点）。

## 3. 风险

- 字符串分配进块堆后受 GC 触发阈值管辖（今天绕过）——minor 频次会变，需 Stage 0 记账 `minor collections` 行。
- 大字符串（>64KiB）走 large extent：`large` map 与 `--gc-stats` 的 large 行语义。
- rope 原地追加优化（`+=` 循环）依赖 rc==1；无 rc 后需替代判据，否则 string-concat 基准退化。

## 4. S2-a1 规格与执行（2026-09-03 夜）

**目标**：string 家族的分配前缀从 4B rc 字变为 8B `gc.Metadata`（kind=`.string`，rc 仍在 lifetime 尾字 payload−4），不改活性、不改追踪；让 rope/flat 与所有 GC kind 同构，为 S2-a2（块 cell 载体）铺路。

| 改点 | 内容 |
|---|---|
| gc.zig | `string_rc_prefix_size`(4) → `string_prefix_size = metadata_prefix_size`(8)；`representation_kind_catalog` `.string .prefix = .metadata`；catalog 断言改为「所有 kind prefix==metadata」（`.string_rc` 枚举保留仅作历史注释） |
| string.zig | `String.header()/fromHeader()` 与 `StringRope.header()/fromHeader()` 改用 `ref_count_offset_from_payload`（payload−4，语义不变）；新增 `metadata()`（base−8）；`createUninitialized`/`allocRopeNode` 用 `string_prefix_init`（kind string、rc 1）初始化整个前缀；`destroyFlat` 从 `metadata()` 起释放；`inlineAllocationLayout` 总长 +4 且**分配对齐 4→8**（Metadata 对齐）；comptime 断言同步 |
| tests/core.zig | 手工布局用例改为 8B 前缀 + `metadata()` 初始化 |
| gc_representation.zig / 快照 | `rc_prefix=8`、`prefix=metadata` |

代价：每个 flat string +4B（rope 不变，其前缀本就 8B）；分配对齐 8（slab 类均 16 的倍数，无额外浪费）。门：子批 test+stress；Stage 0 归入 S2 整期。

## 5. S2-a2/b 函数级规格（string 活性切换到 tracer）

### 5.0 结论：a2（载体）与 b（追踪）必须同批切换

块 cell 的活性权威是 mark 位图：sweep 释放所有 `alloc & ~mark` 的 cell。string 一旦进块 cell，若 tracer 不标记它就会被清扫；反之 tracer 标记后，mutator 的 rc→0 即时释放对 frontier-safe kind 非法（标记队列裸指针悬空，`assertFrontierAllowsReclaimKind` 在安全构建直接 panic）。所以「进块 cell」「被标记」「rc 不再决定死亡」是同一个开关。落地策略：**comptime 开关 `gc.string_tracer_owned`（默认 false）**，所有改动先在开关下并存，两种构建各自过门后翻转默认值，再删 rc 分支（S2-d）。

### 5.1 载体（string.zig / memory.zig / gc_block_heap.zig）

| 函数 | 现状 | 开关为 true 时 |
|---|---|---|
| `String.createUninitialized`（string.zig:849） | `rt.allocStringAlignedBytes(total, 8)` 裸 slab，前缀 `string_prefix_init` | `total ≤ 128` → `rt.memory.createStringCell(total)`：`gc_object_cell_heap.allocCell(total)`（复用 Object 的块堆；cell 索引已由分配器戳入 bytes 0..2），`initGcPrefixBlockCell`（kind=.string），`creditAlloc(accountedBodyBytesForRequest(total, 8))`；`total > 128` → `Heap.alloc(total)`（medium/large）+ 标准 8B 前缀（`alloc_info.standalone=true`，`size_class=encodeHeapBytes`），首个 medium 调用者。两路都紧接 `rt.gc.addInitializedWithSizeNoFail(header?, bytes)`——注意 string 无 `gc.Header`（无 TraceHeader 链字），发布漏斗以 `*GCObjectHeader` 计 = payload 指针（String 结构体起点，Metadata 在其前 8B），与 Object 的 body 指针约定一致（§G：两者 Metadata 都在 payload−8） |
| `allocRopeNode`（:1481） | 同上，56/64B | 同上走 `allocCell`（永远小类） |
| `destroyFlat`/`freeRopeNode` | `freeAlignedBytes` | 仅 sweep 调用（见 5.3）；块 cell → `debitBlockCellPayload` + `heap.freeSmallCell(base)`；extent → `recordHeapFreeWithBytes` + `Heap.freeMedium/freeLarge`（补 `freeLarge`，现只有 `freeMedium`） |
| memory.zig:1432/1546/1657/1663/1781 `object_kind_tag` 守卫 | 只放 Object 进块 | 新增 `createStringCell/destroyStringCell` 专用入口，不改 `createInternal` 泛型路由（string 是变长 FAM，走不了 comptime 尺寸路径） |
| `Registry.publishInitialized` | block cell 隐含 object（`is_nonblock_object`、`tracked=isCycleCandidate`） | `isCycleCandidate(.string)=true`；block cell 且 kind≠object → 不进 nonBlockObjectAuthority、不 linkGcObjectTail（位图权威）；standalone extent string → `linkGcObjectTail`？**否**：string 无链字，extent string 必须由 `Heap.large/medium` 表枚举（新 `Heap.forEachExtent` 给 iterator/sweep），`isCycleCandidate(.string)` 仅用于块 cell；`GcObjectIterator` 加 extent 段 |
| `heapByteSizeFromHeader` `.string` | 0 | flat：`string_prefix_size + payload_offset + payload_size`（由 len_meta 重算，`inlineAllocationLayout`）；rope：56/64；块 cell 用 `accountedBodyBytesForRequest` |
| `verifyMetadataSemantics` | `.string_family ⇒ PrefixModelMismatch` | `.string` 走 `registry_published` 规则（block cell 或 standalone），`.detached_leaf` 仅开关关时 |
| 三处「block cell ⇒ object」断言 | gc_trace_stw.zig:69、gc.zig:508-509 catalog、memory.zig | 改为 `kind == .object or kind == .string`；catalog `.string .allocation = .block_slab_or_standalone`（`string_family` 枚举删除） |

### 5.2 追踪（value.zig / gc_trace_stw.zig / roots）

| 项 | 改法 |
|---|---|
| `cycleMarkHeader`/`isTracerOwned` | 区间下界 `Tag.module`→`Tag.symbol`（−8）：`[symbol, object]` 连续，仍单比较；`Tag.first` 不变 |
| `traceHeaderEdges` `.string` 臂 | flat/symbol body：无子边；rope：`visitValue(&left)`、`visitValue(&right)`（`RopeTailState` 的 `?*` 尾槽是 native 缓冲，不含 GC 边）。区分 flat/rope：`Metadata.flags` 借 `BlockFlags` 的 `mark` 位（块 cell 的 mark 权威是位图，此位对 string 空闲）→ 新 `flags.rope: bool`（重命名该位为 `kind_ext`），`string_prefix_init_rope` 置位 |
| `frontierEpochSafe(.string)=true`、`traceRememberedCacheEligible(.string)=true`（remembered 位要求 Metadata 前缀 ✔）、`refCountRemoved(.string)=true`（开关下） |
| `Collector.shade` 守卫 | string 走 frontier 路径（push） |
| `publishGreyCold`（gc.zig:4673） | `.string` 臂：`setHeaderMarked` + push（rope 有子边） |
| `MarkFootprint.noteMarkedHeader` | 已按 kind 计数 ✔；`beginTraceClass(.non_object)` ✔ |
| `auditCondemnedYoung`（gc_trace_stw.zig:2281） | `Object.fromHeader(child)` 前加 `kind==.object` 判断 |
| `RegExpPayload.traceChildEdges`（object_payloads.zig:729） | 访问 `source`、`compiled_bytecode` 两个 `*String`（`visitor.stringBody(...)` 新访问器 = `shadeExact(payload 指针)`） |
| 根 | runtime 六缓存（runtime.zig:1362-1382）→ `JSRuntime.traceRoots` 上报；atom 表：`DynamicAtom.str` + `predefined_str[]` 作强根（S3 弱化前），`AtomTable.traceRoots` 遍历；`recent_atom_strings`、`empty_string` 同 |
| 写屏障 | 对象槽写 string 值的路径已走 `generationalBarrierValue`（`cycleMarkHeader` 扩后自动覆盖）；**rope 子边写**：`createRopeNode` 是新建（无屏障需求）、`flatten`/`replaceAwaited` 类原地改写 left/right → 加 `generationalBarrierValue(rope_header, new_child)`；`RegExpPayload` setter（object.zig:4386）加屏障 |
| 保守根 | 块几何解析自动覆盖（cell base+8 = String 指针，`heap_accounted` 门 ✔）；extent string 走 `Heap.medium/large` 表 → 地址注册表 `forEachTraceCandidateAt` 加 extent 段 |
| 单测无保守扫描 | 持 string JSValue 跨 GC 的测试须 `rootValues` 帧；gc-stress 门会暴露 |

### 5.3 死亡（sweep）

| 项 | 改法 |
|---|---|
| `destroyCondemned` 块段（:2500）/ `destroyDoomedSlice`（:1306）/ 位图 `takeDoomedCell` | `header.kind` 分派：`.object → Object.destroyFromHeader`；`.string → String.destroyCellFromHeader`（symbol body 先做 5.4 握手，再 `debitBlockCellPayload` + `settle/freeSmallCell`） |
| extent string | 新 `.string` 专用 doomed 表（sweep 遍历 `Heap.medium/large` 表里 kind==string 且未标记者）——或更简单：extent string 也进 `gc_obj_list`？**不行**（无链字）。选：`Heap.forEachExtentUnmarked(epoch, visit)`，标记位用 extent 表项的 `mark_epoch: u64` 字段（`MediumExtent`/`LargeMap` 各加一字），`headerMarked/setHeaderMarked` 对 `alloc_info.standalone and kind==.string` 走表查（冷路径；大字符串稀少） |
| `JSValue.free/dup` string 臂 | 开关下 no-op（`isTracerOwned` 已含）；`releaseRefCountedNeedsDestroy*`/`freeFromPlainObjectDestroy` 同 |
| value_ops.zig:883/985 `rc==1` rope 原地追加 | 开关下改判据：`flags.young and !shared`？无 shared 位 → 先删（记账看 string-concat 基准），必要时用 rope 的 `flags` 借位做「唯一持有者」位（创建即置 1，任何 `dup` 清 0 —— 但 dup 是 no-op…）→ 删除，S2 记账 |
| runtime.deinit `releaseCachedStrings`/`releaseValueSymbolBodiesAfterGc` | 开关下改为清根 + `gc.deinit` 清扫（块堆 deinit 释放所有 cell；extent 表 deinit 释放） |

### 5.4 atom 握手（S2-c，同批）

- `symbolBodyIfLive`（atom.zig:1664）`rc==0` → `!headerMarked(body)`，仅在 sweep 期（`phase == .tracer_destroy`）有意义；mutator 期 body 只要在表里就活（表是强根，S3 前）。
- `onSymbolBodyZeroRef`（:1642）→ 由 `String.destroyCellFromHeader` 在 sweep 期对 `atom_id` 为动态 atom 的 body 调用（语义不变：body 死 ⇒ entry 出表或留 weak 壳）。
- `ensureSymbolBody` 的 rc 转移（:1712）、`retainValueSymbolEntry`（:1876）、`strongRefCount`（:896）：开关下 entry 计数回到 `entry.ref_count`（不再借 body rc），`weakref_count` 不变。
- `DynamicAtom.str` 强根：`AtomTable.traceRoots` 遍历 `entries` 上报 `str`；`predefined_str` 同。

### 5.5 分片与门

1. **S2-a2.1**：开关 + 载体（5.1）+ `heapByteSizeFromHeader` + 三处断言 + catalog；开关关时零行为变化 → 门 test+stress。
2. **S2-a2.2**：追踪（5.2）全部在开关下 + 根 + rope/RegExp 边；开关关时零变化 → 门。
3. **S2-a2.3**：死亡（5.3）+ atom 握手（5.4）在开关下；**翻开关跑全门**（test / stress / test262 / diag）；修到绿；Stage 0 记账。
4. **S2-d**：默认 true 合入后删 rc 分支与 `.string_rc`/`StringHeader` 等。

### 5.6 执行记录

- **S2-a2.1（2026-09-03 深夜）**：`gc.string_tracer_owned` comptime 开关（默认 false）落地；开关下：`refCountRemoved/frontierEpochSafe/traceRememberedCacheEligible/isCycleCandidate` 对 `.string` 取开关值，catalog 两表按开关切换，`heapByteSizeFromHeader` `.string` 臂走 `string.accountedAllocationSizeFromHeader`；`memory.createStringCell/destroyStringCell`（复用 Object 块堆的 `allocCell`，前缀按块 cell 约定初始化，kind=.string）；`String.createUninitialized`/`allocRopeNode` 在开关下优先取块 cell 并 `addInitializedWithSizeNoFail`（extent 路径留 a2.3，暂回落裸 slab）；`destroyFlat`/`freeRopeNode` 识别块 cell；rope 判别位 = 前缀 `flags.mark`（`string_prefix_init_rope`）；`traceHeaderEdges` 的块 cell 断言放宽并分派 `string.traceStringEdges`（rope 访问 left/right，双形态 visitor）。`publishGreyCold` 保持只推 Object（非 Object kind 发布时留白，靠创建者栈引用 + 写屏障，注释有据）。两种开关值均编译通过；开关关时行为零变化。
- **S2-a2.2（同夜）**：开关下的追踪：`JSValue.tracer_owned_first_tag`（开关→`Tag.symbol`，否则 `Tag.big_int`），`cycleMarkHeader`/`isTracerOwned`/两处 deinit 判定共用，仍单比较；`JSRuntime.traceStringCacheRoots`（六缓存 + `atoms.traceRoots`）挂在 `traceRoots` 末尾；`AtomTable.traceRoots` 上报 `predefined_str[]` 与 `entries[].str`（强根，S3 前）；rope `flatten` 改写 left/right 前加 `generationalBarrierValue`；`RegExpPayload.traceChildEdges` 访问 `source`/`compiled_bytecode`（双形态 `callVisitValue`），`setRegexpSource`/两处 `compiled_bytecode` 写点加屏障。开关关时零变化；两种开关值均编译。剩余：a2.3 = sweep 分派（块 cell/extent 的 `.string` 臂、symbol body 握手、runtime.deinit 两处 release 改清根、value_ops rc==1 rope 原地追加处理、extent 载体与表标记），然后翻开关跑全门。

### 5.7 S2-a2.3 细化（sweep 分派、atom 握手、extent）——待实现

**atom 表在 S2 的所有权规则（替代 5.4 草案）**：`entry.ref_count` 只计「按 atom id 的持有者」（shape 属性键、parser、native `atoms.dup`），**不再借 symbol body 的 rc**；body 的 JS 持有者靠 mark。`AtomTable.traceRoots` 只对 `entry.ref_count > 0` 的条目上报 `str`（string 与 symbol 同规则；`predefined_str` 全上报）。由此：
- `ensureSymbolBody`：开关下不做 `transferred_refs` 转移，`entry.ref_count` 原样保留；`retainValueSymbolEntry`：恒 `ref_count += 1`；`free`：恒 `ref_count -= 1`，归零时若 `str == null` 立即 `finalizeDeadEntry`（无 body ⇒ 无 JS 持有者），否则留给 sweep。
- `strongRefCount/isLive/hasLiveValue`：开关下 `ref_count != 0 or str != null`；`symbolBodyIfLive`：开关下 `entry.str`（有 body 即活，直到被清扫）。
- **sweep 握手** `AtomTable.onSymbolBodyDead(idx, body)`（由 `String.destroyCellFromHeader` 在 `phase == .tracer_destroy` 调用，条件 `body.atom_id` 为动态 atom）：`weakref_count != 0` → `unindexEntry` + `entry.str = null`（弱壳，`symbolValueIfLive` 返回 null）；否则 `finalizeDeadEntry(idx, body)`（`destroying_body == body` 已避免二次释放）。`releaseSymbolWeakRef` 末次弱引用：开关下 `str == null and ref_count == 0` 才 finalize。
- deinit：`releaseCachedStrings`/`releaseValueSymbolBodiesAfterGc` 开关下只清槽（`str = null`、`predefined_str = null`），内存由 `gc.deinit`（块堆/extent 表 deinit）整体回收。

**sweep 分派**：`destroyCondemned`（gc_trace_stw.zig:2509）与 `destroyDoomedSlice`（:1307）的块循环把 `assert(kind == .object)` 改为 `switch (kind) { .object => Object.destroyFromHeader, .string => string_mod.destroyCellFromHeader(rt, header), else => unreachable }`。`destroyCellFromHeader`：rope → `freeRopeTail`（native 尾缓冲）后归还 cell；flat → symbol 握手后归还 cell（`destroyStringCell`）。计数：`garbage_count/destroyed` 同 Object。

**extent（>128B）**：`Heap.alloc(total)`（medium/large）+ 前缀 `alloc_info.standalone=true`、`size_class=encodeHeapBytes`；`LargeMap`/`MediumExtent` 各加 `mark_epoch: u64`、`kind: u8`；`headerMarked/setHeaderMarked` 对 `kind == .string and standalone` 走 `Heap.extentMark*(addr)`（hash 查表，冷路径）；sweep 末尾 `Heap.sweepStringExtents(epoch, rt)` 遍历两表释放未标记者（含 rope tail？rope 永远小类，不涉及）；地址注册表 `forEachTraceCandidateAt` 加 extent 段（`Heap.extentContaining(addr)`）。`destroyFlat` 对 standalone string 走 `Heap.free(base)` + `recordHeapFreeWithBytes`。发布：`addInitializedWithSizeNoFail`（cold arm：standalone → `insertLiveAddressCold` 进地址注册表 ✔，`linkGcObjectTail` 须跳过 string（无链字）→ `publishInitialized` 中 `tracked and !is_block_cell` 分支加 `kind != .string`）。

**value_ops**：`node.header().rc == 1` 两处与 `rc > max_ref_count` 一处改经 `core.string.ropeExclusivelyHeld(node)`/`ropeShareCountAtMost(node, n)`：开关下返回 false（放弃原地追加，S2 记账后决定是否用 young 位替代）。

**翻开关前的门**：两种开关值 test+stress；开关开时 test262 script、diag、Stage 0；预计要修的测试类别：`allocated_bytes` 精确相等（string 释放延迟到 sweep）、`refCount` 断言（tests/core.zig 4 处、bytecode.zig 4 处、property_direct.zig 7 处）、无保守扫描下持 string 跨 GC 的测试须 `rootValues` 帧。
- **S2-a2.3（2026-09-03 夜，三个并行 worktree 代理 + driver 合并）**：A `s2a23-atom`（2fd73ad0）atom 表所有权规则——`ref_count` 只计 id 持有者，JSValue 持有靠 mark；`takeSymbolValue` 把创建者的 id 计数转成 JSValue（`ref_count -= 1`），`Symbol()` 新建后 `ref_count == 0` 仅靠 mark 存活；表自身对 body 的引用经 `retainBody/releaseBody`（开关下 no-op；纠正了「gc.release 对 StringHeader 是 no-op」的误判：gc.zig 会路由到 `String.releaseFromHeader`）；`traceRoots` 只对 `ref_count > 0` 的条目上报。B `s2a23-sweep`（3a28d350）`String.destroyCellFromHeader`（rope 释放 tail 后归还 cell；flat 先 `onSymbolBodyDead` 再归还）、`AtomTable.onSymbolBodyDead`（弱壳 / finalize）、两处块循环 kind 分派、`ropeExclusivelyHeld/ropeShareCountAtMost`（开关下 false）、三个 rc→0 析构入口加 `assert(!switch)`。C `s2a23-extent`（931be386）`MediumExtent/LargeMap.mark_epoch`、`Heap.extentSetMark/extentIsMarked/extentContaining/sweepStringExtents`、`memory.createStringExtent/destroyStringExtent`、`Registry.unpublishStringExtent`、`headerMarked/setHeaderMarked` 的 standalone string 分支、`publishInitialized` 对 string 跳过 list 链接与 young 锚点、地址注册表 extent 探测。driver：合并（string.zig 一处冲突：保留两侧、删 shim）、把 `sweepStringExtents` 接到 `destroyCondemned` 块段之后与 `finishIncrementalCycle` 的位图快照之后；测试里 15 处 string rc 断言加 `comptime !switch` 守卫。待办：开关开的门 + 测试修复（`allocated_bytes` 精确相等类、无保守扫描下的 string 根）、A 提出的弱处理相位问题（`symbolBodyIfLive` 在 `.tracer_destroy` 期应读 mark）。

## 6. 交接（2026-09-04 00:30，owner「先收尾 handover」）

**状态**：S2 全部工作已合入 main（a318014c），`gc.string_tracer_owned` **默认 false**，开关关时行为与 S1 终态一致（8d2e5f11 上 test 2502/0、gc-stress 2498/0；test262/Stage 0 未对 S2 分支重跑——开关关的改动是 8B 前缀 + 守卫代码，建议下一位开工前跑一次 `/tmp/s1_stage_gate.sh` 同款整期门确认）。

**开关开（`string_tracer_owned = true`）的进度**：已过 `defineScriptArgs` 等单测（分配→标记→清扫→deinit 全链路通），全量单测的第一处失败在 **`String.releaseFromHeader`（string.zig:726）← `concatFlatStringBodiesOwned`（value_ops.zig:1080）← `stringAddStringsOwned` ← `op_add_strings`**：value_ops 直接调 `String.retain()/releaseFromHeader()` 的 5 处（勘察 §1.3：883/985/1004/1052/1130 附近）在开关下仍走 rc 路径并触发 `assert(!switch)`/析构。下一步（S2-d 前置）：把 `String.retain`/`releaseFromHeader`/`header().retain()` 在开关下变为 no-op（或在这 5 处用 `if (comptime !gc.string_tracer_owned)` 门），然后继续跑 `zig build test` 逐个清失败；预期后续失败类别见 §5.7 末段（`allocated_bytes` 精确相等、无保守扫描下的 string 根、`parser.zig:12914` 的 `strongRefCount` 求和、`refCount()` 对 symbol 现返回 id 计数）。

**翻开关的操作方法**：在独立 worktree 里 `sed -i 's/^pub const string_tracer_owned: bool = false;/... = true;/' src/core/gc.zig`，`zig build test -Dtest-filter=<子串>` 逐个复现（Debug 编译 ≈2-3 min），修好后把补丁同步回 main 树（本次用 python 脚本对两棵树同改）；脚本 `/tmp/s2_flip_gate.sh`（临时文件，可能已丢，逻辑如上）。

**三个并行 lane 的未决点**（来自各代理报告）：A：弱处理相位——`symbolBodyIfLive` 在 `.tracer_destroy` 期应读 `headerMarked(body)`（WeakRef 清理/FinalizationRegistry 对 symbol 目标）；`Object.weakRefDeref` 对 symbol 不 `keepAliveWeakRefTarget`。B：`appendRopeTail` 内部的 `rc > max_ref_count` 已改经 `ropeShareCountAtMost`（开关下恒 false）。C：extent 未进 `GcObjectIterator`（census/verify 只通过 `HeapAccountingIterator.extents` 看到），`extentContaining` 是线性扫描。

**待 owner 裁决**：消融余项（docs/gc-ablation-plan.md §6）；S2 翻开关后 rope 原地追加优化的替代判据（记账后定）。

**分支/工作树**：main = a318014c；`gc/tgc-s2-20260903` = 8d2e5f11（已合入，可删）；三个 lane 分支与临时 worktree 已删除；`/home/aneryu/worktrees/gc-ablation` 与其他旧 worktree 未动。
