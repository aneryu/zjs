# 13 — `call_runtime.zig`（一）：Call 分发与 inline

VM 调用路由。操作数窗口借用直到 `popOwnedStackRegion`；`pushOwned` 转移一个拥有引用。`global` 是 Realm 权威。对照 `JS_CallInternal`（quickjs.c:20817 一带）。

## 类型

- `InlineCallRequest`：`target` + `region_base` + `argc` + `RegionLayout`。88 字节经 `req_out` 写回，避免每站点 sret。
- `ExecCallResult`：`done` / `continue_loop` / `inline_call`。
- `OwnedArgList`：同步 native→bytecode 的事务性 argv；前两槽 `[receiver, callable]`。inline 容量 10。
- `SyncInlineRoute`：活动 invocation + 已解析 `InlineTarget`。
- `VmNativeCallableDispatch`：bound / resolved_record / native_ref / host_function / internal tag / name_dispatch。

---

### `execCall` (`src/exec/call_runtime.zig:78`)

- **签名**：`pub fn execCall( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, argc: u16, output: ?*std.Io.Writer, global: *core.Object, allow_inline: bool, req_out: *InlineCallRequest, ) align(32) !ExecCallResult`。
- **作用**：`OP_call`：零拷贝借 func+args，优先 inline。
- **实现**：`total=argc+1`，不足 `StackUnderflow`。`allow_inline` 且 `resolveInlineTarget(this=undefined)` 命中则写 `req_out` 返回 `.inline_call`（箭头在 resolve 里改词法 this）。否则 `callValueOrBytecodeRootPreRootedInternal`；失败先 pop 窗口、关 for-of 迭代器、`handleCatchableRuntimeError`。OP_call 绝不是构造；class 构造器直接调用由 `OP_check_ctor` 拒绝。
- **所有权 / 错误 / 调用**：`vm_call`（`allow_inline=true`）与 `tailcall_dispatch`（自己先试 inline，再以 `allow_inline=false` 落到这里）。结果 `pushOwnedAssumeCapacity`。

### `popOwnedStackRegion` (`src/exec/call_runtime.zig:131`)

- **签名**：`pub fn popOwnedStackRegion(stack: *stack_mod.Stack, region_base: usize) void`。
- **作用**：丢掉窗口；collector 只扫已发布长度。
- **实现**：`stack.setLen(region_base)`。
- **所有权 / 错误 / 调用**：调用完成后。值不逐个 free（tracing GC）。

### `handleCatchableRuntimeError` (`src/exec/call_runtime.zig:140`)

- **签名**：`pub noinline fn handleCatchableRuntimeError( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, err: anyerror, ) !bool`。
- **作用**：每个 `*Vm` opcode 包装共享的冷异常缝：把 `err` 交给本帧 catch，而不把整段 catch 机械内联进热 handler。
- **实现**：直接 `tryCatchInFrame`。注释钉死 noinline 原因：内联会把迭代器关闭、错误构造、栈裁剪拼进每个热包装的帧，膨胀每次调用都要建拆的 spill set；outline 后冷边只剩一条 `bl`。
- **所有权 / 错误 / 调用**：`execCall` 以及 `tailcall_dispatch`、`vm_call`、`vm_property_*`、`vm_arith`、`vm_value`、`vm_literal`、`vm_gen_async` 等全部 `*Vm` 包装，还有 `object_ops`（`getSuperValue`/`putSuperValue`/`checkBrandVm`/`addBrandVm`/`privateInVm`/`defineClass`/`defineMethod*`）、`iterator_ops`、`slot_ops`、`eval_ops`、`using_ops`，共 19 个文件近 160 处。返回 true 表示已转入本帧 handler（调用方变 `.continue_loop`）。

### `tryCatchInFrame` (`src/exec/call_runtime.zig:158`)

