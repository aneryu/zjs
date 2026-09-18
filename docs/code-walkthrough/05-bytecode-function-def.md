# 05 — FunctionDef 与编译期 Bytecode

覆盖 `function_def`（镜像 `JSFunctionDef`，quickjs.c:21420）与 `function_mod.BytecodeImpl`（lowering 的可变载体）、`LegacyExecutionAdapter`、执行 flags 发布。

## FunctionDef

parser 的 Phase 1 状态：作用域、变量、标签、临时字节码、子函数列表、cpool、atom_operands、source_loc_slots。Phase 2/3 之后由 `pipeline_finalize` 收成 `FunctionBytecode`。

要点：

- 缓冲全部几何增长（`growSliceBy`，容量翻倍、地板 8），`slice.len` 是已用，backing 是 `ptr[0..capacity]`。
- `scope_next` 链与 `arg_scope_end = -2` 对齐 QuickJS 参数环境。
- `builder` 是唯一 lowering 后端；finalize 时必须存在。
- `deinit` 递归销毁 `child_list`，释放 label reloc、cpool reserved BigInt、source（len+1）。

## Bytecode

finalize 的中间载体：最终码、atom ledger、argdefs/vardefs/closure_var、constants、pc2line、call/prop site 计数、以及将写入 CallFacts 的资格位。生产路径在 `createFunctionBytecodeAfterChildren` 里短命存在，然后搬进 packed FB。夹具/测试可长期拿着它，再经 `LegacyExecutionAdapter` 借给 VM。

`publishExecutionFlags` 必须在码与 stack-BFS 完成之后调用一次；attach/call 禁止再扫码。

## 函数



### `function_def`

### `function_def.freeOwnedValue` (`src/bytecode.zig:4728`)

- **签名**：`fn freeOwnedValue(value: JSValue, rt: anytype) void`。
- **作用**：未发布 cpool BigInt 的 reserved 销毁。
- **实现**：同 constant.freeOwnedValue。
- **所有权 / 错误 / 调用**：FunctionDef.deinit。


### `function_def.growSliceBy` (`src/bytecode.zig:4817`)

- **签名**：`inline fn growSliceBy( comptime T: type, mem: *memory.MemoryAccount, slice: *[]T, capacity: *usize, n: usize, ) ![]T`。
- **作用**：几何增长：len 是已用，capacity 是 backing。
- **实现**：够用则只伸 len；否则走 noinline growSliceBySlowBytes（翻倍，地板 8）。
- **所有权 / 错误 / 调用**：返回新尾的可写视图。OOM。


### `function_def.growSliceBySlowBytes` (`src/bytecode.zig:4850`)

- **签名**：`noinline fn growSliceBySlowBytes( mem: *memory.MemoryAccount, old_ptr: [*]u8, capacity: *usize, used: usize, new_used: usize, elem_size: usize, alignment: std.mem.Alignment, ) ![*]u8`。
- **作用**：`growSliceBy` 在 `new_used > capacity` 时的类型擦除增长：翻倍（地板 8），拷贝 used，释放旧 backing。
- **实现**：断言 `new_used > capacity.*`。`new_cap = max(new_used, capacity==0 ? 8 : capacity*2)`。`allocElements` 失败上抛。`used * elem_size` 溢出 → OOM。非零 used 则 memcpy；旧 capacity 非 0 才按 `capacity * elem_size` `freeAlignedBytes`。对齐 qjs：`js_resize_array` 内联，只在超容量时进 noinline `js_realloc_array`。分配走 `allocElements` / `allocSlowErased`，不走 `allocAlignedBytes(trigger=true)`。
- **所有权 / 错误 / 调用**：新块记在 `MemoryAccount`。失败时旧 backing 不动。`growSliceBy` 是唯一调用方。


### `function_def.freeGrowableSlice` (`src/bytecode.zig:4875`)

- **签名**：`fn freeGrowableSlice( comptime T: type, mem: *memory.MemoryAccount, slice: *[]T, capacity: *usize, ) void`。
- **作用**：释放 backing 并清零。
- **实现**：按 capacity free。
- **所有权 / 错误 / 调用**：deinit。


### `function_def.freeGrowableAtomSlice` (`src/bytecode.zig:4888`)

- **签名**：`fn freeGrowableAtomSlice( mem: *memory.MemoryAccount, slice: *[]atom.Atom, capacity: *usize, ) void`。
- **作用**：原子切片：capacity 优先。
- **实现**：不减 atom ref（tracing）。rc 时代那个从不使用的首参 `_: *atom.AtomTable` 已从签名和调用点删除。
- **所有权 / 错误 / 调用**：deinit。


### `function_def.freeGrowableNamedSlice` (`src/bytecode.zig:4904`)

- **签名**：`fn freeGrowableNamedSlice( comptime T: type, mem: *memory.MemoryAccount, slice: *[]T, capacity: *usize, ) void`。
- **作用**：带 atom 字段的结构切片。
- **实现**：按 T free。行里的 `var_name` atom 不在此释放，rc 时代那个被忽略的 `*atom.AtomTable` 形参已删。
- **所有权 / 错误 / 调用**：vars/args/global/closure。


### `FunctionDef.init` (`src/bytecode.zig:5083`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionDefImpl`。
- **作用**：空 FunctionDef：名字同时当 filename/script_or_module。
- **实现**：结构体字面量，缓冲全空。
- **所有权 / 错误 / 调用**：account/atoms 借入。


### `FunctionDef.replaceSourceText` (`src/bytecode.zig:5093`)

- **签名**：`pub fn replaceSourceText(self: *FunctionDefImpl, source: []const u8) !void`。
- **作用**：换成 `len+1` NUL 结尾的源。
- **实现**：alloc、memcpy、写 0、free 旧。
- **所有权 / 错误 / 调用**：OOM。finalize 把同一块 move 进 DebugInfo。


### `FunctionDef.deinitInitFailure` (`src/bytecode.zig:5104`)

- **签名**：`pub fn deinitInitFailure(self: *FunctionDefImpl) void`。
- **作用**：初始化失败：只丢 builder 与 scopes。
- **实现**：与 deinit 相同条款释放已 attach 的 Builder。
- **所有权 / 错误 / 调用**：ParseState.initRootEmitter 之后失败。


### `FunctionDef.appendScope` (`src/bytecode.zig:5125`)

- **签名**：`pub fn appendScope(self: *FunctionDefImpl, parent: i32) !i32`。
- **作用**：push_scope：记录 parent，继承可见绑定头。
- **实现**：返回新 scope_level。使 scope_link_cache 失效。
- **所有权 / 错误 / 调用**：quickjs.c:23486。


### `FunctionDef.rebuildFinalScopeLinks` (`src/bytecode.zig:5138`)

- **签名**：`pub fn rebuildFinalScopeLinks(self: *FunctionDefImpl) error{InvalidScope}!void`。
- **作用**：重建 vars 的 scope_next 链（对齐 `js_create_function` 开头 quickjs.c:36034-36059 的一次性重建）。
- **实现**：先失效缓存；scopes 为空、`scope_count` 与 `scopes.len` 不符、scopes[0].parent≠-1、有参数表达式而 scopes[1].parent≠-1、body_scope 越界都抛 InvalidScope。所有 `first` 清 -1，有参数表达式时 `scopes[1].first = arg_scope_end`（-2）；按 scope_level 把 vars 逐个头插成链；再从 scope 2 起把仍为空的 scope 继承父 first，并给 scope_level>1 且 scope_next<0 的行补上父 first；最后按 `scope_level` 刷新 `scope_first`。
- **所有权 / 错误 / 调用**：不分配；只写 scopes/vars 与 `scope_first`。错误只有 `error{InvalidScope}`。生产唯一调用方是 `prepareCurrentBeforeChildren`（`src/bytecode.zig:10659`，`catch return error.InvalidBytecode`，紧接 `addEvalVariables`）；此后 `scopes[].first` 与 `VarDef.scope_next` 是词法链唯一权威。


### `FunctionDef.validateFinalScopeLinks` (`src/bytecode.zig:5203`)

- **签名**：`pub fn validateFinalScopeLinks(self: *const FunctionDefImpl) error{InvalidScope}!void`。
- **作用**：只读校验链，不改缓存。
- **实现**：空 scopes 也合法（要求 scope_count==0、body_scope<0、scope_first==-1）；否则逐 scope 走链，终止哨兵按层级取 -1 / `arg_scope_end` / 父 scope 的 first；`visited >= vars.len` 即判环；越界、层级不符、scope_count 与 scopes.len 不一致都是 InvalidScope。
- **所有权 / 错误 / 调用**：`proveAncestorScopeLinks`、`JSContext.proveScopeLinksForResolution`（`src/bytecode.zig:6765`）、`ensureArgumentsArgumentBinding` 的前后自检与单测。


### `FunctionDef.invalidateScopeLinkCache` (`src/bytecode.zig:5276`)

- **签名**：`fn invalidateScopeLinkCache(self: *FunctionDefImpl) void`。
- **作用**：缓存标 unproven。
- **实现**：仅当 `scope_link_cache != .disabled` 时改成 `.unproven`；未启用缓存的 def 不动。
- **所有权 / 错误 / 调用**：任何改 scopes/vars/args 的路径。


### `FunctionDef.proveAncestorScopeLinks` (`src/bytecode.zig:5280`)

- **签名**：`fn proveAncestorScopeLinks(self: *FunctionDefImpl) error{InvalidScope}!void`。
- **作用**：在缓存允许时证明祖先链。
- **实现**：`.proven` 直接返回（测试下累加 cache_hits）；否则跑 `validateFinalScopeLinks`，且只有原状态是 `.unproven` 时才升成 `.proven`（`.disabled` 每次都重验）。
- **所有权 / 错误 / 调用**：`proveParentScopeLinksForResolution` 逐层证明祖先链（`src/bytecode.zig:6776`）。


### `FunctionDef.consumeGlobalVars` (`src/bytecode.zig:5291`)

- **签名**：`pub fn consumeGlobalVars(self: *FunctionDefImpl) void`。
- **作用**：hoist 计划已装进 resolve 完的字节码之后，丢掉只属于 parse 期的 global_vars 账本。
- **实现**：先清空 slice/capacity/count，再把每行 `var_name` 置 null_atom，capacity 非 0 才按 capacity free。
- **所有权 / 错误 / 调用**：`createFunctionBytecodeAfterChildren` 在 v2 lowering 成功后调用（`src/bytecode.zig:10832`）。


### `FunctionDef.ensureFuncExprSelfBinding` (`src/bytecode.zig:5308`)

- **签名**：`pub fn ensureFuncExprSelfBinding(self: *FunctionDefImpl) !i32`。
- **作用**：幂等创建命名函数表达式的 self-binding（qjs add_func_var）。
- **实现**：经 func_var_idx 去重。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，只在 `func_var_idx < 0` 时转调 `appendVar`，所有权与 `error{OutOfMemory}` 都来自那里。调用方：parser 的作用域解析 `src/parser.zig:3142`/`:3155`/`:3366`、binding_rules 的闭包绑定查找 `src/bytecode.zig:9004`/`:9103`、finalize 的 `addEvalVariables`（`src/bytecode.zig:10520`/`:10545`）——后两者用 `catch return error.OutOfMemory` 收敛。`src/compiler/resolve_*.zig` 里没有生产调用方（同名调用全在 test 块内）。


### `FunctionDef.ensureThisBinding` (`src/bytecode.zig:5330`)

