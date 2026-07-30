# P3-09 — `fib_rec` leaf setup / return 动态归因

- **日期**：2026-07-28
- **测量 HEAD**：`653b3ed6`（P3-08 已回退，源码树 = `03cb6486`）
- **性质**：**只做画像，未改任何源码**
- **原始数据**：`P3-09-results.json`

---

## 1. `fib_rec` 的实际调用链（真实符号）

`fib` 自身含调用，因此**不是 leaf**：`exact_args_leaf_kind`、`capture_leaf_kind`、
`simple_inline_empty_leaf` 全部不命中。argc=1 → `OP_call1`。

```text
opCall__struct_75094.h            (op_call1 实例，align(64))
  resolveInlineFunction           inline_calls.zig:126-160
  leaf 各臂全部 miss
  pushAndEnter(inline_exact=true)
  pushPlainCall(true, …)
  pushExactSimpleFrameImpl        内联展开，无 bl
  enterEntry                      tailcall_dispatch.zig:455-490
→ 被调 bytecode（op_get_arg_short / opCompare / op_if_false8 / opBinary / opLoc …）
→ op_return                       tailcall_dispatch.zig:1240
  popFrameMode                    inline_calls.zig:3320-3350
    Entry.deinitReturned          inline_calls.zig:606-632
    leaveInlineCallDepthBytes     vm_call.zig:288-296
  caller restore                  tailcall_dispatch.zig:4051-4069
```

**没有任何外联构造器参与**：`pushExactSimpleFrame` wrapper、`FrameSlab.carve`、
`allocHeap`、`execCall`、`setupInlineEntry` 在四个 workload 中命中数均为
**1**（顶层 `run()` 自身），内层调用一次都不经过。

## 2. 动态计数（扣除顶层 `run()`）

| 计数项 | `call_empty_0` | `call_identity_1` | `recursive_countdown_1` | `fib_rec` |
|---|---:|---:|---:|---:|
| 内层 JS→JS 调用 | 200 | 200 | 201 | 465 |
| 外联 exact frame setup | 0 | 0 | 0 | 0 |
| `FrameSlab.carve` | 0 | 0 | 0 | 0 |
| heap fallback (`allocHeap`) | 0 | 0 | 0 | 0 |
| arena grow (`carveSlow`) | 0 | 0 | 0 | 0 |
| Entry chunk 增长 (`acquireSlotSlow`) | 0 | 0 | 0 | 0 |
| `Frame.ensureCold` | 0 | 0 | 0 | 0 |
| open var refs (`closeOpenVarRefs`) | 0 | 0 | 0 | 0 |
| RC drop-to-zero (`destroyZeroRef`) | 0 | 0 | 0 | 0 |
| argv 借用 | 每次 | 每次 | 每次 | 每次 |
| argv 复制 | 0 | 0 | 0 | 0 |

**全部符合预期，无一偏离。** 普通递归调用路径上没有分配、没有增长、没有冷 side-struct、
没有释放慢路 —— 剩下的成本**全是控制面**。

## 3. 六阶段采样归因

采样按源码行聚合后归入阶段（解析总计 100.0% / 100.1%，非截断汇总）。
⚠️ 采样占比用于定位，不作为收益上界（沿用第 3 刀更正后的口径）。

| 阶段 | `call_empty_0` | `call_identity_1` | `recursive_countdown_1` | **`fib_rec`** |
|---|---:|---:|---:|---:|
| Body / 其他 opcode | 41.15% | 41.46% | 46.86% | **42.22%** |
| **Return** | 32.56% | 28.15% | 19.00% | **20.25%** |
| Setup | 8.48% | 11.04% | 8.40% | **15.91%** |
| Admission | 2.20% | 1.71% | 5.11% | **7.68%** |
| Publication | 1.78% | 2.51% | 5.95% | **5.00%** |
| RC / cold | 0.23% | 3.68% | 1.93% | **4.78%** |
| Setup(preflight) | 0.98% | 0.23% | 0.81% | **2.77%** |
| unattributed | 12.58% | 11.20% | 11.89% | 1.34% |

四者对照的读法：**Return 在四个 workload 中都占 19%–33%**，
说明它是普通调用固定税，不是递归或 fib body 特有的。

`fib_rec` 每次调用 28.95 ns（4.3436 ms / 150049 次调用），qjs 21.46 ns，**差 +7.49 ns**。

### `fib_rec` 内 Return 的构成（占 `op_return` 局部采样）

| 项 | 局部 % | 折合 fib_rec |
|---|---:|---:|
| 值释放（this / current_function / live range / args / open refs / ctor fallback，行 622-630） | 18.27% | 4.57% |
| **深度与字节记账（3324 / 3344 / 3345 / 3346 + vm_call 294 / 295）** | **18.55%** | **4.64%** |
| caller restore（tailcall_dispatch 1066 / 1218 / 4051-4069） | 8.31% | 2.08% |
| teardown 形态判别（336 / 440 / 476） | 3.89% | 0.97% |
| arena restore（608） | 1.19% | 0.30% |

## 4. QJS 最小对应画像

`JS_CallInternal` 占 qjs 的 **99.96%**（单函数，无独立符号）。按行号区间划分：

| 区间 | % |
|---|---:|
| prologue：entry + frame setup（17816-17870） | 34.52% |
| body opcodes | 31.03% |
| JSValue 宏（RC / dup / free，quickjs.h） | 15.15% |
| `OP_call` 结果压栈（18200） | 7.12% |
| `set_value`（2667-2668） | 6.96% |
| **`done:` return epilogue（20698-20710）** | **0%（低于 5169 样本的可见度）** |

qjs 的普通返回 epilogue 全文只有：

