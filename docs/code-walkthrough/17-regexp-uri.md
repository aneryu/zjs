# 17 — RegExp 与 URI

RegExp 分三层：`regexp_ops` 记录/编译/escape，`regexp_fastpath` 可观察 exec/test/construct，`regexp_adapter` 接到 `libs/regexp.zig`（栈溢出与 timeout）。URI 全局在 `uri_ops`，decode 按 qjs 代码单元 + UTF-8 组装。



## `src/exec/regexp_ops.zig` — RegExp 记录 / 编译 / escape

匹配引擎在 `libs/regexp.zig`；可观察的 exec/test/species 在 `regexp_fastpath.zig` 与 `string_ops.zig`。本文件：构造记录、flags/source 访问器、`RegExp.escape`、编译选项与栈溢出。

`regexpCall`：`new RegExp` 走 construct 分支（可无 materialized 构造器对象）；`RegExp()` 作函数走 fastpath 的「已是 RegExp 且无 flags 则原样返回」。


### `prototypeMethodId` (`src/exec/regexp_ops.zig:44`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把安装期看到的 `RegExp.prototype` 方法名映射到记录 id。
- **实现**：一串 `std.mem.eql`，覆盖 `toString`、`test`、`exec`、`[Symbol.search]`、`[Symbol.match]`、`[Symbol.matchAll]`、`[Symbol.replace]`、`[Symbol.split]`、`compile` 九个名字（symbol 方法用带方括号的安装名），返回对应的 `PrototypeMethod` 值；全不匹配返回 null。
- **所有权 / 错误 / 调用**：纯映射；访问器名走 `accessorMethodId`（已搬到 core）。

### `decodePrototypeMethodId` (`src/exec/regexp_ops.zig:57`)

- **签名**：`pub fn decodePrototypeMethodId(id: u32) ?u32`。
- **作用**：把 `PrototypeMethod` 记录 id 压成 `regexpCall` 内部用的 1..9 小编号。
- **实现**：`switch (id)`：`to_string`→1、`test_`→2、`exec`→3、`symbol_search`→4、`symbol_match`→5、`symbol_match_all`→6、`symbol_replace`→7、`symbol_split`→8、`compile`→9；不是原型方法 id 时返回 null（`regexpCall` 据此报 TypeError）。
- **所有权 / 错误 / 调用**：纯映射。

### `regexpEntry` (`src/exec/regexp_ops.zig:147`)

- **签名**：`fn regexpEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：构造走共享 magic 分派的普通 `.regexp` 记录。
- **实现**：`.magic = @intCast(id)`、`.cproto = .generic_magic`、`.native_function = builtin_dispatch.genericMagicFunction(&regexpCall)`。表里的 `escape`、`toString`、`test`、`[Symbol.search]`、`[Symbol.matchAll]`、`[Symbol.replace]`、`compile` 以及 15 条 legacy 静态访问器（`get input` / `set input` / `get lastMatch` / `get lastParen` / `get leftContext` / `get rightContext` / `get $1`..`get $9`）都用它。
- **所有权 / 错误 / 调用**：comptime 求值。

### `regexpGenericEntry` (`src/exec/regexp_ops.zig:158`)

- **签名**：`fn regexpGenericEntry( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime implementation: core.host_function.NativeGenericFn, ) core.host_function.InternalEntry`。
- **作用**：给热点方法造「专用处理函数」记录，绕开共享的 magic switch。
- **实现**：`.id = id` 但 `.magic = 0`，`.cproto = .generic`，`.native_function = .{ .generic = implementation }`——调用时直接进指定实现。表里 `exec`（`regexpExecCall`）、`[Symbol.match]`（`regexpSymbolMatchCall`）、`[Symbol.split]`（`regexpSymbolSplitCall`）三条用它。
- **所有权 / 错误 / 调用**：comptime 求值。

### `regexpGetterEntry` (`src/exec/regexp_ops.zig:178`)

- **签名**：`fn regexpGetterEntry( comptime name: []const u8, comptime id: u32, comptime implementation: core.host_function.NativeGetterFn, ) core.host_function.InternalEntry`。
- **作用**：造 `source` / `flags` 这两个各有独立 getter 的访问器记录。
- **实现**：`.length = 0`、`.magic = 0`、`.cproto = .getter`、`.native_function = .{ .getter = implementation }`。源码注明这是照搬 QuickJS 的调用形状：`flags` 与 `source` 有各自的 getter 函数，只有八个布尔 flag getter 才共享 `JS_CGETSET_MAGIC_DEF`。
- **所有权 / 错误 / 调用**：comptime 求值。

### `regexpFlagGetterEntry` (`src/exec/regexp_ops.zig:193`)

- **签名**：`fn regexpFlagGetterEntry(comptime name: []const u8, comptime id: u32, comptime mask: u16) core.host_function.InternalEntry`。
- **作用**：造八个布尔 flag getter（`global` / `ignoreCase` / `multiline` / `dotAll` / `unicode` / `sticky` / `hasIndices` / `unicodeSets`）。
- **实现**：`.length = 0`、`.cproto = .getter_magic`、`.native_function = .{ .getter_magic = &regexpFlagAccessorCall }`，关键是 `.magic = mask`——**magic 携带的是编译后 regexp 的 flag 位掩码**，而 `.id` 仍是安装用的 `AccessorMethod` 值，与 QuickJS 的 magic getter 完全同形。
- **所有权 / 错误 / 调用**：comptime 求值。

### `regexpConstructorEntry` (`src/exec/regexp_ops.zig:207`)

- **签名**：`fn regexpConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：造 `RegExp` 构造器记录（既能 `new` 也能当函数调）。
- **实现**：`.magic = @intCast(id)`、`.cproto = .constructor_or_func_magic`、`.native_function = builtin_dispatch.constructorOrFunctionMagic(&regexpCall)`，于是 `new RegExp(...)` 与 `RegExp(...)` 都进 `regexpCall`，由它按 `is_constructor` 分岔。表里只有一条（`"RegExp"`，length 2）。
- **所有权 / 错误 / 调用**：comptime 求值。

### `regexpCall` (`src/exec/regexp_ops.zig:226`)

- **签名**：`fn regexpCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.regexp` domain 的共享记录处理函数：构造器、原型方法与 legacy 静态访问器的总分派。
- **实现**：`nativeCall` 恢复 `NativeCall`（失败 → `error.TypeError`）；有 `func_obj` 时 global 取自 `callableRealm`（断言 `realm.realm == ctx`），否则用 `host_call.global`。① 构造器 id：这一支**放在 `func_obj` 检查之前**，因为 VM 的构造快路径（`regexp_fastpath.regExpConstructCall`）会在没有构造器对象的情况下把强制转换后的终态送进来。`host_call.is_constructor` 为真时，global 为空 → TypeError，`pattern` / `flags` 缺省补空字符串，转 `constructWithPrototypeInRealm(rt, active_global, pattern, flags, host_call.new_target)`；否则（当函数调）转 `regexp_fastpath.regExpFunctionCall`，由它实现「参数已经是 RegExp 且没给 flags 就原样返回」的语义。② 其余分支都要求有 `func_obj`（没有 → TypeError）。`StaticMethod.escape` → 本模块的 `escape(ctx.runtime, args)`。`legacyAccessorMethodFromId` 命中 → `regexp_fastpath.regExpLegacyAccessor`。③ 其余走 `decodePrototypeMethodId`（映不到 → TypeError）：9 = `compile` → `regexp_fastpath.regExpCompile`（null 折 TypeError）；1 = `string_ops.regExpToString`；2 = `regexp_fastpath.regExpTestMethod`；3 = `regexp_fastpath.regExpExecMethod`；4..8 依次是 `string_ops` 的 `regExpSymbolSearch` / `regExpSymbolMatch` / `regExpSymbolMatchAll` / `regExpSymbolReplace` / `regExpSymbolSplit`，返回 null 一律折成 TypeError。
- **所有权 / 错误 / 调用**：返回值归调用方；exec 侧的 RegExp opcode 处理与匹配快路径也直接调用那些 `regexp_fastpath` / `string_ops` 实现，所以它们留在 exec。

### `regexpFlagsAccessorCall` (`src/exec/regexp_ops.zig:294`)

- **签名**：`fn regexpFlagsAccessorCall( native_ctx: *core.JSContext, native_this: core.JSValue, ) HostError!core.JSValue`。
- **作用**：`RegExp.prototype.flags` 的 getter。
- **实现**：`nativeCall`（实参空切片、magic 0）失败 → TypeError；取 `callableRealm` 的 global 并断言；receiver 不是对象 → `throwTypeErrorMessage(..., "not an object")`。然后照 `js_regexp_get_flags`（quickjs.c:47943）做**泛型 receiver**：按规范顺序用普通 `[[Get]]`（`object_ops.getValueProperty`，带 caller function / frame）依次读 `hasIndices`、`global`、`ignoreCase`、`multiline`、`dotAll`、`unicode`、`unicodeSets`、`sticky` 八个属性，`coercion_ops.valueTruthy` 为真就把对应字母 `d g i m s u v y` 写进栈上定长数组，最后 `createStringValue` 造结果——因此用户覆写这些属性是可观察的。
- **所有权 / 错误 / 调用**：结果字符串归调用方；不读内部 flag 位。

### `regexpSourceAccessorCall` (`src/exec/regexp_ops.zig:337`)

- **签名**：`fn regexpSourceAccessorCall( native_ctx: *core.JSContext, native_this: core.JSValue, ) HostError!core.JSValue`。
- **作用**：`RegExp.prototype.source` 的 getter。
- **实现**：`nativeCall` + `callableRealm`（断言 realm 与 ctx 一致）；必须有 `func_obj`；receiver 不是对象 → `"not an object"` TypeError。receiver 是 `regexp` class 且 `regexpFlagBits` 能拿到编译结果（即真有 bytecode）时，走本模块的 `accessor(rt, this, "source")` 取转义后的 source。否则若 receiver 恰好是 realm 的 `RegExp.prototype` 本身，返回字符串 `"(?:)"`。都不是就 `array_ops.throwRegExpAccessorTypeError`（带 getter 函数自身的值）后返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：`regExpPrototypeFromGlobal` 返回的 `OwnedPrototype` 在函数内 defer 释放。

### `regexpFlagAccessorCall` (`src/exec/regexp_ops.zig:365`)

- **签名**：`fn regexpFlagAccessorCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：八个布尔 flag getter 共享的实现，`magic` 就是要测的 flag 掩码。
- **实现**：`nativeCall`（带 `native_magic`）+ `callableRealm` + 断言；必须有 `func_obj`；receiver 不是对象 → `"not an object"` TypeError。receiver 是 `regexp` class 且能取到 flag 位时，返回 `(bits & mask) != 0` 的布尔（`mask` 由 `native_magic` 截取而来）。否则 receiver 正好是 realm 的 `RegExp.prototype` 时返回 `undefined`（规范要求原型上的 flag getter 给 undefined 而不是抛错）。再不然 `throwRegExpAccessorTypeError` 后 `error.TypeError`。
- **所有权 / 错误 / 调用**：`OwnedPrototype` defer 释放。

### `regexpExecCall` (`src/exec/regexp_ops.zig:394`)

- **签名**：`fn regexpExecCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`RegExp.prototype.exec` 的专用记录处理函数（不经共享 magic switch）。
- **实现**：`nativeCall`（magic 传 0）失败 → TypeError；`callableRealm` 取 global 并断言；转发 `regexp_fastpath.regExpExecMethod(ctx, output, global, this, args, caller_function, caller_frame)` 并直接返回。
- **所有权 / 错误 / 调用**：本层不分配、不建根：`native_this`/`native_args` 借用调用帧，返回的匹配数组由 `regExpExecMethod` 在 GC 堆上建好并留在 managed 帧里。`HostError` 即 `core.errors.RuntimeError`：`nativeCall` 恢复失败直接 `error.TypeError`（由边界 materialize 成 JS TypeError），被转发实现抛的异常以 `error.JSException` + 已挂 pending exception 的形式透传。不被直接调用，只经 `regexpGenericEntry("exec", 1, …, &regexpExecCall)` 登记为 NativeEntry（`src/exec/regexp_ops.zig:115`）。

### `regexpSymbolMatchCall` (`src/exec/regexp_ops.zig:414`)

