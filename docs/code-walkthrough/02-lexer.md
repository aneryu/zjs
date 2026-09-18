# 02 — Lexer：词法扫描与前瞻

本册覆盖 `src/lexer.zig` 与 `src/simple_token.zig`。词法器把源字节变成 `parser.token.Token`，parser 用它做递归下降、模板续扫、regexp 重扫和箭头前瞻。TypeScript 只做语法擦除，不进类型检查。

子文件：

- [02-lexer.md](02-lexer.md)（本文件）：`namespace`、`LexerImpl` 热路径、标识符/数字/字符串/模板/regexp/标点
- [02-lexer-typescript.md](02-lexer-typescript.md)：`enableTypeScript` 之后的擦除区间与 TS 粗词法
- [02-lexer-simple-token.md](02-lexer-simple-token.md)：非持有的 `simple_next_token` 子集

权威仍是源码与 ECMA-262。`lexer.zig` 对齐 QuickJS `quickjs.c:21794..23200` 的 `next_token` / `js_parse_string` / `js_parse_template_part` / `js_parse_regexp`。token 整数 id 在 `parser.zig` 的 `token` 命名空间，不在本文件。

## 和 parser 怎么配合

`parser.zig:265` 用 `lexer.namespace(token)` 实例化本文件。生产入口 `compileQjsProgram`（`parser.zig:16180`）构造 `Lexer`，按 `options.mode == .module`（`is_strict_mode` 还或上 `options.strict`）设 `is_strict_mode` / `is_module`，再按 `shouldStrip` 决定是否 `enableTypeScript()`。

| 协作点 | parser 侧 | lexer / simple_token |
| --- | --- | --- |
| 消费 token | `State.advance` 调 `nextIntoReplacing` | 先 `releaseTokenPayload` 再 `nextInto`，热路径不拷贝大 `Token` |
| 首 token | `ParseState` 初始化 | `nextInto` |
| 行终结 | ASI、`throw`/`return`/`break`、箭头 | `got_lf` / `gotLineTerminator`；trivia 里看到 LF/LS/PS 才置位 |
| 模板 | 替换表达式后 lookahead 已吃掉 `}` | `nextTemplatePartAfterBraceInto`（`pos` 已过 `}`，不再 bump） |
| 模板（pos 在 `}`） | 测试 / 非 lookahead 路径 | `nextTemplatePart` / `nextTemplatePartInto` |
| regexp | 先看到 `/` 或 `/=`，确认 regexp 上下文 | `rescanRegexpInto(out, mark_pos)` 回到斜杠重扫 |
| `ident =>` | `checkIdentArrowHead` | 先 `simpleNextIsArrowNoLineTerminator`；TS 或 `.unsupported` 才快照 + 全量 lexer |
| `(...) =>` | `checkAsyncArrowHeadAfterAsync` 等 | `simpleCurrentParenIsArrowHead` → `parenArrowAfterOpen` |
| 跳过括号/数组/对象 | `scanBalancedToken` | `balancedAfterOpen`；模板、`\\`、非 ASCII、TS 擦除回退全量 lexer |
| 投机扫描 | 保存 cursor，`nextInto` 到 scratch | `dupToken` 复制持有 payload；失败路径 `freeToken` |

TypeScript 相关标志：

- `is_typescript`：`enableTypeScript` 置位；`skipTrivia` 按 `skipped_intervals` 跳过擦除区间；`simpleNextIsArrowNoLineTerminator` / `simpleCurrentParenIsArrowHead` 直接返回 `null`，parser 不得用 raw 字节前瞻。
- `skipped_intervals`：`markTypeRanges` 合并后的半开区间 `[start, end)`。命中时 `skipRange` 推进 `pos/line/col`，区间内的 LF 会置 `got_lf`。
- `is_strict_mode`：遗留八进制、`\8`/`\9`、keyword 的 FutureReservedWord。
- `is_module` + `allow_html_comments`：脚本才认 `<!--` / 行首 `-->`；模块报 `HtmlCommentInModule` 的路径在 parser，lexer 这边直接不把它们当 trivia。

## 文件级类型

`lexer.zig` 只有一个入口：`namespace(comptime token: type)`。返回的匿名 struct 里嵌 `LexerImpl`、`Error`、TS 擦除类型。parser 把 `LexerImpl` re-export 成 `Lexer`。

### `Error`（`src/lexer.zig:21`）

词法失败集合。parser 把它们映射成带位置的 `SyntaxError`（`State.advance` 用 `mark_pos/mark_line/mark_col`）。成员：

| 成员 | 何时 |
| --- | --- |
| `UnexpectedEof` | 当前未在扫描循环里直接返回；保留给调用方 |
| `UnterminatedString` / `UnterminatedTemplate` / `UnterminatedRegExp` / `UnterminatedComment` | 对应字面量没闭合 |
| `InvalidEscape` / `InvalidUnicodeEscape` / `InvalidUtf8` | 转义或 UTF-8 非法 |
| `InvalidNumber` / `InvalidIdentifier` / `InvalidPrivateName` / `InvalidRegExp` | 字面量形态非法 |
| `LegacyOctalInStrictMode` | 严格模式或模板里的 `\0N` / `\1..\7` / `\8`/`\9` |
| `HtmlCommentInModule` | 留给 parser；lexer 在模块模式不把 HTML 注释当 trivia |
| `OutOfMemory` | `dupe` / `ArrayList` / `atoms.internString` |
| `SyntaxError` | 通用语法失败槽 |

### `LexerImpl`（`src/lexer.zig:40`）

扫描游标 + 解析标志。字段：

| 字段 | 含义 |
| --- | --- |
| `allocator` | 持有 payload（解码后的 string/template bytes） |
| `atoms` | 标识符 intern；keyword 走静态 atom，不进 HashMap |
| `source` | 整份源，lexer 不拥有 |
| `pos` / `line` / `col` | 下一字节；`line`/`col` 1-based。`\n` 才换行；`\r\n` 在 trivia/数字等路径分别处理 |
| `is_strict_mode` / `is_module` / `allow_html_comments` | 对齐 `JSParseState` |
| `got_lf` | 最近一次 `nextInto` 在 token 前跳过了 LineTerminator（含块注释内、TS skip 区间）。对齐 `got_lf`（`quickjs.c:21572`） |
| `mark_pos` / `mark_line` / `mark_col` | 当前 token 起点；parser 用 `mark_pos` 做 regexp 重扫 |
| `is_typescript` | 擦除模式 |
| `skipped_intervals` | 按 `start` 排序、已合并的擦除区间 |

`bump` 把任意非 `\n` 字节（含 `\r`、UTF-8 续字节）都算一列；多字节空白走专门的 `skipNonAsciiWhiteSpace`，把 2/3 字节序列算一列。

### `TemplatePhase`（`src/lexer.zig:1053`）

