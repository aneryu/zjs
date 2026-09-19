# 03 — parser 扫描 / token / 前瞻

`ParseState.advance`、ASI、`expect*`、失败诊断、箭头 cover 与 for 头的平衡扫描、lexer 快照。表达式/语句的真正下降在其它分册。


### `ParseState.advance` (`src/parser.zig:2018`)

- **签名**：`fn advance(self: *State) Error!void`。
- **作用**：消费当前 token，就地换成下一个 token（被消费 token 的 payload 由 `nextIntoReplacing` 释放）。
- **实现**：先过原生栈守卫：`self.runtime` 存在时调 `rt.checkNativeStackOverflow(0)`，越线就 `failHere(error.StackOverflow)`——所有递归下降路径（括号、数组、对象、嵌套语句）都从这里取 token，一处检查即可把病态嵌套变成可捕获的 SyntaxError（对照 QuickJS 在 `next_token` 里的守卫，quickjs.c:22836）。然后断言 `self.lex.pos == self.currentTokenEndOffset()`（跳 trivia 之前 `lex.pos` 就是当前 token 的结束位置，对应 qjs 的 `last_ptr = buf_ptr`），把被消费 token 的结束偏移与行列存进 `last_token_end_offset` / `last_token_line_num` / `last_token_col_num` 供 ASI 与诊断使用，最后由 `self.lex.nextIntoReplacing(&self.token)` 就地换成下一个 token。词法失败时只要不是 `error.OutOfMemory`，就用 `lex.mark_pos` / `mark_line` / `mark_col` 与 `@errorName(err)` 调 `setPendingDiagnostic`，再把 err 原样上抛。
- **所有权 / 错误 / 调用**：不分配：`nextIntoReplacing` 先释放被消费 token 的 payload（解码过的字符串/raw 字节），ident 的 atom id 只是借用——TGC S3-c 后 token 不再持引用计数，`releaseTokenPayload` 对 ident 分支什么都不做（lexer.zig:133-138），编译期 intern 的 id 由 `CompileAtomScope` 这个 GC RootProvider 钉到编译结束。错误有两个来源：栈守卫的 `error.StackOverflow`（先经 `failHere` 钉位置）与 `lex.nextIntoReplacing` 的 `lexer_mod.Error`（OOM 不写诊断，其余先写 `pending_diagnostic`），一律原样上抛，最后由 `compile` 收成 `Result.syntax_error` 或 ICE。调用方是整棵递归下降树（parser.zig 内 222 处 `s.advance()`）。

### `ParseState.setPendingDiagnostic` (`src/parser.zig:2049`)

- **签名**：`noinline fn setPendingDiagnostic(self: *State, err: Error, position: diagnostics.Position, message: []const u8) void`。
- **作用**：把一次词法/语法失败钉成 `pending_diagnostic`：位置、error 码、截断进固定缓冲的消息。
- **实现**：构造 `PendingDiagnostic`，消息长度取 `min(message.len, message_buffer.len)`，`@memcpy` 进内嵌缓冲，再写入 `self.pending_diagnostic`。`noinline` 把诊断拷贝从 `advance` 热路径拆出去。
- **所有权 / 错误 / 调用**：不分配。缓冲所有权在 `ParseState`。调用方：`advance` 在 `nextIntoReplacing` 非 OOM 失败时。`recordFailureHere`（以及经它转调的 `failHere`）、`failExpectedDescription` / `failUnexpectedToken` / `failWithMessage` 也都从这里写入；只有 `propagateFailureHere` 读这份 pending，用来判断同一个 err 是否已经记过。

### `ParseState.currentDiagnosticPosition` (`src/parser.zig:2060`)

- **签名**：`fn currentDiagnosticPosition(self: *const State) diagnostics.Position`。
- **作用**：取当前 token 起点的 offset/行/列，作为诊断位置。
- **实现**：三个字段直接组装成 `diagnostics.Position`：`offset` 取 `currentTokenStartOffset()`（跳过 trivia 之后的 token 起点，不是 `lex.pos`），行列抄 `token.line_num` / `token.col_num`。不读 `pending_diagnostic`，也不看 `last_token_*`，所以它给出的永远是「当前这个还没被消费的 token」的位置。
- **所有权 / 错误 / 调用**：无：不分配、无 error，只读 `token` 与 `lex.source` 组装纯值。调用方：`recordFailureHere`(`src/parser.zig:2081`)、`failExpectedDescription`/`failUnexpectedToken`/`failWithMessage` 的缺省位置(2159/2185/2190)，以及先存位置后报错的 `src/parser.zig:4870`、`recordInvalidStrictParameterName`(7043)。

### `ParseState.recordFailureHere` (`src/parser.zig:2068`)

- **签名**：`fn recordFailureHere(self: *State, err: Error) void`。
- **作用**：把一次失败按当前 token 位置记进 `pending_diagnostic`。
- **实现**：单个 `switch (err)`：`error.OutOfMemory` 与 `error.BytecodeOverflow` 不是源码位置问题，直接忽略不覆盖 pending；其余 err 以 `@errorName(err)` 为消息、`currentDiagnosticPosition()` 为位置调 `setPendingDiagnostic`。
- **所有权 / 错误 / 调用**：不分配：诊断写进 `ParseState.pending_diagnostic` 的内嵌缓冲。无 error 返回；`OutOfMemory` / `BytecodeOverflow` 被刻意跳过，不覆盖已有 pending（它们不是源码位置问题）。调用方：`failHere`(`src/parser.zig:2086`)、`propagateFailureHere`(2094)，以及诊断单测(16554-16566)。

### `ParseState.failHere` (`src/parser.zig:2075`)

- **签名**：`fn failHere(self: *State, err: Error) Error`。
- **作用**：把一个已经拿到的 `Error` 就地钉上当前 token 的位置再抛出，让调用点能写成 `return self.failHere(err)` 一行。
- **实现**：转调 `recordFailureHere(err)` 按当前 token 位置记诊断，再把同一个 `err` 原样返回，供调用点写成一行 `return self.failHere(...)`。
- **所有权 / 错误 / 调用**：不分配，只写 pending 诊断；返回类型是 `Error` 而非 `Error!void`，让调用点写成 `return self.failHere(...)`。树内唯一调用方是 `advance` 的栈守卫(`src/parser.zig:2035`)，传的永远是 `error.StackOverflow`。

### `ParseState.propagateFailureHere` (`src/parser.zig:2080`)

- **签名**：`fn propagateFailureHere(self: *State, err: Error) Error`。
- **作用**：向上抛一个已有失败：若 `pending_diagnostic` 里已经是同一个 err 就保留原来的位置，否则改记当前位置。
- **实现**：先读 `pending_diagnostic`：若里面记的 `pending.err` 与要上抛的 `err` 相同，说明更内层已经钉过更精确的位置，直接原样返回不覆盖；否则走 `recordFailureHere` 按当前 token 位置补记后返回。
- **所有权 / 错误 / 调用**：不分配；读 `pending_diagnostic` 决定是否覆盖位置，err 原样返回。调用方是各层的 catch 桥：`parseExpr`(`src/parser.zig:4002`)、`parseAssignExpr`(4029)、语句层(8515/8939/8949/8953)，以及 `compileQjsProgram` 的三处顶层 catch(16264/16283/16285)——最终那份 pending 就是 `compile` 生成 `Result.syntax_error` 用的位置与消息。

### `ParseState.tokenKindLabel` (`src/parser.zig:2088`)

- **签名**：`fn tokenKindLabel(self: *const State, kind: tok.TokenKind, buffer: []u8) []const u8`。
- **作用**：把一个 token kind 渲染成诊断消息里的可读名字。
- **实现**：三条路径：kind 落在 `0..maxInt(u8)` 说明是单字符标点（kind 编码就是字符本身），渲染成 `'c'` 三字节写进调用方缓冲，缓冲不足 3 字节时退回 `"token"`；`tok.isKeyword(kind)` 为真时用 `tok.keywordAtom(kind)` 取 atom 再经 `function.atoms.name` 查名字，查不到退回 `"keyword"`；其余由一张 switch 映射成 `"number"` / `"string"` / `"template"` / `"identifier"` / `"regexp"` / `"end of input"` / `"invalid token"` / `"private name"` 以及 `'=>'`、`'...'`、`'??'`、`'?.'`，未列出的返回 `"token"`。
- **所有权 / 错误 / 调用**：只写调用方给的栈缓冲，不分配；关键字分支返回的是 `function.atoms.name()` 借来的 atom 表字节，生命期是编译期的 atom 表，调用方只在拼消息时用一次。无 error。调用方：`currentTokenKindLabel`(`src/parser.zig:2127`)、`failExpectedToken`(2138)、`failExpectedDescriptionAt`(2170)、类成员诊断(12611)。

### `ParseState.currentTokenKindLabel` (`src/parser.zig:2116`)

- **签名**：`fn currentTokenKindLabel(self: *const State, buffer: []u8) []const u8`。
- **作用**：给当前 token 取诊断名字；`tokenKindLabel` 只能给出通用的 `"token"` 时，退化成把 token 的源码原文加上单引号。
- **实现**：先用 `tokenKindLabel(peekKind(), buffer)` 取通用名字，只要结果不是 `"token"` 就直接返回；落到 `"token"` 时再看 token 的源码原文能不能带两个单引号装进 buffer（`token.len` 非 0 且不超过 `buffer.len - 2`），能装就把原文 `@memcpy` 进缓冲中段、两侧补 `'` 返回，装不下仍返回通用名字。
- **所有权 / 错误 / 调用**：只写调用方缓冲；退化分支拷的是 `token.ptr[0..len]`，即借用的源码切片，不分配。无 error。调用方只有两个诊断出口：`failExpectedDescription`(`src/parser.zig:2156`)、`failUnexpectedToken`(2178)。

### `ParseState.failExpectedToken` (`src/parser.zig:2126`)

- **签名**：`fn failExpectedToken(self: *State, expected: tok.TokenKind) Error`。
- **作用**：`expectToken` / `expectSemicolon` 这类「必须是某个 token」的诊断出口：把期待的 kind 渲染成人读的名字后报 `expected X, got Y`。
- **实现**：把 `expected` 经 `tokenKindLabel` 渲染进 8 字节栈缓冲（单字符标点 `'c'` 三字节，关键字名也在这个量级），再交给 `failExpectedDescription` 拼消息并抛错。
- **所有权 / 错误 / 调用**：不分配（8 字节栈缓冲）；恒定返回 `failExpectedDescription` 给出的 `error.UnexpectedToken`。调用方 27 处：三个包装 `expectSemicolon`(`src/parser.zig:2456`)、`expectToken`(2461)、`expectPunct`(7313)，其余是对象/类/函数体里直接检查 `'}'`、`'('` 的下降点。

### `ParseState.formatExpectedGot` (`src/parser.zig:2132`)

- **签名**：`fn formatExpectedGot(buffer: []u8, expected: []const u8, actual: []const u8) []const u8`。
- **作用**：把 `expected X, got Y` 拼进调用方给的栈缓冲区（`State` 的无 self 辅助函数）。
- **实现**：按 `"expected "` + expected + `", got "` + actual 先算 `needed` 长度，超出调用方缓冲就整体放弃、返回常量 `"UnexpectedToken"`；否则四次 `@memcpy` 顺序拼进 buffer 并返回 `buffer[0..needed]`。无 self、不分配，纯写调用方的栈缓冲。
- **所有权 / 错误 / 调用**：无 self、不分配，只写调用方缓冲；缓冲装不下时返回静态字面量 `"UnexpectedToken"`（调用方随后原样拷进 pending）。无 error。调用方：`failExpectedDescription`(`src/parser.zig:2158`)、`failExpectedDescriptionAt`(2172)。

