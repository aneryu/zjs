# 03 — parser 语句

`parseProgramStatements` → `parseStatementOrDecl` → 各语句。指令 prologue、块、控制语句、`var`/`for`/`try`/`switch`。


### `parseProgramStatements` (`src/parser.zig:8509`)

- **签名**：`pub fn parseProgramStatements(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：程序体的顶层语句循环。
- **实现**：
先压一层 using 帧（`errdefer restoreUsingBlockFramesAfterError` 在失败时把帧栈与 `active_catch_marker_depth` 还原），然后 `while (peekKind() != TOK_EOF)` 反复 `parseStatementOrDecl`，失败经 `propagateFailureHere` 钉住诊断位置；正常结束再 `finalizeCurrentUsingBlockFrame` 发顶层的 dispose 收尾。
- **所有权 / 错误 / 调用**：唯一持有的资源是 `s.using_block_frames` 上新压的那一帧（用 `s.function.memory.allocator` 扩容），失败由 `errdefer restoreUsingBlockFramesAfterError(s, frame_len, catch_marker_depth)` 连同 `active_catch_marker_depth` 一起回滚；正常路径由 `finalizeCurrentUsingBlockFrame` 消费。语句产生的字节码与 `FunctionDef` 写入不可回滚。错误经 `propagateFailureHere` 钉住位置后上抛 `parser_core.Error`。`pub` 出口，除 `compile` 主路径（`src/parser.zig:16283`）外还被编译器测试直接调用（`src/compiler/test_entry.zig:87`、`src/compiler/tests.zig` 多处）。

### `parseBlockContentsAfterOpen` (`src/parser.zig:8520`)

- **签名**：`fn parseBlockContentsAfterOpen(s: *State) Error!void`。
- **作用**：在已消费 `{` 之后解析块内容，并处理 TypeScript 参数属性与 using 帧。
- **实现**：
若是基类构造器最外层块且有 TypeScript 参数属性，先对每个 atom 发 `push_this; scope_get_var; put_field`（zjs 独有擦除，不是 qjs）。然后压 using 帧，循环 `parseStatementOrDecl` 直到 `}`，`finalizeCurrentUsingBlockFrame`。出错 `restoreUsingBlockFramesAfterError`。
- **所有权 / 错误 / 调用**：与 `parseProgramStatements` 同一套 using 帧协议：压帧 → `errdefer restoreUsingBlockFramesAfterError(s, frame_len, catch_marker_depth)` → 正常路径 `finalizeCurrentUsingBlockFrame`。TypeScript 参数属性那段会把 `s.is_outer_constructor_block` 置回 `false`（一次性消费，不恢复），读的是 `s.current_parameter_properties` 里借来的 atom id，不 retain、也不负责释放（那份列表归 `parseFunctionDecl` / `parseClassElementFunction` 的 `defer`）。本函数**自己吃掉收尾的 `}`**，但不管 `{`（由调用方 `parseBlock` / `parseFunctionBodyBlock` 消费）。错误：缺 `}` 经 `expectToken` 折成 `error.UnexpectedToken`，其余由 `parseStatementOrDecl` 上抛。两个调用方：`parseBlock`（`src/parser.zig:8558`）与 `parseFunctionBodyBlock`（`:8570`）。

### `parseBlock` (`src/parser.zig:8549`)

- **签名**：`pub fn parseBlock(s: *State) Error!void`。
- **作用**：解析普通的块语句 `{ ... }`（空块不开作用域，也不识别 directive prologue）。
- **实现**：对照 QuickJS `js_parse_block`：空的普通块**不**分配词法作用域，并且块里不识别 directive prologue（那是函数体 `parseFunctionBodyBlock` 的事）。非空块才 `pushScope` → `parseBlockContentsAfterOpen` → `popScope`，失败时 `errdefer popScopeIdentity`。
- **所有权 / 错误 / 调用**：不分配堆内存；唯一需要配对的是作用域——`pushScope` 发 `enter_scope` 并切 `scope_level`，正常路径 `popScope`（发 `leave_scope` 并还原），错误路径只 `popScopeIdentity`（只还 `scope_level`，不补 `leave_scope`，因为整个 `FunctionDef` 随后会被丢弃）。空块的早退路径在 `pushScope` 之前，所以既不留作用域也不发码。四个调用方：`parseBlockStatement`（`src/parser.zig:9029`）、`parseTryStatement` 的 try/catch 块（`:9779` / `:9852`）、`parseSharedFinallyBlock`（`:10154`）。

### `parseFunctionBodyBlock` (`src/parser.zig:8565`)

- **签名**：`fn parseFunctionBodyBlock(s: *State) Error!void`。
- **作用**：解析函数体的 `{ ... }`：体作用域与 directive prologue 属于 FunctionBody 产生式，与普通块不同。
- **实现**：
对照 QuickJS `js_parse_function_decl2` 里与普通块不同的函数体路径：体作用域与 directive 属于 FormalParameters/FunctionBody 产生式，而不是普通块。顺序是 `expectToken('{')` → `beginFunctionBody()` → `parseDirectives` → `parseBlockContentsAfterOpen`（后者自己吃掉 `}`）。
- **所有权 / 错误 / 调用**：不分配；`beginFunctionBody` 开的那层体作用域只有 `errdefer s.popScopeIdentity()` 兜底，**正常路径不 pop**——函数体作用域由 `parseFunctionParamsAndBody` 的收尾（`popFunction`）连同整个子 `FunctionDef` 一起带走。与 `parseBlock` 的另一个区别是空体也照样开作用域。两个调用方：`parseFunctionParamsAndBody`（`src/parser.zig:11948`）与 `parseArrowFunction` 的块体臂（`:12476`）。

### `parseDirectives` (`src/parser.zig:8575`)

- **签名**：`pub fn parseDirectives(s: *State) Error!void`。
- **作用**：解析函数 / 文件开头的指令序言，只认 `"use strict"` 并据此改写严格模式状态。
- **实现**：
对照 `js_parse_directives`（`quickjs.c:35642`）。只在文件/函数体开头连续字符串语句中认 `"use strict"`（无转义、恰好 10 字节）。若此前 directive 含 legacy escape 则失败。命中后设 `is_strict` / lexer strict / `has_use_strict`。completion 模式把字符串写入 `<ret>`。无 `;` 且无 ASI 则不是 directive，停。
- **所有权 / 错误 / 调用**：不分配；`str_payload.bytes` 是当前 token 借来的切片，只活到下一次 `advance`，所以 `emitStringLiteralValue` 必须在 `advance` 之前发出。写进 `State` / `FunctionDef` 的四个严格标志（`has_use_strict`、`s.is_strict`、`curFunc().is_strict_mode`、`s.lex.is_strict_mode`）是**有意不恢复**的持久副作用，由外层的 `saved_is_strict` / `saved_lex_is_strict` 在函数边界还原。唯一的自有错误是 legacy 八进制转义与 `"use strict"` 同现时的 `failUnexpectedToken`。`pub` 出口：`parseFunctionBodyBlock`（`src/parser.zig:8569`）、`compile` 的程序入口（`:16264`），以及解析器测试（`src/tests/parser.zig:916` / `:13614`）。

### `stringLiteralStatementHasDirectiveTerminator` (`src/parser.zig:8616`)

- **签名**：`fn stringLiteralStatementHasDirectiveTerminator(s: *const State) bool`。
- **作用**：判断一条字符串字面量语句后面是否真的到此结束（即它可以当 directive），而不是某个更长表达式的开头。
- **实现**：从当前 token 结束偏移起**直接扫源字节**（不动词法器）：`;` / `}` 为真；行终结符则交给 `lineTerminatorContinuesStringLiteralExpression` 判断下一行会不会用 `in` / `instanceof` 续上；空白跳过；`//` 为真；`/* */` 跳过并在其中含换行时为真；其余字符（说明后面还跟着运算符等）为假；扫到源尾为真。
- **所有权 / 错误 / 调用**：无：`*const State` 上的**只读源码字节前瞻**——从当前 token 末尾直接扫 `s.lex.source`（借用切片，归 `compile` 的调用方所有），不动 lexer 光标、不取 token、不分配、无 error set。它刻意绕开 lexer 是因为指令序言的判定必须在还没决定 ASI 之前完成。唯一调用方 `parseDirectives`（`src/parser.zig:8580`）。

