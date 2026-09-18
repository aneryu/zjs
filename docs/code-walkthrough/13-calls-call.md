# 13 — `call.zig`：公共 Call 入口与 host 全局

无活动 Machine 时的调用入口、CLI 可见 host 全局、`NativeEntry` 分发、无 Realm 的 `Object.*` 回退。热路径 ABI 是显式 `ctx`/`output`/`global`/caller-function/caller-frame，不经共享 context 再发布。对照 `js_call_c_function` 与 `OP_call_method`（quickjs.c:17562、18220）。

## 类型

- `HostFunction`：引擎内部 host 可调用枚举，目前只有 `output`。嵌入者函数是 `NativeEntry`，不扩展此枚举。删除的 qjs:std/os 槽位冻结留空。
- `HostCall` / `HostCallFlags` / `HostFunctionRecord`：`print` 一类 id 分发。`host_function_records` 表。
- `output_host_entry`：`print` 与 `console.log/warn/error` 共享的静态 managed `NativeEntry`；writer 来自活动 invocation 的 `vmCallerView`。
- `VmDispatchName`：borrowed 或 owned 的 dispatch 名；`deinit` 只在 owned 时 free。
- `string_construct_ref`：String 装箱走 String construct 记录。
- `PromiseCombinatorCallbackMode` / `PromiseCapability`：遗留 Promise 合成函数（主路径已迁 `promise_ops`）。

---

### `hostResult` (`src/exec/call.zig:42`)

- **签名**：`fn hostResult(result: anytype) HostError!switch (@typeInfo(@TypeOf(result)))`。
- **作用**：把任意 error union 收成 `HostError`。
- **实现**：`catch |err| @errorCast(err)`。非 error union `@compileError`。
- **所有权 / 错误 / 调用**：Realm 创建、btoa 等。

### `restoreEvalGlobalLexicals` (`src/exec/call.zig:49`)

- **签名**：`pub fn restoreEvalGlobalLexicals( ctx: *core.JSContext, global: *core.Object, saved_lexicals: ?*core.Object, keep_active_lexicals: bool, ) !void`。
- **作用**：间接 eval / `$262.evalScript` 结束后恢复 `ctx.lexicals`，并把当前词法写回 global。
- **实现**：`global.setGlobalLexicals(active)`；keep 则留 active，否则回到 saved。
- **所有权 / 错误 / 调用**：`indirectEval` 与 `evalGlobalScriptSource` 的 err/ok 路径都调。

### `hostGlobalOwnPropertyCapacity` (`src/exec/call.zig:63`)

- **签名**：`pub fn hostGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize`。
- **作用**：host 全局自有属性容量：标准全局 + 6（print、globalThis、NaN、Infinity、undefined、console）。
- **实现**：加法。
- **所有权 / 错误 / 调用**：`installHostGlobals`。

### `contextGlobalOwnPropertyCapacity` (`src/exec/call.zig:67`)

- **签名**：`pub fn contextGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize`。
- **作用**：再加 `scriptArgs`（CLI）。
- **实现**：+1。
- **所有权 / 错误 / 调用**：公共 CLI host setup。

### `installHostGlobals` (`src/exec/call.zig:71`)

- **签名**：`pub fn installHostGlobals(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：安装 CLI 可见 host 全局。必须先 `installStandardGlobals`，否则 Realm 未建立不能发 host placeholder。
- **实现**：reserve → 标准全局 → print NativeEntry → globalThis → NaN/Infinity/undefined → console auto-init。
- **所有权 / 错误 / 调用**：裸 runtime 嵌入者。

### `defineConsoleObject` (`src/exec/call.zig:87`)

- **签名**：`fn defineConsoleObject(rt: *core.JSRuntime, global: *core.Object, entry: *const core.NativeEntry) !void`。
- **作用**：`console` 延迟 AUTOINIT 属性。
- **实现**：`defineConsoleAutoInitProperty`，host id `output`。
- **所有权 / 错误 / 调用**：不自己建 `console` 对象：`defineConsoleAutoInitProperty` 只在全局上装一个 AUTOINIT 槽，真正的对象等第一次读 `console` 时才物化；`entry` 是模块级静态 `output_host_entry`，按指针借用，没有生命周期问题。error set 为分配错误。唯一调用方是本文件的全局安装流程（`call.zig:84`）。

### `outputHostThunk` (`src/exec/call.zig:107`)

- **签名**：`fn outputHostThunk( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`print`/`console.*` 的 managed C 入口。
- **实现**：无 global → `InvalidBuiltinRegistry` 哨兵。`hostOutputValues` 用 `vmCallerView(ctx).output`。
- **所有权 / 错误 / 调用**：NB2 managed。

### `callValue` (`src/exec/call.zig:124`)

- **签名**：`pub fn callValue( ctx: *core.JSContext, output: ?*std.Io.Writer, callee: core.JSValue, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：this=undefined、无 globals 的调用。
- **实现**：转 `callValueWithThisAndGlobals`。
- **所有权 / 错误 / 调用**：测试/算法。

### `callValueWithThis` (`src/exec/call.zig:133`)

- **签名**：`pub fn callValueWithThis( ctx: *core.JSContext, output: ?*std.Io.Writer, this_value: core.JSValue, callee: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：指定 this。
- **实现**：空 globals。
- **所有权 / 错误 / 调用**：纯转发（`globals` 传空切片），不分配、不建根；`this_value`/`callee`/`args` 全部借用，需由调用方在调用期间保活。error set 推断自 `callValueWithThisAndGlobals`（JS 异常以 `error.JSException` + `ctx` 上的 pending 值返回）。树内只有测试用（`src/tests/exec.zig:5850`、`5857`）；它是留给嵌入者的 pub 形态。

### `callValueWithThisAndGlobals` (`src/exec/call.zig:143`)

- **签名**：`pub fn callValueWithThisAndGlobals( ctx: *core.JSContext, output: ?*std.Io.Writer, globals: []globals_mod.Slot, this_value: core.JSValue, callee: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：带测试全局槽。
- **实现**：`global=null`。
- **所有权 / 错误 / 调用**：c_closure 回调。

### `callValueWithThisGlobalsAndGlobal` (`src/exec/call.zig:154`)

- **签名**：`pub fn callValueWithThisGlobalsAndGlobal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, input_this_value: core.JSValue, input_callee: core.JSValue, input_args: []const core.JSValue, ) !core.JSValue`。
- **作用**：无 Machine 的分类 Call。
- **实现**：≤8 参栈拷；更多则先 root 源窗口再 `ValueRootBuffer.initCopy`（分配是 GC 点）。root this/callee/args。Proxy apply；`expectCallableObject`；bound；遗留 Promise 合成函数；internal tag；hostFunctionKind；bytecode → `callValueOrBytecodeRoot`；c_closure；否则 `callNativeBuiltin`。
- **所有权 / 错误 / 调用**：非可调用 TypeError。测试证明 overflow args 在 copy 分配时仍活。

### `hostFunctionRecordFromId` (`src/exec/call.zig:273`)

- **签名**：`fn hostFunctionRecordFromId(value: i32) ?HostFunctionRecord`。
- **作用**：id → 记录。
- **实现**：越界 null。
- **所有权 / 错误 / 调用**：读 comptime 建好的 `host_function_records` 表，按值返回 `?HostFunctionRecord`（内含函数指针，不涉及所有权），越界/负值返回 `null`。不分配、不抛。调用方 `call.zig:223`（通用调用分发）与 `329`（VM 免 globals 分发），两处都把 `null` 翻成 `error.TypeError`。

### `callHostFunction` (`src/exec/call.zig:278`)

- **签名**：`fn callHostFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, func_obj: *core.Object, this_value: core.JSValue, args: []const core.JSValue, record: HostFunctionRecord, flags: HostCallFlags, ) !core.JSValue`。
- **作用**：C 函数预检 + Realm 视图 + native backtrace 后调记录。
- **实现**：`preflightCFunctionCall`；忽略 globals；`finalCallableRealmView`；错误 `materializeRuntimeError`。
- **所有权 / 错误 / 调用**：print。

### `callHostFunctionObjectForVm` (`src/exec/call.zig:318`)

- **签名**：`pub fn callHostFunctionObjectForVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, this_value: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：VM 路径：仅无 globals 即可分发的 host id。
- **实现**：kind 0 或非 output → null。
- **所有权 / 错误 / 调用**：`callNativeCallableObject`。

