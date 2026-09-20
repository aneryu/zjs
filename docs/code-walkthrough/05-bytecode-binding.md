# 05 — binding_rules

规则库，不是一遍 pass。镜像 `resolve_variables`（quickjs.c:33622）的绑定决定与写手：词法链顺序、closure 源穿线、动态环境探针、private brand、以及每种决定写出的精确字节。

`compiler/resolve_variables.zig` 拥有 CFG / LabelId / 事务输出，每条绑定决定调用这里，使树上只有一份 QuickJS 绑定语义。

## 关键类型

- `JSContext`：解析上下文，借 `Bytecode` + 可选 `FunctionDef`。`scope_link_proof` 只由结构校验推进。
- `ScopeOperand`：u16 = level | `opcode.scope_no_dynamic_env_flag`（0x8000：LHS 已选环境，fallback put 只走静态链）。
- `ScopeVarAction` / `ResolvedScopeVarPlan` / `ScopeVarProbePlan`：先规划再写，size/atomCount 与 writer 共用。
- `EvalVarObjectProbeKind`：eval 变量对象上的 probe 与 `dyn_env.ProbeKind` 的对应。
- `ClosureDynamicEnvProbeIterator` / `LocalWithProbeIterator`：沿闭包/with 链枚举需要 `dyn_env_probe` 的对象。
- `Error`：`OutOfMemory` / `InvalidBytecode` / `BytecodeOverflow` / `NoFunctionDef` / `NoParentScope` / `ClosureVarNotFound`。

降低总原则：能变成 `get_loc*`/`get_arg*`/`get_var_ref*` 就变；否则走全局闭包行（`get_var`/`put_var` 等 `var_ref` 格式，操作数是 u16 闭包下标而不是 atom）或 `dyn_env_probe` 链；const 写走 `throw_error`。

## 函数



### `binding_rules`

### `binding_rules.decodeScopeOperand` (`src/compiler/binding_rules.zig:38`)

- **签名**：`fn decodeScopeOperand(bytes: *const [2]u8) ScopeOperand`。
- **作用**：解开 u16 作用域操作数：低位 level，高位 `scope_no_dynamic_env_flag`。
- **实现**：0xFFFF 当作 level=-1。
- **所有权 / 错误 / 调用**：纯解码，不分配、无 error set。经 `surface.decodeScopeOperand`（`bytecode.zig:9520`）由 `compiler/resolve_variables.zig:1642`、`:1710`、`:1777`、`:1882` 四处 phase-1 scope_* 指令改写读取操作数。


### `binding_rules.markEvalCapturedVariables` (`src/compiler/binding_rules.zig:58`)

- **签名**：`fn markEvalCapturedVariables(fd: *function_def_mod.FunctionDef, scope_level: u16) Error!void`。
- **作用**：把某作用域链上的局部全部 captureLocal。
- **实现**：沿 scope.first / scope_next；错误终止哨兵 InvalidBytecode。
- **所有权 / 错误 / 调用**：就地改写借来的 `fd`（经 `fd.captureLocal` 置捕获状态），自身不分配。`scope_level` 越界、局部下标越界、遍历次数超过 `fd.vars.len`（环）或终止哨兵既非 -1 也非 `arg_scope_end` → `error.InvalidBytecode`；`captureLocal` 的 `BytecodeOverflow` 原样上抛。经 `surface.markEvalCapturedVariables`（`bytecode.zig:9521`）由 `compiler/resolve_variables.zig:2101`、`:2115`、`:2437`、`:2442` 的 eval 降低调用。


### `binding_rules.encodeEvalScopeHead` (`src/compiler/binding_rules.zig:74`)

- **签名**：`fn encodeEvalScopeHead(fd: *const function_def_mod.FunctionDef, scope_level: u16) Error!u16`。
- **作用**：把 scope head 加 `EVAL_SCOPE_HEAD_BIAS`（= `-arg_scope_end`）偏置成 u16。
- **实现**：负/溢出 BytecodeOverflow。
- **所有权 / 错误 / 调用**：不分配，只读 `fd.scopes` / `arg_scope_end`。偏置后为负或超 u16 返回 `Error.BytecodeOverflow`，沿 `resolve_variables.Error` 上抛，不产生 JS 异常对象。经 `surface.encodeEvalScopeHead`（`bytecode.zig:9522`）由 `compiler/resolve_variables.zig:2102`、`:2116` 的 eval 作用域头改写调用——不是「私有」。


### `binding_rules.validateFunctionDefParentChain` (`src/compiler/binding_rules.zig:86`)

- **签名**：`fn validateFunctionDefParentChain(start: *function_def_mod.FunctionDef) error{InvalidBytecode}!void`。
- **作用**：Floyd 判圈：父指针环 → InvalidBytecode。
- **实现**：无分配、无深度帽。
- **所有权 / 错误 / 调用**：只读借来的 `parent` 链，用快慢指针代替 visited 集所以不分配；唯一错误 `error.InvalidBytecode`。`binding_rules` 私有，两个调用方：`bytecode.zig:6773`（`proveParentScopeLinksForResolution`）与 `:9018`（`resolveBindingTopologyAfterCurrentMiss` 的独立回退路径）。


### `binding_rules.JSContext.initWithFunctionDef` (`src/compiler/binding_rules.zig:117`)

- **签名**：`pub fn initWithFunctionDef( function: *bytecode_function.Bytecode, fd: *function_def_mod.FunctionDef, ) JSContext`。
- **作用**：解析用上下文。
- **实现**：带上 fd。
- **所有权 / 错误 / 调用**：`function` 与 `fd` 都是借用，生命周期由调用方持有；不分配、无 error set，`scope_link_proof` 起始 `.none`。唯一生产调用方 `compiler/resolve_variables.zig:2467`（`run` 入口），另有 `bytecode.zig:7209` 单测。


### `binding_rules.JSContext.proveScopeLinksForResolution` (`src/compiler/binding_rules.zig:134`)

- **签名**：`pub fn proveScopeLinksForResolution(self: *JSContext) Error!void`。
- **作用**：当前 def 的 scope 链证明。
- **实现**：先把 `scope_link_proof` 清成 `.none`，`fd.validateFinalScopeLinks()` 通过后才置 `.current`（祖先链另由 `proveParentScopeLinksForResolution` 惰性升级为 `.tree`）。
- **所有权 / 错误 / 调用**：不分配，只读/只写 `ctx` 自身字段。无 `function_def` → `error.NoFunctionDef`；`validateFinalScopeLinks` 的任何失败统一映射为 `error.InvalidBytecode`。调用方 `compiler/resolve_variables.zig:2468`（紧跟 `initWithFunctionDef`）。


### `binding_rules.JSContext.proveParentScopeLinksForResolution` (`src/compiler/binding_rules.zig:141`)

- **签名**：`fn proveParentScopeLinksForResolution(self: *JSContext) Error!void`。
- **作用**：Floyd 证明父链后再 prove 祖先 scope 链接。
- **实现**：已是 `.tree` 直接返回；不是 `.current` 则 InvalidBytecode；无 FunctionDef → NoFunctionDef。Floyd 判圈后沿父链逐个 `proveAncestorScopeLinks`，最后升级为 `.tree`。 错误臂：`error.InvalidBytecode`、`error.NoFunctionDef`。
- **所有权 / 错误 / 调用**：错误：`error.InvalidBytecode`、`error.NoFunctionDef`。编译管线错误由 parser/finalize 映射为 JS 异常或失败返回。 唯一调用方 `bytecode.zig:9016`（`resolveBindingTopologyAfterCurrentMiss`：首次真实父作用域 miss 时惰性证明）；私有，`surface` 不导出。


### `binding_rules.fclosureEncodingSize` (`src/compiler/binding_rules.zig:155`)

- **签名**：`fn fclosureEncodingSize(cpool_idx: i32) error{InvalidBytecode}!usize`。
- **作用**：fclosure / fclosure8 的编码长度。
- **实现**：下标≥256 用 5 字节，否则 2。非法负下标 InvalidBytecode。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：不分配。`cpool_idx` 为负或超范围返回 `error.InvalidBytecode`。`binding_rules` 私有，唯一调用方 `bytecode.zig:7484`（`enterScopeRefreshSize`）；与 `emitFClosure` 成对，保证预算与实际写入一致。


### `binding_rules.emitFClosure` (`src/compiler/binding_rules.zig:159`)

- **签名**：`fn emitFClosure(output: []u8, out_idx: *usize, cpool_idx: i32) error{InvalidBytecode}!void`。
- **作用**：写出 fclosure 或 fclosure8。
- **实现**：按 cpool_idx 选宽窄。 小端写入 opcode 与立即数。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：只往调用方给的 `output` 窗口写字节，不分配、不拥有缓冲。`error.InvalidBytecode` 同 `fclosureEncodingSize`。唯一调用方 `bytecode.zig:7507`（`writeEnterScopeRefresh`）；注意 `parser.zig:2944` 的 `State.emitFClosure` 是同名但不相干的另一个函数，不是本函数的调用方。


### `binding_rules.lowerScopeVarOpGlobal` (`src/compiler/binding_rules.zig:178`)

- **签名**：`fn lowerScopeVarOpGlobal(op_id: u8) u8`。
- **作用**：scope_* → 3 字节 var_ref 族。scope_put_var_init → put_var_init。
- **实现**：switch 映射。 分支覆盖：`scope_get_var_checkthis`、`scope_put_var`、`scope_get_var_undef`、`scope_put_var_init`。
- **所有权 / 错误 / 调用**：纯 opcode 映射：不分配、无 error set、不碰 `ctx`。`binding_rules` 私有，调用方 `bytecode.zig:8160`（`globalScopeVarAction`）、`:8273`（`planResolvedScopeVarAction`）——不经 `surface`，`resolve_variables.zig` 够不着。


### `binding_rules.lowerScopeVarOpLocal` (`src/compiler/binding_rules.zig:194`)

- **签名**：`fn lowerScopeVarOpLocal(op_id: u8) u8`。
- **作用**：scope_* → loc 族。scope_get_var_undef 塌成 get_loc（帧槽已分配）。
- **实现**：switch。 分支覆盖：`scope_get_var_checkthis`、`scope_put_var`、`scope_get_var_undef`、`scope_put_var_init`。
- **所有权 / 错误 / 调用**：纯 opcode 映射，不分配、无 error set。`binding_rules` 私有，调用方 `bytecode.zig:8225`（`planScopeVarAction`）、`:8267`（`planResolvedScopeVarAction`）。


### `binding_rules.selectShortLoc` (`src/compiler/binding_rules.zig:221`)

- **签名**：`fn selectShortLoc(base_op: u8, idx: u16) ShortLocForm`。
- **作用**：loc 族：idx<4 burned，<256 loc8，否则 wide。
- **实现**：按 base_op。 分支覆盖：`get_loc`、`put_loc`、`set_loc`。
- **所有权 / 错误 / 调用**：纯查表，返回按值的 `ShortLocForm`，不分配、无 error set。私有，唯一调用方 `bytecode.zig:6884`（`selectLocForm`）。


### `binding_rules.shortOpcodesEnabled` (`src/compiler/binding_rules.zig:247`)

- **签名**：`fn shortOpcodesEnabled(ctx: *const JSContext) bool`。
- **作用**：当前函数是否允许短 opcode（finalize 后 use_short_opcodes）。
- **实现**：读 FunctionDef 的 `use_short_opcodes`；无 def 直接 false。
- **所有权 / 错误 / 调用**：只读 `ctx.function_def` 的 `use_short_opcodes`（无 def 即 false），不分配、无 error set。私有，三个调用方都是 form 选择器：`bytecode.zig:6884`（`selectLocForm`）、`:7583`（`selectVarRefForm`）、`:7604`（`selectArgForm`）。


### `binding_rules.selectLocForm` (`src/compiler/binding_rules.zig:252`)

- **签名**：`fn selectLocForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm`。
- **作用**：若允许短码则 selectShortLoc，否则 wide。
- **实现**：一层包装。
- **所有权 / 错误 / 调用**：不分配、无 error set；只读 `ctx.function_def` 的 `use_short_opcodes`。私有，是 size/writer 两侧共用的单一定价点：`bytecode.zig:7485`（`enterScopeRefreshSize`）与 `:7508`（`writeEnterScopeRefresh`）、`:8226`（`planScopeVarAction`）、`:8268`（`planResolvedScopeVarAction`）等 12 处。


### `binding_rules.closureVarIsRuntimeVarRef` (`src/compiler/binding_rules.zig:257`)

- **签名**：`fn closureVarIsRuntimeVarRef(cv: function_def_mod.ClosureVar) bool`。
- **作用**：该闭包行是否持有真实运行时 VarRef：只有 `.global` 是纯 atom 载体（false），其余（含 `global_ref`/`global_decl`/`module_decl`/`module_import`）都是 true。
- **实现**：看 ClosureType。 分支覆盖：`global`、`module_import`。
- **所有权 / 错误 / 调用**：纯谓词，按值收 `ClosureVar`，不分配、无 error set。私有，但被 `binding_rules` 外的 `FunctionDefImpl.addClosureVar`（`bytecode.zig:5784`）直接引用，用来在唯一增长点维护 `closure_var_may_have_dynamic_env`；其余调用方在本 namespace 内（`:6922`、`:7794`、`:8808`、`:8966` 等 5 处）。


### `binding_rules.closureVarSourceIsDynamicGlobal` (`src/compiler/binding_rules.zig:268`)

- **签名**：`fn closureVarSourceIsDynamicGlobal(fd: *const function_def_mod.FunctionDef, start_idx: usize) bool`。
- **作用**：从 start_idx 沿 ref 链是否撞上动态全局对象。
- **实现**：从 `start_idx` 起沿链跳，最多 64 跳：`global`/`global_ref`/`global_decl` → true；`.ref` 换到父函数、下标改成 `cv.var_idx` 继续（无父即 false）；`local`/`arg`/`module_decl`/`module_import` → false。
- **所有权 / 错误 / 调用**：只读 `fd.closure_var` 链，不分配、无 error set。私有，调用方 `bytecode.zig:6923`（`lookupClosureVar`）、`:8967`（`findResolvedClosureBinding`）。


### `binding_rules.lookupClosureVar` (`src/compiler/binding_rules.zig:288`)

- **签名**：`fn lookupClosureVar(ctx: *const JSContext, atom_id: u32) ?u16`。
- **作用**：当前函数闭包表按 atom 找运行时 ref。
- **实现**：线性扫 `fd.closure_var`，跳过非运行时 VarRef 行（`closureVarIsRuntimeVarRef`）和源头是动态全局的行（`closureVarSourceIsDynamicGlobal`），同名即返回下标；miss 直接返回 null，**不**回退到祖先索引空间（父闭包/局部/参数是另一套下标，见 quickjs.c:32736-32760、33290-33354）。
- **所有权 / 错误 / 调用**：只读扫描，返回借来的下标（不是所有权），不分配、无 error set。私有，调用方是 size/writer 对与 probe 判定共 10 处：`bytecode.zig:8229`（`planScopeVarAction`）、`:8353`（`loweredScopeDeleteVarSize`）、`:8466`（`writeLoweredScopeDeleteVar`）等。


### `binding_rules.lookupGlobalClosureVar` (`src/compiler/binding_rules.zig:304`)

