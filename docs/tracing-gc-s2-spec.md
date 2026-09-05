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

## 7. S2 在裁剪树上的收口（2026-09-04 上午，driver）

**基线变化**：§6 交接后，owner 在主树上做了代码消融与裁剪（未提交，快照分支 `wip/s2-ablated-base` = 23385e95，−16,880/+2,786 非注释行）。裁剪把 S2 的开关**固化为真并删除了 rc 分支**：`gc.string_tracer_owned`、`RefCountHeader/StringHeader/string_rc_prefix_size/ref_count_offset_from_payload/string_prefix_init`、`String.retain/releaseFromHeader`、`refCountRemoved` 全部消失；`tracer_owned_first_tag` 固定为 `Tag.symbol`（value.zig:17）。同时超出 S2 范围做掉了完成计划 S3 的第 4/5 步：`JSValue.dup` 恒返回自身、`JSValue.free` 对所有 tag 为 no-op（value.zig:494-498），调用点已机械删除（`.dup()` 903→0、`.free(rt` 2966→1；`defer …free(` 残 37 处多为 allocator/atoms）。

**被裁掉的 S2 相关机制**：rope 尾部累加器（`RopeTailState`/`appendRopeTail`，依赖 rc==1 的原地追加）连同 4 个测试一并删除，`ropeExclusivelyHeld/ropeShareCountAtMost` 也随之消失——§3 第三条风险（string-concat 退化）由 Stage 0 记账裁决。共删测试 27 个、新增 14 个（2496 → 2491）。§6 所列「开关开的第一处失败」及 §5.7 末段预告的失败类别已在裁剪中修复：症状为 `rt.atoms.name(symbol) == null` 的 71 个「roots direct symbol …」测试改用 `rt.takeSymbolValue`（创建者的 id 计数转为 JSValue 持有）。

**门（裁剪树，开关固化）**：`zig build test` 2489/0（2 skip）；`test-gc-stress` 2485/0（6 skip）；`-Dzjs_gc_roots_diag=true` 2489/0；test262 script **0/49778**（passed 44584，reports/test262-s2）。Stage 0：见 7.1。

**§6 三个 lane 未决点的处置**：
- A 弱相位（`symbolBodyIfLive` 在 `.tracer_destroy` 期应读 mark；`weakref_kept_alive` 是否为根）→ 分支 `s2/weak-20260904`（Opus 子代理，worktree /home/aneryu/worktrees/s2-weak）。
- B `appendRopeTail` 的 `rc > max_ref_count` → 随 rope 尾部一起被裁掉，无余项。
- C extent 未进 `GcObjectIterator`、`extentContaining` 线性扫描（每个保守扫描字 × extent 数）→ 分支 `s2/extent-20260904`（Opus 子代理，worktree /home/aneryu/worktrees/s2-extent）。

### 7.1 Stage 0 记账（2026-09-04，`.scratch/stage0/s2-flip-20260904-official/`，未含 7.3 的两个 lane 补丁）

首跑卡在 gc-stats 快照的「marked kind partition does not add to headers」：marked-set kinds 行缺 `string` 项（S2-c 未做的 `--gc-stats` string 行）。修复：zjs.zig `dumpGcMarkFootprint` 加 `string {d}`；`gc_stats_snapshot.py` 正则可选组、`block_headers ≤ object + string`、refcount-removed 期望含 string、`byKind.string`；`stage0_screen.py` `compare_stats` 改为不对称容忍（候选多出的 leaf 按基线 0 计 drift，少 leaf 仍硬错）——冻结基线 JSON 是旧 schema 且不重生成。

裁决 **STOP**（真实性能，非记账）：

| workload | insn C/B | cycles C/B | minflt | maxrss | committed |
|---|---:|---:|---:|---:|---:|
| deltablue | 0.894 | 0.977 | 0.915 | 0.998 | 1.166 |
| earley-boyer | 0.890 | 0.932 | 1.058 | 1.173 | 0.893 |
| pdfjs | **111.9** | **275.4** | 13.08 | 9.65 | 35.8 |
| raytrace | 0.898 | 0.929 | 0.967 | 0.991 | 1.023 |
| regexp | **1.204** | **1.467** | 1.987 | 1.730 | 2.317 |
| splay | **1.174** | **1.286** | 0.959 | 0.951 | 1.348 |