- **签名**：`pub fn ensureThisBinding(self: *FunctionDefImpl) !i32`。
- **作用**：追加 this 伪绑定；不挂进 scopes[].first。
- **实现**：resolve_scope_var 用字段身份而非名字扫描。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，幂等地转调 `appendVar`（`error{OutOfMemory}` 由它产生）；派生类构造器还会顺手把该行的 `tdz_emitted_at_decl` 置上，TDZ 初始化本身归 resolve_labels。调用方：`src/parser.zig:3304`（父函数 this 捕获）与 `:15130`（默认类构造器）、binding_rules 的 `ensureCurrentPseudoBinding`（`src/bytecode.zig:8947`）、finalize 的 `addEvalVariables`（`:10503`/`:10533`）。


### `FunctionDef.ensureNewTargetBinding` (`src/bytecode.zig:5348`)

- **签名**：`pub fn ensureNewTargetBinding(self: *FunctionDefImpl) !i32`。
- **作用**：幂等创建 new.target 伪绑定。
- **实现**：字段身份。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，转调 `appendVar`，`error{OutOfMemory}` 由它产生。调用方三处：`src/parser.zig:3307`（父函数 new.target 捕获）、`src/bytecode.zig:8945`（`ensureCurrentPseudoBinding`）、`src/bytecode.zig:10504`/`:10534`（finalize 的 `addEvalVariables`）。


### `FunctionDef.ensureThisActiveFunctionBinding` (`src/bytecode.zig:5360`)

- **签名**：`pub fn ensureThisActiveFunctionBinding(self: *FunctionDefImpl) !i32`。
- **作用**：幂等创建 this_active_func 伪绑定。
- **实现**：字段身份。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，转调 `appendVar`，`error{OutOfMemory}` 由它产生。parser 里没有直接调用方：只有 binding_rules 的 `ensureCurrentPseudoBinding`（`src/bytecode.zig:8943`）与 finalize 的 `addEvalVariables`（`:10506`/`:10536`）会建这个伪绑定。


### `FunctionDef.ensureHomeObjectBinding` (`src/bytecode.zig:5372`)

- **签名**：`pub fn ensureHomeObjectBinding(self: *FunctionDefImpl) !i32`。
- **作用**：幂等创建 home_object 伪绑定。
- **实现**：字段身份；无论是否新建，返回前都无条件把 `need_home_object` 置 true（对齐 qjs：显式 parser 位或解析出的 home-object 伪局部任一成立即发布）。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，转调 `appendVar`（`error{OutOfMemory}` 由它产生）；注意副作用是无条件的——即使绑定已存在也会把 `need_home_object` 置 true。调用方：`src/bytecode.zig:8941`（`ensureCurrentPseudoBinding`）与 `:10508`/`:10538`（finalize 的 `addEvalVariables`，以 `has_home_object` 为前置）。


### `FunctionDef.ensureArgumentsBinding` (`src/bytecode.zig:5390`)

- **签名**：`pub fn ensureArgumentsBinding(self: *FunctionDefImpl) !i32`。
- **作用**：qjs add_arguments_var：字段而非名字拥有身份。显式参数名 arguments 不抑制此伪绑定。
- **实现**：幂等。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，转调 `appendVar`，`error{OutOfMemory}` 由它产生；身份只看 `arguments_var_idx` 字段，不做名字扫描。调用方最多：`src/parser.zig:3088`（隐式 arguments 局部）、`:15749`（参数作用域 arguments）、binding_rules 的 `src/bytecode.zig:8928`/`:8999`/`:9049`、finalize 的 `:10512`/`:10542`。


### `FunctionDef.ensureArgumentsArgumentBinding` (`src/bytecode.zig:5406`)

- **签名**：`pub fn ensureArgumentsArgumentBinding(self: *FunctionDefImpl) !void`。
- **作用**：qjs add_arguments_arg：唯一在普通建 scope 之后手工链入的伪绑定。
- **实现**：先 `validateFinalScopeLinks` 拒绝畸形拓扑；`arguments_arg_idx >= 0` 直接返回；参数作用域固定为 scope 1，缺失则 InvalidScope；沿 scope 1 的链找同名 `arguments`，找到就让显式形参赢、不记合成别名；否则 appendVar 一条 is_lexical 行并接到 `scopes[1].first`，最后再验一次链。 错误臂：`error.InvalidScope`。
- **所有权 / 错误 / 调用**：自身不分配（新行经 `appendVar`，`src/bytecode.zig:5672`）；error set 是 `error{OutOfMemory, InvalidScope}`，后者来自前后两次 `validateFinalScopeLinks`。三个调用方各自收敛它：`src/parser.zig:15750` 翻成 `error.ParserInvariant`，binding_rules 的 `resolveBindingTopologyAfterCurrentMiss`（`src/bytecode.zig:9050`）与 finalize 的 `addEvalVariables`（`:10514`）翻成 `error.InvalidBytecode`。


### `FunctionDef.hasExplicitArgumentsVar` (`src/bytecode.zig:5447`)

- **签名**：`pub fn hasExplicitArgumentsVar(self: *const FunctionDefImpl) bool`。
- **作用**：是否有源级 `var arguments`（区别于懒伪绑定）。
- **实现**：`arguments_var_idx < 0` 或越界返回 false；否则看 `vars[idx].scope_next != 0`——合成伪绑定用 add_var 的零起源，源级声明保留 parser 起源。
- **所有权 / 错误 / 调用**：纯读、不分配、无 error set；越界下标读成 false。调用方三处，都在判「参数初始化闭包该绑到函数的 arguments 还是函数体自己声明的 `var arguments`」：`src/bytecode.zig:9054`、`src/parser.zig:3188`、`:3233`。


### `FunctionDef.appendVar` (`src/bytecode.zig:5459`)

- **签名**：`pub fn appendVar(self: *FunctionDefImpl, var_def: VarDef) !i32`。
- **作用**：add_var：追加 VarDef，调用方填 scope/kind。
- **实现**：几何增长；使链接缓存失效。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 `var_name` 只是值拷贝——rc 时代的「The atom is duplicated」注释已改写成「atom id 按值拷贝」，tracing GC 下 atom 没有每槽引用计数（`freeOwnedAtomSlice` 等辅助函数那个从不使用的 `*AtomTable` 形参也已从签名和调用点删除）。调用方：本结构体的六个 `ensure*Binding`（`:5558`/`:5577`/`:5595`/`:5607`/`:5619`/`:5637`）、`ensureArgumentsArgumentBinding`（`:5672`）、`addScopeVar`（`:5758`），finalize 的 `addEvalVariables` 建 var_object/arg_var_object 两行（`src/bytecode.zig:10484`/`:10492`，`catch return error.OutOfMemory`），以及 parser 的 `src/parser.zig:1708`/`:13554`；`src/compiler/` 下的调用全在 test 块内。


### `FunctionDef.appendGlobalVar` (`src/bytecode.zig:5469`)

- **签名**：`pub fn appendGlobalVar(self: *FunctionDefImpl, global_var: GlobalVar) !void`。
- **作用**：追加 GlobalVar 账本项。
- **实现**：几何增长。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配与错误同 `appendVar`（几何增长 + `error{OutOfMemory}`）；`global_vars` 的 backing 由 `deinit` 的 `freeGrowableNamedSlice`（`src/bytecode.zig:5981`）释放，或在 finalize 取走时由 `consumeGlobalVars`（`:5536`）释放——后者只把每行 `var_name` 清成 `null_atom`，不做 atom 释放。调用方全在 parser 的全局声明登记：`src/parser.zig:1894`、`:1906`、`:1922`。


### `FunctionDef.appendArg` (`src/bytecode.zig:5479`)

- **签名**：`pub fn appendArg(self: *FunctionDefImpl, var_def: VarDef) !i32`。
- **作用**：追加形参行，parser 把同名引用降成 get_arg*。
- **实现**：几何增长。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 同时把 `arg_count` 与 `defined_arg_count` 都刷成新长度（默认值/rest 参数之后由 parser 改回 `defined_arg_count`）。调用方全是 parser 的形参构造：`src/parser.zig:11354`、`:11441`、`:12256`、`:12292`、`:12376`、`:13528`。


### `FunctionDef.addChild` (`src/bytecode.zig:5492`)

- **签名**：`pub fn addChild(self: *FunctionDefImpl, child: *FunctionDefImpl) !void`。
- **作用**：把子 FunctionDef 链入 child_list（qjs list_add_tail）。
- **实现**：几何增长指针表。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：父在这里接管 child 指针的所有权（写 `child.parent`、清 `discard_next`），child 由 `FunctionDef.deinit` 递归销毁；本函数自身只为 `child_list` 做几何增长，error set 只有 `error.OutOfMemory`（失败时 child 仍归调用方，parser 用 `errdefer` 销毁）。调用方全在 parser 收尾子函数处：`src/parser.zig:12063`、`:12531`、`:14319`、`:15158`。


### `FunctionDef.addScopeVar` (`src/bytecode.zig:5501`)

- **签名**：`pub fn addScopeVar( self: *FunctionDefImpl, name: atom.Atom, var_kind: VarKind, scope_level: i32, is_lexical: bool, is_const: bool, ) !i32`。
- **作用**：add_scope_var：加 var 并挂到 scope_level 的 first。
- **实现**：更新 scope 头。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：自身不分配，转调 `appendVar`（`error{OutOfMemory}` 由它产生），再把新行挂到 `scopes[scope_level].first` 并更新 `scope_first`；`scope_level` 越界时只是不挂链，不报错。生产调用方只有一处：parser 的 `State.addScopeVar` 包装（`src/parser.zig:1511`，`catch return error.OutOfMemory`，前后各夹一次 linked-declaration 索引写）；parser 里其余 `addScopeVar(...)` 调用（`:1728`/`:1784`/`:1792`/`:8712`/`:8832`/`:14003`）都是那个四参数的 State 包装，不是本函数。


### `FunctionDef.addClosureVar` (`src/bytecode.zig:5530`)

- **签名**：`pub fn addClosureVar(self: *FunctionDefImpl, init_value: ClosureVar.Init) !i32`。
- **作用**：追加闭包行（模块/eval 顶层或捕获）。
- **实现**：可置 monotone 动态 env 旗。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 行内的 `var_name` 同样只是值拷贝，不改 atom 引用；同时在这个唯一增长点维护单调的 `closure_var_may_have_dynamic_env`。调用方：binding_rules 的 `addOrFindClosureSource`（`src/bytecode.zig:6959`）与 `ensureGlobalClosureVar`（`:7024`）、finalize 的 `addGlobalVariables`（`:10625`）、parser 的 `src/parser.zig:3411`/`:3436`/`:15350` 与 eval 闭包种子播种（`:16237`）。


### `FunctionDef.captureBinding` (`src/bytecode.zig:5549`)

- **签名**：`fn captureBinding(self: *FunctionDefImpl, vd: *VarDef) CaptureError!void`。
- **作用**：首次真实捕获立刻分配稳定的 owner-frame cell 下标。
- **实现**：`open_binding_idx` 已不是 `no_open_binding` 说明这行早已分到 cell，只补上 `is_captured` 就返回（下标不重分配）；否则 `var_ref_count < 0` → `error.InvalidBytecode`，下一个序号撞上 `no_open_binding` 哨兵 → `error.BytecodeOverflow`，都通过则置 `is_captured`、把 `var_ref_count` 当作新 cell 下标写进 `open_binding_idx`，再自增 `var_ref_count`。
- **所有权 / 错误 / 调用**：私有；不分配，只改已有行的 `is_captured`/`open_binding_idx` 并推进 `var_ref_count`。error set 是显式的 `CaptureError = error{InvalidBytecode, BytecodeOverflow}`（`src/bytecode.zig:5792`）：`var_ref_count` 为负是发布 bug，下一个索引撞上 `no_open_binding` 哨兵则溢出。两个调用方都在本结构体：`captureLocal`（`:5811`）与 `captureArg`（`:5817`）。


