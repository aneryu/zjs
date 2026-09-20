# 12 — 调用 / 构造 / 深度预算（`vm_call.zig`）

文件职责：`op.call*` / `call_method` / `apply` / `call_constructor` / `fclosure*` / `check_ctor` / `check_ctor_return` / `init_ctor`，以及逻辑/native/字节预算。操作数进入时 owned；帧按 `Frame` 的 disposition borrow/dup/转移。`CallDepthGuard` 平衡三套预算。inline 请求写调用方 `InlineCallRequest` 槽，避免 sret。对应 `JS_CallInternal` 17828–17866 与 class-call 17746–17791。

热 native 分发已迁到 `vm_native.dispatch`；本文件仍提供方法冷路径、记录解析、构造与帧初始化。

## 类型

`Step`：`done` / `continue_loop`。

`CallStep`：另加 `inline_call`（请求写在 `req_out`）与 `inline_constructor`（`OP_apply(1)` 展开成构造续体）。

`CallDepthGuard`：`ctx` + `planned_stack_bytes`。`deinit` 退还字节预算并 `call_depth--`、`native_call_depth--`。

### `CallDepthGuard.deinit` (`src/exec/vm_call.zig:46`)

- **签名**：`pub fn deinit(self: CallDepthGuard) void`。
- **作用**：非 inline 的 `enterCallDepth` 配对释放。
- **实现**：assert 字节预算足够，减去 planned，两个 depth -1。
- **所有权 / 错误 / 调用**：`zjs_vm` 根调用。无错误。

### `enterCallDepth` (`src/exec/vm_call.zig:55`)

- **签名**：`pub fn enterCallDepth( ctx: *core.JSContext, global: *core.Object, planned_stack_bytes: usize, ) !CallDepthGuard`。
- **作用**：根/慢调用的三预算准入（native depth、逻辑 depth、字节）。
- **实现**：超限 → InternalError `"stack overflow"` + `error.StackOverflow`（qjs 17837）。否则累加三计数，返回 guard。
- **所有权 / 错误 / 调用**：`zjs_vm`。inline 路径用 `*InlineCallDepthBytes*`。

### `bytecodeFrameAllocaSize` (`src/exec/vm_call.zig:79`)

- **签名**：`pub fn bytecodeFrameAllocaSize( function: *const bytecode.FunctionBytecode, argc: usize, copy_argv: bool, ) usize`。
- **作用**：qjs `JS_CallInternal` 的 planned `alloca_size`（无 COPY_ARGV 时）。尾调用 flags=0，只在缺参时为 argv 前缀计价。
- **实现**：`copy_argv or argc < arg_count` 则分配 `arg_count` 个槽，否则 0。加上 var_count + stack_size 个 JSValue，加上 var_ref_count 个指针。
- **所有权 / 错误 / 调用**：`inline_calls` 几乎每个 push。

### `bytecodeLeafFrameAllocaSize` (`src/exec/vm_call.zig:101`)

- **签名**：`pub inline fn bytecodeLeafFrameAllocaSize( function: *const bytecode.FunctionBytecode, ) usize`。
- **作用**：叶函数计价：已发布叶都是 copy_argv=false 且 argc≥arg_count，argv 前缀为空，塌成函数头标量。
- **实现**：`(var_count+stack_size)*sizeof(JSValue) + var_ref_count*sizeof(*VarRef)`。无 argc load。
- **所有权 / 错误 / 调用**：叶构造/释放路径。

### `bytecodeStackBudgetWouldOverflow` (`src/exec/vm_call.zig:109`)

- **签名**：`inline fn bytecodeStackBudgetWouldOverflow( rt: *const core.JSRuntime, planned_stack_bytes: usize, ) bool`。
- **作用**：字节预算是否会越过 native 栈护栏。
- **实现**：`admissionCeilingsReject(&rt.hot, active +% planned, planned)`。
- **所有权 / 错误 / 调用**：所有准入。

### `admissionCeilingsReject` (`src/exec/vm_call.zig:122`)

