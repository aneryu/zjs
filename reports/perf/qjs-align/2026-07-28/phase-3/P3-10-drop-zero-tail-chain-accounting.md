# P3-10 — 删除普通返回的零 tail-chain 二次记账

- **日期**：2026-07-28
- **P0**：`c1361781`
- **裁决**：**合入**（结构性小收益档：`fib_rec` −1.92%，4/4，五处普通 epilogue 全部缩小）
- **原始数据**：`P3-10-results.json`

---

## 1. One-cut 定义

`popFrameMode`（`inline_calls.zig`）此前对**每一个**退栈帧执行两轮深度/字节记账：

```zig
const chain_budget: Entry.TailChainBudget = if (dying.teardown.tail_chain)
    dying.tailChainBudgetSlot().* else .{ .extra_depth = 0, .planned_stack_bytes = 0 };
…
vm_call.leaveInlineCallDepthBytes(self.ctx, dying_stack_bytes);   // 真实记账
…
hot.call_depth -= chain_budget.extra_depth;                        // 普通帧恒为 -= 0
hot.active_bytecode_stack_bytes -= chain_budget.planned_stack_bytes; // 普通帧恒为 -= 0
```

P1 把整个 tail-chain 形态移进外联孪生函数：

```zig
if (dying.teardown.tail_chain) return self.popTailChainFrameMode(returned);
// 普通路径此后不再提及 chain_budget
```

普通路径因此不再：读 overlay、构造 16 字节 budget、把它跨 teardown 保活、
对两个热 runtime 字段各做一次读-改-写。

**未按「静态区分」实现的原因**：`tail_chain` 是退栈帧的运行时属性，不是调用点的
comptime 属性，`popFrameMode` 的两个调用点都无法静态分辨。计划允许的次优形态
（flag 测试 + 分支）在这里代价极低：该 bit 位于 `teardown` 字节内，
而 `deinitReturned` 本来就要加载同一字节来测 `has_native_caller` 与
`constructor_completion`。把状态搬进 sidecar 属于 P3-12 范围，本刀不做。

未改动：JS 语义、ownership、arena restore、frame pop、caller-region release、
结果压栈顺序、真实 tail-chain 的记账数值。

## 2. 纯度

### 正向 tail-chain probe（不可由普通 workload 替代）

zjs 的 parser **从不发射** `op.tail_call` / `op.tail_call_method`
（`src/bytecode.zig` 中这两个 opcode 只出现在终结指令表与一处合成 fixture）。
生产 JS 触发不到 tail replacement，因此正向 probe 只能来自测试套件的合成 bytecode
（`src/tests/exec.zig:1005` "raw tail call opcodes share the bounded tail-chain
stack contract"）。

在 P1 的 `test-exec` 二进制上设断点计数：

```text
popTailChainFrameMode 命中 = 10
Summary: 388 passed; 0 skipped; 0 failed
```

该测试断言的正是**有界 tail-chain 栈契约**，即累计 budget 的释放是否正确 ——
若记账被误删，深度/字节会泄漏并使断言失败。

⚠️ 这也意味着：被删掉的那一轮零值扣减，是为**生产 JS 实际触发不到**的机制
在每一次普通返回上收税。

### 普通 workload 的 tail-chain 命中

`call_empty_0` / `call_identity_1` / `recursive_countdown_1` / `fib_rec`
的 `popTailChainFrameMode` 命中均为 **0**。

### 静态符号体积（同态配对，两个编译器态各自独立给出同一结果）

| 符号 | P0 | P1 | Δ |
|---|---:|---:|---:|
| `Machine.popTailChainFrameMode` | 不存在 | 1392 | **+1392** |
| `tailcall_dispatch.op_return` | 5416 | 5212 | **−204** |
| `tailcall_dispatch.op_return_undef` | 5180 | 5040 | **−140** |
| `zjs_vm.runWithCallEnvAfterInterruptPoll` | 15524 | 15280 | **−244** |
| `Machine.popConstructorReturn` | 1156 | 1096 | **−60** |
| `Machine.deinit` | 1396 | 1380 | **−16** |
| 其余全部命名符号 | — | — | **不变** |
| 643 个编译器编号符号 | — | — | **净 0** |

净 +728 字节。**五处内联展开点全部缩小**，稀有形态外联一次 —— 这是 one-cut 的
教科书签名，也证明普通路径没有新增热分支（否则代码不会变小）。

## 3. 结果

两个 codegen 实例/侧，四个跨实例组合，10 轮平衡交错。

### 目标

