# 02 — `simple_token`：非持有前瞻

`src/simple_token.zig` 实现 QuickJS `simple_next_token` / `js_parse_skip_parens_token` 的借用扫描：不分配、不碰 `LexerImpl` 游标。只能覆盖「ASCII 够用」的子集。`.unsupported` 或 `null` 表示必须回退到全量 lexer。

parser 三处入口：

1. `LexerImpl.simpleNextIsArrowNoLineTerminator` → `next(..., no_line_terminator=true)`：`ident =>` 同行箭头。
2. `LexerImpl.simpleCurrentParenIsArrowHead` → `parenArrowAfterOpen`：已经过 `(` 的箭头形参。
3. `scanBalancedToken`（`parser.zig:13398`）→ `balancedAfterOpen`：跳过 `(...)` / `[...]` / `{...}` 并分类随后 token，同时收集顶层 `;` / `...` / `=` 拓扑位。`is_typescript` 时 parser 根本不走这条。

`balancedAfterOpen` 对模板、标识符转义、表达式中的非 ASCII 起点及 HTML 注释返回 null，交回全量 lexer。分隔符不匹配或源耗尽则可返回 closed=false；`next` 的返回类型不同，用 `.unsupported` 表示自身无法处理的情况。regexp 是否允许跟在 ident 后由 `identifierRegexpContext` 近似 QuickJS skip-parens 分类。

## 类型

### `Kind`（`src/simple_token.zig:8`）

`next` 的结果：

| 变体 | 含义 |
| --- | --- |
| `import_keyword` / `export_keyword` | 完整单词且后面不是 ident 续 |
| `identifier` | 其它 ident 起点（含 `importx`） |
| `arrow` | `=>` |
| `line_terminator` | 禁止跨行时遇到 CR/LF/LS/PS，或遇到直接按行终结处理的 `//` 注释 |
| `dot` / `left_paren` | `.` `(` |
| `other` | 其余 ASCII 标点或单字节 |
| `eof` | 源结束 |
| `unsupported` | 调用方必须用全量 lexer（未闭合注释、块注释内非 ASCII 且禁止跨行、坏 UTF-8 等） |

### `Decoded`（`src/simple_token.zig:21`）

`{ codepoint: u21, width: usize }`。`decodeAt` 私有产物。

### `BalancedFollowing`（`src/simple_token.zig:117`）

闭合分隔符之后、跳过 trivia 的下一 token 分类：`arrow` `assignment` `comma` `right_paren` `right_bracket` `right_brace` `identifier` `in_keyword` `line_terminator` `other` `eof`。parser 映射到 `TOK_ARROW`、`=`、`,`、`)`、`]`、`}`、`TOK_IDENT`、`TOK_IN`、`'\n'`、`TOK_EOF`。

注意：`==` / `===` 是 `.other` 不是 `.assignment`，避免对象/数组字面量走解构路径。

### `BalancedScan`（`src/simple_token.zig:131`）

| 字段 | 含义 |
| --- | --- |
| `following` | 匹配闭合后的下一 token |
| `closed` | 是否在源结束前配对成功 |
| `has_top_level_semicolon` | 最外层（level==2）见到 `;`（`for (;;)`） |
| `has_top_level_ellipsis` | 最外层 `...`（解构 rest） |
| `has_assignment` | 见到「不是 `==`/`=>` 的 `=`」（形参默认值 / 解构赋值） |

### `RegexpContext`（`src/simple_token.zig:392`）

跳过括号时 `/` 的角色：

| 变体 | 含义 |
| --- | --- |
| `allowed` | `/` 开 regexp |
| `disallowed` | `/` 是除号（可跟 `=`） |
| `identifier` | 刚扫完单词，遇 `/` 再查关键字表 |
| `mode_dependent` | `await` / 严格未来保留字；本扫描器不看 parser 模式，遇 `/` 直接 `null` 回退 |

---

## 函数

### `next` (`src/simple_token.zig:30`)

