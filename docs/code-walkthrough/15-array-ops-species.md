# 15 — `array_ops.zig`：species、from、sort、by-copy、flat

从 `arraySpeciesCreate` 到 `typedArrayByCopyCoerceValue` 一带。默认 species 快路径禁止跳过可观察的 `constructor`/`@@species` Get；跨 realm 的 intrinsic `%Array%` 在 Get 之后被压回当前 realm 的普通 Array。

### `arraySpeciesCreate` (`src/exec/array_ops.zig:3538`)

- **签名**：`pub fn arraySpeciesCreate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, original: core.JSValue, length: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：先走 `defaultArraySpeciesCreate`（plain Array + 未改 constructor/prototype/@@species）。
- **实现**：先走 `defaultArraySpeciesCreate`（plain Array + 未改 constructor/prototype/@@species）。否则：IsArray 才读 `constructor`；跨 realm 的 intrinsic `%Array%` 被压回默认；再 Get `@@species`（null 当 undefined）；再比较当前 realm 的 intrinsic Array；最后 `constructValueOrBytecode(species, [length])`。非数组 original 直接造默认 Array。输出数组经 `arraySpeciesCreate` / `@@species` 构造。错误：error.RangeError、error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的输出对象：默认路径是新建普通数组（挂 realm 的 `Array.prototype`），species 路径则是 `constructValueOrBytecode` 用**用户构造器**造出来的任意对象——调用方因此必须用 `createDataPropertyOrThrow` 一类的可观察写入。`original` 借用。error set：`length > max_array_length` 且走默认路径 → `error.RangeError`；`constructor` 不是对象、取不到 `Symbol.species` atom → `error.TypeError`；两次属性读的 getter 与构造器本身的异常透传。⚠️ 可观察次序：`Symbol.species` 的 Get 必须发生，`arraySpeciesConstructorIsForeignIntrinsicArray` 的抑制在 Get 之前、`...IsRealmIntrinsicArray` 的抑制在 Get 之后。调用方五处：`arrayIterationModeCall`（`:1514`）、`arraySliceCall`（`:2275`）、`arraySpliceCallImpl`（`:2656`）、`arrayFlatCall`（`:5399`）、`exec/string_ops.zig:3066`（concat）。

### `arrayHasDefaultSpecies` (`src/exec/array_ops.zig:3599`)

- **签名**：`pub fn arrayHasDefaultSpecies(rt: *core.JSRuntime, global: *core.Object, original: *core.Object) !?*core.Object`。
- **作用**：必须是非 Proxy 的 Array、无 own constructor、原型是 realm `%Array.prototype%`、`Array.prototype.constructor` 仍指向带 `.constructor` marker 的 intrinsic、`@@species` 是「getter 带 `.species_getter` marker + setter undefined」的 accessor。
- **实现**：必须是非 Proxy 的 Array、无 own constructor、原型是 realm `%Array.prototype%`、`Array.prototype.constructor` 仍指向带 `.constructor` marker 的 intrinsic、`@@species` 是「getter 带 `.species_getter` marker + setter undefined」的 accessor。任一条件失败返回 null，迫使走可观察 Get。成功时返回 realm 的 `Array.prototype`，调用方拿它建数组。QuickJS 坐标：quickjs.c:42962-42971。
- **所有权 / 错误 / 调用**：返回借用的 `Array.prototype` 指针（调用方只拿它当新数组的原型），或 null 表示「species 链被改过，必须走可观察路径」。`getOwnProperty` 返回的两个描述符各自 `defer destroy(rt)` 释放。判定链：receiver 是非 proxy 数组且没有 own `constructor` → 原型是 realm 的 `Array.prototype` → global 的 `Array` 带 `.constructor` marker → `Array.prototype.constructor` 就是它 → `Array[Symbol.species]` 是带 `.species_getter` marker 的只读访问器。error set：只有 `getOwnProperty` 的透传。调用方 `arraySliceCall`（`:2252`）、`fastDenseArraySplice`（`:2483`）、`defaultArraySpeciesCreate`（`:3636`）。

### `defaultArraySpeciesCreate` (`src/exec/array_ops.zig:3630`)

- **签名**：`pub fn defaultArraySpeciesCreate(rt: *core.JSRuntime, global: *core.Object, original: *core.Object, length: usize) !?core.JSValue`。
- **作用**：默认 species 快路径：`arrayHasDefaultSpecies` 通过时直接造一条 plain Array，省掉 `constructor`/`@@species` 两次 Get。
- **实现**：`arrayHasDefaultSpecies` 返回 null 时本函数也返回 `null`（调用方必须走可观察 Get，不能偷懒）；通过后 `length > max_array_length` 即 `error.RangeError`，否则 `createArray` + `setArrayLength`。关键调用：`arrayHasDefaultSpecies`、`Object.createArray`、`out.setArrayLength`、`out.value`。错误：error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的新普通数组，或 null 表示 species 已被改（调用方走可观察路径）。error set：`length > core.array.max_array_length` → `error.RangeError`（注意这一步在确认默认 species **之后**才做），以及分配 OOM。唯一调用方 `arraySpeciesCreate`（`:3558`）。

### `arrayConstructorFromGlobal` (`src/exec/array_ops.zig:3640`)

- **签名**：`pub fn arrayConstructorFromGlobal(_: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：取 global 上 own data 属性 `Array` 的构造器对象（不走原型链、不触发 getter）；缺失或不是对象返回 null。
- **实现**：薄封装，主体转发到 `global.getOwnDataPropertyValue`、`atom.predefinedId`、`objectFromValue`。
- **所有权 / 错误 / 调用**：返回借用的 `Array` 构造器对象（global 的 own 数据属性值），global 持有；找不到或不是对象返回 null。不分配、无 error set，`rt` 参数未用（`_:`）。⚠️ 只读 **own data** 属性，因此被访问器化或删除的 `Array` 一律判 null，把调用方推回可观察路径。唯一调用方 `arrayHasDefaultSpecies`（`:3610`）。

### `arraySpeciesOriginalIsArray` (`src/exec/array_ops.zig:3645`)

- **签名**：`pub fn arraySpeciesOriginalIsArray(object: *core.Object) !bool`。
- **作用**：ES `IsArray`：自身是数组即 true；是 Proxy 就递归看 target（target/handler 缺失＝已 revoke，抛 `error.TypeError`）；其余 false。
- **实现**：关键调用：`object.isArray`、`object.isProxy`、`object.proxyTarget`、`object.proxyHandler`、`objectFromValue`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：纯谓词但**带 error set**：proxy 链上 target 或 handler 缺失（已 revoke）→ `error.TypeError`，对齐 spec 的 IsArray。递归穿透 proxy 到底层 target，不分配、不跑用户代码。调用方 `arraySpeciesCreate`（`:3559`）、`flattenIntoArray`（`:5442`）、自身递归（`:3657`），以及 `exec/string_ops.zig:3152`/`:3155`（concat 的 isConcatSpreadable 回退）。

### `arraySpeciesConstructorIsForeignIntrinsicArray` (`src/exec/array_ops.zig:3662`)

- **签名**：`fn arraySpeciesConstructorIsForeignIntrinsicArray(ctx: *core.JSContext, constructor_value: core.JSValue) !bool`。
- **作用**：ArraySpeciesCreate 的第一条 legacy-web-compat 臂：判断 `constructor` 是不是**别的 realm** 的 intrinsic `%Array%`（是就在读 `@@species` 之前压回默认 Array）。
- **实现**：品牌用 `arrayBuiltinMarker() == .constructor`（bound / Proxy 继承不到，改名也伪造不了），再用 `functionRealmContext` 证明它的 FunctionRealm 不是当前 ctx 且确实是那个 realm 的 intrinsic。关键调用：`objectFromValue`、`constructor_object.arrayBuiltinMarker`、`call_runtime.functionRealmContext`、`arraySpeciesConstructorIsRealmIntrinsicArray`。
- **所有权 / 错误 / 调用**：私有谓词；`arrayBuiltinMarker` 是**不可伪造、不可继承**的引擎内部品牌（bound function 与 Proxy 都拿不到），所以这条只认「另一个 realm 的那个真 %Array%」。不分配。error set：`call_runtime.functionRealmContext` 的透传（revoked proxy 的 `error.TypeError` 等）。唯一调用方 `arraySpeciesCreate`（`:3570`），用于 legacy-web-compat 的第一条抑制臂。

### `arraySpeciesConstructorIsRealmIntrinsicArray` (`src/exec/array_ops.zig:3670`)

- **签名**：`fn arraySpeciesConstructorIsRealmIntrinsicArray(realm: *core.JSContext, constructor_value: core.JSValue) bool`。
- **作用**：判断某个值是不是给定 realm 的 intrinsic `%Array%`：`arrayBuiltinMarker() == .constructor` 且 `nativeFunctionRealm()` 正是该 realm。
- **实现**：薄封装，主体转发到 `objectFromValue`、`constructor_object.arrayBuiltinMarker`、`constructor_object.nativeFunctionRealm`。
- **所有权 / 错误 / 调用**：私有谓词，不分配、无 error set、不跑用户代码：只比对 `arrayBuiltinMarker == .constructor` 且 `nativeFunctionRealm()` 等于给定 realm。调用方 `arraySpeciesCreate`（`:3586`，在 `Symbol.species` 的 Get **之后**做第二次抑制）与 `arraySpeciesConstructorIsForeignIntrinsicArray`（`:3671`）。

### `arrayFromCall` (`src/exec/array_ops.zig:3676`)

- **签名**：`pub fn arrayFromCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.from` 的 VM 入口；callee 若是 `%TypedArray%.from` 则整段转给 `typedArrayFromStaticCall`。
- **实现**：callee 不匹配 record id / 函数名 `from` 时返回 `null`。首参 null/undefined 抛 TypeError；`args[1]` 非 undefined 必须可调用（mapper），`args[2]` 是 thisArg。分流顺序：构造器是 TypedArray 且源是数组 → `arrayFromArrayLike`；有 `@@iterator`（必须可调用）→ 先 Call 拿迭代器再 `arrayFromIteratorLike`（迭代中途失败会先 IteratorClose）；generator/async generator、Map/Set（经 collection record 取 values/entries 迭代器）、Map/Set iterator 也走迭代器臂；数组源走 `arrayFromArrayLike`；最后才是内联的 array-like 尾巴（Get `length` + ToLength，> u32 最大值即 RangeError，逐下标 Get + 可选 mapper + `createArrayFactoryDataPropertyOrThrow`，收尾写 `length`）。输出对象：构造器 constructor-like 则 `Construct(C, [len])`，否则新建默认 Array。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。对不上这个 builtin 时返回 `null`，让上层继续级联。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的结果数组值，或 null 表示「不是 `Array.from`」；`%TypedArray%.from` 在开头就被转交 `typedArrayFromStaticCall`。非构造器 `this` 走 `createArray` 时带 `errdefer destroyFromHeader`；构造器路径产出的对象由用户控制，所以元素一律经 `createArrayFactoryDataPropertyOrThrow` 写入。error set：源为 null/undefined、mapfn 不可调用、`Symbol.iterator` 不可调用、Map/Set 抽取失败 → `error.TypeError`；`length > u32` 上限 → `error.RangeError`；用户 iterator/mapper/getter 的异常透传（这条路径**不做 IteratorClose**，close 在 `arrayFromIteratorLike` 里）。调用方 `exec/builtin_glue.zig:234`（记录路径）与 `exec/call_runtime.zig:1271`（名字级联）。

### `fromAsyncStateSet` (`src/exec/array_ops.zig:3790`)

- **签名**：`fn fromAsyncStateSet(rt: *core.JSRuntime, state: *core.Object, key: core.Atom, value: core.JSValue) !void`。
- **作用**：往 fromAsync 闭包的内部状态对象（用户永远看不到）写一个槽，`defineOwnProperty` 成可写/可枚举/可配置的数据属性。
- **实现**：薄封装，主体转发到 `state.defineOwnProperty`、`Descriptor.data`。
- **所有权 / 错误 / 调用**：无返回值；把值写进内部状态对象的一个普通数据属性，所有权转给该对象（这个 state 对象是 `fromAsyncStart` 新建的、永不逃逸到用户代码，因此不需要屏障之外的额外处理）。error set：`defineOwnProperty` 的 OOM。调用方是整个 fromAsync 状态机（`fromAsyncStart`、`fromAsyncAwait`、`fromAsyncContinuation`、`fromAsyncResume`、`fromAsyncCloseWithValue` 等十余处）。

### `fromAsyncStateGet` (`src/exec/array_ops.zig:3796`)

- **签名**：`fn fromAsyncStateGet(_: *core.JSRuntime, state: *core.Object, key: core.Atom) core.JSValue`。
- **作用**：读内部状态槽；槽不存在时断言该对象确实没有这个 own 属性并返回 `undefined`。
- **实现**：薄封装，主体转发到 `state.getOwnDataPropertyValue`、`debug.assert`、`state.hasOwnProperty`、`JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：`getOwnDataPropertyValue` 的**借用**读出（TGC 下没有 retain，值的存活靠 state 对象这条 GC 边；函数上的 doc 注释已改实），槽不存在时断言确实没有该属性并返回 undefined。不分配、无 error set、`rt` 参数未用。调用方遍布 fromAsync 状态机。

### `fromAsyncStateNumber` (`src/exec/array_ops.zig:3802`)

- **签名**：`fn fromAsyncStateNumber(rt: *core.JSRuntime, state: *core.Object, key: core.Atom) f64`。
- **作用**：按数值读状态槽（`k` / `len` / `phase` 用），不是数值给 0。
- **实现**：薄封装，主体转发到 `fromAsyncStateGet`、`value_ops.numberValue`。
- **所有权 / 错误 / 调用**：返回 f64，不分配、无 error set；非数字槽一律读成 0（`k`/`len`/`phase` 这些计数槽都由本文件自己写入，所以这个兜底只在状态被破坏时生效）。调用方 `fromAsyncResume`、`fromAsyncOnNextResult`、`fromAsyncAdvanceIterIndex`、`fromAsyncArrayLikeStep`、`fromAsyncDefineElement` 等。

### `fromAsyncGetMethod` (`src/exec/array_ops.zig:3808`)

- **签名**：`fn fromAsyncGetMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：spec `GetMethod(V, P)`：取到的值是 undefined/null 时返回 Zig `null`（表示「没有这个方法」），非 callable 抛 TypeError。
- **实现**：`[[Get]]` 后判 undefined/null → `null`；非 callable 走 `throwTypeErrorMessage("not a function")`；否则返回该方法。关键调用：`getValueProperty`、`method.isUndefined`、`method.isNull`、`isCallableValue`、`throwTypeErrorMessage`。
- **所有权 / 错误 / 调用**：返回 owned 的方法值，或 null 表示 undefined/null（spec GetMethod 的「没有这个方法」）。error set：属性是非 callable → `throwTypeErrorMessage("not a function")`，它挂上带消息的 TypeError 并返回 `error.TypeError`，所以那句 `_ = try` 之后的 `return method` 在该分支不可达；属性 getter 的异常透传。唯一调用方 `fromAsyncStart`（`:3906`、`:3909`），分别取 `Symbol.asyncIterator` 与 `Symbol.iterator`。

### `arrayFromAsyncCall` (`src/exec/array_ops.zig:3833`)

- **签名**：`pub fn arrayFromAsyncCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.fromAsync(asyncItems[, mapfn[, thisArg]])` 的入口：建 promise capability，跑同步前奏，返回结果 promise。
- **实现**：callee 对不上 record id / 函数名 `fromAsync` 时返回 `null` 让级联继续。`defaultPromiseCapability` 失败是唯一同步抛出的情况；`fromAsyncStart` 的任何错误都被 catch 成 `promiseRejectCapabilityForError`，最后照样返回 `capability.promise`。关键调用：`callableObjectFromValue`、`isArrayStaticRecord`、`call_mod.nativeFunctionNameForVmEquals`、`promise_ops.defaultPromiseCapability`、`fromAsyncStart`、`promise_ops.promiseRejectCapabilityForError`。
- **所有权 / 错误 / 调用**：返回 owned 的结果 promise 值，或 null 表示「不是 `Array.fromAsync`」。错误模型是这一族的关键：只有 `defaultPromiseCapability` 失败会同步上抛，`fromAsyncStart` 的**任何** abrupt completion 都被 `catch` 住并转成 `promiseRejectCapabilityForError`（拒绝结果 promise），因此正常情况下调用方拿到的永远是一个已拿到 capability 的 promise。capability 的 resolve/reject 随后存进内部 state 对象，由它持有。调用方 `exec/builtin_glue.zig:235` 与 `exec/call_runtime.zig:1272`。

### `fromAsyncStart` (`src/exec/array_ops.zig:3859`)

- **签名**：`fn fromAsyncStart( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, resolve: core.JSValue, reject: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：fromAsync 闭包的同步前奏（spec 3.a-k）：mapfn 校验 → 建内部 state 对象 → 取 `@@asyncIterator`（没有就用 `@@iterator` 包成 async-from-sync）→ 构造目标 → 迈出第一步。
- **实现**：mapfn 非 undefined 且不可调用先抛 TypeError（早于任何对 asyncItems 的访问）。state 是 null 原型的内部对象，用 `ValueRootFrame` 钉住；依次写 resolve/reject/mapfn/this_arg/k=0。有迭代器方法时：Call 拿迭代器（必须是对象），sync 臂再过 `createAsyncFromSyncIterator`，读 `next` 存进 state，目标 `IsConstructor(C) ? Construct(C) : ArrayCreate(0)`，然后 `fromAsyncIterStep`。否则走 array-like 臂：Get `length` → ToLength，目标 `Construct(C, [len])` 或 `ArrayCreate(len)`（len > 2^32−1 抛 RangeError「invalid array length」），然后 `fromAsyncArrayLikeStep`。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。错误：error.TypeError。
- **所有权 / 错误 / 调用**：无返回值；新建的内部 state 对象用 `ValueRootFrame` 挂根（后面每次 `defineOwnProperty` 都可能触发 GC），它同时持有 resolve/reject/mapfn/thisArg/iterator/next/target 这些值的 GC 边，本函数返回后靠 continuation 回调对象上的 `state` 槽继续存活。error set：mapfn 不可调用、iterator 结果不是对象 → `throwTypeErrorMessage`（带消息的 TypeError）；`len > 2^32-1` 且非构造器 → `throwRangeErrorMessage("invalid array length")`；取不到 well-known symbol atom → `error.TypeError`；用户方法/构造器/getter 的异常透传。**错误不在这里变 JS 异常**，而是由唯一调用方 `arrayFromAsyncCall`（`:3852`）捕获后拒绝结果 promise。

### `fromAsyncAwait` (`src/exec/array_ops.zig:3977`)

- **签名**：`fn fromAsyncAwait( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, value: core.JSValue, phase: i32, ) !void`。
- **作用**：一次 spec `Await(value)`：先把恢复点写进 state 的 `phase` 槽，再 `PromiseResolve(%Promise%, value)` 并用内部 `PerformPromiseThen` 挂上一对 continuation 回调（不读用户可见的 `.then`）。
- **实现**：关键调用：`fromAsyncStateSet`、`JSValue.int32`、`promise_ops.promiseDefaultConstructor`、`promise_ops.promiseStaticCall`、`fromAsyncContinuation`、`promise_ops.performPromiseThen`、`JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无返回值；先把 resume 点写进 state 的 `phase` 槽，再用 `promiseStaticCall(.resolve)` 把值包成 promise，最后 `performPromiseThen` 挂上两个新建的 continuation 函数对象（它们各自持有 state 的 GC 边）。**全程不读用户的 `.then`**，是内部 await。error set：默认 Promise 构造器缺失、`createDataFunction` 的 OOM 与 `performPromiseThen` 透传。调用方 `fromAsyncResume`（`:4082`）、`fromAsyncOnNextResult`（`:4142`）、`fromAsyncIterStep`（`:4189`）、`fromAsyncArrayLikeStep`（`:4212`）、`fromAsyncCloseWithValue`（`:4306`）。

### `fromAsyncContinuation` (`src/exec/array_ops.zig:3994`)

- **签名**：`fn fromAsyncContinuation(rt: *core.JSRuntime, global: *core.Object, state: *core.Object, rejected: bool) !core.JSValue`。
- **作用**：造一个带 `.array_from_async_continuation` 内部 tag 的无名函数（length 1）当 promise reaction，把 state 与 `rejected` 标志挂在它自己的槽上。
- **实现**：关键调用：`builtin_glue.createDataFunction`、`objectFromValue`、`callback_object.setInternalCallableTag`、`fromAsyncStateSet`、`state.value`、`JSValue.boolean`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的回调函数值（随即被 `performPromiseThen` 注册进 promise 的反应表并由它持有）。回调对象上挂两个槽：`state`（到状态对象的 GC 边）与 `rejected` 标志；`setInternalCallableTag(.array_from_async_continuation)` 是它被 `call_runtime.callInternalCallableByTag` 路由回 `arrayFromAsyncContinuationCall` 的唯一依据。error set：`createDataFunction` 的 OOM、结果不是对象 → `error.TypeError`、写槽的 OOM。唯一调用方 `fromAsyncAwait`（`:3993` 建 onFulfilled、`:3994` 建 onRejected）。

### `arrayFromAsyncContinuationCall` (`src/exec/array_ops.zig:4007`)

- **签名**：`pub fn arrayFromAsyncContinuationCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`.array_from_async_continuation` 回调的入口（由 `call_runtime.callInternalCallableByTag` 路由）：从函数对象取回 state 与 rejected，再进 `fromAsyncResume`。
- **实现**：state 用 `ValueRootFrame` 钉住；`fromAsyncResume` 抛出的任何错误都转成对结果 promise 的 reject（promise 自身的 already-resolved 闩让迟到的二次 settle 变成 no-op），本函数恒返回 `undefined`。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。关键调用：`fromAsyncStateGet`、`root_frame.activate`、`root_frame.deactivate`、`objectFromValue`、`valueTruthy`、`JSValue.undefinedValue`、`fromAsyncResume`、`promise_ops.promiseRejectCapabilityForError`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 undefined（promise 反应的返回值被丢弃）。先从函数对象上取回 state 并用 `ValueRootFrame` 挂根，再把活交给 `fromAsyncResume`；**resume 的任何错误都被 `catch` 成 `promiseRejectCapabilityForError`**，所以异常不会逃回 job 循环（promise 自身的已决锁存使重复 settle 成为空操作）。error set：state 槽不是对象 → `error.TypeError`，以及 reject 路径自身的失败。唯一调用方 `exec/call_runtime.zig:888`（按 internal callable tag 路由）。

### `fromAsyncResume` (`src/exec/array_ops.zig:4037`)

- **签名**：`fn fromAsyncResume( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, rejected: bool, settled: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：await 落地后按 state 里的 `phase` 分派到对应的恢复点（五个 phase 常量 1-5）。
- **实现**：phase 1（迭代器 `next` 结果）：rejected 直接 reject，**不**关迭代器（spec 这一步用 `?` 而非 IfAbruptCloseAsyncIterator）；否则 `fromAsyncOnNextResult`。phase 2（迭代器 mapped 值）：rejected 走 `fromAsyncCloseWithValue`，定义元素失败走 `fromAsyncCloseWithError`，成功则 `fromAsyncAdvanceIterIndex`。phase 3/4（array-like 的 kValue / mapped 值）：array-like 循环从不关迭代器，任何 abrupt 直接 reject；phase 3 有 mapfn 时先调 mapper 再 Await（转 phase 4）。phase 5（AsyncIteratorClose 的 `return()` 结果）：无论落地成什么，都用 state 里存的 `pending` 原错误 reject。未知 phase 返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：无返回值；按 `phase` 槽分派五个 resume 点，值全部来自 state 槽（借用）或参数。错误处理是逐相定制的：phase 1（Await(nextResult)）拒绝时**不关闭迭代器**（spec 这一步用 `?` 而非 IfAbruptCloseAsyncIterator）；phase 2 的拒绝与定义元素失败都走 `fromAsyncCloseWithError`；phase 3/4（array-like）任何 abrupt 都直接 reject，从不关闭；phase 5 用 `pending` 槽里保存的原错误 reject，**无论 return() 的结果如何**。未知 phase → `error.TypeError`。唯一调用方 `arrayFromAsyncContinuationCall`（`:4034`）。

### `fromAsyncOnNextResult` (`src/exec/array_ops.zig:4104`)

- **签名**：`fn fromAsyncOnNextResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, next_result: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`Await(nextResult)` 兑现后的迭代器循环体（spec 3.j.ii.iv-x）：结果必须是对象，读 `done`/`value`，然后收尾、或 map+Await、或定义元素后取下一个。
- **实现**：非对象抛 TypeError「iterator must return an object」。`done` 为真 → `fromAsyncFinish(k)`。有 mapfn 时调 mapper（失败走 `fromAsyncCloseWithError`），再 `fromAsyncAwait(..., phase 2)`；没有 mapfn 就直接 `fromAsyncDefineElement`（失败同样 close），再 `fromAsyncAdvanceIterIndex`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：无返回值；`next_result` 借用。结果不是对象 → `throwTypeErrorMessage("iterator must return an object")`（带消息 TypeError）；`done` 为真转 `fromAsyncFinish`；有 mapfn 时 mapper 的 abrupt 被 `catch` 成 `fromAsyncCloseWithError`（AsyncIteratorClose(throw)），随后 Await 进 phase 2；无 mapfn 时 `fromAsyncDefineElement` 的 abrupt 同样转 close。取不到 `done`/`value` 的预定义 atom → `error.TypeError`。唯一调用方 `fromAsyncResume` 的 phase 1 臂（`:4062`）。

### `fromAsyncAdvanceIterIndex` (`src/exec/array_ops.zig:4151`)

- **签名**：`fn fromAsyncAdvanceIterIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：迭代器循环的 `k += 1`，带 spec 的 2^53−1 上限（超了抛 TypeError 并转 AsyncIteratorClose），然后进下一轮 `next()` + Await。
- **实现**：`k + 1 >= 9007199254740991` 时 `throwTypeErrorMessage("too many elements")` 的错误交给 `fromAsyncCloseWithError` 并直接返回；否则写回 `k` 再 `fromAsyncIterStep`。关键调用：`fromAsyncStateNumber`、`throwTypeErrorMessage`、`fromAsyncCloseWithError`、`fromAsyncStateSet`、`JSValue.number`、`fromAsyncIterStep`。
- **所有权 / 错误 / 调用**：无返回值；k 是 f64 计数，写回 state 的 `k` 槽。超过 2^53-1 时不是直接上抛，而是把 `throwTypeErrorMessage("too many elements")` 的错误立刻交给 `fromAsyncCloseWithError` 走 AsyncIteratorClose，close 里的二次错误被原错误压过（phase 5）。其余 error 由 `fromAsyncIterStep` 透传。调用方 `fromAsyncResume` 的 phase 2 臂（`:4071`）与 `fromAsyncOnNextResult`（`:4150`）。

### `fromAsyncIterStep` (`src/exec/array_ops.zig:4173`)

- **签名**：`fn fromAsyncIterStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：迭代器循环头（spec 3.j.ii.ii-iii）：`Call(next, iterator)`——这一步 abrupt 直接 reject 而**不**关迭代器——再 `Await(nextResult)`（phase 1）。
- **实现**：关键调用：`fromAsyncStateGet`、`callValueOrBytecodeRoot`、`fromAsyncAwait`。
- **所有权 / 错误 / 调用**：无返回值；iterator 与 next 方法都是从 state 槽借出的。`next()` 的 abrupt **直接上抛**（由 `arrayFromAsyncContinuationCall` / `arrayFromAsyncCall` 转成 promise 拒绝），刻意不关闭迭代器——对应 spec 3.j.ii.ii 的 `?`。成功则 Await 进 phase 1。调用方 `fromAsyncStart`（`:3946`）与 `fromAsyncAdvanceIterIndex`（`:4172`）。

### `fromAsyncArrayLikeStep` (`src/exec/array_ops.zig:4190`)

- **签名**：`fn fromAsyncArrayLikeStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：array-like 循环头（spec 3.k.vii）：`k >= len` 就收尾（写 length + resolve），否则 `Get(arrayLike, k)` 后 `Await(kValue)`（phase 3）。
- **实现**：关键调用：`fromAsyncStateNumber`、`fromAsyncFinish`、`fromAsyncStateGet`、`propertyAtomFromLengthIndex`（配 `defer index_atom.deinit(rt)`）、`@intFromFloat`、`getValueProperty`、`fromAsyncAwait`。
- **所有权 / 错误 / 调用**：无返回值；k ≥ len 时转 `fromAsyncFinish` 收尾，否则从 `items` 槽读第 k 个元素再 Await 进 phase 3。`propertyAtomFromLengthIndex` 产出的 atom 配了 `defer index_atom.deinit(rt)`，与本文件其它约 30 处索引读写点一致（大索引 >2^31 的 pin 因此会被释放）。error set：属性 getter 与 Await 透传。调用方 `fromAsyncStart`（`:3975`）与 `fromAsyncResume` 的 phase 3/4 臂（`:4087`、`:4093`）。

### `fromAsyncDefineElement` (`src/exec/array_ops.zig:4213`)

- **签名**：`fn fromAsyncDefineElement( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`CreateDataPropertyOrThrow(A, ToString(k), value)`：把一个已 await 的值写进目标对象的第 `k` 个下标。
- **实现**：从 state 取 `target`（不是对象则 `error.TypeError`）与 `k`，下标 atom 经 `propertyAtomFromLengthIndex`（配 `defer index_atom.deinit(rt)`），再 `createDataPropertyOrThrow`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：无返回值；`value` 借用，写入后由 target 对象持有。`target` 从 state 槽读出，不是对象 → `error.TypeError`。index atom 同样配了 `defer index_atom.deinit(rt)`（与 `fromAsyncArrayLikeStep` 一致）。error set：`createDataPropertyOrThrow` 在目标拒绝定义时的 `error.TypeError`，以及 OOM。调用方 `fromAsyncResume`（phase 2/3/4 共三处：`:4068`、`:4085`、`:4091`）与 `fromAsyncOnNextResult`（`:4147`）。

### `fromAsyncFinish` (`src/exec/array_ops.zig:4232`)

- **签名**：`fn fromAsyncFinish( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, length: f64, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：循环收尾：`Set(A, "length", length, true)`（和数组 mutator 同样的 throw 纪律），再用目标对象 resolve 结果 promise。
- **实现**：关键调用：`fromAsyncStateGet`、`setValuePropertyOrThrow`、`JSValue.number`、`promise_ops.promiseResolveCapability`。
- **所有权 / 错误 / 调用**：无返回值；先按「失败即抛」的语义写 target 的 `length`（`setValuePropertyOrThrow`），再用 `promiseResolveCapability` 兑现结果 promise——`target` 的所有权就此交给 promise 的 resolve。error set：length 写失败的 `error.TypeError` 与 resolve 自身的失败，都会被上层 `catch` 转成 promise 拒绝。调用方 `fromAsyncOnNextResult`（`:4127`）与 `fromAsyncArrayLikeStep`（`:4206`）。

### `fromAsyncReject` (`src/exec/array_ops.zig:4248`)

- **签名**：`fn fromAsyncReject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, reason: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：用给定 reason 拒绝结果 promise（reject 函数从 state 槽里取）。
- **实现**：关键调用：`fromAsyncStateGet`、`promise_ops.promiseRejectCapability`。
- **所有权 / 错误 / 调用**：无返回值；`reason` 借用，交给 `promiseRejectCapability` 后由 promise 持有。不分配、无自有 error set。调用方七处：`fromAsyncResume` 的 phase 1/3/4/5 臂（`:4061`、`:4076`、`:4090`、`:4099`），以及 `fromAsyncCloseWithValue` 的三条「关不掉就直接拒绝」出口（`:4296`、`:4299`、`:4303`）。

### `fromAsyncCloseWithError` (`src/exec/array_ops.zig:4263`)

- **签名**：`fn fromAsyncCloseWithError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, err: core.errors.HostError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把挂起的 Zig error（或它对应的 JS 异常值）物化成 reason，再以 throw completion 跑 AsyncIteratorClose。
- **实现**：关键调用：`exception_ops.promiseErrorValue`、`fromAsyncCloseWithValue`。
- **所有权 / 错误 / 调用**：无返回值；把 Zig 的 `HostError` 物化成 JS 值（`exception_ops.promiseErrorValue` 会消费掉 pending 异常），再转 `fromAsyncCloseWithValue`。这是 fromAsync 里唯一的 error→value 转换点。error set：物化自身的 OOM。调用方 `fromAsyncResume`（`:4069`）、`fromAsyncOnNextResult`（`:4140`、`:4148`）与 `fromAsyncAdvanceIterIndex`（`:4167`）。

### `fromAsyncCloseWithValue` (`src/exec/array_ops.zig:4280`)

- **签名**：`fn fromAsyncCloseWithValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, state: *core.Object, reason: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`AsyncIteratorClose(iteratorRecord, ThrowCompletion(reason))`：close 内部的任何 abrupt 都被原错误压过，即使 `return()` 的结果成功兑现也照样用原错误 reject。
- **实现**：读 `return`——取失败就清掉异常直接 `fromAsyncReject(reason)`；不存在/不可调用也直接 reject；调用 `return()` 失败同样清异常后 reject。调用成功则把 reason 存进 state 的 `pending` 槽，再 `Await(inner)` 转 phase 5。关键调用：`fromAsyncStateGet`、`getValueProperty`、`ctx.hasException`、`ctx.clearException`、`fromAsyncReject`、`return_method.isUndefined`、`return_method.isNull`、`isCallableValue`。
- **所有权 / 错误 / 调用**：无返回值；实现 AsyncIteratorClose(throw)：读 `return` 方法或调用它失败时**先 `ctx.clearException()` 再用原 `reason` 拒绝**（二次错误被丢弃），方法不存在/不可调用也直接用原 reason 拒绝；成功拿到 inner result 则把 reason 存进 `pending` 槽并 Await 进 phase 5——那一相无论结果如何都用 `pending` 拒绝。error set：只剩 `fromAsyncStateSet` / `fromAsyncAwait` 的 OOM。调用方 `fromAsyncResume` 的 phase 2 臂（`:4067`）与 `fromAsyncCloseWithError`（`:4275`）。

### `typedArrayFromStaticCall` (`src/exec/array_ops.zig:4307`)

- **签名**：`pub fn typedArrayFromStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`%TypedArray%.from`：this 必须是构造器，按源的形态（迭代器 / generator / Map·Set(-iterator) / array-like）收集元素再造 TypedArray。
- **实现**：this 不是 constructor-like 或首参 null/undefined 即 `error.TypeError`；`args[1]` 非 undefined 必须可调用。有 `@@iterator`（可调用）→ Call 后 `typedArrayFromIteratorValue`；generator/async generator、Map/Set（经 collection record 取迭代器）、Map/Set iterator 同样走迭代器臂；其余走 `typedArrayFromArrayLikeSource`。关键调用：`call_runtime.isConstructorLike`、`isNull`、`isUndefined`、`isCallableValue`、`JSValue.undefinedValue`、`getIteratorMethod`、`iterator_method.isUndefined`、`iterator_method.isNull`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值（不返回 null——不匹配的情形在调用方 `arrayFromCall` 就筛掉了）。`constructor_value` 借用。error set：`this` 不是构造器、源为 null/undefined、mapfn 不可调用、`Symbol.iterator` 不可调用、Map/Set 抽取失败 → `error.TypeError`；用户迭代器/mapper 的异常透传（这条路**不做 IteratorClose**）。唯一调用方 `arrayFromCall`（`:3694`），在 `%TypedArray%.from` 的 record id 命中时。

### `typedArrayFromIteratorValue` (`src/exec/array_ops.zig:4352`)

- **签名**：`pub fn typedArrayFromIteratorValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, iterator_value: core.JSValue, map_fn: ?core.JSValue, this_arg: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`%TypedArray%.from` 的迭代器臂：先把迭代器完整抽干成一个临时数组，再按它的长度当 array-like 造 TypedArray（mapper 在第二趟才调用）。
- **实现**：关键调用：`collectIteratorValues`、`objectFromValue`、`typedArrayFromArrayLikeSource`、`values.arrayLength`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值。`collectIteratorValues` 先把迭代器排空成一个中间数组（owned，随后只作为 array-like 源被读），再交给 `typedArrayFromArrayLikeSource`——因此元素在整个过程里由那个中间数组持根。error set：中间结果不是对象 → `error.TypeError`，排空与构造的异常透传。调用方 `typedArrayFromStaticCall` 四处（`:4331`、`:4336`、`:4344`、`:4347`）。

### `fromArrayLikeSource` (`src/exec/array_ops.zig:4388`)

- **签名**：`noinline fn fromArrayLikeSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, source: core.JSValue, fixed_length: ?usize, map_fn: ?core.JSValue, this_arg: core.JSValue, kind: ArrayFromLikeKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Array.from` / `TypedArray.from` 的 array-like 臂：构造输出、按下标 Get、可选 mapper、再 define/set。
- **实现**：`kind == .typed` 先算 length（`fixed_length` 或 Get `length` + ToLength），大于 u32 最大值 → `error.RangeError`，然后 `typedArrayCreateWithLength`。`.array`：constructor-like 则 `constructValueOrBytecode`（有 `fixed_length` 传 length 参数），否则 `createArray`；有 `fixed_length` 且 out 是 Array 则 `setArrayLength`。循环：typed length 固定；array 每轮重读 `source.arrayLength()` 除非 fixed。array 下标 > u32 最大值 → RangeError。Get 后可选 `CallSite.call2`（typed 用 `lengthIndexValue`，array 用 int32）。typed `typedArraySetElementValue`；array `createArrayFactoryDataPropertyOrThrow`。array 结束写 `length`。outlined leftover：两个 public 包装只传 kind。
- **所有权 / 错误 / 调用**：`noinline` 的共享实现，返回 owned 的输出对象。两种 kind 的所有权不同：`.typed` 先 `typedArrayCreateWithLength`（走 species，结果可能是用户对象，已做类型/长度校验）再逐元素 `typedArraySetElementValue`；`.array` 用构造器或 `createArray` 产出后逐元素 `createArrayFactoryDataPropertyOrThrow`，最后按实际写入个数 `setValuePropertyOrThrow` 写 `length`。`source` / `map_fn` / `this_arg` 借用；`mapper_call` 的 `CallSite` 在本函数栈上。⚠️ `.array` 且 `fixed_length == null` 时每轮循环都**重新读一次源数组长度**，mapper 里改长度是可观察的。error set：长度或索引超 u32 上限 → `error.RangeError`；输出不是对象 → `error.TypeError`；getter/mapper/构造器透传。调用方就是下面两个 `inline` 壳（`:4481`、`:4496`）。

### `typedArrayFromArrayLikeSource` (`src/exec/array_ops.zig:4467`)

- **签名**：`pub inline fn typedArrayFromArrayLikeSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, source: core.JSValue, fixed_length: ?usize, map_fn: ?core.JSValue, this_arg: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`%TypedArray%.from(arrayLike, mapFn, thisArg)` 的 array-like 一支：按 length 逐个下标读源、可选过 mapper，写进新建的 TypedArray。
- **实现**：`inline` 壳，唯一动作是给共享的 `fromArrayLikeSource` 补上 `kind = .typed` 再转发；`fixed_length` 非 null 时跳过对源读 `length`（`typedArrayFromIteratorValue` 先把迭代器收成数组，就用那个已知长度调进来）。按函数上方注释，array 与 typed 两条公开入口都保持 `inline` 且只传 kind，是为了让 `fromArrayLikeSource` 这一份 `noinline` 主体被两边共用（数组侧的 construct/length/define 与 TypedArray 侧的 create/set 差异改在运行时判，见 knife 94/98 注释）。
- **所有权 / 错误 / 调用**：`inline` 壳，除了把 `kind` 钉成 `.typed` 之外没有自己的所有权或错误语义，全部见 `fromArrayLikeSource`。调用方 `typedArrayFromStaticCall`（`:4351`）与 `typedArrayFromIteratorValue`（`:4367`）。

### `arrayFromArrayLike` (`src/exec/array_ops.zig:4482`)

- **签名**：`pub inline fn arrayFromArrayLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, source: core.JSValue, fixed_length: ?usize, map_fn: ?core.JSValue, this_arg: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Array.from` 的 array-like 臂：只把 `kind = .array` 传给共用的 `fromArrayLikeSource`。
- **实现**：关键调用：`fromArrayLikeSource`。
- **所有权 / 错误 / 调用**：`inline` 壳，把 `kind` 钉成 `.array`；所有权与 error set 全见 `fromArrayLikeSource`。调用方 `arrayFromCall` 两处（`:3710` 传源数组的当前长度，`:3726` 传 null 表示每轮重读长度）。

### `arrayFromIteratorLike` (`src/exec/array_ops.zig:4497`)

- **签名**：`pub fn arrayFromIteratorLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, iterator_value: core.JSValue, map_fn: ?core.JSValue, this_arg: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Array.from` 的迭代器臂：跑完整迭代器协议，逐个（可选 map 后）`CreateDataPropertyOrThrow` 到输出，最后写 `length`。
- **实现**：输出对象 = 构造器 constructor-like 时 `Construct(C)`（无参），否则新建默认 Array。`next` 必须可调用，否则 TypeError。循环里 `next()`、结果非对象、读 `done`/`value`、mapper、define 六处失败都先 `iteratorCloseValue` 再把**原**错误抛出去。`done` 用 `valueTruthy`（ToBoolean）判定，与 `iterator_ops` 的其它步进一致。含循环：按 length 或迭代器步进处理元素。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的输出数组（构造器路径的对象由用户控制，所以元素走 `createArrayFactoryDataPropertyOrThrow`）。这是本文件 IteratorClose 做得最全的一处：`next()`、`done` 读、`value` 读、mapper 调用、定义元素**五个失败点各自先 `iteratorCloseValue` 再重抛原错误**；但 close 用的是 `try`，close 自己失败会盖掉原错误。error set：输出/迭代器/next 结果不是对象或 next 不可调用 → `error.TypeError`，其余透传。调用方 `arrayFromCall` 四处（`:3718`、`:3723`、`:3737`、`:3740`）。

### `arrayOfCall` (`src/exec/array_ops.zig:4557`)

- **签名**：`pub fn arrayOfCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.of`；callee 若是 `%TypedArray%.of` 则转 `typedArrayOfStaticCall`。
- **实现**：callee 对不上 record id / 函数名 `of` 时返回 `null`。参数个数超过 `maxInt(i32)` 抛 RangeError。输出 = this constructor-like 时 `Construct(C, [argc])`，否则新建默认 Array 并 `setArrayLength`；逐个 `createArrayFactoryDataPropertyOrThrow`，最后 `Set(length, argc, true)`。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`callableObjectFromValue`、`typedArrayStaticMethodId`、`typedArrayOfStaticCall`、`isArrayStaticRecord`、`call_mod.nativeFunctionNameForVmEquals`、`math.maxInt`、`JSValue.int32`、`call_runtime.isConstructorLike`。错误：error.RangeError、error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的结果数组，或 null 表示「不是 `Array.of`」；`%TypedArray%.of` 在开头转交 `typedArrayOfStaticCall`。非构造器路径的 `createArray` 带 `errdefer destroyFromHeader`；构造器路径的对象由用户控制，元素与 `length` 分别走 `createArrayFactoryDataPropertyOrThrow` 与 `setValuePropertyOrThrow`。error set：`args.len > maxInt(i32)` → `error.RangeError`，输出不是对象 → `error.TypeError`，构造器与属性定义透传。调用方 `exec/builtin_glue.zig:236` 与 `exec/call_runtime.zig:1273`。

### `isArrayStaticRecord` (`src/exec/array_ops.zig:4596`)

- **签名**：`pub fn isArrayStaticRecord(function_object: *core.Object, method_id: u32) bool`。
- **作用**：判断一个函数对象是不是 `.array` 域里指定 id 的**静态**方法记录（`Array.from` / `fromAsync` / `of` 的身份门）。
- **实现**：`decodeNativeBuiltinId(function_object.nativeFunctionId())` 解出 `{domain, id}`：解不出返回 false，否则要求 `domain == .array` 且 `id == method_id`。
- **所有权 / 错误 / 调用**：无：纯谓词，读函数对象上编码的 native builtin id，不分配、无 error set、不跑用户代码。调用方三处，全是静态方法的身份门：`arrayFromCall`（`:3696`）、`arrayFromAsyncCall`（`:3848`）、`arrayOfCall`（`:4574`）。

### `arrayPrototypeRecordId` (`src/exec/array_ops.zig:4601`)

- **签名**：`pub fn arrayPrototypeRecordId(function_object: *core.Object) ?u32`。
- **作用**：取函数对象的 `.array` 域原型方法 id：不是 `.array` 域、或 id 既不在 `decodePrototypeMethodId` 表里也不在那串显式白名单里，返回 null。
- **实现**：先 `decodeNativeBuiltinId(function_object.nativeFunctionId())`，不是 `.array` 域就返回 null；再用 `array.decodePrototypeMethodId` 认 id，认得出就返回该 id；认不出时若 id 命中函数体里那串显式 `and native_ref.id != ...` 白名单也照样返回，否则 null。
- **所有权 / 错误 / 调用**：无：纯谓词式查表，返回 `?u32`，不分配、无 error set。那一长串 `and native_ref.id != ...` 是白名单补丁——`decodePrototypeMethodId` 认不出的 id 只要在列表里也放行，所以**新增原型方法记录时必须同步这里**，否则它会被判成「不是数组原型方法」而退回名字匹配。调用方：本文件 `arrayIterationCall`（`:1432`）、`arrayFlatCall`、`arrayByCopyCall`、`isArrayPrototypeRecord`，以及 `exec/string_ops.zig:2919`、`:2949`。

### `isArrayPrototypeRecord` (`src/exec/array_ops.zig:4631`)

- **签名**：`pub fn isArrayPrototypeRecord(function_object: *core.Object, method_id: u32) bool`。
- **作用**：判断一个函数对象是不是 `.array` 域里指定 id 的**原型**方法记录。
- **实现**：一行 `return arrayPrototypeRecordId(function_object) == method_id`（`null` 与任何 id 都不相等，因此非 `.array` 域自动为 false）。
- **所有权 / 错误 / 调用**：无：一行转发 `arrayPrototypeRecordId(function_object) == method_id`，不分配、无 error set。它是本文件十余个 `*Call` 开头那句「record id 优先、名字回退」身份门的前半句，调用方遍布 array_ops 与 `exec/string_ops.zig`（经别名）。

### `typedArrayOfStaticCall` (`src/exec/array_ops.zig:4635`)

- **签名**：`pub fn typedArrayOfStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`%TypedArray%.of`：this 必须是构造器，用 `typedArrayCreateWithLength(argc)` 造视图后逐个 `typedArraySetElementValue`。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`call_runtime.isConstructorLike`、`math.maxInt`、`typedArrayCreateWithLength`、`objectFromValue`、`typedArraySetElementValue`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 值；`constructor_value` 借用，输出由 species 构造器产出并已在 `typedArrayCreateWithLength` 里做过类型与长度校验。每个参数经 `typedArraySetElementValue` 写入（对象元素会跑 ToPrimitive）。error set：`this` 不是构造器 → `error.TypeError`；`args.len > maxInt(u32)` → `error.RangeError`；输出不是对象 → `error.TypeError`；元素强制转换与写入透传。唯一调用方 `arrayOfCall`（`:4572`）。

### `createArrayFactoryDataPropertyOrThrow` (`src/exec/array_ops.zig:4655`)

- **签名**：`fn createArrayFactoryDataPropertyOrThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`Array.from`/`of` 这类工厂往输出写元素的统一入口：目标是 TypedArray 时走 `typedArrayDefineOwnProperty`（越界抛「out-of-bound index in typed array」），否则普通 `CreateDataPropertyOrThrow`。
- **实现**：关键调用：`object.isTypedArrayObject`、`typed_array.typedArrayDefineOwnProperty`、`Descriptor.data`、`throwTypeErrorMessage`、`createDataPropertyOrThrow`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：私有；无返回值，`value` 借用、写入后由目标持有。TypedArray 与普通对象走两条不同的定义语义：前者用 `typedArrayDefineOwnProperty`，返回 null（不是合法数值索引）→ `error.TypeError`，返回 false（越界）→ `throwTypeErrorMessage("out-of-bound index in typed array")` 后 `unreachable`；后者走可观察的 `createDataPropertyOrThrow`。调用方四处：`arrayFromCall`（`:3770`）、`fromArrayLikeSource` 的 `.array` 臂（`:4459`）、`arrayFromIteratorLike`（`:4550`）、`arrayOfCall`（`:4592`）。

### `createArrayDataOrTypedArrayElement` (`src/exec/array_ops.zig:4682`)

- **签名**：`pub fn createArrayDataOrTypedArrayElement( rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, ) !void`。
- **作用**：在数组或 TypedArray 上创建一个自有数据元素：TypedArray 走 `typedArraySetIndex`（下标不合法或写不进去即 TypeError），普通对象优先 dense 追加，否则 `defineOwnProperty`。
- **实现**：TypedArray 臂先 `arrayIndexFromAtom` 换下标。普通臂：private atom 且已存在同名 own 属性直接 TypeError；数字下标先试 `appendDenseArrayDefineIndex`（CreateDataProperty 定义的是新的 own 元素，不走原型链上的索引 setter）；回落 `defineOwnProperty`，其 `IncompatibleDescriptor`/`NotExtensible`/`ReadOnly` 都被翻成 `error.TypeError`。错误：error.TypeError、error.IncompatibleDescriptor、error.NotExtensible、error.ReadOnly。
- **所有权 / 错误 / 调用**：无返回值；`value` 借用。它是**不带 ctx 的 bare-runtime 版本**：不走 `createDataPropertyOrThrow`，因此不触发 proxy trap，也不接 caller 帧。三类结构性失败被统一翻成 `error.TypeError`——TypedArray 的非法索引/越界写、私有 atom 撞上已有 own 属性，以及 `defineOwnProperty` 的 `IncompatibleDescriptor` / `NotExtensible` / `ReadOnly`；其余错误（OOM）原样上抛。调用方 `exec/object_ops.zig:1745`、`exec/call_runtime.zig:2906`、`:2921`（spread / 解构建数组）。

### `typedArrayConstructorObject` (`src/exec/array_ops.zig:4706`)

- **签名**：`pub fn typedArrayConstructorObject(value: core.JSValue) ?*core.Object`。
- **作用**：判断一个值是不是 TypedArray 构造器函数对象（元素大小与 kind 都非 0），是则返回该对象。
- **实现**：薄封装，主体转发到 `objectFromValue`、`object.typedArrayElementSize`、`object.typedArrayKind`。
- **所有权 / 错误 / 调用**：无：纯谓词式取值，返回借用的构造器对象或 null（元素大小或 kind 为 0 就不是 TypedArray 构造器），不分配、无 error set。唯一调用方 `arrayFromCall`（`:3707`），用来决定 `Array.from` 是否走 TypedArray 源的直取长度快路。

### `arrayMapCall` (`src/exec/array_ops.zig:4712`)

- **签名**：`pub fn arrayMapCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`map` 的窄快路径，排在 `arrayMethodFastCall` 级联里 `arrayIterationCall` 之后——完整语义在 `arrayIterationModeCall`，只有那条先返回 `null` 时才会落到这里。
- **实现**：准入极窄：必须正好 1 个可调用参数、receiver 是 Array、callee 是 `map` 的 record id 或同名函数，任一不满足返回 `null`。命中后逐个 `getProperty` 取元素（**不**做 HasProperty 跳洞），回调只收一个参数（没有 index / receiver），输出是 `createArray(rt, null)` —— null 原型、不走 species，逐下标 `defineOwnProperty`。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`isCallableValue`、`property_ops.expectObject`、`object.isArray`、`callableObjectFromValue`、`isArrayPrototypeRecord`、`call_mod.nativeFunctionNameForVmEquals`、`Object.createArray`、`Object.destroyFromHeader`。
- **所有权 / 错误 / 调用**：返回 owned 的新数组（**挂 null 原型**，与 spec 路径 `arrayIterationModeCall` 的 species 输出不同），或 null 表示不适用（参数不是单个可调用、receiver 不是数组、函数身份不匹配）。失败由 `errdefer destroyFromHeader` 回收。回调经 `callValueOrBytecodeSyncInternal` 同步调用，不透传 caller 帧。error set：`getProperty` / 回调 / `defineOwnProperty` 透传。唯一调用方 `arrayMethodFastCall`（`:210`）——注意 `arrayPrototypeNativeRecord` 的 map 走的是 `arrayIterationModeCall`，两条路径的输出原型因此不同。

### `ArraySortEntry.freeEntry` (`src/exec/array_ops.zig:4749`)

- **签名**：`pub fn freeEntry(self: ArraySortEntry, ctx: *core.JSContext) void`。
- **作用**：释放 sort 条目上缓存的 ToString 字节。
- **实现**：薄封装，主体转发到 `allocator.free`。
- **所有权 / 错误 / 调用**：释放 `key` 缓存缓冲（`ctx.runtime.memory.allocator` 分配，`arraySortStringKey` 里 `toOwnedSlice` 出来的）；`value` 是借用的元素值，不碰。无 error set。调用方必须对**每个** entry 调一次：`arraySortCall`（`:4863` 的 `defer for`）、`arrayByCopyCall` 的 toSorted 臂（`:5185`）、`typedArrayByCopyCall` 的 toSorted 臂（`:5302`）。

### `SortScratch` (`src/exec/array_ops.zig:4762`)

- **签名**：`fn SortScratch(comptime T: type) type`。
- **作用**：生成 sort 生命期内的临时存储类型：优先从 runtime 的 `VmStackArena` 切窗口（对应 qjs 每次 sort 一次 malloc 的 `ValueSlot` 数组），切不出来才退回堆。
- **实现**：`comptime` 工厂，返回一个只有 `items: []T` 与 `heap: bool` 两个字段的结构。`acquire(rt, n)` 先试 `rt.vm_stack.carveTyped(&rt.memory, T, n)` 从 VM 栈 arena 切窗口，切不出来才 `rt.memory.alloc(T, n)` 并把 `heap` 置真；`release` 只在 `heap` 为真时 `rt.memory.free`，arena 窗口交给调用方的 mark/restore 回收。对应 qjs 每次 sort 一次 malloc 的 `ValueSlot` 数组（quickjs.c:43428），区别是常见规模下走 arena、零 malloc。
- **所有权 / 错误 / 调用**：comptime 泛型容器：`acquire` 优先从 `rt.vm_stack` 这块 VM 栈 arena 切窗口（arena 是严格 LIFO，调用方必须用 `vm_stack.mark()` / `restore()` 括起来），切不到才退回堆。`release` 只在 `heap` 为真时 free——arena 窗口由 mark/restore 统一回收。它只管缓冲，不管缓冲里 JSValue 的根身份（那是 `SortEntryRootWindow` 的事）。实例化处三处：`SortEntryRootWindow.rooted_values`、`arraySortCall` 的 `entries_scratch`、`stableArraySortEntries` 的 `temp_scratch`。

### `ArraySortEntry.acquire` (`src/exec/array_ops.zig:4767`)

- **签名**：`fn acquire(rt: *core.JSRuntime, n: usize) !@This()`。
- **作用**：从 VM 栈 arena 切 scratch，失败则堆分配。
- **实现**：薄封装，主体转发到 `This`、`vm_stack.carveTyped`、`memory.alloc`。
- **所有权 / 错误 / 调用**：返回持有窗口的 `SortScratch`：arena 命中时 `heap = false`（**不能 free**，靠调用方的 `vm_stack.restore` 回收），落堆时 `heap = true` 由 `release` 负责。error set 只有堆分配的 `error.OutOfMemory`。调用方 `SortEntryRootWindow.activate`（`:4792`）、`arraySortCall`（`:4878`）、`stableArraySortEntries`（`:5036`）。

### `ArraySortEntry.release` (`src/exec/array_ops.zig:4772`)

- **签名**：`fn release(self: @This(), rt: *core.JSRuntime) void`。
- **作用**：若 scratch 来自堆则释放；arena 窗口由调用方 mark/restore。
- **实现**：薄封装，主体转发到 `This`、`memory.free`。
- **所有权 / 错误 / 调用**：只在 `heap` 为真时 `rt.memory.free`，arena 窗口是空操作；无 error set。三个调用方都写成 `defer`：`SortEntryRootWindow.deactivate`（`:4806`）、`arraySortCall`（`:4861`）、`stableArraySortEntries`（`:5037`）。

### `SortEntryRootWindow.activate` (`src/exec/array_ops.zig:4787`)

- **签名**：`inline fn activate(self: *@This(), rt: *core.JSRuntime, entries: []const ArraySortEntry) !void`。
- **作用**：把本结构的值切片登记为 GC 根。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。含循环：按 length 或迭代器步进处理元素。关键调用：`@This`、`SortScratch`、`acquire`、`frame.activate`。
- **所有权 / 错误 / 调用**：`entries` 只借用来抄值：把每个 entry 的 `value` 复制进一块 arena/堆窗口，再以 `.borrowed` 切片挂 `ValueRootFrame`——因为保守栈扫描只看得见缓冲指针、看不见缓冲里的值。`value_root_frames_enabled` 关闭时整个函数是空操作，`entries.len == 0` 时也不分配不激活（这与 `deactivate` 的同条件早退配对，正是 `-Dzjs_gc_roots_diag` 在 `[].sort()` 上抓到的 LIFO 违规的修法）。error set：`SortScratch.acquire` 的 OOM。调用方 `arraySortCall`（`:4905`）与 `arrayByCopyCall` 的 toSorted 臂（`:5201`）。

### `SortEntryRootWindow.deactivate` (`src/exec/array_ops.zig:4797`)

- **签名**：`fn deactivate(self: *@This(), rt: *core.JSRuntime) void`。
- **作用**：从根链卸下；空窗口不得 deactivate（LIFO）。
- **实现**：窗口为空（`rooted_values.items.len == 0`）时直接返回——`activate` 对空 entries 根本没 push 帧，再 deactivate 就是 LIFO 违规（精确根构建下 `[].sort()` 会炸）。否则 `frame.deactivate` 再 `rooted_values.release`。
- **所有权 / 错误 / 调用**：先 `frame.deactivate` 再 `rooted_values.release`（次序与 `activate` 相反，满足根帧与 arena 双重 LIFO），然后把字段清回空值以免重复释放；`rooted_values.items.len == 0` 直接返回，对应 `activate` 从未 push 帧的情形。无 error set。调用方与 `activate` 成对（`:4906`、`:5202`），都写成 `defer`。

### `arraySortCall` (`src/exec/array_ops.zig:4809`)

- **签名**：`pub fn arraySortCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.sort` / `%TypedArray%.prototype.sort` 的原地排序。
- **实现**：callee 对不上 record id / 函数名 `sort` 时返回 `null`。比较器非 undefined 且不可调用即 `error.TypeError`（先于任何元素访问）。TypedArray 域方法要求 TypedArray this 并查 detached/OOB/immutable。收集阶段：**完全 dense 的普通数组**（receiver 就是该对象、fast array、无 exotic、`fastArrayCount() == length`）直接从 `fastArrayValues()` 切一块 arena 窗口读；否则逐下标 `HasProperty` + `Get`。`undefined` 元素不进 entries，只记数（最终排到末尾），洞连记都不记。排序用 `stableArraySortEntries`，整段用 `SortEntryRootWindow` 做精确根。写回：若数组仍是同一完全 dense 形态就直接写槽（`order == sorted_index` 的跳过），否则逐下标 `setValuePropertyOrThrow` 写元素、补 `undefined`、再把剩下的下标 delete 掉。含循环：按 length 或迭代器步进处理元素。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 `receiver_object_value`（原地排序，不新建对象），或 null 表示函数身份不匹配。所有权/GC 是这条路最密的地方：`vm_stack.mark()` + `defer restore` 括住所有 arena 取用；收集到的 `entries` 可能来自 arena（dense receiver）或 `std.ArrayList`（通用 walk），每个 entry 的 `key` 缓存由 `defer for (entries) |e| e.freeEntry(ctx)` 释放；排序期间 `SortEntryRootWindow` 把元素值挂成根。写回有两条：仍是同一段全 dense 时直接 `setFastArrayElementDup` 写槽，否则逐个 `setValuePropertyOrThrow` 并删掉尾部空洞——`entry.order == index` 的槽**跳过写入**（连 setter 都不调用，与 qjs 一致，对访问器/proxy receiver 可观察）。error set：comparator 不可调用 → `error.TypeError`；`%TypedArray%.prototype.sort` 的非 TypedArray/detached/immutable → `error.TypeError`；receiver 不是对象 → `error.TypeError`；comparator、ToString、属性读写透传。调用方 `arrayMethodFastCall`（`:212`）、`exec/call_runtime.zig:1290`、记录 hub `:259`。

### `arraySortCompare` (`src/exec/array_ops.zig:4970`)

- **签名**：`pub fn arraySortCompare( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, typed_array: bool, comparator_call: *CallSite, lhs: ArraySortEntry, rhs: ArraySortEntry, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !i32`。
- **作用**：有用户比较器时的两条目比较（`arrayByCopySortCompare` 在 comparator 非 undefined 时转到这里）。
- **实现**：非 TypedArray 时，两个值位相同（payload+tag 全等）就不调比较器，直接按原序号定序（qjs `js_array_cmp_generic`，quickjs.c:43378）；TypedArray 没有这条捷径，每对都要调（`js_TA_cmp_generic`，quickjs.c:58759）。比较器结果通过 error union 的 payload 指针就地读（避免 16 字节 JSValue 复制造成的 store-forwarding 停顿）：int32 直接按整数取符号，否则先试 float64 tag，再退到 `toNumberForDateMethod`（ToPrimitive(number) + bigint TypeError 形状），用 `(v>0)-(v<0)` 取符号，NaN 与 ±0 都给 0（quickjs.c:43385-43393）。结果为 0 时按 `order` 稳定定序。
- **所有权 / 错误 / 调用**：返回 `i32`，不分配。`comparator_call` 指向调用方栈上的 `CallSite`；两个 entry 按值传入（其中 `value` 是借用）。结果值刻意**通过 error union 的 payload 指针就地读**（拷成局部会踩到向量存→标量读的 store-forwarding 停顿）。语义细节：非 TypedArray 时 bit 相同的两个元素不进用户 comparator，直接按 `order` 稳定定序（qjs 同款捷径，TypedArray 没有）；int32 结果按整数判号，其余走 `toNumberForDateMethod`（BigInt 在那里报 `error.TypeError`）；NaN 与 ±0 都折成 0 并由 `order` 兜底。error set：comparator 与 ToNumber 的透传。唯一调用方 `arrayByCopySortCompare`（`:5556`）。

### `stableArraySortEntries` (`src/exec/array_ops.zig:5019`)

- **签名**：`pub fn stableArraySortEntries( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, typed_numeric_default: bool, comparator: core.JSValue, entries: []ArraySortEntry, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：对 `ArraySortEntry` 切片做稳定排序（Array 与 TypedArray 的 sort/toSorted 共用）。
- **实现**：少于 2 个元素直接返回。归并 scratch 从 VM 栈 arena 切（`mark`/`restore` 包住，切不出才上堆）。自底向上归并，`src`/`dst` 两块缓冲 ping-pong：每趟整块读写后交换角色，省掉「归并进 temp 再拷回」的一次复制，而比较器调用序列与拷回写法完全一致。比较用 `arrayByCopySortCompare`，只有结果**严格大于 0** 才取右侧，保证相等元素保持左优先（稳定），对齐 qjs `a_idx < b_idx` 的 tie-break（quickjs.c:43362 / 58759）。`errdefer` 在异常时把 `src` 拷回 `entries`，保证调用方的逐条目清理能看到每个元素及其缓存 key 恰好一次。含循环：按 length 或迭代器步进处理元素。
- **所有权 / 错误 / 调用**：无返回值，原地把 `entries` 排好序。`temp` 归并缓冲来自 `SortScratch`（arena 优先），本函数自己 `vm_stack.mark()` / `defer restore` 括住；`entries` 与 `temp` 之间乒乓交换，末尾若结果落在 `temp` 就 `@memcpy` 回 `entries`。**`errdefer if (src.ptr != entries.ptr) @memcpy(entries, src)` 是所有权关键**：comparator 抛出时某一趟只写了一半 `dst`，而 `src` 仍完整持有每个元素及其 `key` 缓存各一份，把它拷回去才能让调用方的 `freeEntry` 循环不重复释放、不漏释放。`entries` 里的值本身由调用方的 `SortEntryRootWindow` 持根。error set：`acquire` 的 OOM 与比较函数透传。调用方 `arraySortCall`（`:4908`）、`arrayByCopyCall` 的 toSorted 臂（`:5203`）、`typedArrayByCopyCall` 的 toSorted 臂（`:5311`）。

### `arrayByCopyCall` (`src/exec/array_ops.zig:5103`)

- **签名**：`pub fn arrayByCopyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`toReversed` / `toSorted` / `toSpliced` / `with` 四个 by-copy 方法的共用实现（TypedArray 版先转 `typedArrayByCopyCall`）。
- **实现**：按 record id 或函数名判出 mode，都对不上返回 `null`。`toSorted` 的比较器非 undefined 且不可调用即 TypeError。输出一律是 `createArrayByCopyOutput` 造的普通数组（**不**走 species）。`to_reversed`：倒序 `arrayCopyIndex`。`to_sorted`：逐下标 Get（不跳洞，`undefined` 单独记数排末尾），`stableArraySortEntries` 后 `defineArrayByCopyElement` 写出。`with_`：负下标折算，越界或非有限即 RangeError，替换位写新值、其余 `arrayCopyIndex`。`to_spliced`：算 start/deleteCount/insertCount，新长度超 2^53−1 抛 TypeError、超 `max_array_length` 抛 RangeError，然后头段、插入段、尾段依次写出。含循环：按 length 或迭代器步进处理元素。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的**新**数组（by-copy 系一律不改 receiver），或 null 表示身份/形态不匹配；输出由 `createArrayByCopyOutput` 建（普通数组，挂 realm 原型），所以元素可以直接 `defineArrayByCopyElement` 写而不必走可观察定义。`%TypedArray%` 方法先转交 `typedArrayByCopyCall`。toSorted 臂自己管一套排序资源：`vm_stack.mark()` + `defer restore`、`entries` 列表与每项 `key` 的 `freeEntry` 循环、`SortEntryRootWindow` 挂根。error set：comparator 不可调用 → `error.TypeError`；长度/新长度超 `max_array_length` 或 `with`/`toSpliced` 索引越界 → `error.RangeError`；插入后长度超 2^53-1 → `error.TypeError`；getter 与强制转换透传。调用方 `arrayMethodFastCall`（`:213`）、`exec/call_runtime.zig:1291`、记录 hub `:267`。

### `typedArrayByCopyCall` (`src/exec/array_ops.zig:5269`)

- **签名**：`pub fn typedArrayByCopyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, name: []const u8, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`%TypedArray%.prototype` 的 `toReversed` / `toSorted` / `with`（**没有** `toSpliced`，那个名字落回通用臂时返回 `null`）。
- **实现**：非 TypedArray 返回 `null`；detached/OOB 即 TypeError。输出用 `typedArrayCreateSameType`（同类新视图，不读用户 species）。`toReversed` 倒序拷；`toSorted` 先把全部元素读进 entries，默认比较器走 TypedArray 数值序（`typed_numeric_default = true`），排完再造输出写回；`with` 先强制替换值（可能触发用户 valueOf）再用**当前**长度校验下标，越界/非有限抛 RangeError。含循环：按 length 或迭代器步进处理元素。关键调用：`object.isTypedArrayObject`、`object.typedArrayDetached`、`object.typedArrayOutOfBounds`、`object.typedArrayLength`、`mem.eql`、`typedArrayCreateSameType`、`objectFromValue`、`typed_array.typedArrayGetIndex`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的新 TypedArray（`typedArrayCreateSameType` 用同类构造器造，不走 species 的用户 hook），或 null 表示名字不匹配（调用方再走普通数组臂）。toSorted 臂的 `entries` 列表与每项 `key` 由 `defer` 的 `freeEntry` + `deinit` 释放；**这条臂没有 `SortEntryRootWindow`**——元素是从 TypedArray 读出的数字/BigInt，不是任意对象引用。error set：非 TypedArray → null 之前先判 detached/越界 `error.TypeError`；`with` 的索引越界或非有限 → `error.RangeError`；元素强制转换（BigInt 与数字混用）→ `error.TypeError`；comparator 透传。唯一调用方 `arrayByCopyCall`（`:5156`）。

### `arrayFlatCall` (`src/exec/array_ops.zig:5344`)

- **签名**：`pub fn arrayFlatCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.flat` 与 `flatMap`（按 record id / 函数名分辨）。
- **实现**：输出数组经 `arraySpeciesCreate(receiver, 0)` / `@@species` 构造。`flatMap` 的 `args[0]` 必须可调用（否则 TypeError），深度固定 1，`args[1]` 是 thisArg；`flat` 的深度由 `args[0]` 经 ToIntegerOrInfinity 得出（NaN 或 ≤0 → 0，+Infinity → `maxInt(usize)`，缺省 1）。真正的展开在 `flattenIntoArray`，返回写入个数后再 `Set(length, written)`（仅当输出是数组）。callee 对不上时返回 `null`。关键调用：`callableObjectFromValue`、`arrayPrototypeRecordId`、`call_mod.nativeFunctionNameForVmBorrowed`、`dispatch_name.deinit`、`mem.eql`、`objectFromValue`、`primitiveObjectForAccess`、`source.isArray`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的输出对象，或 null 表示身份不匹配。输出来自 `arraySpeciesCreate(..., 0, ...)`（可能是用户构造器造的任意对象），因此元素由 `flattenIntoArray` 用 `createDataPropertyOrThrow` 写、`length` 只在输出确实是数组时才补写。`mapper_call` 的 `CallSite` 在本函数栈上，只传给第一层 flatten（递归层不带 mapper）。error set：`flatMap` 的 mapper 不可调用 → `error.TypeError`；输出不是对象 → `error.TypeError`；depth 强制转换、species 构造、getter/mapper 透传。调用方 `arrayMethodFastCall`（`:211`）、`exec/call_runtime.zig:1289`、记录 hub `:262`。

### `flattenIntoArray` (`src/exec/array_ops.zig:5410`)

- **签名**：`pub fn flattenIntoArray( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_value: core.JSValue, target: *core.Object, source_value: core.JSValue, source: *core.Object, source_length: usize, start: usize, depth: usize, mapper_call: ?*CallSite, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：spec `FlattenIntoArray`：把源的元素（可选先过 mapper）按剩余深度递归摊进目标数组，返回下一个可写下标。
- **实现**：缺席下标（空洞）用 `HasProperty` 跳过，不把 `undefined` 当元素。mapper 只在最外层调用一次（递归时传 null），参数是 `(element, index, source)`。元素在 `depth > 0` 且 `IsArray`（含 Proxy 递归解包）时递归展开：子长度对真数组读 `arrayLength()`，否则 Get `length`；深度为 `maxInt(usize)`（`flat(Infinity)`）时不再递减。否则写入前先查 `target_index > max_array_length` → `error.TypeError`，再 `createDataPropertyOrThrow`。含循环：按 length 或迭代器步进处理元素。关键调用：`propertyAtomFromLengthIndex`、`source_key.deinit`、`hasValueProperty`、`getValueProperty`、`lengthIndexValue`、`call_site.call3`、`objectFromValue`、`arraySpeciesOriginalIsArray`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回写到的下一个目标索引（调用方据此补 `length`）；递归自调用时把它接力下去。`source`/`target` 借用，元素读出后由 `createDataPropertyOrThrow` 交给目标。递归深度受 `depth` 参数限制（`maxInt(usize)` 表示 `Infinity`，那一层不减），**递归调用不带 mapper**——只有最外层映射，符合 spec。error set：`target_index > max_array_length` → `error.TypeError`；`arraySpeciesOriginalIsArray` 对 revoked proxy 的 `error.TypeError`；has/get/define 与 mapper 透传。调用方 `arrayFlatCall`（`:5405`）与自身递归（`:5450`）。

### `createArrayByCopyOutput` (`src/exec/array_ops.zig:5461`)

- **签名**：`pub fn createArrayByCopyOutput(rt: *core.JSRuntime, global: *core.Object, length: usize) !*core.Object`。
- **作用**：by-copy 方法的输出数组：realm 默认 `Array.prototype` + 预设 length 的普通数组（by-copy 按 spec 不走 species）。
- **实现**：`length > max_array_length` 即 `error.RangeError`，否则 `createArray` + `setArrayLength`。错误：error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的新数组（挂 realm 的 `Array.prototype`，长度先设好、元素后填），`global` 借用。error set：`length > core.array.max_array_length` → `error.RangeError`，分配 OOM。调用方全在 `arrayByCopyCall`：toReversed（`:5169`）、toSorted（`:5179`）、with（`:5220`）、toSpliced（`:5250`）。

### `typedArrayCreateSameType` (`src/exec/array_ops.zig:5468`)

- **签名**：`pub fn typedArrayCreateSameType( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, length: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：spec `TypedArrayCreateSameType`：用**源自身 kind 对应的 global 构造器**（不读用户 `constructor`/`@@species`）造一条等长新视图，by-copy 方法用。
- **实现**：关键调用：`typedArrayConstructorForObject`、`constructValueOrBytecode`、`lengthIndexValue`。
- **所有权 / 错误 / 调用**：返回 owned 的新 TypedArray。它取的是**同类构造器**（`typedArrayConstructorForObject` 读 global 上那个名字的当前值），不读 receiver 的 `constructor` / `Symbol.species`——by-copy 系按 spec 不走 species。error set：认不出 kind 或全局构造器不是对象 → `error.TypeError`，构造器本身的异常透传。调用方 `typedArrayByCopyCall` 三臂（`:5288`、`:5313`、`:5330`）。

### `typedArrayByCopyCoerceValue` (`src/exec/array_ops.zig:5481`)

- **签名**：`pub fn typedArrayByCopyCoerceValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：按目标视图的元素类别把值强制成可写入的形式：BigInt64/BigUint64（kind 11/12）走 ToBigInt，其余走 ToNumber 且 BigInt 输入直接 TypeError。
- **实现**：先 ToPrimitive(number)（用户 valueOf 在此触发）。关键调用：`toPrimitiveForNumber`、`object.typedArrayKind`、`value_ops.toBigIntValue`、`bigint.deinit`、`value_ops.createBigIntValue`、`primitive.isBigInt`、`value_ops.toNumberValue`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的强制转换结果值（BigInt 臂新建 BigInt 值，中间的 `value_ops.toBigIntValue` 句柄由 `defer bigint.deinit()` 释放；数字臂返回数字值）。会跑用户 ToPrimitive。error set：BigInt64/BigUint64 视图以外的类收到 BigInt → `error.TypeError`，`toBigIntValue` 对非 BigInt 可转值的 `error.TypeError`/`error.SyntaxError` 透传。调用方 `typedArrayConstructArrayLikeVm`（`:590`）、`typedArrayConstructArrayLikeOwnDataFast`（`:634`）、`arrayFillCall`（`:2849`）、`typedArrayByCopyCall` 的 with 臂（`:5324`）。

### `defineArrayByCopyElement` (`src/exec/array_ops.zig:5500`)

- **签名**：`pub fn defineArrayByCopyElement(rt: *core.JSRuntime, out: *core.Object, index: usize, value: core.JSValue) !void`。
- **作用**：往 array-by-copy 系列（`toSorted`/`with`/`toSpliced`/`toReversed`）正在构建的结果数组上钉一个下标元素。
- **实现**：两行：`atomFromUInt32(index)` 造下标 atom，`out.defineOwnProperty` 定义成可写、可枚举、可配置的数据属性（CreateDataPropertyOrThrow 语义）。结果数组是本函数自己新建的，所以不必走 `[[Set]]`，也不会触发 setter 或原型链。直接调用方有 `toSorted` 的排序回写与 undefined 尾填、`with` 的替换位、`toSpliced` 的插入段，以及 `arrayCopyIndex`（它先从源读再交给这里）。
- **所有权 / 错误 / 调用**：无返回值；直接 `defineOwnProperty` 写普通数据属性，`value` 借用、写入后由 `out` 持有。**不走 `createDataPropertyOrThrow`**，因为 by-copy 系的输出一定是本文件刚建的普通数组（没有 proxy/exotic），省掉一次可观察定义。error set：`defineOwnProperty` 的 OOM 等。调用方 `arrayByCopyCall` 的 toSorted/with/toSpliced 臂（`:5205`、`:5209`、`:5224`、`:5257`）与 `arrayCopyIndex`（`:5525`）。

### `arrayCopyIndex` (`src/exec/array_ops.zig:5509`)

- **签名**：`pub noinline fn arrayCopyIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source_receiver: core.JSValue, dest: *core.Object, from_index: usize, to_index: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`toReversed` / `with` / `toSpliced` 的 get+define，**没有** has 检查：缺席源下标在副本上变成 `undefined`。
- **实现**：`propertyAtomFromLengthIndex(from)` + `getValueProperty` + `defineArrayByCopyElement(dest, to)`。注释明确与 outlined `arrayCopyPresentIndex` 区分：那条 skip-missing 走 `createDataPropertyOrThrow`，本条缺席也定义属性。
- **所有权 / 错误 / 调用**：`noinline`；无返回值。源索引 atom 由 `defer key.deinit` 退 pin，读出的元素随即交给 `defineArrayByCopyElement`。与 `arrayCopyPresentIndex` 的关键差别：**不做 HasProperty 检查**，源的洞会在副本里变成实实在在的 `undefined`（这正是 toReversed / with / toSpliced 的 spec 语义）。`caller_function` / `caller_frame` 只透传给 Get。error set：getter 与定义的透传。调用方 `arrayByCopyCall` 四处（`:5172`、`:5227`、`:5253`、`:5266`）。

### `toIntegerOrInfinityForArrayByCopy` (`src/exec/array_ops.zig:5526`)

- **签名**：`pub fn toIntegerOrInfinityForArrayByCopy( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !f64`。
- **作用**：ToIntegerOrInfinity（BigInt 输入抛 TypeError，NaN → 0，±Infinity 原样保留，其余截断），by-copy / fill / copyWithin / 搜索的 fromIndex 都用它。
- **实现**：关键调用：`toPrimitiveForNumber`、`primitive.isBigInt`、`value_ops.toNumberValue`、`value_ops.numberValue`、`math.nan`、`math.isNan`、`math.isFinite`、`@trunc`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 f64，不分配；跑用户 ToPrimitive 后截断，NaN 与 ±0 归 0，±∞ 原样返回（调用方据此判 `isFinite`）。error set：BigInt → `error.TypeError`，ToPrimitive/ToNumber 透传。调用方 10 处：`typedArraySetCall` 的 offset（`:1152`）、`arrayFirstIndexStart`/`arrayLastIndexStart`（`:2165`、`:2184`）、`arrayCopyWithinCall` 的 TypedArray 臂三参数（`:2738`、`:2742`、`:2746`）、`arrayByCopyCall` 的 with/toSpliced（`:5215`、`:5238`）、`typedArrayByCopyCall` 的 with（`:5322`）、`arrayFlatCall` 的 depth（`:5393`）。

### `arrayByCopySortCompare` (`src/exec/array_ops.zig:5541`)

- **签名**：`pub fn arrayByCopySortCompare( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, typed_numeric_default: bool, comparator: core.JSValue, comparator_call: ?*CallSite, lhs: *ArraySortEntry, rhs: *ArraySortEntry, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !i32`。
- **作用**：`stableArraySortEntries` 的比较入口：三选一分派到用户比较器、TypedArray 默认数值序、或 Array 默认字符串序。
- **实现**：比较器非 undefined → `arraySortCompare`；否则 `typed_numeric_default` 为真 → `typedArrayDefaultSortCompare`；再否则按默认字符串序，每个操作数经 `arraySortStringKey` 转成字节 key（每个元素只 ToString 一次并缓存在条目上，对齐 qjs `js_array_cmp_generic`，quickjs.c:43398-43410），`std.mem.order` 比较，相等时按 `order` 稳定定序。
- **所有权 / 错误 / 调用**：返回 `i32`，不分配、不建根；两个 entry 以指针传入是为了让字符串键缓存能写回去。三条分支：有用户 comparator → `arraySortCompare`；TypedArray 默认序 → `typedArrayDefaultSortCompare`；否则按 qjs 的缓存字符串键比较，相等时用 `order` 稳定兜底。error set：comparator、ToString、`typedArrayDefaultSortCompare` 的 `error.TypeError` 透传。唯一调用方 `stableArraySortEntries`（`:5079`）。

### `arraySortStringKey` (`src/exec/array_ops.zig:5574`)

- **签名**：`fn arraySortStringKey( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, entry: *ArraySortEntry, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) ![]const u8`。
- **作用**：懒算并缓存一个 sort 条目的 ToString 字节 key（对齐 qjs `ValueSlot.str`），已有缓存直接返回。
- **实现**：`entry.key` 非空直接返回缓存。否则 `toStringForAnnexB` 把元素转成字符串（可能跑用户 `toString`/`valueOf`），`value_ops.appendRawString` 把它铺进一条局部 `ArrayList(u8)`（`errdefer bytes.deinit` 覆盖住写进 `entry.key` 之前的失败窗口），`toOwnedSlice` 出独立缓冲后存进 `entry.key` 再返回。对应 qjs `ValueSlot.str` 的懒缓存（quickjs.c:43398）：每个元素最多 ToString 一次，缓冲最终由 `ArraySortEntry.freeEntry` 释放。
- **所有权 / 错误 / 调用**：返回借用的键字节（**所有权在 `ArraySortEntry.key` 上，由 `freeEntry` 释放**，调用方不得 free）：首次调用 ToString 后 `toOwnedSlice` 出一块缓冲存进 entry，之后直接命中缓存。`errdefer bytes.deinit` 覆盖写缓存之前的失败窗口。这是 qjs `ValueSlot.str` 缓存的对应物——每个元素最多 ToString 一次。error set：ToString（可能跑用户 `toString`）与 OOM。唯一调用方 `arrayByCopySortCompare`（`:5563`、`:5564`）。

### `typedArrayDefaultSortCompare` (`src/exec/array_ops.zig:5592`)

- **签名**：`pub fn typedArrayDefaultSortCompare(rt: *core.JSRuntime, lhs: ArraySortEntry, rhs: ArraySortEntry) !i32`。
- **作用**：TypedArray 无比较器时的默认数值序：NaN 排最后、−0 排在 +0 前、其余按数值，全相等时按原序稳定。
- **实现**：数值臂里两个 NaN 互相打平走 `stableSortTieBreak`，只有一个 NaN 则它更大；两个零时按位模式区分 −0/+0。非数值（BigInt 元素）臂改用 `value_ops.compare` 的 `lt`/`gt` 两次比较，都不成立则稳定定序。关键调用：`value_ops.numberValue`、`math.isNan`、`stableSortTieBreak`、`@bitCast`、`value_ops.compare`、`less.asBool`、`greater.asBool`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 `i32`，不分配、不跑用户代码（只读数值或走引擎的 `value_ops.compare`）。error set：一侧是数字而另一侧不是 → `error.TypeError`（BigInt 与 Number 混排），`value_ops.compare` 透传。语义要点：NaN 一律排到最后（两个 NaN 之间按 `order` 稳定），-0 排在 +0 之前。唯一调用方 `arrayByCopySortCompare`（`:5558`）。

### `stableSortTieBreak` (`src/exec/array_ops.zig:5619`)

- **签名**：`pub fn stableSortTieBreak(lhs: ArraySortEntry, rhs: ArraySortEntry) i32`。
- **作用**：比较结果相等时的稳定定序：按条目记录的原始下标 `order` 决定先后。
- **实现**：`order` 小的返回 −1、大的返回 1、相同返回 0。
- **所有权 / 错误 / 调用**：无：只比 `ArraySortEntry.order`（收集时记下的原始下标）这个标量，不分配、无 error、不 retain `entry.value`。调用方 3 处，都在 `typedArrayDefaultSortCompare`：`src/exec/array_ops.zig:5600`（两边都是 NaN）、`:5611`（数值相等，含 ±0 已分出先后之后）、`:5618`（非数值，`lt` 与 `gt` 都不成立）。

### `typedArrayOwnKeys` (`src/exec/array_ops.zig:5625`)

- **签名**：`pub fn typedArrayOwnKeys(rt: *core.JSRuntime, source: *core.Object) ![]core.Atom`。
- **作用**：TypedArray 的 `[[OwnPropertyKeys]]`：先按当前长度列出 0..len-1 的整数下标，再补普通字符串键，最后补公开 symbol 键。
- **实现**：普通键里会跳过公开 symbol（留到第三趟）、canonical numeric index（已由第一趟覆盖）、`isTypedArrayInternalOwnKey` 认定的内部访问器名，以及已经收进来的重复键。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住（这里是 `rootAtomList`）。含循环：按 length 或迭代器步进处理元素。关键调用：`Object.freeKeys`、`runtime.rootAtomList`、`keys_roots.activate`、`keys_roots.deactivate`、`object.typedArrayLength`、`appendAtom`、`atom.atomFromUInt32`、`source.ownKeys`。
- **所有权 / 错误 / 调用**：返回 owned 的 atom 列表——调用方必须 `core.Object.freeKeys` 释放（`exec/object_ops.zig:1876` 这么做了）；失败路径由本函数的 `errdefer freeKeys` 兜底。两个 `[]Atom`（自建的 `keys` 与 `source.ownKeys` 的 `ordinary`）都用 `core.runtime.rootAtomList` 挂根，因为 `appendAtom` 会分配、可能触发 GC 而裸切片不是保守扫描根。顺序契约：先全部数值索引，再非 symbol 的普通键，最后 public symbol；`buffer`/`length`/`byteLength`/`byteOffset` 这些内部键被 `isTypedArrayInternalOwnKey` 滤掉。error set：`typedArrayLength` 的 detached 错误与分配 OOM。唯一调用方 `exec/object_ops.zig:1876`。

### `isTypedArrayInternalOwnKey` (`src/exec/array_ops.zig:5658`)

- **签名**：`pub fn isTypedArrayInternalOwnKey(atom_id: core.Atom) bool`。
- **作用**：判断某个 atom 是不是 TypedArray 的内部访问器名（`buffer` / `length` / `byteLength` / `byteOffset`）——ownKeys 不把它们当自有属性列出来。
- **实现**：直接与四个预定义 atom 比对。
- **所有权 / 错误 / 调用**：无：四个预定义 atom 的等值比较，不分配、不 retain atom、无 error。唯一调用方 `typedArrayOwnKeys`（`src/exec/array_ops.zig:5648`），在合并 ordinary own keys 时把这四个名字滤掉。

### `atomicsTypedArray` (`src/exec/array_ops.zig:5665`)

- **签名**：`pub fn atomicsTypedArray(value: core.JSValue, waitable: bool) !*core.Object`。
- **作用**：Atomics 目标 TypedArray 的校验：必须是 TypedArray，且元素类别在允许集合内，否则 TypeError。
- **实现**：`waitable` 为真时只允许 kind 6（Int32Array）与 11（BigInt64Array）；否则允许 1/2/4/5/6/7/11/12（即除 Uint8Clamped 与三种浮点外的整数类）。关键调用：`property_ops.expectObject`、`object.isTypedArrayObject`、`object.typedArrayKind`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回借用的 `*core.Object`（调用方不得释放）。不分配、不跑用户代码。`waitable` 为真时只接受 Int32Array / BigInt64Array（`Atomics.wait` 系），否则接受全部整数类；任何不符都是裸 `error.TypeError`，消息由上层 Atomics 记录边界补。调用方 `exec/atomics_ops.zig:223`、`:262`、`:295`、`:317`、`:1178` 等。

### `atomicsTypedArrayIsBigInt` (`src/exec/array_ops.zig:5677`)

- **签名**：`pub fn atomicsTypedArrayIsBigInt(object: *core.Object) bool`。
- **作用**：判断 Atomics 目标是不是 BigInt 视图（kind 11 = BigInt64Array、12 = BigUint64Array），决定操作数走 BigInt 还是 Number。
- **实现**：薄封装，主体转发到 `object.typedArrayKind`。
- **所有权 / 错误 / 调用**：无：一行谓词（kind 11/12 即 BigInt64Array / BigUint64Array），不分配、无 error set。调用方 `exec/atomics_ops.zig:228`、`:268`、`:322`、`:1183`——它决定 Atomics 的操作数按 BigInt 还是 Number 强制转换。

## 覆盖核对

- 清单函数数（本文件分到）: 69（`src/exec/array_ops.zig` 全文件 231）
- 本文标题覆盖: 69
- 未覆盖: 无
