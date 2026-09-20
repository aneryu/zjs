# 13 — `call_runtime.zig`（三）：词法、间接 eval、generator、instanceof

全局 `var`/`let` 细胞、间接 eval、generator 协议、属性定义、`in`/`instanceof`。

## 类型

- `ActiveRootValueProbe`：测试里中途 cycle-removal。
- `GeneratorValueDone`：for-of 快路径的 `(value, done)`，不造 iterator-result 对象。
- `GeneratorYieldStarReturnStep` / `ThrowStep`：`yield_result` 或 `complete`。
- `SetFailureError`：无 setter / 不兼容 / 不可扩展 / 只读 / TypeError。
- `IntegrityLevel`：sealed/frozen；`object_builtin_ops` 的 seal/freeze 与 TestIntegrityLevel 从这里 import。
- `PendingDescriptorRoots`：`definePropertiesOnTarget` 暂存列表的精确根。
- `RegExpCapture`：本文件声明的捕获形状（`start`/`len`/`undefined`/`name`），`string_ops` import 使用；正则引擎本身不在此文件。

---

### `assertThrows` (`src/exec/call_runtime.zig:2668`)

- **签名**：`pub fn assertThrows( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：测试 `assert.throws(TypeError, fn)`。
- **实现**：args<2 TypeError。回调抛 pending 且消息匹配构造器、或 Zig error 名匹配 → undefined；否则 JSException（含未抛）。
- **所有权 / 错误 / 调用**：名字慢路 `"throws"`。

### `callAssertThrowsCallback` (`src/exec/call_runtime.zig:2696`)

- **签名**：`fn callAssertThrowsCallback( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, callback: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：零参调回调。
- **实现**：`callValueOrBytecodeRoot` this=undefined。
- **所有权 / 错误 / 调用**：纯转发到 `callValueOrBytecodeRoot`（建一次执行根），自身不分配、不建根。error set 推断自被调方：回调抛出的 JS 异常以 `error.JSException` + `ctx` 上的 pending 值形式返回。唯一调用方是 `assertThrows` 宿主内建（`call_runtime.zig:2685`），它正是要靠这个错误判断「有没有抛」。

### `collectIteratorValues` (`src/exec/call_runtime.zig:2707`)

- **签名**：`pub fn collectIteratorValues( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：耗尽 iterator 成 Array。
- **实现**：`Get next`，不可调用 `TypeError`；每步失败都 `iteratorCloseValue` 再传错；`done` 真退出并 `setArrayLength`。
- **所有权 / 错误 / 调用**：`array_ops`。

### `getIteratorMethod` (`src/exec/call_runtime.zig:2750`)

- **签名**：`pub fn getIteratorMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source_value: core.JSValue, ) !core.JSValue`。
- **作用**：`Get(src, @@iterator)`。
- **实现**：comptime `Symbol.iterator` atom。
- **所有权 / 错误 / 调用**：spread / appendIteratorValues。

### `cacheIteratorNextMethod` (`src/exec/call_runtime.zig:2760`)

- **签名**：`pub fn cacheIteratorNextMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：GetIterator 捕获的 `next` 存进 iterator。
- **实现**：不可调用 TypeError。
- **所有权 / 错误 / 调用**：把取到的 `next` 方法写进迭代器对象的 `cachedIteratorNextSlot`（`setOptionalValueSlot` 负责屏障与槽所有权），之后这份引用由对象持有。`next` 不可调用 → `error.TypeError`；`getValueProperty` 可能触发 proxy trap 并抛。唯一调用方 `src/exec/iterator_ops.zig:3113`。

### `appendIteratorValues` (`src/exec/call_runtime.zig:2774`)

- **签名**：`pub fn appendIteratorValues( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, source_value: core.JSValue, start_index: i32, ) !i32`。
- **作用**：把可迭代追加到 target，返回下一 index。
- **实现**：generator 直接当 iterator；否则 GetIterator。`iteratorStepValue` 循环 `defineDataProperty`。
- **所有权 / 错误 / 调用**：不可迭代 TypeError 消息。

### `appendSpreadValuesEnumerate` (`src/exec/call_runtime.zig:2822`)

- **签名**：`pub fn appendSpreadValuesEnumerate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, source_value: core.JSValue, start_index: i32, ) !i32`。
- **作用**：`[...src]` / `f(...src)`，忠于 `js_append_enumerate`（quickjs.c:16814）。
- **实现**：总是 GetIterator。快路径仅当：默认 Array Iterator、kind=value、`next` 是 builtin `array_iterator_next`、目标无洞 `length==count`。否则 `iteratorStepWithNext`。读的是 iterator 当前 target（可部分消费）。dense 目标一次 `reserveDenseArrayElements`。
- **所有权 / 错误 / 调用**：六值 root。旧快路径只看 `flags.is_array`，会忽略用户 `@@iterator`。

### `isCallableValue` (`src/exec/call_runtime.zig:2922`)

- **签名**：`pub fn isCallableValue(value: core.JSValue) bool`。
- **作用**：FB 或函数 class 或 callable proxy。
- **实现**：`isFunctionLikeClass` / `proxyTargetIsCallableObject`。
- **所有权 / 错误 / 调用**：全 exec。

### `isIteratorIdentityFunction` (`src/exec/call_runtime.zig:2929`)

- **签名**：`pub fn isIteratorIdentityFunction(rt: *core.JSRuntime, function_object: *core.Object) bool`。
- **作用**：`[Symbol.iterator]` 是否返回 this。
- **实现**：对象标志；忽略 rt。
- **所有权 / 错误 / 调用**：名字慢路。

### `globalLexicalEnv` (`src/exec/call_runtime.zig:2934`)

- **签名**：`pub fn globalLexicalEnv(ctx: *core.JSContext) !*core.Object`。
- **作用**：`ctx.lexicals` 或 global 上的词法对象，缺则新建。
- **实现**：create object class。
- **所有权 / 错误 / 调用**：挂在 ctx。

### `existingGlobalLexicalEnv` (`src/exec/call_runtime.zig:2947`)

- **签名**：`pub fn existingGlobalLexicalEnv(ctx: *core.JSContext) ?*core.Object`。
- **作用**：不创建。
- **实现**：ctx 或 ctx.global 的 lexicals。
- **所有权 / 错误 / 调用**：只查不建：返回借用的 `*Object`（由 `ctx.lexicals` 或全局对象持有），不分配、无 error set。调用方 `src/exec/vm_property_ref.zig:196`、本文件 `globalLexicalCell`（`2977`）与 `setGlobalLexicalValueForFastPathOwned`（`3304`）。

### `existingGlobalLexicalEnvForGlobal` (`src/exec/call_runtime.zig:2953`)

- **签名**：`pub fn existingGlobalLexicalEnvForGlobal(ctx: *core.JSContext, global: *core.Object) ?*core.Object`。
- **作用**：间接 eval 可能针对非 ctx.global 的 global。
- **实现**：ctx.lexicals → global.globalLexicals → 若 ctx.global 不同再试它。
- **所有权 / 错误 / 调用**：同上，只读借用、不分配、不抛。调用方 4 处都在本文件：`globalLexicalHasForGlobal`（`2968`）、`selectOrdinaryGlobalClosureCell`（`2998`）、`globalLexicalValueForGlobal`（`3249`）、`setGlobalLexicalValueForGlobal`（`3291`）。

