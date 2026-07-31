# P7-61：给 `op.lnot` 一个 immediate 快臂 —— 立即数赢 86–91%，complex 触发回退阈值

- 日期：2026-07-30
- 性质：**生产一刀（single-mechanism one-cut）**，已实施、已计量、**已按阈值回退**
- 基线：`97267596`（唯一基线；P7-60 / P7-41 的二进制一律不作 P0）
- 分支：`perf/qjs-align-p7-61-lnot-hot-handler`
- 一刀提交：`f09d89ef`　回退提交：`fe3aa198`
- 对照引擎：pinned Bellard QuickJS `04be2460`，sha256 `b76d1542…`（与 P7-20/40/41/42/60 同一文件）
- 依据：`P7-60-logical-not/`（频次与归因），`measurement-contracts.md`（九条陷阱）
- 数据产物：`P7-61-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/logical_not/`（新增 `run_ab.py` 四二进制轮转 A/B、`analyze_ab.py`、
  `run_purity.py` 动态纯度、`run_truthiness.py` 语义 oracle、`build_results_p761.py`、
  `truthiness_stmt_table.js` 语句上下文表、`sentinels/` 六个非目标哨兵）

## 1. 裁决

```text
decision = REVERT

pass:  immediate cycles/op   +86.1% .. +91.2%   (门槛 ≥60%，4/4 同向)
pass:  immediate insn/op     +80.9% .. +85.7%   (门槛 ≥50%)
FAIL:  complex types         −2.17% .. −5.64%   whole-case
                             −2.0%  .. −15.6%   marginal per-op
                             (门槛「无稳定回退 ≥1%」；两次独立扫描、4/4 组合复现)
pass:  product hot group     geomean +0.83%     (门槛 ≥0.5%)，3/4 同向改善(门槛 ≥3/4)
pass:  product 无单项回退 ≥1%  最差 zlib −0.07%
pass:  splay 中性哨兵         −0.04%（如预测，不是受益负载）
pass:  普通哨兵 6 项           最差 −0.71%，且落在该 case 自身 P0 双稳 1.19% 之内
pass:  动态纯度               immediate 冷命中 1→0，complex 冷命中逐格不变
pass:  语义 oracle            两张表 × 三种表示 × 66 行逐字节相同
pass:  全门禁                 test262 0/49775，perf-self-check 75/75
```

**只有一条不过，而它是回退条款。** 按交付契约「任何门槛不过则报告失败并回退，不得把数字
往下辩」，一刀已回退（`fe3aa198`），机制代码不入库。§7 给出坐实病因的证据与后继形状，
§8 单独说明为什么本文不把这条阈值当成可辩的。

## 2. 立项时记下的两个数（不是事后挪门槛）

协调者要求在动手前把「字面 40% 阶段判据不成立、但仍然立项」的算术写进档案，原样照录：

```text
max_individual_stage_share = 31%       // literal 40% test not met
cold_route_mechanism_delta = 18.3 cyc  // single-mechanism control, ~90% of total
decision = proceed
reason = multiple measured buckets are one routing protocol,
         not independently modified mechanisms
```

事后看，这个判断的**前半段被证实、后半段被证伪**：

- 证实：冷路由协议确实是唯一元凶。免掉它以后 immediate 从 20.3–22.1 cyc 掉到
  **1.63–3.01 cyc**，回收 18.5–19.1 cyc/次 —— 与 18.3 cyc 的单机制对照量几乎逐位吻合
  （P7-60 §6.1 事前给出的落点是「≈3 … 4.3 cyc」，实测 1.6–3.0，比上界还好）。
- 证伪：「一个改动一次性拿掉全部阶段」对 immediate 成立，对 complex **不成立**。
  complex 不但没少付任何阶段，还多付了一次进入协议的门票（§7）。

## 3. 计量身份

| 项 | 值 |
|---|---|
| P0-a sha256 | `06adaefa93cd04960fa40ae4d79f40934c094d56564eaf5a9dc9733c581c37e2` |
| P0-b sha256 | `72db63a0dcdb409105a89b0f1b46c34c3461836b900f2e19a5c05554981a82d6` |
| P1-a sha256 | `5d403fe212c2e135e72f4b8c5a0cbb3f0bea9f3fcd1fe4fb6f3d92d4c934cf8a` |
| P1-b sha256 | `3326ee9c75ce5a28bffd18b700ce8f2b8caf2e4aea38b521397cc318e02c0b34` |
| P1 nan-boxing sha256 | `8145d97fd47ac6e3dd0489d5a9bc46f46a1c039262fce5b0b8d992c4e630a4ea` |
| P0/P1 计数构建 sha256 | `c9e969d3e7e9…` / `2a839643af86…`（`-Dzjs_enable_opcode_profile=true` + 临时计数器；**从不用于任何计时数字**） |
| qjs sha256 | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |
| 核 / PMU | CPU 19（`armv8_pmuv3_1`），20 核 big.LITTLE，事件一律带 PMU 前缀，`<not counted>` 视为硬错误 |
| 锁 | 计时与 `perf stat` 取 `flock -x` + `taskset -c 19`；构建/测试取 `flock -s`；纯计数不取锁；`nm`/`objdump` 不取锁 |
| 采样周期 | 全程 `perf stat` 计数模式，**没有用过 `-F`**（合同第 2 条） |
| 轮转 | 每 case 一个独占窗口，窗口内四个二进制按 4 组轮转（`(0123)(3210)(1032)(2301)`），样本数取 4 的倍数，每个二进制占据每个位置的次数相同；`first_position_balanced: true` |

