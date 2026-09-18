# 08 — 线外 payload 与 FinalizationRegistry 入队

`object_payloads.zig`：各 class 的线外表示、所有权拆除、`traceChildEdges`。`object_gc.zig` 只剩 FinalizationRegistry 清理入队（Pass-A/B 死亡机械已抽走；边枚举在 `Object.traceChildEdgesFallible`）。

## 类型与存储边界

本文件定义 payload 的字段、清理和边枚举。destroy 不统一表示释放分配或执行用户可观察的清理：值槽通常只置空，GC cell 的 backing 留给收集器，普通资源分配则由具体方法归还。字段的 trace 方法不负责完整 GC 阶段控制；弱集合与 FR 的标记策略由 visitor 决定。

| 类型 | 字段与合同 |
| --- | --- |
| `CollectionEntry` | key/value、active（默认 true）、hash、hash_next；无下一项用 collection_no_entry=maxInt(usize)。 |
| `WeakCollectionEntry` | key_identity/value/hash/hash_next；无 active 字段，identity 不作为强对象边。 |
| `FinalizationRegistryCellState` / `FinalizationRegistryCell` | u8 状态 active/pending_enqueue/queued；两个可空 identity 和 held_value。active/pending 保活 held_value，注册时取得的 job 预留槽在排入或销毁时处理。 |
| `DataPropertyLookup` | index:usize 与 JSValue 值副本。 |
| `IntrinsicPromiseReaction` / `PromiseReactionCapability` | intrinsic 存 target/self_error_global；union 的 external 存可选 resolve/reject。 |
| `PromiseReactionRecordPayload` | 两个可选 handler 与 capability，默认空 external；独立的 tracer payload，无资源析构方法。 |
| `OrdinaryPayload` | CallSite file/function/行列/标志、Promise reaction/capability/combinator、Error stack/sites 与计数；行列默认1，其他计数与布尔默认0/false。 |
| `IteratorPayload` | 八个可选值槽、普通分配 atom_keys 快照、index/length、zip 状态、executing、collection_cursor_held。cursor 影响集合条目重排，不是 GC pin。 |
| `WeakReferenceHolderLink` | previous/next 指向拥有者 Object，均为弱链；另存 borrowed_holder_index:u32 和 registered。 |
| `CollectionPayload` | 强/弱条目各有有效 slice 和容量，普通桶数组、active_count、live_cursors 与 holder link。非零 cursor 约束条目压缩；trace 本体不检查 entry.active。 |
| `SharedBufferStore` | 原子 ref_count（初值1）、bytes、外部记账 token、可选 deinit/context。内部 bytes 来自 page_allocator；外部 bytes 则在最后 release 时交回回调。 |
| `ExternalByteStorageDeinit` | 接受可空 context 和 []u8 的 void 函数指针，不接收 runtime。 |
| `BufferPayload` | bytes、32字节未初始化 inline_bytes/inline_length、shared store/token/回调、detached/immutable、可选 max_byte_length、弱 first_view。存储模式须由安装路径维护一致。 |
| `TypedArrayPayload` | buffer 强值、offset/element_size/fixed_length/kind、live_length/data 缓存，以及 backing/prev/next 弱链。element_size=0 表示 DataView。 |
| `RegExpPayload` | extern 两个可空 String 指针，编译期断言为两指针宽；标准 RegExp 放在 Object 的宽臂内，动态 class 仍可能使用线外分配路径。 |
| `BoundFunctionPayload` / `ProxyPayload` | 前者含 target/this 和固定 GC 参数 slice，后者含 target/handler；值均以可选槽保存。 |
| `ArgumentsPayload` / `ObjectDataPayload` | 前者的 var_refs 实际为 []JSValue 的 GC slice；后者为可选 data 值，不能与 Object 的 dense mapped arguments 指针表混淆。 |
| `WeakRefPayload` / `VarRefPayload` | 前者是可空弱 identity 与 holder link；后者是可选 value 与 const/function_name/deletable 标志，并不是独立 VarRef cell。 |
| `FinalizationRegistryPayload` | callback、普通分配 cells/容量、RealmRef 与 holder link；registry 自身的 realm 决定 cleanup job 起始 realm。 |
| `StdFilePayload` | FILE 指针、is_popen/is_stdio；本类型 destroy 只清字段，不 fclose/pclose。 |
| `DisposableResourceKind` / `DisposalHint` / `DisposableMethodKind` | 分别为 use/adopt/defer_、sync/async、direct/async_from_sync，均 enum(u8)。 |
| `DisposableResource` / `DisposableStackPayload` | 资源项含 value/method 与上述三种判别，默认 undefined、defer_/sync/direct；stack 含 GC slice/容量、disposed 和三个异步 dispose 值槽。其 destroy 不调用方法。 |
| `GlobalPayload` / `RealmRecordPayload` | 分别仅保存 uninitialized_vars 对象边与 RealmRef；RealmRef 为追踪指针，deinit 不同步销毁 realm。 |
| `PromisePayload` | 三个 optional result/reaction 值、订阅 GC slice/容量和 rejected/atomics_wait_async 标志；容量非零即需追踪 backing，即使有效长度为0。 |
| `RegExpLegacyStatics` | 五个 optional 匹配值、九个 captures、capture_slot_count 与 lazy 匹配元数据。 |
| `FunctionRarePayload` | 十二个 optional 值槽，以及 callable/builtin/iterator/Promise/async/disposal 标记和索引；realm_global 是其中一个值边，不等同 native.realm。 |
| `FunctionPayload.NativeFields` / `FunctionPayload` | NativeFields 为40字节，含 realm、native entry 缓存、host/native id、dispatch atom、TypedArray 元数据；整个 payload 为56字节，另含 rare 指针及三字节 little-endian index+1 缓存（0表示未缓存）。 |
| `BytecodeFunctionAux` | home_object 与内嵌 FunctionRarePayload；自身为 GC cell，内嵌 rare 不能按 native rare 独立释放。 |
| `BytecodeFunctionStorage` | 24字节 extern 三字布局：FunctionBytecode 指针、可空 VarRef 指针数组的非空哨兵/实际起点、home_or_aux。后者由 Object 按低位 tag 解释为 aux 或直接 home object。 |

ArrayBuiltinMarker 与 TypedArrayBuiltinMarker 是 property.zig 类型别名。通用 callVisit helpers 按 visitor 是否声明对应方法及是否返回 error union 分派；缺方法即跳过，不隐式增加其他边。真实字段指针与临时指针的回写行为不同，详见各 trace 方法。

