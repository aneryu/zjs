# 17 — 强制转换、值运算、Error、Function、print

`value_ops` 是无 realm 的算术核；`coercion_ops` 带 ToPrimitive。Error 构造统一抓栈；OOM 用预分配对象。Function.call/apply 有 forwarding 记录。`exceptions.zig` 无函数，只 re-export `RuntimeError`/`HostError`。



## `src/exec/value_ops.zig` — 包装类型与 Symbol 静态

`.primitive` id = `class_tag * 10 + method`（1 Number … 5 String）。方法 1/2 是 toString/valueOf，3 是构造器当函数，4/5 是 Symbol description / @@toPrimitive；6+ 是 BigInt.asIntN/asUintN、Symbol.for/keyFor。


### `toString` (`src/exec/value_ops.zig:20`)

- **签名**：`pub fn toString(value: bool) []const u8`。
- **作用**：布尔到 `"true"` / `"false"` 切片（静态字面量）。
- **实现**：`if (value) "true" else "false"`。
- **所有权 / 错误 / 调用**：返回静态字符串，无分配。

### `primitiveId` (`src/exec/value_ops.zig:40`)

- **签名**：`fn primitiveId(comptime tag: Tag, comptime method: u32) u32`。
- **作用**：编码 `.primitive` 记录 id：`tag * 10 + method`。
- **实现**：class tag 1..5 对应 Number..String。
- **所有权 / 错误 / 调用**：无：comptime 纯算术，不分配、无 error set。调用方全在本文件的静态表构造（`src/exec/value_ops.zig:50-64` 的 `primitiveEntry`、`:88`/`:89`/`:102`/`:103` 的 id 常量）。

### `primitiveEntry` (`src/exec/value_ops.zig:110`)

- **签名**：`fn primitiveEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，为 `.primitive` domain 的**实例侧**记录生成 `InternalEntry`：Boolean/BigInt/String 原型的 `toString` + `valueOf`、Number 原型的 `valueOf`（它的 `toString` 在 `.number` domain）、Symbol 原型的 `toString`/`valueOf`/`get description`/`[Symbol.toPrimitive]`，以及 `Boolean(x)` / `Symbol(x)` 这种把包装构造器当普通函数调用的条目。
- **实现**：`.id` 与 `.magic` 都取传入 id，`cproto` 固定 `.generic_magic`，`native_function` 是 `genericMagicFunction(&primitiveCall)`。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项，无运行期分配；`name` 是字符串字面量。

### `primitiveCall` (`src/exec/value_ops.zig:124`)

- **签名**：`pub fn primitiveCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.primitive` 原型方法共享 handler：转到 `object_ops.primitivePrototypeMethod`。
- **实现**：`nativeCall` + `callableRealm`，需要 `func_obj`。VM 原型快路径也调用同一 op，所以留在 exec。
- **所有权 / 错误 / 调用**：`this`/`args` 借用，返回值归 GC。三处错误：无活跃 native environment（`nativeCall` 返回 null）与拿不到 `func_obj` 都返 `error.TypeError`，`callableRealm` 在 `callable_realm == null` 时返 `error.InvalidBuiltinRegistry`（`src/exec/builtin_dispatch.zig:327`）；其余错误由 `object_ops.primitivePrototypeMethod` 透传。调用方是 `boolean_entries` / `shared_entries` / `symbol_entries` 三张表经 `primitiveEntry` 挂上的 `genericMagicFunction`。


### `primitiveStaticEntry` (`src/exec/value_ops.zig:147`)

- **签名**：`fn primitiveStaticEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：同上的**静态方法**版本，只用于四条构造器静态：`BigInt.asIntN` / `BigInt.asUintN` 与 `Symbol.for` / `Symbol.keyFor`（id 从 6 起，与原型方法的 id 段错开）。
- **实现**：同 `primitiveEntry`，但 `native_function` 挂 `genericMagicFunction(&primitiveStaticCall)`。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项，无运行期分配。

### `primitiveStaticCall` (`src/exec/value_ops.zig:163`)