**四个二进制两两不同，本轮没有免费的噪声地板**（P7-31/P7-42 曾遇到某一侧逐字节相同的运气）。
噪声尺改用两项：①**同侧两次冷构建的差**（每张表都列了 `p0_spread` / `p1_spread`）；
②complex 组的**第二次独立扫描**（`C2`，见 §6.2）。

## 4. 一刀的内容

`op.lnot` 是唯一没有热 handler 的真值 opcode：`dispatch_table` 与 `cold_table` 两张表里
装的**是同一个** `coldStd` 壳（`tailcall_dispatch_colds.zig:309`），所以每一次 `!x` ——
包括两个引擎都不折叠的 `if (!x)` 形态 —— 都要走 `vm.publish` → `noinline logicalNot`
（Stack.pop/push，外加一次纯粹为了按指针传参而做的 JSValue 内存往返）→ `coldNext` 重新
派生 pc/sp，然后才轮到语义。

qjs 对同一个操作数是内联回答的（`quickjs.c:19092-19105`，逐字核对过）：

```c
CASE(OP_lnot):
    op1 = sp[-1];
    if ((uint32_t)JS_VALUE_GET_TAG(op1) <= JS_TAG_UNDEFINED) {
        res = JS_VALUE_GET_INT(op1) != 0;
    } else {
        res = JS_ToBoolFree(ctx, op1);
    }
    sp[-1] = JS_NewBool(ctx, !res);
```

加入的 handler：

```zig
pub fn op_lnot(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.asBranchImmediateBool()) |truthy| {
        (sp - 1)[0] = JSValue.boolean(!truthy);
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}
```

比 `op_if_false8` **故意更窄**：没有 plain-object 臂，因为 qjs 的 lnot 快臂也没有。
object / string / float / BigInt / symbol 全部原封不动落回既有冷 `logicalNot`，
pc 与 sp 都没碰过，冷 handler 从原始状态重新执行。

### 4.1 两件要求实测而不是照抄的事

**（一）操作数长度：`pc + 1`，从 opcode 表推导。** `bytecode.zig:517` 的
`.{ .name = "lnot", .size = 1, … }`，而 `.size` 是「opcode + 操作数」的总字节数
（同表 `if_false8` 是 2，`op_if_false8` 用的正是 `pc + 2`）。`opcode.sizeOf` 是公开访问器，
§5 的字节码钉子就用它逐 opcode 走码，所以这个 1 不是从邻居 handler 抄来的。

**（二）中断轮询：冷路由今天不轮询，因此热臂也不能加。** 三条独立证据：

1. qjs 的 `CASE(OP_lnot)` 里**没有** `js_poll_interrupts`；qjs 只在回边上轮询
   （`OP_goto` 18822-18826、`OP_if_*` 18881-18919）。lnot 不是回边。
2. zjs 的冷路由是 `coldStd` = `publish` → body → `coldNext`；`coldNext`
   （`tailcall_dispatch.zig:285`）只做越界检查、`maybeStop` 与重派发，**没有轮询**。
3. `op_if_false8` 的 immediate 臂里那句 `vm.ctx.pollInterruptTick()` 是它作为分支
   opcode 的义务，不是真值判断的义务。

所以本刀**没有**加轮询：加了就是新增语义而不是保留语义。

顺带钉死 `coldNext` 的另一项职责 `maybeStop` 对本 opcode **不可达**：
`stop_before_pc` 在生产里只可能是 0（`call_runtime.zig:5730` 是它唯一的非 null 来源），
而 `publish` 令 `frame.pc = offset(pc) + 1 ≥ 1`，`stopBeforePc` 又要求
`frame.pc == stop_pc` 才生效。因此热臂用 `cont` 跳过 `coldNext` 不会漏掉任何停靠边界，
也就不需要 `op_compare_cold` / `op_add_loc_cold` 那样的 `local_fast_blocked` 分流。

### 4.2 刻意没做的事

不加 plain-object 臂（哪怕 `op_if_false8` 有）、不加 HTMLDDA 处理、不内联完整 `ToBoolean`、
不动 `logicalNot` 的 `noinline`、不做条件上下文 `!x` peephole、不做 `!!x` 融合 opcode、
不加 branch hint、不加 `align(64)`、不重排热/冷表、不迁移任何其它一元 opcode。
目的是让 P0/P1 只回答一个问题：**immediate 的 `!` 该不该躲开冷路由。**

