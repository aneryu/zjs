# Parser：TypeScript 一等公民重设计

状态：v1.0，2026-09-19 落地。取代 lexer 侧的"类型区间擦除器"。

## 1. 目标与边界

- **一套文法**。lexer 与 parser 不再区分 JS 与 TS 输入：`Options.source_kind`、
  `EvalSourceKind`、文件后缀判定全部删除。任何文件都按 TS 文法（JS 的超集）解析。
- **发射层不动**。类型语法由 parser 内一组**纯解析函数**消费：只推进 token，
  不发射字节码、不登记作用域、不改 `features`。JS 输入产出的字节码逐位不变，
  由 `zjs --bytecode-fingerprint` 在语料上前后对比作硬门。
- **运行时语义的 TS 语法保留并补齐**：`enum`/`const enum`（常量折叠 + 运行时表达式
  兜底）、`namespace`/`module`（含点号嵌套、`export`）、构造器参数属性、
  `import x = A.B` 别名。装饰器、`accessor` 字段与 `import x = require()`/`export =`
  明确拒绝。
- **JSX 不在范围**。`.tsx`/`.jsx` 文件名在 compile 入口直接报 SyntaxError。

## 2. 与 JS 的三处已知分歧

TS 文法在三处与 JS 对同一 token 序列给出不同解释，全部按 TS 解释：

| 输入 | JS | 本 parser |
| --- | --- | --- |
| `f<T>(x)` | `(f < T) > (x)` | 泛型调用 `f(x)` |
| `<T>expr` | 语法错误 | 尖括号断言，等价于 `expr` |
| `cond ? (a): T => b : c` | 三元 | 三元的 whenTrue 分支禁止箭头返回类型，仍按 JS 解析 |

前两条在真实 JS 中不出现；第三条沿用 tsc 的 `allowReturnTypeInArrowFunction` 规则，
通过 `ParseFlags.arrow_return_type_forbidden` 只在 `?:` 的 whenTrue 分支置位。

上下文关键字（`type`/`interface`/`declare`/`namespace`/`module`/`abstract`/`as`/
`satisfies`/`readonly`/`keyof`…）只在特定形状下生效，其余位置仍是普通标识符，
test262 的 `var interface = 1` 一类用例保持通过。

## 3. 词法层改动（`src/lexer.zig`）

- 删除：`is_typescript`、`skipped_intervals`、`enableTypeScript`、`skipRange`、
  `getSkippedIntervalAtPos`、`skipTrivia` 里的区间跳过、`SourceKindImpl`、
  `isTypeScriptPath`、`shouldStrip`、`findUnsupportedTypeScriptSyntax`、`tsTokenize`
  与全部 `mark*` 启发式（约 1.5k 行）。
- 新增 `splitGreaterThan(tok)` / `splitLessThan(tok)`：当类型解析器需要一个 `>`（`<`）
  而当前 token 是 `>>`/`>>>`/`>=`/`>>=`/`>>>=`（`<<`/`<<=`）时，把 token 截成单字符，
  并把 `pos` 回退到该字符之后，余下字符由下一次 `nextInto` 重新切分。这是泛型闭合
  `A<B<C>>` 的唯一词法支持。表达式上下文的泛型实参（`f<T>(x)`）闭合必须是独立的 `>`
  token（tsc `reScanGreaterToken` 语义），`x>>>0<y>>>0` 因此仍是比较。

`simple_token.zig`：`scanFollowing` 新增 `.colon` 与 `.left_brace`；`parenArrowAfterOpen`
遇到 `(...) :` 返回 `null`，把带返回类型的箭头头判定交给完整扫描；`(...) {` 让
`tsFunctionHasBodyAhead` 不必回退到完整 lexer。

## 4. 类型解析器（`src/parser.zig`，纯函数族）

全部签名为 `fn (s: *State) Error!void`，只用 `advance`/`peekKind`/`isIdent` 与
lexer 光标快照，任何一处失败都以普通 SyntaxError 报出。

| 函数 | 产生式 |
| --- | --- |
| `tsParseType` | 条件类型 `A extends B ? C : D`、函数类型 `(…) => R`、构造器类型 `[abstract] new (…) => R`、泛型函数类型 `<T>(…) => R` |
| `tsParseUnionType` / `tsParseIntersectionType` | 可带前导 `\|`/`&` 的联合、交叉 |
| `tsParseTypeOperator` | `keyof`/`unique`/`readonly`/`infer X [extends C]` 前缀 |
| `tsParsePostfixType` | 同行 `[]` 数组与 `[T]` 索引访问 |
| `tsParsePrimaryType` | 括号、对象类型字面量与映射类型、元组（含命名/可选/rest 成员）、`typeof` 实体名、`import("m").A`、`this`、字面量（字符串/数字/负数/bigint/模板字面量类型/true/false）、类型引用 `A.B<Args>` |
| `tsParseTypeArguments` / `tsParseTypeArgumentsInExpression` | `<T, U>`，类型上下文闭合处可拆 `>>`；表达式上下文要求独立 `>` |
| `tsParseTypeParameters` | `<const in out T extends C = D>` |
| `tsParseTypeAnnotationOpt` | 当前为 `:` 时消费 `: Type` |
| `tsParseReturnTypeOpt` / `tsParseTypeOrPredicate` | 返回类型位置：类型或谓词 `x is T` / `asserts x [is T]` / `this is T` |
| `tsParseSignatureParameters` | 无发射的参数签名：修饰符、`this`、模式（用平衡扫描跳过）、`?`、注解、rest |
| `tsParseObjectType` / `tsParseObjectTypeMember` / `tsParseIndexOrMappedMember` | 属性/方法/调用/构造/索引签名、访问器签名、映射类型成员 |
| `tsSkipBalancedGroup` / `tsSkipTemplate` | 消费一个平衡的 `{}`/`()`/`[]`（模板整体视为一个项） |

