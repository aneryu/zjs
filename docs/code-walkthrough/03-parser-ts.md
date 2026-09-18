# 03 — TypeScript 擦除（parser 侧）

类型注记主要在 `lexer.enableTypeScript()` 丢掉。parser 额外认识：

- `enum` / `const enum` → 运行时对象（双向映射，字符串成员单向）。
- `namespace` → `N = N || {}` 再往上挂成员。
- 构造器参数属性 `public/private/protected/readonly x`：`isParameterModifier` 识别，`parseBlockContentsAfterOpen` 在构造器体前插入 `this.x = x`。
- 不支持的 TS 语法在 `compile` 入口被 `findUnsupportedTypeScriptSyntax` 挡掉。


### `isParameterModifier` (`src/parser.zig:2765`)

- **签名**：`fn isParameterModifier(s: *State) bool`。
- **作用**：当前 token 是否为 TypeScript 参数属性修饰符。
- **实现**：
`TOK_PUBLIC/PRIVATE/PROTECTED` 为真。ident 且无转义时名字是 `public`/`private`/`protected`/`readonly` 也为真。给构造器参数属性用。
- **所有权 / 错误 / 调用**：无：只读当前 token——关键字臂比 kind，ident 臂拿 `s.lex.atoms.name(...)` 得到 AtomTable 内部的**借用**字节切片当场比较（不复制、不释放，atom id 也只是读）。不分配、无 error set、不推进 lexer。唯一调用方 `parseFunctionParameters`（`src/parser.zig:11319`）的 TypeScript 构造器分支，循环调用直到不再是修饰符。

### `parseEnumDeclaration` (`src/parser.zig:8283`)

- **签名**：`fn parseEnumDeclaration(s: *State) Error!void`。
- **作用**：把 TypeScript enum 擦成运行时对象（数字双向映射，字符串单向）。
- **实现**：
消费 `enum` 与名字；没有同名 var 则 `addScopeVar`。发射 `Enum = Enum || {}`（`scope_get_var_undef` + dup + `if_true` 跳过 `object`）。每个成员：
- 无初始化：`push_i32` 自增 counter，再双向映射 `Enum[Enum.Member = n] = "Member"`。
- `= 字符串`：只 `put_field` 正向。
- `= 数字` / `= -数字`：解析字面量（后面必须是 `,`/`}`），更新 counter，再双向映射。
`namespace_export` 时把 enum 对象挂到当前命名空间。
- **所有权 / 错误 / 调用**：不分配堆内存。名字 atom 有明确的取用顺序：`enum_atom` 与每个 `member_atom` 都在 `advance()` **之前**取走（源码注释对照 qjs `next_token`/`free_token` 的所有权顺序），`member_name` 则是 `atoms.name` 的借用切片，只在本轮循环里用。`addScopeVar` 新增的 VarDef 与发出的字节码都是不可回滚的持久副作用。栈契约是本函数最容易读错的地方：双向映射那段按注释里标注的六步维持 `[outer_obj, value, ...]` 形状，最终由 `put_array_el` 消费干净；字符串成员只做正向 `put_field`，因此**不**参与 counter 自增。收尾写 `setLastDeclaredAtom`，供外层 namespace 把它挂到命名空间对象上。错误：名字不是标识符、初始化器后面不是 `,`/`}`（用带位置的 `failExpectedDescriptionAt`）、初始化器既不是字符串也不是（负）数字字面量，都是 fail 族。两个调用方：`parseEnumStatement`（`src/parser.zig:9051`）与 `parseVariableStatement` 的 `const enum` 改道（`:9098`）。

### `parseNamespaceDeclaration` (`src/parser.zig:8399`)