## 5. 字节码形态钉子（本刀唯一保留入库的部分）

`op.lnot` 一旦有专用 handler，「哪些语法形态真的会执行它」就变成承重结构。zjs 与 qjs
（`quickjs.c:27620`）都不做条件上下文取反折叠，`if (!x)` 照样执行一次 `OP_lnot`。
新增测试 `F4: `!` emits exactly one lnot; plain and comparison conditions emit none`
用 `opcode.sizeOf` 逐 opcode 走最终码（操作数字节可以是任意值，**按字节扫会误计**）：

| 形态 | `op.lnot` 数 |
|---|---:|
| `if (x) { … }` | **0** |
| `if (x !== 0) { … }` | **0** |
| `while (x) { … }` | 0 |
| `if (!x) { … }` / `while (!x)` / `for (; !x; )` | **1** |
| `u = !x;` | 1 |
| `u = !!x;` | **2** |

`if (x)` 与 `x !== 0` 的两个零是仪器的负向自检。**这一项在回退后保留**：它断言的是
parser 的事实而不是 handler 的事实，并且是 P7-60 频次普查继续有效的守卫。

## 6. 性能矩阵

### 6.1 合成 immediate：门槛 cycles ≥60% / insn ≥50%，4/4 —— PASS

每格是一对只差一个 `lnot` 字节的 case（`u = x` / `u = !x`，20 000 000 次），
per-op 取 `(k1 − k0) / iterations`，把循环脚手架差掉。四个组合逐一报，取最差。

| 操作数 | P0 cyc/op | P1 cyc/op | 最差组合 | 最好组合 | P0 insn/op | P1 insn/op | insn 最差 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `undefined` | 20.61 | **1.63** | **+91.2%** | +92.9% | 87.05 | **13.00** | +85.1% |
| `null` | 20.31 | **1.81** | **+90.3%** | +91.8% | 87.05 | **13.01** | +85.1% |
| `false` | 20.80 | **2.02** | **+90.2%** | +90.4% | 91.05 | **13.00** | +85.7% |
| `true` | 20.69 | **1.92** | **+90.7%** | +90.8% | 91.05 | **13.01** | +85.7% |
| `0`（int） | 21.96 | **2.95** | **+86.1%** | +87.0% | 94.05 | **18.01** | +80.9% |
| `7`（int） | 22.12 | **3.01** | **+86.3%** | +86.4% | 94.05 | **18.01** | +80.9% |

最差 **+86.1% cycles / +80.9% instructions**，门槛 60% / 50%，**24/24 组合同向**。
P7-60 事前推的落点是 3…4.3 cyc（上界来自 zjs 自己 `if_false8` 的内联臂），
实测 1.63–3.01，**比上界更好** —— 因为 lnot 不必付分支 opcode 那次 `pollInterruptTick`。

### 6.2 合成 complex：门槛「无稳定回退 ≥1%」—— **FAIL**

| 操作数 | P0 cyc/op | P1 cyc/op | marginal 最差 | whole-case 最差 | Δinsn/op |
|---|---:|---:|---:|---:|---:|
| `-0.0` | 20.78 | 22.16 | −8.1% | **−3.53%** | **+8.00** |
| `NaN` | 21.15 | 22.27 | −6.0% | **−2.75%** | **+8.00** |
| `1.5` | 21.25 | 22.73 | −9.9% | **−2.17%** | **+8.00** |
| `0n` | 20.95 | 22.67 | −10.1% | **−4.18%** | **+8.01** |
| `7n` | 24.68 | 25.95 | −5.3% | **−3.42%** | **+8.00** |
| 30 位 BigInt（堆） | 20.60 | 21.46 | −5.9% | **−3.54%** | **+8.00** |
| `""` | 21.43 | 22.82 | −12.8% | **−5.51%** | **+8.00** |
| `"abcdefgh"` | 21.95 | 22.75 | −5.9% | **−5.64%** | **+8.00** |
| 72 字节 string | 21.72 | 23.65 | −15.6% | **−5.41%** | **+8.00** |
| 140 000 字节 rope | 24.82 | 25.33 | −7.4% | **−3.44%** | **+8.00** |
| `Symbol("s")` | 18.51 | 20.25 | −12.6% | **−4.28%** | **+8.00** |
| `{a:1}` | 18.97 | 20.32 | −8.7% | **−3.92%** | **+8.00** |
| `[1,2]` | 18.51 | 20.68 | −13.1% | **−3.84%** | **+8.01** |
| `function` | 18.92 | 20.79 | −11.3% | **−3.87%** | **+8.01** |

**14 格全部回退，14 格全部超过 1%，两个口径都超过。** 换成更宽容的**中位组合**读法结论不变：
whole-case 中位落在 **−1.88% … −3.88%**，14 格全部仍 ≥1%。稳定性用三重方式钉住：

1. **同侧构建双稳**：whole-case 的 `p0_spread` / `p1_spread` 是 0.05%–3.77%，
   而跨侧差是 2.17%–5.64%，多数格远在双稳之外；