### `ParseState.failExpectedDescription` (`src/parser.zig:2144`)

- **签名**：`fn failExpectedDescription(self: *State, expected: []const u8) Error`。
- **作用**：报「此处期待某某」：期待值是调用方给的自然语言描述串（如 `binding name`、`non-conflicting declaration`），实际值取当前 token。
- **实现**：当前 token 的名字由 `currentTokenKindLabel` 写进 16 字节栈缓冲，消息由 `formatExpectedGot` 拼在 `PendingDiagnostic.message_capacity` 大小的栈缓冲上，位置取 `currentDiagnosticPosition()`，`setPendingDiagnostic` 后返回 `error.UnexpectedToken`。全程只用栈缓冲，不分配。
- **所有权 / 错误 / 调用**：全程栈缓冲不分配，消息由 `setPendingDiagnostic` 拷进 pending 的内嵌缓冲，返回后栈缓冲即可失效；固定返回 `error.UnexpectedToken`。是 parser.zig 里最密集的描述式诊断出口（55 处），包括 `defineVar` 的重复声明判定(1739-1805 共 8 处)与 `scanBalancedToken` 的开括号检查(13390)。

### `ParseState.failExpectedDescriptionAt` (`src/parser.zig:2153`)

- **签名**：`fn failExpectedDescriptionAt( self: *State, expected: []const u8, actual: tok.TokenKind, position: diagnostics.Position, ) Error`。
- **作用**：同 `failExpectedDescription`，但实际 token 与诊断位置由调用方指定——用于要报在前瞻 token 上的场景（调用方先用 `peekNextDiagnosticToken` 拿到 `kind` / `position`，如可选链后缺 `'.'`、对象字面量缺 `',' or '}'`）。
- **实现**：与 `failExpectedDescription` 同形，只是 actual 名字由传入的 `actual` kind 经 `tokenKindLabel` 渲染（而不是当前 token），最后走 `failWithMessage(position, message)` 用调用方给的位置记诊断并返回 `error.UnexpectedToken`。
- **所有权 / 错误 / 调用**：同 `failExpectedDescription`，只是位置与实际 kind 由调用方给（都来自前瞻得到的 `DiagnosticToken` 纯值，不借 token 内存）；经 `failWithMessage` 写 pending 后返回 `error.UnexpectedToken`。调用方 5 处：`src/parser.zig:5771`、对象/绑定列表 8746/8760/8769、类成员 12610。

### `ParseState.failUnexpectedToken` (`src/parser.zig:2166`)

- **签名**：`fn failUnexpectedToken(self: *State) Error`。
- **作用**：报「这个 token 不该出现在这里」：消息为 `unexpected <当前 token 名>`，位置在当前 token。
- **实现**：当前 token 名字取自 `currentTokenKindLabel`，消息用 `std.fmt.bufPrint("unexpected {s}", .{actual_name})` 拼在栈缓冲上、格式化失败退回常量 `"UnexpectedToken"`，位置取 `currentDiagnosticPosition()`，记完返回 `error.UnexpectedToken`。
- **所有权 / 错误 / 调用**：不分配：`std.fmt.bufPrint` 写栈缓冲，装不下退回常量；写 pending 后固定返回 `error.UnexpectedToken`。是最常用的失败出口，parser.zig 内 135 处调用，覆盖表达式、绑定、模块、类各层。

### `ParseState.failWithMessage` (`src/parser.zig:2179`)

- **签名**：`fn failWithMessage(self: *State, position: ?diagnostics.Position, message: []const u8) Error`。
- **作用**：定制文案错误的共同出口：用调用方拼好的整条消息（位置可选）钉诊断并返回 `error.UnexpectedToken`。
- **实现**：`position` 为 null 时退回 `currentDiagnosticPosition()`，把调用方给的整条消息交给 `setPendingDiagnostic`（超长部分在那里被截断），返回 `error.UnexpectedToken`。
- **所有权 / 错误 / 调用**：不分配；`message` 必须在本次调用期间有效（调用方给的都是栈缓冲或字面量），`setPendingDiagnostic` 会拷贝进 pending 缓冲。固定返回 `error.UnexpectedToken`。调用方 18 处：`failExpectedDescriptionAt`(`src/parser.zig:2173`)、`failUndefinedLabel`(2202)、`mapLookaheadLexerError`(3921)、`delete` 与严格模式诊断(5315-5353)、`rejectInvalidStrictParameterName`(7049) 等。

### `ParseState.failUndefinedLabel` (`src/parser.zig:2184`)

- **签名**：`fn failUndefinedLabel(self: *State, atom_id: Atom) Error`。
- **作用**：`break` / `continue` 引用了当前没有活动标签帧的标签名时，报 `undefined label '<name>'`。
- **实现**：先用 `function.atoms.name(atom_id)` 取标签名，取不到说明 atom 表与标签栈失配，直接返回 `error.ParserInvariant`（内部不变量错，不是用户语法错）；否则把 `undefined label '<name>'` 拼进栈缓冲（失败退回 `"undefined label"`），经 `failWithMessage` 以 null 位置（即当前 token）抛出。
- **所有权 / 错误 / 调用**：不分配；label 名字借 `function.atoms.name(atom_id)`。特有错误来源：atom 查不到名字时返回 `error.ParserInvariant`——那是 ICE 通道（`isInternalCompilerError`），不是语法错误；正常路径返回 `failWithMessage` 的 `error.UnexpectedToken`。唯一调用方 `resolveFinallyControlTarget`(`src/parser.zig:10332`)。

### `ParseState.peekKind` (`src/parser.zig:2195`)

- **签名**：`pub fn peekKind(self: *const State) tok.TokenKind`。
- **作用**：读当前 token 的种类标签，是解析器所有分支判定的基本读操作。
- **实现**：直接返回 `self.token.val`，不触碰 lexer，也不做任何前瞻。
- **所有权 / 错误 / 调用**：无：纯读 `token.val` 的访问器，不分配、无 error；parser.zig 内约 324 处调用，是所有 kind 判定的入口。

### `ParseState.currentTokenStartOffset` (`src/parser.zig:2199`)

- **签名**：`fn currentTokenStartOffset(self: *const State) usize`。
- **作用**：把当前 token 的指针换算成相对源码起点的字节偏移。
- **实现**：把 `lex.source.ptr` 与 `token.ptr` 都 `@intFromPtr` 后相减：token 指针不大于源码起点（初始或合成 token）时返回 0，否则差值再 `@min` 到 `lex.source.len`，保证返回值始终是合法的源码下标。
- **所有权 / 错误 / 调用**：无：只做指针算术并夹到 `lex.source` 长度内，不分配、无 error。调用方：`currentDiagnosticPosition`(`src/parser.zig:2072`)、`currentFunctionSourceStart`(2218)、`currentTokenEndOffset`(2225)、类源码起点(14748)。

### `ParseState.currentFunctionSourceStart` (`src/parser.zig:2206`)

- **签名**：`fn currentFunctionSourceStart(self: *const State) FunctionSourceStart`。
- **作用**：把当前 token 的 offset/行/列打包成函数源码文本的起点。
- **实现**：把 `currentTokenStartOffset()` 与 `token.line_num` / `token.col_num` 打包成 `FunctionSourceStart` 返回，不做检查也不动状态。
- **所有权 / 错误 / 调用**：无分配、无 error：返回纯值 `FunctionSourceStart`，调用方把它留在栈上直到 `captureFunctionSource` 回填源码范围。16 处调用，全在函数/方法/箭头/类的头部(如 `src/parser.zig:3965`、6314、8938)。

### `ParseState.currentTokenEndOffset` (`src/parser.zig:2214`)

- **签名**：`fn currentTokenEndOffset(self: *const State) usize`。
- **作用**：当前 token 起点加上 `token.len`（clamp 到源码长度），即 token 的结束偏移。
- **实现**：`currentTokenStartOffset() + token.len` 再 `@min` 到 `lex.source.len`；`advance` 用它断言 `lex.pos` 与当前 token 一致。
- **所有权 / 错误 / 调用**：无分配、无 error。调用方只有两处：`advance` 的位置不变量断言(`src/parser.zig:2039`)与预声明扫描起点(8617)。

### `ParseState.captureFunctionSource` (`src/parser.zig:2218`)

- **签名**：`fn captureFunctionSource(self: *State, fd: *function_def_mod.FunctionDef, source_start: usize) Error!void`。
- **作用**：把 `fd` 的源码文本设成 `source_start` 到上一个 token 结束处（`last_token_end_offset`）。
- **实现**：单行转调 `setFunctionSourceRange(fd, source_start, self.last_token_end_offset)`：函数体解析完时当前 token 已经越过 `}`，所以终点取上一个 token 的结束偏移。
- **所有权 / 错误 / 调用**：自身不分配，转调 `setFunctionSourceRange`；因此唯一的失败是那条路径上 `fd.replaceSourceText` 的 `error.OutOfMemory`。区间右端取 `last_token_end_offset`（上一次 `advance` 存的），所以必须在函数体的收尾 token 消费之后调用。调用方：函数体收尾 `src/parser.zig:12011` 与 12513。

### `ParseState.setFunctionSourceRange` (`src/parser.zig:2222`)

- **签名**：`fn setFunctionSourceRange( self: *State, fd: *function_def_mod.FunctionDef, source_start: usize, source_end: usize, ) Error!void`。
- **作用**：把 `[source_start, source_end)` 这段源码存进 `fd`，作为该函数的源码文本。
- **实现**：先做区间体检：`source_end <= source_start`，或任一端越过 `lex.source.len`，就静默返回不报错（源码文本只是诊断/`toString` 用途，不值得中断解析）；否则 `fd.replaceSourceText(self.lex.source[source_start..source_end])`，由 `FunctionDef` 自己拷一份持有。
- **所有权 / 错误 / 调用**：源码切片借用 `lex.source`，但 `fd.replaceSourceText`（`src/bytecode.zig:5338`）把它复制成 `FunctionDef` 自己 owned 的 `[:0]const u8` 并释放旧副本，所以本函数唯一的 error 是那次分配的 `error.OutOfMemory`；区间非法（倒挂或越界）时静默返回，不报错。调用方：`captureFunctionSource`(`src/parser.zig:2229`)、`setChildFunctionSourceByCpoolIndex`(2250)。

### `ParseState.setChildFunctionSourceByCpoolIndex` (`src/parser.zig:2232`)

- **签名**：`fn setChildFunctionSourceByCpoolIndex( self: *State, cpool_idx: u16, source_start: usize, source_end: usize, ) Error!void`。
- **作用**：按 `parent_cpool_idx` 在当前函数的 `child_list` 里找到对应子函数，给它设置源码区间。
- **实现**：线性扫 `curFunc().child_list`，跳过 `child.parent_cpool_idx != cpool_idx` 的项，命中第一个就 `setFunctionSourceRange` 后立即返回；一个都不匹配时什么也不做。
- **所有权 / 错误 / 调用**：只读 `curFunc().child_list`（借用的子 `FunctionDef` 指针），找不到匹配 `parent_cpool_idx` 就什么都不做；错误同样只有 `replaceSourceText` 的 `error.OutOfMemory`。唯一调用方：类构造器源码回填 `src/parser.zig:14868`。

### `ParseState.isPunct` (`src/parser.zig:2245`)

- **签名**：`fn isPunct(self: *const State, ch: u8) bool`。
- **作用**：当前 token 是否就是给定的单字符标点。
- **实现**：把 `ch` `@intCast` 成 `tok.TokenKind` 与 `token.val` 比较——单字符标点的 kind 编码就是该字符的字节值。
- **所有权 / 错误 / 调用**：无：一次整数比较，不分配、无 error。调用方 10 处，集中在 ASI(`src/parser.zig:2447`/2453)、逗号表达式(4011)、条件运算(4665)与 `expectPunct`(7313)。