### `FunctionDef.captureLocal` (`src/bytecode.zig:5564`)

- **签名**：`pub fn captureLocal(self: *FunctionDefImpl, idx: usize) CaptureError!void`。
- **作用**：capture_var on vars[idx]。
- **实现**：转 captureBinding。 返回 `error.InvalidBytecode`。 内部 `try` 传播错误。 标记对应槽 `is_captured`。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：不分配、不建 GC 根；error set `CaptureError`——下标越界返回 `error.InvalidBytecode`，其余由 `captureBinding` 产生。调用方（注意与 `Frame.captureLocal`（`src/exec/frame.zig:570`）同名不同型）：binding_rules 的 `markEvalCapturedVariables`（`src/bytecode.zig:6685`）、`markReferenceTakenBinding`（`:8750`）、`threadParentLocalSource`（`:8851`），finalize 的 `captureEvalParentLocal`（`:10421`）与 `addEvalVariables`（`:10525`）；前几处一律 `catch return error.InvalidBytecode`。


### `FunctionDef.captureArg` (`src/bytecode.zig:5570`)

- **签名**：`pub fn captureArg(self: *FunctionDefImpl, idx: usize) CaptureError!void`。
- **作用**：capture_var on args[idx]。
- **实现**：转 captureBinding。 返回 `error.InvalidBytecode`。 内部 `try` 传播错误。 标记对应槽 `is_captured`。 错误臂：`error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：与 `captureLocal` 同协议：不分配，越界即 `error.InvalidBytecode`，其余错误来自 `captureBinding`。调用方 `src/bytecode.zig:8754`（`markReferenceTakenBinding`）、`:8869`（`threadParentArgSource`）、`:10455`（`captureEvalParentArg`）、`:10522`（`addEvalVariables` 给 eval 的父参数全量开洞）、`:11076`（`publishLoweredMetadata`）。


### `FunctionDef.findVar` (`src/bytecode.zig:5578`)

- **签名**：`pub fn findVar(self: *const FunctionDefImpl, name: atom.Atom) i32`。
- **作用**：按名从新到旧找局部，没有返回 -1。
- **实现**：htab-free 路径，quickjs.c:23378。 循环扫描切片或字节码。
- **所有权 / 错误 / 调用**：纯线性读、不分配、无 error set；找不到返回 -1（不是 `null`），新行优先（倒序扫描）。调用方：`src/parser.zig:3083` 与 `:3131`（与 `findArg` 成对判「本函数已有同名绑定」）、`:8710`/`:8830`（TS enum / namespace 的重复声明合并）。


### `FunctionDef.findArg` (`src/bytecode.zig:5587`)

- **签名**：`pub fn findArg(self: *const FunctionDefImpl, name: atom.Atom) i32`。
- **作用**：按名找参数下标，没有 -1。
- **实现**：线性扫。 循环扫描切片或字节码。
- **所有权 / 错误 / 调用**：纯线性读、不分配、无 error set；找不到返回 -1，倒序扫描取最后一个同名形参。调用方比 `findVar` 多：`src/bytecode.zig:7610`（`lookupArg`）、`:9086`/`:9482`（闭包绑定解析），parser 侧 `src/parser.zig:1751`、`:1812`、`:3213` 等。


### `FunctionDef.appendByteCode` (`src/bytecode.zig:5598`)

- **签名**：`pub fn appendByteCode(self: *FunctionDefImpl, bytes: []const u8) !void`。
- **作用**：往 FunctionDef 临时码追加字节。
- **实现**：几何增长。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 空输入直接返回，不触碰缓冲。phase-1 原始字节后端（`appendBytesNoSource` 一族）删除后生产树内已无调用方，只剩 `src/tests/bytecode.zig` 的夹具在用。


### `FunctionDef.truncateSourceLocs` (`src/bytecode.zig:5607`)

- **签名**：`pub fn truncateSourceLocs(self: *FunctionDefImpl, target_len: usize) void`。
- **作用**：回滚源位置槽，不放 capacity。
- **实现**：与 truncateByteCode 配套。
- **所有权 / 错误 / 调用**：不分配、不释放（保留 backing 供重发射复用）、无 error set；只收缩可见 `len` 并同步 `source_loc_count`，越界由断言挡。调用方是 parser 的两个回滚点：`src/parser.zig:2841`（`rollbackEmission`）与 `:3781`（`truncateCode`）。


### `FunctionDef.appendAtomOperand` (`src/bytecode.zig:5613`)

- **签名**：`pub fn appendAtomOperand(self: *FunctionDefImpl, atom_id: atom.Atom) !void`。
- **作用**：登记一条 atom 操作数。
- **实现**：几何增长。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 只把 atom 值写进槽，不提引用（tracing GC 下 atom 无每槽计数）。生产调用方仅一处：`src/parser.zig:15080`，为合成的类字段初始化调用登记 `atom_class_fields_init`。


### `FunctionDef.appendAtomOperandAssumeCapacity` (`src/bytecode.zig:5618`)

- **签名**：`pub fn appendAtomOperandAssumeCapacity(self: *FunctionDefImpl, atom_id: atom.Atom) void`。
- **作用**：已 reserve 后无检查追加。
- **实现**：调用方保证容量。
- **所有权 / 错误 / 调用**：不分配、无 error set；容量不足只有 `std.debug.assert` 挡（ReleaseFast 下会越界写）。原调用方是 parser 原始字节后端里 `emit_to_function_def` 为真的那一臂，该后端已删，本函数现在树内零调用方。


### `FunctionDef.appendCpool` (`src/bytecode.zig:5625`)

- **签名**：`pub fn appendCpool(self: *FunctionDefImpl, value: JSValue) !u32`。
- **作用**：追加常量。
- **实现**：几何增长 JSValue 表。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：分配只发生在 `growSliceBy`（`src/bytecode.zig:5055`）的几何增长里，backing 归 `FunctionDef`，由 `deinit` 的 `freeGrowableSlice` 释放；error set 推导下来只有 `error.OutOfMemory`，它不在此处变成 JS 异常，而是沿 parser 的 `Error` 上抛到 `src/exec/eval_entry.zig:93` 的 `try parser.compile`。 关键所有权事实在别处：写进 `cpool` 的 `JSValue` 在 artifact 发布前唯一的 GC 根是 `FunctionDef.traceCompileRoots`（`src/bytecode.zig:5937`），由 `ParseState.traceCompileValueRoots`（`src/parser.zig:1095`）挂上——本函数把 `cpool_count` 与 `cpool.len` 同步，正是为了让那条精确根覆盖新槽。调用方：`src/parser.zig:7597`（常量字面量）与 `:12026`/`:12529`/`:14317`/`:15156`（为每个嵌套函数预留一个槽）。


### `FunctionDef.traceCompileRoots` (`src/bytecode.zig:5660`)

- **签名**：`pub fn traceCompileRoots( self: *FunctionDefImpl, visitor: *runtime_mod.RootVisitor, ) runtime_mod.RootTraceError!void`。
- **作用**：把 cpool 等编译期活值交给 RootVisitor。
- **实现**：conservative 扫描看不到这些栈外缓冲。 循环扫描切片或字节码。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：不分配、不 retain：只把 `cpool` 切片交给 visitor（`visitor.values`），GC 据此在 artifact 发布前把 RegExp 串、tagged template 数组对、每个嵌套函数预留槽标活；`cpool_count` 与 `cpool.len` 在每个增长点保持相等，所以这条切片就是活集。error set 是 `runtime_mod.RootTraceError`（由 visitor 决定）。调用方：`ParseState.traceCompileValueRoots`（`src/parser.zig:1097`-`:1101`，覆盖根 def、`cur_func_stack` 与 `discarded_func_head` 三种状态）与本函数对 `child_list` 的递归（`src/bytecode.zig:5942`）。


### `FunctionDef.truncateByteCode` (`src/bytecode.zig:5670`)

- **签名**：`pub fn truncateByteCode(self: *FunctionDefImpl, target_len: usize) void`。
- **作用**：截 byte_code 到 watermark，保留 capacity。
- **实现**：投机回滚热路径。
- **所有权 / 错误 / 调用**：不分配、不释放（保留 capacity 供投机回滚后重发射）、无 error set；越界由断言挡。调用方是 parser 的两个回滚点：`src/parser.zig:2842`（`rollbackEmission`）与 `:3801`（`truncateCode`）。


### `FunctionDef.truncateAtomOperands` (`src/bytecode.zig:5678`)

- **签名**：`pub fn truncateAtomOperands(self: *FunctionDefImpl, target_len: usize) void`。
- **作用**：截 atom_operands，保留 backing。
- **实现**：只把可见切片长度改回 `target_len`，backing 与 capacity 不动。
- **所有权 / 错误 / 调用**：不分配、不释放 backing、无 error set。tracing GC 下 atom 是纯值，尾部条目掉出可见窗口不释放任何东西——原先那个只推进下标的空 `while` 循环与「releasing the per-element atom refcounts」注释都已删除。调用方 `src/parser.zig:2840`（`rollbackEmission`）与 `:3811`（`truncateAtomOperands`）。


### `FunctionDef.deinit` (`src/bytecode.zig:5683`)

- **签名**：`pub fn deinit(self: *FunctionDefImpl, rt: anytype) void`。
- **作用**：释放全部编译缓冲、子 FunctionDef、label reloc、cpool 值、source。
- **实现**：先清三个 atom 字段并兜底释放 builder，再依次释放 vars/vars_htab/args/scopes/global_vars/byte_code/atom_operands、label reloc 链与 label_slots、cpool（逐槽 freeOwnedValue）、closure_var、jump_slots、source_loc_slots 与 source（len+1）；**最后**才递归 `child.deinit` 并 destroy 每个子 def，再释放 child_list backing。
- **所有权 / 错误 / 调用**：无 error set，不可失败；`rt` 只透传给 `freeOwnedValue`（`src/bytecode.zig:4966`），用于销毁那些还没发布进 FunctionBytecode 的 reserved cpool BigInt，其余缓冲一律还给 `MemoryAccount`。释放前先把字段置空/清零再释放旧块，所以重复调用安全；`builder` 这一支是 parse 期与错误路径的兜底（成功的 v2 lowering 已在消费点释放它）；`child_list` 里的子 def 由本函数递归 `deinit` 后 `destroy`，父对子指针的所有权来自 `addChild`。



### `function_mod`（Bytecode / adapter / 发布）

### `function_mod.growSliceBy` (`src/bytecode.zig:10978`)

- **签名**：`fn growSliceBy( comptime T: type, mem: *memory.MemoryAccount, slice: *[]T, capacity: *usize, n: usize, ) ![]T`。
- **作用**：扩容 growable 切片。
- **实现**：与 `function_def.growSliceBy` 同形：`new_used <= capacity` 只伸 len；否则 `new_cap = max(new_used, capacity==0 ? 8 : capacity*2)`，`mem.alloc(T, new_cap)` + memcpy 已用部分 + free 旧 backing。此处是有类型的直接实现，不走类型擦除的 noinline 臂。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：与 `function_def.growSliceBy`（`src/bytecode.zig:5055`）同形的私有副本；新块记在 `MemoryAccount`，backing 归调用者的 `Bytecode` 字段并由 `deinit` 的 `freeGrowableSlice` 释放，失败时旧 backing 不动。error set 只有 `error.OutOfMemory`。三个调用方都在 `BytecodeImpl`：`appendCode`、`appendSourceLoc`、`appendAtomOperand`（`reserveAtomOperands` 无调用方，已删）。


### `function_mod.freeGrowableSlice` (`src/bytecode.zig:11003`)

- **签名**：`fn freeGrowableSlice( comptime T: type, mem: *memory.MemoryAccount, slice: *[]T, capacity: *usize, ) void`。
- **作用**：归还一块几何增长缓冲：按 `capacity`（真实分配长度）而不是可见的 used 长度释放，配合 `growSliceBy` 的「slice.len = 已用、capacity = 分配」双计数约定。
- **实现**：`capacity.* != 0` 时用 `slice.ptr[0..capacity.*]` 还原出整块分配；随后先把 `slice.*` 清成空切片、`capacity.*` 归零，最后才 `mem.free`，保证任何重入或后续 `deinit` 都看不到悬空指针。`capacity == 0` 表示这个槽当前不拥有几何缓冲，直接清空不释放。
- **所有权 / 错误 / 调用**：释放走 `MemoryAccount`（计入该编译单元的内存账），无 error set。调用方全在 `BytecodeImpl` 上：`deinit` 释放 `code` 与 `source_loc_slots`，`setCode`、`installCodeWithCapacity`、`installAtomOperandsWithCapacity` 在换缓冲前先释放旧块（无容量参数的 `installCode`/`installAtomOperands` 无调用方，已删）。FunctionDef 侧另有一个同名同形的私有副本（`src/bytecode.zig:5113`），两者互不调用。


### `function_mod.freeOwnedAtomSlice` (`src/bytecode.zig:11016`)

- **签名**：`fn freeOwnedAtomSlice(mem: *memory.MemoryAccount, slot: *[]atom.Atom) void`。
- **作用**：释放 `BytecodeImpl` 自有的精确长度 atom 数组（`var_ref_names`），不涉及容量计数。
- **实现**：先把 `slot.*` 取出并清成空切片，再对非空的 `items` 调 `mem.free`；顺序保证释放期间槽已失效。行内 atom 的引用不在这里归还——rc 时代那个被忽略的首参 `_: *atom.AtomTable` 已从整个 `freeOwned*` 家族的签名和调用点删除。
- **所有权 / 错误 / 调用**：内存经 `MemoryAccount` 归还，无 error set。唯一调用方是 `BytecodeImpl.deinit`（`src/bytecode.zig:11641`）。


### `function_mod.freeOwnedVarDefSlice` (`src/bytecode.zig:11022`)

- **签名**：`fn freeOwnedVarDefSlice(mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.BytecodeVarDef) void`。
- **作用**：释放 `BytecodeImpl` 自有的 `BytecodeVarDef` 行数组（形参表 `argdefs` 与局部表 `vardefs`）。
- **实现**：与 `freeOwnedAtomSlice` 同形：取出 `slot.*`、清空槽、非空才 `mem.free`；行里的 `var_name` atom 不在此释放。
- **所有权 / 错误 / 调用**：无 error set。由 `BytecodeImpl.deinit` 对 `argdefs` 和 `vardefs` 各调一次（`src/bytecode.zig:11639`-`11640`）；注意 finalize 后的行可能是从最终 arguments+locals 表借来的，那种情形下这两个槽为空切片，本函数零工作。


### `function_mod.freeOwnedClosureVarSlice` (`src/bytecode.zig:11028`)

- **签名**：`fn freeOwnedClosureVarSlice(mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.BytecodeClosureVar) void`。
- **作用**：释放 `BytecodeImpl` 自有的 `BytecodeClosureVar` 行数组（`closure_var`，即闭包/var-ref 拓扑表）。
- **实现**：同族三兄弟的第三个：取出、清空槽、非空才 `mem.free`；行里的 `var_name` 引用不在此归还。
- **所有权 / 错误 / 调用**：无 error set。唯一调用方 `BytecodeImpl.deinit`（`src/bytecode.zig:11642`）。这张表同时是 `varRefIsLexicalAt` / `varRefName` 等派生访问器的唯一数据源，所以释放它等于同时废掉那组访问器的后备存储。


### `function_mod.freeGrowableAtomSlice` (`src/bytecode.zig:11034`)

- **签名**：`fn freeGrowableAtomSlice( mem: *memory.MemoryAccount, slice: *[]atom.Atom, capacity: *usize, ) void`。
- **作用**：释放 `atom_operands` 这块几何增长的 atom 缓冲——它既可能由 `growSliceBy` 撑出容量，也可能被 pipeline 换成精确长度切片，所以两种形态都要能收。
- **实现**：先取出 `items` 与 `old_capacity` 并把槽清零，再二选一释放：`old_capacity != 0` 释放 `items.ptr[0..old_capacity]` 整块，否则退化成按 `items` 自身长度释放。这正是它与 `freeGrowableSlice` 的唯一区别（后者在 `capacity == 0` 时视作不拥有、什么都不放）。rc 时代那个被忽略的首参 `_: *atom.AtomTable` 已删：操作数 atom 在 tracing GC 下是纯值。
- **所有权 / 错误 / 调用**：无 error set。调用方：`BytecodeImpl.deinit`（`src/bytecode.zig:11638`）与 FunctionDef 侧同名副本的调用点（`:5984`）互不相干。


### `Bytecode.init` (`src/bytecode.zig:11211`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) BytecodeImpl`。
- **作用**：空可变 Bytecode 载体。
- **实现**：name 同时当 filename/script_or_module；constants.init。
- **所有权 / 错误 / 调用**：借入 account/atoms。