硬漂移：minor 次数 deltablue 558→628、pdfjs 154→84、regexp 164→398、splay **5→689**（string 分配进了触发阈值，§3 第一条风险兑现）；splay deferred block runs 1691→2985。pdfjs 符号差 98% 落在 `MemoryAccount.createStringExtent`（+823k 采样，基线 0）；`heapBytes.live` 8.1MB→343MB、`blockHeap.committed` 23MB→823MB、forced major finishes 0→183。三个 rc 去除后的正向读数（deltablue/earley-boyer/raytrace insn −10%）是 dup/free 删除的红利。

**归因（driver 读码）**：
1. `Heap.findMediumRun`（gc_block_heap.zig:2485）对全部 superblock × 16 页位做 first-fit 线性扫描，heap 823MB ≈ 1.3 万 superblock ⇒ 每次 medium 分配扫 20 万页位，二次方——medium 在 S2 前零调用者，从未被负载打过。
2. extent 只在 major 末清扫（`destroyCondemned(sweep_string_extents=true)` 仅 :2231 的 major 路径；minor :2128 传 false），pdfjs 的短命大字符串（>128B）在 rc 时代即时释放，现在要活到下一次 major，堆被撑到 forced major；regexp/splay 同族更轻。
3. extent 曾被永久置 young 位并虚增 `young_count`（lane C 代理已修，见 7.3），对 minor 阈值的影响待合并后重测。

### 7.2 S2-e 规格：extent 分配器索引 + young extent 进 minor（待实现，Opus 子代理）

基线：主树合并 7.3 两补丁后的快照 `wip/s2-merged-base`。

**(1) medium 分配器（gc_block_heap.zig）**：superblock 64KiB = 16 页；`Superblock` 加 `max_free_run: u8`（0..16，由 `page_bits` 重算：对 `~page_bits` 的 u16 掩码找最长连 1 段）与 `bucket_link` 双向索引；`Heap.medium_buckets: [17]列表`（下标 = max_free_run，存 superblock 索引；0 号桶 = 满块，不入桶）。`allocMedium(pages)`：从桶 `pages..16` 找首个非空桶（≤16 步）取一个 sb，在其 u16 掩码里用位运算找首个 ≥pages 的空闲段（16 位内 `@ctz` 循环，常数），置位后重算 `max_free_run` 并换桶；无桶命中才 `reserveSuperblock`。`freeMedium`：清位、重算、换桶；`max_free_run == 16`（整块空）的 sb 交给现有 decommit/释放策略（BH-20）。删 `findMediumRun`。测试：满/半满/碎片化三种形态各一次分配落点与桶迁移；`verifyHeapAccounting` 里加「每个 medium sb 的桶号 == 重算 max_free_run」校验。复杂度目标：分配与释放均 O(1)（不随 superblock 数增长），用 Debug 计数器在测试里断言「分配 10k 个 medium extent 期间扫描的 sb 数 ≤ 10k + 常数」。

**(2) young extent 进 minor**：`Heap.young_extents: ArrayList(usize)`（base），`allocMedium/allocLarge` 追加；`Registry.markPublishedYoungClassified` 对 extent 恢复 `young = true`、`young_count += 1`（撤销 lane C 的「extent 不进 young 集」，改为「extent 进 young 集但不进 young 链/young block」）；minor 标记后（`:2128` 附近，`destroyCondemned(false)` 之后）新增 `string_mod.sweepYoungStringExtents(rt)`：遍历 `young_extents`，`extentIsMarked(base, epoch)` 者存活，否则 `destroyDeadStringExtent`；`clearYoungState` 对 `young_extents` 里的幸存者清 young 位并清空列表（晋升老年）。major 路径不变（`sweepStringExtents` 全表）。正确性依据：老对象→young extent 的写已由 `generationalBarrierValue` 记入 remembered set（`cycleMarkHeader` 含 string tag），minor 的 shade 对 standalone string 走 `extentSetMark`；extent 自身无出边（rope 永远是 cell）。`verifyMajorRetirementCommit` 的 young 计数校验要把 `young_extents.len` 计入。测试：分配一个 >128B 且无根的字符串 → 一次 minor 后 extent 表不再含它；有根/被老对象持有（经屏障）者存活；`young_count` 在 minor 后回落。

