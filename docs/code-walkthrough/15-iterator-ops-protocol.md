# 15 — `iterator_ops.zig`：for-of/for-in 协议与 Array Iterator

从 `forOfStart` 到 `iteratorConcatCall` 及其单测替身为止。栈上 for-of 记录是三元组 `[iterator, nextMethod, catchMarker]`。`forOfNext` 的 errdefer 会 `abandonForOfIteratorAtIndex`：next 已经失败的迭代器不再调用 `return()`。

### `forOfStart` (`src/exec/iterator_ops.zig:39`)

- **签名**：`pub fn forOfStart( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: ?usize, is_async: bool, ) !void`。
- **作用**：`for_of_start` / `for_await_of_start` 的实现：把栈顶 iterable 换成 `[iterator, nextMethod, catchMarker]` 三元组。
- **实现**：弹出 iterable。async：先 Get `@@asyncIterator`，非 undefined/null 时必须可调用，调用后结果必须是对象，取 `next` 后 `pushForAwaitRecord`（marker 是 async 的 -2）。否则回到同步路径：`call_runtime.getIteratorMethod` 取 `@@iterator`，不可调用就 `throwTypeErrorMessage("value is not iterable")` 并返回 `error.TypeError`；调用后结果必须是对象；若 `is_async` 则用 `createAsyncFromSyncIterator` 包一层再压 for-await 记录。纯同步路径依次 `pushOwned(iterator)` / `push(next)` / `pushOwned(iteratorCatchMarker(catchTargetMarkerValue(catch_target)))`，中间用 `errdefer` 弹回已压的槽。
- **所有权 / 错误 / 调用**：弹出的 iterable 由本函数消费。同步路径把 iterator、next、marker 依次压成三槽记录——注意 TGC 下 `stack.pushOwned` 与 `stack.push` 是同一份实现（`stack.zig:214`/`:220` 都只是 reserve + 写槽），「owned」只剩文档语义，没有运行时动作；失败时靠链式 `errdefer` 把已压的槽弹回，不留半截记录。RC 时代残留的 `owns_iterator_value` 标志（只写不读）已删。async 路径里 sync iterator 的引用移交给 `createAsyncFromSyncIterator` 造的 wrapper 槽。错误：不可迭代时先 `exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable")` 挂上消息再返回 `error.TypeError`；其余是 Get `@@asyncIterator`/`@@iterator`、调用迭代器方法、`expectObject` 的透传（用户异常、`error.TypeError`、OOM）。唯一调用方 `iterator_ops.zig:104`（`forOfStartVm`）。

### `forOfStartVm` (`src/exec/iterator_ops.zig:91`)

- **签名**：`pub noinline fn forOfStartVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, is_async: bool, ) !Step`。
- **作用**：`forOfStart` 的 VM 外壳：把 catchable HostError 转成 `Step.continue_loop`，让解释器跳进 catch 而不是把 Zig error 漏出 dispatch。
- **实现**：调用 `forOfStart(..., catch_target.*, is_async)`。失败走 `call_runtime.handleCatchableRuntimeError`：当前帧有 catch 则修剪栈、压异常、改 pc，返回 `.continue_loop`；不可捕获或无 handler 则原样传播。成功返回 `.done`。
- **所有权 / 错误 / 调用**：自身不持有任何值：三槽记录的压入与回滚都在 `forOfStart` 里。`catch_target` 传指针，是因为命中 catch 时 `handleCatchableRuntimeError` 要改写它。错误分两类：`exception_ops.runtimeErrorInfo` 认识的（TypeError/RangeError/OutOfMemory…）在 `tryCatchInFrame` 里由 `createSentinelError` 铸成 JS 异常压给 handler，返回 `.continue_loop`；不可捕获或本帧没有 handler 时原样上抛、逃出 dispatch 循环。唯一调用方 `tailcall_dispatch_colds.zig:124` 的 `h_for_of_start`（同时挂在 `op.for_of_start` 与 `op.for_await_of_start` 上，用 pc[0] 区分）。

### `catchTargetMarkerValue` (`src/exec/iterator_ops.zig:108`)

- **签名**：`fn catchTargetMarkerValue(catch_target: ?usize) i32`。
- **作用**：把可选的 catch target 转成 marker 编码用的 i32：有值就 `@intCast`，null 记作 -1。
- **实现**：单表达式 `if (catch_target) |target| @intCast(target) else -1`，结果交给 `forof_ops.iteratorCatchMarker` 编码。
- **所有权 / 错误 / 调用**：纯转换：不分配、无 error、无副作用。`-1` 这个哨兵与 `forof_ops.iteratorCatchMarker` 的编码约定绑死（-1 → `minInt(i32)`），改一处必须改两处。唯一调用方 `iterator_ops.zig:91`（`forOfStart` 压 marker 槽前）。

### `iteratorNextMethod` (`src/exec/iterator_ops.zig:112`)

- **签名**：`fn iteratorNextMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, function: ?*const bytecode.FunctionBytecode, frame: ?*frame_mod.Frame, comptime getValueProperty: anytype, ) !core.JSValue`。
- **作用**：取迭代器的 `next` 方法（GetMethod 的 Get 部分，不做可调用性检查）。
- **实现**：用 `core.atom.ids.next` 调 comptime 传入的 `getValueProperty`，原样返回；`getValueProperty` 作为 comptime 参数是为了让单测注入替身。
- **所有权 / 错误 / 调用**：返回的是 Get 的结果值，交给调用方处置：`forOfStart` 随即压栈，`createAsyncFromSyncIterator` 则先 root 住再写进 `iteratorNextSlot`；本函数自己不建根，跨分配点的保活是调用方的事。只做 Get、不查可调用性（GetMethod 的 IsCallable 检查留在调用方）。error 全是 `getValueProperty` 的透传：getter/proxy trap 抛的用户异常与 OOM。调用方 `iterator_ops.zig:58`、`:75`、`:80`（`forOfStart` 的三条路径）与 `:166`（`createAsyncFromSyncIterator`）。

### `pushForAwaitRecord` (`src/exec/iterator_ops.zig:126`)

- **签名**：`fn pushForAwaitRecord( _: *core.JSContext, stack: *stack_mod.Stack, iterator_value: core.JSValue, next_method: core.JSValue, ) !void`。
- **作用**：压入 for-await 的三槽记录：`[iterator, next, asyncIteratorCatchMarker()]`。
- **实现**：`push(iterator)` → `push(next)` → `pushOwned(forof_ops.asyncIteratorCatchMarker())`，每步之后挂 `errdefer` 把已压的槽弹回。`ctx` 参数未使用（签名里写成 `_`）。
- **所有权 / 错误 / 调用**：把 `[iterator, next, asyncMarker]` 三槽压好；`push` 与 `pushOwned` 在 TGC 下同实现（见 `forOfStart` 条），所以这里的差异只是记法。每压一槽挂一层 `errdefer` 往回弹，保证失败后栈上不留半截 for-await 记录。`ctx` 参数未用。error 只有 `reserveAdditional` 的 `error.OutOfMemory`。调用方 `iterator_ops.zig:59`（`@@asyncIterator` 路径）与 `:76`（sync→async 包装路径）。

### `createAsyncFromSyncIterator` (`src/exec/iterator_ops.zig:144`)

- **签名**：`pub fn createAsyncFromSyncIterator( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, sync_iterator: core.JSValue, function: ?*const bytecode.FunctionBytecode, frame: ?*frame_mod.Frame, comptime getValueProperty: anytype, comptime isCallableValue: anytype, ) !core.JSValue`。
- **作用**：建 %AsyncFromSyncIteratorPrototype% 风格的包装对象：把一个同步迭代器包成异步迭代器。
- **实现**：`rootValues` 钉住 sync iterator 与取到的 next。先 `iteratorNextMethod` 取 `next`，再建 `async_from_sync_iterator` 类对象（`errdefer destroyFromHeader`），把 sync iterator 与 next 写进 `iteratorTargetSlot` / `iteratorNextSlot`，最后用 `asyncFromSyncMethod` 造 `next`(id 1) / `return`(id 2) / `throw`(id 3) 三个原生方法并 `defineValueProperty` 装上。comptime 参数 `isCallableValue` 目前未使用（`_ = isCallableValue`），只为与调用点签名对齐。
- **所有权 / 错误 / 调用**：返回 owned 的 wrapper 对象：调用方 `iterator_ops.zig:73`（`forOfStart`）随即压栈，`array_ops.zig:3925`（`fromAsyncStart`）把它存进 `Array.fromAsync` 的状态对象。sync iterator 与 next 方法写进 `iteratorTargetSlot`/`iteratorNextSlot` 用的是 `setOptionalValueSlot`（带分代屏障），槽自持一份；三个 `asyncFromSyncMethod` 造的方法对象归 wrapper 的属性表。GC：`rooted_sync_iterator`/`rooted_next_method` 全程挂在 `ValueRootFrame` 上，因为 `Object.create` 与三次方法安装都可能触发回收。失败路径 `errdefer destroyFromHeader` 销毁尚未发布的 wrapper（同样只写不读的 `owns_next_method` 标志已删）。error：`asyncFromSyncMethod` 的 `error.TypeError` 与各处 OOM，以及 Get `next` 的用户异常。