- **签名**：`pub fn tryCatchInFrame( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, err: anyerror, ) !bool`。
- **作用**：把 `err` 交给本帧 catch。有 handler 则裁栈、压异常、改 pc。
- **实现**：uncatchable 或非运行时错误 false。先关本帧 for-of 迭代器。无 catch_target false（外层 Machine 再拆挂起帧）。pending exception `takeException`；否则 `createSentinelError`，OOM 用预分配 oom error（无栈）。`popCatchMarker` 恢复外层 target。
- **所有权 / 错误 / 调用**：热包装经 `handleCatchableRuntimeError` 进来，避免内联本函数。无 handler 时错误继续往外传到 Machine。

### `callValueOrBytecodeRoot` (`src/exec/call_runtime.zig:207`)

- **签名**：`pub fn callValueOrBytecodeRoot( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：JS_Call 形：拷 argv 并 root 至返回。
- **实现**：≤8 栈拷；更多先 root 源再 `initCopy`。root this/func/args 后 `callValueOrBytecodeDispatch(..., copy_argv=true)`。
- **所有权 / 错误 / 调用**：测试证明 inline args 在 FB 帧分配前仍活。

### `coerceCallThis` (`src/exec/call_runtime.zig:264`)

- **签名**：`pub fn coerceCallThis( ctx: *core.JSContext, global: *core.Object, runtime_strict: bool, this_value: core.JSValue, boxed_out: *?core.JSValue, ) HostError!core.JSValue`。
- **作用**：给挂起的 async/generator 急切装箱 this。普通调用保留生 this，首次观察再物化。
- **实现**：strict 原样；nullish → global；非 object `primitiveObjectForAccess` 写入 `boxed_out`。
- **所有权 / 错误 / 调用**：`callFunctionBytecodeModeStateAfterInterruptPoll` 的 async 臂。

### `callNativeBuiltinRecordForVm` (`src/exec/call_runtime.zig:281`)

- **签名**：`pub fn callNativeBuiltinRecordForVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, this_value: core.JSValue, function_object: *core.Object, native_ref: core.function.NativeBuiltinRef, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：VM 热路径走与慢路同一张 internal record 表，本文件零域知识。
- **实现**：`internalBuiltinRecord` 命中后分两臂：`c_function` 走 preflight + `finalCallableRealmView` + `callInternalRecordDirectInRealm`；其它 class（如 `c_function_data`）走 `callInternalRecordDirect`（legacy 切片传空 `&.{}`，realm 权威用调用方 `global`）。未命中且 `.host` 域的不在 `internal_builtins`，走 `callHostGlobalNativeFunctionRecord`。其它返回 null，表示坏/陈旧的标准 native id。
- **所有权 / 错误 / 调用**：忽略 `func` 值，只要函数对象。

### `throwRuntimeErrorForGlobal` (`src/exec/call_runtime.zig:324`)

- **签名**：`pub fn throwRuntimeErrorForGlobal(ctx: *core.JSContext, global: *core.Object, err: anyerror) !void`。
- **作用**：把 Zig 运行时错误物化成挂起异常。
- **实现**：已匹配 pending 则返回。无 `runtimeErrorInfo` 忽略。`createSentinelError` + `throwValue`。
- **所有权 / 错误 / 调用**：native 记录失败、派生类 this TDZ。

### `callValueOrBytecodeRootPreRooted` (`src/exec/call_runtime.zig:336`)

- **签名**：`pub fn callValueOrBytecodeRootPreRooted( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：this/func/args 已根（C-API）；`copy_argv=true`。
- **实现**：转 dispatch。
- **所有权 / 错误 / 调用**：`functionCallCall`、`vm_call` 的 apply 臂（inline 未命中时）、`tailcall_dispatch` 的字节码 getter 调用。

### `callValueOrBytecodeRootPreRootedInternal` (`src/exec/call_runtime.zig:352`)

- **签名**：`pub fn callValueOrBytecodeRootPreRootedInternal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：opcode 窗口已根；`copy_argv=false`，arity 够时可借 argv。
- **实现**：dispatch false。
- **所有权 / 错误 / 调用**：`execCall`、`OP_eval` 非 intrinsic。