**(3) 相邻 extent 的 one-past-end**（lane C 未决 1）：`forEachTraceCandidateAt` 对 `addr` 页对齐且 `addr == A.end == B.base` 的情形 visit 两者（照 block/arena 两臂的做法）。

门：test / stress / diag 三门 + test262 script + Stage 0（对照 `.scratch/stage0/s2-flip-20260904-official`；目标：pdfjs/regexp/splay 的 cycles 与 insn 回到 ≤1.10，minor 次数行接受漂移但要解释）。

### 7.3 两个 lane 的落地（2026-09-04 中午，已合入主树工作树）

合并后主树四门：test 2497/0、gc-stress 2493/0、roots_diag 2497/0、test262 script 0/49778。Stage 0（`.scratch/stage0/s2-merged-20260904`）见 7.5。

- A 弱相位（`s2/weak-20260904` = a363c7b5）：`symbolBodyIfLive/symbolBodyHeaderIfLive/symbolValueIfLive/symbolDescription` 加 `rt`，`.tracer_destroy` 期以 `headerMarked(body)` 为准（`bodyLiveForCurrentPhase`）；`weakRefDeref` 死目标不进 `[[KeptAlive]]`；`weakref_kept_alive` 已是根（runtime.zig:2231），无需补；5 个新测试（含一条无修复即红的白盒探针）。审计结论：in-tree 无 sweep 期到达路径，只有 embedder 的 `WeakPersistentValue.get` 回调理论可达。未决：`weakIdentityIsCurrentlyLive` 的 symbol 臂不查 body（弱壳时 `isAlive()` 与 `get()` 口径不一）；`keyIsMarked` 不认 `is_pinned`。
- C extent（`s2/extent-20260904` = 4e0354d2 + b3b76a81）：`extent_pages` 页索引（每页一项 `{base,end}`，`page_shift` 单一来源在 gc_block_heap），探测 O(1)（Debug 实测 148ns，与 extent 数无关；旧线性 2048 个 extent 时 60µs）；插入失败整条回滚并计数、期间走精确线性回退；tombstone 按四分之一容量 rehash；`verifyExtentPageIndex` 接进 `verifyHeapAccounting`。`GcObjectIterator` 只对 `.all` 加 extent 段，`HeapAccountingIterator` 改为继承。**发现并修复真缺陷**：`markPublishedYoungClassified` 给 extent 置永久 young 位、`young_count` 虚高（无人退休）。未决：相邻 extent one-past-end 单赢家（→7.2(3)）；`liveCount(.string)` 口径含 extent。

### 7.5 合并树 Stage 0（`.scratch/stage0/s2-merged-20260904`，含 7.3 两补丁）

仍 **STOP**：pdfjs insn 109.2 / cycles 270.9；regexp 1.087 / 1.290；splay 1.182 / 1.304；deltablue 0.894 / 0.981；earley-boyer 0.891 / 0.942；raytrace 0.899 / 0.937。与 7.1 相比只有 regexp cycles 从 1.47 降到 1.29（extent 页索引把保守扫描的探测成本拿掉了），pdfjs 不变——证实 lane C 的 young 位修正与页索引都不是 pdfjs 的主因，主因是 7.1 归因的 (1)(2)，由 S2-e 解决后重测。

### 7.6 S2-e 落地与 S2-f 规格（2026-09-04 下午）

**S2-e 落地**（`s2/extent2-20260904` = 28a3f406..559b4a52，已 apply 进主树）：medium 分配器 17 桶（`Superblock.max_free_run` 截断到 16 = 桶号，双向桶链；superblock 实为 2MiB/512 页，`scanFreeRuns` 用 `@ctz` 按段步进）；`young_extents` + `sweepYoungStringExtents`（minor 的 `destroyCondemned(false)` 之后）+ `retireYoungStringExtents`（minor 晋升块与 `clearYoungState` 两处）+ `clearYoungExtentMarksStw`；**规格外必要修正**：`extentIsMarked` 的 `epoch != 0` 守卫在首个 major 前让 minor 把所有 extent 读成未标记 → 新生 extent 改带奇数哨兵 `extent_unmarked_epoch = 1`；one-past-end 双访问 `extentsContaining{inside, one_past_end}`。门 test 2504/0、stress 2500/0、diag 2504/0。pdfjs.fixed 快速自证（ReleaseFast，CPU19）：wall **836.9s → 12.9s**，对冻结参照 3.10s 的比值 273 → **4.19**；maxrss 925MB 不变（参照 95MB）；major 184→172、minor 28→96；`--gc-mark-footprint` 显示 172 次 major 累计 marked string 仅 63 万，即 331MB live 是「上次 major 后新分配未回收」而非可达。

