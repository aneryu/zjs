# P7-60：`op.lnot` 的类型语义矩阵、频次普查与归因边界

- 日期：2026-07-30
- 性质：**仅剖析（profiling-only）**，不改生产代码，止于裁决
- 基线：`ab4fc64b`，分支 `perf/qjs-align-p7-logicalnot`
- 对照引擎：pinned Bellard QuickJS `04be2460`，二进制 sha256 `b76d1542…`（与 P7-20 / P7-40 / P7-41 / P7-42 同一文件）
- 依据：`candidate-register.md` 的 P7-60 条目（来源 `P7-41-builtin-bridge.md` §2.4 的意外探针）
- 数据产物：`P7-60-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/logical_not/`（`gen_cases.py` 62 个 case、`run_matrix.py` ABBA 计时、
  `run_census.py` 频次/周期普查、`run_stage_record.py` 定周期 per-symbol 归因、`analyze.py`、
  `build_results.py`、`corpus.json` 语料声明、`truthiness_table.js` 正确性边界表）
- `git diff ab4fc64b -- src/` ：**空**（临时计数器已还原，见 §9）

## 0. 计量身份（每个报数都出自这一套）

| 项 | 值 |
|---|---|
| 基线 commit | `ab4fc64b`（唯一基线；P7-41 的 18.17 / 3.06 只作复现对象，不作本线 P0） |
| zjs 冷缓存构建 A1 sha256 | `402c921dd738bea1da11b1365393f8a73dceefcf2ca0f5b1b6e59fd615a9a264` |
| zjs 冷缓存构建 A2 sha256 | `402c921dd738bea1da11b1365393f8a73dceefcf2ca0f5b1b6e59fd615a9a264` |
| 两次冷构建是否逐字节相同 | **是** |
| 计数专用构建 sha256 | `df2021a94afb384457d6c434764b57881c4fc393d9d1c53c51d89921c36c64a9`（`-Dzjs_enable_opcode_profile=true` + 临时计数器；**从不用于任何计时数字**） |
| qjs sha256 | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |
| 核 / PMU | CPU 19（`armv8_pmuv3_1`），20 核 big.LITTLE，事件一律带 PMU 前缀 |
| 计时与 `perf record` | `flock -x` + `taskset -c 19`；构建取 `flock -s`；纯计数不取锁（P7-51A 先例）；`nm` / `objdump` 不取锁 |
| ABBA | 每 case 每引擎 6 个样本，`first_position_balanced: true`（三份计时采集件全为真） |

**A1 与 A2 逐字节相同**，所以本树没有构建 bistability 可报（与 P7-42 同一情形）。噪声尺改用
**同一源码上两次独立的完整计时扫描**（A1 / T2，各自 6 样本 ABBA、各自独占锁）：21 个类型格的
`zjs − qjs` 每事件差两次复现极差 **0.02 … 1.42 cyc**（中位 0.36），纯 boolean 斜率复现极差
**0.10 cyc**。**顺带记一个坑**：同一源码的**暖缓存**构建给出 `32a7b010…`，与两次冷构建的
`402c921d…` 不同 —— 本线所有数字只用冷构建，暖构建产物只作对照留档。

## 1. 裁决

```text
Decision:
    genuine unfaithful divergence, and NOT dynamically cold:
    op.lnot carries 0.08 % .. 1.53 % of cycles in the 11 product workloads
    that hit it more than 1e5 times per run,
    with 1.53 % / 1.35 % / 1.03 % in three unrelated ones.
    The cost is the cold-dispatch protocol, not ToBoolean (1.58 of ~20 cyc).
    → escalate.  One-cut shape = qjs-shaped immediate fast arm in a hot handler
      (the action of option C), using zjs's own asBranchImmediateBool.
      Caveat: by the literal "largest stage >= 40 %" test the answer is D; §6.3
      argues the test's premise (independently removable stages) does not hold here.
```

三个头条数字：

| | 值 |
|---|---:|
| 每事件 `zjs − qjs`（immediate 操作数，21 格矩阵、两次扫描） | **+18.00 cyc / +73 insn** |
| 绝对最大贡献（`earley-boyer`，20 626 333 次 × 加权 17.69） | **364.9 M cycles = 该负载 1.53%** |
| `ToBoolean` 语义本身在这笔成本里的份额（immediate） | **1.58 / ≈20 cyc = 7%** |

**与 P7-51A 的对照就是本线的意义。** 同样形状的立项（忠实偏差已核验、单事件成本高），
P7-51A 在 170 个语料条目里只数到 6 次而关闭；P7-60 在同一套语料上数到的是
**每 Mcycle 47 … 863 次、单负载最高 2 千万次**，且 16 个产品型负载全部非零、11 个每轮超过 10⁵ 次。

## 2. 频次先行：`op.lnot` 在代表性语料里的执行次数

### 2.1 先确认「什么语法形态真的执行 `op.lnot`」

协调者的第一条修正是对的方向，但对 zjs 的结论是反的，必须先钉死：**zjs 没有条件上下文的
取反 peephole**，`if (!x)` 照样执行一次 `op.lnot`。用临时 tag 计数器逐形态实测（每形态 1000 次求值）：