### `testAsyncFromSyncGetValueProperty` (`src/exec/iterator_ops.zig:182`)

- **签名**：`fn testAsyncFromSyncGetValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：单测替身：固定返回注入的方法/属性。
- **实现**：忽略全部参数，直接返回文件级变量 `test_async_from_sync_next_method`（测试用它注入一个直接的 function-bytecode 值，验证包装期间该值被 root 住）。
- **所有权 / 错误 / 调用**：不分配、不建根、实际永不返回 error（声明成 `!core.JSValue` 只为与 `object_ops.getValueProperty` 的签名对齐）；返回的是文件级变量 `test_async_from_sync_next_method` 里那个 function-bytecode 值的浅拷贝，由测试自己持有，替身不转移所有权。无生产调用方，只在 `iterator_ops.zig:249` 作为 comptime `getValueProperty` 注入 `createAsyncFromSyncIterator`（用来验证包装期间该值被 root 住）。

### `testAsyncFromSyncIsCallable` (`src/exec/iterator_ops.zig:201`)

- **签名**：`fn testAsyncFromSyncIsCallable(value: core.JSValue) bool`。
- **作用**：单测替身：把「函数字节码或任意对象」都当作可调用，绕开完整的 `isCallableValue`。
- **实现**：薄封装，主体转发到 `value.isFunctionBytecode`、`objectFromValue`。
- **所有权 / 错误 / 调用**：无：测试替身，不分配、无 error、无生产调用方；只被本文件两条 GC 单测（`iterator_ops.zig:250`、`:1504` 两个实参位）当 comptime 依赖注入喂给 `createAsyncFromSyncIterator` / `iteratorConcatCall`，生产路径传的是 `call_runtime.isCallableValue`。

### `asyncFromSyncMethod` (`src/exec/iterator_ops.zig:257`)

- **签名**：`fn asyncFromSyncMethod(ctx: *core.JSContext, name: []const u8, method_id: i32) !core.JSValue`。
- **作用**：造 async-from-sync 包装器上的一个原生方法对象，并打上 1/2/3 的方法标记。
- **实现**：`core.function.nativeFunction(ctx, name, 0)` 建 length 为 0 的原生函数，`expectObject` 取对象；`method_id` 不在 1..3 → `error.TypeError`；`addAsyncFromSyncIteratorMethod` 打标记失败也 → `error.TypeError`。
- **所有权 / 错误 / 调用**：返回 owned 的原生函数对象，调用方 `createAsyncFromSyncIterator` 立刻用 `defineValueProperty` 挂到 wrapper 上；挂载失败时该函数对象不再显式销毁，由 GC 回收。error set：`method_id` 越界或 `addAsyncFromSyncIteratorMethod` 打标记失败给 `error.TypeError`（都属于内部不变量破坏，不带消息），另有 `nativeFunction` 的 OOM。调用方只有 `iterator_ops.zig:174`/`:177`/`:180` 这三处（next/return/throw）。

### `defineValueProperty` (`src/exec/iterator_ops.zig:266`)

- **签名**：`fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void`。
- **作用**：`createAsyncFromSyncIterator` 建 wrapper 时的三行样板收敛——把 `next` / `return` / `throw` 这三个 `asyncFromSyncMethod` 造出来的原生函数以 spec 要求的属性特性挂到 `%AsyncFromSyncIteratorPrototype%` 形状的 wrapper 上，是文件内唯一调用点（`iterator_ops.zig:175`/`178`/`181`）。
- **实现**：`object.defineOwnProperty(key, Descriptor.data(value, true, false, true))`：可写、不可枚举、可配置的数据属性。
- **所有权 / 错误 / 调用**：不持有所有权：属性槽接管 `value` 的一份引用，本函数返回后不再引用它。error 主要是 `defineOwnProperty` 的 OOM（键是预定义 atom，不会走 to-property-key 转换）。文件私有，调用方只有 `iterator_ops.zig:175`/`:178`/`:181`；`object_ops.zig`、`root.zig` 里的同名函数是各自独立的实现，不是本函数的调用点。

### `forInStart` (`src/exec/iterator_ops.zig:270`)

- **签名**：`pub fn forInStart( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, ) !void`。
- **作用**：`for_in_start`：弹出对象，建 for-in 迭代器并压回栈。
- **实现**：先 `reserveAdditional(1)` 保证回压不会失败，`pop` 取对象值，`forof_ops.createForInIterator` 建迭代器，`pushOwned` 上栈。
- **所有权 / 错误 / 调用**：弹出的对象值被消费；`createForInIterator` 铸出的迭代器由本函数 `pushOwned` 交给操作数栈（栈从此是它唯一的根）。开头的 `reserveAdditional(1)` 先把回压容量备好，让「pop 之后必然压得回去」成立。error：`stack.pop` 的 `error.StackUnderflow`（不在 `runtimeErrorInfo` 映射表里，不会变成 JS 异常）与 `createForInIterator` 透传的 OOM / proxy trap 异常。唯一调用方 `iterator_ops.zig:295`（`forInStartVm`）。

### `forInStartVm` (`src/exec/iterator_ops.zig:282`)

- **签名**：`pub noinline fn forInStartVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`forInStart` 的 VM 外壳：快照根对象可枚举字符串键时若抛（例如 Proxy ownKeys），转成 catchable 步进。
- **实现**：调用 `forInStart`；失败 `handleCatchableRuntimeError`，命中 catch → `.continue_loop`，否则传播；成功 `.done`。无 `function` / `is_async` 参数，因为 for-in 启动不读字节码、不走 asyncIterator。
- **所有权 / 错误 / 调用**：迭代器由 `createForInIterator` 分配、`forInStart` 压栈，本壳不碰所有权。错误处理同 `forOfStartVm`：catchable 的交给 `handleCatchableRuntimeError` 变 JS 异常并返回 `.continue_loop`，其余上抛。唯一调用方 `tailcall_dispatch_colds.zig:730`（`t[op.for_in_start]` 的 cold handler）。

### `iteratorNext` (`src/exec/iterator_ops.zig:297`)

- **签名**：`pub fn iteratorNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：`iterator_next`：用栈上记录的 `next` 方法带一个参数调用迭代器，结果换掉栈顶参数。
- **实现**：栈深不足 4 → `error.StackUnderflow`。从栈顶往下取 `iterator`(-4)、`next`(-3)、`arg`(-1)，`callValueOrBytecodeRoot(iterator, next, &.{arg})`；调用成功后 `pop` 掉参数槽，`pushOwned` 压入结果对象。
- **所有权 / 错误 / 调用**：栈上的 iterator/next/arg 三个值都按借用读（只索引 `stack.values`，不 pop 后再用）；`next()` 的结果由 `pushOwned` 交给栈，压之前先 `pop` 掉参数槽。error set：栈深不足 4 的 `error.StackUnderflow`——它**不在 `exception_ops.runtimeErrorInfo` 里**，`tryCatchInFrame` 认不出，所以不会变成可 catch 的 JS 异常，而是当引擎错误逃给宿主；其余是 `next()` 抛的用户异常与 OOM。唯一调用方 `iterator_ops.zig:334`（`iteratorNextVm`）。

### `iteratorNextVm` (`src/exec/iterator_ops.zig:320`)

- **签名**：`pub noinline fn iteratorNextVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`iteratorNext` 的 VM 外壳：`next(arg)` 抛出时把异常交给当前帧 catch。
- **实现**：调用 `iteratorNext`（从栈顶四元组取 iterator/next/arg，调用后 pop arg、`pushOwned` 结果）。失败 `handleCatchableRuntimeError`；成功 `.done`。
- **所有权 / 错误 / 调用**：结果所有权经 `iteratorNext` 的 `pushOwned` 落到操作数栈，本壳只转发。用户 `next()` 抛的异常在 `handleCatchableRuntimeError` 里交给本帧 catch；`error.StackUnderflow` 这类非映射错误直接上抛。唯一调用方 `tailcall_dispatch_colds.zig:735`（`t[op.iterator_next]`）。

### `iteratorCheckObject` (`src/exec/iterator_ops.zig:336`)

- **签名**：`pub fn iteratorCheckObject(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`iterator_check_object`：校验栈顶（`next()` 的结果）是对象。
- **实现**：`peekBorrowed` 为空 → `error.StackUnderflow`；值不是对象 → `error.TypeError`。不消费栈顶，`ctx` 参数未使用。
- **所有权 / 错误 / 调用**：只 `peekBorrowed` 读栈顶，不消费、不分配、不建根，`ctx` 未用。error set 两个：`error.StackUnderflow`（不在 `runtimeErrorInfo` 映射表，逃给宿主）与 `error.TypeError`——后者是**裸 sentinel**，本函数不挂消息，最终由 `createSentinelError` 按 `runtimeErrorInfo` 的空 message 造出 `TypeError`。唯一调用方 `iterator_ops.zig:355`（`iteratorCheckObjectVm`）。

### `iteratorCheckObjectVm` (`src/exec/iterator_ops.zig:342`)

- **签名**：`pub noinline fn iteratorCheckObjectVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：`iteratorCheckObject` 的 VM 外壳：栈顶不是对象时把 TypeError 交给 catch。
- **实现**：调用 `iteratorCheckObject`（`peekBorrowed`，非 object → `error.TypeError`）。失败 `handleCatchableRuntimeError`。`global` 在参数表末尾，与其它 `*Vm` 的位置不同，只为对齐 `handleCatchableRuntimeError` 形参。
- **所有权 / 错误 / 调用**：不消费栈顶，也不接管任何值；`global` 放在参数表末尾只为对齐 `handleCatchableRuntimeError` 的形参顺序。TypeError 在这里变成 JS 异常压给 catch handler。唯一调用方 `tailcall_dispatch_colds.zig:740`（`t[op.iterator_check_object]`）。

