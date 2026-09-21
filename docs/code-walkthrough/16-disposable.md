# 16 — using opcode 与 DisposableStack

本文件覆盖 `src/exec/vm_opcodes.zig` 与 `src/exec/disposable_ops.zig`。字节码面在前者，ECMA-262 Explicit Resource Management 算法在后者。`promise_ops.zig` 顶部把 async 一组名字 re-export 回来，实现不在 Promise 文件里。

## `using_ops.zig`：ext0 调度

`ext0` 载体的第二字节是 `bytecode.opcode.ext0_sub`。热路径 cold 平面 `tailcall_dispatch_colds.zig:526` 调 `execVm`。真正的 using 只有 `create` / `add*` / `dispose` / `dispose_throw`；其余 sub 是 opcode 空间回收后寄居在同一平面的冷指令。

### 类型

`Step`（`using_ops.zig:23`）：`done` 继续下一条；`continue_loop` 表示 catch 已改写 PC。

`DisposalDisposition`（`using_ops.zig:28`）：`normal` 弹 1 个操作数；`throw` 弹 2 个（栈 + pending 完成值）。

### `popOwnedOperands` (`src/exec/vm_opcodes.zig:33`)

- **签名**：`fn popOwnedOperands(_: *core.JSRuntime, stack: *stack_mod.Stack, count: usize) !void`。
- **作用**：从操作数栈弹出 `count` 个值并丢弃，给 add/dispose 失败或成功后清操作数。
- **实现**：循环 `stack.pop()`。tracing GC 下弹出即不再被栈窗口根住；runtime 参数忽略。
- **所有权 / 错误 / 调用**：`addResourceWithHint`、`disposeStackVm` 在把值交给 disposable_ops 之后调用。栈下溢由 `pop` 报 `StackUnderflow`。

### `routeRuntimeError` (`src/exec/vm_opcodes.zig:40`)

- **签名**：`fn routeRuntimeError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, err: anytype, ) !Step`。
- **作用**：把 disposable/using 算法的同步失败送进当前字节码 catch。
- **实现**：`call_runtime.handleCatchableRuntimeError` 成功则 `.continue_loop`，否则原样返回 `err`。
- **所有权 / 错误 / 调用**：create/add/dispose 的 `catch` 臂。不吞 `OutOfMemory` / `ProcessExit` 一类不可捕获错误。

### `createStackVm` (`src/exec/vm_opcodes.zig:55`)

- **签名**：`pub noinline fn createStackVm( ctx: *core.JSContext, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, ) !Step`。
- **作用**：`ext0_sub.create`：为 parser `using`/`await using` 造内部 disposable 栈并压到操作数栈。
- **实现**：`stack.reserveAdditional(1)`；`usingCreateAsyncDisposableStack`（内部 `async_disposable_stack`，不查用户构造器）。失败走 `routeRuntimeError`。
- **所有权 / 错误 / 调用**：返回值 `pushOwnedAssumeCapacity`。不是 `new AsyncDisposableStack()`，避免用户改 prototype 被观察到。该 pub noinline 函数已纳入清单。

### `execVm` (`src/exec/vm_opcodes.zig:71`)

- **签名**：`pub noinline fn execVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：ext0 第二级分发：using 与寄居冷 opcode。
- **实现**：读 `code[frame.pc]` 为 sub，PC+1。`isAdd(sub)` 则 `addResourceWithHint(..., addHint(sub))`。其余：`create`/`dispose`/`dispose_throw` 走 using；`put_super_value`/`to_object`/`to_propkey`/`set_name_computed`/`set_proto`/`check_ctor_return`、类型测试 `is_undefined`/`typeof_is_undefined`/`typeof_is_function`，以及一串 stack perm（`insert4`…`dup1`）转给 `object_ops` / `vm_value` / `vm_property_field` / `vm_call` / `vm_literal`。未知 sub → `error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：`tailcall_dispatch_colds` 唯一生产入口。hint 非法也是 `InvalidBytecode`。

### `addResourceWithHint` (`src/exec/vm_opcodes.zig:178`)

