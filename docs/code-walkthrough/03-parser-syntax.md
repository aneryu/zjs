# 03 — parser 表达式

`parseExpr` 家族：赋值、条件、`??`、逻辑、二元、一元、后缀、LHS、主键、数组/对象字面量。对照 `quickjs.c:27049..27645`。


### `parseArrowAssignment` (`src/parser.zig:3763`)

- **签名**：`fn parseArrowAssignment(s: *State, flags: ParseFlags) Error!bool`。
- **作用**：在赋值表达式的边界上做箭头函数覆盖文法的试探：认出来就整个解析成箭头函数并返回 `true`，认不出原样退回（token 未被消费）让常规路径重来。
- **实现**：三条入口，每条都先用只前瞻不发射的 `checkArrowHead*` 做确认，确认失败立刻 `return false`：`(` 开头走 `checkArrowHead`；contextual `async` 走 `checkAsyncArrowHeadAfterAsync`，确认后才 `advance` 吃掉 `async` 并以 `.async` 种类解析；单标识符形参走 `checkIdentArrowHead`。第三条之前另有三道与 `parsePrimary` 对齐的资格闸：生成器或严格模式下的 `TOK_YIELD` 不是 BindingIdentifier；`canUseAwaitAsIdentifier` 为假时的 `TOK_AWAIT` 同理；带转义且在当前上下文里其实是保留字的 `TOK_IDENT`（`escapedIdentifierIsReservedWordForCurrentContext`）也不行；非标识符类 token 直接 false。少了这些闸，这个早于 `parsePrimary` 的分发就会把 `yield` / `await` 表达式误读成箭头形参。确认通过后记下 `currentFunctionSourceStart()` 再 `parseArrowFunction`，返回 `true`。
- **所有权 / 错误 / 调用**：本函数自身不分配、不保存状态；关键契约是**返回 `false` 时 token 流必须原封不动**——三个 `checkArrowHead*` 都是复位式前瞻，只有确认成功才 `advance`（`async` 那条是唯一在确认之后、解析之前额外吃掉一个 token 的）。返回 `true` 时箭头函数的子 `FunctionDef` 已经建好并交给父 `FunctionDef`，全部所有权归 `parseArrowFunction`。错误只从 `checkArrowHead*`（前瞻中的 lexer 错误、`OutOfMemory`）与 `parseArrowFunction` 上抛，本函数没有自己的 fail 分支。唯一调用方 `parseAssignExpr2`（`src/parser.zig:4044`），且排在所有其它形态之前。

### `parseExpr` (`src/parser.zig:3802`)

- **签名**：`pub fn parseExpr(s: *State) Error!void`。
- **作用**：表达式解析的默认入口：按默认 flags 解析一个完整表达式（含逗号运算符），失败时把诊断钉在当前 token。
- **实现**：
对照 `js_parse_expr`（`quickjs.c:27645`）。一行转调 `parseExpr2(s, ParseFlags.default)`，失败时经 `propagateFailureHere` 把诊断钉在当前 token 位置。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有资源；唯一的额外动作是 `propagateFailureHere`，把诊断位置钉在本表达式开头而不是最深层的失败点。`pub` 出口：引擎内部有十余处调用，另外还是解析器测试的表达式入口（`src/tests/parser.zig`、`src/tests/helpers.zig:766`）。

### `parseExpr2` (`src/parser.zig:3807`)

