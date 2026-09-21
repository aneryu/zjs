# 14f — `object_builtin_ops.zig`：`Object` 内建表与算法

[`src/exec/object_ops.zig`](../../src/exec/object_ops.zig) 是 `.object` 域的 native-record：构造入口 + `Object.*` 静态 + `Object.prototype.*`。接收者与参数 borrowed，返回 owned `JSValue`。对照 `js_object_constructor` 与表 `quickjs.c:40098`、`41006-41054`。

值级 Get/Set/Proxy/ownKeys 仍走 `object_ops` 别名。本文件只拥有「JS 可见的 Object 方法」。

## 类型与表

`RootedValueCopies`：复制一份 `[]JSValue` 并为每个元素挂 `ValueRootValue`。只拥有 root/bits 缓冲，不拥有值的堆对象。`init` / `deinit` 是其方法。

`StaticMethod` / `ConstructorMethod`：re-export `builtin_method_ids.object`。

`PrototypeMethod`：`to_string=101` … `lookup_setter=110`，与 install 顺序、`objectCallForNativeRecord` 的 magic 对齐。

`internal_entries`：构造器一条 + 全部静态 + 原型方法。`hasOwnProperty` 额外挂 `managed = objectHasOwnPropertyDirect`。

`EntriesMode` / `ownEntriesArray`：core re-export。

`ObjectIteratorStepValue`：`{ value, done }`。

`OwnPropertyKeyFilter`：`.string` / `.symbol`，给 `getOwnPropertyNames` / `Symbols`。

---

### `RootedValueCopies.init` (`src/exec/object_ops.zig:69`)

- **签名**：`fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies`。
- **作用**：为即将定义到新对象上的值数组挂 GC 根。
- **实现**：`alloc` 拷贝 `values`；再 `alloc` 等长 `roots`，每项 `{ .value = &values[i] }`。失败 `errdefer` 释放已分配缓冲。
- **所有权 / 错误 / 调用**：`literal` 在 `Object.create` / `defineOwnProperty` 可能触发 GC 时使用。`deinit` 只 `free` 两片缓冲。

### `RootedValueCopies.deinit` (`src/exec/object_ops.zig:83`)

- **签名**：`fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void`。
- **作用**：释放 root 与 values 缓冲。
- **实现**：先 free roots，再 free values。不 `JS_FreeValue`。
- **所有权 / 错误 / 调用**：须在 `ValueRootFrame.deactivate` 之后。

### `staticMethodId` (`src/exec/object_ops.zig:105`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：把 `Object.xxx` 名字映到 `StaticMethod` 枚举整型。
- **实现**：一串 `mem.eql`：assign/create/defineProperty/…/groupBy。未知 `null`。
- **所有权 / 错误 / 调用**：install 与测试用，热路径走 magic id。

### `prototypeMethodId` (`src/exec/object_ops.zig:132`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：`Object.prototype` 方法名 → `PrototypeMethod`。
- **实现**：toString … `__lookupSetter__`。
- **所有权 / 错误 / 调用**：纯查表：`name` 是借用切片（只做 `std.mem.eql` 比较，不保留），不分配、无 error set，未命中返回 null 而不是错误。树内唯一调用点是 `src/exec/standard_globals.zig:3295` 的 comptime 断言——比对 `Object.prototype.toString` 描述符里的 `native_builtin_id` 与本表一致，也就是说它主要当作**两张表不许漂移**的编译期校验器；运行期的名字→id 解析走 `core.host_function` 里各域自己的 `prototypeMethodId`。

### `prototypeMethodOrdinal` (`src/exec/object_ops.zig:146`)

- **签名**：`pub fn prototypeMethodOrdinal(id: u32) ?i32`。
- **作用**：把原型方法 id 收成 1..10 的旧 ordinal，给无 realm 的 fallback。
- **实现**：switch；未知 `null`。
- **所有权 / 错误 / 调用**：`objectCall` 在没有 `func_obj`/global 时走 `call.objectPrototypeMethodCall`。

### `staticEntry` (`src/exec/object_ops.zig:162`)

