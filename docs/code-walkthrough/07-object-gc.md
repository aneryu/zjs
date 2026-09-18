# 07 — 对象析构与 tracing（`src/core/object.zig`）

常规 sweep 依据 finalizer 标记选择需要资源清理的对象；普通对象的属性 cell、dense backing、a 类 payload 交 GC 回收。但 destroyFromHeader 本身没有“无 finalizer 则拒绝调用”的限制：整体 teardown 与构造失败清理也可调用它。WeakRef 使用身份 token，不再以保留对象尸体维持身份。

`traceChildEdgesFallible` 是子边权威。普通 `class_id==object && kind==none` 只 mark Shape+属性（外加空的 iterator-next 侧表检查）后返回，对齐 qjs OBJECT arm。

---


### `destroyDetachedClassPayload` (`src/core/object.zig:172`)

- **签名**：`pub fn destroyDetachedClassPayload(rt: *JSRuntime, class_id: class.ClassId, payload_kind: class.PayloadKind, payload: *class.Payload) void`。
- **作用**：断开payload指针并清理需要显式析构的外部payload。
- **实现**：payload为空返回，否则保存ptr并先置原槽null。tracer-owned或none分类直接返回；iterator先releaseIteratorCollectionCursor，再typed.destroy(rt)和memory.destroy；collection/finalization_registry/buffer/typed_array/weak_ref/generator同样destroy(rt)后memory.destroy；std_file调用destroy()后memory.destroy，realm_record调用destroy()后rt.destroyRuntime，function调用destroyNative(rt)后memory.destroy。
- **所有权 / 错误 / 调用**：tracer-owned分类只断开引用，不逐字段清空或手动释放cell；inline promise/regexp也在该提前返回分类。其它分支要求payload_kind/class_id与实际存储匹配，先置null防重入重复销毁；无可恢复错误返回，不意味着任意指针/kind组合安全。

### `Object.enqueueDeferredStdFileClose` (`src/core/object.zig:2635`)

- **签名**：`fn enqueueDeferredStdFileClose(self: *Object, rt: *JSRuntime) void`。
- **作用**：将非stdio文件从payload移交延后关闭流程。
- **实现**：无stdFilePayload、file为空或is_stdio时返回；其它先payload.file=null，再runtime.enqueueDeferredStdFileClose(rt,file,is_popen)。
- **所有权 / 错误 / 调用**：本函数不直接执行close，先断开字段避免再次提交；是否排队或其它处理由runtime helper决定。

### `Object.owesFinalizerWork` (`src/core/object.zig:2653`)

- **签名**：`fn owesFinalizerWork(rt: *JSRuntime, self: *const Object) bool`。
- **作用**：依据当前状态重算对象是否有析构工作。
- **实现**：依次检查payload责任、weak id/borrowed holder、weak holder类、global、动态class；再查destructionPlan.has_payload_finalizer及cached iterator next entry。任一满足true，否则false。
- **所有权 / 错误 / 调用**：不读取needs_finalizer来决定结果，用于独立核对该位。缓存entry存在即算责任，即使其value为null；动态class无条件算责任。

### `Object.auditNeedsFinalizerBit` (`src/core/object.zig:2677`)

- **签名**：`fn auditNeedsFinalizerBit(rt: *JSRuntime, self: *Object) void`。
- **作用**：验证有析构责任的对象已置位，并统计plain sticky位。
- **实现**：读取header needs_finalizer；owesFinalizerWork为true但未置位时输出对象/class/payload等诊断并panic。无责任且已置位、plain Object、payload none时饱和增加plain_objects_with_finalizer_bit。
- **所有权 / 错误 / 调用**：函数内部无Debug开关，destroyFromHeader调用处才以Debug门控；不清位或修复对象。反向计数只覆盖所列plain状态，不是全部多余位。

### `Object.destroyFromHeader` (`src/core/object.zig:2713`)

- **签名**：`pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) align(16) void`。
- **作用**：记录析构入口统计并交完整慢析构路径。
- **实现**：fromHeader取得对象，Debug先auditNeedsFinalizerBit；object_destructor_calls饱和加一，plain Object且payload为none/tracer-owned、未标finalizer时另增加plain_object_destructor_calls；最后destroyFromHeaderSlow。
- **所有权 / 错误 / 调用**：入口本身不检查是否condemned或阻止重入，不等于所有plain对象都不可能到达此函数；常规bitmap路线避免调用，显式清理等调用仍可计入。慢路径资源/撤账顺序另见对应函数。

### `destroyFromHeaderSlow` (`src/core/object.zig:2733`)

- **签名**：`noinline fn destroyFromHeaderSlow(rt: *JSRuntime, header: *gc.Header) void`。
- **作用**：按资源、登记、原始存储顺序完成对象析构。
- **实现**：先置finalizing，保存class与destructionPlan并计算accounted尺寸。注销weak holder和borrowed holder，global按需清借用引用，std_file提交延后关闭；清property存储、dropUnshared旧Shape并换成finalizingShape，刷新摘要。需要class payload finalizer时先执行它；再清iterator缓存，按剩余payload kind析构资源，移除weak identity，unregisterObjectWithBytes，freeObjectAllocation，最后releaseObjectDefinition。
- **所有权 / 错误 / 调用**：不是只摘链或延后保留weak husk，原始存储本次释放。class callback观察到属性已清空、Shape为tombstone，但对象尚未完成GC撤账；helper未做重入早退。GC管理的property/array/payload cell不逐一手动free，资源载体另走显式析构；class定义保护直到对象存储释放后才归还。