### `ParseState.gotLineTerminator` (`src/parser.zig:2250`)

- **签名**：`fn gotLineTerminator(self: *const State) bool`。
- **作用**：当前 token 之前是否出现过换行（ASI 判定用）。
- **实现**：
函数体只有一行，转发给 `self.lex.gotLineTerminator()`。
- **所有权 / 错误 / 调用**：无：转发 `lex.gotLineTerminator()`（读 `lex.got_lf`），不分配、无 error。17 处调用中多数直接写 `s.lex.gotLineTerminator()`，本包装只被 ASI(`src/parser.zig:2453`)等少数点使用。

### `ParseState.expectSemicolon` (`src/parser.zig:2432`)

- **签名**：`fn expectSemicolon(s: *State) Error!bool`。
- **作用**：按 ASI 规则要求语句结尾的分号；返回 true 表示有真分号或自动插入成功。
- **实现**：当前是 `;` 就 `advance` 吃掉并返回 true；否则按 ASI 判定：前面出现过换行（`gotLineTerminator`）、已到 `TOK_EOF`、或当前 token 是 `}`，三者任一成立即返回 true 且不消费任何 token；都不成立时 `failExpectedToken(';')`。
- **所有权 / 错误 / 调用**：不分配。两条失败路径：ASI 不成立时 `failExpectedToken(';')` 的 `error.UnexpectedToken`，以及消费分号时 `advance` 上抛的词法错误/`StackOverflow`。25 处调用方，全是以分号结尾的语句(`src/parser.zig:9039`、9071、9088、9107 等)。

### `expectToken` (`src/parser.zig:2446`)

- **签名**：`fn expectToken(s: *State, kind: tok.TokenKind) Error!void`。
- **作用**：要求下一个 token 匹配给定种类，否则诊断失败。
- **实现**：`peekKind() != kind` 时直接 `return s.failExpectedToken(kind)` 报 `expected X, got Y`；匹配则 `advance` 消费掉再返回。
- **所有权 / 错误 / 调用**：不分配；kind 不符即 `failExpectedToken` 报 `error.UnexpectedToken`，符合则失败只可能来自 `advance`。59 处调用方，覆盖块、类体、枚举、模块子句等所有固定 token(`src/parser.zig:4767`、8542、8550 等)。

### `peekNextKind` (`src/parser.zig:2453`)

- **签名**：`fn peekNextKind(s: *State) tok.TokenKind`。
- **作用**：看当前 token 之后那一个 token 的种类，`s.token` 与 lexer 游标都保持不变。
- **实现**：先 `takeLexerCursorSnapshot` 并 `defer restoreLexerCursorSnapshot`，用栈上的 scratch token 调 `lex.nextInto`（词法失败一律返回 `tok.TOK_EOF`，前瞻不抛错），`defer freeToken` 释放其 payload 后只取 `val` 返回。`s.token` 全程不动，前瞻结束后仍然有效。
- **所有权 / 错误 / 调用**：有真实的 token 所有权协议：`nextInto` 写出的 peek token 由本函数 `defer s.lex.freeToken` 释放（只释放解码出的字符串字节，ident 的 atom id 是借用不用管），游标由 `takeLexerCursorSnapshot`/`restoreLexerCursorSnapshot` 成对回滚。无 error——所有词法失败（含 `error.OutOfMemory`）都被 `catch return tok.TOK_EOF` 吞掉。27 处调用方，全是「看下一个 token 是什么」的判定(`src/parser.zig:2335`、4762、6286 等)。

### `peekNextIsOfToken` (`src/parser.zig:2462`)

- **签名**：`fn peekNextIsOfToken(s: *State) bool`。
- **作用**：判断当前 token 之后那一个是不是上下文关键字 `of`（`for (x of ...)` 的分流判据）。
- **实现**：与 `peekNextKind` 同样先 `takeLexerCursorSnapshot` + `defer restoreLexerCursorSnapshot`，用 scratch token 调 `lex.nextInto`（失败返回 false）并 `defer freeToken`；`TOK_OF` 直接为真，否则要求是 `TOK_IDENT`、`has_escape` 为假且 `atomNameEquals(..., "of")`——转义写法 `o\u0066` 不算上下文关键字。
- **所有权 / 错误 / 调用**：同 `peekNextKind` 的协议：快照回滚游标、`defer freeToken` 释放 peek token；名字比较走 `atomNameEquals`（只读 atom 表，不分配）。无 error，词法失败（含 OOM）吞成 false。唯一调用方：for 头的 of 判定 `src/parser.zig:10874`。

### `peekNextKindNoLineTerminator` (`src/parser.zig:2474`)

- **签名**：`fn peekNextKindNoLineTerminator(s: *State, expected: tok.TokenKind) bool`。
- **作用**：判断下一个 token 是否为 `expected` 且与当前 token 之间没有换行——用于受限产生式（no LineTerminator here）的前瞻。
- **实现**：与 `peekNextKind` 同样快照/恢复 lexer 游标并用 scratch token 前瞻（词法失败返回 false），命中条件是 `peek_token.val == expected` 且 `!s.lex.gotLineTerminator()`——`gotLineTerminator` 反映的是刚取到的这个 token 之前有没有换行。
- **所有权 / 错误 / 调用**：同上的快照 + `freeToken` 协议；词法失败吞成 false，无 error。调用方 3 处，都在 `async function` 不能跨行的判定：`src/parser.zig:6357`、8944、9144。

### `peekNextKindWithLineTerminator` (`src/parser.zig:2484`)

- **签名**：`fn peekNextKindWithLineTerminator(s: *State, line_terminator: *bool) tok.TokenKind`。
- **作用**：看下一个 token 的种类，同时通过出参回报它前面有没有换行，供调用方一次前瞻同时判种类与 ASI 约束。
- **实现**：与 `peekNextKind` 同形，额外在返回前把 `lex.gotLineTerminator()` 写回出参 `line_terminator.*`；词法失败返回 `tok.TOK_EOF`（此时出参不写）。调用方（如 `usingDeclarationStart`）借此一次前瞻同时拿到种类与换行信息，省掉第二次扫描。
- **所有权 / 错误 / 调用**：同上的快照 + `freeToken` 协议；额外把 `lex.got_lf` 写进调用方的 `line_terminator` out 参数——注意词法失败时直接 `return tok.TOK_EOF`，out 参数保持调用方的初值。无 error。调用方 3 处：`src/parser.zig:4915`（yield 操作数）、8328（`using` 前瞻）、13972（类访问器）。

### `forHeadHasNoTopLevelSemicolon` (`src/parser.zig:2499`)

- **签名**：`fn forHeadHasNoTopLevelSemicolon(s: *State) bool`。
- **作用**：判定 `for (` 之后的头部有没有顶层分号，用来把 C 风格 for 与 for-in/of 分流。
- **实现**：对照 QuickJS 在 `for` 语句边界上的 `SKIP_HAS_SEMI` 分发：C 风格 for 头必定含顶层分号，不含的一律交给真正的 for-in/of 解析器（语法与诊断归它）；这条独立扫描要留到统一扫描器能保住生产 CodeLoad 的布局门为止。先 `takeLexerCursorSnapshot`，再用 `lex.dupToken(s.token)` 独立持有当前 token（dup 失败即返回 false），因为扫描会边走边消费 `s.token`；`defer` 里释放扫描用的 token、恢复游标、把原 token 装回 `s.token`。之后用嵌套的 `advanceLocal` 逐个吞 token，维护 `paren_depth` / `bracket_depth` / `brace_depth` 三个计数：`TOK_TEMPLATE` 由 `skipTemplateInPredeclareScan` 整体跳过，`/` 与 `/=` 交给 `skipRegexpInPredeclareScan` 判定是否正则。三层深度都为 0 时遇到 `;` 返回 false（存在顶层分号），遇到收尾的 `)` 返回 true；EOF、括号失配或任何词法失败都返回 false。
- **所有权 / 错误 / 调用**：这里有真分配：扫描会消费 `s.token`，所以先 `lex.dupToken(s.token)` 复制出一份独立所有权（字符串 payload 走 `allocator.dupe`，ident 的 atom id 只是复制借来的整数），dupe 的 `error.OutOfMemory` 被 `catch return false` 吞掉；`defer` 块负责 `freeToken(&s.token)` 释放扫描用完的 token、回滚游标、把副本装回 `s.token`——漏掉这段就会泄漏那份副本。子扫描（template/regexp）的错误同样吞成 false。无 error 返回。唯一调用方：for 头形态判定 `src/parser.zig:9357`。

### `advanceLocal.call` (`src/parser.zig:2511`)

- **签名**：`fn call(state: *State) bool`。
- **作用**：在前瞻扫描里消费一个 token，失败返回 false。
- **实现**：`forHeadHasNoTopLevelSemicolon` 的扫描步进：`state.lex.nextIntoReplacing(&state.token)` 就地换下一个 token，词法错误吞掉并返回 false，让外层扫描放弃（前瞻扫描不允许把错误抛给解析器）。
- **所有权 / 错误 / 调用**：无独立所有权：`nextIntoReplacing` 自己释放旧 payload 再写入新 token，所有权始终在 `state.token`。错误（含 OOM）被吞成 `false`，由外层当作「扫不动了」结束扫描。只在 `forHeadHasNoTopLevelSemicolon` 内联使用，不是可复用 API。

### `rhsContainsDirectEval` (`src/parser.zig:2574`)

- **签名**：`fn rhsContainsDirectEval(s: *State) bool`。
- **作用**：前瞻赋值右侧还没解析的那段表达式，判断里面有没有 direct eval 调用（决定自由闭包目标是否需要提前的 Reference 捕获）。
- **实现**：纯 lexer 前瞻。保存/恢复方式与 `forHeadHasNoTopLevelSemicolon` 相同（`takeLexerCursorSnapshot` + `lex.dupToken(s.token)`，`defer` 里释放扫描用 token、恢复游标、装回原 token；直接复制 token 结构会还原一个已释放的标识符 atom）。循环里模板递归给 `templateContainsDirectEval`、`function` 整块交给 `skipFunctionInPredeclareScan`、`/` 与 `/=` 交给 `skipRegexpInPredeclareScan`，这三条都把 `eval_candidate` 清零。无转义、前一个 token 不是 `.` 的标识符 `eval` 置 `eval_candidate`；若它紧跟在 `(` 后还置 `grouped_eval_candidate`，使 `(eval)(...)`、`((eval))(...)` 能带着候选状态穿过闭括号（括号内出现逗号或其它运算符则在闭括号前就清掉）。带着候选遇到 `(` 即返回 true。三层深度 `paren_depth` / `bracket_depth` / `brace_depth` 都为 0 时遇到 `,` 或 `;` 说明已到当前表达式边界，返回 false；EOF、括号失配、词法失败同样返回 false。嵌套函数体不属于当前函数的直接 eval 环境。
- **所有权 / 错误 / 调用**：与 `forHeadHasNoTopLevelSemicolon` 同一套协议：`dupToken` 复制出独立的 token 副本（OOM 吞成 false），`defer` 释放扫描中的 `s.token`、回滚游标、装回副本。调用的 `templateContainsDirectEval` / `skipFunctionInPredeclareScan` / `skipRegexpInPredeclareScan` 的 `Error` 全部 `catch` 成 bool，因此本函数无 error——扫描失败时返回 false（按「没有 direct eval」处理）。唯一调用方：`src/parser.zig:4390` 的闭包捕获判定。

