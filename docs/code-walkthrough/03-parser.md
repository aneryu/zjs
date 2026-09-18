# 03 — `src/parser.zig`：语法、作用域、发射

本册覆盖 `src/parser.zig`（约 16600 行、清单 649 个函数）。词法主体在 `src/lexer.zig`（02 册）；本文件在词法之后做 **递归下降 + 作用域 + phase-1 字节码发射**，再交给 `src/compiler/` 做变量/标签解析与 short layout。

TypeScript 只做语法擦除，不是类型检查器。

## 子文件目录

| 文件 | 内容 |
| --- | --- |
| [03-parser.md](03-parser.md) | 本页：类型地图、诊断、token 常数、`ParseState` 生命周期、`compile()` |
| [03-parser-scan.md](03-parser-scan.md) | `advance` / peek / expect / 失败诊断 / 箭头与 for 头前瞻 / 快照 |
| [03-parser-syntax.md](03-parser-syntax.md) | 表达式：`parseExpr*` / 一元 / 成员 / 主键 / 字面量 |
| [03-parser-syntax-stmt.md](03-parser-syntax-stmt.md) | 语句与 `var`/`for`/`try`/`switch` |
| [03-parser-syntax-fn.md](03-parser-syntax-fn.md) | 函数、箭头、解构、类 |
| [03-parser-scope.md](03-parser-scope.md) | 作用域、`defineVar`、闭包、标签、模块 import/export、私有名 |
| [03-parser-emit.md](03-parser-emit.md) | `emit*` / `Emitter` / Builder 门面 / lvalue / using 清理 |
| [03-parser-ts.md](03-parser-ts.md) | TypeScript 擦除：`enum` / `namespace` / 参数属性 |

## `compile()` 怎样走 parse → emit

一次 `parser.compile(compile_context, source, options)`（`compile_entry.compile`，`src/parser.zig:16059`）的数据流：

1. **Arena + atom 区间根**。解析期分配走 runtime 的短命 arena；所有 intern 的 atom 进 `CompileAtomScope`，直到产物自己带 tracer 边。
2. **TS 护栏**。`lexer.shouldStrip` 为真时先 `findUnsupportedTypeScriptSyntax`；不支持的语法直接 `Result.syntax_error`，不建 ParseState。
3. **`compileQjsProgram`**（`src/parser.zig:16180`）
   - `Lexer.init`，module/strict 旗；TS 源 `lex.enableTypeScript()`（类型注记在词法层丢掉）。
   - `ParseState.initCanonicalRootWithRuntime`：根函数从第一条指令就写进真正的 `FunctionDef`（不再先写一份可变 `Bytecode` 再克隆）。
   - `activateCompileRoots`：atom 根 +（若开启）cpool/RegExp/子函数的 value 根，避免编译中途 major GC 收走还没发布的单元格。
   - 按 `Mode`（script / module / eval_direct / eval_indirect）填 `FunctionDef` 旗：四模式的根都是 QuickJS 意义上的 eval bytecode，`is_global_var` 决定声明落 global 还是局部。
   - `beginProgramEmission`：程序体 `enter_scope` 是流的第一条事件。
   - eval 则 `enableEvalReturn`（`<ret>` 槽接每个表达式语句）；否则可选 completion。
   - **`parseDirectives`**：只在这里认 `"use strict"`，然后 **重算** `is_strict` / `is_global_var`（对齐 `js_parse_program`：指令 prologue 之后严格性才权威）。
   - **`parseProgramStatements`**：语句/声明递归下降，边解析边经 `Emitter` → `compiler.Builder` 发 **phase-1** opcode（`scope_get_var` 7 字节、`enter_scope`/`leave_scope`、绝对跳转标签）。
   - module 再 `validateModuleLocalExports`。
   - 收尾：completion → `get_loc <ret>; return`；否则 `isLiveCode` 则 `return_undef`。
4. **finalize**。allocator 切到 `artifactAllocator()`，调用 `bytecode.pipeline.finalize.createFunctionBytecode`（或 module 变体）：
   - `resolve_variables`：name+scope 降成 `get_loc` / `get_var` / 闭包，处理 TDZ、eval、with。
   - `resolve_labels`：LabelId 穿成最终跳转；生产 `layout=short`。
   - 打包 GC 管理的 `FunctionBytecode`（88 字节固定头 + 跟在后面的常量/变量/闭包/code 尾块）。
5. **所有权移交**。可变 `Bytecode` 壳和 arena 丢掉；`Result` 只持有 FB（script/eval）或 `ModuleArtifact{fb, record}`（module）。嵌入方用 `takeFunctionBytecodeValue` / `takeModuleArtifact` 拿走。

热路径：表达式下降（`parseAssignExpr2` → `parseUnary` → `parseLhsExpr` → `parsePrimary`）和 `Emitter.op*` inline 门面。冷路径：模块、class、Annex B、optional-chain delete 重写、诊断。

## 文件级类型

### `diagnostics`（`src/parser.zig:3`）

- `Position`：`offset` / `line`（从 1）/ `column`（从 1）。
- `SyntaxError`：`memory: *MemoryAccount`、`atoms: *AtomTable`、owned `message: []u8`、`filename: Atom`、`position`。由 `Result` 带着，`deinit` 把 message 还给 `MemoryAccount`。

### `token`（`src/parser.zig:52`）

QuickJS `TOK_*` 的 Zig 镜像：`Kind = i16`。字面量从 `TOK_NUMBER = -128` 起；赋值算子块顺序钉死 `OP_mul + (op - TOK_MUL_ASSIGN)`；关键字 `TOK_NULL..TOK_AWAIT` 与 `quickjs-atom.h` 逐行对齐。单字符标点就是 ASCII。`Payload` 是 `none` / `num` / `str` / `ident` / `regexp` 联合体。`TokenImpl` 有 `val, line_num, col_num, ptr, len, payload`。

`pub const lexer = @import("lexer.zig").namespace(token)`：词法器按这套 Kind 吐 token。

### `parser_core.Error`（`src/parser.zig:480`）

词法 `Error` 并上 `UnexpectedToken`、`InvalidLhs`、`InvalidNumberLiteral`、`InvalidIdentifier`、`InvalidAssignmentTarget`、`YieldOutsideGenerator`、`AwaitOutsideAsyncFunction`、`SyntaxError`、`BytecodeOverflow`、`ParserInvariant`、`StackOverflow`。`ParserInvariant` 不是源程序对错，经 ICE 通道上报。`StackOverflow` 由 `advance` 里的 native 栈探测变成可捕获 SyntaxError。

### `ParseFlags`（`src/parser.zig:514`）

packed u32，镜像 `PF_*`：`in_accepted`、`pow_allowed`、`result_needed`、`yield_forbidden`。

### `BlockEnv` / `LabelFrame` / `ControlFrames` / `ReturnFinallyFrame` / `UsingBlockFrame`

break/continue/finally/using 的解析期栈。`LabelFrame` 带 `LabelId`（不再写绝对 PC）。`UsingBlockFrame` 记 disposable stack 局部、catch 标签、是否见过 async hint。

### `DeclMask` / `FunctionKind` / `ParseFunctionKind` / `FeatureImpl`

`DeclMask` 控制语句位置能否出现函数/其它声明（`DECL_MASK_*`）。`ParseFunctionKind` 覆盖普通/生成器/async/箭头/方法/get/set/构造器/static block。

### `ParseState`（`parser_core.State`，`src/parser.zig:700`）

`JSParseState` 模拟。关键字段：

| 字段 | 含义 |
| --- | --- |
| `lex` / `token` | 词法器与一枚 lookahead |
| `function` / `function_def` | 可变 Bytecode 壳 + 真正的 FunctionDef |
| `runtime` | 可空；生产编译有，单测 parser 可无 |
| `pending_diagnostic` | 失败时钉死位置+短消息，OOM 不覆盖 |
| `scope_level` / `is_strict` / `is_eval` | 词法作用域与模式 |
| `eval_ret_idx` | `<ret>` 局部下标；-1 非 completion |
| `cur_func_stack` / `discarded_func_head` | 嵌套函数与投机回滚 |
| `emit_to_function_def` / `emit_phase1_temp` | 写 FunctionDef vs 根壳；发 temp opcode |
| `break_*` / `continue_*` / `label_frames` | 控制流 |
| `class_private_*` | 当前类的 `#` 元素 |
| `atom_scope` / `compile_value_roots_registered` | TGC 编译期根 |

### `compile_entry` 产物（`src/parser.zig:15761`）

- `Mode`：`script` / `module` / `eval_direct` / `eval_indirect`。
- `Options`：文件名、strict、eval 的 new.target/super/arguments、闭包种子。
- `Result`：`artifact`（FB 或 `ModuleArtifact`）+ `syntax_error` + `features` + `parse_path`。
- `EvalClosureSeed`：direct eval 从调用方环境带来的闭包行（含私有名）。

根文件 re-export：`compile`、`ParseState`、`Result`、`Options`、`Mode`。

## 函数


### `diagnostics.SyntaxError.create` (`src/parser.zig:20`)

- **签名**：`pub fn create(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom, position: Position, message: []const u8) !SyntaxError`。
- **作用**：分配并拷贝一条语法错误诊断。
- **实现**：
从 `MemoryAccount` 分配一份 `message` 拷贝（空串用零长切片，不分配）。`errdefer` 在拷贝失败时释放。`filename` 只保存 Atom，不在这里 retain。返回的 `SyntaxError` 由 `Result.deinit` 或调用方 `deinit` 释放。
- **所有权 / 错误 / 调用**：message 拷贝由 `MemoryAccount` 分配、`SyntaxError.deinit` 释放；`account` / `atoms` 只借用。唯一的 error 是 `OutOfMemory`。调用方是 `compile` 的 TS 护栏臂与 `setPendingSyntaxError` / `setInternalCompilerError` / `setFallbackSyntaxError`。

### `diagnostics.SyntaxError.deinit` (`src/parser.zig:33`)

- **签名**：`pub fn deinit(self: *SyntaxError) void`。
- **作用**：把一条语法错误诊断持有的 message 还给 `MemoryAccount`，并把这条诊断清成空壳。
- **实现**：
把 `filename` 置 `null_atom`、`message` 置空切片，再按原切片长度 `memory.free`。空 message 不 free。
- **所有权 / 错误 / 调用**：只归还 `create` 分配的 message；`memory` / `atoms` 是借用指针，不在这里释放。由 `Result.deinit` 调用。

### `diagnostics.advance` (`src/parser.zig:41`)

- **签名**：`pub fn advance(position: *Position, byte: u8) void`。
- **作用**：把源码位置或当前 token 往前推进一步。
- **实现**：
`offset += 1`。若 `byte == '\n'` 则 `line += 1` 且 `column = 1`，否则只加列。给词法位置与诊断共用。
- **所有权 / 错误 / 调用**：无：只把一个 `Position` 结构就地推进一个字节，不碰 `State`、不分配、无 error set。**树内零调用方**——`diagnostics.Position` 的实际推进由 lexer 自己维护（`lex.line`/`lex.col`/`lex.pos`），parser 侧取位置都走 `currentDiagnosticPosition`（`src/parser.zig:2070`）从 token 上读，所以这个逐字节推进器现在只是 `diagnostics` 命名空间里的公开 API。

### `token.isKeyword` (`src/parser.zig:176`)

- **签名**：`pub fn isKeyword(val: Kind) bool`。
- **作用**：判断 token 种类是否落在 QuickJS 关键字块。
- **实现**：
`TOK_NULL..TOK_AWAIT`（-85..-40）闭区间即为关键字。单字符标点走 ASCII 正值，不在此列。
- **所有权 / 错误 / 调用**：无：两个常量的区间比较，不分配、无 error set。调用方跨文件：`lexer.zig:616`（识别关键字后填 ident atom），parser 内 8 处（`keywordAtom` 自己的 `assert`（`src/parser.zig:185`）、`tokenKindLabel`（`:2106`）、`parseNewCalleeMemberAccess`（`:5820`）、`parseMemberChain`（`:5876`/`:5931`/`:5939`）、`parseObjectPropertyName`（`:6929`）、`tokenCanBeExportName`（`:15410`）），另有 `src/tests/parser.zig` 的全关键字对账。

