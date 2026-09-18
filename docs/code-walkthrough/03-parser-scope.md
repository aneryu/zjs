# 03 — parser 作用域、闭包、标签、模块

`defineVar` 是声明语义的唯一入口。闭包在非 phase-1 路径由 `ensureClosureVar` 物化；生产路径把发现留给 `resolve_variables`。模块 import/export 写 `bytecode.module.Record`。


### `ParseState.pushScopeIdentity` (`src/parser.zig:1422`)

- **签名**：`pub fn pushScopeIdentity(self: *State) Error!void`。
- **作用**：新建一个词法作用域身份并设为当前 `scope_level`，不发任何字节码。
- **实现**：对照 `push_scope`（quickjs.c:23486）：以当前 `scope_level` 为父调 `curFunc().appendScope(parent)` 新建一个 `VarScope`，分配失败转 `error.OutOfMemory`；成功后把新下标同时写进 `self.scope_level` 与 `curFunc().scope_level`（两份必须同步，解析器读前者、`FunctionDef` 侧的登记读后者）。进入一个新词法块时调用。
- **所有权 / 错误 / 调用**：自身不分配：`curFunc().appendScope(parent)` 在 `FunctionDef` 自己的 memory 上扩 `scopes` 数组，任何失败都收敛成 `error.OutOfMemory`（唯一 error）。新 scope 行的所有权在 `FunctionDef`，本函数只改 `scope_level`。调用方必须配 `popScopeIdentity`：`pushScope`(`src/parser.zig:1438`)、`beginFunctionBodyIdentityOnly`(1455) 都写成 `errdefer`，另有块语句 8850、8884。

### `ParseState.pushScope` (`src/parser.zig:1432`)

- **签名**：`pub fn pushScope(self: *State) Error!void`。
- **作用**：新建词法作用域并发出它的 phase-1 进入事件。
- **实现**：`pushScopeIdentity()` → `errdefer popScopeIdentity()` → `emitEnterScope()` 三步。失败时的状态回滚只回滚身份：`emitEnterScope` 没发出去就把作用域弹掉，绝不让一次失败的解析在字节码里留下一个没有配对 enter 的 leave 事件。
- **所有权 / 错误 / 调用**：唯一分配是 `pushScopeIdentity` 里 `appendScope` 在当前 `FunctionDef` 的 memory 上多出的一行 `VarScope`（归 fd，随 fd 释放；失败统一收成 `error.OutOfMemory`）；不碰 atom、不登记 GC 根。`emitEnterScope` 的错误来自 builder 经 `mapBuilderError` 的三元组 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`，此时 `errdefer popScopeIdentity()` 已把身份弹回。调用方是 parser.zig 内 10 处语句解析：`parseBlock`（`src/parser.zig:8556`）、`parseIfStatement`（`src/parser.zig:9226`）、`parseForStatement`（`src/parser.zig:9383`）等。

### `ParseState.beginFunctionBody` (`src/parser.zig:1440`)

- **签名**：`pub fn beginFunctionBody(self: *State) Error!void`。
- **作用**：进入函数体词法作用域并发出对应字节码事件。
- **实现**：先 beginFunctionBodyIdentityOnly，再 emitEnterScope；两步错误均经 try 传播。
- **所有权 / 错误 / 调用**：改变解析器作用域及发射流；若发射失败由外层编译失败路径清理，不应假定本函数回滚已成功的第一步。

### `ParseState.beginFunctionBodyIdentityOnly` (`src/parser.zig:1449`)

- **签名**：`pub fn beginFunctionBodyIdentityOnly(self: *State) Error!void`。
- **作用**：创建函数体作用域身份，不发字节码。
- **实现**：`pushScopeIdentity` 成功后把当前 `scope_level` 写进 `curFunc().body_scope`。原先那条 `errdefer popScopeIdentity()` 后面只剩一条不可失败的赋值，永远不会触发，已删。
- **所有权 / 错误 / 调用**：作用域表由 ParseState 持有；与 beginFunctionBody 的区别是没有 emitEnterScope。

### `ParseState.popScopeIdentity` (`src/parser.zig:1458`)

- **签名**：`pub fn popScopeIdentity(self: *State) void`。
- **作用**：回到父作用域身份，并重算 `scope_first`。
- **实现**：对照 `pop_scope`（quickjs.c:23532）：`scope_level < 0` 时什么也不做；否则读 `curFunc().scopes[scope_level].parent`，把 `self.scope_level` 与 `curFunc().scope_level` 都设成父作用域。之后重算 `scope_first`——先清成 -1，再从父作用域沿 `parent` 链向外走，取第一个 `scopes[i].first >= 0` 写进 `curFunc().scope_first`（对照 `get_first_lexical_var`，quickjs.c:23521），一路没有就留 -1。这一步是必须的：后续的名字查找从 `scope_first` 起步，不重算就会继续看见刚离开的块里的词法变量。
- **所有权 / 错误 / 调用**：不释放任何东西——scope 行留在 `FunctionDef.scopes` 里供后续 pass 用，这里只把 `scope_level` 与 `scope_first` 退回父作用域。不分配、无 error。19 处调用，多数是与 `pushScopeIdentity` 配对的 `errdefer`/`defer`(`src/parser.zig:1439`、1456、1487、8557、8568、8861、8895)。

### `ParseState.popScope` (`src/parser.zig:1479`)

- **签名**：`pub fn popScope(self: *State) Error!void`。
- **作用**：发出当前作用域的 phase-1 离开事件，再恢复父作用域身份。
- **实现**：先 `emitLeaveScope(self.scope_level)` 发出 phase-1 离开事件，成功后才 `popScopeIdentity()`。顺序与 `pushScope` 相反且不可交换：发射用的是即将离开的那个 `scope_level`。
- **所有权 / 错误 / 调用**：不分配也不释放——`VarScope` 行留在 fd 里供 `resolve_variables` 继续读，这里只把 `scope_level` 拨回父作用域。唯一错误来自 `emitLeaveScope`，即 builder 经 `mapBuilderError` 的 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`；与 `pushScope` 不同，这里没有 errdefer：发射失败就不弹身份，整条解析路径已在往上抛。调用方 8 处：`parseBlock`（`src/parser.zig:8559`）、`parseIfStatement`（`src/parser.zig:9268`）、`parseForStatement`（`src/parser.zig:9518`）等。

### `ParseState.addScopeVar` (`src/parser.zig:1491`)

- **签名**：`pub fn addScopeVar( self: *State, name: Atom, kind: function_def_mod.VarKind, is_lexical: bool, is_const: bool, ) Error!i32`。
- **作用**：在 `function_def.vars` 里登记一条变量声明，并同步声明冲突索引。
- **实现**：对照 `add_scope_var`（quickjs.c:23577）：`kind` 与两个 bool 一起决定这一行的性质（`var` 用 normal，`let` 加 `is_lexical`，`const` 再加 `is_const`）。三步：`prepareLinkedDeclarationIndexWrite(fd, name, kind, is_lexical)` 先备好声明冲突索引的写入（它可能要扩容，所以放在不可回滚的 `addScopeVar` 之前），`fd.addScopeVar(name, kind, self.scope_level, is_lexical, is_const)` 在当前词法层登记（分配失败转 `error.OutOfMemory`），`commitLinkedDeclarationIndexWrite(fd, var_index, index_prepared)` 用拿到的下标落账；返回新 var 下标。
- **所有权 / 错误 / 调用**：两处可失败的分配：`prepareLinkedDeclarationIndexWrite` 为 `State` 持有的 `declaration_conflict_indices` 预留容量，`fd.addScopeVar` 在 `FunctionDef` 的 `vars` 上扩数组（错误一律收敛成 `error.OutOfMemory`）。`name` 只是借用的 atom id，行里存 id 不 retain、不释放（编译期由 `CompileAtomScope` 钉住）。调用方：`defineVar` 的三个分支(`src/parser.zig:1728`、1784、1792)、`addPrivateClassBinding`(14003) 等 parser 内 6 处；`src/compiler/*` 里同名的是 `FunctionDef.addScopeVar`，不是本函数。

### `ParseState.atFunctionBodyScope` (`src/parser.zig:1544`)

- **签名**：`fn atFunctionBodyScope(self: *State) bool`。
- **作用**：判断当前作用域是否正是当前函数体作用域。
- **实现**：要求 body_scope>=0 且 scope_level==body_scope。
- **所有权 / 错误 / 调用**：只读函数定义，不分配。

### `ParseState.atProgramBodyScope` (`src/parser.zig:1548`)

- **签名**：`fn atProgramBodyScope(self: *State) bool`。
- **作用**：判断当前是否处于最外层程序的函数体作用域。
- **实现**：要求 cur_func_stack 为空、当前函数 is_eval 为真，并通过 atFunctionBodyScope。
- **所有权 / 错误 / 调用**：只读状态；嵌套函数不会因 scope_level 数字相等而命中。

### `ParseState.isChildScope` (`src/parser.zig:1552`)

- **签名**：`fn isChildScope(self: *State, scope: i32, parent_scope: i32) bool`。
- **作用**：沿 parent 链判断 `scope` 是否在 `parent_scope` 之内（相等也算）。
- **实现**：任一端为负（无效 scope）直接 false；否则从 `scope` 起沿 `scopes[current].parent` 上行，命中 `parent_scope` 即 true（自身也算）。循环同时用 `visited <= scopes.len` 的步数上限和 `current >= scopes.len` 的下标检查兜住被破坏或成环的 parent 链，走到链尾仍未命中返回 false。
- **所有权 / 错误 / 调用**：无：只沿 `scopes[].parent` 上溯，带 `visited` 上限防成环，不分配、无 error。调用方：`findFunctionVarInChildScopeLegacy`(`src/parser.zig:1672`)、`defineVar` 的全局重声明判定(1761)。

### `ParseState.firstGlobalVarIndex` (`src/parser.zig:1565`)

- **签名**：`fn firstGlobalVarIndex(self: *State, name: Atom) ?usize`。
- **作用**：查找当前函数全局声明数组中第一个同名项。
- **实现**：从头扫描 global_vars，var_name==name 时返回 idx，未命中返回 null。
- **所有权 / 错误 / 调用**：返回下标，不转移或复制数组存储。

### `ParseState.findLexicalDeclarationLegacy` (`src/parser.zig:1577`)

- **签名**：`fn findLexicalDeclarationLegacy(self: *State, name: Atom, check_catch: bool) ?LexicalDeclaration`。
- **作用**：QuickJS `find_lexical_decl` 的等价扫描：在当前函数里沿作用域链找同名的词法声明（`let`/`const`/`class`，可选含 catch 参数），是声明冲突检查的权威实现。
- **实现**：对照 QuickJS `find_lexical_decl`（quickjs.c:24087）——后面那份 parser 专用索引正是从这套链式拓扑推导出来的，索引不可用或被标脏时就回退到这里。从 `fd.scope_first` 起沿 `vd.scope_next` 走整条链（`visited <= fd.vars.len` 的步数上限加下标越界检查双重兜底），命中 `var_name == name` 且 `is_lexical`（或 `check_catch` 为真且 `var_kind == .catch_`）就返回 `.{ .local = var_idx }`。链上没有时，只有全局 eval（`is_eval` 且非 direct、非 indirect、非 module）才追加查 `findLexicalGlobalVar`，命中返回 `.global`；其余返回 null。
- **所有权 / 错误 / 调用**：无分配、无 error（返回 optional）：只读当前 `FunctionDef` 的 scope 链与 `global_vars`。它是索引路径失效时的回退实现，调用方 `findLexicalDeclaration` 的两处(`src/parser.zig:1649` 索引报拓扑错、1662 无索引)。

### `ParseState.findIndexedLexicalDeclaration` (`src/parser.zig:1600`)

- **签名**：`fn findIndexedLexicalDeclaration( self: *State, index: *const DeclarationConflictIndex, fd: *const function_def_mod.FunctionDef, name: Atom, check_catch: bool, ) error{InvalidTopology}!?u16`。
- **作用**：借 `DeclarationConflictIndex` 的 `scope_names` 哈希，从当前作用域沿父链找同名词法声明。
- **实现**：从 `self.scope_level` 起沿 `fd.scopes[scope].parent` 上行，每层用 `DeclarationConflictIndex.scopeNameKey(scope, name)` 查 `index.scope_names`：`check_catch` 决定取条目的 `newest_lexical_or_catch` 还是 `newest_lexical`，值不是 `no_declaration_index` 就返回该 var 下标。走到根仍没命中返回 null。作用域步数超过 `fd.scopes.len`、scope 下标越界、key 构造失败、或索引里的 var 下标越过 `fd.vars.len` / `maxInt(u16)`，一律返回 `error.InvalidTopology`——这不是语法错误，而是要求调用方把索引标 dirty 并回退 legacy 链式扫描。
- **所有权 / 错误 / 调用**：不分配：只读 `DeclarationConflictIndex`（`State` 拥有，`declaration_conflict_indices` 在 `State.deinit` 释放）。错误集被刻意收窄成 `error{InvalidTopology}`——scope 越界、key 构造失败、行号越界都归它，由调用方把索引标 `dirty` 并回退 legacy 扫描，永远不会变成 JS 语法错误。唯一调用方 `findLexicalDeclaration`(`src/parser.zig:1647`)。

### `ParseState.findLexicalDeclaration` (`src/parser.zig:1634`)

- **签名**：`fn findLexicalDeclaration( self: *State, name: Atom, check_catch: bool, ) Error!?LexicalDeclaration`。
- **作用**：词法声明冲突检查的统一入口：查当前位置可见的同名 `let`/`const`/`class`（可选含 catch 参数）声明，有索引走索引、没有或索引坏了回退线性扫描。
- **实现**：`declarationConflictIndex(fd)` 给出索引时走 `findIndexedLexicalDeclaration`，它一旦报 `InvalidTopology` 就把 `index.dirty = true` 并整体回退 `findLexicalDeclarationLegacy`；索引查到下标即包成 `.{ .local = var_index }`。索引没查到时补一条 `.global` 回退：仅限全局 eval（`fd.is_eval` 且非 direct、非 indirect、非 module）且 `findLexicalGlobalVar(name)` 成立。索引整体不可用时直接走 legacy。两条路径的判据完全一致，索引只是把链式扫描换成哈希查表。
- **所有权 / 错误 / 调用**：自身不分配，但 `declarationConflictIndex` 可能为这个 `fd` 现建一份索引（分配在 `function.memory.allocator`，所有权归 `State`），OOM 上抛；`findIndexedLexicalDeclaration` 的 `InvalidTopology` 在这里就地降级成 `index.dirty = true` + legacy 回退，不外泄。所以对外的 error 只有 `error.OutOfMemory`。调用方：`defineVar` 的 lexical 分支(`src/parser.zig:1731`)与 `var` 分支(1795)。

### `ParseState.findFunctionVarInChildScopeLegacy` (`src/parser.zig:1663`)

- **签名**：`fn findFunctionVarInChildScopeLegacy(self: *State, name: Atom, scope_level: i32) ?u16`。
- **作用**：找一条「声明位置在给定作用域之内」的函数级 `var` 行——Annex B 把块内函数声明提升成函数级 var 时，要靠它判断是否已经有这条提升行。
- **实现**：对照 QuickJS `find_var_in_child_scope`（quickjs.c:24048）：函数 `var` 始终是 scope 0 的一行，但在最终重建 scope 链接之前，它的 `scope_next` 字段存的是声明实际发生的词法作用域，因此这类行有意不挂在 `scope.first` 链上、链式扫描看不见它们。实现是对 `curFunc().vars` 的线性扫描：跳过名字不符或 `scope_level != 0` 的行，再用 `isChildScope(vd.scope_next, scope_level)` 判断原始声明位置是否落在给定作用域内，命中即返回其下标。
- **所有权 / 错误 / 调用**：无分配、无 error：线性扫 `vars` 并用 `isChildScope` 过滤。调用方是 `findFunctionVarInChildScope` 的三条回退路径(`src/parser.zig:1686`、1695、1702)。

### `ParseState.findFunctionVarInChildScope` (`src/parser.zig:1671`)

- **签名**：`fn findFunctionVarInChildScope( self: *State, name: Atom, scope_level: i32, ) Error!?u16`。
- **作用**：同 `findFunctionVarInChildScopeLegacy`，但优先用 `DeclarationConflictIndex` 里预先算好的 `oldest_child_function_var` 直接取答案。
- **实现**：`declarationConflictIndex(fd)` 给出索引时用 `scopeNameKey(scope_level, name)` 查 `scope_names`：key 构造失败、或条目里的 `oldest_child_function_var` 越过 `fd.vars.len` / `maxInt(u16)`，都先把 `index.dirty = true` 再回退 `findFunctionVarInChildScopeLegacy`；条目存在且下标合法就直接返回，条目缺失或值为 `no_declaration_index` 时返回 null。索引不可用时整体走 legacy 线性扫描。
- **所有权 / 错误 / 调用**：同 `findLexicalDeclaration`：索引由 `declarationConflictIndex` 提供（可能现建，OOM 上抛），key 构造失败或行号越界就标 `dirty` 回退 legacy 实现，因此对外 error 只有 `error.OutOfMemory`。唯一调用方 `defineVar`(`src/parser.zig:1755`)。

### `ParseState.appendFunctionVarAtOrigin` (`src/parser.zig:1699`)

- **签名**：`fn appendFunctionVarAtOrigin(self: *State, name: Atom, origin_scope: i32) Error!u16`。
- **作用**：把一条函数级 `var` 追加成 scope-0 行，用 `scope_next` 记住声明发生的作用域。
- **实现**：与 `addScopeVar` 同样的 prepare/commit 夹心，但登记的是一行函数级 `var`：`fd.appendVar` 时 `scope_level` 固定写 0（函数的 var/arg 层），`scope_next` 记住声明真正发生的那个 `origin_scope`，`is_lexical` / `is_const` 均为 false、`var_kind = .normal`。索引写入由 `prepareFunctionVarOriginIndexWrite` / `commitFunctionVarOriginIndexWrite` 这一对负责（commit 还要吃 `origin_scope`）；返回值窄化成 `u16`。
- **所有权 / 错误 / 调用**：两处分配：`prepareFunctionVarOriginIndexWrite` 的索引预留与 `fd.appendVar`（收敛成 `error.OutOfMemory`）；`name` 借用，行里只存 id。返回 `vars` 下标，不是所有权。调用方 5 处：`defineVar` 的 var 分支(`src/parser.zig:1815`)、`ensureFunctionScopeVar`(1880)、eval 返回槽(1983、10145)、13505。

### `ParseState.defineVar` (`src/parser.zig:1718`)

- **签名**：`pub fn defineVar(self: *State, name: Atom, var_def_type: DefineVarType) Error!DefinedVar`。
- **作用**：声明语义唯一入口：处理冲突并选出 local/argument/global 绑定。
- **实现**：
声明语义的唯一入口，对照 `quickjs.c:24303` `define_var`。按 `DefineVarType`：

- `.with_`：当前 with 作用域 `addScopeVar`（非词法）。
- `.let_` / `.const_` / `.function_decl` / `.new_function_decl`：先 `findLexicalDeclaration(..., check_catch=true)`。同层冲突除非非严格函数再声明；catch 绑定与 `scope_level+2` 也冲突。函数体作用域上与形参冲突（函数声明除外）。`findFunctionVarInChildScope` 命中则冲突。`is_global_var` 时再查 `global_vars` 子作用域。eval 程序体（非 direct/indirect）的词法走到 `addGlobalVar` 返回 `.global`，否则 `addScopeVar` 返回 `.local`。
- `.catch_`：`VarKind.catch_` 的 scope var。
- `.var_`：与词法声明冲突则失败；`is_global_var` 则 `addGlobalVar`（模块同层词法 global 仍冲突）；否则复用 `findFunctionScopeVar` / 形参，或 `appendFunctionVarAtOrigin` 挂到 scope-0，名字 `arguments` 且 `has_arguments_binding` 时回写 `arguments_var_idx`。