- **签名**：`fn lookupGlobalClosureVar(ctx: *const JSContext, atom_id: u32) ?u16`。
- **作用**：找 atom 对应的「全局族」闭包行——除 `.global`/`.global_ref`/`.global_decl` 外，`.module_decl`/`.module_import` 也算命中。
- **实现**：按 `var_name` 线性扫 `fd.closure_var`，closureType 落在上述五类之一即返回下标。
- **所有权 / 错误 / 调用**：只读扫描，不分配、无 error set；找不到返回 null，由调用方决定是新建行还是报 `ClosureVarNotFound`。私有，调用方 `bytecode.zig:7001`（`ensureGlobalClosureVar`）、`:7043`（`emitGlobalVarOp`）、`:8157`（`globalScopeVarAction`）。


### `binding_rules.addOrFindClosureSource` (`src/compiler/binding_rules.zig:316`)

- **签名**：`fn addOrFindClosureSource( fd: *function_def_mod.FunctionDef, closure_type: function_def_mod.ClosureType, source_idx: u16, source: function_def_mod.ClosureVar, ) Error!u16`。
- **作用**：按 (type, source_idx) 去重追加闭包行。
- **实现**：已有则返回下标。 循环扫描切片或字节码。 内部 `try` 传播错误。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**会分配**：未命中时 `fd.addClosureVar` 经 `fd.memory`（MemoryAccount）增长 `closure_var`，新行的 `var_name` 直接复制 atom id，不 retain；行归 FunctionDef 所有，随 `FunctionDef.deinit` 释放。OOM 冒泡为 `Error.OutOfMemory`，下标溢出为 `error.InvalidBytecode`。私有，唯一调用方 `bytecode.zig:6997`（`threadClosureSource`）。


### `binding_rules.threadClosureSource` (`src/compiler/binding_rules.zig:343`)

- **签名**：`fn threadClosureSource( target: *function_def_mod.FunctionDef, source_owner: *function_def_mod.FunctionDef, source_idx: u16, source: function_def_mod.ClosureVar, source_type: function_def_mod.ClosureType, ) Error!u16`。
- **作用**：qjs get_closure_var 递归：每个中间函数一行指向直接父。
- **实现**：身份 (closure_type, var_idx) 去重；直接父用 source_type，否则中间行降成 `.ref`（`global_ref` 源保持 `global_ref`）；target_type 落到 global/global_decl/module_* 则 InvalidBytecode。 分支覆盖：`global_ref`、`module_import`。 内部 `try` 传播错误。 调用 `threadClosureSource` 穿父源。 错误臂：`error.InvalidBytecode`、`error.NoParentScope`。
- **所有权 / 错误 / 调用**：沿 `target.parent` 递归，**会分配**（每层经 `addOrFindClosureSource` → `fd.addClosureVar` 增长 `closure_var`），新行归各自 FunctionDef 所有；`target` 无父 → `error.NoParentScope`，target_type 落到 `global`/`global_decl`/`module_*` → `error.InvalidBytecode`，OOM 上抛。`binding_rules` 私有（`surface` 不导出），调用方全在 `bytecode.zig`：`:6986`（自身递归）、`:7038`（`ensureGlobalClosureVar`）、`:8853`（`threadParentLocalSource`）、`:8871`（`threadParentArgSource`）、`:9130`/`:9137`（`resolveBindingTopologyAfterCurrentMiss`），另有 `:10427`/`:10459`/`:10586` 三处单测。


### `binding_rules.ensureGlobalClosureVar` (`src/compiler/binding_rules.zig:369`)

- **签名**：`fn ensureGlobalClosureVar(ctx: *JSContext, atom_id: u32) Error!u16`。
- **作用**：确保一条指向全局的闭包行。
- **实现**：先查本函数已有的 global 族行；否则在最近的 `is_eval` 根上找/建 `.global` 载体，再用 `threadClosureSource` 把 `.global_ref` 穿回当前 def。 分支覆盖：`global_decl`。 循环扫描切片或字节码。 内部 `try` 传播错误。 调用 `threadClosureSource` 穿父源。 错误臂：`error.InvalidBytecode`、`error.NoFunctionDef`。
- **所有权 / 错误 / 调用**：**会分配**：eval 根缺载体时 `root.addClosureVar` 增长根的 `closure_var`，随后 `threadClosureSource` 在每一层中间函数再各加一行；行归各 FunctionDef 所有。无 `function_def` → `error.NoFunctionDef`，下标超 u16 → `error.InvalidBytecode`，另可上抛 `OutOfMemory`/`NoParentScope`。私有，调用方全在本 namespace：`bytecode.zig:9147`（`resolveBindingTopologyAfterCurrentMiss`）、`:9202`/`:9210`（`resolveScopeVarBindingTopologyImpl`）、`:9325`/`:9331`（`resolveScopeVarPlanImpl`）。


### `binding_rules.emitGlobalVarOp` (`src/compiler/binding_rules.zig:410`)

- **签名**：`fn emitGlobalVarOp(ctx: *JSContext, output: []u8, out_idx: *usize, op_id: u8, atom_id: u32) Error!void`。
- **作用**：写 get_var/put_var 等 3 字节全局 var_ref 指令。
- **实现**：先 `lookupGlobalClosureVar` 取闭包行下标（找不到 `ClosureVarNotFound`），再写 opcode + u16 下标；不写 atom、不动 ledger。 错误臂：`error.ClosureVarNotFound`、`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：只往调用方给的 `output` 窗口写 3 字节，不分配；窗口不够 → `error.InvalidBytecode`，闭包行缺失 → `error.ClosureVarNotFound`。私有，调用方 `bytecode.zig:8501`、`:8528`（都在 `writeLoweredScopeGetRef`）；`parser.zig:3448` 的 `State.emitGlobalVarOp` 是同名的另一个函数，与本函数无关。


### `binding_rules.lookupTopLevelModuleLexicalClosureVar` (`src/compiler/binding_rules.zig:418`)

- **签名**：`fn lookupTopLevelModuleLexicalClosureVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16`。
- **作用**：模块顶层词法闭包行。
- **实现**：只在 `scope_level == 0` 时生效（否则 null）；线性扫 `fd.closure_var`，要求同名、closureType 是 `.module_decl` 或 `.global_decl`、且 `isLexical()`。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，调用方 `bytecode.zig:7903`（`staticBindingStopsDynamicEnvProbes`）、`:8194`（`planScopeVarAction`）、`:9204`（`resolveScopeVarBindingTopologyImpl`）等 5 处。


### `binding_rules.preferTopLevelModuleClassBinding` (`src/compiler/binding_rules.zig:427`)

- **签名**：`fn preferTopLevelModuleClassBinding(ctx: *const JSContext, atom_id: u32, loc_idx: u16) ?u16`。
- **作用**：class 绑定优先用模块顶层行而非局部。
- **实现**：先要求 `loc_idx` 那一槽就是这个 atom、位于 scope 0、且 `is_lexical` + `is_const`（class 绑定在类体内不可写的那一份）；再在 `fd.closure_var` 里找同名、`.module_decl`、lexical 且**非** const 的行，命中就返回它的下标顶替局部。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，调用方 `bytecode.zig:8206`（`planScopeVarAction`）、`:9212`（`resolveScopeVarBindingTopologyImpl`）、`:9333`（`resolveScopeVarPlanImpl`）。


### `binding_rules.closureVarKind` (`src/compiler/binding_rules.zig:438`)

- **签名**：`fn closureVarKind(ctx: *const JSContext, idx: u16) function_def_mod.VarKind`。
- **作用**：闭包行的 VarKind。
- **实现**：读 flags。
- **所有权 / 错误 / 调用**：只读访问器，不分配、无 error set；越界时返回 `.normal` 而不是报错。私有，调用方 `bytecode.zig:8177`（`closureScopeVarAction`）、`:8387`（`loweredScopeMakeRefSize`）、`:8614`（`writeLoweredScopeMakeRef`）等 5 处。


### `binding_rules.closureVarWriteThrowsReadOnly` (`src/compiler/binding_rules.zig:458`)

- **签名**：`fn closureVarWriteThrowsReadOnly(ctx: *const JSContext, ref_idx: u16) bool`。
- **作用**：对该闭包写是否应编译期 throw（模块 import 只读）。
- **实现**：无 `function_def` 或 `ref_idx` 越界一律 false，否则转 `closureVarConstWriteThrows`；global 族被豁免——它们走运行时 `put_var` 的全局词法 cell 路径（TDZ ReferenceError 优先）。
- **所有权 / 错误 / 调用**：只读谓词，不分配、无 error set。私有，size 与 writer 成对使用：`bytecode.zig:8174`（`closureScopeVarAction`）、`:8386`（`loweredScopeMakeRefSize`）、`:8612`（`writeLoweredScopeMakeRef`）等 4 处。


### `binding_rules.closureVarConstWriteThrows` (`src/compiler/binding_rules.zig:464`)

- **签名**：`fn closureVarConstWriteThrows(start_fd: *const function_def_mod.FunctionDef, start_idx: u16) bool`。
- **作用**：沿闭包源链看 const 写是否 throw。
- **实现**：起始行非 const 直接 false；否则**迭代**（非递归）沿 `.ref`/`.global_ref` 转发行跳到父函数的源行，最多 64 跳，用基行身份定夺：`global`/`global_decl`/`global_ref` → false，`local`/`arg`/`ref`/`module_decl`/`module_import` → true。
- **所有权 / 错误 / 调用**：沿 closure 链只读回溯，不分配、无 error set（hops < 64 硬帽兜住环）。私有，唯一调用方 `bytecode.zig:7092`（`closureVarWriteThrowsReadOnly`）。


### `binding_rules.writeThrowVarReadOnly` (`src/compiler/binding_rules.zig:491`)

- **签名**：`fn writeThrowVarReadOnly(func: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32) void`。
- **作用**：写 throw_error 只读。
- **实现**：转 writeThrowVarError。
- **所有权 / 错误 / 调用**：薄包装，只往调用方预留的 `output` / `output_atoms` 窗口写，不分配、无 error set；自身不做边界检查，容量由配对的 size 函数保证。私有，调用方 `bytecode.zig:7421`/`:7430`（`writeLoweredPrivateField`）、`:8317`（`writeScopeVarAction`）、`:8590`/`:8613`（`writeLoweredScopeMakeRef`）。


### `binding_rules.writeThrowVarError` (`src/compiler/binding_rules.zig:495`)

- **签名**：`fn writeThrowVarError( _: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32, error_type: u8, ) void`。
- **作用**：写 throw_error + atom + 错误码。
- **实现**：atom 进 ledger。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：写 6 字节 `throw_error` 并把 atom id 复制进 `output_atoms` 账本（只写 id，不 retain/release；账本本身归 `resolve_variables.ResolvedProduct` 所有）。不分配、无 error set。私有，唯一调用方 `bytecode.zig:7123`（`writeThrowVarReadOnly`）。


### `binding_rules.writeThrowVarRedeclaration` (`src/compiler/binding_rules.zig:512`)

- **签名**：`fn writeThrowVarRedeclaration(_: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32) void`。
- **作用**：写重复声明 throw。
- **实现**：特定 error_type。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：同 `writeThrowVarError`，只是 error_type 固定为 `JS_THROW_VAR_REDECL`；不分配、无 error set，atom 只复制 id。经 `surface.writeThrowVarRedeclaration`（`bytecode.zig:9577`）由 `compiler/resolve_variables.zig:665`（`emitThrowVarRedeclaration`）调用，是本组唯一进 surface 的写手。


### `binding_rules.lowerScopeVarOpForClosure` (`src/compiler/binding_rules.zig:521`)

- **签名**：`fn lowerScopeVarOpForClosure(ctx: *const JSContext, atom_id: u32, ref_idx: u16, op_id: u8) u8`。
- **作用**：scope_* 对闭包行选 get/put/check/init 变体。
- **实现**：先取 `lowerScopeVarOpClosure(op_id)` 的带 check 基线，再按 `ref_idx` 这一行（权威身份，不再按 atom 重搜）打三个补丁：`scope_put_var_init` 且 atom 是 `this` → `put_var_ref_check_init`（BindThisValue 的初始化一次守卫，quickjs.c:33355-33364）；`scope_get_var`/`scope_get_var_undef` 且该行是 `function_decl` 或非 lexical → `get_var_ref`；`scope_put_var` 且非 lexical → `put_var_ref`。
- **所有权 / 错误 / 调用**：只读 `fd.closure_var`，不分配、无 error set；无 def 或越界时退回基线 opcode。私有，唯一生产调用方 `bytecode.zig:8180`（`closureScopeVarAction`）；`:7212`–`:7224` 是本文件的单测断言。


### `binding_rules.resolvePrivateField` (`src/compiler/binding_rules.zig:602`)

- **签名**：`fn resolvePrivateField(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?PrivateFieldResolution`。
- **作用**：沿词法链解析 private 字段绑定。
- **实现**：先沿 `fd.scopes[scope_level].first` / `scope_next` 扫本函数局部（`visited` 次数帽防环），名字相同且 `isPrivateVarKind` 即返回 `{idx, is_ref=false, var_kind}`；局部没有再线性扫 `fd.closure_var`，命中返回 `is_ref=true` 的闭包下标；都没有返回 null。
- **所有权 / 错误 / 调用**：只读解析，返回按值的 `PrivateFieldResolution`（内含借来的下标），不分配、无 error set；找不到返回 null。经 `surface.resolvePrivateField`（`bytecode.zig:9564`）由 `compiler/resolve_variables.zig:1889`（`lowerPrivateField`）调用，namespace 内还有 `bytecode.zig:9440`（`resolvePrivateBindingTopology`）。


### `binding_rules.isPrivateVarKind` (`src/compiler/binding_rules.zig:628`)

- **签名**：`fn isPrivateVarKind(kind: function_def_mod.VarKind) bool`。
- **作用**：VarKind 是否 private_*。
- **实现**：枚举判断。 返回 `switch (kind) { .private_field, .private_method, .private_getter, .private_setter, .private_getter_setter, => true, else => false, }`。 按 `switch` 分派。
- **所有权 / 错误 / 调用**：纯 enum 谓词，不分配、无 error set、不碰 `ctx`。私有，调用方 `bytecode.zig:7244`/`:7252`（`resolvePrivateField`）、`:7462`（`varNeedsTdzRearm`）、`:9390`/`:9402`（`privateBindingOwner`）。


### `binding_rules.isPrivateSetterCompanionName` (`src/compiler/binding_rules.zig:640`)

- **签名**：`fn isPrivateSetterCompanionName(ctx: *const JSContext, private_atom: atom.Atom, candidate_atom: atom.Atom) bool`。
- **作用**：候选 atom 是否该 private 的 setter 伴生名。
- **实现**：伴生名约定 = private 名后缀 `"<set>"`：先从 `ctx.atoms.name` 取两个名字（取不到即 false），再比长度与前后两段字节。
- **所有权 / 错误 / 调用**：只读 atom 表做前缀比较，不分配、无 error set。私有，调用方 `bytecode.zig:7291`/`:7299`（`resolvePrivateSetter`）、`:9424`（`findPrivateSetterOwnerBinding`）。


### `binding_rules.resolvePrivateSetter` (`src/compiler/binding_rules.zig:649`)

- **签名**：`fn resolvePrivateSetter(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) ?PrivateFieldResolution`。
- **作用**：解析 private setter（getter/setter 对写入时取 setter 那一半）。
- **实现**：与 `resolvePrivateField` 同一双段扫描，但筛选条件换成 `var_kind == .private_setter` 且名字满足 `isPrivateSetterCompanionName`：先本函数局部（`is_ref=false`）后 `closure_var`（`is_ref=true`）。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，调用方 `bytecode.zig:7348`（`loweredPrivateFieldSize`）、`:7432`（`writeLoweredPrivateField`）、`:9444`/`:9450`（`resolvePrivateBindingTopology`）。


### `binding_rules.privateAccessorSize` (`src/compiler/binding_rules.zig:674`)

- **签名**：`fn privateAccessorSize(ctx: *const JSContext, res: PrivateFieldResolution) usize`。
- **作用**：写出 private 访问器的字节数。
- **实现**：视 loc vs var_ref。
- **所有权 / 错误 / 调用**：纯定价，不分配、无 error set；必须与 `writePrivateAccessor` 写出的字节数逐字节相等。私有，唯一调用方是 `bytecode.zig:7335`、`:7349`（都在 `loweredPrivateFieldSize` 内）。


### `binding_rules.writePrivateAccessor` (`src/compiler/binding_rules.zig:678`)

- **签名**：`fn writePrivateAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, res: PrivateFieldResolution) void`。
- **作用**：写 get_loc/get_var_ref 取出 private 品牌/访问器。
- **实现**：按 resolution。 按 `switch` 分派。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：只往预留窗口写，不分配、无 error set；容量由 `privateAccessorSize` 保证。私有，六个调用点全在 `bytecode.zig:7398`–`:7450`（`writeLoweredPrivateField`）。


### `binding_rules.loweredPrivateFieldSize` (`src/compiler/binding_rules.zig:702`)

- **签名**：`fn loweredPrivateFieldSize(ctx: *const JSContext, op_id: u8, atom_id: atom.Atom, scope_level: i32, res: PrivateFieldResolution) !usize`。
- **作用**：降低后 private 字段指令的总字节。
- **实现**：含可选 call_method。 分支覆盖：`scope_get_private_field2`、`private_field`、`private_method`、`private_getter_setter`、`private_setter`、`scope_put_private_field`、`private_getter`、`scope_in_private_field`。 错误臂：`error.ClosureVarNotFound`。
- **所有权 / 错误 / 调用**：纯定价，不分配；读 `.private_setter`、写 `.private_method`/`.private_getter` 都折成 `throw_error` 的 6 字节；setter 伴生绑定缺失或 `var_kind` 不在 private 集 → `error.ClosureVarNotFound`。经 `surface.loweredPrivateFieldSize`（`bytecode.zig:9565`）由 `compiler/resolve_variables.zig:758`（`Resolver.writeLoweredPrivateField`）调用做 `prepareLegacyWrite` 预算，必须与 `writeLoweredPrivateField` 实写逐字节相等。


### `binding_rules.loweredPrivateFieldAtomCount` (`src/compiler/binding_rules.zig:726`)

- **签名**：`fn loweredPrivateFieldAtomCount(op_id: u8, res: PrivateFieldResolution) usize`。
- **作用**：降低后消耗几个 atom ledger 项。
- **实现**：按 op。 分支覆盖：`scope_get_private_field2`、`scope_put_private_field`、`scope_in_private_field`。
- **所有权 / 错误 / 调用**：纯计数，不分配、无 error set；结果就是 `resolve_variables` 向 `product.atom_operands` 预留的槽数。经 `surface.loweredPrivateFieldAtomCount`（`bytecode.zig:9566`）由 `compiler/resolve_variables.zig:765`（`writeLoweredPrivateField`）调用，树内无其它调用方。


### `binding_rules.writePrivateCallMethodZero` (`src/compiler/binding_rules.zig:735`)

- **签名**：`fn writePrivateCallMethodZero(output: []u8, out_idx: *usize) void`。
- **作用**：写 call_method argc=0 的占位 cache_idx。
- **实现**：转 `writePrivateCallMethod(output, out_idx, 0)`；cache_idx 由 `resolve_labels` 写最终形态时填真值。
- **所有权 / 错误 / 调用**：只写 4 字节，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7419`（`writeLoweredPrivateField` 的 getter 臂）。


