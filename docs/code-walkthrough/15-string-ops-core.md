# 15 — `string_ops.zig`：ToString、concat、RegExp 符号方法

从 `toStringForAnnexB` 到 `stringPrototypeMethod` 之前。concat 对齐 `JS_ConcatString1`：按 code unit 拼接，禁止把 high-latin1 当 UTF-8 再解。

### `toStringForAnnexB` (`src/exec/string_ops.zig:108`)

- **签名**：`pub fn toStringForAnnexB( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：本文件的 ToString owner：对齐 qjs `JS_ToString`，Symbol 抛 TypeError，对象先取 string hint 的原始值。
- **实现**：Symbol 直接抛 TypeError「cannot convert symbol to string」（`JS_ToStringInternal`，quickjs.c:13632）；已是字符串原样返回；对象经 `toPrimitiveForString` 取原始值，取回来仍是 Symbol 同样抛 TypeError，是字符串则直接返回；其余走 `value_ops.toStringValue`。
- **所有权 / 错误 / 调用**：字符串入参**原样借用返回**（`if (value.isString()) return value;`，既不 dup 也不建根），对象腿的结果来自 `toPrimitiveForString`（可能跑用户 `Symbol.toPrimitive`/`toString`/`valueOf`），其余经 `value_ops.toStringValue` 新建串。Symbol（含 ToPrimitive 后仍是 Symbol）由 `throwTypeErrorMessage` 挂上 "cannot convert symbol to string" 并返回 `error.TypeError`——本文件所有 `throw*Message` 都是「装 pending 异常 + 返回对应 Zig error」。它是本文件最热的入口，全树 80+ 处调用，除本文件的 `stringConcat`/`stringReplaceCore`/`captureReplaceMatch` 外还有 `src/binding/context.zig:407`、`src/exec/uri_ops.zig:104`。

### `toStringCheckObject` (`src/exec/string_ops.zig:137`)

- **签名**：`pub fn toStringCheckObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：对齐 `JS_ToStringCheckObject`：null/undefined 抛 TypeError，其余 `toStringForAnnexB`。
- **实现**：对齐 `JS_ToStringCheckObject`：null/undefined 抛 TypeError，其余 `toStringForAnnexB`。String.prototype 方法体的 this 强制转换。QuickJS 坐标：quickjs.c:13670、quickjs.c:45453。
- **所有权 / 错误 / 调用**：只比 `toStringForAnnexB` 多一条 null/undefined 检查（`throwTypeErrorMessage` 挂 "null or undefined are forbidden" 并返回 `error.TypeError`），返回值所有权与它一致：字符串接收者是借用返回，其余是新建串。调用方只有 builtins 侧两处自带 coercion 的直接体——`string_builtin_ops.zig:546`（`stringCharCodeAtDirectHost`）与 `:631`（`stringCaseCall`）。

### `toPrimitiveForString` (`src/exec/string_ops.zig:150`)

- **签名**：`pub fn toPrimitiveForString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：string hint 的 ToPrimitive：先试 `Symbol.toPrimitive`，否则走 toString/valueOf 序列。
- **实现**：非对象原样返回。取 `Symbol.toPrimitive` 属性，为 undefined/null 时落 `toOrdinaryPrimitiveString`；存在但不可调用抛 TypeError「not a function」（qjs `JS_ToPrimitiveInternal` 的 `JS_CallFree`，quickjs.c:11096）；可调用则以 `"string"` hint 调用，返回对象抛 TypeError「toPrimitive」（quickjs.c:11104）。
- **所有权 / 错误 / 调用**：返回值可能是借用的原值（非对象）、用户 `Symbol.toPrimitive` 的返回值，或 `toOrdinaryPrimitiveString` 的结果；`hint` 串是本函数新建的临时值，只作实参传出。它会执行用户 JS，但自身不建根——`value` / `method` 的保活靠调用方窗口。错误：`Symbol.toPrimitive` 非 callable → "not a function"，返回对象 → "toPrimitive"，都带消息。调用方：`toStringForAnnexB:121`、`object_ops.zig:2419`。

### `toOrdinaryPrimitiveString` (`src/exec/string_ops.zig:177`)

- **签名**：`pub fn toOrdinaryPrimitiveString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：OrdinaryToPrimitive(string)：依次试 `toString`、`valueOf`。
- **实现**：两次 `callObjectToPrimitiveMethod`（先 `toString` 后 `valueOf`），任一返回原始值即用；都拿不到原始值时抛 TypeError「toPrimitive」（qjs `JS_ToPrimitiveInternal`，quickjs.c:11131）。
- **所有权 / 错误 / 调用**：两次 `callObjectToPrimitiveMethod` 都可能跑用户 `toString`/`valueOf`，返回的原始值直接交给调用方；两者都给不出原始值时 `throwTypeErrorMessage("toPrimitive")` + `error.TypeError`。调用方：`toPrimitiveForString:160`、`:174`。

### `stringFunctionCall` (`src/exec/string_ops.zig:191`)

- **签名**：`pub fn stringFunctionCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String(...)` 作为函数调用时的实现。
- **实现**：无参数返回空串；Symbol 参数走 `value_ops.toStringValue`（描述串，不抛）；非对象参数同样走 `toStringValue`；对象参数才走带 ToPrimitive 的 `toStringForAnnexB`。
- **所有权 / 错误 / 调用**：无参返回新建空串；Symbol / 非对象参数经 `value_ops.toStringValue` 新建串（注意这里 Symbol 是合法的 `String(sym)` 描述串，与 `toStringForAnnexB` 的 Symbol 禁令相反）；对象参数走 `toStringForAnnexB`，可能跑用户代码。调用方：`string_builtin_ops.zig:705`（`stringCall` 的 `ConstructorMethod.call` 腿）、`call_runtime.zig:1126`。

### `stringConstructWithPrototype` (`src/exec/string_ops.zig:219`)

- **签名**：`pub fn stringConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new String(...)` 的 exec 侧入口：先做可观察的 ToString，再把结果交给 String 构造记录。
- **实现**：无参数用空串，否则 `toStringForAnnexB(args[0])`；随后 `builtin_dispatch.callConstructRecord` 以 `string_construct_ref` 和解析好的 prototype 调用构造记录，记录返回 null 时报 TypeError。
- **所有权 / 错误 / 调用**：先把参数 ToString（新串或借用），再经 `builtin_dispatch.callConstructRecord` 进 `.string` 记录的 construct 腿——真正建包装对象、建根的是 `string_builtin_ops.constructWithPrototype`，本函数只负责可观察的 coercion。记录缺失 → 裸 `error.TypeError`。唯一调用方 `class_init_ops.zig:132`（`class X extends String` 的 super 构造）。

### `stringConcat` (`src/exec/string_ops.zig:235`)

- **签名**：`pub fn stringConcat( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.concat`：把接收者与每个参数各做一次 ToString，再按 code unit 拼成一个新串。
- **实现**：this 是 null/undefined 直接抛 TypeError。段数（`args.len + 1`）不超过 `qjs_concat_direct_part_limit`（32）时用 Zig 栈上的 `parts` 数组：逐段 `toStringForAnnexB` 后用 `concatLatin1Part` 试借 latin1 扁平体，全程保持窄且总长由 `concatAddLength` 累加，则一次 `createLatin1Parts` 建串（总长 0 时返回运行时共享空串）；任一段是 rope 或宽串就落 `stringConcatFromConverted`（按 code unit 拓宽，禁止把 latin1 当 UTF-8 再解）。段数超过 32 才走 `stringConcatSlow`（堆缓冲 + 显式建根）。QuickJS 坐标：quickjs.c:5042（`JS_ConcatString`）、quickjs.c:4646（`JS_ConcatString1`）。
- **所有权 / 错误 / 调用**：≤32 段全在 Zig 栈上：`parts[i].value` 借用各段 ToString 结果，`parts[i].latin1` 借用它们的扁平体。中间还会跑 `toStringForAnnexB`（可能建串、可能跑用户代码），这些栈上的值靠保守栈扫描覆盖——`stringConcatSlow` 的注释正是把「malloc 缓冲不被保守扫描走到」列为它必须显式建根的理由。返回新建串或 runtime 共享空串。错误：nullish 接收者 → 带消息 "null or undefined are forbidden"；长度溢出经 `concatAddLength` → `error.StringTooLong`。调用方：`stringPrototypeMethod:2023`（id 10）、`call_runtime.zig:1334`。