| 形态 | 每次求值的 `op.lnot` 次数 |
|---|---:|
| `u = !x` / `return !x` / `!x ? a : b` / `t + (!x ? 1 : 0)` | 1 |
| `if (!x) {…}` / `while (!x)` / `for (; !x; )` / `do {…} while (!x)` | **1** |
| `x && !y` / `!x \|\| y` / `!(a < b)` / `if (!o.p)` | 1 |
| `u = !!x` | **2**（第一次操作数是原类型，第二次是 boolean） |
| `if (x) {…}` | 0 |
| `x !== 0` | 0 |

代码侧一致：`parser.zig:7246` 对 `!` 无条件 `emitOp(op.lnot)`，全 `src/` 里 `lnot` 只出现在
parser 的这一处与 `bytecode.zig` 的表定义，`resolve_labels` 不重写它。qjs 同构：`OP_lnot`
在 `quickjs.c` 里只出现于 19092（解释器臂）与 27620（`js_parse_unary` 发码），`resolve_labels`
也不重写。**两个引擎都不做条件上下文取反折叠**，所以两侧计的是同一件事。

`x !== 0` 计到 0 是仪器的负向自检；正向自检是上表每一行都恰好等于设计次数（1000 / 2000）。

### 2.2 语料与计数

计数用临时计数器构建，每条目独立进程跑一次，进程退出时 `atexit` 把总数与
**按操作数 tag 分桶**的分布追加到 `$ZJS_LNOT_CENSUS_FILE`。**只计数、不计时，未占独占锁。**

| 组 | 条目数 | 含 `op.lnot` 的条目 |
|---|---:|---:|
| `microbench`（`tools/compare/microbench_cases.js` 抽出的 75 个 case） | 75 | **0** |
| `named_eval`（P7-50 的 NamedEvaluation 形态 + bootstrap） | 3 | **0** |
| `bootstrap`（纯 runtime 起停、以及轻触每个 builtin 家族） | 2 | **0** |
| `p0_sentinel`（`tools/perf/same_runtime/cases`，含 call / property / string / bigint / closure 热 case） | 48 | **0** |
| `wrapped`（P7-41 的七个 Array builtin workload + P7-50 闭包矩阵 + 各热 case） | 96 | 5 |
| `product`（`gbemu` + `javascript-zoo/bench` 的 15 个 Octane 派生负载） | 16 | **16 非零，其中 11 个 >10⁵ 次** |

`wrapped` 里那 5 个非零条目**全部就是 P7-41 为隔离 `!` 而写的探针本身**
（`n_neg` / `c_every` / `perf_c_every` / `count_c_every`，各 100% boolean 操作数），
外加 `closure_identity_probe` 的每进程常量 7 次。这一组不作产品频次证据。

`wrapped` 里有 2 个条目（`baseline` / `count_baseline`）在两个引擎上都 `ReferenceError`
退出 —— 这是继承自 P7-51A 语料生成的既有破损（`print(0); print(run())`，`run` 未定义），
不是本线引入；两者都在报错前已经执行过 `print`，因此不可能藏住 `op.lnot`。

### 2.3 产品型负载：`op.lnot` 一点都不冷

计数两轮独立复现（第二轮与 `perf stat` 同进程），`count2/count1` 比值 **1.000**（`code-load`
0.985、`deltablue` 1.006、`splay` 1.001、`gbemu` 因 Octane 按墙钟排程而在 1.25 —— 见 §2.4）。
分母取干净 A1 构建的 `perf stat` 总 cycles（与计数构建相差 ≤1.5%）。

每事件差按**该负载自己的操作数 tag 分布**加权（§3 的 per-tag 表），不是拿一个数乘全部：

| 负载 | `op.lnot` 次数 | immediate 操作数占比 | 加权 `zjs−qjs` cyc/次 | 估计超额 cycles | 占该负载 cycles |
|---|---:|---:|---:|---:|---:|
| `earley-boyer` | 20 626 333 | 100.0% | 17.69 | **364.9 M** | **1.527%** |
| `mandreel` | 16 034 159 | 100.0% | 17.69 | **283.7 M** | **1.347%** |
| `raytrace` | 7 091 133 | 74.6% | 17.39 | **123.3 M** | **1.026%** |
| `splay` | 5 776 055 | 5.7% | 12.97 | 74.9 M | 0.774% |
| `typescript` | 5 673 591 | 85.9% | 17.09 | 97.0 M | 0.320% |
| `zlib` | 14 481 087 | 100.0% | 19.02 | 275.5 M | 0.151% |
| `box2d` | 335 842 | 98.3% | 17.93 | 6.0 M | 0.138% |
| `deltablue` | 511 022 | 100.0% | 17.69 | 9.0 M | 0.115% |
| `gbemu` | 284 209 | 100.0% | 17.69 | 5.0 M | 0.102% |
| `pdfjs` | 586 994 | 80.4% | 17.31 | 10.2 M | 0.204% |
| `code-load` | 15 129 | 95.6% | 18.57 | 0.28 M | 0.004% |
| `crypto` / `navier-stokes` / `regexp` / `richards` | 2 … 6 | — | — | ~0 | 0.000% |