所有冲突都走 `failExpectedDescription("non-conflicting declaration")`；`findLexicalDeclaration` 命中 `.global` 时，只有正处在函数体作用域才算冲突。
物理结果是 `DefinedVar{local,argument,global}`，不把 C 的 ARGUMENT/GLOBAL_VAR_OFFSET 哨兵引进 Zig。
- **所有权 / 错误 / 调用**：自己不分配，写入都在 `addScopeVar` / `addGlobalVar` / `appendFunctionVarAtOrigin`（各自的 `error.OutOfMemory`）。`name` 是借用 atom id，登记进 `vars`/`global_vars` 只存 id。本函数特有的错误面是重复声明：8 个判定点全部走 `failExpectedDescription("non-conflicting declaration")`，即写了 pending 诊断的 `error.UnexpectedToken`。parser 内约 24 处调用（catch 参数 `src/parser.zig:9827`、绑定/形参/类名/`using` 等）；`src/tests/parser.zig` 里的调用属测试。

### `ParseState.scopeHasVar` (`src/parser.zig:1818`)

- **签名**：`fn scopeHasVar(self: *State, scope_idx: i32, name: Atom) bool`。
- **作用**：某个作用域里是否直接声明过这个名字（只走该作用域自己的链，不看父作用域）。
- **实现**：`scope_idx` 为负或越过 `scopes.len` 直接 false。否则从 `scopes[scope_idx].first` 起沿 `var_def.scope_next` 走：一旦某行的 `scope_level != scope_idx` 就 `break`（链已经越到父作用域的行上），期间 `var_name == name` 即 true。只看本作用域自己的那一段链，不上行。
- **所有权 / 错误 / 调用**：无：沿单个 scope 的 `first`/`scope_next` 链走一遍，不分配、无 error。唯一调用方：Annex-B 判定 `src/parser.zig:11782`。

### `ParseState.visibleLexicalScopeVar` (`src/parser.zig:1830`)

- **签名**：`fn visibleLexicalScopeVar(self: *State, name: Atom) ?u16`。
- **作用**：从当前作用域沿父链找第一个可见的同名词法绑定，返回其 var 下标。
- **实现**：双层循环：外层从 `self.scope_level` 沿 `scopes[scope_idx].parent` 上行，内层与 `scopeHasVar` 同形地走本层的 `first` / `scope_next` 链，遇到 `scope_level != scope_idx` 的行即退出本层。内层命中 `var_name == name` 且 `is_lexical` 时返回该 var 下标——先内层后上行，保证拿到的是最内层可见的那条遮蔽绑定。全链无命中返回 null。
- **所有权 / 错误 / 调用**：无：外层 scope 链 + 每层链表的双重循环，不分配、无 error。调用方 `src/parser.zig:11709`、11737（函数声明的可见 lexical 冲突判定）。

### `ParseState.findLexicalGlobalVar` (`src/parser.zig:1847`)

- **签名**：`fn findLexicalGlobalVar(self: *State, name: Atom) bool`。
- **作用**：判断某个名字在全局层是否已有词法声明（顶层 `let`/`const`），用于全局 eval 的重声明检查。
- **实现**：对照 qjs `find_lexical_global_var`（quickjs.c:24078）：线性扫 `curFunc().global_vars`，要求同名且 `is_lexical`——也就是以 `JS_CLOSURE_GLOBAL_DECL` 形式声明的顶层 `let`/`const`。
- **所有权 / 错误 / 调用**：无：线性扫 `curFunc().global_vars`，不分配、无 error。调用方：两条 lexical 查找的 eval 分支(`src/parser.zig:1599`、1656)、11741。

### `ParseState.findGlobalVar` (`src/parser.zig:1856`)

- **签名**：`fn findGlobalVar(self: *State, name: Atom) bool`。
- **作用**：判断某个名字在全局层是否已被登记过（不论哪种声明形态）。
- **实现**：对照 qjs `find_global_var`（quickjs.c:24066）：线性扫 `curFunc().global_vars`，只比名字——顶层 `var`、提升的函数声明、词法声明都算命中。
- **所有权 / 错误 / 调用**：无：同上但不看 `is_lexical`，不分配、无 error。唯一调用方：direct eval 的 var-object 登记前查重 `src/parser.zig:12059`。

### `ParseState.ensureFunctionScopeVar` (`src/parser.zig:1865`)

- **签名**：`fn ensureFunctionScopeVar(self: *State, name: Atom) Error!u16`。
- **作用**：取当前函数 scope-0（函数级 var/arg 层）里叫 `name` 的行，没有就补建一条并返回其下标。
- **实现**：先 `findFunctionScopeVar(name)`，命中直接返回。没有现成的 scope-0 行时用 `appendFunctionVarAtOrigin(name, 0)` 补一条：Annex B 的 `create_func_var` 路径直接走 `add_var`，这行本来就不挂进 scope 0 的词法链，origin 取 QuickJS 零初始化行留下的 0。（源码上方那段描述 `define_var` `is_global_var` 重定义检查的注释与本 helper 无关，已换成描述本函数行为的注释。）
- **所有权 / 错误 / 调用**：自身不分配；未命中时由 `appendFunctionVarAtOrigin` 追加一行（`error.OutOfMemory`，也是唯一 error）。唯一调用方：Annex-B 函数声明的 var 复制 `src/parser.zig:12060`。

### `ParseState.findFunctionScopeVar` (`src/parser.zig:1873`)

- **签名**：`fn findFunctionScopeVar(self: *State, name: Atom) ?u16`。
- **作用**：在当前函数的 scope-0（函数级 var/arg 层）里找同名行，从后往前取最新一条。
- **实现**：对 `curFunc().vars` 从尾往头倒扫，返回第一条 `var_name == name` 且 `scope_level == 0` 的下标。倒序保证拿到的是最新追加的那条函数级行（同名 `var` 可以重复声明）。
- **所有权 / 错误 / 调用**：无分配、无 error：倒序扫 `vars` 找 `scope_level == 0` 的行，后声明优先。调用方 4 处：`defineVar`(`src/parser.zig:1811`)、`ensureFunctionScopeVar`(1876)、11695、13499。

### `ParseState.addGlobalVar` (`src/parser.zig:1883`)

- **签名**：`fn addGlobalVar(self: *State, name: Atom, is_lexical: bool, is_const: bool) Error!void`。
- **作用**：为全局脚本 / 全局 eval 的顶层声明追加一条 `global_vars` 记录（`var`、函数声明、`let`、`const` 都经这里），运行时据此在全局对象或全局词法环境上建绑定。
- **实现**：一次 `curFunc().appendGlobalVar`：`cpool_idx = -1`（不是函数声明，没有对应的常量池函数体）、`force_init = false`、`scope_level` 取当前作用域、`is_lexical` / `is_const` 由调用方给；`is_configurable` 只在 `eval_global_var_bindings` 为真且本次不是词法声明时成立——全局 eval 里 `var` 建的绑定可以 `delete`，脚本顶层的不行。追加失败转 `error.OutOfMemory`。
- **所有权 / 错误 / 调用**：`fd.appendGlobalVar` 在 `FunctionDef` 的 memory 上扩 `global_vars`，错误收敛成 `error.OutOfMemory`（唯一 error）；`name` 借用。调用方 3 处：`defineVar` 的两条 global 分支(`src/parser.zig:1775`、1808)、12037。

### `ParseState.addGlobalAnnexBFunctionVar` (`src/parser.zig:1895`)

- **签名**：`fn addGlobalAnnexBFunctionVar(self: *State, name: Atom, is_configurable: bool) Error!void`。
- **作用**：为 Annex B 的块内函数声明在全局层补一条非词法的 `global_vars` 记录，`is_configurable` 由调用方按声明形态给。
- **实现**：同样一次 `appendGlobalVar`，但字段固定：`scope_level = 0`、`is_lexical = false`、`is_const = false`、`force_init = false`，`is_configurable` 由参数给。`force_init` 必须为 false——qjs 只在 strict 代码里强制 Annex B 的 var 拷贝，而 Annex B 本身是 sloppy 规则，这条声明不能被归类成全局函数初始化器。
- **所有权 / 错误 / 调用**：分配与错误同 `addGlobalVar`（`appendGlobalVar` 的 `error.OutOfMemory`）；差别只在写入的标志：`force_init = false`、`scope_level = 0`、`is_configurable` 由调用方给。唯一调用方：Annex-B 全局函数声明 `src/parser.zig:12058`。

### `ParseState.addDirectEvalVarObjectVar` (`src/parser.zig:1910`)

- **签名**：`fn addDirectEvalVarObjectVar(self: *State, name: Atom) Error!void`。
- **作用**：direct eval 里的 `var` / 函数声明：在调用者的变量对象上登记一条可配置（可被 `delete`）的绑定。
- **实现**：一次 `appendGlobalVar`，`force_init = true`、`is_configurable = true`、`scope_level = 0`、非词法非 const：direct eval 往调用者变量对象上加的绑定必须每次进入 eval 时初始化，并且按规范可以被 `delete`。
- **所有权 / 错误 / 调用**：同族的第三个：`appendGlobalVar` 的 `error.OutOfMemory`；写入 `force_init = true` / `is_configurable = true` / `scope_level = 0`。唯一调用方 `src/parser.zig:12059`（direct eval 的 var-object 绑定）。

### `ParseState.emitGlobalScopePutVar` (`src/parser.zig:1923`)

- **签名**：`fn emitGlobalScopePutVar(self: *State, atom_id: Atom) Error!void`。
- **作用**：Annex B 的全局函数绑定更新专用的赋值发射：绕过所有块级/函数局部，最终降成 `put_var`。
- **实现**：一条 `Emitter.opAtomU16(scope_put_var, atom_id, std.math.maxInt(u16))`。作用域操作数填满 u16 是给 resolver 用的哨兵（源码注释按有符号写作 `scope_level = -1`），意思是「不要在任何作用域里解析这个名字」，降级后就是全局 `put_var`。
- **所有权 / 错误 / 调用**：不分配长期对象：atom 以**借用 id** 写进 code 流与 builder 的 `atom_operands`（编译期由 `CompileAtomScope` 钉住，`...Owned` 只是历史命名，没有 retain）。错误来自 builder，经 `mapBuilderError` 收成 `error.OutOfMemory` / `error.BytecodeOverflow` / `Error.ParserInvariant`（后者对应 builder 的 `InvalidBytecode` 失败闭合）。调用方：Annex-B 全局函数绑定更新 `src/parser.zig:12091`、12116。

### `ParseState.emitEvalVarObjectScopePutVar` (`src/parser.zig:1930`)

- **签名**：`fn emitEvalVarObjectScopePutVar(self: *State, atom_id: Atom) Error!void`。
- **作用**：Annex B 里把块内函数名拷回函数级 `var` 的那次赋值的发射，落点必须是 eval 声明环境而不是块级词法绑定。
- **实现**：同样一条 `scope_put_var <atom>`，但作用域操作数填 0 而不是哨兵：scope 0 把块内那个同名函数绑定排除在外，同时保留编译器种下的 `_var_` / `_arg_var_` 伪局部和调用者闭包里的确切目标——直接用哨兵会连 eval 声明环境一起跳过。
- **所有权 / 错误 / 调用**：同 `emitGlobalScopePutVar`（借用 atom、builder 三元错误），区别只在 scope 操作数写 0 而不是 `maxInt(u16)`。调用方：Annex-B 的 eval var-object 赋值 `src/parser.zig:12095`、12119。

### `ParseState.enableEvalReturn` (`src/parser.zig:1959`)

- **签名**：`pub fn enableEvalReturn(self: *State) Error!void`。
- **作用**：启用 eval 的完成值和可删除绑定处理。
- **实现**：设置 ParseState 与当前 FunctionDef 的 is_eval，再设 eval_delete_bindings，最后 enableReturnCompletion。
- **所有权 / 错误 / 调用**：最后一步可能失败；本函数不恢复已设置的模式标志，外层按编译失败处理。

### `ParseState.enableReturnCompletion` (`src/parser.zig:1969`)

- **签名**：`pub fn enableReturnCompletion(self: *State) Error!void`。
- **作用**：在不改变声明语义的前提下打开表达式语句的完成值捕获（全局脚本返回完成值用）。
- **实现**：用 `appendFunctionVarAtOrigin(eval_ret_atom, 0)` 建 `<ret>` 伪局部——注释点明这里对应 `js_parse_program` 用的是 `add_var` 而非 `add_scope_var`：`<ret>` 是 scope-0 伪局部，绝不能成为程序体真正词法链的头。拿到的下标同时写进 `self.eval_ret_idx` 与 `curFunc().eval_ret_idx`，再发 `undefined` + `emitEvalRetPut` 把槽位初始化掉，使没有任何表达式的空脚本也有合理完成值。之后所有读写一律按槽位发射，因为每个语法 finally 都会再加一个同名 `<ret>` 保存槽，按名字查会歧义。
- **所有权 / 错误 / 调用**：`appendFunctionVarAtOrigin` 在 `curFunc().vars` 上加一行（内存归 fd），`eval_ret_atom` 是预定义 id、借用不 retain。错误有两类：vars 追加与索引写入一律收成 `error.OutOfMemory`；两条发射经 `mapBuilderError` 还可能是 `BytecodeOverflow` / `ParserInvariant`。树内调用方只有 `enableEvalReturn`（`src/parser.zig:1973`）与 `compileQjsProgram`（`src/parser.zig:16261`），其余 5 处在 `src/compiler/tests.zig`。

### `ParseState.emitEvalRetGet` (`src/parser.zig:1983`)

- **签名**：`fn emitEvalRetGet(self: *State) Error!void`。
- **作用**：把 eval 完成值槽 `<ret>` 里的值压栈。
- **实现**：`eval_ret_idx < 0`（本次编译没开完成值捕获）时什么都不发；否则发一条 `get_loc <eval_ret_idx>`。按槽号而不是按名字发射：每个语法上的 `finally` 都会再加一个同名 `<ret>` 保存槽，名字查找从第二个起就有歧义。
- **所有权 / 错误 / 调用**：不分配；`eval_ret_idx < 0` 时直接返回，所以非 eval 编译里是 no-op。错误来自 builder：`error.OutOfMemory` / `error.BytecodeOverflow` / `Error.ParserInvariant`。调用方：`src/parser.zig:2009`、finally 路径 10147。

### `ParseState.emitEvalRetPut` (`src/parser.zig:1988`)

- **签名**：`fn emitEvalRetPut(self: *State) Error!void`。
- **作用**：把栈顶的值存进 eval 完成值槽 `<ret>`。
- **实现**：`eval_ret_idx < 0` 时不发；否则发一条 `put_loc <eval_ret_idx>`，同样按槽号寻址。语句级的完成值更新（`setEvalReturnUndefined`、表达式语句的结果写回）都经这里。
- **所有权 / 错误 / 调用**：同 `emitEvalRetGet`：无分配，非 eval 时 no-op，错误来自 builder 三元组。10 处调用，都是「语句完成值写回 eval 返回槽」(`src/parser.zig:1990`、2019、8599、9041、9165、9186、9203 等)。

### `ParseState.finalizeEvalReturn` (`src/parser.zig:1997`)

- **签名**：`pub fn finalizeEvalReturn(self: *State) Error!void`。
- **作用**：将 eval 完成值作为函数返回值发射。
- **实现**：eval_ret_idx<0 时不发码；否则 emitEvalRetGet，再发 return opcode。
- **所有权 / 错误 / 调用**：只改变发射流；发射分配错误向上传播。

### `ParseState.setEvalReturnUndefined` (`src/parser.zig:2006`)

- **签名**：`pub fn setEvalReturnUndefined(self: *State) Error!void`。
- **作用**：把 eval 完成值重置为 undefined（控制流语句在解析子结构前调用）。
- **实现**：`eval_ret_idx < 0`（没开完成值捕获）直接返回，不发任何码；否则发 `undefined` 再 `emitEvalRetPut`。对照 QuickJS `set_eval_ret_undefined`（quickjs.c:28219-28226）：控制流语句在解析自己的子结构之前先把完成值清空，真正执行到的表达式语句再覆盖它。
- **所有权 / 错误 / 调用**：不分配、不碰 atom；`eval_ret_idx < 0` 的早退路径连 error 都不可能产生。唯一错误来自两条 Emitter 发射（builder 三元组 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`）。调用方 7 处控制流语句解析：`parseIfStatement`（`src/parser.zig:9228`）、`parseDoOrWhileStatement`（`src/parser.zig:9283`）、`parseForStatement`（`src/parser.zig:9343`）等。

### `ParseState.emitReturnUndefined` (`src/parser.zig:2012`)

- **签名**：`pub fn emitReturnUndefined(self: *State) Error!void`。
- **作用**：给脚本或函数体尾部补上隐式的 `return undefined` 终结指令。
- **实现**：无条件发一条 `opcode.op.return_undef`，对应 qjs `js_parse_program` / 函数解析收尾处的隐式终结（quickjs.c:31459、quickjs.c:36946）。调用点先用 `isLiveCode` 判断落点是否可达；与 `finalizeEvalReturn` 二选一——编译走 `return_completion` 时改发 `get_loc <ret>` + `return`。
- **所有权 / 错误 / 调用**：不分配；错误只来自 builder（`error.OutOfMemory` / `error.BytecodeOverflow` / `Error.ParserInvariant`）。parser 内调用方两处：函数体尾的活代码判定 `src/parser.zig:8015` 与程序尾 16302；其余 14 处在 `src/tests/parser.zig`。

### `ParseState.hasActiveLabel` (`src/parser.zig:2260`)

- **签名**：`fn hasActiveLabel(s: *State, atom_id: Atom) bool`。
- **作用**：当前是否有同名的活动标签帧。
- **实现**：正序线性扫 `s.label_frames.items`，任一帧 `frame.atom == atom_id` 即 true。只答存在性；要拿帧下标用 `findLabelFrame`。
- **所有权 / 错误 / 调用**：无分配、无 error：线性扫 `State.label_frames`（列表与每帧的 fixup 都由 `State` 拥有）。唯一调用方：重复 label 检测 `src/parser.zig:8963`。

### `ParseState.pushLabelFrame` (`src/parser.zig:2267`)

- **签名**：`fn pushLabelFrame(s: *State, atom_id: Atom, allow_continue: bool) Error!usize`。
- **作用**：为带标签的语句压一个 `LabelFrame`，并预分配它的 break / continue 标签。
- **实现**：标签分配顺序与 qjs `push_break_entry` 一致：`allow_continue` 为真时先 `emitterNewLabel` 建 continue 标签，再建 break 标签（不允许 continue 的语句只有 break 标签）。然后向 `label_frames` 追加一个 `LabelFrame`，同时记下 `catch_marker_depth`（当前 catch 标记深度）、`control_frame_depth`（此刻的 continue 帧数）与 `break_frame_depth`（break 帧数），供跨帧 `break`/`continue` 计算要清理多少层。返回新帧下标。
- **所有权 / 错误 / 调用**：新帧用 `s.function.memory.allocator` 追加进 `s.label_frames`，`LabelFrame` 自带 `break_fixups` / `continue_fixups` 两条 list，**必须**由 `popLabelFrame` 释放（直接 `pop()` 会泄漏这两条 list）；两个 LabelId 只是 Builder 的句柄，归 Builder，`atom_id` 借用不 retain。错误：`emitterNewLabel` 的 builder 三元组 + append 的 `error.OutOfMemory`；标签先建后 append，append 失败不回收标签——零引用的死标签由 `resolve_labels_v2` 丢弃。调用方 5 处：`parseStatementOrDeclSlow`（`src/parser.zig:8977`）、`parseDoOrWhileStatement`（`src/parser.zig:9299`）、`parseForStatement`（`src/parser.zig:9489`），另有 `parseSwitchStatement:9576` 与 `parseForInOf:10977`。

### `ParseState.patchLabelBreaks` (`src/parser.zig:2284`)

- **签名**：`fn patchLabelBreaks(s: *State, frame_index: usize) Error!void`。
- **作用**：把标签帧的 break 汇合标签绑定到当前位置。
- **实现**：帧里有 `break_label` 就 `emitterBindLabel` 绑到当前位置，没有则什么也不做。对照 qjs `emit_label(label_break)`：汇合标签无条件绑定，哪怕零引用——死标签留给 `resolve_labels_v2` 丢弃。
- **所有权 / 错误 / 调用**：不分配、不转移所有权（只读一次帧里的 `break_label`）。唯一错误来自 `emitterBindLabel` 经 `mapBuilderError`：重复绑定或外来标签这类 Builder fail-closed 会变成 `Error.ParserInvariant`，其余是 `OutOfMemory` / `BytecodeOverflow`。调用方 5 处：`parseStatementOrDeclSlow`（`src/parser.zig:8996`）、`parseDoOrWhileStatement`（`src/parser.zig:9322`）、`parseForStatement`（`src/parser.zig:9510`）等。

### `ParseState.patchLabelContinues` (`src/parser.zig:2292`)

- **签名**：`fn patchLabelContinues(s: *State, frame_index: usize) Error!void`。
- **作用**：把标签帧的 continue 汇合标签绑定到当前位置。
- **实现**：与 `patchLabelBreaks` 同形，绑的是帧里的 `continue_label`（`allow_continue` 为假时该字段是 null，直接跳过）。同样对照 qjs `emit_label(label_cont)` 的无条件绑定。
- **所有权 / 错误 / 调用**：与 `patchLabelBreaks` 完全同族——不分配，错误只有 `emitterBindLabel` 经 `mapBuilderError` 的 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`。调用方 3 处，都在带 continue 目标的循环收尾：`parseDoOrWhileStatement`（`src/parser.zig:9306`）、`parseForStatement`（`src/parser.zig:9499`）、`parseForInOf`（`src/parser.zig:11033`）。

