# 18 — 事件循环（`src/event_loop.zig`）

宿主事件循环：定时器、fd 就绪、信号、以及把这些臂接到 exec 的 job 排水。JS 调用 / Promise 语义在 exec；公共适配在 binding；本目录只提供调度缝。拓扑对齐 `quickjs-libc.c:2014-2175` 与 `:2422-2627`。

## 文件级类型

### `Options`（`src/event_loop.zig:42`）

`output: ?*std.Io.Writer = null`。循环不拥有 writer，只在回调 / job 排水时借给 exec。

### `RunResult`（`src/event_loop.zig:46`）

`has_pending_exception` / `has_unhandled_rejection`。`hasPendingError` 是二者的或。

### `EventLoop`（`src/event_loop.zig:55`）

| 字段 | 含义 |
| --- | --- |
| `context` | 绑定的 `*core.JSContext` |
| `realm` | `RealmRef.retain`，让 realm 活过循环寿命 |
| `output` | 借用的 stdout/捕获 writer |
| `timers` / `timers_capacity` | 定时器表；`len` 是活条目，释放必须按 capacity |
| `rw_handlers` / `rw_handlers_capacity` | fd 读/写回调 |
| `signal_handlers` / `signal_handlers_capacity` | 信号回调 |
| `next_timer_id` | 从 1 起的 i64；超过 `2^53-1` 回绕到 1（可当 JS Number） |
| `exit_code` | `std.process.exit` 请求（`error.ProcessExit`） |
| `installed` | 是否已挂到 `JSContext.host_event_loop` |

内部类型：`Timer{id, callback, timeout_ms, delay_ms, repeats}`、`RwHandler{fd, read_callback, write_callback}`（空槽为 `null`）、`SignalHandler{sig, callback}`。

`vtable`（582）是 `core.context.HostEventLoop.VTable`：exec 经不透明指针回调本模块，core 不 import runtime。

`os_pending_signals: u64` 进程级位图，信号处理器只置位。

Windows 路径用 `GetStdHandle` / `WaitForSingleObject`；POSIX `@cImport` `poll.h`/`signal.h`，并关掉 `_FORTIFY_SOURCE` 以免 translate-c 撞 glibc 包装。

本文件就是 `zjs.runtime` 门面：`EventLoop`、`EventLoopOptions`、`EventLoopRunResult`、`runUntilIdle`。测试钉死不暴露 `plugin`、`ffi`、`JSRuntime` 等内部名。模块图、Atomics wake/cleanup、ArrayBuffer detach 在 `src/exec/`。

---

## `RunResult`

### `RunResult.hasPendingError` (`src/event_loop.zig:50`)

- **签名**：`pub fn hasPendingError(self: RunResult) bool`。
- **作用**：一次排水结束后，宿主要不要按失败退出。
- **实现**：`has_pending_exception or has_unhandled_rejection`。
- **所有权 / 错误 / 调用**：无分配。CLI 在 `runUntilIdle` 之后看 context 上的 rejection；本方法给单测与嵌入方。

## `EventLoop` 构造 / 安装 / 拆掉

### `EventLoop.init` (`src/event_loop.zig:69`)

- **签名**：`pub inline fn init(context: *zjs.JSContext, options: Options) EventLoop`。
- **作用**：从公共 context 造未安装循环。
- **实现**：`return initCore(context.core, options)`。
- **所有权 / 错误 / 调用**：栈上值；调用方 `install` + `deinit`。CLI `main`、test262 嵌入引擎、本文件测试。

### `EventLoop.initCore` (`src/event_loop.zig:73`)

- **签名**：`pub inline fn initCore(context: *core.JSContext, options: Options) EventLoop`。
- **作用**：绑定 core context 并 retain realm。
- **实现**：填 `context`、`RealmRef.retain(context)`、`output`；handler 切片默认空。
- **所有权 / 错误 / 调用**：`realm` 必须在 `deinit` 里 `RealmRef.deinit`。无错误。

### `EventLoop.install` (`src/event_loop.zig:81`)

- **签名**：`pub fn install(self: *EventLoop) void`。
- **作用**：把循环挂到 context 的 `HostEventLoop` 槽，让 `setTimeout` / `os.poll` 等能找到 vtable。
- **实现**：`context.setHostEventLoop(.{ .ptr = self, .vtable = &vtable })`，`installed = true`。
- **所有权 / 错误 / 调用**：同一 context 同时只能有一个 host loop。`deinit` 若 `installed` 会 `clearHostEventLoop(self)`。

