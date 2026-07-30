# P5-01 — Native continuation boundary prototype：**决定性负结果，路线关闭**

- **日期**：2026-07-29
- **P0**：`3c272686`
- **裁决**：**关闭 native recursion 路线**。`fib_rec` 劣化 **24.8%**，绝对值 `1.2989x → 1.6174x`
- **原始数据**：`P5-01-results.json`

---

## 1. 验证的命题

> 在 musttail VM 调用链中，于 `OP_call` 边界插入一个非尾的 native continuation
> boundary，能否替代显式 caller continuation 保存/恢复，从而降低普通同步调用成本？

## 2. 实现形态（按修正后的设计）

- `NativeContinuationFrame` 语义由 `runNativeContinuationCall` 的原生活动记录承担，
  **不新建结构、不替代 `Frame`**；
- Entry 照旧 `pushPlainCall` 压栈，同一张 handler 表跑函数体，同一套 teardown 退栈；
- **唯一改变的是返回路径**：`op_return` 在 `machine.depth == vm.native_boundary_depth`
  时产出 `.returned`，由原生 return 把值交回边界，而不是尾调用回 caller 并重发布其状态；
- 全部由 `-Dzjs_native_continuation_proto` 隔离，**默认构建逐字节不变**（默认构建 RC=0，
  `Vm` 字段在关闭时为零尺寸）；
- 硬门槛：`native_continuation_max_depth = 512`，超出后回落既有路径。

### 覆盖范围

只有**通用普通调用**被改道（`pushAndEnter` 那一臂）。leaf / constructor / method /
forwarded / continuation 各臂在其之前就已返回，全部不受影响。

## 3. 语义与硬门槛（全部通过）

| 项 | 结果 |
|---|---|
| `fib(12)` / `down(200)` / identity / empty | 输出正确 |
| **深递归 `down(2000)`** | **正确返回 2000，无段错误**（超 512 层回落） |
| `fib(24)` | 46368 |
| throw probe | 200，正确 |
| `down(600)` | 0 次边界命中 —— 回退门槛按设计生效 |

### 命中分布（每 200 次调用）

| workload | native boundary 命中 |
|---|---:|
| `fib` | **466**（每次递归都走 prototype） |
| `recursive_countdown` / `identity` / `empty` | **1**（顶层 `run()`；本体走 leaf 臂） |

## 4. 结果

| workload | P0 | P1 | **P1/P0** | P0 ns/call | P1 ns/call | Δ |
|---|---:|---:|---:|---:|---:|---:|
| **`fib_rec`** | 4.2049 ms | 5.2479 ms | **1.2481** | 28.02 | 34.97 | **+6.95** |
| `call_empty_0` | 7.1269 | 7.1817 | 1.0077 | 23.76 | 23.94 | +0.18 |
| `call_identity_1` | 7.4988 | 7.5758 | 1.0103 | 25.00 | 25.25 | +0.26 |
| `recursive_countdown_1` | 3.2086 | 3.2391 | 1.0095 | 21.39 | 21.59 | +0.20 |

```text
fib_rec 绝对定位：qjs 3.2401 ms   zjs(proto) 5.2404 ms   ratio 1.6174
                （P0 为 1.2989）
```

**唯一走 prototype 的 workload 慢了 24.8%，每次调用多付 6.95 ns。**
三个走 leaf 臂的对照各慢 0.77%–1.03% —— 那是 `op_return` 多一个边界测试
加代码增长的代价，落在从不使用该边界的路径上。

### 裁决

| 门槛 | 实测 | |
|---|---|---|
| 强成功：`fib_rec ≤ 1.15` 且 return ≤ 3 ns | `1.6174`，return 未测（总量已劣化） | ✗ |
| 中成功：`1.15–1.22` | — | ✗ |
| **关闭：改善 < 5%** | **−24.8%（劣化）** | **触发** |

**关闭 native recursion 路线。**

## 5. 这个负结果证伪了什么

P3-13 的模型是：

> return 占剩余差距 68%（zjs 5.91 ns vs qjs 1.54 ns），
> 根因是 qjs 的普通返回是 alloca 帧上的一次 C `return`，恢复靠原生 return address，
> 而 zjs 维护显式 Machine 帧栈。

**本实验直接否定了这个因果链的后半段。**