**操作数类型分布是本线最有用的副产品**：真实代码里 `!` 的操作数几乎全落在
qjs 用内联算术臂覆盖的那四个 immediate tag 上。

| 负载 | boolean | int | null | undefined | object | string | float64 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `earley-boyer` | 20 626 384 | | | | | | |
| `mandreel` | 16 034 155 | | | 2 | 2 | | |
| `zlib` | 7 824 | 14 473 229 | 2 | 4 | 19 | 9 | |
| `raytrace` | 105 435 | 5 182 659 | | | 1 802 004 | | 1 035 |
| `splay` | 3 | | 328 960 | | 5 455 475 | | |
| `typescript` | 4 318 131 | 455 570 | 74 555 | 25 987 | 799 313 | 35 | |
| `pdfjs` | 387 182 | 40 850 | 1 245 | 42 421 | 17 006 | 98 290 | |
| `box2d` | 247 642 | 82 410 | 10 | | 5 780 | | |
| `gbemu` | 284 149 | 25 | 5 | 5 | 25 | | |

`splay` 是唯一以 object 操作数为主的负载（94.3%）—— 这一格 qjs 自己也要付
`JS_ToBoolFree` 调用，所以它的 0.774% 里只有 0.055% 落在「qjs 忠实 immediate 快臂」的射程内。
这一点必须写进任何一刀的验收预期，不能拿 `splay` 当受益负载。

### 2.4 关于 Octane 派生负载的按墙钟排程

`javascript-zoo/bench/*.js` 是 Octane 的自包含单测，`BenchmarkSuite` 按最小墙钟时长排程，
迭代次数因此不是常量。这带来两个后果，都已处理：

1. 计数与分母**取自同一个进程**（`run_census.py --mode cycles` 在计数构建上同时拿
   `perf stat` 的 cycles 和计数器输出），所以「占该负载 cycles 的比例」是自洽的比率，
   不受迭代次数漂移影响。
2. `gbemu` 与 `gbemu_product` 是**同一个文件**（`cmp` 逐字节相同），两次计数 227 332 / 284 209
   的差正是这个排程漂移的量级（±25%），不是两个不同负载。表里两行都保留，不藏工件。

## 3. JS 类型语义矩阵

case 形状：操作数在循环外**只读一次**存进局部 `x`（数组字面量供源，杜绝两个引擎的解析期折叠），
循环体 20 000 000 次。每格是一对 case，字节码只差一个 `lnot` 字节：

```javascript
u = x;      // k0
u = !x;     // k1
```

对非引用计数类型（bool / int / float64 / undefined / null）这一对**没有任何不对称**；对引用
计数类型，`k0` 的 `put_loc u` 释放上一轮的引用，`k1` 在 `lnot` 内部释放，各一次 dup 各一次 free。

**每格的操作数 tag 都用临时计数器实测过，不是假定的**（`double_pos_zero` 实测落在 `int`，
见下）。表值是 A1 与 T2 两次独立扫描的均值：

| 操作数（实测 tag） | qjs insn | qjs cyc | qjs IPC | zjs insn | zjs cyc | zjs IPC | **Δcyc** | 两扫描极差 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `false`（boolean） | 18.01 | 2.92 | 6.2 | 91.05 | 20.24 | 4.5 | **+17.32** | 0.02 |
| `true`（boolean） | 18.01 | 2.93 | 6.2 | 91.05 | 20.99 | 4.3 | **+18.06** | 0.29 |
| `0`（int） | 18.01 | 2.89 | 6.2 | 94.05 | 22.02 | 4.3 | **+19.14** | 0.28 |
| `7`（int） | 18.01 | 2.94 | 6.1 | 94.05 | 21.78 | 4.3 | **+18.85** | 0.17 |
| `+0.0` → **归一成 int** | 18.00 | 2.91 | 6.2 | 94.05 | 21.99 | 4.3 | **+19.09** | 0.38 |
| `undefined` | 18.01 | 2.69 | 6.7 | 87.05 | 20.33 | 4.3 | **+17.64** | 0.32 |
| `null` | 18.01 | 2.91 | 6.2 | 87.05 | 20.56 | 4.2 | **+17.65** | 0.45 |
| `-0.0`（float64） | 48.01 | 6.32 | 7.6 | 95.05 | 20.69 | 4.6 | **+14.37** | 0.66 |
| `NaN`（float64） | 48.01 | 6.02 | 8.0 | 97.05 | 21.14 | 4.6 | **+15.12** | 0.19 |
| `1.5`（float64） | 48.01 | 6.36 | 7.6 | 97.05 | 21.04 | 4.6 | **+14.69** | 0.40 |
| `""`（string） | 42.01 | 5.67 | 7.4 | 113.05 | 21.30 | 5.3 | **+15.63** | 0.27 |
| `"abcdefgh"`（string） | 42.01 | 5.37 | 7.8 | 113.05 | 21.06 | 5.4 | **+15.69** | 0.43 |
| 72 字节 string | 42.01 | 5.33 | 7.9 | 113.05 | 21.18 | 5.3 | **+15.85** | 0.44 |
| 140 000 字节 **string_rope** | 38.01 | 4.89 | 7.8 | 137.06 | 24.19 | 5.7 | **+19.29** | 单扫描 |
| `{a:1}`（object） | 41.01 | 5.91 | 6.9 | 92.04 | 18.36 | 5.0 | **+12.45** | 0.61 |
| `[1,2]`（object） | 41.01 | 5.87 | 7.0 | 92.04 | 18.92 | 4.9 | **+13.05** | 0.22 |
| `function`（object） | 41.01 | 5.86 | 7.0 | 92.04 | 18.41 | 5.0 | **+12.56** | 0.33 |
| `0n`（short_big_int） | 41.01 | 5.02 | 8.2 | 108.05 | 20.82 | 5.2 | **+15.80** | 0.18 |
| `7n`（short_big_int） | 41.01 | 5.04 | 8.1 | 115.06 | 24.95 | 4.6 | **+19.90** | 0.29 |
| 30 位 BigInt（big_int，堆） | 42.02 | 5.79 | 7.3 | 110.05 | 19.90 | 5.5 | **+14.11** | 0.74 |
| `Symbol("s")` | 41.01 | 4.78 | 8.6 | 95.04 | 18.32 | 5.2 | **+13.54** | 0.35 |