### `callValueOrBytecodeRootPreRootedAfterInterruptPoll` (`src/exec/call_runtime.zig:367`)

- **签名**：`pub fn callValueOrBytecodeRootPreRootedAfterInterruptPoll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：opcode 已付调用者 Realm poll。
- **实现**：`DispatchAfterInterruptPoll(..., false)`。
- **所有权 / 错误 / 调用**：VM 快失败回退。

### `OwnedArgList.init` (`src/exec/call_runtime.zig:395`)

- **签名**：`fn init( self: *OwnedArgList, rt: *core.JSRuntime, receiver: core.JSValue, callable: core.JSValue, args: []const core.JSValue, ) HostError!void`。
- **作用**：拷接收者+可调用+args，前缀逐步发布到 root 链。
- **实现**：total=args.len+2；≤10 用 inline；否则 heap。每写入一格扩大 `rooted_prefix`。
- **所有权 / 错误 / 调用**：失败 `deinit` 只释放已发布前缀。

### `OwnedArgList.initTakeArgs` (`src/exec/call_runtime.zig:425`)

- **签名**：`fn initTakeArgs( self: *OwnedArgList, rt: *core.JSRuntime, receiver: core.JSValue, callable: core.JSValue, args: []core.JSValue, ) HostError!void`。
- **作用**：移动调用方 owned args（`@memset` 源为 undefined）。
- **实现**：`@memcpy` 后清空源。
- **所有权 / 错误 / 调用**：`runSyncInlineRouteOwnedArgsGeneral`。

### `OwnedArgList.deinit` (`src/exec/call_runtime.zig:454`)

- **签名**：`fn deinit(self: *OwnedArgList) void`。
- **作用**：槽置 undefined，去 root，释放 heap。
- **实现**：从尾到头；`root.deinit`。
- **所有权 / 错误 / 调用**：成功帧建立后槽已被转移，前缀已空。

### `resolveSyncInlineRoute` (`src/exec/call_runtime.zig:475`)

- **签名**：`inline fn resolveSyncInlineRoute( route: *SyncInlineRoute, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, ) bool`。
- **作用**：同 Machine、同 Realm 才允许 native_boundary 同步回调。
- **实现**：无活动 invocation 或 ctx/global/output 不匹配 → false。`resolveInlineTargetInto`。
- **所有权 / 错误 / 调用**：`callValueOrBytecodeSyncInternal`。

### `runSyncInlineRouteMoved` (`src/exec/call_runtime.zig:505`)

- **签名**：`noinline fn runSyncInlineRouteMoved( comptime idle_machine: bool, invocation: *inline_calls.ActiveInvocation, target: *const inline_calls.InlineTarget, global: *core.Object, moved_values: []core.JSValue, out: *core.JSValue, ) HostError!void`。
- **作用**：把已拥有的 `[receiver, callable, ...args]` 槽移进同一 Machine 的 `.native_boundary` 帧并跑到返回。
- **实现**：`idle_machine` 用 `IdleBoundaryScope`（驻留宿主 invocation，跳过外层 dispatch 快照），否则 `NativeBoundaryScope`。`push` 后 `errdefer deinit`。`pushMovedCall(..., .method, .native_boundary, 0)`；`recordSameMachineSyncCall`；`runActiveInvocationUntilNativeBoundary`；`finish` 后 `takeNativeReturnInto(out)`。CallSite 按站点缓存不可变 target、按次选 Machine，所以本助手拿 invocation+target 而不是整条 `SyncInlineRoute`。
- **所有权 / 错误 / 调用**：`moved_values` 所有权交给新帧。`runSyncInlineRouteOwnedCopy` / `OwnedArgsGeneral` 的收口。失败走 boundary `deinit`。

### `runSyncInlineRouteCopiedArgs` (`src/exec/call_runtime.zig:536`)

- **签名**：`pub inline fn runSyncInlineRouteCopiedArgs( comptime fixed_argc: ?usize, comptime idle_machine: bool, invocation: *inline_calls.ActiveInvocation, target: *const inline_calls.InlineTarget, global: *core.Object, this_value: *const core.JSValue, args: []const core.JSValue, lean: ?*inline_calls.LeanFrame, out: *core.JSValue, ) HostError!void`。
- **作用**：CallSite 热臂：拷参压 Entry，跑到 `.native_boundary`。
- **实现**：断言 simple eligible。idle 用 `IdleBoundaryScope` 否则 `NativeBoundaryScope`。优先 `pushLeanEntry`；否则 `tryPushNativeBoundaryCopiedArgsFast` / `pushNativeBoundaryCopiedArgs`。`runPushedEntryUntilNativeBoundary`；`takeNativeReturnInto`。
- **所有权 / 错误 / 调用**：lean `in_use` defer 清。resident rt 从 `machine.vm.rt` 一载。

### `runSyncInlineRouteMovedArgs` (`src/exec/call_runtime.zig:579`)

- **签名**：`noinline fn runSyncInlineRouteMovedArgs( invocation: *inline_calls.ActiveInvocation, target: *const inline_calls.InlineTarget, global: *core.Object, args: []core.JSValue, out: *core.JSValue, ) HostError!void`。
- **作用**：simple 目标：把调用方已拥有的 argv **搬进** 可写帧（receiver/callable 仍借自还活着的原生算法）。
- **实现**：断言 `nativeBoundarySimpleEligible`。只用 `NativeBoundaryScope`（无 idle 特化）。`tryPushNativeBoundaryMovedArgsFast` 命中即用，否则 `pushNativeBoundaryMovedArgs`。随后 `runPushedEntryUntilNativeBoundary` + `takeNativeReturnInto`。
- **所有权 / 错误 / 调用**：`callOwnedArgsValueOrBytecodeSyncInternal` 的 simple 臂。失败不把 args 所有权交回（已尝试 push）。

### `runSyncInlineRouteOwnedCopy` (`src/exec/call_runtime.zig:607`)

- **签名**：`pub noinline fn runSyncInlineRouteOwnedCopy( idle_machine: bool, invocation: *inline_calls.ActiveInvocation, target: *const inline_calls.InlineTarget, ctx: *core.JSContext, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, out: *core.JSValue, ) HostError!void`。
- **作用**：拷一份 argv 再走 Moved：调用方仍拥有原切片。
- **实现**：`OwnedArgList.init` 拷 receiver+callable+args；`defer deinit`。`idle_machine` 是运行时 bool，避免为 comptime 特化把本助手实例化两份；idle/active 篱笆仍特化在 `runSyncInlineRouteMoved`。
- **所有权 / 错误 / 调用**：CallSite 非 simple 臂、`callValueOrBytecodeSyncInternal` 非 simple 臂。init 失败只释放已发布前缀。

### `runSyncInlineRouteOwnedArgsGeneral` (`src/exec/call_runtime.zig:630`)

- **签名**：`noinline fn runSyncInlineRouteOwnedArgsGeneral( invocation: *inline_calls.ActiveInvocation, target: *const inline_calls.InlineTarget, ctx: *core.JSContext, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []core.JSValue, out: *core.JSValue, ) HostError!void`。
- **作用**：非 simple 布局的 take-args 冷路径：剥夺调用方 argv，组装完整 owned 事务再 Moved。
- **实现**：断言 **非** `nativeBoundarySimpleEligible`。`OwnedArgList.initTakeArgs` 后 `runSyncInlineRouteMoved(false, ...)`（总是活动篱笆）。
- **所有权 / 错误 / 调用**：`callOwnedArgsValueOrBytecodeSyncInternal`。`initTakeArgs` 把源槽 `@memset` 成 undefined；回退路径不会走到这里（resolve 失败时调用方仍拥有 args）。

### `callValueOrBytecodeSyncInternal` (`src/exec/call_runtime.zig:655`)

- **签名**：`pub inline fn callValueOrBytecodeSyncInternal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：原生算法必须同步拿到字节码回调结果时的显式边界。
- **实现**：无论哪条路都 `pollInterrupt`。resolve 失败 → 根路径 `copy_argv=true`。simple → copied args；否则 owned copy。
- **所有权 / 错误 / 调用**：输入须已根。Apply 终端用 inline 适配器；回调队列用 outlined 缝。

