# 17 — 集合与 Reflect/Proxy

Map/Set 热路径校验 `collection_method_owner_class`。Reflect.construct 对内建构造器走同一张 `callConstructRecord` 表。Proxy.revocable 的 revoke 是 `.reflect` domain 的一条记录。



## `src/exec/collection_ops.zig` — Map/Set/WeakMap/WeakSet

强集合复制 key/value；弱表只留身份。`collectionCall`：construct id → `constructWithPrototype`；`groupBy` 不读 receiver（可拆下来当函数用）；无 func_obj 的算法复用走 primitive `methodCall*`；有函数对象则 `collectionNativeRecord`（校验 owner class）。

`sameValueZero` 是 `JSValue.sameValueZero` 的薄封装。Set 代数方法经 `GetSetRecord` 读 size/has/keys。


### `constructorKindFromId` (`src/exec/collection_ops.zig:64`)

- **签名**：`fn constructorKindFromId(id: u32) ?u32`。
- **作用**：把 construct 记录 id 反查成 `ConstructorKind` 的数值，供构造记录处理函数用。
- **实现**：`switch (id)` 把 `ConstructorMethod.construct_map` / `construct_set` / `construct_weak_map` / `construct_weak_set` 映成 `ConstructorKind` 的 map=1 / set=2 / weak_map=3 / weak_set=4，其余 id 返回 null（表示这条记录不是集合构造器）。
- **所有权 / 错误 / 调用**：纯映射；唯一调用方是 `collectionCall` 的第一级分派。

### `staticMethodId` (`src/exec/collection_ops.zig:74`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：把安装期看到的 JS 静态方法名映射到 `.collection` domain 的记录 id。
- **实现**：只认 `"groupBy"`，返回 `StaticMethod.group_by`（本文件里显式定成 101，避开原型方法 id 段）；其它名字返回 null。
- **所有权 / 错误 / 调用**：纯映射；由标准全局 bootstrap 在安装 `Map.groupBy` 时调用。

### `collectionEntry` (`src/exec/collection_ops.zig:139`)

- **签名**：`fn collectionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：构造一条非构造器的 `.collection` 记录。
- **实现**：`.magic = @intCast(id)`（id 兼作 magic），`.cproto = .generic_magic`，`.native_function = builtin_dispatch.genericMagicFunction(&collectionCall)`；`internal_entries` 里 21 条原型方法（含 `"get size"` 与迭代器 `"next"`）和 `"groupBy"` 静态都由它生成。
- **所有权 / 错误 / 调用**：comptime 求值，无运行期所有权。

### `collectionConstructorEntry` (`src/exec/collection_ops.zig:153`)

- **签名**：`fn collectionConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：构造 Map / Set / WeakMap / WeakSet 四条可构造记录。
- **实现**：与 `collectionEntry` 同形，区别是 `.cproto = .constructor_magic` 且 `.native_function = builtin_dispatch.constructorMagic(&collectionCall)`，于是 `new Map(...)` 等能走到 `collectionCall` 的构造臂。四条记录的 `length` 都是 0，且构造器对象本身不带 native id（按名字解析），只能通过显式 ref 的 `callConstructRecord` 到达。
- **所有权 / 错误 / 调用**：comptime 求值，无运行期所有权。

### `collectionCall` (`src/exec/collection_ops.zig:170`)

- **签名**：`fn collectionCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：该 domain 的唯一记录处理函数：从 `nativeCall` 恢复执行环境后按 magic/id 转发到构造、静态或原型方法实现。
- **实现**：先 `builtin_dispatch.nativeCall` 恢复 `NativeCall`，失败 → `error.TypeError`。`observable = host_call.func_obj != null`：可观察调用取 `callableRealm`（断言 `realm.realm == ctx`）的 global 作为 realm 权威，并把 legacy `globals` 置成空切片（legacy 槽只属于无函数对象的算法复用）；不可观察时用 `host_call.global` 与 `host_call.globals`。随后分四路：① `constructorKindFromId(id)` 命中 → `constructWithPrototype(ctx.runtime, kind, host_call.new_target)`，用可迭代实参填充（adder 协议）由 VM 的 construct site 在对象建好之后驱动；② `id == StaticMethod.group_by` → `collectionGroupByRecord`；③ 没有 `func_obj`（`Array.from` / typed-array 工厂抽 Map/Set 迭代器、构造器 adder 填充、直接 opcode 路径这类引擎内部调用点）→ 有 `host_call.global` 时先把 this 转成 receiver 对象（不是对象 → TypeError），若 `collectionCallResultIsDropped` 成立就先试 `methodCallDroppedResult`（成功返回 undefined），否则 `methodCallObjectWithGlobal`；完全没有 global 时走 `methodCallWithCallbackHost(..., collection_adapter.host(ctx, globals))` 的裸原始实现；④ 有 `func_obj` → `callable_global` 为空则 `error.InvalidBuiltinRegistry`，否则 `collectionNativeRecord`，它返回 null（未知 id）时折成 `error.TypeError`。
- **所有权 / 错误 / 调用**：不分配；失败走 `HostError`，已挂 pending exception 时上层收成 `error.JSException`。由 `internal_entries` 的全部 26 条记录共享。

### `collectionGroupByRecord` (`src/exec/collection_ops.zig:232`)

- **签名**：`fn collectionGroupByRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, globals: []globals_mod.Slot, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：`Map.groupBy` 静态记录的入口，按有没有 realm global 选实现。
- **实现**：有 global → `mapGroupByCall`，返回 null 折成 `error.TypeError`。没有 global 的裸运行时路径：若 `this_value` 是对象，尝试 `object_ops.constructorPrototypeObject` 从构造器 receiver 推出结果原型（失败按 null，defer deinit），然后 `groupByWithCallbackHost(ctx.runtime, args, prototype_object, collection_adapter.host(ctx, globals))`，错误 switch 只把 `error.TypeError` 原样透出、其余原样上抛。两条路径都**不要求** receiver：镜像 `js_object_groupBy`（quickjs.c:52343，与 `Object.groupBy` 共享的 is_map=1 入口）——qjs 用 `JS_UNDEFINED` 的 this 走 `js_map_constructor`，所以 `const g = Map.groupBy; g(items, fn)` 这种解绑调用照样工作。
- **所有权 / 错误 / 调用**：`OwnedPrototype` 在函数内 defer 释放；返回的 Map 归调用方；调用方是 `collectionCall`。

### `sameValueZero` (`src/exec/collection_ops.zig:270`)

- **签名**：`pub fn sameValueZero(a: core.JSValue, b: core.JSValue) bool`。
- **作用**：SameValueZero 比较的薄 shim。
- **实现**：直接 `return a.sameValueZero(b)`；真正实现已搬到 `core/value.zig`（挨着 `JSValue.sameValue`），这里保留自由函数拼写，好让 Map/Set 键查找与安装路径的老调用点不用改。
- **所有权 / 错误 / 调用**：纯比较，不分配、不抛错。

### `construct` (`src/exec/collection_ops.zig:282`)

- **签名**：`pub fn construct(realm: *core.RealmContext, kind: u32) !core.JSValue`。
- **作用**：过渡期 `new_collection` 字节码用的窄构造器：建一个无原型的集合对象，并把方法作为自有属性挂上去。
- **实现**：`constructWithPrototype(realm.runtime, kind, null)` 建对象（原型为 null），`expectObject` 取出，再 `defineNativeMethods(realm, object, object.class_id)`。因为这个兼容对象没有原型，方法必须是自有的 C-function 属性，所以构造 realm 要显式传进来。
- **所有权 / 错误 / 调用**：返回值归调用方；方法函数对象由 `defineNativeMethods` 挂到对象上。

### `constructBare` (`src/exec/collection_ops.zig:291`)

- **签名**：`pub fn constructBare(rt: *core.JSRuntime, kind: u32) !core.JSValue`。
- **作用**：只带 payload 的 fixture / 算法用构造器。
- **实现**：直接 `constructWithPrototype(rt, kind, null)`，不发布任何可调用属性——调用方改用 `methodCall` 直接驱动方法体。
- **所有权 / 错误 / 调用**：返回的是刚 `core.Object.create` 出来的 GC 对象，没有引用计数义务，但也没有建根——调用方必须在下一次可能触发回收的操作前把它放进自己的根（`constructWithPrototype` 只用 `errdefer core.Object.destroyFromHeader` 兜住发布前的失败）。error 来自 `collectionClassId` 的 `error.TypeError`（kind 非法）与 `Object.create` 的 OOM。调用方 `src/exec/collection_ops.zig:813` 与 `src/tests/builtins.zig` 的多处 fixture。

### `constructWithPrototype` (`src/exec/collection_ops.zig:295`)

- **签名**：`pub fn constructWithPrototype(rt: *core.JSRuntime, kind: u32, prototype: ?*core.Object) !core.JSValue`。
- **作用**：所有集合构造路径的底座：按 kind 建一个带指定原型的空集合对象。
- **实现**：`collectionClassId(kind)` 把 1/2/3/4 映成 map/set/weakmap/weakset class（未知 kind → `error.TypeError`），`core.Object.create(rt, class_id, prototype)` 建对象并挂 `errdefer core.Object.destroyFromHeader`，返回 `object.value()`。
- **所有权 / 错误 / 调用**：返回值归调用方；`construct`（:283）/ `constructBare`（:292）/ `collectionCall` 构造臂（:199）/ `groupByWithCallbackHost`（:505）/ `setComposition`（:1049）/ `constructPlainSet`（:1824）/ `mapGroupByRecord`（:2162）都经它。

### `methodCall` (`src/exec/collection_ops.zig:306`)