**S2-f 三根因（代理归因，driver 核实）**：
1. **页粒度**：129..4095B 的字符串体全走 medium，每个至少占 1 页 4KiB；pdfjs 21.8M 次 below-large 分配里 8.8M 不被小类覆盖；micro：38 万个 320B 字符串 → committed 1.64GB。根因是 `gc_space.zig` 的 `measured_max_small_payload = 128` 是从 object-only 混合冻结的（§4.2 规则：几何类只保留到覆盖 p99 的那一级），S2 后的混合没重冻结；`classes` 现在是字面量表，几何生成器 `nextGeometricClass` 只在 `cutoffForCoverage` 里用。
2. **medium superblock 从不归还**：`releaseFreeBlockPages`（BH-20）只走 classed 的 `free_blocks` 链；整块空的 medium sb 停在 16 号桶，committed 单调不降。
3. **string 分配不驱动 GC 触发**：阈值边界只有 `JSRuntime.collectBeforeObjectAllocation`（qjs `js_trigger_gc(sizeof(JSObject))` 的镜像，memory.zig:97 注释），string 分配只 `creditAlloc` 不过边界；纯字符串循环 1.64GB / `young_count` 38 万 / 零次 GC。qjs 里 string 是 malloc+rc 不需要触发，tracing 下 string 是 GC 载体就必须触发。

**S2-f 规格**（基线 = 主树 S2-e 合并后快照 `wip/s2e-merged-base`）：
- (3) 先做：`String.createUninitialized` 与 `allocRopeNode`（string.zig）在块堆构建里于分配前调用 `rt.collectBeforeObjectAllocation(total_size)`（与 Object 同一边界，level-triggered 一次比较 + 冷尾）；`allocStringAlignedBytes` 里仅测试/force 模式的旧触发若因此冗余则删；测试：纯字符串循环（无对象分配）在阈值处触发 minor，`collection entries > 0`。
- (1) 尺寸类重冻结：`classes` 改为 comptime 生成 = 线性 16..128 + `nextGeometricClass` 序列直到 `measured_max_small_payload`（160,192,240,304,384,480,608,768,960,1200,1504,1888,2368,2960,3712,…，`block_bytes/(class+8) ≥ 16` 封顶 ≈4088）；`classIndexForPayload` 对几何段用 comptime 建的 `[fine_bucket_count]u8` 查表（`(payload+15)/16` 索引）；`canAllocCellSize`/`accountedBodyBytesForRequest`/Block 几何（每类 cell 数、位图宽度）按 `class_count` 泛化，Object 的 comptime 特化路径与 codegen 不变（对照反汇编或至少 `zig build test -Dtest-filter=layout`）。冻结值：先用 `--gc-stats` 的 size histogram 跑六个固定负载 + pdfjs.fixed，取各自 p99 的最大值，按 `cutoffForCoverage` 规则定 `measured_max_small_payload`（预期落在 1–4KiB），把测得的直方图数字写进常量旁的注释；恢复一条「表按 §4.2 规则生成、不是 4KiB 硬编码」的测试（裁剪删掉了旧的）。`createStringCell` 的 `canAllocCellSize(total)` 自动放宽；rope 节点不受影响。
- (2) medium 释放：major 末 `releaseFreeBlockPages` 同一时机加 `releaseEmptyMediumSuperblocks`：`max_free_run == 16 ∧ 512 页全空` 的 sb 释放（保留 1 个备用），**`superblocks` 数组不能移动元素**（`MediumExtent.super_index` 与 `extent_pages` 引用索引）→ 槽位置墓碑 + `free_superblock_slots` 空闲链，`reserveSuperblock` 先取空槽；`verifyMediumBuckets` 跳过墓碑。计入 `stats.committed_bytes` 与 decommit 统计行。
- 门：`zig build test`；pdfjs.fixed 快速自证（wall / maxrss / committed，对照 S2-e 的 12.9s / 925MB）；合入主树后 driver 跑一次 Stage 0。

