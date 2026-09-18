# 13 — eval 入口与直接 eval

`eval_entry.zig` 是公开 script/module 求值（QuickJS `JS_EvalInternal` 的 exec 侧）。`eval_ops.zig` 实现 `OP_eval` / `OP_apply_eval` 的直接 eval，以及闭包种子。间接 eval 在 `call_runtime.indirectEval`。

## 类型

### `PreparedRoot`（`eval_entry.zig:59`）

编译阶段产物：可选 `module_record`、是否要求值、`function`、已发布的 `root_function_value`/`root_function_object`、`first_execute_start`。解析结果在 `prepareRootFunction` 内 `deinit`，不活过 VM 帧。

### `ModuleAwaitResume`（`eval_entry.zig:405`）

模块顶层 `await` 恢复：`value` + `rejected`。

### `DirectEvalClosureSeed`（`eval_ops.zig:70`）

`values: []EvalClosureSeed` + `is_arg_scope`。参数初始化器里的 eval 只看见伪参数绑定。

### `DirectEvalClosureResolverContext`（`eval_ops.zig:222`）

把调用者帧交给 `createRootBytecodeFunctionObject` 的 custom resolve。

### `ExecEvalResult`（`eval_ops.zig:252`）

`done` / `continue_loop` / `tail_inline: InlineCallRequest`。后者是「callee 不是 `%eval%` 且处于 `return` 前」的尾调用复用。

---

## `eval_entry.zig`

### `evalScriptSource` (`src/exec/eval_entry.zig:28`)

- **签名**：`pub fn evalScriptSource(ctx: *core.JSContext, source_text: []const u8, options: core.context.ScriptEvalOptions) !core.JSValue`。
- **作用**：脚本求值薄包装，选 Realm 全局后进 `evalGlobalScriptSource`。
- **实现**：`options.realm_global orelse contextGlobal`，转 `call.evalGlobalScriptSource`。
- **所有权 / 错误 / 调用**：源文借用。公共 `evalScript` / `$262.evalScript`。

### `evalScriptValue` (`src/exec/eval_entry.zig:33`)

- **签名**：`pub fn evalScriptValue(ctx: *core.JSContext, source_value: core.JSValue, options: core.context.ScriptEvalOptions) !core.JSValue`。
- **作用**：字符串 JSValue → UTF-8 再 `evalScriptSource`。
- **实现**：非 string 抛 `TypeError`；`appendSourceStringUtf8` 进 `ArrayList`。
- **所有权 / 错误 / 调用**：临时 buffer 在 runtime allocator，`defer deinit`。

### `resolveModuleName` (`src/exec/eval_entry.zig:47`)

- **签名**：`noinline fn resolveModuleName(ctx: *core.JSContext, options: core.context.ContextEvalOptions) !core.Atom`。
- **作用**：模块才 intern 名；`<eval>` 编成 `<eval>#N`。
- **实现**：非 module 返回 `null_atom`。`bufPrint` 的 64 字节缓冲必须在独立帧，不能与解释器同帧（保守扫描假根）。
- **所有权 / 错误 / 调用**：atom 由 `eval` 用 `rootAtoms` 跨编译+求值保住。

### `prepareRootFunction` (`src/exec/eval_entry.zig:82`)

- **签名**：`noinline fn prepareRootFunction( ctx: *core.JSContext, source_text: []const u8, options: core.context.ContextEvalOptions, module_name: core.Atom, ) !PreparedRoot`。
- **作用**：编译、安装、链接，发布根函数对象；解析结果在此释放。
- **实现**：`parser.compile`（script 总是 `return_completion=true`，对齐 `js_parse_program` hidden `<ret>`）。语法错误走 `throwParseSyntaxError`（fileName/line/column + `at file:line:col`，quickjs.c:7553）。module：`installParsedModuleArtifact` + `linkModule`；已 evaluated 跳过；errored 重抛 `eval_exception`。script：`takeFunctionBytecodeValue` 进 `createRootBytecodeFunctionObject(.root_global)`，Realm 必须是 `ctx`。
- **所有权 / 错误 / 调用**：`compiled.deinit` 在返回前。`eval` 立刻 root `root_function_value`。

### `eval` (`src/exec/eval_entry.zig:197`)

