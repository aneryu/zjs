# 13 — `construct.zig`：剩余构造体

通用 `constructValue` 分类器已删除。有 Realm 的 `[[Construct]]` 入口是 `call_runtime.constructValueOrBytecodeWithNewTarget*`。本文件留下的是唯一构造体与分配叶子，不是第二套 dispatcher：

- `objectConstructorValue`：唯一 Object 体；Object [[Call]] 与 Object record 共用
- `weakRefWithPrototype`：WeakRef 分配叶子（校验在 `function_ops.weakRefConstructWithNewTarget`）
- `constructDOMExceptionObject`：唯一 DOMException 体
- `constructTypedArrayTypedArrayInput`：唯一 TypedArray 源复制 primitive（`typedArrayConstructVm` 消费）
- `typedArrayElement`：名字 → 元素元数据
- `functionObject`：测试用构造器对象工厂
- `constructErrorObject`：Error 实例体（生产 Error 构造走 `object_ops`）

`string_construct_ref`：`new Object(stringPrimitive)` 经 String 的 construct 记录建包装对象。`TypedArrayElement` 是 `core.typed_array_names.Element` 别名。

---

### `functionObject` (`src/exec/construct.zig:23`)

- **签名**：`pub fn functionObject(ctx: *core.RealmContext, name: core.Atom) !core.JSValue`。
- **作用**：带 `prototype.constructor` 环的原生函数对象（测试用构造器工厂）。
- **实现**：`nativeFunctionWithPrototypeAndCapacity`；prototype 容量 1；constructor 可写不可枚举。
- **所有权 / 错误 / 调用**：缺 cached proto `InvalidBuiltinRegistry`。不随分类器删除而改语义。

### `constructErrorObject` (`src/exec/construct.zig:42`)