把 caller continuation 交给原生 return address 后，每次调用不是省了 4.37 ns，
而是**多付了 6.95 ns**。原因是 zjs 的 tail-call trampoline **本来就比原生边界便宜**：

```text
尾链返回：op_return 尾调用回 caller handler + reloadAfterPop 重发布
          —— 无原生帧、无寄存器保存/恢复、musttail 直接跳转

原生边界：每次调用一个真实原生活动记录（帧 + 寄存器保存/恢复）
          + next() 必须以返回值形式把 Outcome 送回，musttail 链被打断
          + 显式 pop 与 caller 状态恢复仍然要做（Entry 没有消失）
```

**结论：zjs 并没有在为「缺少原生 return address」付费。**
它在这个粒度上已经比原生边界更便宜 —— 现有的 musttail 链本身就是极低开销的控制转移，
强行插入原生帧反而打断尾链、引入 ABI 保存、增加寄存器 spill 与原生栈活动。

对 qjs 的比较也应随之修正：**不是「qjs 快因为用了 C 栈」，
而是「qjs 快因为它的普通 frame 状态模型极简，C 栈只是实现手段」**
（无 arena mark、无 catch target、无 teardown 形态、无 continuation 标签）——
那是**状态量**问题，不是**恢复机制**问题。

## 6. Phase 3–4 的完整证伪链

| 轮次 | 曾被认为的根因 | 结果 |
|---|---|---|
| P3-08 | argc 台阶 = wrapper 调用边界 | 4.18 ns 中只拿回 0.68 ns |
| P4-00 | Entry 四条 cache line = 特殊状态 | 特殊状态仅 22 B 且与热字段同线 |
| P4-01a | `op_return` 208 B 帧 = extended 链 | 体积 −27%，帧 −15%，`fib_rec` 0% |
| P4-02.0 | 切片长度 = 纯冗余 | 兼编码「窗口已安装」，三条改动路径 |
| P4-01c | 调用路径对代码布局敏感 | 五个 pad lineage 极差 ≤0.24% |
| **P5-01** | **return 差距 = 缺少原生 return address** | **原生边界每次调用多付 6.95 ns** |

六次证伪指向同一个结论：**剩余差距既不在共享的控制流、也不在布局、
也不在恢复机制，而在普通帧携带的状态量本身**
（`arena_mark` 16 B、`catch_target` 16 B、`this_value` 16 B、
五个切片 80 B、`Stack` 40 B —— qjs 一样都没有）。

## 7. 建议的去向

按既定规则，native recursion 失败则回到 Frame representation 或转 BigInt。
结合 P4-01c（布局不敏感）与 P4-02.0（长度不可纯推导、107 个消费者）：

```text
Frame/Stack representation redesign
    收益上限：Entry 256 -> 128~136（P4-01b）
    代价：107+ 消费者改动，一次大范围语义门禁
    时间收益证据：无（P4-01c 只排除了布局，未证明 footprint 是瓶颈）

BigInt mul-multilimb ≈ 1.77x
    明确热点，独立路径，无前置证伪缺口
```

**建议转 BigInt。** 理由：Frame representation 是本阶段唯一剩下的方向，
但它是「高代价 + 无时间证据」的组合。

⚠️ **对 `fib_rec ≈ 1.30x` 的正确表述**（不要说成「已证明不可优化」）：

> 在当前 same-Machine continuation 模型下，经过 wrapper、return 判别、
> extended 状态、cache line 归属、代码布局、native return boundary 六类假设的验证后，
> 剩余差距主要来自 Frame/Stack 状态模型本身；继续优化需要结构级重设计，
> 而不是下一刀 one-cut。

六次证伪缩小的是**假设空间**，不是**可优化性**。Frame/Stack 方向未被关闭，
只是降级为「无时间证据支撑、代价已知很高」，应在有新证据时重开。

## 8. 限制

- 单实例 P0/P1，未做四组合（劣化幅度 24.8% 远超 build-instance spread ~0.5%，
  结论不受影响）；
- 未拆 entry/return/body 三段 —— 总量已劣化，分段归因对裁决无影响；
- prototype 未支持 throw/tail 的边界内处理（按 (a) 方案设计如此），
  但 throw probe 证明不会破坏 VM；
- 该实现每次调用仍保留 Entry 压栈；「同时去掉 Entry 与尾链」的组合未测，
  但其收益需先由 Frame representation 提供，不属于本实验。
