# Phase 3.0A — argv 动态归因与 argc 台阶的因果分离

- **日期**：2026-07-28
- **测量 HEAD**：`b8fa61b0`
- **裁决**：**argv 已 canonical（情况 B），P3-07 关闭**；台阶的因果由后续实验单独分离
- **未改任何源码**

---

## 1. 结论摘要

```text
1. argc=4 每次调用命中 borrowed-argv admission          是
2. 反汇编中的 16-byte「copy loop」每次调用执行          否 —— 它根本不是循环（见 §3）
3. 它复制的是否是 argv                                  不适用
4. argc=3 与 argc=4 还多执行了哪些 setup 阶段            一个也没有 —— 同一函数体，只差调用边界
```

**基线 dossier §6 中「有一处 16 字节后增量拷贝循环」的说法是错的，此处更正**：
`str q1, [x22], #16` 没有回跳边，是一条单独的后增量存储
（`takeSourceSlot` 取走 callable 后把源槽写成 undefined）。当时只看了寻址模式，
没有检查是否存在向后分支。

## 2. 帧构造器命中计数（每 workload 200 次调用）

| workload | formal | argc | `pushExactSimpleFrame` | `FrameSlab.carve` | `allocHeap` | `setupInlineEntry` |
|---|---:|---:|---:|---:|---:|---:|
| exact0 | 0 | 0 | 1 | 1 | 0 | 0 |
| exact3 | 3 | 3 | 1 | 1 | 0 | 0 |
| **exact4** | 4 | 4 | **201** | 1 | 0 | 0 |
| **exact6** | 6 | 6 | **201** | 1 | 0 | 0 |
| **extra** | 4 | 5 | **201** | 1 | 0 | 0 |
| missing | 5 | 4 | 1 | 1 | 0 | 0 |

每列的 `1` 是顶层 `run()` 自身那一次（该噪声在全部列中单独扣除）。
`allocHeap` 全零 —— 无 heap fallback。`carve` 只有顶层那次，因为 200 次内层调用
直接走 `rt.vm_stack.carve`（已内联），不经过 `FrameSlab.carve`。

## 3. 指针归属（不靠反汇编推断）

在 `op_get_arg_short` 侧读取被调 frame 的窗口地址：

| workload | formal | argc | `args.ptr` | `args.len` | `locals.ptr` | `locals−args` | 判定 |
|---|---:|---:|---|---:|---|---:|---|
| exact3 | 3 | 3 | `0xfffff7d1d0b0` | 3 | （len 0） | — | **借用** |
| exact4 | 4 | 4 | `0xfffff7d1d0b0` | 4 | `0xfffff7d1d100` | 80 = 5×16 | **借用** |
| exact6 | 6 | 6 | `0xfffff7d1d0b0` | 6 | `0xfffff7d1d120` | 112 = 7×16 | **借用** |
| extra | 4 | 5 | `0xfffff7d1d0b0` | 5 | `0xfffff7d1d110` | 96 = 6×16 | **借用** |
| missing | 5 | 4 | `0xfffff7d1d100` | **5** | `0xfffff7d1d150` | 80 = 5×16 | **复制并补 undefined** |

判据满足情况：

- 借用四例的 `args.ptr` **完全相同**（`0xfffff7d1d0b0`），即 caller operand region 基址，
  与 argc 无关 —— 复制的话每次会落在新 carve 的 slab 里；
- `locals.ptr − args.ptr` 恰好等于 `(1 callable + argc args) × 16`，
  说明 locals 是紧贴 caller region 之上 carve 的，而 args 指向该 region **之内**；
- `missing` 一例 `args.ptr` 落在 slab 内、紧邻 locals，且 `len` 被补到 formal=5 ——
  **参数不足时确实复制并补 undefined，这是正确行为**；
- extra-args（formal=4, argc=5）仍然借用，`len=5`。

代码侧一致：`setupSimpleInlineEntryImpl` 的 `@memcpy` 被
`if (pad_args or move_args)` 守住，而 `pushPlainCall` 以 `pad_args=false, move_args=false`
调用它；该实例的反汇编中没有任何 memcpy 调用，唯一的 `bl memset` 与唯一的存储循环
都是 `index z0.d` 立即数模式填充（locals / padding），**源操作数不是内存**。

**裁决：argv 已经是 canonical borrowed 形态。按 §7.4，不为计划完整性重写。**

## 4. 台阶的真正来源：leaf 臂 vs 外联，两件事

基线里 argc 3→4 的 +7.06 ns 台阶**混淆了两个变化**：

```text
argc<=3 的被调函数是 leaf  → 走 exact-args leaf 快臂（另一套构造器）
argc>=4                    → 走 pushExactSimpleFrame（外联）
```

用**带一个 local 的被调函数**把 leaf 臂永久关掉，两侧就跑同一个构造器体：