### `hostFunctionCanDispatchFromVmWithoutGlobals` (`src/exec/call.zig:333`)

- **签名**：`fn hostFunctionCanDispatchFromVmWithoutGlobals(kind: i32) bool`。
- **作用**：目前只有 `output`。
- **实现**：相等比较。
- **所有权 / 错误 / 调用**：纯枚举比较，不分配、不抛：目前只有 `output`（print/console.log）允许在没有 `globals` 数组的情况下直接从 VM 分发。唯一调用方 `callHostFunctionObjectForVm`（`call.zig:328`），不满足时返回 `null` 让 VM 退回带 globals 的慢路径。

### `definePredefinedHostEntryFunction` (`src/exec/call.zig:337`)

- **签名**：`fn definePredefinedHostEntryFunction( rt: *core.JSRuntime, target: *core.Object, comptime name: []const u8, length: i32, entry: *const core.NativeEntry, ) !void`。
- **作用**：预定义 atom 上挂 AUTOINIT host 函数。
- **实现**：`defineHostAutoInitPropertyWithEntry`，id output。
- **所有权 / 错误 / 调用**：`print`。

### `predefinedStringAtom` (`src/exec/call.zig:357`)

- **签名**：`fn predefinedStringAtom(comptime name: []const u8) core.Atom`。
- **作用**：编译期预定义 string atom。
- **实现**：`atom.predefinedId(name, .string).?`。
- **所有权 / 错误 / 调用**：comptime 求值的预定义 atom 查表（找不到就 `.?` 触发编译期错误），运行期零成本，atom 是常量 id、不计引用。调用方 `defineConsoleObject`（`call.zig:88`）与 `definePredefinedHostEntryFunction`（`346`）。

### `defineObjectProperty` (`src/exec/call.zig:361`)

- **签名**：`pub fn defineObjectProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void`。
- **作用**：可写可枚举可配置数据属性。
- **实现**：`Descriptor.data(..., true, true, true)`。
- **所有权 / 错误 / 调用**：广泛。

### `defineGlobalThisProperty` (`src/exec/call.zig:365`)

- **签名**：`fn defineGlobalThisProperty(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：`globalThis` 指向自身，可写不可枚举可配置。
- **实现**：`defineOwnPropertyAssumingNew`。
- **所有权 / 错误 / 调用**：把全局对象自身的值写成 `globalThis` 属性（writable、non-enumerable、configurable），形成全局对象对自己的自引用边——由属性表持有，不需要额外建根。用的是 `defineOwnPropertyAssumingNew`，前提是安装期该键必不存在。error set 为分配错误。唯一调用方是全局安装流程（`call.zig:79`）。

### `defineConstantPropertyAssumingNew` (`src/exec/call.zig:369`)

- **签名**：`fn defineConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void`。
- **作用**：不可写常量。
- **实现**：intern + assuming new。
- **所有权 / 错误 / 调用**：`internAtom` 得到的 atom 归 `AtomTable`，调用方不释放；`value` 交给属性表持有。写的是全不可变描述符（non-writable/non-enumerable/non-configurable），且假定键不存在。唯一调用方是 `defineNumberConstantPropertyAssumingNew` 的非预定义名回退（`call.zig:376`）。

### `defineNumberConstantPropertyAssumingNew` (`src/exec/call.zig:374`)

- **签名**：`fn defineNumberConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: f64) !void`。
- **作用**：NaN/Infinity。
- **实现**：预定义 atom 优先。
- **所有权 / 错误 / 调用**：预定义 atom 命中时直接写属性表（省掉 intern），否则转 `defineConstantPropertyAssumingNew`；数值经 `numberToValue` 变成立即数或堆 double，由属性表持有。error set 为分配错误。调用方是全局安装的 `NaN`/`Infinity` 两处（`call.zig:80`、`81`）。

### `promiseObjectFromValue` (`src/exec/call.zig:382`)

- **签名**：`fn promiseObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：promise class 或 null。
- **实现**：class_id 检查。
- **所有权 / 错误 / 调用**：测试。

### `expectCallableObject` (`src/exec/call.zig:388`)

- **签名**：`pub fn expectCallableObject(value: core.JSValue) ?*core.Object`。
- **作用**：可调用对象门（含四类 bytecode）。
- **实现**：c_function / data / async resume / bytecode / c_closure / bound。
- **所有权 / 错误 / 调用**：`callValueWithThisGlobalsAndGlobal`。

### `promiseResolvingFunctionCall` (`src/exec/call.zig:401`)

- **签名**：`fn promiseResolvingFunctionCall(rt: *core.JSRuntime, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue`。
- **作用**：遗留 resolve/reject 一次性结算。
- **实现**：无 target 返回 null（不是这类函数）。已结算 no-op。写 result + rejected 标志。
- **所有权 / 错误 / 调用**：VM 主路径在 `promise_ops`；此为无 Realm 回退。

### `promiseCapabilityExecutorCall` (`src/exec/call.zig:413`)

- **签名**：`fn promiseCapabilityExecutorCall(rt: *core.JSRuntime, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue`。
- **作用**：executor 把 resolve/reject 写入 capability slot。
- **实现**：已填则 TypeError（不可二次执行）。
- **所有权 / 错误 / 调用**：不分配；`setPromiseCapability` 把 `resolve`/`reject` 两个值存进 capability 槽（对象接手，含写屏障）。返回 `null` 表示「这个函数对象不是 capability executor」，交给调用方继续试别的臂；capability 已被填过则按规范抛 `error.TypeError`（对应 QuickJS 的 already-set 检查）。唯一调用方 `call.zig:210`；`src/exec/call_runtime.zig:880` 走的是 `promise_ops` 里的同名实现，不是这一个。

### `promiseCombinatorElementCall` (`src/exec/call.zig:436`)

- **签名**：`fn promiseCombinatorElementCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, function_object: *core.Object, args: []const core.JSValue, ) HostError!?core.JSValue`。
- **作用**：Promise.all / allSettled / any 元素回调。
- **实现**：mode 0 → null。called 标志。写 values[index]；remaining==0 时 resolve 或 AggregateError reject。
- **所有权 / 错误 / 调用**：会再入 `callValueWithThisGlobalsAndGlobal`。

### `activeGlobalObject` (`src/exec/call.zig:496`)

- **签名**：`pub fn activeGlobalObject(_: *core.JSRuntime, global: ?*core.Object, globals: []globals_mod.Slot) !?*core.Object`。
- **作用**：显式 global 或槽 `globalThis`。
- **实现**：`getByAtom`。
- **所有权 / 错误 / 调用**：无 Realm 属性路径。

### `createPromiseBuiltinFunction` (`src/exec/call.zig:502`)