2. **四组合几乎全部同向**：14 格 × 4 组合 = 56 个组合里，whole-case **54 个为负**、
   marginal **55 个为负**，其中 **52 个 whole-case 组合回退 ≥1%**。三个非负组合全部是
   `p0b/p1b` 这一对，且全部落在三格最吵的 case 上（`t_string_long` / `t_string_short`
   的 P0 双稳是 3.08% / 2.16%，`t_string_rope` 是 1.47%）；这三格自身的 whole-case
   **中位**仍是 −2.61% / −2.53% / −1.89%。**表里报的是最差组合，不是中位**，
   所以 §6.2 的主表比中位更严；
3. **第二次独立扫描**（`C2`，另一次独占窗口、另一轮 8 样本）逐格复现：

| 操作数 | C1 marginal | C2 marginal | C1 whole | C2 whole |
|---|---:|---:|---:|---:|
| `{a:1}` | −7.1% | −8.4% | −3.92% | −4.20% |
| `"abcdefgh"` | −3.6% | −9.2% | −5.64% | −4.84% |
| `1.5` | −7.0% | −5.7% | −2.17% | −2.63% |
| `Symbol` | −9.4% | −10.3% | −4.28% | −4.08% |
| `7`（immediate 对照） | **+86.4%** | **+86.1%** | +39.3% | +39.0% |

**最硬的一条证据是指令数：14 格全部恰好 `+8.00`（rounding 到 +8.01 的三格是中位数取整）。**
这不是噪声也不是布局彩票，是一条确定性的机器码增量（§7）。

### 6.3 产品负载：门槛 ≥3/4 同向、geomean ≥0.5%、无单项回退 ≥1% —— PASS

Octane 派生负载按墙钟排程（P7-60 §2.4），**迭代次数不是常量，所以 cycles 不是度量**，
分数才是（越高越好）。四个二进制在同一独占窗口内轮转，四组合逐一报。

| 负载 | P0-a / P0-b | P1-a / P1-b | 最差组合 | 中位 | 最好组合 | 4/4 同向 |
|---|---:|---:|---:|---:|---:|---|
| `EarleyBoyer` | 2552 / 2570 | 2606 / 2586 | **+0.62%** | **+1.39%** | +2.16% | 是 |
| `Mandreel` | 1634 / 1634 | 1658 / 1648 | **+0.89%** | **+1.16%** | +1.44% | 是 |
| `MandreelLatency` | 11772 / 11662 | 11955 / 11828 | +0.48% | +1.49% | +2.52% | 是 |
| `RayTrace` | 1714 / 1729 | 1734 / 1738 | **+0.29%** | **+0.84%** | +1.40% | 是 |
| `zlib` | 3268 / 3265 | 3253 / 3276 | −0.46% | **−0.07%** | +0.32% | 否（平） |
| `Splay`（中性哨兵） | 5346 / 5362 | 5364 / 5340 | −0.40% | **−0.04%** | +0.33% | 否（平） |
| `SplayLatency` | 9168 / 9179 | 9186 / 9169 | −0.11% | +0.04% | +0.19% | 否（平） |

热组 geomean（`EarleyBoyer` / `Mandreel` / `RayTrace` / `zlib`）= **+0.829%**，门槛 0.5%；
3/4 同向改善，门槛 3/4；最差单项 `zlib` −0.07%，门槛 −1%。**三条全过。**

**`splay` 按预案是中性哨兵，实测 −0.04%，不是受益负载 —— 这一条预测被逐位证实**（§6.5）。

### 6.4 非目标哨兵：门槛「无稳定回退 ≥1%」—— PASS

| 哨兵 | 最差组合 | 最好组合 | P0 双稳 | P1 双稳 |
|---|---:|---:|---:|---:|
| `local_arith_loop` | −0.02% | +0.23% | 0.16% | 0.09% |
| `global_write_loop` | −0.59% | −0.25% | 0.21% | 0.13% |
| `prop_read_mono_loop` | −0.71% | +0.83% | **1.19%** | 0.34% |
| `fib_rec` | −0.16% | +0.01% | 0.08% | 0.10% |
| `call_body_loop` | −0.52% | +0.22% | 0.45% | 0.28% |
| **`if_false8_branch_loop`**（专设） | −0.46% | +0.01% | 0.44% | 0.03% |

`prop_read_mono_loop` 的 −0.71% 落在它**自己 P0 两次构建 1.19% 的差**之内，判为彩票。
专设的 `if_false8_branch_loop`（一亿次 int 操作数分支，**整段没有一个 `!`**）±0.46%，
与 §9 反汇编的「`op_if_false8` 函数体逐指令未变」互相印证。

### 6.5 用 P7-60 的操作数普查反算：模型与实测吻合到 0.03–0.27pp

把 §6.1/§6.2 的**每 tag 实测 Δcyc** 乘以 P7-60 §2.3 每个负载**自己的**操作数分布，
再除以该负载 cycles：

