# 15 — `iterator_builtin_ops.zig`：Iterator record 表

## 类型

- `AccessorMethod` / `StaticMethod` / `PrototypeMethod` / `IntrinsicMethod`：re-export `builtin_method_ids.iterator`。
- `internal_entries`：constructor/toStringTag accessor、from/concat/zip*、toArray/every/find/forEach/reduce/some/map/filter/take/drop/flatMap、`@@dispose`、以及 Array Iterator.next 与 Generator.next/return/throw。全部 `generic_magic` 到 `iteratorCall`。

### `staticMethodId` (`src/exec/iterator_builtin_ops.zig:21`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：把 `Iterator` 静态方法名映射成 `.iterator` 域内 id，供 standard-global 安装时解析名字。
- **实现**：四条 `std.mem.eql` 比较：`from` / `concat` / `zip` / `zipKeyed` → 对应 `StaticMethod` 枚举值；其余返回 `null`。
- **所有权 / 错误 / 调用**：无所有权、无 error set：`name` 只被 `std.mem.eql` 读，返回的是 `StaticMethod` 的枚举序号。唯一调用方 `standard_globals.zig:437`，而且**只在 comptime 跑**：`preparedMethods` 建 `iterator_static` 表（`standard_globals.zig:2540`）时逐条解析名字，`setRequiredMethodNativeBuiltinId` 对 `null` 直接 `@compileError`，所以「名字打错」是编译期失败而不是运行期缺方法。

### `prototypeMethodId` (`src/exec/iterator_builtin_ops.zig:29`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `Iterator.prototype` 方法名映射成 `.iterator` 域内 id。
- **实现**：十一条 `std.mem.eql`：`toArray`/`every`/`find`/`forEach`/`reduce`/`some`/`map`/`filter`/`take`/`drop`/`flatMap` → 对应 `PrototypeMethod`；其余 `null`（`[Symbol.dispose]` 不走这里，由 standard-global 单独用枚举 id 装）。
- **所有权 / 错误 / 调用**：同 `staticMethodId`：无所有权、无 error，comptime 专用。唯一调用方 `standard_globals.zig:438` 建 `iterator_prototype` 表（`:2547`）；`[Symbol.dispose]` 不在此表，由 `standard_globals.zig:544` 的 `iterator_dispose_auto_init` 用 `PrototypeMethod.dispose` 枚举直接钉 id。

### `iteratorEntry` (`src/exec/iterator_builtin_ops.zig:83`)

- **签名**：`fn iteratorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：`internal_entries` 那张表的逐行构造器——把一个 `.iterator` 域方法（`Iterator.from`/`concat`/`zip`/`zipKeyed`、`Iterator.prototype` 的 `map`/`filter`/`take`/`drop`/`flatMap`/`reduce`/`toArray` 等、`constructor` 与 `@@toStringTag` 的 getter/setter、`@@dispose`，以及 Array Iterator / Generator 的 `next`/`return`/`throw` intrinsic）压成一条 `InternalEntry` 记录。
- **实现**：填 `InternalEntry`：`name`/`length` 原样，`id = id`，`magic = @intCast(id)`，`cproto = .generic_magic`，`native_function = builtin_dispatch.genericMagicFunction(&iteratorCall)`——整张表共享同一 handler，靠 magic 区分。
- **所有权 / 错误 / 调用**：comptime 构造器：返回的 `InternalEntry` 是 `internal_entries` 数组的一个元素，全程只读静态数据，不分配、无 error set。整张表共用同一个 `&iteratorCall` 函数指针，靠 `magic`（== 域内 id）区分记录；表最终被 `internal_builtins.zig:151` 的 `recordTable(&iterator.internal_entries)` 收进 `.iterator` 域的 `EntryTable`，由 `installStandardGlobals` 挂到 `JSRuntime.internal_builtins`。唯一调用点是本文件 `:68`–`:91` 那 24 行表项。

### `iteratorCall` (`src/exec/iterator_builtin_ops.zig:100`)

- **签名**：`fn iteratorCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.iterator` 域全部 record 共享的 handler：解析 realm 与 caller 上下文后，把 magic（域内 id）转交 `iterator_ops.iteratorCallForNativeRecord`。
- **实现**：`builtin_dispatch.nativeCall` 解出 host_call（失败即 `error.TypeError`），`callableRealm` 取当前 realm（用 `realm.realm` 作 ctx、`realm.global` 作 global），`host_call.magic` 当域内 id，再取 `callerBytecode` / `callerFrame`，转发 `iterator_ops.iteratorCallForNativeRecord`；返回 `null` 表示 id 无对应 handler（只可能是 id 损坏），转成 `error.TypeError`。
- **所有权 / 错误 / 调用**：不分配、不持有：`host_call.args`/`this_value` 是调用方栈上的借用切片与值，返回值由 `iterator_ops.iteratorCallForNativeRecord` 铸出并直接交给 native 调用缝（记为 owned）。error set 是 `HostError`：`nativeCall` 拿不到活动 native 环境、`iteratorCallForNativeRecord` 对未知 id 返回 null 都变 `error.TypeError`，`callableRealm` 另有 `error.InvalidBuiltinRegistry`，其余由被调用方透传；这些 Zig error 在 native 入口由 `builtin_dispatch.nativeFromHostError` → `materializeRuntimeError` → `createSentinelError` 变成 JS 异常并返回异常哨兵（堆耗尽时退回 realm 预分配的 OOM 值）。生产调用方不是源码里的某一行，而是 `internal_entries` 里 24 条记录的 `native_function` 指针，由 record dispatch 间接进入。

## 覆盖核对

- 清单函数数: 4
- 本文标题覆盖: 4
- 未覆盖: 无
