# 11 — VM 内核：`run` → Machine → 尾分发

本册讲解释器**外壳**：公共 `exec` 门面、`zjs_vm.run*` 如何把一条 `FunctionBytecode` 变成可跑的 `Machine`、驻留 `Vm` 的 ABI、剖析计数、以及精确根扫描。opcode 热路径见 [11-vm-dispatch.md](11-vm-dispatch.md)，冷表见 [11-vm-dispatch-colds.md](11-vm-dispatch-colds.md)，帧/操作数栈见 [11-vm-frame-stack.md](11-vm-frame-stack.md)，同机调用与小函数内联见 [11-vm-inline-calls.md](11-vm-inline-calls.md)。

权威仍是源码与 ECMA-262；QuickJS 是对照（`// quickjs.c:N`）。生产配置是栈式字节码解释器，没有寄存器机。

## 子文件

| 文件 | 内容 |
| --- | --- |
| [11-vm-kernel.md](11-vm-kernel.md) | `root.zig`、`zjs_vm.zig`、`vm_exec_state.zig`、`vm_profile.zig`、`active_invocation_trace.zig` |
| [11-vm-dispatch.md](11-vm-dispatch.md) | `tailcall_dispatch.zig`（289 个函数，每个 opcode handler 一条） |
| [11-vm-dispatch-colds.md](11-vm-dispatch-colds.md) | `tailcall_dispatch_colds.zig` 全冷表与 `b` 体 |
| [11-vm-frame-stack.md](11-vm-frame-stack.md) | `frame.zig`、`stack.zig` |
| [11-vm-inline-calls.md](11-vm-inline-calls.md) | `inline_calls.zig`、`small_inline.zig` |

## `run()` → Machine → 尾分发

一次顶层执行（`JSContext.eval` / `zjs_vm.run`）的控制流：

1. **`zjs_vm.run` / `runWithOutput`**：普通 canonical FB 先 `createRootBytecodeFunctionObject` 造**真实根函数对象**（闭包 PASS1 的 GLOBAL_DECL 已装好），再进 `runWithCallEnv`。module 与 legacy adapter 仍走 `runWithArgs`。
2. **`runWithCallEnv` → `runWithCallEnvAfterInterruptPoll`**：对齐 qjs `JS_CallInternal`：先在**调用者 Realm** 做 interrupt poll 与 `bytecodeFrameAllocaSize` 栈预算，再切到 `b->realm`。generator/async 的 alloca_size 为 0（堆上驻留帧）。
3. **`runWithArgsState`**：打 `vm_stack` watermark；构造 `Frame`（同步壳或 `initResidentExecution`）；在**最终地址**上构造 `Machine`（不可再搬）；挂 `MachineBacktraceView.root` 与 `ActiveInvocation`（`rt.active_invocation`）；首次进入则 `initFreshEntryFrame`，resume 则跳过抛片。
4. **`runTC`**：把当前 `ExecutionLevel` 写进 Machine 内驻留的 `tailcall_dispatch.Vm`（`function/frame/stack/code_base/catch_target/prop_sites`），调用 `runDispatchLoop`。
5. **`runDispatchLoopPublished`**：四寄存器 `(pc, sp, var_buf, vm)` 尾调用 `next` → `active_dispatch_tbl[pc[0]]`。每个 handler **在自己的 Zig 帧里**干活并以 `@call(.always_tail)` 离开，避免巨型 switch 把所有臂的 spill 加在同一帧上。
6. **Outcome**：`.returned` 把 `vm.return_value` 交回；depth>0 时 `popReturn` 再 `reloadTop`。`.threw` 出循环。`.tail` 由驱动 `pushCall`/`tailCallReuse`。`.suspended` 是 yield/await。`.native_returned` 把结果交给仍在跑的 Zig 内建。

热 handler 只动寄存器 `pc/sp/var_buf`；冷路径必须先 `Vm.publish` 把它们写回 `frame.pc` / `stack.top_ptr`，outlined `vm_*.zig` helper 才看得到活窗口。

## Arena 帧布局

普通同步字节码帧优先从 per-runtime `VmStackArena` 切：

```
[ args | original_args? | locals | operand stack | var_refs* | open_var_refs? ]
```

