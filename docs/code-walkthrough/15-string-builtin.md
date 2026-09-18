# 15 — `string_builtin_ops.zig`：String record 表与直接叶子

## 类型

- `TrimMode`：start / end / both。
- `CodePointSpan`：一个码点及其码元区间 `{value, start, end}`（代理对时 `end - start == 2`）。
- `StringSliceRange`：slice/substring 规范化后的 `[start, end)`。
- `PadSide`：padStart / padEnd。
- `StringContainsMode`：includes / startsWith / endsWith。
- `internal_entries`：String 构造器 construct-capable；fromCharCode 走 `exec_direct`；charAt/charCodeAt/at/codePointAt 走 `prim_self` 叶子（平字符串+int32 下标），tag miss 回退完整 ToString/ToNumber。

`methodCall` 是过渡窄实现；完整 locale/html/normalize 仍在 `string_ops.stringPrototypeMethod`。

### `stringEntry` (`src/exec/string_builtin_ops.zig:119`)

- **签名**：`fn stringEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：造一条用共享 `stringCall` 分发器的 `.string` 记录。
- **实现**：把 `&stringCall` 作为 handler 转发给 `stringEntryWithHandler`，其余字段原样传递。
- **所有权 / 错误 / 调用**：无运行时行为：comptime 造表项，结果只出现在 `internal_entries`（:69）里，由 `internal_builtins.recordTable` 注册给 `rt.internal_builtins`。表里除构造器、fromCharCode、concat、两个 case 方法和四个索引读之外的条目都用它。

### `stringDirectEntry` (`src/exec/string_builtin_ops.zig:123`)

- **签名**：`fn stringDirectEntry( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, ) core.host_function.InternalEntry`。
- **作用**：造一条带专用 handler（而非共享 `stringCall`）的 `.string` 记录。
- **实现**：参数原样转发 `stringEntryWithHandler`；`concat` / `toUpperCase` / `toLowerCase` 用它挂各自的 record 函数。
- **所有权 / 错误 / 调用**：同 `stringEntry`：纯 comptime、不分配，区别只是 handler 由调用处给。调用方是 `internal_entries` 的三条——toUpperCase / toLowerCase（`stringCaseCall`，:86-:87）与 concat（`stringConcatCall`，:93）。

### `stringExecDirectEntry` (`src/exec/string_builtin_ops.zig:135`)

- **签名**：`fn stringExecDirectEntry( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, comptime direct: core.native_entry.ManagedFn, ) core.host_function.InternalEntry`。
- **作用**：在共享记录之上挂 `exec_direct` 直接体，让热路径跳过 TLS / typed-cproto / `stringCall` 的 magic 多路分发。
- **实现**：先用 `stringEntryWithHandler(name, length, id, handler)` 造出 generic_magic 记录，再把 `entry.managed` 设成 comptime 传入的 `ManagedFn`（当前只有 `fromCharCode` 用它）。
- **所有权 / 错误 / 调用**：纯 comptime；`entry.managed` 存的是 `ManagedFn` 函数指针（comptime 常量），不是 GC 对象，不涉及所有权。唯一调用点是 `internal_entries` 的 fromCharCode（:76）。

### `stringPrimLeafEntry` (`src/exec/string_builtin_ops.zig:151`)

- **签名**：`fn stringPrimLeafEntry( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, comptime direct: ?core.native_entry.ManagedFn, comptime sig: []const u8, comptime leaf: native_legacy.LeafStringI32ToI32, ) core.host_function.InternalEntry`。
- **作用**：造 `prim_self`（design §4.3）形状的 `method_leaf` 记录：热臂是平字符串接收者 + int32 下标的类型化 leaf，声明的 handler 与可选 exec_direct 体是 tag-miss 回退。
- **实现**：在 `stringEntryWithHandler` 的结果上写 `entry.managed = direct`（允许为 null）和 `entry.prim_leaf = .{ .sig = sig, .target = core.NativeEntry.code(leaf) }`；charAt / charCodeAt / at / codePointAt 四项用它。
- **所有权 / 错误 / 调用**：纯 comptime；`core.NativeEntry.code(leaf)` 只把叶函数指针装进记录，叶子自己不接触 runtime、不建根。调用点是 `internal_entries` 的 charAt / charCodeAt / at / codePointAt 四条（:84、:98-:100）。

### `stringEntryWithHandler` (`src/exec/string_builtin_ops.zig:166`)

- **签名**：`fn stringEntryWithHandler( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, ) core.host_function.InternalEntry`。
- **作用**：四个 entry 构造器的公共尾：填好 `InternalEntry` 的通用字段。
- **实现**：`magic = @intCast(id)`、`cproto = .generic_magic`、`native_function = builtin_dispatch.genericMagicFunction(handler)`；不设 `managed` / `prim_leaf`，由上层构造器补。
- **所有权 / 错误 / 调用**：纯 comptime，但它定下的 `.generic_magic` 是本文件**所有** `*Call` handler 的错误契约：handler 返回的 `HostError` 由 `native_legacy.managedGenericMagic` 的 thunk 经 `builtin_dispatch.hostResultToValue` → `nativeFromHostError` 变成「pending JS 异常 + 异常哨兵 JSValue」，handler 自己不必挂异常；`error.TypeError` 这类裸 error 由 `materializeRuntimeError` 补成空消息的 TypeError。调用方：本文件四个 entry 构造器。

### `testStringDeclById` (`src/exec/string_builtin_ops.zig:195`)

- **签名**：`fn testStringDeclById(comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 按 id 在 `internal_entries` 里查记录，供本文件的单测断言用。
- **实现**：comptime 遍历 `internal_entries`，`decl.id == id` 命中即返回；查不到时 `@compileError("no String entry with that id")`。
- **所有权 / 错误 / 调用**：纯 comptime，无运行时分配；调用方只有本文件的 test 块。

### `stringConstructorEntry` (`src/exec/string_builtin_ops.zig:266`)

- **签名**：`fn stringConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：造 String 构造器记录：construct-capable，`String(...)` 与 `new String(...)` 都进 `stringCall`。
- **实现**：手写 `InternalEntry`：`magic = @intCast(id)`、`cproto = .constructor_or_func_magic`、`native_function = builtin_dispatch.constructorOrFunctionMagic(&stringCall)`。
- **所有权 / 错误 / 调用**：纯 comptime。`constructor_or_func_magic` 让同一个 `stringCall` 同时服务 `String(...)` 与 `new String(...)`（construct 侧入口在 `exec/construct.zig`），错误契约与 `stringEntryWithHandler` 相同。唯一调用点是 `internal_entries` 的 String 条目（:75）。

### `stringPrimitiveIndexRead` (`src/exec/string_builtin_ops.zig:290`)

- **签名**：`inline fn stringPrimitiveIndexRead(host_call: NativeCall, comptime mid: u32) HostError!?core.JSValue`。
- **作用**：charCodeAt / at / codePointAt 的共用快路径：接收者已是字符串且下标是立即数时直接读码元；形状对不上返回 `null`，让调用方落到完整的强制转换路径。
- **实现**：接收者非字符串立即返回 `null`；是 rope 就先 `flatten()`（与 qjs `JS_ToStringCheckObject` → `js_linearize_string_rope` 同一边界，展平后缓存进节点，再次进入是 O(1)）。下标缺省为 0，否则经 `stringPrimitiveInt32Sat` 饱和成 i32，该函数返回 null（需要可观察 ToNumber）时整体返回 `null`。随后按 comptime `mid` 分三臂：29（charCodeAt）越界返回 NaN，否则返回码元 int32；30（at）负下标按 `len + idx` 回绕，越界返回 undefined，否则经 `codeUnitStringValue` 返回单码元串；其余（31，codePointAt）越界返回 undefined，高代理且后继是低代理时合成码点。QuickJS 坐标：quickjs.c:45450、quickjs.c:13597-13598、quickjs.c:4838-4844、quickjs.c:4851-4855。
- **所有权 / 错误 / 调用**：接收者与参数都是借用；rope 接收者会被 `node.flatten()` **就地展平**（展平体缓存回节点，是对接收者的可见副作用，不是新串）。29 / 31 臂返回立即数不分配，30 臂经 `codeUnitStringValue` 取 runtime 共享单字节串或新建 UTF-16 串。`flatten` / 建串的 `OutOfMemory`、`StringTooLong` 经 `@errorCast` 变成 `HostError` 上抛，到 thunk 才成为 JS 异常；形状不符返回 `null`（不是错误）。调用方：`stringCharCodeAtDirectHost:542`、`stringCharCodeAtCall:583`、`stringAtCall:594` 等 4 处。

### `stringPrimitiveInt32Sat` (`src/exec/string_builtin_ops.zig:342`)

- **签名**：`inline fn stringPrimitiveInt32Sat(value: core.JSValue) ?i32`。
- **作用**：qjs `JS_ToInt32SatFree` 的立即数腿：把索引参数饱和成 i32；需要可观察 ToNumber 的值（对象、字符串、Symbol、BigInt）返回 `null`。
- **实现**：int32 直返；bool 取 `@intFromBool`；null / undefined 取 0；其余取 `asNumber`，拿不到就返回 `null`。NaN → 0，小于 `minInt(i32)` 或大于 `maxInt(i32)` 时饱和到边界，否则 `@intFromFloat` 截断。字符串长度到不了 `INT32_MAX`，所以饱和不改变可观察结果。
- **所有权 / 错误 / 调用**：无：纯值检查，不分配、不建根、不返回 error；`null` 只表示「需要可观察 ToNumber」，由调用方决定回退。调用方：`stringPrimitiveIndexRead:309`、`stringCharCodeAtDirectHost:565`/`:569`。

### `stringPrimitiveConcat` (`src/exec/string_builtin_ops.zig:371`)

- **签名**：`inline fn stringPrimitiveConcat(host_call: NativeCall) HostError!?core.JSValue`。
- **作用**：`String.prototype.concat` 的直接快路径：平 latin1 接收者配 latin1 字符串 / int32 参数时，量一次长、分配一次、逐段 memcpy。
- **实现**：接收者必须是非 rope 的平 latin1 字符串，否则返回 `null`；参数个数超过 `concat_direct_max_args`（7）也返回 `null`。逐参数取 latin1 切片，int32 参数用 `number_format.formatInt32` 写进栈上 12 字节缓冲，不新建中间数字串；出现其它形状立刻返回 `null`。累计长度超过 `core.string.max_length` 同样回退，让 StringTooLong 只走共享路径；总长为 0 返回 `rt.emptyString()`，否则 `String.createLatin1Parts` 一次建串。QuickJS 坐标：quickjs.c:45525（`js_string_concat`）、quickjs.c:4646（`JS_ConcatString1`）。
- **所有权 / 错误 / 调用**：`parts` 里全是借用切片——接收者与字符串参数的 latin1 体，以及 int32 参数格式化进的栈上 12 字节缓冲。取切片到 `createLatin1Parts` 之间没有建串（建串才是 `collectBeforeObjectAllocation` 分配点），接收者/参数又由调用帧的操作数栈窗口保活，所以借用合法。返回新建 latin1 串或 runtime 共享空串（`rt.emptyString`）。总长超 `core.string.max_length` 时返回 `null` 回退，`StringTooLong` 因此只可能出自共享路径；`OutOfMemory` 经 `@errorCast` 上抛。唯一调用方 `stringConcatCall:413`。

### `stringConcatCall` (`src/exec/string_builtin_ops.zig:406`)

- **签名**：`fn stringConcatCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`concat` 记录的专用 handler：先试 latin1 直接体，miss 落共享 `stringCall`。
- **实现**：三步固定形状：`builtin_dispatch.nativeCall` 把 C ABI 参数收成 `NativeCall`（收不成即 `error.TypeError`），`stringPrimitiveConcat` 试直接路径——接收者必须是未成 rope 的 latin1 串、参数个数不超过 `concat_direct_max_args`，整数参数就地格式化进栈上小缓冲，一次拼完；返回 `null` 表示不适用，落到通用的 `stringCall`。
- **所有权 / 错误 / 调用**：`builtin_dispatch.nativeCall` 读 TLS 里的 `active_native_call` 环境，取不到就返回裸 `error.TypeError`（无消息，由 thunk 的 `materializeRuntimeError` 补成空消息 TypeError）。直接体 miss 时把原始 C ABI 参数整份转交 `stringCall`，自身不复制不持有。调用方：只有记录分发，经 `internal_entries` 的 concat 条目（:93）。

### `stringFromCharCodeDirect` (`src/exec/string_builtin_ops.zig:417`)

- **签名**：`fn stringFromCharCodeDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`String.fromCharCode` 的 NMFD C ABI 直接入口：不经 TLS magic mux，把码元参数拼成字符串，失败折成 JS 异常值。
- **实现**：取 `ctx.global`（为空则把 `error.InvalidBuiltinRegistry` 交给 `hostErrorToValue` 变成异常值），经 `builtin_dispatch.vmCallerView` 拿 output / caller 视图（this 与 caller 帧在本体里未使用），再转 `string_ops.stringFromCharCode`；失败同样经 `hostErrorToValue` 转成 JS 异常值。
- **所有权 / 错误 / 调用**：C ABI 直接体，永不返回 Zig error：`ctx.global` 缺失走 `hostErrorToValue(error.InvalidBuiltinRegistry)`——该 error 不在 `exception_ops.runtimeErrorInfo` 表里，最终落成 `Error: InvalidBuiltinRegistry`；`string_ops.stringFromCharCode` 的错误同样经 `hostErrorToValue` 转成异常值（已有 pending 异常时保留原异常）。返回值的所有权来自被调方（新建串或 runtime 缓存串）。它不是被 Zig 直接调用的：`entry.managed`（:76）由 NativeEntry 的 managed 直接体路径调起。

### `stringFromCharCodeCall` (`src/exec/string_builtin_ops.zig:440`)

- **签名**：`fn stringFromCharCodeCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`String.fromCharCode` 的 generic_magic handler：解析出 realm global 后转 `string_ops.stringFromCharCode`。
- **实现**：`builtin_dispatch.nativeCall` 组不出调用视图即 TypeError；有 `func_obj` 时经 `callableRealm` 取 realm global 并断言 realm 就是当前 ctx，否则用 `host_call.global`，两者都没有返回 TypeError。
- **所有权 / 错误 / 调用**：generic_magic handler：取不到 TLS 环境、或既无 `func_obj` 又无 `global` → 裸 `error.TypeError`；`callableRealm` 在记录没带 `callable_realm` 时返回 `error.InvalidBuiltinRegistry`。自身不分配，返回值所有权来自 `string_ops.stringFromCharCode`。调用点是 `internal_entries` fromCharCode 条目（:76）的 handler 槽。

### `stringCharCodeAtLeaf` (`src/exec/string_builtin_ops.zig:464`)

- **签名**：`fn stringCharCodeAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32`。
- **作用**：`charCodeAt` 的 prim_self 叶子：平字符串 + int32 下标下直接返回码元。
- **实现**：下标为负或 `>= str.len()` 返回 -1（哨兵，让臂落回 fallback 去算可观察的 NaN），否则 `str.codeUnitAt(index)`。
- **所有权 / 错误 / 调用**：`str` 是臂（`builtin_dispatch.invokeMethodLeafFast`）已验过的扁平接收者借用指针；不分配、不建根、无 error，`-1` 是「落回 fallback」的哨兵而非异常。树内无 Zig 调用方：只经 charCodeAt 记录（:98）的 `prim_leaf.target` 被臂调起，另有本文件 test 直接验哨兵规则。

### `stringCharAtLeaf` (`src/exec/string_builtin_ops.zig:469`)

- **签名**：`fn stringCharAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32`。
- **作用**：`charAt` 的 prim_self 叶子：返回码元，由调用臂按 `STRING_I32_TO_STRING` 签名转成单字符串。
- **实现**：下标为负或 `>= str.len()` 返回 -1（哨兵，落回 fallback 去算空串），否则 `str.codeUnitAt(index)`。
- **所有权 / 错误 / 调用**：同 `stringCharCodeAtLeaf`：借用扁平接收者、返回码元或 `-1` 哨兵，不分配无 error；`-1` 让臂去 fallback 里算出空串。经 charAt 记录（:84）的 `prim_leaf.target` 调起，树内无 Zig 调用方。

### `stringAtLeaf` (`src/exec/string_builtin_ops.zig:474`)

- **签名**：`fn stringAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32`。
- **作用**：`at` 的 prim_self 叶子：支持负下标回绕，返回码元由臂转成单字符串。
- **实现**：`relative = if (index < 0) len + index else index`；`relative` 落在 `[0, len)` 外返回 -1（哨兵，落回 fallback 去算 undefined），否则 `str.codeUnitAt(relative)`。
- **所有权 / 错误 / 调用**：同族叶子：借用接收者、负下标先回绕再判越界，返回码元或 `-1` 哨兵，不分配无 error。经 at 记录（:99）的 `prim_leaf.target` 调起，树内无 Zig 调用方。

### `stringCodePointAtLeaf` (`src/exec/string_builtin_ops.zig:481`)

- **签名**：`fn stringCodePointAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32`。
- **作用**：`codePointAt` 的 prim_self 叶子：返回码点（必要时合成代理对）。
- **实现**：下标为负或越界返回 -1（哨兵）；否则读码元，若是高代理且后一个码元是低代理则 `unicode.codePointFromSurrogatePair` 合成，否则返回该码元。
- **所有权 / 错误 / 调用**：同族叶子：借用接收者，代理对合成后仍是 i32 立即数，不分配无 error，`-1` 为回退哨兵。经 codePointAt 记录（:100）的 `prim_leaf.target` 调起，树内无 Zig 调用方（本文件 test 直接验代理对规则）。

### `stringCharCodeAtDirect` (`src/exec/string_builtin_ops.zig:493`)

- **签名**：`fn stringCharCodeAtDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`String.prototype.charCodeAt` 的 NMFD C ABI 直接入口：不经 TLS magic mux，取一个码元，失败折成 JS 异常值。
- **实现**：取 `ctx.global`（缺失则 `error.InvalidBuiltinRegistry` 转异常值）与 `vmCallerView` 的 output / caller 帧，转 `stringCharCodeAtDirectHost`，结果经 `builtin_dispatch.hostResultToValue` 变成 `JSValue`。
- **所有权 / 错误 / 调用**：C ABI 直接体：`stringCharCodeAtDirectHost` 的 `HostError` 由 `builtin_dispatch.hostResultToValue` 就地变成 pending 异常 + 异常哨兵值；`ctx.global` 缺失单独走 `hostErrorToValue(error.InvalidBuiltinRegistry)`。本函数自己不分配、不建根。调用点是 charCodeAt 记录（:98）的 `managed` 槽。

### `stringCharCodeAtDirectHost` (`src/exec/string_builtin_ops.zig:518`)

- **签名**：`inline fn stringCharCodeAtDirectHost( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：exec_direct 热路径落到带 realm/caller 的 HostError 实现。
- **实现**：手工拼一个 `func_obj == null`、`magic = char_code_at` 的 `NativeCall`，先走 `stringPrimitiveIndexRead(host_call, 29)`。miss 时刻意不回到 `stringPrototypeMethod` / `callStringBody`（那会以 null `func_obj` 再入本记录的 exec_direct 并抛 InvalidBuiltinRegistry），而是直接 `string_ops.toStringCheckObject` 强制接收者（它总是交出一个持有引用的串），必要时 `flatten` rope；下标先试 `stringPrimitiveInt32Sat`，失败再经 `builtin_glue.toNumberLikeArgument` 做可观察 ToNumber，仍拿不到 i32 则 TypeError。越界返回 NaN，否则返回码元。
- **所有权 / 错误 / 调用**：返回值恒为立即数（码元 int32 或 NaN），不分配。中途 `string_ops.toStringCheckObject` 的结果只在函数内读取：字符串接收者被原样交回（`string_ops.zig:119` 是 `if (value.isString()) return value;`，不 dup——函数上方那段「总是 owned、漏释放会泄漏」的注释描述的是 rc 时代的义务），其它接收者才是新建串；rope 结果同样就地 `flatten`。错误：`toStringCheckObject` / `toNumberLikeArgument` 已用 `throwTypeErrorMessage` 挂好 pending 消息，本函数原样上抛 Zig error；ToNumber 后仍取不到 i32 时返回裸 `error.TypeError`。刻意不回落 `stringPrototypeMethod`——那会以 `func_obj == null` 重入本记录并触发 `InvalidBuiltinRegistry`。唯一调用方 `stringCharCodeAtDirect:507`。

### `stringCharCodeAtCall` (`src/exec/string_builtin_ops.zig:576`)

- **签名**：`fn stringCharCodeAtCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`charCodeAt` 记录的 generic_magic handler：先试 `stringPrimitiveIndexRead(…, 29)`，miss 落 `stringCall`。
- **实现**：`nativeCall` 收参（失败 `error.TypeError`）后先试 `stringPrimitiveIndexRead(host_call, 29)`：接收者是字符串才走，是 rope 先 `flatten()` 线性化（与 qjs `JS_ToStringCheckObject` → `js_linearize_string_rope` 同一个边界，摊到 O(1)），再按 magic 29 取码元；返回 `null` 就落回通用 `stringCall`。
- **所有权 / 错误 / 调用**：tag 命中时直接返回 `stringPrimitiveIndexRead` 的立即数，miss 时把原参数整份转交 `stringCall`；自身不分配、不建根。取不到 TLS 环境即裸 `error.TypeError`。它是 charCodeAt 记录（:98）的 tag-miss fallback handler（热臂先走 `stringCharCodeAtLeaf`）。

### `stringAtCall` (`src/exec/string_builtin_ops.zig:587`)

- **签名**：`fn stringAtCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`at` 记录的 generic_magic handler：先试 `stringPrimitiveIndexRead(…, 30)`，miss 落 `stringCall`。
- **实现**：与 `stringCharCodeAtCall` 同形，只是 `stringPrimitiveIndexRead` 的 comptime magic 是 30（`at` 的负下标语义）；快路径要求接收者是字符串、rope 先线性化，不适用时落回 `stringCall`。
- **所有权 / 错误 / 调用**：同族：命中返回 `stringPrimitiveIndexRead` 的结果（undefined 立即数或共享/新建的单码元串），miss 转交 `stringCall`；自身不分配。无 TLS 环境 → 裸 `error.TypeError`。它是 at 记录（:99）的 tag-miss fallback handler。

### `stringCodePointAtCall` (`src/exec/string_builtin_ops.zig:598`)

- **签名**：`fn stringCodePointAtCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`codePointAt` 记录的 generic_magic handler：先试 `stringPrimitiveIndexRead(…, 31)`，miss 落 `stringCall`。
- **实现**：与同族两个 handler 同形，comptime magic 为 31（按码点读，成对代理合并）；接收者非字符串或快路径返回 `null` 时落回 `stringCall`。
- **所有权 / 错误 / 调用**：同族：命中返回立即数，miss 转交 `stringCall`；自身不分配。无 TLS 环境 → 裸 `error.TypeError`。它是 codePointAt 记录（:100）的 tag-miss fallback handler。

### `stringCaseCall` (`src/exec/string_builtin_ops.zig:609`)

- **签名**：`fn stringCaseCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`toUpperCase` / `toLowerCase` 共用的记录 handler（按 magic 区分方向）。
- **实现**：`magic == to_lower_case` 决定 `to_lower`。引擎内部臂（`func_obj == null` 且 `global == null`）直接走 `unicodeCaseReceiver` 复用纯 Unicode 体，若带构造标志则 TypeError；否则解析 realm global（有 `func_obj` 时经 `callableRealm` 并断言 realm 就是当前 ctx，否则用 `host_call.global`），用 `string_ops.toStringCheckObject` 强制接收者后交 `unicodeCaseOwnedString`。
- **所有权 / 错误 / 调用**：三条腿所有权不同：引擎内部腿（`func_obj == null and global == null`）跑纯 `unicodeCaseReceiver`；JS 腿先 `toStringCheckObject`（字符串接收者原样借用返回、其余是新建串），再按文件头 `Owned` 约定把结果交给 `unicodeCaseOwnedString` 消费（无变化时原样交回同一个串，不新建）。错误：无环境、内部腿上被当构造器调用、取不到 realm global → 裸 `error.TypeError`；`toStringCheckObject` 的 TypeError 自带消息。调用点是 toUpperCase / toLowerCase 两条记录（:86-:87）。

### `stringCall` (`src/exec/string_builtin_ops.zig:643`)

- **签名**：`fn stringCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.string` 域的共享记录 handler：String 迭代器 `next`、构造、引擎内部纯体重用，以及按 id 转 `string_ops` 的 realm 相关实现。
- **实现**：`nativeCall` 组不出视图即 TypeError。id 为 `iterator_next` 时接收者必须是 `string_iterator` 类对象，转 `stringIteratorNext`；`is_constructor` 且 id 为 `ConstructorMethod.call` 时转 `constructWithPrototype(rt, args, new_target)`。`func_obj == null` 且 `global == null`（引擎内部调用约定：接收者/参数已解析、不需要 realm global）时解码 prototype method id：id 0 走 `charAtValue`（`methodCall` 不处理 id 0，下标取 args[0]），其余走 `methodCall`；这一臂刻意绕开 `string_ops.stringPrototypeMethod`，否则会再入本记录并递归。其余情况解析 realm global 后 `switch`：构造器 call → `stringFunctionCall`，`fromCharCode` / `fromCodePoint` / `raw` → 对应 `string_ops` 实现，默认解码 prototype id 后转 `stringPrototypeMethod`。
- **所有权 / 错误 / 调用**：返回值形态随 id 而变：立即数、runtime 共享串、新建串、新建对象（String 包装 / split 数组 / 迭代结果），或原样交回的接收者；本函数自己不建 GC 根，建根都在下游（`constructWithPrototype`、`split`/`splitReceiver`、`match`）。错误一路上抛给 generic_magic thunk 变异常：`decodePrototypeMethodId` 失配、非 string_iterator 接收者、缺 realm global 都是裸 `error.TypeError`，而 `string_ops.stringPrototypeMethod` 腿的消息已由 `throw*Message` 挂好。调用方：`internal_entries` 里大多数条目的 handler、四个索引/concat handler 的 miss 尾调用，以及 `string_ops.callStringBody` 经 `builtin_dispatch.callInternalRecord` 进入的 `func_obj == null and global == null` 腿。

### `thisObject` (`src/exec/string_builtin_ops.zig:716`)

- **签名**：`fn thisObject(value: core.JSValue) ?*core.Object`。
- **作用**：把 `JSValue` 当对象取 `*core.Object`，非对象或取不到 header 时返回 `null`。
- **实现**：`value.isObject()` 过滤后 `refHeader()`，再 `core.Object.fromHeader`。
- **所有权 / 错误 / 调用**：无：纯 tag 检查，返回借用的 `*Object`（不加引用、不建根）。唯一调用方 `stringCall:656`。

### `charAt` (`src/exec/string_builtin_ops.zig:722`)

- **签名**：`pub fn charAt(bytes: []const u8, index: usize) []const u8`。
- **作用**：字节缓冲版 charAt：按字节下标取单字节子切片。
- **实现**：`index >= bytes.len` 返回 `""`，否则返回 `bytes[index .. index + 1]`。
- **所有权 / 错误 / 调用**：返回的是借用自入参的切片，`bytes` 失效后不得再用；无分配、无错误。

### `toUpperAscii` (`src/exec/string_builtin_ops.zig:727`)

- **签名**：`pub fn toUpperAscii(buf: []u8, bytes: []const u8) []u8`。
- **作用**：把字节缓冲逐字节做 ASCII 大写映射（不涉及 Unicode 特例）。
- **实现**：`n = @min(buf.len, bytes.len)` 先截断，逐字节 `unicode.toUpperAscii` 写入 `buf`，返回 `buf[0..n]`。
- **所有权 / 错误 / 调用**：写调用方给的 `buf` 并返回它的前缀切片（借用，随 `buf` 失效），不分配、无 error。树内无调用方：`pub` 遗留 API（逐字节被调用的是 `unicode.toUpperAscii`）。

### `construct` (`src/exec/string_builtin_ops.zig:735`)

- **签名**：`pub fn construct(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：过渡 `new_string_object` 字节码用的窄 String 包装构造。
- **实现**：转发 `constructWithPrototype(rt, args, null)`（原型传 null）。
- **所有权 / 错误 / 调用**：只是 `constructWithPrototype(rt, args, null)` 的转发，所有权与错误全同下条。树内无调用方：`stringCall` 的 construct 腿直接调 `constructWithPrototype`，本函数留给 `new_string_object` 过渡字节码与嵌入方。

### `constructWithPrototype` (`src/exec/string_builtin_ops.zig:739`)

- **签名**：`pub fn constructWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：分配并初始化对应的 JS 对象或数组。
- **实现**：先把参数拷进 `ValueRootBuffer`，和 `data_value` / `object_value` 一起挂进 `ValueRootFrame`。首参是 Symbol 返回 TypeError；有参数时经 `stringValueFromSearchArgument` 转字符串，否则用空串，再 `ensureFlat`。随后创建 `class.ids.string` 对象、写入 `objectDataSlot`，逐码元调用 `defineStringIndexUnitProperty` 定义索引属性，最后用 `defineReadonlyIntProperty` 定义只读 `length`。
- **所有权 / 错误 / 调用**：本文件建根最密的一条：`ValueRootBuffer.initCopy` 复制并钉住 `args`，`data_value` / `object_value` 进 `ValueRootFrame`，覆盖每次建串、建对象、定义属性的分配点。返回新建的 String 包装对象；内部串写进 `objectDataSlot`，逐码元属性由 `defineStringIndexUnitProperty` 新建单码元串并交给对象持有，`length` 是不可写不可枚举不可配置。`errdefer` 只把 `object_value` 置回 undefined（失败时让新对象变垃圾，不显式销毁）。错误：Symbol 参数或内部值取不到字符串体 → 裸 `error.TypeError`。调用方：`stringCall:670`（`new String(...)` 的 construct 腿）、`construct:736`、`src/tests/exec.zig:5093`。

### `stringIteratorNext` (`src/exec/string_builtin_ops.zig:793`)

- **签名**：`pub fn stringIteratorNext(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue) !core.JSValue`。
- **作用**：String Iterator 的 `next`：按码点（含代理对）推进并产出结果对象。
- **实现**：接收者必须是 `string_iterator` 类对象；target 槽为空直接返回 done 结果，target 非字符串返回 TypeError。下标到达串长时返回 done 结果并清空 target 槽。否则读当前码元：`< 0x100` 取 runtime 的共享单字节串并前进 1（对应 qjs `js_new_string_char` 的窄臂，quickjs.c:3953-3962）；高代理且后继是低代理时取两码元 `createUtf16` 并前进 2；其余单码元 `createUtf16` 并前进 1。
- **所有权 / 错误 / 调用**：返回 `iteratorResult` 新建的 `{value, done}` 对象；`value` 是 runtime 共享单字节串（`rt.singleByteString`）或新建 UTF-16 串，随即交给结果对象持有。副作用落在迭代器对象上：推进 `iteratorIndexSlot`，done 时 `clearOptionalValueSlot` 断掉对 target 的边（屏障在 slot helper 内）。错误：接收者非对象 / 非 string_iterator / target 非字符串 → 裸 `error.TypeError`。唯一调用方 `stringCall:658`（`PrototypeMethod.iterator_next`）。

### `fromCharCode` (`src/exec/string_builtin_ops.zig:838`)

- **签名**：`pub fn fromCharCode(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：过渡字节码用的 primitive-only `String.fromCharCode`；JS 可见调用走 VM 共享实现，以保留对象强制与异常传播。
- **实现**：参数必须已是 int32，否则 TypeError（这里不做 ToNumber）。两参数走 `rt.recentTwoUnitString` 缓存（`fromCharCode(H, L)` 代理对模式）；单参数且低 16 位 ≤ 0xff 走 `rt.singleByteString`；其余情况参数数 ≤16 时用 16 项栈缓冲、更多才 `rt.memory.alloc` 堆缓冲，逐参数取低 16 位后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`pub` 遗留原语，树内无调用方（JS 可见路径走 `string_ops.stringFromCharCode`）。≤16 个参数用栈缓冲，超出才 `rt.memory.alloc` 并 defer free；返回 runtime 的单字节 / 双单元缓存串或新建 UTF-16 串。参数不是 int32 就返回裸 `error.TypeError`——它刻意不做可观察 ToNumber，这正是它服务不了 JS 调用的原因。

### `fromCodePoint` (`src/exec/string_builtin_ops.zig:873`)

- **签名**：`pub fn fromCodePoint(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`String.fromCodePoint` 的 runtime 级实现：把码点参数编码成 UTF-16 串。
- **实现**：逐参数：Symbol 返回 TypeError；`value_ops.toIntegerOrInfinity` 后 NaN / 非有限 / 负数 / 大于 0x10FFFF / 非整数都返回 RangeError；合法码点经 `unicode.appendUtf16CodePoint` 追加进 `units`，最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`pub` 遗留原语，树内无调用方。`units` 是运行时 allocator 的 ArrayList，defer deinit；返回新建 UTF-16 串。错误：Symbol 参数 → 裸 `error.TypeError`，越界/非整数码点 → 裸 `error.RangeError`（挂 "invalid code point" 消息的是 `string_ops.stringFromCodePoint`）。

### `charAtValue` (`src/exec/string_builtin_ops.zig:891`)

- **签名**：`pub fn charAtValue(rt: *core.JSRuntime, receiver: core.JSValue, index_value: core.JSValue) !core.JSValue`。
- **作用**：过渡 `string_char_at` 字节码用的窄 charAt。
- **实现**：先 `stringInteger` 取整数下标。接收者是字符串或 String 包装对象时按码元读：越界返回空串，否则 `codeUnitStringValue`；其余接收者经 `appendStringReceiverBytes` 展成 UTF-8 字节后按字节取单字节子串，越界同样是空串。
- **所有权 / 错误 / 调用**：字符串腿返回 runtime 共享单码元串或空串，非字符串腿先把接收者 ToString 进临时字节缓冲（defer deinit）再建串；两条腿的返回值都归调用方。错误来自 `stringInteger`（BigInt → 裸 TypeError）与 `appendStringReceiverBytes`（null/undefined 接收者 → 裸 `error.TypeError`）。唯一调用方 `stringCall:694`，也就是 `string_ops.callStringCharAtBody` 经记录表落到的那条腿。

### `methodCall` (`src/exec/string_builtin_ops.zig:909`)

- **签名**：`pub fn methodCall(rt: *core.JSRuntime, receiver: core.JSValue, id: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：按 method id 分发到本文件的过渡或完整实现。
- **实现**：先用一串 `if (id == …)` 把有码元级实现的方法分派到各自的 `*Receiver` 体（charCodeAt、codePointAt、trim/trimStart/trimEnd、大小写、substring、indexOf、includes/startsWith/endsWith、at、split、repeat、lastIndexOf、slice、isWellFormed、toWellFormed）；其余 id 先经 `appendStringReceiverBytes` 把接收者展成 UTF-8 字节，再 `switch` 到字节版实现（id 9 的 toString 要求无参数否则 TypeError、concat、Annex B html 系列、substr、repeat、pad、localeCompare、normalize、search、match、replaceAll）。前面已处理的 id 在 `switch` 里写成 `unreachable`，未知 id 返回 TypeError。
- **所有权 / 错误 / 调用**：自身不分配：id 命中就转发给对应的 `*Receiver` 实现；只有落到尾部 switch 的 AnnexB / pad / normalize 等 id 才先用 `appendStringReceiverBytes` 把接收者 ToString 进临时字节缓冲（defer deinit）。未覆盖的 id 返回裸 `error.TypeError`。唯一调用方 `stringCall:696`（`func_obj == null and global == null` 腿），即 `string_ops.callStringBody` 的落点。

### `concat` (`src/exec/string_builtin_ops.zig:984`)

- **签名**：`fn concat(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.concat`：接收者字节后依次追加各参数的字符串表示。
- **实现**：把 `bytes` 拷进 `out`，逐参数 `appendValueString`，最后 `createStringValue`；`out` 在返回前 `deinit`。
- **所有权 / 错误 / 调用**：`out` 临时 ArrayList defer deinit，返回 `createStringValue` 新建的串；参数经 `appendValueString`（`unwrap_wrappers = true`）转字节，可能抛 `AppendStringError`。唯一调用方 `methodCall` 的 id 10 分支。

### `substring` (`src/exec/string_builtin_ops.zig:992`)

- **签名**：`fn substring(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.substring`。
- **实现**：`stringSubstringRange` 规范化区间后切 `bytes` 建新串。
- **所有权 / 错误 / 调用**：返回新建串；`bytes` 是调用方临时缓冲的借用切片，本函数不持有。唯一调用方 `substringReceiver:1007` 的非字符串接收者回退。

### `substringReceiver` (`src/exec/string_builtin_ops.zig:997`)

- **签名**：`fn substringReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`substring` 的码元级实现：字符串 / String 包装接收者直接用 `String.createSlice` 共享底层数据。
- **实现**：取到 `*String` 时用 `stringSubstringRange(string_value.len(), args)` 得到 `[start, end)` 并 `createSlice`；其余接收者展成 UTF-8 字节后转字节版 `substring`。
- **所有权 / 错误 / 调用**：字符串腿的 `String.createSlice` 是**拷贝**成独立新串（不共享父串 payload），返回值归调用方；非字符串腿的字节缓冲 defer deinit。错误来自 `stringSubstringRange` 里的 `stringInteger`（BigInt → 裸 TypeError）与 `appendStringReceiverBytes`。唯一调用方 `methodCall`（id 1）。

### `trimReceiver` (`src/exec/string_builtin_ops.zig:1010`)

- **签名**：`fn trimReceiver(rt: *core.JSRuntime, receiver: core.JSValue, mode: TrimMode) !core.JSValue`。
- **作用**：`trim` / `trimStart` / `trimEnd` 的接收者入口（由 `mode` 区分）。
- **实现**：字符串 / String 包装接收者走码元级 `trimStringValue`；其余接收者展成 UTF-8 字节，按 mode 用 `trimStartAscii` / `trimEndAscii` / `std.mem.trim(u8, …, " \t\r\n")` 裁剪后建串。
- **所有权 / 错误 / 调用**：两条腿都返回新建串（字符串腿经 `trimStringValue`，字节腿 `createStringValue`）；字节缓冲 defer deinit，`trimStartAscii`/`mem.trim` 的结果只是它的子切片。唯一调用方 `methodCall`（id 8 / 21 / 22）。

### `trimStringValue` (`src/exec/string_builtin_ops.zig:1025`)

- **签名**：`fn trimStringValue(rt: *core.JSRuntime, string_value: *core.string.String, mode: TrimMode) !core.JSValue`。
- **作用**：码元级空白裁剪。
- **实现**：先 `ensureFlat`；按 mode 用 `isTrimCodeUnit`（ECMA 空白 + 行终止符）从头推进 `start`、从尾回退 `end`；再按 `resolveData()` 分别用 `createLatin1SliceValue` 或 `String.createUtf16` 建结果串。
- **所有权 / 错误 / 调用**：`ensureFlat` 会就地展平接收者（对 rope 的可见副作用）；随后的 `resolveData()` 切片只在建串前使用——`createLatin1SliceValue` / `String.createUtf16` 是分配点，切完即用。返回新建串。唯一调用方 `trimReceiver:1012`。

### `isWellFormedReceiver` (`src/exec/string_builtin_ops.zig:1041`)

- **签名**：`fn isWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：`String.prototype.isWellFormed` 的接收者入口。
- **实现**：字符串 / String 包装接收者走 `isWellFormedString`；其余接收者先 `appendStringReceiverBytes` 触发强制转换（null / undefined 在此抛 TypeError），然后恒返回 `true`。
- **所有权 / 错误 / 调用**：返回布尔立即数，不分配；非字符串腿仍跑一遍 `appendStringReceiverBytes`（借此复用它的 null/undefined → 裸 `error.TypeError` 检查），缓冲 defer deinit 后直接返回 true。唯一调用方 `methodCall`（id 38）。

### `toWellFormedReceiver` (`src/exec/string_builtin_ops.zig:1051`)

- **签名**：`fn toWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：`String.prototype.toWellFormed` 的接收者入口。
- **实现**：字符串 / String 包装接收者走 `toWellFormedString`；其余接收者展成 UTF-8 字节后原样建串。
- **所有权 / 错误 / 调用**：两条腿都返回新建串（字符串腿经 `toWellFormedString`，字节腿把缓冲原样建串），缓冲 defer deinit。唯一调用方 `methodCall`（id 39）。

### `isWellFormedString` (`src/exec/string_builtin_ops.zig:1061`)

- **签名**：`fn isWellFormedString(string_value: *core.string.String) bool`。
- **作用**：判断串里没有孤立代理。
- **实现**：逐码元扫描：高代理必须紧跟低代理（成对则跳 2），出现孤立高代理或孤立低代理返回 `false`，走完返回 `true`。
- **所有权 / 错误 / 调用**：无：只读遍历借用的 `*String`，不分配、无 error。唯一调用方 `isWellFormedReceiver:1043`。

### `toWellFormedString` (`src/exec/string_builtin_ops.zig:1076`)

- **签名**：`fn toWellFormedString(rt: *core.JSRuntime, string_value: *core.string.String) !core.JSValue`。
- **作用**：把孤立代理替换成 U+FFFD 的副本。
- **实现**：`ensureFlat` 后按串长预留 `units`；成对代理原样复制并跳 2，孤立高代理或孤立低代理写 0xFFFD，其余码元原样追加；最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`ensureFlat` 就地展平接收者；`units` 临时 ArrayList 预留容量后 defer deinit；返回新建 UTF-16 串。唯一调用方 `toWellFormedReceiver:1053`。

### `isHighSurrogateUnit` (`src/exec/string_builtin_ops.zig:1102`)

- **签名**：`fn isHighSurrogateUnit(unit: u16) bool`。
- **作用**：码元是否是高代理（转 `unicode` 库）。
- **实现**：薄封装，主体转发到 `unicode.isHighSurrogateUnit`。
- **所有权 / 错误 / 调用**：无：转发 `unicode` 的纯谓词，不分配无 error。本文件的码点扫描都经它（`stringPrimitiveIndexRead`、`stringCodePointAtLeaf`、`stringIteratorNext` 等 9 处）。

### `isLowSurrogateUnit` (`src/exec/string_builtin_ops.zig:1106`)

- **签名**：`fn isLowSurrogateUnit(unit: u16) bool`。
- **作用**：码元是否是低代理（转 `unicode` 库）。
- **实现**：薄封装，主体转发到 `unicode.isLowSurrogateUnit`。
- **所有权 / 错误 / 调用**：无：转发 `unicode` 的纯谓词，不分配无 error。调用点 11 处：除与 `isHighSurrogateUnit` 配对的 9 处外，`isWellFormedString:1070` 与 `toWellFormedString:1096` 还单独用它检出孤立低代理。

### `substr` (`src/exec/string_builtin_ops.zig:1110`)

- **签名**：`fn substr(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：Annex B `String.prototype.substr` 的字节版。
- **实现**：参数个数不在 1-2 返回 TypeError；`start` 为负时按 `bytes.len + start` 回绕并钳到 0、再钳到串长；第二参数缺省或 undefined 时长度取到末尾，`<= 0` 取 0；`end = @min(start + len, total)` 后切片建串。
- **所有权 / 错误 / 调用**：返回新建串，`bytes` 借用调用方缓冲。错误：参数个数不是 1-2 → 裸 `error.TypeError`；`stringInteger` 的转换可抛。唯一调用方 `methodCall`（id 25）。

### `split` (`src/exec/string_builtin_ops.zig:1127`)

- **签名**：`fn split(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.split`（非 RegExp 核心）。
- **实现**：参数与结果数组都挂进 `ValueRootFrame`。`limit` 由 `toUint32Limit` 取，缺省 `maxInt(u32)`，为 0 直接返回空数组；分隔符缺省或 undefined 时整串作为唯一元素；空分隔符按字节逐个切分；否则 `std.mem.indexOfPos` 逐段切，循环受 `limit` 约束，未到 limit 时补上最后一段。QuickJS 坐标：quickjs.c:45749-45836。
- **所有权 / 错误 / 调用**：建根覆盖整段：`ValueRootBuffer` 钉住 args、`out_value` 进 `ValueRootFrame`，因为每个 `defineStringElement` 都是「建串 + 定义属性」两个分配点。返回新建数组，元素串在 `defineValueElement` 里把所有权让渡给数组；`errdefer` 只把 `out_value` 置回 undefined。`sep` 字节缓冲 defer deinit。唯一调用方 `splitReceiver:1257` 的非字符串接收者回退（另有本文件 test）。

### `splitReceiver` (`src/exec/string_builtin_ops.zig:1189`)

- **签名**：`fn splitReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`split` 的码元级实现：避免 UTF-8 往返，结果元素是共享底层数据的切片串。
- **实现**：接收者、参数、结果、分隔符都挂进 `ValueRootFrame`。字符串 / String 包装接收者：`ensureFlat` 后建数组，`limit` 规则同 `split`（0 返回空数组、缺省分隔符时整串一项）；分隔符经 `stringValueFromSearchArgument` 转串，空分隔符按码元逐个 `codeUnitStringValue`，否则 `stringIndexOfUnits` 定位并用 `defineStringSliceElement` 建共享切片，未到 limit 时补尾段。其余接收者展成字节转 `split`。
- **所有权 / 错误 / 调用**：接收者、args、`out_value`、`sep_value` 全挂 `ValueRootFrame`（每个 `defineStringSliceElement` 都建新串）；`ensureFlat` 就地展平接收者。返回新建数组，元素串由数组持有。错误：分隔符 ToString 后取不到字符串体 → 裸 `error.TypeError`；`toUint32Limit` 的转换可抛。唯一调用方 `methodCall`（id 27），非字符串接收者转 `split`。

### `search` (`src/exec/string_builtin_ops.zig:1260`)

- **签名**：`fn search(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：过渡的字节版 `String.prototype.search`：把参数当普通字符串做子串查找，返回下标或 -1（不编译 RegExp；RegExp 语义在 `string_ops.stringSearch`）。
- **实现**：参数缺省为 undefined，经 `appendValueString` 取字符串表示作 needle，`std.mem.indexOf` 命中返回下标，否则 -1。
- **所有权 / 错误 / 调用**：返回 int32 立即数，不分配；`needle` 临时缓冲 defer deinit。唯一调用方 `methodCall`（`legacy_search_method_id`）。

### `match` (`src/exec/string_builtin_ops.zig:1269`)

- **签名**：`fn match(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：过渡的字节版 `String.prototype.match`：按普通子串查找构造匹配结果数组（不编译 RegExp；RegExp 语义在 `string_ops.stringMatch`）。
- **实现**：参数与结果都挂进 `ValueRootFrame`。参数的字符串表示作 needle，`std.mem.indexOf` 未命中返回 `null`；命中则建数组，0 号元素是命中的子串，再用 `defineIntProperty` 定义 `index`，并以 `Descriptor.data(input, true, false, true)`（可写、不可枚举、可配置）定义 `input`。
- **所有权 / 错误 / 调用**：args 与 `out_value` / `input` 挂 `ValueRootFrame`；返回新建数组，元素串、`index` 与 `input`（整串的新拷贝）都由数组持有。未命中直接返回 JS null，不建数组。`needle` 缓冲 defer deinit。唯一调用方 `methodCall`（`legacy_match_method_id`），另有本文件 test。

### `replaceAll` (`src/exec/string_builtin_ops.zig:1305`)

- **签名**：`fn replaceAll(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.replaceAll`（搜索值按普通字符串处理）。
- **实现**：search 与 replacement 都取字符串表示。search 为空串时先写一份 replacement，再在每个字节后各插一份；否则 `std.mem.indexOfPos` 循环拼接命中之间的片段与 replacement，最后补上尾段，再 `createStringValue`。
- **所有权 / 错误 / 调用**：三个临时 ArrayList（search / replacement / out）全部 defer deinit，返回新建串。唯一调用方 `methodCall`（`legacy_replace_all_method_id`）。

### `defineStringElement` (`src/exec/string_builtin_ops.zig:1337`)

- **签名**：`fn defineStringElement(rt: *core.JSRuntime, object: *core.Object, index: u32, bytes: []const u8) !void`。
- **作用**：把一段 UTF-8 字节建成字符串写进结果数组的第 `index` 个索引位；`String.prototype.split` 的纯字节路径（`split`）和 `String.prototype.match` 的结果数组第 0 项都由它填。
- **实现**：先把 `object.value()` 放进单槽 `ValueRootFrame` 并 `activate`（`defer deactivate`）——此时数组还只被本函数的局部变量持有，而下一步 `createStringValue` 会分配、可能触发 GC。建串成功后转给 `defineValueElement` 落属性。
- **所有权 / 错误 / 调用**：新串归 `object` 所有（写进属性后由数组这条边保活）；root frame 只覆盖建串窗口。错误只可能来自分配（`OutOfMemory` / `StringTooLong`）与 `defineOwnProperty`。调用方：`split`（三处分支）、`match`。

### `defineStringSliceElement` (`src/exec/string_builtin_ops.zig:1352`)

- **签名**：`fn defineStringSliceElement(rt: *core.JSRuntime, object: *core.Object, index: u32, string_value: *core.string.String, start: usize, slice_len: usize) !void`。
- **作用**：从源 `String` 上切 `[start, start + slice_len)` 建新串并写进结果数组第 `index` 位；`splitReceiver`（split 的 UTF-16 感知路径）用它产出各分段和「无分隔符」时的整串副本。
- **实现**：`rootValues(.{&object_value})` 钉住数组后 `activate` / `defer deactivate`，再 `String.createSlice(rt, string_value, start, slice_len)`。`createSlice`（`src/core/string.zig:887`）按父串的 latin1 / utf16 存储原样切一段重建，不经 UTF-8 转码，`slice_len == 0` 时返回空 ASCII 串——这是它相对 `defineStringElement` 的价值：split 分段不必先把整串拍成字节。建好的串再交 `defineValueElement`。
- **所有权 / 错误 / 调用**：源 `string_value` 只读借用，切片是新分配的独立串，定义进数组后由数组持有。调用方只有 `splitReceiver`。

### `defineValueElement` (`src/exec/string_builtin_ops.zig:1362`)

- **签名**：`fn defineValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：三个 `define*Element` 的公共尾巴——把已经建好的值按数字索引定义成 split / match 结果数组的一个元素。
- **实现**：object 与 value 一起进两槽 `rootValues` root frame（`defineOwnProperty` 可能扩容元素存储、换 shape，从而触发 GC，两边都得钉住），然后 `object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), Descriptor.data(rooted_value, true, true, true))`：writable / enumerable / configurable 全真，即 CreateDataPropertyOrThrow 的属性形状（与 String 包装对象那种不可写索引属性相反，见 `defineStringIndexUnitProperty`）。
- **所有权 / 错误 / 调用**：调用方把 value 的所有权让渡给 `object`。调用方：`defineStringElement`、`defineStringSliceElement`、`splitReceiver` 里逐码元的分支。

### `defineStringIndexUnitProperty` (`src/exec/string_builtin_ops.zig:1372`)

- **签名**：`fn defineStringIndexUnitProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void`。
- **作用**：给 String 包装对象定义一个码元索引属性。
- **实现**：把 object 挂进 root frame，单码元经 `String.createUtf16` 建串，用 `atom.atomFromUInt32(index)` 定义 `Descriptor.data(value, false, true, false)`：不可写、可枚举、不可配置，符合 String exotic 索引属性。
- **所有权 / 错误 / 调用**：把新建的单码元 UTF-16 串（这里**不**走 `rt.singleByteString` 共享表）定义成不可写不可配置的下标属性，值随即由对象持有；root frame 只钉 `object`，覆盖建串这个分配点。唯一调用方 `constructWithPrototype:776`。

### `htmlWrap` (`src/exec/string_builtin_ops.zig:1384`)

- **签名**：`inline fn htmlWrap(rt: *core.JSRuntime, bytes: []const u8, tag: []const u8) !core.JSValue`。
- **作用**：Annex B 里无属性的 HTML 包装（`<tag>str</tag>`，如 `String.prototype.bold`）。
- **实现**：薄封装，主体转发到 `htmlTagged`。
- **所有权 / 错误 / 调用**：无自身所有权：以 `attr = null` 转发 `htmlTagged`，返回值与错误全由它决定。调用方：`methodCall` 的无属性 AnnexB id（12-15、18、20、23、24、26）与本文件 test。

### `htmlWithAttribute` (`src/exec/string_builtin_ops.zig:1388`)

- **签名**：`inline fn htmlWithAttribute( rt: *core.JSRuntime, bytes: []const u8, tag: []const u8, attr: []const u8, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：Annex B 里带属性的 HTML 包装（`<tag attr="arg">str</tag>`，如 `String.prototype.anchor` / `link`）。
- **实现**：`inline`，直接 `htmlTagged(rt, bytes, tag, attr, args)`。与 `htmlWrap` 的唯一差别是 `attr` 非空，于是 `htmlTagged` 会把第一个参数转成字符串当属性值（没有参数时用字面量 `"undefined"`，多于一个参数是 `error.TypeError`），插成 `attr="..."`，其中的 `"` 由 `appendEscapedHtmlAttribute` 换成 `&quot;`；两个包装共用一条外联走法，不再各留一份 `<tag>…</tag>` 骨架。
- **所有权 / 错误 / 调用**：无自身所有权：带 `attr` 转发 `htmlTagged`。调用方：`methodCall` 的带属性 AnnexB id（11 anchor、16/17 fontcolor/fontsize、19 link）与本文件 test。

### `htmlTagged` (`src/exec/string_builtin_ops.zig:1403`)

- **签名**：`noinline fn htmlTagged( rt: *core.JSRuntime, bytes: []const u8, tag: []const u8, attr: ?[]const u8, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：Annex B HTML 包装的共用实现：拼 `<tag>…</tag>`，可选插入 `attr="…"`（`"` 转 `&quot;`）。
- **实现**：有 `attr` 时：`args.len > 1` → TypeError；有 `args[0]` 则 `appendValueString`，否则写字面 `"undefined"`（所以不能把无属性包装折叠进属性 helper，否则会注入 `attr="undefined"`）。然后拼 `<tag`，有属性则 ` attr="` + `appendEscapedHtmlAttribute` + `">`，否则 `>`；再 `bytes`、`</tag>`。`createStringValue` 交出结果。outlined leftover：`htmlWrap` / `htmlWithAttribute` 两个 `inline` 包装只传是否带 attr。
- **所有权 / 错误 / 调用**：`attr_bytes` / `out` 两个临时 ArrayList defer deinit，返回 `createStringValue` 新建的串；属性值经 `appendValueString` 转字节，`&quot;` 转义就地由 `appendEscapedHtmlAttribute` 做。错误：带属性形态给了多于 1 个参数 → 裸 `error.TypeError`。调用方：`htmlWrap`、`htmlWithAttribute`。

### `appendEscapedHtmlAttribute` (`src/exec/string_builtin_ops.zig:1440`)

- **签名**：`fn appendEscapedHtmlAttribute(rt: *core.JSRuntime, out: *std.ArrayList(u8), bytes: []const u8) !void`。
- **作用**：把属性值字节追加到输出缓冲，并把 `"` 转义成 `&quot;`。
- **实现**：逐字节：`"` 写 `&quot;`，其余原样 `append`。
- **所有权 / 错误 / 调用**：只往调用方的 `out` 追加，不分配独立缓冲、不返回值；唯一错误是 ArrayList 扩容的 `OutOfMemory`。唯一调用方 `htmlTagged:1428`。

### `trimStartAscii` (`src/exec/string_builtin_ops.zig:1478`)

- **签名**：`fn trimStartAscii(bytes: []const u8) []const u8`。
- **作用**：跳过开头的 ASCII 空白，返回借用的子切片。
- **实现**：`while (start < bytes.len and isAsciiTrim(bytes[start]))` 推进后返回 `bytes[start..]`。
- **所有权 / 错误 / 调用**：无：返回入参 `bytes` 的子切片（借用，随调用方缓冲失效），不分配无 error。唯一调用方 `trimReceiver:1018`。

### `trimEndAscii` (`src/exec/string_builtin_ops.zig:1484`)

- **签名**：`fn trimEndAscii(bytes: []const u8) []const u8`。
- **作用**：去掉结尾的 ASCII 空白，返回借用的子切片。
- **实现**：`while (end > 0 and isAsciiTrim(bytes[end - 1]))` 回退后返回 `bytes[0..end]`。
- **所有权 / 错误 / 调用**：无：同上，返回 `bytes` 的前缀借用切片。唯一调用方 `trimReceiver:1019`。

### `isAsciiTrim` (`src/exec/string_builtin_ops.zig:1490`)

- **签名**：`fn isAsciiTrim(byte: u8) bool`。
- **作用**：字节级空白谓词。
- **实现**：只认空格、`\t`、`\r`、`\n` 四个字节；码元路径用的是覆盖面更广的 `isTrimCodeUnit`。
- **所有权 / 错误 / 调用**：无：纯谓词，不分配无 error。调用方 `trimStartAscii` / `trimEndAscii`。

### `codePointAtResolved` (`src/exec/string_builtin_ops.zig:1494`)

- **签名**：`fn codePointAtResolved(data: core.string.String.ResolvedData, len: usize, index: usize) CodePointSpan`。
- **作用**：在已解析的 latin1 / utf16 切片上取一个码点及其码元区间。
- **实现**：`latin1` 分支每个字节就是一个码点（latin1 码元不可能是代理），span 是 `[index, index+1)`；`utf16` 分支在高代理且下一个是低代理时算 `0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)` 并返回 `[index, index+2)`，否则返回单码元 span。
- **所有权 / 错误 / 调用**：无：只读已解析的 `ResolvedData` 视图（借用自字符串体），返回的 `CodePointSpan` 全是标量。唯一调用方 `unicodeCaseOwnedString:1546`——那里的前提正是循环内不建串，切片才始终有效。

### `unicodeCaseReceiver` (`src/exec/string_builtin_ops.zig:1513`)

- **签名**：`fn unicodeCaseReceiver(rt: *core.JSRuntime, receiver: core.JSValue, to_lower: bool) !core.JSValue`。
- **作用**：`toLowerCase` / `toUpperCase` 的接收者入口。
- **实现**：先 `toStringValueForMethod` 把接收者转成字符串值，再交 `unicodeCaseOwnedString`。
- **所有权 / 错误 / 调用**：`toStringValueForMethod` 交回的可能是借用（字符串接收者 / 包装对象内部值）也可能是新建串，随后按 `Owned` 约定转交 `unicodeCaseOwnedString`，本函数不再持有。调用方：`stringCaseCall:621` 的引擎内部腿、`methodCall`（id 2 / 3）。

### `unicodeCaseOwnedString` (`src/exec/string_builtin_ops.zig:1518`)

- **签名**：`fn unicodeCaseOwnedString(rt: *core.JSRuntime, primitive: core.JSValue, to_lower: bool) !core.JSValue`。
- **作用**：Unicode 大小写映射本体（含希腊 Σ 词尾 ς 规则）。
- **实现**：取 `asStringBody`（拿不到返回 TypeError），`resolveData()` 只解析一次；长度为 0 直接返回入参。latin1 源先试 `String.createAsciiCaseMapped` 的纯 ASCII 快路径。其余逐码点走 `codePointAtResolved`：`to_lower` 且码点是 Σ(0x03A3) 且 `isFinalSigma` 时映射成 ς(0x03C2)，否则 `unicode.caseConvert`；输出先攒在 latin1 缓冲，一旦出现 > 0xFF 的码点就把已有内容搬进 `wide` 并改走 UTF-16（`appendUtf16CodePoint`）；最后按是否 widen 用 `String.createUtf16` 或 `String.createLatin1` 建串。
- **所有权 / 错误 / 调用**：按文件头 `Owned` 约定消费入参：空串与全 ASCII 无变化的情形把 `primitive` 原样交回（不新建），其余返回新建串。`string_value.resolveData()` 的切片在整个转换循环里被借用，而 `latin1` / `wide` 只是 allocator 上的临时 ArrayList（不是建串分配点），直到最后一次 `createUtf16` / `createLatin1` 才落盘，所以切片不会中途失效；两个缓冲 defer deinit。入参取不到字符串体 → 裸 `error.TypeError`。调用方：`stringCaseCall:640`、`unicodeCaseReceiver:1515`。

### `toStringValueForMethod` (`src/exec/string_builtin_ops.zig:1578`)

- **签名**：`fn toStringValueForMethod(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：方法内部用的 ToString：尽量返回已有的字符串值，避免多余拷贝。
- **实现**：字符串直返；String 包装对象返回内部 `objectData()`（缺失则 TypeError）；其它对象经 `appendValueString` 展成字节再建串；null / undefined 返回 TypeError；其余原始值同样展字节建串。
- **所有权 / 错误 / 调用**：字符串接收者与 String 包装的内部值是**借用返回**（不新建、不加引用），其余分支把接收者 ToString 进临时字节缓冲（defer deinit）后返回新建串。null/undefined 接收者、包装对象没有内部数据 → 裸 `error.TypeError`。唯一调用方 `unicodeCaseReceiver:1514`。

### `singleCaseMapping` (`src/exec/string_builtin_ops.zig:1598`)

- **签名**：`fn singleCaseMapping(cp: u21) unicode.CaseMapping`。
- **作用**：造一个只含单个码点的 `unicode.CaseMapping`（Σ→ς 这种定点映射用）。
- **实现**：`len = 1`、`codepoints[0] = cp`，其余槽保持 undefined。
- **所有权 / 错误 / 调用**：无：在栈上造一个单码点 `CaseMapping` 按值返回，不分配无 error。唯一调用方 `unicodeCaseOwnedString` 的 final-sigma 分支（:1552）。

### `codePointAtStringIndex` (`src/exec/string_builtin_ops.zig:1610`)

- **签名**：`fn codePointAtStringIndex(string_value: *const core.string.String, index: usize) CodePointSpan`。
- **作用**：从给定下标**向后**读一个完整码点（成对的代理对合并，否则就是单码元），并给出它的起止下标。
- **实现**：读 `index` 处的码元；若它是高代理且 `index + 1` 仍在串内、且下一个是低代理，就 `unicode.codePointFromSurrogatePair` 合成码点并给出 `end = index + 2`。其余情况按单码元返回，`end = index + 1`。返回的 `CodePointSpan` 同时带起止下标，调用方据此推进游标。
- **所有权 / 错误 / 调用**：无：只读借用的 `*const String`，返回标量 span；下标越界由调用方保证。唯一调用方 `isFinalSigma:1652`。

### `codePointBeforeStringIndex` (`src/exec/string_builtin_ops.zig:1622`)

- **签名**：`fn codePointBeforeStringIndex(string_value: *const core.string.String, end: usize) ?CodePointSpan`。
- **作用**：从给定下标**向前**读一个完整码点（低代理在前时回看一格合并），`end == 0` 返回 `null`。
- **实现**：`end == 0` 返回 `null`。取 `end - 1` 处的码元；若它是低代理且前面还有一格、且那一格是高代理，就合成码点并把 `start` 退到 `end - 2`。其余按单码元返回。与 `codePointAtStringIndex` 镜像，供 `isFinalSigma` 向前扫描词尾 Σ 的上下文使用（树内没有别的反向遍历用它）。
- **所有权 / 错误 / 调用**：无：只读借用的 `*const String`，`end == 0` 返回 `null` 而不是越界。唯一调用方 `isFinalSigma:1643`。

### `appendUtf16CodePoint` (`src/exec/string_builtin_ops.zig:1636`)

- **签名**：`fn appendUtf16CodePoint(rt: *core.JSRuntime, units: *std.ArrayList(u16), cp: u21) !void`。
- **作用**：把码点、字符串或值追加到缓冲。
- **实现**：薄封装，主体转发到 `unicode.appendUtf16CodePoint`。
- **所有权 / 错误 / 调用**：无自身所有权：把 `rt.memory.allocator` 交给 `unicode.appendUtf16CodePoint`，往调用方的 `units` 追加，唯一错误是扩容 `OutOfMemory`。唯一调用方 `unicodeCaseOwnedString:1566`。

### `isFinalSigma` (`src/exec/string_builtin_ops.zig:1640`)

- **签名**：`fn isFinalSigma(string_value: *const core.string.String, sigma_start: usize, after_sigma: usize) bool`。
- **作用**：判断某个 Σ 是否处于词尾（决定映射成 ς 还是 σ）。
- **实现**：先向前用 `codePointBeforeStringIndex` 跳过 case-ignorable 码点：必须先遇到 cased 码点，遇到非 cased 或走到串头返回 `false`。再向后用 `codePointAtStringIndex` 跳过 case-ignorable：遇到 cased 返回 `false`，走到串尾返回 `true`。
- **所有权 / 错误 / 调用**：无：只读扫描借用的 `*const String`，不分配无 error。唯一调用方 `unicodeCaseOwnedString:1551`（仅 to_lower 且码点为 Σ 时才进）。

### `indexOf` (`src/exec/string_builtin_ops.zig:1660`)

- **签名**：`fn indexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.indexOf`。
- **实现**：参数个数不在 1-2 返回 TypeError；needle 取 args[0] 的字符串表示；有第二参数时经 `stringSearchStart` 规范起点；`std.mem.indexOfPos` 命中返回下标，否则 -1。
- **所有权 / 错误 / 调用**：返回 int32 立即数；`needle` 临时缓冲 defer deinit。错误：参数个数不是 1-2 → 裸 `error.TypeError`，`stringSearchStart` 的转换可抛。唯一调用方 `indexOfReceiver:1682` 的字节回退腿。

### `indexOfReceiver` (`src/exec/string_builtin_ops.zig:1670`)

- **签名**：`fn indexOfReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`indexOf` 的码元级实现。
- **实现**：字符串 / String 包装接收者：needle 经 `stringValueFromSearchArgument`（取不到串体则 TypeError），起点经 `stringSearchStart`，用 `stringIndexOfUnits` 查，未命中返回 -1；其余接收者展成 UTF-8 字节后转字节版 `indexOf`（参数个数检查也在那边）。
- **所有权 / 错误 / 调用**：字符串腿几乎全是借用：`stringValueFromSearchArgument` 对字符串参数直接交回原值（非字符串才新建串），`stringIndexOfUnits` 只读两个体的 `resolveData()` 切片，返回 int32 立即数。这条腿不建根——`stringSearchStart` 走的是裸 runtime 的 `toIntegerOrInfinity`，不会回调用户代码。错误同 `indexOf`。唯一调用方 `methodCall`（id 4）。

### `lastIndexOf` (`src/exec/string_builtin_ops.zig:1685`)

- **签名**：`fn lastIndexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.lastIndexOf`。
- **实现**：参数个数不在 1-2 返回 TypeError；默认起点是 `bytes.len - needle.len`（needle 更长则 0），第二参数非 undefined 时经 `stringLastSearchStart` 规范；空 needle 直接返回起点，needle 比串长返回 -1；否则从 `@min(start, default_start)` 起倒序逐位 `std.mem.eql` 比较，命中返回下标，走完返回 -1。
- **所有权 / 错误 / 调用**：返回 int32 立即数；`needle` 缓冲 defer deinit。错误：参数个数不是 1-2 → 裸 `error.TypeError`，`stringLastSearchStart` 的转换可抛。唯一调用方 `lastIndexOfReceiver:1735` 的字节回退腿。

### `lastIndexOfReceiver` (`src/exec/string_builtin_ops.zig:1709`)

- **签名**：`fn lastIndexOfReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`lastIndexOf` 的码元级实现。
- **实现**：字符串 / String 包装接收者：needle 经 `stringValueFromSearchArgument`；空 needle 返回规范化后的起点（默认取串长）；needle 比串长返回 -1；否则默认起点取 `len - needle.len()`，第二参数非 undefined 时经 `stringLastSearchStart` 规范，再交 `stringLastIndexOfUnits`。其余接收者展成字节走 `lastIndexOf`。
- **所有权 / 错误 / 调用**：与 `indexOfReceiver` 同形：needle 为字符串时借用原值，比较只读 `resolveData()` 切片，返回 int32 立即数，不建根。唯一调用方 `methodCall`（id 28）。

### `charCodeAtReceiver` (`src/exec/string_builtin_ops.zig:1738`)

- **签名**：`fn charCodeAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`charCodeAt` 的接收者版：接收者必须是字符串或 String 包装对象。
- **实现**：`stringPrimitiveValue` 取字符串原始值（否则 TypeError），`stringInteger` 取下标（缺省 0）；越界返回 NaN（`JSValue.float64`），否则返回码元 int32。
- **所有权 / 错误 / 调用**：返回立即数（码元或 NaN），不分配；接收者不是字符串/String 包装时由 `stringPrimitiveValue` 返回裸 `error.TypeError`（函数体内不直接 return error），`stringInteger` 的转换可抛。唯一调用方 `methodCall`（id 29）。

### `codePointAtReceiver` (`src/exec/string_builtin_ops.zig:1745`)

- **签名**：`fn codePointAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`codePointAt` 的接收者版：命中高代理且后继是低代理时合成码点。
- **实现**：`stringPrimitiveValue` 取字符串原始值，`stringInteger` 取下标（缺省 0）；越界返回 undefined；读码元后若是高代理且后一个是低代理则 `unicode.codePointFromSurrogatePair` 合成，否则返回该码元。
- **所有权 / 错误 / 调用**：返回立即数（码点 int32 或 undefined），不分配；`stringPrimitiveValue` 交回的是借用的接收者/包装内部值。错误同 `charCodeAtReceiver`。唯一调用方 `methodCall`（id 31）。

### `at` (`src/exec/string_builtin_ops.zig:1760`)

- **签名**：`fn at(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.at`（支持负下标）。
- **实现**：`stringInteger` 取相对下标（缺省 0），负值按 `len + relative` 回绕；落在 `[0, len)` 外返回 undefined，否则返回单字节子串。
- **所有权 / 错误 / 调用**：返回新建串或 undefined 立即数；`bytes` 借用调用方缓冲。唯一调用方 `atReceiver:1780` 的字节回退腿。

### `atReceiver` (`src/exec/string_builtin_ops.zig:1768`)

- **签名**：`fn atReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`at` 的码元级实现。
- **实现**：字符串 / String 包装接收者按码元取：负下标回绕，越界返回 undefined，命中走 `codeUnitStringValue`；其余接收者展成字节走字节版 `at`。
- **所有权 / 错误 / 调用**：字符串腿经 `codeUnitStringValue` 返回 runtime 共享单字节串或新建 UTF-16 串；字节腿缓冲 defer deinit 后转 `at`。唯一调用方 `methodCall`（id 30）。

### `slice` (`src/exec/string_builtin_ops.zig:1783`)

- **签名**：`fn slice(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.slice`。
- **实现**：起止经 `stringInteger`（`end` 缺省或 undefined 时取串长）；负值按 `len + x` 回绕并钳到 0，正值钳到 `len`；`end < start` 时取 `end = start`（空串）；最后切片建串。
- **所有权 / 错误 / 调用**：返回新建串，`bytes` 借用调用方缓冲；区间夹紧在本函数内做（不复用 `stringSliceRange`）。唯一调用方 `sliceReceiver:1803` 的字节回退腿。

### `sliceReceiver` (`src/exec/string_builtin_ops.zig:1793`)

- **签名**：`fn sliceReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`slice` 的码元级实现：用 `String.createSlice` 共享底层数据。
- **实现**：字符串 / String 包装接收者经 `stringSliceRange` 得区间后 `createSlice`；其余接收者展成字节走字节版 `slice`。
- **所有权 / 错误 / 调用**：字符串腿的 `String.createSlice` 拷贝成独立新串归调用方；字节腿缓冲 defer deinit。错误来自 `stringSliceRange` 的 `stringInteger` 与 `appendStringReceiverBytes`。唯一调用方 `methodCall`（id 32）。

### `stringSubstringRange` (`src/exec/string_builtin_ops.zig:1811`)

- **签名**：`fn stringSubstringRange(rt: *core.JSRuntime, len_usize: usize, args: []const core.JSValue) !StringSliceRange`。
- **作用**：`substring` 的区间规范化。
- **实现**：两端各经 `stringInteger`（`end` 缺省或 undefined 时取长度），各自钳进 `[0, len]`，再返回 `{ .start = @min(start, end), .end = @max(start, end) }`——即两端会互换以保证 `start <= end`。
- **所有权 / 错误 / 调用**：无：只算区间标量，不分配不建根；唯一 error 来自 `stringInteger`（BigInt → 裸 `error.TypeError`）。调用方：`substring:993`、`substringReceiver:999`。

### `stringSliceRange` (`src/exec/string_builtin_ops.zig:1820`)

- **签名**：`fn stringSliceRange(rt: *core.JSRuntime, len_usize: usize, args: []const core.JSValue) !StringSliceRange`。
- **作用**：`slice` 的区间规范化。
- **实现**：两端经 `stringInteger` 后，负值按 `len + x` 回绕并钳到 0、正值钳到 `len`；`end < start` 时收成空区间（`end = start`，不互换）。
- **所有权 / 错误 / 调用**：无：同上，区别是负下标回绕而不是夹到 0 后再排序。唯一调用方 `sliceReceiver:1795`。

### `repeatReceiver` (`src/exec/string_builtin_ops.zig:1839`)

- **签名**：`fn repeatReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`repeat` 的 resolve-once 实现：借用接收者已展平的码元，按 `count * unit_len` 一次预分配。
- **实现**：非字符串 / 包装接收者展成字节回退字节版 `repeat`。`count` 经 `stringInteger`，落在 `[0, 2^31-1]` 之外返回 RangeError；`ensureFlat` 后码元数或 count 为 0 返回空串；`total` 由 `std.math.mul` 算（溢出即报错），超过 `core.string.max_length` 返回 InvalidLength；latin1 与 utf16 各自分配临时缓冲逐段 `@memcpy` 平铺后建串。QuickJS 坐标：quickjs.c:46371。
- **所有权 / 错误 / 调用**：`ensureFlat` 就地展平接收者；结果缓冲是 `rt.memory.allocator.alloc` 的原始内存（defer free），memcpy 完再建串，新串归调用方。错误：count 越界 → 裸 `error.RangeError`，总长超 `max_length` → 裸 `error.InvalidLength`；消息由 `string_ops.stringNumericArgsMethod:3839` / `stringPrototypeMethod:2054` 的 catch 补成 "invalid repeat count" / "invalid string length"——`InvalidLength` 不在 `runtimeErrorInfo` 表里，少了这层就会退化成 `Error: InvalidLength`。唯一调用方 `methodCall`（id 33）。

### `repeat` (`src/exec/string_builtin_ops.zig:1877`)

- **签名**：`fn repeat(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：字节版 `String.prototype.repeat`。
- **实现**：`count` 经 `stringInteger`，落在 `[0, 2^31-1]` 之外返回 RangeError（与 `repeatReceiver` 同一套 qjs 检查）；空串或 count 为 0 返回空串；`total` 由 `std.math.mul` 算，超过 `core.string.max_length` 返回 InvalidLength；否则分配 `total` 字节逐段 `@memcpy` 后建串。QuickJS 坐标：quickjs.c:46371。
- **所有权 / 错误 / 调用**：与 `repeatReceiver` 同一套错误与缓冲约定（原始 `alloc` + defer free，返回新建串）。唯一调用方 `repeatReceiver:1844` 的非字符串接收者回退——`methodCall` 尾部 switch 的 `33` 分支被前面 `id == 33` 的早退拦住，永远走不到。

### `pad` (`src/exec/string_builtin_ops.zig:1894`)

- **签名**：`fn pad(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue, side: PadSide) !core.JSValue`。
- **作用**：字节版 `padStart` / `padEnd`（由 `side` 区分）。
- **实现**：目标长度经 `stringInteger`，不大于当前字节长度时直接返回原串；填充串缺省为一个空格，显式给出的空串同样返回原串；否则分配 `target_len` 字节，按 side 用 `fill.items[index % fill.items.len]` 循环填充，另一侧 `@memcpy` 原文。
- **所有权 / 错误 / 调用**：`fill` 临时 ArrayList 与 `out` 原始缓冲都在返回前释放，返回新建串；`target_len <= bytes.len` 或填充串为空时把源字节原样建串返回。唯一调用方 `methodCall` 的 id 34 / 35 分支（JS 可见的 padStart/padEnd 实际走 exec 的 `string_ops.stringPad`）。

### `localeCompare` (`src/exec/string_builtin_ops.zig:1925`)

- **签名**：`fn localeCompare(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：`localeCompare` 的过渡实现：按字节序比较，不接 ICU / locale。
- **实现**：参数（缺省 undefined）取字符串表示后 `std.mem.order`，映射成 -1 / 0 / 1。
- **所有权 / 错误 / 调用**：返回 int32 立即数；`other` 缓冲 defer deinit。唯一调用方 `methodCall`（id 36）。

### `normalize` (`src/exec/string_builtin_ops.zig:1938`)

- **签名**：`fn normalize(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue`。
- **作用**：`String.prototype.normalize` 的过渡实现：只校验 form 参数，不做实际规范化。
- **实现**：有非 undefined 的 form 参数时必须是 `NFC` / `NFD` / `NFKC` / `NFKD` 之一，否则 RangeError；随后把接收者字节原样建串返回。
- **所有权 / 错误 / 调用**：返回把 `bytes` 原样建回的新串（不做真正规范化）；`form` 缓冲 defer deinit；未知 form → 裸 `error.RangeError`（挂 "bad normalization form" 消息的是 `string_ops.stringNormalize`）。唯一调用方 `methodCall`（`legacy_normalize_method_id`）。

### `contains` (`src/exec/string_builtin_ops.zig:1953`)

- **签名**：`fn contains(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue, mode: StringContainsMode) !core.JSValue`。
- **作用**：`includes` / `startsWith` / `endsWith` 的字节版（由 `mode` 区分）。
- **实现**：参数个数不在 1-2 返回 TypeError；needle 取字符串表示，位置参数经 `stringSearchStart`。contains 用 `std.mem.indexOfPos`；starts 用 `std.mem.startsWith(bytes[pos..])`；ends 的终点取显式位置参数（非 undefined 时）或串长，needle 比终点长直接 false，否则比较结尾等长片段。
- **所有权 / 错误 / 调用**：返回布尔立即数；`needle` 缓冲 defer deinit；参数个数不是 1-2 → 裸 `error.TypeError`。唯一调用方 `containsReceiver:1991` 的字节回退腿。

### `containsReceiver` (`src/exec/string_builtin_ops.zig:1971`)

- **签名**：`fn containsReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue, mode: StringContainsMode) !core.JSValue`。
- **作用**：`includes` / `startsWith` / `endsWith` 的码元级实现。
- **实现**：字符串 / String 包装接收者：needle 经 `stringValueFromSearchArgument`（取不到串体 TypeError），位置经 `stringSearchStart`；contains 用 `stringIndexOfUnits`，starts 用 `stringMatchesAtUnits(…, pos)`，ends 取终点（显式位置或串长）后比 `end - needle.len()` 处。其余接收者展成字节走字节版 `contains`（参数个数检查在那边）。
- **所有权 / 错误 / 调用**：字符串腿只借用两个字符串体的 `resolveData()` 切片比较，返回布尔立即数，不分配不建根；needle 是字符串时 `stringValueFromSearchArgument` 直接交回原值。唯一调用方 `methodCall`（id 5 / 6 / 7）。

### `appendStringReceiverBytes` (`src/exec/string_builtin_ops.zig:1994`)

- **签名**：`fn appendStringReceiverBytes(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), target: core.JSValue) !void`。
- **作用**：把字符串方法接收者转换并追加到字节缓冲。
- **实现**：字符串直接走 `core.string.appendValueUtf8`；String 包装对象取内部值，其他非 null/undefined 值走本文件的 `appendValueString`。null/undefined 或缺少包装内部值返回 TypeError。
- **所有权 / 错误 / 调用**：不返回 JSValue、不分配自己的缓冲：只借用 `target` 并往调用方的 `buffer` 追加（缓冲的 defer deinit 归调用方）。错误：`target` 是 null/undefined、或 String 包装对象取不到 `objectData()` → 裸 `error.TypeError`（这也是各 `*Receiver` 复用它做 null/undefined 校验的原因），其余是 `AppendStringError`（ToString 与 ArrayList 扩容）的透传。调用方是本文件所有非字符串接收者的字节回退腿，共 13 处（`charAtValue:900`、`methodCall:932`、`substringReceiver:1006`、`trimReceiver:1016`、`isWellFormedReceiver:1047`、`toWellFormedReceiver:1057`、`splitReceiver:1256`、`indexOfReceiver:1681`、`lastIndexOfReceiver:1734`、`atReceiver:1779`、`sliceReceiver:1802`、`repeatReceiver:1843`、`containsReceiver:1990`）。

### `stringValueFromSearchArgument` (`src/exec/string_builtin_ops.zig:2015`)

- **签名**：`fn stringValueFromSearchArgument(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：搜索 / 分隔参数的 ToString：已是字符串就原样返回，否则展成字节再建串。
- **实现**：`value.isString()` 直返；否则 `appendValueString` 展成 UTF-8 字节后 `createStringValue`。
- **所有权 / 错误 / 调用**：字符串入参是借用返回（同一个值），其它分支把它 ToString 进临时缓冲（defer deinit）后返回新建串。调用方：`constructWithPrototype:761`、`splitReceiver:1227`、`indexOfReceiver:1672` 等 5 处。

### `stringMatchesAtResolved` (`src/exec/string_builtin_ops.zig:2023`)

- **签名**：`fn stringMatchesAtResolved( haystack: core.string.String.ResolvedData, needle: core.string.String.ResolvedData, hlen: usize, nlen: usize, start: usize, ) bool`。
- **作用**：在两个已解析的码元切片上做定点比较。
- **实现**：`start > hlen` 或 `nlen > hlen - start` 返回 `false`；否则逐码元用 `resolvedUnitAt` 比较，全等返回 `true`。
- **所有权 / 错误 / 调用**：无：只比较两个借用视图，不分配无 error；起点越界由开头的 `start > hlen` 判断兜住。调用方：`stringMatchesAtUnits`、`stringLastIndexOfUnits:2092`。

### `stringMatchesAtUnits` (`src/exec/string_builtin_ops.zig:2041`)

- **签名**：`fn stringMatchesAtUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) bool`。
- **作用**：`startsWith` / `endsWith` 的一次性 resolve 包装。
- **实现**：把两串各 `resolveData()` 一次（把 slice/rope 父链遍历提出逐字符循环）后转 `stringMatchesAtResolved`。
- **所有权 / 错误 / 调用**：无：把两个字符串体 `resolveData()` 成扁平切片再交给 `stringMatchesAtResolved`，不分配无 error。唯一调用方 `containsReceiver`（starts / ends 两臂）。

### `resolvedUnitAt` (`src/exec/string_builtin_ops.zig:2045`)

- **签名**：`inline fn resolvedUnitAt(data: core.string.String.ResolvedData, i: usize) u16`。
- **作用**：从已解析的 latin1 / utf16 切片取第 i 个码元。
- **实现**：`switch` 两个分支：latin1 取字节（零扩展成 u16），utf16 直接取码元。
- **所有权 / 错误 / 调用**：无：对借用视图的一次索引，不分配无 error，边界由调用方保证。调用方：`stringMatchesAtResolved`、`stringIndexOfUnits`、`stringLastIndexOfUnits`。

### `stringIndexOfUnits` (`src/exec/string_builtin_ops.zig:2052`)

- **签名**：`fn stringIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize`。
- **作用**：码元级 indexOf：两串各 resolve 一次 + 首码元跳过。
- **实现**：`start > hlen` 返回 `null`；空 needle 返回 `start`；`nlen > hlen - start` 返回 `null`。随后把两串各 `resolveData()` 一次，从 `start` 扫到 `hlen - nlen`，首码元不等直接跳过，相等再逐码元比；循环里不分配，解析出的切片全程有效。QuickJS 坐标：quickjs.c:45553。
- **所有权 / 错误 / 调用**：返回下标不涉及所有权；两个 `resolveData()` 切片在整个扫描循环里被借用，而循环内没有任何分配，所以切片全程有效（源码注释点明了这一点）。调用方：`splitReceiver:1243`、`indexOfReceiver:1675`、`containsReceiver:1977`。

### `stringLastIndexOfUnits` (`src/exec/string_builtin_ops.zig:2077`)

- **签名**：`fn stringLastIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize`。
- **作用**：码元级 lastIndexOf：两串各 resolve 一次 + 首码元跳过。
- **实现**：空 needle 返回 `@min(start, hlen)`；needle 比串长返回 `null`；否则两串各 `resolveData()` 一次，从 `@min(start, hlen - nlen)` 倒序扫描，首码元命中后再用 `stringMatchesAtResolved` 全比。
- **所有权 / 错误 / 调用**：同上：解析一次两个扁平切片，循环内零分配，返回下标。唯一调用方 `lastIndexOfReceiver:1728`。

### `codeUnitStringValue` (`src/exec/string_builtin_ops.zig:2100`)

- **签名**：`fn codeUnitStringValue(rt: *core.JSRuntime, unit: u16) !core.JSValue`。
- **作用**：单码元结果串（`charAt` / `at` / 包装对象索引读用）。
- **实现**：`unit < 0x100` 时取 runtime 的共享单字节串（零分配，对应 qjs `js_new_string_char` 的窄臂），否则 `String.createUtf16` 建单码元串。
- **所有权 / 错误 / 调用**：`< 0x100` 返回 runtime 单字节串表的**共享**项（`rt.singleByteString`，runtime 拥有，调用方不释放、不得改写），否则返回新建 UTF-16 串。调用方：`stringPrimitiveIndexRead:323`、`charAtValue:895`、`atReceiver:1774` 等 4 处。

### `createLatin1SliceValue` (`src/exec/string_builtin_ops.zig:2105`)

- **签名**：`fn createLatin1SliceValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：由 latin1 字节建一个新的字符串值。
- **实现**：`String.createLatin1(rt, bytes)` 后取 `.value()`。
- **所有权 / 错误 / 调用**：把借用的 latin1 切片**拷贝**成新串返回（`String.createLatin1` 不共享入参内存）。调用方：`trimStringValue:1036`、`repeatReceiver:1865`。

### `stringPrimitiveValue` (`src/exec/string_builtin_ops.zig:2110`)

- **签名**：`fn stringPrimitiveValue(value: core.JSValue) !core.JSValue`。
- **作用**：取接收者的字符串原始值：字符串直返，String 包装对象取内部值，其余 TypeError。
- **实现**：`value.isString()` 直返；否则 `expectObject` 后要求 `class_id == class.ids.string`，取 `objectData()`，缺失同样 TypeError。
- **所有权 / 错误 / 调用**：返回借用值（接收者自身或 String 包装的内部数据），不新建、不加引用。非字符串且非 String 包装 → 裸 `error.TypeError`。调用方：`charCodeAtReceiver:1739`、`codePointAtReceiver:1746`。

### `stringValueFromReceiver` (`src/exec/string_builtin_ops.zig:2117`)

- **签名**：`pub fn stringValueFromReceiver(value: core.JSValue) ?*core.string.String`。
- **作用**：取接收者的 `*String` 体：只有字符串和 String 包装对象有值，其余返回 `null`。
- **实现**：`stringValueFromReceiverRaw` 后取 `asStringBody()`。
- **所有权 / 错误 / 调用**：返回借用的 `*String`（不加引用、不建根）；`null` 表示调用方该走非字符串接收者的回退腿。调用方：本文件 10 个 `*Receiver` 实现（substring/trim/isWellFormed/toWellFormed/split/indexOf/lastIndexOf/slice/repeat/contains）与 `constructWithPrototype:764`，另有本文件 test。

### `stringValueFromReceiverRaw` (`src/exec/string_builtin_ops.zig:2122`)

- **签名**：`fn stringValueFromReceiverRaw(value: core.JSValue) ?core.JSValue`。
- **作用**：同 `stringValueFromReceiver`，但返回未取串体的 `JSValue`。
- **实现**：字符串直返；对象必须 `expectObject` 成功且 `class_id == class.ids.string` 并有 `objectData()`，否则返回 `null`；其余标签一律 `null`。
- **所有权 / 错误 / 调用**：返回借用的 `JSValue`（接收者自身或包装对象的 `objectData()`），不新增引用。调用方：`charAtValue:893`、`atReceiver:1769`、`stringValueFromReceiver:2118`。

### `iteratorResult` (`src/exec/string_builtin_ops.zig:2135`)

- **签名**：`fn iteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue`。
- **作用**：建 `{ value, done }` 迭代结果对象的自有包装。
- **实现**：转发 `iterator_ops.createIteratorResult`。
- **所有权 / 错误 / 调用**：按文件内注释的单 owner 约定：调用方把 `value` 的所有权交给它，结果对象持有该值并归调用方。唯一调用方 `stringIteratorNext`（五处：`:796`/`:800` 两条 done 分支与 `:816`/`:825`/`:832` 三条非 done 分支），另有本文件的 GC 根测试（`:2157`）。

### `defineIntProperty` (`src/exec/string_builtin_ops.zig:2215`)

- **签名**：`fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: i32) !void`。
- **作用**：在对象上定义可写 / 可枚举 / 可配置的整数数据属性（如 match 结果的 `index`）。
- **实现**：把 object 放进单槽 root frame 并 `activate` / `defer deactivate`（`defineOwnProperty` 可能扩容换 shape 触发 GC），然后 `defineOwnProperty(rt, key, Descriptor.data(JSValue.int32(value), true, true, true))`：writable / enumerable / configurable 三真，即 CreateDataProperty 的形状。
- **所有权 / 错误 / 调用**：root frame 只钉 `object`（值是 int32 立即数，无需建根），属性写完由对象持有。唯一调用方 `match:1298`（`index` 属性）。

### `defineReadonlyIntProperty` (`src/exec/string_builtin_ops.zig:2224`)

- **签名**：`fn defineReadonlyIntProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: i32) !void`。
- **作用**：在对象上定义不可写 / 不可枚举 / 不可配置的整数数据属性（String 包装对象的 `length`）。
- **实现**：与 `defineIntProperty` 只差描述符标志：`Descriptor.data(JSValue.int32(value), false, false, false)`，不可写 / 不可枚举 / 不可配置——String 包装对象的 `length` 就是这种 exotic 形状。root frame 的用法相同。
- **所有权 / 错误 / 调用**：同 `defineIntProperty`，但描述符是不可写/不可枚举/不可配置。唯一调用方 `constructWithPrototype:778`（String 包装的 `length`）。

### `stringSearchStart` (`src/exec/string_builtin_ops.zig:2233`)

- **签名**：`fn stringSearchStart(rt: *core.JSRuntime, length: usize, value: core.JSValue) !usize`。
- **作用**：把搜索起点参数规范成 `[0, length]` 内的下标。
- **实现**：`value_ops.toIntegerOrInfinity` 后：NaN 或 `<= 0` 返回 0；`+∞` 返回 `length`；截断值 `>= length` 返回 `length`；否则 `@intFromFloat`。
- **所有权 / 错误 / 调用**：无：走裸 runtime 的 `value_ops.toIntegerOrInfinity`（不会回调用户代码），返回夹到 `[0, length]` 的下标；BigInt 参数 → 裸 `error.TypeError`。调用方：`indexOf`、`indexOfReceiver`、`contains`、`containsReceiver`。

### `stringLastSearchStart` (`src/exec/string_builtin_ops.zig:2242`)

- **签名**：`fn stringLastSearchStart(rt: *core.JSRuntime, default_start: usize, value: core.JSValue) !usize`。
- **作用**：把 `lastIndexOf` 的起点参数规范到 `[0, default_start]`。
- **实现**：`value_ops.toIntegerOrInfinity` 后：NaN 或 `+∞` 返回 `default_start`；`<= 0` 返回 0；截断值 `>= default_start` 返回 `default_start`；否则 `@intFromFloat`。
- **所有权 / 错误 / 调用**：无：同上，区别是 NaN / +Inf 都回到 `default_start`。调用方：`lastIndexOf:1693` 一处与 `lastIndexOfReceiver:1716`/`:1725` 两处。

### `toUint32Limit` (`src/exec/string_builtin_ops.zig:2252`)

- **签名**：`fn toUint32Limit(rt: *core.JSRuntime, value: core.JSValue) !u32`。
- **作用**：`split` 的 `limit` 参数 ToUint32。
- **实现**：BigInt 或 Symbol 返回 TypeError；`value_ops.toIntegerOrInfinity` 后 NaN / 非有限 / 0 都返回 0；否则向零取整再对 `4294967296.0` 取模。
- **所有权 / 错误 / 调用**：无分配；BigInt / Symbol → 裸 `error.TypeError`，其余经裸 runtime 的 `toIntegerOrInfinity` 取模到 u32。调用方：`split:1152`、`splitReceiver:1217`（split 的 limit 参数）。

### `stringInteger` (`src/exec/string_builtin_ops.zig:2261`)

- **签名**：`fn stringInteger(rt: *core.JSRuntime, value: core.JSValue) !i64`。
- **作用**：字符串方法用的 ToIntegerOrInfinity：返回饱和到 i64 的整数下标。
- **实现**：int32 立即数直返；否则 `value_ops.toIntegerOrInfinity`，NaN 返回 0，`+∞` / `-∞` 饱和到 `maxInt(i64)` / `minInt(i64)`，其余向零取整后 `@intFromFloat`。
- **所有权 / 错误 / 调用**：无分配、不建根；int32 直返，其余走裸 runtime 的 `toIntegerOrInfinity`（BigInt → 裸 `error.TypeError`），±Inf 饱和到 i64 边界。本文件所有取数值参数的实现都用它（16 处）。

### `isTrimCodeUnit` (`src/exec/string_builtin_ops.zig:2272`)

- **签名**：`fn isTrimCodeUnit(unit: u16) bool`。
- **作用**：码元级空白谓词：ECMA 空白或行终止符。
- **实现**：薄封装，主体转发到 `unicode.isEcmaWhitespaceOrLineTerminatorUnit`。
- **所有权 / 错误 / 调用**：无：转发 `unicode.isEcmaWhitespaceOrLineTerminatorUnit` 的纯谓词。唯一调用方 `trimStringValue`。

### `appendValueString` (`src/exec/string_builtin_ops.zig:2277`)

- **签名**：`fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void`。
- **作用**：把给定值的字符串表示追加到调用方的字节缓冲。
- **实现**：转发到 `core.value_string.appendValueString`，启用 `.unwrap_wrappers = true`；`std.ArrayList(u8)` 是参数类型，不是运行时调用。
- **所有权 / 错误 / 调用**：借用输入值并修改调用方的 buffer，不返回 `JSValue`。转换或扩容错误通过 `AppendStringError` 传播；缓冲的清理由调用方负责。

## 覆盖核对

- 清单函数数: 111
- 本文标题覆盖: 111
- 未覆盖: 无
