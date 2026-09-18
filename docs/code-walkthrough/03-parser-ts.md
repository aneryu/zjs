# 03 — TypeScript（parser 侧）

文法是 TypeScript 的，JavaScript 按其子集解析；没有 source-kind 开关，词法层也不区分。
设计与裁决见 [docs/parser-ts-first-class-design.md](../parser-ts-first-class-design.md)。

`src/parser.zig` 里以 `ts` 为前缀的函数分两类：

- **纯解析函数**（`tsParse*` / `tsSkip*` / `tsAt*` / `tsPeek*`）：只推进 lexer，不发射字节码、不登记作用域、不改 `features`。
  这保证 JS 输入的字节码逐位不变（门禁：`zjs --bytecode-fingerprint`，`tools/gates/bytecode_fingerprint.sh`），
  也让每一次投机解析都能用 parser 快照回退。
- **降级函数**（`parseEnumDeclaration` / `parseNamespaceDeclaration*` / `tsParseImportAlias` / 参数属性）：
  有运行时语义，按 tsc 输出的形状发射普通字节码。

## 投机与回退

- `TsSpeculation` = `takeParserSnapshot` + `pending_diagnostic` 副本。`tsBeginSpeculation` / `tsRollback` / `tsCommit`。
  `tsCommit` 只释放快照里复制的 token。
- `tsProbe(s, parse_fn)`：把纯解析当探针跑，语法错误变 `false`，`OutOfMemory` / `StackOverflow` / `BytecodeOverflow` 照常上抛。
- `tsSkipBalancedGroup` / `tsSkipBalancedRest`：按 `(`/`[`/`{` 深度消费一个平衡组；模板整体（含 `${}`）由 `tsSkipTemplate` 消费。
  只用于类型位置里的模式跳过、`declare` 体、计算属性名，不用于判断 JS 语义。

## 类型文法（全部纯）

| 函数 | 产生式 |
| --- | --- |
| `tsParseTypeAnnotationOpt` | `: Type`（上下文重置为允许条件类型） |
| `tsParseReturnTypeOpt` / `tsParseTypeOrPredicate` | 返回类型位：类型或谓词 `x is T` / `asserts x [is T]` / `this is T` |
| `tsParseType` | 函数/构造器类型，否则联合类型，再可选 `extends B ? C : D`（`ts_disallow_conditional` 为真时不进条件类型） |
| `tsAtFunctionTypeStart` | `<`、`new`、`abstract new`，或 `(` 经 `scanBalancedToken` 后紧跟 `=>` |
| `tsParseUnionType` / `tsParseIntersectionType` | 允许前导 `\|` / `&` |
| `tsParseTypeOperator` | `keyof` / `unique` / `readonly` 前缀；`infer U [extends C]`，约束用投机解析，若会抢走外层条件类型的 `?` 则回退 |
| `tsParsePostfixType` | 同行的 `[]` 与 `[T]` |
| `tsParsePrimaryType` | 括号、元组、对象类型、字面量（字符串/数字/负数/`true`/`false`/`null`/`void`/`this`/模板）、`typeof`、`import("m")`、类型引用 |
| `tsParseTypeReference` / `tsParseEntityName` | `A.B.C<Args>`；点号后允许关键字 |
| `tsParseTypeArguments` | 类型上下文的 `<T, U>`，闭合处 `tsExpectGreater` 可拆 `>>` / `>=` |
| `tsParseTypeArgumentsInExpression` | 表达式上下文：闭合必须是独立的 `>` token（tsc `reScanGreaterToken` 语义），`x>>>0<y>>>0` 因此仍是比较 |
| `tsParseTypeParameters` | `<const in out T extends C = D>` |
| `tsParseTupleType` | 可选/命名/rest 成员 |
| `tsParseObjectType` / `tsParseObjectTypeMember` / `tsParseIndexOrMappedMember` | 对象类型字面量、interface 体、映射类型、索引签名、调用/构造/方法签名、访问器签名 |
| `tsParseSignatureParameters` | 无函数体签名的参数表：修饰符、`this`、模式（平衡跳过）、`?`、注解、rest；不允许初始化器 |
| `tsParseTemplateLiteralType` | 用 `nextTemplatePartAfterBraceInto` 续扫 |
| `tsExpectGreater` / `tsExpectLess` | 调 lexer 的 `splitGreaterThan` / `splitLessThan` |

## 声明

