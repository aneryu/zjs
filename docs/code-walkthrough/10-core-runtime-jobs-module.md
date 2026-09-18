# 10 — Job FIFO 与模块记录

本分册覆盖 `src/core/jobs.zig` 与 `src/core/module.zig`。前者是 Runtime 拥有的类型化 Promise/模块/Atomics/GC 任务 FIFO；后者是 realm 核心的 `ModuleRecord` 图、live-binding 格与链接状态。**链接、求值、模块图编排**在 `exec/module.zig` / `module_graph.zig`；本文件只提供记录身份与纯索引 resolve。

Job 队列 **不是** 宿主事件循环。定时器、fd、signal 走 `JSContext.host_event_loop`（vtable 接到 `runtime/event_loop.zig`）。本 FIFO 对应 QuickJS `rt->job_list` 与 `JS_EnqueueJob` / `JS_ExecutePendingJob`。Runner 回调拿到的是条目里的 `RealmRef`，不是正在 drain 的宿主 context。

---

## `src/core/jobs.zig` — Runtime 拥有的类型化 FIFO

### 类型

- `MaxArgs = 5`：generic job 参数上限。
- `Func = *const fn (*JSContext, []const JSValue) JSValue`
- `RunOneStatus`：`empty` / `success` / `exception`（测试 `runGenericOneForTest`）
- `GenericPayload`：`func` + `argc: u3` + `argv[5]`
- `PromisePayload`：单个 `value`（Promise 对象）
- `PromiseReactionPhase`：`invoke` / `resolve` / `reject`
- `PromiseReactionPayload`：reaction记录、输入值、rejected；phase默认invoke
- `AsyncResumePayload`：内部 Await 续体；continuation/value由可达Job的traceRoots访问，无JS callable
- `PromiseThenablePhase`：prepare / invoke / reject；类型只记录阶段，单次调用保证依赖执行层转换规则
- `PromiseThenablePayload`：target/thenable/then_function；resolving_resolve、resolving_reject、completion默认undefined，phase默认prepare
- `PromiseSettlementPayload`：resolving 函数已赢 once-guard、但 reaction 准备 OOM 时的续体
- `DynamicImportPayload`：exec 安装的 `Runner` + resolve/reject/basename/specifier/attributes
- `AtomicsWaiterPayload`：不透明 waiter + `Runner`/`Destroyer` + Promise；Job.deinit调用destroyer释放；成功执行和teardown的清理安排由外层负责
- `FinalizationPayload`：FinalizationRegistry 回调 + held value
- `Payload` union / `Kind = std.meta.Tag(Payload)`
- `Job`（钉 128 字节）：`runtime`、`realm: RealmRef`、`payload`
- `Queue`：借用memory账户，capacity记录整块容量；`jobs` 是 backing 块里的活窗口；`head` 是已 drain 前缀；`reserved_entries` 是未提交事务槽；`unlinked_head_slots` 钉在窗口之下给 `prependReserved`

这些普通结构和切片本身不自动注册根：由Runtime追踪Queue，再由Job.traceRoots访问realm及payload；出队执行期间的保护由外层负责。队列不验证传入context.runtime与持有者一致，调用方必须保持同runtime使用。DynamicImportPayload.Runner接受context、可选Writer与只读payload，返回RuntimeError!JSValue；Atomics runner返回RuntimeError!void，Destroyer接受opaque waiter且无错误返回。Generic argc默认0、五个argv默认undefined；RunOneStatus用于测试辅助接口，不作为本次非测试行为审核目标。

comptime断言JSValue为16字节，还钉了 Generic=96、Promise=16、Reaction=40、Thenable=104、DynImport=88、Finalization=32。

### `PromiseReactionPayload.replaceValueOwned` (`src/core/jobs.zig:48`)

- **签名**：`pub fn replaceValueOwned(self: *PromiseReactionPayload, _: *core.JSRuntime, value: core.JSValue) void`。
- **作用**：替换reaction条目保存的输入或完成值。
- **实现**：直接self.value=value，忽略runtime参数。
- **所有权 / 错误 / 调用**：不释放旧值、不增加引用计数、不注册根，也不改变phase；可达性由追踪该payload的持有者保证。防止重复调用处理器还依赖exec相位管理，不能仅由本赋值保证。

### `PromiseThenablePayload.replaceCompletionOwned` (`src/core/jobs.zig:79`)

- **签名**：`pub fn replaceCompletionOwned(self: *PromiseThenablePayload, _: *core.JSRuntime, value: core.JSValue) void`。
- **作用**：保存thenable执行的完成值。
- **实现**：直接self.completion=value，忽略runtime参数。
- **所有权 / 错误 / 调用**：不改变phase或执行reject，不释放旧目标或注册根。重试是否跳过用户回调由执行层负责。

### `Job.init` (`src/core/jobs.zig:152`)

- **签名**：`pub fn init(context: *core.JSContext, func: Func, args: []const core.JSValue) !Job`。
- **作用**：构造generic回调条目。
- **实现**：参数超过5时先报TooManyJobArgs；保存context.runtime、RealmRef及func/argc，逐项复制argv，未用元素保持undefined。
- **所有权 / 错误 / 调用**：不分配；RealmRef.retain是普通指针边。当前错误均发生在构造前，后续errdefer没有可失败步骤。返回条目尚未入队，调用方保证入队前与执行时可追踪。

### `Job.initPromise` (`src/core/jobs.zig:170`)

- **签名**：`pub fn initPromise(context: *core.JSContext, value: core.JSValue) Job`。
- **作用**：构造promise类型条目。
- **实现**：保存runtime和realm边，并把value位拷贝进promise payload。
- **所有权 / 错误 / 调用**：无分配，不检查value为Promise或对象；不入队、不自行注册根，值和realm须由可达Job持有者追踪。

### `Job.initOwnedPromiseObject` (`src/core/jobs.zig:181`)

- **签名**：`pub fn initOwnedPromiseObject(context: *core.JSContext, value: core.JSValue) Job`。
- **作用**：构造对象值的promise条目供预留提交路径使用。
- **实现**：断言value.isObject，保存runtime/realm/value。
- **所有权 / 错误 / 调用**：只检查对象tag，不检查Promise品牌；构造本身不预留或消耗队列槽。无分配，调用方负责随后发布及根保护。

### `Job.initPromiseReaction` (`src/core/jobs.zig:194`)

- **签名**：`pub fn initPromiseReaction( context: *core.JSContext, reaction: core.JSValue, value: core.JSValue, rejected: bool, ) Job`。
- **作用**：构造待调用阶段的reaction条目。
- **实现**：保存runtime/realm、reaction、value与rejected，phase默认invoke。
- **所有权 / 错误 / 调用**：无分配、不验证reaction品牌，也不注册符号根；可达Job通过traceRoots访问这些值，位拷贝本身不等于GC根。

### `Job.initAsyncResume` (`src/core/jobs.zig:212`)

- **签名**：`pub fn initAsyncResume(context: *core.JSContext, continuation: core.JSValue, value: core.JSValue) Job`。
- **作用**：构造内部Await恢复条目。
- **实现**：断言continuation为对象，保存realm/runtime及continuation/value。
- **所有权 / 错误 / 调用**：不验证具体续体品牌，不执行恢复，也不直接预留或发布槽；无分配，输入追踪依赖持有者。

### `Job.initPromiseThenable` (`src/core/jobs.zig:224`)

- **签名**：`pub fn initPromiseThenable( context: *core.JSContext, target: core.JSValue, thenable: core.JSValue, then_function: core.JSValue, ) Job`。
- **作用**：构造处于prepare阶段的thenable条目。
- **实现**：保存runtime/realm及target、thenable、then_function；resolving_resolve、resolving_reject、completion默认undefined。
- **所有权 / 错误 / 调用**：无分配，不验证可调用性或执行用户函数；resolving函数对及相位推进留给执行层。队列预留不由本函数实施。

### `Job.initPromiseSettlementNoFail` (`src/core/jobs.zig:244`)