| workload | P0 | P1 | 四组合 | geomean | 方向 |
|---|---|---|---|---:|---|
| **`fib_rec`** | 4.3445 / 4.3407 ms | 4.2711 / 4.2471 | 0.9831 0.9840 0.9776 0.9784 | **0.9808** | **4/4** |
| `recursive_countdown_1` | 3.2006 / 3.2118 | 3.2010 / 3.2017 | 1.0001 0.9966 1.0004 0.9969 | 0.9985 | 2/4 |
| `call_identity_1` | 7.5358 / 7.5208 | 7.5383 / 7.4862 | 1.0003 1.0023 0.9934 0.9954 | 0.9979 | 2/4 |
| `call_empty_0` | 7.2034 / 7.1759 | 7.1938 / 7.1778 | 0.9987 1.0025 0.9964 1.0003 | 0.9995 | 2/4 |

### 为什么只有 `fib_rec` 动了 —— 三个「中性」结果是确认，不是异常

对四个 workload 分别做 `op_return` 的行级归因，被删除的那三行
（`inline_calls.zig:3324 / 3344 / 3345`）占比为：

| workload | 该记账占 `op_return` |
|---|---:|
| `call_empty_0` | **0.00%** |
| `call_identity_1` | **0.00%** |
| `recursive_countdown_1` | **0.00%** |
| **`fib_rec`** | **13.56%** |

其余三者的返回走 leaf 返回臂（`op_return` 内 `isEmptyLeaf()` 分支等），
根本不经过 `popFrameMode`。**预测为 0 的地方实测为 0（−0.05% ~ −0.21%），
预测有成本的地方实测有收益。**

`fib_rec` 的事前估算：`13.56% × 25.03% = 3.39% of fib_rec`，实测 **1.92%**。
沿用第 3 刀更正后的口径 —— 采样占比是**局部显式成本估计，不是收益上界**，
方向一致、量级同阶即可，偏乐观是常态。

### 非目标哨兵

| workload | geomean | 方向 | 判读 |
|---|---:|---|---|
| `call_throw` | 0.9706 | 4/4 | 改善 2.94% |
| `call_arguments` | 0.9795 | 4/4 | 改善 2.05% |
| `call_body_loop` | 0.9863 | 4/4 | 改善 1.37% |
| `method_call_loop` | 0.9921 | 4/4 | 改善 0.79% |
| `global_write_loop` | **1.0057** | 4/4 | 回退 0.57%，低于 1% 线 |
| `prop_read_mono_loop` | **1.0038** | 4/4 | 回退 0.38%，低于 1% 线 |

四个走 `popFrameMode` 的调用型哨兵一致改善（0.8%–2.9%），
两个**非调用型** workload 一致小幅回退 —— 后者与本机制无关，
是 `op_return` 缩小 204 字节后代码放置/对齐位移的结果，两者均远低于 1% 门槛。
`call_arguments` 与 `call_throw` 只要求不回退，实测反而是改善最大的两个。

## 4. 裁决

| 门槛 | 实测 | |
|---|---|---|
| `fib_rec` 改善 ≥ 2% | 1.92% | ✗（差 0.08 个百分点） |
| ordinary-call geomean 改善 ≥ 2% | 0.59% | ✗ |
| 4/4 同向（目标） | `fib_rec` 4/4 | ✓ |
| 非目标哨兵无稳定回退 ≥ 1% | 最大 +0.57% | ✓ |
| tail-chain 正向 probe 一致 | 10 次命中，388 passed | ✓ |

未达「明确成功」，按**结构性小收益**条款合入：

- 收益 1.92% 落在 0.5%–2% 区间，4/4 同向；
- **普通 epilogue 代码体明确减少**：五处调用点分别 −204 / −140 / −244 / −60 / −16，
  编译器编号符号净 0；
- **无新增热分支**：flag 位于本就被加载的 `teardown` 字节，且代码在每一处都变小；
- 删除的是普通返回中**语义上无效**的 tail-chain bookkeeping，不是 benchmark 特化。

## 5. 门禁

测量前：`test-exec` / `test-bytecode` / `test-core` / `test262-smoke` /
`zig fmt --check` / `git diff --check` —— 全绿。

合入前：`test` / `test262-gate` / `test-oom` / `smoke` /
`test -Doptimize=ReleaseSafe` / `test-core -Dzjs_force_gc=true` /
`perf-self-check` —— 见 §7。

## 6. 对 Phase 3 主线的位置

```text
fib_rec  1.3489x  ->  约 1.323x
```

距 `≤1.20x` 退出线仍差约 10%。P3-09 已给出天花板判断：
Return 阶段内没有任何单一子机制达到 8%，需要连续清理多个独立固定税。
下一步按既定顺序进入 **P3-11 普通 return epilogue 字段触达审计**。

本刀额外提供了一条可复用的方法学结论：**用「预测为零的 workload 实测也为零」
作为归因的正向对照**，比只看目标 workload 改善更能排除布局运气。

## 7. 已知限制

- 生产 JS 触发不到 tail replacement，正向 probe 只能来自测试套件合成 bytecode；
- 两个 build instance 不构成配对 compiler state，比较取四个跨实例组合；
- 两个非调用型哨兵的 0.38%–0.57% 回退未做机制归因，按代码放置效应记录；
- 事前估算 3.39% 与实测 1.92% 的差距未单独拆解。