### `ParseState.popLabelFrame` (`src/parser.zig:2300`)

- **签名**：`fn popLabelFrame(s: *State, frame_index: usize) void`。
- **作用**：弹出并释放最内层 `LabelFrame`。
- **实现**：先 `std.debug.assert(frame_index + 1 == s.label_frames.items.len)` 钉死栈纪律（只能弹栈顶），再对该帧调 `deinit(s.function.memory.allocator)` 释放它自己持有的列表，最后 `s.label_frames.pop().?` 摘掉。
- **所有权 / 错误 / 调用**：真正的释放点：`LabelFrame` 自带 `break_fixups` / `continue_fixups` 两条列表，必须经 `frame.deinit(allocator)` 再出栈，直接 `pop()` 会泄漏；断言只允许弹栈顶。不分配、无 error。调用方 6 处：`src/parser.zig:8978`(errdefer)/8997、9323、9511、9744、11068。

### `ParseState.findLabelFrame` (`src/parser.zig:2306`)

- **签名**：`fn findLabelFrame(s: *State, atom_id: Atom) ?usize`。
- **作用**：从内向外在 `label_frames` 里找名字匹配的标签帧下标。
- **实现**：从 `label_frames` 尾部往前倒扫，返回第一条 `atom == atom_id` 的下标；倒序即由内向外，命中最近的那层同名标签。找不到返回 null，调用方据此报 `failUndefinedLabel`。
- **所有权 / 错误 / 调用**：无分配、无 error：倒序找最近的同名 label 帧。两个调用方对「找不到」的处理不同：`controlTargetCrossesFinallyFrame`(`src/parser.zig:10100`) 当作 `Error.ParserInvariant`，`resolveFinallyControlTarget`(10332) 报 `failUndefinedLabel`。

### `ParseState.emitLabelledBreak` (`src/parser.zig:2315`)

- **签名**：`fn emitLabelledBreak(s: *State, atom_id: Atom) Error!void`。
- **作用**：发射 `break label;`——把带标签的 break 变成一次穿过中间 finally 与环境清理的跳转。
- **实现**：整个函数就是把参数包成 `FinallyControlTarget{ .kind = .@"break", .label_atom = atom_id }` 交给 `emitControlThroughFinally`；目标解析、跨越环境的 iterator/drop 清理、gosub 穿 finally 全在那里。
- **所有权 / 错误 / 调用**：不分配；`atom_id` 只作 `findLabelFrame` 的比较键，借用不 retain。错误全部由 `emitControlThroughFinally` 产生：标签查不到走 `failUndefinedLabel` → `failWithMessage` 的 `error.UnexpectedToken`（消息 `undefined label '…'`，atom 名字查不到时退化成 `error.ParserInvariant`），记账与环境链失配是 `Error.ParserInvariant`，发射失败是 builder 三元组。唯一调用方 `parseBreakOrContinueStatement`（`src/parser.zig:9539`）。

### `ParseState.emitLabelledContinue` (`src/parser.zig:2319`)

- **签名**：`fn emitLabelledContinue(s: *State, atom_id: Atom) Error!void`。
- **作用**：发射 `continue label;`，与 `emitLabelledBreak` 只差目标种类。
- **实现**：包成 `FinallyControlTarget{ .kind = .@"continue", .label_atom = atom_id }` 交给 `emitControlThroughFinally`。
- **所有权 / 错误 / 调用**：同 `emitLabelledBreak`，不分配、atom 借用；额外一条自 `resolveFinallyControlTarget`：标签帧不允许 continue 或没有 continue 帧时报 `continue must target a loop label` 的 `error.UnexpectedToken`。唯一调用方 `parseBreakOrContinueStatement`（`src/parser.zig:9541`）。

### `ParseState.labelStartAtomOwned` (`src/parser.zig:2323`)

- **签名**：`fn labelStartAtomOwned(s: *State) ?Atom`。
- **作用**：当前位置若是 `label:` 形式就返回标签 atom，否则 null。
- **实现**：三道闸：当前 token 不是「像标识符」的（`isIdentifierLikeToken`）返回 null；`peekNextKind()` 不是 `':'` 返回 null（那是普通表达式起始而非标签）；是 `TOK_IDENT` 且带转义、而该名字在当前上下文里是保留字（`escapedIdentifierIsReservedWordForCurrentContext`）也返回 null。都过了返回 `identifierLikeAtom(s)`——那是一个借用的 atom id，TGC S3-c 之后 `advance` 只换 token payload 不碰 atom，id 由整场编译的 `CompileAtomScope` 钉住，所以调用方可以把它存进 label 帧一直用到语句结束。
- **所有权 / 错误 / 调用**：返回的是**借用**的 atom id（来自 `identifierLikeAtom`），调用方不释放——名字要存进 label 帧并活到语句结束，靠的是 `CompileAtomScope` 在整场编译内钉住该 id，不是 token；函数名里的 "Owned" 是 rc 时代遗留。前瞻用的 `peekNextKind` 自己释放 peek token 并回滚游标。不分配、无 error。唯一调用方 `src/parser.zig:8959`。

### `ParseState.isReservedLabelIdentifier` (`src/parser.zig:2332`)

- **签名**：`fn isReservedLabelIdentifier(s: *State, atom_id: Atom) bool`。
- **作用**：这个名字在当前上下文里是否被保留、不能当标签（module/async/static block 里的 `await`，generator 或 strict 里的 `yield`）。
- **实现**：一条五项析取，全部用 `atomNameEquals` 比名字：`await` 在 module（`lex.is_module`）、async 函数（`in_async`）、class static block（`in_class_static_block`）三种上下文里保留；`yield` 在 generator（`in_generator`）或 strict（`is_strict` 或 `curFunc().is_strict_mode`）下保留。
- **所有权 / 错误 / 调用**：无分配、无 error：五条上下文判定，名字比较走 `atomNameEquals`（借 atom 表字节）。唯一调用方 `src/parser.zig:8962`，紧跟在 `labelStartAtomOwned` 之后。

### `ParseState.deinitCurrentControlFrames` (`src/parser.zig:2340`)

- **签名**：`fn deinitCurrentControlFrames(s: *State) void`。
- **作用**：释放当前函数层的全部 break / continue / label / using 帧列表。
- **实现**：用 `s.function.memory.allocator` 顺序 `deinit` 六组 break 侧列表（`break_fixups`、`break_frame_lens`、`break_frame_labels`、`break_frame_catch_marker_depths`、`break_frame_cleanup_drops`、`break_frame_cross_cleanup_drops`）与六组 continue 侧列表（`continue_fixups`、`continue_frame_lens`、`continue_frame_labels`、`continue_frame_break_frame_indices`、`continue_frame_catch_marker_depths`、`continue_frame_cleanup_drops`）；`label_frames` 要先逐个 `frame.deinit(allocator)` 再释放数组本身（标签帧自己还持有资源）；最后 `using_block_frames`。
- **所有权 / 错误 / 调用**：释放当前函数层持有的 14 条列表 backing（6 条 break 并行数组 + 6 条 continue 并行数组 + `label_frames` + `using_block_frames`），外加每个 `LabelFrame` 自己的两条 fixup 列表；不碰 `FunctionDef`、不碰已发射的字节码，也不重置字段（调用方紧接着整体覆盖）。不分配、无 error。唯一调用方 `leaveControlBoundary`(`src/parser.zig:2412`)——`State.deinit` 走的是 1042 一带自己那份释放序列。

### `ParseState.enterControlBoundary` (`src/parser.zig:2361`)

- **签名**：`fn enterControlBoundary(s: *State) ControlFrames`。
- **作用**：进入新的函数边界：把十七项控制帧状态整组搬进返回值并清空，使内层函数看不见外层的 break/continue/标签。
- **实现**：先把 `ControlFrames` 的十七个字段从 `s` 上逐项复制进 `saved`（`top_break`、六组 break 列表、六组 continue 列表、`label_frames`、`pending_label_atom`、`active_catch_marker_depth`、`using_block_frames`），再把 `s` 上对应字段整批置成 `.empty` / null / 0 后返回 `saved`。这是所有权移交而不是拷贝：列表的堆内存跟着 `saved` 走，`s` 换上空列表，因此内层函数既看不见也不会改到外层的 fixup 与标签帧。
- **所有权 / 错误 / 调用**：不分配、无 error，但**是所有权转移点**：17 个控制流字段（14 条列表 + `top_break`／`pending_label_atom`／`active_catch_marker_depth` 三个标量）整体搬进返回的 `ControlFrames` 纯值，`State` 侧一律置 `.empty`。返回值必须交给 `leaveControlBoundary`，否则那批 backing 泄漏。调用方：函数体解析 `src/parser.zig:11941`、12465，都配了 errdefer + 正常路径各一次 leave。

### `ParseState.leaveControlBoundary` (`src/parser.zig:2401`)

- **签名**：`fn leaveControlBoundary(s: *State, saved: ControlFrames) void`。
- **作用**：离开函数边界：先 `deinitCurrentControlFrames` 释放本层，再把外层那组原样装回。
- **实现**：先 `deinitCurrentControlFrames()` 释放内层这一轮自己建起来的全部列表，再把 `saved` 的十七个字段逐项写回 `s`。必须与 `enterControlBoundary` 严格配对：少调一次就泄漏外层列表，多调一次会把已释放的列表装回去。
- **所有权 / 错误 / 调用**：与 `enterControlBoundary` 配对的释放点：先 `deinitCurrentControlFrames()` 释放内层那批列表，再把 `saved` 里的所有权装回 `State`；`saved` 一经传入即被消费，不能重复使用。不分配、无 error。调用方 4 处：`src/parser.zig:11943`(errdefer)/11976、12467(errdefer)/12509。

### `ParseState.truncateClassPrivateElements` (`src/parser.zig:2422`)

- **签名**：`fn truncateClassPrivateElements(self: *State, len: usize) void`。
- **作用**：将类私有元素记录恢复到指定长度。
- **实现**：一行 `shrinkRetainingCapacity(len)`，保留容量（rc 时代那个空体的尾部遍历已删）。
- **所有权 / 错误 / 调用**：不逐项释放 atom 或对象；调用方保证 len 不超过当前长度。

### `ParseState.truncateClassPrivateBoundNames` (`src/parser.zig:2426`)

- **签名**：`fn truncateClassPrivateBoundNames(self: *State, len: usize) void`。
- **作用**：将类私有已绑定名字列表恢复到指定长度。
- **实现**：一行 `shrinkRetainingCapacity(len)`（rc 时代那个空体的尾部遍历已删）。
- **所有权 / 错误 / 调用**：不逐项 unpin；保留底层容量，len 必须是有效的恢复水位。

### `ensureImplicitArgumentsLocal` (`src/parser.zig:3007`)

- **签名**：`fn ensureImplicitArgumentsLocal(fd: *function_def_mod.FunctionDef) Error!?u16`。
- **作用**：给需要 `arguments` 的函数按需物化那条隐式绑定，返回它的 var 下标（不需要或轮不到时返回 null）。
- **实现**：四道闸：`fd.parent == null`（顶层脚本）、`func_type == .arrow`、`func_type == .class_static_init` 这三类没有自己的 `arguments`，返回 null；`fd.arguments_var_idx >= 0` 说明已建过，直接返回旧下标；函数里已有同名形参或 var（`findArg` / `findVar`）时返回 null——用户绑定优先，不再造伪绑定。四闸都过才 `fd.ensureArgumentsBinding()` 建槽。对照 qjs `add_arguments_var` 走 `add_var`：`arguments` 是普通 scope/var/arg 查找之后的特殊回退项，不进词法作用域链表。
- **所有权 / 错误 / 调用**：无 `self`，只读写传入的 `fd`：命中已有绑定时只返回下标；否则 `fd.ensureArgumentsBinding()` 在 `FunctionDef` 上追加 var 行，失败收敛成 `error.OutOfMemory`（唯一 error）。返回的是 `vars` 下标而不是所有权。调用方 2 处，都是 `ensureClosureVar`：当前函数分支 `src/parser.zig:3127`、父函数分支 3247。

### `isDynamicEnvironmentCaptureAtom` (`src/parser.zig:3021`)

- **签名**：`fn isDynamicEnvironmentCaptureAtom(atom_id: Atom) bool`。
- **作用**：该 atom 是否是动态环境伪绑定（`with_object` / `var_object` / `arg_var_object`）。
- **实现**：三项 atom id 相等比较：`with_object`、`var_object`、`arg_var_object`。这三个名字是解析器给 `with` 语句对象和 direct-eval 变量对象造的伪绑定，闭包与作用域判定要把它们与用户绑定区别对待。
- **所有权 / 错误 / 调用**：无：三次预定义 id 比较（`with_object` / `var_object` / `arg_var_object`），无 `State`、不分配、无 error。唯一调用方：`ensureClosureVar` 的父层 closure 扫描 `src/parser.zig:3262`。

### `ensureClosureVar` (`src/parser.zig:3027`)

- **签名**：`fn ensureClosureVar(self: *State, atom_id: Atom) Error!void`。
- **作用**：在非 phase-1 路径上按需物化闭包捕获。
- **实现**：
`emit_to_function_def==false` 或 `emit_phase1_temp` 时直接返回：phase-1 只发 name+scope，绑定发现留给 `resolve_variables`。

非 temp 路径：
1. `arguments`：当前作用域看不见显式绑定则 `ensureParameterArgumentsLocals` 或 `ensureImplicitArgumentsLocal`（参数默认值环境 vs 函数体）。
2. `findVar`/`findArg` 命中：扁平查找；若是具名函数表达式自身、且当前作用域链看不见该绑定，则 `ensureFuncExprSelfBinding`（`function rec(){ { let rec; } return rec; }`）。
3. 已有同名 `closure_var` 则返回。
4. 具名函数表达式自身再物化一次 self-binding。
5. `ensureArrowSpecialCapture` 处理箭头的 `this` / `new.target`。
6. 再 `emit_phase1_temp` 则返回（不在解析期发明普通闭包行）。
7. 沿 `cur_func_stack` 向外：参数环境优先捕获父函数的 arguments 单元格；`findVisibleParentVarCapturingWith` 顺带把可见 `with_object` 链起来；形参、隐式 arguments、父闭包行（含动态环境捕获 atom）分别 `ensureClosureChain`。
- **所有权 / 错误 / 调用**：自己不分配，但会让被调方在各 `FunctionDef` 上长出行：`ensureParameterArgumentsLocals` / `ensureImplicitArgumentsLocal` / `ensureFuncExprSelfBinding` / `ensureClosureChain`（逐层 `addClosureVar`），这些行归对应的 `FunctionDef`。atom 全程是借用 id。错误两类：上述分配的 `error.OutOfMemory`，以及 `findVisibleParentVarCapturingWith` / `ensureClosureChain` 的 `Error.ParserInvariant`（vars 下标越界、closure 链断裂）。调用方 3 处：变量引用 `src/parser.zig:3007`、4364、绑定发射 12739。

### `ensureArrowSpecialCapture` (`src/parser.zig:3221`)

- **签名**：`fn ensureArrowSpecialCapture(self: *State, atom_id: Atom) Error!bool`。
- **作用**：箭头函数里引用 `this` / `new.target` 时，在最近的非箭头父函数上物化对应的隐藏本地，并经闭包链把它引到当前箭头。
- **实现**：对照 qjs 的建模：箭头的词法 `this` 与 `new.target` 就是按需创建的普通闭包变量——在最近的非箭头 FunctionDef 上物化隐藏本地后，用与用户绑定完全相同的 ref 链把它带穿层层嵌套的箭头。当前函数不是 `.arrow`、或 atom 既不是 `atom_this` 也不是 `atom_new_target` 时直接返回 false。否则沿 `cur_func_stack` 由内向外跳过所有箭头，找到第一个非箭头父函数：`this` 走 `parent.ensureThisBinding()`；`new.target` 先查 `parent.new_target_allowed`，不允许就返回 false，允许则走 `parent.ensureNewTargetBinding()`。拿到 var 下标后按源行的 `is_lexical` / `is_const` / `var_kind` 组一条 `.local` 闭包源交给 `ensureClosureChain` 逐层补齐，返回 true。整条栈都是箭头（没有非箭头父函数）时返回 false。
- **所有权 / 错误 / 调用**：`parent.ensureThisBinding()` / `ensureNewTargetBinding()` 在父 `FunctionDef` 上追加行，失败就地收敛成 `error.OutOfMemory`；随后 `ensureClosureChain` 的错误（OOM 或 `Error.ParserInvariant`）原样上抛。返回 bool 表示是否已经处理掉这次捕获。唯一调用方 `ensureClosureVar`(`src/parser.zig:3158`)。

### `findVisibleParentVarCapturingWith` (`src/parser.zig:3252`)

- **签名**：`fn findVisibleParentVarCapturingWith( self: *State, parent_index: usize, parent: *function_def_mod.FunctionDef, atom_id: Atom, visible_scope_level: i32, ) Error!?i32`。
- **作用**：在父函数里找从子函数可见的同名绑定，顺带把沿途可见的 `with_object` 也捕获进闭包链。
- **实现**：外层从 `visible_scope_level` 沿 `parent.scopes[].parent` 上行，内层沿该作用域的 `first` / `scope_next` 链走（遇到 `vd.scope_level != scope_idx` 即退出本层；var 下标越过 `parent.vars.len` 报 `Error.ParserInvariant`）。链上命中 `var_name == atom_id` 立即返回该下标。命中之前每遇到一行 `with_object` 伪绑定（且本次找的不是 `with_object` 自己），就先 `ensureClosureChain` 把这个 `with` 对象捕获进闭包链——被 `with` 罩住的名字在运行时必须先查 with 对象，所以捕获不能漏。作用域链走完后，从 `parent.vars` 尾部倒扫找 `var_kind == .function_name` 的行。最后一条回退是嵌套引用外层具名函数表达式自己的名字：`parent.is_named_func_expr` 且名字相符时用 `parent.ensureFuncExprSelfBinding()` 在 eager var 原先占据的那个回退位置物化自绑定（对照 `resolve_scope_var` 的 enclosing-function 分支，quickjs.c:33151-33155），从而保持捕获顺序不变。全都没有则返回 null。
- **所有权 / 错误 / 调用**：名为 find，实则**有副作用**：扫到 `with_object` 行时会调 `ensureClosureChain` 让 with 环境一并被捕获（会在各层 `FunctionDef` 上分配 closure 行）。特有 error：`vars` 下标越界时 `Error.ParserInvariant`；其余是 `ensureClosureChain` / `parent.ensureFuncExprSelfBinding` 的 `error.OutOfMemory`。返回的是父函数的 `vars` 下标，不是所有权。唯一调用方 `ensureClosureVar`(`src/parser.zig:3202`)。

### `ensureClosureChain` (`src/parser.zig:3300`)