### `lineTerminatorContinuesStringLiteralExpression` (`src/parser.zig:8649`)

- **签名**：`fn lineTerminatorContinuesStringLiteralExpression(source: []const u8, start: usize) bool`。
- **作用**：换行之后是不是 `in` / `instanceof`——这两个算子会把前面的字符串续成一个表达式，从而否掉 directive 判定。
- **实现**：从 `start` 起跳过空白与换行、跳过 `/* */` 块注释（遇到 `//` 行注释或不成对注释直接返回 false），停在第一个实质字符上，再用 `startsKeywordAt` 判断它是不是完整的 `in` 或 `instanceof`。
- **所有权 / 错误 / 调用**：无：连 `State` 都不接，只吃借来的 `source` 切片做字节扫描，不分配、无 error set、无副作用。唯一调用方 `stringLiteralStatementHasDirectiveTerminator`（`src/parser.zig:8622`），用来把 `"use strict"\n in x` 这种「换行后跟 `in`/`instanceof`」排除出指令。

### `startsKeywordAt` (`src/parser.zig:8669`)

- **签名**：`fn startsKeywordAt(source: []const u8, index: usize, keyword: []const u8) bool`。
- **作用**：源字节层面的完整关键字匹配（不能是更长标识符的前缀）。
- **实现**：先查长度与 `std.mem.eql`，再要求紧随其后的字节不是标识符续接字符（到源尾也算匹配）。
- **所有权 / 错误 / 调用**：无：三个参数全是借用/标量，纯字节比较 + 词边界检查，不分配、无 error set。唯一调用方 `lineTerminatorContinuesStringLiteralExpression`（`src/parser.zig:8666`，两次，分别试 `in` 与 `instanceof`）。

### `isAsciiIdentifierContinue` (`src/parser.zig:8676`)

- **签名**：`fn isAsciiIdentifierContinue(c: u8) bool`。
- **作用**：谓词：这个 ASCII 字节能否出现在标识符中间。
- **实现**：
一行转调 `unicode.isAsciiIdentifierPartByte(c)`，让源字节级的扫描复用词法器同一份表。
- **所有权 / 错误 / 调用**：无：单行转发 `unicode.isAsciiIdentifierPartByte`，不分配、无 error set。唯一调用方 `startsKeywordAt`（`src/parser.zig:8673`）。

### `emitStringLiteralValue` (`src/parser.zig:8680`)

- **签名**：`fn emitStringLiteralValue(s: *State, bytes: []const u8) Error!void`。
- **作用**：把一段字符串字面量的字节发成一条常量压栈指令（模板拼接、`case` 串等共用）。
- **实现**：先 `internString(bytes)` 取 atom。对照 `emit_push_const(as_atom = true)`（`quickjs.c:23974-24004`），普通字符串 atom 直接发 `push_atom_value`；但规范数字名会被 intern 成 tagged-int atom，压 atom 值就丢了字符串身份，因此这种情况在有 runtime 时改成 `String.createUtf8` 新建字符串再 `pushConstOwned` 进常量池。没有 runtime 的解析片段（如标签模板的测试路径）不能拥有 JSValue，仍退回 atom 形态。建串的 `OutOfMemory` / `StringTooLong` 折成 `Error.OutOfMemory`，`InvalidUtf8` 原样上抛。
- **所有权 / 错误 / 调用**：两条臂的所有权不同：普通字符串走 `atoms.internString` 得到一个 id 再 `Emitter.opAtom` 写进 Builder 的 atom 流——只是 id，不 retain，由 `CompileAtomScope` 作根；**tagged-int（规范数字名）且有 runtime 时**改造一个真 GC `String` 并经 `Emitter.pushConstOwned` 把所有权交给 `curFunc().cpool`（编译期间由 `traceCompileValueRoots` 保活，最终进 FB）。没有 runtime 的解析器专用 `State` 落回 atom-only 那条臂，不造 JSValue。错误：`internString` 的 `OutOfMemory`、`String.createUtf8` 的 `OutOfMemory`/`StringTooLong` → `Error.OutOfMemory` 与 `InvalidUtf8`，以及 Builder 经 `mapBuilderError` 折出的错误。5 个调用方：`parsePrimary`（`src/parser.zig:6253`）、`parseTemplate`（`:6462`）、`parseDirectives`（`:8598`）、`parseEnumDeclaration`（`:8751`/`:8795`）。

### `parseStatementOrDecl` (`src/parser.zig:8929`)

- **签名**：`pub fn parseStatementOrDecl(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：语句与声明的分发入口：`function` / `async function` 单独走，其余交慢路径。
- **实现**：
对照 `js_parse_statement_or_decl`（`quickjs.c:28228`）。`function` / `async function`（无换行）单独处理，避免 Debug 下巨型 switch 撑爆 native 栈。其余进 `parseStatementOrDeclSlow`。`DeclMask` 关掉时函数声明 unexpected。
- **所有权 / 错误 / 调用**：不分配、不保存状态，只做分派；三条出口（两条 `parseFunctionDecl` 与 `parseStatementOrDeclSlow`）都用 `catch |err| return s.propagateFailureHere(err)` 把诊断位置钉在本语句开头，而不是让内层的位置一路冒出来。`pub` 出口，递归调用点遍布各语句解析器（块体、标签语句、`if`/循环体等），本身不持有任何需要释放的资源。

### `parseStatementOrDeclSlow` (`src/parser.zig:8956`)

- **签名**：`fn parseStatementOrDeclSlow(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：语句与声明的主分发：先处理带标签的语句，再按首 token 分派到各语句解析器。
- **实现**：
先看标签：`ident:` 且非保留字、非重复。循环类语句把 atom 放进 `pending_label_atom`；其它语句 `pushLabelFrame` + `pushControlBlock`（不允许 labelled class / generator / async function）。然后按 token 分发 block/string/enum/return/throw/var/function/class/ident/await/import/export/if/while/with/do/for/break/continue/switch/try/debugger/`;`/表达式。
- **所有权 / 错误 / 调用**：标签路径是唯一有资源的一段，用三层配对守住：`label_atom` 由 `labelStartAtomOwned` 取出后由本地变量持有，跨过 `advance` 与整条被标签语句（`LabelFrame` 有意**不**持有 atom）；`pushLabelFrame` 配 `errdefer s.popLabelFrame(label_frame)`，正常路径在 `patchLabelBreaks` 之后手工 pop；`pushControlBlock` 配 `label_block_active` + `defer popControlBlock`，正常路径同样提前手工 pop 并清标志。循环类语句（`while`/`do`/`for`/`switch`）不建这两层，而是把 atom 放进 `pending_label_atom` 并用 `defer` 还原，由语句自身建帧。错误：保留字作标签、重复标签、被标签的 class / generator / async function 都经 `failUnexpectedToken`。唯一调用方 `parseStatementOrDecl`（`src/parser.zig:8953`）。

### `parseBlockStatement` (`src/parser.zig:9028`)

- **签名**：`fn parseBlockStatement(s: *State) Error!void`。
- **作用**：语句位置上的块。
- **实现**：
一行转调 `parseBlock`；分出这一层只是让语句分发表的每个臂都是同一形状的调用。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有任何资源，错误原样由 `parseBlock` 上抛。唯一调用方是 `parseStatementOrDeclSlow` 的 `'{'` 臂（`src/parser.zig:9028` 附近的分发表）。

### `parseStringStatement` (`src/parser.zig:9032`)

- **签名**：`fn parseStringStatement(s: *State) Error!void`。
- **作用**：处理以字符串字面量打头的表达式语句（指令 prologue 之后的 `"...";`）。
- **实现**：与普通表达式语句同形：`expressionStatementKeepsCompletion`（有 `<ret>` 槽且不是 module）决定结果留不留；先 `emitGrammarSource` 钉住语句首行列，再 `parseExpr2(in_accepted = true, result_needed = keep_completion)`，`expectSemicolon` 处理 ASI；留结果时 `emitEvalRetPut` 写进 `<ret>`，否则发一条不带源事件的 `drop`。真正的 `"use strict"` 指令早已被 `parseDirectives` 吃掉，能走到这里的字符串只是普通表达式。
- **所有权 / 错误 / 调用**：不分配、不保存状态；`expressionStatementKeepsCompletion`（`src/parser.zig:7914`：`eval_ret_idx >= 0 且非模块`）只是读判定。栈平衡由两条臂各自兜底：留结果走 `emitEvalRetPut`，否则 `drop`——两者都消费 `parseExpr2` 压上的那一个值。错误来自 `parseExpr2` 与 `expectSemicolon`（ASI 失败即 `error.UnexpectedToken`）。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_STRING` 臂。

### `parseReturnStatement` (`src/parser.zig:9054`)

- **签名**：`fn parseReturnStatement(s: *State) Error!void`。
- **作用**：解析 `return [expr];`，连同 finally / 迭代器的退出清理一起降级。
- **实现**：先判合法性：eval 根或 `return_depth == 0` 时 `return` 非法。吃掉关键字后按「下一枚不是 `;` / `}` 且中间没有换行」确定有没有返回值（ASI 规则），有就 `parseExpr`。随后 `takeEmissionSnapshot` + `errdefer rollbackEmission`，保证后续发射失败不留半条 return。`reattributeReturnTailCallSource` 把尾调用的源事件改挂到 `return` 关键字上（对齐 qjs `resolve_labels` 对 `call ; OP_line_num ; return` 的归属），失败时用 `errdefer restoreSourceLoc` 回滚该标记。最后 `emitGrammarSource(关键字位置)` + `emitParsedReturn`——qjs 同样是在整个 `emit_return` 降级（含 async / finally 清理）之前只发一条关键字源事件；收尾 `expectSemicolon`。
- **所有权 / 错误 / 调用**：不分配堆内存，但有两层**可回滚的发射状态**：`takeEmissionSnapshot` / `errdefer rollbackEmission`（`src/parser.zig:2818` / `:2837`）保证 `emitParsedReturn` 途中失败不留半条 return；`reattributeReturnTailCallSource` 改写过的源位置由 `errdefer restoreSourceLoc`（`:10206`）还原。表达式本身发的码在快照之前，不在回滚范围内——那部分失败时整个 `FunctionDef` 会被丢弃。错误：`is_eval` 或 `return_depth == 0` 时 `failUnexpectedToken`，其余来自 `parseExpr` / `expectSemicolon` / emit。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_RETURN` 臂。