- `args` 长度 `max(argc, function.arg_count)`，不足补 `undefined`。
- `original_args` 只在 unmapped `arguments` / derived constructor / strict 需要快照时出现；sloppy 简单形参读活 `frame.args`，跳过复制。
- `locals` 是 `var_buf` 热路径基址。
- `stack` 窗口在根帧 `entry_stack.capacity==0` 时直接变成 `Stack.initArenaWindow`。
- 尾部把 JSValue 槽 **reinterpret** 成 `*VarRef` / `?*VarRef`（8 字节槽，对齐 qjs `JSVarRef **`，quickjs.c:17844）。
- arena 切不动或 generator 需要可转移存储时改 `FrameSlab.allocHeap`；`ownership.storage=.owned` 时 `deinit` 才 `free`。

`new.target` 不占热 Frame：直接构造时 `aliases_function`（就是 `current_function`）；只有 spread/`super()` 转发才懒分配 `FrameCold`。

## Generator / async 驻留帧

generator/async 必须跨 `yield`/`await` 存活，**不能**把窗口借在本次 `runWithArgsState` 的 arena watermark 上。

- 首次：`initFreshEntryFrame` 用 `generatorCombinedFrameStorage()` 或 heap slab，`installResidentStorage`（borrowed，不在 Frame 析构时 free）。
- 已启动：`GeneratorExecutionState.has_frame` 为真则 **跳过抛片**（qjs `JS_CALL_FLAG_GENERATOR` early-out，quickjs.c:17790），`resumeExecutionState` 把保存的 locals/args/var_refs/stack 装回临时 `Frame`。
- 挂起：`finishExecutionStateRun` 把窗口所有权搬回 execution record；临时 Frame 变成 `isEmptyResidentExecutionShell`，`deinit` 是 no-op。
- L0 `stop_before_pc` / `stop_on_yield` 是夹具/无标记内部 generator 的停机缝；生产 generator 用 `OP_initial_yield`。只有 `depth == 0` 且 `l0.stop_before_pc != null` 时 `runDispatchLoop` 才置 `local_fast_blocked` 并把 `active_dispatch_tbl` 指向 `&cold_table`，让每条 op 都经过 `coldNext` 里的 `maybeStop`。

## `VmExecState` ABI

`vm_exec_state.zig` **零函数**。它钉的是解释器、`vm_native` 与未来 baseline JIT 共用的执行态布局（engine-evolution-plan §5.3/§5.4）。字段顺序是 ABI（`VM_ABI_VERSION = 1`）：

| 偏移 | 字段 | 含义 |
| --- | --- | --- |
| 0 | `vm: *anyopaque` | 解释器私有 `tailcall_dispatch.Vm*`；JIT 传自己的等价物 |
| 8 | `pc` | 当前 opcode 指针 |
| 16 | `sp` | 操作数栈顶 |
| 24 | `fp` | 帧指针（局部基） |
| 32 | `var_base` | 变量基 |
| 40 | `function` | 当前 `FunctionBytecode*` |

`function` 之后紧跟 `exit_reason`/`exit_value`（各带默认值 `.none` / `undefined`），再是 native-call 子集 `ctx/rt/global/output/stack/frame/machine/catch_target`。`tail` / `reenter` / `native_returned` **不**穿过这条边界。生成的 `.inc` 必须从这个 struct 出，禁止手写偏移。

`VmHelperStatus`：`continue_execution / exception / function_return / suspended / interrupted / bailout`。`VmExitReason`：`none / returned / threw / suspended`。

## `tail_hot_layout_aarch64.ld`

AArch64 ELF 专用链接脚本（`build/artifacts.zig` 在 `arch == .aarch64 and ofmt == .elf` 时给 zjs/zjs-size/zjs-profile 三个可执行挂上）。把所有 `linksection(".text.zjs.op_handlers")` 的 Handler 收成页对齐的 `.text.zjs.op_handlers` 岛，`INSERT BEFORE .text`。源码顺序即岛内顺序；新 handler 必须进 `.text.zjs.op_handlers.tail`，以免滑动已测量的 get_arg/loc/arith 偏移。`pad=0` 时 layout pad 为空，KEEP 为 no-op。其他目标不用此脚本。本文件无 Zig 函数，不进清单。


## `src/exec/root.zig`
exec 子系统命名空间与嵌入用薄 `Vm` 门面。只 re-export 各域，不合并所有权缝。这里的 `Vm` **不是** `tailcall_dispatch.Vm`：它自有一条 `Stack`，借用 `JSContext`，把 `run` 委托给 `zjs_vm.runWithOutput`。

`pub const subsystem_name = "exec"`。随后一长串 `pub const zjs_vm = @import(...)` 把 frame/stack/call/module/promise/… 暴露给 `src/exec` 聚合者。

### `opcodeName` (`src/exec/root.zig:72`)