| 负载 | immediate 省下 | complex 多付 | 预测 | 实测（中位） | 差 |
|---|---:|---:|---:|---:|---:|
| `earley-boyer` | 387.4 M | 0.00 M | +1.62% | **+1.39%** | 0.23 pp |
| `mandreel` | 301.1 M | 0.00 M | +1.43% | **+1.16%** | 0.27 pp |
| `raytrace` | 100.8 M | 3.24 M | +0.81% | **+0.84%** | 0.03 pp |
| `zlib` | 276.0 M | 0.00 M | +0.15% | −0.07% | 0.22 pp |
| `splay` | 6.1 M | 9.82 M | **−0.04%** | **−0.04%** | 0.00 pp |

五个负载全部落在 0.27pp 以内，`splay`（语料里 object 操作数最多的负载，94.3%）逐位吻合。
**这条模型今后可以直接用来给同类候选定价，不必每次跑全套产品负载。**

`zlib` 的 0.15% 预测低于它自己的测量噪声（该负载四组合极差 0.78%），所以「实测 −0.07%」
不构成对模型的反证，只说明它的信噪比不足以分辨 0.15%。

## 7. 病因：`+8.00 insn/op` 是什么

不是推断，是从两侧反汇编逐指令读出来的。P1 的 `op_lnot`（0x48 = 72 字节，
`callconv(.c)`，**无栈帧**）：

```asm
op_lnot:
  ldur  x8, [x1, #-8]        ; 载入栈顶 tag
  cmp   x8, #0x3             ; qjs 的 (uint32_t)tag <= JS_TAG_UNDEFINED
  b.ls  .immediate
  ; ---- complex 落回，以下 5 条是本刀新增的过路费 ----
  ldrb  w8, [x0]             ; 重新读 pc[0]
  adrp  x9, cold_table
  add   x9, x9, #0xa08
  ldr   x4, [x9, x8, lsl #3] ; 第二次表载入
  br    x4                   ; 第二次间接派发 → 原来的 coldStd 壳
.immediate:
  ldur  x8, [x1, #-16]       ; payload
  cmp   x8, #0x0
  cset  w8, eq               ; !truthy
  mov   w9, #0x1             ; Tag.boolean
  stp   x8, x9, [x1, #-16]   ; 原地覆盖栈顶，sp 不动
  ldrb  w8, [x0, #1]!        ; pc + 1
  adrp  x9, dispatch_table
  add   x9, x9, #0x208
  ldr   x4, [x9, x8, lsl #3]
  br    x4                   ; 尾调下一 op
```

complex 路径 = 前 3 条（载入 tag、比较、未命中的分支）+ 后 5 条（重读 pc、两条地址生成、
表载入、间接跳） = **恰好 8 条**，与 14 格实测的 `+8.00 insn/op` 逐位对上。

**代价的实质不是那条比较，而是那次间接跳。** 从前 `dispatch_table[op.lnot]` 一跳就到冷壳；
现在要跳两次。P7-60 §5 早就量过同一现象的另一半：zjs 自己的 `if_false8` 内联时 4.3 cyc、
被路由进 `cold_table` 时 22.6 cyc。本刀等于给 complex 操作数**新装了一条冷路由的引道**。

代价的绝对值只有 **+0.51 … +2.17 cyc/次**（中位 +1.4）。它之所以在合成表里读作 2%–5.6%，
是因为那些 case 是 lnot 占约四成工作量的紧循环；§6.5 已给出它在真实负载里的落点。

## 8. 为什么本文不把这条阈值往下辩

`raytrace` 是语料里 immediate/complex 混合最典型的负载（74.6% / 25.4%），它的净值是
**+0.84%**；`splay`（94.3% object）是 **−0.04%**。也就是说本刀在**任何**实测负载上都没有
造成 ≥1% 的回退，产品侧的三条门槛全过。

但**「complex types: no stable regression ≥1%」是按合成口径写的回退条款，合成口径实测
−2.17% … −5.64%，稳定复现，不过就是不过。** 交付契约写得很清楚：门槛不过则报告失败并
回退，不得把数字辩下去 —— 这正是 P7-51A 之后立的规矩。本文因此：

- 裁决 **REVERT**，机制代码不入库（`fe3aa198`）；
- 把 §6.5 的加权模型当作**给协调者重新定价用的信息**，不作为对阈值的申诉；
- 把后继形状写在 §10，由协调者决定是否以修订后的判据重新立项。

## 9. 反汇编合同