### `stringConcatSlow` (`src/exec/string_ops.zig:295`)

- **签名**：`fn stringConcatSlow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.concat` 的通用路径：段数超过 32 时用堆缓冲。
- **实现**：`values` 预留 `args.len + 1` 容量后用 `ValueSliceRoot` 把 `items` 切片登记成 GC 根（容量已预留，`items.ptr` 稳定，后续 `appendAssumeCapacity` 自动延长被根覆盖的前缀）——每次 `toStringForAnnexB` 都可能分配并运行用户 `toString`，没有这个根前一轮的结果就只被这块 malloc 内存引用。随后逐个 `resolveData()` 累加长度（`concatAddLength` 兜住溢出/超长），任一段是 utf16 就整体 wide；总长为 0 返回空串，否则 `String.createResolvedParts` 一次建串。
- **所有权 / 错误 / 调用**：`values` 是 malloc 内存，不在保守扫描范围内，所以用 `ValueSliceRoot` 把 `values.items` 整段登记成根（容量已预留，`items.ptr` 稳定，`appendAssumeCapacity` 自动延长已登记前缀）——否则第 i 个 ToString 结果会在第 i+1 次 ToString 的回收点被判死。两个 ArrayList defer deinit；返回新建串或共享空串。某段取不到字符串体 → 裸 `error.TypeError`。唯一调用方 `stringConcat:292`（段数 > 32）。

### `stringConcatFromConverted` (`src/exec/string_ops.zig:356`)

- **签名**：`fn stringConcatFromConverted(ctx: *core.JSContext, parts: []const QjsConcatPart) !core.JSValue`。
- **作用**：直接 concat 路径的混宽 / rope 残留分支：按码元拼接，禁止把 high-latin1 当 UTF-8 再解。
- **实现**：逐段取 `asStringBody().resolveData()`（非字符串体报 TypeError），用 `concatAddLength` 累加长度并记录是否出现 utf16；总长为 0 返回运行时空串，否则 `String.createResolvedParts` 一次分配并按需逐单元加宽。对应 qjs `JS_ConcatString1`（quickjs.c:4646）。
- **所有权 / 错误 / 调用**：`parts` 由 `stringConcat` 在栈上持有，本函数只读它们的 `resolveData()` 视图，且解析后到 `createResolvedParts` 之间不建串；返回新建串或共享空串。某段不是字符串体 → 裸 `error.TypeError`。唯一调用方 `stringConcat:289`（混宽 / rope 残余）。

### `concatLatin1Part` (`src/exec/string_ops.zig:377`)

- **签名**：`fn concatLatin1Part(value: core.JSValue) ?[]const u8`。
- **作用**：判断一段 concat 输入能否走 latin1 直接路径，能则借出其字节切片。
- **实现**：rope 直接返回 `null`；取 `asStringBodyRaw()` 后 `borrowLatin1()`，宽串同样返回 `null`。
- **所有权 / 错误 / 调用**：无所有权：返回借用自字符串体的 latin1 切片（rope 或宽串返回 `null`），不分配无 error；切片的有效期由调用方保证。调用方：`stringConcat:257`、`:269`。

### `concatAddLength` (`src/exec/string_ops.zig:383`)

- **签名**：`fn concatAddLength(total: usize, addend: usize) !usize`。
- **作用**：concat 的长度累加与上限检查。
- **实现**：`std.math.add` 溢出转 `error.StringTooLong`；结果超过 `core.string.max_length` 同样报 `error.StringTooLong`。
- **所有权 / 错误 / 调用**：无分配；加法溢出与超过 `core.string.max_length` 都折成 `error.StringTooLong`（`exception_ops.runtimeErrorInfo` 把它映射成 InternalError "string too long"）。调用方：`stringConcat`、`stringConcatSlow`、`stringConcatFromConverted` 共 6 处。

### `stringReplace` (`src/exec/string_ops.zig:389`)

- **签名**：`pub fn stringReplace( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.replace` 的薄包装。
- **实现**：以 `is_replace_all = false` 转 `stringReplaceCore`。
- **所有权 / 错误 / 调用**：薄包装，所有权与错误全在 `stringReplaceCore`（`is_replace_all = false`）。调用方：`stringPrototypeMethod:2013`、`call_runtime.zig:1337`。

### `stringReplaceCore` (`src/exec/string_ops.zig:410`)

- **签名**：`noinline fn stringReplaceCore( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, is_replace_all: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.replace` / `replaceAll` 的共用实现：先 @@replace 委托，否则在 flattened 字符串上做 indexOf + GetSubstitution。
- **实现**：对照 `js_string_replace`（quickjs.c:46012，magic 0/1）。nullish this → 「cannot convert to object」。search 是对象时：replaceAll 先 `isRegExpObservable`，flags 为 nullish → 「cannot convert to object」，flags 字符串无 `g` → 「regexp must have the 'g' flag」；然后 `callStringReplaceMethod`（@@replace）命中即返回。随后 this/search/replace 走 `toStringForAnnexB`。函数替换用 `CallSite`；字面替换走 `appendSubstitutionStringSearch`（captures 为空，只认 `$$` `$&` `$`` `$'`，`$n`/`$<name>` 原样拷）。`ensureFlat` 后 `stringIndexOfData`；空 search 第一次命中 0，之后每次前进 1。第一次搜索未命中直接返回源字符串。`noinline` 防止经薄包装内联进 prototype dispatcher 挤掉 NumericArgs 热路径（实测 charCodeAt +4.6%）。
- **所有权 / 错误 / 调用**：首轮搜索未命中直接**原样返回** `source_value`（借用，不新建）；命中则由 `StringBuffer.finish` 新建串，缓冲 defer deinit。`sp_data` / `search_data` / `rep_data` 是借用的扁平视图，其宿主值只活在本帧 Zig 局部里（保守栈扫描覆盖），而 `replacement_call` 每次命中都会跑用户替换函数（可观察、可回收）。错误：nullish 接收者 → "cannot convert to object"；replaceAll 收到无 g 的正则 → "regexp must have the 'g' flag"；取不到字符串体 → 裸 `error.TypeError`。调用方：`stringReplace:398`、`stringReplaceAll:2139`。

### `resolvedCodeUnitAt` (`src/exec/string_ops.zig:515`)

- **签名**：`fn resolvedCodeUnitAt(data: core.string.String.ResolvedData, index: usize) u16`。
- **作用**：从已解析的 latin1 / utf16 切片取第 index 个码元。
- **实现**：`switch` 两个表示分支：latin1 取字节（零扩展成 u16），utf16 直接取码元。
- **所有权 / 错误 / 调用**：无：`ResolvedData` 是对字符串 payload 的借用视图，本函数只索引不分配、不建根、无 error；索引越界由调用方保证（函数自己不做边界检查）。调用方都在本文件：`stringIndexOfData`（:543,550）、`$`-替换模板扫描（:578,1815,1819,1828,1863）等。

### `stringIndexOfCharData` (`src/exec/string_ops.zig:524`)

- **签名**：`fn stringIndexOfCharData(data: core.string.String.ResolvedData, c: u16, from: usize) ?usize`。
- **作用**：在已解析的切片里找码元 `c` 从 `from` 起的首次出现（qjs `string_indexof_char`）。
- **实现**：`switch` 表示分支：latin1 下 `c > 0xff` 直接 `null`（窄串不可能含该码元），否则 `std.mem.indexOfScalarPos(u8, …)`；utf16 走 `indexOfScalarPos(u16, …)`。QuickJS 坐标：quickjs.c:45553。
- **所有权 / 错误 / 调用**：无：只扫借用视图，不分配无 error（窄串遇到 >0xFF 的目标码元直接返回 `null`）。调用方：`stringIndexOfData:546`、`appendSubstitutionStringSearch:573`。

### `stringIndexOfData` (`src/exec/string_ops.zig:535`)

- **签名**：`fn stringIndexOfData( haystack: core.string.String.ResolvedData, needle: core.string.String.ResolvedData, from: usize, ) ?usize`。
- **作用**：在已解析的切片上做子串查找（qjs `string_indexof`）：首码元扫描 + 尾部比较。
- **实现**：空 needle 返回 `from`；否则取 needle 首码元，循环里用 `stringIndexOfCharData` 找候选位置，位置加长度越界即 `null`，否则逐码元比对尾部，命中返回下标，不中则从 `j + 1` 继续。QuickJS 坐标：quickjs.c:45573。
- **所有权 / 错误 / 调用**：无：只读两个借用视图返回下标，循环内零分配、不建根。唯一调用方 `stringReplaceCore:491`。