### `EventLoop.deinit` (`src/event_loop.zig:89`)

- **签名**：`pub fn deinit(self: *EventLoop) void`。
- **作用**：卸 vtable、释放三张表的 capacity 切片、放 realm。
- **实现**：先 clear host loop。`len` 是活条目，分配按 capacity，所以 `free(ptr[0..capacity])`。先把字段置空再 free，防止析构重入看见半释放表。tracing GC 下回调 `JSValue` 不必逐个 `free`。
- **所有权 / 错误 / 调用**：必须在 context/runtime 销毁之前。CLI 默认成功路径不调用（进程退出）；`--leak-check` 与 test262 每测 teardown 会调。

### `EventLoop.runUntilIdle` (`src/event_loop.zig:117`)

- **签名**：`pub fn runUntilIdle(self: *EventLoop) !RunResult`。
- **作用**：排空当前 context 上的 Promise job 以及由 vtable 接到的宿主臂，直到空闲。
- **实现**：取 `globalObject()`，调 `exec.zjs_vm.drainPendingPromiseJobs`。该函数内部顺序见主册「事件循环排空顺序」。job 排水若以非异常错误失败，且 context 上已有 exception/rejection，则吞掉 Zig error，改由 `result()` 报告。
- **所有权 / 错误 / 调用**：可能 `error.JSException` 或 exec 的分配错误。顶层 `runUntilIdle` 包装器、单测「drains queued JS callbacks」。

### `EventLoop.result` (`src/event_loop.zig:125`)

- **签名**：`pub fn result(self: *const EventLoop) RunResult`。
- **作用**：快照 context 上是否还有未取走的异常 / 未处理 rejection。
- **实现**：读 `hasException` / `hasUnhandledRejection`。
- **所有权 / 错误 / 调用**：无。`runUntilIdle` 的返回值。

### `EventLoop.setExitCode` (`src/event_loop.zig:132`)

- **签名**：`pub fn setExitCode(self: *EventLoop, code: u8) void`。
- **作用**：记录 `process.exit` 请求的退出码。
- **实现**：写 `exit_code`。
- **所有权 / 错误 / 调用**：vtable 包装 `setExitCode`；CLI `exitIfRequested` 读它。

### `EventLoop.exitCode` (`src/event_loop.zig:136`)

- **签名**：`pub fn exitCode(self: *const EventLoop) ?u8`。
- **作用**：读出已请求的退出码。
- **实现**：返回 `exit_code`。
- **所有权 / 错误 / 调用**：无：`*const` 只读访问器，返回一个 `?u8` 标量，不分配、不建根、无 error。CLI 的 `exitIfRequested`（`src/cli/zjs.zig:570`）直接调这个方法；此外还经 `vtable.exitCode`（表项在 :585，`*anyopaque` 适配器在 :610）暴露给 `core.context.HostEventLoop`。

### `EventLoop.traceRoots` (`src/event_loop.zig:140`)