| 要求 | 结果 |
|---|---|
| immediate 臂无 native frame | **满足**（`op_lnot` 无 prologue/epilogue，`nm` 类型 `t`，0x48 字节） |
| 无 call | **满足**（整个函数只有两条 `br`，都是尾调） |
| 无 Stack publish | **满足**（无 `frame.pc` / `stack.top_ptr` 写；`stp` 写的是栈顶 JSValue 本身） |
| 无 refcount | **满足**（immediate 四个 tag 都不是引用值，无 `free` / 无 tag 区间检查） |
| 形状 = 载入 → tag 测试 → payload 测试 → 造 boolean → 存栈顶 → 尾调 next | **满足**，逐条见 §7 |
| complex 落回仍是间接 `cold_table[pc[0]]` | **满足**（`adrp`+`add` 指向 `+0xa08` 的冷表，与热表 `+0x208` 是两张表） |
| 冷 helper 未被 LLVM 重新内联 | **满足**：`exec.vm_value.logicalNot` 在 P0 与 P1 里**都只有一个调用点**（`objdump | grep -c` = 1），符号仍在 |
| `op_if_false8` 函数体未被机械改动 | **满足**，见下 |

**「加一个热函数会扰动周边 codegen」这条前科本轮实测到的答案是「没扰动」。**
把地址与表偏移归一化后比对四个二进制的函数体：

| 符号 | 字节数（四建全同） | 归一化函数体 |
|---|---:|---|
| `op_if_false8` | 0x128 = 296 | 两个变体，且 **P0-a ≡ P1-b、P0-b ≡ P1-a** |
| `op_if_true8` | 0x130 = 304 | 同上配对 |
| `op_goto8` | 0x44 = 68 | 同上配对 |
| `op_drop_fast` | 0xf8 = 248 | 同上配对 |
| `op_update_loc` | 0x94 = 148 | 同上配对 |
| `op_add_loc` | 0xd8 = 216 | 同上配对 |
| `op_get_array_el` / `op_put_array_el` | 0x2fc / — | 同上配对 |
| `op_dup` | 0x54 = 84 | **四建完全相同** |
| `op_get_field` | 0x214 = 532 | **四建完全相同** |

**配对方式是关键读法**：每个 P1 构建的函数体都与某个 P0 构建**逐指令相同**，
两个变体的差别只是冷表间接跳那 4 条指令的调度顺序与 x9/x10 寄存器互换（指令数相同）。
也就是说这个二元变体是 **P0 自身就有的构建彩票**，不是本刀引入的。
`exec.vm_value.logicalNot` 的 0xd8 / 0xd4 两种尺寸同样在 P0 内部就出现（P0-a 0xd8、
P0-b 0xd4），因此也不能记在本刀账上。

文本增量：

| | P0-a | P0-b | P1-a | P1-b | 增量 |
|---|---:|---:|---:|---:|---:|
| dispatch unit 符号字节和 | 160 992 | 160 976 | 161 048 | 161 064 | **+72**（按变体配对，两边都恰好 +72） |
| `.text` 段 | 3 857 060 | 3 855 804 | 3 855 868 | 3 857 124 | +64（对齐填充差 8 B），占 **+0.0017%** |
| dispatch unit 符号数 | 286 | 286 | 287 | 287 | +1 |

**+72 字节 = `op_lnot` 自身的 0x48。一个字节也没多。**

### 9.1 替代表示（`-Dzjs_nan_boxing=true`）

本树默认是 16 字节 payload+tag 表示（`build.zig:21`，指针宽度 ≥64 走 qjs 的规范布局）——
**P7-60 §8.3 说「本树是 NaN-boxed 布局」是错的，在此更正**；NaN-boxing 是替代表示。
替代表示下 `op_lnot` 编译为 0x64 = 100 字节，immediate 臂同样**无帧、无调用、无 publish、
无 refcount**，只是 tag 判据换成 boxed prefix 的解码算术（`ubfx` + 3 条 `sub` + `cmp`），
complex 落回仍是间接 `cold_table`。`asBranchImmediateBool` 建在语义 `tagOf()`/`payloadOf()`
层上，两种表示共用同一份源码，实测两种表示的语义输出逐字节相同（§11）。

## 10. 动态纯度合同

计数用**默认关闭**的临时诊断计数器（`-Dzjs_enable_opcode_profile=true` 才编译进去，
运行时还要 `$ZJS_LNOT_PROBE_FILE` 才落盘），**从不用于任何计时数字**，已还原（§13）。
每个 case 跑两个迭代数（1000 / 3000）后**作差**，所以 harness、bootstrap、parser 的命中
全部抵消，剩下的恰好是每次 `!` 的账。

**先在「已知发生」的场景验证计数器，再信任零**（合同第 5 条）：P0 上先量到
`cold_body = 1.0000/op` 与 `logical_not = 1.0000/op`，P1 上先量到
`hot_entered = 1.0000/op`，然后才去读对侧的零。

### immediate（6 格）

| 阶段 | P0 | P1 |
|---|---:|---:|
| hot `op_lnot` | 0/op | **1/op** |
| `cold_table` lnot body | 1/op | **0/op** |
| `logicalNot` | 1/op | **0/op** |
| Stack publish / rehydrate | 1/op | **0/op** |

`undefined` / `null` / `false` / `true` / `0` / `7` 六格逐格如上，无一例外。
publish 与 rehydrate 与 `cold_body` 同计数：在 `coldStd` 里，`cold_body` 这个点严格在
`vm.publish(pc, sp)` 之后、`coldNext` 之前，三者是同一条直线上的三个点。

