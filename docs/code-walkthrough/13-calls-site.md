# 13 — CallSite 与常驻 HostInvocation

`call_site.zig` 把三条旧入口合成一个解析产物：嵌入者 `JSContext.callFunction`、内建回调 `SyncInternalCallSite`、权威根路径 `callValueOrBytecodeRoot`。`host_invocation.zig` 是每个 Runtime 一个常驻 Machine，给「C 栈上没有活动 invocation」的宿主→JS 用。设计对应 `docs/perf/native-boundary-design.md` §6。

## 类型

### `BytecodeRoute`（`call_site.zig:39`）

- `invocation`：解析时活动的 `ActiveInvocation`，同 Machine 臂用指针比较。
- `target`：`InlineTarget`（receiver / callable / captures / FB），Realm 内任意 Machine 可用。
- `simple`：`nativeBoundarySimpleEligible`，拷参序言是否合法。
- `host_eligible`：站点 `global` 就是 `ctx` 自己的 Realm 全局，空闲时可跑常驻 host Machine。
- `host` / `host_epoch`：上次进入的 `HostInvocation` 与 `retarget_epoch`；epoch 命中则省掉 `acquire` 的三字段再证明。

### `Route`（`call_site.zig:64`）

`bytecode` 或 `generic`。generic 覆盖 bound / proxy / native / generator / 跨 Realm。

### `CallSite`（`call_site.zig:69`）

字段：`ctx` / `output` / `global` / `this_value` / `callee` / `caller_function` / `caller_frame` / `route` / 延迟初始化的 `lean` 帧 / `pins`。宿主站点 pin callee 与 receiver；引擎内部站点不 pin（操作数窗口或算法已根住）。

### `HostInvocation`（`host_invocation.zig:41`）

常驻 idle 帧 + 空栈 + `Machine` + backtrace view。`published` 仅在一次 call 期间为真。`one_shot_target` 缓存 `callOnceInto` 的上次 callee。`one_shot_pin` 防止地址复用。

---

## `call_site.zig`

### `CallSite.init` (`src/exec/call_site.zig:96`)

- **签名**：`pub fn init( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: JSValue, callee: JSValue, ) !CallSite`。
- **作用**：宿主侧构造：pin callee/receiver，解析路由一次。
- **实现**：`initInternal` 填字段后 `JSValueHandle.init` pin 两个值；pin `this_value` 失败时 `errdefer` 释放已拿到的 callee pin。`deinit` 必须成对调用。
- **所有权 / 错误 / 调用**：pin 走 runtime persistent ledger（`createPersistentRootSlot`）。OOM 时返回分配错误。唯一调用方是 binding 门面 `src/binding/context.zig:892`（`zjs.CallSite.init`）——嵌入者要复用的长寿命站点；`JSContext.callFunction` 不走这里，它走 `callOnceInto`。

### `CallSite.initInternal` (`src/exec/call_site.zig:114`)

- **签名**：`pub inline fn initInternal( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: JSValue, callee: JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) CallSite`。
- **作用**：引擎内部构造，不 pin。
- **实现**：直接聚合字面量；`route = resolveRoute(...)`；`lean` 留 `undefined`，`lean_state = .unknown`。`caller_function`/`caller_frame` 只给 generic 回退的 backtrace。
- **所有权 / 错误 / 调用**：callee/this 由调用方在站点寿命内根住。内建 forEach/sort/JSON reviver 走这里。

### `CallSite.leanFrame` (`src/exec/call_site.zig:137`)

- **签名**：`inline fn leanFrame(self: *CallSite, route: *const BytecodeRoute) ?*inline_calls.LeanFrame`。
- **作用**：按 `lean_state` 取预建 lean 帧，避免每次从 `initInternal` 拷 300 字节。
- **实现**：`.ready` 且 `isIntact()` 返回 `&self.lean`；损坏则 `leanFrameInit`。`.none` 返回 null。`.unknown` 首次初始化。
- **所有权 / 错误 / 调用**：无分配错误。被 `callInto` / `callWithThisInto` 使用。

### `CallSite.leanFrameInit` (`src/exec/call_site.zig:145`)