- **签名**：`fn createPromiseBuiltinFunction(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8, length: i32) !core.JSValue`。
- **作用**：带 Function.prototype 的 native data 函数。
- **实现**：无 global `InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：capability 的 resolve/reject。

### `createPromiseCapability` (`src/exec/call.zig:508`)

- **签名**：`fn createPromiseCapability( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, constructor_value: core.JSValue, constructor_object: *core.Object, ) !PromiseCapability`。
- **作用**：NewPromiseCapability。内建 Promise 快路径；否则 `new constructor(executor)`。
- **实现**：五值 root。名字 "Promise" 时直接 construct + 两个 resolving 函数。否则 slot+executor tag，调 constructor，校验 resolve/reject 可调用。
- **所有权 / 错误 / 调用**：测试覆盖 GC。主路径 `promise_ops`。

### `installTestStandardRealm` (`src/exec/call.zig:583`)

- **签名**：`fn installTestStandardRealm(ctx: *core.JSContext) !*core.Object`。
- **作用**：单测装标准 Realm。
- **实现**：`configureRuntime`；建 global_object；失败 rollback intrinsic。
- **所有权 / 错误 / 调用**：文件内测试。

### `getValuePropertyViaGlobalSlots` (`src/exec/call.zig:625`)

- **签名**：`pub fn getValuePropertyViaGlobalSlots( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, receiver: core.JSValue, key: core.Atom, ) !core.JSValue`。
- **作用**：无 Realm 时的 [[Get]]：沿原型，accessor 则调 getter。
- **实现**：ToObject；有 active global 用 sync internal call。
- **所有权 / 错误 / 调用**：bind 读 name/length（经 `getValuePropertyProxyAware`）；`reflect_ops` 取 proxy handler 的 trap 也直接用它。

### `getValuePropertyProxyAware` (`src/exec/call.zig:654`)

- **签名**：`fn getValuePropertyProxyAware( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, receiver: core.JSValue, key: core.Atom, ) !core.JSValue`。
- **作用**：有 global 走完整 `getValueProperty`（含 proxy）；否则槽路径。
- **实现**：分流。
- **所有权 / 错误 / 调用**：不分配、不建根；返回的属性值可能来自 getter/proxy trap（那条路会重入 JS 并可能抛）。有活跃 realm global 时走完整的 `object_ops.getValueProperty`，否则退到 `getValuePropertyViaGlobalSlots` 的裸运行时读法。调用方是 `Function.prototype.bind` 里取 `length`/`name` 两处（`call.zig:1522`、`1525`），那里的 target 已经被 `rooted_target` 建根。

### `hasOwnPropertyProxyAware` (`src/exec/call.zig:668`)

- **签名**：`fn hasOwnPropertyProxyAware( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, object: *core.Object, key: core.Atom, ) !bool`。
- **作用**：own 描述符，proxy 感知。
- **实现**：无 global 则 `hasOwnProperty`。
- **所有权 / 错误 / 调用**：bind 的 length。

### `setArrayIndex` (`src/exec/call.zig:683`)

- **签名**：`fn setArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：定义下标并抬 length。
- **实现**：`atomFromUInt32`。
- **所有权 / 错误 / 调用**：combinator values。

### `createPromiseSettlementRecord` (`src/exec/call.zig:691`)

- **签名**：`pub noinline fn createPromiseSettlementRecord(rt: *core.JSRuntime, rejected: bool, payload: core.JSValue) !core.JSValue`。
- **作用**：allSettled `{status, value|reason}`。
- **实现**：root payload。与 `promise_ops.promiseSettlementRecord` 同走；保留一份 outlined 拷贝。
- **所有权 / 错误 / 调用**：`promiseCombinatorElementCall`；`promise_ops.promiseSettlementRecord` 就是本函数的再导出别名。

### `createPromiseAggregateError` (`src/exec/call.zig:729`)

- **签名**：`fn createPromiseAggregateError(rt: *core.JSRuntime, global: ?*core.Object, errors: *core.Object) !core.JSValue`。
- **作用**：any 失败时的 AggregateError。
- **实现**：尽量用全局构造器 prototype；自有 name+errors。
- **所有权 / 错误 / 调用**：新建 error 对象，`errdefer core.Object.destroyFromHeader` 覆盖后续两次属性定义的失败；成功后返回 owned 值。`errors` 数组由调用方持有并通过 `errors` 属性挂进实例。原型从全局的 `AggregateError.prototype` 借来（`constructorPrototype` 是 borrowed 读），拿不到就建无原型对象。error set 为分配/属性读错误。唯一调用方 `Promise.any` 的全拒绝路径（`call.zig:483`）。

### `createPromiseCombinatorState` (`src/exec/call.zig:746`)

- **签名**：`fn createPromiseCombinatorState( rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object, ) !*core.Object`。
- **作用**：combinator 共享状态（remaining 初值 1）。
- **实现**：三值 root。
- **所有权 / 错误 / 调用**：测试注意增量 mark 下直接析构。

### `callNativeBuiltin` (`src/exec/call.zig:808`)

- **签名**：`fn callNativeBuiltin( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, this_value: core.JSValue, function_object: *core.Object, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：记录表分发；名字链已删。
- **实现**：`callNativeFunctionRecord` 空则 TypeError。
- **所有权 / 错误 / 调用**：自身不分配、不建根，只是把 `callNativeFunctionRecord` 的 `null`（未登记的 id）翻成 `error.TypeError`——旧的按字符串名匹配的链路已实测为冷路径并删除。error set 是精确的 `HostError`，被调 builtin 的 JS 异常照常以 pending + `error.JSException` 形式返回。唯一调用方是本文件通用调用分发的兜底臂（`call.zig:234`）。

### `callNativeFunctionRecord` (`src/exec/call.zig:824`)

- **签名**：`pub fn callNativeFunctionRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, this_value: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：`nativeEntry()` 或 decode id → `callInternalRecord`；`.host` 域走 `callHostGlobalNativeFunctionRecord`。
- **实现**：标准域落到这里表示坏 id → TypeError。
- **所有权 / 错误 / 调用**：VM 与慢路。

### `callHostGlobalNativeFunctionRecord` (`src/exec/call.zig:867`)

- **签名**：`pub fn callHostGlobalNativeFunctionRecord( ctx: *core.JSContext, global: ?*core.Object, this_value: core.JSValue, _: *core.Object, id: u32, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：HTML/zjs host：btoa/atob/queueMicrotask/gc/navigator/DOMException 非 new/species/CallSite 方法。
- **实现**：id switch。DOMException 无 new → TypeError 消息。CallSite 方法 `exception_ops.callSiteMethodById`。
- **所有权 / 错误 / 调用**：按 id 分派的纯路由：`btoa`/`atob`/`navigator.userAgent` 等臂返回新建字符串（owned 交给调用方），`species_getter` 直接把 `this_value` 借回，CallSite 方法走 `exception_ops.callSiteMethodById`。函数对象参数被 `_:` 丢弃。DOMException 的无 `new` 调用与未知 id 都是 TypeError；`global` 缺失 → `error.InvalidBuiltinRegistry`。调用方 `call.zig:858`（`.host` 域兜底）与 `src/exec/call_runtime.zig:315`。

### `functionBindCall` (`src/exec/call.zig:905`)

- **签名**：`pub fn functionBindCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, this_value: core.JSValue, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`Function.prototype.bind`。
- **实现**：不可调用 TypeError；thisArg 默认 undefined；rest 为 bound args。
- **所有权 / 错误 / 调用**：function 域记录与 VM bind 快路径都进这里。

### `createRealmObject` (`src/exec/call.zig:919`)

- **签名**：`pub fn createRealmObject(parent: *core.JSContext) HostError!core.JSValue`。
- **作用**：`$262.createRealm`：子 JSContext + `{global}`。
- **实现**：`createConstructingWithOptions` 继承 stack/unhandled；`WrongRuntimeThread` unreachable。`installOwnedRealmRef`。
- **所有权 / 错误 / 调用**：child 由 RealmRef 拥有。

### `callObjectStatic` (`src/exec/call.zig:959`)