### `callValueOrBytecodeSyncInternalOutlined` (`src/exec/call_runtime.zig:708`)

- **签名**：`pub noinline fn callValueOrBytecodeSyncInternalOutlined( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：与上面同一条同步契约的循环回调适配器：把目标解析和回退 union 赶出周围原生算法的迭代体。
- **实现**：一层转调 `callValueOrBytecodeSyncInternal`。注释区分：Apply 的单次终端调用留 inline 适配器；`forEach`/`map`/`JSON`/`iterator` 这类回调队列必须走这条 outlined 缝，否则一次 callback 站点会把 spill set 铺到整个循环。
- **所有权 / 错误 / 调用**：`array_ops`/`object_ops`/`disposable_ops`/`coercion_ops` 把本符号别名为 `callValueOrBytecodeSyncInternal`。`iterator_ops`、`json_ops`、`collection_ops`、`promise_ops`、`string_ops`、`regexp_fastpath`、`error_stack_ops`、`object_builtin_ops`、`call.zig` 直接调用。输入须已根。

### `callOwnedArgsValueOrBytecodeSyncInternal` (`src/exec/call_runtime.zig:736`)

- **签名**：`pub inline fn callOwnedArgsValueOrBytecodeSyncInternal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：调用方提供已根 owned argv；simple 目标直接 move 进可写帧。
- **实现**：先 `pollInterrupt`；resolve 失败 → 根路径 `copy_argv=true`。simple → `runSyncInlineRouteMovedArgs`；否则 `runSyncInlineRouteOwnedArgsGeneral`（`initTakeArgs`）。回退不剥夺调用方所有权。
- **所有权 / 错误 / 调用**：`functionApplyArrayLike`、`reflect_ops` 的 `Reflect.apply`。