- **签名**：`fn ensureClosureChain(self: *State, source_index: usize, source_value: function_def_mod.ClosureVar.Init) Error!void`。
- **作用**：把一个绑定从持有它的函数一路 ref 到当前函数，沿途每层补齐 `closure_var` 行。
- **实现**：先按 `source.closureType()` 把源函数里对应的 `vars[var_idx]` 或 `args[var_idx]` 标上 `is_captured`（下标越界则跳过，不报错）。然后从 `source_index + 1` 起逐层向内直到当前函数：第一层直接用 source 那条 `ClosureVar`，之后每层构造一条 `.ref` 行，`var_idx` 指向上一层刚确定的行下标（`parent_ref_idx` 为空说明链断了，报 `Error.ParserInvariant`），`is_lexical` / `is_const` / `var_kind` / `var_name` 一律沿用 source。每层先线性找是否已有等价行：复用判定只看绑定身份（`closureType()` 与 `var_idx` 都相同），对照 qjs `get_closure_var` 只按绑定身份判等——同名但来自不同环境的行必须各自保留，「取第一个匹配」才能模拟遮蔽。有就复用其下标，没有就 `child.addClosureVar` 追加。
- **所有权 / 错误 / 调用**：从源函数到当前函数逐层 `child.addClosureVar`，行分配在各自 `FunctionDef` 的 memory 上（OOM 上抛），同时把源 `vars`/`args` 标 `is_captured`；`var_name` 借用。特有 ICE：中间层拿不到上一层的 `parent_ref_idx` 时返回 `Error.ParserInvariant`。9 处调用方全在捕获逻辑内部：`ensureClosureVar`(`src/parser.zig:3192`-3274 共 7 处)、`ensureArrowSpecialCapture`(3310)、`findVisibleParentVarCapturingWith`(3340)。

### `findClosureVarIndex` (`src/parser.zig:3344`)

- **签名**：`fn findClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16`。
- **作用**：在给定 FunctionDef 的 `closure_var` 里找第一个同名行。
- **实现**：线性扫 `fd.closure_var`，返回第一条 `var_name == atom_id` 的下标，只比名字不看类型。取第一个匹配是有意的：`ensureClosureChain` 保证行的追加顺序就是遮蔽顺序。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：线性扫 `fd.closure_var` 比 `var_name`。唯一调用方 `src/parser.zig:11753`（eval 的父函数绑定可见性判定）。

### `findGlobalClosureVarIndex` (`src/parser.zig:3351`)

- **签名**：`fn findGlobalClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16`。
- **作用**：在 `closure_var` 里找同名且闭包类型属于全局/模块那一组（`global` / `global_ref` / `global_decl` / `module_decl` / `module_import`）的行。
- **实现**：线性扫 `fd.closure_var`：名字不符直接跳过；名字相符时再看 `closureType()` 是否落在 `.global` / `.global_ref` / `.global_decl` / `.module_decl` / `.module_import` 这五种里，命中返回下标，否则继续找——同名但属于普通局部捕获的行不能拿来当全局引用。
- **所有权 / 错误 / 调用**：同上，只是只接受 global/global_ref/global_decl/module_decl/module_import 这几类 closure 行。无分配、无 error。唯一调用方 `ensureGlobalClosureVarIndex`(`src/parser.zig:3435`)。

### `ensureGlobalClosureVarIndex` (`src/parser.zig:3362`)

- **签名**：`fn ensureGlobalClosureVarIndex(self: *State, atom_id: Atom) Error!u16`。
- **作用**：取（必要时新建）当前函数里指向某个全局 / 模块名的闭包行下标——全局变量读写指令的 u16 操作数就是它。
- **实现**：先 `findGlobalClosureVarIndex` 复用已有行。没有时追加一条 `.global` 闭包行（非 lexical、非 const、`var_kind = .normal`、`var_idx = 0`，因为全局引用按名字解析、不指向任何本地槽），分配失败转 `Error.OutOfMemory`；返回下标为负或超过 `maxInt(u16)`（放不进指令操作数）时报 `Error.ParserInvariant`。
- **所有权 / 错误 / 调用**：未命中时 `fd.addClosureVar` 追加一行 global closure（`FunctionDef` 内存，失败收敛成 `Error.OutOfMemory`）；返回下标超 `u16` 时报 `Error.ParserInvariant`。`atom_id` 借用。调用方：`emitGlobalVarOp`(`src/parser.zig:3449`)、`emitGlobalVarOpNoSource`(3456)。

### `emitGlobalVarOp` (`src/parser.zig:3377`)

- **签名**：`fn emitGlobalVarOp(self: *State, op_id: u8, atom_id: Atom) Error!void`。
- **作用**：把一个按名字的全局变量访问发射成「闭包行下标」形式：先给该名字要到一行全局 closure var，再发 `op <u16 idx>`。
- **实现**：`ensureGlobalClosureVarIndex(atom_id)` 拿到（或按需建出）该名字的全局闭包行下标，再 `Emitter.opU16(self, op_id, ref_idx)`。非 temp 的全局 var 降级与 temp 形态共用同一套 op + u16 闭包行下标编码。
- **所有权 / 错误 / 调用**：先经 `ensureGlobalClosureVarIndex` 可能新增一行 closure（OOM / `ParserInvariant`），再发 `op + u16`（builder 错误经 `mapBuilderError` 收成 OOM / BytecodeOverflow / ParserInvariant）。不分配长期对象。parser 内调用方三处：`src/parser.zig:3018`、12744、12746；`src/bytecode.zig:8501`/8528 的同名函数是另一份实现，不是本函数的调用方。

### `emitGlobalVarOpNoSource` (`src/parser.zig:3384`)

- **签名**：`fn emitGlobalVarOpNoSource(self: *State, op_id: u8, atom_id: Atom) Error!void`。
- **作用**：同 `emitGlobalVarOp`，但用在编译器自己合成、不该出现在 source map 里的位置。
- **实现**：同样先 `ensureGlobalClosureVarIndex`，只是改走 `Emitter.opU16NoSource`——不为这条指令记 source 偏移。
- **所有权 / 错误 / 调用**：与 `emitGlobalVarOp` 同一套（可能新增 closure 行 + builder 三元错误），只是不写源码位置记录。唯一调用方 `src/parser.zig:3020`。

### `scopeChainContains` (`src/parser.zig:3389`)

- **签名**：`fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool`。
- **作用**：从 `start_scope` 沿 parent 链能否走到 `target_scope`。
- **实现**：从 `start_scope` 沿 `fd.scopes[].parent` 上行，命中 `target_scope` 返回 true；下标变负或越过 `fd.scopes.len` 时停止并返回 false。与 `ParseState.isChildScope` 同义，区别是这份只吃 `*const FunctionDef`，可在没有 `ParseState` 的地方调用。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：沿 `fd.scopes[].parent` 上溯看是否经过目标 scope。唯一调用方 `hasVisibleCurrentBinding`(`src/parser.zig:3479`)。

### `hasVisibleCurrentBinding` (`src/parser.zig:3398`)

- **签名**：`fn hasVisibleCurrentBinding( fd: *const function_def_mod.FunctionDef, atom_id: Atom, scope_level: i32, ) bool`。
- **作用**：判断某个名字在当前函数里已经有可见绑定——形参，或作用域链上看得见的 var / 词法行。
- **实现**：先查形参：`fd.findArg(atom_id) >= 0` 即 true。再从 `fd.vars` 尾部倒扫（后声明的优先），要求名字相同且 `scopeChainContains(fd, scope_level, vd.scope_level)`——该行所在作用域必须在给定 `scope_level` 的父链上，才算对当前位置可见。都不命中返回 false。
- **所有权 / 错误 / 调用**：无分配、无 error：先查参数表，再倒序扫 `vars` 并用 `scopeChainContains` 过滤可见性。调用方 3 处：`ensureClosureVar` 的 `arguments` 与自引用判定(`src/parser.zig:3118`、3140)、4377。

### `pushBreakFrame` (`src/parser.zig:7468`)

- **签名**：`fn pushBreakFrame(s: *State) Error!void`。
- **作用**：为一个循环压一整组 break + continue 帧。
- **实现**：往 break / continue 两侧的并行数组各推一行：`break_frame_lens` / `continue_frame_lens` 记下当前 fixup 水位（弹帧时据此回收本帧的跳转），`continue_frame_break_frame_indices` 记下配对的 break 帧下标，两侧的 `*_catch_marker_depths` 记下 `active_catch_marker_depth`，`break_frame_cleanup_drops` / `break_frame_cross_cleanup_drops` / `continue_frame_cleanup_drops` 三个清理计数一律推 0。最后按 qjs `push_break_entry` 的顺序分配标签：先 continue 标签，后 break 标签（顺序影响标签编号，进而影响 resolve 后的布局）。
- **所有权 / 错误 / 调用**：八条并行数组全部用 `s.function.memory.allocator` 追加（内存归 fd），另有两个 LabelId 分别追加进 `continue_frame_labels` / `break_frame_labels`、LabelId 本身归 Builder；配对的释放点是 `popBreakFrameAndPatch`（`src/parser.zig:8121`，它把两侧数组同步弹回并绑定 break 标签），异常退出时由 `deinitCurrentControlFrames` 整体回收。错误：各 append 的 `error.OutOfMemory` 与 `emitterNewLabel` 的 builder 三元组；没有 errdefer——中途失败会留下长度不齐的并行数组，但那条解析路径已经在往上抛，不会再有人消费。调用方 3 处：`parseDoOrWhileStatement`（`src/parser.zig:9298`）、`parseForStatement`（`src/parser.zig:9488`）、`parseForInOf`（`src/parser.zig:10971`）。

### `pushBreakOnlyFrame` (`src/parser.zig:7482`)

- **签名**：`fn pushBreakOnlyFrame(s: *State) Error!void`。
- **作用**：只压 break 一侧的帧与标签（没有 continue 目标的结构，如 switch / 带标签的普通语句）。
- **实现**：只推 break 一侧：`break_frame_lens` 记 fixup 水位、`break_frame_catch_marker_depths` 记当前 catch marker 深度、`break_frame_cleanup_drops` 与 `break_frame_cross_cleanup_drops` 推 0，再分配一个 break 标签。continue 侧的所有并行数组一律不动——switch 与带标签的普通语句没有 continue 目标，推了反而会让 `continue` 错误地命中它们。
- **所有权 / 错误 / 调用**：同族但只推 break 侧四条数组 + 一个标签，内存归 fd；配对释放点是 `popBreakOnlyFrameAndPatch`（`src/parser.zig:8138`）。错误只有 append 的 `error.OutOfMemory` 与 `emitterNewLabel` 的 builder 三元组。唯一调用方 `parseSwitchStatement`（`src/parser.zig:9572`）。

### `pushControlBlock` (`src/parser.zig:7494`)

- **签名**：`fn pushControlBlock( s: *State, block: *BlockEnv, label_name: ?Atom, has_break_target: bool, has_continue_target: bool, is_regular_stmt: bool, scope_level: i32, drop_count: i32, has_iterator: bool, ) void`。
- **作用**：把一个 `BlockEnv` 链进 `top_break` 有序环境链，登记它的标签名、break/continue 目标有无、scope_level、drop 数与是否持有 iterator。
- **实现**：一次整体赋值构造 `BlockEnv`：`prev` 接旧的 `s.top_break`，`label_name` 无名时填 `atom_module.null_atom`，`label_break` / `label_cont` 用 `0` / `-1` 编码「本环境有没有对应目标」（真正的标签号由后续 fixup 填），`label_finally` 固定 -1，`drop_count` / `scope_level` / `has_iterator` / `is_regular_stmt` 照参数写，`catch_marker_depth` 取当前 `s.active_catch_marker_depth`；最后把它设为新的 `s.top_break`。跳转操作数仍归已有的 fixup 列表所有，这里只建链。
- **所有权 / 错误 / 调用**：不分配：`block` 是调用方栈上的 `BlockEnv`，本函数只填字段并把它链进 `s.top_break`——所以必须在同一栈帧里配对 `popControlBlock`，否则 `top_break` 会指向失效的栈内存。`label_name` 是借用 atom id（无 label 时写 `null_atom`）。无 error。调用方 5 处：label 语句 `src/parser.zig:8980`、循环 9301/9491、switch 9578、for-in/of 10980。

### `popControlBlock` (`src/parser.zig:7520`)

- **签名**：`fn popControlBlock(s: *State, block: *BlockEnv) void`。
- **作用**：把 `top_break` 退回该环境的 `prev`（断言弹的就是栈顶）。
- **实现**：先 `std.debug.assert(s.top_break == block)` 确认弹的就是栈顶（`BlockEnv` 由调用方在栈上分配、按词法嵌套压入），再把 `s.top_break` 指回 `block.prev`。不释放任何内存。
- **所有权 / 错误 / 调用**：只把 `s.top_break` 退回 `block.prev`，不释放任何东西（`BlockEnv` 的存储在调用方栈上）；断言栈顶就是这个块。不分配、无 error。10 处调用，与 `pushControlBlock` 成对出现在 `defer` 与正常路径(`src/parser.zig:8982`/8994、9303/9318、9493/9506、9580 等)。

### `setCurrentBreakCleanupDrops` (`src/parser.zig:7525`)

- **签名**：`fn setCurrentBreakCleanupDrops(s: *State, drops: u8) void`。
- **作用**：设定最内层 break 帧的清理 drop 数（同时写普通版与 cross 版）。
- **实现**：没有 break 帧时直接返回（顶层语句不需要清理记账）。否则把 `break_frame_cleanup_drops` 与 `break_frame_cross_cleanup_drops` 两个栈的最后一项同时改成 `drops`——普通退出与跨帧退出用同一个数，之后若两者需要分开，再由 `setCurrentBreakCrossCleanupDrops` 单独覆盖 cross 那份。
- **所有权 / 错误 / 调用**：不分配：改写 break 帧两条并行数组的最后一项（cleanup 与 cross-cleanup 同时写），列表为空时静默返回。无 error。调用方 2 处：for-of / for-await 的迭代器清理位 `src/parser.zig:10973`、10975。

### `setCurrentBreakCrossCleanupDrops` (`src/parser.zig:7531`)

- **签名**：`fn setCurrentBreakCrossCleanupDrops(s: *State, drops: u8) void`。
- **作用**：只设定最内层 break 帧「跨出时」的清理 drop 数。
- **实现**：没有帧时返回；否则只改 `break_frame_cross_cleanup_drops` 的最后一项，`break_frame_cleanup_drops` 保持不变。用于「从内层跨出这一帧时要多丢几个栈项，但在本帧内正常 break 不用」的情形。
- **所有权 / 错误 / 调用**：同上但只写 `break_frame_cross_cleanup_drops` 的最后一项——用于「跨帧才需要多丢一个槽」的场合。不分配、无 error。唯一调用方：switch 语句 `src/parser.zig:9573`。

### `emitUnlabelledBreakCleanup` (`src/parser.zig:7536`)

- **签名**：`fn emitUnlabelledBreakCleanup(s: *State, cleanup_drops: u8) Error!void`。
- **作用**：无标签 `break` 跳出前，按帧上记的清理数发对应的栈清理指令。
- **实现**：`cleanup_drops == shared_iterator_close_marker`（哨兵 255）时直接返回——这枚标记表示该迭代器的 close 由别处（目标帧自己的收尾）负责，在这里发就重复了；其余一律转给 `emitCrossFrameCleanup`。
- **所有权 / 错误 / 调用**：不分配、不改任何帧状态（`cleanup_drops` 按值传入）。错误全部来自转调的 `emitCrossFrameCleanup`，即 `iterator_close` / `drop` 发射经 `mapBuilderError` 的 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`。唯一调用方 `emitControlBlocksUntil`（`src/parser.zig:10453`，只在 `.@"break"` 臂）。

### `emitCrossFrameCleanup` (`src/parser.zig:7541`)

- **签名**：`fn emitCrossFrameCleanup(s: *State, cleanup_drops: u8) Error!void`。
- **作用**：发出跨越一层控制帧时要做的栈清理：要么关掉迭代器，要么丢掉固定条数的栈项。
- **实现**：`cleanup_drops` 是两用编码：等于 `shared_iterator_close_marker`（255）或 `direct_iterator_close_marker`（254）时发一条 `iterator_close`；否则把它当计数，循环发出同样条数的 `drop`。两种都走 `Emitter.opNoSource`，不带 source 标记——这些是编译器补的清理码，不对应任何源码位置。
- **所有权 / 错误 / 调用**：不分配；两个哨兵值（`shared_iterator_close_marker` / `direct_iterator_close_marker`）改发一条 `iterator_close`，否则按计数发 `drop`。错误全部来自 builder：`error.OutOfMemory` / `error.BytecodeOverflow` / `Error.ParserInvariant`。唯一调用方 `emitUnlabelledBreakCleanup`(`src/parser.zig:7856`)。

### `emitCatchMarkerDropsFromDepth` (`src/parser.zig:7552`)

- **签名**：`fn emitCatchMarkerDropsFromDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void`。
- **作用**：把 catch marker 栈从当前深度退到目标深度，沿途逐层发出丢弃与 using 释放。
- **实现**：`current_depth.* < target_depth` 说明调用方记账已经错乱，报 `Error.ParserInvariant`。否则循环到 `current_depth.*` 降到 `target_depth` 为止：每层先发一条不带 source 的 `drop` 丢掉被跨过的 catch-marker 槽（对照 qjs 的 abrupt cleanup，quickjs.c:28371-28377），再对该深度调 `emitUsingDisposesForCatchMarkerDepth` 发出这一层的资源释放，最后把 `current_depth.*` 减一。深度经指针出参回写，调用方据此继续记账。
- **所有权 / 错误 / 调用**：不分配；`current_depth` 是 in/out 指针，写的是调用方栈上的游标而非 `State` 字段，所以中途报错时游标停在已发射的那一层、调用方不再使用它。自有错误一条 `Error.ParserInvariant`（`current_depth.* < target_depth`，说明调用方记账错乱）；其余来自 `drop` 发射与 `emitUsingDisposesForCatchMarkerDepth`。调用方 3 处：`emitControlBlocksUntil`（`src/parser.zig:10447` 与 `10460`）、`emitControlThroughFinally`（`src/parser.zig:10490`）。

### `emitUsingDisposesForCatchMarkerDepth` (`src/parser.zig:7562`)

- **签名**：`fn emitUsingDisposesForCatchMarkerDepth(s: *State, depth: u32) Error!void`。
- **作用**：为某个 catch marker 深度上的所有 `using` 块发出资源释放序列（显式资源管理的 abrupt 退出路径）。
- **实现**：从 `using_block_frames` 尾部往前遍历（由内向外，符合资源释放的逆序要求）：跳过 `frame.catch_marker_depth != depth` 的帧，以及 `stack_loc` 还是 null（尚未物化 DisposableStack）的帧；其余发 `emitUsingDisposeStack(s, stack_loc, frame.seen_async_hint)` 再 `s.emitCloseLoc(stack_loc)` 关掉那个本地槽。
- **所有权 / 错误 / 调用**：不分配，只读 `s.using_block_frames`（帧本身归 State，由 using 块的退出路径负责弹出）。无自有 error；全部错误来自 `emitUsingDisposeStack` 与 `s.emitCloseLoc` 的发射，即 builder 三元组 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`。调用方 2 处：`emitCatchMarkerDropsFromDepth`（`src/parser.zig:7875`）与 `emitStackTopCatchMarkerDropsToDepth`（`src/parser.zig:12867`）。

### `emitUnlabelledBreak` (`src/parser.zig:7574`)

- **签名**：`fn emitUnlabelledBreak(s: *State) Error!void`。
- **作用**：发出无标签 `break`：跳到最内层 break 帧的汇合点，途中穿过的 finally 与清理由下游补齐。
- **实现**：`break_frame_lens` 为空说明当前没有可 break 的语句，直接返回、什么也不发（语法层的「非法 break」在别处报错）。否则把活交给 `emitControlThroughFinally(s, .{ .kind = .@"break" })`，由它解析目标帧、发清理码再跳转。
- **所有权 / 错误 / 调用**：不分配；帧数为 0 的早退路径不产生任何 error。其余错误全部来自 `emitControlThroughFinally`：记账与环境链失配的 `Error.ParserInvariant`、发射的 builder 三元组。唯一调用方 `parseBreakOrContinueStatement`（`src/parser.zig:9547`）。

### `emitUnlabelledContinue` (`src/parser.zig:7579`)

- **签名**：`fn emitUnlabelledContinue(s: *State) Error!void`。
- **作用**：发出无标签 `continue`：跳到最内层循环 continue 帧的汇合点。
- **实现**：与 `emitUnlabelledBreak` 同形：`continue_frame_lens` 为空时直接返回，否则交给 `emitControlThroughFinally(s, .{ .kind = .@"continue" })`。
- **所有权 / 错误 / 调用**：同 `emitUnlabelledBreak`，不分配；错误来自 `emitControlThroughFinally`（`resolveFinallyControlTarget` 在 continue 帧为空时报 `Error.ParserInvariant`，发射走 builder 三元组）。唯一调用方 `parseBreakOrContinueStatement`（`src/parser.zig:9550`）。