- **签名**：`pub fn opcodeName(opcode: u8) []const u8`。
- **作用**：把 opcode 字节映射成调试用名字（转调 `bytecode.opcode.nameOf`）。
- **实现**：直接 `return bytecode.opcode.nameOf(opcode)`。给调试/剖析打印用，不碰栈。
- **所有权 / 错误 / 调用**：错误：无。 调用：不是 VM 内部调用的函数——`src/root.zig` 的 `activateOpcodeProfile` 把它作为函数指针注册给 `core.profile.setOpcodeNameProvider`，供 CLI 打印 opcode 剖析表。

### `Vm.init` (`src/exec/root.zig:83`)

- **签名**：`pub fn init(ctx: *core.JSContext) Vm`。
- **作用**：`src/exec` 的嵌入门面构造器：把一个 `JSContext` 包成可以直接 `run(FunctionBytecode)` 的轻量执行器，自带一条按 `ctx.stackLimit()` 设限的操作数栈。
- **实现**：保存 `ctx`，用 `ctx.runtime.memory` 与 `ctx.stackLimit()` 构造空 `Stack`。output/globals 保持默认空。
- **所有权 / 错误 / 调用**：错误：无。 调用：嵌入门面，VM 内核自身不用；仓库内的调用方是 `src/tests/helpers.zig` / `src/tests/exec.zig` 这类嵌入式用例。

### `Vm.initWithOutput` (`src/exec/root.zig:90`)

- **签名**：`pub fn initWithOutput(ctx: *core.JSContext, output: *std.Io.Writer) Vm`。
- **作用**：同 `init`，并挂嵌入方 `Writer` 给 print 一类输出。
- **实现**：同 `init`，再挂上嵌入方提供的 `*std.Io.Writer`，供 `print` 一类宿主输出。
- **所有权 / 错误 / 调用**：错误：无。 调用：同 `Vm.init`，仓库内只有嵌入式测试用例（`src/tests/exec.zig`）用它把 print 输出接到自己的 writer。

### `Vm.deinit` (`src/exec/root.zig:98`)

- **签名**：`pub fn deinit(self: *Vm) void`。
- **作用**：归还这个门面自己持有的两样东西——globals 槽数组与操作数栈 backing；`JSContext` 由调用方所有，不在此销毁。
- **实现**：先把 `globals` 字段置空切片，再把取出的每个槽写成 undefined；长度非 0 才 `memory.free`；清空 `global_object`；`stack.deinit(runtime)`。不销毁 `JSContext`。
- **所有权 / 错误 / 调用**：错误：无。 调用：嵌入方/测试用例在 `Vm` 生命期结束时调用；VM 内核不调。

### `Vm.run` (`src/exec/root.zig:109`)

- **签名**：`pub fn run(self: *Vm, function: *const bytecode.FunctionBytecode) !core.JSValue`。
- **作用**：执行一条 canonical `FunctionBytecode`。
- **实现**：`stack.reserveAdditional(function.stack_size)` 后转 `zjs_vm.runWithOutput(ctx, &stack, function, output)`。这是嵌入门面，真正造根函数对象在 `zjs_vm`。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：嵌入方/测试入口；它自己调 `zjs_vm.runWithOutput`。
## `src/exec/zjs_vm.zig`
唯一的字节码 dispatcher 入口（parser-rewrite M2 之后）。`CallEnv` 收齐 this/args/captures/eval/generator/module-await 旗标；`PreparedEntryFrame` 允许调用方预切 slab。
首次抛片见 `initFreshEntryFrame`；栅栏内捕获循环见 `runActiveInvocationAfterNativeBoundaryError`。

### `run` (`src/exec/zjs_vm.zig:37`)

- **签名**：`pub fn run( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, ) !core.JSValue`。
- **作用**：执行一条 canonical `FunctionBytecode`。
- **实现**：函数体只有一行 `return runWithOutput(ctx, stack, function, null)`；造根函数对象、选 `this`、module/legacy 分流与异常清理全在 `runWithOutput` 里。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：对外/嵌入入口，仓库里目前没有直接调用方（`exec.Vm.run` 直接走 `runWithOutput`）。

### `runWithOutput` (`src/exec/zjs_vm.zig:45`)

