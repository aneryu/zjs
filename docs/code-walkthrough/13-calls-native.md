# 13 — native_legacy：InternalEntry → NativeEntry

`native_legacy.zig` 是 NB2 边界 Phase A2（`docs/perf/native-boundary-design.md` §3.3）：把遗留 `InternalEntry`（qjs `cproto` + 返回 `HostError!JSValue` 的 Zig 体）在 **comptime** 收成 `NativeEntry`，`target` 是 `callconv(.c)` thunk。每条 builtin 零手工改；以前 `dispatchTypedRecord` 运行时 switch 的签名转换现在按 entry 编进 thunk。遗留体仍可读 `builtin_dispatch.nativeCall`，所以这里产出的 entry 带 `flags.needs_env`（A4 按普查剥离）。

## 类型与签名

`LeafSig` 是引擎私有枚举（定义在 `src/core/native_entry.zig`），`.none` 表示 managed。本文件再导出 `sig_*` 别名：`void_to_void`、`i32_to_i32`、`f64_to_f64`、`f64_f64_to_f64`、`bool_to_bool`、`state_*`、`string_i32_to_*`、`self_*`（K2 方法叶，`self` 是 NativeObject payload）。

对应 C 原型类型：`LeafF64ToF64` 等。`string_i32_to_i32` 负返回表示形状不匹配，走 fallback。

---

### `args` (`src/exec/native_legacy.zig:70`)

- **签名**：`inline fn args(argv: [*]const JSValue, argc: u32) []const JSValue`。
- **作用**：C ABI 指针+长度切成 Zig slice。
- **实现**：`argv[0..argc]`。
- **所有权 / 错误 / 调用**：借用操作数窗口。

### `managedGeneric` (`src/exec/native_legacy.zig:75`)

- **签名**：`fn managedGeneric(comptime body: core.host_function.NativeGenericFn) core.native_entry.ManagedFn`。
- **作用**：包 `generic` 体为 managed thunk。
- **实现**：返回匿名 struct 的 `thunk` 指针。
- **所有权 / 错误 / 调用**：`entryFromInternal` 的 `.generic` / constructor 臂。

### `managedGeneric.thunk` (`src/exec/native_legacy.zig:77`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object) callconv(.c) JSValue`。
- **作用**：调 `body(ctx, this, args)`，`HostError` 映成哨兵。
- **实现**：忽略 entry/func_obj；`hostResultToValue`。
- **所有权 / 错误 / 调用**：Zig 错误集不跨界。

### `managedGenericMagic` (`src/exec/native_legacy.zig:85`)

- **签名**：`fn managedGenericMagic(comptime body: core.host_function.NativeGenericMagicFn) core.native_entry.ManagedFn`。
- **作用**：带 `entry.magic` 的 generic。
- **实现**：同结构，多传 `@intCast(entry.magic)`。
- **所有权 / 错误 / 调用**：comptime 工厂，返回指向匿名 struct 内 `thunk` 的静态函数指针，不分配。调用方 `entryFromInternal` 的 `.generic_magic` / `.constructor_magic` / `.constructor_or_func_magic` 三臂（`native_legacy.zig:176`/`184`/`192`），以及 `f_f`/`f_f_f` 的 `fallback` 字段（`216`/`223`）。

### `managedGenericMagic.thunk` (`src/exec/native_legacy.zig:87`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object) callconv(.c) JSValue`。
- **作用**：magic generic 的 C 入口。
- **实现**：`body(..., magic)` → `hostResultToValue`。
- **所有权 / 错误 / 调用**：`argv[0..argc]` 是借用的操作数窗口，thunk 不分配也不建 GC 根。Zig error set 不跨 C ABI：`body` 的 `HostError` 由 `builtin_dispatch.hostResultToValue` 经 `nativeFromHostError` → `materializeRuntimeError` 写成 `ctx` 上的 pending 异常，返回值降为 exception 哨兵；OOM 走同一条路。调用方只有 `entry.target` 的间接调用。

### `getterThunk` (`src/exec/native_legacy.zig:94`)

- **签名**：`fn getterThunk(comptime body: core.host_function.NativeGetterFn) core.native_entry.GetterFn`。
- **作用**：无 magic getter。
- **实现**：包 `body(ctx, this)`。
- **所有权 / 错误 / 调用**：comptime 工厂，产静态 thunk 指针，不分配。唯一调用方 `entryFromInternal` 的 `.getter` 臂（`native_legacy.zig:196`）。

### `getterThunk.thunk` (`src/exec/native_legacy.zig:96`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：getter C 入口。
- **实现**：忽略 entry；`hostResultToValue`。
- **所有权 / 错误 / 调用**：不分配、不建根。`body` 的 `HostError` 经 `hostResultToValue` 变成 `ctx` 的 pending 异常 + exception 哨兵返回值（error set 不跨 C ABI）。只由属性读取路径经 `entry.target` 间接调用。

### `getterMagicThunk` (`src/exec/native_legacy.zig:103`)

- **签名**：`fn getterMagicThunk(comptime body: core.host_function.NativeGetterMagicFn) core.native_entry.GetterFn`。
- **作用**：magic getter。
- **实现**：传 `entry.magic`。
- **所有权 / 错误 / 调用**：comptime 工厂，产静态 thunk 指针。唯一调用方 `entryFromInternal` 的 `.getter_magic` 臂（`native_legacy.zig:200`）。

### `getterMagicThunk.thunk` (`src/exec/native_legacy.zig:105`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：magic getter C 入口。
- **实现**：`body(ctx, this, magic)`。
- **所有权 / 错误 / 调用**：不分配、不建根；magic 从 `entry` 借读。错误协议同 `getterThunk.thunk`：`HostError` → pending 异常 + 哨兵。