- **签名**：`fn addResourceWithHint( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, hint_byte: u8, ) !Step`。
- **作用**：`using` / `await using` 绑定：按 hint 把栈顶值登记到 disposable 栈。
- **实现**：hint `0` = `DisposalHint.sync`，`1` = `.async`，否则 `InvalidBytecode`。需要 ≥2 操作数：`[stack, value]`。sync → `disposable_ops.usingAddSyncResource`；async → `promise_ops.usingAddAsyncResource`（re-export）。无论成败都 `popOwnedOperands(..., 2)`。
- **所有权 / 错误 / 调用**：资源对象与 dispose 方法由 stack payload 持有。失败经 `routeRuntimeError`。

### `disposeStack` (`src/exec/vm_opcodes.zig:207`)

- **签名**：`fn disposeStack( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack_value: core.JSValue, completion: ?core.JSValue, ) !core.JSValue`。
- **作用**：按栈上对象是 sync 还是 async hint 选择同步或异步拆栈。
- **实现**：`parserDisposableStackReceiver` 接受 `disposable_stack` 与 `async_disposable_stack`。无 async hint：有 `completion` 走 `usingDisposeSyncStackForThrow`，否则 `usingDisposeSyncStack`。有 async hint：对应 `usingDisposeAsyncStack*`（返回 Promise）。
- **所有权 / 错误 / 调用**：只被 `disposeStackVm` 调用。sync 路径错误是抛出的 JS 异常；async 路径错误变成 rejected Promise。

### `disposeStackVm` (`src/exec/vm_opcodes.zig:232`)

- **签名**：`pub noinline fn disposeStackVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, disposition: DisposalDisposition, ) !Step`。
- **作用**：`ext0_sub.dispose` / `dispose_throw` 的栈约定。
- **实现**：`normal` 弹 1，`throw` 弹 2。调用 `disposeStack`，弹出操作数，把结果 `pushOwnedAssumeCapacity`。
- **所有权 / 错误 / 调用**：`execVm` 传入 `.normal` / `.throw`。失败先弹出再 `routeRuntimeError`。

## `disposable_ops.zig`：资源栈算法

payload 在对象 class `disposable_stack` / `async_disposable_stack` 上。每条 `DisposableResource` 记 `value`、`method`、`kind`（use/adopt/defer_）、`hint`（sync/async）、`method_kind`（direct / async_from_sync）。

### 类型

`DisposableStackMethod`（`:37`）：`use=1` `adopt=2` `defer_=3` `dispose=4` `move=5` `disposed_get=6`，与 native method marker 一致。

`AsyncDisposableStackMethod`（`:348`）：同样编号，`dispose` 换成 `dispose_async=4`。

### `disposableStackMethodFromMarker` (`src/exec/disposable_ops.zig:46`)

- **签名**：`pub fn disposableStackMethodFromMarker(marker: u8) ?DisposableStackMethod`。
- **作用**：把函数对象上的 u8 marker 译成枚举。
- **实现**：已知 1–6 各一臂，否则 `null`。
- **所有权 / 错误 / 调用**：`disposableStackMethodCall`。未知 marker 在调用处变 `TypeError`。

### `disposableStackReceiver` (`src/exec/disposable_ops.zig:58`)

- **签名**：`pub fn disposableStackReceiver(receiver: core.JSValue) !*core.Object`。
- **作用**：要求 `this` 是 `class_id == disposable_stack`。
- **实现**：非对象或 class 不对 → `TypeError`。
- **所有权 / 错误 / 调用**：原型方法入口。parser using 用更宽的 `parserDisposableStackReceiver`。

### `parserDisposableStackReceiver` (`src/exec/disposable_ops.zig:64`)

- **签名**：`pub fn parserDisposableStackReceiver(receiver: core.JSValue) !*core.Object`。
- **作用**：using opcode 的栈对象：sync 或 async class 都收。
- **实现**：两 class_id 之一，否则 `TypeError`。
- **所有权 / 错误 / 调用**：`usingAddSyncResource`、`usingDisposeSyncStack*`、`using_ops.disposeStack`。

### `disposableStackMethodCall` (`src/exec/disposable_ops.zig:71`)