### 7.7 S2-f 落地（2026-09-04 傍晚，`s2/f-20260904` = ddebf258/ca389b9d/15672998，已 apply 进主树）

- (3) `String.createUninitialized`/`allocRopeNode` 在取裸指针前调 `rt.collectBeforeObjectAllocation(total)`；删零调用者 `allocStringAlignedBytes`；两条「不修即红」测试（纯 flat / 纯 rope 循环必须触发收集）。
- (1) 直方图（ReleaseFast，各一次 fixed-work）：p99 deltablue 160 / earley-boyer 128 / raytrace 160 / regexp 3840 / splay 112 / pdfjs >4096（`over_fine` 饱和）；128 覆盖率 pdfjs 59.6%。冻结 `measured_max_small_payload = 3760`（几何封顶：`64Ki/(3760+8)=17 ≥ 16`）。表 comptime 生成 24 类：16..128 线性 + 160,192,240,288,352,432,528,656,816,1008,1248,1552,1936,2416,3008,3760；几何段 `classIndexForPayload` 查 comptime 表。**顺手修真缺陷**：`cutoffForCoverage` 搜索下界写成 `max_small_payload`（只能原样返回冻结值，旧冻结恰等于线性上限所以看不见）→ 改 `linear_max_bytes`。Object 路径 `allocCellFixedPtr` 反汇编前后 140 条指令一致，仅 `active[]` 字段位移变化。恢复「§4.2 规则、非 4KiB 硬编码」测试。
- (2) `releaseEmptyMediumSuperblocks` 挂 `releaseFreeBlockPages` 尾部；`SuperblockKind.tombstone` + 侵入式空闲槽链，`reserveSuperblock` 返回槽索引、`unreserveSuperblock` 取代三处 `items.len -= 1` 回滚；页位图为「全空」权威；**测量倒逼加 idle 门** `medium_release_min_idle_ns = 1s`（无门时 pdfjs 归还 1711 sb/3.59GB 但 wall 5.84s→30.82s，纯抖动）；加门后七个负载零归还（medium sb 是稳态工作集）。新统计行 `medium_superblocks_released / bytes`。
- 门 test 2507/0。pdfjs.fixed 自证：wall 12.9s → **6.01s**、maxrss 925MB → **107MB**（参照 3.10s / 95MB）、committed 823MB → 75MB、小类覆盖 59.6% → 88.7%、major/minor 172/96 → 942/631（触发边界生效，待 Stage 0 记账）。参考：deltablue 18.55s/9.9MB、raytrace 11.63s/82MB、regexp 5.19s/45MB、splay 2.92s/296MB。
- 未决：idle 门 1s 还是 100ms（+3 sb/6MB，无 wall 代价）待 owner；`fine_bucket_limit = 4096` 让冻结规则在 pdfjs 上饱和，下次重冻结前先加大直方图分辨率；7.3 遗留三项未动。

### 7.8 Stage 0（S2-f 合并树，`.scratch/stage0/s2f-20260904`）与 S2-g 规格

| workload | insn | cycles | minflt | maxrss | committed |
|---|---:|---:|---:|---:|---:|
| deltablue | 0.901 | 0.986 | 0.856 | 0.897 | 1.077 |
| earley-boyer | 0.892 | 0.934 | 1.045 | 1.268 | 0.933 |
| pdfjs | **1.397** | **2.353** | 1.365 | 1.171 | 3.340 |
| raytrace | 0.899 | 0.928 | 0.954 | 0.949 | 1.004 |
| regexp | 0.987 | 0.987 | 4.765 | 3.511 | 2.445 |
| splay | **1.213** | **1.341** | 0.747 | 0.738 | 1.036 |

STOP: pdfjs cycles（275 → 2.35）。硬漂移：minor 次数 pdfjs 154→615、splay 5→781、regexp 164→508、deltablue 558→625；**pdfjs major 6→908**、minor STW 总 75ms→386ms；splay minor STW 4ms→582ms。符号差榜首 `Collector.traceHeader +1129`、`shadeExact +514`、`memcpy +507`、`Table.remove +433`——即 GC 频次本身。另：pdfjs `atomAudit.missingEdge = 2`（S3-a 审计在生产路径抓到两条，交 S3-roots lane）。