### `parseThrowStatement` (`src/parser.zig:9074`)

- **签名**：`fn parseThrowStatement(s: *State) Error!void`。
- **作用**：解析 `throw expr;`。
- **实现**：记下关键字行列后 `advance`；`throw` 与表达式之间不允许换行（ASI 限制），`gotLineTerminator` 即 `failUnexpectedToken`。`parseExpr` 把值留在栈上后取 emission 快照并 `errdefer rollbackEmission`，再 `emitGrammarSource(关键字位置)` + 一条自身不带源事件的 `throw`——与 `quickjs.c:28984-28997` 中 `TOK_THROW` 紧贴关键字源事件发 `OP_throw` 的顺序一致；最后 `expectSemicolon`。
- **所有权 / 错误 / 调用**：不分配；`takeEmissionSnapshot` + `errdefer rollbackEmission` 只覆盖「源事件 + `throw`」这两步，表达式的码在快照之前。`parseExpr` 压上的值由 `throw` 消费，栈自平衡。错误：`throw` 与表达式间有换行即 `failUnexpectedToken`（ASI 限制），其余来自 `parseExpr` / `expectSemicolon`。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_THROW` 臂。

### `parseVariableStatement` (`src/parser.zig:9091`)

- **签名**：`fn parseVariableStatement(s: *State, tok_kind: tok.TokenKind, decl_mask: DeclMask) Error!void`。
- **作用**：分派 `var` / `let` / `const` 打头的语句，含 sloppy 模式下 `let` 其实只是标识符、以及 TypeScript `const enum` 两处改道。
- **实现**：三道前置改道：sloppy 模式下 `canTreatLetAsExpressionStatement` 判定这个 `let` 只是标识符引用时转 `parseLetKeywordExpressionStatement`；TypeScript 源里 `const enum` 吃掉 `const` 后转 `parseEnumDeclaration`；`decl_mask.other` 为假的位置（如 `if (x) let y = 1;`）不允许词法声明，`let` / `const` 报 `failUnexpectedToken`，`var` 仍放行。其余情况吃掉声明关键字，交 `parseVar(var_tok, false, ParseFlags.default)` 解析声明列表，收尾 `expectSemicolon`。
- **所有权 / 错误 / 调用**：自身不分配、不保存状态，只做三次改道再转发；`decl_mask` 按值传入。`canTreatLetAsExpressionStatement` 里的前瞻由它自己用 `takeLexerCursorSnapshot` / `defer restoreLexerCursorSnapshot` 复位，本函数看到的 token 流不变。错误只有一处自有的 `failUnexpectedToken`（`decl_mask.other` 为假时的 `let`/`const`），其余由 `parseVar` / `parseEnumDeclaration` / `expectSemicolon` 上抛。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_VAR/TOK_LET/TOK_CONST` 臂。

### `parseFunctionDeclarationStatement` (`src/parser.zig:9110`)

- **签名**：`fn parseFunctionDeclarationStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：语句位置上的 `function` 声明。
- **实现**：先按 `decl_mask` 判位置：既不允许普通函数声明（`func`）也不允许带标签的函数声明（`func_with_label`）就 `failUnexpectedToken`。随后 `currentFunctionSourceStart` 记下函数源码起点（`Function.prototype.toString` 要用），以 `.normal` 种类交 `parseFunctionDecl`。函数里保留了一条 `isIdent("async")` 分支，但本函数只从 `TOK_FUNCTION` 的分派臂进入，而 `isIdent` 要求当前 token 是 `TOK_IDENT`，所以该分支恒不成立——`async function` 声明实际由 `parseIdentifierStatement` 处理。
- **所有权 / 错误 / 调用**：不分配、不持有资源；`source_start` 只是一组行列/偏移标量，透传给 `parseFunctionDecl` 供 `Function.prototype.toString` 截源。声明产生的绑定与子 `FunctionDef` 全归 `parseFunctionParamsAndBody` 记账。唯一自有错误是 `decl_mask` 不允许时的 `failUnexpectedToken`。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_FUNCTION` 臂（注意快路径里 `parseStatementOrDecl` 已经先截走了绝大多数 `function` 声明）。

### `parseClassDeclarationStatement` (`src/parser.zig:9124`)

- **签名**：`fn parseClassDeclarationStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：语句位置上的 `class` 声明。
- **实现**：`decl_mask.func` 为假的位置（如 `if (x) class C {}`）即 `failUnexpectedToken`。否则 `parseClass(s, true)` 按声明形态解析；它返回 `null` 表示匿名类，在声明位置不合法，同样 `failUnexpectedToken`。返回的类名 atom 这里用不到（绑定已由 `parseClass` 建好），显式丢弃。
- **所有权 / 错误 / 调用**：`parseClass(s, true)` 返回的是**移交过来的类名 atom**，本函数用 `_ = name_atom;` 显式丢弃——编译期 atom 由 `CompileAtomScope` 作根，所以丢弃不泄漏；类的绑定与字节码都已在 `parseClass` 内落定。两处 `failUnexpectedToken`：位置不允许声明、以及 `parseClass` 返回 `null`（声明形态下不应发生）。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_CLASS` 臂。

### `parseIdentifierStatement` (`src/parser.zig:9132`)

- **签名**：`fn parseIdentifierStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：当前 token 是普通标识符时的语句分派：TypeScript `namespace`、`using` 声明、`async function` 声明，都不是就当表达式语句。
- **实现**：四条臂按序试：(1) TypeScript 源里 `namespace Ident` → `parseNamespaceDeclaration`；(2) `usingDeclarationStart` 认出 `using x = …` → 要求 `decl_mask.other`，走 `parseUsingDeclaration(.sync)` 再 `expectSemicolon`；(3) `async` 后同一行紧跟 `function`（`peekNextKindNoLineTerminator`，换行会让 ASI 把它退化成表达式）→ 校验 `decl_mask.func` / `func_with_label`，记源码起点、吃掉 `async`、交 `parseFunctionDecl(.async)`；(4) 其余落到与 `parseExpressionStatement` 同形的尾巴：`emitGrammarSource` → `parseExpr2` → `expectSemicolon` → eval 模式 `emitEvalRetPut`、否则 `drop`。
- **所有权 / 错误 / 调用**：不分配、不保存状态；`usingDeclarationStart` / `awaitUsingDeclarationStart` / `peekNextKindNoLineTerminator` 都是自复位的前瞻。表达式臂的栈由 `emitEvalRetPut` 或 `drop` 平衡。自有错误是三处 `decl_mask` 不满足时的 `failUnexpectedToken`，其余由被转发的解析器上抛。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_IDENT` 臂——注意分派顺序有意义：`namespace` 在 `using` 之前、`using` 在 `async function` 之前，最后才落到表达式。