### `enterSwitchContinueCleanup` (`src/parser.zig:7584`)

- **签名**：`fn enterSwitchContinueCleanup(s: *State) void`。
- **作用**：为经过 switch 的 continue 路径增加一个待丢弃栈项。
- **实现**：遍历 continue_frame_cleanup_drops；跳过两个 iterator-close marker，其他计数加一。
- **所有权 / 错误 / 调用**：只修改计数，不执行 IteratorClose，也不立即弹 VM 栈。

### `leaveSwitchContinueCleanup` (`src/parser.zig:7590`)

- **签名**：`fn leaveSwitchContinueCleanup(s: *State) void`。
- **作用**：退出 switch 后撤销 continue 路径的附加清理计数。
- **实现**：跳过两个 iterator-close marker，只对大于零的普通计数减一。
- **所有权 / 错误 / 调用**：与进入 switch 的计数维护配合；不执行运行时清理。

### `pushReturnFinallyFrame` (`src/parser.zig:9613`)

- **签名**：`fn pushReturnFinallyFrame( s: *State, finally_label: FinallyLabel, catch_marker_depth: u32, ) Error!usize`。
- **作用**：为一个 try/finally 压 return-finally 帧，记住 finally 标签与当时的作用域、catch marker 深度、break/continue/label 深度和 `BlockEnv` 边界。
- **实现**：先做记账一致性检查：传入的 `catch_marker_depth` 大于 `s.active_catch_marker_depth` 说明调用方算错了，报 `error.ParserInvariant`。随后向 `return_finally_frames` 追加一帧，除 `finally_label` 外把当时的 `scope_level`、`catch_marker_depth`、`break_frame_lens.items.len`、`continue_frame_lens.items.len`、`label_frames.items.len` 与 `top_break` 一并留底——后续的 `return` / `break` / `continue` 要靠这组水位判断自己是否跨出了这个 finally。返回新帧下标。
- **所有权 / 错误 / 调用**：向 `State.return_finally_frames` 追加一帧（`function.memory.allocator`，OOM 上抛），返回下标，调用方必须配对 `popReturnFinallyFrame`。特有 ICE：`catch_marker_depth > s.active_catch_marker_depth` 时返回 `error.ParserInvariant`。帧内只存深度与 `block_boundary` 指针（指向调用方栈上的 `BlockEnv`），不持有堆对象。调用方：try 体 `src/parser.zig:9772`、catch 体 9839。

### `popReturnFinallyFrame` (`src/parser.zig:9631`)

- **签名**：`fn popReturnFinallyFrame(s: *State, frame_index: usize) void`。
- **作用**：弹出最内层 return-finally 帧（断言弹的就是栈顶）。
- **实现**：先 `std.debug.assert(frame_index + 1 == s.return_finally_frames.items.len)` 确认弹的是栈顶，再 `pop` 丢弃。帧本身是值类型、不持有堆内存，所以不需要额外释放。
- **所有权 / 错误 / 调用**：只 pop 不释放——帧本身没有自带分配，列表 backing 归 `State`；断言只允许弹栈顶。不分配、无 error。4 处调用：`src/parser.zig:9775`(errdefer)/9781、9842(errdefer)/9854。

### `enterReturnFinallyFunctionBoundary` (`src/parser.zig:9636`)

- **签名**：`fn enterReturnFinallyFunctionBoundary(s: *State) ReturnFinallyBoundary`。
- **作用**：进入嵌套函数：把 `return_finally_frames` 与 `finally_body_control_frames` 整组搬走并清空。
- **实现**：把 `s.return_finally_frames` 与 `s.finally_body_control_frames` 两个列表原样装进 `ReturnFinallyBoundary` 返回，再把 `s` 上这两项置成 `.empty`。与 `enterControlBoundary` 同一套路：所有权随返回值移交，内层函数的 `return` 不会跳进外层函数的 finally。
- **所有权 / 错误 / 调用**：不分配、无 error，但是所有权转移点：`return_finally_frames` 与 `finally_body_control_frames` 两条列表整体搬进返回值，`State` 侧置 `.empty`；返回值必须交给 `leaveReturnFinallyFunctionBoundary`，否则泄漏。调用方：嵌套函数体 `src/parser.zig:11575`、12181（都带条件，只有真正进入子函数时才取）。

### `leaveReturnFinallyFunctionBoundary` (`src/parser.zig:9646`)

- **签名**：`fn leaveReturnFinallyFunctionBoundary(s: *State, saved: *const ReturnFinallyBoundary) void`。
- **作用**：离开嵌套函数：释放本层这两个列表，再把外层的装回。
- **实现**：两组各做一次「先释放内层、再装回外层」：`return_finally_frames.deinit(allocator)` 后写回 `saved.frames`，`finally_body_control_frames.deinit(allocator)` 后写回 `saved.finally_body_control_frames`；分配器取 `s.function.memory.allocator`。
- **所有权 / 错误 / 调用**：与 enter 配对的释放点：先 deinit 内层两条列表，再把 `saved` 的所有权装回 `State`。不分配、无 error。调用方 `src/parser.zig:11576`、12182，都写在 `defer` 里。

### `controlTargetCrossesFinallyFrame` (`src/parser.zig:9653`)

- **签名**：`fn controlTargetCrossesFinallyFrame(s: *State, target: FinallyControlTarget, frame_index: usize) Error!bool`。
- **作用**：判断这次 break/continue 会不会跨出指定的 return-finally 帧。
- **实现**：带标签时先 `findLabelFrame(atom_id)`（找不到即 `Error.ParserInvariant`，语法层的未定义标签应当已被更早拦下）；`continue` 目标所在标签帧若 `allow_continue` 为假同样报 `ParserInvariant`；随后比较 `label_frame_index < frame.label_depth`——标签帧比这个 finally 压得还早，就说明跳过去要跨出它。不带标签时改比帧数水位：`break` 看 `break_frame_lens.items.len <= frame.break_depth`，`continue` 看 `continue_frame_lens.items.len <= frame.continue_depth`，即目标帧不在这个 finally 之内。
- **所有权 / 错误 / 调用**：不分配；只读 label 帧与 break/continue 帧的深度。特有错误：label 查不到、或 `continue` 指向 `allow_continue == false` 的 label 时返回 `Error.ParserInvariant`——这两种形态本应在更早的 `resolveFinallyControlTarget` 就被拒成语法错误，走到这里说明内部状态不一致。唯一调用方 `src/parser.zig:10477`。

### `resolveFinallyControlTarget` (`src/parser.zig:9865`)

- **签名**：`fn resolveFinallyControlTarget(s: *State, target: FinallyControlTarget) Error!ResolvedFinallyControlTarget`。
- **作用**：把一次 break/continue（可带标签）解析成目标帧深度、catch marker 深度与清理 drop 数。
- **实现**：带标签时：`findLabelFrame` 找不到就 `failUndefinedLabel`。`break` 取标签帧的 `break_frame_depth` 当深度，`cleanup_drops` 仅当该帧允许 continue（即标签贴在循环上）且深度非 0 时取 `break_frame_cleanup_drops[depth - 1]`，否则 0。`continue` 先要求 `allow_continue` 且 `control_frame_depth != 0`，不满足报 `continue must target a loop label`；满足则取 `control_frame_depth` 与 `continue_frame_cleanup_drops[depth - 1]`。两种都把 `catch_marker_depth` 取自标签帧并回传 `label_frame_index`。不带标签时取最内层帧：深度为帧数组长度，`catch_marker_depth` 与 `cleanup_drops` 各取对应数组的 `getLast()`，`label_frame_index` 为 null；帧数组为空说明上游没拦住非法 `break`/`continue`，报 `Error.ParserInvariant`。
- **所有权 / 错误 / 调用**：不分配；读 label 帧与 break/continue 的并行数组。三类错误：label 未定义 → `failUndefinedLabel`（`error.UnexpectedToken`，atom 名查不到时是 `error.ParserInvariant`）；`continue` 指向非循环 label → `failWithMessage` 的 `error.UnexpectedToken`；无 label 而对应帧栈为空 → `Error.ParserInvariant`。唯一调用方 `src/parser.zig:10469`。

### `controlBlockMatchesTarget` (`src/parser.zig:9915`)

- **签名**：`fn controlBlockMatchesTarget(block: *const BlockEnv, target: FinallyControlTarget) bool`。
- **作用**：判断某个 `BlockEnv` 是不是这次 break/continue 的目标环境。
- **实现**：带标签时要求 `block.label_name == atom_id` 且该方向的目标存在（`break` 看 `label_break >= 0`，`continue` 看 `label_cont >= 0`）。不带标签时：`break` 还额外要求 `!block.is_regular_stmt`——贴在普通语句（非循环/switch）上的标签环境不接无标签 `break`；`continue` 只要求 `label_cont >= 0`。纯谓词，不发指令。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：比 `BlockEnv` 上的 `label_name` 与 `label_break`/`label_cont` 是否可用。唯一调用方 `src/parser.zig:10446`（跨块清理的匹配循环）。

### `emitResolvedControlJump` (`src/parser.zig:9928`)

- **签名**：`fn emitResolvedControlJump( s: *State, target: FinallyControlTarget, resolved: ResolvedFinallyControlTarget, ) Error!void`。
- **作用**：发出 break / continue 的那条实际跳转，落点是目标帧预先分配好的汇合标签。
- **实现**：先定标签：`resolved.label_frame_index` 非空时取该标签帧的 `break_label` / `continue_label`；否则按 `resolved.depth` 去 `break_frame_labels` / `continue_frame_labels` 取第 `depth - 1` 项（depth 为 0 或越界时得到 null）。标签为 null 说明帧记账与标签数组失配，报 `Error.ParserInvariant`；拿到则 `emitterJumpNoSource(s, opcode.op.goto, label_id)` 发一条不带 source 的跳转。v2 下跳转直接以 LabelId 出生（对应 qjs 的 `emit_goto(label_break/label_cont)`），没有操作数偏移回填表。
- **所有权 / 错误 / 调用**：不分配；`LabelId` 只是从帧或并行数组里读出的 Builder 句柄，谁都不拥有它。自有错误一条 `Error.ParserInvariant`——取到 null 说明帧记账与 `break_frame_labels` / `continue_frame_labels` 失配（depth 为 0 或越界）；发射错误经 `emitterJumpNoSource` → `mapBuilderError`。唯一调用方 `emitControlBlocksUntil`（`src/parser.zig:10456`）。

### `emitCrossedControlBlockCleanup` (`src/parser.zig:9952`)

- **签名**：`fn emitCrossedControlBlockCleanup(s: *State, block: *const BlockEnv) Error!void`。
- **作用**：跨出一层控制环境时，把该环境压在栈上的东西清干净（迭代器要 close，其余按 `drop_count` 丢）。
- **实现**：`block.has_iterator` 为真时先发一条 `iterator_close`，并把 `dropped` 记成 3——`iterator_close` 已经吃掉迭代器那三个栈项；然后循环补发 `drop` 直到 `dropped` 达到 `block.drop_count`。两种指令都走 `Emitter.opNoSource`，不挂源码位置。
- **所有权 / 错误 / 调用**：不分配；有迭代器时先发 `iterator_close` 顶掉 3 个槽，再补 `drop` 到 `drop_count`。错误来自 builder：`error.OutOfMemory` / `error.BytecodeOverflow` / `Error.ParserInvariant`。唯一调用方 `src/parser.zig:10461`。

### `emitControlBlocksUntil` (`src/parser.zig:9967`)

- **签名**：`fn emitControlBlocksUntil( s: *State, target: FinallyControlTarget, resolved: ResolvedFinallyControlTarget, block_cursor: *?*BlockEnv, boundary: ?*BlockEnv, scope_cursor: *i32, catch_marker_depth: *u32, ) Error!bool`。
- **作用**：沿 `top_break` 环境链向外走到 break/continue 的目标环境，一路发出被跨过环境的清理码，命中目标就发跳转——`emitControlThroughFinally` 在每两个 finally 之间调用它一段。
- **实现**：以 `block_cursor` 为游标遍历 `BlockEnv` 链，四个出口：撞到 `boundary`（本段 finally 的边界）返回 false 让调用方接着处理这个 finally；链走完且 `boundary == null` 返回 false（调用方据此判 `ParserInvariant`）；链走完但 `boundary != null` 直接 `Error.ParserInvariant`；命中目标返回 true。每一步先 `closeScopes(scope_cursor.*, current.scope_level)` 并推进 `scope_cursor`——作用域退出排在目标测试之前，与 QuickJS `emit_break` 一致。随后 `controlBlockMatchesTarget(current, target)`：命中时先 `emitCatchMarkerDropsFromDepth` 降到 `resolved.catch_marker_depth`，`.@"break"` 再补一次 `emitUnlabelledBreakCleanup(resolved.cleanup_drops)`（`.@"continue"` 不补），最后 `emitResolvedControlJump`；注释说明为什么要在这里补：zjs 的数组式 fixup 不像 qjs 那样都落在目标 epilogue 前的物理 break 标签上，所以目标帧既有的栈清理必须由这里保住，`BlockEnv` 游走只负责被跨过环境的清理。未命中时对当前环境发 `emitCatchMarkerDropsFromDepth(current.catch_marker_depth)` + `emitCrossedControlBlockCleanup(current)`，再把游标移到 `current.prev`。
- **所有权 / 错误 / 调用**：不分配；`block_cursor` / `scope_cursor` / `catch_marker_depth` 三个 in/out 指针指向 `emitControlThroughFinally` 的栈上局部，由调用方在两段之间续用，本函数不持有 `BlockEnv`（它们在各自 `parse*` 的栈帧上）。自有错误一条 `Error.ParserInvariant`（链走完但 `boundary != null`）；其余来自 `closeScopes`、两个清理发射与 `emitResolvedControlJump`。唯一调用方 `emitControlThroughFinally`（`src/parser.zig:10479` 的分段调用与 `10501` 的收尾调用）。

### `emitControlThroughFinally` (`src/parser.zig:10003`)

- **签名**：`fn emitControlThroughFinally(s: *State, target: FinallyControlTarget) Error!void`。
- **作用**：发出一次完整的 `break` / `continue`：沿途穿过的 finally 逐个 gosub 执行，跨过的作用域、catch marker 与栈项逐层清理，最后跳到目标帧的汇合标签。
- **实现**：先 `resolveFinallyControlTarget` 定出目标帧深度、catch marker 深度与清理数，再用 `block_cursor`（从 `s.top_break` 起）、`scope_cursor`、`catch_marker_depth` 三个游标向外走。外层循环由内向外遍历 `return_finally_frames`：`controlTargetCrossesFinallyFrame` 判定不跨出的帧直接跳过；要跨出时先 `emitControlBlocksUntil` 走到该帧的 `block_boundary`（途中若已命中目标环境并发出跳转就直接返回），随后 `closeScopes` 退到帧的 `scope_level`、`emitCatchMarkerDropsFromDepth` 退到帧的 catch marker 深度，接着按 qjs `emit_break` / `emit_return`（quickjs.c:28373-28377、28447-28449）的形状发 `undefined` 占位保持栈深、用 `emitterJumpNoSource(op.gosub, finally_label)` 进 finalizer、回来再发 `drop` 丢掉被跨过的 finalizer 完成值。所有 finally 处理完后再 `emitControlBlocksUntil(..., boundary = null)` 走完剩下的环境；仍然没命中目标说明记账与环境链失配，报 `Error.ParserInvariant`。
- **所有权 / 错误 / 调用**：不分配，三个游标都在本函数栈上；`return_finally_frames` / `top_break` 链只读，帧的所有权归各自的 `parse*`。错误三类：`resolveFinallyControlTarget` 的语法错（未定义标签、`continue` 打在非循环标签，均为 `error.UnexpectedToken`）、记账与环境链失配的 `Error.ParserInvariant`（含最后兜底的那条 return）、发射经 `mapBuilderError` 的三元组。调用方 4 处：`emitLabelledBreak`（`src/parser.zig:2326`）、`emitLabelledContinue`（`src/parser.zig:2330`）、`emitUnlabelledBreak`（`src/parser.zig:7894`）、`emitUnlabelledContinue`（`src/parser.zig:7899`）。

### `needVarReference` (`src/parser.zig:10054`)

- **签名**：`fn needVarReference(s: *State, var_tok: tok.TokenKind) bool`。
- **作用**：判断这条 `var` 声明是否需要走 Reference 形式。
- **实现**：对照 `js_parse_var`（quickjs.c:27847）。非 `TOK_VAR`（即 `let` / `const`）一律 false。sloppy 的非模块代码——`!s.is_strict and !fd.is_strict_mode and !s.lex.is_module`——恒为 true。剩下的情形只看是不是全局 var：`cur_func_stack.len == 0` 且（非 eval 或开了 `eval_global_var_bindings`），再与 `!s.lex.is_module` 相与；模块顶层因此永远为 false（模块的顶层 `var` 是模块环境里的绑定，不是全局对象属性）。
- **所有权 / 错误 / 调用**：无分配、无 error：读严格模式 / module / eval-global 标志决定 `var` 是否要走引用形态。调用方 3 处：`src/parser.zig:10624`、12680、12733。

### `classAccessorKind` (`src/parser.zig:13500`)

- **签名**：`fn classAccessorKind(s: *State) ?bool`。
- **作用**：判断类成员位置上的 `get` / `set` 是访问器前缀还是普通成员名：true=getter、false=setter、null=不是访问器。
- **实现**：当前 token 必须是无转义标识符 `get` 或 `set`（`isIdent`），否则 null。再用 `peekNextKindWithLineTerminator` 一次前瞻：`get` / `set` 与后面的成员名之间有换行时返回 null；下一个 token 是 `(`（方法调用形参表）、`=`（字段初始化）、`;` 或 `}`（无初始化字段）时说明 `get` / `set` 本身就是成员名，也返回 null。都不命中才按 `isIdent("get")` 返回 true（getter）或 false（setter）。
- **所有权 / 错误 / 调用**：不分配：前瞻交给 `peekNextKindWithLineTerminator`，peek token 的释放与游标回滚都在那里。无 error（前瞻失败被吞成 `TOK_EOF`，这里返回 null）。唯一调用方：类成员解析 `src/parser.zig:13747`。

### `registerClassPrivateElement` (`src/parser.zig:13516`)

- **签名**：`fn registerClassPrivateElement(s: *State, atom_id: Atom, kind: ClassPrivateElementKind) Error!void`。
- **作用**：把一个私有元素登记进 `class_private_elements`，并先检查与同名元素的冲突。
- **实现**：先线性扫 `class_private_elements`：对每条同名记录调 `classPrivateElementsConflict(entry, kind, s.is_static)`，只有「一 getter 一 setter 且 static 归属相同」这一种组合不算冲突，其余（重复字段、重复方法、getter 与 getter、static 与非 static 混搭）一律 `failUnexpectedToken`。无冲突则用 `s.function.memory.allocator` 追加一条 `{ atom, kind, is_static }`。
- **所有权 / 错误 / 调用**：向 `State.class_private_elements` 追加一条（`function.memory.allocator`，OOM 上抛）；存的是借用 id，**没有 retain**（rc 时代那句 `const retained = atom_id;` 中转已删）。列表归 `State`（`src/parser.zig:1062` 释放），类体结束时按保存长度 `truncateClassPrivateElements` 回退。冲突时返回 `failUnexpectedToken()` 的 `error.UnexpectedToken`。调用方 4 处：访问器 `src/parser.zig:13754`、方法 13822、字段 13847/13856。

### `addPrivateClassBinding` (`src/parser.zig:13533`)