- **签名**：`pub fn initPromiseSettlementNoFail( context: *core.JSContext, target: core.JSValue, completion: core.JSValue, rejected: bool, ) Job`。
- **作用**：构造Promise结算重试条目。
- **实现**：断言target为对象，保存runtime/realm、target、completion、rejected。
- **所有权 / 错误 / 调用**：无分配，不验证或更新once-guard，不预留FIFO；用于准备阶段已留槽的提交路径，但单独构造并不使条目自动可达。

### `Job.initDynamicImport` (`src/core/jobs.zig:262`)

- **签名**：`pub fn initDynamicImport( context: *core.JSContext, runner: DynamicImportPayload.Runner, resolve: core.JSValue, reject: core.JSValue, basename: core.JSValue, specifier: core.JSValue, attributes: core.JSValue, ) Job`。
- **作用**：构造由外层runner处理的动态导入条目。
- **实现**：保存runtime/realm、runner及resolve/reject/basename/specifier/attributes五个值。
- **所有权 / 错误 / 调用**：不分配，不验证参数类型、不加载模块或调用runner；Job.run不支持此tag，执行层按tag分发。

### `Job.initAtomicsWaiter` (`src/core/jobs.zig:285`)

- **签名**：`pub fn initAtomicsWaiter( context: *core.JSContext, waiter: *anyopaque, promise: core.JSValue, runner: AtomicsWaiterPayload.Runner, destroyer: AtomicsWaiterPayload.Destroyer, ) Job`。
- **作用**：构造持有不透明waiter资源的宿主完成条目。
- **实现**：断言promise为对象，保存runtime/realm、runner/destroyer/waiter/promise。
- **所有权 / 错误 / 调用**：构造不调用回调、不分配，也不验证Promise品牌。最终Job.deinit调用destroyer；不能把按值复制的多个条目各自销毁同一waiter。

### `Job.initFinalization` (`src/core/jobs.zig:305`)

- **签名**：`pub fn initFinalization( realm: *core.JSContext, callback: core.JSValue, held_value: core.JSValue, ) Job`。
- **作用**：构造FinalizationRegistry回调条目。
- **实现**：保存给定realm的runtime/RealmRef，以及callback和held_value。
- **所有权 / 错误 / 调用**：无分配，不验证callback可调用性，也不执行清理；realm来自条目而非之后drain的宿主context，追踪由持有者负责。

### `Job.deinit` (`src/core/jobs.zig:320`)

- **签名**：`pub fn deinit(self: *Job) void`。
- **作用**：清除条目持有的JS值边及realm边，并清理waiter资源。
- **实现**：按活动payload把值置undefined；generic只清原argc范围并置argc=0；atomics先清promise再destroyer(waiter)；最后realm.deinit将指针置null。
- **所有权 / 错误 / 调用**：不直接销毁JS堆对象，不清payload tag、runtime或所有相位。atomics没有清waiter/destroyer，重复deinit会再次调用销毁器，因此不保证幂等。出队后由接收方承担一次最终清理。

### `Job.run` (`src/core/jobs.zig:372`)

- **签名**：`pub fn run(self: *Job) core.JSValue`。
- **作用**：调用generic条目的回调并原样返回结果。
- **实现**：直接访问generic union臂，以realm.borrow() orelse unreachable取得context，传argv[0..argc]。
- **所有权 / 错误 / 调用**：要求tag为generic、realm非空、argc合法；不做tag分发、异常转换、自动deinit或根注册。回调可返回exception哨兵，具体处理交给外层。

### `Job.traceRoots` (`src/core/jobs.zig:377`)

- **签名**：`pub fn traceRoots(self: *Job, visitor: anytype) !void`。
- **作用**：向visitor提交realm与活动payload中的JS值边。
- **实现**：realm存在先调用constHeader；再按tag调用value，generic仅遍历argc个参数，thenable包含resolving对与completion，atomics仅访问promise。
- **所有权 / 错误 / 调用**：visitor错误即传播，前面已访问部分不回滚。runtime指针、函数指针与opaque waiter本身不作为JS边遍历；当前源码名为traceRoots而非traceChildEdges。队列/运行中根持有者需实际调用它。

### `Queue.init` (`src/core/jobs.zig:442`)

- **签名**：`pub fn init(account: *memory.MemoryAccount) Queue`。
- **作用**：创建借用内存账户的空队列。
- **实现**：仅设置memory，jobs为空，capacity/head/reserved_entries/unlinked_head_slots均默认0。
- **所有权 / 错误 / 调用**：不分配，账户必须活过队列；持有backing后不能把Queue按值复制为可独立销毁的多个所有者。

### `Queue.deinit` (`src/core/jobs.zig:446`)

- **签名**：`pub fn deinit(self: *Queue) void`。
- **作用**：清理当前活窗口内任务并释放其backing。
- **实现**：清reserved_entries（仅函数首行一次），断言没有unlinked claim；保存窗口/容量/块起点，先将队列置空，再逐Job.deinit，最后按原capacity释放块。
- **所有权 / 错误 / 调用**：不处理已出队任务，不逐项释放废弃槽中的旧位拷贝。回调在队列已清空后运行；若destroyer重入入队，新队列不属于保存的旧窗口。账户指针仍保留，普通空队列可再次deinit。

### `Queue.blockStart` (`src/core/jobs.zig:461`)

- **签名**：`fn blockStart(self: *const Queue) [*]Job`。
- **作用**：从当前活窗口恢复backing起始指针。
- **实现**：jobs.ptr减head个Job。
- **所有权 / 错误 / 调用**：依赖窗口与偏移一致；不验证容量或返回可独立拥有的分配，空队列结果不可解引用。

### `Queue.reclaimDrainedPrefix` (`src/core/jobs.zig:468`)

- **签名**：`fn reclaimDrainedPrefix(self: *Queue) void`。
- **作用**：把活窗口移到保留头槽之后以复用前缀。
- **实现**：floor=unlinked_head_slots；head等于floor则不动，否则copyForwards复制活Job到block[floor..]，更新jobs与head。
- **所有权 / 错误 / 调用**：无分配，重叠复制保持任务次序，但使指向旧槽的指针失效。复制是逻辑移动，不应清理遗留副本；floor保留的是容量额度，不是固定物理地址。

### `Queue.enqueue` (`src/core/jobs.zig:478`)

- **签名**：`pub fn enqueue(self: *Queue, job: Job) !void`。
- **作用**：将已构造的Job追加到队列。
- **实现**：ensureAdditionalCapacity(1)成功后enqueuePrepared。
- **所有权 / 错误 / 调用**：失败不调用job.deinit，任务仍由调用方负责。成功后逻辑持有权转入队列，不应再销毁原位拷贝；分配期间调用方须保护输入Job的GC边。

### `Queue.ensureAdditionalCapacity` (`src/core/jobs.zig:483`)

- **签名**：`fn ensureAdditionalCapacity(self: *Queue, additional: usize) !void`。
- **作用**：为活任务、已有尾部预留与新增条目准备空间。
- **实现**：ensureCapacity(jobs.len + reserved_entries + additional)。
- **所有权 / 错误 / 调用**：这里的普通usize加法不是checked算术，不能将所有整数溢出概括为OOM；有效调用量须可表示。此函数不增加预留计数。

### `Queue.ensureCapacity` (`src/core/jobs.zig:487`)

- **签名**：`pub fn ensureCapacity(self: *Queue, min_capacity: usize) !void`。
- **作用**：保证活窗口起点之后至少有min_capacity个槽位。
- **实现**：已有capacity-head足够则返回。前缀回收后能满足且reclaimable>=活长度或reclaimable*2>=capacity时移动窗口；否则从4或旧容量两倍开始倍增，分配新块，将活项复制到floor偏移，再更新并释放旧块。
- **所有权 / 错误 / 调用**：min_capacity是含现有活项的总窗口容量，不是新增数。分配失败保留旧队列；增长算术不是溢出转OOM接口。扩容/回收使旧元素指针失效，保留unlinked额度但不复制其旧物理槽；运行中任务须由外层持有。

### `Queue.reserveEntries` (`src/core/jobs.zig:520`)

- **签名**：`pub fn reserveEntries(self: *Queue, count: usize) !void`。
- **作用**：为尚未提交的事务保留尾部槽额度。
- **实现**：count为0直接返回；ensureCapacity(len+reserved+count)成功后reserved_entries加count。
- **所有权 / 错误 / 调用**：失败不增加计数；预留不是任务、不含payload根，也不占FIFO位置。重入普通入队必须避让额度，提交时才确定任务次序。

