# 15 — `string_ops.zig`：prototype 分发、Array concat/search、pad/html

从 `stringPrototypeMethod` 到文件末尾。`arraySearchCall` / `arrayConcatCall` 因历史别名墙住在本文件，但语义属于 Array；`isConcatSpreadable` 决定 concat 展开还是当单元素。空洞在展开时同样靠 HasProperty。

### `stringPrototypeMethod` (`src/exec/string_ops.zig:1979`)

- **签名**：`pub fn stringPrototypeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：RegExp 耦合方法（split/search/match/replace*）自己检查 nullish（「cannot convert to object」）；其余先 `toStringCheckObject`「null or undefined are forbidden」。
- **实现**：RegExp 耦合方法（split / search / match / replace / replaceAll / matchAll）先于粗粒度检查被分派出去，因为它们自己的 nullish 检查抛的是「cannot convert to object」（quickjs.c:45846/46021/46133）。之后统一判 nullish 抛「null or undefined are forbidden」。再按 method_id 分派：10 → `stringConcat`；34/35 → `stringPad`；11-20/23/24/26 → `stringHtmlMethod`；normalize → `stringNormalize`；36 → `stringLocaleCompare`；4/5/6/7/28 → `stringSearchPositionMethod`；0/1/25/29-33 → `stringNumericArgsMethod`。其余 id 先 ToString 再经 `callStringBody` 落回记录表，并把 `error.RangeError` / `error.InvalidLength` 翻成「invalid repeat count」/「invalid string length」的 RangeError。
- **所有权 / 错误 / 调用**：自身只做分发，不分配、不建根；返回值所有权取决于选中的实现（多数是新建串，`stringPad` / `stringNumericArgsMethod` 的若干腿会原样交回接收者串）。错误分两类：RegExp 耦合的六个 id 由各自实现挂 "cannot convert to object"，其余先统一挂 "null or undefined are forbidden"；尾部 `callStringBody` 的 `error.RangeError` / `error.InvalidLength` 在这里被补成带消息的 RangeError（"invalid repeat count" / "invalid string length"）而不外传——少了这层，`InvalidLength` 不在 `runtimeErrorInfo` 表里，会退化成 `Error: InvalidLength`。调用方：`string_builtin_ops.zig:711`（`stringCall` 的 realm 腿）、`call_runtime.zig:1402`、`:1416`。

### `appendUtf32FromStringValue` (`src/exec/string_ops.zig:2052`)

- **签名**：`pub fn appendUtf32FromStringValue(rt: *core.JSRuntime, out: *std.ArrayList(u32), value: core.JSValue) !void`。
- **作用**：将值的 UTF-16 码元序列追加为 UTF-32 单元。
- **实现**：先用临时 u16 数组取得码元，再合并有效的高低代理对；未配对代理项保留原数值。
- **所有权 / 错误 / 调用**：临时 `units` 数组由 defer 用 `rt.memory.allocator` 释放；out 由调用方持有和清理。唯一错误是取码元与扩容的 `OutOfMemory`，不返回 JSValue。调用方：`stringNormalize:3746`、`normalizedUtf32:3795`。

### `appendUtf16CodePoint` (`src/exec/string_ops.zig:2069`)

- **签名**：`pub fn appendUtf16CodePoint(rt: *core.JSRuntime, out: *std.ArrayList(u16), code_point: u32) !void`。
- **作用**：把一个码点按 UTF-16 编码（BMP 一个码元、增补面拆成代理对）追加到 u16 缓冲。
- **实现**：薄封装，`@intCast` 成 u21 后转发到 `unicode_lib.appendUtf16CodePoint`。
- **所有权 / 错误 / 调用**：无自身所有权：把 `rt.memory.allocator` 交给 `unicode_lib.appendUtf16CodePoint`，往调用方的 `out` 追加，唯一错误是扩容 `OutOfMemory`。调用方：`stringFromCodePoint:763`、`stringNormalize:3752`（`string_builtin_ops.zig:1636` 有同名的另一个 helper）。

### `stringSearchPositionMethod` (`src/exec/string_ops.zig:2072`)

- **签名**：`pub fn stringSearchPositionMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`indexOf` / `includes` / `startsWith` / `endsWith` / `lastIndexOf` 的 realm 侧入口：做完 this 与参数强制后交记录表。
- **实现**：nullish 接收者返回 `error.TypeError`，随后接收者 ToString。includes / startsWith / endsWith（id 5/6/7）遇到可观察的 RegExp 搜索参数抛 TypeError「regexp not supported」（qjs `js_string_includes`，quickjs.c:45757）。搜索参数 ToString；位置参数为 undefined 时保持 undefined，否则经 ToPrimitive（BigInt 返回 `error.TypeError`）+ ToNumber 规范；最后 `callStringBody` 带 1-2 个已强制的参数调用码元级实现。
- **所有权 / 错误 / 调用**：自己不建串：接收者与 search 参数经 `toStringForAnnexB`（字符串入参是借用返回），位置参数经 `toPrimitiveForNumber` + ToNumber 规整进栈上 `coerced`，再交给 `callStringBody`，返回值归调用方。错误：nullish 接收者是裸 `error.TypeError`（这条腿没补消息）；includes/startsWith/endsWith 收到正则 → 带消息 "regexp not supported"；BigInt 位置参数 → 裸 `error.TypeError`。唯一调用方 `stringPrototypeMethod:2048`（id 4/5/6/7/28）。

### `isRegExpForStringSearch` (`src/exec/string_ops.zig:2111`)