- **签名**：`fn staticEntry(comptime name: []const u8, comptime length: u8, comptime method: StaticMethod) core.host_function.InternalEntry`。
- **作用**：静态方法表项。
- **实现**：`objectEntry(name, length, @intFromEnum(method))`。
- **所有权 / 错误 / 调用**：comptime，填 `internal_entries`。

### `prototypeEntry` (`src/exec/object_ops.zig:166`)

- **签名**：`fn prototypeEntry(comptime name: []const u8, comptime length: u8, comptime method: PrototypeMethod) core.host_function.InternalEntry`。
- **作用**：原型方法表项。
- **实现**：同上，id 来自 `PrototypeMethod`。
- **所有权 / 错误 / 调用**：comptime 构造，不分配：返回按值的 `InternalEntry`，`name` 指向编译期字符串字面量（静态存储），`native_function` 是 `objectCall` 的 `generic_magic` 包装（`src/exec/object_ops.zig:181`），全部是静态生命周期；无 error set。调用方是同文件的函数表字面量 `src/exec/object_ops.zig:232`-`:241` 共 9 项，以及 `prototypeExecDirectEntry`（`src/exec/object_ops.zig:176`）——后者先拿它建基础项再挂 `managed` 直通函数，`hasOwnProperty` 走的是那条。

### `prototypeExecDirectEntry` (`src/exec/object_ops.zig:170`)

- **签名**：`fn prototypeExecDirectEntry( comptime name: []const u8, comptime length: u8, comptime method: PrototypeMethod, comptime direct: core.native_entry.ManagedFn, ) core.host_function.InternalEntry`。
- **作用**：原型项外加 `managed` 直调函数（绕过 generic magic 热路径）。
- **实现**：`prototypeEntry` 后写 `entry.managed = direct`。
- **所有权 / 错误 / 调用**：仅 `hasOwnProperty` → `objectHasOwnPropertyDirect`。

### `objectEntry` (`src/exec/object_ops.zig:181`)

- **签名**：`fn objectEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：共享表项：generic_magic + `objectCall`。
- **实现**：`cproto = .generic_magic`，`native_function = genericMagicFunction(&objectCall)`，`magic = id`。
- **所有权 / 错误 / 调用**：静态与原型共用。

### `constructorEntry` (`src/exec/object_ops.zig:192`)

- **签名**：`fn constructorEntry() core.host_function.InternalEntry`。
- **作用**：`Object` 本身：constructor_or_func_magic。
- **实现**：`name = "Object"`，`length = 1`，`native_function = constructorOrFunctionMagic(&objectConstructorCall)`。
- **所有权 / 错误 / 调用**：自定义 new.target 在 VM 拦截后再进本 record。

### `objectConstructorCall` (`src/exec/object_ops.zig:247`)

- **签名**：`fn objectConstructorCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Object(...)` / `new Object(...)` 在无自定义 new.target 时的体。
- **实现**：`nativeCall` 失败 TypeError。有参且首参是对象 → 返回该对象。否则 `construct_mod.objectConstructorValue`。对照 `js_object_constructor`。
- **所有权 / 错误 / 调用**：返回 owned。nullish 变新对象由 `objectConstructorValue` 做。

### `objectCall` (`src/exec/object_ops.zig:265`)

- **签名**：`fn objectCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.object` 域共享 handler：有 realm 走 `objectCallForNativeRecord`，否则 fallback。
- **实现**：解 `host_call`。`func_obj != null` → `callableRealm`（debug 断言 realm==ctx）后 record。否则若 `host_call.global` 仍走 record。再否则原型 ordinal → `call.objectPrototypeMethodCall`；静态 → `call.callObjectStatic`。
- **所有权 / 错误 / 调用**：prebootstrap / 无 global 的合成调用走 call.zig。

### `objectCallForNativeRecord` (`src/exec/object_ops.zig:307`)

- **签名**：`fn objectCallForNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, id: u32, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：按 magic id 分发到本文件或 `object_ops` / `string_ops` / `call_runtime`。
- **实现**：巨大 switch。`!?JSValue` 的 `null` 收成 `error.TypeError`。`Object.is` 内联 `sameValue`。`toString`/`toLocaleString` → `string_ops`。`defineProperty`/`isExtensible`/`setPrototypeOf`/`keys`/`values`/`entries`/`defineProperties` 转 exec。
- **所有权 / 错误 / 调用**：未知 id TypeError。这是 Object 内建的唯一 realm 分发点。