- **签名**：`pub fn callObjectStatic( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：无 Realm 的 `Object.assign/create/keys/...`。
- **实现**：按 `StaticMethod` id。assign 只拷 enumerable；create 可 defineProperties；keys/values/entries 用 `ownEntriesArray`；描述符路径 `materializeMappedArgumentsDescriptorValue`；setPrototypeOf 映 PrototypeCycle/NotExtensible→TypeError。未知 id TypeError。
- **所有权 / 错误 / 调用**：`object_builtin_ops` 在 `global==null` 时委托。

### `objectStaticToObjectValue` (`src/exec/call.zig:1162`)

- **签名**：`fn objectStaticToObjectValue(ctx: *core.JSContext, global: ?*core.Object, value: core.JSValue) !core.JSValue`。
- **作用**：ToObject。null/undefined TypeError。
- **实现**：已是 object 原样；原语走 `primitiveWrapper`（string 经 String 记录）。
- **所有权 / 错误 / 调用**：ToObject：对象原样借回；原语要新建包装对象（owned 返回），原型从全局借（`primitivePrototypeFromGlobal`）；`null`/`undefined` → `error.TypeError`。函数不建根——包装对象建好即返回，中间没有可触发 GC 的第二次分配。调用方 19 处，全在本文件：`getValuePropertyViaGlobalSlots` 的 ToObject（`call.zig:633`）与各 `Object` 静态/原型方法臂（如 `970`、`1007`）。

### `objectAssignGet` (`src/exec/call.zig:1185`)

- **签名**：`fn objectAssignGet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, receiver: core.JSValue, desc: core.Descriptor, ) HostError!core.JSValue`。
- **作用**：assign 读源：data 或调 getter。
- **实现**：generic → undefined。
- **所有权 / 错误 / 调用**：data 描述符直接把槽里的值借回，accessor 则调 getter（`callValueWithThisGlobalsAndGlobal`，可重入 JS 并抛）。自身不分配、不建根，error set 是精确的 `HostError`。唯一调用方 `Object.assign` 的拷贝循环（`call.zig:981`）。

### `objectAssignSet` (`src/exec/call.zig:1203`)

- **签名**：`fn objectAssignSet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, target_value: core.JSValue, target: *core.Object, key: core.Atom, value: core.JSValue, ) !void`。
- **作用**：assign 写目标：setter / 只读拒绝 / 沿原型。
- **实现**：`setProperty` 把 ReadOnly 等映 TypeError，InvalidLength→RangeError。
- **所有权 / 错误 / 调用**：不分配；沿自有属性→原型链找到 accessor 就调 setter（重入 JS），否则落到 `target.setProperty`。所有 set 失败在这里统一归一：`ReadOnly`/`AccessorWithoutSetter`/`NotExtensible`/`IncompatibleDescriptor` → `error.TypeError`，`InvalidLength` → `error.RangeError`；只读数据属性与无 setter 的 accessor 提前抛 TypeError。唯一调用方 `Object.assign` 的拷贝循环（`call.zig:982`）。

### `objectIsSealed` (`src/exec/call.zig:1251`)

- **签名**：`fn objectIsSealed(rt: *core.JSRuntime, object: *core.Object) !bool`。
- **作用**：不可扩展且无一 configurable。
- **实现**：`ownKeys`。
- **所有权 / 错误 / 调用**：keys  defer free。

### `objectIsFrozen` (`src/exec/call.zig:1262`)

- **签名**：`fn objectIsFrozen(rt: *core.JSRuntime, object: *core.Object) !bool`。
- **作用**：sealed 且无一 writable data。
- **实现**：再扫 keys。
- **所有权 / 错误 / 调用**：`ownKeys` 返回的是新分配的键数组，用 `defer core.Object.freeKeys` 释放（数组本身是 native `[]Atom`，本函数中间不调用可重入 JS 的东西，所以不需要 atom 根提供者）。error set 为分配/属性读错误。唯一调用方 `Object.isFrozen` 臂（`call.zig:1132`）。

### `objectPrototypeMethodCall` (`src/exec/call.zig:1277`)

- **签名**：`pub fn objectPrototypeMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, method: i32, this_value: core.JSValue, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：无 Realm 的 `Object.prototype.*`（ordinal 1–10）。
- **实现**：toString / 调 toString / valueOf / hasOwn / isPrototypeOf / propertyIsEnumerable / __define(G|S)etter / __lookup(G|S)etter。
- **所有权 / 错误 / 调用**：object 域 `global==null`。

### `objectPrototypeToString` (`src/exec/call.zig:1307`)

