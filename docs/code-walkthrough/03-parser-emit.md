# 03 — parser 发射与 lvalue

phase-1 opcode 经 `Emitter` → `builderEmit*` → `compiler.Builder`。`getLValue`/`putLValue` 把最后一条 getter 收成赋值目标。using / finally / 隐式 return 的清理也在这里。


### `takeEmissionSnapshot` (`src/parser.zig:2804`)

- **签名**：`fn takeEmissionSnapshot(self: *State) EmissionSnapshot`。
- **作用**：给当前发射流拍一份回滚点。
- **实现**：把四条可失败流的当前位置连同两项 provenance 装成一个 `EmissionSnapshot` 返回：`currentCodeLen()`、`currentAtomOperandLen()`、source_loc 槽数（按 `emit_to_function_def` 在 `curFunc()` 与 `self.function` 之间二选一）、`currentParserLabelCount()`，外加 `curFunc().last_opcode_pos` 与 `self.last_opcode_source_offset` 两项 provenance。纯读不改状态，配 `rollbackEmission` 使用：OOM 时把半发布的 code / atom / source 截回这个点，运行时仍可用——QuickJS 那边 DynBuf 失败会毒化整个编译。
- **所有权 / 错误 / 调用**：不分配、不改状态：把 `curFunc()`（或 root 侧 `self.function`）里已有的四个长度和两项 provenance 抄进一个按值返回的 `EmissionSnapshot`，返回值不是借用、无需释放。无 error set。两个调用方都紧跟一条 `errdefer rollbackEmission`：`parseReturnStatement`、`parseThrowStatement`。

### `rollbackEmission` (`src/parser.zig:2823`)

- **签名**：`fn rollbackEmission(self: *State, snapshot: EmissionSnapshot) void`。
- **作用**：把一次 parser 阶段发射期间写过的所有可失败流（字节码、atom 操作数、source_loc、label 计数、last_opcode 记号）退回快照点，使 OOM 失败不留半成品。
- **实现**：按 `emit_to_function_def` 选 `curFunc()` 或 `self.function` 作为目标，依次 `truncateAtomOperands` / `truncateSourceLocs` / 截断字节码（FunctionDef 侧是 `truncateByteCode`，root 侧是 `truncateCode`）；再 `setParserLabelCount(snapshot.label_count)`、写回 `curFunc().last_opcode_pos` 与 `self.last_opcode_source_offset`。（增量维护的 flow-tail 摘要 `FlowTailSummary` 已随 phase-1 原始字节后端一起删除，这里不再有摘要要作废。）与 QuickJS 的差别也写在 doc 注释里：qjs 在 DynBuf 失败后毒化整个编译且不再恢复，zjs 返回 OOM 并保持 runtime 可用，因此绝不能让任何消费者看到这份半发布的 code/atom/source/provenance 状态。
- **所有权 / 错误 / 调用**：只退长度，不释放也不重分配任何缓冲：`truncateAtomOperands` / `truncateSourceLocs` / `truncateByteCode`（root 侧 `truncateCode`）都只改 slice 的 len、保留容量。被丢掉的 atom 操作数只是 id——两个 `truncateAtomOperands`（`FunctionDefImpl` / `BytecodeImpl`）都只改 slice 长度，rc 时代那条 release 循环在 TGC S3-c 之后先变成空循环、本轮已删；编译期 atom 的存活统一由 `CompileAtomScope` 这个 GC RootProvider 负责，所以这里没有任何引用计数义务。不碰 `builder`（Builder 有自己的 `snapshot`/`rollback`），也不碰已发布的 `FunctionBytecode`。无 error set，两处调用全在 errdefer 上：`parseReturnStatement`、`parseThrowStatement`。

### `currentParserLabelCount` (`src/parser.zig:2839`)

- **签名**：`fn currentParserLabelCount(self: *State) u32`。
- **作用**：读出当前发射目标已分配的 parser 阶段 label 个数（快照/回滚与新 label 编号都靠它）。
- **实现**：`!self.emit_to_function_def` 时直接返回 root 侧的 `self.root_parser_label_count`；否则断言 `curFunc().label_count >= 0`（FunctionDef 用有符号计数）后 `@intCast` 成 `u32` 返回。
- **所有权 / 错误 / 调用**：无：纯读访问器，不分配、无 error set，负计数只有 Debug 下的 `assert`（失败是 panic 不是错误返回）。调用方是两处快照构造——`takeEmissionSnapshot`（`src/parser.zig:2826`）与 `takeParserSnapshot`（`:13222`）。

### `setParserLabelCount` (`src/parser.zig:2845`)

- **签名**：`fn setParserLabelCount(self: *State, count: u32) void`。
- **作用**：写侧镜像：设置当前发射目标已分配的 parser 阶段 label 个数（快照回滚时用）。
- **实现**：`currentParserLabelCount` 的写侧镜像：`emit_to_function_def` 时 `curFunc().label_count = @intCast(count)`（回到有符号域），否则写 `self.root_parser_label_count = count`。
- **所有权 / 错误 / 调用**：不分配、无 error set，就地写回计数（FunctionDef 侧转回有符号域）。唯一调用方 `rollbackEmission`（`src/parser.zig:2848`）。

### `markDirectEvalCall` (`src/parser.zig:2853`)

- **签名**：`fn markDirectEvalCall(self: *State) Error!void`。
- **作用**：在当前 `FunctionDef` 上打「含直接 eval」的标记。
- **实现**：取 `curFunc()` 后置 `fd.has_eval_call = true`，标记该函数含直接 eval（后续变量解析据此保守处理作用域）。返回 `Error!void` 只为与其它发射辅助同形，当前实现没有失败路径。
- **所有权 / 错误 / 调用**：不分配：只在借来的 `curFunc()` 上置一个 `bool`。`Error!void` 是与其它发射辅助同形的名义签名，函数体里没有任何 `try`/`return error`，不可能失败。唯一调用方 `emitPreparedCall`（`src/parser.zig:5574`，`prepared.kind == .direct_eval` 分支）。

### `emitFClosure` (`src/parser.zig:2873`)

- **签名**：`fn emitFClosure(self: *State, idx: u32) Error!void`。
- **作用**：发「用子函数常量池下标造闭包」的指令。
- **2026-09-20 退役后**：只剩宽形式 `Emitter.opU32(self, op.fclosure, idx)`；phase-1 临时 opcode 与含 `fclosure8` 的短 opcode 区撞号，短形式一律由 `resolve_labels` 在临时码擦除后缩出。`emitFClosure8` 与它的「已是 phase-2 形态」臂已删。下面两行是退役前的描述。
- **实现**：按常量池下标宽度选形式：`idx < 256` 时 `@intCast` 后转给 `emitFClosure8`（再由后者决定短/宽），否则直接 `Emitter.opU32(self, op.fclosure, idx)` 保留宽操作数（qjs `js_parse_function_decl2`，quickjs.c:36500）。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。调用方 6 处：`parseFunctionParamsAndBody`（`:12067`/`:12079`/`:12125`）、`parseArrowFunction`（`:12534`）、`emitClassFieldsInitValue`（`:14675`）、`emitClassStaticInitCall`（`:14706`），传入的都是子函数在父常量池里的下标。

### `emitCloseLoc` (`src/parser.zig:2883`)

- **签名**：`fn emitCloseLoc(self: *State, idx: u16) Error!void`。
- **作用**：发一条关闭被捕获局部槽的 `close_loc`，属于作用域退出清理。
- **实现**：单行转调 `Emitter.opU16NoSource(self, op.close_loc, idx)`。关闭被捕获的局部槽属于 `close_scopes` 发出的 phase-1 清理动作，不该带 source marker（quickjs.c:24160-24169），所以走 NoSource 形式。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.opU16NoSource` 写进 `activeBuilder()`，失败只可能是 Builder 的 OOM / 溢出 / 不变量（`mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`）。调用方是 using/for-of 的清理点：`emitUsingDisposesForCatchMarkerDepth`（`src/parser.zig:7888`）、`finalizeCurrentUsingBlockFrame`（`:8493`）、`parseUsingDeclaration`（`:9971`）等 5 处。

### `emitEnterScope` (`src/parser.zig:2896`)

- **签名**：`fn emitEnterScope(self: *State) Error!void`。
- **作用**：在块级作用域入口写一条 phase-1 的 `enter_scope` 临时码。
- **2026-09-20 退役后**：`!self.emit_phase1_temp` 那道早退已删，只剩 `scope_level`/`scope` 为负时的早退；标记总是发。
- **实现**：两道早退：`!self.emit_phase1_temp`（非 phase-1 形态根本不需要 scope 标记）与 `self.scope_level < 0` 都直接返回、什么都不发。否则 `Emitter.opU16NoSource(op.enter_scope, scope_level)`——对齐 qjs `push_scope`（`quickjs.c:23486`），且这个标记不带 source 事件（`quickjs.c:24128-24135`）。`resolve_variables` 再把它降成一次 per-scope 绑定刷新（TDZ 重新武装 + 捕获槽脱钩，见 `enterScopeRefreshSize`），循环体内声明的 lexical 因此每轮都是新绑定。
- **所有权 / 错误 / 调用**：不分配；`emit_phase1_temp` 关或 `scope_level < 0` 时直接返回（无副作用），否则经 `Emitter.opU16NoSource` 写 Builder，失败同样是 `mapBuilderError` 折出来的 OOM / 溢出 / `ParserInvariant`。调用方：`ParseState.pushScope`（`src/parser.zig:1440`）、`ParseState.beginFunctionBody`（`:1447`）、`enterParameterExpressionScope`（`:13442`）。

### `emitLeaveScope` (`src/parser.zig:2904`)

- **签名**：`fn emitLeaveScope(self: *State, scope: i32) Error!void`。
- **作用**：在块级作用域出口写一条 phase-1 的 `leave_scope` 临时码。
- **2026-09-20 退役后**：`!self.emit_phase1_temp` 那道早退已删，只剩 `scope_level`/`scope` 为负时的早退；标记总是发。
- **实现**：两道早退：`!self.emit_phase1_temp` 直接返回（非 phase-1 形态不需要 scope 标记），`scope < 0` 也返回（无效作用域）。否则 `Emitter.opU16NoSource(self, op.leave_scope, @intCast(scope))`，无 source 事件，对应 qjs `pop_scope` / `close_scopes`（quickjs.c:24150-24169）。
- **所有权 / 错误 / 调用**：不分配；与 `emitEnterScope` 对称，`emit_phase1_temp` 关或 `scope < 0` 时 no-op。失败来自 Builder（`mapBuilderError` → OOM / `BytecodeOverflow` / `ParserInvariant`）。调用方 7 处：`ParseState.popScope`（`src/parser.zig:1486`）、`closeScopes`（`:2989`）、`leaveParameterExpressionScope`（`:13514`），其余在 `parseClass`（`:14938`/`:14939`/`:15001`/`:15002`）。

### `closeScopes` (`src/parser.zig:2914`)

- **签名**：`fn closeScopes(self: *State, start_scope: i32, scope_stop: i32) Error!void`。
- **作用**：从 `start_scope` 沿 `scopes[].parent` 链逐层发 `leave_scope`，直到（不含）`scope_stop`；不改解析器自身的 scope 状态。
- **实现**：从 `start_scope` 起 `while (scope > scope_stop)`：先用 `curFunc().scopes.len` 做越界检查（越界即 `error.ParserInvariant`，作用域号只可能来自本函数的表），发一条 `emitLeaveScope(scope)`，再沿 `scopes[scope].parent` 往外跳一层。`scope_stop` 本身不发、也不动解析器的 `scope_level`：这是 `break` / `continue` / `return` 穿出多层块时补的词法退出链，不是真的离开作用域（qjs `close_scopes`）。
- **所有权 / 错误 / 调用**：不分配；只发 `leave_scope`，不改 `self.scope_level`，也不改 `curFunc().scopes` 表（只读 `parent` 链）。自身唯一的显式错误是越界时的 `error.ParserInvariant`，其余失败来自 `emitLeaveScope` 底下的 Builder（`mapBuilderError` 折成 OOM / `BytecodeOverflow` / `ParserInvariant`）。调用方 6 处：`parseForStatement`（`:9414`/`:9497`）、`emitControlBlocksUntil`（`:10444`）、`emitControlThroughFinally`（`:10488`）、`parseForInOf`（`:10955`/`:11031`）——全是 break/continue/return 穿出多层块的补链点。

### `emitScopeVar` (`src/parser.zig:2929`)

- **签名**：`noinline fn emitScopeVar( self: *State, atom_id: Atom, scope_op: u8, global_op: u8, attach_source: bool, ) Error!void`。
- **作用**：把「作用域临时 opcode / 全局 var opcode」合成一条走法：phase-1 发 `scope_*`（atom + 当前 `scope_level`），否则发对应 `get_var`/`put_var` 族；`resolve_variables` 再把 scope 临时码降下来。
- **2026-09-20 退役后**：签名去掉 `global_op`，不再先调 `ensureClosureVar`（已删），只剩 phase-1 臂：按 `attach_source` 走 `Emitter.opAtomU16` / `opAtomU16NoSource`。`emitGlobalVarOp` / `emitGlobalVarOpNoSource` 已删。
- **实现**：先 `ensureClosureVar(atom_id)`。`emit_phase1_temp` 时按 `attach_source` 走 `Emitter.opAtomU16` 或 `opAtomU16NoSource`（操作数是 `scope_op` + atom + `u16` scope_level；qjs `resolve_scope_var` 消费同一族，quickjs.c:33036-33052）。否则按 `attach_source` 走 `emitGlobalVarOp` / `emitGlobalVarOpNoSource`（操作数是 `global_op`）。opcode 对与 source 旗标是运行时参数，避免 LLVM 再拆出五份 typed 副本（leftover candidate35）。
- **所有权 / 错误 / 调用**：不分配；先 `ensureClosureVar(atom_id)`（phase-1 下直接返回，非 phase-1 才去父链里物化闭包变量，可返回 `Error`），随后两条臂都只写字节码：phase-1 经 `Emitter.opAtomU16[NoSource]` 写 `activeBuilder()`，非 phase-1 经 `emitGlobalVarOp[NoSource]`。atom 不在这里 retain（编译期 atom 由 `CompileAtomScope` 这个 GC RootProvider 托底）。失败源是 Builder 的 OOM / 溢出 / 不变量，经 `mapBuilderError` 折成 `Error.*`。调用方就是紧随其后的七个 inline 包装（`:3024`–`:3052`）。

### `emitScopeGetVar` (`src/parser.zig:2953`)

- **签名**：`inline fn emitScopeGetVar(self: *State, atom_id: Atom) Error!void`。
- **作用**：发「按名字读变量」：phase-1 是待解析的 `scope_get_var`，非 phase-1 是全局 `get_var`。
- **实现**：一行转调 `emitScopeVar(atom_id, op.scope_get_var, op.get_var, true)`：phase-1 发带 atom + `scope_level` 的临时读取码，非 phase-1 发全局 `get_var`，两者都附 source marker。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。最热的一个：树内 39 处调用，从 `emitThisValue`（`:3062`/`:3072`）、`emitSuperThis`（`:5106`）、`parsePrimary`（`:6377`）到 `parseClass`（`:14957`/`:14958`），凡是「按名字读一个标识符」都走它。

### `emitScopeGetVarCheckThis` (`src/parser.zig:2957`)

- **签名**：`inline fn emitScopeGetVarCheckThis(self: *State, atom_id: Atom) Error!void`。
- **作用**：发带 this-TDZ 检查的按名读取（派生构造器里 `this` 未初始化要抛 ReferenceError）。
- **实现**：转调 `emitScopeVar(atom_id, op.scope_get_var_checkthis, op.get_var, true)`。scope 侧换成带 this-TDZ 检查的读取形式（派生构造器里 `this` 未初始化要抛 ReferenceError），全局侧仍回落到普通 `get_var`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。调用方 3 处，全在派生构造器/函数体的 `this` 读回上：`emitFunctionReturn`（`:10307`/`:10310`）与 `parseFunctionParamsAndBody`（`:11993`）。

### `emitScopePutVar` (`src/parser.zig:2961`)

- **签名**：`inline fn emitScopePutVar(self: *State, atom_id: Atom) Error!void`。
- **作用**：发「按名字写回变量」的普通赋值指令。
- **实现**：转调 `emitScopeVar(atom_id, op.scope_put_var, op.put_var, true)`：普通赋值写回，带 source marker。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。调用方 5 处：`parseEnumDeclaration`（`:8725`）、`parseNamespaceDeclarationWithIdent`（`:8845`）、`parseTryStatement`（`:9829`，catch 形参绑定）、`parseForInOf`（`:10867`/`:10939`）。

### `emitScopePutVarNoSource` (`src/parser.zig:2965`)

- **签名**：`inline fn emitScopePutVarNoSource(self: *State, atom_id: Atom) Error!void`。
- **作用**：按名写回的无 source marker 版本，供编译器自己插入的合成存储使用。
- **实现**：与 `emitScopePutVar` 同一对 opcode，但 `attach_source = false`，供不该在源码里留位置的合成写回（编译器自己插的存储）使用。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。树内唯一调用方 `parseVar`（`:10649`）——`var` 声明的合成写回不该在源码里留位置。

### `emitScopeGetVarUndef` (`src/parser.zig:2969`)

- **签名**：`inline fn emitScopeGetVarUndef(self: *State, atom_id: Atom) Error!void`。
- **作用**：发「名字解析不到时求值成 `undefined` 而不抛」的读取指令（`typeof` 一类场合）。
- **实现**：转调 `emitScopeVar(atom_id, op.scope_get_var_undef, op.get_var_undef, true)`：未解析的名字求值为 `undefined` 而不是抛 ReferenceError 的读取形式（`typeof` 等场合）。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。调用方 2 处：`parseEnumDeclaration`（`:8717`）与 `parseNamespaceDeclarationWithIdent`（`:8837`），都是「名字可能还不存在」的探测式读取。

### `emitScopePutVarInit` (`src/parser.zig:2977`)

- **签名**：`inline fn emitScopePutVarInit(self: *State, atom_id: Atom) Error!void`。
- **作用**：为 `let` / `const` 的初始化写回发一条 `scope_put_var_init`。
- **实现**：转调 `emitScopeVar(atom_id, op.scope_put_var_init, op.put_var_init, true)`，带 source marker。与普通 `scope_put_var` 的区别在 TDZ：这是把槽从「未初始化」点亮的那一次写。流水线后续按解析结果降码——解析成局部就是 `put_loc`，顶层词法全局则保留 `put_var_init`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。调用方 15 处，覆盖所有词法绑定的点亮点：`parseVar`（`:10664`）、`parseUsingDeclaration`（`:9964`）、`parseForInOf`（`:10865`/`:11013`）、`parseClassElement`（`:13773`/`:13777`/`:13837`）、`addPrivateClassFieldBinding`（`:14014`）、`parseExport`（`:15469`/`:15499`）等。

### `emitScopePutVarInitNoSource` (`src/parser.zig:2981`)

- **签名**：`inline fn emitScopePutVarInitNoSource(self: *State, atom_id: Atom) Error!void`。
- **作用**：`let` / `const` 初始化写回的无 source marker 版本。
- **实现**：转调 `emitScopeVar(atom_id, op.scope_put_var_init, op.put_var_init, false)`：`let` / `const` 绑定初始化写入的无 source marker 版本，与 `emitScopePutVarInit` 只差 `attach_source`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。树内唯一调用方 `parseVar`（`:10647`）。

### `emitThisValue` (`src/parser.zig:2985`)

- **签名**：`fn emitThisValue(self: *State) Error!void`。
- **作用**：按当前函数有没有自己的 ThisBinding，发出取 `this` 的正确形式。
- **实现**：三路分支。①`emit_to_function_def` 且 `curFunc().has_this_binding`：发 `emitScopeGetVar(atom_this)`——显式 `this` 读走普通词法检查，派生构造器里未初始化的 `this` 因此在自己的 realm 抛 TDZ ReferenceError；带 caller-realm 的 checkthis 形式只留给 `emitReturnValue` 里合成的派生返回回退。②`emit_to_function_def` 且当前函数是 `.arrow` / `.class_static_init` / `is_direct_eval`：同样 `emitScopeGetVar(atom_this)`，因为它们没有自己的 ThisBinding，要沿闭包链解析（qjs 的 TOK_THIS 恒发 `OP_scope_get_var this`，quickjs.c:26934-26939；直接 eval 见 quickjs.c:37239，按调用者种子解析以免 root eval 捕获的 `this` 遮蔽方法自己的 this）。③其余情况（root 发射、有自己 this 的普通函数走不到这里）直接 `Emitter.op(self, op.push_this)`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` → `activeBuilder()`（`curFunc().builder.?`）写入，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。前两条臂经 `emitScopeGetVar` 出去，第三条臂直接 `Emitter.op(push_this)`；本身不分配、不改函数状态。调用方 2 处：`parseLhsExpr`（`:5669`）与 `parsePrimary`（`:6274`，`TOK_THIS`）。

### `emitBigIntLiteral` (`src/parser.zig:3413`)

- **签名**：`fn emitBigIntLiteral(self: *State, text: []const u8, negate: bool) Error!void`。
- **作用**：把 BigInt 字面量降成字节码：小值走立即数，大值造常量池里的 BigInt 对象。
- **实现**：快路径：`parseBigIntI32(text, negate)` 能把字面量装进 `i32` 时发 `Emitter.opI32(op.push_bigint_i32, small)` 就返回。慢路径分三步：①若文本含数字分隔符 `_`，先复制一份剔除 `_` 的 `normalized` 缓冲（用 `self.function.memory.allocator`，`defer` 里按指针是否变化决定释放）；②`libs_bignum.parseAutoAlloc(persistent_allocator, parse_text)` 解析，失败一律映射成 `Error.InvalidNumberLiteral`，`negate` 且非零时翻转 `parsed.negative`（避免造出 `-0n`）；③在 function 的账上 `create` 一个 `core_bigint.BigInt`，`initExternalFromOwned(parsed)` 接管位串，然后 `Emitter.pushConstOwned(big.valueRef())` 交给常量池，成功后清 `big_owned` 以关掉 `errdefer` 的 `destroyWithAccount`。注释点明这是「保留态（未注册）堆 BigInt」：在拥有它的 FunctionBytecode 发布（`BigInt.registerReservedValue`）之前它不入 GC 链表，所以解析剩余阶段的任何一次回收既不会清扫它也不需要 trace 它；解析器可能在没有 runtime 的情况下运行，所以分配和失败路径的释放都走函数自己的内存账。
- **所有权 / 错误 / 调用**：两处分配都在**函数自己的内存账**上（解析器可能没有 runtime）：剔除 `_` 的 `normalized` 缓冲用 `self.function.memory.allocator`，`defer` 按指针是否变化决定释放；`libs_bignum.parseAutoAlloc` 用 persistent_allocator，解析失败一律映射成 `Error.InvalidNumberLiteral`。堆 `BigInt` 由 `create` + `initExternalFromOwned(parsed)` 接管位串，`errdefer destroyWithAccount` 守着，直到 `Emitter.pushConstOwned` 把它交给常量池后清 `big_owned` 转移所有权；此时它仍是「保留态（未注册）」对象，不入 GC 链表，直到宿主 `FunctionBytecode` 发布时 `BigInt.registerReservedValue`。树内唯一调用方 `parsePrimary`（`:6241`）。

### `invalidateLastOpcode` (`src/parser.zig:3448`)

- **签名**：`fn invalidateLastOpcode(self: *State) void`。
- **作用**：作废「最后一条已发指令」的记录，让之后的窥孔改写不敢跨过这个点。
- **实现**：一行转调 `self.activeBuilder().invalidateLastOpcode()`，清掉 Builder 的 last-opcode provenance。控制流汇合（绑定 label）和字节码截断后都必须调它，否则窥孔会把汇合点两侧的指令融在一起。
- **所有权 / 错误 / 调用**：不分配、无 error set：把 `activeBuilder()`（`curFunc().builder.?`）的 `last_opcode_pos` 置成无效，之后的窥孔改写就不会跨过这个点。`curFunc()` 为空 builder 时 `.?` 会 panic，所以只能在 `ensureBuilderForFd` 之后调用。同名方法有两层：本条是 `State` 的转发，直接调 `Builder.invalidateLastOpcode` 的还有 `builderBindLabel`（`:3694`）/`builderBindParserLabel`（`:3703`）等 7 处（`:5638`、`:13636`、`:13668`、`:14315`、`:15062`）。`State` 这一层的调用方是 `parseExpr2`、`parseTaggedTemplateInvocation` 等 3 处（原来的第四处 `State.truncateCode` 已随 phase-1 原始字节后端一起删除）。

