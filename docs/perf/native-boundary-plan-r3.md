# JS↔native 边界第三轮执行方案（R3，2026-09-07，driver；派 Opus 子代理执行）

前置：`native-boundary-design.md`（NB2 设计，§16 进度与读数）。main
`7385547f`：叶形态已领先四引擎，managed 与 qjs 持平；剩余账在
native→JS 再入（1.3–1.9× qjs）、原生类方法/访问器（缺属性缓存）、
`charAt` 单字符分配，以及 fun 侧的重新接入。本轮四个工作包并行，每包一个
worktree、一个 Opus 子代理，文件所有权互斥；合并由 driver 做。

通用规则（每包必须遵守）：
- 度量协议不变：`tools/perf/native_boundary`（`sample.py` / `sample_embed.py`，
  4 样本 ABBA，`--cpu 19`，`flock -x /tmp/zjs-host-heavy.lock`），对照 =
  worktree 基点的 ReleaseFast 二进制 + qjs（`~/quickjs/qjs`、
  `/tmp/qjs-boundary-bench`）。
- 门：每步 `zig build test`；收尾 `zig build test262-check -Doptimize=ReleaseFast`
  0 失败 + `mise run batch-gate`（worktree 需先 `git submodule update --init test262`）。
- 16 B `JSValue` 的内存拷贝一律用整数对（`JSValue.loadSlotAsIntPair` /
  `storeSlotAsIntPair`、`call_site.pinnedLoad/pinnedStore`）：X925 上 128 位
  访存对 64 位访存不做 store-forwarding（每次 ~12 cyc）。
- FNABI schema（`src/abi/fun_native_abi.zig` `signatures`）追加签名 id 时
  **本轮统一从 33 起，按包预留**：WP2 无；WP4 无；其他包需要时先在报告里
  申请，driver 分配后再落地（第二轮 K/D 撞号教训）。
- 不 push；不碰其他包的文件；报告 ≤ 60 行：SHA、机制、读数前/后/qjs、门、欠账。

---

## WP1 再入精简帧 R3（zjs，branch `nb2/reentry3`）

目标（cycles / 次，qjs 括号）：`CallSite.call1` 66 → ≤ 40（48）、`call0`
54 → ≤ 30（28）、`callFunction(cb,[i])` 75 → ≤ 45、reduce 回调 99 → ≤ 60
（67）、sort 比较器 111 → ≤ 70（79）、forEach 100 → ≤ 60（69）。

lane R 归因（`4ce1b77f` 提交信息 + 设计稿 §16.3 第 1 项）：IPC 5.0 对 qjs
6.1，零分支预测失误，差距 = 依赖链长度。四刀，按顺序，每刀单独度量：

1. **跨调用保留 `Vm` 每级字段**。`HostInvocation` 已缓存上一个一次性
   callee 的 `LeanFrame`；在 `zjs_vm.runDispatchLoopPublished` /
   `Vm.publishPushedEntry` 前加「同 callee 短路」：若 `machine.vm.function ==
   target.fb` 且 `code_base` 相同，只刷新 `frame` / `stack` / `catch_target`
   三个字段（其余 9 个 store 省掉）。对 `CallSite.callInto` 也一样（站点
   持有的 lean frame 已知 fb）。验收：site1 insn −8 以上。
2. **窗口挂 Entry，去掉 `Stack.setTopPtr` 的 TLS 探针**。现状：
   `stack_mod.pendingCallRegion()`（threadlocal）在每次 `setTopPtr` 上探测，
   用于 `active_invocation_trace.traceStack` 把「region 后退到 frame push
   之间」的操作数纳入根。改为把 pending region 记在 `Machine`（或当前
   Entry）的两个字段（base, len），`traceStack` 从 Machine 读；`setTopPtr`
   变成一条 store。审计全部 `pendingCallRegion` / `retreatToCallRegion*`
   读写点（`grep -n pendingCallRegion\|pending_call_region src/exec`）。
   验收：`op_return` insn −10 以上；`ZJS_GC_STRESS=1` 全套单测绿（根覆盖）。