- **签名**：`fn objectPrototypeToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：原语标签或 `objectToString`。
- **实现**：Undefined/Null/Boolean/Number/String/BigInt/Symbol 固定串。
- **所有权 / 错误 / 调用**：每个分支都用 `createStringValue` 新建字符串（owned 返回给调用方），对象分支转 `objectToString`。不建根、不 retain 入参。error set 为分配错误。唯一调用方是 `objectPrototypeMethodCall` 的 method 1（`call.zig:1287`）。

### `objectPrototypeValueOf` (`src/exec/call.zig:1318`)

- **签名**：`fn objectPrototypeValueOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue) !core.JSValue`。
- **作用**：ToObject。
- **实现**：`objectStaticToObjectValue`。
- **所有权 / 错误 / 调用**：纯转发 ToObject：对象原样借回、原语新建包装（owned）。`null`/`undefined` → `error.TypeError`。唯一调用方 `objectPrototypeMethodCall` 的 method 3（`call.zig:1295`）。

### `objectPrototypeHasOwn` (`src/exec/call.zig:1322`)

- **签名**：`fn objectPrototypeHasOwn(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`hasOwnProperty` 布尔。
- **实现**：getOwnProperty != null。
- **所有权 / 错误 / 调用**：不分配（`atomFromPropertyKey` 可能 intern 一个 atom，归 `AtomTable`），返回立即 boolean；receiver 是原语时 `objectStaticToObjectValue` 会造临时包装对象，用完即弃（由 GC 回收）。error set：键不可转成属性键或 receiver 是 null/undefined → TypeError。唯一调用方 `objectPrototypeMethodCall` 的 method 4（`call.zig:1296`）。

### `objectPrototypePropertyIsEnumerable` (`src/exec/call.zig:1332`)

- **签名**：`fn objectPrototypePropertyIsEnumerable(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：own enumerable。
- **实现**：无描述符 false。
- **所有权 / 错误 / 调用**：同 `objectPrototypeHasOwn` 的所有权形状（临时包装对象 + intern 的 atom 归表），只多读一次描述符的 `enumerable`；描述符缺失返回 `false`。唯一调用方 `objectPrototypeMethodCall` 的 method 6（`call.zig:1298`）。

### `objectPrototypeIsPrototypeOf` (`src/exec/call.zig:1342`)

- **签名**：`fn objectPrototypeIsPrototypeOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：沿 arg 原型链找 this。
- **实现**：非 object arg → false。
- **所有权 / 错误 / 调用**：不分配（除 receiver 是原语时的临时包装对象）；原型链用 `getPrototype()` 逐级借用遍历，不 retain。参数不是对象直接返回 `false`。唯一调用方 `objectPrototypeMethodCall` 的 method 5（`call.zig:1297`）。

### `objectPrototypeDefineAccessor` (`src/exec/call.zig:1354`)

- **签名**：`fn objectPrototypeDefineAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue`。
- **作用**：`__defineGetter__` / `__defineSetter__`。
- **实现**：accessor 必须可调用。Incompatible→TypeError。
- **所有权 / 错误 / 调用**：`__defineGetter__`/`__defineSetter__`：accessor 函数值交给描述符、由属性表持有；非可调用参数 → `error.TypeError`。`defineOwnProperty` 的失败被归一成 `TypeError`（`IncompatibleDescriptor`/`NotExtensible`/`ReadOnly`）与 `RangeError`（`InvalidLength`）。调用方 `objectPrototypeMethodCall` 的 method 7/8（`call.zig:1299`、`1300`，`getter` 参数区分两者）。

### `objectPrototypeLookupAccessor` (`src/exec/call.zig:1374`)

- **签名**：`fn objectPrototypeLookupAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue`。
- **作用**：沿链找 accessor 的 get/set。
- **实现**：非 accessor 描述符 → undefined。
- **所有权 / 错误 / 调用**：`__lookupGetter__`/`__lookupSetter__`：返回的是描述符槽里的 getter/setter 借用值，不 retain；沿原型链走到第一个命中的属性为止，命中的若不是 accessor 就返回 undefined。不分配（除原语 receiver 的临时包装）。调用方 `objectPrototypeMethodCall` 的 method 9/10（`call.zig:1301`、`1302`）。

### `isCallableObjectValue` (`src/exec/call.zig:1389`)

- **签名**：`pub fn isCallableObjectValue(value: core.JSValue) bool`。
- **作用**：与 `expectCallableObject` 同类集合，布尔。
- **实现**：class 检查。
- **所有权 / 错误 / 调用**：bind / capability。

### `primitiveWrapper` (`src/exec/call.zig:1399`)

- **签名**：`pub fn primitiveWrapper(ctx: *core.JSContext, class_id: core.class.ClassId, primitive: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：`Object(primitive)` / `new String` 装箱。
- **实现**：string 走 `callConstructRecord(string_construct_ref)`。其它 root primitive 进 objectData。
- **所有权 / 错误 / 调用**：测试 root 符号。

### `primitivePrototypeFromGlobal` (`src/exec/call.zig:1442`)

- **签名**：`fn primitivePrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, class_id: core.class.ClassId) ?*core.Object`。
- **作用**：`global.String.prototype` 等自有数据。
- **实现**：无 global / 无构造器 → null。
- **所有权 / 错误 / 调用**：两次 `getOwnDataObjectBorrowed` 都是借用读（不触发 getter、不分配、不抛），`rt` 参数被 `_ =` 丢弃。任何一步缺失就返回 `null`，调用方据此建无原型包装。唯一调用方 `objectStaticToObjectValue`（`call.zig:1182`）。

### `defineDataPropertyWithFlags` (`src/exec/call.zig:1458`)

- **签名**：`fn defineDataPropertyWithFlags( rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool, ) !void`。
- **作用**：带标志数据属性。
- **实现**：`Descriptor.data`。
- **所有权 / 错误 / 调用**：bound name/length。

### `boundFunctionNameValue` (`src/exec/call.zig:1470`)

- **签名**：`fn boundFunctionNameValue(rt: *core.JSRuntime, target_name: core.JSValue) !core.JSValue`。
- **作用**：`"bound " + name`。
- **实现**：非 string name 只留前缀。
- **所有权 / 错误 / 调用**：用运行时 allocator 的临时 `ArrayList` 拼 `"bound " ++ name`，`defer deinit` 释放，最终 `createStringValue` 新建字符串（owned 返回）。目标名不是字符串时只留 `"bound "` 前缀。error set 为分配错误。唯一调用方 `createBoundFunction`（`call.zig:1526`）。

### `boundFunctionLengthValue` (`src/exec/call.zig:1480`)

- **签名**：`fn boundFunctionLengthValue(target_length: core.JSValue, bound_arg_count: usize) core.JSValue`。
- **作用**：`max(0, ToInteger(length) - boundCount)`；NaN/−Inf→0；+Inf 保持。
- **实现**：trunc；负零当 0。
- **所有权 / 错误 / 调用**：纯数值运算，不分配、不抛、无 error set：NaN/−∞/负数一律 0，+∞ 原样保留，其余按 `trunc(length) − 绑定实参数` 且不小于 0。唯一调用方 `createBoundFunction`（`call.zig:1523`）。

### `createBoundFunction` (`src/exec/call.zig:1491`)

- **签名**：`fn createBoundFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, target: core.JSValue, bound_this: core.JSValue, bound_args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`[[BoundTarget]]`/`[[BoundThis]]`/`[[BoundArgs]]` + name/length。
- **实现**：proxy 感知读 length/name。原型拷 target。bound args 最后一步进 payload cell（无精确根窗口，靠 conservative + 不手 free）。Realm 在最终目标选择。
- **所有权 / 错误 / 调用**：`functionBindCall`。测试 GC。

### `Trigger.trigger` (`src/exec/call.zig:1637`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：分配点强制 cycle-removal，看 inline arg 是否仍 intern。
- **实现**：暂时摘掉 trigger 防重入；`tryRunObjectCycleRemovalWithValueRoots(..., .engine_active)`。
- **所有权 / 错误 / 调用**：测试局部 struct 的方法，不分配；安装成 `rt.memory.trigger_gc_fn` 后由分配路径经函数指针回调，没有直接调用方。先摘 hook 并 `defer` 还原以防重入，`tryRunObjectCycleRemovalWithValueRoots` 的错误被 `catch {}` 吞掉；断言点是实参符号 atom 是否仍存活（即参数窗口是否被当作根）。

### `Trigger.trigger` (`src/exec/call.zig:1714`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：`initCopy` 分配时证明 9 个符号仍活。
- **实现**：精确扫描；任一 atom 丢失设 `lost_arg`。
- **所有权 / 错误 / 调用**：同族探针的多实参版：`atom_ids` 是测试栈上的借用切片，回调只读不改；同样摘 hook + `defer` 还原、`catch {}` 吞错误，用 `collections`/`lost_arg` 记录多次收集后是否丢过实参。由 GC 触发钩子经函数指针调用。

### `callBoundFunction` (`src/exec/call.zig:1784`)

- **签名**：`fn callBoundFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, object: *core.Object, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：合并 bound args 再调 target，this 为 boundThis。
- **实现**：`boundFunctionArgs` + `freeArgs`。
- **所有权 / 错误 / 调用**：无 Machine 路径。

### `objectToString` (`src/exec/call.zig:1799`)

- **签名**：`fn objectToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：`[object Tag]`，Tag 来自 `Symbol.toStringTag` 或默认。
- **实现**：string tag 拼接。
- **所有权 / 错误 / 调用**：临时 ArrayList。

### `defaultObjectTag` (`src/exec/call.zig:1817`)

- **签名**：`fn defaultObjectTag(object: *core.Object) []const u8`。
- **作用**：class → 字面标签。
- **实现**：Array/Function/Map/Set/Promise/Arguments 等；否则 Object。
- **所有权 / 错误 / 调用**：静态串。

### `nativeFunctionName` (`src/exec/call.zig:1846`)

- **签名**：`pub fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8`。
- **作用**：可见 `name` 的 owned 字节。
- **实现**：`prefer_dispatch_name=false`。
- **所有权 / 错误 / 调用**：调用方 free。

### `nativeFunctionNameForVm` (`src/exec/call.zig:1854`)

- **签名**：`pub fn nativeFunctionNameForVm(rt: *core.JSRuntime, function_object: *core.Object) ![]u8`。
- **作用**：dispatch 名 owned 拷贝。
- **实现**：`nativeFunctionDispatchName`。
- **所有权 / 错误 / 调用**：热路径应改用 borrowed。

### `VmDispatchName.deinit` (`src/exec/call.zig:1872`)

- **签名**：`pub fn deinit(self: VmDispatchName, rt: *core.JSRuntime) void`。
- **作用**：释放 owned 回退字节。
- **实现**：`if (owned) free`。
- **所有权 / 错误 / 调用**：borrowed 路径 owned=null。