### `token.keywordAtom` (`src/parser.zig:184`)

- **签名**：`pub fn keywordAtom(val: Kind) atom.Atom`。
- **作用**：把关键字 token 映射到预定义 atom。
- **实现**：
断言 `isKeyword`。返回 `ATOM_null + (val - TOK_NULL)`，与 `quickjs-atom.h:29..76` 行对齐；`keywordAtomAlignmentTest` 钉死这个不变量。
- **所有权 / 错误 / 调用**：返回的是**预定义 atom id**（`ids.null_ + (val - TOK_NULL)`，对应 quickjs-atom.h 的 1..47 号），不是新建的 atom：既不分配也不 retain，调用方不得 release，它们在 AtomTable 的整个生命周期内恒存，与 `CompileAtomScope` 无关。无 error set（非关键字只有 Debug `assert`）。调用方：`lexer.zig:617`，parser 内 11 处（`tokenKindLabel`（`src/parser.zig:2107`）、`parseNewCalleeMemberAccess`（`:5821`）、`parseMemberChain`（`:5877`/`:5940`）、`parsePrimary` 的松散 `let`（`:6387`）、`parseObjectPropertyName`（`:6924`/`:6930`）、`identifierLikeAtom`（`:7102`）、`parseVar`（`:10548`）、类元素名（`:14074`）、导出名（`:15419`））。

### `lreCheckStackOverflow` (`src/parser.zig:296`)

- **签名**：`fn lreCheckStackOverflow(opaque_ptr: ?*anyopaque, alloca_size: usize) bool`。
- **作用**：给 libregexp 编译器用的原生栈溢出回调。
- **实现**：
RegExp 编译回调。`opaque_ptr` 转 `*JSRuntime`，转调 `checkNativeStackOverflow(alloca_size)`。`null` 指针返回 false。对应 `quickjs.c:48000` `lre_check_stack_overflow`。
- **所有权 / 错误 / 调用**：无：把 `?*anyopaque` 还原成 `*JSRuntime` 再问一次原生栈余量，不分配、无 error set，`null` 上下文直接返回 false。它是**给 C 风格回调表用的函数指针**，parser 侧唯一的登记点是 `parseRegExpLiteral`（`src/parser.zig:6210`）的 `.check_stack_overflow`；同名函数在 `exec/regexp_ops.zig:523`、`exec/regexp_adapter.zig:31` 各有一份，别混。

### `DeclarationConflictIndex.deinit` (`src/parser.zig:363`)

- **签名**：`fn deinit(self: *DeclarationConflictIndex, allocator: std.mem.Allocator) void`。
- **作用**：释放冲突索引的 `scope_names` 哈希表，并把索引复位成可以重新 `build` 的空状态。
- **实现**：
两句：`scope_names.deinit(allocator)`，再把整个索引重置成默认值（`observed_vars_len = 0`、`dirty = false`），使同一块内存可以被重新 `build`。
- **所有权 / 错误 / 调用**：释放 `scope_names` 这张 `AutoHashMapUnmanaged` 的桶数组（allocator 由调用方传入，实际总是 `State.function.memory.allocator`）并把结构体清零；表里的 key 是 `(scope_level, atom)` 打包的 `u64`、value 是三个索引，没有任何指针或 atom 所有权。无 error set。三个调用方：`State.deinitDeclarationConflictIndices`（`src/parser.zig:1163`）、`State.discardDeclarationConflictIndex`（`:1174`），以及 `declarationConflictIndex` 里 `defer` 清理重建失败的临时表（`:1195`）。

### `DeclarationConflictIndex.scopeNameKey` (`src/parser.zig:368`)

- **签名**：`fn scopeNameKey(scope_level: i32, name: Atom) ?u64`。
- **作用**：把「作用域层级 + 名字 atom」打成冲突索引的哈希键。
- **实现**：
负的 `scope_level`（即没有归属作用域）返回 `null`；否则 `(@as(u64, scope_level) << 32) | name`，高 32 位是作用域、低 32 位是 atom id。
- **所有权 / 错误 / 调用**：无：把 `scope_level` 与 atom id 打包成 `u64` 的纯函数，负 scope 返回 `null`（调用方据此把索引标脏或报 `InvalidTopology`），不分配、无 error set，atom 只当整数用。8 处调用方：`recordLinkedNewestFirst`（`src/parser.zig:401`）、`recordFunctionVarOriginOldestFirst`（`:424`）、四个 prepare/commit（`:1237`/`:1273`/`:1305`/`:1351`），以及查询侧 `findIndexedLexicalDeclaration`（`:1619`）、`findFunctionVarInChildScope`（`:1684`）。

### `DeclarationConflictIndex.validateScopes` (`src/parser.zig:373`)

- **签名**：`fn validateScopes(fd: *const function_def_mod.FunctionDef) BuildError!void`。
- **作用**：校验作用域树的拓扑合法（父指针必须指向更早的作用域）。
- **实现**：遍历 `fd.scopes`：`parent < -1` 直接非法；`parent >= 0` 时父作用域的下标必须**小于**自己的下标（作用域按创建顺序追加，父一定更早出现）。任一条不满足就 `error.InvalidTopology`，`build` 据此把这张索引判废、调用方退回线性扫描。
- **所有权 / 错误 / 调用**：只读 `fd.scopes`，不分配。error set 是本结构体私有的 `BuildError`（`OutOfMemory` / `InvalidTopology`）而**不是** `parser_core.Error`：父 scope 编号越界或不严格小于自身时返回 `error.InvalidTopology`，最终在 `declarationConflictIndex`（`src/parser.zig:1196`）被吞成「返回 `null` 走慢速线性扫描」，永远不会变成 JS 异常。唯一调用方 `build`（`:438`）。

### `DeclarationConflictIndex.entry` (`src/parser.zig:382`)

- **签名**：`fn entry( self: *DeclarationConflictIndex, allocator: std.mem.Allocator, key: u64, ) BuildError!*DeclarationConflictEntry`。
- **作用**：按键取（必要时新建）一条冲突记录。
- **实现**：`scope_names.getOrPut(allocator, key)`，新插入的条目显式赋 `.{}`（三个下标字段都初始化成 `no_declaration_index`），返回 value 指针供调用方就地改写。唯一可能的 error 是 `OutOfMemory`。
- **所有权 / 错误 / 调用**：**会分配**：`scope_names.getOrPut` 可能触发哈希表扩容（用传入的 allocator），失败即 `BuildError.OutOfMemory`。返回的 `*DeclarationConflictEntry` 是**借用**指针，只在下一次插入前有效（扩容会搬桶），调用方都是当场写完即弃。新键插入时显式初始化为全 `no_declaration_index`。调用方 `recordLinkedNewestFirst`（`src/parser.zig:402`）与 `recordFunctionVarOriginOldestFirst`（`:425`）。

### `DeclarationConflictIndex.recordLinkedNewestFirst` (`src/parser.zig:392`)

- **签名**：`fn recordLinkedNewestFirst( self: *DeclarationConflictIndex, allocator: std.mem.Allocator, vd: function_def_mod.VarDef, var_index: usize, ) BuildError!void`。
- **作用**：把一条词法/catch 声明按「最新优先」记进索引。
- **实现**：只收词法声明与 catch 参数：`is_lexical` 或 `var_kind == .catch_` 之外的行直接返回。键取 `scopeNameKey(vd.scope_level, vd.var_name)`，算不出（负 scope_level）即 `error.InvalidTopology`。写入采取「首次写入即最终值」：`build` 沿 `scope.first` 链按最新优先的顺序喂进来，所以第一个落进 `newest_lexical`（仅词法行）和 `newest_lexical_or_catch` 的下标就是该作用域里最新的那条声明。
- **所有权 / 错误 / 调用**：经 `entry` 间接分配（哈希表扩容），失败是 `BuildError.OutOfMemory`；`scopeNameKey` 返回 `null` 时报 `BuildError.InvalidTopology`，两者都被 `declarationConflictIndex` 收成「不用索引」而非 JS 异常。只写索引，不改 `FunctionDef`；`vd` 是按值传入的 `VarDef` 拷贝。唯一调用方 `build`（`src/parser.zig:455`）。

### `DeclarationConflictIndex.recordFunctionVarOriginOldestFirst` (`src/parser.zig:411`)

- **签名**：`fn recordFunctionVarOriginOldestFirst( self: *DeclarationConflictIndex, allocator: std.mem.Allocator, fd: *const function_def_mod.FunctionDef, vd: function_def_mod.VarDef, var_index: usize, ) BuildError!void`。
- **作用**：把一条 parser 期的函数 var 按「最旧优先」记进它的原始作用域及所有祖先。
- **实现**：从 `vd.scope_next`（parser 期 scope-0 行把原始声明作用域藏在这个字段里）出发，沿 `fd.scopes[].parent` 一路走到根，每层都 `entry` 出条目，且只在 `oldest_child_function_var` 还是 `no_declaration_index` 时写入——调用方按 var 下标从小到大喂，先写的即最旧，复刻旧线性扫描返回的下标。`visited` 计数配合下标范围检查做双重防环，越界即 `error.InvalidTopology`。覆盖整条祖先链是因为函数 var 与任一祖先作用域里的词法声明都可能冲突。
- **所有权 / 错误 / 调用**：同族：经 `entry` 间接分配，`BuildError.OutOfMemory` / `InvalidTopology`（scope 链越界或走够 `fd.scopes.len` 步仍未到根 —— 环检测）。沿 `scope_next` 起点向上写每一层祖先 scope 的 `oldest_child_function_var`，只读 `fd`、只写索引。唯一调用方 `build`（`src/parser.zig:465`）。

### `DeclarationConflictIndex.build` (`src/parser.zig:433`)

- **签名**：`fn build( self: *DeclarationConflictIndex, allocator: std.mem.Allocator, fd: *const function_def_mod.FunctionDef, ) BuildError!void`。
- **作用**：从一个 `FunctionDef` 的完整 scopes/vars 拓扑重建整张冲突索引。
- **实现**：先 `validateScopes`，再按 `fd.vars.len` 一次性 `ensureTotalCapacity`。第一遍逐作用域走 `scope.first` 链：链是最新优先，遇到第一条 `scope_level` 不等于当前作用域下标的行就 `break`（那已经是外层继承来的头），其余交 `recordLinkedNewestFirst`。第二遍扫全部 vars，只挑 `scope_level == 0` 的 parser 期函数 var（它们有意不挂在任何 `scope.first` 上），按下标升序交 `recordFunctionVarOriginOldestFirst`。收尾把 `observed_vars_len` 记成 `fd.vars.len` 并清 `dirty`。两遍都有 `visited` 上限，链表成环时报 `InvalidTopology` 而不是死循环。
- **所有权 / 错误 / 调用**：整张索引的构造：`ensureTotalCapacity(fd.vars.len)` 先预留，再两趟写入。分配都在传入的 allocator 上、归 `self.scope_names`，失败时**不回滚**——调用方 `declarationConflictIndex`（`src/parser.zig:1191`-`:1198`）用 `candidate` + `defer candidate.deinit` 保证半成品被整表丢弃。error set 是 `BuildError`：`OutOfMemory` 上抛成 `Error.OutOfMemory`，`InvalidTopology` 被就地吞成 `null`（退回线性扫描），所以拓扑异常不会成为用户可见的编译错误。唯一调用方 `declarationConflictIndex`（`:1196`）。

### `DeclarationConflictIndex.readyFor` (`src/parser.zig:472`)