---

### `WeakCollectionEntry.destroy` (`src/core/object_payloads.zig:37`)

- **签名**：`pub fn destroy(self: WeakCollectionEntry, rt: *JSRuntime) void`。
- **作用**：释放条目对弱 identity 的辅助引用。
- **实现**：仅调用 rt.releaseWeakIdentity(key_identity)。
- **所有权 / 错误 / 调用**：self 按值传入，不清原槽、不修改 hash/value、不释放条目 backing。object identity 无引用计数动作；symbol identity 的弱引用计数由 runtime 处理。

### `FinalizationRegistryCell.isActive` (`src/core/object_payloads.zig:54`)

- **签名**：`pub fn isActive(self: FinalizationRegistryCell) bool`。
- **作用**：判断 cell 是否处于注册有效状态。
- **实现**：返回 state==active。
- **所有权 / 错误 / 调用**：按值只读；不验证 target identity 仍活着。

### `FinalizationRegistryCell.isPending` (`src/core/object_payloads.zig:58`)

- **签名**：`pub fn isPending(self: FinalizationRegistryCell) bool`。
- **作用**：判断是否处于等待入队状态。
- **实现**：返回 state==pending_enqueue。
- **所有权 / 错误 / 调用**：不查询队列或预留容量；状态不等同于 job 已排入。

### `FinalizationRegistryCell.keepsHeldValuesAlive` (`src/core/object_payloads.zig:62`)

- **签名**：`pub fn keepsHeldValuesAlive(self: FinalizationRegistryCell) bool`。
- **作用**：判断 cell 的 held_value 是否仍需由 registry 保活。
- **实现**：active 或 pending_enqueue 返回 true，queued 返回 false。
- **所有权 / 错误 / 调用**：这是状态谓词，本身不标记或清除 value；queued 后 job 的引用由队列协议维护。

### `FinalizationRegistryCell.destroy` (`src/core/object_payloads.zig:66`)

- **签名**：`pub fn destroy(self: FinalizationRegistryCell, rt: *JSRuntime) void`。
- **作用**：释放两个可选弱 identity 的辅助引用及尚未消费的 job 预留槽。
- **实现**：依次 release target/token；state 为 active/pending 且 job_queue.capacity 非零时 releaseReservedEntries(1)。
- **所有权 / 错误 / 调用**：按值接收，不清原 cell、不销毁 held_value，也不直接释放 backing；不能重复销毁同一个仍保留 identity/预留状态的 cell。capacity 判断兼容 runtime 先销毁 queue 的 teardown 顺序。

### `callVisitObject` (`src/core/object_payloads.zig:81`)

- **签名**：`pub inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void`。
- **作用**：按 visitor 能力分派 visitObject。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitObject 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `callVisitValue` (`src/core/object_payloads.zig:94`)

- **签名**：`pub inline fn callVisitValue(vis: anytype, val_ptr: anytype) !void`。
- **作用**：按 visitor 能力分派 visitValue。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitValue 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `callVisitStorageCell` (`src/core/object_payloads.zig:110`)

- **签名**：`pub inline fn callVisitStorageCell(vis: anytype, header: anytype) !void`。
- **作用**：按 visitor 能力分派 storageCell。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 storageCell 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `callVisitShape` (`src/core/object_payloads.zig:123`)

- **签名**：`pub inline fn callVisitShape(vis: anytype, shape_ref: anytype) !void`。
- **作用**：按 visitor 能力分派 visitShape。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitShape 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `callVisitRealm` (`src/core/object_payloads.zig:136`)

- **签名**：`pub inline fn callVisitRealm(vis: anytype, ctx_ptr: anytype) !void`。
- **作用**：按 visitor 能力分派 visitRealm。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitRealm 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `traceOptValue` (`src/core/object_payloads.zig:149`)

- **签名**：`pub inline fn traceOptValue(vis: anytype, opt_val: anytype) !void`。
- **作用**：访问 optional 值槽的非空内容。
- **实现**：解引用 opt_val；存在 payload 时取得其地址并传给 callVisitValue。
- **所有权 / 错误 / 调用**：实际 optional JSValue 槽传入的是 *?JSValue，不是把 ?*JSValue 当作同义类型。visitor 可原位修改值；空槽不调用，错误立即传播。

### `callVisitWeakCollectionEntry` (`src/core/object_payloads.zig:153`)

- **签名**：`pub inline fn callVisitWeakCollectionEntry(vis: anytype, entry: anytype) !void`。
- **作用**：按 visitor 能力分派 visitWeakCollectionEntry。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitWeakCollectionEntry 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `callVisitFinalizationCell` (`src/core/object_payloads.zig:166`)

- **签名**：`pub inline fn callVisitFinalizationCell(vis: anytype, entry: anytype) !void`。
- **作用**：按 visitor 能力分派 visitFinalizationCell。
- **实现**：编译期从 visitor 类型（指针则取 child）检测 visitFinalizationCell 声明；存在时传入原参数，error-union 返回值使用 try，否则直接调用。
- **所有权 / 错误 / 调用**：缺少方法则编译为空操作；不自动回退到其他 visitor 方法、不自带标记或弱键判活逻辑。回调的错误向上传播，字段更新与具体追踪语义由回调决定。

### `destroyOptionalValue` (`src/core/object_payloads.zig:179`)

- **签名**：`pub fn destroyOptionalValue(_: *JSRuntime, slot: *?JSValue) void`。
- **作用**：清除 optional JSValue 槽。
- **实现**：slot.*=null，runtime 参数未使用。
- **所有权 / 错误 / 调用**：不释放旧值、不执行 RC 或 GC 屏障，不销毁槽所在存储。

### `destroyOwnedValue` (`src/core/object_payloads.zig:183`)

- **签名**：`pub fn destroyOwnedValue(_: *JSRuntime, slot: *JSValue) void`。
- **作用**：把 JSValue 槽清为 undefined。
- **实现**：直接写 undefinedValue，runtime 参数未使用。
- **所有权 / 错误 / 调用**：Owned 名称不代表当前执行引用计数释放；被引用对象由 GC 管理。

### `replaceOwnedValue` (`src/core/object_payloads.zig:187`)

- **签名**：`pub fn replaceOwnedValue(_: *JSRuntime, slot: *JSValue, next_value: JSValue) void`。
- **作用**：直接替换 JSValue 槽。
- **实现**：slot.*=next_value，runtime 参数未使用。
- **所有权 / 错误 / 调用**：不释放旧值、不保活新值、无 owner 屏障；所需根与屏障由调用协议提供。