- **签名**：`pub fn eval(ctx: *core.JSContext, source_text: []const u8, options: core.context.ContextEvalOptions) !core.JSValue`。
- **作用**：公开 script/module/direct/indirect eval 入口。
- **实现**：`call_depth==0` 时 `updateNativeStackTop`（`JS_UpdateStackTop`）；嵌套直接 eval 不刷新。`prepareRootFunction` 在独立 native 帧。module：status `linked→evaluating→evaluated`，失败缓存 `eval_exception`。script：`runWithCallEnv`，strict `this` 为 undefined，sloppy 为 Realm 全局；`eval_global_var_bindings` 仅 `eval_indirect`；`direct_eval_vars_reach_global` 对 script 或 sloppy indirect。精确根用 `.slices`（生产 container-only 政策）。最后 `drainAndFinish`。
- **所有权 / 错误 / 调用**：`JSContext.eval`。job drain 在 `drainAndFinish`。

### `drainAndFinish` (`src/exec/eval_entry.zig:325`)

- **签名**：`noinline fn drainAndFinish( ctx: *core.JSContext, options: core.context.ContextEvalOptions, result: core.JSValue, ) !core.JSValue`。
- **作用**：root 完成值、排微任务、应用 host 结果政策。
- **实现**：完成值放 slice root（scalar ValueRoot 生产会被擦掉）。`drainPendingPromiseJobs`。script 且 `discard_script_result` 或 `!return_completion` 则丢完成值返回 undefined。
- **所有权 / 错误 / 调用**：drain OOM 时 completion 由 root 保住再释放。

### `runEvalModule` (`src/exec/eval_entry.zig:360`)

- **签名**：`fn runEvalModule( ctx: *core.JSContext, record: *core.module.ModuleRecord, output: ?*std.Io.Writer, timing: ?*core.context.ContextEvalTiming, ) !core.JSValue`。
- **作用**：模块体步进，处理顶层 await。
- **实现**：generator class 的 `module_state`。循环 `runModuleEvaluationStep`；若 just yielded，`waitForModuleAwaitReaction` 后设 resume completion type（rejected=2）。
- **所有权 / 错误 / 调用**：链接错误经 `moduleResolutionError`。

### `waitForModuleAwaitReaction` (`src/exec/eval_entry.zig:413`)

- **签名**：`fn waitForModuleAwaitReaction( ctx: *core.JSContext, output: ?*std.Io.Writer, awaited: core.JSValue, timing: ?*core.context.ContextEvalTiming, ) !ModuleAwaitResume`。
- **作用**：等该 await 的 reaction 排到 FIFO 头。
- **实现**：`createModuleAwaitReactionPromise`；循环 `drainOnePendingJob`，空则 `runOneModuleAwaitHostEvent`。无进展抛 `throwModuleHostStall`。rejected 时 `markHandled`。
- **所有权 / 错误 / 调用**：后续 job 留在队列直到模块下次挂起或完成。

### `runOneModuleAwaitHostEvent` (`src/exec/eval_entry.zig:465`)

- **签名**：`fn runOneModuleAwaitHostEvent( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, ) !bool`。
- **作用**：job 空时推进一个宿主事件。
- **实现**：signal → rw → timer → atomics waiter。任一 true 即进展。
- **所有权 / 错误 / 调用**：无事件返回 false，上层 stall。

### `parserMode` (`src/exec/eval_entry.zig:476`)

- **签名**：`fn parserMode(mode: core.context.EvalMode) parser.Mode`。
- **作用**：把 context eval 模式映到 parser。
- **实现**：script/module/eval_direct/eval_indirect 一一对应。
- **所有权 / 错误 / 调用**：`prepareRootFunction`。

### `parserSourceKind` (`src/exec/eval_entry.zig:485`)

- **签名**：`fn parserSourceKind(kind: core.context.EvalSourceKind) parser.SourceKind`。
- **作用**：auto/javascript/typescript 映射。
- **实现**：穷尽 switch。TS 只擦除。
- **所有权 / 错误 / 调用**：纯枚举映射：不分配、无 error set、不触碰 GC。树内唯一调用方是 `prepareRootFunction` 填 `parser.compile` 选项处（`src/exec/eval_entry.zig:101`）。

---

## `eval_ops.zig`

### `appendEvalClosureSeed` (`src/exec/eval_ops.zig:37`)

- **签名**：`fn appendEvalClosureSeed( rt: *core.JSRuntime, seeds: *std.ArrayList(parser.EvalClosureSeed), atom_id: core.Atom, closure_type: bytecode.function_bytecode.ClosureType, var_idx: u16, is_lexical: bool, is_const: bool, var_kind: bytecode.function_bytecode.VarKind, ) !void`。
- **作用**：向直接 eval 种子追加一行可见绑定。
- **实现**：`null_atom` 跳过。同名绑定是不同身份，shadowing 靠 lookup 先匹配（对齐 qjs `add_closure_variables`）。
- **所有权 / 错误 / 调用**：allocator 追加。

### `directEvalVarIsInParameterScope` (`src/exec/eval_ops.zig:61`)

