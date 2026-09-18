# 01 — `JSContext` 门面

> binding 层 `CallSite` 与 `defineClass` 已删除。native → JS 走 `JSContext.callFunction` → `exec/call_site.zig`。下文若仍写 `CallSite` / `defineClass`，以源码为准。

`src/binding/context.zig` 提供 core realm 的宿主门面。拥有型构造建立 core context 的宿主根，deinit/destroy 撤销这份根；realm 本身由 tracing GC 管理，仍被函数、job 等对象引用时可以继续存活。borrowCore 只借用已有 core 指针。公共构造在成功返回前完成 global/intrinsic bootstrap，但各个 auto-init 属性仍可延迟物化；不能把“公共 context 已就绪”理解为所有 builtin 属性均已实例化。

---

## 类型

| 名字 | 含义 |
| --- | --- |
| `ContextCreateTiming` | 内部诊断：`raw_create_ns` / `bootstrap_ns`。完整公共边界仍是调用方在 `createWithOptionsMeasured` 外层计时。 |
| `JSContext` | `{ core: *core.JSContext }`。堆身份即这个指针。 |
| `CallSite` | `{ ctx: *JSContext, site: exec.call_site.CallSite }`。解析一次的 native→JS 目标。 |
| `CallSite.Options` | `this_value`、`output`（`print`/`console.log` 的 writer；null = 进程 stdout）。 |

`PublicValueRootWindow(count)` 为部分公共嵌入调用临时保存并登记裸 JSValue。当前 `core.runtime.value_root_frames_enabled` 恒为 true，因此 slice 描述符和 frame 在生产配置中也存在；源文件中的旧 RC 擦除注释不代表当前行为。

---

## 根窗口与创建

### `PublicValueRootWindow` (`src/binding/context.zig:28`)

- **签名**：`fn PublicValueRootWindow(comptime count: usize) type`。
- **作用**：生成「`count` 个 JSValue + 可选 ValueRootFrame」的栈结构类型。
- **实现**：字段 `values: [count]JSValue`；`slices`/`frame` 在 `value_root_frames_enabled` 时存在，否则是 `void`。
- **所有权 / 错误 / 调用**：`getPropertyKey` / `deletePropertyKey` / `hasOwnPropertyKey` / `ownPropertyDescriptor` 各窗口 2 个值。

### `PublicValueRootWindow.init` (`src/binding/context.zig:38`)

- **签名**：`fn init(values: [count]JSValue) Self`。
- **作用**：按值拷进窗口。
- **实现**：`return .{ .values = values };`
- **所有权 / 错误 / 调用**：只复制 JSValue 位表示，不复制堆对象，也不自动激活根；必须随后 activate 才提供这份存活保证。

### `PublicValueRootWindow.activate` (`src/binding/context.zig:42`)

- **签名**：`fn activate(self: *Self, rt: *JSRuntime) void`。
- **作用**：若精确根开着，把 `values` 挂成 borrowed slice 并 `frame.activate(rt)`。
- **实现**：`comptime` 开关；关掉则空操作。
- **所有权 / 错误 / 调用**：当前配置也执行，须配对 deactivate。frame 借用窗口内部数组，激活期间不能移动窗口或使其存储失效；不替调用方建立跨调用的持久根。

### `PublicValueRootWindow.deactivate` (`src/binding/context.zig:50`)

- **签名**：`fn deactivate(self: *Self, rt: *JSRuntime) void`。
- **作用**：卸下刚才挂的 frame。
- **实现**：enabled 时 `frame.deactivate(rt)`。
- **所有权 / 错误 / 调用**：LIFO；与 core `ValueRootFrame` 协议一致。

### `ensureStandardGlobalsRegistered` (`src/binding/context.zig:56`)

- **签名**：`fn ensureStandardGlobalsRegistered(rt: *JSRuntime) void`。
- **作用**：保证 runtime 有 context-global 物化回调，以及 standard globals 的 install 回调/容量。
- **实现**：`materialize_context_global_cb == null` 则装 `zjs_vm.contextGlobal`；`install_standard_globals_cb == null` 则 `standard_globals.configureRuntime(rt)`。两个回调必须在第一个 realm 物化前配对。
- **所有权 / 错误 / 调用**：已有非 null 回调不被覆盖；两个条件分别判断，不验证宿主预装回调与容量是否匹配。这里只配置回调，不创建某个 realm 的 global；构造、globalObject 和执行入口按各自路径使用它。

### `context.cb` (`src/binding/context.zig:59`)

- **签名**：`fn cb(c: *core.JSContext) anyerror!*core.Object`。
- **作用**：runtime 的 global 物化回调：走 VM 的 `contextGlobal`（装标准对象）。
- **实现**：`return try exec.zjs_vm.contextGlobal(c);`
- **所有权 / 错误 / 调用**：core 在第一次 `globalObject` 时调。OOM 等沿 `anyerror` 上浮。

### `initWithOptionsImpl` (`src/binding/context.zig:80`)

- **签名**：`fn initWithOptionsImpl( comptime measure: bool, self: *JSContext, rt: *JSRuntime, options: core.ContextOptions, timing: if (measure) *ContextCreateTiming else void, ) !void`。
- **作用**：公共构造的真实实现：先注册 globals 回调，再造 core context，再物化 global（intrinsic bootstrap）。
- **实现**：记下 `rt.gcThreshold()`，`defer` 设回去（bootstrap 可能跑 GC 并改阈值）。`core.JSContext.createConstructingWithOptions`；`errdefer core.destroy()`。measure 时用 `platform_clock` 累加 `raw_create_ns` / `bootstrap_ns`。bootstrap = `self.core.globalObject()`。
- **所有权 / 错误 / 调用**：self 须是可写且未持有另一活跃 context 的门面槽。core 创建失败时不赋值；bootstrap 失败时调用 core.destroy 撤销新 context 的宿主根，不保证立即释放 core 堆块，self 也不会被清零，不能当作成功初始化后再 deinit。阈值在成功和失败时均恢复，回调配置及其他 runtime 副作用不回滚。

### `createWithOptionsImpl` (`src/binding/context.zig:105`)

- **签名**：`fn createWithOptionsImpl( comptime measure: bool, rt: *JSRuntime, options: core.ContextOptions, timing: if (measure) *ContextCreateTiming else void, ) !*JSContext`。
- **作用**：从 runtime 分配器分配门面，再 `initWithOptionsImpl`。
- **实现**：`rt.memory.create(JSContext)`，`errdefer destroy`。
- **所有权 / 错误 / 调用**：返回的指针由调用方 `destroy` 一次。

### `createWithOptionsMeasured` (`src/binding/context.zig:119`)

- **签名**：`pub fn createWithOptionsMeasured( rt: *JSRuntime, options: core.ContextOptions, timing: *ContextCreateTiming, ) !*JSContext`。
- **作用**：走同一构造实现，分别测量 core 创建和 bootstrap 两个区间；成功路径每个区间各读取起止时钟。
- **实现**：`createWithOptionsImpl(true, ...)`。
- **所有权 / 错误 / 调用**：时间累加到传入结构，不先清零；阶段失败时不会累加该阶段的耗时，此前完成阶段的计数保留。统计不包括门面分配、完整退出清理等外层成本，完整构造时间需调用方另测。对象所有权同 createWithOptions。

### `JSContext.borrowCore` (`src/binding/context.zig:134`)

- **签名**：`pub fn borrowCore(core_ctx: *core.JSContext) JSContext`。
- **作用**：给已经带着稳定 core 指针的回调做一个非拥有门面。
- **实现**：`return .{ .core = core_ctx };`
- **所有权 / 错误 / 调用**：不分配、不保活 core，也不执行 bootstrap；不能对借用门面调用 destroy/deinit。使用期限受外部持有者保证的 core 生命周期约束，复制或保存门面本身不会延长该期限。

### `JSContext.create` (`src/binding/context.zig:138`)

- **签名**：`pub fn create(rt: *JSRuntime) !*JSContext`。
- **作用**：默认选项造一个 realm 门面。
- **实现**：`createWithOptions(rt, .{})`。
- **所有权 / 错误 / 调用**：调用方拥有宿主引用，必须 `destroy` 恰好一次。

### `JSContext.createWithOptions` (`src/binding/context.zig:142`)

- **签名**：`pub fn createWithOptions(rt: *JSRuntime, options: core.ContextOptions) !*JSContext`。
- **作用**：带 `ContextOptions` 的公共构造。
- **实现**：`createWithOptionsImpl(false, ..., {})`。
- **所有权 / 错误 / 调用**：同 `create`。

### `JSContext.init` (`src/binding/context.zig:146`)

- **签名**：`pub fn init(self: *JSContext, rt: *JSRuntime, options: core.ContextOptions) !void`。
- **作用**：在调用方提供的门面槽上初始化（不分配门面）。
- **实现**：`initWithOptionsImpl(false, ...)`。
- **所有权 / 错误 / 调用**：成功后用 deinit 撤销宿主根，不释放调用方提供的门面存储。不得用 destroy 释放栈上或其他分配来源的门面；init 失败后不能按成功实例执行 deinit。