3. **lean 返回 handler**。`op_return` 对 `.native_boundary` lean 帧
   （`continuation_payload` 标记）走独立 handler `op_return_lean`：不保存
   callee-saved（tail-call 形状，无 prologue），两条 `str` 把返回值写进
   `out`（两个 GPR），`popReturnedLean`，返回 `.native_returned`。做法：
   在 `popAndResume` 之前用 `dying.isLeanBoundary()` 一次判定跳到出线
   `noinline` 的 `returnLeanTail(...)`，确认反汇编里主 `op_return` 的序言
   没有因此增大（lane R 曾量到序言 7 store）。
4. **builtin 回调省快照**。`NativeBoundaryScope.init` 的 32 insn 快照与
   backtrace 段节点 ~16 insn：对 `simple` 路由且非空闲机的场景，只记
   `fence_depth` + arena mark（其余字段在返回时不需要恢复，因为 lean 帧
   不改动它们）；segment view 节点改为惰性（只有 `Error().stack` 触发时
   才物化，现有 `MachineBacktraceView` 的 resolver 可按需重建）。验收：
   reduce / sort 各 −15 cyc。

文件：`src/exec/inline_calls.zig`、`call_site.zig`、`call_runtime.zig`
（`runSyncInlineRoute*`）、`zjs_vm.zig`、`host_invocation.zig`、`stack.zig`、
`active_invocation_trace.zig`、`tailcall_dispatch.zig` **仅** `op_return*` /
`popAndResume` / `runDispatchLoopPublished` 区域。不碰 `vm_native.zig`、
`builtin_dispatch.zig`、`op_call*` / `op_call_method` 的 native 臂、
`get_field*` handler（WP2）。

---

## WP2 W1 属性缓存 + `native_getter` 臂（zjs，branch `nb2/w1`）

这是 `hermes-parity-plan.md` 的 W1（owner 已批，D0=C 序列的中间项）+ NB2 §8.2
的 IC 臂。目标：OO 基准 +5–10%（Octane fixed-work Richards / DeltaBlue /
RayTrace insn −5% 以上）、`prop_dense` 微基准 +8%（T-spike 尺）、
`getter_typed` 50 → ≤ 30、`method_typed` 35 → ≤ 25、`hasOwnProperty` 90 →
≤ 70；test262 0 回归；字节码增长 ≤ 3%。

机制（Hermes `GET_BY_ID_IMPL` 形状，T-spike 已定价 +8～12%）：

1. **Shape identity**（PERF-SHAPE-ID）：`Shape` 加 `identity: u64`
   （runtime 计数器，创建时取新值，**每次原地变异前**（append / delete /
   flags update / proto swap）也取新值，grow-relocation 保留）。参考
   `spike/perf-t-main:src/exec/tspike.zig` 的 `tspike_identity` 与
   `shape.zig` 的变异点。`ptr` 守卫**不可用**（tspike 头注释 R12 说明）。
2. **站点缓存存储**：`FunctionBytecode` 加 `prop_sites: [*]PropSiteCache`
   + `prop_site_count: u16`，与 lane Q 的 `call_sites`（`2c6a231c`）同一
   分配/释放方式；`PropSiteCache = extern struct { guard_key: u64, proto_key:
   u64, slot: u16, state: u8 (empty/own/proto/native_getter/mega), misses:
   u8, holder_slot_or_pad: u32 }` 24 B（或 32 B 二次幂，看寻址）。不是 GC 边。
3. **编码**：`get_field` / `get_field2` / `put_field` 以及 emit 期融合形
   `get_loc0_field` / `get_loc2_field` / `get_var_field` / `get_field_field2`
   / `get_field2_call_method` 在编译期带 u8 `cache_idx`（`.atom_u8` 形，
   T-spike 用过；255 = 无缓存），emitter 按函数分配（`resolve_labels.zig`
   与 lane Q 的 call idx 同一处），所有 size 表 / 反汇编 / `opcode_logical`
   / 测试跟进；opcode 编号不新增。
