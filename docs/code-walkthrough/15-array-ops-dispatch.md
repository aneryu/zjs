# 15 — `array_ops.zig`：分发、ArrayBuffer、TypedArray 构造

从文件头到 `addCollectionEntriesFromArray`。含 `arrayMethodFastCall`、ArrayBuffer/TypedArray 构造与 accessor、`typedArraySetCall`。

### `setValuePropertyOrThrow` (`src/exec/array_ops.zig:95`)

- **签名**：`fn setValuePropertyOrThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：数组 mutator 内建写 receiver 元素/length 的统一入口，带 qjs `JS_PROP_THROW` 纪律（spec `Set(O, P, V, true)`）：失败一律抛，连 sloppy 调用方也不例外。
- **实现**：把 `throw` 参数写死成 `true` 转给 `object_ops.setValuePropertyWithThrow`，丢弃其布尔返回值；对应 qjs 在各 `js_array_*` 处调 `JS_SetPropertyInt64` 的形状。
- **所有权 / 错误 / 调用**：私有薄包装：`value` 借用，写成功后由目标对象持有；`setValuePropertyWithThrow` 的 bool 结果被 `_ =` 丢弃，因为末位 `true` 已经要求失败即抛。不分配、不建根。error set 由属性写路径决定（不可写 / 冻结 / proxy 拒绝 / setter 自身抛出，典型是 `error.TypeError`），沿 `try` 上抛后在 VM 快调用路径由 `call_runtime.handleCatchableRuntimeError` 变成 JS 异常并跳 catch，在记录路径由 `array_builtin_ops` 的 handler 经 `managedGenericMagic` thunk 的 `hostResultToValue` 变成 pending 异常。调用方全在本文件（20 余处数组 mutator：copyWithin `:2702`/`:2706`、fill `:2918`、push `:3009`/`:3013`、pop/shift/unshift/reverse/splice 各处）。

### `popCatchMarker` (`src/exec/array_ops.zig:117`)

- **签名**：`pub fn popCatchMarker(_: *core.JSRuntime, stack: *stack_mod.Stack) !??usize`。
- **作用**：for-of 记录的 catch-offset 编码或识别。
- **实现**：从栈顶往下扫：遇 `forof_ops.isIteratorCatchMarker` 认定的 marker 就连弹三格（iterator / nextMethod / marker 三元组，不足 3 格是 `error.StackUnderflow`）继续扫；否则弹一格，若它 `is(.catch_offset)` 就返回 `popped.catchTarget()`。扫空整条栈都没有 catch offset 时返回外层 `null`（返回类型是 `!??usize`：外层 null = 没有 catch 目标，内层 optional 是 `catchTarget()` 自己的）。错误：error.StackUnderflow。
- **所有权 / 错误 / 调用**：`stack` 借用；弹出的值直接丢弃（TGC 下出栈没有 release 义务，槽位由栈顶指针回退失去根身份），不分配、不建根。error set 只有 `error.StackUnderflow`——迭代器 catch marker 后面不足三个槽意味着引擎不变量已破；`exception_ops.runtimeErrorInfo` 不认识这个 sentinel，所以它没有对应的 JS 错误构造器，万一逃到 native 边界只会被 `nativeFromHostError` 兜底成 `Error: StackUnderflow`。调用方：`exec/vm_opcodes.zig:114`、`:119`（throw 处理）与 `exec/call_runtime.zig:198`（catch 派发）。

### `arrayPrototypeFromGlobal` (`src/exec/array_ops.zig:132`)

- **签名**：`pub fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：取当前 realm 的 `Array.prototype`，给新建数组定原型用。
- **实现**：先查 realm 缓存 `cachedRealmValue(.array_prototype)`（`expectObject` 失败按 null 处理）；缓存未填时退回 global 上 own data 属性 `Array` 再取其 own data `prototype`；都没有返回 null。关键调用：`global.cachedRealmValue`、`property_ops.expectObject`、`global.getOwnDataObjectBorrowed`、`constructor.getOwnDataObjectBorrowed`。
- **所有权 / 错误 / 调用**：返回借用指针：原型由 realm 缓存或 `global.Array` 的 `prototype` 属性持有，调用方既不 retain 也不释放；null 时调用方用引擎默认原型建数组。无 error set——`property_ops.expectObject` 的失败被 `catch null` 吞成「缓存不可用」。调用方遍布 exec（50 余处，如 `object_ops.zig:747`、`iterator_ops.zig:1165`、本文件 `buildCallSiteArray` `:277`），是「新建数组挂什么原型」的统一入口；比 `exec/array_ops.zig:284` 的同名私有函数多一层 `Array.prototype` 属性回退。

### `arrayIteratorPrototypeFromContext` (`src/exec/array_ops.zig:142`)

- **签名**：`pub fn arrayIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object`。
- **作用**：取本 context 的 %ArrayIteratorPrototype%（首次访问时现建），给 `Array.prototype.values`/`keys`/`entries` 造出来的迭代器当原型。
- **实现**：整条转发 `iterator_ops.arrayIteratorPrototypeFromContext`（`src/exec/iterator_ops.zig:1041`）：被转发者先查 `ctx.class_prototypes[core.class.ids.array_iterator]`，命中且是对象就直接返回；未命中才现建一个 `Symbol.toStringTag == "Array Iterator"` 的 iterator 原型、装上原生 `next`（`method_ids.iterator.IntrinsicMethod.array_iterator_next`）并用 `addArrayIteratorNextFunction` 登记身份，再从 %IteratorPrototype% 继承 `@@iterator`。本文件只留这个再导出壳。
- **所有权 / 错误 / 调用**：一行转发，返回借用的 %ArrayIteratorPrototype%；所有权与 error set 全由 `iterator_ops.arrayIteratorPrototypeFromContext` 决定（realm 未装好时是 `error.InvalidBuiltinRegistry` 一类的注册表错误）。唯一调用方是本文件的 `arrayIteratorMethodRecord`（`:6354`）——`iterator_ops.zig:1104` 调的是它自己那个同名函数，不是这层壳。

### `isArrayMethodReceiver` (`src/exec/array_ops.zig:146`)

- **签名**：`pub fn isArrayMethodReceiver(value: core.JSValue) bool`。
- **作用**：判断一个值是不是数组对象（`Object.isArray()` 意义上的数组 exotic），给 realm 名字级联筛掉非数组 receiver。
- **实现**：`objectFromValue(value) orelse return false`，然后返回 `object.isArray()`；不穿透 proxy、不看 `Symbol.isConcatSpreadable`。
- **所有权 / 错误 / 调用**：无：纯谓词，不分配、无 error set、不跑用户代码（`objectFromValue` + `isArray`，proxy 不穿透）。唯一调用方 `exec/call_runtime.zig:1333`，realm 名字级联用它把非数组 receiver 的 `concat` 挡在数组实现之外。

### `pushFunctionClosure` (`src/exec/array_ops.zig:151`)

- **签名**：`pub fn pushFunctionClosure( ctx: *core.JSContext, frame: *frame_mod.Frame, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, global: *core.Object, index: usize, ) !void`。
- **作用**：VM 栈原语（不属于 Array 语义）：取常量池第 `index` 项造出字节码函数对象并压栈，`vm_call.zig` 的闭包 opcode 用。
- **实现**：`function.constantAt(index)` 拿不到常量即 `error.InvalidBytecode`；否则 `createBytecodeFunctionObject(ctx, frame, global, value)` 造对象再 `stack.push`。关键调用：`function.constantAt`、`createBytecodeFunctionObject`、`stack.push`。错误：error.InvalidBytecode。
- **所有权 / 错误 / 调用**：新建的函数对象所有权随 `stack.push` 转给操作数栈（栈槽同时是 GC 根）；`function`/`global`/`frame` 借用。error set：常量池下标越界 → `error.InvalidBytecode`（引擎不变量；`runtimeErrorInfo` 不认识它，逃到 native 边界只会兜底成 `Error: InvalidBytecode`），其余是 `createBytecodeFunctionObject` 的 OOM。push 失败时新建对象没有 errdefer，直接留给 GC 回收。唯一调用方 `exec/vm_opcodes.zig:436`（闭包 opcode）。