### `Queue.releaseReservedEntries` (`src/core/jobs.zig:526`)

- **签名**：`pub fn releaseReservedEntries(self: *Queue, count: usize) void`。
- **作用**：撤销指定数量的尾部预留额度。
- **实现**：count超过现有值则清0，否则相减。
- **所有权 / 错误 / 调用**：无分配、无错误；多释放被钳为0而非拒绝，不验证事务身份，也不销毁任务。

### `Queue.reserveUnlinkedEntrySlot` (`src/core/jobs.zig:539`)

- **签名**：`pub fn reserveUnlinkedEntrySlot(self: *Queue) void`。
- **作用**：为刚出队的可重试任务保留一个头部槽额度。
- **实现**：断言head>unlinked_head_slots后加1。
- **所有权 / 错误 / 调用**：应在takeFirst后、任何可能回收前缀的操作前调用；额度本身不保持出队Job可达。无分配，与reserved_entries为不同额度。

### `Queue.releaseUnlinkedEntrySlot` (`src/core/jobs.zig:545`)

- **签名**：`pub fn releaseUnlinkedEntrySlot(self: *Queue) void`。
- **作用**：放弃一个头部保留额度。
- **实现**：断言额度非0，再减1。
- **所有权 / 错误 / 调用**：不重新入队、不销毁出队Job、不回收前缀；完成任务且不再需要该槽时可直接释放，成功并不一律要求enqueueUnlinkedEntrySlot。

### `Queue.enqueueUnlinkedEntrySlot` (`src/core/jobs.zig:554`)

- **签名**：`pub fn enqueueUnlinkedEntrySlot(self: *Queue, job: Job) void`。
- **作用**：用一个头部保留额度在队尾提交任务。
- **实现**：先减unlinked；若head+len+reserved恰好等于capacity，则回收前缀，再append。
- **所有权 / 错误 / 调用**：无分配，但回收可移动整个活窗口，单次不是恒定时间。保持尾部预留不被挤占，任务放到当前尾部而非原头部，成功后由队列清理。

### `Queue.enqueuePrepared` (`src/core/jobs.zig:567`)

- **签名**：`pub fn enqueuePrepared(self: *Queue, job: Job) void`。
- **作用**：利用未被预留的可用尾槽提交任务。
- **实现**：断言head+len+reserved<capacity，再append。
- **所有权 / 错误 / 调用**：不分配，也不消耗reserved_entries；与enqueueReserved不同。要求此前已经保证额外容量，成功后任务由队列持有。

### `Queue.enqueueReserved` (`src/core/jobs.zig:573`)

- **签名**：`pub fn enqueueReserved(self: *Queue, job: Job) void`。
- **作用**：消耗一个尾部预留额度并提交任务。
- **实现**：断言reserved非0，减1，再断言物理尾槽可用并append。
- **所有权 / 错误 / 调用**：不分配，不检查预留归属；调用方须保证预留协议有效。保留的是容量而非先到先得的位置，提交时追加到尾部。

### `Queue.append` (`src/core/jobs.zig:580`)

- **签名**：`fn append(self: *Queue, job: Job) void`。
- **作用**：扩展活窗口一项并写入Job。
- **实现**：断言head+len<capacity，延长jobs切片并在旧len处赋值。
- **所有权 / 错误 / 调用**：不分配、不执行任务或GC屏障；只检查物理槽，预留额度约束由外层提交函数维护。

### `Queue.enqueueFunc` (`src/core/jobs.zig:587`)

- **签名**：`pub fn enqueueFunc(self: *Queue, context: *core.JSContext, func: Func, args: []const core.JSValue) !void`。
- **作用**：准备容量并构造、提交generic任务。
- **实现**：先ensureAdditionalCapacity(1)，再Job.init及enqueuePrepared。
- **所有权 / 错误 / 调用**：参数超过5仍可能先扩容，故TooManyJobArgs不保证backing未变；OOM可先于参数错误。没有提交半条任务；当前Job.init成功后无可失败步骤，errdefer不用于正常清理。

### `Queue.enqueuePromise` (`src/core/jobs.zig:594`)

- **签名**：`pub fn enqueuePromise(self: *Queue, context: *core.JSContext, value: core.JSValue) !void`。
- **作用**：准备容量并追加promise条目。
- **实现**：ensureAdditionalCapacity(1)后initPromise，再enqueuePrepared。
- **所有权 / 错误 / 调用**：失败发生在构造前，不消费输入或执行Promise；调用方保护输入跨分配窗口，成功后由队列traceRoots访问。

### `Queue.enqueueOwnedPromiseObjectPrepared` (`src/core/jobs.zig:600`)

- **签名**：`pub fn enqueueOwnedPromiseObjectPrepared(self: *Queue, context: *core.JSContext, value: core.JSValue) void`。
- **作用**：用已预留的尾槽提交对象promise条目。
- **实现**：调用initOwnedPromiseObject后enqueueReserved。
- **所有权 / 错误 / 调用**：名字虽为Prepared，实际消耗reserved_entries。无分配，要求对象tag及至少一个尾部预留；不验证Promise品牌。

### `Queue.preparePromiseReaction` (`src/core/jobs.zig:604`)

- **签名**：`pub fn preparePromiseReaction( self: *Queue, context: *core.JSContext, reaction: core.JSValue, value: core.JSValue, rejected: bool, ) Job`。
- **作用**：只构造reaction条目供后续提交。
- **实现**：忽略self，返回Job.initPromiseReaction。
- **所有权 / 错误 / 调用**：不扩容、不预留、不入队、不注册根；返回任务在提交前由调用方保护。

### `Queue.enqueuePromiseReaction` (`src/core/jobs.zig:615`)

- **签名**：`pub fn enqueuePromiseReaction( self: *Queue, context: *core.JSContext, reaction: core.JSValue, value: core.JSValue, rejected: bool, ) !void`。
- **作用**：准备容量并追加reaction任务。
- **实现**：ensureAdditionalCapacity(1)后initPromiseReaction，再enqueuePrepared。
- **所有权 / 错误 / 调用**：OOM不发布任务；无用户回调或reaction执行，phase默认invoke。输入在准备分配期间由调用方保护。

### `Queue.enqueuePromiseThenable` (`src/core/jobs.zig:626`)

- **签名**：`pub fn enqueuePromiseThenable( self: *Queue, context: *core.JSContext, target: core.JSValue, thenable: core.JSValue, then_function: core.JSValue, ) !void`。
- **作用**：准备容量并追加thenable任务。
- **实现**：ensureAdditionalCapacity(1)后initPromiseThenable，再enqueuePrepared。
- **所有权 / 错误 / 调用**：OOM不发布任务；并不在此创建resolving对或调用then，输入根责任仍在外层。

### `Queue.enqueueDynamicImport` (`src/core/jobs.zig:637`)

- **签名**：`pub fn enqueueDynamicImport( self: *Queue, context: *core.JSContext, runner: DynamicImportPayload.Runner, resolve: core.JSValue, reject: core.JSValue, basename: core.JSValue, specifier: core.JSValue, attributes: core.JSValue, ) !void`。
- **作用**：准备容量并追加带runner的导入任务。
- **实现**：ensureAdditionalCapacity(1)后initDynamicImport，再enqueuePrepared。
- **所有权 / 错误 / 调用**：不调用runner、不加载模块；OOM时没有新条目，五个输入值跨分配需由外层保护。

### `Queue.enqueueAtomicsWaiter` (`src/core/jobs.zig:651`)

- **签名**：`pub fn enqueueAtomicsWaiter( self: *Queue, context: *core.JSContext, waiter: *anyopaque, promise: core.JSValue, runner: AtomicsWaiterPayload.Runner, destroyer: AtomicsWaiterPayload.Destroyer, ) !void`。
- **作用**：准备容量并接管waiter完成任务。
- **实现**：ensureAdditionalCapacity(1)成功才构造并提交AtomicsWaiter Job。
- **所有权 / 错误 / 调用**：OOM发生在接管前，不调用destroyer，waiter仍由调用方清理。成功后Job.deinit负责一次destroyer调用；本函数无跨线程同步。

