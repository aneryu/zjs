# 17 — Atomics 与 ArrayBuffer

Atomics RMW 是单指令原子操作。**waitAsync：外线程只 signal，Promise/堆只在 owner 线程变。** ArrayBuffer 存储在 core；本册是记录分发和可读用户 options 的构造参数。



## `src/exec/atomics_ops.zig` — Atomics 与 waitAsync 线程规则

RMW 用单条 `@atomicRmw` / `@cmpxchgStrong`（seq_cst），避免「读-算-写」丢掉并发更新。

**waitAsync 线程规则（硬不变量）**：

- **外线程（notify）只发信号**：`atomicsWakeWaiters` 只把 `completion` 从 `waiting` 写成 `notified`，`cond.signal`，并对 waitAsync 节点 `signalHostCompletion`。不分配、不碰 Promise、不改 RealmRef。
- **堆突变只在 owner 线程**：链接/拆链 waiter、造 Promise、`processExpiredAtomicsWaiters` 入队、`atomicsRunAsyncWaiterCompletion` 结算，全部 `assertOwnerThread`。
- 入队分配失败时，在 **mutex 外** 把已冻结的 completion 重新链回去，避免持锁跑 GC。

同步 `Atomics.wait` 用栈上 `AtomicsWaiter` + condition；`canBlock()==false` 的线程在比较内存之前就 TypeError（quickjs.c:60900）。


### `methodId` (`src/exec/atomics_ops.zig:35`)

- **签名**：`pub fn methodId(name: []const u8) ?u32`。
- **作用**：安装 `Atomics` 命名空间时，把函数列表里的方法名翻成 `.atomics` domain 的记录 id（`atomics_wait.StaticMethod` 的序号）。
- **实现**：14 条 `std.mem.eql` 顺序比较 `isLockFree`/`load`/`store`/`add`/`sub`/`and`/`or`/`xor`/`exchange`/`compareExchange`/`wait`/`waitAsync`/`notify`/`pause`，命中即 `@intFromEnum`（`and`/`or` 写成 Zig 转义成员 `@"and"`/`@"or"`）；全不中返回 null。
- **所有权 / 错误 / 调用**：纯比较，不分配、不持根。唯一调用点是 `standard_globals.zig:440` 的 `.atomics` 安装分支，而那张表在 comptime 建：返回 null 会让 `setRequiredMethodNativeBuiltinId` 触发 `@compileError`，所以方法名表和这里必须同步。

### `atomicsEntry` (`src/exec/atomics_ops.zig:73`)

- **签名**：`fn atomicsEntry( comptime name: []const u8, comptime length: u8, comptime method: StaticMethod, ) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，为 `internal_entries` 里 14 个 `Atomics.*` 方法各生成一行 `InternalEntry`（属性名、`length`、记录 id、magic、cproto、native 函数指针）。
- **实现**：`id = @intFromEnum(method)` 同时填 `.id` 与 `.magic`，`cproto` 固定 `.generic_magic`，`native_function` 是 `genericMagicFunction(&atomicsCall)`。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项；`name` 是字符串字面量，无运行期分配，不会失败。

### `atomicsCall` (`src/exec/atomics_ops.zig:89`)

- **签名**：`fn atomicsCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：14 个 `Atomics.*` 函数对象共用的 native 函数体：记录里的 `magic` 就是方法 id，这里只还原执行环境再转给 `atomicsCallForNativeRecord`。
- **实现**：`nativeCall` 从 native ABI 还原出 `NativeCall`（ctx、this、args、magic、`output`、调用方 bytecode/frame），失败即 `error.TypeError`；再 `callableRealm` 取函数对象所属 realm 并 `assert(realm.realm == host_call.ctx)`——Atomics 方法不跨 realm；最后把 `host_call.magic` 当方法 id 连同 realm 的 global 交给 `atomicsCallForNativeRecord`。
- **所有权 / 错误 / 调用**：this/args 借用；返回值（数字/BigInt/字符串/Promise/结果对象）都是 GC 管理的新值。`nativeCall` 认不出调用形态时返回**裸** `error.TypeError`（无 pending exception，由 native seam 的 `materializeRuntimeError` 渲染）；`callableRealm` 解析 realm 后整块工作交给 `atomicsCallForNativeRecord`，其错误（`RangeError` 索引、`TypeError` detached/非共享、用户 getter 抛出）多数仍是裸哨兵，只有下游真正调用过 `throw*Message` 的分支才带 pending exception。没有直接调用方：经 `atomicsEntry(...)` 的 `genericMagicFunction(&atomicsCall)`（`src/exec/atomics_ops.zig:85`）由 `.atomics` 记录表分发。

### `atomicsCallForNativeRecord` (`src/exec/atomics_ops.zig:150`)