### `arrayMethodFastCall` (`src/exec/array_ops.zig:164`)

- **签名**：`pub fn arrayMethodFastCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：先确认 callee 是 native callable（用户字节码函数一次 bail）。
- **实现**：先确认 callee 是 native callable（用户字节码函数一次 bail）。iterator 域走 `iteratorCallForNativeRecord`；随后级联 iteration/at/reduce/search/copyWithin/fill/push/pop/shift/unshift/reverse/splice/TA slice/slice/map/flat/sort/by-copy/concat。全部 miss 返回 null，交给通用调用。QuickJS 坐标：quickjs.c:17562、quickjs.c:18220。对不上这个 builtin 时返回 `null`，让上层继续级联。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「这不是数组方法，回退通用调用」；`receiver`/`func`/`args` 都是 VM 操作数栈上的借用（栈帧即根），本函数自身不分配不建根。唯一调用方 `exec/vm_opcodes.zig:600`：它把这里抛出的错误交给 `call_runtime.handleCatchableRuntimeError` 变成 JS 异常并跳 catch，null 则继续走 `callValueOrBytecodeRoot*`。级联的共享前置守卫是开头那句 `callableObjectFromValue(func) orelse return null`。

### `arrayPrototypeNativeRecord` (`src/exec/array_ops.zig:221`)

- **签名**：`pub fn arrayPrototypeNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: ?*core.Object, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype` record 分发中枢：把域内 record id 映射到 `array_ops` 的各叶子实现。
- **实现**：`function_object` 为 null 直接 `error.TypeError`（余下每个 id 都需要物化的函数对象来分 Array/`%TypedArray%`、读 species 与回调）。先试 `arrayIterationModeFromRecordId` 走迭代族，再按 id/mode `switch` 分发到具体叶子（splice 走 `arraySpliceCallImpl`，keys/values/entries 走 `arrayIteratorMethodRecord`）；未知 id 返回 null。关键调用：`arrayIterationModeFromRecordId`、`arrayIterationModeCall`、`arrayToStringCall`、`arrayToLocaleStringCall`、`arrayReduceCall`、`function_object_nonnull.value`、`arrayAtCall`、`arraySearchCall`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示未知 id——`builtin_glue.arrayNativeRecord` 会把 null 再翻成 `error.TypeError`。`function_object` 为 null 直接 `error.TypeError`（记录损坏）；receiver/args 借用。唯一调用方 `exec/builtin_glue.zig:237`，错误最终由 `array_builtin_ops.arrayCall` 经 `managedGenericMagic` thunk 的 `hostResultToValue` 变成 pending JS 异常。

### `buildCallSiteArray` (`src/exec/array_ops.zig:275`)

- **签名**：`pub fn buildCallSiteArray(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue`。
- **作用**：给 `error_stack_ops` 造 `Error.prepareStackTrace` 用的 CallSite 数组。
- **实现**：对象分配后 `errdefer destroyFromHeader`，失败不泄漏。从最内层帧往外遍历快照；`skip_name` 非空时先跳过直到名字匹配的那一帧（含该帧）；`errorStackTraceLimit` 到达即停；每帧 `createCallSiteObject` 后按序号 define，最后同时 `setArrayLength` 与 define `length`。关键调用：`Object.createArray`、`arrayPrototypeFromGlobal`、`Object.destroyFromHeader`、`array.gcHeader`、`errorStackTraceLimit`、`ctx.snapshotBacktraceFrames`、`ctx.freeBacktraceFrameSnapshot`、`exception_ops.resolveBacktraceFunctionName`。
- **所有权 / 错误 / 调用**：返回 owned 数组值，建到一半失败由 `errdefer destroyFromHeader` 回收；backtrace 快照 `frames` 由 `defer ctx.freeBacktraceFrameSnapshot` 释放，每个 CallSite 对象建好即交给数组属性持有。error set：OOM 与 `createCallSiteObject` / `defineOwnProperty` 透传。调用方 `exec/exception_ops.zig:30`、`:48`（经该文件顶部的别名）。

### `aggregateErrorsIterableToArray` (`src/exec/array_ops.zig:301`)

- **签名**：`pub fn aggregateErrorsIterableToArray( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterable: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !*core.Object`。
- **作用**：`AggregateError` 构造用：把 `errors` iterable 按完整迭代器协议跑一遍，收成一个新数组对象（`object_ops` 的 AggregateError 路径唯一调用方）。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。`@@iterator` 缺失/不可调用即 `error.TypeError`；随后反复 `next()`、读 `done`/`value`，逐个 define 到输出数组；结束时 `setArrayLength` 并 define `length`。注意这条路径失败时**不**做 IteratorClose。含循环：按 length 或迭代器步进处理元素。关键调用：`JSValue.undefinedValue`、`runtime.rootValues`、`root_frame.activate`、`root_frame.deactivate`、`getIteratorMethod`、`iterator_method.isUndefined`、`iterator_method.isNull`、`isCallableValue`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 `*core.Object`（不是 JSValue），调用方 `exec/object_ops.zig:731` 拿去挂进 AggregateError 的 `errors`。GC：八个在飞值（iterable / iterator / next / out / next_result / done / item）全部进 `core.runtime.rootValues` 根帧，覆盖用户 `next` 与 getter 回调期间的 GC。error set：不可迭代、`next` 不可调用、`next()` 结果不是对象 → `error.TypeError`，用户回调的异常原样透传；中途失败直接上抛，**不做 IteratorClose**。

### `regExpLegacyNoCaptureSliceValue` (`src/exec/array_ops.zig:370`)

- **签名**：`pub fn regExpLegacyNoCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, kind: RegExpLegacyNoCaptureSlice) ?core.JSValue`。
- **作用**：RegExp 符号方法、exec 结果或 legacy 静态槽。
- **实现**：`legacy.lazy_no_capture_match` 为假或 `legacy.input` 为空就返回 `null`（该 legacy 槽不是惰性无捕获匹配，调用方另想办法）。否则按 kind 切：`.match` 取 `[lazy_match_index, +lazy_match_len)`；`.left` 在 index 为 0 时给空串，否则取 `[0, index)`；`.right` 从 `@min(index+len, lazy_input_len)` 取到输入尾，越界给空串。切片失败（`catch null`）也归 null。
- **所有权 / 错误 / 调用**：返回 owned 的新字符串值，或 null 表示「没有可复算的惰性缓存」；`legacy` 是 `anytype` 的借用视图（RegExp 的 legacy 静态状态），`input` 不被 retain。**无 error set**：`stringSliceValue` / `createStringValue` 的失败一律被 `catch null` 吞掉，OOM 因此表现为一次 miss 而不是异常。调用方 `exec/regexp_ops.zig:580`（lastMatch）、`:582`（leftContext）、`:583`（rightContext），miss 时回退 `regExpLegacySlotValue`。

### `throwRegExpAccessorTypeError` (`src/exec/array_ops.zig:387`)

- **签名**：`pub fn throwRegExpAccessorTypeError(ctx: *core.JSContext, getter_value: core.JSValue) !?core.JSValue`。
- **作用**：legacy RegExp 静态访问器在 receiver 不是 RegExp 时抛 TypeError（用 getter 自己 realm 的 `TypeError.prototype`，消息 "RegExp object expected"）。
- **实现**：getter 必须是带 `nativeFunctionRealm` 的对象且该 realm 就是当前 `ctx`，否则 `error.InvalidBuiltinRegistry`。造好错误对象后 `ctx.throwValue` 并返回 `error.JSException`——正常路径永不返回值。关键调用：`objectFromValue`、`getter_object.nativeFunctionRealm`、`getter_realm.nativeErrorPrototypeObject`、`exception_ops.createNamedErrorWithPrototype`、`ctx.throwValue`。错误：error.InvalidBuiltinRegistry、error.JSException。
- **所有权 / 错误 / 调用**：反常形态：**成功路径也返回 error**——建好带 getter realm 专属原型的 TypeError 值、`ctx.throwValue` 挂成 pending 异常后返回 `error.JSException`，声明里的 `?core.JSValue` 实际永远不会被返回。结构性失配（getter 不是对象、跨 realm、realm 没装 TypeError 原型或 global）返回 `error.InvalidBuiltinRegistry`；错误原型一律取自 getter 自己的 realm，所以签名里不再带调用方的 `global`。调用方 `exec/regexp_ops.zig:366`、`:395` 两个 legacy 访问器，都写成 `_ = try`，把它当「必抛」。

### `createRegExpIndicesArray` (`src/exec/array_ops.zig:398`)

- **签名**：`pub noinline fn createRegExpIndicesArray(rt: *core.JSRuntime, global: *core.Object, found: *const RegExpMatch) !core.JSValue`。
- **作用**：为带 `d` 标志的 exec 结果造 `indices` 数组：下标 0 是整次匹配的 `[start, end]` 对，其后对应各捕获；未参与的捕获写 `undefined`，再挂 named `groups`。
- **实现**：`Object.createArray` 造输出，失败 `errdefer destroyFromHeader`。先 `createRegExpIndexPair(found.index, found.index+found.len)` 写到下标 0。再按 `found.capture_count` 循环：`capture.undefined` 则 `defineSplitValueElement(..., undefined)`，否则再造一对 `[start, start+len]`。最后 `defineRegExpIndicesGroupsProperty` 写 `groups`（无具名捕获则为 `undefined`）。对应 ES `MakeMatchIndicesIndexPairArray`。
- **所有权 / 错误 / 调用**：返回的数组由调用方拥有。`createRegExpMatchArrayFromValue` 在 `has_indices` 时调用并把结果定义为 `indices`。`createRegExpIndexPair` 在 `regexp_fastpath.zig`；groups 在 `object_ops.defineRegExpIndicesGroupsProperty`。失败路径销毁已分配数组。

### `constructArrayBufferNativeRecord` (`src/exec/array_ops.zig:420`)

- **签名**：`pub fn constructArrayBufferNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, function_object: *core.Object, args: []const core.JSValue, new_target: core.JSValue, ) !?core.JSValue`。
- **作用**：`new ArrayBuffer(...)` / `new SharedArrayBuffer(...)` 的 record 构造臂。
- **实现**：函数对象的 native id 必须落在 `.buffer` 域且是两个 buffer 构造器之一，且 `new_target` 与 `func` 同一（子类化时不等）——否则返回 `null` 让通用构造路径接手。零参直接造 0 字节；单个非负 int32 参数走 `*ConstructLength` 快臂；其余交 `arrayBufferConstructWithPrototype`（那里才处理 `maxByteLength` 选项）。关键调用：`function.decodeNativeBuiltinId`、`function_object.nativeFunctionId`、`new_target.sameValue`、`constructorPrototypeObject`、`prototype.deinit`、`typed_array.sharedArrayBufferConstructLength`、`prototype.object`、`typed_array.arrayBufferConstructLength`。
- **所有权 / 错误 / 调用**：返回 owned 的 ArrayBuffer/SharedArrayBuffer 值，或 null 表示「这条记录不归我管」（非 `.buffer` 域、id 不是两个 buffer 构造器、或 `new_target != func` 的子类化）——调用方回退通用构造。`OwnedPrototype` 由 `defer prototype.deinit(ctx.runtime)` 释放，传给 core 的只是它的借用 `object()`。error set：长度/选项强制转换的 `error.TypeError` / `error.RangeError` 与分配 OOM。唯一调用方 `exec/call_runtime.zig:2209`。

### `typedArrayConstructVm` (`src/exec/array_ops.zig:456`)

- **签名**：`pub fn typedArrayConstructVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`new Uint8Array(...)` 一类 TypedArray 构造的 VM 侧入口，按首参数形态分流。
- **实现**：从函数对象取 kind/element size 与其 realm 的 `%ArrayBuffer.prototype%`（缺一即 `error.InvalidBuiltinRegistry`）。无参 → 长度 0；首参非对象 → `typedArrayConstructToIndex` 当长度；首参是 TypedArray → 返回 `null` 交给别的构造路径；首参是 ArrayBuffer/SharedArrayBuffer → 单参走 `typedArrayConstructWithOptions`，多参走 `typedArrayConstructBufferVm`；有 `@@iterator` → `typedArrayConstructFromIterable`；否则按 array-like 走 `typedArrayConstructArrayLikeVm`。关键调用：`function_object.typedArrayKind`、`function_object.typedArrayElementSize`、`function_object.nativeFunctionRealm`、`target_realm.classPrototypeObject`、`typedArrayConstructorPrototypeVm`、`prototype.deinit`、`typedArrayConstructLengthVm`、`prototype.object`。错误：error.InvalidBuiltinRegistry、error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值，或 null——本函数只有 `:493` 一处返回 null（源本身是 TypedArray，交给通用构造路径）；`typedArrayConstructFromIterable` 返回 null 时不是往上传 null，而是继续走 array-like 分支。四个分支各自 `defer prototype.deinit`，`array_buffer_prototype` 与 `function_object` 借用。error set：目标 realm 或其 `%ArrayBuffer.prototype%` 缺失 → `error.InvalidBuiltinRegistry`；非对象首参的 index 强制转换 → `error.TypeError` / `error.RangeError`；其余由各分支透传。唯一调用方 `exec/call_runtime.zig:2203`。