- **签名**：`pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：不带任何回调能力的最裸集合方法调用入口。
- **实现**：转发 `methodCallWithCallbackHost(rt, object_value, method, args, .{})`。空 `CallbackHost` 的 `call` 与 `ctx` 都是 null，所以一旦方法体真要回调用户函数（forEach、getOrInsertComputed、面向 set-like 的代数方法）就会得到 `error.TypeError`；它只用于 set/get/has/delete/add 这类纯存储操作。
- **所有权 / 错误 / 调用**：返回值归调用方；本文件的 `setAddValue` / `setDeleteValue` / `setHasValue` / `mapGetOrInsertComputedCall` / `mapAppendGroupByValue` 都用它操作自己刚建的 Set/Map。

### `methodCallWithCallbackHost` (`src/exec/collection_ops.zig:310`)

- **签名**：`pub fn methodCallWithCallbackHost( rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：无 `JSContext` 的集合方法入口，回调能力由传入的 `CallbackHost` 提供。
- **实现**：`expectObject` 把 receiver 值转成对象，再 `methodCallResolved(rt, null, globalObjectFromGlobals(host.globals), object, method, args, host)`——ctx 传 null，global 只能从 legacy `globals` 槽里的 `globalThis` 反推。
- **所有权 / 错误 / 调用**：返回值归调用方；`collectionCall` 的无 global 分支与 `core` 侧集合算法复用点用它。

### `methodCallWithContextAndHost` (`src/exec/collection_ops.zig:321`)

- **签名**：`pub fn methodCallWithContextAndHost( ctx: *core.JSContext, object_value: core.JSValue, method: u32, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：带 `JSContext` 的 primitive 方法调用（原先还有一个只传 `globals` 的薄壳 `methodCallWithContext`，仅单测在用，已删）。
- **实现**：`expectObject` 后 `methodCallResolved(ctx.runtime, ctx, globalObjectFromGlobals(host.globals), object, method, args, host)`：ctx 已知，global 仍从 legacy 槽推。
- **所有权 / 错误 / 调用**：不分配；`expectObject` 失败返回 `error.TypeError`，其余 error 由 `methodCallResolved` 及其调用的具体方法产生。receiver 的根由 `methodCallResolved`（`rootObjects`/`activate`）负责，本层不建根。树内调用方是 `src/tests/core.zig` 的 realm 选择单测。

### `methodCallWithGlobalAndHost` (`src/exec/collection_ops.zig:332`)

- **签名**：`pub fn methodCallWithGlobalAndHost( ctx: *core.JSContext, global: *core.Object, object_value: core.JSValue, method: u32, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：显式给定 global 的 primitive 方法调用（原先还有一个只传 `globals` 的薄壳 `methodCallWithGlobal`，仅单测在用，已删）。
- **实现**：`expectObject` 后 `methodCallResolved(ctx.runtime, ctx, global, object, method, args, host)`——ctx 与 global 都是直接给的，不再反推。
- **所有权 / 错误 / 调用**：不分配；`expectObject` 失败返回 `error.TypeError`。receiver 的根同样由 `methodCallResolved` 建，本层只做解包。树内调用方是 `src/tests/core.zig` 的 realm 选择单测。

### `methodCallObjectWithGlobal` (`src/exec/collection_ops.zig:344`)

- **签名**：`pub fn methodCallObjectWithGlobal( ctx: *core.JSContext, global: *core.Object, object: *core.Object, method: u32, args: []const core.JSValue, globals: []globals_mod.Slot, ) !core.JSValue`。
- **作用**：receiver 已经解析成 `*core.Object` 时的方法入口（记录分派的主用形态）。
- **实现**：转发 `methodCallObjectWithGlobalAndHost`，host 只带 `.globals`。
- **所有权 / 错误 / 调用**：返回值归调用方；`collectionCall` 的无 func_obj + 有 global 分支（:223，传 `host_call.globals`）与 `collectionNativeRecord` 的存储类方法臂（:1627/:1649，传空切片 `&.{}`）都走它。

### `methodCallObjectWithGlobalAndHost` (`src/exec/collection_ops.zig:355`)

- **签名**：`pub fn methodCallObjectWithGlobalAndHost( ctx: *core.JSContext, global: *core.Object, object: *core.Object, method: u32, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：上面一族入口的终点形态：ctx、global、receiver 对象、host 全部显式。
- **实现**：直接 `methodCallResolved(ctx.runtime, ctx, global, object, method, args, host)`，省掉 `expectObject` 这一步。
- **所有权 / 错误 / 调用**：纯转发：不分配、不建根、不产生自己的 error（连 `expectObject` 的 `error.TypeError` 都没有，因为 receiver 已是 `*core.Object`）。树内唯一调用方是 `methodCallObjectWithGlobal`（`src/exec/collection_ops.zig:373`）。

### `methodCallResolved` (`src/exec/collection_ops.zig:366`)

- **签名**：`fn methodCallResolved( rt: *core.JSRuntime, ctx: ?*core.JSContext, global: ?*core.Object, object: *core.Object, method: u32, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：集合方法的编号分派表：把 `method` 数值转到具体的 primitive 实现。
- **实现**：先用 `core.runtime.rootObjects(.{&receiver})` 把 receiver 钉成根并 activate / defer deactivate——集合方法不走 builtin dispatch 漏斗，插入途中触发的 minor 否则可能回收正在遍历的集合本身。然后 `switch (method)`：1 `mapSet`、2 `mapGet`、3 `collectionHas`、4 `collectionDelete`、5 `collectionClear`、6 `setAdd`、7/8/9 `collectionIterator` 的 `.key`/`.value`/`.key_value`、10 `collectionForEach`、11 `mapGetOrInsert`、12 `mapGetOrInsertComputed`（唯一要求实参 ≥ 2，否则 `error.TypeError`）、13 `collectionIteratorNext`、14 `collectionSize`、15/16/20/21 `setComposition` 的 difference/intersection/symmetric_difference/union_、17/18/19 `setComparison` 的 is_disjoint_from/is_subset_of/is_superset_of；未知编号 `error.TypeError`。缺失的实参统一补 `undefined`。
- **所有权 / 错误 / 调用**：根帧在函数内 defer 撤销；返回值归调用方。

### `methodCallDroppedResult` (`src/exec/collection_ops.zig:444`)

- **签名**：`pub fn methodCallDroppedResult(rt: *core.JSRuntime, object: *core.Object, method: u32, args: []const core.JSValue) !bool`。
- **作用**：调用点丢弃返回值时的快路径：跳过「返回 this / 返回布尔」的结果构造。
- **实现**：只认三个 id——`PrototypeMethod.set` → `mapSetNoResult`、`add` → `setAddNoResult`、`delete` → `collectionDeleteNoResult`，处理完返回 true；其它方法返回 false，让调用方回到常规分派。缺参补 `undefined`。它不经过 `methodCallResolved`，因此没有那里的 receiver 根登记，也不做 owner class 校验（调用方已经校验过）。
- **所有权 / 错误 / 调用**：`error.TypeError`（例如 WeakMap 收到不能弱持有的键）由调用方 `collectionNativeRecord` 转成带消息的异常；调用方是 `collectionCall` 与 `collectionNativeRecord`。

### `groupBy` (`src/exec/collection_ops.zig:466`)

- **签名**：`pub fn groupBy( ctx: *core.JSContext, args: []const core.JSValue, globals: []globals_mod.Slot, prototype: ?*core.Object, ) !core.JSValue`。
- **作用**：带 ctx 的 groupBy 便利入口。
- **实现**：直接转发 `groupByWithCallbackHost(ctx.runtime, args, prototype, collection_adapter.host(ctx, globals))`，即把回调能力接到 exec 的闭包调用上。
- **所有权 / 错误 / 调用**：返回的 Map 归调用方。

### `groupByWithCallbackHost` (`src/exec/collection_ops.zig:475`)

- **签名**：`pub fn groupByWithCallbackHost( rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object, host: CallbackHost, ) !core.JSValue`。
- **作用**：裸运行时版本的 `Map.groupBy`：只支持字符串与数组来源。
- **实现**：实参少于 2 个、或 `args[1]` 不是 `isCallableObject` → `error.TypeError`；`constructWithPrototype(rt, 1, prototype)` 建结果 Map。`args[0]` 是字符串时交 `groupString` 按「字符串元素」分组并返回；否则必须是对象且 `isArray()`（不是数组 → `error.TypeError`），按 `arrayLength()` 逐下标 `getProperty` 取元素并 `addGroupedItem`。注意它不走通用 iterator 协议——那是 VM 路径 `mapGroupByRecord` 的职责。
- **所有权 / 错误 / 调用**：结果 Map 归调用方；回调通过 `host` 发出。

### `mapSet` (`src/exec/collection_ops.zig:502`)

- **签名**：`fn mapSet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue`。
- **作用**：`Map.prototype.set` / `WeakMap.prototype.set` 的返回值形态。
- **实现**：调 `mapSetNoResult` 完成写入，再返回 `object.value()`（规范要求返回 this）。
- **所有权 / 错误 / 调用**：返回的是 receiver 自身的值。

### `mapSetNoResult` (`src/exec/collection_ops.zig:507`)

- **签名**：`fn mapSetNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void`。
- **作用**：Map / WeakMap 写入的真正实现。
- **实现**：`weakmap` 分支先 `weakKeyIdentityRegister` 注册键身份，返回 null（键不能被弱持有）→ `error.TypeError`，然后 `setWeakMapEntryByIdentityChecked`。否则 class 必须是 `map`，不是就 `error.TypeError`；`canonicalizeKey` 把 -0 归一成 +0；`findStrongEntry` 命中时直接改写 payload 里的 `entry.value`，并显式补一次 `rt.gc.generationalBarrier(object.gcHeader(), next_value.cycleMarkHeader())`——覆盖写落在 entry 切片上，没有任何属性写屏障覆盖；未命中则 `appendStrongEntryOwned` 追加新 `CollectionEntry`。
- **所有权 / 错误 / 调用**：强集合持有 key/value 的引用；弱表只留身份。

### `mapGet` (`src/exec/collection_ops.zig:537`)

- **签名**：`fn mapGet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue`。
- **作用**：Map / WeakMap 的取值。
- **实现**：`weakmap` 分支用 `weakKeyIdentityPeek`（只查不注册），没有身份或没有命中条目都返回 `undefined`，命中则读 `weakCollectionEntriesSlot` 里的 value。否则 class 必须是 `map`；`findStrongEntry` 未命中返回 `undefined`，命中返回 `collectionEntriesSlot` 里的 value。
- **所有权 / 错误 / 调用**：返回的是集合里存着的值，不额外分配。

### `iteratorRealm` (`src/exec/collection_ops.zig:572`)

- **签名**：`fn iteratorRealm( rt: *core.JSRuntime, current_context: ?*core.JSContext, explicit_global: ?*core.Object, ) !IteratorRealm`。
- **作用**：为集合迭代器定位 realm（context + global）。
- **实现**：给了 `explicit_global` 就用 `rt.contextForGlobalIncludingConstructing(global)` 反查 context（查不到 → `error.InvalidBuiltinRegistry`）；否则用 `current_context` 以及它的 `context.global`，任一为 null 都是 `error.InvalidBuiltinRegistry`。
- **所有权 / 错误 / 调用**：返回的 `IteratorRealm` 只是借用指针；调用方是 `collectionIterator`。

### `collectionIterator` (`src/exec/collection_ops.zig:586`)

- **签名**：`fn collectionIterator( rt: *core.JSRuntime, ctx: ?*core.JSContext, global: ?*core.Object, object: *core.Object, kind: CollectionIteratorKind, ) !core.JSValue`。
- **作用**：`keys` / `values` / `entries` 的共同实现：建一个 Map/Set 迭代器对象。
- **实现**：receiver 是 `map` 取 `map_iterator` class、是 `set` 取 `set_iterator`，其它 class → `error.TypeError`；把 target value 用 `rootValues` 钉住跨分配窗口；`iteratorRealm` 解析 realm 后 `iteratorPrototype` 取（或懒建）`"Map Iterator"` / `"Set Iterator"` 原型；`core.Object.create` 建迭代器（errdefer 销毁），写 `iteratorTargetSlot`、`iteratorIndexSlot = 0`、`iteratorKindSlot = kind`。新迭代器**不**持有 entry 数组游标——对应 qjs `js_map_iterator_new`（quickjs.c:52556）里 `cur_record == NULL`，游标要到第一次 advance 才取、耗尽或 payload 拆解时释放。
- **所有权 / 错误 / 调用**：迭代器归调用方；`CollectionIteratorKind` 是 `key = 1` / `value = 2` / `key_value = 3` 的 u8 枚举。

### `iteratorPrototype` (`src/exec/collection_ops.zig:624`)

- **签名**：`fn iteratorPrototype( rt: *core.JSRuntime, realm: *core.JSContext, global: *core.Object, iterator_class: core.ClassId, tag_name: []const u8, ) !IteratorPrototypeRef`。
- **作用**：取 realm 里缓存的迭代器原型，没有就懒建并缓存。
- **实现**：以 `iterator_class` 当下标查 `realm.class_prototypes`，槽里已是对象就直接返回 `.{ .object = ..., .owned = false }`。否则 `createIteratorPrototype` 新建；下标仍在范围内时写回槽位，并手动补一次 `rt.gc.generationalBarrier(&realm.header, prototype.gcHeader())`——这是原始槽写而不是 `setClassPrototype`（与 iterator_ops 里 Array 迭代器原型同一处理：懒建发生在 realm 变老之后，而 realm 在 create-ref 被消费后不再是根），返回 `owned = false`；下标越界时返回 `owned = true`，表示这个原型没人缓存。
- **所有权 / 错误 / 调用**：`IteratorPrototypeRef` 带 `object` 与 `owned` 两个字段；当前唯一调用方 `collectionIterator` 只取 `.object`。

### `createIteratorPrototype` (`src/exec/collection_ops.zig:651`)

- **签名**：`fn createIteratorPrototype( rt: *core.JSRuntime, global: *core.Object, iterator_class: core.ClassId, tag_name: []const u8, ) !*core.Object`。
- **作用**：现造一个 Map/Set 迭代器原型对象。
- **实现**：基座优先取 realm 的 `%IteratorPrototype%`（`iterator_ops.iteratorPrototypeFromGlobal`）；取不到就地造一个 fallback：以 `objectPrototypeFromGlobal` 为原型建对象、打上 `Symbol.toStringTag = "Iterator"`、建名为 `"[Symbol.iterator]"` 的 native 函数并 `addIteratorIdentityFunction`（失败 → `error.TypeError`），以 writable / non-enumerable / configurable 定义成 `Symbol.iterator`。然后以基座为原型建 specific 对象（errdefer 销毁），打上 `tag_name`，建 `"next"` 函数，把它的 `nativeFunctionIdSlot` 写成 `.collection` domain 的 `PrototypeMethod.iterator_next` 记录 id，再 `addCollectionMethodOwnerClass(rt, iterator_class)` 把它钉到具体迭代器 class 上——镜像 `js_map_iterator_next`（quickjs.c:52576）里 `JS_GetOpaque2(JS_CLASS_MAP_ITERATOR)` + magic 的效果：Map Iterator 的 next 拒绝 Set 迭代器，反之亦然。最后把 `next` 以 writable / non-enumerable / configurable 定义上去。
- **所有权 / 错误 / 调用**：fallback 基座在被 specific 对象接管后从 `owned_base` 里摘掉（不再走 errdefer 销毁）；返回的原型归调用方（通常立刻存进 realm 缓存）。

### `objectPrototypeFromGlobal` (`src/exec/collection_ops.zig:689`)

- **签名**：`fn objectPrototypeFromGlobal(global: *core.Object) ?*core.Object`。
- **作用**：从 realm global 上取 `Object.prototype`。
- **实现**：`predefinedId("Object", .string)` 取 atom，`global.getOwnDataObjectBorrowed` 拿到 `Object` 构造器，再取它的 `prototype`；任一步缺失返回 null。
- **所有权 / 错误 / 调用**：借用指针，不增引用；只被 `createIteratorPrototype` 的 fallback 分支使用。

### `globalObjectFromGlobals` (`src/exec/collection_ops.zig:695`)

- **签名**：`fn globalObjectFromGlobals(globals: []const globals_mod.Slot) ?*core.Object`。
- **作用**：从 legacy global 槽里反推 realm global 对象。
- **实现**：`globals_mod.getByAtom(globals, core.atom.ids.globalThis)` 取值，`expectObject` 转对象，失败返回 null。
- **所有权 / 错误 / 调用**：借用指针；被 `methodCallWithCallbackHost` 与 `methodCallWithContextAndHost` 使用。

### `defineToStringTag` (`src/exec/collection_ops.zig:702`)

- **签名**：`fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void`。
- **作用**：给迭代器原型打 `Symbol.toStringTag`。
- **实现**：`predefinedId("Symbol.toStringTag", .symbol)` 取不到 → `error.TypeError`；`core.string.String.createUtf8(rt, tag_name)` 造标签串，以 `Descriptor.data(value, false, false, true)`（non-writable / non-enumerable / configurable）定义。源码注明它是 `iterator_ops.defineToStringTag` 的本地镜像，要保持同步。
- **所有权 / 错误 / 调用**：字符串的引用随属性定义转移给对象。

### `collectionIteratorNext` (`src/exec/collection_ops.zig:708`)

- **签名**：`fn collectionIteratorNext(rt: *core.JSRuntime, global: ?*core.Object, iterator: *core.Object) !core.JSValue`。
- **作用**：Map/Set 迭代器的 `next`。
- **实现**：receiver class 必须是 `map_iterator` 或 `set_iterator`，否则 `error.TypeError`；`iteratorTargetSlot` 为空（已耗尽 / 已 detach）直接返回 `{ value: undefined, done: true }`。取到 target 后先 `retainCollectionIteratorCursor()` 把游标停住（对应 quickjs.c:52605 的 `mr->ref_count++`），再从 `iteratorIndexSlot` 开始扫 entry 数组：下标先自增再读，`!entry.active` 的条目跳过，命中就 `iteratorValue` 取值并包成 `done = false` 的结果；扫完则先建好 done 结果，再 `detachCollectionIteratorTarget(rt)` 释放游标与 target 槽。
- **所有权 / 错误 / 调用**：结果对象归调用方；`global` 为 null 时迭代结果对象拿不到 realm 原型，所以记录路径总是带 global 进来。

### `iteratorValue` (`src/exec/collection_ops.zig:727`)

- **签名**：`fn iteratorValue(rt: *core.JSRuntime, global: ?*core.Object, class_id: core.ClassId, entry: core.object.CollectionEntry, kind: CollectionIteratorKind) !core.JSValue`。
- **作用**：按迭代器 kind 把一条 entry 变成 `next` 要吐的值。
- **实现**：`.key` 直接给 `entry.key`；`.value` 对 Set 给 key、对 Map 给 `entry.value`；`.key_value` 先把 key / value 两个局部用 `rootValues` 钉住，再以 realm 的 `Array.prototype`（`global` 为 null 时无原型）`createArray` 建 pair（errdefer 销毁），把下标 0 / 1 以 `Descriptor.data(..., true, true, true)` 定义上去。pair 的原型取自 realm 而不是 null-proto，对应 qjs `js_create_array` → `JS_NewArray`（quickjs.c:9601、5841）。
- **所有权 / 错误 / 调用**：pair 归调用方；根帧在函数内 defer 撤销。

### `iteratorResult` (`src/exec/collection_ops.zig:752`)

- **签名**：`fn iteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue`。
- **作用**：本文件唯一的 `CreateIterResultObject` 出口。
- **实现**：转发 `iterator_ops.createIteratorResult(rt, global, value, done)`。
- **所有权 / 错误 / 调用**：按源码注释，调用方把 `value` 的引用交给它；结果对象归调用方。

### `testCallbackHost` (`src/exec/collection_ops.zig:816`)

- **签名**：`fn testCallbackHost(ctx: *core.JSContext) CallbackHost`。
- **作用**：单元测试用的最小 `CallbackHost`。
- **实现**：返回 `.{ .ctx = ctx, .call = testCallbackCallWithThis }`，`globals` 保持默认空切片。
- **所有权 / 错误 / 调用**：只被本文件的 `Map groupBy roots direct symbol key ...` 测试使用。

### `testCallbackCallWithThis` (`src/exec/collection_ops.zig:820`)

- **签名**：`fn testCallbackCallWithThis( ctx: *core.JSContext, callback: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot, ) CallbackError!core.JSValue`。
- **作用**：测试桩回调体：充当「分组函数」但不真的进 VM。
- **实现**：`ctx` / `callback` / `this_value` / `globals` 全部丢弃，`std.debug.assert(args.len >= 1)` 后原样返回 `args[0]`，即把元素本身当分组键。
- **所有权 / 错误 / 调用**：不分配、不抛错；仅测试使用。

### `collectionSize` (`src/exec/collection_ops.zig:835`)

- **签名**：`fn collectionSize(object: *core.Object) !core.JSValue`。
- **作用**：`Map.prototype.size` / `Set.prototype.size` getter 的实现。
- **实现**：class 不是 `map` 也不是 `set` → `error.TypeError`；否则把 `strongSize(object)`（活跃条目数）包成 `int32`。
- **所有权 / 错误 / 调用**：不分配；由 `methodCallResolved` 的 14 号臂调到。

### `collectionForEach` (`src/exec/collection_ops.zig:840`)

- **签名**：`fn collectionForEach( object: *core.Object, args: []const core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：裸 `CallbackHost` 版本的 `Map/Set.prototype.forEach`。
- **实现**：class 必须是 `map` 或 `set`；`args[0]` 必须过 `isCallableObject`，否则 `error.TypeError`；`this_arg` 取 `args[1]`，缺省 `undefined`。遍历前 `object.retainCollectionCursor()` / defer `releaseCollectionCursor()`：qjs `js_map_forEach`（quickjs.c:52318-52332）锁住当前 record 再前进，zjs 按下标走，所以锁的是 entry 数组——回调可以删条目，但槽位不能在游标下移动。循环按下标读条目（先自增），跳过 `!entry.active`，key 与 value 先取出本地副本（对应 quickjs.c:52322 的「must duplicate in case the record is deleted」；tracing GC 下这不是 retain，而是「回调前先读出」——回调期间 entry 槽可能被清空，`callback_args` 才是让这两个值保持可达的根），Set 的 value 就是 key；回调实参是 `(value, key, object.value())`，通过 `host.callWithThis(args[0], this_arg, ...)` 发出。结束返回 `undefined`。
- **所有权 / 错误 / 调用**：不分配；空 `CallbackHost` 会让 `callWithThis` 直接 `error.TypeError`。

### `mapGetOrInsert` (`src/exec/collection_ops.zig:872`)

- **签名**：`fn mapGetOrInsert(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue`。
- **作用**：`Map/WeakMap.prototype.getOrInsert`：有就取、没有就插入给定的默认值。
- **实现**：`weakmap` 分支先 `weakKeyIdentityRegister`（null → `error.TypeError`），`findWeakEntry` 命中直接返回已存的 value，否则 `appendWeakEntry` 写入并返回 value。否则 class 必须是 `map`；`canonicalizeKey` 归一后 `findStrongEntry` 命中返回已存 value，未命中 `appendStrongEntryOwned` 追加并返回 value。
- **所有权 / 错误 / 调用**：不涉及用户回调，因此裸入口也能用。

### `mapGetOrInsertComputed` (`src/exec/collection_ops.zig:889`)

- **签名**：`fn mapGetOrInsertComputed( rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, callback: core.JSValue, host: CallbackHost, ) !core.JSValue`。
- **作用**：`getOrInsertComputed` 的裸 `CallbackHost` 版本：缺失时用回调算值。
- **实现**：`callback` 不是可调用对象 → `error.TypeError`。`weakmap` 分支：注册键身份（null → TypeError），已存在直接返回现值（**不**调回调）；否则 `host.callValue(callback, &.{key})` 算值，回调返回后如果该键已经存在（回调自己插的）就 `removeWeakEntry` 再 `appendWeakEntry`——镜像 quickjs.c:52206 的 `map_delete_record` + `map_add_record`，让这条记录带着计算值重新排到迭代尾部。`map` 分支同构，只是键先过 `canonicalizeKey`、回调实参用的是 canonical key、删除用 `removeStrongEntry`、追加用 `appendStrongEntryOwned`；其它 class → `error.TypeError`。
- **所有权 / 错误 / 调用**：回调经 `host` 发出；VM 路径的对应实现是 `mapGetOrInsertComputedCall`。

### `canonicalizeKey` (`src/exec/collection_ops.zig:926`)

- **签名**：`fn canonicalizeKey(key: core.JSValue) core.JSValue`。
- **作用**：集合键的 -0 归一。
- **实现**：`key.asFloat64()` 拿到数值且等于 0（+0 与 -0 都满足）时返回 `core.JSValue.int32(0)`，其余原样返回。
- **所有权 / 错误 / 调用**：纯值变换；`canonicalizeMapKey` 是 VM 路径上的同实现副本。

### `collectionHas` (`src/exec/collection_ops.zig:933`)

- **签名**：`fn collectionHas(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue`。
- **作用**：四种集合共用的 `has`。
- **实现**：`weakmap` / `weakset` 用 `weakKeyIdentityPeek`（只查不注册），没有身份直接 `false`，否则看 `findWeakEntry`；`map` / `set` 看 `findStrongEntry`；其它 class → `error.TypeError`。结果一律包成布尔值。
- **所有权 / 错误 / 调用**：不分配、不建根、不改动集合：`weakKeyIdentityPeek` 是只查不注册版本，`findWeakEntry`/`findStrongEntry` 只读 entry 数组，返回的布尔是立即数。唯一 error 是 class 不匹配时的 `error.TypeError`。调用方 `src/exec/collection_ops.zig:417`（方法号 3）与 `:1208`。

### `collectionDelete` (`src/exec/collection_ops.zig:944`)

- **签名**：`fn collectionDelete(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue`。
- **作用**：`delete` 的返回布尔形态。
- **实现**：把 `collectionDeleteBool` 的结果包成 `core.JSValue.boolean`。
- **所有权 / 错误 / 调用**：自身不分配；删除动作在 `collectionDeleteBool`（:971）里完成——弱集合走 `removeWeakEntry`（摘掉运行时登记的弱引用，可失败），强集合走 `core/collection.zig` 的 `removeStrongEntry`：`takeStrongEntry` 清掉槽位，达到阈值时再 `compactStrongEntries` + `shrinkStrongStorage` 把 entry 数组缩回去（这是这条路径上唯一的堆动作）。被删的键/值本身归 GC，不需要调用方释放。error 只有 class 不匹配的 `error.TypeError` 与弱集合路径带出的分配失败。唯一调用方 `src/exec/collection_ops.zig:421`（方法号 4）。

### `collectionDeleteNoResult` (`src/exec/collection_ops.zig:948`)

- **签名**：`fn collectionDeleteNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !void`。
- **作用**：结果被丢弃时的 `delete`。
- **实现**：调 `collectionDeleteBool` 并丢弃返回值，省掉布尔装箱。
- **所有权 / 错误 / 调用**：由 `methodCallDroppedResult` 调用。

### `collectionDeleteBool` (`src/exec/collection_ops.zig:952`)

- **签名**：`fn collectionDeleteBool(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !bool`。
- **作用**：删除的真正实现。
- **实现**：`weakmap` / `weakset` 用 `weakKeyIdentityPeek`，没有身份或 `findWeakEntry` 未命中都返回 false，命中则 `removeWeakEntry` 后 true。否则 class 必须是 `map` 或 `set`（不是就 `error.TypeError`），`findStrongEntry` 未命中 false，命中 `removeStrongEntry`（不返回错误）后 true。
- **所有权 / 错误 / 调用**：移除会释放条目持有的强引用。

### `collectionClear` (`src/exec/collection_ops.zig:966`)

- **签名**：`fn collectionClear(rt: *core.JSRuntime, object: *core.Object) !core.JSValue`。
- **作用**：`Map/Set.prototype.clear`（弱表也走这里）。
- **实现**：`map` / `set` → `clearStrongEntries(object)`；`weakmap` / `weakset` → `clearWeakEntries(rt, object)`；两条路径都返回 `undefined`；其它 class → `error.TypeError`。
- **所有权 / 错误 / 调用**：清空时释放条目持有的引用 / 弱身份登记。

### `setAdd` (`src/exec/collection_ops.zig:978`)

- **签名**：`fn setAdd(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !core.JSValue`。
- **作用**：`Set/WeakSet.prototype.add` 的返回值形态。
- **实现**：调 `setAddNoResult` 后返回 `object.value()`（规范要求返回 this）。
- **所有权 / 错误 / 调用**：返回的是 receiver 自身的值。

### `setAddNoResult` (`src/exec/collection_ops.zig:983`)

- **签名**：`fn setAddNoResult(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void`。
- **作用**：Set / WeakSet 插入的真正实现。
- **实现**：`weakset` 分支 `weakKeyIdentityRegister` 注册身份（null → `error.TypeError`），只有 `findWeakEntry` 未命中才 `appendWeakEntry`，条目的 value 存 `undefined`。否则 class 必须是 `set`；`canonicalizeKey` 归一后同样只有未命中才 `appendStrongEntryOwned`，value 也是 `undefined`。重复插入是 no-op。
- **所有权 / 错误 / 调用**：强 Set 持有 key 的引用；WeakSet 只留身份。

### `setComposition` (`src/exec/collection_ops.zig:1019`)

- **签名**：`fn setComposition(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComposition, host: CallbackHost) !core.JSValue`。
- **作用**：裸 `CallbackHost` 版本的 `difference` / `intersection` / `symmetricDifference` / `union`（`SetComposition` 枚举的四个成员）。
- **实现**：receiver class 必须是 `set`、`args[0]` 必须是对象，否则 `error.TypeError`；`setLikeRecord` 读出 other 的 size 并校验 `has`/`keys`。遍历前 `retainCollectionCursor` / defer release 锁住 receiver 的 entry 数组——这些分支边走 receiver 边调用户的 `has`/`keys`，槽位不能移动（与 `js_map_forEach` 的 record lock 同契约，quickjs.c:52320）。结果集用 `constructWithPrototype(rt, 2, object.getPrototype())`，即继承 receiver 的原型。四个分支：`difference` 按大小选策略——receiver 更大时先把 receiver 全拷进结果、再用 `setLikeKeys` 拿 other 的键逐个从结果里 `removeStrongEntry`；否则逐个 `setLikeHas` 过滤。`intersection` 同样按大小二选一（receiver 较小则逐个 `setLikeHas`，否则拿 other 的键去 receiver 里查）。`symmetric_difference` 先整体拷贝 receiver，再遍历 other 的键：receiver 里有的就从结果里删、receiver 里没有且结果里也没有的就加、剩下的情况保持不动（键在迭代中从 receiver 消失时保留 receiver 的改动）。`union_` 拷贝 receiver 后把 other 的键全部 `setAdd`。
- **所有权 / 错误 / 调用**：`setLikeKeys` 返回的列表由 `freeValueList` defer 释放；结果 Set 归调用方。VM 路径的对应实现是 `setMethodRecord` 那一族。

### `setComparison` (`src/exec/collection_ops.zig:1114`)

- **签名**：`fn setComparison(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComparison, host: CallbackHost) !core.JSValue`。
- **作用**：裸 `CallbackHost` 版本的 `isDisjointFrom` / `isSubsetOf` / `isSupersetOf`（`SetComparison` 枚举的三个成员），返回布尔。
- **实现**：与 `setComposition` 相同的前置：receiver 必须是 `set`、`args[0]` 必须是对象、`setLikeRecord` 读记录、`retainCollectionCursor` / defer release 锁 entry 数组（`setLikeHas` 会跑用户代码）。`is_disjoint_from` 让小的一边驱动：receiver 不大于 other 时逐个 `setLikeHas`，命中即 `false`；否则取 other 的键去 receiver 里查，命中即 `false`；走完 `true`。`is_subset_of`：receiver 比 other 大直接 `false`，否则 receiver 的每个活跃键都必须 `setLikeHas` 命中。`is_superset_of`：receiver 比 other 小直接 `false`，否则 other 的每个键都必须在 receiver 里（用的是原始 key，没有再 canonicalize）。
- **所有权 / 错误 / 调用**：键列表 defer 释放；不分配结果对象。

### `setLikeRecord` (`src/exec/collection_ops.zig:1160`)

- **签名**：`fn setLikeRecord(object: *core.Object) !SetLikeRecord`。
- **作用**：裸路径版的 GetSetRecord：把 other 的 size 与方法校验打包。
- **实现**：先 `setLikeSize` 读大小，再 `validateSetLikeMethods` 校验 `has`/`keys`，返回 `SetLikeRecord{ .object, .size }`（只存对象指针与 size，不缓存方法值）。
- **所有权 / 错误 / 调用**：借用 other 对象指针；VM 路径的对应物是 `getSetRecord` / `SetLikeRecordVm`。

### `setLikeSize` (`src/exec/collection_ops.zig:1166`)

- **签名**：`fn setLikeSize(object: *core.Object) !usize`。
- **作用**：读 set-like 参数的元素个数。
- **实现**：原生 `set` / `map` 直接用内部的 `strongSize`；否则读可观察的 `size` 属性，必须是 int32（`asInt32()` 失败 → `error.TypeError`）且非负，否则 `error.TypeError`。
- **所有权 / 错误 / 调用**：读属性可能触发 getter；不分配。

### `validateSetLikeMethods` (`src/exec/collection_ops.zig:1174`)

- **签名**：`fn validateSetLikeMethods(object: *core.Object) !void`。
- **作用**：校验 set-like 参数带可调用的 `has` 与 `keys`。
- **实现**：原生 `set` / `map` 直接放行；否则分别读 `has`、`keys` 属性，任一不满足 `isCallableClosure`（即 class 不是 `c_closure`）就 `error.TypeError`。
- **所有权 / 错误 / 调用**：只被 `setLikeRecord` 调用。

### `setLikeHas` (`src/exec/collection_ops.zig:1186`)

- **签名**：`fn setLikeHas(rt: *core.JSRuntime, record: SetLikeRecord, key: core.JSValue, host: CallbackHost) !bool`。
- **作用**：对 set-like 参数问一次 `has`。
- **实现**：原生 `set` / `map` 走内部 `collectionHas`，结果 `asBool() orelse false`。否则**每次**重新读 `has` 属性并再校验一遍 `isCallableClosure`（不是就 `error.TypeError`），然后 `host.callWithThis(has_value, object.value(), &.{key})`，返回值同样 `asBool() orelse false`。
- **所有权 / 错误 / 调用**：回调经 `host` 发出；不分配。

### `setLikeKeys` (`src/exec/collection_ops.zig:1200`)

- **签名**：`fn setLikeKeys(rt: *core.JSRuntime, record: SetLikeRecord, host: CallbackHost) ![]core.JSValue`。
- **作用**：把 set-like 参数的键物化成一段切片。
- **实现**：原生 `set` / `map` 直接遍历 entry 数组，跳过 `!entry.active`，用 `appendValue` 逐个收集 key（errdefer `freeValueList`）。否则读 `keys` 属性并校验是 closure，`host.callWithThis(keys_value, object.value(), &.{})` 调用它；结果必须是对象，且**必须是数组**——按下标 `getProperty` 逐个收集；不是数组就 `error.TypeError`。裸路径不实现通用 iterator 协议，那是 VM 路径 `setLikeKeysIterator` 的职责。
- **所有权 / 错误 / 调用**：返回切片归调用方，用 `freeValueList` 释放。

### `appendValue` (`src/exec/collection_ops.zig:1230`)

- **签名**：`fn appendValue(rt: *core.JSRuntime, values: *[]core.JSValue, value: core.JSValue) !void`。
- **作用**：往一段 `JSValue` 列表尾部追加一个值。
- **实现**：先把待写入值与 `values` 这段可变切片一起装进 `ValueRootFrame`（`ValueRootSlice{ .mutable = values }` + `ValueRootValue`）并 activate，保证分配触发 GC 时新旧两边都被扫到；然后 `rt.memory.alloc(core.JSValue, len + 1)`（errdefer free）、`@memcpy` 旧内容、写入新值、释放非空的旧切片、把 `values.*` 换成新切片。每次追加都重新分配，长度是精确的 `len + 1`。
- **所有权 / 错误 / 调用**：列表所有权始终在调用方，最终由 `freeValueList` 释放。

### `freeValueList` (`src/exec/collection_ops.zig:1249`)

- **签名**：`fn freeValueList(rt: *core.JSRuntime, values: []core.JSValue) void`。
- **作用**：释放 `appendValue` / `setSnapshotKeys` 建的值列表。
- **实现**：长度为 0 时什么都不做（空切片不是堆分配），否则 `rt.memory.free(core.JSValue, values)`。
- **所有权 / 错误 / 调用**：不返回错误。

### `Trigger.trigger` (`src/exec/collection_ops.zig:1274`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：`appendValue roots existing values and incoming value during growth` 这条单元测试里的 GC 触发桩。
- **实现**：装进 `rt.memory.trigger_gc_fn`，在分配时被调用：丢弃 `size`，把 `context` 还原成 `*Trigger`，跑一次 `rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active)`（错误吞掉），然后记录两个符号 atom 在回收后是否仍然存活到 `saw_first` / `saw_second`。
- **所有权 / 错误 / 调用**：仅测试使用，测试结束时恢复原来的 trigger 钩子。

### `groupString` (`src/exec/collection_ops.zig:1304`)

- **签名**：`fn groupString( rt: *core.JSRuntime, map: *core.Object, string_value: core.JSValue, callback: core.JSValue, host: CallbackHost, ) !void`。
- **作用**：`groupByWithCallbackHost` 的字符串来源分支：按字符串元素逐个分组。
- **实现**：`stringFromValue` 取字符串体（不是字符串 → `error.TypeError`）；两个游标——`unit_index` 是码元下标（由 `stringElementAt` 推进，遇到代理对一次吃两个），`element_index` 是传给回调的元素序号（每轮 +1）；每个元素交 `addGroupedItem`。
- **所有权 / 错误 / 调用**：每个元素都是新建的字符串值；分组数组挂进 map。

### `addGroupedItem` (`src/exec/collection_ops.zig:1320`)

- **签名**：`fn addGroupedItem( rt: *core.JSRuntime, map: *core.Object, callback: core.JSValue, host: CallbackHost, item: core.JSValue, index: u32, ) !void`。
- **作用**：对一个元素求分组键并把它塞进对应的组数组。
- **实现**：先把 `rooted_item` / `key` / `existing` / `group_value` 四个局部装进 `ValueRootFrame` 并 activate（回调与建数组都会分配）；`host.callValue(callback, &.{ item, int32(index) })` 得到 key；`mapGet(rt, map, key)` 查已有组，非 `undefined` 就 `expectObject` 后 `appendArrayValue` 追加并返回；否则 `core.Object.createArray(rt, null)` 建一个**无原型**数组（裸路径没有 realm），追加元素后 `mapSet` 写回 map。
- **所有权 / 错误 / 调用**：组数组的引用随 `mapSet` 转移给 map；根帧在函数内 defer 撤销。VM 路径的对应实现 `mapAppendGroupByValue` 用的是 realm 的 `Array.prototype`。

### `appendArrayValue` (`src/exec/collection_ops.zig:1361`)

- **签名**：`fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void`。
- **作用**：往组数组末尾追加一个元素。
- **实现**：`!array.isArray()` → `error.TypeError`；否则以当前 `arrayLength()` 为下标 `defineOwnProperty`，描述符是 `Descriptor.data(value, true, true, true)`。
- **所有权 / 错误 / 调用**：值的引用随属性定义转移给数组。

### `stringElementAt` (`src/exec/collection_ops.zig:1366`)

- **签名**：`fn stringElementAt(rt: *core.JSRuntime, string_object: *core.string.String, index: *usize) !core.JSValue`。
- **作用**：从字符串里取出一个「元素」（完整代理对算一个），并推进下标。
- **实现**：读 `index.*` 处的码元并把下标 +1（String 恒为扁平，无需先物化）；若它是高代理且后面还有码元、且下一个是低代理，就再 +1 并用两个码元 `String.createUtf16` 造双码元字符串；否则用单个码元造字符串。孤立代理原样保留。
- **所有权 / 错误 / 调用**：返回的新字符串归调用方（立即交给 `addGroupedItem`）。

### `isCallableClosure` (`src/exec/collection_ops.zig:1383`)

- **签名**：`fn isCallableClosure(value: core.JSValue) bool`。
- **作用**：判断值是不是 `c_closure` 类的可调用对象（裸路径校验 set-like 的 `has`/`keys` 用）。
- **实现**：非对象、拿不到 `refHeader` 都返回 false；否则要求 `object.class_id == core.class.ids.c_closure`——比 `isCallableObject` 更窄，不接受 `c_function`。
- **所有权 / 错误 / 调用**：纯谓词。

### `isCallableObject` (`src/exec/collection_ops.zig:1390`)

- **签名**：`fn isCallableObject(value: core.JSValue) bool`。
- **作用**：判断值是不是本文件裸路径认可的可调用对象。
- **实现**：非对象、拿不到 `refHeader` 都返回 false；class 是 `c_closure` 或 `c_function` 时为 true。注意它不认 `bound_function` / `bytecode_function` 这类 class，VM 路径改用 `call_runtime.isCallableValue`。
- **所有权 / 错误 / 调用**：纯谓词；被 `groupByWithCallbackHost`、`collectionForEach`、`mapGetOrInsertComputed` 使用。

### `collectionClassId` (`src/exec/collection_ops.zig:1422`)

- **签名**：`fn collectionClassId(kind: u32) ?core.ClassId`。
- **作用**：把 `ConstructorKind` 数值映成引擎 class id。
- **实现**：1 → `map`、2 → `set`、3 → `weakmap`、4 → `weakset`，其它返回 null。
- **所有权 / 错误 / 调用**：唯一调用方是 `constructWithPrototype`（null 在那里变成 `error.TypeError`）。

### `defineNativeMethodWithRecordId` (`src/exec/collection_ops.zig:1435`)

- **签名**：`fn defineNativeMethodWithRecordId(realm: *core.RealmContext, object: *core.Object, key: core.Atom, length: i32) !void`。
- **作用**：给无原型的 legacy `construct` 对象挂一个带记录 id 的自有方法。
- **实现**：`core.atom.predefinedName(key)` 取方法名，`function_builtin.nativeFunction(realm, name, length)` 建函数对象；`prototypeMethodId(name)` 查不到 → `error.TypeError`；把 `method_object.nativeFunctionIdSlot().*` 写成 `nativeBuiltinId(.collection, id)`，于是调用走整数记录分派；最后以 `Descriptor.data(method, true, false, true)`（writable / non-enumerable / configurable）定义到对象上。
- **所有权 / 错误 / 调用**：函数对象的引用随属性定义转移；只被 `defineNativeMethods` 调用。

### `defineNativeMethods` (`src/exec/collection_ops.zig:1445`)

- **签名**：`fn defineNativeMethods(realm: *core.RealmContext, object: *core.Object, class_id: core.ClassId) !void`。
- **作用**：按 class 给 legacy 构造出来的集合对象挂全套自有方法。
- **实现**：`map` / `weakmap` 共同挂 `set`(2) / `get`(1) / `has`(1) / `delete`(1)；`map` 再加 `clear`(0) / `keys`(0) / `values`(0) / `entries`(0) / `forEach`(1) / `getOrInsert`(2) / `getOrInsertComputed`(2)，`weakmap` 只加 `getOrInsert`(2) / `getOrInsertComputed`(2)。`set` / `weakset` 共同挂 `add`(1) / `has`(1) / `delete`(1)；`set` 再加 `clear`(0) / `keys`(0) / `values`(0) / `entries`(0) / `forEach`(1)。其它 class 什么都不做。
- **所有权 / 错误 / 调用**：只被 `construct` 调用。

### `stringFromValue` (`src/exec/collection_ops.zig:1483`)

- **签名**：`fn stringFromValue(value: core.JSValue) ?*core.string.String`。
- **作用**：把值当字符串取字符串体。
- **实现**：直接 `return value.asStringBody()`（不是字符串返回 null）。
- **所有权 / 错误 / 调用**：借用指针；只被 `groupString` 使用。

### `ValueListRoot.init` (`src/exec/collection_ops.zig:1525`)

- **签名**：`fn init(self: *ValueListRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void`。
- **作用**：把一段可变的 `JSValue` 切片登记成 GC 根。
- **实现**：记下 `rt`，把 `values` 指针填进单元素数组 `slices[0] = .{ .mutable = values }`，用它组出 `ValueRootFrame` 并 `activate(rt)`。因为登记的是切片指针本身，切片被替换（重新分配）后新内容一样会被扫到。
- **所有权 / 错误 / 调用**：不拥有列表内存，只负责根登记；必须配对 `deinit`。

### `ValueListRoot.deinit` (`src/exec/collection_ops.zig:1534`)

- **签名**：`fn deinit(self: *ValueListRoot) void`。
- **作用**：撤销根登记。
- **实现**：`self.rt` 为 null 直接返回；否则 `self.frame.deactivate(rt)` 并把 `self.rt` 置回 null，因此重复 deinit 安全。
- **所有权 / 错误 / 调用**：不释放列表内存（那是 `freeValueList` 的事）。

### `collectionNativeRecord` (`src/exec/collection_ops.zig:1541`)

- **签名**：`pub fn collectionNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, id: u32, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：有函数对象（可观察调用）时的集合原型方法分派：先做 receiver 校验，再按方法选热臂或 realm 感知臂。
- **实现**：① receiver：`this_value` 不是对象时，若函数对象带 owner class 就抛 `throwCollectionReceiverTypeError`（"Map object expected" 之类），否则裸 `error.TypeError`；是对象但 `receiver.class_id != owner_class` 同样抛带 class 名的 TypeError——`collectionMethodOwnerClass` 读的是安装时钉在函数对象上的 owner class。② 把 `id` 映成 `PrototypeMethod`，未知 id 返回 `null`（由 `collectionCall` 折成 TypeError）。③ 若 `collectionCallResultIsDropped` 成立，先试 `methodCallDroppedResult`，它抛的 `error.TypeError` 转成 `throwCollectionMethodTypeError`（能区分弱集合无效键的消息），处理成功则返回 `undefined`。④ 正式分派：`set` / `get` / `has` / `delete` / `clear` / `add` / `keys` / `values` / `entries` / `get_or_insert` / `size_getter` 走 `methodCallObjectWithGlobal`（legacy globals 传空切片），其 `error.TypeError` 转成带消息的异常；`for_each` → `collectionForEachRecord`；`get_or_insert_computed` → `mapGetOrInsertComputedCall`；七个集合代数方法 → `setMethodRecord`；`iterator_next` 先要求 receiver 是 `map_iterator` / `set_iterator`，再同样走 `methodCallObjectWithGlobal`——必须带 realm，否则迭代结果对象会拿到 null 原型（源码注释明说这是从旧的 global-less `methodCall` 改过来的原因）。
- **所有权 / 错误 / 调用**：返回值归调用方；`null` 表示「这条 id 不归我管」。唯一调用方是 `collectionCall`。

### `collectionCallResultIsDropped` (`src/exec/collection_ops.zig:1637`)

- **签名**：`fn collectionCallResultIsDropped(caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame) bool`。
- **作用**：问调用点是不是会立刻丢弃返回值。
- **实现**：直接转发 `builtin_dispatch.callerResultIsDropped(caller_function, caller_frame)`，本文件只是包一层本地名字。
- **所有权 / 错误 / 调用**：被 `collectionCall` 与 `collectionNativeRecord` 用来决定要不要走 `methodCallDroppedResult`。

### `collectionForEachRecord` (`src/exec/collection_ops.zig:1641`)

- **签名**：`fn collectionForEachRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, receiver: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：realm 感知版的 `Map/Set.prototype.forEach`：回调经 VM 调用点发出。
- **实现**：receiver class 不是 `map` / `set` → `throwCollectionReceiverTypeError`；`args[0]` 必须过 `call_runtime.isCallableValue`，否则 `error.TypeError`；`this_arg` 取 `args[1]`，缺省 `undefined`。用 `CallSite.initInternal(ctx, output, global, this_arg, callback, caller_function, caller_frame)` 建一个常驻调用点（整轮循环复用）。遍历前 `receiver.retainCollectionCursor()` / defer release 锁住 entry 数组（与 `js_map_forEach` quickjs.c:52318-52332 同样的 record lock + 实参复制）；跳过 `!entry.active`，Set 的 value 用 key；回调实参是 `(value, key, this_value)`——第三个参数直接用传进来的原始 this 值。结束返回 `undefined`。
- **所有权 / 错误 / 调用**：回调抛错直接上抛（不吞）；调用方是 `collectionNativeRecord`。

### `setMethodRecord` (`src/exec/collection_ops.zig:1680`)

- **签名**：`fn setMethodRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, method: PrototypeMethod, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：七个 Set 代数 / 比较方法的 realm 感知入口。
- **实现**：receiver class 不是 `set` → `throwCollectionReceiverTypeError(..., core.class.ids.set)`；没有 `args[0]` → `error.TypeError`；`getSetRecord` 按规范顺序读出 other 的 `size` / `has` / `keys`；`setMethodModeFromRecord` 把方法映成 `SetMethodMode`（映不到 → `error.TypeError`）；`receiver.retainCollectionCursor()` / defer release 保证跨用户 `has`/`keys` 调用时 entry 下标稳定；最后按 mode 分派到 `setDifference` / `setIntersection` / `setIsDisjointFrom` / `setIsSubsetOf` / `setIsSupersetOf` / `setSymmetricDifference` / `setUnion`。
- **所有权 / 错误 / 调用**：结果（新 Set 或布尔）归调用方；调用方是 `collectionNativeRecord`。

### `setMethodModeFromRecord` (`src/exec/collection_ops.zig:1708`)

- **签名**：`fn setMethodModeFromRecord(method: PrototypeMethod) ?SetMethodMode`。
- **作用**：把 `PrototypeMethod` 里的七个集合代数方法转成本文件的 `SetMethodMode`。
- **实现**：`difference` / `intersection` / `is_disjoint_from` / `is_subset_of` / `is_superset_of` / `symmetric_difference` / `union_` 一一对应，其余方法返回 null。
- **所有权 / 错误 / 调用**：纯映射；只被 `setMethodRecord` 调用。

### `getSetRecord` (`src/exec/collection_ops.zig:1721`)

- **签名**：`fn getSetRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, other_value: core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !SetLikeRecordVm`。
- **作用**：规范的 GetSetRecord：从 set-like 参数上读出 size / has / keys 并做全部校验。
- **实现**：镜像 `get_set_record`（quickjs.c:52641）。参数必须是对象。size：只有原生 `set`（`JS_GetOpaque(obj, JS_CLASS_SET)` 那条快路）用内部计数 `setStrongSize`；Map 与其它 set-like 都读**可观察**的 `size` 属性——结果是对象时先 `coercion_ops.toPrimitiveForNumber`，再 `value_ops.toNumberValue`，NaN 抛 TypeError `".size is not a number"`，然后按 qjs 的 int64 clamp（低于 -2^63 取 `minInt(i64)`，≥ 2^63 取 `maxInt(i64)`，因为 INT64_MAX 无法精确表示成 double，上界比较用的是 0x1p63），负数抛 RangeError `".size must be positive"`。has / keys：无论参数是不是原生 Set/Map 都要读（所以实例级覆写保持可观察），`undefined` 分别抛 `".has is undefined"` / `".keys is undefined"`，非可调用抛 `".has is not a function"` / `".keys is not a function"`；这些 `throw*Message` 之后跟 `unreachable`。返回 `SetLikeRecordVm{ .object_value, .size, .has, .keys }`，后续调用直接用这份已取到的方法值。
- **所有权 / 错误 / 调用**：记录里存的是借用的值；调用方是 `setMethodRecord`。

### `setStrongSize` (`src/exec/collection_ops.zig:1794`)

- **签名**：`fn setStrongSize(object: *core.Object) usize`。
- **作用**：数强集合里的活跃条目。
- **实现**：遍历 `collectionEntriesSlot()`，`entry.active` 为真才计数（被删的条目留有墓碑槽位）。
- **所有权 / 错误 / 调用**：纯读；VM 侧的 set 代数实现都用它和 `other_record.size` 比大小。

### `constructPlainSet` (`src/exec/collection_ops.zig:1802`)

- **签名**：`fn constructPlainSet(ctx: *core.JSContext) !core.JSValue`。
- **作用**：建一个带 realm `Set.prototype` 的空 Set，作为集合代数方法的结果容器。
- **实现**：`ctx.classPrototypeObject(core.class.ids.set)` 取原型（缺失 → `error.InvalidBuiltinRegistry`），再 `constructWithPrototype(ctx.runtime, 2, set_proto)`。注意 VM 路径的结果原型来自 realm，而裸路径 `setComposition` 用的是 receiver 自己的原型。
- **所有权 / 错误 / 调用**：返回新建的 GC Set 对象，本函数不建根，三个调用方也只把它放在 Zig 局部变量里——只有在 `setAddValue`/`setDeleteValue` 进入 `methodCallResolved` 期间它才作为 receiver 被临时 root（:400-403）。error 有两支：原型缺失的 `error.InvalidBuiltinRegistry` 与 `constructWithPrototype` 的 OOM。调用方 `src/exec/collection_ops.zig:1895`（`setCloneReceiver`）、`:1945`、`:1985`。

### `setAddValue` (`src/exec/collection_ops.zig:1807`)

- **签名**：`fn setAddValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void`。
- **作用**：往引擎自己刚建的结果 Set 里插入一个值。
- **实现**：`methodCall(rt, set_value, 6, &.{key})`（6 号 = `setAdd`）并丢弃返回的 this。走裸 `methodCall` 是安全的：结果 Set 是原生 Set，插入不需要回调能力。
- **所有权 / 错误 / 调用**：不分配额外缓冲。

### `setDeleteValue` (`src/exec/collection_ops.zig:1811`)

- **签名**：`fn setDeleteValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void`。
- **作用**：从结果 Set 里删一个值。
- **实现**：`methodCall(rt, set_value, 4, &.{key})`（4 号 = `collectionDelete`）并丢弃布尔结果。
- **所有权 / 错误 / 调用**：自身不分配、不建根；`methodCall` 内部会为 receiver 建根。error 透传自 `collectionDelete`（class 不匹配 → `error.TypeError`）。调用方 `src/exec/collection_ops.zig:1959`（`setDifference`）与 `:2048`（`setSymmetricDifference`）的剔除步。

### `setHasValue` (`src/exec/collection_ops.zig:1815`)

- **签名**：`fn setHasValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !bool`。
- **作用**：查结果 Set / receiver 里有没有某个值（内部查询，不经用户可见的 `has`）。
- **实现**：`methodCall(rt, set_value, 3, &.{key})`（3 号 = `collectionHas`），结果过 `coercion_ops.valueTruthy`。
- **所有权 / 错误 / 调用**：自身不分配、不建根，返回的是 Zig `bool` 而非 JSValue，所以结果不需要 GC 保护；走内部 `methodCall` 而不是用户可见的 `has`，因此不会触发用户代码。error 透传自 `collectionHas`。调用方 `src/exec/collection_ops.zig:2002,2047,2049,2085,2131` 共 5 处集合代数步。

### `setLikeHasCall` (`src/exec/collection_ops.zig:1820`)

- **签名**：`fn setLikeHasCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, record: SetLikeRecordVm, key: core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !bool`。
- **作用**：调 set-like 参数那份**已经取到**的 `has`。
- **实现**：`call_runtime.callValueOrBytecodeSyncInternalOutlined`，this 为 `record.object_value`、callee 为 `record.has`、实参 `&.{key}`，结果过 `coercion_ops.valueTruthy`。镜像 `js_set_isSubsetOf` 一族（quickjs.c:52813）：记录里的 `has` 对任何参数种类都要 `JS_Call`，原生 Set 也不例外。
- **所有权 / 错误 / 调用**：用户代码可能在这里改动 receiver，所以调用方已经锁住了 entry 数组。

### `setLikeKeysIterator` (`src/exec/collection_ops.zig:1845`)

- **签名**：`fn setLikeKeysIterator( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：调 set-like 参数的 `keys` 并把返回的迭代器准备好。
- **实现**：`callValueOrBytecodeSyncInternalOutlined` 以 `record.object_value` 为 this 调 `record.keys`（镜像 `js_set_union` quickjs.c:53144：原生 Set/Map 也照调）；结果必须是对象，否则 `error.TypeError`；再读它的 `next` 属性并要求可调用，把 `next` 存进 `iterator_object.cachedIteratorNextSlot(ctx.runtime)`，之后的 `iteratorStepValue` 直接用缓存；返回迭代器值本身。
- **所有权 / 错误 / 调用**：迭代器归调用方，异常退出时由各 `set*` 实现决定是否 `closeIteratorFromVm`。

### `setCloneReceiver` (`src/exec/collection_ops.zig:1874`)

- **签名**：`fn setCloneReceiver(ctx: *core.JSContext, receiver: *core.Object) !core.JSValue`。
- **作用**：把 receiver 的活跃元素拷进一个新的 realm Set。
- **实现**：`constructPlainSet` 建结果，按下标遍历 receiver 的 entry 数组，跳过 `!entry.active`，逐个 `setAddValue`。
- **所有权 / 错误 / 调用**：结果归调用方；被 `setUnion` 与 `setSymmetricDifference` 使用。

### `setSnapshotKeys` (`src/exec/collection_ops.zig:1885`)

- **签名**：`fn setSnapshotKeys(rt: *core.JSRuntime, receiver: *core.Object) ![]core.JSValue`。
- **作用**：把 receiver 当前的活跃键快照成一段切片。
- **实现**：先 `setStrongSize` 数个数，为 0 时直接返回空切片（不分配）；否则一次 `rt.memory.alloc`（errdefer free），遍历 entry 数组把活跃 key 依次写入。
- **所有权 / 错误 / 调用**：切片归调用方（`setDifference` 用 `freeValueList` defer 释放，并用 `ValueListRoot` 钉根）。

### `setDifference` (`src/exec/collection_ops.zig:1916`)

- **签名**：`fn setDifference( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.difference` 的 realm 感知实现。
- **实现**：结果是 `constructPlainSet` 建的新 Set。receiver 活跃数大于 `other_record.size` 时：先把 receiver 的活跃键全部 `setAddValue` 进结果，再 `setLikeKeysIterator` 取 other 的键迭代器，`iteratorStepValue` 逐个 `setDeleteValue`。否则：`setSnapshotKeys` 把 receiver 的键快照下来（`freeValueList` defer 释放 + `ValueListRoot` 钉根，因为随后的 `has` 调用会跑用户代码并可能触发 GC），逐个 `setLikeHasCall`，不在 other 里的才加进结果。
- **所有权 / 错误 / 调用**：结果 Set 归调用方；这条路径不主动 close 迭代器。

### `setIntersection` (`src/exec/collection_ops.zig:1956`)

- **签名**：`fn setIntersection( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.intersection`。
- **实现**：结果是新的 realm Set。receiver 活跃数不大于 `other_record.size` 时按下标遍历 receiver 的活跃条目，`setLikeHasCall` 命中才 `setAddValue`；否则取 other 的键迭代器，对每个键用内部的 `setHasValue(receiver)` 判断，命中才加。
- **所有权 / 错误 / 调用**：结果 Set 归调用方。

### `setUnion` (`src/exec/collection_ops.zig:1990`)

- **签名**：`fn setUnion( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.union`。
- **实现**：**先**调 `setLikeKeysIterator` 拿 other 的键迭代器，**再** `setCloneReceiver` 克隆 receiver（这个顺序是可观察的：`keys` 里的副作用发生在快照之前），然后 `iteratorStepValue` 逐个 `setAddValue` 进结果。
- **所有权 / 错误 / 调用**：结果 Set 归调用方。

### `setSymmetricDifference` (`src/exec/collection_ops.zig:2011`)

- **签名**：`fn setSymmetricDifference( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.symmetricDifference`。
- **实现**：同样先取 other 的键迭代器再 `setCloneReceiver`。对迭代出的每个键：`setHasValue(receiver)` 为真说明两边都有，从结果里 `setDeleteValue`；否则若结果里也还没有，就 `setAddValue`。
- **所有权 / 错误 / 调用**：结果 Set 归调用方。

### `setIsDisjointFrom` (`src/exec/collection_ops.zig:2036`)

- **签名**：`fn setIsDisjointFrom( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.isDisjointFrom`，返回布尔。
- **实现**：receiver 不大于 other 时遍历 receiver 的活跃条目，任一 `setLikeHasCall` 命中就 `false`，走完 `true`（这条路径不建迭代器）。否则取 other 的键迭代器逐个 `setHasValue(receiver)`，命中就先 `forof_ops.closeIteratorFromVm` 再返回 `false`；迭代 done 返回 `true`。
- **所有权 / 错误 / 调用**：提前退出时负责关闭迭代器。

### `setIsSubsetOf` (`src/exec/collection_ops.zig:2072`)

- **签名**：`fn setIsSubsetOf( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.isSubsetOf`。
- **实现**：receiver 活跃数大于 `other_record.size` 直接 `false`（size 先行短路，不调任何 trap）；否则按下标遍历 receiver 的活跃条目，任一 `setLikeHasCall` 不命中就 `false`，全部命中 `true`。全程不需要 other 的 `keys`。
- **所有权 / 错误 / 调用**：不建迭代器，也就没有关闭义务。

### `setIsSupersetOf` (`src/exec/collection_ops.zig:2093`)

- **签名**：`fn setIsSupersetOf( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: *core.Object, other_record: SetLikeRecordVm, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !core.JSValue`。
- **作用**：`Set.prototype.isSupersetOf`。
- **实现**：receiver 活跃数小于 `other_record.size` 直接 `false`；否则取 other 的键迭代器，任一键 `setHasValue(receiver)` 不命中就 `closeIteratorFromVm` 后 `false`；迭代 done 返回 `true`。
- **所有权 / 错误 / 调用**：提前退出时负责关闭迭代器。

### `mapGroupByCall` (`src/exec/collection_ops.zig:2118`)

- **签名**：`pub fn mapGroupByCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Map.groupBy` 的 realm 入口：补上结果 Map 的原型。
- **实现**：`ctx.classPrototypeObject(core.class.ids.map)` 取内建 `Map.prototype`（缺失 → `error.InvalidBuiltinRegistry`），再转发 `mapGroupByRecord`。
- **所有权 / 错误 / 调用**：结果归调用方；调用方是 `collectionGroupByRecord`（以及 VM 侧的按名分派）。

### `mapGroupByRecord` (`src/exec/collection_ops.zig:2130`)

- **签名**：`pub fn mapGroupByRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, prototype: ?*core.Object, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：`Map.groupBy` 的完整实现：按通用迭代协议遍历来源并分组。
- **实现**：实参少于 2 个或 `args[1]` 不可调用 → `error.TypeError`；`constructWithPrototype(ctx.runtime, 1, prototype)` 建结果 Map；`iterator_ops.iteratorForValue` 从 `args[0]` 取迭代器；用 `CallSite.initInternal`（this 传 `undefined`）建常驻回调调用点。循环里：`index` 达到 `9007199254740991`（2^53-1）时先 `closeIteratorForFromEntriesAbrupt` 再 `error.TypeError`；`iteratorStepValue` 报 done 就返回 map；回调实参是 `(step.value, numberToValue(index))`，回调抛错时先关闭迭代器再上抛；`mapAppendGroupByValue` 抛错同样先关闭迭代器；每轮 `index += 1`。
- **所有权 / 错误 / 调用**：结果 Map 归调用方；abrupt 退出的迭代器关闭义务全部在本函数内处理。

### `mapGetOrInsertComputedCall` (`src/exec/collection_ops.zig:2180`)

- **签名**：`pub fn mapGetOrInsertComputedCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) !?core.JSValue`。
- **作用**：realm 感知版的 `Map/WeakMap.prototype.getOrInsertComputed`。
- **实现**：receiver 不是对象、或 class 既不是 `weakmap` 也不是 `map` → 返回 `null`（交回上层）；函数对象带的 owner class 与 receiver 不符 → `throwCollectionReceiverTypeError`；实参少于 2 个或 `args[1]` 不可调用 → `error.TypeError`。键：`map` 过 `canonicalizeMapKey`，`weakmap` 原样但要过 `primitive_ops.canBeHeldWeakly`，不通过则抛 `"invalid value used as WeakMap key"`。然后先用裸 `methodCall(..., 3, &.{key})` 问 `has`，命中就 `methodCall(..., 2, ...)` 取现值返回（不调回调）；否则 `call_runtime.callValueOrBytecodeSyncInternalOutlined` 以 `undefined` 为 this 调回调算值，再按 quickjs.c:52206 的 `map_delete_record` + `map_add_record` 顺序：`methodCall(..., 4, ...)` 删、`methodCall(..., 1, &.{ key, computed })` 写，最后返回计算值——回调自己插进去的同键记录会被删掉并以计算值重新排到迭代尾部。
- **所有权 / 错误 / 调用**：返回值归调用方；调用方是 `collectionNativeRecord` 的 `get_or_insert_computed` 臂。

### `collectionMethodOwnerClass` (`src/exec/collection_ops.zig:2230`)

- **签名**：`pub fn collectionMethodOwnerClass(function_object: *core.Object) ?core.ClassId`。
- **作用**：读函数对象上钉着的「这个方法属于哪个集合 class」标记。
- **实现**：取 `function_object.collectionMethodOwnerClass()`，等于 `core.class.invalid_class_id` 时返回 null，否则返回该 class id。
- **所有权 / 错误 / 调用**：热路径 receiver 校验（`collectionNativeRecord`、`mapGetOrInsertComputedCall`）靠它，比按名字比对快且准。

### `canonicalizeMapKey` (`src/exec/collection_ops.zig:2236`)

- **签名**：`fn canonicalizeMapKey(key: core.JSValue) core.JSValue`。
- **作用**：VM 路径上的键 -0 归一。
- **实现**：与 `canonicalizeKey` 完全同构：`asFloat64()` 为 0 时返回 `int32(0)`，否则原样返回。
- **所有权 / 错误 / 调用**：只被 `mapGetOrInsertComputedCall` 使用。

### `throwCollectionReceiverTypeError` (`src/exec/collection_ops.zig:2243`)

- **签名**：`fn throwCollectionReceiverTypeError(ctx: *core.JSContext, global: *core.Object, owner_class: core.ClassId) !core.JSValue`。
- **作用**：抛「receiver 类型不对」的 TypeError。
- **实现**：`exception_ops.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(owner_class))`，消息文本按 owner class 选。
- **所有权 / 错误 / 调用**：异常挂在 ctx 上；返回值只是形式上的 sentinel。

### `throwCollectionMethodTypeError` (`src/exec/collection_ops.zig:2247`)

- **签名**：`fn throwCollectionMethodTypeError( ctx: *core.JSContext, global: *core.Object, receiver: *core.Object, method: PrototypeMethod, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把方法体里的裸 `error.TypeError` 还原成带准确消息的异常。
- **实现**：两个特例优先——receiver 是 `weakmap` 且方法是 `set` / `get_or_insert` / `get_or_insert_computed`、且首个实参不能被弱持有时抛 `"invalid value used as WeakMap key"`；receiver 是 `weakset` 且方法是 `add`、首参不能被弱持有时抛 `"invalid value used in weak set"`；两者都不是则回落到 `collectionReceiverMessage(receiver.class_id)` 的通用消息。
- **所有权 / 错误 / 调用**：由 `collectionNativeRecord` 在 `methodCallDroppedResult` / 存储类方法臂捕获 TypeError 后调用。

### `collectionReceiverMessage` (`src/exec/collection_ops.zig:2269`)

- **签名**：`fn collectionReceiverMessage(owner_class: core.ClassId) []const u8`。
- **作用**：按 class 给出 receiver 类型错误的消息文本。
- **实现**：`map` → `"Map object expected"`、`set` → `"Set object expected"`、`weakmap` → `"WeakMap object expected"`、`weakset` → `"WeakSet object expected"`、`map_iterator` → `"Map Iterator object expected"`、`set_iterator` → `"Set Iterator object expected"`，其余返回 `"not an object"`。
- **所有权 / 错误 / 调用**：返回静态字面量，不需要释放。

### `mapAppendGroupByValue` (`src/exec/collection_ops.zig:2279`)

- **签名**：`fn mapAppendGroupByValue( ctx: *core.JSContext, global: *core.Object, map_value: core.JSValue, key: core.JSValue, value: core.JSValue, ) !void`。
- **作用**：`mapGroupByRecord` 的写入步骤：把一个元素放进它所属的组数组。
- **实现**：`methodCall(ctx.runtime, map_value, 2, &.{key})`（2 号 = `mapGet`）查已有组：非 `undefined` 时必须是数组（`expectObject` + `isArray`，否则 `error.TypeError`），在 `arrayLength()` 下标 `defineOwnProperty(..., Descriptor.data(value, true, true, true))` 追加后返回。否则以 `array_ops.arrayPrototypeFromGlobal` 的 realm `Array.prototype` `createArray` 建新组（errdefer 销毁），写入首元素，再 `methodCall(..., 1, &.{ key, group.value() })`（1 号 = `mapSet`）挂进 map。
- **所有权 / 错误 / 调用**：新组数组的引用随 `mapSet` 转移给 map。

## `src/exec/collection_adapter.zig` — 集合回调的 realm 适配

`host()` 填 `CallbackHost.call = callWithThis`。成功堆结果归调用方。普通引擎失败在这里变成 pending JS 异常；只有七个硬/控制错误穿过 core 回调缝。


### `host` (`src/exec/collection_adapter.zig:18`)

- **签名**：`pub fn host(ctx: *core.JSContext, globals: []globals_mod.Slot) CallbackHost`。
- **作用**：把 exec 侧的调用能力打包成 core 集合算法要用的 `CallbackHost`。
- **实现**：返回结构字面量 `.{ .ctx = ctx, .globals = globals, .call = callWithThis }`，没有别的逻辑。
- **所有权 / 错误 / 调用**：`ctx` 与 `globals` 都是借用；调用方是 `collection_ops.collectionCall` 的无 global 分支（`src/exec/collection_ops.zig:225`）、`collectionGroupByRecord`（:259）与 `groupBy`（:493），每次进入集合算法时现场构造一个。

### `callWithThis` (`src/exec/collection_adapter.zig:26`)

- **签名**：`fn callWithThis( ctx: *core.JSContext, callback: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot, ) CallbackError!core.JSValue`。
- **作用**：`CallbackHost.call` 的实体：替集合算法回调一个 JS 可调用值。
- **实现**：转发 `closure_mod.callWithThis(ctx.runtime, callback, this_value, args, globals)`；`catch` 到的错误交给 `narrowCallbackError` 收窄。
- **所有权 / 错误 / 调用**：callback / receiver / 实参都是借用，返回的堆结果归调用方；错误集被收窄成 `CallbackError`。

### `narrowCallbackError` (`src/exec/collection_adapter.zig:37`)

- **签名**：`fn narrowCallbackError(ctx: *core.JSContext, err: anytype) CallbackError`。
- **作用**：把闭包调用可能抛出的任意引擎错误压缩成能穿过 core 回调缝的七个结果。
- **实现**：`switch (@as(anyerror, err))`：`OutOfMemory`、`Interrupted`、`ProcessExit`、`StackOverflow`、`Timeout`、`UnhandledPromiseRejection` 六个硬 / 控制错误原样透传；`JSException` 在 `ctx.hasException()` 时直接返回，否则先 `builtin_dispatch.nativeFromHostError(ctx, ctx.global, err)` 物化再返回；其余一切错误都先物化成 pending 异常，再统一返回 `error.JSException`。
- **所有权 / 错误 / 调用**：显式传入的 `ctx` 就是错误 realm 权威；物化后的异常挂在该 ctx 上，返回值只作为信号。


## `src/exec/reflect_ops.zig` — Reflect.* 与 Proxy.revocable 实现

`reflectConstruct` 对带 construct 记录的内建（Date/RegExp/String、Array、集合）走 `callConstructRecord`，Number/WeakRef/FinalizationRegistry/TypedArray 各有专门分支，全不命中则造普通对象。`proxyRevocable` 造 `{proxy, revoke}`；revoke 闭包是一个 data function，靠写死的 `.reflect` `proxy_revoke` native id 回到 `revokeProxy`。（本文件原先还有 `reflectHasProperty` / `proxyReflectHasProperty` / `typedArrayReflectHas` 一组，三者只互相调用、没有任何外部入口——`Reflect.has` 真正走 `reflectHasCall` → `object_ops.hasValueProperty`——已作为不可达代码删除。）


### `reflectConstruct` (`src/exec/reflect_ops.zig:48`)

- **签名**：`pub fn reflectConstruct(ctx: *core.JSContext, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：无 VM global 时的 `Reflect.construct` 回退实现：校验 target / new.target 可构造，解析实例原型，再按内建种类分派到对应构造路径。
- **实现**：实参少于 2 个或 `isConstructorValue(args[0])` 为假 → `error.TypeError`；`thisObject(args[0])` 取 target，`nativeFunctionName` 取名字（失败按 null，成功则 defer free）；`new_target` 取 `args[2]`，缺省用 `args[0]`，同样要过 `isConstructorValue`。第一级分派看 native builtin id：`core.function.decodeNativeBuiltinId(target.nativeFunctionId())` 命中且 `reflectConstructTargetName` 给出类名（Date / RegExp / String）时，用 `ReflectConstructArguments` 展开 `args[1]`、`reflectConstructPrototype` 解析原型，再走 `builtin_dispatch.callConstructRecord`，返回非 null 即为结果。第二级是名字级联：`"Array"` 且 `target.arrayBuiltinMarker() == .constructor` → 走模块顶部固定的 `array_construct_ref` 记录；`"Iterator"` → new_target 与 `args[0]` 同值时 TypeError，否则只造一个普通 object 实例；`"Number"` → 参数是 Symbol 抛 TypeError，是 BigInt 走 `value_ops.bigIntToNumber`（对照 qjs `js_number_constructor`，quickjs.c:44822-44841：ToNumeric 之后 bigint 转 float64 而不抛），其余走 `value_ops.toIntegerOrInfinity`，无参数则 `int32(0)`，最后 `primitiveWrapper` 包成 Number 对象；`"FinalizationRegistry"` → 第一个参数必须存在且可调用，`createFinalizationRegistry` 后写 cleanup callback 槽；`"WeakRef"` → `core.symbol.canBeHeldWeakly` 校验后 `construct_mod.weakRefWithPrototype`；集合构造器名（`builtin_method_id_lookup.collection.constructorId`）→ 以 `.collection` domain 的 construct 记录、空参数列表调 `callConstructRecord`；`construct_mod.typedArrayElement(name)` 命中 → `construct_mod.constructTypedArrayValue`。全不命中时按 `target_name orelse "Object"` 解析原型并造普通 object 实例。
- **所有权 / 错误 / 调用**：`target_name` 由 `rt.memory.allocator` 分配、defer 释放；`ReflectConstructArguments` 与 `OwnedPrototype` 各自 defer deinit；新建实例上挂 `errdefer core.Object.destroyFromHeader`。这是 null-global 回退入口（源码注释明说原始参数不做 VM 上下文强制转换），有 VM global 的路径走 `reflectConstructCall`；src 内直接调用方只有 `src/tests/exec.zig`。

### `reflectConstructTargetName` (`src/exec/reflect_ops.zig:164`)

- **签名**：`fn reflectConstructTargetName(native_ref: core.function.NativeBuiltinRef) ?[]const u8`。
- **作用**：把已解码的 native-builtin ref 映射成 `reflectConstructPrototype` 要用的内建实例类名。
- **实现**：按 `native_ref.domain` switch：`.date` 且 id 是 `date.ConstructorMethod.construct` → `"Date"`；`.regexp` 且 id 是 `regexp.ConstructorMethod.construct` → `"RegExp"`；`.string` 且 id 是 `string.ConstructorMethod.call`（不是 construct）→ `"String"`；其余一律 null，让调用方落到名字级联与普通实例回退。
- **所有权 / 错误 / 调用**：返回的是静态字符串字面量，不需要释放；唯一调用方是 `reflectConstruct`。

### `ReflectConstructArguments.init` (`src/exec/reflect_ops.zig:179`)

- **签名**：`fn init(self: *ReflectConstructArguments, rt: *core.JSRuntime, value: core.JSValue) !void`。
- **作用**：把 `Reflect.construct` 的 argumentsList 数组展开成参数切片，并把它钉成 GC 根。
- **实现**：`reflectConstructArgumentList(rt, value)` 分配并填充 `self.values`，记下 `self.rt`，再 `self.root.init(rt, &self.values)` 把这段切片登记进 `ValueSliceRoot`。
- **所有权 / 错误 / 调用**：切片归本结构所有，必须由 `deinit` 释放；错误（`error.TypeError` / OOM）直接上抛，此时结构仍是零值、`deinit` 是安全的 no-op。

### `ReflectConstructArguments.deinit` (`src/exec/reflect_ops.zig:185`)

- **签名**：`fn deinit(self: *ReflectConstructArguments) void`。
- **作用**：撤销根登记并释放 `init` 分配的参数切片。
- **实现**：`self.rt` 为 null（没 init 过）直接返回；否则依次 `self.root.deinit()`、`freeReflectConstructArgumentList(rt, self.values)`，最后 `self.* = .{}` 复位，因此重复 deinit 安全。
- **所有权 / 错误 / 调用**：不返回错误；`reflectConstruct` 的每个分支都用 `defer construct_args.deinit()` 调它。

### `reflectConstructArgumentList` (`src/exec/reflect_ops.zig:193`)

- **签名**：`fn reflectConstructArgumentList(rt: *core.JSRuntime, value: core.JSValue) ![]core.JSValue`。
- **作用**：把 argumentsList 参数（必须是数组）读成一段 `JSValue` 切片。
- **实现**：`expectObjectArg` 取对象，`!object.isArray()` → `error.TypeError`；按 `object.arrayLength()` 一次性 `rt.memory.alloc`（errdefer free）；随后用一个独立的 `rooted_out` 切片 + `ValueSliceRoot` 只钉住**已初始化前缀**，循环 `object.getProperty(core.atom.atomFromUInt32(index))` 逐个写入并把 `rooted_out` 推进到 `out[0..initialized]`，避免取值过程中触发 GC 时扫到未初始化的槽位。
- **所有权 / 错误 / 调用**：返回切片归调用方，由 `freeReflectConstructArgumentList` 释放；唯一调用方是 `ReflectConstructArguments.init`。

### `freeReflectConstructArgumentList` (`src/exec/reflect_ops.zig:212`)

- **签名**：`fn freeReflectConstructArgumentList(rt: *core.JSRuntime, values: []core.JSValue) void`。
- **作用**：释放 `reflectConstructArgumentList` 分配的参数切片。
- **实现**：长度为 0 时什么都不做（空切片不是堆分配），否则 `rt.memory.free(core.JSValue, values)`。
- **所有权 / 错误 / 调用**：只被 `ReflectConstructArguments.deinit` 调用。

### `isConstructorValue` (`src/exec/reflect_ops.zig:216`)

- **签名**：`fn isConstructorValue(rt: *core.JSRuntime, value: core.JSValue) bool`。
- **作用**：判断一个值能不能当 `Reflect.construct` 的 target / new.target 用。
- **实现**：先 `value_ops.isFunctionObject` 过滤，再 `thisObject` 取对象；是 proxy 就对 `proxyTarget()` 递归。然后按 `object.class_id` 分：`c_function` 时，host entry function 看有没有自有 `prototype` 属性；否则先用 `decodeNativeBuiltinId` + `builtin_dispatch.isConstructRecordRef` 探记录表（带 construct 记录的 Date/RegExp/String 直接算构造器，不依赖名字），探不到才退回名字集合 `isBuiltinConstructorName`（取名失败返回 false，取到则 defer free）。`bytecode_function`、`c_closure`、`bound_function` 一律 true，其余 class 为 false。
- **所有权 / 错误 / 调用**：不返回错误（取名字失败就地吞掉）；名字缓冲在函数内 defer 释放；调用方是 `reflectConstruct` 的两处入参校验。

### `reflectConstructPrototype` (`src/exec/reflect_ops.zig:244`)

- **签名**：`fn reflectConstructPrototype(ctx: *core.JSContext, target_name: []const u8, new_target: core.JSValue) !object_ops.OwnedPrototype`。
- **作用**：解析新实例的 `[[Prototype]]`：优先取 new.target 的 `prototype`，否则退到 new.target 所在 realm 的内建原型。
- **实现**：`thisObject(new_target)` 失败 → `error.TypeError`；读 `core.atom.ids.prototype`，是对象就直接包成 `OwnedPrototype{ .value = ... }` 返回。否则 `call_runtime.functionRealmContext(ctx, new_target)` 取 fallback realm：先试 `object_ops.constructorClassPrototypeId(target_name)` 查内建类原型，再试 `object_ops.nativeErrorKindFromConstructorName(target_name)` 查原生 Error 原型——两者查到 id 但 realm 里拿不到对象时返回 `error.InvalidBuiltinRegistry`；都不匹配则返回 `OwnedPrototype.fromObject(null)`（无原型）。
- **所有权 / 错误 / 调用**：返回的 `OwnedPrototype` 由调用方 `defer prototype.deinit(rt)`；只被 `reflectConstruct` 的各分支调用。

### `proxyRevocable` (`src/exec/reflect_ops.zig:260`)

- **签名**：`pub fn proxyRevocable(rt: *core.JSRuntime, global: ?*core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Proxy.revocable(target, handler)`：建一个 proxy 与一个 revoke 闭包，装进 `{ proxy, revoke }` 结果对象。
- **实现**：实参少于 2 个或 `global` 为 null → `error.TypeError`；`core.runtime.ValueRootBuffer.initCopy` 复制实参，装进 `ValueRootSlice` / `ValueRootFrame` 并 `activate`，保证后续分配窗口里两个参数不被回收；两个参数都要过 `expectObjectArg`。接着 `core.Object.create(rt, core.class.ids.object, null)` 建结果对象（errdefer 销毁），`core.Object.create(rt, core.class.ids.proxy, null)` 建 proxy，`ensureProxyPayload` 后把 target / handler 写进 `proxyTargetSlot` / `proxyHandlerSlot`，`defineObjectProperty(..., core.atom.ids.proxy, ...)` 成功后把 `proxy_raw_owned` 置 false 交出所有权。revoke 侧：从 realm global 取 `functionPrototypeFromGlobal`（缺失 → `error.InvalidBuiltinRegistry`），`core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 0)` 造一个空名、length 0 的 data function，直接把 `nativeFunctionIdSlot().*` 写成 `nativeBuiltinId(.reflect, StaticMethod.proxy_revoke)`（data carrier 故意不进真 C-function 记录缓存，由 dispatch 的 caller-data 臂解码这个稳定 id），再把 proxy 存进 `functionProxyRevokeTargetSlot`，最后 define 成 `revoke` 属性。对应 QuickJS `js_proxy_revocable` 用 `JS_NewCFunctionData` 的做法：revoker 是带捕获数据的 callable，在调用方 realm 里执行。
- **所有权 / 错误 / 调用**：半成品结果对象与 proxy 由 errdefer `destroyFromHeader` 兜底，proxy 的所有权在挂上属性后转移给结果对象；根缓冲与根帧都 defer 撤销；调用方是 `reflect_proxy_ops.reflectCall` 的 `proxy_revocable` 臂。

### `revokeProxy` (`src/exec/reflect_ops.zig:306`)

- **签名**：`pub fn revokeProxy(rt: *core.JSRuntime, function_object: *core.Object) !core.JSValue`。
- **作用**：`Proxy.revocable` 返回的 revoke 闭包体：清掉被捕获 proxy 的 handler，使之后的 trap 查找抛错。
- **实现**：取 `function_object.functionProxyRevokeTargetSlot(rt)`，`takeOptionalValueSlot` 把 proxy 取出**并清空**槽位——因此第二次调用拿不到值，直接返回 `undefined`（幂等）；拿到后 `thisObject` 取对象，`clearOptionalValueSlot(rt, proxy.proxyHandlerSlot())` 清 handler；无论哪条路径都返回 `undefined`。对照 QuickJS `js_proxy_revoke`。
- **所有权 / 错误 / 调用**：不新分配；错误只可能来自槽位获取；调用方是 `reflect_proxy_ops.reflectCall` 的 `proxy_revoke` 臂（它负责取 `func_obj`）。

### `isBuiltinConstructorName` (`src/exec/reflect_ops.zig:314`)

- **签名**：`fn isBuiltinConstructorName(name: []const u8) bool`。
- **作用**：按名字判断一个 native 函数是不是内建构造器。
- **实现**：一长串 `std.mem.eql` 的或运算：Object / Function / AsyncFunction / GeneratorFunction / AsyncGeneratorFunction / Array / String / Number / Boolean / Symbol / BigInt / Date / RegExp，加上 `core.error_names.isErrorConstructorName(name)`，再加 Iterator / DisposableStack / AsyncDisposableStack / Promise / Map / Set / WeakMap / WeakSet / ArrayBuffer / DataView；全不匹配返回 false。
- **所有权 / 错误 / 调用**：纯谓词；本文件里只被 `isConstructorValue` 调用。注意 `src/exec/call_runtime.zig:2527` 另有一个同名的 `pub` 版本，两者是各自独立的实现。

### `reflectCallForNativeRecord` (`src/exec/reflect_ops.zig:341`)

- **签名**：`pub fn reflectCallForNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：13 个 `Reflect.*` 静态方法的总分派：按记录 id 转到各自实现。
- **实现**：`switch (id)` 到 `StaticMethod`：`define_property` → `object_ops.definePropertyWithKind(..., kind = 2, ...)`（`kind` 选失败语义：`Object.defineProperty` 传 1 会抛 TypeError，`Reflect.defineProperty` 传 2 则返回 `false`）、`get_own_property_descriptor` / `delete_property` / `get_prototype_of` / `set_prototype_of` → `object_ops` 里对应的 `reflect*Call`、`get` / `set` / `is_extensible` / `prevent_extensions` / `has` / `own_keys` / `construct` → 本文件的同名 `reflect*Call`、`apply` → `reflectApplyCall`。除 `apply` 外每个子调用都返回 `?core.JSValue`，null 一律折成 `error.TypeError`；未知 id 也是 `error.TypeError`。
- **所有权 / 错误 / 调用**：本身不分配，返回值归调用方；唯一调用方是 `reflect_proxy_ops.reflectCall`（已先剥掉 `proxy_revocable` / `proxy_revoke` 两个 id）。

### `reflectSetCall` (`src/exec/reflect_ops.zig:369`)

- **签名**：`pub fn reflectSetCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.set(target, key, value, receiver)`：按规范的 `[[Set]]` 语义写属性并返回布尔结果。
- **实现**：无实参 → `error.TypeError`；`set_value` 取 `args[2]`（缺省 undefined），`args[0]` 必须过 `property_ops.expectObject`（失败转 TypeError），key 取 `args[1]`（缺省 undefined）经 `object_ops.toPropertyKeyAtom` 变成 atom。module namespace 对象一律返回 `false`。主分支是「不是数组的 `length` 键」：receiver 取 `args[3]`，缺省用 `args[0]`；target 是 proxy → `object_ops.proxySetValueProperty` 的布尔结果；target 是 TypedArray 时按 `typedArrayCanonicalNumericIndex` 三态处理——`.invalid` 且 receiver 与 target 同一对象仍要把 value 强制转换一遍（`coerceTypedArrayElementInput` + `typed_array.typedArrayCoerceElementValue`，保留可观察副作用）然后返回 `true`；`.index` 且同一对象则先 `coerceTypedArrayElementForSet`，索引失效返回 `true`、buffer immutable 返回 `false`，否则 `typedArraySetElement` 后 `true`；`.index` 但 receiver 不同则索引失效返回 `true`、receiver 非对象返回 `false`，否则交 `array_ops.typedArrayReflectSetReceiverOwn`。再往下若 receiver 是对象，先试 `array_ops.typedArrayPrototypeSet`（target 是 TypedArray 原型的情形），最后统一 `call_runtime.ordinarySetWithReceiver`。数组 `length` 分支：按 qjs `JS_SetPropertyInternal`，`obj != this_obj` 时 `if (unlikely(p != p1)) goto retry2`（quickjs.c:9701-9702）会跳过 `JS_PROP_LENGTH` / `set_array_length` 臂（9714-9717）走通用 receiver 路径（9892-9929），所以这里当 `args.len >= 4` 且 `args[3]` 与 `args[0]` 不是同一对象时直接 `ordinarySetWithReceiver`；否则 `array_ops.arrayLengthAssignmentValue` 算出要写的值再 `object.setProperty`，把 `ReadOnly` / `AccessorWithoutSetter` / `NotExtensible` / `IncompatibleDescriptor` 折成 `false`、`InvalidLength` 转成 `error.RangeError`，其余错误上抛，成功返回 `true`。
- **所有权 / 错误 / 调用**：不分配长期缓冲；返回 `?core.JSValue` 且实际从不返回 null，调用方 `reflectCallForNativeRecord` 仍把 null 折成 TypeError。

### `reflectIsExtensibleCall` (`src/exec/reflect_ops.zig:440`)

- **签名**：`pub fn reflectIsExtensibleCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.isExtensible(target)`：只是在 `Object.isExtensible` 之上加了「必须是对象」的前置校验。
- **实现**：无实参 → `error.TypeError`；`!args[0].isObject()` → `error.TypeError`（这正是 `Reflect.isExtensible` 与对原始值返回 `false` 的 `Object.isExtensible` 的差别）；其余全部转发 `object_ops.objectIsExtensibleCall`，由它处理 proxy trap。
- **所有权 / 错误 / 调用**：不分配；调用方是 `reflectCallForNativeRecord` 的 `is_extensible` 臂。

### `reflectPreventExtensionsCall` (`src/exec/reflect_ops.zig:453`)

- **签名**：`pub fn reflectPreventExtensionsCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.preventExtensions(target)`：返回布尔而不是抛错。
- **实现**：无实参 → `error.TypeError`；`object_ops.objectFromValue` 取不到对象 → `error.TypeError`；target 是 proxy 时把 `object_ops.proxyAwarePreventExtensions` 的布尔结果原样返回（trap 说失败就是 `false`）；普通对象直接 `object.preventExtensions()` 并返回 `true`。
- **所有权 / 错误 / 调用**：不分配；调用方是 `reflectCallForNativeRecord` 的 `prevent_extensions` 臂。

### `reflectConstructCall` (`src/exec/reflect_ops.zig:470`)

- **签名**：`pub fn reflectConstructCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：有 VM global 时的 `Reflect.construct`：展开 argumentsList 后交给 VM 的构造分派器。
- **实现**：实参少于 2 个或 `call_runtime.isConstructorLike(args[0])` 为假 → `error.TypeError`；`new_target` 取 `args[2]`（缺省 `args[0]`），同样要过 `isConstructorLike`。`array_ops.argsFromArrayLike` 把 `args[1]` 展开成参数切片，`defer call_runtime.freeArgs` 释放，并用 `ValueSliceRoot` 钉住。随后一个 TypedArray 专用前置：target 是非 proxy 对象时取 `call_mod.nativeFunctionNameForVm`（defer free），名字命中 `construct_mod.typedArrayElement` 就先跑 `array_ops.typedArrayValidateConstructArgsPreAllocate`，让参数强制转换的副作用发生在分配之前。最后 `call_runtime.constructValueOrBytecodeWithNewTarget(..., args[0], construct_args, ..., new_target)`。
- **所有权 / 错误 / 调用**：参数切片与名字缓冲都在本函数 defer 释放；调用方是 `reflectCallForNativeRecord` 的 `construct` 臂。

### `reflectHasCall` (`src/exec/reflect_ops.zig:498`)

- **签名**：`pub fn reflectHasCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.has(target, key)`，即 `key in target` 的反射形式。
- **实现**：实参少于 2 个 → `error.TypeError`；`objectFromValue(args[0])` 取不到对象 → `error.TypeError`；`toPropertyKeyAtom` 转 key。target 是 proxy 走 `object_ops.hasValueProperty`（带 trap 分派），否则走 `object_ops.ordinaryHasValueProperty(..., false, ...)`，结果包成 `core.JSValue.boolean`。
- **所有权 / 错误 / 调用**：不分配；调用方是 `reflectCallForNativeRecord` 的 `has` 臂。

### `reflectApplyCall` (`src/exec/reflect_ops.zig:516`)

- **签名**：`pub fn reflectApplyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Reflect.apply(target, thisArgument, argumentsList)`。
- **实现**：无实参或 `args[0]` 不可调用时走 `exception_ops.throwTypeErrorMessage(ctx, global, "not a function")`（带消息的异常，不是裸 `error.TypeError`）；不足 3 个实参 → `error.TypeError`。`array_ops.ownedArgsFromArrayLike(args[2])` 展开参数（defer deinit）；参数为空时直接 `call_runtime.callValueOrBytecodeSyncInternal`，this 为 `args[1]`、callee 为 `args[0]`、实参空切片；非空时先 `ValueSliceRoot` 钉住再走 `call_runtime.callOwnedArgsValueOrBytecodeSyncInternal`。
- **所有权 / 错误 / 调用**：参数缓冲归 `owned_args`，defer 释放；这是唯一返回非可选值的 `Reflect.*` 分支，`reflectCallForNativeRecord` 对它直接 `try`。

### `reflectGetCall` (`src/exec/reflect_ops.zig:554`)

- **签名**：`pub fn reflectGetCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Reflect.get(target, key, receiver)`：带显式 receiver 的属性读取。
- **实现**：实参少于 2 个 → `error.TypeError`；`objectFromValue(args[0])` 取不到对象 → `error.TypeError`；`toPropertyKeyAtom` 转 key；receiver 取 `args[2]`，缺省用 `args[0]`；转发 `object_ops.getValuePropertyWithReceiver`，由它处理 proxy trap 与 getter 的 this 绑定。
- **所有权 / 错误 / 调用**：不分配；调用方除 `reflectCallForNativeRecord` 的 `get` 臂外无其它。

### `reflectOwnKeysCall` (`src/exec/reflect_ops.zig:569`)

- **签名**：`pub fn reflectOwnKeysCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !?core.JSValue`（不接 caller_function / caller_frame）。
- **作用**：`Reflect.ownKeys(target)`：把自有键列表物化成一个新数组。
- **实现**：无实参 → `error.TypeError`；`property_ops.expectObject(args[0])` 失败也转 `error.TypeError`；`object_ops.objectRestOwnKeys` 取 atom 列表（defer `core.Object.freeKeys`）；`core.Object.createArray` 以 `array_ops.arrayPrototypeFromGlobal` 为原型建结果数组（errdefer 销毁）；逐个 `object_ops.proxyTrapKeyValue` 把 atom 转成字符串 / symbol 值，再 `defineOwnProperty` 到当前 `out.arrayLength()` 下标，描述符为 `Descriptor.data(key_value, true, true, true)`（writable / enumerable / configurable 全开）。
- **所有权 / 错误 / 调用**：keys 列表与结果数组的失败路径都有 defer / errdefer 兜底；结果数组归调用方；调用方是 `reflectCallForNativeRecord` 的 `own_keys` 臂。

## `src/exec/reflect_proxy_ops.zig` — Reflect 记录表

`.reflect` domain：13 个 Reflect.* + Proxy.revocable + revoke。`reflectCall` 要求可观察调用的 `callableRealm`。（原先还有一个 src 内无使用方的 `ownKeys` 转发与遗留占位类型 `RevocableProxy`（只翻一个 `revoked` 布尔，与真正生效的 `reflect_ops.revokeProxy` 无关联），已删除。）


### `methodId` (`src/exec/reflect_proxy_ops.zig:18`)

- **签名**：`pub fn methodId(name: []const u8) ?u32`。
- **作用**：把安装期看到的 JS 方法名映射到 `.reflect` domain 的记录 id。
- **实现**：一串 `std.mem.eql` 覆盖 13 个 `Reflect.*` 名字（`defineProperty` / `getOwnPropertyDescriptor` / `deleteProperty` / `get` / `getPrototypeOf` / `set` / `setPrototypeOf` / `isExtensible` / `preventExtensions` / `has` / `ownKeys` / `construct` / `apply`），返回对应的 `StaticMethod` 值；全不匹配返回 null。注意它**不**认 `proxy_revocable` / `proxy_revoke`——前者由 `standard_globals`（`src/exec/standard_globals.zig:370`）直接按 id 绑定，后者的 id 由 `reflect_ops.proxyRevocable` 在造 revoke data function 时写进 `nativeFunctionIdSlot`。
- **所有权 / 错误 / 调用**：纯映射；`standard_globals` 的 Reflect 安装路径用它解析名字与 id。

### `reflectEntry` (`src/exec/reflect_proxy_ops.zig:69`)

- **签名**：`fn reflectEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：构造一条 `InternalEntry`：名字、length、id/magic、cproto 与 native 函数指针。
- **实现**：`.magic = @intCast(id)`（id 兼作 magic，记录不再带别的选择子），`.cproto = .generic_magic`，`.native_function = builtin_dispatch.genericMagicFunction(&reflectCall)`——15 条记录共享同一个处理函数。
- **所有权 / 错误 / 调用**：comptime 求值，无运行期所有权。

### `reflectCall` (`src/exec/reflect_proxy_ops.zig:86`)

- **签名**：`fn reflectCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：该 domain 的 NativeEntry 处理函数：从 `nativeCall` 恢复执行环境后按 magic/id 转发到实现。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。随后**无条件**取 `callableRealm`（该 domain 的 15 条记录全是可观察 callable，没有 func-object-free 的算法复用），断言 `realm.realm == ctx`。 随后按 magic 三分：`proxy_revoke` 取 `host_call.func_obj`（缺失则 `error.TypeError`）调 `reflect_ops.revokeProxy(ctx.runtime, function_object)`；`proxy_revocable` 调 `reflect_ops.proxyRevocable(ctx.runtime, global, args)`，按 qjs `js_proxy_revocable`（quickjs.c:51502）的 `JS_CFUNC_DEF` 语义完全不读 this_val，所以解绑调用也合法；其余 13 个 `Reflect.*` 统一转发 `reflect_ops.reflectCallForNativeRecord(ctx, output, global, id, args, caller_function, caller_frame)`。
- **所有权 / 错误 / 调用**：本层不分配、不建根：`args`/`this` 借用调用帧，返回值由被转发的 `reflect_ops.*` 产生并留在 managed 帧里。`HostError` 就是 `core.errors.RuntimeError`（`src/core/errors.zig:88`）：`nativeCall` 恢复失败或 `func_obj` 缺失时直接 `error.TypeError`，由边界的 `materializeRuntimeError` 变成 JS TypeError；被转发实现自己抛异常时返回 `error.JSException`，此时 pending exception 已挂好，边界只做传递。本函数不被直接调用，而是以 `builtin_dispatch.genericMagicFunction(&reflectCall)` 登记为 `.reflect` domain 的 NativeEntry（`src/exec/reflect_proxy_ops.zig:76`）。

## 覆盖核对

- 清单函数数: 126（`src/exec/collection_adapter.zig` 3 + `src/exec/collection_ops.zig` 100 + `src/exec/reflect_ops.zig` 20 + `src/exec/reflect_proxy_ops.zig` 3）
- 本文标题覆盖: 126
- 未覆盖: 无