- **签名**：`pub fn parseExpr2(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析逗号表达式（逗号运算符这一层）。
- **实现**：对照 `js_parse_expr2`（`quickjs.c:27621`），逗号运算符。先记下 `.expression` feature，解析首个 `parseAssignExpr2`；每遇一个 `,` 就发 `drop` 丢掉左侧值再解析下一个操作数（`result_needed` 逐轮还原成外层的值）。出现过逗号时收尾 `invalidateLastOpcode`。
- **所有权 / 错误 / 调用**：不分配、不保存状态。栈约定是本函数的核心：每个操作数各压一个值，逗号处显式 `drop` 掉左值，因此整条逗号表达式净压一个值。`invalidateLastOpcode` 不是优化而是**正确性**要求——它切断 `getLValue` 对「最后一条指令是 getter」的识别，保证 `(a, b) = c` 不会被当成合法赋值目标。错误全部来自 `parseAssignExpr2` 与 `advance`。`pub` 出口，调用方遍布语句层与表达式层（`parseExpr` 是它的默认 flags 包装）。

### `parseAssignExpr` (`src/parser.zig:3829`)

- **签名**：`pub fn parseAssignExpr(s: *State) Error!void`。
- **作用**：赋值表达式的默认入口（不含逗号运算符），失败时把诊断钉在当前 token。
- **实现**：
对照 `js_parse_assign_expr`（`quickjs.c:27615`）。一行转调 `parseAssignExpr2(s, ParseFlags.default)`，失败经 `propagateFailureHere`。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有资源，只多一层 `propagateFailureHere` 钉诊断位置。与 `parseExpr` 的区别只有一个：不吃逗号运算符，所以用在实参、初始化器、属性值等「逗号另有含义」的位置。`pub` 出口，引擎内部八处调用。

### `parseAssignExpr2` (`src/parser.zig:3836`)

- **签名**：`pub fn parseAssignExpr2(s: *State, flags: ParseFlags) Error!void`。
- **作用**：赋值表达式的正体：先试箭头与解构赋值覆盖文法，再解析条件表达式，最后按 `=` / 复合赋值 / 逻辑赋值收尾。
- **实现**：
对照 `js_parse_assign_expr2`（`quickjs.c:27311`）。`assign_expr_depth` 进出成对；若本层刚结束过 `??` 则清 `last_coalesce_expr_depth`。

顺序：`parseArrowAssignment` → `parseDestructuringAssignment` → 记下直接 ident 作为 `direct_lhs_atom` → `parseCondExpr`。若不是 `=` / 复合赋值 / 逻辑赋值则返回。`??` 表达式不能当赋值目标。

消费运算符后 `getLValue`：逻辑赋值遇到 Annex-B 运行时非法调用目标是早期 SyntaxError；普通 `=` 则跳过 RHS 可达路径、解析不可达 RHS 以保持语法状态，再 `emitInvalidAssignmentTarget`。逻辑赋值走 `parseLogicalAssignment`。否则递归解析 RHS，复合运算在运算符源位置 `Emitter.opAt`，直接 ident 且 `owns_name` 时 `setObjectName`，最后 `putLValue(..., .keep_top)`。
- **所有权 / 错误 / 调用**：`lvalue` 是唯一需要配对的资源（`defer lvalue.deinit(s)`，`.field` / `.scope_var` 等臂带 `owns_name` 的 atom）；`assign_expr_depth` 用 `defer` 减回，`last_coalesce_expr_depth` 只清不存。`direct_lhs_atom` 刻意用**本地 owner** 而不是复用下游操作数里的那份（源码注释：qjs 靠发出的 getter 钉住 `name0`，这里不依赖那个生命周期），它只用于匿名函数命名，且要求 `lvalue.owns_name` 且名字一致才 `setObjectName`。`??` 直接作赋值目标返回 `Error.InvalidAssignmentTarget`；Annex-B 的运行时非法调用目标则**不**报早期错误，而是发一段跳过 RHS、栈平衡的不可达尾巴再 `emitInvalidAssignmentTarget`——但逻辑赋值（`&&=` / `||=` / `??=`）不享受这条豁免，仍是早期 `InvalidAssignmentTarget`。`pub` 出口，除 RHS 递归自调用外，主要由 `parseExpr2` 与各初始化器位置调用。

### `parseDestructuringAssignment` (`src/parser.zig:3922`)

- **签名**：`fn parseDestructuringAssignment(s: *State, flags: ParseFlags) Error!bool`。
- **作用**：在赋值表达式位置试探 `[a, b] = x` / `({a} = x)` 这种解构赋值：认出来就整段解析掉并返回 true，认不出来不消耗任何 token。
- **实现**：首 token 不是 `[` 或 `{` 立刻返回 false。否则 `scanPatternTopology` 做一次不产生副作用的括号配平前瞻，若闭合之后**紧跟的不是 `=`** 同样返回 false（那是数组/对象字面量，交给普通表达式路径）。确认是解构赋值后转给 `parseDestructuringElement(.assignment, …)` 做真正的模式解析与发射，只把 `in_accepted` 一位旗透传下去（`pow_allowed` 等在模式内部无意义），最后返回 true。
- **所有权 / 错误 / 调用**：与 `parseArrowAssignment` 同一套契约：返回 `false` 时 token 流必须完好——`scanPatternTopology` 内部用光标快照做配平扫描并复位，本函数在它之前只做一次 `peekKind`。返回 `true` 时整段模式的绑定与字节码都已由 `parseDestructuringElement` 落定，不可回滚。本身不分配、无自有错误分支。唯一调用方 `parseAssignExpr2`（`src/parser.zig:4045`），排在箭头试探之后、`parseCondExpr` 之前。

### `parseCondExpr` (`src/parser.zig:4459`)

- **签名**：`pub fn parseCondExpr(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析条件表达式 `a ? b : c`，并发出两条分支的跳转骨架。
- **实现**：先 `parseCoalesceExpr` 吃掉条件部分；没有 `?` 就到此为止。有 `?` 时按 qjs `js_parse_cond_expr`（`quickjs.c:27282`）发两枚标签：`if_false` 跳 `else_label`；then 分支用 `forceResultNeeded(flags)` 并强制 `in_accepted = true`（`? :` 内部不受 for-init 的 no-`in` 限制），解析完 `goto end_label`；绑 `else_label`、`expectPunct(':')`、解析 else 分支（同样 `forceResultNeeded`）、绑 `end_label`。两个分支都必须留下值，所以 `result_needed` 在这里被强制打开。
- **所有权 / 错误 / 调用**：不分配、不保存状态；两个 `Label` 是栈上的值，由 `Emitter.newLabel` 登记、`bind` 消费，两条臂各绑一次。栈平衡靠语法保证：条件值被 `if_false` 消费，then / else 各留一个值，所以整体净压一个。错误只从 `expectPunct(':')` 与子解析器上抛。`pub` 出口，主调用方是 `parseAssignExpr2`（它在覆盖文法试探失败后才进来）。

### `parseCoalesceExpr` (`src/parser.zig:4482`)

- **签名**：`pub fn parseCoalesceExpr(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析 `??` 链并发出「左值非空就短路」的跳转。
- **实现**：先 `parseLogicalAndOr(TOK_LOR, flags)`；没有 `??` 就结束。有则记下 `last_coalesce_expr_depth = assign_expr_depth`（供 `??` 与 `||` / `&&` 无括号混用的报错判定），新建一个共用出口标签后循环：每个 `??` 发 `dup; is_undefined_or_null; if_false → 出口; drop`，右操作数用 `parseExprBinary(8, forceResultNeeded(flags))` 解析——只到二元第 8 级，因此链里不可能直接吞进未加括号的 `||` / `&&`。循环结束 `Emitter.bind` 绑出口（qjs `js_parse_coalesce_expr`，`quickjs.c:27254`）。
- **所有权 / 错误 / 调用**：不分配；唯一写进 `State` 的是 `last_coalesce_expr_depth`——它**只置不清**，由 `parseAssignExpr2` 在进入新的一层赋值深度时清掉，并据此把 `a ?? b = c` 判成 `Error.InvalidAssignmentTarget`。出口标签是整条 `??` 链共用的一个 `LabelId`，循环里每轮都往它上面挂一条 `if_false`，最后统一绑定。`dup` / `drop` 成对，链净压一个值。错误来自子解析器与 emit。`pub` 出口，唯一调用方 `parseCondExpr`。

### `parseLogicalAndOr` (`src/parser.zig:4503`)

- **签名**：`pub fn parseLogicalAndOr(s: *State, op_kind: tok.TokenKind, flags: ParseFlags) Error!void`。
- **作用**：解析 `||` 与 `&&` 链并发出短路跳转；`op_kind` 指定处理哪一层，`TOK_LOR` 层先递归下探 `TOK_LAND` 层。
- **实现**：两层结构同构。`TOK_LOR` 层先 `parseLogicalAndOr(TOK_LAND, flags)`，`TOK_LAND` 层先 `parseExprBinary(8, flags)`；随后若确实看到本层算子，就新建一个**物理**标签（`PhysLabel` + `newPhysLabel`）再循环：`dup`、`if_true`（`||`）或 `if_false`（`&&`）跳出口、`drop`、解析下一个操作数（`forceResultNeeded`），最后 `bindPhys` 绑出口。`dup` / `drop` 的配法保证短路时栈顶留下的正是决定短路的那个值。每轮还查一次：本层算子已断而下一个 token 是 `??` 时 `failUnexpectedToken`——这是 spec 禁止 `a || b ?? c` 这类无括号混用的落点（qjs `js_parse_logical_and_or`，`quickjs.c:27213`）。
- **所有权 / 错误 / 调用**：不分配、不保存状态。这里用的是 **`PhysLabel`**（物理标签）而不是 `LabelId`——与 qjs 的 `new_label` / `emit_label` 一一对应，每层链一个出口标签，栈上分配、`bindPhys` 消费。所有跳转与 `dup`/`drop` 都走 `NoSource` 形式，不产生源事件（短路拓扑不属于任何源码位置）。唯一自有错误是 `??` 无括号混用时的 `failUnexpectedToken`。`pub` 出口，调用方是 `parseCoalesceExpr` 与自身（`TOK_LOR` 层递归进 `TOK_LAND` 层）。

### `parseExprBinary` (`src/parser.zig:4549`)

- **签名**：`pub fn parseExprBinary(s: *State, level: u32, flags: ParseFlags) Error!void`。
- **作用**：按优先级层号递归解析二元表达式（1..8 级），并在算子的源位置上发出对应 opcode。
- **实现**：手写 Pratt：`level == 0` 落到 `parseUnary`（`pow_allowed = true`，其余 flag 透传）。第 4 级上有一条特例——`in_accepted` 且当前是 `TOK_PRIVATE_NAME`、下一个是 `in` 时解析 `#x in obj`：`findClassPrivateBoundName` 查不到该私有名就 `failUnexpectedToken`，吃掉私有名与 `in`，挡掉紧跟的箭头头部，解析右侧后发 `scope_in_private_field <atom> <scope_level>`。一般情形是先 `parseExprBinary(level - 1, flags)`，再循环：`matchBinaryOp(peekKind(), level, flags)` 取本层 opcode，取到 `invalid` 就返回；记下算子 token 的行列、`advance`、生成器内紧跟 `yield` 直接报错、递归解析右操作数，最后用 `Emitter.opAt` 把算子指令钉在算子自己的源位置上——与 qjs 一样是在解析完 RHS 之后才钉（`quickjs.c:27889-27894`）。
- **所有权 / 错误 / 调用**：不分配、不保存状态；私有名那条臂取到的 `private_atom` 只是借用 id（源码里的 `retained_private_atom` 是 TGC S3-c 之前的遗名），写进 `scope_in_private_field` 的操作数。递归深度由 `parseUnary` / `advance` 里的原生栈检查兜底（`Error.StackOverflow`）。两处自有错误：私有名未在任何类里绑定、以及生成器里算子后紧跟 `yield`，都是 `failUnexpectedToken`。`pub` 出口，调用方是 `parseLogicalAndOr`、`parseCoalesceExpr` 与自身递归。

### `parseUnary` (`src/parser.zig:4595`)

- **结构（2026-09-19 拆分后）**：前缀 `++`/`--` 在 `parsePrefixUpdate`，`yield` 在 `parseYieldExpression`，`await` 在 `parseAwaitExpression`；本函数只剩一元运算符与 `**` 尾。
- **签名**：`pub fn parseUnary(s: *State, flags: ParseFlags) align(16) Error!void`。
- **作用**：解析一元与前缀表达式：`+` `-` `~` `!` `void` `typeof` `delete`、前缀 `++` / `--`、右结合 `**`，以及上下文相关的 `yield` 与 `await`。
- **实现**：
对照 `js_parse_unary`（`quickjs.c:26922`）。`align(16)` 是热路径取指边界。

前缀 `+` → 递归 unary（禁止 `**`、禁止 yield）再 `to_number`；`-` 在 short opcode 下把精确 i32 字面量折成 `push_i32` 负值，否则 `neg`；`~` → `not`；`!` → `lnot`；`void` → `drop`+`undefined`；`typeof` 把最后一条 `scope_get_var` 改成 `scope_get_var_undef` 再 `typeof`；`delete` 交给 `parseDelete`。

前缀 `++`/`--`：解析 unary、`getLValue(keep)`、在运算符源位置 `inc`/`dec`、`putLValue(.keep_top)`；若随后是 `**` 再解析右操作数。非法调用目标走 `emitInvalidAssignmentTarget`。

class static block 里 `await`/`yield` 直接 unexpected。`yield`：参数默认值、非生成器（严格或后面像表达式）报错；生成器里 `yield*` 走 `emitYieldStarDelegation`，光 `yield` 推 `undefined`，有操作数则 `parseAssignExpr2`，然后 `yield` + `if_false` 跳过 `emitReturnValue`（生成器被 `return()` 恢复时才走这条返回路径）。行终结后的 `*` 是语法错误。

`await`：参数默认值拒绝 AwaitExpression；非 async 且非模块顶层时，若可当 ident 则当 postfix，否则 `AwaitOutsideAsyncFunction`。模块顶层设 `has_top_level_await`。操作数是 UnaryExpression（所以 `await x * y` 是 `(await x)*y`），再 `await`。

否则 `parsePostfixExpr`；`PF_POW_ALLOWED` 且看到 `**` 则右结合再解析 unary。
- **所有权 / 错误 / 调用**：不分配堆内存；前缀 `++`/`--` 那条臂的 `lvalue` 是唯一需要配对的资源（`defer lvalue.deinit(s)`）。`typeof` 那条臂**直接改写 Builder 已发出的字节**（把最后一条 `scope_get_var` 的 opcode 就地换成 `scope_get_var_undef`），只在 `last_opcode_pos` 确实指向该指令时才动，成员/调用/逗号尾巴一律不碰。写进 `State` 的持久位有两个：`features` 与模块的 `has_top_level_await`。错误分层明显：`Error.YieldOutsideGenerator` 与 `Error.AwaitOutsideAsyncFunction` 是**不带诊断消息的错误码**（由上层统一成消息），其余（静态块里的 `await`/`yield`、`yield_forbidden`、参数初始化器里的 `yield`/`await`、换行后的 `yield *`）走 `failUnexpectedToken`。递归很深（每个前缀都递归自身），靠 `advance` 里的原生栈检查产生 `Error.StackOverflow`。`pub` 出口，主调用方是 `parseExprBinary(level 0)` 与自身递归；`align(16)` 是为了在前一个递归调度器代码尺寸变化时把这个热后继钉在稳定的取指边界上。

### `parsePostfixExpr` (`src/parser.zig:5375`)

- **签名**：`pub fn parsePostfixExpr(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析左值表达式后面可能跟的后缀 `++` / `--`。
- **实现**：先 `parseLhsExpr`；后面不是 `TOK_INC` / `TOK_DEC` 就直接返回。ASI 闸：`s.lex.got_lf` 为真（算子与操作数之间隔了行终结符）同样返回，把 `++` 留给下一条语句（qjs `quickjs.c:26206`）。否则 `getLValue(s, true)` 取可写引用（`defer lvalue.deinit`），记下算子行列，按 token 选 `post_inc` / `post_dec`，`advance` 吃掉算子。lvalue 带 `invalid_call` 标记时（`f()++` 这类）只发 `emitInvalidAssignmentTarget`，把 ReferenceError 留到运行时再抛。正常路径 `Emitter.opAt` 把更新指令钉在算子位置，再 `putLValue(&lvalue, .keep_second)` 写回并把**旧值**留在栈上。
- **所有权 / 错误 / 调用**：不分配；`lvalue` 用 `defer lvalue.deinit(s)` 配对。栈约定与前缀形态不同：`putLValue(.keep_second)` 保证留在栈上的是**自增前的旧值**。没有自有的 fail 分支——`f()++` 不报早期错误而是发 `emitInvalidAssignmentTarget` 把 ReferenceError 推到运行时（Annex-B）。`got_lf` 那条 ASI 闸不报错，只是把 `++` 让给下一条语句。`pub` 出口，调用方是 `parseUnary` 的三处（`src/parser.zig:4924` 非生成器 `yield`、`:4983` 可当标识符的 `await`、`:4999` 一般路径）。

### `parseLhsExpr` (`src/parser.zig:5411`)

- **签名**：`pub fn parseLhsExpr(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析左值表达式：主表达式加上任意多的成员访问、调用与 `new`，并在这里收口可选链、展开 `super(...)`。
- **实现**：先取头（`new` 走 `parseNewExpr`，否则 `parsePrimary`）并记下 `last_was_super`，再由 `parseMemberChain` 吃掉后续的 `.x` / `[x]` / `(...)` / `?.`，可选链出口标签经 `optional_chain_label` 回传。链上出现过 `?.` 时在这里收口：记下当前 `code_len` 作为 getter 末尾，`Emitter.bindParserRaw` 绑出口（raw：保留最后一条 getter 的 provenance），再把紧邻的尾码换成可选链版本——6 字节的 `get_field` → `get_field_opt_chain`、1 字节的 `get_array_el` → `get_array_el_opt_chain`，都对不上就 `invalidateLastOpcode`；这一步让 `delete a?.b` / `a?.b()` 仍能从真正的最后一条 getter 取身份，不必靠字节签名恢复。最后是 `super(...)`：仅当 `was_super`、没有可选链、下一个是 `(` 时进入；`allow_super_call` 为假 `failUnexpectedToken`；`this_active_func_var_idx` / `new_target_var_idx` / `this_var_idx` 任一为负说明 super 是跨函数捕获来的，转 `parseCapturedSuperConstructorCall` 并返回。常规路径 `discardTrailingGetSuper` 撤掉刚发的取 super 尾码，重发 `get_loc <active_func>; get_super; get_loc <new_target>`，`parseCallArgs` 之后按形态发 `call_constructor <argc>` 或 `apply 1`（都钉在 `super` 的源位置），然后 `dup` + `put_loc_check_init <this>` 完成 `this` 的 TDZ 初始化、`emitClassFieldInitCall` 跑字段初始化器；派生构造器里若登记了 TS 参数属性，再逐个发 `this.<name> = <param>`。
- **所有权 / 错误 / 调用**：不分配；`optional_chain_label` 是 `parseMemberChain` 通过出参交回来的**必须绑定一次**的标签身份，本函数是它唯一的绑定点。可选链收口与 `discardTrailingGetSuper` 都会**就地改写或截断已发出的字节码**（前者把尾码换成 `*_opt_chain`，后者撤掉刚发的 `get_super`），这是本函数最容易踩的不变量：改写只在 `last_opcode_pos` 与 `code_len` 恰好对齐尾指令时进行，否则 `invalidateLastOpcode` 放弃。`s.last_was_super` 是一次性标志，用完置 `false`。TS 参数属性读的是 `current_parameter_properties` 里借来的 atom。唯一自有错误是 `super()` 出现在 `allow_super_call` 为假处的 `failUnexpectedToken`。`pub` 出口，调用方有 `parsePostfixExpr`（`src/parser.zig:5580`）、`parseForInOf` 的左端（`:10898`）、`parsePatternTarget` 的 assignment 臂（`:12706`）、`parseClassHeritage`（`:13693`）。

### `parseCapturedSuperConstructorCall` (`src/parser.zig:5480`)

- **签名**：`fn parseCapturedSuperConstructorCall(s: *State, flags: ParseFlags, loc: ?SourceLoc) Error!void`。
- **作用**：在 `this` / `new.target` / `<this_active_func>` 不是当前函数局部槽时（典型是构造器里的箭头函数）发射 `super(...)`，三个隐式绑定全部走 phase-1 的 `scope_get_var`，由 `resolve_variables` 解析成闭包捕获。
- **实现**：先 `discardTrailingGetSuper` 撤掉成员链已经发出的那条 `get_super`，再按 `<this_active_func>` → `get_super` → `<new.target>` 的顺序重建调用前缀。`parseCallArgs` 返回 `.direct` 时发 `call_constructor argc`，`.applied`（带 spread）时发 `apply 1`；两种都在有 `loc` 时用带行列的 `opU16At` 变体。随后 `dup` 结果并 `scope_put_var_init <this>` 完成 this 绑定，接着 `emitClassFieldInitCall` 跑实例字段初始化。最后若身处带 `extends` 的构造器且有 TypeScript 参数属性（`current_parameter_properties`），逐个发 `this.x = x`。
- **所有权 / 错误 / 调用**：不分配、不持有资源，纯发射；`loc` 是可选的行列标量，`null` 时用不带源事件的 `opU16` 变体。与 `parseLhsExpr` 里的常规 super 路径相比，差别只有「三个隐式绑定用 `scope_get_var`/`scope_put_var_init` 而不是 `get_loc`/`put_loc_check_init`」——也就是把解析推迟给 `resolve_variables`，让箭头函数拿到闭包捕获。已发出的字节码不可回滚，失败时整个 `FunctionDef` 被上层丢弃。错误全部来自 `parseCallArgs` 与 emit 路径。两个调用方：`parseLhsExpr`（`src/parser.zig:5650`）与 `parseMemberChain` 里的 `super(` 臂（`:5994`）。

### `emitClassFieldInitCall` (`src/parser.zig:5521`)

- **签名**：`fn emitClassFieldInitCall(s: *State) Error!void`。
- **作用**：在 `super()` 返回之后调用词法里的 `<class_fields_init>` 闭包，把实例字段装到新的 `this` 上。
- **实现**：对照 `emit_class_field_init`（`quickjs.c:25184-25207`）：`scope_get_var <class_fields_init>` 取出闭包后 `dup` 一份做条件，`if_false` 跳到新建的 `skip_call` 标签（没有字段时该槽是 undefined）；不跳则 `scope_get_var <this>` + `swap` 把接收者摆到位，`call_method 0` 调用。标签绑在共用的收尾处，两条路径都以一条 `drop` 结束，栈高度一致。两个名字都保持 phase-1 的 scope 操作数，于是直接构造器解析成局部、含 `super()` 的箭头函数解析成闭包捕获。
- **所有权 / 错误 / 调用**：不分配；`skip_call` 是栈上的 `Label`，建出来后必定被 `bind` 一次。栈平衡是本函数的硬约定：进来时压一个闭包值，两条路径（调用过 / 跳过）都汇合到同一条 `drop`，净效应为零。发出的码不可回滚。无自有错误分支。四个调用方：`parseLhsExpr` 的常规 `super()`（`src/parser.zig:5665`）、`parseCapturedSuperConstructorCall`（`:5709`）、`parseMemberChain` 的 `super(` 臂（`:6008`）、以及基类构造器进入体之前的那次（`parseFunctionParamsAndBody`，`:11932`）。

### `parseNewExpr` (`src/parser.zig:5536`)

- **签名**：`fn parseNewExpr(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析 `new` 开头的表达式，包括 `new.target`、`new new F().m` 这样的嵌套，以及带不带实参表的构造调用。
- **实现**：吃掉 `new` 后先看 `.`：只接受无转义的标识符 `target`，且当前上下文 `new_target_allowed`，否则 `failUnexpectedToken`；随后生产路径发 `scope_get_var <new.target>`，独立 ParseState（测试用，`emit_to_function_def` 为假）退化成 `special_object 3`，然后直接返回。callee 部分分三臂：`new` 递归调自身、`import` 先确认下一枚是 `.`（不是就 `failExpectedDescriptionAt("'.'")`）再走 `parsePrimary`，其余也走 `parsePrimary`；三臂都接 `parseNewCalleeMemberAccess` 吃成员尾，这样 `new new F().m` 解析成 `new ((new F()).m)`，与 qjs 递归 `js_parse_postfix_expr(s, 0)`（`quickjs.c:27016`）一致。实参表存在时 `dup` 出 new.target 再按 `parseCallArgs` 的形状发 `call_constructor argc`，或 spread 形状下按 `quickjs.c:27359-27364` 的 `perm3 ; apply 1` 把 dup 出来的 callee 挪进 new.target 槽。没有括号的 `new X` 等价于 `new X()`：先发一条源事件（对齐 `quickjs.c:27020-27025` 的单事件顺序）再 `dup ; call_constructor 0`。
- **所有权 / 错误 / 调用**：不分配、不保存状态。栈约定：callee 压一个值，`dup` 出的第二份就是 new.target，`call_constructor` / `apply` 各自消费掉它们，净压一个结果。`peekNextDiagnosticToken` 是带位置的前瞻（自复位），只用来给 `new import` 报一个指向正确 token 的错误。两处自有 `failUnexpectedToken`（`new.` 后面不是无转义的 `target`、以及 `new_target_allowed` 为假），一处 `failExpectedDescriptionAt`。递归调用自身处理 `new new F()`。唯一调用方 `parseLhsExpr`（`src/parser.zig:5617`）。

### `parseNewCalleeMemberAccess` (`src/parser.zig:5604`)

- **签名**：`fn parseNewCalleeMemberAccess(s: *State) Error!void`。
- **作用**：吃掉 `new` 的 callee 后面那段成员访问尾（`.x` / `#x` / `[e]` / 模板标签），但**不**吃实参括号——括号留给 `parseNewExpr` 当构造实参。
- **实现**：循环看当前 token：`.` 之后接受标识符、私有名，以及关键字（`keywordAtom` 还原 atom）和被词法特殊化的 `delete`(atom 9) / `catch`(atom 25)，其余 `failUnexpectedToken`。私有名要求 `in_class` 且 `classPrivateNameIsBound`，经 `privateNameAtom` 换成带类身份的 atom，发 `scope_get_private_field name, scope_level`；普通名发 `get_field`。操作数在属性 token 仍持有 atom 时就发出、再 `advance` 让 token 释放它，保持与 qjs 相同的单次 retain 路径。`[` 臂递归 `parseExpr` 后 `expectPunct(']')` 再发 `get_array_el`；模板 token 交 `parseTaggedTemplateInvocation`。都不匹配就返回，把 `(`（若有）留给调用方。每个访问点先 `emitGrammarSource` 记下该访问自己的行列。
- **所有权 / 错误 / 调用**：不分配；属性名 atom 全是借用的 token 内容，**必须在 `advance()` 之前写进操作数**（源码注释说明这与 qjs 的单次 retain 路径一致）。私有名经 `privateNameAtom` 得到的是类身份限定后的 atom，同样只是 id。原先那个从未被读的 `flags` 形参（末尾只有一条 `_ = flags;`）已从签名和全部调用点删除。错误：`.` 后面不是可接受的属性名、类外用私有名、私有名未绑定，都是 `failUnexpectedToken`，另有 `expectPunct(']')`。三个调用点全在 `parseNewExpr`（`src/parser.zig:5767` / `:5774` / `:5777`）。

### `parseMemberChain` (`src/parser.zig:5659`)

- **签名**：`fn parseMemberChain(s: *State, flags: ParseFlags, optional_chain_label: *?OptionalChainLabel) Error!void`。
- **作用**：循环吃掉左值后面的 `.x` / `[x]` / 调用 / 标签模板 / `?.`，其中 super 属性、私有名与可选链各有专门的发射形态。
- **实现**：
LHS 的 `.` / `[]` / 调用 / 模板标签 / `?.` 循环。`?.` 发 `optional_chain_test` 跳到共享出口标签。`super.x` / `super[x]` 先 `discardTrailingGetSuper` + `emitSuperThisAndHomeObject` + `get_super`，再用 `get_super_value` 取值（不是 `get_field`/`get_array_el`）。私有名走 `scope_get_private_field`，且要求在类体内且该名字已绑定。调用走 `prepareCallReference` + `parseCallArgs` + `emitPreparedCall`；`super(...)` 例外：直接 `get_loc <this_active_func>` + `get_super` + `get_loc <new_target>` 后发 `call_constructor`（有 spread 则 `apply`），再 `dup` + `put_loc_check_init <this>` + `emitClassFieldInitCall`；三个槽位有一个没分配就退到 `parseCapturedSuperConstructorCall`。标签模板走 `parseTaggedTemplateInvocation`（`?.` 链里禁止）。`new` 不在这里（`parseLhsExpr` 先分流）。
- **所有权 / 错误 / 调用**：不分配堆内存。两个跨轮次的状态要点：(1) `s.last_was_super` 在每个访问臂开头**先取走再置 `false`**，保证 `super.x.y` 里只有第一段是 super 形态；(2) `optional_chain_label` 是出参，第一次遇到 `?.` 时由 `emitOptionalChainTest` 建出身份、之后各段共用，但**绑定不在本函数**——交回 `parseLhsExpr` 收口，所以中途 `return` 的错误路径会留下一个未绑定的标签身份（错误路径整个 `FunctionDef` 会被丢弃，所以不构成泄漏）。属性名 atom 全是 token 借用的，写进操作数后才 `advance`。super 形态会 `discardTrailingGetSuper` **截断已发出的尾码**再重发。错误面：`.` / `?.` 后面不是可接受的属性名、`super?.`、类外私有名、未绑定私有名、`super()` 在 `allow_super_call` 为假处、可选链里的标签模板，全是 `failUnexpectedToken`。唯一调用方 `parseLhsExpr`（`src/parser.zig:5623`）。

### `parseTaggedTemplateInvocation` (`src/parser.zig:5818`)

- **签名**：`fn parseTaggedTemplateInvocation(s: *State) Error!void`。
- **作用**：把标签模板降成对模板对象的调用。
- **实现**：
`prepareCallReference(.template)` 拿 callee。无替换的模板：runtime 下 `TaggedTemplateObjectBuilder` 冻一对象，否则测试占位。有替换则循环 `parseExpr` + `nextTemplatePartAfterBraceInto`，argc 含模板对象。`emitPreparedCall` 后 `invalidateLastOpcode`（标签模板不是赋值目标）。
- **所有权 / 错误 / 调用**：有 runtime 时 `TaggedTemplateObjectBuilder` 会**真的造一个 GC 对象**（cooked/raw 两个数组的模板对象），经 `Emitter.pushConst` 进 `curFunc().cpool` 后所有权归 `FunctionDef`，编译期由 `traceCompileValueRoots`（`src/parser.zig:1095`）保活；无 runtime 的解析器专用 `State` 落到 `emitTaggedTemplateSingletonObject` / `undefined` 占位那条臂，不造对象。带替换的循环里手工管 token：`s.lex.freeToken(&s.token)` 之后立刻 `nextTemplatePartAfterBraceInto` 换成下一段模板 token——这一对必须成对出现，否则 token payload 会泄漏或被二次释放。收尾的 `invalidateLastOpcode` 是**正确性**动作：标签模板是 CallExpression TemplateLiteral，不能被 `getLValue` 当成可赋值的调用目标。错误：模板 payload 缺失或替换段没有以 `}` 收尾，都是 fail 族。两个调用点：`parseNewCalleeMemberAccess`（`:5856`）与 `parseMemberChain`（`:6016`）。

### `parseCallArgs` (`src/parser.zig:5933`)

- **签名**：`fn parseCallArgs(s: *State, flags: ParseFlags) Error!CallArgsShape`。
- **作用**：解析 `(arg0, arg1, ...)` 实参表（自己吃掉 `(` 与 `)`），返回 `CallArgsShape` 告诉调用方用直接调用还是 `apply`。
- **实现**：无 spread 时逐个 `parseAssignExpr2` 计数，返回 `.direct = argc`（参数留在栈顶）；一旦出现 `...`，改成 QuickJS 的 `apply` 降法——在栈上攒一个实参数组并返回 `.applied`，最终的 `apply <is_new>` 与栈整理（普通调用 `undefined; swap`、方法/`new` 用 `perm3`）由调用方负责。参数 `flags` 未使用。
- **所有权 / 错误 / 调用**：不分配堆内存；返回的 `CallArgsShape` 是纯值，但它**同时描述了栈上的形状**，调用方必须按约定收尾：`.direct` 时 argc 个实参在栈顶，`.applied` 时栈顶是一个实参数组（spread 路径内部用 `array_from` + `push_i32` 维护一个索引，收尾 `drop` 掉索引只留数组）。实参一律用 `ParseFlags.default`（`in_accepted = true`），因此 for-init 的 no-`in` 限制在实参位置被重置；传进来的 `flags` 实际未使用（首行 `_ = flags;`）。错误来自 `expectPunct` 与 `parseAssignExpr2`。六个调用点：`parseLhsExpr`（`src/parser.zig:5658`）、`parseCapturedSuperConstructorCall`（`:5690`）、`parseNewExpr`（`:5783`）、`parseMemberChain` 的三处（`:5922` 可选调用、`:6001` super()、`:6012` 普通调用）。

### `parseRegExpLiteral` (`src/parser.zig:5986`)

- **签名**：`fn parseRegExpLiteral(s: *State) Error!void`。
- **作用**：解析正则字面量，并在**解析期**就把它编译好，发 `regexp` opcode。
- **实现**：
先从 `lex.mark_pos` 处 `rescanRegexpInto` 重扫出 pattern/flags（词法层默认把 `/` 当除号）。第一条常量是 pattern 源文本：用 `String.createUtf8` 转成运行时字符串再 `pushConstOwned`（不 intern 成 atom）。随后 `regexp_lib.compilePatternAndFlagsWithOptions` 就地编译，栈溢出回调是 `lreCheckStackOverflow`；错误映射为 `OutOfMemory` / `StackOverflow` / `InvalidRegExp`。第二条常量是编译出的 lre 字节码（`String.createLatin1`），最后发 `regexp`。这样每次求值该字面量时运行时只是共享这段不可变字符串，而不是重新编译。需要 runtime（`s.runtime.?`）。
- **所有权 / 错误 / 调用**：这是 parser 里少数**真正造 GC 对象**的地方：两个 `core.string.String`（源 pattern 的 UTF-8 解码串、`compilePatternAndFlagsWithOptions` 产出的 lre 字节码 Latin-1 串）经 `Emitter.pushConstOwned` 交给 `curFunc().appendCpool`，所有权从此归 `FunctionDef.cpool`，在编译期间由 `ParseState.traceCompileValueRoots`（`src/parser.zig:1095`）注册的 RootProvider 保活，最终随 `createFunctionBytecode` 进 FB。中间的 `compiled` 正则结果是**临时**的，`defer compiled.deinit(s.function.memory.allocator)` 就地释放。token 侧：先 `freeToken` 旧 token 再 `rescanRegexpInto` 重扫成正则 token，`pattern`/`flags` 是指向该 token payload 的借用切片，必须在末尾 `s.advance()` 之前用完。错误映射是本函数最具体的部分：`String` 的 `OutOfMemory`/`StringTooLong` → `Error.OutOfMemory`，`InvalidUtf8` 原样，正则编译的 `StackOverflow` → `Error.StackOverflow`（对应 qjs `libregexp.c:2411` 的 re_parse_error，最终被 `compile` 收成 SyntaxError），其它一律 `Error.InvalidRegExp`。注意 `s.runtime.?`：**无 runtime 的解析器专用 `State` 走到这里会 panic**。唯一调用方 `parsePrimary`（`:6256`）。

### `parsePrimary` (`src/parser.zig:6029`)

- **签名**：`fn parsePrimary(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析主表达式：各类字面量、`this` / `super` / `import` / `class` / `function`、标识符与括号表达式。
- **实现**：
对照 `js_parse_primary`/`postfix` 内层（`quickjs.c:25500`）。

- 数字：bigint → `emitBigIntLiteral`；精确 i32 → `push_i32`；否则 `pushConst(float64)`。
- 字符串：`emitStringLiteralValue`（`push_atom_value`，tagged-int atom 在有 runtime 时改 cpool 字符串）。
- `/` 或 `/=`：`parseRegExpLiteral`。
- 模板：`parseTemplate`。
- true/false/null：对应 push opcode。
- `this`：`emitThisValue`，清 `last_was_super`。
- `super`：需 `allow_super`，发 `get_super`，设 `last_was_super`。
- `import`：`import.meta` 仅模块非 eval，发 `special_object import_meta`；否则 `parseDynamicImportCall`。
- `class`：`parseClass(false)`。
- `function`：普通函数表达式（`async function` 的 `async` 是 TOK_IDENT，由下面的 ident 臂接管，所以这条臂不再探测 async）。
- ident / 上下文关键字：async function 无换行则 `parseFunctionExpr(.async)`；禁止转义 `import(` / `import.`；`arguments` 在禁止环境失败；否则源位置 + `emitScopeGetVar`。
- 松散 `let`：当 ident 读绑定。
- `(`：`parseExpr2(ParseFlags.default)`（分组重置 `in`/`yield` 限制）再 `)`。
- `[` / `{`：字面量。
- **所有权 / 错误 / 调用**：本身不分配，但有两条臂会**造 GC 值并交给 `curFunc().cpool`**：非精确 i32 的数字走 `pushConst(JSValue.float64(...))`，正则走 `parseRegExpLiteral`（两个字符串常量）；BigInt 字面量由 `emitBigIntLiteral` 处理。`s.last_was_super` 是本函数唯一写的跨函数状态：只有 `super` 那条臂置 `true`，其余臂显式清 `false`（`parseLhsExpr` 立刻读走）。标识符 atom 借自 token，写进 `scope_get_var` 操作数后才 `advance`。错误分两类：`Error.AwaitOutsideAsyncFunction` / `Error.YieldOutsideGenerator` 是无消息错误码，其余（`import.meta` 出现在非模块或 eval、带转义的 `import(`、禁止环境里的 `arguments`、严格模式下的 `let` 标识符、无法开始表达式的 token）都是 `failUnexpectedToken`。两个调用方：`parseLhsExpr`（`src/parser.zig:5619`）与 `parseNewExpr` 的两条 callee 臂（`:5773` / `:5776`）。

### `parseDynamicImportCall` (`src/parser.zig:6205`)

- **签名**：`fn parseDynamicImportCall(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析 `import(specifier[, options])` 动态导入调用并降成 `import` opcode。
- **实现**：记下 `.dynamic_import` feature，吃掉 `import` 与 `(`，用 `ParseFlags.default`（重置 no-in）解析 specifier。第二个参数：没有逗号、或逗号后直接是 `)` 时补一条 `undefined` 占位；否则解析 options 并允许一个尾随逗号。最后 `)` + `Emitter.op(import)`；参数 `flags` 未使用。
- **所有权 / 错误 / 调用**：不分配、不持有资源；`flags` 未使用（首行 `_ = flags;`），内部一律用 `ParseFlags.default`。栈契约固定为两格：specifier 与 options（缺省时补 `undefined`），由 `import` opcode 一并消费。写进 `State` 的只有 `.dynamic_import` feature 位。错误来自 `expectPunct` 与 `parseAssignExpr2`。唯一调用方 `parsePrimary` 的 `TOK_IMPORT` 臂（`src/parser.zig:6303`，即下一枚 token 不是 `.` 的那条分支）。

### `parseTemplate` (`src/parser.zig:6243`)

- **签名**：`fn parseTemplate(s: *State, flags: ParseFlags) Error!void`。
- **作用**：解析不带标签的模板字面量，降成 `concat` 拼接序列。
- **实现**：循环吃 `TOK_TEMPLATE` 分片。每片先取 payload：没有 `template` 标记说明词法状态错乱，`failUnexpectedToken`；`cooked_invalid`（非法转义）直接 `Error.InvalidEscape`。片段非空或 `depth == 0` 时 `emitStringLiteralValue` 压串；其中 `depth == 0` 的首片若就是 `.no_substitution`（整串没有替换位），吃掉 token 直接返回——单个字符串常量不必搭拼接序列；否则 intern `"concat"` 并发 `get_field2 concat`，把方法与首片一起备好。`.tail` 片发 `call_method depth - 1` 收尾返回。`.head` / `.middle` 则 `advance` 后 `parseExpr` 解析替换表达式、`depth += 1`，并要求正停在 `}`（否则 `failExpectedToken('}')`）；随后 `freeToken` + `lex.nextTemplatePartAfterBraceInto` 让词法器从 `}` 之后按模板规则继续扫下一片（前瞻 `}` 已把 `lex.pos` 推过一字节，不能再 bump）。循环正常退出意味着始终没等到 `.tail`，报 `failUnexpectedToken`。带标签的模板不走这里，由 `parseTaggedTemplateInvocation` 处理（qjs `js_parse_template`，`quickjs.c:23880`）。
- **所有权 / 错误 / 调用**：不分配堆内存；`bytes` 是模板 token payload 的借用切片，必须在换片之前发完。换片这一步有严格的手工协议：`freeToken(&s.token)` 之后立刻 `lex.nextTemplatePartAfterBraceInto(&s.token)`，而且**不能再 bump `lex.pos`**（前瞻 `}` 时已经推过一个字节）。栈契约：`get_field2 concat` 压方法+接收者两格，之后每片/每个替换表达式各压一格，收尾 `call_method depth - 1` 全部消费；`.no_substitution` 的快路径在建立这套契约之前就返回，所以不会失衡。`flags` 未使用。错误：非法 cooked 转义是 `Error.InvalidEscape`，payload 缺 `template` 标记或替换段没停在 `}` 是 fail 族，循环耗尽而没见到 `.tail` 同样 `failUnexpectedToken`。唯一调用方 `parsePrimary` 的 `TOK_TEMPLATE` 臂（`src/parser.zig:6257`）。

### `parseObjectProperty` (`src/parser.zig:6518`)

- **签名**：`fn parseObjectProperty( s: *State, flags: ParseFlags, proto_field_seen: *bool, capacity_hint: *ObjectLiteralCapacityHint, ) Error!void`。
- **作用**：解析对象字面量的一个属性（spread/方法/访问器/简写/键值）。
- **实现**：
属性始终用 `PF_IN_ACCEPTED` 解析（对象字面量重置 for-init 的 no-in）。
- `...`：spread，`copy_data_properties`，作废容量提示。
- `*`：生成器方法，计算名用 `define_method_computed`。
- 上下文 `async`（后面不是 `:`/`(`/`,`/`}`，且无换行）：async / async generator 方法。
- `get`/`set`：`parseObjectAccessorProperty`。
- 计算名 `[expr]`：方法或数据属性。
- 普通名：`(` → 方法；`:` → 数据属性（`__proto__` 走 `ext0/set_proto` 且整个字面量里只允许一次，重复即语法错误；其余名字 `setObjectName` + `define_field`）；否则简写，保留字/转义拒绝。
- **所有权 / 错误 / 调用**：不分配堆内存；属性名 atom 来自 `parseObjectPropertyName`（借用 id，由 `CompileAtomScope` 作根）。两个出参是调用方持有的累积状态：`proto_field_seen` 记「`__proto__:` 已经出现过一次」，重复即语法错误；`capacity_hint` 在遇到 spread / 计算名这类无法静态计数的形态时被 `invalidate()`，用于给对象字面量预估 shape 容量——两者都由 `parseObjectLiteral` 拥有，本函数只写不建。`flags` 未使用（首行 `_ = flags;`），内部一律用 `ParseFlags.default`。栈契约：进来时对象已在栈顶，每条臂自己把属性装完并把对象留在原位（spread 臂用两条 `drop` 平衡 excludeList 与源对象）。错误：重复 `__proto__`、简写位置上的保留字/转义标识符、缺 `(` 等，全是 fail 族。唯一调用方 `parseObjectLiteral`。

### `parseObjectAccessorProperty` (`src/parser.zig:6669`)

- **签名**：`fn parseObjectAccessorProperty( s: *State, flags: ParseFlags, func_kind: ParseFunctionKind, define_flags: u8, source_start: FunctionSourceStart, capacity_hint: *ObjectLiteralCapacityHint, ) Error!void`。
- **作用**：解析对象字面量里的 `get` / `set` 访问器属性。
- **实现**：计算名 `[expr]` 分支作废容量提示、解析键表达式、要求紧跟 `(`，然后 `parseObjectMethodFunction` + `define_method_computed`（flags 带 `| 4`）。静态名分支用 `parseObjectPropertyName` 取名（取不到就 unexpected）、记进容量提示，同样要求 `(`，最后发 `define_method`（同样 `| 4`）。
- **所有权 / 错误 / 调用**：不分配；`define_flags` 是调用方算好的位（getter=1 / setter=2），本函数只在其上或一个 `| 4`（enumerable 标志）。`capacity_hint` 是调用方的累积状态：计算名臂 `invalidate()`，静态名臂把名字记进去。`source_start` 是标量，透传给 `parseObjectMethodFunction` 供 `toString` 截源。方法体的子 `FunctionDef` 全部由 `parseObjectMethodFunction` → `parseFunctionParamsAndBody` 记账。错误：取不到属性名、访问器名后不是 `(`，都是 fail 族。唯一调用方 `parseObjectProperty` 的 `get`/`set` 臂（`src/parser.zig:6839`）。

### `parseObjectPropertyName` (`src/parser.zig:6703`)

- **签名**：`fn parseObjectPropertyName(s: *State) Error!?ObjectPropertyName`。
- **作用**：把 ident/关键字/字符串/数字收成属性名 atom。
- **实现**：
ident / 可用的 `await` / 关键字 / 字符串 / 数字（bigint 先 format）。返回 atom、是否 `__proto__`、能否简写、是否转义。无法构成名字返回 null（调用方处理计算名）。
- **所有权 / 错误 / 调用**：返回的 `ObjectPropertyName.atom` 分两种来源，但如今**所有权义务相同**：ident 臂直接借 `s.token.payload.ident.atom`，关键字臂取预定义 id，字符串/数字臂则 `atoms.internString` 新建——三者都只是 id，由 `CompileAtomScope` 在整场编译内作根，调用方不需要也不应该 release。结构体原来还有一个 `retained` 字段（记 atom 是不是本函数新 intern 的），**全树无人读取**，是旧引用计数协议的残留，已连同三处写入一并删除。真正的生命周期约束是借用语义而非计数：ident 臂的 id 在 `s.advance()` 之后仍然有效（`advance` 释放的是 token payload，不是 atom），由整场编译的 `CompileAtomScope` 作根。分配只有 bigint 属性名的 `formatBigIntPropertyName` 临时缓冲，由 `defer ... free(text)` 就地释放。错误：`internString` 的 `OutOfMemory`、`advance` 的 lexer 错误族；不认识的 token 返回 `null`（由调用方决定是不是语法错误）。7 处调用方：`parseObjectProperty`（`:6766`/`:6797`/`:6827`）、`parseObjectAccessorProperty`（`:6897`）、`parseObjectPatternBody`（`:13041`）、`parseClassElement`（`:13788`/`:13879`）。

### `escapedIdentifierIsReservedWordForBinding` (`src/parser.zig:6748`)

- **签名**：`noinline fn escapedIdentifierIsReservedWordForBinding(s: *State, atom_id: Atom, has_escape: bool) bool`。
- **作用**：转义过的标识符若拼出保留字，则不能当绑定名（`null`/`true`/`if`/…；严格模式再加 `let`/`yield` 等；async/module/static-block 再加 `await`）。
- **实现**：`!has_escape` 立即 false。`atoms.name` 失败也 false。然后一串 `mem.eql`：无条件关键字；`strict = is_strict || curFunc().is_strict_mode` 时 FutureReservedWord（`implements`/`interface`/`let`/`package`/`private`/`protected`/`public`/`static`）；`(in_generator || strict)` 时 `yield`；`(in_async || lex.is_module || in_class_static_block)` 时 `await`。outlined 是为合并 leftover 里 CurrentContext 上那份重复检查。
- **所有权 / 错误 / 调用**：只读 atom 名（`atoms.name` 返回的借用切片当场比完即弃），不分配、无 error set、无副作用。`noinline` 是刻意的代码体积决策：源码注释（`src/parser.zig:6961-6962`）说明 leftover candidate39 里还留着一份 757 B 的 CurrentContext 副本，其额外的 null/false/true/await/yield 检查与本函数重复，outline 之后可以合并。五个调用点：`escapedIdentifierIsReservedWordForShorthandBinding`（`:7018`）、`escapedIdentifierIsReservedWordForCurrentContext`（`:7033`）、`identifierLikeHasInvalidEscapeForBinding`（`:7111`）、`parseVar`（`:10554`）、`shorthandPatternTarget`（`:12718`）。

### `atomNameEquals` (`src/parser.zig:6976`)

- **签名**：`fn atomNameEquals(s: *State, atom_id: Atom, name: []const u8) bool`。
- **作用**：比较一个 atom 的名字文本是否等于给定字符串。
- **实现**：
`atoms.name(atom_id)` 取名字后 `std.mem.eql`；atom 查不到名字（如已释放/非法 id）返回 false。
- **所有权 / 错误 / 调用**：无：`atoms.name(atom_id)` 返回的是 AtomTable 内部的**借用**字节切片，当场比较完即弃，不复制、不释放；atom id 本身也只是读。不分配、无 error set，未知 id 返回 `false`。全树 50 处调用（分布在 41 行，全部在 `src/parser.zig` 内），是 parser 里最常用的「名字是不是 eval/arguments/await/of」判定：`defineVar`（`src/parser.zig:1816`）、`isReservedLabelIdentifier`（`:2343`-`:2347`）、`peekNextIsOfToken`（`:2485`）、`getLValue`（`:4359`）等。这是「在 token 生命周期内消费、不算借用外泄」的典型形状。

### `atomsNameEqual` (`src/parser.zig:6980`)

- **签名**：`fn atomsNameEqual(s: *State, left: Atom, right: Atom) bool`。
- **作用**：比较两个 atom 是否指同一个名字（id 不同但文本相同也算相等）。
- **实现**：id 相等直接真；否则两边各取名字再 `std.mem.eql`，任一取不到名字返回 false。
- **所有权 / 错误 / 调用**：无：先比 id 再比名字（两次 `atoms.name` 都是借用切片，不复制不释放），不分配、无 error set。之所以不能只比 id，是因为 eval 种子里的名字可能来自另一次 intern。唯一调用方 `evalAnnexBBlockedFunctionName`（`src/parser.zig:7202`）。

### `evalAnnexBBlockedFunctionName` (`src/parser.zig:6987`)

- **签名**：`fn evalAnnexBBlockedFunctionName(s: *State, atom_id: Atom) bool`。
- **作用**：判断这个函数名是否在 direct eval 传进来的 Annex-B 禁止提升名单里。
- **实现**：线性扫 `s.eval_annex_b_blocked_function_names`，逐个用 `atomsNameEqual` 比名字；名单通常为空，所以是冷路径。
- **所有权 / 错误 / 调用**：无：线性扫 `s.eval_annex_b_blocked_function_names`——那是 `compile` 的 `options` 直接借来的 `[]const Atom`（`src/parser.zig:16235` 写进 `State`），**归调用方所有，parser 不复制也不释放**。不分配、无 error set。唯一调用方 `parseFunctionParamsAndBody`（`:11757`），用于直接 eval 里被外层阻断的 Annex-B 函数提升。

### `atomNameIsPrivate` (`src/parser.zig:6994`)

- **签名**：`fn atomNameIsPrivate(s: *State, atom_id: Atom) bool`。
- **作用**：判断一个 atom 是不是 `#name` 私有名。
- **实现**：
一行 `s.function.atoms.kind(atom_id) == .private`——私有性记在 atom 表的 kind 上，不靠名字前缀判断。
- **所有权 / 错误 / 调用**：无：只问 AtomTable 这个 id 的 kind 是不是 `.private`，不取名字、不分配、无 error set。两个调用方都在 `delete` 的私有名拒绝路径：`finishDelete`（`src/parser.zig:5314`）与 `rewriteOptionalChainDeleteBuilder`（`:5380`）。

## 覆盖核对

- 清单函数数（本文件分到）: 32（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 32
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