### `JSContext.deinit` (`src/binding/context.zig:150`)

- **签名**：`pub fn deinit(self: *JSContext) void`。
- **作用**：释放这份宿主 realm 引用，并清该 context 的 Atomics waiter。
- **实现**：`cleanupAtomicsWaitersForContext` 然后 `self.core.destroy()`。不释放门面堆块。
- **所有权 / 错误 / 调用**：不立即拆除 core 的 global/module 等资源；撤销宿主根后，GC 按剩余 heap 边决定 realm 是否可回收。清理 Atomics waiter 不等于排空 job 队列。门面指针字段不清零，不可重复 deinit 或再接 destroy。

### `JSContext.destroy` (`src/binding/context.zig:155`)

- **签名**：`pub fn destroy(self: *JSContext) void`。
- **作用**：`deinit` 再加上释放门面堆块。
- **实现**：先记下 `rt`，cleanup waiters，`core.destroy()`，`rt.memory.destroy(JSContext, self)`。
- **所有权 / 错误 / 调用**：`create` / `createWithOptions` 的配对释放。`createRealm` 的孩子不要走这条（引用在 realm-record JSValue 上）。

---

## 委托：异常、句柄、backtrace、策略

下列方法主要转发 `self.core.*`。pending exception 值及其标志位属于 Runtime，同一 Runtime 的 context 看到同一异常槽；unhandled-rejection 列表则属于各自 context。JS 异常值、exception 哨兵和 Zig error 是不同通道，不能假定所有失败均已转成 JSException 或已有 pending 值。

### `JSContext.runtimePtr` (`src/binding/context.zig:163`)

- **签名**：`pub fn runtimePtr(self: *JSContext) *JSRuntime`。
- **作用**：取出拥有这个 realm 的 runtime。
- **实现**：`self.core.runtime`。
- **所有权 / 错误 / 调用**：不转移所有权。

### `JSContext.createValueHandle` (`src/binding/context.zig:167`)

- **签名**：`pub fn createValueHandle(self: *JSContext, val: JSValue) !core.runtime.JSValueHandle`。
- **作用**：为 val 创建持久根槽，不复制其指向的对象。
- **实现**：转发 `core.createValueHandle`。
- **所有权 / 错误 / 调用**：根槽分配可能失败；成功后句柄须 deinit。当前 initDup 与 init 使用相同实现，不能按旧引用计数模型理解为再增加对象引用计数。

### `JSContext.takeValueHandle` (`src/binding/context.zig:171`)

- **签名**：`pub fn takeValueHandle(self: *JSContext, val: JSValue) !core.runtime.JSValueHandle`。
- **作用**：将值登记到持久根槽；当前与 createValueHandle 的存活效果相同。
- **实现**：转发 `core.takeValueHandle`。
- **所有权 / 错误 / 调用**：不会修改传入 JSValue，也不会自动注销调用方已有的其他根。失败不产生句柄；裸值副本自身不是持久根，成功句柄须由调用方释放。

### `JSContext.hasException` (`src/binding/context.zig:175`)

- **签名**：`pub fn hasException(self: JSContext) bool`。
- **作用**：是否挂着未取走的 JS 异常。
- **实现**：`self.core.hasException()`。
- **所有权 / 错误 / 调用**：不消费；判断 runtime.current_exception 是否不是 uninitialized，不是查询本 context 独立的异常槽。

### `JSContext.takeException` (`src/binding/context.zig:179`)

- **签名**：`pub fn takeException(self: *JSContext) JSValue`。
- **作用**：把 Runtime 上挂着的 pending 异常摘下来交给宿主，同时把异常槽复位——嵌入方在 eval/call 返回失败后靠它拿到异常对象。
- **实现**：`self.core.takeException()`。core 侧先用 `hasException()`（即 `current_exception` 不是 `uninitialized`）判空，空则返回 `undefinedValue()`；否则先存下 `runtime.current_exception`，把它写回 `uninitialized()`，并把 `current_exception_uncatchable`、`current_exception_out_of_memory` 两个标志一起清零，最后返回存下的值。
- **所有权 / 错误 / 调用**：无 pending 异常时返回 undefined；否则取出值、清空共享槽并重置 uncatchable/OOM 标志。返回值不自动取得持久根，undefined 也可能本身就是抛出的值，须用 hasException 区分是否有异常。

### `JSContext.clearException` (`src/binding/context.zig:183`)

- **签名**：`pub fn clearException(self: *JSContext) void`。
- **作用**：无条件丢弃 pending 异常（宿主决定吞掉这次失败时用）。
- **实现**：`self.core.clearException()`，它是 `takeException` 去掉取值与判空的那一半：直接把 `runtime.current_exception` 写成 `uninitialized()`，并清 `current_exception_uncatchable`、`current_exception_out_of_memory`。没有 pending 异常时这三次写入是幂等的。
- **所有权 / 错误 / 调用**：清空 Runtime 共享异常槽并重置 uncatchable/OOM 标志；不清 context 的 unhandled-rejection 列表，不立即销毁此前异常对象。

### `JSContext.throwValue` (`src/binding/context.zig:187`)

- **签名**：`pub fn throwValue(self: *JSContext, val: JSValue) JSValue`。
- **作用**：把任意 JSValue 安装成当前 pending 异常并返回 `exception` 哨兵，是引擎内部「抛出」的统一出口。
- **实现**：`self.core.throwValue(val)`。core 侧先把 `current_exception` 置 `uninitialized()` 并清 `current_exception_uncatchable` / `current_exception_out_of_memory`，再写入新值，最后返回 `JSValue.exception()`。先清后写的次序是刻意的：`setExceptionUncatchable` / `markExceptionOutOfMemory` 必须在 `throwValue` 之后立刻调用，否则标志会被下一次抛出抹掉。
- **所有权 / 错误 / 调用**：替换 Runtime 共享 pending 值，并清除此前 uncatchable/OOM 标志；不会直接展开宿主调用栈。native 调用可用返回的 exception 哨兵传递状态，公共 throwError 另返回 Zig JSException。

### `JSContext.recordUnhandledRejection` (`src/binding/context.zig:191`)

- **签名**：`pub fn recordUnhandledRejection(self: *JSContext, val: JSValue) void`。
- **作用**：登记一条没有 Promise 身份的未处理 rejection（宿主直接报告 reason 的场合）。
- **实现**：`self.core.recordUnhandledRejection(val)` 就是 `recordUnhandledPromiseRejection(null, val)`。promise 为 null 时跳过按身份去重的那一趟扫描，直接 `appendUnhandledRejection` 追加 `(undefined, reason)` 条目；追加失败（分配失败）直接 `return`，随后若 `!hasException()` 再 `throwValue(val)` 把 reason 变成 pending 异常。
- **所有权 / 错误 / 调用**：以 null promise 转发，不按 reason 去重，也不在此检查跟踪开关；成功记录且 Runtime 没有 pending exception 时还会把 reason 放进异常槽。

### `JSContext.recordUnhandledPromiseRejection` (`src/binding/context.zig:195`)

- **签名**：`pub fn recordUnhandledPromiseRejection(self: *JSContext, promise: ?JSValue, val: JSValue) void`。
- **作用**：向该 context 的 rejection 列表追加 Promise/reason，提供非 null promise 时按其身份去重。
- **实现**：转发 core；重复 promise 直接返回，追加分配失败也直接返回，void 接口不报告丢失。
- **所有权 / 错误 / 调用**：不在本方法内检查跟踪开关。成功追加且没有 pending exception 时设置 reason 为共享 pending 值；已有异常保留。不是调用宿主 rejection 回调，也不执行 Promise job。

### `JSContext.hasUnhandledRejection` (`src/binding/context.zig:199`)

- **签名**：`pub fn hasUnhandledRejection(self: JSContext) bool`。
- **作用**：查询该 realm 的未处理 rejection 列表是否非空，事件循环 drain 后用它判断本轮是否要报错退出。
- **实现**：`self.core.hasUnhandledRejection()`，即 `self.unhandled_rejections.len != 0`。只看长度，不看容量（`clearUnhandledRejection` 之外容量一直保留），也不触发 job 队列。
- **所有权 / 错误 / 调用**：`runJobs` 在 drain 失败时用它决定是否吞 error。

### `JSContext.takeUnhandledRejection` (`src/binding/context.zig:203`)

- **签名**：`pub fn takeUnhandledRejection(self: *JSContext) JSValue`。
- **作用**：移除最早的一条 rejection 并返回 reason；空列表返回 undefined。
- **实现**：转发 core，剩余条目向前移动，容量保留。
- **所有权 / 错误 / 调用**：不清 Runtime pending exception，不返回 Promise 身份，也不为 reason 建立持久根。

### `JSContext.clearUnhandledRejection` (`src/binding/context.zig:207`)