### `Queue.enqueueFinalization` (`src/core/jobs.zig:663`)

- **签名**：`pub fn enqueueFinalization( self: *Queue, realm: *core.JSContext, callback: core.JSValue, held_value: core.JSValue, ) !void`。
- **作用**：准备容量并追加最终化回调条目。
- **实现**：ensureAdditionalCapacity(1)后initFinalization，再enqueuePrepared。
- **所有权 / 错误 / 调用**：不调用清理回调；OOM不发布任务，callback/held_value及realm需跨准备窗口保持可达。

### `Queue.hasJobs` (`src/core/jobs.zig:673`)

- **签名**：`pub fn hasJobs(self: Queue) bool`。
- **作用**：判断活窗口是否非空。
- **实现**：返回jobs.len!=0。
- **所有权 / 错误 / 调用**：不计未提交预留或已出队的运行中任务，不能表示所有异步工作均已结束。

### `Queue.takeFirst` (`src/core/jobs.zig:679`)

- **签名**：`pub fn takeFirst(self: *Queue) ?Job`。
- **作用**：从FIFO头摘出一个任务并移交给调用方。
- **实现**：空窗口返回null，否则复制首项、窗口前移一格、head加1。
- **所有权 / 错误 / 调用**：O(1)，不分配、不清旧物理槽、不销毁任务；窗口为空也不立即重置head。出队后不再由Queue.traceRoots访问，调用方需保护并最终清理或重新提交。

### `Queue.takeAt` (`src/core/jobs.zig:693`)

- **签名**：`pub fn takeAt(self: *Queue, index: usize) Job`。
- **作用**：移交指定索引任务并从活窗口删除。
- **实现**：断言索引有效；0委托takeFirst，否则copyForwards左移后续项并缩短窗口。
- **所有权 / 错误 / 调用**：保持其他任务相对次序，中间删除成本随后续项数增长；非0分支不增加head，不能据此宣称新获头部保留额度。不清尾部废弃副本，调用方承担任务清理。

### `Queue.prependReserved` (`src/core/jobs.zig:709`)

- **签名**：`pub fn prependReserved(self: *Queue, job: Job) void`。
- **作用**：用头部保留额度把任务重新放到FIFO首位。
- **实现**：断言unlinked非0并减1，断言head非0并减1；窗口起点左移一项、长度加1，写入job。
- **所有权 / 错误 / 调用**：无分配、O(1)，要求之前已保留头槽；不消费reserved_entries。成功后任务重新由队列追踪，原调用方不得重复清理。

### `Queue.firstIndexOfKind` (`src/core/jobs.zig:719`)

- **签名**：`pub fn firstIndexOfKind(self: Queue, kind: Kind) ?usize`。
- **作用**：查询活窗口中第一个指定tag的索引。
- **实现**：线性扫描activeTag(job.payload)，匹配即返回索引，无匹配返回null。
- **所有权 / 错误 / 调用**：索引相对当前jobs窗口，不是backing绝对位置；不包含运行中任务或未提交预留。后续队列变化可使索引失效。

### `Queue.countKind` (`src/core/jobs.zig:726`)

- **签名**：`pub fn countKind(self: Queue, kind: Kind) usize`。
- **作用**：统计活窗口内指定tag的条目数。
- **实现**：逐项匹配payload活动tag，累加usize。
- **所有权 / 错误 / 调用**：无分配，不计已出队任务或预留，也不验证payload内容。

### `Queue.traceRoots` (`src/core/jobs.zig:734`)

- **签名**：`pub fn traceRoots(self: *Queue, visitor: anytype) !void`。
- **作用**：追踪当前活窗口内每个Job的边。
- **实现**：按FIFO顺序逐Job.traceRoots，visitor错误立即传播。
- **所有权 / 错误 / 调用**：不扫描已废弃槽、预留空槽或出队任务；错误可能发生在部分访问之后。visitor不得使当前遍历窗口失效。

### `runGenericOneForTest` (`src/core/jobs.zig:743`)

- **签名**：`fn runGenericOneForTest(queue: *Queue) RunOneStatus`。
- **作用**：测试辅助：取出一条 generic、跑、deinit，报告 empty/success/exception。
- **实现**：`takeFirst`，断言 generic，`job.run()`，看 `is(.exception)`。
- **所有权 / 错误 / 调用**：仅本文件 tests。FIFO 在异常后保留尾部。

### `TestJob.fail` (`src/core/jobs.zig:759`)