### `Bytecode.deinit` (`src/bytecode.zig:11222`)

- **签名**：`pub fn deinit(self: *BytecodeImpl, rt: anytype) void`。
- **作用**：释放 code/atom_operands/argdefs/vardefs/var_ref_names/closure_var/source_loc_slots/constants/module_record/pc2line。
- **实现**：先把 name/filename/script_or_module 置 null_atom；几何缓冲按 capacity free，owned 切片按 len free；pc2line 只有 `owns_pc2line_buf` 为真才释放。可变 Bytecode 上原有的 `debug_table`（`debug.Table` 那条链）只被单测填充过，已连同 `ensureDebug` 一起删除。
- **所有权 / 错误 / 调用**：rt 传给 `constants.deinit`（reserved BigInt）。


### `Bytecode.byteCode` (`src/bytecode.zig:11244`)

- **签名**：`pub inline fn byteCode(self: *const BytecodeImpl) []const u8`。
- **作用**：读取字段或切片。
- **实现**：返回 `self.code`。
- **所有权 / 错误 / 调用**：返回借用切片，不分配、无 error set；`code.len` 是已用长度，backing 是 `code.ptr[0..code_capacity]`，由 `deinit` 的 `freeGrowableSlice` 释放。非测试树里没有以 `Bytecode` 为接收者的调用方——解释器读的是 `FunctionBytecode.byteCode()`，legacy adapter 也只转发 `varRef*` 家族（`src/bytecode.zig:4155`-`:4174`），其余字段直取 `legacy.code`。


### `Bytecode.funcName` (`src/bytecode.zig:11247`)

- **签名**：`pub inline fn funcName(self: *const BytecodeImpl) atom.Atom`。
- **作用**：读出这份可变编译期字节码记录的函数名 atom（`self.name`）。
- **实现**：单字段直读。`Bytecode.init` 会把同一个 atom 同时填进 `name`、`filename`、`script_or_module` 作默认值，之后三者可各自被改写（例如 eval 的 filename 固定成 `<eval>`）。
- **所有权 / 错误 / 调用**：借用读，不改引用计数，无 error set。发布时 `LegacyExecutionAdapter.init` 把 `source.name` 抄进 `FunctionBytecode.func_name`（`src/bytecode.zig:12036`）；运行期同一事实由 `FunctionBytecode.funcName`（`:4151`）提供，本 getter 服务于仍持有可变 `Bytecode` 的编译期与夹具路径。


### `Bytecode.argVarDefs` (`src/bytecode.zig:11250`)

- **签名**：`pub inline fn argVarDefs(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeVarDef`。
- **作用**：读出形参行表 `argdefs`（每行一个 `BytecodeVarDef`：名字、是否被捕获、`var_ref_idx`）。
- **实现**：直接返回 `self.argdefs` 的只读视图，不做长度或 `arg_count` 一致性校验。
- **所有权 / 错误 / 调用**：借用切片，生命周期绑在这份 `Bytecode` 上（`deinit` 里由 `freeOwnedVarDefSlice` 释放）。无 error set。`FunctionBytecode.argVarDefs` 的 legacy-adapter 臂返回的正是同一块 `legacy.argdefs`（`src/bytecode.zig:4116`），`argOpenBindingIndex` 再从中取捕获槽号。


### `Bytecode.varDefs` (`src/bytecode.zig:11253`)

- **签名**：`pub inline fn varDefs(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeVarDef`。
- **作用**：读出局部变量行表 `vardefs`（紧凑的 `BytecodeVarDef` 行，用 `has_scope` 取代编译期的数值 scope level，与 qjs `JSBytecodeVarDef` 同形）。
- **实现**：直接返回 `self.vardefs` 的只读视图；这张表在 finalize 后可能是从最终 arguments+locals 表借来的，也可能由可变根 `Bytecode` 自有。
- **所有权 / 错误 / 调用**：借用切片，无 error set。`FunctionBytecode.varDefs` 的 legacy 臂直接返回同一块（`src/bytecode.zig:4120`），`localOpenBindingIndex` 由它派生捕获槽号。


### `Bytecode.closureVar` (`src/bytecode.zig:11256`)

- **签名**：`pub inline fn closureVar(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeClosureVar`。
- **作用**：读出闭包行表 `closure_var`（每行记 `closure_type`、`var_idx`、`var_name` 与 lexical/const 位），是 var-ref 一切派生元数据的唯一权威。
- **实现**：直接返回 `self.closure_var` 的只读视图。zjs 刻意不再维护并行的 `[]bool` 镜像：lexical / const / global-decl 三种状态一律由 `varRefIsLexicalAt` 等访问器在读时从这张表算出。
- **所有权 / 错误 / 调用**：借用切片，由 `deinit` 经 `freeOwnedClosureVarSlice` 释放。无 error set。`FunctionBytecode.closureVar` 的 legacy 臂返回同一块（`src/bytecode.zig:4128`）；`LegacyExecutionAdapter.init` 用它的长度（为 0 时退回 `var_ref_names.len`）填 `closure_var_count`（`:12042`）。


### `Bytecode.cpoolSlice` (`src/bytecode.zig:11259`)

- **签名**：`pub inline fn cpoolSlice(self: *const BytecodeImpl) []const JSValue`。
- **作用**：读取字段或切片。
- **实现**：返回 `self.constants.values`。
- **所有权 / 错误 / 调用**：返回 `constants.values` 的借用切片，不分配、无 error set；池里的值由 `constant.Pool.deinit` 负责（它对未发布的 reserved BigInt 调 `freeOwnedValue`），发布前的 GC 根是 `Bytecode.traceCompileRoots`（`src/bytecode.zig:11921`）。非测试树里没有以 `Bytecode` 为接收者的调用方，39 处 `.cpoolSlice()` 读数全落在 `FunctionBytecode` 上。


### `Bytecode.constantAt` (`src/bytecode.zig:11262`)