### `globalLexicalHasForGlobal` (`src/exec/call_runtime.zig:2962`)

- **签名**：`pub fn globalLexicalHasForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) bool`。
- **作用**：词法环境是否有该名。
- **实现**：`hasOwnProperty`。
- **所有权 / 错误 / 调用**：直接 eval 种子。

### `globalLexicalCell` (`src/exec/call_runtime.zig:2971`)

- **签名**：`pub fn globalLexicalCell(ctx: *core.JSContext, atom_id: core.Atom) ?core.JSValue`。
- **作用**：词法 VARREF 细胞的 owned ref。
- **实现**：非细胞槽 null（调用方走 data 属性）。
- **所有权 / 错误 / 调用**：调用方拥有返回 ref。

### `selectOrdinaryGlobalClosureCell` (`src/exec/call_runtime.zig:2988`)

- **签名**：`pub fn selectOrdinaryGlobalClosureCell( ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, ) !core.JSValue`。
- **作用**：qjs `js_closure_global_var`：词法 VARREF → 物化 AUTOINIT → 全局 VARREF → 停放的 uninitialized 细胞。
- **实现**：不调 getter。返回 owned 细胞 ref。消费侧 ClosureVar 标志不改 owner 细胞。
- **所有权 / 错误 / 调用**：根/嵌套/直接 eval 闭包建造共用。

### `globalUninitializedVarsEnv` (`src/exec/call_runtime.zig:3020`)

- **签名**：`fn globalUninitializedVarsEnv(ctx: *core.JSContext, global: *core.Object) !*core.Object`。
- **作用**：qjs `u.global_object.uninitialized_vars` 侧表。
- **实现**：无则 create + `setGlobalUninitializedVars`。
- **所有权 / 错误 / 调用**：缺失时新建侧表对象并用 `setGlobalUninitializedVars` 挂到全局对象上——所有权立刻转给全局对象（它负责后续 trace/回收），返回的是借用指针。error set 为分配错误。唯一调用方 `globalObjectGetUninitializedVar`（`call_runtime.zig:3039`）。

### `globalObjectGetUninitializedVar` (`src/exec/call_runtime.zig:3032`)

- **签名**：`pub fn globalObjectGetUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) !core.JSValue`。
- **作用**：共享 UNINITIALIZED 细胞，缺则建并归档（quickjs.c:17069）。
- **实现**：C_W_E VARREF。`appendPreparedPropertyEntry` 两端都消费 cell。
- **所有权 / 错误 / 调用**：调用方拥有返回 ref；表槽另有一份。

### `globalObjectFindUninitializedVar` (`src/exec/call_runtime.zig:3051`)

- **签名**：`pub fn globalObjectFindUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_lexical: bool) ?core.JSValue`。
- **作用**：声明时取出停放细胞，让更早捕获别名新绑定（17098）。
- **实现**：从侧表 delete；非词法把值重置 undefined。
- **所有权 / 错误 / 调用**：无细胞 null。

### `ensureGlobalObjectVarRefCell` (`src/exec/call_runtime.zig:3069`)

- **签名**：`pub fn ensureGlobalObjectVarRefCell( ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, configurable: bool, is_function: bool, ) !?core.JSValue`。
- **作用**：顶层 `var`/function 的 JS_PROP_VARREF。可配置 accessor 仅函数声明才转换（`js_closure_define_global_var`）。
- **实现**：AUTOINIT 物化循环。已有 VARREF 更新 flags。不可转换 accessor → null。否则 get/find uninitialized 再 `replaceOwnPropertyWithVarRefCell` 或 append。
- **所有权 / 错误 / 调用**：返回的是 VarRef cell 的一份 owned ref（`cell.valueRef()`），调用方负责其后续归属。两条路径的失败语义是刻意设计的：`appendPreparedPropertyEntry` 在成功与失败两路都会消费 cell 槽，所以调用方不得再加 errdefer 释放；把侧表里那份 park 的引用留到 `replaceOwnPropertyWithVarRefCell` 成功之后才删，使 OOM 回滚自动成立。AUTOINIT 物化失败 → `error.OutOfMemory`，侧表状态不一致 → `error.InvalidBytecode`；不可转换的 accessor 返回 `null` 让调用方走旧路径。调用方 `call_runtime.zig:3152`、`src/exec/object_ops.zig:383`。

### `ensureGlobalLexicalCell` (`src/exec/call_runtime.zig:3135`)

- **签名**：`pub fn ensureGlobalLexicalCell(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_const: bool) !core.JSValue`。
- **作用**：顶层 let/const 的 ctx.lexicals VARREF（quickjs.c:17134）。细胞初值 UNINITIALIZED（TDZ）。
- **实现**：若全局已有同名 VARREF：新细胞拿走旧值，旧细胞变词法（值 UNINITIALIZED）——「if there is a corresponding global variable, reuse」（17148）。generationalBarrier（TGC S0 L3：eval `var x` 后下一脚本 `let x`）。失败回滚。否则停放细胞或新建。
- **所有权 / 错误 / 调用**：append 消费 transferred ref。

### `globalLexicalValueForGlobal` (`src/exec/call_runtime.zig:3204`)

- **签名**：`pub fn globalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) ?core.JSValue`。
- **作用**：读词法绑定值。
- **实现**：data 或 VARREF 细胞值。
- **所有权 / 错误 / 调用**：`lookupFrameVarRef` 的全局哨兵。

### `defineGlobalLexicalValue` (`src/exec/call_runtime.zig:3212`)

- **签名**：`pub fn defineGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue, is_const: bool) !void`。
- **作用**：无则 assuming-new 数据属性。
- **实现**：已存在不覆盖。
- **所有权 / 错误 / 调用**：`globalLexicalEnv` 可能新建 lexicals 环境（挂在 `ctx` 上，由 ctx 持有）；`value` 存进属性表后由环境对象持有，函数自身不建根。已存在同名绑定则整条是 no-op。error set 为分配错误。唯一调用方 `src/exec/vm_property_globals.zig:508`（给未初始化的全局词法绑定填 uninitialized 哨兵）。

### `defineGlobalDeclLexicalCell` (`src/exec/call_runtime.zig:3225`)

- **签名**：`pub fn defineGlobalDeclLexicalCell( ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ref_idx: u16, atom_id: core.Atom, is_const: bool, ) !bool`。
- **作用**：PASS2 词法 GLOBAL_DECL：建细胞并 rebound 槽。
- **实现**：非词法/名字不符 false。
- **所有权 / 错误 / 调用**：`ensureGlobalLexicalCell` 交回一份 owned cell ref，紧接着 `slot_ops.storeVarRefSlot` 把它存进帧的 var_ref 槽（帧接手所有权并负责 trace）；`ensureVarRefsCapacity` 可能扩容帧的 var_refs 数组。返回 `false`（槽不是词法 GLOBAL_DECL 或名字不符）时没有任何副作用，调用方 `src/exec/vm_property_globals.zig:507` 改走非 GLOBAL_DECL 回退。error set 为分配错误。

