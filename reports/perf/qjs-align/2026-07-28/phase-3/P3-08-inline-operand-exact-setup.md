# P3-08 — 内联 `.operand` 普通 exact-frame setup：**负结果，已回退**

- **日期**：2026-07-28
- **P0**：`03cb6486`
- **裁决**：**回退**。假设被证伪 —— 4.18 ns 台阶中只有 0.68 ns 来自 wrapper 调用边界
- **原始数据**：`P3-08-results.json`

---

## 1. One-cut 定义

唯一改动是 `src/exec/tailcall_dispatch.zig` 中的一个 comptime 选择：

```zig
const inline_exact = comptime switch (argc_source) {
    .one, .two, .three => true,
    .operand, .zero => false,          // P0
};
//                    .operand => true  // P1
```

`pushExactSimpleFrameImpl`、快臂 wiring、admission、argv 借用、ownership、
continuation、return epilogue、异常路径、opcode 编码与 dispatch 顺序**均未改动**。

## 2. 纯度检查（全部通过）

### 动态（每 200 次调用，扣除顶层 `run()` 的 1 次）

| workload | P0 wrapper 命中 | P1 wrapper 命中 |
|---|---:|---:|
| exact4 / exact6 / extra | 201 | **1** |
| 非 leaf argc4 / argc6 | 201 | **1** |
| exact3 / 非 leaf argc1,3 | 1 | 1 |
| missing | 1 | 1 |

`FrameSlab.carve`、`allocHeap`、`Frame.ensureCold` 两侧完全相同。

### argv 归属两侧逐字节相同

`args.ptr` / `args.len` / `locals.ptr` 在 exact3/4/6、extra、missing 五例中
P0 与 P1 完全一致（借用四例仍指向 caller operand region `0xfffff7d1d0b0`，
missing 一例仍复制补齐到 formal count）。

### 静态（同态配对，两个编译器态各自独立给出同一结果）

| 符号 | P0 | P1 |
|---|---:|---:|
| `opCall__struct_*`（`.operand` 实例） | 2332 | **3340**（+1008） |
| `opCall` 其余四个实例 | 4052 / 4040 / 3944 / 3848 | **完全不变** |
| `Machine.acquireSlot` | 内联无独立符号 | 92（被外联为共享辅助） |
| 其余全部命名符号 | — | **体积不变** |
| 643 个编译器编号符号 | — | 多重集仅差 `{−2332, +3340}` |

**全二进制符号字节合计 +1100**，符合约 1.4 KB 的预期，低于 2 KB 检查线。

`op_call` 中对 `pushExactSimpleFrame` 的调用点由 4 个降为 3 个 ——
消失的正是 `pushPlainCall(inline_exact=false)` 使用的那一个；wrapper 全局调用点
17 → 16，仍被其他路径（strict 变体、宿主入口等）使用，未变成死码。

### 语义

`exact4/6`、extra args、missing args、method、closure、`arguments`、throw、
异常后恢复、`apply`/`call`/`Reflect.apply` 共 13 项输出与 pinned qjs 逐行一致。
`test-exec` / `test-bytecode` / `test-core` / `test262-smoke` / `fmt` / `diff --check` 全绿。

## 3. 结果

两个 codegen 实例/侧，四个跨实例组合，10 轮平衡交错。

### 目标

| workload | P0 | P1 | 四组合 | geomean | 方向 |
|---|---|---|---|---:|---|
| `call_exact4_nonleaf` | 11.6984 / 11.7215 ms | 11.4851 / 11.5502 | 0.9818 0.9798 0.9873 0.9854 | **0.9836** | 4/4 |
| `call_exact6_nonleaf` | 12.0701 / 12.0607 | 11.8288 / 11.8691 | 0.9800 0.9808 0.9833 0.9841 | **0.9821** | 4/4 |

### 边界（必须不受影响）

| workload | geomean | 方向 |
|---|---:|---|
| `call_exact3_nonleaf` | 1.0009 | 3/4 |

符合预期：`.operand` 的改动不触及 argc≤3。