### `activeBuilder` (`src/parser.zig:3460`)

- **签名**：`pub fn activeBuilder(self: *State) *compiler.Builder`。
- **作用**：取当前正在解析的 FunctionDef 所属的 `Builder`。
- **实现**：`return self.curFunc().builder.?;` —— 刻意用不带检查的解包。doc 注释说明只在 v2 解析期间有意义：v2 解析里每个被发射的 FunctionDef 都应由 `ensureBuilderForFd` 装过 Builder，没装上就是迁移漏洞，宁可在这里响亮地 panic。
- **所有权 / 错误 / 调用**：纯访问器：不分配、不写任何流、无 error set。返回的是**借用**指针（`curFunc().builder` 这个 optional 的负载），生存期绑在该 `FunctionDef` 上，调用方不得跨 `pushFunction`/`popFunction` 保存。`builder` 为 `null` 时 `.?` 直接 panic（不是可恢复错误），所以必须在 `ensureBuilderForFd`（`:3709`）之后调用。树内约 70 处调用，几乎所有 `builder*` / `emitter*` 包装的第一行都是它。

### `builderAddSourceMarker` (`src/parser.zig:3467`)

- **签名**：`pub fn builderAddSourceMarker(self: *State, line_num: u32, col_num: u32) compiler.builder.Error!void`。
- **作用**：v2 侧的 source marker 登记：为下一条发出的指令钉住 (line, col) 权威位置，是 `emitSourcePosAndLoc` 的 v2 半边。
- **实现**：取 `activeBuilder()`；若 `source_len != 0`，比对最后一个 source 槽：`line` 与 `col` 都与本次相同就直接返回——对应 QuickJS 比较最后一个显式 source 指针、不为同一个语法点重复发 `OP_line_num`。否则 `v2b.addSourceMarker(@intCast(line_num), @intCast(col_num))`；Builder 自身会忽略非正坐标。
- **所有权 / 错误 / 调用**：不自己分配：去重通过后由 `Builder.addSourceMarker` 在 `fd.memory` 上扩 `source_slots`。返回的是 **`compiler.builder.Error`**（不是 `parser_core.Error`），由调用方的 `mapBuilderError`（`src/parser.zig:7448`）折成 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`。调用方：`Emitter.opAt`（`:7489`）、`Emitter.addSourceMarker`（`:7507`），另有单测 `src/tests/parser.zig:13070`。

### `builderRecordPlainControl` (`src/parser.zig:3479`)

- **签名**：`fn builderRecordPlainControl(self: *State, op_id: u8) compiler.builder.Error!void`。
- **作用**：无立即数指令发出后，把其中的「终结基本块」事实登记进 Builder 的控制索引。
- **实现**：一个 `switch (op_id)`：`op.return` / `op.return_undef` / `op.throw` / `op.ret` 四者归并到同一分支，调 `activeBuilder().recordControl(.terminal)`；`else` 什么都不做。
- **所有权 / 错误 / 调用**：不分配；命中终结指令时调 `Builder.recordControl(.terminal)`，控制索引的增长在 `fd.memory` 上（`enableControlIndex` 已在 `ensureBuilderForFd` 打开）。error set 是 `compiler.builder.Error`，由上层 `mapBuilderError` 翻译。调用方 `builderEmitOp`（`src/parser.zig:3639`）与 `Emitter.opU8NoSource`（`:7553`）。

### `builderRecordU16Control` (`src/parser.zig:3490`)

- **签名**：`fn builderRecordU16Control(self: *State, op_id: u8) compiler.builder.Error!void`。
- **作用**：带 u16 立即数的指令发出后的控制流登记。
- **实现**：`switch (op_id)`：`op.tail_call` / `op.tail_call_method` 记 `.terminal`（尾调用不返回本帧），`op.apply_eval` 记 `.direct_eval`，其余 `else` 不记。
- **所有权 / 错误 / 调用**：同族：不分配，只把 `tail_call*` 记成 `.terminal`、`apply_eval` 记成 `.direct_eval`，error set 为 `compiler.builder.Error`。调用方 `builderEmitOpU16`（`src/parser.zig:3649`）、`Emitter.opU16At`（`:7501`）、`Emitter.callOp`（`:7569`）。

### `builderRecordU32Control` (`src/parser.zig:3498`)

- **签名**：`fn builderRecordU32Control(self: *State, op_id: u8) compiler.builder.Error!void`。
- **作用**：带 u32 立即数的指令发出后的控制流登记——这一族只有直接 eval 一种事实。
- **实现**：单个 `if`：`op_id == opcode.op.eval` 时 `activeBuilder().recordControl(.direct_eval)`，否则什么都不做。
- **所有权 / 错误 / 调用**：同族：不分配，只有 `op.eval` 一条臂记 `.direct_eval`，error set 为 `compiler.builder.Error`。调用方 `builderEmitOpU32`（`src/parser.zig:3654`）、`Emitter.opU32NoSource`（`:7619`）。

### `builderRecordAtomU8Control` (`src/parser.zig:3503`)

- **签名**：`fn builderRecordAtomU8Control(self: *State, op_id: u8) compiler.builder.Error!void`。
- **作用**：带 atom + u8 立即数的指令发出后的控制流登记。
- **实现**：单个 `if`：`op_id == opcode.op.throw_error` 时记 `.terminal`（这条抛错指令终结基本块），否则无动作。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。唯一调用方 `builderEmitAtomOpU8Owned`（`:3669`）；树内唯一会命中的 opcode 是 `throw_error`。

### `builderEmitOp` (`src/parser.zig:3510`)

- **签名**：`pub fn builderEmitOp(self: *State, op_id: u8) compiler.builder.Error!void`。
- **作用**：发一条无立即数指令，并登记它可能带来的终结型控制流。
- **实现**：`activeBuilder().emitOp(op_id)` 后接 `builderRecordPlainControl(op_id)`。按 QuickJS 的风格，`emit_op()` 本身不带 source：source marker 由拥有该处的语法产生式显式添加。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。生产侧唯一调用方 `Emitter.op`（`:7477`）——它先发 source marker 再转给本函数；另有单测 `src/tests/parser.zig:13066` 与 `src/tests/helpers.zig:767` 直调。

### `builderEmitOpU8` (`src/parser.zig:3516`)

- **签名**：`pub fn builderEmitOpU8(self: *State, op_id: u8, val: u8) compiler.builder.Error!void`。
- **作用**：发一条带 u8 立即数的指令。
- **实现**：单行转调 `activeBuilder().emitOpU8(op_id, val)`。这一族对应 QuickJS 的 `emit_op` + `emit_u8`，同样不带 source marker；u8 立即数里没有需要登记的控制流效应，所以不跟 record 调用。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。唯一调用方 `Emitter.opU8`（`:7546`）。

### `builderEmitOpU16` (`src/parser.zig:3520`)

- **签名**：`pub fn builderEmitOpU16(self: *State, op_id: u8, val: u16) compiler.builder.Error!void`。
- **作用**：发一条带 u16 立即数的指令并登记其控制流效应。
- **实现**：`activeBuilder().emitOpU16(op_id, val)` 后调 `builderRecordU16Control(op_id)`，于是 `tail_call` 系被记成 terminal、`apply_eval` 被记成 direct_eval。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。唯一调用方 `Emitter.opU16`（`:7561`）。

### `builderEmitOpU32` (`src/parser.zig:3525`)

- **签名**：`pub fn builderEmitOpU32(self: *State, op_id: u8, val: u32) compiler.builder.Error!void`。
- **作用**：发一条带 u32 立即数的指令并登记其控制流效应。
- **实现**：`activeBuilder().emitOpU32(op_id, val)` 后调 `builderRecordU32Control(op_id)`，即 `op.eval` 会被记成 direct_eval。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。唯一调用方 `Emitter.opU32`（`:7574`）。

### `builderEmitOpI32` (`src/parser.zig:3530`)

- **签名**：`pub fn builderEmitOpI32(self: *State, op_id: u8, val: i32) compiler.builder.Error!void`。
- **作用**：发一条带有符号 i32 立即数的指令（`push_i32`、`push_bigint_i32` 等）。
- **实现**：单行转调 `activeBuilder().emitOpI32(op_id, val)`；这一族没有控制流效应，所以不跟 `builderRecord*Control`。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。唯一调用方 `Emitter.opI32`（`:7580`）。

### `builderEmitAtomOpOwned` (`src/parser.zig:3536`)

- **签名**：`pub fn builderEmitAtomOpOwned(self: *State, op_id: u8, atom_id: Atom) compiler.builder.Error!void`。
- **作用**：发一条以 atom 为立即数的指令，并把该 atom 的一份所有权移交给 Builder。
- **实现**：单行转调 `activeBuilder().emitAtomOpOwned(op_id, atom_id)`。名字里的 Owned 是所有权契约：无论成功还是失败，Builder sink 都接管 `atom_id`，调用方不再负责释放；source marker 仍由语法点自己发。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。atom 走 **owned** 契约：无论成功失败，`atom_id` 的这一份所有权都由 Builder sink 接管，调用方不得再释放。生产侧唯一调用方 `Emitter.opAtom`（`:7519`），另有单测 `src/tests/parser.zig:13068`。

### `builderEmitAtomOpU8Owned` (`src/parser.zig:3540`)

- **签名**：`pub fn builderEmitAtomOpU8Owned(self: *State, op_id: u8, atom_id: Atom, val: u8) compiler.builder.Error!void`。
- **作用**：发一条 atom + u8 立即数指令（典型是 `throw_error`），atom 所有权移交 Builder，并登记控制流。
- **实现**：`activeBuilder().emitAtomOpU8Owned(op_id, atom_id, val)` 后调 `builderRecordAtomU8Control(op_id)`，`throw_error` 因此被记成 terminal。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。atom 走 **owned** 契约：无论成功失败，`atom_id` 的这一份所有权都由 Builder sink 接管，调用方不得再释放。唯一调用方 `Emitter.opAtomU8`（`:7541`）。

### `builderEmitAtomOpU16Owned` (`src/parser.zig:3545`)

- **签名**：`pub fn builderEmitAtomOpU16Owned(self: *State, op_id: u8, atom_id: Atom, val: u16) compiler.builder.Error!void`。
- **作用**：发一条 atom + u16 立即数指令——`scope_*` 临时码「atom + scope_level」就是这个形状，atom 所有权移交 Builder。
- **实现**：单行转调 `activeBuilder().emitAtomOpU16Owned(op_id, atom_id, val)`，没有控制流登记。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。atom 走 **owned** 契约：无论成功失败，`atom_id` 的这一份所有权都由 Builder sink 接管，调用方不得再释放。唯一调用方 `Emitter.opAtomU16`（`:7432`）——即 `scope_*` 临时码那条路。

### `builderEmitJump` (`src/parser.zig:3551`)

- **签名**：`pub fn builderEmitJump(self: *State, op_id: u8, label: compiler.LabelId) compiler.builder.Error!void`。
- **作用**：发一条以 `compiler.LabelId` 为目标的跳转，目标偏移留到 `resolve_labels_v2` 再回填。
- **实现**：单行转调 `activeBuilder().emitJump(op_id, label)`。对应 QuickJS 的 `emit_goto()`：不带 source marker；LabelId 操作数在标签解析前一直处于 pending 状态。
- **所有权 / 错误 / 调用**：不分配（字节码/atom/控制索引的增长都在 Builder 自己的 `fd.memory` 账上）；error set 是 **`compiler.builder.Error`**（`OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode`），不是 `parser_core.Error`，也不归 `rollbackEmission` 管——Builder 自带 `snapshot`/`rollback`，翻译成 `Error.*` 是调用方 `mapBuilderError`（`:7448`）的事。`label` 只是 Builder 内的索引，没有释放义务；跳转目标在 `resolve_labels_v2` 之前一直 pending。生产侧唯一调用方 `Emitter.jump`（`:7464`），另有单测 `src/tests/parser.zig:13065`。

### `builderNewLabel` (`src/parser.zig:3555`)

- **签名**：`pub fn builderNewLabel(self: *State) compiler.builder.Error!compiler.LabelId`。
- **作用**：向当前 Builder 要一个新的 v2 label 标识。
- **实现**：单行 `return self.activeBuilder().newLabel();`。未绑定的 label 只是个 id，绑定位置与跳转回填都由 Builder 负责。
- **所有权 / 错误 / 调用**：不分配 label 对象本身，只在 Builder 的 label 表上追加一行（`fd.memory`）；返回的 `LabelId` 是索引不是指针，无释放义务，但只在**同一个** Builder 内有效（跨 FunctionDef 使用会被 Builder 判成 foreign label → `InvalidBytecode`）。error set 是 `compiler.builder.Error`。调用方 `Emitter.newLabel`（`src/parser.zig:7459`）与单测 `src/tests/parser.zig:13064`。

### `builderBindLabel` (`src/parser.zig:3564`)

- **签名**：`pub fn builderBindLabel(self: *State, label: compiler.LabelId) compiler.builder.Error!void`。
- **作用**：把 label 绑在当前 v2 位置；因为绑定点是控制流汇合，同时作废 last-opcode 记录。
- **实现**：取 `activeBuilder()`，先 `v2b.bindLabel(label)` 再 `v2b.invalidateLastOpcode()`。后一步等价于 qjs 的 `emit_label` 让 `OP_label` 成为可见的最后一条指令（`fd->last_opcode_pos`），从而没有窥孔能跨汇合点融合。
- **所有权 / 错误 / 调用**：不分配；`Builder.bindLabel` 失败（重复 bind / 外来 label）返回 `error.InvalidBytecode`，经调用方 `mapBuilderError` 变成 `Error.ParserInvariant`——即内部编译器错误而不是源程序判决，`compile` 走 `setInternalCompilerError`（`src/parser.zig:16374`）而非 SyntaxError。bind 成功后顺带 `invalidateLastOpcode`，保证窥孔不跨控制流汇合点。调用方 `Emitter.bind`（`:7644`）与单测 `src/tests/parser.zig:13069`。

### `builderBindParserLabel` (`src/parser.zig:3573`)

- **签名**：`pub fn builderBindParserLabel(self: *State, label: compiler.LabelId) compiler.builder.Error!void`。
- **作用**：绑定与 parser 物理 `OP_label` 对应的那种标签：除作废 last-opcode 外还保留顺序窥孔屏障。
- **实现**：取 `activeBuilder()`，调 `v2b.bindLabelMatchBarrier(label)`——即使这个 label 后来失去全部引用，屏障仍然留在那里；随后 `v2b.invalidateLastOpcode()` 清掉 last-opcode provenance。
- **所有权 / 错误 / 调用**：与 `builderBindLabel` 同形，只把 `bindLabel` 换成 `bindLabelMatchBarrier`（保留顺序窥孔屏障）；不分配，`compiler.builder.Error` 同样由上层折成 `ParserInvariant` 一类。唯一调用方 `Emitter.bindParser`（`src/parser.zig:7657`）。

### `ensureBuilderForFd` (`src/parser.zig:3582`)

- **签名**：`pub fn ensureBuilderForFd(self: *State, fd: *function_def_mod.FunctionDef) compiler.builder.Error!void`。
- **作用**：给一个 FunctionDef 装上属于它自己的 `Builder`（幂等）。
- **实现**：`self` 未使用（`_ = self`）。仅当 `fd.builder == null` 时：`fd.memory.create(compiler.Builder)` 分配，`compiler.Builder.init(fd.memory, fd.atoms)` 初始化，`enableControlIndex()` 打开控制流索引，最后挂到 `fd.builder`。已经有则原样返回，因此可反复调用。每个被发射进去的 FunctionDef 都拥有一个 Builder。
- **所有权 / 错误 / 调用**：**本族唯一真正分配的函数**：`fd.memory.create(compiler.Builder)` + `Builder.init(fd.memory, fd.atoms)` + `enableControlIndex()`，所有权归 `fd.builder`，由 `FunctionDef.deinit`（`bytecode.zig` 里那段「parse-time/error-path backstop」）或 v2 lowering 的消费点释放，本函数不负责。幂等（已有则直接返回）。失败是 `compiler.builder.Error`（`create`/`enableControlIndex` 的 OOM）；生产调用方大多写成 `catch return error.OutOfMemory`：`initRootEmitter`（`src/parser.zig:952`）、`pushFunction`（`:1396`）、`createClassFieldsInitFunction`（`:14302`）、`appendDefaultClassConstructor`（`:15117`），另有 `beginProgramEmission`（`:3729`）与测试钩子（`:3722`）。

### `beginBuilderEmissionForTest` (`src/parser.zig:3594`)

- **签名**：`pub fn beginBuilderEmissionForTest(self: *State) compiler.builder.Error!void`。
- **作用**：测试钩子：为当前函数开始 v2 发射，首次使用时顺带分配 Builder。
- **实现**：单行 `try self.ensureBuilderForFd(self.curFunc())`。生产路径走 `beginProgramEmission`（那条还要补发 body scope 的 enter 事件），这个入口只供单测直接构造发射场景。
- **所有权 / 错误 / 调用**：不自己分配，转发 `ensureBuilderForFd(curFunc())`，Builder 的所有权和释放同上。**生产零调用方**：只有 `src/compiler/tests.zig:47` 与 `src/tests/parser.zig:13060` 两个测试入口（函数名里的 `ForTest` 就是这个意思）。error set 为 `compiler.builder.Error`。

### `beginProgramEmission` (`src/parser.zig:3601`)

- **签名**：`pub fn beginProgramEmission(self: *State) compiler.builder.Error!void`。
- **作用**：生产路径的程序根发射起点：装好 Builder 并把 body scope 的 `enter_scope` 事件补进流里。
- **实现**：先 `ensureBuilderForFd(self.curFunc())`；`curFunc().body_scope < 0` 视为 `error.InvalidBytecode`。取 Builder、`v2b.snapshot()` 并挂 `errdefer v2b.rollback(snapshot)`，再 `v2b.emitOpU16(opcode.op.enter_scope, @intCast(body_scope))`。之所以要补发：`initRootEmitter` 在任何 Builder 存在之前就确立了 body-scope 标识，这一个 enter 事件只能等 Builder 挂上后才落流（qjs 在 `js_parse_program` 之前由 `push_scope` 发 `OP_enter_scope`，无 source 事件，quickjs.c:24128-24135/31441）。
- **所有权 / 错误 / 调用**：自己不分配，分配发生在转调的 `ensureBuilderForFd`（Builder 挂在 `fd.builder` 上）。error set 是 **`compiler.builder.Error`**：`body_scope < 0` 直接 `error.InvalidBytecode`，`enter_scope` 的发射失败由 `errdefer v2b.rollback(snapshot)` 把 Builder 退回本函数入口态（注意退的是 Builder 的快照，不是 `rollbackEmission`）。唯一调用方 `compileQjsProgram`（`:16255`）。

### `currentCodeLen` (`src/parser.zig:3613`)

- **签名**：`fn currentCodeLen(self: *State) usize`。
- **作用**：读当前发射目标已写出的字节码长度，也就是下一条指令的起始 pc。
- **实现**：`emit_to_function_def` 时返回 `curFunc().byte_code.len`，否则返回 root 的 `self.function.code.len`。
- **所有权 / 错误 / 调用**：无：纯读长度，不分配、无 error set。读的是 phase-1 原始字节流（`curFunc().byte_code` / `self.function.code`），**不是** Builder 的 `code_len`——这两个流是分开的。调用方 3 处：`takeEmissionSnapshot`、`parseFunctionParamsAndBody`、`takeParserSnapshot`。

### `currentAtomOperandLen` (`src/parser.zig:3618`)

- **签名**：`fn currentAtomOperandLen(self: *State) usize`。
- **作用**：读当前发射目标已记账的 atom 操作数个数。
- **实现**：一个三元式：`emit_to_function_def` 时取 `curFunc().atom_operands.len`，否则取 `self.function.atom_operands.len`。`takeEmissionSnapshot` 用它记 atom 回滚点，`rollbackEmission` 的失败路径据此截回。
- **所有权 / 错误 / 调用**：无：纯读长度，不分配、无 error set。调用方 3 处：`takeEmissionSnapshot`（`src/parser.zig:2821`）、`parseForStatement`（`:9445`）、`takeParserSnapshot`（`:13217`）。

### `parseLogicalAssignment` (`src/parser.zig:3946`)

- **签名**：`fn parseLogicalAssignment( s: *State, flags: ParseFlags, lvalue: *LValue, kind: LogicalAssignKind, direct_lhs_atom: ?Atom, ) Error!void`。
- **作用**：发 `&&=` / `||=` / `??=` 的短路赋值序列。
- **实现**：按 `&&=` / `||=` / `??=` 的短路语义排指令（对照 qjs `js_parse_assign_expr2` 的逻辑赋值分支，quickjs.c:28167-28204；所有拓扑记账一律无 source）。先 `dup` 复制已读出的旧值；`kind == .nullish` 时再发 `is_undefined_or_null` 把判定转成布尔；新建 `skip_assign` 标签并按 kind 发条件跳转（`.lor` 用 `if_true`，其余用 `if_false`），短路成立就跳过整个赋值。赋值臂里：`drop` 丢掉旧值，用只保留 `in_accepted` 的 `rhs_flags` 调 `parseAssignExpr2` 解析 RHS；若 `direct_lhs_atom` 非空且与 lvalue 持有的 `name` 相同（匿名函数直接赋给标识符），补一次 `setObjectName`。随后按 `lvalue.depth` 把待存值排到正确深度：depth 3 走 `emitterOpU8(ext0, ext0_sub.insert4)`，0/1/2 分别是 `dup` / `insert2` / `insert3`（其他值 `unreachable`），再 `putLValue(..., .no_keep_depth)` 落存。最后新建 `end` 标签、`goto end`；`skip_assign` 臂按 `depth` 连发同样多条 `nip` 把 lvalue 的基址/键弹掉、只留旧值；两臂在 `end` 汇合。
- **所有权 / 错误 / 调用**：不分配 JS 对象；全部产出是字节码与两个 Builder label（`skip_assign` / `end`，只是 Builder 内索引，无释放义务）。`lvalue` 是**借用**的可变指针，本函数消费它的 `depth` 与 `name` 但不接管它——释放仍归调用方的 `LValue.deinit`。失败来自 `parseAssignExpr2` 递归（可能是 `SyntaxError` / `StackOverflow`）与底层 Builder 的 OOM / 溢出（经 `mapBuilderError` 折成 `Error.*`）；`lvalue.depth` 超出 0-3 是 `unreachable`（Debug 下 panic）。树内唯一调用方 `parseAssignExpr2`（`:4097`）。

### `LValue.deinit` (`src/parser.zig:4018`)

- **签名**：`fn deinit(self: *LValue, _: *State) void`。
- **作用**：放弃描述符对 `name` atom 的所有权标记（`putLValue` 把 atom 交出去之后、或调用方中途放弃这个赋值目标时的收尾）。
- **实现**：
`LValue` 丢掉 `owns_name` 标记。atom 若已交给 put 指令则不再 free；若调用方提前放弃，标记清掉即可（atom 由 CompileAtomScope 区间根管）。
- **所有权 / 错误 / 调用**：如今**什么都不释放**：函数体只把 `owns_name` 清零。`name` 里那个 atom 在 TGC S3-c 之后是普通借用 id，由 `CompileAtomScope` 统一作根，所以 `getLValue` 从 Builder 里 `takeTrailingAtomOpcodeOwned` 取回的名字不再带引用计数义务——结构体上方那句「retained atom … until putLValue transfers or releases it」的注释是旧协议的遗留。无 error set。调用方全是 `defer`/`errdefer`：`parseAssignExpr2`（`src/parser.zig:4072`）、`getLValue`（`:4350`）、`parseUnary`（`:4883`）、`parsePostfixExpr`（`:5589`）、`parseForInOf`（`:10900`）等 7 处。

### `isRuntimeInvalidCallOpcode` (`src/parser.zig:4025`)

- **签名**：`fn isRuntimeInvalidCallOpcode(op_id: u8) bool`。
- **作用**：谓词：该 opcode 是否属于调用表达式族（`call` / `call_method` / `apply` / `eval` / `apply_eval`）——非严格模式下拿它当赋值目标只在运行时报 ReferenceError（Annex B）。
- **实现**：一个 `switch (op_id)`：`op.call` / `op.call_method` / `op.apply` / `op.eval` / `op.apply_eval` 归一分支返回 true，其余 false。这五个正是 Annex B 允许当赋值目标解析、但必须在运行时抛 ReferenceError 的 CallExpression 尾指令。
- **所有权 / 错误 / 调用**：无：纯 comptime 查表式 switch，不碰 `State`、不分配、无 error set。唯一调用方 `getLValue`（`src/parser.zig:4338`）的 Annex-B 宽松模式分支。

### `emitInvalidAssignmentTarget` (`src/parser.zig:4042`)

- **签名**：`fn emitInvalidAssignmentTarget(s: *State) Error!void`。
- **作用**：给「调用表达式当赋值目标」发出运行时抛 ReferenceError 的两条指令（Annex B 语义）。
- **实现**：两条指令：`Emitter.opNoSource(s, op.drop)` 丢掉已求值的 CallExpression 目标，再 `Emitter.opAtomU8(s, op.throw_error, null_atom, opcode.throw_error_invalid_assignment_target)` 抛出 Annex-B 规定的运行时 ReferenceError。注释说明为何要经 `Emitter` 而不是直接写 legacy 流：两个后端都要能落地——legacy 流保持它原先那两次调用，v2 解析则把它们路由进 Builder，而不是悄悄追加到没人消费的 legacy 缓冲。
- **所有权 / 错误 / 调用**：不分配；两条 `Emitter` 调用都落到 `activeBuilder()`，失败经 `mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。注意它发的是**运行时**抛错指令 `throw_error`（`throw_error_invalid_assignment_target`），不是编译期 `SyntaxError`：atom 操作数写的是 `null_atom`，没有任何 atom 所有权。调用方 4 处：`parseAssignExpr2`（`src/parser.zig:4092`）、`parseUnary`（`:4885`）、`parsePostfixExpr`（`:5598`）、`parseForInOf`（`:10912`）。