- **签名**：`inline fn admissionCeilingsReject( hot: *const core.JSRuntime.HotExecState, accumulated: usize, planned_stack_bytes: usize, ) bool`。
- **作用**：一条谓词：wrap 不用测（planned 受 u16 槽限制）；`frameAddress -| accumulated < native_stack_limit`。
- **实现**：debug assert accumulated≥planned。用 `+%` 代替 `std.math.add` 以免 cset spill。
- **所有权 / 错误 / 调用**：预算核心。

### `canEnterInlineCallDepthBytes` (`src/exec/vm_call.zig:140`)

- **签名**：`pub inline fn canEnterInlineCallDepthBytes( ctx: *const core.JSContext, planned_stack_bytes: usize, ) bool`。
- **作用**：inline 调用的只读准入（逻辑 depth + 字节）。
- **实现**：`call_depth < maxLogical` 且不会 overflow。
- **所有权 / 错误 / 调用**：`enterInlineCallDepthBytes`。

### `commitInlineCallDepthBytes` (`src/exec/vm_call.zig:149`)

- **签名**：`pub inline fn commitInlineCallDepthBytes( ctx: *core.JSContext, planned_stack_bytes: usize, ) void`。
- **作用**：准入已过之后记账。
- **实现**：assert 不 wrap，bytes+=，call_depth+=1。不碰 native_call_depth（inline 不占 native 递归）。
- **所有权 / 错误 / 调用**：`enterInlineCallDepthBytes` / 部分 inline_calls。

### `tryCommitInlineCallDepthBytesRt` (`src/exec/vm_call.zig:169`)

- **签名**：`pub inline fn tryCommitInlineCallDepthBytesRt( rt: *core.JSRuntime, planned_stack_bytes: usize, ) bool`。
- **作用**：K2 融合准入+提交：调用方已有 `rt`，检查与 RMW 连在一起，避免 arena carve 后的 ctx→runtime 重载。
- **实现**：一次 load depth/bytes，sum，ceilings 或 `depth >= stack_size` → false；否则写回。qjs 检查即承诺（17837/17845）；carve miss 必须 `retreatInlineCallDepthBytesMiss`。
- **所有权 / 错误 / 调用**：叶/暖构造。false 不抛。

### `retreatInlineCallDepthBytesMiss` (`src/exec/vm_call.zig:191`)

- **签名**：`pub noinline fn retreatInlineCallDepthBytesMiss( rt: *core.JSRuntime, planned_stack_bytes: usize, ) void`。
- **作用**：commit-before-carve 后 carve miss 的退账。
- **实现**：`leaveInlineCallDepthBytesRt`。noinline 让暖体 miss 只 bl。
- **所有权 / 错误 / 调用**：`inline_calls` 各 miss 出口。

### `enterInlineCallDepthBytes` (`src/exec/vm_call.zig:200`)

- **签名**：`pub inline fn enterInlineCallDepthBytes( ctx: *core.JSContext, global: *core.Object, planned_stack_bytes: usize, ) !void`。
- **作用**：带抛错的 inline 准入+提交。
- **实现**：不能进 → `inlineCallDepthOverflow`；否则 commit。
- **所有权 / 错误 / 调用**：errdefer leave。

### `leaveInlineCallDepthBytes` (`src/exec/vm_call.zig:211`)

- **签名**：`pub inline fn leaveInlineCallDepthBytes( ctx: *core.JSContext, planned_stack_bytes: usize, ) void`。
- **作用**：ctx 形态的释放。
- **实现**：转 `leaveInlineCallDepthBytesRt`。
- **所有权 / 错误 / 调用**：inline 弹出。

### `leaveInlineCallDepthBytesRt` (`src/exec/vm_call.zig:221`)

- **签名**：`pub inline fn leaveInlineCallDepthBytesRt( rt: *core.JSRuntime, planned_stack_bytes: usize, ) void`。
- **作用**：rt 形态释放：叶弹出在 arena store **之前**加载 rt，避免 alias 挡住 CSE。
- **实现**：assert，bytes-=，call_depth-=1。
- **所有权 / 错误 / 调用**：热释放。

### `checkTailCallChainStackBudget` (`src/exec/vm_call.zig:236`)