### `forAwaitOfNext` (`src/exec/iterator_ops.zig:357`)

- **签名**：`pub fn forAwaitOfNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：for-await 记录的一步：无参调用 `next()`，把结果 Promise/对象压栈。
- **实现**：栈深不足 3 → `error.StackUnderflow`。记录起点是 `len-3`，marker 槽是 `len-1`；先把 marker 槽写成 `undefined`（await 期间该记录不再是可关闭记录），再 `callValueOrBytecodeRoot(iterator, next, &.{})`，`pushOwned` 结果。
- **所有权 / 错误 / 调用**：所有权上最关键的一步是**把 marker 槽写成 `undefined`**：记录在 await 期间不再被 `isForOfRecordAt` 认成可关闭记录，于是 unwind 扫描不会在 await 悬挂时对它跑 IteratorClose；`iteratorGetValueDone` 之后再把 async marker 写回去。iterator/next 按借用读，`next()` 的结果 `pushOwned` 交栈。error：`error.StackUnderflow`（非映射错误，逃给宿主）与 `next()` 的用户异常/OOM。唯一调用方 `iterator_ops.zig:391`（`forAwaitOfNextVm`）。

### `forAwaitOfNextVm` (`src/exec/iterator_ops.zig:377`)

- **签名**：`pub noinline fn forAwaitOfNextVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`forAwaitOfNext` 的 VM 外壳：异步 `next()` 抛出时转成 catchable 步进。
- **实现**：调用 `forAwaitOfNext`（把 for-await 记录的 marker 槽写成 `undefined`，无参调用 next，`pushOwned` 结果 Promise/对象）。失败 `handleCatchableRuntimeError`。
- **所有权 / 错误 / 调用**：结果（通常是一个 promise）经 `pushOwned` 上栈，本壳不持有。异步 `next()` 抛出时由 `handleCatchableRuntimeError` 转成 catchable 步进。唯一调用方 `tailcall_dispatch_colds.zig:756`（`t[op.for_await_of_next]`）。

### `iteratorGetValueDone` (`src/exec/iterator_ops.zig:393`)

- **签名**：`pub fn iteratorGetValueDone( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：`iterator_get_value_done`：把 `next()` 结果对象拆成 value 与 done 两个栈值。
- **实现**：先 `reserveAdditional(1)`，栈深不足 2 → `error.StackUnderflow`；`pop` 出结果并 `expectObject`；先 Get `done` 做 `valueTruthy`，再 Get `value`；然后把当前栈顶（记录的 marker 槽）写回 `asyncIteratorCatchMarker()`，最后 `pushOwnedAssumeCapacity(value)` 与 `pushOwnedAssumeCapacity(boolean(done))`。预定义 atom 缺失时返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：`pop` 出来的结果对象被消费（读完 done/value 就不再引用）；两次 Get 的返回值由本函数压栈（`pushOwnedAssumeCapacity`，容量已由开头的 `reserveAdditional(1)` 加上被 pop 掉的那槽保证）。marker 槽重新写回 `asyncIteratorCatchMarker()`，把记录恢复成可关闭状态（与 `forAwaitOfNext` 的清空配对）。error set：`error.StackUnderflow`（非映射，逃给宿主）、`expectObject` 与预定义 atom 缺失的 `error.TypeError`，以及 `done`/`value` getter 抛的用户异常。唯一调用方 `iterator_ops.zig:434`（`iteratorGetValueDoneVm`）。

### `iteratorGetValueDoneVm` (`src/exec/iterator_ops.zig:420`)

- **签名**：`pub noinline fn iteratorGetValueDoneVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`iteratorGetValueDone` 的 VM 外壳：从 `{value, done}` 拆字段时 getter 抛出则进 catch。
- **实现**：调用 `iteratorGetValueDone`（pop 结果对象，Get `done`/`value`，把 async catch-marker 写回记录槽，再压 value 与 boolean done）。失败 `handleCatchableRuntimeError`。
- **所有权 / 错误 / 调用**：value 与 done 由 `iteratorGetValueDone` 压栈，本壳不接管。`done`/`value` 是普通属性读，用户 getter 抛出时经 `handleCatchableRuntimeError` 进本帧 catch。唯一调用方 `tailcall_dispatch_colds.zig:745`（`t[op.iterator_get_value_done]`）。

### `iteratorCall` (`src/exec/iterator_ops.zig:436`)

- **签名**：`pub fn iteratorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：`iterator_call`：按字节码里的 flags 对当前迭代器调用 `return` 或 `throw`。
- **实现**：先从 `frame.pc` 读 1 字节 flags 并前进 pc（越界 → `error.InvalidBytecode`）；栈深不足 4 → `error.StackUnderflow`。`iterator` 取 `len-4`、`arg` 取 `len-1`。`flags & 1` 选方法名 `"throw"`，否则 `"return"`；`internAtom` 后 Get。方法是 undefined/null 时只 `pushOwned(boolean(true))` 表示「方法缺失」并返回（不弹参数）。否则 `flags & 2` 置位时无参调用，未置位时带 `arg` 调用；随后 `reserveAdditional(1)`、`pop` 掉参数槽，压入结果与 `boolean(false)`。
- **所有权 / 错误 / 调用**：有副作用的所有权点有两个：读 flags 时推进 `frame.pc`（失败前不回退），以及「方法缺失」分支只压 `boolean(true)` 而**不弹参数槽**，栈形与正常分支（pop 参数、压结果 + `boolean(false)`）不同，这条不对称是编译器与本 opcode 的约定。iterator/arg 按借用读，`return`/`throw` 的返回值 `pushOwnedAssumeCapacity` 交栈。error set：`error.InvalidBytecode`（pc 越界）与 `error.StackUnderflow` 都不在 `runtimeErrorInfo` 映射表里，不会变成可 catch 的 JS 异常；`internAtom` 会 OOM；Get 与调用的用户异常照常透传。唯一调用方 `iterator_ops.zig:485`（`iteratorCallVm`）。

### `iteratorCallVm` (`src/exec/iterator_ops.zig:471`)

- **签名**：`pub noinline fn iteratorCallVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`iteratorCall` 的 VM 外壳：`return`/`throw` 方法调用失败时转成 catchable 步进。
- **实现**：调用 `iteratorCall`（读一字节 flags：`flags & 1` 选 throw vs return，`flags & 2` 置位表示无参调用、未置位则带栈顶参数）。失败 `handleCatchableRuntimeError`。
- **所有权 / 错误 / 调用**：栈形由 `iteratorCall` 决定（方法存在：pop 参数后压结果 + `boolean(false)`；方法缺失：只压 `boolean(true)`），本壳不改。用户 `return`/`throw` 抛出时走 `handleCatchableRuntimeError`；`error.InvalidBytecode`/`error.StackUnderflow` 直接上抛。唯一调用方 `tailcall_dispatch_colds.zig:750`（`t[op.iterator_call]`）。

### `forOfIteratorIndex` (`src/exec/iterator_ops.zig:491`)

- **签名**：`pub fn forOfIteratorIndex(stack: *const stack_mod.Stack, depth: u8) !usize`。
- **作用**：按 `for_of_next` 的 depth 操作数定位 for-of 记录的 iterator 槽下标，并校验它确实是一条记录。
- **实现**：`required = depth + 3`，栈深不足 → `error.InvalidBytecode`；`iterator_index = len - required`；记录第三槽必须是 `isIteratorCatchMarker`，iterator 槽必须是 `undefined` 或对象，否则同样 `error.InvalidBytecode`。depth 是字节码契约的一部分：接受栈上别处找到的迭代器会在异常完成时关错迭代器。
- **所有权 / 错误 / 调用**：只读校验：不分配、不改栈，返回的是下标而非所有权。error set 只有 `error.InvalidBytecode`，它不在 `runtimeErrorInfo` 映射表里，所以不会变成 JS 异常——这正合语义，非法 depth 是字节码损坏而不是脚本错误。调用方三处：`iterator_ops.zig:518`（`forOfNext`）、`:561`（`finishForOfNextResult`）、`tailcall_dispatch.zig:2877`（`op_for_of_next` 的内联臂先用它定位记录，失败就 `else |_| {}` 落回 `forOfNextVm`）。

### `forOfNext` (`src/exec/iterator_ops.zig:502`)