- **签名**：`fn addPrivateClassBinding(s: *State, atom_id: Atom, kind: function_def_mod.VarKind) Error!u16`。
- **作用**：为一个私有类元素建出它的词法 const 绑定行，并在行上记下 static 归属。
- **实现**：对照 QuickJS `add_private_class_field`：每个私有元素都表示成一条词法 const `VarDef`，只有解析期这一行额外保留用于校验 getter/setter 配对的 static 判别位。实现是 `addScopeVar(atom_id, kind, true, true)`（后两个 true 即 is_lexical、is_const），返回下标为负或越过 `curFunc().vars.len` 时报 `Error.ParserInvariant`，否则把 `vars[idx].is_static_private` 置成当前的 `s.is_static` 再返回下标。
- **所有权 / 错误 / 调用**：经 `addScopeVar` 在当前 `FunctionDef` 上建一行 lexical+const 的私有绑定（OOM 来自那里），再写 `is_static_private`。特有 ICE：返回下标为负或越界时 `Error.ParserInvariant`。`atom_id` 借用。调用方 4 处：`src/parser.zig:13776`、13824、`addPrivateClassFieldBinding`(14010)、`preparePrivateAccessorBinding`(14026)。

### `addPrivateClassFieldBinding` (`src/parser.zig:13540`)

- **签名**：`fn addPrivateClassFieldBinding(s: *State, atom_id: Atom) Error!void`。
- **作用**：声明一个私有字段 `#x`：建出它的词法绑定，并在类体作用域里把该字段的唯一私有 symbol 初始化进去。
- **实现**：先 `addPrivateClassBinding(s, atom_id, .private_field)` 建绑定，再按 qjs `js_parse_class` 的顺序发 `private_symbol <atom>` 物化这个私有名的唯一 symbol，最后 `emitScopePutVarInit(atom_id)` 把它写进刚建的词法槽（初始化写入，绕过 TDZ 检查）。
- **所有权 / 错误 / 调用**：绑定行写进 `curFunc().vars`（内存归 fd）；`atom_id` 是借用 id，作为 `private_symbol` 的 atom 操作数写进 code 与 `atom_operands`，这里不 retain。错误：`addScopeVar` 一侧的 `error.OutOfMemory`、`addPrivateClassBinding` 下标越界的 `Error.ParserInvariant`、两条发射的 builder 三元组。调用方 2 处，都在 `parseClassElement`（`src/parser.zig:13848` 有初始化式、`13857` 无初始化式）。

### `preparePrivateAccessorBinding` (`src/parser.zig:13548`)

- **签名**：`fn preparePrivateAccessorBinding(s: *State, atom_id: Atom, is_getter: bool) Error!void`。
- **作用**：为私有 getter/setter 准备绑定：已有对偶就升级成 `private_getter_setter`，否则新建一条。
- **实现**：`findCurrentScopeVar` 在当前作用域找到同名行时走「配对」路径：该行的 `is_static_private` 与当前 `s.is_static` 不一致即 `failUnexpectedToken`；`var_kind` 必须正好是对偶的那一种（本次是 getter 就要求已有 `.private_setter`，反之亦然），不是则 `failUnexpectedToken`——这挡住了重复的 getter/getter 与字段和访问器同名；通过则把该行升级成 `.private_getter_setter`。没有同名行时新建一条 `.private_getter` 或 `.private_setter` 绑定。
- **所有权 / 错误 / 调用**：命中同名行时只就地把 `var_kind` 升级成 `private_getter_setter`，不分配；否则经 `addPrivateClassBinding` 新建一行（OOM / `ParserInvariant`）。静态位不一致或已有种类不是配对的另一半时返回 `failUnexpectedToken()` 的 `error.UnexpectedToken`。唯一调用方 `src/parser.zig:13755`。

### `privateSetterAtom` (`src/parser.zig:13560`)

- **签名**：`fn privateSetterAtom(s: *State, private_atom: Atom) Error!Atom`。
- **作用**：给私有 setter 造一个名字为 `<私有名><set>` 的私有 symbol atom。
- **实现**：先用 `s.function.atoms.name(private_atom)` 取私有名的字符串，取不到就是内部不变量错 `Error.InvalidIdentifier`；在 `s.function.memory` 上开一块 `name.len + "<set>".len` 的缓冲（`defer free`），拼出 `<私有名><set>`，交 `newSymbol(bytes, .private)` 造一个新的私有 symbol atom。getter 与 setter 因此拿到两个不同的 atom，同名访问器才能在同一个类里共存。
- **所有权 / 错误 / 调用**：临时缓冲由本函数 `defer` 释放。返回的是 `newSymbol` 新建的 atom id，借用语义：编译期由 `CompileAtomScope` 作为 GC 根钉住（`newSymbol` 走 `noteCompileScope`），调用方不释放。失败：`Error.InvalidIdentifier`（取不到名字）与 `error.OutOfMemory`。
### `markPrivateBrandNeeded` (`src/parser.zig:13570`)

- **签名**：`fn markPrivateBrandNeeded(s: *State) Error!void`。
- **作用**：标记本类需要私有 brand；实例侧还要把字段初始化子函数开头休眠的 brand 前奏打开。
- **实现**：static 侧只置 `class_static_private_brand_needed = true` 就返回。实例侧置 `class_instance_private_brand_needed = true` 后，经 `ensureClassFieldsInitFunction` 拿到字段初始化子函数（下标越过 `parent.child_list.len` 即 `Error.ParserInvariant`），取它的 `builder`（为空或 `code_len == 0` 都是 `ParserInvariant`），把首字节的 `push_false` 就地改写成 `push_true`——`createClassFieldsInitFunction` 预先埋了一段以 `push_false` + `if_false` 跳过的休眠 brand 前奏，第一个需要 brand 的私有方法/访问器在这里把它点亮；已经是 `push_true` 则什么都不做，其它值说明前奏被破坏，报 `ParserInvariant`。
- **所有权 / 错误 / 调用**：实例分支会经 `ensureClassFieldsInitFunction` 现建字段初始化子函数（子 `FunctionDef` 归父的 `child_list`，OOM 上抛），然后**直接改写那个子函数已发射字节码的第一个字节**（`push_false` → `push_true`）。因此它对状态一致性极敏感：child 下标越界、`builder` 缺失、`code_len == 0`、首字节不是 `push_true`/`push_false` 四种情况都返回 `Error.ParserInvariant`。调用方：私有访问器 `src/parser.zig:13763`、私有方法 13825。

### `isForbiddenPublicFieldName` (`src/parser.zig:13591`)

- **签名**：`fn isForbiddenPublicFieldName(s: *State, atom_id: Atom) bool`。
- **作用**：判断某个公有字段名是否被规范禁止：实例字段不能叫 `constructor`，静态字段还不能叫 `prototype`。
- **实现**：非 static 时只比 `atom_module.ids.constructor`；static 时再并上 `atom_module.ids.prototype`。两者都是 atom id 的恒等比较，不查名字字符串。
- **所有权 / 错误 / 调用**：无：比预定义 id `constructor`（静态时再加 `prototype`），无分配、无 error。调用方 3 处：公共字段名检查 `src/parser.zig:13932`、13942、13946。

### `classNameAtomOwned` (`src/parser.zig:13599`)

- **签名**：`fn classNameAtomOwned(s: *State) ?Atom`。
- **作用**：取当前 class 声明名字的 atom，不能当类名时返回 null。
- **实现**：`TOK_IDENT` 时取 `token.payload.ident.atom`，但若 `escapedIdentifierIsReservedClassName` 判定这个带转义的写法其实是保留字则返回 null；`TOK_AWAIT` 且 `canUseAwaitAsIdentifier` 成立时返回 `tok.keywordAtom(kind)`（sloppy 非 async 上下文里 `await` 可以当类名）；其余 kind 返回 null。源码注释已写明本函数交出的是借用 id，由 `CompileAtomScope` 作根、调用方不释放。
- **所有权 / 错误 / 调用**：返回的是一个**借用**的 atom id，不是 retain，调用方不释放——`parseClass` 两处调用点都只是把它存进 `class_name` 就继续解析，parser 里没有任何配对的释放。函数上方原先那句 `Return one owned retain for the current class name. The caller frees.` 是 rc 时代的遗留（已改实）：`TOK_IDENT` 分支直接交出 `s.token.payload.ident.atom`，`TOK_AWAIT` 分支交出 `tok.keywordAtom(kind)` 这个预定义 id，两条路径都不调用任何 retain。TGC S3-c 之后 `lexer.releaseTokenPayload` 只释放 token 的字节缓冲、不再释放 atom（见 src/lexer.zig:127-140 的注释「the token's id is an ordinary borrow now」），id 的存活改由整场编译的 `CompileAtomScope` 根提供者保证，sweep 在编译结束后才回收。所以这个 id 在 `advance()` 之后仍然有效，跨整个 `parseClass` 都可用；`advance()` 释放的是 token payload，不是 atom。
### `escapedIdentifierIsReservedClassName` (`src/parser.zig:13612`)

- **签名**：`fn escapedIdentifierIsReservedClassName(s: *State, atom_id: Atom, has_escape: bool) bool`。
- **作用**：带转义写法的标识符用作类名时，是否其实是保留字。
- **实现**：`has_escape` 为假直接 false——只有带 Unicode 转义的写法才要在这里补判。为真时沿用 `escapedIdentifierIsReservedWordForShorthandBinding` 那一整组保留字，再并上一条：module、async 函数或 class static block 上下文里的 `await` 也不能当类名。
- **所有权 / 错误 / 调用**：无分配、无 error：转调 `escapedIdentifierIsReservedWordForShorthandBinding`，再补一条 module/async/static-block 下 `await` 的判定（名字比较借 atom 表字节）。唯一调用方：类名 atom 取用 `src/parser.zig:14070`。

### `enterFieldInitFunction` (`src/parser.zig:13645`)

- **签名**：`fn enterFieldInitFunction(s: *State, init_fd: *function_def_mod.FunctionDef) Error!FieldInitContext`。
- **作用**：切进 class 字段初始化子函数：保存被顶掉的十项解析现场并装上初始化器上下文。
- **实现**：先把会被顶掉的十项解析现场整体存进 `FieldInitContext`：`emit_to_function_def`、`last_opcode_source_offset`、`scope_level`、`is_strict` 与 `lex.is_strict_mode`、`allow_super` / `allow_super_call`、`new_target_allowed`、`in_constructor`、`last_function_child_index`。随后 `pushFunction(init_fd)`——它下面再没有任何可失败的语句（源码注释据此断言：拿到 context 的调用方必然配对恰好一次 `leaveFieldInitFunction`），失败时现场也还没被改动。成功后装上初始化器上下文：`emit_to_function_def = true`、`last_opcode_source_offset = null`、`scope_level = 0`、strict（类体恒为 strict）、`allow_super = true` 但 `allow_super_call = false`（字段初始化器里可以 `super.x`，不能 `super()`）、`new_target_allowed = true`、`in_constructor = false`。配对的 `leaveFieldInitFunction` 负责把这十项装回去并弹出函数。
- **所有权 / 错误 / 调用**：不分配长期对象，只把 10 个 `State` 字段存进返回的 `FieldInitContext` 纯值；唯一可失败处是 `pushFunction`（函数栈扩容，`error.OutOfMemory`），而且它在所有字段改写之前——所以拿到 context 的调用方总能配上且只配一次 `leaveFieldInitFunction`（源码 14125-14126 的注释就是这个不变量）。`init_fd` 的所有权仍在类解析侧（父 `FunctionDef` 的 `child_list`）。调用方：`enterStaticBlockFunction`(`src/parser.zig:14156`)、字段初始化 14203。

### `leaveFieldInitFunction` (`src/parser.zig:13673`)

- **签名**：`fn leaveFieldInitFunction(s: *State, saved: FieldInitContext) void`。
- **作用**：退出字段初始化子函数：`popFunction` 后把十项现场逐个装回。
- **实现**：先 `s.popFunction()` 退出初始化子函数，再把 `FieldInitContext` 的十个字段逐项写回：`emit_to_function_def`、`last_opcode_source_offset`、`scope_level`、`is_strict`、`lex.is_strict_mode`、`allow_super`、`allow_super_call`、`new_target_allowed`、`in_constructor`、`last_function_child_index`。与 `enterFieldInitFunction` 一一配对：后者在 `pushFunction` 之后把这些位设成字段初始化器该有的形态（强制 strict、`scope_level = 0`、允许 `super` 属性但禁 `super()`）。
- **所有权 / 错误 / 调用**：不释放任何东西：`popFunction` 只缩 `cur_func_stack`（子 `FunctionDef` 由父的 `child_list` 持有），其余是字段回写。不分配、无 error。调用方 3 处：`leaveStaticBlockFunction`(`src/parser.zig:14170`)、14204(errdefer)、14234。

### `enterStaticBlockFunction` (`src/parser.zig:13687`)

- **签名**：`fn enterStaticBlockFunction(s: *State, init_fd: *function_def_mod.FunctionDef) Error!StaticBlockContext`。
- **作用**：在 `enterFieldInitFunction` 之上再保存 static block 特有的四项，并设 `in_class_static_block = true`、`is_static = false`。
- **实现**：先 `enterFieldInitFunction(s, init_fd)` 取走那十项通用现场（同时压入子函数、强制 strict 等），再额外留底四项 static block 独有的状态：`pending_function_name`、`pending_function_is_decl`、`in_class_static_block`、`is_static`。随后把前两项清成 null / false（静态块里的函数不继承外面待定的函数名），`in_class_static_block = true`（`await` 在此成为保留字），`is_static = false`（块体内部的成员判定不再算静态位置）。
- **所有权 / 错误 / 调用**：分配与失败面全部来自内嵌的 `enterFieldInitFunction`（`pushFunction` 的 `error.OutOfMemory`）；自己只多存 4 个字段进 `StaticBlockContext`。配对的还原是 `leaveStaticBlockFunction`(`src/parser.zig:14169`)，它再转调 `leaveFieldInitFunction`。唯一调用方：static block 解析 `src/parser.zig:14569`。

### `leaveStaticBlockFunction` (`src/parser.zig:13702`)

- **签名**：`fn leaveStaticBlockFunction(s: *State, saved: StaticBlockContext) void`。
- **作用**：离开 class static block 子函数，恢复外层解析现场。
- **实现**：`leaveFieldInitFunction(s, saved.field_init)`，再写回 `pending_function_name` / `pending_function_is_decl` / `in_class_static_block` / `is_static`。
- **所有权 / 错误 / 调用**：不分配。与 `enterStaticBlockFunction` 成对。

### `emitFieldInitializer` (`src/parser.zig:13720`)

- **签名**：`noinline fn emitFieldInitializer( s: *State, atom_id: Atom, is_private: bool, is_computed: bool, has_initializer: bool, is_static: bool, ) Error!void`。
- **作用**：把一条 class 字段初始化写进对应的 init 子函数：进子函数、推 receiver、可选 RHS、define、drop。
- **实现**：static 走 `ensureClassStaticInitFunction`，否则 `ensureClassFieldsInitFunction`；下标越界 `ParserInvariant`。`enterFieldInitFunction` + `errdefer leave`。receiver：static 用 `emitScopeGetVar(atom_this)`，instance 用 `push_this`（qjs `js_parse_class`：实例字段从传入的 this 起）。private/computed 再 `emitScopeGetVar(atom_id)` 取 key。有初始化则 `parseAssignExpr`，再 `setObjectNameComputed` 或 `setObjectName`；无则 `undefined`。define：private → `define_private_field`，computed → `define_array_el`，否则 `define_field` + atom。最后 `drop` 并 `leaveFieldInitFunction`。outlined leftover：把 instance/static/computed 三份拷贝收成运行时标志。
- **所有权 / 错误 / 调用**：失败走 `parser_core.Error`；写入 init 子 `FunctionDef.builder`。`emitStaticFieldInitializer` / `emitInstanceFieldInitializer` 是 inline 包装。

### `emitStaticFieldInitializer` (`src/parser.zig:13770`)

- **签名**：`inline fn emitStaticFieldInitializer( s: *State, atom_id: Atom, is_private: bool, is_computed: bool, has_initializer: bool, ) Error!void`。
- **作用**：发出一条静态类字段的初始化代码（写进类的静态初始化子函数）。
- **实现**：单行转调 `emitFieldInitializer(s, atom_id, is_private, is_computed, has_initializer, true)`——最后那个 `true` 即静态臂：目标子函数取 `ensureClassStaticInitFunction`，接收者用 `emitScopeGetVar(atom_this)`（静态初始化器里的 `this` 是类构造器本身）而不是 `push_this`。`inline` 且只传布尔标志，不在包装层留任何多余代码。
- **所有权 / 错误 / 调用**：`inline` 纯转发，不分配、无自有 error，一切归 `emitFieldInitializer`（含它内部对静态初始化子函数的 `ensureClassStaticInitFunction`）。调用方 6 处：`parseClassElement`（`src/parser.zig:13851` / `13859` / `13935`）、`emitPublicFieldNoInitializer`（`src/parser.zig:14249`）、`emitStaticClassComputedElement`（`src/parser.zig:14507` / `14509`）。

### `emitPublicFieldNoInitializer` (`src/parser.zig:13780`)

- **签名**：`fn emitPublicFieldNoInitializer(s: *State, atom_id: Atom) Error!void`。
- **作用**：发出没有初始化式的公有字段（`class C { x }`）的定义代码——值取 `undefined`。
- **实现**：按 `s.is_static` 分流：静态走 `emitStaticFieldInitializer(s, atom_id, false, false, false)`，实例走 `emitInstanceFieldInitializer(s, atom_id, false, false)`；三个 false 分别表示非私有、非 computed、无初始化式。无初始化式的字段由 `emitFieldInitializer` 统一补一条 `undefined`（对照 qjs `js_parse_class`）。
- **所有权 / 错误 / 调用**：不分配、无自有 error，只按 `s.is_static` 二选一转发。调用方 2 处，都在 `parseClassElement`（`src/parser.zig:13943` / `13947`）。

### `emitInstanceFieldInitializer` (`src/parser.zig:13788`)

- **签名**：`inline fn emitInstanceFieldInitializer( s: *State, atom_id: Atom, has_initializer: bool, is_private: bool, ) Error!void`。
- **作用**：发出一条实例类字段的初始化代码（写进类的实例字段初始化子函数）。
- **实现**：单行转调 `emitFieldInitializer(s, atom_id, is_private, false, has_initializer, false)`：`is_computed` 固定 false，最后的 `false` 选实例臂——目标子函数取 `ensureClassFieldsInitFunction`，接收者用 `push_this`（实例初始化器从传入的 receiver 起手）。同样是 `inline` 薄包装。
- **所有权 / 错误 / 调用**：`inline` 纯转发，不分配、无自有 error；目标子函数由 `emitFieldInitializer` 内的 `ensureClassFieldsInitFunction` 负责。调用方 4 处：`parseClassElement`（`src/parser.zig:13853` / `13861` / `13937`）、`emitPublicFieldNoInitializer`（`src/parser.zig:14252`）。

### `ensureClassFieldsInitFunction` (`src/parser.zig:13797`)

- **签名**：`fn ensureClassFieldsInitFunction(s: *State) Error!usize`。
- **作用**：取当前类的实例字段初始化子函数在父 `child_list` 里的下标，第一次用到时才创建。
- **实现**：`s.class_fields_init_child_index` 有值就直接返回（每个类只建一个）。还没有时 `createClassFieldsInitFunction(s, true)`——`true` 表示带上那段休眠的实例 brand 前奏，之后由 `markPrivateBrandNeeded` 按需点亮——并把返回的 child 下标缓存进 `class_fields_init_child_index`。
- **所有权 / 错误 / 调用**：幂等：已建过就返回缓存的 `class_fields_init_child_index`，否则 `createClassFieldsInitFunction` 用 `function.memory.create` 新建一个 `FunctionDef` 并挂进父的 `child_list`——所有权归父 fd，构建中途失败由那边的 `errdefer discardFunctionDef` 回收。错误即被调方的 `error.OutOfMemory` 与 `Error.ParserInvariant`。调用方：`markPrivateBrandNeeded`(`src/parser.zig:14045`)、14198。

### `ensureClassStaticInitFunction` (`src/parser.zig:13804`)

- **签名**：`fn ensureClassStaticInitFunction(s: *State) Error!usize`。
- **作用**：取当前类的静态初始化子函数下标，第一次用到时才创建。
- **实现**：与 `ensureClassFieldsInitFunction` 同形，缓存字段换成 `s.class_static_init_child_index`，创建时传 `false`：静态侧不需要实例 brand 前奏（静态私有 brand 由 `class_static_private_brand_needed` 在类构造处理）。
- **所有权 / 错误 / 调用**：同 `ensureClassFieldsInitFunction`（子 `FunctionDef` 归父 `child_list`，错误来自 `createClassFieldsInitFunction`），差别是 `include_instance_brand_prologue = false` 且缓存在 `class_static_init_child_index`。调用方：`src/parser.zig:14196`、static block 14564。