`head_or_no_subst`：从 `` ` `` 开始；`middle_or_tail`：从 `}` 继续。决定发出的 `TemplatePart`（`.no_substitution`/`.head` vs `.tail`/`.middle`）。

token 侧 `parser.token.TemplatePart`：`no_substitution` / `head` / `middle` / `tail`。payload `str.bytes` 是 cooked，`raw_bytes` 是 raw（CRLF 归一成 LF）；`cooked_invalid` 在模板里把非法转义变成「cooked 为空、仍发出 token」，tagged template 的 cooked 槽是 `undefined`。

---

## 函数

### `namespace` (`src/lexer.zig:2`)

- **签名**：`pub fn namespace(comptime token: type) type`。
- **作用**：把 lexer 钉在一份 token 表示上，返回含 `Lexer` / `Error` / TS 擦除 API 的类型。
- **实现**：整个文件是这个 comptime 函数的函数体。`const t = token;` 后所有 `t.Token`、`t.TOK_*`、`t.keywordAtom` 都来自调用方（生产是 `parser.token`）。不在运行时分配。
- **所有权 / 错误 / 调用**：无运行时所有权。`parser.zig:265` `pub const lexer = @import("lexer.zig").namespace(token);`，测试同样参数化。

### `LexerImpl.init` (`src/lexer.zig:74`)

- **签名**：`pub fn init( allocator: std.mem.Allocator, atoms: *AtomTable, source: []const u8, ) LexerImpl`。
- **作用**：构造空游标 lexer，不读源、不 intern。
- **实现**：填 `allocator`/`atoms`/`source`，`skipped_intervals` 为空 `ArrayList`。其余字段用默认：`pos=0`，`line/col=1`，标志全 false（`allow_html_comments` 默认 true）。
- **所有权 / 错误 / 调用**：不拥有 `source` 和 `atoms`。`skipped_intervals` 必须 `deinit`。`compileQjsProgram` 与测试直接调用。

### `LexerImpl.deinit` (`src/lexer.zig:87`)

- **签名**：`pub fn deinit(self: *LexerImpl) void`。
- **作用**：释放擦除区间表。
- **实现**：`skipped_intervals.deinit(self.allocator)`。不释放当前 token payload——那是 parser 的 `token` 所有权。
- **所有权 / 错误 / 调用**：调用方还要对未 `freeToken` 的 `Token` 自行释放。无 error。

### `LexerImpl.enableTypeScript` (`src/lexer.zig:91`)

- **签名**：`pub fn enableTypeScript(self: *LexerImpl) !void`。
- **作用**：打开 TS 擦除：后续 `skipTrivia` 会跳过类型区间。
- **实现**：`is_typescript = true`，然后 `markTypeRanges`（见 [02-lexer-typescript.md](02-lexer-typescript.md)）。失败来自 tokenize / `ArrayList`。
- **所有权 / 错误 / 调用**：`compileQjsProgram` 在 `shouldStrip(options.source_kind, options.filename)` 为真时调用。之后 `simple_*` 前瞻全部失效。

### `LexerImpl.getSkippedIntervalAtPos` (`src/lexer.zig:96`)

- **签名**：`fn getSkippedIntervalAtPos(self: *const LexerImpl, pos: usize) ?Range`。
- **作用**：若 `pos` 正好是某擦除区间起点，返回该区间。
- **实现**：线性扫 `skipped_intervals`（已按 `start` 排序）。`range.start == pos` 命中；`range.start > pos` 提前结束。不检查 `pos` 落在区间内部——`skipTrivia` 每次只在 token 边界问一次，跳完后 `pos == range.end`。
- **所有权 / 错误 / 调用**：只读。仅 `skipTrivia` 在 `is_typescript` 时调用。

### `LexerImpl.skipRange` (`src/lexer.zig:104`)

- **签名**：`fn skipRange(self: *LexerImpl, range: Range) bool`。
- **作用**：把游标从当前 `pos` 推到 `range.end`，维护行列，报告是否见到换行。
- **实现**：逐字节走 `[pos, range.end)`。`\n` 与 `\r`（可跟 `\n`）都让 `line+=1, col=1` 并记 `saw_lf`；其它字节 `col+=1`。最后 `self.pos = range.end`。
- **所有权 / 错误 / 调用**：不分配。返回值给 `skipTrivia` 置 `got_lf` / `allow_html_close`。区间本身是源切片，无 payload。

### `LexerImpl.releaseTokenPayload` (`src/lexer.zig:128`)

- **签名**：`inline fn releaseTokenPayload(self: *LexerImpl, tok: *t.Token) void`。
- **作用**：丢掉 token 持有的解码字符串，不改 `val`。
- **实现**：只处理 `.str`：`bytes` / `raw_bytes` 若非空且不是 `source` 内切片则 `allocator.free`。`.ident` 的 atom 不再在这里 `free`（TGC S3-c：compile scope 扎根，sweep 回收）。其它 payload 无拥有堆。
- **所有权 / 错误 / 调用**：`freeToken`、`nextIntoReplacing` 使用。无 error。对齐 `quickjs.c:22190-22208` 的 `free_token`，但去掉 rc。

### `LexerImpl.freeToken` (`src/lexer.zig:143`)

- **签名**：`pub fn freeToken(self: *LexerImpl, tok: *t.Token) void`。
- **作用**：释放 payload 并把 union 置 `.none`，避免 double-free。
- **实现**：`releaseTokenPayload` 然后 `tok.payload = .none`。
- **所有权 / 错误 / 调用**：parser 的 scratch lookahead、`advance` 失败路径、`State.deinit` 都走这里。无 error。

### `LexerImpl.nextIntoReplacing` (`src/lexer.zig:154`)

- **签名**：`pub fn nextIntoReplacing(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：QuickJS `next_token`：先放掉当前 `JSToken`，再原地写入下一个。
- **实现**：先 `releaseTokenPayload(out)`。`nextInto(out)` 成功则新 token 覆盖全部字段（不必先把 union 清成 `.none`，避免热路径写整块 backing storage）。失败则 `out.payload = .none` 再返回，保证 `State.deinit` 安全。
- **所有权 / 错误 / 调用**：`State.advance`（`parser.zig:2028`）主路径。error 原样上抛；parser 用 `mark_*` 填诊断。

### `LexerImpl.dupToken` (`src/lexer.zig:165`)

- **签名**：`pub fn dupToken(self: *LexerImpl, tok: t.Token) Error!t.Token`。
- **作用**：为投机解析快照复制一份独立拥有的 token。
- **实现**：按位拷贝后：`.ident` 复制 atom 句柄（不 intern 第二次）；`.str` 仅当 bytes/raw 不是 source 切片时 `dupe`，并用 `errdefer` 回滚已拷的 `bytes`。数字/regexp 的切片仍指向源，复制结构即可。
- **所有权 / 错误 / 调用**：返回值必须 `freeToken` 或交回 parser state。`OutOfMemory` 来自 `dupe`。

### `LexerImpl.isSourceSlice` (`src/lexer.zig:187`)

- **签名**：`fn isSourceSlice(self: *const LexerImpl, bytes: []const u8) bool`。
- **作用**：判断切片是否落在 `source` 内，从而决定要不要 `free`。
- **实现**：空切片视为「不拥有」。否则比较指针区间 `[bytes.ptr, bytes.ptr+len)` 是否 ⊆ `[source.ptr, source.ptr+len)`。
- **所有权 / 错误 / 调用**：无分配。`releaseTokenPayload` / `dupToken` 使用。无转义的字符串 token 直接切片源，不能 free。

### `LexerImpl.gotLineTerminator` (`src/lexer.zig:197`)

- **签名**：`pub fn gotLineTerminator(self: *LexerImpl) bool`。
- **作用**：告诉 parser 当前 token 前有没有 LineTerminator。
- **实现**：返回 `got_lf`。`skipTrivia` 每次 `nextInto` 开头清零再置位。
- **所有权 / 错误 / 调用**：`State.gotLineTerminator` 转发。ASI、禁止跨行的 `=>` / `throw` / `return` / `using` 绑定都读它。无 error。

### `LexerImpl.next` (`src/lexer.zig:202`)

- **签名**：`pub fn next(self: *LexerImpl) Error!t.Token`。
- **作用**：返回新 token 值（测试与少数冷路径）。
- **实现**：栈上 `undefined` Token，`nextInto`，再返回。error union 会拷贝整个 Token。
- **所有权 / 错误 / 调用**：调用方拥有返回的 payload。热路径用 `nextInto` / `nextIntoReplacing` 避免这次拷贝。

### `LexerImpl.nextInto` (`src/lexer.zig:211`)

- **签名**：`pub fn nextInto(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：跳过 trivia，按首字节分发给各 `lex*`，写入 `out`。EOF 发 `TOK_EOF`。
- **实现**：`skipTrivia` → `mark()`。`pos >= len` 则 `emitInto(TOK_EOF, .none)`。否则：标识符起点 / 非 ASCII / `\u` 转义 → `lexIdentifier`；数字 → `lexNumber(false)`；`#` → `lexPrivateName`；引号 → `lexString`；`` ` `` → `lexTemplate(.head_or_no_subst)`；`.` → `lexDotOrNumber`；其余 → `lexPunctuator`。`/` 在这里是标点，不是 regexp。
- **所有权 / 错误 / 调用**：不释放 `out` 旧 payload（那是 `nextIntoReplacing` 的事）。parser 投机扫描把结果写进 scratch Token。`skipTrivia` 的 error 直接上抛。

### `LexerImpl.nextTemplatePart` (`src/lexer.zig:252`)

- **签名**：`pub fn nextTemplatePart(self: *LexerImpl) Error!t.Token`。
- **作用**：从当前位置（必须在 `}`）继续扫模板中段/尾。
- **实现**：栈上 Token，转发 `nextTemplatePartInto`。
- **所有权 / 错误 / 调用**：测试用。parser 表达式路径用 AfterBrace 变体，因为 lookahead 已经吃掉 `}`。

### `LexerImpl.nextTemplatePartInto` (`src/lexer.zig:258`)

- **签名**：`pub fn nextTemplatePartInto(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：原地写入下一模板段；`pos` 必须停在闭合 `}`。
- **实现**：`mark()` 后 `lexTemplate(out, .middle_or_tail)`，后者 `expect_open_byte=true`，会 bump `}`。
- **所有权 / 错误 / 调用**：对齐 `js_parse_template_part` 第二次进入（`quickjs.c:21794`）。调用方保证 `pos` 在 `}`。

### `LexerImpl.nextTemplatePartAfterBrace` (`src/lexer.zig:267`)

- **签名**：`pub fn nextTemplatePartAfterBrace(self: *LexerImpl) Error!t.Token`。
- **作用**：`}` 已被 lookahead 消费后，返回下一模板段。
- **实现**：转发 `nextTemplatePartAfterBraceInto`。
- **所有权 / 错误 / 调用**：值返回，热路径不用。

### `LexerImpl.nextTemplatePartAfterBraceInto` (`src/lexer.zig:273`)

- **签名**：`pub fn nextTemplatePartAfterBraceInto(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：parser 标准路径：`}` 已是当前 token，`lex.pos` 在其后一字节。
- **实现**：`mark()`，`lexTemplateBody(out, .middle_or_tail, false)`——不再 bump 开字节。
- **所有权 / 错误 / 调用**：`parseTemplate`、tagged template、predeclare 扫描在确认 peek 为 `}` 后 `freeToken` 再调这里（`parser.zig:6069`、`6491`、`2752`、`8225`）。错误：`UnterminatedTemplate`、OOM、转义相关。

### `LexerImpl.rescanRegexp` (`src/lexer.zig:283`)

- **签名**：`pub fn rescanRegexp(self: *LexerImpl, slash_offset: usize) Error!t.Token`。
- **作用**：把刚发出的 `/` 或 `/=` 重扫成 regexp 字面量并返回。
- **实现**：转发 `rescanRegexpInto`。
- **所有权 / 错误 / 调用**：测试。生产走 `rescanRegexpInto`。

### `LexerImpl.rescanRegexpInto` (`src/lexer.zig:289`)

- **签名**：`pub fn rescanRegexpInto(self: *LexerImpl, out: *t.Token, slash_offset: usize) Error!void`。
- **作用**：parser 在 regexp 允许上下文确认后，从斜杠重扫（`js_parse_regexp`，`quickjs.c:22005`）。
- **实现**：`pos = slash_offset`，行列恢复为 `mark_line/mark_col`（调用方须在斜杠 token 的 mark 仍有效时调用），再 `mark()` + `lexRegexp`。
- **所有权 / 错误 / 调用**：`parseRegExpLiteral` 先 `freeToken` 再传入 `s.lex.mark_pos`。predeclare / fallback syntax 同样。pattern/flags 是源切片，不必 free。不跳 trivia。

### `LexerImpl.peek` (`src/lexer.zig:301`)

- **签名**：`inline fn peek(self: *const LexerImpl) u8`。
- **作用**：当前字节。
- **实现**：`source[pos]`。调用方保证 `pos < len`。
- **所有权 / 错误 / 调用**：无。几乎所有 `lex*` 热路径。

### `LexerImpl.peekAt` (`src/lexer.zig:305`)

- **签名**：`inline fn peekAt(self: *const LexerImpl, n: usize) u8`。
- **作用**：相对 peek；越界返回 `0`。
- **实现**：`pos+n < len` 则取字节，否则 `0`。`0` 也可能是 NUL，调用方用 `remaining` 区分。
- **所有权 / 错误 / 调用**：标点最长匹配、`<!--`、数字前缀。

### `LexerImpl.remaining` (`src/lexer.zig:309`)

- **签名**：`inline fn remaining(self: *const LexerImpl) usize`。
- **作用**：剩余字节数。
- **实现**：`source.len - pos`。
- **所有权 / 错误 / 调用**：无。UTF-8 / 转义长度检查。

### `LexerImpl.simpleNextIsArrowNoLineTerminator` (`src/lexer.zig:317`)

- **签名**：`pub fn simpleNextIsArrowNoLineTerminator(self: *const LexerImpl) ?bool`。
- **作用**：不改 lexer 状态，问「下一 token 是不是同行的 `=>`」。对齐 `peek_token(..., TRUE)`。
- **实现**：`is_typescript` 则 `null`。否则 `simple_token.next(source, &local_pos, true)`：`.arrow` → true；`.unsupported` → null（调用方回退全量 lexer）；其余（含 `.line_terminator`）→ false。
- **所有权 / 错误 / 调用**：`checkIdentArrowHead`（`parser.zig:3827`）首选。不分配、不置 `got_lf`。

### `LexerImpl.simpleCurrentParenIsArrowHead` (`src/lexer.zig:330`)

- **签名**：`pub fn simpleCurrentParenIsArrowHead(self: *const LexerImpl) ?bool`。
- **作用**：当前 `pos` 已在 `(` 之后时，判断括号是否箭头形参表。
- **实现**：TS 返回 `null`。否则 `simple_token.parenArrowAfterOpen(source, pos)`。
- **所有权 / 错误 / 调用**：parser 在 peek 为 `(` 且已 bump 过开括号之后调用（`parser.zig:3882`）。`null` 表示模板/转义/非 ASCII，必须全量扫描。

### `LexerImpl.bump` (`src/lexer.zig:335`)

- **签名**：`inline fn bump(self: *LexerImpl) void`。
- **作用**：消费一字节并更新行列。
- **实现**：读字节、`pos+=1`；仅 `\n` 时 `line+=1, col=1`，否则 `col+=1`。`\r` 不当换行（trivia 路径单独处理 `\r`/`\r\n`）。
- **所有权 / 错误 / 调用**：无。UTF-8 多字节用 `decodeUtf8` 按序列推进。

### `LexerImpl.mark` (`src/lexer.zig:346`)

- **签名**：`fn mark(self: *LexerImpl) void`。
- **作用**：记下当前 token 起点，供 `emitInto` 和 regexp 重扫。
- **实现**：复制 `pos/line/col` 到 `mark_*`。
- **所有权 / 错误 / 调用**：`nextInto` 在 trivia 之后；模板/regexp 入口也会 mark。parser 诊断用同一组字段。

### `LexerImpl.emitInto` (`src/lexer.zig:352`)

- **签名**：`inline fn emitInto(self: *LexerImpl, out: *t.Token, val: t.TokenKind, payload: t.Payload) void`。
- **作用**：按 mark 与当前 `pos` 填满 `Token`。
- **实现**：`val`、`line_num=mark_line`、`col_num=mark_col`、`ptr` 指向 `source[mark_pos]`（EOF 时指向 `source.ptr+len`）、`len = pos - mark_pos`、`payload`。
- **所有权 / 错误 / 调用**：不分配。payload 所有权已在各 `lex*` 里决定。覆盖 `out` 全部字段。

### `LexerImpl.skipTrivia` (`src/lexer.zig:366`)

- **签名**：`fn skipTrivia(self: *LexerImpl) Error!void`。
- **作用**：跳过空白、换行、注释、脚本 HTML 注释、文件头 hashbang；设置 `got_lf`。
- **实现**：开头 `got_lf=false`，`allow_html_close = (col==1)`（行首才认 `-->`）。循环：TS 且当前位置是擦除起点则 `skipRange`，区间内 LF/`\r` 会改 `line/col` 并可能置 `got_lf`；ASCII 空白 ` \t\v\f` bump；`c>=0x80` 试 `skipNonAsciiWhiteSpace`（LS/PS 改 `line` 并返回 true）；`\n`/`\r` 都置 `got_lf` 再 `bump`——`bump` 只把 `\n` 当成换行，单独 `\r` 只 `col+=1`，`\r\n` 靠下一轮 bump `\n` 才 `line+=1`；`//` → `skipLineComment`；`/*` → `skipBlockComment`，块内换行置 lf；非模块且允许时 `<!--` 当行注释；行首 `-->` 同样；`pos==0` 的 `#!` 当行注释。否则 return。
- **所有权 / 错误 / 调用**：仅 `UnterminatedComment`。`nextInto` 唯一调用方。HTML 注释是 Annex B.1.3，模块关闭。

### `LexerImpl.skipLineComment` (`src/lexer.zig:435`)

- **签名**：`fn skipLineComment(self: *LexerImpl) Error!void`。
- **作用**：从当前位置吃到行终结之前（不吃掉 LF）。
- **实现**：直到 `\n`/`\r` 或 UTF-8 LS/PS（`isUtf8LineSeparator`）停止；否则 `bump`。不要求已经 bump 过 `//`——调用时 `pos` 仍在 `/` 或 `<` 或 `#`。
- **所有权 / 错误 / 调用**：也服务于 `<!--`、`-->`、`#!`。永不 error（签名有 `Error` 但路径不返回）。LF 留给 `skipTrivia`。

### `LexerImpl.skipNonAsciiWhiteSpace` (`src/lexer.zig:444`)

- **签名**：`fn skipNonAsciiWhiteSpace(self: *LexerImpl) ?bool`。
- **作用**：若当前位置是 ECMA 空白或 LS/PS，消费它并返回是否为行终结。
- **实现**：硬编码 UTF-8：NBSP `C2 A0`；Ogham `E1 9A 80`；U+2000–U+200A、U+202F、U+205F、U+3000、BOM `EF BB BF`；LS `E2 80 A8` / PS `E2 80 A9` 返回 `true` 并换行。不匹配返回 `null`（让标识符路径去解码）。
- **所有权 / 错误 / 调用**：`skipTrivia`。一次序列算一列。无 error。

### `LexerImpl.isUtf8LineSeparator` (`src/lexer.zig:496`)

- **签名**：`fn isUtf8LineSeparator(self: *LexerImpl) bool`。
- **作用**：当前位置是否 LS/PS 三字节序列。
- **实现**：`remaining>=3` 且 `E2 80 A8/A9`。
- **所有权 / 错误 / 调用**：行注释、块注释。只读。

### `LexerImpl.skipBlockComment` (`src/lexer.zig:501`)

- **签名**：`fn skipBlockComment(self: *LexerImpl) Error!bool`。
- **作用**：吃掉 `/* ... */`，报告块内是否有换行。
- **实现**：bump `/` 与 `*`。循环到 `*/`：LS/PS 按三字节换行并 `saw_newline=true`；`\n`/`\r` 只记标志再 bump。源耗尽 → `UnterminatedComment`。
- **所有权 / 错误 / 调用**：`skipTrivia`。返回值驱动 ASI。

### `LexerImpl.startsWithBytes` (`src/lexer.zig:525`)

- **签名**：`fn startsWithBytes(self: *const LexerImpl, lit: []const u8) bool`。
- **作用**：当前位置是否等于字面量。
- **实现**：长度不够 false，否则 `mem.eql`。
- **所有权 / 错误 / 调用**：`<!--`、`-->`、`#!`。

### `LexerImpl.startsUnicodeEscape` (`src/lexer.zig:530`)

- **签名**：`fn startsUnicodeEscape(self: *const LexerImpl) bool`。
- **作用**：是否 `\u` 标识符转义起点。
- **实现**：至少两字节且 `\\` + `u`。
- **所有权 / 错误 / 调用**：`nextInto` 分发、`lexIdentifier` 循环。

### `LexerImpl.lexIdentifier` (`src/lexer.zig:536`)

- **签名**：`fn lexIdentifier(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：扫 IdentifierName / 关键字，含 Unicode 转义。
- **实现**：先 `lexAsciiIdentifierNoEscape` 快路径。否则用 `ArrayList` 解码：首码点必须 `IdentifierStart`（`\u` 或 `consumeIdentCodePoint`）；后续 `IdentifierContinue` 或 ASCII continue；`isNonAsciiTriviaStart` 停（空白不当 ident 续）。`emitIdentifierOrKeyword`。
- **所有权 / 错误 / 调用**：scratch `decoded` defer deinit；intern 后的 atom 活在 compile scope。`InvalidIdentifier`、`InvalidUnicodeEscape`、OOM。

### `LexerImpl.lexAsciiIdentifierNoEscape` (`src/lexer.zig:582`)

- **签名**：`fn lexAsciiIdentifierNoEscape(self: *LexerImpl, out: *t.Token) Error!bool`。
- **作用**：纯 ASCII、无 `\` 的标识符快路径；失败则回滚让慢路径处理。
- **实现**：首字节 `\\` 或 `>=0x80` 返回 false。bump 后只吃 ASCII continue；一旦见到 `\\` 或非 ASCII，恢复 `pos/line/col` 返回 false。成功则对源切片 `emitIdentifierOrKeyword(..., false)`。
- **所有权 / 错误 / 调用**：无临时缓冲。intern/keyword 错误上抛。

### `LexerImpl.emitIdentifierOrKeyword` (`src/lexer.zig:609`)

- **签名**：`fn emitIdentifierOrKeyword(self: *LexerImpl, out: *t.Token, lexeme: []const u8, has_escape: bool) Error!void`。
- **作用**：无转义则查关键字表，否则一律 `TOK_IDENT`。
- **实现**：`!has_escape` 时 `keywordLookup`；若 `t.isKeyword(val)`，payload 用 `t.keywordAtom(val)`（静态 atom，不进 HashMap），`is_reserved = isReservedKeyword(val, is_strict_mode)`。否则 `atoms.internString` 发 `TOK_IDENT`，`is_reserved=false`。带转义的 `if`/`null` 等保持标识符（规范：EscapeSequence 不能当关键字）。
- **所有权 / 错误 / 调用**：`OutOfMemory` 来自 intern。`of` 不在 lookup 里当关键字（QuickJS 正常词法把 `of` 当 ident，`TOK_OF` 仅 parser 前瞻）。

### `LexerImpl.isNonAsciiTriviaStart` (`src/lexer.zig:637`)

- **签名**：`fn isNonAsciiTriviaStart(self: *LexerImpl) bool`。
- **作用**：标识符扫描时，当前位置是否应停下来留给 trivia。
- **实现**：与 `skipNonAsciiWhiteSpace` 同一组 UTF-8 空白/LS/PS，但不消费。
- **所有权 / 错误 / 调用**：`lexIdentifier` 循环。避免把 NBSP 吃进 ident。

### `LexerImpl.consumeIdentCodePoint` (`src/lexer.zig:651`)

- **签名**：`fn consumeIdentCodePoint(self: *LexerImpl, out: *std.ArrayList(u8), is_start: bool) Error!void`。
- **作用**：消费一个标识符码点并追加 UTF-8 字节。
- **实现**：ASCII 走 `isAsciiIdentStart/Continue` + bump 单字节。否则 `decodeUtf8`，用 `unicode.isIdentifierStart/Continue`。非 ASCII 追加**源切片**（已是 UTF-8），不是再编码。
- **所有权 / 错误 / 调用**：`InvalidIdentifier`、`InvalidUtf8`。私有名与 ident 共用。

### `LexerImpl.lexPrivateName` (`src/lexer.zig:667`)

- **签名**：`fn lexPrivateName(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：扫 `#IdentifierName`，atom 含前导 `#`（QuickJS 同形）。
- **实现**：bump `#`，缓冲以 `#` 开头，随后与 ident 相同的 start/continue/`\u` 规则。空或非法 start → `InvalidPrivateName`。`internString` 后 `TOK_PRIVATE_NAME`。
- **所有权 / 错误 / 调用**：scratch deinit。不查关键字。`#` 后立即 EOF 失败。

### `LexerImpl.lexDotOrNumber` (`src/lexer.zig:717`)

- **签名**：`fn lexDotOrNumber(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`.` 可能是 `...`、小数、或成员点。
- **实现**：`..` 再一 `.` → `TOK_ELLIPSIS`。下字节是十进制数字 → `lexNumber(true)`。否则 bump 发 ASCII `'.'`。
- **所有权 / 错误 / 调用**：`?.` 不在这里（`lexQuestion`）。数字错误来自 `lexNumber`。

### `LexerImpl.lexNumber` (`src/lexer.zig:732`)

- **签名**：`fn lexNumber(self: *LexerImpl, out: *t.Token, leading_dot: bool) Error!void`。
- **作用**：扫 NumericLiteral / BigIntLiteral。
- **实现**：非 leading-dot 且 `0x/0o/0b`（大小写）→ 对应 digit run，可选 `n`，`finishNumber` 基 16/8/2。否则必吃整数位（leading-dot 除外），可选 `.` 小数、`e/E` 指数（可带符号）、或十进制 `n`。分隔符 `_` 由 `consumeDigitRun` 处理。
- **所有权 / 错误 / 调用**：`InvalidNumber` 包括空 digit run、指数无数字。`0` 后非 x/o/b 落入十进制，遗留八进制在 `finishNumber`。

### `LexerImpl.finishNumber` (`src/lexer.zig:794`)

- **签名**：`fn finishNumber(self: *LexerImpl, out: *t.Token, start: usize, is_bigint: bool, base: u8) Error!void`。
- **作用**：拒绝数字后紧跟 ident 续字符，解析值并 emit `TOK_NUMBER`。
- **实现**：下一字节若 ASCII ident continue 或非 trivia 的非 ASCII → `InvalidNumber`（`123abc` 一个错）。BigInt：十进制禁止多位前导 0；payload `is_bigint=true`，`bigint_text` 去掉 `n` 的源切片，`value=0`。十进制再试 `legacyOrNonOctalDecimalValue`。其余 `parseNumber`。
- **所有权 / 错误 / 调用**：lexeme 是源切片。`parseNumber` 可能为去 `_` 分配临时缓冲。

### `LexerImpl.lexString` (`src/lexer.zig:825`)

- **签名**：`fn lexString(self: *LexerImpl, out: *t.Token, quote: u8) Error!void`。
- **作用**：扫 `'...'` / `"..."`。无转义时 payload 直接切片源。
- **实现**：bump 开引号。无 `\\`、无原始换行则关闭时 `bytes` 指向源（`@constCast`），`contains_escape=false`。一旦见到 `\\`，把已扫前缀拷进 `ArrayList`，再 `decodeStringEscape`。原始 `\n`/`\r` → `UnterminatedString`。
- **所有权 / 错误 / 调用**：有转义则 `dupe` 的 `bytes` 由 token 拥有。`contains_legacy_escape` 来自 `decodeStringEscape` 的返回值（`\8`/`\9` 与遗留八进制）。

### `LexerImpl.decodeStringEscape` (`src/lexer.zig:879`)

- **签名**：`fn decodeStringEscape(self: *LexerImpl, out: *std.ArrayList(u8), in_template: bool) Error!bool`。
- **作用**：反斜杠之后的转义；返回是否遗留八进制/`\8`/`\9`。调用前已 bump `\\`。
- **实现**：`n t r b f v` 标准；`0` 后若跟十进制数字：严格或模板 → `LegacyOctalInStrictMode`，否则 `consumeLegacyOctalEscape` 并返回 true；单独 `\0` 写 NUL。`\xHH`；`\u` 走 `consumeUnicodeEscapeAfterBackslash`。`\n` / `\r` / `\r\n` 行继续，不写 cooked。`E2 80 A8/A9` 当行继续（不写字节，返回 false）。`\1..\7` 同遗留八进制；严格/模板里 `\8`/`\9` 失败，否则 identity 并返回 true。其它 identity escape。
- **所有权 / 错误 / 调用**：字符串要完整 cooked；模板捕获这些 error 改标 `cooked_invalid`。返回 true 仅用于 `contains_legacy_escape`。

### `LexerImpl.consumeLegacyOctalEscape` (`src/lexer.zig:971`)

- **签名**：`fn consumeLegacyOctalEscape(self: *LexerImpl) Error!u21`。
- **作用**：读 `\0..\377` 风格的遗留八进制。
- **实现**：第一位已在 peek。`0-3` 最多再两 digit，`4-7` 再一位。非 `0-7` 停。
- **所有权 / 错误 / 调用**：调用方已确认不在严格/模板，或准备把 error 当 cooked_invalid。无独立 error。

### `LexerImpl.consumeUnicodeEscapeAfterBackslash` (`src/lexer.zig:989`)

- **签名**：`fn consumeUnicodeEscapeAfterBackslash(self: *LexerImpl) Error!u21`。
- **作用**：`\\` 已消费，下一字节是 `u`；解码码点，并拼接合法 surrogate pair。
- **实现**：必须 `u`。`{hex}`：至少一位，值 ≤ `0x10FFFF`，闭合 `}`。否则四 hex。若 BMP 高代理且后面是 `\uXXXX`（非 `{`），试低代理；成功则 `0x10000+...`；失败则回滚第二段，返回孤立高代理（规范：每个孤立代理是自己的 code unit）。
- **所有权 / 错误 / 调用**：`InvalidUnicodeEscape`。字符串/模板/标识符共用。

### `LexerImpl.consumeUnicodeEscape` (`src/lexer.zig:1033`)

- **签名**：`fn consumeUnicodeEscape(self: *LexerImpl) Error!u21`。
- **作用**：从 `\\` 开始的 `\u` 转义。
- **实现**：确认 `\\`，bump，转发 AfterBackslash。
- **所有权 / 错误 / 调用**：标识符路径。`InvalidUnicodeEscape`。

### `LexerImpl.consumeFourHex` (`src/lexer.zig:1039`)

- **签名**：`fn consumeFourHex(self: *LexerImpl) Error!u16`。
- **作用**：读恰好四位 ASCII hex。
- **实现**：不足四字节或非 hex → `InvalidUnicodeEscape`。
- **所有权 / 错误 / 调用**：`\uXXXX`。无分配。

### `LexerImpl.lexTemplate` (`src/lexer.zig:1056`)

- **签名**：`fn lexTemplate(self: *LexerImpl, out: *t.Token, phase: TemplatePhase) Error!void`。
- **作用**：带开字节的模板扫描入口。
- **实现**：`lexTemplateBody(..., true)`。
- **所有权 / 错误 / 调用**：`nextInto`（head）与 `nextTemplatePartInto`（middle，pos 在 `}`）。

### `LexerImpl.lexTemplateBody` (`src/lexer.zig:1060`)

- **签名**：`fn lexTemplateBody(self: *LexerImpl, out: *t.Token, phase: TemplatePhase, expect_open_byte: bool) Error!void`。
- **作用**：扫一段模板：直到 `` ` `` 或 `${`。
- **实现**：`expect_open_byte` 时 head 断言/bump `` ` ``，middle 断言/bump `}`。双缓冲 cooked/raw。`` ` `` → `no_substitution` 或 `tail`；`${` → `head` 或 `middle`。`\\`：`decodeStringEscape(..., true)` 把 `InvalidEscape`/`InvalidUnicodeEscape`/`LegacyOctalInStrictMode` 变成 `cooked_invalid`，raw 仍用 `appendNormalizedTemplateRaw` 记下源转义。`\r`/`\r\n` 在 cooked 与 raw 都写成 `\n`。EOF → `UnterminatedTemplate`。
- **所有权 / 错误 / 调用**：`bytes`/`raw_bytes` 都 `dupe`，token 拥有。parser 用 `template` 判别是否还要 parseExpr。