### `nativeFunctionNameForVmBorrowed` (`src/exec/call.zig:1893`)

- **签名**：`pub fn nativeFunctionNameForVmBorrowed(rt: *core.JSRuntime, function_object: *core.Object) !VmDispatchName`。
- **作用**：免分配 dispatch 名（对齐 qjs 用已解析 magic，不重派生名字）。
- **实现**：interned atom 字节；否则走分配路径以保留 utf16/get x/bind/符号名/`name` getter 副作用。
- **所有权 / 错误 / 调用**：atom 字节活到下次 atom 表变异；探针立即比较。

### `nativeFunctionNameForVmEquals` (`src/exec/call.zig:1905`)

- **签名**：`pub fn nativeFunctionNameForVmEquals( rt: *core.JSRuntime, function_object: *core.Object, expected: []const u8, ) !bool`。
- **作用**：eql 且含错误情况，无热路径分配。
- **实现**：borrowed + `mem.eql`。
- **所有权 / 错误 / 调用**：`VmDispatchName` 可能借 atom 表的字节（`owned == null`），也可能是 `nativeFunctionDispatchName` 新分配的副本；`defer dispatch.deinit(rt)` 同时覆盖两种情况，所以本函数对外零分配残留。error set 含分配错误与 `name` 非字符串的 `error.TypeError`（刻意与旧的分配路径逐一对齐）。调用方 17 处内建快臂身份检查：`src/exec/array_ops.zig:1335`、`1718`、`2207` 等 16 处与 `src/exec/string_ops.zig:3059`。

### `functionToStringValue` (`src/exec/call.zig:1915`)