### `destroyValueSlice` (`src/core/object_payloads.zig:191`)

- **签名**：`pub fn destroyValueSlice(rt: *JSRuntime, slot: *[]JSValue) void`。
- **作用**：摘除并释放普通分配的 JSValue slice。
- **实现**：保存旧 slice，先置空字段，旧 len 非零则 memory.free(JSValue,values)。
- **所有权 / 错误 / 调用**：不逐项销毁值；传入长度须匹配分配合同，不适用于直接手还 GC cell。

### `destroyValueSliceValuesOnly` (`src/core/object_payloads.zig:197`)

- **签名**：`pub fn destroyValueSliceValuesOnly(_: *JSRuntime, slot: *[]JSValue) void`。
- **作用**：仅摘除 JSValue slice。
- **实现**：直接将 slice 置空，不使用 runtime。
- **所有权 / 错误 / 调用**：名称中的 ValuesOnly 不表示遍历元素；不清 backing 内容、不释放 backing。GC cell 或外围 slab 的寿命由其拥有者管理。

### `payloadSliceCellHeader` (`src/core/object_payloads.zig:205`)

- **签名**：`pub inline fn payloadSliceCellHeader(ptr: anytype) *gc.GCObjectHeader`。
- **作用**：把 subordinate payload cell 的起始指针解释为 GC header。
- **实现**：仅 alignCast/ptrCast，不做地址偏移。
- **所有权 / 错误 / 调用**：调用方须提供真实 cell 起点；非零 capacity/非空 fixed slice 是拥有者侧判据，本函数不验证 registry 或 kind，也不能传空哨兵。

### `clearVarRefCellSlice` (`src/core/object_payloads.zig:210`)

- **签名**：`pub fn clearVarRefCellSlice(slot: *[]*var_ref_mod.VarRef) void`。
- **作用**：摘除借用的 VarRef 指针窗口。
- **实现**：将 slice 置空。
- **所有权 / 错误 / 调用**：不 close cell、不释放 cell 或 slab，不逐项清旧 backing。

### `closeOpenVarRefCellSlots` (`src/core/object_payloads.zig:216`)

- **签名**：`pub fn closeOpenVarRefCellSlots(rt: *JSRuntime, slots: []?*var_ref_mod.VarRef) void`。
- **作用**：逐项摘除窗口中的 VarRef 指针并关闭 cell。
- **实现**：跳过 null；先置当前槽为 null，再调用 cell.close(rt)。
- **所有权 / 错误 / 调用**：close 对已关闭 cell 无操作；对 open cell 复制绑定值、做世代屏障并将 pvalue 改向内部 value。这里不做 RC release，也不释放 cell 或窗口 backing。

### `destroyValueSliceWithCapacity` (`src/core/object_payloads.zig:224`)

- **签名**：`pub fn destroyValueSliceWithCapacity(rt: *JSRuntime, slot: *[]JSValue, capacity: *usize) void`。
- **作用**：清除 slice/capacity 并按实际容量释放普通 backing。
- **实现**：保存旧字段后将 slice 置空、capacity 置零；旧 capacity 非零则 free ptr[0..capacity]，否则旧 len 非零时 free 原 slice。
- **所有权 / 错误 / 调用**：调用方须提供一致且可由 memory.free 回收的分配；不逐值释放、不验证 len<=capacity，不手还 GC cell。

### `PromiseReactionCapability.traceChildEdges` (`src/core/object_payloads.zig:253`)

- **签名**：`pub fn traceChildEdges(self: *PromiseReactionCapability, visitor: anytype) !void`。
- **作用**：按 capability 当前 union 分支枚举值边。
- **实现**：external 依次访问非空 resolve/reject；intrinsic 依次访问 target/self_error_global。
- **所有权 / 错误 / 调用**：将字段地址传给 visitor，允许原位更新；第一个错误中止后续访问，不自行执行 promise resolve/reject 或弱语义。

### `PromiseReactionCapability.destroy` (`src/core/object_payloads.zig:266`)

- **签名**：`pub fn destroy(self: *PromiseReactionCapability, rt: *JSRuntime) void`。
- **作用**：清当前 capability 分支并重置为空 external。
- **实现**：external 清两个 optional，intrinsic 清两个值，随后整个 union 写为 external 默认值。
- **所有权 / 错误 / 调用**：不调用回调、不释放被引用对象，也不释放自身存储；无 fallible 操作。

### `PromiseReactionRecordPayload.traceChildEdges` (`src/core/object_payloads.zig:286`)

- **签名**：`pub fn traceChildEdges(self: *PromiseReactionRecordPayload, visitor: anytype) !void`。
- **作用**：枚举独立 reaction record 的两个 handler 与 capability。
- **实现**：按 on_fulfilled、on_rejected、capability 顺序访问。
- **所有权 / 错误 / 调用**：错误立即传播，可由 visitor 修改实际字段；record 是追踪 cell，本类型没有独立 destroy 方法。

### `OrdinaryPayload.destroy` (`src/core/object_payloads.zig:315`)

- **签名**：`pub fn destroy(self: *OrdinaryPayload, rt: *JSRuntime) void`。
- **作用**：重置普通对象的 CallSite、Promise 和 Error 冷字段。
- **实现**：逐项清 optional 值并 destroy capability，最后 self.*=.{} 恢复全部默认值。
- **所有权 / 错误 / 调用**：不释放 OrdinaryPayload cell 或它引用的对象；最后整体重置也恢复 line/column=1、计数=0 和标志=false。

### `OrdinaryPayload.traceChildEdges` (`src/core/object_payloads.zig:332`)

- **签名**：`pub fn traceChildEdges(self: *OrdinaryPayload, visitor: anytype) !void`。
- **作用**：枚举普通 payload 的可选值与 reaction capability。
- **实现**：顺序为 CallSite file/function、reaction handlers/capability、promise resolve/reject、combinator resolve/reject/values/keys、error_stack/sites。
- **所有权 / 错误 / 调用**：仅非空 optional 内容送 visitor；数值计数和标志不构成边，错误中止后续遍历；不枚举拥有该 payload 的 Object。

### `IteratorPayload.destroy` (`src/core/object_payloads.zig:374`)