### `appendNormalizedTemplateRaw` (`src/lexer.zig:1144`)

- **签名**：`fn appendNormalizedTemplateRaw( out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, ) Error!void`。
- **作用**：把一段源（通常是转义序列）写入 template raw，CRLF→LF。
- **实现**：逐字节；`\r` 写 `\n` 并跳过紧随 `\n`。
- **所有权 / 错误 / 调用**：仅 `lexTemplateBody`。OOM。规范 TV/TRV 的行终结归一。

### `LexerImpl.lexRegexp` (`src/lexer.zig:1165`)

- **签名**：`fn lexRegexp(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：从 `/` 扫 RegularExpressionLiteral 的 pattern 与 flags（不编译）。
- **实现**：bump 开 `/`。`in_class`/`escaped`：`\\` 逃逸下一字节；`[` 进类、`]` 出类（`]` 无条件出类）；类外 `/` 结束。原始 LF/CR/LS/PS → `UnterminatedRegExp`。flags 吃 ASCII ident continue 或非 trivia 的非 ASCII。payload 是源切片。
- **所有权 / 错误 / 调用**：不验证 flag 字母、不跑 regexp 引擎。`parseRegExpLiteral` 随后 `compilePatternAndFlags`。

### `LexerImpl.lexPunctuator` (`src/lexer.zig:1216`)

- **签名**：`fn lexPunctuator(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：按首字节分发多字符算符，或发出单字节 ASCII 标点。
- **实现**：`+ - * / % = ! < > & | ^ ?` 各 `lex*`。`~()[]{},;:` bump 后 `TokenKind` 就是该 ASCII 字节。其它 bump 后 `InvalidIdentifier`（未知首字节）。
- **所有权 / 错误 / 调用**：`/` 从不在这里变 regexp。payload 全 `.none`。

### `LexerImpl.lexPlus` (`src/lexer.zig:1243`)

- **签名**：`fn lexPlus(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`++` / `+=` / `+`。
- **实现**：bump `+`，再看 `+`→`TOK_INC`，`=`→`TOK_PLUS_ASSIGN`，否则 ASCII `'+'`。
- **所有权 / 错误 / 调用**：无。`+++` 会先发 `TOK_INC` 留下一个 `+`。

### `LexerImpl.lexMinus` (`src/lexer.zig:1260`)

- **签名**：`fn lexMinus(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`--` / `-=` / `-`。HTML `-->` 在 trivia 已处理，这里是算符。
- **实现**：同 `lexPlus` 结构，token 为 `TOK_DEC` / `TOK_MINUS_ASSIGN` / `'-'`。
- **所有权 / 错误 / 调用**：不分配：`emitInto`（`src/lexer.zig:351`）把结果就地写进调用方给的 `out`，`ptr`/`len` 是源缓冲的借用切片，寿命跟着 `self.source`，词法器不拥有也不释放它。签名带 `Error!void` 只是与 `lexPunctuator` 的臂统一，本函数永不返回错误（`Error` 那 16 个成员来自 trivia/字符串/模板/数字/正则/标识符等别的路径，其中 `UnexpectedEof` / `InvalidRegExp` / `HtmlCommentInModule` / `SyntaxError` 在 `lexer.zig` 里根本没有返回点）。唯一调用方 `lexPunctuator` 的 `'-'` 臂（`src/lexer.zig:1219`）。

### `LexerImpl.lexStar` (`src/lexer.zig:1277`)

- **签名**：`fn lexStar(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`**=` / `**` / `*=` / `*`。
- **实现**：第二字节 `*` 再看 `=` 得 `TOK_POW_ASSIGN` 否则 `TOK_POW`；否则 `=` → `TOK_MUL_ASSIGN`。
- **所有权 / 错误 / 调用**：赋值 opcode 由 parser 用 `TOK_MUL_ASSIGN` 起点推导。

### `LexerImpl.lexSlash` (`src/lexer.zig:1299`)

- **签名**：`fn lexSlash(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：只发 `/` 或 `/=`。注释已在 trivia 吃掉。
- **实现**：bump `/`，`=` 则 `TOK_DIV_ASSIGN`。
- **所有权 / 错误 / 调用**：parser 在 PrimaryExpression / 允许 regexp 的上下文调 `rescanRegexpInto`。

### `LexerImpl.lexPercent` (`src/lexer.zig:1309`)

- **签名**：`fn lexPercent(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`%=` / `%`。
- **实现**：可选 `=` → `TOK_MOD_ASSIGN`。
- **所有权 / 错误 / 调用**：同族：不分配、token 就地写 `out`、切片借自 `self.source`；`Error!void` 是形式上的，本函数永不出错。唯一调用方 `lexPunctuator` 的 `'%'` 臂（`src/lexer.zig:1222`）。

### `LexerImpl.lexEquals` (`src/lexer.zig:1319`)

- **签名**：`fn lexEquals(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`===` / `==` / `=>` / `=`。
- **实现**：第二字节 `=` 再第三 `=` 得严格相等；第二字节 `>` 得 `TOK_ARROW`。
- **所有权 / 错误 / 调用**：箭头前瞻尽量不走到这里（`simple_token`）。

### `LexerImpl.lexBang` (`src/lexer.zig:1341`)

- **签名**：`fn lexBang(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`!==` / `!=` / `!`。
- **实现**：最长 `=` 匹配。TS 非空断言 `!` 在擦除阶段已从源区间删掉，JS 路径这里就是逻辑非。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`。唯一调用方 `lexPunctuator` 的 `'!'` 臂（`src/lexer.zig:1224`）。

### `LexerImpl.lexLt` (`src/lexer.zig:1356`)

- **签名**：`fn lexLt(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`<=` / `<<=` / `<<` / `<`。
- **实现**：`<!--` 在 trivia。这里不发 `TOK_LT` 常量（那是 -103），单 `<` 是 ASCII 0x3C，与 QuickJS 单字符标点一致。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`。唯一调用方 `lexPunctuator` 的 `'<'` 臂（`src/lexer.zig:1225`）。

### `LexerImpl.lexGt` (`src/lexer.zig:1378`)

- **签名**：`fn lexGt(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`>=` / `>>>=` / `>>>` / `>>=` / `>>` / `>`。
- **实现**：三层 `>` 再可选 `=`。`TOK_SHR` 是无符号 `>>>`，`TOK_SAR` 是 `>>`。
- **所有权 / 错误 / 调用**：TS `>>` 关类型参数由擦除器按字节切，不在本函数。

### `LexerImpl.lexAmp` (`src/lexer.zig:1410`)

- **签名**：`fn lexAmp(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`&&=` / `&&` / `&=` / `&`。
- **实现**：先 `&&` 再 `=`，否则 `&=`。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`。唯一调用方 `lexPunctuator` 的 `'&'` 臂（`src/lexer.zig:1227`）。

### `LexerImpl.lexPipe` (`src/lexer.zig:1432`)

- **签名**：`fn lexPipe(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`||=` / `||` / `|=` / `|`。
- **实现**：同 `lexAmp`。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`。唯一调用方 `lexPunctuator` 的 `'|'` 臂（`src/lexer.zig:1228`）。

### `LexerImpl.lexCaret` (`src/lexer.zig:1454`)

- **签名**：`fn lexCaret(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`^=` / `^`。
- **实现**：可选 `=` → `TOK_XOR_ASSIGN`。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`。唯一调用方 `lexPunctuator` 的 `'^'` 臂（`src/lexer.zig:1229`）。

### `LexerImpl.lexQuestion` (`src/lexer.zig:1464`)

- **签名**：`fn lexQuestion(self: *LexerImpl, out: *t.Token) Error!void`。
- **作用**：`??=` / `??` / `?.` / `?`。
- **实现**：`??` 再 `=`。`?.` 仅当 `.` 后不是十进制数字（否则 `?` `.123` 是三元 + 小数，规范禁止 `?.1` 当 optional chain 数字）。
- **所有权 / 错误 / 调用**：同族：不分配、永不返回错误、结果就地写 `out`；`?.` 的数字前瞻只读源字节不推进 `pos`。唯一调用方 `lexPunctuator` 的 `'?'` 臂（`src/lexer.zig:1230`）。

### `LexerImpl.decodeUtf8` (`src/lexer.zig:1488`)

- **签名**：`fn decodeUtf8(self: *LexerImpl) Error!u21`。
- **作用**：从 `pos` 解码一个 UTF-8 码点并按序列 bump。
- **实现**：首字节定 1–4 长度，非法前缀或截断 → `InvalidUtf8`。`utf8Decode` 失败同样。`pos += len`，`col += 1`（整序列一列，不走 `bump` 以免中间字节改 col）。
- **所有权 / 错误 / 调用**：`consumeIdentCodePoint`。不处理 BOM（BOM 是 trivia）。

### `LexerImpl.startsUtf8Trivia` (`src/lexer.zig:1502`)

- **签名**：`fn startsUtf8Trivia(self: *const LexerImpl) bool`。
- **作用**：数字/regexp flags 后面，非 ASCII 是空白则不当 ident 续。
- **实现**：与 skip 路径同一组空白 UTF-8，再加上 `startsUtf8LineTerminator`。
- **所有权 / 错误 / 调用**：`finishNumber`、`lexRegexp` flags。只读。

### `LexerImpl.startsUtf8LineTerminator` (`src/lexer.zig:1517`)

- **签名**：`fn startsUtf8LineTerminator(self: *const LexerImpl) bool`。
- **作用**：LS/PS 检测（只读）。
- **实现**：`E2 80 A8/A9`。
- **所有权 / 错误 / 调用**：`lexRegexp` 禁止跨行；`startsUtf8Trivia`。

### `isAsciiIdentStart` (`src/lexer.zig:1526`)

- **签名**：`fn isAsciiIdentStart(c: u8) bool`。
- **作用**：ASCII IdentifierStart。
- **实现**：`unicode.isAsciiIdentifierStartByte`（`$ _ A-Z a-z`）。
- **所有权 / 错误 / 调用**：`nextInto` 分发、ident。无。

### `isAsciiIdentContinue` (`src/lexer.zig:1530`)

- **签名**：`fn isAsciiIdentContinue(c: u8) bool`。
- **作用**：ASCII IdentifierPart。
- **实现**：`unicode.isAsciiIdentifierPartByte`（start + 数字）。
- **所有权 / 错误 / 调用**：ident、flags、数字后缀拒绝。

### `hexNibble` (`src/lexer.zig:1534`)

- **签名**：`fn hexNibble(c: u8) u16`。
- **作用**：ASCII hex 转 0–15。
- **实现**：`unicode.asciiHexDigitValueByte orelse unreachable`。调用方已验证。
- **所有权 / 错误 / 调用**：`\x`、`\u`。

### `appendUtf8` (`src/lexer.zig:1538`)

- **签名**：`fn appendUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void`。
- **作用**：把码点写成 UTF-8；孤立代理写成 CESU-8 三字节 `ED A0..BF`（V8/QuickJS 对 lone surrogate escape 的表面形式）。
- **实现**：`utf8Encode`；失败且在 `D800–DFFF` 则手写 3 字节，否则 `InvalidUnicodeEscape`。
- **所有权 / 错误 / 调用**：字符串/ident 转义。OOM。

### `isHexDigit` (`src/lexer.zig:1554`)

- **签名**：`fn isHexDigit(c: u8) bool`。
- **作用**：十六进制 digit 谓词。
- **实现**：`unicode.isAsciiHexDigitByte`。
- **所有权 / 错误 / 调用**：`consumeDigitRun` 特化。

### `isOctalDigit` (`src/lexer.zig:1558`)

- **签名**：`fn isOctalDigit(c: u8) bool`。
- **作用**：`0-7`。
- **实现**：`unicode.isAsciiOctalDigitByte`。
- **所有权 / 错误 / 调用**：`0o` 字面量。

### `isBinaryDigit` (`src/lexer.zig:1562`)

- **签名**：`fn isBinaryDigit(c: u8) bool`。
- **作用**：`0-1`。
- **实现**：`unicode.isAsciiBinaryDigitByte`。
- **所有权 / 错误 / 调用**：`0b`。

### `isDecimalDigit` (`src/lexer.zig:1566`)

- **签名**：`fn isDecimalDigit(c: u8) bool`。
- **作用**：`0-9`。
- **实现**：`unicode.isAsciiDigitByte`。
- **所有权 / 错误 / 调用**：数字、`?.` 歧义。

### `consumeDigitRun` (`src/lexer.zig:1570`)

- **签名**：`fn consumeDigitRun(self: *LexerImpl, comptime isDigit: fn (u8) bool) bool`。
- **作用**：吃 `digit ( '_' digit )*`，拒绝首尾或连续 `_`。
- **实现**：digit 清 `prev_sep`；`_` 要求已有 digit 且上一个不是 `_`。结束时必须 `any && !prev_sep`。
- **所有权 / 错误 / 调用**：返回 false 不回滚已 bump 的字节——调用方把整段当 `InvalidNumber`。

### `consumeHexDigits` (`src/lexer.zig:1588`)

- **签名**：`fn consumeHexDigits(self: *LexerImpl) bool`。
- **作用**：十六进制 digit run。
- **实现**：`consumeDigitRun(self, isHexDigit)`。
- **所有权 / 错误 / 调用**：`0x`。

### `consumeOctalDigits` (`src/lexer.zig:1592`)

- **签名**：`fn consumeOctalDigits(self: *LexerImpl) bool`。
- **作用**：八进制 digit run。
- **实现**：`consumeDigitRun(self, isOctalDigit)`。
- **所有权 / 错误 / 调用**：`0o`。

### `consumeBinaryDigits` (`src/lexer.zig:1596`)

- **签名**：`fn consumeBinaryDigits(self: *LexerImpl) bool`。
- **作用**：二进制 digit run。
- **实现**：`consumeDigitRun(self, isBinaryDigit)`。
- **所有权 / 错误 / 调用**：`0b`。

### `consumeDecDigits` (`src/lexer.zig:1600`)

- **签名**：`fn consumeDecDigits(self: *LexerImpl) bool`。
- **作用**：十进制 digit run。
- **实现**：`consumeDigitRun(self, isDecimalDigit)`。
- **所有权 / 错误 / 调用**：整数、指数、小数。

### `consumeDecDigitsRequired` (`src/lexer.zig:1604`)

- **签名**：`fn consumeDecDigitsRequired(self: *LexerImpl) Error!void`。
- **作用**：必须有一段合法十进制 digit。
- **实现**：false → `InvalidNumber`。
- **所有权 / 错误 / 调用**：非 leading-dot 整数部分。

### `consumeOptionalFractionDigits` (`src/lexer.zig:1608`)

- **签名**：`fn consumeOptionalFractionDigits(self: *LexerImpl) Error!void`。
- **作用**：`.` 之后：有 digit 或 `_` 则必须成 run，否则允许 `.` 后无数字（`1.` 合法）。
- **实现**：EOF 直接回；`digit` 或 `_` 则 `consumeDecDigits`，失败 `InvalidNumber`（如 `._`）。
- **所有权 / 错误 / 调用**：`lexNumber`。

### `decimalBigIntHasInvalidLeadingZero` (`src/lexer.zig:1616`)

- **签名**：`fn decimalBigIntHasInvalidLeadingZero(lexeme: []const u8) bool`。
- **作用**：十进制 BigInt 禁止 `0_1n` / `01n` 这类前导零（一位 `0n` 合法）。
- **实现**：最后必须是 `n`。跳过 `_` 数 digit；多于一位且首位 `'0'` 则非法。
- **所有权 / 错误 / 调用**：`finishNumber`。不分配。

### `legacyOrNonOctalDecimalValue` (`src/lexer.zig:1628`)

- **签名**：`fn legacyOrNonOctalDecimalValue(self: *LexerImpl, lexeme: []const u8) !?f64`。
- **作用**：Annex B：非严格 `012` 当八进制；`08` 当十进制；严格或含 `_` 则错。
- **实现**：须以 `0` 开头。有 `.`/`e`/`E` 或 digit 数 ≤1 则 `null`（走普通 parse）。有 `_` 或严格 → `InvalidNumber`。含 8/9 则 `null`（非八进制十进制）。否则按八进制积成 `u128` 转 `f64`。
- **所有权 / 错误 / 调用**：`finishNumber` 仅 base 10。`null` 表示不是遗留形式。

### `parseNumberLiteral` (`src/lexer.zig:1661`)

- **签名**：`fn parseNumberLiteral(lexeme: []const u8) ?f64`。
- **作用**：数字 lexeme → `f64`，对齐 `js_parse_number` → `js_atof(ACCEPT_BIN_OCT | ACCEPT_UNDERSCORES)`。
- **实现**：`number_format.parseNumberExact(lexeme, 0, .{ .accept_bin_oct, .accept_underscores })`；lexer 已定好字面量范围并校验过分隔符位置，遗留八进制与 BigInt 后缀在此之前处理。
- **所有权 / 错误 / 调用**：不分配。null → `finishNumber` 报 `InvalidNumber`。非十进制超长字面量由 dtoa bignum 精确转换，不再有 u128 溢出后的逐位累加。

### `keywordLookup` (`src/lexer.zig:1665`)

- **签名**：`fn keywordLookup(lexeme: []const u8) ?t.TokenKind`。
- **作用**：按长度 + 首字节的固定比较把 ASCII 单词映射到 `TOK_*`。
- **实现**：长度 2–10。表含 ReservedWord、FutureReservedWord、`async`/`await`/`let`/`static`/`yield` 等。**不含 `of`**：注释写明 QuickJS 正常词法把它当 ident。比较用 `eq`。
- **所有权 / 错误 / 调用**：仅无 escape 的 ident。命中后再 `isKeyword` 过滤（`TOK_ASYNC` 在 keyword 闭区间外，会落到 intern 成 `TOK_IDENT`——`async` 由 parser 当伪关键字）。

`keywordLookup` 长度桶（消费点：`emitIdentifierOrKeyword`）：

| 长度 | 词 |
| --- | --- |
| 2 | `do` `if` `in` |
| 3 | `for` `let` `new` `try` `var` |
| 4 | `case` `else` `enum` `null` `this` `true` `void` `with` |
| 5 | `async` `await` `break` `catch` `class` `const` `false` `super` `throw` `while` `yield` |
| 6 | `delete` `export` `import` `public` `return` `static` `switch` `typeof` |
| 7 | `default` `extends` `finally` `package` `private` |
| 8 | `continue` `debugger` `function` |
| 9 | `interface` `protected` |
| 10 | `implements` `instanceof` |

### `eq` (`src/lexer.zig:1739`)

- **签名**：`inline fn eq(a: []const u8, b: []const u8) bool`。
- **作用**：关键字表的字节相等。
- **实现**：`std.mem.eql(u8, a, b)`。
- **所有权 / 错误 / 调用**：`keywordLookup`。长度已在外层分桶，仍做完整比较。

### `isReservedKeyword` (`src/lexer.zig:1745`)

- **签名**：`fn isReservedKeyword(val: t.TokenKind, is_strict: bool) bool`。
- **作用**：标 ident payload 的 `is_reserved`：规范 ReservedWord；FutureReservedWord 仅严格模式。
- **实现**：`null/false/true` 与控制/声明/class/module 关键字 true。`implements interface let package private protected public static yield` 随 `is_strict`。`await`/`of` 上下文，返回 false。
- **所有权 / 错误 / 调用**：parser 用 `is_reserved` 拒绝 BindingIdentifier。无分配。

TypeScript 擦除函数、`Range` / `SourceKind` 等见 [02-lexer-typescript.md](02-lexer-typescript.md)。`simple_token` 见 [02-lexer-simple-token.md](02-lexer-simple-token.md)。

## 覆盖核对

覆盖以本目录 `02-*.md` 合计为准：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
    --docs 'docs/code-walkthrough/02-*.md' \
    src/lexer.zig src/simple_token.zig
```

- 清单函数数（本文件分到）: 93（`src/lexer.zig` 全文件 169）
- 本组标题覆盖: 186
- 未覆盖: 无

`simple_token.identifierRegexpContext` 已纳入清单，并在 [02-lexer-simple-token.md](02-lexer-simple-token.md) 讲解。