### `Object.finalizeClassPayload` (`src/core/object.zig:2870`)

- **签名**：`fn finalizeClassPayload(self: *Object, rt: *JSRuntime, generation: u64, inline_payload: bool) void`。
- **作用**：调用注册class finalizer并处理残留payload。
- **实现**：先保存原payload kind及slot，runPayloadFinalizer(class,generation,rt,self,slot)，断言返回true。inline payload只清slot/kind；其它先取回调后slot剩余指针、清对象slot/kind，再destroyDetachedClassPayload按原kind清理残余。
- **所有权 / 错误 / 调用**：回调可能改写payload槽；不是始终销毁回调前指针。inline字节属于Object原始分配，不能单独free。无error返回，generation/class有效性由class表协议保障。

### `Object.clearBorrowedReferencesForDestroyedObject` (`src/core/object.zig:2894`)

- **签名**：`fn clearBorrowedReferencesForDestroyedObject(rt: *JSRuntime, destroyed: *Object) void`。
- **作用**：为被销毁global触发裸地址借用引用清理。
- **实现**：deinit时返回；以header地址清最低位构造identity，无holders或非global返回。已有cleanup作用域时enqueue，OOM则直接single清理后返回；否则begin/defer end，enqueue或fallback，再drain。
- **所有权 / 错误 / 调用**：此identity不是generation-bearing weak token；嵌套调用主要追加队列，外层负责排空。OOM不忽略清理，而是同步fallback；不作为所有对象的通用弱引用处理器。

### `Object.drainBorrowedWeakCleanup` (`src/core/object.zig:2918`)

- **签名**：`pub fn drainBorrowedWeakCleanup(rt: *JSRuntime) void`。
- **作用**：按runtime当前identity批次调用holder清理。
- **实现**：scanned_identity_count从0开始；小于当前identity count时以runtime_batch起始索引执行matcher扫描，结束后把scanned设为此时最新count再检查。
- **所有权 / 错误 / 调用**：函数本身不begin/end作用域或清空队列，依赖调用方管理。使用可增长runtime批次，不是复制固定identity快照。

### `Object.clearBorrowedReferencesForDestroyedIdentity` (`src/core/object.zig:2926`)

- **签名**：`fn clearBorrowedReferencesForDestroyedIdentity(rt: *JSRuntime, destroyed_identity: usize) void`。
- **作用**：对单个裸identity执行borrowed holder扫描。
- **实现**：委托clearBorrowedReferencesForMatcher(.single=destroyed_identity)。
- **所有权 / 错误 / 调用**：不排队、不建立新identity，也不验证该地址仍有存储。

### `Object.clearBorrowedReferencesForMatcher` (`src/core/object.zig:2930`)

- **签名**：`fn clearBorrowedReferencesForMatcher(rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void`。
- **作用**：按identity匹配器清理可能随回调变化的borrowed holder列表。
- **实现**：先修复cached indices，创建本次扫描共享的finalization_enqueue_blocked=false；逐项跳过无相关状态者，否则调用其清理。当前项仍在同索引则前进；列表变化后重新查current索引，已移除则留当前位置处理替入项，仍存在则调整游标到其后。
- **所有权 / 错误 / 调用**：不以固定长度for遍历；清理回调可能修改列表。局部blocked状态传给各holder处理，具体弱表/FR行为由下层实现；不在此直接释放Object。

### `Object.compactBorrowedReferenceHolders` (`src/core/object.zig:2963`)

- **签名**：`fn compactBorrowedReferenceHolders(rt: *JSRuntime) void`。
- **作用**：修复borrowed holder的缓存索引。
- **实现**：遍历当前列表并setBorrowedReferenceHolderIndex(index)。
- **所有权 / 错误 / 调用**：当前实现不删除或压缩任何entry，名称延续旧weak husk机制；长度和顺序均不在此改变。

### `Object.runtimeBorrowedReferenceHolderIndex` (`src/core/object.zig:2969`)

- **签名**：`fn runtimeBorrowedReferenceHolderIndex(rt: *JSRuntime, object: *Object) ?usize`。
- **作用**：取得并必要时修复holder在runtime列表的索引。
- **实现**：未标holder返回null；缓存索引范围与指针匹配则返回，否则线性扫描，找到后写回缓存；未找到null。
- **所有权 / 错误 / 调用**：缓存不可信时会验证，不单凭缓存访问；未找到不自动清flag或插入列表。

### `Object.pruneBorrowedReferenceHolderIfEmpty` (`src/core/object.zig:2983`)