### complex（13 格）

| 阶段 | P0 | P1 |
|---|---:|---:|
| hot `op_lnot` | 0/op | **1/op**（新增的一次判据） |
| `cold_table` lnot body | 1/op | **1/op**（不变） |
| `logicalNot` | 1/op | **1/op**（不变） |

13 格：`-0` / `NaN` / `1.5` / `7n` / 堆 BigInt / `""` / `"abcdefgh"` / 真 rope /
`Symbol` / `{a:1}` / `function` / **throwing `valueOf`+`toString` 的对象** / **HTMLDDA**。

- **throwing-`valueOf` 格证明 `!object` 从不调用它**：那个 case 一旦被调用就会抛，
  而它 1000 / 3000 次全部正常返回，两侧输出相同。
- **HTMLDDA 只能由 `$262.IsHTMLDDA` 构造**，所以这一格是在 test262 runner 里跑的
  （同样做差），fixture 里同时断言 `!x === true`、`!!x === false`、循环 1000 次全部走
  falsy 分支 —— **特殊 falsy-object 语义保住了**。它落到冷路径是结构必然：HTMLDDA 是
  `Tag.object`，而本 handler 根本没有 object 臂。
- **没有 `+0` 的 float 格**：两个引擎都把整值正零归一回 int tag（P7-60 §3 实测），
  这一格在任何一侧都不存在；保留的是 `-0` / `NaN` / 非零 float。

## 11. 语义门禁

两张表 × 四个引擎，**全部逐字节相同**：

| 表 | 行数 | sha256 |
|---|---:|---|
| `truthiness_table.js`（`!x` / `!!x`，P7-60 的 oracle，一字未改） | 33 | `3bcdb8bd2417ccc81039ffd32053062317081b0f0a2222999dcf01fe95689716` |
| `truthiness_stmt_table.js`（新增：`if (!x)` / `while (!x)` / `for (; !x; )`，同样 33 形态） | 33 | `2c23fd97cee016df9a55b45a841ab6405f7fc12256cd74554ac7ab2e323d728f` |

四个引擎：**zjs P1 默认表示**、**zjs P1 `-Dzjs_nan_boxing=true`**、**pinned qjs `04be2460`**、
以及 **zjs P0**（对照）。33 形态覆盖 undefined / null / bool / int / float(`+0` `-0` `NaN`
`1.5` `Infinity`) / short 与堆 BigInt / 空串非空串 / 真 rope 与空 rope /
`{}` `[]` `new Number(0)` `new Boolean(false)` / throwing-`valueOf` 对象 /
function / arrow / Symbol / Date / RegExp / Proxy。

## 12. 全门禁（在一刀上跑，不是在回退后跑）

```
fmt clean / git diff --check clean
test-core       315   test-parser    464   test-bytecode  188   test-exec      403
test-builtins   195   test-runtime    72   test-runner     43   test-oom        20
ReleaseSafe(test-core)  315
force-GC(test-core)     315
test-altrepr           2022
test262-smoke   0/12 errors
test262-gate    0/49775 errors, passed 44541, known 25
perf-self-check 75/75 compatible, 0 validation failures, paired geomean 1.00
```

`test-parser` 从 463 涨到 464 就是 §5 的钉子。`test-runner` 第一次跑报 2 个 FileNotFound：
**本 worktree 的 `test262/` 子模块没有 checkout**（九个 worktree 全都没有），
用只读符号链接指向集成树 `/home/aneryu/zjs/test262/{harness,test}` 后 43/43 通过，
gitlink 未受影响（`git diff HEAD -- test262` 为空）。这是环境缺件，不是代码问题，
但**它意味着「本线之前在 worktree 里跑过 test262」的说法需要核对**，留档于此。

## 13. 临时插桩与还原

- 新增 `src/exec/lnot_probe.zig`（四个 `Site`、原子计数、`appendToFile`）
- `src/exec/root.zig` 导出一行
- `src/exec/tailcall_dispatch.zig` 两行 `hit(.hot_entered)` / `hit(.hot_immediate)`
- `src/exec/tailcall_dispatch_colds.zig` 一行 `hit(.cold_body)`
- `src/exec/vm_value.zig` 的 `logicalNot` 一行 `hit(.logical_not)`
- `src/cli/zjs.zig` 与 `src/cli/run_test262.zig` 各一段 `atexit` 落盘

**全部已还原。** `git diff 97267596 -- src/` 现在只剩 `src/tests/parser.zig` 的 30 行钉子。
计数构建的 sha256 记在 §3，**没有任何 cycles / instructions 数字出自它们**：
性能表全部来自四个干净冷构建。全程未用 `git stash`，未为制造符号强加 `noinline`
（`logicalNot` 的 `noinline` 是基线自带的），未改任何已对齐 handler 的 `noinline` 属性。

## 14. 本条线没有建立的东西