### `collectionPrototypeMethodByName` (`src/exec/call_runtime.zig:788`)

- **签名**：`fn collectionPrototypeMethodByName( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, name: []const u8, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：无烘焙 id 的 Map/Set 原型方法慢路。
- **实现**：`collectionMethodOwnerClass` 无效 → null。keys/values/entries/forEach 限 Map|Set；差集等限 Set。set/get/has 有 id，不在此。
- **所有权 / 错误 / 调用**：不匹配继续名字链。接收者合法性由记录 handler 抛。

### `vmNativeCallableDispatch` (`src/exec/call_runtime.zig:836`)

- **签名**：`fn vmNativeCallableDispatch(function_object: *core.Object) VmNativeCallableDispatch`。
- **作用**：按 class 选 native 臂，避免热路径名字比较。
- **实现**：bound；async resolve/reject → async_function_resume；c_function：nativeCallTarget / decode id / host kind / internal tag / name；c_function_data 类似无 resolved_record。
- **所有权 / 错误 / 调用**：`callNativeCallableObject`。

### `callInternalCallableByTag` (`src/exec/call_runtime.zig:867`)

- **签名**：`pub fn callInternalCallableByTag( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, tag: core.host_function.InternalCallableTag, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：Promise/async 合成函数。
- **实现**：`.none` null。resolving / capability executor / combinator / finally / async resume / async generator resolve / from-sync wrap / unwrap / async disposable / arrayFromAsync / `%ThrowTypeError%`。
- **所有权 / 错误 / 调用**：`call.zig` 的无 Realm 回退路径（`c_function_data` / async resume 臂）也调用本函数；promise resolving 与 capability executor 在那条路上另有本地前置分支。

### `callRawFunctionBytecode` (`src/exec/call_runtime.zig:893`)

- **签名**：`noinline fn callRawFunctionBytecode( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：可调用值本身就是裸 `FunctionBytecode` 时的 Call 臂（无函数对象、无捕获）。
- **实现**：`functionBytecodeFromValue(func)` 失败 `TypeError`。`new.target=undefined`，captures 空切片。class 直调拒绝是字节码入口的 `OP_check_ctor`，对齐 qjs `JS_CallInternal`；普通函数走同一条 undefined-new.target 路，FB 上不携带 class-syntax 事实。转 `callFunctionBytecodeModeStateAfterInterruptPoll`。
- **所有权 / 错误 / 调用**：`callValueOrBytecodeDispatchAfterInterruptPoll` 在 `func.is(.function_bytecode)` 时。`copy_argv` 原样下传。

### `callFunctionObjectBytecode` (`src/exec/call_runtime.zig:925`)

- **签名**：`noinline fn callFunctionObjectBytecode( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, function_object: *core.Object, args: []const core.JSValue, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：四类 bytecode 函数对象的最终 Call 臂：从对象取 FB 与捕获。
- **实现**：`functionBytecode()` 或再 `functionBytecodeFromValue` 失败 `TypeError`。Bound/Proxy 已在外层拆到这一臂。助手在 interrupt/stack preflight 期间保持本调用者视图；`zjs_vm` 只在那些检查之后才选 FB Realm。`OP_check_ctor` 仍在函数 Realm 拒绝 class 直调。`new.target=undefined`。
- **所有权 / 错误 / 调用**：dispatch 对 `bytecode_function` / `generator_function` / `async_function` / `async_generator_function`。捕获切片借自对象。

### `callNativeCallableObject` (`src/exec/call_runtime.zig:944`)

- **签名**：`noinline fn callNativeCallableObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：c_function / data / bound / async resume / c_closure 的 class 分发：先记录/host/tag，名字链只做最后兼容。
- **实现**：`vmNativeCallableDispatch`：
  - `.bound_function` → `callBoundFunction`。
  - `.resolved_record`：`preflightCFunctionCall` + `CallRealmView.caller` + `callInternalRecordDirectInRealm`；失败 `throwRuntimeErrorForGlobal` 后原样返回 err。
  - `.native_ref`：`callNativeBuiltinRecordForVm`；有值则返回，null 掉进名字链。失败用 **函数对象 Realm** 物化。
  - `.host_function`：`callHostFunctionObjectForVm`，有值返回。
  - `.internal`：函数 Realm 上 `callInternalCallableByTag`。
  - `.name_dispatch` 以及上面未命中：`finalCallableRealmView` 后 `callNativeCallableByName`。
- **所有权 / 错误 / 调用**：dispatch 对 c_function/data/async_function_resolve/reject/c_closure/bound。记录失败必须先挂起 JS 异常再返回 Zig err。

### `callValueOrBytecodeDispatch` (`src/exec/call_runtime.zig:1006`)

- **签名**：`fn callValueOrBytecodeDispatch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：poll 后进分类。
- **实现**：`pollInterrupt` + After。
- **所有权 / 错误 / 调用**：Root 包装。

### `callValueOrBytecodeDispatchAfterInterruptPoll` (`src/exec/call_runtime.zig:1021`)

- **签名**：`pub fn callValueOrBytecodeDispatchAfterInterruptPoll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：权威 Call 分类（JS_CallInternal 形状）。
- **实现**：裸 FB → `callRawFunctionBytecode`。对象：四类 bytecode → `callFunctionObjectBytecode`；callable proxy → `callProxyApply`；c_function/data/async resume/c_closure/bound → `callNativeCallableObject`。不可调用 `throwTypeErrorMessage("not a function")`。其余 `callValueWithThisGlobalsAndGlobal`。
- **所有权 / 错误 / 调用**：CallSite generic、sync 回退。

### `callNativeCallableByName` (`src/exec/call_runtime.zig:1068`)

- **签名**：`noinline fn callNativeCallableByName( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：没有稳定 native record / internal tag 的可调用对象的兼容名字分发；故意不与字节码共享调用帧。
- **实现**：`nativeFunctionDispatchNameRef` 借 atom 支持的 ASCII 名（不每调用 `[]u8` 分配；URI 热路径会来数百万次）。空名 / 无可用名 → undefined。先精确 `eql`：`raw`、`sumPrecise`、DisposableStack / AsyncDisposableStack 方法、`callNativeFunctionRecord`、`collectionPrototypeMethodByName`。然后首字节 switch 走常见全局：`Array` 构造（须 `arrayBuiltinMarker()==.constructor`）、`BigInt`/`Number`/`Object`/`String`、`d`/`e` 的 URI id、`fromCharCode`。其余是约 48 条 `eql` 加若干探针的冷链（源码注释记的 ~95 是加首字节 switch 之前走到 URI 要过的检查数）：`get [Symbol.species]`、动态 Function 族、`parseInt`/`parseFloat`/`isNaN`/`isFinite`、`RegExp`（`NativeBacktraceScope` + `regExpFunctionCall`）、Error 构造、iterator `next`/`throw`/`return` 与 `@@iterator`/`@@asyncIterator`/`@@asyncDispose`、`apply`/`call`、`__proto__` 访问器、Array/TypedArray 方法族、`eval`（间接，Realm 取函数对象 `functionRealmGlobal`）、regexp 符号、DataView get/set、String 原型。链尽 `callValueWithThisGlobalsAndGlobal`。对齐 qjs：`JS_CallInternal` 按 class 进专用调用函数，C/native 不与字节码共帧。
- **所有权 / 错误 / 调用**：`callNativeCallableObject` 的最后一臂。RegExp/Array Iterator 等仍要 `materializeRuntimeError`。`DisposableStack`/`AsyncDisposableStack` 当构造名直接 `TypeError`。

### `Trigger.trigger` (`src/exec/call_runtime.zig:1454`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：`callValueOrBytecodeRoot` 根测试的 GC 探针。
- **实现**：与 call.zig 测试 Trigger 相同：摘 hook、engine_active 收集、看 atom。
- **所有权 / 错误 / 调用**：测试局部 struct 的方法，不分配；被安装成 `rt.memory.trigger_gc_fn` 后由分配路径经函数指针回调，不是直接调用方。进入后先把 hook 摘掉并 `defer` 还原以防重入，`tryRunObjectCycleRemovalWithValueRoots` 的错误被 `catch {}` 吞掉（探针只关心 atom 是否存活，不关心回收是否成功）。

### `functionHasInstanceCall` (`src/exec/call_runtime.zig:1521`)

- **签名**：`pub fn functionHasInstanceCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Function.prototype[Symbol.hasInstance]`。
- **实现**：`ordinaryHasInstance` → boolean。
- **所有权 / 错误 / 调用**：不分配、不建根：`args` 借用调用方窗口，返回的是立即 boolean。error set 是推断的（`ordinaryHasInstance` 的传播，含 `HostError` 与 OOM），由两个 native 包装层落成 JS 异常——`function_ops.zig:111` 的 exec-direct thunk 经 `hostResultToValue`，`function_ops.zig:166` 的 generic 体经调用它的 builtin dispatch。

### `ordinaryHasInstance` (`src/exec/call_runtime.zig:1534`)

- **签名**：`pub fn ordinaryHasInstance( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：OrdinaryHasInstance。
- **实现**：不可调用 false。bound 递归 target。`.prototype` 优先自有 data（避免 Descriptor）；否则 `getValueProperty`。原型链：非 proxy 直接 `getPrototype`（qjs `p->shape->proto` quickjs.c:8087），proxy / `%ThrowTypeError%` 走 trap。
- **所有权 / 错误 / 调用**：prototype 非 object TypeError。

### `functionCallCall` (`src/exec/call_runtime.zig:1588`)

- **签名**：`pub fn functionCallCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：`Function.prototype.call`。
- **实现**：thisArg 默认 undefined；`argv[1..]` 已由外层 native 调用根住，不再拷 8 槽（对齐 `js_function_call` 直转 `JS_Call`）。
- **所有权 / 错误 / 调用**：记录与名字慢路共享。

### `functionApplyCall` (`src/exec/call_runtime.zig:1613`)

- **签名**：`pub fn functionApplyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：`Function.prototype.apply`（`js_function_apply` qjs:41213）。
- **实现**：先 `isCallableValue`（check_function 在读 argv 前）。nullish 列表 → 空参 sync call。否则 `functionApplyArrayLike`。
- **所有权 / 错误 / 调用**：bound/Proxy 与普通函数同一 call 腿。

### `throwApplyTypeError` (`src/exec/call_runtime.zig:1645`)

- **签名**：`noinline fn throwApplyTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) HostError!core.JSValue`。
- **作用**：apply 两条 TypeError 臂的 outlined 抛出：接收者不可调用、参数列表非对象。
- **实现**：`createNamedError(..., "TypeError", message)` + `throwValue`，返回 `error.JSException`。两条文案对齐 qjs：`check_function` 的 `"not a function"`（qjs:41221 前），`build_arg_list` 的 `"not a object"`（qjs:41167，注意英文是 `a object`）。
- **所有权 / 错误 / 调用**：`functionApplyCall`（非函数 this）、`functionApplyArrayLike`（非对象 list）。noinline 避免把错误构造拼进扁平 record 体。

### `functionApplyArrayLike` (`src/exec/call_runtime.zig:1655`)

- **签名**：`noinline fn functionApplyArrayLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_arg: core.JSValue, this_value: core.JSValue, arg_array: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：apply 收到非 nullish 列表时才需要的 CreateListFromArrayLike 物化与 owned argv 事务（qjs `build_arg_list`，qjs:41159）。
- **实现**：`arg_array` 非对象 → `throwApplyTypeError("not a object")`。`ownedArgsFromArrayLike` 建列表，`defer deinit`。空列表走 `callValueOrBytecodeSyncInternal`（拷贝契约、无参）。非空则 `ValueSliceRoot` 根住切片，再 `callOwnedArgsValueOrBytecodeSyncInternal`（simple 目标 move 进帧）。
- **所有权 / 错误 / 调用**：`functionApplyCall` 的冷腿。outlined 是为了不把这段大状态留在扁平 `functionApplyCall` 热体里。根在 sync call 期间覆盖 argv。

### `callBoundFunction` (`src/exec/call_runtime.zig:4536`)

- **签名**：`pub fn callBoundFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：VM 路径 bound：合并 args，this=boundThis，再 `callValueOrBytecodeRoot`。
- **实现**：缺 target/this TypeError。
- **所有权 / 错误 / 调用**：`callNativeCallableObject`。与 call.zig 版本不同：这里有 caller_function/frame 且走 Root。

### `boundFunctionArgs` (`src/exec/call_runtime.zig:4552`)

- **签名**：`pub fn boundFunctionArgs(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) ![]core.JSValue`。
- **作用**：`bound ++ extra` 新切片。
- **实现**：两边空返回 `& .{}`。alloc + 两段拷贝。
- **所有权 / 错误 / 调用**：调用方 `freeArgs`。构造路径同样用。

## 覆盖核对

- 清单函数数（本文件分到）: 41（`src/exec/call_runtime.zig` 全文件 162）
- 本文标题覆盖: 41
- 未覆盖: 无（`call_runtime.zig` 其余在 [13-calls-runtime-construct.md](13-calls-runtime-construct.md)、[13-calls-runtime-env.md](13-calls-runtime-env.md)）