- **签名**：`pub fn checkTailCallChainStackBudget( ctx: *core.JSContext, global: *core.Object, planned_stack_bytes: usize, ) !void`。
- **作用**：`op.tail_call` 帧替换预检。qjs 嵌套 `JS_CallInternal` 查 native SP；zjs 复用物理 Entry，把 planned 字节放进独立 Runtime 预算，并保持逻辑 depth。两者都不 alias 每 Realm 的 interrupt 计数。
- **实现**：逻辑 depth 或字节 overflow → `inlineCallDepthOverflow`。
- **所有权 / 错误 / 调用**：尾调用驱动。不修改计数（替换不是 push）。

### `inlineCallDepthOverflow` (`src/exec/vm_call.zig:254`)

- **签名**：`noinline fn inlineCallDepthOverflow(ctx: *core.JSContext, global: *core.Object) !void`。
- **作用**：造 `"stack overflow"` InternalError。noinline 以免 LLVM 把大 error-union 帧耦到每个 JS 调用序言。
- **实现**：`throwInternalErrorMessage` + `StackOverflow`。
- **所有权 / 错误 / 调用**：所有 inline/tail 超限。

### `initFrameLocals` (`src/exec/vm_call.zig:259`)

- **签名**：`pub inline fn initFrameLocals( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, use_inline_storage: bool, windows: frame_mod.FrameStorageWindows, ) !void`。
- **作用**：把 `var_count` 个局部填成 undefined。
- **实现**：0 立即返回。优先 `windows.locals`，再 vm_stack carve，再 `allocOwnedStorage`。errdefer 未移交则 `releaseOwnedStorage`。`@memset` undefined。
- **所有权 / 错误 / 调用**：`zjs_vm` / `inline_calls`。OOM。

### `initFrameVarRefs` (`src/exec/vm_call.zig:286`)

- **签名**：`pub inline fn initFrameVarRefs( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, var_refs: []const *core.VarRef, use_inline_storage: bool, windows: frame_mod.FrameStorageWindows, ) !void`。
- **作用**：安装闭包 cell 窗口。
- **实现**：传入 `var_refs` 非空：指针拷贝（qjs JS_CLOSURE_REF，17322）。空但有 `closureVar`：`InvalidBytecode`——规范函数的捕获数组来自它的函数对象，帧入口不再重建 cell。（2026-09-20 之前的 legacy 适配器臂已删；下文若仍提到 `globalLexicalCell` 或 `createClosed` 普通全局。
- **所有权 / 错误 / 调用**：窗口来自 carve 或 `allocFrameVarRefWindow`。define_var 稍后把 placeholder 换成真正 VARREF。

### `allocFrameVarRefWindow` (`src/exec/vm_call.zig:320`)

- **签名**：`fn allocFrameVarRefWindow(ctx: *core.JSContext, frame: *frame_mod.Frame, count: usize) ![]*core.VarRef`。
- **作用**：堆回退：按 JSValue 槽对齐分配，再 window 成指针切片，teardown 仍走 `storage_values`。
- **实现**：`ptr_bytes`，`divCeil` 成 value_slots，`bytesAsSlice`。
- **所有权 / 错误 / 调用**：OOM。initFrameVarRefs。

### `closure` (`src/exec/vm_call.zig:327`)

- **签名**：`pub noinline fn closure( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, ) !Step`。
- **作用**：服务 `op.fclosure` / `op.fclosure8`。
- **实现**：u32 或 u8 常量索引，`array_ops.pushFunctionClosure`。output/catch 未用。
- **所有权 / 错误 / 调用**：新函数对象 owned 压栈。热路径常自己推。

### `call` (`src/exec/vm_call.zig:352`)

- **签名**：`pub fn call( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, req_out: *call_runtime.InlineCallRequest, ) !CallStep`。
- **作用**：服务 `op.call` / `call0`–`call3` 的冷入口。
- **实现**：call 读 u16 argc 且 `pc += 3`（含 cache_idx）；callN 固定 argc。`call_runtime.execCall(..., allow_inline=true, req_out)`。
- **所有权 / 错误 / 调用**：窗口由 execCall 管理。native 快路径在分发层已先走 `vm_native`。