**归因（driver 读码）**：`pollGC`（runtime.zig:3030-3040）在提供 minor 之前先算 `over_threshold = allocated_bytes > malloc_gc_threshold`，越线直接走 major——这是 earley-boyer「13,642 minor / 0 major」的修法。rc 时代 string 即时释放，`allocated_bytes` 基本只含老代；S2 后 young string 只在收集时释放，pdfjs 22.9GB 的 string 分配量对着 `2×live + 1.5MB ≈ 17MB` 的阈值每 17MB 就触发一次 major（22.9GB/17MB ≈ 1350，实测 908）。minor 触发是 `young_count ≥ 16K`（计数，gc.zig:242/3654），string 让它填得快 60×，但单次 minor 0.6-0.7ms 尚可，总量随 major 消失后再看。

**S2-g 规格**（基线 `wip/s2f-merged-base`）：`pollGC` 的判定改为分代顺序——(1) 若 `over_threshold ∧ mode.acceptsMinor() ∧ shouldTryMinor()`（或 young 集非空）：先跑 minor（同现有路径，记账不变），然后**重新计算** `over_threshold = allocated_bytes > malloc_gc_threshold`；(2) 仍越线 → 现有 major 路径（保住 earley-boyer 修法：老代垃圾导致的越线在 minor 后依然越线）；(3) 未越线 → 返回 minor 的结果，且 `clearStaleAllocationThresholdRequest`。`collectBeforeObjectAllocation` 那条边界的 `requestGC(.allocation_threshold)` 不动（它只是登记请求，服务在 poll）。注释里把 earley-boyer 的理由改写成「minor 先行 + 二次判定」。测试：(a) 纯 string churn（live 小）跑到分配总量远超阈值，major 次数保持 0 或 ≤1、minor > 0；(b) earley-boyer 形态回归（老代持续增长、minor 回收极少）仍触发 major——用现有 earley-boyer 相关测试或构造「老对象链持续增长」；(c) `--gc-stats` 上 pdfjs.fixed 的 major 次数从 908 回到个位数或十位数，wall 与 maxrss 报数。门：`zig build test`；合入后 driver 跑 Stage 0。

### 7.9 S2-g 落地（2026-09-04 晚，`s2/g-20260904` = c3d9288f，已 apply 进主树）

`pollGC`：`crossing = over_threshold ∨ pendingAllocationThresholdRequest()`（**规格外必要偏离 1**：越线是 `collectBeforeObjectAllocation` 用 `allocated_bytes + size` 提前上报为 request 的，poll 自己账面只看到 33 次越线对 874 次 major，故必须认 request 形态并开放到 `.normal`）；crossing 时若 `pollScansConservatively(mode)`（`.engine_active`，同步 minor 需覆盖 mutator 原生帧）∧ `shouldTryMinorBeforeMajor()` → 先 minor，再二次读 `allocated_bytes > threshold`：仍越线 → 原 major 路径（minor 耗时不进 major pause 环）；否则 `clearStaleAllocationThresholdRequest`，无其它 requester 即返回 minor 结果。**偏离 2**：`shouldTryMinorBeforeMajor` 的尺寸判据用 `minor_crossing_young_floor = minor_young_threshold/16 = 1k`（floor=0 时 earley-boyer 越线紧跟普通 minor 之后、reclaim 0 三次触发 `low_yield_limit` 把普通 minor 一起挂起 → young 10.9M / maxrss 81MB→2.6GB；三档：1k → pdfjs 24 major/4.63s/145MB，4k → 281/5.25s/123MB，16k → 904/6.7s/111MB）。earley-boyer 历史数字保留在注释。测试：young churn 越线由 minor 消化（父提交上必红）、老代持续增长仍触发 major、`setGCThreshold(0)` 越线仍由 major 回答。门 test 2515/0。

pdfjs.fixed（同机对照）：wall 6.70 → **4.62s**、major 908 → **24**、minor 617 → 2324、maxrss 111.6 → **145.5MB**（+31%）、major p50 1.00 → 0.76ms。其余：earley-boyer 22.84→23.18s、deltablue 18.60→18.56s、raytrace 11.42→11.44s（maxrss 103→137MB）、splay 2.93→2.98s。