- **签名**：`pub fn clearUnhandledRejection(self: *JSContext) void`。
- **作用**：清空该 context 的全部 rejection 记录。
- **实现**：转发 core，重置列表和容量并释放条目数组。
- **所有权 / 错误 / 调用**：不清 Runtime pending exception，不执行回调；移除记录中的 GC 边不等于立即回收 Promise 或 reason 对象。

### `JSContext.classPrototypeSlotCount` (`src/binding/context.zig:211`)

- **签名**：`pub fn classPrototypeSlotCount(self: JSContext) usize`。
- **作用**：报告该 realm 已分配的 class-prototype 槽数，用于诊断与容量核对。
- **实现**：`self.core.classPrototypeSlotCount()`，即 `self.class_prototypes.len`。这个 slice 在小规模时指向 context 内联的 `class_prototypes_inline` 数组，超出后改指堆数组（`usingInlineClassPrototypes` 靠指针相等区分两态），但本函数只读长度，两种形态返回同一个语义。
- **所有权 / 错误 / 调用**：诊断/容量。

### `JSContext.takePendingException` (`src/binding/context.zig:215`)

- **签名**：`pub fn takePendingException(self: *JSContext) JSValue`。
- **作用**：优先取该 context 最早的 unhandled rejection；列表为空时才取 Runtime pending exception。
- **实现**：`self.core.takePendingException()`。
- **所有权 / 错误 / 调用**：取 rejection 的分支还会清空 Runtime 当前异常，即使当前异常不是该 rejection 的 reason。每次只取一条 rejection；不是 takeException 的简单别名。返回值不自动建立持久根。

### `JSContext.pushBacktraceFrame` (`src/binding/context.zig:219`)

- **签名**：`pub fn pushBacktraceFrame( self: *JSContext, function_name: atom.Atom, filename: atom.Atom, line_num: i32, col_num: i32, ) !void`。
- **作用**：向 Runtime 的持久 backtrace 数组压入一帧（函数名、文件名、行列），供 `Error.stack` 与诊断输出回溯。
- **实现**：`self.core.pushBacktraceFrame(...)`，core 侧再以 `location_data`/`location_resolver` 均为 null 转给 `pushBacktraceFrameWithResolver`，最终落到 `pushBacktraceFrameLazyName`：先按需扩容（首次 16，其后翻倍，`alloc`+`memcpy`+释放旧数组），再把两个 atom 经 `runtime.atoms.noteHolderStore` 存入新帧、写入行列，最后把 slice 长度加一。`function_value` 传的是 `undefinedValue()`，所以名字不走惰性解析。
- **所有权 / 错误 / 调用**：写入 Runtime 共享的持久 backtrace 数组，不是各 context 独立的帧栈；扩容可能失败。输入 atom 须在入槽前有效，成功入槽后由 runtime 根遍历覆盖。只在成功 push 后配对 pop。

### `JSContext.pushBacktraceFrameWithResolver` (`src/binding/context.zig:229`)

- **签名**：`pub fn pushBacktraceFrameWithResolver( self: *JSContext, function_name: atom.Atom, filename: atom.Atom, line_num: i32, col_num: i32, location_data: ?*const anyopaque, location_resolver: ?core.BacktraceLocationResolver, ) !void`。
- **作用**：压入一帧并附带惰性位置解析器——调用点只记 PC 与不透明数据，真正的行列在生成 stack 文本时才由 resolver 算出。
- **实现**：`self.core.pushBacktraceFrameWithResolver(...)` 把六个参数原样转给 `pushBacktraceFrameLazyName`，`function_value` 补 `undefinedValue()`。与无 resolver 版本共用同一条扩容与写入路径，差别只在新帧的 `location_data` / `location_resolver` 两个字段被填上；push 阶段不会调用 resolver。
- **所有权 / 错误 / 调用**：只保存 location_data 和 resolver，不在 push 时调用，也不复制或销毁所指数据。其存储及回调代码须在该帧使用期间保持有效；扩容失败不追加新帧。

### `JSContext.popBacktraceFrame` (`src/binding/context.zig:241`)

- **签名**：`pub fn popBacktraceFrame(self: *JSContext) void`。
- **作用**：弹出最近压入的 backtrace 帧，与 push 成对出现在调用/返回路径上。
- **实现**：`self.core.popBacktraceFrame()`：`backtrace_frames.len == 0` 时直接返回（对多余的 pop 宽容），否则把 slice 重新切成 `ptr[0..len-1]`。只改长度，不清帧内容、不释放数组容量，所以下一次 push 会原地覆盖这块槽位。
- **所有权 / 错误 / 调用**：空数组时直接返回，否则只缩短 Runtime 共享数组的长度，保留容量。不调用 resolver 或释放 location_data，也不操作另一条 active-backtrace 链。

### `JSContext.updateBacktracePc` (`src/binding/context.zig:245`)

- **签名**：`pub fn updateBacktracePc(self: *JSContext, pc: usize) void`。
- **作用**：把栈顶帧的指令地址改成一个具体快照值，通常在调用点从「借用 PC」切回定值时使用。
- **实现**：`self.core.updateBacktracePc(pc)`：空数组直接返回；否则取末尾下标，先把 `pc_source` 置 null（解除 `borrowBacktracePc` 建立的借用），再写 `pc`。行列字段不动——那是 `updateBacktraceLocation` 的职责。
- **所有权 / 错误 / 调用**：无帧时无操作；有帧时清除最后一帧的 pc_source，再写入 pc，不修改行列或调用 resolver。这里的“当前帧”指共享持久帧数组末尾。

### `JSContext.borrowBacktracePc` (`src/binding/context.zig:249`)

- **签名**：`pub fn borrowBacktracePc(self: *JSContext, pc_source: *const usize) void`。
- **作用**：让栈顶帧的 PC 指向解释器循环里那个活的 pc 变量，免去每条指令回写一次栈帧。
- **实现**：`self.core.borrowBacktracePc(pc_source)`：空数组直接返回；否则只把末尾帧的 `pc_source` 字段设为传入指针。不解引用、不同步写 `pc` 字段，读取推迟到生成 backtrace 时；`updateBacktracePc` / `updateBacktraceLocation` 会把 `pc_source` 重新置 null 来结束借用。
- **所有权 / 错误 / 调用**：无帧时无操作；有帧时只保存指针，不立即读取，也不修改已存 pc。指针须保持有效，直到帧被移除、指针被替换，或 updateBacktracePc/updateBacktraceLocation 解除借用。

### `JSContext.updateBacktraceLocation` (`src/binding/context.zig:253`)

- **签名**：`pub fn updateBacktraceLocation(self: *JSContext, pc: usize, line_num: i32, col_num: i32) void`。
- **作用**：直接写入最后一帧的 pc、line_num 和 col_num，不按 PC 查找源码位置。
- **实现**：转发 core，同时将 pc_source 置 null。
- **所有权 / 错误 / 调用**：无帧时无操作，不调用 location_resolver，也不移除已保存的 resolver/data。

### `JSContext.defineDataProperty` (`src/binding/context.zig:257`)

- **签名**：`pub fn defineDataProperty( self: *JSContext, target: JSValue, property_name: []const u8, val: JSValue, options: core.DataPropertyOptions, ) !void`。
- **作用**：在对象上 define 数据属性（W/E/C 来自 options）。
- **实现**：`Object.expect(target)`；`internAtom`；TGC S3 §4 class B：define 可能分配 shape 并收集，于是 `rootAtoms(.{&key})` 包住 `defineOwnProperty`。
- **所有权 / 错误 / 调用**：非对象直接返回 Zig TypeError，此包装不另安装 pending JS 异常。intern 和属性定义均可失败；atom 根仅覆盖本次定义，不为返回后宿主保存的裸值提供持久根。描述符标志来自 options，不是调用已有 setter 的赋值操作。

### `JSContext.arrayBuffer` (`src/binding/context.zig:274`)

- **签名**：`pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue`。
- **作用**：从已有 Bytes.Store 的外部存储创建 ArrayBuffer；store.is_shared 为 true 时创建 SharedArrayBuffer。
- **实现**：转发 `core.arrayBuffer`。
- **所有权 / 错误 / 调用**：不复制字节，成功后将 store 清空并把外部存储清理责任交给 buffer；新对象原型为 null，不自动使用 realm 的标准原型。缺少 deinit_fn 返回 InvalidStore。非共享路径失败不会清空输入 store；共享路径若已创建 SharedBufferStore、随后对象分配失败，会通过 release 调用外部 deinit，但输入 store 仍未清空。因此不能承诺所有失败都保留字节所有权，也不能在该失败分支无条件再次 store.release。

### `JSContext.setStackLimit` (`src/binding/context.zig:278`)