- **签名**：`fn regexpSymbolMatchCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.match]` 的专用记录处理函数。
- **实现**：`nativeCall` + `callableRealm` + 断言后转 `string_ops.regExpSymbolMatch`，返回 null 折成 `error.TypeError`。
- **所有权 / 错误 / 调用**：返回值归调用方；同一个 `string_ops` 实现也支撑 `String.prototype.match`。

### `regexpSymbolSplitCall` (`src/exec/regexp_ops.zig:434`)

- **签名**：`fn regexpSymbolSplitCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.split]` 的专用记录处理函数。
- **实现**：`nativeCall` + `callableRealm` + 断言后转 `string_ops.regExpSymbolSplit`，返回 null 折成 `error.TypeError`。
- **所有权 / 错误 / 调用**：返回值归调用方；同一实现也支撑 `String.prototype.split`。

### `constructWithPrototype` (`src/exec/regexp_ops.zig:454`)

- **签名**：`pub fn constructWithPrototype(rt: *core.JSRuntime, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：指定实例原型的构造入口（不带 realm global）。
- **实现**：转发 `constructWithPrototypeInRealm(rt, null, pattern, flags, prototype)`；`realm_global` 为 null 意味着拿不到 realm 的 regexp shape，也无法为编译错误建具名异常。
- **所有权 / 错误 / 调用**：返回值归调用方；生产侧没有调用方（同名的零参 `construct` 壳已删），仅 `src/tests/exec.zig` 四处在用（`regexp_fastpath` 刻意**不**直接用它，构造走记录表 `builtin_dispatch.callConstructRecord*`，见 `regexp_fastpath.zig:20-30` 的注释）。

### `constructWithPrototypeInRealm` (`src/exec/regexp_ops.zig:458`)

- **签名**：`fn constructWithPrototypeInRealm(rt: *core.JSRuntime, realm_global: ?*core.Object, pattern: core.JSValue, flags: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：RegExp 构造的总实现：解析 source/flags、编译、建对象。
- **实现**：短路分支——`flags` 是 `undefined` 且 `pattern` 已经是 RegExp 对象时，直接复用它的内部 source 与已编译 bytecode（bytecode 为空 → `error.TypeError`），走 `constructCompiled` 不重新编译。否则把 `source_val` / `flags_val` 两个局部用 `rootValues` 钉住：source 取自 pattern（是 RegExp 取内部 source、是 `undefined` 取空串、其余 `regExpStringValue` 转字符串）；flags 在 `undefined` 且 pattern 是 RegExp 时取 pattern 的内部 flags 字符串、`undefined` 且不是 RegExp 时取空串、否则 `regExpStringValue`。然后 `compileSourceAndFlags`（defer 释放编译产物），最后 `constructCompiled`。
- **所有权 / 错误 / 调用**：编译缓冲在函数内释放（bytecode 由 `constructCompiled` 复制进对象）；根帧 defer 撤销。

### `regExpStringValue` (`src/exec/regexp_ops.zig:495`)

- **签名**：`fn regExpStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：把 pattern / flags 参数转成字符串值（裸运行时 ToString）。
- **实现**：已经是字符串就原样返回；否则开临时 `ArrayList(u8)`（defer 释放），`appendValueString` 写入后 `createStringValue`。
- **所有权 / 错误 / 调用**：本文件的 `appendValueString` 带 `.unsupported = .type_error`，所以不能字符串化的值（如 Symbol）会变成 `error.TypeError`。


### `regexpCompileOptions` (`src/exec/regexp_ops.zig:509`)

- **签名**：`fn regexpCompileOptions(rt: *core.JSRuntime) regexp_lib.CompileOptions`。
- **作用**：组装本文件编译路径要用的 `CompileOptions`。
- **实现**：`.{ .@"opaque" = rt, .check_stack_overflow = lreCheckStackOverflow }`。
- **所有权 / 错误 / 调用**：只被 `compileSourceAndFlags` 使用。

### `throwRegExpStackOverflow` (`src/exec/regexp_ops.zig:516`)

- **签名**：`fn throwRegExpStackOverflow(rt: *core.JSRuntime, global: ?*core.Object) !void`。
- **作用**：把 regexp 编译时的栈溢出报成 `SyntaxError("stack overflow")`。
- **实现**：有 `global` 时用 `rt.contextForGlobal`（退而求其次 `contextForGlobalIncludingConstructing`）找 ctx 并 `exception_ops.throwSyntaxErrorMessage`；没有 global 时退到 `rt.context_head` 及其 global。无论有没有成功挂上异常，最后都 `return error.SyntaxError`。源码注明**不能**复用 `error.StackOverflow`——那个会物化成 InternalError，而 qjs 这里是 `JS_ThrowSyntaxError(ctx, "%s", ...)` 配 `re_parse_error(s, "stack overflow")`（quickjs.c:47633-47635）。
- **所有权 / 错误 / 调用**：被 `compileSourceAndFlags` 的 flag 解析与 pattern 编译两处捕获点调用。

### `compileSourceAndFlags` (`src/exec/regexp_ops.zig:532`)

- **签名**：`fn compileSourceAndFlags(rt: *core.JSRuntime, global: ?*core.Object, source: core.JSValue, flags: core.JSValue) !regexp_lib.Compiled`。
- **作用**：按 QuickJS `js_compile_regexp` 的顺序把 source + flags 编译成 regexp bytecode。
- **实现**：先用 `core.JSValue.String.Utf8.fromValue` 取 flags 的 UTF-8 视图（ASCII 字符串借用内联字节，只有需要转码的才分配临时缓冲，与 `JS_ToCStringLen2` 的借用/拥有契约一致），`regexp_lib.parseFlagBits` 解析；**flags 先于 source 转换**，保持 qjs 的异常与分配顺序。`InvalidPattern` / `Unsupported` 一律转成 `error.SyntaxError`，`StackOverflow` 先 `throwRegExpStackOverflow` 再返回 `error.SyntaxError`。随后按 `cesu8 = (flag_bits & (unicode | unicode_sets)) == 0` 取 source 的 UTF-8 视图（`fromValueCesu8`）——非 Unicode 模式保持 UTF-16 码元表示，不提前合并代理对。最后 `regexp_lib.compilePatternWithFlagBitsAndOptions` 编译，错误映射与上面相同。
- **所有权 / 错误 / 调用**：两个 `Utf8` 视图都 defer `deinit`；返回的 `Compiled` 归调用方释放。

### `createRegExpObject` (`src/exec/regexp_ops.zig:567`)

- **签名**：`fn createRegExpObject(rt: *core.JSRuntime, realm_global: ?*core.Object, prototype: ?*core.Object) !*core.Object`。
- **作用**：建 RegExp 实例对象（尽量命中 realm 的预建 shape）。
- **实现**：有 realm global 且能找到 ctx、且 `ctx.regexp_shape` 的 `proto` 正好等于要求的 prototype 时，走 `core.Object.createRegExpFromShape` 直接复用内建 shape。否则（自定义 / null 原型，QJS 里也是 `js_create_from_ctor` 之后再定义 `lastIndex`）用 `createWithOwnPropertyCapacity(..., core.class.ids.regexp, prototype, 1)` 预留一个属性槽（errdefer 销毁），再 `initializeRegExpLastIndex`，让普通的 shape 转换缓存去建对应 shape。
- **所有权 / 错误 / 调用**：失败路径由 errdefer 销毁半成品；返回对象归调用方。

### `constructCompiled` (`src/exec/regexp_ops.zig:585`)

- **签名**：`fn constructCompiled(rt: *core.JSRuntime, realm_global: ?*core.Object, source: core.JSValue, bytecode: []const u8, prototype: ?*core.Object) !core.JSValue`。
- **作用**：把 source 与已编译 bytecode 装进一个新 RegExp 对象。
- **实现**：先把 `source_val` 用 `rootValues` 钉住（建对象会分配、可能触发 GC），`createRegExpObject` 建实例（errdefer 销毁），再 `setRegexpSource` 与 `setRegexpCompiledBytecode`，返回对象值。
- **所有权 / 错误 / 调用**：`setRegexpCompiledBytecode` 把 bytecode 存进对象，调用方仍负责释放自己那份 `Compiled`；根帧 defer 撤销。

### `regexpObjectFromValue` (`src/exec/regexp_ops.zig:625`)

- **签名**：`fn regexpObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：把值当 RegExp 实例取对象指针。
- **实现**：先 `refHeader()`，再要求 `value.is(.object)`，最后 class 必须是 `regexp`，任一不满足返回 null。
- **所有权 / 错误 / 调用**：借用指针；构造路径与测试用它。

### `accessor` (`src/exec/regexp_ops.zig:632`)

- **签名**：`pub fn accessor(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8) !core.JSValue`。
- **作用**：按名字读 RegExp 实例的内部访问器（primitive-only 回退）。
- **实现**：`expectRegExpObject` 校验 receiver。`"source"` → 取内部 source 后 `escapedSource`。其余先 `regexpFlagBits`（没有编译结果 → `error.TypeError`）：`"flags"` → `canonicalFlagsValue`；其它名字经 `regexpFlagBit` 查掩码，命中就返回 `(bits & bit) != 0`，查不到名字则返回 `false`（不报错）。
- **所有权 / 错误 / 调用**：返回值归调用方；调用方有 `regexpSourceAccessorCall` 的 fast 分支与 `src/tests/exec.zig`。

### `escapedSource` (`src/exec/regexp_ops.zig:648`)

- **签名**：`fn escapedSource(rt: *core.JSRuntime, source: core.JSValue) !core.JSValue`。
- **作用**：把内部 source 变成 `RegExp.prototype.source` 该返回的、可直接放进 `/.../` 里的字符串。
- **实现**：`regexpSourceCanReturnRaw` 为真时原样返回原字符串（零拷贝快路径）。否则 `appendValueString` 摊成字节；空串返回 `"(?:)"`。再逐字节重写：`\` 连同它转义的下一个字节整体保留；`[` 置 `in_class = true`、`]` 置 false（都原样写）；`/` 在字符类**外**时前面补一个 `\`；换行与回车写成两字符序列（Zig 字面量 `"\\n"` / `"\\r"`，即反斜杠加 `n` / `r`）；其余原样。最后 `createStringValue`。
- **所有权 / 错误 / 调用**：两个临时缓冲 defer 释放；只被 `accessor` 的 `"source"` 分支调用。

### `regexpSourceCanReturnRaw` (`src/exec/regexp_ops.zig:690`)

- **签名**：`fn regexpSourceCanReturnRaw(source: core.JSValue) bool`。
- **作用**：判断 source 能不能跳过转义直接返回。
- **实现**：不是字符串体、或长度为 0 → false（空串要变成 `"(?:)"`）。否则扫码元并维护 `in_class`：`[` 进字符类、`]` 出字符类；在字符类外遇到 `/` → false；遇到 ECMA 行终止符（`unicode.isEcmaLineTerminatorUnit`）→ false；全程没触发就 true。注意它不检查反斜杠。
- **所有权 / 错误 / 调用**：纯谓词。

### `escape` (`src/exec/regexp_ops.zig:707`)

- **签名**：`pub fn escape(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`RegExp.escape(str)` 静态方法。
- **实现**：实参缺失或第一个不是字符串 → `error.TypeError`（规范要求不做 ToString）。按 `resolveData()` 分宽度：`.latin1` 逐字节 `appendEscapedCodeUnit`，`is_first` 只对下标 0 为真；`.utf16` 手动走码元——高代理后跟低代理时合成码点用 `unicode.appendUtf8CodePoint` 原样写出并跳 2，落单的高/低代理写成 `\uXXXX`，其余码元走 `appendEscapedCodeUnit`。最后 `String.createUtf8`。
- **所有权 / 错误 / 调用**：缓冲 defer 释放；结果字符串归调用方；调用方是 `regexpCall` 的 `StaticMethod.escape` 臂。

### `toString` (`src/exec/regexp_ops.zig:744`)

- **签名**：`fn toString(rt: *core.JSRuntime, object: *core.Object) !core.JSValue`。
- **作用**：不带 realm 的 `RegExp.prototype.toString` 实现。
- **实现**：取内部 source 与 flag 位；往缓冲里写 `'/'`、`appendValueString(source)`（注意写的是**原始** source，不走 `escapedSource`）、`'/'`、再 `appendCanonicalRegExpFlags` 追加规范顺序的 flag 字母；最后 `String.createUtf8`。
- **所有权 / 错误 / 调用**：缓冲 defer 释放；只被本文件的 `methodCall` 调用（记录路径上的 `toString` 走 `string_ops.regExpToString`）。

### `canonicalFlagsValue` (`src/exec/regexp_ops.zig:759`)

- **签名**：`fn canonicalFlagsValue(rt: *core.JSRuntime, flag_bits: u16) !core.JSValue`。
- **作用**：把 flag 位图变成 flags 字符串值。
- **实现**：开临时缓冲（defer 释放），`appendCanonicalRegExpFlags` 写入后 `createStringValue`（空 flags 会命中 `createStringValue` 的规范空串 atom）。
- **所有权 / 错误 / 调用**：只被 `accessor` 的 `"flags"` 分支调用。

### `appendCanonicalRegExpFlags` (`src/exec/regexp_ops.zig:766`)

- **签名**：`fn appendCanonicalRegExpFlags(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), flag_bits: u16) !void`。
- **作用**：把 flag 位图按规范顺序写进缓冲。
- **实现**：转发 `regexp_adapter.appendCanonicalFlagsFromBits(rt.memory.allocator, buffer, flag_bits)`（顺序 `d g i m s u v y`，`v` 存在时不输出 `u`）。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `expectRegExpObject` (`src/exec/regexp_ops.zig:770`)

- **签名**：`fn expectRegExpObject(value: core.JSValue) !*core.Object`。
- **作用**：要求值是 RegExp 实例，否则抛 TypeError。
- **实现**：`refHeader()` 取不到 → `error.TypeError`；不是对象 → `error.TypeError`；class 不是 `regexp` → `error.TypeError`；否则返回对象指针。与 `regexpObjectFromValue` 的区别只在于失败是抛错还是返回 null。
- **所有权 / 错误 / 调用**：借用指针。

### `expectString` (`src/exec/regexp_ops.zig:778`)

- **签名**：`fn expectString(value: core.JSValue) !*core.string.String`。
- **作用**：要求值是字符串并取字符串体。
- **实现**：`value.asStringBody() orelse return error.TypeError`。
- **所有权 / 错误 / 调用**：借用指针；只被 `escape` 使用。

### `getInternalSource` (`src/exec/regexp_ops.zig:786`)

- **签名**：`fn getInternalSource(object: *core.Object) !core.JSValue`。
- **作用**：读 RegExp 实例的内部 `[[OriginalSource]]` 槽。
- **实现**：`object.regexpSource()` 为 null 时 `error.TypeError`，否则返回该值。
- **所有权 / 错误 / 调用**：返回的是对象里存着的值，不新分配。

### `getInternalFlags` (`src/exec/regexp_ops.zig:790`)

- **签名**：`fn getInternalFlags(rt: *core.JSRuntime, object: *core.Object) !core.JSValue`。
- **作用**：把实例的内部 flag 位还原成 flags 字符串。
- **实现**：`regexp_adapter.flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode())`——直接从已编译 bytecode 取位图再格式化。
- **所有权 / 错误 / 调用**：新建的字符串归调用方；`constructWithPrototypeInRealm` 在「pattern 是 RegExp 而 flags 是 undefined」时用它。

### `regexpFlagBits` (`src/exec/regexp_ops.zig:794`)

- **签名**：`fn regexpFlagBits(object: *core.Object) !u16`。
- **作用**：取实例的 flag 位图，顺带当「有没有编译结果」的检查。
- **实现**：拿 `object.regexpCompiledBytecode()`，长度为 0（未初始化的 RegExp 对象，例如 `RegExp.prototype` 本身）→ `error.TypeError`；否则 `regexp_adapter.flagBitsFromBytecode`。
- **所有权 / 错误 / 调用**：访问器分支用 `catch null` 把这个错误当「不是有效实例」的信号。

### `regexpFlagBit` (`src/exec/regexp_ops.zig:800`)

- **签名**：`fn regexpFlagBit(name: []const u8) ?u16`。
- **作用**：按 JS 属性名查对应的 flag 位掩码。
- **实现**：一串 `std.mem.eql`：`global` / `ignoreCase` / `multiline` / `dotAll` / `unicode` / `sticky` / `hasIndices`（对应 `flag_bits.indices`）/ `unicodeSets`，其余返回 null。
- **所有权 / 错误 / 调用**：只被 `accessor` 使用。

### `appendEscapedCodeUnit` (`src/exec/regexp_ops.zig:812`)

- **签名**：`fn appendEscapedCodeUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16, is_first: bool) !void`。
- **作用**：`RegExp.escape` 的逐码元规则。
- **实现**：ASCII（≤ 0x7f）时依次判：首字符且是字母数字 → `\xNN`（防止转义结果被当成标识符的一部分）；`syntaxEscapeChar` 命中（`^` `$` `\` `.` `*` `+` `?` `(` `)` `[` `]` `{` `}` `|` `/`）→ 反斜杠加原字符；`controlEscapeChar` 命中（tab/换行/0x0b/换页/回车）→ 反斜杠加 `t n v f r`；空格或 `otherPunctuator`（`,` `-` `=` `<` `>` `#` `&` `!` `%` `:` `;` `@` `~`、单引号、反引号与双引号）→ `\xNN`；其余原样写一个字节。非 ASCII 时，`isEscapedWhitespaceOrLineTerminator` 命中就按宽度写 `\xNN`（≤ 0xff）或 `\uXXXX`；否则把码元当码点 `appendUtf8CodePoint` 原样写出。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `appendHexEscape` (`src/exec/regexp_ops.zig:838`)

- **签名**：`fn appendHexEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void`。
- **作用**：写一个 `\xNN` 转义。
- **实现**：先 `appendSlice("\\x")`，再 `appendHexByte` 写两位小写十六进制。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `appendUnicodeEscape` (`src/exec/regexp_ops.zig:843`)

- **签名**：`fn appendUnicodeEscape(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: u16) !void`。
- **作用**：写一个 `\uXXXX` 转义。
- **实现**：`appendSlice("\\u")` 后分两次 `appendHexByte`（先高字节再低字节），共四位小写十六进制。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `appendHexByte` (`src/exec/regexp_ops.zig:849`)

- **签名**：`fn appendHexByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void`。
- **作用**：把一个字节写成两位**小写**十六进制。
- **实现**：两次 `buffer.append`，字符由 `unicode.asciiLowerHexDigitChar` 生成（与 `uri_ops` 的大写版本相反）。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `syntaxEscapeChar` (`src/exec/regexp_ops.zig:854`)

- **签名**：`fn syntaxEscapeChar(byte: u8) bool`。
- **作用**：判断字符是不是要用反斜杠转义的正则语法字符。
- **实现**：`switch`：`^` `$` `\` `.` `*` `+` `?` `(` `)` `[` `]` `{` `}` `|` `/` 返回 true，其余 false。
- **所有权 / 错误 / 调用**：只被 `appendEscapedCodeUnit` 使用。

### `controlEscapeChar` (`src/exec/regexp_ops.zig:861`)

- **签名**：`fn controlEscapeChar(byte: u8) ?u8`。
- **作用**：把控制字符映到它的单字母转义。
- **实现**：`\t`→`t`、`\n`→`n`、`0x0b`→`v`、`\x0c`→`f`、`\r`→`r`，其余 null。
- **所有权 / 错误 / 调用**：只被 `appendEscapedCodeUnit` 使用。

### `otherPunctuator` (`src/exec/regexp_ops.zig:872`)

- **签名**：`fn otherPunctuator(byte: u8) bool`。
- **作用**：规范里要求 `RegExp.escape` 用 `\xNN` 处理的其它标点集合。
- **实现**：`switch`：`,` `-` `=` `<` `>` `#` `&` `!` `%` `:` `;` `@` `~`、单引号、反引号与双引号 返回 true，其余 false。
- **所有权 / 错误 / 调用**：只被 `appendEscapedCodeUnit` 使用。

### `isEscapedWhitespaceOrLineTerminator` (`src/exec/regexp_ops.zig:879`)

- **签名**：`fn isEscapedWhitespaceOrLineTerminator(unit: u16) bool`。
- **作用**：判断非 ASCII 码元是不是要转义的空白 / 行终止符（如 U+00A0、U+2028、U+FEFF）。
- **实现**：`unit > 0x7f` **且** `unicode.isEcmaWhitespaceOrLineTerminatorUnit(unit)`——ASCII 段由前面的控制字符分支处理，这里只管高位。
- **所有权 / 错误 / 调用**：只被 `appendEscapedCodeUnit` 使用。

### `surrogateCodePoint` (`src/exec/regexp_ops.zig:883`)

- **签名**：`fn surrogateCodePoint(high: u16, low: u16) u32`。
- **作用**：把代理对合成码点。
- **实现**：`@intCast(unicode.codePointFromSurrogatePair(high, low))`。
- **所有权 / 错误 / 调用**：只被 `escape` 的 utf16 分支使用。

### `appendValueString` (`src/exec/regexp_ops.zig:888`)

- **签名**：`fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void`。
- **作用**：本文件对裸运行时 ToString 的统一策略入口。
- **实现**：转发 `core.value_string.appendValueString(rt, buffer, value, .{ .unsupported = .type_error })`——与 `uri_ops` 里同名函数的区别就在这个选项：无法字符串化的值报 `error.TypeError` 而不是走默认处理。
- **所有权 / 错误 / 调用**：缓冲归调用方；`regExpStringValue` / `escapedSource` / `toString` 都经它。

## `src/exec/regexp_ops.zig` — RegExp 可观察 exec/test/construct

`regExpConstructCall` 先 preflight + NativeBacktraceScope，再在同一 native 帧里做可观察强制转换。exec 默认 `exec` 方法仍是内建时走编译字节码；`test` 在 lastIndex 可跳过 coerce 且非 global/sticky 时 `regExpTestFastNoResult`。Annex B 遗留 `$1`/`input` 等走 `regExpLegacyAccessor`。


### `constructRegExpRecordInNativeScope` (`src/exec/regexp_ops.zig:32`)

- **签名**：`fn constructRegExpRecordInNativeScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: ?*core.Object, prototype: ?*core.Object, pattern: core.JSValue, flags: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：本文件所有构造路径的共同终点：用已强制转换好的 (pattern, flags) 跑记录表里的 RegExp 构造器体。
- **实现**：把两个值装成 `args` 数组，调 `builtin_dispatch.callConstructRecordInNativeScope(..., regexp_construct_ref, prototype, &args, ...)`，返回 null 折成 `error.TypeError`。用文件顶部固定的 `regexp_construct_ref`（domain `.regexp` + `ConstructorMethod.construct`）而不是直接 import `regexp_ops.constructWithPrototype`，好让构造逻辑的所有权留在记录表里。
- **所有权 / 错误 / 调用**：结果对象归调用方；被 `regExpFunctionCall` 与 `regExpConstructCallInNativeScope` 使用。

### `regExpFunctionCall` (`src/exec/regexp_ops.zig:82`)

- **签名**：`pub fn regExpFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`RegExp(...)` 当**普通函数**调用时的实现。
- **实现**：先做「原样返回」判定：`isRegExpObservable(pattern)`（读 `Symbol.match`）为真且没给 flags 时，读 pattern 的 `constructor` 属性，若与 global 上的 `RegExp` 是同一对象就直接返回原 pattern。否则开始强制转换：缺省 pattern 用空串；pattern 是「可观察 RegExp」但 class 不是 `regexp`（用户伪造的 RegExp-like）时读它的 `source` 属性；pattern 是非 regexp 对象时 `toStringForAnnexB`；既不是 RegExp、也不是字符串 / undefined 的原始值同样 `toStringForAnnexB`——镜像 `js_regexp_constructor`（quickjs.c:47786-47793）走 `JS_ToString`，所以 Symbol 抛 TypeError 而不是漏出 `[object Object]`。flags 同理：显式给了就用；没给且 pattern 是非原生 RegExp-like 时读它的 `flags` 属性；再不然空串；最后非字符串的 flags 也过一次 `toStringForAnnexB`（对应 `js_compile_regexp` quickjs.c:47577-47578 的 `JS_ToCStringLen`，Symbol 抛 TypeError）。终点是 `constructRegExpRecordInNativeScope`，原型固定取 `ctx.classPrototypeObject(regexp)`（函数调用形态没有 new.target）。
- **所有权 / 错误 / 调用**：中途新建的字符串记录在 `owned_*` 局部里；调用方是 `regexp_ops.regexpCall` 的非构造分支与 VM 的调用快路径。

### `regExpConstructCall` (`src/exec/regexp_ops.zig:159`)

- **签名**：`pub fn regExpConstructCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: ?*core.Object, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new RegExp(...)` 的 VM 快路径入口：负责 native 帧与错误物化。
- **实现**：`builtin_dispatch.preflightInternalRecordCFunction(ctx, global, constructor, regexp_construct_ref)` 先做记录预检；`NativeBacktraceScope.init(ctx, constructor)` 后 `push()` 并 defer `deinit()`，让强制转换期间的回溯里带上这一层 native 帧；然后调 `regExpConstructCallInNativeScope`，捕获到错误时先 `builtin_dispatch.materializeRuntimeError(ctx, global, err)` 再把错误原样上抛。
- **所有权 / 错误 / 调用**：结果归调用方；调用方是 VM 的 construct 分派。

### `regExpConstructCallInNativeScope` (`src/exec/regexp_ops.zig:180`)

- **签名**：`fn regExpConstructCallInNativeScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: ?*core.Object, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new RegExp(...)` 的实际参数解析与构造。
- **实现**：最快的一支：pattern 与 flags **都**已经是字符串或 undefined 时没有任何可观察强制转换，`reflectConstructPrototypeVm(..., "RegExp", new_target, ...)` 解析实例原型后直接把原值送进记录（源码注明这条已经取代了早先借用 Latin1 的快路径，结果对象完全一致）。否则先 `isRegExpObservable`，再按情况取 source：undefined → 空串；可观察 RegExp 且 class 是 `regexp` → `regexpInternalStringValue(..., true)` 读内部 source；可观察但不是原生 regexp → 读 `source` 属性；非 regexp 对象或其它非字符串原始值 → `toStringForAnnexB`（quickjs.c:47786-47793）。flags：显式给了就用；没给且 pattern 是原生 regexp → `regexpInternalStringValue(..., false)`；没给且是 RegExp-like → 读 `flags` 属性；否则 undefined。**顺序要点**：先 `reflectConstructPrototypeVm` 解析 new.target 的原型，**之后**才对非字符串 flags 做 `toStringForAnnexB`——对应 qjs 里 flags 的 ToString 发生在 `js_create_from_ctor` 之后（quickjs.c:47795-47797 + 47577-47578），且 `JS_ToCStringLen` 对 Symbol 抛的是 TypeError 而非 SyntaxError。最后 `constructRegExpRecordInNativeScope`。
- **所有权 / 错误 / 调用**：`OwnedPrototype` defer 释放；中间字符串记在 `owned_*` 局部。

### `regExpExecMethod` (`src/exec/regexp_ops.zig:276`)

- **签名**：`pub fn regExpExecMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：内建 `RegExp.prototype.exec`。
- **实现**：receiver 不是对象、或 class 不是 `regexp` → `throwTypeErrorMessage(..., "RegExp object expected")`；输入实参缺省 `undefined`，非字符串走 `toStringForAnnexB`；然后 `regExpExecResult(..., use_last_index = true, ...)`，返回 null（没有编译好的字节码等）时折成 `error.TypeError`。
- **所有权 / 错误 / 调用**：结果数组或 `null` 值归调用方；调用方有 `regexp_ops` 的 `exec` 记录（`regexp_ops.zig:289,408`）、本文件的 `regExpExecGeneric`（:550）与 VM 的 exec 快路径 `call_runtime.zig:1340`（`regExpTestMethod` 不经它，直接调 `regExpExecResult`）。

### `regExpTestMethod` (`src/exec/regexp_ops.zig:301`)

- **签名**：`pub fn regExpTestMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：内建 `RegExp.prototype.test`。
- **实现**：receiver 必须是对象（否则 `"RegExp object expected"`，注意这里**不**再要求 class 是 regexp）；输入非字符串走 `toStringForAnnexB`。随后按 receiver 的 `exec` 是否仍是默认内建（`regExpPrototypeMethodIsDefault`，比对 `PrototypeMethod.exec` 记录）分两路：是默认时先试 `regExpTestFastNoResult`（不物化结果数组），给出结果就直接返回布尔；否则退到 `regExpExecResult`（null 视为 `false`），结果非 null 即为 true。`exec` 被覆写时走 `regExpExecGeneric` 调用户的 `exec`，再看结果是不是 null。
- **所有权 / 错误 / 调用**：返回 `?core.JSValue`；`regexp_ops` 的 `test` 记录把 null 折成 TypeError。

### `regExpTestFastNoResult` (`src/exec/regexp_ops.zig:333`)

- **签名**：`pub fn regExpTestFastNoResult( ctx: *core.JSContext, regexp_object: *core.Object, string_value: core.JSValue, ) !?bool`。
- **作用**：`test` 的「只要布尔、不建结果数组」快路径。
- **实现**：三道准入——`regExpLastIndexCanSkipCoercion` 为假（lastIndex 是对象/BigInt/Symbol，读它可能可观察）返回 null；没有已编译 bytecode 返回 null；flag 里带 `global` 或 `sticky`（需要读写 lastIndex）也返回 null。都过了就 `regexp_adapter.testOnStringFromIndex(..., start = 0)`，把 `BytecodeCorrupt` / `Timeout` 吞成 null（让调用方走慢路径），其余错误上抛。
- **所有权 / 错误 / 调用**：不分配；null 表示「快路径不适用」。

### `regExpLastIndexCanSkipCoercion` (`src/exec/regexp_ops.zig:354`)

- **签名**：`pub fn regExpLastIndexCanSkipCoercion(object: *core.Object) bool`。
- **作用**：判断 `lastIndex` 能不能不做可观察的转换就跳过。
- **实现**：取不到内部 `lastIndex` 槽 → false；值是对象、BigInt 或 Symbol（ToLength 会跑用户代码或抛错）→ false；其余为 true。
- **所有权 / 错误 / 调用**：纯谓词。

### `regExpCompile` (`src/exec/regexp_ops.zig:360`)

- **签名**：`pub fn regExpCompile( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：Annex B 的 `RegExp.prototype.compile`：就地替换 receiver 的模式与 flags。
- **实现**：receiver 不是对象或 class 不是 `regexp` → 返回 null（交回上层）；receiver 的原型必须正好是 realm 的 `RegExp.prototype`，否则 `"RegExp object expected"` TypeError。① flags 是 undefined 且 pattern 是原生 regexp 时，直接复制它的内部 source 与已编译 bytecode（bytecode 为空 → TypeError），再把 `lastIndex` 置 0 并返回 this。② 否则分别算 source 与 flags：pattern 是原生 regexp 时，**给了 flags 就 `error.TypeError`**（规范禁止 `re.compile(otherRegExp, "g")`），source/flags 都取内部值；pattern 是 undefined 取空串、其它值 `toStringForAnnexB`；flags 是 undefined 取空串、否则 `toStringForAnnexB`。然后把两者 `appendValueString` 摊成字节，`regexp_adapter.compileWithRuntime` 编译：`InvalidPattern` / `Unsupported` → `error.SyntaxError`，`StackOverflow` → 先抛 `SyntaxError("stack overflow")` 再返回 `error.SyntaxError`。成功后 `setRegexpCompiledBytecode` + `setRegexpSource`，`lastIndex` 置 0（走 `setValuePropertyStrict`，可观察），返回 this。
- **所有权 / 错误 / 调用**：两个字节缓冲与 `Compiled` 都 defer 释放；`OwnedPrototype` 也 defer 释放。

### `regExpSpeciesConstructor` (`src/exec/regexp_ops.zig:441`)

- **签名**：`pub fn regExpSpeciesConstructor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`SpeciesConstructor(rx, %RegExp%)`：给 `Symbol.split` / `Symbol.replace` 等挑构造器。
- **实现**：默认值用 `regExpConstructorFromGlobal` 取 **realm 内建** 的 RegExp 构造器（对应 `JS_SpeciesConstructor(ctx, rx, ctx->regexp_ctor)`——不是可被替换的全局绑定）。读 `rx.constructor`：`undefined` → 默认；不是对象 → `error.TypeError`；再读它的 `Symbol.species`：`undefined` 或 `null` → 默认；不是 constructor-like → `error.TypeError`；否则返回 species。
- **所有权 / 错误 / 调用**：返回值归调用方（`regExpConstructorFromGlobal` 的回退查找可能产生最后一个引用）。

### `regExpFlagsAreFullUnicode` (`src/exec/regexp_ops.zig:470`)

- **签名**：`pub fn regExpFlagsAreFullUnicode(rt: *core.JSRuntime, flags_string: core.JSValue) !bool`。
- **作用**：判断一段 flags 字符串是不是 full-unicode 模式。
- **实现**：`stringValueContainsByte(rt, flags_string, 'u')` 或 `'v'` 任一为真即 true——直接在字符串里找字母，不解析成位图。
- **所有权 / 错误 / 调用**：通常不分配——`stringValueContainsByte`（`src/exec/string_ops.zig:1081`）对已是字符串的 flags 就地扫 Latin-1/UTF-16 payload；但非字符串入参会走 `appendRawString` 的兜底，临时 `ArrayList` 在该函数内 `defer deinit`，不外泄。error 也只来自那条兜底路径（OOM / 转换异常）。调用方 `src/exec/string_ops.zig:958,1060,1246,1379`（`@@match`/`@@replace`/`@@split` 的 unicode 判定），经 :91 的别名引入。

### `setRegExpLastIndexZero` (`src/exec/regexp_ops.zig:475`)

- **签名**：`pub fn setRegExpLastIndexZero(rt: *core.JSRuntime, regexp_object: *core.Object) !void`。
- **作用**：把 `lastIndex` 重置为 0（内部写，不走 receiver 链）。
- **实现**：`regexp_object.setProperty(rt, lastIndex, int32(0))`，把 `ReadOnly` / `AccessorWithoutSetter` / `NotExtensible` 三种失败统一折成 `error.TypeError`，其余错误上抛。
- **所有权 / 错误 / 调用**：不分配、不建根：写入的是立即数 `int32(0)`，不产生指针边、无需写屏障。error 映射是这里的实质内容——`ReadOnly`/`AccessorWithoutSetter`/`NotExtensible` 三种定义失败被折成 `error.TypeError`（对应 spec 的 Set(…, true) throw），其余原样上抛。调用方 `src/exec/string_ops.zig:1478,1514,1522`，经 :92 的别名引入。

### `appendNamedCaptureSubstitution` (`src/exec/regexp_ops.zig:482`)

- **签名**：`pub fn appendNamedCaptureSubstitution( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, named_captures: core.JSValue, replacement: []const u16, index: *usize, out: *std.ArrayList(u16), caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：处理替换串里的 `$<name>` 具名捕获引用。
- **实现**：`named_captures` 是 undefined → 直接 false（不是具名替换）。名字从 `index + 2` 开始，找不到 `'>'` 也返回 false。把这段 UTF-16 转成 UTF-8（`appendUtf16UnitsAsUtf8`，缓冲 defer 释放）后 `internAtom`；用 `core.runtime.rootAtoms` 把 atom 钉住——TGC S3 §4 class B：属性读取可能跑用户 accessor，其结果还要 ToString，atom 必须活过这两步。读到的 capture 非 undefined 时 `toStringForAnnexB` 后 `appendStringValueUnits` 写进 `out`（undefined 相当于写空）。最后把 `index.*` 推到 `'>'` 的位置并返回 true。
- **所有权 / 错误 / 调用**：atom 根帧 defer 撤销；输出缓冲归调用方。

### `regExpExecGeneric` (`src/exec/regexp_ops.zig:514`)

- **签名**：`pub fn regExpExecGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, string_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：规范的 `RegExpExec(R, S)`：优先调 receiver 上的 `exec`，否则回落到内建。
- **实现**：读 `rx.exec`。既不是 undefined 也不是 null 时：可调用就 `call_runtime.callValueOrBytecodeSyncInternalOutlined` 以 rx 为 this、字符串为唯一实参调用它，结果必须是 null 或对象（否则 `error.TypeError`）并原样返回（源码注明 receiver / 方法 / 字符串都被这个作用域钉住，所以合格的 bytecode 覆写可以跑在当前 Machine 上）。不可调用时，rx 必须是原生 regexp 对象，否则 `error.TypeError`。`exec` 是 undefined / null，或上面那条原生兜底成立时，走 `regExpExecMethod`。
- **所有权 / 错误 / 调用**：结果归调用方。

### `regExpLegacyAccessor` (`src/exec/regexp_ops.zig:553`)

- **签名**：`pub fn regExpLegacyAccessor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, method: method_ids.regexp.LegacyAccessorMethod, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Annex B 的 RegExp 静态遗留访问器（`RegExp.input` / `$_`、`lastMatch`、`lastParen`、`leftContext`、`rightContext`、`$1`..`$9`）。
- **实现**：realm 取自 getter 函数自己的 `nativeFunctionRealmGlobalPtr()`（拿不到才退回传入的 global），因此跨 realm 取到的是定义它的那个 realm 的状态。receiver 必须**就是**该 realm 的 RegExp 构造器对象，否则 `"RegExp legacy accessor receiver mismatch"` TypeError。`ensureInstalledRealmRegExpLegacyStatics` 取（或建）遗留状态块。随后按 method 分派：`set_input` 先 `materializeRegExpLegacyNoCaptureSlots` 把惰性槽落实，再把实参 `toStringForAnnexB` 后写进 `legacy.input`，返回 undefined；`get_input` 读 `legacy.input`；`get_last_match` / `get_left_context` / `get_right_context` 先试惰性切片 `regExpLegacyNoCaptureSliceValue(.match/.left/.right)`，不行才读已物化的槽；`get_last_paren` 与 `$1`..`$9`（经 `legacyCaptureIndex` 换算下标）先试 `regExpLegacyCaptureSliceValue`，同样以槽值兜底；未知 method → `error.TypeError`。空槽由 `regExpLegacySlotValue` 变成空字符串。
- **所有权 / 错误 / 调用**：新建的切片字符串经 `replaceRegExpLegacySlot` 挂进 realm 状态；调用方是 `regexp_ops.regexpCall` 的 legacy 分支。

### `regExpConstructorFromGlobal` (`src/exec/regexp_ops.zig:594`)

- **签名**：`pub fn regExpConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue`。
- **作用**：取 realm 的 RegExp 构造器值。
- **实现**：优先读 realm 缓存 `global.cachedRealmValue(rt, .regexp_constructor)`，缓存里不是对象 → `error.TypeError`；没有缓存时回落到 global 上的 `RegExp` 属性，同样要求是对象。
- **所有权 / 错误 / 调用**：源码注明返回的是**拥有的**值——回退查找可能产生某个新对象的最后一个引用，所以调用方在使用对象指针期间必须持住这个 JSValue。

### `regExpLegacySlotValue` (`src/exec/regexp_ops.zig:607`)

- **签名**：`pub fn regExpLegacySlotValue(rt: *core.JSRuntime, slot: ?core.JSValue) !core.JSValue`。
- **作用**：读遗留槽，空槽给空字符串。
- **实现**：槽里有值就原样返回，否则 `value_ops.createStringValue(rt, "")`。
- **所有权 / 错误 / 调用**：空串走规范空串 atom，不真分配。

### `materializeRegExpLegacyNoCaptureSlots` (`src/exec/regexp_ops.zig:612`)

- **签名**：`pub fn materializeRegExpLegacyNoCaptureSlots(rt: *core.JSRuntime, owner: *core.Object, legacy: anytype) !void`。
- **作用**：把惰性记录的「上次匹配位置」落实成真正的字符串槽（写 `input` 之前必须先做，否则旧切片会指错串）。
- **实现**：`legacy.lazy_no_capture_match` 为假直接返回；`legacy.input` 为空则清掉惰性标记后返回。否则按 `lazy_match_index` / `lazy_match_len` 切出 `last_match` 写进槽；`lazy_match_index == 0` 时 `left_context` 直接清空，否则切 `[0, index)`；右侧起点取 `min(index + len, lazy_input_len)`，越界就清空 `right_context`，否则切到串尾。接着把 `last_paren` 与 `captures[0..capture_slot_count]` 里还是惰性编码的槽逐个 `regExpLegacyCaptureSliceValue` 物化并写回。最后 `lazy_no_capture_match = false`。
- **所有权 / 错误 / 调用**：新字符串经 `replaceRegExpLegacySlot` 挂进 realm 状态（带写屏障）；`legacy` 用 `anytype` 是为了不在这里 import 那个状态结构的类型。

### `regExpLegacyCaptureSliceValue` (`src/exec/regexp_ops.zig:648`)

- **签名**：`pub fn regExpLegacyCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, slot: ?core.JSValue) ?core.JSValue`。
- **作用**：把一个惰性编码的捕获槽解成真正的子串值。
- **实现**：不在惰性状态、没有 `input`、槽为空、或 `decodeRegExpLegacyCaptureSlice` 解不出 (start, len) 都返回 null；否则 `stringSliceValue` 切子串，**切失败（`catch null`）也返回 null**。
- **所有权 / 错误 / 调用**：返回的新字符串归调用方；null 表示「该走已物化的槽值」。

### `clearRegExpLegacySlot` (`src/exec/regexp_ops.zig:656`)

- **签名**：`pub fn clearRegExpLegacySlot(_: *core.JSRuntime, slot: *?core.JSValue) void`（`rt` 参数未使用）。
- **作用**：清空一个遗留槽。
- **实现**：一句 `slot.* = null`；不需要写屏障，因为只是去掉引用。
- **所有权 / 错误 / 调用**：被 `materializeRegExpLegacyNoCaptureSlots` 的左右上下文分支使用。

### `getRegExpLastIndexLength` (`src/exec/regexp_ops.zig:660`)

- **签名**：`pub fn getRegExpLastIndexLength( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, regexp_value: core.JSValue, regexp_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：读 `lastIndex` 并转成长度索引。
- **实现**：快路径——`regexp_value` 就是 `regexp_object` 本身、内部槽有值、且 `fastToLengthIndex` 能直接转换时，直接返回。否则走可观察的 `getValueProperty(lastIndex)` + `toLengthIndexSlow`（可能触发 getter 与 valueOf）。
- **所有权 / 错误 / 调用**：自身不分配、不建根，返回 Zig `usize`（不是 JSValue，所以结果无需 GC 保护）。慢路径会执行用户可见的 getter 与 `valueOf`，因此可能带出 `error.JSException`（pending exception 已挂）以及 `toLengthIndexSlow` 的 `error.RangeError`/`error.TypeError`；调用方必须把它当作可重入点，重新读回可能被改动的对象状态。树内唯一调用方 `src/exec/regexp_ops.zig:713`。

### `setRegExpLastIndexStrict` (`src/exec/regexp_ops.zig:678`)

- **签名**：`pub fn setRegExpLastIndexStrict( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, regexp_value: core.JSValue, regexp_object: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：按 strict 语义写 `lastIndex`。
- **实现**：快路径——`regexp_value` 与 `regexp_object` 同一对象且内部槽存在时，先查 `regexpLastIndexWritable()`，不可写 → `error.TypeError`，可写就直接写槽。否则走可观察的 `setValuePropertyStrict`。
- **所有权 / 错误 / 调用**：快路径直写 `regexpLastIndexSlot()` 且不打写屏障——这是安全的，因为四个调用方传的 `value` 一律是 `int32`/`float64` 数字（`src/exec/regexp_ops.zig:727,794,810`、`src/exec/string_ops.zig:1538`），不会在对象里种下新的指针边。不可写时返回 `error.TypeError`；慢路径交给 `setValuePropertyStrict`，可能执行用户 setter 并带出 `error.JSException`。自身不分配、不建根。

### `regExpExecResult` (`src/exec/regexp_ops.zig:698`)

- **签名**：`pub fn regExpExecResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, regexp_value: core.JSValue, regexp_object: *core.Object, string_value: core.JSValue, use_last_index: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：内建 exec 的前半段：算起点、处理越界，再交给编译匹配。
- **实现**：`string_value` 拿不到字符串体 → 返回 null（交回慢路径）。`use_last_index` 时先 `getRegExpLastIndexLength` 读起点。没有已编译 bytecode 时同样返回 null。有 bytecode 时从 flag 位取 `is_global` / `is_sticky` / `has_indices`；起点只有在 `use_last_index` 且 global 或 sticky 时才用 lastIndex，否则 0。起点**大于**串长时：global/sticky 情况下把 lastIndex 归 0，然后返回 `null` 值（JS 的 `null`，不是 Zig 的 null）。其余交 `regExpExecCompiledResult`。
- **所有权 / 错误 / 调用**：返回 Zig `null` 表示「本函数管不了」，返回 JS `null` 表示「没匹配上」——两者含义不同。

### `regExpExecCompiledResult` (`src/exec/regexp_ops.zig:737`)

- **签名**：`pub fn regExpExecCompiledResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, regexp_value: core.JSValue, regexp_object: *core.Object, string_value: core.JSValue, string_data: core.string.String.ResolvedData, compiled: regexp_adapter.Compiled, use_last_index: bool, is_global: bool, is_sticky: bool, has_indices: bool, start_index: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：真正跑匹配并物化结果数组。
- **实现**：先把 `regexp_value` 与 `string_value` 用 `rootValues` 钉住——TGC R1-c：借用的 `compiled.bytecode`（后面还要给 `captureNameAt` 读）与 `string_data` 都不是扫描器能映射回 owner 的 GC 指针，只有钉住这两个 JSValue 才能让它们活过 `setRegExpLastIndexStrict`（可能跑 accessor）与 `createRegExpMatchArrayFromValue`（为每个捕获分配子串）。捕获槽按 `compiled.allocCount()` 选：不超过 `small_exec_slots` 用栈数组，否则堆分配（defer 释放）。`execCaptureSlotsOnResolvedStringFromIndex` 跑匹配，`BytecodeCorrupt` / `Timeout` 吞成 null。`.match`：槽 0/1 给出起止（`captureSlotValue` 为 null 时起点按 0、终点按起点），`use_last_index` 且 global/sticky 时把 lastIndex 更新成 `match_end`（超出 i32 范围就用 float64），然后组 `RegExpMatch`（`capture_slots` 取 `[2 .. capture_count*2]`、`capture_count` 是总数减 1、`has_named_captures` 看 `named_groups` 位）交 `createRegExpMatchArrayFromValue`。`.no_match` / `.out_of_range`：global/sticky 时把 lastIndex 归 0，返回 JS `null`。`.not_available`：返回 Zig null。
- **所有权 / 错误 / 调用**：堆捕获槽 defer 释放；结果数组归调用方。

### `isRegExpValue` (`src/exec/regexp_ops.zig:818`)

- **签名**：`pub fn isRegExpValue(value: core.JSValue) bool`。
- **作用**：判断值是不是原生 RegExp 实例（不可观察）。
- **实现**：`property_ops.expectObject` 失败返回 false，否则看 class 是不是 `regexp`。
- **所有权 / 错误 / 调用**：纯谓词。

### `isRegExpObservable` (`src/exec/regexp_ops.zig:823`)

- **签名**：`pub fn isRegExpObservable( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：规范的 IsRegExp：先看 `Symbol.match`，再退到内部 class。
- **实现**：不是对象直接 false；`Symbol.match` atom 取不到时退化成 `isRegExpValue`。读 `value[Symbol.match]`（可观察，可能跑 getter），非 undefined 时按它的真值性返回；是 undefined 才退回 `isRegExpValue`。
- **所有权 / 错误 / 调用**：读属性可能抛错；调用方是本文件两条构造路径（:93、:205）以及 `string_ops.zig`（:432、:981、:2127，经 :77 的别名引入）。

### `regexpLastIndex` (`src/exec/regexp_ops.zig:838`)

- **签名**：`pub fn regexpLastIndex(_: *core.JSRuntime, object: *core.Object) usize`（`rt` 参数未使用）。
- **作用**：不可观察地把内部 `lastIndex` 读成一个 usize。
- **实现**：槽为空返回 0；int32 时负数按 0；float64 时 NaN 或 ≤ 0 按 0、≥ `maxInt(usize)` 截到最大值、其余向下取整；其它类型（对象 / BigInt / Symbol）一律 0。
- **所有权 / 错误 / 调用**：不抛错、不分配——与可观察的 `getRegExpLastIndexLength` 是两回事。

### `createRegExpIndexPair` (`src/exec/regexp_ops.zig:849`)

- **签名**：`pub fn createRegExpIndexPair(rt: *core.JSRuntime, global: *core.Object, start: usize, end: usize) !core.JSValue`。
- **作用**：为 `d` 标志（`hasIndices`）的结果建一个 `[start, end]` 二元数组。
- **实现**：以 realm 的 `Array.prototype` `createArray`（errdefer 销毁），`defineSplitValueElement` 写下标 0 与 1 两个 int32。
- **所有权 / 错误 / 调用**：数组归调用方。

### `appendDecodedRegExpGroupName` (`src/exec/regexp_ops.zig:857`)

- **签名**：`pub fn appendDecodedRegExpGroupName(rt: *core.JSRuntime, out: *std.ArrayList(u8), name: []const u8) !void`。
- **作用**：把 bytecode 里存的捕获组名解转义后写出（组名允许 `\uXXXX` 形式）。
- **实现**：逐字节扫描；遇到 `\u` 就试 `readRegExpGroupNameEscape`，解出的码点若是高代理，则保存位置再试读下一个转义，是低代理就合成完整码点、否则回退位置；解出的码点用 `appendUtf8CodePointForRegExpName` 写出并 `continue`（不再额外推进）。不是转义（或解析失败）就原样写一个字节并推进一位。
- **所有权 / 错误 / 调用**：输出缓冲归调用方。

### `readRegExpGroupNameEscape` (`src/exec/regexp_ops.zig:884`)

- **签名**：`pub fn readRegExpGroupNameEscape(name: []const u8, index: *usize) ?u21`。
- **作用**：从组名里读一个 `\uXXXX` 或 `\u{...}` 转义，成功时推进下标。
- **实现**：位置上不是 `\u`（或长度不够）返回 null。`{` 形式：逐位累加十六进制直到 `}`，中途出现非十六进制字符、值超过 `0x10ffff`、一位数字都没有、或没等到 `}` 都返回 null；成功时把下标移到 `}` 之后。定长形式：第一个字符必须是十六进制，然后**最多**看 4 位连续十六进制，实际用的位数是 `min(可用位数, 4)`——不足 4 位也接受（比严格的 `\uXXXX` 宽松）；累加后把下标推进相应位数。两种形式都返回码点。
- **所有权 / 错误 / 调用**：只被 `appendDecodedRegExpGroupName` 使用；失败时不改 `index.*`。

## `src/exec/regexp_ops.zig` — 运行时感知的 regexp 库适配

把扁平 JS 字符串、native 栈溢出、超时中断、捕获槽接到 `libs/regexp.zig`。`compileWithRuntime` 把 `lre_check_stack_overflow` 接到 `JSRuntime.checkNativeStackOverflow`。


### `compile` (`src/exec/regexp_ops.zig:24`)

- **签名**：`pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled`。
- **作用**：不带运行时钩子的编译入口（fixture / 单测用）。
- **实现**：直接转发 `regexp_lib.compilePatternAndFlags(allocator, pattern, flags)`，不装栈溢出检查回调。
- **所有权 / 错误 / 调用**：返回的 `Compiled` 归调用方，要用同一个 allocator `deinit`。

### `compileWithRuntime` (`src/exec/regexp_ops.zig:28`)

- **签名**：`pub fn compileWithRuntime(rt: *core.JSRuntime, pattern: []const u8, flags: []const u8) !Compiled`。
- **作用**：引擎正式路径的编译入口：用运行时分配器并接上栈溢出检查。
- **实现**：`regexp_lib.compilePatternAndFlagsWithOptions(rt.memory.allocator, pattern, flags, .{ .@"opaque" = rt, .check_stack_overflow = lreCheckStackOverflow })`——`opaque` 带的就是 runtime 指针。
- **所有权 / 错误 / 调用**：返回的 `Compiled` 归调用方（RegExp 对象的 payload），用 `rt.memory.allocator` 释放。


### `execCaptureSlotsOnResolvedStringFromIndex` (`src/exec/regexp_ops.zig:45`)

- **签名**：`pub fn execCaptureSlotsOnResolvedStringFromIndex( rt: *core.JSRuntime, compiled: Compiled, string_data: core.string.String.ResolvedData, start_index: usize, capture: []usize, ) ExecError!ExecResult`。
- **作用**：对**已经解析好**的扁平字符串数据跑一次匹配，把捕获写进调用方给的槽数组。
- **实现**：先 `execOptions(rt)` 拿到（可能带超时回调的）选项，再按 `string_data` 的 `.latin1` / `.utf16` 两臂分别调 `regexp_bytecode.execCaptureSlotsSliceTrustedWithOptions`。之所以传已解析的宽度而不是 JSValue：QuickJS 从 `js_regexp_exec` 一路把同一个 `JSString *` / buffer 带进 `lre_exec`，这样 global match/replace 的循环里不用每次重新解码。
- **所有权 / 错误 / 调用**：`capture` 槽由调用方分配与持有；错误集是 `ExecError = { OutOfMemory, BytecodeCorrupt, Timeout }`。

### `captureSlotValue` (`src/exec/regexp_ops.zig:59`)

- **签名**：`pub fn captureSlotValue(value: usize) ?usize`。
- **作用**：把一个原始捕获槽解释成「有值 / 未参与匹配」。
- **实现**：直接转发 `regexp_bytecode.captureSlotValue(value)`，哨兵值返回 null。
- **所有权 / 错误 / 调用**：纯转换，不分配。

### `groupName` (`src/exec/regexp_ops.zig:63`)

- **签名**：`pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8`。
- **作用**：按 1 起的捕获序号查命名捕获组的名字。
- **实现**：直接转发 `regexp_bytecode.groupName(bytecode, one_based_capture_index)`；没有名字返回 null。
- **所有权 / 错误 / 调用**：返回的切片指向 bytecode 内部，随 `Compiled` 存活，不需要释放。

### `testOnStringFromIndex` (`src/exec/regexp_ops.zig:67`)

- **签名**：`pub fn testOnStringFromIndex(rt: *core.JSRuntime, compiled: Compiled, string_value: core.JSValue, start_index: usize) ExecError!?bool`。
- **作用**：只问「从某位置起匹配不匹配」，不物化捕获。
- **实现**：`string_value.asStringBody()` 取不到字符串体就返回 null（交回调用方走慢路径）；字符串恒为扁平表示（旧的空壳 `String.ensureFlat` 及其全部调用点已删除）；直接按 `resolveData()` 的 `.latin1` / `.utf16` 两臂调 `regexp_bytecode.testMatchTrustedWithOptions`，选项同样来自 `execOptions`。
- **所有权 / 错误 / 调用**：不分配捕获缓冲；返回 `?bool`——null 表示「这不是字符串」，不是「不匹配」。

### `execOptions` (`src/exec/regexp_ops.zig:77`)

- **签名**：`fn execOptions(rt: *core.JSRuntime) regexp_bytecode.ExecOptions`。
- **作用**：按运行时有没有装中断处理器决定匹配期要不要查超时。
- **实现**：`!rt.hasInterruptHandler()` 时返回默认空选项（一次回调都不装，热路径零开销）；否则返回 `.{ .@"opaque" = rt, .check_timeout = checkRuntimeTimeout }`。
- **所有权 / 错误 / 调用**：被 `execCaptureSlotsOnResolvedStringFromIndex` 与 `testOnStringFromIndex` 使用。


### `flagBitsFromBytecode` (`src/exec/regexp_ops.zig:90`)

- **签名**：`pub fn flagBitsFromBytecode(bytecode: []const u8) u16`。
- **作用**：从编译结果里取 flag 位图。
- **实现**：直接转发 `regexp_bytecode.getFlags(bytecode)`。
- **所有权 / 错误 / 调用**：纯读。

### `appendCanonicalFlagsFromBits` (`src/exec/regexp_ops.zig:94`)

- **签名**：`pub fn appendCanonicalFlagsFromBits(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), bits: u16) !void`。
- **作用**：按规范顺序把 flag 位图写成字母序列。
- **实现**：固定顺序表 `d`(indices) / `g`(global) / `i`(ignore_case) / `m`(multiline) / `s`(dot_all) / `u`(unicode) / `v`(unicode_sets) / `y`(sticky)，逐项检查对应位；唯一特例是 `u`——当 `unicode_sets` 位也置着时跳过 `u`，只输出 `v`。
- **所有权 / 错误 / 调用**：往调用方的 `ArrayList` 追加，缓冲归调用方。

### `flagsStringValueFromBytecode` (`src/exec/regexp_ops.zig:111`)

- **签名**：`pub fn flagsStringValueFromBytecode(rt: *core.JSRuntime, bytecode: []const u8) !core.JSValue`。
- **作用**：把编译结果的 flag 位图变成 `RegExp.prototype.flags` 那种字符串值。
- **实现**：开一个 `std.ArrayList(u8)`（defer deinit），`appendCanonicalFlagsFromBits(..., flagBitsFromBytecode(bytecode))` 填好后 `core.string.String.createAscii(rt, buffer.items)` 造字符串并取 `.value()`。
- **所有权 / 错误 / 调用**：临时缓冲在函数内释放；返回的字符串值归调用方。

## `src/exec/uri_ops.zig` — encodeURI / decodeURI / escape

六条全局：encode/decode URI(Component) + Annex B escape/unescape。有 realm 时先 Annex B ToString；URIError 用 `throwUriErrorMessage` 保留具体消息（对照 `js_throw_URIError`）。decode 忠实移植 `js_global_decodeURI`：按代码单元走、% 启动 UTF-8 组装、过长/代理项 → `"malformed UTF-8"`。


### `throwUriErrorMessage` (`src/exec/uri_ops.zig:37`)

- **签名**：`fn throwUriErrorMessage(ctx: *core.JSContext, global: ?*core.Object, message: []const u8) HostError`（返回的是错误值本身，不是 error union）。
- **作用**：抛带具体消息的 `URIError`，镜像 qjs `js_throw_URIError`（quickjs.c:54734）。
- **实现**：`global` 为 null（裸运行时没有 error 原型可用）时直接返回 `error.URIError` sentinel；否则 `exception_ops.createNamedError(ctx, active_global, "URIError", message)` 造错误值，`ctx.throwValue` 挂成 pending exception，再返回 `error.URIError`。宿主调用边界的 `hasException()` 检查会保住这个具体消息，不让它被粗粒度的 "expecting hex digit" 回退覆盖。
- **所有权 / 错误 / 调用**：异常值归 ctx；本文件所有 URI 错误点都经它。

### `uriEntry` (`src/exec/uri_ops.zig:60`)

- **签名**：`fn uriEntry(comptime name: []const u8, comptime mode: u32) core.host_function.InternalEntry`。
- **作用**：给四个 `encodeURI` / `decodeURI` 族记录起名，参数命名上强调 id 就是模式选择子（1=encodeURI、2=encodeURIComponent、3=decodeURI、4=decodeURIComponent）。
- **实现**：直接 `return uriNamedEntry(name, mode)`，没有别的逻辑。
- **所有权 / 错误 / 调用**：comptime 求值。

### `uriNamedEntry` (`src/exec/uri_ops.zig:64`)

- **签名**：`fn uriNamedEntry(comptime name: []const u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：构造一条 `.uri` 记录。
- **实现**：`.length = 1`、`.id = id`、`.magic = id`（id 直接兼作 magic，不做 `@intCast`）、`.cproto = .generic_magic`、`.native_function = builtin_dispatch.genericMagicFunction(&uriCall)`；`internal_entries` 的六条（四个 URI 函数 + `escape`(id 5) + `unescape`(id 6)）都由它生成。
- **所有权 / 错误 / 调用**：comptime 求值。

### `uriCall` (`src/exec/uri_ops.zig:81`)

- **签名**：`fn uriCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：六个全局 URI / Annex B 函数共享的记录处理函数：负责实参的字符串强制转换，再进方法体。
- **实现**：`nativeCall` 恢复 `NativeCall`，失败 → `error.TypeError`。有 `func_obj`（可观察调用）时取 `callableRealm` 的 global 并断言 `realm.realm == ctx`；没有函数对象（VM 的按名回退合成调用）时才用 `host_call.global`。`mode` 取 magic，`input` 取 `args[0]`，缺参补 `undefined`。有 global 的 realm 路径：输入已经是字符串就直接进 `uriBody`（省一次转换），否则先 `string_ops.toStringForAnnexB`（用户可见的 ToString，带 caller bytecode / frame）再进 `uriBody`。没有 global 时直接 `uriBody(ctx, null, mode, input)`，走只用原始值的裸实现（也就拿不到具体的 URIError 文本）。
- **所有权 / 错误 / 调用**：不分配；返回值归调用方。exec 侧的直接调用点统一走 `callInternalRecord` 进这里，而不是按名字点到方法体。

### `uriBody` (`src/exec/uri_ops.zig:121`)

- **签名**：`fn uriBody(ctx: *core.JSContext, global: ?*core.Object, mode: u32, input: core.JSValue) HostError!core.JSValue`。
- **作用**：把 `.uri` 记录 id 分派到具体方法体。
- **实现**：`switch (mode)`：`escape_id`(5) → `escape(rt, input)`，`unescape_id`(6) → `unescape(rt, input)`，其余（1..4）→ `call(ctx, global, mode, input)`。`global` 只用于构造具体的 `URIError` 文本，裸运行时传 null。
- **所有权 / 错误 / 调用**：返回值归调用方；被 `uriCall` 的两条路径共用。

### `uriHexDigitValue` (`src/exec/uri_ops.zig:144`)

- **签名**：`fn uriHexDigitValue(unit: u32) ?u8`。
- **作用**：把一个码元当十六进制数字解析。
- **实现**：`'0'...'9'` → `unit - '0'`，`'a'...'f'` → `unit - 'a' + 10`，`'A'...'F'` → `unit - 'A' + 10`，其余返回 null。
- **所有权 / 错误 / 调用**：纯函数；被 `uriHexDecodeAt` 使用（字节路径另有 `core.uri.fastHexPair`）。

### `uriUnitCount` (`src/exec/uri_ops.zig:153`)

- **签名**：`fn uriUnitCount(bytes: []const u8, unit_size: u8) usize`。
- **作用**：把「字节切片 + 单元宽度」换算成码元个数。
- **实现**：两条 `std.debug.assert`——`unit_size` 只能是 1 或 2、`bytes.len` 必须能被 `unit_size` 整除——然后 `bytes.len / unit_size`。
- **所有权 / 错误 / 调用**：纯计算；宽度无关的 decode walk（`decodeUriUnits` / `uriHexDecodeAt`）用它。

### `uriUnitAt` (`src/exec/uri_ops.zig:159`)

- **签名**：`inline fn uriUnitAt(bytes: []const u8, unit_size: u8, index: usize) u32`。
- **作用**：按单元宽度读第 `index` 个码元。
- **实现**：`unit_size == 1` 时直接 `bytes[index]`；否则把 `bytes.ptr + index * 2` 当 `*const u16` 读（`@ptrCast` + `@alignCast`），返回宿主字节序下的码元值。
- **所有权 / 错误 / 调用**：inline，不做边界检查（调用方先用 `uriUnitCount` 约束）。

### `uriUtf16Bytes` (`src/exec/uri_ops.zig:165`)

- **签名**：`fn uriUtf16Bytes(units: []const u16) []const u8`。
- **作用**：把 utf16 码元切片重解释成字节切片，好交给宽度无关的 walk。
- **实现**：`std.mem.sliceAsBytes(units)`。
- **所有权 / 错误 / 调用**：只是视图转换，不复制。

### `uriHexDecodeAt` (`src/exec/uri_ops.zig:172`)

- **签名**：`fn uriHexDecodeAt( ctx: *core.JSContext, global: ?*core.Object, bytes: []const u8, unit_size: u8, k: usize, ) HostError!u8`。
- **作用**：在位置 `k` 解一个 `%XX`，对应 qjs `hex_decode`（quickjs.c:54744）。
- **实现**：`k` 越界或该位置不是 `'%'` → URIError `"expecting %"`；`k + 3 > n`（后面不够两个码元）→ URIError `"expecting hex digit"`；两个码元分别过 `uriHexDigitValue`，任一不是十六进制数字 → URIError `"expecting hex digit"`；成功返回 `(hi << 4) | lo`。
- **所有权 / 错误 / 调用**：错误经 `throwUriErrorMessage` 变成带消息的 pending 异常；只被 `decodeUriUnits` 调用。

### `isUriReservedChar` (`src/exec/uri_ops.zig:188`)

- **签名**：`fn isUriReservedChar(c: u32) bool`。
- **作用**：判断码点是不是 `decodeURI`（非 component）要保持转义的保留字符，对应 qjs `isURIReserved`（quickjs.c:54727）。
- **实现**：`c >= 0x100` 直接 false；否则在字面量 `"#$&+,/:;=?@"` 里查这个字节。
- **所有权 / 错误 / 调用**：纯谓词；宽度无关 walk 用它，字节路径用的是另一份 `isReserved`——两者字符集合相同（`# $ & + , / : ; = ? @`），只是写法与参数类型不同。

### `decodeUriUnits` (`src/exec/uri_ops.zig:199`)

- **签名**：`noinline fn decodeUriUnits( ctx: *core.JSContext, global: ?*core.Object, bytes: []const u8, unit_size: u8, component: bool, ) HostError!core.JSValue`。
- **作用**：忠实移植 qjs `js_global_decodeURI`（quickjs.c:54755）：按源串 code unit 走，`%` 开 hex 转义；lead≥0x80 组装 %XX UTF-8，校验后写成码点。
- **实现**：`ArrayList(u16)` 预留 `unit_len`。遇 `%`：`uriHexDecodeAt` 读 lead，k+=3。ASCII lead 且非 component 且是 URI-reserved 则退回 `%` 并 k-=2（保留转义）。多字节：按 c0–df / e0–ef / f0–f7 定 n 与 c_min，后续字节必须 `10xxxxxx`，否则清零。`c < c_min` / `> 0x10FFFF` / 代理 → `throwUriErrorMessage("malformed UTF-8")`（quickjs.c:54812）。`c > 0xFFFF` 写成代理对（qjs `string_buffer_putc`）。最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`out` 用 runtime allocator，`defer deinit`；结果字符串归调用方。失败走 `HostError`（URIError 已挂 pending）。调用方只有 `call`：字符串快路径发现非 ASCII 码元时，以及非字符串输入被 ToString 之后，都落到这里。

### `call` (`src/exec/uri_ops.zig:277`)

- **签名**：`pub fn call(ctx: *core.JSContext, global: ?*core.Object, mode: u32, input: core.JSValue) HostError!core.JSValue`。
- **作用**：四个 URI 函数（mode 1=encodeURI、2=encodeURIComponent、3=decodeURI、4=decodeURIComponent）的方法体。
- **实现**：decode（mode 3/4）先试字符串快路径：`stringInputValue` 能拿到字符串值、`stringDataFromValue` 能拿到字符串体时，`stringDataContainsPercent` 为假就**直接把原字符串返回**（无需解码）；否则扫一遍内容，`.latin1` 有 ≥ 0x80 的字节、或 `.utf16` 有 ≥ 0x80 的码元，就转去忠实的 `decodeUriUnits` 走（早期版本在这里按字节乱拆非 ASCII，现已修正）；全 ASCII 才进 `decodeStringDataFast`，它返回非 null 即为结果。encode（mode 1/2）的字符串输入直接开一个 `ArrayList(u8)`，`encodeStringValue` 写完后 `String.createUtf8`。以上都没命中时走通用慢路径：`appendValueString` 把输入 ToString 成字节；decode 时把这些字节重建成字符串、按宽度交 `decodeUriUnits`（保证非字符串输入也走同一套忠实 walk）；encode 时按 mode 调 `encodeBytes(..., component)`，mode 不是 1/2/3/4 则 `error.TypeError`，最后 `String.createUtf8`。`component` 参数就是 `mode == 2` / `mode == 4`。
- **所有权 / 错误 / 调用**：所有临时 `ArrayList` 都在函数内 defer 释放；结果字符串归调用方。`global` 只用来生成具体的 `URIError` 文本，为 null 时只能返回裸 sentinel。调用方是 `uriBody`（以及经 `callInternalRecord` 进来的 exec 直接调用点）。

### `decodeStringDataFast` (`src/exec/uri_ops.zig:357`)

- **签名**：`fn decodeStringDataFast(ctx: *core.JSContext, global: ?*core.Object, string_value: *core.string.String, component: bool) HostError!?core.JSValue`。
- **作用**：字符串输入的 decode 快路径入口：把内容摊成 ASCII 字节再解。
- **实现**：`.latin1` 直接把字节交 `decodeAsciiBytes`。`.utf16` 先扫一遍，只要有码元 `> 0x7f` 就返回 `null`（让调用方回到 `appendValueString` 慢路径——那条路保留 QuickJS 兼容的 `\uXXXX` 加宽）；全 ASCII 时，长度不超过 128 就窄化进栈上 `stack_buf`，超过则用 `ArrayList` 预留后逐个窄化，再交 `decodeAsciiBytes`。
- **所有权 / 错误 / 调用**：临时缓冲在函数内释放；返回 `null` 表示「没走快路径」，不是空结果。

### `decodeAsciiBytes` (`src/exec/uri_ops.zig:380`)

- **签名**：`fn decodeAsciiBytes(ctx: *core.JSContext, global: ?*core.Object, bytes: []const u8, component: bool) HostError!core.JSValue`。
- **作用**：对一段 ASCII 字节跑 `%XX` 解码并造出结果字符串。
- **实现**：先试 `decodeSingleFourByteEscape`——整串恰好是一个四字节 UTF-8 转义时直接命中运行时的双码元字符串缓存。否则按长度选缓冲：`bytes.len <= 128` 时用栈上 `stack_buf` + `decodeBytesInto`（解码后的最坏长度不超过输入长度：每个 `%XX` 收缩成 1 字节，保留的保留字符维持 `%XX` 原长），否则用 `ArrayList` + `decodeBytes`；两条路都以 `String.createUtf8` 收尾。
- **所有权 / 错误 / 调用**：堆缓冲 defer 释放；结果字符串归调用方。

### `decodeSingleFourByteEscape` (`src/exec/uri_ops.zig:401`)

- **签名**：`fn decodeSingleFourByteEscape(rt: *core.JSRuntime, bytes: []const u8) !?core.JSValue`。
- **作用**：`decodeURI("%F0%9F%98%80")` 这类「整串就是一个四字节转义」的专用快路径。
- **实现**：`core.uri.decodeSingleFourByteEscapeUnitsFromAscii(bytes)` 探测并解出代理对；不匹配返回 null；命中则用 `rt.recentTwoUnitString(units.high, units.low)` 取缓存的双码元字符串并返回它的值。
- **所有权 / 错误 / 调用**：走的是运行时的近期双码元字符串缓存，通常不新分配。

### `escape` (`src/exec/uri_ops.zig:407`)

- **签名**：`pub fn escape(rt: *core.JSRuntime, input: core.JSValue) !core.JSValue`。
- **作用**：Annex B 的全局 `escape`。
- **实现**：`appendValueCodeUnits` 把输入摊成 u16 码元列表（defer 释放）；逐个码元：≤ 0xff 时，`isAnnexBEscapeUnmodified` 认可的字符（ASCII 字母数字与 `@ * _ + - . /`）原样输出，否则 `percentEncodedByte` 写成 `%XX`；> 0xff 的码元用 `percentEncodedUnit` 写成 `%uXXXX`。最后 `String.createUtf8` 造结果。
- **所有权 / 错误 / 调用**：两个 `ArrayList` 都在函数内 defer 释放；结果字符串归调用方；不需要 realm。

### `unescape` (`src/exec/uri_ops.zig:432`)

- **签名**：`pub fn unescape(rt: *core.JSRuntime, input: core.JSValue) !core.JSValue`。
- **作用**：Annex B 的全局 `unescape`。
- **实现**：同样先 `appendValueCodeUnits` 摊成码元列表。扫描时遇到 `'%'`：后面是 `'u'` 且还有 4 个十六进制码元 → 拼成一个 u16 并跳过 5 个码元；否则后面紧跟 2 个十六进制码元 → 拼成字节值并跳过 2 个；都不满足就把 `'%'` 当普通字符原样输出（不报错）。结果用 `String.createUtf16`（**不是** utf8，码元可能是任意 u16）。
- **所有权 / 错误 / 调用**：缓冲 defer 释放；结果字符串归调用方。

### `stringInputValue` (`src/exec/uri_ops.zig:471`)

- **签名**：`fn stringInputValue(input: core.JSValue) !?core.JSValue`。
- **作用**：判断输入能不能直接当字符串用（快路径准入）。
- **实现**：输入本身是字符串就原样返回；是对象且 class 为 `string`（String 包装对象）时取 `objectData()`，取不到 → `error.TypeError`，取到就返回里面的原始字符串值；其余返回 null，让调用方走 `appendValueString` 慢路径。
- **所有权 / 错误 / 调用**：返回的是借用的值；被 `call` 的 encode 与 decode 两侧使用。

### `stringDataFromValue` (`src/exec/uri_ops.zig:486`)

- **签名**：`fn stringDataFromValue(value: core.JSValue) ?*core.string.String`。
- **作用**：取字符串值的字符串体。
- **实现**：直接 `return value.asStringBody()`。
- **所有权 / 错误 / 调用**：借用指针。

### `encodeStringValue` (`src/exec/uri_ops.zig:490`)

- **签名**：`fn encodeStringValue(ctx: *core.JSContext, global: ?*core.Object, out: *std.ArrayList(u8), value: core.JSValue, component: bool) HostError!void`。
- **作用**：`encodeURI` / `encodeURIComponent` 在字符串输入上的主体。
- **实现**：`asStringBody` 取不到就静默返回；按 `resolveData()` 分宽度：`.latin1` 逐字节 `encodeCodepoint`；`.utf16` 要处理代理——落单的低代理 → URIError `"invalid character"`，高代理后面没有码元或后一个不是低代理 → URIError `"expecting surrogate pair"`（两条都对应 `js_global_encodeURI`，quickjs.c:54887），配对成功则 `codePointFromSurrogatePair` 合成码点后编码并多跳一个码元；其余码元直接编码。
- **所有权 / 错误 / 调用**：往调用方的 `out` 写；错误经 `throwUriErrorMessage`。

### `encodeCodepoint` (`src/exec/uri_ops.zig:524`)

- **签名**：`fn encodeCodepoint(rt: *core.JSRuntime, out: *std.ArrayList(u8), codepoint: u21, component: bool) !void`。
- **作用**：按 URI 规则输出一个码点：要么原样，要么百分号编码。
- **实现**：码点 ≤ 0x7f 且满足 `isUnescaped`（ASCII 字母数字与 `- _ . ! ~ * ' ( )`），或者在非 component 模式下满足 `isReserved`，就原样写一个字节返回。其余先 `std.unicode.utf8Encode`（失败 → `error.URIError`），再对每个 UTF-8 字节 `appendPercentByte` 写成 `%XX`。
- **所有权 / 错误 / 调用**：往调用方的 `out` 写。

### `appendPercentByte` (`src/exec/uri_ops.zig:537`)

- **签名**：`fn appendPercentByte(rt: *core.JSRuntime, out: *std.ArrayList(u8), byte: u8) !void`。
- **作用**：往缓冲里追加一个字节的 `%XX` 形式。
- **实现**：`percentEncodedByte(byte)` 生成三字节数组后 `out.appendSlice`。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `stringDataContainsPercent` (`src/exec/uri_ops.zig:542`)

- **签名**：`fn stringDataContainsPercent(string_value: *core.string.String) bool`。
- **作用**：decode 前的预筛：整串没有 `'%'` 就不用解码。
- **实现**：按 `resolveData()` 的宽度分别 `std.mem.indexOfScalar` 找 `'%'`（latin1 找字节、utf16 找码元）。
- **所有权 / 错误 / 调用**：纯读；`call` 的 decode 快路径靠它直接把原字符串原样返回。

### `encodeBytes` (`src/exec/uri_ops.zig:549`)

- **签名**：`fn encodeBytes(rt: *core.JSRuntime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void`。
- **作用**：对已经 ToString 成字节的输入做百分号编码（非字符串输入的慢路径）。
- **实现**：逐字节：`isUnescaped(ch)`，或非 component 模式下的 `isReserved(ch)`，原样追加；否则 `percentEncodedByte` 写 `%XX`。注意这里按字节走，不像 `encodeStringValue` 那样做码点 / 代理校验。
- **所有权 / 错误 / 调用**：缓冲归调用方。

### `percentEncodedByte` (`src/exec/uri_ops.zig:560`)

- **签名**：`fn percentEncodedByte(byte: u8) [3]u8`。
- **作用**：把一个字节写成 `%XX`。
- **实现**：返回 `{ '%', 高 4 位的大写十六进制字符, 低 4 位的大写十六进制字符 }`，字符由 `unicode.asciiUpperHexDigitChar` 生成。
- **所有权 / 错误 / 调用**：返回值是按值传的定长数组。

### `percentEncodedUnit` (`src/exec/uri_ops.zig:564`)

- **签名**：`fn percentEncodedUnit(unit: u16) [6]u8`。
- **作用**：把一个 u16 码元写成 Annex B 的 `%uXXXX`。
- **实现**：返回 `{ '%', 'u', 四个大写十六进制字符（从高 4 位到低 4 位） }`。
- **所有权 / 错误 / 调用**：只被 `escape` 使用。

### `decodeBytes` (`src/exec/uri_ops.zig:575`)

- **签名**：`fn decodeBytes(ctx: *core.JSContext, global: ?*core.Object, out: *std.ArrayList(u8), bytes: []const u8, component: bool) HostError!void`。
- **作用**：字节层的 `%XX` 解码（堆缓冲版本）。
- **实现**：非 `'%'` 字节原样追加。遇 `'%'`：后面不足两个字节 → URIError `"expecting hex digit"`；`core.uri.fastHexPair` 解两位十六进制，失败同样报 `"expecting hex digit"`（对应 qjs `hex_decode`，quickjs.c:54744）。解出的字节若在非 component 模式下是 `isReserved`，就把原来的 `%XX` 三字节原样写回（保持转义）；`< 0x80` 直接写；否则按 UTF-8 lead 分类（c0-df → 1 个后续字节 / min 0x80，e0-ef → 2 个 / 0x800，f0-f7 → 3 个 / 0x10000，其余 → count 0、min 1、codepoint 0）逐个读后续的 `%XX`：不是 `'%'` → `"expecting %"`（quickjs.c:54747），长度不够或非十六进制 → `"expecting hex digit"`，不是 `10xxxxxx` 的续字节则把码点清零并跳出（quickjs.c:54806）。最后码点低于 min、超过 0x10ffff 或落在代理区 → `"malformed UTF-8"`（quickjs.c:54812），否则 `utf8Encode` 回写（编码失败同样报 `"malformed UTF-8"`）。
- **所有权 / 错误 / 调用**：往调用方的 `ArrayList` 写；长输入路径用它。

### `decodeBytesInto` (`src/exec/uri_ops.zig:647`)

- **签名**：`fn decodeBytesInto(ctx: *core.JSContext, global: ?*core.Object, dest: []u8, bytes: []const u8, component: bool, out_len: *usize) HostError!void`。
- **作用**：与 `decodeBytes` 完全同一套逻辑，只是写进调用方给的定长缓冲。
- **实现**：分支、错误消息与 quickjs.c 对应点（54744 / 54747 / 54806 / 54812）都与 `decodeBytes` 一致，区别在于用本地 `len` 游标往 `dest` 写（保留保留字符时写 3 个字节、普通字节写 1 个、多字节码点用 `utf8Encode(dest[len..])` 就地编码），结束时把总长写回 `out_len.*`。调用方保证 `dest.len >= bytes.len`——URI 解码后的长度绝不会超过输入长度。
- **所有权 / 错误 / 调用**：不分配；`decodeAsciiBytes` 的栈缓冲路径用它。

### `isSurrogate` (`src/exec/uri_ops.zig:718`)

- **签名**：`fn isSurrogate(codepoint: u21) bool`。
- **作用**：判断码点是否落在代理区。
- **实现**：转发 `unicode.isSurrogateCodePoint(codepoint)`。
- **所有权 / 错误 / 调用**：被 `decodeBytes` / `decodeBytesInto` 的 `"malformed UTF-8"` 校验使用。

### `appendValueCodeUnits` (`src/exec/uri_ops.zig:722`)

- **签名**：`fn appendValueCodeUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) AppendStringError!void`。
- **作用**：把任意值摊成 u16 码元序列，供 `escape` / `unescape` 使用。
- **实现**：Symbol → `error.TypeError`；字符串 → `appendStringCodeUnits`；String 包装对象（class `string`）→ 取 `objectData()`（取不到 → `error.TypeError`）后同样走 `appendStringCodeUnits`；其余值先 `appendValueString` 做裸运行时 ToString 得到字节，再把每个字节零扩展成一个码元追加。
- **所有权 / 错误 / 调用**：中间字节缓冲在函数内 defer 释放；输出缓冲归调用方。

### `appendStringCodeUnits` (`src/exec/uri_ops.zig:740`)

- **签名**：`fn appendStringCodeUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void`。
- **作用**：把一个字符串值的码元追加进列表。
- **实现**：`asStringBody` 取不到就静默返回；`.latin1` 逐字节零扩展追加、`.utf16` 直接 `appendSlice` 整段。
- **所有权 / 错误 / 调用**：输出缓冲归调用方。

### `isAnnexBEscapeUnmodified` (`src/exec/uri_ops.zig:748`)

- **签名**：`fn isAnnexBEscapeUnmodified(ch: u8) bool`。
- **作用**：Annex B `escape` 里不需要转义的字符集。
- **实现**：ASCII 字母数字，或 `@`、`*`、`_`、`+`、`-`、`.`、`/` 七个符号之一。
- **所有权 / 错误 / 调用**：只被 `escape` 使用。

### `isHexCodeUnit` (`src/exec/uri_ops.zig:752`)

- **签名**：`fn isHexCodeUnit(unit: u16) bool`。
- **作用**：判断码元是不是十六进制数字。
- **实现**：转发 `unicode.isAsciiHexDigitUnit(unit)`。
- **所有权 / 错误 / 调用**：只被 `unescape` 使用。

### `hexCodeUnitValue` (`src/exec/uri_ops.zig:756`)

- **签名**：`fn hexCodeUnitValue(unit: u16) u8`。
- **作用**：把十六进制码元转成数值。
- **实现**：`unicode.asciiHexDigitValueUnit(unit) orelse unreachable`——调用方必须先用 `isHexCodeUnit` 过滤，否则是 UB / panic。
- **所有权 / 错误 / 调用**：只被 `unescape` 使用。

### `isUnescaped` (`src/exec/uri_ops.zig:760`)

- **签名**：`fn isUnescaped(ch: u8) bool`。
- **作用**：URI 编码里永不转义的字符集（spec 的 uriUnescaped）。
- **实现**：ASCII 字母数字，或 `-`、`_`、`.`、`!`、`~`、`*`、`'`、`(`、`)` 之一。
- **所有权 / 错误 / 调用**：被 `encodeCodepoint` 与 `encodeBytes` 使用。

### `isReserved` (`src/exec/uri_ops.zig:764`)

- **签名**：`fn isReserved(ch: u8) bool`。
- **作用**：URI 保留字符集（spec 的 uriReserved 加 `#`）：`encodeURI` 保持原样、`decodeURI` 保持转义。
- **实现**：`;`、`,`、`/`、`?`、`:`、`@`、`&`、`=`、`+`、`$`、`#` 十一个字符。
- **所有权 / 错误 / 调用**：被 `encodeCodepoint` / `encodeBytes` / `decodeBytes` / `decodeBytesInto` 使用；宽单元 walk 用的是等价的 `isUriReservedChar`。

### `appendValueString` (`src/exec/uri_ops.zig:769`)

- **签名**：`fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void`。
- **作用**：本文件对裸运行时 ToString 的统一策略入口。
- **实现**：转发 `core.value_string.appendValueString(rt, buffer, value, .{})`，即用默认选项。
- **所有权 / 错误 / 调用**：缓冲归调用方；`call` 与 `appendValueCodeUnits` 的非字符串输入路径经它。

## 覆盖核对

- 清单函数数: 127（`src/exec/regexp_ops.zig` 12 + `src/exec/regexp_ops.zig` 30 + `src/exec/regexp_ops.zig` 47 + `src/exec/uri_ops.zig` 38）
- 本文标题覆盖: 127
- 未覆盖: 无
