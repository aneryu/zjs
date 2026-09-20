# 20 — core 值 / 对象 / GC / atom / bigint

`src/tests/core.zig` 覆盖 shape/属性、tracing GC、FinalizationRegistry、弱集合与跨模块运行时合同。叶子合同（atom 表、string 布局、MemoryAccount、VmStackArena、array_list_erased、heap/kernel BigInt、Object handle/payload、shape 注册表、Runtime init-deinit）已回到对应生产文件。多数用例直接操 Runtime，而不是 `eval` 一整段脚本。 源文件 `src/tests/core.zig`（16294 行，447 个 `test` 块）。

## `src/tests/core.zig`

`src/tests/core.zig` 覆盖 shape/属性、tracing GC、FinalizationRegistry、弱集合与跨模块运行时合同。叶子合同（atom 表、string 布局、MemoryAccount、VmStackArena、array_list_erased、heap/kernel BigInt、Object handle/payload、shape 注册表、Runtime init-deinit）已回到对应生产文件。多数用例直接操 Runtime，而不是 `eval` 一整段脚本。

文件头：Exercises core value, object, GC, memory, and runtime primitives.

类型：本文件的 `fn` 几乎都是嵌在 `test` 里的探针 struct（`Probe.trigger` 在分配路径上强制 GC、`ModuleAutoInitFixture.resolve` 物化 MODULE_NS、各种 `visit*` 给 tracer 计数、OOM 注入 allocator）。bigint lockstep / 除法参考实现已随合同回到 `src/core/bigint.zig` 与 `src/libs/bigint.zig`。读函数节时按类型前缀对照周围测试块。

### 函数（清单 112）

### `Probe.trigger` (`src/tests/core.zig:15`)

- **签名**：`fn trigger(raw: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `Probe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只对 `size >= 4096` 的分配生效（小分配直接 `return`），命中后 `calls += 1`；先把 `self.rt.memory.trigger_gc_fn` 置 `null` 并用 `defer` 还原，避免 GC 内部分配再次回调本探针；再 `_ = self.rt.forceGC(null) catch { self.failed = true; }`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ModuleAutoInitFixture.resolve` (`src/tests/core.zig:155`)

- **签名**：`fn resolve( owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, atom_id: core.Atom, ) anyerror!core.property.AutoInitMaterialization`。
- **作用**：测试夹具/探针 `ModuleAutoInitFixture.resolve`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。关键调用：`@constCast`、`entry.holder.setProperty`。显式 `return error.InvalidBuiltinRegistry` / `error.OutOfMemory`。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.property.AutoInitMaterialization`，由测试 `try`/`expectError` 消费。

### `publishFreshModule` (`src/tests/core.zig:184`)

- **签名**：`fn publishFreshModule( registry: *core.module.Registry, module_name: core.Atom, pending: *core.module.PendingDefinition, ) !*core.ModuleRecord`。
- **作用**：测试夹具/探针 `publishFreshModule`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`registry.prepareFreshTarget`、`prepared.isFresh`、`prepared.record`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `!*core.ModuleRecord`，由测试 `try`/`expectError` 消费。

### `publishEmptyModule` (`src/tests/core.zig:194`)