### `setGlobalLexicalValueForGlobal` (`src/exec/call_runtime.zig:3246`)

- **签名**：`pub fn setGlobalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool`。
- **作用**：写词法：先 TDZ 初始化，再 writable data，再 setProperty。
- **实现**：无绑定 false。只读 TypeError。
- **所有权 / 错误 / 调用**：写入的 `value` 被属性槽/VarRef cell 接管（`initializeGlobalLexicalValue` 内含 generational barrier），函数不建根。`setProperty` 的 `IncompatibleDescriptor`/`NotExtensible`/`ReadOnly` 在这里统一翻成 `error.TypeError`（即 const 赋值的 TypeError），其余错误原样上抛；没有该绑定时返回 `false` 而不是报错。调用方 `src/exec/vm_property_globals.zig:310`、`545`。

### `setGlobalLexicalValueForFastPathOwned` (`src/exec/call_runtime.zig:3259`)

- **签名**：`pub fn setGlobalLexicalValueForFastPathOwned(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool`。
- **作用**：快路径：按 index 拥有写。
- **实现**：`setOwnDataPropertyAtForLexicalSyncOwned`。
- **所有权 / 错误 / 调用**：名字里的 Owned 指调用方交出 `value` 的所有权：`setOwnDataPropertyAtForLexicalSyncOwned` 直接按 index 覆写槽并负责屏障。没有 lexicals 环境或找不到绑定时返回 `false`（调用方 `src/exec/vm_property_globals.zig:301`、`538` 退回慢路径）。error set 来自被调的槽写入。

### `initializeGlobalLexicalValue` (`src/exec/call_runtime.zig:3265`)

- **签名**：`pub fn initializeGlobalLexicalValue(rt: *core.JSRuntime, env: *core.Object, atom_id: core.Atom, value: core.JSValue) bool`。
- **作用**：TDZ 槽 UNINITIALIZED → value。已初始化 false。
- **实现**：data 与 var_ref；old-to-young barrier。
- **所有权 / 错误 / 调用**：只处理 TDZ 的 UNINITIALIZED 槽：data 槽直接覆写并显式补 `rt.gc.generationalBarrier(env, next)`（长寿环境对象指向新值的 old-to-young 边），var_ref 槽走 `cell.setVarRefValue`（屏障在其内部）。不分配、不抛（返回 `bool`）。唯一调用方 `setGlobalLexicalValueForGlobal`（`call_runtime.zig:3294`）。

### `varDefIsEvalHoistedVar` (`src/exec/call_runtime.zig:3292`)

- **签名**：`fn varDefIsEvalHoistedVar(vd: bytecode.function_bytecode.BytecodeVarDef) bool`。
- **作用**：直接 eval 提升的 var/function。
- **实现**：无 scope、非词法、kind normal/function_decl/new_function_decl。
- **所有权 / 错误 / 调用**：纯标志位判定，不分配、不抛。唯一调用方是本文件直接 eval 的 var 提升循环（`call_runtime.zig:3164`）。

### `indirectEval` (`src/exec/call_runtime.zig:3299`)

- **签名**：`pub fn indirectEval( ctx: *core.JSContext, output: ?*std.Io.Writer, eval_global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：间接 eval：`eval` 当值调用。this=全局；sloppy `var` 进全局变量环境。
- **实现**：无参 undefined；非 string 原样返回。若 eval_global≠ctx.global 临时换 lexicals。compile `.eval_indirect` filename `"<eval>"`。根函数 `.root_global`。`eval_global_var_bindings` / `direct_eval_vars_reach_global` = !strict。`is_eval_code=true`。restore lexicals 时 root 完成值。
- **所有权 / 错误 / 调用**：名字 `"eval"` 与 `evalGlobalScriptSource` 近亲。不捕获调用者闭包。

### `isSimpleIdentifierName` (`src/exec/call_runtime.zig:3381`)

- **签名**：`pub fn isSimpleIdentifierName(name: []const u8) bool`。
- **作用**：ASCII IdentifierStart + Part。
- **实现**：空 false。
- **所有权 / 错误 / 调用**：native toString 名过滤。

### `ActiveRootValueProbe.trigger` (`src/exec/call_runtime.zig:3443`)

- **签名**：`pub fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：操作中途强制收集，证明在飞值已根。
- **实现**：engine_active cycle-removal。
- **所有权 / 错误 / 调用**：测试。

### `freeArgs` (`src/exec/call_runtime.zig:3411`)

- **签名**：`pub fn freeArgs(rt: *core.JSRuntime, args: []core.JSValue) void`。
- **作用**：释放 argv 切片（不 free 每个 JSValue）。
- **实现**：len≠0 则 `memory.free`。
- **所有权 / 错误 / 调用**：bound/apply。

### `Probe.trigger` (`src/exec/call_runtime.zig:3443`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：`argsFromArrayLike` 前缀根测试。
- **实现**：同其它 Trigger。
- **所有权 / 错误 / 调用**：测试局部 struct 的方法，不分配；安装成 `rt.memory.trigger_gc_fn` 后由分配路径经函数指针回调，没有直接调用方。进入时先摘 hook 并 `defer` 还原以防重入；`tryRunObjectCycleRemovalWithValueRoots` 的错误被 `catch {}` 吞掉，探针只看符号 atom 是否还活着。

### `callFunctionBytecodeConstruct` (`src/exec/call_runtime.zig:3486`)

- **签名**：`pub fn callFunctionBytecodeConstruct( ctx: *core.JSContext, func: core.JSValue, current_function_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, new_target_value: core.JSValue, copy_argv: bool, ) !core.JSValue`。
- **作用**：构造器体：CallConstructorInternal poll 之后再付一次 JS_CallInternal poll（调用者 Realm），然后才切函数 Realm。
- **实现**：`DerivedThisUninitialized` 在 **调用者** global 物化（qjs OP_get_loc_checkthis 在 caller_ctx，18717）。
- **所有权 / 错误 / 调用**：`copy_argv` 传入 After。

### `callFunctionBytecodeModeState` (`src/exec/call_runtime.zig:3516`)

- **签名**：`pub fn callFunctionBytecodeModeState( ctx: *core.JSContext, func: core.JSValue, current_function_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, defer_generators: bool, generator_state: ?*core.Object, resume_value: ?core.JSValue, stop_before_pc: ?usize, new_target_value: core.JSValue, ) HostError!core.JSValue`。
- **作用**：跑/恢复字节码，含 generator 状态。
- **实现**：有 generator_state：`enterCallDepth(..., 0)` 后 poll（`async_func_resume` alloca_size=0）。否则只 poll。`call_depth_precharged` 对 generator 为 true。
- **所有权 / 错误 / 调用**：next/return/throw。

