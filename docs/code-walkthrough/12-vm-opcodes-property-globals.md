# 12 — 全局变量（`vm_property_globals.zig`）

文件职责：`op.get_var` / `get_var_undef` / `put_var` / `put_var_init`，以及闭包 PASS1/PASS2 的全局声明校验与 cell 实例化。快路径门来自 `vm_property`；IC 来自 `property_direct`。

文件内测试：`QuickJS global declaration validation does not materialize auto-init properties`。

### `closureVarAt` (`src/exec/vm_property.zig:32`)

- **签名**：`inline fn closureVarAt(function: *const bytecode.FunctionBytecode, idx: u16) ?bytecode.function_bytecode.BytecodeClosureVar`。
- **作用**：安全取 closure var 描述符。
- **实现**：越界 null。
- **所有权 / 错误 / 调用**：get/put_var 判断词法。

### `throwGlobalTdzReferenceError` (`src/exec/vm_property.zig:37`)

- **签名**：`fn throwGlobalTdzReferenceError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：全局词法 TDZ 的统一入口。
- **实现**：`throwTdzReferenceError` 再 handleCatchable。
- **所有权 / 错误 / 调用**：getVar/putVar 词法臂。

### `getVarFromGlobalObject` (`src/exec/vm_property.zig:55`)

- **签名**：`fn getVarFromGlobalObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, atom_id: core.Atom, ) !Step`。
- **作用**：qjs `OP_get_var` 慢臂（18474）：未初始化的**非词法**闭包 var 经全局**对象** `[[Get]]`，不查 lexical env。`get_var` 无绑定抛 ReferenceError；`get_var_undef`（typeof）给 undefined。
- **实现**：runtime strict 时若 lexical 已初始化则用之。否则自有 data。`get_var` 先 has，没有则 not-defined。否则 `getValueProperty`（含原型/getter）。push。
- **所有权 / 错误 / 调用**：cell uninit 回退。

### `getVar` (`src/exec/vm_property.zig:95`)

- **签名**：`pub noinline fn getVar( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, ) !Step`。
- **作用**：服务 `op.get_var` / `op.get_var_undef`。
- **实现**：`site_pc = pc-1`，读 u16 ref_idx，atom = `globalVarAtom`。有 `frame.var_refs[idx]`：cell 已初始化则 push（定义期 cell 手术保证权威，无 per-read lexical 检查）；uninit 时词法且不可删 → TDZ，否则 `getVarFromGlobalObject`。无 cell 但 closure var 词法 → TDZ。然后：undefined atom 快路径；`fastInstalledGlobalDataValueForAtomAtPc`；`canUseFastGlobalVarLookup` 下 lexical/data IC。最后完整 lexical → own data → has/get。`get_var` 无绑定抛错；`get_var_undef` 继续 get（可能 undefined）。
- **所有权 / 错误 / 调用**：两条 fast 臂命中后就地 `stack.push(value)` 返回 `.done`（原先中转的 `useFastGlobalDataValue` 只剩这两句加一串无副作用的空 `if`，连同它唯一调用的 `nextOpCanStartGlobalUriCall1` 一起已删）。分发冷路径；热路径有自己的 own-data 内联。

### `putVar` (`src/exec/vm_property.zig:204`)

- **签名**：`pub noinline fn putVar( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, strict_unresolved_get_var: bool, eval_global_var_bindings: bool, is_eval_code: bool, ) !Step`。
- **作用**：服务 `op.put_var`。
- **实现**：读 ref_idx/atom，pop value。有 cell：uninit 或 const 时，词法 cell → TDZ 或 TypeError；非词法落到全局对象写。已初始化且非 function-name → `setVarRefValue`。无 cell 的词法 closure → TDZ。快写：lexical / `setGlobalWritableDataStoreForFastPathOwned`。然后 `setGlobalLexicalValueForGlobal`。qjs **总是** `JS_HasProperty` 再 Set（18511），松散模式也不能跳过（Proxy has）。无绑定且（严格或 `strict_unresolved_get_var`）→ not-defined。eval 全局 var + 无 setter 的自有访问器 → 静默 continue（Annex B）。`setOwnWritableDataProperty`；松散下只读/无 setter 自有 → 静默。否则 `setValueProperty`。
- **所有权 / 错误 / 调用**：value 写入。许多成功臂返回 `.continue_loop`（pc 已在函数内前进）；冷壳 `h_put_var` 用 `_ = try` 丢掉这个 Step，两种取值都接 `coldNext`。

### `globalOwnRejectedNonStrictSet` (`src/exec/vm_property.zig:319`)

- **签名**：`fn globalOwnRejectedNonStrictSet(global: *core.Object, atom_id: core.Atom) bool`。
- **作用**：松散模式：自有只读 data 或无 setter 的访问器应静默失败。
- **实现**：有 exotic methods → false（必须走完整 Set）。扫 shape 找 atom。
- **所有权 / 错误 / 调用**：putVar。

### `canUseFastGlobalVarWrite` (`src/exec/vm_property.zig:335`)

- **签名**：`fn canUseFastGlobalVarWrite( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, atom_id: core.Atom, frame: *const frame_mod.Frame, ) bool`。
- **作用**：put_var 快写门。
- **实现**：`canFuseGlobalDataWrite` 且无 `functionFrameBindingShadowsGlobal`。
- **所有权 / 错误 / 调用**：putVar。

### `canUseFastGlobalUndefinedLookup` (`src/exec/vm_property.zig:346`)

- **签名**：`fn canUseFastGlobalUndefinedLookup( function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, ) bool`。
- **作用**：`undefined` 标识符能否直接压 undefined。
- **实现**：帧没有名为 undefined 的 var-ref。
- **所有权 / 错误 / 调用**：getVar。

### `evalFunctionDeclaresGlobalVar` (`src/exec/vm_property.zig:354`)

- **签名**：`fn evalFunctionDeclaresGlobalVar(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool`。
- **作用**：当前 eval 代码是否把该名字声明成全局 var（Annex B 访问器静默）。
- **实现**：closure var `global_decl` 且非词法，名字相等。
- **所有权 / 错误 / 调用**：putVar。

### `globalOwnAccessorWithoutSetter` (`src/exec/vm_property.zig:362`)

- **签名**：`fn globalOwnAccessorWithoutSetter(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) !bool`。
- **作用**：自有访问器且 setter undefined。
- **实现**：`getOwnProperty`。
- **所有权 / 错误 / 调用**：可能 OOM（描述符）。putVar。

### `globalDeclIsFunction` (`src/exec/vm_property.zig:367`)

- **签名**：`fn globalDeclIsFunction(cv: core.function_bytecode.BytecodeClosureVar) bool`。
- **作用**：该 GLOBAL_DECL 是否函数声明。
- **实现**：`global_decl` 且 `varKind == .global_function_decl`。
- **所有权 / 错误 / 调用**：校验与 PASS2。

### `validateGlobalVarDeclaration` (`src/exec/vm_property.zig:371`)

- **签名**：`fn validateGlobalVarDeclaration( ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, cv: core.function_bytecode.BytecodeClosureVar, is_eval_code: bool, ) !void`。
- **作用**：单条 GLOBAL_DECL 的 PASS1（`JS_CheckDefineGlobalVar`）：读**原始** shape，不触发 AUTOINIT。
- **实现**：先看自有（未删）shape 条目：不可配置时，词法 → SyntaxError；函数声明且（访问器或不可写或不可枚举）→ TypeError。无自有条目且非词法且不可扩展 → TypeError。最后才是 `globalLexicalHasForGlobal` → SyntaxError。
- **所有权 / 错误 / 调用**：`function`/`is_eval_code` 未用。`validateGlobalVarDeclarations`。

### `validateGlobalVarDeclarations` (`src/exec/vm_property.zig:406`)

- **签名**：`pub fn validateGlobalVarDeclarations( ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, is_eval_code: bool, ) !void`。
- **作用**：qjs `js_closure2` PASS1：只扫最终 GLOBAL_DECL 表。
- **实现**：对每个 `global_decl` 调上一函数。
- **所有权 / 错误 / 调用**：`zjs_vm` 进入脚本/eval 帧前；`object_ops` 闭包定义。

### `globalDefinition` (`src/exec/vm_property.zig:451`)

- **签名**：`pub noinline fn globalDefinition( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, eval_global_var_bindings: bool, opc: u8, ) !Step`。
- **作用**：服务 `op.put_var_init`（词法/eval 初始化）。
- **实现**：仅 `put_var_init`。读 idx/atom，pop value。非 eval-global-var 绑定时先快/慢写 lexical。否则 `setProperty` 到 global 对象。
- **所有权 / 错误 / 调用**：eval 全局 var 初始化是否针对 eval 变量环境是 L0 入口事实，不是每层嵌套函数的属性。

### `QuickJS global declaration validation does not materialize auto-init properties` (`src/exec/vm_property.zig:418`)

- **签名**：`test "..."`
- **作用**：断言 PASS1 不把 AUTOINIT 物化成 data。
- **实现**：造带 auto_init 的全局，编一条 global_decl 字节码，`validateGlobalVarDeclarations` 后 kind 仍是 auto_init。
- **所有权 / 错误 / 调用**：单测；自建 Runtime/Context。

## 覆盖核对

- 清单函数数: 15
- 本文标题覆盖: 16（含 1 条清单外的内嵌辅助函数标题）
- 未覆盖: 无