### `advanceLocal.call` (`src/parser.zig:2587`)

- **签名**：`fn call(state: *State) bool`。
- **作用**：在前瞻扫描里消费一个 token，失败返回 false。
- **实现**：`rhsContainsDirectEval` 的扫描步进，与 2525 处那份同形：`state.lex.nextIntoReplacing(&state.token)` 换下一个 token，词法错误吞掉返回 false 终止扫描。
- **所有权 / 错误 / 调用**：同 2525 那份：`nextIntoReplacing` 就地换 token，错误吞成 `false`；这是 `rhsContainsDirectEval` 自己的内联副本，两处闭包互不共享。

### `templateContainsDirectEval` (`src/parser.zig:2678`)

- **签名**：`fn templateContainsDirectEval(s: *State, first: tok.Token) bool`。
- **作用**：扫描模板字面量的各个 `${}` 替换表达式，判断其中是否含 direct eval 调用。
- **实现**：先看 `first.payload.str.template`：`.no_substitution` / `.tail` 说明这段模板后面没有 `${}` 可扫，直接 false；只有 `.head` / `.middle` 进扫描。外层循环按模板段推进，内层循环用 `lex.nextInto` 取栈上 scratch token（`defer freeToken`，全程不动 `s.token`）：`TOK_EOF` 返回 false；`TOK_FUNCTION` 交 `skipFunctionInPredeclareScan` 整体跳过（函数体里的 `eval(` 不是外层的 direct eval）；嵌套的 `TOK_TEMPLATE` 递归调用自身；`/` 与 `TOK_DIV_ASSIGN` 先问 `skipRegexpInPredeclareScan`（带上一个 token 的 kind）判定是不是正则字面量，是就整体跳过并把 `previous_token_kind` 记成 `TOK_REGEXP`。direct eval 的判据是一个两步状态机：无转义、atom 名等于 `eval`、且前一个 token 不是 `.` 的 `TOK_IDENT` 把 `eval_candidate` 置真（`a.eval(` 这种成员调用因此被排除），紧接着的 token 恰好是 `(` 就返回 true；任何其它 token 都把候选清零。括号计数用 `expr_depth`：`{` `(` `[` 加一，`}` `)` `]` 减一；深度为 0 时的 `}` 是本段替换表达式的收尾，跳出内层循环，深度为 0 时的 `)` / `]` 是失配，返回 false。段间用 `lex.nextTemplatePartAfterBraceInto` 取下一段，落到 `.tail` / `.no_substitution` 即整段扫完、返回 false。游标的保存与恢复由调用方负责。
- **所有权 / 错误 / 调用**：每个 `nextInto` / `nextTemplatePartAfterBraceInto` 产出的临时 token 都 `defer s.lex.freeToken`；不动 `s.token`、也不回滚游标——游标恢复由调用方 `rhsContainsDirectEval` 的快照负责。`first` 只读不持有。无 error：词法失败与非模板 payload 一律返回 false。调用方：`rhsContainsDirectEval`(`src/parser.zig:2623`) 与自身对嵌套模板的递归(2716)。

### `isIdent` (`src/parser.zig:2749`)

- **签名**：`inline fn isIdent(s: *State, name: []const u8) bool`。
- **作用**：当前 token 是否是无转义、名字等于 `name` 的标识符。
- **实现**：三级快速否定：`peekKind() != tok.TOK_IDENT` 返回 false；`token.payload.ident.has_escape` 为真返回 false（带 Unicode 转义的写法不当上下文关键字用）；否则 `lex.atoms.name(atom)` 取名字（取不到返回 false）与 `name` 做 `std.mem.eql` 比较。逐字节比名字比 `isAsyncIdentifier` 的 atom 恒等比较贵，所以只用于没有预置 atom 的少数词。
- **所有权 / 错误 / 调用**：无分配：名字经 `lex.atoms.name(atom)` 借 atom 表字节做 `mem.eql`，不 intern 也不释放。无 error。21 处调用，都是 contextual keyword 判定(`async`/`using`/`of`/`namespace` 等，如 `src/parser.zig:6313`、8325、9133)。

### `isAsyncIdentifier` (`src/parser.zig:2759`)

- **签名**：`inline fn isAsyncIdentifier(s: *State) bool`。
- **作用**：当前 token 是否是无转义的上下文关键字 `async`。
- **实现**：三条同时成立才为真：当前 token 是 `TOK_IDENT`、`payload.ident.has_escape` 为假（`\u0061sync` 不算上下文关键字）、`payload.ident.atom == atom_module.ids.async_`。对照 QuickJS `token_is_pseudo_keyword(s, JS_ATOM_async)`：上下文关键字识别是一次 atom id 比较，不是对每个普通标识符都去查 atom 名字符串。
- **所有权 / 错误 / 调用**：无分配、无 error：直接比预定义 id `atom_module.ids.async_`，不查名字表（比 `isIdent("async")` 少一次字节比较）。调用方 5 处：`src/parser.zig:3842` 的断言、3970、4769、6354、13689。

### `isOfToken` (`src/parser.zig:2779`)

- **签名**：`fn isOfToken(s: *State) bool`。
- **作用**：当前 token 是否是 `of`（`TOK_OF` 或同名标识符）。
- **实现**：`peekKind() == tok.TOK_OF` 或 `isIdent("of")` 二者取或——`of` 在 lexer 里可能已被识别成专用 kind，也可能仍是普通标识符。
- **所有权 / 错误 / 调用**：无：转调 `peekKind`/`isIdent`，不分配、无 error。调用方：`usingDeclarationBindingIsOf`(`src/parser.zig:8389`)、for 头(10943)。

### `canTreatLetAsForInitializerExpression` (`src/parser.zig:2783`)

- **签名**：`fn canTreatLetAsForInitializerExpression(s: *State) bool`。
- **作用**：for 头里的 `let` 能否按普通表达式起始处理，而不是词法声明。
- **实现**：当前不是 `TOK_LET` 直接返回 false；是则把判定整体交给 `canTreatLetAsExpressionStatement(s, DeclMask{ .other = true })`，对应 qjs 在 for 初始化式与 for-in/of 头上调用的 `is_let(s, DECL_MASK_OTHER)`（quickjs.c:29164、quickjs.c:28703）。
- **所有权 / 错误 / 调用**：无分配、无 error：转调 `canTreatLetAsExpressionStatement`，那里的前瞻自己做快照与 token 释放并把失败吞成 bool。唯一调用方：for 初始化头 `src/parser.zig:9393`。

### `checkIdentArrowHead` (`src/parser.zig:3628`)

- **签名**：`fn checkIdentArrowHead(s: *State) Error!bool`。
- **作用**：判断当前的标识符后面是不是 `=>`（且中间无换行），即单参数箭头函数头。
- **实现**：先试轻量快路 `s.lex.simpleNextIsArrowNoLineTerminator()`：它只用不建 token 的简易扫描看下一个符号是不是 `=>`，给出确定答案（`?bool` 非 null）就直接返回。快路给不出答案（TypeScript 模式或遇到它不认的形态）时才快照 lexer 游标（`defer` 恢复），用 `nextRegexpAwareLookaheadKind` 取下一个 kind，要求它是 `TOK_ARROW` 且 `!s.lex.gotLineTerminator()`（`=>` 前不允许换行）；前瞻中的词法/语法错误经 `lookaheadErrorAsNoMatch` 降级成「不匹配」而不是报错。
- **所有权 / 错误 / 调用**：不分配：快路径 `simpleNextIsArrowNoLineTerminator` 只扫源码字节，慢路径的 peek token 由 `nextRegexpAwareLookaheadKind` 自己 `freeToken`，游标由 take/restore 快照成对回滚。经 `lookaheadErrorAsNoMatch` 过滤后，唯一还能上抛的 error 是 `error.OutOfMemory`——推测扫描里的语法错误一律变成「不匹配」。调用方：`checkArrowHead`(`src/parser.zig:3886`)、`async` 箭头判定(3990)。

### `checkAsyncArrowHeadAfterAsync` (`src/parser.zig:3642`)

- **签名**：`fn checkAsyncArrowHeadAfterAsync(s: *State) Error!bool`。
- **作用**：在当前 token 已确认是 `async` 的前提下，判断它是不是 async 箭头函数头。
- **实现**：入口就是 `std.debug.assert(s.isAsyncIdentifier())`——对照 QuickJS，只有 `token_is_pseudo_keyword(JS_ATOM_async)` 成功后才进这条路径，atom-id 判据留在调用方，普通标识符不会在这里白付一次投机快照。取 `takeLexerCursorSnapshot` 并 `defer restoreLexerCursorSnapshot` 之后，用 `nextRegexpAwareLookaheadKind` 取 `async` 后面那个 kind，词法/语法失败一律经 `lookaheadErrorAsNoMatch` 降级成「不匹配」（只有 OOM 上抛）。两条形态：该 kind 能当 AsyncArrowBindingIdentifier（`isAsyncArrowBindingIdentifierKind`；zjs 把 sloppy 上下文关键字词法成独立 kind，所以要在那里补收，对照 qjs `update_token_ident` quickjs.c:22738-22764）时，再取一个 kind 并要求它是 `TOK_ARROW`；否则必须是 `(`，交 `scanBalancedAfterOpening` 平衡扫描到配对的 `)`，要求 `closed` 且 `following == TOK_ARROW`。两处前瞻之后都查 `lex.gotLineTerminator()`：`async` 与参数之间、参数与 `=>` 之间有换行就不是 async 箭头（受限产生式）。
- **所有权 / 错误 / 调用**：同 `checkIdentArrowHead` 的协议（游标快照回滚、token 由被调方释放、经 `lookaheadErrorAsNoMatch` 后只剩 `error.OutOfMemory`）；括号形态转给 `scanBalancedAfterOpening`，它自己释放扫描 token。入口 `std.debug.assert(s.isAsyncIdentifier())` 要求调用方已确认当前 token 是 `async`。调用方 3 处：`src/parser.zig:3971`、4769、13689。

### `isAsyncArrowBindingIdentifierKind` (`src/parser.zig:3666`)

- **签名**：`fn isAsyncArrowBindingIdentifierKind(s: *State, kind: tok.TokenKind) bool`。
- **作用**：判断某个 token kind 能否充当 AsyncArrowBindingIdentifier。
- **实现**：`TOK_IDENT` 无条件为真；`s.is_strict` 或当前 `FunctionDef.is_strict_mode` 为真时其余一律为假。sloppy 下用一个 switch 补收 zjs 单独词法出来的上下文关键字：`TOK_YIELD`（仅在非 generator 里）、`TOK_STATIC`、`TOK_LET`，以及 `isSloppyFutureReservedToken` 那一组。`await` 刻意不收——+Await 下它作绑定名非法，尽管 qjs 在 sloppy 顶层接受 `async await => 1`（quickjs.c:22749-22756）。
- **所有权 / 错误 / 调用**：无：只读 `kind` 与 `is_strict`/`in_generator` 标志，不分配、无 error。唯一调用方 `checkAsyncArrowHeadAfterAsync`(`src/parser.zig:3852`)。

### `checkArrowHead` (`src/parser.zig:3681`)