- **签名**：`pub fn disposableStackMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`DisposableStack` 原型方法总入口。
- **实现**：marker 0 → `null`（不是本类方法）。译码后 `disposableStackReceiver`，再分发 use/adopt/defer_/dispose/move/`disposed` getter。
- **所有权 / 错误 / 调用**：builtin 分发。`null` 让调用方继续别的 tag。

### `disposableStackUse` (`src/exec/disposable_ops.zig:95`)

- **签名**：`pub fn disposableStackUse( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`DisposableStack.prototype.use(value)`：登记 `[Symbol.dispose]`。
- **实现**：已 disposed → `ReferenceError`。null/undefined 原样返回且不登记。非对象 → `TypeError`。取 `Symbol.dispose`，必须可调用，然后 `appendDisposableResource(..., .use, .sync, .direct)`。
- **所有权 / 错误 / 调用**：返回 `value`。方法与值活在 stack payload，有 generational barrier。

### `disposableStackAdopt` (`src/exec/disposable_ops.zig:115`)

- **签名**：`pub fn disposableStackAdopt( rt: *core.JSRuntime, stack: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`adopt(value, onDispose)`：用调用方提供的回调释放 value。
- **实现**：disposed → `ReferenceError`；`onDispose` 必须可调用。`appendDisposableResource(..., .adopt, .sync, .direct)`。
- **所有权 / 错误 / 调用**：dispose 时以 `undefined` this 调 `onDispose(value)`。

### `disposableStackDefer` (`src/exec/disposable_ops.zig:128`)

- **签名**：`pub fn disposableStackDefer( rt: *core.JSRuntime, stack: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`defer(onDispose)`：无资源值的回调。
- **实现**：已 disposed → `ReferenceError`；回调必须可调用。资源值存 `undefined`，kind `.defer_`。返回 `undefined`。
- **所有权 / 错误 / 调用**：dispose 时 `onDispose()` 无参。

### `disposableStackDispose` (`src/exec/disposable_ops.zig:140`)

- **签名**：`pub fn disposableStackDispose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`dispose()`：无初始错误地拆同步栈。
- **实现**：转 `disposeDisposableStackResources(..., null, ...)`。
- **所有权 / 错误 / 调用**：已 disposed 的幂等路径返回 `undefined`。

### `disposableStackRecordDisposeError` (`src/exec/disposable_ops.zig:151`)

- **签名**：`pub fn disposableStackRecordDisposeError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, pending_error: *?core.JSValue, thrown: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把一次 dispose 失败叠到 pending 错误上（后错误抑制先错误）。
- **实现**：已有 pending 则 `suppressedErrorForDispose(thrown, suppressed)`；否则记下 `thrown`。
- **所有权 / 错误 / 调用**：sync 与 async 记录错误都用同一 SuppressedError 构造。

### `disposeDisposableStackResources` (`src/exec/disposable_ops.zig:168`)

- **签名**：`pub fn disposeDisposableStackResources( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, initial_error: ?core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：同步 DisposeResources：标记 disposed，LIFO 调每个资源。
- **实现**：已 disposed：有 `initial_error` 则 `throwValue` → `JSException`，否则 `undefined`。否则 `disposed=true`，`popDisposableResource` 直到空，失败走 `runtimeErrorValueForDisposableDispose` + `disposableStackRecordDisposeError`。最后有 pending 则抛。
- **所有权 / 错误 / 调用**：`usingDisposeSyncStack*` 与 `disposableStackDispose`。继续 dispose 剩余资源，不在第一个失败处停。

### `usingAddSyncResource` (`src/exec/disposable_ops.zig:203`)

- **签名**：`pub fn usingAddSyncResource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：parser `using` 的 add：`args[0]` 栈，`args[1]` 值。
- **实现**：需要 ≥2 参。null/undefined 值跳过。非对象或缺少可调用 `Symbol.dispose` → `TypeError`。已 disposed → `ReferenceError`。返回 `undefined`（opcode 不把值留在栈上）。
- **所有权 / 错误 / 调用**：`using_ops.addResourceWithHint` sync 臂。caller_function/frame 传 null。

### `usingDisposeSyncStack` (`src/exec/disposable_ops.zig:222`)

- **签名**：`pub fn usingDisposeSyncStack( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：正常离开 using 块的同步拆栈。
- **实现**：`args[0]` 为栈，`initial_error=null`。
- **所有权 / 错误 / 调用**：`using_ops.disposeStack` 无 completion 时。

### `usingDisposeSyncStackForThrow` (`src/exec/disposable_ops.zig:233`)

- **签名**：`pub fn usingDisposeSyncStackForThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：using 块因 throw 离开：`args[1]` 是原异常。
- **实现**：`disposeDisposableStackResources(..., args[1], ...)`。资源错误变成对原异常的 suppressed。
- **所有权 / 错误 / 调用**：`ext0_sub.dispose_throw`。最终仍 `throwValue` 合成错误。

### `disposeResource` (`src/exec/disposable_ops.zig:244`)

- **签名**：`pub fn disposeResource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, resource: core.object.DisposableResource, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：同步处置单条资源。
- **实现**：`.use`：`method.call(value, [])`；`.adopt`：`method.call(undefined, [value])`；`.defer_`：`method.call(undefined, [])`。走 `callValueOrBytecodeSyncInternal`（同步，不排 job）。
- **所有权 / 错误 / 调用**：注释写明 async 栈不走这里。错误上抛给 `disposeDisposableStackResources`。

### `runtimeErrorValueForDisposableDispose` (`src/exec/disposable_ops.zig:261`)

- **签名**：`pub fn runtimeErrorValueForDisposableDispose( ctx: *core.JSContext, global: *core.Object, err: anytype, ) !core.JSValue`。
- **作用**：把 dispose 失败收成可抑制的 JS 值。
- **实现**：pending 异常匹配 `err` 则 `takeException`；否则清掉无关 pending，用 `runtimeErrorInfo` 造 sentinel；未知错误原样返回。
- **所有权 / 错误 / 调用**：sync/async 两条拆栈循环。

### `suppressedErrorForDispose` (`src/exec/disposable_ops.zig:272`)

- **签名**：`pub fn suppressedErrorForDispose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, suppressed_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new SuppressedError(error, suppressed)`。
- **实现**：realm 的 `suppressed_error` 原型；`suppressedErrorConstructWithPrototype`。
- **所有权 / 错误 / 调用**：缺原型 → `InvalidBuiltinRegistry`。

### `disposableStackMove` (`src/exec/disposable_ops.zig:286`)

- **签名**：`pub fn disposableStackMove( ctx: *core.JSContext, global: *core.Object, stack: *core.Object, ) !core.JSValue`。
- **作用**：`DisposableStack.prototype.move()`。
- **实现**：忽略 `global`，`disposableStackMoveWithClass(..., disposable_stack)`。
- **所有权 / 错误 / 调用**：原栈 disposed，资源搬到新栈。

### `usingCreateAsyncDisposableStack` (`src/exec/disposable_ops.zig:295`)

- **签名**：`pub fn usingCreateAsyncDisposableStack( ctx: *core.JSContext, global: *core.Object, ) !core.JSValue`。
- **作用**：parser 内部栈：async class payload，但不走用户构造器。
- **实现**：`asyncDisposableStackConstructWithPrototype(ctx, global, null)`。
- **所有权 / 错误 / 调用**：`using_ops.createStackVm`。sync using 也用这个 class，靠 `disposableStackHasAsyncHint()` 区分拆栈路径。

### `usingAddAsyncResource` (`src/exec/disposable_ops.zig:305`)

- **签名**：`pub fn usingAddAsyncResource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`await using` 登记。
- **实现**：`asyncDisposableStackReceiver(args[0])`，再 `asyncDisposableStackUse(..., args[1..2], null, null)`。
- **所有权 / 错误 / 调用**：`using_ops` async hint。会查 `Symbol.asyncDispose`，没有则 sync dispose + `async_from_sync`。

### `usingDisposeAsyncStack` (`src/exec/disposable_ops.zig:316`)

- **签名**：`pub fn usingDisposeAsyncStack( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：正常完成的 await using：返回拆栈 Promise。
- **实现**：校验 receiver 后 `asyncDisposableStackDisposeAsync`。
- **所有权 / 错误 / 调用**：opcode 把 Promise 压回操作数栈，随后 `OP_await`。

### `usingDisposeAsyncStackForThrow` (`src/exec/disposable_ops.zig:327`)

- **签名**：`pub fn usingDisposeAsyncStackForThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：await using 在 throw 路径上拆栈：先记下 `args[1]`，再异步 dispose。
- **实现**：先 `defaultPromiseCapability`。已 disposed 则直接 reject 该 capability。否则标记 disposed、`asyncDisposableStackStoreCapability`、`asyncDisposableStackContinueOrReject(..., args[1])`。
- **所有权 / 错误 / 调用**：返回 capability.promise。与 `disposeAsync` 不同：已 disposed 时 reject 原异常而不是 resolve。

### `asyncDisposableStackMethodFromMarker` (`src/exec/disposable_ops.zig:357`)

- **签名**：`pub fn asyncDisposableStackMethodFromMarker(marker: u8) ?AsyncDisposableStackMethod`。
- **作用**：async 原型方法 marker。
- **实现**：1–6 对应 use/adopt/defer_/dispose_async/move/disposed_get。
- **所有权 / 错误 / 调用**：`asyncDisposableStackMethodCall`。

### `asyncDisposableStackConstructWithPrototype` (`src/exec/disposable_ops.zig:369`)

- **签名**：`pub fn asyncDisposableStackConstructWithPrototype( ctx: *core.JSContext, _: *core.Object, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：分配 `async_disposable_stack` 对象。
- **实现**：`Object.create` + `errdefer destroyFromHeader`。global 未用。
- **所有权 / 错误 / 调用**：用户 `new AsyncDisposableStack` 与 parser `usingCreate*`。

### `asyncDisposableStackReceiver` (`src/exec/disposable_ops.zig:379`)

- **签名**：`pub fn asyncDisposableStackReceiver(receiver: core.JSValue) !*core.Object`。
- **作用**：要求 `async_disposable_stack` class。
- **实现**：否则 `TypeError`。
- **所有权 / 错误 / 调用**：async 方法与 using async 路径。

### `asyncDisposableStackMethodCall` (`src/exec/disposable_ops.zig:385`)

- **签名**：`pub fn asyncDisposableStackMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：async 原型方法总入口。
- **实现**：`dispose_async` 在 receiver 校验前调用（错误变成 rejected Promise）。其余方法先 `asyncDisposableStackReceiver`。
- **所有权 / 错误 / 调用**：marker 0 → `null`。

### `asyncDisposableStackUse` (`src/exec/disposable_ops.zig:410`)

- **签名**：`pub fn asyncDisposableStackUse( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`AsyncDisposableStack.prototype.use`：优先 `Symbol.asyncDispose`。
- **实现**：已 disposed → `ReferenceError`。null/undefined 仍 append 一条空 `.use`/`.async`（与 sync use 跳过不同）。非对象 → `TypeError`。有 asyncDispose 且可调用 → `.direct`；否则 `Symbol.dispose` 可调用 → `.async_from_sync`（dispose 返回值不当 Promise 等待）。
- **所有权 / 错误 / 调用**：两种 method 都记在 payload。

### `asyncDisposableStackAdopt` (`src/exec/disposable_ops.zig:440`)

- **签名**：`pub fn asyncDisposableStackAdopt( rt: *core.JSRuntime, stack: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：async `adopt`。
- **实现**：与 sync 相同，hint `.async`。
- **所有权 / 错误 / 调用**：回调返回值若 thenable，后续 `asyncDisposableStackAwaitValue` 会等。

### `asyncDisposableStackDefer` (`src/exec/disposable_ops.zig:453`)

- **签名**：`pub fn asyncDisposableStackDefer( rt: *core.JSRuntime, stack: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：async `defer`。
- **实现**：已 disposed → `ReferenceError`；回调必须可调用（否则 `TypeError`）。`appendDisposableResource(undefined, onDispose, .defer_, .async, .direct)`，返回 `undefined`。
- **所有权 / 错误 / 调用**：回调由 stack payload 持有（`appendDisposableResource` 自带 generational barrier），本函数不建串不建对象。错误都是裸的 `ReferenceError` / `TypeError`。唯一调用方 `asyncDisposableStackMethodCall:403`。

### `asyncDisposableStackMove` (`src/exec/disposable_ops.zig:465`)

- **签名**：`pub fn asyncDisposableStackMove( ctx: *core.JSContext, global: *core.Object, stack: *core.Object, ) !core.JSValue`。
- **作用**：async `move()`。
- **实现**：`disposableStackMoveWithClass(..., async_disposable_stack)`。
- **所有权 / 错误 / 调用**：忽略 global。

### `disposableStackMoveWithClass` (`src/exec/disposable_ops.zig:477`)

- **签名**：`noinline fn disposableStackMoveWithClass( ctx: *core.JSContext, stack: *core.Object, class_id: core.class.ClassId, ) !core.JSValue`。
- **作用**：sync/async `move` 的共用实现。
- **实现**：disposed → `ReferenceError`。用 class 原型造新对象，`moveDisposableResourcesTo`，源 `disposed=true`。
- **所有权 / 错误 / 调用**：noinline 函数已纳入清单。失败 `errdefer` 销毁新对象。

### `asyncDisposableStackStoreCapability` (`src/exec/disposable_ops.zig:491`)

- **签名**：`pub fn asyncDisposableStackStoreCapability(stack: *core.Object, rt: *core.JSRuntime, capability: PromiseCapabilityVm) !void`。
- **作用**：把拆栈用的 resolve/reject 存进 payload。
- **实现**：先 `clearDisposableStackAsyncCapability`，再写两槽，并对两函数做 generational barrier。
- **所有权 / 错误 / 调用**：`disposeAsync` 与 `usingDisposeAsyncStackForThrow`。槽与资源同对象，tracer 能看见。

### `asyncDisposableStackDisposeAsync` (`src/exec/disposable_ops.zig:507`)

- **签名**：`pub fn asyncDisposableStackDisposeAsync( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`[Symbol.asyncDispose]` / `disposeAsync()`。
- **实现**：先造 default capability。receiver 非法 → reject TypeError 并返回该 Promise（方法不抛）。已 disposed → resolve undefined。否则 disposed=true，存 capability，`ContinueOrReject(null)`。
- **所有权 / 错误 / 调用**：返回的 Promise 由 capability 持有，后续续体用存着的 resolve/reject。

### `asyncDisposableStackContinuation` (`src/exec/disposable_ops.zig:533`)

- **签名**：`pub fn asyncDisposableStackContinuation( rt: *core.JSRuntime, global: *core.Object, stack: *core.Object, rejected: bool, ) !core.JSValue`。
- **作用**：造内部 then 回调，resume 拆栈循环。
- **实现**：data function，tag `.async_disposable_stack_continuation`，槽里是 stack 与 rejected 标志。
- **所有权 / 错误 / 调用**：`asyncDisposableStackAwaitValue` 一对 fulfill/reject。

### `asyncDisposableStackContinuationCall` (`src/exec/disposable_ops.zig:547`)

- **签名**：`pub fn asyncDisposableStackContinuationCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：上述回调的 native 体。
- **实现**：取出 stack；reject 臂把 `args[0]` 当 awaited_rejection。`ContinueOrReject`。无槽 → `null`。
- **所有权 / 错误 / 调用**：builtin 分发。返回 `undefined`。

### `asyncDisposableStackContinueOrReject` (`src/exec/disposable_ops.zig:565`)

- **签名**：`pub fn asyncDisposableStackContinueOrReject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, awaited_rejection: ?core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：拆栈循环的故障屏障：算法失败则 reject 已存 capability。
- **实现**：`asyncDisposableStackContinue` catch → `promiseErrorValue` + `asyncDisposableStackRejectStored`。
- **所有权 / 错误 / 调用**：disposeAsync、throw 路径、continuation。

### `asyncDisposableStackContinue` (`src/exec/disposable_ops.zig:580`)

- **签名**：`pub fn asyncDisposableStackContinue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, awaited_rejection: ?core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：倒序弹出资源；遇到 async 结果就 await 并返回（一次只等一个）。
- **实现**：若有 `awaited_rejection` 先 `RecordError`。循环 `popDisposableResource`：`asyncDisposeResource` 失败记 error 继续；hint `.async` 则 `AwaitValue` 并 return。栈空：有 pending error 则 reject stored，否则 resolve undefined。
- **所有权 / 错误 / 调用**：对齐 spec DisposeResources 的异步一步。sync hint 的资源调用后不等待。

### `asyncDisposeResource` (`src/exec/disposable_ops.zig:613`)

- **签名**：`pub fn asyncDisposeResource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, resource: core.object.DisposableResource, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：调用一条资源的 dispose，返回要不要 await 的值。
- **实现**：method undefined → `undefined`。调用约定与 sync `disposeResource` 相同，但走 `callValueOrBytecodeRoot`（允许返回 Promise）。`async_from_sync` 丢弃返回值，改返回 `undefined`（不当 thenable）。
- **所有权 / 错误 / 调用**：`asyncDisposableStackContinue`。

### `asyncDisposableStackAwaitValue` (`src/exec/disposable_ops.zig:633`)

- **签名**：`pub fn asyncDisposableStackAwaitValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`PromiseResolve(value)` 然后内部 then 接到 continuation。
- **实现**：`promiseStaticCall(..., .resolve)` + 一对 continuation + `performPromiseThen`（undefined resolving funcs，与 async 函数 await 相同，不读 `.then`）。
- **所有权 / 错误 / 调用**：job 跑完回调会再进 `Continue`。

### `asyncDisposableStackRecordError` (`src/exec/disposable_ops.zig:653`)

- **签名**：`pub fn asyncDisposableStackRecordError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, error_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把错误写进 `disposableStackAsyncErrorSlot`，已有则合成 SuppressedError。
- **实现**：`setOptionalValueSlot`，走对象写屏障。
- **所有权 / 错误 / 调用**：await reject 与资源调用失败。

### `asyncDisposableStackResolveStored` (`src/exec/disposable_ops.zig:671`)

- **签名**：`pub fn asyncDisposableStackResolveStored( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：拆栈成功：调存着的 resolve，清 capability。
- **实现**：resolve 槽空则 return（幂等）。`promiseResolveCapability` 后 `clearDisposableStackAsyncCapability`。
- **所有权 / 错误 / 调用**：`Continue` 空栈无 pending error。

### `asyncDisposableStackRejectStored` (`src/exec/disposable_ops.zig:685`)

- **签名**：`pub fn asyncDisposableStackRejectStored( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *core.Object, reason: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：拆栈失败：调存着的 reject，清 capability。
- **实现**：对称于 resolve。
- **所有权 / 错误 / 调用**：`ContinueOrReject` 与空栈 pending error。

### `asyncIteratorAsyncDispose` (`src/exec/disposable_ops.zig:699`)

- **签名**：`pub fn asyncIteratorAsyncDispose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`%AsyncIteratorPrototype%[Symbol.asyncDispose]`：对 receiver 调 `return()`，结果包成 Promise。
- **实现**：函数必须 stamped `isAsyncIteratorAsyncDisposeFunction`，否则 `null`。取 `return`：缺/undefined → fulfilled undefined；不可调用 → rejected TypeError。调用失败 → rejected。返回值不是对象 → rejected TypeError；已是 Promise 则造新 Promise 并用 `performPromiseThen` 接到它的 resolving pair（等 inner settle，不在 VM 里 drain）；其它对象 → fulfilled undefined。
- **所有权 / 错误 / 调用**：`asyncIteratorPrototypeFromGlobal` 安装的方法。job 由宿主泵。

## 覆盖核对

- 清单函数数: 49（`src/exec/disposable_ops.zig` 42 + `src/exec/vm_opcodes.zig` 7）
- 本文标题覆盖: 49
- 未覆盖: 无