- **签名**：`pub fn runWithOutput( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, output: ?*std.Io.Writer, ) !core.JSValue`。
- **作用**：带可选 writer 的根执行入口。
- **实现**：非 module 且无 legacy adapter：取 `function.realmContext()`（为 null 则 `error.InvalidBuiltinRegistry`），在该 Realm 上 `contextGlobal` + `createRootBytecodeFunctionObject(.root_global)`，`rootValues` 护住根函数值，`runtimeStrictMode()` 时 `this` 为 undefined、否则为全局对象，captures 取根函数对象的 `functionCaptures()`，再 `runWithCallEnv`（`direct_eval_vars_reach_global` / `global_declarations_prevalidated` 为 true）。失败且非 JSException/Interrupted、未要求 preserve 且确有 pending 异常时 `clearException`。module/legacy 走 `runWithArgs`（module 或 strict 时 `this` 为 undefined）。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 GC 根：`core.runtime.rootValues` 帧护住尚未入帧的根函数值。 调用：`zjs_vm.run` 与 `exec.Vm.run`。

### `contextGlobalFast` (`src/exec/zjs_vm.zig:103`)

- **签名**：`pub inline fn contextGlobalFast(ctx: *core.JSContext) !*core.Object`。
- **作用**：`contextGlobal` 的寄存器快臂：活 context 已有 global 则不再走 bootstrap。
- **实现**：`ctx.global` 已有且 `ctx.isLive()` 则直接返回；否则落到 `contextGlobal` 做 bootstrap。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：嵌入 API 侧的 `src/js_context.zig`（宿主取全局的快路径）。

### `contextGlobal` (`src/exec/zjs_vm.zig:110`)

- **签名**：`pub fn contextGlobal(ctx: *core.JSContext) !*core.Object`。
- **作用**：懒构建并缓存 per-context 全局对象（标准构造器 + print/console）。
- **实现**：已有 global：未 live 则 `publishLive` 后返回。否则按 `call_mod.contextGlobalOwnPropertyCapacity` 的容量 `Object.createWithOwnPropertyCapacity` 建 `class.ids.global_object`，`ensureGlobalPayload`，暂存 `ctx.global`（construction-only），`installHostGlobals`，建 `throwTypeErrorIntrinsicForGlobal`，首次时预分配 OOM 错误对象（无栈，对齐 qjs；失败吞成 null），读出 `eval` 缓存到 `ctx.eval_function`，`finishConstruction`。`errdefer` 调 `rollbackIntrinsicBootstrap` 并把 `ctx.global` 置回 null。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：`runWithOutput`、`eval_entry.zig`、`module_graph.zig`，以及嵌入层 `src/js_context.zig` / `src/binding/binding.zig`。

### `runWithArgs` (`src/exec/zjs_vm.zig:151`)

- **签名**：`pub fn runWithArgs( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, initial_this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, break_var_ref_cycles_on_exit: bool, strict_unresolved_get_var: bool, stop_on_yield: bool, ) !core.JSValue`。
- **作用**：带显式 this/args/captures 的兼容入口。
- **实现**：canonical 非 module 走 `runCanonicalRootWithArgs`；否则直接 `runWithCallEnv`。catch 后同样按 preserve/JSException/Interrupted 决定是否 `clearException`。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：`runWithOutput` 的 module/legacy 臂，以及 `src/tests/exec.zig` 的兼容用例。

### `resolveSuppliedRootCapture` (`src/exec/zjs_vm.zig:202`)

- **签名**：`fn resolveSuppliedRootCapture( opaque_context: ?*anyopaque, ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, index: usize, cv: bytecode.function_bytecode.BytecodeClosureVar, ) HostError!*core.VarRef`。
- **作用**：把调用方传入的 capture 数组按 index 交给闭包 PASS1。
- **实现**：把 `opaque_context` 当成 `SuppliedRootCaptures`（为 null 也是 `InvalidBytecode`）；index 越界 `InvalidBytecode`；否则返回调用方提供的 cell。ctx/global/function/cv 有意忽略。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：不直接被调用——`runCanonicalRootWithArgs` 把它装进 `ClosureCaptureSource.custom`，由 `object_ops.createRootBytecodeFunctionObject` 的闭包 PASS1 逐 index 回调。

### `runCanonicalRootWithArgs` (`src/exec/zjs_vm.zig:223`)

- **签名**：`fn runCanonicalRootWithArgs( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, initial_this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, break_var_ref_cycles_on_exit: bool, strict_unresolved_get_var: bool, stop_on_yield: bool, ) HostError!core.JSValue`。
- **作用**：为借用的 canonical FB 造与 parser.Result 相同的真实根函数对象再执行。
- **实现**：校验 Realm/runtime/global 一致，captures 长度匹配。空 captures 用 `.root_global`，否则 custom resolver。造根函数对象、rootValues 护住，再 `runWithCallEnv`（`direct_eval_vars_reach_global` 与 `global_declarations_prevalidated` 为 true）。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 GC 根：`core.runtime.rootValues` 帧护住新建的根函数值。 调用：只由 `runWithArgs` 的 canonical 臂调用。