- **签名**：`noinline fn leanFrameInit(self: *CallSite, route: *const BytecodeRoute) ?*inline_calls.LeanFrame`。
- **作用**：冷路径：就地 `LeanFrame.initInPlace`。
- **实现**：成功则 `lean_state = .ready`；失败 `.none`。outline 避免热循环吸收 spill。
- **所有权 / 错误 / 调用**：形状不合格（arity/captures）返回 null，改走通用 push。

### `CallSite.deinit` (`src/exec/call_site.zig:154`)

- **签名**：`pub fn deinit(self: *CallSite) void`。
- **作用**：释放 pin，把路由打回 generic。
- **实现**：`pins.this_value` / `pins.callee` `deinit`；`route = .generic`。内部站点的空 handle 是 no-op。
- **所有权 / 错误 / 调用**：不释放 lean 帧存储（它嵌在站点里）。调用方负责。

### `CallSite.callInto` (`src/exec/call_site.zig:170`)

- **签名**：`pub noinline fn callInto(self: *CallSite, args: []const JSValue, out: *JSValue) HostError!void`。
- **作用**：站点主入口：结果经 `out` 两字写出，不物化 24 字节 error union。
- **实现**：`pollInterrupt`；bytecode 臂调 `enterBytecode`；generic 调 `callGeneric`。outline 让算法循环不吸收 call 的 spill。
- **所有权 / 错误 / 调用**：`args` 借用。异常走 `HostError`。`call` / `callFixedInto` 包它。

### `CallSite.call` (`src/exec/call_site.zig:179`)

- **签名**：`pub inline fn call(self: *CallSite, args: []const JSValue) HostError!JSValue`。
- **作用**：按值返回的便利包装。
- **实现**：栈上 `out`，`callInto`，`pinnedLoad`。
- **所有权 / 错误 / 调用**：返回值所有权与 `callInto` 相同。

### `CallSite.call0` (`src/exec/call_site.zig:190`)

- **签名**：`pub inline fn call0(self: *CallSite) HostError!JSValue`。
- **作用**：0 参固定元数调用。
- **实现**：`callFixed(0, &.{})`。
- **所有权 / 错误 / 调用**：不分配（空窗口 `&.{}`）；error set 是 `HostError`，来自 `callInto` 里的 `pollInterrupt` 与被调方，异常本身留在 `ctx` 上。树内无调用方：这是给嵌入者的 pub 形态，`src/binding/context.zig:906` 的同名门面走自己的 `callFixed`→`callFixedInto`。

### `CallSite.call1` (`src/exec/call_site.zig:194`)

- **签名**：`pub inline fn call1(self: *CallSite, a0: JSValue) HostError!JSValue`。
- **作用**：1 参；参数用 pinned store 写入窗口。
- **实现**：`[1]JSValue` + `pinnedStore` + `callFixed(1, &args)`。避免 LLVM 经 q 寄存器拼窗口。
- **所有权 / 错误 / 调用**：`a0` 按值；窗口栈上。

### `CallSite.call2` (`src/exec/call_site.zig:200`)

- **签名**：`pub inline fn call2(self: *CallSite, a0: JSValue, a1: JSValue) HostError!JSValue`。
- **作用**：2 参固定元数。
- **实现**：与 `call1` 相同，两个 `pinnedStore`。
- **所有权 / 错误 / 调用**：`args` 是本函数栈上的临时窗口，被调方按借用读；两个实参不 retain、不建根，存活由调用方保证。error set `HostError` 原样上抛。调用方 `src/exec/array_ops.zig:3767`、`4451`、`4544`（map/其它回调迭代）与 `4998`（sort comparator）。

### `CallSite.call3` (`src/exec/call_site.zig:207`)

- **签名**：`pub inline fn call3(self: *CallSite, a0: JSValue, a1: JSValue, a2: JSValue) HostError!JSValue`。
- **作用**：3 参固定元数。
- **实现**：三个 pinned store。
- **所有权 / 错误 / 调用**：栈上三槽窗口，借用语义同 `call2`；不分配、不建根。调用方 `src/exec/array_ops.zig:1550`、`1635`、`1664` 等 4 处（`(item, index, receiver)` 形状的数组回调）。