### `typedArrayConstructLengthVm` (`src/exec/array_ops.zig:507`)

- **签名**：`pub fn typedArrayConstructLengthVm( rt: *core.JSRuntime, array_buffer_prototype: *core.Object, prototype: ?*core.Object, element: construct_mod.TypedArrayElement, length: usize, ) !core.JSValue`。
- **作用**：按元素个数造一条自带 backing ArrayBuffer 的 TypedArray。
- **实现**：`length` 超过 `maxInt(u32)` 即 `error.RangeError`；`length * element.size` 用 `std.math.mul` 检溢出；先 `arrayBufferConstructLength` 造 buffer，再 `typedArrayConstructFullBufferOwned` 铺满视图。关键调用：`math.maxInt`、`math.mul`、`typed_array.arrayBufferConstructLength`、`objectFromValue`、`typed_array.typedArrayConstructFullBufferOwned`。错误：error.RangeError、error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值；它新建的 backing ArrayBuffer 的所有权随即由 `typedArrayConstructFullBufferOwned` 转给这个视图，两个 prototype 参数是借用。error set：`length > maxInt(u32)` 或 `length * element.size` 溢出 → `error.RangeError`（后者来自 `std.math.mul`），新建 buffer 不是对象 → `error.TypeError`，其余是分配 OOM。调用方全在本文件：`:481`、`:489`、`:575`。

### `typedArrayConstructBufferVm` (`src/exec/array_ops.zig:521`)