### `runWithCallEnv` (`src/exec/zjs_vm.zig:326`)

- **签名**：`pub fn runWithCallEnv(env: CallEnv) HostError!core.JSValue`。
- **作用**：统一 `CallEnv` 入口：中断轮询后进入状态机。
- **实现**：`generator_state != null` 且未 precharged：复制一份 env，把 `global` 换成 `ctx.global orelse env.global`，`enterCallDepth(..., 0)`（对齐 `async_func_resume` 的 `js_check_stack_overflow(rt, 0)`）、`pollInterrupt`，标记 `call_depth_precharged` 后进 AfterInterruptPoll。普通路径先 poll 再 AfterInterruptPoll。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：`runWithOutput` / `runWithArgs` / `runCanonicalRootWithArgs`，以及 `call.zig`、`call_runtime.zig`、`module.zig`、`eval_entry.zig`。

### `runWithCallEnvAfterInterruptPoll` (`src/exec/zjs_vm.zig:350`)

- **签名**：`pub fn runWithCallEnvAfterInterruptPoll(env: CallEnv) HostError!core.JSValue`。
- **作用**：调用者 Realm 已 poll 之后的最终字节码入口，避免跨 Realm 双计栈预算。
- **实现**：在调用者 Realm 按 qjs 顺序做 `bytecodeFrameAllocaSize(function, args.len, copy_argv)` 栈守卫（generator 为 0），然后若 `function.realmContext()` 非空就把 `ctx/global` 切到该 Realm（realm 没有 global 则 `error.InvalidBuiltinRegistry`），最后把 `CallEnv` 摊平成参数调用 `runWithArgsState`。已 `call_depth_precharged` 则不再二次 enter。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：`runWithCallEnv`，以及已自行完成 poll 的 `call_runtime.zig` / `promise_ops.zig` 调用路径。

### `runWithArgsState` (`src/exec/zjs_vm.zig:410`)

- **签名**：`fn runWithArgsState( ctx: *core.JSContext, entry_stack: *stack_mod.Stack, entry_function: *const bytecode.FunctionBytecode, initial_this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, break_var_ref_cycles_on_exit: bool, entry_strict_unresolved_get_var: bool, entry_stop_on_yield: bool, entry_generator_state: ?*core.Object, resume_value: ?core.JSValue, entry_stop_before_pc: ?usize, current_function_value: core.JSValue, new_target_value: core.JSValue, entry_eval_global_var_bindings: bool, entry_direct_eval_vars_reach_global: bool, entry_is_eval_code: bool, entry_global_declarations_prevalidated: bool, entry_suspend_on_module_await: bool, entry_initial_pc: usize, entry_prepared_frame: ?*const PreparedEntryFrame, ) HostError!core.JSValue`。
- **作用**：构造 Machine / 帧 / ActiveInvocation 并驱动 `runTC` 直到结束。
- **实现**：真正的解释器入口。校验根函数对象；可选 GLOBAL_DECL 校验；给 `vm_stack` 打 watermark；generator 则 `Frame.initResidentExecution`，否则 `Frame.init`。构造不可移动的 `Machine` + `ActiveInvocation`（精确根开启时挂 `traceRoots`），push backtrace。非 resume 走 `initFreshEntryFrame` 切 `[args|locals|operand|var-ref]`；已有 `has_frame` 的 generator 跳过抛片，直接 `resumeExecutionState`。`runTC` 循环：错误时只有 `machine.depth > 0` 且 `unwindForError` 报告被捕获才 continue，否则原样返回错误。成功返回 `machine.vm.return_value`。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 同步帧优先 `VmStackArena` 切窗口，入口处 `mark()` / `defer restore()` 成批回收，不逐值挂 root。 驻留帧：storage 所有权在 `GeneratorExecutionState`，Frame 只借窗口。 `break_var_ref_cycles_on_exit` 时退出前跑一次 `tryRunObjectCycleRemovalWithValueRoots(.engine_active)`。 调用：唯一调用方是 `runWithCallEnvAfterInterruptPoll`。

### `initFreshEntryFrame` (`src/exec/zjs_vm.zig:594`)