- **签名**：`pub fn pruneBorrowedReferenceHolderIfEmpty(self: *Object, rt: *JSRuntime) void`。
- **作用**：从runtime列表移除已无borrowed状态的holder。
- **实现**：未标holder返回；hasBorrowedReferences为false才unregisterBorrowedReferenceHolder。
- **所有权 / 错误 / 调用**：不销毁对象或payload，是否为空依赖该谓词的语义，不等于JS对象没有普通属性。

### `Object.hasBorrowedReferences` (`src/core/object.zig:2988`)

- **签名**：`fn hasBorrowedReferences(self: *const Object, _: *JSRuntime) bool`。
- **作用**：查询对象是否仍有需要borrowed清理的弱状态。
- **实现**：WeakRef identity非null、collection weak_entries非空或FR cells非空任一满足true，其余false。
- **所有权 / 错误 / 调用**：不检查每个cell是否active，也不遍历普通强属性；rt参数当前未用。

### `Object.mayContainBorrowedReferences` (`src/core/object.zig:3001`)

- **签名**：`fn mayContainBorrowedReferences(self: *const Object, _: *JSRuntime) bool`。
- **作用**：筛选borrowed清理扫描候选。
- **实现**：当前与hasBorrowedReferences相同，检查WeakRef identity、weak_entries长度和FR cells长度。
- **所有权 / 错误 / 调用**：不是更宽泛的class判断，pending/queued等仍计入非空cells；rt未使用。

### `BorrowedIdentityMatcher.matches` (`src/core/object.zig:3018`)

- **签名**：`inline fn matches(self: BorrowedIdentityMatcher, rt: *JSRuntime, identity: usize) bool`。
- **作用**：按单identity或runtime批次匹配身份数值。
- **实现**：single直接整数相等；runtime_batch以起始索引调用borrowedWeakCleanupIdentityMatchesSlice。
- **所有权 / 错误 / 调用**：不解引用identity或核对generation；runtime_batch读取runtime当前集合，不持有独立快照。

### `Object.clearBorrowedReferencesToDestroyedIdentities` (`src/core/object.zig:3026`)

- **签名**：`fn clearBorrowedReferencesToDestroyedIdentities( self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher, finalization_enqueue_blocked: *bool, ) void`。
- **作用**：清理匹配弱状态并视结果注销空holder。
- **实现**：先clearWeakIdentities(rt,matcher,blocked)，再pruneBorrowedReferenceHolderIfEmpty。
- **所有权 / 错误 / 调用**：共享blocked指针可能被更新；自身不负责建立cleanup作用域或释放Object。

### `Object.clearWeakIdentities` (`src/core/object.zig:3036`)

- **签名**：`fn clearWeakIdentities( self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher, finalization_enqueue_blocked: *bool, ) void`。
- **作用**：清理匹配WeakRef、weak collection及FinalizationRegistry状态。
- **实现**：WeakRef命中则clearWeakIdentitySlot。weak_entries稳定压缩保留未命中项，命中项releaseWeakIdentity，长度变化则clearCollectionIndex。FR逐cell先遇pending置共享blocked；无target或不匹配保留；匹配queued直接丢出有效slice；active先转pending，blocked时保留，否则先将原表项标queued再调用enqueueFinalizationCleanup，局部转queued后destroy。pending保留，最后缩短cells。
- **所有权 / 错误 / 调用**：不RC free weak collection value；FR pending会阻止本批后续active入队。enqueue helper为void：通常使用预留job槽，但无预留的fallback可能吞分配错误，因此不能写成此处有错误回滚/重试保证。匹配queued分支不再次cell.destroy，不能概括为所有移除项均在此释放identity。

### `Object.weakIdentityIsLive` (`src/core/object.zig:6713`)

- **签名**：`fn weakIdentityIsLive(rt: *const JSRuntime, identity: usize) bool`。
- **作用**：按弱 identity 编码查询当前身份。
- **实现**：奇数 identity 解出 atom，超出 Atom 范围 false，否则只检查 atom kind==symbol；偶数 identity 查询 liveObjectFromWeakIdentity 是否非空。
- **所有权 / 错误 / 调用**：symbol 分支不是完整 symbolValueIfLive/标记状态检查；本 helper 不注册、retain 或复活目标。

### `Object.objectFromValue` (`src/core/object.zig:6724`)

- **签名**：`fn objectFromValue(stored: JSValue) ?*Object`。
- **作用**：从引用值中提取 Object 指针。
- **实现**：无 refHeader 或 header kind 非 object 返回 null，否则 fromHeader。
- **所有权 / 错误 / 调用**：先检查 header kind，不能把任意堆引用解释为 Object；不分配或延长存活。

### `Object.markClassPayload` (`src/core/object.zig:6730`)

- **签名**：`fn markClassPayload(self: *Object, rt: *JSRuntime, visitor: *class.PayloadVisitor) bool`。
- **作用**：在对象布局允许时调用 class 的 payload 标记入口。
- **实现**：Array 和字节码函数直接 false；slots2 要求 kind 非 none 且 payloadSlot 非空，其他布局只要求 arm 非空，然后调用 rt.classes.markPayload 并返回其 bool。
- **所有权 / 错误 / 调用**：非 slots2 的动态/嵌入 class 即使 kind==none 也可有 payload；这里只分派 payload，不遍历普通属性或 shape，不把 bool 解释成整对象可达性。