- **签名**：`pub fn setStackLimit(self: *JSContext, size: usize) void`。
- **作用**：设置整个 Runtime 的逻辑栈预算，不是设置 OS/native 栈上限。
- **实现**：转发到 runtime.setStackSize，保存 hot.stack_size 并重新计算 vm_stack_arena_policy。
- **所有权 / 错误 / 调用**：同一 Runtime 中的其他 context 也读取这一设置。此调用不分配栈、不改变 native_stack_size，也不刷新 native stack top。

### `JSContext.stackLimit` (`src/binding/context.zig:282`)

- **签名**：`pub fn stackLimit(self: JSContext) usize`。
- **作用**：读取嵌入方配置的逻辑栈预算（递归深度守卫用的字节数），不是当前栈用量。
- **实现**：`self.core.stackLimit()` → `self.runtime.stackSize()` → `runtime.hot.stack_size`。值存在 Runtime 的 hot 区而非 context，所以同 Runtime 下所有 realm 读到同一个数；写入口是 `setStackLimit` → `runtime.setStackSize`。
- **所有权 / 错误 / 调用**：按值收 `JSContext`（薄壳 copy），只读 `runtime.hot.stack_size`，不分配、不建根、无 error set。树内没有生产调用方：`src/exec/eval_entry.zig:254`、`src/exec/module.zig:687`、`src/exec/call.zig:922` 等处的 `ctx.stackLimit()` 走的是 core `JSContext` 的同名方法；这一层是嵌入 API，只有 `src/tests/engine_production.zig:122` 断言它。

### `JSContext.setTrackUnhandledRejections` (`src/binding/context.zig:286`)

- **签名**：`pub fn setTrackUnhandledRejections(self: *JSContext, enabled: bool) void`。
- **作用**：设置该 context 的 unhandled-rejection 跟踪策略标志。
- **实现**：直接写 track_unhandled_rejections。
- **所有权 / 错误 / 调用**：不清除已有列表或 pending exception，也不补录此前遗漏的 rejection。直接调用 recordUnhandledPromiseRejection 不在该方法内部检查此标志。

### `JSContext.tracksUnhandledRejections` (`src/binding/context.zig:290`)

- **签名**：`pub fn tracksUnhandledRejections(self: JSContext) bool`。
- **作用**：读取该 realm 是否开启未处理 rejection 跟踪，Promise 侧据此决定要不要上报。
- **实现**：`self.core.tracksUnhandledRejections()`，即读 `self.track_unhandled_rejections` 这个 bool 字段。注意这是纯查询：`recordUnhandledPromiseRejection` 自身并不检查它，过滤责任在调用方。
- **所有权 / 错误 / 调用**：只读一个 bool 字段，不分配、无 error set。树内生产代码不经这条 getter：`src/exec/promise_ops.zig:741` 直接读 `ctx.track_unhandled_rejections`；本方法与 core 版一样只服务嵌入方，树内唯一调用点是 `src/tests/engine_production.zig:126`。

### `JSContext.setPreserveUncaughtException` (`src/binding/context.zig:294`)

- **签名**：`pub fn setPreserveUncaughtException(self: *JSContext, enabled: bool) void`。
- **作用**：设置该 context 供执行层读取的未捕获异常保留策略。
- **实现**：只写 preserve_uncaught_exception。
- **所有权 / 错误 / 调用**：设置本身不改当前 pending exception，也不阻止显式 takeException/clearException 清空 Runtime 异常槽。

### `JSContext.preservesUncaughtException` (`src/binding/context.zig:298`)

- **签名**：`pub fn preservesUncaughtException(self: JSContext) bool`。
- **作用**：读取「未捕获异常是否保留在异常槽里」的策略位，执行层收尾时据此决定是清空还是留给宿主检视。
- **实现**：`self.core.preservesUncaughtException()`，即读 `self.preserve_uncaught_exception` 字段；与 `setPreserveUncaughtException` 一写一读，无其他副作用。
- **所有权 / 错误 / 调用**：只读一个 bool 字段，不分配、无 error set。生产路径同样绕过它——`src/exec/zjs_vm.zig:84` 与 `:193` 直接读 `preserve_uncaught_exception` 决定要不要 `clearException`；树内唯一调用点是 `src/tests/engine_production.zig:130`。

### `JSContext.setHostEventLoop` (`src/binding/context.zig:302`)

- **签名**：`pub fn setHostEventLoop(self: *JSContext, host_loop: core.context.HostEventLoop) void`。
- **作用**：把宿主事件循环（定时器、fd 读写、信号、exit code）的 ptr+vtable 记录挂到 realm 上，`setTimeout` 等内建靠它落到宿主实现。
- **实现**：`self.core.setHostEventLoop(host_loop)` 就是一次字段赋值 `self.host_event_loop = host_event_loop`。`HostEventLoop` 是 `{ ptr: *anyopaque, vtable: *const VTable }` 的胖指针，VTable 有 traceRoots/setExitCode/enqueueTimer 等 13 个函数指针；赋值按值覆盖，旧记录既不被通知也不被销毁。
- **所有权 / 错误 / 调用**：按值替换钩子记录，不调用新旧回调，不启动循环，也不销毁旧 loop；ptr 所指对象及回调代码由宿主保活。

### `JSContext.clearHostEventLoop` (`src/binding/context.zig:306`)

- **签名**：`pub fn clearHostEventLoop(self: *JSContext, ptr: *anyopaque) void`。
- **作用**：宿主拆除自己的事件循环时撤销挂钩，用 ptr 作凭证避免误删别人后装的循环。
- **实现**：`self.core.clearHostEventLoop(ptr)`：`host_event_loop` 为 null 时什么都不做；非空则比较 `host_event_loop.ptr == ptr`，相等才把字段置 null。只比 ptr，不比 vtable。
- **所有权 / 错误 / 调用**：不执行 loop 的清理或取消任务；比较的是裸指针，不校验其他回调字段。

### `JSContext.hostEventLoop` (`src/binding/context.zig:310`)

- **签名**：`pub fn hostEventLoop(self: *JSContext) ?core.context.HostEventLoop`。
- **作用**：取出当前挂着的宿主事件循环记录，内建与 GC 根遍历通过它拿到 vtable 再分发。
- **实现**：`self.core.hostEventLoop()`，直接返回 `self.host_event_loop` 这个 `?HostEventLoop` 字段的按值拷贝（16 字节的 ptr+vtable 对）。不判断循环是否仍然活着。
- **所有权 / 错误 / 调用**：返回可选钩子记录的副本，内部 ptr/vtable 仍是借用；不调用回调，也不增加 loop 的生命周期。此后替换 context 中的记录不会更新已取出的副本。

---

## 全局、属性、转换、调用

### `JSContext.globalObject` (`src/binding/context.zig:315`)

- **签名**：`pub fn globalObject(self: *JSContext) !*Object`。
- **作用**：物化并返回 realm 全局对象（含标准内建）。
- **实现**：`ensureStandardGlobalsRegistered` 然后 `zjs_vm.contextGlobal`。
- **所有权 / 错误 / 调用**：返回 core `Object`，不转移 realm。几乎所有公共操作的 realm_global 默认走这里。

### `JSContext.createObject` (`src/binding/context.zig:320`)

- **签名**：`pub fn createObject(self: *JSContext) !JSValue`。
- **作用**：创建原型为 null 的普通对象，不自动关联 realm 的 Object.prototype。
- **实现**：`Object.create(rt, class.ids.object, null).value()`。
- **所有权 / 错误 / 调用**：分配失败向上传播；返回 GC 管理的对象值，但不建立宿主持久根，保存到宿主堆后须按根协议保活。

### `JSContext.createString` (`src/binding/context.zig:325`)

- **签名**：`pub fn createString(self: *JSContext, bytes_data: []const u8) !JSValue`。
- **作用**：从 UTF-8/ASCII 字节造 JS 字符串。
- **实现**：空串走 `rt.emptyString()`；ASCII 走 `String.createAscii`，否则 `createUtf8`。
- **所有权 / 错误 / 调用**：输入字节仅借用到调用结束；非空路径创建字符串，不把任意内容统一 intern 到 atom 表。空串缓存首次建立也可能分配失败，返回值不自动建立持久根。

### `JSContext.getPropertyAtom` (`src/binding/context.zig:337`)

- **签名**：`pub fn getPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom) !JSValue`。
- **作用**：已有 atom 的 `[[Get]]`。
- **实现**：`globalObject` + `zjs_vm.getValueProperty`。
- **所有权 / 错误 / 调用**：执行层可运行 accessor / Proxy 代码并失败；与 root.object.getProperty 的核心存储读取不同。调用方保证 atom 属于同一 Runtime 且在调用期间存活，包装不为传入 atom 增加 host pin。output 使用 null。

### `JSContext.getProperty` (`src/binding/context.zig:342`)

- **签名**：`pub fn getProperty(self: *JSContext, val: JSValue, property_name: []const u8) !JSValue`。
- **作用**：按字节名 get；一次性路径（热循环请用 `PropertySite`）。
- **实现**：`internAtom`，`rootAtoms` 包住（getter 可跑 JS），再 `getPropertyAtom`。
- **所有权 / 错误 / 调用**：每次按字节 intern，已有名字可复用 atom，并非每次都新分配。临时 atom 根覆盖全局获取及实际读取；getter/Proxy 的副作用和错误沿调用传播。