### `resolvedNativeCallTargetAssumeCFunction` (`src/exec/vm_call.zig:385`)

- **签名**：`pub inline fn resolvedNativeCallTargetAssumeCFunction( ctx: *core.JSContext, func_obj: *core.Object, ) ?core.Object.NativeCallTarget`。
- **作用**：一次走 payload：entry + callable realm。记录尚未 memo 则 lazy resolve 再试。
- **实现**：`nativeCallTarget()` 或先 `resolvedNativeMethodRecordAssumeCFunction` 再读。
- **所有权 / 错误 / 调用**：`vm_native.dispatch`。调用方已证明 c_function。

### `resolvedNativeMethodRecord` (`src/exec/vm_call.zig:399`)

- **签名**：`pub inline fn resolvedNativeMethodRecord( ctx: *core.JSContext, method_obj: *core.Object, ) ?*const core.NativeEntry`。
- **作用**：带 class_id 门的记录解析（qjs 读 `p->u.cfunc.c_function`）。
- **实现**：非 c_function → null；否则 Assume 变体。
- **所有权 / 错误 / 调用**：`fastNativeMethodCall` / 分发。

### `resolvedNativeMethodRecordAssumeCFunction` (`src/exec/vm_call.zig:408`)

- **签名**：`pub inline fn resolvedNativeMethodRecordAssumeCFunction( ctx: *core.JSContext, method_obj: *core.Object, ) ?*const core.NativeEntry`。
- **作用**：K1：调用方已证 `class_id == c_function`。
- **实现**：payload 已有 entry 则返回。否则 `decodeNativeBuiltinId` → `internalBuiltinRecord`，写入 `nativeEntrySlot`（comptime rodata，写一次，永不悬空）。
- **所有权 / 错误 / 调用**：宿主无 builtin id 则 null（走 generic/host 表）。

### `callResolvedNativeMethod` (`src/exec/vm_call.zig:424`)

- **签名**：`pub inline fn callResolvedNativeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, method_obj: *core.Object, record: *const core.NativeEntry, receiver: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：调用已解析记录。调用方负责一次入口 interrupt poll，并在可观察调用期间 root receiver/method/args。
- **实现**：`builtin_dispatch.callInternalRecordDirect`。
- **所有权 / 错误 / 调用**：结果 owned。`fastNativeMethodCall`、分发内部方法。

### `callMethod` (`src/exec/vm_call.zig:449`)

- **签名**：`pub noinline fn callMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, allow_inline: bool, req_out: *call_runtime.InlineCallRequest, ) !CallStep`。
- **作用**：服务 `op.call_method` 冷路径（native 快臂 miss 之后）。
- **实现**：读 u16 argc，`pc += 3`。allow_inline 且 `resolveInlineTarget` 命中 → 填 `req_out` layout `.method`，`.inline_call`。否则零拷贝窗口 `[obj, func, args...]`：poll interrupt；`fastNativeMethodCall`；再 `arrayMethodFastCall`；再 `callValueOrBytecodeRootPreRootedAfterInterruptPoll`。成功 pop 窗口，`dropUnusedCallResult` 或 push 结果。
- **所有权 / 错误 / 调用**：窗口在整个调用期间 root。错误先 pop 再 catch。构造器被 `resolveInlineTarget` 拒绝，不挡 super()。

### `dropUnusedCallResult` (`src/exec/vm_call.zig:531`)

- **签名**：`pub fn dropUnusedCallResult( _: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, _: core.JSValue, ) bool`。
- **作用**：若下一条是 `op.drop`，吞掉调用结果并 `pc += 1`（语句位置的 `f();`）。
- **实现**：pc 越界或非 drop → false。不释放传入的值（调用方决定不 push）。
- **所有权 / 错误 / 调用**：`dispatch` / `callMethod`。GC 不需要的值从未发表到栈。

### `fastNativeMethodCall` (`src/exec/vm_call.zig:542`)

- **签名**：`inline fn fastNativeMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：方法调用的 c_function 表命中。exec 不按 domain 分支；表 HIT 即终值。MISS 让调用方走 array 快路径再 generic。
- **实现**：非对象或非 c_function → null。`resolvedNativeMethodRecord` + `callResolvedNativeMethod`。bound/proxy/闭包走 generic。
- **所有权 / 错误 / 调用**：args borrowed 自窗口。host 机制故意无标准记录表 → null。