### `hasWithScopeFrom` (`src/parser.zig:4060`)

- **签名**：`fn hasWithScopeFrom(fd_start: *const function_def_mod.FunctionDef, scope_start: i32) bool`。
- **作用**：谓词：从指定 `FunctionDef` / 作用域往外走，是否存在笼罩此处的 `with` 作用域。
- **实现**：从 `fd_start` / `scope_start` 起沿 FunctionDef 链向外走。每一层：严格模式的 FunctionDef 整层跳过（`with` 在严格模式不合法）；否则若 `scope` 落在 `current.scopes` 范围内，就从 `scopes[scope].first` 起沿 `vars[].scope_next` 遍历，遇到 `var_name == atom_module.ids.with_object` 立即 `return true`。一层走完后 `scope = current.parent_scope_level`、`fd = current.parent` 继续，链走空返回 false。注释解释为何一条 `scope_next` 链就是完整可见链：`appendScope` 继承父作用域的可见链表头、`addScopeVar` 把新声明挂到链首，所以这与 QuickJS `has_with_scope` 用的是同一个循环。
- **所有权 / 错误 / 调用**：无：纯读 `*const FunctionDef` 链（`scopes`/`vars`/`parent`），不分配、无 error set，也不改任何状态；比较的是裸 atom id `ids.with_object`，不涉及引用计数。调用方 2 处：`getLValue`（`src/parser.zig:4386`）与 `prepareCallReference`（`:5526`）。

### `reemitLValueGetter` (`src/parser.zig:4085`)

- **签名**：`fn reemitLValueGetter(s: *State, lvalue: *const LValue) Error!void`。
- **作用**：`keep` 模式（复合赋值、前/后缀自增）下把刚被 `getLValue` 收回的那条 getter 重新发一遍，使目标的基址/键留在栈上、同时旧值被读出来。
- **实现**：按 `lvalue.opcode` 分六路，全部走无 source 形式（这是 `reemitLValueGetterAssumeCapacity` 的 v2 孪生）：`.scope_var` 先断言 `emit_phase1_temp`，重发 `scope_get_var`（保留的 atom + scope，quickjs.c:26009-26013）；`.field` 发 `get_field2`，在取出的值下面保留基对象（26015-26018）；`.private_field` 同样断言 phase-1 后发 `scope_get_private_field2`，保留基址与 phase-1 scope 操作数（26019-26023）；`.array_element` 发 `get_array_el3`，基址与键都留给后面的 setter（26024-26026）；`.super_value` 连发 `to_propkey`、`ext0` 子码 `dup3`、`get_super_value`，保住 receiver/base/key 三元组（26027-26030）；`.ref_value` 发 `get_ref_value`，穿过 with-scope 引用读值并保留引用对（26007-26008）。
- **所有权 / 错误 / 调用**：`lvalue` 是 `*const` **借用**，本函数只读它的 `opcode`/`name`/`scope`，不接管也不清 `owns_name`——描述符仍归调用方，`name` 那个 atom 因此同时出现在描述符和重发指令的操作数里；这在 TGC S3-c 之后是安全的（编译期 atom 是借用 id，由 `CompileAtomScope` 作根，名字里的 `Owned` 不再意味着引用计数转移）。不分配；两处 `std.debug.assert(s.emit_phase1_temp)`（`.scope_var` / `.private_field` 臂）在 Debug 下是 panic 而非可恢复错误。失败只来自底层 Builder（经 `mapBuilderError` 折成 `Error.OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`）。树内唯一调用方 `getLValue`（`:4457`，`keep` 为真时）。

### `getLValue` (`src/parser.zig:4128`)

- **签名**：`fn getLValue(s: *State, keep: bool) Error!LValue`。
- **作用**：把刚刚发出的那条 getter 从字节码尾部收回，换成一份描述赋值目标的 `LValue`（连同它取回的 atom 所有权）；`keep` 为真时再把 getter 重发一遍，供先读后写的复合赋值使用。
- **实现**：
对照 `get_lvalue`（`quickjs.c:25933`）。看 Builder `last_opcode_pos`：无则 `InvalidAssignmentTarget`。

非严格下若最后一条完整指令是 call/call_method/apply/eval/apply_eval，返回 `invalid_call=true` 的伪 lvalue（Annex B 运行时 ReferenceError）。

否则按 opcode：
- `scope_get_var`：解码 atom+scope；禁止给 `eval`/`arguments`（严格）、`this`、`new.target` 赋值。`with`、严格未解析引用、或松散模式 RHS 含直接 eval 时改成 `scope_make_ref`（`ref_value`，depth 2）。
- `get_field`：取回字段 atom，depth 1。
- `scope_get_private_field`：私有名+scope，depth 1。
- `get_array_el` / `get_super_value`：截断 getter，depth 2/3。
- 其他：`InvalidAssignmentTarget`。

`keep` 为真时 `reemitLValueGetter` 把 getter 再写回去（复合赋值 / 前缀更新要先读后写）。
- **所有权 / 错误 / 调用**：**按值返回**一个 `LValue`，其 `name` 是 `v2b.takeTrailingAtomOpcodeOwned` 从 Builder 的 atom 操作数账本里取回来的 id、`owns_name = true`：调用方必须配 `defer lvalue.deinit(s)`（8 个调用方全都这么写）。函数内部自身的 `errdefer if (lvalue_initialized) lvalue.deinit(s)` 只覆盖构造之后的失败。它会**改写已发射的字节码**：`takeTrailingAtomOpcodeOwned` / `truncateLastOpcodePreserveSources` 把尾部那条 getter 从 Builder 里摘掉（对应 qjs 的 `fd->byte_code.size = fd->last_opcode_pos` 回卷），所以只能在 getter 确实是整个尾部时调用，否则返回 `Error.InvalidAssignmentTarget`。错误面：`InvalidAssignmentTarget`（非法赋值目标、严格模式下的 `eval`/`arguments`、`this`/`new.target`、opcode 不在白名单、尾部长度对不上）与 Builder 错误经 `mapBuilderError` 的折叠。调用方 8 处：`parseAssignExpr2`（`:4071`）、`parseUnary`（`:4882`）、`parsePostfixExpr`（`:5588`）、`parseVar`（`:10635`）、`parseForInOf`（`:10899`）、`definePatternBindingAtom`（`:12682`）、`parsePatternTarget`（`:12707`）、`shorthandPatternTarget`（`:12726`）。

### `putLValue` (`src/parser.zig:4264`)

- **签名**：`fn putLValue(s: *State, lvalue: *LValue, mode: PutLValueMode) Error!void`。
- **作用**：按 `LValue` 的目标形态和 `PutLValueMode` 要求的栈保留方式发出对应 setter，并把描述符持有的 atom 所有权转交给这条指令。
- **实现**：对照 `put_lvalue`（`quickjs.c:26077`）。①先用一张 `switch (opcode)` × `switch (mode)` 的表算出 `shuffle_op`：`scope_var` 只有 `.keep_top` 需要 `dup`；`field` / `private_field` 分别是 `insert2` / `perm3` / `swap`；`array_element` 与 `ref_value` 是 `nop` / `insert3` / `perm4` / `rot3l`；`super_value` 全部为 null（它的保留模式改走 ext0 子码）。②前置校验：`scope_var` / `private_field` 要求 `emit_phase1_temp` 且 `owns_name`，`field` 要求 `owns_name`，`ref_value` 还要求 `ref_label != null`（否则分别是 `InvalidAssignmentTarget` / `ParserInvariant`）。③`ref_value` 特例：**在栈洗牌之前**清 `owns_name` 并 `Emitter.bindParser(lvalue.ref_label.?)` 绑上 `scope_make_ref` 的 aux 标签——这个 bind 就是 provenance 边界，对应 qjs 里 `JS_FreeAtom(name)` 之后的 `emit_label`（quickjs.c:26118-26123），并且即使 `scope_make_ref` 已消耗掉辅助 refcount，它仍作为 Stage-4 匹配屏障保留（legacy phase-1 流用 `OP_label` 表达同一边界）。④发栈洗牌：`super_value` 的 `.keep_top` / `.keep_second` / `.no_keep_bottom` 分别走 `ext0` 子码 `insert4` / `perm5` / `rot4l`（insert4 已被 fusion v4 回收，按 using+sub 编码），其余情况发上面算出的 `shuffle_op`。⑤发 setter 并转移 atom：`scope_var` → `scope_put_var`（atom+scope）、`field` → `put_field`、`private_field` → `scope_put_private_field`，三者都先清 `owns_name` 再发；`array_element` → `put_array_el`；`ref_value` → `put_ref_value`；`super_value` → `ext0` 子码 `put_super_value`。
- **所有权 / 错误 / 调用**：`lvalue` 是**可变借用**：发出 setter 之前先把 `owns_name` 清零，等于把 `name` 这份所有权标记交给那条 `*Owned` 指令（调用方后续的 `deinit` 因此变成空操作）。`ref_value` 臂还会 `Emitter.bindParser(lvalue.ref_label.?)` 把 `scope_make_ref` 的 aux 标签绑在此处——这是 provenance 边界，对应 qjs `JS_FreeAtom(name)` 之后的 `emit_label`。本函数不分配、不释放缓冲。错误面：前置校验不过分别是 `Error.InvalidAssignmentTarget`（`scope_var`/`private_field` 不在 phase-1、或 `owns_name` 已丢）与 `Error.ParserInvariant`（`ref_value` 少了 `ref_label`），其余失败来自 Builder 经 `mapBuilderError` 的折叠。调用方 7 处：`parseAssignExpr2`（`:4118`）、`parseLogicalAssignment`（`:4183`）、`parseUnary`（`:4891`）、`parsePostfixExpr`（`:5604`）、`parseVar`（`:10645`）、`parseForInOf`（`:10914`）、`putPatternTarget`（`:12753`）。

### `hasKnownBinding` (`src/parser.zig:4362`)

- **签名**：`fn hasKnownBinding(s: *State, atom_id: Atom) bool`。
- **作用**：谓词：当前 `FunctionDef` 的闭包变量、顶层声明、词法作用域链或形参里，是否已经有这个名字。
- **实现**：在当前 FunctionDef 自己的四张表里依次找 `atom_id`：①`closure_var` 的 `var_name`；②`global_vars`——注释指出 QuickJS 把顶层声明留在 `global_vars` 里直到 `add_global_variables` 把它们物化成 closure 行，所以解析期的绑定查询（尤其 local-export 校验与模块重复声明检查）必须直接查声明表，不能指望 parser 造出来的 closure 占位；③词法作用域：从 `s.scope_level` 起沿 `scopes[].parent` 向外，每层从 `scopes[scope].first` 沿 `vars[].scope_next` 扫，一旦 `v.scope_level != scope` 就 break（链已经跨到外层）；④`args`。四处都落空返回 false。
- **所有权 / 错误 / 调用**：无：只读 `curFunc()` 的 `closure_var`/`global_vars`/`scopes`/`vars`/`args` 四张表做线性查找，不分配、无 error set、无副作用；只看**当前** FunctionDef 自己的表（不上溯父函数）。调用方 8 处，集中在 module 顶层重声明与 local-export 校验：`parseUsingDeclaration`（`src/parser.zig:9952`）、`validateModuleLocalExports`（`:15328`）、`addModuleImportBinding`（`:15348`），其余 5 处在 `strictUnresolvedAssignmentNeedsReference`（`:4617`）/`parseVar`（`:10571`）/`parseFunctionDecl`（`:11115`）/`definePatternBindingAtom`（`:12661`）/`parseClass`（`:14897`）。

### `strictUnresolvedAssignmentNeedsReference` (`src/parser.zig:4411`)

- **签名**：`inline fn strictUnresolvedAssignmentNeedsReference(s: *State, atom_id: Atom, keep: bool) bool`。
- **作用**：判断一次严格模式赋值是否必须改发引用形式（`scope_make_ref` + `put_ref_value`）而不是直接 `scope_put_var`，以便「目标不可解析」这一事实在 LHS 求值时就被定下来。
- **实现**：四道否决之后取反查绑定表：`keep` 为真直接 false（复合赋值与更新运算符会先读目标，那次读已经替不可解析的严格引用抛过错）；`s.is_strict` 与 `curFunc().is_strict_mode` 都不成立 false；`s.is_eval` / `s.lex.is_module` / `curFunc().is_module` 任一成立 false；`s.cur_func_stack.len != 0`（不在最外层 FunctionDef）false；最后 `return !hasKnownBinding(s, atom_id)`。doc 注释给出理由与限制：按 sec-putvalue，PutValue 检查的是 RHS 之前由 ResolveBinding 产出的 Reference Record，而 RHS 可能在中间创建这个全局属性（`undeclared = (this.undeclared = 5)`），此时全局查找发生在 RHS 之后的普通 `scope_put_var` 会静悄悄存进去；发引用形式相当于在 RHS 运行前给未解析绑定拍快照，`resolve_variables` 随后会在绑定其实静态可知的地方把它折回直接存储。刻意只限普通脚本的最外层 FunctionDef：parser 发 phase-1 name+scope 字节码期间 `ensureClosureVar` 是 no-op（绑定发现属于拓扑 pass），`hasKnownBinding` 只看得见本 FunctionDef 的表——嵌套函数里它会对每个父函数捕获都报「无绑定」，模块或直接 eval 里绑定可能住在 module record 或调用者环境里；只有脚本顶层，「不在这个 FunctionDef 的表里」才等同于「不可解析」。
- **所有权 / 错误 / 调用**：无：`inline fn`，只读 `State` 与 `curFunc()` 的标志位再转 `hasKnownBinding`，不分配、无 error set。唯一调用方 `getLValue`（`src/parser.zig:4376`）的 `scope_get_var` 臂。

### `argumentsIdentifierIsForbidden` (`src/parser.zig:4421`)

- **签名**：`fn argumentsIdentifierIsForbidden(s: *State) bool`。
- **作用**：判断当前正在解析的函数里 `arguments` 标识符是否被禁用（类字段初始化器及其中的箭头函数）。
- **实现**：单行 `return !s.curFunc().arguments_allowed;`。注释说明依据：QuickJS 把每个字段初始化器解析进一个 `arguments_allowed=false` 的合成方法 FunctionDef（quickjs.c:36472）；zjs 的实例初始化器与静态初始化器现在都用这个真实的函数边界，箭头函数继承它的入口契约。
- **所有权 / 错误 / 调用**：无：单行读 `curFunc().arguments_allowed`，不分配、无 error set。唯一调用方 `parsePrimary`（`src/parser.zig:6367`）在识别出 `arguments` 标识符时。

### `emitYieldStarDelegation` (`src/parser.zig:4811`)

- **签名**：`fn emitYieldStarDelegation(s: *State, is_async: bool) Error!void`。
- **作用**：把 `yield*` 降成完整的迭代器委托循环（含 async 版本）。
- **实现**：
对照 `quickjs.c:28038-28131`。`for_of_start`/`for_await_of_start` 后丢掉 iter proto，压两个 undefined。循环：`iterator_next`（async 再 `await`）→ `iterator_check_object` → `get_field2 done`；未完成则 `yield_star`/`async_yield_star`，按 resume 的 throw/return 调 iterator 的 `throw`/`return`，再回到循环。完成则取 `value` 作为 yield* 的结果。全程 LabelId，不写绝对 PC。
- **所有权 / 错误 / 调用**：不分配 JS 对象；`done`/`value` 用的是**预定义 atom**（`atom_module.predefinedId`，取不到即 `Error.ParserInvariant`），不是新建的，因此没有 atom 所有权义务。循环骨架全部是 Builder 的 `LabelId`（索引，无释放义务），不写绝对 PC。不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。树内唯一调用方 `parseUnary`（`:4935`，`yield*` 分支）。

### `emitSuperThis` (`src/parser.zig:4897`)

- **签名**：`fn emitSuperThis(s: *State) Error!void`。
- **作用**：为 super 引用压上 `this`（方法与其中的箭头函数共用同一条伪变量查找）。
- **实现**：`emit_to_function_def` 时发 `s.emitScopeGetVar(atom_this)` 后返回——注释指出 QuickJS 在方法和其中嵌套的箭头函数里发的是同一条 scope 查找，由 `resolve_pseudo_var` 去决定它落成所有者的局部槽还是对最近 ThisBinding 的闭包捕获。否则（低层可变 root fixture，没有 FunctionDef）直接 `Emitter.op(s, opcode.op.push_this)`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。两条臂都不分配：`emit_to_function_def` 时转 `emitScopeGetVar(atom_this)`（`atom_this` 是预定义 atom，借用），否则直接发 `push_this`。树内唯一调用方 `emitSuperThisAndHomeObject`（`:5117`）。

### `emitSuperThisAndHomeObject` (`src/parser.zig:4912`)

- **签名**：`fn emitSuperThisAndHomeObject(s: *State) Error!void`。
- **作用**：为 super 属性引用压上 `[this, home object]` 这一对操作数。
- **实现**：两步：先 `emitSuperThis(s)` 压 `this`，再压 home object——`emit_to_function_def` 时走普通伪变量解析 `s.emitScopeGetVar(atom_home_object)`，否则发 `Emitter.opU8(s, op.special_object, special_object_subtype.home_object)` 从帧里取特殊对象。两条合起来正是 super 属性引用要消费的 `[this, home_object]` 对。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。不分配；用的两个名字 `atom_this` / `atom_home_object` 都是预定义 atom，借用即可。调用方 2 处，都在 `parseMemberChain`（`:5894`、`:5972`）的 super 属性引用上。

### `discardTrailingGetSuper` (`src/parser.zig:4921`)

- **签名**：`fn discardTrailingGetSuper(s: *State) Error!void`。
- **作用**：把刚发出的那条 `get_super` 从 Builder 尾部撤掉（`super` 被当成调用/构造引用而不是属性读时的回卷）。
- **实现**：取 `activeBuilder()`；`last_opcode_pos < 0` 即 `Error.ParserInvariant`。再校验它确实是流的最后一条指令且形状对得上：`pos + 1 == builder.code_len` 且 `builder.code[pos] == opcode.op.get_super`，任一不成立都是 `ParserInvariant`。通过后 `builder.truncateLastOpcodePreserveSources(pos)`，Builder 侧错误经 `mapBuilderError` 转成 parser 的 Error；按名字所示 source 事件保留不动。
- **所有权 / 错误 / 调用**：不分配、不释放：只让 Builder 把尾部那一个字节的 `get_super` 丢掉（`truncateLastOpcodePreserveSources`，source 事件按名字所示保留）。三道前置校验（`last_opcode_pos < 0`、不是整条尾巴、尾字节不是 `get_super`）全部返回 `Error.ParserInvariant`——内部不变量，走 `setInternalCompilerError` 的 ICE 出口而不是 SyntaxError；Builder 侧错误经 `mapBuilderError` 折叠。调用方 5 处：`parseLhsExpr`（`:5654`）、`parseCapturedSuperConstructorCall`（`:5685`）、`parseMemberChain`（`:5893`/`:5971`/`:5997`）。

### `parseDelete` (`src/parser.zig:4948`)

- **签名**：`fn parseDelete(s: *State, flags: ParseFlags, delete_position: diagnostics.Position) Error!void`。
- **作用**：解析 `delete` 一元表达式，并把尾部的属性访问改写成删除序列。
- **实现**：自身只有两步：`parseUnary(.{ .pow_allowed = false, .in_accepted = flags.in_accepted })` 解析操作数，然后 `finishDelete(s, delete_position)`。真正的活在 `finishDelete` 的尾码回改（对齐 `js_parse_delete`，`quickjs.c:26829`）：`a.b` 把尾部 `get_field` 换成同字节长度的 `push_atom_value b` 再发 `delete`；`a[i]` 截掉 1 字节的 `get_array_el` 再发 `delete`；操作数不是引用时按 spec 发 `drop ; push_true`（仍要求值以保留副作用）。因为只动最后一次访问，`delete a.b.c` 这种任意深度的链都成立；optional chain 与 `super` 有各自的尾码改写，私有名引用直接报错。
- **所有权 / 错误 / 调用**：自身不分配、不发任何指令：只是 `parseUnary` + `finishDelete` 的两行编排，错误全部来自这两个被调方（`parseUnary` 的 `SyntaxError`/`StackOverflow`，`finishDelete` 的 `ParserInvariant` 与「私有字段/严格模式标识符不可删」两条 `failWithMessage`）。`delete_position` 按值传入，只用于错误定位。树内唯一调用方 `parseUnary`（`:4872`，`TOK_DELETE` 分支）。

### `compactAppendedTailReplacement` (`src/parser.zig:4959`)

- **签名**：`fn compactAppendedTailReplacement( s: *State, snapshot: compiler.builder.Snapshot, remove_start: u32, ) Error!void`。
- **作用**：把快照点之后新追加的那段替换指令整体左移，压掉快照里 `remove_start` 起的那条待删尾指令——qjs「`fd->byte_code.size = fd->last_opcode_pos` 之后重新发射」在 v2 流上的对应物。
- **实现**：取 Builder，先校验区间：要求 `remove_start < snapshot.code_len` 且 `snapshot.code_len <= v2b.code_len`，算出 `removed_len`（被删尾指令长度）与 `appended_len`（快照后新追加的长度）。接着把四类不变量全部查完（任一不满足都 `Error.ParserInvariant`，因为提交阶段不可失败）：①快照内的 reloc 不得落在被删区间内，快照之后新增的 reloc 必须都在 `snapshot.code_len` 之后；②快照内已绑定的 label 不得绑在被删区间内部，新增的已绑定 label 必须都在 `snapshot.code_len` 之后；③新增 source 槽的 `temp_offset` 必须都不小于 `snapshot.code_len`；④`last_opcode_pos` 不得还指在快照区内（它必须已经指向替换段）。校验通过后进入无失败提交：`std.mem.copyForwards` 把追加段搬到 `remove_start`，`code_len = remove_start + appended_len`；新增 reloc 的 `operand_offset`、新增已绑定 label 的 `bound_offset`、以及 `last_opcode_pos` 各减 `removed_len`；source 槽则把新增的那批（`temp_offset` 同样减 `removed_len`）覆盖写到 `old_source_keep` 起——`old_source_keep` 是快照里 `temp_offset < remove_start` 的槽数，于是描述被删尾巴的旧 source 事件消失，新事件跟着替换段一起左移。
- **所有权 / 错误 / 调用**：不分配、不释放：全部工作是在 `activeBuilder()` 已有的 `code`/`relocs`/`label_slots`/`source_slots` 数组里做 `copyForwards` 和偏移减法，缓冲仍归 Builder（`fd.memory`）。错误全是 `Error.ParserInvariant`——七处前置检查（被删区间里还有 reloc / 绑定 label / source 事件 / `last_opcode_pos`）都是**内部不变量**而非源程序判决，`compile` 经 `isInternalCompilerError`（`src/parser.zig:16352`）走 `setInternalCompilerError` 而不是 SyntaxError；没有 OOM 路径。注意它不是失败可回滚的：命中 `ParserInvariant` 时前面的检查还没动过数据，但调用方不做局部回滚，整个编译就此终止。调用方 4 处：`finishDelete`（`:5330`/`:5338`/`:5359`）与 `rewriteOptionalChainDeleteBuilder`（`:5412`）。