- **签名**：`pub fn forOfNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：`for_of_next`：按 depth 定位记录，走一步迭代，把 value 与 done 压栈。
- **实现**：先读 1 字节 depth 操作数并前进 pc（越界 → `error.InvalidBytecode`），`forOfIteratorIndex` 定位记录；`errdefer forof_ops.abandonForOfIteratorAtIndex`（next 已失败的迭代器不再 return()）。依次试三条快路径：`fastArrayForOfNext`、`fastMapSetForOfNext`、`fastGeneratorForOfNext`，命中即返回（它们自己压 value+done，不造 `{value,done}` 对象）。否则：iterator 槽已是 `undefined` 就直接产出 `{undefined, done=true}`；不然取 `iterator_index + 1` 的 `next`（缺槽 → `error.StackUnderflow`）走 `iteratorStepWithNext`。最后 `reserveAdditional(2)`，done 时把 iterator 槽清成 `undefined`，再压 value 与 `boolean(done)`。
- **所有权 / 错误 / 调用**：`errdefer forof_ops.abandonForOfIteratorAtIndex` 是核心的所有权动作：`next()` 或结果读取失败时把记录的 iterator 槽写成 `undefined`，交出这一份引用，后续 unwind 不会再对刚失败的迭代器调 `return()`。产出的 value 来自快路径的借用槽（数组元素、集合条目）或 `iteratorStepWithNext` 的 Get 结果，一律 `pushOwnedAssumeCapacity` 交栈；`done` 时 iterator 槽同样清成 `undefined`，记录就地变成已关闭。error set：`error.InvalidBytecode`（pc 越界 / depth 非法）与 `error.StackUnderflow` 不映射成 JS 异常，`next()`、`done`/`value` getter 抛的用户异常与 OOM 则沿 `forOfNextVm` 进 catch。唯一调用方 `iterator_ops.zig:830`（`forOfNextVm`）。

### `finishForOfNextResult` (`src/exec/iterator_ops.zig:546`)

- **签名**：`pub fn finishForOfNextResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, depth: u8, next_result: core.JSValue, ) !void`。
- **作用**：字节码 `next()` 在当前 Machine 里返回后，接着完成 `for_of_next` 的后半段：读 done/value 并压栈。
- **实现**：调用期间调用方栈被刻意保持原样，所以 depth 仍指向同一条记录：`forOfIteratorIndex` 重新定位并挂 `errdefer abandonForOfIteratorAtIndex`。`next_result` 必须是对象（否则 `error.TypeError`），用 `iteratorResultProperty` 读 `done`，`valueTruthy` 为真时 value 直接取 `undefined`（不再 Get），否则再读 `value`。普通字节码帧入口已预留 `stack_size + 1`，所以只在容量真不够时才 `reserveAdditional(2)`；done 时把 iterator 槽清成 `undefined`，最后压 value 与 `boolean(done)`。
- **所有权 / 错误 / 调用**：`next_result` 的所有权在**每条路径上**都归本函数（函数头注释明写）：调用方把内联 `next()` 帧的返回值交出来后不再引用它。同样挂 `errdefer abandonForOfIteratorAtIndex`，读 done/value 失败时放弃该迭代器。`iteratorResultProperty` 快路径返回的是借用值，随即被 `valueTruthy` 消费或压栈，中间没有分配点。error set：结果不是对象给 `error.TypeError`（裸 sentinel，无消息），加上 getter 抛的用户异常与 `reserveAdditional` 的 OOM；`forOfIteratorIndex` 的 `error.InvalidBytecode` 同样不映射成 JS 异常。唯一调用方 `tailcall_dispatch.zig:1446`（`completeForOfNextContinuation`，内联 `next()` 帧返回后的续作）。

### `iteratorResultProperty` (`src/exec/iterator_ops.zig:605`)

- **签名**：`inline fn iteratorResultProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, receiver: core.JSValue, atom_id: core.Atom, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !core.JSValue`。
- **作用**：读迭代结果对象的 `done` / `value`：先走自有数据槽快探，再退回权威属性解析。
- **实现**：对齐 qjs `JS_IteratorNext2` 的分档：非 proxy 且无 exotic 方法时先 `findOwnDataValueFast`，命中直接返回借用值；命中的是慢属性（accessor/var ref/auto-init，`slow_property` 置位）则转 `object_ops.getValueProperty`。否则再试 `property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath`（走普通 shape/原型链，真缺失返回 undefined），最后仍未命中才落到 `getValueProperty`。
- **所有权 / 错误 / 调用**：快路径返回的是**借用**的自有数据槽值（源码注释 "borrowed data value"），调用方必须在下一个可分配点之前消费掉——`finishForOfNextResult` 里 `done` 立刻进 `valueTruthy`、`value` 立刻 `pushOwnedAssumeCapacity`，中间不分配，所以借用是安全的。慢路径的返回值来自 `object_ops.getValueProperty`（TGC 下同样不需要释放）。本函数自己不分配、不建根，error 全是 `getValueProperty` 的透传。`inline` 且文件私有，唯一调用方 `finishForOfNextResult`（`iterator_ops.zig:565` 读 `done`、`:580` 读 `value`）。

### `fastArrayForOfNext` (`src/exec/iterator_ops.zig:632`)

- **签名**：`fn fastArrayForOfNext(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize) !bool`。
- **作用**：Array Iterator 的 for-of 快路径：直接压 value+done，不造 `{value,done}` 结果对象；条件不满足返回 false 回退通用协议。
- **实现**：层层设卡，任一条不满足就 `return false` 回退通用路径：记录必须有 next 槽；iterator 是 `array_iterator` 类；next 函数带 `isArrayIteratorNextFunction` 标记（未被改写）；kind 只接受 1(keys) 与 2(values)，3(entries) 不走快路径。target 槽已空则直接压 `undefined` + `true`。target 必须是数组且无 exotic 方法、非 proxy。`index >= arrayLength()` 时清 target 槽、iterator 槽写 `undefined`，压 `undefined` + `true`。下标超过 `atom.max_int_atom` 回退。kind=1 压 `int32(index)`；kind=2 要求该下标不在 shape 属性里、且在 dense `arrayElements()` 范围内，取元素值。命中后 `iteratorIndexSlot` 加一，压 value 与 `boolean(false)`。
- **所有权 / 错误 / 调用**：返回 true = 已经把 value+done 压进栈并推进了游标，返回 false = **一个字节都没动**，调用方可以安全回落通用协议（所有 `return false` 都在任何压栈/加下标之前）。压的值不新建对象：kind=1 是立即数 `int32`，kind=2 是 dense `arrayElements()` 里的借用元素，靠栈上 iterator→target 这条边保活；耗尽分支用 `clearOptionalValueSlot` 断开 target 并把记录的 iterator 槽写成 `undefined`。error set 只有 `stack.reserveAdditional` 的 `error.OutOfMemory`——本快路径不会执行任何用户代码。唯一调用方 `iterator_ops.zig:520`（`forOfNext` 的第一条快路径）。

### `fastMapSetForOfNext` (`src/exec/iterator_ops.zig:696`)

- **签名**：`fn fastMapSetForOfNext(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize) !bool`。
- **作用**：内建 Map/Set 迭代器的 for-of 快路径：推进条目游标并直接压值，跳过每步的结果对象分配；条件不满足返回 false 回退。
- **实现**：iterator 必须是 `map_iterator`/`set_iterator`，kind ∈ {1 key, 2 value, 3 key_value}，next 函数解码出的 native builtin 必须是 `.collection` 域的 `iterator_next`（未被用户改写）。target 槽为空即走 `finishMapSetForOfDone(clear_target = false)`；target 必须是 Map/Set。`retainCollectionIteratorCursor` 先把游标停好（同通用 `collectionIteratorNext`，quickjs.c:52605），然后从 `iteratorIndexSlot` 扫 `collectionEntriesSlot`，跳过 `!entry.active` 的墓碑；kind=1 取 key，kind=2 对 Set 取 key、对 Map 取 value（都是集合持有的借用槽），kind=3 用 `buildCollectionEntryPair` 现造 `[k,v]`；`reserveAdditional(2)` 后压 value 与 `boolean(false)`。扫完则 `finishMapSetForOfDone(clear_target = true)`。
- **所有权 / 错误 / 调用**：同样的「true=已处理 / false=未动栈」契约。kind=1/2 压的是集合条目里的借用 key/value（集合经 iterator 的 target 边活着，`reserveAdditional` 触发的回收伤不到它），kind=3 由 `buildCollectionEntryPair` 现造一个 owned 的 `[k,v]` 数组直接压栈。`retainCollectionIteratorCursor` 把游标停在当前位置（与通用 `collectionIteratorNext` 同一处理，quickjs.c:52605），耗尽时 `finishMapSetForOfDone` 调 `detachCollectionIteratorTarget` 放掉迭代器对集合的引用。error set 只有分配失败（`reserveAdditional` / `createArray`）——不执行用户代码。唯一调用方 `iterator_ops.zig:521`。

### `fastGeneratorForOfNext` (`src/exec/iterator_ops.zig:751`)

- **签名**：`fn fastGeneratorForOfNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, iterator_index: usize, ) !bool`。
- **作用**：未被改写的同步生成器的 for-of 快路径：`syncGeneratorStep` 恢复一步后直接压 value+done；条件不满足返回 false 回退（所有回退都在恢复之前，不会二次推进）。
- **实现**：iterator 必须是 `generator` 类、next 带 `isGeneratorNextFunction` 标记；随后 `call_runtime.syncGeneratorStep` 恢复一步，返回 null（非同步生成器 receiver）时回退——所有 `return false` 都发生在恢复之前，所以回退不会二次推进生成器。拿到 value/done 后 `reserveAdditional(2)`，done 时把 iterator 槽写 `undefined`，压 value 与 `boolean(done)`，跳过通用协议的 `{value,done}` 结果对象（qjs JS_IteratorNext2 内建快路径，quickjs.c:16548）。
- **所有权 / 错误 / 调用**：与另外两条快路径不同：本路径**会执行用户代码**（`syncGeneratorStep` 恢复生成器体），因此 error set 包含生成器体抛的任意用户异常与 OOM。所有权：`step.value` 是恢复结果，`pushOwnedAssumeCapacity` 交栈；done 时把记录的 iterator 槽写成 `undefined`。所有 `return false` 都发生在 resume 之前，所以回落通用路径不会二次推进生成器（唯一能在恢复之后返回 false 的情形被 `syncGeneratorStep` 的 null 判定排除在恢复之前）。唯一调用方 `iterator_ops.zig:522`。

### `buildCollectionEntryPair` (`src/exec/iterator_ops.zig:784`)

- **签名**：`fn buildCollectionEntryPair(rt: *core.JSRuntime, is_set: bool, entry: core.object.CollectionEntry, prototype: ?*core.Object) !core.JSValue`。
- **作用**：为 Map/Set 的 entries 迭代造 `[key, value]` 这一对的 dense 数组。
- **实现**：照 qjs `js_create_array`（quickjs.c:9601）：先 `Object.createArray`（原型是 realm 的 Array.prototype，可为 null）并挂 `errdefer destroyFromHeader`，再 `createArrayStorageSlice(2)` 预分配存储（TGC S4-b §2.2 的 `.array_storage` cell），直接写 `elements[0] = entry.key`、`elements[1] = if (is_set) entry.key else entry.value`，`adoptDenseArrayElementsAssumingEmpty` 收编，并补上 `flags.may_have_indexed_properties`。刻意不用两次 `defineOwnProperty`（省掉 atomFromUInt32 + 描述符 + 下标属性机器）；所有分配都在写入之前完成，中途不会插入 GC。
- **所有权 / 错误 / 调用**：返回 owned 的 dense 数组，调用方 `fastMapSetForOfNext`（`iterator_ops.zig:732`，kind=3 臂）直接压栈；`entry` 的 key/value 是集合持有的借用槽，本函数只把值写进新数组的存储。所有分配（`createArray`、`createArrayStorageSlice`）都发生在写值之前，所以借用与 adopt 之间没有 GC 窗口；失败路径 `errdefer destroyFromHeader` 销毁未发布的数组。error set 只有 `error.OutOfMemory`。

### `finishMapSetForOfDone` (`src/exec/iterator_ops.zig:803`)

- **签名**：`fn finishMapSetForOfDone(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize, clear_target: bool) !bool`。
- **作用**：Map/Set 快路径的收尾：产出一次 done 步，并按需切断迭代器与集合的关联。
- **实现**：`clear_target` 为真时对 iterator 对象调 `detachCollectionIteratorTarget`（正常耗尽）；然后 `reserveAdditional(2)`、把栈上 iterator 槽写成 `undefined`，压 `undefined` 与 `boolean(true)`，恒定返回 true 表示快路径已处理。
- **所有权 / 错误 / 调用**：恒返回 true（「快路径已处理」），不交出任何所有权：`clear_target` 为真时 `detachCollectionIteratorTarget` 断开迭代器→集合的边，随后把栈上 iterator 槽写成 `undefined` 放弃记录里的迭代器，再压 `undefined` + `true`。error set 只有 `reserveAdditional` 的 `error.OutOfMemory`。调用方是 `fastMapSetForOfNext` 的两处：`iterator_ops.zig:712`（target 槽已空，`clear_target=false`）与 `:745`（条目扫完，`clear_target=true`）。

### `forOfNextVm` (`src/exec/iterator_ops.zig:816`)

- **签名**：`pub noinline fn forOfNextVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`forOfNext` 的 VM 外壳：`next()` / 快路径失败时把异常交给当前帧 catch。
- **实现**：调用 `forOfNext`（读 depth 操作数、定位三元组、fastArray/MapSet/Generator 快路径或 `iteratorStepWithNext`，压 value+done）。失败 `handleCatchableRuntimeError`。`forOfNext` 自己的 `errdefer` 已 `abandonForOfIteratorAtIndex`，本包装不再二次 close。
- **所有权 / 错误 / 调用**：value 与 done 由 `forOfNext` 压栈，本壳不接管；`forOfNext` 的 `errdefer` 已经放弃失败的迭代器，所以这里**不再**做第二次 close（重复 close 会对同一个 abrupt completion 调两次 `return()`）。唯一调用方 `tailcall_dispatch.zig:2949`——`op_for_of_next` 的内联快臂走不通时的回落边。