### `binding_rules.writePrivateCallMethod` (`src/compiler/binding_rules.zig:739`)

- **签名**：`fn writePrivateCallMethod(output: []u8, out_idx: *usize, argc: u16) void`。
- **作用**：写带 argc 的 call_method。
- **实现**：占位 cache_idx。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：写 4 字节（`call_method` + u16 argc + 1 字节占位 cache_idx），不分配、无 error set。私有，调用方 `bytecode.zig:7368`（`writePrivateCallMethodZero`）、`:7443`（`writeLoweredPrivateField` 的 setter 臂，argc=1）。


### `binding_rules.writeLoweredPrivateField` (`src/compiler/binding_rules.zig:745`)

- **签名**：`fn writeLoweredPrivateField( ctx: *const JSContext, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, op_id: u8, atom_id: atom.Atom, scope_level: i32, res: PrivateFieldResolution, ) !void`。
- **作用**：写出 get/put/in private 的最终序列。
- **实现**：accessor + 字段 op + 可选 call。 分支覆盖：`scope_get_private_field2`、`private_field`、`private_method`、`private_getter_setter`、`private_setter`、`scope_put_private_field`、`private_getter`。 小端写入 opcode 与立即数。 错误臂：`error.ClosureVarNotFound`。
- **所有权 / 错误 / 调用**：只往 `output` / `output_atoms` 两个预留窗口写，不分配、不做边界检查（容量由 `loweredPrivateFieldSize` / `loweredPrivateFieldAtomCount` 保证）；setter 伴生缺失或 `var_kind` 不在 private 集 → `error.ClosureVarNotFound`。经 `surface.writeLoweredPrivateField`（`bytecode.zig:9567`）由 `compiler/resolve_variables.zig:772`（`Resolver.writeLoweredPrivateField`，其调用点在 `:1894` 的 `lowerPrivateField`）调用。


### `binding_rules.varNeedsTdzRearm` (`src/compiler/binding_rules.zig:826`)

- **签名**：`fn varNeedsTdzRearm(vd: function_def_mod.VarDef) bool`。
- **作用**：普通词法 var 在 enter_scope 要重装 TDZ；函数声明走另一臂。
- **实现**：看 var_kind。 返回 `vd.is_lexical and (vd.var_kind == .normal or isPrivateVarKind(vd.var_kind))`。
- **所有权 / 错误 / 调用**：纯 VarDef 谓词，按值收参，不分配、无 error set。私有，size/writer 成对调用：`bytecode.zig:7486`（`enterScopeRefreshSize`）、`:7509`（`writeEnterScopeRefresh`）。


### `binding_rules.varNeedsScopeFunctionInit` (`src/compiler/binding_rules.zig:830`)

- **签名**：`fn varNeedsScopeFunctionInit(vd: function_def_mod.VarDef) bool`。
- **作用**：该绑定是否要在 enter_scope 用 func_pool_idx 初始化。
- **实现**：函数声明。 返回 `vd.is_lexical and vd.func_pool_idx >= 0 and (vd.var_kind == .function_decl or vd.var_kind == .new_function_decl)`。
- **所有权 / 错误 / 调用**：纯 VarDef 谓词，不分配、无 error set。私有，调用方 `bytecode.zig:7483`（`enterScopeRefreshSize`）、`:7506`（`writeEnterScopeRefresh`）。


### `binding_rules.enterScopeRefreshSize` (`src/compiler/binding_rules.zig:839`)

- **签名**：`fn enterScopeRefreshSize(ctx: *const JSContext, scope: i32) Error!usize`。
- **作用**：OP_enter_scope 降低的字节数：只初始化本 scope 声明的绑定（qjs `OP_enter_scope`，quickjs.c:34398）。
- **实现**：沿 `fd.scopes[scope].first` / `scope_next` 走，`vd.scope_level != scope`（继承来的尾巴）立即停；跳过 `fd.arguments_arg_idx`；函数声明记 `fclosureEncodingSize + selectLocForm(put_loc)`，其余需重装 TDZ 的词法各记 3 字节。无 fd 或 scope 越界返回 0。
- **所有权 / 错误 / 调用**：不分配；沿 `scope.first`/`scope_next` 只读遍历。错误只来自 `fclosureEncodingSize` 的 `error.InvalidBytecode`。经 `surface.enterScopeRefreshSize`（`bytecode.zig:9569`）由 `compiler/resolve_variables.zig:788` 调用，用来 `prepareLegacyWrite` 预留窗口——它与 `writeEnterScopeRefresh` 必须逐字节相等，否则 Resolver 报 `error.InvalidBytecode`。


### `binding_rules.writeEnterScopeRefresh` (`src/compiler/binding_rules.zig:861`)

- **签名**：`fn writeEnterScopeRefresh(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) Error!void`。
- **作用**：写出 enter_scope 降低（TDZ rearm / 函数声明 init）。
- **实现**：与 size 函数同一遍历、同样的 `scope_level != scope` 停止条件与 arguments 跳过；函数声明写 `emitFClosure` + `writeSelectedLocForm(put_loc)`，其余词法写 `set_loc_uninitialized <u16>`（3 字节，小端）。
- **所有权 / 错误 / 调用**：只往预留窗口写，不分配；错误集同 `emitFClosure`。经 `surface.writeEnterScopeRefresh`（`bytecode.zig:9570`）由 `compiler/resolve_variables.zig:794` 调用（其 `run` 在 `:2229` 的 `enter_scope` 臂进入）。


### `binding_rules.leaveScopeCloseSize` (`src/compiler/binding_rules.zig:887`)

- **签名**：`fn leaveScopeCloseSize(ctx: *const JSContext, scope: i32) usize`。
- **作用**：OP_leave_scope：只 close 本 scope 声明的捕获局部。
- **实现**：沿 `fd.scopes[scope].first` / `scope_next` 走，`vd.scope_level != scope`（继承来的尾巴属于外层）立即停；每个 `is_captured` 槽记 3 字节（`close_loc <u16>`）。无 fd 或 scope 越界返回 0。
- **所有权 / 错误 / 调用**：不分配、无 error set；只数本作用域自己声明的 captured 局部。经 `surface.leaveScopeCloseSize`（`bytecode.zig:9571`）由 `compiler/resolve_variables.zig:804` 调用做容量预留。


### `binding_rules.writeLeaveScopeClose` (`src/compiler/binding_rules.zig:901`)

- **签名**：`fn writeLeaveScopeClose(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) void`。
- **作用**：写 close_loc 序列。
- **实现**：与 `leaveScopeCloseSize` 同一遍历、同样的 `scope_level != scope` 停止条件；每个 `is_captured` 槽写 `close_loc` + u16 局部下标（小端，3 字节）。
- **所有权 / 错误 / 调用**：只写 `close_loc` 序列到预留窗口，不分配、无 error set。经 `surface.writeLeaveScopeClose`（`bytecode.zig:9572`）由 `compiler/resolve_variables.zig:810` 调用（`run` 在 `:2237` 的 `leave_scope` 臂进入）。


### `binding_rules.lowerScopeVarOpClosure` (`src/compiler/binding_rules.zig:918`)

- **签名**：`fn lowerScopeVarOpClosure(op_id: u8) u8`。
- **作用**：scope_* → var_ref 族（含 check/init）。
- **实现**：switch。 分支覆盖：`scope_get_var_undef`、`scope_put_var`、`scope_put_var_init`。
- **所有权 / 错误 / 调用**：纯 opcode 映射，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7153`（`lowerScopeVarOpForClosure`）。


### `binding_rules.selectShortVarRef` (`src/compiler/binding_rules.zig:930`)

- **签名**：`fn selectShortVarRef(base_op: u8, idx: u16) ShortLocForm`。
- **作用**：var_ref 短形式：0..3 burned，否则 wide。
- **实现**：无 var_ref8。 分支覆盖：`get_var_ref`、`put_var_ref`、`set_var_ref`。
- **所有权 / 错误 / 调用**：纯查表，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7583`（`selectVarRefForm`）。


### `binding_rules.selectVarRefForm` (`src/compiler/binding_rules.zig:947`)

- **签名**：`fn selectVarRefForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm`。
- **作用**：允许短码则 selectShortVarRef。
- **实现**：包装。
- **所有权 / 错误 / 调用**：不分配、无 error set。私有，与 `selectLocForm` 一样是 size/writer 共用的单一定价点，9 处调用方含 `bytecode.zig:8368`（`loweredScopeGetRefSize`）与 `:8519`（`writeLoweredScopeGetRef`）这样的配对。


### `binding_rules.selectShortArg` (`src/compiler/binding_rules.zig:952`)

- **签名**：`fn selectShortArg(base_op: u8, idx: u16) ShortLocForm`。
- **作用**：arg 短形式 0..3 / 否则 wide。
- **实现**：无 arg8。 分支覆盖：`get_arg`、`put_arg`。
- **所有权 / 错误 / 调用**：纯查表，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7604`（`selectArgForm`）。


### `binding_rules.selectArgForm` (`src/compiler/binding_rules.zig:968`)

- **签名**：`fn selectArgForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm`。
- **作用**：允许短码则 selectShortArg。
- **实现**：包装。
- **所有权 / 错误 / 调用**：不分配、无 error set。私有，调用方 `bytecode.zig:8200`（`planScopeVarAction`）、`:8248`（`planResolvedScopeVarAction`）、`:8359`/`:8490`（`loweredScopeGetRefSize` 与 `writeLoweredScopeGetRef` 的配对）。


### `binding_rules.lookupArg` (`src/compiler/binding_rules.zig:973`)

- **签名**：`fn lookupArg(ctx: *const JSContext, atom_id: u32) ?u16`。
- **作用**：当前函数参数表按 atom 查找。
- **实现**：转 `fd.findArg(atom_id)`（newest-first 线性查），返回 <0 即 null；无 `function_def` 也是 null。
- **所有权 / 错误 / 调用**：只读扫描 `fd.args`，不分配、无 error set。私有，调用方 `bytecode.zig:7757`（`resolveLocalOrArgImpl`）、`:8351`（`loweredScopeDeleteVarSize`）、`:8464`（`writeLoweredScopeDeleteVar`）。


### `binding_rules.lookupCurrentFunctionName` (`src/compiler/binding_rules.zig:985`)

- **签名**：`fn lookupCurrentFunctionName(ctx: *const JSContext, atom_id: u32) ?u16`。
- **作用**：词法/参数查找之后的命名函数表达式绑定（含参数环境激活时）。
- **实现**：只认 `fd.func_var_idx` 指的那一槽（qjs resolve_scope_var，quickjs.c:32975-32978）：下标越界、`var_name` 不符或 `var_kind != .function_name` 一律 null。参数作用域故意不链到函数体作用域，所以普通链走不到这一槽。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，调用方 `bytecode.zig:7763`（`resolveLocalOrArgImpl`）、`:8352`（`loweredScopeDeleteVarSize`）、`:8465`（`writeLoweredScopeDeleteVar`）。


### `binding_rules.lookupCurrentPseudoBinding` (`src/compiler/binding_rules.zig:994`)

- **签名**：`fn lookupCurrentPseudoBinding(ctx: *const JSContext, atom_id: atom.Atom) ?u16`。
- **作用**：this/new.target/home_object 等伪绑定。
- **实现**：先要求 `fd.has_this_binding`；再按 atom 选字段——`home_object`→`home_object_var_idx`、`this_active_func`→`this_active_func_var_idx`、`new_target`→`new_target_var_idx`、`this_`→`this_var_idx`，其余 atom 直接 null；下标为负/越界或该槽名字不符也返回 null。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7759`（`resolveLocalOrArgImpl`）。