- **签名**：`pub fn destroy(self: *IteratorPayload, rt: *JSRuntime) void`。
- **作用**：清迭代器值槽并释放 atom 快照数组。
- **实现**：按顺序清 target/data/next/callback/inner_next/zip_nexts/zip_pads/zip_keys；摘除 atom_keys 后，非空则 memory.free。
- **所有权 / 错误 / 调用**：不调用 iterator.return，不归还 collection cursor，不逐个释放 atom，也不重置 index/length/执行状态等标量。Object 的销毁路径须先处理持有的 collection cursor；值槽清空不触发 RC 析构。

### `IteratorPayload.traceChildEdges` (`src/core/object_payloads.zig:388`)

- **签名**：`pub fn traceChildEdges(self: *IteratorPayload, visitor: anytype) !void`。
- **作用**：枚举八个可选值槽与 atom_keys。
- **实现**：先依次 traceOptValue 八槽，再逐个 atom.callVisitAtom(atom_id)。
- **所有权 / 错误 / 调用**：值槽地址可供 visitor 更新，atom 按 id 传递；回调缺失则按通用 helper 规则跳过。游标标志及索引不是边，遇错立即停止。

### `CollectionPayload.destroy` (`src/core/object_payloads.zig:437`)

- **签名**：`pub fn destroy(self: *CollectionPayload, rt: *JSRuntime) void`。
- **作用**：摘除强条目、桶和弱条目 backing。
- **实现**：保存旧数组与容量，先清数组/容量和 active_count；强条目按 capacity（否则 len）释放，桶按 len 释放；逐个 releaseWeakIdentity 后按同样容量规则释放弱条目。
- **所有权 / 错误 / 调用**：不逐值销毁 key/value；live_cursors 和 weak_holder_link 没有在这里重置或摘链。必须使用拥有正确分配容量的 payload，弱 holder 注销属于对象层协议。

### `CollectionPayload.traceChildEdges` (`src/core/object_payloads.zig:466`)

- **签名**：`pub fn traceChildEdges(self: *CollectionPayload, visitor: anytype) !void`。
- **作用**：访问强条目的 key/value 并分派弱条目回调。
- **实现**：遍历整个 entries slice，逐槽访问 key 再 value；随后逐个 callVisitWeakCollectionEntry。
- **所有权 / 错误 / 调用**：不检查 active 位，也不遍历 capacity 以外或 len 以外的槽；墓碑值的清理由 mutation 路径负责。弱 value 是否保活由 visitor 的 ephemeron/诊断策略决定，本体不直接强标所有弱 value。

### `SharedBufferStore.create` (`src/core/object_payloads.zig:484`)

- **签名**：`pub fn create(rt: *JSRuntime, byte_length: usize) !*SharedBufferStore`。
- **作用**：创建带原子引用计数的共享字节存储。
- **实现**：page_allocator 分配 store 和 byte_length 字节，reportExternalAlloc 得到记账 token，再将 bytes 清零并初始化 store，ref_count=1。
- **所有权 / 错误 / 调用**：分配和记账失败传播，errdefer 释放已成功取得的资源；字节不经 rt.memory 分配，但仍报告外部内存，不能称为完全不计入 runtime 记账。

### `SharedBufferStore.createExternal` (`src/core/object_payloads.zig:501`)

- **签名**：`pub fn createExternal( rt: *JSRuntime, bytes: []u8, deinit_fn: ExternalByteStorageDeinit, context: ?*anyopaque, ) !*SharedBufferStore`。
- **作用**：采纳调用者提供的外部字节及销毁回调。
- **实现**：只由 page_allocator 创建 store，报告 bytes.len 外部内存，再安装借入的 slice、deinit/context 和 ref_count=1。
- **所有权 / 错误 / 调用**：不复制或清零 bytes；成功后最后一次 release 调用回调。失败只清本函数创建的 store/token，不调用 deinit，不消费调用者的字节所有权。

### `SharedBufferStore.retain` (`src/core/object_payloads.zig:522`)

- **签名**：`pub fn retain(self: *SharedBufferStore) void`。
- **作用**：增加共享 store 的引用数。
- **实现**：ref_count.fetchAdd(1,.monotonic)，忽略旧值。
- **所有权 / 错误 / 调用**：调用方须已持有效存活引用；不创建 GC 根，不对 bytes 访问做同步或边界检查，也无溢出防护。

### `SharedBufferStore.release` (`src/core/object_payloads.zig:526`)

- **签名**：`pub fn release(self: *SharedBufferStore) void`。
- **作用**：递减引用数并在最后一个引用释放时销毁 store。
- **实现**：fetchSub(1,.acq_rel) 旧值非1直接返回；否则保存 bytes/回调/context，先 release 外部 token 并清相应字段，再调用外部 deinit 或 page_allocator.free，最后 destroy store。
- **所有权 / 错误 / 调用**：最后释放后 self 不可再访问；调用者负责配对引用，不能对零引用对象重放 release。原子计数不等于共享字节操作均线程安全。

### `BufferPayload.destroy` (`src/core/object_payloads.zig:562`)

- **签名**：`pub fn destroy(self: *BufferPayload, rt: *JSRuntime) void`。
- **作用**：先摘除弱 view 链，再释放字节存储。
- **实现**：unlinkAllViews 后 releaseStorage。
- **所有权 / 错误 / 调用**：避免后续 view 清理继续使用已销毁 backing payload；本函数不释放 BufferPayload 自身，也不设置 detached/immutable/max_byte_length。

### `BufferPayload.traceChildEdges` (`src/core/object_payloads.zig:570`)

- **签名**：`pub fn traceChildEdges(self: *const BufferPayload, visitor: anytype) !void`。
- **作用**：提供无强边的 buffer payload 访问接口。
- **实现**：忽略 self 和 visitor，函数体无遍历。
- **所有权 / 错误 / 调用**：字节不是 JS 值边，first_view 是弱链；这是整个 tracing 接口中的空 payload 分支，不只是不参与 cycle graph。对象的其他边仍由 Object 枚举。

### `BufferPayload.releaseStorage` (`src/core/object_payloads.zig:578`)

- **签名**：`pub fn releaseStorage(self: *BufferPayload, rt: *JSRuntime) void`。
- **作用**：释放当前字节所有权并清存储字段。
- **实现**：先 invalidateViews；按 shared_store、external_deinit、inline_length 非零、普通 bytes 的优先级处理。shared 调 store.release；external 先 release token 再回调；inline 报 untracked free 并置 inline_length=0；普通分支 release token 后按非空 bytes 释放。最后清 bytes/store/token/deinit/context。
- **所有权 / 错误 / 调用**：不摘除 view 链，不设置 detached，也不清 immutable/max_byte_length 或 inline_bytes 内容。依赖存储模式互斥；回调发生在末尾字段清空之前，不能宣称对同一 payload 的递归释放安全。