### `callFunctionBytecodeModeStateAfterInterruptPoll` (`src/exec/call_runtime.zig:3577`)

- **签名**：`fn callFunctionBytecodeModeStateAfterInterruptPoll( ctx: *core.JSContext, func: core.JSValue, current_function_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, defer_generators: bool, generator_state: ?*core.Object, resume_value: ?core.JSValue, stop_before_pc: ?usize, new_target_value: core.JSValue, copy_argv: bool, call_depth_precharged: bool, ) HostError!core.JSValue`。
- **作用**：真正进 VM：深度、Realm、generator 对象、async start、arena 帧。
- **实现**：generator/async_generator 且 `defer_generators` → `createGeneratorObject`（不跑体）。async 无 state → `coerceCallThis` + `asyncFunctionStart`。普通帧从 `vm_stack` carve 操作数窗口；generator/async 驻留堆。`runWithCallEnvAfterInterruptPoll`。async-generator 体把原始挂起值交给 queue 机，此处不包 Promise。
- **所有权 / 错误 / 调用**：arena_mark restore。缺 FB Realm `InvalidBuiltinRegistry`。

### `runGeneratorParameterInit` (`src/exec/call_runtime.zig:3697`)

- **签名**：`pub fn runGeneratorParameterInit( ctx: *core.JSContext, fb: *const bytecode.FunctionBytecode, nested: *const bytecode.FunctionBytecode, prepared_entry_frame: ?*const zjs_vm.PreparedEntryFrame, object: *core.Object, current_function_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, var_refs: []const *core.VarRef, output: ?*std.Io.Writer, call_depth_precharged: bool, call_entry_ctx: *core.JSContext, call_entry_global: *core.Object, ) !core.JSValue`。
- **作用**：generator 参数初始化跑到 `OP_initial_yield`；普通 async 停在 pc 0。
- **实现**：async 或 legacy/空 bytecode：`stop_before_pc=0`。非 async 付 depth(0)+poll。`strict_unresolved_get_var=true`。
- **所有权 / 错误 / 调用**：`createGeneratorObject`。

### `generatorNext` (`src/exec/call_runtime.zig:3763`)

- **签名**：`pub fn generatorNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`.next()`。非 generator 返回 null 让名字链继续。
- **实现**：async_generator → `asyncGeneratorEnqueue` magic 0（EXECUTING 只排队，不 TypeError）。sync：executing TypeError；done → `{value:undefined, done:true}`。`executing` 旗；`callFunctionBytecodeModeState` 失败 complete。yield* 已是 iterator-result 则原样返回。
- **所有权 / 错误 / 调用**：`payload.executing = true` 配 `defer` 复位构成重入保护；恢复执行失败时先 `object.completeGeneratorExecution(ctx.runtime)` 释放挂起帧再把错误上抛。返回的迭代结果对象由 `iterator_ops.createIteratorResult` 新建（owned 交给调用方），yield* 透传臂则把子迭代器给的结果原样转手。非生成器 receiver 返回 `null` 而不是报错；执行中再次 next → `error.TypeError`。调用方 `call_runtime.zig:1184`（内建 `.next`）与 `src/exec/iterator_ops.zig:3191`（intrinsic 分发，`null` 翻成 TypeError）。

### `generatorFunctionBytecodeFromExecution` (`src/exec/call_runtime.zig:3822`)

- **签名**：`inline fn generatorFunctionBytecodeFromExecution(object: *core.Object, execution: *const core.object.GeneratorExecutionState) ?core.JSValue`。
- **作用**：恢复用的 FB 值。
- **实现**：current_function 是 FB 或函数对象的 bytecode；等于 self 则 null。
- **所有权 / 错误 / 调用**：只读借用：返回的是 `execution.current_function` 或函数对象里存的 FB 值，不 retain、不分配、不抛。三个调用方都在本文件（`call_runtime.zig:3834`、`3908`、`4042`），拿不到就各自 `error.TypeError`。

### `generatorHasYieldStarResult` (`src/exec/call_runtime.zig:3830`)

- **签名**：`inline fn generatorHasYieldStarResult(payload: *const core.object.GeneratorPayload) bool`。
- **作用**：是否处于 yield* 转发。
- **实现**：`yield_star_suspended` 或 iterator 槽非 undefined。
- **所有权 / 错误 / 调用**：只读 payload 标志与 `yield_star_iterator` 槽，不分配、不抛。调用方三处，都在本文件的生成器恢复臂（`call_runtime.zig:3857`、`3931`、`4067`），用来决定这一步的结果是否已经是子迭代器给的 iterator-result（不能再包一层）。

### `syncGeneratorStep` (`src/exec/call_runtime.zig:3845`)

- **签名**：`pub fn syncGeneratorStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !?GeneratorValueDone`。
- **作用**：for-of 快路径：不分配 `{value,done}`（qjs `JS_IteratorNext2` quickjs.c:16548）。
- **实现**：仅 sync generator。yield* 结果已是 iterator-result：读 done，!done 才读 value。与 `generatorNext` 平行实现，test262 两边都跑。
- **所有权 / 错误 / 调用**：非 sync generator null。

### `generatorYieldStarSuspended` (`src/exec/call_runtime.zig:3896`)

- **签名**：`pub fn generatorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object) bool`。
- **作用**：读 yield* 挂起旗。
- **实现**：忽略 rt。
- **所有权 / 错误 / 调用**：薄访问器，`rt` 参数被 `_ =` 丢弃（保持与同族 setter 的签名对称），只读对象槽，不分配、不抛。调用方在本文件三处恢复/throw 路径（`call_runtime.zig:3999`、`4023`、`4227`）。

### `setGeneratorYieldStarSuspended` (`src/exec/call_runtime.zig:3901`)

- **签名**：`pub fn setGeneratorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object, value: bool) !void`。
- **作用**：写旗。
- **实现**：slot 赋值，忽略 rt。
- **所有权 / 错误 / 调用**：`vm_gen_async` 进入 yield* 挂起时置 true。

### `generatorResumeCompletionType` (`src/exec/call_runtime.zig:3953`)

- **签名**：`pub fn generatorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object) i32`。
- **作用**：0 next / 1 return / 2 throw。
- **实现**：读槽，忽略 rt。
- **所有权 / 错误 / 调用**：本仓库当前无调用方（读侧都直接走 `object.generatorResumeCompletionType()`）；写侧 setter 才被 `async_generator`/`module_graph`/`eval_entry` 使用。

### `setGeneratorResumeCompletionType` (`src/exec/call_runtime.zig:3958`)

- **签名**：`pub fn setGeneratorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object, value: i32) !void`。
- **作用**：写完成类型。
- **实现**：槽。
- **所有权 / 错误 / 调用**：直接写生成器 payload 里的 i32 槽，`rt` 同样未用；写的是立即数，不需要屏障或建根。error set 虽为 `!void` 但实际不会失败。调用方 8 处：本文件 `resumeGeneratorYieldStarCompletion`（`call_runtime.zig:3981`）、`src/exec/async_generator.zig:302`/`306`/`310`/`314`（normal=0 / throw=2 / return=1 / yield* 转发的完成类型）、`src/exec/promise_ops.zig:2651`、`src/exec/eval_entry.zig:393`、`src/exec/module_graph.zig:1617`（await/模块恢复点标记 normal=0 或 throw=2）。

### `resumeGeneratorYieldStarCompletion` (`src/exec/call_runtime.zig:3910`)

- **签名**：`pub fn resumeGeneratorYieldStarCompletion( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, resume_value: core.JSValue, completion_type: i32, ) !core.JSValue`。
- **作用**：从 yield* 内部挂起用指定完成类型恢复。
- **实现**：设 type、executing、ModeState；done 则 complete。仍 yield* 挂起则原样 result。
- **所有权 / 错误 / 调用**：return/throw 的 suspended 臂。

### `generatorReturn` (`src/exec/call_runtime.zig:3948`)

- **签名**：`pub fn generatorReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`.return(v)`。
- **实现**：async enqueue magic 1。yield* suspended → resume type 1。有 iterator → `generatorYieldStarReturnStep`。已启动则 ModeState type 1。否则 complete 成 `{v, done:true}`。
- **所有权 / 错误 / 调用**：executing TypeError。