### `optionalChainExitAtEnd` (`src/parser.zig:5050`)

- **签名**：`fn optionalChainExitAtEnd(s: *State) Error!compiler.LabelId`。
- **作用**：从 Builder 的 label 身份里找回「此刻正好绑在流末尾」的那个可选链短路出口 LabelId。
- **实现**：遍历全部 label 槽，跳过未绑定或 `bound_offset != v2b.code_len` 的。对每个候选沿 `slot.first_reloc` / `reloc.next` 走它的重定位链（下标越界或步数超过 `reloc_len` 都判 `ParserInvariant`，防环），看有没有这样一条 `.jump32`：`operand_offset > 0`、`operand_offset + 4 <= code_len`、操作数前一个字节是 `opcode.op.goto`、且 4 字节操作数读出来正是这个 label 下标——有则置 `has_chain_goto`。没有链上 goto 的候选跳过；命中第二个候选立即 `ParserInvariant`（歧义按失败处理）；一个都没有返回 `Error.UnexpectedToken`。注释给出依据：链的生产者在 getter 末尾 raw-bind 这个出口，并且至少有一条无 source 的 `goto` 重定位引用它。
- **所有权 / 错误 / 调用**：只读 Builder 的 label/reloc 表，不分配、不修改；返回的 `LabelId` 是索引，无释放义务。两种失败：reloc 链越界或走成环、以及「末尾同时有两个候选 label」→ `Error.ParserInvariant`（内部不变量，走 ICE 出口）；找不到候选则返回 `Error.UnexpectedToken`，这条会经 `compile` 变成 `Result.syntax_error` 再由 `exec/eval_entry.zig:127` 抛成 JS SyntaxError。调用方 2 处：`rewriteOptionalChainDeleteBuilder`（`src/parser.zig:5374`）与 `prepareCallReference`（`:5468`）。

### `emitDeleteNonReference` (`src/parser.zig:5083`)

- **签名**：`fn emitDeleteNonReference(s: *State) Error!void`。
- **作用**：操作数不是 Reference 时 `delete` 的结果序列：丢值、压 `true`。
- **实现**：取 Builder 快照并挂 `errdefer v2b.rollback(snapshot)`，然后发两条：`op.drop` 丢掉操作数、`op.push_true` 压 `true`。对应规范里「操作数不是 Reference 时，先为副作用求值，然后 `delete` 求值为 `true`」。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。自己额外挂了一层 `v2b.snapshot()` + `errdefer v2b.rollback(snapshot)`，保证两条指令要么都在要么都不在（这是 Builder 快照，不是 `rollbackEmission`）。不分配。调用方 3 处，全在 `finishDelete`（`:5301` 无尾指令、`:5347` `this`/`new.target`、`:5361` 其余非引用）。

### `finishDelete` (`src/parser.zig:5095`)

- **签名**：`fn finishDelete(s: *State, delete_position: diagnostics.Position) Error!void`。
- **作用**：`delete` 的发射收尾：把刚解析完的操作数尾部那条访问指令就地改写成 delete 形态（`js_parse_delete` 的 v2 版本）。
- **实现**：取 Builder；`last_opcode_pos < 0` 直接 `emitDeleteNonReference`；`pos >= code_len` 为 `ParserInvariant`。随后按尾指令字节分派：`get_field_opt_chain` / `get_array_el_opt_chain` 转 `rewriteOptionalChainDeleteBuilder`。`get_field`（W1 下是 `atom_cache_u8`，6 字节）先校验它是整条尾巴且 atom 台账末项与指令里的 atom 一致，私有名直接 `failWithMessage`「private fields cannot be deleted」；否则取快照后把 opcode 原地改成 `push_atom_value` 并把 `code_len` 砍到 `pos + 5`（替换形式比 W1 getter 少一个 `cache_idx` 字节），再发 `delete`。`get_array_el`（1 字节）取快照后先发 `delete`，再 `compactAppendedTailReplacement(snapshot, pos)` 把新尾左移压掉旧 getter。`get_length`（1 字节）同法，只是先补一条 `push_atom_value length` 再 `delete`。`scope_get_var`（phase-1，7 字节）校验 atom 台账后：`this` / `new.target` 不是可删引用，转 `emitDeleteNonReference`；严格模式下 `failWithMessage`「unqualified identifiers cannot be deleted in strict mode」；否则把 opcode 原地换成同宽的 `scope_delete_var`。`scope_get_private_field` 直接报私有字段不可删。`get_super_value`（1 字节）追加 `throw_error`（null atom、子码 3）后 compact。其余一律 `emitDeleteNonReference`。doc 注释点出这套改写的性质：同宽的 field/scope 改写保留各自的 atom 台账项；需要截断的无 atom getter 则先追加、待全部分配成功后再 compact，因而是事务性的。
- **所有权 / 错误 / 调用**：就地**改写已发射的字节码**：同宽的 `get_field`→`push_atom_value`、`scope_get_var`→`scope_delete_var` 保留各自的 atom 台账项；需要截断的无 atom getter 走「先追加再 `compactAppendedTailReplacement`」的事务写法，所有分配成功后才提交。改写前都用 `v2b.snapshot()` + `errdefer v2b.rollback` 兜底。不分配 JS 对象；atom 是台账里已有的借用 id。错误面三类：`Error.ParserInvariant`（`pos >= code_len`、尺寸/台账对不上等内部不变量）、两条源程序判决 `failWithMessage`（`:5315`/`:5353`「private fields cannot be deleted」、`:5350`「unqualified identifiers cannot be deleted in strict mode」，经 `compile` 成 `Result.syntax_error`）、以及 Builder 经 `mapBuilderError` 折出的 OOM/溢出。树内唯一调用方 `parseDelete`（`:5154`）。

### `rewriteOptionalChainDeleteBuilder` (`src/parser.zig:5164`)

- **签名**：`fn rewriteOptionalChainDeleteBuilder(s: *State, pos: u32) Error!void`。
- **作用**：`delete a?.b` / `delete a?.[i]`：借已绑定的链出口 LabelId 把可选链尾部的伪 getter 改写成 delete 形态，并把短路路径引到一个 `drop; push_true` 垫片，使其求值为 `true`。
- **实现**：取 Builder，按尾字节判 `field_form`（`get_field_opt_chain` 在 W1 下 6 字节，数组形式 1 字节），要求它正是整条尾巴，再用 `optionalChainExitAtEnd` 取出共享链出口 label。field 形式还要核对 atom 台账末项；若该名字是私有名，走另一条出口：取快照后发 `drop` + `push_true`，并把 opcode 还原成普通 `get_field` 后返回。正常路径取快照挂 `errdefer rollback`：field 形式**先**把 opcode 原地改成 `push_atom_value` 并把 `code_len` 砍到 `pos + 5`——W1 让 `get_field_opt_chain` 比替换形式长一个字节，所以这一步必须早于追加尾巴，后面记下的 `cleanup_offset`、goto 重定位与 label 绑定才都是最终偏移。然后新建 `next_label`，依次发 `delete`、`goto next_label`，记 `cleanup_offset = v2b.code_len`，发垫片 `drop` + `push_true`，再 `Emitter.bindParser(next_label)`。收尾：field 形式把链出口 label 的 `bound_offset` 直接改绑到 `cleanup_offset`；数组形式先 `compactAppendedTailReplacement(snapshot, pos)` 把追加段左移，再绑到 `cleanup_offset - getter_size`。全程没有绝对 PC 进入 v2 流，新的汇合点一出生就是 LabelId 重定位。
- **所有权 / 错误 / 调用**：整段在 `v2b.snapshot()` + `errdefer v2b.rollback(snapshot)` 的保护下就地改写 Builder 已发射的字节（改 opcode、砍 `code_len`、改 label 的 `bound_offset`），不分配、不释放；新建的 `next_label` 只是 Builder 内索引。前置校验（尾指令形状/尺寸、atom 台账末项）不过即 `Error.ParserInvariant`；`optionalChainExitAtEnd` 找不到唯一出口时会把 `ParserInvariant`/`UnexpectedToken` 透传上来。私有名走「还原成普通 `get_field` + `drop; push_true`」的旁路而不是报错。树内唯一调用方 `finishDelete`（`:5308`）。

### `prepareCallReference` (`src/parser.zig:5245`)

- **签名**：`fn prepareCallReference( s: *State, consumer: CallConsumerKind, has_optional_site: bool, ) Error!PreparedCallReference`。
- **作用**：在调用实参开始发射之前，对「真正的最后一条 getter」做分类并就地改写，决定这次调用走普通调用、保留 receiver 的方法调用还是直接 eval，并告诉调用方可选链短路时要丢几个栈值。
- **实现**：取 Builder；`last_opcode_pos < 0` 时直接返回 `.plain` / `optional_drop_count = 1`；`pos >= code_len` 为 `ParserInvariant`。按尾字节分派：**可选链形式**（`get_field_opt_chain` 6 字节 / `get_array_el_opt_chain` 1 字节）核对尺寸与 atom 台账、取出链出口 label 后，取快照、新建 `next_label`、发 `goto next_label`，记 `cleanup_offset = code_len`，发 `undefined` 垫片并 `Emitter.bindParser(next_label)`；最后把 getter 原地改成 `get_field2` / `get_array_el2`（保留 receiver）、把链出口改绑到 `cleanup_offset`，返回 `.method` / drop 2。对应 qjs `js_parse_postfix_expr`（quickjs.c:26771-26790）：对已闭合的可选链引用发起调用要保留 receiver、活路径绕过 undefined 垫片、共享链出口移到该垫片；v2 用两个 LabelId 代替原来的 `OP_label` 字节。**`get_field`**（6 字节）原地改 `get_field2`，返回 `.method` / drop 2。**`scope_get_private_field`**（phase-1、7 字节）改 `scope_get_private_field2`，同样 `.method` / drop 2。**`get_array_el`**（1 字节）改 `get_array_el2`。**`get_super_value`**（1 字节）改成 `get_array_el`。**`scope_get_var`**（phase-1、7 字节）解出 atom 与 scope：普通消费者、无可选链站点且名字是 `eval` 时返回 `.direct_eval` / drop 1；否则若 `hasWithScopeFrom(curFunc(), scope)` 说明作用域链上有 `with`，把 opcode 改成 `scope_get_ref` 并返回 `.method` / drop 1（receiver 由引用对提供）。所有尺寸校验不过的分支与 `else` 都退回 `.plain` / drop 1。注释强调这是 QuickJS 的「调用点消费者」写法：只依据真正的最后一条指令分类改写，生产者绝不靠偷看下一个 token 来挑 receiver 形式。
- **所有权 / 错误 / 调用**：**按值返回** `PreparedCallReference`（kind + `optional_drop_count`，无堆资源、无释放义务）。副作用是就地改写尾部 getter 的 opcode（`get_field`→`get_field2` 等）并可能追加短路垫片，改写前取 `v2b.snapshot()` 并挂 `errdefer rollback`；不分配、atom 只读台账里的借用 id。错误面：尺寸/台账校验失败与 `optionalChainExitAtEnd` 的 `Error.ParserInvariant`，以及 Builder 经 `mapBuilderError` 折出的 OOM/溢出；校验不过的普通情形不报错而是退回 `.plain`。调用方 3 处：`parseMemberChain`（`:5920`/`:6011`）与 `parseTaggedTemplateInvocation`（`:6026`）。

### `emitPreparedCall` (`src/parser.zig:5332`)

- **签名**：`fn emitPreparedCall( s: *State, prepared: PreparedCallReference, shape: CallArgsShape, line_num: u32, col_num: u32, ) Error!void`。
- **作用**：按调用形态（普通 / 方法 / 直接 eval / apply）发出真正的调用指令，并把唯一的 source 事件钉在 callee 上。
- **实现**：先取 Builder 快照并挂 `errdefer rollback`，再 `Emitter.addSourceMarker(s, line_num, col_num)`——qjs 把一个 source 事件钉在 callee 上，其后的 call/apply 尾巴不再打 marker（quickjs.c:26623-26763）。然后按 `shape` × `prepared.kind` 分派：`.direct(argc)` 下 `.plain` 走 `emitterCallOp(op.call, argc)`、`.method` 走 `emitterCallOp(op.call_method, argc)`、`.direct_eval` 发 `op.eval`，其 u32 立即数是 `argc | (scope_level << 16)`；`.applied`（实参已收拢成数组的 apply 形态）下 `.plain` 先补 `undefined` + `swap` 再发 `apply 0`，`.method` 用 `perm3` 把 receiver 排到位再发 `apply 0`，`.direct_eval` 发 `apply_eval`（立即数是 `scope_level`）。最后 `prepared.kind == .direct_eval` 时调 `s.markDirectEvalCall()`，在当前 FunctionDef 上打 `has_eval_call` 标记。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。整段挂 `v2b.snapshot()` + `errdefer v2b.rollback`，source marker 与调用指令因此是原子的。`prepared` 按值传入，不持有资源。唯一的状态副作用是 `.direct_eval` 臂末尾的 `s.markDirectEvalCall()`（在当前 `FunctionDef` 上置 `has_eval_call`）。调用方 4 处：`parseMemberChain`（`:5923`/`:6013`）与 `parseTaggedTemplateInvocation`（`:6039`/`:6072`）。

### `emitOptionalChainTest` (`src/parser.zig:5902`)

- **签名**：`fn emitOptionalChainTest( s: *State, optional_chain_label: *?OptionalChainLabel, drop_count: u8, ) Error!void`。
- **作用**：在 `?.` 处发出「接收者是 null/undefined 就让整条链短路成 `undefined`」的测试序列。
- **实现**：先 `v2b.snapshot()`，`errdefer` 同时回滚字节码和 `optional_chain_label`（失败不能留下半条链和被污染的标签）。链出口标签惰性创建：`optional_chain_label.*` 为 `null` 时才 `Emitter.newLabel`，所以一条链上的多个 `?.` 共用一个出口。序列对齐 qjs `optional_chain_test`（`quickjs.c:26158`）：`dup`、`is_undefined_or_null`、`if_false NEXT`、`drop × drop_count`、`undefined`、`goto CHAIN_EXIT`（NoSource），最后 `Emitter.bind(NEXT)` 让正常访问从这里接着走。`drop_count` 在成员访问（`?.b` / `?.[k]`）是 1，在成员 dup 之后的方法调用（`obj?.b()` / `?.()`）是 2。出口 `goto` 的实际目标等 `parseLhsExpr` 走完整条链再绑。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的 `OutOfMemory` / `BytecodeOverflow` / `InvalidBytecode` 由 `mapBuilderError`（`:7448`）折成 `Error.*`（注意这条路径不归 `rollbackEmission` 管，Builder 自带 `snapshot`/`rollback`）。`optional_chain_label` 是**可变借用**的 optional：为空时才 `Emitter.newLabel` 惰性创建，于是同一条链上的多个 `?.` 共用一个出口 label；`errdefer` 同时回滚 Builder 快照和这个 out 参数，失败后不会留下半条链或被污染的标签。label 只是 Builder 内索引，无释放义务；出口 `goto` 的目标等整条链走完才绑。调用方 3 处，全在 `parseMemberChain`（`:5921` 属性、`:5925`/`:5935` 调用形态）。

### `emitTaggedTemplateSingletonObject` (`src/parser.zig:6287`)

- **签名**：`fn emitTaggedTemplateSingletonObject(s: *State, bytes: []const u8, raw_bytes: []const u8) Error!void`。
- **作用**：没有 runtime 造常量模板对象时的回退：用指令在运行期现搭单段标签模板对象。
- **实现**：没有运行时 runtime（因而做不出常量模板对象）时的回退路径：用六条指令在运行期现场搭出那个 `{ 0: cooked, raw: [raw] }` 形状。先 `internString(bytes)` 得到 cooked atom、发 `push_atom_value` + `array_from 1` 造出单元素 cooked 数组；再同法用 `raw_bytes` 造出单元素 raw 数组；最后 intern 出 `"raw"` 并发 `define_field`，把 raw 数组挂到模板数组的 `raw` 属性上。只处理单段（无插值）模板，所以两个数组的长度都写死 1。
- **所有权 / 错误 / 调用**：三次 `atoms.internString` 会在 AtomTable 里新建 atom，这些 id 的存活由本次编译的 `CompileAtomScope`（`compile` 在 `src/parser.zig:16083` 打开）作根，本函数既不 retain 也不 release；`Emitter.opAtom` 把 id 写进 Builder 的 atom 操作数流。失败源两类：`internString` 的 `OutOfMemory`，以及 Builder 经 `mapBuilderError` 折出的 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。唯一调用方 `parseTaggedTemplateInvocation`（`:6036`）的**无 runtime 分支**——只有解析器单测这样跑；生产路径走 `TaggedTemplateObjectBuilder` 造真对象。

### `realmArrayPrototype` (`src/parser.zig:6300`)

- **签名**：`fn realmArrayPrototype(rt: *core.JSRuntime) ?*core.Object`。
- **作用**：取当前 runtime 里某个 realm 的 `Array.prototype`，供解析期构造的模板/raw 数组挂原型。
- **实现**：先看 `rt.context_head`，再看 `rt.constructing_context_head`（context 还在构造中时用它），各自取 `ctx.array_shape` 的初始 shape 并返回它的 `proto`；两处都拿不到就返回 `null`。
- **所有权 / 错误 / 调用**：返回的是**借用**的 `*core.Object`（realm 初始 array shape 的 proto），不 retain、不建根，调用方只把它当 `createArray` 的 proto 参数当场用掉。不分配、无 error set；两个 context 头都取不到时返回 `null`（此时 `createArray` 得到 null proto）。唯一调用方 `TaggedTemplateObjectBuilder.init`（`src/parser.zig:6540`）。

### `TaggedTemplateObjectBuilder.init` (`src/parser.zig:6326`)

- **签名**：`fn init(rt: *core.JSRuntime) Error!TaggedTemplateObjectBuilder`。
- **作用**：构造对象并填好默认字段。
- **实现**：
`TaggedTemplateObjectBuilder.init`：在当前 realm 的 `Array.prototype` 下分配 cooked/raw 两个数组，并把 raw 数组以不可枚举/不可写/不可配置的 `raw` 属性挂到 cooked 对象上；后续 `addPart` 填元素，`finish` 才把两个数组 freeze。给标签模板对象用，对象进 cpool，编译期靠 `traceCompileValueRoots` 保活。
- **所有权 / 错误 / 调用**：**本文件里少数直接在 GC 堆上建对象的函数**：两次 `core.Object.createArray(rt, prototype)`（proto 取自 `realmArrayPrototype`，借用，取不到就是 null proto），失败折成 `Error.OutOfMemory`；两条 `errdefer core.Object.destroyFromHeader` 只保护 init 自身的失败路径。成功后所有权随**按值返回**的结构体交给调用方栈帧：从这里到 `Emitter.pushConst` 把 `template_value` 放进 cpool 之前，栈上的 builder 是这两个数组唯一的持有者，靠 `ParseState.traceCompileValueRoots`（`:1095`）注册的 RootProvider 保活（`force_gc_in_window_for_test` 就是压这个窗口的测试缝）。`raw` 属性用的是预定义 atom `atom_module.ids.raw`，`defineOwnProperty` 失败折成 `Error.ParserInvariant`。调用方 2 处，都在 `parseTaggedTemplateInvocation`（`:6031` 无插值、`:6048` 带插值）。

### `TaggedTemplateObjectBuilder.addPart` (`src/parser.zig:6349`)

- **签名**：`fn addPart( self: *TaggedTemplateObjectBuilder, cooked_bytes: []const u8, raw_bytes: []const u8, cooked_invalid: bool, ) Error!void`。
- **作用**：往标签模板对象追加第 `depth` 个元素：cooked 串（`cooked_invalid` 时写 `undefined`）进模板数组，raw 串进 raw 数组，然后 `depth += 1`。
- **实现**：给模板对象追加第 `depth` 个模板段。cooked 侧：`cooked_invalid`（含非法转义序列）时值取 `undefined`，否则 `String.createUtf8(cooked_bytes)`，失败映射成 `Error.InvalidUtf8`；随后 `defineOwnProperty(atomFromUInt32(depth), ...)` 以可写/可枚举/可配置的数据属性写进 `template_object`（定义失败按 `ParserInvariant`）。中间插着测试缝：`is_test` 且 `force_gc_in_window_for_test` 为真时主动 `rt.forceMajorGC(null)`，用来验证「两个数组和本段 cooked/raw 字符串只被栈上的 builder 持有」这段窗口里的 GC 可达性。raw 侧同样 `createUtf8(raw_bytes)` 后按同一下标写进 `raw_array`。最后 `depth += 1`。
- **所有权 / 错误 / 调用**：`self` 是可变借用；新建的 cooked/raw 字符串在 `defineOwnProperty` 成功后由两个数组（即 builder 持有的对象图）接管，本函数不保留额外引用、也没有 errdefer——因为失败时整个 builder 连同两个数组都会被调用方那条路径丢弃，GC 负责回收。错误面：`String.createUtf8` 失败 → `Error.InvalidUtf8`；两次 `defineOwnProperty` 失败 → `Error.ParserInvariant`。`is_test` 下的 `forceMajorGC` 只在 `force_gc_in_window_for_test` 打开时执行，用来证明这段窗口内对象确实可达。调用方 2 处，都在 `parseTaggedTemplateInvocation`（`:6032`、`:6057`）。

### `TaggedTemplateObjectBuilder.finish` (`src/parser.zig:6380`)

- **签名**：`fn finish(self: *TaggedTemplateObjectBuilder) Error!void`。
- **作用**：封口标签模板对象：先 freeze raw 数组，再 freeze 模板对象。
- **实现**：两行：先 `raw_array.freeze(rt)` 再 `template_object.freeze(rt)`，失败一律映射成 `Error.OutOfMemory`。冻结是规范对模板对象的要求（GetTemplateObject 产出的数组及其 `raw` 都是不可变的），冻结之后这对数组才适合放进常量池被多次调用共享。
- **所有权 / 错误 / 调用**：不分配、不转移所有权：只把两个数组对象 `freeze`。两个 `freeze` 的失败都被折成 `Error.OutOfMemory`（`freeze` 自己的错误码不外传）。所有权要点在别处：`init` 建的两个对象在 `Emitter.pushConst` 把 `template_value` 交给 `curFunc().appendCpool`（`src/parser.zig:7597`）之前，唯一持有者就是栈上的 builder 结构——这段窗口靠 `ParseState.traceCompileValueRoots`（`:1095`）注册的 RootProvider 扫描 cpool 保活，`TaggedTemplateObjectBuilder.force_gc_in_window_for_test` 就是为了压这个窗口。`finish` 之后不需要显式销毁，对象归 cpool、随 `FunctionDef` 走完 finalize。调用方是 `parseTaggedTemplateInvocation` 的两条臂（`:6033` 无插值、`:6071` 带插值）。

### `parseArrayLiteral` (`src/parser.zig:6393`)

