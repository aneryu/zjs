# 12 — eval 与动态 import（`vm_eval_module.zig`）

文件职责：`op.eval`、`op.apply_eval`、`op.import`。活动帧提供词法/调用方权威；模块 job 与 Promise 结算留在 `module_graph` / `promise_ops`。栈操作数在返回分发循环前被移走或释放。

## 类型

`Step`：`done` / `continue_loop`。

`EvalStep`：上两种，外加 `tail_inline: InlineCallRequest`——非 `%eval%` 的尾位置 callee，可以复用帧。

### `directEval` (`src/exec/vm_opcodes.zig:29`)

- **签名**：`pub noinline fn directEval( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, global: *core.Object, caller_eval_global_var_bindings: bool, allow_tail_inline: bool, ) !EvalStep`。
- **作用**：服务 `op.eval`。读 argc+scope 操作数，把直接 eval 交给 `eval_ops.execDirectEval`。
- **实现**：小端 u32：低 16 位 argc，高 16 位 eval_scope。`eval_scope_head = eval_scope + arg_scope_end`（相对参数作用域终点）。`pc += 4`。把 `caller_eval_global_var_bindings` 与 `allow_tail_inline` 原样下传。把 `eval_ops` 的三态映射到 `EvalStep`。
- **所有权 / 错误 / 调用**：不自己 pop 参数；`execDirectEval` 拥有窗口。错误经 eval_ops 的 catch。调用方：`tailcall_dispatch` 的 eval handler。`allow_tail_inline` 通常是 `vm.machine.depth > 0`。

### `applyEval` (`src/exec/vm_opcodes.zig:64`)

- **签名**：`pub noinline fn applyEval( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, global: *core.Object, caller_eval_global_var_bindings: bool, ) !Step`。
- **作用**：服务 `op.apply_eval`：直接 eval 的 apply/spread 形（`eval(...args)`），参数已聚成一个数组，栈上是 `[callee, arg_array]`。
- **实现**：读 u16 eval_scope，`pc += 2`，同样换算 `eval_scope_head`。`eval_ops.execApplyEval`。该路径**从不**请求 tail-inline（`.tail_inline => unreachable`）。
- **所有权 / 错误 / 调用**：同 directEval。调用方：apply_eval 冷 handler。

### `dynamicImport` (`src/exec/vm_opcodes.zig:95`)

- **签名**：`pub noinline fn dynamicImport( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.import`（`import(specifier, options)`）。同步做 ToString 与 options 校验，加载/链接/求值进 job，返回 pending Promise（quickjs.c:31073 `js_dynamic_import`）。
- **实现**：pop options，再 pop specifier。realm 的 Promise 原型来自 `promisePrototypeFromGlobal`。`toStringForAnnexB` 失败则造 rejected Promise 压栈并返回（不抛）。referrer = `function.scriptOrModule()` 的稳定 ScriptOrModule 名（直接 eval 与 `"<eval>"` 显示名分开，逃逸的 eval 函数不依赖活着的调用帧）。`module_graph.evaluateImportCall` 失败同样压 rejected Promise。成功压 pending Promise。
- **所有权 / 错误 / 调用**：specifier/options 在 ToString / evaluate 中消费。同步错误变成 rejected Promise，**不**走 throw。OOM 等仍可上抛。调用方：import opcode handler。

### `readInt` (`src/exec/vm_opcodes.zig:133`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：小端读 eval 操作数（u32 argc/scope，u16 scope）。
- **实现**：`std.mem.readInt(T, bytes[0..@sizeOf(T)], .little)`。调用方已切好切片。
- **所有权 / 错误 / 调用**：无分配、无错误。`directEval` / `applyEval` 使用。

## 覆盖核对

- 清单函数数: 4
- 本文标题覆盖: 4
- 未覆盖: 无