### `BufferPayload.attachView` (`src/core/object_payloads.zig:602`)

- **签名**：`pub fn attachView(self: *BufferPayload, view: *TypedArrayPayload) void`。
- **作用**：把未链接的 view 插入弱链头并刷新缓存。
- **实现**：断言 backing/prev/next 均为空，设置 backing 和 next，修原链头 prev，再更新 first_view、调用 updateLiveState。
- **所有权 / 错误 / 调用**：不安装 view.buffer 强边、不验证 buffer 值是否对应此 backing；无分配或独立根/屏障。

### `BufferPayload.detachView` (`src/core/object_payloads.zig:614`)

- **签名**：`pub fn detachView(self: *BufferPayload, view: *TypedArrayPayload) void`。
- **作用**：摘除属于本 backing 的 view 并清缓存。
- **实现**：backing 不同则断言为空并返回；否则修前后节点或 first_view，清 view 的 backing/prev/next，再 clearLiveState。
- **所有权 / 错误 / 调用**：不清 buffer 强值、不释放 backing 或 view；对已断链 view 的返回分支也不会另外清其缓存。非空错误 backing 是调用违约。

### `BufferPayload.invalidateViews` (`src/core/object_payloads.zig:636`)

- **签名**：`fn invalidateViews(self: *BufferPayload) void`。
- **作用**：清所有已链接 view 的 live 缓存。
- **实现**：沿 buffer_next 调 clearLiveState。
- **所有权 / 错误 / 调用**：保留弱链、view.buffer 和固定配置；不释放字节。

### `BufferPayload.updateViews` (`src/core/object_payloads.zig:643`)

- **签名**：`pub fn updateViews(self: *BufferPayload) void`。
- **作用**：依据当前 backing 字节刷新所有 view 缓存。
- **实现**：沿 buffer_next 调 view.updateLiveState(self)。
- **所有权 / 错误 / 调用**：本函数不修改字节长度、不分配；缓存结果取决于 detached、offset、宽度及固定/跟踪模式。

### `BufferPayload.unlinkAllViews` (`src/core/object_payloads.zig:650`)

- **签名**：`fn unlinkAllViews(self: *BufferPayload) void`。
- **作用**：摘除全部弱 view 链节点。
- **实现**：只要 first_view 非空就 detachView(first_view)。
- **所有权 / 错误 / 调用**：不清各 view 的 buffer 强值；依赖链及 backing 指针一致，无环检测。

### `TypedArrayPayload.destroy` (`src/core/object_payloads.zig:667`)

- **签名**：`pub fn destroy(self: *TypedArrayPayload, rt: *JSRuntime) void`。
- **作用**：从 backing 弱链摘除 view，清 buffer 强值槽。
- **实现**：若 backing_payload 非空则 detachView，然后 destroyOptionalValue(buffer)。
- **所有权 / 错误 / 调用**：当前 destroyOptionalValue 只置 null，不会立即 finalize ArrayBuffer；旧 RC 顺序注释不能当作当前行为。不会释放本 payload 或重置 offset/element_size/fixed_length/kind。

### `TypedArrayPayload.traceChildEdges` (`src/core/object_payloads.zig:675`)

- **签名**：`pub fn traceChildEdges(self: *TypedArrayPayload, visitor: anytype) !void`。
- **作用**：访问可选 buffer 强值槽。
- **实现**：仅 traceOptValue(visitor,&buffer)。
- **所有权 / 错误 / 调用**：backing/prev/next 和 data 均不作为强边；允许 visitor 原位改 buffer，错误传播。

### `TypedArrayPayload.clearLiveState` (`src/core/object_payloads.zig:679`)

- **签名**：`fn clearLiveState(self: *TypedArrayPayload) void`。
- **作用**：把可用范围缓存清为不可用。
- **实现**：live_length=0，data=null。
- **所有权 / 错误 / 调用**：不改固定配置、弱链或 buffer 强槽；既可表示 detached/OOB，也用于发布新状态前清理。

### `TypedArrayPayload.updateLiveState` (`src/core/object_payloads.zig:684`)

- **签名**：`fn updateLiveState(self: *TypedArrayPayload, backing: *BufferPayload) void`。
- **作用**：依据 backing 重新计算 live_length/data。
- **实现**：先清缓存；detached 或 offset>bytes.len 返回。DataView（宽0）在 kind==1 且 max_byte_length 非空时跟踪剩余字节，offset==len 返回；其他 DataView 需 fixed_length 且范围放得下。TypedArray 固定长度用 checked 乘法检查范围；无固定长度则至少剩一个完整元素，取 remaining/width。长度须可转 u32，成功后 data=bytes.ptr+offset。
- **所有权 / 错误 / 调用**：不验证 offset 对齐、buffer 强值或弱链一致性；长度/乘法不适配时静默保持空缓存，不返回 error。固定零长度可发布非空位置指针，跟踪零长度则保留 null，两者不同。

### `RegExpPayload.destroy` (`src/core/object_payloads.zig:739`)

- **签名**：`pub fn destroy(self: *RegExpPayload, _: *JSRuntime) void`。
- **作用**：清除 source/compiled_bytecode 两个可选字符串指针。
- **实现**：self.*=.{}，runtime 未使用。
- **所有权 / 错误 / 调用**：不释放字符串或自身存储；标准 RegExp payload 嵌于 Object 臂，动态 class 是否另分配由对象构造分支决定。

### `RegExpPayload.traceChildEdges` (`src/core/object_payloads.zig:743`)

- **签名**：`pub fn traceChildEdges(self: *const RegExpPayload, visitor: anytype) !void`。
- **作用**：为两个非空字符串字段报告值边。
- **实现**：依次将 source 与 compiled_bytecode 转为局部 JSValue，传局部 slot 地址给 callVisitValue。
- **所有权 / 错误 / 调用**：visitor 对临时值的修改不会回写原指针；此接口为不可移动字符串边的访问方式。错误中止后续访问，非空 compiled 字符串内容不在这里解析。

### `BoundFunctionPayload.destroy` (`src/core/object_payloads.zig:766`)