### `CallSite.call4` (`src/exec/call_site.zig:215`)

- **签名**：`pub inline fn call4(self: *CallSite, a0: JSValue, a1: JSValue, a2: JSValue, a3: JSValue) HostError!JSValue`。
- **作用**：4 参固定元数。
- **实现**：四个 pinned store。
- **所有权 / 错误 / 调用**：栈上四槽窗口，借用语义同 `call2`。调用方只有 `Array.prototype.reduce`/`reduceRight` 两处（`src/exec/array_ops.zig:1793`、`1836`），accumulator 由那两处的循环自己保活。

### `CallSite.callFixed` (`src/exec/call_site.zig:228`)

- **签名**：`pub inline fn callFixed(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue) HostError!JSValue`。
- **作用**：`call0..call4` 的共享返回包装。
- **实现**：`callFixedInto` + `pinnedLoad`。不把 comptime argc 穿进 `enterBytecode`，避免每个 leftover arity 一份 ~6 KiB 拷贝。
- **所有权 / 错误 / 调用**：不分配；`args` 指向调用方栈上的固定数组，只在调用期间借用。error set `HostError` 由 `callFixedInto` 透传。调用方仅本文件的 `call0`..`call4`（`call_site.zig:190`-`224`）。

### `CallSite.callFixedInto` (`src/exec/call_site.zig:234`)

- **签名**：`pub inline fn callFixedInto(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue, out: *JSValue) HostError!void`。
- **作用**：固定元数写入 `out`。
- **实现**：转 `callInto(args, out)`。
- **所有权 / 错误 / 调用**：纯转发，不分配、不改站点状态；结果经 `out` 出参回传（见 `callInto` 的两字宽度纪律）。调用方：本文件 `callFixed`，以及 binding 门面 `src/binding/context.zig:925`——OOM 在那里被 `restoreUncaughtOutOfMemory` 收成嵌入层错误。

### `CallSite.callWithThisInto` (`src/exec/call_site.zig:244`)

- **签名**：`pub noinline fn callWithThisInto(self: *CallSite, this_value: JSValue, args: []const JSValue, out: *JSValue) HostError!void`。
- **作用**：复用已解析 callable，换本次 `this`（JSON reviver 每步换 holder）。
- **实现**：poll 后拷一份 `route.target` 到栈上改 `this_value`，不改站点模板。generic 走 `callGeneric`。
- **所有权 / 错误 / 调用**：`this_value` 由调用方根住至返回。

### `CallSite.callWithThis` (`src/exec/call_site.zig:257`)

- **签名**：`pub inline fn callWithThis(self: *CallSite, this_value: JSValue, args: []const JSValue) HostError!JSValue`。
- **作用**：`callWithThisInto` 的按值包装。
- **实现**：`pinnedLoad`。
- **所有权 / 错误 / 调用**：按值包装，不分配；`this_value` 与 `args` 都要由调用方根住到返回（见 `callWithThisInto`）。调用方是 JSON 的 reviver/replacer 遍历 `src/exec/json_ops.zig:1780`、`2356`，那里的 holder 已经过 `rooted_holder_value` 显式建根；另有 binding 门面 `src/binding/context.zig:931` 走 `callWithThisInto`。

### `pinnedLoad` (`src/exec/call_site.zig:267`)

- **签名**：`pub inline fn pinnedLoad(slot: *const JSValue) JSValue`。
- **作用**：用整数对加载 16 字节槽（AArch64 `ldp`）。
- **实现**：aarch64 内联汇编；其它架构 `JSValue.loadSlotAsIntPair`。宽度纪律与 `Vm.takeNativeReturnInto` 一致，保证 store-to-load forwarding。
- **所有权 / 错误 / 调用**：纯位拷贝。

### `pinnedStore` (`src/exec/call_site.zig:283`)