- **签名**：`noinline fn initFreshEntryFrame( ctx: *core.JSContext, entry_stack: *stack_mod.Stack, entry_function: *const bytecode.FunctionBytecode, frame_storage: *frame_mod.Frame, global: *core.Object, args: []const core.JSValue, var_refs: []const *core.VarRef, entry_generator_state: ?*core.Object, entry_prepared_frame: ?*const PreparedEntryFrame, ) HostError!void`。
- **作用**：仅首次进入时切 `[args|original_args?|locals|operand|var-ref]` 窗口。resume 的 generator 已经在 execution state 里拥有这些窗口，把分配留在 `runWithArgsState` 会撑大每次 resume 的 native 帧。
- **实现**：非 generator/async 且无 generator_state 则用 `ctx.runtime.vm_stack`。`need_original_args` / `frame_arg_count` / `open_var_ref_count` 优先取 `PreparedEntryFrame`，否则按 FB 与 `args.len` 算。slab：有 prepared 则 `installResidentStorage`；有 generator combined storage 则 `FrameSlab.partitionStorage`；否则 arena `FrameSlab.carve`，carve 失败或无 arena 则 `allocHeap` + `installOwnedStorage`。根帧 `entry_stack.capacity==0` 且 slab 带 stack 窗口时把 `entry_stack` 改成 `Stack.initArenaWindow`。然后 `initFrameLocals`、`initArguments`、安装 open var-ref 槽、`initFrameVarRefs`。
- **所有权 / 错误 / 调用**：arena 窗口借 `VmStackArena` watermark；heap 窗口 `ownership.storage=.owned`，Frame 析构才 free。generator 驻留片 Frame 只借。错误：`HostError`（OOM）。调用：`runWithArgsState` 非 resume 臂。

### `runTC` (`src/exec/zjs_vm.zig:701`)

- **签名**：`fn runTC(m: *inline_calls.Machine) HostError!void`。
- **作用**：把 Machine 当前层发布进驻留 `Vm`，启动 handler 链。
- **实现**：先断言 `vm.ctx/rt/global` 与 Machine 一致，再发布 `machine` 本身与 `currentLevel()` 的 `function`（随之 `publishPropSites(func)`，避免上一函数的 prop-site 镜像按序号错配）、`frame`、`stack`、`code_base = func.byteCode().ptr`、`catch_target`，然后 `tailcall_dispatch.runDispatchLoop(vm)`。ctx/rt/global/output 与两张驻留尾表（`resident_tail_tbl` / `property_tail_tbl`）在 `Vm.initResident` 时已写好。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：`runWithArgsState` 的主循环、`runActiveInvocationUntilNativeBoundary`、`runActiveInvocationAfterNativeBoundaryError`。

### `runActiveInvocationUntilNativeBoundary` (`src/exec/zjs_vm.zig:724`)

- **签名**：`pub inline fn runActiveInvocationUntilNativeBoundary( invocation: *inline_calls.ActiveInvocation, scope: anytype, ) HostError!void`。
- **作用**：在已激活 Machine 上跑回调 Entry，直到 `.native_boundary` 把控制交回 Zig 内建。
- **实现**：断言 depth > fence。`runTC` 成功则断言回到 fence 且 top 匹配。失败走 outlined `runActiveInvocationAfterNativeBoundaryError`：在 fence 内 `unwindForErrorToDepth` 循环，捕获则再 `runTC`，未捕获把错误交回 native。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：`call_runtime.zig` 的宿主回调边界（内建在自己的原生帧里驱动 JS 回调）。

### `runPushedEntryUntilNativeBoundary` (`src/exec/zjs_vm.zig:740`)

- **签名**：`pub inline fn runPushedEntryUntilNativeBoundary( invocation: *inline_calls.ActiveInvocation, scope: anytype, entry: *inline_calls.Entry, target: *const inline_calls.InlineTarget, ) HostError!void`。
- **作用**：刚 push 的 Entry 用 pusher 寄存器发布 per-level 字段后跑到原生栅栏。
- **实现**：`vm.publishPushedEntry` 用 pusher 寄存器发布新层（pc0 = code_base），`runDispatchLoopPublished` 直入。错误同样走栅栏 unwind。
- **所有权 / 错误 / 调用**：错误：`HostError`；上层把它变成 JS 异常或继续 unwind。 调用：`call_runtime.zig` 中刚 `pushCall` 完 Entry 的两条宿主→JS 路径。

### `runActiveInvocationAfterNativeBoundaryError` (`src/exec/zjs_vm.zig:763`)