| argc | `pushExactSimpleFrame` 命中 |
|---:|---:|
| 1 / 2 / 3 | 1（仅顶层） |
| 4 / 5 / 6 | 201 |

即 argc≤3 走 `pushExactSimpleFrameImpl`（**内联**），argc≥4 走
`pushExactSimpleFrame`（**外联 noinline 包装，转调同一个 Impl**）：

```zig
if (inline_exact) {
    return self.pushExactSimpleFrameImpl(false, false, false, global, target, source);
}
return self.pushExactSimpleFrame(false, false, false, global, target, source);
```

### 分离后的测量

| argc | qjs ns/次 | zjs ns/次 | delta | qjs 增量 | zjs 增量 |
|---:|---:|---:|---:|---:|---:|
| 1 | 27.73 | 33.59 | +5.86 | — | — |
| 2 | 28.23 | 34.41 | +6.18 | 0.51 | 0.82 |
| 3 | 28.84 | 34.90 | +6.06 | 0.61 | 0.49 |
| **4** | 29.42 | **38.90** | **+9.48** | 0.58 | **4.00** |
| 5 | 30.13 | 39.48 | +9.35 | 0.71 | 0.58 |
| 6 | 30.78 | 40.26 | +9.48 | 0.66 | 0.78 |

**台阶仍在，且为 +4.00 ns。** 原始 7.06 ns 中：

```text
4.00 ns  同一构造器体，内联 vs 外联           <- 纯调用边界成本
~3 ns    leaf 快臂比 exact-simple 构造器便宜   <- 既有特化的正常收益，不是缺陷
```

因为两侧是**逐字节相同的函数体、相同实参、相同语义**，唯一差别是
一次 `bl` 进入 1448 字节、208 字节原生帧的 noinline 函数。

### 这解释了为什么拆构造器内部阶段不会有帮助

线级采样确实能看到内部构成（prologue 4.48% + epilogue 2.85%，
`entry.stack = initArenaWindow` 4.03%，`entry.frame = .{…}` 一次性初始化合计约 7%，
`acquireSlot` 的 chunk 索引 0.87%，depth 记账 2.4%）。
但**这些阶段在 argc≤3 一侧一模一样地执行**。让函数体更便宜会同等地帮助两侧，
**关不掉这 4.00 ns**。

## 5. 对下一刀的影响

按 §「情况 B」，原计划是进入 `pushExactSimpleFrame` 内部分阶段。
上面的分离实验说明该方向**不能解释台阶**，因此建议改为：

```text
候选：让 OP_call 的 .operand 实例与 .one/.two/.three 一样内联同一个构造器体
      （inline_exact: .operand = false -> true）
```

需要说明为什么这不是「加宽 leaf bypass」：

- `inline_exact` 不选择路径、不改语义、不跳过任何工作，
  它只决定同一个 `pushExactSimpleFrameImpl` 是展开还是经由 `bl`；
- 快臂（`wire_exact_args_leaf` / `wire_padded_args_leaf`）保持不变，
  `.operand` 仍然不进入任何 leaf 家族；
- 满足基线 dossier 写下的证伪判据：**台阶收窄**（普通路径本身变便宜），
  而不是「只有 argc≥4 绕开了普通路径」。

真实代价是**文本增长**：现有注释明确写了这是刻意的取舍
（"The operand form and call0's non-leaf remainder keep the compact out-of-line
constructor so text growth stays on the measured hot instances"）。
`op_call` 会增加约 1.4 KB，因此该刀必须以 I-cache 敏感的 sentinel
（`fib_rec`、`method_call_loop`、`prop_read_mono_loop`、`local_arith_loop`）
判定，且要报告 `op_call` 与全二进制的 text 增量。

## 6. 3.1A 的位置

维持后置。两条 store（`return_action` / `continuation_payload`，偏移 253/248 相邻，
后端很可能合并为一次 8 字节存储）在本轮线级采样中没有形成可测份额，
且它们在内联与外联两侧同样执行 —— 与台阶无关。
按 §「3.1A 的位置」四项条件，当前只满足第 1 项（argv 无 copy），
第 2 项（Entry 初始化/store 占可测份额）不成立，因此不单独为它建立 P0/P1。

## 7. 方法学说明与限制

- 全部为动态计数与指针归属，未改源码；临时布局探针（`@compileError` 打印偏移）
  未进入提交；
- 每次成本含循环开销，`local_arith_loop` 显示 zjs 循环快于 qjs，故 delta 偏保守；
- 计数中的顶层 `run()` 噪声已逐列标注并扣除；
- 台阶分离实验只改被调函数体（加一个 local）以关闭 leaf 臂，
  调用点形态、参数个数、迭代数保持不变；
- 未测量 `call_arguments`（+47 ns/次）与 `call_throw`（+44 ns/次）的机制，
  两者按计划保持在退出线外。
