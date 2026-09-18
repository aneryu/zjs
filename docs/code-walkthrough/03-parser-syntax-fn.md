# 03 — parser 函数 / 箭头 / 解构 / 类

`parseFunctionParamsAndBody` 是所有函数形态的汇合点。解构 pattern 与 class 元素也在本册。


### `FunctionEntryContext.save` (`src/parser.zig:6927`)

- **签名**：`inline fn save(s: *State, comptime fields: FunctionEntryFields) FunctionEntryContext`。
- **作用**：保存一组 FunctionEntry 字段，供嵌套函数解析后 restore。
- **实现**：
按 `FunctionEntryFields` 位拷贝 `pending_function_name` / `is_decl` / `export_default` 等到栈上结构，嵌套解析后 `restore`。
- **所有权 / 错误 / 调用**：不分配：把 `State` 上九个进入函数体前要保存的标量（`pending_function_*`、`in_generator`/`in_async`/`is_strict`/`allow_super`/`parsing_method_params` 等）按 comptime 的 `fields` 掩码抄进一个按值返回的结构体——没被掩码选中的字段留在 `undefined`，所以这个值**只能配同一个 `fields` 的 `restore` 用**。`pending_function_name` 存的是 atom id，不 retain（编译期 atom 由 `CompileAtomScope` 作根）。无 error set。六个调用方，每个都紧跟一条 `defer saved_entry.restore(...)`：`emitObjectMethodFunction`（`src/parser.zig:7177`）、`parseFunctionDecl`（`:11141`）、`parseFunctionExpr`（`:11201`）、`parseAnonymousDefaultFunctionDecl`（`:11239`）、`parseArrowFunction`（`:12187`）、`parseClassElementFunction`（`:14460`）。

### `FunctionEntryContext.restore` (`src/parser.zig:6941`)

- **签名**：`inline fn restore(saved: FunctionEntryContext, s: *State, comptime fields: FunctionEntryFields) void`。
- **作用**：把 `save` 记下的 FunctionEntry 字段写回 ParseState。
- **实现**：
把 `save` 的字段写回 ParseState，保证内层函数不会泄漏 pending 名字到外层。
- **所有权 / 错误 / 调用**：不分配、无 error set：按同一个 comptime 掩码把九个标量写回 `State`，被覆盖的旧值不需要释放（都是标量或借用的 atom id）。它总是以 `defer` 形式出现，所以错误路径也会恢复。顺序上有一处已被源码注释固定（`src/parser.zig:11143`）：这条 `defer` 必须在更早注册的 name_atom 持有者 `defer` **之前**恢复字段。六个调用点与 `save` 一一对应（`:7178`/`:11142`/`:11202`/`:11240`/`:12188`/`:14461`）。

### `parseFunctionDecl` (`src/parser.zig:10612`)