### `parseAwaitStatement` (`src/parser.zig:9171`)

- **签名**：`fn parseAwaitStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：当前 token 是 `await` 时的语句分派：`await using x = …` 声明，否则是以 `await` 打头的表达式语句。
- **实现**：`awaitUsingDeclarationStart` 认出 `await using` 形态时要求 `decl_mask.other`，走 `parseUsingDeclaration(.async)`（`await` 由它自己吃掉）再 `expectSemicolon` 返回。否则与 `parseExpressionStatement` 同形：`emitGrammarSource` 钉住语句首位置、`parseExpr2(in_accepted = true, result_needed = keep_completion)`、`expectSemicolon`，eval 模式 `emitEvalRetPut`、否则 `drop`；`await` 本身在此上下文是否合法由表达式层的 `in_async` 检查负责。
- **所有权 / 错误 / 调用**：不分配、不保存状态；`awaitUsingDeclarationStart` 自复位前瞻。表达式臂的值由 `emitEvalRetPut` 或 `drop` 消费。自有错误只有 `await using` 出现在不允许声明的位置时的 `failUnexpectedToken`；`await` 本身在同步上下文里的非法性由表达式层（`in_async` / 模块顶层规则）报出，不在这里。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_AWAIT` 臂。

### `parseImportStatement` (`src/parser.zig:9192`)