### `binding_rules.lowerScopeVarOpArg` (`src/compiler/binding_rules.zig:1013`)

- **签名**：`fn lowerScopeVarOpArg(op_id: u8) ?u8`。
- **作用**：scope_* → arg 族；有些 op 不能降到 arg 则 null。
- **实现**：optional。 分支覆盖：`scope_get_var_checkthis`、`scope_put_var_init`。
- **所有权 / 错误 / 调用**：纯 opcode 映射，返回 null 表示该 op 没有 arg 形态，不分配、无 error set。私有，调用方 `bytecode.zig:8199`（`planScopeVarAction`，`.?` 解包）、`:8247`（`planResolvedScopeVarAction`，null 转 `error.InvalidBytecode`）。


### `binding_rules.resolveScopeVarLookupImpl` (`src/compiler/binding_rules.zig:1034`)

- **签名**：`inline fn resolveScopeVarLookupImpl( comptime trust_final_scope_links: bool, ctx: *const JSContext, atom_id: u32, scope_level: i32, ) ScopeVarLookup`。
- **作用**：带终端哨兵的词法链查找（保留 ARG_SCOPE_END）。
- **实现**：沿 `fd.scopes[scope_level].first` / `scope_next` 找同名槽；链走完后若终端哨兵是 `arg_scope_end` 就只回 `argument_environment_only = true`（压掉 find_var 那一遍），否则再对 `fd.vars` 做 newest-first 的 `scope_level == 0` 扫描（qjs find_var）。`trust_final_scope_links` 是 comptime 参数：真则只断言 `scope_link_proof != .none`，假则每步做下标与 `visited` 上界检查。
- **所有权 / 错误 / 调用**：`inline`，不分配、无 error set；`trust_final_scope_links` 为假时用 `visited` 计数 + 下标上界防住损坏的 `scope_next` 链，为真时改成 `scope_link_proof` 断言。私有，两个实例化站点 `bytecode.zig:7710`（`resolveScopeVarImpl`）、`:7745`（`resolveLocalOrArgImpl`）。


### `binding_rules.resolveScopeVarImpl` (`src/compiler/binding_rules.zig:1061`)

- **签名**：`inline fn resolveScopeVarImpl( comptime trust_final_scope_links: bool, ctx: *const JSContext, atom_id: u32, scope_level: i32, ) ?u16`。
- **作用**：只返回局部下标的包装。
- **实现**：丢弃哨兵。 返回 `resolveScopeVarLookupImpl( trust_final_scope_links, ctx, atom_id, scope_level, ).local`。
- **所有权 / 错误 / 调用**：`inline` 薄包装，不分配、无 error set。私有，唯一调用方 `bytecode.zig:7719`（`resolveScopeVar`）。


### `binding_rules.resolveScopeVar` (`src/compiler/binding_rules.zig:1075`)

- **签名**：`inline fn resolveScopeVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16`。
- **作用**：不信任缓存的 resolveScopeVarImpl。
- **实现**：trust=false。 返回 `resolveScopeVarImpl(false, ctx, atom_id, scope_level)`。
- **所有权 / 错误 / 调用**：`inline`，不分配、无 error set，返回借来的局部下标。私有，调用方 `bytecode.zig:8348`（`loweredScopeDeleteVarSize`）、`:8453`（`writeLoweredScopeDeleteVar`）——正是一对 size/writer。


### `binding_rules.resolveLocalOrArgImpl` (`src/compiler/binding_rules.zig:1095`)

- **签名**：`inline fn resolveLocalOrArgImpl( comptime trust_final_scope_links: bool, ctx: *const JSContext, atom_id: u32, scope_level: i32, ) ?LocalOrArg`。
- **作用**：局部或参数槽——qjs `resolve_scope_var` 的「本函数」那一半。
- **实现**：先跑 `resolveScopeVarLookupImpl`，命中即 `.local`；否则按固定顺序补查：仅当哨兵不是 ARG_SCOPE_END 才查形参（`lookupArg` → `.arg`），再 `lookupCurrentPseudoBinding`、`arguments`（`fd.arguments_var_idx`）、`lookupCurrentFunctionName`，全 miss 返回 null。
- **所有权 / 错误 / 调用**：`inline`，不分配、无 error set。私有，两个实例化站点 `bytecode.zig:7768`（`resolveLocalOrArg`，trust=false）、`:9163`（`resolveBindingTopologyResultImpl`，按 comptime 参数传递）。


### `binding_rules.resolveLocalOrArg` (`src/compiler/binding_rules.zig:1124`)

- **签名**：`inline fn resolveLocalOrArg(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?LocalOrArg`。
- **作用**：trust=false 包装。
- **实现**：解析。 返回 `resolveLocalOrArgImpl(false, ctx, atom_id, scope_level)`。
- **所有权 / 错误 / 调用**：`inline`，不分配、无 error set。私有，9 处调用方，含 `bytecode.zig:8374`/`:8573`（`loweredScopeMakeRefSize` 与 `writeLoweredScopeMakeRef` 配对）、`:8744`（`markReferenceTakenBinding`）。


### `binding_rules.isEvalVarObjectAtom` (`src/compiler/binding_rules.zig:1135`)

- **签名**：`fn isEvalVarObjectAtom(atom_id: atom.Atom) bool`。
- **作用**：atom 是否 eval 变量对象名（`<var>` 或 `<arg_var>`）。
- **实现**：与 atom.ids.var_object 比较。 返回 `atom_id == atom.ids.arg_var_object or atom_id == atom_var_object`。
- **所有权 / 错误 / 调用**：纯 atom id 比较，不分配、无 error set。私有，调用方 `bytecode.zig:7783`（`isDynamicEnvObjectAtom`）、`:8808`（`resolveEvalGlobalVarTargets`）、`:8833`（`hasDirectEvalLexicalRedeclaration`）。


### `binding_rules.isDynamicEnvObjectAtom` (`src/compiler/binding_rules.zig:1139`)

- **签名**：`fn isDynamicEnvObjectAtom(atom_id: atom.Atom) bool`。
- **作用**：atom 是否 with/var_object 动态环境对象。
- **实现**：两个哨兵名。 返回 `isEvalVarObjectAtom(atom_id) or atom_id == atom.ids.with_object`。
- **所有权 / 错误 / 调用**：纯 atom id 比较，不分配、无 error set。私有，但和 `closureVarIsRuntimeVarRef` 一样被 namespace 外的 `FunctionDefImpl.addClosureVar`（`bytecode.zig:5785`）引用；其余 7 处在本 namespace（`:7794`、`:7932`、`:8049`、`:9136` 等）。


### `binding_rules.closureVarRangeHasDynamicEnvObjects` (`src/compiler/binding_rules.zig:1143`)

- **签名**：`fn closureVarRangeHasDynamicEnvObjects( fd: *const function_def_mod.FunctionDef, start: usize, ) bool`。
- **作用**：从 start 起的闭包行是否含动态 env 对象。
- **实现**：`start > fd.closure_var.len`（游标过期）先 fail closed 返回 true；否则线性扫尾段，行既是运行时 VarRef 又叫动态 env 名即 true。
- **所有权 / 错误 / 调用**：只读扫描，不分配、无 error set。经 `surface`（`bytecode.zig:9534`）由 `compiler/resolve_variables.zig:212`（`hasDynamicEnvObjects`）调用；namespace 内调用方 `bytecode.zig:7805`（`functionHasDynamicEnvObjects`）。


### `binding_rules.functionHasDynamicEnvObjects` (`src/compiler/binding_rules.zig:1156`)

- **签名**：`fn functionHasDynamicEnvObjects(ctx: *const JSContext) bool`。
- **作用**：本函数是否存在动态环境对象（`<var>` / `<arg_var>` / `<with>`）。
- **实现**：三段——`fd.var_object_idx >= 0` 或 `fd.arg_var_object_idx >= 0` 直接 true；再扫 `fd.vars` 找 `with_object` 名；最后 `closureVarRangeHasDynamicEnvObjects(fd, 0)` 全量扫闭包表。注意它**不**读 `closure_var_may_have_dynamic_env` 那个单调旗（那旗只服务 V2 的增量游标）。
- **所有权 / 错误 / 调用**：薄包装，不分配、无 error set。经 `surface`（`bytecode.zig:9533`）调用方只有 `compiler/resolve_variables.zig:2518`（`run` 末尾往 `Bytecode` 发布该标志），树内无其它调用点。


### `binding_rules.scopeUsesArgumentEnvironmentOnly` (`src/compiler/binding_rules.zig:1165`)

- **签名**：`fn scopeUsesArgumentEnvironmentOnly(fd: *const function_def_mod.FunctionDef, scope_level: i32) bool`。
- **作用**：该 scope 是否只看见参数环境。
- **实现**：先要求 `fd.has_parameter_expressions`（否则 false），再沿本 scope 链走到尽头，看终端哨兵是否正好是 `arg_scope_end`；链损坏（下标越界/超 `visited` 帽）保守返回 false。
- **所有权 / 错误 / 调用**：只读 scope 链，不分配、无 error set。经 `surface`（`bytecode.zig:9548`）由 `compiler/resolve_variables.zig:607`（`emitDynamicEnvProbes`）调用；namespace 内调用方 `bytecode.zig:8071`（`evalVarObjectProbePlan`），两处必须同判。


### `binding_rules.ClosureDynamicEnvProbeIterator.init` (`src/compiler/binding_rules.zig:2482`)

- **签名**：`fn init(ctx: *const JSContext, atom_id: atom.Atom) ClosureDynamicEnvProbeIterator`。
- **作用**：按名字建立「闭包行中的动态环境对象」遍历器：先找出第一个会遮蔽 `atom_id` 的静态闭包绑定，把它的下标定为 `stop_idx`，后续遍历只在该前缀内进行。
- **实现**：`ctx.function_def` 为空时返回 `.fd = null`、`stop_idx = 0` 的空迭代器。否则 `stop_idx` 先取 `fd.closure_var.len`，再线性扫 `fd.closure_var`：只有同时满足「不是 `isDynamicEnvObjectAtom` 的环境对象名 + `var_name == atom_id` + `varKind() != .catch_` + 不是 `closureVarIsGlobalFamily`」的行才终止探针链，命中即记下 `idx` 并 break。catch 行只在 catch 块活跃期可见、global/module 家族行是动态环境对象之后的兜底，因此都不终止。
- **所有权 / 错误 / 调用**：不分配、无 error set；返回值里的 `fd` 是借用的 `*const FunctionDef`，只在本次解析内有效。调用方是同文件的 `evalVarObjectProbePlan`（`src/bytecode.zig:8079`，审计口径的尺寸预言机）；发射侧走的是绑定已知的姊妹函数 `closureDynamicEnvProbeIteratorInitResolved`。


### `binding_rules.ClosureDynamicEnvProbeIterator.next` (`src/compiler/binding_rules.zig:1240`)

- **签名**：`fn next(self: *ClosureDynamicEnvProbeIterator) ?usize`。
- **作用**：吐出下一个需要发射 `dyn_env_probe` 的闭包行下标，即 `stop_idx` 之前所有指向 with/eval 变量对象的 `var_ref` 行。
- **实现**：`fd == null` 直接返回 null。循环 `next_idx < stop_idx`，取出 `fd.closure_var[idx]` 并前进游标；行不是 `closureVarIsRuntimeVarRef`（即不是真正的运行期 var_ref）或名字不是 `isDynamicEnvObjectAtom`（`eval` 变量对象族或 `with_object`）就跳过，否则返回该下标。走到 `stop_idx` 返回 null 结束。
- **所有权 / 错误 / 调用**：无 error set、不分配。经 `surface.closureDynamicEnvProbeIteratorNext` 由 `Resolver.emitDynamicEnvProbes`（`src/compiler/resolve_variables.zig:626`）驱动，每个返回的下标配一条 `evalVarObjectClosureProbe` 形状的探针指令；审计路径上由 `evalVarObjectProbePlan` 用同一遍历算出 `count`/`prefix_size`。


### `binding_rules.LocalWithProbeIterator.init` (`src/compiler/binding_rules.zig:2482`)

- **签名**：`fn init(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) LocalWithProbeIterator`。
- **作用**：建立「当前 scope 链上的 `with` 局部变量」遍历器，起点是 `scope_level` 这一层的第一个变量下标。
- **实现**：取 `ctx.function_def`；若为 null 或 `scope_level` 越界（负数或 `>= def.scopes.len`）则把 `next_var_idx` 置 `-1`，得到一个立刻结束的迭代器；否则取 `def.scopes[scope_level].first`。`atom_id` 原样存下，供 `next` 判定遮蔽。
- **所有权 / 错误 / 调用**：不分配、无 error set，`fd` 为借用指针。经 `surface.localWithProbeIteratorInit` 由 `Resolver.emitDynamicEnvProbes`（`src/compiler/resolve_variables.zig:594`）调用，同时也用于 `evalVarObjectProbePlan` 的尺寸预言机（`src/bytecode.zig:8060`）。


### `binding_rules.LocalWithProbeIterator.next` (`src/compiler/binding_rules.zig:1240`)

- **签名**：`fn next(self: *LocalWithProbeIterator) ?u16`。
- **作用**：沿 `scope_next` 链由内向外吐出每个 `with` 语句的局部环境槽下标，一旦先遇到同名静态绑定就提前停住。
- **实现**：`fd == null` 返回 null。循环以 `visited < fd.vars.len` 作防环上界，逐个取 `fd.vars[next_var_idx]` 并把游标推到 `vd.scope_next`：`vd.var_name == self.atom_id` 说明该名字在更内层已被静态绑定遮蔽，把游标钉成 `-1` 并返回 null；`vd.var_name == atom.ids.with_object` 则返回该槽下标。下标越界同样返回 null（失败关闭）。
- **所有权 / 错误 / 调用**：无 error set、不分配。经 `surface.localWithProbeIteratorNext` 驱动 `Resolver.emitDynamicEnvProbe(.{ .with_local = idx }, ...)`（`src/compiler/resolve_variables.zig:595`）。


### `binding_rules.staticBindingStopsDynamicEnvProbes` (`src/compiler/binding_rules.zig:1259`)

- **签名**：`fn staticBindingStopsDynamicEnvProbes(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) bool`。
- **作用**：静态绑定挡住 with/eval 探针链。
- **实现**：按名字重发现，三道：① 顶层模块/全局词法闭包行（`lookupTopLevelModuleLexicalClosureVar`）直接 true；② 本函数是 eval 且同名闭包行的 kind 是 `.catch_` → true（直接 eval 看见的 catch 参数就是它的活跃词法环境）；③ 否则 `resolveLocalOrArg`：`.arg` → true，`.local` 则该槽是 `catch_` 且其 scope 不在引用点的祖先链上（`scopeContainsBinding`）→ false，其余看 `!isEvalNonLexicalLocal`。解析不到绑定返回 false。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。曾经导出到 `surface`，但 `resolve_variables.zig` 一次都没用，该导出已删；现在唯一调用方是 namespace 内的 `evalVarObjectProbePlan`。


### `binding_rules.scopeVarDynamicProbeEligible` (`src/compiler/binding_rules.zig:1286`)

