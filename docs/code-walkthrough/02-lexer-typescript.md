# 02 — Lexer：TypeScript 擦除

`lexer.zig` 后半不是完整 TS 解析器。`enableTypeScript` 用一份粗词法（`TSToken`）标出应从 JS 词法里跳过的源区间，写入 `LexerImpl.skipped_intervals`。`skipTrivia` 在这些区间上调用 `skipRange`，parser 只看见擦除后的 JavaScript。装饰器、`import=` / `export=` 不擦除，由 `findUnsupportedTypeScriptSyntax` 报错。

入口链：`shouldStrip` → `LexerImpl.enableTypeScript` → `markTypeRanges` → 各 `mark*` → 排序合并。生产调用在 `compileQjsProgram`（`parser.zig:16196`）。`is_typescript` 为真时 `simple_token` 前瞻全部关闭。

## 类型

### `Range`（`src/lexer.zig:1796`）

半开区间 `{ start, end }`，字节偏移。`skipRange` / `addRange` 的货币。合并时相邻或重叠区间并成一段，避免 `skipTrivia` 漏跳。

### `TypeScriptUnsupportedSyntax`（`src/lexer.zig:1801`）

`{ message, offset, line, column }`。`message` 是静态字符串，不拥有。行列 1-based，与 lexer 一致。

### `SourceKindImpl` / `SourceKind`（`src/lexer.zig:1808`，别名 `3313`）

`auto`：按文件名；`javascript`：永不擦除；`typescript`：总是擦除。parser `Options.source_kind` 用这个。

### `TSTokenKind`（`src/lexer.zig:1829`）

粗词法种类：`identifier` / `number` / `string` / `template` / `regexp` / `punct`。没有 keyword 枚举——关键字按 `text()` 比较。

### `TSToken`（`src/lexer.zig:1838`）

`{ kind, start, end }`。文本是 `src[start..end]`。不 intern、不解码转义。模板是整段 `` `...` `` 一个 token（不拆 `${`），足够做区间擦除，不够做语义。

### `ClassMethodSignature`（`src/lexer.zig:2434`）

类方法 overload 扫描结果：`start_idx` / `name_idx` / `end_idx` / `has_body`。无函数体且后面有同名实现时，签名整段进 `skipped_intervals`。

### `TypeScanEnd`（`src/lexer.zig:2943`）

`{ index, end }`：`index` 是停止处的 token 下标，`end` 是源字节（常为该 token 的 `start`，表示类型在它之前结束）。`>>` 可能停在 token 内部，`end` 小于 `tokens[i].end`。

---

## 函数

### `isTypeScriptPath` (`src/lexer.zig:1814`)

- **签名**：`pub fn isTypeScriptPath(path: []const u8) bool`。
- **作用**：文件名是否按 TS 擦除。
- **实现**：后缀 `.ts` / `.mts` / `.cts` / `.tsx`。不看内容。
- **所有权 / 错误 / 调用**：`shouldStrip(.auto, filename)`。无。

### `shouldStrip` (`src/lexer.zig:1821`)

- **签名**：`pub fn shouldStrip(kind: SourceKindImpl, filename: []const u8) bool`。
- **作用**：编译选项是否打开擦除。
- **实现**：`.typescript` true，`.javascript` false，`.auto` 跟路径。
- **所有权 / 错误 / 调用**：parser 两处调用：`compile`（`parser.zig:16090`，决定是否先跑不支持语法守卫）与 `compileQjsProgram`（`parser.zig:16196`，决定是否 `enableTypeScript`）。CLI/eval 默认 `auto`。

### `TSToken.text` (`src/lexer.zig:1843`)

- **签名**：`fn text(self: TSToken, src: []const u8) []const u8`。
- **作用**：token 源切片。
- **实现**：`src[start..end]`。
- **所有权 / 错误 / 调用**：不拥有。所有 `textEql` / `tokenTextEql` 的输入。

### `markTypeRanges` (`src/lexer.zig:1848`)

- **签名**：`fn markTypeRanges(self: *LexerImpl) !void`。
- **作用**：一次扫描源，填好合并后的 `skipped_intervals`。
- **实现**：`tsTokenize` 得到 `TSToken` 列表，依次 `markTypeOnlyStatements`、`markMixedTypeSpecifiers`、`markClassAndTypeModifiers`、`markImplementsClauses`、`markFunctionOverloadSignatures`、`markTypeParameters`、`markTypeAnnotations`、`markTypeAssertions`、`markNonNullAssertions`。`sort_erased.heap` 按 `rangeLessThan` 排序，然后线性合并：新区间 `start` 大于上一段 `end` 则 append，否则只在 `range.end` 比上一段 `end` 更大时才延长 `end`（被完全包含的区间丢弃）。
- **所有权 / 错误 / 调用**：临时 `tokens`/`ranges` defer deinit。结果留在 `self.skipped_intervals`。OOM。`enableTypeScript` 唯一调用方。

### `findUnsupportedTypeScriptSyntax` (`src/lexer.zig:1877`)