- **签名**：`pub inline fn next(source: []const u8, pos: *usize, no_line_terminator: bool) Kind`。
- **作用**：从 `pos.*` 跳过 trivia 并分类一个子集 token，推进 pos 到已识别的位置；identifier 分支不保证消费整个单词。
- **实现**：本地 `p` 循环。CR/LF：禁止跨行则 `finish(..., line_terminator)` 且 **不**前进越过 LF。ASCII 空白跳过。`/`：`//` 在禁止跨行时直接当 line terminator（对齐 QuickJS `peek_token(..., TRUE)` 不扫注释体）；否则 `skipLineComment`。`/*`：块内 CR/LF 同样受 `no_line_terminator` 约束；块内 `>=0x80` 且禁止跨行 → `unsupported`（不复制全量 lexer 的 LS/PS 错误路径）。`=>` `.` `(` 特判。`i`/`e` 走 `identifierOrKeyword`（`import`/`export`）。其它 ASCII ident start → 只吃一字节当 `identifier`（不扫完单词——箭头测试只需要「是 ident」）。非 ASCII：`decodeAt`，LS/PS 当行终结，空白跳过，`IdentifierStart` → ident（宽度整码点），否则 `other`。坏 UTF-8 → `unsupported`。
- **所有权 / 错误 / 调用**：不分配。`pos` 是调用方局部变量，不是 `LexerImpl.pos`。`simpleNextIsArrowNoLineTerminator`（`src/lexer.zig:316`）用 `true`；CLI 的 `sourceLooksLikeModule`（`src/cli/zjs.zig:752`）用 `false` 连扫两枚 token 做模块探测，`import_keyword` / `export_keyword` 只有它一个消费者。无 error set。

### `balancedAfterOpen` (`src/simple_token.zig:145`)

- **签名**：`pub fn balancedAfterOpen( source: []const u8, start: usize, opening: u8, no_line_terminator: bool, ) ?BalancedScan`。
- **作用**：从已扫过的 `(` `[` `{` **之后**扫到匹配闭合，分类随后 token，并记下拓扑位。对齐 `js_parse_skip_parens_token`。
- **实现**：`opening` 必须是三开界之一，否则 null。`delimiters[256]` 栈，`level` 从 2（哨兵 0 + opening）。空白（含 CR/LF）无条件跳过——`no_line_terminator` 只作用于闭合后的 `scanFollowing`。开界入栈，regexp 允许；闭界必须匹配，level 回到 1 则 `closed=true` 并 `scanFollowing`。引号 `skipQuoted`。`/`：注释、或按 `regexp_context`（ident 延迟到 `identifierRegexpContext`）扫 regexp / 除号。`+`/`-`：`-` 处若是 `-->` → null（HTML 注释）；`++`/`--` 禁止 regexp，单 `+`/`-`/`+=` 允许。`.`：`...` 在 level==2 置 ellipsis；`.digit` `skipNumberLike`；否则成员点。数字 `skipNumberLike`。`` ` `` 与 `\\` 立即 null。`<` 遇 `<!--` null。`#` 私有名必须 ASCII ident start。ASCII 单词记下区间，context=`.identifier`。`=` 若下一字节不是 `=`/`>` 则 `has_assignment`，再吞 punct 续字节。`;` 在 level==2 置 semicolon。其它算符吞续字节后 regexp 允许。非 ASCII 或未知 ASCII → null。源耗尽返回当前 `result`（可能 `closed=false`）。
- **所有权 / 错误 / 调用**：不分配。parser 的 `scanBalancedToken` 总是先试它。`null` = 回退全量 lexer。`(...) {` 归为 `.left_brace`、`(...) :` 归为 `.colon`；`parenArrowAfterOpen` 遇到 `.colon` 返回 `null`，让 parser 判断那是箭头返回类型还是三元冒号。当待入栈的 level>=256 时返回 null；256 槽还包含哨兵，最多同时保存 255 个开分隔符。

### `parenArrowAfterOpen` (`src/simple_token.zig:303`)

- **签名**：`pub fn parenArrowAfterOpen(source: []const u8, start: usize) ?bool`。
- **作用**：`(params)` 后是否同行 `=>`。
- **实现**：`balancedAfterOpen(source, start, '(', true)`，返回 `closed && following == .arrow`。内层失败则 null。
- **所有权 / 错误 / 调用**：`simpleCurrentParenIsArrowHead`。禁止跨行，所以 `(a)\n=>` 为 false（following 是 line_terminator）。