- **签名**：`fn checkArrowHead(s: *State) Error!bool`。
- **作用**：判断当前位置是不是箭头函数头（`(` 参数表或单个标识符）。
- **实现**：对照 `js_parse_skip_parens_token`（quickjs.c:24194）：保存词法位置、用 scratch token 向前扫、再恢复，使缓存的 parser token 保持有效。当前 token 是 `(` 时先试 `lex.simpleCurrentParenIsArrowHead()` 这条不建快照的快路径，它给出确定答案就直接返回；给不出才 `scanBalancedToken(s, true)` 平衡扫描，要求 `closed` 且 `following == TOK_ARROW`，扫描失败经 `lookaheadErrorAsNoMatch` 降级成不匹配。当前 token 是 `TOK_IDENT` 时转 `checkIdentArrowHead`；其余 kind 一律 false。
- **所有权 / 错误 / 调用**：不分配：`simpleCurrentParenIsArrowHead` 快路径只读源码，慢路径 `scanBalancedToken` 内部负责快照与 token 释放；经 `lookaheadErrorAsNoMatch` 后只剩 `error.OutOfMemory` 会上抛。调用方 3 处：箭头函数入口 `src/parser.zig:3964`、关系表达式层 4768、13688。

### `lookaheadErrorAsNoMatch` (`src/parser.zig:3691`)

- **签名**：`fn lookaheadErrorAsNoMatch(err: Error) Error!bool`。
- **作用**：把前瞻过程中的失败降级成「不匹配」，只让 OOM 继续上抛。
- **实现**：一个 `switch (err)`：只把 `error.OutOfMemory` 原样返回，其余一律返回 `false`——投机扫描里的语法/词法错误是「这条形态不匹配」的信号，不应该成为最终诊断。
- **所有权 / 错误 / 调用**：无 self、不分配：把 `Error` 分成两类——`error.OutOfMemory` 继续上抛，其余一律压成 `false`，这样推测性前瞻不会把扫描中遇到的语法错误当成真的解析失败（pending 诊断可能被写脏，但位置最终由真正失败的那条路径覆盖）。调用方 5 处，全在箭头前瞻：`src/parser.zig:3833`、3847、3853、3858、3883。

### `diagnosticTokenFromToken` (`src/parser.zig:3703`)

- **签名**：`fn diagnosticTokenFromToken(s: *const State, found_token: *const tok.Token) DiagnosticToken`。
- **作用**：把一个 scratch token 折成诊断用的 `DiagnosticToken`（kind + 位置）。
- **实现**：offset 由 token 的起始指针减去源码缓冲起点得到；指针不落在源码缓冲内（合成 token）时取 0，并用 `@min` 夹到 `source.len` 以内。行列直接抄 token 的 `line_num` / `col_num`，结果只留 kind + 位置两项，不保留任何 payload。
- **所有权 / 错误 / 调用**：无分配、无 error：指针算术 + 抄 token 的行列，返回纯值 `DiagnosticToken`；不持有 token，调用方随后仍会 `freeToken`。调用方：`peekNextDiagnosticToken`(`src/parser.zig:3935`)、`scanBalancedAfterOpening`(13307)。

### `mapLookaheadLexerError` (`src/parser.zig:3719`)

- **签名**：`fn mapLookaheadLexerError(s: *State, err: lexer_mod.Error) Error`。
- **作用**：把 lexer 的 error 转成 parser 的 error：OOM 直穿，其余在 `lex.mark_*` 位置记一条诊断。
- **实现**：一个 `switch (err)`：`error.OutOfMemory` 原样返回（分配失败不是源码位置问题），其余以 `@errorName(err)` 为消息、`lex.mark_pos` / `mark_line` / `mark_col` 为位置调 `failWithMessage`——`mark_*` 记的是这次失败的 token 的起点，比当前 token 的位置更精确。
- **所有权 / 错误 / 调用**：不分配：把 `lexer_mod.Error` 收窄成 parser 的 `Error`——`error.OutOfMemory` 原样上抛，其余先经 `failWithMessage` 用 `lex.mark_*` 记 pending 诊断，再返回 `error.UnexpectedToken`。调用方 5 处前瞻/平衡扫描：`src/parser.zig:3933`、3945、3957、13303、13375。

### `peekNextDiagnosticToken` (`src/parser.zig:3730`)

- **签名**：`fn peekNextDiagnosticToken(s: *State) Error!DiagnosticToken`。
- **作用**：取当前 token 之后那一个 token 的 kind 与源码位置（`DiagnosticToken`），供 `failExpectedDescriptionAt` 把错误报在前瞻 token 上。
- **实现**：快照 lexer 游标并 `defer` 恢复，用 scratch token 调 `lex.nextInto`（`defer freeToken`），经 `diagnosticTokenFromToken` 折成只含 `kind` 与 `position` 的 `DiagnosticToken` 返回；词法失败经 `mapLookaheadLexerError` 转成 parser error（OOM 原样上抛，其余以 `@errorName(err)` 为消息、`lex.mark_*` 为位置走 `failWithMessage`）。只留下 kind 与位置，前瞻 token 80 字节的 payload 不外泄。
- **所有权 / 错误 / 调用**：peek token 由 `defer s.lex.freeToken` 释放、游标由快照回滚；返回的 `DiagnosticToken` 是纯值，不借 token 内存，所以调用方可以在 token 释放后继续用。错误经 `mapLookaheadLexerError`（`error.OutOfMemory` 或写了 pending 的 `error.UnexpectedToken`）。调用方 4 处：`src/parser.zig:5769`、对象/绑定列表 8744/8758/8767。

### `nextRegexpAwareLookaheadKind` (`src/parser.zig:3744`)

- **签名**：`fn nextRegexpAwareLookaheadKind(s: *State, previous_token_kind: ?tok.TokenKind) Error!tok.TokenKind`。
- **作用**：取下一个 token 的 kind（必要时把 `/` 重扫成正则），scratch token 不外泄。
- **实现**：在栈上开一个 `tok.Token`，`lex.nextInto` 取下一个 token（失败转 `mapLookaheadLexerError`），`defer freeToken` 保证 payload 不外泄；再交 `rescanLookaheadTokenIfRegexp` 按 `previous_token_kind` 决定要不要把 `/` / `/=` 从 mark 位置重扫成正则字面量；最后只返回 `lookahead_token.val`。对照 QuickJS `js_parse_skip_parens_token`：它在 parse state 里只留一个 `JSToken`、只把后随 token 的 kind 交出去；这里同样把投机 token 关在函数内，否则长括号前瞻的每一步都要拷贝 80 字节 payload。
- **所有权 / 错误 / 调用**：lookahead token 由本函数 `defer s.lex.freeToken` 释放一次——`rescanLookaheadTokenIfRegexp` 在重扫前会先释放旧 payload 再写入新 payload，槽位所有权始终在这里，不会双释放。错误经 `mapLookaheadLexerError` 收窄为 `error.OutOfMemory` 或 `error.UnexpectedToken`。调用方 3 处箭头前瞻：`src/parser.zig:3833`、3847、3853。

### `rescanLookaheadTokenIfRegexp` (`src/parser.zig:3752`)

- **签名**：`fn rescanLookaheadTokenIfRegexp(s: *State, lookahead_token: *tok.Token, previous_token_kind: ?tok.TokenKind) Error!void`。
- **作用**：前瞻 token 若是 `/` 或 `/=` 且该位置应当开始正则，就从斜杠处把它重扫成一个正则 token。
- **实现**：两道前置闸：前瞻 token 不是 `'/'` 也不是 `TOK_DIV_ASSIGN` 就原样返回；`predeclareSlashStartsRegexp(s, previous_token_kind)` 判定此处该读除法时也返回。两闸都过才重扫：先记下 `s.lex.mark_pos` 作为斜杠偏移，`freeToken` 释放旧 token，再 `lex.rescanRegexpInto(lookahead_token, slash_offset)` 原地写回正则 token；重扫失败经 `mapLookaheadLexerError` 转成 parser error。
- **所有权 / 错误 / 调用**：就地改写调用方的 token：确认是 regexp 起点后先 `s.lex.freeToken(lookahead_token)` 释放旧 payload，再 `rescanRegexpInto` 写入新 payload；槽位所有权仍归调用方，由它的 `defer freeToken` 最终释放。错误经 `mapLookaheadLexerError`（OOM 或 `error.UnexpectedToken`，`InvalidRegExp` 等在那里变成 pending 诊断）。调用方：`nextRegexpAwareLookaheadKind`(`src/parser.zig:3947`)、`scanBalancedAfterOpening`(13306)。

### `tokenStartsPrimaryExpression` (`src/parser.zig:4429`)

- **签名**：`fn tokenStartsPrimaryExpression(k: tok.TokenKind) bool`。
- **作用**：判断 token kind 能否作为 PrimaryExpression 的开头。
- **实现**：一条 `or` 链，覆盖数字/字符串/模板/`true`/`false`/`null`/`this`/`super`/`class`/`function`/标识符与 `let`、`yield`，以及 `(`、`[`、`{`、`/`、`/=`（后两者是正则字面量的起始形态）。
- **所有权 / 错误 / 调用**：无：纯 kind 比较，不看 `State`、不分配、无 error。唯一调用方 `tokenStartsYieldExpressionOperand`(`src/parser.zig:4655`)。

### `tokenStartsYieldExpressionOperand` (`src/parser.zig:4450`)

- **签名**：`fn tokenStartsYieldExpressionOperand(k: tok.TokenKind) bool`。
- **作用**：判断 `yield` 后面的 token 能否开始一个操作数。
- **实现**：`tokenStartsPrimaryExpression(k) and !tokenCanStartSlashRegexp(k)`，即在 PrimaryExpression 起始集合上再把 `/`、`/=` 排除掉。
- **所有权 / 错误 / 调用**：无：两张 kind 表的与运算，不分配、无 error。唯一调用方：`yield` 是否带操作数的判定 `src/parser.zig:4920`。

### `tokenCanStartSlashRegexp` (`src/parser.zig:4454`)

- **签名**：`fn tokenCanStartSlashRegexp(k: tok.TokenKind) bool`。
- **作用**：token kind 是否是 `/` 或 `/=`（可能是正则字面量的开头）。
- **实现**：纯 kind 比较：`'/'` 或 `tok.TOK_DIV_ASSIGN` 为真。斜杠开头的 token 在除法/正则两义之间，调用方拿到 true 后再用 `predeclareSlashStartsRegexp` 之类的上下文判据定夺。
- **所有权 / 错误 / 调用**：无：两个常量比较。调用方：for 头扫描 `src/parser.zig:2544`、`tokenStartsYieldExpressionOperand`(4655)。

### `escapedIdentifierIsReservedWordForShorthandBinding` (`src/parser.zig:6800`)

- **签名**：`fn escapedIdentifierIsReservedWordForShorthandBinding(s: *State, atom_id: Atom, has_escape: bool) bool`。
- **作用**：判断一个带转义写法的标识符用在对象简写绑定位置时，是否其实是保留字。
- **实现**：`has_escape` 为假直接返回 false（只有带 Unicode 转义的写法才需要这层检查）；`function.atoms.name(atom_id)` 取不到名字也返回 false。随后在 `escapedIdentifierIsReservedWordForBinding` 的结论上并入 `implements` / `interface` / `let` / `package` / `private` / `protected` / `public` / `static` / `yield` 这批名字——对象简写绑定 `{ \u0079ield }` 无论当前是否 strict 都不接受它们。
- **所有权 / 错误 / 调用**：不分配：名字经 `function.atoms.name(atom_id)` 借 atom 表做字节比较（这批保留字没有预定义 id，所以是字节比较而不是 id 比较），查不到名字返回 false。无 error。调用方：对象简写属性 `src/parser.zig:6927`、类名检查 14081。

### `escapedIdentifierIsReservedWordForCurrentContext` (`src/parser.zig:6817`)