未决：maxrss 增量 = medium superblock 高水位（raytrace sb 45→62 ×2MiB ≈ +34MB，live 反降），两闸门都在 S2-f——`medium_release_min_idle_ns = 1s` 与 `releaseFreeBlockPages` 只挂 major（major 从 908 降到 24 后 decommit 少跑 884 次）；最小动作是把 `releaseFreeBlockPages` 也挂到 minor 尾部（待 owner）。`minor_crossing_young_floor` 只在 pdfjs+earley-boyer 上冻结。`.idle` 模式不享受 crossing-minor（精确扫描下同步 minor 安全性未论证）。

**⚠️ 回归（同日晚）**：S2-g 合入后 Stage 0 在 regexp 固定负载上报 `RegExp: Error: Wrong checksum.`。二分（四个 checkpoint 各建 ReleaseFast）：S2-f 904 / +S3 编译作用域 897 / +S3 roots 893 / +cpool 883 均正常，S2-g（单独，S2-f+S2-g）即复现；Debug + `ZJS_GC_STRESS=1` 无断言、只错结果 → 静默复用（minor 回收了仍被引用的对象）。主树 checkpoint 0a0bc2b2 暂留，Opus 代理在 `s2/g-20260904` 诊断（切分三处改动 → 缺屏障/缺根 → 修根因）。顺带：S3 三批合计 regexp 分数 −2.3%（atom 边遍历 + `dup` 可空判断），S3-c 删 rc 后重看。

**回归根因与修复（`s2/g-20260904` = 080c2ddc，已合入主树）**：S2-g 本身无错，它让 minor 真的会落在 string 分配边界上，掀开了「字符串是 rc 所有、永不判死」前提下的写点。真凶 `string_ops.initRegExpMatchArrayDenseElementsFromValue`：(1) capture 子串先写进 `rt.memory.alloc` 的原生暂存缓冲——既非 traced carrier 也不在保守扫描范围，第 i 个 capture 被第 i+1 个触发的 minor 判死；(2) `adoptDenseArrayElementsAssumingEmpty` 批量写入绕过 `rememberOwnerForBulkWrite`（`createArray` 之后的每次 `stringSliceValue` 都是收集边界，owner 可能已晋升）。静默是因为被判死的 cell 立刻被下一次分配复用（拿到别的字符串字节）。整个 regexp 负载里「minor 落在一次 fill 内部」只发生 5 次即毁 checksum；切分实验：把 `.normal` 排除即恢复；`ZJS_MINOR_AUDIT=1` 命中 owner=match 数组（3 属性）。修法：adopt 收口加 remember（改签名收 `rt`，5 调用点；孪生 `adoptDenseUnmappedArgumentsElementsAssumingEmpty` 同补）；fill 前缀发布为 `ValueSliceRoot`（与 `argsFromArray` 同型）。同族普查另修 4 处：`Object.setErrorStack`（与 S3-c 重合，合并时保留一份）、`setCallSiteMetadata` 的 `callsite_file`、`replaceRegExpLegacySlot` 记错 owner（槽在 realm 的 `regexp_legacy_statics` 却记 global，新增 `setRealmRegExpLegacySlot` 记 realm header）、`defineJsonParseDataProperty` 重复键覆盖臂。两条删除即红的测试（第二条只在 ReleaseFast 红：Debug 未优化帧把中间值溢出到栈被保守扫描接住）。读数：regexp.fixed 891-894；pdfjs major 24 / minor 2316 不变；test262 RegExp+String+JSON+Error+staging/sm 子集 0/4608。**owner 待裁的同类洞**：`initDenseArrayLiteralValues*` 直写无屏障（现靠「裸分配不触发收集」成立）；`putDenseArrayElementOverwriteOwnedFast` reserved-capacity append 只有探针无屏障（`UnbarrieredStoreSite` 登记的已知决定，热路径定价）；WeakMap value 写入无屏障（依赖 ephemeron 遍历是否在 minor 路径）；若干 `_ = rt;` 存量写点安装强边不记账。

### 7.4 S3 余项


裁剪后 S3 只剩 atom 表弱化（完成计划 §3 S3 第 1–3 步）：`DynamicAtom.str` 变弱、GC kind 加 `visitAtom` 边、编译作用域 root provider、major 末扫 `entries[]`、删 `atoms.dup/free`（现 229 / 1442 处）与 `ref_count`（atom.zig 29 处）。函数级规格另起 `docs/tracing-gc-s3-spec.md`（勘察进行中）。