- **签名**：`pub inline fn pinnedStore(slot: *JSValue, value: JSValue) void`。
- **作用**：`pinnedLoad` 的孪生 store（`stp`）。
- **实现**：aarch64 `stp`；否则 `storeSlotAsIntPair`。
- **所有权 / 错误 / 调用**：只写调用方给的槽位，不分配、不抛、不做屏障（窗口是栈上临时数组，不是堆槽）。调用方：本文件 `call1`..`call4` 的窗口构造与 `callGeneric` 的结果写出（`call_site.zig:411`），以及 binding 门面 `src/binding/context.zig:912`/`918`/`919`。

### `callOnceInto` (`src/exec/call_site.zig:302`)

- **签名**：`pub inline fn callOnceInto( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: JSValue, callee: JSValue, args: []const JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, out: *JSValue, ) HostError!void`。
- **作用**：一次性 `initInternal`+`callInto`，不物化站点（给 `JSContext.callFunction`）。
- **实现**：poll。若有活动 invocation：解析 inline，Machine 匹配则 `runOnInvocation`。否则若 `hostEligible`：`HostInvocation.acquire` + `oneShotRoute` 缓存命中则 publish/跑/unpublish。否则 `callGeneric`。嵌套宿主→JS 禁止改写空闲 Machine 的 one-shot 缓存。
- **所有权 / 错误 / 调用**：不 pin。one-shot 缓存靠 `one_shot_pin` 保 callee 身份。

### `hostEligible` (`src/exec/call_site.zig:346`)

- **签名**：`inline fn hostEligible(ctx: *core.JSContext, global: *core.Object) bool`。
- **作用**：常驻 host Machine 只跑调用者自己的 Realm。
- **实现**：`ctx.global == global`；无全局则 false。根路径会切到 callee Realm，所以跨 Realm 不能走 host。
- **所有权 / 错误 / 调用**：`resolveRoute` 与 `callOnceInto` 共用。

### `enterBytecode` (`src/exec/call_site.zig:354`)

- **签名**：`inline fn enterBytecode( comptime fixed_argc: ?usize, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, route: *BytecodeRoute, target: *const inline_calls.InlineTarget, this_value: *const JSValue, callee: *const JSValue, args: []const JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, lean: ?*inline_calls.LeanFrame, out: *JSValue, ) HostError!void`。
- **作用**：bytecode 臂选 Machine。
- **实现**：活动 invocation 等于 `route.invocation` 或 `machineMatches` → `runOnInvocation`；否则 `host_eligible` → `runOnHostInvocation`；否则 `callGeneric`。`this_value`/`callee` 用指针，避免每次 32 字节 q 临时量。
- **所有权 / 错误 / 调用**：`callInto` / `callWithThisInto`。

### `machineMatches` (`src/exec/call_site.zig:382`)

- **签名**：`inline fn machineMatches(machine: *const inline_calls.Machine, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) bool`。
- **作用**：执行权威三元组比较。
- **实现**：指针相等 `ctx`/`global`/`output`。
- **所有权 / 错误 / 调用**：纯指针比较，不分配、不抛。调用方只有本文件两处：`call_site.zig:320`（`callOnceInto` 的嵌套宿主→JS 臂）与 `373`（`enterBytecode` 进入前复核活动 invocation）。`resolveRoute` 在 `499` 把同样三个比较写开，没有走这个 helper。

### `callGeneric` (`src/exec/call_site.zig:389`)

- **签名**：`fn callGeneric( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: JSValue, callee: JSValue, args: []const JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, out: *JSValue, ) HostError!void`。
- **作用**：JS_Call 形根路径：在 callee Realm 开新执行根。
- **实现**：`callValueOrBytecodeDispatchAfterInterruptPoll(..., copy_argv=true)`，`pinnedStore` 到 `out`。
- **所有权 / 错误 / 调用**：bound/proxy/native/generator/跨 Realm 都落到这里。

### `runOnInvocation` (`src/exec/call_site.zig:414`)