- **签名**：`pub fn typedArrayConstructBufferVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, element: construct_mod.TypedArrayElement, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`new TA(buffer, byteOffset, length)` 形态：先把 offset/length 参数强制成索引，再交给 `typedArrayConstructWithOptions`。
- **实现**：`args[1]`（非 undefined 才算）经 `typedArrayConstructToIndex` 成 byteOffset，`args[2]` 同理成 length；再把强制后的数值重新包成 JSValue，按「有 length / 只有 offset / 都没有」裁出 3/2/1 个参数传下去（保证副作用只跑一次且顺序为 offset→length）。关键调用：`isUndefined`、`typedArrayConstructToIndex`、`lengthIndexValue`、`JSValue.undefinedValue`、`offset_value.isUndefined`、`typed_array.typedArrayConstructWithOptions`。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值；`args[0]` 的 ArrayBuffer 被新视图借用（不拷贝字节），`prototype` 借用。`construct_args` 是栈上数组，`lengthIndexValue` 只产立即数，全程不额外分配。error set：byteOffset / length 的 `typedArrayConstructToIndex` 抛 `error.TypeError` / `error.RangeError`（且这两次强制转换会跑用户 `valueOf`），越界由 `typedArrayConstructWithOptions` 报 RangeError。唯一调用方 `typedArrayConstructVm`（`:500`）。

### `typedArrayConstructArrayLikeVm` (`src/exec/array_ops.zig:551`)

- **签名**：`pub fn typedArrayConstructArrayLikeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, array_buffer_prototype: *core.Object, prototype: ?*core.Object, element: construct_mod.TypedArrayElement, source_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：从 array-like 源（有 `length` 和数字下标、但没有 `@@iterator`）构造 TypedArray。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。先 `[[Get]] length` → `toLengthIndex`，按该长度 `typedArrayConstructLengthVm` 造出结果；能走 `typedArrayConstructArrayLikeOwnDataFast` 就直接返回，否则逐个下标 `[[Get]]` → `typedArrayByCopyCoerceValue` → `typedArraySetIndex`。含循环：按 length 或迭代器步进处理元素。关键调用：`JSValue.undefinedValue`、`runtime.rootValues`、`root_frame.activate`、`root_frame.deactivate`、`getValueProperty`、`toLengthIndex`、`typedArrayConstructLengthVm`、`objectFromValue`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的结果视图，`source_value` 借用。GC：`result_value` / `item` / `coerced` 进 `rootValues` 根帧，因为每次 `getValueProperty` 都可能跑用户 getter 并触发 GC；循环里每个 `propertyAtomFromLengthIndex` 的 atom 由 `defer key.deinit` 退 pin（>2^31 的索引才是真 pin）。error set：`length` 强制转换与用户 getter 的异常透传、`typedArraySetIndex` 的 detached `error.TypeError`、结果不是对象的 `error.TypeError`。调用方 `:507`（array-like 分支）与 `:809`（iterable 收尾）。

### `typedArrayConstructArrayLikeOwnDataFast` (`src/exec/array_ops.zig:597`)

- **签名**：`pub fn typedArrayConstructArrayLikeOwnDataFast( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, result_object: *core.Object, source_object: *core.Object, length: usize, ) !bool`。
- **作用**：array-like 构造的零观察快路径：源是普通对象且下标 0..length-1 是连续的 own data 属性时，直接按 shape 槽位读值，跳过 `[[Get]]`。
- **实现**：源是 Proxy 或有 exotic 方法、或 length 超 `maxInt(u32)` 直接 false。先在 `shapeProps()` 里找 atom 为 `"0"` 的属性下标（找不到则只有 `length == 0` 算成功）；再用 `typedArrayArrayLikeOwnDataFastPathUsable` 校验从该下标起的 length 个槽位；通过后逐个 `getOwnDataPropertyValueAt` 取值、coerce、写入结果，返回 true。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。含循环：按 length 或迭代器步进处理元素。关键调用：`source_object.proxyTarget`、`source_object.hasExoticMethods`、`math.maxInt`、`source_object.shapeProps`、`Flags.fromBits`、`prop_flags.isAccessor`、`atom.atomFromUInt32`、`typedArrayArrayLikeOwnDataFastPathUsable`。
- **所有权 / 错误 / 调用**：不产出值，返回 bool：true = 已整段写完，false = 调用方改走通用属性循环。`item` / `coerced` 进 `rootValues` 根帧。注意半途 false 的语义——`getOwnDataPropertyValueAt` 落空时已经写进目标的前缀元素不回滚，调用方 `typedArrayConstructArrayLikeVm`（`:578`）从索引 0 重写一遍覆盖它们，结果仍然正确。error set：`typedArrayByCopyCoerceValue` 与 `typedArraySetIndex` 透传（快路只接受非对象元素，所以不会跑用户 ToPrimitive）。

### `typedArrayArrayLikeOwnDataFastPathUsable` (`src/exec/array_ops.zig:640`)

- **签名**：`pub fn typedArrayArrayLikeOwnDataFastPathUsable(source_object: *core.Object, first_property: usize, length: usize) bool`。
- **作用**：判断从 `first_property` 开始的 length 个 shape 槽位是否正好是 0..length-1 的非 accessor、非 deleted、非对象值的 own data 属性。
- **实现**：逐个槽位比对：越界、atom 不等于对应数字下标、deleted、accessor、`asDataAt` 取不到、或存的是对象（可能触发 valueOf）→ 立刻 false；全通过 true。含循环：按 length 或迭代器步进处理元素。关键调用：`source_object.shapeProps`、`Flags.fromBits`、`atom.atomFromUInt32`、`prop_flags.isAccessor`、`source_object.asDataAt`、`stored.isObject`。
- **所有权 / 错误 / 调用**：无：纯只读谓词，只看 shape 属性与 own data 槽，不分配、无 error set、不触发任何用户代码（遇到对象元素即判 false，把 ToPrimitive 留给通用路径）。唯一调用方 `typedArrayConstructArrayLikeOwnDataFast`（`:621`）。

### `typedArrayConstructorPrototypeVm` (`src/exec/array_ops.zig:654`)

- **签名**：`pub fn typedArrayConstructorPrototypeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !object_ops.OwnedPrototype`。
- **作用**：解析 TypedArray 构造用的实例原型：先读 `constructor.prototype`，不是对象时回落到该 kind 在 getter realm 里的 class prototype。
- **实现**：`[[Get]] prototype` 是对象就直接包成 `OwnedPrototype`；否则按 `typedArrayKind()` 取构造器名（取不到则 `fromObject(null)`，即用引擎默认原型），再经 `constructorClassPrototypeId` 换成 class id，从 `nativeFunctionRealm` 的 `classPrototypeObject` 取（realm 或 prototype 缺失是 `error.InvalidBuiltinRegistry`）。关键调用：`getValueProperty`、`prototype_value.isObject`、`typedArrayNameFromKind`、`function_object.typedArrayKind`、`OwnedPrototype.fromObject`、`function_object.nativeFunctionRealm`、`object_ops.constructorClassPrototypeId`、`realm.classPrototypeObject`。错误：error.InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：返回 `object_ops.OwnedPrototype`，调用方**必须** `defer prototype.deinit(ctx.runtime)`——五个调用方（`:479`、`:487`、`:495`、`:505`、`:805`）都成对写了。`.value` 形态持有从 `constructor.prototype` 读来的值（可能跑用户 getter），`fromObject` 形态只是借用 realm 的 class 原型。error set：用户 getter 的异常透传；`nativeFunctionRealm` 或 `classPrototypeObject` 缺失 → `error.InvalidBuiltinRegistry`；认不出构造器名时返回 null 原型而不是报错。

### `typedArrayConstructToIndex` (`src/exec/array_ops.zig:671`)

- **签名**：`pub fn typedArrayConstructToIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !usize`。
- **作用**：TypedArray / ArrayBuffer 构造与 `byteOffset`、`length`、`maxByteLength` 这类参数的 ToIndex 强制：把任意 JS 值折成 usize，非法值抛 RangeError / TypeError。
- **实现**：先 `toPrimitiveForNumber` 跑用户可见的 `valueOf` / `Symbol.toPrimitive`，结果是 BigInt 直接 `error.TypeError`；`toNumberValue` 之后按 ToIndex 第一步把 NaN 记作 0；非有限值 → `error.RangeError`；`@trunc` 后为负 → RangeError；恰为 0 直接返回 0；大于 2^53−1（源码里的 `9007199254740991.0`）→ RangeError；其余 `@intFromFloat` 返回。
- **所有权 / 错误 / 调用**：返回 usize，不分配、不建根，但会跑 `toPrimitiveForNumber`（用户 `valueOf` / `Symbol.toPrimitive` 在此可见，可能 detach buffer，调用方须在其后重新校验）。error set：BigInt 入参 → `error.TypeError`；非有限、负数、超过 2^53-1 → `error.RangeError`；NaN 按 0。调用方 14 处：`builtin_glue.zig:311`/`:315`/`:351`/`:367`、`class_init_ops.zig:87`，其余 9 处都在本文件的 buffer/TypedArray 构造族（`:486`、`:533`、`:538`、`:702`、`:721`、`:1069`、`:6789`、`:6795`、`:6798`）。