- **签名**：`fn parseNamespaceDeclaration(s: *State) Error!void`。
- **作用**：消费已匹配的 `namespace` ident，转入带名字的命名空间解析。
- **实现**：
调用方已把当前 ident 认成 `namespace`。`expectToken(TOK_IDENT)` 消费它，再 `parseNamespaceDeclarationWithIdent`。
- **所有权 / 错误 / 调用**：两行转发，不分配、不持有资源。`expectToken(TOK_IDENT)` 吃掉的正是调用方已经用 `isIdent("namespace")` 认过的那枚 contextual 关键字——它本身不是保留字，所以这里只按 `TOK_IDENT` 消费，不校验拼写。唯一调用方 `parseIdentifierStatement` 的 TypeScript 臂（`src/parser.zig:9134`）。

### `parseNamespaceDeclarationWithIdent` (`src/parser.zig:8404`)

- **签名**：`fn parseNamespaceDeclarationWithIdent(s: *State) Error!void`。
- **作用**：擦除 TypeScript `namespace N { ... }`：把 `N` 当 var 绑定，发 `N = N || {}`，再在命名空间上下文里解析体。
- **实现**：
TypeScript `namespace N { ... }` 擦除：把名字当 var 绑定，发射 `N = N || {}`，再在命名空间 atom 下解析体（`in_namespace` / `current_namespace_atom`）。嵌套 `namespace` 递归。导出时把绑定 `put_field` 到外层命名空间对象。不是类型检查器，只发运行时对象。
- **所有权 / 错误 / 调用**：`ns_atom` 在 `advance()` 之前取走并由 `addScopeVar` 让 `FunctionDef` 成为所有者（已有同名声明则复用）。两条分支（`.` 点号嵌套与 `{` 块体）各自用同一套三件 `defer` 恢复：`in_namespace`、`current_namespace_atom`（经 `setCurrentNamespaceAtom`）、以及 `pushScopeIdentity` / `popScopeIdentity` 的作用域身份——注意这里用的是 identity 版本，不发 `enter_scope`/`leave_scope`，命名空间在运行时只是一个普通对象。`last_declared_atom` 是跨调用的一次性槽：嵌套分支解析完子命名空间后读它拿到子名字并 `put_field`，然后把自己写回去。`namespace_export` 时再往父命名空间挂一次。错误：名字不是标识符、缺 `{`/`}`，都是 fail 族。三个调用点：`parseNamespaceDeclaration`（`src/parser.zig:8821`）、自身的点号嵌套（`:8864`）、以及体内语句循环经 `parseNamespaceStatement` 间接递归。

### `parseNamespaceStatement` (`src/parser.zig:8494`)

- **签名**：`fn parseNamespaceStatement(s: *State) Error!void`。
- **作用**：可选 `export` 后解析一条命名空间体语句。
- **实现**：
可选消费 `export` 并临时打开 `namespace_export`，然后 `parseStatementOrDecl` 解析体（嵌套 namespace / enum / 声明）。
- **所有权 / 错误 / 调用**：不分配；唯一的状态是 `namespace_export`，用「保存 → 置成本条语句是否带 `export` → `defer` 还原」的形式管理，所以嵌套语句不会继承上一条的导出性。体语句用的是完整 `DeclMask`（`func` / `func_with_label` / `other` 全开），命名空间体内允许任何声明。无自有错误分支。唯一调用方 `parseNamespaceDeclarationWithIdent` 的体循环（`src/parser.zig:8899`）。

### `parseEnumStatement` (`src/parser.zig:8627`)

- **签名**：`fn parseEnumStatement(s: *State) Error!void`。
- **作用**：仅在 TypeScript 模式下解析 enum 声明语句。
- **实现**：
非 TypeScript 模式 `failUnexpectedToken`。否则 `parseEnumDeclaration`。
- **所有权 / 错误 / 调用**：纯守门转发，不分配、不持有资源。唯一自有错误是非 TypeScript 源里出现 `enum` 时的 `failUnexpectedToken`——`enum` 在 JS 里是保留字，词法器始终把它切成 `TOK_ENUM`，所以这条闸是必需的。唯一调用方是 `parseStatementOrDeclSlow` 的 `TOK_ENUM` 臂（`src/parser.zig:9004`）。

## 覆盖核对

- 清单函数数（本文件分到）: 6（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 6
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
