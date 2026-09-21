# 16 — Promise 抽象操作、内建表、async generator、completion 根

覆盖 `src/exec/promise_ops.zig`（110 个清单函数）、`promise_builtin_ops.zig`、`async_generator.zig`、`async_completion.zig`。对象布局在 `core/promise.zig`；FIFO 载体在 `core/jobs.zig`。本文件是算法与排水。

`promise_ops` 文件头把 `disposable_ops` / `atomics_ops` 的历史名字 re-export 成 `pub const`，那些**不是**本文件函数。

## 类型（`promise_ops.zig`）

`LegacyStaticMethod`：host_function 里 Promise 静态方法 id 的别名。

`PromiseResolvingPairVm`：`{ resolve, reject }` 一对 resolving function。

`PreparedPromiseReactionJobs`：结算前准备好的 `[]Job` + `reserved_entries`。`commit` 才入队并清空 promise 的 reactions 数组。

`PromiseStaticMode` / `PromiseCombinatorMode` / `PromiseCombinatorCallbackMode`：静态方法与 combinator 元素回调的 magic。

`PromiseCapabilityVm`：`{ promise, resolve, reject }`，NewPromiseCapability 结果。

`ThenCapability`：`then` 快路径。intrinsic 时只有 promise + `intrinsic_global`，没有用户可见 resolving pair；fallback 才有 resolve/reject。

`ThenCapabilityTestMetrics` / `ThenCapabilityTestStorage`：仅 test 计数 intrinsic vs fallback。

`PromiseRejectionReason`：`{ value, from_exception }`。executor/then 已经跑过，不能丢 abrupt completion。

`PromiseFinallyCallbackMode`：`fulfill`/`reject`/`return_value`/`throw_reason`。

`PromiseJobOomProbe` / `PromiseBareCapabilityErrorProbe`：单测用 native thunk，模拟 OOM 与裸 TypeError。

---

### `legacyStaticMethodId` (`src/exec/promise_ops.zig:31`)

- **签名**：`pub fn legacyStaticMethodId(name: []const u8) ?u32`。
- **作用**：把静态方法名映射到 `LegacyStaticMethod` 整数 id。
- **实现**：逐个 `mem.eql`：resolve/all/race/reject/allSettled/any/try/withResolvers/allKeyed/allSettledKeyed；否则 `null`。
- **所有权 / 错误 / 调用**：无分配。安装 Promise 静态表、名字查找。

### `promisePrototypeFromGlobal` (`src/exec/promise_ops.zig:129`)

- **签名**：`pub fn promisePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：取 `%Promise.prototype%`，不读被替换的 getter 热路径优先。
- **实现**：`cachedPromiseProto`；否则 `global.Promise.prototype` 自身数据属性。
- **所有权 / 错误 / 调用**：缺绑定返回 `null`。构造、rejected 包装、await 都用。

### `asyncFunctionPrototypeFromGlobal` (`src/exec/promise_ops.zig:136`)

- **签名**：`pub fn asyncFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：惰性安装 `%AsyncFunction.prototype%` 与构造器。
- **实现**：realm cache 命中即返回。否则造 object 原型（`[[Prototype]]` = Function.prototype）、`AsyncFunction` native 构造器、互指 prototype/constructor、`@@toStringTag`，写入 realm slot。
- **所有权 / 错误 / 调用**：失败 `TypeError`/`InvalidBuiltinRegistry`。`constructAsyncFunctionFromSource` 的原型链。

### `asyncIteratorPrototypeFromGlobal` (`src/exec/promise_ops.zig:155`)

- **签名**：`pub fn asyncIteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：`%AsyncIteratorPrototype%`：`@@asyncIterator` 与可选 `@@asyncDispose`。
- **实现**：cache；否则 `Object.create`，定义 `[Symbol.asyncIterator]`；若有 `Symbol.asyncDispose` 预定义 atom，装 stamped dispose 函数（`addAsyncIteratorAsyncDisposeFunction`）。`errdefer` 销毁未发布对象。
- **所有权 / 错误 / 调用**：`asyncGeneratorPrototypeFromGlobal` 的原型。dispose 体在 `disposable_ops.asyncIteratorAsyncDispose`。

### `asyncGeneratorPrototypeFromGlobal` (`src/exec/promise_ops.zig:175`)

- **签名**：`pub fn asyncGeneratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：`%AsyncGenerator.prototype%`。
- **实现**：原型 = async iterator prototype；`installAsyncGeneratorPrototypeProperties`；cache。
- **所有权 / 错误 / 调用**：async generator 实例的 `[[Prototype]]`。

### `installAsyncGeneratorPrototypeProperties` (`src/exec/promise_ops.zig:188`)

- **签名**：`pub fn installAsyncGeneratorPrototypeProperties(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !void`。
- **作用**：装 `next`/`return`/`throw` 与 `@@toStringTag="AsyncGenerator"`。
- **实现**：三个 `defineAsyncGeneratorDataMethod`；tag 不可写、不可枚举、可配置。
- **所有权 / 错误 / 调用**：缺 `Symbol.toStringTag` atom → `TypeError`。

### `defineAsyncGeneratorDataMethod` (`src/exec/promise_ops.zig:198`)

- **签名**：`pub inline fn defineAsyncGeneratorDataMethod(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32) !void`。
- **作用**：给 async generator 原型钉 stamped native 数据方法。
- **实现**：`builtin_glue.defineStampedNativeDataMethod(..., .async_generator, 0)`。
- **所有权 / 错误 / 调用**：实际入队在 `async_generator.asyncGeneratorEnqueue`。

### `asyncGeneratorFunctionPrototypeFromGlobal` (`src/exec/promise_ops.zig:202`)