- **签名**：`pub inline fn constantAt(self: *const BytecodeImpl, index: usize) ?JSValue`。
- **作用**：按常量池下标取常量值，越界返回 null——供 `push_const` 一类带 cpool 操作数的指令做边界安全的读取。
- **实现**：转交 `constant.Pool.get`（`src/bytecode.zig:2930`），它先 `index >= values.len` 判越界再返回元素，因此本函数天然是 optional 口径而不是 panic。
- **所有权 / 错误 / 调用**：返回的是池内 `JSValue` 的拷贝，不加引用计数；池由 `constants.deinit` 统一释放。无 error set。运行期同名的 `FunctionBytecode.constantAt`（`src/bytecode.zig:4146`）走 `cpoolSlice`，VM 侧把它的 null 翻成 `error.TypeError`（`src/exec/vm_value.zig:89`）或 `error.InvalidBytecode`（`src/exec/tailcall_dispatch.zig:3626`）。


### `Bytecode.pc2lineBuf` (`src/bytecode.zig:11265`)

- **签名**：`pub inline fn pc2lineBuf(self: *const BytecodeImpl) []const u8`。
- **作用**：读出 pc→行列映射的编码缓冲 `pc2line_buf`，异常栈回溯按它把 pc 还原成源码位置。
- **实现**：单字段直读，返回只读视图；缓冲本身是否自有由另一字段 `owns_pc2line_buf` 记录（`installPc2Line` 负责维护），本 getter 不看这个标志。
- **所有权 / 错误 / 调用**：借用切片；`deinit` 只在 `owns_pc2line_buf` 为真时释放它。无 error set。`FunctionBytecode.pc2lineBuf` 的 legacy 臂返回同一块（`src/bytecode.zig:4272`），消费者是 `src/exec/exception_ops.zig:474`/`:745` 的行号解码。


### `Bytecode.lineNum` (`src/bytecode.zig:11268`)

- **签名**：`pub inline fn lineNum(self: *const BytecodeImpl) i32`。
- **作用**：读出函数体起始行号（`line_num`，`init` 默认 1），作为 pc2line 增量解码的基准行。
- **实现**：单字段直读，不校验正负；`appendSourceLoc` 会丢弃 `line_num <= 0` 的记录，所以基准值恒为正。
- **所有权 / 错误 / 调用**：无 error set。`FunctionBytecode.lineNum` 的 legacy 臂返回同一字段（`src/bytecode.zig:4297`）；运行期消费者是 `src/exec/exception_ops.zig:475`、`:493` 的栈帧行列填充。


### `Bytecode.colNum` (`src/bytecode.zig:11271`)

- **签名**：`pub inline fn colNum(self: *const BytecodeImpl) i32`。
- **作用**：读出函数体起始列号（`col_num`，`init` 默认 1），与 `lineNum` 成对做 pc2line 解码基准。
- **实现**：单字段直读。与行号同理，`appendSourceLoc` 拒收非正列号。
- **所有权 / 错误 / 调用**：无 error set。对应 `FunctionBytecode.colNum` 的 legacy 臂（`src/bytecode.zig:4308`）；`src/exec/exception_ops.zig:475`/`:494` 与 `src/exec/small_inline.zig:1400`/`:1413` 用它拼被展开站点的源位置。


### `Bytecode.scriptOrModule` (`src/bytecode.zig:11274`)

- **签名**：`pub inline fn scriptOrModule(self: *const BytecodeImpl) atom.Atom`。
- **作用**：读出稳定的 ScriptOrModule 身份 atom，宿主按它解析 import 的 referrer。
- **实现**：单字段直读。它与 `filename` 分开存正是因为 eval 的 `filename` 固定为 `<eval>`，而 referrer 必须仍指向真正的宿主脚本/模块。
- **所有权 / 错误 / 调用**：借用 atom，不改引用计数，无 error set。`FunctionBytecode.scriptOrModule` 的 legacy 臂读同一字段（`src/bytecode.zig:4322`）；运行期消费者包括模块查找 `src/exec/object_ops.zig:1949`、动态 import 的 referrer 路径 `src/exec/vm_eval_module.zig:124`、GC 的 atom 访问 `src/core/gc_trace_stw.zig:170`。


### `Bytecode.realmContext` (`src/bytecode.zig:11277`)

- **签名**：`pub inline fn realmContext(self: *const BytecodeImpl) ?*context.RealmContext`。
- **作用**：读出这份字节码所属 realm 的借用指针（可为 null）。
- **实现**：单字段直读，返回 `?*context.RealmContext`。可变的 legacy/模块/夹具字节码把它留空，改由模块或测试入口在进入时补 realm——这就是返回类型是 optional 的原因。
- **所有权 / 错误 / 调用**：借用指针，`Bytecode` 不持有 realm 生命周期。无 error set。`FunctionBytecode.realmContext` 的 legacy 臂读同一字段（`src/bytecode.zig:4494`）；消费者如 `src/exec/object_ops.zig:302`（null 即 `error.InvalidBytecode`）、`src/exec/small_inline.zig:334`（跨 realm 一律不展开）、`publishExecutionFlags` 的字节数统计（`src/bytecode.zig:12219`）。


### `Bytecode.isGlobalVar` (`src/bytecode.zig:11280`)

- **签名**：`pub inline fn isGlobalVar(self: *const BytecodeImpl) bool`。
- **作用**：该字节码是不是「全局 var 作用域」的根（脚本、模块或 sloppy 间接 eval），决定进入 VM 前要不要跑全局声明实例化。
- **实现**：读 `flags.is_global_var` 这一位（`Flags` 的 bit 8）。
- **所有权 / 错误 / 调用**：无 error set。`FunctionBytecode.isGlobalVar` 的 legacy 臂读同一位、而规范 FB 恒返回 false（`src/bytecode.zig:4192`：正式根在进 VM 前已完成 closure2，只有夹具适配器还要求运行期实例化声明）；消费者是 `src/exec/zjs_vm.zig:446`/`:553` 与 `src/exec/inline_calls.zig:3142`。


### `Bytecode.isModule` (`src/bytecode.zig:11283`)

- **签名**：`pub inline fn isModule(self: *const BytecodeImpl) bool`。
- **作用**：该字节码根是不是 ECMAScript 模块体。
- **实现**：读 `flags.is_module`（`Flags` bit 9）。注意运行期同名 getter 走的是另一条线：`FunctionBytecode.isModule` 读 `callFacts().execution.is_module`（`src/bytecode.zig:4195`），两者由 `LegacyExecutionAdapter.init` 在发布 `ExecutionFlags` 时对接（`:12062`）。
- **所有权 / 错误 / 调用**：无 error set。模块体这一位在 small-inline 里与 eval 一起被排除（`src/exec/small_inline.zig:377`）。


### `Bytecode.functionKind` (`src/bytecode.zig:11286`)

- **签名**：`pub inline fn functionKind(self: *const BytecodeImpl) function_bytecode_mod.FunctionKind`。
- **作用**：把编译期的两个独立标志合成 `normal` / `generator` / `async` / `async_generator` 四类之一。
- **实现**：四臂 if 链：`is_async and is_generator` → `.async_generator`，只 `is_async` → `.async`，只 `is_generator` → `.generator`，否则 `.normal`。与运行期不同——`FunctionBytecode.functionKind` 是从 `flag_byte17` 里取两位（`src/bytecode.zig:3985`），可变记录这边没有打包字段，所以每次现算。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 并不调用本函数，而是把同一条 if 链原样内联了一份来算 `func_kind`（`src/bytecode.zig:12006`-`12013`）后交给 `applyFlags`。


### `Bytecode.isDerivedClassConstructor` (`src/bytecode.zig:11296`)

- **签名**：`pub inline fn isDerivedClassConstructor(self: *const BytecodeImpl) bool`。
- **作用**：该函数体是不是 `class X extends Y` 的构造器（`this` 在 `super()` 前处于 TDZ）。
- **实现**：读 `flags.is_derived_class_constructor`（`Flags` bit 2）。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 把这一位经 `applyFlags` 搬进 `flag_byte17`（`src/bytecode.zig:12026`），之后运行期一律查 `FunctionBytecode.isDerivedClassConstructor`。


### `Bytecode.hasPrototype` (`src/bytecode.zig:11299`)

- **签名**：`pub inline fn hasPrototype(self: *const BytecodeImpl) bool`。
- **作用**：该函数对象要不要挂 `.prototype`（普通函数与 generator 要，箭头/方法/访问器不要）。
- **实现**：读 `flags.has_prototype`（`Flags` bit 0，默认 false）。
- **所有权 / 错误 / 调用**：无 error set。经 `LegacyExecutionAdapter.init` → `applyFlags` 发布进 `flag_byte17`（`src/bytecode.zig:12024`）。


### `Bytecode.hasSimpleParameterList` (`src/bytecode.zig:11302`)

- **签名**：`pub inline fn hasSimpleParameterList(self: *const BytecodeImpl) bool`。
- **作用**：形参表是否「简单」（无默认值、无解构、无 rest）——mapped `arguments` 与全部内联族的规范前置条件。
- **实现**：读 `flags.has_simple_parameter_list`。这是 `Flags` 里唯一默认值为 `true` 的位（bit 1），解析到复杂形参时才清零。
- **所有权 / 错误 / 调用**：无 error set。经 `applyFlags` 发布（`src/bytecode.zig:12025`）；运行期由 `FunctionBytecode.hasSimpleParameterList` 供 `src/exec/object_ops.zig:2309` 的 mapped-arguments 判定等使用。


### `Bytecode.needHomeObject` (`src/bytecode.zig:11305`)

- **签名**：`pub inline fn needHomeObject(self: *const BytecodeImpl) bool`。
- **作用**：函数体里出现过 `super.x` 引用，创建函数对象时必须绑定 `[[HomeObject]]`。
- **实现**：读 `flags.need_home_object`（`Flags` bit 3）。
- **所有权 / 错误 / 调用**：无 error set。经 `LegacyExecutionAdapter.init` → `applyFlags` 搬进 `flag_byte17`（`src/bytecode.zig:12027`）。


### `Bytecode.newTargetAllowed` (`src/bytecode.zig:11308`)

- **签名**：`pub inline fn newTargetAllowed(self: *const BytecodeImpl) bool`。
- **作用**：函数体内是否允许 `new.target`。
- **实现**：读的是 `entry_contract.new_target_allowed`——注意这四条语法许可存在独立的 `EntryContract` 结构里，不在 `flags` 打包位里。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 从 `source.entry_contract` 取值交给 `applyFlags`（`src/bytecode.zig:12029`），发布后由 `FunctionBytecode.entryContract` 重新组装。


### `Bytecode.superCallAllowed` (`src/bytecode.zig:11311`)

- **签名**：`pub inline fn superCallAllowed(self: *const BytecodeImpl) bool`。
- **作用**：函数体内是否允许 `super(...)`（派生类构造器及其内部箭头函数）。
- **实现**：读 `entry_contract.super_call_allowed`。
- **所有权 / 错误 / 调用**：无 error set。经 `LegacyExecutionAdapter.init` → `applyFlags` 发布（`src/bytecode.zig:12030`）。


### `Bytecode.superAllowed` (`src/bytecode.zig:11314`)

- **签名**：`pub inline fn superAllowed(self: *const BytecodeImpl) bool`。
- **作用**：函数体内是否允许 `super.x` 属性访问（方法与类体内函数）。
- **实现**：读 `entry_contract.super_allowed`。
- **所有权 / 错误 / 调用**：无 error set。经 `LegacyExecutionAdapter.init` → `applyFlags` 发布进 `flag_byte18`（`src/bytecode.zig:12031`）。