### `arrayBufferConstructWithPrototype` (`src/exec/array_ops.zig:690`)

- **签名**：`pub fn arrayBufferConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, prototype: ?*core.Object, shared: bool, ) !core.JSValue`。
- **作用**：`new ArrayBuffer(len, opts)` 与 `new SharedArrayBuffer(len, opts)` 的共用构造体，`shared` 形参选走哪一个 core 分配入口。
- **实现**：首参缺席按 0，否则 `typedArrayConstructToIndex` 做 ToIndex（用户 `valueOf` 副作用在此发生）；再 `arrayBufferMaxByteLengthOption` 从第二参 options 里解析 `maxByteLength`，它是否为 null 决定新 buffer 可不可 resize / grow；最后按 `shared` 调 `core.typed_array.sharedArrayBufferConstructLength` 或 `arrayBufferConstructLength`，并把调用方解析好的 `prototype`（`new.target` 派生结果）交给它。
- **所有权 / 错误 / 调用**：返回 owned 的 ArrayBuffer 或 SharedArrayBuffer 值，`prototype` 借用。求值次序是可观察契约：先 `args[0]` 的 byteLength 强制转换，再读选项对象的 `maxByteLength`，两次都可能跑用户代码。error set：两次强制转换的 `error.TypeError` / `error.RangeError`、`maxByteLength < byteLength` 的 `error.RangeError`、分配 OOM。调用方 `exec/call_runtime.zig:2328` 与本文件 `:456`。

### `arrayBufferMaxByteLengthOption` (`src/exec/array_ops.zig:707`)

- **签名**：`pub fn arrayBufferMaxByteLengthOption( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, byte_length: usize, ) !?usize`。
- **作用**：解析 `new ArrayBuffer(len, { maxByteLength })` 第二个参数里的 `maxByteLength` 选项；返回 null 表示没给，于是新 buffer 是固定长度的。
- **实现**：第二个参数缺席、是 undefined 或不是对象就返回 `null`（没有 options）；否则 `[[Get]] maxByteLength`，仍是 undefined 也返回 `null`；强制成索引后小于 `byte_length` 即 `error.RangeError`。关键调用：`isUndefined`、`isObject`、`getValueProperty`、`max_value.isUndefined`、`typedArrayConstructToIndex`。错误：error.RangeError。
- **所有权 / 错误 / 调用**：返回 `?usize`，不分配；第二参数不是对象、或没有 `maxByteLength` 属性一律返回 null（= 非 resizable）。error set：`maxByteLength < byteLength` → `error.RangeError`，属性 getter 与 `typedArrayConstructToIndex` 的异常透传。调用方 `exec/function_ops.zig:90`（经别名）与本文件 `:705`。

### `typedArrayConstructFromIterable` (`src/exec/array_ops.zig:730`)

- **签名**：`pub fn typedArrayConstructFromIterable( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, metadata_object: ?*core.Object, ) !?core.JSValue`。
- **作用**：`new Uint8Array(iterable)` 这一支：先按迭代器协议把可迭代对象抽干进一个临时数组，再用它构造 TypedArray；返回 null 表示「这不是可迭代源」，让调用方回落到 length / ArrayBuffer / array-like 各臂。
- **实现**：入口四道否决返回 `null`：首参缺席或不是对象、首参本身是 TypedArray / `array_buffer` / `shared_array_buffer`、`@@iterator` 取到 undefined 或 null；`@@iterator` 存在但不可调用则是 `error.TypeError`。之后六个局部值（iterator、values_value、next_method、next、done、item）进 `core.runtime.rootValues` root frame——循环里每一步都会跑用户代码、随时可能触发 GC。主循环依次 `next()` → 结果必须是对象 → 读 `done` → 读 `value`，其中任一步出错或结果非对象都先 `iteratorCloseValue` 关闭迭代器再上抛；取到的值按序 `defineOwnProperty` 写进临时数组，循环退出后 `setArrayLength(index)`。收尾：收集完成后不再读原 iterator。构造器若是原生 TypedArray 构造器（`typedArrayElementSize() != 0` 且 `typedArrayKind() != .none`），就用 `typedArrayConstructorPrototypeVm` 解析实例原型（`defer prototype.deinit`）、从 `nativeFunctionRealm` 取该 realm 的 %ArrayBuffer.prototype%，走 `typedArrayConstructArrayLikeVm`；否则（子类或用户构造器）`error.TypeError`。不调用 `constructValue`。
- **所有权 / 错误 / 调用**：返回 owned 的结果值，或 null 表示不适用（首参不是对象、是 TypedArray/ArrayBuffer/SharedArrayBuffer、或没有 `Symbol.iterator`），调用方继续走别的构造分支。GC：六个在飞值进 `rootValues`，中间收集数组由 `values_value` 持根。error set：`Symbol.iterator` 不可调用、`next` 不可调用、`next()` 结果不是对象、非原生 TypedArray 收尾 → `error.TypeError`；**next / done / value 三处失败都先 `iteratorCloseValue` 再重抛原错误，而 close 自己用的是 `try`，它的错误会盖掉原错误**。调用方 `typedArrayConstructVm`。

### `arrayBufferAccessor` (`src/exec/array_ops.zig:822`)

- **签名**：`pub fn arrayBufferAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype` 上五个 getter —— `byteLength`、`detached`、`maxByteLength`、`resizable`、`immutable` —— 的共用实现体，按传进来的属性名选分支。
- **实现**：receiver 必须是 `class_id == core.class.ids.array_buffer` 的对象，否则 TypeError（SharedArrayBuffer 在这里也被拒，它走 `sharedArrayBufferAccessor`）。`byteLength`：已 detach 报 0，否则 `byteStorage().len`。`detached`：直接 `arrayBufferDetached()`。`maxByteLength`：已 detach 报 0，否则 `arrayBufferMaxByteLength()`，非 resizable buffer 回落到当前字节数。`resizable`：`arrayBufferMaxByteLength() != null`。`immutable`：`core.object.arrayBufferIsImmutable`。名字一个都不匹配时 `error.TypeError`。
- **所有权 / 错误 / 调用**：返回值都不分配堆：`lengthIndexValue` 给的是 int32/float64 立即数，`detached`/`resizable`/`immutable` 是 boolean 立即数；`receiver` 借用。error set：receiver 不是对象或 class 不是 `array_buffer`、以及认不出的访问器名 → `error.TypeError`。唯一调用方 `exec/builtin_glue.zig:249`，`accessor` 是它按访问器记录传进来的静态名字。

### `sharedArrayBufferAccessor` (`src/exec/array_ops.zig:844`)

- **签名**：`pub fn sharedArrayBufferAccessor(receiver: core.JSValue, accessor: []const u8) !core.JSValue`。
- **作用**：`SharedArrayBuffer.prototype` 上三个 getter —— `byteLength`、`maxByteLength`、`growable`。
- **实现**：receiver 必须是 `class_id == core.class.ids.shared_array_buffer`，否则 TypeError。`byteLength` 直接给 `byteStorage().len`：共享 buffer 没有 detach 概念，所以不像 `arrayBufferAccessor` 那样先判 detached。`maxByteLength` 在非 growable 时回落到当前长度；`growable` 即 `arrayBufferMaxByteLength() != null`。
- **所有权 / 错误 / 调用**：同 `arrayBufferAccessor` 的立即数返回与借用约定，但 class 必须是 `shared_array_buffer`（ArrayBuffer 走到这里就是 `error.TypeError`）。与 `arrayBufferAccessor` 不同，签名里没有 `ctx`——shared buffer 没有 immutable 概念，不需要 runtime（那个从不被读的形参已删）。唯一调用方 `exec/builtin_glue.zig:252`。

### `arrayBufferIsView` (`src/exec/array_ops.zig:859`)