四条要读出来的：

1. **qjs 的行为完全按 `quickjs.c:19096` 的 tag 判据分成两档**：`(uint32_t)tag <= JS_TAG_UNDEFINED`
   的四个 tag 走 18.0 insn 的纯内联算术臂（2.7–2.9 cyc），其余全部走 `JS_ToBoolFree`
   调用（38–48 insn，4.8–6.4 cyc）。`+0.0` 落在快臂里是因为 `JS_NewFloat64` 把整值正零归一回
   int tag —— zjs 也归一（实测 tag 为 `int`），**所以「`+0` 走 float64 臂」这一格在两个引擎里
   都不存在**，本表把它标成受控对照而不是 float 格。
2. **zjs 是一条平线**：87–137 insn、18.3–25.0 cyc，**与操作数类型基本无关**。IPC 4.3–5.7
   对 qjs 的 6.1–8.5。
3. **差值最大的恰恰是 qjs 有内联臂的那四个 tag**（+17.3 … +19.1），最小的是 qjs 也要付调用的
   object / symbol（+12.5 … +13.5）。这条单调关系本身就是归因证据（§6）。
4. **最贵的一格是真 rope**（24.19 cyc / 137 insn）。注意：短串拼接会被压平成 `Tag.string`；
   本表的 rope 格是用 `"x".repeat(70000) + "y".repeat(70000)` 造的，并用 tag 计数器确认过
   落在 `Tag.string_rope`。

### 3.1 `!` 与 `!!`、以及「立即消费」与「先存槽」

| 形状 | 口径 | qjs cyc | zjs cyc | Δ |
|---|---|---:|---:|---:|
| 单个 `!`，结果**存局部槽** | `t_int_nonzero_k1 − k0` | 2.94 | 21.79 | +18.85 |
| 单个 `!`，结果**立即被分支消费** | `r_int_nonzero_lnot − r_int_nonzero_if` | 3.27 | 20.40 | +17.13 |
| 追加的 `!`（`!!` 的第二个，操作数是 boolean，串行依赖链） | `s_bool_k{1..4}` 斜率 | 4.69 | 17.65 | +12.96 |

三个口径都在 +13 … +19 的带里。**串行链口径的 qjs 值（4.69）比吞吐口径（2.94）高 1.75 cyc，
zjs 几乎不动** —— 因为 qjs 的快臂是 3 条 ALU 指令，在有空隙时被乱序藏住、在依赖链里就露出
延迟；zjs 走的是串行的冷调用，本来就没有可藏的空隙。这解释了为什么 P7-41 那个探针
（分支消费口径）报 3.06，而本线的存槽口径报 2.94、串行口径报 4.69：**三个数都对，口径不同。**

### 3.2 复现 P7-41 的原始探针

P7-41 §2.4 的 `n_plain` / `n_neg` 是分支消费口径。本线在 `ab4fc64b` 上重测同一形状
（`r_bool_true_if` / `r_bool_true_lnot`）：

| | P7-41（`0e4ee496` 前的树、诊断探针） | 本线（`ab4fc64b`、6 样本 ABBA ×2 扫描） |
|---|---:|---:|
| `lnot` 每次 instructions，qjs / zjs | 17.998 / 91.067 | **18.01 / 91.05** |
| `lnot` 每次 cycles，qjs / zjs | 3.061 / 18.165 | **3.13 / 20.27** |

指令数逐位复现，cycles 高出 2.1（zjs 侧）。**原登记的 18.17 vs 3.06 成立**，本线把它换成
按采样纪律测出的 20.27 vs 3.13，并把后续所有绝对贡献都算在 §3 的 per-tag 表上。

## 4. 机制：两侧代码逐行对照

**qjs**（`quickjs.c:19092-19105`）：

```c
CASE(OP_lnot):
    op1 = sp[-1];
    if ((uint32_t)JS_VALUE_GET_TAG(op1) <= JS_TAG_UNDEFINED) {
        res = JS_VALUE_GET_INT(op1) != 0;          /* 纯算术，无调用 */
    } else {
        res = JS_ToBoolFree(ctx, op1);             /* 与 OP_if_true/false 共用 */
    }
    sp[-1] = JS_NewBool(ctx, !res);
```