- **签名**：`pub fn destroy(self: *BoundFunctionPayload, rt: *JSRuntime) void`。
- **作用**：清 target/this 并摘除参数 slice。
- **实现**：清两个 optional，再 destroyValueSliceValuesOnly(args)。
- **所有权 / 错误 / 调用**：参数 backing 是 subordinate GC payload cell，不手动释放；不调用目标函数，也不释放 BoundFunctionPayload 自身。

### `BoundFunctionPayload.traceChildEdges` (`src/core/object_payloads.zig:774`)

- **签名**：`pub fn traceChildEdges(self: *BoundFunctionPayload, visitor: anytype) !void`。
- **作用**：枚举 bound target、this、参数 backing 和参数值。
- **实现**：先访问两个 optional；args 非空时报告 payloadSliceCellHeader 给 storageCell，再逐值访问参数。
- **所有权 / 错误 / 调用**：固定 slice 无独立 capacity；非空即代表 cell。storageCell 回调缺失时仍继续值遍历，任一步错误停止后续访问。

### `ProxyPayload.destroy` (`src/core/object_payloads.zig:789`)

- **签名**：`pub fn destroy(self: *ProxyPayload, rt: *JSRuntime) void`。
- **作用**：清 target 和 handler 槽。
- **实现**：两次 destroyOptionalValue 依次置 null。
- **所有权 / 错误 / 调用**：不调用 trap 或 revoke 回调，不销毁引用对象或自身 cell；不能等同于完整 Proxy.revocable 执行流程。

### `ProxyPayload.traceChildEdges` (`src/core/object_payloads.zig:794`)

- **签名**：`pub fn traceChildEdges(self: *ProxyPayload, visitor: anytype) !void`。
- **作用**：枚举 target/handler 强值边。
- **实现**：依次 traceOptValue 两槽。
- **所有权 / 错误 / 调用**：回调接收真实值地址，可更新；错误立即传播，不执行 trap。

### `ArgumentsPayload.destroy` (`src/core/object_payloads.zig:803`)

- **签名**：`pub fn destroy(self: *ArgumentsPayload, rt: *JSRuntime) void`。
- **作用**：摘除 var_refs 值数组。
- **实现**：destroyValueSliceValuesOnly 将 slice 置空。
- **所有权 / 错误 / 调用**：字段实际类型是 []JSValue，不是 Object dense mapped-arguments arm 的 ?*VarRef 数组；不关闭 VarRef 或手还 GC backing。

### `ArgumentsPayload.traceChildEdges` (`src/core/object_payloads.zig:808`)

- **签名**：`pub fn traceChildEdges(self: *ArgumentsPayload, visitor: anytype) !void`。
- **作用**：枚举参数 payload 的值数组及 backing cell。
- **实现**：非空 slice 先报告 storageCell，再逐值 callVisitValue。
- **所有权 / 错误 / 调用**：只遍历 len；空 slice 是哨兵。visitor 不支持 storageCell 时仍可处理值边。

### `ObjectDataPayload.destroy` (`src/core/object_payloads.zig:818`)

- **签名**：`pub fn destroy(self: *ObjectDataPayload, rt: *JSRuntime) void`。
- **作用**：清包装对象的可选 data 槽。
- **实现**：destroyOptionalValue(data)。
- **所有权 / 错误 / 调用**：不调用值转换、析构或 RC release，也不释放 payload cell。

### `ObjectDataPayload.traceChildEdges` (`src/core/object_payloads.zig:822`)

- **签名**：`pub fn traceChildEdges(self: *ObjectDataPayload, visitor: anytype) !void`。
- **作用**：访问非空 data 值。
- **实现**：traceOptValue(visitor,&data)。
- **所有权 / 错误 / 调用**：直接使用真实槽地址，错误传播；不检查具体包装 class。

### `WeakRefPayload.destroy` (`src/core/object_payloads.zig:831`)

- **签名**：`pub fn destroy(self: *WeakRefPayload, rt: *JSRuntime) void`。
- **作用**：清弱目标 identity 并释放辅助引用。
- **实现**：rt.clearWeakIdentitySlot 先摘除非空 identity，再 releaseWeakIdentity。
- **所有权 / 错误 / 调用**：object identity release 无操作，symbol 维护弱引用计数；不清 weak_holder_link、不从 holder 链注销，外层负责。

### `WeakRefPayload.traceChildEdges` (`src/core/object_payloads.zig:835`)

- **签名**：`pub fn traceChildEdges(self: *const WeakRefPayload, visitor: anytype) !void`。
- **作用**：不把弱目标或 holder 链作为强边枚举。
- **实现**：空体，忽略 self/visitor。
- **所有权 / 错误 / 调用**：不等于执行 weak target 判活或清除；这些阶段由 runtime/collector 处理。

### `VarRefPayload.destroy` (`src/core/object_payloads.zig:848`)

- **签名**：`pub fn destroy(self: *VarRefPayload, rt: *JSRuntime) void`。
- **作用**：清可选 value 并恢复三个标志默认值。
- **实现**：destroyOptionalValue 后 self.*=.{}。
- **所有权 / 错误 / 调用**：此 payload 不是独立 VarRef cell，不执行 close 或释放 cell；全部 flag 恢复 false。

### `VarRefPayload.traceChildEdges` (`src/core/object_payloads.zig:853`)

- **签名**：`pub fn traceChildEdges(self: *VarRefPayload, visitor: anytype) !void`。
- **作用**：枚举可选 value 槽。
- **实现**：traceOptValue(visitor,&value)。
- **所有权 / 错误 / 调用**：is_const/is_function_name/is_deletable 为标量，不参与边枚举；不做 TDZ 或写权限检查。

### `FinalizationRegistryPayload.destroy` (`src/core/object_payloads.zig:869`)

- **签名**：`pub fn destroy(self: *FinalizationRegistryPayload, rt: *JSRuntime) void`。
- **作用**：清 cleanup callback/realm，并清理全部 registration cell 与 backing。
- **实现**：先清 callback 和 realm.ptr，摘除 cells/容量，再逐个 entry.destroy 释放弱 identity/预留槽，按旧 capacity（否则 len）释放数组，最后 self.*=.{}。
- **所有权 / 错误 / 调用**：不运行 cleanup callback、不直接析构 realm；RealmRef.deinit 只置空。最终弱链字段也清零，但不代替外层先注销 holder 的步骤；active/pending 预留回收遵循队列尚在的条件。

### `FinalizationRegistryPayload.traceChildEdges` (`src/core/object_payloads.zig:885`)