| 函数 | 内容 |
| --- | --- |
| `tsDeclarationStart` | 上下文关键字只在这些形状且下一 token 同行时开启声明：`interface X`、`type X`、`declare <decl>`、`abstract class`、`namespace X`、`module X`。先按名字过滤再前瞻，普通标识符语句不付前瞻代价 |
| `tsParseInterfaceDeclaration` / `tsParseTypeAliasDeclaration` | 整段丢弃 |
| `tsParseAmbientDeclaration*` | `declare var/let/const/function/class/enum/namespace/module/global/interface/type`，全部无产出 |
| `tsFunctionHasBodyAhead` | 用 `scanBalancedToken` 看参数表之后是 `{` 还是 `:`；`:` 时投机解析返回类型再看 `{`。在创建子 `FunctionDef` 之前决定 |
| `tsSkipFunctionSignature` | 重载签名：消费后要求紧跟 `function` / `async` / `export` / `default`，否则报"implementation is missing" |
| `tsSkipMethodSignature` | 类里的重载 / `abstract` / 可选方法；非 abstract、非可选且下一 token 是 `}` 时报错 |
| `tsSkipDeclaredField` | `declare x: T` 不定义字段 |
| `tsCanFollowClassModifier` / 修饰符循环（`parseClassElement`） | tsc `nextTokenCanFollowModifier`：`static` 容忍换行，其余要求同行；`accessor` 不支持 |
| `tsIndexSignatureAhead` / `tsSkipIndexSignature` | 类体 `[k: string]: T` |
| `tsPatternHasInitializerAfterAnnotation` | `{...}?: T = v` 的初始化器藏在注解之后，`parseDestructuringElement` 据此提前发跳转 |

## 表达式

| 函数 | 内容 |
| --- | --- |
| `tsGenericArrowHead` | `<T>(...) [: R] =>`；`parseArrowAssignment` 命中后消费类型参数再走 `parseArrowFunction` |
| `tsParenArrowHeadWithReturnType` | `(...): R =>`；`checkArrowHead` 在 `scanBalancedToken` 看到 `:` 时调用，`ParseFlags.arrow_return_type_forbidden`（三元 whenTrue 分支）为真时不调用 |
| `tsParseTypeAssertion` | `parseUnary` 顶部的 `<T>expr` / `<const>expr` |
| `tsTryParseTypeArgumentsInExpression` / `tsCanFollowTypeArgumentsInExpression` | `parseMemberChain` / `parseNewExpr` / `?.` 处的 `<T>` 试探；后跟 `(`、模板、二元运算符、换行或不能起始表达式的 token 才算类型实参；`<` `>` `+` `-` `=` 及各赋值运算符一律不算 |
| `tsAtAsOrSatisfies` | `parseExprBinary` level 4 循环里的同行 `as T` / `as const` / `satisfies T` |
| `parseMemberChain` 的 `!` 臂 | 同行后缀 `!` 擦除 |

## 模块

| 函数 | 内容 |
| --- | --- |
| `tsImportTypeModifier` | `import type ...` 是否为 type-only（tsc 规则，含 `import type from "m"` 的默认导入名例外） |
| `tsSpecifierTypeModifier` | `{ type X }` / `{ type as as X }` / `{ type as X }` 三形状 |
| `tsSkipTypeOnlyImport` / `tsSkipTypeOnlyExport` / `tsSkipFromClause` | 不登记模块请求地消费 |
| `parseImport` / `parseExport` | 全部 specifier 为 type-only 时整条语句省略（与 tsc 默认一致）；`export type/interface/declare/abstract class/enum/namespace/import x = A.B`；`export =` 与 `import x = require()` 报错 |
| `tsImportAliasAhead` / `tsParseImportAlias` | `import x = A.B.C;` 降级为 `const x = A.B.C;`，可 `export`，可在 namespace 内 |

## enum

`parseEnumDeclaration`：`E = E || {}` 后逐成员。成员名允许标识符、关键字、字符串。
初始化器先经 `tsTryFoldEnumInitializer` 常量折叠（字面量、无替换模板、括号、一元 `+ - ~`、二元
`+ - * / % ** << >> >>> & | ^`、对本 enum 已折叠成员的引用，含 `E.A`），折叠结果数值走
`E[E["A"] = v] = "A"`、字符串走 `E["A"] = s`；折叠失败则按普通表达式在运行时求值并仍发反向映射；
其后无初始化器的成员报错（tsc TS1061）。`TsEnumValue` 里的字符串由 `s.function.memory.allocator` 持有，函数结束统一释放。

## 参数属性与 namespace

- `isParameterModifier`（`public/private/protected/readonly/override`，且后面必须跟绑定）只在构造器参数表生效；`parseFunctionParameters` 收进 `current_parameter_properties`，`parseBlockContentsAfterOpen`（基类）或 `super()` 之后（派生类）插入 `this.x = x`。
- `parseNamespaceDeclaration` / `parseNamespaceDeclarationWithIdent` / `parseNamespaceStatement`：`namespace` 与 `module` 关键字同形；`N = N || {}`，点号嵌套递归，`export` 成员挂到命名空间对象上。

## 明确拒绝

装饰器（`@`，`decoratorDiagnosticMessage` 给出定制消息）、`accessor` 字段、`import x = require()`、`export =`、`.tsx` / `.jsx` 文件（compile 入口直接 `syntax_error_guard`）。