### `forInNext` (`src/exec/iterator_ops.zig:839`)

- **签名**：`pub noinline fn forInNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, ) !void`。
- **作用**：步进 for-in 迭代器：先耗尽当前链对象的快照键，耗尽后惰性走原型，并对每个候选做 **own** 存在探测（删除检测），对齐 qjs `js_for_in_next`。
- **实现**：对照 quickjs.c:16404。栈顶不是 `JS_CLASS_FOR_IN_ITERATOR` → `pushForInDone`。循环：`iteratorIndexSlot` 未耗尽则取键；fast-array 档用 `__JS_AtomFromUInt32(idx)` 即时生成下标。耗尽时：若尚未进原型链则 `forInPrepareProtoChainEnum`（无任何可枚举原型键则 done）；然后 `objectGetPrototypeOfValue`，null 则 done，否则把原型写进 `iteratorTargetSlot`，`forInSnapshotOwnStringKeys` 替换 atom 表（旧表 `freeAtomList`，新键 `shadeAtomIfMarking`）。原型链档先 `existsOwnProperty` 去重再 `forInDefineVisited`。删除检测一律 `proxyAwareExistsOwnProperty`（gopd trap，**不是**会走原型的 `[[HasProperty]]`）。命中后 `atoms.toStringValue` 压 key，再压 `done=false`。
- **所有权 / 错误 / 调用**：栈顶迭代器是 `peek` 借用，不消费；产出的 key 字符串由 `atoms.toStringValue` 铸出、`pushOwnedAssumeCapacity` 交栈。原型步进时旧 atom 表由 `freeAtomList` 释放、新表移交 `iteratorAtomKeysSlot` 前逐个 `shadeAtomIfMarking`（TGC S3 §2.3），target 槽换成原型对象走 `setOptionalValueSlot`（带屏障）、走到链尾用 `clearOptionalValueSlot` 断开。错误分两层：状态不合法（栈顶不是 for-in 迭代器、target 为空）**不报错**，按 qjs fail-safe 直接 `pushForInDone`；真正的 error 是 `error.StackUnderflow`（空栈，非映射错误）与 proxy `getOwnPropertyDescriptor`/`getPrototypeOf`/`ownKeys` trap 抛的用户异常、快照的 OOM，它们经 `forInNextVm` 进 catch。唯一调用方 `iterator_ops.zig:994`（`forInNextVm`）。

### `pushForInDone` (`src/exec/iterator_ops.zig:919`)

- **签名**：`fn pushForInDone(stack: *stack_mod.Stack) !void`。
- **作用**：for-in 的 done 步：压 `undefined` 与 `true`。
- **实现**：`reserveAdditional(2)` 后 `pushOwnedAssumeCapacity(undefined)`、`pushOwnedAssumeCapacity(boolean(true))`。
- **所有权 / 错误 / 调用**：只压两个立即数（`undefined` 与 `boolean(true)`），不涉及所有权；唯一 error 是 `reserveAdditional` 的 `error.OutOfMemory`。6 处调用全在 `forInNext`（`iterator_ops.zig:853`、`:854`、`:860`、`:866`、`:874`、`:891`），即 for-in 的全部 done 出口——包括非迭代器/target 为空的 fail-safe 分支。

### `forInPrepareProtoChainEnum` (`src/exec/iterator_ops.zig:929`)

- **签名**：`fn forInPrepareProtoChainEnum( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator: *core.Object, root: *core.Object, ) !bool`。
- **作用**：根对象键耗尽、准备进原型链阶段：判断整条原型链还有没有可枚举字符串键，并把根快照的键种进 visited 集。返回 true 表示枚举已结束。
- **实现**：对齐 qjs `js_for_in_prepare_prototype_chain_enum`（quickjs.c:16341）。先从 root 的原型开始，用 `rootValues` 钉住游标值，逐级 `forInHasEnumerableStringKey` 探测（ENUM_ONLY 快筛，quickjs.c:16353-16377）；整条链都没有可枚举字符串键就返回 true，调用方直接 done。否则进 slow_path（quickjs.c:16379-16391）：fast-array 档要先把计数快照转成真键表——`forInSnapshotOwnStringKeys` 取键（本地持有、用完 `freeAtomList`，因为调用方随即会把 tab 换成原型的），把 `is_array` 归 0，并把这些键逐个 `forInDefineVisited`；普通档则把现有 `iteratorAtomKeys()`（非可枚举项在快照时已进 visited）逐个 `forInDefineVisited`。最后返回 false。
- **所有权 / 错误 / 调用**：fast-array 档转换出的键表是本函数自己的（`defer freeAtomList`，因为调用方随后会把 payload 的表整个换成原型的快照）；visited 标记以属性形式落在迭代器对象上，归迭代器。GC：原型游标 `obj1_val` 跨逐级 `getPrototypeOf`/ownKeys（可进 proxy trap）挂在 `ValueRootFrame` 上。error：proxy 的 `getPrototypeOf`/`ownKeys`/gopd trap 抛的用户异常与 `forInDefineVisited` 的 OOM，全部直接上抛、不吞。唯一调用方 `iterator_ops.zig:865`（`forInNext` 在根对象键耗尽、尚未进原型链时调用一次）。