- **签名**：`pub fn arrayBufferIsView(args: []const core.JSValue) core.JSValue`。
- **作用**：`ArrayBuffer.isView(x)` 静态方法的实现体。
- **实现**：无参或首参不是对象 → false；否则 `isTypedArrayObject(object) or class_id == dataview` —— DataView 也算 view。
- **所有权 / 错误 / 调用**：无：纯谓词，返回 boolean 立即数，不分配、无 error set、不跑用户代码（`args` 借用，空参按 false）。调用方 `exec/builtin_glue.zig:247`（记录路径）与 `exec/call_runtime.zig:1175`（realm 名字级联）。

### `arrayBufferPrototypeNativeRecord` (`src/exec/array_ops.zig:865`)

- **签名**：`pub fn arrayBufferPrototypeNativeRecord(ctx: *core.JSContext, receiver: core.JSValue, id: u32, args: []const core.JSValue) !?core.JSValue`。
- **作用**：`ArrayBuffer.prototype` 与 `SharedArrayBuffer.prototype` 全部方法的 record 分发中枢：先按 receiver 的 class 选表，再按 record id 落到具体的 `*Call` 叶子。
- **实现**：receiver 不是对象直接 `null`。共享 buffer 一侧：`slice`/`resize`/`transfer`/`transferToFixedLength`/`sliceToImmutable`/`transferToImmutable` 这几个 ArrayBuffer 专有 id 一律 `error.TypeError`（跨类借用被拒），只认 `SharedArrayBufferPrototypeMethod.slice`（转 `arrayBufferSliceCall(..., shared = true)`）与 `.grow`（转 `sharedArrayBufferGrowCall`）。非共享一侧对称：两个 Shared 专有 id 报 TypeError，其余各自转到 `arrayBufferSliceCall(shared = false)`、`arrayBufferSliceToImmutableCall`、`arrayBufferResizeCall`、`arrayBufferTransferCall`、`arrayBufferTransferToImmutableCall`，其中 `transfer` 与 `transferToFixedLength` 共用一个叶子、靠 `fixed_length` 布尔区分。各臂在这里补齐缺省实参：slice 的 start 缺省 `JSValue.int32(0)`、end 缺省 `undefined`；resize/grow 的新长度缺省 `int32(0)`，transfer 系列缺省 `undefined`。class 既非 array_buffer 也非 shared_array_buffer、或 id 落不进表，都返回 `null` 让上层级联继续找。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「receiver 不是 buffer / id 不归我管」，让调用方继续往后找。跨类误用不是 null 而是显式 `error.TypeError`（SharedArrayBuffer 上调 `slice`/`resize`/`transfer` 系、ArrayBuffer 上调 `grow`），缺参按 `int32(0)` 或 undefined 补齐。唯一调用方 `exec/builtin_glue.zig:260`。

### `arrayBufferSliceCall` (`src/exec/array_ops.zig:923`)

- **签名**：`pub fn arrayBufferSliceCall( ctx: *core.JSContext, receiver: core.JSValue, object: *core.Object, start_value: core.JSValue, end_value: core.JSValue, shared: bool, ) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype.slice` 与 `SharedArrayBuffer.prototype.slice`（由 `shared` 选形）：走 species 构造出目标 buffer 再拷贝字节。
- **实现**：`ctx.global` 为空（非 VM 上下文，看不到 species）时直接退到 core 的纯版本 `typed_array.sharedArrayBufferSlice` / `arrayBufferSlice`。正常路径：源已 detach → TypeError；非共享且源 immutable → TypeError；`relativeSliceIndex` 把 start/end 规范化（负值相对末尾，end 为 undefined 时取 len），长度取 `end > start ? end - start : 0`。然后 `arrayBufferSpeciesConstructor` 选构造器、`constructValueOrBytecode` 造出结果，紧接一串针对 species 返回值的校验，全部 TypeError：不是对象、class 不匹配（shared 要 shared_array_buffer、否则要 array_buffer）、非共享结果是 immutable、`sameValue(receiver)`（species 把源 buffer 原样还回）、结果已 detach、结果容量小于 length。之后再复查一次源 buffer——species 构造器里跑过用户代码，可能已 detach 或缩容——通过才 `@memcpy` 拷字节；length 为 0 时连拷贝都跳过。
- **所有权 / 错误 / 调用**：返回 owned 的新 buffer——它由 species 构造器产出，**可能是用户对象**，所以后面整串校验（类不对 / 与源同一个对象 / 已 detached / 容量不足）全部是 `error.TypeError`。`ctx.global` 为空时整个退到 bare-runtime 的 `core.typed_array.*Slice`。索引强制转换和 species 构造都能跑用户代码并 detach 源，因此 `@memcpy` 之前重新校验源的 detached 与长度。error set：上述 `error.TypeError` 加索引强制转换透传的 RangeError。调用方 `:883`（shared）与 `:900`（普通）。

### `arrayBufferSpeciesConstructor` (`src/exec/array_ops.zig:958`)

- **签名**：`pub fn arrayBufferSpeciesConstructor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, shared: bool, ) !core.JSValue`。
- **作用**：`slice` 用的 SpeciesConstructor：在 %ArrayBuffer% / %SharedArrayBuffer% 默认构造器与用户 `Symbol.species` 之间选一个。
- **实现**：默认构造器从 global 上按名字取（`shared` 决定是 `"SharedArrayBuffer"` 还是 `"ArrayBuffer"`，名字现场 `internAtom`）。随后读 receiver 的 `constructor` 属性：undefined 用默认；不是对象 → TypeError；是对象则再读它的 `Symbol.species`，undefined 或 null 仍用默认；剩下的必须通过 `isConstructorLike`，否则 TypeError。两次属性读都走 `getValueProperty`，因此用户 getter 会被执行。
- **所有权 / 错误 / 调用**：返回 owned 的构造器值：默认分支是 `global` 上 `ArrayBuffer` / `SharedArrayBuffer` 的当前属性值（不是硬编码 intrinsic），否则是用户的 `Symbol.species`；`internAtom` 新建的 atom 由运行时 atom 表持有。error set：`constructor` 不是对象、species 不是构造器、取不到 `Symbol.species` 预定义 atom → `error.TypeError`，属性 getter 异常透传。唯一调用方 `arrayBufferSliceCall`（`:945`）。

### `arrayBufferSliceToImmutableCall` (`src/exec/array_ops.zig:984`)

- **签名**：`pub fn arrayBufferSliceToImmutableCall( ctx: *core.JSContext, receiver: core.JSValue, object: *core.Object, start_value: core.JSValue, end_value: core.JSValue, ) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype.sliceToImmutable`：切出一段并直接产出不可变 buffer。
- **实现**：`ctx.global` 为空时退到 core 的 `typed_array.arrayBufferSliceToImmutable`。正常路径：源已 detach → TypeError；源本身已 immutable → TypeError；`relativeSliceIndex` 规范化 start/end 后交给 `typed_array.arrayBufferSliceToImmutableRange`。与 `arrayBufferSliceCall` 的关键差别是结果类型写死，不查 species、不构造用户对象，因此也不需要构造后的那一串复查。
- **所有权 / 错误 / 调用**：返回 owned 的新 immutable buffer；与 `arrayBufferSliceCall` 不同，它**不走 species**，直接交给 `core.typed_array.arrayBufferSliceToImmutableRange`，所以没有用户对象参与、也不需要复检。`ctx.global` 为空时退到 bare-runtime 版本。error set：源 detached 或已 immutable → `error.TypeError`，索引强制转换透传。唯一调用方 `:905`。

### `arrayBufferResizeCall` (`src/exec/array_ops.zig:1000`)