### `setterThunk` (`src/exec/native_legacy.zig:111`)

- **签名**：`fn setterThunk(comptime body: core.host_function.NativeSetterFn) core.native_entry.SetterFn`。
- **作用**：无 magic setter。
- **实现**：包 `body(ctx, this, new_value)`。
- **所有权 / 错误 / 调用**：comptime 工厂，产静态 thunk 指针。唯一调用方 `entryFromInternal` 的 `.setter` 臂（`native_legacy.zig:204`）。

### `setterThunk.thunk` (`src/exec/native_legacy.zig:113`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：setter C 入口。
- **实现**：忽略 entry。
- **所有权 / 错误 / 调用**：`new_value` 借用，不 retain 也不建根；thunk 自身不分配。`HostError` 经 `hostResultToValue` 落成 pending 异常 + exception 哨兵。

### `setterMagicThunk` (`src/exec/native_legacy.zig:120`)

- **签名**：`fn setterMagicThunk(comptime body: core.host_function.NativeSetterMagicFn) core.native_entry.SetterFn`。
- **作用**：magic setter。
- **实现**：传 magic。
- **所有权 / 错误 / 调用**：comptime 工厂，产静态 thunk 指针。唯一调用方 `entryFromInternal` 的 `.setter_magic` 臂（`native_legacy.zig:208`）。

### `setterMagicThunk.thunk` (`src/exec/native_legacy.zig:122`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：magic setter C 入口。
- **实现**：`body(..., magic)`。
- **所有权 / 错误 / 调用**：同 `setterThunk.thunk`，另从 `entry.magic` 借读一个立即数；错误仍经 `hostResultToValue` 变 pending 异常 + 哨兵。

### `leafF64` (`src/exec/native_legacy.zig:128`)

- **签名**：`fn leafF64(comptime body: core.host_function.NativeF64Fn) LeafF64ToF64`。
- **作用**：qjs `f_f`：`double f(double)`，VM 侧拆箱。
- **实现**：C thunk 直接调 body。
- **所有权 / 错误 / 调用**：不抛、不分配。

### `leafF64.thunk` (`src/exec/native_legacy.zig:130`)

- **签名**：`fn thunk(x: f64) callconv(.c) f64`。
- **作用**：`f_f` 叶。
- **实现**：`return body(x)`。
- **所有权 / 错误 / 调用**：叶 ABI 没有 `ctx`：不能抛、不能分配、不接触堆，返回值是纯 `f64`，异常只能由 VM 侧在拆箱失败时走 `entry.fallback`。

### `leafF64F64` (`src/exec/native_legacy.zig:136`)

- **签名**：`fn leafF64F64(comptime body: core.host_function.NativeF64F64Fn) LeafF64F64ToF64`。
- **作用**：qjs `f_f_f`。
- **实现**：两 double。
- **所有权 / 错误 / 调用**：comptime 工厂，产静态 thunk 指针。唯一调用方 `entryFromInternal` 的 `.f_f_f` 臂（`native_legacy.zig:219`）。

### `leafF64F64.thunk` (`src/exec/native_legacy.zig:138`)

- **签名**：`fn thunk(x: f64, y: f64) callconv(.c) f64`。
- **作用**：`f_f_f` 叶。
- **实现**：`body(x, y)`。
- **所有权 / 错误 / 调用**：同 `leafF64.thunk`：无 `ctx`、不抛不分配；参数类型不匹配时由 VM 改走 `entry.fallback`（`managedGenericMagic` 包的 coercion 体）。

### `entryFromInternal` (`src/exec/native_legacy.zig:147`)

- **签名**：`pub fn entryFromInternal(comptime e: InternalEntry) NativeEntry`。
- **作用**：声明→entry 的唯一映射；按 distinct InternalEntry comptime 记忆化，同 body 共享 thunk 指针（身份检查依赖）。
- **实现**：缺 native_function / tag≠cproto / 非数值 cproto 带 fallback / 构造器带 managed → `@compileError`。基底 `kind=.managed`、`needs_env=true`、`arity=e.length`、`magic=e.magic`。若 `e.managed`：直接 code(body)，`needs_env=false`，再 `primLeafOrManaged`。否则按 cproto：generic / generic_magic / constructor* / getter* / setter* 走对应 thunk；`f_f`/`f_f_f` 设 `.leaf`、sig、`Effect.leaf`、可选 fallback。
- **所有权 / 错误 / 调用**：builtin 表在 comptime 填 `NativeEntry`。

### `primLeafOrManaged` (`src/exec/native_legacy.zig:233`)

- **签名**：`fn primLeafOrManaged(comptime e: InternalEntry, comptime managed_entry: NativeEntry) NativeEntry`。
- **作用**：Lane K：有 `prim_leaf` 时把刚建的 managed thunk 变成 tag-miss fallback，叶 target/sig 进热字段。
- **实现**：无 prim_leaf 原样返回。要求 managed kind 且 `leaf.sig != .none`。`kind=.method_leaf`；effect：不抛、不重入 JS、读堆；`string_i32_to_string` 才 `may_alloc`。
- **所有权 / 错误 / 调用**：`charCodeAt` 一类方法叶。

### `genericEntry` (`src/exec/native_legacy.zig:255`)

- **签名**：`pub fn genericEntry(comptime body: core.host_function.NativeGenericFn, comptime length: u8) NativeEntry`。
- **作用**：测试/嵌入：无表的裸 generic。
- **实现**：`managedGeneric(body)`，`needs_env=true`，`arity=length`。
- **所有权 / 错误 / 调用**：仓内测试。

## 覆盖核对

- 清单函数数: 20
- 未覆盖: 无
