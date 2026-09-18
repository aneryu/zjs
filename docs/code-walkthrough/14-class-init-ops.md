# 14h — `class_init_ops.zig`：内建 `super()` 构造

[`src/exec/class_init_ops.zig`](../../src/exec/class_init_ops.zig) 处理 `class X extends <Builtin>` 的 `super(...)`：按构造器 **名字** 分发到各内建的「带原型的 construct」。构造器对象常常没有 native id（例如 Array），所以 Array 走显式 `NativeBuiltinRef{ .domain = .array, .id = ConstructorMethod.construct }`。

大量具体 construct 实现仍在 `object_ops` / `promise_ops` / `date_ops` 等，这里只做名字路由与 Promise 的 VM `[[Get]]` 特判。

---

### `constructBuiltinSuperConstructor` (`src/exec/class_init_ops.zig:59`)

- **签名**：`pub fn constructBuiltinSuperConstructor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, name: []const u8, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target: core.JSValue, ) !?core.JSValue`。
- **作用**：按内建构造器名字执行 derived `super()` / `Reflect.construct` 需要的实例分配。
- **实现**：名字字符串分发：
  - `Symbol` / `BigInt` → `error.TypeError`（不可 `new`）。
  - `Iterator`：`new_target === constructor` → TypeError（抽象）；否则 `GetPrototypeFromConstructor`（`reflectConstructPrototypeVm`）后 `Object.create` 普通对象。
  - `Function` / `AsyncFunction` / `GeneratorFunction` / `AsyncGeneratorFunction` → `constructDynamicFunctionFromSource`，kind 对应。
  - `ArrayBuffer` / `SharedArrayBuffer`：`typedArrayConstructToIndex` + `arrayBufferMaxByteLengthOption`，再 length construct。
  - `DataView`：`dataViewConstructorArgs` 后 `dataViewConstructWithPrototype`。文件后部另有一段 DataView 走 `core.typed_array.dataViewConstruct`，因前面已 return，实际不可达。
  - `RegExp` → `regExpConstructCall`。
  - `Promise` → `constructPromiseBuiltinSuperNativeVm`（见下）。
  - 其余先解析 `new_target.prototype` 到 `OwnedPrototype`（`defer deinit`）：
    - `Object`：`new_target` 即 constructor 且首参已是对象 → 返回该对象（ToObject 捷径）；否则空对象。
    - `Array`：构造器须带 `arrayBuiltinMarker() == .constructor`，否则 `null`（不是 Array 内建）。`callConstructRecord`；`RangeError` 且 pending 异常与之不匹配（`pendingExceptionMatchesError` 为假）时改成 `"invalid array length"`。
    - `String` / `Number` / `Boolean` / `Date`：各自 wrapper。Number 对齐 `js_number_constructor`（`quickjs.c:44822`）：`ToNumeric`，对象先 ToPrimitive，BigInt 再 `bigIntToNumber`。Symbol 参数 TypeError。
    - `AggregateError` / `SuppressedError` / 其他 Error 名 / `WeakRef` / `FinalizationRegistry` / `DisposableStack` / `AsyncDisposableStack` / collection / TypedArray。
  - 未识别 → `null`（调用方改走普通 construct）。
- **所有权 / 错误 / 调用**：返回 owned 实例。`prototype` handle 必须活到 `create` 保留原型之后。`null` 与 error 不同：`null` 表示「这不是我们认的内建」。WeakRef 目标须 `canBeHeldWeakly`；FinalizationRegistry 回调须可调用。

### `constructPromiseBuiltinSuperNativeVm` (`src/exec/class_init_ops.zig:188`)

- **签名**：`fn constructPromiseBuiltinSuperNativeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, function_object: *core.Object, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：带不同 `new.target` 的 Promise 构造必须走可观察的 VM `[[Get]]` 取 `newTarget.prototype`。
- **实现**：注释：直接 Promise 助手可以读普通 intrinsic data；`Reflect.construct` 与 derived `super()` 必须在 Promise native 帧仍活动时跑 accessor/Proxy。`preflightCFunctionCall`；`NativeBacktraceScope` push/defer；体内 `constructPromiseBuiltinSuperInScope`，错误经 `materializeRuntimeError`。
- **所有权 / 错误 / 调用**：backtrace 与 realm 错误物化必须在 native 作用域内。

### `constructPromiseBuiltinSuperInScope` (`src/exec/class_init_ops.zig:209`)

- **签名**：`fn constructPromiseBuiltinSuperInScope( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, new_target: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：在已推 native 栈的前提下：校验 executor，取原型，调 `promiseConstructWithPrototype`。
- **实现**：无参或首参不可调用 → `"not a function"`。`reflectConstructPrototypeVm(..., "Promise", new_target)`；`defer prototype.deinit`；`promiseConstructWithPrototype`。
- **所有权 / 错误 / 调用**：executor 检查在 GetPrototypeFromConstructor 之前，与 spec `Promise` 构造函数步骤一致。

## 覆盖核对

- 清单函数数: 3
- 本文标题覆盖: 3
- 未覆盖: 无