- **签名**：`fn readyFor(self: *const DeclarationConflictIndex, fd: *const function_def_mod.FunctionDef) bool`。
- **作用**：冲突索引是否与当前 vars 长度一致且未脏。
- **实现**：
一行 `return !self.dirty and self.observed_vars_len == fd.vars.len;`——`build` 成功时记下 `fd.vars.len` 并清 `dirty`，任何跟不上的增量写都会把 `dirty` 置真。
- **所有权 / 错误 / 调用**：无：两个标量比较（未脏 + 观察到的 `vars.len` 与当前一致），不分配、无 error set。这是「索引还能不能信」的唯一判据。两个调用方：`State.declarationConflictIndex`（`src/parser.zig:1187`）与 `State.readyDeclarationConflictIndexForWrite`（`:1218`）。

### `PendingDiagnostic.message` (`src/parser.zig:508`)

- **签名**：`fn message(self: *const PendingDiagnostic) []const u8`。
- **作用**：返回 pending 诊断里已截断的消息切片。
- **实现**：
一行 `return self.message_buffer[0..self.message_len];`。`message_buffer` 是内联的 `[96]u8`（`message_capacity`），所以整条 pending 诊断不需要分配。
- **所有权 / 错误 / 调用**：返回**借用** slice，指向 `PendingDiagnostic` 自己的 96 字节内联缓冲（`message_buffer`），随该结构体走，不分配也不需要释放；但调用方必须在结构体还活着时用完——`compile` 的做法是立刻把它 `SyntaxError.create` 复制进堆（`src/parser.zig:16347`），那份副本才归 `Result.syntax_error` 所有。无 error set。生产调用方只有 `setPendingSyntaxError`（`:16347`），其余是本文件的单测。

### `forceResultNeeded` (`src/parser.zig:524`)

- **签名**：`fn forceResultNeeded(flags: ParseFlags) ParseFlags`。
- **作用**：复制 ParseFlags 并把 `result_needed` 强制为 true。
- **实现**：
三行：按值拷贝一份 `flags`，把 `result_needed` 置真后返回；其余位（`in_accepted` / `pow_allowed` / `yield_forbidden`）原样透传。
- **所有权 / 错误 / 调用**：无：`ParseFlags` 按值进按值出，只置一位，不碰 `State`、不分配、无 error set。5 处调用方，都是「子表达式的值必须留在栈上」的语法点：`parseCondExpr` 的 then/else 两臂（`src/parser.zig:4667`/`:4669`）、`parseCoalesceExpr` 的 `??` 右操作数（`:4693`）、`parseLogicalAndOr` 的 `||` 与 `&&` 右操作数（`:4721`/`:4741`）。

### `LabelFrame.deinit` (`src/parser.zig:556`)

- **签名**：`fn deinit(self: *LabelFrame, allocator: std.mem.Allocator) void`。
- **作用**：回收一层标签帧上登记的 break/continue 待回填列表。
- **实现**：
释放 `LabelFrame` 的 `break_fixups` / `continue_fixups` 两个 ArrayList。标签 atom 不在这里 free。
- **所有权 / 错误 / 调用**：释放这一帧自己的两个 `std.ArrayList(usize)` fixup 缓冲（`break_fixups` / `continue_fixups`，allocator 总是 `State.function.memory.allocator`）；帧里的 `atom` 与两个 `LabelId` 都是裸值，无释放义务。无 error set。调用方：`State.deinit` 遍历 `label_frames`（`src/parser.zig:1055`）与 `popLabelFrame`（`:2310`）。

### `ParseState.initRootEmitter` (`src/parser.zig:922`)

- **签名**：`fn initRootEmitter( lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode, emit_root_to_function_def: bool, ) Error!State`。
- **作用**：构造根 ParseState：scope 0、Builder、第一个 token、函数体 identity。
- **实现**：
填 `function_def`（`js_new_function_def`：scope 0 parent=-1）、`CompileAtomScope`、`ensureBuilderForFd`。`lex.nextInto` 读第一个 token。`beginFunctionBodyIdentityOnly` 建立程序体作用域 identity，但不发 `enter_scope`（等 `beginProgramEmission` 作为流的第一条）。独立 ParseState 默认 `has_this_binding`/`arguments_allowed`；生产 `compile_entry` 会覆盖。
- **所有权 / 错误 / 调用**：**构造者**：在返回值里就地建 `FunctionDef`（`FunctionDef.init`，缓冲挂 `function.memory`）与 `CompileAtomScope`，再 `appendScope(-1)`、`ensureBuilderForFd` 分配 root 的 `compiler.Builder`，最后 `lex.nextInto(&state.token)` 读进第一个 token（token 的 payload 归 `State`，由 `advance`/`State.deinit` 释放）。失败路径用 `errdefer state.function_def.deinitInitFailure()`；`appendScope`/`ensureBuilderForFd` 的错误被统一折成 `error.OutOfMemory`。注意**返回的是按值的 `State`**：`atom_scope` 与两个 root provider 都存 `&self`，所以调用方必须先让它落到最终地址，再调 `activateCompileRoots`。调用方：`ParseState.init`（`src/parser.zig:967`）与 `initCanonicalRootWithRuntime`（`:994`）。

### `ParseState.init` (`src/parser.zig:963`)

- **签名**：`pub fn init(lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode) Error!State`。
- **作用**：构造对象并填好默认字段。
- **实现**：
`initRootEmitter(lex, function, false)`：根字节码仍写到 `Bytecode` 壳，给低层单测用。
- **所有权 / 错误 / 调用**：薄包装：`initRootEmitter(..., false)`，即 root 发射到 `Bytecode` 而不是 `FunctionDef`；所有权/错误同上条，`runtime` 留空（表示「无 runtime 的解析器专用入口」，`TaggedTemplateObjectBuilder`、`discardFunctionDef` 等处按这个字段分叉）。调用方：`initWithRuntime`（`src/parser.zig:980`）与 `src/tests/parser.zig` / `compiler/tests.zig` 的低层解析测试。

### `ParseState.initWithRuntime` (`src/parser.zig:972`)

- **签名**：`pub fn initWithRuntime( rt: *core.JSRuntime, lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode, ) Error!State`。
- **作用**：在 `init` 之上挂上 JSRuntime，以便发射运行时常量。
- **实现**：
`init` 之后把 `runtime` 设上。有 runtime 才能把 RegExp / 标签模板 / tagged-int 字符串收成真正的 JSValue 常量。
- **所有权 / 错误 / 调用**：在 `init` 之上只补一个 `state.runtime = rt`（借用指针，不 retain、不接管 runtime 生命周期）。error set 同 `initRootEmitter`。本入口仍是 `emit_root_to_function_def = false` 的旧形，生产 `compile` 走的是 `initCanonicalRootWithRuntime`；它的消费者是需要 runtime 常量（RegExp / tagged template）的可执行字节码辅助与测试。

### `ParseState.initCanonicalRootWithRuntime` (`src/parser.zig:986`)

- **签名**：`pub fn initCanonicalRootWithRuntime( rt: *core.JSRuntime, lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode, ) Error!State`。
- **作用**：生产根：从第一条指令就 emit 进 FunctionDef。
- **实现**：
`initRootEmitter(..., emit_root_to_function_def=true)` 再挂 runtime。生产 `compileQjsProgram` 走这条：根函数与子函数同一套 finalize。
- **所有权 / 错误 / 调用**：生产入口：`initRootEmitter(..., true)` 让 root 从第一个 body-scope 事件起就发射进自己的 `FunctionDef`，再挂上借来的 `rt`。错误同 `initRootEmitter`（都折成 `OutOfMemory` 或 lexer 的首 token 错误）。唯一调用方 `compileQjsProgram`（`src/parser.zig:16199`），紧接着就是 `defer state.deinit(rt)` 与 `try state.activateCompileRoots()`。

### `ParseState.deinit` (`src/parser.zig:1000`)

- **签名**：`pub fn deinit(self: *State, rt: anytype) void`。
- **作用**：按固定顺序拆掉一次解析持有的全部 Zig 堆资源：GC 根、冲突索引、函数定义栈、控制流列表，最后才是 atom 区间。
- **实现**：
顺序：先 `deactivateCompileValueRoots`（否则拆 FunctionDef 时 tracer 仍走它们），再冲突索引、namespace/last-declared atom、`source_line_starts`、当前 token。销毁 `cur_func_stack` 上每个 FunctionDef，再沿 `discarded_func_head` 清投机回滚留下的 def。然后 break/continue/label/using/private 列表。最后 `function_def.deinit`，**最后** `atom_scope.deinit`（拆的过程还要把 atom 还表）。
- **所有权 / 错误 / 调用**：整个 `State` 的析构，顺序本身是契约：**先** `deactivateCompileValueRoots()`（下面每一步都可能释放 provider 正在遍历的 `FunctionDef`），**最后** `atom_scope.deinit()`（中间的拆解仍会把 atom id 交还给表）。中段依次释放：声明冲突索引表、`source_line_starts`、当前 token 的 payload（`lex.freeToken`）、`cur_func_stack` 上每个 `FunctionDef`（`fd.deinit(rt)` + `memory.destroy`）与栈缓冲、`discarded_func_head` 链上的同样处理、十余个 `ArrayList`（break/continue/label/finally/using 帧）、类私有元素与私有名表，最后是 root `function_def.deinit(rt)`。`rt` 只是转给 `FunctionDef.deinit` 用来释放 cpool 里的 GC 值，本函数不拥有它；已经被 `takeFunctionBytecodeValue` 之类移走的产物不在此列。无 error set。调用方：`compileQjsProgram` 的 `defer`（`src/parser.zig:16200`）与各测试。

### `ParseState.traceCompileValueRoots` (`src/parser.zig:1092`)