- **签名**：`fn directEvalVarIsInParameterScope(vd: bytecode.function_bytecode.BytecodeVarDef) bool`。
- **作用**：参数作用域 eval 只收伪参数。
- **实现**：home_object / this_active_func / new_target / this_ / arg_var_object / function_name。
- **所有权 / 错误 / 调用**：纯 atom id 比较，不分配、不抛。唯一调用方 `createDirectEvalClosureSeed` 的 argument-scope 分支（`src/exec/eval_ops.zig:122`），用来把参数初始化器里的 eval 可见集裁到 QuickJS 的伪参数绑定。

### `createDirectEvalClosureSeed` (`src/exec/eval_ops.zig:75`)

- **签名**：`fn createDirectEvalClosureSeed( rt: *core.JSRuntime, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, eval_scope_head: i32, ) !DirectEvalClosureSeed`。
- **作用**：按 `scope_next` 链复制调用者可见绑定，作 parser `eval_closure_seed`。
- **实现**：无 caller 返回空。从 `eval_scope_head` 走 `has_scope` 行。链尾 `-1` 或 `arg_scope_end`。非参数作用域再加 args + 无 scope 的 locals（跳过 `<ret>`）。参数作用域只加伪参数。闭包表：省略 global 族，转发 local/arg/ref/module_*。拷到 runtime alloc。
- **所有权 / 错误 / 调用**：调用方 `free` `values`。环或越界 `InvalidBytecode`。

### `directEvalOuterVarRefView` (`src/exec/eval_ops.zig:161`)

- **签名**：`fn directEvalOuterVarRefView( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, idx: usize, ) !*core.VarRef`。
- **作用**：直接 eval 共享外层 var_ref 槽，不包只读包装细胞。
- **实现**：只返回 `frame.var_refs[idx]`。只读语义在 eval 字节码 ClosureVar + `execPutVarRef`，避免同一绑定两个身份（模块 import 直接别名导出细胞）。
- **所有权 / 错误 / 调用**：不 dup。越界 `InvalidBytecode`。

### `ownedCellFromValue` (`src/exec/eval_ops.zig:172`)

- **签名**：`fn ownedCellFromValue(_: *core.JSRuntime, owned: core.JSValue) !*core.VarRef`。
- **作用**：JSValue → VarRef。
- **实现**：`VarRef.fromValue` 失败 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：假定 `owned` 已是细胞值。

### `directEvalSeedFrameVarRef` (`src/exec/eval_ops.zig:178`)

- **签名**：`fn directEvalSeedFrameVarRef( ctx: *core.JSContext, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, eval_global_var_bindings: bool, cv: bytecode.function_bytecode.BytecodeClosureVar, ) !*core.VarRef`。
- **作用**：按种子行从调用者帧取细胞。
- **实现**：`.local`：无 scope 且全局词法已有同名且可见 local 计数为 1 且 `eval_global_var_bindings` 时改走 `selectOrdinaryGlobalClosureCell`；否则 `captureLocal`。`.arg`：`captureArg`。`.ref`：`directEvalOuterVarRefView`。global/module 族在种子里不该出现 → `InvalidBytecode`。
- **所有权 / 错误 / 调用**：`resolveDirectEvalClosureCell`。

### `resolveDirectEvalClosureCell` (`src/exec/eval_ops.zig:228`)

- **签名**：`fn resolveDirectEvalClosureCell( opaque_context: ?*anyopaque, ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, index: usize, cv: bytecode.function_bytecode.BytecodeClosureVar, ) HostError!*core.VarRef`。
- **作用**：根函数对象 custom resolver。
- **实现**：global 族走 `createRootGlobalClosureCell`；其余 `directEvalSeedFrameVarRef`。
- **所有权 / 错误 / 调用**：`directEval` 把 context 指针传给 `createRootBytecodeFunctionObject`。

### `execDirectEval` (`src/exec/eval_ops.zig:260`)

- **签名**：`pub fn execDirectEval( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, argc: u16, output: ?*std.Io.Writer, global: *core.Object, eval_scope_head: i32, caller_eval_global_var_bindings: bool, allow_tail_inline: bool, ) !ExecEvalResult`。
- **作用**：`OP_eval`：直接 eval 或普通调用。
- **实现**：`allow_tail_inline` 且下一 opcode 是 `return` 且 callee 不是 `%eval%`：`resolveInlineTarget` 成功则返回 `tail_inline`（12.3.4.1 step 9 tailCall）。否则弹 argc+func，root 它们。intrinsic eval → `directEval`；否则 `callValueOrBytecodeRootPreRootedInternal`（this=undefined）。错误经 `handleCatchableRuntimeError` 可变 `continue_loop`。
- **所有权 / 错误 / 调用**：args 堆分配，`defer free`。结果 `stack.push`。