- **签名**：`inline fn runOnInvocation( comptime fixed_argc: ?usize, comptime idle_machine: bool, invocation: *inline_calls.ActiveInvocation, simple: bool, target: *const inline_calls.InlineTarget, ctx: *core.JSContext, global: *core.Object, this_value: *const JSValue, callee: *const JSValue, args: []const JSValue, lean: ?*inline_calls.LeanFrame, out: *JSValue, ) HostError!void`。
- **作用**：在已有 Machine 上压 Entry 跑到 native_boundary。
- **实现**：`simple` → `runSyncInlineRouteCopiedArgs`；否则 `runSyncInlineRouteOwnedCopy`。
- **所有权 / 错误 / 调用**：`idle_machine=true` 时跳过外层 dispatch 快照。

### `runOnHostInvocation` (`src/exec/call_site.zig:438`)

- **签名**：`inline fn runOnHostInvocation( comptime fixed_argc: ?usize, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, route: *BytecodeRoute, target: *const inline_calls.InlineTarget, this_value: *const JSValue, callee: *const JSValue, args: []const JSValue, lean: ?*inline_calls.LeanFrame, out: *JSValue, ) HostError!void`。
- **作用**：无活动 invocation：publish 常驻 host Machine，入口与内建回调相同。
- **实现**：cached `route.host` 且 epoch 匹配则复用；否则 `acquireForRoute`。`publish` / `defer unpublish` / `runOnInvocation(..., idle_machine=true)`。
- **所有权 / 错误 / 调用**：只对 `host_eligible` 路由 publish。

### `acquireForRoute` (`src/exec/call_site.zig:466`)

- **签名**：`noinline fn acquireForRoute( rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, route: *BytecodeRoute, ) HostError!*host_invocation_mod.HostInvocation`。
- **作用**：绑定站点到常驻 invocation 的冷臂。
- **实现**：`HostInvocation.acquire`，写 `route.host` 与 `host_epoch`。
- **所有权 / 错误 / 调用**：首次创建或其它调用者 retarget 后走这里。

### `resolveRoute` (`src/exec/call_site.zig:483`)

- **签名**：`inline fn resolveRoute( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: JSValue, callee: JSValue, ) Route`。
- **作用**：解析一次：class + inline 资格 + 活动 invocation + host 资格。
- **实现**：`resolveInlineFunction` 失败 → `.generic`（也拒绝 Realm 全局不是 `global` 的 callee）。否则 bind `InlineTarget`，若活动 Machine 三元组匹配则记下 invocation，算 `host_eligible` 与 `simple`。
- **所有权 / 错误 / 调用**：`initInternal` 唯一调用方。无分配。

---

## `host_invocation.zig`

### `HostInvocation.create` (`src/exec/host_invocation.zig:86`)

- **签名**：`pub fn create(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation`。
- **作用**：分配并装配常驻 Machine（idle 帧永不执行）。
- **实现**：`rt.memory.create`；idle_frame.function 指向从未进 registry 的 `host_idle_function`；`Machine.init`；backtrace 是无 bottom 的 segment；可选精确根 `traceRoots`。
- **所有权 / 错误 / 调用**：由 `acquireSlow` 挂到 `rt.host_invocation`。失败不泄漏：create 失败在 allocator。

### `HostInvocation.destroy` (`src/exec/host_invocation.zig:121`)

- **签名**：`pub fn destroy(self: *HostInvocation, rt: *core.JSRuntime) void`。
- **作用**：拆常驻根。
- **实现**：断言未 published、depth==0；释放 one-shot pin；`machine.deinitStorage`；idle_stack.deinit；`memory.destroy`。
- **所有权 / 错误 / 调用**：`retire` 在 runtime 销毁时调用。

### `HostInvocation.acquire` (`src/exec/host_invocation.zig:132`)

- **签名**：`pub inline fn acquire(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation`。
- **作用**：Runtime 单例，按需 retarget。
- **实现**：已有则断言 idle，`alreadyTargets` 否则 `retarget` 并 `retarget_epoch +%= 1`；否则 `acquireSlow`。
- **所有权 / 错误 / 调用**：CallSite 与 `callOnceInto`。epoch bump 使旧站点重新 acquire。

### `HostInvocation.acquireSlow` (`src/exec/host_invocation.zig:145`)

- **签名**：`noinline fn acquireSlow(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation`。
- **作用**：首次创建并登记 retire 回调。
- **实现**：`create`，写 `rt.host_invocation` 与 `host_invocation_retire`。
- **所有权 / 错误 / 调用**：冷路径。