- **签名**：`pub fn constructErrorObject(rt: *core.JSRuntime, name: []const u8, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：Error 族实例体。生产 `new TypeError(...)` 走 `object_ops.errorConstructWithPrototype`。
- **实现**：自有 `name` 不装（在 per-class prototype）。有 message 则 ToString。`AggregateError` 分流 `constructAggregateErrorObject`。
- **所有权 / 错误 / 调用**：args root。文件内 GC 测试。

### `constructDOMExceptionObject` (`src/exec/construct.zig:93`)

- **签名**：`pub fn constructDOMExceptionObject(rt: *core.JSRuntime, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：唯一 `new DOMException(message, name)` 体。
- **实现**：error class；默认 message `""`、name `"Error"`；`code` 由 `domExceptionCode`。
- **所有权 / 错误 / 调用**：`call.zig` `createDOMExceptionValue` 与 `call_runtime` 名字 `"DOMException"` 臂。

### `domExceptionCode` (`src/exec/construct.zig:156`)

- **签名**：`fn domExceptionCode(rt: *core.JSRuntime, name_value: core.JSValue) !i32`。
- **作用**：DOM 历史数字 code（1-based 表，空洞为 null）。
- **实现**：原始字符串与表比；未知 0。
- **所有权 / 错误 / 调用**：临时 ArrayList。

### `constructAggregateErrorObject` (`src/exec/construct.zig:195`)

- **签名**：`fn constructAggregateErrorObject(rt: *core.JSRuntime, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`new AggregateError(errors, message, options)` 的无 VM 体。生产路径走 `object_ops.aggregateErrorConstructWithPrototype`。
- **实现**：errors 必须是 Array（此路径不走迭代器）。拷到新数组。options.cause 有自有属性也装（即便 undefined）。忽略 constructor 参数。
- **所有权 / 错误 / 调用**：非 array `TypeError`。

### `isConstructErrorObjectName` (`src/exec/construct.zig:258`)

- **签名**：`pub fn isConstructErrorObjectName(name: []const u8) bool`。
- **作用**：Error / TypeError / AggregateError 等名字。
- **实现**：`core.error_names.isConstructErrorObjectName`。
- **所有权 / 错误 / 调用**：纯查表转发。

### `weakRefWithPrototype` (`src/exec/construct.zig:262`)

- **签名**：`pub fn weakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：WeakRef 分配叶子：安装弱目标。校验（`CanBeHeldWeakly`）在 `function_ops.weakRefConstructWithNewTarget`。
- **实现**：root target；`setWeakRefTarget`。
- **所有权 / 错误 / 调用**：公开给 Construct 名字臂与测试。不回 `constructValue`。

### `constructPrimitiveWrapper` (`src/exec/construct.zig:304`)

- **签名**：`fn constructPrimitiveWrapper(rt: *core.JSRuntime, class_id: core.class.ClassId, prototype: ?*core.Object, primitive: core.JSValue) !core.JSValue`。
- **作用**：Number/Boolean/BigInt/Symbol 包装对象分配。
- **实现**：root primitive；`objectDataSlot`。
- **所有权 / 错误 / 调用**：`objectConstructorValue` 装箱。String 不走这里，走 String construct 记录。

### `objectConstructorValue` (`src/exec/construct.zig:340`)

- **签名**：`pub fn objectConstructorValue(ctx: *core.JSContext, args: []const core.JSValue, constructor: *core.Object) !core.JSValue`。
- **作用**：唯一 Object 体。`callNativeCallableByName` 的 `"Object"` [[Call]] 与 Object construct record 共用；不合成 newTarget。
- **实现**：已是 object 原样返回。非 nullish 原语按类型装箱（string 走 String 记录）。否则空 object，prototype 来自 constructor.prototype。
- **所有权 / 错误 / 调用**：记录路径已区分自定义 new.target，对齐 `js_object_constructor`。

### `primitivePrototypeFromObjectConstructor` (`src/exec/construct.zig:369`)

- **签名**：`fn primitivePrototypeFromObjectConstructor(constructor: *core.Object, class_id: core.ClassId) !*core.Object`。
- **作用**：从 constructor 的 Realm 取包装原型。
- **实现**：`nativeFunctionRealm` + `classPrototypeObject`。
- **所有权 / 错误 / 调用**：缺 Realm `InvalidBuiltinRegistry`。

### `typedArrayElement` (`src/exec/construct.zig:376`)

- **签名**：`pub fn typedArrayElement(name: []const u8) ?TypedArrayElement`。
- **作用**：名字 → 元素大小/kind。
- **实现**：`core.typed_array_names.element`。
- **所有权 / 错误 / 调用**：纯名字查表。`reflect_ops.reflectConstructCall` 的 TypedArray 预强制、`function_ops` / `array_ops` 仍用。

### `constructTypedArrayTypedArrayInput` (`src/exec/construct.zig:380`)

- **签名**：`pub fn constructTypedArrayTypedArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, array_buffer_prototype: *core.Object, element: TypedArrayElement, source: *core.Object) !core.JSValue`。
- **作用**：唯一 TypedArray 源复制 primitive。`typedArrayConstructVm` 遇到 TypedArray 源走这里，而不是把 null 改成 TypeError。
- **实现**：detached `TypeError`；out-of-bounds 时固定长度或 byteOffset 越界拒绝。用 `typedArrayGetIndex`/`SetIndex`。
- **所有权 / 错误 / 调用**：`backing_buffer`/`object_value`/`value` 三个槽先进 `rootValues`。调用方 `array_ops.typedArrayConstructVm`。

### `createTypedArrayBackingBuffer` (`src/exec/construct.zig:411`)

- **签名**：`fn createTypedArrayBackingBuffer(rt: *core.JSRuntime, array_buffer_prototype: *core.Object, byte_length: i32) !core.JSValue`。
- **作用**：按长度造 ArrayBuffer。
- **实现**：`arrayBufferConstructLength`。
- **所有权 / 错误 / 调用**：复制 primitive 把它写进已 activate 的根帧槽。

### `expectStringValue` (`src/exec/construct.zig:417`)

- **签名**：`fn expectStringValue(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void`。
- **作用**：测试：原始字符串相等。
- **实现**：`appendRawString` + `expectEqualStrings`。
- **所有权 / 错误 / 调用**：文件内 GC 测试。

### `isCallableObject` (`src/exec/construct.zig:424`)

- **签名**：`fn isCallableObject(value: core.JSValue) bool`。
- **作用**：c_function / data / async resume / bytecode / bound。不含已删的 `c_closure`。
- **实现**：header + class。
- **所有权 / 错误 / 调用**：文件内 constructability 测试。正式 IsCallable 是 `call_runtime.isCallableValue`。

### `isConstructibleBytecodeFunctionObject` (`src/exec/construct.zig:435`)

- **签名**：`fn isConstructibleBytecodeFunctionObject(object: *const core.Object) bool`。
- **作用**：仅 `bytecode_function` 且 `hasPrototype` 且 `functionKind==normal`。
- **实现**：generator/async/async_generator 一律 false。
- **所有权 / 错误 / 调用**：`expectConstructor`。

### `expectConstructor` (`src/exec/construct.zig:449`)

- **签名**：`fn expectConstructor(value: core.JSValue) !*core.Object`。
- **作用**：文件内 constructability 测试门。不是生产 `[[Construct]]` 入口。
- **实现**：bytecode 类走 `isConstructibleBytecodeFunctionObject`；另允许 c_function / bound。
- **所有权 / 错误 / 调用**：箭头（无 prototype）TypeError。生产构造走 `call_runtime.isConstructorLike`。

## 覆盖核对

- 清单函数数: 见源码剩余构造体；`constructValue` / `constructFunctionValue` / `constructTypedArrayValue` 已删
- 未覆盖: 无（本页只覆盖仍存在的所有者）