- **签名**：`fn parseArrayLiteral(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析数组字面量，并按稠密 / 稀疏 / 展开三种形态发出建数组的指令。
- **实现**：消费 `[` 之后在三种发射形态间切换：默认「收集模式」只用 `count` 数元素，结束时一条 `array_from <count>` 建数组。遇到 `,` 空洞——已在 spread 模式就发 `inc` 推进运行下标；否则第一次转 sparse，先把稠密前缀 `array_from <count>` 发掉，之后每个实际元素改用 `define_field "<十进制下标>"`（下标现场 `bufPrint` 再 `internString`，格式化失败折成 `ParserInvariant`）。遇到 `...` 置 `features.spread_rest`，首次转 spread 时补 `array_from <count>` 和 `push_i32 <count>` 作运行下标，元素求值后 `append`；spread 模式下的普通元素是 `define_array_el; inc`。元素一律用 `ParseFlags.default` 解析——方括号里恢复 `in` 运算符（`js_parse_assign_expr`，`quickjs.c:28283`）。收尾 `]` 之后按状态补 `length`：spread 走 `ext0/dup1` + `put_field length`，纯稠密走 `array_from <count>`，sparse 走 `dup; push_i32 <sparse_index>; put_field length`。
- **所有权 / 错误 / 调用**：不建 JS 对象（数组是运行期由 `array_from`/`append` 造的）；唯一的堆动作是 sparse 臂里为十进制下标做的 `bufPrint` + `atoms.internString`，产出的 atom 由本次编译的 `CompileAtomScope` 作根，本函数无 retain/release 义务，`bufPrint` 失败折成 `Error.ParserInvariant`。字节码经 `Emitter.*` 进 `activeBuilder()`，Builder 错误经 `mapBuilderError` 折成 `Error.*`；元素解析的递归会带上 `SyntaxError` / `StackOverflow`。`flags` 参数被 `_ = flags` 丢弃——方括号内一律用 `ParseFlags.default`（恢复 `in`）。树内唯一调用方 `parsePrimary`（`:6404`）。

### `parseObjectLiteral` (`src/parser.zig:6470`)

- **签名**：`fn parseObjectLiteral(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析对象字面量：发 `object` 加逐属性定义，末尾按静态属性数做一次容量窥孔。
- **实现**：消费 `{`，先记下 `object` 这条 opcode 的写入位置再发它（`quickjs.c:24361-24383`）。对象非空就进循环：每轮 `parseObjectProperty` 吃一个属性（普通 / 简写 / 计算键 / 方法 / 访问器 / 展开 / `__proto__` 都在那里分流，`proto_field_seen` 保证只有第一个 `__proto__` 被当成原型设置），遇 `,` 继续并允许尾逗号（`,}` 直接 break）。`expectPunct('}')` 之后做一次窥孔：`capacity_hint.eligible` 且 `unique_count != 0` 时，把开头那条 `object` 就地改写成 `object_slots2`，让运行时按属性数预留槽位。`ObjectLiteralCapacityHint` 只记至多 2 个互不相同的静态属性名，超出或出现计算键等不可数形态就 `invalidate()`，改写随之取消。
- **所有权 / 错误 / 调用**：不建 JS 对象；本函数自己不 intern atom（属性名由 `parseObjectProperty` 处理），`ObjectLiteralCapacityHint` 是栈上的定长结构，不上堆。收尾的窥孔**就地改写 Builder 已发射的字节**：把开头那条 `object` 换成同宽的 `object_slots2`，没有截断也没有重定位搬移，因此不需要快照。错误来自 `parseObjectProperty` 递归（`SyntaxError` / `StackOverflow` / atom intern 的 OOM）与 Builder 经 `mapBuilderError` 的折叠。树内唯一调用方 `parsePrimary`（`:6407`）。

### `ObjectLiteralCapacityHint.invalidate` (`src/parser.zig:6500`)

- **签名**：`fn invalidate(self: *@This()) void`。
- **作用**：宣告当前对象字面量不再适合用「预开槽」的 `object_slots2` 形式建对象。
- **实现**：一行 `self.eligible = false;`。展开、计算属性名、访问器、`__proto__` 等无法在编译期确定静态形状的属性形式都会调它，之后 `noteStaticProperty` 也随即变成 no-op。
- **所有权 / 错误 / 调用**：无：单行置位 `eligible = false`，作用在调用方栈上的 `ObjectLiteralCapacityHint`（定容内联数组，不上堆），不分配、无 error set。调用方：`parseObjectProperty`（`src/parser.zig:6743`/`:6757`/`:6788`/`:6808`）与 `parseObjectAccessorProperty`（`:6887`）——每遇到计算键、getter/setter、spread 等无法静态计数的形态就作废提示。

### `ObjectLiteralCapacityHint.noteStaticProperty` (`src/parser.zig:6504`)

- **签名**：`fn noteStaticProperty(self: *@This(), atom_id: Atom) void`。
- **作用**：登记一个编译期已知的静态属性名，用来判断字面量能否按固定槽数预分配。
- **实现**：`!eligible` 直接返回。先在已记的 `atoms[0..unique_count]` 里线性查重，命中就返回（同名重复定义不增加槽数）。新名字若已经填满 `atoms`（容量 2）则把 `eligible` 置 false 后返回——超过两个唯一静态属性就不再走这条提示路径；否则把 atom 写进数组并 `unique_count += 1`。`parseObjectLiteral` 在收尾时若 `eligible` 且 `unique_count != 0`，就把起始那条 `op.object` 原地改写成 `op.object_slots2`。
- **所有权 / 错误 / 调用**：不分配：把 atom id 记进结构体内联的定长数组（只存 id，无 retain/release 义务，编译期 atom 由 `CompileAtomScope` 作根）；数组满了就自我作废（`eligible = false`）而不是扩容，所以没有 OOM 路径、无 error set。调用方 5 处：`parseObjectProperty`（`src/parser.zig:6768`/`:6799`/`:6855`/`:6860`）与 `parseObjectAccessorProperty`（`:6899`）。

### `parseObjectMethodFunction` (`src/parser.zig:6954`)

- **签名**：`fn parseObjectMethodFunction(s: *State, name: ?Atom, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：以「方法」语义解析并发射一个函数（对象字面量里的方法与访问器）。
- **实现**：一行：`parseFunctionParamsAndBody(s, func_kind, source_start, .{ .name = name, .is_method = true })`。方法语义（home object、`allow_super`、重复参数门、强制作为子函数、`in_generator` / `in_async` 按 kind）全部由 `parseFunctionParamsAndBody` 从 `func_kind` 与 `entry.is_method` 派生进 `FunctionContext`。以前这里名字取参数 `name`、`is_decl = false`（方法是表达式不是声明）、`root_mode = true`、`in_generator` 与 `in_async` 由 `func_kind` 是否为 `.generator` / `.async` / `.async_generator` 推出、`allow_super = true`（方法可以用 `super`）、`parsing_method_params = true`。最后调 `parseFunctionParamsAndBody(s, func_kind, source_start)` 真正解析并发射函数体。
- **所有权 / 错误 / 调用**：自身不发任何字节码、不分配、不再保存任何状态（函数边界的整体保存/恢复在 `parseFunctionParamsAndBody` 里），把活全部交给 `parseFunctionParamsAndBody`——真正的 FunctionDef 分配、子函数发射与错误都在那里。`name` 是可选的借用 atom，只写进 `pending_function_name`，不 retain。调用方 8 处：`parseObjectProperty`（`:6762`/`:6770`/`:6793`/`:6801`/`:6814`/`:6861`）与 `parseObjectAccessorProperty`（`:6892`/`:6901`）。

### `formatBigIntPropertyName` (`src/parser.zig:6998`)

- **签名**：`fn formatBigIntPropertyName(s: *State, text: []const u8) Error![]const u8`。
- **作用**：把 BigInt 字面量形式的属性键（`{ 1n: v }` / `obj[1n]` 的静态形态）规范化成十进制字符串，以便按普通属性名 intern。
- **实现**：与 `emitBigIntLiteral` 的前半段同形：文本含 `_` 时先复制出剔除分隔符的 `normalized` 缓冲（`defer` 里按指针是否变化决定释放），再 `libs_bignum.parseAutoAlloc` 解析（失败映射 `Error.InvalidNumberLiteral`，`defer parsed.deinit()`），最后 `parsed.formatBase10Alloc` 输出十进制字符串（OOM 映射 `Error.OutOfMemory`）。返回的切片由调用方负责释放。
- **所有权 / 错误 / 调用**：**返回的切片是 owned 的**：`parsed.formatBase10Alloc(s.function.memory.allocator)` 在函数自己的内存账上分配，调用方必须释放——唯一调用方 `parseObjectPropertyName`（`:6942`）紧跟着 `defer if (is_bigint) s.function.memory.allocator.free(text)`。中间两笔分配自理：剔除 `_` 的 `normalized` 由 `errdefer` + 按指针比较的 `defer free` 收尾，`parsed` 由 `defer parsed.deinit()` 收尾。错误面：`Error.OutOfMemory`（两处分配）与 `Error.InvalidNumberLiteral`（`parseAutoAlloc` 失败）。不发字节码、不 intern atom（intern 由调用方做）。

### `compoundAssignOpcode` (`src/parser.zig:7020`)

- **签名**：`fn compoundAssignOpcode(k: tok.TokenKind) ?u8`。
- **作用**：把复合赋值 token（`*=` `/=` `%=` `+=` `-=` `<<=` `>>=` `>>>=` `&=` `^=` `|=` `**=`）映射成对应二元 opcode，不是复合赋值就返回 null。
- **实现**：一张 token→opcode 的 `switch` 表：`*=` `/=` `%=` `+=` `-=` `<<=` `>>=` `>>>=` `&=` `^=` `|=` `**=` 分别映射到 `mul` `div` `mod` `add` `sub` `shl` `sar` `shr` `and` `xor` `or` `pow`；`else` 返回 `null`，于是普通 `=` 和一切非赋值 token 都落空。
- **所有权 / 错误 / 调用**：无：token → opcode 的纯查表 switch，不碰 `State`、不分配、无 error set，不认识的 token 返回 `null`。唯一调用方 `parseAssignExpr2`（`src/parser.zig:4057`）。

### `logicalAssignKind` (`src/parser.zig:7038`)

- **签名**：`fn logicalAssignKind(k: tok.TokenKind) ?LogicalAssignKind`。
- **作用**：把 `&&=` / `||=` / `??=` 三个 token 映射成 `LogicalAssignKind`（`.land` / `.lor` / `.nullish`），其余返回 null。
- **实现**：三项 `switch`：`&&=` → `.land`、`||=` → `.lor`、`??=` → `.nullish`，其余返回 `null`。调用方据此决定是否走 `parseLogicalAssignment` 的短路发射而不是普通复合赋值。
- **所有权 / 错误 / 调用**：无：三条臂的纯查表 switch，不分配、无 error set。唯一调用方 `parseAssignExpr2`（`src/parser.zig:4058`），与 `compoundAssignOpcode` 在同一行区分复合赋值与逻辑赋值。

### `matchBinaryOp` (`src/parser.zig:7048`)

- **签名**：`fn matchBinaryOp(k: tok.TokenKind, level: u32, flags: ParseFlags) u8`。
- **作用**：按优先级层号把当前 token 翻成二元 opcode，不属于该层就返回 `opcode.op.invalid`。
- **实现**：对照 qjs 的 token→opcode 分层表（`quickjs.c:27083..27201`）。函数体是两级 switch（先 `level` 1-8、再 token）：1=`*` `/` `%`，2=`+` `-`，3=移位，4=关系与 `instanceof`/`in`（`in` 还要 `flags.in_accepted`），5=相等族，6=`&`，7=`^`，8=`|`；其余层一律 `invalid`。
- **所有权 / 错误 / 调用**：无：按优先级层的纯查表 switch，不分配、无 error set；不匹配时返回 `opcode.op.invalid` 这个哨兵（不是错误）。唯一调用方 `parseExprBinary`（`src/parser.zig:4779`）的层循环。

### `parseBigIntI32` (`src/parser.zig:7111`)

- **签名**：`fn parseBigIntI32(text: []const u8, negate: bool) ?i32`。
- **作用**：把 BigInt 字面量文本按 i64 解析并按 `negate` 取反，落在 i32 范围内就返回该值（给 `push_bigint_i32` 用），否则返回 null 走堆 BigInt 路径。
- **实现**：`core.value_format.parseAsciiInt(i64, text, 0)` 按前缀自动识别进制解析成 `i64`（失败返回 `null`）；`negate` 时取负；结果越出 `i32` 范围返回 `null`，否则 `@intCast` 回 `i32`。`emitBigIntLiteral` 用它判定能否走 `push_bigint_i32` 快路径。注意它不处理数字分隔符 `_`，含 `_` 的文本会在 `parseAsciiInt` 处失败并回落到慢路径。
- **所有权 / 错误 / 调用**：**纯函数**：不接受 `*State`、不分配、无副作用、无 error set——不认识或超范围时返回 `null` 而不是错误。返回的是按值的 `?i32`，无所有权义务。树内唯一调用方 `emitBigIntLiteral`（`:3485`），用它决定走 `push_bigint_i32` 立即数快路径还是堆 BigInt 慢路径。

### `Emitter`（`src/parser.zig`，2026-09-19 合并后的唯一发射门面）

- **形态**：`*State` 上的函数命名空间（`Emitter.<verb>(s, ...)`），不是值类型——带接收者的 struct 会在 Debug 下为每个调用点物化一份临时量，足以撑爆 64 KiB 原生栈。旧的 `emitter*` 自由函数家族与 `Label` / `PhysLabel` 栈上容器已折进来：标签一律是裸 `compiler.LabelId`。
- **错误**：所有动词把 `compiler.builder.Error` 经 `mapBuilderError` 折成 parser 的 `Error`；`InvalidBytecode`（重复绑定、外来标签）走 `ParserInvariant`。
- **source 事件**：grammar 站点自己发标记（`emitGrammarSource` / `addSourceMarker`）；`NoSource` 拼写与无后缀版本是同一条路径，只记录「qjs 在此处不发 source 事件」这一意图。
- **标签动词**：`newLabel` 分配；`jump` / `jumpNoSource` 发跳转；`bind` 绑定并作废 last-opcode（控制流汇合，qjs `emit_label`）；`bindRaw` 绑定但保留 last-opcode 作为 call/delete 的 provenance（qjs `emit_label_raw`）；`bindParser` / `bindParserRaw` 是物理标签家族，保留 Stage-4 match barrier，会以 `OP_label` 存活到流里；`retargetLabel` 把待决跳转改指向别处已绑定的边界，不发指令也不作废 last-opcode（qjs `patchJumpTarget`）。
- **指令动词**：`op`（`noinline`，最热的一条，每一份内联副本都是机器码）、`opAt`（先发显式 source 标记再发指令）、`opU8` / `opU8NoSource`（后者是冷平面载体 opcode + 子字节，不记源）、`opU16`（`noinline`）/ `opU16NoSource` / `opU16At`（快照 + 标记 + 指令为一个回滚事务）、`callOp`（`argc:u16` + cache 字节，不记源：qjs 把调用的唯一 source 事件钉在被调用者上）、`opU32` / `opU32NoSource`、`opI32`（qjs 把有符号字面量直接跟在 `OP_push_i32` 后，quickjs.c:26847-26853）、`opAtom` / `opAtomNoSource` / `opAtomU8` / `opAtomU16` / `opAtomU16NoSource`、`scopeRefOp`（qjs get_lvalue 的 `OP_scope_make_ref`）。
- **常量**：`pushConst`（`noinline`）先发占位指令再追加常量并回填 cpool 下标，保持 qjs `emit_push_const` 顺序（quickjs.c:23974-24004）；cpool 增长失败时 Builder 回滚把指令一并撤掉。
- **段操作**：`detachTail` / `spliceSegment` 是 Builder 段机制的门面；`discardDetachedSources` 丢弃被搬走代码的 parser source 槽（class runtime 与 for-update 块都用这份契约）。
- **保留的属性**：`op` / `opU16` / `pushConst` 保持 `noinline`，`opNoSource` / `opU16NoSource` / `opAt` / `opAtomU16` 保持 `inline`，与体积战役当年的取舍一致。


### `mapBuilderError` (`src/parser.zig:7232`)

- **签名**：`fn mapBuilderError(err: compiler.builder.Error) Error`。
- **作用**：把 `compiler.builder.Error` 翻成 parser 的 `Error`。
- **实现**：三项 `switch`：`error.OutOfMemory` → `Error.OutOfMemory`，`error.BytecodeOverflow` → `Error.BytecodeOverflow`，`error.InvalidBytecode` → `Error.ParserInvariant`。最后一条把 Builder 的 fail-closed 不变量（重复绑定、外来 label）并进 parser 自己那套内部不变量错误，和其它 parser fail-closed 检查同一个出口。
- **所有权 / 错误 / 调用**：不分配也不发射；各 `emitter*` 包装用它把 Builder 错误转成解析错误。

### `emitGrammarSource` (`src/parser.zig:7298`)

- **签名**：`fn emitGrammarSource(s: *State, source: SourcePosition) Error!void`。
- **作用**：语法站点发一次源位置事件；parser 里只有这条路允许主动写 source marker。
- **实现**：把 `SourcePosition` 拆成 `line_num` / `col_num` 交给 `Emitter.addSourceMarker`（进而是带去重的 `builderAddSourceMarker`）。对应 qjs `emit_source_pos()`：普通 emitter 一律不推断位置，只有语法站点知道该把行号钉在哪个 token 上。
- **所有权 / 错误 / 调用**：不分配（字节码 / reloc / atom 台账的增长都在 Builder 的 `fd.memory` 账上）；这一层的全部作用是把 `compiler.builder.Error` 经 `mapBuilderError`（`:7448`）换成 parser 的 `Error`（`OutOfMemory` / `BytecodeOverflow` 原样过，fail-closed 的 `InvalidBytecode` → `Error.ParserInvariant` 走 ICE 出口）。它不受 `rollbackEmission` 管——那条回滚的是 phase-1 raw 字节流；这里的事务性由调用方自己的 `v2b.snapshot()` / `rollback` 提供。语义上的约束比技术上的强：**只有语法产生式**可以调它（对应 qjs `emit_source_pos()`），普通发射动词绝不推断位置。树内 21 处调用，全在各 parse* 产生式里。

### `expressionStatementKeepsCompletion` (`src/parser.zig:7596`)

- **签名**：`fn expressionStatementKeepsCompletion(s: *const State) bool`。
- **作用**：谓词：表达式语句要不要保留 completion value（写进 eval 结果槽）。
- **实现**：一个与式：`s.eval_ret_idx >= 0 and !s.lex.is_module`。前一半说明当前编译有一个承接 completion value 的局部槽（eval / 间接 eval 的返回值槽），后一半排除模块——模块没有 completion value 语义。为真时表达式语句要把值存进 `eval_ret_idx` 而不是直接 `drop`。
- **所有权 / 错误 / 调用**：无：`*const State` 两个字段的与运算，不分配、无 error set、无副作用。7 处调用方，全是「这条语句要不要写 `<ret>` 完成值」的判定点：`parseDirectives`（`src/parser.zig:8593`）、`parseStringStatement`（`:9033`）、`parseIdentifierStatement`（`:9157`/`:9178`/`:9195`）等。

### `caseTailCanFallthrough` (`src/parser.zig:7621`)

- **签名**：`fn caseTailCanFallthrough(s: *State, scan_start: u32, body_start: u32) bool`。
- **作用**：判断一个 `switch` case 体的末尾是否还可能继续往下走（决定要不要给它补一条跳到 switch 出口的尾跳）。
- **实现**：取 Builder，从 `body_start`（若 `code_len` 还没到 `body_start` 则从 `scan_start`）起按 `opcode.sizeOfPhase1` 逐条前扫到 `code_len`，记下最后一条 opcode；扫完断言 `pc == code_len`（必须停在指令边界）。一条都没有（`last == null`）返回 true。然后看这条 opcode 是不是五个终结码之一——`goto` / `return` / `return_undef` / `return_async` / `throw`——不是就返回 true。是终结码时还要看有没有入边：遍历 label 槽，只要有一个「已绑定、`bound_offset == code_len`、`ref_count > 0`」的 label 就返回 true，否则 false。doc 注释解释了为何不能直接用 `caseCanFallthrough`：后者读 `flowSummary().last_non_line_op` 是**整条流**的属性，什么都没发射的 case 体（比如空 `default`）会拿到前一个子句的尾 goto 当答案；从 switch 自己的首次发射位置扫起可以复现整流答案又不用 O(code_len) 走全程。入边规则与 `isLiveCode` / qjs `js_is_live_code`（quickjs.c:23816）相同，因为 v2 的 label 绑定不产生字节，否则 while 族的回边 `goto` 会被误判成「走不下去」。注释还叮嘱：这里必须保持这 5 个终结码，不要复用 `isLiveCode` 更宽的那一组。
- **所有权 / 错误 / 调用**：无：只读 `activeBuilder()` 的 `code` 与 `label_slots`，不分配、不改写、无 error set；`sizeOfPhase1` 返回 0（未知 opcode）时靠 `assert` 而不是错误返回，Release 下会当成走到尾。两个调用方都在 `parseSwitchStatement`（`src/parser.zig:9650`/`:9697`），用来决定 case 尾部要不要补跳转。

### `isLiveCode` (`src/parser.zig:7662`)

- **签名**：`pub fn isLiveCode(s: *State) bool`。
- **作用**：谓词：当前发射位置还可不可达——决定要不要补隐式 `return undefined` 之类的收尾码。
- **实现**：两段判断。先看 provenance：`last_opcode_pos < 0`（还没发指令，或刚被 `Emitter.bind` 抹掉）算活；否则看最后一条 opcode 是不是终结码——`goto` / `return` / `return_undef` / `return_async` / `tail_call` / `tail_call_method` / `throw` / `throw_error` / `ret` 判死，其余判活（qjs `get_prev_opcode`，`quickjs.c:23816`）。判死之后再扫一遍 label 表找入边：只有「已绑定 **且** 绑定偏移正好等于当前 `code_len` **且** `ref_count > 0`」的 label 才算一条到达此处的边，这补上了 `Emitter.bindRaw` 那种保留 provenance 的绑定（对应 legacy 的 `max_absolute_target >= tail_start`）；尚未绑定的 label 是将来的 handler / 出口目标，不算入边。
- **所有权 / 错误 / 调用**：无：只读 Builder 的 `last_opcode_pos`/`code`/`label_slots`，不分配、无 error set。它是 `parser_core` 少数几个 `pub` 出去的判定之一：树内 6 处调用方——`parseTryStatement`（`src/parser.zig:9785`/`:9862`）、`parseFunctionParamsAndBody`（`:11982`）、`parseArrowFunction`（`:12484`）、测试钩子 `emitPlainTailForTest`（`:8015`），以及 namespace 外的 `compileQjsProgram`（`:16301`，决定程序末尾补不补 `return_undef`）。

### `emitPlainTailForTest` (`src/parser.zig:7692`)

- **签名**：`pub fn emitPlainTailForTest(s: *State) Error!void`。
- **作用**：测试钩子：按脚本 / 普通函数尾声的原样跑一遍「判活 + 补 return undefined」。
- **实现**：两行：`if (isLiveCode(s)) try s.emitReturnUndefined();`。这是脚本 / 普通函数尾声在 v2 下的「判断 + 终结指令」组合，测试用的发射 harness 可以照脚本尾声的原样调用它。
- **所有权 / 错误 / 调用**：不自己发指令：`isLiveCode` 为真时转 `s.emitReturnUndefined()`，所有分配与错误都在后者（经 Builder，`mapBuilderError` 折成 `Error.*`）。**生产零调用方**：只有 `src/compiler/tests.zig` 的四处（`:1678`/`:1701`/`:1723`/`:1757`）——函数名里的 `ForTest` 就是这个意思，它把「脚本/普通函数尾声」的判活+补 `return undefined` 组合暴露给发射 harness。

### `patchContinueFrame` (`src/parser.zig:7696`)

- **签名**：`fn patchContinueFrame(s: *State) Error!void`。
- **作用**：把当前循环的 `continue` 目标标签绑在此处（循环的更新/条件段入口）。
- **实现**：`continue_frame_labels` 为空即 `Error.ParserInvariant`；否则取栈顶 `getLast()` 调 `Emitter.bind` 绑定。注意只绑不弹——弹栈在 `popBreakFrameAndPatch` 里做。
- **所有权 / 错误 / 调用**：不分配：只从 `s.continue_frame_labels` 栈顶取一个 `LabelId` 交给 `Emitter.bind` 绑在当前位置，**只绑不弹**（弹栈由 `popBreakFrameAndPatch` 做）。栈为空即 `Error.ParserInvariant`（内部不变量，ICE 出口）；其余失败来自 Builder 经 `mapBuilderError` 的折叠（重复绑定同样是 `ParserInvariant`）。调用方是各循环构造的「更新/条件段入口」。

### `popBreakFrameAndPatch` (`src/parser.zig:7701`)

- **签名**：`fn popBreakFrameAndPatch(s: *State) Error!void`。
- **作用**：弹出一整套 break/continue 帧（循环、switch 用的那种既有 break 又有 continue 的帧），并把 `break` 标签绑在当前位置。
- **实现**：先查 `break_frame_lens` 与 `continue_frame_lens` 非空，否则 `ParserInvariant`。然后成对弹出 continue 侧四个并行栈（`continue_frame_lens` / `continue_frame_break_frame_indices` / `continue_frame_catch_marker_depths` / `continue_frame_cleanup_drops`）与 break 侧四个（`break_frame_lens` 取出 `start`、`break_frame_catch_marker_depths` / `break_frame_cleanup_drops` / `break_frame_cross_cleanup_drops`）。continue 标签只弹不绑（它已由 `patchContinueFrame` 绑过），break 标签弹出后 `Emitter.bind` 绑在当前位置。收尾断言 `break_fixups.items.len == start`，确认这一帧的 fixup 都已消费干净。
- **所有权 / 错误 / 调用**：只弹不释放：十个并行栈（continue 侧五个 + break 侧五个，各含一个 label 栈）都是 `ArrayList`，`pop` 只改长度，底层缓冲留给下一个循环复用，真正的释放在 `State.deinit`。两个长度栈任一为空即 `Error.ParserInvariant`，两个 label 栈弹空同样是 `pop() orelse return Error.ParserInvariant`。break 标签弹出后 `Emitter.bind` 绑在当前位置（continue 标签只弹不绑——它已由 `patchContinueFrame` 绑过）。收尾的 `break_fixups.items.len == start` 是 `assert`（Debug panic），不是可恢复错误。

### `popBreakOnlyFrameAndPatch` (`src/parser.zig:7718`)

- **签名**：`fn popBreakOnlyFrameAndPatch(s: *State) Error!void`。
- **作用**：弹出只有 `break` 没有 `continue` 的那种帧（带标签的语句块、`switch` 的 break 边界），并把 break 标签绑在当前位置。
- **实现**：`break_frame_lens` 为空即 `ParserInvariant`。弹出 `break_frame_lens`（取 `start`）、`break_frame_catch_marker_depths`、`break_frame_cleanup_drops`、`break_frame_cross_cleanup_drops` 四个并行栈，再弹出 break 标签并 `Emitter.bind` 绑定，最后断言 `break_fixups.items.len == start`。与 `popBreakFrameAndPatch` 的差别就是完全不碰 continue 侧的栈。
- **所有权 / 错误 / 调用**：与 `popBreakFrameAndPatch` 同构，只是完全不碰 continue 侧的四个栈：弹 `break_frame_lens` / `break_frame_catch_marker_depths` / `break_frame_cleanup_drops` / `break_frame_cross_cleanup_drops` 四个栈，再从 `break_frame_labels` 弹出标签（弹空即 `Error.ParserInvariant`）并 `Emitter.bind` 绑在当前位置。只弹不释放（缓冲归 `State.deinit`）。`break_frame_lens` 为空即 `Error.ParserInvariant`；末尾的 fixup 数核对是 `assert`。用于带标签块与 `switch` 这类只有 break 边界的构造。

### `emitCreateUsingDisposableStack` (`src/parser.zig:7972`)

- **签名**：`fn emitCreateUsingDisposableStack(s: *State) Error!u16`。
- **作用**：为 `using` 声明建一个 disposable stack 存进匿名临时局部槽，返回槽号。
- **实现**：三步：`appendAnonymousTempLocal` 要一个匿名临时局部槽，发 `ext0` 子码 `create` 造出 disposable stack，再 `put_loc stack_loc` 存进该槽，返回槽号。这是 zjs 自有的 explicit resource management（`using` 声明）lowering，逐条对齐 legacy 的建栈 + 存局部序列。
- **所有权 / 错误 / 调用**：会在当前 `FunctionDef` 上**留下一个永久副作用**：`appendAnonymousTempLocal`（`src/parser.zig:13553`）给 `fd.vars` 追加一行匿名局部（`growSliceBy(fd.memory)`，OOM 的主要来源），返回的槽号归 FunctionDef，本函数不负责回收——发射失败时靠调用方的语句级回滚/`State.deinit` 清理。之后两条 `Emitter` 写入 Builder，错误经 `mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。唯一调用方 `armCurrentUsingBlockFrame`（`:8454`）。

### `emitUsingAwait` (`src/parser.zig:7981`)

- **签名**：`fn emitUsingAwait(s: *State) Error!void`。
- **作用**：为 `await using` 发 `await`，并顺带做模块顶层 await 记账与上下文校验。
- **实现**：先记账再校验再发射：模块顶层（`lex.is_module` 且 `cur_func_stack.len == 0`）时把 `function.ensureModule().has_top_level_await` 置真；既不在 async 函数内、又不是模块顶层，返回 `Error.AwaitOutsideAsyncFunction`；通过后发普通的 `Emitter.op(op.await)`——`await using` 的等待复用的就是普通 await 指令。
- **所有权 / 错误 / 调用**：不分配，但有副作用：模块顶层时 `s.function.ensureModule().has_top_level_await = true`（写的是 root `Bytecode` 自己的 module 记录，所有权不变）。本函数**自己产 SyntaxError**：非 async 且非模块顶层时直接 `return Error.AwaitOutsideAsyncFunction`，该错误由 `compile` 收成 `Result.syntax_error`（`setFallbackSyntaxError` 用 `@errorName`）再在 `exec/eval_entry.zig:127` 抛成 JS SyntaxError；其余失败来自 Builder（`mapBuilderError`）。唯一调用方 `emitUsingAwaitIfNeeded`（`src/parser.zig:8426`）。

### `emitUsingAddResource` (`src/parser.zig:7989`)

- **签名**：`fn emitUsingAddResource(s: *State, kind: DisposalHint, stack_loc: u16, resource_loc: u16) Error!void`。
- **作用**：把一个资源登记进 disposable stack，同步 / async 处置由子码区分。
- **实现**：三条指令，操作数顺序与 legacy 一致：`get_loc stack_loc` 压 disposable stack、`get_loc resource_loc` 压资源，再发 `ext0` 子码 `add(@intFromEnum(kind))`——处置提示（同步 / async）编进子码里，由运行时决定登记 `[Symbol.dispose]` 还是 `[Symbol.asyncDispose]`。
- **所有权 / 错误 / 调用**：不分配、不持有任何东西：三条 `Emitter` 调用写 Builder，两个局部槽号是调用方传进来的借用值。失败只来自 Builder，经 `mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。两个调用方：`parseUsingDeclaration`（`src/parser.zig:9969`）与 `parseForInOf`（`:11018`）。

### `emitUsingAwaitIfNeeded` (`src/parser.zig:7997`)

- **签名**：`fn emitUsingAwaitIfNeeded(s: *State, may_be_async: bool) Error!void`。
- **作用**：可能是 async 处置时，插一段「处置结果非 `undefined` 才 await」的判定。
- **实现**：`may_be_async` 为假直接返回。否则发一段运行时判定：`dup` 复制栈顶结果、`ext0` 子码 `is_undefined` 判它是不是 `undefined`，新建 `skip_await` 标签并 `if_true` 跳过；不跳过就 `emitUsingAwait`（含模块顶层 await 记账与 async 上下文校验），最后 `bind(skip_await)`。也就是说只有处置函数真的返回了东西才 await。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`（这条路径不归 `rollbackEmission` 管）。`may_be_async` 为假时是彻底的 no-op（一条指令都不发）。`skip_await` 是栈上的 `Label` 容器，`id` 只是 Builder 内索引，无释放义务。可能透传 `emitUsingAwait` 的 `Error.AwaitOutsideAsyncFunction`。调用方 2 处：`emitUsingDisposeStack`（`:8435`）与 `emitUsingDisposeStackForThrow`（`:8445`）。

### `emitUsingDisposeStack` (`src/parser.zig:8010`)

- **签名**：`fn emitUsingDisposeStack(s: *State, stack_loc: u16, may_be_async: bool) Error!void`。
- **作用**：正常完成路径上触发 disposable stack 的逆序处置。
- **实现**：正常完成路径的处置序列，逐条对齐 legacy：`get_loc stack_loc` 取回 disposable stack，`ext0` 子码 `dispose` 触发逆序处置，`emitUsingAwaitIfNeeded(may_be_async)` 视情况 await 其结果，最后 `drop` 丢掉留在栈上的结果值。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`（这条路径不归 `rollbackEmission` 管）。`stack_loc` 是调用方传进来的借用槽号，本函数不分配槽也不回收它。可能透传 `emitUsingAwaitIfNeeded` → `emitUsingAwait` 的 `Error.AwaitOutsideAsyncFunction`。调用方 2 处：`emitUsingDisposesForCatchMarkerDepth`（`:7887`）与 `finalizeCurrentUsingBlockFrame`（`:8492`）。

### `emitUsingDisposeStackForThrow` (`src/parser.zig:8019`)

- **签名**：`fn emitUsingDisposeStackForThrow(s: *State, stack_loc: u16, may_be_async: bool) Error!void`。
- **作用**：异常完成路径上的处置：先把被抛出的值垫到 stack 之下，再走 `dispose_throw`。
- **实现**：异常完成路径的处置序列：`get_loc stack_loc` 取栈后先 `swap`，把被抛出的值压到 disposable stack 之下保住（后续的 SuppressedError 合成要用它），再发 `ext0` 子码 `dispose_throw`，然后 `emitUsingAwaitIfNeeded(may_be_async)`，最后 `drop`。与正常路径的差别就在那条 `swap` 和 `dispose_throw` 子码。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 的错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`（这条路径不归 `rollbackEmission` 管）。与 `emitUsingDisposeStack` 的差别只在多一条 `swap`（把抛出的值垫在 disposable stack 之下）与子码换成 `dispose_throw`。`stack_loc` 借用。树内唯一调用方 `finalizeCurrentUsingBlockFrame`（`:8497`）。

### `armCurrentUsingBlockFrame` (`src/parser.zig:8029`)

- **签名**：`fn armCurrentUsingBlockFrame(s: *State) Error!u16`。
- **作用**：在块里第一次遇到 `using` 资源时，给当前 using 块帧真正装上 disposable stack 与合成 catch 边（幂等）。
- **实现**：`using_block_frames` 为空即 `error.ParserInvariant`。取栈顶帧，若 `stack_loc` 已有就直接返回它（同一个块里的第二个资源不重复装配）。否则 `emitCreateUsingDisposableStack` 建栈拿槽号，`Emitter.newLabel` 新建 catch 标签并 `Emitter.jump(op.catch, catch_label)` 发出合成 catch 边（identity-native，直到最终布局前都不落成绝对地址），`active_catch_marker_depth += 1`，然后把 `{ stack_loc, catch_label, catch_marker_depth }` 整体写回帧，返回槽号。
- **所有权 / 错误 / 调用**：**幂等**：栈顶帧已经有 `stack_loc` 就直接返回它，不重复建栈。首次武装时有两处持久副作用：`emitCreateUsingDisposableStack` 在 `fd.vars` 上追加一个匿名临时局部（归 FunctionDef，本函数不回收），以及 `s.active_catch_marker_depth += 1` 并把 `{stack_loc, catch_label, catch_marker_depth}` 回写进 `using_block_frames` 栈顶——这个深度必须由 `finalizeCurrentUsingBlockFrame` 配对递减，失败路径则靠 `restoreUsingBlockFramesAfterError` 恢复。`using_block_frames` 为空即 `error.ParserInvariant`；其余失败来自 Builder 经 `mapBuilderError` 的折叠。调用方 2 处：`parseUsingDeclaration`（`:9958`）与 `parseForInOf`（`:11005`）。

### `noteUsingResourceHint` (`src/parser.zig:8049`)

- **签名**：`fn noteUsingResourceHint(s: *State, hint: DisposalHint) Error!void`。
- **作用**：把本块里出现过 `await using` 这件事记在当前 using 块帧上，供收尾时决定处置序列要不要带 await。
- **实现**：`using_block_frames` 为空即 `Error.ParserInvariant`；`hint == .async` 时把栈顶帧的 `seen_async_hint` 置真，同步提示不做任何事。`finalizeCurrentUsingBlockFrame` 把这个标志作为 `may_be_async` 传给两条处置序列。
- **所有权 / 错误 / 调用**：不分配、不发射：只在 `using_block_frames` 栈顶置一个 `bool`。唯一的错误是栈为空时的 `Error.ParserInvariant`——内部不变量，经 `isInternalCompilerError`（`src/parser.zig:16352`）走 ICE 出口而不是 SyntaxError。两个调用方紧跟在 `emitUsingAddResource` 之后：`parseUsingDeclaration`（`:9970`）、`parseForInOf`（`:11019`）。

### `finalizeCurrentUsingBlockFrame` (`src/parser.zig:8056`)

- **签名**：`fn finalizeCurrentUsingBlockFrame(s: *State) Error!void`。
- **作用**：块结束时收掉当前 using 帧：发出正常完成与异常完成两条处置路径，并把帧弹栈。
- **实现**：`using_block_frames` 为空即 `ParserInvariant`。取栈顶帧；若 `stack_loc` 为空（这个块里根本没有 `using` 资源），直接弹栈返回。否则先校验 catch 标记深度对得上（`frame.catch_marker_depth != active_catch_marker_depth` 或深度为 0 都是 `ParserInvariant`），然后 `active_catch_marker_depth -= 1`。正常路径：`drop` 丢掉 catch 标记、`emitUsingDisposeStack(stack_loc, frame.seen_async_hint)`、`emitCloseLoc(stack_loc)` 关闭该临时槽，新建 `end_label` 并 `goto end_label`。异常路径：绑 `catch_label`，发 `emitUsingDisposeStackForThrow(...)`。两路在 `end_label` 汇合后弹栈。整段用真实的 catch/end LabelId 表达汇合，不落绝对地址。
- **所有权 / 错误 / 调用**：栈顶帧没有 `stack_loc`（从未武装过）时只 `pop` 就返回，不发任何指令。正常路径**消费**这一帧：先 `s.active_catch_marker_depth -= 1`（与 `armCurrentUsingBlockFrame` 的递增配对，深度对不上或已为 0 即 `Error.ParserInvariant`），发完正常/异常两条处置臂后 `_ = s.using_block_frames.pop()`——注意 pop 在函数末尾，中途发射失败时帧仍留在栈上，由调用方的 `restoreUsingBlockFramesAfterError` 收拾。`pop` 不释放底层缓冲。`frame.catch_label` 为空同样是 `ParserInvariant`；其余失败来自 Builder 经 `mapBuilderError` 的折叠。调用方 4 处：`parseProgramStatements`（`:8517`）、`parseBlockContentsAfterOpen`（`:8543`）、`parseForStatement`（`:9514`）、`parseForInOf`（`:11027`）。

### `restoreUsingBlockFramesAfterError` (`src/parser.zig:8082`)

- **签名**：`fn restoreUsingBlockFramesAfterError(s: *State, frame_len: usize, catch_marker_depth: u32) void`。
- **作用**：解析出错回退时把 `using_block_frames` 弹回 `frame_len`，并把 `active_catch_marker_depth` 复位成 `catch_marker_depth`。
- **实现**：两步、无返回值、不发指令：`while` 把 `using_block_frames` 弹回到 `frame_len`，再把 `active_catch_marker_depth` 写回传入的 `catch_marker_depth`。挂在 `parseProgramStatements` 一类的 `errdefer` 上，保证解析失败后帧栈与 catch 深度不残留。
- **所有权 / 错误 / 调用**：只 `pop` 到给定长度并恢复 `active_catch_marker_depth`；`using_block_frames` 是 `std.ArrayList`，`pop` 不释放底层缓冲（缓冲在 `State.deinit` 里统一 `deinit`），帧本身是平凡值、无内嵌所有权。不分配、无 error set。四个调用方全是错误路径：`parseProgramStatements`（`src/parser.zig:8513`）与 `parseBlockContentsAfterOpen`（`:8538`）的 `errdefer`，以及 `parseForStatement`（`:9371`）、`parseForInOf`（`:10999`）里显式的失败清理。

### `emitReturnValue` (`src/parser.zig:9723`)

- **签名**：`fn emitReturnValue(s: *State, await_before_unwind: bool) Error!void`。
- **作用**：返回值已在栈顶时，发出穿越 finally 帧、迭代器记录与 catch 标记的完整 return 清理链。
- **实现**：值已在栈顶时发出完整的 return 清理链。①`await_before_unwind` 为真先发 `op.await`——异步生成器的显式返回值要在展开之前 await（qjs `emit_return`，quickjs.c:28401-28405）。②用两个可变游标 `block_cursor = s.top_break`、`catch_marker_depth = s.active_catch_marker_depth` 从内到外遍历 `return_finally_frames`（倒序）：每一帧先 `emitBlockEnvReturnCleanupUntil` 把迭代器记录展开到该帧的 `block_boundary`，再 `emitStackTopCatchMarkerDropsToDepth` 把 catch 标记降到该帧深度，最后用 `Emitter.jumpNoSource(op.gosub, frame.finally_label)` 发一条 `gosub`，逐个执行跨过的 finally（quickjs.c:28447-28449）。③帧走完后再做一次到底的清理：`emitBlockEnvReturnCleanupUntil(..., null, ...)` 与 `emitStackTopCatchMarkerDropsToDepth(..., 0)`。④`emitFunctionReturn(s, true)` 收尾。可变游标的作用是保证每个迭代器 / catch 记录只展开一次，而所有活跃的 finalizer 共用同一个 gosub 目标。
- **所有权 / 错误 / 调用**：不分配：只读 `s.return_finally_frames` / `s.top_break` 两个栈并逐层发清理码，不弹栈也不改帧（`block_cursor` 与 `catch_marker_depth` 是栈上的游标副本，按指针传给两个 helper 更新）。`FinallyLabel` 今天就是一个 `compiler.LabelId`（原先那条从未被构造的 phase-1 raw `.temp` 臂已删）。错误来自被调的清理 helper 与 Builder 经 `mapBuilderError` 的折叠。调用方 3 处：`parseUnary`（`:4958`，`yield` 的 return 完成）、`emitYieldStarDelegation`（`:5069`）、`emitParsedReturn`（`:10288`）。

### `restoreSourceLoc` (`src/parser.zig:9753`)

- **签名**：`fn restoreSourceLoc(s: *State, updated: UpdatedSourceLoc) void`。
- **作用**：把 `reattributeReturnTailCallSource` 改写过的那一个 source 槽原样写回（尾调用归因没有落成时的撤销）。
- **实现**：取 `activeBuilder()`，断言 `updated.index < source_len` 后把保存的 `SourceSlot` 写回 `builder.source_slots[updated.index]`。只改这一个槽，不动长度。
- **所有权 / 错误 / 调用**：不分配、无 error set：把保存下来的 `SourceSlot` 原样写回 `Builder.source_slots[index]`。`UpdatedSourceLoc` 现在是一个普通 struct——原先的 `.temp` 臂在树内从未被构造（唯一生产者 `reattributeReturnTailCallSource` 只产 builder 形态），已随 phase-1 原始字节后端一并删除。唯一调用方 `parseReturnStatement` 的 `errdefer`。

### `reattributeReturnTailCallSource` (`src/parser.zig:9759`)

- **签名**：`fn reattributeReturnTailCallSource(s: *State, has_expr: bool, source: SourcePosition) Error!?UpdatedSourceLoc`。
- **作用**：把 `return f(...)` 里那条调用指令的 source 位置改归到 `return` 关键字上（qjs 在 `resolve_labels` 里对 `call; OP_line_num; return` 做的同一件事），并返回可撤销的旧值。
- **实现**：先是一串前置否决，任何一条成立都返回 `null`（不做归因）：没有返回表达式、当前在 async / generator、在派生类构造器里；或者 `return_finally_frames` / `finally_body_control_frames` 非空、`top_break != null`、`active_catch_marker_depth != 0`——也就是只要 return 还要穿过清理链就不改。随后取 Builder，`last_opcode_pos < 0` 返回 `null`，`pc >= code_len` 是 `ParserInvariant`，最后一条 opcode 不是 `op.call` / `op.call_method` 也返回 `null`。命中后从 `source_len` 倒着找 `temp_offset == pc` 的 marker：找到就把它的 `line` / `col` 改成 `return` 关键字的位置，并返回 `.builder = .{ index, previous }` 供 `restoreSourceLoc` 撤销；遇到 `temp_offset < pc` 就停止查找。没有这样的 marker 时（QuickJS 的裸模板 concat 路径会发一条前面没有 source 事件的 `OP_call_method`，`js_parse_template`，quickjs.c:24573）补一条等价事件：先确认末尾 marker 的 `temp_offset` 不大于 `pc`（否则 `ParserInvariant`），`builder.addSourceMarker(...)` 追加后把新槽的 `temp_offset` 直接改成 `pc`，这条路径返回 `null`（新增的 marker 不需要撤销）。
- **所有权 / 错误 / 调用**：不分配长期对象；两条写路径都作用在 `activeBuilder().source_slots` 上：命中已有 marker 就就地改 line/col 并把**旧值**装进返回的 `UpdatedSourceLoc`（供 `restoreSourceLoc` 在错误时回滚，返回值是纯值不是借用），没有 marker 就 `addSourceMarker` 新增一行（那行**不进返回值**，失败时不回滚）。错误两类：`ParserInvariant`（`last_opcode_pos` 越界、或 marker 顺序被破坏——内部不变量，走 ICE 出口）与 `addSourceMarker` 经 `mapBuilderError` 折出的 `OutOfMemory`/`BytecodeOverflow`。唯一调用方 `parseReturnStatement`（`src/parser.zig:9065`）。

### `emitParsedReturn` (`src/parser.zig:9807`)

- **签名**：`fn emitParsedReturn(s: *State, has_expr: bool) Error!void`。
- **作用**：`return` 语句的发射入口：判断需不需要值、必要时补 `undefined`，再交清理链或直接终结。
- **实现**：先算 `needs_value`：有返回表达式、或在 async / generator 里、或还有 `return_finally_frames` / `finally_body_control_frames` / `top_break` / 非零 `active_catch_marker_depth` 需要穿越——任一成立就必须有一个值在栈上。都不成立时直接 `emitFunctionReturn(s, false)`（会落成 `return_undef`）。否则：没有表达式时先发 `op.undefined` 把缺失的返回值物化出来（qjs `emit_return`，quickjs.c:28411-28414），再调 `emitReturnValue`，其 `await_before_unwind` 参数是 `has_expr and s.in_async and s.in_generator`——只有异步生成器的显式返回值要在展开清理链之前 await。
- **所有权 / 错误 / 调用**：不分配：只按七个状态位（`has_expr` / `in_async` / `in_generator` / 两个 frame 栈 / `top_break` / `active_catch_marker_depth`）决定走哪条臂，自己最多发一条 `undefined`，其余转给 `emitFunctionReturn` 或 `emitReturnValue`。错误全部由被调方产生（Builder 经 `mapBuilderError` 折叠，async 生成器路径还可能带出 `await` 相关判定）。树内唯一调用方 `parseReturnStatement`（`:9070`）。

### `emitFunctionReturn` (`src/parser.zig:9826`)

- **签名**：`fn emitFunctionReturn(s: *State, has_value: bool) Error!void`。
- **作用**：选择函数尾部的终结指令，含派生构造器的返回值替换与 async / generator 的补值。
- **实现**：先补值：`has_value` 为假但在 async / generator 里时发 `op.undefined` 并把 `value_on_stack` 置真（qjs quickjs.c:28396-28400）。然后三路选终结指令。①派生类构造器（`in_constructor and class_has_extends`）：有值时发 `ext0` 子码 `check_ctor_return` 检查返回值是否是对象，新建 `return_value` 标签并 `if_false` 跳过替换；不跳过就 `drop` 掉返回值、改用 `emitScopeGetVarCheckThis(atom_this)` 取带 TDZ 检查的 `this`，再绑标签（quickjs.c:28453-28472）；无值时直接 `emitScopeGetVarCheckThis(atom_this)`。两种情况最后都发 `op.return`（quickjs.c:28472-28473）。②async / generator：发 `op.return_async`（quickjs.c:28474-28475）。③普通函数：按 `value_on_stack` 在 `op.return` 与 `op.return_undef` 之间二选一（quickjs.c:28476-28477）。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。派生构造器臂新建一个栈上 `Label`（Builder 索引，无释放义务）并转调 `emitScopeGetVarCheckThis(atom_this)`（预定义 atom，借用）。`has_value` 只是入参，函数用局部 `value_on_stack` 决定是否先补一条 `undefined`，不改 `State`。调用方 2 处：`emitReturnValue`（`:10189`，清理走完后的终结）与 `emitParsedReturn`（`:10281`，无需值的快路径）。

### `emitDirectPatternPut` (`src/parser.zig:12271`)

- **签名**：`fn emitDirectPatternPut(s: *State, binding: anytype) Error!void`。
- **作用**：解构目标就是一个简单绑定名时的写回指令。
- **2026-09-20 退役后**：两行：按 `binding.is_init` 选 `scope_put_var_init` / `scope_put_var`，`Emitter.opAtomU16(op_id, name, binding.scope)`。`ensureClosureVar` 前置调用与 `put_var` 臂已删。
- **实现**：解构里「目标就是一个简单绑定名」时的存储路径。先 `s.ensureClosureVar(binding.name)`；`emit_phase1_temp` 时按 `binding.is_init` 在 `op.scope_put_var_init` 与 `op.scope_put_var` 之间选码，用 `Emitter.opAtomU16(op_id, name, binding.scope)` 发 phase-1 形式；非 phase-1 时按 `is_init` 走 `s.emitGlobalVarOp(op.put_var_init, ...)` 或 `emitGlobalVarOp(op.put_var, ...)`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。先 `s.ensureClosureVar(binding.name)`（phase-1 下是 no-op，非 phase-1 才物化闭包变量，可返回 `Error`）。`binding` 是 `anytype` 传入的借用视图，`name` 只是 atom id（`CompileAtomScope` 作根，无 retain/release）。树内唯一调用方 `putPatternTarget`（`:12752`）的 `.direct_binding` 臂。

### `putPatternTarget` (`src/parser.zig:12283`)

- **签名**：`fn putPatternTarget(s: *State, target: *PatternTarget) Error!void`。
- **作用**：把栈顶的值存进一个解构目标，两种目标形态各走各的存储路径。
- **实现**：`switch (target.*)`：`.direct_binding` 转 `emitDirectPatternPut(s, binding)`（简单名字绑定）；`.lvalue` 转 `putLValue(s, lvalue, .no_keep_depth)`（成员访问、super、引用等一般赋值目标，`no_keep_depth` 表示存完不留值）。
- **所有权 / 错误 / 调用**：不分配：两条臂分别转 `emitDirectPatternPut`（直接绑定）与 `putLValue(..., .no_keep_depth)`。`target` 是**可变借用**——`.lvalue` 臂会被 `putLValue` 清掉 `owns_name`（atom 所有权交给发出的 setter），因此调用方随后的 `PatternTarget.deinit` 变成空操作。错误由两个被调方产生（`InvalidAssignmentTarget` / `ParserInvariant` / Builder 折叠）。调用方 4 处：`parseArrayPatternBody`（`:12994`）与 `parseObjectPatternBody`（`:13029`/`:13075`/`:13104`）。

### `parsePatternDefault` (`src/parser.zig:12290`)

- **签名**：`fn parsePatternDefault(s: *State, target: *const PatternTarget) Error!void`。
- **作用**：解析并发射解构目标的 `= 默认值`（只在取到 `undefined` 时生效）。
- **实现**：下一个 token 不是 `=` 就直接返回（没有默认值）。否则发一段运行时判定：`dup` 复制取出的值、`undefined`、`strict_eq` 比较，新建 `has_value` 标签并 `if_false` 跳过默认值分支（值不是 `undefined` 就用它）。默认值分支里先 `drop` 掉那个 `undefined`，`advance` 吃掉 `=`，`parseAssignExpr` 解析默认表达式；若 `target.defaultName()` 给出名字（目标是简单绑定），调 `emitAnonymousDefaultName` 给匿名函数/类补名。最后 `bind(has_value)` 汇合。注意判定用的是 `strict_eq undefined` 而不是 nullish，符合规范里默认值只对 `undefined` 生效。
- **所有权 / 错误 / 调用**：下一个 token 不是 `=` 时是彻底的 no-op。`has_value` 是栈上的 `Label` 容器（Builder 索引，无释放义务）。`target` 是 `*const` **借用**，只用来取 `defaultName()` 给匿名函数命名，不接管。错误来自 `parseAssignExpr` 递归（`SyntaxError` / `StackOverflow`）与 Builder 经 `mapBuilderError` 的折叠。调用方 3 处：`parseArrayPatternBody`（`:12992`）与 `parseObjectPatternBody`（`:13074`/`:13103`）。

### `rotateNamedSourcePastTarget` (`src/parser.zig:12306`)

- **签名**：`fn rotateNamedSourcePastTarget(s: *State, depth: u8) Error!void`。
- **作用**：在具名属性解构里，把刚取出的源值旋到赋值目标那几个栈槽之上（目标自身占 `depth` 个槽）。
- **实现**：按 `depth` 查表发一条栈洗牌指令：0 什么都不发，1 发 `swap`，2 发 `rot3l`，3 发 `ext0` 子码 `rot4l`；其他值 `unreachable`——`getLValue` 只会产生 0…3 这四种规范栈形状。
- **所有权 / 错误 / 调用**：不分配；四条臂都是单条 `Emitter` 发射，`depth > 3` 走 `unreachable`（Debug panic / Release UB），不是可捕获错误——`getLValue` 的四种规范栈形保证 depth ≤ 3。失败只来自 Builder，经 `mapBuilderError` 转域。唯一调用方 `parseObjectPatternBody`（`src/parser.zig:13100`）。

### `rotateComputedSourcePastTarget` (`src/parser.zig:12316`)

- **签名**：`fn rotateComputedSourcePastTarget(s: *State, depth: u8) Error!void`。
- **作用**：计算属性名解构的对应旋转：属性键本身也占一个槽，所以要比具名版多转一位。
- **实现**：同样按 `depth` 查表：0 不发；1 发 `ext0` 子码 `rot3r`；2 发 `ext0` 子码 `swap2`；3 连发两条 `ext0` 子码 `rot5l`（两次五元左旋等于右旋两位）；其他 `unreachable`。
- **所有权 / 错误 / 调用**：不分配；四条臂都是 `ext0` 子码（`depth == 3` 要连发两条 `rot5l`），`depth > 3` 走 `unreachable`（Debug panic / Release UB）而不是可捕获错误——`getLValue` 的四种规范栈形保证 depth ≤ 3。失败只来自 Builder，经 `mapBuilderError` 转域。树内唯一调用方 `parseObjectPatternBody`（`:13097`）。

### `addNamedObjectRestExclusion` (`src/parser.zig:12329`)

- **签名**：`fn addNamedObjectRestExclusion(s: *State, name: Atom) Error!void`。
- **作用**：发指令把一个具名属性键记进对象 rest 的排除表（`swap`/`null`/`define_field name`/`swap`），让后续 rest 复制跳过它。
- **实现**：四条指令，把一个具名属性登记进对象 rest 的排除表：`swap` 把排除表换到栈顶、`null` 压一个占位值、`define_field name` 在排除表上定义这个键（值无所谓，只看键存在）、再 `swap` 换回原来的顺序。
- **所有权 / 错误 / 调用**：不分配；`Emitter.opAtom` 把 `name` 的 id 写进 Builder 的 atom 操作数流，只是 id 拷贝、无 retain/release（编译期 atom 由 `CompileAtomScope` 作根），调用方仍可继续使用该 atom。失败只来自 Builder，经 `mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。三个调用方都在 `parseObjectPatternBody`（`src/parser.zig:13059`/`:13065`/`:13086`）。

### `addComputedObjectRestExclusion` (`src/parser.zig:12336`)

- **签名**：`fn addComputedObjectRestExclusion(s: *State) Error!void`。
- **作用**：同上的计算键版本：`to_propkey` 规整栈顶键，再 `perm3`/`null`/`define_array_el`/`perm3` 把它写进排除表并复原栈序。
- **实现**：计算键版本，五条指令：`to_propkey` 把键规范化成属性键、`perm3` 把它排到排除表之下、`null` 压占位值、`define_array_el` 用计算键在排除表上定义、`perm3` 把栈序换回来。
- **所有权 / 错误 / 调用**：不分配、不涉及 atom：五条无立即数指令写 Builder（键在运行时栈上），失败只来自 Builder 经 `mapBuilderError` 的转域。两个调用方都在 `parseObjectPatternBody`（`src/parser.zig:13052`/`:13079`）。

### `objectRestCopyMask` (`src/parser.zig:12344`)

- **签名**：`fn objectRestCopyMask(depth: u8) Error!u8`。
- **作用**：算出 `copy_data_properties` 指令用的那个栈位掩码：把源对象与排除表相对栈顶的深度编码成一个字节。
- **实现**：`depth > 3` 直接 `Error.InvalidAssignmentTarget`——`getLValue` 只有 0…3 四种规范栈形状，注释说明这里先把 `depth` 加宽到 `u16` 再移位，是为了让将来写坏的调用方报一个内部赋值目标错误而不是在窄算术上溢出。随后返回 `((wide_depth + 1) << 2) | ((wide_depth + 2) << 5)`，即两个操作数深度分别放在 bit 2-4 与 bit 5-7。
- **所有权 / 错误 / 调用**：不碰 `State`、不分配：纯算术。唯一错误 `Error.InvalidAssignmentTarget` 是**防御性**的（`depth > 3` 在当前 `getLValue` 的四种栈形下不可达），它不在 `isInternalCompilerError` 名单里，所以真发生时会被 `compile` 收成用户可见的 `Result.syntax_error`。唯一调用方 `parseObjectPatternBody`（`src/parser.zig:13026`）。

### `emitArrayPatternRest` (`src/parser.zig:12353`)

- **签名**：`fn emitArrayPatternRest(s: *State, target_depth: u8) Error!void`。
- **作用**：把数组解构里的 `...rest` 降成「把迭代器取尽装进新数组」的循环。
- **实现**：把迭代器剩余元素收进一个新数组的循环。先 `array_from 0` 造空数组、`push_i32 0` 压下标。`next` 标签用 `Emitter.bindRaw` 绑（raw：不作废 last opcode，回边不算控制流汇合）。循环体：`for_of_next (target_depth + 2)` 取下一个元素（立即数是迭代器相对栈顶的深度，+2 是数组与下标这两个槽），`if_true done` 在迭代结束时跳出，否则 `define_array_el` 写入、`inc` 递增下标、`goto next` 回边。`done` 用普通 `Emitter.bind` 绑（真汇合），最后两条 `drop` 丢掉下标与迭代器残留，留下收好的数组。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。两个 `LabelId`（`next` / `done`）是栈上索引，无释放义务；注意 `next` 用的是 `Emitter.bindRaw`（保留 last-opcode provenance），`done` 用普通 `Emitter.bind`（汇合点，作废 provenance）。`target_depth` 只作 `for_of_next` 的立即数（`target_depth + 2`），不改 `State`。调用方 2 处，都在 `parseArrayPatternBody`（`:12977`/`:12988`）。

### `pushPatternIteratorBlock` (`src/parser.zig:12371`)

- **签名**：`fn pushPatternIteratorBlock(s: *State, block: *BlockEnv) void`。
- **作用**：给解构里的迭代器登记一个 `BlockEnv` 记录，使 `break` / `return` 穿越时知道要关闭这个迭代器。
- **实现**：就地把 `block` 填成一条迭代器记录：`prev = s.top_break` 串进链表，标签名与 `label_break` / `label_cont` / `label_finally` 全部填空（`null_atom` / `-1`，解构迭代器不是可跳转目标），`drop_count = 2`（迭代器占两个栈槽），`scope_level` 与 `catch_marker_depth` 取当前值，`has_iterator = true`、`is_regular_stmt = false`。最后 `s.top_break = block`。
- **所有权 / 错误 / 调用**：不分配：`BlockEnv` 是调用方的**栈上**变量，本函数只填字段并把 `s.top_break` 指向它——因此这块内存的生命周期完全由调用方的栈帧决定，必须配对 `popPatternIteratorBlock` 才能让 `top_break` 不悬空。无 error set。唯一调用方 `parseArrayPatternBody`（`src/parser.zig:12948`）。

### `popPatternIteratorBlock` (`src/parser.zig:12387`)

- **签名**：`fn popPatternIteratorBlock(s: *State, block: *BlockEnv) void`。
- **作用**：解构结束时把上面那条迭代器 `BlockEnv` 摘出链表。
- **实现**：两行：`std.debug.assert(s.top_break == block)` 确认摘的是栈顶那条（配对使用），然后 `s.top_break = block.prev`。`block` 本身在调用方栈上，不需要释放。
- **所有权 / 错误 / 调用**：不释放任何东西（`BlockEnv` 在调用方栈上）：只把 `s.top_break` 退回 `block.prev`，并 `assert` 栈顶就是这一帧。无 error set。两个调用方都在 `parseArrayPatternBody`：正常出口 `src/parser.zig:13004` 与兜底的 `defer`（`:12950`）。

### `emitStackTopCatchMarkerDropsToDepth` (`src/parser.zig:12395`)

- **签名**：`fn emitStackTopCatchMarkerDropsToDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void`。
- **作用**：把 catch 标记深度降到目标值，过程中保住栈顶值并补上各层 `using` 处置。
- **实现**：`current_depth.* < target_depth` 是 `Error.ParserInvariant`（只许往下降）。然后循环到 `target_depth`：每轮发一条 `op.nip_catch` 删掉一条 catch 记录同时保住栈顶值（qjs `emit_return`，quickjs.c:28415-28419），再 `emitUsingDisposesForCatchMarkerDepth(s, current_depth.*)` 补上该层 using 块的处置，最后 `current_depth.* -= 1`。之所以必须用 `nip_catch` 而不是普通 drop：挂起过的 `yield` 可能在 catch 标记与被注入的返回值之间留下表达式操作数。
- **所有权 / 错误 / 调用**：`current_depth` 是**可变借用的游标**：循环里每发一条 `nip_catch` 就递减一格，调用方靠它接着往下走；本函数不碰 `s.active_catch_marker_depth` 本身。`current_depth.* < target_depth` 即 `Error.ParserInvariant`（内部不变量，ICE 出口）。不分配；其余失败来自 `emitUsingDisposesForCatchMarkerDepth` 与 Builder 经 `mapBuilderError` 的折叠。调用方 3 处：`emitReturnValue`（`:10180`/`:10188`）与 `emitBlockEnvReturnCleanupUntil`（`:12906`）。

### `emitBlockEnvReturnCleanupUntil` (`src/parser.zig:12408`)

- **签名**：`fn emitBlockEnvReturnCleanupUntil( s: *State, block_cursor: *?*BlockEnv, boundary: ?*BlockEnv, catch_marker_depth: *u32, ) Error!void`。
- **作用**：`return` 穿出若干层块时，沿 BlockEnv 链逐层发迭代器与 finally 的清理码，直到（不含）`boundary`。
- **实现**：`async_generator = s.in_async and s.in_generator` 决定迭代器收尾要不要走 await 版，并据此预取 `"return"` atom。然后沿 `block_cursor` 往外走，碰到 `boundary` 立即返回；走到链尾仍没碰到说明边界不在链上，返回 `Error.ParserInvariant`。每层分三种处理：① 该 BlockEnv 出现在 `finally_body_control_frames` 里（正在 finalizer 体内）→ 两条 `nip`，丢掉这层的 completion 与 gosub 返回 PC，保住注入的 return 值（`quickjs.c:28408-28419`）；② `has_iterator` → 先 `emitStackTopCatchMarkerDropsToDepth` 把 catch marker 深度降到这层记录的 `catch_marker_depth`，再 `nip_catch` 摘掉迭代器的 catch 记录，异步生成器还要 `nip; swap; get_field2 "return"; dup; is_undefined_or_null`，有 `return` 方法就 `call_method 0` + `iterator_check_object` + `await`、没有就 `drop`，两路汇合后再 `drop` 还原注入的返回值（`quickjs.c:28422-28440`），同步路径则 `ext0/rot3r` + `undefined` + `iterator_close`（`quickjs.c:28441-28444`）；③ 其余层不发码，只推进游标。
- **所有权 / 错误 / 调用**：不分配：`block_cursor` 与 `catch_marker_depth` 都是**可变借用的游标**，函数沿 `BlockEnv.prev` 链把前者推到 `boundary`（不含）并同步后者；它不改 `s.top_break` 本身，也不释放任何 `BlockEnv`（那些都在各自的栈帧上）。async 生成器路径用预定义 atom `"return"`（取不到即 `Error.ParserInvariant`），只是 id 借用。其余失败来自 `emitStackTopCatchMarkerDropsToDepth` 与 Builder 经 `mapBuilderError` 的折叠。调用方 2 处，都在 `emitReturnValue`（`:10179` 逐 finally 帧、`:10187` 收尾一次走到底）。

### `setObjectName` (`src/parser.zig:13138`)

- **签名**：`fn setObjectName(s: *State, atom_id: Atom) Error!void`。
- **作用**：把推断出的名字回填到紧邻的匿名函数/类占位指令上（`const f = function(){}` 一类的 name 推断）。
- **实现**：只认**直接尾随**的那条指令：`builder.last_opcode_pos < 0` 直接放弃；下标越过 `code_len` 说明 provenance 已坏，报 `Error.ParserInvariant`。按尾码分两路。`set_name`：要求它确实是尾部完整的 5 字节（`code_len - opcode_pos == 5`）且 atom ledger 非空，读出占位 atom，只有占位仍是 `null_atom`（没被别的推断先占）时才 `replaceAtomOperand` 换成 `atom_id`。`set_class_name`：经 `trailingClassNamePatch` 找回对应的 `define_class` 位置与 atom 下标，把 `empty_string` 占位换成名字，再 `invalidateLastOpcode()` 并清 `last_class_name_patch`，保证同一处不会被改写两次。其他尾码一律不动。名字只落在运行时指令上，既不写进 `FunctionDef.func_name`，也不产生具名函数表达式的自绑定（qjs `set_object_name`）。
- **所有权 / 错误 / 调用**：不分配：两条臂都是就地改写 `activeBuilder()` 已有的字节与 atom 操作数（`replaceAtomOperand` 换掉占位 id）。`atom_id` 只是 id 拷贝——写进 Builder 的 atom 流不 retain、调用方也不因此失去它（编译期 atom 由 `CompileAtomScope` 作根）。错误两类：`Error.ParserInvariant`（`last_opcode_pos` 越界、`set_name` 尾形不是 5 字节、atom 流为空——都是内部不变量，走 `setInternalCompilerError` 的 ICE 出口），以及 `replaceAtomOperand` 经 `mapBuilderError` 折出的 `OutOfMemory`/`BytecodeOverflow`。`set_class_name` 臂还会清掉 `s.last_class_name_patch` 并 `invalidateLastOpcode`。8 处调用方：`parseAssignExpr2`（`src/parser.zig:4115`）、`parseLogicalAssignment`（`:4170`）、`parseObjectProperty`（`:6856`）等，另加 `emitAnonymousDefaultName`（`:13676`）转发。

### `setObjectNameComputed` (`src/parser.zig:13179`)

- **签名**：`fn setObjectNameComputed(s: *State) Error!void`。
- **作用**：计算属性名场景下，把尾部的名字占位指令改成「从栈上取键」的运行时形式。
- **实现**：前置检查与 `setObjectName` 相同（`last_opcode_pos` 有效、下标不越界，否则 `Error.ParserInvariant`）。`set_name` 分支：确认尾部是完整 5 字节且占位仍为 `null_atom` 后，`rewriteTrailingAtomOpAsPlain` 把带 atom 的 `set_name` 就地改写成无 atom 的 `set_name_computed`，名字改由栈上的计算键提供。`set_class_name` 分支：用 `trailingClassNamePatch` 定位 `define_class`，把它那一字节直接改成 `define_class_computed`——匿名类于是在任何 static 初始化器运行之前消费掉计算键；随后 `invalidateLastOpcode()` 并清 `last_class_name_patch`。其余尾码不动（qjs `set_object_name_computed`）。
- **所有权 / 错误 / 调用**：不分配、不涉及任何 atom 所有权（把带 atom 立即数的 `set_name` 改写成无立即数的 `set_name_computed`，`rewriteTrailingAtomOpAsPlain` 顺带摘掉 Builder atom 流尾部那一项，摘掉的只是 id）。错误与 `setObjectName` 同形：形状检查失败 → `Error.ParserInvariant`（ICE 出口），Builder 失败经 `mapBuilderError`。两个调用方：`parseObjectProperty`（`src/parser.zig:6820`）与 `emitFieldInitializer`（`:14217`）。

### `emitAnonymousDefaultName` (`src/parser.zig:13207`)

- **签名**：`fn emitAnonymousDefaultName(s: *State, atom_id: Atom) Error!void`。
- **作用**：按 NamedEvaluation 给刚求值出来的匿名函数 / 类补上名字。
- **实现**：单行 `try setObjectName(s, atom_id);`。栈顶如果是刚求值出来的匿名函数 / 类，就按 NamedEvaluation 给它补上名字；`setObjectName` 自己会判断该值是否需要命名。调用点是解构默认值（`parsePatternDefault`）与默认导出一类「名字由目标决定」的场合。
- **所有权 / 错误 / 调用**：单行转发 `setObjectName`，自身不分配、不引入新错误，所有权/错误全同上条（atom 只是 id 拷贝）。存在的意义是给「匿名函数取默认导出名 / 解构默认名」这三个调用点一个有名字的入口：`parsePatternDefault`（`src/parser.zig:12769`）、`parseNamedBindingDefaultInitializer`（`:13566`）、`parseExport`（`:15497`）。

### `parseClassElementFunction` (`src/parser.zig:13968`)

- **签名**：`fn parseClassElementFunction(s: *State, kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：以「类方法」语义解析并发射一个函数：类体恒严格、允许 super，构造器还负责收集 TS 参数属性。
- **实现**：一层状态保存 + 一次解析。①TypeScript 参数属性：构造器（`.class_constructor` / `.derived_class_constructor`）时把 `s.current_parameter_properties` 换成空列表，其它 kind 置 `null`；`defer` 里对构造器调 `deinitOwnedParserAtoms` 释放收集到的 atom，再还原旧值。②以 `FunctionEntry{ .is_method = true }` 调 `parseFunctionParamsAndBody`；类体恒严格与 `allow_super` 不必在此重设（类体入口已置 strict，方法的 super 能力由 kind 派生）。以前这里还用 `FunctionEntryContext.save` 整批保存八个入口状态位并 `defer` 还原，然后按类方法语义重设：`pending_function_name = null`、`is_decl = false`、`in_async` / `in_generator` 由 kind 推出、`is_strict = true`（类体恒为严格模式）、`allow_super = true`、`root_mode = true`、`parsing_method_params = true`。③`parseFunctionParamsAndBody(s, kind, source_start)` 解析并发射方法体。与 `parseObjectMethodFunction` 的差别就是多了 `is_strict` 与参数属性这两件事。
- **所有权 / 错误 / 调用**：自身不发字节码。一处 `defer` 是它的全部所有权工作：①构造器类 `kind` 时把 `s.current_parameter_properties` 换成一个新的 `ArrayList(Atom)`，退出时 `deinitOwnedParserAtoms` 释放它（**这是本条目里唯一真正拥有资源的地方**）再还原旧值；②（已删）`FunctionEntryContext.save`/`restore` 曾把八个入口状态位整批存还。真正的 FunctionDef 分配与错误都在转调的 `parseFunctionParamsAndBody` 里。调用方 7 处：`parseClassElement`（`:13762`/`:13797`/`:13823`/`:13902`）、`emitStaticClassComputedElement`（`:14488`）、`emitInstanceClassComputedElement`（`:14524`）、`parseClassComputedMethod`（`:14552`）。

### `parseClassComputedName` (`src/parser.zig:14007`)

- **签名**：`fn parseClassComputedName(s: *State) Error!void`。
- **作用**：解析类成员的计算键 `[expr]`，并把求值结果规范化成属性键。
- **实现**：四步：`expectToken('[')`、`parseAssignExpr2(s, ParseFlags.default)` 求值键表达式、发 `Emitter.op(op.to_propkey)` 把结果规范化成属性键（qjs `js_parse_class` 在存下或交给 `define_method_computed` 之前就做这一步）、`expectPunct(']')`。规范化必须在这里做，因为键的求值顺序早于后面的初始化器。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。自身只发一条 `to_propkey`；其余错误来自 `parseAssignExpr2` 递归（`SyntaxError` / `StackOverflow`）与两处 token 期待（`expectToken('[')` / `expectPunct(']')` 的 `SyntaxError`）。不碰 atom。调用方 3 处：`emitStaticClassComputedElement`（`:14486`）、`emitInstanceClassComputedElement`（`:14522`）、`parseClassComputedMethod`（`:14550`）。

### `emitStaticClassComputedElement` (`src/parser.zig:14016`)

- **签名**：`fn emitStaticClassComputedElement(s: *State, kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：发射静态的计算名成员：方法直接定义，字段先把键存进隐藏的 const 绑定。
- **实现**：类栈是 `[constructor, prototype]`，静态元素要先 `swap` 把构造器露到栈顶，再 `parseClassComputedName` 求键。随后分两路。①下一个 token 是 `(`：这是计算名静态方法——`parseClassElementFunction` 解析函数体，`define_method_computed 0` 定义，再 `swap` 把类栈换回来，返回。②否则必须是 `.method` kind（不然 `ParserInvariant`），当作计算名静态字段处理：`classComputedFieldTempAtom` 造一个临时名、`defineVar(key_atom, .const_)` 声明成 const、`emitScopePutVarInit` 把键存进这个隐藏绑定，然后 `swap` 恢复类栈；接着按有没有 `=` 调 `emitStaticFieldInitializer(s, key_atom, false, true, has_initializer)`，最后 `expectSemicolon`。把键先存进 const 绑定，是为了让键只求值一次而初始化器可以稍后运行。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。`classComputedFieldTempAtom`（`:14427`）会在 AtomTable 里 intern 一个 `__class_computed_field_<n>` 名字（中间那块 `allocPrint` 缓冲当场 `defer free`），该 atom 的存活归本次编译的 `CompileAtomScope`，本函数无 retain/release 义务；副作用是 `s.with_scope_id += 1`。`defineVar(key_atom, .const_)` 会在当前作用域留下一条绑定（归 FunctionDef）。`kind != .method` 的非方法计算键是 `Error.ParserInvariant`（内部不变量）。树内唯一调用方 `parseClassElement`（`:13870`）。

### `emitInstanceComputedPublicFieldInitializer` (`src/parser.zig:14051`)

- **签名**：`inline fn emitInstanceComputedPublicFieldInitializer(s: *State, key_atom: Atom, has_initializer: bool) Error!void`。
- **作用**：实例侧计算名公有字段初始化器的发射入口。
- **实现**：单行转调 `emitFieldInitializer(s, key_atom, false, true, has_initializer, false)`：非私有、is_computed=true、按参数决定有无初始化器、非静态。注释记着这是「刀 101」留下的实例计算字段入口——实例侧原先被写成 `is_computed=false`，而共享发射走法里取键那条臂的条件是 `is_private or is_computed`，所以这里显式传 true 才能走到取键臂。
- **所有权 / 错误 / 调用**：`inline` 单行转发 `emitFieldInitializer(s, key_atom, false, true, has_initializer, false)`，自身不分配、不引入新错误——参数里那两个写死的 `false` 就是它存在的理由（knife 101 之后实例侧 `is_private=false`、末位 `is_static=false`，取键那条臂是 `is_private or is_computed`）。`key_atom` 借用。调用方 2 处，都在 `emitInstanceClassComputedElement`（`:14537`/`:14539`）。

### `emitInstanceClassComputedElement` (`src/parser.zig:14055`)

- **签名**：`fn emitInstanceClassComputedElement(s: *State, kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：发射实例侧的计算名成员，与静态版同构但不需要交换类栈。
- **实现**：与 `emitStaticClassComputedElement` 同构，但实例侧栈顶已经是 prototype，所以两头都不需要 `swap`。`parseClassComputedName` 求键后：下一个 token 是 `(` 就 `parseClassElementFunction` + `define_method_computed 0` 定义计算名实例方法并返回；否则要求 kind 是 `.method`（否则 `ParserInvariant`），走计算名实例字段——`classComputedFieldTempAtom` 造临时名、`defineVar(..., .const_)`、`emitScopePutVarInit` 存键，再按有没有 `=` 调 `emitInstanceComputedPublicFieldInitializer(s, key_atom, has_initializer)`，最后 `expectSemicolon`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。`classComputedFieldTempAtom`（`:14427`）会在 AtomTable 里 intern 一个 `__class_computed_field_<n>` 名字（中间那块 `allocPrint` 缓冲当场 `defer free`），该 atom 的存活归本次编译的 `CompileAtomScope`，本函数无 retain/release 义务；副作用是 `s.with_scope_id += 1`。与静态版的差别是不发那两条维护类栈的 `swap`。`kind != .method` → `Error.ParserInvariant`。树内唯一调用方 `parseClassElement`（`:13872`）。

### `parseClassComputedMethod` (`src/parser.zig:14078`)

- **签名**：`fn parseClassComputedMethod(s: *State, kind: ParseFunctionKind, define_flags: u8, source_start: FunctionSourceStart) Error!void`。
- **作用**：发射计算名的访问器 / 方法，`define_flags` 区分 getter、setter 与普通方法。
- **实现**：计算名访问器（getter / setter）的发射。`s.is_static` 时先 `swap` 把构造器露到栈顶，再 `parseClassComputedName` 求键；下一个 token 不是 `(` 就 `failExpectedToken('(')`（访问器必须紧跟参数表）。然后 `parseClassElementFunction` 解析函数体，发 `define_method_computed` 并把 `define_flags` 作为 u8 立即数传进去（这个标志位区分 getter / setter / 普通方法）；静态时最后再 `swap` 把类栈恢复成 `[constructor, prototype]`。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。不碰 atom、不留绑定：只按 `s.is_static` 在前后各补一条 `swap`，中间解析计算键并把方法体交给 `parseClassElementFunction`，最后发 `define_method_computed define_flags`。下一个 token 不是 `(` 时走 `s.failExpectedToken('(')`（源程序 `SyntaxError`，不是内部不变量）。树内唯一调用方 `parseClassElement`（`:13785`）。

### `parseClassStaticBlock` (`src/parser.zig:14097`)

- **签名**：`fn parseClassStaticBlock(s: *State) Error!void`。
- **作用**：把 `static { ... }` 编译成对一个合成初始化函数的方法调用。
- **实现**：把 `static { ... }` 编译成一次对合成初始化函数的方法调用。先 `ensureClassStaticInitFunction` 拿到子函数下标并从 `parent_fd.child_list` 取出 `init_fd`（下标越界是 `ParserInvariant`）。`enterStaticBlockFunction` 切进这个子 FunctionDef（`errdefer leaveStaticBlockFunction` 保证失败也切回来），用 `.class_static_block` kind 调 `parseFunctionParamsAndBody` 解析块体。回到外层后发调用序列：`emitScopeGetVar(atom_this)` 取类构造器作为接收者，`swap` 把它排到闭包之下，`callOp(op.call_method, 0)` 无参调用，`drop` 丢掉完成值（qjs `js_parse_class`，quickjs.c:25394）。最后正常路径上再调一次 `leaveStaticBlockFunction` 切回。
- **所有权 / 错误 / 调用**：有**发射目标切换**的所有权协议：`enterStaticBlockFunction(s, init_fd)` 把解析上下文切到静态初始化子函数，`errdefer leaveStaticBlockFunction(s, saved_ctx)` 保证失败也切回，成功路径在末尾显式切回（不是 `defer`——切回之后还要在父函数流里发调用序列）。子 FunctionDef 由 `ensureClassStaticInitFunction` 建在父 `child_list` 上，归父 FunctionDef，本函数不回收；`child_index` 越界即 `Error.ParserInvariant`。`atom_this` 是预定义 atom（借用）。其余失败来自 `parseFunctionParamsAndBody` 与 Builder 经 `mapBuilderError` 的折叠。树内唯一调用方 `parseClassElement`（`:13959`）。

### `parseClassBodyAfterOpen` (`src/parser.zig:14123`)

- **签名**：`fn parseClassBodyAfterOpen(s: *State) Error!void`。
- **作用**：解析类体的全部成员，直到闭合的 `}`。
- **实现**：`{` 已由调用方消费。循环到 `}` 或 `TOK_EOF` 为止：孤立的 `;` 直接吃掉继续（类体允许空成员分号），其余交 `parseClassElement`。出循环后 `s.expectToken('}')`——因 EOF 提前退出的情形由这一步报语法错。对齐 `js_parse_class_body`。
- **所有权 / 错误 / 调用**：自身不发字节码、不分配、无 atom 义务：只是「跳过空 `;` + 反复 `parseClassElement` + 最后 `expectToken('}')`」的循环骨架，所有错误都由 `parseClassElement` 递归与那次 token 期待产生（`SyntaxError` / `StackOverflow` / 底层 OOM）。注意循环同时以 `}` 和 `TOK_EOF` 为界，未闭合的类体由末尾的 `expectToken('}')` 报错。树内唯一调用方 `parseClass`（`:14841`）。

### `collectClassPrivateBoundNames` (`src/parser.zig:14135`)

- **签名**：`fn collectClassPrivateBoundNames(s: *State, bound_start: usize) Error!void`。
- **作用**：在真正解析类体之前先扫一遍 token，把类体里声明的私有名全部登记成绑定，使类体内任意位置的 `#x` 前向引用都能解析。
- **实现**：下一个 token 不是 `{` 直接返回。用 `takeLexerCursorSnapshot` / `defer restoreLexerCursorSnapshot` 把整个预扫描做成无副作用的前瞻。然后从 `brace_depth = 1` 起逐 token 扫到配平：遇到 `TOK_PRIVATE_NAME` 且处在类体的直接层级（`brace_depth == 1`、`paren_depth == 0`、`bracket_depth == 0`）、且前一个 token 不是 `.` 也不是 `?.`（那样是**使用**而非声明）时，用 `privateNameDeclarationAtom(..., bound_start)` 造出声明 atom 并 `registerClassPrivateBoundName` 登记。扫描器还要正确跳过会干扰括号计数的词法结构：`/` 与 `/=` 交给 `skipRegexpInPredeclareScan` 判断是否正则字面量，`TOK_TEMPLATE` 交给 `skipTemplateInPredeclareScan` 整体跳过，两者都直接 `continue` 并把 `prev_kind` 记成对应类别；`{` `}` `(` `)` `[` `]` 维护三个深度计数（`}` 使 `brace_depth` 归零时结束），`TOK_EOF` 提前跳出。每轮末尾更新 `prev_kind`。
- **所有权 / 错误 / 调用**：**预扫描**：用 `takeLexerCursorSnapshot`/`restoreLexerCursorSnapshot`（`src/parser.zig:13256`/`:13268`）把 lexer 光标借出去再还回来，`defer` 保证任何错误路径都复位；扫描里每个 `scan_token` 都由 `defer s.lex.freeToken` 释放 payload（释放的是 token 的字符串缓冲，不是 atom）。真正的分配在 `registerClassPrivateBoundName` 直接往 `s.class_private_bound_names` 追加借用 id（缓冲归 `State`，`State.deinit` 释放；rc 时代的 `appendRetainedAtom` 包装已删）；`privateNameDeclarationAtom`（`:14387`）可能经 `newClassPrivateAtom` 新建一个 `.private` symbol atom，同样由 `CompileAtomScope` 作根。错误：`OutOfMemory`（append / newSymbol）、lexer 的 `SyntaxError` 族、`Error.InvalidIdentifier`（atom 无名）。唯一调用方 `parseClass`（`:14826`），调用前后靠 `bound_start` 游标划分本类的私有名区间。

### `emitClassLocalInitFromClassStack` (`src/parser.zig:14194`)

- **签名**：`fn emitClassLocalInitFromClassStack(s: *State, local_idx: u16) Error!void`。
- **作用**：把构造器存进类体内那个不可变的类名局部绑定。
- **实现**：四条指令，在保持类栈 `[constructor, prototype]` 顺序的前提下初始化类体内那个不可变的类名绑定：`swap` 把构造器换到栈顶、`dup` 复制一份、`put_loc_check_init local_idx` 存进类名局部槽（check_init 形式确保这个 const 绑定只初始化一次）、再 `swap` 把栈序换回来。
- **所有权 / 错误 / 调用**：不分配、不持有：四条 `Emitter` 发射写 Builder，`local_idx` 是调用方给的槽号。失败只来自 Builder，经 `mapBuilderError` 折成 `OutOfMemory`/`BytecodeOverflow`/`ParserInvariant`。两个调用方都在 `parseClass`（`src/parser.zig:14926`/`:14994`，声明式与表达式两条收尾路径）。

### `emitClassFieldsInitValue` (`src/parser.zig:14203`)

- **签名**：`fn emitClassFieldsInitValue(s: *State, class_fields_init_child_index: ?u16) Error!void`。
- **作用**：给隐藏的 `class_fields_init` 绑定压上初值：初始化器闭包，或没有实例字段时的 `undefined`。
- **实现**：给隐藏的 `class_fields_init` 绑定准备初值。有 `class_fields_init_child_index` 时：取 `parent_fd.child_list[child_index]` 的 `parent_cpool_idx`（下标越界或 cpool 下标为负都是 `ParserInvariant`），`s.emitFClosure(cpool_idx)` 造出初始化器闭包，再发 `set_home_object` 把它绑到类的 home object 上（qjs `emit_class_init_end`）。没有实例字段时直接发 `op.undefined`——qjs 同样用 `undefined` 初始化这个隐藏绑定。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。两条臂都不碰 atom：有初始化子函数时读 `parent_fd.child_list[child_index].parent_cpool_idx`（常量早已归 `FunctionDef.cpool`，这里只用下标），没有就发一条 `undefined`。`child_index` 越界或 `cpool_idx < 0` 都是 `Error.ParserInvariant`（内部不变量）。树内唯一调用方 `emitClassFieldsInitLocalInitFromClassStack`（`:14687`）。

### `emitClassFieldsInitLocalInitFromClassStack` (`src/parser.zig:14220`)

- **签名**：`fn emitClassFieldsInitLocalInitFromClassStack(s: *State, fields_init_local_idx: u16, class_fields_init_child_index: ?u16) Error!void`。
- **作用**：把 fields-initializer 的初值存进它的隐藏词法槽。
- **实现**：两步：`emitClassFieldsInitValue(s, class_fields_init_child_index)` 把闭包或 `undefined` 压上栈，再 `Emitter.opU16(op.put_loc_check_init, fields_init_local_idx)` 存进隐藏的 fields-initializer 词法槽。用 check_init 形式同样是因为它是只能初始化一次的词法绑定。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。两行：转 `emitClassFieldsInitValue` 后补一条 `put_loc_check_init fields_init_local_idx`。`fields_init_local_idx` 是调用方给的借用槽号，本函数不分配槽。错误由被调方产生（`ParserInvariant`）或来自 Builder。调用方 2 处，都在 `parseClass`（`:14928` 声明式、`:14987` 表达式两条收尾路径）。

### `emitClassStaticInitCall` (`src/parser.zig:14227`)

- **签名**：`fn emitClassStaticInitCall(s: *State, class_static_init_child_index: ?u16) Error!void`。
- **作用**：立即调用类的静态初始化器闭包（有静态块或静态字段时才发）。
- **实现**：`class_static_init_child_index` 为空直接返回（没有静态块/静态字段就不发）。否则从 `parent_fd.child_list[child_index]` 取 `parent_cpool_idx`（越界或为负都是 `ParserInvariant`）。此刻栈上只有类构造器，于是发五条：`dup` 复制构造器当接收者兼 home object、`emitFClosure(cpool_idx)` 造静态初始化器闭包、`set_home_object` 绑定、`callOp(op.call_method, 0)` 立即无参调用、`drop` 丢掉完成值。对应 quickjs.c:25735-25744。
- **所有权 / 错误 / 调用**：不分配；经 `Emitter.*` / `emitter*` 写 `activeBuilder()`，Builder 错误由 `mapBuilderError`（`:7448`）折成 `Error.OutOfMemory` / `Error.BytecodeOverflow` / `Error.ParserInvariant`。`class_static_init_child_index` 为 `null` 时整条 no-op（没有静态初始化器）。同样只读 `parent_fd.child_list[...].parent_cpool_idx`，越界或负下标 → `Error.ParserInvariant`。不碰 atom、不留绑定。调用方 2 处，都在 `parseClass`（`:14932`/`:14998`）。

### `emitClassPrivateBrands` (`src/parser.zig:14250`)

- **签名**：`fn emitClassPrivateBrands(s: *State, instance_needed: bool, static_needed: bool) Error!void`。
- **作用**：按需给实例侧（prototype）与静态侧（构造器）打上私有成员 brand。
- **实现**：类栈是 `[constructor, prototype]`，两段都保持栈序不变。`instance_needed` 时发 `dup` / `null` / `swap` / `add_brand`：实例私有成员以 prototype 作 home object，所以要在用户代码有机会把 prototype 变成不可扩展之前先把 brand 建好。`static_needed` 时发 `swap` / `dup` / `dup` / `add_brand` / `swap`：静态私有成员给构造器本身打 brand，两头的 `swap` 负责露出构造器再把 constructor/prototype 顺序还原。
- **所有权 / 错误 / 调用**：不分配、无 atom 立即数：两段都是纯栈操作指令，失败只来自 Builder 经 `mapBuilderError` 的转域；两个开关都为假时整条 no-op。两个调用方都在 `parseClass`（`src/parser.zig:14919`/`:14988`），位置必须在类体的运行时段被 `Emitter.spliceSegment` 贴回之前——`src/compiler/tests.zig:2481` 的注释固定了这个顺序。

### `emitClassDefineOperands` (`src/parser.zig:14270`)

- **签名**：`fn emitClassDefineOperands(s: *State, cpool_idx: u16) Error!void`。
- **作用**：把构造器子函数的常量池下标压栈，供紧随其后的 `define_class` 消费。
- **实现**：单条指令 `Emitter.opU32(s, opcode.op.push_const, cpool_idx)`：把构造器子函数的常量池下标压栈，供紧随其后的 `define_class` 消费。
- **所有权 / 错误 / 调用**：不分配：单条 `push_const <cpool_idx>`，常量本身早已由 `appendCpool` 归 `FunctionDef.cpool` 所有，这里只写下标。失败只来自 Builder，经 `mapBuilderError` 转域。两个调用方都在 `parseClass`（`src/parser.zig:14915`/`:14979`）。

### `appendClassFieldInitCallToFunctionDef` (`src/parser.zig:14564`)

- **签名**：`fn appendClassFieldInitCallToFunctionDef( fd: *function_def_mod.FunctionDef, this_idx: u16, ) Error!void`。
- **作用**：往一个构造器 FunctionDef 的字节码里补上「若存在字段初始化器就以 `this` 为接收者调用它」这段序幕。
- **实现**：先按 `fd.is_derived_class_constructor` 选读 `this` 的 opcode：派生构造器用 `get_loc_check`（它的 `this` 是词法绑定、要 TDZ 检查），基类默认构造器用普通 `get_loc`。然后经 `fd.builder orelse return Error.ParserInvariant` 拿到 Builder（两个调用方都在 `ensureBuilderForFd` 之后，所以这条 orelse 只是 fail-closed），依次 `emitAtomOpU16Owned(scope_get_var, atom_class_fields_init, fd.scope_level)`、`emitOp(dup)`、`newLabel()` 得到 `skip`、`emitJump(if_false, skip)`、`emitOpU16(this_read_op, this_idx)`、`emitOp(swap)`、`emitCallOp(call_method, 0)`、`bindLabel(skip)` + `invalidateLastOpcode()`、`emitOp(drop)`；所有 builder 错误经 `mapBuilderError`。（原先还有一条没有 Builder 时手写 22 字节 raw 码的备用臂，生产不可达，已删。）注释解释了为何这里全用长形式：qjs `emit_class_field_init`（quickjs.c:25184-25207）用 phase-1 的 `scope_get_var` 读 `this`，而 `resolve_scope_var` 只有在绑定是词法的时候才把它降成 `get_loc_check`——`add_var_this`（quickjs.c:32834-32845）只对派生构造器这么做；基类默认构造器的 `this` 是普通 var，qjs 用 `get_loc` 读、再由 `resolve_labels` 缩成 `get_loc0`。这里短槽号落在 phase-1 临时码的重叠区间里不能用，所以连 `if_false` 也发长形式：`resolve_labels` 会重映射它的绝对目标并在 `get_loc` 缩短之后重新缩短这条跳转，而裸的 `if_false8` 相对操作数永远不会被重映射，因此绝不能让它跨越尺寸会变的指令。
- **所有权 / 错误 / 调用**：⚠️ 签名里没有 `*State`：它直接往传入的 `fd` 的 Builder 上发射（`emitAtomOpU16Owned` + `newLabel`/`bindLabel` + `invalidateLastOpcode`，错误经 `mapBuilderError`）。Builder 缺席时返回 `Error.ParserInvariant`，实际不会发生——`appendDefaultClassConstructor` 在调用它之前必定 `ensureBuilderForFd`。`atom_class_fields_init` 是预定义 atom（借用），`this_idx` 是借用槽号。失败即 `OutOfMemory` / Builder 折叠出的错误，没有局部回滚。调用方 2 处，都在 `appendDefaultClassConstructor`（`:15138` 派生、`:15150` 基类）。

### `appendDefaultClassConstructor` (`src/parser.zig:14600`)

- **签名**：`fn appendDefaultClassConstructor(s: *State, name_atom: Atom) Error!u16`。
- **作用**：为没有显式 constructor 的类合成默认构造器 FunctionDef。
- **实现**：
合成子 FunctionDef：有 extends 则为 derived（`init_ctor` + `put_loc_check_init this` + fields_init + `get_loc_checkthis; return`），否则基类（`check_ctor` + fields_init + `return_undef`）。严格、有 home object。`appendCpool` + `addChild`，返回 cpool 下标给 `define_class`。
- **所有权 / 错误 / 调用**：**本条目里所有权最重的一个**：`s.function.memory.create(FunctionDef)` 新建子 FunctionDef，用 `child_moved` 旗标 + `errdefer if (!child_moved) s.discardFunctionDef(child_fd)` 守到最后——直到 `parent_fd.addChild(child_fd)` 成功才置 `child_moved = true`，此后所有权归父 FunctionDef 的 `child_list`。途中还有三笔持久副作用：两次 `appendScope`、`ensureBuilderForFd(child_fd)`（Builder 挂在子 fd 上）、以及 `parent_fd.appendCpool(JSValue.undefinedValue())` 占一个 cpool 槽并回写 `child_fd.parent_cpool_idx`（**返回值就是这个下标**）。`name_atom` 只是借用 id。错误面：这些分配的 `OutOfMemory`（多处写成 `catch return error.OutOfMemory`）、`this_idx` 越 u16 的 `Error.ParserInvariant`、以及 Builder 经 `mapBuilderError` 的折叠。树内唯一调用方 `parseClass`（`:14857`）。

## 覆盖核对

- 清单函数数（本文件分到）: 195（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 195
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