### `JSContext.getPropertyKey` (`src/binding/context.zig:351`)

- **签名**：`pub fn getPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !JSValue`。
- **作用**：键已是 JSValue 时的 get（先 ToPropertyKey）。
- **实现**：`PublicValueRootWindow(2)` 根住 obj 与 key；`toPropertyKeyAtom` 然后 `object_ops.getValueProperty`。`realm_global` 默认 `globalObject`。
- **所有权 / 错误 / 调用**：先解析 global，再转换 key，最后读取目标属性；对象键转换可调用 Symbol.toPrimitive 或 toString/valueOf，Symbol 键保留其身份。转换失败时不执行后续读取，已发生的转换副作用不回滚；窗口只在调用期间保活两份输入。

### `JSContext.deleteProperty` (`src/binding/context.zig:360`)

- **签名**：`pub fn deleteProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool`。
- **作用**：按名字 delete。
- **实现**：intern + atom 根（可进 Proxy trap）+ `deletePropertyAtom(..., .{})`。
- **所有权 / 错误 / 调用**：目标必须是对象，不给 primitive 装箱，非对象返回 TypeError。属性不存在也可返回 true，不可配置属性或拒绝删除的 Proxy trap 可返回 false；本入口不将 false 强制转换成异常。Proxy trap 及其不变量检查仍可能抛错。

### `JSContext.deletePropertyKey` (`src/binding/context.zig:369`)

- **签名**：`pub fn deletePropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool`。
- **作用**：键为 JSValue 的 delete。
- **实现**：窗口根住两值，ToPropertyKey，再 `deletePropertyAtom` 带 output/realm_global。
- **所有权 / 错误 / 调用**：与字节名版本采用相同删除结果约定，但先转换 key，之后才由 deletePropertyAtom 检查目标对象；即使目标无效，对象键转换仍可能先产生副作用。

### `JSContext.hasOwnProperty` (`src/binding/context.zig:378`)

- **签名**：`pub fn hasOwnProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool`。
- **作用**：按名字 HasOwnProperty。
- **实现**：intern + 根 + `hasOwnPropertyAtom`。
- **所有权 / 错误 / 调用**：经自有描述符是否存在判断，不沿原型链，也不执行该属性的 getter；可以触发 Proxy 的 getOwnPropertyDescriptor trap。目标必须是对象，不自动装箱；全局 globalThis 的合成描述符也会计为存在。

### `JSContext.hasOwnPropertyKey` (`src/binding/context.zig:387`)

- **签名**：`pub fn hasOwnPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool`。
- **作用**：先转换 JSValue 键，再查询自有描述符是否存在。
- **实现**：窗口 + ToPropertyKey + `hasOwnPropertyAtom`。
- **所有权 / 错误 / 调用**：与字节名版本一样要求目标为对象；键转换先于该检查，转换和 Proxy 描述符查询都可运行用户代码并失败。

### `JSContext.ownPropertyDescriptor` (`src/binding/context.zig:396`)

- **签名**：`pub fn ownPropertyDescriptor(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !?core.PropertyDescriptor`。
- **作用**：`[[GetOwnProperty]]` 的公共入口。
- **实现**：窗口 + ToPropertyKey + `ownPropertyDescriptorAtom`。
- **所有权 / 错误 / 调用**：目标须是对象，返回 null 表示没有描述符；不会因为数据值为 undefined 就返回 null。accessor 返回 getter/setter 值而不执行它们，但键转换、Proxy trap、auto-init 或 mapped-arguments 处理仍可能失败。返回结构里的 JSValue 不自动成为持久根。

### `JSContext.toString` (`src/binding/context.zig:405`)

- **签名**：`pub fn toString(self: *JSContext, val: JSValue) !JSValue`。
- **作用**：ECMAScript ToString（会跑 `toString`/`valueOf`），不是 tag 检查。
- **实现**：`string_ops.toStringForAnnexB`。
- **所有权 / 错误 / 调用**：已是字符串时返回同一值；Symbol 及对象转换得到的 Symbol 都抛 TypeError，不采用 String(symbol) 的描述性字符串特例。对象转换可运行 Symbol.toPrimitive、toString/valueOf；global 获取和转换均可能失败。

### `JSContext.toOwnedUtf8` (`src/binding/context.zig:410`)

- **签名**：`pub fn toOwnedUtf8(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8`。
- **作用**：先执行 ToString，再分配独立的 UTF-8/WTF-8 字节副本；未配对代理项按字符串视图的编码规则保留。
- **实现**：`toString` → `asString()` 失败则 TypeError → `toOwnedUtf8(allocator)`。
- **所有权 / 错误 / 调用**：调用方使用传入 allocator 释放返回切片；不追加 NUL 终止符，内容可含零字节。ToString 的用户代码副作用与异常先发生，之后的副本分配也可能失败。

### `JSContext.toNumber` (`src/binding/context.zig:416`)

- **签名**：`pub fn toNumber(self: *JSContext, val: JSValue) !f64`。
- **作用**：ToNumber。BigInt 在 ToPrimitive 之后拒绝。
- **实现**：`toPrimitiveForNumber`；是 BigInt → TypeError；`toNumberValue`；`asNumber()` 失败则 NaN。
- **所有权 / 错误 / 调用**：对象转换可运行 Symbol.toPrimitive/valueOf/toString，错误向上传播。BigInt 检查直接返回 Zig TypeError，本包装不在该分支另安装 pending 异常；不能假设每个失败都可用 takeException 取得 JS 错误对象。

### `JSContext.toIntegerOrInfinity` (`src/binding/context.zig:424`)

- **签名**：`pub fn toIntegerOrInfinity(self: *JSContext, val: JSValue) !f64`。
- **作用**：ToIntegerOrInfinity。
- **实现**：先 `toNumber`；NaN 或 0 → 0；非有限原样返回；否则按符号 `floor(abs)`。
- **所有权 / 错误 / 调用**：数值截断本身不分配，但前置 toNumber 可运行用户代码并分配；NaN、+0、-0 均返回 +0。这里确实截断小数，不同于 root.value 同名助手的实现。

### `JSContext.isCallable` (`src/binding/context.zig:431`)

- **签名**：`pub fn isCallable(self: *JSContext, val: JSValue) bool`。
- **作用**：值是否可调用。
- **实现**：忽略 self，`call_runtime.isCallableValue(val)`。
- **所有权 / 错误 / 调用**：无分配，包含内部 FunctionBytecode 值以及 Proxy target 的可调用性路径；不实际调用该值，因此 true 不保证一次调用不会抛错。

### `JSContext.isConstructor` (`src/binding/context.zig:436`)

- **签名**：`pub fn isConstructor(self: *JSContext, val: JSValue) bool`。
- **作用**：公共「像构造器吗」谓词，**不可失败**；OOM 时保守 `false`。
- **实现**：`isConstructorLike catch false`。引擎内部用可失败版本传 OOM。
- **所有权 / 错误 / 调用**：不分配、不建根。`isConstructorLike` 的 error set 在这里被整体吞掉（`catch false`），所以 OOM 既不返回错误也不留 pending exception，读数与「真的不是构造器」不可区分；需要区分的引擎内部路径用可失败版本（`src/exec/object_ops.zig:4195` 的 class extends 校验一线）。树内调用方是 CLI 的 test262 宿主 `src/cli/run_test262_host.zig:724`。

### `JSContext.functionName` (`src/binding/context.zig:443`)

- **签名**：`pub fn functionName(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8`。
- **作用**：取得对象的内部函数派发名称，并复制到调用方 allocator；不等同于读取 JavaScript 的可观察 name 属性。
- **实现**：`Object.expect`；`nativeFunctionNameForVm`（runtime allocator）再 `dupe`。
- **所有权 / 错误 / 调用**：优先使用 nativeDispatchName atom，缺失时走内部名称回退路径；包装只检查对象，并未先验证 callable。临时字节始终释放，返回切片由调用方 allocator 释放；名称解析、临时分配和最终复制都可能失败。

### `JSContext.callFunction` (`src/binding/context.zig:450`)

- **签名**：`pub fn callFunction(self: *JSContext, callee: JSValue, args: []const JSValue, options: core.FunctionCallOptions) !JSValue`。
- **作用**：一次性 native→JS 调用。热循环请用 `CallSite`。
- **实现**：realm_global 缺省时 `contextGlobalFast`。NB2 C2：callee/receiver/`args` 是嵌入方的；native 栈被 conservative 扫，堆数组必须自己 pin。不链 per-call root frame（qjs `JS_Call` 也不链）。`call_site.callOnceInto`：合格 bytecode 走驻留 host Machine，其余走权威根路径。OOM 经 `restoreUncaughtOutOfMemory`。成功 `pinnedLoad` 出参。
- **所有权 / 错误 / 调用**：this_value 缺省为 undefined，args 只在调用期间借用。包装不保存可复用站点或建立持久结果根。调用返回 JSException 且 pending 异常带引擎 OOM 标记时改为 OutOfMemory，但不清除该异常槽；其他错误保持原样。默认 global 获取发生在此错误转换之前。