- **签名**：`noinline fn runActiveInvocationAfterNativeBoundaryError( machine: *inline_calls.Machine, fence_depth: usize, expected_top: ?*inline_calls.Entry, initial_err: HostError, ) HostError!void`。
- **作用**：把「回调抛错」的完整有界 unwind 循环从成功同步返回驱动里拆出去：短回调只付一次 `runTC` + 一次结果检查。
- **实现**：`pending_err = initial_err`。循环：若 `depth <= fence_depth` 或 `unwindForErrorToDepth(global, fence, pending)` 未捕获，断言回到 fence 且 top 匹配，返回 `pending_err`。捕获则再 `runTC`：失败把 `pending_err` 换成新错 continue；成功同样断言 fence/top 后 `return`。
- **所有权 / 错误 / 调用**：不越过 fence 去碰挂起的外层字节码帧。错误原样交回 native builtin。调用：`runActiveInvocationUntilNativeBoundary` / `runPushedEntryUntilNativeBoundary` 的 `runTC`/`runDispatchLoopPublished` catch 臂。

### `reserveEntryFrameCapacity` (`src/exec/zjs_vm.zig:792`)

- **签名**：`fn reserveEntryFrameCapacity(entry_stack: *stack_mod.Stack, entry_function: *const bytecode.FunctionBytecode) !void`。
- **作用**：按 FB `stack_size` 预留操作数栈（Debug 允许未 finalize 的夹具用 code 长度）。
- **实现**：ReleaseFast 用 finalize 过的 `stack_size`；Debug 若 stack_size==0 但有 code，用 code 长度兜未跑 stack-size pass 的夹具。然后 `Stack.reserveFrameCapacity`。
- **所有权 / 错误 / 调用**：错误：error union（`StackOverflow` / OOM），由 `runWithArgsState` 交给上层。 调用：只由 `runWithArgsState` 在非 resume（`!skip_resume_slab`）时调用；已驻留的 generator 帧在创建那次已过同一道门。
## `src/exec/vm_exec_state.zig`
**零函数文件。** 只钉 ABI 类型，见上文「`VmExecState` ABI」。`VM_ABI_VERSION: u32 = 1`。comptime 断言 `vm/pc/sp/fp/var_base/function` 的偏移为 0/8/16/24/32/40。

native helper（`vm_native.zig`）吃 `*VmExecState` 而不是解释器私有 `*tailcall_dispatch.Vm`，这样 JIT 第一天就能调同一组 helper。通过 typed 字段拿 `ctx/rt/global/output`，不要把 `vm: *anyopaque` 再转回去。
## `src/exec/vm_profile.zig`
默认构建整文件编译掉。剖析构建把计数放在 `cont`/`next`，handler 体保持未包一层（曾经的 256 槽 `profiledHandler` 把 L-1 岛滑开，zlib 上 `op_return` musttail ABI 崩溃）。

### `noteDispatch` (`src/exec/vm_profile.zig:17`)

- **签名**：`pub inline fn noteDispatch(rt: *core.JSRuntime, pc: [*]const u8) void`。
- **作用**：剖析构建里记下一次 opcode 分发（含 ext0 子码）。
- **实现**：`enabled`（= `build_options.zjs_enable_opcode_profile`）为 false 时 `comptime` 直接 return，整函数编译掉。否则 `rt.opcode_profile` 为 null 就返回，有则 `profile.noteDispatch(pc[0])`；若该字节是 `LogicalOpcode.ext0` 再 `noteCarrierSub(pc[1])`。只做内存存储，不 syscall，musttail 安全。
- **所有权 / 错误 / 调用**：错误：无。 调用：`tailcall_dispatch.zig` 的两个分发点 `next` 与 `cont`（都包在 `if (comptime vm_profile.enabled)` 里），handler 体不再套壳。
## `src/exec/active_invocation_trace.zig`
`zjs_vm.zig` 只在 `core.runtime.value_root_frames_enabled` 为真时 `@import` 它（该常量现在恒为 `true`，见 `src/core/runtime.zig`，所以实际总是编译）。core 只看见记录偏移 0 的 `ActiveInvocationTrace`；文件顶部的 `comptime` 块就断言这两件事。只扫语义活窗口：Frame 的 this/function/args/locals/var_refs、Stack `liveValues`、以及仍停在起点的 `PendingCallRegion`。未使用的 slab 容量不访问。未 publish 的 generator shell 不能当 Object 走（shape_ref 未初始化）。

### `traceRoots` (`src/exec/active_invocation_trace.zig:26`)