- **签名**：`fn scopeVarDynamicProbeEligible(atom_id: atom.Atom, scope_level: i32) bool`。
- **作用**：该 atom+scope 是否允许动态探针。
- **实现**：伪绑定等排除。 返回 `scope_level >= 0 and atom_id != atom.ids.ret and !isDynamicEnvObjectAtom(atom_id)`。
- **所有权 / 错误 / 调用**：纯谓词，不分配、无 error set。经 `surface`（`bytecode.zig:9539`）调用方只有 `compiler/resolve_variables.zig:566`（`needsDynamicEnvProbes`）。


### `binding_rules.resolvedBindingStopsDynamicEnvProbes` (`src/compiler/binding_rules.zig:1295`)

- **签名**：`fn resolvedBindingStopsDynamicEnvProbes( ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32, binding: ScopeVarBinding, ) bool`。
- **作用**：已有拓扑结果时的挡住判断，不再按名重找。
- **实现**：四臂——`.arg` 恒 true；`.local` 与 `staticBindingStopsDynamicEnvProbes` 的局部臂同款（catch 槽不在祖先链上 → false，否则 `!isEvalNonLexicalLocal`）；`.closure` 只在「scope 0 的同名 `module_decl`/`global_decl` 词法行」或「本函数是 eval 且该行 kind 为 `.catch_`」时 true；`.global` 恒 false。越界/无 fd 都 false。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。经 `surface`（`bytecode.zig:9547`）调用方只有 `compiler/resolve_variables.zig:600`（`emitDynamicEnvProbes`）。


### `binding_rules.closureDynamicEnvProbeIteratorInitResolved` (`src/compiler/binding_rules.zig:1330`)

- **签名**：`fn closureDynamicEnvProbeIteratorInitResolved( ctx: *const JSContext, binding: ScopeVarBinding, ) ClosureDynamicEnvProbeIterator`。
- **作用**：用已解析绑定初始化闭包探针迭代器。
- **实现**：`stop_idx` 默认取 `fd.closure_var.len`（整表都要探）；只有绑定是 `.closure`、下标在界内、且该行既不是动态 env 名、kind 不是 `.catch_`、也不属 global 族时，才把 `stop_idx` 收到 `ref_idx`——即只探被它遮蔽之前的前缀。其余绑定形态不收窄。
- **所有权 / 错误 / 调用**：返回按值的迭代器，内部只持借来的 `*const FunctionDef` 和下标，不分配、无 error set。经 `surface`（`bytecode.zig:9544`）调用方只有 `compiler/resolve_variables.zig:625`（`emitDynamicEnvProbes`），配套 `next` 也从 surface 取。


### `binding_rules.scopeContainsBinding` (`src/compiler/binding_rules.zig:1351`)

- **签名**：`fn scopeContainsBinding( fd: *const function_def_mod.FunctionDef, reference_scope: i32, binding_scope: i32, ) bool`。
- **作用**：binding_scope 是否在 reference_scope 的祖先链上。
- **实现**：任一参数为负即 false；从 `reference_scope` 沿 `fd.scopes[].parent` 上溯，等于 `binding_scope` 返回 true；下标越界或 `visited` 超过 `fd.scopes.len` 兜底 false。
- **所有权 / 错误 / 调用**：只读 scope 父链，不分配、无 error set。私有，调用方 `bytecode.zig:7921`（`staticBindingStopsDynamicEnvProbes`）、`:7951`（`resolvedBindingStopsDynamicEnvProbes`）。


### `binding_rules.EvalVarObjectProbeKind.matches` (`src/compiler/binding_rules.zig:1373`)

- **签名**：`fn matches(self: EvalVarObjectProbeKind, op_id: u8) bool`。
- **作用**：判断某个 `scope_*` 占位 opcode 是否属于本 probe kind，用来确认调用方传进来的 kind 和实际待降级的指令一致。
- **实现**：对 `self` 做 switch：`.read` 同时接受 `scope_get_var` 与 `scope_get_var_undef`（`typeof` 形态），`.delete` 对 `scope_delete_var`，`.put` 对 `scope_put_var`，`.get_ref` 对 `scope_get_ref`，`.make_ref` 对 `scope_make_ref`。
- **所有权 / 错误 / 调用**：纯函数、无 error set。只被同文件的 `evalVarObjectProbePlan`（`src/bytecode.zig:8049`）用作首道守卫：不匹配就直接返回 null 表示无需探针。


### `binding_rules.EvalVarObjectProbeKind.wireKind` (`src/compiler/binding_rules.zig:1383`)

- **签名**：`fn wireKind(self: EvalVarObjectProbeKind) opcode.dyn_env.ProbeKind`。
- **作用**：把解析期内部枚举翻成写进 `dyn_env_probe` 指令操作数的 `opcode.dyn_env.ProbeKind`，让运行期知道探到属性后该读、删、写还是取引用。
- **实现**：五个成员一一对应映射（`read`/`delete`/`put`/`get_ref`/`make_ref`），没有别的逻辑；两套枚举分开是为了让线上编码可以独立演化。
- **所有权 / 错误 / 调用**：纯函数、无 error set。经 `surface.scopeVarProbeWireKind` 由 `src/compiler/resolve_variables.zig:1692`（普通 scope var 降级）与 `:1750`（`scope_delete_var` 路径）调用，结果直接交给 `emitDynamicEnvProbes`。


### `binding_rules.evalVarObjectProbePlan` (`src/compiler/binding_rules.zig:1399`)

- **签名**：`fn evalVarObjectProbePlan( ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32, op_id: u8, kind: EvalVarObjectProbeKind, ) ?EvalVarObjectProbePlan`。
- **作用**：为 eval 变量对象规划 dyn_env_probe 链（审计口径的尺寸预言机，与 `Resolver.emitDynamicEnvProbes` 的发射顺序一一对应）。
- **实现**：先过守卫——`kind.matches(op_id)` 不符、`scope_level < 0`、atom 本身是动态 env 名、atom 是 `ret`（eval 完成值是帧内槽，永不查 with/变量对象）都返回 null。随后按固定顺序累加 `count` 与 `prefix_size`（每项 = 访问器字节 + `opcode.sizeOf(dyn_env_probe)`）：`LocalWithProbeIterator` 的 with 局部 → 若 `staticBindingStopsDynamicEnvProbes` 挡住则就此收尾 → `fd.var_object_idx`（且非「只见参数环境」）→ `fd.arg_var_object_idx` → `ClosureDynamicEnvProbeIterator` 的闭包行。`count == 0` 返回 null。
- **所有权 / 错误 / 调用**：返回按值的计划体，不分配、无 error set（不可探测时返回 null）。`prefix_size` 就是调用方要预留的字节数。经 `surface`（`bytecode.zig:9538`）由 `compiler/resolve_variables.zig:1366`（`planMakeRefFold`）、`:1670`（`lowerScopeVar`）、`:1730`（`lowerScopeRef`）等 4 处调用；namespace 内还有 `bytecode.zig:8294`（`planScopeVarLowering`）。


### `binding_rules.ScopeVarAction.size` (`src/compiler/binding_rules.zig:1450`)

- **签名**：`fn size(self: ScopeVarAction) usize`。
- **作用**：报出这条已选定动作最终要写多少字节码字节，供 v2 resolver 先预留缓冲再写。
- **实现**：直接返回 `self.selected.size`——`ShortLocForm` 在选型时就把总长（短形式 1 字节、u8 操作数 2 字节、u16 操作数 3 字节，`throw_error` 6 字节）算好了，这里不重算。
- **所有权 / 错误 / 调用**：纯 getter、无 error set。经 `surface.scopeVarActionSize` 由 `Resolver.writeScopeVarAction`（`src/compiler/resolve_variables.zig:447`）调用，和 `atomCount` 一起喂给 `prepareLegacyWrite`。


### `binding_rules.ScopeVarAction.atomCount` (`src/compiler/binding_rules.zig:1454`)

- **签名**：`fn atomCount(self: ScopeVarAction) usize`。
- **作用**：报出这条动作会往 atom 操作数表里追加几个 atom，用于预留 atom 侧缓冲和 atom 引用计数对账。
- **实现**：只有 `throw_error` 形态（只读赋值抛 TypeError）会把变量名写进 atom 操作数表，所以返回 `@intFromBool(self.selected.op_id == opcode.op.throw_error)`，其余形态恒为 0。
- **所有权 / 错误 / 调用**：纯 getter、无 error set。经 `surface.scopeVarActionAtomCount` 由 `Resolver.writeScopeVarAction`（`src/compiler/resolve_variables.zig:448`）以及 `src/compiler/resolve_variables.zig:1412`-`1413` 的复合赋值快路径判定（get/put 动作都不带 atom 才允许走紧凑写法）使用。


### `binding_rules.ScopeVarAction.form` (`src/compiler/binding_rules.zig:1458`)

- **签名**：`fn form(selected: ShortLocForm, index: u16) ScopeVarAction`。
- **作用**：把一个已选好的 `ShortLocForm`（opcode + 操作数宽度）和它的索引打包成 `ScopeVarAction`，是普通局部/参数/闭包/全局四类降级结果的统一构造口。
- **实现**：单行聚合初始化 `.{ .selected = selected, .index = index }`，不做校验；`selected` 由 `selectLocForm`/`selectArgForm`/`selectVarRefForm` 之类的选型函数产出。
- **所有权 / 错误 / 调用**：纯构造、无 error set。调用方集中在同文件 `globalScopeVarAction`、`closureScopeVarAction`、`planScopeVarAction`、`planResolvedScopeVarAction`（`src/bytecode.zig:8158`、`8181`、`8200`-`8226`、`8248`-`8271`）。


### `binding_rules.ScopeVarAction.throwReadonly` (`src/compiler/binding_rules.zig:1462`)

- **签名**：`fn throwReadonly() ScopeVarAction`。
- **作用**：构造「写只读绑定 → 运行期抛 TypeError」这条动作：给 `const`、函数名绑定等不可写目标降级成 `throw_error`。
- **实现**：返回 `op_id = opcode.op.throw_error`、`size = throw_error_instr_size`（6 字节：1 字节 opcode + 4 字节 atom + 1 字节 error_type）、`operand_size = 0` 的定值；`index` 留默认 0，真正的变量名由 `writeScopeVarAction` → `writeThrowVarReadOnly` 以 `JS_THROW_VAR_RO`（对应 quickjs.c:18334）写入。
- **所有权 / 错误 / 调用**：纯构造、无 error set。由同文件 `closureScopeVarAction`（`src/bytecode.zig:8175`）、`planScopeVarAction`（`:8210`）和 `planResolvedScopeVarAction`（`:8252`）在检出只读目标时调用。


### `binding_rules.ScopeVarAction.dropAction` (`src/compiler/binding_rules.zig:1470`)

- **签名**：`fn dropAction() ScopeVarAction`。
- **作用**：构造「丢弃栈顶值」这条动作：给写入 `arguments`、`this` 之类结果被规范忽略的目标降级成单字节 `drop`。
- **实现**：返回 `op_id = opcode.op.drop`、`size = 1`、`operand_size = 0` 的定值；`writeScopeVarAction` 对它走专门的一字节分支，不经 `writeSelectedLocForm`。
- **所有权 / 错误 / 调用**：纯构造、无 error set。由同文件 `closureScopeVarAction`（`src/bytecode.zig:8178`）、`planScopeVarAction`（`:8213`）和 `planResolvedScopeVarAction`（`:8255`）调用。


### `binding_rules.scopeVarProbeKind` (`src/compiler/binding_rules.zig:1479`)

- **签名**：`fn scopeVarProbeKind(op_id: u8, no_dynamic_env: bool) ?EvalVarObjectProbeKind`。
- **作用**：scope op → EvalVarObjectProbeKind；no_dynamic_env 可关掉。
- **实现**：`scope_put_var` → `no_dynamic_env` 为真时 null（LHS 已选好环境），否则 `.put`；`scope_get_var` / `scope_get_var_undef` → `.read`（不看 `no_dynamic_env`）；其余 opcode 一律 null。
- **所有权 / 错误 / 调用**：纯 opcode→ProbeKind 映射，不分配、无 error set。经 `surface`（`bytecode.zig:9536`）由 `compiler/resolve_variables.zig:1668`（`lowerScopeVar`）调用；namespace 内 `bytecode.zig:8293`（`planScopeVarLowering`）。


### `binding_rules.globalScopeVarAction` (`src/compiler/binding_rules.zig:1489`)

- **签名**：`fn globalScopeVarAction(ctx: *const JSContext, atom_id: atom.Atom, op_id: u8) Error!ScopeVarAction`。
- **作用**：未解析到局部时的全局动作。
- **实现**：`lookupGlobalClosureVar` 取行（缺失即 `ClosureVarNotFound`），动作是 `lowerScopeVarOpGlobal` 的 3 字节 var_ref 形式。 错误臂：`error.ClosureVarNotFound`。
- **所有权 / 错误 / 调用**：只读规划，返回按值的 `ScopeVarAction`，不分配；闭包表里没有对应全局行时 `error.ClosureVarNotFound`（沿 `resolve_variables.Error` 上抛，不是 JS 异常）。私有，三个调用点全在 `planScopeVarAction`：`bytecode.zig:8193`（scope_level<0）、`:8204`（sloppy-eval 非词法局部改走全局）、`:8232`（全 miss 的兜底）。


### `binding_rules.closureScopeVarAction` (`src/compiler/binding_rules.zig:1501`)

- **签名**：`fn closureScopeVarAction( ctx: *const JSContext, atom_id: atom.Atom, ref_idx: u16, op_id: u8, ) ScopeVarAction`。
- **作用**：已有闭包下标时的动作（check/readonly/short）。
- **实现**：三段——`scope_put_var` 且 `closureVarWriteThrowsReadOnly` → `ScopeVarAction.throwReadonly()`；`scope_put_var` 且该行 kind 是 `function_name` → `dropAction()`（写被规范忽略）；否则 `lowerScopeVarOpForClosure` 选最终 opcode，再交 `selectVarRefForm` 定形。
- **所有权 / 错误 / 调用**：只读规划，返回按值的 `ScopeVarAction`，不分配、无 error set。私有，四个调用点在 `bytecode.zig:8195`/`:8207`/`:8230`（`planScopeVarAction`）与 `:8270`（`planResolvedScopeVarAction`）。


### `binding_rules.planResolvedScopeVarAction` (`src/compiler/binding_rules.zig:1521`)

- **签名**：`fn planResolvedScopeVarAction( ctx: *const JSContext, atom_id: atom.Atom, op_id: u8, binding: ScopeVarBinding, ) Error!ScopeVarAction`。
- **作用**：qjs resolve_scope_var 的 opcode 半：对已有身份做投影。
- **实现**：不重新发现绑定。 分支覆盖：`arg`、`local`、`closure`、`global`。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：不分配；`ctx` 是 `*const`，本函数不会新建 closure 行。`lowerScopeVarOpArg` 返回 null 时给 `error.InvalidBytecode`，沿 `resolve_variables.Error` 上抛（`bytecode.zig:10825` 的 switch 收敛成 `FinalizeError`），不是 JS 异常。经 `surface`（`bytecode.zig:9529`）由 `compiler/resolve_variables.zig:1400`、`:1406`（`planMakeRefFold`）调用。


### `binding_rules.writeScopeVarAction` (`src/compiler/binding_rules.zig:1564`)

