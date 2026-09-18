# 14d — `object_ops.zig`：rest、generator、iterator、arguments

接 [14-object-ops.md](14-object-ops.md)。本文件覆盖原型走查、对象 rest、`import.meta`、generator 实例、iterator 原型、arguments 对象，以及把 `JSValue` 收成可调用对象。

`createMappedArgumentsObject` / `createArgumentsObject` 是 `OP_special_object` 造 arguments 的 `noinline` 建造函数。

---

### `objectGetPrototypeOfStep` (`src/exec/object_ops.zig:1761`)

- **签名**：`pub fn objectGetPrototypeOfStep( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?*core.Object`。
- **作用**：一层 `[[GetPrototypeOf]]`：普通对象读 shape 原型；Proxy 走 trap + 不可扩展 invariant。
- **实现**：非 Proxy：`%ThrowTypeError%` 无原型时回退 `%Function.prototype%`（其 realm）；否则 `getPrototype()`。Proxy：无 handler TypeError。Get `getPrototypeOf`；缺 trap 则递归 target。调用 trap 得 null 或对象。若 target 不可扩展，结果必须等于 target 的原型。
- **所有权 / 错误 / 调用**：`isPrototypeOf`、lookupGetter、Has 链。返回 borrowed 指针（结果对象由 trap/shape 拥有）。

### `objectGetPrototypeOfValue` (`src/exec/object_ops.zig:1802`)