### `Object.collectReachableObjects` (`src/core/object.zig:6753`)

- **签名**：`fn collectReachableObjects(rt: *JSRuntime, visited: *ObjectVisitSet, current: *Object) ObjectGraphError!void`。
- **作用**：按对象地址去重后递归收集其直接子对象。
- **实现**：visited.getOrPut(current 地址) 失败传播，已存在则返回；新插入则 collectDirectChildObjects(rt,visited)。
- **所有权 / 错误 / 调用**：先插入再递归以截断环；递归错误不回滚 visited，集合可能只完成部分遍历。

### `Object.ClassPayloadTraceAdaptor` (`src/core/object.zig:6759`)

- **签名**：`pub fn ClassPayloadTraceAdaptor(comptime VisitorType: type) type`。
- **作用**：生成将擦除类型的 payload 回调转接到泛型 visitor 的结构体类型。
- **实现**：返回带 visitor 字段及 visitValue/visitObject 两个静态回调的匿名结构；每个回调在编译期判断底层 visitor 是否支持相应方法和 error union 返回。
- **所有权 / 错误 / 调用**：按 VisitorType 本身保存值或指针；错误只有在 VisitorType 为指针且 pointee 有 err 字段时才记入该字段，其他 fallible 情况被 catch 后不传播。调用方必须选用合适的错误通道。

### `ClassPayloadTraceAdaptor.visitValue` (`src/core/object.zig:6763`)

- **签名**：`pub fn visitValue(context_ptr: *anyopaque, value_ptr: *anyopaque) void`。
- **作用**：将 class 的 visitValue 回调转交泛型 visitor。
- **实现**：把 context 转成 adaptor，输入地址转为 *JSValue；CleanType 为 visitor pointee 或值类型，无对应方法则无操作。有方法时按其返回类型直接调用或 catch；catch 仅在指针 visitor 且有 err 字段时保存错误。
- **所有权 / 错误 / 调用**：传递实际槽地址，不复制其引用值；错误不会经 void 回调返回，缺少 err 通道会丢弃错误，也不因旧错误而停止后续调用。

### `ClassPayloadTraceAdaptor.visitObject` (`src/core/object.zig:6783`)

- **签名**：`pub fn visitObject(context_ptr: *anyopaque, object_ptr: *anyopaque) void`。
- **作用**：将 class 的 visitObject 回调转交泛型 visitor。
- **实现**：把 context 转成 adaptor，输入地址转为 *?*Object；CleanType 为 visitor pointee 或值类型，无对应方法则无操作。有方法时按其返回类型直接调用或 catch；catch 仅在指针 visitor 且有 err 字段时保存错误。
- **所有权 / 错误 / 调用**：传递实际槽地址，不复制其引用值；错误不会经 void 回调返回，缺少 err 通道会丢弃错误，也不因旧错误而停止后续调用。

### `Object.traceClassPayloadRootEdges` (`src/core/object.zig:6809`)

