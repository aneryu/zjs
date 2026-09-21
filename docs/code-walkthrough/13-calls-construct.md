# 13 — `construct.zig`：无 VM 的构造路由

无活动 Machine 时的 `[[Construct]]` 选择器（QuickJS `JS_CallConstructorInternal` quickjs.c:20809–20869；Error/Object 体 41441 / 40098）。有 Realm 的 VM 路径在 `call_runtime.constructValueOrBytecodeWithNewTarget*`。内建记录域拥有直接体；本文件选缝并委托 TypedArray 分配给 `typed_array_construct.zig`。

`array_construct_ref`：`Array` 构造器对象自身不带 native id（call-as-function/species 识别仍走名字 + `arrayBuiltinMarker`），用显式 `NativeBuiltinRef` 进 construct 记录。`string_construct_ref`：`new Object(stringPrimitive)` 经 String 的 construct 记录建包装对象，而不是直接点名 `string_builtin_ops.constructWithPrototype`。

`TypedArrayElement` 是 `core.typed_array_names.Element` 别名。

---

### `constructCollectionRecord` (`src/exec/construct.zig:45`)

- **签名**：`fn constructCollectionRecord(ctx: *core.JSContext, kind: u32, prototype: ?*core.Object, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：空 Map/Set/WeakMap/WeakSet 走 collection construct 记录。
- **实现**：`constructIdForKind` → `callConstructRecord` 空 args。可迭代填充仍由调用方驱动。
- **所有权 / 错误 / 调用**：`constructCollectionValue`。无记录 `TypeError`。

### `collectionPrimitiveMethodCall` (`src/exec/construct.zig:58`)

- **签名**：`fn collectionPrimitiveMethodCall( ctx: *core.JSContext, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, globals: []globals_mod.Slot, ) !core.JSValue`。
- **作用**：构造填充时调原生 `set`/`add`，无函数对象、`global==null` 走 primitive 路径。
- **实现**：`.collection` + `callInternalRecord`。`globals` 留给按名解析的遗留闭包 adder。
- **所有权 / 错误 / 调用**：`callCollectionAdder`。

### `functionObject` (`src/exec/construct.zig:69`)

- **签名**：`pub fn functionObject(ctx: *core.RealmContext, name: core.Atom) !core.JSValue`。
- **作用**：带 `prototype.constructor` 环的原生函数对象（测试/回退构造器）。
- **实现**：`nativeFunctionWithPrototypeAndCapacity`；prototype 容量 1；constructor 可写不可枚举。
- **所有权 / 错误 / 调用**：缺 cached proto `InvalidBuiltinRegistry`。

### `constructValue` (`src/exec/construct.zig:88`)

- **签名**：`pub fn constructValue(ctx: *core.JSContext, callee: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：无 VM 的总构造入口。
- **实现**：拷 args 进 `ValueRootBuffer`，root callee/instance。`expectConstructor`。prototype 先自有数据槽。TypedArray 元数据 → `constructTypedArrayValue`。有 native id → `callConstructRecord`。再按名：collection / Function（夹具 kind 13）/ Object / Array 记录 / Iterator·Symbol·BigInt·TypedArray 拒绝 / DOMException / Promise / Proxy（校验两 object）/ ArrayBuffer·SAB / FinalizationRegistry / WeakRef / DataView / 具体 TA 名 / Number（ToPrimitive+ToNumber，对齐 `js_number_constructor`）/ Boolean / Error。否则普通 object + 自有 `constructor`。
- **所有权 / 错误 / 调用**：`call_runtime` 与 `Object()` 回退。callee 在定义 constructor 属性期间保持 root。

### `constructTypedArrayValue` (`src/exec/construct.zig:249`)

- **签名**：`pub fn constructTypedArrayValue(rt: *core.JSRuntime, constructor: *core.Object, prototype: ?*core.Object, element: TypedArrayElement, args: []const core.JSValue) !core.JSValue`。
- **作用**：按第一参分类构造 TypedArray。
- **实现**：从 constructor Realm 取 ArrayBuffer prototype。object：Array / TA / 非 AB 的 array-like / AB·SAB。非 object：长度→byteLength，负长 `RangeError`。
- **所有权 / 错误 / 调用**：args 再拷一份 root。缺 Realm `InvalidBuiltinRegistry`。

### `constructErrorObject` (`src/exec/construct.zig:280`)

- **签名**：`pub fn constructErrorObject(rt: *core.JSRuntime, name: []const u8, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：Error 族实例。AggregateError 分流。
- **实现**：自有 `name` 不装（在 per-class prototype，qjs 41441 只定义 message/cause）。有 message 则 ToString。
- **所有权 / 错误 / 调用**：args root。

### `constructDOMExceptionObject` (`src/exec/construct.zig:331`)

- **签名**：`pub fn constructDOMExceptionObject(rt: *core.JSRuntime, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`new DOMException(message, name)`。
- **实现**：error class；默认 message `""`、name `"Error"`；`code` 由 `domExceptionCode`。
- **所有权 / 错误 / 调用**：`call.zig` `createDOMExceptionValue` 与 VM 构造路径。

### `domExceptionCode` (`src/exec/construct.zig:394`)

- **签名**：`fn domExceptionCode(rt: *core.JSRuntime, name_value: core.JSValue) !i32`。
- **作用**：DOM 历史数字 code（1-based 表，空洞为 null）。
- **实现**：原始字符串与表比；未知 0。
- **所有权 / 错误 / 调用**：临时 ArrayList。

### `constructAggregateErrorObject` (`src/exec/construct.zig:433`)

- **签名**：`fn constructAggregateErrorObject(rt: *core.JSRuntime, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`new AggregateError(errors, message, options)`。
- **实现**：errors 必须是 Array（此路径不走迭代器）。拷到新数组。options.cause 有自有属性也装（即便 undefined）。忽略 constructor 参数。
- **所有权 / 错误 / 调用**：非 array `TypeError`。

### `isConstructErrorObjectName` (`src/exec/construct.zig:496`)

- **签名**：`pub fn isConstructErrorObjectName(name: []const u8) bool`。
- **作用**：Error / TypeError / AggregateError 等名字。
- **实现**：`core.error_names.isConstructErrorObjectName`。
- **所有权 / 错误 / 调用**：纯查表转发，不分配、不抛、无 error set。本文件唯一使用点是 `construct.zig:199`（构造分发按名字选 `constructErrorObject`）；这里的 `pub` 包装是给 exec 层复用 `core.error_names` 的门面。

### `constructWeakRef` (`src/exec/construct.zig:500`)

- **签名**：`fn constructWeakRef(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：校验可弱持有后建 WeakRef。
- **实现**：`canBeHeldWeakly` 否则 TypeError。
- **所有权 / 错误 / 调用**：`constructValue`。

### `weakRefWithPrototype` (`src/exec/construct.zig:505`)

- **签名**：`pub fn weakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：安装弱目标。
- **实现**：root target；`setWeakRefTarget`。
- **所有权 / 错误 / 调用**：公开给其它模块。

### `constructFinalizationRegistry` (`src/exec/construct.zig:522`)

- **签名**：`fn constructFinalizationRegistry(ctx: *core.JSContext, cleanup_callback: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：`new FinalizationRegistry(cb)`。
- **实现**：`createFinalizationRegistry` + cleanup slot。
- **所有权 / 错误 / 调用**：调用方已确认 cb 可调用。

### `defineData` (`src/exec/construct.zig:555`)

- **签名**：`fn defineData( rt: *core.JSRuntime, target: *core.Object, key: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool, ) !void`。
- **作用**：数据属性。
- **实现**：`Descriptor.data`。
- **所有权 / 错误 / 调用**：Error/DOMException 字段。

### `constructPrimitiveWrapper` (`src/exec/construct.zig:555`)

- **签名**：`fn constructPrimitiveWrapper(rt: *core.JSRuntime, class_id: core.class.ClassId, prototype: ?*core.Object, primitive: core.JSValue) !core.JSValue`。
- **作用**：Number/Boolean/BigInt/Symbol 包装对象。
- **实现**：root primitive；`objectDataSlot`。
- **所有权 / 错误 / 调用**：String 不走这里，走 String construct 记录。

### `objectConstructorValue` (`src/exec/construct.zig:592`)

- **签名**：`pub fn objectConstructorValue(ctx: *core.JSContext, args: []const core.JSValue, constructor: *core.Object) !core.JSValue`。
- **作用**：`Object` 构造体（记录路径与 generic 回退共享）。记录路径已区分自定义 new.target，对齐 `js_object_constructor`。
- **实现**：已是 object 原样返回。非 nullish 原语按类型装箱（string 走 String 记录）。否则空 object，prototype 来自 constructor.prototype。
- **所有权 / 错误 / 调用**：`constructValue` 名 `"Object"`。

### `primitivePrototypeFromObjectConstructor` (`src/exec/construct.zig:621`)

- **签名**：`fn primitivePrototypeFromObjectConstructor(constructor: *core.Object, class_id: core.ClassId) !*core.Object`。
- **作用**：从 constructor 的 Realm 取包装原型。
- **实现**：`nativeFunctionRealm` + `classPrototypeObject`。
- **所有权 / 错误 / 调用**：缺 Realm `InvalidBuiltinRegistry`。

### `typedArrayElement` (`src/exec/construct.zig:628`)

- **签名**：`pub fn typedArrayElement(name: []const u8) ?TypedArrayElement`。
- **作用**：名字 → 元素大小/kind。
- **实现**：`core.typed_array_names.element`。
- **所有权 / 错误 / 调用**：纯名字查表，返回按值的 `?Element`，不分配、不抛。调用方跨模块共 6 处：`src/exec/object_ops.zig:1652`、`src/exec/function_ops.zig:175`、`src/exec/reflect_ops.zig:140` 等（另有 `reflect_ops.zig:551`、`array_ops.zig:1248`、本文件 `179`）。

### `constructTypedArrayArrayInput` (`src/exec/construct.zig:632`)

- **签名**：`fn constructTypedArrayArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, array_buffer_prototype: *core.Object, element: TypedArrayElement, source: *core.Object) !core.JSValue`。
- **作用**：从 Array 逐元拷入新 TA。
- **实现**：backing buffer；循环 get + `typedArraySourceValue` + `typedArraySetIndex`；临时值清 undefined 以免假根。
- **所有权 / 错误 / 调用**：四槽 root。

### `constructTypedArrayTypedArrayInput` (`src/exec/construct.zig:663`)

- **签名**：`fn constructTypedArrayTypedArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, array_buffer_prototype: *core.Object, element: TypedArrayElement, source: *core.Object) !core.JSValue`。
- **作用**：从另一 TA 拷。
- **实现**：detached `TypeError`；out-of-bounds 时固定长度或 byteOffset 越界拒绝。用 `typedArrayGetIndex`/`SetIndex`。
- **所有权 / 错误 / 调用**：`backing_buffer`/`object_value`/`value` 三个槽先进 `core.runtime.rootValues` 建的 `ValueRootFrame` 并 `activate`（`defer deactivate`），因为 `arrayBufferConstructLength`、`typedArrayConstructWithOptions` 与逐元素 get/set 都可能分配并触发 GC；循环里每步把 `value` 复位成 undefined，不给根帧留悬挂旧值。返回的 TA 值是 owned，交给调用方。error set 含 `TypeError`（detached / out-of-bounds）、`std.math.mul` 的 `Overflow` 与分配错误；都以 Zig error 上抛，由构造分发链最外层变成 JS 异常。唯一调用方 `construct.zig:268`。

### `constructTypedArrayArrayLikeInput` (`src/exec/construct.zig:694`)

- **签名**：`fn constructTypedArrayArrayLikeInput(rt: *core.JSRuntime, prototype: ?*core.Object, array_buffer_prototype: *core.Object, element: TypedArrayElement, source: *core.Object) !core.JSValue`。
- **作用**：从 array-like 的 `.length` 拷。
- **实现**：负 length `RangeError`；非 int32 length 当 0。
- **所有权 / 错误 / 调用**：四槽 `ValueRootFrame`（多一个 `coerced`，因为 `typedArraySourceValue` 可能拆箱出堆值）；根帧与复位纪律同上一臂。返回 owned TA 值。负 length → `error.RangeError`，非 int32 的 `length` 当 0，另有 `Overflow` 与分配错误。唯一调用方 `construct.zig:269`。

### `createTypedArrayBackingBuffer` (`src/exec/construct.zig:729`)

- **签名**：`fn createTypedArrayBackingBuffer(rt: *core.JSRuntime, array_buffer_prototype: *core.Object, byte_length: i32) !core.JSValue`。
- **作用**：按长度造 ArrayBuffer。
- **实现**：`arrayBufferConstructLength`。
- **所有权 / 错误 / 调用**：返回新建 ArrayBuffer 的 owned 值，本函数不建根：三个拷贝臂把它直接写进已 activate 的根帧槽（`construct.zig:659`、`692`、`725`），标量长度臂（`275`）是栈上局部并立刻交给 `typedArrayConstructFullBufferOwned`。error set 即 `arrayBufferConstructLength` 的分配/长度错误。

### `typedArraySourceValue` (`src/exec/construct.zig:733`)

- **签名**：`fn typedArraySourceValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：若是原语包装则拆箱。
- **实现**：`coercion_ops.primitiveWrapperStoredValue(rt, value) orelse value`。（本文件原来另有一份与 `coercion_ops` 逐字相同的 `primitiveWrapperStoredValue` 私有副本，已删，改直接调 exec 内的那一份。）
- **所有权 / 错误 / 调用**：不分配：命中包装对象时返回的是 `objectData` 里的借用值，否则原样返回入参；`rt` 只为签名统一而带。实际不会失败（error set 由 `!` 推断为空集）。调用方是两个需要拆箱的拷贝臂 `construct.zig:666`、`732`。

### `constructFunctionValue` (`src/exec/construct.zig:737`)

- **签名**：`fn constructFunctionValue(rt: *core.JSRuntime) !core.JSValue`。
- **作用**：无源码的 Function 构造回退：合成闭包 kind 13（返回 undefined）。
- **实现**：`closure_mod.create(rt, 13, 0, 0, 0)`。完整 `new Function(src)` 在 `function_ops`。
- **所有权 / 错误 / 调用**：无 Realm 路径。

### `constructCollectionValue` (`src/exec/construct.zig:741`)

- **签名**：`fn constructCollectionValue( ctx: *core.JSContext, kind: u32, prototype: ?*core.Object, args: []const core.JSValue, globals: []globals_mod.Slot, ) !core.JSValue`。
- **作用**：空集合 + 可选可迭代填充。
- **实现**：kind 1/3（Map/WeakMap）用 `set` 且 entry 必须是 array；否则 `add`。原生 adder 只走 record；否则先 `c_closure` 再 record。非 array 源走 iterator。
- **所有权 / 错误 / 调用**：null/undefined 源跳过填充。

### `constructCollectionFromIterator` (`src/exec/construct.zig:790`)

- **签名**：`fn constructCollectionFromIterator( ctx: *core.JSContext, collection_value: core.JSValue, kind: u32, iterable_value: core.JSValue, adder: core.JSValue, adder_name: []const u8, globals: []globals_mod.Slot, ) !void`。
- **作用**：GetIterator 后逐步 add/set；失败 `closeIterator`。
- **实现**：`Symbol.iterator` 必须可调用。`done`/`value` 经 getter。Map 条目必须是 object。
- **所有权 / 错误 / 调用**：中途错误关 iterator。

### `callCollectionAdder` (`src/exec/construct.zig:854`)

- **签名**：`fn callCollectionAdder( ctx: *core.JSContext, collection_value: core.JSValue, adder: core.JSValue, adder_name: []const u8, args: []const core.JSValue, globals: []globals_mod.Slot, ) !void`。
- **作用**：原生 adder 或闭包 + 再跑原生（夹具与真 Set 双写）。
- **实现**：`set`→id 1，`add`→id 6。
- **所有权 / 错误 / 调用**：自身不分配、不建根：`args` 与 `globals` 都借用调用方的栈窗口。错误原样上抛（`TypeError` 来自 adder 不可调用或 class 不符），由两个调用方 `construct.zig:866`、`872` 用 `catch` 接住并先 `closeIterator` 再重抛，保证迭代器被关闭。

### `closeIterator` (`src/exec/construct.zig:873`)

- **签名**：`fn closeIterator(ctx: *core.JSContext, iterator: *core.Object, globals: []globals_mod.Slot) !void`。
- **作用**：IteratorClose：调 `return` 若可调用。
- **实现**：`return` 失败吞掉（关迭代器本身失败不覆盖原错误）。
- **所有权 / 错误 / 调用**：不分配。`iterator.getProperty(return)` 的错误用 `try` 上抛，但 `return` 方法自身的调用结果被 `catch return` 吞掉——IteratorClose 失败不能盖住触发它的原错误。调用方是集合构造里的 6 处错误清理点（`construct.zig:848`、`854`、`858` 等）。

### `getPropertyWithGetter` (`src/exec/construct.zig:880`)

- **签名**：`fn getPropertyWithGetter(ctx: *core.JSContext, object: *core.Object, key: core.Atom, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：沿原型链读，accessor 则调 getter。
- **实现**：无描述符 undefined。
- **所有权 / 错误 / 调用**：iterator `done`/`value`。

### `callClosureWithThis` (`src/exec/construct.zig:896`)

- **签名**：`fn callClosureWithThis( ctx: *core.JSContext, callable: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot, ) !core.JSValue`。
- **作用**：集合构造里调 iterator/adder。
- **实现**：`c_function` 按名查 `legacyClosureMethodId` 走 record；`c_closure` 走 `closure_mod.callWithThis`；其它 TypeError。
- **所有权 / 错误 / 调用**：名字分配 defer free。

### `nativeFunctionName` (`src/exec/construct.zig:928`)

- **签名**：`fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8`。
- **作用**：分配一份可见/dispatch 名。
- **实现**：`nativeFunctionNameValue(..., true)` + `appendRawString` + `toOwnedSlice`。
- **所有权 / 错误 / 调用**：调用方 free。

### `nativeFunctionNameValue` (`src/exec/construct.zig:936`)

- **签名**：`fn nativeFunctionNameValue(rt: *core.JSRuntime, function_object: *core.Object, prefer_dispatch_name: bool) !core.JSValue`。
- **作用**：dispatch atom 或 `name` 属性。
- **实现**：prefer 时 `nativeDispatchName` → `toStringValue`。非 string `TypeError`。
- **所有权 / 错误 / 调用**：返回的字符串 JSValue 可能是 `atoms.toStringValue` 新建的堆值（也可能是 `name` 属性槽里的借用值），函数不建根；三个调用方都是拿到就立刻 `appendRawString` 拷成字节：`nativeFunctionName`（`construct.zig:955`）、`isNativeCollectionAdder`（`982`，错误 `catch return false`）、`constructorName`（`1017`，错误 `catch return null`）。`name` 不是字符串 → `error.TypeError`。

### `isNativeCollectionAdder` (`src/exec/construct.zig:951`)

- **签名**：`fn isNativeCollectionAdder(rt: *core.JSRuntime, value: core.JSValue, expected: []const u8) bool`。
- **作用**：是否名为 `set`/`add` 的 `c_function`。
- **实现**：读名失败当 false。
- **所有权 / 错误 / 调用**：临时 buffer。

### `getCollectionAdder` (`src/exec/construct.zig:963`)

- **签名**：`fn getCollectionAdder(rt: *core.JSRuntime, collection: *core.Object, name: []const u8) !core.JSValue`。
- **作用**：沿链取 adder；accessor 则 `closure_mod.call` getter。
- **实现**：找不到 undefined。
- **所有权 / 错误 / 调用**：`internAtom` 的 atom 归 `AtomTable`，调用方不释放；返回值是描述符槽里的借用值，或 accessor getter 的返回值（那一路经 `closure_mod.call`，其错误原样重抛）。找不到返回 undefined，由唯一调用方 `construct.zig:780` 接着用 `isCallableObject` 判 `TypeError`。

### `expectStringValue` (`src/exec/construct.zig:983`)

- **签名**：`fn expectStringValue(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void`。
- **作用**：测试：原始字符串相等。
- **实现**：`appendRawString` + `expectEqualStrings`。
- **所有权 / 错误 / 调用**：测试断言：本地 `ArrayList` 以 `defer deinit` 释放，不产生长期所有权；失败经 `std.testing` 的 error 上抛。调用方是本文件三处 GC 测试（`construct.zig:325`、`384`、`387`）；`src/tests/oom.zig` 里的同名函数是另一个实现。

### `constructorName` (`src/exec/construct.zig:990`)

- **签名**：`fn constructorName(rt: *core.JSRuntime, constructor: *core.Object) !?[]u8`。
- **作用**：构造器名字节；失败 null 而非抛。
- **实现**：owned slice。
- **所有权 / 错误 / 调用**：`constructValue` defer free。

### `isCallableObject` (`src/exec/construct.zig:998`)

- **签名**：`fn isCallableObject(value: core.JSValue) bool`。
- **作用**：c_function / data / async resume / c_closure / bytecode / bound。
- **实现**：header + class。
- **所有权 / 错误 / 调用**：纯 header + class_id 判定，不分配、不抛、不 retain。调用方 6 处，都在本文件：`construct.zig:174`（FinalizationRegistry 的 cleanup 回调参数）、`781`（adder）、`829`/`836`（iterator/next 方法）、`902`（`closeIterator` 的 `return`）、`1102`（constructability 测试）。

### `isConstructibleBytecodeFunctionObject` (`src/exec/construct.zig:1010`)

- **签名**：`fn isConstructibleBytecodeFunctionObject(object: *const core.Object) bool`。
- **作用**：仅 `bytecode_function` 且 `hasPrototype` 且 `functionKind==normal`。
- **实现**：generator/async/async_generator 一律 false。
- **所有权 / 错误 / 调用**：`expectConstructor`。

### `expectConstructor` (`src/exec/construct.zig:1024`)

- **签名**：`fn expectConstructor(value: core.JSValue) !*core.Object`。
- **作用**：`[[Construct]]` 门。
- **实现**：bytecode 类走 `isConstructibleBytecodeFunctionObject`；另允许 c_function / bound / c_closure。
- **所有权 / 错误 / 调用**：箭头（无 prototype）TypeError。

### `Fixture.create` (`src/exec/construct.zig:1052`)

- **签名**：`fn create(runtime: *core.JSRuntime, case: Case) !*core.Object`。
- **作用**：按 class/func_kind/has_prototype 造 FB 函数对象。
- **实现**：`createFixture` + `setFunctionBytecodeValue`。
- **所有权 / 错误 / 调用**：四类 constructability 测试。

## 覆盖核对

- 清单函数数: 40
- 未覆盖: 无