- **签名**：`pub fn traceChildEdges(self: *FinalizationRegistryPayload, visitor: anytype) !void`。
- **作用**：访问注册表 realm、cleanup callback 和 registration cell。
- **实现**：先把 realm.ptr 地址传 callVisitRealm（即使当前为空），再访问非空 callback，最后逐个 callVisitFinalizationCell。
- **所有权 / 错误 / 调用**：不在本函数强标 target/token；held_value 是否追踪由 cell visitor 结合状态决定。回调可更新实际字段，错误立即传播。

### `StdFilePayload.destroy` (`src/core/object_payloads.zig:899`)

- **签名**：`pub fn destroy(self: *StdFilePayload) void`。
- **作用**：重置 file 指针与两个标志。
- **实现**：self.*=.{}。
- **所有权 / 错误 / 调用**：没有 fclose/pclose 调用；不能把此方法描述为关闭文件。宿主资源关闭须由具体 finalizer/显式关闭路径承担。

### `StdFilePayload.traceChildEdges` (`src/core/object_payloads.zig:903`)

- **签名**：`pub fn traceChildEdges(self: *const StdFilePayload, visitor: anytype) !void`。
- **作用**：为不含 GC 强边的 FILE 状态提供空访问接口。
- **实现**：忽略 self 和 visitor。
- **所有权 / 错误 / 调用**：FILE 指针不是 JS 值边；不验证或关闭文件。

### `DisposableStackPayload.destroy` (`src/core/object_payloads.zig:942`)

- **签名**：`pub fn destroy(self: *DisposableStackPayload, rt: *JSRuntime) void`。
- **作用**：摘除资源表并清异步 dispose 能力和状态。
- **实现**：resources 置空、capacity 置零，清 resolve/reject/error 三槽，再整体默认初始化。
- **所有权 / 错误 / 调用**：不调用 resource.method，不执行 ECMAScript disposal，不释放 subordinate GC cell；disposed 最终恢复 false，而不是标记为已成功 dispose。

### `DisposableStackPayload.traceChildEdges` (`src/core/object_payloads.zig:952`)

- **签名**：`pub fn traceChildEdges(self: *DisposableStackPayload, visitor: anytype) !void`。
- **作用**：枚举资源 backing、有效资源值/方法及异步 dispose 槽。
- **实现**：capacity 非零就报告 storageCell，即使 len 为零；逐个有效 resource 访问 value/method，随后访问非空 resolve/reject/error。
- **所有权 / 错误 / 调用**：kind/hint/method_kind/disposed 是标量，不影响本函数边枚举；不调用方法，错误立即停止遍历。

### `GlobalPayload.destroy` (`src/core/object_payloads.zig:976`)

- **签名**：`pub fn destroy(self: *GlobalPayload, _: *JSRuntime) void`。
- **作用**：清全局对象的未初始化绑定侧表指针。
- **实现**：self.*=.{}，runtime 未使用。
- **所有权 / 错误 / 调用**：不销毁侧表对象或 realm；本 payload 只有 uninitialized_vars，intrinsics 等 realm 状态不在这里。

### `GlobalPayload.traceChildEdges` (`src/core/object_payloads.zig:980`)

- **签名**：`pub fn traceChildEdges(self: *GlobalPayload, visitor: anytype) !void`。
- **作用**：访问 uninitialized_vars 对象边。
- **实现**：直接将可空对象指针字段地址传 callVisitObject。
- **所有权 / 错误 / 调用**：即使字段 null 也分派回调，由 visitor 处理空指针；修改可回写真实字段，错误传播。

### `RealmRecordPayload.destroy` (`src/core/object_payloads.zig:991`)

- **签名**：`pub fn destroy(self: *RealmRecordPayload) void`。
- **作用**：清 realm record 的追踪指针。
- **实现**：realm.deinit 后整体默认初始化。
- **所有权 / 错误 / 调用**：RealmRef.deinit 只置 null，不执行引用计数或同步销毁 context；不释放 record payload 自身。

### `RealmRecordPayload.traceChildEdges` (`src/core/object_payloads.zig:996`)

- **签名**：`pub fn traceChildEdges(self: *RealmRecordPayload, visitor: anytype) !void`。
- **作用**：报告 realm record 引用的 realm。
- **实现**：borrow 得到局部可空指针，将局部地址传 callVisitRealm。
- **所有权 / 错误 / 调用**：与直接传 realm.ptr 的接口不同，visitor 修改局部指针不会回写 payload；此方法不创建独立 GC 根。

### `PromisePayload.destroy` (`src/core/object_payloads.zig:1016`)

- **签名**：`pub fn destroy(self: *PromisePayload, rt: *JSRuntime) void`。
- **作用**：清 Promise 结果、reaction 状态及订阅列表。
- **实现**：清 result/reaction_callback/reaction_arg，reactions 置空、capacity 置零，is_rejected/atomics_wait_async 置 false。
- **所有权 / 错误 / 调用**：不执行 reaction、resolve/reject 或取消宿主等待；订阅 backing 是 GC cell，不手还，也不遍历销毁订阅值。

### `PromisePayload.traceChildEdges` (`src/core/object_payloads.zig:1028`)

- **签名**：`pub fn traceChildEdges(self: *PromisePayload, visitor: anytype) !void`。
- **作用**：枚举 Promise 的值槽、订阅 backing 与有效订阅值。
- **实现**：先访问三个 optional；capacity 非零时报告 storageCell，再遍历 reactions 的有效 slice。
- **所有权 / 错误 / 调用**：len=0 且 capacity>0 时仍保活 backing；不遍历未发布容量部分。visitor 缺 storageCell 可跳过该回调，任一步错误中止后续遍历。

### `RegExpLegacyStatics.destroy` (`src/core/object_payloads.zig:1060`)

- **签名**：`pub fn destroy(self: *RegExpLegacyStatics, rt: *JSRuntime) void`。
- **作用**：清 legacy regexp 匹配快照并恢复默认状态。
- **实现**：清五个 optional 字段和全部九个 captures，然后整体默认初始化。
- **所有权 / 错误 / 调用**：不按 capture_slot_count 缩短销毁遍历；计数与 lazy 匹配元数据也清零。无字符串 RC release，不分配或执行匹配。

### `FunctionRarePayload.destroy` (`src/core/object_payloads.zig:1116`)