4. **handler 命中臂**（`op_get_field` 及融合形）：receiver 是对象 →
   `shape = obj.shape; if (shape.identity == site.guard_key)`：`.own` →
   `prop_values[slot]`；`.proto` → 再比 `proto.shape.identity == proto_key`
   → `proto.prop_values[slot]`；`.native_getter` → slot 指向的访问器 entry
   （lane D：K3 函数对象即 cell，`nativeRecord()` 给 entry）→ `sig != 0`
   走 `builtin_dispatch.invokeTypedGetterFast`，否则 `entry.getter()`。
   命中臂不得调用任何非 inline 函数（R12 规则 1：capture 出线、命中内联）。
5. **miss / capture**：出线 `noinline` 的 `captureGetField(site, ...)`：走
   现有慢路得到结果后按结果形态填槽（own data slot / 一级原型 data slot /
   原型上的原生访问器）；miss 覆盖策略（Hermes：直接覆盖，不锁单态）；
   `misses >= 4` → `mega`，永不再填。accessor 非原生、Proxy、exotic、
   typed array 索引等一律不填。
6. **`put_field`**：仅 own 可写 data slot 臂（identity 守卫 + writable 标志
   已在 shape flags）；其余走慢路。
7. **失效**：identity 在变异前更新，所以不需要显式失效；但 `Shape` 被回收
   后地址复用无害（守卫比较的是 u64 identity，不是指针）。文档化到
   `docs/vm-value-representation-contract.md` §5.2 的槽规则。

度量：`mise run perf-screen`（Octane fixed-work）+ T-spike 的四个微基准
（`spike/perf-t-main` 分支 `reports/evidence/PERF-T-SPIKE` 有语料与协议）+
边界语料 `getter_typed` / `method_typed` / `hasOwnProperty`。分两步提交：
先 identity + 存储 + 编码（应为中性），再命中臂（读数）。

文件：`src/core/shape.zig`、`src/bytecode.zig`、`src/compiler/*`（idx 分配）、
`src/opcode_logical.zig`、`src/exec/tailcall_dispatch.zig` **仅** `get_field*`
/ `put_field` / 融合形 handler、`src/exec/vm_property_*.zig`、`property_direct.zig`。
不碰 `op_return*` / `op_call*`（WP1）、`string_*`（WP4）。

---

## WP3 fun 重新接入（fun 仓库，branch `nb2-reconnect`）

结论先行：**zjs 已到可接入状态**。公开面 `zjs.native.managed / leaf /
leafWithState / Class`、`Call`、`defineFunction / createFunction /
defineClass`、`zjs.CallSite`、`zjs.value.Persistent`、`zjs.object.Buffer.Borrow`
全部在 main，文档（`docs/public-api-contract.md`、`docs/embedding-cookbook.md`）
已改写。fun 现状：`third_party/zjs` 是 git subtree；`HostApi.HostCall =
zjs.host.Call` 被 20 个扩展文件（407 处）当作参数类型；`NativeFunction.wrap`
2348 行 comptime marshalling 每次调用建 arena + Scope + 每参 allocPrint +
每返回值 Persistent。

步骤：

1. **同步 subtree**：`git subtree pull --prefix third_party/zjs
   /home/aneryu/zjs main --squash`（或 `git subtree merge`）；修 zig 0.16 /
   接口漂移直到 `zig build` 通过。
2. **保住扩展层的类型**：在 `src/engine/HostApi.zig` 定义 fun 自己的
   `HostCall = struct { realm: *zjs.JSContext(core), output, func_obj:
   ?*Object, this_value, args: []const JSValue }`，由 `*zjs.native.Call`
   构造（`c.ctx.core`、`c.output()`、`c.func_obj`、`c.this`、`c.args()`）；
   `HostFunction` 改为 `zjs.native.Spec`。20 个扩展文件的签名
   `fn(ptr, HostCall) anyerror!JSValue` 保持不变——只在一个适配器里从
   `Call` 构造 `HostCall` 并调用（state 指针经 `Options.state`，finalizer 经
   `Options.finalize`）。`VM.defineGlobalFunction` / `createExternalFunction`
   两处改为 `ctx.defineFunction / createFunction`。