- **签名**：`pub fn functionToStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：`Function.prototype.toString`。
- **实现**：裸 FB 用源文。Proxy：有 handler 且 target 可 toString 则 `[native code]`。bytecode 优先源文。bound 总是 native。其它函数 class 用 `functionSource` 或 native 模板。
- **所有权 / 错误 / 调用**：非可调用 TypeError。

### `nativeFunctionDispatchNameRef` (`src/exec/call.zig:1954`)

- **签名**：`pub fn nativeFunctionDispatchNameRef( rt: *core.JSRuntime, function_object: *core.Object, ) ?struct { name: []const u8, name_value: core.JSValue }`。
- **作用**：热分发借用 latin1 名。
- **实现**：dispatch atom 或自有 `name` 的 latin1；utf16 返回 null 让调用方走分配路径。
- **所有权 / 错误 / 调用**：`callNativeCallableByName` 数百万次。

### `stringLatin1BytesRef` (`src/exec/call.zig:1977`)

- **签名**：`fn stringLatin1BytesRef(value: core.JSValue) ?[]const u8`。
- **作用**：不拷 latin1。
- **实现**：utf16 null。
- **所有权 / 错误 / 调用**：零拷贝借用：返回的切片指向 `String` 本体的 latin1 数据，只在该字符串存活且未被移动/扁平化改写期间有效；utf16 返回 `null`。不分配、不抛。唯一调用方 `nativeFunctionDispatchNameRef`（`call.zig:1968`），它把字节和作为 owner 的 `name_value` 一起交出去。

### `nativeFunctionDispatchName` (`src/exec/call.zig:1985`)

- **签名**：`fn nativeFunctionDispatchName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8`。
- **作用**：owned dispatch 名。
- **实现**：dupe atom 或从可见名 `appendRawString`。
- **所有权 / 错误 / 调用**：调用方 free。

### `nativeFunctionNameValue` (`src/exec/call.zig:1999`)

- **签名**：`fn nativeFunctionNameValue(rt: *core.JSRuntime, function_object: *core.Object, prefer_dispatch_name: bool) !core.JSValue`。
- **作用**：dispatch 或 `name` 属性。
- **实现**：prefer → `nativeFunctionNameValueLocal`；否则 getProperty，非 string TypeError。
- **所有权 / 错误 / 调用**：返回的字符串值可能是 `nativeFunctionNameValueLocal` 里 `toStringValue` 新建的，也可能是 `name` 属性槽里的借用值；不建根，调用方须立刻消费。`name` 不是字符串 → `error.TypeError`。调用方三处，都在本文件：`call.zig:1847`、`nativeFunctionDispatchName`（`1992`）、`nativeFunctionSourceValue`（`2028`，用 `catch null` 容错）。

### `functionBytecodeToStringValue` (`src/exec/call.zig:2010`)

- **签名**：`fn functionBytecodeToStringValue( rt: *core.JSRuntime, function_bytecode: *const bytecode.FunctionBytecode, object: ?*core.Object, ) !core.JSValue`。
- **作用**：FB 源文或 native 模板。
- **实现**：`sourceText()`；否则 `functionSource`；否则 native。
- **所有权 / 错误 / 调用**：有源文本就 `createStringValue` 新建字符串（owned）；否则退到函数对象存的 `functionSource()`（借用值）或 `nativeFunctionSourceValue` 合成的 `[native code]` 串。error set 为分配错误。调用方是 `functionToStringValue` 的两处（`call.zig:1918` 裸 FB 值、`1931` 字节码函数对象）。

### `nativeFunctionSourceValue` (`src/exec/call.zig:2023`)

- **签名**：`fn nativeFunctionSourceValue(rt: *core.JSRuntime, object: ?*core.Object) !core.JSValue`。
- **作用**：`function name() {\n    [native code]\n}`。
- **实现**：可选插入过滤后的名。
- **所有权 / 错误 / 调用**：对齐 `js_function_toString` quickjs.c:41335。

### `appendNativeFunctionSourceName` (`src/exec/call.zig:2037`)

- **签名**：`fn appendNativeFunctionSourceName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), stored_name: core.JSValue) !void`。
- **作用**：空格 + 合法源名。
- **实现**：`nativeFunctionSourceName` null 则不加。
- **所有权 / 错误 / 调用**：临时 name_buffer。

### `nativeFunctionSourceName` (`src/exec/call.zig:2047`)

- **签名**：`fn nativeFunctionSourceName(name: []const u8) ?[]const u8`。
- **作用**：过滤 `get `/`set `/标识符/`[computed]`。
- **实现**：非法 getter 只留 `"get"`。
- **所有权 / 错误 / 调用**：纯字节判定，返回的是入参切片的子串（借用，不分配、不抛）：`get `/`set ` 前缀后若是合法属性名就保留整串，否则退成 `"get"`/`"set"`；都不合法返回 `null`（调用方据此不写名字）。唯一调用方 `appendNativeFunctionSourceName`（`call.zig:2042`）。

### `isNativeFunctionPropertyName` (`src/exec/call.zig:2060`)

- **签名**：`fn isNativeFunctionPropertyName(name: []const u8) bool`。
- **作用**：ASCII 标识符或 Unicode 标识符或 computed。
- **实现**：三者或。
- **所有权 / 错误 / 调用**：三个纯判定的或（简单标识符 / Unicode 标识符 / `[computed]` 形式），不分配、不抛。调用方只有本文件的 `nativeFunctionSourceName` 三处（`call.zig:2051`、`2055`、`2057`）。

### `isUnicodeIdentifierName` (`src/exec/call.zig:2070`)

- **签名**：`fn isUnicodeIdentifierName(name: []const u8) bool`。
- **作用**：UTF-8 IdentifierStart/Continue（「ém」合法，qjs 原样发出）。
- **实现**：非法 UTF-8 false。
- **所有权 / 错误 / 调用**：只读遍历 UTF-8 码点，不分配、不抛：非法 UTF-8 由 `Utf8View.init` 的 `catch return false` 挡掉。唯一调用方 `isNativeFunctionPropertyName`（`call.zig:2062`）。

### `isNativeFunctionComputedPropertyName` (`src/exec/call.zig:2086`)

- **签名**：`fn isNativeFunctionComputedPropertyName(name: []const u8) bool`。
- **作用**：`[...]` 且括号闭合在末尾；跟踪引号与转义。
- **实现**：引号内换行非法。
- **所有权 / 错误 / 调用**：栈上状态机（depth/quote/escaped 三个标量）扫字节，不分配、不抛。唯一调用方 `isNativeFunctionPropertyName`（`call.zig:2063`）。

### `isFunctionToStringCallable` (`src/exec/call.zig:2121`)

- **签名**：`fn isFunctionToStringCallable(value: core.JSValue) bool`。
- **作用**：toString 是否可对 proxy 目标递归。
- **实现**：FB / 函数 class / 有 handler 的 proxy。
- **所有权 / 错误 / 调用**：只读 class 与 proxy target 的递归判定，不分配、不抛、不 retain（revoked proxy 直接 false）。调用方 `functionToStringValue` 的 proxy 臂（`call.zig:1925`）与本函数自身的 target 递归（`2127`）。

### `thisObject` (`src/exec/call.zig:2130`)

- **签名**：`pub fn thisObject(value: core.JSValue) ?*core.Object`。
- **作用**：object JSValue → Object。
- **实现**：`isObject` + `fromHeader`。
- **所有权 / 错误 / 调用**：全文件。

### `constructorPrototype` (`src/exec/call.zig:2138`)

- **签名**：`pub fn constructorPrototype(rt: *core.JSRuntime, object: *core.Object) ?*core.Object`。
- **作用**：自有 `.prototype` 数据对象。
- **实现**：`getOwnDataObjectBorrowed`。
- **所有权 / 错误 / 调用**：`getOwnDataObjectBorrowed` 是借用读：不触发 getter、不分配、不抛，返回的原型对象由构造器的属性槽持有；`rt` 参数被 `_ =` 丢弃。调用方 `call.zig:537`、`564`、`735`（Promise/普通实例/AggregateError 三处取原型）。

### `hostOutputValues` (`src/exec/call.zig:2143`)

- **签名**：`fn hostOutputValues( ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, values: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：print：空格分隔，末尾换行。string 原样，其它 `printHostArgument`（对齐 `js_print` quickjs-libc.c:4063）。
- **实现**：写失败 `throwHostError`。无 writer 仍返回 undefined。
- **所有权 / 错误 / 调用**：不分配 JS 值（返回 undefined），只往借来的 `writer` 写字节。写失败的 `WriteFailed` 经 `exception_ops.throwHostError` 变成 `ctx` 上的 JS 异常，`OutOfMemory` 原样上抛，所以 error set 是精确的 `HostError`。`output` 为 `null` 时整函数是 no-op。调用方 `outputHostThunk`（`call.zig:119`，取 `vmCallerView` 的 writer）与 `hostCallOutput`（`2169`）。

### `hostCallOutput` (`src/exec/call.zig:2168`)

- **签名**：`fn hostCallOutput(call: HostCall) HostError!core.JSValue`。
- **作用**：id 表的 print 体。
- **实现**：`hostOutputValues` 用 realm 与 call.output。
- **所有权 / 错误 / 调用**：纯适配：把 `HostCall` 里已解析好的 realm/global/writer/args 拆开转给 `hostOutputValues`，不分配、不建根。没有普通调用方——它作为函数指针填进 comptime 表 `host_function_records[output]`（`call.zig:269`），由 `callHostFunction` 经 `record.call` 间接调用。

### `runNextOsSignalHandler` (`src/exec/call.zig:2172`)

- **签名**：`pub fn runNextOsSignalHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool`。
- **作用**：排一个信号处理器。
- **实现**：无 event loop false；错误 `@errorCast`。
- **所有权 / 错误 / 调用**：模块 await stall。

### `globalBtoa` (`src/exec/call.zig:2179`)

- **签名**：`fn globalBtoa(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：HTML `btoa`：latin1≤0xff → base64。
- **实现**：ToString；InvalidCharacter → DOMException。
- **所有权 / 错误 / 调用**：两段临时缓冲都归运行时 allocator 并 `defer deinit`（`stringToLatin1Bytes` 的 latin1 字节、`encodeBase64Bytes` 的结果），只有最后 `createStringValue` 产出 owned JS 字符串。`error.InvalidCharacter` 被翻成 DOMException `InvalidCharacterError`（`throwInvalidCharacter` 写 pending 异常并返回 `error.InvalidCharacterError`），其余错误上抛。唯一调用方 `callHostGlobalNativeFunctionRecord` 的 `btoa` 臂（`call.zig:876`）。

### `globalAtob` (`src/exec/call.zig:2192`)

- **签名**：`fn globalAtob(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`atob`：≤0x7f latin1，loose base64。
- **实现**：SyntaxError 同样 InvalidCharacter 消息。结果 ASCII string。
- **所有权 / 错误 / 调用**：同 `globalBtoa` 的缓冲纪律（两个 `defer deinit`），结果用 `String.createAscii` 新建 owned 字符串。`InvalidCharacter` 与解码的 `SyntaxError` 都收敛成同一个 DOMException `InvalidCharacterError`。唯一调用方 `callHostGlobalNativeFunctionRecord` 的 `atob` 臂（`call.zig:877`）。

### `stringToLatin1Bytes` (`src/exec/call.zig:2211`)

- **签名**：`fn stringToLatin1Bytes(rt: *core.JSRuntime, value: core.JSValue, max_unit: u16) Latin1StringError!std.ArrayList(u8)`。
- **作用**：平坦化后按单位上限拷字节。
- **实现**：utf16 单位 > max 拒绝。
- **所有权 / 错误 / 调用**：调用方 deinit。

### `throwInvalidCharacter` (`src/exec/call.zig:2233`)

- **签名**：`fn throwInvalidCharacter(ctx: *core.JSContext, global: ?*core.Object, message: []const u8) !core.JSValue`。
- **作用**：挂 DOMException InvalidCharacterError。
- **实现**：`throwValue` + `error.InvalidCharacterError`。
- **所有权 / 错误 / 调用**：建好 DOMException 值后 `ctx.throwValue` 把它变成 pending 异常，然后**总是**返回 `error.InvalidCharacterError`（返回类型里的 `JSValue` 不会真的产生）。没有可用 global 时退成 `error.TypeError`。不留长期分配。调用方 `call.zig:2183`、`2196`、`2201`（btoa/atob 的三个非法输入点）。

### `createDOMExceptionValue` (`src/exec/call.zig:2240`)

- **签名**：`fn createDOMExceptionValue(ctx: *core.JSContext, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue`。
- **作用**：尽量用全局 DOMException.prototype，否则 named Error。
- **实现**：`constructDOMExceptionObject`。
- **所有权 / 错误 / 调用**：返回 owned 的异常对象值；`message`/`name` 先各建一个 owned 字符串再交给 `constructDOMExceptionObject`（它接手）。全局上没有可用的 `DOMException` 构造器或原型时降级为 `exception_ops.createNamedError`，保证总能造出错误对象。原型是借用读。唯一调用方 `throwInvalidCharacter`（`call.zig:2236`）。

### `globalQueueMicrotask` (`src/exec/call.zig:2253`)

- **签名**：`fn globalQueueMicrotask(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`queueMicrotask(cb)`。
- **实现**：不可调用 TypeError 消息；`enqueuePendingMicrotask`。
- **所有权 / 错误 / 调用**：不分配 JS 值；`enqueuePendingMicrotask` 把 `callback` 存进运行时的微任务队列（队列接手其存活责任，直到被执行）。参数不可调用时先 `throwTypeErrorMessage` 写 pending 异常再以错误返回。没有 global → `error.TypeError`。唯一调用方 `callHostGlobalNativeFunctionRecord` 的 `queueMicrotask` 臂（`call.zig:878`）。

### `globalGc` (`src/exec/call.zig:2261`)

- **签名**：`fn globalGc(ctx: *core.JSContext) core.JSValue`。
- **作用**：zjs `gc()` 助手。
- **实现**：`runObjectCycleRemoval`，返回 undefined。
- **所有权 / 错误 / 调用**：直接跑一次 `runObjectCycleRemoval` 并丢弃返回的回收计数，返回 undefined；不分配、不抛（签名里没有 error set），这是调试用的 `gc()` 全局。唯一调用方 `callHostGlobalNativeFunctionRecord` 的 `gc` 臂（`call.zig:879`）。

### `materializeMappedArgumentsDescriptorValue` (`src/exec/call.zig:2266`)

- **签名**：`fn materializeMappedArgumentsDescriptorValue( rt: *core.JSRuntime, object: *core.Object, key: core.Atom, desc: *core.Descriptor, ) void`。
- **作用**：mapped arguments 的 data 描述符值来自 var_ref 细胞。
- **实现**：非 mapped / 非下标 / 无细胞则不动。
- **所有权 / 错误 / 调用**：getOwnPropertyDescriptor。

### `materializeMappedArgumentsDescriptorValueForVm` (`src/exec/call.zig:2282`)

- **签名**：`pub fn materializeMappedArgumentsDescriptorValueForVm( rt: *core.JSRuntime, object: *core.Object, key: core.Atom, desc: *core.Descriptor, ) !void`。
- **作用**：VM 包装，永不失败。
- **实现**：调上一函数。
- **所有权 / 错误 / 调用**：就地改调用方栈上的 `desc`：把 mapped arguments 的 VarRef cell 当前值填进 `desc.value` 并置 `value_present`，值是借用（不 retain、不建根）。包装的 `!void` 只为统一 VM 侧调用形状，内层 `materializeMappedArgumentsDescriptorValue` 实际不会失败。调用方 4 处：`src/binding/context.zig:553`、`src/exec/object_builtin_ops.zig:1162`/`1217`、`src/exec/object_ops.zig:3352`。

### `descriptorFromObjectBare` (`src/exec/call.zig:2291`)

- **签名**：`pub fn descriptorFromObjectBare(object: *core.Object) !core.Descriptor`。
- **作用**：无 Realm 的 ToPropertyDescriptor。
- **实现**：有 get/set → accessor；有 value/writable → data；否则 generic。bool 缺省 null。四次存在性判定与两次取值直接调 `object.hasProperty` / `object.getProperty`（原先经 `expectedHas`/`expectedValue` 两个只为吞掉一个未用 `rt` 首参而存在的转发函数，已删；本函数与 `optionalBoolProperty` 的 `rt` 形参也一并删除）。
- **所有权 / 错误 / 调用**：defineProperty。

### `descriptorObject` (`src/exec/call.zig:2323`)

- **签名**：`fn descriptorObject(rt: *core.JSRuntime, desc: core.Descriptor) !core.JSValue`。
- **作用**：FromPropertyDescriptor。
- **实现**：root value/getter/setter。
- **所有权 / 错误 / 调用**：测试 GC。

### `optionalBoolProperty` (`src/exec/call.zig:2378`)

- **签名**：`fn optionalBoolProperty(object: *core.Object, key: core.Atom) !?bool`。
- **作用**：缺席 null；非 bool 当 false。
- **实现**：`object.hasProperty(key)` 为假返回 null，否则 `object.getProperty(key)` 后 `asBool() orelse false`。
- **所有权 / 错误 / 调用**：不分配；缺属性返回 `null`（区别于 `false`），非 boolean 值一律当 `false`——描述符三态语义就落在这里。错误来自两次属性访问。调用方 `descriptorFromObjectBare` 的 `enumerable`/`configurable`/`writable` 三处（`call.zig:2297`、`2298`、`2316`）。

### `definePropertiesFromObject` (`src/exec/call.zig:2384`)

- **签名**：`fn definePropertiesFromObject(rt: *core.JSRuntime, object: *core.Object, properties_value: core.JSValue) !void`。
- **作用**：无 trap 的 `Object.defineProperties`。
- **实现**：ownKeys；undefined 描述符跳过。
- **所有权 / 错误 / 调用**：`ownKeys` 新分配的键数组用 `defer core.Object.freeKeys` 释放；描述符里的值由目标对象的属性表接手。`defineOwnProperty` 的失败归一成 `error.TypeError`（`IncompatibleDescriptor`/`NotExtensible`/`ReadOnly`）与 `error.RangeError`（`InvalidLength`）；值为 undefined 的键被跳过。调用方 `call.zig:996`（`Object.create` 的第二参）与 `1156`（`Object.defineProperties` 的裸运行时臂）。

### `atomFromPropertyKey` (`src/exec/call.zig:2401`)

- **签名**：`fn atomFromPropertyKey(rt: *core.JSRuntime, value: core.JSValue) HostError!core.Atom`。
- **作用**：ToPropertyKey atom。
- **实现**：`propertyKeyAtom` via hostResult。
- **所有权 / 错误 / 调用**：`propertyKeyAtom` 可能 intern 一个新 atom，归 `AtomTable` 持有，调用方不释放。`hostResult` 把内层的宽错误集收窄成 `HostError`（ToString/ToPropertyKey 的失败按原样保留）。调用方是本文件多个按键取值的内建臂（`call.zig:1025`、`1082`、`1143` 等 7 处，含定义处共 8 个引用点）。

### `defineBoolProperty` (`src/exec/call.zig:2405`)

- **签名**：`fn defineBoolProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: bool) !void`。
- **作用**：布尔数据属性。
- **实现**：`defineObjectProperty`。
- **所有权 / 错误 / 调用**：转 `defineObjectProperty` 写一个可写/可枚举/可配置的 boolean 数据属性；写的是立即值，不涉及所有权转移或屏障。error set 为属性定义错误。调用方是描述符对象构造的三处（`call.zig:2346`-`2348`，`writable`/`enumerable`/`configurable`）。

### `errorNameMatchesConstructor` (`src/exec/call.zig:2411`)

- **签名**：`pub fn errorNameMatchesConstructor(err: anytype, constructor_name: []const u8) bool`。
- **作用**：`assert.throws` 把 Zig error 名对上构造器名。
- **实现**：Type/Syntax/Range/Eval/Reference。
- **所有权 / 错误 / 调用**：`assertThrows`。

### `isFunctionClass` (`src/exec/call.zig:2420`)

- **签名**：`fn isFunctionClass(class_id: core.ClassId) bool`。
- **作用**：toString/callable 用的函数 class 集。
- **实现**：含四类 bytecode 与 c_closure。
- **所有权 / 错误 / 调用**：测试四类。

### `evalGlobalScriptSource` (`src/exec/call.zig:2454`)

- **签名**：`pub fn evalGlobalScriptSource( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: []const u8, filename: []const u8, ) !core.JSValue`。
- **作用**：`$262.evalScript` / 嵌入 `evalScript`：在指定 global 上跑 script。
- **实现**：最外层 `updateNativeStackTop`。若 ctx.global 不是该 global，临时把 `ctx.lexicals` 换成 `global.globalLexicals`。compile script `return_completion=true`。语法错误 compile-error 表面。根函数 `.root_global`，`this`=global，`direct_eval_vars_reach_global=true`。恢复 lexicals 时 root 完成值。
- **所有权 / 错误 / 调用**：`eval_entry.evalScriptSource`。错误 `normalizeEvalRuntimeError`。

## 覆盖核对

- 清单函数数: 109
- 未覆盖: 无