### `literal` (`src/exec/object_ops.zig:361`)

- **签名**：`pub fn literal(rt: *core.JSRuntime, names: []const core.Atom, values: []const core.JSValue) !core.JSValue`。
- **作用**：`new_object` 字节码用的对象字面量：等长 name/value 定义到新对象。
- **实现**：长度不等 TypeError。`RootedValueCopies` + `ValueRootFrame`。`Object.create`；逐个 `defineOwnProperty` data W/E/C=true。单测验证 function bytecode 值在 GC 阈值 0 时仍活着。
- **所有权 / 错误 / 调用**：返回对象 owned。值在 define 期间由 root frame 钉住。

### `objectIsPrototypeOf` (`src/exec/object_ops.zig:431`)

- **签名**：`pub fn objectIsPrototypeOf( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Object.prototype.isPrototypeOf`。
- **实现**：无参 → false。`args[0]` 非对象 → false。`this` 非对象 TypeError。沿 `objectGetPrototypeOfStep` 走链（Proxy 可观察），命中 `this_object` → true。
- **所有权 / 错误 / 调用**：GetPrototypeOf trap 可抛。

### `objectValueOfCall` (`src/exec/object_ops.zig:450`)

- **签名**：`pub fn objectValueOfCall(rt: *core.JSRuntime, global: *core.Object, this_value: core.JSValue) !core.JSValue`。
- **作用**：`Object.prototype.valueOf`：ToObject。
- **实现**：nullish TypeError；已是对象原样返回；否则 `primitiveObjectForAccess`。
- **所有权 / 错误 / 调用**：装箱对象 owned。

### `objectCreateCall` (`src/exec/object_ops.zig:456`)

- **签名**：`pub fn objectCreateCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.create(proto, properties?)`。
- **实现**：无参 TypeError。proto 为 null → 无原型；否则必须是对象，否则 `"not a prototype"`。`Object.create`；第二参非 undefined 则 `definePropertiesOnTarget`。
- **所有权 / 错误 / 调用**：失败 `errdefer` destroy。返回实例。

### `objectAssignCall` (`src/exec/object_ops.zig:477`)

- **签名**：`pub fn objectAssignCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.assign(target, ...sources)`。
- **实现**：无参 TypeError；target nullish → 带消息 TypeError。非对象则装箱。每个 source：nullish 跳过；否则 ToObject，`objectRestOwnKeys`。普通源走 `objectAssignEnumOnly`（qjs `JS_GPN_ENUM_ONLY` 单次走查，`quickjs.c:40654→16920`）；Proxy/exotic 走 `objectAssignKeys`（每键 gopd trap）。
- **所有权 / 错误 / 调用**：返回 target。keys 切片 `freeKeys`。

### `assignSourceIsOrdinary` (`src/exec/object_ops.zig:525`)

- **签名**：`fn assignSourceIsOrdinary(source: *core.Object) bool`。
- **作用**：源能否保持 ENUM_ONLY（enumerable 直接读 shape）。
- **实现**：有 proxy target / exotic / `module_ns` / TypedArray → 假。对照 qjs `!p->is_exotic || !em->get_own_property_names`（`quickjs.c:16920-16927`）。
- **所有权 / 错误 / 调用**：假则走描述符路径，trap 顺序与 qjs ~ENUM_ONLY 分支一致。

### `objectAssignEnumOnly` (`src/exec/object_ops.zig:548`)

- **签名**：`fn objectAssignEnumOnly( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_value: core.JSValue, source_value: core.JSValue, source: *core.Object, own_keys: []const core.Atom, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !void`。
- **作用**：普通源的 CopyDataProperties：先快照 enumerable，再 Get+Set，**不再** 每键复查。
- **实现**：分配 `[]bool` 快照 `ownPropertyEnumerable`。对仍为真的键 `getValueProperty` 然后 `setValuePropertyStrict`。快照是 load-bearing：前面键的 getter 可能改后面键的可枚举性，qjs 仍拷贝因为键已在 ENUM_ONLY 列表里。这与 `Object.keys` 每键复查不同（`quickjs.c:40400`）。
- **所有权 / 错误 / 调用**：快照缓冲 defer free。