- **签名**：`inline fn escapedIdentifierIsReservedWordForCurrentContext(s: *State, atom_id: Atom, has_escape: bool) bool`。
- **作用**：当前上下文下带转义的标识符是否是保留字；与 `ForBinding` 用同一套判定。
- **实现**：
函数体只有一行，直接转发 `escapedIdentifierIsReservedWordForBinding`。
- **所有权 / 错误 / 调用**：无：`inline` 转发到 `escapedIdentifierIsReservedWordForBinding`，不分配、无 error。调用方 4 处：label 判定 `src/parser.zig:2338`、箭头前瞻 3988、对象属性 6336、`export` 名字 9533。

### `isInvalidStrictFunctionBindingName` (`src/parser.zig:6821`)

- **签名**：`fn isInvalidStrictFunctionBindingName(s: *State, atom_id: Atom) bool`。
- **作用**：strict 下的函数绑定名是否非法，即是不是 `eval` / `arguments`。
- **实现**：把 `atom_id` 与 `atom_module.ids.eval_`、`atom_module.ids.arguments` 两个预定义 id 比较，命中任一即为真；`s` 形参未使用（`_ = s;`），判据与当前解析状态无关，strict 的判定由调用方负责。
- **所有权 / 错误 / 调用**：无分配、无 error：`s` 参数没用到（函数体第一行 `_ = s`），只比预定义 id `eval_`/`arguments`。调用方 3 处：`recordInvalidStrictParameterName`(`src/parser.zig:7042`)、函数名检查 11956、模块导出 15301。

### `recordInvalidStrictParameterName` (`src/parser.zig:6826`)

- **签名**：`fn recordInvalidStrictParameterName(s: *State, first: *?diagnostics.Position, atom_id: Atom) void`。
- **作用**：记下参数表里第一个 strict 非法绑定名的位置，供参数表结束后再决定是否报错。
- **实现**：仅当 `first.*` 还是 null（只记第一处）且 `isInvalidStrictFunctionBindingName` 判定该 atom 是 `eval` 或 `arguments` 时，把 `currentDiagnosticPosition()` 写进 `first.*`。自身从不报错——参数表解析时还不知道函数体里有没有 "use strict"，真正的报错由 `rejectInvalidStrictParameterName` 在结尾按这个位置补发。
- **所有权 / 错误 / 调用**：不分配：把第一处非法名字的位置写进调用方栈上的 `?diagnostics.Position`（out 参数），已有值就不覆盖；位置取自 `currentDiagnosticPosition`，因此必须在该参数的 token 还是当前 token 时调用。无 error。调用方 5 处参数列表解析：`src/parser.zig:11326`、11429、12251、12282、12367。

### `rejectInvalidStrictParameterName` (`src/parser.zig:6832`)

- **签名**：`fn rejectInvalidStrictParameterName(s: *State, first: ?diagnostics.Position) Error!void`。
- **作用**：若先前记过非法参数名的位置，就在那个位置报语法错误。
- **实现**：`first` 为 null（参数表里没出现过可疑名字）直接返回；否则在那个先前记下的位置调 `failWithMessage(position, "invalid binding name in strict parameter list")`——报错点回到第一个非法参数名，而不是发现 strict 指令时的当前位置。
- **所有权 / 错误 / 调用**：不分配；`first` 为 null 时静默返回（非严格或没有非法名字），否则 `failWithMessage` 报 `error.UnexpectedToken`——消息是字面量，位置是当初记下的那个。与 `recordInvalidStrictParameterName` 配对，调用方 4 处：`src/parser.zig:11962`、12253、12440、12480。

### `canUseAwaitAsIdentifier` (`src/parser.zig:6837`)

- **签名**：`fn canUseAwaitAsIdentifier(s: *State) bool`。
- **作用**：当前上下文能否把 `await` 当成普通标识符（非 async 函数、非 module、非 class static block）。
- **实现**：三个状态位取反后相与：`!s.in_async and !s.lex.is_module and !s.in_class_static_block`——只有三者都不成立时 `await` 才不是保留字。
- **所有权 / 错误 / 调用**：无：读 `in_async` / `lex.is_module` / `in_class_static_block` 三个标志，不分配、无 error。11 处调用，都是 `await` 能否当标识符用的判定。

### `isIdentifierLikeToken` (`src/parser.zig:6841`)

- **签名**：`fn isIdentifierLikeToken(s: *State) bool`。
- **作用**：当前 token 能否当作绑定标识符使用（含各种上下文相关关键字）。
- **实现**：一条 `or` 链：`TOK_IDENT`；`TOK_AWAIT` 且 `canUseAwaitAsIdentifier`；`TOK_YIELD` 且非 generator、非 strict；`isSloppyFutureReservedBindingToken`（它自己再夹一层 sloppy 判据）；以及 sloppy 下的 `TOK_STATIC` / `TOK_LET`。后几项存在的原因是 zjs 把这些上下文关键字词法成了独立 kind，而它们在 sloppy 下本来就是合法标识符。
- **所有权 / 错误 / 调用**：无分配、无 error：只看当前 token 的 kind 与严格/generator/module 上下文。16 处调用，覆盖 catch 参数、绑定名、`using` 声明、label(`src/parser.zig:2334`、9528、9943、10545 等)。

### `isSloppyFutureReservedBindingToken` (`src/parser.zig:6850`)

- **签名**：`fn isSloppyFutureReservedBindingToken(s: *State) bool`。
- **作用**：非 strict 下当前 token 是否是 future reserved word（这时它还能当绑定名）。
- **实现**：先要求非 strict（`s.is_strict` 与 `curFunc().is_strict_mode` 都为假），再由 `isSloppyFutureReservedToken` 判当前 kind 是否落在 `TOK_IMPLEMENTS` / `TOK_INTERFACE` / `TOK_PACKAGE` / `TOK_PRIVATE` / `TOK_PROTECTED` / `TOK_PUBLIC` 这组里。这些词 zjs 在 lexer 就给了专用 kind，所以 sloppy 下要在这里补回「其实可以当标识符」。
- **所有权 / 错误 / 调用**：无：两个标志加一次查表，不分配、无 error。调用方 3 处：`isIdentifierLikeToken`(`src/parser.zig:7060`)、绑定判定 10541、10842。

### `isSloppyFutureReservedToken` (`src/parser.zig:6854`)

- **签名**：`fn isSloppyFutureReservedToken(kind: tok.TokenKind) bool`。
- **作用**：判断 kind 是否属于 future reserved word 这一组。
- **实现**：一个 switch，只对 `TOK_IMPLEMENTS` / `TOK_INTERFACE` / `TOK_PACKAGE` / `TOK_PRIVATE` / `TOK_PROTECTED` / `TOK_PUBLIC` 六个 kind 返回 true，其余 else 为 false。这六个只在 strict 下才是保留字，sloppy 下可作标识符。
- **所有权 / 错误 / 调用**：无：无 `State` 参数的纯 switch，不分配、无 error。调用方 3 处：`isAsyncArrowBindingIdentifierKind`(`src/parser.zig:3871`)、`isSloppyFutureReservedBindingToken`(7066)、`let` 判定 10020。

### `tokenCanStartExpression` (`src/parser.zig:6867`)

- **签名**：`fn tokenCanStartExpression(kind: tok.TokenKind) bool`。
- **作用**：判断 token kind 能否开始一个表达式。
- **实现**：一条 `or` 链，列出标识符、`await`、`yield`、数字/字符串、`true`/`false`/`null`/`this`、`function`、`class` 与 `(`、`[`、`{`。与 `tokenStartsPrimaryExpression` 相比多了 `await`，少了模板、`super`、`let`、`/`、`/=`——它用在「这里还有没有表达式」这类粗判上，不做正则/除号的消歧。
- **所有权 / 错误 / 调用**：无：纯 kind 表，不分配、无 error。唯一调用方：`yield` 后能否接表达式的判定 `src/parser.zig:4976`。

### `identifierLikeAtom` (`src/parser.zig:6884`)

- **签名**：`fn identifierLikeAtom(s: *State) Atom`。
- **作用**：取当前这个「像标识符」的 token 对应的 atom：`TOK_IDENT` 取 payload 里的 atom，关键字取 `tok.keywordAtom(kind)`。
- **实现**：一个三元：`TOK_IDENT` 取 `token.payload.ident.atom`，否则按关键字 kind 查 `tok.keywordAtom(kind)`。返回的是借用的 id（源码处标了 `borrowed-atom`）：TGC S3-c 之后 token 不再持 atom 的引用计数，`advance()` 只换掉 token payload，这个 id 由整场编译的 `CompileAtomScope` 根列表钉住，跨 `advance()` 仍然有效；源码注释原先写的「valid only until advance(); retain via identifierLikeAtom」是 rc 时代的遗留，已改成「借用 id，由 CompileAtomScope 作根」；`identifierLikeAtom` 今天只是本函数的同义转发，名字留给那些把 id 交进更长寿表的调用点。
- **所有权 / 错误 / 调用**：返回的是**借用**的 atom id：`TOK_IDENT` 取 `token.payload.ident.atom`，否则取 `tok.keywordAtom(kind)` 的预定义 id。TGC S3-c 后这个 id 没有引用计数，`advance` 释放的只是 token payload，不碰 atom；编译期 intern 的 id 由 `CompileAtomScope`（`src/core/atom.zig:2448`，注册成 GC RootProvider）钉到编译结束，所以取走的 id 在整场编译内有效——源码 `src/parser.zig:7101` 那行「valid only until advance()」是 S3-c 之前的遗留注释。无 error。12 处调用方，如 label(`src/parser.zig:2337`)、对象属性(6366)、`import`/`export` 名(9531/9945)。

### `identifierLikeAtom` (`src/parser.zig:6892`)

- **签名**：`fn identifierLikeAtom(s: *State) Atom`。
- **作用**：与 `identifierLikeAtom` 取同一个 atom，用在需要标注「调用方要负责其寿命」的位置。
- **实现**：
函数体只有一行，直接转发 `identifierLikeAtom`：当前 atom 表实现下不需要额外 retain。
- **所有权 / 错误 / 调用**：现在与 `identifierLikeAtom` 完全等价（函数体只有一行转调）：S3-c 之前这里负责 retain，atom 不再计数后名字里的 "Owned" 只剩历史含义，返回的仍是借用的 id，调用方不需要也不应该释放。无 error。调用方 7 处，都是要把名字留到 `advance` 之后的地方：枚举名 `src/parser.zig:8706`、namespace 名 8826、catch 参数 9821、绑定名 10791/10848、形参名 11325/12281。

### `identifierLikeHasInvalidEscapeForBinding` (`src/parser.zig:6896`)

- **签名**：`fn identifierLikeHasInvalidEscapeForBinding(s: *State) bool`。
- **作用**：当前标识符 token 是否用转义写了一个保留字（出现在绑定位置即非法）。
- **实现**：只对 `TOK_IDENT` 生效（其余 kind 直接 false），把 token 自己的 `payload.ident.atom` 与 `has_escape` 转交 `escapedIdentifierIsReservedWordForBinding` 判定——即 `l\u0065t` 这类用转义写出来的保留字，出现在绑定位置时非法。
- **所有权 / 错误 / 调用**：无分配、无 error：读当前 token 的 `has_escape` 与 atom，转调 `escapedIdentifierIsReservedWordForBinding`。8 处调用，都是绑定名位置的转义保留字拒绝(`src/parser.zig:9944`、10788、11427、12249 等)。

### `expectPunct` (`src/parser.zig:7099`)