- **签名**：`pub fn isRegExpForStringSearch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：判断搜索参数是否是「可观察意义上的」RegExp（`Symbol.match` 可被改写）。
- **实现**：直接转 `isRegExpObservable`（`regexp_fastpath.zig`）。
- **所有权 / 错误 / 调用**：纯转发 `regexp_fastpath.isRegExpObservable`（它会读 `Symbol.match`，可能跑用户 getter 并抛），自身不分配无状态。唯一调用方 `stringSearchPositionMethod:2097`。

### `stringReplaceAll` (`src/exec/string_ops.zig:2122`)

- **签名**：`pub fn stringReplaceAll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.replaceAll` 的薄包装。
- **实现**：以 `is_replace_all = true` 转 `stringReplaceCore`。
- **所有权 / 错误 / 调用**：薄包装，所有权与错误全在 `stringReplaceCore`（`is_replace_all = true`）。唯一调用方 `stringPrototypeMethod:2016`。

### `stringSearch` (`src/exec/string_ops.zig:2134`)

- **签名**：`pub fn stringSearch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.search`：优先委托参数的 `Symbol.search`，否则用参数造一个 RegExp 再调它的 @@search。
- **实现**：nullish 接收者抛 TypeError「cannot convert to object」（qjs `js_string_match`，quickjs.c:45846）；接收者先 ToString，再试 `callStringWellKnownMethod(…, "Symbol.search")`，没命中就转 `stringRegExpCreateAndInvoke`。
- **所有权 / 错误 / 调用**：返回用户 @@search（或新建正则的 @@search）的结果，归调用方；本函数只把接收者 ToString。nullish 接收者 → 带消息 "cannot convert to object"。唯一调用方 `stringPrototypeMethod:2007`。

### `stringIteratorCall` (`src/exec/string_ops.zig:2151`)

- **签名**：`pub fn stringIteratorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype[Symbol.iterator]`：造一个 String Iterator 对象。
- **实现**：nullish 接收者返回 `error.TypeError`；接收者 ToString 后取（或惰性建出）String Iterator 原型，创建 `class.ids.string_iterator` 对象，把字符串写进 target 槽、下标清零；分配后到返回前用 `errdefer destroyFromHeader` 兜底。
- **所有权 / 错误 / 调用**：新建 string_iterator 对象，`string_value`（可能就是借用的接收者本身）经 `setOptionalValueSlot` 写进 target 槽后由迭代器持有；写槽失败时 `errdefer` 显式 `destroyFromHeader` 销毁它。nullish 接收者 → 裸 `error.TypeError`。唯一调用方 `call_runtime.zig:1399`。

### `stringIteratorPrototypeFromContext` (`src/exec/string_ops.zig:2169`)

- **签名**：`pub fn stringIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object`。
- **作用**：取当前 realm 的 %StringIteratorPrototype%，没有就建一个并缓存进 `ctx.class_prototypes`。
- **实现**：槽里已有对象就直接返回。否则 `iteratorPrototype(rt, global, "String Iterator")` 造原型并定义 `next`（带 `(.string, iterator_next)` 原生 id），`@@iterator` 靠继承 %IteratorPrototype% 而不自备一份；随后裸写 `class_prototypes` 槽并手动 `gc.generationalBarrier`（不走 `setClassPrototype`，与 Array 迭代器原型同一处理）。
- **所有权 / 错误 / 调用**：命中 `ctx.class_prototypes` 时返回**借用**的缓存 prototype；miss 才新建，装好 `next` 后写回槽位——用的是裸槽写 + 手动 `gc.generationalBarrier`（不是 `setClassPrototype`），与 Array 迭代器 prototype 同一处理。失败时 `errdefer` 销毁新建的 proto。缓存槽里存的不是对象（例如仍是 undefined）时不报错，直接落到新建腿；只有 `isObject()` 成立却 `expectObject` 取不出指针才裸 `error.TypeError`。唯一调用方 `stringIteratorCall:2169`。

### `stringMatch` (`src/exec/string_ops.zig:2193`)

- **签名**：`pub fn stringMatch( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.match`：优先委托参数的 `Symbol.match`，否则用参数造一个 RegExp 再调它的 @@match。
- **实现**：nullish 接收者抛 TypeError「cannot convert to object」（qjs `js_string_match`，quickjs.c:45846）。与 `search` 不同，这里先用**原始接收者**查 @@match（qjs 也是查完才做 ToString）；没命中才 ToString 并转 `stringRegExpCreateAndInvoke`。
- **所有权 / 错误 / 调用**：先用**原始接收者**查 @@match（qjs 的顺序是查找在 ToString 之前），命中就返回用户方法的结果；否则 ToString 后交给 `stringRegExpCreateAndInvoke`。nullish 接收者 → 带消息 "cannot convert to object"。唯一调用方 `stringPrototypeMethod:2010`。

### `stringRegExpCreateAndInvoke` (`src/exec/string_ops.zig:2212`)

- **签名**：`pub fn stringRegExpCreateAndInvoke( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, string_value: core.JSValue, regexp: core.JSValue, symbol_name: []const u8, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`match` / `search` 的回退：按 RegExpCreate 语义造一个 RegExp，再调它的 @@match / @@search。
- **实现**：构造器优先取 realm 缓存的 `%RegExp%`，最小 embedder 才回退到全局属性查找。非 RegExp 的对象 pattern 先 ToString（这一步保证不重复触发 IsRegExp 与 Get @@match，kangax 的 Proxy.get.String.match/search 要求恰好是 [@@match|@@search, @@toPrimitive]）。随后 `regExpConstructCall` 建 rx，再 `callStringWellKnownMethod` 调对应符号方法；新建的 rx 上没有可调用的 @@match/@@search 时返回 `error.TypeError`（对应 qjs 的 `JS_InvokeFree`，quickjs.c:45881），没有静默回退到内建匹配。
- **所有权 / 错误 / 调用**：`constructor` 优先取 realm 缓存的 %RegExp%（借用），否则现从 global 读属性；非正则的对象 pattern 先 ToString 成 `owned_pattern` 再交给 `regExpConstructCall`，新建的 rx 只在本函数内用作接收者。新 rx 没有可调用的 @@match/@@search → 裸 `error.TypeError`（对应 qjs `JS_InvokeFree` 的尾部，没有静默回退到内建匹配）。调用方：`stringSearch:2156`、`stringMatch:2217`。

### `callStringWellKnownMethod` (`src/exec/string_ops.zig:2250`)

- **签名**：`pub fn callStringWellKnownMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, candidate: core.JSValue, symbol_name: []const u8, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：取候选对象上的某个 well-known 符号方法并以字符串为参数调用它；不适用时返回 `null`。
- **实现**：候选为 nullish 或非对象返回 `null`；取符号属性，为 undefined/null 返回 `null`；存在但不可调用返回 `error.TypeError`；否则以候选为 this、`[this_value]` 为参数走 `callValueOrBytecodeRoot`。
- **所有权 / 错误 / 调用**：命中就返回用户方法的结果（归调用方），候选不是对象或没有该方法时返回 `null` 让调用方继续；本函数不分配、不建根，`method_args` 是栈上数组。方法存在但不可调用 → 裸 `error.TypeError`。调用方：`stringSearch:2155`、`stringMatch:2215`、`stringRegExpCreateAndInvoke:2250`。

### `stringSplit` (`src/exec/string_ops.zig:2270`)

- **签名**：`pub fn stringSplit( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.split`：优先委托分隔符的 `Symbol.split`，否则走字符串分割。
- **实现**：nullish 接收者抛 TypeError「cannot convert to object」（qjs `js_string_split`，quickjs.c:46133）。分隔符是对象时取 `Symbol.split`，非 nullish 则必须可调用（否则 TypeError）并以 `(this, limit)` 调用；参数数组刻意不登记根，因为 `callValueOrBytecodeRoot` 在任何分配点之前就把参数 `@memcpy` 进自己的 `inline_args`（源码注释记录了这一 TGC R1-c 判断）。否则接收者 ToString：无参数直接空参调用内建 split；有参数时 limit 经 ToPrimitive（BigInt → TypeError）+ ToUint32 规范，分隔符 undefined 保持 undefined、否则 ToString（@@split 落空后即便是 RegExp 也走字符串路径，quickjs.c:46139-46165），最后交 `stringSplitBuiltinArray`。
- **所有权 / 错误 / 调用**：@@split 腿直接返回用户方法的结果；其余把接收者/分隔符 ToString（字符串入参是借用返回）、limit 规整成 u32 数值后交给 `stringSplitBuiltinArray`。源码注释交代 `split_args` **故意不建根**：`callValueOrBytecodeRoot` 在第一个回收点之前就 `@memcpy` 进自己的 `inline_args`。错误：nullish 接收者 → 带消息 "cannot convert to object"；@@split 不可调用、BigInt limit → 裸 `error.TypeError`。唯一调用方 `stringPrototypeMethod:2004`。

### `stringSplitBuiltinArray` (`src/exec/string_ops.zig:2332`)

- **签名**：`pub fn stringSplitBuiltinArray( ctx: *core.JSContext, global: *core.Object, string_value: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：调内建 split 体并把结果数组接回当前 realm 的 `Array.prototype`。
- **实现**：`callStringBody(..., legacy_split_method_id, args)` 拿到数组；结果是原型为 null 的数组时，把它的原型设成 realm 的 `Array.prototype`（内建体建数组时没有 realm 信息）。
- **所有权 / 错误 / 调用**：返回 `callStringBody` 建出的数组（归调用方），并在它还没有原型时补挂 realm 的 `Array.prototype`——builtins 侧的 `split` / `splitReceiver` 建数组时传的是 `null` 原型。调用方：`stringSplit:2311`、`:2337`。

### `RegExpMatch.captureAt` (`src/exec/string_ops.zig:2362`)

- **签名**：`pub inline fn captureAt(self: *const RegExpMatch, capture_index: usize) RegExpCapture`。
- **作用**：读第 `capture_index` 个捕获（从第 1 组算起）的起点与长度。
- **实现**：断言下标在 `capture_count` 内；取 `capture_slots[2*i]`，槽为空（未参与匹配）时返回 `{ .start = 0, .len = 0, .undefined = true }`，否则用结束槽（缺省等于起点）算出长度。
- **所有权 / 错误 / 调用**：无所有权：把借用的 `capture_slots`（匹配器复用的槽缓冲）解释成 `RegExpCapture` 的下标/长度，不分配、不建串；`capture_index < capture_count` 由 `debug.assert` 挡。调用方：`initRegExpMatchArrayDenseElementsFromValue:2540`、`updateRegExpLegacyStaticsForMatch:2616`、`object_ops.zig:1201` 等 6 处。

### `RegExpMatch.captureNameAt` (`src/exec/string_ops.zig:2373`)

- **签名**：`pub inline fn captureNameAt(self: *const RegExpMatch, capture_index: usize) ?[]const u8`。
- **作用**：取第 `capture_index` 个捕获的组名（无命名捕获时 `null`）。
- **实现**：断言下标在 `capture_count` 内；`has_named_captures` 为假返回 `null`，否则从字节码里取 `groupName(capture_bytecode, capture_index + 1)`。
- **所有权 / 错误 / 调用**：无：返回借用自编译字节码的组名切片（随 `capture_bytecode` 有效，不拷贝），没有命名组时 `null`。调用方：`object_ops.zig:1200`、`:1241`。

### `encodeRegExpLegacyCaptureSlice` (`src/exec/string_ops.zig:2391`)

- **签名**：`pub fn encodeRegExpLegacyCaptureSlice(start: usize, len: usize) ?core.JSValue`。
- **作用**：把 legacy 捕获的 `(start, len)` 打包进一个立即数 payload，避免马上切出字符串。
- **实现**：`len` 占低 20 位、`start` 占其上（各自有 `1 << 20` / `1 << 27` 的上限），超限返回 `null` 让调用方退回物化字符串；否则打成 `JSValue.shortBigInt` 的 payload。
- **所有权 / 错误 / 调用**：无分配：把 (start, len) 打包成 short BigInt **立即值**（不是堆 BigInt，所以写进 realm 槽不引入新的 GC 边），越界返回 `null` 让调用方放弃惰性编码。唯一调用方 `updateRegExpLegacyStaticsLazyForMatch:2640`。

### `decodeRegExpLegacyCaptureSlice` (`src/exec/string_ops.zig:2397`)

- **签名**：`pub fn decodeRegExpLegacyCaptureSlice(value: core.JSValue) ?LazyRegExpLegacyCapture`。
- **作用**：把 `encodeRegExpLegacyCaptureSlice` 的 payload 解回 `{start, len}`。
- **实现**：取 `asShortBigInt`，为负或超过 `1 << 47` 的 payload 上限返回 `null`；否则按 20 位掩码拆出 `len`、右移拆出 `start`。
- **所有权 / 错误 / 调用**：无：立即值解包，不是 short BigInt 或越界返回 `null`。唯一调用方 `regexp_fastpath.zig:652`（惰性 Annex-B 静态量的读取侧）。

### `defineSplitSliceElement` (`src/exec/string_ops.zig:2407`)

- **签名**：`pub fn defineSplitSliceElement(rt: *core.JSRuntime, object: *core.Object, index: u32, input: core.JSValue, start: usize, len: usize) !void`。
- **作用**：把输入串的一段作为数组元素定义进结果数组。
- **实现**：`stringSliceValue` 切出子串后交 `defineSplitValueElementOwned`（子串的引用随之转移）。
- **所有权 / 错误 / 调用**：`stringSliceValue` 新建（或共享表返回）的切片串随即由 `defineSplitValueElementOwned` 交给数组持有，本函数不保留引用。调用方：`regExpSymbolSplitGeneric:1163`、`:1184`。

### `defineSplitValueElement` (`src/exec/string_ops.zig:2412`)

- **签名**：`pub fn defineSplitValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：把一个借用的值定义成数组的第 index 个元素。
- **实现**：先试 `appendDenseArrayDefineIndex` 走 dense 追加，不成才 `defineOwnProperty` 以 `Descriptor.data(value, true, true, true)` 定义。
- **所有权 / 错误 / 调用**：把调用方给的值定义成下标属性，dense 快路径不适用才落 `defineOwnProperty`；值随后由数组持有。注意它与下面的 `Owned` 变体在当前实现里落到同一个 `Object.appendDenseArrayDefineIndex`（原来的 `...Mode` 中转层与它的 `comptime take_ownership` 参数已删，`appendDenseArrayDefineIndexOwned` 现在只是同名别名）。调用方：`regExpSymbolSplitGeneric:1140`、`regexp_fastpath.zig:852`/`:853`、`array_ops.zig:405` 等 6 处。

### `defineSplitValueElementOwned` (`src/exec/string_ops.zig:2418`)

- **签名**：`pub fn defineSplitValueElementOwned(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：同 `defineSplitValueElement`，但接手调用方对 `value` 的引用。
- **实现**：先 `try appendDenseArrayDefineIndexOwned`（消费引用），未追加成功则 `defineOwnProperty` 以可写/可枚举/可配置的数据描述符定义。
- **所有权 / 错误 / 调用**：契约上消费调用方交来的值：成功后由数组持有，返回 false 或 error 时所有权留在调用方（`Object.appendDenseArrayDefineIndexOwned` 的注释写明了这条），实现与非 Owned 变体共用同一个 mode 函数。调用方：`regExpSymbolSplitGeneric:1176`、`regExpSymbolMatchGeneric:1265`、`defineSplitSliceElement:2425`。

### `initRegExpResultPropertyTemplate` (`src/exec/string_ops.zig:2427`)

- **签名**：`pub noinline fn initRegExpResultPropertyTemplate(rt: *core.JSRuntime, global: *core.Object) !*core.Shape`。
- **作用**：保证当前 realm 的 `regexp_result_shape` 已发布：标准 bootstrap 一次造齐五件初始 Shape，本函数是最小 embedder 的回退。
- **实现**：`contextForGlobal` 失败 → TypeError。已有 `ctx.regexp_result_shape` 直接返回。否则 `ctx.initializeInitialShapes`（Object / Array / RegExp 原型），再取 `regexp_result_shape`，仍空则 TypeError。只发布 Shape 所有者到 realm，不在这里造匹配数组。
- **所有权 / 错误 / 调用**：返回的 `*Shape` 由 realm 持有（`ctx.regexp_result_shape`），调用方只借用、不释放；`regExpResultPropertyTemplate` 已经先查过缓存，所以这里是 miss 才走的冷路径。global 没有对应 context 或初始化后仍无 shape → 裸 `error.TypeError`。唯一调用方 `regExpResultPropertyTemplate:2460`。

### `regExpResultPropertyTemplate` (`src/exec/string_ops.zig:2438`)

- **签名**：`fn regExpResultPropertyTemplate(rt: *core.JSRuntime, global: *core.Object) !*core.Shape`。
- **作用**：取当前 realm 已发布的 `regexp_result_shape`，缺失时落到 `initRegExpResultPropertyTemplate` 兜底。
- **实现**：薄封装，主体转发到 `rt.contextForGlobal`、`initRegExpResultPropertyTemplate`。
- **所有权 / 错误 / 调用**：无自身所有权：先读 realm 缓存（借用），miss 才落 `initRegExpResultPropertyTemplate`。唯一调用方 `createRegExpMatchArrayFromValue:2471`。

### `createRegExpMatchArrayFromValue` (`src/exec/string_ops.zig:2445`)

- **签名**：`pub noinline fn createRegExpMatchArrayFromValue( rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize, has_indices: bool, ) !core.JSValue`。
- **作用**：从一次 `RegExpMatch` 造 exec 结果数组：走 `regexp_result_shape` 模板，填 dense 捕获、更新 legacy 静态槽，可选挂 `indices`。
- **实现**：`regExpResultPropertyTemplate` 取 Shape。有 named captures 则先造空 groups 对象。`createRegExpMatchArrayFromShape` 写入 `index` / `input` / `groups`。`errdefer destroyFromHeader`。`initRegExpMatchArrayDenseElementsFromValue` 填 `[0]` 整次匹配与各捕获（未参与为 `undefined`），并把具名捕获写进 groups。`updateRegExpLegacyStaticsForMatch` 更新 `$1`…。`has_indices` 时 `createRegExpIndicesArray` 再 `defineFreshNonIndexDataProperty(..., "indices")`。
- **所有权 / 错误 / 调用**：返回的匹配数组归调用方；`input_value` 只借用（被模板写进 `input` 槽），`groups` 对象与 `indices` 数组建好即由结果数组持有，失败路径 `errdefer` 销毁刚建的数组。`updateRegExpLegacyStaticsForMatch` 顺带更新 realm 的 Annex-B 静态量。唯一调用方 `regexp_fastpath.zig:806`。

### `initRegExpMatchArrayDenseElementsFromValue` (`src/exec/string_ops.zig:2474`)

- **签名**：`pub fn initRegExpMatchArrayDenseElementsFromValue( rt: *core.JSRuntime, out: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, groups: ?*core.Object, ) !void`。
- **作用**：把整次匹配与各捕获写进匹配数组的 dense 元素区，并填好 named groups。
- **实现**：先断言 `out` 是刚建出的空数组（长度 / 元素 / 容量都为 0）。按 `capture_count + 1` 建一块 `.array_storage` cell 并整体 `@memset` 成 undefined，然后用 `ValueRootFrame` 同时以 `.headers` 钉住 cell 本身、以 `.slices` 钉住其中的槽——每次 `stringSliceValue` 都是一次分配边界，这个容器帧取代了「新建即安装」的相邻性要求。`cell[0]` 写整次匹配的子串，其余槽按捕获逐个写（未参与匹配的保持 undefined），每次写入都配 `gc.generationalBarrierValue`（老 cell 指向新串正是分代屏障要处理的边）。有 `groups` 对象时经 `populateRegExpGroupsFromCaptureValues` 同步具名捕获，最后 `adoptDenseArrayElementsAssumingEmpty` 把 cell 交给数组并置 `may_have_indexed_properties`。
- **所有权 / 错误 / 调用**：数组直接持有写进去的子串（不额外 dup 再由调用方释放）；`input_value` 借用。GC：裸 `.array_storage` cell 先 `@memset` 成 undefined，再由 `ValueRootFrame` 的 `.headers`（cell 自身）+ `.slices`（cell 里的槽）双重登记——每个 `stringSliceValue` 都是建串分配点，这正是取代旧「native 暂存再拷贝」形状的理由；每次写槽都补 `generationalBarrierValue`。唯一调用方 `createRegExpMatchArrayFromValue:2480`。

### `updateRegExpLegacyStaticsForMatchValues` (`src/exec/string_ops.zig:2536`)

- **签名**：`pub fn updateRegExpLegacyStaticsForMatchValues( rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize, matched: core.JSValue, legacy_capture_values: *const [9]?core.JSValue, last_capture_value: ?core.JSValue, ) !void`。
- **作用**：用已物化的匹配值更新 realm 的 RegExp legacy 静态槽（`RegExp.$1`…`$9`、`lastMatch` 等）。
- **实现**：先拿 realm 的 legacy 静态块（没有就 `ensureInstalledRealmRegExpLegacyStatics` 建，仍拿不到则直接返回），记下旧的 `capture_slot_count`，新值取 `min(found.capture_count, legacy.captures.len)`，并清掉 `lazy_no_capture_match` 惰性标志。随后逐槽写：`input` 与 `lastMatch` 直接 `replaceRegExpLegacySlot`；`leftContext` 在 `found.index == 0` 时清空、否则切 `[0, index)`；`rightContext` 以 `min(index + len, input_len)` 为起点，够不到串尾才切、否则清空；`lastParen` 有值就写、没值但旧槽非空就清。最后从 0 扫到新旧槽数的较大者：新范围内有值就写、没值就清，超出新范围的旧槽一律清，扫完把 `capture_slot_count` 更新成新值——这样 `RegExp.$1`…`$9` 不会留下上一次匹配的残值。
- **所有权 / 错误 / 调用**：把调用方建好的串写进 realm 的 Annex-B 静态槽，`replaceRegExpLegacySlot` 负责去重与屏障、槽随后持有它们；多出来的旧槽由 `clearRegExpLegacySlot` 清掉。左右上下文串在本函数内由 `stringSliceValue` 新建。realm 装不出 legacy 结构时直接返回，不算错误。唯一调用方 `updateRegExpLegacyStaticsForMatch:2624`。

### `updateRegExpLegacyStaticsForMatch` (`src/exec/string_ops.zig:2589`)

- **签名**：`pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !void`。
- **作用**：匹配后更新 legacy 静态槽：先试惰性 payload 版，不行才物化捕获字符串。
- **实现**：先调 `updateRegExpLegacyStaticsLazyForMatch`，成功即返回；否则用 `found.captureAt` 逐个切出捕获字符串（循环里直接 `last_capture_value = value`，RC 时代那层多余的中转绑定已删），再交 `updateRegExpLegacyStaticsForMatchValues`。
- **所有权 / 错误 / 调用**：惰性编码成功（`updateRegExpLegacyStaticsLazyForMatch` 返回 true）时一个串都不建；否则为 matched 与每个捕获组 `stringSliceValue` 新建串，再交给 `...ForMatchValues` 写进 realm 槽。这些新串在写入前只被 Zig 栈上的 `legacy_capture_values` 持有（靠保守栈扫描覆盖）。唯一调用方 `createRegExpMatchArrayFromValue:2482`。

### `updateRegExpLegacyStaticsLazyForMatch` (`src/exec/string_ops.zig:2608`)

- **签名**：`pub fn updateRegExpLegacyStaticsLazyForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !bool`。
- **作用**：legacy 静态槽的惰性版：把捕获存成 `(start, len)` payload 而不是字符串。
- **实现**：逐个捕获经 `encodeRegExpLegacyCaptureSlice` 打包，任一超限立即返回 `false`，让调用方改走物化字符串的版本。realm 还没有 legacy 静态块时按需安装，装不出来直接返回 `true`。随后写 `input` 槽；上一轮不是惰性快照时清掉 `last_match` / `left_context` / `right_context`；按最后一个参与匹配的捕获更新 `last_paren`；捕获槽按新旧数量的较大值遍历，超出本次捕获数或未参与的槽清空。最后记下 `capture_slot_count`、`lazy_no_capture_match`、匹配的 index/len 与调用方传入的 `input_len`（不再重复做一次字符串长度分派）。
- **所有权 / 错误 / 调用**：零建串路径：捕获位置经 `encodeRegExpLegacyCaptureSlice` 编成 short BigInt 立即值写进槽，`last_match` / 左右上下文改成惰性（只记 index / len / input_len，由 `regexp_fastpath` 的读取侧现算）。任一捕获超出编码范围就返回 false，让调用方回到建串的老路。唯一调用方 `updateRegExpLegacyStaticsForMatch:2608`。

### `appendUtf8CodePointForRegExpName` (`src/exec/string_ops.zig:2667`)

- **签名**：`pub fn appendUtf8CodePointForRegExpName(rt: *core.JSRuntime, out: *std.ArrayList(u8), cp: u21) !void`。
- **作用**：按 UTF-8 追加一个码点（RegExp 组名拼装用）。
- **实现**：薄封装，主体转发到 `unicode_lib.appendUtf8CodePoint`。
- **所有权 / 错误 / 调用**：无自身所有权：往调用方的 `out` 追加 UTF-8 字节，唯一错误是扩容 `OutOfMemory`。唯一调用方 `regexp_fastpath.zig:875`（经 `:52` 的别名）。

### `isHighSurrogateCodePoint` (`src/exec/string_ops.zig:2671`)

- **签名**：`pub fn isHighSurrogateCodePoint(cp: u21) bool`。
- **作用**：码点是否落在高代理区间。
- **实现**：薄封装，主体转发到 `unicode_lib.isHighSurrogateCodePoint`。
- **所有权 / 错误 / 调用**：无：`unicode_lib` 谓词的 `pub` 再导出，不分配无 error。唯一调用方 `regexp_fastpath.zig:863`（经 `:64` 的别名）。

### `isLowSurrogateCodePoint` (`src/exec/string_ops.zig:2675`)

- **签名**：`pub fn isLowSurrogateCodePoint(cp: u21) bool`。
- **作用**：码点是否落在低代理区间。
- **实现**：薄封装，主体转发到 `unicode_lib.isLowSurrogateCodePoint`。
- **所有权 / 错误 / 调用**：无：`unicode_lib` 谓词的 `pub` 再导出。唯一调用方 `regexp_fastpath.zig:866`（经 `:65` 的别名）。

### `combinedSurrogateCodePoint` (`src/exec/string_ops.zig:2679`)

- **签名**：`pub fn combinedSurrogateCodePoint(high: u16, low: u16) u21`。
- **作用**：把高低代理码元合成一个码点。
- **实现**：薄封装，主体转发到 `unicode_lib.codePointFromSurrogatePair`。
- **所有权 / 错误 / 调用**：无：`unicode_lib.codePointFromSurrogatePair` 的再导出（与本文件 `codePointFromSurrogatePair` 同一实现，只是这个名字有调用方）。调用方：`appendUtf32FromStringValue:2068`、`regexp_fastpath.zig:867`。

### `stringSliceValue` (`src/exec/string_ops.zig:2683`)

- **签名**：`pub fn stringSliceValue(rt: *core.JSRuntime, value: core.JSValue, start: usize, len: usize) !core.JSValue`。
- **作用**：从字符串值切出 `[start, start+len)` 的子串（尽量复用已有对象）。
- **实现**：非字符串体原样返回入参。区间先钳进 `[0, len]`；覆盖整串时返回原值，长度为 0 返回运行时空串；否则：单码元且 `< 0x100` 取 runtime 共享单字节串，其余走 `String.createSlice`——它是 qjs `js_sub_string` 那样的**急切拷贝**（`string.zig:887` 注释写明「没有零拷贝视图，结果不持有父串」）。
- **所有权 / 错误 / 调用**：三种返回形态：整段覆盖时**原样交回** `value`（借用）、空片返回 runtime 共享空串、单个 latin1 码元返回 `rt.singleByteString` 的共享表项，其余才 `String.createSlice` 拷成新串（不共享父串 payload）。调用方：本文件的 split / 匹配数组 / legacy statics 共 7 处，以及 `regexp_fastpath.zig:619` 等。

### `getStringPrototypeMethodId` (`src/exec/string_ops.zig:2698`)

- **签名**：`pub fn getStringPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32`。
- **作用**：从函数对象的 native builtin id 反查它是 `String.prototype` 上的第几号方法（不是 string 域就 `null`）。
- **实现**：解码函数对象的 `nativeFunctionId()`，domain 不是 `.string` 返回 `null`，否则经 `decodePrototypeMethodId` 转成 legacy 方法 id；`rt` 参数未使用。
- **所有权 / 错误 / 调用**：无：读函数对象上的 native builtin id 再解码成 legacy 选择子，`rt` 参数未使用，不分配无 error。调用方：`array_ops.zig:2205`、`call_runtime.zig:1401`。

### `bigIntPrototypeToString` (`src/exec/string_ops.zig:2705`)

- **签名**：`pub fn bigIntPrototypeToString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, primitive: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`BigInt.prototype.toString`：按 radix 格式化 BigInt。
- **实现**：无参数或 undefined 时 radix 取 10；否则 radix 经 ToPrimitive（BigInt / Symbol → TypeError）+ ToNumber，NaN / 非有限 / 不在 2-36 → RangeError。随后克隆 BigInt 值，用 `formatBaseAlloc` 按进制格式化成字节再建串。
- **所有权 / 错误 / 调用**：克隆出的 BigInt 与 `formatBaseAlloc` 的文本缓冲都在返回前释放，返回新建串归调用方；`caller_function` / `caller_frame` 未使用。错误：radix 是 BigInt/Symbol → 裸 `error.TypeError`，NaN/非有限/不在 2-36 → 裸 `error.RangeError`（消息由上层补）。唯一调用方 `object_ops.zig:1310`。

### `standardStringMethodId` (`src/exec/string_ops.zig:2764`)

- **签名**：`pub fn standardStringMethodId(name: []const u8) ?u32`。
- **作用**：按方法名查标准 `String.prototype` 方法表里的 magic id。
- **实现**：在 comptime 的 `standard_string_method_ids` 名字表上做 `name_id.lookup`（`toLocaleUpperCase` / `toLocaleLowerCase` 与非 locale 版共用 id）。
- **所有权 / 错误 / 调用**：无：comptime 名表查找，不分配无 error。调用方：`call_runtime.zig:1408`（按名字分发 String.prototype 方法）与本文件锁定 id 的测试。

### `isStringMethodReceiver` (`src/exec/string_ops.zig:2768`)

- **签名**：`pub fn isStringMethodReceiver(value: core.JSValue) bool`。
- **作用**：判断接收者能否走 String 方法的快路径（字符串或 String 包装对象）。
- **实现**：字符串返回 `true`；非对象时只要不是 null / undefined 就返回 `true`（其它原始值可被 ToString）；对象则必须是 `class.ids.string` 包装对象。
- **所有权 / 错误 / 调用**：无：纯 tag / class 检查，不分配无 error。唯一调用方 `call_runtime.zig:1407`。

### `annexBStringMethodId` (`src/exec/string_ops.zig:2797`)

- **签名**：`pub fn annexBStringMethodId(name: []const u8) ?u32`。
- **作用**：按方法名查 Annex B 字符串方法表（`anchor` / `big` / `trimLeft` 等）里的 magic id。
- **实现**：在 comptime 的 `annexb_string_method_ids` 名字表上做 `name_id.lookup`（html 系列、`trimLeft`/`trimStart` 与 `trimRight`/`trimEnd` 共用 id、`substr`、`split`）。
- **所有权 / 错误 / 调用**：无：同 `standardStringMethodId`，查的是 AnnexB 那张表。调用方：`call_runtime.zig:1415` 与本文件测试。

### `errorToStringCall` (`src/exec/string_ops.zig:2801`)

- **签名**：`pub fn errorToStringCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Error.prototype.toString`：按 `name: message` 拼错误串。
- **实现**：接收者非对象抛 TypeError「not an object」。读 `name`（undefined 取 `"Error"`，否则 ToString）与 `message`（undefined 取空串，否则 ToString），各自展成字节；name 为空只返回 message、message 为空只返回 name，两者都非空时拼成 `name: message`。
- **所有权 / 错误 / 调用**：三个临时字节缓冲全部 defer deinit，返回新建串；`name` / `message` 两次属性读可能跑用户 getter 并抛。非对象接收者 → 带消息 "not an object" 的 TypeError。唯一调用方 `error_ops.zig:78`。

### `toStringBytesForSymbol` (`src/exec/string_ops.zig:2842`)

- **签名**：`pub fn toStringBytesForSymbol( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) ![]u8`。
- **作用**：取值的字符串表示字节（Symbol 直接 TypeError），调用方拥有返回的缓冲。
- **实现**：Symbol 直接 `error.TypeError`（ToString 对 Symbol 抛错）。已经是字符串就原样用，否则经 `toStringForAnnexB` 转换（可能触发用户 `toString`）。然后在临时 `ArrayList` 上 `appendRawString` 取出字节，`toOwnedSlice` 把缓冲交给调用方；`errdefer` 保证中途失败时缓冲被释放。
- **所有权 / 错误 / 调用**：返回的是 `buffer.toOwnedSlice` 的**堆切片，所有权交给调用方**（由它按 runtime allocator 释放），失败路径 `errdefer` 自行回收；字符串入参不新建串。Symbol → 裸 `error.TypeError`。唯一调用方 `builtin_glue.zig:494`。

### `consumePendingExceptionIfMatchesConstructor` (`src/exec/string_ops.zig:2862`)

- **签名**：`pub fn consumePendingExceptionIfMatchesConstructor(ctx: *core.JSContext, expected_name: []const u8) !bool`。
- **作用**：挂起异常来自指定构造器时清掉它并返回 true。
- **实现**：先用 `thrownValueMatchesConstructor` 比对，随后**无论是否命中**都 `ctx.clearException()`，只把匹配结果返回给调用方。
- **所有权 / 错误 / 调用**：读 `ctx.runtime.current_exception`（借用）判完后**无条件** `clearException()`——调用方拿到的只是「是否匹配」，异常到此为止。判定过程里的属性读本身可能抛（返回类型是 `!bool`）。唯一调用方 `call_runtime.zig:2687`。

### `thrownValueMatchesConstructor` (`src/exec/string_ops.zig:2869`)

- **签名**：`pub fn thrownValueMatchesConstructor(rt: *core.JSRuntime, thrown_value: core.JSValue, expected_name: []const u8) !bool`。
- **作用**：判断一个抛出值是不是指定构造器名（如 "TypeError"）造出来的错误对象——只比名字，不看原型链身份。
- **实现**：非对象直接 false。先看 `constructor` 属性：是对象时用 `nativeFunctionNameForVmBorrowed` 取它的原生函数名（借用视图，`defer deinit`），与 `expected_name` 相等即 true。否则退到 `name` 属性：不是字符串返回 false，是字符串就 `appendRawString` 到临时缓冲后 `std.mem.eql` 比较。两道判据都不命中返回 false——它只做名字匹配，不看原型链身份。
- **所有权 / 错误 / 调用**：只读借用的异常对象：`dispatch_name` 是借用的名字视图，`defer deinit` 归还；`name_bytes` 缓冲 defer deinit。它不清异常也不改引擎状态。调用方：`consumePendingExceptionIfMatchesConstructor:2884`、`binding/context.zig:486`。

### `arraySearchCall` (`src/exec/string_ops.zig:2890`)

- **签名**：`pub fn arraySearchCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.indexOf` / `lastIndexOf` / `includes`（含 TypedArray 同名方法）在 VM 调用点上的实现体：先从被调函数对象反查出是哪一种模式，再按接收者形态挑扫描策略；认不出函数身份就返回 `null`，让调用点退回通用调用。
- **实现**：身份识别两条路：`arrayPrototypeRecordId` 命中 `PrototypeMethod.index_of` / `last_index_of` / `includes` 直接定模式，否则用 `nativeFunctionNameForVmBorrowed` 按名字匹配，三个名字都不是就返回 `null`；走名字路的还要再从 global 的 `Array.prototype` 上取同名方法核对是同一个函数对象（接收者是 typed array 时豁免）。接着 null/undefined 接收者抛 `"Cannot convert undefined or null to object"`，原始值经 `primitiveObjectForAccess` 包装；`isTypedArrayPrototypeMethod` 为真而接收者不是 typed array 时 `error.TypeError`（brand check）。length 分三档：typed array 用 `arrayMethodTypedArrayLength`、快数组直接 `arrayLength()`、其余读 `length` 属性再 `toLengthIndex`；`length == 0` 时 includes 返回 `false`、其余返回 `-1`。fromIndex 由 `arrayFirstIndexStart` / `arrayLastIndexStart` 折算（`lastIndexOf` 得到的是**排他**上界）。扫描分四条：typed array 交 `array_ops.typedArraySearchScan` 按元素类直扫后备缓冲、不装箱（对齐 `quickjs.c:58072`）；`lastIndexOf` 且 `length > 1_000_000` 交 `arrayLastIndexSparseLarge`，枚举 own key 排序后倒着取，避免对稀疏巨长数组逐下标探测；`lastIndexOf` 的 dense 臂要求 fast array 且 `arrayLength() == length == arrayElements().len` 三者相等，满足就整段反扫并直接给出结果（扫不到就是 `-1`，不再走通用尾巴）；`indexOf` / `includes` 只扫 dense 前缀，扫不到继续往下。通用尾巴按 `from_right` 决定方向，逐个 `propertyAtomFromLengthIndex` 取键，非 includes 模式先 `has` 再 `get` 以跳过空洞（`quickjs.c:42426-42483`），比较用 `sameValueZero`（includes）或 `valuesStrictEqual`（另两种）。
- **所有权 / 错误 / 调用**：`dispatch_name` 是借用的名字视图，`defer deinit` 归还；循环里的 `key` 每轮 `defer deinit`。两处 `error.TypeError`：null/undefined 接收者已由 `throwTypeErrorMessage` 挂好消息，typed brand check 则是裸错误、由上层补消息。调用方：`array_ops` 的 dispatch（`src/exec/array_ops.zig:199` 的级联与 `:247` 的 record-id 表）以及 `call_runtime.zig:1278`。

### `arrayConcatCall` (`src/exec/string_ops.zig:3027`)

- **签名**：`pub fn arrayConcatCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.concat` 的实现体：用 ArraySpeciesCreate 造出目标数组，再把接收者和各参数依次平铺进去。
- **实现**：身份验证比 search 严：`isArrayPrototypeRecord(..., concat)` 不成立时，还要名字等于 `"concat"` **且** `arrayBuiltinMarker() == .concat` 双证，否则返回 `null`。null/undefined 接收者直接 `error.TypeError`，原始值 `primitiveObjectForAccess` 包装。输出数组走 `arraySpeciesCreate(..., 0, ...)`（尊重 `@@species`，可能是用户构造器），`property_ops.expectObject` 取出对象。随后先 `concatAppendValue` 接收者自身、再 for 循环各参数，是否展开由被调方里的 `isConcatSpreadable` 判定，游标 `next_index` 由被调方推进。收尾：`next_index > core.array.max_array_length` 时 `error.RangeError`，否则 `setValueProperty` 写回 `length`（Set 走完整属性协议，species 造出的宿主对象也能拦）。
- **所有权 / 错误 / 调用**：输出值的所有权交给调用方。错误：接收者为 null/undefined 或 species 构造失败时 `error.TypeError`，超长时 `error.RangeError`。调用方：`array_ops.zig:214` / `:258` 与 `call_runtime.zig:1292`；实际搬运在 `concatAppendValue`。

### `concatAppendValue` (`src/exec/string_ops.zig:3056`)

- **签名**：`pub fn concatAppendValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, out: *core.Object, next_index: *usize, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`Array.prototype.concat` 的搬运单元：一个值要么按 IsConcatSpreadable 展开成多个元素，要么整体当一个元素写进目标数组，并推进共享游标 `next_index`。
- **实现**：值是对象且 `isConcatSpreadable`（`@@isConcatSpreadable` 优先，其次 IsArray）为真时走展开路径：`concatSpreadLengthValue` + `toLengthIndex` 得到长度，先做 2^53-1 溢出检查（`next_index` 越界或加起来超过 `max_safe_length` → `error.TypeError`），再逐下标 `arrayCopyPresentIndex` 搬运——只搬存在的下标，空洞在目标里仍是空洞；每步先查 `core.array.max_array_length` 上限（超了 `error.RangeError`）再推进游标。非展开路径：同样两道上限检查后，`propertyAtomFromLengthIndex` 造下标 atom（`defer deinit`），`createDataPropertyOrThrow` 写入并推进游标。
- **所有权 / 错误 / 调用**：把元素写进调用方的 `out` 数组（`arrayCopyPresentIndex` / `createDataPropertyOrThrow` 让数组接手值），并就地推进 `next_index`；每轮的 `key` 都 `defer deinit`。超过 2^53-1 → 裸 `error.TypeError`，超过 `core.array.max_array_length` → 裸 `error.RangeError`；属性读写可能跑用户代码。调用方：`arrayConcatCall:3069`、`:3070`。

### `concatSpreadLengthValue` (`src/exec/string_ops.zig:3101`)

- **签名**：`pub fn concatSpreadLengthValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：取 concat 展开时该用的长度：一般就是 `length` 属性，但长度固定且未越界的 TypedArray 要拿自有 `length` 与之取较大者。
- **实现**：先照常读 `length` 属性得到 `dynamic`。随后只有一种情况会改口：对象是 TypedArray、`typedArrayFixedLength()` 非空（长度固定）且 `typedArrayOutOfBounds()` 为假，且自有 `length` 是数据属性、两边都是数字、自有值**大于**动态值时，返回自有 `length`。任何一条不满足都返回 `dynamic`。
- **所有权 / 错误 / 调用**：返回读出来的长度值（借用，多为数值立即数），本函数不分配；typed array 在动态 `length` 与自有 `length` 之间取大的那个。属性读可能跑用户 getter 并抛。唯一调用方 `concatAppendValue:3089`。

### `isConcatSpreadable` (`src/exec/string_ops.zig:3123`)

- **签名**：`pub fn isConcatSpreadable( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：`IsConcatSpreadable`：决定 `Array.prototype.concat` 展开该值还是当单元素。
- **实现**：先读 `Symbol.isConcatSpreadable`：为 undefined 时回落到 `arraySpeciesOriginalIsArray`（含 Proxy 递归的 IsArray），否则按 `valueTruthy` 取其真值。
- **所有权 / 错误 / 调用**：无所有权：读 `Symbol.isConcatSpreadable`（可能跑用户 getter）取真值性，未定义时回落 `arraySpeciesOriginalIsArray`。唯一调用方 `concatAppendValue:3088`。

### `uint8ArrayStringBytes` (`src/exec/string_ops.zig:3138`)

- **签名**：`pub fn uint8ArrayStringBytes(rt: *core.JSRuntime, value: core.JSValue) !std.ArrayList(u8)`。
- **作用**：取 `Uint8Array.fromHex` / `fromBase64` 这类入口的字符串参数字节（非字符串 TypeError）。
- **实现**：非字符串直接 `error.TypeError`。否则开一个临时 `ArrayList`（`errdefer deinit`），`appendRawString` 把串的字节复制进去，整个 list 交给调用方（由调用方负责 `deinit`）。
- **所有权 / 错误 / 调用**：返回的 `ArrayList(u8)` **所有权交给调用方**（由它 `deinit`），失败时 `errdefer` 自行释放。非字符串入参 → 裸 `error.TypeError`。调用方：`array_ops.zig:5695`、`:5702`、`:5737` 等 5 处（base64 / hex 解码入口）。

### `appendSourceStringUtf8` (`src/exec/string_ops.zig:3146`)

- **签名**：`pub fn appendSourceStringUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void`。
- **作用**：为 eval/Function 源码转换追加 UTF-8/WTF-8 字节。
- **实现**：通过 `JSValue.String.Utf8.fromValue` 建立视图，追加 `utf8.slice()`；有效代理对合为一个标量，孤立代理项保留三字节 WTF-8 表示。
- **所有权 / 错误 / 调用**：`Utf8` 视图在返回前 `defer deinit`，字节复制进调用方的 `buffer`；buffer 的分配与释放归调用方，唯一错误是转换/扩容的 `OutOfMemory`，不返回 JSValue。调用方：`function_ops.zig:466`/`:469`（Function 构造器的参数与函数体）、`eval_entry.zig:37`、`eval_ops.zig:399`、`call_runtime.zig:3353`（eval 源码）。

### `iteratorConcatCall` (`src/exec/string_ops.zig:3157`)

- **签名**：`pub fn iteratorConcatCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`Iterator.concat` 的转发入口。
- **实现**：直接转 `iterator_ops.iteratorConcatCall`。
- **所有权 / 错误 / 调用**：纯转发 `iterator_ops.iteratorConcatCall`，把本模块的三个依赖（`arrayPrototypeFromGlobal` / `getIteratorMethod` / `isCallableValue`）作为参数注入；所有权与错误全在被调方。唯一调用方 `iterator_ops.zig:3219`（`iterator_ops.zig:1497` 调的是 `iterator_ops` 自己那个七参版本，不经本转发）。

### `regExpStringIteratorNext` (`src/exec/string_ops.zig:3166`)

- **签名**：`pub fn regExpStringIteratorNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：RegExp String Iterator 的 `next`：靠下标槽当 done 标志，逐次跑 exec。
- **实现**：接收者不是 `regexp_string_iterator` 对象返回 `null`（交回上层级联）。下标槽非 0 表示已结束，直接返回 done 结果。target（matcher）或 data（字符串）缺失时返回 done 并置下标为 1。跑 `regExpExecGeneric`：结果为 null 时返回 done、置下标 1 并清空 target / data 槽。命中时按 kind 槽 bit0 判断是否 global——非 global 直接把下标置 1（下次即结束）；global 且命中是空串时读 `lastIndex` 并用 `advanceStringIndexNumber`（kind 槽 bit1 决定是否完整 Unicode）推进后写回。最后以整个 exec 结果作为迭代值返回。
- **所有权 / 错误 / 调用**：返回 `createIteratorResult` 新建的结果对象（归调用方）；耗尽时把 `iteratorIndexSlot` 置 1 并 `clearOptionalValueSlot` 断掉对 regexp 与输入串的两条边。接收者不是 regexp_string_iterator 时返回 `null` 让调用方继续级联（不是错误）。中途的 `regExpExecGeneric` 与 lastIndex 读写会跑用户代码。唯一调用方 `call_runtime.zig:1186`。

### `getFastStringPrimitiveDataProperty` (`src/exec/string_ops.zig:3208`)

- **签名**：`pub fn getFastStringPrimitiveDataProperty( ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, ) !?core.JSValue`。
- **作用**：字符串原始值读属性的快路径：直接从 realm 的 `%String.prototype%` 上取方法，不物化 String 包装对象。
- **实现**：接收者非字符串返回 `null`。只接受预定义的非索引 atom（排除 `length`，那是原始值自己的长度），所以 `s[i]` / `s.length` / 动态名仍走原路径；这一闸门必须同时覆盖记录表方法和以普通函数安装的 String.prototype 方法（concat / replace / replaceAll / AnnexB html），否则 `"x".replace(...)` 会掉进 `primitiveObjectForAccess` 逐字符建包装对象。原型经 `primitivePrototypeFromRealmOrGlobal` 取（对应 qjs `JS_GetPrototypePrimitive`，quickjs.c:7995-8011），有 exotic 方法则放弃；随后用内联的 `findOwnDataValueFast` 一趟取值（对应 qjs `find_own_property` + 已加载 flags 的分支，quickjs.c:6135），只有访问器 / auto-init 这类少见属性才落 `ownDataOrAutoInitPropertyValue`。
- **所有权 / 错误 / 调用**：返回的是原型上**借用**的属性值（方法函数对象等，不新建、不建包装对象）；不适用时返回 `null` 让上层继续级联。只有罕见的 accessor / auto-init 属性会落到 `ownDataOrAutoInitPropertyValue`（可能物化并写回原型）。调用方：`tailcall_dispatch.zig:4368`、`object_ops.zig:2728`。

### `defineStringWrapperIndexProperty` (`src/exec/string_ops.zig:3248`)

- **签名**：`pub fn defineStringWrapperIndexProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void`。
- **作用**：给 String 包装对象定义一个码元索引属性。
- **实现**：`< 0x100` 的码元取 runtime 共享单字节串，否则 `String.createUtf16` 建单码元串；再以 `Descriptor.data(value, false, true, false)`（不可写、可枚举、不可配置）定义 `atomFromUInt32(index)`。
- **所有权 / 错误 / 调用**：值要么是 runtime 共享单字节串、要么是新建 UTF-16 串，定义成不可写不可配置的下标属性后由对象持有；本函数不建根（`object` 的保活归调用方）。唯一调用方 `object_ops.zig:2799`。

### `getStringIndexValue` (`src/exec/string_ops.zig:3258`)

- **签名**：`pub fn getStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !?core.JSValue`。
- **作用**：字符串原始值的索引读：`s[i]` 的快路径。
- **实现**：atom 不是数组索引返回 `null`；接收者非字符串返回 `null`；下标越界返回 undefined。命中时 `< 0x100` 的码元取 runtime 共享单字节串（URI 扫描这类热循环靠它省掉每次的 header+字节两次分配），否则建单码元 UTF-16 串。
- **所有权 / 错误 / 调用**：非字符串或非下标原子返回 `null`（让调用方继续级联），越界返回 undefined 立即数；命中时 `< 0x100` 用 runtime 共享单字节串（URI 热循环靠它省掉每次的 header+bytes 分配对），否则新建 UTF-16 串归调用方。唯一调用方 `object_ops.zig:2610`。

### `arrayToStringCall` (`src/exec/string_ops.zig:3276`)

- **签名**：`pub fn arrayToStringCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.toString` 的实现体：按 ES2024 23.1.3.36，去接收者身上取 `join`，可调用就调它，否则退回 `Object.prototype.toString` 的内建实现。
- **实现**：先验身份（record id 或 `arrayBuiltinMarker() == .to_string`，不符返回 `null`）。null/undefined 接收者 `error.TypeError`，原始值经 `primitiveObjectForAccess` 包装成对象。`getValueProperty(object_value, join)` —— 是从**对象上**取而不是直接用内建 join，所以用户覆盖的 `join`（含继承来的）会被尊重；`isCallableValue` 为真就 `callValueOrBytecodeRoot` 无参调用它并返回结果，否则调 `objectToStringIntrinsic` 得到 `"[object Array]"` 一类的标签串。
- **所有权 / 错误 / 调用**：返回值归调用方。错误：接收者为 null/undefined 时 `error.TypeError`；用户 `join` 抛出的异常原样透出。调用方：`array_ops.zig:239` 的 record-id 表与 `call_runtime.zig:1266`。

### `arrayToLocaleStringCall` (`src/exec/string_ops.zig:3298`)

- **签名**：`pub fn arrayToLocaleStringCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.toLocaleString`（及 TypedArray 同名方法）的实现体：逐个元素调它自己的 `toLocaleString()`，结果用 `,` 拼起来。
- **实现**：身份验证同族（record id 或 `arrayBuiltinMarker() == .to_locale_string`）；null/undefined 接收者 `error.TypeError`，原始值包装后 `expectObject` 失败则返回 `null` 放弃快路径；`isTypedArrayPrototypeMethod` 为真而接收者不是 typed array 时 `error.TypeError`。length 取自 `arrayMethodTypedArrayLength` 或 `length` 属性 + `toLengthIndex`。循环里：下标非 0 先追加一个 `,`（分隔符恒为逗号，不随 locale 变）；typed array 用 `typedArrayGetIndex` 取元素，若调用的是 `Array.prototype` 版本且下标越过当前实际长度（RAB 中途缩了）就取 `undefined`；普通对象按 `propertyAtomFromLengthIndex` 走 `getValueProperty`。元素是 `undefined` / `null` 时贡献空串（只留逗号），否则取它的 `toLocaleString` 属性、`callValueOrBytecodeRoot` 无参调用、`toStringForAnnexB` 转字符串后 `appendRawString` 进缓冲。最后 `createStringValue` 出串。
- **所有权 / 错误 / 调用**：拼接缓冲是运行时 allocator 的临时 `ArrayList`，`defer deinit`；返回串归调用方。每轮的元素取值与用户 `toLocaleString` 都可能抛异常并原样透出。调用方：`array_ops.zig:240` 与 `call_runtime.zig:1269`。

### `objectToLocaleStringCall` (`src/exec/string_ops.zig:3347`)

- **签名**：`pub fn objectToLocaleStringCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Object.prototype.toLocaleString`：转调接收者自己的 `toString`。
- **实现**：两步：`getValueProperty` 从接收者上取 `toString`，再 `callValueOrBytecodeRoot` 无参调用它。规范就是这样定义的——`Object.prototype.toLocaleString` 不做任何本地化，只是转发给 `this.toString()`，所以用户覆盖的 `toString` 会被用上；属性取不到或不可调用时的报错由被调方给出。
- **所有权 / 错误 / 调用**：只做「读 `toString` 再调用」，返回值归调用方；属性读与调用都可能跑用户代码并抛，本函数不做 callable 检查（交给 `callValueOrBytecodeRoot`）。唯一调用方 `object_builtin_ops.zig:346`（`Object.prototype.toLocaleString`）。

### `objectToStringCall` (`src/exec/string_ops.zig:3360`)

- **签名**：`pub fn objectToStringCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Object.prototype.toString` 的实现体（ES2024 20.1.3.6）。
- **实现**：先处理 spec 的前两步特例：`this` 为 `undefined` 返回 `"[object Undefined]"`、为 `null` 返回 `"[object Null]"`（这两步在 ToObject 之前，所以不会抛）。其余走 ToObject——已经是对象就直用，原始值 `primitiveObjectForAccess` 包装——再把标签计算整个交给 `objectToStringIntrinsic`。
- **所有权 / 错误 / 调用**：返回串归调用方。调用方：`object_builtin_ops.zig:345` 的 `Object.prototype` 方法分发。

### `objectToStringIntrinsic` (`src/exec/string_ops.zig:3374`)

- **签名**：`pub fn objectToStringIntrinsic( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：算出 `[object X]` 里的 X：先定内建标签，再让 `Symbol.toStringTag` 覆盖；`Object.prototype.toString` 和「没有可调用 `join` 的 `Array.prototype.toString`」都收敛到这里。
- **实现**：`expectObject` 取对象后 `defaultObjectToStringTag` 给出内建标签（Proxy 透到 target、数组、各函数类、`Arguments` / `Error` / 包装类等）。接着取 comptime 预定义的 `Symbol.toStringTag` atom；这个 atom 在当前构建里不存在时直接返回 `"[object Object]"`。有 atom 就 `getValueProperty` 读该属性——这一步会触发 getter 与 proxy trap，因此排在内建标签之后但结果优先：读出来是字符串就用它（经 `appendRawString` 拿到字节），不是字符串则回落到内建标签。
- **所有权 / 错误 / 调用**：标签字节只在临时 `ArrayList` 里活一次，`defer deinit`；返回串归调用方。错误：非对象输入、revoked proxy（经 `defaultObjectToStringTag`）以及用户 getter 抛出的异常。调用方：`objectToStringCall`、`arrayToStringCall`。

### `objectTagString` (`src/exec/string_ops.zig:3395`)

- **签名**：`pub fn objectTagString(rt: *core.JSRuntime, tag: []const u8) !core.JSValue`。
- **作用**：把一个标签名包成 `"[object <tag>]"` 字符串值，是 `Object.prototype.toString` 系列唯一的出串点。
- **实现**：运行时 allocator 上开临时 `ArrayList`，依次 `appendSlice` `"[object "`、`tag`、`"]"`，再 `value_ops.createStringValue` 复制成 JS 串。`tag` 只被借用，允许是字面量也允许是从 `Symbol.toStringTag` 读出的用户串。
- **所有权 / 错误 / 调用**：临时缓冲 `defer deinit`；返回串归调用方。错误只有分配失败。调用方：`objectToStringCall`（Undefined / Null 两个特例）、`objectToStringIntrinsic`。

### `defaultObjectToStringTag` (`src/exec/string_ops.zig:3404`)

- **签名**：`pub fn defaultObjectToStringTag(object: *core.Object) ![]const u8`。
- **作用**：`Object.prototype.toString` 的内建标签：按对象形态给出 `Array` / `Function` / `Error` 等。
- **实现**：按对象形态返回内建标签：Proxy 先查 handler（已 revoke 则 `error.TypeError`）并递归看 target 是否是数组（数组标签 `Array`、可调用 target 标签 `Function`），其余按 `isArray` / 函数类 / 各内建类 id 给出 `Array`、`Function`、`Error`、`String` 等标签，默认 `Object`。
- **所有权 / 错误 / 调用**：返回的是**静态字面量**切片，不分配、调用方不释放、也不随对象失效。revoked proxy（`proxyHandler() == null`）→ 裸 `error.TypeError`。调用方：`objectToStringIntrinsic:3403`，另有本文件按 class 断言标签的测试。

### `objectIsArrayForToString` (`src/exec/string_ops.zig:3478`)

- **签名**：`pub fn objectIsArrayForToString(object: *core.Object) !bool`。
- **作用**：IsArray 抽象操作（ES2024 7.2.2）在 toString 标签计算里的那一份：真数组，或者层层穿透后 target 是数组的 Proxy，都算 Array。
- **实现**：`isArray()` 为真立即 true；不是 Proxy 就 false；是 Proxy 但 `proxyHandler()` 已为 `null`（被 revoke）时 `error.TypeError`——这正是 spec 要求 IsArray 对已撤销 proxy 抛错的那一条；否则取 `proxyTarget()` 递归下去，取不到 target 或 target 不是对象时 false。递归深度等于 proxy 嵌套层数。
- **所有权 / 错误 / 调用**：纯查询，不分配。错误：revoked proxy 的 `error.TypeError`。调用方：`defaultObjectToStringTag` 的 Proxy 分支；递归调用自身。

### `stringObjectHasIndexProperty` (`src/exec/string_ops.zig:3487`)

- **签名**：`pub fn stringObjectHasIndexProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool`。
- **作用**：判断 String 包装对象是否拥有某个索引属性。
- **实现**：类不是 `class.ids.string`、取不到内部字符串、atom 不是数组索引都返回 `false`；否则比较下标与码元长度。
- **所有权 / 错误 / 调用**：无：只读 String 包装对象的内部串长度做下标判断，不分配无 error（失败一律 false）。唯一调用方 `object_ops.zig:3787`。

### `appendUtf16UnitsAsUtf8` (`src/exec/string_ops.zig:3497`)

- **签名**：`pub fn appendUtf16UnitsAsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void`。
- **作用**：把一段 UTF-16 码元按 UTF-8 追加进字节缓冲。
- **实现**：薄封装，主体转发到 `unicode_lib.appendUtf16UnitsAsUtf8`。
- **所有权 / 错误 / 调用**：无自身所有权：转发 `unicode_lib`，往调用方的 buffer 追加，唯一错误是扩容。唯一调用方 `regexp_fastpath.zig:498`（经 `:51` 的别名）。

### `appendAsciiUnits` (`src/exec/string_ops.zig:3500`)

- **签名**：`pub fn appendAsciiUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), bytes: []const u8) !void`。
- **作用**：把 ASCII 字节逐个零扩展成码元追加进 u16 缓冲。
- **实现**：逐字节 `out.append`（调用方保证输入是 ASCII）。
- **所有权 / 错误 / 调用**：无自身所有权：逐字节追进调用方的 u16 列表，唯一错误是扩容 `OutOfMemory`。调用方全在本文件的 `stringCreateHtml`（11 处）。

### `isAsciiDigitUnit` (`src/exec/string_ops.zig:3504`)

- **签名**：`pub fn isAsciiDigitUnit(unit: u16) bool`。
- **作用**：码元是否是 ASCII 数字。
- **实现**：薄封装，主体转发到 `unicode_lib.isAsciiDigitUnit`。
- **所有权 / 错误 / 调用**：无：`unicode_lib` 谓词的再导出。调用方：`replacementCaptureUnits`、`parseSlotCaptureRefData` 共 6 处。

### `isHighSurrogateUnit` (`src/exec/string_ops.zig:3508`)

- **签名**：`pub fn isHighSurrogateUnit(unit: u16) bool`。
- **作用**：码元是否是高代理。
- **实现**：薄封装，主体转发到 `unicode_lib.isHighSurrogateUnit`。
- **所有权 / 错误 / 调用**：无：`unicode_lib` 谓词的再导出。调用方全在本文件：`advanceStringIndexBody:1191`、`advanceStringIndexUnits:1199`、`advanceStringIndexNumber:1935`、`appendUtf32FromStringValue:2067`。

### `isLowSurrogateUnit` (`src/exec/string_ops.zig:3512`)

- **签名**：`pub fn isLowSurrogateUnit(unit: u16) bool`。
- **作用**：码元是否是低代理。
- **实现**：薄封装，主体转发到 `unicode_lib.isLowSurrogateUnit`。
- **所有权 / 错误 / 调用**：无：`unicode_lib` 谓词的再导出，与 `isHighSurrogateUnit` 成对出现在同样四处。

### `StringBuffer.deinit` (`src/exec/string_ops.zig:3549`)

- **签名**：`fn deinit(self: *StringBuffer) void`。
- **作用**：释放窄 / 宽两个本地缓冲。
- **实现**：分别 `latin1.deinit` 与 `wide.deinit`；不涉及 JSValue 所有权。
- **所有权 / 错误 / 调用**：释放两个内部 ArrayList；`StringBuffer` 本身是调用方的栈变量，三个调用方都用 `defer`：`stringReplaceCore:482`、`regExpReplaceFast:1503`、`stringPad:3699`。

### `StringBuffer.putc8` (`src/exec/string_ops.zig:3555`)

- **签名**：`fn putc8(self: *StringBuffer, byte: u8) !void`。
- **作用**：追加一个 latin1 码元（qjs `string_buffer_putc8`）。
- **实现**：已 widen 时写进 `wide`，否则写进 `latin1`。
- **所有权 / 错误 / 调用**：无所有权：往当前宽度的缓冲追一个 latin1 单元，唯一错误是扩容。调用方：`appendSubstitutionStringSearch:581`、`appendRegExpSubstitutionFromSlots:1870`/`:1893`/`:1896`。

### `StringBuffer.appendStringValue` (`src/exec/string_ops.zig:3563`)

- **签名**：`fn appendStringValue(self: *StringBuffer, value: core.JSValue) !void`。
- **作用**：把一个字符串值的全部码元追加进缓冲（qjs `string_buffer_concat_value`）。
- **实现**：取 `asStringBody`（拿不到 `error.TypeError`）后用 `resolveData()` 的整段交 `appendUnits`。
- **所有权 / 错误 / 调用**：只借用入参串的 `resolveData()` 视图往缓冲复制，不保留任何引用。取不到字符串体 → 裸 `error.TypeError`。调用方：`stringReplaceCore:502`、`appendSubstitutionStringSearch:583`。

### `StringBuffer.widen` (`src/exec/string_ops.zig:3569`)

- **签名**：`fn widen(self: *StringBuffer) !void`。
- **作用**：把已攒的 latin1 内容搬进 UTF-16 缓冲并切换到宽模式。
- **实现**：置 `is_wide`，按已有长度预留 `wide` 容量并逐字节零扩展搬过去，最后 `latin1.clearRetainingCapacity`。
- **所有权 / 错误 / 调用**：就地把 latin1 内容搬进 `wide` 并清空 latin1（容量保留），不涉及 JSValue；唯一错误是扩容。唯一调用方 `appendUnits:3639`。

### `StringBuffer.ensureCapacity` (`src/exec/string_ops.zig:3576`)

- **签名**：`fn ensureCapacity(self: *StringBuffer, additional: usize) !void`。
- **作用**：按当前宽窄模式预留额外容量。
- **实现**：`is_wide` 时 `wide.ensureUnusedCapacity`，否则 `latin1.ensureUnusedCapacity`。
- **所有权 / 错误 / 调用**：只按当前宽度预留容量，不改内容也不改宽度。调用方：`appendUnits:3628`、`stringPad:3700`。

### `StringBuffer.appendUnits` (`src/exec/string_ops.zig:3585`)

- **签名**：`fn appendUnits(self: *StringBuffer, data: core.string.String.ResolvedData, start: usize, count: usize) !void`。
- **作用**：追加 `data` 中 `[start, start+count)` 的码元，必要时就地 widen。
- **实现**：latin1 源全部 `<= 0xFF`：宽模式下逐字节零扩展进 `wide`，窄模式直接 `appendSlice`。utf16 源先 `ensureCapacity(count)`，逐码元扫描：窄模式遇到 `<= 0xff` 直接写 latin1，遇到更大的先 `widen()` 再为本段剩余码元补预留，随后写 `wide`（对应 qjs `string_buffer_concat` 的 widen 路径）。
- **所有权 / 错误 / 调用**：只读调用方给的 `ResolvedData` 借用视图，`start`/`count` 的合法性由调用方保证；latin1 源直接 `appendSlice`，宽源遇到首个 >0xFF 单元才 `widen` 并为剩余部分补预留。唯一错误是扩容。调用方：`stringReplaceCore`、`appendSubstitutionStringSearch`、`regExpReplaceFast`、`appendRegExpSubstitutionFromSlots`、`stringPad` 共 10 余处。

### `StringBuffer.finish` (`src/exec/string_ops.zig:3619`)

- **签名**：`fn finish(self: *StringBuffer, rt: *core.JSRuntime) !core.JSValue`。
- **作用**：把缓冲收尾成字符串值。
- **实现**：`is_wide` 时 `String.createUtf16(wide.items)`，否则 `String.createLatin1(latin1.items)`。
- **所有权 / 错误 / 调用**：把缓冲内容**拷贝**成新串返回给调用方；缓冲本身不被清空，仍由调用方的 `defer deinit` 释放（重复调用会得到两个独立的串）。调用方：`stringReplaceCore:512`、`regExpReplaceFast:1548`、`stringPad:3715`。

### `stringPad` (`src/exec/string_ops.zig:3628`)

- **签名**：`pub fn stringPad( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`padStart`（id 34）/ `padEnd`（id 35）的 realm 侧实现：窄优先累加器，一次解析源码元。
- **实现**：nullish 接收者抛「null or undefined are forbidden」，接收者 ToString 后只 `resolveData()` 一次（qjs 直接读 JSString 的 len，quickjs.c:46313-46314）。目标长度经 `toLengthIndex`，不大于源长度时原样返回；填充串缺省为一个空格，为空串时也原样返回；目标长度超过 `js_string_len_max` 抛 RangeError「invalid string length」（quickjs.c:46331-46334）。随后按 `target_length` 预留 `StringBuffer`，padEnd 先写源串、padStart 后写源串，中间按 `fill_len` 分块循环写填充（quickjs.c:46338-46356）。
- **所有权 / 错误 / 调用**：目标长度不超过源长、或填充串为空时**原样交回** `string_value`（借用，不新建）；否则 `StringBuffer`（defer deinit）攒完由 `finish` 新建串。`source` / `fill` 都直接借用 `resolveData()` 视图。错误：nullish 接收者挂 "null or undefined are forbidden"，超过 `js_string_len_max` 挂 "invalid string length"，取不到字符串体是裸 `error.TypeError`。唯一调用方 `stringPrototypeMethod:2033`（id 34 / 35）。

### `stringNormalize` (`src/exec/string_ops.zig:3687`)

- **签名**：`pub fn stringNormalize( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.normalize`：真正做 NFC/NFD/NFKC/NFKD 规范化。
- **实现**：nullish 接收者抛「null or undefined are forbidden」，接收者 ToString。form 缺省为 NFC，否则取字符串后比对四个名字，都不匹配抛 RangeError「bad normalization form」（qjs `js_string_normalize`，quickjs.c:46635）。随后把串展成 UTF-32 码点，交 `unicode_lib.normalizeAlloc` 规范化，再逐码点编回 UTF-16 建串。
- **所有权 / 错误 / 调用**：UTF-32 输入缓冲、`normalizeAlloc` 的结果切片与 u16 输出列表都在返回前释放，返回新建 UTF-16 串。错误：nullish 接收者挂 "null or undefined are forbidden"，未知 form 挂 "bad normalization form"（`throwRangeErrorMessage` → `error.RangeError`）。唯一调用方 `stringPrototypeMethod:2042`。

### `stringLocaleCompare` (`src/exec/string_ops.zig:3725`)

- **签名**：`pub fn stringLocaleCompare( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`String.prototype.localeCompare` 的 realm 侧实现：两边先 NFC 规范化再按码点序比较。
- **实现**：nullish 接收者抛「null or undefined are forbidden」；两个操作数都 ToString 后经 `normalizedUtf32(.nfc)` 转成 UTF-32，再 `std.mem.order` 映射成 -1 / 0 / 1（无 locale/ICU 支持）。
- **所有权 / 错误 / 调用**：返回 int32 立即数，不新建串；两个 `NormalizedUtf32` 各自 `defer deinit` 释放归一化结果。nullish 接收者 → 带消息 TypeError；两次 ToString 可能跑用户代码。唯一调用方 `stringPrototypeMethod:2045`。

### `NormalizedUtf32.deinit` (`src/exec/string_ops.zig:3756`)

- **签名**：`fn deinit(self: NormalizedUtf32) void`。
- **作用**：释放 `normalizedUtf32` 分配的那块 UTF-32 结果缓冲；不涉及 JSValue，也没有根要拆。
- **实现**：一行 `self.allocator.free(self.slice)`（allocator 由结构体按值携带）。
- **所有权 / 错误 / 调用**：释放 `normalizeAlloc` 返回的 u32 切片（结构体按值持有 allocator）；调用方必须 `defer` 调用它——见 `stringLocaleCompare:3771`、`:3773`。

### `normalizedUtf32` (`src/exec/string_ops.zig:3761`)

- **签名**：`fn normalizedUtf32(rt: *core.JSRuntime, value: core.JSValue, form: unicode_lib.NormalizationForm) !NormalizedUtf32`。
- **作用**：把字符串值展成 UTF-32 并按给定形式规范化，返回自带释放器的缓冲。
- **实现**：`appendUtf32FromStringValue` 收集码点（临时缓冲随即释放），再 `unicode_lib.normalizeAlloc` 分配规范化结果，连同 allocator 一起装进 `NormalizedUtf32`。
- **所有权 / 错误 / 调用**：返回的 `slice` 是 `unicode_lib.normalizeAlloc` 的堆内存，**所有权交给调用方**（经 `NormalizedUtf32.deinit` 释放）；输入的 UTF-32 ArrayList 在函数内 defer deinit。唯一调用方 `stringLocaleCompare:3770`、`:3772`。

### `stringNumericArgsMethod` (`src/exec/string_ops.zig:3771`)

- **签名**：`pub fn stringNumericArgsMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：参数是数值的 String 方法（charAt / substring / substr / charCodeAt / at / codePointAt / slice / repeat）的共用入口。
- **实现**：nullish 接收者抛「null or undefined are forbidden」；接收者已是字符串就直接用，否则 ToString。最多两个参数：undefined 保持 undefined，已是数值直接用，其余经 `builtin_glue.toNumberLikeArgument` 做可观察 ToNumber。随后 id 1（substring）先试 `fastLatin1Substring`，id 0（charAt）走 `callStringCharAtBody`，id 25（substr）走 `stringSubstr`，其余经 `callStringBody` 落记录表，并把 `error.RangeError` / `error.InvalidLength` 翻成带消息的 RangeError。
- **所有权 / 错误 / 调用**：接收者是字符串时**原样借用**、否则 ToString；数值参数经 `builtin_glue.toNumberLikeArgument` 规整进栈上 `coerced`。返回值要么是 `fastLatin1Substring` / `stringSubstr` 新建的串，要么是 `callStringBody` / `callStringCharAtBody` 交回的值。错误：nullish 接收者挂 "null or undefined are forbidden"；被调方的 `error.RangeError` / `error.InvalidLength` 在这里补成带消息的 RangeError。唯一调用方 `stringPrototypeMethod:2051`（id 0/1/25/29-33）。

### `fastLatin1Substring` (`src/exec/string_ops.zig:3815`)

- **签名**：`fn fastLatin1Substring(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !?core.JSValue`。
- **作用**：`substring`（id 1）的窄串快路径：接收者是扁平 latin1 串、起止又都是 int32 立即数时直接按字节切，条件不满足返回 `null` 回落通用记录表实现。
- **实现**：接收者必须是字符串、参数不超过两个；只接受 latin1 表示（utf16 返回 `null`）。起止参数必须是 int32 或 undefined（undefined 的 end 取串长），否则返回 `null` 交回通用路径。两端钳进 `[0, len]` 后按大小排序，空区间返回运行时空串，其余 `String.createLatin1` 复制出子串。
- **所有权 / 错误 / 调用**：`bytes` 是借用视图，空区间返回 runtime 共享空串，否则 `String.createLatin1` 拷成新串归调用方。形状不符（宽串、参数不是 int32、参数超过两个）返回 `null` 让调用方回落。唯一调用方 `stringNumericArgsMethod:3830`（id 1）。

### `int32OrUndefinedStringIndex` (`src/exec/string_ops.zig:3836`)

- **签名**：`fn int32OrUndefinedStringIndex(value: core.JSValue) ?i64`。
- **作用**：取立即数 int32 下标；undefined 或非 int32 返回 `null`。
- **实现**：undefined 返回 `null`；`asInt32` 成功则扩成 i64，否则 `null`。
- **所有权 / 错误 / 调用**：无：纯取值，undefined 与非 int32 都返回 `null`，不分配无 error。调用方：`fastLatin1Substring:3855`、`:3856`。

### `stringSubstr` (`src/exec/string_ops.zig:3845`)

- **签名**：`pub fn stringSubstr( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, string_value: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：Annex B `String.prototype.substr` 的 realm 侧实现（按码元）。
- **实现**：先把接收者展成 u16 码元。start 参数缺省或 undefined 取 0；NaN / 0 取 0，负数按 `size - |trunc|` 回绕（`-∞` 取 0），`+∞` 取 size，其余截断后钳到 size。length 参数缺省取到末尾，NaN 或 `<= 0` 取 0，`+∞` 取剩余长度，其余截断后钳到剩余长度；最后按区间 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`units` 临时 ArrayList defer deinit，返回新建 UTF-16 串；`output` / `global` 参数未使用，只为与同族 AnnexB body（`stringPad` / `stringHtmlMethod` / `stringNormalize` 等）保持 ABI 一致，函数上已加注释说明。参数此时已被调用方规整成数值，这里不再跑可观察转换，因此除分配外无 error。唯一调用方 `stringNumericArgsMethod:3837`（id 25）。

### `stringHtmlMethod` (`src/exec/string_ops.zig:3893`)

- **签名**：`pub fn stringHtmlMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Annex B html 包装方法（anchor/big/blink/bold/fixed/fontcolor/fontsize/italics/link/small/strike/sub/sup）的 realm 侧入口。
- **实现**：nullish 接收者返回 `error.TypeError`；接收者 ToString 后展成码元，再按 method_id `switch` 到 `stringCreateHtml`：带属性的四个（anchor=a/name、fontcolor=font/color、fontsize=font/size、link=a/href）传 `args[0]`（缺省 undefined），其余只传标签名；未知 id 返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：`string_units` 临时 ArrayList defer deinit，返回值来自 `stringCreateHtml`（新建串）。nullish 接收者与未知 id 都是裸 `error.TypeError`（这条腿不补消息）。唯一调用方 `stringPrototypeMethod:2039`（13 个 AnnexB id）。

### `stringCreateHtml` (`src/exec/string_ops.zig:3928`)

- **签名**：`fn stringCreateHtml( ctx: *core.JSContext, string_units: []const u16, tag: []const u8, attr: []const u8, attr_value: core.JSValue, has_attr: bool, output: ?*std.Io.Writer, global: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：html 包装的共用拼装：`<tag[ attr="…"]>…</tag>`。
- **实现**：按码元拼 `<`、标签名；`has_attr` 时属性值先 ToString 再展成码元，逐码元拷贝并把 `"` 转义成 `&quot;`，包在 ` attr="` 与 `"` 之间；然后 `>`、接收者码元、`</`、标签名、`>`，最后 `String.createUtf16`。
- **所有权 / 错误 / 调用**：`out` / `attr_units` 两个 ArrayList defer deinit，返回新建 UTF-16 串；属性值经 `toStringForAnnexB`（可能跑用户代码）后逐单元把 `"` 转义成 `&quot;`。唯一调用方 `stringHtmlMethod` 的 13 个 id 分支。

## 覆盖核对

- 清单函数数（本文件分到）: 86（`src/exec/string_ops.zig` 全文件 155）
- 本文标题覆盖: 86
- 未覆盖: 无