### `objectAssignKeys` (`src/exec/object_ops.zig:575`)

- **签名**：`pub fn objectAssignKeys( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target_value: core.JSValue, source_value: core.JSValue, source: *core.Object, own_keys: []const core.Atom, symbol_pass: ?bool, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !void`。
- **作用**：exotic/Proxy 源：每键 gopd，只拷 enumerable。
- **实现**：可选 `symbol_pass` 过滤。`objectRestOwnPropertyDescriptor` miss 跳过；`enumerable != true` 跳过；否则 Get+严格 Set。
- **所有权 / 错误 / 调用**：`symbol_pass = null` 表示一次遍历全部键（assign 用）。

### `objectHasOwnCall` (`src/exec/object_ops.zig:599`)

- **签名**：`pub fn objectHasOwnCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.hasOwn(O, P)`。
- **实现**：无参 `null`；O nullish TypeError；ToObject；ToPropertyKey；`proxyAwareExistsOwnProperty`（qjs `JS_GetOwnPropertyInternal(ctx, NULL, p, atom)`，`quickjs.c:8854`：不建描述符、不 dup、推迟 auto-init；Proxy 仍走完整 gopd trap）。
- **所有权 / 错误 / 调用**：返回布尔。

### `objectHasOwnPropertyDirect` (`src/exec/object_ops.zig:629`)