- **签名**：`pub inline fn objectGetPrototypeOfValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：把 Step 的 `?*Object` 收成 JS 值（对象或 `null`）。
- **实现**：inline 包装，避免第二份 trap 走查。
- **所有权 / 错误 / 调用**：`Object.getPrototypeOf` / `Reflect.getPrototypeOf` / `__proto__` getter。

### `destructuringObjectRest` (`src/exec/object_ops.zig:1814`)

- **签名**：`pub fn destructuringObjectRest( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：对象解构 rest：拷贝源上未排除且可枚举的 own 键。
- **实现**：无参 TypeError。源非对象则装箱。root 住 source/out/value。新对象挂 Object.prototype。`objectRestOwnKeys`；跳过 String 包装的 `length`；`objectRestKeyExcluded(args[1..])`；gopd 且 enumerable 才 Get（**从原始 args[0]**，不是装箱后的 source_value）并 define 到 rest。
- **所有权 / 错误 / 调用**：Get 用未装箱源，以保留原始 receiver。

### `objectRestOwnKeys` (`src/exec/object_ops.zig:1882`)

- **签名**：`pub fn objectRestOwnKeys( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: *core.Object, ) HostError![]core.Atom`。
- **作用**：`[[OwnPropertyKeys]]`：TypedArray / 普通 / Proxy `ownKeys` trap。
- **实现**：非 Proxy TypedArray → `typedArrayOwnKeys`。非 Proxy → `source.ownKeys`。Proxy：Get `ownKeys`；缺 trap 递归 target。trap 结果必须是对象；读 `length`，每下标须为 string/symbol，重复键 TypeError；`validateProxyOwnKeysResult`。trap 结果与累积 atom 列表都要 root（TGC S3 §4 V/B）。
- **所有权 / 错误 / 调用**：调用方 `Object.freeKeys`。assign/keys/integrity/fromEntries 共用。

### `objectRestOwnPropertyDescriptor` (`src/exec/object_ops.zig:1935`)

- **签名**：`pub fn objectRestOwnPropertyDescriptor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: *core.Object, key: core.Atom, ) !?core.Descriptor`。
- **作用**：rest/assign 用的 gopd，caller 为空（无字节码站点）。
- **实现**：`proxyAwareOwnPropertyDescriptor(..., null, null)`。
- **所有权 / 错误 / 调用**：薄包装。

### `objectRestKeyExcluded` (`src/exec/object_ops.zig:1945`)

- **签名**：`pub fn objectRestKeyExcluded(ctx: *core.JSContext, excluded: []const core.JSValue, key: core.Atom) !bool`。
- **作用**：解构已绑定的键是否应排除。
- **实现**：每个 excluded 值 `propertyKeyAtom`，与 key 比较。
- **所有权 / 错误 / 调用**：排除列表是已求值的属性键，不是任意对象。

### `atomicsBufferObject` (`src/exec/object_ops.zig:1953`)

- **签名**：`pub fn atomicsBufferObject(object: *core.Object) !*core.Object`。
- **作用**：TypedArray → 背后的 ArrayBuffer 对象。
- **实现**：`typedArrayBuffer()` 否则 TypeError；`expectObject`。
- **所有权 / 错误 / 调用**：Atomics 内建。

### `importMetaObject` (`src/exec/object_ops.zig:1958`)

- **签名**：`pub fn importMetaObject( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, ) !core.JSValue`。
- **作用**：惰性 `import.meta`：null 原型对象，带 `url` 与 `main`。
- **实现**：模块记录 `import_meta` 已有则返回。否则 `Object.create(..., null)`（对齐 `JS_NewObjectProto(ctx, JS_NULL)`，`quickjs.c:30900`；否则 ToPrimitive 会落到 Object.prototype.toString）。定义 url/main；写入 record 并 `generationalBarrier`（与 `setEvalException` 同因：记录早于首次求值）。
- **所有权 / 错误 / 调用**：`ModuleNotFound` 若 bytecode 无 scriptOrModule。

### `createGeneratorObject` (`src/exec/object_ops.zig:1984`)

- **签名**：`pub fn createGeneratorObject( ctx: *core.JSContext, func: core.JSValue, current_function_value: core.JSValue, this_value: core.JSValue, input_args: []const core.JSValue, input_var_refs: []const *core.VarRef, output: ?*std.Io.Writer, global: *core.Object, is_async: bool, call_depth_precharged: bool, call_entry_ctx: *core.JSContext, call_entry_global: *core.Object, ) !core.JSValue`。
- **作用**：造 generator/async generator 实例：执行状态、参数序言、最终原型。
- **实现**：root 住 func/current/this/boxed_this 与 args/var_refs 切片。argc > 65534 RangeError。`detached_shell = current.isObject()`：正常 JS 调用先 `createGeneratorShell`（避免短命 null-prototype Shape），内部字节码路径直接 create。shell 路径按 FB 尺寸 `initGeneratorExecutionWithStorage` 并 `PreparedEntryFrame`。保存 current function（realm 出处）。宽松 this：nullish→global，原始值装箱。`runGeneratorParameterInit`。`generatorObjectPrototype`；shell 则 `finishGeneratorShell`，否则 `setFreshObjectPrototype`。对照 `js_generator_function_call`。
- **所有权 / 错误 / 调用**：errdefer 区分 registered destroy 与 `destroyGeneratorShell`。

### `generatorObjectPrototype` (`src/exec/object_ops.zig:2125`)

- **签名**：`pub fn generatorObjectPrototype(rt: *core.JSRuntime, global: *core.Object, function_value: core.JSValue, is_async: bool) !OwnedPrototype`。
- **作用**：实例原型：函数 `.prototype` 若是对象，否则 `%Generator.prototype%` / async 变体。
- **实现**：fallback 先取 intrinsic。函数非对象 → fallback。own data prototype 或 Get 为对象则用它。
- **所有权 / 错误 / 调用**：Get 可能跑用户代码；调用方 defer deinit。

### `iteratorPrototypeAccessor` (`src/exec/object_ops.zig:2134`)

- **签名**：`pub fn iteratorPrototypeAccessor(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, id: u32) !core.JSValue`。
- **作用**：Iterator.prototype 上 constructor / toStringTag setter 的守卫，再转 `iterator_ops`。
- **实现**：constructor setter：有参则 receiver 与值须为对象。toStringTag setter：给 **home** Iterator.prototype 赋值 → `"Cannot assign to read only property"`。
- **所有权 / 错误 / 调用**：内建不可写属性的 JS 可见错误。

### `iteratorPrototypeAccessorSet` (`src/exec/object_ops.zig:2149`)

- **签名**：`pub fn iteratorPrototypeAccessorSet(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) !core.JSValue`。
- **作用**：按 atom 区分 constructor / @@toStringTag 的同样守卫。
- **实现**：与上一函数平行，键来自赋值站点而非 method id。
- **所有权 / 错误 / 调用**：`iterator_ops.iteratorPrototypeAccessorSet`。

### `iteratorPrototypeMethodCall` (`src/exec/object_ops.zig:2162`)

- **签名**：`pub fn iteratorPrototypeMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, method_id: u32, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：Iterator.prototype 方法体的转发。
- **实现**：原样转 `iterator_ops.iteratorPrototypeMethodCall`。
- **所有权 / 错误 / 调用**：exec 入口保留在 object_ops 以便 opcode/其它域调用。

### `iteratorIsOnIteratorPrototypeChain` (`src/exec/object_ops.zig:2184`)

- **签名**：`pub fn iteratorIsOnIteratorPrototypeChain(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) bool`。
- **作用**：值的原型链上是否出现 `%Iterator.prototype%`。
- **实现**：非对象假。沿 `getPrototype()` 比较指针。
- **所有权 / 错误 / 调用**：不跑 Proxy GetPrototypeOf。

### `wrapForValidIteratorPrototype` (`src/exec/object_ops.zig:2195`)

- **签名**：`pub fn wrapForValidIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object`。
- **作用**：惰性 `%WrapForValidIterator.prototype%`：`next`/`return` 挂在 Iterator.prototype 下。
- **实现**：缓存；create；定义 next/return 并 `tagIteratorWrapPrototypeMethod`（1/2）；store realm。
- **所有权 / 错误 / 调用**：`Iterator.from` 包装。

### `tagIteratorWrapPrototypeMethod` (`src/exec/object_ops.zig:2211`)

- **签名**：`pub fn tagIteratorWrapPrototypeMethod(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, key: core.Atom, method_id: i32) !void`。
- **作用**：给包装方法打 wrap-method 槽，并把原型设为 Function.prototype。
- **实现**：Get 方法对象；`functionIteratorWrapMethodSlot` 写入 id；可选 `setPrototype` Function.prototype。
- **所有权 / 错误 / 调用**：方法非对象则静默返回。

### `iteratorPrototypeFromGlobal` (`src/exec/object_ops.zig:2220`)

- **签名**：`pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：`%Iterator.prototype%`。
- **实现**：转 `iterator_ops`。
- **所有权 / 错误 / 调用**：薄转发。

### `iteratorPrototype` (`src/exec/object_ops.zig:2224`)

- **签名**：`pub fn iteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object`。
- **作用**：带 `@@toStringTag` 的迭代器原型（ArrayIterator 等）。
- **实现**：转 `iterator_ops.iteratorPrototype`。
- **所有权 / 错误 / 调用**：薄转发。

### `argumentsPropertyTemplate` (`src/exec/object_ops.zig:2228`)

- **签名**：`fn argumentsPropertyTemplate(rt: *core.JSRuntime, global: *core.Object, comptime mapped: bool) !*core.Shape`。
- **作用**：realm 上缓存的 mapped/unmapped arguments 初始 shape。
- **实现**：已有则返回。否则 `initializeInitialShapes`（Object/Array/RegExp 原型）后再读槽。
- **所有权 / 错误 / 调用**：无 context → TypeError。

### `createMappedArgumentsObject` (`src/exec/object_ops.zig:2245`)

- **签名**：`noinline fn createMappedArgumentsObject( ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, args: []core.JSValue, ) !core.JSValue`。
- **作用**：qjs `js_build_mapped_arguments`（quickjs.c:16215-16266）：从 `mapped_arguments_shape` 造对象，形参走 `captureArg`，多余实际参数走闭合 `VarRef`。
- **实现**：shape 用缓存或 `argumentsPropertyTemplate(..., true)`。entries：length、`argumentsIteratorValueOwned`、callee=`frame.current_function`。`Object.createArgumentsFromShape(mapped_arguments, ...)`；`errdefer destroyFromHeader`。`args.len==0` 直接返回。否则 `allocateMappedArgumentsVarRefsAssumingEmpty`：`[0, min(argc, formal))` `frame.captureArg`，其余 `VarRef.createClosed`。整表写完 `gc.rememberOwnerForBulkWrite`——中途 `captureArg`/`createClosed` 可能跑过 minor，remembered set 已被清，必须再记一次 owner。
- **所有权 / 错误 / 调用**：独立 `noinline` 是为了不把 thrower/accessor 建造坐进 sc_list / apply 热 I-cache。调用：`createArgumentsObject` 的 mapped 臂。

### `argumentsIteratorValueOwned` (`src/exec/object_ops.zig:2290`)

- **签名**：`fn argumentsIteratorValueOwned(ctx: *core.JSContext, global: *core.Object) !core.JSValue`。
- **作用**：arguments 的 `@@iterator`：realm 缓存的 `%Array.prototype.values%`。
- **实现**：`ctx.global == global` 时直读 `cached_values[array_prototype_values]`（qjs `JS_DupValue(ctx->array_proto_values)`，`quickjs.c:16162/16226`）。否则 `arrayPrototypeValuesFromGlobal`，没有则 undefined。
- **所有权 / 错误 / 调用**：bootstrap / 外供 global 走查找。

### `createArgumentsObject` (`src/exec/object_ops.zig:2310`)

- **签名**：`pub noinline fn createArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, mapped_override: ?bool) !core.JSValue`。
- **作用**：按有效严格性决定 mapped / unmapped arguments。zjs 适应：编译期可能给宽松函数发 mapped subtype，但 runtime-strict 必须降级 unmapped（spec 严格函数无映射 arguments，也不 `captureArg`）。
- **实现**：`mapped = requested ∧ ¬strict ∧ hasSimpleParameterList`（override 为 null 则只看后两项）。mapped 读 `frame.args`；unmapped 优先 `originalArgs()`。mapped 转 `createMappedArgumentsObject`。unmapped：`argumentsPropertyTemplate(..., false)`，callee 是 `throwTypeErrorIntrinsic` 的 getset（`fromBorrowedValues` 双 retain，对齐 qjs 16161-16164 两个 thrower 引用），iterator 同上。`createArgumentsFromShape(arguments, ...)`；有实际参数则 `createArrayStorageSlice` 拷元素，`adoptDenseUnmappedArgumentsElementsAssumingEmpty`。
- **所有权 / 错误 / 调用**：`noinline` 对齐 qjs `OP_special_object` 出线调用（quickjs.c:17971-17983）。调用：`frameArgumentsObjectForSpecialObject`。失败 `errdefer destroyFromHeader`。

### `installFunctionPrototypeThrowTypeErrorAccessors` (`src/exec/object_ops.zig:2362`)

- **签名**：`pub fn installFunctionPrototypeThrowTypeErrorAccessors(rt: *core.JSRuntime, global: *core.Object, thrower: core.JSValue) !void`。
- **作用**：给 `%Function.prototype%` 装 `arguments`/`caller` 的 %ThrowTypeError% 访问器。
- **实现**：无 Function.prototype 则返回。accessor 不可枚举可配置。
- **所有权 / 错误 / 调用**：realm 初始化。

### `isThrowTypeErrorIntrinsicObject` (`src/exec/object_ops.zig:2369`)

- **签名**：`pub fn isThrowTypeErrorIntrinsicObject(object: *core.Object) bool`。
- **作用**：识别 %ThrowTypeError% 函数对象。
- **实现**：`isThrowTypeErrorIntrinsicFunction()`。
- **所有权 / 错误 / 调用**：GetPrototypeOf 特判。

### `frameArgumentsObjectForSpecialObject` (`src/exec/object_ops.zig:2373`)

- **签名**：`pub fn frameArgumentsObjectForSpecialObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, subtype: u8) !core.JSValue`。
- **作用**：`OP_special_object` 造 arguments：subtype 0 非映射、1 映射。
- **实现**：`mapped_override` 0→false、1→true、其它 null。转 `createArgumentsObject`。编译器只发一次，结果存 hidden vardef；direct eval 经 closure2 捕获该 local。
- **所有权 / 错误 / 调用**：无第二份跨字节码 FrameCold 缓存。

### `functionObjectFromValue` (`src/exec/object_ops.zig:2385`)

- **签名**：`pub fn functionObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：值是否为任一 bytecode function class。
- **实现**：`objectFromValue` + `isBytecodeFunctionClass`。
- **所有权 / 错误 / 调用**：含 generator/async 函数对象。

### `plainBytecodeFunctionObjectFromValue` (`src/exec/object_ops.zig:2400`)

- **签名**：`pub inline fn plainBytecodeFunctionObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：inline-call 用：仅 `JS_CLASS_BYTECODE_FUNCTION` 一次比较（`quickjs.c:17816`）。
- **实现**：class_id 必须恰好 `bytecode_function`。四 class 位测会编译成 shift+mask；非 normal 反正两 load 后被 `functionKind() != .normal` 拒绝，精确比较让 generator/async 更早进慢路径。
- **所有权 / 错误 / 调用**：接受集与「normal bytecode function」相同。

### `callableObjectFromValue` (`src/exec/object_ops.zig:2413`)

- **签名**：`pub fn callableObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：C 函数 / c_function_data / async resume / c_closure / bound_function。
- **实现**：列 class id。不含 bytecode function（那是 `functionObjectFromValue`）。
- **所有权 / 错误 / 调用**：Proxy 可调用性另见 `proxyTargetIsCallable`。

`objectFromValue` / `objectFromValueTrustedExpression` 是 `core.value_semantics` 的 re-export，清单无函数行。

## 覆盖核对

- 清单函数数（本文件分到）: 28（`src/exec/object_ops.zig` 全文件 194）
- 本文标题覆盖: 28
- 未覆盖: 无（`object_ops.zig` 其余在兄弟分册）