- **签名**：`pub fn findUnsupportedTypeScriptSyntax( allocator: std.mem.Allocator, src: []const u8, ) !?TypeScriptUnsupportedSyntax`。
- **作用**：擦除器不处理的语法：装饰器 `@`、`import =` / `import ident =`、`export =`。
- **实现**：`tsTokenize` 后扫 token。`@` 立即失败。`import` 后 `=` 或 ident 再 `=`；`export` 后 `=`。消息是静态英文。
- **所有权 / 错误 / 调用**：`compile`（`parser.zig:16091`）在 `compileQjsProgram` 打开擦除之前调用，命中就直接产 SyntaxError 返回。OOM。返回的 `message` 不需 free。

### `unsupportedSyntaxAt` (`src/lexer.zig:1925`)

- **签名**：`fn unsupportedSyntaxAt(src: []const u8, offset: usize, message: []const u8) TypeScriptUnsupportedSyntax`。
- **作用**：把字节偏移换成 1-based 行列。
- **实现**：扫到 `offset`：`\n` 换行；`\r` 可吞 `\n` 后换行；其它 `column+=1`。`offset` clamp 到 `src.len`。
- **所有权 / 错误 / 调用**：`message` 必须是静态生命期。无 error。

### `tsTokenize` (`src/lexer.zig:1951`)

- **签名**：`fn tsTokenize(allocator: std.mem.Allocator, src: []const u8, tokens: *std.ArrayList(TSToken)) !void`。
- **作用**：粗分词，供擦除启发式，不报词法错。
- **实现**：跳 ASCII 空白。`//` `/*` 注释。ident（`tsIsIdentStart`，含任意 `>=0x80` 字节当 ident 起点——比正式 lexer 粗）。数字 `tsSkipNumber`。引号 / 模板 / 在 `tsCanStartRegExp` 时的 `/`。否则 `tsPunctuatorLen` 当 punct。`prev_sig` 只为 regexp 歧义。
- **所有权 / 错误 / 调用**：未闭合字符串/注释吞到 EOF，不 error。OOM。

### `tsSkipLineComment` (`src/lexer.zig:1996`)

- **签名**：`fn tsSkipLineComment(src: []const u8, start: usize) usize`。
- **作用**：从注释体起点走到 LF/CR 或 EOF。
- **实现**：`while i < len and != \n/\r`。不认 LS/PS。
- **所有权 / 错误 / 调用**：返回新下标，不写入 tokens。

### `tsSkipBlockComment` (`src/lexer.zig:2002`)

- **签名**：`fn tsSkipBlockComment(src: []const u8, start: usize) usize`。
- **作用**：走到 `*/` 之后或 EOF。
- **实现**：未闭合返回 `src.len`，不报错。
- **所有权 / 错误 / 调用**：粗词法容错。

### `tsSkipQuoted` (`src/lexer.zig:2008`)

- **签名**：`fn tsSkipQuoted(src: []const u8, start: usize, quote: u8) usize`。
- **作用**：跳过引号字符串；原始换行视为结束（不包含换行）。
- **实现**：`escaped` 翻转；`\\` 下一字节任意；遇到 quote 返回 `i+1`。
- **所有权 / 错误 / 调用**：不解码。未闭合到 EOF。

### `tsSkipTemplate` (`src/lexer.zig:2027`)