- **签名**：`fn parseImportStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：`import` 打头的语句：`import(...)` 动态导入与 `import.meta` 按表达式走，其余是模块声明。
- **实现**：先 peek 下一枚 token：`(` 或 `.` 说明这是动态 `import()` 或 `import.meta` 表达式，按表达式语句那套处理（源事件 → `parseExpr2` → `expectSemicolon` → 写 `<ret>` 或 `drop`）后返回。否则必须同时满足 `decl_mask.other` 与 `canParseModuleDeclarationHere`（`lex.is_module` 且处于程序体作用域），不满足即 `failUnexpectedToken`；满足则整段交 `parseImport` 解析 import 子句与模块说明符。
- **所有权 / 错误 / 调用**：不分配、不保存状态；只用一次 `peekNextKind` 决定走表达式还是模块声明。表达式臂的值由 `emitEvalRetPut` 或 `drop` 消费；声明臂把模块记录的写入全交给 `parseImport`（它会往 `FunctionDef` / 模块表里追加不可回滚的条目）。自有错误是位置不合法时的 `failUnexpectedToken`（`canParseModuleDeclarationHere`，`src/parser.zig:9978`）。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_IMPORT` 臂。

### `parseExportStatement` (`src/parser.zig:9215`)

- **签名**：`fn parseExportStatement(s: *State, decl_mask: DeclMask) Error!void`。
- **作用**：`export` 打头的模块声明。
- **实现**：唯一的检查是 `decl_mask.other` 且 `canParseModuleDeclarationHere`（`lex.is_module` 且在程序体作用域）：任何嵌套位置，或 script / eval 源里出现 `export`，一律 `failUnexpectedToken`；通过后整段交 `parseExport`。与 `import` 不同，`export` 没有任何表达式形态，所以没有改道臂。
- **所有权 / 错误 / 调用**：不分配、不持有资源，只做一次位置校验再转发；导出名登记等持久副作用全在 `parseExport` 里。自有错误只有 `failUnexpectedToken`（非模块源或非程序体作用域）。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_EXPORT` 臂。

### `parseIfStatement` (`src/parser.zig:9222`)

- **签名**：`fn parseIfStatement(s: *State) Error!void`。
- **作用**：解析 if/else，并处理 Annex B 单语句函数声明。
- **实现**：
整个 IfStatement 一个 wrapper scope（Annex B then/else 函数共享）。求值条件，`if_false` 跳过 then。松散模式且 then/else 是非生成器 `function` 时设 `annex_b_if_function_decl_clause` 并允许 `DeclMask.func`。有 else 则 then 末 `goto` 过 else。最后 `popScope`。
- **所有权 / 错误 / 调用**：不分配堆内存。两类需要配对的状态：wrapper 作用域（`pushScope` → 正常路径 `popScope`，失败路径 `errdefer s.popScopeIdentity()`）与 `annex_b_if_function_decl_clause`（`defer` 兜底，且 then / else 两支各自在解析完后立刻手工还原，使 else 的判定不受 then 的影响）。`Label` 是栈上的值，由 `Emitter.newLabel` 登记进 Builder、`bind` 消费；本函数保证每条 `if_false` / `goto` 都恰好绑定一次。无自有错误分支，全部来自 `expectToken` / `parseExpr2` / `parseStatementOrDecl`。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_IF` 臂。

### `parseDoOrWhileStatement` (`src/parser.zig:9279`)

- **签名**：`noinline fn parseDoOrWhileStatement(s: *State, is_do: bool) Error!void`。
- **作用**：do/while 共用解析：pending label、eval-undef、循环顶绑定、break/label 帧、控制块、body、continue 补丁、条件回边。comptime 身份只剩「先测还是先体」。
- **实现**：`advance` 吃 `do`/`while`，收下 `pending_label_atom`，`setEvalReturnUndefined`。`while` 先 `expectToken('(')`。新建并绑定 `loop_top`（qjs：`TOK_WHILE` 的 `label_cont` 绑在测试处，回边是 `goto`；`TOK_DO` 的 `label1` 绑在 body，回边是 `if_true`）。`while`：`parseExpr`、新建 `exit_label`、`if_false` 跳出、`expectToken(')')`。然后 `pushBreakFrame`、可选 `pushLabelFrame`、`pushControlBlock`（可 break/continue）。`parseStatementOrDecl` 吃 body，`patchContinueFrame`，有 label 再 `patchLabelContinues`。`do`：`while (` expr `)`，`if_true` 回 `loop_top`，可选分号。`while`：`goto` 回 `loop_top` 并绑定 `exit_label`。最后 pop 控制块、`popBreakFrameAndPatch`、补 label break 并 pop。`parseWhileStatement` / `parseDoStatement` 是只传旗标的 inline 包装（knives 94/98）。
- **所有权 / 错误 / 调用**：不分配堆内存，但同时握着四层需要配对的解析器状态：`pending_label_atom`（进门就取走并置 `null`，**不恢复**——它本就是「传给下一条循环语句」的一次性槽）、`pushBreakFrame` / `popBreakFrameAndPatch`、可选的 `pushLabelFrame` / `patchLabelBreaks` + `popLabelFrame`、以及 `pushControlBlock`（唯一带 `defer` 兜底的一层：`loop_block_active` 标志 + `defer popControlBlock`，正常路径提前手工 pop 并清标志）。break/label 两层**没有 errdefer**，错误路径靠上层丢弃整个 `FunctionDef` 收场。`Label` 值在栈上，`loop_top` 用 `bindTarget` 先绑再被回边引用，`exit_label` 只在 `while` 臂使用。错误全部来自 `expectToken` / `parseExpr` / `parseStatementOrDecl` 与 emit。两个调用方都是 `inline` 包装：`parseWhileStatement`（`src/parser.zig:9327`）与 `parseDoStatement`（`:9335`）。

### `parseWhileStatement` (`src/parser.zig:9327`)

- **签名**：`inline fn parseWhileStatement(s: *State) Error!void`。
- **作用**：`while` 语句。
- **实现**：
`inline` 包装，一行 `parseDoOrWhileStatement(s, false)`。被调方是 `noinline` 且 `is_do` 是**普通运行时参数**（源码注释里写明「Take that at runtime」），所以这里选中的「先测试后循环体」是运行时分支，不是 comptime 特化；拆出包装只是让语句分派表保持同一形状。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有资源，错误原样上抛。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_WHILE` 臂。

### `parseWithStatement` (`src/parser.zig:9331`)

- **签名**：`fn parseWithStatement(s: *State) Error!void`。
- **作用**：`with` 语句。
- **实现**：
一行转调 `parseWith`（真正的实现，含严格模式拒绝）。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有资源；`with` 作用域的进出与严格模式报错都在 `parseWith`（`src/parser.zig:10701`）里。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_WITH` 臂。

### `parseDoStatement` (`src/parser.zig:9335`)

- **签名**：`inline fn parseDoStatement(s: *State) Error!void`。
- **作用**：`do ... while` 语句。
- **实现**：
`inline` 包装，一行 `parseDoOrWhileStatement(s, true)`，选中「先循环体、回边用 `if_true`」的那条路径；与 `parseWhileStatement` 一样，`is_do` 是运行时参数而非 comptime 特化。
- **所有权 / 错误 / 调用**：纯转发，不分配、不持有资源，错误原样上抛。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_DO` 臂。

### `parseForStatement` (`src/parser.zig:9339`)

- **签名**：`fn parseForStatement(s: *State) Error!void`。
- **作用**：解析 `for` 语句：区分 C 风格三段头与 for-in/of，并搭出 continue / break 标签与逐轮词法作用域。
- **实现**：
消费 `for`。`for await (` 要求 async，转 `parseForInOf(true)`。否则用 `forHeadHasNoTopLevelSemicolon`：无顶层 `;` 就是 for-in/of。

C 风格 `for (init; test; update)`：先 `pushScope`（即使 init 为空或非词法也开，对齐 QuickJS）。init 四选一——`using` / `await using`（开一层 using 帧后 `parseUsingDeclaration`）、`var`/`let`/`const`（`let` 还要过 `canTreatLetAsForInitializerExpression` 排除「`let` 只是标识符」）、普通表达式（求值后 `drop`）、或空；非空 init 之后 `closeScopes` 回到块层级。接着绑 `top_label`（用 `emitterBindParserLabel`，保留 legacy 的物理 `OP_label` 语义以维持 Stage-4 顺序匹配屏障），发测试（省略测试时压 `push_true`），再建 `exit_label` + `if_false`。**update 的处理是本函数的核心手法**：它在括号里就地解析并发码，随后用 `emitterDetachTail` 从 Builder 尾部整段摘下（并 `emitterDiscardDetachedSources` 丢掉带外源槽），等 body、`closeScopes`、`patchContinueFrame` / `patchLabelContinues` 都做完之后，再 `emitterSpliceSegment` 接回去——于是 `continue` 落点自然位于 update 之前，而源码顺序与 LabelId 都不受影响（空 update 不摘任何东西，保持字节形状）。body 之前照例 `pushBreakFrame` + 可选 `pushLabelFrame` + `pushControlBlock`，之后 `goto top_label`、绑 `exit_label`、依次 pop 控制块 / break 帧 / label 帧，最后 `finalizeCurrentUsingBlockFrame` 与 `popScope`。
- **所有权 / 错误 / 调用**：这是本册里状态最多的一个函数。`errdefer` 只覆盖前半段（`for_using_frame_active` → `restoreUsingBlockFramesAfterError`、`for_scope_pushed` → `popScopeIdentity`，以及 Builder 的 `snapshot` / `rollback`），后半段的 break 帧、label 帧、控制块与 `parseDoOrWhileStatement` 一样只有控制块带 `defer`，其余错误路径靠上层丢弃整个 `FunctionDef`。`update_seg` 这段摘下来的字节码由 `defer s.activeBuilder().discardSegment(&update_seg)` 兜底，正常路径被 `emitterSpliceSegment` 消费。`emit_lexical_tdz_at_decl` 在 `let`/`const` 头期间被临时置起并 `defer` 还原。`pending_label_atom` 先取走再在两条 for-in/of 改道前写回，供被调方建帧。错误：`for await` 出现在非 async 里直接 `Error.AwaitOutsideAsyncFunction`（不走诊断），其余来自 `expectToken` / 各子解析器 / emit。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_FOR` 臂。

### `parseBreakOrContinueStatement` (`src/parser.zig:9524`)

- **签名**：`fn parseBreakOrContinueStatement(s: *State) Error!void`。
- **作用**：解析 `break` / `continue`（带或不带标签），发出跨作用域清理之后的跳转。
- **实现**：用当前 token 区分 break 还是 continue 后 `advance`。只有同一行紧跟标识符类 token 才认标签（`gotLineTerminator` 后按 ASI 视为无标签）；标签名若是带转义写法的保留字则 `failUnexpectedToken`。标签 atom 在 `advance` 释放 token 后仍要当查找键，所以先存进局部变量再消耗 token。`expectSemicolon` 之后分两路：有标签走 `emitLabelledBreak` / `emitLabelledContinue` 按名字找标签帧；无标签先确认确有可用帧（`break_frame_lens` / `continue_frame_lens` 非空），否则 `failUnexpectedToken`，再 `emitUnlabelledBreak` / `emitUnlabelledContinue`。
- **所有权 / 错误 / 调用**：不分配；`label_atom` 只是个借用 id，但必须在 `advance()` 之前取出（token 在 `advance` 时释放），并一直留到跳转发出为止——源码注释把这条约束写在取值处。跨作用域的清理（`leave_scope`、迭代器关闭、using dispose）由 `emitLabelledBreak` 等四个发射器按帧计算，本函数不参与。三处 `failUnexpectedToken`：带转义的保留字标签、没有可用 break 帧、没有可用 continue 帧。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_BREAK` / `TOK_CONTINUE` 臂。

### `parseSwitchStatement` (`src/parser.zig:9554`)

- **签名**：`fn parseSwitchStatement(s: *State) Error!void`。
- **作用**：解析 `switch` 语句：求值 discriminant，在独立的 CaseBlock 作用域里排比较链与贯穿。
- **实现**：
`switch (expr) { case/default }`。吃掉 `switch` 后收走 `pending_label_atom`，求值 discriminant 并把它留在栈上直到收尾；`{` 之后 `pushScope` 建 CaseBlock 的独立词法作用域并置 `in_switch_case_block_scope`（`defer` 还原）。控制结构三件套：`pushBreakOnlyFrame`（switch 只截 `break` 不截 `continue`）+ `setCurrentBreakCrossCleanupDrops(1)`（跨出时要多丢一个 discriminant）+ `enterSwitchContinueCleanup`（`defer leave…`），再加可选 `pushLabelFrame` 与 `pushControlBlock`。主循环按子句走：`case` 先把上一轮攒下的「未命中」标签全部绑到这里，再发 `dup ; <case 表达式> ; strict_eq ; if_false → 新的未命中标签`，命中后原地解析子句体（体里用的是完整 `DeclMask`，因为 case 子句不是独立 Block，声明属于整个 CaseBlock）；子句末尾用 `caseTailCanFallthrough` 扫这段发射流判断能否贯穿，能就发一条 `goto` 到下一子句的 fallthrough 标签（而不是隐式 break）。`default` 至多一个（重复即报错），它在没有任何未命中出口时先补一条 `goto` 占位，并**急切地**在体首绑一个候选标签；体为空且后面还有 `case` 时把 `default` 的落点推迟到下一个有体的子句。`}` 之后收口：有 `default` 就用 `emitterRetargetLabel` 把所有未命中标签**改指**到 default 的身份上（v2 不允许改写跳转 PC，所以移的是引用而非目标），没有 default 就把它们直接绑到公共出口。最后绑残留的 fallthrough 标签、pop 控制块 / break 帧 / label 帧，发一条 `drop` 丢掉 discriminant，`popScope`。
- **所有权 / 错误 / 调用**：未命中标签存在一个**栈上定长数组** `no_match_labels[64]`，超过即 `Error.ParserInvariant`（不是用户级 SyntaxError，等于对单个 switch 的 case 数设了 64 的硬上限）。作用域用 `pushScope` + `errdefer popScopeIdentity`，控制块用 `switch_block_active` + `defer`，`in_switch_case_block_scope` 与 switch-continue 清理用 `defer`；break 帧与 label 帧没有 errdefer，错误路径靠上层丢弃 `FunctionDef`。栈平衡：discriminant 从 `parseExpr` 压入一直活到收尾的 `drop`，因此所有跨出 switch 的 `break` 都要靠 `setCurrentBreakCrossCleanupDrops(s, 1)` 多丢一个。错误：重复 `default`、子句位置出现非 `case`/`default` 的 token 都是 `failUnexpectedToken`。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_SWITCH` 臂。

### `parseTryStatement` (`src/parser.zig:9750`)

- **签名**：`fn parseTryStatement(s: *State) Error!void`。
- **作用**：解析 `try` / `catch` / `finally`：catch 参数自成词法层，finally 用 gosub 式进入。
- **实现**：
`try` 块。可选 `catch (p)`：catch 参数是自己的词法层（`DefineVarType.catch_`），解构参数走 pattern。`finally` 用 `parseSharedFinallyBlock`：gosub 式进入，栈上留 `[completion, ret_pc]`。`return`/`break`/`continue` 经 `emitControlThroughFinally` 穿过。无 catch 有 finally 时仍要装 catch 标记深度以便 using/迭代器清理。四个 LabelId 里 `catch` / `finally` / `end` 在开头一次建好，`catch2` 推迟到 catch 子句里才建——v2 要求每个建出来的 label 最终都要绑定，而无 catch 的 try 永远不会绑 catch2（label id 顺序因此与 qjs 不同，但解析结果一致）。try 体与 catch 体的活代码尾各发一串 `drop ; undefined ; gosub finally ; drop ; goto end`；catch2（或无 catch 时的 catch）处则是 `gosub finally ; throw` 的重抛路径；最后绑 `finally`、可选 `parseSharedFinallyBlock`、发 `ret`、绑 `end`。catch 子句一共开**两层**作用域：绑定层（catch 参数所在，`defineVar(.catch_)` 或解构 pattern）与 QuickJS 额外要的 wrapper 层，块自身的作用域再由 `parseBlock` 开第三层。
- **所有权 / 错误 / 调用**：本函数的配对最密：`active_catch_marker_depth` 与 `pushReturnFinallyFrame` 成对出现两次（try 体一组、catch 体一组），每组都是「`errdefer` 兜底 + 正常路径手工 `popReturnFinallyFrame` 并清 `*_active` 标志、同时把深度还原」；catch 的两层作用域各有 `catch_binding_scope_active` / `catch_wrapper_scope_active` 配 `errdefer popScopeIdentity`，正常路径按**内层先出**的顺序 `popScope`。`finally_ref` 只是包着 `label_finally` 的值类型，被两个 return-finally 帧共享，`return` / `break` / `continue` 经 `emitControlThroughFinally`（`src/parser.zig:10468`）穿过它。错误：既无 `catch` 又无 `finally` 时 `failUnexpectedToken`；严格模式下 catch 参数叫 `eval`/`arguments` 同样报错。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_TRY` 臂（`src/parser.zig:9021`）。

### `parseDebuggerStatement` (`src/parser.zig:9896`)

- **签名**：`fn parseDebuggerStatement(s: *State) Error!void`。
- **作用**：`debugger;` 语句。
- **实现**：
吃掉 `debugger` 再 `expectSemicolon()`（走 ASI）；不发任何 opcode。
- **所有权 / 错误 / 调用**：不分配、不发射任何指令（`debugger` 在 zjs 里被完全擦除）：只 `advance()` 吃掉关键字再 `expectSemicolon()`。错误因此只有两类——`advance` 的 lexer 错误族与 `expectSemicolon` 的 `SyntaxError`（记 pending 诊断，最终由 `exec/eval_entry.zig:127` 抛成 JS SyntaxError）。唯一调用方 `parseStatementOrDeclSlow`（`src/parser.zig:9022`）。

### `parseEmptyStatement` (`src/parser.zig:9901`)

- **签名**：`fn parseEmptyStatement(s: *State) Error!void`。
- **作用**：空语句 `;`。
- **实现**：
只 `advance()` 吃掉分号，不发任何 opcode、不建作用域。
- **所有权 / 错误 / 调用**：不分配、不发射：单条 `advance()` 吃掉 `;`，`Error!void` 的全部失败面就是 `advance` 里的 lexer 错误与栈溢出保护（`advance` 的 `checkNativeStackOverflow` → `Error.StackOverflow`）。唯一调用方 `parseStatementOrDeclSlow`（`src/parser.zig:9023`）。

### `parseExpressionStatement` (`src/parser.zig:9906`)

- **签名**：`fn parseExpressionStatement(s: *State) Error!void`。
- **作用**：通用表达式语句：算完值后按是不是 eval 决定写进 `<ret>` 还是丢弃。
- **实现**：对照 `quickjs.c:28960`：`expressionStatementKeepsCompletion`（`eval_ret_idx >= 0` 且不是 module）为真时把值存进 `eval_ret_idx` 让 `eval()` 能返回它，否则 `drop`。顺序是 `emitGrammarSource`（语句首行列）→ `parseExpr2(in_accepted = true, result_needed = keep_completion)` → `expectSemicolon`（含 ASI）→ `emitEvalRetPut` 或不带源事件的 `drop`。`<ret>` 是非词法槽，降级后就是一条 `put_loc`（或 short 形式），流水线透明处理。
- **所有权 / 错误 / 调用**：不分配、不保存状态；`parseExpr2` 压上的那一个值必定被 `emitEvalRetPut` 或 `drop` 之一消费，所以栈自平衡。没有自有的错误分支，全部来自 `parseExpr2` / `expectSemicolon` / emit。它是语句分派表的 `else` 兜底臂（`src/parser.zig:9024`），也是 `parseIdentifierStatement` / `parseAwaitStatement` / `parseImportStatement` / `parseStringStatement` 各自复制的同一段尾巴的原型。

### `parseUsingDeclaration` (`src/parser.zig:9930`)

- **签名**：`fn parseUsingDeclaration(s: *State, kind: DisposalHint) Error!void`。
- **作用**：解析 `using x = expr` / `await using x = expr`，把资源登记进当前 using 块的 disposable stack。
- **实现**：三道前置：`await using` 要求 `in_async` 或模块顶层，否则 `AwaitOutsideAsyncFunction`；不是模块顶层却处在程序体作用域（即 script 顶层）时报明确消息 "using declaration is not allowed at the top level of a script"；必须已经有 `using_block_frames`，否则 `ParserInvariant`。随后吃掉 `await`（若有）与 `using`，循环解析逗号分隔的声明：名字必须是合法标识符、不能是 `let`，严格模式下不能是 `eval` / `arguments`，模块顶层还要避开 `hasKnownBinding` 命中的名字；用 `.const_` 定义（using 绑定不可重新赋值），并强制要求 `=` 初始化器。发射上 `armCurrentUsingBlockFrame` 先取到 disposable stack 槽，`parseAssignExpr` 求值、`setObjectName` 给匿名函数命名，然后 `dup` 成两份——一份 `scope_put_var_init` 给词法绑定，一份 `put_loc` 存进 `appendAnonymousTempLocal` 开的匿名局部当资源，交 `emitUsingAddResource(kind, stack_loc, resource_loc)` 登记、`noteUsingResourceHint` 记 sync/async 提示，最后 `emitCloseLoc` 关掉这个临时槽。遇 `,` 继续下一条，否则退出循环。
- **所有权 / 错误 / 调用**：本函数**不建也不收** using 帧——它要求调用方已经压好（帧为空即 `Error.ParserInvariant`），只往当前帧上 `armCurrentUsingBlockFrame` 挂资源；帧的 `finalize` / 错误回滚归 `parseBlockContentsAfterOpen`、`parseProgramStatements` 或 `parseForStatement`。`appendAnonymousTempLocal` 开的资源槽归 `FunctionDef`，没有释放接口，运行时由 `emitCloseLoc` 负责关闭 cell。定义的绑定与发出的字节码都是不可回滚的持久副作用。错误三层：`AwaitOutsideAsyncFunction`（`await using` 在非 async 非模块顶层）、script 顶层的 `failWithMessage`、以及名字检查的 `failUnexpectedToken` / 缺 `=` 的 `failExpectedToken`；帧缺失是 `Error.ParserInvariant`。三个调用方：`parseIdentifierStatement`（`src/parser.zig:9139`，`.sync`）、`parseAwaitStatement`（`:9174`，`.async`）、`parseForStatement` 的头（`:9390`）。

### `canParseModuleDeclarationHere` (`src/parser.zig:9978`)

- **签名**：`fn canParseModuleDeclarationHere(s: *State) bool`。
- **作用**：谓词：此处能否出现 `import` / `export` 声明。
- **实现**：
一行 `s.lex.is_module and s.atProgramBodyScope()`——只有模块源码的程序体顶层才允许，嵌套块/函数里都不行。
- **所有权 / 错误 / 调用**：无：两个只读条件的与（模块源 + 处于程序体作用域），不分配、无 error set、无副作用。两个调用方：`parseImportStatement`（`src/parser.zig:9209`）与 `parseExportStatement`（`:9216`），都拿它与 `decl_mask.other` 一起做门槛，不满足就 `failUnexpectedToken`（`import(` / `import.meta` 的表达式形态在更早一步就已分流走，不靠这个谓词）。

### `canTreatLetAsExpressionStatement` (`src/parser.zig:9991`)

- **签名**：`fn canTreatLetAsExpressionStatement(s: *State, decl_mask: DeclMask) bool`。
- **作用**：谓词：非严格模式下打头的 `let` 到底引入词法声明还是一条普通表达式语句。
- **实现**：对照 QuickJS `is_let`（`quickjs.c:28619`）的**反向**判断：返回真表示打头的 `let` 引入的是 ExpressionStatement 而不是词法声明。qjs 里 `let [` 永远不是表达式语句；`let` 后跟 `{`、非保留字标识符、`let`、`yield`、`await` 时，只要中间没有行终结符**或**当前正在找 Declaration（`decl_mask.other`），就是声明；其余是表达式。严格模式下 qjs 把 `let` 词法成 TOK_LET、根本不问 `is_let`，所以这里一上来就 `return false`。
- **所有权 / 错误 / 调用**：**前瞻但保证复位**：`takeLexerCursorSnapshot`/`restoreLexerCursorSnapshot`（`src/parser.zig:13256`/`:13268`）成对使用，而且 `defer restoreLexerCursorSnapshot` **必须在 `nextInto` 之前武装**——源码注释点明 `nextInto` 会先推进 `pos` 再 intern 标识符，失败逃逸时若恢复未武装就会把解析器卡在半个 token 上。`peek_token` 的 payload 由 `defer s.lex.freeToken` 释放。返回 `bool` 而不是错误：`nextInto` 失败直接 `catch return false`，把词法问题让给随后的正规解析报告，所以本函数**无 error set、不分配**。两个调用方：`canTreatLetAsForInitializerExpression`（`:2801`）与 `parseVariableStatement`（`:9092`）。

### `parseLetKeywordExpressionStatement` (`src/parser.zig:10030`)

- **签名**：`fn parseLetKeywordExpressionStatement(s: *State) Error!void`。
- **作用**：sloppy 模式下打头的 `let` 只是一个标识符引用时，把整条语句按表达式语句解析。
- **实现**：主体与 `parseExpressionStatement` 同形（源事件 → `parseExpr2` → 结果写 `<ret>` 或 `drop`），中间多一道诊断改良：表达式结束后若当前既不是 `;`、也没有换行可触发 ASI、也不是 `}` 或 EOF，说明这行本该是一条词法声明，于是报 `failExpectedDescription("binding name")`（用户真正缺的是绑定名）而不是泛泛的「意外 token」。
- **所有权 / 错误 / 调用**：不分配、不保存状态；`parseExpr2` 的值由 `emitEvalRetPut` 或 `drop` 消费。唯一自有错误是那条诊断改良的 `failExpectedDescription("binding name")`。唯一调用方 `parseVariableStatement`（`src/parser.zig:9093`），且只在 `canTreatLetAsExpressionStatement` 判定为真时进入。

### `parseSharedFinallyBlock` (`src/parser.zig:10115`)

- **签名**：`fn parseSharedFinallyBlock(s: *State) Error!void`。
- **作用**：解析一次 `finally` 块本体，并把它登记成 return / break / continue 退出时共用的清理接缝。
- **实现**：先在栈上造一个 `BlockEnv`（`drop_count = 2` 对应完成值与 gosub PC，`is_regular_stmt = false`）挂上 `s.top_break`，`defer` 断言并还原，于是每个穿越本体的 abrupt completion 都按同一条边界丢弃这两格。同时往 `finally_body_control_frames` 压一条记录，把当前 catch marker 深度与 break / continue / label 三个栈的深度快照下来（`defer` 弹出），供 return 走查判断要跨越哪些帧。若本次编译带 `<ret>`（eval），先 `appendFunctionVarAtOrigin` 开一个匿名局部，把进入 finalizer 时的完成值 `emitEvalRetGet` 出来 `put_loc` 存好，并把 `<ret>` 复位成 undefined——这是 zjs 特有的共享 finalizer 降级。随后 `parseBlock` 解析块体，结束时 `get_loc` + `emitEvalRetPut` 把原完成值恢复回去（finalizer 自身的正常值按规范被忽略）。
- **所有权 / 错误 / 调用**：`BlockEnv` 是**栈上局部**，只把地址挂进 `s.top_break` 链，`defer` 里先 `std.debug.assert(s.top_break == &block)` 再摘链——所以块体内任何多余的 push/pop 都会在 Debug 下当场炸出来；`finally_body_control_frames` 上那条记录同样用 `defer pop` 配对（`append` 用的是 `s.function.memory.allocator`，是本函数唯一的堆动作）。`appendFunctionVarAtOrigin` 开的 `<ret>` 备份槽归 `FunctionDef`，无释放接口。两条 `defer` 都不区分成功失败，所以错误路径也干净。自身没有错误分支，全部来自 `parseBlock` 与 emit。唯一调用方 `parseTryStatement`（`src/parser.zig:9888`），且只在真的见到 `finally` 关键字时调用——没有 `finally` 时 `label_finally` 仍被绑定，只是接缝里只剩一条 `ret`。

### `parseVar` (`src/parser.zig:10533`)

- **签名**：`fn parseVar(s: *State, var_tok: tok.TokenKind, export_decl: bool, parse_flags: ParseFlags) Error!void`。
- **作用**：解析 `var` / `let` / `const` 的绑定列表（含解构、默认值、模块导出登记与 TDZ 结束的写回）。
- **实现**：
`var`/`let`/`const` 列表（`is_lexical` 还额外把 `s.in_namespace` 算进来）。`let` 当关键字还是 ident 由调用方 `canTreatLetAsExpressionStatement` 决定。逗号循环，每轮的左端三选一：**简单标识符**（含非严格模式下可当绑定名的 `yield`/`static`/`let`/`await` 等 `sloppy_keyword_var`）、**`[` / `{` 解构**（先压 `undefined` 占位再 `parseDestructuringElement`，没有初始化器就 `failExpectedToken('=')`）、其余 `failExpectedDescription("binding name")`。标识符一路要过四道检查：带转义的保留字、词法声明不许叫 `let`、严格模式不许 `eval`/`arguments`、模块顶层与已知绑定冲突；`var arguments` 在有参数表达式的函数里还要把已提升的 `arguments_var_idx` 接过来（`ensureParameterArgumentsLocals`）。`defineVar` 之后按种类分：词法记 `tdz_emitted_at_decl`（声明点**不**发 `set_loc_uninitialized`，TDZ 的唯一布防归 `enter_scope` 降级）。有 `=` 时：`needVarReference` 决定要不要先 `scope_get_var` + `getLValue` 拿一个 with/eval 语义的引用，`parseAssignExpr2` 求值、`setObjectName` 补匿名名，然后取 Builder 快照（`errdefer rollback`）、把源事件钉在 `=` 上，再按引用 / 词法 / 普通三种形态写回（`putLValue` / `scope_put_var_init` / `scope_put_var`，都用 NoSource 形式）。没有 `=` 时：`const` 报 `failExpectedToken('=')`，`let x;` 补一对 `undefined ; scope_put_var_init`，`var x;` 什么都不发。`export_decl` 登记模块导出名，`namespace_export` 再补一段 `scope_get_var ns ; scope_get_var x ; put_field x`。循环末尾只看 `,`；分号与 ASI 归调用方。
- **所有权 / 错误 / 调用**：`declaration_lvalue` 是唯一需要配对释放的值（`defer lvalue.deinit(s)`），初始化器写回那几步另有 Builder `snapshot` / `errdefer rollback`。其余全是对 `FunctionDef` 的不可回滚写：新 VarDef / GlobalVar、`arguments_var_idx`、模块导出名、以及已发出的字节码。绑定名 atom 在 `advance()` 前取走（源码注释对照 qjs `js_parse_var` 在 `next_token` 释放 token 前先取 `name`），之后只当 id 用。错误面：五类 `failUnexpectedToken`（转义保留字 / `let` 作词法名 / 严格模式 `eval`·`arguments` / 模块重名）、两处 `failExpectedToken('=')`、一处 `failExpectedDescription`，其余是 `defineVar` / emit 的 `OutOfMemory`。三个调用方：`parseVariableStatement`（`src/parser.zig:9106`）、`parseForStatement` 的 C 风格头（`:9404`，`in_accepted = false`）、`parseExport`（`:15602`，`export_decl = true`）。

### `parseWith` (`src/parser.zig:10701`)

- **签名**：`fn parseWith(s: *State) Error!void`。
- **作用**：解析 `with (expr) stmt`（只在非严格模式合法）。
- **实现**：严格模式（`s.is_strict` 或当前函数已严格）直接 `failUnexpectedToken`。吃掉 `with` 与 `(`，`parseExpr` 求出对象、`)` 收尾，然后 `pushScope` 开一层作用域并以 `.with_` 种类定义内部绑定 `<with_object>`（必为局部槽）。发射对照 `quickjs.c:29553-29570`：`ext0/to_object` 把表达式强制成对象，`put_loc with_idx` 存进该槽。解析体之前把 `active_with_atom` 切到这个 atom（`defer` 还原），于是体内的标识符引用会降级成经由 with 对象的动态查找；`setEvalReturnUndefined` 复位完成值后 `parseStatementOrDecl(DeclMask{})`（with 体内不允许任何声明），最后 `popScope` 发 `leave_scope`。
- **所有权 / 错误 / 调用**：不分配堆内存；两件需要配对的东西：作用域（`pushScope` → 正常 `popScope`，失败 `errdefer popScopeIdentity`）与 `active_with_atom`（`defer` 还原）。`<with_object>` 槽归 `FunctionDef`，`defineVar(.with_)` 在这里断言必是 `.local`（`else => unreachable`）——with 的内部绑定不可能落到全局或参数上。`parseExpr` 压的对象值被 `ext0.to_object` + `put_loc` 消费，栈自平衡。唯一自有错误是严格模式下的 `failUnexpectedToken`。唯一调用方 `parseWithStatement`（`src/parser.zig:9332`）。

### `declareForInOfVarBinding` (`src/parser.zig:10730`)

- **签名**：`fn declareForInOfVarBinding(s: *State, atom_id: Atom) Error!void`。
- **作用**：给 `for (var x in/of ...)` 的左端声明一个 var 绑定。
- **实现**：`defineVar(atom_id, .var_)`；若绑定名恰是 `arguments` 且当前函数确有 arguments 绑定，则把新槽位记进 `curFunc().arguments_var_idx`（`.argument` / `.global` 两种归宿不需要记）。
- **所有权 / 错误 / 调用**：不分配、不发码，只做一次 `defineVar(.var_)` 并按需回填 `curFunc().arguments_var_idx`——这个回填是对 `FunctionDef` 的不可回滚写。`atom_id` 是借用 id。错误只有 `defineVar` 上抛的 `OutOfMemory`（`.var_` 不产生重复声明错误）。唯一调用方 `parseForInOf`（`src/parser.zig:10859`），只在 `for (var x in/of …)` 的非词法、非解构左端使用。

### `parseForInOf` (`src/parser.zig:10742`)

- **签名**：`fn parseForInOf(s: *State, is_for_await: bool) Error!void`。
- **作用**：解析 `for-in` / `for-of` / `for await-of`：一趟扫描搭出赋值目标与迭代循环，收尾负责 `iterator_close`。
- **实现**：
对照 `js_parse_for_in_of`（`quickjs.c:27991`）。先 `pushScope`，发 `goto expr_label` 跳过赋值块，紧接着绑 `assign_label` —— 赋值目标只解析一趟、发一次码，每轮迭代靠末尾的 `if_false → assign_label` **向后**跳回来重用。

左端四选一：`using` / `await using`（`defineVar(.const_)`，禁止 `=`，并先把迭代值 `put_loc` 进一个匿名槽）；`var` / `let` / `const`（解构走 `parseDestructuringElement`，简单名按词法与否发 `scope_put_var_init` 或 `scope_put_var`，`var` 另经 `declareForInOfVarBinding`）；`[` / `{` 开头且拓扑扫描认定是 pattern 的赋值解构；其余走 `parseLhsExpr` + `getLValue` + `putLValue`。两个特例：松散模式下 `let in` 里的 `let` 当标识符；`for (async of …)` 被显式拒绝。运行时非法的调用目标（`lvalue.invalid_call`）要立刻求值并抛，所以把 `expr_label` 用 `emitterRetargetLabel` **改指**到 `assign_label`（v2 不改写跳转 PC），随后就不再单独绑定 `expr_label`。

接着是 Annex-B 的 `for (var x = init in obj)`：只有非严格、非词法、非解构的简单 `var` 声明才允许，且不能与 `of` 同现。判完 `in` / `of`（`for await` 必须配 `of`，`using` 也必须配 `of`）后求值右端、`closeScopes` 回到块层级、吃掉 `)`，发 `for_in_start` / `for_of_start` / `for_await_of_start`，再 `goto next_label` + 绑 `body_label`。

循环体前建三层控制结构：`pushBreakFrame` + `setCurrentBreakCleanupDrops`（for-of 用迭代器关闭标记，for-in 用 1）、可选 `pushLabelFrame`、`pushControlBlock`（栈深 for-of 3 / for-in 1，`has_iterator` 只对 for-of 置起）。`using` 形态还在这里开一层 using 帧、把迭代值 `dup` 成绑定值与资源两份并 `emitUsingAddResource`。体解析完后 `finalizeCurrentUsingBlockFrame`、`closeScopes`、`patchContinueFrame` / `patchLabelContinues`，然后绑 `next_label` 取下一个值：for-await 是 `for_await_of_next ; await ; iterator_get_value_done`，for-of 是 `for_of_next 0`，for-in 是 `for_in_next`；再 `if_false → assign_label` 回到赋值块。收尾按形态丢栈并 `iterator_close`（for-in 只丢两格、不关迭代器），最后补 label break、pop 控制块与作用域。
- **所有权 / 错误 / 调用**：三处 `errdefer`：for 作用域（`pushed_for_scope` → `popScopeIdentity`）、控制块（`loop_block_active` → `popControlBlock`）、迭代 using 帧（`iteration_using_frame_active` → `restoreUsingBlockFramesAfterError`）；break 帧与 label 帧同样没有错误路径保护，靠上层丢弃 `FunctionDef`。`lvalue` 用 `defer lvalue.deinit(s)`。`appendAnonymousTempLocal` 开的迭代值槽与资源槽归 `FunctionDef`，运行时由两条 `emitCloseLoc` 关闭 cell。`pending_label_atom` 在建帧前取走并置 `null`。错误：`await using` 在非 async 非模块顶层是 `Error.AwaitOutsideAsyncFunction`；缺 `in`/`of`、`async of`、`using`/`for await` 配 `in`、Annex-B 初始化器出现在不允许处都经 fail 族；`target_atom` / 迭代值槽缺失是 `Error.ParserInvariant`。两个调用方都是 `parseForStatement`：`for await`（`src/parser.zig:9349`）与普通无顶层分号的 for 头（`:9360`）。

## 覆盖核对

- 清单函数数（本文件分到）: 44（`src/parser.zig` 全文件 649）
- 本文标题覆盖: 44
- 未覆盖: 无

全文件清单共 649 个函数；以 `03-parser*.md` 合计为准。