**zjs**：`op.lnot` 只在 `src/exec/tailcall_dispatch_colds.zig:309` 注册，且注册进的是
`h(...)` → `coldStd(...)` 协议（符号 `exec.tailcall_dispatch.coldStd__struct_69769.h`），
没有任何快 handler。全 `src/` 里 `t[op.lnot]` 只有这一处赋值，`cold_table` 与 `dispatch_table`
（`tailcall_dispatch.zig:4117` / `:4235`）由同一个 `buildTable` 生成，因此**两张表里 lnot 都是这个冷 handler**。

从反汇编读出来的实际链条（int 操作数，91–94 insn）：

```
coldStd__struct_69769.h              [callconv(.c), 64B 帧, 保存 x30/x19-x22]
├─ vm.publish(pc, sp)                  frame.pc 重算 + stack.setTopPtr
├─ bl exec.vm_value.logicalNot       [noinline, 唯一调用点]
│  ├─ stack.pop()                      栈下溢检查 + top 回写
│  ├─ str q0,[sp] ; ldp x20,x21,[sp]   ← JSValue 落栈再读回，只为按指针传参
│  ├─ bl core.value_semantics.toBoolean  ← 第二层 out-of-line 调用
│  │  └─ ldp x1,x2,[x0]                  ← 从上一步刚写的栈槽读回（store→load forwarding）
│  ├─ stack.pushOwnedAssumeCapacity      两次重复 load stack.top
│  └─ 操作数 free：tag 区间检查 + refcount 递减
└─ coldNext(vb, vm)                    byteCode().len 重取 + maybeStop + pc 重算
                                       + stack.topPtr 重取 + 间接 tail-call
```

对比 zjs **自己**的 `op_if_false8`（`tailcall_dispatch.zig:3771`）：它用
`JSValue.asBranchImmediateBool()`（`value.zig:450`）内联处理 immediate，用
`isObject()` 内联处理普通对象，只有需要完整 `ToBoolean` 的值才 `cold_table[pc[0]]`。
**而 `asBranchImmediateBool` 已经是 `quickjs.c:19096` 那一行的逐字镜像**：

```zig
pub inline fn asBranchImmediateBool(self: JSValue) ?bool {
    const tag: u32 = @bitCast(self.tagOf());
    const last_immediate: u32 = @intCast(Tag.undefined_value);
    if (tag > last_immediate) return null;
    return self.payloadOf() != 0;
}
```

也就是说：**zjs 已经有这条判据、已经在别的 opcode 上用着，只是 `lnot` 没用。**

## 5. 归因边界（一）：用 zjs 自己的分支 opcode 做同语义对照

这是本线最强的一组证据，因为它把「`ToBoolean` 贵」与「冷路由贵」放在**同一个引擎、同一个
opcode、同一套语义**上分开。分支族每格三个 case：`none`（无真值测试）、`if`（`if (x) t=t+1`）、
`lnot`（`if (!x) {} else t=t+1`），差分给出每次迭代的增量：

| 操作数 | zjs `get_loc+if_false` insn | zjs cyc | zjs 走的腿 | qjs insn | qjs cyc | qjs 走的腿 |
|---|---:|---:|---|---:|---:|---|
| boolean | 33.02 | **4.33** | 内联 immediate 臂 | 40.02 | 5.45 | 内联算术臂 |
| int | 33.02 | **4.29** | 内联 immediate 臂 | 40.01 | 5.12 | 内联算术臂 |
| object | 51.02 | **7.47** | 内联 object 臂 | 73.02 | 9.31 | `JS_ToBoolFree` 调用 |
| float64 | 121.05 | **22.59** | **`cold_table` 路由** | 72.02 | 8.54 | `JS_ToBoolFree` 调用 |
| string | 150.06 | **28.74** | **`cold_table` 路由** | 74.02 | 9.11 | `JS_ToBoolFree` 调用 |

读法：

- zjs 的**同一个 `if_false8` opcode**，做同一件真值判断，内联时 33 insn / 4.3 cyc，
  被路由进 `cold_table` 时 121 insn / 22.6 cyc。**冷路由附加税 = +88 insn / +18.3 cyc。**
- `op.lnot` 的**全部**成本是 91 insn / ≈20 cyc。也就是说 `lnot` 的成本几乎**就等于**
  「一次冷路由」这一件事，与它算的是什么语义无关。
- 反向确认：`ToBoolean` 语义本身在 zjs 里不贵 —— 对象真值判断（`isHTMLDDA` → `refHeader`
  → flags）内联跑只要 7.47 cyc，比 qjs 的 9.31 还便宜。
- qjs 侧的对照量级也值得记：qjs 从内联臂掉到 `JS_ToBoolFree` 调用只涨 **+32 insn / +3.1 cyc**。
  **同样是「掉出快臂」，qjs 付 3.1 cyc，zjs 付 18.3 cyc** —— 差的不是语义，是协议
  （publish + 两层嵌套 out-of-line 调用 + 一次为传参而做的内存往返 + `coldNext` 重派生）。

## 6. 归因边界（二）：定周期 per-symbol 阶段拆分