### `resumeGeneratorCatchForRuntimeError` (`src/exec/call_runtime.zig:4018`)

- **签名**：`pub fn resumeGeneratorCatchForRuntimeError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, err: anytype, ) !?core.JSValue`。
- **作用**：yield* 步骤抛错且帧有 catch 时，把错误当 throw 完成喂回。
- **实现**：async 或 pc=0 或无 catch_target → null。`runtimeErrorValueForGeneratorCatch`；type 2。
- **所有权 / 错误 / 调用**：return/throw 的 catch。

### `generatorYieldStarReturnStep` (`src/exec/call_runtime.zig:4069`)

- **签名**：`pub fn generatorYieldStarReturnStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, generator: *core.Object, return_arg: core.JSValue, ) !GeneratorYieldStarReturnStep`。
- **作用**：对内层 iterator 调 `return`。
- **实现**：无/undefined return → complete(arg)。不可调用 TypeError。结果 !done → yield_result；done 取 value 并清 iterator。
- **所有权 / 错误 / 调用**：返回的 union 里装的是子迭代器给的值（`result_value` 或其 `value` 属性），按 owned 转交调用方；状态副作用是 `generatorJustYieldedSlot` 与 `clearGeneratorYieldStarIterator`。error set：无 yield* 迭代器或 `return` 不可调用 → `error.TypeError`，属性读/调用的异常上抛。唯一调用方是本文件的 `generatorReturn` 臂（`call_runtime.zig:4027`），它 `catch` 后负责清掉 yield* 状态。

### `generatorYieldStarThrowStep` (`src/exec/call_runtime.zig:4104`)

- **签名**：`pub fn generatorYieldStarThrowStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, generator: *core.Object, thrown: core.JSValue, ) !GeneratorYieldStarThrowStep`。
- **作用**：内层 `throw`。
- **实现**：无 throw 方法：`generatorYieldStarCloseForMissingThrow` 后 TypeError。!done yield_result；done complete(value)。
- **所有权 / 错误 / 调用**：与 return 臂同构；差别在缺 `throw` 方法时先 `generatorYieldStarCloseForMissingThrow` 关闭子迭代器、再 `clearGeneratorYieldStarIterator`，然后才抛 `error.TypeError`（规范要求先 IteratorClose）。结果值 owned 转交。唯一调用方 `call_runtime.zig:4232`。

### `generatorYieldStarCloseForMissingThrow` (`src/exec/call_runtime.zig:4140`)

- **签名**：`pub fn generatorYieldStarCloseForMissingThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：缺 throw 时仍调 return 关闭。
- **实现**：return 结果必须是 object。
- **所有权 / 错误 / 调用**：不分配；`return` 缺失时静默返回，`return` 不可调用或返回非对象 → `error.TypeError`，调用本身的异常上抛（与 `closeIterator` 那种吞错误的收尾不同，这里的失败要盖过原 TypeError 上报）。唯一调用方 `generatorYieldStarThrowStep`（`call_runtime.zig:4172`）。

### `generatorThrow` (`src/exec/call_runtime.zig:4154`)

- **签名**：`pub fn generatorThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`.throw(e)`。
- **实现**：async enqueue magic 2。yield* 步骤失败可 catch 恢复。complete 时把 thrown 挂到 ctx。未启动 complete 后 `throwValue` + JSException。
- **所有权 / 错误 / 调用**：yield* complete 后 pc 跳过 yield_star 再跑体。

### `generatorCatchResumeResultValue` (`src/exec/call_runtime.zig:4248`)

- **签名**：`pub fn generatorCatchResumeResultValue(result: core.JSValue) core.JSValue`。
- **作用**：catch offset 哨兵 → undefined。
- **实现**：`isCatchOffset`。
- **所有权 / 错误 / 调用**：纯值判定，不分配、不抛：catch-offset 哨兵换成 undefined，否则原样返回（借用进借用出）。调用方是本文件两处 throw 恢复点（`call_runtime.zig:4111`、`4295`）。

### `generatorPcAfterYieldStar` (`src/exec/call_runtime.zig:4252`)

- **签名**：`pub fn generatorPcAfterYieldStar(fb: *const bytecode.FunctionBytecode, pc: usize) ?usize`。
- **作用**：yield_star / async_yield_star 下一 pc。
- **实现**：`opcode.sizeOf`。
- **所有权 / 错误 / 调用**：throw 完成内层后。

### `wrapIteratorFromIterator` (`src/exec/call_runtime.zig:4261`)

- **签名**：`pub fn wrapIteratorFromIterator(ctx: *core.JSContext, global: *core.Object, iterator: core.JSValue, next_method: ?core.JSValue) !core.JSValue`。
- **作用**：`Iterator.from` 的 wrap。
- **实现**：`iterator_wrap` class；装 target；显式 next 或拿走 cached next。
- **所有权 / 错误 / 调用**：测试 FB next 根。

### `pollGCSafePoint` (`src/exec/call_runtime.zig:4322`)

- **签名**：`pub fn pollGCSafePoint(ctx: *core.JSContext) !void`。
- **作用**：可选 GC safepoint。
- **实现**：`PayloadMarkFailed` 当 OOM。
- **所有权 / 错误 / 调用**：不分配、不建根；把 `gcSafepoint` 的两个错误都收敛成 `error.OutOfMemory`（`PayloadMarkFailed` 也当 OOM 上报），所以调用方只需处理一种失败。唯一调用方 `src/exec/promise_ops.zig:4110`（微任务循环在每个 job 之间打安全点）。

### `runNextOsTimer` (`src/exec/call_runtime.zig:4329`)

- **签名**：`pub fn runNextOsTimer(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool`。
- **作用**：一个到期定时器。
- **实现**：无 host event loop 返回 false。
- **所有权 / 错误 / 调用**：`promise_ops` 的 job drain、`module_graph` 模块 await、`eval_entry`。