- **签名**：`pub fn arrayBufferResizeCall(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype.resize(newLength)` 的实现体，只对带 `maxByteLength` 的 resizable buffer 成立。
- **实现**：对照 qjs `js_array_buffer_resize`（quickjs.c:57216-57237）的判序：class 检查 → immutable TypeError → `arrayBufferLengthNumber` 跑长度强制（用户 valueOf 副作用先发生）→ detached TypeError → 非 resizable（无 `maxByteLength`）TypeError → 最后才是范围 RangeError。范围用 spec 的 ToIntegerOrInfinity 语义，不抄 qjs `JS_ToInt64` 的取模回绕。关键调用：`objectFromValue`、`object.arrayBufferIsImmutable`、`arrayBufferLengthNumber`、`object.arrayBufferDetached`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：不新建对象，返回 `arrayBufferResizeLength` 的结果（undefined）；`receiver` 借用。错误次序是与 qjs 对齐的可观察契约：class 检查 → immutable `error.TypeError` → 长度强制转换（用户 `valueOf` 在这一步运行，可能 detach）→ detached `error.TypeError` → 不可 resize `error.TypeError` → 越界 `error.RangeError`。唯一调用方 `:909`。

### `sharedArrayBufferGrowCall` (`src/exec/array_ops.zig:1017`)

- **签名**：`pub fn sharedArrayBufferGrowCall(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue`。
- **作用**：`SharedArrayBuffer.prototype.grow(newLength)` 的实现体，只对带 `maxByteLength` 的 growable 共享 buffer 成立。
- **实现**：对照 qjs 带 SHARED_ARRAY_BUFFER magic 的 `js_array_buffer_resize`（quickjs.c:57216，入口 quickjs.c:57354）：class 检查先于长度强制，「不可 grow」的 TypeError 先于范围 RangeError。关键调用：`objectFromValue`、`arrayBufferLengthNumber`、`object.arrayBufferMaxByteLength`、`@floatFromInt`、`typed_array.sharedArrayBufferGrowLength`、`@intFromFloat`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：同 `arrayBufferResizeCall` 的返回与借用约定；次序差异是 class 检查在强制转换之前、「不可 grow」的 `error.TypeError` 在 `error.RangeError` 之前（对齐 qjs 的 SHARED_ARRAY_BUFFER magic 分支）。唯一调用方 `:887`。

### `arrayBufferLengthNumber` (`src/exec/array_ops.zig:1034`)

- **签名**：`fn arrayBufferLengthNumber(ctx: *core.JSContext, value: core.JSValue) !f64`。
- **作用**：`resize` / `grow` 长度参数强制的前一半：跑完 ToNumber（含用户副作用）给出截断后的 f64，范围校验故意留给调用方。
- **实现**：`undefined` 直接返回 0。非 VM 上下文（`ctx.global == null`）只可能拿到基本值，走窄版 `value_ops.toIndexUsize` 再转 f64。正常路径 `toPrimitiveForNumber` → BigInt 报 `error.TypeError` → `toNumberValue`，NaN 记作 0，其余 `@trunc`（ToIntegerOrInfinity）。这里不做范围判断是刻意的：qjs `js_array_buffer_resize`（quickjs.c:57229-57238）把范围 RangeError 排在 detached / not-resizable 的 TypeError 之后，只有把强制与校验拆开，`arrayBufferResizeCall` 才能复刻这个判序。
- **所有权 / 错误 / 调用**：私有；返回 f64，不分配、不建根。它只做 ToNumber + 截断，**故意把范围校验留给调用方**，好让 detached / 不可 resize 的 TypeError 排在 RangeError 前面。会跑用户 ToPrimitive。error set：BigInt → `error.TypeError`；没有 `ctx.global` 的 bare 路径改走 `value_ops.toIndexUsize` 并透传它的 RangeError。调用方 `arrayBufferResizeCall`（`:1014`）与 `sharedArrayBufferGrowCall`（`:1027`）。

### `arrayBufferTransferCall` (`src/exec/array_ops.zig:1048`)

- **签名**：`pub fn arrayBufferTransferCall(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue, fixed_length: bool) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype.transfer` 与 `.transferToFixedLength` 的共用实现体（`fixed_length` 选形）：把字节所有权移交给新 buffer，原 buffer 随之 detach。
- **实现**：receiver 不是对象 → TypeError。新长度的缺省值取原 buffer 当前 `byteStorage().len`，receiver 的 class 不是 `array_buffer` 时缺省取 0；交 `arrayBufferLengthArgument` 解析后调 `core.typed_array.arrayBufferTransferLength`。class 校验、detach 判定与实际搬运都落在 core 一侧，这里只做参数拼装。
- **所有权 / 错误 / 调用**：返回 owned 的新 buffer；源 buffer 的字节所有权被 `arrayBufferTransferLength` 搬走并把源 detach——调用方此后不得再用源的 `byteStorage`。非 ArrayBuffer 的 receiver 在这里不报错，只是 fallback 长度取 0，由 core 侧判定。error set：receiver 不是对象 → `error.TypeError`，长度强制转换透传。调用方 `:913`（transfer）与 `:917`（transferToFixedLength）。

### `arrayBufferTransferToImmutableCall` (`src/exec/array_ops.zig:1055`)

- **签名**：`pub fn arrayBufferTransferToImmutableCall(ctx: *core.JSContext, receiver: core.JSValue, new_length_value: core.JSValue) !core.JSValue`。
- **作用**：`ArrayBuffer.prototype.transferToImmutable`：移交字节并把结果 buffer 钉成不可变。
- **实现**：比 `arrayBufferTransferCall` 多一道本地 class 检查——receiver 必须是 `array_buffer`，否则 TypeError（所以没有那条 fallback 0 的缺省长度）；缺省新长度固定取原 `byteStorage().len`，经 `arrayBufferLengthArgument` 后调 `core.typed_array.arrayBufferTransferToImmutableLength`。
- **所有权 / 错误 / 调用**：同上，但先做 class 检查（非 `array_buffer` 直接 `error.TypeError`），fallback 长度取源的当前字节数；产出的 immutable buffer owned，源被 detach。唯一调用方 `:921`。

### `arrayBufferLengthArgument` (`src/exec/array_ops.zig:1062`)

- **签名**：`pub fn arrayBufferLengthArgument(ctx: *core.JSContext, value: core.JSValue, undefined_length: ?usize) !usize`。
- **作用**：给 `transfer` 系列解析可选的新长度实参；`undefined` 时回落到调用方传来的缺省值。
- **实现**：`undefined` 返回 `undefined_length orelse 0`；非 VM 上下文走窄版 `value_ops.toIndexUsize`；正常路径复用 `typedArrayConstructToIndex` 做完整 ToIndex，因此用户 `valueOf` 副作用、BigInt 的 TypeError 与越界 RangeError 都与构造器参数一致。
- **所有权 / 错误 / 调用**：返回 usize，不分配；undefined 用调用方给的 `undefined_length`（再 null 就按 0）。有 `ctx.global` 时走完整的 `typedArrayConstructToIndex`（会跑用户 ToPrimitive），否则退到 bare 的 `value_ops.toIndexUsize`。error set：这两者的 `error.TypeError` / `error.RangeError`。调用方 `:1055`、`:1062`。

### `relativeSliceIndex` (`src/exec/array_ops.zig:1068`)

- **签名**：`pub fn relativeSliceIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, len: usize, undefined_is_len: bool, ) !usize`。
- **作用**：把相对下标（负从尾）夹到 [0, length]。
- **实现**：`undefined_is_len` 且值是 undefined 时直接返回 `len`（`slice` 的 end 缺省）。否则 `toPrimitiveForNumber` → BigInt 报 `error.TypeError` → `toNumberValue`；NaN 与 −∞ → 0，+∞ → `len`；`@trunc` 后为负时按 `len + truncated` 从尾部折回并夹到 [0, len]，非负时超过 `len` 取 `len`，其余原样转 usize。
- **所有权 / 错误 / 调用**：返回 usize，不分配、不建根，但会跑 `toPrimitiveForNumber`：调用方必须假定长度在这之后可能已失效（buffer 被 detach / resize）。error set 只有 BigInt 的 `error.TypeError`——数值侧一律夹紧而不报错（NaN 与 -∞ → 0，+∞ 与超长 → len，负数从尾部折回）。调用方本文件 `:942`/`:943`（slice）与 `:999`/`:1000`（sliceToImmutable）；`core/typed_array.zig` 里另有一个只收 `rt`、不跑用户代码的同名函数，不是这一个。