- **签名**：`fn primitiveStaticCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：包装类型构造器静态方法（id 6+）：asIntN/asUintN、Symbol.for/keyFor。
- **实现**：`nativeCall` + `callableRealm` 之后按 `host_call.magic` 分支：`bigint_asintn_id` / `bigint_asuintn_id` 都进 `builtin_glue.bigIntAsN`，区别只在 `unsigned` 参数（asIntN 传 false、asUintN 传 true）；`symbol_for_id` → `symbolFor`；`symbol_key_for_id` → `symbolKeyFor(ctx.runtime, args)`；其余 id → `error.TypeError`。
- **所有权 / 错误 / 调用**：入参借用，返回值归 GC。`nativeCall` 拿不到 native environment 与未知 magic 都返 `error.TypeError`，`callableRealm` 缺 realm 返 `error.InvalidBuiltinRegistry`；四个分支自身的错误由 `builtin_glue` 透传。调用方是 `bigint_static_entries` / `symbol_static_entries` 两张表（此前这些是 `.none` 表，掉进 `call_runtime.callNativeCallableByName` 的名字级联）。



## `src/exec/value_ops.zig` — ToPrimitive / ToLength / ToUint32

`toPrimitiveForAdditionFree` 消费对象（对照 `JS_ToPrimitiveFree`）；非对象热路径零 dup。ToLength：int/float 走 `fastToLengthIndex`，其余 ToNumber 后夹到 0..2^53-1。BigInt 在 ToNumber 路径抛 `"cannot convert bigint to number"`。


### `toPrimitiveForAdditionFree` (`src/exec/value_ops.zig:26`)

- **签名**：`pub inline fn toPrimitiveForAdditionFree( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：ToPrimitive（default hint），对照 `JS_ToPrimitiveFree`（名字沿用 qjs；tracing GC 下没有所有权转移，也不 free）。
- **实现**：非对象（加法热路径的 int/float）直接原样返回；只有对象落到 outlined 的 `toPrimitiveForAdditionObject`。
- **所有权 / 错误 / 调用**：借用入参、返回值归 GC。本身不产生错误：所有错误来自对象臂的 `toPrimitiveForAdditionObject`，其 TypeError 已由 `throwTypeErrorMessage` 挂成 pending exception，上层只见哨兵。7 处调用全在 `src/exec/vm_opcodes.zig`（`:539`、`:542`、`:590`、`:656` 等加法/比较慢路径）。


### `toPrimitiveForAddition` (`src/exec/value_ops.zig:40`)

- **签名**：`pub const toPrimitiveForAddition = toPrimitiveForAdditionFree;`。
- **作用**：`toPrimitiveForAdditionFree` 的别名。摘除引用计数后两者逐字相同（`Free` 后缀只是 rc 时代「消费入参」的拼写），保留第二个名字是因为它在各自调用点读起来更准确。
- **实现**：无独立函数体。
- **所有权 / 错误 / 调用**：完全等同被别名者。6 处调用全在 `src/exec/vm_opcodes.zig`（`:61`、`:62`、`:822`、`:826` 等）。


### `toPrimitiveForAdditionObject` (`src/exec/value_ops.zig:42`)

- **签名**：`fn toPrimitiveForAdditionObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：对象的 ToPrimitive（default hint）：先试 `Symbol.toPrimitive`，再退回 valueOf/toString。
- **实现**：`Symbol.toPrimitive` atom 取不到就直接 `toOrdinaryPrimitive`。取到的方法非 undefined/null 时：不可调用也照样报 TypeError `"not a function"`（quickjs.c:11096 JS_CallFree），可调用则以 hint 字符串 `"default"` 调用，返回值仍是对象 → TypeError `"toPrimitive"`（quickjs.c:11104）。方法是 undefined/null 则走 `toOrdinaryPrimitive`。
- **所有权 / 错误 / 调用**：分配一个 hint 字符串 `"default"`（`value_ops.createStringValue`，GC 管理，不手动释放）；`getValueProperty` / `callValueOrBytecodeSyncInternal` 会重入 JS，期间任何值都靠 GC 根而非本函数保活。两处 TypeError 走 `throwTypeErrorMessage`：Error 对象在那里就已挂到 `ctx`（pending exception），返回的 `error.TypeError` 只是哨兵，上层不必再 materialize。调用方只有本文件 `toPrimitiveForAdditionFree`（`src/exec/value_ops.zig:34`），树内无其它调用方。

### `toPrimitiveForNumber` (`src/exec/value_ops.zig:66`)

- **签名**：`pub fn toPrimitiveForNumber( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：ToPrimitive（number hint），借用入参。
- **实现**：非对象直接返回。其余与 `toPrimitiveForAdditionObject` 同形：hint 字符串是 `"number"`，兜底走 `toOrdinaryPrimitiveNumber`；非 callable 的 `Symbol.toPrimitive` 报 `"not a function"`（quickjs.c:11096），返回对象报 `"toPrimitive"`（quickjs.c:11104）。
- **所有权 / 错误 / 调用**：hint 字符串 `"number"` 由 `value_ops.createStringValue` 新建，GC 管理；返回的原始值同样归 GC，调用方不释放。TypeError 由 `throwTypeErrorMessage` 就地挂 pending exception 并返回 `error.TypeError` 哨兵；属性读与方法调用的错误原样透传。全树 54 处调用，典型如 `src/exec/vm_opcodes.zig:65`
、`src/exec/iterator_ops.zig:2508`、`src/js_context.zig:418`。

### `toOrdinaryPrimitive` (`src/exec/value_ops.zig:91`)

- **签名**：`pub fn toOrdinaryPrimitive( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：OrdinaryToPrimitive（default/string 路径）：valueOf → toString。
- **实现**：依次 `callObjectToPrimitiveMethod(valueOf)`、`(toString)`，谁先返回原始值就用谁；都没有则 TypeError `"toPrimitive"`（quickjs.c:11131）。
- **所有权 / 错误 / 调用**：本身不分配：两次 `callObjectToPrimitiveMethod` 返回的原始值归 GC。兜底的 `throwTypeErrorMessage(ctx, global, "toPrimitive")` 已把 Error 挂到 `ctx`，返回 `error.TypeError` 哨兵。调用方只有本文件的 `toPrimitiveForAdditionObject`（`:54`、`:69`），树内无外部调用方。

### `toOrdinaryPrimitiveNumber` (`src/exec/value_ops.zig:103`)

- **签名**：`pub fn toOrdinaryPrimitiveNumber( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：OrdinaryToPrimitive 的 number-hint 孪生体。
- **实现**：函数体与 `toOrdinaryPrimitive` 完全相同（valueOf → toString → TypeError `"toPrimitive"`，quickjs.c:11131）；number hint 下 qjs 的顺序本就是 valueOf 在前。
- **所有权 / 错误 / 调用**：与 `toOrdinaryPrimitive` 同：不分配，TypeError 由 `throwTypeErrorMessage` 就地挂 pending exception 后返回哨兵。调用方只有本文件 `toPrimitiveForNumber`（`:79`、`:94`），树内无外部调用方。

### `valueTruthy` (`src/exec/value_ops.zig:115`)

- **签名**：`pub fn valueTruthy(value: core.JSValue) bool`。
- **作用**：ToBoolean。
- **实现**：直接转调 `value_ops.isTruthy`。
- **所有权 / 错误 / 调用**：无：纯转调 `value_ops.isTruthy`，不分配、无 error set。全树 47 处调用，典型如 `src/exec/iterator_ops.zig:413`、`src/exec/object_ops.zig:972`、`src/exec/object_ops.zig:1071`。

### `toUint16CodeUnit` (`src/exec/value_ops.zig:119`)

- **签名**：`pub fn toUint16CodeUnit(number: f64) u16`。
- **作用**：ToUint16：把 double 折成一个 UTF-16 code unit。
- **实现**：NaN、非有限或 0 → 0；否则向零取整（负数用 `-@floor(@abs(n))`）后对 65536 取模。
- **所有权 / 错误 / 调用**：无：纯浮点算术，不分配、无 error set。唯一调用方是 `String.fromCharCode` 的 code-unit 填充循环（`src/exec/string_ops.zig:845`）。

### `toLengthIndex` (`src/exec/value_ops.zig:126`)

- **签名**：`pub fn toLengthIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !usize`。
- **作用**：ToLength，并把结果当 usize 下标返回。
- **实现**：栈上开 `index`，转调 `toLengthIndexInto` 后返回。
- **所有权 / 错误 / 调用**：`index` 是栈上出参，无堆分配；实际工作在 `toLengthIndexInto`。错误全部来自慢路径：BigInt 在 `toLengthNumber` 被 `throwTypeErrorMessage` 就地挂成 TypeError（返回 `error.TypeError` 哨兵），其余是 ToPrimitive 重入 JS 的透传错误。全树 38 处调用，典型如 `src/exec/object_ops.zig:1906`、`src/exec/string_ops.zig:784`、`src/exec/iterator_ops.zig:1130`。

### `toLengthIndexInto` (`src/exec/value_ops.zig:135`)

- **签名**：`noinline fn toLengthIndexInto(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, index: *usize) !void`。
- **作用**：QJS `JS_ToLengthFree` 形状：整数状态 + 出参写转换后的 length，避免 `!usize` 的 16 字节结果槽绕过 tag switch。
- **实现**：`fastToLengthIndex` 命中则写 `index.*` 返回。否则 `toLengthIndexSlow`（ToPrimitive/ToNumber）。对照 `JS_ToInt64SatFree`：整数/浮点标签直接处理，object/Symbol/BigInt 留在可观察慢路径。
- **所有权 / 错误 / 调用**：不拥有 `value`。`toLengthIndex` 是唯一包装。慢路径 TypeError 已由 `throwTypeErrorMessage` 挂消息。

### `toLengthIndexSlow` (`src/exec/value_ops.zig:149`)

- **签名**：`pub fn toLengthIndexSlow(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !usize`。
- **作用**：ToLength 的可观察一半：已经排除数值 tag 的调用方从这里进。
- **实现**：`toLengthNumber` 之后，≥ `maxInt(usize)` 就夹到 `maxInt(usize)`，否则 `@intFromFloat`。
- **所有权 / 错误 / 调用**：可观察路径：ToPrimitive/ToNumber 会跑用户代码；BigInt 的 TypeError 由 `toLengthNumber` 挂消息。

### `toLengthNumber` (`src/exec/value_ops.zig:155`)

- **签名**：`pub fn toLengthNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64`。
- **作用**：ToLength 的 double 形态（0 ≤ len ≤ 2^53-1）。
- **实现**：`toPrimitiveForNumber` 后若是 BigInt，抛 TypeError `"cannot convert bigint to number"`（quickjs.c:12959）；再 `value_ops.toNumberValue`，取不出数值按 NaN 处理：NaN 或 ≤0 → 0，≥ 9007199254740991 夹到该上限，其余 `@floor`。
- **所有权 / 错误 / 调用**：不拥有 `value`；BigInt 分支先 `throwTypeErrorMessage` 挂上消息再返回 `error.TypeError`。

### `fastToLengthIndex` (`src/exec/value_ops.zig:170`)

- **签名**：`pub fn fastToLengthIndex(value: core.JSValue) ?usize`。
- **作用**：ToLength 的无副作用快路径：只吃 int32 / float64 两种 tag。
- **实现**：int32：≤0 → 0，否则直接 `@intCast`。float64：NaN 或 ≤0 → 0，≥ 9007199254740991 先夹到该上限再 `@floor`，超过 `maxInt(usize)` 夹住。其他 tag 返回 null，交给慢路径。
- **所有权 / 错误 / 调用**：无：只读 tag 的纯函数，不分配、无 error set，失败用 `null` 而不是错误。调用方是本文件 `toLengthIndexInto`（`:145`）与 `src/exec/regexp_ops.zig:671`。

### `toUint32Number` (`src/exec/value_ops.zig:185`)

- **签名**：`pub fn toUint32Number(number: f64) u32`。
- **作用**：ToUint32 的数值部分。
- **实现**：NaN、非有限或 0 → 0；否则向零取整后对 2^32 取模。
- **所有权 / 错误 / 调用**：无：纯浮点取模，不分配、无 error set。8 处调用，典型如 `src/exec/math_ops.zig:473`（`Math.imul`）、`src/exec/math_ops.zig:330`、`src/exec/string_ops.zig:950`。

### `uint32NumberValue` (`src/exec/value_ops.zig:192`)

- **签名**：`pub fn uint32NumberValue(value: u32) core.JSValue`。
- **作用**：把 u32 装箱成 JSValue。
- **实现**：≤ `maxInt(i32)` 走 `int32`，否则 `float64`。
- **所有权 / 错误 / 调用**：无：按范围选 int32 还是 float64 立即数 tag，不分配、无 error set。三处调用全在 `src/exec/string_ops.zig`（`:950`、`:1053`、`:2321`）。

### `coerceOptionalNumberMethodArgument` (`src/exec/value_ops.zig:197`)

- **签名**：`pub fn coerceOptionalNumberMethodArgument( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, preserve_undefined: bool, ) !?core.JSValue`。
- **作用**：可选数值参数的 ToNumber：给只在「确实传了参数」时才转换的内建方法用。
- **实现**：`args.len == 0` 返回 null；`preserve_undefined` 且首参是 undefined 也返回 null。否则 `toPrimitiveForNumber`，是 BigInt 就抛 TypeError `"cannot convert bigint to number"`（quickjs.c:12959），其余 `value_ops.toNumberValue`。
- **所有权 / 错误 / 调用**：返回的 JSValue 由调用方拥有；`toPrimitiveForNumber` 会跑用户代码，TypeError 已由 `throwTypeErrorMessage` 挂好消息再以 error 上抛。

### `primitiveWrapperStoredValue` (`src/exec/value_ops.zig:218`)

- **签名**：`pub fn primitiveWrapperStoredValue(rt: *core.JSRuntime, value: core.JSValue) ?core.JSValue`。
- **作用**：取包装对象里存着的那个原始值。
- **实现**：非对象或 `expectObject` 失败返回 null；只认 `number` / `boolean` / `big_int` / `symbol` 四个 class（String 包装不在内），命中才取 `object.objectData()`，取不到也返回 null。
- **所有权 / 错误 / 调用**：返回的是包装对象内部槽里的**借用**值（`object.objectData()`），不建根，调用方不得释放；`rt` 参数未使用（只为保持跨文件调用点统一的 `(rt, value)` 形状，函数头注释已写明）。无 error set：`property_ops.expectObject` 的失败被 `catch return null` 吞掉，非包装类一律 `null`。调用方 `src/exec/json_ops.zig:2432`（把 `null` 转成 `error.TypeError`）；`src/exec/construct.zig:749` 另有一份同名的文件私有副本。

### `toNumberForDateMethod` (`src/exec/value_ops.zig:232`)

- **签名**：`pub fn toNumberForDateMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Date 方法参数的 ToNumber：对象先 ToPrimitive(number)，BigInt 一律 TypeError。
- **实现**：对象分支：`toPrimitiveForNumber` 后是 BigInt → TypeError `"cannot convert bigint to number"`（quickjs.c:12959），否则 `value_ops.toNumberValue`。非对象分支：BigInt 同样 TypeError，其余直接 `toNumberValue`。`caller_function` / `caller_frame` 未使用（函数头注释已写明：两条腿都不需要调用帧，`toPrimitiveForNumber` 自己开 native 环境）。
- **所有权 / 错误 / 调用**：返回的是 int32/float64 立即数，不分配；`caller_function`/`caller_frame` 当前被 `_ =` 丢弃（只为对齐 date 调用点的签名）。两处 BigInt 拒绝都走 `throwTypeErrorMessage`，Error 已挂 `ctx`，函数再返回 `error.TypeError` 哨兵；对象路径经 `toPrimitiveForNumber` 可重入 JS 并透传其错误。9 处调用，典型如 `src/exec/date_ops.zig:142`
、`src/exec/date_ops.zig:178`、`src/exec/array_ops.zig:5009`。


## `src/exec/value_ops.zig` — 算术、比较、BigInt、字符串核

输入默认借用；`addStringsOwned` 消费两个字符串操作数。ToNumber 对 BigInt/Symbol 抛 TypeError（ToNumeric 由调用方先转）。字符串 `.length` 读 rope 节点长度，不 flatten。


### `binary` (`src/exec/value_ops.zig:20`)

- **签名**：`pub fn binary(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：二元运算的通用体：`op` 是字节码 opcode，覆盖加减乘除模幂与位运算。
- **实现**：`add` 且任一侧是字符串 → `stringAdd`。任一侧 Symbol → TypeError。有 BigInt：两侧都得是 BigInt，否则 TypeError，然后 `binaryBigInt`。移位/按位（shl/sar/shr/and/xor/or）两侧 `toInt32`，移位量取 `& 31`，`shr` 按 u32 逻辑右移再 `numberToValue`。剩下的算术走 `binaryNumber`。函数尾是 `unreachable`：生产 opcode 已被上面各臂穷尽。
- **所有权 / 错误 / 调用**：入参借用；字符串/BigInt 结果是新建的 GC 值（tracing GC 管理，调用方不释放），数值结果是立即数。本文件只拿 `*core.JSRuntime`、没有 realm，所以 `error.TypeError`（Symbol 操作数、BigInt 与非 BigInt 混用、BigInt 的 `shr`）是**裸哨兵**，没有 pending exception，靠调用方的 `builtin_dispatch.materializeRuntimeError`（`src/exec/builtin_dispatch.zig:457`）按 `runtimeErrorInfo` 渲染成 JS Error；BigInt 臂还会原样上浮 `error.DivisionByZero` / `error.NegativeExponent` / `error.BigIntTooLarge`。10 处调用全在 `src/exec/vm_opcodes.zig`（`:56`、`:63`、`:69`、`:70` 与 `:564` 起的 inc/dec-add 臂），另有 4 处单测。


### `compare` (`src/exec/value_ops.zig:57`)

- **签名**：`pub fn compare(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：关系比较 lt/lte/gt/gte 的通用体。
- **实现**：双字符串：同一值直接 0，否则 `compareStringValues`（返回 null 时 TypeError），按 op 取符号。任一侧 BigInt：`compareBigIntRelational`，得 null（不可比，例如 NaN/undefined）一律返回 false。其余：两侧能取数值就取，否则 `toIntegerOrInfinity`，再按 op 做 f64 比较。
- **所有权 / 错误 / 调用**：不分配 JS 值（结果是 bool 立即数）；BigInt 关系比较的临时 `bignum.BigInt` 在 `compareBigIntRelational` 那一层就地释放。`error.TypeError`（字符串体不可比、BigInt 与 Symbol/对象混比）是裸哨兵，由调用方 materialize。5 处调用：`src/exec/vm_opcodes.zig:135`、`:228`、`:231`，以及 `Array.prototype.sort` 默认比较器的 `src/exec/array_ops.zig:5614`、`:5616`。


### `compareBigIntRelational` (`src/exec/value_ops.zig:92`)

- **签名**：`fn compareBigIntRelational(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !?std.math.Order`。
- **作用**：BigInt 参与的关系比较，返回 `Order` 或 null（不可比）。
- **实现**：双 BigInt 走 `compareBigIntValues`（拿不到位就 TypeError）。只有 a 是 BigInt 走 `compareBigIntToNonBigInt`；只有 b 是就反过来调再 `reverseOrder`，null 原样传出。
- **所有权 / 错误 / 调用**：自身不分配：BigInt×BigInt 走栈上 limb scratch 的 `compareBigIntValues`，混类型才进 `compareBigIntToNonBigInt`（临时 BigInt 在那里 `defer deinit`）。`error.TypeError` 是裸哨兵。文件私有，唯一调用方 `compare`（`src/exec/value_ops.zig:70`）。

### `compareBigIntToNonBigInt` (`src/exec/value_ops.zig:101`)

- **签名**：`fn compareBigIntToNonBigInt(rt: *core.JSRuntime, bigint_value: core.JSValue, other: core.JSValue) !?std.math.Order`。
- **作用**：把 BigInt 和一个非 BigInt 操作数比大小。
- **实现**：字符串：`parseStringToBigInt`，解析失败返回 null（不可比）。数值：`compareBigIntToNumber`。布尔：跟 1/0 比。null：跟 0 比。undefined：null。其余（Symbol/对象）：TypeError。临时 BigInt 都 `defer deinit`。
- **所有权 / 错误 / 调用**：这里的「局部缓冲」是真的：`parseStringToBigInt` / `bignum.BigInt.fromIntAlloc` / `cloneBigIntValue` 产出的 `bignum.BigInt` 都用 `rt.memory.allocator` 分配并 `defer deinit()`，不产生任何 JS 值。字符串解析失败被 `catch return null`（比较结果记为 false），`undefined` 返回 `null`，其余非法类型是裸 `error.TypeError`，OOM 上浮。文件私有，调用方 `compareBigIntRelational`（`:96`、`:97`）。

### `parseStringToBigInt` (`src/exec/value_ops.zig:127`)

- **签名**：`pub fn parseStringToBigInt(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt`。
- **作用**：把字符串值按 StringToBigInt 解析成临时 `bignum.BigInt`。
- **实现**：`appendRawString` 进临时缓冲，`trimJsWhitespace` 去掉完整 JS 空白集（qjs `JS_StringToBigInt` quickjs.c:14609 经 `skip_spaces` quickjs.c:11230）；空串返回 0n，否则 `bignum.parseAutoAlloc`。
- **所有权 / 错误 / 调用**：返回的 BigInt 由调用方 `deinit`；临时字节缓冲在函数内释放。

### `compareBigIntToNumber` (`src/exec/value_ops.zig:138`)

- **签名**：`fn compareBigIntToNumber(rt: *core.JSRuntime, bigint_value: core.JSValue, number: f64) !?std.math.Order`。
- **作用**：BigInt 与 double 的精确比较（不走浮点转换）。
- **实现**：NaN → null；+∞ → `.lt`；-∞ → `.gt`。否则把 number 截断成 BigInt 比较；整数部分相等时再看小数：number 有小数则正数偏大（`.lt`）、负数偏小（`.gt`）。
- **所有权 / 错误 / 调用**：两个临时 `bignum.BigInt`（`truncatedFiniteNumberToBigInt` 的右值与 `cloneBigIntValue` 的左值）都 `defer deinit()`，不产生 JS 值。NaN/无穷用返回值表达而非错误，错误只有分配失败。文件私有，调用方 `compareBigIntToNonBigInt`（`:109`）与 `bigIntEqualsNumber`（`:154`）。

### `bigIntEqualsNumber` (`src/exec/value_ops.zig:153`)

- **签名**：`pub fn bigIntEqualsNumber(rt: *core.JSRuntime, bigint_value: core.JSValue, number: f64) !bool`。
- **作用**：BigInt 与 double 是否相等（NaN/±∞ 一律 false）。
- **实现**：`compareBigIntToNumber` 返回 null 就 false，否则判 `.eq`。
- **所有权 / 错误 / 调用**：自身不分配，临时 BigInt 全在 `compareBigIntToNumber` 内释放；无法比较（NaN）折成 `false`，错误只有 OOM。调用方是松散相等的 BigInt×Number 臂：`src/exec/vm_opcodes.zig:815`、`:819`。

### `truncatedFiniteNumberToBigInt` (`src/exec/value_ops.zig:158`)

- **签名**：`fn truncatedFiniteNumberToBigInt(allocator: std.mem.Allocator, number: f64) !bignum.BigInt`。
- **作用**：把有限 double 的整数部分变成 BigInt。
- **实现**：直接拆 IEEE-754 位：指数与尾数全 0 → 0n；`exp_bits == 0` 按次正规数取 -1022 与裸尾数，否则补隐含位。`shift = exponent - 52` ≥0 就 `base.shl`，否则右移丢掉小数部分（移量 ≥64 时结果为 0）。最后按符号位置 `negative`（0 不带负号）。
- **所有权 / 错误 / 调用**：返回的 `bignum.BigInt` 是**新分配**的，调用方负责 `deinit`（本文件的调用点都用 `defer`）。

### `integerNumberToBigIntValue` (`src/exec/value_ops.zig:182`)

- **签名**：`pub fn integerNumberToBigIntValue(rt: *core.JSRuntime, number: f64) !core.JSValue`。
- **作用**：把「整数值的 double」转成 BigInt 值，非整数直接报错。
- **实现**：非有限或 `@trunc(number) != number` → `error.RangeError`；否则 `truncatedFiniteNumberToBigInt` 后 `createBigIntValue` 装箱，临时 BigInt `defer deinit`。
- **所有权 / 错误 / 调用**：局部 `bignum.BigInt` `defer deinit()`；结果由 `createBigIntValue` **拷贝**进 GC 堆（或压成 short bigint 立即数），返回值归 GC。非有限/非整数返回裸 `error.RangeError` 哨兵（无 pending exception，消息由 `runtimeErrorInfo` 补）。唯一调用方 `src/exec/builtin_glue.zig:79`（`BigInt(x)` 的 number 臂）。

### `reverseOrder` (`src/exec/value_ops.zig:189`)

- **签名**：`fn reverseOrder(order: std.math.Order) std.math.Order`。
- **作用**：把比较结果反向（lt↔gt，eq 不变）。
- **实现**：按 `order` 分支。
- **所有权 / 错误 / 调用**：无：三分支纯函数，不分配、无 error set。文件私有，唯一调用方 `compareBigIntRelational`（`src/exec/value_ops.zig:98`）。

### `strictEqual` (`src/exec/value_ops.zig:197`)

- **签名**：`pub fn strictEqual(a: core.JSValue, b: core.JSValue) core.JSValue`。
- **作用**：`===` 的装箱版。
- **实现**：`core.JSValue.boolean(valuesEqual(a, b))`。
- **所有权 / 错误 / 调用**：无：转调 `valuesEqual` 后返回 bool 立即数，不分配、无 error set。5 处调用，典型 `src/exec/vm_opcodes.zig:128`、`:212`、`:779`。

### `strictNotEqual` (`src/exec/value_ops.zig:201`)

- **签名**：`pub fn strictNotEqual(a: core.JSValue, b: core.JSValue) core.JSValue`。
- **作用**：`!==` 的装箱版。
- **实现**：`core.JSValue.boolean(!valuesEqual(a, b))`。
- **所有权 / 错误 / 调用**：无：`valuesEqual` 取反后的 bool 立即数，不分配、无 error set。调用方 `src/exec/vm_opcodes.zig:129`、`:213`。

### `length` (`src/exec/value_ops.zig:205`)

- **签名**：`pub fn length(value: core.JSValue) !core.JSValue`。
- **作用**：取 `.length`：字符串、数组与一般对象三条路。
- **实现**：字符串走 rope 感知的 `core.string.stringValueLen`，**不 flatten**（qjs 把长度存在 `JSStringRope.len` 上，所以 `s = s + x; s.length` 不会退化成每轮 O(n)），超 i32 用 float64。对象：数组读 `arrayLength()`，否则 `getProperty(length)`，undefined 归一成 undefined。null/undefined → TypeError，其余原始值 → undefined。
- **所有权 / 错误 / 调用**：字符串臂读 rope 节点长度，不物化不分配；数组臂读 `arrayLength()`；一般对象臂走 `core.Object.getProperty`，返回的是属性槽里的**借用**值，且该读路径不触发 accessor（accessor 返回的是 getter 函数本身），因此不会重入 JS。`null`/`undefined` 返回裸 `error.TypeError` 哨兵，`getProperty` 的 `error.ReferenceError`（未初始化 var_ref）也可能上浮。调用方 `src/exec/object_ops.zig:2517`、`:2609`。

### `unary` (`src/exec/value_ops.zig:232`)

- **签名**：`pub fn unary(rt: *core.JSRuntime, op: u8, value: core.JSValue) !core.JSValue`。
- **作用**：一元运算：not/neg/to_number/inc/dec（含 post_ 变体）。
- **实现**：`not` 且非 BigInt：`toInt32` 后按位取反。float64 tag 直接算并 `numberToValue`。BigInt：`to_number` 是 TypeError；先试 `shortBigIntUnary` 的 short 快路径，否则 clone 后按 op 做 neg（置符号，0 不带负号）/ ±1（`bignum.subAlloc`/`addAlloc`）/ `bitNot`，结果 `createBigIntValue`。其余值先 `toNumberValue` 再算；最后一段整数臂用 `toInt32`。
- **所有权 / 错误 / 调用**：数值臂只产立即数；BigInt 臂在堆上克隆并做加减/取反，中间 `bignum.BigInt` 全部 `defer deinit()`，结果经 `createBigIntValue` 拷进 GC 堆。`to_number` 作用于 BigInt 返回裸 `error.TypeError` 哨兵，其余错误是 OOM 与 `toIntegerOrInfinity` 的透传。6 处调用，全在 `src/exec/vm_opcodes.zig`（`:261`、`:263`、`:292`、`:339`、`:401`、`:483`）。


### `toStringValue` (`src/exec/value_ops.zig:305`)

- **签名**：`pub fn toStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：无 realm 的 ToString：产出字符串 JSValue。
- **实现**：先试 `primitiveToStringValueFast`；不命中就用临时 `ArrayList(u8)` 走 `appendValueString`，再 `createStringValue`。
- **所有权 / 错误 / 调用**：返回值可能是入参本身（字符串原样返回，借用）、runtime 缓存串（空串/0-255 小整数）或新建的 GC 字符串，三种都不需要调用方释放。慢路径的 `std.ArrayList(u8)` 用 `rt.memory.allocator` 并 `defer deinit()`。error set 是 `appendValueString` 的 `AppendStringError`（= `RuntimeError`）裸哨兵；Symbol 在本文件策略下走 `.describe` 写描述而非抛错。11 处调用，典型 `src/exec/string_ops.zig:126`、`:200`、`src/exec/call.zig:2181`。

### `primitiveToStringValueFast` (`src/exec/value_ops.zig:313`)

- **签名**：`fn primitiveToStringValueFast(rt: *core.JSRuntime, value: core.JSValue) !?core.JSValue`。
- **作用**：原始值 ToString 的免缓冲快路径，不认识的值返回 null。
- **实现**：字符串原样返回。int32：0..255 用 `rt.smallIntString` 缓存，否则栈上 `formatInt32`。float64：NaN/Infinity/-Infinity/-0（输出 `"0"`）特判，其余 `formatFiniteNumberAssumeCapacity`。short BigInt 用 `formatInt64`；bool、undefined、null 各自的字面量。其他（对象等）返回 null。
- **所有权 / 错误 / 调用**：字符串入参原样返回（借用，不 dup）；0-255 的整数取 `rt.smallIntString` 的 runtime 缓存串（runtime 拥有）；其余经 `createAsciiStringValue` 新建 GC 字符串。`[32]`/`[64]` 的数字格式化缓冲在栈上，不逃逸。非原始值返回 `null` 让调用方走慢路径，错误只有 OOM。文件私有，唯一调用方 `toStringValue`（`src/exec/value_ops.zig:342`）。

### `fastStringToInt32` (`src/exec/value_ops.zig:343`)

- **签名**：`fn fastStringToInt32(bytes: []const u8) ?i32`。
- **作用**：纯十进制短字符串到 i32 的快速解析（给 ToNumber 用）。
- **实现**：长度 0 或 >10 直接 null；逐字符必须是 `'0'..'9'`（不接受符号、空白、小数点）；累加到 i64，超过 `maxInt(i32)` 返回 null。
- **所有权 / 错误 / 调用**：无：对借用的 latin1 字节切片做纯十进制解析，不分配、无 error set，任何不合规（空、超 10 位、非数字、越界）都返回 `null`。文件私有，唯一调用方 `toNumberValue` 的 latin1 臂（`src/exec/value_ops.zig:405`）。

### `toNumberValue` (`src/exec/value_ops.zig:354`)

- **签名**：`pub fn toNumberValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：无 realm 的 ToNumber（已是原始值的那一半）。
- **实现**：Symbol → TypeError；BigInt → TypeError（qjs `JS_ToNumberHintFree` quickjs.c:12955-12959：纯 ToNumber 下 BigInt 抛错，ToNumeric 语义由调用方先转）。数值归一，bool → 1/0，null → 0。字符串（恒为扁平）直接按 `resolveData()` 分臂：latin1 先试 `fastStringToInt32`，否则 `parseJsNumberLatin1`（0x80-0xFF 是单个码点而非 UTF-8 前导字节）；utf16 走 `appendRawString` + `parseJsNumber`。其余（含对象、undefined）返回 NaN。
- **所有权 / 错误 / 调用**：返回立即数，不新建 JS 值；latin1 臂零分配，UTF-16 臂有 `std.ArrayList(u8)` 局部缓冲 `defer deinit()`。Symbol 与 BigInt 返回**裸** `error.TypeError` 哨兵——本文件没有 realm，`"cannot convert bigint to number"` 那条消息是 exec 调用方（如 `src/exec/value_ops.zig:165`）自己抛的。45 处调用，典型 `src/exec/value_ops.zig:168`、`src/exec/string_ops.zig:755`、`src/exec/string_ops.zig:843`。

### `asN` (`src/exec/value_ops.zig:383`)

- **签名**：`pub fn asN(rt: *core.JSRuntime, bits_value: core.JSValue, bigint_value: core.JSValue, unsigned: bool) !core.JSValue`。
- **作用**：`BigInt.asIntN` / `BigInt.asUintN`：把 BigInt 截到 bits 位。
- **实现**：bits 是 BigInt 或 Symbol → TypeError；`toIntegerOrInfinity` 后非有限、为负、或 > 2^53-1 → RangeError。`bits == 0` 直接 0n。不需要截断的快路径：unsigned 且非负且位宽 ≤ bits，或 signed 且位宽 < bits，原样返回。否则 `modPowerOfTwo(bits)`；signed 且结果第 `bits-1` 位为 1 时再减去 `pow2(bits)` 变成负数。
- **所有权 / 错误 / 调用**：`toBigIntValue` 返回 owned `bignum.BigInt`（`defer deinit()`），`modPowerOfTwo` / `pow2` / `subAlloc` 的中间量同样各自 `defer deinit()`；所有出口都用 `createBigIntValue`（**拷贝**进 GC 堆，不消费局部量）。裸哨兵错误：bits 非有限/为负/超 2^53-1 → `error.RangeError`，bits 是 BigInt/Symbol 或入参无法转 BigInt → `error.TypeError`。唯一调用方 `src/exec/builtin_glue.zig:120`（`BigInt.asIntN`/`asUintN`）。

### `numberToValue` (`src/exec/value_ops.zig:414`)

- **签名**：`pub fn numberToValue(value: f64) core.JSValue`。
- **作用**：double 结果装箱：能精确回落 int32 就用 int32。
- **实现**：值落在 i32 范围内、`@intFromFloat` 往返相等且不是 -0 才走 `int32`，否则 `float64`。
- **所有权 / 错误 / 调用**：无：只做 tag 规范化（可精确表示且非 -0 就 int32，否则 float64），不分配、无 error set。全树 45 处调用，典型 `src/exec/vm_opcodes.zig:249`、`src/native.zig:595`、`src/exec/builtin_glue.zig:61`。

### `createStringValue` (`src/exec/value_ops.zig:427`)

- **签名**：`pub noinline fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：从字节铸造 JS 字符串：空串走运行时缓存，ASCII 走 `createAscii`，否则 `createUtf8`。
- **实现**：`bytes.len == 0` → `rt.emptyString().value()`。`core.string.isAsciiBytes` 分流。outlined leftover：把 `string_builtin_ops` / `regexp_ops` 以及大量内联点的同一走法收成一处。
- **所有权 / 错误 / 调用**：返回的 `JSValue` 由调用方拥有。OOM 上抛。`createAsciiStringValue` 是 ASCII-only 私有孪生。

### `createAsciiStringValue` (`src/exec/value_ops.zig:439`)

- **签名**：`fn createAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：已知全 ASCII 的字节铸造字符串值。
- **实现**：空串走 `rt.emptyString()` 缓存，否则 `core.string.String.createAscii`（跳过 `createStringValue` 的 ASCII 判定）。
- **所有权 / 错误 / 调用**：新建 GC 字符串并返回（空串取 `rt.emptyString()` 的 runtime 缓存，不新建）；返回值归 tracing GC，调用方不释放。错误只有 OOM。文件私有，唯一调用方 `primitiveToStringValueFast`（`src/exec/value_ops.zig:357`-`:375` 的各个字面量臂）。


### `createBigIntI128` (`src/exec/value_ops.zig:467`)

- **签名**：`pub fn createBigIntI128(rt: *core.JSRuntime, value: i128) !core.JSValue`。
- **作用**：把 i128 装箱成 BigInt 值。
- **实现**：`shortBigIntFits` 就用内联 short BigInt，否则 `core.bigint.BigInt.create` 上堆并取 `valueRef()`。
- **所有权 / 错误 / 调用**：值域内返回 short bigint 立即数（零分配），否则 `core.bigint.BigInt.create` 新建 GC BigInt 并返回 `valueRef()`，归 GC。错误只有 OOM。6 处调用，典型 `src/root.zig:85`、`src/root.zig:92`、`src/exec/builtin_glue.zig:77`。

### `createBigIntOwned` (`src/exec/value_ops.zig:475`)

- **签名**：`fn createBigIntOwned(rt: *core.JSRuntime, value: bignum.BigInt) !core.JSValue`（文件私有）。
- **作用**：**消费** 一个 `bignum.BigInt` 并装箱。
- **实现**：能转成 i64 且 `shortBigIntFits` 就先 `deinit` 再返回 short BigInt；否则 `createFromOwned` 接管 limb 内存。`errdefer` 保证失败路径也释放。
- **所有权 / 错误 / 调用**：**消费**入参 `bignum.BigInt`：能压成 short 时立刻 `owned.deinit()` 并返回立即数，否则 `createFromOwned` 接管其 limb 缓冲；失败路径由 `errdefer owned.deinit()` 兜底。调用方交出后不得再 `deinit`——这正是它与 `createBigIntValue` 的分工。树内只有本文件两个调用方：`binaryBigInt`（`:760`）与 `addPositiveShortToBigInt`（`:772`）。


### `createBigIntValue` (`src/exec/value_ops.zig:488`)

- **签名**：`pub fn createBigIntValue(rt: *core.JSRuntime, value: bignum.BigInt) !core.JSValue`。
- **作用**：**借用** 一个 `bignum.BigInt` 并装箱（调用方仍需自己 deinit）。
- **实现**：short 适配同上，否则 `createFromBigInt` 复制一份到堆。
- **所有权 / 错误 / 调用**：与 `createBigIntOwned` 相反：**不消费**入参，`createFromBigInt` 复制 limbs，调用方仍要 `deinit` 自己那份 `bignum.BigInt`；返回的 GC BigInt（或 short 立即数）归 GC。错误只有 OOM。6 处调用，典型 `src/exec/vm_opcodes.zig:796`、`src/exec/atomics_ops.zig:1070`、`src/exec/builtin_glue.zig:88`。

### `bigIntToNumber` (`src/exec/value_ops.zig:502`)

- **签名**：`pub fn bigIntToNumber(rt: *core.JSRuntime, value: core.JSValue) !f64`。
- **作用**：BigInt → double（ToNumeric 侧调用方用）。
- **实现**：short bigint 直接 `@floatFromInt`；否则 clone 出临时 BigInt，`BigInt.toFloat64` 从 limb 一次就近偶舍入（qjs `js_bigint_to_float64`）；临时 BigInt 在函数内释放。
- **所有权 / 错误 / 调用**：`cloneBigIntValue` 的 `bignum.BigInt` `defer deinit()`。错误只有 OOM。7 处调用，典型 `src/exec/builtin_glue.zig:61`、`src/exec/function_ops.zig:140`、`src/exec/reflect_ops.zig:102`。

### `toIntegerOrInfinity` (`src/exec/value_ops.zig:509`)

- **签名**：`pub fn toIntegerOrInfinity(rt: *core.JSRuntime, value: core.JSValue) !f64`。
- **作用**：ToNumber 的 f64 形态（**不做截断**，取整由调用方负责）。
- **实现**：已是数值直接返回；BigInt → TypeError（qjs `JS_ToNumberHintFree` quickjs.c:12955-12959）；bool → 1/0；null → 0；undefined → NaN；其余（字符串/对象）`appendValueString` 后 `parseJsNumber`。
- **所有权 / 错误 / 调用**：返回 f64，不产生 JS 值；字符串/对象臂的 `std.ArrayList(u8)` `defer deinit()`。BigInt 返回裸 `error.TypeError` 哨兵，其余错误来自 `appendValueString`（`AppendStringError`）。7 处调用，典型 `src/root.zig:119`、`src/exec/string_ops.zig:878`、`src/exec/reflect_ops.zig:104`。

### `toIndexUsize` (`src/exec/value_ops.zig:524`)

- **签名**：`pub fn toIndexUsize(rt: *core.JSRuntime, value: core.JSValue) !usize`。
- **作用**：ToIndex：非负整数下标，越界报 RangeError。
- **实现**：`toIntegerOrInfinity` 后 NaN → 0，非有限 → RangeError，`@trunc` 为负 → RangeError，其余取整数部分。
- **所有权 / 错误 / 调用**：自身不分配（临时缓冲在 `toIntegerOrInfinity` 内释放）；非有限或负数返回裸 `error.RangeError` 哨兵，BigInt 的 `error.TypeError` 透传，NaN 折成 0。调用方 `src/exec/array_ops.zig:1042`、`:1068`。

### `toBigIntValue` (`src/exec/value_ops.zig:534`)

- **签名**：`pub fn toBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt`。
- **作用**：ToBigInt：产出临时 `bignum.BigInt`。
- **实现**：BigInt 直接 clone；Number → TypeError；bool → 1n/0n；字符串或对象先 `appendValueString`，`trimJsWhitespace`（qjs quickjs.c:14609 + 11230）后空串算 0n，否则 `parseAutoAlloc`——`error.BigIntTooLarge` 原样传出（qjs 从 `js_atof` 抛 RangeError，quickjs.c:12471），其他解析失败统一成 `error.SyntaxError`。其余值 TypeError。
- **所有权 / 错误 / 调用**：返回的 BigInt 由调用方 `deinit`；临时缓冲在函数内释放。

### `heapBigInt` (`src/exec/value_ops.zig:557`)

- **签名**：`inline fn heapBigInt(value: core.JSValue) ?*core.bigint.BigInt`。
- **作用**：取值背后的堆 BigInt 指针。
- **实现**：非 BigInt、或没有 ref header（short BigInt）都返回 null；否则 `@fieldParentPtr` 还原。
- **所有权 / 错误 / 调用**：无所有权转移：`@fieldParentPtr` 取出的是**借用**的 `*core.bigint.BigInt`，不 retain、不建根，只在同一表达式里读长度/符号；short bigint 与非 BigInt 返回 `null`。无 error set。文件私有，唯一调用方是 `binaryBigInt` 的单分配乘法臂（`src/exec/value_ops.zig:710`、`:711`）。

### `bigIntFromValueBorrowed` (`src/exec/value_ops.zig:563`)

- **签名**：`pub fn bigIntFromValueBorrowed(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt`。
- **作用**：拿到可运算的 `bignum.BigInt` 视图：short 会新分配，堆 BigInt 只借 limbs。
- **实现**：short BigInt → `fromIntAlloc`（**调用方要 deinit**）；堆 BigInt → `big.borrowedValue`（借用，不拷贝，不可 deinit）；其余 TypeError。
- **所有权 / 错误 / 调用**：所有权取决于入参形态，`binaryBigInt` 用 `as(.short_big_int) != null` 判断该不该释放。

### `isTruthy` (`src/exec/value_ops.zig:573`)

- **签名**：`pub fn isTruthy(value: core.JSValue) bool`。
- **作用**：ToBoolean：判断值的真假（`undefined`/`null`/`false`/`0`/`NaN`/空串为假）。

- **实现**：转调 `core.value_semantics.toBoolean`。
- **所有权 / 错误 / 调用**：无：转调 `core.value_semantics.toBoolean` 的只读谓词，不分配、无 error set。16 处调用，典型 `src/exec/vm_opcodes.zig:85`、`src/exec/value_ops.zig:122`、`src/root.zig:123`。

### `isFunctionObject` (`src/exec/value_ops.zig:577`)

- **签名**：`pub fn isFunctionObject(value: core.JSValue) bool`。
- **作用**：谓词：该值是否是可调用的函数对象。
- **实现**：非对象/无 header → false；有 `proxyTarget()` 转 `proxyTargetIsFunction`；否则认这些 class：`c_function`、任意 bytecode function class、`bound_function`、`c_function_data`、async-resume class、`c_closure`。
- **所有权 / 错误 / 调用**：无：只读 class_id 与 proxy target 的谓词，不分配、无 error set。调用方 `proxyTargetIsFunction`（同文件）与 `src/exec/reflect_ops.zig:217`（`value_ops.typeOf` 已删，`typeof` 走 `src/exec/vm_opcodes.zig` 的同名 helper）。

### `proxyTargetIsFunction` (`src/exec/value_ops.zig:590`)

- **签名**：`fn proxyTargetIsFunction(value: core.JSValue) bool`。
- **作用**：谓词：该值是 Proxy 且其 target 可调用。
- **实现**：取 `proxyTarget()`，为空 false；target 是 function bytecode 或 `isFunctionObject` 则 true（两函数互相递归处理 proxy 套 proxy）。
- **所有权 / 错误 / 调用**：无：读 proxy target 后回调 `isFunctionObject`（两者互相递归，沿代理链下降），不分配、无 error set；revoked/非代理走 `orelse false`。文件私有，唯一调用方是同文件的 `isFunctionObject`（`value_ops.typeOf` 已删）。

### `atomNameEql` (`src/exec/value_ops.zig:617`)

- **签名**：`pub fn atomNameEql(rt: *core.JSRuntime, atom_id: core.Atom, name: []const u8) bool`。
- **作用**：atom 的名字是否等于给定字节串。
- **实现**：`rt.atoms.name(atom_id)` 取不到名字直接 false，否则 `std.mem.eql`。
- **所有权 / 错误 / 调用**：无：拿 atom 表里的**借用**名字切片与字面量比对，不分配、不 retain atom、无 error set；未知 atom 返回 false。4 处调用：`src/exec/property_ops.zig:33`、`:48`、`src/exec/call_runtime.zig:4704`、`src/js_context.zig:548`。

### `appendRawString` (`src/exec/value_ops.zig:631`)

- **签名**：`pub fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void`。
- **作用**：把一个字符串 JSValue 的内容以 UTF-8 追加到调用方的字节缓冲，是引擎内 `JS_ToCStringLen2` 的等价出口（atom 驻留、数字解析、栈文本拼装、主机/FS 边界共用这一份编码）。
- **实现**：转调 `core.string.appendValueUtf8`：ASCII latin1 原样拷，latin1 0x80-0xFF 展成两字节 UTF-8，UTF-16 按代理对合并编码（qjs `JS_ToCStringLen2` quickjs.c:4458）。latin1 高位字节**不能**裸写，下游一律按 UTF-8 解读。该名字也在嵌入 API（`src/root.zig`）中公开。
- **所有权 / 错误 / 调用**：只往调用方拥有的 `std.ArrayList(u8)` 追加，缓冲的分配/释放全归调用方，本函数不建根也不产生 JS 值。error set 是 `core.string.appendValueUtf8` 的 `RuntimeError`（OOM、编码类）裸哨兵。42 处调用，典型 `src/exec/exception_ops.zig:140`、`src/exec/exception_ops.zig:459`、`src/js_context.zig:824`。


### `formatFiniteNumberAssumeCapacity` (`src/exec/value_ops.zig:635`)

- **签名**：`pub fn formatFiniteNumberAssumeCapacity(buffer: []u8, value: f64) []const u8`。
- **作用**：同上，但假定调用方缓冲足够大（不返回 error）。
- **实现**：转调 `core.value_format.formatFiniteNumberAssumeCapacity`。
- **所有权 / 错误 / 调用**：无：转调 core 版本写进调用方的栈缓冲（容量不足是调用方的契约违约，不返回错误），不分配、无 error set。6 处调用：本文件 `primitiveToStringValueFast` 的 float 臂（`:365`）与 `src/exec/json_ops.zig` 五处（`:978`、`:1424`、`:1538`、`:2025`、`:2407`）。


### `binaryBigInt` (`src/exec/value_ops.zig:639`)

- **签名**：`fn binaryBigInt(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：两个 BigInt 的二元运算。
- **实现**：先试 `shortBigIntBinary` 的 short×short 快路径。`add` 且一侧是正 short 时试 `addPositiveShortToBigInt`（就地加小数）。`mul` 且两侧都是堆 BigInt 且结果压不回 short 时走 `createMulInline`：header+limbs 一次分配（qjs `js_bigint_new` 的形状，quickjs.c:11860）。通用路径 `bigIntFromValueBorrowed` 取两侧（short 侧是新分配，`defer` 释放），按 op 调 `mulAlloc`/`div`/`rem`/`addAlloc`/`subAlloc`/`pow`/`bitwise`/`shiftBigInt`；`shr`（无符号右移）对 BigInt 是 TypeError。`DivisionByZero` / `NegativeExponent` / `BigIntTooLarge` 原样上抛，交给 `runtimeErrorInfo` 渲染 qjs 的具体 RangeError 文案。
- **所有权 / 错误 / 调用**：本文件所有权最密的一段。short×short 快臂零分配；`createMulInline` 一次分配直接产 GC BigInt；通用臂的 `bigIntFromValueBorrowed` 对 short 操作数返回 **owned** 副本、对堆 BigInt 返回**借用视图**，所以用 `lhs_is_owned`/`rhs_is_owned` 决定是否 `deinit`（借用视图 deinit 会毁掉堆对象的 limbs）；运算结果 `out` 是 owned，交给 `createBigIntOwned` 消费。`error.DivisionByZero` / `error.NegativeExponent` / `error.BigIntTooLarge` 故意原样上浮，好让 `runtimeErrorInfo` 渲染 qjs 的专用 RangeError 文案；BigInt 的 `shr` 是裸 `error.TypeError`。文件私有，唯一调用方 `binary`（`src/exec/value_ops.zig:25`）。

### `addPositiveShortToBigInt` (`src/exec/value_ops.zig:723`)

- **签名**：`fn addPositiveShortToBigInt(rt: *core.JSRuntime, value: core.JSValue, addend: bignum.Limb) !?core.JSValue`。
- **作用**：把一个正的 short BigInt 加进堆 BigInt 的快路径。
- **实现**：非 BigInt、无 header、或堆值为负都返回 null（回退通用路径）；否则 clone 一份后 `addPositiveSmallInPlace`，再 `createBigIntOwned` 交出所有权。
- **所有权 / 错误 / 调用**：返回的 JSValue 由调用方拥有；中途的 clone 由 `errdefer` 在失败时释放，成功时交给 `createBigIntOwned` 接管。

### `shortBigIntBinary` (`src/exec/value_ops.zig:735`)

- **签名**：`pub fn shortBigIntBinary(op: u8, lhs: i64, rhs: i64) ?core.JSValue`。
- **作用**：short BigInt 的二元快路径，装不下返回 null。
- **实现**：add/sub/mul 走带溢出检查的 `shortBigIntAdd/Sub/Mul`；and/xor/or 直接对 i64 位运算后装箱；其他 op（div/mod/pow/移位）返回 null。
- **所有权 / 错误 / 调用**：无：纯 i64 运算派发，不分配、无 error set；溢出或放不进 short bigint 时返回 `null`，由调用方退回堆路径。调用方 `binaryBigInt`（`:682`）与 `src/exec/vm_opcodes.zig:49`
、`:528`、`:649`。

### `shortBigIntUnary` (`src/exec/value_ops.zig:747`)

- **签名**：`pub fn shortBigIntUnary(op: u8, value: i64) ?core.JSValue`。
- **作用**：short BigInt 的一元快路径，装不下返回 null。
- **实现**：neg = `0 - value`，inc/dec 走 `shortBigIntAdd/Sub(±1)`，not 直接 `~value` 装箱；其他 op 返回 null。
- **所有权 / 错误 / 调用**：无：一元版的纯 i64 派发，不分配、无 error set，放不下返回 `null`。调用方 `unary`（`:249`）与 `src/exec/vm_opcodes.zig:256`、`:330`、`:389`、`:467` 四处。


### `shortBigIntAdd` (`src/exec/value_ops.zig:757`)

- **签名**：`fn shortBigIntAdd(lhs: i64, rhs: i64) ?core.JSValue`。
- **作用**：i64 加法，溢出或装不进 short BigInt 就返回 null。
- **实现**：`@addWithOverflow` 判溢出，再 `shortBigIntFits` 判范围。
- **所有权 / 错误 / 调用**：无：`@addWithOverflow` 加 `shortBigIntFits` 双重检查的纯函数，不分配、无 error set，放不下返回 `null`。文件私有，调用方 `shortBigIntBinary`（`:777`）与 `shortBigIntUnary`（`:791`）。

### `shortBigIntSub` (`src/exec/value_ops.zig:764`)

- **签名**：`fn shortBigIntSub(lhs: i64, rhs: i64) ?core.JSValue`。
- **作用**：i64 减法，溢出或装不进 short BigInt 就返回 null。
- **实现**：`@subWithOverflow` 判溢出，再 `shortBigIntFits` 判范围。
- **所有权 / 错误 / 调用**：无：同 `shortBigIntAdd` 的减法版，不分配、无 error set。文件私有，调用方 `shortBigIntBinary`（`:778`）与 `shortBigIntUnary`（`:789`、`:790`，neg 复用为 `0 - value`）。

### `shortBigIntMul` (`src/exec/value_ops.zig:771`)

- **签名**：`fn shortBigIntMul(lhs: i64, rhs: i64) ?core.JSValue`。
- **作用**：i64 乘法，溢出或装不进 short BigInt 就返回 null。
- **实现**：`@mulWithOverflow` 判溢出，再 `shortBigIntFits` 判范围。
- **所有权 / 错误 / 调用**：无：`@mulWithOverflow` 加 `shortBigIntFits` 的纯函数，不分配、无 error set。文件私有，唯一调用方 `shortBigIntBinary`（`:779`）。

### `binaryNumber` (`src/exec/value_ops.zig:778`)

- **签名**：`fn binaryNumber(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：数值二元运算（mul/div/mod/add/sub/pow）。
- **实现**：两侧取数值，取不到就 `toIntegerOrInfinity`；`mod` 用 `@rem`，`pow` 用 `jsMathPow`。结果装箱按 qjs `js_add_slow` / `js_binary_arith_slow`：**两侧都是 int tag** 才 `numberToValue` 归一（溢出转 float），只要有一侧是 float 就直接 `float64`，不再重新 int32 化。
- **所有权 / 错误 / 调用**：结果是立即数，不分配；非数值操作数经 `toIntegerOrInfinity` 走 ToString/ToNumber，其错误（BigInt 的裸 `error.TypeError`、`AppendStringError`）原样上浮。文件私有，唯一调用方 `binary`（`src/exec/value_ops.zig:46`、`:50`）。

### `toInt32` (`src/exec/value_ops.zig:798`)

- **签名**：`fn toInt32(rt: *core.JSRuntime, value: core.JSValue) !i32`。
- **作用**：ECMA-262 ToInt32（7.1.6）：`binary` 里 `shl`/`sar`/`shr`/`and`/`or`/`xor` 六个位运算的两个操作数、以及 `unary` 的 `not` 与非 double 慢路径，都靠它折成 i32。
- **实现**：`toIntegerOrInfinity` 之后：非有限或 NaN → 0；向零取整后对 2^32 取模，再 `@bitCast` 成 i32。
- **所有权 / 错误 / 调用**：自身不分配（字符串缓冲在 `toIntegerOrInfinity` 内释放）；错误全部是 `toIntegerOrInfinity` 的透传（BigInt 裸 `error.TypeError`、OOM）。文件私有，调用方 `binary` 的位运算臂（`:30`、`:31`）与 `unary`（`:234`、`:293`）。

### `stringAdd` (`src/exec/value_ops.zig:806`)

- **签名**：`fn stringAdd(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：`+` 的字符串臂。
- **实现**：任一侧 Symbol → TypeError。字符串+int32 / int32+字符串走 `stringAddStringInt`（suffix / prefix），不命中回落。双字符串走 `stringAddStringsOwned`。其余把两侧 `appendValueString` 进同一缓冲再 `createStringValue`。
- **所有权 / 错误 / 调用**：字符串×字符串臂把两个操作数的所有权交给 `stringAddStringsOwned`；混合臂用 `std.ArrayList(u8)` 局部缓冲（`defer deinit()`）再 `createStringValue` 新建 GC 字符串。Symbol 操作数返回裸 `error.TypeError` 哨兵。文件私有，唯一调用方 `binary` 的 add 前置分支（`src/exec/value_ops.zig:21`）。

### `stringAddStringInt` (`src/exec/value_ops.zig:827`)

- **签名**：`fn stringAddStringInt(rt: *core.JSRuntime, string_value: core.JSValue, int_value: i32, position: StringIntPosition) !?core.JSValue`。
- **作用**：「字符串 ± 整数」的拼接快路径，处理不了返回 null。
- **实现**：先在 value/tag 层面认 rope（避免 `stringObject` 触发 flatten）：空 rope 直接返回数字串，否则按 position 建平衡 rope 节点。非 rope：空串返回数字串；`borrowLatin1` 拿不到（UTF-16）返回 null；0..255 的整数用 `rt.smallIntString` 缓存的数字串，否则栈上 `formatInt32`，最后 `createLatin1Concat`。
- **所有权 / 错误 / 调用**：不消费入参；返回的新字符串（或 rope 节点）由调用方拥有。返回 null 表示「这条快路径处理不了」，不是错误。

### `addStringsOwned` (`src/exec/value_ops.zig:872`)

- **签名**：`pub fn addStringsOwned(rt: *core.JSRuntime, lhs: core.JSValue, rhs: core.JSValue) !core.JSValue`。
- **作用**：VM 的双字符串 `+` 入口：**消费**两个操作数，返回一个自有结果（对照 `JS_ConcatString`）。
- **实现**：直接转调 `stringAddStringsOwned`。
- **所有权 / 错误 / 调用**：名义上消费两个入参（tracing GC 下无实际释放动作），结果归 GC，调用方不释放；错误全部由 `stringAddStringsOwned` 产生（非字符串体的裸 `error.TypeError`、OOM / `error.StringTooLong`）。生产调用方只有寄存器驻留的 `op_add` 双字符串臂 `src/exec/tailcall_dispatch.zig:3291`，另有 3 处单测。


### `appendAsciiSuffixOwned` (`src/exec/value_ops.zig:879`)

- **签名**：`pub fn appendAsciiSuffixOwned(rt: *core.JSRuntime, value: core.JSValue, suffix: []const u8) !core.JSValue`。
- **作用**：**消费**一个已知字符串并接上 ASCII 字面量后缀，只分配一次结果。
- **实现**：`asStringBody` 取不到就 TypeError；否则 `core.string.String.createAsciiSuffix`，避免像 `JS_ConcatString3` 那样先把 suffix 物化成第二个 JSString。
- **所有权 / 错误 / 调用**：名义上消费入参字符串值（对照 `JS_ConcatString3`，tracing GC 下没有实际释放动作），返回 `createAsciiSuffix` 新建的 GC 字符串。入参不是字符串体时返回裸 `error.TypeError`，其余是 OOM / `error.StringTooLong`。唯一调用方 `src/exec/string_ops.zig:1078`（给 RegExp flags 追加 `"y"`）。

### `stringAddStringsOwned` (`src/exec/value_ops.zig:891`)

- **签名**：`fn stringAddStringsOwned(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !core.JSValue`。
- **作用**：两个字符串值的拼接核心：**消费**两侧，按 rope / tail-buffer / 平铺三类形态选最省的走法。
- **实现**：右侧非 rope 时：右为空返回左；左是 rope 且左为空返回右；左 rope 带 tail buffer 且右够短 → `appendTailBufferRope` 就地追加（必须排在下面的 QJS 短右合并之前，因为视图节点的 `right` 是未定义值）；左 rope 未线性化且两个短片段 → 把 `node.right` 与 b 合并后重建平衡 rope（QJS `ConcatString2` + `new_string_rope`）。左右都是平铺串时：左为空返回右；短右 + 中等长度左 → 左长度达到 `tail_buffer_seed_len` 就 `createTailBufferRope` 开 tail buffer（把 `s = s + x` 的二次项摊成一次拷贝），否则 `concatFlatStringBodiesOwned`。右侧是 rope 时对称处理左短片段。都不命中就 `createBalancedRopeOwned`，失败时它负责释放两侧。
- **所有权 / 错误 / 调用**：消费两个字符串操作数（`JS_ConcatString` 契约）：空串分支直接把另一侧原样返回，rope 分支把入参或其子节点转交给新节点，最终的 `createBalancedRopeOwned` 在分配/再平衡失败时负责释放两侧，所以中途不需要 errdefer；tail-buffer 分支就地追加进已有缓冲，不产生新字符串体。非字符串体返回裸 `error.TypeError`，其余是 OOM 与 `error.StringTooLong`。调用方 `stringAdd`（`:854`）与 pub 包装 `addStringsOwned`（`:913`）。

### `concatFlatStringBodiesOwned` (`src/exec/value_ops.zig:987`)

- **签名**：`fn concatFlatStringBodiesOwned( rt: *core.JSRuntime, a_string: *core.string.String, b_string: *core.string.String, ) !core.JSValue`。
- **作用**：两个平铺 String 体的拼接；名字里的 `Owned` 指的是外层 `JS_ConcatString` 契约，它本身只读两个 String 体、不释放它们。

- **实现**：长度相加溢出或超 `core.string.max_length` → `error.StringTooLong`。双 latin1：先试 `percentHexConcat` 的缓存串，否则 `createLatin1Concat` 直接分配+memcpy。双 utf16：`createUtf16Concat`。宽度混合才退回 `ArrayList(u16)` + `appendStringUtf16Units` + `createUtf16`。
- **所有权 / 错误 / 调用**：入参是两个**借用**的 `*core.string.String` 体（不消费，调用方那侧的所有权由 `stringAddStringsOwned` 统一处理），输出是新建的 GC 字符串；混宽度臂的 `std.ArrayList(u16)` 由 `initCapacity` 分配并 `defer deinit()`。长度相加溢出或超 `core.string.max_length` 返回裸 `error.StringTooLong`（由 `runtimeErrorInfo` 渲染成 RangeError）。文件私有，调用方 `stringAddStringsOwned`（`:965`、`:991`、`:1009`）。

### `percentHexConcat` (`src/exec/value_ops.zig:1025`)

- **签名**：`fn percentHexConcat(rt: *core.JSRuntime, a: []const u8, b: []const u8) !?core.JSValue`。
- **作用**：`"%" + hex` 这类 URI 编码碎片的缓存串快路径。
- **实现**：`"%"` 加一个十六进制字符 → `rt.recentTwoUnitString('%', b[0])`；`"%X"` 再加一个十六进制字符 → `rt.percentHexString((high << 4) | low)`。其余返回 null。
- **所有权 / 错误 / 调用**：命中时返回的是 runtime 缓存串的值，调用方按普通拥有值处理；未命中返回 null。

### `upperHexValue` (`src/exec/value_ops.zig:1039`)

- **签名**：`fn upperHexValue(byte: u8) ?u8`。
- **作用**：ASCII 十六进制数字的取值（非十六进制返回 null）。
- **实现**：转调 `unicode_lib.asciiUpperHexDigitValueByte`。
- **所有权 / 错误 / 调用**：无：`unicode_lib.asciiUpperHexDigitValueByte` 的查表包装，不分配、无 error set。文件私有，唯一调用方 `percentHexConcat`（`:1066`、`:1071`、`:1072`）。

### `stringObject` (`src/exec/value_ops.zig:1043`)

- **签名**：`fn stringObject(value: core.JSValue) ?*core.string.String`。
- **作用**：取值背后的 `String` 体。
- **实现**：转调 `value.asStringBody()`（rope 会在这里物化，所以 rope 敏感的路径要先在 tag 层判断）。
- **所有权 / 错误 / 调用**：返回**借用**的 `*core.string.String`，不 retain、不建根；注意 `asStringBody()` 会把 rope 物化，所以 `stringAddStringInt` 必须先在 value/tag 层判 rope 再调它。无 error set，非字符串返回 `null`。文件私有，调用方 `toNumberValue`（`:401`）与 `stringAddStringInt`（`:881`）。

### `appendStringUtf16Units` (`src/exec/value_ops.zig:1047`)

- **签名**：`fn appendStringUtf16Units(rt: *core.JSRuntime, out: *std.ArrayList(u16), string: *const core.string.String) !void`。
- **作用**：把一个 String body 按 UTF-16 代码单元展开进 `ArrayList(u16)`，供 `concatFlatStringBodiesOwned` 在两个操作数宽度不同（latin1 + utf16）、拼不出同宽快路径时统一成宽字符串。
- **实现**：latin1 按字节逐个 `append` 成 u16；utf16 直接 `appendSlice`。
- **所有权 / 错误 / 调用**：只往调用方拥有的 `std.ArrayList(u16)` 追加（latin1 逐字节零扩展，utf16 整段 `appendSlice`），缓冲归调用方；错误只有 append 的 OOM。文件私有，唯一调用方 `concatFlatStringBodiesOwned` 的混宽度臂（`:1060`、`:1061`）。

### `shiftBigInt` (`src/exec/value_ops.zig:1056`)

- **签名**：`fn shiftBigInt(allocator: std.mem.Allocator, lhs: bignum.BigInt, rhs: bignum.BigInt, direction: enum { left, right }) !bignum.BigInt`。
- **作用**：BigInt 的 `<<` / `>>`，负移位量等价于反向移位。
- **实现**：clone 出移位量取绝对值，`effective_right = (direction == .right) != negative_shift`。移位量超过一个 limb 时：有效右移饱和成 0 或 -1（按 lhs 符号，qjs `js_bigint_shr` 的 `d >= a->len` 臂），有效左移的非零值报 `error.BigIntTooLarge`（qjs `js_bigint_shl` → `js_bigint_new` quickjs.c:11592-11596），零值返回 0n。否则按方向调 `shl` / `shr`。
- **所有权 / 错误 / 调用**：入参 `lhs`/`rhs` 借用，返回的 BigInt **新分配**由调用方处置（`binaryBigInt` 交给 `createBigIntOwned`）；超限返回 `error.BigIntTooLarge`。

### `parseJsNumber` (`src/exec/value_ops.zig:1077`)

- **签名**：`fn parseJsNumber(bytes: []const u8) f64`。
- **作用**：转发到 core 的 StringNumericLiteral 解析（ToNumber 的字符串分支）：`toNumberValue` 的 utf16 慢路径与 `toIntegerOrInfinity` 的通用路径先把值渲染成 UTF-8 缓冲，再交给它出 f64。
- **实现**：转调 `core.value_format.parseJsNumber`。
- **所有权 / 错误 / 调用**：无：`core.value_format.parseJsNumber` 的包装，只读借用字节，不分配、无 error set（解析失败即 NaN）。文件私有，调用方 `toNumberValue`（`:415`）与 `toIntegerOrInfinity`（`:557`）。

### `valuesEqual` (`src/exec/value_ops.zig:1081`)

- **签名**：`fn valuesEqual(a: core.JSValue, b: core.JSValue) bool`。
- **作用**：`===` 的判定体（含 NaN≠NaN、字符串按内容比）。
- **实现**：双 BigInt 走 `compareBigIntValues`；双数值取 f64 比较且 NaN 恒 false；int32、bool 各自同 tag 比较；null/undefined 用 `same`；双字符串同指针即真，否则 `compareStringValues(eq_only = true)`；其余落到 `a.same(b)` 的身份比较。
- **所有权 / 错误 / 调用**：无堆分配：BigInt 走栈上 limb scratch 的 `compareBigIntValues`，字符串走 `core.string.compareStringValues`（不物化 rope），其余是 tag 比较。无 error set。文件私有，调用方 `strictEqual`（`:198`）与 `strictNotEqual`（`:202`）。

### `compareBigIntValues` (`src/exec/value_ops.zig:1105`)

- **签名**：`fn compareBigIntValues(a: core.JSValue, b: core.JSValue) ?std.math.Order`。
- **作用**：两个 BigInt 值（short 或堆）的大小比较。
- **实现**：各用一个 `[2]Limb` 栈上 scratch 经 `bigIntParts` 取出符号与 limbs，交给 `bignum.compareParts`；任一侧不是 BigInt 返回 null。
- **所有权 / 错误 / 调用**：局部缓冲在**栈**上：两个 `[2]bignum.Limb` scratch 供 short bigint 展开，`bigIntParts` 返回的 limb 切片借用它们或堆 BigInt 的内部 limbs，都不得逃出本帧。无堆分配、无 error set，非 BigInt 返回 `null`。文件私有，调用方 `compareBigIntRelational`（`:94`）与 `valuesEqual`（`:1123`）。

### `bigIntParts` (`src/exec/value_ops.zig:1118`)

- **签名**：`fn bigIntParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntParts`。
- **作用**：把 BigInt 值拆成 (符号, limbs) 视图，short BigInt 写进调用方给的 scratch。
- **实现**：short：取绝对值后按 limb 位宽切片写进 scratch（0 得到空 limbs）；堆 BigInt：直接借 `big.negative()` / `big.limbs()`；其余返回 null。
- **所有权 / 错误 / 调用**：返回的 `limbs` 是**借用**切片：short bigint 指向调用方传入的栈 `scratch`，堆 BigInt 直接指向对象内部 limbs（不 retain、不建根），生命周期都不超过调用方那一帧。不分配、无 error set。文件私有，唯一调用方 `compareBigIntValues`（`:1148`、`:1149`）。

### `isHTMLDDA` (`src/exec/value_ops.zig:1141`)

- **签名**：`pub fn isHTMLDDA(value: core.JSValue) bool`。
- **作用**：判断值是否带 [[IsHTMLDDA]]（`document.all` 这类在 `typeof`/ToBoolean/松散相等里伪装成 undefined 的对象）。

- **实现**：转调 `core.value_semantics.isHTMLDDA`（`document.all` 那类 [[IsHTMLDDA]] 值）。
- **所有权 / 错误 / 调用**：无：`core.value_semantics.isHTMLDDA` 的只读谓词包装，不分配、无 error set。8 处调用，典型 `src/exec/vm_opcodes.zig:781`、`src/exec/vm_opcodes.zig:188`、`:212`。

### `compareStringValues` (`src/exec/value_ops.zig:1145`)

- **签名**：`fn compareStringValues(a: core.JSValue, b: core.JSValue, eq_only: bool) ?i32`。
- **作用**：两个字符串值的比较，`eq_only` 时只判等。
- **实现**：转调 `core.string.compareStringValues`。
- **所有权 / 错误 / 调用**：无：转调 `core.string.compareStringValues`，两个字符串值都是借用，不分配、无 error set；不可比（非字符串体）返回 `null`，由调用方转成 `error.TypeError` 或 false。文件私有，调用方 `compare`（`:59`）与 `valuesEqual`（`:1140`）。

### `jsMathPow` (`src/exec/value_ops.zig:1149`)

- **签名**：`fn jsMathPow(lhs: f64, rhs: f64) f64`。
- **作用**：`**` / `Math.pow` 的 JS 语义幂。
- **实现**：底数绝对值为 1 且指数非有限时返回 NaN（JS 与 C `pow` 的分歧点），其余 `std.math.pow`。
- **所有权 / 错误 / 调用**：无：纯 f64 运算（`|lhs| == 1` 且指数非有限时按 spec 返回 NaN），不分配、无 error set。文件私有，唯一调用方 `binaryNumber` 的 pow 臂（`src/exec/value_ops.zig:827`）。

### `valuesStrictEqual` (`src/exec/value_ops.zig:1156`)

- **签名**：`pub fn valuesStrictEqual(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !bool`。
- **作用**：VM 侧的严格相等，字符串比较可能要物化字节。
- **实现**：双数值按 f64 比（NaN 恒 false）；bool 同 tag 比；null/undefined 用 `same`；双 BigInt 用 `sameValue`；双字符串同指针即真，否则各自 `appendRawString` 成 UTF-8 后 `std.mem.eql`；其余 `a.same(b)`。
- **所有权 / 错误 / 调用**：两个临时字节缓冲在函数内释放；只有字符串分支会分配（可能 OOM）。

### `cloneBigIntValue` (`src/exec/value_ops.zig:1183`)

- **签名**：`pub fn cloneBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt`。
- **作用**：把 BigInt 值复制成独立的 `bignum.BigInt`。
- **实现**：转调 `core.value_format.cloneBigIntValue(rt.memory.allocator, value)`。
- **所有权 / 错误 / 调用**：返回值由调用方 `deinit`。

### `appendValueString` (`src/exec/value_ops.zig:1188`)

- **签名**：`pub fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void`。
- **作用**：本文件对共享 ToString 的策略封装：把任意 JSValue 的 ToString 结果按 UTF-8 追加进缓冲，且 Symbol 不抛 TypeError 而是写出它的描述文本（`.symbol = .describe`），用于诊断/内部渲染而非可观察的 ToString。
- **实现**：转调 `core.value_string.appendValueString`，本文件的策略是 `.{ .symbol = .describe }`（Symbol 走描述而不是抛错）。
- **所有权 / 错误 / 调用**：只往调用方拥有的 `std.ArrayList(u8)` 追加，缓冲归调用方；本文件钉的策略是 `.{ .symbol = .describe }`（Symbol 写描述而不是抛 TypeError），这是它与带 realm 的 ToString 的唯一语义差别。error set `AppendStringError` = `core.errors.RuntimeError`，裸哨兵。8 处调用，典型 `src/root.zig:104`、`src/exec/property_ops.zig:79`、`src/exec/object_ops.zig:3874`。


## `src/exec/exception_ops.zig` — Error 记录缝

`.error_object`：`toString`、stack getter/setter、`captureStackTrace`。构造器不走这张表。`errorCall` 校验 `Error.captureStackTrace` 的 receiver 是名为 Error 的可调用对象。


### `errorEntry` (`src/exec/exception_ops.zig:42`)

- **签名**：`fn errorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，为 `.error_object` domain 的四条记录——`Error.prototype.toString`、`stack` 的 getter 与 setter、静态 `Error.captureStackTrace`——各生成一行 `InternalEntry`。
- **实现**：`.id` 与 `.magic` 都取传入 id，`cproto` 固定 `.generic_magic`，`native_function` 是 `genericMagicFunction(&errorCall)`。表里四条：`toString`、`get stack`、`set stack`、`captureStackTrace`。
- **所有权 / 错误 / 调用**：只在 comptime 求值（表本身是 `errorEntries:` 块），产物是静态表项，无运行期分配。

### `errorCall` (`src/exec/exception_ops.zig:53`)

- **签名**：`fn errorCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：上面四条记录共用的 native 函数体：还原执行环境后按记录 id 分派，并承担 `Error.captureStackTrace` 的 receiver 校验（必须是名为 `Error` 的可调用对象）。
- **实现**：`nativeCall` + `callableRealm` 之后按 id 分派。`capture_stack_trace` 先校验 receiver：`call.thisObject` 取到对象、`isCallableValue(this_value)`、`constructorNameEqlLocal(receiver, "Error")`，三者任一不成立都是 TypeError，然后进 `error_stack_ops.errorCaptureStackTrace`。其余：`to_string` → `string_ops.errorToStringCall`；`stack_getter` → `errorStackGetter`；`stack_setter` 需要 `host_call.func_obj`（缺则 TypeError）再进 `errorStackSetter`；未知 id → TypeError。
- **所有权 / 错误 / 调用**：`this_value` / `args` 借用，返回值归 GC。`nativeCall` 认不出调用形态时返回 `null` → 裸 `error.TypeError`；`capture_stack_trace` 的三道校验（非对象 receiver、不可调用、构造器名不是 `Error`）与 `else` 分支同样是**裸**哨兵，没有 pending exception，由 native seam 的 `builtin_dispatch.materializeRuntimeError` 渲染；被转发的 `errorStackGetter` / `errorStackSetter` / `errorCaptureStackTrace` / `errorToStringCall` 则可能已经挂好 pending exception。realm 由 `callableRealm(host_call)` 原子选定，之后所有下游都用 `realm.global`。没有直接调用方：它经 `internal_entries` 的 `genericMagicFunction(&errorCall)`（`src/exec/exception_ops.zig:49`）由 `.error_object` 记录表分发。


## `src/exec/exception_ops.zig` — stack 捕获与 CallSite

对照 `build_backtrace`（quickjs.c:7553-7658）。`Error.prepareStackTrace` 若可调用则用之，并用 `formatting_error_stack` 防重入。顶层脚本帧名字==文件名时渲染 `"<eval>"`。


### `captureErrorStack` (`src/exec/exception_ops.zig:28`)

- **签名**：`pub fn captureErrorStack(ctx: *core.JSContext, global: *core.Object, instance: *core.Object) !void`。
- **作用**：在 Error 实例上捕获当前 VM 回溯，存成 CallSite 数组槽（格式化留到读 `stack` 时）。
- **实现**：`buildCallSiteArray(ctx, global, null)` 后 `instance.setErrorStackSites`。
- **所有权 / 错误 / 调用**：`buildCallSiteArray` 新建的 CallSite 数组立刻交给 `instance.setErrorStackSites` 存进 Error 的 ordinary payload，由 payload 拥有；该 setter 内部会打 `rt.gc.generationalBarrier`（Error 可能已被 minor 提升，sites 是新生代子对象），本函数自己不建根。错误是数组构造与 payload 分配的 OOM 透传（裸哨兵）。4 处调用：`attachStackToErrorValue`（`src/exec/exception_ops.zig:41`）与 `src/exec/object_ops.zig:735`、`:828`、`:934` 的 Error 实例构造点。

### `attachStackToErrorValue` (`src/exec/exception_ops.zig:38`)

- **签名**：`pub fn attachStackToErrorValue(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !void`。
- **作用**：值层面的栈捕获：值是对象才挂 CallSite，原始值直接忽略。
- **实现**：`expectObject` 失败就 `return`（不报错），否则转 `captureErrorStack`。这是 `exception_ops` 各构造原语在「构造时抓栈」的接缝（对照 qjs `JS_ThrowError2` 里的 `build_backtrace`）。
- **所有权 / 错误 / 调用**：非对象值被 `property_ops.expectObject(...) catch return` 静默忽略（不是错误，也不是 no-op 以外的语义）；对象走 `captureErrorStack`，sites 数组的所有权与写屏障都在那里处理。错误只有透传。3 处调用，全在 `src/exec/exception_ops.zig`：`:33`（`createNamedError`）、`:97`、`:291`（`promiseAggregateError`）。

### `buildErrorStackValue` (`src/exec/exception_ops.zig:43`)

- **签名**：`pub fn buildErrorStackValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, skip_name: ?[]const u8) !core.JSValue`。
- **作用**：产出 `Error.prototype.stack` 的值：优先交给用户的 `Error.prepareStackTrace`，否则用内建文本格式。
- **实现**：`ctx.runtime.formatting_error_stack` 已置位（重入）时直接走 `buildErrorStackStringValue`。否则若 `errorPrepareStackTrace` 拿到可调用的 hook：先 `buildCallSiteArray(skip_name)`，置 `formatting_error_stack`（`defer` 复位）后 `callValueOrBytecodeRoot(undefined, prepare, {error_value, sites})`。hook 抛错时：命中 pending exception 就 `takeException` 并返回 null 值；否则清异常，`runtimeErrorInfo(err) != null` 也返回 null 值，其余 error 上抛。没有 hook 就回落内建文本。
- **所有权 / 错误 / 调用**：返回新建的 GC 字符串，或用户 `Error.prepareStackTrace` 钩子的返回值（同样归 GC）。`ctx.runtime.formatting_error_stack` 是重入闸：置位 + `defer` 复位，防止钩子里再读 `.stack` 无限递归。钩子抛错时的错误处理是本函数的要点：pending exception 与 err 匹配就 `takeException()` **吞掉**并返回 `null` 值；否则 `clearException()` 后凡是 `runtimeErrorInfo` 认识的引擎 sentinel 也折成 `null` 值，只有它不认识的错误才上浮。调用方 `errorStackGetter`（`:254`）与 `errorCaptureStackTrace`（`:342`）。

### `formatCapturedErrorStackValue` (`src/exec/exception_ops.zig:63`)

- **签名**：`pub fn formatCapturedErrorStackValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, sites_value: core.JSValue, site_count: usize, ) !core.JSValue`。
- **作用**：已经抓好 CallSite 数组的 Error 读 `stack` 时的格式化入口。
- **实现**：与 `buildErrorStackValue` 同形，只是不再重新采集：重入或无 hook 时走 `formatCapturedErrorStackStringValue(sites_value, site_count)`，有 hook 时把现成的 sites 数组传给它，错误处理（pending exception → null 值）也一致。
- **所有权 / 错误 / 调用**：「已有 sites」版本：`sites_value` 是从 Error payload 借来的数组，不 dup 不建根；返回新建的 GC 字符串或钩子结果。与 `buildErrorStackValue` 共用同一套 `formatting_error_stack` 防递归与「把钩子异常吞成 `null` 值」的错误策略。唯一调用方 `errorStackGetter`（`src/exec/exception_ops.zig:250`）。

### `throwParseSyntaxError` (`src/exec/exception_ops.zig:98`)

- **签名**：`pub fn throwParseSyntaxError( ctx: *core.JSContext, global: *core.Object, filename: []const u8, line: u32, col: u32, message: []const u8, ) !core.JSValue`。
- **作用**：解析/编译期报错的统一出口：按 `filename:line:col` 造一个栈已经铺好的 `SyntaxError`，挂进 pending exception，并返回 `error.SyntaxError` 哨兵。
- **实现**：line/col 用 `std.math.cast` 转 i32，溢出饱和成 `maxInt(i32)`；`createNamedErrorWithoutStack("SyntaxError", message)` 建对象，`defineParseErrorSurface` 铺开 fileName/lineNumber/columnNumber 与预建 stack，然后 `ctx.throwValue(error_value)` 并返回 `error.SyntaxError` 这个哨兵（对照 qjs `build_backtrace` 的 filename 分支，quickjs.c:7553-7570：编译错误的栈在抛出时就建好）。
- **所有权 / 错误 / 调用**：`createNamedErrorWithoutStack` 建出的 Error 归 GC（注释里「构造失败就 free」在 tracing GC 下退化成交给 GC）；`ctx.throwValue(error_value)` 之后异常槽是它的根。返回的 `error.SyntaxError` 是**已挂 pending exception** 的哨兵，调用方不必再 materialize；`defineParseErrorSurface` 失败则在挂异常之前原样上浮。5 处调用：`src/exec/eval_entry.zig:441`、`src/exec/eval_entry.zig:127`、`src/exec/function_ops.zig:500`，另有 `call_runtime.zig:3371`、`call.zig:2496` 两处。

### `defineParseErrorSurface` (`src/exec/exception_ops.zig:120`)

- **签名**：`fn defineParseErrorSurface( ctx: *core.JSContext, global: *core.Object, error_value: core.JSValue, filename: []const u8, line_num: i32, col_num: i32, ) !void`。
- **作用**：给上面那个 `SyntaxError` 对象补齐可观察表面：三个 own 属性 `fileName` / `lineNumber` / `columnNumber`，外加一条预先渲染好、直接写进 error 的 stack 槽的栈文本（编译错误没有真实调用帧可在读 `stack` 时回溯）。
- **实现**：`expectObject` 失败直接返回。三个 own 数据属性 `fileName` / `lineNumber` / `columnNumber` 都以 (writable=true, enumerable=false, configurable=true) 定义。再把 `"    at {file}:{line}:{col}\n"` 打进临时缓冲，接上 `buildErrorStackStringValue` 的默认帧文本，`createStringValue` 后 `instance.setErrorStack`，于是惰性 `stack` 访问器原样返回它。
- **所有权 / 错误 / 调用**：新建两个 GC 字符串（fileName 与最终 stack），分别由属性槽和 `setErrorStack` 的 payload 持有；`setErrorStack` 内部打 generational barrier（TGC S2 之后字符串体也是 tracer cell）。`std.ArrayList(u8)` 是真正的局部缓冲，`defer bytes.deinit` 释放。非对象 `error_value` 被 `catch return` 忽略。此时 Error 还没进异常槽，所有错误都是裸哨兵向上传。文件私有，唯一调用方 `throwParseSyntaxError`（`src/exec/exception_ops.zig:114`）。

### `errorPrepareStackTrace` (`src/exec/exception_ops.zig:144`)

- **签名**：`fn errorPrepareStackTrace(global: *core.Object) !?core.JSValue`（文件私有）。
- **作用**：取 `Error.prepareStackTrace` hook，不可调用（或 `Error` 不是对象）时返回 null。
- **实现**：`global.getProperty(Error)` → `expectObject`（失败 null）→ `getProperty(prepareStackTrace)` → `isCallableValue` 过滤。
- **所有权 / 错误 / 调用**：两次 `getProperty` 都是不触发 accessor 的普通读，返回的 `prepare` 是**借用**值，调用方在 `formatting_error_stack` 窗口内立即用掉。`Error` 不是对象或钩子不可调用时返回 `null` 而不是错误；错误只有 `getProperty` 自身的透传（如未初始化 var_ref 的 `error.ReferenceError`）。文件私有，调用方 `buildErrorStackValue`（`:47`）与 `formatCapturedErrorStackValue`（`:74`）。

### `backtraceFunctionNameEql` (`src/exec/exception_ops.zig:156`)

- **签名**：`pub fn backtraceFunctionNameEql(ctx: *core.JSContext, entry: core.BacktraceFrame, expected: []const u8) bool`。
- **作用**：回溯帧的显示名是否等于给定字符串。
- **实现**：`std.mem.eql(u8, callSiteFunctionName(ctx, entry), expected)`，因此比的是渲染后的名字（含 `<anonymous>` / `<eval>` 映射）。
- **所有权 / 错误 / 调用**：无：比对 `callSiteFunctionName` 返回的借用切片，不分配、无 error set。2 处调用，都是栈格式化时跳过 `captureStackTrace` 指定的起始帧：`src/exec/string_ops.zig:677`、`src/exec/array_ops.zig:289`。

### `callSiteFunctionName` (`src/exec/exception_ops.zig:168`)

- **签名**：`pub fn callSiteFunctionName(ctx: *core.JSContext, entry: core.BacktraceFrame) []const u8`。
- **作用**：回溯帧的显示名（对照 qjs build_backtrace，quickjs.c:7580-7586）。
- **实现**：从 atom 表取函数名与文件名：名字为空 → `"<anonymous>"`；名字与文件名相同 → `"<eval>"`（zjs 顶层字节码的 name 就是 filename，qjs 那边是编译器把顶层命名成 `JS_ATOM__eval_`，quickjs.c:37252）；否则原名。
- **所有权 / 错误 / 调用**：返回的是 atom 表里的**借用**名字切片，或静态字面量 `"<anonymous>"` / `"<eval>"`；调用方不得释放，也不能跨 atom 表变动继续持有。不分配、无 error set。文件内唯一调用方 `backtraceFunctionNameEql`（`src/exec/exception_ops.zig:158`）。

### `callSiteFunctionNameValue` (`src/exec/exception_ops.zig:176`)

- **签名**：`pub fn callSiteFunctionNameValue(ctx: *core.JSContext, entry: core.BacktraceFrame) !core.JSValue`。
- **作用**：同 `callSiteFunctionName`，但产出 CallSite 用的 JS 值。
- **实现**：名字为空返回 **null 值**（不是 `"<anonymous>"`）；名字等于文件名返回字符串 `"<eval>"`；否则把原名铸成字符串。
- **所有权 / 错误 / 调用**：与上面的切片版不同，这里**新建** GC 字符串（`"<eval>"` 或函数名），匿名帧返回 `null` 值；返回值归 GC，错误只有 OOM。唯一调用方 `src/exec/object_ops.zig:983`（构造 CallSite 对象的 functionName 槽）。

### `errorStackTraceLimit` (`src/exec/exception_ops.zig:184`)

- **签名**：`pub fn errorStackTraceLimit(_: *core.JSRuntime, global: *core.Object) usize`。
- **作用**：读 `Error.stackTraceLimit`，决定回溯最多收几帧。
- **实现**：默认 10：`Error` 不是 own 数据对象、或没有 own `stackTraceLimit` 都取 10；值是 undefined/null → 0；取不出数值 → 10；非有限或 ≤0 → 0；否则 `@floor` 并在超过 `maxInt(usize)` 时夹住。`rt` 参数未使用。
- **所有权 / 错误 / 调用**：runtime 参数未使用。只读 `Error.stackTraceLimit` 的**自有数据属性借用值**（`getOwnDataObjectBorrowed` + `getOwnDataPropertyValue`：不走原型链、不触发 accessor、不重入 JS），缺省 10。不分配、无 error set——非数值/不可用一律折成 10 或 0。2 处调用：`src/exec/string_ops.zig:666`、`src/exec/array_ops.zig:279`。

### `appendBacktraceFunctionName` (`src/exec/exception_ops.zig:197`)

- **签名**：`pub fn appendBacktraceFunctionName( ctx: *core.JSContext, bytes: *std.ArrayList(u8), function_name: core.Atom, filename: core.Atom, ) !void`。
- **作用**：拼装 `error.stack` 文本时写出一帧的函数名，数据来自帧记录里的两个 atom；匿名帧和顶层 script/eval 帧在这里归一成 `<anonymous>` / `<eval>`。
- **实现**：与 `callSiteFunctionName` 同一套映射，只是直接往缓冲里写：空名写 `"<anonymous>"`，名字等于文件名写 `"<eval>"`，否则写原名。
- **所有权 / 错误 / 调用**：只往调用方缓冲里 append，缓冲归调用方（`string_ops.zig:684` 的 backtrace 渲染）；error 只有 `OutOfMemory`。

### `appendCallSiteFunctionName` (`src/exec/exception_ops.zig:215`)

- **签名**：`pub fn appendCallSiteFunctionName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void`。
- **作用**：同样写一帧的函数名，但取自 CallSite 对象的内部槽——即 `Error.prepareStackTrace` 把帧暴露成 CallSite 之后的那条渲染路径。
- **实现**：`site.callSiteFunctionName()` 取不到、或取到的不是字符串，都写 `"<anonymous>"`；否则 `value_ops.appendRawString` 写进缓冲。
- **所有权 / 错误 / 调用**：只往调用方缓冲里 append（调用点 `string_ops.zig:712`）；`site` 借用，不改内部槽；error 只有 `OutOfMemory`。

### `appendCallSiteFileName` (`src/exec/exception_ops.zig:227`)

- **签名**：`pub fn appendCallSiteFileName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void`。
- **作用**：从 CallSite 对象的内部槽取源文件名写进缓冲，是上一条的文件名对应项（调用点把它写进单独的 `filename_bytes` 缓冲再拼进帧行）。
- **实现**：`site.callSiteFile()` 取不到、或取到的不是字符串，都写 `"<anonymous>"`；否则 `value_ops.appendRawString`。
- **所有权 / 错误 / 调用**：只往调用方缓冲里 append（调用点 `string_ops.zig:721`）；`site` 借用；error 只有 `OutOfMemory`。

### `errorStackGetter` (`src/exec/exception_ops.zig:239`)

- **签名**：`pub fn errorStackGetter( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, ) !core.JSValue`。
- **作用**：`Error.prototype.stack` 的 getter：惰性把捕获的 CallSite 格式化成字符串并缓存。
- **实现**：this 不是对象 → TypeError；class 不是 `error_` → 返回 undefined（不报错）。已有 `errorStack()` 直接返回缓存。有 `errorStackSites()` 就 `formatCapturedErrorStackValue`（传 `errorStackSiteCount()`）并 `setErrorStack` 缓存。两者都没有才现场 `buildErrorStackValue`（不缓存）。
- **所有权 / 错误 / 调用**：命中缓存时返回 payload 里的**借用**值（`object.errorStack()`）；否则新建字符串（`formatCapturedErrorStackValue` / `buildErrorStackValue`），并用 `setErrorStack` 写回 payload（带 generational barrier）后返回同一个值。非对象 this 是裸 `error.TypeError`；非 `error_` class 返回 `undefined` 而不抛。2 处调用：`src/exec/exception_ops.zig:79`（stack getter 记录）与 `src/exec/call.zig:424`（inspector 用 `catch break :blk null` 吞掉这里的错误）。

### `errorStackSetter` (`src/exec/exception_ops.zig:256`)

- **签名**：`pub fn errorStackSetter( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Error.prototype.stack` 的 setter：把访问器覆盖成 own 数据属性，同时兼容 Proxy 与用户自定义 setter。
- **实现**：this 不是对象 → TypeError；值不是字符串 → TypeError；this 恰好是 realm 的 `Error.prototype` → TypeError。取 `stack` 的 proxy-aware own descriptor：不存在就新建 (writable, enumerable, configurable) 全真的数据属性（proxy 走 `proxyDefineOwnProperty`，普通对象 `defineOwnProperty`，`ReadOnly`/`NotExtensible`/`IncompatibleDescriptor` 折成 TypeError、`InvalidLength` 折成 RangeError）。已有 descriptor：若它是访问器且 setter 就是本函数对象（`isErrorStackSetterValue`），先试 `proxySetTrapForErrorStackSetter`，否则 `defineErrorStackDataProperty` 落成数据属性。receiver 是 proxy 则走 `proxySetValueProperty`（返回 false → TypeError）。剩下按 kind：访问器且 setter 为 undefined → TypeError，否则调用用户 setter；数据属性不可写 → TypeError，否则 `defineErrorStackDataProperty`。
- **所有权 / 错误 / 调用**：不新建值：写入的是借用的 `args[0]` 字符串，最终由属性槽（`defineErrorStackDataProperty`）或 proxy set trap 接管。错误面很宽且全部是裸哨兵 `error.TypeError`：this 非对象、值非字符串、receiver 就是 `Error.prototype`、accessor 无 setter、数据属性不可写、proxy 拒绝；`defineOwnProperty` 的 `error.InvalidLength` 被翻成 `error.RangeError`，`ReadOnly`/`NotExtensible`/`IncompatibleDescriptor` 折成 `false` 后再转 TypeError。proxy trap 与用户 accessor 分支会重入 JS。唯一调用方 `src/exec/exception_ops.zig:82`。

### `isErrorStackSetterValue` (`src/exec/exception_ops.zig:322`)

- **签名**：`fn isErrorStackSetterValue(value: core.JSValue) bool`（文件私有）。
- **作用**：谓词：该值是否就是内建的 `Error.prototype.stack` setter 函数。
- **实现**：`decodeNativeBuiltinId(object.nativeFunctionId())` 后判 `domain == .error_object` 且 id 是 `PrototypeMethod.stack_setter`。
- **所有权 / 错误 / 调用**：无：解码函数对象的 native builtin id 后比对 domain 与 id，不分配、无 error set。唯一调用方是 `errorStackSetter` 的「setter 就是内建 stack setter」判定（`src/exec/exception_ops.zig:295`）。


### `errorCaptureStackTrace` (`src/exec/exception_ops.zig:328`)

- **签名**：`pub fn errorCaptureStackTrace( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`Error.captureStackTrace(target[, skipFn])`：在 target 上定义 `stack` 数据属性。
- **实现**：首参缺失或非对象 → TypeError `"not an object"`。第二参可调用时取其函数名当 `skip_name`（回溯里跳到该函数为止，用完 `free`）。`buildErrorStackValue` 产出值后 `defineDataPropertyByAtom(stack, writable=true, enumerable=false, configurable=true)`，返回 undefined。
- **所有权 / 错误 / 调用**：本簇里唯一持有真正堆缓冲的函数：`exception_ops.functionNameBytes` 返回 allocator 新分配的 `[]u8`，由这里的 `defer ... free` 释放。stack 值是新建的 GC 字符串，经 `defineDataPropertyByAtom` 挂成目标对象的 non-enumerable 属性，之后归属性槽。参数校验失败走 `exception_ops.throwTypeErrorMessage(ctx, global, "not an object")`——Error 已挂 `ctx`，返回的 `error.TypeError` 只是哨兵。唯一调用方 `src/exec/exception_ops.zig:73`。


## `src/exec/function_ops.zig` — Function.prototype 与动态函数

call/apply 有独立记录 + `forwards_call` + managed 直通 ABI，让 `op_call_method` 改写 operand window。`@@hasInstance` 是 `.generic`（不是 magic），24M `instanceof` 不进共享 switch。`constructDynamicFunctionFromSource` 拼 `(function anonymous(...) {\n...})` 再 `parser.compile`；嵌套 eval **不**在退出时跑全堆 cycle GC。


### `isDefaultHasInstanceRecord` (`src/exec/function_ops.zig:41`)

- **签名**：`pub fn isDefaultHasInstanceRecord(rt: *core.JSRuntime, record: *const core.NativeEntry) bool`。
- **作用**：谓词：该 NativeEntry 是不是本 realm 安装的默认 `Function.prototype[@@hasInstance]`。
- **实现**：用 `rt.internalBuiltinRecord(.function, has_instance)` 取密排表里的槽位，做**指针相等**比较（不是按名字、也不是 shape 缓存），对照 qjs 比 C 函数指针（quickjs.c:41395）。
- **所有权 / 错误 / 调用**：无：只做指针比较（把 `record` 与 runtime 内建记录表里 `.function`/`has_instance` 那一槽比地址），不分配、不 retain、无 error set；表里没有该槽时返回 false。唯一调用方 `src/exec/tailcall_dispatch.zig:6054`（`instanceof` 的默认 `@@hasInstance` 判定）。

### `recordIsDefaultHasInstance` (`src/exec/function_ops.zig:51`)

- **签名**：`pub inline fn recordIsDefaultHasInstance(record: *const core.NativeEntry) bool`。
- **作用**：同一身份判定的免运行时表版本。
- **实现**：`record.target == default_has_instance_target`；该常量来自 comptime 记忆化的 `entryFromInternal(functionHasInstanceEntry()).target`，所以表项和常量共享同一个 thunk 指针。
- **所有权 / 错误 / 调用**：无：与 `default_has_instance_target` 这个 comptime 常量比 `record.target` 指针，不查 runtime 表、不分配、无 error set。唯一调用方 `src/exec/tailcall_dispatch.zig:5993`。

### `functionHasInstanceEntry` (`src/exec/function_ops.zig:78`)

- **签名**：`fn functionHasInstanceEntry() core.host_function.InternalEntry`。
- **作用**：单独构造 `Function.prototype[Symbol.hasInstance]` 那一行 `InternalEntry`——本域唯一一条 `.generic` cproto 且带 `managed` 直通臂的记录。
- **实现**：与本域其他条目不同：`cproto` 是 `.generic`（qjs 的 `JS_CFUNC_DEF` 而非 `MAGIC_DEF`），`magic = 0`，`native_function = .{ .generic = &functionHasInstance }`，并带 `managed = &functionHasInstanceDirect`。这样 24M 次的 `instanceof` 不用挤进 `functionCall` 的 magic switch。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是 `internal_entries` 里的静态表项，无运行期分配。

### `functionHasInstanceDirect` (`src/exec/function_ops.zig:95`)

- **签名**：`fn functionHasInstanceDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`functionHasInstance` 的 exec-direct（managed ABI）孪生体。
- **实现**：`argv[0..argc]` 成切片；`ctx.global` 为空时 `hostErrorToValue(error.InvalidBuiltinRegistry)`；`builtin_dispatch.vmCallerView(ctx)` 取 output 与 caller 的 bytecode/frame（不做 NativeCallEnvironment 往返），转 `call_runtime.functionHasInstanceCall`，结果经 `hostResultToValue` 变成 JSValue（异常走哨兵值）。
- **所有权 / 错误 / 调用**：managed ABI 不返回 Zig error：失败经 `hostErrorToValue` / `hostResultToValue` 变成异常哨兵 JSValue，pending exception 留在 ctx 上。

### `functionCallDirect` (`src/exec/function_ops.zig:115`)

- **签名**：`fn functionCallDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`Function.prototype.call` 的 managed ABI 直通体。
- **实现**：与 `functionHasInstanceDirect` 同形，终点是 `call_runtime.functionCallCall`。`call_entry_target` 就是它的代码指针，VM 的 `op_call_method` 窗口改写臂靠它认身份。
- **所有权 / 错误 / 调用**：同上：错误以哨兵 JSValue 返回，不走 Zig error。

### `functionApplyDirect` (`src/exec/function_ops.zig:135`)

- **签名**：`fn functionApplyDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`Function.prototype.apply` 的 managed ABI 直通体。
- **实现**：与上面同形，终点是 `call_runtime.functionApplyCall`；`apply_entry_target` 是它的代码指针。
- **所有权 / 错误 / 调用**：同上：错误以哨兵 JSValue 返回，不走 Zig error。

### `functionHasInstance` (`src/exec/function_ops.zig:158`)

- **签名**：`fn functionHasInstance( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`Function.prototype[Symbol.hasInstance]` 的 `.generic` 记录 handler（qjs:41379）。
- **实现**：`nativeCall(..., magic = 0)` 恢复环境（失败 TypeError），`callableRealm` 后断言 realm 与 ctx 一致，转 `call_runtime.functionHasInstanceCall`：receiver 是构造器，`args[0]` 是被测值（对照 `JS_OrdinaryIsInstanceOf(ctx, argv[0], this_val)`）。
- **所有权 / 错误 / 调用**：`native_this`（构造器）与 `native_args`（被测值）都借用，返回 bool 立即数。`nativeCall` 认不出调用形态返回 `null` → 裸 `error.TypeError`（无 pending exception，由 native seam materialize）；其余错误由 `call_runtime.functionHasInstanceCall` 产生，可能已挂 pending exception（原型链读取会重入 JS/proxy）。没有直接调用方：经 `functionHasInstanceEntry()` 注册进 `.function` 记录表，并被 `default_has_instance_target` 取地址做身份常量。

### `functionEntry` (`src/exec/function_ops.zig:177`)

- **签名**：`fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，只给共用 magic switch 的两条记录 `Function.prototype.toString` 与 `Function.prototype.bind` 生成 `InternalEntry`；`call` / `apply` / `[Symbol.hasInstance]` 各有自己的构造函数。
- **实现**：`.id`/`.magic` 取传入 id，`cproto` = `.generic_magic`，handler 是 `genericMagicFunction(&functionCall)`；`toString` 与 `bind` 用它。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项，无运行期分配。

### `functionCallEntry` (`src/exec/function_ops.zig:188`)

- **签名**：`fn functionCallEntry() core.host_function.InternalEntry`。
- **作用**：`Function.prototype.call` 的专属条目（热的转发原语，不共享 magic switch）。
- **实现**：name `"call"`、length 1、`forwards_call = true`（进 `op_call_method` 的窗口改写臂）、`native_function = genericMagicFunction(&functionCallRecord)`、`managed = &functionCallDirect`。
- **所有权 / 错误 / 调用**：无运行期所有权：comptime 求值出一张静态 `InternalEntry`，`name` 是字面量。要点在两个字段指针：`native_function` 指 `functionCallRecord`（env 路径），`managed` 指 `functionCallDirect`（NB2-B 直接 ABI，省掉 `NativeCallEnvironment` 往返），`forwards_call = true` 让 VM 走 `op_call_method` 的窗口重写臂。两处调用都在本文件：`internal_entries` 表构造（`src/exec/function_ops.zig:62`）与 `call_entry_target` 常量（`:259`，取的正是 `managed` 那支 `functionCallDirect` 的代码指针）。


### `functionApplyEntry` (`src/exec/function_ops.zig:212`)

- **签名**：`fn functionApplyEntry() core.host_function.InternalEntry`。
- **作用**：`Function.prototype.apply` 的专属条目（qjs:41392 也是独立 C 函数）。
- **实现**：name `"apply"`、length 2、`forwards_call = true`、`native_function = genericMagicFunction(&functionApplyRecord)`、`managed = &functionApplyDirect`。VM 靠 `apply_entry_target` 认出 apply，把稠密数组实参直接铺进 operand window，其他 array-like 才落到本体。
- **所有权 / 错误 / 调用**：无运行期所有权：同样是 comptime 静态表项。`native_function` = `functionApplyRecord`、`managed` = `functionApplyDirect`、`forwards_call = true`；VM 靠 `apply_entry_target` 把它和 `call` 区分开，dense 参数列表由 VM 自己铺进操作数窗口，其余 array-like 才落到这个 body。两处调用都在本文件：`internal_entries` 表构造（`src/exec/function_ops.zig:63`）与 `apply_entry_target` 常量（`:260`）。


### `functionCall` (`src/exec/function_ops.zig:303`)

- **签名**：`fn functionCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.function` 域里**剩下**两个方法的共享 handler：`toString` 与 `bind`。
- **实现**：`nativeCall` 之后按 magic：`to_string` 直接 `call.functionToStringValue(rt, this)`（不取 realm）；`bind` 先 `callableRealm` 并断言 realm == ctx，再 `call.functionBindCall`；其余 id → TypeError。call/apply/@@hasInstance 都有自己的 handler，不走这里。
- **所有权 / 错误 / 调用**：this/args 借用；`to_string` 与 `bind` 的返回值都是新建的 GC 值。`nativeCall` 返回 `null` 与 `else` 分支是**裸** `error.TypeError`（无 pending exception）；`bind` 先 `callableRealm` 再进 `call.functionBindCall`，其错误可能已挂 pending exception。注意 `to_string` 臂**不**取 realm（只用 `ctx.runtime`），只有 `bind` 臂才付 realm 解析的代价。没有直接调用方：经 `functionEntry(...)` 的 `genericMagicFunction(&functionCall)` 由 `.function` 记录表分发（`toString`/`bind` 两项）。

### `functionApplyRecord` (`src/exec/function_ops.zig:326`)

- **签名**：`fn functionApplyRecord( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Function.prototype.apply` 的专用记录 handler（对照 qjs `js_function_apply` magic 0）：它不进 `functionCall` 的 magic switch，因为 apply 是热转发原语。
- **实现**：`nativeCall` 恢复环境（失败 TypeError）、`callableRealm` 并断言 realm 与 ctx 一致，然后把 this/args/caller 对交给 `call_runtime.functionApplyCall`。它是仍需要 env 往返的分发器用的 shim，热路径走 `functionApplyDirect`。
- **所有权 / 错误 / 调用**：this/args 借用，返回值归被调函数（GC）。`nativeCall` 返回 `null` → 裸 `error.TypeError`；之后 `callableRealm` 解析 realm（断言与 `host_call.ctx` 一致），实体工作全在 `call_runtime.functionApplyCall`，其错误（array-like 展开、被调用方抛出）多半已带 pending exception。这是 env 路径的 shim，热路径走 `functionApplyDirect`。没有直接调用方：由 `functionApplyEntry()` 注册（`src/exec/function_ops.zig:221`）。


### `functionCallRecord` (`src/exec/function_ops.zig:346`)

- **签名**：`fn functionCallRecord( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Function.prototype.call` 的专用记录 handler，与 apply 同形；两条记录都带 `forwards_call = true`，让调用侧知道这一层只是把调用转发出去。
- **实现**：与 `functionApplyRecord` 同形，终点是 `call_runtime.functionCallCall`；热路径同样由 `functionCallDirect` 承担。
- **所有权 / 错误 / 调用**：与 `functionApplyRecord` 同形：this/args 借用，`nativeCall` 失败是裸 `error.TypeError`，realm 解析后转 `call_runtime.functionCallCall`，被调用方抛出的异常已挂在 `ctx` 上。env 路径 shim，热路径是 `functionCallDirect`。没有直接调用方：由 `functionCallEntry()` 注册（`src/exec/function_ops.zig:197`）。


### `constructFunctionFromSource` (`src/exec/function_ops.zig:366`)

- **签名**：`pub fn constructFunctionFromSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new Function(...)`：转调通用动态函数构造。
- **实现**：`constructDynamicFunctionFromSource(..., new_target = constructor, kind = .normal, ...)`。
- **所有权 / 错误 / 调用**：纯转发：把两个 constructor 位置都填成同一个 `constructor` 并以 `.normal` 调 `constructDynamicFunctionFromSource`，自身不分配、不建根；返回的新函数对象归 GC。错误全部由被转发方产生——源码解析失败在 `throwParseSyntaxError` 里就挂了 pending exception 并返回 `error.SyntaxError` 哨兵。2 处调用：`src/exec/call_runtime.zig:1140`、`:2269`（按构造器名字命中 `"Function"`）。

### `constructGeneratorFunctionFromSource` (`src/exec/function_ops.zig:378`)

- **签名**：`pub fn constructGeneratorFunctionFromSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new GeneratorFunction(...)`。
- **实现**：同上，`kind = .generator`（async 两种 kind 由别处传入）。
- **所有权 / 错误 / 调用**：与上一条同形，只是 kind 传 `.generator`；不分配、不建根，错误全来自 `constructDynamicFunctionFromSource`。2 处调用：`src/exec/call_runtime.zig:1142`、`:2271`（构造器名字命中 `"GeneratorFunction"`）。

### `constructDynamicFunctionFromSource` (`src/exec/function_ops.zig:397`)

- **签名**：`pub fn constructDynamicFunctionFromSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, new_target: core.JSValue, args: []const core.JSValue, kind: DynamicFunctionKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：动态函数构造的本体：把实参拼成源码、编译、在嵌套 VM 里求值出函数对象。
- **实现**：末位实参是函数体，其余是形参：都经 `toStringForAnnexB` + `appendSourceStringUtf8`（形参用 `,` 连接）。编译 realm 取自 `functionRealmContext(constructor)`。源码 = 按 kind 选前缀（`"(function anonymous("` / `"(async function anonymous("` / `"(function* anonymous("` / `"(async function* anonymous("`）+ 形参 + `"\n) {\n"` + 函数体 + `"\n})"`；filename 同样按 kind 取 `Function` / `AsyncFunction` / `GeneratorFunction` / `AsyncGeneratorFunction`。`parser.compile(.{ .mode = .eval_direct, .strict = false })`；有 `syntax_error` 就走 `throwParseSyntaxError`（编译错误的 fileName/lineNumber/columnNumber + 首行栈，对照 quickjs.c:7553-7570）。拿到根字节码后建根函数对象并 `rootValues` 钉住，在独立的 `stack_mod.Stack` 上 `runWithCallEnv`（`is_eval_code = true`）。**嵌套 eval 退出时不跑全堆 cycle GC**：外层帧持有本轮看不见的根（例如在途异常），qjs 也从不在 eval 退出时 GC。返回后把 `nested_stack` 里那份同值的残留槽清成 undefined 再 `setLen(0)`，避免 deinit 时二次释放已被别处别名的值。最后按 `new_target` 解析出 prototype 并 `setPrototype`。
- **所有权 / 错误 / 调用**：三个 `std.ArrayList(u8)`（params / body / source）都用 `ctx.runtime.memory.allocator` 并 `defer deinit`；`parser.compile` 的产物用 `defer compiled.deinit()`，根字节码经 `takeFunctionBytecodeValue` 转交给新建的根函数对象；该对象用 `core.runtime.rootValues` 建根并 `defer deactivate`，嵌套 `stack_mod.Stack` 同样 `defer deinit`，返回前还要把栈里那份别名副本清成 undefined 并 `setLen(0)`，否则 deinit 会重复释放。`dynamicFunctionNewTargetPrototype` 拿到的 prototype 句柄 `defer prototype.deinit`。错误面：编译失败走 `throwParseSyntaxError`（已挂 pending exception，返回 `error.SyntaxError` 哨兵）；拿不到编译单元/根字节码是裸 `error.InvalidBytecode`；`functionRealmContext` 无 global 是 `error.InvalidBuiltinRegistry`；参数 ToString 与嵌套 `runWithCallEnv` 的错误原样透传。8 处调用：本文件 `:424`、`:436`，`src/exec/promise_ops.zig:2578`、`:2590`（async / async generator），以及 `src/exec/function_ops.zig:80`-`:83` 四条按构造器名字的分派。



## `src/exec/builtin_glue.zig` — performance.now

Web 兼容命名空间；QuickJS 没有。`now` = 单调时钟毫秒 − `runtime.performance_time_origin_ms`。描述符由 core `materializePerformanceAutoInit` 惰性盖 id。


### `performanceNowCall` (`src/exec/builtin_glue.zig:25`)

- **签名**：`fn performanceNowCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`performance.now()` 的实现体：返回自本 runtime 的 time origin 起经过的毫秒数（带小数）。这个命名空间 QuickJS 没有，zjs 仍让它走同一套 cproto/magic/函数指针边界。
- **实现**：`nativeCall` 恢复环境（失败 TypeError）；`host_call.magic != now_id` 也是 TypeError；返回 `float64(performanceNowMs() - ctx.runtime.performance_time_origin_ms)`。
- **所有权 / 错误 / 调用**：不分配：返回 float64 立即数（当前时钟减去 `runtime.performance_time_origin_ms`），this/args 借用且不被读取。两处失败都是**裸** `error.TypeError`（`nativeCall` 认不出调用形态、magic 不是 `now_id`），没有 pending exception，由 native seam 的 `materializeRuntimeError` 渲染。没有直接调用方：经 `internal_entries` 的 `genericMagicFunction(&performanceNowCall)`（`src/exec/builtin_glue.zig:21`）分发。

### `performanceNowMs` (`src/exec/builtin_glue.zig:36`)

- **签名**：`fn performanceNowMs() f64`。
- **作用**：单调时钟的当前毫秒数（未减 time origin）。
- **实现**：`std.Io.Threaded.global_single_threaded.io()` 上取 `Clock.Timestamp.now(.awake)` 的纳秒数，除以 `std.time.ns_per_ms`。
- **所有权 / 错误 / 调用**：无：读一次单线程全局 `std.Io` 时钟并换算成毫秒，不分配、无 error set、不碰 JS 堆。文件私有，唯一调用方 `performanceNowCall`（`src/exec/builtin_glue.zig:33`）。


## `src/exec/call.zig` — CLI print / console.log

对照 `JS_PrintValue`（quickjs.c:13678-14432）字节级输出：深度 2、字符串 1000、每容器 100 项。顶层字符串由调用方原样写出；其余走 `printValueRec`。分配只有 BigInt 十进制文本，以及 Error 接收者经 `error_stack_ops.errorStackGetter` 物化的 `stack` 字符串（宿主装了 `Error.prepareStackTrace` 时还会重入 JS）。


### `State.puts` (`src/exec/call.zig:44`)

- **签名**：`fn puts(self: *State, text: []const u8) Error!void`。
- **作用**：往输出 writer 写一段字节。
- **实现**：`self.writer.writeAll(text)`。
- **所有权 / 错误 / 调用**：无所有权：把借用切片写进 `State.writer`，不分配。本文件 `Error` = `std.Io.Writer.Error || error{OutOfMemory}`，不是 `RuntimeError`：这里既不挂 pending exception 也不经 `materializeRuntimeError`，错误一路退到唯一外部出口 `src/exec/call.zig:2157`，那里 `error.WriteFailed` 交给 `exception_ops.throwHostError` 变成 JS 异常，`error.OutOfMemory` 原样上浮。 本文件内 45 处调用。

### `State.putc` (`src/exec/call.zig:48`)

- **签名**：`fn putc(self: *State, byte: u8) Error!void`。
- **作用**：往输出 writer 写一个字节。
- **实现**：`self.writer.writeByte(byte)`。
- **所有权 / 错误 / 调用**：无所有权：单字节写入，不分配；error set 同族（`Writer.Error || OutOfMemory`，不挂 pending exception）。本文件内 22 处调用。

### `State.printf` (`src/exec/call.zig:52`)

- **签名**：`fn printf(self: *State, comptime fmt: []const u8, args: anytype) Error!void`。
- **作用**：按格式串写一段文本。
- **实现**：`self.writer.print(fmt, args)`。
- **所有权 / 错误 / 调用**：无所有权：`std.Io.Writer.print` 的格式化直写，不经中间缓冲、不分配；error set 同族。本文件内 15 处调用，典型 `:186`（`... N more characters`）、`:300`（`... N more items`）、`:496`。


### `State.putUnicodeEscape` (`src/exec/call.zig:56`)

- **签名**：`fn putUnicodeEscape(self: *State, value: u64) Error!void`。
- **作用**：写一个 `\uXXXX` 转义。
- **实现**：先写 `\u`，再用 `gc_audit_print.hexPad(value, 4, &hex_buf)` 补足四位十六进制（栈上 16 字节缓冲）。
- **所有权 / 错误 / 调用**：`[16]u8` 是栈上十六进制缓冲，由 `gc_audit_print.hexPad` 就地填充，不分配也不逃逸；error set 同族。4 处调用，全在 `printUnits` 的控制字符/孤代理臂（`:141`、`:146`、`:151`、`:157`）。

### `makeState` (`src/exec/call.zig:63`)

- **签名**：`fn makeState(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer) State`。
- **作用**：组装一次打印用的 `State`（runtime/ctx/global/output/writer，level 从 0 起）。
- **实现**：结构体字面量；`print_stack` 保持 undefined，由 `printValueRec` 按 level 填。
- **所有权 / 错误 / 调用**：无：按值构造 `State`，四个字段（`rt`/`ctx`/`global`/`writer`）全是**借用**指针，`print_stack` 故意留 `undefined`（只在 `level` 以下有效），不分配、无 error set。文件私有，调用方 `printValue`（`:67`）与 `printHostArgument`（`:74`）。

### `printHostArgument` (`src/exec/call.zig:69`)

- **签名**：`pub fn printHostArgument(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer, value: core.JSValue) Error!void`。
- **作用**：一个 `print` / `console.log` 实参（`js_print`，quickjs-libc.c:4063）。
- **实现**：顶层字符串走 `printRawString` 原样输出（不加引号、不转义），其余值走 `printValueRec`。
- **所有权 / 错误 / 调用**：`value` 借用，不产生 JS 值。顶层字符串走 `printRawString`（不加引号），其余进递归 dump。本文件 `Error` = `std.Io.Writer.Error || error{OutOfMemory}`，不是 `RuntimeError`：这里既不挂 pending exception 也不经 `materializeRuntimeError`，错误一路退到唯一外部出口 `src/exec/call.zig:2157`，那里 `error.WriteFailed` 交给 `exception_ops.throwHostError` 变成 JS 异常，`error.OutOfMemory` 原样上浮。 唯一调用方 `src/exec/call.zig:2157`（`hostOutputValues`，即 `print`/`console.log` 的逐参数循环）。

### `printFloat64` (`src/exec/call.zig:77`)

- **签名**：`fn printFloat64(s: *State, d: f64) Error!void`。
- **作用**：按 qjs `js_print_float64`（quickjs.c:13713）打印 double。
- **实现**：NaN / Infinity / -Infinity 直接写字面量；0 按符号写 `"-0"` 或 `"0"`（`JS_DTOA_MINUS_ZERO`，与 Number::toString 的唯一差别）；其余 `formatFiniteNumberAssumeCapacity` 到栈上 64 字节缓冲。
- **所有权 / 错误 / 调用**：`[64]u8` 栈缓冲交给 `formatFiniteNumberAssumeCapacity` 就地写，不分配；error set 同族（只有写失败）。4 处调用：`printValueRec`（`:650`）与 typed array 的 float16/32/64 臂（`:522`-`:524`）。

### `Units.len` (`src/exec/call.zig:92`)

- **签名**：`fn len(self: Units) usize`。
- **作用**：code-unit 视图的长度。
- **实现**：latin1 取 `bytes.len`，utf16 取 `units.len`。
- **所有权 / 错误 / 调用**：无：读 union 里**借用**切片的长度，不分配、无 error set；切片的生命周期由持有它的 `*core.string.String` 决定（String 恒为扁平表示）。调用方 `printUnits` 的循环上界与各 `printString`/`printRegExp` 站点。

### `Units.at` (`src/exec/call.zig:99`)

- **签名**：`fn at(self: Units, index: usize) u16`。
- **作用**：取第 index 个 UTF-16 code unit。
- **实现**：latin1 字节零扩展成 u16，utf16 直接取。
- **所有权 / 错误 / 调用**：无：按下标读一个 code unit（latin1 零扩展成 u16），不分配、无 error set、不做边界检查——越界是调用方的契约违约。调用方 `printUnits`（`:115` 起）与 `printError` 的 stack 逐单元循环。

### `printUnits` (`src/exec/call.zig:109`)

- **签名**：`fn printUnits(s: *State, units: Units, len: usize, sep: u16) Error!void`。
- **作用**：按 `js_print_string1`（quickjs.c:13736-13791）转义输出前 `len` 个 code unit。
- **实现**：`\t \r \n \b \f \\` 走反斜杠转义；等于 `sep`（引号）也转义；0x20-0x7e 原样；<0x20 与 0x7f-0x9f 用 `\uXXXX`；高代理后面跟合法低代理才合成码点并输出 UTF-8，落单的高/低代理都打成 `\uXXXX`。
- **所有权 / 错误 / 调用**：`units` 是**借用**的字符串数据（调用方负责保证已 flatten 且在本次调用内不被回收）；转义只写 writer，唯一缓冲是 `[4]u8` 栈上 UTF-8 编码区。error set 同族。3 处调用：`printString`（`:182`）与 `printNameBytes` 的两条臂（`:241`、`:245`）。

### `unitsOfString` (`src/exec/call.zig:162`)

- **签名**：`fn unitsOfString(body: *const core.string.String) Units`。
- **作用**：把已 flatten 的 String 体转成 `Units` 视图。
- **实现**：按 `resolveData()` 取 latin1 字节或 utf16 单元。
- **所有权 / 错误 / 调用**：无：把已 flatten 的 `*const core.string.String` 的 `resolveData()` 包成 `Units`，返回的是指向字符串体内部的**借用**切片，不 retain、不得逃出调用方帧；不分配、无 error set。3 处调用：`printString`（`:178`）、`printRegExp`（`:338`）、`printError`（`:431`）。

### `printString` (`src/exec/call.zig:171`)

- **签名**：`fn printString(s: *State, value: core.JSValue) Error!void`。
- **作用**：带引号、带转义、带截断的字符串输出（`js_print_string`，quickjs.c:13812-13829）。
- **实现**：取不到 String 体写 `<invalid string tag>`。只打印前 1000 个 code unit（`default_max_string_length`），超出时补 `... N more character(s)`（N>1 才加 s）。
- **所有权 / 错误 / 调用**：不分配（String 恒扁平，`unitsOfString` 只借用它的 `resolveData()` 切片），只写 writer。非字符串 tag 打印 `<invalid string tag>` 而不报错。文件私有，唯一调用方 `printValueRec`（`:664`）。

### `printRawString` (`src/exec/call.zig:186`)

- **签名**：`fn printRawString(s: *State, value: core.JSValue) Error!void`。
- **作用**：字符串原文输出，不加引号不转义（`js_print_raw_string`，quickjs.c:13831）。
- **实现**：取不到 String 体直接返回。latin1：<0x80 原样，否则手写两字节 UTF-8；utf16：用 `Utf16LeIterator` 逐码点编码成 UTF-8（编码失败的码点跳过）。
- **所有权 / 错误 / 调用**：不分配，只按 `resolveData()` 的两臂写 writer；latin1 的 0x80-0xFF 按码点重新编成两字节 UTF-8 而不是裸字节，UTF-16 用 `Utf16LeIterator` 并对非法序列 `catch continue` 静默跳过。非字符串值直接 `return`。5 处调用：`printHostArgument`（`:75`）、`printError` 的 name/message（`:408`、`:416`）、`[Function name]`（`:537`）、Date 的 ISO 文本（`:629`）。

### `isAsciiIdent` (`src/exec/call.zig:210`)

- **签名**：`fn isAsciiIdent(bytes: []const u8) bool`。
- **作用**：谓词：这个名字能不能当裸键打印（`is_ascii_ident`，quickjs.c:13843）。
- **实现**：空串 false；每个字符必须是字母、`_`、`$`，数字只允许出现在首位之后。
- **所有权 / 错误 / 调用**：无：对借用字节切片做纯谓词判断，不分配、无 error set。文件私有，唯一调用方 `printNameBytes`（`:237`）。

### `printAtom` (`src/exec/call.zig:223`)

- **签名**：`fn printAtom(s: *State, atom_id: core.Atom) Error!void`。
- **作用**：打印属性键 / Symbol 描述（`js_print_atom`，quickjs.c:13857-13877）。
- **实现**：tagged int atom 直接打十进制；`null_atom` 打 `<null>`；否则把 atom 的 UTF-8 名字交给 `printNameBytes`。
- **所有权 / 错误 / 调用**：不分配：`s.rt.atoms.name(atom_id)` 返回 atom 表里的**借用** UTF-8 切片（未知 atom 折成空串），tagged int 与 null atom 各有直写分支。error set 同族。3 处调用：`printClassName`（`:258`）、`printValueRec` 的 Symbol 描述（`:667`）、`printObject` 的属性键（`:591`）。


### `printNameBytes` (`src/exec/call.zig:230`)

- **签名**：`fn printNameBytes(s: *State, bytes: []const u8) Error!void`。
- **作用**：名字的「裸键或带引号」输出。
- **实现**：`isAsciiIdent` 通过就原样写。否则加引号：先试着把 UTF-8 转成 UTF-16 进栈上 256 单元缓冲再 `printUnits`（这样转义看到的和 qjs 一样）；名字过长或非法 UTF-8 时退回按字节（latin1 视图）转义。
- **所有权 / 错误 / 调用**：`[256]u16` 是栈上转码缓冲：名字能装下就按 UTF-16 单元走转义，装不下或非法 UTF-8 时退化成按字节（latin1 视图）转义——两条臂都不分配。error set 同族。文件私有，调用方 `printAtom`（`:232`）与 `printClassName` 的 fallback（`:282`）。

### `printClassName` (`src/exec/call.zig:249`)

- **签名**：`fn printClassName(s: *State, class_id: core.class.ClassId) Error!void`。
- **作用**：打印对象的 class 名。
- **实现**：Proxy 之外先查 `rt.classes.className(class_id)`（非 null atom 就走 `printAtom`）。查不到时用内置回退表：Proxy / global / module namespace 都叫 `Object`（qjs 把 Proxy 注册在 `JS_CLASS_PROXY` 下也显示 Object），Promise 家族、async 家族、WeakRef、FinalizationRegistry、DOMException、CallSite、RawJSON、FILE、DisposableStack 等各自的名字；`async_from_sync_iterator` 是空串；表外的 class 打 `<null>`。
- **所有权 / 错误 / 调用**：不分配：先取 `rt.classes.className(class_id)` 的 atom（借用），没有名字再落到本函数写死的 fallback 字面量表。error set 同族。4 处调用：typed array 头（`:502`）、`[Function]`/一般对象头（`:546`、`:571`）、超深度时的 `[ClassName]`（`:682`）。

### `printComma` (`src/exec/call.zig:282`)

- **签名**：`fn printComma(s: *State, comma_state: *u8) Error!void`。
- **作用**：容器元素之间的分隔状态机（`js_print_comma`，quickjs.c:13903）。
- **实现**：`comma_state` 0（首项）什么都不写；1 写 `", "`；其余（2，即 `[Function f]` / 正则 / Error 这类「头」）写 `" { "`——所以只有后面真的还有属性时才会开花括号。写完一律把状态置 1。
- **所有权 / 错误 / 调用**：无所有权：只按 `comma_state` 写分隔符并把状态推进到 1，不分配；`comma_state` 由调用方在栈上持有。error set 同族。6 处调用：`printMoreItems`（`:299`）与 `printObject` 的数组/空洞/typed array/Map-Set/属性各臂（`:489`、`:495`、`:512`、`:551`、`:590`）。


### `printMoreItems` (`src/exec/call.zig:292`)

- **签名**：`fn printMoreItems(s: *State, comma_state: *u8, n: usize) Error!void`。
- **作用**：容器截断尾巴 `... N more item(s)`（`js_print_more_items`，quickjs.c:13918）。
- **实现**：先 `printComma` 补分隔，再按 N 是否 >1 决定复数。
- **所有权 / 错误 / 调用**：无所有权：转调 `printComma` 后写 `... N more item(s)`，不分配。error set 同族。4 处调用，对应四种被截断的容器（`:492` 数组、`:530` typed array、`:560` Map/Set、`:614` 属性列表）。

### `ownOrProtoDataString` (`src/exec/call.zig:299`)

- **签名**：`fn ownOrProtoDataString(object: *const core.Object, atom_id: core.Atom) ?core.JSValue`。
- **作用**：取一个字符串型数据属性：own 的，或往上**一层**原型的（Error 的 `name` 就靠这条）。
- **实现**：`findProperty` 命中后，auto_init 槽用 `getProperty` 物化（zjs 把内建原型的 `name`、函数的 `prototype` 存成惰性槽，qjs 那边是普通值），否则 `asDataAt`；不是字符串返回 null。最多走一跳原型（`hops == 1` 之后返回 null）。对照 `get_prop_string`（quickjs.c:7504）。
- **所有权 / 错误 / 调用**：返回的是**借用**的属性值（不 dup）；auto_init 物化失败时当作没找到返回 null。

### `printRegExp` (`src/exec/call.zig:326`)

- **签名**：`fn printRegExp(s: *State, object: *const core.Object) Error!void`。
- **作用**：打印正则字面量形态（`js_print_regexp`，quickjs.c:13926-13990）。
- **实现**：没有编译字节码或没有 source 就写 `[uninitialized_regexp]`。空 pattern 打 `(?:)`。扫描时跟踪字符类状态 `bra`：`\` 连带下一个单元一起原样输出；`[` 开类（紧跟 `]` 的话连着输出）、`]` 关类；换行/回车转成 `\n` / `\r`；类外的 `/` 转成 `\/`。收尾按 lre 位序输出 flag 字母 `g i m s u y d v`——第 8 位其实是 named-groups 位却打成 `v`，这与 qjs 的输出一致。
- **所有权 / 错误 / 调用**：`object` 与 `regexpSource()` 都是借用，不分配。未编译/无源码的 RegExp 打印 `[uninitialized_regexp]` 而不报错。flag 位取自 `regexp_adapter.flagBitsFromBytecode`，不分配。文件私有，唯一调用方 `printObject` 的 regexp 臂（`:562`）。

### `putUnitRaw` (`src/exec/call.zig:390`)

- **签名**：`fn putUnitRaw(s: *State, c: u32) Error!void`。
- **作用**：把一个 code unit 原样写出。
- **实现**：<0x80 直接写字节；否则编码成 UTF-8（qjs 只写低字节，这里避免写出孤立字节），编码失败就丢弃。
- **所有权 / 错误 / 调用**：`[4]u8` 栈上编码缓冲；非法码点被 `catch return` 静默丢弃（而不是报错）。不分配，error set 同族。4 处调用：`printRegExp`（`:383`、`:384`）与 `printError` 的 stack 输出（`:441`、`:444`）。

### `printError` (`src/exec/call.zig:399`)

- **签名**：`fn printError(s: *State, object: *const core.Object) Error!void`。
- **作用**：打印 Error 对象：`Name: message` + 换行 + stack（`js_print_error`，quickjs.c:13992-14026）。
- **实现**：`name` 取不到就写 `"Error"`；`message` 非空才写 `": "` + 原文。stack 先找 own/原型上的数据属性，没有就通过原生 getter `errorStackGetter` 读（zjs 把 `stack` 放成 `Error.prototype` 上的访问器，V8 形状；读失败当作没有），拿到字符串才换行输出，并丢掉末尾那个 `\n`，输出时自己做代理对合并。
- **所有权 / 错误 / 调用**：`Error` = `std.Io.Writer.Error || error{OutOfMemory}`：只往 writer 写，不建 JS 值、不挂 pending exception。 读 stack 会经过原生 getter，可能触发一次惰性格式化。

### `isTypedArrayClass` (`src/exec/call.zig:442`)

- **签名**：`fn isTypedArrayClass(class_id: core.class.ClassId) bool`。
- **作用**：谓词：class 是否属于 typed array 家族。
- **实现**：class id 落在 `uint8c_array` 到 `float64_array` 的连续区间内。
- **所有权 / 错误 / 调用**：无：class id 区间比较的纯谓词，不分配、无 error set（依赖 typed array class id 在表中连续这一不变量）。文件私有，唯一调用方 `printObject`（`:499`）。

### `isCallableClass` (`src/exec/call.zig:448`)

- **签名**：`fn isCallableClass(class_id: core.class.ClassId) bool`。
- **作用**：谓词：qjs 会给这个 class 注册 call handler 吗（quickjs.c:14106 的 `class_array[class_id].call != NULL && class_id != JS_CLASS_PROXY`）。
- **实现**：白名单 switch：`c_function`、`bytecode_function`、`bound_function`、`c_function_data`、`c_closure`、generator/async/async-generator function、Promise resolve/reject 与 async function resolve/reject，其余 false。
- **所有权 / 错误 / 调用**：无：class id 白名单查表，不分配、无 error set；对应 qjs 的 `class_array[class_id].call != NULL && class_id != JS_CLASS_PROXY`。文件私有，唯一调用方 `printObject`（`:531`）。

### `printObject` (`src/exec/call.zig:468`)

- **签名**：`fn printObject(s: *State, object: *const core.Object) Error!void`。
- **作用**：对象体的打印（`js_print_object`，quickjs.c:14028-14267）。
- **实现**：按 class 选头：Array 打 `[ `，只在 `fast_array` 时遍历稠密元素（最多 100 项，再补 `... N more items`，末尾空洞打 `<N empty item(s)>`）；typed array 打 `ClassName(len) [ ` 后按元素宽度直接读 backing store；可调用 class 打 `[Function name]`（名字为空或取不到打 `(anonymous)`）并置 `comma_state = 2`；Map/Set 打 `ClassName(active_count) { `（Map 的值用 ` => ` 连）；RegExp / Date（ISO 文本成功时）/ Error 各自的头也置 2；其余非 `object` class 先打类名再 `{ `。随后按 shape 顺序遍历属性，跳过 deleted 与非 enumerable（String 包装的整数下标属性也跳过，保持 `String {  }`），前 100 条打 `key: value`：访问器按有无 getter/setter 打 `[Getter/Setter]` / `[Setter]` / `[Getter]`，var_ref 打单元里的值，auto_init 打 `[autoinit]`，data 递归。收尾：数组类写 ` ]`，其余在 `comma_state != 2` 时写 ` }`。
- **所有权 / 错误 / 调用**：`object` 是**借用**的 `*const core.Object`，整个 dump 期间不建根——安全性靠调用方持有该值、且各臂只读现成数据（`arrayElements`、`typedArrayPayloadFast`、`collectionPayloadBorrowed` 都是借用视图，不复制）。会分配的只有 Error 臂里的 `errorStackGetter`（它可能新建 stack 字符串、甚至经 `Error.prepareStackTrace` 重入 JS；`printError` 用 `catch break :blk null` 把那条路径上的一切错误吞掉）。error set 同族。文件私有，唯一调用方 `printValueRec`（`:679`）。

### `dateIsoText` (`src/exec/call.zig:618`)

- **签名**：`fn dateIsoText(s: *State, object: *const core.Object) bool`。
- **作用**：Date 的 ISO 文本打印（qjs 的 `get_date_string(..., 0x23)` 臂，quickjs.c:14153），写不出就返回 false。
- **实现**：`date_ops.isoStringForInspector` 出错或返回 null（如 NaN 时间值）→ false，让调用方退回通用 `Date {  }` 转储；写出来了返回 true（连写失败也返回 true，表示头已处理）。
- **所有权 / 错误 / 调用**：内部 `catch` 吞掉错误并用返回值表达成败；写失败时也返回 true。

### `printStackIndex` (`src/exec/call.zig:625`)

- **签名**：`fn printStackIndex(s: *State, object: *const core.Object) ?usize`。
- **作用**：当前打印栈上是否已经有这个对象（用来打 `[circular N]`）。
- **实现**：线性扫 `print_stack[0..level]` 比指针，命中返回下标。
- **所有权 / 错误 / 调用**：无：在 `s.print_stack[0..s.level]` 里按**指针**线性找当前对象做循环检测，不分配、无 error set；栈里存的是借用指针，靠 `printValueRec` 的 `level += 1` / `defer level -= 1` 维持有效窗口。文件私有，唯一调用方 `printValueRec`（`:673`）。

### `printValueRec` (`src/exec/call.zig:633`)

- **签名**：`fn printValueRec(s: *State, value: core.JSValue) Error!void`。
- **作用**：一个值的递归打印分发（`js_print_value`，quickjs.c:14278-14399）。
- **实现**：按 tag 依次：int32、bool、null、undefined、uninitialized、float64、short BigInt（`formatInt64` + `n`）、堆 BigInt（clone + `formatBase10Alloc`，**本文件唯一的分配**，用完即释放）、字符串（`printString`）、Symbol（`Symbol(desc)`）。对象：先查打印栈，命中打 `[circular N]`；`level < 2`（`default_max_depth`）就把自己压栈、level+1 后 `printObject`；超深则只打 `[ClassName]`。都不是则 `[unknown tag]`。
- **所有权 / 错误 / 调用**：`Error` = `std.Io.Writer.Error || error{OutOfMemory}`：只往 writer 写，不建 JS 值、不挂 pending exception。 堆 BigInt 的临时值与十进制文本在本函数内释放。


## `src/exec/exception_ops.zig` — 零函数 re-export

本文件没有函数。它把 core 的引擎错误面再导出成历史名 `exec.exceptions`：

- `RuntimeError` = `core.errors.RuntimeError`：引擎控制/语义错误集（OOM、Interrupted、TypeError、URIError、JSException 等）。
- `HostError` = `core.errors.HostError`，而后者就是 `RuntimeError` 本身（`pub const HostError = RuntimeError;`）：同一个 error set，只是在 native/host 边界上换个名字表达意图。

权威定义在 `src/core/errors.zig`；exec 各 `*_ops.zig` 用这里的别名，避免 core 依赖 exec。



## `src/exec/exception_ops.zig` — 命名 Error 构造与 throw 助手

引擎抛错的中心：`createNamedError` 在构造时抓栈（对照 `JS_ThrowError2` 内 `build_backtrace`）。OOM 投递 **必须** 用 realm 预分配的 `InternalError: out of memory`，catch 里看到的值身份稳定且零分配。`throwInterrupted` 把 InternalError 标成 uncatchable。


### `createNamedError` (`src/exec/exception_ops.zig:31`)

- **签名**：`pub fn createNamedError(ctx: *core.JSContext, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue`。
- **作用**：按 global 上的构造器造命名 Error，并在构造时抓当前 VM 栈（引擎抛错的单一入口）。
- **实现**：`createNamedErrorWithoutStack` 再 `attachStackToErrorValue`。对照 `JS_ThrowError2` 内 `build_backtrace`。
- **所有权 / 错误 / 调用**：返回**新建**的 Error 对象（GC 管理），并在返回前由 `attachStackToErrorValue` 把当前 backtrace 的 CallSite 数组存进它的 payload（带 generational barrier）。它只构造、**不**把值放进异常槽——挂 pending exception 是 `throw*Message` 系列的事。错误是构造与栈捕获的透传（主要是 OOM），此时还没有 pending exception。全树 39 处调用，典型 `src/exec/exception_ops.zig:344`（`throwTypeErrorMessage`）、`src/exec/builtin_dispatch.zig:58`、`src/exec/uri_ops.zig:39`。

### `createSentinelError` (`src/exec/exception_ops.zig:71`)

- **签名**：`pub fn createSentinelError( ctx: *core.JSContext, global: *core.Object, err: anyerror, info: ErrorInfo, ) !core.JSValue`。
- **作用**：把已分类的引擎 sentinel 变成 JS Error；OOM 必须投递预分配对象，不新建。
- **实现**：`error.OutOfMemory` 返回 `ctx.preallocated_oom_error`（若有）；否则 `createNamedError`。刻意不抓 OOM 栈。
- **所有权 / 错误 / 调用**：OOM 臂返回的是 realm 引导期就建好的 `ctx.preallocated_oom_error`（**零分配、无 `.stack`**，身份稳定，`src/tests/oom_cap.zig` / `src/tests/oom.zig` 钉住这条契约），其余走 `createNamedError` 新建带 CallSite 的 Error（归 GC）。本身不挂 pending exception，错误只有构造透传。7 处调用：`src/exec/call_runtime.zig:179`、`:326`，`src/exec/builtin_dispatch.zig:467`（`materializeRuntimeError`），`src/exec/module.zig:807`、`src/exec/disposable_ops.zig:269`，以及本文件 `promiseErrorValue`（`:305`）与 `rejectedPromiseForRuntimeError`（`:336`）。

### `createNamedErrorWithPrototype` (`src/exec/exception_ops.zig:86`)

- **签名**：`pub fn createNamedErrorWithPrototype(ctx: *core.JSContext, global: *core.Object, prototype: *core.Object, name: []const u8, message: []const u8) !core.JSValue`。
- **作用**：直接在 realm 自有的 native-error 原型上造 Error（qjs 的 `ctx->native_error_proto[]` 路径）。
- **实现**：先 `rootValues` 钉住原型值跨越后面的分配。`expectObject` 失败 → `error.InvalidBuiltinRegistry`；以该原型 `core.Object.create(class error_)`，定义 own `message`（writable+configurable、非 enumerable），再 `attachStackToErrorValue` 抓栈。**`name` 参数未使用**（`_ = name;`，函数体内已加注释）：名字由原型链上的 `name` 决定——调用方正是为这个名字挑的 `prototype`，形参保留是让调用点自明在造哪种 Error；可变的全局构造器绑定不参与 realm 选择。
- **所有权 / 错误 / 调用**：`prototype` 的值先由 `core.runtime.rootValues` 建根并 `defer deactivate`，跨过后面 `Object.create` / `createStringValue` 两次分配；新 Error 与 message 字符串都归 GC（message 由属性槽持有），CallSite 数组由 `attachStackToErrorValue` 存进 payload。不挂 pending exception。原型不是对象时返回裸 `error.InvalidBuiltinRegistry`，其余是分配透传。2 处调用：`src/exec/array_ops.zig:395`（`RegExp object expected`）与本文件 `throwTdzReferenceError`（`:226`）。

### `createNamedErrorWithoutStack` (`src/exec/exception_ops.zig:117`)
 (`src/exec/exception_ops.zig:113`)

- **签名**：`pub fn createNamedErrorWithoutStack(rt: *core.JSRuntime, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue`。
- **作用**：不抓栈的命名 Error 构造，只给两处用：预分配 OOM 对象，以及嵌入方显式 `capture_stack = false` 的 `JSContext.createError`。
- **实现**：`rt.internAtom(name)` 后从 global 取同名构造器，交给 `buildNamedErrorObject`。所有用户可见的 throw 路径都必须走上面会抓栈的原语。
- **所有权 / 错误 / 调用**：只拿 `*core.JSRuntime`（没有 ctx，所以物理上也捕不到 VM 栈）：`internAtom` 把名字登记进 atom 表，`global.getProperty` 取到的构造器是**借用**值，实体构造在 `buildNamedErrorObject`。返回的 Error 归 GC 且**没有** `.stack` sites——只有预分配 OOM 对象和显式 `capture_stack = false` 的嵌入 API 允许走这里。错误是 atom 登记/属性读/构造的透传。4 处调用：`createNamedError`（`:32`）、`createPreallocatedOutOfMemoryError`（`:124`）、`error_stack_ops.throwParseSyntaxError`（`:110`）、`src/js_context.zig:475`。

### `createPreallocatedOutOfMemoryError` (`src/exec/exception_ops.zig:127`)

- **签名**：`pub fn createPreallocatedOutOfMemoryError(rt: *core.JSRuntime, global: *core.Object) !core.JSValue`。
- **作用**：建 runtime 的预分配 OOM catch 值（`InternalError: out of memory`）。
- **实现**：`createNamedErrorWithoutStack` 之后**额外**盖一个 own `name = "InternalError"`：投递路径必须零分配，不能依赖 `InternalError.prototype.name` 那个惰性字符串占位被物化。
- **所有权 / 错误 / 调用**：它**构造**的正是 runtime 那个预分配 OOM 对象，因此没有「分配失败退回预分配对象」的退路：堆真的耗尽时它只能把 OOM 原样上浮（启动期调用，那时内存还充裕）。新建的 Error 与自述的 `name` 字符串都归 GC，`name` 写成 own 属性是为了让日后的零分配投递不依赖 `InternalError.prototype.name` 这个惰性占位符。唯一调用方 `src/exec/zjs_vm.zig:140`（realm 引导时填 `ctx.preallocated_oom_error`）。

### `buildNamedErrorObject` (`src/exec/exception_ops.zig:135`)

- **签名**：`fn buildNamedErrorObject(rt: *core.JSRuntime, ctor_value: core.JSValue, name: []const u8, message: []const u8) !core.JSValue`。
- **作用**：命名 Error 的底层建造：一个 own `message` + 从构造器取来的原型。
- **实现**：`rootValues` 钉住构造器值。建 `error_` class 对象（`errdefer` 销毁），定义 own `message`（writable+configurable、非 enumerable）——对照 `JS_ThrowError2`（quickjs.c:7637-7658）：`name`/`constructor` 都从原型解析，不做 own 属性。构造器是对象就读它的 `prototype` 并 `setPrototype`。装不上原型时（例如 zjs 特有的 `InvalidCharacterError` 没有 realm 构造器）退化：盖一个自描述的 own `name`，qjs 到不了这个状态。
- **所有权 / 错误 / 调用**：显式建根：`core.runtime.rootValues(.{&rooted_ctor_value})` 在整段构造期间给构造器值挂 `ValueRootFrame`（同文件单测就是钉这条，用符号构造器验证它不被回收）；新对象另有 `errdefer core.Object.destroyFromHeader` 做失败清理。message 字符串新建后由 `defineNonEnumValueProperty` 写成 non-enumerable 属性（属性槽拥有）；原型从构造器的 `prototype` **借用**并 `setPrototype`。找不到构造器原型时降级为再写一个自述的 own `name`。错误是分配/属性读的透传。文件私有，调用方 `createNamedErrorWithoutStack`（`:116`）与单测（`:181`）。

### `throwTdzReferenceError` (`src/exec/exception_ops.zig:216`)

- **签名**：`pub fn throwTdzReferenceError(ctx: *core.JSContext) error{ReferenceError}`。
- **作用**：let/const 绑定在 TDZ 内被读写时的抛出点：造 `ReferenceError: Cannot access 'x' before initialization`（消息里的 `'x'` 是写死的字面量，不带真实标识符）并返回 `error.ReferenceError` 哨兵。
- **实现**：没有 global、拿不到 realm 的 `reference_error` intrinsic 原型、或 `createNamedErrorWithPrototype` 失败（OOM 硬化路径）这三种情况，都退化成 `throwReferenceErrorSentinel` 再返回 `error.ReferenceError`。正常路径用 realm intrinsic 原型造 `ReferenceError: Cannot access 'x' before initialization` 并 `ctx.throwValue`——用 intrinsic 而非可变的全局构造器绑定，是为了让 `instanceof ReferenceError` 成立。
- **所有权 / 错误 / 调用**：错误值转交给 pending exception 槽；返回类型固定是 `error{ReferenceError}`（VM 哨兵约定）。

### `normalizeEvalRuntimeError` (`src/exec/exception_ops.zig:247`)

- **签名**：`pub fn normalizeEvalRuntimeError(err: anytype) (@TypeOf(err) || error{TypeError})`。
- **作用**：把 eval 路径上的属性定义类错误折成 TypeError。
- **实现**：`IncompatibleDescriptor` / `NotExtensible` / `ReadOnly` → `error.TypeError`，其余原样返回；返回类型是 `@TypeOf(err) || error{TypeError}`。
- **所有权 / 错误 / 调用**：无所有权：纯 error-set 映射（`IncompatibleDescriptor`/`NotExtensible`/`ReadOnly` → `error.TypeError`，其余原样），不分配、不碰 pending exception——已挂的异常对象与被改写的 sentinel 可能因此不一致，调用方随后要么重新 materialize 要么本就没挂异常。4 处调用：`src/exec/eval_entry.zig:317`、`:368`、`src/exec/call.zig:2532`、`src/exec/call_runtime.zig:3409`。

### `runtimeErrorValueForGeneratorCatch` (`src/exec/exception_ops.zig:254`)

- **签名**：`pub fn runtimeErrorValueForGeneratorCatch(ctx: *core.JSContext, global: *core.Object, err: anytype) !core.JSValue`。
- **作用**：generator/async 的 catch 接缝：把哨兵 error 变成可交给 JS 的异常值。
- **实现**：pending exception 与该 error 匹配时直接 `takeException`。否则按哨兵造对应命名 Error：TypeError（空消息）、RangeError（空消息）、ReferenceError（`"not defined"`）、SyntaxError（`"invalid syntax"`）；不在表里的 error 先清 pending exception 再把 error 原样上抛。造好之后同样清掉可能残留的 pending exception。
- **所有权 / 错误 / 调用**：把 sentinel 变成 generator `catch` 能接住的值。已挂 pending exception 且与 err 匹配时 `ctx.takeException()`——**所有权从异常槽转移给调用方**（槽被清空）；否则对四个可识别 sentinel 用 `createNamedError` 新建 Error（GC），并在返回前 `clearException()` 清掉任何残留；不认识的 sentinel 清掉异常后原样上浮。唯一调用方 `src/exec/call_runtime.zig:4087`。

### `promiseAggregateError` (`src/exec/exception_ops.zig:277`)

- **签名**：`pub fn promiseAggregateError(ctx: *core.JSContext, global: *core.Object, errors: *core.Object) !core.JSValue`。
- **作用**：`Promise.any` 拒绝用的内建 AggregateError（对照 `js_aggregate_error_constructor`，quickjs.c:41582）。
- **实现**：从 global 取 `AggregateError` 构造器的 `prototype` 装到新建的 `error_` 对象上（取不到就保持无原型）；唯一 own 属性是 `errors`（writable+configurable、非 enumerable），**没有** own `message`/`name`。qjs 在这里不跑 `build_backtrace`，zjs 仍然 `attachStackToErrorValue` 抓一次 call site——否则惰性 `stack` 访问器会拿第一个读它的上下文去重建回溯。
- **所有权 / 错误 / 调用**：新建一个 `error_` class 对象（GC），原型从 `global` 的 `AggregateError.prototype` **借用**；唯一 own 属性 `errors` 由 `defineNonEnumValueProperty` 写入（`errors` 数组的所有权归属性槽）；随后 `attachStackToErrorValue` 存 CallSite 数组——qjs 在这里不跑 `build_backtrace`，zjs 补这一步是因为惰性 `stack` 访问器否则会在第一个读它的上下文里重建栈。不挂 pending exception。错误是分配/属性读的透传。2 处调用：`src/exec/promise_ops.zig:1806`、`:2309`。

### `promiseErrorValue` (`src/exec/exception_ops.zig:299`)

- **签名**：`pub fn promiseErrorValue(ctx: *core.JSContext, global: *core.Object, err: exceptions.HostError) exceptions.HostError!core.JSValue`。
- **作用**：把哨兵 error 转成 Promise 拒绝理由，不借用 pending exception 槽当中转。
- **实现**：`error.Interrupted` 且当前异常是 uncatchable 时直接 `takeException`（这条转移只留给 Promise，放进通用匹配器会让 generator catch 吃掉不可捕获错误）。pending exception 匹配也直接 `takeException`。否则 `promiseErrorInfo` 分类后 `createSentinelError`；构造再失败且是 OOM，就投递 `preallocated_oom_error`，连它都没有（构造期/裸 context）就返回 **null 值**当非分配的 abrupt 结果，绝不让已经开跑的 Promise job 丢失。
- **所有权 / 错误 / 调用**：三条出口的所有权各不同：`takeException()` 两臂（uncatchable 的 `Interrupted`、pending exception 与 err 匹配）把异常槽里的值**转移**给调用方并清空槽；其余走 `createSentinelError` 新建（OOM 时交出 realm 预分配对象，再没有就返回 **null 值**当非分配的 abrupt 结果，绝不让已开跑的 Promise job 丢失）。本函数自己不挂 pending exception，返回值由调用方交给 reject。19 处调用，典型 `src/exec/promise_ops.zig:1003`、`src/exec/promise_ops.zig:221`、`src/exec/disposable_ops.zig:575`。

### `rejectedPromiseForRuntimeError` (`src/exec/exception_ops.zig:327`)

- **签名**：`pub fn rejectedPromiseForRuntimeError( ctx: *core.JSContext, global: *core.Object, err: exceptions.HostError, prototype: ?*core.Object, ) exceptions.HostError!core.JSValue`。
- **作用**：把哨兵 error 直接变成一个已拒绝的 Promise。
- **实现**：pending exception 匹配时用 `runtime.current_exception` 作 reason 建 `rejectedWithPrototype`，再 `clearException`。否则 `runtimeErrorInfo` 分类（返回 null 说明不是可转换的哨兵，原样上抛 err），`createSentinelError` 造值后建拒绝 Promise，并清掉残留 pending exception。
- **所有权 / 错误 / 调用**：两条所有权路径：pending exception 匹配时直接拿 `ctx.runtime.current_exception`（借用）建 rejected promise，再 `ctx.clearException()` 清槽；否则 `createSentinelError` 新建 Error（OOM 时交出 realm 预分配的 OOM 对象，零分配）。`runtimeErrorInfo` 不认识的 err 原样上浮。返回的 promise 归 GC，函数出口保证异常槽已清空。14 处调用，典型 `src/exec/promise_ops.zig:3215`、`src/exec/vm_opcodes.zig:108`、`src/exec/disposable_ops.zig:714`。

### `throwTypeErrorMessage` (`src/exec/exception_ops.zig:348`)

- **签名**：`pub fn throwTypeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue`。
- **作用**：带自定义消息抛 `TypeError` 的通用出口——引擎里绝大多数「不是函数 / 不能转换 / 不可写」类错误的最后一跳。
- **实现**：`createNamedError(ctx, global, "TypeError", message)` 造对象（内部 `createNamedErrorWithoutStack` + `attachStackToErrorValue` 补栈），`ctx.throwValue` 存进 pending 异常槽，然后 `return error.TypeError`。返回类型写成 `!core.JSValue` 只是为了能在需要返回值的位置直接 `return try ...`，正常路径永远不会真的产出值。
- **所有权 / 错误 / 调用**：错误值的所有权随 `throwValue` 交给 pending 异常槽；`message` 只被读取（字符串内容复制进 error 对象），调用方仍可在返回后释放自己的临时缓冲。构造本身可能 `error.OutOfMemory`，此时不会有 pending 异常。

### `throwRangeErrorMessage` (`src/exec/exception_ops.zig:354`)

- **签名**：`pub fn throwRangeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue`。
- **作用**：带自定义消息抛 `RangeError`：越界下标、非法长度/精度、无效时间值等数值域错误走这里。
- **实现**：与 `throwTypeErrorMessage` 同形：`createNamedError(..., "RangeError", message)` → `ctx.throwValue` → 返回 `error.RangeError` 哨兵。
- **所有权 / 错误 / 调用**：错误值转交 pending 异常槽；`message` 借用。

### `throwInternalErrorMessage` (`src/exec/exception_ops.zig:366`)

- **签名**：`pub fn throwInternalErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue`。
- **作用**：抛 `InternalError`（qjs `JS_ThrowInternalError` 的对应物）：引擎自身的限额/内部故障用它，例如栈深度耗尽。
- **实现**：造 `InternalError(message)`、`ctx.throwValue`，返回的哨兵是 **`error.StackOverflow`**——函数头注释已写明这是有意的：四个调用方全是栈/递归限额守卫，`error.StackOverflow` 正是它们的 unwind 路径匹配的哨兵。
- **所有权 / 错误 / 调用**：`createNamedError` 建 Error（带栈），`ctx.throwValue` **把它移交异常槽**（此后槽是它的根），函数返回 `error.StackOverflow`——注意返回的哨兵与 `InternalError` 名字并不同名，调用方拿到的是**已挂 pending exception** 的错误，不需要也不应再 materialize。构造失败（OOM）则在挂异常之前就上浮。4 处调用：`src/exec/vm_opcodes.zig:67`、`:255`、`src/exec/builtin_dispatch.zig:448`、`src/exec/inline_calls.zig:1456`。

### `throwInterrupted` (`src/exec/exception_ops.zig:374`)

- **签名**：`pub fn throwInterrupted(ctx: *core.JSContext, global: *core.Object) !void`。
- **作用**：中断轮询命中时的抛出点（qjs `JS_ThrowInterrupted`）：在当前 Realm 里挂一个真的 `InternalError: interrupted`，同时把异常标成 JS `catch` 抓不住，让执行一路退出。
- **实现**：造 `InternalError("interrupted")` 并 `throwValue`，然后 `setExceptionUncatchable(true)`，返回 `error.Interrupted`。构造遇 OOM 时（非 OOM 的 error 原样上抛）：若还没有 pending exception 就塞入 `preallocated_oom_error`（没有则 null 值），同样标成 uncatchable 再返回 `error.Interrupted`——qjs 在递归 OOM 下也保持「当前异常不可捕获」这条契约。
- **所有权 / 错误 / 调用**：新建的 `InternalError: interrupted` 由 `ctx.throwValue` 移交异常槽，并被 `setExceptionUncatchable(true)` 标成 JS `catch` 抓不住；函数**总是**以 error 结束——正常路径与 OOM 退化路径都返回 `error.Interrupted`（非 OOM 的构造错误原样上抛，此时没有 pending exception）。OOM 退化时若槽是空的才塞入 `ctx.preallocated_oom_error`（零分配）
或 null 值，不覆盖已有异常。2 处调用，都在本文件：`pollInterrupt`（`:392`）与 `pollInterruptSlowLeg`（`:400`）。

### `pollInterrupt` (`src/exec/exception_ops.zig:399`)

- **签名**：`pub inline fn pollInterrupt(ctx: *core.JSContext, global: *core.Object) !void`。
- **作用**：一次语义调用/跳转的 interrupt poll：计数在 RealmContext，抛错在 exec（需要该 Realm 的 InternalError intrinsic）。
- **实现**：`ctx.pollInterrupt()` 假则返回；真则 `throwInterrupted`。
- **所有权 / 错误 / 调用**：Zig error 向上传；命中时挂 uncatchable InternalError。

### `pollInterruptSlowLeg` (`src/exec/exception_ops.zig:407`)

- **签名**：`pub noinline fn pollInterruptSlowLeg(ctx: *core.JSContext, global: *core.Object) core.errors.HostError!void`。
- **作用**：给「自己内联了 `pollInterruptTick`」的分发器用的慢半边：重置计数、GC safepoint、跑 interrupt handler，handler 要求终止时抛。
- **实现**：`ctx.pollInterruptSlowPublic()` 假则返回。真则 `throwInterrupted(ctx, global) catch |err| return @errorCast(err)`，把 `!void` 收成 `HostError`。
- **所有权 / 错误 / 调用**：不分配（异常对象由 `throwInterrupted` 造，OOM 走预分配对象）。opcode 热路径 tick 命中后落到这里，避免把 throw 编进每个 handler。

### `throwReferenceErrorMessage` (`src/exec/exception_ops.zig:412`)

- **签名**：`pub fn throwReferenceErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue`。
- **作用**：带自定义消息抛 `ReferenceError` 的底座；`throwReferenceErrorNotDefined` 与其他绑定类报错都先把消息拼好再进这里。
- **实现**：与 `throwTypeErrorMessage` 同形：`createNamedError(..., "ReferenceError", message)` → `ctx.throwValue` → 返回 `error.ReferenceError` 哨兵。
- **所有权 / 错误 / 调用**：错误值转交 pending 异常槽；`message` 借用，调用方（如 `throwReferenceErrorNotDefined`）返回后才释放自己的 `allocPrint` 缓冲。

### `throwReferenceErrorNotDefined` (`src/exec/exception_ops.zig:424`)

- **签名**：`pub fn throwReferenceErrorNotDefined(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) !core.JSValue`。
- **作用**：未解析绑定的专用出口：把 atom 还原成标识符文本，抛 `ReferenceError: 'name' is not defined`，保证 JS `catch` 看到的是带名字的消息而不是通用哨兵文本。
- **实现**：tagged int atom 打成十进制数字，否则取 atom 名（取不到用空串）；`allocPrint` 出 `'name' is not defined` 并 `defer free`，再交给 `throwReferenceErrorMessage`。每个未解析绑定的出口（get_var、严格模式 put_var、with 作用域、ref-value）都走这里，否则 JS catch 只会看到 `runtimeErrorInfo` 给的通用 `"not defined"`。对照 qjs `JS_ThrowReferenceErrorNotDefined`（quickjs.c:7820）。
- **所有权 / 错误 / 调用**：唯一持堆缓冲的 throw helper：`std.fmt.allocPrint` 拼出 `'name' is not defined`，`defer allocator.free(message)` 释放（tagged int atom 走栈上 `[16]u8`，atom 名字是借用切片）。消息串进 `throwReferenceErrorMessage` 后被复制成 GC 字符串，再由 `ctx.throwValue` 移交异常槽；返回 `error.ReferenceError` 哨兵**已带 pending exception**。9 处调用，典型 `src/exec/vm_property.zig:89`、`src/exec/vm_property.zig:82`、`src/exec/vm_property.zig:253`。

### `throwSyntaxErrorMessage` (`src/exec/exception_ops.zig:436`)

- **签名**：`pub fn throwSyntaxErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue`。
- **作用**：运行期造 `SyntaxError` 的出口，用在解析器之外的语法类拒绝上（正则编译栈溢出、`JSON.rawJSON` 的非法字符串）；解析器自己的报错走 `error_stack_ops.throwParseSyntaxError`，那条会额外铺 fileName/行列与栈。
- **实现**：与 `throwTypeErrorMessage` 同形：`createNamedError(..., "SyntaxError", message)` → `ctx.throwValue` → 返回 `error.SyntaxError` 哨兵。
- **所有权 / 错误 / 调用**：错误值转交 pending 异常槽；`message` 借用。

### `isCallSiteObject` (`src/exec/exception_ops.zig:442`)

- **签名**：`pub fn isCallSiteObject(object: *core.Object) bool`。
- **作用**：谓词：该对象是不是 CallSite（`Error.prepareStackTrace` 暴露给用户的帧对象，元数据在内部槽里）。
- **实现**：转调 `object.isCallSite()`。
- **所有权 / 错误 / 调用**：无：转调 `object.isCallSite()` 的只读谓词，不分配、无 error set。文件私有意义上只有一个调用方 `callSiteMethodById`（`src/exec/exception_ops.zig:440`）。

### `callSiteMethodById` (`src/exec/exception_ops.zig:448`)

- **签名**：`pub fn callSiteMethodById(object: *core.Object, id: core.function.HostGlobalMethod) ?core.JSValue`。
- **作用**：CallSite 原型方法按 `.host` 记录 id 取值（元数据在对象的内部槽里）。
- **实现**：receiver 不是 CallSite 直接返回 null。`getFunction` 恒为 null 值；`getFunctionName` / `getFileName` 取不到槽也返回 null 值；`getLineNumber` / `getColumnNumber` 对 native 帧返回 null 值，否则 int32；`isNative` 返回布尔；其他 id 返回 null（表示不是 CallSite 方法）。
- **所有权 / 错误 / 调用**：返回的都是**借用**值：CallSite 内部槽里已存的字符串（`callSiteFunctionName`/`callSiteFile`）或就地构造的 int32/bool/null 立即数，不分配、无 error set；receiver 不是 CallSite、或 id 不在表内时返回 `null`。唯一调用方 `src/exec/call.zig:894`（把 `null` 转成 `error.TypeError`）。

### `backtraceFunctionNameAtom` (`src/exec/exception_ops.zig:461`)

- **签名**：`fn backtraceFunctionNameAtom(ctx: *core.JSContext, fallback: core.Atom, current_function_value: core.JSValue) !core.Atom`（文件私有）。
- **作用**：把函数对象的 own `name` 属性转成 atom，用于回溯帧命名。
- **实现**：不是对象就返回 `fallback`；没有 own `name`、或它不是字符串数据属性，都返回 `empty_string` atom；否则 `appendRawString` 成 UTF-8 后 `internString`。
- **所有权 / 错误 / 调用**：`std.ArrayList(u8)` 局部缓冲 `defer deinit`；返回的是 `internString` 登记后的 **Atom**（atom 表拥有，调用方不释放）。非对象返回传入的 `fallback`，没有 `name` 或非字符串 data 属性返回 `ids.empty_string`。错误是 `getOwnProperty` 与分配的透传。唯一调用方是本文件的 `resolveBacktraceFunctionName`（`src/exec/exception_ops.zig:467`）。


### `resolveBacktraceFunctionName` (`src/exec/exception_ops.zig:472`)

- **签名**：`pub fn resolveBacktraceFunctionName(ctx: *core.JSContext, frame: *core.BacktraceFrame) core.Atom`。
- **作用**：惰性解析回溯帧的函数名 atom 并写回 frame。
- **实现**：`frame.function_value` 是 undefined 说明已解析过，直接返回现有 `function_name`。否则先把 `function_value` 清成 undefined（一次性），`backtraceFunctionNameAtom` 解析（失败退化成 `empty_string`）后写回 `frame.function_name`。
- **所有权 / 错误 / 调用**：**原地改写调用方的 `core.BacktraceFrame`**：把 `frame.function_value` 清成 `undefined`（解除该帧对函数值的引用，这是它唯一的所有权动作）并把解析结果写回 `frame.function_name`。无 error set——`backtraceFunctionNameAtom` 的任何失败都 `catch` 成 `ids.empty_string`，因为这条路径本身就在处理异常，不能再失败。2 处调用：`src/exec/string_ops.zig:675`、`src/exec/array_ops.zig:287`。

### `resolveBacktraceLocation` (`src/exec/exception_ops.zig:481`)

- **签名**：`pub fn resolveBacktraceLocation(data: ?*const anyopaque, target_pc: usize) core.BacktraceLocation`。
- **作用**：回溯帧的行列解析回调（按 pc 查 pc2line）。
- **实现**：`data` 为空返回 1:1。函数没有 pc2line 缓冲时用 header 的 `lineNum()`/`colNum()`。**有** 缓冲则以它为准：`sourceLocationFromPc2Line` 失败返回 0:0（与 qjs `find_line_num` 一致），刻意不回退 header，免得掩盖损坏的产物。
- **所有权 / 错误 / 调用**：把 `?*const anyopaque` 还原成**借用**的 `*const bytecode.FunctionBytecode`（调用方保证它活着），只读 `pc2lineBuf`，不分配。无 error set：空指针给 1:1，畸形/缺失 pc2line 给 0:0 而不是报错（故意不回退到 header，以免掩盖损坏的产物）。生产用法不是直接调用，而是作为函数指针存进 `frameBacktraceSnapshot` 的 `.location_resolver`（`src/exec/exception_ops.zig:503`）；另有单测 `src/tests/exec.zig:9601`。

### `frameBacktraceSnapshot` (`src/exec/exception_ops.zig:497`)

- **签名**：`pub fn frameBacktraceSnapshot(frame: *const frame_mod.Frame) core.ActiveBacktraceSnapshot`。
- **作用**：把一个活的 VM 帧快照成回溯节点。
- **实现**：抄下函数名/文件名 atom、header 行列、当前函数值，并挂上 `resolveBacktraceLocation` 作解析器。关键一点：`pc` 存的是 `frame.pc -| 1`——发布的 pc 是返回/恢复地址（指向当前指令之后，同 qjs 的 `sf->cur_pc`），退一个字节才能让行列查询落在这条指令内（对照 `sf->cur_pc - b->byte_code_buf - 1`，quickjs.c:7595）。
- **所有权 / 错误 / 调用**：快照只借用 atom、函数指针与当前函数值，不获取所有权；不分配、不出错。

### `isErrorConstructorName` (`src/exec/exception_ops.zig:517`)

- **签名**：`pub fn isErrorConstructorName(name: []const u8) bool`。
- **作用**：谓词：这个名字是不是标准 Error 构造器名。
- **实现**：转调 `core.error_names.isErrorConstructorName`。
- **所有权 / 错误 / 调用**：无：转调 `core.error_names.isErrorConstructorName` 的静态名字表查询，只读借用切片，不分配、无 error set。4 处调用走这个 exec 包装：`src/exec/function_ops.zig:160`、`src/exec/call_runtime.zig:1169`、`:2358`、`src/js_context.zig:502`（`src/exec/reflect_ops.zig:389` 等另有几处直接调 `core.error_names.isErrorConstructorName`）。


### `functionNameBytes` (`src/exec/exception_ops.zig:521`)

- **签名**：`pub fn functionNameBytes(rt: *core.JSRuntime, value: core.JSValue) ![]u8`。
- **作用**：取函数对象 `name` 属性的 UTF-8 字节（`Error.captureStackTrace` 的 skip 名用）。
- **实现**：不是对象、或 `name` 不是字符串，都返回 `dupe("")`；否则 `appendRawString` 进临时缓冲后 `dupe`。
- **所有权 / 错误 / 调用**：返回的字节**由调用方 free**（`errorCaptureStackTrace` 用 `defer free`）；临时 ArrayList 在函数内释放。

### `pendingExceptionMatchesError` (`src/exec/exception_ops.zig:531`)

- **签名**：`pub fn pendingExceptionMatchesError(ctx: *core.JSContext, err: anyerror) bool`。
- **作用**：当前 pending exception 是不是这个 Zig 哨兵 error 对应的那个异常对象。
- **实现**：没有 pending exception → false；`error.JSException` 恒为 true（它本来就表示「异常已在槽里」）；否则 `errorNameForRuntimeError` 取期望名，再用 `objectDataStringPropertyMatches` 比异常对象的 `name`。
- **所有权 / 错误 / 调用**：只读：不分配、不清槽、不转移所有权，纯粹回答「当前 pending exception 是否就是这个 sentinel 的 JS 形态」。`error.JSException` 一律算匹配；其余先经 `errorNameForRuntimeError` 取期望名字，再用 `objectDataStringPropertyMatches` 做**不触发 accessor、不分配**的 `name` 比对（异常处理路径不能再分配）。无 error set。13 处调用，典型 `src/exec/builtin_dispatch.zig:465`（`materializeRuntimeError` 的短路）、`src/exec/exception_ops.zig:52`、`src/exec/call_runtime.zig:167`。

### `objectDataStringPropertyMatches` (`src/exec/exception_ops.zig:543`)

- **签名**：`fn objectDataStringPropertyMatches(object: *core.Object, atom_id: core.Atom, expected: []const u8) bool`。
- **作用**：不分配地比对象（含原型链）上某个字符串属性的值。
- **实现**：沿原型链用 `findOwnPropertySlotTrusted` 找槽，跳过 deleted：data 取槽值、var_ref 取单元值、auto_init 只认 `string_constant` 描述符并当场比名字、accessor 一律 false。找到第一个非空槽就给出结论。之所以不走 `getProperty`：异常分发已经在处理 abrupt completion，不能为了物化惰性 `name` 字符串再分配。
- **所有权 / 错误 / 调用**：只读且**刻意不分配**：沿原型链用 `findOwnPropertySlotTrusted` 走 data / var_ref / auto_init 三种事实，accessor 一律判 false（惰性构造的名字不算权威），string_constant 的 AUTOINIT 直接比它的名字而不物化。无 error set。文件私有，唯一调用方 `pendingExceptionMatchesError`（`src/exec/exception_ops.zig:527`）。

### `stringBodyEqualsAscii` (`src/exec/exception_ops.zig:563`)

- **签名**：`fn stringBodyEqualsAscii(string: *core.string.String, expected: []const u8) bool`。
- **作用**：String 体与 ASCII 字面量逐字节比较。
- **实现**：latin1 直接 `std.mem.eql`；utf16 先比长度再逐单元与字节比较。
- **所有权 / 错误 / 调用**：无：对**借用**的字符串体逐单元比对 ASCII 字面量（latin1 走 `mem.eql`，utf16 逐 unit），不分配、不物化 rope、无 error set。文件私有，唯一调用方 `objectDataStringPropertyMatches`（`src/exec/exception_ops.zig:549`）。

### `runtimeErrorInfo` (`src/exec/exception_ops.zig:582`)

- **签名**：`pub fn runtimeErrorInfo(err: anyerror) ?ErrorInfo`。
- **作用**：把引擎哨兵 error 映射成 (Error 名, 默认消息)；不认识的 error 返回 null。
- **实现**：URIError/InvalidUtf8 → `URIError: expecting hex digit`；OutOfMemory / StackOverflow（quickjs.c:7789-7791）/ Interrupted / StringTooLong 都是 `InternalError`；DerivedConstructorReturn → TypeError（quickjs.c:18273-18278 在调用方 context 造）、DerivedThisUninitialized → `ReferenceError: this is not initialized`（quickjs.c:18717-18728）；NotExtensible → `TypeError: object is not extensible`（quickjs.c:10144）；BigIntTooLarge / DivisionByZero / NegativeExponent 各自的 RangeError 文案（quickjs.c:11593、11888、12113）；TypeError/RangeError 是空消息；ReferenceError → `"not defined"`。这些只是**兜底**消息：知道真实原因的抛出点应该用带消息的 `throw*Message`。
- **所有权 / 错误 / 调用**：纯映射，返回的是静态字面量切片，不分配。

### `promiseErrorInfo` (`src/exec/exception_ops.zig:619`)

- **签名**：`pub fn promiseErrorInfo(err: anyerror) ErrorInfo`。
- **作用**：同 `runtimeErrorInfo`，但给 Promise 拒绝用，**一定**有结果。
- **实现**：表基本与 `runtimeErrorInfo` 相同（少了 `NotExtensible` / `InvalidCharacterError` 两条），差别在兜底：不认识的 error 返回 `{ Error, "" }` 而不是 null。
- **所有权 / 错误 / 调用**：纯映射，不分配。

### `hostIoErrorInfo` (`src/exec/exception_ops.zig:647`)

- **签名**：`pub fn hostIoErrorInfo(err: HostIoError) ErrorInfo`。
- **作用**：把宿主 I/O 错误分类成 `ErrorInfo`（Error 名 + 消息），不产生 JS 值。
- **实现**：`OutOfMemory` → `InternalError: out of memory`；其余整张 `HostIoError` 列表统一成 `{ name = "Error", message = @errorName(err) }`。
这里刻意穷举而不是收 `anyerror`：Zig 标准库改了错误集就必须编译失败，逼人重审转换策略。
- **所有权 / 错误 / 调用**：纯映射，不分配。

### `hostErrorValue` (`src/exec/exception_ops.zig:688`)

- **签名**：`pub fn hostErrorValue( ctx: *core.JSContext, global: *core.Object, err: HostIoError, ) exceptions.HostError!core.JSValue`。
- **作用**：宿主错误到 JS 值的转换。
- **实现**：`hostIoErrorInfo` 分类后 `createNamedError`（会抓栈），构造错误经 `@errorCast` 收成 `HostError`。不碰 pending exception 槽。
- **所有权 / 错误 / 调用**：返回 `createNamedError` 新建、已挂好 CallSite 的 Error（归 GC），**不**碰 pending exception 槽——它专门给「要一个拒绝理由值」的调用方用（`throwHostError` 是把同一个值再抛出去的那一层）。构造错误经 `@errorCast` 收成 `HostError` 原样上浮（主要是 OOM），此时没有 pending exception。3 处调用：本文件 `throwHostError`（`src/exec/exception_ops.zig:699`）与模块加载失败的拒绝理由 `src/exec/module.zig:1791`、`:1833`。




### `throwHostError` (`src/exec/exception_ops.zig:701`)

- **签名**：`pub fn throwHostError( ctx: *core.JSContext, global: *core.Object, err: HostIoError, ) exceptions.HostError!core.JSValue`。
- **作用**：宿主 I/O 失败（`HostIoError`）在产生点的转换器：按错误种类查出 Error 名与消息造值抛出，把宿主错误接进 JS 异常通道。
- **实现**：`error.OutOfMemory` 直接原样返回（硬控制错误，不建 JS 值）；已有 pending exception 则直接返回 `error.JSException`；否则 `hostErrorValue` 造值、`throwValue`，返回 `error.JSException`。
- **所有权 / 错误 / 调用**：不新建值时有两条早退：`error.OutOfMemory` 直接原样返回（**不**走预分配 OOM 对象——那是 `createSentinelError` / `promiseErrorValue` 的策略），已有 pending exception 则返回 `error.JSException` 不覆盖。其余情况由 `hostErrorValue` → `createNamedError` 新建带栈的 Error（GC），`ctx.throwValue` 移交异常槽，返回的 `error.JSException` 哨兵已带 pending exception。

### `throwModuleHostStall` (`src/exec/exception_ops.zig:718`)

- **签名**：`pub fn throwModuleHostStall( ctx: *core.JSContext, global: *core.Object, ) exceptions.HostError!core.JSValue`。
- **作用**：模块求值被宿主调度器卡住（一轮推进后毫无进展）时的抛出点：物化成 `InternalError: module host made no progress`，避免这个状态无声地流出 eval。
- **实现**：已有 pending exception 就直接 `error.JSException`；否则造 `InternalError: module host made no progress`（`module_host_stall_message`）、`throwValue`，返回 `error.JSException`。主机调度器推不动模块求值属于引擎/宿主集成故障，不是动态 import 的 unsupported 哨兵。
- **所有权 / 错误 / 调用**：已有 pending exception 时直接返回 `error.JSException`（不覆盖已挂的异常）；否则 `createNamedError` 建带栈的 `InternalError`，`ctx.throwValue` 移交异常槽，返回 `error.JSException` 哨兵——调用方拿到的是已挂异常的错误。构造失败（OOM）在挂异常前上浮。5 处调用：`src/exec/eval_entry.zig:448`、`:456`、`src/exec/module.zig:1258` 等。

### `errorNameForRuntimeError` (`src/exec/exception_ops.zig:733`)

- **签名**：`fn errorNameForRuntimeError(err: anyerror) ?[]const u8`。
- **作用**：哨兵 error 对应的 Error **名字**（只给 `pendingExceptionMatchesError` 比对用）。
- **实现**：比 `runtimeErrorInfo` 少一层消息：URIError/InvalidUtf8 → URIError；StackOverflow/StringTooLong/**OutOfMemory** → InternalError（漏掉 OOM 会让已挂的 OOM 异常被清掉再重建，在耗尽的堆上分配还丢原栈）；Derived* 与 TypeError/ReferenceError 各归其类；RangeError 家族含 BigIntTooLarge/DivisionByZero/NegativeExponent；其余 null。
- **所有权 / 错误 / 调用**：纯映射，不分配。

### `sourceLocationFromPc2Line` (`src/exec/exception_ops.zig:753`)

- **签名**：`fn sourceLocationFromPc2Line(function: *const bytecode.FunctionBytecode, target_pc: usize) ?SourceLocation`。
- **作用**：在 pc2line 表里查一个 pc 的行列。
- **实现**：pc 转不成 u32、或 `pc2line.findSourceLocation` 出错都返回 null（由 `resolveBacktraceLocation` 折成 0:0）。
- **所有权 / 错误 / 调用**：无：只读**借用**的 `pc2lineBuf` 切片，不分配；`findSourceLocation` 的任何错误与 pc 超 u32 都 `catch`/`orelse` 成 `null`，本函数对外无 error set。文件私有，唯一调用方 `resolveBacktraceLocation`（`src/exec/exception_ops.zig:480`）。

### `defineNonEnumValueProperty` (`src/exec/exception_ops.zig:766`)

- **签名**：`fn defineNonEnumValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void`。
- **作用**：定义 qjs 给 error 对象用的那种 own 数据属性。
- **实现**：`defineOwnProperty(key, Descriptor.data(value, writable = true, enumerable = false, configurable = true))`，即 `JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE`（对照 quickjs.c:7652、41593）。
- **所有权 / 错误 / 调用**：把借用的 `value` 交给 `defineOwnProperty`，此后归属性槽（writable + configurable、非 enumerable，即 qjs 在 error 对象上用的那套属性位）；自身不分配。错误是 `defineOwnProperty` 的透传（`ReadOnly`/`NotExtensible`/OOM 等裸哨兵）。文件私有，5 处调用：`createNamedErrorWithPrototype`（`:96`）、`createPreallocatedOutOfMemoryError`（`:127`）、`buildNamedErrorObject`（`:144`、`:165`）、`promiseAggregateError`（`:290`）。

### `throwReferenceErrorSentinel` (`src/exec/exception_ops.zig:774`)

- **签名**：`fn throwReferenceErrorSentinel(ctx: *core.JSContext) void`。
- **作用**：造不出 Error 对象时的兜底：把一个**裸 int32** 塞进异常槽。
- **实现**：`ctx.throwValue(core.JSValue.int32(comptime core.atom.predefinedId("ReferenceError", .string).?))`——即 ReferenceError 的预定义 atom id（不再硬编码 209）。零分配，用于 TDZ 路径无 realm / 构造失败的兜底；调用方仍然返回 `error.ReferenceError` 哨兵，上层可在异常边界重新物化。
- **所有权 / 错误 / 调用**：把值写进 ctx 的 pending exception 槽；不分配、不返回 error。

## 覆盖核对

- 清单函数数: 199（`src/exec/value_ops.zig` 17 + `src/exec/exception_ops.zig` 2 + `src/exec/exception_ops.zig` 18 + `src/exec/exception_ops.zig` 42 + `src/exec/function_ops.zig` 16 + `src/exec/builtin_glue.zig` 2 + `src/exec/value_ops.zig` 6 + `src/exec/call.zig` 29 + `src/exec/value_ops.zig` 67）
- 本文标题覆盖: 200（含 1 条清单外的内嵌辅助函数标题）
- 未覆盖: 无