`logicalNot` 与 `toBoolean` 都是真符号（`nm` 有条目，`logicalNot` 0xd8 字节、全二进制只有
**一个**调用点），所以三个阶段不需要任何 `file:line` 表就能按符号分开 —— 这正是 P7-42
留下的第二条纪律（按符号作用域归因，不聚合裸 `file:line`）。第一条纪律同样照做：
**只用固定互质周期**（cycles `50021` / `65599` / `82657`），不用 `-F`。报的是 `k1 − k0`
的差分，所以循环脚手架抵消。

| 阶段（符号） | `int` 操作数 cyc/次 | 三周期极差 | `object` 操作数 cyc/次 | 三周期极差 |
|---|---:|---:|---:|---:|
| `S1` 冷 wrapper + next dispatch（`coldStd__struct_69769.h`） | **7.02** | 1.22 | 5.53 | 0.33 |
| `S2` helper 帧 + 结果发布 + 操作数 free（`exec.vm_value.logicalNot`） | **5.38** | 0.29 | **6.00** | 0.54 |
| `S3` tag 分类 + `ToBoolean` 计算（`core.value_semantics.toBoolean`） | **1.58** | 0.10 | 4.57 | 0.17 |
| `other`（未映射：循环脚手架与被记到邻居身上的流水线断裂） | 8.49 | 0.86 | 3.32 | 1.81 |
| 合计 | 22.47 | | 19.42 | |

合计 22.47 / 19.42 与 §3 计时口径的 21.79 / 18.37 相差 0.7 … 1.1 cyc，量级一致。

三条结论：

1. **`S3` 是 1.58 cyc（immediate）/ 4.57 cyc（object），占 7% / 24%。`ToBoolean` 语义
   不是这笔成本。** 协调者选项 C 的**判据**（primitive tag classification dominates）
   因此**不成立**。
2. `S1` + `S2` = 12.40 cyc（immediate），加上 `other` 里那部分因冷跳而记到邻居 handler
   头上的阻塞，冷路由协议解释约 **93%** 的成本。
3. `other` 在 immediate 上是 8.49、在 object 上只有 3.32。这一格不是噪声也不是脚手架漂移：
   插入一次冷跳会打断 dispatch 流水线，乱序核把阻塞记在**依赖链末端的消费者**上（P7-42 §2
   的同一现象）。所以 §6 的 cyc 列是**归因不是账本**，不得把它当 20 cyc 的分解相加。

### 6.1 zjs 自身给出的「刀后天花板」

`r_int_nonzero_if − r_int_nonzero_none = 4.29 cyc` 包含 `get_loc x` **加** 内联 `if_false`，
所以 **4.29 cyc 是 zjs 一条内联 immediate 真值臂的上界**。qjs 的 `lnot` 在同口径下是 2.94。
两者一起把一刀之后 zjs `op.lnot`（immediate）的合理落点框在 **≈3 … 4.3 cyc**，
即从 ≈21 cyc 回收 **16.7 … 18.9 cyc / 次**。表里 `immediate_only_recoverable_share` 一列
按 `zjs_cyc(tag) − 4.29` 的保守口径给出：`earley-boyer` **1.41%**、`mandreel` **1.24%**、
`raytrace` **0.78%**、`typescript` 0.26%、`zlib` 0.14%、`splay` **0.055%**。

### 6.2 逐条对照升级门槛

| 门槛（协调者口径） | 结果 | 依据 |
|---|---|---|
| ≥2 个互不相关的代表性负载 `op.lnot` 超过 ~1% cycles | **达成** | `earley-boyer` 1.53% / `mandreel` 1.35% / `raytrace` 1.03`%`，三个互不相关 |
| 某 Pareto case 超过 ~5% | **未达成** | 最高的 Pareto case 是 `raytrace` 1.03% |
| 绝对语料贡献超过当前 deferred 候选 | **达成** | P7-51A 的 deferred 项在唯一产品负载上是 ≈8.9 k cycles 全程；本线 `earley-boyer` 单负载 **364.9 M** |
| 真实产品负载里稳定高频命中 | **达成** | 16 个产品负载**全部非零**，其中 11 个每轮 >10⁵ 次；两轮计数比值 1.000、最高 2.06×10⁷ 次/轮 |

四条里三条达成，**频次判决通过**。这不是 P7-51A 的收场。

### 6.3 一刀的形状：为什么答案是 C 的动作，而字面 40% 判据指向 D

按协调者给的四选一：

- **A**（cold dispatch/wrapper dominates → 只搬到常规 handler、仍调 `logicalNot`）：
  `S1` 是最大单一阶段，但 7.02 / 22.47 = **31%**，未过 40%。而且只搬表不改体的话，
  `publish` 与那两层 out-of-line 调用都还在，回收上限只有 `coldNext` 那一段。
- **B**（noinline 调用边界 dominates）：`S2` = 5.38 / 22.47 = **24%**，未过 40%。
- **C**（primitive tag classification dominates）：**判据不成立**，`S3` 只有 1.58 cyc = 7%。
- **D**（最大阶段仍低于 ~40% → 关闭生产路线）：**按字面读，本线落在这里。**

本线不打算悄悄绕过这个判据，而是明确记下为什么认为它的**前提**在这里不成立，并把最终取舍
交回协调者：