### `runNextOsRwHandler` (`src/exec/call_runtime.zig:4336`)

- **签名**：`pub fn runNextOsRwHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool`。
- **作用**：一个 rw 处理器。
- **实现**：同 timer。
- **所有权 / 错误 / 调用**：与 timer 同三处，且总排在 timer 之前。

### `enqueuePendingMicrotask` (`src/exec/call_runtime.zig:4343`)

- **签名**：`pub fn enqueuePendingMicrotask(ctx: *core.JSContext, callback: core.JSValue) !void`。
- **作用**：`queueMicrotask`。
- **实现**：`enqueuePendingPromiseJob`。
- **所有权 / 错误 / 调用**：`call.zig` 的 `globalQueueMicrotask` 与 `src/event_loop.zig`。

### `throwTypeErrorIntrinsicForGlobal` (`src/exec/call_runtime.zig:4381`)

- **签名**：`pub fn throwTypeErrorIntrinsicForGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue`。
- **作用**：Realm 的 `%ThrowTypeError%`（arguments.callee 等）。
- **实现**：缓存命中返回。否则 length=0、空 name、freeze、装 Function.prototype 上的访问器。
- **所有权 / 错误 / 调用**：标准全局安装。

### `throwTypeErrorIntrinsic` (`src/exec/call_runtime.zig:4402`)

- **签名**：`pub fn throwTypeErrorIntrinsic(ctx: *core.JSContext, global: *core.Object, _: *core.Object) !core.JSValue`。
- **作用**：调用 `%ThrowTypeError%`。
- **实现**：`invalid property access` TypeError + JSException。
- **所有权 / 错误 / 调用**：internal tag。

### `currentFrameFunctionIsStrict` (`src/exec/call_runtime.zig:4408`)

- **签名**：`pub fn currentFrameFunctionIsStrict(frame: *frame_mod.Frame) bool`。
- **作用**：当前函数是否严格（含 runtimeStrict）。
- **实现**：frame.function 或 current_function 上的 FB。
- **所有权 / 错误 / 调用**：只读帧与 FB 标志，不分配、不抛、不 retain（`frame.current_function` 只借用）。调用方是 `arguments` 对象的构造判定 `src/exec/object_ops.zig:2309`、`2311`（非严格 + 简单参数表才做 mapped arguments）。

### `functionBytecodeFromValue` (`src/exec/call_runtime.zig:4420`)

- **签名**：`pub fn functionBytecodeFromValue(value: core.JSValue) ?*const bytecode.FunctionBytecode`。
- **作用**：JSValue → FB（`@fieldParentPtr("header")`）。
- **实现**：无 header null。
- **所有权 / 错误 / 调用**：全 exec。

### `isFunctionLikeClass` (`src/exec/call_runtime.zig:4425`)

- **签名**：`pub fn isFunctionLikeClass(class_id: core.class.ClassId) bool`。
- **作用**：可调用 class 集。
- **实现**：c_function/data/async resume/c_closure/bytecode/bound。
- **所有权 / 错误 / 调用**：`isCallableValue`。

### `throwPrivateBrandTypeError` (`src/exec/call_runtime.zig:4567`)