### `createClassFieldsInitFunction` (`src/parser.zig:13811`)

- **签名**：`fn createClassFieldsInitFunction(s: *State, include_instance_brand_prologue: bool) Error!usize`。
- **作用**：新建一个 class 字段/静态初始化子函数 FunctionDef，挂进父函数的 `child_list` 与 cpool。
- **实现**：在 `s.function.memory` 上 `create` 一个 `FunctionDef` 并 `init`，名字固定 `atom_class_fields_init`；`errdefer` 在尚未挂进父函数（`child_moved` 为假）时 `discardFunctionDef` 回收。随后逐项设形态：继承父函数的 `filename` / `script_or_module` / `use_short_opcodes`，位置取当前 token 的行列，`parent` 与 `parent_scope_level` 指向父函数，`is_strict_mode = true`、`func_type = .method`、`func_kind = .normal`、`has_prototype = false`、`has_home_object` / `need_home_object` / `has_this_binding` / `new_target_allowed` / `super_allowed` 为真、`arguments_allowed = false`；再 `appendScope(-1)` 建根作用域、`ensureBuilderForFd` 备好 Builder。`include_instance_brand_prologue` 为真时直接往 Builder 写一段休眠前奏：`push_false`、`if_false skip`、`push_this`、`scope_get_var home_object`、`add_brand`、绑定 `skip`，最后 `invalidateLastOpcode`；那条 `push_false` 就是 `markPrivateBrandNeeded` 日后要改成 `push_true` 的开关，跳过目标以 LabelId 出生而不是旧的绝对偏移 base+15。最后在父函数 cpool 占一个 `undefined` 槽、把槽号记进 `parent_cpool_idx`，`addChild` 挂上去并返回 child 下标。
- **所有权 / 错误 / 调用**：这是本族唯一的真分配点——子 `FunctionDef` 由 `s.function.memory.create` 分出，在 `addChild` 之前由 `errdefer if (!child_moved) discardFunctionDef(child_fd)` 兜底回收；`child_moved = true` 之后所有权整体移交 `parent_fd.child_list`（随父函数一起释放或落盘），父函数 cpool 里那个 `undefined` 槽与子函数自己的 Builder 同归子 fd。atom 用的是预定义 `atom_class_fields_init` 与 `atom_module.ids.home_object`，借用不 retain。错误：`appendScope` / `ensureBuilderForFd` 被显式收成 `error.OutOfMemory`，brand 前奏的六条发射经 `mapBuilderError` 给出 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`，`appendCpool` 与 `addChild` 给 `error.OutOfMemory`。调用方 2 处：`ensureClassFieldsInitFunction`（`src/parser.zig:14266`，带 brand 前奏）与 `ensureClassStaticInitFunction`（`src/parser.zig:14273`，不带）。

### `finishClassFieldsInitFunction` (`src/parser.zig:13858`)

- **签名**：`fn finishClassFieldsInitFunction(s: *State) Error!void`。
- **作用**：结束存在的实例字段初始化子函数。
- **实现**：没有 class_fields_init_child_index 则返回，否则将该索引交给 finishClassInitFunction。
- **所有权 / 错误 / 调用**：初始化函数收尾错误向上传播；无子函数时不分配。

### `finishClassStaticInitFunction` (`src/parser.zig:13863`)

- **签名**：`fn finishClassStaticInitFunction(s: *State) Error!void`。
- **作用**：结束存在的类静态初始化子函数。
- **实现**：没有 class_static_init_child_index 则返回，否则调用 finishClassInitFunction。
- **所有权 / 错误 / 调用**：共享类初始化收尾逻辑，错误向上传播。

### `finishClassInitFunction` (`src/parser.zig:13868`)

- **签名**：`fn finishClassInitFunction(s: *State, child_index: usize) Error!void`。
- **作用**：给初始化子函数收尾：最后一条不是终结指令时补 `return_undef`。
- **实现**：`child_index` 越过 `parent_fd.child_list.len`、或子函数没有 `builder`，都报 `Error.ParserInvariant`。终结判定照 qjs `js_is_live_code` 的形状做在子函数的临时指令流上：`v2b.last_opcode_pos < 0`（`get_prev_opcode` 无效，例如刚绑过 merge 标签）按「活」处理、需要补终结；否则看最后一条指令，是 `return` / `return_undef` / `return_async` / `throw` 才算已终结。需要补时发 `return_undef` 并 `recordControl(.terminal)`。
- **所有权 / 错误 / 调用**：不分配；注意它写的**不是当前函数**的 Builder——`v2b` 直接取自 `parent_fd.child_list[child_index].builder`，绕过 `activeBuilder()` 往子函数的指令流上补码。自有错误两条 `Error.ParserInvariant`（下标越界、子函数没有 Builder），`emitOp` 与 `recordControl` 的失败经 `mapBuilderError` 变成 `OutOfMemory` / `BytecodeOverflow` / `ParserInvariant`。调用方 2 处：`finishClassFieldsInitFunction`（`src/parser.zig:14327`）与 `finishClassStaticInitFunction`（`src/parser.zig:14332`）。

### `registerClassPrivateBoundName` (`src/parser.zig:13887`)

- **签名**：`fn registerClassPrivateBoundName(s: *State, atom_id: Atom) Error!void`。
- **作用**：把一个私有名 atom 登记进 `class_private_bound_names`（已有同名则不重复追加）。
- **实现**：先线性扫 `class_private_bound_names`，已有同一个 atom 就直接返回（同名私有元素只登记一次，getter/setter 对偶共用一条）。否则直接 `class_private_bound_names.append` 一次（rc 时代的 `appendRetainedAtom` 包装已删），存进去的是借用 id——这份名字要活到整个类体解析完，靠的是 `CompileAtomScope` 在编译期把 id 钉成 GC 根。
- **所有权 / 错误 / 调用**：去重后直接 `list.append` 一个借用 id（rc 时代的 `appendRetainedAtom` 包装已删）；列表内存来自 `function.memory.allocator`，`error.OutOfMemory` 是唯一 error。`class_private_bound_names` 归 `State`（`src/parser.zig:1064` 释放），类体结束按保存长度截断。唯一调用方：类体私有名收集 `src/parser.zig:14626`。

### `classPrivateNameIsBound` (`src/parser.zig:13895`)

- **签名**：`fn classPrivateNameIsBound(s: *State, atom_id: Atom) bool`。
- **作用**：判断指定私有名是否已在当前类绑定。
- **实现**：线性扫描 class_private_bound_names，比对 atom id；命中 true，遍历结束 false。
- **所有权 / 错误 / 调用**：借用 atom id，不 intern、不分配。

### `classPrivateElementsConflict` (`src/parser.zig:13902`)

- **签名**：`fn classPrivateElementsConflict( existing: ClassPrivateElement, new_kind: ClassPrivateElementKind, new_is_static: bool, ) bool`。
- **作用**：同名私有元素是否冲突。
- **实现**：唯一的不冲突组合是「一个 getter 配一个 setter 且 static 属性相同」：先算 `getter_setter_pair`（existing 是 getter 而 new 是 setter，或反之），返回 `!getter_setter_pair or existing.is_static != new_is_static`。于是同名的两个字段、两个方法、两个 getter、两个 setter，以及 static 与非 static 混用的 getter/setter 对，全部判冲突。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：唯一不算冲突的组合是 getter/setter 配对且 `is_static` 相同。唯一调用方 `registerClassPrivateElement`(`src/parser.zig:13987`)。

### `privateNameAtom` (`src/parser.zig:13913`)

- **签名**：`fn privateNameAtom(s: *State, atom_id: Atom) Error!Atom`。
- **作用**：取这个私有名对应的 `#name` 私有 symbol atom，没有就新建；顺带置上 `private_name` feature。
- **实现**：先 `s.features.insert(.private_name)` 记下本次编译用到了私有名。随后 `findClassPrivateBoundName(s, atom_id, 0)`——窗口起点 0 意味着连外层类的绑定一起找，所以嵌套类里引用外层的 `#x` 能复用同一个 symbol；找到就返回，找不到才 `newClassPrivateAtom` 新建。
- **所有权 / 错误 / 调用**：不分配：命中已登记的私有名就返回列表里那个借用 atom id，未命中才转 `newClassPrivateAtom` 新造一个私有 symbol（那里分配临时缓冲并 `defer free`）。返回的 id 都是借用——编译期由 `CompileAtomScope` 作为 GC 根钉住，调用方不释放（`advance()` 释放的是 token payload，不是 atom）。错误来自 `newClassPrivateAtom`：`Error.InvalidIdentifier`（atom 查不到名字）与 `error.OutOfMemory`。另有副作用：`s.features.insert(.private_name)` 记下本次编译用到了私有名。

### `privateNameDeclarationAtom` (`src/parser.zig:13921`)

- **签名**：`fn privateNameDeclarationAtom(s: *State, atom_id: Atom, bound_start: usize) Error!Atom`。
- **作用**：同 `privateNameAtom`，但只在 `bound_start` 之后（即当前类自己的绑定窗口）里找已有私有 atom。
- **实现**：与 `privateNameAtom` 只差查找窗口：同样先置 `.private_name` feature，但 `findClassPrivateBoundName` 从调用方给的 `bound_start` 起找，即只看当前类自己新增的那段绑定。声明位置必须这样限定——内层类声明 `#x` 时不能把外层同名的私有 symbol 拿来复用，否则两个类的 `#x` 会串成同一个。
- **所有权 / 错误 / 调用**：与 `privateNameAtom` 同一套（借用 atom id、错误来自 `newClassPrivateAtom` 的 `Error.InvalidIdentifier` / `error.OutOfMemory`、顺带置 `.private_name` feature），差别只在查找起点由 `bound_start` 给定，因此只看当前类体登记的私有名，不会命中外层类的同名私有元素。

### `findClassPrivateBoundName` (`src/parser.zig:13929`)

- **签名**：`fn findClassPrivateBoundName(s: *State, atom_id: Atom, bound_start: usize) ?Atom`。
- **作用**：在 `class_private_bound_names` 的 `[bound_start, len)` 窗口里从内向外找匹配的私有 atom。
- **实现**：从 `class_private_bound_names` 尾部往前倒扫到 `bound_start` 为止（由内向外，先命中最近的那层类），逐条交给 `privateAtomMatchesName` 比名字，命中返回那个私有 atom，扫完返回 null。
- **所有权 / 错误 / 调用**：无分配、无 error：从 `bound_start` 往回找，返回列表里存的那个借用 atom id（带 `#` 前缀的私有名），调用方不释放。调用方 3 处：`#x in obj`(`src/parser.zig:4764`)、14381、14389。

### `privateAtomMatchesName` (`src/parser.zig:13939`)

- **签名**：`fn privateAtomMatchesName(s: *State, private_atom: Atom, atom_id: Atom) bool`。
- **作用**：私有 atom 的名字是否等于给定名字，`#x` 与 `x` 视为同一个。
- **实现**：两个 atom 都先经 `function.atoms.name` 取名字，任一取不到即 false。名字完全相同为真；否则若待比名字自己就以 `#` 开头，说明两个都是私有写法却不相等，直接 false；剩下一种情况是私有 atom 比待比名字长一个字节、首字节是 `#` 且其余部分逐字节相等，即 `#x` 与 `x` 视作同一个。
- **所有权 / 错误 / 调用**：无分配、无 error：两个名字都经 `function.atoms.name` 从 atom 表借出再比，兼容带 `#` 与不带 `#` 的写法（`#x` 匹配 `x`），任一 atom 查不到名字即返回 false。唯一调用方 `findClassPrivateBoundName`(`src/parser.zig:14400`)。

### `newClassPrivateAtom` (`src/parser.zig:13949`)

- **签名**：`fn newClassPrivateAtom(s: *State, atom_id: Atom) Error!Atom`。
- **作用**：为一个私有名新建 private symbol atom（名字不以 `#` 开头就补上 `#`）。
- **实现**：`function.atoms.name(atom_id)` 取不到名字报 `Error.InvalidIdentifier`。名字已经以 `#` 开头时直接 `newSymbol(name, .private)`。否则在 `s.function.memory` 上临时分配 `name.len + 1` 字节（`defer free`），首字节写 `#`、其余拷贝原名，再 `newSymbol(bytes, .private)`。每次调用都造一个新的 private symbol——私有名的身份靠 symbol 唯一性而不是字符串相等。
- **所有权 / 错误 / 调用**：临时缓冲在 `s.function.memory` 上分配并 `defer free`（名字已带 `#` 时连缓冲都不开）。返回的是 `atoms.newSymbol(..., .private)` 新建的 atom id，借用语义：编译期由 `CompileAtomScope` 钉住（`newSymbol` 走 `noteCompileScope`），调用方不释放。错误：atom 查不到名字时 `Error.InvalidIdentifier`（内部不变量），以及缓冲分配与 `newSymbol` 的 `error.OutOfMemory`。调用方：`privateNameAtom`(`src/parser.zig:14384`)、`privateNameDeclarationAtom`(14392)。

### `classComputedFieldTempAtom` (`src/parser.zig:13961`)

- **签名**：`fn classComputedFieldTempAtom(s: *State) Error!Atom`。
- **作用**：给 computed 字段名造一个 `__class_computed_field_<N>` 临时绑定名（N 取自自增的 `with_scope_id`）。
- **实现**：用 `std.fmt.allocPrint` 拼出 `__class_computed_field_{d}`，序号取 `s.with_scope_id` 后自增（与 `with` 作用域共用同一个计数器，只求全局唯一），`defer free` 释放临时缓冲，再 `function.atoms.internString(temp_name)` 得到 atom。computed 字段名要先求值存进这个临时绑定，等到初始化子函数里再取出来当键。
- **所有权 / 错误 / 调用**：临时名字串由 `allocPrint` 在 `function.memory.allocator` 上分配并 `defer free`；返回的是 `atoms.internString` 新 intern 的 atom id，借用语义（`CompileAtomScope` 钉住，调用方不释放）。副作用是 `s.with_scope_id += 1`，保证同一次编译里每个计算字段拿到不同的临时名。错误只有 `error.OutOfMemory`（`allocPrint` 或 `internString`）。

### `parseImport` (`src/parser.zig:14698`)

- **签名**：`fn parseImport(s: *State) Error!void`。
- **作用**：下降解析 `Import` 产生式并按需发射 phase-1 字节码。
- **实现**：
对照 `js_parse_import`（`quickjs.c:31312`）。四种：
- `import 'mod'` 副作用，可选 `with` 属性；
- `import x from 'mod'` 默认；
- `import * as ns from 'mod'` 命名空间（`module_decl` 槽）；
- `import { a as b, "s" as c } from 'mod'` 具名（字符串名必须 `as`）。

可与 default 组合（`import x, {a} from` / `import x, * as ns`）。`addModuleImportBinding` 拒绝重复局部名，闭包类型 namespace→`module_decl`，具名→`module_import`。`parseFromClause` 管 `from` 字符串和 `with`。
- **所有权 / 错误 / 调用**：具名分支在 fd 的 allocator 上建一条 `imports: ArrayList(ModuleImportSpec)`，由 `defer freeModuleImportSpecs` 释放（该函数今天只 `deinit` 数组本体，元素里的 atom 是借用 id；rc 时代的空循环与 `import_name_live` / `local_name_live` 这对写而不读的标志都已删）；真正留存的是 `curFunc().closure_var` 里的 import 槽与 `ensureModule()` 拿到的 `Record` 行（归 `FunctionBytecode`），存的都是借用 atom。错误：局部名重复、字符串 import 名缺 `as`、缺 import 子句等一律 `failExpectedDescription` 的 `error.UnexpectedToken`；closure 数超 u16 是 `error.BytecodeOverflow`；`internString` 与 `record.add*` 收成 `error.OutOfMemory`。唯一调用方 `parseImportStatement`（`src/parser.zig:9212`）。

### `validateModuleImportBindingName` (`src/parser.zig:14808`)

- **签名**：`fn validateModuleImportBindingName(s: *State, atom_id: Atom) Error!void`。
- **作用**：拒绝严格模式下非法的模块导入绑定名。
- **实现**：isInvalidStrictFunctionBindingName 为真时调用 failUnexpectedToken，否则成功返回。
- **所有权 / 错误 / 调用**：失败经过解析器诊断路径，不直接生成运行时 JS 值。

### `moduleHasExportName` (`src/parser.zig:14814`)

- **签名**：`fn moduleHasExportName(record: *const bytecode_module.Record, export_name: Atom) bool`。
- **作用**：模块记录里是否已经有这个导出名。
- **实现**：依次线性扫模块记录的三张表：`record.exports`（本地导出）、`record.indirect_exports`（`export ... from`）与 `record.star_exports`，任一条 `export_name` 相等即 true。star 表里名字为 `atom_star` 的条目（纯 `export * from 'm'`，导出名要到链接期才展开）显式排除在重名判定之外。
- **所有权 / 错误 / 调用**：无分配、无 error：扫 `Record` 的 exports / indirect_exports / star_exports 三张表（记录归 `function.module_record`，`atom_star` 的星号导出不参与重名）。调用方 3 处：`addModuleExportName`(`src/parser.zig:15321`)、`addModuleIndirectExport`(15387)、`addModuleStarExport`(15393)。

### `addModuleExportName` (`src/parser.zig:14827`)

- **签名**：`fn addModuleExportName(s: *State, export_name: Atom, local_name: Atom) Error!void`。
- **作用**：登记一条本地导出（`export { x }` / `export const x`）：导出名对外，局部名指向模块内的绑定。
- **实现**：先 `s.function.ensureModule()` 取（必要时建）模块记录，`moduleHasExportName` 查重后重名报 `unique export name`，否则 `record.addExport(export_name, local_name)`，追加失败转 `error.OutOfMemory`。
- **所有权 / 错误 / 调用**：`function.ensureModule()` 按需在 `FunctionBytecode` 上建 `module.Record`（所有权归它）；`record.addExport` 在 record 的 memory 上扩数组，两个 atom 以**借用 id** 存入（`src/bytecode.zig:3100` 明确不 retain），失败收敛成 `error.OutOfMemory`。重名时 `failExpectedDescription("unique export name")` 报 `error.UnexpectedToken`。13 处调用方：绑定导出 `src/parser.zig:10610`、12678，`export default` 与具名导出 15464-15489 等。

### `validateModuleLocalExports` (`src/parser.zig:14833`)

- **签名**：`pub fn validateModuleLocalExports(s: *State) Error!void`。
- **作用**：程序解析完后检查每条本地导出都有对应的绑定。
- **实现**：没有 `module_record`（不是模块）时直接返回。否则遍历 `record.exports`，逐条用 `hasKnownBinding(s, entry.local_name)` 确认导出的局部名确实在模块里声明过，缺一即报 `local export binding`。只查本地导出——间接导出与星号导出的名字解析属于链接期，模块内不需要有绑定。这一步必须等整个模块体解析完才能做，所以由 `compile` 在收尾处调用。
- **所有权 / 错误 / 调用**：不分配；逐条检查 `record.exports` 的 `local_name` 是否有对应绑定（`hasKnownBinding` 只读 closure_var/global_vars），缺失即 `failExpectedDescription("local export binding")` 的 `error.UnexpectedToken`。没有 module record 时直接返回。唯一调用方：`compileQjsProgram` 的模块收尾 `src/parser.zig:16285`，外面套 `propagateFailureHere`。

### `addModuleImportAttribute` (`src/parser.zig:14840`)

- **签名**：`fn addModuleImportAttribute(s: *State, request_index: u32, key: Atom, value: Atom) Error!void`。
- **作用**：登记一条 import attribute（`import x from 'm' with { type: 'json' }` 的键值对），挂在对应的 module request 上。
- **实现**：`ensureModule()` 后线性扫 `record.import_attributes`，同一个 `request_index` 上出现重复 `key` 报 `unique import attribute key`；通过则 `record.addImportAttribute(request_index, key, value)`。
- **所有权 / 错误 / 调用**：record 所有权同 `addModuleExportName`；key/value 两个 atom 借用存入。重复 key 报 `failExpectedDescription("unique import attribute key")` 的 `error.UnexpectedToken`，`addImportAttribute` 的失败收敛成 `error.OutOfMemory`。唯一调用方 `parseWithClause`(`src/parser.zig:15737`)。