- **签名**：`pub fn traceRoots(invocation_ptr: *anyopaque, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：精确根扫描入口：沿 `ActiveInvocation` 链走每台 Machine。
- **实现**：把 opaque 指针当成 `ActiveInvocation*`，沿 `previous` 链对每台 Machine 调 `traceMachine`。
- **所有权 / 错误 / 调用**：错误：`RootTraceError`，由收集器处理。 调用：不是被 VM 调用的——`runWithArgsState` 把它写进 `ActiveInvocation.header`，`JSRuntime.traceActiveRoots` 通过 `rt.active_invocation` 的偏移 0 记录头调用。

### `traceMachine` (`src/exec/active_invocation_trace.zig:34`)

- **签名**：`fn traceMachine(machine: *inline_calls.Machine, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：扫 L0 与 inline Entry 的 Frame/Stack/pending 窗口和已 publish 的 generator。
- **实现**：扫 `async_completions`、L0 frame/stack、已 `heap_accounted` 的 generator_state（用 `visitor.constOptionalObject`），再沿 `machine.top` 的 Entry 链逐层 `traceFrame`/`traceStack`/`traceEntryExtras`，两处 `traceStack` 都带上同一个 `machine.pending_call_region`。未 publish 的 generator shell 不当地当 Object 走（shape_ref 未初始化）。
- **所有权 / 错误 / 调用**：错误：`RootTraceError`。 GC：本函数是精确根 walk，只扫活窗口。 调用：本模块的 `traceRoots` 沿 `previous` 链逐台 Machine 调用。

### `traceFrame` (`src/exec/active_invocation_trace.zig:64`)

- **签名**：`fn traceFrame(rt: *core.JSRuntime, frame: *frame_mod.Frame, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：扫 this/current_function/已注册 FB/args/locals/cold/var_refs。
- **实现**：扫 this、current_function；仅当 `rt.gc.address_registry.containsHeader` 认得该 FB header 才把 function 当堆对象报上去（栈上夹具 Bytecode 的 header 是垃圾）。再扫 args/locals；`frame.cold` 存在时扫非 `aliases_function` 的 new_target 与 `cold.original_args`；最后逐个把 var_ref/非空 open_var_ref 的 `valueRef()` 报上去。
- **所有权 / 错误 / 调用**：错误：`RootTraceError`。 GC：本函数是精确根 walk，只扫活窗口。 调用：本模块的 `traceMachine`（L0 帧与每个 inline Entry 的帧）。

### `traceStack` (`src/exec/active_invocation_trace.zig:98`)

- **签名**：`fn traceStack( stack: *stack_mod.Stack, pending: *const stack_mod.PendingCallRegion, visitor: *RootVisitor, ) RootTraceError!void`。
- **作用**：扫 `liveValues` 以及仍停在起点的 `PendingCallRegion`。
- **实现**：`visitor.values(liveValues())`；若 `pending.windowFor(stack)` 非空再扫那一段（调用点已 retreat、尚未入帧的参数）。
- **所有权 / 错误 / 调用**：错误：`RootTraceError`。 GC：本函数是精确根 walk，只扫活窗口。 调用：本模块的 `traceMachine`（L0 Stack 与每个 Entry 的 Stack）。

### `traceEntryExtras` (`src/exec/active_invocation_trace.zig:114`)

- **签名**：`fn traceEntryExtras(entry: *inline_calls.Entry, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：扫 native_caller 与 `.proxy_get` 停住的 atom。
- **实现**：`teardown.has_native_caller` 或 `teardown.constructor_completion` 时扫 `native_caller`；`return_action == .proxy_get` 且 `continuation_payload != null_atom` 时用 `visitor.atomRoot` 把 continuation 里的 atom 当根（其它 action 把同一个字当 for-of 深度或 0，所以 action 才是判别式）。
- **所有权 / 错误 / 调用**：错误：`RootTraceError`。 GC：本函数是精确根 walk，只扫活窗口。 调用：本模块的 `traceMachine`，只对 inline Entry 调。
## 覆盖核对

- 清单函数数: 27（`src/exec/active_invocation_trace.zig` 5 + `src/exec/root.zig` 5 + `src/exec/vm_profile.zig` 1 + `src/exec/zjs_vm.zig` 16）
- 本文标题覆盖: 27
- 未覆盖: 无
- 第 11 册合计（五份子文件）: 清单 755，标题 755，未覆盖 无（27 + 72 + 125 + 242 + 289）

核对命令：

```sh
python3 docs/code-walkthrough/_check_coverage.py --docs 'docs/code-walkthrough/11-*.md' \
  src/exec/root.zig src/exec/zjs_vm.zig src/exec/tailcall_dispatch.zig \
  src/exec/tailcall_dispatch_colds.zig src/exec/frame.zig src/exec/stack.zig \
  src/exec/inline_calls.zig src/exec/small_inline.zig src/exec/vm_exec_state.zig \
  src/exec/vm_profile.zig src/exec/active_invocation_trace.zig
```