### `forInNextVm` (`src/exec/iterator_ops.zig:981`)

- **签名**：`pub noinline fn forInNextVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`forInNext` 的 VM 外壳：gopd trap / 原型走抛出是普通 catchable JS 异常，对齐 qjs `js_for_in_next` 返回 -1 走进 `OP_for_in_next` 的异常路径。
- **实现**：调用 `forInNext`；失败 `handleCatchableRuntimeError`。无 `function` 参数：for-in 步进不读字节码操作数。
- **所有权 / 错误 / 调用**：key 与 done 由 `forInNext` 压栈，本壳不接管。trap 抛出经 `handleCatchableRuntimeError` 变成本帧可 catch 的 JS 异常（对齐 qjs `js_for_in_next` 返回 -1 走 `OP_for_in_next` 异常路径）。唯一调用方 `tailcall_dispatch_colds.zig:761`（`t[op.for_in_next]`）。

### `iteratorClose` (`src/exec/iterator_ops.zig:996`)

- **签名**：`pub fn iteratorClose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, ) !void`。
- **作用**：`iterator_close`：消费三槽迭代器记录，并按 marker 类型执行同步或 for-await 的 IteratorClose。
- **实现**：opcode 契约固定消费三槽。先 `pop` marker：既不是 iterator marker 也不是 `undefined`（qjs 风格 generator-return 清理用的哑 marker）就 `error.InvalidBytecode`；`isAsyncIteratorCatchMarker` 决定是不是 for-await 记录。再 `pop` 掉 next 槽与 iterator 槽；iterator 已是 `undefined` 则直接返回。async 记录走 `promise_ops.closeForAwaitIteratorFromVm`，同步记录走 `forof_ops.closeIteratorFromVm`。刻意不从 iterator/next 的值形状去猜记录：proxy 与宿主 callable 让这些形状既不唯一也不稳定。
- **所有权 / 错误 / 调用**：三槽记录在这里被 `pop` 消费掉，迭代器的最后一份栈引用随之交给 close 实现；iterator 已是 `undefined`（被 `abandonForOfIterator*` 放弃或已 done）时直接返回，不会二次 `return()`。error set：marker 既不是 iterator marker 也不是 `undefined` 时 `error.InvalidBytecode`（不在 `runtimeErrorInfo` 映射表里，不变成 JS 异常）；其余是 `closeIteratorFromVm` / `closeForAwaitIteratorFromVm` 透传的 `error.TypeError` 与用户 `return()` 抛的异常。唯一调用方 `iterator_ops.zig:1034`（`iteratorCloseVm`）。

### `iteratorCloseVm` (`src/exec/iterator_ops.zig:1021`)

- **签名**：`pub noinline fn iteratorCloseVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`iteratorClose` 的 VM 外壳：消费三槽记录并 `return()` 时，把 close 路径的异常交给当前帧 catch。
- **实现**：调用 `iteratorClose`（pop marker/next/iterator；非 catch-marker 且非 `undefined` → `error.InvalidBytecode`；async 走 `closeForAwaitIteratorFromVm`，sync 走 `closeIteratorFromVm`；iterator 已是 `undefined` 则 no-op）。失败 `handleCatchableRuntimeError`。
- **所有权 / 错误 / 调用**：三槽记录被 `iteratorClose` pop 消费；`return()` 内部的二次错误由 close 实现自己处理，本壳只把顶层 error 交给 `handleCatchableRuntimeError`。唯一调用方 `tailcall_dispatch_colds.zig:766`（`t[op.iterator_close]`）。

### `arrayIteratorPrototypeFromContext` (`src/exec/iterator_ops.zig:1036`)

- **签名**：`pub fn arrayIteratorPrototypeFromContext( ctx: *core.JSContext, global: *core.Object, ) !*core.Object`。
- **作用**：惰性建出并缓存 realm 的 %ArrayIteratorPrototype%。
- **实现**：先查 `ctx.class_prototypes[array_iterator]`，已是对象就直接返回。否则 `iteratorPrototype(rt, global, "Array Iterator")` 建一个以 %IteratorPrototype% 为原型、带 toStringTag 的对象（`errdefer destroyFromHeader`），用 `defineNativeDataMethodWithNativeId` 装 `next`（`.iterator` 域的 `array_iterator_next` id），再把该函数对象打上 `addArrayIteratorNextFunction` 标记供 for-of 快路径识别。**不**自装 `@@iterator`：%ArrayIteratorPrototype% 要从 %IteratorPrototype% 继承，否则 ES6 原型链测试（proto2 有 own @@iterator）会挂。最后写回 class_prototypes 槽，并因为是裸槽写而手动补 `gc.generationalBarrier`。
- **所有权 / 错误 / 调用**：返回的是**借用**指针：第一次调用铸出原型后写进 `ctx.class_prototypes[array_iterator]`，此后归 realm，调用方不得销毁（发布前的失败由 `errdefer destroyFromHeader` 兜）。那次写槽是裸槽存储，所以本函数手动补 `gc.generationalBarrier(&ctx.header, object.gcHeader())`——realm 早已进老代且 host create-ref 被消费后不再是根，少这道屏障会让 minor 的 sticky mark 停在 realm 上、把新原型误收。error set：class_prototypes 槽里不是对象、预定义 atom 缺失、`addArrayIteratorNextFunction` 打标记失败都给 `error.TypeError`（内部不变量，无消息），另有各处 OOM。调用方：`iterator_ops.zig:1104`（`arrayIteratorMethod`）与 `array_ops.zig:6354`（`arrayIteratorMethodRecord`，record 分发臂），`array_ops.zig:144` 是同名转发壳。

### `arrayIteratorMethod` (`src/exec/iterator_ops.zig:1078`)

- **签名**：`pub fn arrayIteratorMethod( ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, ) !?core.JSValue`。
- **作用**：Array/TypedArray 的 `keys`/`values`/`entries`：按函数对象上记录的 kind 造一个 array iterator。
- **实现**：`function_object.arrayIteratorKind()` 不在 1..3 返回 `null`，让上层继续级联到别的 builtin。receiver 是 null/undefined → `error.TypeError`；原始值先 `primitiveObjectForAccess` 包装，并用 `rootValues` 钉住。若这是 TypedArray 原型上的方法（`isTypedArrayPrototypeMethod`），receiver 必须是 typed array 且未 detach、未越界。随后取 `arrayIteratorPrototypeFromContext` 作原型建 `array_iterator` 对象（`errdefer destroyFromHeader`），把 target 写进 `iteratorTargetSlot`、`index = 0`、`kind = kind`。
- **所有权 / 错误 / 调用**：返回 owned 的新 iterator 对象，或 `null` 表示「这不是 keys/values/entries」，让 `call_runtime` 的 builtin 级联继续往下试——`null` 不是错误。receiver 若是原始值，`primitiveObjectForAccess` 包出的对象在建 iterator 期间挂在 root frame 上，写进 `iteratorTargetSlot` 后立刻把局部置 `undefined` 解除根；发布前失败由 `errdefer destroyFromHeader` 回收。error set：receiver 为 null/undefined、TypedArray 方法遇到非 typed array / 已 detach / 越界都给 `error.TypeError`，加上 OOM。唯一调用方 `call_runtime.zig:1243`。

### `arrayIteratorNext` (`src/exec/iterator_ops.zig:1109`)

- **签名**：`pub fn arrayIteratorNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, ) !?core.JSValue`。
- **作用**：%ArrayIteratorPrototype%.next 的实现：产出下一个 key/value/entry 的迭代结果对象。
- **实现**：receiver 必须是 `array_iterator` 类对象，否则 `error.TypeError`。target 槽已空 → 直接 `createIteratorResult(undefined, true)`。length 分三档：typed array 先查 detach/越界（都抛 TypeError）再取 `typedArrayLength`；真数组取 `arrayLength()`；其它对象 Get `length` 后 `toLengthIndex` 并截到 `maxInt(u32)`。`index >= length` 时先造 done 结果再清空 target 槽。否则 index 加一，`arrayIteratorValue` 取值，包进 `createIteratorResult(value, false)`。
- **所有权 / 错误 / 调用**：返回 owned 的 `{value, done}` 结果对象（`createIteratorResult` 铸，调用方转给 JS）；耗尽分支**先**造 done 结果**再** `clearOptionalValueSlot` 断 target，顺序不能反（分配可能触发回收，target 还得给 tracer 看见）。error set：receiver 不是 array_iterator、TypedArray 已 detach/越界给 `error.TypeError`，普通对象走 `length` 属性读时会执行用户 getter（异常透传），另有 OOM。调用方：`iterator_ops.zig:3190`（`iteratorCallForNativeRecord` 的 `array_iterator_next` intrinsic 臂）与 `array_ops.zig:6383`（`arrayIteratorNextFast`）；`array_builtin_ops.zig` 里的同名函数是另一套 host-tier 实现，不是本函数的调用方。