3. **重写 `NativeFunction.wrap`**：输入 `*zjs.native.Call`；参数按
   `c.arg(i)` 就地转换；**去掉** per-call arena / `JSValue.Scope` /
   `Persistent.init` / `pinForBorrow`（调用期间参数由操作数窗口保活，
   返回值直接返回；契约见 `docs/embedding-cookbook.md` Rooting Rules）；
   只有需要 UTF-8 拷贝的字符串参数用 `std.heap.stackFallback(4096)`；
   错误信息文本（`arg[i] expected T, got …`）与 A5 缺参 TypeError 语义逐字
   保留（用 `std.fmt.bufPrint` 到栈缓冲）；`MarshalCtx` 的 `throw*` 改为
   `Call.throwError` 家族。`Bytes` / `MutBytes` 仍是调用期借用（无 pin）。
4. **热回调改 CallSite**：`src/runtime/host/graphics/root.zig` 的
   `drainCompletions`（每帧 `__fun_raf_flush`）与事件分发里的 JS handler
   调用改为持久 `zjs.CallSite`（按 handler 身份缓存，换函数时 `deinit` +
   重建）；`HostApi.callFunction` 保留作一次性路径。
5. **验收**：fun 全部测试（找 `mise.toml` / `zig build test` 的等价物）
   绿；写一个 fun 级微基准（JS 调一个 typed leaf 扩展函数、JS 调一个
   managed 扩展函数、宿主每帧调 JS handler）前后对比并附读数；`wrap` 行数
   与 per-call 分配次数（应为 0）写进报告。

不碰 zjs 仓库源码（发现 zjs 缺口 → 报告，driver 处理）。

---

## WP4 单码元字符串表 + 清理（zjs，branch `nb2/strtab`）

1. **单码元字符串表**：runtime 持 `single_unit_strings: [256]?*String`
   （Latin-1 0..255，惰性创建，永生：经 pin 账本或 immortal 标记，GC 不回收），
   `leafCodeUnitString`（`builtin_dispatch.zig`）、`String.fromCharCode`
   单参、`charAt` / `at` / `String.prototype[Symbol.iterator]` 单码元产出
   全部改查表；> 255 的码元仍分配。验收：`charAt` 76 → ≤ 40、`at` 83 → ≤ 45
   （qjs 90 / 94）；`zig build test` + test262；`ZJS_GC_STRESS=1` 单测绿。
2. **清理**（机械，零语义）：`core.host_function.InternalRecord /
   InternalRecordTable / SparseInternalRecord` 别名全树改名为
   `NativeEntry / EntryTable / SparseEntry`；`Object.nativeRecord*` →
   `nativeEntry*`（保留旧名一个提交周期不必要——直接改）；删除 lane F
   报告的 dispatcher-dead `Machine.pushForwardedCall` /
   `tryPushForwardedEmptyLeafCallFast`（先确认 grep 无引用，其单测改到
   等价路径或删除）；`Kind.forward_call / forward_apply` 未使用 → 删
   （§5.4 已由窗口重排实现，设计稿 §4 表同步）；`CallSiteCache` 保留（JIT
   R10），加注释说明解释器不读。
3. 设计稿 §4.3 / §16 同步一句。

文件：`src/core/string.zig`、`src/core/runtime.zig`（表字段 + 初始化 +
teardown）、`src/exec/string_*.zig`、`builtin_dispatch.zig` **仅**
`leafCodeUnitString`、改名波及的全部文件（机械）。改名与 WP1/WP2 会有
文本冲突：改名提交放在最后一个 commit，driver 合并时以改名为准。

---

## 合并顺序与验收

WP4（清理最后一提交）→ WP1 → WP2 → WP3（fun 侧，依赖 zjs main 同步）。
每次合并后 `mise run batch-gate` + 两套语料复测，读数进设计稿 §16.6。