- **签名**：`fn traceRoots(self: *EventLoop, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：把三张表里的回调值交给 tracer。
- **实现**：逐个 `timer.traceRoots` / `handler.traceRoots`。
- **所有权 / 错误 / 调用**：GC 经 vtable `traceRoots`；失败向上传 `RootTraceError`。

## 定时器

### `EventLoop.takeNextTimerId` (`src/event_loop.zig:152`)

- **签名**：`fn takeNextTimerId(self: *EventLoop) i64`。
- **作用**：分配可当 JS Number 的 timer id。
- **实现**：返回当前 id，`+= 1`；若 `> 9007199254740991`（2^53−1）回到 1。
- **所有权 / 错误 / 调用**：vtable `nextTimerId`；`setTimeout` 宿主。不复用仍活着的 id（回绕在极端长时间运行才发生）。

### `EventLoop.ensureTimerCapacity` (`src/event_loop.zig:159`)

- **签名**：`fn ensureTimerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void`。
- **作用**：把 timer 数组扩到至少 `min_capacity`。
- **实现**：0→2，之后倍增。`rt.memory.alloc(Timer, next)`，拷旧、换切片、free 旧 capacity。`errdefer` 释放新块。
- **所有权 / 错误 / 调用**：OOM 经 runtime 内存记账。`enqueueTimer`。

### `EventLoop.enqueueTimer` (`src/event_loop.zig:176`)

- **签名**：`pub fn enqueueTimer(self: *EventLoop, ctx: *core.JSContext, id: i64, callback: zjs.JSValue, delay_ms: u64, repeats: bool) !void`。
- **作用**：登记一条 timer，到期时刻 = `nowMs() + delay_ms`。
- **实现**：扩容后把 `len` 伸一格，`Timer.init(...)` 写入。回调值按位存放，由 `traceRoots` 保活。
- **所有权 / 错误 / 调用**：扩容可能 OOM。test262 `setTimeout`、单测。vtable 包装会 `assert(ctx == self.context)`。

### `EventLoop.clearTimer` (`src/event_loop.zig:184`)

- **签名**：`fn clearTimer(self: *EventLoop, ctx: *core.JSContext, id: i64) void`。
- **作用**：按 id 删一条 timer（`clearTimeout`）。
- **实现**：`id <= 0` 直接回。线性扫描，命中 `removeTimerAt` 后 return。
- **所有权 / 错误 / 调用**：无分配。vtable。

### `EventLoop.removeTimerAt` (`src/event_loop.zig:194`)

- **签名**：`fn removeTimerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void`。
- **作用**：O(n) 前移删除，空表时归还整块。
- **实现**：`@memmove` 压缩。`len==0` 且 capacity≠0 则 `free` 整块并清 capacity。中间删除不 realloc（单测钉死 allocated_bytes 不变）。
- **所有权 / 错误 / 调用**：`clearTimer`、一次性 timer 开火、单测。

### `EventLoop.runNextTimer` (`src/event_loop.zig:209`)

- **签名**：`fn runNextTimer(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：跑一个到期 timer，或睡到下一期限 / atomics 信号。
- **实现**：无 timer → `false`。扫表：未到期的记最小剩余；到期的——一次性则先 `removeTimerAt`，重复则刷新 `timeout_ms = now+delay`。回调在调用前挂 `ValueRootFrame`（生产 tracing 擦标量根，一次性 timer 出队后必须有窗口根）。若回调是未结算 Promise，填 `undefined` 结果并 `settlePendingPromiseReaction`；否则 `callValueOrBytecodeRoot(this=global, argv=[])`。重复 timer 若回调里被 `clearTimeout`，仍返回 `true`。全未到期则：有 atomics waiter 时 `waitForAtomicsHostSignalUntil`（可被 waitAsync 叫醒并缩短到 waiter 期限），否则 `sleep`。`sleep` 失败忽略。
- **所有权 / 错误 / 调用**：调用错误向上传。返回 `true` 表示本臂有进展，排水循环回到 job 队列。对照 `quickjs-libc.c` 的 timer 臂。

### `EventLoop.timerExists` (`src/event_loop.zig:264`)

- **签名**：`fn timerExists(self: *const EventLoop, id: i64) bool`。
- **作用**：重复 timer 开火后，看回调是否把它清掉了。
- **实现**：线性扫 `id`。
- **所有权 / 错误 / 调用**：仅 `runNextTimer`。

## fd 读/写 handler

### `EventLoop.ensureRwHandlerCapacity` (`src/event_loop.zig:271`)

- **签名**：`fn ensureRwHandlerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void`。
- **作用**：扩 rw 表，算法同 timer。
- **实现**：0→2 倍增，拷、换、free 旧。
- **所有权 / 错误 / 调用**：OOM。`setRwHandler`。

### `EventLoop.setRwHandler` (`src/event_loop.zig:288`)

- **签名**：`fn setRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool, callback: zjs.JSValue) !void`。
- **作用**：给 fd 的读或写槽登记回调；已有同一 fd 则覆盖对应槽。
- **实现**：命中现有 `fd` 则 `setCallback`；否则扩容追加 `RwHandler{ .fd }`。
- **所有权 / 错误 / 调用**：OOM。只经 `core.context.HostEventLoop.setRwHandler` 这道 vtable 缝进入；树内没有注册 fd 回调的 JS 内建（形状对照 quickjs-libc 的 `os.setReadHandler` / `setWriteHandler`），留给嵌入宿主。

### `EventLoop.clearRwHandler` (`src/event_loop.zig:304`)

- **签名**：`fn clearRwHandler(self: *EventLoop, ctx: *core.JSContext, fd: i32, write_handler: bool) void`。
- **作用**：清读或写槽；两槽都 null 则删整行。
- **实现**：`clearCallback` 后若 `read` 与 `write` 皆 `is(.null_value)`，`removeRwHandlerAt`。
- **所有权 / 错误 / 调用**：无分配。vtable。

### `EventLoop.removeRwHandlerAt` (`src/event_loop.zig:316`)

- **签名**：`fn removeRwHandlerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void`。
- **作用**：压缩删除 rw 行；空表归还整块。
- **实现**：同 `removeTimerAt`。
- **所有权 / 错误 / 调用**：`clearRwHandler`、单测。

### `EventLoop.runNextRwHandler` (`src/event_loop.zig:331`)

- **签名**：`fn runNextRwHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：按 OS 选 Windows / POSIX 就绪臂。
- **实现**：`comptime` 分支。
- **所有权 / 错误 / 调用**：vtable。

### `EventLoop.runNextRwHandlerWindows` (`src/event_loop.zig:341`)

- **签名**：`fn runNextRwHandlerWindows(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：Windows 上只等可读 stdin，对齐 QuickJS：任意 CRT fd 不是 waitable HANDLE。
- **实现**：找 `fd==0` 且有 read 回调的 handler，否则 `false`。有 pending job 或 atomics waiter 则 timeout=0；否则无 timer 时 `INFINITE`，有 timer 则下一期限。`GetStdHandle(STD_INPUT_HANDLE)` + `WaitForSingleObject`；非 `WAIT_OBJECT_0` 返回 `false`。命中则 `callValueOrBytecodeRoot` 一次。
- **所有权 / 错误 / 调用**：不分配 poll 数组。调用错误向上。

### `EventLoop.runNextRwHandlerPosix` (`src/event_loop.zig:376`)

- **签名**：`fn runNextRwHandlerPosix(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：`poll(2)` 等待已登记 fd 的 POLLIN/POLLOUT。
- **实现**：runtime 内存分配 `struct_pollfd`（defer free）。无事件的 handler 跳过。timeout：有 job/atomics → 0；无 timer → −1；否则下一 timer（已到期记 0）。`poll` ≤0 → `false`。按 pollfd 顺序找第一个就绪 handler：读优先（POLLIN|ERR|HUP），再写。每次只调一个回调后 return `true`。
- **所有权 / 错误 / 调用**：pollfd 数组记账到 runtime。对照 `quickjs-libc.c` poll 循环。

## 信号

### `EventLoop.ensureSignalHandlerCapacity` (`src/event_loop.zig:437`)

- **签名**：`fn ensureSignalHandlerCapacity(self: *EventLoop, ctx: *core.JSContext, min_capacity: usize) !void`。
- **作用**：扩信号表。
- **实现**：同 timer 倍增。
- **所有权 / 错误 / 调用**：OOM。`setSignalHandler`。

### `EventLoop.setSignalHandler` (`src/event_loop.zig:454`)

- **签名**：`fn setSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, callback: zjs.JSValue) !void`。
- **作用**：登记/覆盖信号回调，并把 OS handler 接到 `osSignalHandler`。
- **实现**：已有 `sig` 则换 callback 并 `signal(sig, osSignalHandler)`；否则追加 `SignalHandler.init` 再 `signal`。
- **所有权 / 错误 / 调用**：OOM。`signal(2)` 失败被忽略（返回值丢弃）。vtable。

### `EventLoop.clearSignalHandler` (`src/event_loop.zig:469`)

- **签名**：`fn clearSignalHandler(self: *EventLoop, ctx: *core.JSContext, sig: u32, disposition: core.context.SignalDisposition) void`。
- **作用**：撤 JS 回调，并把 OS 处置改回 default/ignore。
- **实现**：找到则 `removeSignalHandlerAt`。然后 `signal(sig, 0|1)` 对应 `.default` / `.ignore`。
- **所有权 / 错误 / 调用**：即使没找到 JS handler 也重置 OS 处置。vtable。

### `EventLoop.removeSignalHandlerAt` (`src/event_loop.zig:482`)

- **签名**：`fn removeSignalHandlerAt(self: *EventLoop, ctx: *core.JSContext, index: usize) void`。
- **作用**：压缩删除信号行。
- **实现**：同其它 `remove*At`。
- **所有权 / 错误 / 调用**：`clearSignalHandler`、单测。

### `EventLoop.runNextSignalHandler` (`src/event_loop.zig:497`)

- **签名**：`fn runNextSignalHandler(self: *EventLoop, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：把 `os_pending_signals` 里置位的一个信号派成 JS 调用。
- **实现**：位图 0 → `false`。扫 handlers，命中则清该 bit，`callValueOrBytecodeRoot(this=undefined, argv=[])`（信号回调无 this）。每次一个。
- **所有权 / 错误 / 调用**：信号处理函数本身不跑 JS。vtable；排水循环第一宿主臂。

## 顶层包装与内部记录

### `runUntilIdle` (`src/event_loop.zig:512`)

- **签名**：`pub fn runUntilIdle(context: *zjs.JSContext, options: Options) !RunResult`。
- **作用**：给嵌入方一次性「装循环、排空、拆掉」。
- **实现**：栈上 `EventLoop.init` + `install`，`defer deinit`，调方法 `runUntilIdle`。
- **所有权 / 错误 / 调用**：`root.zig` re-export。CLI 自己持有长寿命 `EventLoop`，不走这条。

### `Timer.init` (`src/event_loop.zig:526`)

- **签名**：`fn init(id: i64, callback: zjs.JSValue, timeout_ms: u64, delay_ms: u64, repeats: bool) Timer`。
- **作用**：填一条 timer 记录。
- **实现**：结构字面量。不 dup 回调。
- **所有权 / 错误 / 调用**：`enqueueTimer`。

### `Timer.traceRoots` (`src/event_loop.zig:536`)

- **签名**：`fn traceRoots(self: *Timer, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：标记 timer 回调槽。
- **实现**：`visitor.value(&self.callback)`。
- **所有权 / 错误 / 调用**：`EventLoop.traceRoots`。

### `RwHandler.setCallback` (`src/event_loop.zig:546`)

- **签名**：`fn setCallback(self: *RwHandler, write_handler: bool, callback: zjs.JSValue) void`。
- **作用**：覆盖读或写槽。
- **实现**：选 `write_callback` / `read_callback` 赋值。旧值直接丢掉（tracing，无 RC）。
- **所有权 / 错误 / 调用**：`setRwHandler`。

### `RwHandler.clearCallback` (`src/event_loop.zig:551`)

- **签名**：`fn clearCallback(self: *RwHandler, write_handler: bool) void`。
- **作用**：槽置 `null`。
- **实现**：写 `JSValue.nullValue()`。
- **所有权 / 错误 / 调用**：`clearRwHandler`。

### `RwHandler.traceRoots` (`src/event_loop.zig:556`)

- **签名**：`fn traceRoots(self: *RwHandler, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：标记读写两个回调槽。
- **实现**：两次 `visitor.value`。
- **所有权 / 错误 / 调用**：`EventLoop.traceRoots`。

### `SignalHandler.init` (`src/event_loop.zig:566`)

- **签名**：`fn init(sig: u32, callback: zjs.JSValue) SignalHandler`。
- **作用**：填信号记录。
- **实现**：结构字面量。
- **所有权 / 错误 / 调用**：`setSignalHandler`、单测手工插入。

### `SignalHandler.setCallback` (`src/event_loop.zig:573`)

- **签名**：`fn setCallback(self: *SignalHandler, callback: zjs.JSValue) void`。
- **作用**：覆盖信号回调。
- **实现**：赋值。
- **所有权 / 错误 / 调用**：`setSignalHandler` 命中已有 sig。

### `SignalHandler.traceRoots` (`src/event_loop.zig:577`)

- **签名**：`fn traceRoots(self: *SignalHandler, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：标记信号回调。
- **实现**：`visitor.value(&self.callback)`。
- **所有权 / 错误 / 调用**：`EventLoop.traceRoots`。

## vtable 包装（`callconv` 经 `HostEventLoop`）

这些自由函数把 `*anyopaque` 转回 `*EventLoop`，并 `assert` 传入的 core context 就是循环绑定的那个。exec 只看见 vtable。

### `fromOpaque` (`src/event_loop.zig:598`)

- **签名**：`fn fromOpaque(ptr: *anyopaque) *EventLoop`。
- **作用**：vtable 入口的类型恢复。
- **实现**：`@ptrCast(@alignCast(ptr))`。
- **所有权 / 错误 / 调用**：所有 vtable 包装。

### `traceRoots` (`src/event_loop.zig:602`)

- **签名**：`fn traceRoots(ptr: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：vtable 的根扫描入口。
- **实现**：`fromOpaque(ptr).traceRoots(visitor)`。
- **所有权 / 错误 / 调用**：`JSRuntime.traceActiveRoots` → `HostEventLoop.traceRoots`。

### `setExitCode` (`src/event_loop.zig:606`)

- **签名**：`fn setExitCode(ptr: *anyopaque, code: u8) void`。
- **作用**：vtable 写退出码。
- **实现**：转 `EventLoop.setExitCode`。
- **所有权 / 错误 / 调用**：树内没有调用 `HostEventLoop.setExitCode` 的内建，留给实现 `std.exit` 的嵌入宿主；CLI 只在 `error.ProcessExit` 后读 `exitCode`。

### `exitCode` (`src/event_loop.zig:610`)

- **签名**：`fn exitCode(ptr: *anyopaque) ?u8`。
- **作用**：vtable 读退出码。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：CLI `exitIfRequested` 走 `EventLoop.exitCode` 方法；其它宿主可走 vtable。

### `nextTimerId` (`src/event_loop.zig:614`)

- **签名**：`fn nextTimerId(ptr: *anyopaque) i64`。
- **作用**：vtable 分配 timer id。
- **实现**：`takeNextTimerId`。
- **所有权 / 错误 / 调用**：`setTimeout`。

### `enqueueTimer` (`src/event_loop.zig:618`)

- **签名**：`fn enqueueTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64, callback: zjs.JSValue, delay_ms: u64, repeats: bool) !void`。
- **作用**：vtable 入队 timer。
- **实现**：assert context 一致后转方法。
- **所有权 / 错误 / 调用**：本层只做 `@ptrCast` 还原与 `ctx == core_ctx` 的 assert，不分配；真正的所有权在 `EventLoop.enqueueTimer`（:176）：`callback` 这个 JSValue 被**存进** `self.timers`（`rt.memory` 分配的数组，`ensureTimerCapacity` 倍增、旧块当场 free），此后由 `EventLoop.traceRoots`（:140）逐个 `timer.traceRoots` 当作 GC 根扫描，直到 `removeTimerAt` 摘掉。error 只有 `ensureTimerCapacity` 的 OOM，且 `errdefer` 保证失败时新块不漏。不被直接调用，只作为 `vtable.enqueueTimer`（:587）的函数指针。

### `clearTimer` (`src/event_loop.zig:624`)

- **签名**：`fn clearTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, id: i64) void`。
- **作用**：vtable 删 timer。
- **实现**：assert 后转方法。
- **所有权 / 错误 / 调用**：树内只有 `core.context.HostEventLoop.clearTimer` 这层包装，没有内建调用方；留给实现 `clearTimeout` 的宿主。

### `runNextTimer` (`src/event_loop.zig:630`)

- **签名**：`fn runNextTimer(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：vtable 定时器臂。
- **实现**：转 `EventLoop.runNextTimer`。
- **所有权 / 错误 / 调用**：`drainPendingPromiseJobs` 第 4 臂。

### `setRwHandler` (`src/event_loop.zig:636`)

- **签名**：`fn setRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool, callback: zjs.JSValue) !void`。
- **作用**：vtable 登记 fd 回调。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：同 `enqueueTimer` 的适配器形状：本层不分配。`EventLoop.setRwHandler`（:288）把 `callback` 存进 `RwHandler.read_callback`/`write_callback`，同 fd 已存在时直接覆盖（旧回调就此失去这条根），新 fd 则 `ensureRwHandlerCapacity` 扩数组；存入后由 `traceRoots` 当 GC 根扫描。error 只有扩容 OOM。注册点 `vtable.setRwHandler`（:590）。

### `clearRwHandler` (`src/event_loop.zig:642`)

- **签名**：`fn clearRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, fd: i32, write_handler: bool) void`。
- **作用**：vtable 清 fd 回调。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：无 error、不分配；反向解除所有权：`EventLoop.clearRwHandler`（:304）把对应方向的回调置 null，读写两侧都空了才 `removeRwHandlerAt` 把槽位移出数组（数组清空时才把 backing 块还给 `rt.memory`），被摘掉的回调随之失去 GC 根。注册点 `vtable.clearRwHandler`（:591）。

### `runNextRwHandler` (`src/event_loop.zig:648`)

- **签名**：`fn runNextRwHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：vtable fd 臂。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：排水第 3 臂。

### `setSignalHandler` (`src/event_loop.zig:654`)

- **签名**：`fn setSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, callback: zjs.JSValue) !void`。
- **作用**：vtable 登记信号。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：本层不分配。`EventLoop.setSignalHandler`（:454）把 `callback` 存进 `SignalHandler`（同 sig 覆盖 / 否则 `ensureSignalHandlerCapacity` 扩容），随后由 `SignalHandler.traceRoots`（:577）当 GC 根；副作用是向 OS 注册 `osSignalHandler`。error 只有扩容 OOM——注意 `signal()` 的注册在扩容之后，OOM 时不会留下没有回调的 OS handler。注册点 `vtable.setSignalHandler`（:593）。

### `clearSignalHandler` (`src/event_loop.zig:660`)

- **签名**：`fn clearSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, sig: u32, disposition: core.context.SignalDisposition) void`。
- **作用**：vtable 撤信号。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：无 error、不分配；`EventLoop.clearSignalHandler`（:469）先 `removeSignalHandlerAt` 摘掉槽位（回调失去 GC 根，数组清空时归还 backing 块），再按 `disposition` 把 OS 处置改回 `SIG_DFL`(0)/`SIG_IGN`(1)——即使本来就没登记过也照样改 OS 状态。注册点 `vtable.clearSignalHandler`（:594）。

### `runNextSignalHandler` (`src/event_loop.zig:666`)

- **签名**：`fn runNextSignalHandler(ptr: *anyopaque, core_ctx: *core.context.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool`。
- **作用**：vtable 信号臂。
- **实现**：转方法。
- **所有权 / 错误 / 调用**：排水第 2 臂。

### `osSignalHandler` (`src/event_loop.zig:674`)

- **签名**：`fn osSignalHandler(sig: c_int) callconv(.c) void`。
- **作用**：OS 信号里只置位，禁止跑 JS / 分配。
- **实现**：`sig` 不在 `[0,64)` 则回；否则 `os_pending_signals |= 1<<sig`。
- **所有权 / 错误 / 调用**：`signal(2)` 登记。async-signal-safe。

### `nowMs` (`src/event_loop.zig:679`)

- **签名**：`fn nowMs() u64`。
- **作用**：醒时钟毫秒，给 timer 期限。
- **实现**：`Clock.Timestamp.now(hostTimerIo(), .awake)` ns / `ns_per_ms`。
- **所有权 / 错误 / 调用**：`enqueueTimer` / `runNextTimer` / Windows timeout。

### `hostTimerIo` (`src/event_loop.zig:684`)

- **签名**：`fn hostTimerIo() std.Io`。
- **作用**：循环用的单线程 Io。
- **实现**：`std.Io.Threaded.global_single_threaded.io()`。
- **所有权 / 错误 / 调用**：sleep / now。不是进程线程池。

## 测试里的 visitor（清单收录）

### `Counter.visitValue` (`src/event_loop.zig:899`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *zjs.JSValue) core.runtime.RootTraceError!void`。
- **作用**：单测计数 event-loop 根里值为 102–105 的 int32。
- **实现**：`asInt32` 落在区间则 `count += 1`。
- **所有权 / 错误 / 调用**：仅 `"runtime root tracer visits EventLoop host roots"`。

### `Counter.visitObject` (`src/event_loop.zig:906`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：满足 `RootVisitor` 的 object 回调；本测不关心对象根。
- **实现**：忽略参数。
- **所有权 / 错误 / 调用**：同上。

---

## 覆盖核对

- 清单函数数: 见当前 `src/event_loop.zig`（`src/runtime/root.zig` 已删除）
- 本文标题覆盖: 57
- 未覆盖: 无