- **签名**：`pub fn atomicsCallForNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：按 Atomics 方法 id 转到 isLockFree/pause/notify/wait/waitAsync/store/RMW。
- **实现**：`wait_async` 走 `promise_ops.atomicsWaitAsync`（再进本文件的 `atomicsWaitAsync`）。load 与加减与或异或交换走 `atomicsReadModifyWrite`。未知 id → TypeError。
- **所有权 / 错误 / 调用**：入参借用。返回拥有的 JSValue。调用方：`atomicsCall`。

### `atomicsIsLockFree` (`src/exec/atomics_ops.zig:179`)

- **签名**：`pub fn atomicsIsLockFree( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Atomics.isLockFree(size)`：size ToInt32 后是否为 1/2/4/8。
- **实现**：`toInt32ForAtomics` 后返回 boolean。与 `atomics_wait.isLockFree` 同一集合。
- **所有权 / 错误 / 调用**：不碰共享内存。

### `atomicsPause` (`src/exec/atomics_ops.zig:192`)

- **签名**：`pub fn atomicsPause( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Atomics.pause([n])`：可选参数必须是有限整数，否则 TypeError；本体是空操作。
- **实现**：有参数且非 undefined 则检查 isNumber 且 trunc 后仍是该数。不调用 CPU pause。
- **所有权 / 错误 / 调用**：无堆分配。

### `atomicsReadModifyWrite` (`src/exec/atomics_ops.zig:213`)

- **签名**：`pub fn atomicsReadModifyWrite( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, atomic_op: AtomicsReadModifyOp, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Atomics.load/add/and/or/sub/xor/exchange/compareExchange 的共享体：校验视图、原子 RMW、装箱旧值。
- **实现**：`atomicsTypedArray`（非 waitable）。非 load 拒绝 immutable buffer。`atomicsGetBufIndex` 按 qjs `old_len` 规则。operand/replacement 按是否 bigint 走 ToBigInt 或 ToUint32。非 load 在 coerce 后再 `atomicsRevalidateIndex`。`atomicsReadModifyWriteBits` 一条原子指令。
- **所有权 / 错误 / 调用**：对照 js_atomics_op（quickjs.c:60637-60697）。并发安全靠硬件原子，不是读-算-写。

### `atomicsStore` (`src/exec/atomics_ops.zig:253`)

- **签名**：`pub fn atomicsStore( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Atomics.store`：写入后返回**被转换的值**（不是旧值）。
- **实现**：校验视图、index、ToInteger/ToBigInt，再 `atomicsRevalidateIndex`（js_atomics_store 60770），`atomicsWriteBits`。
- **所有权 / 错误 / 调用**：返回的是 store 的输入转换结果，调用方拥有。

### `atomicsNotify` (`src/exec/atomics_ops.zig:286`)

- **签名**：`pub fn atomicsNotify( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Atomics.notify`：唤醒最多 count 个匹配 waiter，返回实际唤醒数。
- **实现**：waitable typed array；非 SAB 且 detached → TypeError。count 默认 +∞。非 SAB 或 count==0 返回 0。否则 `atomicsWakeWaiters`。
- **所有权 / 错误 / 调用**：可从任意代理线程调用 wake；本函数本身在 JS 调用线程。

### `atomicsWait` (`src/exec/atomics_ops.zig:308`)

- **签名**：`pub fn atomicsWait( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Atomics.wait`：同步阻塞直到 notify 或超时。
- **实现**：必须是 SAB。coerce 之后、load 之前检查 `canBlock()`（quickjs.c:60900）。值不等返回 `"not-equal"`；timeout 0 返回 `"timed-out"`；否则 `atomicsWaitForNotification`。
- **所有权 / 错误 / 调用**：栈上 waiter。字符串在释放 registry 锁之后才分配。

### `atomicsNotifyCount` (`src/exec/atomics_ops.zig:343`)

- **签名**：`pub fn atomicsNotifyCount( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：解析 `Atomics.notify` 的第三个参数 count（省略即「全部唤醒」）。
- **实现**：缺参或 undefined 直接返回 `maxInt(usize)`；否则 `toIntegerValueForAtomics` 之后：取不出数值、NaN 或 ≤0 → 0，非有限 → `maxInt(usize)`，其余截到 `maxInt(i32)`。
- **所有权 / 错误 / 调用**：转换可跑用户代码（valueOf），error 上抛；调用方 `atomicsNotify`。

### `atomicsWaitTimeoutMilliseconds` (`src/exec/atomics_ops.zig:359`)

- **签名**：`pub fn atomicsWaitTimeoutMilliseconds(timeout: f64) ?i64`。
- **作用**：把 ToNumber 后的 timeout 折成等待毫秒数。
- **实现**：NaN 或 ±∞ 返回 null（表示无限等待）；≤0 返回 0；其余截到 `maxInt(i64)`。
- **所有权 / 错误 / 调用**：纯函数；调用方 `atomicsWait` 与 `atomicsWaitAsync`（后者用它算 deadline）。

### `atomicsWaiterKey` (`src/exec/atomics_ops.zig:365`)

- **签名**：`pub fn atomicsWaiterKey(view: *core.Object, bytes: []const u8) !AtomicsWaiterKey`。
- **作用**：为一个等待位置算出跨线程可比的 waiter key。
- **实现**：SharedArrayBuffer 且能取到 `sharedByteStorageStore()` 时，key = (store, 该字节相对 `byteStorage()` 基址的偏移)；否则退回裸地址 `@intFromPtr(bytes.ptr)`，`store` 为 null。
- **所有权 / 错误 / 调用**：key 里的 store 是借用；真正登记到链表前要 `atomicsRetainWaiterKey`。调用方 `atomicsNotify` / `atomicsWait` / `atomicsWaitAsync`。

### `atomicsWaiterKeysEqual` (`src/exec/atomics_ops.zig:377`)

- **签名**：`pub fn atomicsWaiterKeysEqual(a: AtomicsWaiterKey, b: AtomicsWaiterKey) bool`。
- **作用**：比较两个 waiter key：store 指针与 offset_or_ptr 都相等才算同一等待位置。
- **实现**：`a.store == b.store and a.offset_or_ptr == b.offset_or_ptr`。
- **所有权 / 错误 / 调用**：无：比较 `store` 指针与偏移两个标量，不 retain（键的引用计数由 `atomicsRetainWaiterKey`/`atomicsReleaseWaiterKey` 管），不分配、无 error set。唯一调用方 `atomicsWakeWaiters`（`src/exec/atomics_ops.zig:401`），调用时持有 `atomics_waiter_mutex`。

### `atomicsRetainWaiterKey` (`src/exec/atomics_ops.zig:381`)

- **签名**：`pub fn atomicsRetainWaiterKey(key: AtomicsWaiterKey) void`。
- **作用**：key 带 `SharedBufferStore` 时 retain，保证等待期间共享存储不被释放。
- **实现**：`if (key.store) |store| store.retain();`，非共享 key 无操作。
- **所有权 / 错误 / 调用**：这一步就是所有权本身：登记到跨 Runtime 链表前必须 retain，配套的释放是 `atomicsReleaseWaiterKey`。

### `atomicsReleaseWaiterKey` (`src/exec/atomics_ops.zig:385`)

- **签名**：`pub fn atomicsReleaseWaiterKey(key: *AtomicsWaiterKey) void`。
- **作用**：释放 `atomicsRetainWaiterKey` 拿的那份 store 引用。
- **实现**：release 之后把 `key.store` 置 null，所以重复调用是幂等的。
- **所有权 / 错误 / 调用**：归还 `atomicsRetainWaiterKey` 的那一份引用；`atomicsWaitForNotification` 用 `defer`、`atomicsDestroyAsyncWaiter` 在销毁节点时调用。

### `atomicsWakeWaiters` (`src/exec/atomics_ops.zig:392`)

- **签名**：`pub fn atomicsWakeWaiters(key: AtomicsWaiterKey, count: usize) usize`。
- **作用**：按 key 唤醒最多 count 个 waiter。可在外线程跑：只写 completion 标量并 signal，不碰 JS 堆。
- **实现**：持 `atomics_waiter_mutex` 扫链表。匹配且仍 `waiting` 的节点：`completion=.notified`，`cond.signal`；若有 promise 则 `realm.borrow().runtime.signalHostCompletion`。
- **所有权 / 错误 / 调用**：外线程禁止分配、禁止改 Promise。owner 稍后 `processExpiredAtomicsWaiters` 才入队。

### `processExpiredAtomicsWaiters` (`src/exec/atomics_ops.zig:424`)

- **签名**：`pub fn processExpiredAtomicsWaiters(ctx: *core.JSContext) !void`。
- **作用**：owner 线程把已通知或到期的 waitAsync 节点拆下，入 typed FIFO job；Promise 结算仍在 `drainOnePendingJob`。
- **实现**：循环：锁 mutex，找本 Runtime 且带 promise 的节点；仍 waiting 则看 deadline，到期则先把 completion 冻成 timed_out 再拆链。解锁后 `job_queue.enqueueAtomicsWaiter`；OOM 则重新链接同一冻结 completion，且绝不在持锁时分配。
- **所有权 / 错误 / 调用**：必须 `assertOwnerThread`。GC/分配只在解锁后。

### `atomicsAsyncWaiterRuntime` (`src/exec/atomics_ops.zig:490`)

- **签名**：`fn atomicsAsyncWaiterRuntime(waiter: *const AtomicsWaiter) ?*core.JSRuntime`。
- **作用**：取一个 waitAsync 节点所属的 Runtime。
- **实现**：`promise == null`（同步栈上 waiter）或 `realm.borrow()` 已失效都返回 null；否则返回该 context 的 runtime。
- **所有权 / 错误 / 调用**：只读：`waiter.realm.borrow()` 拿到的是**借用**的 `*JSContext`（不 retain、不延长寿命），返回其 runtime 指针；同步 waiter（`promise == null`）与已失效 realm 都返回 `null`。不分配、无 error set。**调用契约：调用方必须持有 `atomics_waiter_mutex`**——4 处调用（`:505`、`:530`、`:1256`、`:1272`）全在锁内。

### `atomicsRuntimeHasPendingAsyncWaiters` (`src/exec/atomics_ops.zig:499`)

- **签名**：`pub fn atomicsRuntimeHasPendingAsyncWaiters(rt: *core.JSRuntime) bool`。
- **作用**：该 Runtime 是否还有链在全局链表上的 waitAsync 节点——事件循环用它决定能不能去阻塞一个看不到本 Runtime 完成信号的 OS poll。
- **实现**：跨线程路径只拿 `atomics_waiter_mutex`，不碰 JS 堆。
- **所有权 / 错误 / 调用**：自己 `lockUncancelable` + `defer unlock` 拿全局 `atomics_waiter_mutex` 遍历跨 Runtime 的 waiter 链表，只读、不分配、无 error set；返回的是纯 host 调度事实，不碰 JS 堆。2 处调用：`src/runtime/event_loop.zig:355`、`:393`（决定是否可以阻塞在 OS poll 上）。

### `waitForAtomicsHostSignalUntil` (`src/exec/atomics_ops.zig:516`)

- **签名**：`pub fn waitForAtomicsHostSignalUntil( rt: *core.JSRuntime, external_deadline: ?std.Io.Timestamp, block_indefinite: bool, ) bool`。
- **作用**：owner 线程阻塞等待：外线程的 waitAsync 通知、最近的 waitAsync deadline，或事件循环给的 `external_deadline`，三者谁先到。
- **实现**：入口 `assertOwnerThread`。持 `atomics_waiter_mutex` 扫链表挑本 rt 的节点：已非 `waiting` 的用 now 当 deadline，否则取节点 deadline，与 `external_deadline` 取最小。没有本 rt 的节点、或没有任何有限 deadline 且 `block_indefinite == false`，解锁后返回 false。否则**在同一把锁内** `resetHostCompletionSignal`（保证扫描与等待之间丢不掉通知），解锁后 `waitForHostCompletionUntil` / `waitForHostCompletion`，返回 true。
- **所有权 / 错误 / 调用**：跨线程调用在 owner 边界拒绝。

### `runNextAtomicsHostCompletion` (`src/exec/atomics_ops.zig:558`)

- **签名**：`pub fn runNextAtomicsHostCompletion(ctx: *core.JSContext, block_indefinite: bool) !bool`。
- **作用**：推进一次 owner 线程的 Atomics 主机时钟：先把到期/已通知的节点变成 typed job，没有新 job 才去阻塞等信号。
- **实现**：记下 `job_queue.jobs.len`，跑 `processExpiredAtomicsWaiters`；长度变了说明已入队，返回 true。否则 `waitForAtomicsHostSignalUntil(rt, null, block_indefinite)`，返回 false 就整体返回 false；被唤醒后再跑一次 `processExpiredAtomicsWaiters` 并返回 true。Promise 结算仍留给 `drainOnePendingJob`。
- **所有权 / 错误 / 调用**：跨线程调用在 owner 边界拒绝。

### `cleanupAtomicsWaitersForContext` (`src/exec/atomics_ops.zig:568`)

- **签名**：`pub fn cleanupAtomicsWaitersForContext(ctx: *core.JSContext) void`。
- **作用**：context 拆除时，把链表上属于它的 waitAsync 节点全部摘掉并销毁。
- **实现**：入口 `assertOwnerThread`。循环：持锁找第一个 `realm.borrow() == ctx` 的节点，拆链并清 `linked`/`next`，解锁后 `promise_ops.atomicsDestroyAsyncWaiter`；找不到就返回。销毁始终在锁外。
- **所有权 / 错误 / 调用**：节点内存与 RealmRef 在这里归还；跨线程调用在 owner 边界拒绝。

### `atomicsWaitForNotification` (`src/exec/atomics_ops.zig:599`)

- **签名**：`pub fn atomicsWaitForNotification(rt: *core.JSRuntime, key: AtomicsWaiterKey, timeout_ms: ?i64) !core.JSValue`。
- **作用**：同步 `Atomics.wait` 的等待体：登记栈上 waiter，等到通知或超时，返回 `“ok”` / `“timed-out”`。
- **实现**：`assertOwnerThread` 后 retain key（`defer` 释放），栈上建 `AtomicsWaiter`，持锁 `atomicsLinkWaiter`。`timeout_ms == null` 走 `cond.waitUncancelable` 直到 completion 变化；有限超时则在锁外按 1 ms `std.Io.sleep` 轮询直到 deadline。醒来后记下是否 `.notified`、`atomicsUnlinkWaiter`、解锁，**锁外**才 `createStringValue`。
- **所有权 / 错误 / 调用**：Zig error 向上传，由 `materializeRuntimeError` / `throw*Message` 变成 JS 异常。 跨线程调用在 owner 边界拒绝。

### `atomicsLinkWaiter` (`src/exec/atomics_ops.zig:630`)

- **签名**：`pub fn atomicsLinkWaiter(waiter: *AtomicsWaiter) void`。
- **作用**：把 waiter 追加到全局 waiter 链表尾部。
- **实现**：置 `linked = true`、`next = null`；链表空就当头，否则走到尾节点挂上。本身不加锁，调用方必须已持 `atomics_waiter_mutex`。
- **所有权 / 错误 / 调用**：链表只借用节点；节点内存由同步路径的栈帧或 `atomicsWaitAsync` 的堆分配拥有。调用方：`atomicsWaitForNotification`、`atomicsLinkAsyncWaiter`、`processExpiredAtomicsWaiters` 的 OOM 回滚。

### `atomicsUnlinkWaiter` (`src/exec/atomics_ops.zig:642`)

- **签名**：`pub fn atomicsUnlinkWaiter(waiter: *AtomicsWaiter) void`。
- **作用**：把 waiter 从全局链表上摘下来。
- **实现**：`!waiter.linked` 直接返回；否则顺链找到自己，接好前驱指针（或更新表头），清 `next`/`linked`。同样要求调用方持锁。
- **所有权 / 错误 / 调用**：把节点从全局单链表摘掉并清 `linked`/`next`，**不释放节点内存**：同步 waiter 是等待帧里的栈对象，异步 waiter 由 `atomicsDestroyAsyncWaiter` 负责（它还要 release `RealmRef` 与 waiter key）。不分配、无 error set。**调用契约：必须在持有 `atomics_waiter_mutex` 时调用**——唯一调用方是同步等待循环出口（`src/exec/atomics_ops.zig:623`），它在锁内摘链、解锁后才去 runtime 堆上建结果字符串。

### `Attempt.run` (`src/exec/atomics_ops.zig:683`)

- **签名**：`fn run(self: *@This()) void`。
- **作用**：单测辅助：在另一个 `std.Thread` 上跑 `atomicsWakeWaiters`，证明外线程 notify 不分配。
- **实现**：`self.woken = atomicsWakeWaiters(self.key, 1);`。
- **所有权 / 错误 / 调用**：仅测试使用。

### `Probe.trigger` (`src/exec/atomics_ops.zig:761`)

- **签名**：`fn trigger(raw: ?*anyopaque, _: usize) void`。
- **作用**：单测辅助：挂到 `rt.memory.trigger_gc_fn` 上，在 OOM 触发 GC 的那一刻探测 `atomics_waiter_mutex` 是否真的没被持有。
- **实现**：`tryLock` 成功才记 `mutex_was_free = true` 并立刻解锁；失败直接返回。
- **所有权 / 错误 / 调用**：仅测试使用。

### `atomicsWaiterIo` (`src/exec/atomics_ops.zig:800`)

- **签名**：`pub fn atomicsWaiterIo() std.Io`。
- **作用**：waiter 互斥锁 / condition / host 时钟共用的 `std.Io`（单线程 threaded io）。
- **实现**：返回 `std.Io.Threaded.global_single_threaded.io()`。
- **所有权 / 错误 / 调用**：不分配；waiter 链表的锁、condition 与时间戳都要用同一个 io。

### `atomicsValidateAccess` (`src/exec/atomics_ops.zig:804`)

- **签名**：`pub fn atomicsValidateAccess( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, index_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：ValidateAtomicAccess：先取视图长度，再 ToIndex 下标，越界 RangeError。
- **实现**：`core.object.typedArrayLength` 取长度 → `toIndexForAtomics` 转下标 → `index >= length` 返回 `error.RangeError`，否则返回下标。注意长度在 ToIndex 之前取。
- **所有权 / 错误 / 调用**：`toIndexForAtomics` 会跑用户代码（valueOf/toString），其 error 与 `error.RangeError` 一起上抛。

### `atomicsValidateIndex` (`src/exec/atomics_ops.zig:819`)

- **签名**：`pub fn atomicsValidateIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void`。
- **作用**：按当前视图长度复查下标是否仍在界内。
- **实现**：重新 `core.object.typedArrayLength`，`index >= length` → `error.RangeError`。
- **所有权 / 错误 / 调用**：不分配、不碰所有权：重新读一次 view 的当前长度并比对下标。越界返回**裸** `error.RangeError` 哨兵（无 pending exception，消息由 `runtimeErrorInfo` 补）；`typedArrayLength` 自身的错误透传。4 处调用：`atomicsRevalidateIndex`（`:854`）、`atomicsNotify`（`:302`）、`atomicsWait`（`:333`）、`atomicsWaitAsync` 的最终校验（`:1189`）。

### `atomicsGetBufIndex` (`src/exec/atomics_ops.zig:831`)

- **签名**：`pub fn atomicsGetBufIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, view: *core.Object, index_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：非 waitable 的 Atomics 操作取下标：类型检查、detach 检查、ToIndex、`old_len` 越界判定与转换后的复查一条龙。
- **实现**：对照 js_atomics_get_buf（quickjs.c:60526，is_waitable == 0）：非共享且已 detached 在 ToIndex **之前**就 TypeError；`old_len` 在 ToIndex 之前取，于是下标转换的副作用把 length-tracking 视图撑大也救不回原本越界的下标（`index >= old_len` → RangeError）；最后 `atomicsRevalidateIndex` 再查一次 oob（TypeError）与新长度（RangeError）。
- **所有权 / 错误 / 调用**：下标转换可跑用户代码，因此才有前后两次长度校验；error 上抛成 TypeError / RangeError。

### `atomicsRevalidateIndex` (`src/exec/atomics_ops.zig:852`)

- **签名**：`pub fn atomicsRevalidateIndex(rt: *core.JSRuntime, view: *core.Object, index: usize) !void`。
- **作用**：用户代码跑过之后的复查：视图是否 detached/越界，下标是否还在新长度内。
- **实现**：可返回 `error.TypeError`。 关键调用：`core.object.typedArrayDetached`、`core.object.typedArrayOutOfBounds`、`atomicsValidateIndex`。 注释对照 quickjs.c:60628。
- **所有权 / 错误 / 调用**：不分配：对照 qjs 的 post-coercion re-check——detached 或 resizable 缩水导致 out-of-bounds 先返回裸 `error.TypeError`，再由 `atomicsValidateIndex` 给裸 `error.RangeError`。存在的理由就是所有权之外的时序：索引/操作数强制转换期间跑过用户代码，缓冲可能已经变了。3 处调用：`atomicsGetBufIndex`（`:845`）、`atomicsReadModifyWrite`（`:244`）、`atomicsStore`（`:280`）。

### `atomicsElementBytes` (`src/exec/atomics_ops.zig:857`)

- **签名**：`pub fn atomicsElementBytes(object: *core.Object, index: usize) ![]u8`。
- **作用**：把下标折成 backing store 上那一个元素的字节切片。
- **实现**：buffer 已 detached → TypeError；`offset = typedArrayByteOffset() + index * typedArrayElementSize()`，`offset + elementSize` 超出 `byteStorage().len` → RangeError；否则返回该元素的定长切片。
- **所有权 / 错误 / 调用**：返回的切片**借用** backing store，调用方不得持有到下一次可能 detach/resize 的操作之后；错误是 `error.TypeError`（已 detach）/ `error.RangeError`（越界）。

### `atomicsReadBits` (`src/exec/atomics_ops.zig:870`)

- **签名**：`pub fn atomicsReadBits(object: *core.Object, bytes: []const u8) u64`。
- **作用**：按元素宽度做一次 seq_cst 原子读，结果零扩展成 u64。
- **实现**：按 `object.typedArrayElementSize()` 分 1/2/4/8 字节 `@atomicLoad`（seq_cst），其他宽度返回 0。元素指针天然对齐（byteOffset 是元素宽的整数倍、底层分配至少 8 对齐）。注释对照 quickjs.c:60659。
- **所有权 / 错误 / 调用**：`bytes` 是**借用**的缓冲切片（由 `atomicsElementBytes` 现算，不持有），按元素宽度做一次 seq_cst `@atomicLoad`，不分配、无 error set；宽度不在 1/2/4/8 内返回 0。对齐是前提而非检查：typed array 的 byteOffset 是元素大小的整数倍且底层分配至少 8 字节对齐。2 处调用：`atomicsWait` 的值探测（`:335`）与 `atomicsWaitAsync` 的值探测（`:1191`）。

### `atomicsWriteBits` (`src/exec/atomics_ops.zig:882`)

- **签名**：`pub fn atomicsWriteBits(object: *core.Object, bytes: []u8, value: u64) void`。
- **作用**：按元素宽度做一次 seq_cst 原子写。
- **实现**：按 `object.typedArrayElementSize()` 分 1/2/4/8 字节 `@atomicStore`（seq_cst，窄宽度先 `@truncate`），其他宽度什么都不做。注释对照 quickjs.c:60778。
- **所有权 / 错误 / 调用**：往**借用**的元素切片做一次 seq_cst `@atomicStore`，不分配、无 error set、无返回值；宽度不匹配则什么都不做。缓冲的存活由调用方（刚做过 revalidate）保证。唯一调用方 `atomicsStore`（`src/exec/atomics_ops.zig:282`）。

### `atomicsRmwTyped` (`src/exec/atomics_ops.zig:898`)

- **签名**：`fn atomicsRmwTyped( comptime T: type, ptr: *T, atomic_op: AtomicsReadModifyOp, operand: u64, replacement: u64, ) u64`。
- **作用**：定宽度的一条原子读-改-写指令：load/add/and/or/sub/xor/exchange/compareExchange。
- **实现**：按 `atomic_op` 选 `@atomicLoad` 或 `@atomicRmw`（Add/And/Or/Sub/Xor/Xchg，全 seq_cst）；`compareExchange` 用 `@cmpxchgStrong`，成功时返回 null，故 `orelse op_bits` 把「旧值等于期望值」补回去。注释对照 quickjs.c:60637。
- **所有权 / 错误 / 调用**：无所有权：对**借用**的 `*T` 元素指针做单条原子指令（`@atomicRmw` / `@atomicLoad` / `@cmpxchgStrong`），不分配、无 error set。要点在 compareExchange 的返回约定：`@cmpxchgStrong` 成功时返回 `null`，这里 `orelse op_bits` 把它折成「旧值等于期望值」，与 qjs 成功时返回 `v1` 一致。文件私有，4 处调用全在 `atomicsReadModifyWriteBits` 的宽度分派（`:930`-`:933`）。

### `atomicsReadModifyWriteBits` (`src/exec/atomics_ops.zig:922`)

- **签名**：`pub fn atomicsReadModifyWriteBits( object: *core.Object, bytes: []u8, atomic_op: AtomicsReadModifyOp, operand: u64, replacement: u64, ) u64`。
- **作用**：按元素宽度把 RMW 分派到 `atomicsRmwTyped`，返回零扩展成 u64 的旧值。
- **实现**：按 `object.typedArrayElementSize()` 取 u8/u16/u32/u64 实例化 `atomicsRmwTyped`，其他宽度返回 0。
- **所有权 / 错误 / 调用**：无所有权：按元素宽度把**借用**切片转成对齐指针后交给 `atomicsRmwTyped`，返回零扩展到 u64 的旧值，不分配、无 error set。唯一调用方 `atomicsReadModifyWrite`（`src/exec/atomics_ops.zig:249`），它在调用前已完成 revalidate。

### `atomicsMaskBits` (`src/exec/atomics_ops.zig:938`)

- **签名**：`pub fn atomicsMaskBits(object: *core.Object, value: u64) u64`。
- **作用**：把期望值截到元素宽度，好和 `atomicsReadBits` 读回来的位比较。
- **实现**：按 `object.typedArrayElementSize()` 与 0xff / 0xffff / 0xffff_ffff，8 字节及其他情况原样返回。
- **所有权 / 错误 / 调用**：无：按元素宽度截断 u64 的纯位运算，不分配、无 error set。2 处调用：`atomicsWait`（`:336`）与 `atomicsWaitAsync`（`:1192`）的期望值比对。

### `atomicsValueFromBits` (`src/exec/atomics_ops.zig:947`)

- **签名**：`pub fn atomicsValueFromBits(rt: *core.JSRuntime, object: *core.Object, bits: u64) !core.JSValue`。
- **作用**：把元素位模式按 typed array 的 kind 装箱成 JS 值。
- **实现**：按 `object.typedArrayKind()` 分支：1/4/6 是有符号 8/16/32 位 → `int32`；2/5 是无符号 8/16 位 → `int32`；7 是 Uint32 → 走 `atomicsNumberResult`（可能是 double）；11/12 是 BigInt64/BigUint64 → `createBigIntI128`；其余 kind → `error.TypeError`。
- **所有权 / 错误 / 调用**：整数/浮点臂返回立即数，不分配；两条 BigInt 臂（typedArrayKind 11/12）经 `value_ops.createBigIntI128` 可能新建 GC BigInt（超出 short 范围时），返回值归 GC。未知 kind 返回裸 `error.TypeError`，其余错误只有 OOM。唯一调用方 `atomicsReadModifyWrite`（`src/exec/atomics_ops.zig:250`）。

### `toIndexForAtomics` (`src/exec/atomics_ops.zig:961`)

- **签名**：`pub fn toIndexForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：`Atomics.*` 的 `index` 实参专用的 ToIndex（ECMA-262 7.1.22）：把任意值折成非负整数元素下标 usize；下标是否越界由调用方 `atomicsValidateAccess` / `atomicsGetBufIndex` 另查。
- **实现**：先 `toNumberForAtomics`（可跑用户代码）：NaN → 0；非有限 → `error.RangeError`；`@trunc` 后为负 → `error.RangeError`；否则取整数部分。
- **所有权 / 错误 / 调用**：不分配。经 `toNumberForAtomics` 可能跑用户 `valueOf`/`toString`，所以两个调用方都把长度快照取在它之前：`atomicsGetBufIndex` 之后还要 `atomicsRevalidateIndex` 重查 detach/OOB，`atomicsValidateAccess` 则拿调用前捕获的 `length` 比较。`error.RangeError` 由上层 `materializeRuntimeError` 变成 JS RangeError。

### `toNumberForAtomics` (`src/exec/atomics_ops.zig:977`)

- **签名**：`pub fn toNumberForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !f64`。
- **作用**：所有 Atomics 数值参数共用的 ToNumber（ECMA-262 7.1.4）底座，外加一条 Atomics 专属规则：BigInt 原始值不接受；`Atomics.wait`/`waitAsync` 的 `timeout` 也直接用它。
- **实现**：`coercion_ops.toPrimitiveForNumber` 取原始值；是 BigInt 直接 `error.TypeError`；再 `value_ops.toNumberValue`，取不出数值时退化成 NaN。`caller_function` / `caller_frame` 未使用。
- **所有权 / 错误 / 调用**：不分配。`toPrimitiveForNumber` 会调用户的 `Symbol.toPrimitive`/`valueOf`/`toString`，因此本函数是 Atomics 路径上的可重入点。`error.TypeError` 由上层变成 JS TypeError。

### `toInt32ForAtomics` (`src/exec/atomics_ops.zig:993`)

- **签名**：`pub fn toInt32ForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !i32`。
- **作用**：ToInt32（ECMA-262 7.1.6）。本文件里只有 `atomicsIsLockFree` 用它把 `Atomics.isLockFree(size)` 的 size 折成有符号 32 位整数。
- **实现**：先 `toUint32ForAtomics`，再把低 32 位 `@bitCast` 成 i32。
- **所有权 / 错误 / 调用**：不分配；错误来自底层的 `toNumberForAtomics`（BigInt → TypeError）。

### `toInt32BitsForAtomics` (`src/exec/atomics_ops.zig:1005`)

- **签名**：`pub fn toInt32BitsForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !u64`。
- **作用**：把 `Atomics.wait` / `Atomics.waitAsync` 在非 BigInt 视图上的 `value`（期望值）折成待比较的元素位模式。
- **实现**：`toInt32ForAtomics` 之后按 u32 位模式零扩展成 u64（用于和读回来的元素位比较）。
- **所有权 / 错误 / 调用**：不分配；错误来自 `toInt32ForAtomics`。BigInt64/BigUint64 视图走的是 `toBigIntBitsForAtomics`。

### `toUint32ForAtomics` (`src/exec/atomics_ops.zig:1017`)

- **签名**：`pub fn toUint32ForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !u64`。
- **作用**：ToUint32（ECMA-262 7.1.7），给 `atomicsReadModifyWrite` 把非 BigInt 视图上的 `value` / `compareExchange` 的 `replacement` 折成要写进元素的位。
- **实现**：`toNumberForAtomics` 之后：非有限或 NaN → 0；否则 `@trunc` 再对 2^32 取模，负数加回 2^32。
- **所有权 / 错误 / 调用**：不分配；错误来自 `toNumberForAtomics`。返回 u64 只是为了和 BigInt 路径共用一个位宽。

### `toIntegerValueForAtomics` (`src/exec/atomics_ops.zig:1033`)

- **签名**：`pub fn toIntegerValueForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：ToIntegerOrInfinity 的 Atomics 版，但结果留在 JSValue 里：`Atomics.store` 用它算出要返回给 JS 的规范化数值（返回的是这个数，不是截断后写进内存的值），`atomicsNotifyCount` 用它算 `count`。
- **实现**：`toNumberForAtomics` 之后：NaN 或 0 → `int32(0)`（含 -0 归一）；非有限保留原 double；其余 `@trunc` 后交给 `atomicsNumberResult` 装箱。
- **所有权 / 错误 / 调用**：返回值是不含堆引用的数值 JSValue，无需释放。写入内存的位由 `uint32FromIntegerValueForAtomics` 从这个值再折一次。

### `uint32FromIntegerValueForAtomics` (`src/exec/atomics_ops.zig:1047`)

- **签名**：`pub fn uint32FromIntegerValueForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64`。
- **作用**：把 `toIntegerValueForAtomics` 产出的整数值折成 u32 位模式（供 `Atomics.store` 写入）。
- **实现**：取不出数值、非有限或 NaN → 0；否则 `@trunc` 后对 2^32 取模并把负数加回。`rt` 参数未使用。
- **所有权 / 错误 / 调用**：`rt` 参数未使用。只读已经是数值的 `value`（不做 ToNumber、不重入 JS），做 mod 2^32 归一；非数值/非有限一律给 0。不分配、无 error set。唯一调用方 `atomicsStore`（`src/exec/atomics_ops.zig:276`）。

### `toBigIntValueForAtomics` (`src/exec/atomics_ops.zig:1057`)

- **签名**：`pub fn toBigIntValueForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：ToBigInt（ECMA-262 7.1.13）：`Atomics.store` 在 BigInt64/BigUint64 视图上用它把写入值转成 BigInt，并以这个 BigInt 作为 store 的返回值。
- **实现**：先 `coercion_ops.toPrimitiveForNumber` 取原始值（可跑用户代码），再 `value_ops.toBigIntValue` 解析成临时 BigInt（`defer big.deinit()`），最后 `createBigIntValue` 装成 JSValue。`caller_function` / `caller_frame` 未使用。
- **所有权 / 错误 / 调用**：中间 BigInt 由本函数 `defer deinit` 释放；返回的 JSValue 归调用方。非 BigInt 可转值（如 Number）在 `toBigIntValue` 里变成 `error.TypeError`，上层转成 JS TypeError。

### `toBigIntBitsForAtomics` (`src/exec/atomics_ops.zig:1073`)

- **签名**：`pub fn toBigIntBitsForAtomics( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !u64`。
- **作用**：BigInt64/BigUint64 视图上的写入值/期望值转成 64 位元素位模式，供 RMW、`compareExchange` 的 replacement 与 `wait`/`waitAsync` 的比较使用。
- **实现**：先 `toBigIntValueForAtomics` 得到 BigInt 值，再交给 `bigintBitsForAtomics` 取低 64 位（模 2^64 回绕）。
- **所有权 / 错误 / 调用**：中间 BigInt 值不含需调用方释放的资源；错误来自转换本身（非 BigInt 输入 → TypeError）。

### `atomicsNumberResult` (`src/exec/atomics_ops.zig:1085`)

- **签名**：`pub fn atomicsNumberResult(value: f64) core.JSValue`。
- **作用**：把 f64 结果装箱：能用 int32 表示就用 int32，否则 double。
- **实现**：有限、`@floor(value) == value`、落在 i32 范围内且不是 -0 才走 `int32`；其余 `float64`（所以 -0 保持 double）。
- **所有权 / 错误 / 调用**：无：按 int32 可表示性选 tag（排除 -0），返回立即数，不分配、无 error set。2 处调用：`atomicsValueFromBits` 的 uint32 臂（`:954`）与 `toIntegerValueForAtomics` 的收尾（`:1044`）。

### `bigintBitsForAtomics` (`src/exec/atomics_ops.zig:1092`)

- **签名**：`pub fn bigintBitsForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64`。
- **作用**：取 BigInt 的低 64 位位模式（BigInt64/BigUint64 元素用）。
- **实现**：`value_ops.toBigIntValue` 之后拼低两个 32 位 limb（`limbs[0] | limbs[1] << 32`），负数取二补 `0 -% low`；临时 BigInt 由 `defer big.deinit()` 释放。
- **所有权 / 错误 / 调用**：`value_ops.toBigIntValue` 返回 owned `bignum.BigInt`，由这里 `defer big.deinit()` 释放——这是本文件里少数真有堆临时量的地方；返回的是低 64 位（负数取补），不产生 JS 值。错误是 `toBigIntValue` 的透传（非 BigInt 的裸 `error.TypeError`、`error.SyntaxError`、OOM）。2 处调用：`atomicsStore`（`:274`）与 `toBigIntBitsForAtomics`（`:1082`）。

### `atomicsDestroyAsyncWaiter` (`src/exec/atomics_ops.zig:1101`)

- **签名**：`pub fn atomicsDestroyAsyncWaiter(waiter: *AtomicsWaiter) void`。
- **作用**：销毁一个已摘链的 waitAsync 节点。
- **实现**：从 `waiter.realm` 借出 ctx 后 `assertOwnerThread`，`atomicsReleaseWaiterKey` 放掉 store 引用，`waiter.realm.deinit()` 放掉 RealmRef，最后 `rt.memory.destroy`。
- **所有权 / 错误 / 调用**：节点内存与两份引用在这里归还；必须先从链表摘下。调用方：`cleanupAtomicsWaitersForContext`、`atomicsWaitAsync` 的 errdefer、job 的销毁回调。

### `atomicsDestroyAsyncWaiterOpaque` (`src/exec/atomics_ops.zig:1110`)

- **签名**：`pub fn atomicsDestroyAsyncWaiterOpaque(raw_waiter: *anyopaque) void`。
- **作用**：`atomicsDestroyAsyncWaiter` 的 type-erased 版本，作为 typed job 的销毁回调注册。
- **实现**：`@ptrCast(@alignCast(raw_waiter))` 还原成 `*AtomicsWaiter` 后转调。
- **所有权 / 错误 / 调用**：**销毁**传入的 waiter（含它的 store 引用、RealmRef 与节点内存）；只作为 typed job 的销毁回调注册，节点必须已从链表摘下。

### `atomicsRunAsyncWaiterCompletion` (`src/exec/atomics_ops.zig:1120`)

- **签名**：`pub fn atomicsRunAsyncWaiterCompletion( ctx: *core.JSContext, payload: *const jobs_mod.AtomicsWaiterPayload, ) core.errors.RuntimeError!void`。
- **作用**：owner 线程跑一条 waitAsync 完成：在发布 Promise 之前的失败会把 FIFO 槽留着，成功才用 follow-up Promise job 吃掉预约。
- **实现**：断言 realm/owner。已 settled 则 release 槽返回。按 completion 造 "ok"/"timed-out" 字符串，准备 Promise job。若已有 reaction callback 则不预写 result（留给 settlePendingPromiseReaction，字符串改从 reaction arg 槽传进去；函数里那条说要 free 它的 rc 时代注释已改实），否则写 result 且非 rejected。最后 `enqueueUnlinkedEntrySlot`。
- **所有权 / 错误 / 调用**：调用方：`drainOnePendingJob`。字符串分配失败在发布前，槽不丢。

### `atomicsWaitAsync` (`src/exec/atomics_ops.zig:1169`)

- **签名**：`pub fn atomicsWaitAsync( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：Atomics.waitAsync：校验 SharedArrayBuffer 视图后，或立即返回 not-equal/timed-out，或挂一个 Promise 等待者。
- **实现**：校验 waitable typed array 且 backing 是 SharedArrayBuffer。ToIndex / expected / timeout 之后再 `atomicsValidateIndex`。当前值 ≠ expected → `{async:false,value:"not-equal"}`；timeout≤0 且非 NaN → timed-out。否则 `constructWithPrototype` 造 Promise，标 `promiseAtomicsWaitAsync`，create waiter（retain key、RealmRef、deadline），先 `atomicsWaitAsyncResult(true, promise)` 再 `atomicsLinkAsyncWaiter`——所有可失败分配必须在链入跨 Runtime 链表之前完成。
- **所有权 / 错误 / 调用**：Promise/RealmRef 只在 owner 线程创建。errdefer 在未链接时 `atomicsDestroyAsyncWaiter`。

### `atomicsLinkAsyncWaiter` (`src/exec/atomics_ops.zig:1231`)

- **签名**：`pub fn atomicsLinkAsyncWaiter(waiter: *AtomicsWaiter) void`。
- **作用**：在 owner 线程把 waitAsync 节点链进全局 waiter 链表。
- **实现**：从节点的 RealmRef 借出 ctx 并 `assertOwnerThread`；开了 `value_root_frames_enabled` 就先 `installWaitAsyncRootAdapter` 把 GC 根回调装好；再持 `atomics_waiter_mutex` 调 `atomicsLinkWaiter`。
- **所有权 / 错误 / 调用**：跨线程调用在 owner 边界拒绝。

### `installWaitAsyncRootAdapter` (`src/exec/atomics_ops.zig:1241`)

- **签名**：`fn installWaitAsyncRootAdapter() void`。
- **作用**：一次性把 `trace_atomics_wait_async` 接到 `traceWaitAsyncRoots`，让 GC 能扫 waitAsync Promise。
- **实现**：`value_root_frames_enabled` 时若回调仍空则赋值。只安装一次。
- **所有权 / 错误 / 调用**：写的是进程级的 `core.runtime.trace_atomics_wait_async` 钩子；幂等，不分配。

### `traceWaitAsyncRoots` (`src/exec/atomics_ops.zig:1247`)

- **签名**：`fn traceWaitAsyncRoots(rt_opaque: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：GC 根回调：全局 waiter 链表是 native 内存，GC 扫不到，本函数把链上属于该 runtime 的 waitAsync 节点所持的 realm（`JSContext` header）与 Promise 值报告给 `RootVisitor`。
- **实现**：两趟：先持锁数出本 rt 的带 promise 节点数；为 0 直接返回；超过 16 个才 `rt.memory.alloc` 临时数组，否则用栈上 `[16]JSValue`。第二趟持锁收集：遇到活的 realm 先解锁再 `visitor.constHeader(&ctx.header)`（避免持锁回调 GC）然后重新加锁，promise 收进缓冲；出锁后统一 `visitor.value`。
- **所有权 / 错误 / 调用**：作为 `core.runtime.trace_atomics_wait_async` 回调被 GC 调用；error 是 `RootTraceError`（临时数组 OOM），不会变成 JS 异常。临时数组由本函数 `defer free`。

### `atomicsWaitAsyncResult` (`src/exec/atomics_ops.zig:1290`)

- **签名**：`pub fn atomicsWaitAsyncResult(ctx: *core.JSContext, is_async: bool, value: core.JSValue) !core.JSValue`。
- **作用**：造 `{ async, value }` 结果对象（规范 WaiterList 的同步/异步包装）。
- **实现**：关键调用：`core.Object.create`、`defineValueProperty`。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：显式建根：`core.runtime.rootValues(.{&rooted_value})` 把 payload 钉住，避免 `Object.create` / `defineValueProperty` 触发 GC 时被回收（同文件单测专门验证这点）；新对象另有 `errdefer core.Object.destroyFromHeader` 做失败清理。两个属性值交给属性槽持有，返回的结果对象归 GC。错误是分配与属性定义的透传。4 处调用：`atomicsWaitAsync` 的三个出口（`:1194` not-equal、`:1198` timed-out、`:1225` 异步 Promise）与本文件的单测（`:1323`）。

### `atomicsWaitAsyncPromise` (`src/exec/atomics_ops.zig:1337`)

- **签名**：`pub fn atomicsWaitAsyncPromise(rt: *core.JSRuntime, promise: *core.Object) bool`。
- **作用**：该 Promise 是否由 `Atomics.waitAsync` 创建（读 `promiseAtomicsWaitAsync` 槽）。
- **实现**：`return promise.promiseAtomicsWaitAsync();`，`rt` 参数未使用。
- **所有权 / 错误 / 调用**：`rt` 参数未使用。只读 promise 对象上的 `promiseAtomicsWaitAsync` 标志位（判断这个 Promise 是不是 waitAsync 建的），不分配、无 error set、不改变所有权。4 处调用，全在 `src/exec/promise_ops.zig`（`:3631`、`:3751`、`:3918` 等）。


## `src/exec/atomics_wait.zig` — 方法枚举与 isLockFree

`StaticMethod` 是 Atomics 命名空间的 id 枚举（add=1 … xor=14）。`atomics_ops.atomicsCallForNativeRecord` 按它分支。`isLockFree` 对 1/2/4/8 字节返回 true。


## `src/exec/buffer_ops.zig` — ArrayBuffer / DataView / TypedArray 记录

存储机制在 `core/typed_array.zig`。本文件：`.buffer` 记录表、名字↔id、Uint8Array codec 记录（options getter 可跑用户代码）、以及大量 core 原语的再导出。`ArrayBuffer(n)` 作函数没有 construct cproto，落入 `bufferCall` 的 TypeError；`new ArrayBuffer` 在更上游被 construct 路径截获。


### `uint8ArrayStaticMethodId` (`src/exec/buffer_ops.zig:39`)

- **签名**：`pub fn uint8ArrayStaticMethodId(name: []const u8) ?u32`。
- **作用**：把 `Uint8Array` 的两个静态 codec 方法名 `fromBase64` / `fromHex` 映成 `Uint8ArrayStaticMethod` 的记录 id。
- **实现**：两条 `std.mem.eql`，命中返回 `@intFromEnum(.from_base64)` 或 `.from_hex`，否则 null。
- **所有权 / 错误 / 调用**：不分配。调用点 `standard_globals.zig:434` 的 `.uint8_array_static` 分支，comptime 建表，返回 null 即 `@compileError`。

### `uint8ArrayPrototypeMethodId` (`src/exec/buffer_ops.zig:45`)

- **签名**：`pub fn uint8ArrayPrototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `Uint8Array.prototype` 上四个 codec 方法名 `toBase64` / `toHex` / `setFromBase64` / `setFromHex` 映成 `Uint8ArrayPrototypeMethod` 的记录 id。
- **实现**：四条 `std.mem.eql` 顺序比较，命中即 `@intFromEnum`，否则 null。
- **所有权 / 错误 / 调用**：不分配。调用点 `standard_globals.zig:435` 的 `.uint8_array_prototype` 分支，comptime 建表。

### `staticMethodId` (`src/exec/buffer_ops.zig:67`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：`.buffer` domain 的构造器静态方法名映射，目前表里只有 `ArrayBuffer.isView` 一项。
- **实现**：单条 `std.mem.eql(name, "isView")` → `@intFromEnum(StaticMethod.is_view)`，否则 null。
- **所有权 / 错误 / 调用**：不分配。调用点 `standard_globals.zig:433` 的 `.array_buffer_static` 分支。

### `arrayBufferPrototypeMethodId` (`src/exec/buffer_ops.zig:72`)

- **签名**：`pub fn arrayBufferPrototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `ArrayBuffer.prototype` 的六个方法名（`slice`、`resize`、`transfer`、`transferToFixedLength`、`sliceToImmutable`、`transferToImmutable`）映成 `ArrayBufferPrototypeMethod` 记录 id。
- **实现**：六条 `std.mem.eql` 顺序比较，命中即 `@intFromEnum`，否则 null；注意这里不含访问器（`byteLength`/`detached`/… 走 `arrayBufferAccessorMethodId`）。
- **所有权 / 错误 / 调用**：不分配。调用点 `standard_globals.zig:431` 的 `.buffer_prototype` 分支。

### `sharedArrayBufferPrototypeMethodId` (`src/exec/buffer_ops.zig:82`)

- **签名**：`pub fn sharedArrayBufferPrototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `SharedArrayBuffer.prototype` 仅有的两个方法名 `slice` / `grow` 映成 `SharedArrayBufferPrototypeMethod` 记录 id（与 `ArrayBuffer` 的同名 `slice` 是不同 id）。
- **实现**：两条 `std.mem.eql`，命中即 `@intFromEnum`，否则 null。
- **所有权 / 错误 / 调用**：不分配。调用点 `standard_globals.zig:432` 的 `.shared_buffer_prototype` 分支。

### `dataViewPrototypeMethodId` (`src/exec/buffer_ops.zig:88`)

- **签名**：`pub fn dataViewPrototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `DataView.prototype.getXxx` / `setXxx` 的名字映成对应的 get 或 set 记录 id，两族共用一个查询入口。
- **实现**：依次试 `dataViewGetMethodId`、`dataViewSetMethodId`，都不中返回 null。
- **所有权 / 错误 / 调用**：不分配；两个被调用的映射表在 core（`builtin_method_id_lookup.buffer`）。调用点 `standard_globals.zig:436` 的 `.data_view_prototype` 分支。

### `bufferEntry` (`src/exec/buffer_ops.zig:200`)

- **签名**：`fn bufferEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，为 `.buffer` domain 的非 codec 记录（ArrayBuffer/SharedArrayBuffer 原型方法、四族 byteLength/byteOffset/buffer 等访问器、以及两个构造器名）各生成一行 `InternalEntry`。
- **实现**：`.id` 与 `.magic` 都取传入的 id，`cproto` 固定 `.generic_magic`，`native_function` 是 `genericMagicFunction(&bufferCall)`。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项，无运行期分配。调用者是同文件的 `internal_entries` 表。

### `bufferCall` (`src/exec/buffer_ops.zig:216`)

- **签名**：`fn bufferCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.buffer` domain 除 codec 外全部记录共用的 native 函数体：把记录 id 交给 `builtin_glue.bufferNativeRecord` 执行，无对应实现就报 TypeError——`ArrayBuffer(8)` 这种把构造器当普通函数调用正是走这条路。
- **实现**：先 `nativeCall` 恢复 `NativeCall`，失败 `error.TypeError`；再把 `magic`（即 domain 内 id）、this、args 交给 `builtin_glue.bufferNativeRecord`，它返回 null（例如 ArrayBuffer 构造器记录被当普通函数调用）时也是 `error.TypeError`。
- **所有权 / 错误 / 调用**：this/args 借用，返回值归 GC。与同域其它 handler 不同，它**不**解析 `callableRealm`：直接把 `host_call.magic` 交给 `builtin_glue.bufferNativeRecord`。两处**裸** `error.TypeError`（无 pending exception）：`nativeCall` 认不出调用形态，以及 glue 返回 `null`（例如把 ArrayBuffer 构造器记录当普通函数调用）。没有直接调用方：经 `bufferEntry(...)` 的 `genericMagicFunction(&bufferCall)`（`src/exec/buffer_ops.zig:207`）由 `.buffer` 记录表分发。

### `codecEntry` (`src/exec/buffer_ops.zig:227`)

- **签名**：`fn codecEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：comptime 帮手，为六个 Uint8Array base64/hex codec 记录生成 `InternalEntry`；与 `bufferEntry` 的唯一差别是挂另一个 handler，因为 codec 要读会跑用户 getter 的 options 对象。
- **实现**：同 `bufferEntry`，但 `native_function` 挂的是 `genericMagicFunction(&uint8ArrayCodecCall)`。
- **所有权 / 错误 / 调用**：只在 comptime 求值，产物是静态表项，无运行期分配。

### `uint8ArrayCodecCall` (`src/exec/buffer_ops.zig:245`)

- **签名**：`fn uint8ArrayCodecCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Uint8Array.fromBase64/fromHex` 与 `Uint8Array.prototype.toBase64/toHex/setFromBase64/setFromHex` 六个记录共用的 native 函数体：把 magic 还原成方法名字符串后交给 `array_ops.uint8ArrayCodecCall`。
- **实现**：`nativeCall` 恢复 `NativeCall`（失败 → TypeError），`callableRealm` 取 realm，再用 `switch (host_call.magic)` 把六个 id 翻回常量名字符串（未知 id → TypeError），最后带 realm、`output`、this、名字、args 和调用方 bytecode/frame 调 `array_ops.uint8ArrayCodecCall`——传 writer 与 caller frame 是因为 `check_options_object`（quickjs.c:59376）及 `alphabet` / `lastChunkHandling` / `omitPadding` 的读取会跑用户 getter。
- **所有权 / 错误 / 调用**：this/args 借用，返回新建的 Uint8Array/字符串/结果对象（GC）。与 `bufferCall` 的差别正是它需要 realm 与 writer/caller-frame：`check_options_object` 与 `alphabet`/`lastChunkHandling`/`omitPadding` 的读取会跑用户 getter，因而会重入 JS，异常可能已挂 `ctx`。magic 不在六个 codec 之内、或 `array_ops.uint8ArrayCodecCall` 返回 `null` 时是裸 `error.TypeError`。没有直接调用方：经 `codecEntry(...)` 的 `genericMagicFunction(&uint8ArrayCodecCall)`（`src/exec/buffer_ops.zig:234`）分发。

## `src/exec/typed_array_construct.zig` — 读 maxByteLength 的构造参数

`Get(options, "maxByteLength")` 可观察、可进用户代码，所以放在 exec 而不是 core。`bufferConstructArgs` 把 ArrayBuffer/SharedArrayBuffer 两条 98% 相同的路径收成一处。


### `arrayBufferConstructArgs` (`src/exec/typed_array_construct.zig:19`)

- **签名**：`pub fn arrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：`ArrayBuffer(len, options)` 的构造参数走法（`shared = false`）。
- **实现**：`bufferConstructArgs(rt, args, prototype, false)` 的薄包装。
- **所有权 / 错误 / 调用**：薄转发到 `bufferConstructArgs(..., shared = false)`，自身不分配；结果 ArrayBuffer 由 `createArrayBufferWithPrototype` 新建，归 GC，`prototype` 是借用。错误全部来自被转发方：`toIndexUsize` 的裸 `error.RangeError`、`maxByteLength < byteLength` 的裸 `error.RangeError`、`options.getProperty` 的透传、OOM。2 处调用：`src/exec/construct.zig:168` 与 `src/exec/buffer_ops.zig:311` 的 re-export。

### `sharedArrayBufferConstructArgs` (`src/exec/typed_array_construct.zig:23`)

- **签名**：`pub fn sharedArrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：`SharedArrayBuffer(len, options)` 的构造参数走法（`shared = true`）。
- **实现**：`bufferConstructArgs(rt, args, prototype, true)` 的薄包装。
- **所有权 / 错误 / 调用**：同上，只是 `shared = true`，最终落到 `sharedArrayBufferConstructLength`（结果带跨线程共享的 `SharedBufferStore`，其引用计数由 core 侧管理，本层不 retain）。自身不分配，错误同为被转发方的裸哨兵。2 处调用：`src/exec/construct.zig:171` 与 `src/exec/buffer_ops.zig:312` 的 re-export。

### `bufferConstructArgs` (`src/exec/typed_array_construct.zig:31`)

- **签名**：`noinline fn bufferConstructArgs( rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object, shared: bool, ) !core.JSValue`。
- **作用**：ArrayBuffer / SharedArrayBuffer 共用构造参数走法：ToIndex 长度，可选 `Get(options, "maxByteLength")`，再调对应 core 构造器。
- **实现**：无参则 byteLength=0，否则 `typed_array_core.toIndexUsize(args[0])`。第二参是对象且非 undefined：`expectObject`，读 `atom.ids.maxByteLength`；非 undefined 再 ToIndex，`max < byteLength` → `RangeError`。`shared` 走 `sharedArrayBufferConstructLength`，否则 `createArrayBufferWithPrototype`。outlined leftover：两份 505B、98.6% 相同的拷贝；不折 `createArrayBufferWithPrototype` / `sharedArrayBufferConstructLength` 本身。`Get` 可观察、可进用户代码，所以放在 exec 而不是 core。
- **所有权 / 错误 / 调用**：返回的 buffer 对象由调用方拥有。`arrayBufferConstructArgs` / `sharedArrayBufferConstructArgs` 是 pub 包装。RangeError / TypeError 上抛。

## 覆盖核对

- 清单函数数: 73（`src/exec/atomics_ops.zig` 60 + `src/exec/buffer_ops.zig` 10 + `src/exec/typed_array_construct.zig` 3）
- 本文标题覆盖: 73
- 未覆盖: 无
