# 13 — `call_runtime.zig`（二）：`[[Construct]]`

VM 构造路径对齐 `JS_CallConstructorInternal`（源码注释引 quickjs.c:20817 的入口 poll、20837/20842 的派生-基类分叉、20839-20856 的 new.target 寄存器）。内建 Date/String/RegExp/Object/Array 走 `NativeEntry` construct 记录（按 native id，不按函数名，避免用户函数名叫 `"Date"` 误中）。

## 类型

- `SameMachineConstructorTarget`：`ResolvedInlineFunction` + 函数对象 + `new_target_is_func`（解析时 `same`，避免每 `new` 再跑 SameValue）。
- `SameMachineConstructorPreparation`：`completed`（simple-field 写完）或 `instance`（要进 Machine 跑体）。
- 记录 id 常量：`date_construct_id` / `string_construct_id` / `regexp_construct_id` / `object_construct_id` / `array_construct_ref` / `collection_group_by_static_id=101`。

---

### `constructValueOrBytecode` (`src/exec/call_runtime.zig:1695`)

- **签名**：`pub fn constructValueOrBytecode( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`new F(args)`，new.target=F。
- **实现**：转 `WithNewTarget(..., func)`。
- **所有权 / 错误 / 调用**：`array_ops`/`string_ops` 把它别名成本地 `constructValueOrBytecode`，species / `ArraySpeciesCreate` / `Symbol.split` 等内部构造用它（new.target 就是 `func`）。

### `constructArrayNativeRecordVm` (`src/exec/call_runtime.zig:1743`)

- **签名**：`pub fn constructArrayNativeRecordVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: ?*core.Object, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：`new Array` / `Array(...)` 经 Array construct 记录。
- **实现**：`callConstructRecord(array_construct_ref, prototype, args)`；`RangeError` 且非 pending → `throwRangeErrorMessage("invalid array length")`（已是 pending 则原样传出）；记录返回 null 时 `error.TypeError`。
- **所有权 / 错误 / 调用**：Array 构造器无 native id，用显式 ref。

### `constructBuiltinNativeRecordVm` (`src/exec/call_runtime.zig:1765`)

- **签名**：`fn constructBuiltinNativeRecordVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: ?*core.Object, native_ref: core.function.NativeBuiltinRef, prototype: ?*core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：已强制的 args+prototype 进记录表。
- **实现**：`callConstructRecord`。null 仅当 id 不能 construct。
- **所有权 / 错误 / 调用**：Object 同 new.target 臂。

### `constructStringBuiltinNativeVm` (`src/exec/call_runtime.zig:1779`)

- **签名**：`fn constructStringBuiltinNativeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, native_ref: core.function.NativeBuiltinRef, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：`new String`：预检 + native 栈帧 + 物化错误。
- **实现**：`preflightInternalRecordCFunction`；`NativeBacktraceScope`；体内错误 `materializeRuntimeError`。
- **所有权 / 错误 / 调用**：自身不分配；`NativeBacktraceScope` 的 push/`defer deinit` 保证异常路径也弹栈。错误在这里被 `materializeRuntimeError` 就地物化成 `ctx` 上的 pending JS 异常后**仍把 Zig error 上抛**（`HostError`），返回 `null` 表示「不是这条记录能构造的」而不是失败。唯一调用方 `constructValueOrBytecodeWithNewTargetAfterInterruptPoll`（`call_runtime.zig:2287`），它把 `null` 翻成 `error.TypeError`。

### `constructStringBuiltinNativeInScope` (`src/exec/call_runtime.zig:1801`)

- **签名**：`fn constructStringBuiltinNativeInScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, native_ref: core.function.NativeBuiltinRef, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：在已压 native 帧里：prototype + ToString + 记录。
- **实现**：无参空串；`toStringForAnnexB` 让用户 toString 跑在调用者帧。
- **所有权 / 错误 / 调用**：`constructorPrototypeObject` defer deinit。

### `constructDateBuiltinNativeVm` (`src/exec/call_runtime.zig:1821`)

- **签名**：`fn constructDateBuiltinNativeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, native_ref: core.function.NativeBuiltinRef, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：`new Date` 的预检/栈/错误边界。
- **实现**：同 String。
- **所有权 / 错误 / 调用**：同 String 臂：不分配，`NativeBacktraceScope` 靠 `defer` 平衡，错误先 `materializeRuntimeError` 再上抛，`null` 由唯一调用方 `call_runtime.zig:2298` 翻成 `error.TypeError`。