- **签名**：`fn writeScopeVarAction( func: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: atom.Atom, action: ScopeVarAction, ) Error!void`。
- **作用**：按 ScopeVarAction 写出最终字节与 atom ledger。
- **实现**：`throw_error` 臂走 `writeThrowVarReadOnly`（并占一个 atom ledger 位），`drop` 臂写一字节，其余（含全局 var_ref 形式）走 `writeSelectedLocForm`；先做输出缓冲边界检查。
- **所有权 / 错误 / 调用**：只往调用方预留的 `output` / `output_atoms` 窗口写，不分配、不 retain atom（只复制 id）；窗口不足或 atom ledger 满 → `error.InvalidBytecode`。经 `surface.writeScopeVarAction`（`bytecode.zig:9532`）由 `compiler/resolve_variables.zig:455`（`Resolver.writeScopeVarAction`，自身再被 `:479`、`:981`、`:1805` 调用）驱动。


### `binding_rules.evalVarObjectProbeAccessorSize` (`src/compiler/binding_rules.zig:1585`)

- **签名**：`fn evalVarObjectProbeAccessorSize(ctx: *const JSContext, probe: EvalVarObjectProbe) usize`。
- **作用**：取出 eval 变量对象的访问器字节数。
- **实现**：loc vs var_ref。 分支覆盖：`with_local`、`with_ref`。
- **所有权 / 错误 / 调用**：纯定价，不分配、无 error set；必须与 `writeEvalVarObjectProbeAccessor` 相等。经 `surface`（`bytecode.zig:9540`）由 `compiler/resolve_variables.zig:513`（`emitDynamicEnvProbe`）调用做预留；namespace 内由 `evalVarObjectProbePlan` 累加 4 次（`bytecode.zig:8063`–`:8082`）。


### `binding_rules.evalVarObjectProbeIsWith` (`src/compiler/binding_rules.zig:1592`)

- **签名**：`fn evalVarObjectProbeIsWith(probe: EvalVarObjectProbe) bool`。
- **作用**：该探针是否 with（@@unscopables）。
- **实现**：看对象种类。 返回 `switch (probe) { .with_local, .with_ref => true, .local, .ref => false, }`。 分支覆盖：`with_ref`、`ref`。
- **所有权 / 错误 / 调用**：纯 tag 判定，不分配、无 error set。经 `surface`（`bytecode.zig:9550`）调用方只有 `compiler/resolve_variables.zig:534`（拼 `dyn_env` flags 字节）。


### `binding_rules.evalVarObjectClosureProbe` (`src/compiler/binding_rules.zig:1599`)

- **签名**：`fn evalVarObjectClosureProbe(cv: function_def_mod.ClosureVar, idx: usize) EvalVarObjectProbe`。
- **作用**：闭包行变成探针描述。
- **实现**：下标+类型。 返回 `if (cv.var_name == atom.ids.with_object) .{ .with_ref = @intCast(idx) } else .{ .ref = @intCast(idx) }`。
- **所有权 / 错误 / 调用**：按值构造，不分配、无 error set。经 `surface`（`bytecode.zig:9549`）由 `compiler/resolve_variables.zig:631` 调用；namespace 内 `bytecode.zig:8082`（`evalVarObjectProbePlan`）用同一构造做定价。


### `binding_rules.loweredScopeDeleteVarSize` (`src/compiler/binding_rules.zig:1606`)

- **签名**：`fn loweredScopeDeleteVarSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize`。
- **作用**：scope_delete_var 降低后的长度。
- **实现**：解析到局部时，sloppy-eval var 是 5（`delete_var`+atom），否则 1（`push_false`）；参数 / 函数名 / 闭包也是 1；全都没有则 5。
- **所有权 / 错误 / 调用**：纯定价，不分配、无 error set。经 `surface`（`bytecode.zig:9552`）调用方只有 `compiler/resolve_variables.zig:682`，与 `writeLoweredScopeDeleteVar` 构成预留/写入契约。


### `binding_rules.loweredScopeGetRefSize` (`src/compiler/binding_rules.zig:1616`)

- **签名**：`fn loweredScopeGetRefSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize`。
- **作用**：scope_get_ref 降低长度。
- **实现**：1 字节 `undefined` 占位加取值指令：arg 用 `selectArgForm`，local 的 sloppy-eval var 与词法槽各算 3 字节，其余 `selectLocForm`；闭包用 `selectVarRefForm`；都没有则 1+3 的全局形式。 分支覆盖：`arg`、`local`。
- **所有权 / 错误 / 调用**：纯定价，不分配、无 error set。经 `surface`（`bytecode.zig:9554`）调用方只有 `compiler/resolve_variables.zig:709`，对应写手 `writeLoweredScopeGetRef`。


### `binding_rules.loweredScopeMakeRefSize` (`src/compiler/binding_rules.zig:1632`)

- **签名**：`fn loweredScopeMakeRefSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize`。
- **作用**：scope_make_ref 降低长度。
- **实现**：arg → 7（`make_arg_ref` + atom + u16）。local → sloppy-eval var 5（`make_var_ref`）、只读 6（`throw_error`）、函数名 `1 + get_loc 形长 + 5 + 5`（dummy `{name: binding}` 对象）、其余 7。闭包 → 只读 6、函数名 `1 + get_var_ref 形长 + 5 + 5`、其余 7。全 miss → 5。
- **所有权 / 错误 / 调用**：纯定价，不分配、无 error set。经 `surface`（`bytecode.zig:9556`）调用方只有 `compiler/resolve_variables.zig:729`，对应写手 `writeLoweredScopeMakeRef`。


### `binding_rules.loweredScopeMakeRefAtomCount` (`src/compiler/binding_rules.zig:1654`)

- **签名**：`fn loweredScopeMakeRefAtomCount(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize`。
- **作用**：make_ref 降低消耗的 atom 数。
- **实现**：只有走 `writeFunctionNameDummyRef` 的两条臂（非 eval-var、非只读的函数名局部；非只读的 `function_name` 闭包行）各消耗 2 个 atom（`define_field` + `push_atom_value`），其余形态都是 1。
- **所有权 / 错误 / 调用**：纯计数，不分配、无 error set；结果是 `product.atom_operands` 要预留的槽数。经 `surface`（`bytecode.zig:9557`）调用方只有 `compiler/resolve_variables.zig:730`。


### `binding_rules.writeEvalVarObjectProbeAccessor` (`src/compiler/binding_rules.zig:1674`)

- **签名**：`fn writeEvalVarObjectProbeAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, probe: EvalVarObjectProbe) Error!void`。
- **作用**：写出取变量对象的 get_loc/get_var_ref。
- **实现**：`.local`/`.with_local` 用 `selectLocForm(get_loc, idx)`，`.ref`/`.with_ref` 用 `selectVarRefForm(get_var_ref, idx)`；两臂都先按 `form.size` 校验窗口（不够返回 `error.InvalidBytecode`），再写 opcode 与 0/1/2 字节的小端操作数。
- **所有权 / 错误 / 调用**：只往预留窗口写，不分配；窗口不够返回 `error.InvalidBytecode`（而非越界 panic），沿 `resolve_variables.Error` 上抛。经 `surface`（`bytecode.zig:9541`）调用方只有 `compiler/resolve_variables.zig:526`（`emitDynamicEnvProbe`）。


### `binding_rules.writeLoweredScopeDeleteVar` (`src/compiler/binding_rules.zig:1702`)

- **签名**：`fn writeLoweredScopeDeleteVar( ctx: *const JSContext, _: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32, scope_level: i32, ) Error!void`。
- **作用**：写出 delete 降低：静态可见的绑定写 `push_false`，只有 sloppy-eval var 与完全未绑定的名字写 `delete_var`。
- **实现**：`delete_var` 臂同时登记 atom ledger。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：只往预留窗口写代码并把 atom id 复制进 `output_atoms` 账本（不 retain）；不分配。签名带 `Error!void`，但函数体内没有任何 `try`/`return error`，实际不会失败。经 `surface`（`bytecode.zig:9553`）由 `compiler/resolve_variables.zig:690` 调用（`lowerScopeRef` 在 `:1758` 进入）。


### `binding_rules.writeLoweredScopeGetRef` (`src/compiler/binding_rules.zig:1738`)

- **签名**：`fn writeLoweredScopeGetRef( ctx: *JSContext, output: []u8, out_idx: *usize, atom_id: u32, scope_level: i32, ) Error!void`。
- **作用**：写出 get_ref 降低。
- **实现**：先写一字节 `undefined` 占位，再按 arg / local（sloppy-eval var 走 `emitGlobalVarOp`、词法走 `get_loc_check`、其余短 loc）/ 闭包 / 全局写取值指令；全局臂只查已登记的闭包行，不新建。 分支覆盖：`arg`、`local`。 内部 `try` 传播错误。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：收 `*JSContext`（可变）只因为要传给 `emitGlobalVarOp`；本函数不分配、不新建 closure 行，缺行即 `error.ClosureVarNotFound`。经 `surface`（`bytecode.zig:9555`）由 `compiler/resolve_variables.zig:714` 调用（`lowerScopeRef` 在 `:1760` 进入）。


### `binding_rules.writeFunctionNameDummyRef` (`src/compiler/binding_rules.zig:1795`)

- **签名**：`fn writeFunctionNameDummyRef( _: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32, get_form: ShortLocForm, binding_idx: u16, ) void`。
- **作用**：sloppy 函数名：造一次性 `{name: binding}` 引用对象，赋值改属性不改绑定（qjs resolve_scope_var，quickjs.c:33012-33024、33310-33322）。
- **实现**：定长 11+ 字节序列——`object`（1）、调用方给的 `get_form` 取出绑定值（`writeSelectedLocForm`，1/2/3 字节）、`define_field <atom:u32>`（5）、`push_atom_value <atom:u32>`（5）；后两条各往 atom 账本登记一次同一个 atom。
- **所有权 / 错误 / 调用**：只往预留窗口写，并把 atom id 复制进 `output_atoms` 账本（不 retain）。不分配、无 error set。私有，调用方 `bytecode.zig:8592`、`:8615`，都在 `writeLoweredScopeMakeRef` 内。


### `binding_rules.writeLoweredScopeMakeRef` (`src/compiler/binding_rules.zig:1822`)

- **签名**：`fn writeLoweredScopeMakeRef( ctx: *const JSContext, func: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32, scope_level: i32, ) Error!void`。
- **作用**：写出 make_ref 降低。
- **实现**：arg → `make_arg_ref`；local → sloppy-eval var 走 `make_var_ref`、const 走 `throw_error`、函数名走 `writeFunctionNameDummyRef`、其余 `make_loc_ref`；闭包同构（只读 throw / dummy / `make_var_ref_ref`）；都没有则 `make_var_ref`。 分支覆盖：`arg`、`local`。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：只往预留窗口写；`ctx` 是 `*const`，不新建 closure 行、不分配。atom 只复制 id 进账本。错误集见签名（实际由内部的全局臂给出 `ClosureVarNotFound`）。经 `surface`（`bytecode.zig:9558`）由 `compiler/resolve_variables.zig:737` 调用（`lowerScopeMakeRef` 在 `:1870` 进入）。


### `binding_rules.isLexicalLocal` (`src/compiler/binding_rules.zig:1904`)

- **签名**：`fn isLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool`。
- **作用**：该局部是否 let/const（需要 TDZ 变体）。var 槽 false。
- **实现**：无 `function_def` 或 `loc_idx` 越界一律 false，否则直接读 `fd.vars[loc_idx].is_lexical`。
- **所有权 / 错误 / 调用**：只读 VarDef 标志，不分配、无 error set。私有，调用方 `bytecode.zig:8362`（`loweredScopeGetRefSize`）、`:8502`（`writeLoweredScopeGetRef`）、`:8727`（`localLexicalAccessNeedsCheck`）。


### `binding_rules.isEvalNonLexicalLocal` (`src/compiler/binding_rules.zig:1910`)

- **签名**：`fn isEvalNonLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool`。
- **作用**：eval 里的非词法局部（var）——这种槽要降级成动态 eval 绑定（全局形态）。
- **实现**：层层否决：不是直接/间接 eval 单元（`fd.is_direct_eval` / `fd.is_indirect_eval` / `bytecodeFunctionIsEval`）→ false；strict（`fd.is_strict_mode` 或 `ctx.function.flags.is_strict`）→ false；下标越界 → false；槽名是 `<ret>` 或伪绑定（`isPseudoBindingAtom`）→ false；`scope_level != 0` 或 `is_lexical` → false；最后只认 `var_kind` 为 `normal`/`function_decl`/`new_function_decl`。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，是本 namespace 用得最多的谓词之一（12 处），含 `bytecode.zig:8349`/`:8454`、`:8376`/`:8583` 这样的 size/writer 配对与 `:9209`（`resolveScopeVarBindingTopologyImpl`）。


### `binding_rules.bytecodeFunctionIsEval` (`src/compiler/binding_rules.zig:1934`)

- **签名**：`fn bytecodeFunctionIsEval(ctx: *const JSContext) bool`。
- **作用**：当前函数是否 eval。
- **实现**：FunctionDef 或 flags。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set；有 `function_def` 时以 `fd.is_direct_eval or fd.is_indirect_eval` 为准（解析期 FunctionBytecode 标志还没发布），只有无 fd 的合成调用方才回退到 `ctx.function.flags.is_direct_or_indirect_eval`。私有，调用方 `bytecode.zig:7909`（`staticBindingStopsDynamicEnvProbes`）、`:7967`（`resolvedBindingStopsDynamicEnvProbes`）、`:8657`（`isEvalNonLexicalLocal`）。


### `binding_rules.localIsFunctionName` (`src/compiler/binding_rules.zig:1944`)

- **签名**：`fn localIsFunctionName(ctx: *const JSContext, loc_idx: u16) bool`。
- **作用**：该局部是否函数表达式名。
- **实现**：无 fd 或下标越界 false，否则 `fd.vars[loc_idx].var_kind == .function_name`。
- **所有权 / 错误 / 调用**：只读 VarKind，不分配、无 error set。私有，调用方 `bytecode.zig:8212`（`planScopeVarAction`）、`:8380`（`loweredScopeMakeRefSize`）、`:8591`（`writeLoweredScopeMakeRef`）等 5 处。


### `binding_rules.localWriteThrowsReadOnly` (`src/compiler/binding_rules.zig:1953`)

- **签名**：`fn localWriteThrowsReadOnly(ctx: *const JSContext, loc_idx: u16) bool`。
- **作用**：const 局部或 strict 函数名写 → throw_error。
- **实现**：只看 `fd.vars[loc_idx].is_const`（无 fd/越界 false）——函数表达式名恰好在其定义函数是 strict 时才带 const，sloppy 名走 drop / dummy-ref 两条臂。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set；它为真时写手改发 `throw_error`，所以 size 侧必须同判。私有，调用方 `bytecode.zig:8209`（`planScopeVarAction`）、`:8378`（`loweredScopeMakeRefSize`）、`:8589`（`writeLoweredScopeMakeRef`）等 5 处。


### `binding_rules.lowerScopeVarOpLexical` (`src/compiler/binding_rules.zig:1970`)

- **签名**：`fn lowerScopeVarOpLexical(op_id: u8) u8`。
- **作用**：scope_* → loc_check 族；derived this 的 init 用 put_loc_check_init。
- **实现**：switch。 分支覆盖：`scope_get_var`、`scope_get_var_undef`、`scope_get_var_checkthis`、`scope_put_var`、`scope_put_var_init`。
- **所有权 / 错误 / 调用**：纯 opcode 映射，不分配、无 error set。私有，调用方 `bytecode.zig:8218`（`planScopeVarAction`）、`:8260`（`planResolvedScopeVarAction`）。


### `binding_rules.localLexicalAccessNeedsCheck` (`src/compiler/binding_rules.zig:1985`)