- **签名**：`pub fn destroy(self: *FunctionRarePayload, rt: *JSRuntime) void`。
- **作用**：清 native/closure 冷状态与值槽。
- **实现**：清 source、realm_global、proxy revoke、Promise 能力/状态/finally、async dispose/continuation 共十二个 optional 值，随后 self.*=.{}。
- **所有权 / 错误 / 调用**：整体重置恢复各 marker/tag 默认值与 invalid_class_id；不调用 revoke/Promise/dispose 回调，不释放 payload 自身。

### `FunctionRarePayload.traceChildEdges` (`src/core/object_payloads.zig:1132`)

- **签名**：`pub fn traceChildEdges(self: *FunctionRarePayload, visitor: anytype) !void`。
- **作用**：枚举十二个可选冷状态值。
- **实现**：顺序访问 source、realm_global、proxy_revoke_target、promise_capability_slot、resolving target/state、combinator state、finally payload/callback/constructor、async_dispose_stack、async_function_continuation。
- **所有权 / 错误 / 调用**：enum/布尔/数值 marker 不作为边；参数是真实值槽地址，可由 visitor 更新，错误立即传播。

### `FunctionPayload.destroyRare` (`src/core/object_payloads.zig:1176`)

- **签名**：`fn destroyRare(self: *FunctionPayload, rt: *JSRuntime) void`。
- **作用**：摘除并释放 native 的独立 rare 分配。
- **实现**：rare 非空时先清 self.rare，再 rare.destroy，最后 rt.memory.destroy(FunctionRarePayload,rare)。
- **所有权 / 错误 / 调用**：与 BytecodeFunctionAux 内嵌 rare 的清理不同，这里确实归还 rare 的普通分配；不释放 FunctionPayload 自身。

### `FunctionPayload.destroyNative` (`src/core/object_payloads.zig:1184`)

- **签名**：`pub fn destroyNative(self: *FunctionPayload, rt: *JSRuntime) void`。
- **作用**：清 native realm/dispatch atom 并销毁 rare。
- **实现**：realm.deinit、native_dispatch_name=null_atom，随后 destroyRare。
- **所有权 / 错误 / 调用**：不会重置 call_cache、host/native id、TypedArray 元数据或 borrowed holder 缓存；dispatch atom 仅清字段，没有注释所称的逐 atom free，realm 也无 RC release。

### `FunctionPayload.traceNativeRealm` (`src/core/object_payloads.zig:1191`)

- **签名**：`pub fn traceNativeRealm(self: *FunctionPayload, visitor: anytype) !void`。
- **作用**：报告 native realm 和 dispatch atom。
- **实现**：先以 realm.ptr 的实际地址调用 callVisitRealm，再按值调用 atom.callVisitAtom(native_dispatch_name)。
- **所有权 / 错误 / 调用**：不枚举 rare，外层 Object 负责另行访问；realm 可被回写，atom 按 id 传入。包括 null realm/null_atom 的处理由 visitor 决定。

### `BytecodeFunctionAux.destroy` (`src/core/object_payloads.zig:1212`)

- **签名**：`pub fn destroy(self: *BytecodeFunctionAux, rt: *JSRuntime) void`。
- **作用**：清 closure home object 与内嵌 rare 状态。
- **实现**：home_object=null，调用 rare.destroy。
- **所有权 / 错误 / 调用**：不直接释放 aux GC cell，也不把内嵌 rare 当独立分配销毁；home object 只丢追踪边。

### `BytecodeFunctionStorage.captureSlots` (`src/core/object_payloads.zig:1229`)

- **签名**：`pub inline fn captureSlots(self: *const BytecodeFunctionStorage) []?*var_ref_mod.VarRef`。
- **作用**：借用已安装的可空 capture 指针数组。
- **实现**：var_refs 为 emptyVarRefs 哨兵则返回空；无 FunctionBytecode 也返回空；否则以 fb.closureVarCount 截取指针 slice。
- **所有权 / 错误 / 调用**：即使 FB 需要 capture，构造期哨兵仍返回空；不验证底层容量或逐槽非空，不分配或建立根。

### `BytecodeFunctionStorage.captureSlice` (`src/core/object_payloads.zig:1240`)

- **签名**：`pub inline fn captureSlice(self: *const BytecodeFunctionStorage) []*var_ref_mod.VarRef`。
- **作用**：把完成初始化的 capture 表作为非空指针 slice 借出。
- **实现**：无 FB 返回空；取 captureSlots，Debug/ReleaseSafe 验证长度等于 closureVarCount 且各槽非 null；空则返回空，否则重解释指针类型。
- **所有权 / 错误 / 调用**：发布构建不逐槽验证；调用方必须遵守初始化完成与 backing 容量合同，const self 不使返回的 capture 指针数组只读。

### `BytecodeFunctionStorage.emptyVarRefs` (`src/core/object_payloads.zig:1252`)

- **签名**：`pub inline fn emptyVarRefs() [*]?*var_ref_mod.VarRef`。
- **作用**：返回空 capture 表的非空哨兵地址。
- **实现**：以 @alignOf(?*VarRef) 的整数值构造指针。
- **所有权 / 错误 / 调用**：不是已分配数组，不能解引用；captureSlots 通过相等比较识别，不对任何真实 cell 形成根。

## `object_gc.zig`

TGC S4-e spec 2.5 抽空了以该文件命名的死亡侧机械。只留 FR 清理入队。

### `enqueueFinalizationCleanup` (`src/core/object_gc.zig:15`)

- **签名**：`pub fn enqueueFinalizationCleanup( rt: *JSRuntime, payload: *const FinalizationRegistryPayload, held_value: JSValue, ) void`。
- **作用**：尝试为一条 FR held_value 安排 cleanup job。
- **实现**：无 callback 时，queue.capacity 非零则归还一个预留槽并返回；有 callback 必须存在 payload.realm。reserved_entries 非零走不分配的 enqueueFinalizationJobReserved，否则调用可分配的 enqueueFinalizationJobForRealm 并忽略错误。
- **所有权 / 错误 / 调用**：选择 registry 所存 realm，不从 callback 推导；没有在本函数标记 cell 状态或清 held_value。正常收集使用预留槽，fallback 仅由 reserved_entries==0 触发，并不检查是否 teardown。fallback 失败无错误上报，不能保证每次调用都成功入队或一概不分配。

## 覆盖核对

- 清单函数数: 84（`src/core/object_gc.zig` 1 + `src/core/object_payloads.zig` 83）
- 本文标题覆盖: 84
- 未覆盖: 无