1. **没有量过「直接尾调专用冷 handler」的变体。** §15 的后继形状是从 `+8.00 insn` 的
   来源推出来的，一行代码都没写、一个数都没测。仓库里 `op_add_loc` 对 `op_add_loc_cold`
   正是直接尾调，但同一份注释也记着 `op_compare_cold` 走直接尾调时**热臂 codegen 被扰动**
   （`s=s+i` 每轮 +37 insn）—— 所以这个方向是**有前科的**，必须自己测。
2. **没有拆开那 +1.4 cyc。** 已证它对应 8 条固定指令，但「第二次间接跳里有多少是 BTB、
   多少是表载入延迟」没量；没采 `br_mis_pred_retired`，没用 ARM SPE。
3. **没有测 `-Dzjs_nan_boxing=true` 的性能。** 替代表示只过了语义门禁与反汇编检查
   （§9.1），一个计时数字都没有。
4. **产品语料仍只有 Octane 派生负载。** 没有 Node 应用、没有 minified bundle。
   压缩器偏爱 `!x` / `!!x`，真实前端代码里 immediate 占比可能更高，本线**不能**据此外推。
5. **`zlib` 的信噪比不足以验证 0.15% 的预测。** 该负载四组合极差 0.78%，预测值 0.15%
   落在噪声里；「实测 −0.07%」既不能证实也不能证伪模型。
6. **没有为 complex 回退做过负载级的直接证据。** §6.5 的 `splay −0.04%` 是加权模型与
   分数测量的吻合，不是对 complex 那一格单独下探针得到的。
7. **没有跑 `--engine qjs` 侧的对照 A/B。** 本线全部是 zjs P0 对 zjs P1；
   qjs 只在语义 oracle 里出现。
8. **没有验证非 aarch64 平台。** 全部数字来自本机 CPU 19。

## 15. 后继形状（供协调者定价，不是本线的主张）

`+8.00 insn/op` 全部来自「热 handler 未命中后再间接跳一次到冷壳」。仓库里已有一种
消掉它的既成写法：给 lnot 一个**专用冷 handler**（形如 `op_lnot_cold`），把
`coldStd` 的 publish 壳与 `logicalNot` 的 body 合成一跳（`op_add_loc_cold` 的做法，
其注释写明动机正是「少跨一次 noinline 调用边界」），并让热臂**直接尾调**它。
若成立，complex 的账会从「多 8 条指令、多一次间接跳」变成「多一条比较、少一层调用边界」，
方向可能反号。

三条必须自己测、不能假定的事：

1. **直接尾调有前科**：`op_compare_cold` 的注释记录了直接路由让 int32 热臂
   每轮多 37 insn。必须当轮验证热臂 codegen 没被扰动（§6.1 的 immediate 表就是判据）。
2. **`logicalNot` 的 `noinline` 是基线自带的**，合成一跳等于改它的角色，
   需要重新确认它在别处（如果有）的调用点。本线实测全二进制只有一个调用点。
3. **complex 的收益上限只有约 1.4 cyc/次**，按 §6.5 的模型换算，在语料里最多值
   `splay` 的 0.04%。**这是一个语义整洁性的改动，不是一个性能改动** —— 除非协调者
   打算连同其它被冷路由的 opcode 一起做（P7-60 已给出 +88 insn / +18.3 cyc 的通用冷路由税，
   可直接用来排序候选）。

另一条更省事的路线：**修订 complex 判据的口径**。若把「无稳定回退 ≥1%」改为按语料加权
（§6.5 的模型已证吻合到 0.27pp），本刀四条产品门槛全过、最差实测负载 `splay` −0.04%，
就能以 geomean +0.83% 入库。**这个选择权在协调者，不在本线。**

## 附：`raw/` 里文件名的含义

| 文件 | 用途 |
|---|---|
| `P7-61-matrix-immediate-M1.json` | 6 个 immediate 格的 k0/k1 对（8 样本 × 4 二进制轮转） |
| `P7-61-matrix-complex-C1.json` | 14 个 complex 格的 k0/k1 对，第一次扫描 |
| `P7-61-matrix-confirm-C2.json` | 5 格（4 complex + 1 immediate 对照）第二次独立扫描，噪声尺 |
| `P7-61-product-fast-PROD1.json` | `earley-boyer` / `mandreel` / `raytrace` / `splay`，8 样本 |
| `P7-61-product-zlib-PROD2.json` | `zlib`（单次 47 s），4 样本 |
| `P7-61-sentinels-SENT1.json` | 六个非目标哨兵，含专设的 `if_false8_branch_loop` |
| `P7-61-purity-P0.json` / `-P1.json` | 动态纯度矩阵（19 格，含 HTMLDDA 与 throwing-`valueOf`） |
| `P7-61-truthiness.json` + `truthiness*-{zjs_p1_default,zjs_p1_nanboxing,qjs_04be2460,zjs_p0_default}.txt` | 语义 oracle 与四份逐字节相同的输出 |