### `HostInvocation.leanFrameFor` (`src/exec/host_invocation.zig:154`)

- **签名**：`pub inline fn leanFrameFor(self: *HostInvocation, rt: *core.JSRuntime, target: *const inline_calls.InlineTarget) ?*inline_calls.LeanFrame`。
- **作用**：按 callee 身份复用 lean 帧。
- **实现**：payload/tag、FB 指针、`var_refs` 基址都匹配且 `isIntact` 则返回；否则 `leanFrameInit`。
- **所有权 / 错误 / 调用**：只在 call 存活、嵌入者持有 callee 时读。

### `HostInvocation.leanFrameInit` (`src/exec/host_invocation.zig:166`)

- **签名**：`noinline fn leanFrameInit(self: *HostInvocation, rt: *core.JSRuntime, target: *const inline_calls.InlineTarget) ?*inline_calls.LeanFrame`。
- **作用**：重建 lean 帧。
- **实现**：清 valid；`initInPlace` 失败返回 null；记下 `lean_callee`。
- **所有权 / 错误 / 调用**：形状不合格返回 null。

### `HostInvocation.oneShotRoute` (`src/exec/host_invocation.zig:184`)

- **签名**：`pub inline fn oneShotRoute( self: *HostInvocation, rt: *core.JSRuntime, global: *core.Object, callee: core.JSValue, this_value: core.JSValue, ) ?OneShotRoute`。
- **作用**：`callFunction` 循环同一回调时只解析一次。
- **实现**：global + callable 位相等则 `storeSlotAsIntPair` 写 this（不取调用方地址，避免 `str q`），返回 cached target/lean/simple。未命中 `oneShotRouteResolve`。
- **所有权 / 错误 / 调用**：只从「无活动 invocation」臂读取，不会与嵌套回调竞态。

### `HostInvocation.oneShotRouteResolve` (`src/exec/host_invocation.zig:209`)

- **签名**：`noinline fn oneShotRouteResolve( self: *HostInvocation, rt: *core.JSRuntime, global: *core.Object, callee: core.JSValue, this_value: core.JSValue, ) ?OneShotRoute`。
- **作用**：解析并 pin 新的 one-shot callee。
- **实现**：释放旧 pin；`resolveInlineFunction` 失败返回 null；先 pin 再发布分辨率；bind target；算 simple；`leanFrameFor`。
- **所有权 / 错误 / 调用**：pin 失败当非资格（null），走根路径。

### `HostInvocation.retire` (`src/exec/host_invocation.zig:233`)

- **签名**：`fn retire(rt: *core.JSRuntime, ptr: *anyopaque) void`。
- **作用**：runtime 销毁钩子。
- **实现**：ptrCast 后 `destroy`。
- **所有权 / 错误 / 调用**：`rt.host_invocation_retire`。

### `HostInvocation.publish` (`src/exec/host_invocation.zig:240`)

- **签名**：`pub inline fn publish(self: *HostInvocation, rt: *core.JSRuntime) void`。
- **作用**：一次 call 期间成为 `active_invocation` 与 backtrace 链头。
- **实现**：断言 idle、无活动 invocation；把 `backtrace_frame` 链进 `rt.hot`；设 `active_invocation`。Debug/ReleaseSafe 置 `published`。`rt` 由参数传入，避免再从 ctx 加载。
- **所有权 / 错误 / 调用**：必须 `unpublish`。GC 在 idle 时看不见它。

### `HostInvocation.unpublish` (`src/exec/host_invocation.zig:259`)

- **签名**：`pub inline fn unpublish(self: *HostInvocation, rt: *core.JSRuntime) void`。
- **作用**：撤掉活动根。
- **实现**：断言 depth 0、仍是 backtrace 头；清 `active_invocation`，恢复 previous。
- **所有权 / 错误 / 调用**：与 `publish` 成对，通常 `defer`。

## 覆盖核对

- 清单：`call_site.zig` 27 + `host_invocation.zig` 11，全部有标题。
- 未覆盖: 无
