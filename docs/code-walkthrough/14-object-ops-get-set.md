# 14e — `object_ops.zig`：OrdinaryGet / Set / Has / Delete / Define

接 [14-object-ops-objects.md](14-object-ops-objects.md)。本文件是属性语义的主干：`getValueProperty` ≈ `JS_GetPropertyInternal`，`setValuePropertyWithThrow` ≈ `JS_SetPropertyInternal`。与 exotic/Proxy 的分界见 [14-property-ops.md](14-property-ops.md) 总述。

额外类型：

- `NamedDataPropertyProbe`：`{ slot: ?*const JSValue, needs_slow: bool }`。完整 ordinary miss（`slot==null && !needs_slow`）等于链走完 → undefined；`needs_slow` 才进完整解析器。
- `PendingPropertyDescriptor`：`{ atom_id, desc }`，`destroy` 为空（tracer 下无 rc）。
- `OwnPropertiesKind`：`keys/values/entries/own_names/own_symbols`。
- `NullishOwnError`：`.message` 带文案 / `.bare` 裸 TypeError。

---

### `toPropertyKeyValue` (`src/exec/object_ops.zig:2423`)

- **签名**：`pub fn toPropertyKeyValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：ToPropertyKey 的值半截：非对象原样，对象走 ToPrimitive hint string。
- **实现**：`!isObject` 返回 value；否则 `toPrimitiveForString`。
- **所有权 / 错误 / 调用**：还不 intern。Symbol 保持 symbol。

### `toPropertyKeyAtom` (`src/exec/object_ops.zig:2435`)

- **签名**：`pub fn toPropertyKeyAtom( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.Atom`。
- **作用**：完整 ToPropertyKey → atom。
- **实现**：`toPropertyKeyValue` + `property_ops.propertyKeyAtom`。
- **所有权 / 错误 / 调用**：`Object.defineProperty`、computed 键、`in` 的完整路径。

### `callObjectToPrimitiveMethod` (`src/exec/object_ops.zig:2447`)

- **签名**：`pub fn callObjectToPrimitiveMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：OrdinaryToPrimitive：取 `toString`/`valueOf` 并调用，对象结果当「没有」。
- **实现**：`getMethodPropertyForOrdinaryToPrimitive`；undefined/null 或不可调用 → `null`。调用；结果仍是对象 → `null`。
- **所有权 / 错误 / 调用**：`null` 表示试下一个 hint 方法。

### `getMethodPropertyForOrdinaryToPrimitive` (`src/exec/object_ops.zig:2467`)

- **签名**：`pub fn getMethodPropertyForOrdinaryToPrimitive( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：ToPrimitive 专用 Get：Proxy 走完整 `[[Get]]`；否则先 `findPropertyDescriptor`。
- **实现**：Proxy → `getProxyProperty`。描述符 data 返回值；accessor 调 getter；generic undefined。没有描述符则 `getValueProperty`。
- **所有权 / 错误 / 调用**：避免 ToPrimitive 自己再进 ToPrimitive。

### `getValueProperty` (`src/exec/object_ops.zig:2491`)

- **签名**：`pub fn getValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：可观察 `[[Get]]` 总入口（qjs `JS_GetPropertyInternal`）。
- **实现**：`value.is(.object)` 为真走对象臂，否则尾调 `getValuePropertyNonObject`。对象臂按下列固定顺序试探，前一步不命中才进下一步：
  1. `mightBePrivate` 且 kind==private → `getPrivateValueProperty`（QJS 把私有挡在 Internal 外；`mightBePrivate` 是 AtomTable 的保守下界，`exec`/`flags`/`lastIndex` 这类预定义名只付这一次便宜比较，确认是私有才查完整 kind 表）。
  2. `mappedArgumentsValue`：映射 arguments 覆盖 live cell。
  3. `class_id == proxy` → `getProxyProperty`。
  4. `class_id` 落在 `uint8c_array..float64_array` 且 `findProperty(atom_id) == null`（**shape miss**）：`typedArrayCanonicalGet`（规范数值下标从不占 shape 槽；`length`/`byteLength`/`byteOffset` 这些名字不在这里合成，继续沿真实原型链解析）。
  5. 无 exotic：Array 的 length / tagged-int dense 元素 / own data；普通 object 的 own data。
  6. function-like 且键是 `caller`/`arguments` → `functionCallerArgumentsProperty`（只为这两键付 outlined 代价）。
  7. `getPropertyValueFromObjectChain`：每层先 shape。
  8. 链尽 → undefined（`quickjs.c:8355-8363`：无 class-name 兜底、无 DataView own-leg、无 String 下标 miss 合成）。
- **所有权 / 错误 / 调用**：返回 owned 值。error 来自再入的 getter / Proxy trap（待决异常）或分配失败。这是赋值右侧、内建 Get、Proxy 缺 trap 时的权威路径；`getValuePropertyWithReceiver` 在 receiver 与对象一致时也直接落到这里。快探（`probeNamedDataProperty` 一族）失败才走本函数。

### `probeNamedDataProperty` (`src/exec/object_ops.zig:2583`)

- **签名**：`pub inline fn probeNamedDataProperty( rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, ) NamedDataPropertyProbe`。
- **作用**：内部算法已有 atom 时的 data-only 前缀，不付计算键转换。
- **实现**：tagged int 或 maybe-private → `{ needs_slow=true }`。`objectFromValueTrustedExpression` 失败同样 slow。否则 `probePublicNamedDataPropertyFromObject`。
- **所有权 / 错误 / 调用**：完整 ordinary miss 与 slow/exotic 必须分开：前者立刻 undefined。

### `probePublicNamedDataPropertyFromObject` (`src/exec/object_ops.zig:2597`)

- **签名**：`pub inline fn probePublicNamedDataPropertyFromObject( initial_object: *core.Object, atom_id: core.Atom, ) NamedDataPropertyProbe`。
- **作用**：从已知对象沿原型找 **公开非下标** own data 槽。
- **实现**：循环 `findOwnDataSlotFast`：命中返回 slot；`slow_property` 或 `needsSlowPropertyAccess` → needs_slow；无原型 → 空 probe（ordinary miss）。
- **所有权 / 错误 / 调用**：`JS_IsInstanceOf` 在要 `@@hasInstance` 前已要求 RHS 为对象（`quickjs.c:8136-8139`）。

### `getValuePropertyNonObject` (`src/exec/object_ops.zig:2610`)

- **签名**：`noinline fn getValuePropertyNonObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`[[Get]]` 的非对象臂：原始值读原型，nullish 带消息 TypeError。
- **实现**：私有 atom → `TypeError`（原始值没有私有字段）。字符串：`length` 走 `value_ops.length`；整数下标 `getStringIndexValue`；否则 `getPrimitiveProperty`。number/bool/bigint/symbol 一律 `getPrimitiveProperty`（不装箱）。null/undefined → `throwNullishPropertyTypeError`。其它 tag `TypeError`。
- **所有权 / 错误 / 调用**：`getValueProperty` 在 `!value.is(.object)` 时。outlined 避免把原始值/nullish 冷路径拼进对象热入口。返回 owned。

### `functionCallerArgumentsProperty` (`src/exec/object_ops.zig:2635`)

- **签名**：`noinline fn functionCallerArgumentsProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：遗留 `Function.caller` / `Function.arguments`：只为这两键付 outlined 代价。
- **实现**：非函数类或键不是 `caller`/`arguments` → `null`（入口已预过滤，这里再守一次）。有 own：data 返回值；generic undefined；accessor 调 getter（无 getter → undefined）。否则看 FB：strict / runtime-strict → TypeError。`generator_function`/`async_function`/`async_generator_function` TypeError。`bytecode_function`：`hasPrototype()`（普通函数）→ undefined，否则 TypeError（箭头）。其余 TypeError。用预定义 atom id 比较，避免每个函数对象每次属性读都做名字查找+两次 memcmp（qjs 同样 `atom == JS_ATOM_caller`）。
- **所有权 / 错误 / 调用**：`getValueProperty` 仅在函数类且键命中时。`null` 表示「不是这两键的遗留语义，继续普通链」。

### `getPrivateValueProperty` (`src/exec/object_ops.zig:2679`)

- **签名**：`noinline fn getPrivateValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：私有字段读：只看 own，没有就 brand TypeError。
- **实现**：`getOwnProperty`：data 返回值；generic TypeError；accessor 无 getter TypeError，否则 `callValueOrBytecodeSyncInternal(receiver, getter, &.{})`。没有 own → `throwPrivateBrandTypeError`。不沿原型、不走 Proxy/mapped args。
- **所有权 / 错误 / 调用**：`getValueProperty` 在 `mightBePrivate && kind==private` 时。QJS 把私有挡在 `JS_GetPropertyInternal` 外；zjs 共享入口，故先下界检查再进本函数。

### `setPrivateValueProperty` (`src/exec/object_ops.zig:2702`)

- **签名**：`pub fn setPrivateValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：私有字段写：只看 own。
- **实现**：`getOwnProperty`：data 须 writable 且 `setOwnWritableDataProperty`；accessor 须有 setter 并调用；generic TypeError。没有 own → `throwPrivateBrandTypeError`。
- **所有权 / 错误 / 调用**：不沿原型、不添加新公开属性。

### `getPrimitiveProperty` (`src/exec/object_ops.zig:2732`)

- **签名**：`pub fn getPrimitiveProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：原始值 `[[Get]]`：走 `%String.prototype%` 等链，**不装箱**，receiver 保持原始值。
- **实现**：`getFastStringPrimitiveDataProperty` 先试。`primitivePrototypeForAccess` 无原型 → undefined。否则 `getPropertyValueFromObjectChain` 从该原型开始。对照 `JS_GetPropertyInternal` 对原始值直接选 `ctx->class_proto`。装箱属于 ToObject / `OP_push_this`。
- **所有权 / 错误 / 调用**：字符串下标在 NonObject 臂用 `getStringIndexValue`。

### `ownDataOrAutoInitPropertyValue` (`src/exec/object_ops.zig:2752`)

- **签名**：`pub fn ownDataOrAutoInitPropertyValue(object: *core.Object, atom_id: core.Atom) !?core.JSValue`。
- **作用**：own data 直接读槽；auto-init 触发 `getProperty` 物化。
- **实现**：exotic → `null`。data 返回槽；auto_init 走完整 get；var_ref/accessor `null`。
- **所有权 / 错误 / 调用**：给需要物化惰性 `prototype` 的路径。

### `getValuePropertyWithReceiver` (`src/exec/object_ops.zig:2780`)

- **签名**：`pub fn getValuePropertyWithReceiver( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_value: core.JSValue, target: *core.Object, receiver_value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`[[Get]]` 带独立 receiver（super / Proxy 缺 get trap 转发）。
- **实现**：从 target 沿原型：遇 Proxy → `getProxyProperty(receiver)`；own 描述符 data/accessor（getter 用 receiver 调）。链尽则退回 `getValueProperty(target_value)`。
- **所有权 / 错误 / 调用**：receiver 可以不是 target。**已知代价（函数头注释已写明为有意）**：qjs `JS_GetPropertyInternal(ctx, obj, prop, this_obj, …)`（quickjs.c:8268）把 `this_obj` 穿进**同一趟**链走查，zjs 拆成「这里的描述符走查 + `getValueProperty` 收尾」，因此**完全未命中时同一条原型链会被走两趟**（`super.missing`、无 get trap 的 Proxy 是 O(2×链长)）。第二趟不是冗余：它提供描述符走查表达不出的入口特判（private-name atom、函数目标上的 legacy `caller`/`arguments`）；之所以保留整段再入而不是手挑子集，是因为这些入口检查与普通走查的先后顺序只由 `getValueProperty` 一处定义。注意收尾传的是 `target_value` 而非 `receiver_value`——它能解析出的东西，按定义都是上面那趟 receiver 感知走查已经放弃的。

### `primitiveObjectForAccess` (`src/exec/object_ops.zig:2810`)

- **签名**：`pub fn primitiveObjectForAccess(rt: *core.JSRuntime, global: *core.Object, primitive: core.JSValue) !core.JSValue`。
- **作用**：可观察 ToObject：造包装对象。
- **实现**：root 住 primitive。按类型选原型。String：create string class，逐 code unit `defineStringWrapperIndexProperty`，不可写 `length`。其它 Number/Boolean/BigInt/Symbol 只 `setOptionalValueSlot`。
- **所有权 / 错误 / 调用**：`Object.assign` 装箱、宽松 this。属性 **读** 不得走这里。

### `setValueProperty` (`src/exec/object_ops.zig:2888`)

- **签名**：`pub fn setValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：`[[Set]]`，失败是否抛跟调用方严格性。
- **实现**：`setValuePropertyWithThrow(..., false)`。返回 `undefinedValue()`（赋值表达式的完成值由 VM 管）。
- **所有权 / 错误 / 调用**：opcode `put_field` 等。

### `setValuePropertyWithThrow` (`src/exec/object_ops.zig:2906`)

- **签名**：`pub fn setValuePropertyWithThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, force_throw: bool, ) HostError!core.JSValue`。
- **作用**：带 `JS_PROP_THROW` 覆盖的 Set。数组内建必须 `force_throw=true`，不论调用方是否严格（`JS_SetPropertyInt64`）。
- **实现**：`throw_on_set_failure = force_throw or setFailureShouldThrow(caller_function)`。
  1. private：非对象 TypeError；`setPrivateValueProperty`。
  2. 非对象：nullish TypeError；装箱后 `ordinarySetWithReceiver`（receiver 仍是原始值）。
  3. Proxy 接收者 → `proxySetValueProperty`。
  4. with 环境 + 严格 + 无该属性 → ReferenceError。
  5. mapped arguments 写穿。
  6. TypedArray canonical set。
  7. Array `length`：`arrayLengthAssignmentValue` + `setProperty`，InvalidLength→RangeError。
  8. Array 整数下标：`appendDenseArrayIndex`。
  9. **一次** `setOrDefineOwnDataPropertyForSimpleSet`（qjs 单次 `find_own_property`，`quickjs.c:9707`）。
  10. `typedArrayPrototypeSet`（原型上的 TypedArray）。
  11. `callAccessorSetter`。
  12. `firstProxyInPrototypeSetPath` → 对该 Proxy 做 set trap。
  13. 再 private 拒绝；`arrayLengthAssignmentValue`；`setProperty`。
  失败且需抛 → `throwSetFailureTypeError`。
- **所有权 / 错误 / 调用**：这是 OrdinarySet + 各 exotic 的合并入口。

### `setWithOwnDescriptor` (`src/exec/object_ops.zig:3023`)

- **签名**：`pub fn setWithOwnDescriptor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, atom_id: core.Atom, value: core.JSValue, own_desc: core.Descriptor, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：已知 own 描述符时的 OrdinarySetWithOwnDescriptor（Reflect.set / super）。
- **实现**：accessor → 调 setter 或 false。data 且 `writable == false` → false（generic 不看 writable）。看 **receiver** 的 gopd：已有 accessor 或不可写 data → false；已存在（可写 data/generic）则用只带 `value` 的部分描述符 define，不动原有 W/E/C；receiver 上不存在才创建 W/E/C=true 的 data。Proxy receiver 走 `proxyDefineOwnProperty`。
- **所有权 / 错误 / 调用**：返回是否成功，不自动转 TypeError。

### `bytecodeFunctionObjectTag` (`src/exec/object_ops.zig:3072`)

- **签名**：`pub fn bytecodeFunctionObjectTag(object: *core.Object) []const u8`。
- **作用**：`Object.prototype.toString` 用的 tag：Function / AsyncFunction / GeneratorFunction。
- **实现**：读 FB kind。无 FB → `"Function"`。
- **所有权 / 错误 / 调用**：静态字符串。

### `definePropertyWithKind` (`src/exec/object_ops.zig:3080`)

- **签名**：`pub fn definePropertyWithKind( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, kind: i32, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Object.defineProperty`（kind≠2 失败抛）与 `Reflect.defineProperty`（kind==2 返回布尔）。
- **实现**：目标须对象；ToPropertyKey；描述符对象 `descriptorFromObject`。Proxy → `proxyDefineOwnProperty`；TypedArray → `typedArrayDefineOwnPropertyVm`；否则 `defineOwnProperty`。kind==2 成功 true/失败 false；否则返回 args[0] 或 TypeError/RangeError。
- **所有权 / 错误 / 调用**：`objectCallForNativeRecord` 用 kind=1。

### `PendingPropertyDescriptor.destroy` (`src/exec/object_ops.zig:3132`)

- **签名**：`pub fn destroy(_: PendingPropertyDescriptor, _: *core.JSRuntime) void`。
- **作用**：占位释放（tracer 下描述符不持 rc）。
- **实现**：空体。
- **所有权 / 错误 / 调用**：队列里的 pending define。

### `objectEnumerableOwnPropertiesCall` (`src/exec/object_ops.zig:3148`)

- **签名**：`pub fn objectEnumerableOwnPropertiesCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, kind: OwnPropertiesKind, nullish: NullishOwnError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Object.keys/values/entries` 与 `getOwnPropertyNames/Symbols` 的共用走查。
- **实现**：nullish 按 `.message`/`.bare`。ToObject；ownKeys；造数组。own_names 跳过 symbol；own_symbols 只要 symbol。keys/values/entries 跳过 symbol，gopd 且 enumerable 才收（**每键复查**，与 assign 快照相反）。values Get；entries `objectEntryArrayValue`。`createDataPropertyOrThrow` 追加。
- **所有权 / 错误 / 调用**：root 住 object/out/element。

### `objectProtoGetterCall` (`src/exec/object_ops.zig:3213`)

- **签名**：`pub fn objectProtoGetterCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Object.prototype.__proto__` getter。
- **实现**：nullish TypeError；ToObject；`objectGetPrototypeOfValue`。
- **所有权 / 错误 / 调用**：Annex B。

### `objectProtoSetterCall` (`src/exec/object_ops.zig:3227`)

- **签名**：`pub fn objectProtoSetterCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, prototype_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`__proto__` setter：非法原型或非对象 this 静默成功。
- **实现**：nullish this TypeError。原型非 null 且非对象 → undefined。this 非对象 → undefined。否则 `objectSetPrototypeOfCall`。始终返回 undefined。
- **所有权 / 错误 / 调用**：与 `Object.setPrototypeOf` 不同：后者对非对象原型抛。

### `objectIsExtensibleCall` (`src/exec/object_ops.zig:3256`)

- **签名**：`pub inline fn objectIsExtensibleCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Object.isExtensible` / `Reflect.isExtensible` 的 JS 入口。
- **实现**：非对象 → `false`。否则 `proxyAwareIsExtensible` 包成布尔。
- **所有权 / 错误 / 调用**：inline，把「原始值承认」留在包装层。

### `objectSetPrototypeOfCall` (`src/exec/object_ops.zig:3269`)

- **签名**：`pub fn objectSetPrototypeOfCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Object.setPrototypeOf`：失败抛（循环 / 不可扩展）。
- **实现**：target nullish `"not an object"`。原型须 null 或对象。非对象 target 原样返回。不可变原型且改变 → TypeError。Proxy → `proxyAwareSetPrototypeOf`。`setPrototype`：循环消息走 **callee realm** 的 `throwTypeErrorMessage(global, ...)`，禁止裸 `error.TypeError`（否则 VM catch 用 caller realm）。
- **所有权 / 错误 / 调用**：跨 realm `gw.Object.setPrototypeOf` 必须得到 gw 的 TypeError。

### `reflectSetPrototypeOfCall` (`src/exec/object_ops.zig:3301`)

- **签名**：`pub fn reflectSetPrototypeOfCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.setPrototypeOf`：失败返回 false，不抛循环/不可扩展。
- **实现**：缺参 `null`。非对象 TypeError。不可变且改变 → false。Proxy 返回 trap 布尔。`PrototypeCycle`/`NotExtensible` → false。
- **所有权 / 错误 / 调用**：与 Object.setPrototypeOf 共享 `setPrototype`。

### `reflectConstructPrototypeVm` (`src/exec/object_ops.zig:3326`)

- **签名**：`pub fn reflectConstructPrototypeVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_name: []const u8, new_target: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !OwnedPrototype`。
- **作用**：GetPrototypeFromConstructor：可观察 Get `new_target.prototype`，非对象则用 new_target 的 realm intrinsic。
- **实现**：Get 是对象 → handle。`functionRealmContext`。`constructorClassPrototypeId` 或 `nativeErrorKindFromConstructorName` 选 class / native_error 原型。
- **所有权 / 错误 / 调用**：`class_init` 每个内建 super 都先走这里。derived `super()` 必须跑 accessor/Proxy。

### `objectHasImmutablePrototype` (`src/exec/object_ops.zig:3351`)

- **签名**：`fn objectHasImmutablePrototype(object: *core.Object) bool`（文件私有；原先恒被丢弃的 `rt` 形参已删）。
- **作用**：不可变原型（模块命名空间、部分 intrinsic）。
- **实现**：`object.hasImmutablePrototype()`。
- **所有权 / 错误 / 调用**：setPrototypeOf 在非 Proxy 上先挡。

### `reflectDeletePropertyCall` (`src/exec/object_ops.zig:3355`)

- **签名**：`pub fn reflectDeletePropertyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.deleteProperty`。
- **实现**：expectObject；ToPropertyKey；`deleteValueProperty` 包成布尔。
- **所有权 / 错误 / 调用**：不因不可配置抛（返回 false）；Proxy invariant 仍可 TypeError。

### `reflectGetOwnPropertyDescriptorCall` (`src/exec/object_ops.zig:3369`)

- **签名**：`pub fn reflectGetOwnPropertyDescriptorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.getOwnPropertyDescriptor`。
- **实现**：非对象 TypeError；gopd；mapped arguments 物化；`descriptorObjectFromDescriptor`。
- **所有权 / 错误 / 调用**：无描述符 → undefined。

### `reflectGetPrototypeOfCall` (`src/exec/object_ops.zig:3385`)

- **签名**：`pub fn reflectGetPrototypeOfCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.getPrototypeOf`：要求对象，不装箱。
- **实现**：非对象 TypeError；`objectGetPrototypeOfValue`。
- **所有权 / 错误 / 调用**：与 `Object.getPrototypeOf`（装箱）不同。

### `descriptorObjectFromDescriptor` (`src/exec/object_ops.zig:3398`)

- **签名**：`pub fn descriptorObjectFromDescriptor(rt: *core.JSRuntime, global: *core.Object, desc: core.Descriptor) !core.JSValue`。
- **作用**：内部 Descriptor → 普通对象 `{value,writable,get,set,enumerable,configurable}`。
- **实现**：root 住 value/getter/setter。create 挂 Object.prototype。按 kind 定义存在的域。
- **所有权 / 错误 / 调用**：gopd 返回值。GC 单测钉 bytecode 值。

### `descriptorFromObject` (`src/exec/object_ops.zig:3458`)

- **签名**：`pub fn descriptorFromObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, desc_value: core.JSValue, desc_object: *core.Object, target: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.Descriptor`。
- **作用**：ToPropertyDescriptor：读 value/writable/get/set/enumerable/configurable。
- **实现**：Has 各键；get/set 若非 undefined 须可调用。同时有 accessor 域与 data 域 → TypeError。Array `length` 的 value 非 number 时 `arrayLengthDefineValue`。都没有 → generic 描述符。
- **所有权 / 错误 / 调用**：Has 用 `hasValueProperty`（可走 Proxy）。

### `optionalBoolDescriptorProperty` (`src/exec/object_ops.zig:3544`)

- **签名**：`pub fn optionalBoolDescriptorProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, desc_value: core.JSValue, desc_object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?bool`。
- **作用**：描述符对象上可选布尔域：没有键 → `null`。
- **实现**：Has 为假 `null`；否则 Get + `valueTruthy`。
- **所有权 / 错误 / 调用**：enumerable/configurable。

### `getPropertyValueFromObjectChain` (`src/exec/object_ops.zig:3559`)

- **签名**：`inline fn getPropertyValueFromObjectChain( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, first: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：OrdinaryGet 的原型走查：**每层先 shape**，miss/非普通才进 slow。
- **实现**：`findOwnPropertySlotTrusted`：data 返回槽；accessor 调 getter（K3 native 终端 `tryNativeAccessorCall`）；auto_init/var_ref 落到 slow。shape miss 且 `!needsSlowPropertyAccess` → 下一层。否则 `getSlowPropertyValueFromObject`。链尽 `null`（调用方变 undefined）。
- **所有权 / 错误 / 调用**：这是 ordinary vs exotic 的分界循环。Proxy/TypedArray 税只在 slow 臂。

### `getSlowPropertyValueFromObject` (`src/exec/object_ops.zig:3602`)

- **签名**：`noinline fn getSlowPropertyValueFromObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：shape miss / 非普通 kind 之后的 class/exotic 合成臂；故意不进 ordinary shape 循环的帧。
- **实现**：本层 `class_id==proxy` → `getProxyProperty`（原型链上的 Proxy 在这里才付税）。TypedArray：`typedArrayCanonicalGet`（元素从不占 shape；与接收者侧入口同一调用，HAS 的原型走查有 `typedArrayCanonicalHas`）。然后 `getOwnProperty`：data/generic/accessor（无 getter → undefined）。都没有 `null`，调用方继续下一层原型。对齐 qjs `JS_GetPropertyInternal` 在 `find_own_property` miss 后的 `is_exotic && fast_array`（`quickjs.c:8296-8316`）。
- **所有权 / 错误 / 调用**：`getPropertyValueFromObjectChain` 在 shape miss 且 `needsSlowPropertyAccess`、或 hit 了 auto_init/var_ref 时。返回 owned；`null` 不是 undefined。

### `getSuperPropertyValue` (`src/exec/object_ops.zig:3638`)

- **签名**：`pub fn getSuperPropertyValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, prototype: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`super[key]`：从 **home 原型** 走查，getter 用 receiver（通常是 `this`）。
- **实现**：`findPropertyDescriptor`：accessor/data。TypedArray 在每层 shape miss 后仍供 canonical 下标（与 GetInternal exotic 臂相同，`quickjs.c:8296-8316`）。链尽 undefined。
- **所有权 / 错误 / 调用**：`getSuperValue` opcode。不走 mapped args 入口特判（从 prototype 起）。

### `setSuperPropertyValue` (`src/exec/object_ops.zig:3671`)

- **签名**：`pub fn setSuperPropertyValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, prototype: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：`super[key] = value`：先看原型上的描述符，再 Set 到 receiver。
- **实现**：原型上 accessor → 调 setter（无 setter 且严格则抛）。data 不可写且严格则抛。`rejectModuleNamespaceSuperSet`。否则 `setValueProperty(receiver)`。没有描述符同样 reject module ns 后 Set receiver。
- **所有权 / 错误 / 调用**：严格性来自 caller_function。

### `findPropertyDescriptor` (`src/exec/object_ops.zig:3713`)

- **签名**：`pub fn findPropertyDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor`。
- **作用**：沿原型 `getOwnProperty`，不跑 Proxy 作为起点的 trap（但 getOwnProperty 本身可物化 auto-init）。
- **实现**：own 命中返回；否则递归原型。
- **所有权 / 错误 / 调用**：super 与 ToPrimitive 方法查找。

### `sameObjectIdentity` (`src/exec/object_ops.zig:3719`)

- **签名**：`pub fn sameObjectIdentity(a: core.JSValue, b: core.JSValue) bool`。
- **作用**：两值是否同一堆对象（header 指针）。
- **实现**：都须 isObject 且 `refHeader` 相等。
- **所有权 / 错误 / 调用**：不是 `SameValue`（NaN/+0 规则）。

### `hasPropertyForWith` (`src/exec/object_ops.zig:3737`)

- **签名**：`pub inline fn hasPropertyForWith( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：`with` 环境的 Has：JSValue 收成对象再 `hasValueProperty`。
- **实现**：`expectObject` + 转发。避免第二份 Proxy has trap 拷贝。
- **所有权 / 错误 / 调用**：with 绑定解析。

### `hasValueProperty` (`src/exec/object_ops.zig:3750`)

- **签名**：`pub fn hasValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：`[[HasProperty]]`：Proxy 走 `has` trap，否则 ordinary。
- **实现**：无 proxy → `ordinaryHasValueProperty(..., false)`。`receiver` 形参不被读取——[[HasProperty]] 本身没有 receiver（trap 拿的是 target），保留只为让 get/set/delete/has 四个操作在 `array_ops` / `reflect_ops` 的跨文件调用点保持同形；函数头注释已写明。有 trap：Get `has`；缺则递归 target；调用后 `validateProxyHasResult`。
- **所有权 / 错误 / 调用**：`in`、描述符 Has、with。

### `ordinaryHasValueProperty` (`src/exec/object_ops.zig:3778`)

- **签名**：`pub fn ordinaryHasValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, atom_id: core.Atom, has_builtin_object_proto: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：非 Proxy Has：own + 原型，模块命名空间不走 GetOwnProperty。
- **实现**：`module_ns` → 只 `hasOwnProperty`（避免 TDZ 读绑定）。`typedArrayCanonicalHas`；`indexedExoticHasProperty`。`existsOwnProperty`（qjs desc==NULL，不 dup 值；pdfjs 上曾占 ~5.5%）。原型遇 Proxy → `hasValueProperty`。`has_builtin_object_proto` 链尽兜底（现调用传 false）。
- **所有权 / 错误 / 调用**：存在性，不调 getter。

### `indexedExoticHasProperty` (`src/exec/object_ops.zig:3819`)

- **签名**：`pub fn indexedExoticHasProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool`。
- **作用**：String 对象下标或 TypedArray canonical index 是否存在。
- **实现**：`stringObjectHasIndexProperty`；TypedArray `typedArrayCanonicalHas orelse false`。
- **所有权 / 错误 / 调用**：不跑用户代码。

### `deleteValuePropertyOrThrow` (`src/exec/object_ops.zig:3825`)

- **签名**：`pub fn deleteValuePropertyOrThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, ) !void`。
- **作用**：严格 `delete`：失败 TypeError。
- **实现**：`deleteValueProperty` 为假则 TypeError。
- **所有权 / 错误 / 调用**：严格模式 opcode。

### `deleteValueProperty` (`src/exec/object_ops.zig:3836`)

- **签名**：`pub fn deleteValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：`[[Delete]]`。
- **实现**：`receiver` 形参不被读取，理由同 `hasValueProperty`（[[Delete]] 无 receiver）。非 Proxy → `object.deleteProperty`。Proxy：Get `deleteProperty`；缺 trap 递归。trap 假 → false。真则读 target gopd（嵌套 Proxy 会再 trap）：不可配置 TypeError；再 `proxyAwareIsExtensible`（**会** 打 isExtensible trap，与 `js_proxy_has` 不同，`quickjs.c:51157`）。
- **所有权 / 错误 / 调用**：返回是否删除。

### `defineValueProperty` (`src/exec/object_ops.zig:3874`)

- **签名**：`pub fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void`。
- **作用**：W/E/C=true 的 data define。
- **实现**：`defineOwnProperty(Descriptor.data(..., true,true,true))`。
- **所有权 / 错误 / 调用**：描述符对象字段、import.meta。

### `defineFunctionNameProperty` (`src/exec/object_ops.zig:3878`)

- **签名**：`pub fn defineFunctionNameProperty(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void`。
- **作用**：仅当现有 `name` 为空时定义可配置不可枚举不可写的 `name`。
- **实现**：`objectHasNonEmptyName` 为真则返回。否则 define。
- **所有权 / 错误 / 调用**：方法/class 安装名，不覆盖已有非空名。

### `objectHasNonEmptyName` (`src/exec/object_ops.zig:3884`)

- **签名**：`pub fn objectHasNonEmptyName(rt: *core.JSRuntime, object: *core.Object) !bool`。
- **作用**：own `name` 是否为非空字符串。
- **实现**：无 own 或非 data 字符串 → false。`appendRawString` 看长度。
- **所有权 / 错误 / 调用**：append 失败当 false。

### `throwNullishPropertyTypeError` (`src/exec/object_ops.zig:3893`)

- **签名**：`pub fn throwNullishPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, atom_id: core.Atom) !core.JSValue`。
- **作用**：`null.foo` / `undefined.foo` 的 TypeError 消息。
- **实现**：`atomPropertyName`；`"cannot read property '{s}' of null|undefined"`。
- **所有权 / 错误 / 调用**：`getValuePropertyNonObject`。返回类型是 `!JSValue` 但实际总是 throw（`throwTypeErrorMessage`）。

### `throwNullishComputedPropertyTypeError` (`src/exec/object_ops.zig:3906`)

- **签名**：`pub fn throwNullishComputedPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, key: core.JSValue) !core.JSValue`。
- **作用**：计算键版本：键经 `appendValueString`。
- **实现**：同文案。
- **所有权 / 错误 / 调用**：`obj[expr]` 当 obj 为 nullish。

### `atomPropertyName` (`src/exec/object_ops.zig:3920`)

- **签名**：`pub fn atomPropertyName(rt: *core.JSRuntime, atom_id: core.Atom) ![]const u8`。
- **作用**：atom → 新分配的名字字节（int atom 印十进制）。
- **实现**：tagged int `allocPrint`；否则 `dupe` atom 名（无则空串）。
- **所有权 / 错误 / 调用**：调用方 `allocator.free`。

## 覆盖核对

- 清单函数数（本文件分到）: 53（`src/exec/object_ops.zig` 全文件 194）
- 本文标题覆盖: 53
- 未覆盖: 无（`object_ops.zig` 其余在兄弟分册）
