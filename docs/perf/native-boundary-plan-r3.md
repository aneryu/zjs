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

## WP3 fun 重新接入（fun 仓库，branch `nb2-reconnect`）—— **撤回（owner 2026-09-07：fun 的重新接入不由 zjs 侧做）**

下文保留为 fun 侧接入时的参考说明，不再由本轮子代理执行。fun 仓库里
子代理留下的分支 `nb2-reconnect`（3 个 commit：fun 级微基准基线、
`third_party/zjs` subtree 同步到 zjs `8be7b275` 的树）由 fun 侧决定去留；
工作树已恢复到 `main` 干净状态。

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

## WP5 操作数访存宽度纪律（zjs，branch `nb2/storewidth`；WP1 回报后立项）

WP1 收官归因（`f6cf01e7` 报告）：site1 58 cyc 里约 25、reduce 91 里约 30 是
三处 store-to-load forwarding miss，且全在解释器通用 handler，不在边界：
1. `op_get_arg0_fast` 用 `ldr q0` 读帧参数，而 `pushLeanEntry` /
   `copyValueSlotPinned` 用 64 位对写（`stp`）——16 B 读不能从两条 8 B 写转发；
2. `opBinary` 用 `ldur x10,[x1,#-24]` 读 `op_get_arg0_fast` 以 `str q0`
   重发布的操作数 tag 半——8 B 读不能从 16 B 写转发；
3. `op_return` 用 `ldr x10` 读 `opBinary` 以 `stur d0`（FP 寄存器）写的结果
   ——GPR 读不能从 FP 写转发。
X925 规则（lane C 实测）：**读写宽度必须相同且同为 GPR** 才能转发。

目标：解释器操作数栈与帧槽的 16 B `JSValue` 一律以「两条 64 位 GPR 访存」
读写（`ldp/stp` 或两条 `ldr/str`，禁 `q`/`d` 寄存器路径）。做法：
1. 审计 `src/exec/tailcall_dispatch.zig` 里所有 `loadValueAsIntPair` /
   `storeValueAsIntPair` 未覆盖的 JSValue 读写（`op_get_arg*_fast`、
   `opLoc`、`op_push_*`、`opBinary` 的结果写、`op_return*` 的读、
   `dup/swap/drop` 家族），用 `objdump -d` 找出 `ldr q` / `str q` /
   `stur d` / `ldr d` 访问操作数栈或帧槽的指令；
2. 对每处改为整数对访问（`JSValue.loadSlotAsIntPair` /
   `storeSlotAsIntPair`，必要时 `call_site.pinnedLoad/pinnedStore` 的
   inline asm 形式——LLVM 会把相邻两条 8 B 访存重新合成 `q`，asm 钉住）；
   `opBinary` 的 float64 结果先 `fmov x, d` 再以 GPR 写；
3. 验收：Octane fixed-work PMU（`mise run perf-screen` 或其脚本，5 套
   ABBA）cycles 几何平均 ≤ 0.98（改善 ≥ 2%）且没有单项 > 1.01；边界语料
   site1 ≤ 45、reduce ≤ 70、forEach ≤ 75、sort ≤ 85；`zig build test`、
   gc-stress、test262 0 失败、`zig build merge-gate -j32 --summary all`。
   每处改动单独度量，不划算就回退并记录。

文件：`src/exec/tailcall_dispatch.zig` 的通用 handler（**不含** `get_field*`
/ `put_field`——WP2；`op_return*` 已由 WP1 改成两条 `ldr`，在此基础上继续）、
`src/core/value.zig`（`loadSlotAsIntPair` 等）、`src/exec/inline_calls.zig`
的帧构造拷贝。

**WP5 结案（2026-09-07，branch `nb2/storewidth` `d4ca4777`，两刀全回退）**：
前提不成立。新工具 `tools/perf/native_boundary/forwarding_matrix.c`（4 条
延迟链）测得规则是**寄存器域**而非宽度：`ldr x` 从 `stp`、两条 `str`、
部分重叠的旧 store 都能转发（6.9–7.4 cyc），从 `str q`/`str d` 不能
（10.9，tag 半 14.0）；`ldr q` 无论谁写都慢 ~4，`str q → ldr q` 最差 15.6。
把全部三处（及 ~40 处同类）改成 GPR 后 site1 57→56、sort 106→103，
Octane 9 套 cycles geomean 1.0008 / insn 1.0096（navier-stokes +2.3%、
box2d +2.8%）→ 不达 ≤0.98 门槛，回退。WP1 归因的「≈25/58 cyc」不复现：
尾调分派里操作数 load 多数不在关键路径上。⚠️另一条事实：C1_foreach8
zjs 497 insn / 96 cyc vs qjs 523 / 69，分支误预测两边都可忽略，纯 JS
控制循环 zjs IPC 5.2 vs qjs 7.4——回调行剩余差距是解释器整体 IPC，
归 hermes-parity-plan E1，不在边界范围。

## WP6 宿主→JS 指令减肥（zjs，branch `nb2/hostcall-diet`）

