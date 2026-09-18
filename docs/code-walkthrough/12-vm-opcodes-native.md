# 12 — NativeEntry 分发（`vm_native.zig`）

文件职责：NB2 §5.2 规定的**唯一** VM 侧 native 调用分发器。内建与宿主函数共享 `NativeEntry`；本文件不按 domain 分支。不在此轮询中断（qjs `js_call_c_function` 也不轮询；JS 循环在后沿与函数入口轮询）。

## 类型

`Shape`：`.plain` = `op.call*` 窗口 `[callee, args...]`；`.method` = `op.call_method` 窗口 `[receiver, callee, args...]`。

`Outcome`：`.hit` / `.caught` 经 `coldNext` 再分发；`.miss` 落到通用 call（无 entry，或 `Function.prototype.call` 这类 forwarding entry）。

### `dispatch` (`src/exec/vm_native.zig:32`)

- **签名**：`pub noinline fn dispatch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, func_obj: *core.Object, argc: u16, shape: Shape, ) align(32) core.errors.HostError!Outcome`。
- **作用**：服务 `op.call` / `op.call0`–`op.call3` / `op.call_method`（以及分发层在 c_function 上的快臂 miss）。把窗口里的 native 函数送到 leaf 快臂或 `callRecordFromVmInRealm`。
- **实现**：`window_head` 为 method=2、plain=1。栈长度不足 method 时 `StackUnderflow`。`resolvedNativeCallTargetAssumeCFunction` 一次取出 entry+realm；没有则 `.miss`。`kind == .leaf` 时 method 先把 `pc += 3`（argc+cache_idx），再 `invokeLeafFastEntry`；命中则装箱结果。非 leaf 若 `forwards_call` 立即 `.miss`（让 `op_call_method` 按目标身份改写窗口）。否则 method 同样 `pc += 3`，`this` 取窗口头（plain 为 `undefined`），走 `callRecordFromVmInRealm`。异常哨兵 → `failure`。成功则 `stack.setLen(region_base)`，`dropUnusedCallResult` 吃掉紧随的 `op.drop`，否则 `pushOwnedAssumeCapacity`。
- **所有权 / 错误 / 调用**：窗口在调用期间保持 rooted；成功后整段丢掉（参数/callee 的槽被覆盖或缩短）。`HostError` 经 `failure`。调用方：`tailcall_dispatch` 的 plain/method native 臂。被调用方：`builtin_dispatch`、`vm_call.resolvedNativeCallTargetAssumeCFunction`。

### `managedInlineEligible` (`src/exec/vm_native.zig:90`)

- **签名**：`pub inline fn managedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool`。
- **作用**：K0 驻留臂资格：managed、不要环境、不要 forwarding，且 native 栈够放下 qjs 风格 `arg_buf`。
- **实现**：`kind != .managed` 或 `needs_env` 或 `forwards_call` → false；否则 `!rt.checkNativeStackOverflow(arity * sizeof(JSValue))`。
- **所有权 / 错误 / 调用**：无分配。`tailcall_dispatch` 在 `bl` 进 managed 快臂前调用；不合格走 `dispatch`。

### `getterInlineEligible` (`src/exec/vm_native.zig:97`)

- **签名**：`pub inline fn getterInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool`。
- **作用**：W1 `.native_getter` 臂：无类型（`sig == 0`）、无环境的 managed getter 可以直接 `bl`。
- **实现**：`kind != .getter` 或 `sig != 0` 或 `needs_env` → false；否则同样的 native 栈预检。
- **所有权 / 错误 / 调用**：服务 `op.get_field` 族在 PropSiteCache `.native_getter` 命中后的 getter 调用。无错误。

### `methodManagedInlineEligible` (`src/exec/vm_native.zig:103`)

- **签名**：`pub inline fn methodManagedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool`。
- **作用**：K2 `method_managed` 方法臂资格（`self` 从 NativeObject 解包）。
- **实现**：仅 `kind == .method_managed`，再检查 native 栈。
- **所有权 / 错误 / 调用**：`op.call_method` 驻留 handler 的 K2 臂。无错误。

### `failure` (`src/exec/vm_native.zig:110`)

- **签名**：`pub noinline fn failure( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, region_base: usize, err: core.errors.HostError, ) core.errors.HostError!Outcome`。
- **作用**：native 调用失败的冷腿：丢掉调用窗口，把 pending error 交给帧 handler。
- **实现**：`popOwnedStackRegion(stack, region_base)`；`handleCatchableRuntimeError`。抓住 → `.caught`；否则把 `err` 再抛出（`@errorCast` 处理 handler 自己的失败）。
- **所有权 / 错误 / 调用**：释放窗口内所有槽。`dispatch` 与 `tailcall_dispatch` 的 native 异常哨兵共用。

## 覆盖核对

- 清单函数数: 5
- 本文标题覆盖: 5
- 未覆盖: 无