- **签名**：`pub fn throwPrivateBrandTypeError( ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：私有域不存在。
- **实现**：消息用调用者函数 Realm。`allocPrint`。
- **所有权 / 错误 / 调用**：消息串用 `allocPrint` 从运行时 allocator 临时分配、`defer free`，字符串内容在 `throwTypeErrorMessage` 里被拷进 JS 错误对象。错误对象用**调用方帧所属函数的 Realm global** 构造（拿不到就退回传入 `global`）。函数总是以 `error.JSException` 返回（pending 异常已写进 `ctx`），返回类型里的 `JSValue` 不会真的产生。调用方 `src/exec/object_ops.zig:2686`、`2715`。

### `throwSetFailureTypeError` (`src/exec/call_runtime.zig:4595`)

- **签名**：`pub fn throwSetFailureTypeError(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, reason: SetFailureError) !core.JSValue`。
- **作用**：严格模式赋值失败消息。
- **实现**：无 setter / 不可扩展用静态串；只读带属性名。
- **所有权 / 错误 / 调用**：只读属性名有名字时用 `allocPrint` 拼消息并 `defer free`，其余情况用静态串，不留长期分配。总是返回 `error.JSException`（异常挂在 `ctx` 上）。`reason` 用的是 `SetFailureError` 这个专用 error set，把「哪种 set 失败」映射成不同 TypeError 文案。调用方是 `src/exec/object_ops.zig` 的 15 处 set 失败点（`2900`、`2906`、`2921`–`2933`、`2952`–`2985`、`3660`、`3670`）。

### `setFailureShouldThrow` (`src/exec/call_runtime.zig:4611`)

- **签名**：`pub fn setFailureShouldThrow(caller_function: ?*const bytecode.FunctionBytecode) bool`。
- **作用**：赋值失败是否抛（严格）。
- **实现**：无 caller false。
- **所有权 / 错误 / 调用**：纯读，不分配、不抛；没有 caller_function（宿主发起的 set）时保守返回 `false`，即不抛。调用方 `src/exec/object_ops.zig:2887`、`3653`。

### `functionRuntimeStrict` (`src/exec/call_runtime.zig:4616`)

- **签名**：`pub fn functionRuntimeStrict(function: *const bytecode.FunctionBytecode) bool`。
- **作用**：strict 或 runtimeStrict。
- **实现**：或。
- **所有权 / 错误 / 调用**：纯标志位读（编译期 strict 或运行期 strict），不分配、不抛。调用方 `src/exec/object_ops.zig:2894` 与本文件 `setFailureShouldThrow`（`call_runtime.zig:4678`）。

### `ordinarySetWithReceiver` (`src/exec/call_runtime.zig:4620`)

- **签名**：`pub fn ordinarySetWithReceiver( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_value: core.JSValue, target: *core.Object, receiver_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：OrdinarySet 带 receiver。
- **实现**：proxy → `proxySetValueProperty`。typed array prototype set。`__proto__` setter。自有描述符 `setWithOwnDescriptor`。否则沿原型递归；到顶当可写 data。
- **所有权 / 错误 / 调用**：不分配、不建根：`target_value` 参数直接被 `_ =` 丢弃，原型链递归靠 `prototype.value()` 现取（原型由对象持有）。error set 是精确的 `HostError`；proxy trap、`__proto__` setter、typed-array 写入都可能重入 JS 并抛；失败是否变成 TypeError 由更上层的 `throw_on_set_failure` 决定，这里只返回 `bool`。调用方 `src/exec/object_ops.zig:2899`、`4447`，`src/exec/reflect_ops.zig:480`/`489`（`Reflect.set`），以及本文件的原型链自递归（`4712`）。

### `definePropertiesCall` (`src/exec/call_runtime.zig:4651`)

- **签名**：`pub fn definePropertiesCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Object.defineProperties`。
- **实现**：<2 参 TypeError；非 object 消息。返回 target。
- **所有权 / 错误 / 调用**：不分配；返回的是原样借回的 `args[0]`（`Object.defineProperties` 的返回值就是 target）。`args[0]` 不是对象时不抛 Zig 错误，而是先 `throwTypeErrorMessage` 把异常写进 `ctx` 再以 `error.JSException` 形式从 `try` 返回。唯一调用方 `src/exec/object_builtin_ops.zig:321`（`null` 在那里翻成 `error.TypeError`）。

### `PendingDescriptorRoots.traceRoots` (`src/exec/call_runtime.zig:4679`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：暂存描述符的 atom + value/getter/setter。
- **实现**：扫 list。
- **所有权 / 错误 / 调用**：`value_root_frames_enabled`。

### `PendingDescriptorRoots.provider` (`src/exec/call_runtime.zig:4689`)

- **签名**：`fn provider(self: *PendingDescriptorRoots) core.runtime.RootProvider`。
- **作用**：包装 trace。
- **实现**：context=self。
- **所有权 / 错误 / 调用**：只把 `self` 擦成 `*anyopaque` 和 `traceRoots` 打包成 `RootProvider` 值，不分配、不抛。注意注册与注销必须传**相等的** provider 值，所以 `activate`/`deactivate` 各自重新调用它。调用方是同结构的 `activate`（`call_runtime.zig:4761`）与 `deactivate`（`4768`）。

### `PendingDescriptorRoots.activate` (`src/exec/call_runtime.zig:4693`)

- **签名**：`inline fn activate(self: *PendingDescriptorRoots) !void`。
- **作用**：登记 provider。
- **实现**：默认 rc 编译擦除。
- **所有权 / 错误 / 调用**：向运行时登记根提供者，让 `pending` 列表里的 atom id 与描述符值（value/getter/setter）在后续每次可重入的描述符读取中被 trace——这块堆数组既不在 value-root 帧里也不在保守栈扫描范围内（TGC S3 §2.2 root G）。在默认 `rc` 配置下 `value_root_frames_enabled` 为假，整个函数 comptime 擦除。`registerRootProvider` 失败（OOM）时 `registered` 保持 false，`deactivate` 不会误注销。唯一调用点 `definePropertiesOnTarget`（`call_runtime.zig:4806`）——紧挨着它的 `keys_roots`（`rootAtomList`）负责键快照本身。

### `PendingDescriptorRoots.deactivate` (`src/exec/call_runtime.zig:4699`)

- **签名**：`fn deactivate(self: *PendingDescriptorRoots) void`。
- **作用**：注销。
- **实现**：未登记 no-op。
- **所有权 / 错误 / 调用**：幂等注销（`registered` 为假直接返回），同样在 `rc` 下 comptime 擦除；由 `definePropertiesOnTarget` 的 `defer` 调用（`call_runtime.zig:4807`），保证异常路径也解除登记。不分配、不抛。

### `definePropertiesOnTarget` (`src/exec/call_runtime.zig:4707`)

- **签名**：`pub fn definePropertiesOnTarget( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, properties_arg: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：两阶段：收集 enumerable 描述符再定义（proxy/TA 感知）。
- **实现**：nullish TypeError。非 object ToObject。`objectRestOwnKeys` + atom list root。每 key 读描述符对象。定义失败 Incompatible→TypeError，InvalidLength→RangeError。未 defined false → TypeError。
- **所有权 / 错误 / 调用**：pending 项 `destroy`。

### `callAccessorSetter` (`src/exec/call_runtime.zig:4779`)

- **签名**：`pub fn callAccessorSetter( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：找到 accessor 则调 setter。
- **实现**：无 setter `AccessorWithoutSetter`。K3 `tryNativeAccessorCall`；否则 outlined sync call。非 accessor false。
- **所有权 / 错误 / 调用**：不分配；`desc` 里的 setter 只借用。两条调用路径：K3 原生访问器走 `builtin_dispatch.tryNativeAccessorCall` 的直接终端，否则 `callValueOrBytecodeSyncInternalOutlined`（建同步内部调用），两者的返回值都被丢弃。accessor 无 setter → `error.AccessorWithoutSetter`（由调用方决定是否翻成 TypeError）；找不到属性返回 `false`。调用方 `src/exec/object_ops.zig:1130`、`2955`。

### `inOp` (`src/exec/call_runtime.zig:4804`)

- **签名**：`pub fn inOp( ctx: *core.JSContext, stack: *stack_mod.Stack, output: ?*std.Io.Writer, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`OP_in`。
- **实现**：rhs 非 object `invalid 'in' operand`。proxy 走 `hasValueProperty` 否则 ordinary。
- **所有权 / 错误 / 调用**：压 boolean。

### `instanceofOp` (`src/exec/call_runtime.zig:4826`)

- **签名**：`pub fn instanceofOp( ctx: *core.JSContext, stack: *stack_mod.Stack, output: ?*std.Io.Writer, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`OP_instanceof` 栈壳。
- **实现**：弹 rhs/lhs，`instanceofValue`。
- **所有权 / 错误 / 调用**：从 VM 栈 `pop` 两个操作数（弹出后它们只在本函数栈帧里借用），结果用 `pushOwnedAssumeCapacity` 压回——容量由 opcode 的栈效应保证，不会再分配。error set 推断自 `instanceofValue`（可重入 JS 的 `Symbol.hasInstance` 调用）。唯一调用方 `src/exec/vm_property_field.zig:137`（`OP_instanceof` 冷臂）。

### `instanceofValue` (`src/exec/call_runtime.zig:4843`)

- **签名**：`pub fn instanceofValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, lhs: core.JSValue, rhs: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：`JS_IsInstanceOf`。
- **实现**：rhs 非 object TypeError。取 `@@hasInstance` 再 `instanceofValueWithMethod`。atom 编译期 `Symbol.hasInstance`。
- **所有权 / 错误 / 调用**：操作数由调用方根住。

### `instanceofMethod` (`src/exec/call_runtime.zig:4863`)

- **签名**：`pub fn instanceofMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rhs: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：快探 `@@hasInstance` data。
- **实现**：`probeNamedDataProperty`；需要慢路 `instanceofMethodSlow`。
- **所有权 / 错误 / 调用**：`probeNamedDataProperty` 命中时返回的是属性槽里的借用值（`slot.*`），未命中且不需要慢路径时返回 undefined，否则转 `instanceofMethodSlow`（那里才可能重入 JS 并抛）。自身不分配、不建根。唯一调用方 `instanceofValue`（`call_runtime.zig:4925`）。

### `instanceofMethodSlow` (`src/exec/call_runtime.zig:4878`)

- **签名**：`pub noinline fn instanceofMethodSlow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rhs: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`instanceof` 在 `@@hasInstance` 不是自有 data 时的 outlined Get（寄存器常驻 opcode 壳不内联完整属性走查）。
- **实现**：再取编译期 `Symbol.hasInstance` atom（与快探同一 id）。`getValueProperty` 走可观察 `[[Get]]`（accessor / 原型 / Proxy）。atom intern 失败 `TypeError`（预定义 id 缺失）。
- **所有权 / 错误 / 调用**：`instanceofMethod` 仅在 `needs_slow` 时进入。返回 owned。操作数由调用方根到返回。对齐 qjs `JS_ATOM_Symbol_hasInstance` 后再 `JS_GetProperty`（quickjs.c:8139）。

### `instanceofValueWithMethod` (`src/exec/call_runtime.zig:4890`)

- **签名**：`pub fn instanceofValueWithMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, lhs: core.JSValue, rhs: core.JSValue, has_instance: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：有自定义 hasInstance 则调用；否则 OrdinaryHasInstance 形状（prototype 链，含 GetPrototypeOf）。
- **实现**：方法 nullish 且 rhs 不可调用 → TypeError。lhs 非 object false。prototype 非 object TypeError。
- **所有权 / 错误 / 调用**：自定义方法经 `callValueOrBytecodeRoot(rhs, has_instance, &.{lhs})`。

### `constructorNameEqlLocal` (`src/exec/call_runtime.zig:4927`)

- **签名**：`pub fn constructorNameEqlLocal(rt: *core.JSRuntime, object: *core.Object, expected: []const u8) !bool`。
- **作用**：构造器名是否等于字面。
- **实现**：读名失败 false。
- **所有权 / 错误 / 调用**：call.zig `constructorNameEql` 别名。

### `nativeFunctionNameValueLocal` (`src/exec/call_runtime.zig:4935`)

- **签名**：`pub fn nativeFunctionNameValueLocal(rt: *core.JSRuntime, object: *core.Object) !core.JSValue`。
- **作用**：dispatch atom 或 `name`。
- **实现**：非 string TypeError。
- **所有权 / 错误 / 调用**：返回值可能是 `atoms.toStringValue` 新建的字符串（也可能是 `name` 属性槽里的借用值），不建根，调用方须立即消费。`name` 不是字符串 → `error.TypeError`。调用方 `src/exec/call.zig:2000`（`prefer_dispatch_name` 分支）与本文件 `constructorNameEqlLocal`（`call_runtime.zig:4994`，错误 `catch return false`）。

### `isBlockedByUnscopables` (`src/exec/call_runtime.zig:4948`)

- **签名**：`pub fn isBlockedByUnscopables( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：with 环境 `@@unscopables[key]` 真则跳过。
- **实现**：非 object unscopables false。
- **所有权 / 错误 / 调用**：不分配；两次 `getValueProperty` 都可能触发 proxy trap / getter 并重入 JS，错误原样上抛。缺少 `Symbol.unscopables` 预定义 id 或取到的不是对象时返回 `false`（不抛）。调用方 `src/exec/vm_property_ref.zig:71`、`381`（`with` 作用域的名字解析）。

### `lookupFrameVarRef` (`src/exec/call_runtime.zig:4964`)

- **签名**：`pub fn lookupFrameVarRef(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue`。
- **作用**：按名扫闭包槽。
- **实现**：非词法全局哨兵改读 `globalLexicalValueForGlobal`。deleted eval binding 跳过。非词法 UNINITIALIZED 继续（停放占位）。词法 UNINITIALIZED 可见以便 TDZ。
- **所有权 / 错误 / 调用**：eval/with。

### `closureVarIsNonLexicalGlobalSentinel` (`src/exec/call_runtime.zig:4990`)

- **签名**：`pub fn closureVarIsNonLexicalGlobalSentinel(function: *const bytecode.FunctionBytecode, idx: usize) bool`。
- **作用**：global / global_ref / global_decl 且非词法。
- **实现**：越界 false。
- **所有权 / 错误 / 调用**：纯 ClosureVar 标志判定，越界返回 false，不分配、不抛。调用方 `src/exec/slot_ops.zig:156`、`src/exec/vm_property_locals.zig:257` 与本文件 `lookupFrameVarRef`（`5037`）——三处都靠它区分「真的捕获槽」与「全局占位哨兵」。

### `atomIdOrNameEql` (`src/exec/call_runtime.zig:5000`)

- **签名**：`pub fn atomIdOrNameEql(rt: *core.JSRuntime, left: core.Atom, right: core.Atom) bool`。
- **作用**：id 或 intern 名相等。
- **实现**：先 `==`。
- **所有权 / 错误 / 调用**：eval 种子、词法。

### `functionNameValueFromAtom` (`src/exec/call_runtime.zig:5007`)

- **签名**：`pub fn functionNameValueFromAtom(rt: *core.JSRuntime, atom_id: core.Atom, prefix: ?[]const u8) !core.JSValue`。
- **作用**：函数名字符串；无前缀非公有符号走 atom 缓存串（qjs `JS_AtomToString`）。
- **实现**：前缀空格；tagged int 十进制；公有符号 `[description]`。
- **所有权 / 错误 / 调用**：闭包 name。

### `mappedArgumentsValue` (`src/exec/call_runtime.zig:5042`)

- **签名**：`pub fn mappedArgumentsValue(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?core.JSValue`。
- **作用**：mapped arguments 下标 → 细胞值。
- **实现**：无自有属性或无细胞 null。
- **所有权 / 错误 / 调用**：返回 VarRef cell 里的借用值，不 retain、不建根；非 mapped_arguments、索引越界、cell 已断开或自有属性已被删除都返回 `null`。不分配、不抛。唯一调用方 `src/exec/object_ops.zig:2502`（属性读的 mapped arguments 前置臂）。

### `setMappedArgumentsValue` (`src/exec/call_runtime.zig:5052`)

- **签名**：`pub fn setMappedArgumentsValue(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool`。
- **作用**：写映射参数；删除的映射断开。
- **实现**：无自有属性把 refs[index]=null，返回 false。
- **所有权 / 错误 / 调用**：命中时 `cell.setVarRefValue` 接管写入（内含写屏障）；自有属性已被删除时顺手把 `refs[index]` 置 `null`，即永久切断该索引与形参的映射（对应 qjs 删除后不再联动）。返回 `false` 让调用方走普通属性路径。error set 实际为空。唯一调用方 `src/exec/object_ops.zig:2910`。

### `readInt` (`src/exec/call_runtime.zig:5066`)

- **签名**：`pub fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：小端整数，字节码立即数。
- **实现**：`std.mem.readInt(..., .little)`。
- **所有权 / 错误 / 调用**：纯字节解码（小端），不分配、不抛。五个 opcode 模块把它 `const readInt = call_runtime.readInt;` 别名进本地命名空间后直接读立即数：`src/exec/vm_property_ref.zig:15`、`vm_property_locals.zig:12`、`vm_property_field.zig:19`、`vm_property_globals.zig:15`、`array_ops.zig:89`；另有两份同名私有副本（`object_ops.zig:4378`、`vm_call.zig:971`）不走这一份。

## 覆盖核对

- 清单函数数（三份子文件合计 `call_runtime.zig`）: 92（`src/exec/call_runtime.zig` 全文件 162）
- 未覆盖: 无