- **签名**：`pub fn traceClassPayloadRootEdges(self: *Object, rt: *JSRuntime, root_visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：只把 class payload 声明的边交给 RootVisitor。
- **实现**：建立本地 adaptor 和 class.PayloadVisitor，经 markClassPayload 调用 class 标记；忽略其 bool，最后若 adaptor.err 非空则返回记录的错误。
- **所有权 / 错误 / 调用**：不追踪 wrapper 的普通属性/shape；供 deferred payload finalizer 的临时根合同使用。回调错误先记录，不立即终止 class 标记，后续错误可能覆盖先前错误。

### `traceClassPayloadRootEdges.Adaptor.visitValue` (`src/core/object.zig:6814`)

- **签名**：`fn visitValue(context_ptr: *anyopaque, value_ptr: *anyopaque) void`。
- **作用**：把 class payload 槽转接到 RootVisitor.value。
- **实现**：将擦除的 context/slot 恢复为本地 adaptor 与 *JSValue，调用 visitor.value，catch 时记录到 adaptor.err。
- **所有权 / 错误 / 调用**：void 回调不立即传播错误；外层 markClassPayload 返回后统一检查，后续错误可覆盖已有值。

### `traceClassPayloadRootEdges.Adaptor.visitObject` (`src/core/object.zig:6822`)

- **签名**：`fn visitObject(context_ptr: *anyopaque, object_ptr: *anyopaque) void`。
- **作用**：把 class payload 槽转接到 RootVisitor.optionalObject。
- **实现**：将擦除的 context/slot 恢复为本地 adaptor 与 *?*Object，调用 visitor.optionalObject，catch 时记录到 adaptor.err。
- **所有权 / 错误 / 调用**：void 回调不立即传播错误；外层 markClassPayload 返回后统一检查，后续错误可覆盖已有值。

### `Object.isDetachedGeneratorShellForGc` (`src/core/object.zig:6840`)

- **签名**：`pub fn isDetachedGeneratorShellForGc(self: *const Object) bool`。
- **作用**：按 class/kind/accounting 位识别 detached generator shell。
- **实现**：class 为 generator 或 async_generator，kind 为 generator，且 header.heap_accounted 为 false 时 true。
- **所有权 / 错误 / 调用**：不验证 construction-root 成员资格、payload 指针或 execution 已初始化；是布局阶段判别，不是完整有效性证明。

### `Object.traceDetachedGeneratorShellEdges` (`src/core/object.zig:6850`)

- **签名**：`pub fn traceDetachedGeneratorShellEdges(self: *Object, visitor: anytype) !void`。
- **作用**：只追踪 detached generator shell 已初始化的 payload 边。
- **实现**：断言 generator/async_generator class、generator kind 与 !heap_accounted，再 generatorPayloadPtr().traceChildEdges(visitor)，错误传播。
- **所有权 / 错误 / 调用**：不访问此时尚未完成的 shape/property storage，也不把 shell 注册为普通 Object。

### `Object.recordTraceStorageFootprint` (`src/core/object.zig:6863`)

- **签名**：`pub fn recordTraceStorageFootprint(self: *const Object, rt: *const JSRuntime, recorder: anytype) void`。
- **作用**：向 recorder 报告对象追踪所用存储的分类、容量与模型触达范围。
- **实现**：先按 ordinary/no-payload、bytecode、fast-array、exotic 分类；记录含 metadata 的 Object 与 Shape，exact summary 时 Shape touched 不含属性描述符 FAM。非空属性表按 capacity/count 记录并报告 inline candidate；dense arm 按 JSValue 容量/有效项计量。字节码函数记录 capture backing 和可选 aux 后返回；其他 kind 分派记录 payload 及指定 backing。
- **所有权 / 错误 / 调用**：这是统计模型，不执行 mark，也不是实测内存读取或完整分配账本。全局 iterator-next 表只要非空便在每次调用报告，是否去重由 recorder 决定；零 live backing 被跳过。buffer/regexp/weak_ref/std_file 分支不另记 payload，不可据此断言无强边：RegExp 实际追踪 source/compiled_bytecode 字符串。builtin Promise 的 payload 已计入 body，故只另记 reactions。generator 总记录 execution 全分配，非 running_aliases 时再计未合并 stack/frame，避免把 combined backing 重计；async_queue 单独记录。

### `recordTraceStorageFootprint.Helper.allocation` (`src/core/object.zig:6867`)

- **签名**：`noinline fn allocation(rec: anytype, component: anytype, address: usize, allocated: usize, touched: usize) void`。
- **作用**：向 recorder 转交一个非零存储区域。
- **实现**：allocated 或 touched 为零则跳过；否则 noteAllocation(component,allocated,address,touched)。
- **所有权 / 错误 / 调用**：不验证地址、执行去重或计算实际访问次数；allocated 与 touched 是调用者提供的模型数值。

### `recordTraceStorageFootprint.Helper.backing` (`src/core/object.zig:6872`)

- **签名**：`fn backing(rec: anytype, address: usize, capacity: usize, live: usize, elem_size: usize) void`。
- **作用**：按元素容量与有效长度报告 payload backing。
- **实现**：capacity 或 live 为零则返回，否则用 capacity*elem_size 和 live*elem_size 调用 allocation，component 为 payload_backing。
- **所有权 / 错误 / 调用**：普通乘法不是 checked 算术；不校验 live<=capacity，也不计 GC metadata 前缀。

### `Object.traceUnusualPropertyFallible` (`src/core/object.zig:7058`)

- **签名**：`fn traceUnusualPropertyFallible(visitor: anytype, entry: *property.Entry, slot_flags: property.Flags) !void`。
- **作用**：追踪 accessor、VarRef 与 auto-init 属性的非普通数据边。
- **实现**：data 分支 unreachable；accessor 将 getter/setter 依次转换成临时值、visit 后同步回 entry。var_ref 把 cell.valueRef 交 visitor；auto_init 从 packed realm header 得 context，visitRealm 后要求非空并同步 header。
- **所有权 / 错误 / 调用**：错误立即传播，之前已同步的字段不回滚。VarRef 使用临时值且未回写 cell 指针；auto-init 要求 visitor 保持 realm 非空。不是调用 getter/setter 或执行属性初始化。

### `Object.tracePropertyEntriesFallible` (`src/core/object.zig:7082`)

- **签名**：`inline fn tracePropertyEntriesFallible( self: *Object, visitor: anytype, count: usize, comptime from_summary: bool, summary: u8, ) !void`。
- **作用**：按 summary 或 Shape flags 遍历有效属性边。
- **实现**：遍历前 count 个 storage entries；编译期 from_summary 决定 flags 来源。deleted 跳过，data 直接 visit 槽，其余委托 traceUnusualPropertyFallible。
- **所有权 / 错误 / 调用**：count 和 summary 一致性由调用方保证；错误传播，未访问的后续项不处理。扫描 flags 来自属性记录，不扫描容量余量。

### `Object.traceDataPropertyEntriesFallible` (`src/core/object.zig:7103`)

- **签名**：`inline fn traceDataPropertyEntriesFallible(self: *Object, visitor: anytype, count: usize) !void`。
- **作用**：追踪已知全部为 live data 的属性前缀。
- **实现**：遍历前 count 个 storage entries，逐一 callVisitValue(&slot.data)。
- **所有权 / 错误 / 调用**：不读取 flags 或跳过 deleted；只适用于调用方已证明的全 data 前缀，错误传播。

### `Object.tracePropertyEdgesFallible` (`src/core/object.zig:7108`)

- **签名**：`inline fn tracePropertyEdgesFallible(self: *Object, visitor: anytype) !void`。
- **作用**：保活外置属性 storage cell 并按紧凑 summary 追踪属性值。
- **实现**：prop_values 被判定为 external 时先 visitStorageCell；读取已屏蔽 remembered bit 的 traceShapeSummary。summary<=2 走全 data 路径，其他 exact summary 用其 count/flags，overflow 则用 shape.prop_count/flags。
- **所有权 / 错误 / 调用**：inline slots2 和空 sentinel 不是独立 cell；即使当前属性数为零，也需按 external 判定保活存储。不会扫描未提交到 summary/shape 的容量余量。

### `Object.traceChildEdgesFallible` (`src/core/object.zig:7144`)

- **签名**：`pub inline fn traceChildEdgesFallible(self: *Object, rt: *JSRuntime, visitor: anytype) !void`。
- **作用**：按对象布局追踪 shape、属性、存储 cell 与各类 payload 边。
- **实现**：先 visitShape。普通 object 且 kind none 仅扫属性及可选 iterator-next 缓存后返回。其余先报告 tracer-owned payload cell，处理 realm_record、native realm、global 与缓存，再属性和 ordinary/reaction payload；报告 dense storage cell 并扫 arrayElements，fast Array 到此返回。随后按 kind/class 扫 typed-array、object-data、async-resume、buffer、regexp；字节码函数另扫 capture cell/非空 VarRef、fb、HomeObject、aux cell/rare 后返回。其他对象继续扫 rare、bound、collection、FR、disposable、iterator、generator、arguments、var_ref、mapped-arguments、proxy、promise、weak-ref、std-file payload，最后 class 标记回调。
- **所有权 / 错误 / 调用**：具体哪些边是强/弱以及 visitor 支持哪些回调由 payload/helper 合同决定。FB 临时值和 HomeObject 会同步回字段，capture/mapped VarRef 临时值不会回写表。各 try 错误立即返回；class adaptor 错误依赖 pointer visitor.err 通道。函数不直接释放对象，也不等价于执行完整 GC。

### `traceChildEdgesFallible.Helper.callVisitObject` (`src/core/object.zig:7146`)

- **签名**：`inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void`。
- **作用**：转发到 object_payloads.callVisitObject 泛型访问 helper。
- **实现**：直接返回同名 helper(visitor,参数)。
- **所有权 / 错误 / 调用**：沿用底层 visitor 能力检测与错误协议；本层不提供新追踪语义或错误恢复。

### `traceChildEdgesFallible.Helper.callVisitValue` (`src/core/object.zig:7150`)

- **签名**：`inline fn callVisitValue(vis: anytype, val_ptr: anytype) !void`。
- **作用**：转发到 object_payloads.callVisitValue 泛型访问 helper。
- **实现**：直接返回同名 helper(visitor,参数)。
- **所有权 / 错误 / 调用**：沿用底层 visitor 能力检测与错误协议；本层不提供新追踪语义或错误恢复。

### `traceChildEdgesFallible.Helper.callVisitShape` (`src/core/object.zig:7154`)

- **签名**：`inline fn callVisitShape(vis: anytype, shape_ref: *shape.Shape) !void`。
- **作用**：转发到 object_payloads.callVisitShape 泛型访问 helper。
- **实现**：直接返回同名 helper(visitor,参数)。
- **所有权 / 错误 / 调用**：沿用底层 visitor 能力检测与错误协议；本层不提供新追踪语义或错误恢复。

### `traceChildEdgesFallible.Helper.callVisitRealm` (`src/core/object.zig:7158`)

- **签名**：`inline fn callVisitRealm(vis: anytype, ctx_ptr: *?*context_mod.RealmContext) !void`。
- **作用**：转发到 object_payloads.callVisitRealm 泛型访问 helper。
- **实现**：直接返回同名 helper(visitor,参数)。
- **所有权 / 错误 / 调用**：沿用底层 visitor 能力检测与错误协议；本层不提供新追踪语义或错误恢复。

### `traceChildEdgesFallible.Helper.traceOptValue` (`src/core/object.zig:7162`)

- **签名**：`inline fn traceOptValue(vis: anytype, opt_val: anytype) !void`。
- **作用**：转发到 object_payloads.traceOptValue 泛型访问 helper。
- **实现**：直接返回同名 helper(visitor,参数)。
- **所有权 / 错误 / 调用**：沿用底层 visitor 能力检测与错误协议；本层不提供新追踪语义或错误恢复。

### `Object.traceChildEdges` (`src/core/object.zig:7367`)

- **签名**：`pub inline fn traceChildEdges(self: *Object, rt: *JSRuntime, visitor: anytype) !void`。
- **作用**：调用可失败的统一对象边遍历。
- **实现**：直接返回 traceChildEdgesFallible(rt,visitor)。
- **所有权 / 错误 / 调用**：沿用相同分派、修改槽与错误协议，不额外分配或吞错。

### `Object.traceChildEdgesNoFail` (`src/core/object.zig:7371`)

- **签名**：`pub inline fn traceChildEdgesNoFail(self: *Object, rt: *JSRuntime, visitor: anytype) void`。
- **作用**：为保证不失败的 visitor 提供 void 遍历入口。
- **实现**：调用 traceChildEdgesFallible，任何返回错误均 catch unreachable。
- **所有权 / 错误 / 调用**：调用方必须保证 visitor 路径不会返回错误；不能给可能分配失败的图收集器用此入口来忽略 OOM。

### `Object.collectDirectChildObjects` (`src/core/object.zig:7379`)

- **签名**：`fn collectDirectChildObjects(self: *Object, rt: *JSRuntime, visited: *ObjectVisitSet) ObjectGraphError!void`。
- **作用**：用对象图收集 visitor 运行统一边遍历。
- **实现**：创建含 rt/visited/err 的 CollectVisitor 指针并传入 traceChildEdgesFallible；对象和值回调继续递归，weak collection entry 显式收集 value，FR cell 仅在 keepsHeldValuesAlive 时收集 held_value。
- **所有权 / 错误 / 调用**：虽名字含 Direct，回调会递归加入后继 Object；不是 GC 标记结果或全部 heap carrier 集合。visited 按 Object 地址去重，错误可能留下部分集合。

### `collectDirectChildObjects.CollectVisitor.visitObject` (`src/core/object.zig:7385`)

- **签名**：`pub fn visitObject(cv: *@This(), obj_ptr: *?*Object) !void`。
- **作用**：递归收集可选 Object 槽指向的对象。
- **实现**：槽为 null 则返回；有指针时还检查地址非零，再 collectReachableObjects。
- **所有权 / 错误 / 调用**：不改槽，递归及集合分配错误传播；不执行 GC pin。

### `collectDirectChildObjects.CollectVisitor.visitValue` (`src/core/object.zig:7392`)

- **签名**：`pub fn visitValue(cv: *@This(), val_ptr: *JSValue) !void`。
- **作用**：从值递归收集 Object 及字节码关联对象。
- **实现**：将 val_ptr.* 传给 collectValueObject。
- **所有权 / 错误 / 调用**：不修改值槽，不把所有 JSValue heap carrier 都加入 visited。

### `collectDirectChildObjects.CollectVisitor.visitWeakCollectionEntry` (`src/core/object.zig:7396`)

- **签名**：`pub fn visitWeakCollectionEntry(cv: *@This(), entry: *WeakCollectionEntry) !void`。
- **作用**：收集 weak collection entry 的 value 对象图。
- **实现**：直接 collectValueObject(entry.value)。
- **所有权 / 错误 / 调用**：此回调不检查 key identity 是否 live，不收集弱 key；不能把该图遍历当成 ephemeron 存活判定。

### `collectDirectChildObjects.CollectVisitor.visitFinalizationCell` (`src/core/object.zig:7400`)

- **签名**：`pub fn visitFinalizationCell(cv: *@This(), entry: *FinalizationRegistryCell) !void`。
- **作用**：收集仍需保活的 FR held_value 对象图。
- **实现**：keepsHeldValuesAlive() 为 true 才 collectValueObject(entry.held_value)。
- **所有权 / 错误 / 调用**：不收集 target/token weak identity 或调度 cleanup；错误传播。

### `Object.collectValueObject` (`src/core/object.zig:7410`)

- **签名**：`fn collectValueObject(rt: *JSRuntime, visited: *ObjectVisitSet, stored: JSValue) ObjectGraphError!void`。
- **作用**：从值识别需要递归的 Object 或 FunctionBytecode。
- **实现**：objectFromValue 成功则 collectReachableObjects 后返回；否则尝试 functionBytecodeFromValue，成功则 collectFunctionBytecodeChildObjects，其他值忽略。
- **所有权 / 错误 / 调用**：没有通用处理字符串、VarRef 或任意 GC carrier 的分支；不会将 FunctionBytecode 自身地址插入 ObjectVisitSet。

### `Object.collectFunctionBytecodeChildObjects` (`src/core/object.zig:7419`)

- **签名**：`fn collectFunctionBytecodeChildObjects(rt: *JSRuntime, visited: *ObjectVisitSet, function_bytecode: *const FunctionBytecode) ObjectGraphError!void`。
- **作用**：收集字节码 realm global 与常量池里的对象图。
- **实现**：有 realm/global 则 collectReachableObjects，随后逐项 cpoolSlice 调用 collectValueObject。
- **所有权 / 错误 / 调用**：不把 fb 自身加入 visited，不等于 FunctionBytecode 完整 GC edge walk；递归/集合错误传播。

### `Object.weakIdentityFromValue` (`src/core/object.zig:7429`)

- **签名**：`pub fn weakIdentityFromValue(rt: *JSRuntime, stored: JSValue) !?usize`。
- **作用**：取得 symbol 编码或按需登记 Object 的弱 identity。
- **实现**：asSymbolAtom 成功返回 (atom<<1)|1；否则 objectFromWeakCandidate 失败返回 null，成功则 try rt.registerWeakObjectIdentity。
- **所有权 / 错误 / 调用**：object 登记可能失败；此处不 retain identity、不创建强边，也不实现完整 CanBeHeldWeakly 语义检查。

### `Object.weakIdentityFromValuePeek` (`src/core/object.zig:7437`)

- **签名**：`pub fn weakIdentityFromValuePeek(rt: *const JSRuntime, stored: JSValue) ?usize`。
- **作用**：只查询已有弱 identity，不登记 Object。
- **实现**：symbol 直接编码；其他值尝试 Object 候选，成功则 rt.peekWeakObjectIdentity，否则 null。
- **所有权 / 错误 / 调用**：未登记 Object 返回 null；不会创建身份、分配或保证 symbol 当前仍可作为弱目标。

### `Object.objectFromWeakCandidate` (`src/core/object.zig:7443`)

- **签名**：`fn objectFromWeakCandidate(stored: JSValue) ?*Object`。
- **作用**：按引用 header kind 识别 Object 弱身份候选。
- **实现**：无 refHeader 或 kind 非 object 返回 null，否则 fromHeader。
- **所有权 / 错误 / 调用**：不是 JS 弱目标合法性的全部检查；不查询 condemned/liveness 或登记身份。

### `Object.objectIsCycleGarbage` (`src/core/object.zig:7452`)

- **签名**：`inline fn objectIsCycleGarbage(child: *const Object) bool`。
- **作用**：查询 Object header 的当前 condemned 标记。
- **实现**：直接 gc.headerCondemned(&child.header)。
- **所有权 / 错误 / 调用**：不遍历图或自行判断不可达，也不是 RC 计数判据；名称保留 cycle 历史术语。

### `Object.headerIsCycleGarbage` (`src/core/object.zig:7456`)

- **签名**：`inline fn headerIsCycleGarbage(header: *const gc.Header) bool`。
- **作用**：查询任意 GC header 的当前 condemned 标记。
- **实现**：直接返回 gc.headerCondemned(header)。
- **所有权 / 错误 / 调用**：不校验地址或对象种类，调用方保证有效 header 和收集阶段。

### `Object.clearValueReferenceToVisited` (`src/core/object.zig:7466`)

- **签名**：`fn clearValueReferenceToVisited( rt: *JSRuntime, stored: *JSValue, ) void`。
- **作用**：清除弱集合清扫路径中指向 condemned 对象的值。
- **实现**：若 valueReferencesVisited 则把槽置 undefined 并返回；否则 FunctionBytecode 值仅在其 header condemned 时清槽并递归清其引用。最后尝试 VarRef cell，若 cell 当前值直接引用 condemned Object/VarRef 则把 cell 值置 undefined。
- **所有权 / 错误 / 调用**：不释放 carrier 或执行 RC cascade；活的 FunctionBytecode 分支直接返回。此 helper 会修改仍存在的 VarRef 内容，递归字节码路径不维护独立 visited 集合。

### `Object.clearFunctionBytecodeReferencesToVisited` (`src/core/object.zig:7484`)

- **签名**：`fn clearFunctionBytecodeReferencesToVisited( rt: *JSRuntime, function_bytecode: *FunctionBytecode, ) void`。
- **作用**：清理字节码记录中被 condemned 的 realm 与常量引用。
- **实现**：realmContext 存在且 realm.header condemned 时清 realm.ptr；对 cpoolSlice 每个值调用 clearValueReferenceToVisited。
- **所有权 / 错误 / 调用**：不清字节码所有字段、不释放 realm/常量池；只是特定清扫路径的引用断开。

### `Object.valueReferencesVisited` (`src/core/object.zig:7494`)

- **签名**：`fn valueReferencesVisited(stored: JSValue) bool`。
- **作用**：判断值是否直接引用 condemned Object 或 VarRef。
- **实现**：Object 值查 objectIsCycleGarbage；否则 VarRef.fromValue 成功则查其 header；其他返回 false。
- **所有权 / 错误 / 调用**：名字不表示查询某个 visited 集合，也不包含 FunctionBytecode/String 等全部 carrier。

### `Object.functionBytecodeFromValue` (`src/core/object.zig:7500`)

- **签名**：`fn functionBytecodeFromValue(stored: JSValue) ?*FunctionBytecode`。
- **作用**：按 objectHeader kind 提取 FunctionBytecode。
- **实现**：无 objectHeader 或 kind 非 function_bytecode 返回 null，否则 fieldParentPtr(header)。
- **所有权 / 错误 / 调用**：不编译或验证指令内容，不建立根。

## 覆盖核对

- 清单函数数（本文件分到）: 62（`src/core/object.zig` 全文件 879）
- 本文标题覆盖: 62
- 未覆盖: 无