### `constructPromiseNativeVm` (`src/exec/call_runtime.zig:1847`)

- **签名**：`fn constructPromiseNativeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：Promise 仍走名字分发，但给与记录构造器相同的 C 预检（length=1 是 JSCFunctionListEntry 长度，不是可变 `length` 属性）。
- **实现**：`promiseConstruct` + materialize。
- **所有权 / 错误 / 调用**：executor 同步。

### `constructDateBuiltinNativeInScope` (`src/exec/call_runtime.zig:1871`)

- **签名**：`fn constructDateBuiltinNativeInScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, native_ref: core.function.NativeBuiltinRef, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!?core.JSValue`。
- **作用**：VM 上下文强制 Date 参数后进记录。
- **实现**：1 参：Date 拷 `getTime`；object ToPrimitive；bigint TypeError；非 string ToNumber。≥2 参逐个 `toNumberForDateMethod`（最多 7）。
- **所有权 / 错误 / 调用**：`reflectConstructPrototypeVm("Date")`。

### `constructValueOrBytecodeWithNewTarget` (`src/exec/call_runtime.zig:1919`)

- **签名**：`pub fn constructValueOrBytecodeWithNewTarget( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, ) HostError!core.JSValue`。
- **作用**：公开/算法构造，`copy_argv=true`（JS_CALL_FLAG_COPY_ARGV）。
- **实现**：Mode true。
- **所有权 / 错误 / 调用**：`Reflect.construct`、`vm_call` 的 spread-construct 与 `super(...)` 臂、`tailcall_dispatch`，以及本文件 bound 递归。

### `constructValueOrBytecodeWithNewTargetInternal` (`src/exec/call_runtime.zig:1945`)

- **签名**：`pub fn constructValueOrBytecodeWithNewTargetInternal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, ) HostError!core.JSValue`。
- **作用**：`OP_call_constructor` / super，窗口 VM 拥有，`copy_argv=false`。
- **实现**：Mode false。
- **所有权 / 错误 / 调用**：opcode。

### `ownConstructorPrototypeData` (`src/exec/call_runtime.zig:1988`)

- **签名**：`fn ownConstructorPrototypeData(function_object: *core.Object) ?*core.Object`。
- **作用**：不物化 auto_init 的自有 `.prototype` data（约 9% N0）。
- **实现**：exotic / 非 data / deleted → null。首次 construct 仍走完整 helper。
- **所有权 / 错误 / 调用**：same-Machine 准备。

### `resolveSameMachineConstructor` (`src/exec/call_runtime.zig:1997`)

- **签名**：`pub fn resolveSameMachineConstructor( global: *core.Object, func: core.JSValue, new_target: core.JSValue, ) ?SameMachineConstructorTarget`。
- **作用**：`OP_call_constructor` 准入：同 Realm 普通/派生字节码，且 `new_target.same(func)`（`dup` 发出）。
- **实现**：identity 而非 SameValue（NaN/±0 是 outline，qjs 寄存器里从不重比 quickjs.c:20839）。`resolveInlineDirectConstructorFunction`；必须 `hasPrototype` 且 constructible。
- **所有权 / 错误 / 调用**：proxy/bound/native/跨 Realm/不同 new.target 走权威递归。

### `resolveSameMachineSpreadConstructor` (`src/exec/call_runtime.zig:2022`)

- **签名**：`pub fn resolveSameMachineSpreadConstructor( global: *core.Object, func: core.JSValue, new_target: core.JSValue, ) ?SameMachineConstructorTarget`。
- **作用**：`OP_apply(1)`：spread `super(...args)` 可保留不同 new.target。
- **实现**：`resolveInlineSpreadConstructorFunction`。new.target≠func 时 `objectRealmGlobal` 必须等于调用 global；跨 Realm 仍做执行根。
- **所有权 / 错误 / 调用**：bytecode 类不走 `callableObjectFromValue`（它排除 bytecode）。

### `prepareSameMachineConstructorAfterFirstPoll` (`src/exec/call_runtime.zig:2062`)

- **签名**：`pub fn prepareSameMachineConstructorAfterFirstPoll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, new_target: core.JSValue, target: *const SameMachineConstructorTarget, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!SameMachineConstructorPreparation`。
- **作用**：外层 CallConstructorInternal poll 已付；为非派生 ctor 造急切实例。第二 poll 在实例之后、栈预检之前（JS_CallInternal 序）。
- **实现**：断言非派生。`new_target_is_func` 时自有 prototype 或物化 auto_init → `createProfiledConstructorInstance`；prototype 非对象（`F.prototype=42`）走 `createConstructorInstance`。否则 `createBytecodeConstructorInstance`。E6 删除了每 `new` 的二次 poll。
- **所有权 / 错误 / 调用**：派生入口由 opcode 适配器另处理。返回 `.instance`。

### `constructOrdinaryBytecodeFunctionObject` (`src/exec/call_runtime.zig:2122`)

- **签名**：`fn constructOrdinaryBytecodeFunctionObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, function_object: *core.Object, function_value: core.JSValue, fb: *const bytecode.FunctionBytecode, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：按函数 **class** 而非名字构造用户字节码（qjs 同样）。
- **实现**：派生：this=uninitialized，无实例。基类：`createBytecodeConstructorInstance`，`defer noteConstructorAllocation`；体返回 object 则用它，否则实例。
- **所有权 / 错误 / 调用**：`function_global` 来自对象 Realm。