现状（4 ABBA、CPU 19、每次穿越 insn / cyc，qjs 括号）：`CallSite.call1`
286 / 56（297 / 48）、`call0` 238 / 47（185 / 28）、`callFunction(cb,[i])`
373 / 68（297 / 48）、`callFunction(cb,[])` 327 / 57（185 / 28）。IPC ≈5
下每 5 insn ≈ 1 cyc，差距即指令数。WP1 已归因剩余指令：
`callFixedInto` 的准入链（`call_depth` / `stack_size` /
`active_bytecode_stack_bytes` / 原生栈限 4 次独立 load + 4 分支）、arena
carve、边界作用域 ~12 store、`HostInvocation` publish / unpublish、
`callFunction` 对 CallSite 的每次构造。刀：
1. 准入链合一：Machine 维护一个预算字（`remaining = min(...)` 在任一上限
   变化时重算），入口一 load 一 cmp；
2. `HostInvocation` 在 CallSite 生命期内保持 published（`init` 发布、
   `deinit` 撤销；嵌套 JS→host→JS 的再入路径已走
   `callValueOrBytecodeSyncInternal`，须证明不受影响）；
3. 边界作用域 store 去重：`Vm.EntryState` 里在 lean 帧下不变的字段不存
   （WP1 刀 4 已证 `publishPushedEntry` 覆写全部 8 字段——所以先改
   `publishPushedEntry` 只写变的字段，再省快照）；
4. `JSContext.callFunction` 复用 per-runtime 的 CallSite 缓存（同 callee
   + 同 this 命中）而不是每次 `callOnceInto` 构造。
验收：n2j1 ≤ 320 insn、site1 ≤ 250 insn、site0 ≤ 200 insn，cycles 不升；
Octane fixed-work（`--benches` 排除 zlib，2 ABBA）cycles 无单项 > 1.01；
四门绿。文件：`src/exec/call_site.zig`、`src/exec/host_invocation.zig`、
`src/exec/inline_calls.zig`（lean 入口）、`src/binding/context.zig`
（callFunction）；**不改** `tailcall_dispatch.zig` 的 handler 体
（`popReturnedLean` 除外）。

## WP7 f.call / f.apply 转发臂减肥（zjs，branch `nb2/forward-diet`）

现状：N6_fcall 548 insn / 96 cyc（qjs 412 / 81）、N7_fapply 692 / 116
（850 / 136）。perf：`op_call_method` 28%、`op_get_field2` 15%（W1 proto
臂已接）、`op_return_general` 14%、`pushForwardedCallEntry` 10%、
`pushExactSimpleFrame` 7%。刀：`pushForwardedCallEntry` 与
`pushExactSimpleFrame` 合并成一次窗口重写 + 一次帧构造（现在是两段，
各自读一遍 callee facts）；`f.call(null, x)` 的 `this` 绑定用
`sloppy_global` 预解析臂（同 `pushWarmExactArgsLeafAndEnter(.sloppy_global)`）。
验收：N6 ≤ 450 insn、N7 ≤ 600 insn，cycles 不升；Octane 无单项 > 1.01；
四门绿。文件：`tailcall_dispatch.zig` 的 `pushForwardedCallEntry` /
`op_call_method` 转发臂、`inline_calls.zig` 的对应构造器。与 WP6 串行
（同一 lane，WP6 后做），避免 `inline_calls.zig` 双写。

## WP8 宿主侧 PropertySite（zjs，branch `nb2/propsite`）

现状：`prop_site`（宿主循环 `ctx.getProperty(obj, "field")`）375 insn /
63 cyc vs qjs `JS_GetPropertyStr` 46 cyc。设计稿 §8.3 / §9：公开
`zjs.PropertySite`（`init(ctx, atom)`、`get(obj) !JSValue`、
`set(obj, v)`），内部一个 `PropSiteCache`（W1 同一结构，own / proto 臂，
`Shape.identity` 守卫），miss 走 `getPropertyAtom` 并 capture；
`getProperty(obj, []const u8)` 保持不变（每次 intern）。加 API 契约与
cookbook 段、`prop_site` 语料改用 PropertySite（保留一行旧 API 作对照
`prop_str`）。验收：PropertySite 命中 ≤ 30 cyc / ≤ 150 insn；四门绿；
`public-api-contract.md` 记新面。文件：新 `src/binding/property_site.zig`
、`src/binding/root.zig` 导出、`context.zig`、bench、docs。

## 合并顺序与验收

WP4（已合，`c6453782`）→ WP1（已合，`0f223926`）→ WP2（已合，`d9beaa14`；lazy 镜像 `a42b1cf2`）→ WP5（结案回退，只合工具 `8e72d76f`）→ WP8（已合 `400d0a8f`）→ WP6+WP7（已合 `e3a7c6c2`）。（WP3 撤回。）**第三轮全部关账，收官读数见设计稿 §16.13。**
每次合并后 `mise run batch-gate` + 两套语料复测，读数进设计稿 §16.6。