- **签名**：`fn expectPunct(s: *State, ch: u8) Error!void`。
- **作用**：要求下一个 token 匹配给定种类，否则诊断失败。
- **实现**：`isPunct(ch)` 为假时 `return s.failExpectedToken(ch)` 报 `expected 'c', got X`；匹配则 `advance` 消费。与 `expectToken` 的差别只是入参用字符字面量（`':'`、`')'`）而非 kind 常量。
- **所有权 / 错误 / 调用**：不分配；不是该标点即 `failExpectedToken(ch)` 给出 `error.UnexpectedToken`，否则失败只来自 `advance`。18 处调用方：条件运算的 `':'`(`src/parser.zig:4679`)、下标 `']'`(5852/5928/5976)、参数表 `'('`/`')'`(6140/6161/6186) 等。

### `numberIsExactI32` (`src/parser.zig:7104`)

- **签名**：`fn numberIsExactI32(value: f64) bool`。
- **作用**：判断一个 f64 是否精确等于某个 i32（数字字面量能否降成 i32 常量）。
- **实现**：三道闸：NaN / Inf 直接 false；值落在 `minInt(i32)`..`maxInt(i32)` 之外 false；最后 `@intFromFloat` 截断再 `@floatFromInt` 回来，与原值相等才为真——这一步把带小数部分的值滤掉。
- **所有权 / 错误 / 调用**：无：纯浮点判定（NaN/Inf、i32 范围、round-trip），无 `State`、不分配、无 error。调用方：字面量折叠成 `push_i32` 的两处 `src/parser.zig:4820`、6242。

### `skipFunctionInPredeclareScan` (`src/parser.zig:7729`)

- **签名**：`fn skipFunctionInPredeclareScan(s: *State) Error!void`。
- **作用**：在预扫描/前瞻里整块跳过一个函数：先找到 `{`，再按花括号深度吃到配对的 `}`。
- **实现**：两段循环。第一段一路取 token 直到遇到 `'{'`（函数体开始）或 `TOK_EOF`（直接返回，不报错）；第二段从 `depth = 1` 起按 `'{'` / `'}'` 增减深度扫到配对为止，其中 `TOK_TEMPLATE` 转 `skipTemplateInPredeclareScan` 整块跳过，`'/'` 与 `TOK_DIV_ASSIGN` 交给 `skipRegexpInPredeclareScan`，被判成正则时把 `previous_token_kind` 记成 `TOK_REGEXP` 后 `continue`。全程用 scratch token（`lex.nextInto` + `defer freeToken`），不动 `s.token`，也不恢复游标（由调用方负责）。
- **所有权 / 错误 / 调用**：每个临时 token 都 `defer s.lex.freeToken`（释放解码出的字符串字节），不动 `s.token`——推进游标正是它的目的，回滚由调用方的快照负责。错误直接上抛：`lex.nextInto` 的词法错误与 OOM，以及 `skipTemplateInPredeclareScan` 的 `Error.ParserInvariant`。调用方 3 处：`rhsContainsDirectEval`(`src/parser.zig:2630`)、`templateContainsDirectEval`(2710) 把它 `catch` 成 bool，模板扫描 8199 用 `try`。

### `skipTemplateInPredeclareScan` (`src/parser.zig:7760`)

- **签名**：`fn skipTemplateInPredeclareScan(s: *State, first: tok.Token) Error!void`。
- **作用**：在预扫描/前瞻里整块跳过一个模板字面量，含其所有 `${}` 替换表达式。
- **实现**：先看传入的首段 `first.payload.str.template`：payload 不是模板说明调用方传错，返回 `Error.ParserInvariant`；`.no_substitution` / `.tail` 表示没有后续替换表达式，直接返回；`.head` / `.middle` 才进入循环。外层每轮扫一个 `${...}` 内的表达式：内层按 `'{' '(' '['` / `'}' ')' ']'` 维护 `expr_depth`，`TOK_FUNCTION` 转 `skipFunctionInPredeclareScan`、嵌套 `TOK_TEMPLATE` 递归本函数、`'/'` 与 `TOK_DIV_ASSIGN` 交给 `skipRegexpInPredeclareScan`，`TOK_EOF` 直接返回。深度为 0 的 `'}'` 结束当前替换表达式，外层随即用 `lex.nextTemplatePartAfterBraceInto` 取下一段（它从 `}` 之后按模板规则继续扫）：`.tail` / `.no_substitution` 收尾返回，`.head` / `.middle` 继续下一轮。
- **所有权 / 错误 / 调用**：每个 `nextInto` / `nextTemplatePartAfterBraceInto` 出来的 token 都 `defer freeToken`；`first` 由调用方持有，本函数只读它的 `payload.str.template`。特有错误来源：`first`（或后续部件）不是模板 payload 时返回 `Error.ParserInvariant`，走 ICE 通道而非语法错误；其余错误来自词法层。调用方 5 处：for 头扫描 `src/parser.zig:2539`、`skipFunctionInPredeclareScan`(8167)、自递归(8202)、`scanBalancedAfterOpening`(13311)、类体扫描(14637)。

### `skipRegexpInPredeclareScan` (`src/parser.zig:7815`)

- **签名**：`fn skipRegexpInPredeclareScan(s: *State, previous_token_kind: ?tok.TokenKind) Error!bool`。
- **作用**：预扫描里把当前 `/` 位置按需重扫成正则 token 并丢弃，返回它是否真被当成了正则。
- **实现**：先由 `predeclareSlashStartsRegexp(s, previous_token_kind)` 定夺：判成除法就返回 false，一个 token 都不动。判成正则时记下 `lex.mark_pos`（斜杠所在偏移），`lex.rescanRegexpInto` 到 scratch token 并 `defer freeToken`——只为把 lexer 游标推过整个正则字面量（含标志位），token 本身丢弃，返回 true。
- **所有权 / 错误 / 调用**：重扫出来的 regexp token 由 `defer s.lex.freeToken` 释放；不回滚游标（吞掉整个 regexp 字面量就是目的）。错误来自 `lex.rescanRegexpInto`（`InvalidRegExp`、`UnterminatedRegExp`、OOM 等），原样上抛。调用方 6 处：三处推测扫描 `catch` 成 bool(`src/parser.zig:2545`、2637、2722)，三处 `try`(8169、8207、14631)。

### `predeclareSlashStartsRegexp` (`src/parser.zig:7825`)

- **签名**：`fn predeclareSlashStartsRegexp(s: *State, previous_token_kind: ?tok.TokenKind) bool`。
- **作用**：按前一个 token 判断此处的 `/` 是正则字面量开头还是除号。
- **实现**：`previous_token_kind` 为 null（表达式起始）时默认 true。两条上下文修正先行：sloppy 非 generator 下的 `TOK_YIELD`、以及 `canUseAwaitAsIdentifier` 成立时的 `TOK_AWAIT`，此刻都是普通标识符即「值」，其后的 `/` 是除法，返回 false。其余由一张 switch 列出「后面可以跟正则」的前驱：`( [ { , ; : ? = ! ~ + - * % & | ^`、`TOK_ARROW`、全部比较/相等/移位/逻辑/幂运算符、全部复合赋值（含 `TOK_DIV_ASSIGN`、`TOK_DOUBLE_QUESTION_MARK_ASSIGN`）、以及 `return` / `case` / `throw` / `delete` / `void` / `typeof` / `new` / `in` / `instanceof` / `yield` / `await` / `of`；未列出的（标识符、字面量、`)`、`]`、`}` 等「值」结尾）返回 false。
- **所有权 / 错误 / 调用**：无分配、无 error：只按前一个 token 的 kind 加严格/generator 上下文查表决定 `/` 是除号还是 regexp 起点。调用方：`rescanLookaheadTokenIfRegexp`(`src/parser.zig:3953`)、`skipRegexpInPredeclareScan`(8236)。

### `usingDeclarationStart` (`src/parser.zig:7904`)

- **签名**：`fn usingDeclarationStart(s: *State) bool`。
- **作用**：判断当前位置是不是 `using x` 声明的开头。
- **实现**：要求当前 token 是无转义的标识符 `using`（`peekKind() == TOK_IDENT` 且 `isIdent("using")` 且 `has_escape` 为假）；再用 `peekNextKindWithLineTerminator` 一次前瞻拿下一个 kind 与换行标志，`using` 与绑定名之间出现换行即否（ASI 会把 `using` 断成一条表达式语句）；最后由 `tokenKindCanStartUsingBinding` 判下一个 kind 能不能当绑定名。
- **所有权 / 错误 / 调用**：自己不碰 token 所有权：前瞻交给 `peekNextKindWithLineTerminator`（那里负责 `freeToken` 与游标回滚）。无 error——前瞻失败在那边被吞成 `TOK_EOF`，这里因此返回 false。调用方 3 处：`directUsingDeclarationKind`(`src/parser.zig:8355`)、`advanceUsingDeclarationPrefixForLookahead`(8372)、语句层 9137。

### `awaitUsingDeclarationStart` (`src/parser.zig:7913`)

- **签名**：`fn awaitUsingDeclarationStart(s: *State) bool`。
- **作用**：判断当前位置是不是 `await using x` 声明的开头。
- **实现**：当前 token 必须是 `TOK_AWAIT`，然后快照 lexer 游标（`defer` 恢复）做两步前瞻：第一步取的 token 要是无转义的标识符且 `atomNameEquals(..., "using")`，第二步取的 token 由 `tokenKindCanStartUsingBinding` 判定；两步之前各查一次 `lex.gotLineTerminator()`，任一处有换行即返回 false。任何词法失败一律返回 false（前瞻不报错）。
- **所有权 / 错误 / 调用**：自己开游标快照并连读两个 token，两个都 `defer s.lex.freeToken`，`defer restoreLexerCursorSnapshot` 回滚游标；名字比较走 `atomNameEquals`（借 atom 表）。无 error：任何词法失败（含 OOM）都吞成 false。调用方 3 处：`directUsingDeclarationKind`(`src/parser.zig:8354`)、`advanceUsingDeclarationPrefixForLookahead`(8377)、语句层 9172。

### `directUsingDeclarationKind` (`src/parser.zig:7933`)

- **签名**：`fn directUsingDeclarationKind(s: *State) ?DisposalHint`。
- **作用**：识别直接写在语句位置的 using 声明，返回 `.async` / `.sync`，都不是则 null。
- **实现**：先试 `awaitUsingDeclarationStart` 返回 `.async`，再试 `usingDeclarationStart` 返回 `.sync`，都不成立返回 null。`await` 分支必须先试，否则 `await using x` 会被当成 `await` 表达式。
- **所有权 / 错误 / 调用**：无：两次前瞻判定的组合，所有权与错误都在被调方处理，本函数不分配、无 error。调用方：for 头 `src/parser.zig:9385`、绑定列表 10772。

### `tokenKindCanStartUsingBinding` (`src/parser.zig:7939`)

- **签名**：`fn tokenKindCanStartUsingBinding(s: *State, kind: tok.TokenKind) bool`。
- **作用**：判断某个 token kind 能否作为 using 声明的绑定名。
- **实现**：一条析取式：`TOK_IDENT` 恒成立；`TOK_AWAIT` 要 `canUseAwaitAsIdentifier`；`TOK_YIELD` 要非 generator 且非 strict；sloppy 下再放行 `TOK_STATIC` / `TOK_LET` 与六个 future reserved word（`TOK_IMPLEMENTS` / `TOK_INTERFACE` / `TOK_PACKAGE` / `TOK_PRIVATE` / `TOK_PROTECTED` / `TOK_PUBLIC`）——这些词 zjs 在 lexer 就给了专用 kind，sloppy 下要在此处认回它们是合法绑定名。
- **所有权 / 错误 / 调用**：无分配、无 error：纯 kind + 严格模式/generator 判定，`using x` 里 `x` 的合法起始 token 集合。调用方：`usingDeclarationStart`(`src/parser.zig:8330`)、`awaitUsingDeclarationStart`(8350)。

### `advanceUsingDeclarationPrefixForLookahead` (`src/parser.zig:7949`)