### `JSContext.createError` (`src/binding/context.zig:472`)

- **签名**：`pub fn createError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue`。
- **作用**：创建 Error-class 对象并写入 message，按指定名称查找全局构造器的 prototype，但不调用构造器。
- **实现**：`capture_stack` 则 `createNamedError`，否则 `createNamedErrorWithoutStack`。
- **所有权 / 错误 / 调用**：用 core 属性读取查找构造器及 prototype，不执行其 accessor getter；找不到合适原型时底层使用自己的回退属性。capture_stack 控制是否附加当前 backtrace；分配、属性读取或 stack 附加可失败。成功只是返回错误对象，不设置 pending exception。

### `JSContext.throwError` (`src/binding/context.zig:478`)

- **签名**：`pub fn throwError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue`。
- **作用**：造错 + `throwValue`，返回 `error.JSException`。
- **实现**：`createError` 然后 `throwValue`，`return error.JSException`。
- **所有权 / 错误 / 调用**：错误对象构造成功后才覆盖 pending 异常并返回 JSException；若创建失败，直接传播创建错误，不能假定已经安装了请求的错误对象。没有正常返回 JSValue 的路径。

### `JSContext.pendingExceptionMatchesErrorName` (`src/binding/context.zig:484`)

- **签名**：`pub fn pendingExceptionMatchesErrorName(self: *JSContext, expected_name: []const u8) !bool`。
- **作用**：按名称匹配当前 pending 对象，先比较其 constructor 的内部派发名，再回退比较其字符串 name 属性。
- **实现**：没有异常 → false；否则 `thrownValueMatchesConstructor(runtime.current_exception, ...)`。
- **所有权 / 错误 / 调用**：不消费异常；非对象返回 false。这不是 instanceof 或 Error 品牌验证，普通对象也可能匹配。名称解析和分配可失败，读取采用 core 属性接口。

### `JSContext.consumePendingExceptionIfErrorName` (`src/binding/context.zig:489`)

- **签名**：`pub fn consumePendingExceptionIfErrorName(self: *JSContext, expected_name: []const u8) !bool`。
- **作用**：检查名称后清除 pending 异常，并返回是否匹配。
- **实现**：无异常 false；`pendingExceptionMatchesErrorName` 后 **无条件** `clearException`，再返回 matches。
- **所有权 / 错误 / 调用**：检查正常返回时，无论匹配与否都清空 Runtime 异常槽及相关标志；检查本身失败则提前返回，不执行 clearException。此方法不消费 context 的 rejection 列表。

### `JSContext.runtimeErrorMatchesErrorName` (`src/binding/context.zig:496`)

- **签名**：`pub fn runtimeErrorMatchesErrorName(self: *JSContext, err: anyerror, expected_name: []const u8) bool`。
- **作用**：Zig error 是否对应那个 JS 错误名。
- **实现**：忽略 self。`runtimeErrorInfo(err)` 有则比 `info.name`；否则 `@errorName(err)==expected_name` 且 `isErrorConstructorName`。
- **所有权 / 错误 / 调用**：不碰 pending。

### `JSContext.createRealm` (`src/binding/context.zig:505`)

- **签名**：`pub fn createRealm(self: *JSContext) !JSValue`。
- **作用**：在同一 Runtime 内创建子 realm，返回持有 realm 边和 global 属性的普通记录对象。
- **实现**：`exec.call.createRealmObject(self.core)`。
- **所有权 / 错误 / 调用**：子 context 继承父 context 的逻辑栈设置和 rejection 跟踪标志，并在返回前物化自己的 global。记录对象接管初始 realm 所有权；宿主保存记录时应按 GC 根规则保活，不要再次调用孩子的 context.destroy 撤销同一创建根。构造与属性安装均可能失败。

### `JSContext.realmGlobal` (`src/binding/context.zig:509`)

- **签名**：`pub fn realmGlobal(self: *JSContext, realm: JSValue) !JSValue`。
- **作用**：读 realm 对象的 `global` 属性。
- **实现**：`getPropertyAtom(realm, atom.ids.global)`。
- **所有权 / 错误 / 调用**：是普通执行层属性读取，不验证参数由 createRealm 产生，也不验证返回 global 的 realm 身份；可运行 getter/Proxy 代码，缺失属性返回 undefined。

### `JSContext.realmGlobalObject` (`src/binding/context.zig:513`)

- **签名**：`pub fn realmGlobalObject(self: *JSContext, realm: JSValue) !*Object`。
- **作用**：`realmGlobal` 再 `Object.expect`。
- **实现**：如上。
- **所有权 / 错误 / 调用**：只要求读出的 global 是对象；非对象返回 TypeError，不验证它是否已注册为某个 context 的 global，也不建立持久根。

### `JSContext.isArray` (`src/binding/context.zig:518`)

- **签名**：`pub fn isArray(self: *JSContext, val: JSValue) !bool`。
- **作用**：是否真 Array（跟代理链）。revoked proxy 在这里是 TypeError（`arrayObjectFromValue`）。
- **实现**：`arrayObjectFromValue(val) != null`。
- **所有权 / 错误 / 调用**：非对象返回 false；递归读取 Proxy 内部 target/handler，不调用 Proxy trap。与 root.object.isArray 使用的带深度计数的迭代实现不同，本助手没有显式链深度上限，且 revoked/missing target 的错误向上传播。

### `JSContext.arrayLength` (`src/binding/context.zig:524`)

- **签名**：`pub fn arrayLength(self: *JSContext, val: JSValue) !u32`。
- **作用**：数组 `length`。
- **实现**：`arrayObjectFromValue` 失败/非数组 → TypeError，否则 `object.arrayLength()`。
- **所有权 / 错误 / 调用**：跟随 Proxy target 后直接读最终 Array 的内部 length，不走 length 的 [[Get]] 或 Proxy get trap。普通 array-like 对象不被接受；Proxy 链的错误也会传播。

### `JSContext.getIndex` (`src/binding/context.zig:530`)

- **签名**：`pub fn getIndex(self: *JSContext, val: JSValue, index: u32) !JSValue`。
- **作用**：`val[index]`。
- **实现**：`getPropertyAtom(val, atomFromUInt32(index))`。
- **所有权 / 错误 / 调用**：不要求 val 为 Array，实际按属性读取规则处理；索引通过 tagged-int atom 编码，仅支持 index ≤ 2³¹−1。超出上限触及底层断言，不是可捕获的 RangeError；参数为 u32 不表示覆盖完整 u32 索引范围。

### `JSContext.hasOwnPropertyAtom` (`src/binding/context.zig:534`)

- **签名**：`fn hasOwnPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool`。
- **作用**：HasOwn 的 atom 核心。
- **实现**：`ownPropertyDescriptorAtom != null`。
- **所有权 / 错误 / 调用**：这里按描述符存在性判断，继承 ownPropertyDescriptorAtom 的对象要求、Proxy 查询和 globalThis 合成行为，不是对 shape 做简单查找。

### `JSContext.deletePropertyAtom` (`src/binding/context.zig:538`)

- **签名**：`fn deletePropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool`。
- **作用**：atom 版 delete。
- **实现**：`Object.expect` + `object_ops.deleteValueProperty`。
- **所有权 / 错误 / 调用**：先检查 target 为对象，再按 options 获取 global；不是严格 DeletePropertyOrThrow。普通删除失败或 Proxy trap 返回假时可返回 false，查询/trap/不变量错误仍传播。

### `JSContext.ownPropertyDescriptorAtom` (`src/binding/context.zig:544`)

- **签名**：`fn ownPropertyDescriptorAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !?core.PropertyDescriptor`。
- **作用**：proxy-aware own descriptor；补 mapped arguments；全局缺 `globalThis` 时合成一份。
- **实现**：`proxyAwareOwnPropertyDescriptor`；miss 且对象是 global 且名是 `"globalThis"` → `Descriptor.data(object.value(), true, false, true)`；否则 null。命中后 `materializeMappedArgumentsDescriptorValueForVm`。
- **所有权 / 错误 / 调用**：先要求 val 是对象，再获取 global 和查询描述符；globalThis 的合成结果为 writable=true、enumerable=false、configurable=true，并不把真实属性写回对象。mapped-arguments 描述符还会补入当前绑定值。

### `JSContext.retainSharedArrayBuffer` (`src/binding/context.zig:557`)