### `Bytecode.argumentsAllowed` (`src/bytecode.zig:11317`)

- **签名**：`pub inline fn argumentsAllowed(self: *const BytecodeImpl) bool`。
- **作用**：函数体内是否允许引用 `arguments`（箭头函数与模块体不允许）。
- **实现**：读 `entry_contract.arguments_allowed`。
- **所有权 / 错误 / 调用**：无 error set。经 `LegacyExecutionAdapter.init` → `applyFlags` 发布（`src/bytecode.zig:12032`）；直接 eval 编译时 `src/parser.zig:15896` 从外层 FB 的同名事实继承这条许可。


### `Bytecode.isDirectOrIndirectEval` (`src/bytecode.zig:11320`)

- **签名**：`pub inline fn isDirectOrIndirectEval(self: *const BytecodeImpl) bool`。
- **作用**：这份字节码是不是 eval 编译出来的（直接与间接都置位）。
- **实现**：读 `flags.is_direct_or_indirect_eval`（`Flags` bit 10）。
- **所有权 / 错误 / 调用**：无 error set。经 `applyFlags` 发布进 `flag_byte18` 的 eval 位（`src/bytecode.zig:12033`）；运行期决定全局 var 声明的校验口径（`src/exec/object_ops.zig:453`）与 small-inline 排除（`src/exec/small_inline.zig:377`）。


### `Bytecode.isAsync` (`src/bytecode.zig:11323`)

- **签名**：`pub inline fn isAsync(self: *const BytecodeImpl) bool`。
- **作用**：函数是否带 `async`（与 `isGenerator` 正交，两者都真即 async generator）。
- **实现**：读 `flags.is_async`（`Flags` bit 4）。它不是 `functionKind()` 的结果，而是后者的输入之一。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 用它与 `is_generator` 合成 `func_kind`（`src/bytecode.zig:12006`）；运行期改由 `FunctionBytecode.isAsync` 从 `functionKind()` 反推（`:4197`）。


### `Bytecode.isGenerator` (`src/bytecode.zig:11326`)

- **签名**：`pub inline fn isGenerator(self: *const BytecodeImpl) bool`。
- **作用**：函数是否带 `function*`（与 `isAsync` 正交）。
- **实现**：读 `flags.is_generator`（`Flags` bit 5），同样是 `functionKind()` 的输入位而非派生结果。
- **所有权 / 错误 / 调用**：无 error set。与 `isAsync` 一同决定适配器发布的 `func_kind`（`src/bytecode.zig:12006`-`12013`）；运行期 `FunctionBytecode.isGenerator` 由 kind 反推。


### `Bytecode.entryContract` (`src/bytecode.zig:11329`)

- **签名**：`pub inline fn entryContract(self: *const BytecodeImpl) EntryContract`。
- **作用**：一次取回四条入口语法许可（`new.target` / `super()` / `super.x` / `arguments`）的整份 `EntryContract`。
- **实现**：按值返回 `self.entry_contract` 结构，不做任何合成——与运行期的 `FunctionBytecode.entryContract` 不同，后者在非 legacy 臂上要从 `flag_byte17`/`flag_byte18` 四个位重新拼一个出来（`src/bytecode.zig:4203`）。
- **所有权 / 错误 / 调用**：值拷贝、无 error set。直接 eval 编译时，`src/parser.zig:15892` 用外层函数的同一份契约初始化被 eval 出来的函数体。


### `Bytecode.isStrictMode` (`src/bytecode.zig:11332`)

- **签名**：`pub inline fn isStrictMode(self: *const BytecodeImpl) bool`。
- **作用**：该函数体是否处于严格模式（源码里的 `"use strict"` 或所在语境强制严格）。
- **实现**：读 `flags.is_strict`（`Flags` bit 6）。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 把它经 `applyFlags` 写进 QuickJS 的 `js_mode` 严格位（`src/bytecode.zig:12022`），因此运行期 `FunctionBytecode.isStrictMode` 只需一次 core 加载、不必探扩展尾。


### `Bytecode.runtimeStrictMode` (`src/bytecode.zig:11335`)

- **签名**：`pub inline fn runtimeStrictMode(self: *const BytecodeImpl) bool`。
- **作用**：运行期生效的严格语义（与源码 `is_strict` 分开记，覆盖模块体、类体这类语法上未写 `"use strict"` 但语义为严格的情形）。
- **实现**：读 `flags.runtime_strict`（`Flags` bit 7）。`publishExecutionFlags` 取 `isStrictMode() or runtimeStrictMode()` 的并作为内联分类用的 `strict_mode`（`src/bytecode.zig:12178`）。
- **所有权 / 错误 / 调用**：无 error set。经 `applyFlags` 发布进 `flag_byte18` 的 `runtime_strict` 位（`src/bytecode.zig:12023`）。


### `Bytecode.hasMappedArguments` (`src/bytecode.zig:11338`)

- **签名**：`pub inline fn hasMappedArguments(self: *const BytecodeImpl) bool`。
- **作用**：该函数运行期创建的 `arguments` 对象是否与形参双向联动（spec 的 CreateMappedArgumentsObject 情形）。
- **实现**：读 `flags.has_mapped_arguments`（`Flags` bit 12）。mapped 形态会把每个实参槽都变成开放别名，因此它比静态捕获集更宽。
- **所有权 / 错误 / 调用**：无 error set。`LegacyExecutionAdapter.init` 把它作为 `ExecutionFlags.has_mapped_arguments` 发布（`src/bytecode.zig:12052`），正式路径则由 `publishExecutionFlags` 的同名入参写入。


### `Bytecode.simpleInlineEligible` (`src/bytecode.zig:11341`)

- **签名**：`pub inline fn simpleInlineEligible(self: *const BytecodeImpl) bool`。
- **作用**：sloppy 模式下的简单帧内联资格（只是字节码侧的一半判据，调用点侧的条件仍在 exec 内联路径上查）。
- **实现**：读独立的 `simple_inline_eligible` 字节——它没有挤进 `Flags` 的 u16 打包字里，为的是让既有 sloppy 热路径保持单字节测试。
- **所有权 / 错误 / 调用**：无 error set。由 `LegacyExecutionAdapter.init` 发布成 `ExecutionFlags.simple_inline_eligible`（`src/bytecode.zig:12053`）；正式路径上同一位由 `publishExecutionFlags` 按 `simple_inline_base and !strict_mode` 算出（`:12225`）。


### `Bytecode.strictSimpleInlineEligible` (`src/bytecode.zig:11344`)

- **签名**：`pub inline fn strictSimpleInlineEligible(self: *const BytecodeImpl) bool`。
- **作用**：`simpleInlineEligible` 的 strict 孪生：strict 且不物化 `arguments` 的简单帧内联资格。
- **实现**：读独立字节 `strict_simple_inline_eligible`。单独一个字段而非复用 sloppy 位，是为了让 sloppy 热路径不必为 strict 多加一次分支；strict 臂唯一的语义差别是保留 undefined 的裸 `this`。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布成同名 `ExecutionFlags` 位（`src/bytecode.zig:12054`）；正式口径见 `publishExecutionFlags`（`:12226`）。


### `Bytecode.strictSimpleSnapshotInlineEligible` (`src/bytecode.zig:11347`)

- **签名**：`pub inline fn strictSimpleSnapshotInlineEligible(self: *const BytecodeImpl) bool`。
- **作用**：strict 且会物化 `arguments` 的简单帧内联资格：进帧时要先给实参拍快照，之后可变形参槽再怎么改都不影响 `arguments`。
- **实现**：读独立字节 `strict_simple_snapshot_inline_eligible`，与上一个字段互斥（同为 strict，按是否物化 `arguments` 二分）。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布（`src/bytecode.zig:12055`）；正式口径 `simple_inline_base and strict_mode and materializes_arguments_object`（`:12227`）。


### `Bytecode.simpleInlineEmptyLeaf` (`src/bytecode.zig:11350`)

- **签名**：`pub inline fn simpleInlineEmptyLeaf(self: *const BytecodeImpl) bool`。
- **作用**：零参 sloppy 空叶：帧里既没有局部/捕获/开放引用窗口，也拿不到冷状态，可以走最省的内联臂。
- **实现**：这一位是本组里唯一仍住在打包字里的——读 `flags.simple_inline_empty_leaf`（`Flags` bit 13，原先的保留位），好让既成的 sloppy 判定保持单比特测试，而 strict 孪生只能另起 `raw_this_inline_empty_leaf` 字节。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布成 `ExecutionFlags.simple_inline_empty_leaf`（`src/bytecode.zig:12056`）；正式口径要求 `empty_leaf_geometry` 且栈 BFS 证明返回平衡（`:12228`）。


### `Bytecode.rawThisInlineEmptyLeaf` (`src/bytecode.zig:11353`)

- **签名**：`pub inline fn rawThisInlineEmptyLeaf(self: *const BytecodeImpl) bool`。
- **作用**：零参 strict 空叶：帧几何与 sloppy 空叶完全相同，区别只在保留调用方传入的裸 `this` 字而不替换成 realm 全局对象。
- **实现**：读独立字节 `raw_this_inline_empty_leaf`（不进打包字，理由同上）。普通调用点选 undefined-`this` 臂，方法接收者臂与模式无关。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布（`src/bytecode.zig:12057`）；正式口径 `simple_inline_base and strict_mode and empty_leaf_geometry`（`:12229`）。


### `Bytecode.simpleInlineExactArgsLeaf` (`src/bytecode.zig:11356`)

- **签名**：`pub inline fn simpleInlineExactArgsLeaf(self: *const BytecodeImpl) bool`。
- **作用**：精确 argc 的 sloppy 叶：空叶家族的有参推广（`arg_count > 0`），调用点给足恰好 `arg_count` 个实参时就地借用调用方操作数区（对应 qjs `arg_buf = argv`，quickjs.c:17841）。
- **实现**：读独立字节 `simple_inline_exact_args_leaf`。之所以与 strict 版分成两个字节而不折成一位，是因为实测折叠会给既成 sloppy 臂多花约 3 insn/call。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布（`src/bytecode.zig:12058`）；正式口径 `simple_inline_base and !strict_mode and arg_count > 0 and leaf_body_geometry`（`:12230`）。


### `Bytecode.rawThisInlineExactArgsLeaf` (`src/bytecode.zig:11359`)

- **签名**：`pub inline fn rawThisInlineExactArgsLeaf(self: *const BytecodeImpl) bool`。
- **作用**：精确 argc 的 strict 叶：与上一条同几何，但像 `rawThisInlineEmptyLeaf` 一样原样保留传入的 `this` 字。
- **实现**：读独立字节 `raw_this_inline_exact_args_leaf`，与 sloppy 版互斥。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布（`src/bytecode.zig:12059`）；正式口径见 `publishExecutionFlags`（`src/bytecode.zig:12231`）。


### `Bytecode.exactArgsLeafKind` (`src/bytecode.zig:11362`)

- **签名**：`pub inline fn exactArgsLeafKind(self: *const BytecodeImpl) function_bytecode_mod.ExactArgsLeafKind`。
- **作用**：把上面两个互斥的精确-argc 位融成一个分派字节，让调用解析一次加载就答出「是不是精确-argc 叶、以及哪种 `this` 策略」。
- **实现**：读 `exact_args_leaf_kind`（`ExactArgsLeafKind`：`none`/`sloppy`/`raw_this`）。现实里带参调用臂上占主导的是非叶被调方，所以未命中必须只花一次字节测试而不是两次——两字节链实测在 call-closure-two-arg 上多 1.3% insn。两个布尔字节仍保留，供断言与资格测试。
- **所有权 / 错误 / 调用**：无 error set。经适配器发布成同名 `ExecutionFlags` 字段（`src/bytecode.zig:12060`）；正式口径 `sloppy_exact` → `.sloppy`、`raw_exact` → `.raw_this`、否则 `.none`（`:12232`）。