- **签名**：`fn advanceUsingDeclarationPrefixForLookahead(s: *State, kind: DisposalHint) bool`。
- **作用**：在前瞻中吃掉 using 声明的前缀：`.sync` 前进一次，`.async` 前进两次（`await` 与 `using`）。
- **实现**：按 `kind` 分两臂，各自先重新确认起始形态再推进：`.sync` 要 `usingDeclarationStart` 成立后 `advance` 一次（吃掉 `using`）；`.async` 要 `awaitUsingDeclarationStart` 成立后 `advance` 两次（吃掉 `await` 与 `using`）。任一确认失败或 `advance` 出错都返回 false，错误被吞掉不上抛——调用方只是在前瞻。
- **所有权 / 错误 / 调用**：会真的推进 `s.token`（`.sync` 调一次 `advance`、`.async` 调两次），所以只能在 `takeParserSnapshot` 的保护下调用；`advance` 的错误（含 OOM）被 `catch return false` 吞掉，本函数无 error。唯一调用方 `usingDeclarationBindingIsOf`(`src/parser.zig:8388`)，快照与恢复都由它负责。

### `usingDeclarationBindingIsOf` (`src/parser.zig:7965`)

- **签名**：`fn usingDeclarationBindingIsOf(s: *State, kind: DisposalHint) Error!bool`。
- **作用**：`for (using of ...)` 的消歧：吃掉 using 前缀后，绑定位置上的是不是 `of`。
- **实现**：整段包在 `takeParserSnapshot` + `defer restoreParserLexerSnapshot` 里，所以可以真的调 `advance` 推进：先 `advanceUsingDeclarationPrefixForLookahead` 吃掉 `using` / `await using` 前缀（失败即 false），再用 `s.isOfToken()` 看落点是不是 `of`。据此把 `for (using of x)`（`using` 是绑定名）与 `for (using x of y)`（using 声明）分开。
- **所有权 / 错误 / 调用**：唯一的分配来自 `takeParserSnapshot` 里的 `lex.dupToken`，它也是本函数唯一的 error 来源（`error.OutOfMemory`，用 `try` 上抛）；`defer restoreParserLexerSnapshot` 负责释放扫描中的 `s.token` 并把副本装回去——取了快照不恢复就会泄漏那份副本。前瞻推进本身的失败被 `advanceUsingDeclarationPrefixForLookahead` 吞成 false。唯一调用方：for 头的 `using ... of` 判定 `src/parser.zig:10774`。

### `takeParserSnapshot` (`src/parser.zig:12731`)

- **签名**：`fn takeParserSnapshot(s: *State) Error!ParserSnapshot`。
- **作用**：为投机解析存档：lexer 游标、当前 token 的深拷贝，以及发射端的各个长度水位。
- **实现**：逐字段填 `ParserSnapshot`：lexer 的 `pos` / `line` / `col` / `got_lf` 与 `mark_pos` / `mark_line` / `mark_col`；`lex.dupToken(s.token)` 深拷当前 token（唯一会分配的一项，注释对照 qjs 投机扫描用的 `reparse_ident_token`——扫描会消费掉 token 的持有者，所以必须整份 payload 留底）；`last_token_end_offset` / `last_token_line_num` / `last_token_col_num`、`last_opcode_source_offset` 与 `curFunc().last_opcode_pos`；以及回滚发射用的水位 `code_len` / `atom_len` / `source_loc_len`（后者按 `emit_to_function_def` 在 `curFunc()` 与 `function` 之间选）、`label_count` 和 `features` 集合。
- **所有权 / 错误 / 调用**：只有 `dupToken` 会分配，失败即 `error.OutOfMemory`；快照里那份 token 的所有权在拿到后由 `restoreParserLexerSnapshot` 接管（装回 `s.token`），所以取了快照就必须恢复，否则泄漏。

### `restoreParserLexerSnapshot` (`src/parser.zig:12759`)

- **签名**：`fn restoreParserLexerSnapshot(s: *State, snapshot: ParserSnapshot) void`。
- **作用**：把 lexer 游标与当前 token 回滚到快照状态（只回滚扫描状态）。
- **实现**：先 `lex.freeToken(&s.token)` 释放投机期间换进来的 token，再写回七个游标字段（`pos` / `line` / `col` / `got_lf` 与 `mark_pos` / `mark_line` / `mark_col`），把快照里那份 `dupToken` 深拷贝装回 `s.token`，最后恢复 `last_token_end_offset` / `last_token_line_num` / `last_token_col_num`。`ParserSnapshot` 里同时存着的 `code_len` / `atom_len` / `source_loc_len` / `label_count` / `features` / `last_opcode_*` 这些发射水位**不**在这里回滚，由调用方自己截断。
- **所有权 / 错误 / 调用**：所有权交接点：先 `s.lex.freeToken(&s.token)` 释放推测扫描期间换上的 token payload，再把 `takeParserSnapshot` 用 `dupToken` 复制的副本装回 `s.token`（自此所有权归 `State`，最终由 `State.deinit` 或下一次 `advance` 释放），游标与 `last_token_*` 一并回滚。不分配、无 error。唯一调用方：`usingDeclarationBindingIsOf` 的 defer(`src/parser.zig:8387`)。

### `takeLexerCursorSnapshot` (`src/parser.zig:12788`)

- **签名**：`fn takeLexerCursorSnapshot(s: *State) LexerCursorSnapshot`。
- **作用**：只存 lexer 游标（`pos` / `line` / `col` / `got_lf` 与 `mark_*`），不碰 token，不分配。
- **实现**：把 `lex` 的七个游标字段（`pos` / `line` / `col` / `got_lf` / `mark_pos` / `mark_line` / `mark_col`）复制进一个值类型返回。不碰 `s.token`、不分配，因此可以在热前瞻路径上随手取，恢复时由 `restoreLexerCursorSnapshot` 原样写回。
- **所有权 / 错误 / 调用**：无分配、无 error：只抄 7 个游标/行列字段的纯值，**不碰 token 所有权**——配它的前瞻必须自己 `freeToken`，需要连 `s.token` 一起保存的场合用的是 `takeParserSnapshot`。15 处调用，全部与 `restoreLexerCursorSnapshot` 成对(`src/parser.zig:2468`、2477、2489、2499、2514、2589、3830、3844 等)。

### `restoreLexerCursorSnapshot` (`src/parser.zig:12800`)

- **签名**：`fn restoreLexerCursorSnapshot(s: *State, snapshot: LexerCursorSnapshot) void`。
- **作用**：把 lexer 游标写回快照值，使投机扫描期间借用的 `s.token` 继续有效。
- **实现**：把 `LexerCursorSnapshot` 的七个字段（`pos` / `line` / `col` / `got_lf` / `mark_pos` / `mark_line` / `mark_col`）逐个写回 `s.lex`。不分配、不触碰 `s.token`——这正是它与 `restoreParserLexerSnapshot` 的分工：只回滚游标的场合，`s.token` 自始至终没被换过。
- **所有权 / 错误 / 调用**：无分配、无 error：把 7 个字段写回 `lex`，不释放任何 token——用它的前瞻期间 `s.token` 没被换过（换过的场合走 `restoreParserLexerSnapshot`）。15 处调用，与 `takeLexerCursorSnapshot` 一一成对，多数写在 `defer` 里。

### `scanBalancedAfterOpening` (`src/parser.zig:12823`)

- **签名**：`fn scanBalancedAfterOpening(s: *State, opening: tok.TokenKind, no_line_terminator: bool) Error!BalancedTokenScan`。
- **作用**：开括号已被消费后，平衡扫描到配对的闭括号，并报告后随 token 与几项拓扑标记。
- **实现**：
已消费开括号后，平衡扫描到匹配闭括号。用一个固定的 `delimiters: [256]u8` 栈（对照 QuickJS 的 `state[256]`，`delimiters[0] = 0` 是下溢哨兵，开括号放在下标 1，`level` 从 2 起步）跟踪 `()`/`[]`/`{}`；模板由 `skipTemplateInPredeclareScan` 整体跳过，`/`、`/=` 由 `rescanLookaheadTokenIfRegexp` 按需重扫成正则；嵌套函数没有特殊处理，只按花括号配对。扫描用 scratch token，`s.token` 全程借用有效，本函数自己不恢复游标（由调用方的快照负责）。栈溢出、括号失配、闭括号过多或 EOF 都把 `result.failure` 填成当前 `DiagnosticToken` 并提前返回。沿途记录 `has_top_level_semicolon`（level==2 的 `;`）、`has_top_level_ellipsis`（level==2 的 `...`）与 `has_assignment`（任意 `=`）；标识符 `of` 与 `yield` 会把 `previous_token_kind` 归一成 `TOK_OF`，供正则判定使用。闭合后再取一个 token 作为 `following`，`no_line_terminator` 且中间有换行时 `following` 报成 `'\n'`。给箭头 cover、解构 topology、for 头分类提供 lookahead，不发射字节码。
- **所有权 / 错误 / 调用**：分隔符栈是 256 字节的栈数组（对齐 qjs 的 `state[256]`），不分配；每个 scratch token 与末尾的 `following` token 都 `defer s.lex.freeToken`。游标不回滚——调用方（`scanBalancedToken` 或箭头前瞻）负责快照。错误只有两类：`lex.nextInto` 经 `mapLookaheadLexerError` 变成 `error.OutOfMemory` 或写了 pending 的 `error.UnexpectedToken`，以及 `skipTemplateInPredeclareScan` 的 `Error.ParserInvariant`；括号不匹配、深度溢出、EOF 都不是 error，而是写进返回值的 `failure` 字段。调用方：`checkAsyncArrowHeadAfterAsync`(`src/parser.zig:3858`)、`scanBalancedToken`(13430)。

### `scanBalancedToken` (`src/parser.zig:12916`)

- **签名**：`fn scanBalancedToken(s: *State, no_line_terminator: bool) Error!BalancedTokenScan`。
- **作用**：从当前的 `(` / `[` / `{` 开始做平衡扫描；先试纯 ASCII 快路，不行再走完整 lexer 扫描。
- **实现**：当前 token 不是 `'('` / `'['` / `'{'` 之一时报 `expected opening delimiter`（`failExpectedDescription`）。非 TypeScript 输入先试 `simple_token.balancedAfterOpen(source, lex.pos, opening, no_line_terminator)` 的借用式快扫（不建 token、不分配），命中且 `simple.closed` 时把 `simple.following` 映射回 token kind（`arrow` → `TOK_ARROW`、`assignment` → `'='`、`in_keyword` → `TOK_IN`、`line_terminator` → `'\n'`、`other` / `eof` → `TOK_EOF` 等），连同 `has_top_level_semicolon` / `has_top_level_ellipsis` / `has_assignment` 直接返回。快扫不适用（TypeScript、模板、转义、非 ASCII 等上下文敏感输入）或没扫到配对时，快照游标（`defer` 恢复）后转由 `scanBalancedAfterOpening` 用真 lexer 走一遍。
- **所有权 / 错误 / 调用**：快路径 `simple_token.balancedAfterOpen` 只读源码切片，不建 token、不分配；慢路径先 `takeLexerCursorSnapshot` 再进 `scanBalancedAfterOpening`（token 在那里释放），`defer` 回滚游标。本函数自己产生的唯一错误是开头不是 `(`/`[`/`{` 时 `failExpectedDescription("opening delimiter")` 的 `error.UnexpectedToken`，其余错误来自慢路径。调用方 3 处：`checkArrowHead`(`src/parser.zig:3883`)、类成员 12606、13521。

## 覆盖核对

- 清单函数数（本文件分到）: 83（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 83
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