- **签名**：`pub fn retainSharedArrayBuffer(self: *JSContext, val: JSValue) !core.SharedArrayBufferRef`。
- **作用**：从 SAB 对象拿出可跨 realm 的 store 引用。
- **实现**：必须是 `shared_array_buffer` class；`sharedByteStorageStore`；`store.retain()`；记下 `max_byte_length`。
- **所有权 / 错误 / 调用**：忽略 self，不验证对象与该 context 的 Runtime 归属；只接受直接 SAB 对象，不解开 Proxy。返回 ref 拥有一次共享存储引用，调用方须用 ref.release 配对释放。sharedArrayBufferFromRef 不消费这份引用，不能替代 release。

### `JSContext.sharedArrayBufferFromRef` (`src/binding/context.zig:569`)

- **签名**：`pub fn sharedArrayBufferFromRef(self: *JSContext, ref: core.SharedArrayBufferRef) !JSValue`。
- **作用**：从 ref 再包一个 SAB 对象。
- **实现**：`sharedStore()` 空 → TypeError；max < 当前 len → RangeError；`store.retain` + errdefer release；`Object.create(shared_array_buffer)`；`installSharedByteStorage`；写回 max slot。
- **所有权 / 错误 / 调用**：在当前 Runtime 创建原型为 null 的新 SAB 包装，不复制字节，不消费输入 ref；成功时新对象拥有额外 retain，失败时撤销该次 retain。安装使用 store.bytes 的整个切片，ref 不记录原包装的可见前缀长度，不能假定重建后保留原包装当前 byteLength。

### `JSContext.functionRealmGlobal` (`src/binding/context.zig:583`)

- **签名**：`pub fn functionRealmGlobal(self: *JSContext, function_value: JSValue) !?*Object`。
- **作用**：函数对象所属 realm 的 global。
- **实现**：`call_runtime.functionRealmGlobal`。

- **所有权 / 错误 / 调用**：当前底层返回的是非可选 global 指针或错误：realm 没有 global 时返回 InvalidBuiltinRegistry，不会成功返回 null；门面的可选返回类型不表示存在额外的 null 分支。返回指针借用 realm 对象，不建立持久根。

### `JSContext.restoreUncaughtOutOfMemory` (`src/binding/context.zig:601`)

- **签名**：`fn restoreUncaughtOutOfMemory(self: *JSContext, err: anytype) @TypeOf(err)`。
- **作用**：分配失败在引擎内是可 catch 的 `InternalError: out of memory`，缝上变成 `JSException`；对**没有** JS 处理器吃掉它的路径，契约仍要求宿主看到 `error.OutOfMemory`。
- **实现**：`err==JSException` 且 `exceptionIsOutOfMemory()` → `error.OutOfMemory`，否则原样。JS 若 catch 过，flag 已清，err 穿过。
- **所有权 / 错误 / 调用**：供调用和求值边界使用，仅转换错误类别，不清除 pending 值或 OOM 标志，不重试分配。只凭 InternalError 的名称或 message 不触发转换，必须具有引擎设置的 OOM 标志。

---

## eval、native 注册、异常格式化

### `JSContext.evalScriptSource` (`src/binding/context.zig:608`)

- **签名**：`pub fn evalScriptSource(self: *JSContext, source_text: []const u8, options: core.ScriptEvalOptions) !JSValue`。
- **作用**：按 script 选项求值一段源文（可指定 realm_global）。
- **实现**：确保 globals；`realm_global` 经 `contextForGlobal` 找不到 → TypeError；`eval_entry.evalScriptSource` + OOM 恢复。
- **所有权 / 错误 / 调用**：固定按 script 编译并求 completion；ScriptEvalOptions 只有 output、realm_global、filename，没有 module 模式。显式 global 必须能在当前 Runtime 的已发布 context 中找到，不使用 including-constructing 查找；失败直接返回 TypeError。输入字节借用到调用结束，此入口本身不排空 jobs。

### `JSContext.evalScriptValue` (`src/binding/context.zig:618`)

- **签名**：`pub fn evalScriptValue(self: *JSContext, source_value: JSValue, options: core.ScriptEvalOptions) !JSValue`。
- **作用**：源文已是 JS 字符串值时的 script eval。
- **实现**：同 `evalScriptSource`，走 `eval_entry.evalScriptValue`。
- **所有权 / 错误 / 调用**：先验证显式 realm_global，再由执行层检查 source_value 是字符串；不对非字符串做 ToString。源码转换到临时字节数组，成功或失败均释放；输入值须在调用期间可达。转换和求值错误向上传播。

### `JSContext.eval` (`src/binding/context.zig:628`)

- **签名**：`pub fn eval(self: *JSContext, source_text: []const u8, options: core.EvalOptions) !JSValue`。
- **作用**：最常用的嵌入 eval（script/module 等由 `EvalOptions` 决定）。
- **实现**：确保 globals；`eval_entry.eval(self.core, ...)` + OOM 恢复。
- **所有权 / 错误 / 调用**：默认 mode=script，也接受 module/eval_direct/eval_indirect；此选项类型没有 realm_global。执行层编译并运行后还排空 pending jobs，因此根代码已成功也可能随后因 job 失败而返回错误。return_completion/discard_script_result 控制 script 结果是否返回，不跳过脚本执行或其副作用。输出值不自动取得持久根。

### `JSContext.runJobs` (`src/binding/context.zig:634`)

- **签名**：`pub fn runJobs(self: *JSContext, output: ?*std.Io.Writer) !void`。
- **作用**：驱动当前 Runtime 的 jobs，并在队列空时依次尝试宿主信号、I/O、定时器和 Atomics 完成事件，直到没有可处理工作。
- **实现**：`drainPendingPromiseJobs`；若失败但已有 exception 或 unhandled rejection 则 `return`（不把 drain 的 error 再抛一层）；否则返回 err。
- **所有权 / 错误 / 调用**：没有条数预算；回调持续产生工作时可能持续运行。globalObject 失败直接传播；drain 失败时若已有 pending exception 或本 context 的 rejection 列表非空，包装反而正常返回 void，故成功返回不证明没有异常或已处理完全部工作。只按条数处理 FIFO 的接口是 zjs.job.drain。

### `JSContext.defineFunction` (`src/binding/context.zig:644`)

- **签名**：`pub fn defineFunction(self: *JSContext, name: []const u8, spec: native.Spec, options: native.Options) !JSValue`。
- **作用**：`createFunction` 并装到该 realm 全局：writable、非 enumerable、configurable 数据属性。
- **实现**：缺省 `realm_global = globalObject`；create 后 intern 名、`rootAtoms`、`defineOwnProperty`。
- **所有权 / 错误 / 调用**：始终安装到 self 的 global；options.realm_global 若显式指定其他 realm，只改变新函数的创建 realm，不改变安装目标。返回函数对象，底层 NativeEntry 由 Runtime 持有；后续 intern 或属性定义失败不撤销已创建 entry/finalizer 注册。

### `JSContext.createFunction` (`src/binding/context.zig:660`)

- **签名**：`pub fn createFunction(self: *JSContext, name: []const u8, spec: native.Spec, options: native.Options) !JSValue`。
- **作用**：造 native 函数对象，不安到 global。
- **实现**：解析 realm（`contextForGlobalIncludingConstructing`）；拷 template，填 `state`/`length`。`finalize` 必须伴随 `state`，先 `registerNativeEntryFinalizer` 再 `allocNativeEntry`（失败也要能 teardown 清掉）。`nativeFunctionWithPrototypeAndCapacity`；`with_prototype` 则造 prototype 对象并互指 constructor。`installNativeEntry`。
- **所有权 / 错误 / 调用**：finalizer 是 Runtime 级注册，不随函数对象或 context 被回收而立即执行；由 Runtime 清理外部宿主函数的路径处理。finalizer 注册成功后，后续 entry、函数或 prototype 分配失败不会撤销它，调用方不能因 createFunction 失败就无条件自行释放相同 state。未提供 finalize 时仅保存借用的 state；with_prototype 创建普通原型对象，但不验证 spec 是否具有构造调用能力。

### `JSContext.defineClass` (`src/binding/context.zig:694`)

- **签名**：`pub fn defineClass(self: *JSContext, comptime C: type, options: native.ClassOptions) !C.Handle`。
- **作用**：在 runtime 注册 `zjs.native.Class`（每 runtime 一次；class id 进程全局），并在本 realm 装原型+构造器（每 realm 一次）。
- **实现**：`C.classId` + `native_object.registerType`；已有 class prototype 则跳过 install；否则 `installClassInRealm`。返回 `{ .native_type }`。
- **所有权 / 错误 / 调用**：Handle 借用 Runtime 的 NativeType。类型注册先于 realm 查找与安装，后续失败不会注销类型。已有 class prototype 时跳过整个安装，新的 global_name 不会补装或更新；不能把重复调用理解成重新配置 class。

### `JSContext.installClassInRealm` (`src/binding/context.zig:706`)