### `Bytecode.varRefIsLexicalAt` (`src/bytecode.zig:11369`)

- **签名**：`pub inline fn varRefIsLexicalAt(self: *const BytecodeImpl, idx: usize) bool`。
- **作用**：问第 `idx` 个 var-ref 是不是词法绑定（`let`/`const`/class），据此决定读到 uninitialized 值时要不要抛 TDZ 错误。
- **实现**：先做 `idx >= self.closure_var.len` 的保守越界检查（合成夹具的下标可能越过表尾，一律返回 false），再转交行上的 `closure_var[idx].isLexical()`。这一族访问器刻意从 `closure_var` 现算，而不是维护并行 `[]bool` 镜像——与 qjs 只保留 `JSClosureVar` 的做法一致。
- **所有权 / 错误 / 调用**：纯读、无 error set。`FunctionBytecode.varRefIsLexicalAt` 的 legacy-adapter 臂直接转调本函数（`src/bytecode.zig:4155`），正式 FB 则在自己的 `closureVar()` 上做同样两步；运行期消费者是 `src/exec/call_runtime.zig:5048` 的 TDZ 判定。


### `Bytecode.varRefIsConstAt` (`src/bytecode.zig:11373`)

- **签名**：`pub inline fn varRefIsConstAt(self: *const BytecodeImpl, idx: usize) bool`。
- **作用**：问第 `idx` 个 var-ref 是不是 `const` 绑定，写入时据此抛 TypeError。
- **实现**：同族三兄弟的第二个：越界返回 false，否则返回 `closure_var[idx].isConst()`。
- **所有权 / 错误 / 调用**：纯读、无 error set。由 `FunctionBytecode.varRefIsConstAt` 的 legacy 臂转调（`src/bytecode.zig:4160`）；运行期消费者 `src/exec/vm_call.zig:366` 在写 var-ref 前查这一位。


### `Bytecode.varRefIsGlobalDeclAt` (`src/bytecode.zig:11377`)

- **签名**：`pub inline fn varRefIsGlobalDeclAt(self: *const BytecodeImpl, idx: usize) bool`。
- **作用**：问第 `idx` 个 var-ref 是不是顶层全局声明行（`closure_type == .global_decl`，对应 qjs `JS_CLOSURE_GLOBAL_DECL`），这类引用要落到全局对象而非闭包单元。
- **实现**：越界返回 false，否则比较 `closure_var[idx].closureType() == .global_decl`。
- **所有权 / 错误 / 调用**：纯读、无 error set。由 `FunctionBytecode.varRefIsGlobalDeclAt` 的 legacy 臂转调（`src/bytecode.zig:4165`）；运行期消费者 `src/exec/slot_ops.zig:142` 与 `src/exec/vm_call.zig:356`。


### `Bytecode.varRefNamesLen` (`src/bytecode.zig:11386`)

- **签名**：`pub inline fn varRefNamesLen(self: *const BytecodeImpl) usize`。
- **作用**：给出 var-ref 名字表的有效长度，同时兼容两种存法：自带名字镜像的可变/夹具字节码，和只把名字存在 `closure_var` 行里的最终形态。
- **实现**：`var_ref_names.len != 0` 时返回镜像长度，否则回落到 `closure_var.len`。两者不做一致性校验，谁非空谁说了算。
- **所有权 / 错误 / 调用**：纯读、无 error set。`FunctionBytecode.varRefNamesLen` 的 legacy 臂转调本函数、正式 FB 走 `closureVarCount()`（`src/bytecode.zig:4169`-`4171`）；运行期消费者如 `src/exec/frame.zig:237`、`src/exec/call_runtime.zig:5032`、`src/exec/slot_ops.zig:135` 都用它给遍历定上界。


### `Bytecode.varRefName` (`src/bytecode.zig:11389`)

- **签名**：`pub inline fn varRefName(self: *const BytecodeImpl, idx: usize) atom.Atom`。
- **作用**：取第 `idx` 个 var-ref 的名字 atom，用于 TDZ / 只读错误消息以及 `scope_*` 的按名解析。
- **实现**：与 `varRefNamesLen` 同一条二选一规则：镜像 `var_ref_names` 非空就直接索引它，否则取 `closure_var[idx].var_name`。这里**不做**越界检查，调用方必须先用 `varRefNamesLen()` 收敛下标。
- **所有权 / 错误 / 调用**：返回借用 atom，不加引用计数，无 error set；越界是调用方的错误。`FunctionBytecode.varRefName` 的 legacy 臂转调本函数（`src/bytecode.zig:4174`）；运行期消费者 `src/exec/vm_call.zig:348`、`src/exec/vm_property.zig:65`/`:175`、`src/exec/slot_ops.zig:136` 都先比对长度再取名。


### `Bytecode.setCode` (`src/bytecode.zig:11394`)

- **签名**：`pub fn setCode(self: *BytecodeImpl, bytes: []const u8) !void`。
- **作用**：用拷贝替换 Bytecode.code。
- **实现**：先 `freeGrowableSlice` 释放旧 backing；空输入直接返回（code 留空）；否则 alloc+memcpy，capacity 记为精确长度。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：先无条件释放旧 backing 再精确分配一块新的并拷入（不是几何增长，`code_capacity == bytes.len`）；空输入把 `code` 留成空切片。error set 只有 `error.OutOfMemory`，但注意释放在分配之前——失败后 `Bytecode` 的旧码已经没了。生产树内无调用方：pipeline 走 `installCodeWithCapacity`，本名只被夹具与测试用（`src/tests/helpers.zig:53`/`:58`、`src/tests/bytecode.zig:112`、`src/exec/vm_value.zig:586` 等 test 块）。


### `Bytecode.appendCode` (`src/bytecode.zig:11407`)

- **签名**：`pub fn appendCode(self: *BytecodeImpl, bytes: []const u8) !void`。
- **作用**：几何增长追加最终/中间码。
- **实现**：len 是已用。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：经 `growSliceBy` 几何增长 `MemoryAccount` 上的 `code` 缓冲，backing 归 `Bytecode`（`deinit` 的 `freeGrowableSlice`）；error set 只有 `error.OutOfMemory`，空输入直接返回。原来的唯一生产调用方是 parser 的 `appendBytesNoSource`，随 phase-1 原始字节后端一并删除；现在只有 `src/tests/bytecode.zig` 的夹具调用。


### `Bytecode.appendSourceLoc` (`src/bytecode.zig:11413`)

- **签名**：`pub fn appendSourceLoc(self: *BytecodeImpl, pc: u32, line_num: i32, col_num: i32) !void`。
- **作用**：追加 (pc,line,col) 槽。
- **实现**：`line_num <= 0 或 col_num <= 0` 直接丢弃；断言 pc 单调不减（phase-2 流式重映射 P2-R1T 的要求）；与码、atom 同一事务。 内部 `try` 传播错误。 经几何增长缓冲追加。
- **所有权 / 错误 / 调用**：几何增长 + `error{OutOfMemory}`；非正的行列号直接丢弃，pc 单调不减由断言守。生产树内无调用方：唯一调用点是测试助手 `publishPhase1Stream`（`src/tests/parser.zig:6799`），它把 phase-1 的 slot 流灌进一个可变 carrier 供字节序列断言检查。


### `Bytecode.truncateSourceLocs` (`src/bytecode.zig:11424`)

- **签名**：`pub fn truncateSourceLocs(self: *BytecodeImpl, target_len: usize) void`。
- **作用**：回滚源位置槽，不放 capacity。
- **实现**：`FunctionDef.truncateSourceLocs` 的根字节码对应物，与 `truncateCode` 配套；只改 slice 长度（BytecodeImpl 无 source_loc_count 计数字段）。
- **所有权 / 错误 / 调用**：不分配、不释放、无 error set，只收缩可见 `len`（与 `FunctionDef.truncateSourceLocs` 不同，这里没有并行的 count 字段要同步）。调用方是 parser 的两个回滚点：`src/parser.zig:2845` 与 `:3785`。


### `Bytecode.truncateCode` (`src/bytecode.zig:11431`)

- **签名**：`pub fn truncateCode(self: *BytecodeImpl, target_len: usize) void`。
- **作用**：把已用长度截到 watermark，不释放 capacity。
- **实现**：见 `src/bytecode.zig:11850` 函数体。
- **所有权 / 错误 / 调用**：不分配、不释放（保留 `code_capacity` 供回滚后重发射）、无 error set；越界由断言挡。调用方 `src/parser.zig:2846`（`rollbackEmission`）与 `:3803`（`State.truncateCode`）。


### `Bytecode.installCodeWithCapacity` (`src/bytecode.zig:11444`)

- **签名**：`pub fn installCodeWithCapacity(self: *BytecodeImpl, owned_used: []u8, owned_capacity: usize) void`。
- **作用**：接管 used+capacity 分离的 code。
- **实现**：所有权转移。
- **所有权 / 错误 / 调用**：所有权转移的主用变体：接管 `owned_used` 所在的整块 backing（`owned_capacity` 个元素），先释放旧 backing，此后 `deinit`/`setCode`/`installCodeWithCapacity` 都按 `code.ptr[0..code_capacity]` 释放——所以 `owned_used.len == 0` 时调用方必须传 `backing.ptr[0..0]` 让指针仍指向 backing 头。无 error set，两条前置由断言守。唯一生产调用方是 resolve_labels 的 `commit`（`src/compiler/resolve_labels.zig:3686`），那是「全部操作都不分配、不可观测半装」的移交点。


### `Bytecode.installPc2Line` (`src/bytecode.zig:11452`)

- **签名**：`pub fn installPc2Line(self: *BytecodeImpl, owned: []u8) void`。
- **作用**：接管 pc2line 缓冲。
- **实现**：`owns_pc2line_buf` 置成 `owned.len != 0`；只有旧缓冲原来是自有且非空时才释放它（借来的缓冲不释放）。
- **所有权 / 错误 / 调用**：接管 `owned` 的所有权并按旧的 `owns_pc2line_buf` 决定是否释放旧缓冲；`owned.len == 0` 时 `owns_pc2line_buf` 置 false，即空切片不算自有（`deinit` 也因此不会去 free 它）。无 error set。唯一调用方是 `encodePc2Line`（`src/bytecode.zig:11168`），它把编码结果一次性移交。


### `Bytecode.installAtomOperandsWithCapacity` (`src/bytecode.zig:11465`)

- **签名**：`pub fn installAtomOperandsWithCapacity(self: *BytecodeImpl, owned_used: []atom.Atom, owned_capacity: usize) void`。
- **作用**：带 capacity 的 atom ledger 转移。
- **实现**：同左。
- **所有权 / 错误 / 调用**：与 `installCodeWithCapacity` 同一套转移协议（接管整块 backing、先释放旧块、`owned_used.ptr` 必须是 backing 头），旧条目的 atom 引用不在这里释放；无 error set，前置由断言守。唯一生产调用方同样是 resolve_labels 的 `commit`（`src/compiler/resolve_labels.zig:3694`）。


### `Bytecode.addConstant` (`src/bytecode.zig:11473`)