```c
done:
    if (unlikely(b->var_ref_count != 0)) close_var_refs(rt, b, sf);
    for (pval = local_buf; pval < sp; pval++) JS_FreeValue(ctx, *pval);
rt->current_stack_frame = sf->prev_frame;
return ret_val;
```

**没有深度记账、没有字节记账、没有 continuation、没有 teardown 形态判别、
没有 arena restore、没有 caller-region release、没有 tail-chain 预算。**
`js_check_stack_overflow` 只在入口探测一次，出口没有对应的递减 ——
原生栈自己回退。

### 每次调用的成本对照

| 阶段 | zjs ns/call | qjs ns/call | delta |
|---|---:|---:|---:|
| 调用入（Admission + Setup + preflight + Publication） | 9.08 | 7.41 | **+1.67** |
| **Return** | **5.86** | **≤1.66** | **≈ +4.3** |
| Body + RC | 13.60 | 11.40 | +2.20 |
| 合计 | 28.95 | 21.46 | +7.49 |

⚠️ 三项 delta 相加为 +8.17，与实测 +7.49 有约 9% 出入，来自两侧的
unattributed 桶与阶段边界的分类差异。**这是分解的精度上限，不是精确账本。**

**结论：`fib_rec` 与 qjs 差距的最大单项是 Return，约占总差距的 57%。**
根因是结构性的：qjs 的普通返回是 alloca 帧上的一次 C `return`，栈自动回退；
zjs 维护显式的 Machine 帧栈，每次返回都要更新 runtime 级的深度与字节计数、
判别 teardown 形态、恢复 caller 状态。

## 5. 一处可直接消除的重复

`popFrameMode`（`inline_calls.zig:3320-3350`）在普通返回上做了**两轮**深度/字节记账：

```zig
const chain_budget: Entry.TailChainBudget = if (dying.teardown.tail_chain)
    dying.tailChainBudgetSlot().* else .{ .extra_depth = 0, .planned_stack_bytes = 0 };
…
vm_call.leaveInlineCallDepthBytes(self.ctx, dying_stack_bytes);  // -= planned; call_depth -= 1
…
self.ctx.runtime.hot.call_depth -= chain_budget.extra_depth;                      // -= 0
self.ctx.runtime.hot.active_bytecode_stack_bytes -= chain_budget.planned_stack_bytes; // -= 0
```

对每一个普通帧 `tail_chain` 都是 false，因此第二轮是**对两个热 runtime 字段各做一次
读-改-写、减去静态的 0**，外加一次 flag 读与分支来构造 `chain_budget`。

采样：3324（0.74）+ 3344（7.69）+ 3345（3.31）= **11.74% of `op_return`
= 2.94% of `fib_rec`**。动态命中率 = 每一次返回。

## 6. 下一刀的选择（按 §6 门槛）

门槛：`动态命中 ≈ 每次调用` 且 `≥ 约 8% of fib_rec` 或 `相对 QJS ≥ 3 ns/call`，
且可单机制隔离。

| 候选 | 命中率 | % of fib_rec | vs qjs | 单机制隔离 | 判定 |
|---|---|---:|---:|---|---|
| **Return 阶段（整体）** | 每次 | **20.25%** | **+4.3 ns** | 否，是聚合 | 阶段达标 |
| ├ 值释放（622-630） | 每次 | 4.57% | — | 是 | 语义必需，不可删 |
| ├ **深度/字节记账重复** | 每次 | **2.94%** | — | **是** | **未达 8%，但隔离最干净** |
| ├ caller restore | 每次 | 2.08% | — | 部分 | 未达标 |
| └ teardown 形态判别 | 每次 | 0.97% | — | 是 | 未达标 |
| Setup 阶段 | 每次 | 15.91% | +1.67 ns（含入口全部） | 否 | 相对 qjs 差距小 |
| Admission | 每次 | 7.68% | — | 是 | 边缘 |
| Body | — | 42.22% | +2.20 ns | 否 | 非调用框架 |

**Return 阶段满足门槛（20.25% ≥ 8%，+4.3 ns ≥ 3 ns）**，但**其中没有任何单一子机制
达到 8%**。按决策树分支 A「第一刀只移动 profile 明确指出的一个边界」，
唯一同时满足「每次命中 + 单机制 + 无语义影响 + 边界清晰」的是：

> **普通返回的深度/字节记账重复（`popFrameMode` 的第二轮零值扣减与 tail-chain 预算读取）**
> 预期约 2.9% of `fib_rec`，约 0.85 ns/call。

### 必须同时记录的天花板

即使 Return 阶段被完全消除（不可能，值释放是语义必需），
`fib_rec` 也只能从 `1.3489x` 降到约 `1.15x`。而单靠上面这一刀，
预期只有 `1.3489 → 约 1.31x`。**Phase 3 的 `fib_rec ≤ 1.20x` 退出线，
不可能由任何单刀达成**；它需要 Return 阶段的多个子机制一起处理，
而结构天花板是「显式 Machine 帧栈 vs 原生 alloca 帧」这一差异本身
（§11 native recursion 的采用门槛正是为此设立）。

## 7. 未做与限制

- 只画像，未改源码；临时计数用 gdb 断点，未进入提交；
- 阶段划分按源码行归属，边界（例如 `interrupt_counter` 归 preflight 而非 Admission）
  是判断而非定义，已在表中标明归属；
- 两侧 delta 相加与实测差 9%，见 §4 说明；
- `call_arguments`（+47 ns/call）与 `call_throw`（+44 ns/call）按计划保持在退出线外，
  本轮未测机制；
- qjs 侧只做最小对应画像，未逐阶段还原其内部实现。