- **签名**：`fn fail(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：generic job 抛 int32 91。
- **实现**：`ctx.throwValue(JSValue.int32(91))`。
- **所有权 / 错误 / 调用**：`Queue runOne reports three states...` 测试。

### `TestJob.succeed` (`src/core/jobs.zig:763`)

- **签名**：`fn succeed(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：返回 int32 7。
- **实现**：直接返回。
- **所有权 / 错误 / 调用**：同上测试，证明异常后 FIFO 仍跑后续成功 job。

### `TestJob.append` (`src/core/jobs.zig:817`)

- **签名**：`fn append(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue`。
- **作用**：往 `args[0]` 数组 dense append `args[1]`。
- **实现**：`Object.expect`，`appendDenseArrayDefineIndex`；失败 throw 负 int。
- **所有权 / 错误 / 调用**：FIFO 顺序测试。

### `TestJob.appendAndEnqueue` (`src/core/jobs.zig:830`)

- **签名**：`fn appendAndEnqueue(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue`。
- **作用**：先 append 1，再 enqueue 一个 append 3 的后继 job。
- **实现**：调 `append`，再 `enqueueFunc(append, [arr, 3])`。
- **所有权 / 错误 / 调用**：证明「正在跑的 job 入队的新 job 排在已有尾之后」：结果数组为 1,2,3 而非 1,3,2。

---

## `src/core/module.zig` — 模块记录、live binding、纯索引 resolve

QuickJS 对照：`JSModuleDef`（quickjs.c:888-936）。可达realm通过Registry.traceChildEdges追踪每条ModuleRecord；Registry成员关系本身不是独立GC根。request 边借用同一 registry 的指针，既不 retain 也不 trace 目标（对齐 `JSReqModuleEntry.module`）。`MODULE_NS` 延迟导出经 `module_auto_init.AutoInitModuleOwner`（volume 08），本文件只存 owner。

### 类型

`Status`：`unlinked` / `linking` / `linked` / `evaluating` / `evaluated` / `errored`。

`SyntheticKind`：`none` / `json` / `text` / `bytes`。

`RequestEntry`：`module_name: Atom`，`module: ?*ModuleRecord`（弱、借用）。

`ImportEntry`：request_index为u32，import_name/local_name为Atom，var_idx为u16闭包槽下标，is_namespace为bool；命名空间导入与普通导入的槽安装策略由链接层解释。

`ExportEntry`：export/local 名、`var_idx`、可选 `retained_cell`（链接后留下的 VarRef，使 binding 在模块函数销毁后仍活）。

`IndirectExportEntry`：`export * as name from` 是 namespace 间接导出，不是 star export。

`StarExportEntry`：仅 request 下标。

`ImportAttributeEntry`：request + key/value atom。

`ResolvedBinding`：借用的 *ModuleRecord + Entry（local_export/namespace_export分别携带u32下标）。`Identity` 把 namespace 绑定规范到目标模块的 `*`。

`ResolvedExport`：`not_found` / `ambiguous` / `resolved`。

`PendingDefinition`：未发表的定义容器，借用memory/atoms，拥有六个元数据切片并保存func_obj/synthetic_kind/has_top_level_await。构造器先产生空定义，调用方逐项填写；类型本身不会自动注册GC根。load/compile 在 registry 外建它（含初始 FunctionBytecode），再要 target。OOM 不能部分改写已加载世代。**故意没有 `module_ns`**：命名空间只在新鲜记录完全安装并链接后发表。

`ModuleRecord`：272 字节、16 对齐、`header` 在 offset 0（MemoryAccount 把 GC 元数据放在 payload 前）。字段要点：

| 字段 | 含义 |
| --- | --- |
| `header` | GC 节点 |
| `registry_prev/next` | 加载列表，**不是** GC 链 |
| `registry` / `memory` / `atoms` | 所属 registry 与账户 |
| `module_name` | atom |
| `definition_installed` / `requests_resolved` | 定义已装 / 每条 request 已指向规范记录。循环加载可先发表定义，但 link/eval 不得观察未 resolved 图 |
| `status` | 链接/求值状态机 |
| 六个元数据切片 | requests/imports/exports/indirect/star/attributes |
| `func_obj` | FunctionBytecode **或** 模块函数对象；core 不解码变体 |
| `module_ns` | 完全构造后才发表 |
| `namespace_auto_init_owner` | 每记录一个 MODULE_NS AUTOINIT opaque；属性经 `(record, atom)` 再解析 |
| `import_meta` / `import_meta_main` | import.meta |
| `synthetic_kind` / `has_top_level_await` | JSON/text/bytes 与 TLA |
| `link_dfs_*` / `link_stack_prev` | Tarjan 瞬时，仅 `.linking` |
| `eval_exception` | 求值失败缓存；之后 import 重抛而不重跑（qjs `eval_has_exception` / `eval_exception`，js_inner_module_evaluation quickjs.c:31442） |

`Registry`：借用memory、atoms、gc_registry，保存head/tail可空指针及count；初始化为空。Iterator仅保存cursor。PreparedTarget为existing或fresh，各携带*ModuleRecord。ResolutionVisit保存一次递归路径内借用的module指针与export_name atom，不拥有两者。文件私有atom_default/atom_star分别取预定义default及*字符串atom。

### `ResolvedBinding.bindingName` (`src/core/module.zig:106`)

- **签名**：`pub fn bindingName(self: ResolvedBinding) atom.Atom`。
- **作用**：读取定位器对应的绑定名。
- **实现**：local_export取exports[index].local_name；namespace_export直接返回预定义星号atom。
- **所有权 / 错误 / 调用**：借用身份，不分配；local索引须有效。它不执行identity中的namespace-import规范化，因此本地导出namespace import时仍返回本地名字。

### `ResolvedBinding.sameIdentity` (`src/core/module.zig:113`)

- **签名**：`pub fn sameIdentity(lhs: ResolvedBinding, rhs: ResolvedBinding) bool`。
- **作用**：按规范化模块指针与绑定名判断两个绑定是否同一身份。
- **实现**：分别identity，再比较module指针和binding_name atom。
- **所有权 / 错误 / 调用**：不是比较导出表下标或导出别名，也不比较当前值；要求两个定位器与请求记录有效且稳定，不分配。

### `ResolvedBinding.identity` (`src/core/module.zig:124`)

- **签名**：`fn identity(self: ResolvedBinding) Identity`。
- **作用**：把namespace绑定规范为目标模块加星号身份。
- **实现**：namespace_export查indirect条目的request；local_export按local_name扫描namespace import，命中也取其request.module，否则返回自身模块加local_name。
- **所有权 / 错误 / 调用**：索引必须有效；断言namespace标志及目标非null，但源码仍写有request.module orelse self.module回退，关闭断言时缺目标不会由此报错。普通导入不是本函数递归解析对象；依赖外层提供已解析定位器。

### `PendingDefinition.init` (`src/core/module.zig:179`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) PendingDefinition`。
- **作用**：构造空的未发表定义。
- **实现**：借用memory与atoms，六个切片默认空，func_obj为undefined，synthetic_kind为none，TLA为false。
- **所有权 / 错误 / 调用**：无分配、不注册GC根。后续拥有元数据分配后不可复制成多个独立释放者，账户和atom表须保持存活。

### `PendingDefinition.deinit` (`src/core/module.zig:185`)

- **签名**：`pub fn deinit(self: *PendingDefinition) void`。
- **作用**：拆掉待发表定义的值边并释放六个元数据数组。
- **实现**：保存六个旧切片，将切片、func_obj、synthetic_kind、TLA重置；仅断言已有retained_cell为VarRef（imports/indirect_exports/import_attributes 上的空遍历已删），再按非空切片释放数组。
- **所有权 / 错误 / 调用**：没有提取或显式释放旧func_obj、atom、VarRef，也不销毁请求目标。不是旧RC逐值free流程；清空后的重复deinit无数组可释放，memory/atoms仍保留。

### `PendingDefinition.addRequest` (`src/core/module.zig:217`)

- **签名**：`pub fn addRequest(self: *PendingDefinition, module_name: atom.Atom) !u32`。
- **作用**：追加一个module尚为null的请求并返回新索引。
- **实现**：先将当前requests.len转换u32，失败报ModuleMetadataOverflow；noteHolderStore名字后append。
- **所有权 / 错误 / 调用**：不去重、不解析目标。noteHolderStore含编译scope记录/mark屏障而非retain；后续分配失败保持旧切片，但此前atom记录/着色不回滚。

### `PendingDefinition.addImport` (`src/core/module.zig:224`)

- **签名**：`pub fn addImport( self: *PendingDefinition, request_index: u32, import_name: atom.Atom, local_name: atom.Atom, var_idx: u16, is_namespace: bool, ) !void`。
- **作用**：追加指定请求的导入元数据。
- **实现**：先验证request_index，分别noteHolderStore import_name/local_name，再append含var_idx/is_namespace的条目。
- **所有权 / 错误 / 调用**：只校验请求下标，不检查重复本地名、closure槽是否存在或atom语义；OOM保持旧切片但不回滚已发生atom屏障，元数据输入由外层保证。

### `PendingDefinition.addExport` (`src/core/module.zig:244`)

- **签名**：`pub fn addExport( self: *PendingDefinition, export_name: atom.Atom, local_name: atom.Atom, var_idx: u16, ) !void`。
- **作用**：追加本地导出定位器。
- **实现**：当前exports.len大于u32最大才报ModuleMetadataOverflow；记录两个atom后append，retained_cell默认null。
- **所有权 / 错误 / 调用**：等于u32最大仍允许追加该索引。不会检查导出重名或var_idx有效性，也不在此创建VarRef；分配失败保留原数组。

### `PendingDefinition.addIndirectExport` (`src/core/module.zig:260`)

- **签名**：`pub fn addIndirectExport( self: *PendingDefinition, request_index: u32, export_name: atom.Atom, import_name: atom.Atom, is_namespace: bool, ) !void`。
- **作用**：追加具名间接导出或namespace间接导出。
- **实现**：先校验request_index，再检查当前indirect_exports.len是否大于u32最大；记录名字后append所有字段。
- **所有权 / 错误 / 调用**：is_namespace直接保存，不在此解析目标或创建namespace/cell；与star_exports表分开。非法下标先于数量检查报错；OOM保留旧数组。

### `PendingDefinition.addStarExport` (`src/core/module.zig:279`)

- **签名**：`pub fn addStarExport(self: *PendingDefinition, request_index: u32) !void`。
- **作用**：追加一个star导出的请求索引。
- **实现**：validateRequestIndex成功后append StarExportEntry。
- **所有权 / 错误 / 调用**：不记录额外atom、不去重、不解析导出，也不在此检查歧义；失败不追加条目。

### `PendingDefinition.addImportAttribute` (`src/core/module.zig:284`)

- **签名**：`pub fn addImportAttribute( self: *PendingDefinition, request_index: u32, key: atom.Atom, value: atom.Atom, ) !void`。
- **作用**：追加关联请求的属性键值atom。
- **实现**：先验证请求下标，再noteHolderStore key/value并append。
- **所有权 / 错误 / 调用**：不检查重复键、type是否受支持或值内容，验证留给外层；分配失败保持旧数组但不撤回atom记录/着色。

### `PendingDefinition.funcObjectValue` (`src/core/module.zig:302`)

- **签名**：`pub fn funcObjectValue(self: *const PendingDefinition) value_mod.JSValue`。
- **作用**：读取当前保存的函数或字节码值。
- **实现**：返回func_obj的位拷贝。
- **所有权 / 错误 / 调用**：不清槽、不做typed解码、不建立新根；空定义可返回undefined，跨GC的返回值保护由调用方负责。

### `PendingDefinition.adoptFuncObjectValueNoFail` (`src/core/module.zig:309`)

- **签名**：`pub fn adoptFuncObjectValueNoFail(self: *PendingDefinition, next: value_mod.JSValue) void`。
- **作用**：向空func_obj槽写入非undefined值。
- **实现**：断言旧槽undefined且next非undefined后直接赋值。
- **所有权 / 错误 / 调用**：不验证值是否FunctionBytecode或函数，不注册根、不分配；NoFail表示无错误返回，违反断言仍可失败。

### `PendingDefinition.takeFuncObjectValueNoFail` (`src/core/module.zig:315`)

- **签名**：`pub fn takeFuncObjectValueNoFail(self: *PendingDefinition) value_mod.JSValue`。
- **作用**：取出func_obj并清空原槽。
- **实现**：保存位拷贝，将func_obj写undefined，再返回。
- **所有权 / 错误 / 调用**：允许原槽已为空，此时返回undefined；不分配、不建立返回值根，调用方接手后续可达性责任。

### `PendingDefinition.validateRequestIndex` (`src/core/module.zig:321`)

- **签名**：`fn validateRequestIndex(self: *const PendingDefinition, request_index: u32) !void`。
- **作用**：检查请求索引是否在当前数组内。
- **实现**：转usize后与requests.len比较，越界报InvalidModuleRequestIndex。
- **所有权 / 错误 / 调用**：不检查RequestEntry.module已解析或属于哪个registry；不变更状态、不分配。

### `ModuleRecord.prepare` (`src/core/module.zig:393`)

- **签名**：`fn prepare(self: *ModuleRecord, account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) void`。
- **作用**：在新记录存储上写入空壳默认值。
- **实现**：整结构赋值，只指定memory、atoms及noteHolderStore(name)，其他字段按默认初始化。
- **所有权 / 错误 / 调用**：不分配、不发表到GC或registry；只能用于新记录，覆盖已拥有数组的记录不会自动释放旧存储。atom记录/mark屏障不等于模块根注册。

### `ModuleRecord.replaceDefinitionNoFail` (`src/core/module.zig:405`)

- **签名**：`pub fn replaceDefinitionNoFail(self: *ModuleRecord, pending: *PendingDefinition) void`。
- **作用**：将pending定义移动到新鲜、未加入registry的记录。
- **实现**：断言账户/atom表一致、目标未安装/未解析且数组和函数/namespace槽为空；pending请求目标及retained_cell必须空。转移六数组、func_obj、synthetic/TLA，标记definition_installed，再重置pending。
- **所有权 / 错误 / 调用**：无分配，不深拷贝、链接或解析请求，不发表namespace，也不在此登记GC。保持record身份及其他默认状态；不是允许覆盖已加载世代的更新接口。pending保留memory/atoms供复用或deinit。

### `ModuleRecord.clearForDestroy` (`src/core/module.zig:446`)

- **签名**：`fn clearForDestroy(self: *ModuleRecord) void`。
- **作用**：清除定义边和状态并释放元数据数组。
- **实现**：保存六数组，清安装/解析标记、status、数组、func/ns/meta/exception、synthetic/TLA和链接瞬时字段；断言retained_cell类型后释放非空数组（imports/indirect_exports/import_attributes 上的空遍历已删）。
- **所有权 / 错误 / 调用**：已去掉从不使用的 runtime 形参（唯一调用方 destroyFromHeader 相应不再传），不显式销毁JSValue/atom/VarRef或请求目标；不清module_name、registry关系或namespace resolver，外围destroyFromHeader处理摘链和名称。仅供终结，不是新世代重载接口。

### `ModuleRecord.destroyFromHeader` (`src/core/module.zig:490`)

- **签名**：`pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void`。
- **作用**：销毁header对应的模块记录及其元数据存储。
- **实现**：还原ModuleRecord指针，有registry则unlink；名称置null_atom，clearForDestroy()后memory.destroy记录。
- **所有权 / 错误 / 调用**：不在此从GC登记链摘除header，调用方须满足收集器销毁协议。`rt` 现在在函数内被显式忽略——它只为了让 destroy-by-kind 分派对所有 kind 保持同一 (runtime, header) 形状；不延迟释放到第二遍，也不递归销毁依赖模块。

### `ModuleRecord.traceChildEdgesFallible` (`src/core/module.zig:502`)

- **签名**：`pub inline fn traceChildEdgesFallible(self: *ModuleRecord, rt: anytype, visitor: anytype) !void`。
- **作用**：向visitor枚举值边与名字atom边。
- **实现**：先访问retained_cell、func_obj、module_ns、可选meta/exception；再访问module_name、requests名字、imports双名、exports双名、indirect双名、attributes键值。star只有索引，不产生atom访问。
- **所有权 / 错误 / 调用**：忽略rt；不访问request.module、registry链、link_stack_prev或namespace owner回调。visitValue和visitAtom分别可缺省为不操作；visitor错误立即传播，已访问边不回滚。

### `ModuleRecord.Helper.callVisitValue` (`src/core/module.zig:505`)

- **签名**：`inline fn callVisitValue(vis: anytype, value: *value_mod.JSValue) !void`。
- **作用**：适配可选的值访问方法。
- **实现**：编译期剥一层指针检查visitValue声明；若返回error union则try，否则直接调用；没有声明就不调用。
- **所有权 / 错误 / 调用**：传入可变JSValue槽地址；没有visitValue不报错，不能把该helper本身当作已完成值追踪的证明。回调错误向上传播。

### `ModuleRecord.traceChildEdgesNoFail` (`src/core/module.zig:553`)

- **签名**：`pub inline fn traceChildEdgesNoFail(self: *ModuleRecord, rt: anytype, visitor: anytype) void`。
- **作用**：在visitor保证不失败时调用同一边遍历。
- **实现**：调用Fallible版并catch unreachable。
- **所有权 / 错误 / 调用**：不吞掉错误或继续遍历；若visitor真的失败则违反unreachable前提，不能当作容错包装。

### `ModuleRecord.setStatus` (`src/core/module.zig:557`)

- **签名**：`pub fn setStatus(self: *ModuleRecord, status: Status) void`。
- **作用**：直接写入模块状态枚举。
- **实现**：self.status=status。
- **所有权 / 错误 / 调用**：不验证转移顺序，不同时更新请求标志、exception或链接瞬时字段；状态机协议由外层执行器维护。

### `ModuleRecord.setEvalException` (`src/core/module.zig:564`)

- **签名**：`pub fn setEvalException(self: *ModuleRecord, rt: anytype, value: value_mod.JSValue) void`。
- **作用**：保存求值异常值并执行owner到child的GC屏障。
- **实现**：直接覆盖eval_exception，再调用rt.gc.generationalBarrier(header,value.cycleMarkHeader())。
- **所有权 / 错误 / 调用**：不将status改成errored，不抛出异常、不显式释放旧值，也不要求旧槽为空；传入runtime须与记录匹配。

### `ModuleRecord.request` (`src/core/module.zig:569`)

- **签名**：`pub fn request(self: *ModuleRecord, request_index: u32) ?*RequestEntry`。
- **作用**：借用指定请求条目的可变指针。
- **实现**：索引超过requests.len返回null，否则返回对应元素地址。
- **所有权 / 错误 / 调用**：只验证边界，不验证module已解析；数组销毁后指针失效。返回可变指针不自动落实写边协议，调用方不得绕过已解析图的不变式。

### `ModuleRecord.requestsResolved` (`src/core/module.zig:574`)

- **签名**：`pub fn requestsResolved(self: *const ModuleRecord) bool`。
- **作用**：读取请求完备标志。
- **实现**：直接返回requests_resolved。
- **所有权 / 错误 / 调用**：不重新遍历或验证依赖；标志只在调用方遵守安装/标记协议时代表图完备。

### `ModuleRecord.markRequestsResolvedNoFail` (`src/core/module.zig:581`)

- **签名**：`pub fn markRequestsResolvedNoFail(self: *ModuleRecord) void`。
- **作用**：标记所有请求安装完毕。
- **实现**：断言自身已入registry及每条module非null，然后置requests_resolved=true。
- **所有权 / 错误 / 调用**：空请求数组也可标记；重复调用允许。不逐项验证依赖registry、definition_installed或status；标记后禁止改边依赖setter断言及外层纪律。

### `ModuleRecord.setRequestModuleNoFail` (`src/core/module.zig:589`)

- **签名**：`pub fn setRequestModuleNoFail(self: *ModuleRecord, request_index: u32, dependency: *ModuleRecord) void`。
- **作用**：向尚未填充的请求槽写入借用依赖。
- **实现**：request越界走unreachable；断言自身有registry、依赖同registry、尚未requests_resolved且槽为空，再写指针。
- **所有权 / 错误 / 调用**：无分配、不retain、不执行GC屏障。仅供解析准备阶段一次写入；关闭安全检查不会提供错误返回，调用方必须满足约束。

### `ModuleRecord.funcObjectValue` (`src/core/module.zig:599`)

- **签名**：`pub fn funcObjectValue(self: *const ModuleRecord) value_mod.JSValue`。
- **作用**：读取当前函数或字节码槽。
- **实现**：返回func_obj位拷贝。
- **所有权 / 错误 / 调用**：不清槽或解码品牌、不建立新根；可能为undefined，返回值跨GC需由调用方保护。

### `ModuleRecord.adoptFuncObjectValueNoFail` (`src/core/module.zig:605`)

- **签名**：`pub fn adoptFuncObjectValueNoFail(self: *ModuleRecord, rt: anytype, next: value_mod.JSValue) void`。
- **作用**：将非undefined值写入空函数槽并执行GC屏障。
- **实现**：断言旧func_obj为空且next非undefined，赋值后调用generationalBarrier。
- **所有权 / 错误 / 调用**：不验证FunctionBytecode或函数品牌，不分配；完成具体字节码到函数转换的是外层，不是本setter。

### `ModuleRecord.takeFuncObjectValueNoFail` (`src/core/module.zig:614`)

- **签名**：`pub fn takeFuncObjectValueNoFail(self: *ModuleRecord) value_mod.JSValue`。
- **作用**：移出函数槽的当前值。
- **实现**：复制func_obj，将原槽写undefined并返回。
- **所有权 / 错误 / 调用**：允许返回undefined；不销毁值或建立返回根，调用方承担转移期间可达性责任。

### `ModuleRecord.moduleNamespaceValue` (`src/core/module.zig:620`)

- **签名**：`pub fn moduleNamespaceValue(self: *const ModuleRecord) value_mod.JSValue`。
- **作用**：读取namespace槽。
- **实现**：返回module_ns位拷贝，未发布时为undefined。
- **所有权 / 错误 / 调用**：不构造或解析namespace、不清槽或增加根；调用方保证记录和返回值寿命。

### `ModuleRecord.publishModuleNamespaceNoFail` (`src/core/module.zig:625`)

- **签名**：`pub fn publishModuleNamespaceNoFail(self: *ModuleRecord, rt: anytype, owned: value_mod.JSValue) void`。
- **作用**：把已构造的对象写到空namespace槽。
- **实现**：断言槽undefined且输入为对象，赋值后调用generationalBarrier。
- **所有权 / 错误 / 调用**：只检查对象tag，不检验namespace品牌、构造完整性、链接状态或resolver是否已安装；这些是调用方前提，无分配。

### `ModuleRecord.namespaceAutoInitOwner` (`src/core/module.zig:632`)

- **签名**：`pub fn namespaceAutoInitOwner(self: *const ModuleRecord) *const module_auto_init.AutoInitModuleOwner`。
- **作用**：借用记录内唯一的namespace自动初始化owner。
- **实现**：返回namespace_auto_init_owner字段地址。
- **所有权 / 错误 / 调用**：地址寿命绑定ModuleRecord，不创建独立owner或GC根；默认resolver报InvalidBuiltinRegistry，调用方在发布前安装实际resolver。

### `ModuleRecord.setNamespaceAutoInitResolverNoFail` (`src/core/module.zig:636`)

- **签名**：`pub fn setNamespaceAutoInitResolverNoFail( self: *ModuleRecord, resolve: @FieldType(module_auto_init.AutoInitModuleOwner, "resolve"), ) void`。
- **作用**：在namespace发布前替换初始resolver。
- **实现**：断言namespace槽空且当前resolver等于unresolvedModuleAutoInit，再赋函数指针。
- **所有权 / 错误 / 调用**：不是不可变once token：若传入的仍是stub，之后检查仍可通过。无分配，不自动创建属性或延长模块寿命。

### `ModuleRecord.publishRetainedExportCellNoFail` (`src/core/module.zig:647`)

- **签名**：`pub fn publishRetainedExportCellNoFail( self: *ModuleRecord, export_index: u32, owned_cell: value_mod.JSValue, ) void`。
- **作用**：向本地导出条目安装一个VarRef值边。
- **实现**：直接索引exports，断言retained_cell为空且输入可解码VarRef，再位拷贝赋值。
- **所有权 / 错误 / 调用**：无错误返回，索引须有效；不增加引用计数，也不保证该cell没有其他持有者。本setter没有rt参数或显式generationalBarrier，追踪由记录边遍历完成。

### `ModuleRecord.retainedExportCellValue` (`src/core/module.zig:659`)

- **签名**：`pub fn retainedExportCellValue(self: *const ModuleRecord, export_index: u32) ?value_mod.JSValue`。
- **作用**：读取导出条目的可选VarRef值。
- **实现**：直接索引，非null时断言可解码VarRef，返回optional位拷贝。
- **所有权 / 错误 / 调用**：null表示未安装，越界不是null而是违反索引前提。不清槽、不创建根或增加引用计数。

### `ModuleRecord.clearRetainedExportCellNoFail` (`src/core/module.zig:666`)

- **签名**：`pub fn clearRetainedExportCellNoFail(self: *ModuleRecord, export_index: u32) void`。
- **作用**：移除指定导出条目的cell边。
- **实现**：直接索引；已null则返回，否则断言VarRef后置null。
- **所有权 / 错误 / 调用**：不销毁VarRef；合法索引上的重复清除可行，但并非所有输入都有无失败保证。

### `ModuleRecord.resetLinkTransientNoFail` (`src/core/module.zig:673`)

- **签名**：`pub fn resetLinkTransientNoFail(self: *ModuleRecord) void`。
- **作用**：清除Tarjan链接过程的三个暂存字段。
- **实现**：link_dfs_index与ancestor置0，link_stack_prev置null。
- **所有权 / 错误 / 调用**：不改变status、请求图、导出cell或定义；外层负责选择正确的链接阶段调用。

### `Registry.Iterator.next` (`src/core/module.zig:691`)

- **签名**：`pub fn next(self: *Iterator) ?*ModuleRecord`。
- **作用**：返回当前借用记录并推进游标。
- **实现**：cursor为空则返回null，否则先读取current.registry_next到cursor，再返回current。
- **所有权 / 错误 / 调用**：不延长记录寿命，不是快照；修改或销毁尚待访问的节点会破坏遍历前提，耗尽后持续返回null。

### `Registry.PreparedTarget.record` (`src/core/module.zig:704`)

- **签名**：`pub fn record(self: PreparedTarget) *ModuleRecord`。
- **作用**：取出结果所带的模块指针。
- **实现**：existing与fresh两臂均返回对应target。
- **所有权 / 错误 / 调用**：不改变tag、不创建或增加根；pending是否消耗由prepareFreshTarget完成，访问器本身不操作pending。

### `Registry.PreparedTarget.isFresh` (`src/core/module.zig:710`)

- **签名**：`pub fn isFresh(self: PreparedTarget) bool`。
- **作用**：读取结果是否为fresh分支。
- **实现**：fresh为true，existing为false。
- **所有权 / 错误 / 调用**：只描述该结果的tag，不重新验证记录当前状态或registry成员资格。

### `Registry.init` (`src/core/module.zig:718`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, gc_registry: *gc.Registry) Registry`。
- **作用**：构造空模块registry。
- **实现**：保存memory、atoms、gc_registry三个借用指针；head/tail为null、count为0。
- **所有权 / 错误 / 调用**：无分配；加入记录后registry地址必须稳定，因为记录反向保存其地址，不可复制成独立表。

### `Registry.deinit` (`src/core/module.zig:726`)

- **签名**：`pub fn deinit(self: *Registry) void`。
- **作用**：移除本表全部成员关系。
- **实现**：循环对head调用unlink，结束断言tail为空且count为0。
- **所有权 / 错误 / 调用**：不销毁ModuleRecord、元数据或GC登记，不执行旧RC基引用释放。记录由GC生命周期处理；账户等指针仍保留，空表重复调用可行。

### `Registry.iterator` (`src/core/module.zig:734`)

- **签名**：`pub fn iterator(self: *const Registry) Iterator`。
- **作用**：创建从当前head开始的借用游标。
- **实现**：返回Iterator{cursor=self.head}。
- **所有权 / 错误 / 调用**：不分配、不复制列表、不固定成员寿命；遍历期间调用方维护节点有效性。

### `Registry.traceChildEdgesFallible` (`src/core/module.zig:738`)

- **签名**：`pub inline fn traceChildEdgesFallible(self: *Registry, visitor: anytype) !void`。
- **作用**：向visitor枚举registry内的模块记录。
- **实现**：创建iterator，逐记录通过Helper.callVisitModule调用可选visitModule。
- **所有权 / 错误 / 调用**：这是可达realm到模块的追踪入口，不代表registry本身自动成为根。错误立即传播，不回滚先前访问；不会在此直接遍历每个模块payload。

### `Registry.Helper.callVisitModule` (`src/core/module.zig:740`)

- **签名**：`inline fn callVisitModule(vis: anytype, record: *ModuleRecord) !void`。
- **作用**：适配可选模块访问回调。
- **实现**：编译期剥一层指针检查visitModule；返回error union时try，否则直接调用，无声明则跳过。
- **所有权 / 错误 / 调用**：缺少方法不报错，因此不能只凭调用本helper宣称模块已被追踪；传递借用可变记录指针。

### `Registry.traceChildEdgesNoFail` (`src/core/module.zig:758`)

- **签名**：`pub inline fn traceChildEdgesNoFail(self: *Registry, visitor: anytype) void`。
- **作用**：在visitor不失败的前提下枚举模块边。
- **实现**：调用Fallible版并catch unreachable。
- **所有权 / 错误 / 调用**：不是忽略错误的容错接口；visitor实际报错会违反该前提。

### `Registry.link` (`src/core/module.zig:762`)

- **签名**：`fn link(self: *Registry, record: *ModuleRecord) void`。
- **作用**：将独立模块记录接入registry尾部。
- **实现**：断言record的registry/prev/next都为空，设置registry和prev，更新旧尾或head，再写tail并count加1。
- **所有权 / 错误 / 调用**：不分配、不检查模块重名、不登记GC；不是ECMAScript模块链接。当前prepareFreshTarget先登记GC后调用这里，调用方维护record和表地址稳定。

### `Registry.unlink` (`src/core/module.zig:780`)

- **签名**：`pub fn unlink(self: *Registry, record: *ModuleRecord) void`。
- **作用**：摘除记录在本表中的成员关系。
- **实现**：record.registry不等于self时断言其为null并返回；否则连接前后节点或更新head/tail，清record的三项成员字段并count减1。
- **所有权 / 错误 / 调用**：已脱表记录可重复调用；属于其他表违反断言，关闭断言时直接返回。不会释放记录、清定义或摘GC登记，不执行引用计数操作。

### `Registry.prepareFreshTarget` (`src/core/module.zig:813`)

- **签名**：`pub fn prepareFreshTarget( self: *Registry, name: atom.Atom, pending: *PendingDefinition, ) !PreparedTarget`。
- **作用**：复用已有名字记录，或安装并发布新的完整定义。
- **实现**：先断言pending账户/atom表匹配；find命中断言定义已安装并返回existing。否则create记录、prepare、移动pending、rememberOwnerForBulkWrite、addInitializedWithSizeNoFail，再link并返回fresh。
- **所有权 / 错误 / 调用**：existing不消耗pending；fresh消耗六数组及func等字段。唯一错误返回来自创建记录，失败未移动pending；之后操作无错误返回但仍有调用前提/断言。这是无半成品发布的顺序，不是线程同步原子操作；不解析依赖或运行模块。

### `Registry.find` (`src/core/module.zig:838`)

- **签名**：`pub fn find(self: *const Registry, name: atom.Atom) ?*ModuleRecord`。
- **作用**：按模块名字atom身份查找首个记录。
- **实现**：沿iterator线性扫描module_name == name，无匹配返回null。
- **所有权 / 错误 / 调用**：比较整数atom ID，不是字符串指针；不intern、加载、检查状态或注册返回值根，调用方须使用同一atom身份空间。

### `Registry.resolveExport` (`src/core/module.zig:849`)

- **签名**：`pub fn resolveExport( self: *Registry, record: *ModuleRecord, export_name: atom.Atom, ) !ResolvedExport`。
- **作用**：在现有模块元数据上解析指定导出。
- **实现**：先检查record.registry == self，否则ForeignModuleRecord；创建visiting ArrayList，调用递归解析，defer释放临时数组。
- **所有权 / 错误 / 调用**：不加载依赖、不改status/cell/membership，但会分配遍历栈并可能OOM。没有预先检查requests_resolved标志；仅在访问相关边时检查依赖，返回定位器不延长目标寿命。

### `Registry.resolveExportFromRecord` (`src/core/module.zig:860`)

- **签名**：`fn resolveExportFromRecord( self: *Registry, record: *ModuleRecord, export_name: atom.Atom, visiting: *std.ArrayList(ResolutionVisit), ) !ResolvedExport`。
- **作用**：按本地、间接、star的优先顺序递归解析导出。
- **实现**：当前路径已有同一(record,export_name)则not_found，否则push并defer pop。本地命中若为普通导入别名则追依赖，namespace import验证依赖后返回本地定位器；间接namespace验证后返回间接定位器，其余继续追依赖。前两类未命中且名字为default直接not_found；star逐支收集，歧义直接返回，不同规范化身份也为ambiguous。
- **所有权 / 错误 / 调用**：visiting是当前递归路径而非全局缓存，另一分支可再次访问相同节点；按(module,name)检测，不是遇同模块即判环。显式导出遮蔽star，default仍允许显式导出。错误可来自分配或请求边验证；深图使用原生递归，无此处深度上限。

### `requestDependency` (`src/core/module.zig:937`)

- **签名**：`fn requestDependency(record: *ModuleRecord, request_index: u32) !*ModuleRecord`。
- **作用**：从请求索引取得registry身份一致的依赖。
- **实现**：依次检查索引存在、module非null、dependency.registry等于record.registry，分别失败为InvalidModuleRequestIndex、ModuleNotFound、ForeignModuleRecord。
- **所有权 / 错误 / 调用**：不加载、不retain，不验证status/definition_installed/requests_resolved。单独看helper，两个registry都为null也满足相等；解析入口已要求起点属于self。

### `unresolvedModuleAutoInit` (`src/core/module.zig:944`)

- **签名**：`fn unresolvedModuleAutoInit( owner: *const module_auto_init.AutoInitModuleOwner, realm_header: *gc.Header, atom_id: atom.Atom, ) anyerror!module_auto_init.AutoInitMaterialization`。
- **作用**：为尚未安装的namespace resolver提供失败默认值。
- **实现**：忽略owner、realm_header与atom_id，始终返回InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：不创建属性或调用用户代码；无分配，不依输入选择其他错误。发布前安装实际resolver是外层协议。

### `append` (`src/core/module.zig:955`)

- **签名**：`inline fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void`。
- **作用**：把元数据切片增长一项并写入元素。
- **实现**：checked add计算len+1，溢出报OOM；空片段使用undefined旧指针，否则取旧ptr，以元素大小/对齐调用reallocElements；写新尾项后才更新切片。
- **所有权 / 错误 / 调用**：无独立capacity字段，按请求的新元素数重分配；失败保留原切片。成功可能使旧元素指针失效，不做元素析构、atom屏障或深拷贝，调用方负责输入及存储契约。

## 覆盖核对

- 清单函数数: 108（`src/core/jobs.zig` 51 + `src/core/module.zig` 57）
- 本文标题覆盖: 108
- 未覆盖: 无