**40% 阶段判据假设各阶段可以彼此独立地删。这里不能。** `S1` / `S2` / 以及 `other` 里那份
流水线断裂，都是**同一个协议选择**（「这个 opcode 没有快 handler，走 publish → noinline
helper → `coldNext`」）派生出来的，也会被**同一个改动**一次性拿掉。这个改动不是
「dispatch relocation + helper inlining + tag specialisation 三合一」，而是一件事：
**给 `op.lnot` 一个快 handler，其 immediate 臂复用引擎里已有的 `asBranchImmediateBool`，
其余类型原封不动落回现有的冷 handler** —— 也就是 `op_if_false8` 今天已经在做的事，
以及 `quickjs.c:19096` 那一行。

支持「这是一件事而不是三件事」的是**实测而不是推理**：同一引擎里，`op_if_false8`
在内联时 4.3 cyc、在被路由进 `cold_table` 时 22.6 cyc（§5）。语义、值表示、GC / refcount
纪律全同，差的只有这条协议。因此本线的建议是：

```text
one cut = 采用选项 C 的动作（qjs 形状的 immediate 快臂，判据用 zjs 自己的
          asBranchImmediateBool，不移植 qjs 的 tag 顺序；complex 类型落回
          现有 canonical helper），
          尽管选项 C 的判据（tag classification dominates）不成立，
          且字面的 40% 阶段判据指向 D。
```

若协调者坚持字面判据，正确的收场是 D 并把本线登记为低优先级对齐清理 —— 但那要连同
「`earley-boyer` 1.53% / `mandreel` 1.35% / `raytrace` 1.03%、单负载 3.6 亿 cycles」
一起记下，因为那是本战役目前 deferred 队列里最大的一项。

### 6.4 一刀的验收预期（若立项）

- **受益面按操作数分布走，不按负载名走。** immediate 主导的负载（`earley-boyer`
  `mandreel` `deltablue` `gbemu` `box2d` `zlib` `typescript` `pdfjs`，以及 74.6% immediate
  的 `raytrace`）预期改善 0.1% … 1.4%；**`splay` 基本不受益**（94.3% object 操作数，
  忠实的 qjs immediate 臂不覆盖它，qjs 自己也不覆盖）。
- **不要顺手把 object 也内联。** zjs 的 `op_if_false8` 确实有内联 object 臂，但
  `quickjs.c:19096` 的 lnot 快臂**只**覆盖 `tag <= JS_TAG_UNDEFINED`。把 object 一起内联
  是第二个机制，也是对 qjs 的第二处偏离，必须单独立项、单独量。
- **`+0` 没有 float64 格。** 两个引擎都把整值正零归一回 int tag（实测），所以别为
  「`+0` 走 float 臂」写测试或写代码。
- **合成 case 不能当验收。** `n_neg` / `perf_c_every` 这类探针里 `op.lnot` 占 14%–26% cycles，
  它们只用于类型成本矩阵，不得作为产品频次或收益证据。

## 7. 正确性边界（任何一刀都必须保住的东西）

`tools/perf/logical_not/truthiness_table.js` 覆盖 33 个形态：`undefined` / `null` /
`false` / `true` / int 0 与非 0 / float `+0` `-0` `NaN` `1.5` `Infinity` /
short BigInt `0n` `7n` `-7n` / 堆 BigInt 正负 / 空串与非空串 / **真 rope 与空 rope** /
`{}` `[]` `new Number(0)` `new Boolean(false)` / **带 throwing `valueOf`/`toString` 的对象**
（`!` 绝不能触发它们）/ function / arrow / Symbol / Date / RegExp / Proxy。
每行同时打印 `!x`、`!!x`、`typeof`。

**zjs 与 qjs 的输出逐字节相同**（33 行，sha256 记在 `P7-60-results.json`）。
两个引擎都不在 `!` 上跑 `valueOf`/`toString`（trap 对象正常返回 `!x=false`）。
这张表是任何一刀的 oracle：它必须继续逐字节相同。

## 8. 本条线没有建立的东西

1. **没有做任何一刀。** 未改 `src/`、未建任何候选变体、未计时任何变体。§6.1 的
   「3 … 4.3 cyc 落点」是从 zjs 自己的内联臂与 qjs 的读数推出的**上界**，不是实测的刀后值。
2. **没有把 `S1` / `S2` 内部再拆。** 「冷 wrapper 里 `publish` 与 `coldNext` 各占多少」、
   「`logicalNot` 帧里 callee-saved 保存与那次为传参而做的内存往返各占多少」都没有单独量；
   §4 的链条是静态读反汇编得到的，不是实测拆分。
3. **没有量 `alternate JSValue representation`。** 本树是 NaN-boxed 布局（`value.zig` 的
   `NanBox`）。`-Dvalue_repr=...` 之类的替代布局一格都没测，协调者列表里的这一项**未完成**。
4. **`other` 那 8.49 cyc 没有归到具体符号。** 已证它随冷跳出现（object 格只有 3.32），
   但没有做 per-instruction 追查，也没有用 ARM SPE（本机 `arm_spe_0` 可用，未使用）。