- **签名**：`fn objectHasOwnPropertyDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`Object.prototype.hasOwnProperty` 的 exec-direct 热腿。
- **实现**：`this` 已是对象且首参 `propertyKeyAtomIfReady` 有 atom → 同一 `proxyAwareExistsOwnProperty`（含 TypedArray/Proxy）。否则 `objectHasOwnPropertyHost`。错误经 `hostErrorToValue`。
- **所有权 / 错误 / 调用**：挂在 `internal_entries[].managed`。不跑 ToPropertyKey intern。

### `objectHasOwnPropertyHost` (`src/exec/object_ops.zig:665`)

- **签名**：`fn objectHasOwnPropertyHost( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：direct 失败后的完整 `hasOwnProperty`。
- **实现**：转 `objectPrototypeOwnPropertyCall`，id 为 `has_own_property`；`null` → TypeError。
- **所有权 / 错误 / 调用**：装箱、ToPropertyKey、nullish this。

### `objectPrototypeOwnPropertyCall` (`src/exec/object_ops.zig:698`)

- **签名**：`pub fn objectPrototypeOwnPropertyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`hasOwnProperty` 与 `propertyIsEnumerable` 共用。
- **实现**：其它 id → `null`。ToPropertyKey；this nullish TypeError；ToObject。hasOwnProperty → `proxyAwareExistsOwnProperty`；propertyIsEnumerable → 完整描述符的 `enumerable` 位，没有描述符则 false。
- **所有权 / 错误 / 调用**：enumerable 必须物化描述符（qjs `js_object_propertyIsEnumerable`）。

### `objectPrototypeDefineAccessorCall` (`src/exec/object_ops.zig:729`)

- **签名**：`pub fn objectPrototypeDefineAccessorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, getter: bool, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`__defineGetter__` / `__defineSetter__`。
- **实现**：this nullish TypeError；ToObject；accessor 必须可调用；ToPropertyKey。描述符 kind=accessor，E/C=true，只填 getter 或 setter。Proxy → `proxyDefineOwnProperty`；否则 `defineOwnProperty`。不兼容/不可扩展/只读 → TypeError；InvalidLength → RangeError；`defined == false` TypeError。返回 undefined。
- **所有权 / 错误 / 调用**：Annex B。

### `objectPrototypeLookupAccessorCall` (`src/exec/object_ops.zig:778`)

- **签名**：`pub fn objectPrototypeLookupAccessorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, getter: bool, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`__lookupGetter__` / `__lookupSetter__`：沿原型链找第一个 accessor。
- **实现**：ToObject + ToPropertyKey。循环 `objectRestOwnPropertyDescriptor`：命中非 accessor → undefined；accessor 返回 get 或 set（未 present 则 undefined）。miss 则 `objectGetPrototypeOfStep`。
- **所有权 / 错误 / 调用**：Proxy 每层 gopd/getPrototypeOf 可观察。

### `objectFromEntriesCall` (`src/exec/object_ops.zig:805`)

- **签名**：`pub fn objectFromEntriesCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.fromEntries(iterable)`。
- **实现**：无参 TypeError。新对象以 `%Object.prototype%` 为原型。`iteratorForValue`。每步：非对象 entry 则 close+TypeError；读 `0`/`1`、ToPropertyKey、`createDataPropertyOrThrow`；任一步失败 close iterator。
- **所有权 / 错误 / 调用**：`IteratorClose` 在 abrupt 路径。

### `objectGroupByCall` (`src/exec/object_ops.zig:847`)

- **签名**：`pub fn objectGroupByCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.groupBy(items, callback)`。
- **实现**：需要 callback 且可调用。新对象 **无原型**（null proto，spec）。迭代；index ≥ MAX_SAFE_INTEGER close+TypeError。`CallSite` 调 callback`(value, index)`；ToPropertyKey；`appendObjectGroupByValue`。
- **所有权 / 错误 / 调用**：callback 抛错要 close iterator。

### `objectAddEntriesStepValue` (`src/exec/object_ops.zig:901`)

- **签名**：`fn objectAddEntriesStepValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !ObjectIteratorStepValue`。
- **作用**：IteratorStep 的值级实现：调 `next`，读 `done`/`value`。
- **实现**：iterator 必须是对象。`cachedIteratorNext` 或 Get `next`。不可调用 TypeError。`callValueOrBytecodeRoot`。结果对象读 `done`；真则 `{ undefined, done: true }`。读 `value` 失败则 close。不按 class 分发。
- **所有权 / 错误 / 调用**：fromEntries / groupBy 共用。

### `objectSetIntegrityCall` (`src/exec/object_ops.zig:933`)

- **签名**：`pub fn objectSetIntegrityCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, level: IntegrityLevel, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.seal` / `Object.freeze`。
- **实现**：非对象原样返回。freeze + TypedArray 背后是可调整 buffer → TypeError。先 `objectPreventExtensionsCall`。ownKeys；sealed 只把 configurable=false；frozen 对 data 再 writable=false。Proxy 走 `proxyDefineOwnProperty`。
- **所有权 / 错误 / 调用**：返回原 target。

### `objectTestIntegrityCall` (`src/exec/object_ops.zig:984`)

- **签名**：`pub fn objectTestIntegrityCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, level: IntegrityLevel, ) !?core.JSValue`。
- **作用**：`isSealed` / `isFrozen`。
- **实现**：非对象 → true。qjs `js_object_isSealed`（`quickjs.c:40717`）**先** walk ownKeys+gopd（可配置/可写立刻 false），**最后** 才 IsExtensible——与 spec TestIntegrityLevel 顺序相反，zjs 跟 qjs。
- **所有权 / 错误 / 调用**：`objectIsExtensibleForIntegrity`。

### `objectIsExtensibleForIntegrity` (`src/exec/object_ops.zig:1007`)

- **签名**：`pub fn objectIsExtensibleForIntegrity( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, ) !bool`。
- **作用**：完整性测试用的 IsExtensible，Proxy 走 trap + invariant。
- **实现**：无 proxy → `object.isExtensible()`。否则 Get handler.isExtensible；缺 trap 用 target 标志；调用后必须与 target.isExtensible() 一致否则 TypeError。
- **所有权 / 错误 / 调用**：这里 **不** 递归 `proxyAwareIsExtensible`（与 qjs 测完整性时的 trap 集合对齐）。

### `appendObjectGroupByValue` (`src/exec/object_ops.zig:1027`)

- **签名**：`pub fn appendObjectGroupByValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, out_value: core.JSValue, out: *core.Object, key: core.Atom, value: core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !void`。
- **作用**：把 value 推进 `out[key]` 数组；没有则新建数组并 CreateDataPropertyOrThrow。
- **实现**：Get 失败当 undefined。undefined → `createArray` + 定义到 out。再把 value 定义到 `arrayLength()` 下标。单测：out 不可扩展时 TypeError，且半成品 group 只释放一次。
- **所有权 / 错误 / 调用**：define 失败由调用方/err 路径回收。

### `objectPreventExtensionsCall` (`src/exec/object_ops.zig:1080`)

- **签名**：`pub fn objectPreventExtensionsCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.preventExtensions`。
- **实现**：非对象原样返回。Proxy → `proxyAwarePreventExtensions`，假则 TypeError。否则 `object.preventExtensions()`。返回 target。
- **所有权 / 错误 / 调用**：不抛的失败只出现在 Proxy trap 返回假。

### `getOwnPropertyDescriptorCall` (`src/exec/object_ops.zig:1098`)

- **签名**：`pub fn getOwnPropertyDescriptorCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.getOwnPropertyDescriptor`。
- **实现**：无参 `null`；nullish TypeError；ToObject；ToPropertyKey；`proxyAwareOwnPropertyDescriptor`；mapped arguments 再 `materializeMappedArgumentsDescriptorValueForVm`；`descriptorObjectFromDescriptor`。没有描述符 → undefined。
- **所有权 / 错误 / 调用**：返回描述符对象或 undefined。

### `objectGetPrototypeOfCall` (`src/exec/object_ops.zig:1118`)

- **签名**：`pub fn objectGetPrototypeOfCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.getPrototypeOf`。
- **实现**：无参 `null`；nullish `"not an object"`；ToObject。若对象是 `Object.prototype.isPrototypeOf` 那条 native record（C 函数），返回 `%Function.prototype%`（历史：把该方法当函数原型查询）。否则 `objectGetPrototypeOfValue`。
- **所有权 / 错误 / 调用**：`objectPrototypeMethodFunctionPrototype` 是窄特判。

### `objectPrototypeMethodFunctionPrototype` (`src/exec/object_ops.zig:1134`)

- **签名**：`pub fn objectPrototypeMethodFunctionPrototype( ctx: *core.JSContext, global: *core.Object, object: *core.Object, ) !?*core.Object`。
- **作用**：识别「这是 Object.prototype 上的 isPrototypeOf native」并给出 Function.prototype。
- **实现**：须 `c_function` 且 `isObjectPrototypeNativeRecord(..., is_prototype_of)`。
- **所有权 / 错误 / 调用**：给 GetPrototypeOf 的兼容臂。

### `isObjectPrototypeNativeRecord` (`src/exec/object_ops.zig:1144`)

- **签名**：`pub fn isObjectPrototypeNativeRecord(object: *core.Object, id: u32) bool`。
- **作用**：native builtin id 是否为 `.object` 域的给定方法。
- **实现**：`decodeNativeBuiltinId`；domain==object 且 id 匹配。
- **所有权 / 错误 / 调用**：只读 `object.nativeFunctionId()` 解码，不分配、不建根、无 error set；`object` 是借用指针，非原生函数或跨域一律 false（保守方向：只会放弃快路径）。调用方 `src/exec/object_ops.zig:1189`，用来确认拿到的确实是内建的 `Object.prototype.isPrototypeOf` 而不是被覆写过的同名函数，之后才敢返回 realm 的 Function.prototype 走快路径。

### `getOwnPropertyDescriptorsCall` (`src/exec/object_ops.zig:1149`)

- **签名**：`pub fn getOwnPropertyDescriptorsCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Object.getOwnPropertyDescriptors`。
- **实现**：ToObject；ownKeys；新对象挂 Object.prototype；每键 gopd，mapped args 物化 value，`descriptorObjectFromDescriptor`，CreateDataPropertyOrThrow 到结果对象。
- **所有权 / 错误 / 调用**：缺描述符的键跳过。

### `objectOwnPropertyKeysCall` (`src/exec/object_ops.zig:1185`)

- **签名**：`pub inline fn objectOwnPropertyKeysCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, filter: OwnPropertyKeyFilter, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`getOwnPropertyNames` / `getOwnPropertySymbols`。
- **实现**：转 `objectEnumerableOwnPropertiesCall`，kind 为 `.own_names` / `.own_symbols`，nullish 错误为 `.bare`。不复查 enumerable。
- **所有权 / 错误 / 调用**：与 keys/values/entries 共用 outlined 走查，避免第二份拷贝。

## 覆盖核对

- 清单函数数: 41
- 本文标题覆盖: 41
- 未覆盖: 无