### `addModuleImportBinding` (`src/parser.zig:14849`)

- **签名**：`fn addModuleImportBinding( s: *State, request_index: u32, import_name: Atom, local_name: Atom, is_namespace: bool, ) Error!void`。
- **作用**：登记一条 import 绑定：既在当前函数建出局部可见的闭包行，也在模块记录里留下链接期要填的条目。
- **实现**：局部名已被占用（`hasKnownBinding`）即报 `available local import binding`。`closure_var` 数量超过 `maxInt(u16)` 报 `error.BytecodeOverflow`。随后加一条 lexical + const 的 `closure_var`：对照 qjs `add_import`，namespace 导入用 `.module_decl`（自己拥有一个槽，链接期填入命名空间 cell），具名/默认导入用 `.module_import`（是某个导出绑定的别名）；`var_idx` 取追加前的长度、名字取局部名。返回下标为负或超过 `maxInt(u16)` 同样报 `BytecodeOverflow`。最后把 `(request_index, import_name, local_name, closure 下标, is_namespace)` 记进模块记录。
- **所有权 / 错误 / 调用**：两处写入：当前 `FunctionDef` 的 `closure_var`（`module_decl`/`module_import` 行）与 record 的 import 表，atom 均为借用 id。错误面比同族多两条：本地名已有绑定时 `error.UnexpectedToken`，closure 行数或返回下标超 `u16` 时 `error.BytecodeOverflow`；此外是 `addClosureVar` / `addImport` 的 `error.OutOfMemory`。调用方 5 处：`src/parser.zig:15208`、15233、15235、15288、15291。

### `ensureModuleDefaultExportBinding` (`src/parser.zig:14880`)

- **签名**：`fn ensureModuleDefaultExportBinding(s: *State) Error!void`。
- **作用**：为 `export default` 建出承载默认导出值的那条 `*default*` 绑定。
- **实现**：以 `let` 语义调 `s.defineVar(atom_star_default, .let_)`：模块体的顶层词法声明必须落成 `.global`（模块的顶层绑定走 global/module 层，不是函数局部槽），所以拿到 `.local` 或 `.argument` 说明作用域拓扑不对，报 `Error.ParserInvariant`。
- **所有权 / 错误 / 调用**：不分配（声明行由 `defineVar` 写进 fd），`atom_star_default` 是预定义 id。错误来自 `defineVar`：重复声明是 `failExpectedDescription("non-conflicting declaration")` 的 `error.UnexpectedToken`、追加失败是 `error.OutOfMemory`；本函数自己再加一条 `Error.ParserInvariant`——拿到 `.local` / `.argument` 说明模块顶层绑定没落在 global 层。调用方 2 处，都在 `parseExport`（`src/parser.zig:15468` 匿名 `export default class`、`15498` `export default expr`）。

### `addModuleIndirectExport` (`src/parser.zig:14887`)

- **签名**：`fn addModuleIndirectExport( s: *State, request_index: u32, export_name: Atom, import_name: Atom, is_namespace: bool, ) Error!void`。
- **作用**：登记一条间接导出（`export { a as b } from 'm'`、`export * as ns from 'm'`）——值不在本模块，链接期再去请求的模块里取。
- **实现**：`ensureModule()` 后同样用 `moduleHasExportName` 查重，重名报 `unique export name`；通过则 `record.addIndirectExport(request_index, export_name, import_name, is_namespace)`，`is_namespace` 区分 `export * as ns` 与具名转出。
- **所有权 / 错误 / 调用**：同 `addModuleExportName` 的 record 所有权与借用语义：重名报 `error.UnexpectedToken`，`addIndirectExport` 失败收敛成 `error.OutOfMemory`。调用方：`export { x } from`(`src/parser.zig:15558`)、`export * as ns from`(15590)。

### `addModuleStarExport` (`src/parser.zig:14899`)

- **签名**：`fn addModuleStarExport(s: *State, request_index: u32, export_name: Atom) Error!void`。
- **作用**：登记一条 `export * from 'm'` 的星号导出。
- **实现**：与前两者的差别只在查重条件：`export_name == atom_star` 时跳过 `moduleHasExportName`——纯星号转出可以出现多条（多个来源模块），它导出哪些名字要到链接期才知道；其余（带具体名字的情形）照常查重后报 `unique export name`。通过则 `record.addStarExport(request_index, export_name)`。
- **所有权 / 错误 / 调用**：同族最后一个：`atom_star`（`export * from`）跳过重名检查，其余重名报 `error.UnexpectedToken`，`addStarExport` 失败收敛成 `error.OutOfMemory`。唯一调用方 `src/parser.zig:15592`。

### `addModuleRequestFromCurrentString` (`src/parser.zig:14906`)

- **签名**：`fn addModuleRequestFromCurrentString(s: *State) Error!u32`。
- **作用**：把当前这个字符串 token 当作 module specifier 登记成一条 module request，返回它的下标供 import/export 条目引用。
- **实现**：`moduleStringAtom(s)` 取当前字符串 token 并 intern 成 atom（当前 token 不是 `TOK_STRING` 时它会报 `module string`），`ensureModule()` 后 `record.addRequest(module_name)` 返回新 request 的下标；追加失败转 `error.OutOfMemory`。不做去重——同一个 specifier 写多次就有多条 request。
- **所有权 / 错误 / 调用**：模块名经 `moduleStringAtom` 新 intern 出一个 atom（`atoms.internString`，失败即 `error.OutOfMemory`；当前 token 不是字符串则 `failExpectedDescription("module string")` 的 `error.UnexpectedToken`）。新 id 同样由 `CompileAtomScope` 钉住，调用方不释放。`record.addRequest` 的失败收敛成 `error.OutOfMemory`，返回值是 request 下标。调用方：`import ... from`(`src/parser.zig:15190`)、`export ... from`(15703)。

### `moduleStringAtom` (`src/parser.zig:14912`)

- **签名**：`fn moduleStringAtom(s: *State) Error!Atom`。
- **作用**：从当前字符串 token 取得模块 specifier 的 atom。
- **实现**：先要求 TOK_STRING，否则报告 expected module string；然后 internString(token.payload.str.bytes)。
- **所有权 / 错误 / 调用**：intern 失败映射为 OutOfMemory；不推进 token，atom 的编译期存活由解析器的 atom 根机制承担。

### `isModuleNameToken` (`src/parser.zig:14917`)

- **签名**：`fn isModuleNameToken(kind: tok.TokenKind) bool`。
- **作用**：该 token kind 能否出现在 import/export 的名字位置。
- **实现**：`kind == TOK_IDENT or kind == TOK_STRING or tok.isKeyword(kind)` 三选一。关键字也放行，因为 `export { default as x }` / `import { class as C }` 这类位置上的名字是 ModuleExportName、不受保留字限制。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：`TOK_IDENT` / `TOK_STRING` / 任意关键字都可以当模块导入导出名。调用方 4 处：`src/parser.zig:15247`、15513、15529、15580。

### `moduleImportNameAtomOwned` (`src/parser.zig:14924`)

- **签名**：`fn moduleImportNameAtomOwned(s: *State) Error!Atom`。
- **作用**：取 import/export 名字位置上的 atom。
- **实现**：一个 switch：`TOK_IDENT` 取 `s.token.payload.ident.atom`；`TOK_NULL...TOK_AWAIT` 这段关键字区间取 `tok.keywordAtom(kind)` 的预定义 id；其余（即字符串形式的 ModuleExportName）交 `moduleStringAtom(s)` 新 intern 一个。
- **所有权 / 错误 / 调用**：三条路径返回的都是借用的 atom id，调用方不释放——`parseImport` / `parseExport` 的各个调用点都只把它交给 `addModuleExportName` / `addModuleImportBinding` 之类。函数上方原先那句「owned retain / 标识符的 atom 只活到 `advance()`」是 rc 时代的遗留（已改实）：TGC S3-c 之后 `lexer.releaseTokenPayload` 不再释放 atom（src/lexer.zig:127-140），标识符那份 id 与新 intern 的那份一样，都由整场编译的 `CompileAtomScope` 根列表钉住，`advance()` 之后仍然有效。失败：`moduleStringAtom` 可返回 `error.OutOfMemory` 或字符串不合法时的 `SyntaxError`。
### `isWellFormedModuleString` (`src/parser.zig:14932`)

- **签名**：`fn isWellFormedModuleString(bytes: []const u8) bool`。
- **作用**：模块名字符串是否是 well-formed UTF-8（不含孤立代理）。
- **实现**：逐个 UTF-8 序列走：`utf8ByteSequenceLength` 判不出长度、或长度越过 `bytes.len`，即 false。对三字节序列额外做代理区的显式拦截——首字节 `0xED`、次字节落在 `0xA0..0xBF` 且第三字节是合法续字节（`& 0xC0 == 0x80`）就是编码了孤立代理，返回 false。随后再 `utf8Decode` 完整校验一次，任何错误（含 `Utf8EncodesSurrogateHalf`）都返回 false。全程走完返回 true。
- **所有权 / 错误 / 调用**：无 `State`、无分配、无 error：逐字节走 UTF-8，遇到非法长度、截断或代理半区就返回 false（对应 spec 的 IsStringWellFormedUnicode）。入参是 token 的 `payload.str.bytes`，借用调用方的缓冲。调用方 3 处：`src/parser.zig:15517`、15532、15583。

### `freeModuleImportSpecs` (`src/parser.zig:14949`)

- **签名**：`fn freeModuleImportSpecs(s: *State, imports: *std.ArrayList(ModuleImportSpec)) void`。
- **作用**：释放临时模块导入规格数组。
- **实现**：仅调用 `imports.deinit(memory.allocator)`（rc 时代那条空体的逐元素循环已删）。
- **所有权 / 错误 / 调用**：释放列表 backing，不逐项释放 atom；列表销毁后不可继续使用原存储。

### `freeModuleExportSpecs` (`src/parser.zig:14953`)

- **签名**：`fn freeModuleExportSpecs(s: *State, exports: *std.ArrayList(ModuleExportSpec)) void`。
- **作用**：释放临时模块导出规格数组。
- **实现**：仅调用 `exports.deinit(memory.allocator)`（rc 时代那条空体的逐元素循环已删）。
- **所有权 / 错误 / 调用**：释放列表 backing，不逐项释放 atom；不承诺重复 deinit 安全。

### `parseExport` (`src/parser.zig:14959`)

- **签名**：`fn parseExport(s: *State) Error!void`。
- **作用**：下降解析 `Export` 产生式并按需发射 phase-1 字节码。
- **实现**：
对照 `js_parse_export`（`quickjs.c:31090`）。
- `export default class/function/async function`：有名走声明并导出该名；匿名走 `parseAnonymousDefaultFunctionDecl` / 类表达式，绑定 `*default*`。
- `export default expr`：求值、`emitAnonymousDefaultName(default)`、`ensureModuleDefaultExportBinding` 后 `emitScopePutVarInit(*default*)`。
- `export { a as b, "s" }` 本地或 `from` 再导出（字符串名要 well-formed）。
- `export * from` / `export * as ns from`。
- `export var/let/const/function/class/async function` 声明并导出。

`validateModuleLocalExports` 在程序结束后检查本地导出是否都有绑定。
- **所有权 / 错误 / 调用**：`export { ... }` 分支在 fd 的 allocator 上建 `export_specs: ArrayList(ModuleExportSpec)`，由 `defer freeModuleExportSpecs` 释放（同样只 `deinit` 数组本体；`local_name_live` / `export_name_live` 那对写而不读的标志已删）；导出名是借用 atom——标识符取 token 的 id，字符串名经 `moduleStringAtom` → `internString` 新 intern，两者都不 retain，最终存进 `ensureModule()` 的 `Record`（归 `FunctionBytecode`）。错误：重名导出、非良构（含孤立代理）字符串名、缺 `from` 等是 `error.UnexpectedToken`；`parseClass` 有名却返回 null 是 `Error.ParserInvariant`；`record.add*` 与 intern 是 `error.OutOfMemory`；发射走 builder 三元组。唯一调用方 `parseExportStatement`（`src/parser.zig:9219`）。

### `exportDefaultFunctionNameOwned` (`src/parser.zig:15147`)

- **签名**：`fn exportDefaultFunctionNameOwned(s: *State) ?Atom`。
- **作用**：前瞻 `function` 之后是否有声明名字（含 `function*`），匿名时返回 null。
- **实现**：`takeLexerCursorSnapshot` 之后立刻 `defer restoreLexerCursorSnapshot`——恢复必须在可失败的扫描之前就武装好：`nextInto()` 会在失败之前把 `pos` 推过已经读到的 token（标识符 atom 是最后才 intern 的），若失败时恢复尚未生效，调用方会从 token 中间继续解析，`export function f()` 会从 `(` 接着读并报出假的 SyntaxError，而不是让分配失败原样上抛。扫描本身：取第一个 token，是 `'*'`（`export default function*`）就再取一个，两种情形下只要落点是 `TOK_IDENT` 就返回它的 atom，否则（匿名声明）返回 null；两个扫描 token 都由本函数 `defer freeToken` 释放。扫描 token 在返回前就被释放，但 TGC S3-c 之后 `freeToken` 只还 token 的字节缓冲、不动 atom，id 由整场编译的 `CompileAtomScope` 钉住，所以交出去的是借用 id、调用方不释放（函数头原先那段「必须在这里取一份 owned retain，否则只是碰巧命中 atom 表 LIFO 空闲链」的论证是 rc 时代的遗留，已改实）。
- **所有权 / 错误 / 调用**：返回的是一个**借用**的 atom id，不是 retain，调用方不释放：`parseExport` 的四个调用点（15474 / 15487 / 15616 / 15636）都只把它交给 `addModuleExportName`。函数上方那段「the retain must be taken here … the caller frees」是 rc 时代的推理，实现里并没有任何 retain 调用——`return second.payload.ident.atom` 之后紧跟着的 `defer s.lex.freeToken(&second)` 在 TGC S3-c 之后只释放 token 的字节缓冲，不再释放 atom（src/lexer.zig:127-140：「the token's id is an ordinary borrow now -- the compile scope roots it and the sweep retires it」）。真正保证这个 id 在扫描 token 被释放、游标回滚、随后整段 `parseFunctionDecl` 重新解析之后仍然有效的，是 `CompileAtomScope`：`internDynamic` 等入口都会 `noteCompileScope`，把 id 记进编译期根列表，sweep 只在编译结束、scope `deinit` 之后才回收。因此注释里担心的「借用 id 只是碰巧命中 atom 表 LIFO 空闲链」并不成立。本函数自身除两个扫描 token 外不分配；失败只在 `nextInto` 上，一律吞成 null。
### `hasExportDefaultClassName` (`src/parser.zig:15173`)

- **签名**：`fn hasExportDefaultClassName(s: *State) bool`。
- **作用**：前瞻 `export default class` 后面有没有声明名字，据此决定这个类是具名声明还是匿名默认导出。
- **实现**：与 `exportDefaultFunctionNameOwned` 同一套顺序契约：`takeLexerCursorSnapshot` 之后立刻 `defer restoreLexerCursorSnapshot`，把游标恢复武装在可失败的 `nextInto` 之前；取一个 scratch token（失败吞成 false）、`defer freeToken`，只判断 `name.val == tok.TOK_IDENT`。它不交出 atom——真正的类名由随后的 `parseClass(s, true)` 返回。
- **所有权 / 错误 / 调用**：前瞻 token 由 `defer s.lex.freeToken` 释放，游标由 `takeLexerCursorSnapshot` / `defer restoreLexerCursorSnapshot` 回滚，且恢复必须在可失败的 `nextInto` 之前武装（注释指明与 `exportDefaultFunctionNameOwned` 同一契约）。无 error：`nextInto` 的失败（含 OOM）吞成 false。唯一调用方 `export default class`(`src/parser.zig:15462`)。

### `parseFromClause` (`src/parser.zig:15186`)

- **签名**：`fn parseFromClause(s: *State) Error!u32`。
- **作用**：解析 `from "mod"` 以及它后面可选的 `with { ... }`，把模块名登记成一条 module request 并返回它的下标。
- **实现**：对照 `js_parse_from_clause`（quickjs.c:31039）。`from` 按名字识别（`s.isIdent("from")`，是上下文关键字不是保留字），不匹配报 `failExpectedDescription("'from'")`；`advance` 之后要求当前 token 是 `TOK_STRING`，否则报 `"module string"`——模块名只能是字符串字面量。经 `addModuleRequestFromCurrentString(s)` 登记拿到 `request_index` 再 `advance`——`Record.addRequest` 一律追加新行、不按名字去重，所以同一个模块被 import 两次会得到两条 request。若接着是 `TOK_WITH`，把 `request_index` 交给 `parseWithClause` 挂属性。返回 `request_index`。
- **所有权 / 错误 / 调用**：不分配长期对象；模块名经 `internString` 得到借用 id 后交给 `Record.addRequest`（`src/bytecode.zig:3074`）存进归 `FunctionBytecode` 的 Record，不 retain。错误：缺 `from` / 非字符串名是 `failExpectedDescription` 的 `error.UnexpectedToken`，`internString` 与 `addRequest` 收成 `error.OutOfMemory`，`parseWithClause` 还会因重复属性键报 `error.UnexpectedToken`。调用方 5 处：`parseImport`（`src/parser.zig:15207` / `15231` / `15286`）与 `parseExport`（`src/parser.zig:15556` / `15588`）。

### `parseWithClause` (`src/parser.zig:15209`)

- **签名**：`fn parseWithClause(s: *State, request_index: u32) Error!void`。
- **作用**：解析 import attributes 的 `with { key: "value", ... }`，把每对属性挂到指定的 module request 上。
- **实现**：对照 `js_parse_with_clause`（quickjs.c:30950）。吃掉 `with` 后 `expectToken('{')`，循环到 `}` 或 EOF：key 必须是 `TOK_IDENT` 或 `TOK_STRING`（否则 `"import attribute key"`），标识符取 token 自己的 atom、字符串走 `moduleStringAtom` 新 intern；`expectToken(':')`；值只接受 `TOK_STRING`（否则 `"string attribute value"`），同样经 `moduleStringAtom`。每对交 `addModuleImportAttribute(s, request_index, key_atom, value_atom)`，重复 key 在那里报 `"unique import attribute key"`（parser.zig:15332-15339）。不是 `,` 就跳出循环，最后 `expectToken('}')`——因此允许尾随逗号。
- **所有权 / 错误 / 调用**：不分配长期对象：key 是字符串字面量时经 `moduleStringAtom` 新 intern（借用 id，`CompileAtomScope` 钉住），标识符 key 直接取 token 的 atom，value 同样走 `moduleStringAtom`。错误来源有四类：`advance` / `expectToken` 的词法错误与 `error.UnexpectedToken`、两处 `failExpectedDescription`、`moduleStringAtom` 的 OOM、`addModuleImportAttribute` 的重复 key 与 OOM。调用方：`import ... with {}`(`src/parser.zig:15193`)、`export ... from ... with {}`(15708)。

### `ensureParameterArgumentsLocals` (`src/parser.zig:15241`)

- **签名**：`fn ensureParameterArgumentsLocals(fd: *function_def_mod.FunctionDef) Error!void`。
- **作用**：给带参数表达式的函数把 `arguments` 相关的两条绑定提前物化好（箭头与 class static init 除外）。
- **实现**：`func_type` 是 `.arrow` 或 `.class_static_init` 的函数没有自己的 `arguments`，直接返回。其余函数依次调 `fd.ensureArgumentsBinding()` 建函数体里的 `arguments` 绑定、`fd.ensureArgumentsArgumentBinding()` 建参数环境里对应的那条；后者的 `error.InvalidScope` 说明当前不在参数作用域，属内部记账错，转成 `error.ParserInvariant`，`OutOfMemory` 原样上抛。
- **所有权 / 错误 / 调用**：无 `self`：在传入的 `fd` 上补两个绑定。`ensureArgumentsBinding` 的失败收敛成 `error.OutOfMemory`；`ensureArgumentsArgumentBinding` 的 `error.InvalidScope` 被翻译成 `Error.ParserInvariant`，这是本函数特有的 ICE 来源。arrow 与 class static init 直接返回。调用方 4 处：`ensureClosureVar`(`src/parser.zig:3125`、3187、3232)、参数环境建立 10585。

## 覆盖核对

- 清单函数数（本文件分到）: 146（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 146
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