5. **没有跑 test262 计数。** 因此不能声称覆盖了所有语言形态；`op.lnot` 在 `with` /
   generator / async / module 顶层等形态下的频次未测。
6. **产品语料只有 Octane 派生的 15 个负载加 `gbemu`。** 没有 Node 应用、没有真实 web 代码、
   没有 minified bundle。真实前端代码里 `!` 的密度可能更高（`!x`、`!!x`、`if (!x)` 是
   压缩器偏爱的形态），本线**不能**据此外推。
7. **`gbemu` 与 `gbemu_product` 是同一个文件**，表里两行不是两个独立样本。
8. **计数构建的扰动只作了整体界定**（干净构建与计数构建的总 cycles 相差 ≤1.5%），
   没有逐负载做扰动修正。
9. **没有主张 `publish` / `coldNext` / native 边界 / refcount free 中任何一项是冗余的。**
   本线只证明了它们对 `op.lnot` 这个 opcode 是**不必要地**被走了一遍，因为同一引擎的
   `op_if_false8` 在 immediate 上不走它们。

## 9. 临时插桩与还原

计数用的是**默认关闭**的诊断计数器，编译进二进制只在 `-Dzjs_enable_opcode_profile=true` 下发生，
运行时还要 `$ZJS_LNOT_CENSUS_FILE` 才输出（镜像既有的 `host_dispatch_stats` 形状）：

- 新增 `src/exec/lnot_census.zig`（tag 分桶 + `atexit` 落盘）
- `src/exec/root.zig` 导出一行
- `src/exec/vm_value.zig` 的 `logicalNot` 里一行 `record(value)`
- `src/cli/zjs.zig` 的 `setupLnotCensusExitDump` / `writeLnotCensusAtExit` 与 `main` 里一行调用

**全部已还原，`git diff ab4fc64b -- src/` 为空。** 计数构建的产物 sha256 记在 §0，
**没有任何计时数字出自它**：所有 cycles / instructions 都来自冷构建 A1 / A2。
全程未用 `git stash`，未为制造符号而强加 `noinline`（`logicalNot` 的 `noinline` 是基线自带的）。

## 10. 交给其他线的东西

- **给 VM 线**：`asBranchImmediateBool`（`value.zig:450`）已经是 `quickjs.c:19096` 的逐字镜像，
  已被 `op_if_false8` / `op_if_true8` 使用。凡是「qjs 在解释器里内联处理 immediate、
  zjs 走 `cold_table`」的 opcode，都可以用本线的分支族口径（`none` / `if` / `lnot` 三 case
  差分）在 10 分钟内量出冷路由税。本线量到的税是 **+88 insn / +18.3 cyc**，
  这个数字对**任何**被冷路由的 opcode 都适用，可以直接用来排序候选。
- **给测量方法线**：三条新固化的做法 ——（a）`u = x` / `u = !x` 这类**字节码只差一个
  opcode 字节**的成对 case，是把单 opcode 成本从脚手架里剥出来的最干净口径，且对非引用计数
  类型零不对称；（b）**同一引擎的两条路由（内联臂 vs 冷表）做同语义对照**，比跨引擎差分更能
  分开「语义贵」与「协议贵」；（c）**先用 tag 计数器验证每个类型 case 真的落在你以为的
  representation 上** —— 本线因此发现 `+0` 在两个引擎里都归一成 int、短串拼接不产生 rope，
  两处若不验就会写出错的矩阵。
- **给排序规则线**：本线的加权口径（按每个负载**自己的**操作数 tag 分布加权每事件差，
  而不是拿一个数乘全部）建议成为此后所有「per-event 成本 × 次数」类估计的默认口径。
  `splay` 就是它救下的例子：不加权会把它算成 0.77% 的受益负载，加权后可见其中只有 0.055%
  在忠实 immediate 快臂的射程内。

## 附：`raw/` 里文件名的含义

| 文件 | 用途 |
|---|---|
| `P7-60-matrix-A1.json` | 第一次完整计时扫描（62 case × 6 样本 × 2 引擎，ABBA） |
| `P7-60-matrix-T2.json` | 第二次独立完整计时扫描，噪声尺 |
| `P7-60-matrix-rope-A1.json` | 真 `Tag.string_rope` 格的补测（首版 rope case 被压平成 `Tag.string`，已替换） |
| `P7-60-stage-record-A1.json` | 定周期 ×3 的 per-symbol 阶段归因（§6） |
| `P7-60-census-count-microbench.json` | `microbench` / `named_eval` / `bootstrap` 计数（全 0） |
| `P7-60-census-count-wrapped-p0.json` | `wrapped` / `p0_sentinel` 计数（144 条目，5 条非零，其中 4 条是 P7-41 探针本身） |
| `P7-60-census-count-product.json` | 产品型负载计数 + 操作数 tag 分布 |
| `P7-60-census-cycles-clean-A1.json` | 干净 A1 构建的每负载总 cycles（分母，240 条目） |
| `P7-60-census-cycles-counterbuild.json` | 计数构建上「计数与 cycles 同进程」的一轮，用于按墙钟排程的负载与扰动界定 |
| `P7-60-truthiness-{zjs,qjs}.txt` | 33 行正确性边界表，两侧逐字节相同 |