### `apply` (`src/exec/vm_call.zig:594`)

- **签名**：`pub noinline fn apply( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, req_out: *call_runtime.InlineCallRequest, ) !CallStep`。
- **作用**：服务 `op.apply`。`is_new!=0` 是构造 spread。
- **实现**：读 u16 is_new。构造：窗口 `[callable, new_target, array]`，`argsFromArray` + ValueSliceRoot。`resolveSameMachineSpreadConstructor` 命中则把数组后缀换成最终 args，`.inline_constructor`。否则 `constructValueOrBytecodeWithNewTarget`。普通 spread：窗口 `[callable, receiver, array]`；inline target 则改成 `[receiver, callable, args...]` `.inline_call`（opcode 调用，无 native Function.apply 栅栏）。否则 `callValueOrBytecodeRootPreRooted`。
- **所有权 / 错误 / 调用**：`defer freeArgs`；移到栈上的 arg 把快照槽置 undefined。reserve 可能重定位 backing，必须重载槽。

### `constructor` (`src/exec/vm_call.zig:735`)

- **签名**：`pub noinline fn constructor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.call_constructor`。
- **实现**：读 u16 argc。≤4 栈上 args 否则 heap。逆序 pop args，pop top 作 new_target；若栈仍非空再 pop func，否则 func=top。`constructValueOrBytecodeWithNewTargetInternal`，push 结果。
- **所有权 / 错误 / 调用**：args_buf defer free。handleCatchable。热路径有自己的 region 恢复。

### `throwCtorTypeError` (`src/exec/vm_call.zig:774`)

- **签名**：`fn throwCtorTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) !void`。
- **作用**：构造器 TypeError 消息。
- **实现**：`throwTypeErrorMessage` + `error.TypeError`。
- **所有权 / 错误 / 调用**：checkCtor / initCtor。

### `checkCtor` (`src/exec/vm_call.zig:779`)

- **签名**：`pub fn checkCtor(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.check_ctor`：类构造器必须 `new`。
- **实现**：`newTarget` undefined → `"class constructors must be invoked with 'new'"`。
- **所有权 / 错误 / 调用**：`checkCtorVm`。

### `checkCtorVm` (`src/exec/vm_call.zig:785`)