### `scanFollowing` (`src/simple_token.zig:308`)

- **签名**：`fn scanFollowing(source: []const u8, start: usize, no_line_terminator: bool) ?BalancedFollowing`。
- **作用**：闭合分隔符之后的 trivia + 一枚 token 分类。
- **实现**：ASCII 空白跳过。CR/LF：禁止跨行则 `.line_terminator`。`//` 同 `next`（禁止跨行当 LF）。块注释：与 `next` 不同，非 ASCII 会 `decodeAt` 认 LS/PS，而不是一律 unsupported。`=>` → arrow；`==` → other；单独 `=` → assignment。`,` `)` `]` `}` 对应变体。ASCII ident 扫完单词，`in` → `in_keyword` 否则 `identifier`。`\\` null。非 ASCII：行终结/空白同上，`IdentifierStart` → null（需要全量 lexer  intern），其它 `.other`。EOF → `.eof`。
- **所有权 / 错误 / 调用**：`balancedAfterOpen` 在 `closed` 时。返回 null 使整次 balanced 扫描失败。

### `identifierRegexpContext` (`src/simple_token.zig:404`)

- **签名**：`noinline fn identifierRegexpContext(word: []const u8) RegexpContext`。
- **作用**：按单词决定随后 `/` 是 regexp 还是除号。对齐 QuickJS skip-parens 的关键字分类。
- **实现**：`#` 或空 → disallowed。按 `len` + 首字节最多几次 `matches`：`if in do of var new for try else enum void with case while break throw catch class const super of yield return delete typeof switch export import default finally extends continue function debugger instanceof` → allowed；`let static await public package private interface protected implements` → mode_dependent；`null true this false` 及普通 ident → disallowed。minified 单字母名从不进表。
- **所有权 / 错误 / 调用**：仅当 `balancedAfterOpen` 在 ident 后见到 `/`。mode_dependent 遇到 `/` 返回 null。不分配、无 error set；`noinline` 把这张关键字表留在 `balancedAfterOpen` 主循环之外。

### `skipRegexp` (`src/simple_token.zig:482`)

- **签名**：`fn skipRegexp(source: []const u8, pos: *usize) bool`。
- **作用**：从 `/` 跳过 pattern 与 ASCII flags。
- **实现**：`pos.*+1` 起。CR/LF 或非 ASCII → false。`\\` 必须后跟非行终结。`[` 进类、类中 `]` 出类。类外 `/` 后吃 ASCII ident part；若随后是 `\\` 或非 ASCII flags → false。成功写回 `pos`。
- **所有权 / 错误 / 调用**：比 `LexerImpl.lexRegexp` 严（拒绝非 ASCII）。失败让 balanced 扫描 null。

### `skipNumberLike` (`src/simple_token.zig:517`)

- **签名**：`fn skipNumberLike(source: []const u8, pos: *usize) void`。
- **作用**：跳过数字模样的字节，不验证合法性。
- **实现**：digit、ASCII ident part、`.`、`_` 继续；`e/E` 后的 `+/-` 继续。
- **所有权 / 错误 / 调用**：`0x1fn`、`1e-2` 粗覆盖。总是前进，无失败。

### `matches` (`src/simple_token.zig:537`)

- **签名**：`inline fn matches(value: []const u8, candidate: []const u8) bool`。
- **作用**：关键字精确相等。
- **实现**：`std.mem.eql(u8, value, candidate)`。
- **所有权 / 错误 / 调用**：`identifierRegexpContext`、`scanFollowing` 的 `in`。

### `isAsciiDigit` (`src/simple_token.zig:541`)

- **签名**：`fn isAsciiDigit(c: u8) bool`。
- **作用**：`0-9`。
- **实现**：范围比较。
- **所有权 / 错误 / 调用**：`.digit` 小数、`skipNumberLike`。

### `isPunctuatorContinuation` (`src/simple_token.zig:545`)