### `appendSubstitutionStringSearch` (`src/exec/string_ops.zig:561`)

- **签名**：`fn appendSubstitutionStringSearch( b: *StringBuffer, rt: *core.JSRuntime, matched_value: core.JSValue, sp_data: core.string.String.ResolvedData, position: usize, matched_len: usize, rep_data: core.string.String.ResolvedData, ) !void`。
- **作用**：字符串搜索形态的 GetSubstitution：把替换模板展开进 `StringBuffer`。
- **实现**：用 `stringIndexOfCharData` 找 `$`，末位的 `$` 直接停止扫描；`$$` 输出一个 `$`，`$&` 输出命中串，`` $` `` 输出命中前的前缀，`$'` 输出命中后的后缀；其余 `$c` 按 norep 原样拷贝（captures 为空、namedCaptures 是 undefined，所以 `$N` / `$<name>` 不替换）。循环结束后补上模板剩余部分。QuickJS 坐标：quickjs.c:45888。
- **所有权 / 错误 / 调用**：只往调用方的 `StringBuffer` 追加（缓冲由调用方释放），`sp_data` / `rep_data` 是借用视图、`matched_value` 只读；不新建串、不建根，唯一 error 是缓冲扩容的 `OutOfMemory`。唯一调用方 `stringReplaceCore:504`（非函数替换腿）。

### `callStringReplaceMethod` (`src/exec/string_ops.zig:599`)

- **签名**：`pub fn callStringReplaceMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, search_value: core.JSValue, replace_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`replace` / `replaceAll` 的 `Symbol.replace` 委托：search 是对象且有可调用的 @@replace 时调用它。
- **实现**：search 非对象返回 `null`；取 `Symbol.replace` 属性，为 undefined/null 返回 `null` 让调用方走字符串搜索路径；存在但不可调用返回 TypeError；否则以 `(this_value, replace_value)` 为参数调用。参数刻意不在本帧登记根：`this_value` / `replace_value` / `search_value` 都已被上一帧的 builtin 窗口以 `.slices = .{ .borrowed = args }` 覆盖（源码注释记录了这一 TGC R1-c 判断）。
- **所有权 / 错误 / 调用**：返回用户 `Symbol.replace` 的结果（归调用方），对象没有该方法时返回 `null` 让调用方走字符串搜索腿。源码注释交代了这里**故意不建根**：`this_value` / `replace_value` / `search_value` 都已被上一层 `callTypedInternalRecordDirect` 的 `.slices = .{ .borrowed = args }` 覆盖，唯一没有第二 owner 的是 @@replace 取回的 `replacer`。错误：`replacer` 非 callable → 裸 `error.TypeError`。唯一调用方 `stringReplaceCore:445`。

### `errorStackStringValue` (`src/exec/string_ops.zig:651`)

- **签名**：`noinline fn errorStackStringValue( ctx: *core.JSContext, global: ?*core.Object, skip_name: ?[]const u8, sites_value: core.JSValue, site_count: usize, kind: ErrorStackStringKind, ) !core.JSValue`。
- **作用**：把 live 回溯或 captured CallSite 数组格式化成 `"    at name (file:line:col)\n"` 错误栈字符串。
- **实现**：`.live`：`errorStackTraceLimit==0` 返回空串；`snapshotBacktraceFrames` 从尾往头走，`skip_name` 命中前跳过，native 帧写 `(native)`，否则 `allocPrint(" ({s}:{}:{})")`。`.captured`：从 `sites_value` 数组取最多 `site_count` 个 CallSite，同样格式。两种 kind 共用 ArrayList + `"    at "` leftover；public `inline` 包装只传 kind。有输出时末尾再追加 `\n`。
- **所有权 / 错误 / 调用**：`bytes` 与每行的 `allocPrint` 后缀都在返回前释放，live 腿另有 `freeBacktraceFrameSnapshot` 归还帧快照；返回 `createStringValue` 新建的串。captured 腿只读 `sites_value` 数组里的 CallSite 对象（借用），`global` 允许为 null。调用方只有两个 `inline` 包装 `buildErrorStackStringValue:738` / `formatCapturedErrorStackStringValue:742`。

### `buildErrorStackStringValue` (`src/exec/string_ops.zig:737`)

- **签名**：`pub inline fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue`。
- **作用**：从当前 live 回溯快照格式化出错误 `stack` 用的 `"    at …"` 文本（`skip_name` 用来跳过构造器自身及其之上的帧）。
- **实现**：薄封装，主体转发到 `errorStackStringValue`、`JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：`inline` 包装，只固定 `kind = .live` 并要求非空 realm global；返回值归调用方。调用方：`error_stack_ops.zig:45`、`:61`、`:139`。

### `formatCapturedErrorStackStringValue` (`src/exec/string_ops.zig:741`)

- **签名**：`pub inline fn formatCapturedErrorStackStringValue(ctx: *core.JSContext, sites_value: core.JSValue, site_count: usize) !core.JSValue`。
- **作用**：把已捕获的 CallSite 数组（最多取 `site_count` 条）格式化成同样的 `"    at …"` 栈文本。
- **实现**：薄封装，主体转发到 `errorStackStringValue`。
- **所有权 / 错误 / 调用**：`inline` 包装，`kind = .captured`、`global` 传 null（captured 腿不需要 realm）。调用方：`error_stack_ops.zig:72`、`:88`。

### `stringFromCodePoint` (`src/exec/string_ops.zig:745`)