- **签名**：`fn localLexicalAccessNeedsCheck(ctx: *const JSContext, atom_id: atom.Atom, loc_idx: u16, op_id: u8) bool`。
- **作用**：普通词法读写要 TDZ check；scope_put_var_init 通常是裸 put_loc。
- **实现**：非词法局部直接 false；否则「op 不是 `scope_put_var_init`」或「atom 正好是 `this`」时为真——即只有派生构造器的 `this` 初始化保留 `put_loc_check_init`（quickjs.c:33068-33087）。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。私有，调用方 `bytecode.zig:8215`（`planScopeVarAction`）、`:8257`（`planResolvedScopeVarAction`）。


### `binding_rules.writeSelectedLocForm` (`src/compiler/binding_rules.zig:1990`)

- **签名**：`fn writeSelectedLocForm(output: []u8, out_idx: *usize, form: ShortLocForm, loc_idx: u16) void`。
- **作用**：按 ShortLocForm 写 loc 指令。
- **实现**：burned/u8/wide。 按 `switch` 分派。 小端写入 opcode 与立即数。
- **所有权 / 错误 / 调用**：只按已选好的 `ShortLocForm` 写 1–3 字节，不分配、无 error set；不再自行做 short 选择（选择在 `selectLocForm`）。私有，调用方 `bytecode.zig:7508`（`writeEnterScopeRefresh`）、`:8322`（`writeScopeVarAction`）、`:8548`（`writeFunctionNameDummyRef`）。


### `binding_rules.markReferenceTakenBinding` (`src/compiler/binding_rules.zig:2001`)

- **签名**：`fn markReferenceTakenBinding(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i16) Error!void`。
- **作用**：标记该绑定被引用（活性/捕获）。
- **实现**：无 `function_def` 或 `resolveLocalOrArg` 解析不到就静默返回；`.local` 且 `var_kind != .function_name` 走 `fd.captureLocal`（函数名那一臂由 dummy 引用对象持写目标，qjs 也不 capture），`.arg` 走 `fd.captureArg`；两者的错误一律折成 `error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**有副作用但不分配**：命中局部/参数时调 `fd.captureLocal`/`captureArg`，就地把 `is_captured` 置位并分配稳定的 `open_binding_idx`（`function_name` 类不捕获）。capture 的 `InvalidBytecode`/`BytecodeOverflow` 一律折成 `error.InvalidBytecode`。经 `surface`（`bytecode.zig:9559`）调用方只有 `compiler/resolve_variables.zig:1854`（`lowerScopeMakeRef`）。


### `binding_rules.functionIsStrict` (`src/compiler/binding_rules.zig:2018`)

- **签名**：`fn functionIsStrict(ctx: *const JSContext) bool`。
- **作用**：当前函数 strict。
- **实现**：flags。
- **所有权 / 错误 / 调用**：只读：有 FunctionDef 时读 `fd.is_strict_mode`，否则回退到 `ctx.function.flags.is_strict / runtime_strict`。不分配、无 error set。私有，唯一调用方 `bytecode.zig:8773`（`canOptimizeGlobalRefPutTail`）。


### `binding_rules.functionDeclaresGlobalVar` (`src/compiler/binding_rules.zig:2023`)

- **签名**：`fn functionDeclaresGlobalVar(ctx: *const JSContext, atom_id: u32) bool`。
- **作用**：该 atom 是否本函数声明的全局 var。
- **实现**：扫 global_vars。 循环扫描切片或字节码。
- **所有权 / 错误 / 调用**：只读扫描 `fd.global_vars`，不分配、无 error set。私有，唯一调用方 `bytecode.zig:8773`（`canOptimizeGlobalRefPutTail`）。


### `binding_rules.canOptimizeGlobalRefPutTail` (`src/compiler/binding_rules.zig:2031`)

- **签名**：`fn canOptimizeGlobalRefPutTail(ctx: *const JSContext, atom_id: u32) bool`。
- **作用**：能否折叠 make-ref 的 global put 尾。
- **实现**：非严格，**或**该名字是本函数声明的全局 var。 返回 `!functionIsStrict(ctx) or functionDeclaresGlobalVar(ctx, atom_id)`。
- **所有权 / 错误 / 调用**：只读，不分配、无 error set。经 `surface`（`bytecode.zig:9561`）调用方只有 `compiler/resolve_variables.zig:1396`（`planMakeRefFold`）。


### `binding_rules.closureVarIsGlobalFamily` (`src/compiler/binding_rules.zig:2035`)

- **签名**：`fn closureVarIsGlobalFamily(cv: function_def_mod.ClosureVar) bool`。
- **作用**：ClosureType 是否 global*。
- **实现**：枚举。 返回 `switch (cv.closureType()) { .global, .global_ref, .global_decl, .module_decl, .module_import => true, .local, .arg, .ref => false, }`。 分支覆盖：`module_import`、`ref`。
- **所有权 / 错误 / 调用**：纯 ClosureType 谓词，不分配、无 error set。私有，调用方 `bytecode.zig:7984`（`closureDynamicEnvProbeIteratorInitResolved`）、`:8825`（`hasDirectEvalLexicalRedeclaration`）、`:8971`（`findResolvedClosureBinding`）等 4 处。


### `binding_rules.resolveEvalGlobalVarTargets` (`src/compiler/binding_rules.zig:2045`)

- **签名**：`fn resolveEvalGlobalVarTargets(fd: *function_def_mod.FunctionDef) Error!void`。
- **作用**：按最终闭包顺序解析 eval hoist 目标。动态 env 对象与真绑定共走一条链。
- **实现**：逐条 `fd.global_vars` 填 `eval_target`：非 eval 函数一律 `.global`；eval 函数先默认 `.global`，再顺着 `fd.closure_var` 走第一条适用项——同名行即 `.{ .closure = idx }`（但 Annex B.3.4 的同名 simple catch 行，即 `gv.cpool_idx < 0` 且 kind 为 `catch_`，要跳过，让 hoist 落到动态变量对象），遇到 eval 变量对象名且是运行时 VarRef 则 `.{ .var_object = idx }`，两者都命中即 break。下标超 u16 → `error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**就地改写** `fd.global_vars[*].eval_target`，不分配、不新建 closure 行；下标超 u16 时 `error.InvalidBytecode`，沿 `resolve_variables.Error` 上抛。经 `surface`（`bytecode.zig:9574`）调用方只有 `compiler/resolve_variables.zig:2469`（`run` 在建 ctx 后立刻调用）。


### `binding_rules.hasDirectEvalLexicalRedeclaration` (`src/compiler/binding_rules.zig:2076`)

- **签名**：`fn hasDirectEvalLexicalRedeclaration( fd: *const function_def_mod.FunctionDef, gv: function_def_mod.GlobalVar, ) bool`。
- **作用**：direct eval 的 var 是否与词法冲突。
- **实现**：非 `is_direct_eval` 直接 false。顺 `fd.closure_var` 走：遇 global 族行就停（`add_global_variables` 把它们追加在尾，qjs 的校验走到这里为止，quickjs.c:34209-34215）；同名行——Annex B.3.4 的同名 simple catch（`gv.cpool_idx < 0` 且 kind `catch_`）continue 让外层词法仍能否决，否则返回该行的 `isLexical()`；遇 eval 变量对象名则 false。
- **所有权 / 错误 / 调用**：只读扫描 `fd.closure_var`，不分配、无 error set。返回真时调用方发的是运行时 `throw_error <name> JS_THROW_VAR_REDECL` 指令，不是解析期 SyntaxError。经 `surface`（`bytecode.zig:9575`）调用方只有 `compiler/resolve_variables.zig:1907`（`run` 开头的重声明检查循环）。


### `binding_rules.isPseudoBindingAtom` (`src/compiler/binding_rules.zig:2097`)

- **签名**：`fn isPseudoBindingAtom(atom_id: atom.Atom) bool`。
- **作用**：atom 是否引擎伪绑定名。
- **实现**：this/new.target 等。 返回 `atom_id == atom.ids.home_object or atom_id == atom.ids.this_active_func or atom_id == atom.ids.new_target or atom_id == atom.ids.this_`。
- **所有权 / 错误 / 调用**：纯 atom id 比较，不分配、无 error set。私有，调用方 `bytecode.zig:8668`（`isEvalNonLexicalLocal`）、`:8909`（`discoverParentScopedSource`）、`:9112`/`:9136`（`resolveBindingTopologyAfterCurrentMiss`）等 5 处。


### `binding_rules.threadParentLocalSource` (`src/compiler/binding_rules.zig:2104`)

- **签名**：`fn threadParentLocalSource( target: *function_def_mod.FunctionDef, parent: *function_def_mod.FunctionDef, local_idx: u16, ) Error!u16`。
- **作用**：把父局部穿成当前闭包源。
- **实现**：threadClosureSource(.local)。 调用 `threadClosureSource` 穿父源。 标记对应槽 `is_captured`。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**会改图也会分配**：先 `parent.captureLocal`（就地置 `is_captured` 并分配 `open_binding_idx`），再经 `threadClosureSource`→`addOrFindClosureSource` 在每层 FunctionDef 上用 `fd.memory` 增长 `closure_var`；新行的 atom 只复制 id，不 retain。capture 失败折成 `error.InvalidBytecode`，OOM 为 `Error.OutOfMemory`。私有，9 处调用方，主力是 `bytecode.zig:9033`–`:9105`（`resolveBindingTopologyAfterCurrentMiss`），另有 `:8910`（`discoverParentScopedSource`）、`:9449`（`resolvePrivateBindingTopology`）。


### `binding_rules.threadParentArgSource` (`src/compiler/binding_rules.zig:2122`)

- **签名**：`fn threadParentArgSource( target: *function_def_mod.FunctionDef, parent: *function_def_mod.FunctionDef, arg_idx: u16, ) Error!u16`。
- **作用**：把父参数穿成闭包源。
- **实现**：.arg。 调用 `threadClosureSource` 穿父源。 标记对应槽 `is_captured`。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：同 `threadParentLocalSource` 的参数版：`parent.captureArg` 置位 + 逐层 `addClosureVar` 分配；错误同上。私有，唯一调用方 `bytecode.zig:9089`（`resolveBindingTopologyAfterCurrentMiss`）。


### `binding_rules.discoverParentScopedSource` (`src/compiler/binding_rules.zig:2148`)

- **签名**：`fn discoverParentScopedSource( comptime trust_final_scope_links: bool, target: *function_def_mod.FunctionDef, parent: *function_def_mod.FunctionDef, atom_id: atom.Atom, start_scope: i32, ) Error!ParentScopedSource`。
- **作用**：在父词法链上发现源并穿过来。
- **实现**：`start_scope` 越界即 `error.InvalidBytecode`；沿 parent 的 `first`/`scope_next` 找同名槽，命中返回 `.local`。途中每遇到一个 `with_object` 槽（且查的不是伪绑定名）都立刻 `threadParentLocalSource` 把它穿成闭包源——qjs 里每个挡在前面的 `with` 环境本身就是一次捕获事件。链走完后终端哨兵必须是 -1 或 `arg_scope_end`（否则 `InvalidBytecode`），是后者时返回 `argument_environment_only = true`。`trust_final_scope_links` 为假时每步另做下标/`visited` 上界检查。
- **所有权 / 错误 / 调用**：自身不分配，但遇到 `with_object` 行会调 `threadParentLocalSource`，从而在闭包链上新建行（见该函数）。链损坏/越界返回 `error.InvalidBytecode`。私有，两个实例化站点都在 `bytecode.zig:9028`、`:9030`（`resolveBindingTopologyAfterCurrentMiss`，按 `trust_final_scope_links` 分成两臂）。

### `binding_rules.ensureParentArgumentsBinding` (`src/compiler/binding_rules.zig:2177`)

- **签名**：`fn ensureParentArgumentsBinding(parent: *function_def_mod.FunctionDef) Error!u16`。
- **作用**：确保父有 arguments 伪绑定并返回下标。
- **实现**：调 `parent.ensureArgumentsBinding()`（任何失败折成 `error.OutOfMemory`），再校验 `parent.arguments_var_idx` 落在 `[0, maxInt(u16)]`，否则 `error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**可能分配**：`ensureArgumentsBinding` 会按需在 parent 上新建 `arguments` 局部槽（归 parent 所有）。私有，唯一调用方 `bytecode.zig:9098`（`resolveBindingTopologyAfterCurrentMiss` 的 parent arguments 臂），`surface` 不导出。


### `binding_rules.ensureCurrentPseudoBinding` (`src/compiler/binding_rules.zig:2181`)

- **签名**：`fn ensureCurrentPseudoBinding( fd: *function_def_mod.FunctionDef, atom_id: atom.Atom, ) Error!?u16`。
- **作用**：当前函数按 atom 确保伪绑定。
- **实现**：`fd.has_this_binding` 为假、或 atom 不在 `home_object` / `this_active_func` / `new_target` / `this_` 四者之内，返回 null；否则调对应的 `ensureHomeObjectBinding` / `ensureThisActiveFunctionBinding` / `ensureNewTargetBinding` / `ensureThisBinding`（失败折成 `error.OutOfMemory`），下标出 u16 范围则 `error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：**可能分配**：这是解析末期唯一按需追加特殊局部槽的点，新槽归 `fd` 所有。私有，调用方 `bytecode.zig:8997`（当前函数臂）与 `:9093`（parent 臂），都在 `resolveBindingTopologyAfterCurrentMiss` 内；`surface` 不导出。


### `binding_rules.findResolvedClosureBinding` (`src/compiler/binding_rules.zig:2202`)

- **签名**：`fn findResolvedClosureBinding( fd: *const function_def_mod.FunctionDef, atom_id: atom.Atom, ) ?ScopeVarBinding`。
- **作用**：当前函数闭包身份：真 runtime ref 优先，动态全局作回退。
- **实现**：扫 `fd.closure_var` 的同名行：既是运行时 VarRef、源头又不是动态全局（`closureVarSourceIsDynamicGlobal`）→ 立刻 `.closure = idx`；否则把第一个 global 族行记在 `global_idx` 里；走完返回 `.global = global_idx` 或 null。返回下标本身，调用方不必再按名扫一次。
- **所有权 / 错误 / 调用**：只读扫描，返回按值的 `ScopeVarBinding`（内含借来的下标），不分配、无 error set。私有，唯一调用方 `bytecode.zig:9012`（`resolveBindingTopologyAfterCurrentMiss`）。


### `binding_rules.resolveBindingTopologyAfterCurrentMiss` (`src/compiler/binding_rules.zig:2227`)