- **签名**：`fn isPunctuatorContinuation(c: u8) bool`。
- **作用**：算符 token 的后续 ASCII（宽度不求精确）。
- **实现**：`= ! * & | ^ ? > <`。
- **所有权 / 错误 / 调用**：`balancedAfterOpen` 在 `=` 和其它算符后吞字节，避免把 `===` 拆成多个有效 token。不包含 `/`（除号已特判）。

### `skipQuoted` (`src/simple_token.zig:552`)

- **签名**：`fn skipQuoted(source: []const u8, pos: *usize, quote: u8) bool`。
- **作用**：跳过 `'...'` / `"..."`。
- **实现**：从 `pos+1`。遇 quote 成功。`\\` 吞下一字节，`\r\n` 算一行继续。原始 CR/LF 失败。非 ASCII 解码，LS/PS 失败，其它按 width 前进。未闭合 false。
- **所有权 / 错误 / 调用**：`balancedAfterOpen`。失败 → 整次扫描 null。

### `skipLineComment` (`src/simple_token.zig:579`)

- **签名**：`fn skipLineComment(source: []const u8, pos: *usize) bool`。
- **作用**：从 `//` 走到行终结前。
- **实现**：`pos+2` 起。CR/LF 停。非 ASCII：解码失败则 `pos=p` 返回 false；LS/PS 停（不消费）。成功 `pos=p`（停在 LF 上），true。
- **所有权 / 错误 / 调用**：`next` 与 `scanFollowing`。注释体可含非 ASCII。

### `skipBlockComment` (`src/simple_token.zig:598`)

- **签名**：`fn skipBlockComment(source: []const u8, pos: *usize) bool`。
- **作用**：从 `/*` 走到 `*/` 后。
- **实现**：`pos+2`，`p+1<len` 循环找 `*/`。未闭合 false。不处理嵌套。
- **所有权 / 错误 / 调用**：`balancedAfterOpen` 的 `/*` 分支。`next` 自己内联了块注释循环（因为要插入 `no_line_terminator`）。

### `startsWithAt` (`src/simple_token.zig:609`)

- **签名**：`fn startsWithAt(source: []const u8, start: usize, needle: []const u8) bool`。
- **作用**：绝对偏移处的前缀。
- **实现**：长度 + `mem.eql`。
- **所有权 / 错误 / 调用**：`...`、`<!--`、`-->`。

### `identifierOrKeyword` (`src/simple_token.zig:613`)

- **签名**：`fn identifierOrKeyword( source: []const u8, pos: *usize, start: usize, keyword: []const u8, keyword_kind: Kind, ) Kind`。
- **作用**：`import`/`export` 整词，否则返回 identifier；位置是否只推进一字节取决于是否匹配了关键字前缀。
- **实现**：前缀不等于 keyword → `finish(start+1, identifier)`。等于且 EOF → keyword。匹配了关键字前缀后，pos 推到前缀末尾；下一 ASCII 若 ident part → ident（`importx`），而不是只推进一字节。非 ASCII 解码：continue → ident；坏 UTF-8 → unsupported。
- **所有权 / 错误 / 调用**：`next` 仅对首字节 `i`/`e`。不扫完 ident 的其余字节（箭头前瞻不需要）。

### `decodeAt` (`src/simple_token.zig:646`)

- **签名**：`fn decodeAt(source: []const u8, start: usize) ?Decoded`。
- **作用**：UTF-8 一码点。
- **实现**：`utf8ByteSequenceLength` + 边界 + `utf8Decode`，失败 null。
- **所有权 / 错误 / 调用**：trivia、ident、字符串。null 在 `next` 变 unsupported，在 skip 路径变失败。

### `finish` (`src/simple_token.zig:653`)

- **签名**：`fn finish(pos: *usize, next_pos: usize, kind: Kind) Kind`。
- **作用**：提交 `pos` 并返回 kind。
- **实现**：`pos.* = next_pos; return kind`。
- **所有权 / 错误 / 调用**：`next` 每条 return。`line_terminator` 时 `next_pos` 仍是 LF 处，调用方可再扫。

覆盖核对见 [02-lexer.md](02-lexer.md) 文末。