- **签名**：`fn traceCompileValueRoots(self: *State, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：把本次编译还没发布的 GC 值（RegExp 字符串、标签模板数组、子函数 FB）作为精确根交给 tracer。
- **实现**：
依次 `function.traceCompileRoots`、`function_def.traceCompileRoots`，再遍历 `cur_func_stack` 上正在解析的每个 def，最后沿 `discard_next` 走完 `discarded_func_head` 链。三处存储对应 def 的三种状态：已挂进父 `child_list` 的、正在解析的、被投机回滚丢弃的。
- **所有权 / 错误 / 调用**：**GC 根扫描回调**，不分配、不改状态：把 root `Bytecode`、root `FunctionDef`、`cur_func_stack` 上每个在解析中的 def、以及 `discarded_func_head` 链上每个被投机回滚丢弃的 def 各 `traceCompileRoots(visitor)` 一遍——三种存储恰好覆盖一个 def 可能所处的三种状态。error set 是 `core.runtime.RootTraceError`（visitor 侧的错误），不是 `parser_core.Error`，也不会变成 JS 异常。不直接被调用：经 `traceCompileValueRootsThunk`（`src/parser.zig:1105`）以函数指针形式挂在 `compileValueRootProvider` 上，由 GC 在标记阶段回调。

### `ParseState.traceCompileValueRootsThunk` (`src/parser.zig:1102`)

- **签名**：`fn traceCompileValueRootsThunk(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：`RootProvider` 的 C 风格 trace 回调：把 `*anyopaque` 还原成 `*State` 再转调。
- **实现**：把 `context` `@ptrCast`/`@alignCast` 还原成 `*State` 后转调 `traceCompileValueRoots`。`RootProvider` 只存 `*anyopaque` + 函数指针，这层薄壳是唯一的类型还原点。
- **所有权 / 错误 / 调用**：C 风格 thunk：把 `*anyopaque` 还原成 `*State` 再转发，不分配，error set 同为 `RootTraceError`。注意它把 `context` 指针**当作稳定地址使用**——这就是 `activateCompileRoots` 必须在 `State` 落定后才调用的原因。唯一「调用方」是 `compileValueRootProvider`（`src/parser.zig:1111`）把它写进 `RootProvider.trace`，实际调用者是 GC 的根遍历。

### `ParseState.compileValueRootProvider` (`src/parser.zig:1107`)

- **签名**：`fn compileValueRootProvider(self: *State) core.runtime.RootProvider`。
- **作用**：把 `State` 包成一个 `RootProvider`（context = `self`，trace = thunk）。
- **实现**：
一行构造 `.{ .context = @ptrCast(self), .trace = traceCompileValueRootsThunk }`。注册与注销必须传结构相同的值，所以 `activateCompileRoots` / `deactivateCompileValueRoots` 都重新调它取。
- **所有权 / 错误 / 调用**：不分配：返回一个按值的 `RootProvider{ .context = &self, .trace = thunk }`。**注册与注销必须传结构相同的值**——`deactivateCompileValueRoots`（`src/parser.zig:1131`）就是靠再造一份同样的 provider 来做 `unregisterRootProvider` 的匹配键。无 error set。调用方：`activateCompileRoots`（`:1122`）与 `deactivateCompileValueRoots`（`:1131`）。

### `ParseState.activateCompileRoots` (`src/parser.zig:1115`)

- **签名**：`pub fn activateCompileRoots(self: *State) Error!void`。
- **作用**：把本次 parse 的 atom 区间根与 value 根提供者注册上去（`State` 落到最终地址之后、第一步解析之前恰好调一次）。
- **实现**：先 `atom_scope.activate()`（失败折成 `OutOfMemory`）；只有带 runtime 且 `value_root_frames_enabled` 为真时才 `registerRootProvider` 并置 `compile_value_roots_registered`。
- **所有权 / 错误 / 调用**：把本次解析的两个根注册进去：`atom_scope.activate()`（原子根，`AtomTable.compile_scope`，之后整场编译 intern 出的 id 都由它作根）与 `rt.registerRootProvider(compileValueRootProvider())`（值根，仅在 `value_root_frames_enabled` 且有 runtime 时），并置 `compile_value_roots_registered` 供 `deinit` 幂等注销。注册失败一律折成 `error.OutOfMemory`。**必须恰好调用一次、且在 `State` 到达最终地址之后**（两个 provider 都存 `&self`）。唯一调用方 `compileQjsProgram`（`src/parser.zig:16203`）；无 runtime 的测试路径只拿到 atom 根。

### `ParseState.deactivateCompileValueRoots` (`src/parser.zig:1125`)

- **签名**：`fn deactivateCompileValueRoots(self: *State) void`。
- **作用**：注销本 parse 的 value 根提供者（`State.deinit` 的第一步）。
- **实现**：`compile_value_roots_registered` 为假（没注册过或已注销）直接返回；否则先清标志再 `runtime.?.unregisterRootProvider(compileValueRootProvider())`。注销按值匹配，所以这里重新构造一份字段相同的 provider；标志先清保证重复调用幂等，也保证 `deinit` 拆 FunctionDef 时 tracer 已经不再走它们。
- **所有权 / 错误 / 调用**：只注销值根（atom 根另由 `atom_scope.deinit()` 在 `deinit` 末尾关闭）：靠 `compile_value_roots_registered` 做幂等，未注册直接返回，否则重建同一个 provider 值交给 `unregisterRootProvider`。不分配、无 error set。这里的 `self.runtime.?` 是安全的——该标志只在 `activateCompileRoots` 拿到 runtime 时才置位。唯一调用方 `State.deinit`（`src/parser.zig:1007`），且必须排在一切 `FunctionDef` 释放之前。

### `ParseState.setCurrentNamespaceAtom` (`src/parser.zig:1131`)

- **签名**：`fn setCurrentNamespaceAtom(self: *State, atom_id: ?Atom) void`。
- **作用**：记录 TypeScript `namespace` 擦除时当前所处的命名空间名字（`null` = 不在任何 namespace 内）。
- **实现**：把可空 atom 直接覆盖进 `current_namespace_atom`，不 retain 也不 release（atom 统一由 `atom_scope` 记账），本身也不维护栈：`parseNamespaceDeclarationWithIdent` 进入嵌套 namespace 前自己存下旧值，用 `defer` 调本函数恢复。
- **所有权 / 错误 / 调用**：只覆盖 `current_namespace_atom` 这个 `?Atom` 字段，**不 retain 旧值也不 release 新值**：TGC S3-c 之后编译期 atom 是普通借用 id，由 `CompileAtomScope` 统一作根，函数体里原先那层 `if (atom_id) |atom| atom else null` 的拆包是旧引用计数协议留下的空壳，已折成直接赋值。不分配、无 error set。调用方是 TypeScript `namespace` 擦除路径（`parseNamespaceDeclarationWithIdent`）的进出点。

### `ParseState.setLastDeclaredAtom` (`src/parser.zig:1135`)

- **签名**：`fn setLastDeclaredAtom(self: *State, atom_id: Atom) void`。
- **作用**：记下刚声明完的那个名字 atom；TS 命名空间嵌套用它把内层绑定挂到外层命名空间对象上。
- **实现**：
一行：直接把 `last_declared_atom` 覆盖成传入的 atom，不 retain 旧值也不 release 旧值（atom 由 `atom_scope` 统一记账；rc 时代那句 `const replacement = atom_id;` 中转已删）。
- **所有权 / 错误 / 调用**：同上：单字段赋值，只存 id，不 retain/release（`State.deinit` 里对应的清理也只是置 `null`）。不分配、无 error set。给「匿名函数取名自最近一次声明」这类回填用。

### `ParseState.curFunc` (`src/parser.zig:1142`)

- **签名**：`fn curFunc(self: *State) *function_def_mod.FunctionDef`。
- **作用**：取当前正在解析的 `FunctionDef`。
- **实现**：对照 QuickJS 的 `JSParseState.curFunc`：栈空（顶层程序体）时返回根 `&self.function_def`，否则返回 `cur_func_stack` 的栈顶。
- **所有权 / 错误 / 调用**：返回**借用**指针：栈空时是 `&self.function_def`（内联在 `State` 里，随 `State` 走），否则是 `cur_func_stack` 栈顶那个堆上 `FunctionDef`。调用方不得跨越 `pushFunction`/`popFunction`/`discardCurrentFunction` 持有它。不分配、无 error set；这是全 parser 最热的访问器之一，几百处调用。

### `ParseState.funcAtVirtualIndex` (`src/parser.zig:1149`)

- **签名**：`fn funcAtVirtualIndex(self: *State, idx: usize) *function_def_mod.FunctionDef`。
- **作用**：按「根 = 0、嵌套函数依次 1..n」的虚拟下标取 `FunctionDef`。
- **实现**：下标 0 指根 `function_def`，其余落到 `cur_func_stack[idx - 1]`，让调用方可以把根和栈当成一条连续的函数链遍历。
- **所有权 / 错误 / 调用**：同样返回借用指针，按「虚拟下标」把 0 映射到 root `function_def`、`idx` 映射到 `cur_func_stack[idx-1]`，让闭包穿线可以用统一下标从外到内走整条函数链。越界只有 slice 的边界检查（Debug panic），无 error set、不分配。

### `ParseState.deinitDeclarationConflictIndices` (`src/parser.zig:1154`)

- **签名**：`fn deinitDeclarationConflictIndices(self: *State) void`。
- **作用**：销毁注册表里所有 FunctionDef 的冲突索引。
- **实现**：迭代注册表 `declaration_conflict_indices`，对每个 value 调 `DeclarationConflictIndex.deinit` 释放它的 `scope_names`，然后 deinit 注册表本身并置 `.empty`。键是 `*FunctionDef`，只是借用，不在这里销毁；`State.deinit` 把它排在拆 FunctionDef 之前，避免注册表留下悬空键。
- **所有权 / 错误 / 调用**：遍历 `declaration_conflict_indices` 这张 `AutoHashMapUnmanaged(*FunctionDef, DeclarationConflictIndex)`，先逐个 `value_ptr.deinit(allocator)` 释放每张索引的桶数组，再释放外层表自身并置 `.empty`。key 是**借用**的 `*FunctionDef` 指针，不代表所有权（那些 def 由 `cur_func_stack` / `discarded_func_head` / 父 def 的 `child_list` 拥有）。无 error set。唯一调用方 `State.deinit`（`src/parser.zig:1008`）。

### `ParseState.discardDeclarationConflictIndex` (`src/parser.zig:1164`)

- **签名**：`fn discardDeclarationConflictIndex( self: *State, fd: *function_def_mod.FunctionDef, ) void`。
- **作用**：丢掉某个 `FunctionDef` 的冲突索引（该 def 被放弃或解析完时）。
- **实现**：注册表里有这一项才 `index.deinit(allocator)` 再 `remove(fd)`；没有就什么都不做。由 `discardFunctionDef` 在销毁 def 之前调用，防止注册表留下悬空键。
- **所有权 / 错误 / 调用**：单条目版本：命中就 `deinit` 那张索引再从表里 `remove`；表的桶数组本身不收缩。不碰 `fd` 本身（key 只是借用指针）。无 error set。唯一调用方 `discardFunctionDef`（`src/parser.zig:1414`）——必须在 `fd.deinit` 之前跑，否则表里会留下悬空 key。

### `ParseState.declarationConflictIndex` (`src/parser.zig:1177`)

- **签名**：`fn declarationConflictIndex( self: *State, fd: *function_def_mod.FunctionDef, ) Error!?*DeclarationConflictIndex`。
- **作用**：取一张完整可用的冲突索引，取不到则返回 null 让调用方走线性扫描。
- **实现**：注册表里已有且 `readyFor(fd)` 就直接返回；已有但跟不上就先标 `dirty`。`fd.vars.len` 低于 `declaration_conflict_index_threshold`（64）时返回 `null`，小函数走线性扫描更划算。否则在临时 `candidate` 上 `build`：`InvalidTopology` 折成 `null`（退回线性扫描），`OutOfMemory` 上抛。build 成功后若注册表已有旧项就与旧项交换（旧项交给 `defer` 释放），否则 `put` 进注册表并把所有权交出去（`candidate_owned = false`）。脏索引一律整体重建，从不就地修补。
- **所有权 / 错误 / 调用**：返回的是**借用**的 `*DeclarationConflictIndex`（归 `declaration_conflict_indices` 表所有，下一次 `put` 扩容后即失效），`null` 表示「用线性扫描」。分配有两处：`candidate.build` 的哈希表增长、以及把 candidate `put` 进注册表；`candidate_owned` + `defer` 保证任何失败路径上半成品都被整表释放，替换已有条目时也把**旧表**换进 candidate 由同一个 `defer` 回收。错误：`build` 的 `OutOfMemory` 上抛为 `Error.OutOfMemory`，`InvalidTopology` **就地吞成 `null`**（拓扑异常只降级不报错）；`vars.len` 低于 64（`declaration_conflict_index_threshold`）时直接返回 `null`。两个调用方：`findLexicalDeclaration`（`src/parser.zig:1646`）与 `findFunctionVarInChildScope`（`:1683`）。

### `ParseState.readyDeclarationConflictIndexForWrite` (`src/parser.zig:1208`)

- **签名**：`fn readyDeclarationConflictIndexForWrite( self: *State, fd: *function_def_mod.FunctionDef, ) ?*DeclarationConflictIndex`。
- **作用**：取一个可以做增量写的冲突索引，取不到就让调用方退回线性扫描。
- **实现**：注册表里没有该 def 直接 `null`；有但 `readyFor(fd)` 为假（脏或 vars 长度对不上）就把它标 `dirty` 再返回 `null`——脏索引不会被就地修补，只会在下次 `declarationConflictIndex` 里整体重建。
- **所有权 / 错误 / 调用**：不分配、无 error set：查表，未命中返回 `null`；命中但 `readyFor` 为假就**把它标脏**再返回 `null`（下一次查询会整表重建）。返回的指针同样是借用的表内槽位。两个调用方都是写前预留：`prepareLinkedDeclarationIndexWrite`（`src/parser.zig:1235`）与 `prepareFunctionVarOriginIndexWrite`（`:1296`）。

### `ParseState.prepareLinkedDeclarationIndexWrite` (`src/parser.zig:1223`)

- **签名**：`fn prepareLinkedDeclarationIndexWrite( self: *State, fd: *function_def_mod.FunctionDef, name: Atom, kind: function_def_mod.VarKind, is_lexical: bool, ) Error!bool`。
- **作用**：在权威的 FunctionDef 追加之前，先把这次词法/catch 声明会用到的那个键的容量预留好。
- **实现**：先 `readyDeclarationConflictIndexForWrite`，拿不到就返回 false（调用方照旧走线性路径）。非词法且非 catch 的声明根本不进索引，直接返回 true。否则算 `scopeNameKey(self.scope_level, name)`，算不出就标脏返回 false；键还不存在时按 `count() + 1` `ensureTotalCapacity`。预留必须发生在权威的 `FunctionDef` 追加**之前**——这样 commit 阶段只剩 `putAssumeCapacity`，不会中途失败而让索引与 vars 失步。
- **所有权 / 错误 / 调用**：**只分配不写入**：在权威的 `FunctionDef` 追加之前把这一个 `(scope, name)` 键的容量 `ensureTotalCapacity` 预留好，使随后的 `commitLinkedDeclarationIndexWrite` 变成不可失败的 `putAssumeCapacity`。分配用 `State.function.memory.allocator`，归索引的 `scope_names`。错误：容量计算溢出与 `ensureTotalCapacity` 都报 `Error.OutOfMemory`（这是真会变成宿主 OOM 的那一类，不是 SyntaxError）；`scopeNameKey` 失败则标脏并返回 `false`（降级，不是错误）。返回值 `false` 的含义是「本次不要 commit」。唯一调用方 `addScopeVar`（`src/parser.zig:1505`）。

### `ParseState.commitLinkedDeclarationIndexWrite` (`src/parser.zig:1250`)

- **签名**：`fn commitLinkedDeclarationIndexWrite( self: *State, fd: *function_def_mod.FunctionDef, var_index: i32, prepared: bool, ) void`。
- **作用**：追加成功后免分配地把词法/catch 声明发布进索引。
- **实现**：`prepared` 为假直接返回。再核三项一致性：索引未被标脏、`var_index` 正是刚追加的最后一行（`var_index + 1 == fd.vars.len`）、索引此前正好少记一行（`observed_vars_len + 1 == fd.vars.len`）；任一不满足就标脏放弃增量。通过后读回那条 `VarDef`，若是词法或 catch 行就用 prepare 预留的容量 `putAssumeCapacity` 补条目，`is_lexical` 时写 `newest_lexical`，并无条件覆盖 `newest_lexical_or_catch`（刚追加的一定最新）。收尾把 `observed_vars_len` 跟到 `fd.vars.len`。
- **所有权 / 错误 / 调用**：配对的发布半步：**不分配**（靠上一步的预留走 `putAssumeCapacity`）、无 error set。任何一致性怀疑——索引已脏、`var_index` 不是刚追加的那一行、`observed_vars_len` 对不上——都不是错误，而是把索引标脏后返回，让下次查询重建。`prepared == false` 时整条 no-op。唯一调用方 `addScopeVar`（`src/parser.zig:1518`），紧跟在权威追加之后。

### `ParseState.prepareFunctionVarOriginIndexWrite` (`src/parser.zig:1285`)

- **签名**：`fn prepareFunctionVarOriginIndexWrite( self: *State, fd: *function_def_mod.FunctionDef, name: Atom, origin_scope: i32, ) Error!bool`。
- **作用**：在追加函数 var 之前，把它原始作用域及全部祖先上缺的键一次性预留好。
- **实现**：取到可写索引后，从 `origin_scope` 沿 `parent` 链走到根，逐层算 `scopeNameKey` 并数出尚无条目的层数 `missing`；链越界或键算不出就标脏返回 false。`missing != 0` 时按 `count() + missing` 一次性 `ensureTotalCapacity`（加法溢出折成 `OutOfMemory`）。之所以要覆盖整条祖先链：一个 parser 期函数 var 与它原始作用域及每个祖先里的词法声明都可能冲突，索引必须在每层都能被查到。
- **所有权 / 错误 / 调用**：与上一对同形，但要覆盖**origin scope 及其全部祖先**：先数出缺失的键数，再一次性 `ensureTotalCapacity`。分配同样落在 `State.function.memory.allocator` 上、归索引所有。错误只有 `Error.OutOfMemory`（含容量加法溢出）；scope 链越界/成环或 `scopeNameKey` 失败一律标脏返回 `false` 走降级。唯一调用方 `appendFunctionVarAtOrigin`（`src/parser.zig:1707`）。

### `ParseState.commitFunctionVarOriginIndexWrite` (`src/parser.zig:1321`)

- **签名**：`fn commitFunctionVarOriginIndexWrite( self: *State, fd: *function_def_mod.FunctionDef, var_index: i32, origin_scope: i32, prepared: bool, ) void`。
- **作用**：追加成功后免分配地把函数 var 发布到原始作用域及全部祖先的记录上。
- **实现**：与 `commitLinkedDeclarationIndexWrite` 相同的三项一致性检查（未脏、`var_index` 是最后一行、`observed_vars_len` 正好差一）通过后，再沿 `origin_scope` 的祖先链走一遍，用 prepare 预留的容量 `putAssumeCapacity` 补齐缺的条目，且只在 `oldest_child_function_var` 仍是 `no_declaration_index` 时写入，保住「最旧优先」语义。任何一层下标越界或键算不出都标脏中止。收尾同步 `observed_vars_len`。
- **所有权 / 错误 / 调用**：不分配（`putAssumeCapacity`）、无 error set：沿祖先链把 `oldest_child_function_var` 填成刚追加的那一行（已有值则保留，语义是「最老的那个」）。与另一个 commit 一样，一切不一致都降级成标脏而非报错。唯一调用方 `appendFunctionVarAtOrigin`（`src/parser.zig:1716`）。

### `ParseState.pushFunction` (`src/parser.zig:1365`)

- **签名**：`fn pushFunction(self: *State, fd: *function_def_mod.FunctionDef) Error!void`。
- **作用**：进入嵌套函数时把它的 `FunctionDef` 压上解析栈，并保证它有自己的 `Builder`。
- **实现**：对照 `js_new_function_def`（`quickjs.c:31484-31490`）的父链建立。栈是手工管理的 `[]*FunctionDef` + 容量：不够时容量从 4 起翻倍（至少够 `new_len`），新块 `@memcpy` 旧内容后再释放旧块；写入栈顶后若该 def 还没有 `builder` 就 `ensureBuilderForFd`。
- **所有权 / 错误 / 调用**：**只接管指针不接管对象**：`fd` 由调用方创建（`memory.create(FunctionDef)`），压栈后其释放责任转到 `State`（正常出口 `popFunction` + 父 def 的 `addChild`，异常出口 `discardCurrentFunction` 或 `State.deinit` 扫 `cur_func_stack`）。自身的分配是栈数组的翻倍扩容（`function.memory.alloc` + `@memcpy` + 释放旧块，`errdefer` 覆盖新块），失败即 `Error.OutOfMemory`；随后 `ensureBuilderForFd(fd)` 给它补 Builder，错误统一折成 `OutOfMemory`。三个调用方：`parseFunctionParamsAndBody`（`src/parser.zig:11896`）、`parseArrowFunction`（`:12214`）、`enterFieldInitFunction`（`:14127`）。

### `ParseState.popFunction` (`src/parser.zig:1397`)

- **签名**：`fn popFunction(self: *State) *function_def_mod.FunctionDef`。
- **作用**：退出嵌套函数时把栈顶 `FunctionDef` 摘下来交还给调用方。
- **实现**：读出栈顶指针，再把 `cur_func_stack` 的长度减一；容量 `cur_func_stack_capacity` 不动，下一次 `pushFunction` 直接复用这块内存。弹出的 def 所有权随即转给调用方：`parseFunctionInternal` / class 方法路径把它挂进父 def 的子函数表，`discardCurrentFunction` 则转手 `discardFunctionDef` 销毁或挂上 `discarded_func_head`。栈空时下标计算会越界，所以调用方必须与 `pushFunction` 严格配对。
- **所有权 / 错误 / 调用**：不释放、不分配、无 error set：只把栈长度减一并把那个 `*FunctionDef` **交还给调用方**——从这一刻起它既不在 `cur_func_stack` 上、也还没进父 def 的 `child_list`，调用方必须立刻把它挂上去或交给 `discardFunctionDef`，否则就是泄漏（且 `traceCompileValueRoots` 也扫不到它）。空栈时靠 slice 边界检查 panic。

### `ParseState.discardCurrentFunction` (`src/parser.zig:1403`)

- **签名**：`fn discardCurrentFunction(self: *State) void`。
- **作用**：投机解析失败时把栈顶的 `FunctionDef` 连同它的产物一起丢弃。
- **实现**：
两行：`popFunction()` 取下栈顶，转交 `discardFunctionDef`。
- **所有权 / 错误 / 调用**：`popFunction` + `discardFunctionDef` 的组合，用于投机解析回滚。无 error set、自身不分配；实际的释放语义见下条（有 runtime 就立刻销毁，没有就挂延迟链）。

### `ParseState.discardFunctionDef` (`src/parser.zig:1408`)

- **签名**：`fn discardFunctionDef(self: *State, fd: *function_def_mod.FunctionDef) void`。
- **作用**：释放一个被放弃的 `FunctionDef`，或把它挂进延迟销毁链。
- **实现**：先 `discardDeclarationConflictIndex(fd)` 摘掉它的冲突索引。有 runtime 时立刻 `fd.deinit(rt)` + `memory.destroy` 并返回；没有 runtime（低层单测）时把 `fd` 串到 `discarded_func_head` 链头，留给 `State.deinit` 统一销毁——这条链同时也是 `traceCompileValueRoots` 的第三处根存储。
- **所有权 / 错误 / 调用**：释放路径分两条：**先**无条件 `discardDeclarationConflictIndex(fd)` 清掉以它为 key 的索引（否则表里留悬空 key）；然后有 `runtime` 时立刻 `fd.deinit(rt)` + `memory.destroy`，没有 runtime（解析器专用入口）时把它挂进 `discarded_func_head` 单链，延迟到 `State.deinit` 统一销毁——这条链同时也是 `traceCompileValueRoots` 的第三类根，保证被丢弃的 def 的 cpool 在编译结束前仍被 GC 看见。无 error set。调用方 `discardCurrentFunction`（`src/parser.zig:1409`）与各处投机回滚点。

### `ModuleArtifact.deinit` (`src/parser.zig:15292`)

- **签名**：`pub fn deinit(self: *ModuleArtifactImpl) void`。
- **作用**：释放模块产物里属于自己的那一半——链接元数据 `module.Record`。
- **实现**：
`ModuleArtifact.deinit` 只 `record.deinit()`。FunctionBytecode 不在这里释放——它是独立的 canonical root，由拿走它的调用方或 Result 的 function_bytecode 臂管理。
- **所有权 / 错误 / 调用**：**只释放两半里的一半**：`record.deinit()` 收掉模块链接元数据，`function_bytecode` 那个 `*FunctionBytecode` **不在这里释放**——它是 GC 堆上的对象，所有权在 `installParsedModuleArtifact`（`src/exec/module.zig`）里转给模块记录，未被消费时由 GC 回收。无 error set。唯一调用方 `Result.deinit`（`src/parser.zig:15827`）的 `.module` 臂；`takeModuleArtifact` 把整个结构体移走之后，`Result.artifact` 已置 `.none`，这条路径就不会重复跑。

### `Result.deinit` (`src/parser.zig:15314`)

- **签名**：`pub fn deinit(self: *ResultImpl) void`。
- **作用**：清掉一次编译结果里仍由 Result 拥有的两样东西：语法错误诊断与模块记录。
- **实现**：
`Result.deinit`：释放 `syntax_error`；若 artifact 是 module 则 `ModuleArtifact.deinit`（记录侧）。function_bytecode 臂不在这里 free（所有权在调用方 / GC）。最后把 artifact 置 `.none`。
- **所有权 / 错误 / 调用**：释放 `Result` 自己拥有的两样东西：`syntax_error`（`diagnostics.SyntaxError.deinit` 释放那段堆上的消息字节，`SyntaxError.create` 在 `rt.memory` 上分配）与 `.module` 臂的 `ModuleArtifact`（即 `record`）；`.function_bytecode` 臂**什么都不做**——FB 归 GC。收尾把 `artifact` 置 `.none`，所以与 `takeFunctionBytecodeValue`/`takeModuleArtifact` 的移走语义天然不冲突（谁先谁后都只释放一次）。无 error set。生产调用方全是 `defer`，共 8 处：`exec/eval_entry.zig:117`、`exec/eval_ops.zig:435`、`exec/function_ops.zig:494`、`exec/module.zig:117`/`:1020`、`exec/module_graph.zig:2203`、`exec/call.zig:2490`、`exec/call_runtime.zig:3365`。

### `Result.functionBytecode` (`src/parser.zig:15326`)

- **签名**：`pub fn functionBytecode(self: *const ResultImpl) ?*const bytecode.FunctionBytecode`。
- **作用**：借用式读取根 `FunctionBytecode`（不转移所有权）。
- **实现**：
对 `artifact` 三臂取值：`function_bytecode` 直接返回；`module` 返回 `artifact.function_bytecode`（模块与普通根共用同一个 canonical FB）；`none` 返回 `null`。下面一串 `byteCode` / `constants` / `closureVars` / `varDefs` / `openVarRefCount` / `filenameAtom` / `scriptOrModuleAtom` / `entryContract` / `isStrict` / `isDirectOrIndirectEval` 都建立在它之上。
- **所有权 / 错误 / 调用**：返回**借用**的 `*const FunctionBytecode`（两种 artifact 臂都指向同一个规范根），`Result` 仍然持有它：调用方不得释放，也不得在 `deinit`/`take*` 之后继续用。不分配、无 error set。生产调用方五处，都是先借看再 `take` 走：`exec/eval_entry.zig:168`、`exec/eval_ops.zig:443`、`exec/function_ops.zig:502`、`exec/call.zig:2499`、`exec/call_runtime.zig:3374`。

### `Result.takeFunctionBytecodeValue` (`src/parser.zig:15340`)

- **签名**：`pub fn takeFunctionBytecodeValue(self: *ResultImpl) ?JSValue`。
- **作用**：把普通根的 FunctionBytecode 以 `JSValue` 形式移交给调用方，Result 随即清空。
- **实现**：artifact 不是 `function_bytecode` 臂就返回 `null`（module 走 `takeModuleArtifact`）。取出 FB 指针后**先**把 `artifact` 置 `.none` 再包成 `JSValue.functionBytecode(&fb.header)` 返回，于是随后的 `Result.deinit` 不可能再释放第二次；借用式查看仍走 `functionBytecode`。
- **所有权 / 错误 / 调用**：**所有权转移**：只在 `.function_bytecode` 臂上成立，把 artifact 置 `.none` 后返回一个 `JSValue.functionBytecode(&fb.header)`，从此这个引用归调用方（交给 root `js_closure2` 或自行管理），`Result.deinit` 不会再碰它。不分配、无 error set；`.module`/`.none` 臂返回 `null`。生产调用方 5 处：`exec/eval_entry.zig:181`、`exec/eval_ops.zig:456`、`exec/function_ops.zig:503`、`exec/call.zig:2500`、`exec/call_runtime.zig:3375`。

### `Result.byteCode` (`src/parser.zig:15349`)

- **签名**：`pub fn byteCode(self: *const ResultImpl) []const u8`。
- **作用**：借用根 FB 的 code 字节（无产物时返回空切片）。
- **实现**：`functionBytecode()` 取不到根 FB 就返回空切片，否则转调 `fb.byteCode()`，指向 FB 尾块里的 code 区，生命周期跟着 FB。
- **所有权 / 错误 / 调用**：返回**借用**的只读字节切片，背后是 `FunctionBytecode` 的内联存储，随该 FB 存活；没有 artifact 时返回空 slice 而不是报错。不分配、无 error set。**生产零调用方**：`Result` 上这一族只读访问器只在 `src/tests/parser.zig` 里被用来对账（同名方法 `FunctionBytecode.byteCode` 则到处都是，别混）。

### `Result.constants` (`src/parser.zig:15354`)

- **签名**：`pub fn constants(self: *const ResultImpl) []const JSValue`。
- **作用**：借用根 FB 的常量池切片（无产物时返回空切片）。
- **实现**：同样先 `functionBytecode()`，无产物返回空切片，否则 `fb.cpoolSlice()`——FB 尾块中的常量池，元素是已发布的 `JSValue`，调用方只读不 retain。
- **所有权 / 错误 / 调用**：返回**借用**的 `[]const JSValue`（FB 的 cpool 切片）：里面的值归 FB 所有，调用方既不 retain 也不 release，只能在 FB 存活期间读。不分配、无 error set，无 artifact 时返回空 slice。**生产零调用方**，只在 `src/tests/parser.zig` 里用于常量对账。

### `Result.closureVars` (`src/parser.zig:15359`)

- **签名**：`pub fn closureVars(self: *const ResultImpl) []const bytecode.function_bytecode.BytecodeClosureVar`。
- **作用**：借用根 FB 的闭包变量表（无产物时返回空切片）。
- **实现**：无产物返回空切片，否则 `fb.closureVar()`，即 finalize 后钉进 FB 尾块的闭包变量表（`resolve_variables` 的产物）。
- **所有权 / 错误 / 调用**：返回**借用**的 `[]const BytecodeClosureVar`（FB 内联存储），行里的 `var_name` 只是 atom id、无所有权义务。不分配、无 error set。**生产零调用方**，只被 `src/tests/parser.zig` 用于闭包穿线对账。

### `Result.varDefs` (`src/parser.zig:15364`)

- **签名**：`pub fn varDefs(self: *const ResultImpl) []const bytecode.function_bytecode.BytecodeVarDef`。
- **作用**：借用根 FB 的变量定义表（无产物时返回空切片）。
- **实现**：无产物返回空切片，否则 `fb.varDefs()`，即 FB 尾块里的局部变量表；解析期的 `FunctionDef.vars` 此时已经被 finalize 降成这张表。
- **所有权 / 错误 / 调用**：返回**借用**的 `[]const BytecodeVarDef`（FB 内联存储），同样只读、无所有权转移。不分配、无 error set。**生产零调用方**，只被 `src/tests/parser.zig` 使用。

### `Result.openVarRefCount` (`src/parser.zig:15369`)

- **签名**：`pub fn openVarRefCount(self: *const ResultImpl) u16`。
- **作用**：根 FB 的开放 VarRef 数（无产物时 0）。
- **实现**：无产物返回 0，否则转调 `fb.openVarRefCount()`，读 FB 头上记的闭包 open var_ref 数——`js_closure2` 据此决定要建几个 var_ref。
- **所有权 / 错误 / 调用**：无：转发 `FunctionBytecode.openVarRefCount()`，无 artifact 时返回 0；不分配、无 error set。**`Result` 这一层生产零调用方**（被广泛使用的是 FB 上的同名方法）。

### `Result.filenameAtom` (`src/parser.zig:15374`)

- **签名**：`pub fn filenameAtom(self: *const ResultImpl) atom.Atom`。
- **作用**：根 FB 的文件名 atom（无产物时 `null_atom`）。
- **实现**：无产物返回 `null_atom`，否则 `fb.filenameAtom()`。返回的是 FB 持有的 atom，借用读取，不 retain。
- **所有权 / 错误 / 调用**：返回的是 FB 里存着的 atom id（**借用**：归 FB 所有，随 FB 的 tracer 边保活），调用方不得 release；没有 artifact 时返回 `null_atom`。不分配、无 error set。**`Result` 这一层生产零调用方**，只在 `src/tests/parser.zig:10261` 做名字对账。

### `Result.scriptOrModuleAtom` (`src/parser.zig:15379`)

- **签名**：`pub fn scriptOrModuleAtom(self: *const ResultImpl) atom.Atom`。
- **作用**：根 FB 的 ScriptOrModule 身份 atom（无产物时 `null_atom`）。
- **实现**：无产物返回 `null_atom`，否则 `fb.scriptOrModule()`——这是稳定的脚本/模块身份 atom，与只作显示用的 `filenameAtom` 分开（direct eval 的 filename 是 `"<eval>"`，身份则沿用调用方的）。
- **所有权 / 错误 / 调用**：同上：返回 FB 持有的 atom id，借用、不 release，无 artifact 时是 `null_atom`。不分配、无 error set。唯一调用点是 `src/tests/parser.zig:10262`，生产零调用方。

### `Result.entryContract` (`src/parser.zig:15384`)

- **签名**：`pub fn entryContract(self: *const ResultImpl) bytecode.EntryContract`。
- **作用**：把根 FB 的 `new.target` / `super()` / `super.x` / `arguments` 四个准入位打包成 `EntryContract`。
- **实现**：无产物时返回全默认（四位皆 false）的 `EntryContract`；否则从 FB 头读 `newTargetAllowed` / `superCallAllowed` / `superAllowed` / `argumentsAllowed` 四个位打包返回，供嵌入方在调用这段根字节码前核对准入条件。
- **所有权 / 错误 / 调用**：无：把 FB 的四个入口标志装成一个按值返回的 `EntryContract`，不分配、无 error set，无 artifact 时返回全默认。**生产零调用方**（只有 `src/tests/parser.zig` 两处）。

### `Result.isStrict` (`src/parser.zig:15394`)

- **签名**：`pub fn isStrict(self: *const ResultImpl) bool`。
- **作用**：根 FB 是否按严格模式编译（无产物时 false）。
- **实现**：转调 `fb.isStrictMode()`，读的是 finalize 时钉在 FB 头上的旗；它已经是指令 prologue（`"use strict"`）重算之后的权威严格性，不是 host 选项里的初值。
- **所有权 / 错误 / 调用**：无：转发 `FunctionBytecode.isStrictMode()`，无 artifact 时 `false`；不分配、无 error set。注意它读的是**最终产物**上的标志，也就是指令序言解析之后由 `compileQjsProgram`（`src/parser.zig:16279`，`function.flags.is_strict = parsed_strict`）回写的那个值，而不是 `options.strict`。生产零调用方（`src/tests/parser.zig` 两处）。

### `Result.isGlobalVar` (`src/parser.zig:15399`)

- **签名**：`pub fn isGlobalVar(self: *const ResultImpl) bool`。
- **作用**：谓词：这次编译的声明该落到全局对象还是局部槽。
- **实现**：
没有 artifact 时为假；script / module 恒真；两种 eval 取 `!isStrict()`（严格 eval 的 var 是自己的局部）。这与 `compileQjsProgram` 在 directive prologue 之后回写 `function_def.is_global_var` 的规则是同一条。
- **所有权 / 错误 / 调用**：无：唯一一个**不看 FB 而看 `self.mode`** 的判定（script/module 恒真，eval 看 `isStrict()`），`.none` artifact 恒假；不分配、无 error set。生产零调用方，只有 `src/tests/parser.zig:6166` 对账。

### `Result.isDirectOrIndirectEval` (`src/parser.zig:15409`)

- **签名**：`pub fn isDirectOrIndirectEval(self: *const ResultImpl) bool`。
- **作用**：根 FB 是不是 eval（direct 或 indirect）编译出来的。
- **实现**：无产物返回 false，否则 `fb.isDirectOrIndirectEval()`。该旗由 `initCompileCarrier` 按 `Mode` 落在可变载体上，再由 finalize 带进 FB；VM 用它区分 eval 根与普通函数的作用域规则。
- **所有权 / 错误 / 调用**：无：转发 FB 的同名标志，无 artifact 时 `false`；不分配、无 error set。`Result` 这一层生产零调用方（FB 上的同名方法另有用户）。

### `Result.isModule` (`src/parser.zig:15414`)

- **签名**：`pub fn isModule(self: *const ResultImpl) bool`。
- **作用**：本次编译是不是 module 模式。
- **实现**：只比 `self.mode == .module`，不看 artifact——因此语法错误导致没有产物时，一个 module 编译的 Result 仍然返回 true。
- **所有权 / 错误 / 调用**：无：只比较 `self.mode == .module`，连 artifact 都不看（所以语法错误的模块编译结果仍报 `true`），不分配、无 error set。`Result` 这一层生产零调用方。

### `Result.moduleArtifact` (`src/parser.zig:15418`)

- **签名**：`pub fn moduleArtifact(self: *const ResultImpl) ?*const ModuleArtifactImpl`。
- **作用**：借用式读取 module 臂的产物（非 module 返回 null）。
- **实现**：`artifact` 是 `.module` 臂时返回 `&self.artifact.module`，其它臂返回 `null`。返回的是指进 Result 内部的借用指针，随 `takeModuleArtifact` / `deinit` 失效。
- **所有权 / 错误 / 调用**：返回**借用**的 `*const ModuleArtifact`（指向 `Result` 内联的 union 载荷），`Result` 仍持有它：调用方只读、不得释放，且不能跨过 `takeModuleArtifact`/`deinit` 使用。不分配、无 error set。生产调用方一处：`exec/module_graph.zig:2215`（先借看再 `:2257` 取走）。

### `Result.moduleRecord` (`src/parser.zig:15425`)

- **签名**：`pub fn moduleRecord(self: *const ResultImpl) ?*const bytecode.module.Record`。
- **作用**：借用式读取模块链接用的 `module.Record`（非 module 返回 null）。
- **实现**：先 `moduleArtifact()`，没有就 `null`；有就返回 `&artifact.record`。同样是借用，模块链接器读完 import/export 表即弃，不得跨过 `Result.deinit`。
- **所有权 / 错误 / 调用**：在 `moduleArtifact` 之上再取一层 `&artifact.record`，同样是**借用**的只读指针，所有权仍在 `Result`。不分配、无 error set。**生产零调用方**，只被 `src/tests/parser.zig` 用于导入/导出表对账。

### `Result.takeModuleArtifact` (`src/parser.zig:15433`)

- **签名**：`pub fn takeModuleArtifact(self: *ResultImpl) ?ModuleArtifactImpl`。
- **作用**：把 FB 与模块记录两半一起移交给调用方，Result 随即清空。
- **实现**：非 `.module` 臂返回 `null`。把整个 `ModuleArtifactImpl`（canonical FB 指针 + `module.Record`）按值取出，**先**把 `artifact` 置 `.none` 再返回，于是 FB 与 record 这两个独立所有者各自只会被释放一次。
- **所有权 / 错误 / 调用**：**所有权转移**：把整个 `ModuleArtifact`（FB 指针 + `module.Record`）按值移出并将 `artifact` 置 `.none`，此后 `Result.deinit` 不会再释放 record，责任归调用方（生产上交给 `installParsedModuleArtifact` 装进模块记录）。不分配、无 error set；非 `.module` 臂返回 `null`。生产调用方三处：`exec/eval_entry.zig:135`、`exec/module.zig:1039`、`exec/module_graph.zig:2257`。

### `Result.hasFeature` (`src/parser.zig:15442`)

- **签名**：`pub fn hasFeature(self: ResultImpl, feature: FeatureImpl) bool`。
- **作用**：谓词：本次编译是否用到了某个 `Feature`。
- **实现**：
一行 `return self.features.contains(feature);`；`features` 是 `compileQjsProgram` 结束时从 `state.features` 整体拷过来的 `EnumSet`。
- **所有权 / 错误 / 调用**：无：`self` 按值传入（`EnumSet` 只是位集），查一位，不分配、无 error set。特征集在 `compileQjsProgram` 末尾从 `state.features` 整体拷贝过来（`src/parser.zig:16331`）。**生产零调用方**——21 处调用全在 `src/tests/parser.zig`。

### `compile_entry.isPrivateEvalClosureKind` (`src/parser.zig:15475`)

- **签名**：`fn isPrivateEvalClosureKind(kind: bytecode.function_def.VarKind) bool`。
- **作用**：判断一条 eval 闭包种子是不是类体里的 `#` 私有名（字段/方法/getter/setter/getter-setter 对）。
- **实现**：对 `VarKind` 做 switch：`private_field`、`private_method`、`private_getter`、`private_setter`、`private_getter_setter` 五种返回 true，其余 false。`restoreDirectEvalPrivateBoundNames` 用它从调用方传来的闭包种子里筛出需要在 direct eval 根上重建的私有名绑定。
- **所有权 / 错误 / 调用**：无：五条臂的纯查表 switch，不碰 `State`、不分配、无 error set。唯一调用方 `restoreDirectEvalPrivateBoundNames`（`src/parser.zig:16012`）。

### `compile_entry.isPrivateSetterCompanion` (`src/parser.zig:15487`)

- **签名**：`fn isPrivateSetterCompanion(atoms: *const atom.AtomTable, seed: EvalClosureSeedImpl) bool`。
- **作用**：谓词：这个闭包种子是不是 `#x` 存取器对里那个合成的 setter 伴生项（不该再当成一个独立私有名恢复）。
- **实现**：只认 `var_kind == .private_setter`，再查它的 atom 名字是否以 `"<set>"` 结尾；atom 查不到名字时返回 false。
- **所有权 / 错误 / 调用**：只读：`atoms.name(seed.var_name)` 返回的是 AtomTable 里的**借用**字节切片，只在本次比较中使用、不复制也不释放；atom 表指针是 `*const`，不分配、无 error set，名字查不到时返回 `false`。唯一调用方 `restoreDirectEvalPrivateBoundNames`（`src/parser.zig:16012`），用来跳过 `<set>` 伴生行以免同一个私有名被登记两次。

### `compile_entry.restoreDirectEvalPrivateBoundNames` (`src/parser.zig:15493`)

- **签名**：`fn restoreDirectEvalPrivateBoundNames( rt: *JSRuntime, state: *parser_impl.ParseState, seeds: []const EvalClosureSeedImpl, ) !void`。
- **作用**：direct eval 的根上恢复调用方类体里的 `#` 私有名绑定，让 eval 里的 `#x` 能解析。
- **实现**：**从尾向头**遍历 `seeds`：运行时闭包表是就近优先的，而 parser 查私有名时从 `class_private_bound_names` 的尾部往回找，反向一次就能复原同样的遮蔽顺序。重复名与 `<set>` 伴生项跳过；只要恢复了任何一个名字就把 `state.in_class` 置真。
- **所有权 / 错误 / 调用**：唯一的分配是 `state.class_private_bound_names.append(rt.memory.allocator, ...)`，缓冲归 `State`、由 `State.deinit` 释放；追加的 `seed.var_name` **只是 id 拷贝**（局部变量名叫 `retained` 是 TGC S3-c 之前的遗迹，现在没有 retain），私有名 atom 的存活由 `CompileAtomScope` 负责。副作用还有一条：恢复了任何名字就置 `state.in_class = true`。error set 是 `append` 的 `OutOfMemory`（签名写成 `!void` 推导得来）。倒序遍历是为了让 parser 的「从尾部找」与运行时闭包的「就近优先」得到同一个遮蔽顺序。唯一调用方 `compileQjsProgram`（`src/parser.zig:16247`）的 `mode == .eval_direct` 分支。

### `compile_entry.elapsedNanosSince` (`src/parser.zig:15526`)

- **签名**：`fn elapsedNanosSince(start: u64) u64`。
- **作用**：算一段编译阶段的耗时纳秒数。
- **实现**：
读 `platform_clock.monotonicNanos()`，只有 `end > start` 才返回差值，否则返回 0（时钟不前进时不产生负值/回绕）。`compileQjsProgram` 用它填 `compile_context.timing` 的 `frontend_ns` / `finalize_ns`。
- **所有权 / 错误 / 调用**：无：读一次单调时钟做减法，时间回退时返回 0（不报错）；不分配、无 error set。两个调用方都在 `compileQjsProgram`：前端耗时（`src/parser.zig:16305`）与 finalize 耗时（`:16329`），且只在 `compile_context.timing != null` 时才有意义。

### `compile_entry.initCompileCarrier` (`src/parser.zig:15531`)

- **签名**：`fn initCompileCarrier( rt: *JSRuntime, filename_atom: atom.Atom, options: OptionsImpl, effective_strict: bool, ) bytecode.Bytecode`。
- **作用**：按编译模式建那个可变的 `Bytecode` 壳（解析期的载体，不是最终产物）。
- **实现**：`Bytecode.init` 之后把 `script_or_module`（若选项给了）、`line_num`/`col_num = 1` 填上，再按 mode 落四个旗：`is_strict = module or effective_strict`、`is_global_var`（script/module 为真，两种 eval 取 `!effective_strict`）、`is_module`、`is_direct_or_indirect_eval`。注意这里的严格性只来自 host 选项，指令 prologue 之后 `compileQjsProgram` 还会重算并回写这两个旗。
- **所有权 / 错误 / 调用**：**返回一个按值的 `Bytecode` 载体**，其内部缓冲随后由 `Bytecode.init(&rt.memory, &rt.atoms, filename_atom)` 挂在 runtime 的 MemoryAccount 上——所有权归调用方，`compile` 用 `function_owned` + `errdefer function.deinit(rt)` 管，成功路径在取走 `module_record` 后也会 `function.deinit(rt)`。`filename_atom` 只是 id 拷贝（`compile` 那次 `rt.internAtom` 的结果由 `CompileAtomScope` 作根）。本函数自身**无 error set**（`Bytecode.init` 不分配，只填字段）。唯一调用方 `compile`（`src/parser.zig:16086`）。

### `compile_entry.compile` (`src/parser.zig:15553`)

- **签名**：`pub fn compile(compile_context: bytecode.CompileContext, source: []const u8, options: OptionsImpl) !ResultImpl`。
- **作用**：把源文编译成 FunctionBytecode / 模块产物。
- **实现**：
公共编译入口。步骤：
1. 用 runtime persistent allocator 建短命 arena，把 `rt.memory.allocator` 临时改过去（`defer` 改回）。
2. `CompileAtomScope.activate`：前端所有 intern 的 atom 进区间根，直到产物带上 tracer 边。
3. intern 文件名；`initCompileCarrier` 建可变 `Bytecode` 壳（strict/module/eval 旗）。
4. `shouldStrip` 的源（`.ts` 等）先 `findUnsupportedTypeScriptSyntax`，命中则 `syntax_error_guard` 返回，不进解析。
5. `compileQjsProgram`：成功得到 canonical `FunctionBytecode`。`OutOfMemory` 上抛；`StackOverflow` 与其它语法错误收成 `Result.syntax_error`；`ParserInvariant` 等走 ICE 文案。
6. module 把 `module_record` 挪进 `ModuleArtifact`；script/eval 只持有 FB。然后 `function.deinit` + `arena.deinit`（FB 已在 artifact allocator 上）。
- **所有权 / 错误 / 调用**：两个布尔守着两件必须恰好释放一次的东西：`arena_owned`（`errdefer arena.deinit()`）与 `function_owned`（`errdefer function.deinit(rt)`）——**每一条 `return` 之前都手工 `deinit` 并清标志**，所以正常返回与错误返回都不会重复释放。`rt.memory.allocator` 被临时改指 arena，用 `defer` 还原；`CompileAtomScope` 在第一次 intern 之前 `activate`、`defer deinit`，覆盖从文件名 atom 到发布 FB 的整条链。产物 FB 建在 `compile_context.artifactAllocator()` 上（由 `compileQjsProgram` 切换），所以 arena 释放不影响它；module 还会把 `function.module_record` **移**进 `ModuleArtifact`（移走后把源字段置 `null`）。错误分三类：`OutOfMemory` 原样上抛（唯一会让调用方看到 Zig error 的一类）、`StackOverflow` 与一般解析错误折成 `Result.syntax_error`、`isInternalCompilerError` 命中的走 ICE 文案；三条都仍然返回一个**成功的** `ResultImpl`。`pub` 出口，生产调用方在 `exec/eval_entry.zig`、`exec/eval_ops.zig`、`exec/function_ops.zig`、`exec/module*.zig`、`exec/call*.zig` 共 8 处。

### `compile_entry.compileQjsProgram` (`src/parser.zig:15674`)

- **签名**：`fn compileQjsProgram( rt: *JSRuntime, source: []const u8, options: OptionsImpl, compile_context: bytecode.CompileContext, function: *bytecode.Bytecode, features: *std.EnumSet(FeatureImpl), pending_diagnostic: *?parser_impl.PendingDiagnostic, ) !*bytecode.FunctionBytecode`。
- **作用**：词法+语法+发射+finalize，产出 canonical FunctionBytecode。
- **实现**：
真正的 parse→emit→finalize：
1. `Lexer.init`；module/strict 设词法旗；TS 源 `enableTypeScript()`。
2. `ParseState.initCanonicalRootWithRuntime`（根从第一天就 emit 进 FunctionDef）+ `activateCompileRoots`。
3. 按 mode 填 `function_def`：四模式根都是 eval bytecode；`is_global_var` 在 script/module 为真、松散 eval 为真。direct eval 恢复私有绑定、种 `eval_closure_seed`。module 设 `in_async`、`top_level_lexical_as_module_ref`、`ensureModule`。
4. `beginProgramEmission`（先发 body `enter_scope`）。eval 模式 `enableEvalReturn`，否则可选 `enableReturnCompletion`。
5. `parseDirectives` → 用指令 prologue **之后** 的严格性重算 `is_global_var` / eval 全局 var（对齐 `js_parse_program`）。
6. `parseProgramStatements`；module 再 `validateModuleLocalExports`。
7. 收尾：completion 模式 `finalizeEvalReturn`（`get_loc <ret>; return`）；否则 `isLiveCode` 则 `emitReturnUndefined`。
8. 把 allocator 切到 `artifactAllocator()`，`createFunctionBytecode` / `createModuleFunctionBytecode`（`resolve_variables` + `resolve_labels` + 打包 FB）。计时写入 `compile_context.timing`。
- **所有权 / 错误 / 调用**：三层 `defer` 决定了拆解顺序：`lex.deinit()`、`state.deinit(rt)`、以及**finalize 期间那次 allocator 切换的还原**——注释点明必须在 `State.deinit` 之前还原成解析用的 allocator，否则 parser 的临时缓冲会用错误的 allocator 回收。`errdefer pending_diagnostic.* = state.pending_diagnostic;` 是唯一的错误出参：`State` 马上要被 `defer` 拆掉，所以诊断要在那之前按值抄给 `compile`。返回的 `*FunctionBytecode` 指向 `createFunctionBytecode` 在 `compile_context.artifactAllocator()` 上发布的切片首元素，所有权交给调用方（`compile` 装进 `Result.artifact`）；module 形态的 `record` 仍留在 `function.module_record` 上，由 `compile` 移走。文件名不在参数里：它由 `initCompileCarrier` 提前写进 `function`（原先那个从未被读的 `filename_atom` 形参已删）。错误：`OutOfMemory` 与全部解析错误原样上抛给 `compile` 分类。唯一调用方 `compile`（`src/parser.zig:16119`）。

### `compile_entry.setPendingSyntaxError` (`src/parser.zig:15828`)

- **签名**：`fn setPendingSyntaxError( result: *ResultImpl, rt: *JSRuntime, filename_atom: atom.Atom, pending: *const parser_impl.PendingDiagnostic, ) !void`。
- **作用**：把解析期钉住的 `PendingDiagnostic`（位置 + 短消息）落成 `Result.syntax_error`。
- **实现**：
用 `pending.position` 与 `pending.message()` 调 `SyntaxError.create`（消息在这里才拷进 `MemoryAccount`），并把 `result.parse_path` 置 `.syntax_error_guard`。
- **所有权 / 错误 / 调用**：把 `PendingDiagnostic` 里那份**栈上/借用**的 96 字节消息复制进堆：`SyntaxError.create` 在 `rt.memory` 上 `alloc`，产物归 `result.syntax_error`，由 `Result.deinit` 释放；同时把 `parse_path` 标成 `.syntax_error_guard`。error set 只有 `create` 的 `OutOfMemory`（签名 `!void` 推导），而它**本身不是**错误上报路径——它是把解析错误落成 `Result` 的那一步，真正变 JS 异常发生在 `exec/eval_entry.zig:127` 的 `throwParseSyntaxError`。两个调用方都在 `compile` 的 catch 里：`src/parser.zig:16128`（StackOverflow 臂）与 `:16146`（通用臂）。

### `compile_entry.isInternalCompilerError` (`src/parser.zig:15844`)

- **签名**：`fn isInternalCompilerError(err: anyerror) bool`。
- **作用**：谓词：这个 error 是引擎自身的不变量破了（ICE），而不是源程序的语法错误。
- **实现**：
一个 switch 白名单：`InvalidBytecode`、`BytecodeOverflow`、`InvalidTopology`、`InvalidOpcode`、`StackUnderflow`、`StackMismatch`、`ClosureVarNotFound`、`Pc2LineTruncated`、`Pc2LineOverflow`、`ParserInvariant` 为真，其余为假。紧跟其后的 `comptime` 块用 `if (!isInternalCompilerError(error.ParserInvariant)) @compileError(...)` 钉死 `ParserInvariant` 永远走 ICE 臂。
- **所有权 / 错误 / 调用**：纯谓词（十条臂的 `anyerror` 查表），不分配、无 error set、无副作用。紧跟其后有一段 `comptime` 断言钉死 `error.ParserInvariant` 必须命中这条臂（`src/parser.zig:16369-16372`），防止有人把它挪回用户级 SyntaxError 通道。唯一调用方是 `compile` 的错误分类臂（`:16144` 之前的判定），为真则走 `setInternalCompilerError`。

### `compile_entry.setInternalCompilerError` (`src/parser.zig:15866`)

- **签名**：`fn setInternalCompilerError( result: *ResultImpl, rt: *JSRuntime, filename_atom: atom.Atom, err: anyerror, ) !void`。
- **作用**：把一个 ICE 折成用户可见的 `Result.syntax_error`。
- **实现**：
在 96 字节栈缓冲里 `bufPrint("internal compiler error: {s}", .{@errorName(err)})`（放不下就退回裸字符串 `"internal compiler error"`），位置填 `{0,0,0}`（ICE 没有可信源位置），再 `SyntaxError.create` 并把 `parse_path` 置 `.syntax_error_guard`。
- **所有权 / 错误 / 调用**：消息先在**栈上 96 字节缓冲**里用 `bufPrint` 拼成 `"internal compiler error: <errName>"`（放不下就退回常量串），再由 `SyntaxError.create` 复制到 `rt.memory` 上，归 `result.syntax_error`、由 `Result.deinit` 释放；位置固定为 `(0, 0, 0)`，因为 ICE 没有有意义的源位置。只可能失败于 `OutOfMemory`。唯一调用方 `compile`（`src/parser.zig:16144`），且只在 `isInternalCompilerError(err)` 为真时。

### `compile_entry.setFallbackSyntaxError` (`src/parser.zig:15888`)

- **签名**：`fn setFallbackSyntaxError( result: *ResultImpl, rt: *JSRuntime, filename_atom: atom.Atom, source: []const u8, message: []const u8, ) !void`。
- **作用**：解析失败却没有 pending 诊断时，重扫一遍源文给错误定个位置。
- **实现**：新开一个 `Lexer` 从头扫到 `TOK_EOF`，每取一个 token 就把 `pos` 更新成词法器当前的 `{line, col, pos}`，每个 token 用完立刻 `freeToken`。扫描途中词法器自己报错（非 `OutOfMemory`）时，改用 `lex.mark_*` 的位置 + `@errorName(err)` 作消息立即返回。正常走完则用最后记下的 `pos` 和调用方给的 `message`（例如 `"stack overflow"` 或 `@errorName`）建 `SyntaxError`。两条路径都把 `parse_path` 置 `.syntax_error_guard`。
- **所有权 / 错误 / 调用**：没有 pending 诊断时的兜底：**自己再开一个 `Lexer`** 把源码从头扫到 EOF，只为得到「最后一个成功 token 之后」的位置；扫描期间每个 token 都 `lex.freeToken` 释放 payload，`lex` 本身是栈上值（注意这里没有 `defer lex.deinit()`，Lexer 的状态不持堆资源）。产出同样是 `rt.memory` 上的 `SyntaxError`，归 `result.syntax_error`。error set：扫描中途的 `OutOfMemory` 直接上抛，其它词法错误**就地变成另一条 `SyntaxError`**（位置取 `lex.mark_*`，消息用 `@errorName`）并提前返回。两个调用方同样在 `compile` 的 catch 里（`src/parser.zig:16130`/`:16148`）。

### `compile_entry.nextFallbackSyntaxTokenInto` (`src/parser.zig:15926`)

- **签名**：`fn nextFallbackSyntaxTokenInto(lex: *lexer_mod.Lexer, out: *token_mod.Token, previous_token_kind: ?token_mod.TokenKind) lexer_mod.Error!void`。
- **作用**：fallback 重扫用的取词一步，负责把 `/` 决议成除法还是正则字面量。
- **实现**：`lex.nextInto(out)` 取一个 token（`errdefer` 负责失败时 `freeToken`）；若它是 `'/'` 或 `TOK_DIV_ASSIGN` 且 `fallbackSlashStartsRegexp(previous_token_kind)` 为真，就记下 `lex.mark_pos`、释放刚才那个 token，改用 `rescanRegexpInto` 从斜杠处重扫成正则。
- **所有权 / 错误 / 调用**：写进调用方给的 `out: *Token`；token 的 payload 所有权**归调用方**（`setFallbackSyntaxError` 每轮 `freeToken`），本函数只在自己的失败路径上用 `errdefer lex.freeToken(out)` 兜底，以及在改判正则时先 `freeToken` 旧 token 再 `rescanRegexpInto`。不分配长期对象。error set 是 **`lexer_mod.Error`**（不是 `parser_core.Error`），由调用方分流成 OOM 上抛或 `SyntaxError` 记录。唯一调用方 `setFallbackSyntaxError`（`src/parser.zig:16408`）。

### `compile_entry.fallbackSlashStartsRegexp` (`src/parser.zig:15939`)

- **签名**：`fn fallbackSlashStartsRegexp(previous_token_kind: ?token_mod.TokenKind) bool`。
- **作用**：按上一个 token 判断此处的 `/` 应当开启正则字面量还是当除号。
- **实现**：
`compile` 在解析失败且没有 pending 诊断时，重扫源文定位错误点。`/` 与 `/=` 在「上一 token 能引入正则」时 `rescanRegexpInto`。上一 token 为空、开括号、运算符、`return`/`case`/`throw`/`new` 等返回 true；ident/字面量后的 `/` 当除法。与 parser 的 `predeclareSlashStartsRegexp` 同源思想。
- **所有权 / 错误 / 调用**：无：只看前一个 token 的 kind 做查表判断（无前驱时默认「是正则」），不碰 lexer 状态、不分配、无 error set。它是兜底扫描里对 `/` 的除法/正则消歧，刻意比真正的解析器保守——只服务于错误位置定位，不影响任何编译产物。唯一调用方 `nextFallbackSyntaxTokenInto`（`src/parser.zig:16439`）。

## 覆盖核对

- 清单函数数（本文件分到）: 76（`src/parser.zig` 全文件 622）
- 本文标题覆盖（本文件）: 76
- `03-parser*.md` 合计覆盖: 649
- 未覆盖: 无