### `typedArrayAccessor` (`src/exec/array_ops.zig:1101`)

- **签名**：`pub fn typedArrayAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue`。
- **作用**：`%TypedArray%.prototype` 上 `buffer`、`byteLength`、`byteOffset`、`length` 四个 getter 外加 `Symbol.toStringTag` 的共用实现体。
- **实现**：`[Symbol.toStringTag]` 单独放在最前面且不抛异常：receiver 不是对象或不是 TypedArray 时按 spec 返回 `undefined`，是则用 `typedArrayNameFromKind` 给出 `"Uint8Array"` 之类的字符串值。余下四个 getter 先要求 receiver 是 TypedArray，否则 TypeError：`buffer` 返回内部 buffer 值（缺失即 TypeError）；`byteLength` 走 `core.object.typedArrayByteLength`（length-tracking 视图会现算）；`byteOffset` 走 `typedArrayEffectiveByteOffset`；`length` 走 `typedArrayLength`。名字都对不上回 TypeError。
- **所有权 / 错误 / 调用**：返回 owned 值：`[Symbol.toStringTag]` 新建字符串（非 TypedArray 时给 undefined 而不是抛），`buffer` 返回借用自视图的 buffer 值，其余是 `lengthIndexValue` 的立即数。error set：receiver 不是 TypedArray 或访问器名认不出 → `error.TypeError`，`typedArrayByteLength` / `typedArrayEffectiveByteOffset` / `typedArrayLength` 的 detached 错误透传。唯一调用方 `exec/builtin_glue.zig:258`。

### `typedArrayNameFromKind` (`src/exec/array_ops.zig:1126`)

- **签名**：`pub fn typedArrayNameFromKind(kind: u8) ?[]const u8`。
- **作用**：把 TypedArray 的内部 kind 码翻成构造器名字符串（`"Float64Array"` 等），供 `Symbol.toStringTag` 与原型/类 id 解析使用。
- **实现**：整条转发 `core.typed_array_names.nameFromKind(kind)`；kind 不是已知 TypedArray 种类时返回 `null`，调用方各自决定回落成 `undefined` 还是错误。
- **所有权 / 错误 / 调用**：无：一行转发 `core.typed_array_names.nameFromKind`，返回的是静态只读字符串切片（不分配，调用方不得释放），无 error set。调用方本文件三处：`:668`（构造器原型识别）、`:1109`（toStringTag）、`:2401`（species 构造器名）。

### `typedArraySetCall` (`src/exec/array_ops.zig:1130`)

- **签名**：`pub fn typedArraySetCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`%TypedArray%.prototype.set`：把 TypedArray 或 array-like 源写进目标视图的 offset 处。
- **实现**：receiver 不是 TypedArray 时——是 TypedArray 域的方法就 TypeError，否则返回 `null` 让级联继续；随后 detached / OOB / immutable buffer 三查。offset 由 `toIntegerOrInfinityForArrayByCopy` 强制，负数或非有限是 RangeError；**强制可能 detach/resize 视图，所以之后重新查一遍 detached/OOB 再读 target length**。源是 TypedArray 且与目标同 kind 时走 `@memmove` 整段字节拷贝（同 buffer 重叠也安全，对应 qjs `js_typed_array_set_internal`，quickjs.c:57584-57588）；kind 不同则先把源元素逐个快照进一块 rooted 缓冲再写，避免边读边写串味。源不是 TypedArray 时按 array-like 走：`[[Get]] length` → 逐下标 `[[Get]]` → `typedArraySetElementValue`。越界统一 RangeError。含循环：按 length 或迭代器步进处理元素。关键调用：`isTypedArrayPrototypeMethod`、`objectFromValue`、`object.isTypedArrayObject`、`object.typedArrayDetached`、`object.typedArrayOutOfBounds`、`object.typedArrayRejectImmutableBuffer`、`JSValue.int32`、`toIntegerOrInfinityForArrayByCopy`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 undefined 立即数，或 null 表示「receiver 不是 TypedArray 且调用的也不是 `%TypedArray%.prototype.set`」——这个区分由 `isTypedArrayPrototypeMethod` 读函数对象的 builtin marker 做出，是它就报 `error.TypeError` 而不是 null。所有权/GC：元素类不同的臂先 `rt.memory.alloc` 一块快照缓冲，用 `ValueSliceRoot` 把**已填部分**挂成根（`rooted_values = values[0..filled]`），`defer` 里先把槽清成 undefined 再 free（测试 `:1237` 用 GC 探针钉住 heap BigInt 不被回收）；同类臂直接 `@memmove` 字节，允许同 buffer 重叠。error set：detached / out-of-bounds / immutable buffer / 源不是对象 → `error.TypeError`，offset 与长度越界 → `error.RangeError`；offset 强制转换可能 detach，所以其后重新校验两侧。调用方 `exec/call_runtime.zig:1177`、`:1260`。

### `typedArraySetElementValue` (`src/exec/array_ops.zig:1282`)

- **签名**：`pub fn typedArraySetElementValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, index: usize, value: core.JSValue, ) !void`。
- **作用**：往 TypedArray 的某个下标写一个元素，写前先做 ToPrimitive 强制；`%TypedArray%.prototype.set`（array-like 源）、`%TypedArray%.from`、`%TypedArray%.of` 的逐元素写入步骤都用它。
- **实现**：值是对象时先 `toPrimitiveForNumber` 跑用户 `valueOf` / `Symbol.toPrimitive`（副作用可能 detach 或 resize 目标 buffer，越界由下一步的 core 写入自行处理），基本值原样透传；随后 `core.typed_array.typedArraySetIndex` 按元素类型做数值转换并写入，其返回值在这里被 `_ =` 丢弃。
- **所有权 / 错误 / 调用**：无返回值；`value` 借用，对象要先 `toPrimitiveForNumber`（用户 `valueOf` 在此运行，可能 detach 目标），`typedArraySetIndex` 的返回值被 `_ =` 丢弃——越界写按 spec 静默成功。不分配、不建根（在飞值的根由各调用方的根帧提供）。error set：ToPrimitive 与 set 的透传。调用方本文件 `:1232`（`typedArraySetCall` 的通用臂）、`:4458`、`:4652`。

### `addCollectionEntriesFromArray` (`src/exec/array_ops.zig:1297`)

- **签名**：`pub fn addCollectionEntriesFromArray( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, collection_value: core.JSValue, kind: u32, source: *core.Object, adder: core.JSValue, ) !void`。
- **作用**：`new Map/Set/WeakMap/WeakSet(array)` 的快路径：把源数组的元素逐个喂给集合的 adder。
- **实现**：按 `source.arrayLength()` 逐下标 `[[Get]]`；`kind == 1 或 3`（entry 形态，Map/WeakMap）要求元素是对象，再读它的 `0`/`1` 两个下标当 key/value 调 adder；否则整个元素单参调 adder。含循环：按 length 或迭代器步进处理元素。关键调用：`source.arrayLength`、`getValueProperty`、`source.value`、`atom.atomFromUInt32`、`property_ops.expectObject`、`entry.value`、`callCollectionAdderFromVm`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：无返回值；entry / key / value 全是借用，最终所有权由 `adder`（`Map.prototype.set` / `Set.prototype.add`）调用接管。`source` 借用，按 `arrayLength()` 逐个索引读，getter 与 adder 都可能跑用户代码。error set：kind 1/3 的 entry 不是对象 → `error.TypeError`，getter 与 adder 的异常原样透传。唯一调用方 `exec/builtin_glue.zig:578`，它在集合构造路径里 `catch` 后再处理。

## 覆盖核对

- 清单函数数（本文件分到）: 44（`src/exec/array_ops.zig` 全文件 231）
- 本文标题覆盖: 44
- 未覆盖: 无