- **签名**：`fn installClassInRealm(self: *JSContext, comptime C: type, native_type: *const core.NativeType, realm: *core.JSContext, realm_global: *Object, options: native.ClassOptions) !void`。
- **作用**：造原型、装 methods/getters/setters、造 constructor、可选挂到 global。
- **实现**：先 `setClassPrototype`（traced root，后续分配时原型可达），`errdefer clear`。inline 扫 `C.methods`：盖 `class_id`，`createFunction`，`rootValues` 后 `defineMemberProperty` 数据属性。getters 配同名 setter 成 accessor；未配对的 setter 单独装。constructor 用 `C.constructor_spec`，`state` 指向 `native_type`；ctor.own `prototype` + prototype.constructor。`global_name` 则 define 到 realm_global。
- **所有权 / 错误 / 调用**：方法是 W=true/E=false/C=true 数据属性；accessor 是 E=false/C=true；constructor.prototype 的 W/E/C 全 false，prototype.constructor 和可选 global_name 为 W=true/E=false/C=true。失败清除 realm 的 class-prototype 槽，但不注销 Runtime 类型或撤销此前 NativeEntry 分配，不提供整个安装过程的原子回滚。

### `JSContext.defineMemberProperty` (`src/binding/context.zig:778`)

- **签名**：`fn defineMemberProperty(rt: *JSRuntime, target: *Object, name: []const u8, desc: Descriptor) !void`。
- **作用**：intern 名并 define，带 atom 根。
- **实现**：同其它 class B intern。
- **所有权 / 错误 / 调用**：installClassInRealm。

### `JSContext.formatException` (`src/binding/context.zig:787`)

- **签名**：`pub fn formatException(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) ![]const u8`。
- **作用**：把异常格式化成 `"Name: message"` 或退化字符串。
- **实现**：对象则读 `name`/`message`（`getPropertyString`）；两者都有则 `allocPrint("{s}: {s}")` 成功之后再显式 free 两块临时字节；只有一个则直接返回那份；否则 `appendValueString` 再 dupe。
- **所有权 / 错误 / 调用**：返回切片由调用方 allocator 释放；对象的 name/message 通过 core getProperty 读取，不执行 accessor getter，非字符串不做 ToString。两者都是字符串时即使为空也拼接冒号与空格；无可用字符串时走内部 appendValueString，不是完整 JS ToString。双字符串分支只有一条释放路径：两块临时字节在 `allocPrint` 之前归 `errdefer` 所有（失败时各释放一次），成功后才由显式 `free` 释放，OOM 路径不再重复释放。

### `JSContext.formatExceptionStack` (`src/binding/context.zig:820`)

- **签名**：`pub fn formatExceptionStack(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) !?[]const u8`。
- **作用**：读 `stack` 字符串；非对象或非字符串则 null。
- **实现**：`getPropertyAtom(..., atom.ids.stack)` + `appendRawString` + dupe。
- **所有权 / 错误 / 调用**：与 formatException 的核心读取不同，此处执行层 getPropertyAtom 可运行 stack getter / Proxy 代码并抛错。成功切片由 allocator 释放；非字符串 stack 返回 null，不做 ToString。函数不消费 pending exception，内容使用 UTF-8/WTF-8 且无 NUL 终止符。

### `getPropertyString` (`src/binding/context.zig:833`)

- **签名**：`fn getPropertyString(rt: *JSRuntime, obj: *Object, key: atom.Atom, allocator: std.mem.Allocator) !?[]const u8`。
- **作用**：own/inherited get 后若是字符串则拷 UTF-8。
- **实现**：`obj.getProperty`；非字符串 null；`appendRawString` + dupe。
- **所有权 / 错误 / 调用**：用于 formatException 的 name/message；core 读取可沿原型链或物化 auto-init，但不执行 getter。返回字节由调用方 allocator 释放，内部 runtime 临时数组始终释放；非字符串返回 null，读取和分配错误传播。

### `arrayObjectFromValue` (`src/binding/context.zig:843`)

- **签名**：`fn arrayObjectFromValue(value: JSValue) !?*Object`。
- **作用**：解开（含 Proxy 链）得到 Array 对象；revoked/缺 target → TypeError；非对象/非数组 → null。
- **实现**：非对象 null；`Object.expect` 失败 null；proxy 则递归 `proxyTarget`；`isArray()` 才返回。
- **所有权 / 错误 / 调用**：`isArray` / `arrayLength`。

---

## `CallSite`

可复用的 native→JS 调用站点：初始化时选择执行路径，并为 callee 和默认 receiver 建立持久根槽。选择通用路径不表示 callee 已通过可调用性检查；实际调用仍可能失败。调用先检查 interrupt，再进入适用的 bytecode 路径或通用调用；不能据“解析一次”断言后续调用不分配、没有进一步校验或只有固定成本。站点借用创建它的 context 和 output writer，须保证它们的生命周期。

### `CallSite.init` (`src/binding/context.zig:891`)

- **签名**：`pub fn init(ctx: *JSContext, callee: JSValue, options: Options) !CallSite`。
- **作用**：解析并 pin 目标。
- **实现**：`globalObject`；`this_value` 默认 undefined；`exec.call_site.CallSite.init`。
- **所有权 / 错误 / 调用**：global 获取及两个持久槽分配均可失败，第二个槽失败时释放第一个。成功站点持有 callee/默认 this 的根，但不拥有 context 门面或 output writer；init 成功不保证 callee 可调用。

### `CallSite.deinit` (`src/binding/context.zig:900`)

- **签名**：`pub fn deinit(self: *CallSite) void`。
- **作用**：放掉 pin。
- **实现**：`self.site.deinit()`。
- **所有权 / 错误 / 调用**：须在 context/runtime 销毁前执行；同一实例的已清空根槽允许重复 deinit，但不要复制活跃站点后分别释放。底层只释放根并把 route 置为 generic，保留其他裸值和指针；deinit 后不得继续调用站点。

### `CallSite.call` (`src/binding/context.zig:904`)

- **签名**：`pub fn call(self: *CallSite, args: []const JSValue) !JSValue`。
- **作用**：用 init 时的 receiver 调一次。
- **实现**：`callInto` + OOM 恢复 + `pinnedLoad`。
- **所有权 / 错误 / 调用**：args 仅借用本次，宿主堆中参数值须另有根覆盖。返回值不成为站点持久根；pinnedLoad 是值的整数位加载方式，不是 GC pin 注册。执行错误传播，未捕获且带 OOM 标志的 JSException 转回 OutOfMemory。

### `CallSite.call0` (`src/binding/context.zig:910`)

- **签名**：`pub inline fn call0(self: *CallSite) !JSValue`。
- **作用**：零参快路径。
- **实现**：`callFixed(0, &.{})`。
- **所有权 / 错误 / 调用**：`inline` 转发到 `callFixed(0, &.{})`（`src/binding/context.zig:923`），后者调 `exec.call_site.callFixedInto` 并用 `pinnedLoad` 取回结果。错误是 `HostError`：JS 抛出时返回 `error.JSException` 并把异常留在 realm 的异常槽里；若该异常是 OOM 异常，`restoreUncaughtOutOfMemory`（`src/binding/context.zig:601`）把它换回 `error.OutOfMemory`。返回的 `JSValue` 是借用值，不 retain、不入句柄；宿主栈上的副本靠保守栈扫描保活。调用方：`src/tests/embedding_examples.zig:239`、`:259`。

### `CallSite.call1` (`src/binding/context.zig:914`)

- **签名**：`pub inline fn call1(self: *CallSite, a0: JSValue) !JSValue`。
- **作用**：单参；参数经 `pinnedStore` 放进栈数组。
- **实现**：`callFixed(1, &args)`。
- **所有权 / 错误 / 调用**：a0 需在调用期间可达；pinnedStore 只控制位存储方式，不为它新增持久根，也不复制参数所指的对象。

### `CallSite.call2` (`src/binding/context.zig:920`)

- **签名**：`pub inline fn call2(self: *CallSite, a0: JSValue, a1: JSValue) !JSValue`。
- **作用**：两参快路径。
- **实现**：两次 `pinnedStore` + `callFixed(2, ...)`。
- **所有权 / 错误 / 调用**：同 call1。

### `CallSite.callFixed` (`src/binding/context.zig:927`)

- **签名**：`inline fn callFixed(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue) !JSValue`。
- **作用**：固定 argc 的底层调用。
- **实现**：`callFixedInto` + OOM 恢复 + `pinnedLoad`。
- **所有权 / 错误 / 调用**：`call0/1/2`。

### `CallSite.callWithThis` (`src/binding/context.zig:935`)

- **签名**：`pub fn callWithThis(self: *CallSite, this_value: JSValue, args: []const JSValue) !JSValue`。
- **作用**：同一 callee，这次换 receiver。`this_value` 必须在调用期间从宿主可达。
- **实现**：`callWithThisInto` + OOM 恢复。
- **所有权 / 错误 / 调用**：不修改或替换站点持久根中的默认 this；临时 this 与 args 的存活由调用方保证。返回值不自动保存在站点中，错误采用与 call 相同的 OOM 转换。