- **签名**：`fn parseFunctionDecl(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：解析**函数声明**（含 `async`、生成器与类构造器形态）：名字是必需的，解析完把参数与函数体交给 `parseFunctionParamsAndBody`。
- **实现**：进门先按 `func_kind` 准备 TS 参数属性容器：类构造器（`.class_constructor` / `.derived_class_constructor`）开一个空 `ArrayList(Atom)`，其余置 `null`，`defer` 负责销毁并恢复外层的 `current_parameter_properties`。吃掉 `function` 后看 `*` 定 `is_generator`。名字必须有：`TOK_IDENT`，或 `canUseAwaitAsIdentifier` 下的 `await`，或非严格模式下的 `yield`；都不是就 `failUnexpectedToken`。名字 atom 在 `advance` 之前取走（qjs 也在 `next_token` 释放 token 前 retain，`quickjs.c:36551-36556`），`setLastDeclaredAtom` 记账；模块顶层若该名字已有绑定，直接报重复声明。随后把 `in_generator` / `in_async` 置成本函数的形态并 `defer` 还原，由 `is_generator` 与 `func_kind` 合成 `actual_kind`（`async` + `*` → `.async_generator`）。最后经 `FunctionEntryContext.save` 保存 / 恢复 `pending_function_name`、`pending_function_is_decl` 两个字段，置上名字与「是声明」标志，进入 `parseFunctionParamsAndBody`（qjs `js_parse_function_decl`，`quickjs.c:36388`）。
- **所有权 / 错误 / 调用**：失败走 `parser_core.Error`（含 `SyntaxError` / `OutOfMemory` / `ParserInvariant` / `StackOverflow` 等）；`compile` 再把它收成 `Result.syntax_error` 或 ICE。 典型被调用方：`parseFunctionParamsAndBody`。

### `parseFunctionExpr` (`src/parser.zig:10683`)

- **签名**：`fn parseFunctionExpr(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void`。
- **作用**：解析**函数表达式**：名字可选，并在此处执行具名函数表达式对名字的额外限制。
- **实现**：骨架与 `parseFunctionDecl` 相同（吃 `function`、看 `*`、置 `in_generator` / `in_async` 并 defer 还原、合成 `actual_kind`、经 `FunctionEntryContext` 传 `pending_function_name` 给 `parseFunctionParamsAndBody`），差别全在名字上：名字**可选**，`has_name` 认 `TOK_IDENT`、非 async 且非模块下的 `await`、非严格模式下的 `yield`；取到名字后有三道检查——生成器里叫 `yield`、async 生成器里叫 `await`、严格模式（含所在函数已是严格）下叫 `eval` / `arguments`，都 `failUnexpectedToken`。最终 `pending_function_is_decl = false`，所以下游按具名函数表达式处理（名字只在函数自身作用域里可见）。
- **所有权 / 错误 / 调用**：失败走 `parser_core.Error`（含 `SyntaxError` / `OutOfMemory` / `ParserInvariant` / `StackOverflow` 等）；`compile` 再把它收成 `Result.syntax_error` 或 ICE。 典型被调用方：`parseFunctionParamsAndBody`。

### `parseAnonymousDefaultFunctionDecl` (`src/parser.zig:10746`)

- **签名**：`fn parseAnonymousDefaultFunctionDecl( s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart, ) Error!void`。
- **作用**：解析匿名的 `export default function`：它仍是声明，外部载体名 `*default*`（`atom_star_default`），推断出的函数名是 `default`。
- **实现**：吃掉 `function`，看 `*` 定 `is_generator`，按 `func_kind` 置 `in_generator` / `in_async` 并 `defer` 还原，再合成 `actual_kind`（`.async` + `*` → `.async_generator`）。与 `parseFunctionDecl` 的差别只在名字：不解析标识符，直接 `pending_function_name = atom_default`（推断名 `default`）、`pending_function_is_decl = true`、并多置一个 `pending_function_export_default = true`（`FunctionEntryContext` 的 `fields` 也因此多带这一位）。下游 `parseFunctionParamsAndBody`（`src/parser.zig:11684`）看到这个标志后，把声明绑定的名字换成模块载体 `atom_star_default`（`*default*`，`:15168`）而不是 `default`。两个调用方都在 `export default` 语句里：`:15480`（`.normal`）与 `:15491`（`.async`），它们随后 `addModuleExportName(s, atom_default, atom_star_default)` 把导出名接上。
- **所有权 / 错误 / 调用**：失败走 `parser_core.Error`（含 `SyntaxError` / `OutOfMemory` / `ParserInvariant` / `StackOverflow` 等）；`compile` 再把它收成 `Result.syntax_error` 或 ICE。 典型被调用方：`parseFunctionParamsAndBody`。

### `appendOwnedParserAtom` (`src/parser.zig:10780`)

- **签名**：`fn appendOwnedParserAtom(s: *State, list: *std.ArrayList(Atom), atom_id: Atom) Error!void`。
- **作用**：把一个 atom 追加进解析期持有的 atom 列表。
- **实现**：
先 `ensureUnusedCapacity(s.function.memory.allocator, 1)` 再 `appendAssumeCapacity`，使「先保容量、后写入」这一步不会半途失败。atom 本身不额外 retain，生命周期由 `atom_scope` 覆盖。
- **所有权 / 错误 / 调用**：列表用的是 `s.function.memory.allocator`，所以唯一可能的失败是 `OutOfMemory`（声明的仍是宽的 `parser_core.Error`）。存进去的是**裸 atom id，不 retain**，编译期 atom 统一由 `CompileAtomScope` 作根；因此配套的 `deinitOwnedParserAtoms` 也只还缓冲。四个调用点：TS 参数属性收集（`src/parser.zig:11329`，写 `s.current_parameter_properties`）、简单形参名与 rest 名（`:11349` / `:11436`，写 `FunctionParameters.simple_names`）、箭头形参名（`:13175`，`appendArrowParamBindingName`）。

### `deinitOwnedParserAtoms` (`src/parser.zig:10785`)

- **签名**：`fn deinitOwnedParserAtoms(s: *State, list: *std.ArrayList(Atom)) void`。
- **作用**：释放解析期的 atom 列表。
- **实现**：
一行 `list.deinit(s.function.memory.allocator)`：只还列表存储，列表里的 atom id 不逐个 release（归 `atom_scope` 记账）。
- **所有权 / 错误 / 调用**：不分配、无 error set，只把 `appendOwnedParserAtom` 攒起来的缓冲还给 `s.function.memory.allocator`；里面的 atom id 是借用的，编译期由 `CompileAtomScope` 统一作根，所以不逐个 release。四个调用点都在 `defer` / 作用域收尾里：`parseFunctionDecl` 的参数属性 `defer`（`src/parser.zig:11090`）、`FunctionParameters.deinit`（`:11263`）、`parseArrowFunction` 的 `param_names` `defer`（`:12277`）、`parseClassElementFunction` 的参数属性 `defer`（`:14444`）。

### `FunctionParameters.deinit` (`src/parser.zig:10795`)

- **签名**：`fn deinit(self: *FunctionParameters, s: *State) void`。
- **作用**：归还形参收集器里那份简单形参名列表所持有的 atom。
- **实现**：
只有一件事：`deinitOwnedParserAtoms(s, &self.simple_names)`。其余三个字段（`invalid_strict_name_position` / `has_duplicate_simple` / `has_simple_list`）是纯值，无需释放。
- **所有权 / 错误 / 调用**：只释放 `simple_names` 这个 `std.ArrayList(Atom)` 的缓冲（经 `deinitOwnedParserAtoms` → `list.deinit(s.function.memory.allocator)`）；表里的 atom **只是 id，不 release**——函数名里的 Owned 是 TGC S3-c 之前的遗迹，编译期 atom 由 `CompileAtomScope` 统一作根。`invalid_strict_name_position` 等其余字段是平凡值。无 error set。两个调用方：`parseFunctionParameters` 自己的 `errdefer`（`src/parser.zig:11296`）与 `parseFunctionParamsAndBody` 的 `defer`（`:11936`）。

### `parseFunctionParameters` (`src/parser.zig:10823`)

- **签名**：`fn parseFunctionParameters( s: *State, func_kind: ParseFunctionKind, capture_child: bool, ) Error!FunctionParameters`。
- **作用**：解析形参列表（或方法 / setter 的单参数），含 rest、默认值、解构与 TypeScript 参数属性，并记录严格模式检查需要的重名与非法名信息。
- **实现**：
`func_kind == .class_static_block` 时整段括号解析被跳过（static block 没有形参表），否则先 `scanParameterList` 预扫再 `expectToken('(')`。进括号前就按 `func_kind` 是否 async 置 `reject_await_in_parameter_initializer` 并 `defer` 还原（**整个形参表**期间有效，不只默认值里）；`in_parameter_initializer` 才是只在 `=` 初始化器内置起。循环按首 token 分四类：标识符（简单名）、`{` / `[`（解构，走 `parseParameterDestructuring`）、`...`（rest，置 `.spread_rest` feature 后 `break`），其余 `failExpectedDescription("binding name or binding pattern")`。简单名分支做三道检查：setter 且严格模式下叫 `eval`/`arguments`、与已收集的简单名重名（严格报错，非严格只记 `has_duplicate_simple`）、与 `curFunc().vars` 里已有变量同名；随后 `appendArg` 并在 `=` 时发 `get_arg` / `ext0.is_undefined` / `if_false` / 初始化器 / `put_arg` 的「已传参就保留」序列。TypeScript 参数属性只在 `is_typescript` 且 `func_kind` 是（派生）类构造器时认（`isParameterModifier`：`public/private/protected/readonly`），其 atom 进 `current_parameter_properties`。严格非法名只记第一个位置（`recordInvalidStrictParameterName`），留给调用方兑现。`scanParameterList` 报出的 `has_parameter_expressions` 会写进 `curFunc()` 并开一个参数作用域（`enterParameterExpressionScope` / `leaveParameterExpressionScope`）。收尾两道元数检查：getter 必须零参且无 rest，setter 必须恰好一参且无 rest；再写回 `has_simple_parameter_list` 与 `defined_arg_count`（第一个带默认值的参数下标）。
- **所有权 / 错误 / 调用**：返回的 `FunctionParameters` **由调用方负责 `deinit`**（`parseFunctionParamsAndBody:11936` 的 `defer`），函数内部则用 `errdefer parameters.deinit(s)` 覆盖自己的失败路径；里面唯一的堆缓冲是 `simple_names`（`appendOwnedParserAtom` → `ensureUnusedCapacity(s.function.memory.allocator)`），装的都是裸 atom id。对当前 `FunctionDef` 的写入是**不可回滚的持久副作用**：`appendArg`、`ensureDestructuringArgSlot` 追加的匿名 arg 行、`defined_arg_count`、`has_parameter_expressions`，以及参数作用域绑定——失败时靠上层丢弃整个 `FunctionDef` 而不是局部撤销。三类状态用 `defer` 恢复：`reject_await_in_parameter_initializer`、`in_parameter_initializer`、以及参数作用域的进出。错误来源齐全：`failUnexpectedToken`（重复参数名、严格模式 `eval`/`arguments`、与已有 var 冲突）走 `Error.UnexpectedToken` 并留下 pending 诊断，rest 参数下标对不上走 `Error.ParserInvariant`（ICE 出口），其余是 `OutOfMemory` 与 Builder 经 `mapBuilderError` 折出的错误。唯一调用方 `parseFunctionParamsAndBody`（`:11935`）。

### `parseFunctionParamsAndBody` (`src/parser.zig:11052`)

- **签名**：`fn parseFunctionParamsAndBody(s: *State, func_kind: ParseFunctionKind, source_start: ?FunctionSourceStart) Error!void`。
- **作用**：所有函数形态（声明 / 表达式 / 方法 / 构造器 / static block）共用的下降：建子 `FunctionDef`、解析参数与函数体、收尾发 `fclosure`。
- **实现**：
所有函数形态（声明/表达式/方法/构造器/static block）的共用下降。约 620 行，分四段：

1. **保存/恢复父状态**（emit 目标、scope、eval、strict、super、new.target、constructor 标志）。箭头/static block 继承外层 super；派生构造器才 `allow_super_call`。
2. **子 FunctionDef**：`memory.create` + `FunctionDef.init`，填 `func_type`/`func_kind`/`has_prototype`/`has_this_binding`。声明计划 `FunctionDeclPlan` 处理：顶层 global var、Annex B.3.3 if/块级函数的 var 副本、词法冲突、`arguments` 参数阻断、switch CaseBlock、重复提升。然后 `pushFunction`，scope 回到 0。
3. **体**：构造器入口 `check_ctor`；基类构造器立刻 `emitClassFieldInitCall`。`parseFunctionParameters`；生成器 `initial_yield`。`enterControlBoundary` 切断外层 break/continue。`parseFunctionBodyBlock`（指令 prologue + 体）。严格模式再拒绝非简单参数的 `"use strict"`、非法函数名/参数名、方法/箭头/构造器的重复参数。
4. **收尾**：`isLiveCode` 决定隐式 return（async/generator → `undefined; return_async`；派生构造器 → `scope_get_var_checkthis this; return`；否则 `return_undef`）。pop 子函数，`appendCpool` + `addChild`。表达式发 `fclosure`（匿名再 `set_name null` 占位）；声明按 plan 在源位置或 enter_scope 初始化，Annex B 再 `put_loc` / `emitGlobalScopePutVar` / eval var object。namespace 导出则 `put_field`。失败 `discardCurrentFunction`。
- **所有权 / 错误 / 调用**：核心是子 `FunctionDef` 的所有权接力，由两个布尔守着三段 errdefer：`memory.create` 之后到 `pushFunction` 之前归本函数（`child_owned_before_push` → `discardFunctionDef`）；入栈后归 `cur_func_stack`（`child_pushed` → `discardCurrentFunction`，并回滚 emit 目标 / `scope_level` / `is_eval` / `return_depth` / strict 等九个已保存的标量）；`popFunction` 取回后到 `parent_fd.addChild` 之前又短暂归本函数（`child_moved`），交出后就只属于父 `FunctionDef`。其余父状态（`in_constructor`、`allow_super(_call)`、`new_target_allowed`、`in_class_static_block`、`function_expr_name_binding`、`in_parameter_initializer`、return-finally 边界）全用 `defer` 还原，`enterControlBoundary` 的帧则由 `control_boundary_active` 配 `errdefer` 兜底。`parameters` 的 `simple_names` 缓冲用 `defer parameters.deinit(s)`。错误：早期错误直接 `Error.SyntaxError`（同作用域重复词法声明）或经 `failWithMessage` / `failExpectedDescription` 折成 `error.UnexpectedToken` 并留 pending 诊断，计划与索引对不上则 `Error.ParserInvariant`（ICE 出口），其余是 `OutOfMemory`。六个调用方：`emitObjectMethodFunction`（`:7186`）、`parseFunctionDecl`（`:11146`）、`parseFunctionExpr`（`:11205`）、`parseAnonymousDefaultFunctionDecl`（`:11244`）、`parseClassElementFunction`（`:14470`）、类 static block（`:14572`，传 `.class_static_block` 且 `source_start = null`）。

### `parseArrowFunction` (`src/parser.zig:11676`)

- **签名**：`fn parseArrowFunction(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart, body_flags: ParseFlags) Error!void`。
- **作用**：覆盖文法确认之后真正解析箭头函数：建 `.arrow` 子 `FunctionDef`，解析参数与块体或表达式体，`this` / `arguments` / `super` 一律沿闭包链捕获。
- **实现**：
cover grammar 已确认是箭头后进入。创建 `func_type = .arrow` 的子 FunctionDef：`has_prototype = false`，`has_this_binding` / `has_arguments_binding` 保持 `FunctionDef` 的默认 `false`（`src/bytecode.zig:5183-5184`），`new_target_allowed` / `super_allowed` / `super_call_allowed` / `arguments_allowed` 全部照抄外层。形参**不走** `parseFunctionParameters`，而是本函数自带一套循环：要么单个裸标识符（直接 `appendArg`），要么 `scanParameterList` 预扫 + `expectToken('(')` 后按 ident / 解构 / rest 逐个处理，用 `appendArrowParamBindingName` 查重。参数表沿用外层的 Await 文法参数（`params_in_async = is_async or was_async or is_module or in_class_static_block`），过 `=>` 之后才切成箭头自己的 `in_async`；`=>` 前有换行直接 `failUnexpectedToken`。体两种：`{` 走 `parseFunctionBodyBlock`，收尾按 `isLiveCode` 补 `undefined; return_async`（async）或 `return_undef`；表达式体走 `beginFunctionBody` + `parseAssignExpr2`（刻意比 qjs 严：ConciseBody 继承 `body_flags.in_accepted` 的 no-`in` 限制）后直接发 `return_async` / `return`。`this`/`new.target`/`arguments`/`super` 在名字解析时由 `State.ensureArrowSpecialCapture`（`src/parser.zig:3292`）沿闭包链捕获。收尾 `appendCpool` + `addChild` + `emitFClosure`，并且因为箭头语法上恒为匿名，**总是**补一条 `set_name null` 占位（不像普通函数表达式那样只在匿名时补）。
- **所有权 / 错误 / 调用**：子 `FunctionDef` 的所有权接力与 `parseFunctionParamsAndBody` 同形：`child_owned_before_push`（create 后 → `discardFunctionDef`）→ `child_pushed`（入栈后 → `discardCurrentFunction` 并回滚十个已保存的标量）→ `child_moved`（`popFunction` 后 → `addChild` 交给父 `FunctionDef`）。`param_names` 这份 `ArrayList(Atom)` 由 `defer deinitOwnedParserAtoms` 释放，里面只是借用的 atom id。`in_constructor`、`current_parameter_properties`（箭头里置 `null`，所以 TS 参数属性不会漏进箭头）、`in_parameter_initializer`、`in_async` / `reject_await_in_parameter_initializer`、`in_class_static_block`、`new_target_allowed`、`FunctionEntryContext` 的两个 pending 字段都靠 `defer` 还原；控制边界由 `control_boundary_active` 配 `errdefer` 兜底，表达式体路径另有 `errdefer s.popScopeIdentity()`。错误全部经 `failUnexpectedToken` / `failWithMessage` / `rejectInvalidStrictParameterName` 折成 `error.UnexpectedToken`，外加 `OutOfMemory`。

### `PatternTarget.depth` (`src/parser.zig:12097`)

- **签名**：`fn depth(self: *const PatternTarget) u8`。
- **作用**：解构目标在求值栈上占据的深度。
- **实现**：
`.direct_binding` 深度 0；`.lvalue` 返回内部 `LValue.depth`（字段 1、元素/ref 2、super 3）。决定 rest/赋值时要插多少 dup/nip。
- **所有权 / 错误 / 调用**：只读：绑定目标栈深 0，lvalue 用其 `LValue.depth`。

### `PatternTarget.defaultName` (`src/parser.zig:12104`)

- **签名**：`fn defaultName(self: *const PatternTarget) ?Atom`。
- **作用**：可用来 `setObjectName` 的绑定名字。
- **实现**：
`.direct_binding` 返回绑定 atom。`.lvalue` 仅 `scope_var`/`ref_value` 返回 `name`，成员/私有/下标不能给匿名函数提供推断名。
- **所有权 / 错误 / 调用**：绑定模式返回名字；lvalue 仅 `scope_var`/`ref_value` 有可命名 atom。

### `PatternTarget.deinit` (`src/parser.zig:12114`)

- **签名**：`fn deinit(self: *PatternTarget, s: *State) void`。
- **作用**：按 tag 释放一个解构目标可能挂着的 lvalue 资源。
- **实现**：按 tag 分派：`.direct_binding` 什么都不做（只是一个 atom），`.lvalue` 转调 `LValue.deinit(s)`。
- **所有权 / 错误 / 调用**：按 union 臂分派：`.direct_binding` 是纯值、什么都不做；`.lvalue` 转给 `LValue.deinit`（`src/parser.zig:4217`），而后者如今也只是清 `owns_name` 标志——TGC S3-c 之后 LValue 里的名字 atom 是普通借用 id，没有 release 义务。所以本函数当前是**全无释放动作的空壳**，保留只为形式上的配对。无 error set。五个调用方全是 `errdefer`/`defer`：`parsePatternBindingTarget`（`src/parser.zig:12697`，`errdefer`）、`parseArrayPatternBody`（`:12985`）、`parseObjectPatternBody`（`:13023` / `:13067` / `:13094`）。

### `scanPatternTopology` (`src/parser.zig:12131`)

- **签名**：`fn scanPatternTopology(s: *State) Error!PatternTopology`。
- **作用**：只看 token 的拓扑预扫：判断外层 pattern 后面是否跟 `=` / rest，以及嵌套的 `[` / `{` 是 pattern 还是成员目标的基。
- **实现**：当前 token 必须是 `[` 或 `{`，否则 `failExpectedDescription("binding pattern")`。随后交 `scanBalancedToken` 做一次纯 token 的配平扫描——它先试着直接在源码字节上做 ASCII 快扫，不适用（TypeScript、模板、转义、非 ASCII）才退回词法器并在返回前还原游标快照，因此整个过程不解析表达式、不发码、不定义变量、不碰 FunctionDef。没配平时用 `balanced.failure` 报「期待 `]` / `}`」并带上出错 token 的位置，连 failure 都没有就退回 `failExpectedToken`。成功则返回两项拓扑事实：闭合之后紧跟的 token 种类，以及顶层是否出现过 `...`。
- **所有权 / 错误 / 调用**：**前瞻扫描**：靠 `scanBalancedToken`（它内部负责保存/恢复 lexer 光标并释放每个临时 token 的 payload）走完整个 `[...]`/`{...}`，本函数自己不分配、不改 `State`，返回的 `PatternTopology` 是纯值。错误：开头不是 `[`/`{` → `failExpectedDescription`，未闭合 → `failExpectedToken`/`failExpectedDescriptionAt`（都记 pending 诊断后返回 `Error.UnexpectedToken` 族，最终成为用户可见的 SyntaxError），扫描途中的 lexer 错误与 `OutOfMemory` 原样上抛。5 个调用方：`parseDestructuringAssignment`（`src/parser.zig:4127`）、`parseForInOf`（`:10882`）、`tokenStartsNestedPattern`（`:12628`）、`parseArrayPatternBody`（`:12973`）、`parseDestructuringElement`（`:13129`）。

### `tokenStartsNestedPattern` (`src/parser.zig:12155`)

- **签名**：`fn tokenStartsNestedPattern(s: *State, enclosing_close: tok.TokenKind) Error!bool`。
- **作用**：判断当前的 `[` / `{` 是一个嵌套 pattern，还是成员目标的基（如 `[a][0] = x`）。
- **实现**：当前 token 不是 `[` / `{` 直接 false。否则 `scanPatternTopology` 看这对括号闭合之后紧跟什么：`,`、`=` 或外层的收尾符 `enclosing_close`，说明它自成一个元素，是嵌套 pattern；其它情况（典型是 `[` 或 `.`，即 `[a][0] = x` 这种）说明这对括号只是成员目标的基，返回 false 让调用方走 lvalue 路径。
- **所有权 / 错误 / 调用**：不分配、不改状态（前瞻全在 `scanPatternTopology` 里做完并复位）；错误也完全来自它——当前 token 不是 `[`/`{` 时直接返回 `false`，进去之后未闭合才会报 `SyntaxError` 族。两个调用方：`parseArrayPatternBody`（`src/parser.zig:12971`）与 `parseObjectPatternBody`（`:13049`）。

### `checkPatternParameterDuplicate` (`src/parser.zig:12167`)

- **签名**：`fn checkPatternParameterDuplicate(s: *State, name: Atom) Error!void`。
- **作用**：解构形参里出现重名绑定时报 SyntaxError。
- **实现**：线性扫当前 `FunctionDef` 的 `args` 与 `vars` 两张表，任一条 `var_name` 撞名就 `failExpectedDescription("unique parameter binding")`。解构形参无论严格与否都不许重名（不同于非严格模式下可重复的简单形参表），所以这里不看 `is_strict`；两张表在参数解析阶段都很短，线性扫足够。
- **所有权 / 错误 / 调用**：只读 `curFunc()` 的 `args`/`vars` 两张表做线性查找，不分配、无副作用。唯一的错误是 `failExpectedDescription("unique parameter binding")`——记下 pending 诊断后返回 `Error.UnexpectedToken`，由 `compile` 收成 `Result.syntax_error`，再在 `exec/eval_entry.zig:127` 抛成 JS SyntaxError。唯一调用方 `definePatternBindingAtom`（`src/parser.zig:12654`），且只在 `binding.is_parameter` 时。

### `definePatternBindingAtom` (`src/parser.zig:12176`)

- **签名**：`fn definePatternBindingAtom(s: *State, binding: PatternBindingMode, name: Atom) Error!PatternTarget`。
- **作用**：为 pattern 里的一个标识符建立绑定，并返回后续赋值要用的 `PatternTarget`。
- **实现**：四道前置检查：严格模式（`s.is_strict` 或当前 fd 已严格）下不许绑定 `eval` / `arguments`；`let` / `const` 不许绑定名字 `let`；形参位置额外跑 `checkPatternParameterDuplicate`；`top_level_lexical_as_module_ref` 且正处程序体作用域时，`let` / `const` 与 `hasKnownBinding` 命中的名字（含还没进 vars 的 import 名）冲突要报错。过关后 `defineVar(name, define_type)`。词法声明**不**在声明点发 `set_loc_uninitialized`——TDZ 的唯一一次布防归 `enter_scope` 降级，这里只在 `emit_lexical_tdz_at_decl` 时把 `tdz_emitted_at_decl` 标上；`export_flag` 则顺带登记模块导出名。返回形态分两种：`var` 且 `needVarReference(TOK_VAR)`（要按名字写全局/with/eval 环境）时先 `scope_get_var` 再 `getLValue`，返回 `.lvalue`；其余返回 `.direct_binding`（名字 + 当前 scope + 是否 init 写），稍后由 `emitDirectPatternPut` 落成 `scope_put_var[_init]`。
- **所有权 / 错误 / 调用**：返回值可能是 `.lvalue`，那一支里的 `name` 是 `takeTrailingAtomOpcodeOwned` 交回来的 atom（`owns_name = true`，TGC S3-c 之后实际不再有 release 义务），调用方仍须按协议 `deinit`；`.direct_binding` 则是纯值。对 `FunctionDef` 的写入（`defineVar` 新增的 var / global var、`tdz_emitted_at_decl`、模块导出名）是不可回滚的持久副作用，失败时靠上层丢弃整个 `FunctionDef`。四道检查都经 `failExpectedDescription` 折成 `error.UnexpectedToken` 并留 pending 诊断，其余是 `defineVar` / `getLValue` 上抛的 `OutOfMemory` 与 Builder 错误。两个调用方：`parsePatternBindingTarget`（`src/parser.zig:12696`）与 `shorthandPatternTarget`（`:12723`）。

### `parsePatternBindingTarget` (`src/parser.zig:12224`)

- **签名**：`fn parsePatternBindingTarget(s: *State, binding: PatternBindingMode) Error!PatternTarget`。
- **作用**：在 binding 模式的 pattern 里解析一个标识符目标（`let [a] = …` 里的 `a`），当场把它定义成绑定。
- **实现**：token 必须是标识符类（`isIdentifierLikeToken`）且其转义形式对绑定合法，否则 `failExpectedDescription("binding name")`。取出 atom 后**先** `definePatternBindingAtom` 建绑定、**再** `advance` 吃掉这枚 token——顺序如此才能在 token 仍持有该 atom 时完成定义；`errdefer target.deinit(s)` 保证 advance 失败时 `.lvalue` 形态里的临时资源不泄漏。
- **所有权 / 错误 / 调用**：返回值的所有权归调用方（`.lvalue` 臂带 `owns_name` 的 atom，须配 `PatternTarget.deinit`）；本函数自身只借用 token 的 ident atom，不分配。错误两处：非绑定名 / 非法转义 → `failExpectedDescription("binding name")`（`error.UnexpectedToken`），其余由 `definePatternBindingAtom` 与 `advance` 上抛。唯一调用方 `parsePatternTarget` 的 `.binding` 臂（`src/parser.zig:12704`）。

### `parsePatternTarget` (`src/parser.zig:12235`)

- **签名**：`fn parsePatternTarget(s: *State, mode: PatternMode) Error!PatternTarget`。
- **作用**：按 pattern 所处的模式取出一个赋值目标：binding 模式建新绑定，assignment 模式解析出一个 lvalue。
- **实现**：`.binding` 臂直接转 `parsePatternBindingTarget`；`.assignment` 臂先 `parseLhsExpr`（`in_accepted = false`，`for (… in …)` 头里的 `in` 不属于目标表达式）再 `getLValue(s, false)` 折成 `.lvalue`，于是 `[obj.x] = arr`、`({a: o[i]} = x)` 这类成员目标能被同一套 pattern 代码消费。
- **所有权 / 错误 / 调用**：只是两条臂的分派，自身不分配；返回的 `PatternTarget` 归调用方 `deinit`。注意 `.assignment` 臂有**已发出的字节码副作用**——`parseLhsExpr` 已经把目标表达式的取值序列写进了当前流，`getLValue` 再把最后那条 getter 截掉换成 lvalue 描述符，所以失败后无法局部回滚。三个调用点都在 pattern 体里：`parseArrayPatternBody`（`src/parser.zig:12984`）、`parseObjectPatternBody`（`:13022` / `:13091`）。

### `shorthandPatternTarget` (`src/parser.zig:12245`)

- **签名**：`fn shorthandPatternTarget( s: *State, mode: PatternMode, property: ObjectPropertyName, ) Error!PatternTarget`。
- **作用**：把对象 pattern 的简写属性 `{ x }` 变成绑定目标或赋值 lvalue。
- **实现**：先拒掉不能简写的属性：`allow_shorthand` 为假（计算属性名、字符串/数字键等），或名字是带转义写法的保留字（`escapedIdentifierIsReservedWordForBinding`），都报 `failExpectedDescription("binding shorthand")`。通过后按模式分流：binding 拿属性名 atom 直接 `definePatternBindingAtom`；assignment 则 `scope_get_var` 取同名变量再 `getLValue` 折成 lvalue。
- **所有权 / 错误 / 调用**：`property.atom` 是调用方传进来的借用 atom，本函数不 retain；返回的 `PatternTarget` 归调用方 `deinit`。`.assignment` 臂会先发一条 `scope_get_var`，是不可回滚的字节码副作用。错误：不可简写 → `failExpectedDescription("binding shorthand")`（`error.UnexpectedToken`），其余由 `definePatternBindingAtom` / `getLValue` 上抛。两个调用点都在 `parseObjectPatternBody`：`get_field2` 快路径（`src/parser.zig:13066`）与一般路径（`:13093`，此处 `property_info` 为 `null` 会返回 `Error.ParserInvariant`）。

### `shorthandPatternCanUseGetField2` (`src/parser.zig:12264`)

- **签名**：`fn shorthandPatternCanUseGetField2(s: *State, mode: PatternMode) bool`。
- **作用**：谓词：简写属性能否用 `get_field2`（保留对象在栈上）而不是先 dup。
- **实现**：binding 模式下只要不是 `var`，或者虽是 `var` 但 `needVarReference(TOK_VAR)` 为假（不必按名字写全局/with/eval 环境），就返回 true——可以用 `get_field2` 把源对象留在栈上，省掉一次 `dup`。`var` 且需要 var reference 时目标要先在栈上摆好 ref，返回 false。assignment 模式恒 false。
- **所有权 / 错误 / 调用**：无：两条臂的只读判定（`.assignment` 恒假；`.binding` 问 `define_type` 与 `needVarReference`），不分配、无 error set、不改 `State`。唯一调用方 `parseObjectPatternBody`（`src/parser.zig:13063`），用来决定简写属性能否走 `get_field2` 快路径。

### `parseArrayPatternBody` (`src/parser.zig:12476`)

- **签名**：`fn parseArrayPatternBody(s: *State, mode: PatternMode) Error!void`。
- **作用**：解析数组解构体 `[a, , ...rest]`（binding 与 assignment 两种模式共用），并发射按迭代器协议取值的字节码。
- **实现**：吃掉 `[` 后先 `for_of_start` 建迭代器，并压一个 `BlockEnv` 迭代器块（`defer` 保证异常路径也弹栈）。循环直到 `]`：`EOF` 报缺 `]`；`...` 置 `spread_rest` 特征位并要求后面确有目标（紧跟 `,` 或 `]` 即报错）。空洞（`,`）发 `for_of_next 0` 再两次 `drop` 丢掉值与 done 标志。嵌套 pattern（由 `tokenStartsNestedPattern` 判定）先把元素取到栈上：rest 走 `emitArrayPatternRest(0)`（且再看一次拓扑，rest 后面带 `=` 报 "rest element may not have an initializer"），普通元素走 `for_of_next 0 ; drop`，然后递归 `parseDestructuringElement`。普通目标先 `parsePatternTarget` 拿到 `PatternTarget`，按它的 `depth()`（lvalue 在栈上占的格数）发 `for_of_next depth ; drop`，`parsePatternDefault` 处理 `= 默认值`，最后 `putPatternTarget` 落值；rest 形态改走 `emitArrayPatternRest(depth)` 且不允许默认值。每轮末遇 `]` 跳出，rest 之后不许再有逗号，否则 `expectToken(',')`。收尾 `]` + `iterator_close` 并弹掉迭代器块。
- **所有权 / 错误 / 调用**：本函数不分配堆内存，但对字节码流与 `State` 都有不可回滚的副作用：`for_of_start` 之后栈上多了一组迭代器三元组，必须靠 `iterator_close` 平衡。唯一需要显式配对的是那个 `BlockEnv` 迭代器块——用局部 `block_active` 配 `defer`，正常路径在收尾处先手工 `popPatternIteratorBlock` 再把标志清掉，错误路径由 `defer` 兜底，保证 `State` 的块栈不留残留。每轮的 `PatternTarget` 各自 `defer target.deinit(s)`。错误：缺 `]` / 缺 `,` 经 `failExpectedToken`，rest 后跟 `,`/`]`/`=` 经 `failExpectedDescription` 或 `failWithMessage`，都是 `error.UnexpectedToken`。唯一调用方 `parseDestructuringElement`（`src/parser.zig:13153`）。

### `parseObjectPatternBody` (`src/parser.zig:12541`)

- **签名**：`fn parseObjectPatternBody(s: *State, mode: PatternMode, has_rest: bool) Error!void`。
- **作用**：解析对象解构的花括号主体 `{ a, b: x = d, ...rest }` 并发出取值与写回。
- **实现**：
吃掉 `{` 后先 `ext0.to_object` 把源强制成对象；`has_rest`（由外层拓扑扫描给出）时再压一个空 `object` 并 `swap`，这个新对象就是 rest 的收集器。循环到 `}`：`EOF` 报缺 `}`；`...` 分支要求 `has_rest` 为真（否则 `Error.ParserInvariant`），解析目标后必须紧跟 `}`，然后按目标 `depth()` 算出 `objectRestCopyMask`，发 `object` + `copy_data_properties mask` 再写回并 `break`。普通属性先取键：`[` 走 `parseAssignExpr` + `]` 记 `computed`，否则 `parseObjectPropertyName`；`:` 决定 `explicit_target`，计算键没有 `:` 直接 `failExpectedToken(':')`。随后三条臂——(1) 显式目标且嵌套 pattern：`has_rest` 时先登记排除项（`addComputedObjectRestExclusion` / `addNamedObjectRestExclusion`），再 `get_array_el2` / `get_field2` 取出子值递归进 `parseDestructuringElement`；(2) 简写且 `shorthandPatternCanUseGetField2`：一条 `get_field2` 同时保源取值（目标 `depth()` 必须为 0，否则 ICE），接 `parsePatternDefault` + `putPatternTarget`；(3) 其余：`dup` / `ext0.dup1` 复制源，解析目标后按 `depth()` 用 `rotateNamedSourcePastTarget` / `rotateComputedSourcePastTarget` 把源转到目标之上，再 `get_field` / `get_array_el` 取值、默认值、写回。末尾允许尾逗号（`,` 后再见 `}` 即跳出）。收尾 `}` 之后 `drop` 掉源对象，`has_rest` 时再 `drop` 一次。
- **所有权 / 错误 / 调用**：不分配堆内存；每个 `PatternTarget` 各自 `defer target.deinit(s)`。`property_info` 里的 atom 是借用的（`parseObjectPropertyName` 的产物，第 13043 行那条 `defer if (property_info) |_| {}` 是 TGC S3-c 之后留下的空壳）。栈平衡靠约定而非结构：`to_object` / `object` 压入的值由收尾的 `drop` 负责。错误：缺 `}` / 缺 `,` / 缺 `:` 经 `failExpectedToken`，`property_info` 为 `null` 或没有 `has_rest` 却见到 `...` 是 `Error.ParserInvariant`（ICE 出口）。唯一调用方 `parseDestructuringElement`（`src/parser.zig:13154`，`has_rest` 取自它预扫出的 `topology.has_top_level_rest`）。

### `parseDestructuringElement` (`src/parser.zig:12653`)

- **签名**：`fn parseDestructuringElement( s: *State, mode: PatternMode, has_value: bool, allow_outer_initializer: bool, initializer_flags: ParseFlags, ) Error!bool`。
- **作用**：解析一个解构目标（数组或对象 pattern），必要时连带它的外层 `= 默认值`，返回是否确实存在默认值。
- **实现**：先记 `.destructuring` feature，`scanPatternTopology` 把 pattern 拓扑一次扫清（同时得到 pattern 之后紧跟的 token）；`has_initializer` = 允许外层初始化器且后面是 `=`。既没有待解构的值又没有初始化器时报 `"destructuring declaration requires an initializer"`。有初始化器时先搭跳转骨架：新建 `parse_label`，有值就 `dup; undefined; strict_eq; if_true → parse_label`（值为 `undefined` 才去求默认值），无值则无条件 `goto parse_label`；再建 `assign_label` 并用 `emitterBindLabelRaw` 绑在此处，无值时补一个 `dup`。接着按当前 token 分派 pattern 主体：`[` → `parseArrayPatternBody`，`{` → `parseObjectPatternBody`（带上 `topology.has_top_level_rest`），其他 token 说明调用方判断有误，`Error.ParserInvariant`。有初始化器时收尾：`goto done`、绑 `parse_label`、有值先 `drop` 掉那个 `undefined`、`expectToken('=')`、`parseAssignExpr2` 求默认值、`goto assign_label` 回到 pattern 主体、绑 `done`。这个「默认值字节码发在 pattern 之后、运行时却先到达」的布局既保住了源码子结点顺序，也不需要额外临时槽。
- **所有权 / 错误 / 调用**：不分配堆内存；产出的三个 `LabelId`（`parse_label` / `assign_label` / `done`）归 Builder 记账，全部在本函数内绑定，失败时整个 `FunctionDef` 被上层丢弃，没有局部回滚。返回值 `bool` 就是「是否消费了外层 `=`」，调用方据此决定形参的 `defined_arg_count`。错误：缺初始化器经 `failWithMessage`、缺 `=` 经 `expectToken`（都是 `error.UnexpectedToken`），当前 token 不是 `[`/`{` 是 `Error.ParserInvariant`（调用方本该先判定过），其余来自 label/emit 的 `OutOfMemory`。八个调用点：`parseDestructuringAssignment`（`src/parser.zig:4129`）、`parseVarDecl` 系（`:9808`）、`for` 头与 `for-in/of`（`:10676` / `:10821` / `:10890`）、pattern 体递归（`:12982` / `:13062`）、以及形参解构 `parseParameterDestructuring`（`:13475`）。

### `appendArrowParamBindingName` (`src/parser.zig:12703`)

- **签名**：`fn appendArrowParamBindingName(s: *State, names: *std.ArrayList(Atom), atom_id: Atom) Error!void`。
- **作用**：把一个箭头形参名登记进已见名字表，重名即报错。
- **实现**：线性扫已收集的 `names`，撞到同一个 atom 就 `failUnexpectedToken`（箭头形参不允许重名，与普通函数的非严格重名规则不同）；否则 `appendOwnedParserAtom` 追加。
- **所有权 / 错误 / 调用**：先线性查重、再经 `appendOwnedParserAtom`（`src/parser.zig:11247`）往调用方给的 `std.ArrayList(Atom)` 追加——缓冲归调用方（`parseArrowFunction` 的 `param_names`，由它自己 `deinit`），元素只是 atom id、不 retain。错误两类：重名 → `failUnexpectedToken`（pending 诊断 + `Error.UnexpectedToken`，最终是 JS SyntaxError），`ensureUnusedCapacity` → `OutOfMemory`。两个调用方都在 `parseArrowFunction`（`:12283`/`:12368`）。

### `enterParameterExpressionScope` (`src/parser.zig:12965`)

- **签名**：`fn enterParameterExpressionScope(s: *State) Error!i32`。
- **作用**：开一层「参数环境」作用域（父指针为 -1）并发 `enter_scope`。
- **实现**：
`appendScope(-1)` 建一层**没有父**的作用域（qjs 也强制参数环境无父），把 `State.scope_level` 与 `FunctionDef.scope_level` 都切过去，再 `emitEnterScope` —— 这条 `enter_scope` 正是把每个形参绑定降成「初始未初始化的词法槽」的地方，先于任何默认值初始化器运行。返回新作用域号供 `leaveParameterExpressionScope` 收口。
- **所有权 / 错误 / 调用**：不分配（`appendScope` 的失败一律折成 `error.OutOfMemory`），但对 `FunctionDef` 是**不可回滚的持久写**：新 scope 行、`scope_level` 的双份切换（`State` 与 `FunctionDef` 各一份）、以及已发出的 `enter_scope` 指令；失败只能靠上层丢弃整个 `FunctionDef`。返回的 scope 号必须交回 `leaveParameterExpressionScope` 才能把 `scope_level` 归 0。两个调用方：`parseFunctionParameters`（`src/parser.zig:11312`）与 `parseArrowFunction`（`:12273`），都只在 `capture_child` 且预扫报告有参数表达式时调用。

### `appendParameterExpressionBinding` (`src/parser.zig:12978`)

- **签名**：`fn appendParameterExpressionBinding(s: *State, name: Atom) Error!void`。
- **作用**：把一个形参名登记成参数环境里的 `let` 绑定。
- **实现**：
一行 `defineVar(name, .let_)`：参数环境里的形参名是词法绑定，不是 `var`。
- **所有权 / 错误 / 调用**：只是 `s.defineVar(name, .let_)` 的一行包装，丢弃其返回的槽位（形参的实际写入由 `initializeParameterScopeBinding` 完成）。`name` 是借用的 atom id，不 retain；新增的 VarDef 行是持久副作用。错误只有 `defineVar` 上抛的 `OutOfMemory`（`.let_` 在这里不会撞重复声明，形参重名已由更早的检查拦下）。四个调用点：`parseFunctionParameters` 的简单形参与 rest（`src/parser.zig:11352` / `:11439`）、`parseArrowFunction` 的对应两处（`:12290` / `:12374`）。

### `initializeParameterScopeBinding` (`src/parser.zig:12982`)

- **签名**：`fn initializeParameterScopeBinding(s: *State, name: Atom, arg_index: u32) Error!void`。
- **作用**：用实参槽的值初始化参数环境里的同名绑定。
- **实现**：
两条指令：`get_arg <arg_index>` 取实参，`emitScopePutVarInit(name)` 完成该词法槽的初始化（TDZ 结束）。
- **所有权 / 错误 / 调用**：只发两条指令，不分配、不持有任何资源；`name` 是借用的 atom id。必须跟在 `appendParameterExpressionBinding` 之后使用——它初始化的正是那条 `let` 槽，`scope_put_var_init` 而不是 `scope_put_var`，因为参数环境的 `enter_scope` 把这些槽布成了未初始化状态。错误只有 emit 路径的 `OutOfMemory` / Builder 错误。四个调用点：`parseFunctionParameters`（`src/parser.zig:11392` / `:11454`）与 `parseArrowFunction`（`:12329` / `:12389`）。

### `parseParameterDestructuring` (`src/parser.zig:12987`)

- **签名**：`fn parseParameterDestructuring( s: *State, arg_index: ?u32, has_parameter_expressions: bool, value_already_on_stack: bool, allow_outer_initializer: bool, ) Error!bool`。
- **作用**：解析形参表里的一个解构形参（`function f({a}, [b])`），把对应实参取上栈再交给通用解构路径。
- **实现**：进入时按 `has_parameter_expressions` 置 `in_parameter_initializer`（`defer` 恢复），让内层表达式知道自己在参数初始化器里（影响 eval 与 `arguments` 的处理）。值不在栈上时：有 `arg_index` 就 `get_arg idx`，没有就压 `undefined`。随后转 `parseDestructuringElement`，绑定种类取决于有无参数表达式：有则 `.let_`（形参活在独立的参数作用域里），无则 `.var_`（直接是函数体的 var）；并置 `is_parameter = true` 触发重名检查、`export_flag = false`。返回值透传「这个形参带不带默认值」，调用方据此记 `first_default_param`。
- **所有权 / 错误 / 调用**：不分配；唯一显式恢复的状态是 `in_parameter_initializer`（`defer`）。发出的 `get_arg` / `undefined` 与 `parseDestructuringElement` 里的整段 pattern 代码都是不可回滚的字节码副作用，`defineVar` 新增的绑定同样是持久写。错误全部由 `parseDestructuringElement` 上抛（`error.UnexpectedToken` 族、`Error.ParserInvariant`、`OutOfMemory`）。八个调用点：`parseFunctionParameters` 的 `{` / `[` 形参与 rest 解构（`src/parser.zig:11398` / `:11411` / `:11465` / `:11480`）、`parseArrowFunction` 的对应四处（`:12336` / `:12350` / `:12400` / `:12415`）。

### `leaveParameterExpressionScope` (`src/parser.zig:13020`)

- **签名**：`fn leaveParameterExpressionScope(s: *State, parameter_scope: i32) Error!void`。
- **作用**：关闭参数环境：把只存在于该环境的名字复制成函数体的 var，再发 `leave_scope`。
- **实现**：沿 `scopes[parameter_scope].first` 链遍历参数作用域里的每一行（`visited` 上限加下标、层级校验，异常即 `ParserInvariant`）。凡是既不是形参（`fd.findArg`）也不是函数体已有 var（`findFunctionScopeVar`）的名字——即只存在于参数环境里的那些——用 `appendFunctionVarAtOrigin(name, 0)` 在函数体侧补一条 scope-0 行，再发 `get_loc_check idx ; put_loc body_idx` 把值搬过去；对照 QuickJS 这里用的是 `add_var` 而非 `add_scope_var`，所以这条新行有意不挂进任何词法 `scope.first` 链。收尾显式 `emitLeaveScope(parameter_scope)`（参数作用域故意没有 parent，qjs 同样是显式发事件而不是 `pop_scope`），并把 `scope_level` / `fd.scope_level` 归 0、`fd.scope_first` 复位成 scope 0 的链头。
- **所有权 / 错误 / 调用**：不分配堆内存；对 `FunctionDef` 的写（新 var 行、`scope_level` / `scope_first` 复位）与发出的 `get_loc_check` / `put_loc` / `leave_scope` 都是持久副作用。调用方**不用** `defer` 保护它：它只在正常路径上被调用（`if (parameter_scope) |scope| try leaveParameterExpressionScope(...)`），错误路径由上层丢弃整个 `FunctionDef` 收尾。错误：链表遍历发现越界下标、层级不符或圈数超过 `fd.vars.len` 时返回 `Error.ParserInvariant`（ICE 出口），其余是 `appendFunctionVarAtOrigin` / emit 的 `OutOfMemory`。两个调用方：`parseFunctionParameters`（`src/parser.zig:11503`）与 `parseArrowFunction`（`:12438`）。

### `scanParameterList` (`src/parser.zig:13052`)

- **签名**：`fn scanParameterList(s: *State) Error!ParameterListScan`。
- **作用**：前瞻扫一遍形参表，只回答「里面有没有 `=` 默认值表达式」。
- **实现**：
一次 `scanBalancedToken(s, false)` 括号平衡扫描，只把结果里的 `has_assignment` 抽出来当 `has_parameter_expressions`；不建绑定、不发码。
- **所有权 / 错误 / 调用**：两行前瞻包装：`scanBalancedToken` 负责光标存取与临时 token 的释放，本函数只把 `has_assignment` 重命名成 `has_parameter_expressions` 返回，不分配、不改 `State`。错误全部来自 `scanBalancedToken`（未闭合的 `SyntaxError` 族、lexer 错误、`OutOfMemory`）。两个调用方：`parseFunctionParameters`（`src/parser.zig:11308`）与 `parseArrowFunction`（`:12269`）。

### `ensureDestructuringArgSlot` (`src/parser.zig:13057`)

- **签名**：`fn ensureDestructuringArgSlot(s: *State, arg_index: u32) Error!void`。
- **作用**：给形参位置上的解构模式补齐对应的匿名实参槽，让后面的 `get_arg idx` 有东西可读。
- **实现**：循环 `appendArg` 直到 `args.len > arg_index`，补出来的行是匿名的（`var_name = null_atom`、`scope_level = 0`、非词法、非 const、`.normal`）；随后若 `arg_count` 小于 `arg_index + 1` 就把 `arg_count` 与 `defined_arg_count` 一起抬上去（已经更大时不动）。调用方是形参表解析里遇到 `{` / `[` 形参且 `capture_child` 为真的那几个臂，在 `parseParameterDestructuring` 之前调。
- **所有权 / 错误 / 调用**：**在当前 `FunctionDef` 上留持久副作用**：循环 `appendArg` 补匿名参数行（`var_name = null_atom`，`growSliceBy(fd.memory)`），并把 `arg_count`/`defined_arg_count` 顶到 `arg_index + 1`；这些行归 `FunctionDef`，本函数不回滚——失败时由上层丢弃整个 def。错误只有 `appendArg` 的 `OutOfMemory`。8 个调用方，全在参数解构路径：`parseFunctionParameters`（`src/parser.zig:11397`/`:11410`/`:11459`/`:11474`）与 `parseArrowFunction`（`:12335`/`:12349`/`:12394`/`:12409`）。

### `findCurrentScopeVar` (`src/parser.zig:13075`)

- **签名**：`fn findCurrentScopeVar(s: *State, atom_id: Atom) ?u16`。
- **作用**：在当前 `FunctionDef.vars` 里按名字找**恰好属于当前作用域层级**的那条变量。
- **实现**：从尾向头扫 `curFunc().vars`，要求 `var_name` 相等且 `scope_level == s.scope_level`，命中即返回下标，扫完返回 `null`。从尾扫是因为同名行按声明顺序追加，最后一条才是当前可见的那条。两处用它：Annex B 块级函数声明在 `force_local_init` 时复用已有槽并补标 `tdz_emitted_at_decl`，以及 `preparePrivateAccessorBinding` 把同名 `#x` 的 getter/setter 合并成 `private_getter_setter`。
- **所有权 / 错误 / 调用**：无：从后往前扫 `curFunc().vars`，只返回**下标**（不是指针），所以不受后续扩容影响；不分配、无 error set、无副作用。两个调用方：`parseFunctionParamsAndBody`（`src/parser.zig:11857`）与 `preparePrivateAccessorBinding`（`:14018`）。

### `appendAnonymousTempLocal` (`src/parser.zig:13085`)

- **签名**：`fn appendAnonymousTempLocal(s: *State) Error!u16`。
- **作用**：追加一个无名临时局部槽。
- **实现**：
向当前 `FunctionDef` 追加一行 `var_name = null_atom`、`scope_level = 0`、非词法非 const 的 `.normal` 变量，返回其下标。因为没有名字，它只能靠槽号访问，不会参与任何按名解析。
- **所有权 / 错误 / 调用**：在 `curFunc().vars` 上追加一行匿名局部（`var_name = null_atom`，`growSliceBy(fd.memory)`），槽号返回给调用方**但存储归 `FunctionDef`**，没有释放接口——这些临时槽一直活到 finalize。唯一错误是 `appendVar` 的 `OutOfMemory`。4 个调用方，全是 using / for-of 的隐藏局部：`emitCreateUsingDisposableStack`（`src/parser.zig:8393`）、`parseUsingDeclaration`（`:9965`）、`parseForInOf`（`:10806`/`:11014`）。

### `parseNamedBindingDefaultInitializer` (`src/parser.zig:13096`)

- **签名**：`fn parseNamedBindingDefaultInitializer(s: *State, atom_id: Atom) Error!void`。
- **作用**：解析具名绑定的 `= 默认值`，并给紧跟其后的匿名函数 / 类补上推断名。
- **实现**：
两步：`parseAssignExpr` 解析 `= ` 右边的默认值，再 `emitAnonymousDefaultName(atom_id)` 给紧跟其后的匿名函数/类补上推断名。
- **所有权 / 错误 / 调用**：不分配；`atom_id` 是调用方借用的形参名 atom，只被 `emitAnonymousDefaultName` → `setObjectName` 写进已发出的 `set_name` / `define_class` 操作数里。注意它**不**自己吃掉 `=`——调用方先 `advance` 过 `=` 才进来，函数返回时默认值的求值代码已经留在栈顶，是不可回滚的副作用。错误来自 `parseAssignExpr`（`error.UnexpectedToken` 族）与 `setObjectName` 的 `Error.ParserInvariant`（尾部字节不是预期的补丁形状）。四个调用点，全是带默认值的简单形参：`parseFunctionParameters`（`src/parser.zig:11380` / `:11387`，分别是 `capture_child` 与非 capture 两条臂）与 `parseArrowFunction`（`:12317` / `:12324`）。

### `trailingClassNamePatch` (`src/parser.zig:13101`)

- **签名**：`fn trailingClassNamePatch( s: *State, builder: *compiler.Builder, marker_pos: u32, ) Error!ClassNamePatch`。
- **作用**：校验并取回上一条 `define_class` 的类名补丁点（校验不过即 `ParserInvariant`）。
- **实现**：从 `s.last_class_name_patch` 取出上次记下的补丁点，再做四轮全等校验，任一不符即 `ParserInvariant`：(1) patch 记的 builder 与 `marker_pos` 必须与传入的一致，且 marker 正好占住 code 尾部 5 字节；(2) marker 后 4 字节小端读出的 `distance` 非零、不超过 marker 偏移，且 `marker_after - distance` 正好回指 `define_class_pos`；(3) `define_class_pos` 处确实是 `define_class`，其 4 字节 atom 操作数当前是占位的 `empty_string`，且这段码至少还有 6 字节；(4) `atom_index` 落在 `atom_operands` 范围内且该槽同样是 `empty_string`。全部通过才把 patch 返回给调用方去回填真实类名——校验的意义是保证这段尾部字节确实是刚发出的那条待补 `define_class`，而不是被其它发射打断过。
- **所有权 / 错误 / 调用**：纯校验取值：从 `s.last_class_name_patch` 取出记录并做六重一致性检查（builder 身份、marker 位置、5 字节尾形、`distance` 反算出的 `define_class_pos`、该处确实是 `define_class`、其 atom 立即数与 atom 操作数都还是 `ids.empty_string`），返回的是**按值的副本**，不清除 `s.last_class_name_patch`（清除由调用方在改写成功后做）。不分配、不修改 Builder。任何一项不符都返回 `Error.ParserInvariant`——内部不变量，走 `setInternalCompilerError` 的 ICE 出口而不是用户 SyntaxError。两个调用方：`setObjectName`（`src/parser.zig:13628`）与 `setObjectNameComputed`（`:13666`）。

### `parseClassHeritage` (`src/parser.zig:13215`)

- **签名**：`fn parseClassHeritage(s: *State) Error!void`。
- **作用**：解析可选 `extends` 子句并求值父类表达式。
- **实现**：
有 `extends` 则消费它，禁止紧跟箭头头（`extends () =>` 非法），`parseLhsExpr` 求值父类。没有则不压栈，`define_class` 的 heritage 由调用方补 `undefined`（`parseClass` 里的 `if (!class_has_extends) Emitter.op(undefined)`）。
- **所有权 / 错误 / 调用**：不分配、不保存任何状态；有 `extends` 时把父类表达式的求值代码留在栈顶，是不可回滚的副作用。箭头头检测用 `checkArrowHead` / `checkAsyncArrowHeadAfterAsync` 做前瞻（它们自己负责光标复位），命中就 `failWithMessage("class heritage must be a left-hand-side expression")`。唯一调用方 `parseClass`（`src/parser.zig:14819`），且必须在类名绑定 `defineVar(.const_)` **之前**调用，`extends` 表达式里的类名才处于 TDZ。

### `parseClassElement` (`src/parser.zig:13231`)

- **签名**：`fn parseClassElement(s: *State) Error!void`。
- **作用**：解析一个类元素（字段/方法/访问器/static block/私有名）。
- **实现**：
保存/恢复 `is_static`、`in_constructor`。`static` 仅当后面不是 `;`/`}`/`(`/`=` 时当修饰符（否则它是名字）。

然后 `async` / `*` 设 method_kind。`get`/`set`：私有访问器登记 `#` 名并 `parseClassElementFunction`，`set_home_object` 后 `scope_put_var_init`（setter 用 `<set>` 伴生 atom）；计算名走 `emitClassComputedMethod`；普通名 `define_method` getter/setter 旗。禁止 `get constructor`、static `prototype`。

`#name`：字段或方法（`(`）。`#constructor` 非法。方法 `registerClassPrivateElement` + 函数 + brand；字段进 fields_init 函数。

`constructor`：只能一份、非 static、非 generator/async；派生构造器 `derived_class_constructor`。`static { }` 进 static init 函数。计算名元素按 `is_static` 分流：静态的走 `emitStaticClassComputedElement`，实例的走 `emitInstanceClassComputedElement`（两者都吃 `method_kind_override orelse .method`，字段与方法在里面再分）。普通字段可无初始化器（`emitPublicFieldNoInitializer`），且 `constructor` / `#constructor` 之类的名字由 `isForbiddenPublicFieldName` 挡掉。空元素 `;` **不在本函数**处理——`parseClassBodyAfterOpen`（`src/parser.zig:14591`）在进来之前就把它吃掉了。
- **所有权 / 错误 / 调用**：自己只保存 / 恢复 `is_static` 与 `in_constructor` 两个标量（`defer` 一份，正常路径末尾又手写了一份，重复但无害）。其余状态写进 `State` 的类级容器（`class_private_elements`、`class_private_bound_names`、`class_constructor_cpool_idx`、两个 brand 标志、`class_fields_init_child_index` / `class_static_init_child_index`），**本函数不回滚**——统一由 `parseClass` 的 `errdefer` 按进入时的长度 `truncate` 掉。私有名 atom 经 `privateNameAtom` / `privateSetterAtom` 产出并登记进类绑定表，生命周期归 `CompileAtomScope`。显式构造器那一支会 `snapshot()` / `rollback()` 当前 Builder，把普通 `fclosure` 表达式撤掉，改成用 `class_constructor_cpool_idx` 让 `define_class` 引用子函数——这是本函数里唯一的字节码回滚点。错误：重复构造器、`#constructor`、`static prototype`、非静态的 `{` 块等经 `failUnexpectedToken` / `failExpectedToken` 折成 `error.UnexpectedToken`；构造器 cpool 下标越界是 `Error.ParserInvariant`。唯一调用方 `parseClassBodyAfterOpen`（`src/parser.zig:14595`）。

### `parseClass` (`src/parser.zig:14280`)

- **签名**：`fn parseClass(s: *State, is_decl: bool) Error!?Atom`。
- **作用**：解析类声明或类表达式的整个 ClassTail：作用域、heritage、私有名预扫、类体、`define_class` 与各类初始化调用。
- **实现**：
对照 `js_parse_class`（`quickjs.c:24667`）。`class` 关键字后可选/必选名字。整个 ClassTail 词法严格（禁八进制字面量/转义）。先 `pushScope` 再 `parseClassHeritage`（`extends` 在名字绑定之前求值，故 heritage 里的类名是 TDZ）。再 `defineVar(.const_)` 内部名。`collectClassPrivateBoundNames` 预扫 `#` 名。第二个 scope 放 `<class_fields_init>` const。

`parseClassBodyAfterOpen` 的运行时字节码 `emitterDetachTail` 挪到 `define_class` 之后（对齐 qjs 把 body 推迟）。无构造器则 `appendDefaultClassConstructor`。弹出两个 scope 的 identity，发射 `define_class`、private brand、splice 运行时段、初始化内部名与 fields_init、static init 调用，再 `leave_scope` 两层。声明在 ClassTail 之后才 `defineVar(.let_)` 外层绑定（computed key 期间外层仍 TDZ）。表达式返回 null 名字；声明返回 owned 名字 atom。
- **所有权 / 错误 / 调用**：全局回滚点是开头那个大 `errdefer`：按 `class_private_scope_pushed` / `class_outer_scope_pushed` 弹回 scope identity，把 `class_private_elements` / `class_private_bound_names` 截回进入时的长度，并还原 `class_fields_init_child_index`、`class_static_init_child_index`、两个 brand 标志与 `is_static` / `is_strict` / `lex.is_strict_mode`（成功路径则在中段手工还原同一组字段并把两个 pushed 标志清掉，`errdefer` 便不再重复弹栈）。`runtime_seg` 这段从 Builder 尾部摘下来的字节码由 `defer s.activeBuilder().discardSegment(&runtime_seg)` 兜底，正常路径被 `emitterSpliceSegment` 消费掉。返回值是**移交给调用方的类名 atom**：声明路径在 `return` 前把局部 `class_name` 置 `null` 以示交出，表达式路径返回 `null`。错误：模块顶层重名经 `failExpectedDescription`，缺名字 / 缺 `{` 经 fail 族，内部不变量（声明却没有名字、缺 `class_fields_init` 槽、marker 偏移倒挂）是 `Error.ParserInvariant`，字节码偏移溢出是 `Error.BytecodeOverflow`。五个调用点：类表达式（`src/parser.zig:6308`）、类声明语句（`:9128`）、`export`（`:15463` / `:15466`）、`export default`（`:15624`）。

## 覆盖核对

- 清单函数数（本文件分到）: 40（`src/parser.zig` 全文件 622）
- 本文标题覆盖: 40
- 未覆盖: 无

全文件清单共 622 个函数；以 `03-parser*.md` 合计为准。