- **签名**：`pub fn stringFromCodePoint( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`String.fromCodePoint`：逐参数做可观察的 ToNumber 后编码成 UTF-16。
- **实现**：逐参数 `toPrimitiveForNumber` + `value_ops.toNumberValue`；NaN / 非有限 / 负数 / 大于 0x10FFFF / 非整数都抛 RangeError「invalid code point」（qjs `js_string_fromCodePoint`，quickjs.c:45361）；合法码点经 `appendUtf16CodePoint` 追加，最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`units` ArrayList defer deinit，返回新建 UTF-16 串；`toPrimitiveForNumber` 可能跑用户代码。越界 / 非整数码点由 `throwRangeErrorMessage` 挂上 "invalid code point" 后返回 `error.RangeError`。调用方：`string_builtin_ops.zig:707`（`stringCall` 的 from_code_point 腿）、`call_runtime.zig:1228`。

### `stringRaw` (`src/exec/string_ops.zig:768`)

- **签名**：`pub fn stringRaw( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.raw`：按 `raw` 数组与替换值交错拼出模板原文。
- **实现**：模板对象与其 `raw` 属性都经 `toObjectForStringRaw`（nullish 抛「cannot convert to object」）；长度经 `toLengthIndex`。循环里下标超过 `maxInt(u32)` 返回 `error.RangeError`；每段 `raw[i]` 做 ToString 后按码元追加，若还有下一段且 `args` 里有对应替换值，则把 `args[i+1]` 的 ToString 结果也追加；最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`out` u16 ArrayList defer deinit，返回新建 UTF-16 串；中途的 `getValueProperty` / `toStringForAnnexB` 都可能跑用户代码（模板对象可以是任意对象），本函数不给中间串建根。错误：下标超 u32 → 裸 `error.RangeError`；nullish 模板 → `toObjectForStringRaw` 的带消息 TypeError。调用方：`string_builtin_ops.zig:708`、`call_runtime.zig:1091`。

### `toObjectForStringRaw` (`src/exec/string_ops.zig:805`)

- **签名**：`pub fn toObjectForStringRaw(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !core.JSValue`。
- **作用**：`String.raw` 用的 ToObject：nullish 抛 TypeError，原始值包成包装对象。
- **实现**：null / undefined 抛 TypeError「cannot convert to object」（qjs `js_string_raw` 的 `JS_ToObject`，quickjs.c:39916）；已是对象原样返回；其余经 `primitiveObjectForAccess` 取包装对象。
- **所有权 / 错误 / 调用**：对象入参**原样借用返回**；原始值经 `primitiveObjectForAccess` 得到（可能新建包装对象，归调用方）。nullish → "cannot convert to object" 带消息 TypeError。调用方：`stringRaw:777`、`:781`。

### `stringFromCharCode` (`src/exec/string_ops.zig:813`)

- **签名**：`pub fn stringFromCharCode( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`String.fromCharCode` 的 VM 共享实现：逐参数 ToNumber 后取低 16 位码元。
- **实现**：单个 int32 参数时低 16 位 ≤ 0xff 走 `runtime.singleByteString`，否则单码元 `createUtf16`；两个 int32 参数走 `runtime.recentTwoUnitString` 缓存。其余情况按参数个数分配 u16 缓冲，逐参数 `toPrimitiveForNumber`（BigInt 返回 `error.TypeError`）+ `toNumberValue` 后经 `toUint16CodeUnit` 截断，最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：一参 / 两参快路径返回的是 runtime 的共享单字节串或 `recentTwoUnitString` 缓存项（**不是**新分配，调用方不得释放）；一般路径 `rt.memory.alloc` 的 u16 缓冲 defer free，返回新建串。BigInt 参数 → 裸 `error.TypeError`；`toPrimitiveForNumber` 可能跑用户代码。调用方：`string_builtin_ops.zig:434`（NMFD 直接体）、`:452`（handler）、`:706`（`stringCall`）、`call_runtime.zig:1134`。

### `regExpNativeBuiltinMatches` (`src/exec/string_ops.zig:850`)

- **签名**：`pub fn regExpNativeBuiltinMatches(value: core.JSValue, expected_id: u32) bool`。
- **作用**：判断某个值是否就是 RegExp 域里指定 id 的原生内建函数。
- **实现**：取函数对象后解码 `nativeFunctionId()`，要求 `domain == .regexp` 且 id 相等；任何一步失败返回 `false`。
- **所有权 / 错误 / 调用**：无：纯 native id 比较，不分配无 error。调用方：`object_ops.zig:1054`、`:1077`。

### `regExpAutoInitBuiltinMatches` (`src/exec/string_ops.zig:856`)

- **签名**：`pub fn regExpAutoInitBuiltinMatches(info: core.property.AutoInit, expected_id: u32) bool`。
- **作用**：同上，但作用于尚未实体化的 AutoInit 属性槽。
- **实现**：`info.kind` 不是 `.native_function` 返回 `false`；否则解码 `info.native_builtin_id` 并比较 domain/id。
- **所有权 / 错误 / 调用**：无：纯 `AutoInit` 描述符检查，不分配无 error。唯一调用方 `object_ops.zig:1055`。

### `regExpToString` (`src/exec/string_ops.zig:862`)

- **签名**：`pub fn regExpToString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`RegExp.prototype.toString`：拼出 `/source/flags`。
- **实现**：接收者非对象返回 `error.TypeError`；分别读 `source` 与 `flags` 属性并做 ToString（都可能触发用户 getter），再按 `/`、source、`/`、flags 拼进字节缓冲后建串。
- **所有权 / 错误 / 调用**：`bytes` 缓冲 defer deinit，返回新建串；`source` / `flags` 两次属性读都可能跑用户 getter。非对象接收者 → 裸 `error.TypeError`。唯一调用方 `regexp_ops.zig:287`。

### `regexpInternalStringValue` (`src/exec/string_ops.zig:889`)

- **签名**：`pub fn regexpInternalStringValue(rt: *core.JSRuntime, object: *core.Object, source: bool) !core.JSValue`。
- **作用**：取 RegExp 对象内部的 source 串或由已编译字节码还原的 flags 串。
- **实现**：`source` 为真时返回 `object.regexpSource()`（缺失则 TypeError）；否则由 `object.regexpCompiledBytecode()` 经 `regexp_adapter.flagsStringValueFromBytecode` 还原 flags 串。
- **所有权 / 错误 / 调用**：source 腿返回**借用**的 `object.regexpSource()`（正则对象自己持有的串），flags 腿返回 `regexp_adapter.flagsStringValueFromBytecode` 新建的 ASCII 串。没有 source → 裸 `error.TypeError`。调用方：`regexp_fastpath.zig:221`、`:252`、`:384` 等 5 处。

### `regExpSymbolSearch` (`src/exec/string_ops.zig:896`)

- **签名**：`pub fn regExpSymbolSearch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.search]` 的入口：强制参数为字符串后转通用体。
- **实现**：接收者非对象返回 `error.TypeError`；参数缺省为 undefined，经 `toStringForAnnexB` 后转 `regExpSymbolSearchGeneric`。
- **所有权 / 错误 / 调用**：自身只做 ToString（新串或借用）后转 `regExpSymbolSearchGeneric`，返回值归调用方；签名是 `!?JSValue` 但实际不返回 null。非对象接收者 → 裸 `error.TypeError`。调用方：`regexp_ops.zig:290`、`call_runtime.zig:1349`。

### `regExpSymbolMatch` (`src/exec/string_ops.zig:911`)

- **签名**：`pub fn regExpSymbolMatch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.match]` 的入口：强制参数为字符串后转通用体。
- **实现**：接收者非对象返回 `error.TypeError`；参数缺省为 undefined，经 `toStringForAnnexB` 后转 `regExpSymbolMatchGeneric`。
- **所有权 / 错误 / 调用**：同 `regExpSymbolSearch` 的形状，转 `regExpSymbolMatchGeneric`；本函数不分配。非对象接收者 → 裸 `error.TypeError`。调用方：`regexp_ops.zig:291`、`:428`、`call_runtime.zig:1352`。

### `regExpSymbolMatchAll` (`src/exec/string_ops.zig:926`)

- **签名**：`pub fn regExpSymbolMatchAll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.matchAll]`：按 species 构造 matcher 并造出 RegExp String Iterator。
- **实现**：接收者非对象返回 `error.TypeError`；参数经 `toStringForAnnexB`。随后 `regExpSpeciesConstructor` 取构造器，用 `(this, flags)` 构造 matcher，把接收者的 `lastIndex` 经 `toLengthIndex` / `toUint32Number` 规范后写进 matcher。最后创建 `regexp_string_iterator` 对象（原型来自 `regExpStringIteratorPrototype`），target 槽存 matcher、data 槽存字符串，`iteratorKindSlot` 的 bit0 记 `g`、bit1 记完整 Unicode，下标清零。
- **所有权 / 错误 / 调用**：新建 regexp_string_iterator 对象并把 species 构造出的 `matcher` 与 `string_value` 写进它的 target / data 槽（`setOptionalValueSlot` 负责屏障），失败时 `errdefer` 显式 `destroyFromHeader` 销毁它；返回的迭代器归调用方。中途多次跑用户代码（species 构造器、flags getter、lastIndex 读写），这些中间值不建根。错误：非对象接收者、缺 `flags` 原子 → 裸 `error.TypeError`。调用方：`regexp_ops.zig:292`、`call_runtime.zig:1355`。

### `stringMatchAll` (`src/exec/string_ops.zig:964`)

- **签名**：`pub fn stringMatchAll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.matchAll`：优先委托参数的 `Symbol.matchAll`，否则用带 `g` 的 RegExp 构造一个。
- **实现**：nullish 接收者抛 TypeError「cannot convert to object」（qjs `js_string_match`，quickjs.c:45846），随后接收者做 ToString。参数是对象时先取 `Symbol.matchAll`，若参数是可观察的 RegExp 则检查 flags：nullish flags 抛「cannot convert to object」、缺 `g` 抛「regexp must have the 'g' flag」（quickjs.c:45819）；@@matchAll 非 nullish 就调用它。否则用 `(regexp, "g")` 走 RegExp 构造记录，再取其 `Symbol.matchAll` 调用（缺失返回 TypeError）。
- **所有权 / 错误 / 调用**：返回的是用户 @@matchAll（或新建正则的 @@matchAll）的结果，归调用方；本函数只新建 `"g"` flags 串和经记录构造的正则对象。错误：nullish 接收者 / flags 为 nullish → "cannot convert to object"，缺 g → "regexp must have the 'g' flag"（都带消息），新正则没有 @@matchAll → 裸 `error.TypeError`。唯一调用方 `stringPrototypeMethod:2019`。

### `regExpStringIteratorPrototype` (`src/exec/string_ops.zig:1005`)

- **签名**：`pub fn regExpStringIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：惰性建出 RegExp String Iterator 的原型对象。
- **实现**：在 `iteratorPrototype(rt, global, "RegExp String Iterator")` 之上定义 `next`（`Descriptor.data(next, true, false, true)`：可写、不可枚举、可配置）；失败时 `errdefer` 销毁刚建的原型。
- **所有权 / 错误 / 调用**：返回的 prototype 对象直接被调用方拿去当新迭代器的 proto；`next` 定义失败时 `errdefer` 销毁刚建的 proto。`nativeFunctionForGlobal` 建的 `next` 函数随即由 proto 持有。唯一调用方 `regExpSymbolMatchAll:952`。