- **签名**：`fn publishEmptyModule( rt: *core.JSRuntime, registry: *core.module.Registry, module_name: core.Atom, ) !*core.ModuleRecord`。
- **作用**：测试夹具/探针 `publishEmptyModule`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`defer` 释放本次成功路径上的临时资源。关键调用：`core.module.PendingDefinition.init`、`pending.deinit`、`publishFreshModule`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!*core.ModuleRecord`，由测试 `try`/`expectError` 消费。

### `pointerPayload.get` (`src/tests/core.zig:283`)

- **签名**：`fn get(value: core.JSValue) usize`。
- **作用**：测试夹具/探针 `pointerPayload.get`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`@bitCast`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Counter.visitValue` (`src/tests/core.zig:855`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Counter.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `context` `@ptrCast`/`@alignCast` 还原成 `*@This()`，`slot.as(.int) == marker` 时 `self.count += 1`；非 int32 槽不计数。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Counter.visitObject` (`src/tests/core.zig:860`)

- **签名**：`fn visitObject(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Counter.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：空实现：对象槽不参与计数，`RootVisitor` 的两个回调里只有值访问会加计数。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `TestJob.run` (`src/tests/core.zig:1228`)

- **签名**：`fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：测试夹具/探针 `TestJob.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Attempt.run` (`src/tests/core.zig:1318`)

- **签名**：`fn run(self: *@This()) void`。
- **作用**：测试夹具/探针 `Attempt.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：在非 owner 线程上依次试八个受线程约束的入口，把每次结果折成 `err == error.WrongRuntimeThread` 的布尔写回 `self`：`rt.requireOwnerThread`、`core.RealmContext.create`（意外成功时把 context 存进 `unexpected_context`）、`self.constructing.finishConstructionChecked`、`self.live.tryDestroy`（成功走 `context_destroy_succeeded`）、`rt.classes.register`、`rt.classes.tryUnregisterDynamic`、`rt.ensureContextClassPrototypeCapacity`、`rt.pollGCChecked(null, .urgent)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Worker.run` (`src/tests/core.zig:1394`)

- **签名**：`fn run(self: *@This()) void`。
- **作用**：测试夹具/探针 `Worker.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。`defer` 释放本次成功路径上的临时资源。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`core.JSRuntime.create`、`rt.destroy`、`self.shared_slot.getOrAllocate`、`rt.newClassId`。
- **所有权 / 错误 / 调用**：每个 worker 线程自建一个走 `std.heap.page_allocator` 的 Runtime（`std.testing.allocator` 不跨线程用），并以 `defer rt.destroy()` 在本线程内销毁；不共享引擎。无独立 error set 时失败以断言或 panic 终止测试，失败只写 `self.failed` 留给主线程断言。

### `liveRealmCount` (`src/tests/core.zig:1551`)

- **签名**：`fn liveRealmCount(rt: *core.JSRuntime) usize`。
- **作用**：测试夹具/探针 `liveRealmCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：从 `rt.firstContext()` 起沿 `ctx.runtime_next` 链遍历，数出该 Runtime 上当前还挂着的 realm context 个数。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `testBacktraceLocationResolver` (`src/tests/core.zig:1757`)

- **签名**：`fn testBacktraceLocationResolver(_: ?*const anyopaque, pc: usize) core.BacktraceLocation`。
- **作用**：测试夹具/探针 `testBacktraceLocationResolver`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `pc` 直接编成 `BacktraceLocation`：`line_num = pc`、`col_num = pc + 10`，让断言能从行列反推 pc。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `appendFinalizationRegistryCell` (`src/tests/core.zig:1763`)

- **签名**：`fn appendFinalizationRegistryCell( rt: *core.JSRuntime, registry: *core.Object, target: core.JSValue, held_value: core.JSValue, unregister_token: core.JSValue, ) !void`。
- **作用**：测试夹具/探针 `appendFinalizationRegistryCell`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`registry.appendFinalizationRegistryCell`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `borrowedHolderInitialAllocationBytes` (`src/tests/core.zig:1773`)

- **签名**：`fn borrowedHolderInitialAllocationBytes() usize`。
- **作用**：测试夹具/探针 `borrowedHolderInitialAllocationBytes`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：返回常量 `@sizeOf(*core.Object) * 64`，即 borrowed holder 首次分配的字节数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TailBufferForceGcProbe.trigger` (`src/tests/core.zig:2490`)

- **签名**：`fn trigger(ctx: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `TailBufferForceGcProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：忽略 `size`（`_ = size`），每次触发都 `self.fired += 1`，然后 `_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}`——按「引擎帧活跃」模式在分配点插一次对象环回收，失败吞掉。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `tailBufferText` (`src/tests/core.zig:2498`)

- **签名**：`fn tailBufferText(rt: *core.JSRuntime, allocator: std.mem.Allocator, value: core.JSValue) ![]u8`。
- **作用**：测试夹具/探针 `tailBufferText`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`std.ArrayList`、`out.deinit`、`core.string.stringValueLen`、`core.string.stringValueCodeUnitAt`、`out.append`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `![]u8`，由测试 `try`/`expectError` 消费。

### `countFinalizer` (`src/tests/core.zig:2904`)

- **签名**：`fn countFinalizer() void`。
- **作用**：测试夹具/探针 `countFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把文件级计数 `finalizer_calls` 加一。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countNativeCleanup` (`src/tests/core.zig:2908`)

- **签名**：`fn countNativeCleanup(ptr: *anyopaque) void`。
- **作用**：测试夹具/探针 `countNativeCleanup`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `ptr` 还原成 `*usize` 并加一。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countPayloadFinalizer` (`src/tests/core.zig:2913`)

- **签名**：`fn countPayloadFinalizer(_: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `countPayloadFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把文件级计数 `payload_finalizer_calls` 加一，并把 `payload` 置 null。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countPayloadMark` (`src/tests/core.zig:2918`)

- **签名**：`fn countPayloadMark( _: *anyopaque, _: *anyopaque, payload: *core.class.Payload, visitor: *core.class.PayloadVisitor, ) void`。
- **作用**：测试夹具/探针 `countPayloadMark`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把文件级计数 `payload_mark_calls` 加一，再 `visitor.value(@ptrCast(payload))` 把 payload 槽当作值边交给 tracer。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countVisitedValue` (`src/tests/core.zig:2928`)

- **签名**：`fn countVisitedValue(context: *anyopaque, _: *anyopaque) void`。
- **作用**：测试夹具/探针 `countVisitedValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `context` 还原成 `*usize` 并加一，忽略被访问的值本身。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ClassConstructionUnregisterProbe.trigger` (`src/tests/core.zig:2946`)

- **签名**：`fn trigger(raw: ?*anyopaque, _: usize) void`。
- **作用**：测试夹具/探针 `ClassConstructionUnregisterProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.fired` 做一次性闸门（已触发过就直接 `return`），首次命中置 `fired = true` 后在分配回调里重入 `self.rt.classes.unregisterDynamic(self.class_id)`，模拟对象构造途中类被注销。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ClassConstructionGrowthProbe.trigger` (`src/tests/core.zig:2962`)

- **签名**：`fn trigger(raw: ?*anyopaque, _: usize) void`。
- **作用**：测试夹具/探针 `ClassConstructionGrowthProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：同样用 `self.fired` 只放行一次；首次命中时在构造途中 `self.rt.classes.register(self.growth_id, .{ .class_name = "GrowthDuringConstruction" })`（失败则置 `register_failed` 并返回）逼类表扩容，成功后把 `@intFromPtr(self.rt.classes.recordPtr(self.target_id).?)` 存进 `target_record_after_growth`，供测试断言扩容后 record 指针是否搬家。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `accountedPlainObjectBytes` (`src/tests/core.zig:2974`)

- **签名**：`fn accountedPlainObjectBytes() usize`。
- **作用**：测试夹具/探针 `accountedPlainObjectBytes`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：以 `core.gc.metadata_prefix_size` 为前缀，把 `prefix + core.Object.objectBodyBytes(core.class.ids.object, false)` 交给 `core.gc_block_heap.accountedBodyBytesForRequest(..., prefix)` 并 `.?` 解包，得到一个普通 plain object 在 block heap 上按类圆整后实际计账的字节数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `emptyRootShapeAllocationBytes` (`src/tests/core.zig:2982`)

- **签名**：`fn emptyRootShapeAllocationBytes() usize`。
- **作用**：测试夹具/探针 `emptyRootShapeAllocationBytes`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：返回 `@sizeOf(core.shape.Shape) + @sizeOf(u32) * core.shape.initial_hash_size + @sizeOf(core.shape.Property) * core.shape.initial_prop_size`，即一个空根 Shape 的分配字节数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ObjectConstructionOrderProbe.trigger` (`src/tests/core.zig:2997`)

- **签名**：`fn trigger(raw: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `ObjectConstructionOrderProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`size != accountedPlainObjectBytes()` 的分配直接放行，只在对象体那次重入上记 `object_boundary_calls`；随后用 `shape_hash_count` 比基线多一、`liveCountKind(.shape)` 比基线多一、`gcStats().heap_live_bytes` 比基线多一个 `emptyRootShapeAllocationBytes()` 三项合判，记录 Shape 在对象分配边界前已发布。关键调用：`accountedPlainObjectBytes`、`self.rt.gc.liveCountKind`、`self.rt.gcStats`、`emptyRootShapeAllocationBytes`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `InlineClassFinalizerReentry.reset` (`src/tests/core.zig:3031`)

- **签名**：`fn reset() void`。
- **作用**：测试夹具/探针 `InlineClassFinalizerReentry.reset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把该 struct 的全部文件级静态字段复位：两个 class id 归 `core.class.invalid_class_id`、`property_atom` 归 `core.atom.null_atom`、计数与八个观察布尔归零。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `InlineClassFinalizerReentry.finalize` (`src/tests/core.zig:3046`)

- **签名**：`fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `InlineClassFinalizerReentry.finalize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`calls += 1` 后先记 `owner_thread_observed = rt.isOwnerThread() and rt.classes.isOwnerThread()`；再抓「finalize 时对象已被剥干净」的三项快照——`!object.hasPropertyStorage()`、`object.getPrototype() == null`、`!object.hasOwnProperty(property_atom)`，并 `object.getProperty(property_atom)`（出错置 `property_read_failed`，结果是否 undefined 记 `property_read_was_undefined`）。随后在 finalizer 内部重入类表：`rt.classes.unregisterDynamic(target_id)`，用 `isRegistered(target_id) and unregisterPending(target_id)` 记 `definition_visible_after_unregister`（注销在 finalize 期间只挂 pending），再 `rt.classes.register(growth_id, ...)` 触发扩容（失败置 `register_failed`）；最后 `payload.* = null`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `InlineObjectLifecycleProbe.reset` (`src/tests/core.zig:3078`)

- **签名**：`fn reset() void`。
- **作用**：测试夹具/探针 `InlineObjectLifecycleProbe.reset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把探针的静态字段复位：期望对象、期望 `heap_live_bytes`/`allocated_bytes`、调用计数、两个身份布尔与两个实测字节数全部清零。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `InlineObjectLifecycleProbe.finalize` (`src/tests/core.zig:3089`)

- **签名**：`fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `InlineObjectLifecycleProbe.finalize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`calls += 1`；`identity_matches = object == expected_object`，`owns_object = identity_matches and rt.ownsObject(object)`（即 finalize 时对象仍归本 Runtime 所有）；把 `rt.gcStats().heap_live_bytes` 与 `rt.memory.allocated_bytes` 抄进静态字段供测试与 `expected_*` 比对；最后 `payload.* = null`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `SideAuthorityDestroyProbe.reset` (`src/tests/core.zig:3108`)

- **签名**：`fn reset() void`。
- **作用**：测试夹具/探针 `SideAuthorityDestroyProbe.reset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `@splat` 把定长数组 `expected_objects` 全置 `null`、`calls` 全置 `0`，并把 `unknown_calls` 清零。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `SideAuthorityDestroyProbe.finalize` (`src/tests/core.zig:3114`)

- **签名**：`fn finalize(_: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `SideAuthorityDestroyProbe.finalize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：遍历 `expected_objects` 找本次 finalize 的对象，命中就给对应下标的 `calls` 加一并把 `payload` 置 null 后返回；没找到则计入 `unknown_calls`，同样置 null。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `registerStandaloneInlineObjectTestClass` (`src/tests/core.zig:3128`)

- **签名**：`fn registerStandaloneInlineObjectTestClass( rt: *core.JSRuntime, class_name: []const u8, finalizer: ?core.class.PayloadFinalizer, ) !core.ClassId`。
- **作用**：测试夹具/探针 `registerStandaloneInlineObjectTestClass`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`try rt.newClassId(core.class.invalid_class_id)` 取一个动态 class id，再 `try rt.classes.register` 注册成带内联 payload 的类（`inline_payload_size = 32`、`inline_payload_align = 8`、`payload_finalizer` 由参数传入）——正是这份动态内联 payload 把对象逼出 block cell、走独立对齐分配。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.ClassId`，由测试 `try`/`expectError` 消费。

### `expectPublishedStandaloneInlineObject` (`src/tests/core.zig:3148`)

- **签名**：`fn expectPublishedStandaloneInlineObject(rt: *core.JSRuntime, object: *core.Object) !void`。
- **作用**：Path proof shared by the non-block Object fixtures below. A dynamic inline payload forces `Object.createInternal` through its raw aligned allocation, and the two counters prove the resulting header is both published and enumerated exactly once by the collector rather than merely having the expected allocation flag by accident.。
- **实现**：取 `object.gcHeader()` 后连查六项：`flags.kind == .object`、`alloc_info.standalone`、`!core.gc.Registry.isBlockCellHeader(header)`、`alloc_info.heap_accounted`、`rt.gc.address_registry.by_header.contains(@intFromPtr(header))`、`rt.gc.nonblock_objects.?.items.items.len >= 1`。再走两个循环：一是沿 `rt.gc.lists.objects.sentinel.next_non_object` / `nextNonObject()` 扫非对象链，断言该 header 在链上出现 `0` 次；二是 `rt.gc.objectIterator(.all)` 全量枚举，统计非 block 的 object header 数 `>= 1`、且本 header 恰好被枚举到 `1` 次。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `countYoungHeader` (`src/tests/core.zig:3181`)

- **签名**：`fn countYoungHeader(rt: *core.JSRuntime, expected: *core.gc.Header) usize`。
- **作用**：测试夹具/探针 `countYoungHeader`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `rt.gc.objectIterator(.young)` 只枚举 young 代，数出 `expected` 这个 header 被枚举到的次数并返回（测试据此判断对象是否还在 young 集合里、且不重复出现）。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `ExternalObjectLifecycleProbe.reset` (`src/tests/core.zig:3204`)

- **签名**：`fn reset() void`。
- **作用**：测试夹具/探针 `ExternalObjectLifecycleProbe.reset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `@splat` 批量复位四个定长数组——`expected_objects` 全 `null`、`events` 全 `0xff`（哨兵，表示该槽未写过）、`identity_matches` 与 `owns_objects` 全 `false`、`allocated_bytes` 全 `0`——并把 `calls` 清零。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExternalObjectLifecycleProbe.finalize` (`src/tests/core.zig:3213`)

- **签名**：`fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `ExternalObjectLifecycleProbe.finalize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `payload.*.?` 还原成 `*ExternalObjectLifecyclePayload` 取出 `event` 编号；以当前 `calls` 为下标（随后 `calls += 1`），只要 `index < max_events` 就按 finalize 的**实际发生顺序**记一行：`events[index] = typed.event`、`identity_matches[index]` 用 `@intFromPtr` 比对 `expected_objects[event]`（event 越界或该槽为空则记 `false`）、`owns_objects[index] = identity_matches[index] and rt.ownsObject(...)`、`allocated_bytes[index] = rt.memory.allocated_bytes`。最后 `rt.memory.destroy(ExternalObjectLifecyclePayload, typed)` 并把 `payload.*` 置 null。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `ExternalClassFinalizerReentry.reset` (`src/tests/core.zig:3242`)

- **签名**：`fn reset() void`。
- **作用**：测试夹具/探针 `ExternalClassFinalizerReentry.reset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `target_id`、`expected_object`、`calls` 与三个观察布尔复位。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExternalClassFinalizerReentry.finalize` (`src/tests/core.zig:3251`)

- **签名**：`fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `ExternalClassFinalizerReentry.finalize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`calls += 1` 后记 `identity_matches = object == expected_object`、`owns_object = identity_matches and rt.ownsObject(object)`；随即在 finalizer 内部重入 `rt.classes.unregisterDynamic(target_id)`，并用 `isRegistered(target_id) and unregisterPending(target_id)` 记 `definition_visible_after_unregister`（注销在 finalize 期间只挂 pending、定义仍可见）。最后 `payload.* orelse return` 取外部 payload，`rt.memory.destroy(TestExternalPayload, typed)` 后置 null。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `createExternalObjectLifecycleProbe` (`src/tests/core.zig:3268`)

- **签名**：`fn createExternalObjectLifecycleProbe( rt: *core.JSRuntime, class_id: core.ClassId, event: u8, ) !*core.Object`。
- **作用**：测试夹具/探针 `createExternalObjectLifecycleProbe`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`core.Object.create`、`rt.memory.create`、`object.installExternalClassPayload`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!*core.Object`，由测试 `try`/`expectError` 消费。

### `finalizeTestExternalPayload` (`src/tests/core.zig:3280`)

- **签名**：`fn finalizeTestExternalPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `finalizeTestExternalPayload`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`payload_finalizer_calls += 1`；`payload.* orelse return` 处理已被清空的槽，再把指针还原成 `*TestExternalPayload`、`rt.memory.destroy(TestExternalPayload, typed)` 释放外部 payload 并把 `payload.*` 置 null（保证只释放一次）。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `finalizeTestExternalObjectPayload` (`src/tests/core.zig:3289`)

- **签名**：`fn finalizeTestExternalObjectPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `finalizeTestExternalObjectPayload`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：与 `finalizeTestExternalPayload` 同形，只是 payload 类型换成 `*TestExternalObjectPayload`（内含一个对象边）：`payload_finalizer_calls += 1` → `payload.* orelse return` → `rt.memory.destroy(TestExternalObjectPayload, typed)` → `payload.* = null`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantCollectionClearFinalizer` (`src/tests/core.zig:3298`)

- **签名**：`fn reentrantCollectionClearFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantCollectionClearFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，在 finalizer 内部重入集合方法表：`engine.exec.collection_ops.methodCall(rt, map.value(), 5, &.{})`（method id 5 = clear），失败直接 `return`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantArrayDeleteFinalizer` (`src/tests/core.zig:3308`)

- **签名**：`fn reentrantArrayDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantArrayDeleteFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `array.deleteProperty(rt, core.atom.atomFromUInt32(0))`，在 finalize 期间删掉数组下标 0。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantPropertyDeleteFinalizer` (`src/tests/core.zig:3318`)

- **签名**：`fn reentrantPropertyDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantPropertyDeleteFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `object.deleteProperty(rt, reentrant_property_delete_key)`，在 finalize 期间删一条具名属性。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantRegExpLastIndexFinalizer` (`src/tests/core.zig:3328`)

- **签名**：`fn reentrantRegExpLastIndexFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantRegExpLastIndexFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `regexp.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(99)) catch {}`，在 finalize 期间改写 RegExp 的 `lastIndex`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantMappedArgumentsFinalizer` (`src/tests/core.zig:3338`)

- **签名**：`fn reentrantMappedArgumentsFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantMappedArgumentsFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `arguments.defineOwnProperty(rt, reentrant_mapped_arguments_key, core.Descriptor.data(core.JSValue.int32(99), true, true, true)) catch {}`，在 finalize 期间重定义 mapped arguments 的一个下标。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantCachedIteratorNextFinalizer` (`src/tests/core.zig:3352`)

- **签名**：`fn reentrantCachedIteratorNextFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantCachedIteratorNextFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `object.clearCachedIteratorNext(rt)`，在 finalize 期间作废缓存的 iterator `next`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantExceptionSlotFinalizer` (`src/tests/core.zig:3362`)

- **签名**：`fn reentrantExceptionSlotFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantExceptionSlotFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入 `slot.clear(rt)`，在 finalize 期间清掉异常槽。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `reentrantArrayIteratorFinalizer` (`src/tests/core.zig:3372`)

- **签名**：`fn reentrantArrayIteratorFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void`。
- **作用**：测试夹具/探针 `reentrantArrayIteratorFinalizer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：固定四步开头：`payload_finalizer_calls += 1`、先把 `payload.*` 置 null（防止重入时二次 finalize）、用各自的 `reentrant_*_calls != 0` 做一次性闸门、计数加一；随后取 `reentrant_*_target orelse return`，重入数组内建方法表：`engine.exec.array_builtin_ops.methodCall(rt, iterator.value(), 20, &.{})`（method id 20 = `arrayIteratorNext`），失败直接 `return`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `markTestExternalPayload` (`src/tests/core.zig:3382`)

- **签名**：`fn markTestExternalPayload( _: *anyopaque, _: *anyopaque, payload: *core.class.Payload, visitor: *core.class.PayloadVisitor, ) void`。
- **作用**：测试夹具/探针 `markTestExternalPayload`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`payload_mark_calls += 1`；`payload.* orelse return` 后还原成 `*TestExternalPayload`，用 `visitor.value(@ptrCast(&typed.value))` 把外部 payload 里的那条**值边**报给 tracer。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `markTestExternalObjectPayload` (`src/tests/core.zig:3394`)

- **签名**：`fn markTestExternalObjectPayload( _: *anyopaque, _: *anyopaque, payload: *core.class.Payload, visitor: *core.class.PayloadVisitor, ) void`。
- **作用**：测试夹具/探针 `markTestExternalObjectPayload`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：与 `markTestExternalPayload` 对称，但报的是**对象边**：`payload_mark_calls += 1` → `payload.* orelse return` → 还原成 `*TestExternalObjectPayload` → `visitor.object(@ptrCast(&typed.object))`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `registryResolveOne` (`src/tests/core.zig:3770`)

- **签名**：`fn registryResolveOne(rt: *core.JSRuntime, addr: usize) ?*core.gc.Header`。
- **作用**：Single-winner resolution for tests: the last published GC header the registry's candidate walk reports for `addr` (null when none).。
- **实现**：内嵌一个只存 `last` 的 `Probe`，其 `visit` 把每次报到的 header 覆盖写进 `last`；用 `rt.gc.address_registry.forEachTraceCandidateAt(addr, rt.gc.address_registry.rebuildScanFilter(), &probe, Probe.visit)` 走一遍候选，返回值被丢弃，最终返回 `probe.last`——即候选枚举中**最后一个**命中的 header，没有候选时为 `null`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visit` (`src/tests/core.zig:3773`)

- **签名**：`fn visit(raw: *anyopaque, header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Probe.visit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `raw` 还原成探针，记下最后一次被访问的 header。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visit` (`src/tests/core.zig:3840`)

- **签名**：`fn visit(raw: *anyopaque, header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Probe.visit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `raw` 还原成探针，header 等于 `expected` 时给 `matching_headers` 加一。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TestJob.run` (`src/tests/core.zig:5037`)

- **签名**：`fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：测试夹具/探针 `TestJob.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Counter.visitValue` (`src/tests/core.zig:5047`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Counter.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `context` 还原成 `*@This()`，只在槽是 int32 且值为 `101` 或落在 `106..108` 闭区间时 `count += 1`——即只数本测试埋下的那几个哨兵根值。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Counter.visitObject` (`src/tests/core.zig:5054`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Counter.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：空实现：丢弃 context 与对象槽，本例只统计值根。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Rewriter.visitValue` (`src/tests/core.zig:5089`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Rewriter.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：忽略 `context`；槽是 int32 且值为 `201` 时就地改写成 `core.JSValue.int32(202)`，证明值根槽在 trace 回调里可写回。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Rewriter.visitObject` (`src/tests/core.zig:5096`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Rewriter.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：对象槽非空时置 `saw_object` 并把槽写成 null，证明对象根槽是可写的。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Rewriter.visitValue` (`src/tests/core.zig:5132`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Rewriter.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：与上一个改写探针同形，只是哨兵换成 `301` → `core.JSValue.int32(302)`；`context` 被丢弃。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `Rewriter.visitObject` (`src/tests/core.zig:5139`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `Rewriter.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：空实现：丢弃 context 与对象槽，本例只改写值根。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `DefineFieldForceGcProbe.trigger` (`src/tests/core.zig:6458`)

- **签名**：`fn trigger(ctx: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `DefineFieldForceGcProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：忽略 `size`，每次分配都 `self.fired += 1` 并 `_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}`——即复刻 `-Dzjs_force_gc=true` 的「每次分配前整轮环回收」形态，让 GC 正好落在 append 的超额预留与 replace 分支的 shape 变更中间。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Rewriter.visitValue` (`src/tests/core.zig:7462`)

- **签名**：`pub fn visitValue(self: *@This(), slot: *core.JSValue) void`。
- **作用**：测试夹具/探针 `Rewriter.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：槽是 int32 时分别匹配两个哨兵：`401` → `count_401 += 1` 且写回 `int32(501)`，`402` → `count_402 += 1` 且写回 `int32(502)`；两条判断不互斥地顺序执行（改写后的值不会再被同次调用二次匹配）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Rewriter.visitObject` (`src/tests/core.zig:7475`)

- **签名**：`pub fn visitObject(_: *@This(), slot: *?*core.Object) void`。
- **作用**：测试夹具/探针 `Rewriter.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：空实现：丢弃对象槽。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Local.storeYoungChild` (`src/tests/core.zig:7936`)

- **签名**：`fn storeYoungChild(runtime: *core.JSRuntime, target: *core.Object, key: anytype) !void`。
- **作用**：测试夹具/探针 `Local.storeYoungChild`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`core.Object.createPlainObject`、`target.defineOwnProperty`、`core.Descriptor.data`、`child.value`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `Probe.visitArena` (`src/tests/core.zig:8345`)

- **签名**：`fn visitArena(context: *anyopaque, base: usize) void`。
- **作用**：测试夹具/探针 `Probe.visitArena`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只做一次转发：把 arena 的 `base` 交给 `core.memory.SmallObjectSlab.forEachArenaBlock(base, context, visitBlock)`，由它逐块回调同 struct 的 `visitBlock`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visitBlock` (`src/tests/core.zig:8349`)

- **签名**：`fn visitBlock(context: *anyopaque, user: [*]u8, is_free: bool) void`。
- **作用**：测试夹具/探针 `Probe.visitBlock`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：还原 `context` 后只认**第一个空闲块**：`!is_free` 或 `self.free_meta` 已填就直接返回；否则把 `user` 指针当成 `*core.gc.Header`，取 `header.meta()` 存进 `free_meta`，供测试检查空闲块里残留的元数据。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Visitor.visitValue` (`src/tests/core.zig:8482`)

- **签名**：`pub fn visitValue(_: *@This(), _: *core.JSValue) !void`。
- **作用**：测试夹具/探针 `Visitor.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：无条件 `return error.OutOfMemory`，把值访问做成必失败的注入点。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `Visitor.visitValue` (`src/tests/core.zig:8514`)

- **签名**：`pub fn visitValue(self: *@This(), slot: *core.JSValue) void`。
- **作用**：测试夹具/探针 `Visitor.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`slot.refHeader() orelse return` 跳过非引用槽；命中 `self.data_child.gcHeader()` 则 `data_hits += 1`，命中 `self.getter.gcHeader()` 则 `getter_hits += 1`——用来分别数据属性边与访问器边各被 trace 到几次。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Visitor.visitValue` (`src/tests/core.zig:8552`)

- **签名**：`pub fn visitValue(_: *@This(), _: *core.JSValue) core.gc.CollectionError!void`。
- **作用**：测试夹具/探针 `Visitor.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：无条件 `return error.OutOfMemory`，与上一个探针同形，只是 error set 收窄成 `core.gc.CollectionError`。
- **所有权 / 错误 / 调用**：返回 `core.gc.CollectionError!void`，由测试 `try`/`expectError` 消费。

### `createDeepOwnedPropertyChain` (`src/tests/core.zig:8580`)

- **签名**：`fn createDeepOwnedPropertyChain(rt: *core.JSRuntime, key: core.Atom, length: usize) !*core.Object`。
- **作用**：测试夹具/探针 `createDeepOwnedPropertyChain`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`std.debug.assert(length != 0)` 后先造链头 `core.Object.create(rt, core.class.ids.object, null)`；循环 `1..length` 每轮再造一个 child，用 `tail.defineOwnProperty(rt, key, core.Descriptor.data(child.value(), true, true, true))` 把它挂到当前尾巴的同一个 `key` 上，再把 `tail` 推进到 child。属性成了 child 的唯一所有者，测试手里只留 head，于是释放 head 会走真实的级联释放。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!*core.Object`，由测试 `try`/`expectError` 消费。

### `externalPropertyStorageBytes` (`src/tests/core.zig:8652`)

- **签名**：`fn externalPropertyStorageBytes(rt: anytype, obj: *const core.Object) usize`。
- **作用**：Accounted bytes of an object's external `.property_storage` cell, zero when the storage is the empty sentinel or the inline slots2 tail (TGC S4-b).。
- **实现**：取 `obj.prop_values`，先用 `obj.propertyStoragePointerIsExternal(storage)` 排除空哨兵与内联 slots2 尾巴（这两种返回 `0`）；是外部 cell 才把指针当作 `*const core.gc.Header`，用 `core.gc.Registry.heapByteSizeFromHeader(rt, header)` 读回它计账的字节数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectNoLiveGc` (`src/tests/core.zig:8659`)

- **签名**：`fn expectNoLiveGc(rt: *core.JSRuntime) !void`。
- **作用**：测试夹具/探针 `expectNoLiveGc`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：两条断言：`rt.gc.liveCount()` 为 0，且 `rt.gc.liveCountKind(.shape)` 也为 0——shape 现在是 GC 对象，单看总数会漏掉残留 shape，所以额外单列一项。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectCycleReclaimedIncludingShapes` (`src/tests/core.zig:8664`)

- **签名**：`fn expectCycleReclaimedIncludingShapes(rt: *core.JSRuntime, expected: usize, actual: usize) !void`。
- **作用**：测试夹具/探针 `expectCycleReclaimedIncludingShapes`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只有两步：`std.testing.expectEqual(expected, actual)` 比对本轮回收计数，再 `try expectNoLiveGc(rt)`。函数名里的 “including shapes” 出自上方注释——回收计数除 JS 对象外还含被收走的 shape、（TGC S4-b 起）属性/元素存储 cell 与（S4-c 起）out-of-line 的 a-class payload cell，所以调用方传的 `expected` 要把这些一并算进去。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectAllLiveGcReclaimed` (`src/tests/core.zig:8674`)

- **签名**：`fn expectAllLiveGcReclaimed(rt: *core.JSRuntime) !void`。
- **作用**：测试夹具/探针 `expectAllLiveGcReclaimed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。主动触发/轮询 GC，断言存活集。关键调用：`rt.gc.liveCount`、`std.testing.expectEqual`、`rt.runObjectCycleRemoval`、`expectNoLiveGc`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `dropGcPtr` (`src/tests/core.zig:8682`)

- **签名**：`fn dropGcPtr(ptr: anytype) void`。
- **作用**：Zero a Zig pointer local that no longer holds a GC object, so a conservative scan cannot treat leftover stack bits as a root (§7.2).。
- **实现**：一行 `@memset(std.mem.asBytes(ptr), 0)`：把传进来的指针局部按字节清零，免得保守扫描把栈上残留的位模式当成根（§7.2）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectClosedPropertyCycleReclaimed` (`src/tests/core.zig:8686`)

- **签名**：`fn expectClosedPropertyCycleReclaimed(rt: *core.JSRuntime, freed: usize) !void`。
- **作用**：测试夹具/探针 `expectClosedPropertyCycleReclaimed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `freed` 与文件级常量 `closed_property_cycle_reclaimed_count` 比对，再 `try expectNoLiveGc(rt)`。该常量当前为 `7`，按注释组成：两个 JS 对象 + 两个单属性 transition shape + 两者共同出发的空根 shape（shared 位是粘的，离开它并不释放，最终随 sweep 一起回收）+ TGC S4-b 起两个对象各自的外部 `.property_storage` cell。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `TraceEdges.recordHeader` (`src/tests/core.zig:8735`)

- **签名**：`fn recordHeader(set: *std.AutoHashMap(usize, void), header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `TraceEdges.recordHeader`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`set.put(@intFromPtr(header), {}) catch unreachable`：把 header 地址当 key 去重记进集合；分配失败在测试里直接 `unreachable`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitValue` (`src/tests/core.zig:8742`)

- **签名**：`pub fn visitValue(self: Visitor, val: *core.JSValue) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`val.cycleMarkHeader()` 取出值槽指向的 GC header（非 GC 值返回 null 则跳过），命中就 `recordHeader(self.set, header)` 记一条边。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitObject` (`src/tests/core.zig:8746`)

- **签名**：`pub fn visitObject(self: Visitor, obj_ptr: *?*core.Object) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：槽为 null 直接跳过；非空还额外挡一道 `@intFromPtr(obj) == 0`，然后 `recordHeader(self.set, obj.gcHeader())`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitShape` (`src/tests/core.zig:8753`)

- **签名**：`pub fn visitShape(self: Visitor, shape_ref: *core.Shape) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitShape`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：无条件把 `&shape_ref.header`（Shape 内嵌的 GC header）记进边集合。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitRealm` (`src/tests/core.zig:8757`)

- **签名**：`pub fn visitRealm(self: Visitor, ctx_ptr: *?*core.context.RealmContext) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitRealm`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：槽非空时把 `&ctx.header` 记进边集合，null 槽跳过。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitModule` (`src/tests/core.zig:8761`)

- **签名**：`pub fn visitModule(self: Visitor, record: *core.ModuleRecord) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitModule`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：无条件把 `&record.header`（ModuleRecord 内嵌的 GC header）记进边集合。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.storageCell` (`src/tests/core.zig:8765`)

- **签名**：`pub fn storageCell(self: Visitor, header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.storageCell`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：直接把收到的存储 cell header 原样 `recordHeader` 进边集合（属性/元素/字符串 buffer 这类 cell 边）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitWeakCollectionEntry` (`src/tests/core.zig:8769`)

- **签名**：`pub fn visitWeakCollectionEntry(_: Visitor, _: *core.object.WeakCollectionEntry) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitWeakCollectionEntry`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：空实现：弱集合条目不计入本例的边集合。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.Visitor.visitFinalizationCell` (`src/tests/core.zig:8771`)

- **签名**：`pub fn visitFinalizationCell(self: Visitor, entry: *core.object.FinalizationRegistryCell) void`。
- **作用**：测试夹具/探针 `TraceEdges.Visitor.visitFinalizationCell`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只有 `entry.keepsHeldValuesAlive()` 为真时才把 `&entry.held_value` 当成普通值边交给 `self.visitValue`；否则该 cell 不贡献任何边（held value 不保活）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TraceEdges.collect` (`src/tests/core.zig:8776`)

- **签名**：`fn collect(rt: *core.JSRuntime, header: *core.gc.Header, allocator: std.mem.Allocator) ![]usize`。
- **作用**：测试夹具/探针 `TraceEdges.collect`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `std.AutoHashMap(usize, void)`（`defer set.deinit()`）给边去重，包一个 `Visitor{ .set = &set }`，再按 `header.meta().flags.kind` 分发：`.object` → `core.Object.fromHeader` 后 `traceChildEdgesNoFail`；`.function_bytecode` → `@fieldParentPtr` 还原后先 `visitRealm(&realm)`（取出 `fb.realm.ptr`、访问后写回）再遍历 `cpoolSlice()` 的每个常量槽；`.var_ref` → 访问 `&ref.value`；`.shape` / `.realm_context` / `.module` → 各自的 `traceChildEdgesNoFail`；`.rope` → 有 buffer 时 `storageCell(buf.header())` 再访问 `left`/`right`；`.string`/`.string_buffer`/`.big_int`/`.property_storage`/`.array_storage`/`.payload` 是无出边的叶子，空臂。最后 `allocator.alloc(usize, set.count())` 把 key 抄出来，`std.mem.sort(..., std.sort.asc(usize))` 升序排序后返回（调用方负责释放这段切片）。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `![]usize`，由测试 `try`/`expectError` 消费。

### `TraceEdges.expectContains` (`src/tests/core.zig:8827`)

- **签名**：`fn expectContains(headers: []const usize, header: *core.gc.Header) !void`。
- **作用**：测试夹具/探针 `TraceEdges.expectContains`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`@intFromPtr`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `Shade.shade` (`src/tests/core.zig:9438`)

- **签名**：`fn shade(ctx: *anyopaque, found: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Shade.shade`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `ctx` 还原成探针，`@intFromPtr(found)` 等于 `self.word.*`（测试埋在栈/内存里的那个字）时 `hits += 1`——用来数保守扫描把这个字认成根、并 shade 出对应 header 的次数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visit` (`src/tests/core.zig:9468`)

- **签名**：`fn visit(raw: *anyopaque, header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Probe.visit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `raw` 还原成探针，分别比对 `first`/`second` 两个 header 并置对应的 `saw_*`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `weakPersistentCounterCallback` (`src/tests/core.zig:10399`)

- **签名**：`fn weakPersistentCounterCallback(_: *core.JSRuntime, context: ?*anyopaque) void`。
- **作用**：测试夹具/探针 `weakPersistentCounterCallback`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `context` 还原成 `*usize` 并加一。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `ForceCollectionProbe.trigger` (`src/tests/core.zig:11422`)

- **签名**：`fn trigger(raw: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `ForceCollectionProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只认 `size == @sizeOf(core.property.AutoInit)` 的那一次分配（其余直接 `return`），命中后 `calls += 1`；把 `rt.memory.trigger_gc_fn` 与 `trigger_gc_ctx` 一起存起来置 `null`、用 `defer` 成对还原，避免回收自身分配时递归重入本钩子；随后 `_ = self.rt.forceGC(null) catch { self.collection_failed = true; }`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `interruptOnce` (`src/tests/core.zig:13509`)

- **签名**：`fn interruptOnce(_: *core.JSRuntime, userdata: ?*anyopaque) bool`。
- **作用**：测试夹具/探针 `interruptOnce`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：给 `userdata` 指向的计数器加一并恒返回 true，即第一次询问就请求中断。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `exoticGet` (`src/tests/core.zig:13766`)

- **签名**：`fn exoticGet(_: *core.Object, _: core.Atom) ?core.Descriptor`。
- **作用**：测试夹具/探针 `exoticGet`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：忽略对象与 atom，任何键都返回同一条定值描述符 `core.Descriptor.data(core.JSValue.int32(99), false, false, true)`（值 99，不可写、不可枚举、可配置）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `exoticDefine` (`src/tests/core.zig:13770`)

- **签名**：`fn exoticDefine(_: *core.Object, _: core.Atom, _: core.Descriptor) bool`。
- **作用**：测试夹具/探针 `exoticDefine`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `exotic_define_calls` 加一并返回 true（声称已自行处理定义）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `exoticDelete` (`src/tests/core.zig:13775`)

- **签名**：`fn exoticDelete(_: *core.Object, _: core.Atom) bool`。
- **作用**：测试夹具/探针 `exoticDelete`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `exotic_delete_calls` 加一并返回 true。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `exoticOwnKeys` (`src/tests/core.zig:13780`)

- **签名**：`fn exoticOwnKeys(_: *core.Object, rt: *core.JSRuntime) ![]core.Atom`。
- **作用**：测试夹具/探针 `exoticOwnKeys`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `rt.memory.alloc(core.Atom, 1)` 分配一格并填入 `core.atom.ids.length`，即这个 exotic 钩子恒报「只有一个 own key：`length`」；切片由调用方按 `rt.memory` 释放。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `![]core.Atom`，由测试 `try`/`expectError` 消费。

### `PoisonAllocator.alloc` (`src/libs/bigint.zig:1291`)

- **签名**：`fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `PoisonAllocator.alloc`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：向 backing 取内存，成功后用 `@memset(ptr[0..len], 0xa5)` 把新分配整块涂成非零模式——basecase 乘法漏写或先读后写的限位会因此改变乘积。关键调用：`self.backing.rawAlloc`、`@memset`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PoisonAllocator.resize` (`src/libs/bigint.zig:1297`)

- **签名**：`fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool`。
- **作用**：测试夹具/探针 `PoisonAllocator.resize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：不做涂写，原样转发 `self.backing.rawResize(buf, alignment, new_len, ra)`（原地扩缩不产生新的未初始化字节）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PoisonAllocator.remap` (`src/libs/bigint.zig:1301`)

- **签名**：`fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `PoisonAllocator.remap`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：原样转发 `self.backing.rawRemap(buf, alignment, new_len, ra)`，不涂写。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PoisonAllocator.free` (`src/libs/bigint.zig:1305`)

- **签名**：`fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void`。
- **作用**：测试夹具/探针 `PoisonAllocator.free`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：原样转发 `self.backing.rawFree(buf, alignment, ra)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PoisonAllocator.allocator` (`src/libs/bigint.zig:1309`)

- **签名**：`fn allocator(self: *PoisonAllocator) std.mem.Allocator`。
- **作用**：测试夹具/探针 `PoisonAllocator.allocator`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `self` 和 alloc/resize/remap/free 四个函数组出 `std.mem.Allocator`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `referenceMul` (`src/libs/bigint.zig:1318`)

- **签名**：`fn referenceMul(alloc: std.mem.Allocator, lhs: []const engine.libs.bigint.Limb, rhs: []const engine.libs.bigint.Limb) ![]engine.libs.bigint.Limb`。
- **作用**：Deliberately zero-initialized schoolbook multiply, kept in the test rather than in the kernel: it is the thing the production path stopped doing, so it has to exist somewhere independent to compare against. Returns unnormalized limbs with trailing zeros stripped, matching what `mulAlloc` returns.。
- **实现**：故意保留「先 `@memset(out, 0)` 清零再累加」的课本式乘法——生产路径已经不这么做了，所以参照实现必须独立存在于测试里。先 `alloc.alloc(Limb, lhs.len + rhs.len)`（`errdefer alloc.free(out)`）并清零；外层遍历 `lhs`，内层遍历 `rhs`，用 `u128` 的 `Double` 累加 `a * b + out[i + j] + carry`，低 64 位 `@truncate` 回 `out[i + j]`、高位右移 64 成新 carry，内层结束把 carry 写进 `out[i + rhs.len]`。最后从高位起剥掉全零 limb，长度没变就原样返回，否则 `alloc.realloc(out, len)` 缩到规范长度（与 `mulAlloc` 的返回形状一致）。
- **所有权 / 错误 / 调用**：失败路径靠 `errdefer` 对称释放。返回 `![]engine.libs.bigint.Limb`，由测试 `try`/`expectError` 消费。

### `lockstepLimb` (`src/core/bigint.zig:419`)

- **签名**：`fn lockstepLimb(pattern: usize, index: usize, offset: usize) engine.libs.bigint.Limb`。
- **作用**：Deterministic limb patterns for the lockstep test. Index selects a shape family; the offset keeps the two operands from being identical.。
- **实现**：先算 `i = index + offset`（`offset` 用来让两个操作数不至于完全相同），再按 `pattern` 五选一：`0` 恒 `std.math.maxInt(Limb)`（饱和，进位链最长、最高位进位非零）；`1` 只有 `index == 0` 时给 `1 << 63`、其余为 0（最高进位为零，乘积规范化后比容量少一个 limb）；`2` 稀疏——`i % 3 == 0` 给 1 否则 0；`3` 按 `i` 奇偶交替 `0xAAAA...` / `0x5555...` 条纹；`4` 低熵斜坡 `@as(Limb, @intCast(i)) *% 0x9E37_79B9_7F4A_7C15 +% 1`；其余 `unreachable`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectLockstepMul` (`src/core/bigint.zig:440`)

- **签名**：`fn expectLockstepMul( rt: *core.JSRuntime, lhs_limbs: []const engine.libs.bigint.Limb, lhs_negative: bool, rhs_limbs: []const engine.libs.bigint.Limb, rhs_negative: bool, ) !void`。
- **作用**：Runs one multiply through both kernels and asserts the results agree in sign, length and every limb. Each operand is built once as external storage and once as inline storage, so all four storage combinations are covered.。
- **实现**：先用裸 limb 切片拼两个 `bigint.BigInt`（`@constCast` 借用调用方内存、allocator 取自 `rt.memory.allocator`），跑参照内核 `bigint.mulAlloc` 得到 `expected`（`defer expected.deinit()`）。随后两层 `inline for (.{ false, true })` 穷举 lhs/rhs 的 inline/外部存储四种组合：每轮 `makeLockstepOperand` 造操作数（各自 `defer releaseForTest(rt)`），断言 `isInline()` 与期望一致、`mulResultCannotCompactToShort(lhs, rhs)` 成立，再走 `core.bigint.BigInt.createMulInline(rt, lhs, rhs)` 得到 `product`（同样 `defer releaseForTest`）。对 product 连查五项：`isInline()`、符号等于 `expected.negative`、`expectEqualSlices` 逐 limb 相等、`capacitySliceMut().len == lhs_limbs.len + rhs_limbs.len`（分配从不缩，销毁必须按满容量走）、且规范化后的 `limbs().len` 与容量相等或恰少 1。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `makeLockstepOperand` (`src/core/bigint.zig:488`)

- **签名**：`fn makeLockstepOperand( rt: *core.JSRuntime, limbs: []const engine.libs.bigint.Limb, negative: bool, comptime want_inline: bool, ) !*core.bigint.BigInt`。
- **作用**：测试夹具/探针 `makeLockstepOperand`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按 comptime 的 `want_inline` 走两条路：内联路径 `core.bigint.BigInt.createInlineUninitialized(rt, limbs.len)` 开一个未初始化内联 BigInt，`@memcpy(big.capacitySliceMut(), limbs)` 灌数据后 `big.publishInline(limbs.len, negative)` 发布；外部路径先用 `@constCast(limbs)` 拼一个借用式 `bigint.BigInt`（allocator 取 `rt.memory.allocator`），再交给 `core.bigint.BigInt.createFromBigInt(rt, owned)` 造出外部存储形态。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!*core.bigint.BigInt`，由测试 `try`/`expectError` 消费。

### `DivFailAllocator.allocator` (`src/libs/bigint.zig:1355`)

- **签名**：`fn allocator(self: *DivFailAllocator) std.mem.Allocator`。
- **作用**：测试夹具/探针 `DivFailAllocator.allocator`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `self` 和 alloc/resize/remap/free 四个函数组出 `std.mem.Allocator`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `DivFailAllocator.alloc` (`src/libs/bigint.zig:1364`)

- **签名**：`fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `DivFailAllocator.alloc`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：两条拒绝路径优先于转发：`refuse_next_alloc` 置位时消费掉该标志、置 `induced` 并返回 null；否则按 `alloc_attempts` 编号，编号等于 `fail_alloc_index` 时同样置 `induced` 返回 null。都不命中才转发 backing，并给 `live` 加一。关键调用：`self.backing.rawAlloc`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `DivFailAllocator.resize` (`src/libs/bigint.zig:1384`)

- **签名**：`fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool`。
- **作用**：测试夹具/探针 `DivFailAllocator.resize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`fail_shrink` 且 `new_len < memory.len` 时直接返回 false，其余转发 backing。关键调用：`self.backing.rawResize`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `DivFailAllocator.remap` (`src/libs/bigint.zig:1390`)

- **签名**：`fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `DivFailAllocator.remap`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`fail_shrink` 且 `new_len < memory.len` 时返回 null，并顺手置 `refuse_next_alloc`，让标准分配器的 alloc-and-copy 回退也失败，从而真正走到 `normalize` 的错误路径；其余转发 backing。关键调用：`self.backing.rawRemap`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `DivFailAllocator.free` (`src/libs/bigint.zig:1401`)

- **签名**：`fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void`。
- **作用**：测试夹具/探针 `DivFailAllocator.free`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先给 `live` 减一再转发 backing，`live` 归零即所有权已对称交还。关键调用：`self.backing.rawFree`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectDivisionUnderInjection` (`src/libs/bigint.zig:1408`)

- **签名**：`fn expectDivisionUnderInjection( inject: *DivFailAllocator, lhs_limbs: []const engine.libs.bigint.Limb, lhs_negative: bool, rhs_limbs: []const engine.libs.bigint.Limb, rhs_negative: bool, expected_quotient: engine.libs.bigint.BigInt, expected_remainder: engine.libs.bigint.BigInt, ) !void`。
- **作用**：测试夹具/探针 `expectDivisionUnderInjection`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `inject.allocator()` 拼两个借用 limb 切片的 `bigint.BigInt`，再 `bigint.divRemAlloc(alloc, lhs, rhs)`：成功臂（`defer` 各自 `deinit`）要求商与余数 `compare` 期望值均为 `.eq`——注入下侥幸成功也必须算对；失败臂只允许 `error.OutOfMemory`。两条路径之后都统一收尾：`inject.live` 必须回到 `0`（无悬挂分配），且 `lhs_limbs` / `rhs_limbs` 与输入逐 limb 相等（输入仍归调用方所有、不得被就地改写）。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectDivisionIdentity` (`src/libs/bigint.zig:1441`)

- **签名**：`fn expectDivisionIdentity( lhs_limbs: []const engine.libs.bigint.Limb, lhs_negative: bool, rhs_limbs: []const engine.libs.bigint.Limb, rhs_negative: bool, ) !void`。
- **作用**：Checks `q * b + r == a`, `abs(r) < abs(b)`, the remainder's sign, and that neither result carries a leading zero limb.。
- **实现**：在 `std.testing.allocator` 上拼两个借用式 `BigInt`，取 `lhs.div(rhs)` 与 `lhs.rem(rhs)`（各 `defer deinit`），再 `mulAlloc(quotient, rhs)` + `addAlloc(product, remainder)` 还原出 `recovered`，断言 `recovered.compare(lhs) == .eq`（即 `q*b + r == a`）。随后另拼两个去符号的 `BigInt` 断言 `|r| < |b|`；余数非零时符号必须跟被除数一致，商非零时符号必须是 `lhs_negative != rhs_negative`；最后要求商与余数的最高 limb 都非零（无前导零 limb）。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!void`，由测试 `try`/`expectError` 消费。

### `Case.check` (`src/libs/bigint.zig:1850`)

- **签名**：`fn check(high: Limb, low: Limb, divisor: Limb) !void`。
- **作用**：测试夹具/探针 `Case.check`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `bigint.normalizedReciprocalInit(divisor)` 预算倒数，跑 `bigint.divTwoByOneReciprocal(high, low, divisor, reciprocal)`；再把 `(high << 64) | low` 拼成 `Double`（u128）的裸除法作参照，断言商与余数都与 `numerator / divisor`、`numerator % divisor` 逐位相等。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `countExtentStringHeaders` (`src/tests/core.zig:15883`)

- **签名**：`fn countExtentStringHeaders(rt: *core.JSRuntime, header: *const core.gc.Header) struct { matches: usize, extents: usize, }`。
- **作用**：数 `header` 被全堆迭代器 yield 了几次，以及一共见到多少个 extent string——extent 住在 block heap 的 medium/large 表里，没有 list link、没有 cell、没有 bitmap，只有这条枚举能证明它们对 census/verify 可见。
- **实现**：`rt.gc.objectIterator(.all)` 全堆遍历，跳过 `metaConst().flags.kind != .string` 的候选，再跳过 `core.gc.Registry.isBlockCellHeader` 为真的（那是 block cell 不是 extent），剩下的计入 `extents`，其中等于 `header` 的另计入 `matches`。关键调用：`rt.gc.objectIterator`、`iterator.next`、`candidate.metaConst`、`core.gc.Registry.isBlockCellHeader`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visit` (`src/tests/core.zig:15933`)

- **签名**：`fn visit(raw: *anyopaque, header: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Probe.visit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `raw` 还原成探针，分别比对 `a`/`b` 两个 extent header 并置对应的 `saw_*`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.visit` (`src/tests/core.zig:15984`)

- **签名**：`fn visit(raw: *anyopaque, visited: *core.gc.Header) void`。
- **作用**：测试夹具/探针 `Probe.visit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `raw` 还原成探针，被访问的 header 等于 `want` 时置 `saw`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `atomMarkEpochForTest` (`src/tests/core.zig:16145`)

- **签名**：`fn atomMarkEpochForTest(rt: *core.JSRuntime, id: anytype) ?u64`。
- **作用**：TGC S3: an atom entry is not a heap object, so no `objectIterator` can save or restore it -- its liveness is a stamp compared against `Heap.mark_epoch`. One known id is a sharper probe than a table-wide count: the minor's own trace re-stamps whatever it reaches, and a count would hide a lost stamp behind that work.。
- **实现**：TGC S3: an atom entry is not a heap object, so no `objectIterator` can save or restore it -- its liveness is a stamp compared against `Heap.mark_epoch`. One known id is a sharper probe than a table-wide count: the minor's own trace re-stamps whatever it reaches, and a count would hide a lost stamp behind that work.。线性扫 `rt.atoms.entries`，跳过未占用项，`entry.id == id` 时返回该项的 `mark_epoch`，找不到返回 null。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `driveOneIncrementalMajorForCensusTest` (`src/tests/core.zig:17404`)

- **签名**：`fn driveOneIncrementalMajorForCensusTest(rt: *core.JSRuntime, garbage: usize) !u64`。
- **作用**：Drive one whole incremental major -- open, mark to the frontier's end, finish, and drain the morgue -- over a heap of `garbage` dead objects. Returns the number of finish segments the drive produced, so a caller that reasons about "the finish" can assert there was exactly one.。
- **实现**：先 `rt.forcePreciseRootScanForTest()` 关掉保守扫描的干扰，再造 `garbage` 个立刻失联的 `core.Object.create(rt, core.class.ids.object, null)`；记下 `rt.gc.incremental.stats.total_segments_by_kind[@intFromEnum(core.gc.Registry.SliceKind.finish)]` 的基线，把阈值压到 `rt.memory.allocated_bytes - 1` 后 `rt.pollGC(null, .safepoint)` 开一轮增量 major，并断言 `markingActive()` 确实开起来了。随后循环 poll 到 `markingActive()` 与 `rt.gc.morgue.pending` 都清空（`polls < 10_000` 兜底防死循环），返回这一轮新增的 finish 段数——调用方据此断言「finish 恰好发生一次」。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!u64`，由测试 `try`/`expectError` 消费。

### `s3AtomEntry` (`src/tests/core.zig:17907`)

- **签名**：`fn s3AtomEntry(rt: *core.JSRuntime, id: core.Atom) *core.atom.DynamicAtom`。
- **作用**：测试夹具/探针 `s3AtomEntry`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按 `id - core.atom.first_dynamic_atom` 下标直取 `rt.atoms.entries` 里的 `DynamicAtom`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `s3MarkEpoch` (`src/tests/core.zig:17911`)

- **签名**：`fn s3MarkEpoch(rt: *core.JSRuntime) u64`。
- **作用**：测试夹具/探针 `s3MarkEpoch`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：返回 `rt.gc.block_heap.mark_epoch`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `s3RunMajor` (`src/tests/core.zig:17915`)

- **签名**：`fn s3RunMajor(rt: *core.JSRuntime) !void`。
- **作用**：测试夹具/探针 `s3RunMajor`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`rt.forceMajorGC`、`helpers.finishGcCycles`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `s3OccupiedEntryCount` (`src/tests/core.zig:18076`)

- **签名**：`fn s3OccupiedEntryCount(rt: *core.JSRuntime) usize`。
- **作用**：测试夹具/探针 `s3OccupiedEntryCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：线性扫 `rt.atoms.entries`，用 `@intFromBool(entry.slotOccupied())` 累加，得到 atom 表当前占用的槽数。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `defineS4bNamedProperties` (`src/tests/core.zig:18399`)

- **签名**：`fn defineS4bNamedProperties(rt: *core.JSRuntime, obj: *core.Object, prefix: []const u8, count: usize) !void`。
- **作用**：Give `obj` `count` named data properties, which grows it past the inline slots2 tail into an external `.property_storage` cell.。
- **实现**：在一个 64 字节栈 buffer 上按 `"{s}{d}"`（`prefix` + 序号）拼名字，`rt.internAtom` 取 atom，再 `obj.defineOwnProperty` 定义值为 `core.JSValue.int32(index)`、三个标志全 true 的数据属性，循环 `count` 次。属性数量一旦超过内联 slots2 尾巴，对象就会长出外部 `.property_storage` cell——这正是 S4-b 用例要的形态。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectS4bNamedProperties` (`src/tests/core.zig:18414`)

- **签名**：`fn expectS4bNamedProperties(rt: *core.JSRuntime, obj: *core.Object, prefix: []const u8, count: usize) !void`。
- **作用**：测试夹具/探针 `expectS4bNamedProperties`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：与 `defineS4bNamedProperties` 对称的读回校验：同样用 64 字节栈 buffer 按 `"{s}{d}"` 重建名字、`rt.internAtom` 取 atom，逐条断言 `(try obj.getProperty(key)).as(.int)` 等于 `@as(?i32, @intCast(index))`（用 optional 比较，非 int32 会以 null 暴露）。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `fillS4bDenseArray` (`src/tests/core.zig:18426`)

- **签名**：`fn fillS4bDenseArray(rt: *core.JSRuntime, arr: *core.Object, count: u32) !void`。
- **作用**：Append `count` dense elements one at a time, which walks `ensureArrayBufferCapacity` up its whole 1.5x growth ladder.。
- **实现**：每轮只把容量抬高一格：`arr.fastArrayEnsureCapacity(rt, index + 1)`，逼 `ensureArrayBufferCapacity` 走完整条 1.5 倍增长梯子而不是一步到位；随后 `engine.exec.array_ops.putDenseArrayElementOverwriteOwnedFast(rt, arr.value(), int32(index), int32(index))` 写入下标与值相同的元素，并断言返回 `DenseArrayOverwriteFastResult.handled`（即始终命中 dense 快路径）。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `installMintedStringBufferBody` (`src/tests/core.zig:18473`)

- **签名**：`fn installMintedStringBufferBody(kind: core.gc.GcKind, body: [*]u8, total_bytes: usize) void`。
- **作用**：测试夹具/探针 `installMintedStringBufferBody`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`kind` 不是 `.string_buffer` 时直接返回；否则把 body 当 `core.string.StringBuffer` 写入，`capacity = total_bytes - core.gc.metadata_prefix_size - core.string.StringBuffer.units_offset`、`is_wide = false`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `registerS4cPayloadClass` (`src/tests/core.zig:18716`)

- **签名**：`fn registerS4cPayloadClass( rt: *core.JSRuntime, name: []const u8, payload_kind: core.class.PayloadKind, ) !core.class.ClassId`。
- **作用**：Register a dynamic class whose only interesting property is the a-class payload kind it selects, for the kinds no standard class declares.。
- **实现**：`rt.newClassId(core.class.invalid_class_id)` 取一个动态 id，再 `rt.classes.register(id, .{ .class_name = name, .payload_kind = payload_kind })`——整个类唯一有意义的配置就是这个 a-class payload kind，用来覆盖没有任何标准类声明的那几种 kind。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.class.ClassId`，由测试 `try`/`expectError` 消费。

### `lessThan.lessThan` (`src/tests/core.zig:19222`)

- **签名**：`fn lessThan(_: void, a: Sample, b: Sample) bool`。
- **作用**：测试夹具/探针 `lessThan.lessThan`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先比 `key`，相等时再比 `order`，给排序提供确定的严格弱序。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectAuditPrintMatchesFmt` (`src/tests/core.zig:19231`)

- **签名**：`fn expectAuditPrintMatchesFmt( comptime fmt: []const u8, args: anytype, parts: []const @import("../core/gc_audit_print.zig").Part, ) !void`。
- **作用**：测试夹具/探针 `expectAuditPrintMatchesFmt`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：两个 256 字节栈 buffer：一个用 `std.fmt.bufPrint(&expected_buf, fmt, args)` 产出 `std.fmt` 的参照文本，另一个用 `std.Io.Writer.fixed(&actual_buf)` 接住 `core/gc_audit_print.zig` 的 `write(&writer, parts)` 输出；最后 `std.testing.expectEqualStrings(expected, writer.buffered())` 断言自造的 audit 打印与标准格式化逐字节一致。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### 测试块（496）

### `test "dense parameter arrays borrowed construction roots output during storage allocation"` (`src/tests/core.zig:10`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays borrowed construction roots output during storage allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dense parameter arrays borrowed construction propagates OOM and recovers"` (`src/tests/core.zig:51`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：dense parameter arrays borrowed construction propagates OOM and recovers。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "M-cut Object handle conversion keeps the head at the handle address"` (`src/core/object.zig:11510`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-cut Object handle conversion keeps the head at the handle address」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "host transports and core operation errors keep independent narrow sets"` (`src/tests/core.zig:96`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host transports and core operation errors keep independent narrow sets」。
- **实现**：断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

`JSValue` / `Tag` 表示测试在 `src/core/value.zig`（见 [06-core-value-value.md](06-core-value-value.md)）。

### `test "over-reserved property storage is freed by prop_size not prop_count"` (`src/tests/core.zig:204`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「over-reserved property storage is freed by prop_size not prop_count」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "first named property allocates initial_prop_size slots"` (`src/core/object.zig:11527`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「first named property allocates initial_prop_size slots」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "block Object accounting uses physical cell body capacity"` (src/core/object.zig:11553`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block Object accounting uses physical cell body capacity」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape-sized trailing property storage grows externally and compacts in place"` (src/core/object.zig:11593`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shape-sized trailing property storage grows externally and compacts in place」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 19 处 `std.testing.expect*`。约 19 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "slots2 spill OOM rollback restores inline representation"` (src/core/object.zig:11657`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：slots2 spill OOM rollback restores inline representation。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "M-cut slots2 payload-spill deletion mutant is rejected"` (`src/tests/core.zig:497`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-cut slots2 payload-spill deletion mutant is rejected」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "plain object destroy slim frees two data slots and the value buffer"` (`src/tests/core.zig:528`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「plain object destroy slim frees two data slots and the value buffer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "proven object release preserves generic JSValue ownership semantics"` (`src/tests/core.zig:548`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「proven object release preserves generic JSValue ownership semantics」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "active bytecode release preserves generic ownership"` (`src/tests/core.zig:577`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「active bytecode release preserves generic ownership」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap BigInt value uses reserved QuickJS tag"` (`src/core/bigint.zig:509`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap BigInt value uses reserved QuickJS tag」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap BigInt limbs participate in runtime memory limit and accounting"` (`src/core/bigint.zig:520`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap BigInt limbs participate in runtime memory limit and accounting」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap BigInt external storage reads through the storage accessors"` (`src/core/bigint.zig:547`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap BigInt external storage reads through the storage accessors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap BigInt inline storage destroys by capacity across the slab boundary"` (`src/core/bigint.zig:581`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap BigInt inline storage destroys by capacity across the slab boundary」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 21 处 `std.testing.expect*`。约 21 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime and context init-deinit are leak free"` (`src/core/runtime.zig:5121`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime and context init-deinit are leak free」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RealmContext is header-first and RealmRef owns independently of runtime list membership"` (`src/tests/core.zig:810`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RealmContext is header-first and RealmRef owns independently of runtime list membership」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RealmContext construction stays unpublished and untraced until the live commit"` (`src/tests/core.zig:839`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RealmContext construction stays unpublished and untraced until the live commit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBuiltinRegistry`。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RealmContext owns the five QuickJS initial layouts as Shapes"` (`src/tests/core.zig:879`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RealmContext owns the five QuickJS initial layouts as Shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: known append immediately shades the new target"` (`src/tests/core.zig:915`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: known append immediately shades the new target」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: three append routes cover grey and black owners"` (`src/tests/core.zig:961`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: three append routes cover grey and black owners」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: capacity growth shades only storage and preserves copied edges"` (`src/tests/core.zig:1018`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: capacity growth shades only storage and preserves copied edges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: public uninitialized slot still queues its owner"` (`src/tests/core.zig:1062`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: public uninitialized slot still queues its owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: old array remembers first storage and appended target"` (`src/tests/core.zig:1088`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: old array remembers first storage and appended target」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: failed capacity allocation leaves count and value unchanged"` (`src/tests/core.zig:1116`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: failed capacity allocation leaves count and value unchanged」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。强制 major / 环回收后比对对象身份或存活状态。设置 runtime 内存上限以注入 OOM。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: frontier OOM fails closed after a committed store"` (`src/tests/core.zig:1141`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：array target barrier: frontier OOM fails closed after a committed store。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。强制 major / 环回收后比对对象身份或存活状态。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array target barrier: literal fill marks new edges after owner scanning"` (`src/tests/core.zig:1183`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array target barrier: literal fill marks new edges after owner scanning」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Runtime queues retain their originating Realm until owned jobs are released"` (`src/tests/core.zig:1220`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Runtime queues retain their originating Realm until owned jobs are released」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "caller-owned ClassIdSlot is process-stable while definitions stay per Runtime"` (`src/tests/core.zig:1258`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「caller-owned ClassIdSlot is process-stable while definitions stay per Runtime」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Runtime owner thread rejects foreign structural mutation before publication"` (`src/tests/core.zig:1286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Runtime owner thread rejects foreign structural mutation before publication」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBuiltinRegistry`。断言 20 处 `std.testing.expect*`。约 20 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "process-global ClassId allocation is atomic across owner-thread Runtimes"` (`src/tests/core.zig:1383`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「process-global ClassId allocation is atomic across owner-thread Runtimes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RealmContext participates in cycle collection through typed RealmRef edges"` (`src/tests/core.zig:1440`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RealmContext participates in cycle collection through typed RealmRef edges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionBytecode RealmRef edge participates in realm-global cycle collection"` (`src/tests/core.zig:1466`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionBytecode RealmRef edge participates in realm-global cycle collection」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FinalizationRegistry RealmRef edge participates in realm-global cycle collection"` (`src/tests/core.zig:1521`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FinalizationRegistry RealmRef edge participates in realm-global cycle collection」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "auto_init slot to another realm retains it across JSContext.destroy and cycle GC"` (`src/tests/core.zig:1558`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「auto_init slot to another realm retains it across JSContext.destroy and cycle GC」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FinalizationRegistry RealmRef retains and releases its construction realm exactly once"` (`src/tests/core.zig:1595`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FinalizationRegistry RealmRef retains and releases its construction realm exactly once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dynamic class registration reserves slots in live and future realms"` (`src/tests/core.zig:1614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic class registration reserves slots in live and future realms」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dynamic class prototype capacity and clearing include constructing realms"` (`src/tests/core.zig:1634`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic class prototype capacity and clearing include constructing realms」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime-resident indexes outlive a temporary allocator"` (`src/tests/core.zig:1656`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime-resident indexes outlive a temporary allocator」。
- **实现**：`rt.init` 后把 `rt.memory.allocator` 临时换成一个 arena，在 arena 生效期间跑一轮 `beginBorrowedWeakCleanup` / `enqueueBorrowedWeakCleanupIdentity(2)` / `endBorrowedWeakCleanup`，再换回原分配器并 `arena.deinit()`；随后再跑一轮空的 begin/end。没有 `expect*`：判据是第二轮不得踩到已释放的 arena 内存——即那份保留下来的 hash 分配必须来自 runtime 的持久分配器。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "context backtrace can borrow VM frame pc lazily"` (`src/tests/core.zig:1777`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「context backtrace can borrow VM frame pc lazily」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "private brand property owns exactly one stored symbol value across replacement"` (`src/tests/core.zig:1840`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「private brand property owns exactly one stored symbol value across replacement」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ownership audit quarantines every atom slot the last sweep retired"` (`src/tests/core.zig:1971`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ownership audit quarantines every atom slot the last sweep retired」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC leaves atom-owned unique symbol atoms until release"` (`src/tests/core.zig:2023`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：leaves atom-owned unique symbol atoms until release。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC leaves manually owned unique symbol atoms alone"` (`src/tests/core.zig:2041`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：leaves manually owned unique symbol atoms alone。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps rooted unique symbol atoms until the root is gone"` (`src/tests/core.zig:2053`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps rooted unique symbol atoms until the root is gone。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps atom-owned unique symbol atoms until the atom owner releases"` (`src/tests/core.zig:2070`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps atom-owned unique symbol atoms until the atom owner releases。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps runtime exception and realm value slot unique symbol atoms"` (`src/tests/core.zig:2089`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps runtime exception and realm value slot unique symbol atoms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps context lexical object unique symbol atoms"` (`src/tests/core.zig:2133`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps context lexical object unique symbol atoms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps context pending promise job unique symbol atoms until release"` (`src/tests/core.zig:2156`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps context pending promise job unique symbol atoms until release。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps finalization job unique symbol atoms after dequeue until release"` (`src/tests/core.zig:2177`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps finalization job unique symbol atoms after dequeue until release。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps dequeued finalization job function bytecode symbol constants until release"` (`src/tests/core.zig:2223`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps dequeued finalization job function bytecode symbol constants until release。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps module registry unique symbol atoms until release"` (`src/tests/core.zig:2264`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps module registry unique symbol atoms until release。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC sweeps unique symbol atoms after description string cache"` (`src/tests/core.zig:2297`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：sweeps unique symbol atoms after description string cache。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps rooted function bytecode symbol constants"` (`src/tests/core.zig:2315`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps rooted function bytecode symbol constants。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "GC keeps object-held and registered symbol atoms"` (`src/tests/core.zig:2339`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：keeps object-held and registered symbol atoms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime teardown keeps unique symbol property keys live through shape destruction"` (`src/tests/core.zig:2369`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime teardown keeps unique symbol property keys live through shape destruction」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "S2-i append chain survives a forced collection at every allocation"` (`src/tests/core.zig:2615`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「S2-i append chain survives a forced collection at every allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "S2-i the concat operator seeds a tail buffer and keeps forks independent"` (`src/tests/core.zig:2666`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「S2-i the concat operator seeds a tail buffer and keeps forks independent」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class table registers QuickJS standard classes and dynamic classes"` (`src/tests/core.zig:2796`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class table registers QuickJS standard classes and dynamic classes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.DuplicateClass`。断言 35 处 `std.testing.expect*`。约 35 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class Record default fill matches Record{} without a template"` (`src/tests/core.zig:2849`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class Record default fill matches Record{} without a template」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class prototype inline slots start as JSValue.nullValue"` (`src/tests/core.zig:2861`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class prototype inline slots start as JSValue.nullValue」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class standard_plans match standardPayloadKind before and after register"` (`src/tests/core.zig:2873`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class standard_plans match standardPayloadKind before and after register」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class registration growth OOM does not publish a partial definition and retry succeeds"` (`src/tests/core.zig:3406`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：class registration growth OOM does not publish a partial definition and retry succeeds。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object creation rejects an unregistered dynamic class generation"` (`src/tests/core.zig:3423`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object creation rejects an unregistered dynamic class generation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidClassId`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class construction pins its definition across reentrant unregister"` (`src/tests/core.zig:3437`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class construction pins its definition across reentrant unregister」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidClassId`。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class construction scalar plan survives record table growth"` (`src/tests/core.zig:3472`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class construction scalar plan survives record table growth」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "inline class finalizer reentry keeps definition pinned while growing the table"` (`src/tests/core.zig:3510`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline class finalizer reentry keeps definition pinned while growing the table」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "inline class finalizer observes the live object allocation until callback return"` (`src/tests/core.zig:3548`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline class finalizer observes the live object allocation until callback return」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standalone inline object publication is visible to collector enumeration"` (`src/tests/core.zig:3593`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standalone inline object publication is visible to collector enumeration」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "side authority swap-remove condemnation drains every non-block object exactly once"` (`src/tests/core.zig:3612`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「side authority swap-remove condemnation drains every non-block object exactly once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 18 处 `std.testing.expect*`。约 18 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standalone inline object survives a rooted minor and retires young"` (`src/tests/core.zig:3673`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standalone inline object survives a rooted minor and retires young」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standalone inline object survives a rooted major mark"` (`src/tests/core.zig:3705`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standalone inline object survives a rooted major mark」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "single-code-unit string table survives a declared-roots collection"` (`src/tests/core.zig:3736`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「single-code-unit string table survives a declared-roots collection」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standalone inline object resolves from a conservative interior candidate"` (`src/tests/core.zig:3783`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standalone inline object resolves from a conservative interior candidate」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.NotFound`。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standalone inline object teardown parks its struct free until the drain"` (`src/tests/core.zig:3853`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standalone inline object teardown parks its struct free until the drain」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "external class finalizers run synchronously with original object identity in zero-ref FIFO order"` (`src/tests/core.zig:3880`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「external class finalizers run synchronously with original object identity in zero-ref FIFO order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array teardown releases its unique prototype before its unique dense element"` (`src/tests/core.zig:3915`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array teardown releases its unique prototype before its unique dense element」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak husk keeps its class definition after one synchronous finalizer"` (`src/tests/core.zig:3945`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak husk keeps its class definition after one synchronous finalizer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class finalizers and context prototype slots are wired"` (`src/tests/core.zig:3987`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class finalizers and context prototype slots are wired」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object destruction runs class payload finalizers synchronously without allocation"` (`src/tests/core.zig:4036`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object destruction runs class payload finalizers synchronously without allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "strong collection clear publishes empty state before synchronous finalizer reentry"` (`src/tests/core.zig:4085`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strong collection clear publishes empty state before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dense array delete publishes sparse state before synchronous finalizer reentry"` (`src/tests/core.zig:4124`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array delete publishes sparse state before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary property delete publishes absence before synchronous finalizer reentry"` (`src/tests/core.zig:4163`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary property delete publishes absence before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "IC-R1: in-place delete mutates the shape Property word"` (`src/tests/core.zig:4204`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「IC-R1: in-place delete mutates the shape Property word」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp lastIndex set publishes replacement before synchronous finalizer reentry"` (`src/tests/core.zig:4239`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp lastIndex set publishes replacement before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp lastIndex define publishes replacement before synchronous finalizer reentry"` (`src/tests/core.zig:4278`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp lastIndex define publishes replacement before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped arguments binding update publishes value before synchronous finalizer reentry"` (`src/tests/core.zig:4321`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments binding update publishes value before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped arguments var-ref update publishes value before synchronous finalizer reentry"` (`src/tests/core.zig:4366`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments var-ref update publishes value before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped arguments binding delete publishes disconnection before synchronous finalizer reentry"` (`src/tests/core.zig:4410`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments binding delete publishes disconnection before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cached iterator next clear publishes null before synchronous finalizer reentry"` (`src/tests/core.zig:4459`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cached iterator next clear publishes null before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "exception slot clear publishes empty state before synchronous finalizer reentry"` (`src/tests/core.zig:4499`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「exception slot clear publishes empty state before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array iterator target clear publishes null before synchronous finalizer reentry"` (`src/tests/core.zig:4531`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array iterator target clear publishes null before synchronous finalizer reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime cycle removal follows class payload mark hooks"` (`src/tests/core.zig:4576`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime cycle removal follows class payload mark hooks」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "synchronous class payload finalizer drains payload-owned zero-ref children before free returns"` (`src/tests/core.zig:4629`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous class payload finalizer drains payload-owned zero-ref children before free returns」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "synchronous external payload callback pins its generation through reentrant unregister"` (`src/tests/core.zig:4663`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous external payload callback pins its generation through reentrant unregister」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime cycle removal synchronously finalizes class payload object slots once"` (`src/tests/core.zig:4704`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime cycle removal synchronously finalizes class payload object slots once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对对象身份或存活状态。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "plain objects do not allocate class payload storage"` (src/core/object.zig:11688`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「plain objects do not allocate class payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "iterator classes store iterator state in class payload"` (src/core/object.zig:11699`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「iterator classes store iterator state in class payload」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "collection classes store entries in class payload"` (src/core/object.zig:11712`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「collection classes store entries in class payload」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "buffer and typed array state use payload storage"` (src/core/object.zig:11727`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「buffer and typed array state use payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array buffer view list republishes cached typed array count and data"` (`src/tests/core.zig:4811`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array buffer view list republishes cached typed array count and data」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shared array buffer grow refreshes length-tracking typed array state"` (`src/tests/core.zig:4856`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared array buffer grow refreshes length-tracking typed array state」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shared buffer store can back wrappers in separate runtimes"` (`src/tests/core.zig:4871`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared buffer store can back wrappers in separate runtimes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array buffer backing stores report external memory"` (`src/tests/core.zig:4893`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array buffer backing stores report external memory」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary array buffer backing overlaps account and external ledgers"` (`src/tests/core.zig:4913`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary array buffer backing overlaps account and external ledgers」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shared buffer store reports external memory for its owner runtime"` (src/core/object.zig:11753`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared buffer store reports external memory for its owner runtime」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "large shared buffers request a major through external pressure"` (`src/tests/core.zig:4956`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「large shared buffers request a major through external pressure」。
- **实现**：断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime root tracer visits async roots"` (`src/tests/core.zig:5026`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime root tracer visits async roots」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime root frame slots are mutable"` (`src/tests/core.zig:5070`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime root frame slots are mutable」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "value root buffer exposes mutable copied slice"` (`src/tests/core.zig:5118`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「value root buffer exposes mutable copied slice」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp internals use inline storage and lastIndex uses first shape slot"` (src/core/object.zig:11777`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp internals use inline storage and lastIndex uses first shape slot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bound function state uses payload storage"` (src/core/object.zig:11802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bound function state uses payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "proxy state uses payload storage"` (src/core/object.zig:11827`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「proxy state uses payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped arguments state uses inline var-ref storage"` (src/core/object.zig:11843`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments state uses inline var-ref storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "unmapped arguments share a prepared shape and use dense element storage"` (src/core/object.zig:11861`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「unmapped arguments share a prepared shape and use dense element storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object data state uses payload storage"` (src/core/object.zig:11916`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object data state uses payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array element state uses inline fast-array storage"` (src/core/object.zig:11930`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array element state uses inline fast-array storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "promise state uses payload storage"` (src/core/object.zig:11946`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「promise state uses payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "generator state uses payload storage"` (src/core/object.zig:11965`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator state uses payload storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "generator bound and proxy payloads carry no realm compensation"` (src/core/object.zig:12007`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator bound and proxy payloads carry no realm compensation」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "leaf noncarrier payloads carry no borrowed realm compensation"` (src/core/object.zig:12017`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leaf noncarrier payloads carry no borrowed realm compensation」。
- **实现**：断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "object payloads carry no private-name remap side tables"` (src/core/object.zig:12037`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object payloads carry no private-name remap side tables」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "generator completion eagerly releases the resident execution owners"` (`src/tests/core.zig:5425`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator completion eagerly releases the resident execution owners」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 18 处 `std.testing.expect*`。约 18 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "suspended execution preserves and closes open frame var refs"` (`src/tests/core.zig:5478`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「suspended execution preserves and closes open frame var refs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "suspended execution republishes running aliases without a second owner"` (`src/tests/core.zig:5514`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「suspended execution republishes running aliases without a second owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "native function state uses payload storage"` (`src/tests/core.zig:5548`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：function state uses payload storage。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "true C functions own their construction realm while data functions do not"` (`src/tests/core.zig:5579`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「true C functions own their construction realm while data functions do not」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode function state uses the inline qjs function arm"` (`src/tests/core.zig:5628`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode function state uses the inline qjs function arm」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module namespace uses shape-only live-binding storage"` (`src/tests/core.zig:5661`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module namespace uses shape-only live-binding storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.ReadOnly`。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shapes keep property atoms addressable after a transition"` (src/core/shape.zig:1535`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shapes keep property atoms addressable after a transition」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape shared bit and prototype transitions are tracked"` (src/core/shape.zig:1554`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shape shared bit and prototype transitions are tracked」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "restorePropertyLayout rebuilds a baseline layout after FAM relocation"` (src/core/shape.zig:1576`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「restorePropertyLayout rebuilds a baseline layout after FAM relocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape registry create publishes hashed live shapes"` (src/core/shape.zig:1612`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shape registry create publishes hashed live shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape registry hash grows and reuses object root shapes"` (src/core/shape.zig:1630`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shape registry hash grows and reuses object root shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "createObjectRoot leftover reserved flag shares hashed proto roots"` (src/core/shape.zig:1647`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createObjectRoot leftover reserved flag shares hashed proto roots」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "reserved object root shapes reuse only an exact property capacity"` (src/core/shape.zig:1668`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「reserved object root shapes reuse only an exact property capacity」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary object additions reuse transition shapes"` (src/core/shape.zig:1687`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary object additions reuse transition shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace object shape summary follows append kind delete and compaction"` (`src/tests/core.zig:5867`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace object shape summary follows append kind delete and compaction」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 25 处 `std.testing.expect*`。约 25 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace object shape summary base-5 payload decodes all two-slot states"` (`src/tests/core.zig:5983`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace object shape summary base-5 payload decodes all two-slot states」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "pure property value replacement preserves a shared shape until flags change"` (`src/tests/core.zig:6008`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pure property value replacement preserves a shared shape until flags change」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "unique transition shape appends in place across FAM relocation"` (`src/tests/core.zig:6040`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「unique transition shape appends in place across FAM relocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "first property append OOM restores the no-storage sentinel"` (`src/tests/core.zig:6083`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：first property append OOM restores the no-storage sentinel。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "failed new property definition rolls back retained entry"` (`src/tests/core.zig:6118`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「failed new property definition rolls back retained entry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。强制 major / 环回收后比对对象身份或存活状态。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "unique shape append OOM rolls back shape and value storage together"` (`src/tests/core.zig:6152`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：unique shape append OOM rolls back shape and value storage together。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "property compaction removes tombstones without mutating shared sibling shapes"` (`src/tests/core.zig:6207`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「property compaction removes tombstones without mutating shared sibling shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "context lexicals property alias releases context strong reference"` (`src/tests/core.zig:6265`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「context lexicals property alias releases context strong reference」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "failed auto-init property definition rolls back retained entry"` (`src/tests/core.zig:6283`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「failed auto-init property definition rolls back retained entry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "failed realm auto-init property definition rolls back borrowed holder registration"` (`src/tests/core.zig:6322`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「failed realm auto-init property definition rolls back borrowed holder registration」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。强制 major / 环回收后比对对象身份或存活状态。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "property replacement preserves references under memory cap"` (`src/tests/core.zig:6361`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「property replacement preserves references under memory cap」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "definePlainDataPropertyKnownFast refcounted append and duplicate-key replace balance refs"` (`src/tests/core.zig:6391`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「definePlainDataPropertyKnownFast refcounted append and duplicate-key replace balance refs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "definePlainDataPropertyKnownFast barriers follow committed slot and shape writes"` (`src/tests/core.zig:6426`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「definePlainDataPropertyKnownFast barriers follow committed slot and shape writes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "definePlainDataPropertyKnownFast refcounted define survives forced GC at every allocation"` (`src/tests/core.zig:6469`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「definePlainDataPropertyKnownFast refcounted define survives forced GC at every allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCountKind(.object)` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "definePlainDataPropertyKnownFast OOM sweep leaves refcounted value owned by caller"` (`src/tests/core.zig:6532`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：definePlainDataPropertyKnownFast OOM sweep leaves refcounted value owned by caller。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object data property self-assignment keeps stored object alive"` (`src/tests/core.zig:6591`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object data property self-assignment keeps stored object alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "json parse data property self-assignment keeps stored object alive"` (`src/tests/core.zig:6614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「json parse data property self-assignment keeps stored object alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dense array element self-assignment keeps stored object alive"` (`src/tests/core.zig:6630`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array element self-assignment keeps stored object alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "owned dense array writes consume values only on success"` (`src/tests/core.zig:6646`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「owned dense array writes consume values only on success」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "prototype replacement clones shared transition shape"` (`src/tests/core.zig:6667`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prototype replacement clones shared transition shape」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "failed prototype replacement preserves prototype and refcounts"` (`src/tests/core.zig:6689`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「failed prototype replacement preserves prototype and refcounts」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "failed object registration destroys initialized object once"` (`src/tests/core.zig:6717`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「failed object registration destroys initialized object once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape transition cache releases chained shapes"` (`src/tests/core.zig:6742`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shape transition cache releases chained shapes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "large object property lookup uses shape hash across delete and re-add"` (`src/tests/core.zig:6768`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「large object property lookup uses shape hash across delete and re-add」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "exception slot transfers owned value and clears context slot"` (`src/tests/core.zig:6796`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「exception slot transfers owned value and clears context slot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "reference dup and free retain until final release"` (`src/tests/core.zig:6813`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「reference dup and free retain until final release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc registry tracks live objects and intrusive list state"` (`src/tests/core.zig:7023`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：registry tracks live objects and intrusive list state。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "process memory snapshot is needed exactly when a policy field consumes it"` (`src/tests/core.zig:7037`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「process memory snapshot is needed exactly when a policy field consumes it」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "process memory gate preserves external accounting and still fires when consumed"` (`src/tests/core.zig:7091`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「process memory gate preserves external accounting and still fires when consumed」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc process memory pressure policy maps rss and cgroup usage to major requests"` (`src/tests/core.zig:7123`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：process memory pressure policy maps rss and cgroup usage to major requests。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode registration is old-space accounted"` (`src/tests/core.zig:7149`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode registration is old-space accounted」。
- **实现**：断言 19 处 `std.testing.expect*`。约 19 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime exposes stable gc stats snapshot"` (`src/tests/core.zig:7232`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime exposes stable gc stats snapshot」。
- **实现**：断言 18 处 `std.testing.expect*`。约 18 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc live heap stats drop when object is released"` (`src/tests/core.zig:7286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：live heap stats drop when object is released。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "external memory token registry audits duplicate releases and leaks"` (`src/tests/core.zig:7313`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「external memory token registry audits duplicate releases and leaks」。
- **实现**：断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime runs deferred native cleanup jobs with a budget"` (`src/tests/core.zig:7344`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime runs deferred native cleanup jobs with a budget」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "std file object destruction defers native close cleanup"` (`src/tests/core.zig:7373`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「std file object destruction defers native close cleanup」。
- **实现**：部分配置下 `return error.SkipZigTest`。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc callback boundary defers non-urgent major work until idle"` (`src/tests/core.zig:7406`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：callback boundary defers non-urgent major work until idle。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc callback boundary runs urgent major work"` (`src/tests/core.zig:7425`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：callback boundary runs urgent major work。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime force major gc runs an urgent major poll"` (`src/tests/core.zig:7437`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime force major gc runs an urgent major poll」。
- **实现**：强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object child edge tracing exposes mutable value slots"` (`src/tests/core.zig:7448`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object child edge tracing exposes mutable value slots」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc registry debug verifier accepts linked and unlinked list states"` (`src/tests/core.zig:7490`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：registry debug verifier accepts linked and unlinked list states。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc heap accounting derives live bytes"` (`src/tests/core.zig:7504`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：heap accounting derives live bytes。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc heap accounting rejects an orphaned accounted standalone header"` (`src/tests/core.zig:7520`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：heap accounting rejects an orphaned accounted standalone header。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc heap accounting verifier catches missing allocation entries"` (`src/tests/core.zig:7558`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：heap accounting verifier catches missing allocation entries。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.MissingHeapAllocation`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc heap accounting verifier catches pinned header flag drift"` (`src/tests/core.zig:7574`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：heap accounting verifier catches pinned header flag drift。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.PinnedHeaderFlagMismatch`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: block candidate index audit rejects bloom and exact-set drift"` (`src/tests/core.zig:7593`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: block candidate index audit rejects bloom and exact-set drift。
- **实现**：直接建 `core.gc_block_heap.Heap`（不经 Runtime），分配一个 cell 后逐半破坏候选索引：清空 `classed_block_filter` 断言错误 `error.BlockScanFilterMismatch`，从 `classed_blocks` 移除块基址断言错误 `error.BlockIndexMismatch`，每次恢复后再 `heap.verify()` 必须通过。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "gc invariant negative: block heap rejects geometry free-chain and doomed-list corruption"` (`src/tests/core.zig:7620`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: block heap rejects geometry free-chain and doomed-list corruption。
- **实现**：直接建 `core.gc_block_heap.Heap`（不经 Runtime），依次注入四种腐坏并各自恢复：`sweep_state = .needs_sweep` → `error.SweepStateInvariant`、`cell_count += 1` → `error.BlockGeometryCorrupt`、翻转已 free cell 的 poison 字 → `error.FreeCellPoisonMismatch`、把块挂进 `doomed_blocks` 却无 doomed 位 → `error.DoomedListMembershipMismatch`；每次恢复后 `heap.verify()` 必须通过。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "gc invariant negative: block cell publication audit rejects hidden allocations"` (`src/tests/core.zig:7679`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: block cell publication audit rejects hidden allocations。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: metadata semantics reject kind carrier and field misuse"` (`src/tests/core.zig:7710`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: metadata semantics reject kind carrier and field misuse。
- **实现**：用 `expectError` 钉失败路径。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "compact trace retained-RC backlinks are authoritative and audited"` (`src/tests/core.zig:7771`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「compact trace retained-RC backlinks are authoritative and audited」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.CorruptGcList`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace shape summary: incremental writers track the Shape projection"` (`src/tests/core.zig:7819`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace shape summary: incremental writers track the Shape projection」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace shape summary: appends preserve the leased remembered bit"` (`src/tests/core.zig:7913`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace shape summary: appends preserve the leased remembered bit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: representation audit rejects physical carrier and cell index drift"` (`src/tests/core.zig:7968`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: representation audit rejects physical carrier and cell index drift。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "representation audit cross-checks the remembered object cache and map"` (`src/tests/core.zig:8027`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「representation audit cross-checks the remembered object cache and map」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "representation audit cross-checks the remembered cache on a non-object carrier"` (`src/tests/core.zig:8085`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「representation audit cross-checks the remembered cache on a non-object carrier」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "forget fuses the remembered map removal with its own cache bit"` (`src/tests/core.zig:8169`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「forget fuses the remembered map removal with its own cache bit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: construction root audit rejects published shell state"` (`src/tests/core.zig:8234`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: construction root audit rejects published shell state。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc: a remembered detached generator shell is still a construction root"` (`src/tests/core.zig:8283`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「gc: a remembered detached generator shell is still a construction root」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: arena audit rejects an accounted free slab block"` (`src/tests/core.zig:8335`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: arena audit rejects an accounted free slab block。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: address index audit rejects canonical page drift"` (`src/tests/core.zig:8372`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: address index audit rejects canonical page drift。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: heap accounting audit rejects a pin without an entry"` (`src/tests/core.zig:8411`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: heap accounting audit rejects a pin without an entry。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.PinnedHeaderMissingEntry`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: generation audit rejects census and stale remembered drift"` (`src/tests/core.zig:8425`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: generation audit rejects census and stale remembered drift。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。两次注入世代账本漂移并各自恢复：`generation.stats.young_count += 1` → 断言错误 `error.YoungCountMismatch`，往 `generation.remembered` 塞入不存活的 owner `0xdead_0000` → 断言错误 `error.RememberedOwnerNotLive`；每次恢复后 `verifyGenerationInvariants()` 必须通过。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc invariant negative: retirement audit rejects a marked young survivor"` (`src/tests/core.zig:8450`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：invariant negative: retirement audit rejects a marked young survivor。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.RetirementYoungSurvivor`。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object traceChildEdgesFallible propagates visitor errors"` (`src/tests/core.zig:8471`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object traceChildEdgesFallible propagates visitor errors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary object trace visits data slots and TMASK accessor edges"` (`src/tests/core.zig:8491`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary object trace visits data slots and TMASK accessor edges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object traceChildEdgesFallible propagates class payload visitor errors"` (`src/tests/core.zig:8531`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object traceChildEdgesFallible propagates class payload visitor errors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc object release paths do not allocate"` (`src/tests/core.zig:8561`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：object release paths do not allocate。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。`setMemoryLimit(allocated_bytes)` 把上限压到当前字节当分配探针（release 路径一旦分配就会失败），复位为 null 后再 `runObjectCycleRemoval` 用 `containsHeader` 比对对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "zero-ref release drains a deep acyclic object chain iteratively"` (`src/tests/core.zig:8601`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「zero-ref release drains a deep acyclic object chain iteratively」。
- **实现**：直接 `JSRuntime.create`（`gc_threshold = 256 MiB`），精确根/手工对象图。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cycle scan preserves a deeply rooted object chain without recursion"` (`src/tests/core.zig:8614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cycle scan preserves a deeply rooted object chain without recursion」。
- **实现**：直接 `JSRuntime.create`（`gc_threshold = 256 MiB`），精确根/手工对象图。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "closed object property cycle is released by runtime cycle removal"` (`src/tests/core.zig:8695`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「closed object property cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "fast array iterator-next cache cycle is released by runtime cycle removal"` (`src/tests/core.zig:8712`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fast array iterator-next cache cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function_bytecode trace edges visit realm and cpool"` (`src/tests/core.zig:8836`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function_bytecode trace edges visit realm and cpool」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "var_ref trace edges visit the closed binding value"` (`src/tests/core.zig:8859`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「var_ref trace edges visit the closed binding value」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "realm_context trace edges visit the global object"` (`src/tests/core.zig:8871`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「realm_context trace edges visit the global object」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module trace edges visit function, namespace, meta and thrown values"` (`src/tests/core.zig:8885`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module trace edges visit function, namespace, meta and thrown values」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "strong Map and Set entry cycles are released by runtime cycle removal"` (`src/tests/core.zig:8910`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strong Map and Set entry cycles are released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary error stack and callsite cycles are released by runtime cycle removal"` (`src/tests/core.zig:8937`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary error stack and callsite cycles are released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "accessor getter and setter self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:8957`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「accessor getter and setter self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bound function payload self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:8972`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bound function payload self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arguments payload value-slice cycle is released by runtime cycle removal"` (`src/tests/core.zig:8991`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arguments payload value-slice cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object data self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:9014`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object data self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "fallible GC API reports reclaimed objects and no failure"` (`src/tests/core.zig:9028`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fallible GC API reports reclaimed objects and no failure」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw collects a closed property cycle"` (`src/tests/core.zig:9049`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw collects a closed property cycle」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw ephemeron keeps value only when table and key are live"` (`src/tests/core.zig:9062`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw ephemeron keeps value only when table and key are live」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw ephemeron value does not keep its key alive"` (`src/tests/core.zig:9092`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：trace_stw ephemeron value does not keep its key alive。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw WeakRef deref keep-alive lasts until job end"` (`src/tests/core.zig:9117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw WeakRef deref keep-alive lasts until job end」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw WeakRef symbol target dies with its body"` (`src/tests/core.zig:9151`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw WeakRef symbol target dies with its body」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw FinalizationRegistry symbol target enqueues its cleanup"` (`src/tests/core.zig:9181`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw FinalizationRegistry symbol target enqueues its cleanup」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw WeakMap symbol key entry disappears with the symbol"` (`src/tests/core.zig:9219`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw WeakMap symbol key entry disappears with the symbol」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw symbol liveness queries follow the mark inside the sweep phase"` (`src/tests/core.zig:9246`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw symbol liveness queries follow the mark inside the sweep phase」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw WeakRef symbol deref keep-alive survives the same job"` (`src/tests/core.zig:9301`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw WeakRef symbol deref keep-alive survives the same job」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "trace_stw survivor classes on a known graph"` (`src/tests/core.zig:9334`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace_stw survivor classes on a known graph」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "address registry tracks published objects and interior pointers"` (`src/tests/core.zig:9380`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「address registry tracks published objects and interior pointers」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "conservative scan shades a stack-held object header word"` (`src/tests/core.zig:9422`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「conservative scan shades a stack-held object header word」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "carrier protocols keep adjacent one-past roots multi-hit and diagnostics explicit"` (`src/tests/core.zig:9453`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「carrier protocols keep adjacent one-past roots multi-hit and diagnostics explicit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "address registry page radix covers a multi-page allocation"` (`src/tests/core.zig:9485`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「address registry page radix covers a multi-page allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "address registry lookup cost stays with page occupants not live N"` (`src/tests/core.zig:9504`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「address registry lookup cost stays with page occupants not live N」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "size-class table pins the measured §4.2 allocation policy"` (`src/tests/core.zig:9573`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「size-class table pins the measured §4.2 allocation policy」。
- **实现**：断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "size-class table matches measured publication histogram"` (`src/tests/core.zig:9618`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「size-class table matches measured publication histogram」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "block heap splits a 2MiB superblock into 64KiB classed blocks"` (`src/tests/core.zig:9694`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap splits a 2MiB superblock into 64KiB classed blocks」。
- **实现**：断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap reserve OOM is visible and not swallowed"` (`src/tests/core.zig:9739`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：block heap reserve OOM is visible and not swallowed。
- **实现**：断言错误 `error.OutOfMemory`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap rolls a superblock back when its exact index cannot reserve"` (`src/tests/core.zig:9748`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap rolls a superblock back when its exact index cannot reserve」。
- **实现**：断言错误 `error.OutOfMemory`。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap mark epoch lazily clears the mark bitmap"` (`src/tests/core.zig:9772`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap mark epoch lazily clears the mark bitmap」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "minor doomed snapshot preserves the active block lifecycle"` (`src/tests/core.zig:9791`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor doomed snapshot preserves the active block lifecycle」：该测试不涉及 OOM，钉的是 minor doomed 快照之后活动块仍是下一次分配的落点。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "trace carrier mark epoch keeps zero unmarked and scrubs before wrap"` (`src/tests/core.zig:9815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「trace carrier mark epoch keeps zero unmarked and scrubs before wrap」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "block heap nonempty index follows zero-one population transitions"` (`src/tests/core.zig:9852`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap nonempty index follows zero-one population transitions」。
- **实现**：断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap reopens a swept partial block before reserving a fresh block"` (`src/tests/core.zig:9881`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap reopens a swept partial block before reserving a fresh block」。
- **实现**：断言错误 `error.FreeCellPoisonMismatch`。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap aged decommit reports scans release and recommit"` (`src/tests/core.zig:9961`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap aged decommit reports scans release and recommit」。
- **实现**：部分配置下 `return error.SkipZigTest`。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "block heap returns wholly empty medium superblocks and keeps one spare"` (`src/tests/core.zig:10018`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block heap returns wholly empty medium superblocks and keeps one spare」。
- **实现**：断言 21 处 `std.testing.expect*`。约 21 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "process heap trim fires only when a contraction crosses its threshold"` (`src/tests/core.zig:10084`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「process heap trim fires only when a contraction crosses its threshold」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "pollGC runs pending collection and clears pending flag"` (`src/tests/core.zig:10095`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pollGC runs pending collection and clears pending flag」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object allocation drops a stale threshold request after a transient live-byte peak"` (`src/tests/core.zig:10117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object allocation drops a stale threshold request after a transient live-byte peak」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object allocation keeps a threshold request while prospective bytes remain over threshold"` (`src/tests/core.zig:10140`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object allocation keeps a threshold request while prospective bytes remain over threshold」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "stale threshold request cannot mask explicit or pressure major requests"` (`src/tests/core.zig:10162`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stale threshold request cannot mask explicit or pressure major requests」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a pure string loop reaches the allocation-threshold boundary"` (`src/tests/core.zig:10200`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a pure string loop reaches the allocation-threshold boundary」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a pure rope-concat loop reaches the allocation-threshold boundary"` (`src/tests/core.zig:10221`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a pure rope-concat loop reaches the allocation-threshold boundary」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an unrequested threshold crossing is still serviced at the object boundary"` (`src/tests/core.zig:10248`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an unrequested threshold crossing is still serviced at the object boundary」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an unrequested threshold crossing is still serviced at a scheduler poll"` (`src/tests/core.zig:10269`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an unrequested threshold crossing is still serviced at a scheduler poll」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "persistent value handle keeps object and nested symbols alive"` (`src/tests/core.zig:10299`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「persistent value handle keeps object and nested symbols alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "handle scope local keeps object alive until scope exits"` (`src/tests/core.zig:10319`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「handle scope local keeps object alive until scope exits」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "handle scope locals do not clear persistent handles created inside scope"` (`src/tests/core.zig:10343`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「handle scope locals do not clear persistent handles created inside scope」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "native pin retains direct object and counts nested pins"` (`src/tests/core.zig:10372`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：pin retains direct object and counts nested pins。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak persistent value rejects non-weak targets"` (`src/tests/core.zig:10404`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak persistent value rejects non-weak targets」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak persistent value does not retain direct object target"` (`src/tests/core.zig:10414`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：weak persistent value does not retain direct object target。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak persistent value clears object cycle target during gc"` (`src/tests/core.zig:10446`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak persistent value clears object cycle target during gc」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak persistent value clears unrooted symbol target during gc"` (`src/tests/core.zig:10466`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak persistent value clears unrooted symbol target during gc」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function home object cycle is released by runtime cycle removal"` (`src/tests/core.zig:10492`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function home object cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "async continuation function cycle is released by runtime cycle removal"` (`src/tests/core.zig:10506`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async continuation function cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "async generator promise cycle is released by runtime cycle removal"` (`src/tests/core.zig:10524`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async generator promise cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "materialized native function cycle is released by runtime cycle removal"` (`src/tests/core.zig:10542`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「materialized native function cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode constant object cycle is released by runtime cycle removal"` (`src/tests/core.zig:10580`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode constant object cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime destroy releases callback bytecode before object registries"` (`src/tests/core.zig:10602`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime destroy releases callback bytecode before object registries」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "runtime destroy releases nested callback bytecode in owner order"` (`src/tests/core.zig:10614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime destroy releases nested callback bytecode in owner order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "runtime destroy revisits callback bytecode after parent release"` (`src/tests/core.zig:10633`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime destroy revisits callback bytecode after parent release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "runtime destroy releases cyclic callback bytecode constants"` (`src/tests/core.zig:10652`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime destroy releases cyclic callback bytecode constants」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "runtime destroy releases callback bytecode constants with transferred ownership"` (`src/tests/core.zig:10672`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime destroy releases callback bytecode constants with transferred ownership」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "bytecode-only callback constant cycle is released by runtime cycle removal"` (`src/tests/core.zig:10692`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode-only callback constant cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shared function bytecode constant object cycle is released by runtime cycle removal"` (`src/tests/core.zig:10714`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared function bytecode constant object cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cycle teardown frees bytecode function captures before FB metadata"` (`src/tests/core.zig:10741`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cycle teardown frees bytecode function captures before FB metadata」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "nested function bytecode constant object cycle is released by runtime cycle removal"` (`src/tests/core.zig:10766`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested function bytecode constant object cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cyclic internal function bytecode references are released by runtime cycle removal"` (`src/tests/core.zig:10802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cyclic internal function bytecode references are released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class payload function bytecode constant object cycle is released by runtime cycle removal"` (`src/tests/core.zig:10839`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class payload function bytecode constant object cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "realm context owns cached prototype references"` (`src/tests/core.zig:10880`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「realm context owns cached prototype references」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "auto-init slot owns its Realm until the property is deleted"` (`src/tests/core.zig:10906`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「auto-init slot owns its Realm until the property is deleted」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "typed MODULE_NS auto-init publishes a normal value or the same VarRef cell"` (`src/tests/core.zig:10951`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed MODULE_NS auto-init publishes a normal value or the same VarRef cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "MODULE_NS auto-init failure retains its slot Realm and retries once per read"` (`src/tests/core.zig:10992`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「MODULE_NS auto-init failure retains its slot Realm and retries once per read」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "MODULE_NS auto-init reentry cannot overwrite the replacement property"` (`src/tests/core.zig:11017`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「MODULE_NS auto-init reentry cannot overwrite the replacement property」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.IncompatibleDescriptor`。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "auto-init slot exposes the typed Realm and module owner edges"` (`src/tests/core.zig:11045`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「auto-init slot exposes the typed Realm and module owner edges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "unmaterialized MODULE_NS slot participates in Realm cycle marking"` (`src/tests/core.zig:11065`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「unmaterialized MODULE_NS slot participates in Realm cycle marking」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary and object-data payloads ignore generic realm assignment"` (`src/tests/core.zig:11091`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary and object-data payloads ignore generic realm assignment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "native call carriers do not enter borrowed realm bookkeeping"` (`src/tests/core.zig:11110`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：call carriers do not enter borrowed realm bookkeeping。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "generator noncarriers never enter borrowed realm bookkeeping"` (`src/tests/core.zig:11135`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：generator noncarriers never enter borrowed realm bookkeeping。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "leaf payload noncarriers ignore generic realm assignment"` (`src/tests/core.zig:11157`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leaf payload noncarriers ignore generic realm assignment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "promise weak-ref regexp and typed-array payloads ignore generic realm assignment"` (`src/tests/core.zig:11196`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「promise weak-ref regexp and typed-array payloads ignore generic realm assignment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "iterator collection and disposable payloads ignore generic realm assignment"` (`src/tests/core.zig:11225`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「iterator collection and disposable payloads ignore generic realm assignment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "collection iterator prototype follows explicit active realm, never receiver"` (`src/tests/core.zig:11246`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：collection iterator prototype follows explicit active realm, never receiver。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak reference holders use a lifetime intrusive list"` (`src/tests/core.zig:11305`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak reference holders use a lifetime intrusive list」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection borrowed holder cache supports reverse teardown"` (`src/tests/core.zig:11351`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection borrowed holder cache supports reverse teardown」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "fresh object prototype rebinding reuses the shared empty root shape"` (`src/tests/core.zig:11399`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fresh object prototype rebinding reuses the shared empty root shape」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "data to auto-init replacement stays traceable across allocation GC"` (`src/tests/core.zig:11416`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「data to auto-init replacement stays traceable across allocation GC」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "data to auto-init replacement rolls back descriptor OOM and retries in same runtime"` (`src/tests/core.zig:11480`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：data to auto-init replacement rolls back descriptor OOM and retries in same runtime。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "replacing auto-init transfers the owned Realm edge"` (`src/tests/core.zig:11529`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「replacing auto-init transfers the owned Realm edge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "replacing auto-init rolls back descriptor OOM and retries in same runtime"` (`src/tests/core.zig:11570`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：replacing auto-init rolls back descriptor OOM and retries in same runtime。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "deleting auto-init releases its owned Realm edge"` (`src/tests/core.zig:11621`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「deleting auto-init releases its owned Realm edge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary auto-init replacement releases each owned Realm edge"` (`src/tests/core.zig:11638`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary auto-init replacement releases each owned Realm edge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "specialized auto-init producers retain the same typed Realm owner"` (`src/tests/core.zig:11687`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「specialized auto-init producers retain the same typed Realm owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "auto-init descriptor interning reuses value-identical metadata"` (`src/tests/core.zig:11731`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「auto-init descriptor interning reuses value-identical metadata」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "materialized auto-init true C function owns its construction realm"` (`src/tests/core.zig:11756`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「materialized auto-init true C function owns its construction realm」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dead weak collection key entry is swept when target is destroyed"` (`src/tests/core.zig:11794`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dead weak collection key entry is swept when target is destroyed」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dead weak collection key entry is swept without freeing live value"` (`src/tests/core.zig:11820`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dead weak collection key entry is swept without freeing live value」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "live weak collection key preserves stored value"` (`src/tests/core.zig:11841`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「live weak collection key preserves stored value」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak ref target identity does not retain object target"` (`src/tests/core.zig:11865`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：weak ref target identity does not retain object target。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak ref target registration roots direct symbol target"` (`src/tests/core.zig:11891`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak ref target registration roots direct symbol target」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak ref target registration failure leaves target unset"` (`src/tests/core.zig:11920`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak ref target registration failure leaves target unset」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection capacity failure leaves empty holder unregistered"` (`src/tests/core.zig:11934`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection capacity failure leaves empty holder unregistered」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection append failure rolls back borrowed holder registration"` (`src/tests/core.zig:11949`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection append failure rolls back borrowed holder registration」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection capacity reservation keeps empty holder unregistered"` (`src/tests/core.zig:11966`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection capacity reservation keeps empty holder unregistered」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry capacity failure leaves empty holder unregistered"` (`src/tests/core.zig:11978`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry capacity failure leaves empty holder unregistered」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry append failure rolls back borrowed holder registration"` (`src/tests/core.zig:11993`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry append failure rolls back borrowed holder registration」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry job-queue reserve OOM rolls back the cell"` (`src/tests/core.zig:12012`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：finalization registry job-queue reserve OOM rolls back the cell。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry capacity reservation keeps empty holder unregistered"` (`src/tests/core.zig:12040`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry capacity reservation keeps empty holder unregistered」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection delete and clear unregister empty borrowed holder"` (`src/tests/core.zig:12052`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection delete and clear unregister empty borrowed holder」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry unregister unregisters empty borrowed holder"` (`src/tests/core.zig:12079`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry unregister unregisters empty borrowed holder」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry unregister handles token equal to target"` (`src/tests/core.zig:12096`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry unregister handles token equal to target」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry dead target cleanup tolerates held value reentry"` (`src/tests/core.zig:12117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry dead target cleanup tolerates held value reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection delete tolerates value cleanup reentry"` (`src/tests/core.zig:12158`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection delete tolerates value cleanup reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak collection clear tolerates value cleanup reentry"` (`src/tests/core.zig:12174`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak collection clear tolerates value cleanup reentry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak map deep value chain releases without recursive destruction"` (`src/tests/core.zig:12193`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak map deep value chain releases without recursive destruction」。
- **实现**：直接 `JSRuntime.create`（`gc_threshold = 256 MiB`），精确根/手工对象图。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "weak map cycle sweep clears index after removing dead keys"` (`src/tests/core.zig:12220`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「weak map cycle sweep clears index after removing dead keys」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry dead target releases held value when target is destroyed"` (`src/tests/core.zig:12277`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry dead target releases held value when target is destroyed」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry live target preserves held value"` (`src/tests/core.zig:12303`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry live target preserves held value」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry unregister cannot remove queued cleanup cell"` (`src/tests/core.zig:12330`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry unregister cannot remove queued cleanup cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry cleanup enqueue does not allocate after registration"` (`src/tests/core.zig:12382`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：finalization registry cleanup enqueue does not allocate after registration。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。扫描前把内存上限压到当前 `allocated_bytes` 当探针：job slot 在 register 时已预留，所以紧上限下的 sweep 仍能发布三个 cleanup job，而不是注入 OOM。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object allocation threshold triggers runtime cycle removal"` (`src/tests/core.zig:12449`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object allocation threshold triggers runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object allocation collects reclaimable cycles before memory-limit rejection"` (`src/tests/core.zig:12478`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object allocation collects reclaimable cycles before memory-limit rejection」。
- **实现**：直接 `JSRuntime.create`（`gc_threshold = 256 MiB`），精确根/手工对象图。随后 `setGCThreshold(0)` + `setMemoryLimit(allocated_bytes)`，逼分配边界先回收可达环再做上限检查，替换对象因此仍能分配成功（不断言 OOM）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cache-miss root shape is owned before the object allocation GC boundary"` (`src/tests/core.zig:12515`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cache-miss root shape is owned before the object allocation GC boundary」。
- **实现**：直接 `JSRuntime.create`（`gc_threshold = 256 MiB`），精确根/手工对象图。阈值设在 `allocated_before + @sizeOf(Object)`、内存上限设在 `allocated_before + root shape 字节`，钉 cache-miss root Shape 先于对象分配 GC 边界被拥有，分配成功而非 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "post-shape object OOM rolls back construction owners and retries in the same runtime"` (`src/tests/core.zig:12556`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：post-shape object OOM rolls back construction owners and retries in the same runtime。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "shape reserve OOM does not publish or retain proto"` (`src/tests/core.zig:12629`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：shape reserve OOM does not publish or retain proto。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc threshold API resets after scheduled collection and survives force-GC instrumentation"` (`src/tests/core.zig:12655`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：threshold API resets after scheduled collection and survives force-GC instrumentation。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "proxy target handler cycle is released by runtime cycle removal"` (`src/tests/core.zig:12691`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「proxy target handler cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime cycle removal preserves externally rooted outgoing objects"` (`src/tests/core.zig:12706`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime cycle removal preserves externally rooted outgoing objects」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module namespace shape VarRef cycle is released by runtime cycle removal"` (`src/tests/core.zig:12734`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module namespace shape VarRef cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped arguments var-ref cycle is released by runtime cycle removal"` (`src/tests/core.zig:12751`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments var-ref cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array element self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:12767`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array element self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "typed-array buffer self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:12778`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed-array buffer self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array buffer and linked typed array cycle survives arbitrary finalizer order"` (`src/tests/core.zig:12789`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array buffer and linked typed array cycle survives arbitrary finalizer order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp lastIndex self-cycle is released by runtime cycle removal"` (`src/tests/core.zig:12811`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp lastIndex self-cycle is released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "realm module registry keeps published record addresses stable"` (`src/tests/core.zig:12825`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「realm module registry keeps published record addresses stable」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module registries isolate records between realms"` (`src/tests/core.zig:12845`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module registries isolate records between realms」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module registry trace keeps a linked record alive"` (`src/tests/core.zig:12872`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module registry trace keeps a linked record alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "explicitly rooted module outlives realm registry teardown"` (`src/tests/core.zig:12890`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「explicitly rooted module outlives realm registry teardown」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module namespace strong edge participates in realm object cycle collection"` (`src/tests/core.zig:12920`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module namespace strong edge participates in realm object cycle collection」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Nth module allocation OOM leaves registry and Atom ownership recoverable"` (`src/tests/core.zig:12948`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：Nth module allocation OOM leaves registry and Atom ownership recoverable。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime memory usage counts linked and explicitly rooted unlinked modules"` (`src/tests/core.zig:12989`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime memory usage counts linked and explicitly rooted unlinked modules」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module publication retains indexed metadata and all strong value edges"` (`src/tests/core.zig:13033`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module publication retains indexed metadata and all strong value edges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 22 处 `std.testing.expect*`。约 22 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "pending module metadata and publication OOM are atomic"` (`src/tests/core.zig:13100`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：pending module metadata and publication OOM are atomic。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module registry resolves local indirect star and ambiguous exports"` (`src/tests/core.zig:13142`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module registry resolves local indirect star and ambiguous exports」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "existing published module generation is not overwritten by pending definition"` (`src/tests/core.zig:13210`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「existing published module generation is not overwritten by pending definition」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "indexed module resolution is pure across not-found ambiguous and cyclic graphs"` (`src/tests/core.zig:13244`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「indexed module resolution is pure across not-found ambiguous and cyclic graphs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.ModuleNotFound`。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module resolution follows local exports of ordinary imports"` (`src/tests/core.zig:13338`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module resolution follows local exports of ordinary imports」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module resolution normalizes namespace re-export bindings"` (`src/tests/core.zig:13399`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module resolution normalizes namespace re-export bindings」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime stack and interrupt state are stored"` (`src/tests/core.zig:13515`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime stack and interrupt state are stored」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "realm interrupt cadence advances without a handler and is realm-local"` (`src/tests/core.zig:13536`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「realm interrupt cadence advances without a handler and is realm-local」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary objects define own data properties and descriptors"` (`src/tests/core.zig:13578`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary objects define own data properties and descriptors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "define property enforces non-configurable and non-writable invariants"` (`src/tests/core.zig:13598`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「define property enforces non-configurable and non-writable invariants」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "accessor descriptors store getter setter placeholders"` (`src/tests/core.zig:13618`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「accessor descriptors store getter setter placeholders」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "prototype traversal and cycle checks are enforced"` (`src/tests/core.zig:13640`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prototype traversal and cycle checks are enforced」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.PrototypeCycle`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "own keys follow index string symbol ordering"` (`src/tests/core.zig:13656`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「own keys follow index string symbol ordering」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "extensibility seal and freeze update descriptor flags"` (`src/tests/core.zig:13682`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「extensibility seal and freeze update descriptor flags」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.NotExtensible`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array length tracks sparse indices and truncation"` (`src/tests/core.zig:13710`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array length tracks sparse indices and truncation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.ReadOnly`。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array indexed delete does not let dense holes mask ordinary properties"` (`src/tests/core.zig:13731`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：array indexed delete does not let dense holes mask ordinary properties。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array element storage mode moves between dense and sparse"` (`src/tests/core.zig:13746`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array element storage mode moves between dense and sparse」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "exotic dispatch hooks are called without builtin shortcuts"` (`src/tests/core.zig:13786`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「exotic dispatch hooks are called without builtin shortcuts」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "explicit value root preserves and releases a symbol across GC"` (`src/tests/core.zig:13856`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「explicit value root preserves and releases a symbol across GC」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalization registry pending jobs preserve callback and held symbols"` (`src/tests/core.zig:13874`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalization registry pending jobs preserve callback and held symbols」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "basecase multiplication never reads an uninitialized result limb"` (`src/libs/bigint.zig:1476`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：basecase multiplication never reads an uninitialized result limb。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "inline FAM multiplication matches the external kernel limb for limb"` (`src/core/bigint.zig:665`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline FAM multiplication matches the external kernel limb for limb」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap multiplication costs one allocation and one block"` (`src/core/bigint.zig:729`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap multiplication costs one allocation and one block」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap multiplication crosses the slab boundary into standalone blocks"` (`src/core/bigint.zig:763`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap multiplication crosses the slab boundary into standalone blocks」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap multiplication reports its single allocation failure cleanly"` (`src/core/bigint.zig:810`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap multiplication reports its single allocation failure cleanly」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "heap multiplication rejects an oversize product before allocating"` (`src/core/bigint.zig:854`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap multiplication rejects an oversize product before allocating」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.BigIntTooLarge`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "repeated heap multiplication retains nothing as the count grows"` (`src/core/bigint.zig:877`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「repeated heap multiplication retains nothing as the count grows」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "single-limb division is exact and allocation-bounded"` (`src/libs/bigint.zig:1511`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「single-limb division is exact and allocation-bounded」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "multi-limb division survives a failure at every allocation point"` (`src/libs/bigint.zig:1584`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「multi-limb division survives a failure at every allocation point」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "normalized long division handles every quotient-estimate correction"` (`src/libs/bigint.zig:1656`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「normalized long division handles every quotient-estimate correction」。
- **实现**：冻结 8 条 `Vector{ a, b, event }` 语料（`one correction` ×2、`two corrections`、`three corrections`、`add-back` ×3、`clamped estimate`），每条对四种符号组合 `inline for` 调 `expectDivisionIdentity` 校验 `a = q*b + r` 恒等式；失败时先 `std.debug.print` 打出该向量的 event 名再回抛错误。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "normalized long division covers every normalization shift"` (`src/libs/bigint.zig:1728`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「normalized long division covers every normalization shift」。
- **实现**：用 `std.Random.DefaultPrng.init(0x604C3)` 枚举全部 64 个归一化移位：除数顶 limb 的最高位固定在 `63 - shift`，除数限数 nb ∈ 2..5、被除数限数 na ∈ nb..nb+3，`na == nb` 时把顶 limb 拉到 `maxInt` 以避开提前返回，每组对正负被除数各调一次 `expectDivisionIdentity`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "normalized long division covers the operand relations"` (`src/libs/bigint.zig:1756`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「normalized long division covers the operand relations」。
- **实现**：固定三限除数 `{ 0xDEAD_BEEF_CAFE_BABE, 1, 0x4000_0000_0000_0000 }`，用 6 次 `expectDivisionIdentity` 覆盖操作数关系：lhs < rhs、lhs == rhs、商恰为 1（`cloneWithAllocator` + `addPositiveSmallInPlace(1)`）、整除（`bigint.mulAlloc`）、该商下的最大余数（`bigint.subAlloc` 减一，并再跑一次双负号）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "normalized long division skips a known-zero leading digit"` (`src/libs/bigint.zig:1787`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「normalized long division skips a known-zero leading digit」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "reciprocal two-by-one division is exactly the wide division"` (`src/libs/bigint.zig:1843`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「reciprocal two-by-one division is exactly the wide division」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "minor collection reclaims young garbage and promotes survivors"` (`src/tests/core.zig:14905`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor collection reclaims young garbage and promotes survivors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "minor block mark clearing preserves old sticky marks"` (`src/tests/core.zig:14927`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor block mark clearing preserves old sticky marks」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the minor reclaims young cycles and parks no deferred frees"` (`src/tests/core.zig:14949`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the minor reclaims young cycles and parks no deferred frees」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "minor pause distribution retains the complete diagnostic run"` (`src/tests/core.zig:14995`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor pause distribution retains the complete diagnostic run」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "old-to-young edge survives a minor only because the barrier remembered it"` (`src/tests/core.zig:15021`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「old-to-young edge survives a minor only because the barrier remembered it」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object remembered bit is consumed and rebuilt across consecutive minors"` (`src/tests/core.zig:15076`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object remembered bit is consumed and rebuilt across consecutive minors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental retirement clears remembered cache before the next generation"` (`src/tests/core.zig:15123`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental retirement clears remembered cache before the next generation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 18 处 `std.testing.expect*`。约 18 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "non-object remembered owners use the byte-6 cache and re-arm across consecutive minors"` (`src/tests/core.zig:15194`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「non-object remembered owners use the byte-6 cache and re-arm across consecutive minors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "minor full-trace verifier owns its reachability set per runtime"` (`src/tests/core.zig:15243`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor full-trace verifier owns its reachability set per runtime」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the generational barrier ignores edges a minor would find anyway"` (`src/tests/core.zig:15271`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the generational barrier ignores edges a minor would find anyway」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the folded barrier gate skips exactly the two owner facts"` (`src/tests/core.zig:15286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the folded barrier gate skips exactly the two owner facts」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the barrier gate closes on every phase that needs a richer arm"` (`src/tests/core.zig:15361`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the barrier gate closes on every phase that needs a richer arm」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the barrier shades exact targets while marking and remembers owners otherwise"` (`src/tests/core.zig:15413`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the barrier shades exact targets while marking and remembers owners otherwise」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the barrier shades a target the marker had already passed"` (`src/tests/core.zig:15436`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the barrier shades a target the marker had already passed」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "segmented shared mark frontier grows without dropping work"` (`src/tests/core.zig:15471`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「segmented shared mark frontier grows without dropping work」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "mark frontier whitelist encodes the epoch exemption"` (`src/tests/core.zig:15497`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mark frontier whitelist encodes the epoch exemption」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "checked frontier admission requires a published marked header"` (`src/tests/core.zig:15518`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「checked frontier admission requires a published marked header」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "frontier requeue admission checks a prior claim without executing one"` (`src/tests/core.zig:15536`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「frontier requeue admission checks a prior claim without executing one」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "G-Shape indexed adoption shades the Shape once without requeueing the array"` (`src/tests/core.zig:15571`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G-Shape indexed adoption shades the Shape once without requeueing the array」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "G-Shape adoption traces prototype children and symbol keys but skips white owners"` (`src/tests/core.zig:15592`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G-Shape adoption traces prototype children and symbol keys but skips white owners」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "G-Shape prototype frontier OOM fails before tracing or sweeping"` (`src/tests/core.zig:15639`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：G-Shape prototype frontier OOM fails before tracing or sweeping。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "G-Shape relocation leaves no raw Shape queued and survives declared major GC"` (`src/tests/core.zig:15662`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G-Shape relocation leaves no raw Shape queued and survives declared major GC」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "G-Shape unpublished adoption does not publish a pending owner or target"` (`src/tests/core.zig:15699`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：G-Shape unpublished adoption does not publish a pending owner or target。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Shape barrier requeues only an owner with a prior mark claim"` (`src/tests/core.zig:15728`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Shape barrier requeues only an owner with a prior mark claim」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental abort disables marking before draining every frontier segment"` (`src/tests/core.zig:15763`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental abort disables marking before draining every frontier segment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the barrier queue hands whole segments to a private mark stack"` (`src/tests/core.zig:15789`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the barrier queue hands whole segments to a private mark stack」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "an abandoned retirement transaction closes minors until a major repairs it"` (`src/tests/core.zig:15815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an abandoned retirement transaction closes minors until a major repairs it」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a major retires every block-cell survivor it traces"` (`src/tests/core.zig:15851`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a major retires every block-cell survivor it traces」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a conservative candidate on a shared extent boundary visits both extents"` (`src/tests/core.zig:15899`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a conservative candidate on a shared extent boundary visits both extents」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a published string extent takes no occupant entry and still resolves conservatively"` (`src/tests/core.zig:15958`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a published string extent takes no occupant entry and still resolves conservatively」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "minor collection reclaims an unreachable young string extent"` (`src/tests/core.zig:16011`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor collection reclaims an unreachable young string extent」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a rooted or remembered young string extent survives the minor"` (`src/tests/core.zig:16043`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a rooted or remembered young string extent survives the minor」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the whole-heap iterator enumerates string extents and a major removes the unreachable one"` (`src/tests/core.zig:16088`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the whole-heap iterator enumerates string extents and a major removes the unreachable one」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the full-reachable verifier restores extent marks and atom epoch stamps"` (`src/tests/core.zig:16153`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the full-reachable verifier restores extent marks and atom epoch stamps」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental begin preserves list-young suffix until finish retirement"` (`src/tests/core.zig:16216`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental begin preserves list-young suffix until finish retirement」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "representation audit guards block-cell marker direct dispatch"` (`src/tests/core.zig:16269`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「representation audit guards block-cell marker direct dispatch」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "independent runtimes collect without touching each other"` (`src/tests/core.zig:16288`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「independent runtimes collect without touching each other」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a crossing a minor cannot answer is still answered by a major"` (`src/tests/core.zig:16332`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a crossing a minor cannot answer is still answered by a major」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a minor-only workload still returns free block pages to the OS"` (`src/tests/core.zig:16391`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a minor-only workload still returns free block pages to the OS」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ten thousand plain object deaths reach no destructor"` (`src/tests/core.zig:16432`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ten thousand plain object deaths reach no destructor」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "young churn that crosses the threshold is paid by the minor, not by a major"` (`src/tests/core.zig:16479`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「young churn that crosses the threshold is paid by the minor, not by a major」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an old generation that keeps growing keeps triggering majors"` (`src/tests/core.zig:16517`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an old generation that keeps growing keeps triggering majors」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a dense buffer adopted by an aged array is remembered for the next minor"` (`src/tests/core.zig:16570`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a dense buffer adopted by an aged array is remembered for the next minor」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp capture strings survive a minor taken inside the match-array fill"` (`src/tests/core.zig:16623`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp capture strings survive a minor taken inside the match-array fill」。
- **实现**：部分配置下 `return error.SkipZigTest`。独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(function () {   var letters = "abcdefghijk";   var parts = [];   for (var p = 0; p < letters.length; p++) {     var seg = "";     for (var `。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "a minor does not move the major's threshold"` (`src/tests/core.zig:16672`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：a minor does not move the major's threshold。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "minor detailed stats decompose the outer STW envelope"` (`src/tests/core.zig:16701`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「minor detailed stats decompose the outer STW envelope」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "cell resolution stops at the block header and at unallocated cells"` (`src/tests/core.zig:16742`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cell resolution stops at the block header and at unallocated cells」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "carrier exact handles reject stale block-cell generations"` (`src/tests/core.zig:16763`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「carrier exact handles reject stale block-cell generations」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production current-membership API cannot carry generation or lifecycle state"` (`src/tests/core.zig:16825`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：current-membership API cannot carry generation or lifecycle state。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "carrier generation authorities reject wrap in both extent and block schemes"` (`src/tests/core.zig:16833`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「carrier generation authorities reject wrap in both extent and block schemes」。
- **实现**：断言错误 `error.OutOfMemory`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "a minor that keeps reclaiming nothing stops being offered"` (`src/tests/core.zig:16850`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a minor that keeps reclaiming nothing stops being offered」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "marking barrier shades grey, not black: the stored object's children survive the remark"` (`src/tests/core.zig:16885`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「marking barrier shades grey, not black: the stored object's children survive the remark」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mark frontier allocation failure invalidates rather than rescans"` (`src/tests/core.zig:16928`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mark frontier allocation failure invalidates rather than rescans」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "runtime recovers a frontier OOM through allocation-boundary full GC"` (`src/tests/core.zig:16942`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：runtime recovers a frontier OOM through allocation-boundary full GC。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental marking preserves a frontier beyond both former 65K bounds"` (`src/tests/core.zig:17004`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental marking preserves a frontier beyond both former 65K bounds」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental settled account excludes storage bytes already debited at condemnation"` (`src/tests/core.zig:17052`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental settled account excludes storage bytes already debited at condemnation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental settled account retains finalizer and list corpse charges"` (`src/tests/core.zig:17085`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental settled account retains finalizer and list corpse charges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental destruction credit reconciles each reclaimed byte once"` (`src/tests/core.zig:17126`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental destruction credit reconciles each reclaimed byte once」。
- **实现**：断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "incremental destruction credit funds safe assists from actual native backing release"` (`src/tests/core.zig:17162`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental destruction credit funds safe assists from actual native backing release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental destruction credit rejects growth without sufficient deferred charges"` (`src/tests/core.zig:17219`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental destruction credit rejects growth without sufficient deferred charges」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental marking retains requested-byte pacing across storage growth"` (`src/tests/core.zig:17267`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental marking retains requested-byte pacing across storage growth」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental scheduler slices consume existing allocation assist debt"` (`src/tests/core.zig:17296`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental scheduler slices consume existing allocation assist debt」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an incremental cycle frees threshold garbage across bounded polls"` (`src/tests/core.zig:17315`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an incremental cycle frees threshold garbage across bounded polls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object allocation boundaries pace incremental assists by allocation debt"` (`src/tests/core.zig:17373`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object allocation boundaries pace incremental assists by allocation debt」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "condemning many shapes leaves the transition table exactly consistent"` (`src/tests/core.zig:17423`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「condemning many shapes leaves the transition table exactly consistent」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the marked-set census is its own opt-in, not a rider on the stats panel"` (`src/tests/core.zig:17489`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the marked-set census is its own opt-in, not a rider on the stats panel」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "the incremental finish reports a remark segment net of its census walk"` (`src/tests/core.zig:17520`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「the incremental finish reports a remark segment net of its census walk」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental cycle envelope keeps one exact MemoryAccount S T P domain"` (`src/tests/core.zig:17557`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental cycle envelope keeps one exact MemoryAccount S T P domain」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "synchronous incremental destruction drains more than one parked-free budget"` (`src/tests/core.zig:17607`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous incremental destruction drains more than one parked-free budget」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "terminal pending stats count accounted block and standalone corpses"` (`src/tests/core.zig:17648`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「terminal pending stats count accounted block and standalone corpses」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "pending class finalizer keeps the incremental morgue open"` (`src/tests/core.zig:17701`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pending class finalizer keeps the incremental morgue open」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "incremental block finalizer observes its object without sweep publication"` (`src/tests/core.zig:17756`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「incremental block finalizer observes its object without sweep publication」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "a store during an incremental cycle keeps the stored subgraph alive to the remark"` (`src/tests/core.zig:17792`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a store during an incremental cycle keeps the stored subgraph alive to the remark」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an explicit collection supersedes an open incremental cycle with full precision"` (`src/tests/core.zig:17836`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an explicit collection supersedes an open incremental cycle with full precision」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an urgent poll aborts the open cycle and collects fully"` (`src/tests/core.zig:17868`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an urgent poll aborts the open cycle and collects fully」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime teardown owns a detached generator shell"` (`src/tests/core.zig:17892`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime teardown owns a detached generator shell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime 所有权，但不用 `defer`——teardown 顺序本身是被测对象，`rt.destroy()` 在测试体末尾显式调用；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3: a shape property key is an atom trace edge"` (`src/tests/core.zig:17920`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: a shape property key is an atom trace edge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3: an inline bytecode atom operand is an atom trace edge"` (`src/tests/core.zig:17939`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: an inline bytecode atom operand is an atom trace edge」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.zjsS3Keep = function (o) { return o.zjsS3BytecodeOperand; };`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "TGC S3: a module record name is an atom trace edge"` (`src/tests/core.zig:17957`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: a module record name is an atom trace edge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3: an id-held value symbol keeps its body marked"` (`src/tests/core.zig:17977`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: an id-held value symbol keeps its body marked」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: an atom no edge and no root reaches is retired by the major"` (`src/tests/core.zig:18000`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: an atom no edge and no root reaches is retired by the major」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-b: a compile scope roots an atom no holder edge names"` (`src/tests/core.zig:18022`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-b: a compile scope roots an atom no holder edge names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-b: a compile scope on a runtime-less table records without registering"` (`src/tests/core.zig:18056`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-b: a compile scope on a runtime-less table records without registering」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TGC S3-c: the atom entry census falls back after a major"` (`src/tests/core.zig:18082`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: the atom entry census falls back after a major」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: a young symbol body a shape names by id survives a minor"` (`src/tests/core.zig:18113`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: a young symbol body a shape names by id survives a minor」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: a thousand fresh symbol keys survive the minors taken while they accumulate"` (`src/tests/core.zig:18161`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: a thousand fresh symbol keys survive the minors taken while they accumulate」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: a symbol interned inside a marking window keeps its body"` (`src/tests/core.zig:18190`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: a symbol interned inside a marking window keeps its body」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: a shape key keeps its atom, and the next major after the shape dies retires it"` (`src/tests/core.zig:18221`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: a shape key keeps its atom, and the next major after the shape dies retires it」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: a WeakRef'd symbol still leaves a weak shell instead of a recycled slot"` (`src/tests/core.zig:18248`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: a WeakRef'd symbol still leaves a weak shell instead of a recycled slot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3: the insertion barrier shades an atom stored during marking"` (`src/tests/core.zig:18286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: the insertion barrier shades an atom stored during marking」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: the atom verdict is applied in the pause that took it, not after the morgue drains"` (`src/tests/core.zig:18312`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: the atom verdict is applied in the pause that took it, not after the morgue drains」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "needs_finalizer is recorded in both the header and the block bitmap"` (`src/tests/core.zig:18358`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「needs_finalizer is recorded in both the header and the block bitmap」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "storage-cell mint writes runtime kind tags on block and extent paths"` (`src/tests/core.zig:18444`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「storage-cell mint writes runtime kind tags on block and extent paths」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-b: an external property buffer survives with its owner and dies one major later"` (`src/tests/core.zig:18482`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-b: an external property buffer survives with its owner and dies one major later」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-b: an aged owner remembers a property buffer minted after its promotion"` (`src/tests/core.zig:18510`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-b: an aged owner remembers a property buffer minted after its promotion」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Q22: a bitmap-reclaimed storage cell leaves the byte ledger exactly once"` (`src/tests/core.zig:18537`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Q22: a bitmap-reclaimed storage cell leaves the byte ledger exactly once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-b: a growing dense array leaves every superseded element cell to the sweep"` (`src/tests/core.zig:18584`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-b: a growing dense array leaves every superseded element cell to the sweep」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Q21: the element cell is kept alive by the arm, not by flags.fast_array"` (`src/tests/core.zig:18611`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Q21: the element cell is kept alive by the arm, not by flags.fast_array」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-b: a mapped-arguments var-ref table is an array storage cell"` (`src/tests/core.zig:18647`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-b: a mapped-arguments var-ref table is an array storage cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-b: storage over the block-cell ceiling takes the extent route and is swept"` (`src/tests/core.zig:18677`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-b: storage over the block-cell ceiling takes the extent route and is swept」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "promise coallocation: state and reactions survive through the sole owner"` (`src/tests/core.zig:18726`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「promise coallocation: state and reactions survive through the sole owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "promise coallocation: accounting and allocation failure share the object cell"` (`src/tests/core.zig:18774`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「promise coallocation: accounting and allocation failure share the object cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。强制 major / 环回收后比对 `liveCount` 或对象身份。设置 runtime 内存上限以注入 OOM。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-c: every a-class payload is a cell that dies one major after its owner"` (`src/tests/core.zig:18802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-c: every a-class payload is a cell that dies one major after its owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-c: a bytecode function's rare/aux record is a payload cell"` (`src/tests/core.zig:18883`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-c: a bytecode function's rare/aux record is a payload cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-c: an aged promise remembers a reaction cell minted after its promotion"` (`src/tests/core.zig:18912`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-c: an aged promise remembers a reaction cell minted after its promotion」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-c: bound arguments, disposable resources and arguments var-refs cross a major"` (`src/tests/core.zig:18947`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-c: bound arguments, disposable resources and arguments var-refs cross a major」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S4-c: a payload slice over the block-cell ceiling takes the extent route"` (`src/tests/core.zig:19012`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S4-c: a payload slice over the block-cell ceiling takes the extent route」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

## 覆盖核对

- 清单函数数: 112
- 本文标题覆盖: 627
- 未覆盖: 无