- **签名**：`pub fn addConstant(self: *BytecodeImpl, value: JSValue) !u32`。
- **作用**：Bytecode.constants.append。
- **实现**：OOM。 返回 `self.constants.append(value)`。
- **所有权 / 错误 / 调用**：转调 `constant.Pool.append`（`src/bytecode.zig:2908`），后者每次精确重分配 `len+1` 个 `JSValue`（无几何增长），error set 只有 `error.OutOfMemory` 且失败时旧池不动。池接管值的所有权：未发布的 reserved BigInt 由 `Pool.deinit` 销毁，发布前的 GC 根是 `Bytecode.traceCompileRoots`（`:11921`）。调用方：parser 的常量字面量 `src/parser.zig:7599`，以及 finalize 的 `syncFunctionDefCpool`（`src/bytecode.zig:11364`，把 def 的 cpool 整体复制进 carrier）。


### `Bytecode.traceCompileRoots` (`src/bytecode.zig:11484`)

- **签名**：`pub fn traceCompileRoots( self: *BytecodeImpl, visitor: *runtime.RootVisitor, ) runtime.RootTraceError!void`。
- **作用**：把 cpool 等编译期活值交给 RootVisitor。
- **实现**：conservative 扫描看不到这些栈外缓冲。 内部 `try` 传播错误。
- **所有权 / 错误 / 调用**：不分配、不 retain：只把 `constants.values` 交给 visitor——`module_record` 与 `debug_table` 是纯 atom 构建器，没有 GC 边要暴露。error set 是 `runtime.RootTraceError`。唯一调用方是 `ParseState.traceCompileValueRoots`（`src/parser.zig:1096`），parser-only 夹具与 `syncFunctionDefCpool` 往这个池里塞的值就靠它撑到发布。


### `Bytecode.appendAtomOperand` (`src/bytecode.zig:11491`)

- **签名**：`pub fn appendAtomOperand(self: *BytecodeImpl, atom_id: atom.Atom) !void`。
- **作用**：往可变根 `Bytecode` 的 atom 操作数 ledger 追加一个 atom id（本轮由 `retainAtomOperand` 改名：tracing GC 下只写入 id、不增引用）。
- **实现**：经 `growSliceBy` 几何增长 `atom_operands` 缓冲后写入；内部 `try` 传播 `error.OutOfMemory`。
- **所有权 / 错误 / 调用**：backing 归 `Bytecode`（`deinit` 释放）；atom id 是借用值，不 retain。生产树内无调用方，只有测试助手 `publishPhase1Stream`（`src/tests/parser.zig`）使用；生产 phase-1 写入走 `FunctionDef.appendAtomOperandAssumeCapacity`。

### `Bytecode.appendAtomOperandAssumeCapacity` (`src/bytecode.zig:11496`)

- **签名**：`pub fn appendAtomOperandAssumeCapacity(self: *BytecodeImpl, atom_id: atom.Atom) void`。
- **作用**：已 reserve 容量后无检查地追加一个 atom 操作数（本轮由 `retainAtomOperandAssumeCapacity` 改名）。
- **实现**：直接写入 `atom_operands[len]` 并推进长度；容量不足只有 Debug 断言拦截。
- **所有权 / 错误 / 调用**：不分配、无 error set。本轮删除 parser 的 phase-1 原始字节后端后，树内已无调用方（与 `appendCode`/`appendSourceLoc`/`setCode` 同属只剩夹具用途的可变根 API，是否回收待裁）。

### `Bytecode.truncateAtomOperands` (`src/bytecode.zig:11506`)

- **签名**：`pub fn truncateAtomOperands(self: *BytecodeImpl, target_len: usize) void`。
- **作用**：截 atom_operands，保留 backing。
- **实现**：只把可见切片长度改回 `target_len`，backing 与 capacity 不动。
- **所有权 / 错误 / 调用**：不分配、不释放 backing、无 error set。和 `FunctionDef` 侧一样，空循环与「releasing the per-element atom refcounts」注释都已删除：tracing GC 下没有每槽引用可放。调用方是 parser 的两个回滚点：`src/parser.zig:2844`（`rollbackEmission`）与 `:3814`。


### `Bytecode.localOpenBindingIndex` (`src/bytecode.zig:11511`)

- **签名**：`pub inline fn localOpenBindingIndex(self: *const BytecodeImpl, idx: usize) ?u16`。
- **作用**：局部捕获则返回 var_ref_idx。
- **实现**：未捕获 null。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；越界或未捕获返回 `null`。非测试树里没有以 `Bytecode` 为接收者的调用方——`src/exec/frame.zig:576`/`:621` 调的是 `FunctionBytecode` 的同名方法，legacy adapter 也不转发这一条（只转发 `varRef*` 家族）。


### `Bytecode.argOpenBindingIndex` (`src/bytecode.zig:11517`)

- **签名**：`pub inline fn argOpenBindingIndex(self: *const BytecodeImpl, idx: usize) ?u16`。
- **作用**：参数捕获下标。
- **实现**：未捕获 null。
- **所有权 / 错误 / 调用**：同 `localOpenBindingIndex`：借用读、不分配、无 error set，越界或未捕获返回 `null`；非测试树里同样没有以 `Bytecode` 为接收者的调用方（`src/exec/frame.zig:603` 走的是 `FunctionBytecode` 版本）。


### `Bytecode.ensureModule` (`src/bytecode.zig:11523`)

- **签名**：`pub fn ensureModule(self: *BytecodeImpl) *module.Record`。
- **作用**：懒创建 module.Record。
- **实现**：返回指针。 返回 `&self.module_record.?`。
- **所有权 / 错误 / 调用**：懒建 `module.Record` 并存进 `self.module_record`，`Bytecode` 拥有它、`deinit`（`src/bytecode.zig:11654`）负责销毁；返回的是指向该 optional 内部的借用指针。`Record.init` 不分配，所以这里无 error set。调用方全在 parser 的模块登记：`src/parser.zig:4988`/`:8402`（top-level await）、`:15320`-`:15400` 的 import/export 绑定、`:16252`。


### `LegacyExecutionAdapter.init` (`src/bytecode.zig:11547`)

- **签名**：`pub fn init(self: *@This(), source: *const BytecodeImpl) *const FunctionBytecode`。
- **作用**：在栈上铺一个 160 字节包装：88B FB + 64B hot + 反指针，`byte_code_len=-1`。
- **实现**：zeroes；先标哨兵再 applyFlags；拷计数；最后 setExecutionFlags。返回 `*const FunctionBytecode`。
- **所有权 / 错误 / 调用**：不拥有任何堆；不得当 GC 对象 deinit；不得逃出源 Bytecode 寿命。


### `function_mod.codeMaterializesArgumentsObject` (`src/bytecode.zig:11610`)

- **签名**：`pub fn codeMaterializesArgumentsObject(code: []const u8) bool`。
- **作用**：代码是否 `special_object` 出 arguments / mapped_arguments。
- **实现**：按 `opcode.sizeOf` 逐条步进；`size == 0` 或 `pc + size > code.len`（未知/截断）一律保守返回 true；`special_object` 再看第一个操作数字节是不是 `arguments` / `mapped_arguments` 子类型（`size < 2` 同样保守 true）。
- **所有权 / 错误 / 调用**：纯扫描、不分配、无 error set。唯一调用方是 `publishLoweredMetadata`（`src/bytecode.zig:11068`），且只在 `arguments_object_from_function_def` 这个 comptime 参数为假的那一臂——V2 生产路径改用 `def.arguments_var_idx >= 0` 这个 QuickJS 身份字段，本扫描留给合成/legacy 调用方。扫出的结论写进 `flags.materializes_arguments_object`，再由 `createFunctionBytecodeAfterChildren` 转手喂给 `publishExecutionFlags`（`:10953`）。


### `function_mod.scanSmallInlineEligible` (`src/bytecode.zig:11635`)

- **签名**：`fn scanSmallInlineEligible( fb: *const FunctionBytecode, materializes_arguments_object: bool, contains_direct_eval: bool, class_syntax_excludes_inline: bool, ) bool`。
- **作用**：几何-only 小函数门：非普通 kind / 派生构造器 / 非 simple 形参 / class 语法排除先否；再要求 ≤40B 非空码（`small_inline_max_code`）、arg+var ≤4（`small_inline_max_slots`）、stack_size ≤4（`small_inline_max_stack`）、无闭包行/open var-ref/direct eval/arguments 物化。
- **实现**：逐指令 `traitsOf(form).inline_policy` 判 `.forbidden`；`ext0` 再问 `subForm` 驻留；解码失败即否。禁止身份匹配，避免 demote 后漏网。
- **所有权 / 错误 / 调用**：私有、纯读、不分配、无 error set（解码失败直接返回 false）。唯一调用方是 `publishExecutionFlags`（`src/bytecode.zig:12213`），它把返回值再 AND 上 `leaf_returns_balanced` 才写进 `CallFacts.execution.small_inline_eligible`。


### `function_mod.classifyAsyncExecution` (`src/bytecode.zig:11682`)

- **签名**：`pub fn classifyAsyncExecution(fb: *const FunctionBytecode) AsyncExecutionPolicy`。
- **作用**：保守整段证明：不可达的挂起也拒绝。
- **实现**：非 async 或无 code → unknown；遇 possible → may_suspend；unknown form → unknown；走完 → no_suspend。ext0 看驻留。
- **所有权 / 错误 / 调用**：纯读、不分配、无 error set；三态结果里 `unknown` 是安全兜底（adapter 借用的可变码与解码失败都落在这一档，不给可复用证明）。唯一调用方是 `publishExecutionFlags`（`src/bytecode.zig:12237`），结果以 `@intFromEnum` 存进 hot 扩展的 `async_execution_policy`。


### `function_mod.publishExecutionFlags` (`src/bytecode.zig:11703`)

- **签名**：`pub fn publishExecutionFlags( fb: *FunctionBytecode, materializes_arguments_object: bool, has_mapped_arguments: bool, leaf_returns_balanced: bool, contains_direct_eval: bool, class_syntax_excludes_inline: bool, is_module: bool, ) void`。
- **作用**：在码与栈 BFS 完成之后一次性发布全部 zjs-only 调用分类。
- **实现**：`simple_inline_base` = 普通 kind ∧ 非 class 语法排除 ∧ simple 形参 ∧ 闭包行里没有 `global_decl`；再按 strict/argc/closure 数派生 empty/exact/capture 叶几何；`entry_rejects_plain_call` = 码为空或 `code[0] == check_ctor`；`small_inline_eligible` = `scanSmallInlineEligible` ∧ leaf_returns_balanced；整个 `execution` 结构体一次性覆写后，写入 hot.call_facts 与 header mirror；`async_execution_policy` 来自 `classifyAsyncExecution`。顺带把码长饱和累加进 realm 所属 runtime 的 `small_inline_published_bytes` 计数。
- **所有权 / 错误 / 调用**：只改 `fb` 的 hot 扩展与 header 镜像，不分配、无 error set；进入时断言「非派生构造器，或 class 语法排除位已置」。唯一调用方是 finalize 的 `createFunctionBytecodeAfterChildren`（`src/bytecode.zig:10953`），在码、表与 pc2line 都定稿之后调用一次；attach/call 路径据此禁止再扫码（对齐 qjs `JSFunctionBytecode` 的免扫描约定）。


## 覆盖核对

- 清单函数数（本文件分组）: 115（`src/bytecode.zig` 全文件 507）
- 本文标题覆盖: 115
- 未覆盖: 无