- **签名**：`pub noinline fn checkCtorVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：`op.check_ctor` 的冷路径入口，把 `checkCtor` 的 TypeError 转成本帧 catch 跳转。
- **实现**：`checkCtor(ctx, global, frame) catch |err|` → `call_runtime.handleCatchableRuntimeError`：返回 true（栈已截到 catch marker、异常已压栈、`frame.pc` 已指向 handler）则返回 `.continue_loop`，false 则把 `err` 上抛给分发循环；正常路径返回 `.done`。`checkCtor` 只会抛 `error.TypeError`（`throwCtorTypeError` 已先把真实 TypeError 对象挂到 ctx 上），所以这里走的是「待决异常」分支而非哨兵物化。
- **所有权 / 错误 / 调用**：不碰栈（`checkCtor` 只读 `frame.newTargetValue()`）。唯一调用点是冷表 `t[op.check_ctor]`（`tailcall_dispatch_colds.zig:669`），包在 `h(...)` 里，`Step` 被丢弃——两种取值都会让冷路径在 `frame.pc` 处重新分发，效果相同。

### `checkCtorReturn` (`src/exec/vm_call.zig:800`)

- **签名**：`pub fn checkCtorReturn(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务派生构造器返回检查 opcode：对象 → push false；undefined → push true；其它 → `DerivedConstructorReturn`（qjs 在 caller_ctx 造错，延迟物化）。
- **实现**：peek，不 pop 返回值。ctx 未用。
- **所有权 / 错误 / 调用**：`checkCtorReturnVm`。

### `checkCtorReturnVm` (`src/exec/vm_call.zig:815`)

- **签名**：`pub noinline fn checkCtorReturnVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：派生构造器返回检查的 opcode 入口，把 `checkCtorReturn` 的哨兵错误在本帧变成可捕获异常。
- **实现**：`checkCtorReturn(ctx, stack) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。关键在 `error.DerivedConstructorReturn` 这条：它没有预先挂待决异常，要靠 `exception_ops` 的表（`exception_ops.zig:589`/`617`）在 catch 缝里现造 `TypeError: derived class constructor must return an object or undefined`——即 qjs 那种「在 caller_ctx 里延迟物化」的行为。`error.StackUnderflow` 不在运行时错误表里，会直接上抛。
- **所有权 / 错误 / 调用**：调用者是 `using_ops.execVm` 的 `ext0_sub.check_ctor_return` 分支（`using_ops.zig:123`），它丢弃 `Step` 直接返回 `.done`；由于上层冷 handler 一律在 `frame.pc` 处重新分发，两种 `Step` 等价。

### `initCtor` (`src/exec/vm_call.zig:830`)

- **签名**：`pub fn initCtor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.init_ctor`：**默认派生构造器**（`class X extends Y {}` 的合成 ctor）里隐式 `super(...args)`——对当前函数对象**活**的 `[[Prototype]]` 做 Construct（`Object.setPrototypeOf` 可换构造器原型，定义期 super 载体不作权威）。
- **实现**：无 new.target → 必须 new。`GetPrototype(func_obj)`，无 → not a function。用 `originalArgs`（或 frame.args）与 new.target `constructValueOrBytecodeWithNewTarget`，push 实例。
- **所有权 / 错误 / 调用**：`initCtorVm`。每次入口都 GetPrototype，qjs 亦然。

### `initCtorVm` (`src/exec/vm_call.zig:859`)

- **签名**：`pub noinline fn initCtorVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.init_ctor` 的冷路径入口，把隐式 `super(...)` 构造过程中的可捕获错误转成本帧 catch 跳转。
- **实现**：`initCtor(ctx, output, global, stack, function, frame) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。因为 `initCtor` 会真正执行 super 构造器（任意用户代码），这里要兜住的错误面比其它两个 ctor 包装大得多：TypeError（无 new.target / 原型不是函数）、被调构造器自己抛出的待决异常、以及栈深度/OOM 类哨兵。
- **所有权 / 错误 / 调用**：成功时实例已由 `initCtor` `pushOwned` 进栈；失败时 `handleCatchableRuntimeError` 负责把栈截回 catch marker，本函数不额外释放。唯一调用点为冷表 `t[op.init_ctor]`（`tailcall_dispatch_colds.zig:674`），`Step` 同样被 `h(...)` 丢弃。

### `maxNativeJsCallDepth` (`src/exec/vm_call.zig:875`)

- **签名**：`fn maxNativeJsCallDepth(ctx: *const core.JSContext) usize`。
- **作用**：native 递归上限。
- **实现**：`max(16, stackLimit/16384)`。
- **所有权 / 错误 / 调用**：`enterCallDepth`。

### `maxLogicalJsCallDepth` (`src/exec/vm_call.zig:879`)

- **签名**：`fn maxLogicalJsCallDepth(ctx: *const core.JSContext) usize`。
- **作用**：逻辑 JS 调用深度上限（inline 链）。
- **实现**：`ctx.stackLimit()`。
- **所有权 / 错误 / 调用**：所有逻辑 depth 检查。

### `readInt` (`src/exec/vm_call.zig:883`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：读 argc / closure 索引。
- **实现**：小端。
- **所有权 / 错误 / 调用**：纯读：`bytes` 是 `function.byteCode()` 的借用切片，函数不分配、不持有、无 error set；`bytes[0..@sizeOf(T)]` 的长度由**调用点**的定长切片保证（越界是 panic，不是错误返回）。文件私有，调用方全在本文件的操作数解码点：`src/exec/vm_call.zig:428`、`:548`、`:692` 等 5 处。同名副本另见 `vm_control` / `vm_literal` / `vm_property` / `vm_value` / `vm_eval_module`，各文件一份。

## 覆盖核对

- 清单函数数: 40
- 本文标题覆盖: 40
- 未覆盖: 无