### `arrayIteratorValue` (`src/exec/iterator_ops.zig:1138`)

- **签名**：`pub fn arrayIteratorValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, index: u32, kind: u8, comptime getValueProperty: anytype, ) !core.JSValue`。
- **作用**：按 kind 产出 array iterator 的一步值：1=下标、2=元素、3=`[index, element]` 对。
- **实现**：`switch (kind)`：1 直接 `int32(index)`；2 对 typed array 走 `typedArrayGetIndex`，否则用 comptime 注入的 `getValueProperty` 读 `atomFromUInt32(index)`；3 先 `rootValues` 钉住 pair 与元素值，`Object.createArray`（原型取 realm Array.prototype，`errdefer destroyFromHeader`），再取元素值，然后两次 `defineOwnProperty` 写 0/1 下标（均 writable/enumerable/configurable）；其它 kind → `error.TypeError`。
- **所有权 / 错误 / 调用**：返回 owned 值：kind=1 是立即数，kind=2 是 `typedArrayGetIndex` / `getValueProperty` 的结果，kind=3 是新建的 `[index, element]` 数组。kind=3 期间 `pair_value` 与 `value` 都在 root frame 上（元素读可能执行用户 getter 并触发回收），发布前失败由 `errdefer destroyFromHeader` 回收。error set：非法 kind 给 `error.TypeError`，加上元素 getter 的用户异常与 OOM。调用方 `iterator_ops.zig:1139`（`arrayIteratorNext`）；`:1216` 是本文件那条验证「造 pair 期间元素被 root 住」的 GC 单测，`array_builtin_ops.zig:744` 是同名的另一实现。

### `testArrayIteratorGetValueProperty` (`src/exec/iterator_ops.zig:1175`)

- **签名**：`fn testArrayIteratorGetValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：单测替身：跳过完整属性解析，直接 `expectObject` + `getProperty` 读自有属性。
- **实现**：关键调用：`property_ops.expectObject`、`object.getProperty`。
- **所有权 / 错误 / 调用**：无：测试替身，不分配、无自有 error（只透传 `expectObject`/`getProperty`），生产无调用方；只被 `iterator_ops.zig:1216` 那条 GC 单测当 comptime 注入喂给 `arrayIteratorValue`。

### `iteratorPrototypeFromGlobal` (`src/exec/iterator_ops.zig:1236`)

- **签名**：`pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：取 realm 的 %IteratorPrototype%。
- **实现**：优先 `rt.contextForGlobalIncludingConstructing(global)` 再 `realm.classPrototypeObject(class.ids.iterator)`——%IteratorPrototype% 是 realm 构造时固定的 intrinsic，不能靠走 `globalThis.Iterator.prototype` 解析（Iterator-Helpers polyfill 覆写 `globalThis.Iterator` 会把所有惰性建出的内建迭代器原型从它上面摘掉）；realm 里没有时才回退全局走查：`global.getOwnDataObjectBorrowed("Iterator")` 再取 `prototype`，供无 realm 缓存的 bare-runtime 层用。任一步缺失返回 `null`。
- **所有权 / 错误 / 调用**：返回的是 realm（或全局对象）持有的**借用**指针，可能为 `null`；不分配、不建根、没有 error set（返回 `?*core.Object` 而不是 error union），`getOwnDataObjectBorrowed` 的名字就是借用契约。调用方 6 处以上：`iterator_ops.zig:1261`/`:1267`（`iteratorPrototype` 取 base）、`:1323`（`iteratorPrototypeAccessorSet` 判定 receiver 是不是 home object）、`object_ops.zig:225`（generator 原型的基）、`:2173`（`iteratorIsOnIteratorPrototypeChain`）、`:2185`（`wrapForValidIteratorPrototype`）、`collection_ops.zig:679`，另有 `object_ops.zig:2208` 的同名转发壳。

### `defineToStringTag` (`src/exec/iterator_ops.zig:1249`)

- **签名**：`pub fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void`。
- **作用**：在对象上定义 `@@toStringTag` 数据属性（不可写、不可枚举、可配置）。
- **实现**：取预定义 symbol atom `Symbol.toStringTag`（缺失 → `error.TypeError`），`createStringValue(tag_name)` 造标签串，`defineOwnProperty(Descriptor.data(tag, false, false, true))`。
- **所有权 / 错误 / 调用**：新建的 tag 字符串所有权交给属性槽，本函数返回后不再引用它；属性建成不可写、不可枚举、可配置，与 ES 对内建 `@@toStringTag` 的规定一致。error：预定义 symbol atom 缺失给 `error.TypeError`（内部不变量），其余是 `createStringValue`/`defineOwnProperty` 的 OOM。调用方：本文件 `:1264`/`:1273`（`iteratorPrototype` 的 base 与 specific）、`object_ops.zig:265`（"GeneratorFunction"）、`:1022`（"CallSite"）、`promise_ops.zig:147`（"AsyncFunction"）、`:216`（"AsyncGeneratorFunction"）；`collection_ops.zig:723` 是一份注明「要与本函数保持同步」的本地副本，不是调用方。

### `iteratorPrototype` (`src/exec/iterator_ops.zig:1255`)

- **签名**：`pub fn iteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object`。
- **作用**：建一个以 %IteratorPrototype% 为原型、带指定 `@@toStringTag` 的子原型对象。
- **实现**：`iteratorPrototypeFromGlobal` 为空时先临时造一个带 `"Iterator"` 标签的 base（`errdefer destroyFromHeader`），否则直接用 realm 的 %IteratorPrototype%；再以它为原型 `Object.create` 出 specific（同样挂 `errdefer`），装上 `tag_name` 的 toStringTag 后返回。
- **所有权 / 错误 / 调用**：返回 owned 的新对象，调用方随即写进 realm 缓存或 `class_prototypes` 槽。fallback base 只在它自己的构造块里有 `errdefer`：一旦 base 建成而后面 `Object.create(specific)` 失败，这个 base 不再被显式销毁——TGC 下它只是失去根、由 GC 回收（RC 时代这里会是泄漏）。specific 发布前失败由 `errdefer destroyFromHeader` 兜。error：`defineToStringTag` 的 `error.TypeError` 与各处 OOM。调用方：`iterator_ops.zig:1051`（Array Iterator 原型）、`:1382`（helper 原型），以及经 `object_ops.zig:2212` 转发壳 + `string_ops.zig:87` 别名的 `string_ops.zig:1006`（RegExp String Iterator）与 `:2184`（String Iterator）。

### `iteratorPrototypeAccessor` (`src/exec/iterator_ops.zig:1272`)

- **签名**：`pub fn iteratorPrototypeAccessor( ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, id: u32, ) !core.JSValue`。
- **作用**：%IteratorPrototype% 上 `constructor` 与 `@@toStringTag` 两对 getter/setter 的分发。
- **实现**：按 `AccessorMethod` id 分支：constructor getter 返回 `globalThis.Iterator`；constructor setter 无参时也返回 `globalThis.Iterator`，有参则转 `iteratorPrototypeAccessorSet(constructor, args[0])`；toStringTag getter 返回字符串 `"Iterator"`；toStringTag setter 转 `iteratorPrototypeAccessorSet(@@toStringTag, args[0] 或 undefined)`。未知 id → `error.TypeError`。
- **所有权 / 错误 / 调用**：返回 owned 值：constructor getter 交出 `globalThis.Iterator` 的属性值，toStringTag getter 现造一个字符串，两个 setter 恒返回 `undefined`。调用路径是 `iterator_ops.zig:3201` → `object_ops.zig:2133` 的同名包装 → 本函数：包装先做 receiver/值的类型检查并用 `throwTypeErrorMessage` 挂上「not an object」「Cannot assign to read only property」等消息，所以本函数自己返回的裸 `error.TypeError`（未知 id、预定义 atom 缺失）属于包装拦不住的内部分支，最终由 `createSentinelError` 造成一个空 message 的 TypeError。

### `iteratorPrototypeAccessorSet` (`src/exec/iterator_ops.zig:1303`)

- **签名**：`pub fn iteratorPrototypeAccessorSet( ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue, ) !core.JSValue`。
- **作用**：两个 accessor setter 的公共实现：按 ES 规定把值定义/设置到 receiver 上，并挡住对 %IteratorPrototype% 自身的改写。
- **实现**：receiver 必须是对象。`constructor` 分支：值必须是对象，直接 `defineOwnProperty(writable, 非枚举, 可配置)` 后返回 undefined。`@@toStringTag` 分支：receiver 恰是 realm 的 %IteratorPrototype%（home object）时 `error.TypeError`。随后通用路径：receiver 已有该 own 属性就 `setProperty`（`ReadOnly`/`AccessorWithoutSetter`/`NotExtensible`/`IncompatibleDescriptor` 统一翻成 `error.TypeError`），否则 `defineOwnProperty(writable/enumerable/configurable 全真)`。恒返回 undefined。
- **所有权 / 错误 / 调用**：写入的值由属性槽接管，函数恒返回 `undefined`（不交出新所有权）。error set 实际只有 `error.TypeError` 与分配失败：`setProperty` 的 `error.ReadOnly` / `error.AccessorWithoutSetter` / `error.NotExtensible` / `error.IncompatibleDescriptor` **都被就地翻成 `error.TypeError`**，不会漏给调用方；对 realm 的 %IteratorPrototype% 本体改写 `@@toStringTag` 同样是 TypeError。消息由 `object_ops.zig:2146` 的包装壳负责（本函数返回的是无消息的 sentinel）。调用方：`iterator_ops.zig:1294`/`:1297`（本文件 accessor 的两个 setter 分支）与该包装壳。