### `regExpSymbolReplace` (`src/exec/string_ops.zig:1013`)

- **签名**：`pub fn regExpSymbolReplace( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.replace]` 的入口：强制字符串参数后转通用体。
- **实现**：接收者非对象返回 `error.TypeError`；第一个参数经 `toStringForAnnexB`，第二个参数原样交 `regExpSymbolReplaceGeneric`。
- **所有权 / 错误 / 调用**：只做 ToString 后转 `regExpSymbolReplaceGeneric`，本函数不分配，返回值归调用方。非对象接收者 → 裸 `error.TypeError`。调用方：`regexp_ops.zig:293`、`call_runtime.zig:1358`。

### `regExpSymbolSplit` (`src/exec/string_ops.zig:1029`)

- **签名**：`pub fn regExpSymbolSplit( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`RegExp.prototype[Symbol.split]`：按 species 造 splitter、规范 limit 后转通用体。
- **实现**：接收者非对象返回 `error.TypeError`；字符串参数经 `toStringForAnnexB`。`regExpSpeciesConstructor` 取构造器、`regExpSplitFlags` 保证 flags 带 `y`，据此构造 splitter。limit 参数缺省或 undefined 时取 `maxInt(u32)`，否则经 `toPrimitiveForNumber`（BigInt 返回 `error.TypeError`）+ ToNumber + `toUint32Number` 规范；limit 为 0 时直接返回空数组。最后按 flags 是否是完整 Unicode 决定 `unicode_matching` 并转 `regExpSymbolSplitGeneric`。
- **所有权 / 错误 / 调用**：新建 splitter 正则（species 构造，可能跑用户代码）与 `limit == 0` 时的空数组，都归调用方；其余工作交给 `regExpSymbolSplitGeneric`。BigInt limit → 裸 `error.TypeError`。调用方：`regexp_ops.zig:294`、`:448`、`call_runtime.zig:1361`。

### `regExpSplitFlags` (`src/exec/string_ops.zig:1064`)

- **签名**：`pub fn regExpSplitFlags( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：给 @@split 的 splitter 准备 flags：确保带 `y`。
- **实现**：取 `flags` 字符串，已含 `y` 则原样返回；否则 `value_ops.appendAsciiSuffixOwned(flags, "y")` 消费原串并一次分配出带后缀的结果（对应 qjs 的 `JS_ConcatString3(ctx, "", flags, "y")`，省掉字面量的临时 JSString）。
- **所有权 / 错误 / 调用**：已含 'y' 时**原样借用返回** flags 串；否则 `value_ops.appendAsciiSuffixOwned` 消费它并返回新建串（qjs `JS_ConcatString3` 的对应点，省掉字面量那个中间 JSString）。唯一调用方 `regExpSymbolSplit:1043`。

### `stringValueContainsByte` (`src/exec/string_ops.zig:1081`)

- **签名**：`pub fn stringValueContainsByte(rt: *core.JSRuntime, string_value: core.JSValue, needle: u8) !bool`。
- **作用**：判断字符串值是否含某个 ASCII 字节（flags 检查用）。
- **实现**：已是字符串体时直接走 `stringValueContainsUnitByte` 在扁平 latin1/utf16 载荷上查（与 qjs `string_indexof_char` 同形），非字符串调用方才落到 `appendRawString` + `std.mem.indexOfScalar` 的通用回退。
- **所有权 / 错误 / 调用**：无所有权：字符串体走 `stringValueContainsUnitByte` 只读借用视图；非字符串体腿的 `bytes` 缓冲 defer deinit。返回 bool，唯一 error 来自转换/扩容。调用方：`regExpSymbolMatchAll:957`、`stringMatchAll:989`、`regExpSymbolReplaceGeneric:1378` 等 5 处（含 `regexp_fastpath.zig:471`/`:472`）。

### `regExpSymbolSplitGeneric` (`src/exec/string_ops.zig:1092`)

- **签名**：`pub fn regExpSymbolSplitGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, splitter: core.JSValue, string_value: core.JSValue, limit: u32, unicode_matching: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：@@split 的通用循环：反复调 splitter 的 exec，按命中区间切段并展开捕获。
- **实现**：借用已 `ensureFlat` 的接收串扁平体（不预先拷贝码元，避免把 latin1 拓宽）。空串输入时只调一次 exec，未命中就把整串作为唯一元素。主循环里每轮把 `lastIndex` 写成当前 `pos` 后调 `regExpExecGeneric`：结果为 null 或 `end == start` 时按 `advanceStringIndexBody` 推进；否则切出 `[start, pos)` 段，再把结果数组里 1..length 的捕获原样（不做 ToString）追加，任一时刻 `out_index` 达到 `limit` 立即返回。循环结束补上尾段。
- **所有权 / 错误 / 调用**：`out`、接收串、splitter、exec 结果都挂在 `ValueRootFrame` 上——借用的扁平体 `string_body` 靠 `string_value` 被钉住才合法，而循环里每次 `setValuePropertyStrict` / `regExpExecGeneric` 都可能跑用户代码并回收。返回新建数组，元素串由数组持有；失败时 `errdefer` 显式销毁刚建的数组。取不到字符串体 → 裸 `error.TypeError`。唯一调用方 `regExpSymbolSplit:1061`。

### `advanceStringIndexBody` (`src/exec/string_ops.zig:1188`)

- **签名**：`pub fn advanceStringIndexBody(string: *const core.string.String, index: usize, unicode: bool) usize`。
- **作用**：按 Unicode/码元规则推进字符串下标。
- **实现**：非 unicode 模式或已是最后一个码元时直接 `index + 1`；否则当前码元是高代理且后继是低代理才 `index + 2`。
- **所有权 / 错误 / 调用**：无：只读借用的 `*const String` 返回下标，不分配无 error。调用方：`regExpSymbolSplitGeneric:1151`、`:1159`。

### `advanceStringIndexUnits` (`src/exec/string_ops.zig:1196`)

- **签名**：`pub fn advanceStringIndexUnits(units: []const u16, index: usize, unicode: bool) usize`。
- **作用**：按 Unicode/码元规则推进字符串下标。
- **实现**：同 `advanceStringIndexBody`，但直接在 u16 切片上做：非 unicode 或越界 `index + 1`，成对代理才 `index + 2`。
- **所有权 / 错误 / 调用**：无：只读调用方给的 u16 切片，不分配无 error。唯一调用方 `advanceStringIndexData:1556`。

### `regExpSymbolSearchGeneric` (`src/exec/string_ops.zig:1204`)

- **签名**：`pub fn regExpSymbolSearchGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, string_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：@@search 的通用体：保存并恢复 `lastIndex`，用 exec 取命中位置。
- **实现**：先读 `lastIndex`，不等于 0 就写 0；跑一次 `regExpExecGeneric`；跑完再读 `lastIndex`，与之前不同则写回旧值。结果为 null 返回 -1；结果不是对象返回 `error.TypeError`；否则返回结果的 `index` 属性。
- **所有权 / 错误 / 调用**：返回 exec 结果的 `index` 属性值（用户 `exec` 可返回任意对象，所以形态不定），归调用方；本函数不分配、不建根，但 lastIndex 的读写与 `regExpExecGeneric` 都会跑用户代码。exec 返回非 null 的非对象 → 裸 `error.TypeError`。唯一调用方 `regExpSymbolSearch:908`。

### `regExpSymbolMatchGeneric` (`src/exec/string_ops.zig:1231`)

- **签名**：`pub fn regExpSymbolMatchGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, string_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：@@match 的通用体：非 global 直接返回一次 exec 结果，global 时循环收集所有命中串。
- **实现**：取 flags 串：不含 `g` 时直接返回一次 `regExpExecGeneric` 的结果。含 `g` 时先把 `lastIndex` 写 0 并建结果数组，循环 exec：结果为 null 即结束，否则读第 0 个元素（已是字符串就直接用，否则 `toStringForAnnexB`）追加进数组；命中为空串时读 `lastIndex` 并用 `advanceStringIndexNumber`（按完整 Unicode 标志）推进后写回。一次都没命中时显式销毁这个投机建出的数组并返回 null。
- **所有权 / 错误 / 调用**：非 g 分支直接把 `regExpExecGeneric` 的结果交给调用方；g 分支新建数组，每个匹配串经 `defineSplitValueElementOwned` 把所有权让渡给数组。零命中时**显式** `destroyFromHeader` 销毁这个投机数组再返回 JS null（`errdefer` 在成功返回路径上不跑，这是 qjs 同一处的行为），异常路径才由 `errdefer` 销毁。唯一调用方 `regExpSymbolMatch:923`。

### `ReplaceMatchRoots.traceRoots` (`src/exec/string_ops.zig:1305`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：把结构内所有 JSValue 交给 RootVisitor。
- **实现**：先 `@ptrCast(@alignCast(context))` 把不透明上下文还原成 `*ReplaceMatchRoots`，再遍历 `self.list.items`，对每条 `ReplaceMatch` 依次 `visitor.value(&match.result)`、`visitor.value(&match.matched)`、`visitor.values(match.captures)`、`visitor.value(&match.groups)`。
- **所有权 / 错误 / 调用**：GC 标记回调：把 `list` 里每条 `ReplaceMatch` 的 `result` / `matched` / `captures` / `groups` 报告给 tracer。它不拥有任何值（`captures` 的内存由 `freeReplaceMatches` 释放），只在 `regExpSymbolReplaceGeneric` 的窗口里被注册。无 Zig 调用方：由 `core.runtime.RootVisitor` 经 `provider()` 里的函数指针调起。

### `ReplaceMatchRoots.provider` (`src/exec/string_ops.zig:1315`)

- **签名**：`fn provider(self: *ReplaceMatchRoots) core.runtime.RootProvider`。
- **作用**：构造 RootProvider，把 context/trace 交给 runtime。
- **实现**：单表达式 `.{ .context = @ptrCast(self), .trace = traceRoots }`——把 `self` 擦成 `*anyopaque`，配上本结构的 `traceRoots` 函数指针。
- **所有权 / 错误 / 调用**：把 `self` 指针与 `traceRoots` 打包成 `RootProvider`（借用，不转移所有权）；注册与注销必须用**同一个** provider 值，所以两处都现算。调用方：`activate:1321`、`deactivate:1327`。

### `ReplaceMatchRoots.activate` (`src/exec/string_ops.zig:1319`)

- **签名**：`fn activate(self: *ReplaceMatchRoots) !void`。
- **作用**：把本结构的值切片登记为 GC 根。
- **实现**：`core.runtime.value_root_frames_enabled` 为假时直接返回；否则 `runtime.registerRootProvider(self.provider())` 并置 `registered`。
- **所有权 / 错误 / 调用**：`value_root_frames_enabled` 关闭时是 no-op；否则向 runtime 注册 provider 并置 `registered`，注册表扩容失败时错误上抛且不置位（`deactivate` 因此不会误注销）。唯一调用方 `regExpSymbolReplaceGeneric:1390`，紧跟一个 `defer deactivate`。

### `ReplaceMatchRoots.deactivate` (`src/exec/string_ops.zig:1325`)

- **签名**：`fn deactivate(self: *ReplaceMatchRoots) void`。
- **作用**：注销 RootProvider（未注册时是 no-op）。
- **实现**：`registered` 为假直接返回；否则 `runtime.unregisterRootProvider(self.provider())` 并清标志。
- **所有权 / 错误 / 调用**：幂等注销：没注册过直接返回。唯一调用方 `regExpSymbolReplaceGeneric:1391` 的 `defer`。

### `regExpSymbolReplaceGeneric` (`src/exec/string_ops.zig:1332`)

- **签名**：`pub fn regExpSymbolReplaceGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, string_value: core.JSValue, replace_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：@@replace 的通用体：收集命中（含 named groups）后按函数或模板生成替换结果。
- **实现**：replace 参数可调用时建 `CallSite`，否则先 ToString 成模板串。模板替换且接收者是标准 RegExp 时先试 `regExpReplaceFast`——这一探测在读 flags getter 之前，且本身无副作用，与 qjs 顺序一致。通用路径读 flags 决定 global / 完整 Unicode，global 时把 `lastIndex` 写 0，然后循环 `regExpExecGeneric`：结果为 null 结束、非对象报 TypeError，否则经 `captureReplaceMatch` 存进 `ArrayList(ReplaceMatch)`（该数组经 `ReplaceMatchRoots` 注册成 RootProvider，否则 replacer 回调触发 GC 时 named groups 会被回收）；非 global 只取一次，空命中按 `advanceStringIndexNumber` 推进 `lastIndex`。一次都没命中直接返回源串。拼接阶段把源串展成 u16，按命中顺序追加 `[next_source_position, position)` 片段与替换文本：函数替换走 `callReplaceFunction`，空模板且无 groups 时跳过追加，无 `$` 的字面模板直接复用原串，其余走 `getSubstitutionString`；最后补上尾段并 `String.createUtf16`。
- **所有权 / 错误 / 调用**：命中列表 `matches` 在 Zig 堆上，值散落在结构体里，既不被保守扫描也不被 `ValueRootSlice` 看到，所以整段挂 `ReplaceMatchRoots` 这个 `RootProvider`（源码注释记着它的来历：test262 named-groups 用例在 GC stress 下读到被回收的 `groups`）。`captures` 的内存由 `defer freeReplaceMatches` 释放；零命中时**原样返回** `string_value`（借用），否则返回新建 UTF-16 串。错误：exec 返回非 null 的非对象 → 裸 `error.TypeError`，其余由被调方挂消息。唯一调用方 `regExpSymbolReplace:1026`。

### `regExpReplaceFast` (`src/exec/string_ops.zig:1452`)

- **签名**：`pub fn regExpReplaceFast( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, string_value: core.JSValue, replacement_string: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：标准 RegExp + 模板替换时的快路径：直接跑已编译字节码，不经属性读写与结果数组。
- **实现**：前置条件任一不满足就返回 `null` 交回通用驱动：接收者不是 `class.ids.regexp` 对象、`lastIndex` 需要可观察强制转换、没有已编译字节码、或字节码带命名分组（`$<name>` 只有通用路径支持）。flags 直接从编译字节码的 flag bits 读（不碰可能被改写的 flags getter），global 时先把 `lastIndex` 清零。源串与模板串都 `ensureFlat` 后借用扁平载荷；捕获槽优先用栈上 `small_exec_slots`，不够才堆分配。循环里 `last_index > source_len` 或匹配失败时（global/sticky 会清零 `lastIndex`）结束；命中则把命中前的片段与 `appendRegExpSubstitutionFromSlots` 展开的模板写进 `StringBuffer`；非 global 只走一轮（sticky 时把 `lastIndex` 写成命中末尾），global 下空命中按 `advanceStringIndexData` 推进、否则从命中末尾继续。最后补尾段并 `b.finish`。
- **所有权 / 错误 / 调用**：前置条件不满足时返回 `null` 让上层走通用驱动；匹配阶段的 `error.BytecodeCorrupt` / `error.Timeout` 也被就地吞成 `null` 回退，不外传。整条路径不建任何 JS 对象：捕获槽是栈上数组（超过 `small_exec_slots` 才 `alloc` 并 defer free），`sp_data` / `rep_data` 是借用的扁平视图，`StringBuffer` defer deinit，最后 `finish` 新建结果串归调用方。`lastIndex` 的写回走 `setRegExpLastIndexStrict`（可能跑用户 setter）。唯一调用方 `regExpSymbolReplaceGeneric:1370`。

### `advanceStringIndexData` (`src/exec/string_ops.zig:1553`)

- **签名**：`fn advanceStringIndexData(data: core.string.String.ResolvedData, index: usize, unicode: bool) usize`。
- **作用**：按 Unicode/码元规则推进字符串下标。
- **实现**：`switch` 表示分支：latin1 永远 `index + 1`（窄串没有代理对），utf16 转 `advanceStringIndexUnits`。QuickJS 坐标：quickjs.c:45589。
- **所有权 / 错误 / 调用**：无：latin1 视图不可能含代理对，直接 +1；宽腿转 `advanceStringIndexUnits`。唯一调用方 `regExpReplaceFast:1543`。

### `appendStringValueUnits` (`src/exec/string_ops.zig:1560`)

- **签名**：`pub fn appendStringValueUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void`。
- **作用**：将字符串的码元追加到 u16 缓冲。
- **实现**：字符串先 ensureFlat：Latin-1 字节逐个扩为 u16，UTF-16 直接 appendSlice；非字符串先 appendRawString 到临时字节缓冲，再逐字节扩为 u16。
- **所有权 / 错误 / 调用**：临时字节缓冲由 defer 释放，out 由调用方清理。无返回值对象，转换与分配错误向上传播。

### `stringValueContainsUnitByte` (`src/exec/string_ops.zig:1575`)

- **签名**：`pub fn stringValueContainsUnitByte(value: core.JSValue, needle: u8) bool`。
- **作用**：在已展平的字符串载荷里找某个 ASCII 字节。
- **实现**：非字符串体返回 `false`；`switch` 表示分支：latin1 用 `std.mem.indexOfScalar`，utf16 逐码元比较。
- **所有权 / 错误 / 调用**：无：只读借用视图，非字符串体返回 false，不分配无 error。调用方：`regExpSplitFlags:1073`、`regExpSymbolMatchGeneric:1242`、`regExpSymbolReplaceGeneric:1413` 等 4 处。

### `stringValueUnitsEqualBytes` (`src/exec/string_ops.zig:1588`)

- **签名**：`pub fn stringValueUnitsEqualBytes(value: core.JSValue, expected: []const u8) bool`。
- **作用**：把字符串值和一段 ASCII 字节逐单元比较（不分配）。
- **实现**：非字符串体返回 `false`；`switch` 表示分支：latin1 用 `std.mem.eql`，utf16 先比长度再逐码元与字节比较。
- **所有权 / 错误 / 调用**：无：只读借用视图逐单元比较，不分配无 error。调用方都在别的 ops：`date_ops.zig:306`/`:310`、`iterator_ops.zig:1698-1700`。

### `getRegExpFlagsStringForReplace` (`src/exec/string_ops.zig:1602`)

- **签名**：`pub fn getRegExpFlagsStringForReplace( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：@@replace 路径取 flags 串的命名入口。
- **实现**：直接转 `getRegExpFlagsString`。
- **所有权 / 错误 / 调用**：纯转发 `getRegExpFlagsString`（保留 replace 侧的命名点），所有权与错误完全同它。唯一调用方 `regExpSymbolReplaceGeneric:1377`。

### `getRegExpFlagsString` (`src/exec/string_ops.zig:1613`)

- **签名**：`pub fn getRegExpFlagsString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, rx: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：读 RegExp 的 `flags` 属性并 ToString（可能触发用户 getter）。
- **实现**：取预定义 atom `flags` 的属性值后 `toStringForAnnexB`。
- **所有权 / 错误 / 调用**：读 `flags` 属性（可能跑用户 getter）再 ToString：字符串结果是借用返回，其余是新建串；错误只来自这两步。调用方：`regExpSplitFlags:1072`、`regExpSymbolMatchGeneric:1240`、`getRegExpFlagsStringForReplace:1610`。

### `captureReplaceMatch` (`src/exec/string_ops.zig:1626`)

- **签名**：`pub fn captureReplaceMatch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, result: core.JSValue, string_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !ReplaceMatch`。
- **作用**：把一次 exec 结果对象抽成 `ReplaceMatch`（命中串、位置、捕获数组、groups）。
- **实现**：读第 0 个元素做 ToString 得 `matched`；读 `index` 经 `toLengthIndex` 后钳到串长；读 `length` 决定捕获个数，为每个捕获分配数组并逐个读取（非 undefined 的做 ToString），失败路径 `errdefer` 释放已分配的捕获数组；再读 `groups`。捕获数组在填充期间由 `captures_root` 登记成根。
- **所有权 / 错误 / 调用**：`captures` 是 `rt.memory.alloc` 的 JSValue 数组，**所有权随返回的 `ReplaceMatch` 交给调用方**，由 `freeReplaceMatches` 释放；失败时 `errdefer` 先 free 这块内存。填充期间用 `ValueSliceRoot` 只登记已初始化前缀 `captures[0..initialized]`（每次 `toStringForAnnexB` 都可能建串并触发回收），失败时把前缀清成 undefined 再撤根。`result` / `matched` / `groups` 只是借用地存进结构体，真正保活靠调用方的 `ReplaceMatchRoots`。缺 `index` / `groups` 原子 → 裸 `error.TypeError`。唯一调用方 `regExpSymbolReplaceGeneric:1401`。

### `freeReplaceMatches` (`src/exec/string_ops.zig:1678`)

- **签名**：`pub fn freeReplaceMatches(rt: *core.JSRuntime, matches: []ReplaceMatch) void`。
- **作用**：释放 `captureReplaceMatch` 为每个命中分配的 captures 数组。
- **实现**：逐条 match，非空 `captures` 走 `rt.memory.free`。
- **所有权 / 错误 / 调用**：只释放每条命中的 `captures` 数组内存（JSValue 本身归 GC 管），不碰 `result` / `matched` / `groups`；重复调用会二次释放，所以只挂在 `regExpSymbolReplaceGeneric:1387` 的一个 `defer` 上。

### `callReplaceFunction` (`src/exec/string_ops.zig:1684`)

- **签名**：`pub fn callReplaceFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, replacer_call: *CallSite, match: ReplaceMatch, string_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：函数替换：按 `(matched, ...captures, position, string[, groups])` 调 replacer 并把结果 ToString。
- **实现**：参数个数按捕获数 + 位置 + 源串（groups 非 undefined 时再加一位）分配数组，填好后经 `replacer_call.call` 调用，返回值走 `toStringForAnnexB`。
- **所有权 / 错误 / 调用**：`args` 是 `rt.memory.alloc` 的临时数组，defer free；元素全是借用（`match` 的字段与 `string_value`），保活靠调用方的 `ReplaceMatchRoots`。返回值是用户替换函数的结果经 `toStringForAnnexB` 后的串（可能就是它原样返回的那个串），归调用方。唯一调用方 `regExpSymbolReplaceGeneric:1429`。

### `getSubstitutionString` (`src/exec/string_ops.zig:1707`)

- **签名**：`pub fn getSubstitutionString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, match: ReplaceMatch, string_value: core.JSValue, replacement_string: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：模板替换：在一次命中上展开 `$$` / `$&` / `` $` `` / `$'` / `$n` / `$<name>`。
- **实现**：`groups` 为 undefined 时命名捕获取 undefined，为 null 直接 `error.TypeError`，是对象则原样用，其余原始值经 `primitiveObjectForAccess` 包装。随后把源串、命中串、模板串都展成 u16 缓冲，扫描模板：`$$` 出 `$`，`$&` 出命中串，`` $` `` 出 `[0, index)` 前缀，`$'` 出命中后的后缀，`$0`-`$9` 经 `replacementCaptureUnits` 解析捕获（解析失败原样输出 `$`，捕获是 undefined 则不输出），`$<` 交 `appendNamedCaptureSubstitution`，其余情况输出字面 `$`；末尾 `String.createUtf16`。
- **所有权 / 错误 / 调用**：四个 u16 ArrayList 全部 defer deinit，返回新建 UTF-16 串。`match.groups` 是原始值时经 `primitiveObjectForAccess` 新建包装对象；为 null → 裸 `error.TypeError`。`$<name>` 分支经 `appendNamedCaptureSubstitution` 读 groups 属性，可能跑用户 getter。唯一调用方 `regExpSymbolReplaceGeneric:1435`。

### `replacementCaptureUnits` (`src/exec/string_ops.zig:1780`)

- **签名**：`pub fn replacementCaptureUnits(match: ReplaceMatch, replacement: []const u16, index: *usize) ?core.JSValue`。
- **作用**：解析模板里的 `$n` / `$nn` 捕获引用，返回对应捕获值。
- **实现**：`$` 后首位必须是数字。首位是 `0` 时只接受 `$0n` 形态（第二位数字且编号在捕获范围内），否则返回 `null`。首位非 0 时先取一位编号，若下一位也是数字且两位数仍落在捕获范围内就改用两位；编号为 0 或超出捕获个数返回 `null`。命中时把调用方的 `index` 推进已消费的位数，并返回 `match.captures[编号 - 1]`。
- **所有权 / 错误 / 调用**：返回的是 `match.captures` 里的**借用**值（不新建、不加引用），并就地推进调用方的 `index`；不是合法引用时返回 `null` 且不动 `index`。不分配无 error。唯一调用方 `getSubstitutionString:1764`。

### `parseSlotCaptureRefData` (`src/exec/string_ops.zig:1810`)

- **签名**：`fn parseSlotCaptureRefData(rep_data: core.string.String.ResolvedData, index: usize, capture_count: usize) ?SlotCaptureRef`。
- **作用**：`regExpReplaceFast` 用的 `$n` 解析：在已解析的模板切片上算出捕获槽引用。
- **实现**：`capture_count` 含第 0 组，所以合法组号是 `1..capture_count - 1`，`capture_count` 为 0 或 1 直接返回 `null`。解析规则与 `replacementCaptureUnits` 相同（`$0n` 特例、两位数仅在落入合法范围时才吃第二位），返回 `{ group, consumed }` 而不是物化的 JSValue。
- **所有权 / 错误 / 调用**：无：只解析借用视图里的数字，返回组号与消耗的位数，不分配、不产生 JSValue。唯一调用方 `appendRegExpSubstitutionFromSlots:1886`。

### `appendRegExpSubstitutionFromSlots` (`src/exec/string_ops.zig:1851`)

- **签名**：`fn appendRegExpSubstitutionFromSlots( b: *StringBuffer, sp_data: core.string.String.ResolvedData, match_start: usize, match_end: usize, capture: []const usize, capture_count: usize, rep_data: core.string.String.ResolvedData, ) !void`。
- **作用**：快路径版 GetSubstitution：直接用 matcher 的捕获槽展开模板。
- **实现**：扫描模板里的 `$`：`$$` 输出 `$`，`$&` 输出命中区间，`` $` `` 输出前缀，`$'` 输出后缀，`$n` 经 `parseSlotCaptureRefData` 解析后用 `regexp_adapter.captureSlotValue` 取槽区间（未参与匹配的槽输出空），其余原样拷贝；结束后补上模板剩余部分。QuickJS 坐标：quickjs.c:45888。
- **所有权 / 错误 / 调用**：只往调用方的 `StringBuffer` 追加，写进去的全是 `sp_data` / `rep_data` 借用视图的切片——不为任何捕获组新建串，这正是 fast path 省掉通用驱动全部分配的地方。唯一 error 是缓冲扩容。唯一调用方 `regExpReplaceFast:1529`。

### `stringLengthIndex` (`src/exec/string_ops.zig:1901`)

- **签名**：`pub fn stringLengthIndex(rt: *core.JSRuntime, string_value: core.JSValue) !usize`。
- **作用**：取字符串值的码元长度。
- **实现**：非字符串体返回 0，否则 `string_object.len()`；`rt` 参数未使用。
- **所有权 / 错误 / 调用**：无：读借用字符串体的长度（非字符串体返回 0），`rt` 参数未使用、签名里的 error set 实际不产生错误。调用方：`regExpSymbolReplaceGeneric:1412`/`:1423`、`captureReplaceMatch:1640`。

### `isEmptyStringValue` (`src/exec/string_ops.zig:1907`)

- **签名**：`pub fn isEmptyStringValue(rt: *core.JSRuntime, value: core.JSValue) bool`。
- **作用**：判断是否空串（对齐 qjs `JS_IsEmptyString`）。
- **实现**：已是字符串体时直接读长度；只有非字符串调用方才落到 `appendRawString` 临时缓冲（@@match 每次全局命中都会调它，所以常见路径不分配），转换失败按非空处理。
- **所有权 / 错误 / 调用**：无：字符串体直接读长度；非字符串腿的临时缓冲 defer deinit，且转换失败被 `catch return false` 吞掉（不外传 error、不挂异常）。调用方：`regExpSymbolMatchGeneric:1264`、`regExpSymbolReplaceGeneric:1404`、`regExpStringIteratorNext:3220`。

### `advanceStringIndexNumber` (`src/exec/string_ops.zig:1919`)

- **签名**：`pub fn advanceStringIndexNumber( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, string_value: core.JSValue, index_value: core.JSValue, unicode: bool, ) !core.JSValue`。
- **作用**：AdvanceStringIndex 的数值版：在 `lastIndex` 数值上推进。
- **实现**：下标先经 `toLengthNumber`；非 unicode 模式或数值大到 `usize` 放不下时直接 `+1`；否则接收者必须是字符串且下一个码元存在，当前码元是高代理且后继是低代理才 `+2`，其余 `+1`。
- **所有权 / 错误 / 调用**：返回数值立即数（`value_ops.numberToValue`，int32 或 double），不分配不建根；`toLengthNumber` 可能跑用户 ToNumber。调用方：`regExpSymbolMatchGeneric:1269`、`regExpSymbolReplaceGeneric:1406`、`regExpStringIteratorNext:3222`。

### `replaceRegExpLegacySlot` (`src/exec/string_ops.zig:1941`)

- **签名**：`pub fn replaceRegExpLegacySlot(rt: *core.JSRuntime, owner: *core.Object, slot: *?core.JSValue, value: core.JSValue) !void`。
- **作用**：更新 realm 的 RegExp legacy 静态槽（`RegExp.$1` 这类）。
- **实现**：新旧值 `same` 时直接返回；否则走 `owner.setRealmRegExpLegacySlot`——不能用 `setOptionalValueSlot`，因为那会把 receiver 记成 global，而槽实际在 realm 的 `regexp_legacy_statics` 里。
- **所有权 / 错误 / 调用**：写 realm 的 `regexp_legacy_statics` 槽：值相同就不写。**必须**用 `setRealmRegExpLegacySlot` 而不是 `setOptionalValueSlot`——后者会把 receiver 记成 global，而槽实际属于 realm（屏障由前者负责）。调用方 15 处：`updateRegExpLegacyStaticsForMatchValues`（`string_ops.zig:2570`-`:2598` 6 处）、`updateRegExpLegacyStaticsLazyForMatch`（`:2651`-`:2668` 3 处），以及 `regexp_fastpath.zig` 的 `regExpLegacyAccessor:576` 与 `materializeRegExpLegacyNoCaptureSlots:620`-`:642`（5 处）。

### `stringAtomId` (`src/exec/string_ops.zig:1952`)

- **签名**：`pub fn stringAtomId(value: core.JSValue) ?core.Atom`。
- **作用**：取字符串值已 intern 的 atom id，没有则 `null`。
- **实现**：非字符串体返回 `null`；`atom_id` 等于 `String.no_atom_id` 时也返回 `null`。
- **所有权 / 错误 / 调用**：无：读借用字符串体上已 intern 的 atom id，没有就返回 `null`；不分配、不 intern、不加引用。唯一调用方 `vm_property_field.zig:885`。

### `callStringBody` (`src/exec/string_ops.zig:1966`)

- **签名**：`pub fn callStringBody( ctx: *core.JSContext, string_value: core.JSValue, decoded_method_id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把复用的 String 方法体经记录表的「无 func 对象」臂调回去。
- **实现**：`decoded_method_id` 经 `encodePrototypeMethodId` 重新编码成 `PrototypeMethod` 记录 id（编不出则 TypeError），再用 `builtin_dispatch.callInternalRecord` 以 `.string` 域派发，落到 `string_builtin_ops.stringCall` 的 `func_obj == null` 臂上跑纯 `methodCall` 体；记录返回 null 时报 TypeError。
- **所有权 / 错误 / 调用**：把已解析的接收者与已强制转换过的参数经 `builtin_dispatch.callInternalRecord` 送进 `.string` 记录的 `func_obj == null and global == null` 腿（落点是 `string_builtin_ops.stringCall` → `methodCall` / `charAtValue`），返回值归调用方。id 编码失败或记录缺失 → 裸 `error.TypeError`；被调方的 `error.RangeError` / `error.InvalidLength` 原样穿过这里，消息由 `stringPrototypeMethod:2054` / `stringNumericArgsMethod:3839` 的 catch 补。调用方：`callStringCharAtBody:1984`、`stringPrototypeMethod:2054`、`stringSearchPositionMethod:2116` 等 6 处。

### `callStringCharAtBody` (`src/exec/string_ops.zig:1979`)

- **签名**：`pub fn callStringCharAtBody( ctx: *core.JSContext, string_value: core.JSValue, index_value: core.JSValue, ) !core.JSValue`。
- **作用**：`String.prototype.charAt`（解码 id 0，即 `charAtValue` 体）的记录表入口。
- **实现**：以 `decoded_method_id = 0`、`args = &.{index_value}` 转 `callStringBody`。
- **所有权 / 错误 / 调用**：薄包装（decoded id 0，单个索引作 `args[0]`），所有权与错误同 `callStringBody`。调用方：`stringNumericArgsMethod:3834`、`call_runtime.zig:1393`。

## 覆盖核对

- 清单函数数（本文件分到）: 69（`src/exec/string_ops.zig` 全文件 159）
- 本文标题覆盖: 69
- 未覆盖: 无