- **签名**：`pub fn asyncGeneratorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：`%AsyncGeneratorFunction.prototype%` 与构造器。
- **实现**：类似 AsyncFunction：Function.prototype 上的对象、`AsyncGeneratorFunction` 构造器、其 `.prototype` 指向 async generator 原型并回指 constructor、toStringTag。
- **所有权 / 错误 / 调用**：`constructAsyncGeneratorFunctionFromSource`。

### `defaultPromiseCapability` (`src/exec/promise_ops.zig:221`)

- **签名**：`pub fn defaultPromiseCapability( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !PromiseCapabilityVm`。
- **作用**：用 realm 内建 Promise 构造器做 NewPromiseCapability。
- **实现**：`promiseDefaultConstructor` + `promiseCapability`。
- **所有权 / 错误 / 调用**：async-from-sync、AsyncDisposableStack.disposeAsync。走缓存的 `%Promise%`，不读 `globalThis.Promise`。

### `promiseResolveCapability` (`src/exec/promise_ops.zig:232`)

- **签名**：`pub fn promiseResolveCapability( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, resolve_value: core.JSValue, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`Call(resolve, undefined, «value»)`。
- **实现**：`callValueOrBytecodeRoot`。
- **所有权 / 错误 / 调用**：capability 兑现；async disposable 结束。

### `promiseConstruct` (`src/exec/promise_ops.zig:244`)

- **签名**：`pub fn promiseConstruct( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new Promise(executor)` 用户构造路径：解析 `constructor.prototype` 再构造。
- **实现**：executor 缺或不可调用 → `throwTypeErrorMessage("not a function")`。原型来自 constructor 或 fallback realm 的 Promise.prototype。
- **所有权 / 错误 / 调用**：转 `promiseConstructWithPrototype`。`constructorPrototypeObject` 的临时对象 `defer deinit`。

### `promiseConstructWithPrototype` (`src/exec/promise_ops.zig:265`)

- **签名**：`pub fn promiseConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：造 Promise、造 resolving pair、调 executor；executor 抛则 **Call reject**，不直接 settle。
- **实现**：`core.promise.constructWithPrototype`；`createPromiseResolvingPair`；`callValueOrBytecodeSyncInternalOutlined(executor, [resolve,reject])`。失败：`promiseRejectionReason` 后 `Call(reject, reason)`（尊重 AlreadyResolved），`reason.commit`，仍返回该 promise。对照 qjs `js_promise_constructor`。
- **所有权 / 错误 / 调用**：OOM 在 reason 构造时用 preallocated abrupt。测试覆盖 recursive OOM。

### `createPromiseResolvingState` (`src/exec/promise_ops.zig:301`)

- **签名**：`pub fn createPromiseResolvingState(rt: *core.JSRuntime) !*core.Object`。
- **作用**：共享 `[[AlreadyResolved]]` 细胞。
- **实现**：root 住分配中的 state；`promiseAlreadyResolvedSlot = false`。
- **所有权 / 错误 / 调用**：一对 resolve/reject 共用。公开 resolving 函数必须有；内部 async settle 用 `state=null` 的新鲜 once。

### `createPromiseResolvingPair` (`src/exec/promise_ops.zig:313`)

- **签名**：`pub fn createPromiseResolvingPair(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue) !PromiseResolvingPairVm`。
- **作用**：为给定 promise 造 resolve/reject 函数。
- **实现**：三槽 root；state + 两个 `createPromiseResolvingFunction`。
- **所有权 / 错误 / 调用**：返回值由调用方 root。thenable job prepare 阶段也造一对。

### `createPromiseResolvingFunction` (`src/exec/promise_ops.zig:334`)

- **签名**：`pub fn createPromiseResolvingFunction(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue, reject: bool, state: *core.Object) !core.JSValue`。
- **作用**：tag `.promise_resolving` 的 native 函数，记下 target/state/reject 标志。
- **实现**：root promise+state+function；`nativeDataFunctionWithPrototype`；写 `functionPromiseResolving*` 槽。
- **所有权 / 错误 / 调用**：缺 Function.prototype → `InvalidBuiltinRegistry`。测试验证函数边能挡住 GC。

### `testStandardGlobal` (`src/exec/promise_ops.zig:352`)

- **签名**：`fn testStandardGlobal(ctx: *core.JSContext) !*core.Object`。
- **作用**：单测装 standard globals 并取 context global。
- **实现**：`standard_globals.configureRuntime` + `zjs_vm.contextGlobal`。
- **所有权 / 错误 / 调用**：仅本文件 `test` 块。

### `appendPromiseReaction` (`src/exec/promise_ops.zig:422`)

- **签名**：`pub fn appendPromiseReaction(rt: *core.JSRuntime, promise: *core.Object, reaction: core.JSValue) !void`。
- **作用**：把反应记录链到 pending promise（qjs `list_add_tail`，`quickjs.c:54221`）。
- **实现**：reactions 数组倍增；新 cell 是 payload GC cell，旧 cell 留给 sweep（TGC S4-c）。append 本身无失败。`generationalBarrier(promise, reaction)`。
- **所有权 / 错误 / 调用**：容量从 0→4 再 *2，避免逐次精确 realloc 的 O(N²)。

### `promiseReactionRecord` (`src/exec/promise_ops.zig:452`)

- **签名**：`pub fn promiseReactionRecord( rt: *core.JSRuntime, on_fulfilled: core.JSValue, on_rejected: core.JSValue, resolve: core.JSValue, reject: core.JSValue, ) !core.JSValue`。
- **作用**：分配 `promise_reaction_record` payload，写入四个处理器。
- **实现**：四值 root；`createPromiseReactionRecord`；`errdefer destroyFromHeader`。
- **所有权 / 错误 / 调用**：`performPromiseThen` / combinator 以外的订阅。intrinsic then 走 `thenReactionRecord`。

### `promiseReactionJob` (`src/exec/promise_ops.zig:516`)

- **签名**：`pub fn promiseReactionJob( ctx: *core.JSContext, reaction: *core.Object, value: core.JSValue, rejected: bool, ) !jobs_mod.Job`。
- **作用**：把反应变成 typed FIFO 条目。
- **实现**：`Job.initPromiseReaction`（无失败搬家）。
- **所有权 / 错误 / 调用**：`preparePromiseReactionJobs`。Job 持 RealmRef + 两 JSValue。

### `PreparedPromiseReactionJobs.deinit` (`src/exec/promise_ops.zig:593`)

- **签名**：`pub fn deinit(self: *PreparedPromiseReactionJobs, rt: *core.JSRuntime) void`。
- **作用**：放弃未 commit 的准备：放回 reserved 槽、deinit 已 init 的 job、free 数组。
- **实现**：有 `reserved_entries` 则 `releaseReservedEntries`。
- **所有权 / 错误 / 调用**：`errdefer` 与测试。commit 成功后结构被清空，不必 deinit。

### `PreparedPromiseReactionJobs.commit` (`src/exec/promise_ops.zig:602`)

- **签名**：`pub fn commit(self: *PreparedPromiseReactionJobs, ctx: *core.JSContext, promise: *core.Object) void`。
- **作用**：无失败发布：reactions 数组丢给 sweep，job `enqueueReserved`。
- **实现**：`initialized==0` 早退。断言 reserved==initialized。逐条 enqueue 并减 reserved。
- **所有权 / 错误 / 调用**：只在 `promiseSettleValue` 写完 result 之后。保证「已 settle 必有 job」。

### `preparePromiseReactionJobs` (`src/exec/promise_ops.zig:668`)

- **签名**：`pub fn preparePromiseReactionJobs( ctx: *core.JSContext, promise: *core.Object, value: core.JSValue, rejected: bool, ) !PreparedPromiseReactionJobs`。
- **作用**：为当前 reactions 快照分配 Job 数组并 reserve FIFO。
- **实现**：空列表返回 `{}`。root `value`；alloc N 个 Job；逐条 `promiseReactionJob`；`job_queue.reserveEntries`。
- **所有权 / 错误 / 调用**：失败 `errdefer deinit`，promise 仍 pending。测试覆盖 prepare/reserve OOM。

### `promiseSettleValue` (`src/exec/promise_ops.zig:696`)

- **签名**：`pub fn promiseSettleValue( ctx: *core.JSContext, global: *core.Object, promise: *core.Object, value: core.JSValue, rejected: bool, ) HostError!void`。
- **作用**：Promise 结算：写 result、标 rejected、入队反应（及可选 callback job）。
- **实现**：先 `preparePromiseReactionJobs`（及 waitAsync 的 `initPromise` callback job）。全部 reserve 成功才写 `promiseResult` + barrier + `promiseIsRejected`。无反应的 reject 且 `track_unhandled_rejections` → `recordUnhandledPromiseRejection`。再 enqueue callback、`prepared.commit`。
- **所有权 / 错误 / 调用**：OOM 不改变 pending。`global` 未用。resolving 路径、settlement job、waitAsync 回调共用。

### `promiseSettlementMayAllocate` (`src/exec/promise_ops.zig:854`)

- **签名**：`fn promiseSettlementMayAllocate(target: *const core.Object) bool`。
- **作用**：判断结算会不会分配（有反应，或有未填 arg 的 reaction callback）。
- **实现**：两条件或。
- **所有权 / 错误 / 调用**：`publishPromiseResolution` 决定要不要先 reserve FIFO。

### `settlePromiseResolutionWithReservedOwner` (`src/exec/promise_ops.zig:864`)

- **签名**：`fn settlePromiseResolutionWithReservedOwner( ctx: *core.JSContext, global: *core.Object, target: *core.Object, completion: core.JSValue, rejected: bool, slot_reserved: *bool, ) HostError!void`。
- **作用**：已持 1 个 FIFO 槽时完成结算；settle OOM 则把 `promise_settlement` 续体放进该槽。
- **实现**：`promiseSettleValue` 成功则 `releaseReservedEntries(1)`。`OutOfMemory` → `enqueueReserved(initPromiseSettlementNoFail)`，slot 交给 FIFO。其它错误上抛。
- **所有权 / 错误 / 调用**：once-guard 已可见之后的唯一重试权威是 FIFO。

### `publishPromiseResolution` (`src/exec/promise_ops.zig:892`)

- **签名**：`fn publishPromiseResolution( ctx: *core.JSContext, global: *core.Object, state: ?*core.Object, target: *core.Object, completion: core.JSValue, rejected: bool, ) HostError!void`。
- **作用**：标 AlreadyResolved 并结算。无分配的标量路径不制造假 OOM 点。
- **实现**：`!mayAllocate`：写 already-resolved，直接 `promiseSettleValue`。否则先 reserve，再写 already-resolved，再 `settlePromiseResolutionWithReservedOwner`。
- **所有权 / 错误 / 调用**：`resolvePromiseWithState` 的非 thenable 臂。

### `promiseResolvingFunctionCall` (`src/exec/promise_ops.zig:913`)

- **签名**：`pub fn promiseResolvingFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：Promise resolving function 的 native 体。
- **实现**：无 target 槽 → `null`。target 非 promise 对象 → `undefined`。否则 `resolvePromiseWithState(..., functionPromiseResolvingReject())`。
- **所有权 / 错误 / 调用**：builtin 分发。返回 `undefined` 表示已处理。

### `resolvePromiseWithState` (`src/exec/promise_ops.zig:946`)

- **签名**：`fn resolvePromiseWithState( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, state: ?*core.Object, value: core.JSValue, reject: bool, resolving_function: ?*core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：PromiseResolveThenableJob 之前的共享决议算法。
- **实现**：已有 result 或 already-resolved → no-op。`!reject && value.sameValue(target)` → TypeError「promise self resolution」（realm 取 resolving 函数的，qjs `quickjs.c:53608`）。reject 或非对象 → `publishPromiseResolution`。对象：先 reserve 1 槽，标 already-resolved，`Get(then)`；getter 抛则 reserved 槽 settle reject；then 可调用 → `enqueueReserved(initPromiseThenable)`（**从不**同步跑 then，qjs `quickjs.c:53626`）；否则 settle fulfill。
- **所有权 / 错误 / 调用**：公开 resolving 必须带 state；async `asyncFunctionSettle` 传 `null`。无「已经是原生 Promise 就跳过 then」的快路径。

### `PromiseJobOomProbe.thunk` (`src/exec/promise_ops.zig:1028`)

- **签名**：`fn thunk(ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object) callconv(.c) core.JSValue`。
- **作用**：把 probe.call 接到 NativeEntry。
- **实现**：`hostErrorToValue` 包装错误。
- **所有权 / 错误 / 调用**：不分配、不建根：`entry.state` 指向调用方栈上的 `PromiseJobOomProbe`，生命周期由那一帧负责，本 thunk 只借用。`callconv(.c)` 的 managed ABI 不能抛 Zig error，所以 `self.call` 的 `error.TypeError` 由 `builtin_dispatch.hostErrorToValue(ctx, ctx.global, err)` 就地变成已挂 pending exception 的哨兵 JSValue 返回。不被直接调用，只经 `core.NativeEntry.code(&PromiseJobOomProbe.thunk)` 装进 `promiseJobOomProbeFunction`（:1065）造的 entry；整族只服务于本文件的 OOM 单测。

### `PromiseJobOomProbe.call` (`src/exec/promise_ops.zig:1038`)

- **签名**：`fn call(self: *PromiseJobOomProbe, ctx: *core.JSContext) anyerror!core.JSValue`。
- **作用**：计数调用；sweep 后把内存限制钉在 live size；`fail` 则 TypeError，否则 `int32(77)`。
- **实现**：`tryRunObjectCycleRemovalWithValueRoots` 避免 storage cell 被当成可回收字节。
- **所有权 / 错误 / 调用**：Promise OOM 单测。

### `promiseJobOomProbeFunction` (`src/exec/promise_ops.zig:1052`)

- **签名**：`fn promiseJobOomProbeFunction( ctx: *core.JSContext, probe: *PromiseJobOomProbe, name: []const u8, ) !core.JSValue`。
- **作用**：给 probe 装 managed NativeEntry 函数。
- **实现**：`allocNativeEntry` + `nativeFunction` + `installNativeEntry`。
- **所有权 / 错误 / 调用**：`probe` 只借用（调用方的栈变量），`allocNativeEntry` 分配的 `NativeEntry` 登记进 `rt.native_entries`、随 runtime 销毁；返回的函数对象是 GC 托管的，调用方负责持有。error：`allocNativeEntry`/`nativeFunction` 的 OOM，以及 `objectFromValue` 失败时的 `error.TypeError`（实际不可达）。调用方全是本文件的 OOM 单测 `src/exec/promise_ops.zig:1128,1261,1303` 等 6 处。

### `PromiseBareCapabilityErrorProbe.thunk` (`src/exec/promise_ops.zig:1071`)

- **签名**：`fn thunk(ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object) callconv(.c) core.JSValue`。
- **作用**：每次调用变成 TypeError 值，计数。
- **实现**：`hostErrorToValue(error.TypeError)`。
- **所有权 / 错误 / 调用**：自定义 capability 的 runOne exception 测试。

### `promiseBareCapabilityErrorFunction` (`src/exec/promise_ops.zig:1082`)

- **签名**：`fn promiseBareCapabilityErrorFunction( ctx: *core.JSContext, probe: *PromiseBareCapabilityErrorProbe, ) !core.JSValue`。
- **作用**：造名为 `bareCapabilityError` 的探测函数。
- **实现**：同 `promiseJobOomProbeFunction`。
- **所有权 / 错误 / 调用**：所有权与错误协议同 `promiseJobOomProbeFunction`：entry 归 runtime、函数对象归 GC、`probe` 只借用。唯一调用方 `src/exec/promise_ops.zig:1218`（裸 capability 的 resolve 抛错单测）。

### `appendDummyPromiseReaction` (`src/exec/promise_ops.zig:1097`)

- **签名**：`fn appendDummyPromiseReaction(rt: *core.JSRuntime, promise: *core.Object) !void`。
- **作用**：给测试 promise 挂一条空反应，迫使结算走分配路径。
- **实现**：`promiseReactionRecord(undefined×4)` + append。
- **所有权 / 错误 / 调用**：两步都在 GC 堆上：`promiseReactionRecord`（:452）自己用 `rootValues` 把四个 undefined 参数 root 住后建记录，`appendPromiseReaction`（:422）扩容时用 `createPayloadSliceCell` 铸新 cell 并调 `rt.gc.rememberOwnerForBulkWrite(promise.gcHeader())` 打屏障，旧 cell 留给 sweep；调用方无释放义务，但 `promise` 必须已被 root。error 只有这两步的 OOM。调用方是本文件 6 个 OOM 单测（`src/exec/promise_ops.zig:1161,1256,1296` 等）。

### `TailJob.run` (`src/exec/promise_ops.zig:1220`)

- **签名**：`fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：FIFO 尾随 generic job，返回 `int32(8)`，证明 exception 条目被消费后队列继续。
- **实现**：无副作用。
- **所有权 / 错误 / 调用**：`enqueueFunc` 测试。

### `promiseThenableJobCall` (`src/exec/promise_ops.zig:1437`)

- **签名**：`pub fn promiseThenableJobCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, payload: *jobs_mod.PromiseThenablePayload, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：跑 PromiseResolveThenableJob，带 prepare/invoke/reject 三相。
- **实现**：`.prepare`：造 resolving pair 写入 payload，进 `.invoke`（可重试，用户代码未跑）。`.invoke`：`then.call(thenable, [resolve,reject])`；抛则 `replaceCompletionOwned` 进 `.reject`，**不再调 then**。`.reject`：`Call(reject, completion)`。
- **所有权 / 错误 / 调用**：`drainOnePendingJob`。OOM 整条 prepend 回队。

### `promiseSettlementJobCall` (`src/exec/promise_ops.zig:1496`)

- **签名**：`fn promiseSettlementJobCall( ctx: *core.JSContext, global: *core.Object, payload: *const jobs_mod.PromiseSettlementPayload, ) HostError!void`。
- **作用**：FIFO 上的延迟 `promiseSettleValue`。
- **实现**：target 必须是 promise；已有 result 则幂等返回。
- **所有权 / 错误 / 调用**：once-guard 赢了但同步 settle OOM 之后。

### `promiseReactionJobCall` (`src/exec/promise_ops.zig:1511`)

- **签名**：`pub fn promiseReactionJobCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, payload: *jobs_mod.PromiseReactionPayload, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：PromiseReactionJob：调 handler，再 resolve/reject 子 capability。
- **实现**：`.invoke`：非可调用 handler 在登记时已 canonical 成 undefined，这里不再 IsCallable（revoked Proxy 仍要 Call）。undefined handler → 直接 resolve 或 reject 身份。handler 抛 → 存 abrupt，phase=reject。成功则 phase=resolve。intrinsic capability：`pollInterrupt` + `resolvePromiseWithState(state=null)`，清 intrinsic。否则 `Call(resolve|reject, value)`；undefined resolving 是 qjs 扩展（await 不造 dummy promise，`quickjs.c:53415`）。自定义 capability 的裸 host error 写入 job realm exception，条目消费，不重试用户代码。
- **所有权 / 错误 / 调用**：intrinsic settle OOM 可 retry（`promiseReactionInternalSettleCanRetry`）。

### `resetThenCapabilityTestMetrics` (`src/exec/promise_ops.zig:1659`)

- **签名**：`pub fn resetThenCapabilityTestMetrics() void`。
- **作用**：清 test 计数。
- **实现**：非 test 构建为空操作。
- **所有权 / 错误 / 调用**：不分配、无 error；写的是 `ThenCapabilityTestStorage.metrics` 这个 `builtin.is_test` 才存在的全局（非 test 构建里 `ThenCapabilityTestStorage` 是空结构，函数体被 comptime 消掉）。虽然是 `pub`，调用方只有 `src/exec/promise_ops.zig:4360` 与 `src/tests/exec.zig:23074` 等一批单测。

### `thenCapabilityTestMetrics` (`src/exec/promise_ops.zig:1663`)

- **签名**：`pub fn thenCapabilityTestMetrics() ThenCapabilityTestMetrics`。
- **作用**：读 intrinsic_prepare/intrinsic/fallback/intrinsic_settle/intrinsic_retry。
- **实现**：非 test 返回零结构。
- **所有权 / 错误 / 调用**：不分配、无 error：按值返回计数结构的副本，非 test 构建返回全零字面量。调用方只有 `src/exec/promise_ops.zig:4362-4364` 与 `src/tests/exec.zig:23084` 等单测断言。

### `thenCapability` (`src/exec/promise_ops.zig:1677`)

- **签名**：`fn thenCapability(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, legacy_wait_async: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame) HostError!ThenCapability`。
- **作用**：SpeciesConstructor 之后造 then 的结果 capability；intrinsic Promise 走无 executor 快路径。
- **实现**：非 waitAsync 且 constructor 就是 cached `promise_constructor` 且自有 data prototype → `constructWithPrototype`，不计用户 executor。否则 `promiseCapability` fallback。
- **所有权 / 错误 / 调用**：必须在 Species Get 之后，避免跳过可观察 getter。

### `thenReactionRecord` (`src/exec/promise_ops.zig:1698`)

- **签名**：`fn thenReactionRecord(rt: *core.JSRuntime, capability: *const ThenCapability, on_fulfilled: core.JSValue, on_rejected: core.JSValue) HostError!core.JSValue`。
- **作用**：按 capability 是 intrinsic 还是用户 pair 造反应记录。
- **实现**：无 intrinsic_global → 普通 `promiseReactionRecord`。否则记录只存 handler + `setPromiseReactionIntrinsicCapability(promise, global)`。
- **所有权 / 错误 / 调用**：调用方在整个订阅期间 root 住 capability。

### `promiseCapabilityExecutorCall` (`src/exec/promise_ops.zig:1713`)

- **签名**：`pub fn promiseCapabilityExecutorCall(ctx: *core.JSContext, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue`。
- **作用**：NewPromiseCapability 的 executor：把 resolve/reject 写入预分配槽。
- **实现**：槽已有非 undefined → `TypeError`（只捕获一次）。写 `setPromiseCapability`。无槽 → `null`。
- **所有权 / 错误 / 调用**：槽在 `promiseCapability` 里预先 `promiseCapabilityResolveSlot`，executor 内存储无分配，避免 OOM 被当成「resolve is not callable」。

### `promiseCombinatorElementCall` (`src/exec/promise_ops.zig:1729`)

- **签名**：`pub fn promiseCombinatorElementCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Promise.all`/`allSettled`/`any` 及 keyed 变体的元素回调。
- **实现**：mode 0 → `null`。`functionPromiseCombinatorCalled` once-guard。按 mode 写 values[index]（settled 写成 `{status,value|reason}`）。remaining--；到 0：all 类 `Call(resolve, values)`，keyed 先 `promiseKeyedResult`，any 造 AggregateError 再 reject。resolve 抛则 `promiseRejectCapability`。
- **所有权 / 错误 / 调用**：remaining 初值 1，空迭代在 combinator 尾再减。

### `promiseCapability` (`src/exec/promise_ops.zig:1804`)

- **签名**：`pub fn promiseCapability( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !PromiseCapabilityVm`。
- **作用**：NewPromiseCapability。
- **实现**：root 五槽。constructor realm 的 data function 作 executor（tag `.promise_capability_executor`）。`constructValueOrBytecode(constructor, [executor])`。取出的 resolve/reject 必须都可调用，否则 `TypeError`。
- **所有权 / 错误 / 调用**：species、静态方法、combinator。返回的三个值由调用方 root。

### `promiseSetArrayIndex` (`src/exec/promise_ops.zig:1857`)

- **签名**：`pub fn promiseSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：给 combinator 结果数组写 `array[index]=value` 并抬 length。
- **实现**：`defineDataProperty(atomFromUInt32)`；`arrayLength <= index` 则 `setArrayLength(index+1)`。
- **所有权 / 错误 / 调用**：all/any/keyed。

### `promiseKeyedResult` (`src/exec/promise_ops.zig:1862`)

- **签名**：`pub fn promiseKeyedResult(rt: *core.JSRuntime, keys: *core.Object, values: *core.Object) !core.JSValue`。
- **作用**：把平行的 keys/values 数组合并成普通对象（`Promise.allKeyed` 结果）。
- **实现**：root 住 keys/values/result/当前键值。按 keys.length 取 key→atom、value，`defineDataProperty`。
- **所有权 / 错误 / 调用**：测试验证 symbol 值在定义期间不被收。

### `promiseCombinatorState` (`src/exec/promise_ops.zig:1969`)

- **签名**：`pub fn promiseCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object) !*core.Object`。
- **作用**：combinator 共享状态：resolve/reject/values/remaining=1。
- **实现**：三值 root；`errdefer destroyFromHeader`。
- **所有权 / 错误 / 调用**：`promiseKeyedCombinatorState` 复用。

### `promiseKeyedCombinatorState` (`src/exec/promise_ops.zig:2026`)

- **签名**：`pub fn promiseKeyedCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object, keys: *core.Object) !*core.Object`。
- **作用**：再挂 keys 数组。
- **实现**：`promiseCombinatorState` + `setPromiseCombinatorKeys`。
- **所有权 / 错误 / 调用**：allKeyed / allSettledKeyed。

### `promiseCombinatorCallback` (`src/exec/promise_ops.zig:2033`)

- **签名**：`pub fn promiseCombinatorCallback( rt: *core.JSRuntime, global: *core.Object, mode: PromiseCombinatorCallbackMode, state: *core.Object, index: u32, ) !core.JSValue`。
- **作用**：造 tag `.promise_combinator_element` 的元素函数。
- **实现**：写 mode/state/index/`called=false`。
- **所有权 / 错误 / 调用**：`promiseCombinatorCall` 循环。

### `promiseRejectCapability` (`src/exec/promise_ops.zig:2050`)

- **签名**：`pub fn promiseRejectCapability( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, reject_value: core.JSValue, reason: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`Call(reject, undefined, «reason»)`。
- **实现**：`callValueOrBytecodeRoot`。
- **所有权 / 错误 / 调用**：combinator fail、async dispose。

### `promiseRejectCapabilityForError` (`src/exec/promise_ops.zig:2062`)

- **签名**：`pub noinline fn promiseRejectCapabilityForError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, reject_value: core.JSValue, err: HostError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把 HostError 收成 JS 值再 reject。
- **实现**：`promiseErrorValue` + `promiseRejectCapability`。
- **所有权 / 错误 / 调用**：`pub noinline` 已纳入清单。async-from-sync continuation。

### `rejectCombinatorAndRelease` (`src/exec/promise_ops.zig:2080`)

- **签名**：`noinline fn rejectCombinatorAndRelease( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, capability: *const PromiseCapabilityVm, err: HostError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：qjs `js_promise_all` 的 `fail_reject`：能力已造出则 reject 并返回该 promise，不把错误抛给调用方。
- **实现**：`promiseRejectCapabilityForError`；返回 `capability.promise`。
- **所有权 / 错误 / 调用**：combinator 循环几乎所有可观察失败。

### `promiseResolveIdentity` (`src/exec/promise_ops.zig:2093`)

- **签名**：`pub fn promiseResolveIdentity( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Promise.resolve(x)` 在 x 已是同 constructor 的 Promise 时返回 x。
- **实现**：非 promise class → `null`。快路径走形状链上的 data `constructor`；否则 `Get(constructor)`。`sameValue` 则返回原值。
- **所有权 / 错误 / 调用**：必须在 `isConstructorLike` 之前（qjs `js_promise_resolve` 顺序）。

### `promiseConstructorDataValueForFastPath` (`src/exec/promise_ops.zig:2117`)

- **签名**：`fn promiseConstructorDataValueForFastPath(promise: *core.Object) ?core.JSValue`。
- **作用**：沿原型链找自有 data `constructor`，遇到 slow/accessor/exotic 放弃。
- **实现**：`needsSlowPropertyAccess` / `findOwnDataValueFast` 的 slow 标志则 `null`。
- **所有权 / 错误 / 调用**：对齐 qjs 普通形状走 `JS_GetProperty` 的同一条链。

### `promiseDefaultConstructor` (`src/exec/promise_ops.zig:2128`)

- **签名**：`pub fn promiseDefaultConstructor(ctx: *core.JSContext, global: *core.Object) !core.JSValue`。
- **作用**：await / 默认 species 用的 `%Promise%`，**不**读 `globalThis.Promise`。
- **实现**：realm slot `promise_constructor`；裸测试 global 才 `global.getProperty(Promise)`。对照 qjs `ctx->promise_ctor`（`quickjs.c:54663`）。
- **所有权 / 错误 / 调用**：删除全局 Promise 不能打断 await。

### `promiseSpeciesConstructor` (`src/exec/promise_ops.zig:2141`)

- **签名**：`pub fn promiseSpeciesConstructor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：SpeciesConstructor(receiver, `%Promise%`)。
- **实现**：`Get(constructor)` undefined → default。非对象 → TypeError。`constructor[@@species]` null/undefined → default，否则返回 species。
- **所有权 / 错误 / 调用**：`then` / `finally`。

### `promiseConstructorRealmGlobal` (`src/exec/promise_ops.zig:2162`)

- **签名**：`pub fn promiseConstructorRealmGlobal(constructor_value: core.JSValue, fallback_global: *core.Object) *core.Object`。
- **作用**：capability executor 应落在构造器的 realm。
- **实现**：对象上 `objectRealmGlobal`，否则 fallback。
- **所有权 / 错误 / 调用**：`promiseCapability`。

### `promiseCombinatorCall` (`src/exec/promise_ops.zig:2169`)

- **签名**：`pub fn promiseCombinatorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, mode: PromiseCombinatorMode, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Promise.all/race/allSettled/any`。
- **实现**：this 必须是 constructor。先 capability。Get `resolve`、GetIterator、next 循环。all/allSettled/any 造 `%Array.prototype%` 数组（`instanceof Array`）。每步 `Promise.resolve(value)`、Get then、按 mode 接 onFulfilled/onRejected。失败 `closeIteratorForAbruptCompletion` + `rejectCombinatorAndRelease`。迭代结束 remaining--，0 则立即 resolve/AggregateError。
- **所有权 / 错误 / 调用**：空迭代 all 兑现 `[]`，any 拒绝 AggregateError，race 永不因空而 settle。

### `promiseKeyedCombinatorCall` (`src/exec/promise_ops.zig:2311`)

- **签名**：`pub fn promiseKeyedCombinatorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, all_settled: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Promise.allKeyed` / `allSettledKeyed`：枚举对象自有可枚举键。
- **实现**：`objectRestOwnKeys` + `proxyAwareOwnPropertyDescriptor` 滤 enumerable。键写入 keys 数组，值经 `constructor.resolve` + then。结束 remaining==0 则 `promiseKeyedResult`。
- **所有权 / 错误 / 调用**：`freeKeys` defer。非对象 iterable → reject TypeError。

### `promiseResolveStaticCall` (`src/exec/promise_ops.zig:2411`)

- **签名**：`pub fn promiseResolveStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Promise.resolve` 热路径，不与 combinator 共用栈帧。
- **实现**：this 非对象 → TypeError。先 `promiseResolveIdentity`，命中直接返回。再 `isConstructorLike`、capability、`Call(resolve, payload)`。
- **所有权 / 错误 / 调用**：`promiseResolveCall` / `promiseStaticCall(.resolve)`。

### `promiseStaticCall` (`src/exec/promise_ops.zig:2439`)

- **签名**：`pub fn promiseStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, mode: PromiseStaticMode, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：其余 Promise 静态方法。
- **实现**：`.resolve` 转专用函数。this 校验后：all/race/any/allSettled → combinator；keyed → keyed combinator；`.reject` capability+Call reject；`.try_` 调回调，抛则 reject 否则 resolve；`.with_resolvers` 造 `{promise,resolve,reject}` 普通对象。
- **所有权 / 错误 / 调用**：`promise_builtin_ops.promiseStaticCall`。

### `PromiseRejectionReason.deinit` (`src/exec/promise_ops.zig:2500`)

- **签名**：`pub fn deinit(self: *PromiseRejectionReason, _: *core.JSRuntime) void`。
- **作用**：丢掉未 commit 的 reason 持有（值清成 undefined）。
- **实现**：不 free 堆；tracing 下只是放开本地根。
- **所有权 / 错误 / 调用**：`defer reason.deinit`。

### `PromiseRejectionReason.commit` (`src/exec/promise_ops.zig:2505`)

- **签名**：`pub fn commit(self: *PromiseRejectionReason, ctx: *core.JSContext) void`。
- **作用**：若 reason 来自 pending exception，清掉 exception 槽（所有权已转到 promise）。
- **实现**：`from_exception && hasException` → `clearException`。
- **所有权 / 错误 / 调用**：executor 失败、await thenable 失败。

### `promiseRejectionReason` (`src/exec/promise_ops.zig:2510`)

- **签名**：`pub fn promiseRejectionReason( ctx: *core.JSContext, global: *core.Object, err: anytype, ) HostError!PromiseRejectionReason`。
- **作用**：从 pending 异常或 HostError 取拒绝原因；递归 OOM 用预分配值。
- **实现**：有 exception → `{ current_exception, from_exception=true }`（不 take）。否则 `createNamedError` TypeError/Error；其 OOM → `preallocated_oom_error` 或 `null`。
- **所有权 / 错误 / 调用**：不能重跑已执行的 executor。

### `closeForAwaitIteratorFromVm` (`src/exec/promise_ops.zig:2549`)

- **签名**：`pub fn closeForAwaitIteratorFromVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：for-await 的 IteratorClose；**不等** `return()` 返回的 Promise。
- **实现**：`closeIteratorFromVmImpl`。对照 qjs `OP_iterator_close`。
- **所有权 / 错误 / 调用**：VM for-await 异常路径。

### `constructAsyncFunctionFromSource` (`src/exec/promise_ops.zig:2560`)

- **签名**：`pub fn constructAsyncFunctionFromSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`AsyncFunction` 构造器：动态编译 async 函数。
- **实现**：`constructDynamicFunctionFromSource(..., .async_function)`。
- **所有权 / 错误 / 调用**：new AsyncFunction / 反射。

### `constructAsyncGeneratorFunctionFromSource` (`src/exec/promise_ops.zig:2572`)

- **签名**：`pub fn constructAsyncGeneratorFunctionFromSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`AsyncGeneratorFunction` 构造器。
- **实现**：`.async_generator`。
- **所有权 / 错误 / 调用**：对称于上。

### `asyncFunctionStart` (`src/exec/promise_ops.zig:2584`)

- **签名**：`pub fn asyncFunctionStart( ctx: *core.JSContext, func: core.JSValue, current_function_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, call_depth_precharged: bool, call_entry_ctx: *core.JSContext, call_entry_global: *core.Object, ) HostError!core.JSValue`。
- **作用**：调用 async 函数：立刻返回 Promise，体在 continuation 上跑。
- **实现**：`constructWithPrototype` 造结果 Promise；`createGeneratorObject` 造 continuation，`generatorAsyncPromiseSlot = promise`；`asyncFunctionRunAndSettle`。
- **所有权 / 错误 / 调用**：call 路径。返回的 Promise 与 continuation 互指直到 settle 清槽。

### `asyncFunctionRunState` (`src/exec/promise_ops.zig:2627`)

- **签名**：`pub fn asyncFunctionRunState( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, continuation: *core.Object, resume_value: ?core.JSValue, resume_rejected: bool, ) HostError!core.JSValue`。
- **作用**：在嵌套栈上跑/恢复 async 函数字节码。
- **实现**：已 executing → TypeError。`setGeneratorResumeCompletionType` 0 或 2。`enterCallDepth` + `pollInterrupt` + `runWithCallEnvAfterInterruptPoll`（`suspend_on_module_await=true`）。`defer finalizeGeneratorExecutionCompletion`。
- **所有权 / 错误 / 调用**：`asyncFunctionRunAndSettle`。this/args/captures 来自 generator payload。

### `asyncFunctionRunAndSettle` (`src/exec/promise_ops.zig:2670`)

- **签名**：`pub fn asyncFunctionRunAndSettle( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, continuation: *core.Object, resume_value: ?core.JSValue, resume_rejected: bool, ) HostError!void`。
- **作用**：跑一轮：抛则 reject Promise；yield/await 则 `asyncFunctionAwaitOrReject`；否则 fulfill。
- **实现**：realm 取 continuation 的。异常：`completeGeneratorExecution` + `asyncFunctionSettle(rejected)` + `clearHandledRejectionException` + `asyncFunctionClearPromise`。`generatorJustYielded && !done` → await。否则 complete + fulfill + clear。
- **所有权 / 错误 / 调用**：start、resume callback、async_resume job。

### `asyncFunctionAwaitOrReject` (`src/exec/promise_ops.zig:2698`)

- **签名**：`pub fn asyncFunctionAwaitOrReject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, continuation: *core.Object, awaited_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!void`。
- **作用**：await 准备失败时把 async 函数 Promise 拒绝掉。
- **实现**：`asyncFunctionAwait` catch → complete + settle reject + clear exception + clear promise 槽。
- **所有权 / 错误 / 调用**：`RunAndSettle` 的挂起臂。

### `clearHandledRejectionException` (`src/exec/promise_ops.zig:2716`)

- **签名**：`pub fn clearHandledRejectionException(ctx: *core.JSContext) void`。
- **作用**：handler 已处理的拒绝不应再留在 exception 槽。
- **实现**：`!hasUnhandledRejection && hasException` → `clearException`。
- **所有权 / 错误 / 调用**：reaction job 在 rejected handler 成功后；async 函数 reject settle。

### `asyncFunctionAwait` (`src/exec/promise_ops.zig:2720`)

- **签名**：`pub fn asyncFunctionAwait( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, continuation: *core.Object, awaited_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!void`。
- **作用**：async 函数的 Await：`PromiseResolve` 后接内部 resume。
- **实现**：root continuation/awaited/handlers。`promiseStaticCall(.resolve)`。若结果已是 **fulfilled 原生 Promise**，reserve 后 `enqueueReserved(initAsyncResume(continuation, result))`，不读 `then`。否则造 fulfill/reject resume callback，`performPromiseThen(..., undefined, undefined)`（qjs `js_async_function_resume`，`quickjs.c:21268`）。
- **所有权 / 错误 / 调用**：测试：fulfilled await 的 FIFO 准备 OOM 不发布半截 job。

### `asyncFunctionResumeCallback` (`src/exec/promise_ops.zig:2806`)

- **签名**：`pub fn asyncFunctionResumeCallback( rt: *core.JSRuntime, global: *core.Object, continuation: *core.Object, rejected: bool, ) !core.JSValue`。
- **作用**：内部 Await 处理器：class `async_function_resolve` / `async_function_reject`，只存 continuation。
- **实现**：root continuation；`Object.create(class, Function.prototype)`；`setAsyncResumeContinuation`。
- **所有权 / 错误 / 调用**：不是用户 thenable 的 resolving 函数。测试验证 barrier 与 OOM 保 continuation。

### `asyncResumeJobCall` (`src/exec/promise_ops.zig:2827`)

- **签名**：`fn asyncResumeJobCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, payload: *const jobs_mod.AsyncResumePayload, ) HostError!void`。
- **作用**：typed `async_resume` job：已兑现 Await 的恢复。
- **实现**：`pollInterrupt` + `asyncFunctionRunAndSettle(..., rejected=false)`。
- **所有权 / 错误 / 调用**：`drainOnePendingJob`。OOM 不重放（body 可能已跑），只吸收 abrupt。

### `asyncFunctionResumeCallbackCall` (`src/exec/promise_ops.zig:2840`)

- **签名**：`pub fn asyncFunctionResumeCallbackCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：pending/thenable Await 的 resume 函数体。
- **实现**：无 continuation → `null`。class 是否 reject 决定 `resume_rejected`。realm 用 continuation 的。
- **所有权 / 错误 / 调用**：builtin 分发。返回 `undefined`。

### `Probe.run` (`src/exec/promise_ops.zig:3007`)

- **签名**：`fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool`。
- **作用**：interrupt handler：计数并 `runObjectCycleRemoval`，验证 settle 在 poll 时仍 root 住 promise/continuation/result。
- **实现**：返回 `false` 不中止。
- **所有权 / 错误 / 调用**：仅该测试。

### `settleAsyncPromise` (`src/exec/promise_ops.zig:2960`)

- **签名**：`pub fn settleAsyncPromise(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, promise: core.JSValue, value: core.JSValue, rejected: bool) HostError!void`。
- **作用**：无 generator 载体的普通帧 async 结果结算。
- **实现**：root promise+value；`pollInterrupt`；`CallRealmView.caller` + `resolvePromiseWithState(state=null)`。
- **所有权 / 错误 / 调用**：VM 非 generator 的 async 完成。

### `asyncFunctionSettle` (`src/exec/promise_ops.zig:2973`)

- **签名**：`pub fn asyncFunctionSettle( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, continuation: *core.Object, value: core.JSValue, rejected: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!void`。
- **作用**：把 async 函数的 Promise 兑现/拒绝。
- **实现**：root value/continuation/promise；`pollInterrupt`；caller realm 的 `resolvePromiseWithState(null, ...)`。thenable 仍先 reserve FIFO。
- **所有权 / 错误 / 调用**：标量完成零分配（测试钉 memory limit）。getter OOM 转 settlement job。

### `asyncFunctionClearPromise` (`src/exec/promise_ops.zig:3191`)

- **签名**：`pub fn asyncFunctionClearPromise(rt: *core.JSRuntime, continuation: *core.Object) void`。
- **作用**：settle 后断开 continuation→promise，避免泄漏整个异步图。
- **实现**：`clearOptionalValueSlot(generatorAsyncPromiseSlot)`。
- **所有权 / 错误 / 调用**：`RunAndSettle` 两条完成臂。

### `isAsyncGeneratorPrototypeMethod` (`src/exec/promise_ops.zig:3195`)

- **签名**：`pub fn isAsyncGeneratorPrototypeMethod(rt: *core.JSRuntime, function_object: *core.Object) bool`。
- **作用**：识别 stamped async generator 原型方法。
- **实现**：忽略 rt；对象标志。
- **所有权 / 错误 / 调用**：调用分发。

### `isAsyncGeneratorReceiver` (`src/exec/promise_ops.zig:3200`)

- **签名**：`pub fn isAsyncGeneratorReceiver(value: core.JSValue) bool`。
- **作用**：`this` 是否 async_generator 对象。
- **实现**：class_id 比较。
- **所有权 / 错误 / 调用**：方法入口校验。

### `asyncGeneratorRejectedTypeError` (`src/exec/promise_ops.zig:3205`)

- **签名**：`pub fn asyncGeneratorRejectedTypeError(ctx: *core.JSContext, global: *core.Object) !core.JSValue`。
- **作用**：`this` 非法时返回 **rejected Promise**（async generator 方法不抛同步 TypeError）。
- **实现**：`rejectedPromiseForRuntimeError(TypeError, Promise.prototype)`。
- **所有权 / 错误 / 调用**：enqueue 前的 receiver 检查。

### `asyncFromSyncIteratorMethodCall` (`src/exec/promise_ops.zig:3209`)

- **签名**：`pub fn asyncFromSyncIteratorMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：CreateAsyncFromSyncIterator 包装的 next/return/throw。
- **实现**：method_id 0 → `null`。receiver 必须 `async_from_sync_iterator`。1 next / 2 return / 3 throw。
- **所有权 / 错误 / 调用**：包装对象的 `iteratorTarget` 是同步迭代器。

### `asyncFromSyncIteratorThrow` (`src/exec/promise_ops.zig:3235`)

- **签名**：`pub fn asyncFromSyncIteratorThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, wrapper: *core.Object, sync_iterator: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：GEN_MAGIC_THROW（`quickjs.c:54503`）：每次重读 `.throw`。
- **实现**：无 throw → IteratorClose 后 rejected TypeError「throw is not a method」。不可调用同。有则 Call 再 `asyncFromSyncIteratorContinuation(..., close_on_rejection=true)`。
- **所有权 / 错误 / 调用**：失败变 rejected Promise。

### `asyncFromSyncIteratorCloseWrap` (`src/exec/promise_ops.zig:3277`)

- **签名**：`pub fn asyncFromSyncIteratorCloseWrap( rt: *core.JSRuntime, global: *core.Object, sync_iterator: core.JSValue, ) !core.JSValue`。
- **作用**：onRejected 关闭包装（`quickjs.c:54468`）。
- **实现**：data function，tag `.async_from_sync_iterator_close_wrap`，continuation 槽 = sync iterator。
- **所有权 / 错误 / 调用**：continuation 在 `!done && magic != RETURN` 时安装。

### `asyncFromSyncIteratorCloseWrapCall` (`src/exec/promise_ops.zig:3289`)

- **签名**：`pub fn asyncFromSyncIteratorCloseWrapCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, ) HostError!?core.JSValue`。
- **作用**：重抛 reason，同时 IteratorClose（失败吞掉）。
- **实现**：`iteratorCloseValue` catch 清 exception；`throwValue(reason)` → `JSException`。
- **所有权 / 错误 / 调用**：qjs `JS_IteratorClose(..., TRUE)`。

### `asyncFromSyncIteratorNext` (`src/exec/promise_ops.zig:3307`)

- **签名**：`pub fn asyncFromSyncIteratorNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, wrapper: *core.Object, sync_iterator: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：包装 `.next`。
- **实现**：缓存 `iteratorNext` 或 Get next（必须可调用）。Call 失败 → rejected Promise。成功 `Continuation(..., true)`。
- **所有权 / 错误 / 调用**：receiver 未用。

### `asyncFromSyncIteratorReturn` (`src/exec/promise_ops.zig:3335`)

- **签名**：`pub fn asyncFromSyncIteratorReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, wrapper: *core.Object, sync_iterator: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：包装 `.return`。
- **实现**：无 return → fulfilled `{value:undefined, done:true}`。不可调用 → TypeError。否则 Continuation `close_on_rejection=false`。
- **所有权 / 错误 / 调用**：return 路径关闭包装不在 reject 时再 close。

### `asyncFromSyncIteratorContinuation` (`src/exec/promise_ops.zig:3363`)

- **签名**：`pub fn asyncFromSyncIteratorContinuation( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, result: core.JSValue, sync_iterator: core.JSValue, close_on_rejection: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：把同步 IteratorResult 升成异步：PromiseResolve(value) 再 unwrap 成 `{value,done}` Promise。
- **实现**：default capability。result 必须是对象。读 done/value。`Promise.resolve(value)` 抛且 `close_on_rejection && !done` 则 close（失败吞）。unwrap 回调记下 done；`!done && close_on_rejection` 才装 close-wrap。`performPromiseThen`。
- **所有权 / 错误 / 调用**：返回 capability.promise。

### `asyncFromSyncIteratorUnwrap` (`src/exec/promise_ops.zig:3430`)

- **签名**：`pub fn asyncFromSyncIteratorUnwrap( rt: *core.JSRuntime, global: *core.Object, done: bool, ) !core.JSValue`。
- **作用**：onFulfilled：把兑现值包成 IteratorResult。
- **实现**：slot `functionAsyncFromSyncUnwrapDone` = 2(done) / 1(!done)。
- **所有权 / 错误 / 调用**：tag `.async_from_sync_iterator_unwrap`。

### `asyncFromSyncIteratorUnwrapCall` (`src/exec/promise_ops.zig:3442`)

- **签名**：`pub fn asyncFromSyncIteratorUnwrapCall( ctx: *core.JSContext, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`createIteratorResult(payload, mode==2)`。
- **实现**：mode 0 → `null`；非 1/2 → TypeError。
- **所有权 / 错误 / 调用**：builtin。

### `promiseFinallyCallback` (`src/exec/promise_ops.zig:3462`)

- **签名**：`pub fn promiseFinallyCallback( rt: *core.JSRuntime, global: *core.Object, mode: PromiseFinallyCallbackMode, payload: ?core.JSValue, on_finally: ?core.JSValue, constructor_value: ?core.JSValue, ) !core.JSValue`。
- **作用**：`finally` 的 then 回调或 return/throw 续体。
- **实现**：root 三可选值；tag `.promise_finally_callback`；length 在 fulfill/reject 为 1 否则 0。
- **所有权 / 错误 / 调用**：`promiseFinally` 与 `promiseFinallyCallbackCall` 递归造 return_value/throw_reason。

### `promiseFinallyCallbackCall` (`src/exec/promise_ops.zig:3522`)

- **签名**：`pub fn promiseFinallyCallbackCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：finally 回调体。
- **实现**：`return_value` 返回存着的 payload；`throw_reason` `throwValue`。fulfill/reject：调 `onFinally()`，`Promise.resolve(result)`，再 `.then(return_value|throw_reason continuation)`。
- **所有权 / 错误 / 调用**：mode 0 → `null`。

### `promiseFinally` (`src/exec/promise_ops.zig:3575`)

- **签名**：`pub fn promiseFinally( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Promise.prototype.finally`。
- **实现**：SpeciesConstructor。onFinally 可调用则换成 fulfill/reject 包装，否则原样传给 `then`。
- **所有权 / 错误 / 调用**：`promiseThen` 的 finally 臂。观察用户 `then`。

### `performPromiseThen` (`src/exec/promise_ops.zig:3602`)

- **签名**：`pub fn performPromiseThen( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, on_fulfilled: core.JSValue, on_rejected: core.JSValue, resolve_value: core.JSValue, reject_value: core.JSValue, ) !void`。
- **作用**：PerformPromiseThen（无 species，内部用）。
- **实现**：必须是 promise class。Atomics.waitAsync 且 pending 且 on_fulfilled 可调用：只设 `promiseReactionCallback`（宿主 notify 后 FIFO 填 arg）。否则造反应记录：pending 则 append（rejected 则 `markHandled`）；已 settle 则 prepare job、reserve、**然后** markHandled、enqueueReserved。OOM 不把未处理拒绝标成 handled（测试）。
- **所有权 / 错误 / 调用**：await、module TLA、async dispose、dynamic import 链。output/global 未用。

### `promiseThen` (`src/exec/promise_ops.zig:3711`)

- **签名**：`pub fn promiseThen( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, method_name: []const u8, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`then`/`catch`/`finally` 用户方法。
- **实现**：finally → `promiseFinally`。catch **永远** `Invoke(this,"then",[undefined, onRejected])`（qjs `quickjs.c:54275`），含真 promise，以便观察 patched then。then：非 promise → TypeError。Species + `thenCapability`（waitAsync 禁用 intrinsic）。pending waitAsync 另挂 callback + 透传反应给链式 then。已 settle：prepare reaction job，reserve 后 markHandled。
- **所有权 / 错误 / 调用**：capability 全程 root。返回 `?JSValue` 给名字级分发；builtin 路径不会是 null。

### `promiseCatchGeneric` (`src/exec/promise_ops.zig:3790`)

- **签名**：`pub fn promiseCatchGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`Get(then)` 再 `Call(then, this, [undefined, onRejected])`。
- **实现**：then 不可调用 → TypeError。
- **所有权 / 错误 / 调用**：所有 `catch`，含 thenable。

### `settlePendingPromiseReaction` (`src/exec/promise_ops.zig:3805`)

- **签名**：`pub fn settlePendingPromiseReaction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, promise: *core.Object, ) !void`。
- **作用**：跑 waitAsync 一类的 `promiseReactionCallback`，再用其结果 settle 反应列表。
- **实现**：取出 callback/arg，清槽。Call 失败 → 造 rejected Promise 取其 result 当本 promise 的 reject。成功且结果是已拒绝 promise → 采纳其 reason。否则 fulfill callback_result。若期间 promise 已被别人 settle 则 return。
- **所有权 / 错误 / 调用**：`drainOnePendingJob` 的 `.promise` payload。

### `awaitPendingPromise` (`src/exec/promise_ops.zig:3902`)

- **签名**：`pub fn awaitPendingPromise( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, promise: *core.Object, ) !void`。
- **作用**：可阻塞线程上等待 waitAsync promise settle。
- **实现**：`canBlock` 且是 atomics waitAsync promise。循环 `drainOnePendingJob` + `runNextAtomicsHostCompletion(true)`。
- **所有权 / 错误 / 调用**：job exception → `JSException`。

### `drainPendingPromiseJobs` (`src/exec/promise_ops.zig:3922`)

- **签名**：`pub fn drainPendingPromiseJobs( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, ) HostError!void`。
- **作用**：排空 FIFO，并穿插 signal/rw/timer/atomics 宿主事件。
- **实现**：内层 drainOne 直到 empty；再试四类 host；有进展则再排 FIFO。
- **所有权 / 错误 / 调用**：`zjs_vm` 别名；eval 结束、event_loop、module_graph.runJobs。

### `promiseReactionInternalSettleCanRetry` (`src/exec/promise_ops.zig:3941`)

- **签名**：`fn promiseReactionInternalSettleCanRetry(payload: *const jobs_mod.PromiseReactionPayload) bool`。
- **作用**：反应 job 在 invoke 之后的 settle 阶段 OOM 能否回队。
- **实现**：phase==invoke → false（handler 已跑或未跑完，不重试 invoke）。intrinsic capability → true。resolve/reject 是 `.promise_resolving` 内部函数 → true。用户 capability 不可重试。
- **所有权 / 错误 / 调用**：`drainOnePendingJob`。

### `drainOnePendingJob` (`src/exec/promise_ops.zig:3959`)

- **签名**：`pub fn drainOnePendingJob( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, ) HostError!jobs_mod.RunOneStatus`。
- **作用**：执行恰好一条 typed FIFO。**执行 realm 是 entry.realm**，不是排水 ctx。
- **实现**：先 `processExpiredAtomicsWaiters`。`takeFirst`；`ActiveJobRoot` 让 tracer 看见整条 Job。按 payload：generic `job.run()`；promise → settlePending 或当可调用跑；reaction/thenable/settlement/dynamic_import 先 `reserveUnlinkedEntrySlot`，OOM 且可重试则 `prependReserved` 并 `entry_owned=false`；async_resume 吸收错误；atomics_waiter 失败总是回队；finalization 调 callback(held)。结果 exception 哨兵 → `.exception`。最后 `pollGCSafePoint`。
- **所有权 / 错误 / 调用**：`global` 忽略。宿主 `zjs.job.drain`、eval、module graph、event loop。返回 `.empty/.success/.exception`。

### `enqueuePendingPromiseJob` (`src/exec/promise_ops.zig:4108`)

- **签名**：`pub fn enqueuePendingPromiseJob(ctx: *core.JSContext, promise: core.JSValue) !void`。
- **作用**：把 promise 对象（或可调用）当作 `.promise` payload 入队。
- **实现**：`job_queue.enqueuePromise`。
- **所有权 / 错误 / 调用**：waitAsync 完成通知。

### `awaitThenableValue` (`src/exec/promise_ops.zig:4112`)

- **签名**：`pub fn awaitThenableValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, awaited: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：drain 模型 await（async generator / 模块 TLA）：非 Promise 对象若有可调用 then，现场 `then(resolve,reject)` 并 **同步 drain** 直到 settle。
- **实现**：promise class → `null`（调用方走别的路径）。then 不可调用 → `null`。造 promise+pair；then 抛则直接 settle reject。若仍 pending 且队列非空 `drainPendingPromiseJobs`。`finishAwaitedPromise`。
- **所有权 / 错误 / 调用**：与 async 函数的 job 模型不同：这里要同步等到值。

### `finishAwaitedPromise` (`src/exec/promise_ops.zig:4153`)

- **签名**：`pub fn finishAwaitedPromise(ctx: *core.JSContext, promise: *core.Object) !core.JSValue`。
- **作用**：已 settle 的 promise 变成完成值或抛拒绝。
- **实现**：rejected → `throwValue` + `JSException`。
- **所有权 / 错误 / 调用**：`awaitThenableValue`。

### `rejectModuleNamespaceSuperSet` (`src/exec/promise_ops.zig:4162`)

- **签名**：`pub fn rejectModuleNamespaceSuperSet(ctx: *core.JSContext, receiver: core.JSValue, atom_id: core.Atom) !bool`。
- **作用**：`super[export]=` 打到模块 namespace：先 GetOwnProperty（TDZ 的 ReferenceError 要冒出来），成功则 TypeError。
- **实现**：非 module_ns → `false`。`getOwnProperty` 后 `return error.TypeError`。
- **所有权 / 错误 / 调用**：属性 put 的 namespace 臂。`false` 表示不是 namespace。

### `countPromiseJob` (`src/exec/promise_ops.zig:4175`)

- **签名**：`fn countPromiseJob(_: *core.JSContext, args: []const core.JSValue) core.JSValue`。
- **作用**：测试 generic job：全局计数器 +1，再加 `args[0]`。
- **实现**：`promise_jobs` 文件级 var。
- **所有权 / 错误 / 调用**：`core.promise.enqueueReaction` 测试。

## `promise_builtin_ops.zig`：NativeEntry 表

`internal_entries`：resolve 走专用 thunk；all/race/reject/allSettled/any/try/withResolvers/allKeyed/allSettledKeyed 走 `promiseStaticCall`；then/catch/finally 走 `promisePrototypeCall`。cproto 均为 `.generic_magic`。

### `promiseStaticEntry` (`src/exec/promise_ops.zig:41`)

- **签名**：`fn promiseStaticEntry( comptime name: []const u8, comptime length: u8, comptime method: StaticMethod, ) core.host_function.InternalEntry`。
- **作用**：一张静态方法的 InternalEntry，magic=id。
- **实现**：`genericMagicFunction(&promiseStaticCall)`。
- **所有权 / 错误 / 调用**：comptime 表。

### `promisePrototypeEntry` (`src/exec/promise_ops.zig:57`)

- **签名**：`fn promisePrototypeEntry( comptime name: []const u8, comptime length: u8, comptime method: PrototypeMethod, ) core.host_function.InternalEntry`。
- **作用**：原型方法记录。
- **实现**：`genericMagicFunction(&promisePrototypeCall)`。
- **所有权 / 错误 / 调用**：then/catch/finally。

### `promisePrototypeCall` (`src/exec/promise_ops.zig:81`)

- **签名**：`fn promisePrototypeCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：把 magic 译成 `"then"|"catch"|"finally"` 调 `promiseThen`。
- **实现**：`nativeCall` 失败 → TypeError。`callableRealm`。`promiseThen` 返回 null → TypeError（名字级才会 null，这里不会）。
- **所有权 / 错误 / 调用**：与 qjs `js_promise_proto_funcs`（`quickjs.c:54376`）同一套 JS_GetOpaque2 / Species / catch Invoke / finally thunk。

### `promiseResolveCall` (`src/exec/promise_ops.zig:110`)

- **签名**：`fn promiseResolveCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Promise.resolve` 专用，避免 combinator 帧压到热路径。
- **实现**：assert realm==ctx；`promiseResolveStaticCall`。
- **所有权 / 错误 / 调用**：表第一项。

### `promiseStaticCall` (`src/exec/promise_ops.zig:130`)

- **签名**：`fn promiseStaticCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：把 magic 译成 `PromiseStaticMode` 再进 `promise_ops.promiseStaticCall`。
- **实现**：未知 magic → TypeError。不含 `.resolve`。
- **所有权 / 错误 / 调用**：与 `promiseResolveCall` 分家。

## `async_generator.zig`

对照 qjs `JSAsyncGenerator*`（`quickjs.c:21345-21706`）。状态在 generator 对象 payload，不是独立 opaque。zjs 用 `callFunctionBytecodeModeState` 重入函数体；yield 操作数 await 是 driver trampoline。

### 类型

`State`：`suspended_start/yield/yield_star`、`executing`、`awaiting_return`、`completed`。

`ResolveAction`：`none`、`await_resume`、`yield_operand`、`awaiting_return`（qjs magic 0/1 与 2/3）。

`ResumeArg` / `ExecOutcome`：私有，驱动 `execBody`。

### `state` (`src/exec/promise_ops.zig:63`)

- **签名**：`fn state(gen: *core.Object) State`。
- **作用**：读 `asyncGeneratorStateSlot`。
- **实现**：`@enumFromInt`。
- **所有权 / 错误 / 调用**：全程。

### `setState` (`src/exec/promise_ops.zig:67`)

- **签名**：`fn setState(gen: *core.Object, s: State) void`。
- **作用**：写状态字节。
- **实现**：`@intFromEnum`。
- **所有权 / 错误 / 调用**：不分配、无 error、无需屏障：写的是 `gen` 对象内联槽里的一个整数标签，不含指针，不产生新的老→新边。调用方全在本文件的状态机转移处（`src/exec/promise_ops.zig:163,297,369,421,523,549` 等）。

### `pushRequest` (`src/exec/promise_ops.zig:75`)

- **签名**：`fn pushRequest(rt: *core.JSRuntime, gen: *core.Object, req: AsyncGeneratorRequest) !void`。
- **作用**：请求 FIFO 追加；容量 0→4 再 *2。
- **实现**：溢出则 alloc 新缓冲、memcpy、free 旧。四个值对 generator header 做 generationalBarrier（old-to-young：长寿命 generator 挂新 promise）。
- **所有权 / 错误 / 调用**：OOM 上抛，enqueue 失败。

### `takeHeadRequest` (`src/exec/promise_ops.zig:101`)

- **签名**：`fn takeHeadRequest(gen: *core.Object) ?AsyncGeneratorRequest`。
- **作用**：弹出队头。**必须在 resolving 函数跑之前**，使重入 `next()` 看见缩短的队列（qjs `list_del`，`quickjs.c:21489`）。
- **实现**：`copyForwards` 压缩。空 → `null`。
- **所有权 / 错误 / 调用**：`settleHead`。

### `settleHead` (`src/exec/promise_ops.zig:116`)

- **签名**：`fn settleHead( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, result_value: core.JSValue, is_reject: bool, ) HostError!void`。
- **作用**：用队头的 resolve/reject 结算该请求的 Promise。
- **实现**：无头 return。root 住 result 与 req 四值，防 Call 内 GC。`Call(resolve|reject, [result])`。
- **所有权 / 错误 / 调用**：`resolveHead` 与 throw 完成。

### `resolveHead` (`src/exec/promise_ops.zig:144`)

- **签名**：`fn resolveHead( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, value: core.JSValue, done: bool, ) HostError!void`。
- **作用**：`js_async_generator_resolve`：先造 `{value,done}`。
- **实现**：`createIteratorResult` + `settleHead(..., false)`。
- **所有权 / 错误 / 调用**：每请求一个新 IteratorResult 对象。

### `complete` (`src/exec/promise_ops.zig:161`)

- **签名**：`fn complete(ctx: *core.JSContext, gen: *core.Object) void`。
- **作用**：标 `completed` 并释放保存帧（qjs `async_func_free`）。
- **实现**：已 completed 则 return；`completeGeneratorExecution`。
- **所有权 / 错误 / 调用**：体结束或 start 前 return/throw。

### `resolveFunction` (`src/exec/promise_ops.zig:173`)

- **签名**：`fn resolveFunction( rt: *core.JSRuntime, global: *core.Object, gen: *core.Object, action: ResolveAction, is_reject: bool, ) !core.JSValue`。
- **作用**：await trampoline：tag `.async_generator_resolve`，记下 gen/action/rejected。
- **实现**：data function + continuation 槽。
- **所有权 / 错误 / 调用**：`asyncGeneratorAwait` / `completedReturn` 各一对。

### `asyncGeneratorAwait` (`src/exec/promise_ops.zig:189`)

- **签名**：`fn asyncGeneratorAwait( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, value: core.JSValue, action: ResolveAction, ) HostError!void`。
- **作用**：`PromiseResolve(value)` + `performPromiseThen` 接到 trampoline。
- **实现**：故意不造 thrownawayCapability（qjs `quickjs.c:21464`）。
- **所有权 / 错误 / 调用**：失败在 `execBody` 里变成 throw 重入。

### `completedReturn` (`src/exec/promise_ops.zig:208`)

- **签名**：`fn completedReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, value: core.JSValue, ) HostError!void`。
- **作用**：completed 状态下的 `.return(value)`：仍 PromiseResolve，但 resolve 抛则变成 **rejected promise** 再 then（毒 `Promise.constructor`）。
- **实现**：`promiseStaticCall(.resolve)` catch 非致命错误 → `rejectedWithPrototype`。action `.awaiting_return`。
- **所有权 / 错误 / 调用**：`resumeNext` completed+return。

### `resumeBodyValue` (`src/exec/promise_ops.zig:253`)

- **签名**：`fn resumeBodyValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, resume_value: ?core.JSValue, stop_before_pc: ?usize, ) HostError!core.JSValue`。
- **作用**：用保存的 bytecode/this/args/captures 重入函数体。
- **实现**：`generatorExecuting=true` defer 清。`callFunctionBytecodeModeState(..., gen, resume_value, ...)`。
- **所有权 / 错误 / 调用**：无 bytecode → TypeError。

### `execBody` (`src/exec/promise_ops.zig:288`)

- **签名**：`fn execBody( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, arg: ResumeArg, ) HostError!ExecOutcome`。
- **作用**：resume 一次并解释结局：park / settle / throw 重入。
- **实现**：state=executing。按 ResumeArg 写 completion type（0 next / 1 return / 2 throw / yield* 的 completion）。`resumeBodyValue` 抛 → complete + settleHead reject。未挂起 → complete + resolveHead done=true。`await_op` → `asyncGeneratorAwait(.await_resume)`，失败 throw 重入。`yield` → await `.yield_operand`。`yield_star` → state=suspended_yield_star，resolveHead done=false（值已在字节码里 await）。`.none` assert 失败。
- **所有权 / 错误 / 调用**：finally 里的 yield 不需要 driver 额外状态：完成值留在挂起操作数栈。

### `resumeNext` (`src/exec/promise_ops.zig:386`)

- **签名**：`pub fn resumeNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, ) HostError!void`。
- **作用**：FIFO drain（`js_async_generator_resume_next`，`quickjs.c:21568`）。
- **实现**：队列空 return。`executing`/`awaiting_return` return（只让 trampoline 重入）。`suspended_start`：next 则 execBody start；return/throw 则 complete 再 continue（completed 臂处理同一请求）。`completed`：next → resolve undefined done；return → awaiting_return+completedReturn；throw → settleHead reject；**每次只处理一个请求后 return**（qjs `goto done`）。`suspended_yield` 按 completion 选 throw/return/next。`suspended_yield_star` 两槽 resume。parked → return；settled → continue。
- **所有权 / 错误 / 调用**：enqueue 在 `state!=executing` 时调用。

### `asyncGeneratorEnqueue` (`src/exec/promise_ops.zig:467`)

- **签名**：`pub fn asyncGeneratorEnqueue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, gen: *core.Object, args: []const core.JSValue, magic: i32, ) HostError!core.JSValue`。
- **作用**：`next`/`return`/`throw`：先造 capability（then-getter 可观察），入队，必要时 resume。
- **实现**：realm 用 generator 函数的。`constructWithPrototype` + resolving pair。`completion_type=magic`（0/1/2）。`pushRequest`。非 executing 则 `resumeNext`。返回请求 Promise。
- **所有权 / 错误 / 调用**：qjs `js_async_generator_next`，`quickjs.c:21706`。

### `asyncGeneratorResolveFunctionCall` (`src/exec/promise_ops.zig:502`)

- **签名**：`pub fn asyncGeneratorResolveFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, ) HostError!?core.JSValue`。
- **作用**：await trampoline（`quickjs.c:21670`）。
- **实现**：无 continuation → `null`。`.awaiting_return`：state 必须 awaiting_return 或 completed；标 completed；settle/resolveHead done=true；**不** resumeNext（相对 spec AsyncGeneratorDrainQueue 的 qjs 分叉）。`.await_resume`：必须 executing；reject→execBody throw，else next；然后 resumeNext。`.yield_operand`：reject 则 throw 进 yield 点；fulfill 则 suspended_yield + resolveHead done=false；再 resumeNext。stale trampoline 返回 undefined。
- **所有权 / 错误 / 调用**：builtin 分发。

## `async_completion.zig`

Machine 拥有的、与 callee arena 无关的 async 完成根。`Boundary` ≤96 字节：promise/value/callee。`Store`：第 0 个在 `first`，溢出每 chunk 16 个 `Boundary`。

### `Store.begin` (`src/exec/inline_calls.zig:24`)

- **签名**：`pub fn begin(self: *Store, rt: *core.JSRuntime, callee: Value) !u32`。
- **作用**：在分配 Promise/帧之前预留一个已初始化根。溢出按高水位一次，不按 helper 调用次数。
- **实现**：`count==maxInt(u32)` → OOM。id>0 沿 chunk 链，缺则 `rt.memory.create(Chunk)`。`count+=1`，`at(id).* = { .callee }`。
- **所有权 / 错误 / 调用**：测试：后续 begin OOM 时已发布的 first 根仍在。

### `Store.at` (`src/exec/inline_calls.zig:45`)

- **签名**：`pub fn at(self: *Store, id: u32) *Boundary`。
- **作用**：按 id 取槽。
- **实现**：0 → `&first`；否则走 chunk 链 `(id-1)/16`。
- **所有权 / 错误 / 调用**：assert `id < count`。

### `Store.release` (`src/exec/inline_calls.zig:53`)

- **签名**：`pub fn release(self: *Store, id: u32) void`。
- **作用**：LIFO 释放最新槽，清成 undefined。
- **实现**：assert id==count-1；`at(id).* = .{}`；count--。
- **所有权 / 错误 / 调用**：不释放 chunk（高水位保留）。

### `Store.trace` (`src/exec/inline_calls.zig:58`)

- **签名**：`pub fn trace(self: *Store, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：让 tracer 看见每个活 Boundary 的 promise/value/callee。
- **实现**：`0..count` 三次 `visitor.value`。
- **所有权 / 错误 / 调用**：Machine 的 RootProvider。

### `Store.deinit` (`src/exec/inline_calls.zig:66`)

- **签名**：`pub fn deinit(self: *Store, rt: *core.JSRuntime) void`。
- **作用**：销毁 chunk 链。必须先 release 完。
- **实现**：assert count==0；`destroy(Chunk)`。
- **所有权 / 错误 / 调用**：Machine 销毁。

## 覆盖核对

- 清单函数数: 134（`src/exec/inline_calls.zig` 5 + `src/exec/promise_ops.zig` 15 + `src/exec/promise_ops.zig` 5 + `src/exec/promise_ops.zig` 109）
- 本文标题覆盖: 134
- 未覆盖: 无