### 非目标哨兵

| workload | geomean | 方向 |
|---|---:|---|
| `fib_rec` | 1.0002 | 3/4 |
| `call_empty_0` | 0.9994 | 3/4 |
| `call_identity_1` | 1.0004 | 3/4 |
| `prop_read_mono_loop` | 1.0006 | 2/4 |
| `local_arith_loop` | 1.0003 | 2/4 |
| **`global_write_loop`** | **1.0084** | **4/4** |

### 关键量：argc 3→4 台阶

```text
P0: exact3 34.86 ns  exact4 39.03 ns   step +4.18 ns
P1: exact3 34.89 ns  exact4 38.39 ns   step +3.50 ns   缩小 16%
```

## 4. 裁决

| 门槛 | 实测 | |
|---|---|---|
| 目标 geomean 改善 ≥ 3% | 1.64% / 1.79% | ✗ |
| 四组合 4/4 同向 | 4/4 | ✓ |
| 台阶缩小 ≥ 50%（4.18 → ≤2.09） | 4.18 → 3.50，缩小 16% | ✗ |
| 边界 `exact3` 不受影响 | 1.0009 | ✓ |
| 非目标哨兵无稳定回退 ≥ 1% | 最大 +0.84% | ✓（但见下） |

fallback 条款（1%–3% 时可按结构收益合入）要求同时满足「台阶明显缩小」与
「所有 I-cache 哨兵稳定」，**两项都不成立**：

- 台阶 16% 的收窄相对 50% 的判据属于「基本不变」；
- `global_write_loop` **+0.84%、4/4 同向**，四个组合分别 1.0048 / 1.0117 /
  1.0051 / 1.0120 —— 低于 1% 硬线但方向系统一致，正是 +1008 字节主循环增长
  最可能造成的 I-cache 代价。用 1.7% 的 argc≥4 收益去换 0.84% 的全局写回退，
  在真实代码中全局写远比 argc≥4 调用常见，这笔交易是负的。

**回退。**

## 5. 被证伪的是什么（本刀的真正产出）

3.0A 把 7.06 ns 台阶分离出「4.00 ns 来自同一构造器体内联 vs 外联」。
本刀在**动态确认 wrapper 调用已归零**（201 → 1）的前提下，
只拿回了 **0.68 ns**。因此：

> **argc 3→4 的台阶主要不是 wrapper 调用边界成本。**

这与 Phase 2 的 `put_var → coldStd` 表面同构但机制不同 ——
当时移除 wrapper 拿到了 28%，这里移除 wrapper 只拿到 16% 的台阶。

### 剩余 3.50 ns 的首要假设（未验证）

3.0A 说「两侧是同一函数体、相同实参」——**这句话不完整**。
`.one/.two/.three` 的 `argc` 是 **comptime 常量**，`.operand` 的 `argc` 是
**运行时值**。同一个 `pushExactSimpleFrameImpl` 在两侧因此编译成不同的代码：
slab 尺寸算术、窗口划分、槽初始化的 trip count 在固定 arity 侧可以常量折叠，
在 `.operand` 侧必须动态计算。

其余差异只有 pc 前进 3 而非 1、以及一次 `readInt(u16, pc+1)`，各约一条指令。

⚠️ **这是假设，不是结论。** 验证它需要一次独立实验（例如给 `.operand` 加一个
argc 的运行时分派到几个 comptime 特化实例，或直接对比两侧构造器展开后的
指令数与依赖链），本轮没有做。

## 6. 对 Phase 3 主线的影响

按计划，本刀本就**不预期改善 `fib_rec`**（fib 用 argc≤3 的既有路径），
实测 `fib_rec` 1.0002 也确认了这一点。

回退后立即返回 `fib_rec` 主线。**不要顺着 argc≥4 继续加特化** ——
台阶的剩余部分已被证明不是放置问题。

保留的资产：三个 `call_exact{3,4,6}_nonleaf` case（不入 policy），
它们是把 leaf 分类从 arity 效应里分离出来的可复用工具。