### `iteratorFromCall` (`src/exec/iterator_ops.zig:1333`)

- **签名**：`pub fn iteratorFromCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Iterator.from`：把 source 解析成迭代器，必要时包一层 iterator-wrap。
- **实现**：无参 → `error.TypeError`；source 是 null/undefined → `error.TypeError`；既不是字符串又不是对象 → `error.TypeError`。随后 `iteratorFromSourceForIteratorFrom` 做 GetIteratorFlattenable + %Iterator% 实例判定：`wrap == false` 直接返回解析出的迭代器，否则 `call_runtime.wrapIteratorFromIterator(iterator, next_method)` 建包装器。
- **所有权 / 错误 / 调用**：返回 owned 的迭代器或 wrap 对象：`wrap == false` 时直接交出 `iteratorFromSourceForIteratorFrom` 解析到的迭代器（它本身可能就是入参对象），否则交出 `call_runtime.wrapIteratorFromIterator` 新建的 %WrapForValidIterator%；`result.next_method` 随包装器一并交出。error set：无参、source 为 null/undefined、既非字符串又非对象都给 `error.TypeError`（裸 sentinel），其余是 `@@iterator` 调用与 Get `next` 的用户异常和 OOM。唯一调用方 `iterator_ops.zig:3218`（`iteratorStaticCall` 的 `.from` 臂）。

### `installIteratorHelperMethod` (`src/exec/iterator_ops.zig:1359`)

- **签名**：`pub inline fn installIteratorHelperMethod( rt: *core.JSRuntime, global: *core.Object, helper: *core.Object, key: core.Atom, method_id: i32, ) !void`。
- **作用**：在 helper 原型上安装 stamped native 方法。
- **实现**：关键调用：`builtin_glue.defineStampedNativeDataMethod`。
- **所有权 / 错误 / 调用**：装上的方法归目标对象的属性表，本函数不持有；无自有 error，全是 `builtin_glue.defineStampedNativeDataMethod` 的透传（OOM 等）。4 处调用值得注意分成两类：`iterator_ops.zig:1385`/`:1386` 把 `next`/`return` 装在**共享原型**上（`iteratorMethodsPrototype`），而 `:1932`/`:1933` 把同样两个方法直接装在**每个 zip helper 实例**上（`iteratorZipCreateHelper`）——zip helper 因此每个实例都自带 own `next`/`return`。

### `iteratorMethodsPrototype` (`src/exec/iterator_ops.zig:1369`)

- **签名**：`fn iteratorMethodsPrototype( rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, tag_name: []const u8, ) !*core.Object`。
- **作用**：惰性建出并缓存某个 helper 类原型（Iterator Helper / Iterator Concat），上面装 `next` 与 `return`。
- **实现**：先查 realm 缓存槽 `global.cachedRealmValue(slot)`，命中即 `expectObject` 返回。否则 `iteratorPrototype(tag_name)` 建原型（用 `proto_raw_owned` 标志控制 `errdefer destroyFromHeader`，写进 realm 缓存后不再销毁），`installIteratorHelperMethod` 装 `next`(method_id 1) 与 `return`(method_id 2)，再 `setCachedRealmValue` 写回缓存。
- **所有权 / 错误 / 调用**：返回借用指针：原型铸出后写进 `global` 的 realm 缓存槽（`setCachedRealmValue`），此后归 realm；`proto_raw_owned` 标志让 `errdefer destroyFromHeader` 只在「还没写进缓存」时生效，写进后不再销毁。命中缓存时直接返回槽里的对象，不分配。error：`expectObject` 的 `error.TypeError` 与建原型/装方法/写缓存的 OOM。调用方 `iterator_ops.zig:1397`（`iteratorHelperPrototype`）与 `:1433`（`iteratorConcatCall` 取 "Iterator Concat" 原型）。

### `iteratorHelperPrototype` (`src/exec/iterator_ops.zig:1388`)

- **签名**：`pub fn iteratorHelperPrototype( rt: *core.JSRuntime, global: *core.Object, ) !*core.Object`。
- **作用**：取/建 realm 的 %IteratorHelperPrototype%（toStringTag 为 `"Iterator Helper"`）。
- **实现**：转发 `iteratorMethodsPrototype(rt, global, .iterator_helper_prototype, "Iterator Helper")`。
- **所有权 / 错误 / 调用**：薄壳，返回的同样是 realm 缓存持有的借用指针（`.iterator_helper_prototype` 槽），error 全由 `iteratorMethodsPrototype` 透传。调用方 `iterator_ops.zig:1923`（`iteratorZipCreateHelper`）与 `:2549`（`iteratorCreateHelper`）——map/filter/take/drop/flatMap 与 zip 系 helper 共用这一个原型。

### `iteratorConcatCall` (`src/exec/iterator_ops.zig:1395`)

- **签名**：`pub fn iteratorConcatCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, comptime arrayPrototypeFromGlobal: anytype, comptime getIteratorMethod: anytype, comptime isCallableValue: anytype, ) !core.JSValue`。
- **作用**：`Iterator.concat`：把每个参数与它的 `@@iterator` 方法成对存进 records 数组，建一个 kind=6 的 concat helper。
- **实现**：先建 records 数组（原型由 comptime 传入的 `arrayPrototypeFromGlobal` 给，`errdefer destroyFromHeader`）并用 `rootValues` 钉住。逐个参数：局部 root frame 钉住 item 与其 iterator 方法；item 必须是对象，`getIteratorMethod` 取 `@@iterator`，undefined/null/不可调用都 `error.TypeError`；随后按 `index*2` / `index*2+1` 两个下标 `setProperty` 存 item 与方法（**此处不调用 @@iterator**，真正取迭代器推迟到 helper 的 next）。最后 `iteratorMethodsPrototype(.iterator_concat_prototype, "Iterator Concat")` 取原型，建 `iterator_helper` 对象，把 records 写进 `iteratorTargetSlot`，`kind = 6`、`index = 0`。三个 comptime 参数是给单测注入替身用的。
- **所有权 / 错误 / 调用**：返回 owned 的 concat helper。records 数组在整个收集循环里挂在 `ValueRootFrame` 上，写进 helper 的 `iteratorTargetSlot` 后局部置 `undefined` 解根；每轮循环另开一个局部 root frame 钉住 item 与它的 `@@iterator` 方法（`setProperty` 会分配）。records/helper 发布前失败各有 `errdefer destroyFromHeader`。注意**此处不调用 `@@iterator`**：方法只被存起来，真正取迭代器推迟到 helper 的 `next`，所以这里执行不到用户迭代代码。error set：参数不是对象、`@@iterator` 为 undefined/null 或不可调用给 `error.TypeError`，另有 Get `@@iterator` 的用户异常与 OOM。生产入口是 `string_ops.zig:3183` 的同名壳（喂真正的 `arrayPrototypeFromGlobal`/`getIteratorMethod`/`isCallableValue`），由 `iterator_ops.zig:3219`（`iteratorStaticCall` 的 `.concat` 臂）调用；`iterator_ops.zig:1497` 是本文件的 GC 单测。

### `testIteratorConcatArrayPrototypeFromGlobal` (`src/exec/iterator_ops.zig:1438`)

- **签名**：`fn testIteratorConcatArrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：单测替身：恒返回 `null`，让 records 数组用 null 原型建出来。
- **实现**：忽略 `rt` / `global`，直接 `return null`。
- **所有权 / 错误 / 调用**：无：函数体只有 `return null`，不分配、不建根、无 error（连参数都丢弃）。树内唯一使用点是同文件那条 GC 单测把它当依赖注入传给 `iteratorConcatCall`（`src/exec/iterator_ops.zig:1502`），生产路径传的是真正的 `arrayPrototypeFromGlobal`。

### `testIteratorConcatGetIteratorMethod` (`src/exec/iterator_ops.zig:1444`)

- **签名**：`fn testIteratorConcatGetIteratorMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：单测替身：顺带把 GC 阈值压到 0（逼出一次回收）后返回注入的 `@@iterator` 方法。
- **实现**：忽略 output/global/value，`ctx.runtime.setGCThreshold(0)` 后返回文件级变量 `test_iterator_concat_method`。
- **所有权 / 错误 / 调用**：无：测试替身，无生产调用方，只被 `iterator_ops.zig:1503` 那条 GC 单测（`iteratorConcatCall` 调用在 `:1497`）注入。副作用是把 `rt` 的 GC 阈值压到 0，逼 `iteratorConcatCall` 的下一次分配触发回收，用来验证 `@@iterator` 方法在存进 records 前确实被 root 住。

## 覆盖核对

- 清单函数数（本文件分到）: 55（`src/exec/iterator_ops.zig` 全文件 114）
- 本文标题覆盖: 55
- 未覆盖: 无