## 5. parser 插入点

| 位置 | 新增行为 |
| --- | --- |
| `parseVar` 标识符绑定 / 模式绑定后 | `!`（definite）与 `: Type`，在 `=` 之前 |
| `parseFunctionParameters` / 箭头参数循环 | 构造器参数修饰符（`public/private/protected/readonly/override`）；首参 `this: T` 整体丢弃；`?`；`: Type`；rest 注解；模式参数注解 |
| `parseFunctionParamsAndBody` | `(` 之前的 `<T>` 类型参数；`)` 之后的返回类型 |
| `parseFunctionDecl` / `parseClassElement` | 无函数体的重载签名与 `abstract`/可选方法：先纯前瞻 `tsFunctionHasBodyAhead`，无体则整段消费、不声明 |
| `parseArrowFunction` 与 `checkArrowHead` | `<T>(…) =>`、`(…): R =>`、`async <T>(…) =>` |
| `parseClassElement` | 修饰符循环（`public/private/protected/readonly/abstract/override/declare/static`，按 tsc `canFollowModifier` 判定；`accessor` 不支持）；索引签名 `[k: string]: T` 跳过；字段 `?`/`!`/`: Type`；`declare` 字段不发射；方法类型参数 |
| `parseClass` | `class A<T>`、`extends B<T>`、`implements …` |
| `parseObjectProperty` | 方法 `m<T>(…): R {}` |
| `parseExprBinary` level 4 | 同行 `as T` / `as const` / `satisfies T` |
| `parseMemberChain` | 同行后缀 `!`；`<T>` 泛型实参试探（含实例化表达式 `f<T>`）；`?.<T>(…)` |
| `parseNewExpr` | `new C<T>(…)` |
| `parseUnary` | `<T>expr` 断言 / 泛型箭头 |
| `parseTryStatement` | `catch (e: T)` |
| `parseStatementOrDeclSlow` | `interface`、`type`、`declare …`、`abstract class`、`namespace`/`module`、`enum` |
| `parseImport` / `parseExport` | `import type`、`import { type X }`、`export type`、`export { type X }`、`export type *`、`export interface/type/declare/abstract/enum/namespace`、`import x = A.B`、`export import`、`export as namespace X;` |

泛型实参试探与箭头头判定都用 `takeParserSnapshot`/`restoreParserLexerSnapshot`
回退（`TsSpeculation`），回退时同时恢复 `pending_diagnostic`。函数级细节见
`docs/code-walkthrough/03-parser-ts.md`。

## 6. enum 与 namespace 降级规则

绑定按 tsc 的形状：函数级 `var E;` / `var N;`，namespace 体内 `let E;`（先初始化为
undefined），同名再次声明复用既有绑定（声明合并）。namespace 体是真正的块作用域
（tsc 的 IIFE）：块级函数声明在进入作用域时实例化，兄弟 namespace 可导出同名成员，
体内 `var` 按 `let` 降级；`export` 成员在声明后 `N.x = x` 挂到对象上，函数声明也在
`parseFunctionDecl` 末尾挂接。namespace 上下文（`in_namespace`/`namespace_export`/
`current_namespace_atom`）在进入任何函数体时清零。

`E = E || {}` 后逐成员：

- 初始化器先做常量折叠：数字/字符串字面量、无替换模板、括号、一元 `+ - ~`、
  二元 `+ - * / % ** << >> >>> & | ^`、对本 enum 已折叠成员的引用（裸名或 `E.A`）。
- 折叠成功：数值成员发 `E[E["A"] = v] = "A"`，字符串成员发 `E["A"] = s`。
- 折叠失败：按普通表达式发射到运行时，仍发反向映射；其后无初始化器的成员报错
  （与 tsc 一致）。
- 成员名允许标识符与字符串字面量。

## 7. 删除清单与 API 变化

- `parser.Options.source_kind`、`parser.SourceKind`、`core.context.EvalSourceKind`、
  `ContextEvalOptions.source_kind`、`compiler/test_entry.Options.source_kind`、
  测试 helpers 的同名字段。调用方去掉该字段即可，行为不变。
- 文档：`docs/code-walkthrough/02-lexer-typescript.md` 删除，`03-parser-ts.md` 重写。

## 8. 门禁

1. `zig build test`（含新增 TS 语料单测）。
2. `zig build test262-check -Doptimize=ReleaseFast`：0 失败。
3. `zjs --bytecode-fingerprint` 在 test262
   全部用例 + jetstream3 + fixtures 上与改动前逐行一致（含 SyntaxError 的行列与消息）。
   落地时唯一的差异是诊断文本/位置：装饰器改报专用消息；类体内的词法错误改在出错
   token 处报告。
4. `zig build smoke`。