### `constructValueOrBytecodeWithNewTargetMode` (`src/exec/call_runtime.zig:2149`)

- **签名**：`fn constructValueOrBytecodeWithNewTargetMode( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：poll 后进 After。递归 proxy/bound 每次入口在调用者 Realm 收一次税。
- **实现**：`pollInterrupt`。
- **所有权 / 错误 / 调用**：纯转发，不分配、不建根；`args` 是调用方的窗口，`copy_argv` 只决定下游是否复制。error set `HostError`：`pollInterrupt` 可能抛出中断/超时（异常已在 `ctx` 上），其余由 After 层传上来。两个调用方是同文件的两个 pub 包装：`constructValueOrBytecodeWithNewTarget`（`call_runtime.zig:1929`，`copy_argv=true`）与 `constructValueOrBytecodeWithNewTargetInternal`（`1955`，opcode 入口，VM 拥有 argv）。

### `constructValueOrBytecodeWithNewTargetAfterInterruptPoll` (`src/exec/call_runtime.zig:2168`)

- **签名**：`fn constructValueOrBytecodeWithNewTargetAfterInterruptPoll( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, copy_argv: bool, ) HostError!core.JSValue`。
- **作用**：构造总分类。
- **实现**：proxy → `constructProxy`。bound：合并 args（`ValueSliceRoot` 根住），new.target 若仍是 wrapper 则换成 target。TypedArray 元数据（自定义 new.target 先 `constructBuiltinSuperConstructor`，`RangeError` 映射成 `invalid array index`）；再试 `constructArrayBufferNativeRecord`。有 FB：class 门后 `constructOrdinaryBytecodeFunctionObject`（提到名字 cascade 之前，避免 `new E()` 付 ~20 次 eql）。Object 记录且 new.target==func → 与 call 共享 ToObject 体（realm 用构造器对象的）。名字取 `nativeFunctionDispatchNameRef`，拿不到才分配。`!new_target.sameValue(func)` 且内建名（`Array` 还须 `arrayBuiltinMarker()==.constructor`）才跑 super 构造。然后 Function/AsyncFunction/GeneratorFunction/AsyncGeneratorFunction 动态源码族、Symbol 拒绝、具体 TypedArray 名的 iterable 构造、Number 装箱、String·Date 记录、Array marker、Promise、DisposableStack/AsyncDisposableStack、RegExp、collection、AB·SAB、DataView、Proxy、DOMException、AggregateError/SuppressedError/Error、host entry；最后 `c_function` 且非内建名 → `TypeError`。裸 FB：派生无实例（`this` 保持 uninitialized），基类 `createConstructorInstance` 后体返回 object 才顶替实例；另有一条 `functionObjectFromValue` 兜底回到 `constructOrdinaryBytecodeFunctionObject`。普通 `object` class 且非 proxy → `not a constructor`；非 object `not a function`（派生 ctor `[[Prototype]]` 变 null 后的 `super()`）。最后 `construct.constructValue`。
- **所有权 / 错误 / 调用**：dispatch 名 borrowed 优先。

### `constructExternalHostFunction` (`src/exec/call_runtime.zig:2407`)

- **签名**：`fn constructExternalHostFunction( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, ) !core.JSValue`。
- **作用**：`zjs.native` 构造器：须有自有 prototype。
- **实现**：`createConstructorInstance`；`nativeEntry` 以 instance 为 this 调 managed；返回 object 则用它。
- **所有权 / 错误 / 调用**：无 prototype TypeError。

### `isBuiltinConstructorName` (`src/exec/call_runtime.zig:2522`)

- **签名**：`pub fn isBuiltinConstructorName(name: []const u8) bool`。
- **作用**：~30 路名字，含 Error 集与具体 TypedArray。
- **实现**：一长串 `mem.eql` + `error_names` + `typed_array_names.isConcrete`。
- **所有权 / 错误 / 调用**：new.target≠func 的 super 门上短路在 new.target 比较之后（避免每次 `new Map()` 扫表）；另被构造分类末尾的 `c_function` 拒绝门与 `isConstructorLike` 的名字兜底使用。`reflect_ops` 另有一份同名私有实现。

### `createConstructorInstance` (`src/exec/call_runtime.zig:2556`)

- **签名**：`pub fn createConstructorInstance( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, new_target: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`js_create_from_ctor`：按 new.target.prototype 建 object。
- **实现**：`reflectConstructPrototypeVm("Object")`。
- **所有权 / 错误 / 调用**：prototype 临时 owned。

### `createBytecodeConstructorInstance` (`src/exec/call_runtime.zig:2571`)

- **签名**：`fn createBytecodeConstructorInstance( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, func: core.JSValue, function_object: *core.Object, new_target: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：new.target==func 时物化懒 `.prototype` 再 profiled 分配。
- **实现**：`getOwnConstructorPrototypeObject` 命中则 `createProfiledConstructorInstance`；否则通用 `createConstructorInstance`。
- **所有权 / 错误 / 调用**：首次 `new` 把 auto_init 变成 data 槽。

### `createProfiledConstructorInstance` (`src/exec/call_runtime.zig:2601`)

- **签名**：`fn createProfiledConstructorInstance( rt: *core.JSRuntime, prototype: *core.Object, fb: ?*const bytecode.FunctionBytecode, ) !core.JSValue`。
- **作用**：按 ctor alloc profile 预留自有属性容量。
- **实现**：live profile 的 capacity；≥4 才 `reserveOwnPropertyCapacity`（1–3 槽在本 host 比后来 grow 更贵）。
- **所有权 / 错误 / 调用**：返回新建对象的 owned 值；`errdefer core.Object.destroyFromHeader` 只覆盖 `reserveOwnPropertyCapacity` 失败这一段，成功后所有权交给调用方（由构造流程接着挂到帧/根上）。error set 是推断的分配错误（OOM）。调用方两处，都在本文件：`call_runtime.zig:2088`（内联构造臂）与 `2594`（通用臂）。

### `noteConstructorAllocation` (`src/exec/call_runtime.zig:2619`)

- **签名**：`pub fn noteConstructorAllocation(fb: *const bytecode.FunctionBytecode, instance: core.JSValue) void`。
- **作用**：观察实例 shape.prop_count，更新 profile。
- **实现**：inert 忽略。live 且 observed≤capacity 一次比较无 store。0 忽略。cap 上限 `max_ctor_alloc_capacity`。
- **所有权 / 错误 / 调用**：基类 ctor 返回后。

### `functionRealmContext` (`src/exec/call_runtime.zig:2635`)

- **签名**：`pub fn functionRealmContext(caller: *core.JSContext, function_value: core.JSValue) HostError!*core.JSContext`。
- **作用**：冷 `JS_GetFunctionRealm`。不可用来提前切实际 dispatch：Bound/Proxy 包装在调用者 Realm。
- **实现**：c_function → nativeFunctionRealm；bytecode 四类 → bytecodeFunctionRealmContext；proxy 递归 target（revoked 抛）；bound 递归；其余 caller（含 C_FUNCTION_DATA/C_CLOSURE）。
- **所有权 / 错误 / 调用**：只读查询，不分配、不建根，返回的 `*JSContext` 由 Realm 自己持有。error set `HostError`：注册表缺失返回 `error.InvalidBuiltinRegistry`；revoked proxy 先 `throwTypeErrorMessage` 写 pending 异常再走 `unreachable` 之前的抛出路径。调用方 `src/exec/object_ops.zig:1612`、`3307`，`src/exec/array_ops.zig:3670` 等 5 处（另有 `function_ops.zig:471`、`reflect_ops.zig:249`），都是 `new.target` 跨 Realm 取原型的场合。

### `functionRealmGlobal` (`src/exec/call_runtime.zig:2663`)

- **签名**：`pub fn functionRealmGlobal(caller: *core.JSContext, function_value: core.JSValue) HostError!*core.Object`。
- **作用**：Realm 全局。
- **实现**：`functionRealmContext` + `.global`。
- **所有权 / 错误 / 调用**：缺全局 `InvalidBuiltinRegistry`。

### `isConstructibleFunctionBytecode` (`src/exec/call_runtime.zig:4434`)

- **签名**：`pub fn isConstructibleFunctionBytecode(fb: *const bytecode.FunctionBytecode) bool`。
- **作用**：`hasPrototype && functionKind==normal`。
- **实现**：箭头无 prototype → false。
- **所有权 / 错误 / 调用**：纯标志位读，不分配、不抛。调用方：同文件 `call_runtime.zig:2370`（构造前的 constructibility 检查）、`4507`（`isConstructibleBytecodeFunctionObject`）、`4562`。

### `isConstructibleBytecodeFunctionObject` (`src/exec/call_runtime.zig:4439`)

- **签名**：`pub fn isConstructibleBytecodeFunctionObject(function_object: *const core.Object, fb: *const bytecode.FunctionBytecode) bool`。
- **作用**：仅 `bytecode_function` class 且 FB 可构造。
- **实现**：generator/async/async_generator false。
- **所有权 / 错误 / 调用**：与 construct.zig 私有同名函数平行（那边从对象读 FB）。

### `Fixture.create` (`src/exec/call_runtime.zig:4463`)

- **签名**：`fn create(runtime: *core.JSRuntime, case: Case) !*core.Object`。
- **作用**：四类 constructability 测试夹具。
- **实现**：class + FB flags。
- **所有权 / 错误 / 调用**：测试夹具：新建 Object 与 `FunctionBytecode.createFixture` 都不带 errdefer，所有权直接挂到 runtime，由测试末尾 `rt.destroy()` 统一回收；`publishFixtureNoFail` 把 FB 登记进运行时。error set 是推断的分配错误。只在本文件的 constructability 测试里用。

### `isConstructorLike` (`src/exec/call_runtime.zig:4493`)

- **签名**：`pub fn isConstructorLike(ctx: *core.JSContext, value: core.JSValue) error{OutOfMemory}!bool`。
- **作用**：`IsConstructor`。
- **实现**：裸 FB；函数对象上的 FB；bound 递归；c_function_data/async resume/html DDA false；host entry 看自有 prototype；c_closure true；construct 记录 ref true；否则名字表。OOM 必须冒泡，不能把真构造器判成 false。proxy `proxyTargetIsConstructor`。
- **所有权 / 错误 / 调用**：`new` 门与 `%ThrowTypeError%` 无关。

## 覆盖核对

- 本文件：Construct / Realm / constructability。
- 未覆盖: 无