### `isContextIntrinsicEval` (`src/exec/eval_ops.zig:334`)

- **签名**：`pub fn isContextIntrinsicEval(ctx: *core.JSContext, func: core.JSValue) bool`。
- **作用**：识别 Realm 的 `%eval%`。
- **实现**：object 且 `func.same(ctx.eval_function)`。
- **所有权 / 错误 / 调用**：直接 vs 间接的分界。

### `execApplyEval` (`src/exec/eval_ops.zig:338`)

- **签名**：`pub fn execApplyEval( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, global: *core.Object, eval_scope_head: i32, caller_eval_global_var_bindings: bool, ) !ExecEvalResult`。
- **作用**：`eval.apply` 形：从数组取 argv。
- **实现**：弹 arg_array 与 func；`argsFromArray`；intrinsic → `directEval` 否则 `callValueOrBytecodeRoot`。
- **所有权 / 错误 / 调用**：`freeArgs` + `ValueSliceRoot`。无尾调用臂。

### `directEval` (`src/exec/eval_ops.zig:385`)

- **签名**：`pub fn directEval( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, eval_scope_head: i32, caller_eval_global_var_bindings: bool, ) !core.JSValue`。
- **作用**：ECMA 直接 eval：共享调用者词法环境。
- **实现**：无参 → undefined；非 string 原样返回。UTF-8 源。从 caller 取 strict、`EntryContract`（new.target/super/arguments）。`createDirectEvalClosureSeed`。`parser.compile(.eval_direct, filename="<eval>", eval_in_parameter_initializer=is_arg_scope)`。严格编译结果关掉 `eval_global_var_bindings`。`this`=`directEvalThisValue`；允许则 `directEvalNewTargetValue`。custom resolver 建根函数，`runWithCallEnv`（`is_eval_code=true`，`direct_eval_vars_reach_global` 跟 sloppy 全局 var 绑定走）。
- **所有权 / 错误 / 调用**：种子与 nested_stack 本地释放。语法错误 `throwParseSyntaxError`。

### `directEvalThisValue` (`src/exec/eval_ops.zig:496`)

- **签名**：`pub fn directEvalThisValue( ctx: *core.JSContext, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：直接 eval 的 `this`。
- **实现**：无帧 → undefined。捕获的 `this_` 闭包优先。派生类构造器读 local `this_`（可能仍 TDZ）。否则 `materializeFrameThisBinding`。
- **所有权 / 错误 / 调用**：派生类缺 `this_` 槽 `InvalidBytecode`。

### `capturedSpecialValue` (`src/exec/eval_ops.zig:516`)

- **签名**：`fn capturedSpecialValue( caller_function: ?*const bytecode.FunctionBytecode, caller_frame: *frame_mod.Frame, name: core.Atom, ) ?core.JSValue`。
- **作用**：从闭包表取 `this_` / `new_target`。
- **实现**：按 `var_name` 扫 `closureVar`，读 `var_refs[index].varRefValue()`。
- **所有权 / 错误 / 调用**：借用细胞值。

### `directEvalNewTargetValue` (`src/exec/eval_ops.zig:530`)

- **签名**：`fn directEvalNewTargetValue( caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) core.JSValue`。
- **作用**：直接 eval 的 `new.target`。
- **实现**：捕获优先，否则 `frame.newTargetValue()`；无帧 undefined。
- **所有权 / 错误 / 调用**：返回的是借用值——要么是 caller 帧 var_ref 里的 `new.target`（`capturedSpecialValue`），要么是 `frame.newTargetValue()`；不 retain、不建根，由调用方 `directEval` 在同一帧存活期内立刻交给 `runWithCallEnv`（`src/exec/eval_ops.zig:448`，且只在 `eval_allows_new_target` 时调用）。无 error set。

### `directEvalVisibleLocalNameCount` (`src/exec/eval_ops.zig:538`)

- **签名**：`pub fn directEvalVisibleLocalNameCount(rt: *core.JSRuntime, vardefs: []const bytecode.function_bytecode.BytecodeVarDef, atom_id: core.Atom) usize`。
- **作用**：统计同名可见 local，避免把 shadowed 的 local 误绑到全局词法细胞。
- **实现**：`atomIdOrNameEql` 计数。
- **所有权 / 错误 / 调用**：`directEvalSeedFrameVarRef` 的 local 臂。

## 覆盖核对

- 清单：`eval_entry.zig` 11 + `eval_ops.zig` 15，全部有标题。
- 未覆盖: 无