- **签名**：`fn tsSkipTemplate(src: []const u8, start: usize) usize`。
- **作用**：从开 `` ` `` 扫到闭 `` ` ``。不跟踪 `${}` 嵌套——`${` 里的 `` ` `` 会提前结束。这是擦除器已知近似。
- **实现**：只处理 `\\` 与闭反引号。
- **所有权 / 错误 / 调用**：嵌套模板可能切错 token，后续 mark 偏保守。

### `tsSkipRegExp` (`src/lexer.zig:2045`)

- **签名**：`fn tsSkipRegExp(src: []const u8, start: usize) usize`。
- **作用**：跳过 `/pattern/flags`。
- **实现**：`in_class` / `escaped`；类外 `/` 后吃 ident continue 当 flags。LF/CR 提前停。
- **所有权 / 错误 / 调用**：`tsCanStartRegExp` 为真才走。

### `tsSkipNumber` (`src/lexer.zig:2077`)

- **签名**：`fn tsSkipNumber(src: []const u8, start: usize) usize`。
- **作用**：吃连续 word 字节或 `.`（`0x1f`、`1.2e3` 粗覆盖）。
- **实现**：`unicode.isAsciiWordByte` 或 `.`。
- **所有权 / 错误 / 调用**：可能把 `1..2` 的两个点吃进数字；punct 启发式仍能工作。

### `tsPunctuatorLen` (`src/lexer.zig:2090`)

- **签名**：`fn tsPunctuatorLen(rest: []const u8) usize`。
- **作用**：最长 punct 匹配，否则 1。
- **实现**：表：`>>>=` `===` `!==` `>>>` `<<=` `>>=` `...` `=>` 以及双字符算符。单字符（含 `<` `>` `!` `@`）走 1。
- **所有权 / 错误 / 调用**：`tsTokenize`。顺序最长优先。

### `tsCanStartRegExp` (`src/lexer.zig:2103`)

- **签名**：`fn tsCanStartRegExp(prev: ?TSToken, src: []const u8) bool`。
- **作用**：粗分词里 `/` 是 regexp 还是除号。
- **实现**：无 prev → true。prev ident 仅 `return throw case delete void typeof yield await in of instanceof`。prev punct：开界、`,` `;` `:` `=` `=>` `!` `?` 逻辑/算术算符。其它（`ident` 普通名、`)` `]` 数字字符串）false。
- **所有权 / 错误 / 调用**：比 `simple_token.identifierRegexpContext` 粗，只服务擦除。

### `markTypeOnlyStatements` (`src/lexer.zig:2122`)

- **签名**：`fn markTypeOnlyStatements( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：整句擦除：`import type`、`export type`、`export interface`、`export declare`、`declare`、顶层 `interface`、`type` 别名。
- **实现**：按 token 文本匹配。`import type` / `export type` / `type` 别名用 `findStatementEnd`。interface/declare 走 `addInterfaceRange` / `addDeclareRange`（要吃到匹配 `}`）。`type` 须 `isStatementStart` 且 `looksLikeTypeAlias`。
- **所有权 / 错误 / 调用**：OOM。`export type { X }` 整句去掉（类型-only 导出）。

### `addDeclareRange` (`src/lexer.zig:2164`)

- **签名**：`fn addDeclareRange( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), range_start_idx: usize, declare_idx: usize, ) !void`。
- **作用**：从 `declare`（或前面的 `export`）标到声明结束。
- **实现**：`declare interface` 转 `addInterfaceRange`。否则 `findStatementEnd`，若中途有 `{` 则用 `findMatchingForward` 扩到闭合 `}` 及可选 `;`。
- **所有权 / 错误 / 调用**：覆盖 `declare class/namespace/function/var` 等整段。

### `addInterfaceRange` (`src/lexer.zig:2193`)

- **签名**：`fn addInterfaceRange( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), range_start_idx: usize, interface_idx: usize, ) !void`。
- **作用**：interface 声明（可带 `export`/`declare` 前缀）整段擦除。
- **实现**：同 declare：statement end，遇 `{` 扩到匹配 `}` + 可选 `;`。
- **所有权 / 错误 / 调用**：体里的 `;` 不会提前截断。

### `looksLikeTypeAlias` (`src/lexer.zig:2217`)

- **签名**：`fn looksLikeTypeAlias(src: []const u8, tokens: []const TSToken, type_idx: usize) bool`。
- **作用**：区分 `type Foo = ...` 与标识符 `type`。
- **实现**：从 `type` 后跟踪 `{}()[]` 深度；深度 0 遇到闭界（下溢）直接假；深度 0 见到 `=` 为真；深度 0 见到 `;`、或当前 token 与 `type` 之间已隔换行则假；扫到结尾也是假。
- **所有权 / 错误 / 调用**：`markTypeOnlyStatements`。

### `markMixedTypeSpecifiers` (`src/lexer.zig:2236`)

- **签名**：`fn markMixedTypeSpecifiers( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：`import { type A, b }` 去掉 `type A`（及多余逗号）；若花括号里全是 type-only 则整句 `import/export` 擦掉。
- **实现**：跳过已是 `import type` 的。在语句内找 `{`…`}`，按逗号切 specifier。段以 `type` 开头则标区间：尽量连上前导或尾随逗号。计数 `spec_count != 0` 且 `spec_count == type_spec_count` 才标整句。
- **所有权 / 错误 / 调用**：`import { type A }` 变成空 `import {}` 再被整句删除。

### `markClassAndTypeModifiers` (`src/lexer.zig:2281`)

- **签名**：`fn markClassAndTypeModifiers( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦 `public/private/protected/readonly/override/abstract`，但构造器参数属性保留。
- **实现**：见到 `constructor (` 进入参数层，`paren_depth` 计顶层参数。顶层参数（`paren_depth == 1`）里的 `public/private/protected/readonly` `continue` 不擦——它们留在源里作为构造器参数属性，由 parser 在 `is_typescript` 且函数是 class constructor 时用 `isParameterModifier`（`parser.zig:2779`）识别并消费。`abstract class` 只擦 `abstract`。其它位置 `modifierCanAppearsHere` 为真才擦。
- **所有权 / 错误 / 调用**：OOM。不擦 `static`/`async`（那是 JS）。

### `modifierCanAppearsHere` (`src/lexer.zig:2331`)

- **签名**：`fn modifierCanAppearsHere(src: []const u8, tokens: []const TSToken, idx: usize) bool`。
- **作用**：避免把表达式里的同名 ident 当修饰符。
- **实现**：下一 token 是 `(` `:` `=` `;` → false（调用/标注/赋值）。上一 token 须是 `{` `(` `,` `;`，或文件开头。
- **所有权 / 错误 / 调用**：`markClassAndTypeModifiers`。

### `isTsModifier` (`src/lexer.zig:2341`)

- **签名**：`fn isTsModifier(txt: []const u8) bool`。
- **作用**：是否 TS 修饰符拼写。
- **实现**：`public private protected readonly override abstract`。
- **所有权 / 错误 / 调用**：类成员与参数扫描。

### `findImplementsClassBrace` (`src/lexer.zig:2346`)

- **签名**：`fn findImplementsClassBrace(src: []const u8, tokens: []const TSToken, start_idx: usize) ?usize`。
- **作用**：从 `implements` 之后找到类体 `{`。
- **实现**：前进直到 `{`。遇到 `;` `}` 或声明/控制关键字（`const let var function class interface if while for return`）返回 null。
- **所有权 / 错误 / 调用**：`markImplementsClauses`。不跟踪泛型深度——`implements Array<T>` 的 `<` 不当界。

### `markImplementsClauses` (`src/lexer.zig:2368`)

- **签名**：`fn markImplementsClauses( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦 `implements A, B` 直到类体 `{` 之前。
- **实现**：每个 `implements` 找 brace，区间 `[implements.start, brace.start)`，然后 `i = brace_idx - 1` 避免重复。
- **所有权 / 错误 / 调用**：留下 `class C {`。`extends` 不在这里（那是 JS）。

### `markFunctionOverloadSignatures` (`src/lexer.zig:2383`)

- **签名**：`fn markFunctionOverloadSignatures( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦以 `;` 结束的函数重载签名（可带 `export default async`），再处理类方法重载。
- **实现**：找 `function`，向左吸收 `async`（须与 `function` 同行）、再 `default`、再 `export`（后两个不查换行）。跳可选 `*`、名字、可选 `<...>`、`(params)`。若 `:` 返回类型则必须落到 `;`；否则必须 `;`。有 `{` 的实现不擦。最后调 `markClassMethodOverloadSignatures`。
- **所有权 / 错误 / 调用**：实现函数留下。OOM。

### `markClassMethodOverloadSignatures` (`src/lexer.zig:2441`)

- **签名**：`fn markClassMethodOverloadSignatures( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：类体里无函数体、且后面有同名带体方法的签名擦掉。
- **实现**：每个 `class` 找 body `{`…`}`。成员循环：跳 `;`，`parseClassMethodSignature`；`!has_body` 且 `hasFollowingClassMethodImplementation` 则标整段。
- **所有权 / 错误 / 调用**：单条抽象方法（后面无实现）不擦，留给 JS 当语法错或后续路径。

### `findClassBodyOpen` (`src/lexer.zig:2474`)

- **签名**：`fn findClassBodyOpen(src: []const u8, tokens: []const TSToken, class_idx: usize) ?usize`。
- **作用**：`class` 后第一个「顶层」`{`（泛型/heritage 的括号不算）。
- **实现**：跟踪 `<>()[]{}` 深度。`>` 用 `consumeTypeAngleClosers`（`>>` 可关两层）。四层都 0 的 `{` 即类体。顶层 `;` → null。
- **所有权 / 错误 / 调用**：方法 overload、`braceBelongsToClass`。

### `skipClassMemberSeparators` (`src/lexer.zig:2510`)

- **签名**：`fn skipClassMemberSeparators(src: []const u8, tokens: []const TSToken, start_idx: usize, class_close_idx: usize) usize`。
- **作用**：跳过成员间的 `;`。
- **实现**：`while token == ";" and i < close`。
- **所有权 / 错误 / 调用**：类成员扫描。

### `parseClassMethodSignature` (`src/lexer.zig:2516`)

- **签名**：`fn parseClassMethodSignature(src: []const u8, tokens: []const TSToken, member_start: usize, class_close_idx: usize) ?ClassMethodSignature`。
- **作用**：从成员起点解析「修饰符* `*`? name 类型参数? (params) 返回类型? `;`|`{body}`」。
- **实现**：吃 `isClassMethodModifierAt`。可选 `*`。名字必须 ident。可选 `<...>`；`(` 必须存在并 `findMatchingForward` 匹配到 `)`。可选 `: type`。`;` → `has_body=false`；`{` 匹配到 `}` → `has_body=true`。对不上返回 null（字段、构造器参数属性等）。
- **所有权 / 错误 / 调用**：不处理计算名 `[x]()`、字符串名。

### `isClassMethodModifierAt` (`src/lexer.zig:2565`)

- **签名**：`fn isClassMethodModifierAt(src: []const u8, tokens: []const TSToken, idx: usize) bool`。
- **作用**：类方法前的修饰符，不含 `static()` / `async()` 这种名字。
- **实现**：`isTsModifier` 或（`static`/`async` 且下一 token 不是 `(`）。
- **所有权 / 错误 / 调用**：`parseClassMethodSignature`。

### `hasFollowingClassMethodImplementation` (`src/lexer.zig:2574`)

- **签名**：`fn hasFollowingClassMethodImplementation(src: []const u8, tokens: []const TSToken, name_idx: usize, start_idx: usize, class_close_idx: usize) bool`。
- **作用**：后面是否还有同名、带体的方法。
- **实现**：继续 parse 签名；名字 `sameTokenText` 不同则 false；`has_body` 则 true；无体则继续找。
- **所有权 / 错误 / 调用**：连续 overload 只擦无体的那些。

### `sameTokenText` (`src/lexer.zig:2588`)

- **签名**：`fn sameTokenText(src: []const u8, a: TSToken, b: TSToken) bool`。
- **作用**：两 token 源文本相等。
- **实现**：`textEql(a.text, b.text)`。
- **所有权 / 错误 / 调用**：方法名比较。

### `nextClassMemberStart` (`src/lexer.zig:2592`)

- **签名**：`fn nextClassMemberStart(src: []const u8, tokens: []const TSToken, start_idx: usize, class_close_idx: usize) usize`。
- **作用**：当前成员解析失败时，跳到下一成员。
- **实现**：跟踪 `()[]{}`。顶层 `{` 视为方法/静态块，跳到匹配 `}` 后。顶层 `;` 下一 token。`}` 且 brace 已 0 则到 class close。
- **所有权 / 错误 / 调用**：字段初始化器里的 `;` 在深度 0 才会停。

### `markTypeParameters` (`src/lexer.zig:2626`)

- **签名**：`fn markTypeParameters( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦 `fn f<T>()` / `Foo<T>` 这类类型参数列表。
- **实现**：每个 `<` 若 `looksLikeTypeParameterStart` 且 `findTypeAngleEnd` 成功，标 `[<, >]`（`end` 可在 `>>` 中间）。
- **所有权 / 错误 / 调用**：比较运算 `<` 因 `isValidTypeParameterList` 失败而留下。

### `looksLikeTypeParameterStart` (`src/lexer.zig:2643`)

- **签名**：`fn looksLikeTypeParameterStart(src: []const u8, tokens: []const TSToken, lt_idx: usize) bool`。
- **作用**：`<` 是否可能是类型参数而非小于号。
- **实现**：`lt_idx==0` false。prev 是 `)` `]` / number / string / regexp → 比较或泛型调用的结束，false。`prev == "class"` 且 `lt_idx>=2` 也 false（只挡 `class <` 直接相邻；`class C<T>` 的 prev 是 ident `C`，仍 true）。
- **所有权 / 错误 / 调用**：`markTypeParameters`。

### `markTypeAnnotations` (`src/lexer.zig:2654`)

- **签名**：`fn markTypeAnnotations( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦 `: Type` 以及可选的 `?`（`x?: T` 的 `?` 一并去掉）。
- **实现**：每个 `:` 经 `isTypeAnnotationColon`。`stop_arrow` 当上一 token 是 `)`（返回类型遇到 `=>` 要停，以免吃掉箭头）。起点若上一 token 是 `?` 则从 `?` 开始。
- **所有权 / 错误 / 调用**：对象字面量 `: expr` 被 `isTypeAnnotationColon` 拒绝。

### `isTypeAnnotationColon` (`src/lexer.zig:2671`)

- **签名**：`fn isTypeAnnotationColon(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool`。
- **作用**：这个 `:` 是类型标注而不是对象字段或三元。
- **实现**：`hasUnmatchedTernaryQuestionBefore` → false。上一有效 token（跳过 `?`）若是 `)` → 返回类型，true。否则 `findEnclosingOpen`：`(` 则 `isParameterList`；`{` 若类体则 `classFieldSegmentAllowsType`，否则 `isVariableDeclarationType`；无包围则变量声明类型。
- **所有权 / 错误 / 调用**：`a ? b : c` 被 ternary 检查挡住。

### `isParameterList` (`src/lexer.zig:2699`)

- **签名**：`fn isParameterList(src: []const u8, tokens: []const TSToken, open_idx: usize) bool`。
- **作用**：`(` 是否函数/方法/箭头形参表。
- **实现**：匹配 `)`。主人 `parameterListOwnerIndex`。控制关键字 `if/for/...` false。`function`/`constructor` true。`function ident (` true。ident 后 `{`/`=>` true。ident 或主人后 `:` 则看返回类型是否落到 `{`/`=>`。`)` 后直接 `=>` true。
- **所有权 / 错误 / 调用**：调用表达式 `(x): T` 很少过这些条件。

### `parameterListOwnerIndex` (`src/lexer.zig:2716`)

- **签名**：`fn parameterListOwnerIndex(src: []const u8, tokens: []const TSToken, open_idx: usize) ?usize`。
- **作用**：`(` 前的名字或 `function`，跳过 `>` 关闭的类型参数。
- **实现**：`open_idx-1`；若该 token 以 `>` 开头，`findTypeAngleStartBackward` 再取 `<` 前一个。
- **所有权 / 错误 / 调用**：`f<T>(` 的 owner 是 `f`。

### `findTypeAngleStartBackward` (`src/lexer.zig:2727`)

- **签名**：`fn findTypeAngleStartBackward(src: []const u8, tokens: []const TSToken, gt_idx: usize) ?usize`。
- **作用**：从 `>`/`>>` 回退到匹配的 `<`。
- **实现**：`depth = leadingGreaterCount`。回退时再遇 `>` 加深，遇 `<` 减；depth 到 1 的 `<` 即起点。
- **所有权 / 错误 / 调用**：`parameterListOwnerIndex`。

### `leadingGreaterCount` (`src/lexer.zig:2744`)

- **签名**：`fn leadingGreaterCount(txt: []const u8) usize`。
- **作用**：token 前导 `>` 个数（`>` `>>` `>>>` `>>=`…）。
- **实现**：数前缀 `>`。
- **所有权 / 错误 / 调用**：角度括号深度。

### `returnTypeAfterParameterListLeadsToBody` (`src/lexer.zig:2750`)

- **签名**：`fn returnTypeAfterParameterListLeadsToBody(src: []const u8, tokens: []const TSToken, close_idx: usize) bool`。
- **作用**：`) : Type {` 或 `) : Type =>` 才把 `(` 当参数表。
- **实现**：下一 token 必须 `:`，`findTypeEnd(..., true)` 后是 `{` 或 `=>`。
- **所有权 / 错误 / 调用**：`isParameterList`。

### `isControlKeyword` (`src/lexer.zig:2756`)

- **签名**：`fn isControlKeyword(txt: []const u8) bool`。
- **作用**：`if for while switch with catch` 的 `(` 不是参数表。
- **实现**：六词 `textEql`。
- **所有权 / 错误 / 调用**：`isParameterList`。

### `isVariableDeclarationKeyword` (`src/lexer.zig:2761`)

- **签名**：`fn isVariableDeclarationKeyword(txt: []const u8) bool`。
- **作用**：`let`/`const`/`var`。
- **实现**：三词比较。
- **所有权 / 错误 / 调用**：`isVariableDeclarationType`。

### `isVariableDeclarationType` (`src/lexer.zig:2765`)

- **签名**：`fn isVariableDeclarationType(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool`。
- **作用**：`let x: T` / `const {a}: T` 的 `:`，而不是对象字面量。
- **实现**：回退找语句起点（顶层 `;` 或未匹配的开界）。正向扫：见到声明关键字；记下最近的逗号/声明后位置。再从该位置扫到 `:`，深度 0 的 `=` 则 false（已是初始化器）。必须 `saw_decl`。
- **所有权 / 错误 / 调用**：解构 `let {a: b}` 的 `:`：回退时遇到未匹配的 `{` 就把语句起点定在其后，`let` 落在窗口外，`saw_decl` 为假 → false。类字段走 `classFieldSegmentAllowsType` 另一条路。

### `classFieldSegmentAllowsType` (`src/lexer.zig:2858`)

- **签名**：`fn classFieldSegmentAllowsType(src: []const u8, tokens: []const TSToken, class_open_idx: usize, colon_idx: usize) bool`。
- **作用**：类字段 `x: T` 允许擦类型；`x = y: z` 这种段内已有 `=` 则不许。
- **实现**：从 `colon` 回退到最近 `;` `{` `}` 作为段起点，再正向看是否有 `=`。
- **所有权 / 错误 / 调用**：`isTypeAnnotationColon` 在类体 `{` 内。

### `markTypeAssertions` (`src/lexer.zig:2875`)

- **签名**：`fn markTypeAssertions( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦 `expr as T` / `expr satisfies T`。
- **实现**：跳过 import/export 语句里的 `as`（`import x as y`）。`isTypeAssertionOperator` 确认左是表达式结束、右不是分隔符。`findTypeAssertionEnd` 定右界。
- **所有权 / 错误 / 调用**：`as const` 仍被当成类型断言擦掉（`const` 当类型 token 吃到 delimiter）。

### `markNonNullAssertions` (`src/lexer.zig:2892`)

- **签名**：`fn markNonNullAssertions( allocator: std.mem.Allocator, src: []const u8, tokens: []const TSToken, ranges: *std.ArrayList(Range), ) !void`。
- **作用**：擦后缀 `!`（`x!`）。
- **实现**：`!` 的 prev 是 ident/number/string/`)`/`]`，next 不是 `=`/`==`/`===`（避免 `!=`）。只标 `!` 自身。
- **所有权 / 错误 / 调用**：逻辑非 `!x` 的 prev 不是表达式结束。

### `isTypeAssertionOperator` (`src/lexer.zig:2911`)

- **签名**：`fn isTypeAssertionOperator(src: []const u8, tokens: []const TSToken, idx: usize) bool`。
- **作用**：`as`/`satisfies` 是否类型断言算符。
- **实现**：`previousTokenCanEndExpression`。next 不能是 `:` `,` `;` `)` `}` `=`。
- **所有权 / 错误 / 调用**：`markTypeAssertions`。

### `previousTokenCanEndExpression` (`src/lexer.zig:2923`)

- **签名**：`fn previousTokenCanEndExpression(src: []const u8, prev_token: TSToken) bool`。
- **作用**：prev 能否结束一个表达式。
- **实现**：ident 走 `identifierCanEndExpression`；字面量 true；punct 仅 `)` `]` `}`。
- **所有权 / 错误 / 调用**：`as` 左边。

### `identifierCanEndExpression` (`src/lexer.zig:2934`)

- **签名**：`fn identifierCanEndExpression(txt: []const u8) bool`。
- **作用**：排除不能出现在表达式末尾的关键字。
- **实现**：不是 `const let var function class return throw case delete typeof void new in instanceof yield await`。
- **所有权 / 错误 / 调用**：`foo as T` 的 `foo` 通过；`return as` 不通过。

### `findTypeEnd` (`src/lexer.zig:2948`)

- **签名**：`fn findTypeEnd(src: []const u8, tokens: []const TSToken, start_idx: usize, stop_arrow: bool) ?TypeScanEnd`。
- **作用**：从类型起点扫到类型结束（逗号/分号/等号/闭界，可选 `=>`）。
- **实现**：跟踪 `()[]{}<>`。深度 0 的闭界返回该 token 的 `start`（类型不含闭界）。起始 `{` 当作对象类型吃进去；非起始且四层都 0 的 `{` 当语句体，停在 `{` 前。`>` 用 `consumeTypeAngleClosers`，可能在 `>>` 中切开。
- **所有权 / 错误 / 调用**：标注、返回类型。EOF 返回 null，调用方用 `src.len`。

### `findTypeAssertionEnd` (`src/lexer.zig:2985`)

- **签名**：`fn findTypeAssertionEnd(src: []const u8, tokens: []const TSToken, start_idx: usize) ?TypeScanEnd`。
- **作用**：`as`/`satisfies` 右侧类型的结束，比 `findTypeEnd` 多认表达式分隔符。
- **实现**：同样深度计数。深度 0 且 `isExpressionDelimiter`（含 `||` `&&` `+` `==` 等）则停。
- **所有权 / 错误 / 调用**：`x as T && y` 在 `&&` 前停。

### `isExpressionDelimiter` (`src/lexer.zig:3015`)

- **签名**：`fn isExpressionDelimiter(txt: []const u8) bool`。
- **作用**：断言类型不能跨越的算符。
- **实现**：`,` `;` `:` `?` `}` `=>` 逻辑/算术/比较/`=`。
- **所有权 / 错误 / 调用**：`findTypeAssertionEnd`。不含 `.`（`as Foo.Bar` 继续）。

### `isValidTypeParameterList` (`src/lexer.zig:3024`)

- **签名**：`fn isValidTypeParameterList(src: []const u8, tokens: []const TSToken, start: usize, end: usize) bool`。
- **作用**：`< ... >` 是否像类型参数而不是 `<` 比较。
- **实现**：内部禁止 `&& || ?? == != === !== * / % instanceof ++ --` 及一批语句关键字。闭合后下一 token：ident 只允许 `extends implements as satisfies`；否则须 `typeParameterListCanBeFollowedBy`；number/string/regexp 禁止。
- **所有权 / 错误 / 调用**：`findTypeAngleEnd` 在深度归零时检查。

### `typeParameterListCanBeFollowedBy` (`src/lexer.zig:3064`)

- **签名**：`fn typeParameterListCanBeFollowedBy(txt: []const u8) bool`。
- **作用**：`>` 后合法的 punct：`( { [ , => = : ; ) ] | & . ? !`。
- **实现**：一串 `textEql`。
- **所有权 / 错误 / 调用**：`f<T>(`、`T | U`、`x!` 等。

### `findTypeAngleEnd` (`src/lexer.zig:3072`)

- **签名**：`fn findTypeAngleEnd(src: []const u8, tokens: []const TSToken, lt_idx: usize) ?TypeScanEnd`。
- **作用**：从 `<` 找到匹配 `>`，并验证是类型参数表。
- **实现**：`depth` 从 0，遇 `<` +1。嵌套 `()[]{}`。在 depth==1 时未匹配的 `)` `]` `}` 或 `;` → null。`>` 序列把 depth 减到 0 后要求 paren/bracket/brace 为 0 且 `isValidTypeParameterList`。
- **所有权 / 错误 / 调用**：类型参数、方法签名、`parameterListOwnerIndex` 的前向对应物。

### `startsWithGreater` (`src/lexer.zig:3112`)

- **签名**：`fn startsWithGreater(txt: []const u8) bool`。
- **作用**：token 是否以 `>` 开头（含 `>>` `>=`）。
- **实现**：`txt.len>0 and txt[0]=='>'`。
- **所有权 / 错误 / 调用**：角度括号关闭。

### `consumeTypeAngleClosers` (`src/lexer.zig:3116`)

- **签名**：`fn consumeTypeAngleClosers(txt: []const u8, token_start: usize, depth: *usize) ?usize`。
- **作用**：把 `>>` 拆成两个 `>` 来关泛型；depth 到 0 时返回切开点的源偏移。
- **实现**：每吃一个 `>` 且 `depth>0` 就 `depth-=1`；减到 0 返回 `token_start+consumed+1`。没把 depth 吃到 0 返回 null。
- **所有权 / 错误 / 调用**：`A<B<C>>` 的 `>>` 一个 punct token。

### `findStatementEnd` (`src/lexer.zig:3127`)

- **签名**：`fn findStatementEnd(src: []const u8, tokens: []const TSToken, start_idx: usize) usize`。
- **作用**：从语句起点估结束偏移。
- **实现**：`()[]{}` 深度。深度 0 的 `;` 或 `}` 结束。深度 0 且与下一 token 有换行、且当前 token 不 `continuesAcrossLine` 则结束（ASI 近似）。否则 `src.len`。
- **所有权 / 错误 / 调用**：type-only 语句、declare。

### `continuesAcrossLine` (`src/lexer.zig:3148`)

- **签名**：`fn continuesAcrossLine(txt: []const u8) bool`。
- **作用**：这些 token 后的换行不断句。
- **实现**：`,` `=` `|` `&` `?` `:` `extends` `(` `{` `[`。
- **所有权 / 错误 / 调用**：`findStatementEnd`。

### `findMatchingForward` (`src/lexer.zig:3154`)

- **签名**：`fn findMatchingForward(src: []const u8, tokens: []const TSToken, open_idx: usize, open_text: []const u8, close_text: []const u8) ?usize`。
- **作用**：括号匹配，返回闭合 token 下标。
- **实现**：从 `open_idx` 计 depth，同文 open +1、close -1，到 0 返回。不处理字符串（已是独立 token）。
- **所有权 / 错误 / 调用**：各类 mark。文本必须精确 `(` / `{` 等。

### `findEnclosingOpen` (`src/lexer.zig:3169`)

- **签名**：`fn findEnclosingOpen(src: []const u8, tokens: []const TSToken, idx: usize) ?usize`。
- **作用**：回退找包围 `idx` 的最近未闭合 `(` `[` `{`。
- **实现**：反向计 `) ] }` 加深、开界在对应深度 0 时返回。
- **所有权 / 错误 / 调用**：`isTypeAnnotationColon`、import/export 内的 `as`。

### `braceBelongsToClass` (`src/lexer.zig:3191`)

- **签名**：`fn braceBelongsToClass(src: []const u8, tokens: []const TSToken, open_idx: usize) bool`。
- **作用**：这个 `{` 是否某 `class` 的类体。
- **实现**：回退找 `class`，`findClassBodyOpen` 结果须等于 `open_idx`。遇 `;` 停 false。
- **所有权 / 错误 / 调用**：类字段类型 vs 对象类型字面量。

### `hasUnmatchedTernaryQuestionBefore` (`src/lexer.zig:3204`)

- **签名**：`fn hasUnmatchedTernaryQuestionBefore(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool`。
- **作用**：`:` 是否三元的冒号。
- **实现**：若上一 token 已是 `?`（`x?: T`）返回 false。否则回退，深度 0 的 `?` true；`;` `,` 或未匹配开界停下 false。
- **所有权 / 错误 / 调用**：`isTypeAnnotationColon` 第一道闸。

### `insideImportOrExportStatement` (`src/lexer.zig:3231`)

- **签名**：`fn insideImportOrExportStatement(src: []const u8, tokens: []const TSToken, idx: usize) bool`。
- **作用**：避免把 `import { a as b }` 的 `as` 当类型断言。
- **实现**：回退到上一 `;` 当语句起点。语句内到 `idx` 前若有 `=` 则 false（赋值）。有 `import` true。有 `export`：`findEnclosingOpen` 一旦有结果就以「该开界是 `{` 且在本句内」直接定论（是 `(`/`[` 就 false）；只有完全没有包围开界时才回头看句内有无 `*`/`from`。
- **所有权 / 错误 / 调用**：`markTypeAssertions`。

### `isStatementStart` (`src/lexer.zig:3266`)

- **签名**：`fn isStatementStart(src: []const u8, tokens: []const TSToken, idx: usize) bool`。
- **作用**：token 是否像语句开头（`interface`/`type` 才擦）。
- **实现**：`idx==0` 或 prev 是 `;` `{` `}`。
- **所有权 / 错误 / 调用**：`markTypeOnlyStatements`。方法里的 `interface` ident 不擦。

### `findTokenBeforeOffset` (`src/lexer.zig:3272`)

- **签名**：`fn findTokenBeforeOffset(src: []const u8, tokens: []const TSToken, start_idx: usize, end_offset: usize, needle: []const u8) ?usize`。
- **作用**：在 `[start_idx, end_offset)` 源范围内找文本等于 `needle` 的 token。
- **实现**：`tokens[i].start < end_offset` 且文本相等。
- **所有权 / 错误 / 调用**：`markMixedTypeSpecifiers` 找 `{`。

### `hasLineBreakBetween` (`src/lexer.zig:3280`)

- **签名**：`fn hasLineBreakBetween(src: []const u8, start: usize, end: usize) bool`。
- **作用**：两偏移之间是否有 CR/LF。
- **实现**：扫字节。不认 LS/PS。
- **所有权 / 错误 / 调用**：ASI 近似、`async function` 同行检查。

### `addRange` (`src/lexer.zig:3288`)

- **签名**：`fn addRange(ranges: *std.ArrayList(Range), allocator: std.mem.Allocator, start: usize, end: usize) !void`。
- **作用**：追加半开区间；空区间丢弃。
- **实现**：`end<=start` return。`array_list_erased.append`。
- **所有权 / 错误 / 调用**：所有 mark*。OOM。尚未合并。

### `rangeLessThan` (`src/lexer.zig:3293`)

- **签名**：`fn rangeLessThan(_: void, a: Range, b: Range) bool`。
- **作用**：按 `start` 排序。
- **实现**：`a.start < b.start`。
- **所有权 / 错误 / 调用**：`sort_erased.heap` 在 `markTypeRanges`。

### `tokenTextEql` (`src/lexer.zig:3297`)

- **签名**：`fn tokenTextEql(src: []const u8, tokens: []const TSToken, idx: usize, expected: []const u8) bool`。
- **作用**：带越界保护的 token 文本比较。
- **实现**：`idx < len and textEql(tokens[idx].text(src), expected)`。
- **所有权 / 错误 / 调用**：前瞻 `i+1` 不必每次检查长度。

### `textEql` (`src/lexer.zig:3301`)

- **签名**：`fn textEql(a: []const u8, b: []const u8) bool`。
- **作用**：擦除器字符串相等。
- **实现**：`std.mem.eql(u8, a, b)`。
- **所有权 / 错误 / 调用**：所有关键字/punct 比较。大小写敏感。

### `tsIsIdentStart` (`src/lexer.zig:3305`)

- **签名**：`fn tsIsIdentStart(c: u8) bool`。
- **作用**：粗 ident 起点：ASCII start 或任意非 ASCII 字节。
- **实现**：不解码 UTF-8。非 ASCII 整段会被 `tsIsIdentContinue` 吃进同一个 ident。
- **所有权 / 错误 / 调用**：比正式 lexer 宽，擦除宁多勿少。

### `tsIsIdentContinue` (`src/lexer.zig:3309`)

- **签名**：`fn tsIsIdentContinue(c: u8) bool`。
- **作用**：粗 ident 续：start 或 ASCII 数字。
- **实现**：`tsIsIdentStart or isAsciiDigitByte`。
- **所有权 / 错误 / 调用**：ident 与 regexp flags。

覆盖核对见 [02-lexer.md](02-lexer.md) 文末。