- **签名**：`noinline fn resolveBindingTopologyAfterCurrentMiss( trust_final_scope_links: bool, ctx: *JSContext, atom_id: atom.Atom, ) Error!ScopeVarBinding`。
- **作用**：当前函数的 scope/var/argument 查找 miss 之后，继续 qjs `resolve_scope_var`：伪变量、隐式 `arguments`、具名函数表达式 self，再沿 parent 穿闭包。
- **实现**：无 `function_def` → `NoFunctionDef`。trust 模式断言已有 `scope_link_proof`。当前函数：`ensureCurrentPseudoBinding`；`arguments` 且 `has_arguments_binding` 则 `ensureArgumentsBinding`；具名函数表达式 self 则 `ensureFuncExprSelfBinding`。已穿好的闭包用 `findResolvedClosureBinding`。有 parent 时 trust 走 `proveParentScopeLinksForResolution`，否则 `validateFunctionDefParentChain`。沿 parent：`discoverParentScopedSource` 命中 local 则 `threadParentLocalSource`；箭头在参数环境捕获 `arguments` 时按需 `ensureArgumentsBinding`/`ensureArgumentsArgumentBinding`；非 argument-env-only 再扫 scope-0 函数 var 与 `findArg`；parent 伪绑定 / arguments / 具名 self 同样 thread。非伪 atom 还 thread eval 的 var/arg object。parent 是 eval 则扫其 `closure_var`（global 家族变 `.global`，其余 `.closure`），然后 break。链走完 `ensureGlobalClosureVar`。outlined 是为了把可失败的 parent 遍历与 demand-created 绑定留在局部 miss 之后，对齐 qjs。
- **所有权 / 错误 / 调用**：可能 OOM（ensure*Binding / thread）。`InvalidBytecode` 来自下标溢出或 `InvalidScope`。调用方：`resolveBindingTopologyResultImpl` 当前函数 miss 之后。


### `binding_rules.resolveBindingTopologyResultImpl` (`src/compiler/binding_rules.zig:2386`)

- **签名**：`inline fn resolveBindingTopologyResultImpl( comptime trust_final_scope_links: bool, ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, ) Error!ScopeVarBinding`。
- **作用**：声明与子函数都齐之后发现一条 scope 绑定（拓扑半）。
- **实现**：两段——`scope_level >= 0` 时先跑 `resolveLocalOrArgImpl`（同一个 comptime `trust_final_scope_links` 传下去），命中就把 `LocalOrArg` 映射成 `.local`/`.arg` 返回；miss（或 scope_level<0）才落到外联的 `resolveBindingTopologyAfterCurrentMiss`。
- **所有权 / 错误 / 调用**：自身只做分派，但下游 `resolveBindingTopologyAfterCurrentMiss` 会 capture 并新建闭包行（见 `threadParentLocalSource`），所以这是有副作用的调用。错误集是完整的 `Error`（`OutOfMemory`/`InvalidBytecode`/`BytecodeOverflow`/`NoFunctionDef`/`NoParentScope`/`ClosureVarNotFound`）。私有，三个实例化站点 `bytecode.zig:9183`（`resolveBindingTopologyResult`，trust=false）、`:9195`（`resolveScopeVarBindingTopologyImpl`）、`:9321`（`resolveScopeVarPlanImpl`，`@call(.always_inline)`）。原先第四个 trust=true 站点 `resolveBindingTopologyV2` 无调用方，已删。


### `binding_rules.resolveBindingTopologyResult` (`src/compiler/binding_rules.zig:2408`)

- **签名**：`fn resolveBindingTopologyResult( ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, ) Error!ScopeVarBinding`。
- **作用**：trust=false 包装。
- **实现**：Error。 返回 `resolveBindingTopologyResultImpl(false, ctx, atom_id, scope_level)`。
- **所有权 / 错误 / 调用**：trust=false 的外联包装，副作用与错误同 `resolveBindingTopologyResultImpl`。私有，唯一调用方 `bytecode.zig:9367`（`resolveBindingTopology`）。


### `binding_rules.resolveScopeVarBindingTopologyImpl` (`src/compiler/binding_rules.zig:2419`)

- **签名**：`fn resolveScopeVarBindingTopologyImpl( comptime trust_final_scope_links: bool, ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, ) Error!ScopeVarBinding`。
- **作用**：完整分类：模块词法优先与 sloppy-eval 局部在此规范化。
- **实现**：先 `resolveBindingTopologyResultImpl` 拿 discovered；再三道规范化——`scope_level < 0` 直接 `ensureGlobalClosureVar` 成 `.global`；顶层模块/全局词法闭包行（`lookupTopLevelModuleLexicalClosureVar`）优先成 `.closure`；discovered 是 `.local` 时，sloppy-eval var（`isEvalNonLexicalLocal`）改成 `.global`（同样 ensure 一行），模块顶层 class 绑定（`preferTopLevelModuleClassBinding`）改成 `.closure`；其余原样返回。
- **所有权 / 错误 / 调用**：除拓扑副作用外，全局臂还会 `ensureGlobalClosureVar`，即可能在 eval 根上**新建全局 closure 行**（分配走 `fd.memory`）。错误集为完整 `Error`。私有，两个实例化站点 `bytecode.zig:9226`（trust=false 包装）、`:9379`（`resolveScopeVarBindingTopologyV2`）。


### `binding_rules.ResolvedScopeVarPlan.init` (`src/compiler/binding_rules.zig:2482`)

- **签名**：`fn init( resolved_binding: ScopeVarBinding, resolved_action: ScopeVarAction, ) ResolvedScopeVarPlan`。
- **作用**：把「绑定身份 + 选定动作」两个语义结构压进一个 `u64` packed struct，让 v2 的解析器能用寄存器返回整份结果，而不是经调用方栈内存回传。
- **实现**：先用 `resolved_action` 填好动作四元组（`index`/`op_id`/`size`/`operand_size`），`binding_kind` 与 `binding_index` 先置 `.local`/0；再对 `resolved_binding` 做 switch，四个臂 `.local`/`.arg`/`.closure`/`.global` 分别调 `withBinding` 覆写 kind 与 index。
- **所有权 / 错误 / 调用**：纯值构造、无 error set、不分配。唯一调用方是同文件的 `resolveScopeVarPlanImpl`（`src/bytecode.zig:9345`），它在跑完拓扑查找与 `planResolvedScopeVarAction` 之后打包返回。


### `binding_rules.ResolvedScopeVarPlan.withBinding` (`src/compiler/binding_rules.zig:2502`)

- **签名**：`inline fn withBinding( base: ResolvedScopeVarPlan, kind: ScopeVarBindingKind, index: u16, ) ResolvedScopeVarPlan`。
- **作用**：在已填好动作字段的计划上盖写绑定 kind 与索引，省得 `init` 的四个 switch 臂各写一遍聚合初始化。
- **实现**：拷贝 `base` 到局部 `result`，赋 `binding_kind`/`binding_index` 后返回；`inline fn`，因此在 `init` 里会被完全展开，不产生额外拷贝。
- **所有权 / 错误 / 调用**：纯值函数、无 error set。只被同一结构体的 `init`（`src/bytecode.zig:9273`-`9276`）调用。


### `binding_rules.ResolvedScopeVarPlan.binding` (`src/compiler/binding_rules.zig:2513`)

- **签名**：`inline fn binding(self: ResolvedScopeVarPlan) ScopeVarBinding`。
- **作用**：从压缩计划里还原出 `ScopeVarBinding` 标签联合，给需要绑定身份（而非指令形状）的下游用。
- **实现**：按 `self.binding_kind` 做 switch，四个臂把同一个 `binding_index` 分别包成 `.local`/`.arg`/`.closure`/`.global`；`inline fn`，展开后通常只剩一次 tag 拷贝。
- **所有权 / 错误 / 调用**：无 error set、不分配。经 `surface.resolvedScopeVarPlanBinding` 由 `src/compiler/resolve_variables.zig:1693` 调用，把绑定交给 `emitDynamicEnvProbes` 判断动态环境探针链要不要在此截断。


### `binding_rules.ResolvedScopeVarPlan.action` (`src/compiler/binding_rules.zig:2522`)

- **签名**：`inline fn action(self: ResolvedScopeVarPlan) ScopeVarAction`。
- **作用**：从压缩计划里还原出 `ScopeVarAction`，供需要完整动作结构的旧写入路径与审计对账使用。
- **实现**：把 `action_op_id`/`action_size`/`action_operand_size` 重新装回 `ShortLocForm`，再配上 `action_index` 构成 `ScopeVarAction`；`inline fn`，热路径上通常被写入侧的字段直读取代。
- **所有权 / 错误 / 调用**：无 error set。经 `surface.resolvedScopeVarPlanAction` 由 `Resolver.writeResolvedScopeVarPlan` 在 `throw_error` 这条带 atom 的冷路径上回落到通用写入器（`src/compiler/resolve_variables.zig:481`），以及 `audit_oracles` 构建下与 `planScopeVarLowering` 的结果做 `std.meta.eql` 对账（`:1650`）。


### `binding_rules.resolveScopeVarPlanImpl` (`src/compiler/binding_rules.zig:2534`)

- **签名**：`inline fn resolveScopeVarPlanImpl( comptime trust_final_scope_links: bool, ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, op_id: u8, ) Error!ResolvedScopeVarPlan`。
- **作用**：拓扑 + 动作一次返回。
- **实现**：V2 主路径，把 `resolveScopeVarBindingTopologyImpl` 的三道规范化就地展开（`@call(.always_inline, resolveBindingTopologyResultImpl, …)` → scope_level<0 / 顶层模块词法 / local 的 eval-var 与 class 两改写），再 `@call(.always_inline, planResolvedScopeVarAction, …)` 选动作，最后 `ResolvedScopeVarPlan.init` 打包成寄存器大小的 u64 返回。
- **所有权 / 错误 / 调用**：`inline`；拓扑段的副作用（capture、新建闭包/全局行、`fd.memory` 分配）全部继承自 `resolveBindingTopologyResultImpl` 与 `ensureGlobalClosureVar`，动作段本身不分配。错误集为完整 `Error`。私有，两个实例化站点 `bytecode.zig:9354`（`resolveScopeVarPlan`，trust=false）、`:9363`（`resolveScopeVarPlanV2`，trust=true，即 surface 真正导出的那个）。


### `binding_rules.resolveScopeVarPlanV2` (`src/compiler/binding_rules.zig:2570`)

- **签名**：`inline fn resolveScopeVarPlanV2( ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, op_id: u8, ) Error!ResolvedScopeVarPlan`。
- **作用**：V2 解析：拓扑 + 动作一次返回。
- **实现**：`resolveScopeVarPlanImpl(true, …)`——`inline`，把整条语义走法展开进调用方，依赖 `proveScopeLinksForResolution` 立下的 `scope_link_proof`。
- **所有权 / 错误 / 调用**：副作用/错误同 impl（可能 capture、新建闭包或全局行、`fd.memory` 分配）。经 `surface.resolveScopeVarPlan`（`bytecode.zig:9525`）由 `compiler/resolve_variables.zig:1643`（`lowerScopeVar`）调用，是生产 scope-op 降级的主入口。


### `binding_rules.resolveBindingTopology` (`src/compiler/binding_rules.zig:2579`)

- **签名**：`fn resolveBindingTopology(ctx: *JSContext, atom_id: atom.Atom, scope_level: i32) Error!void`。
- **作用**：只跑拓扑，丢弃结果（要的就是副作用：capture 与闭包行穿线）。
- **实现**：`_ = try resolveBindingTopologyResult(ctx, atom_id, scope_level)`（trust=false），返回值直接丢弃。
- **所有权 / 错误 / 调用**：丢弃结果的包装，副作用与错误同 `resolveBindingTopologyResult`。私有意义上只有一个调用方 `bytecode.zig:9439`（`resolvePrivateBindingTopology`）；`surface.resolveBindingTopology`（`bytecode.zig:9523`）指向的是 V2 变体，且 `resolve_variables.zig` 当前未使用该导出。


### `binding_rules.resolveScopeVarBindingTopologyV2` (`src/compiler/binding_rules.zig:2583`)

- **签名**：`inline fn resolveScopeVarBindingTopologyV2( ctx: *JSContext, atom_id: atom.Atom, scope_level: i32, ) Error!ScopeVarBinding`。
- **作用**：V2 完整分类。
- **实现**：inline。 返回 `resolveScopeVarBindingTopologyImpl(true, ctx, atom_id, scope_level)`。
- **所有权 / 错误 / 调用**：trust=true 的 `inline` 包装，副作用/错误同 `resolveScopeVarBindingTopologyImpl`（含 `ensureGlobalClosureVar` 可能新建全局行）。没有直接调用方：它经 `surface.resolveScopeVarBindingTopology`（`bytecode.zig:9524`）被 `compiler/resolve_variables.zig:1711`（`lowerScopeRef`）、`:1778`（`lowerScopeMakeRef`）使用。


### `binding_rules.privateBindingOwner` (`src/compiler/binding_rules.zig:2596`)

- **签名**：`fn privateBindingOwner(ctx: *const JSContext, res: PrivateFieldResolution) ?PrivateBindingOwner`。
- **作用**：private 解析结果的所有者（当前/闭包）。
- **实现**：`is_ref` 为假时直接校验当前 fd 的该槽是 private VarKind 并返回 `{fd, idx}`；否则沿闭包链最多 64 跳：`.local` 行到父函数取 `cv.var_idx` 那一槽（同样校验 private VarKind）后返回，`.ref` 行换到父继续，`arg`/global 族/module 族一律 null。
- **所有权 / 错误 / 调用**：只读回溯闭包链（硬上限 64 跳），返回借来的 `*FunctionDef` 指针与下标，不分配、无 error set。私有，唯一调用方 `bytecode.zig:9446`（`resolvePrivateBindingTopology`）。


### `binding_rules.findPrivateSetterOwnerBinding` (`src/compiler/binding_rules.zig:2624`)

- **签名**：`fn findPrivateSetterOwnerBinding( ctx: *const JSContext, private_atom: atom.Atom, owner: PrivateBindingOwner, ) ?u16`。
- **作用**：在同一 owner 上找 setter 伴生绑定。
- **实现**：以 owner 那一槽的 `scope_level` 为准，线性扫 `owner.fd.vars`，取同 scope、`var_kind == .private_setter` 且名字满足 `isPrivateSetterCompanionName` 的槽下标；越界或找不到返回 null。
- **所有权 / 错误 / 调用**：只读扫描 owner 的 vars，不分配、无 error set。私有，唯一调用方 `bytecode.zig:9447`（`resolvePrivateBindingTopology`）。


### `binding_rules.resolvePrivateBindingTopology` (`src/compiler/binding_rules.zig:2638`)

- **签名**：`fn resolvePrivateBindingTopology( ctx: *JSContext, op_id: u8, atom_id: atom.Atom, scope_level: i32, ) Error!void`。
- **作用**：private 字段指令的拓扑证明/捕获。
- **实现**：先 `resolveBindingTopology` 跑普通词法/捕获机制，再 `resolvePrivateField` 校验确实解析到 private 绑定（否则 `ClosureVarNotFound`——private miss 绝不退化成全局）。只有 `scope_put_private_field` 且 kind 是 `private_setter`/`private_getter_setter` 时继续：`resolvePrivateSetter` 已能解析就收工；否则找 owner（`privateBindingOwner`）与 owner 上的 setter 槽（`findPrivateSetterOwnerBinding`），owner 不是当前函数就 `threadParentLocalSource` 把它穿过来，最后再解析一次确认，仍失败则 `ClosureVarNotFound`。
- **所有权 / 错误 / 调用**：**有副作用**：`resolveBindingTopology` 与 `threadParentLocalSource` 会 capture 并在闭包链上新建行（分配走 `fd.memory`，可 `OutOfMemory`）；解析不到 private 绑定/ setter → `error.ClosureVarNotFound`，无 fd → `error.NoFunctionDef`。经 `surface.resolvePrivateBindingTopology`（`bytecode.zig:9563`）由 `compiler/resolve_variables.zig:1883`（`lowerPrivateField`，在 `resolvePrivateField` 之前）调用。


## 覆盖核对

- 清单函数数（本文件分组）: 142（`src/bytecode.zig` 全文件 507）
- 本文标题覆盖: 142
- 未覆盖: 无
