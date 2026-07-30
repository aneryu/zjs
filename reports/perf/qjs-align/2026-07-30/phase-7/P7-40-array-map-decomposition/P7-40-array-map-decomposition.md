# P7-40：`array_map_callback` 的同层分解

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码，不提方案
- 起点：`perf/qjs-align-p7-pareto` @ `91b399ab`（基线 `a5bbbe52`）
- 对照引擎：pinned Bellard QuickJS `04be2460`（二进制 sha256 `b76d1542…`，与 P7-20 所用快照**同一个文件**）
- 数据产物：`P7-40-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/array_map/`（case 生成器、采集器、gdb 计数器、分析器）

## 1. 结论

### 1.1 先修正被分解的那个数

**2.618 在当前树上不复现。** 同一段源码逐字不变，pin 在 CPU 19、6 次 ABBA、instructions 与 cycles 双测：

| 口径 | qjs | zjs | 比值 |
|---|---|---|---|
| 墙钟（整进程） | 6.314 ms | 8.112 ms | **1.285** ¹ |
| task-clock（整进程） | 5.430 ms | 7.468 ms | **1.375** |
| instructions（扣空脚本基线） | 121.51 M | 136.24 M | **1.121** |
| cycles（扣空脚本基线） | 19.59 M | 26.72 M | **1.364** |

¹ 墙钟含两侧各约 0.4 ms 的 spawn/exec 常数，会把比值往 1 拉；引用时以 task-clock 与 cycles 为准。

所以本条线真正分解的对象是 **1.364x（cycles）/ 1.121x（instructions）**，不是 2.618。第 2 节给出 2.618 的来源与三条排除。

### 1.2 三分法与份额

分解在**同一层**（进程层、同一批 case、同一把 perf 尺）做，用 `forEach` 作为「同一个 builtin、同一个回调、但不建结果数组」的对照，用长度 0/1/10/100 扫出截距与斜率。每次 `a.map(f)`（10 元素）的 zjs−qjs 差额：

| 组成 | cycles/call | 占原案总差额 | instructions/call | 占原案总差额 |
|---|---|---|---|---|
| **回调调用 + 源元素读**（per-element） | **+478.2** | **70.9%** | +830.0 | 59.1% |
| **内联箭头的每次闭包分配**（per-call） | **+324.5** | **48.1%** | +1184.8 | 84.4% |
| builtin 入口固定成本（per-call） | +85.5 | 12.7% | +393.3 | 28.0% |
| species 查找 + 结果数组构造（per-call） | +60.6 | 9.0% | +207.4 | 14.8% |
| **结果元素 define**（per-element） | **−260.1** | **−38.5%** | −1207.2 | −86.0% |
| 合计 | +688.7 | 102.1% | +1408.2 | 100.4% |
| 实测（`map_inline_arrow`） | +674.8 | 100% | +1403.2 | 100% |

模型闭合残差 cycles +2.0%、instructions +0.4%。

回答提问的原话：

> **主要是 callback invocation。** 它一项就占 70.9% 的 cycles 差额；如果把源码里那个**内联**箭头（`a.map(x => x + 1)` 每次迭代新建一个闭包）单列出来，它再占 48.1%，两项相加超过 100%，因为
> **result-array construction 与 per-element property machinery 合起来是负的**：结果数组构造 + species 只有 +9.0%，而每元素 define 是 **−38.5%**（zjs 更快）。源元素读没有单独的同层探针（它与回调绑在同一条斜率里），但两个旁证都说它不是问题：VM 层同形状的 dense 读 zjs 只贵 1.16 cycles/元素，且计数显示 zjs 每元素比 qjs **少做一次 hole check**（0 对 10）。

把「结果数组」这一类合并（构造 +60.6，define −260.1）净值是 **−199.5 cycles/call**，即 zjs 在结果数组这条轴上**净赢**。因此三分法不是三个正份额，而是「一正一负一小」：回调调用是唯一的大头，闭包分配是与它同量级的第二个大头（但它属于 case 源码写法，不属于 `map`），属性机械是负贡献。

### 1.3 大头的进一步定位：贵的是 builtin→JS 的桥，不是 VM 的调用

同一批 case 里另有一条纯 VM 的梯子（`for` 循环里手写 `t = f(a[j])`），把两个层的每元素成本摆在一起（cycles）：

| 每元素 | qjs | zjs | 差 |
|---|---|---|---|
| VM dense 读 | 9.95 | 11.11 | +1.16 |
| VM 里调一次箭头 | 52.46 | 64.18 | +11.72 |
| 合计 | 62.41 | 75.29 | +12.88 |
| **builtin 内的「读 + 调」斜率** | **63.80** | **111.62** | **+47.82** |
| **builtin 附加税**（= 斜率 − VM 合计） | **+1.38** | **+36.33** | **+34.94** |

qjs 的 builtin 回调与它自己的 VM 调用**几乎等价**（+1.38 cycle）；zjs 的 builtin 回调比它自己的 VM 调用**每次贵 36.3 cycles**。也就是说：zjs 的 VM 调用只落后 qjs 11.7 cycles/次（与 P7-20 记录的 `call_body_loop` 1.15x / `arrow_call_loop` 1.31x 一致），而 `array_map_callback` 的回调差额里有 **73%（34.9/47.8）是 builtin 边界特有的**，不是通用调用税。这条推断跨了两个层（VM 梯子 vs builtin 梯子），在第 7 节登记为「推断而非直接测量」。

`perf record` 与之独立同向。`a.forEach(f)`（100 万次、10 元素）的 cycles 归属：

| qjs | % | zjs | % |
|---|---|---|---|
| `JS_CallInternal` | 68.16 | `SyncInternalCallSite.call` | 31.29 |
| `js_array_every` | 7.94 | `zjs_vm.runTC` | 20.57 |
| `JS_HasProperty` | 6.97 | `qjsArrayIterationModeCall` | 12.27 |
| `JS_GetOwnPropertyInternal` | 4.19 | `tailcall_dispatch.op_return` | 11.44 |
| `JS_GetPropertyValue` | 3.69 | `opBinary.hnd` | 4.91 |

zjs 侧 `SyncInternalCallSite.call` + `runTC` + `op_return` + `op_get_arg_short` + `vm_call.callMethod` ≈ 71%，与 qjs 的 `JS_CallInternal` 68% 是同一件事的两种切法；差别在于 zjs 把它摊在**一个 noinline 的桥函数加一次 VM 重入**上（每回调恰好 1 次 `runActiveInvocationUntilNativeBoundary`，见第 4 节计数）。

### 1.4 IPC：指令没有多，周期多了

| case | qjs IPC | zjs IPC |
|---|---|---|
| `foreach_pre_arrow` | 6.85 | 4.88 |
| `map_pre_arrow` | 6.40 | 5.40 |
| `map_len100` | 6.82 | 5.05 |
| `map_inline_arrow` | 6.24 | 5.17 |

`map_pre_arrow` 的 instructions 比值是 **1.020**（基本打平），`map_len100` 甚至是 **0.949**（zjs 指令更少），但 cycles 分别是 1.208 和 1.283。**这一段的差距不是「zjs 跑了更多指令」，而是同样多的指令跑得更慢**——与本战役此前多数结论（指令数是主因）方向相反，值得单独记一笔。本条线没有采集 stall/miss 事件，因此没有解释 IPC 差从哪来（第 7 节）。

## 2. 2.618 的来源：三条排除加一条剩余解释

### 2.1 排除一：big.LITTLE 未绑核只加方差，不造这个数

P7-20 用的 `phase-6-closeout/process-microbench.json` 自己的 metadata 写着 `affinitySource: "unpinned"`、`affinityMask: "0-19"`、`cpuModel: "Cortex-X925 / Cortex-A725"`。该 case 的 30 个样本因此是双峰的：

| | 快模 n | 快模中位 | 慢模 n | 慢模中位 | 慢/快 |
|---|---|---|---|---|---|
| qjs | 18 | 5.730 ms | 12 | 10.808 ms | 1.886 |
| zjs | 15 | 14.167 ms | 15 | 26.126 ms | 1.844 |

paired ratio 因此散在 1.301–4.571。但**同模相比仍是 2.472（快/快）与 2.417（慢/慢）**，所以未绑核解释的是离散度，不是 2.618 本身。这一条必须先排除，否则会把一个真实的历史差距误判成测量噪声。

### 2.2 排除二：不是构建 bistability

同一棵树独立构建两个实例（sha256 `e00095c9…` 与 `3b94378c…`，同源不同二进制），各跑 6 次 ABBA：

| case | build A cycles 比 | build B cycles 比 | 偏差 |
|---|---|---|---|
| `map_original_toplevel` | 1.365 | 1.367 | +0.15% |
| `map_inline_arrow` | 1.348 | 1.350 | +0.16% |
| `map_pre_arrow` | 1.216 | 1.211 | −0.46% |
| `foreach_pre_arrow` | 1.722 | 1.727 | +0.29% |
| 其余 6 个 | — | — | ≤ 0.76% |

十个 case 的实例间偏差全部 ≤ 0.76%，与 2.618→1.36 差着两个数量级。build A 另外还重复采了一整轮，两轮 instructions 比值到小数点后三位相同。

### 2.3 排除三：不是顶层绑定，也不是 qjs 侧变了

- `map_original_toplevel`（P7-20 原文，顶层 `const a` / `let out`）1.121 insn / 1.364 cyc；`map_original_local`（同一循环搬进函数）1.120 / 1.370。**顶层绑定在这个 case 上不产生可见差**，P7-20 交给 P7-10 的那条线索在这里不适用。
- qjs 二进制 sha256 与快照 metadata 逐字节相同，且快照快模中位 5.730 ms 与本次 pin 后墙钟 6.314 ms（含 Python spawn 开销）、task-clock 5.430 ms 相符。**尺子没变。**

### 2.4 剩余解释：快照里的 zjs 二进制早于「array 回调换桥」那次合并

快照 metadata 记录 zjs 二进制为 commit `0f726fc0`（`dirty: true`）、sha256 `df03ae49…`。该路径上现在的文件是 `d0eef3c1…`，**已被覆盖，无法重跑**。

代码层证据是明确的：

- `git merge-base --is-ancestor 63c409c0 0f726fc0` 为假 —— `63c409c0 perf: reuse active Machine for array callbacks` 不在快照二进制里，它是经 `222df098 merge: QJS alignment Phase 1-6` 进入 `a5bbbe52` 的。
- 在 `0f726fc0`，`array_ops.zig` 的元素循环写的是 `callValueOrBytecode(ctx, output, global, callback_this, args[0], …)`；`SyncInternalCallSite` 这个标识符在该 commit 的 `array_ops.zig` 与 `call_runtime.zig` 里**出现 0 次**。在 `a5bbbe52` 同一处是 `callback_call.call(&.{ item, index_value, receiver_object_value })`，走预解析好的 route。
- 而本条线测得，这条桥正是该 case 唯一的大头（1.3 节）。

即：P7-20 那个 2.618 大概率量的是**换桥之前**的回调路径。本条线**没有**重建 `0f726fc0` 来直接验证（见第 7 节），所以这是「代码层证据 + 逐项排除」，不是实测对照。

### 2.5 对 P7-20 其余条目的影响：仅此一项离群

把 P7-20 排序 B（绝对时间）top 10 里除本案外的 8 个、再加排序 A 里的 `array_write` 与 `typed_array_write`，用同一把 pin 尺重测（载荷口径，扣空脚本基线）：

| case | P7-20（未绑核墙钟，含启动） | 本次 cycles 比 | 本次 insn 比 |
|---|---|---|---|
| `array_map_callback` | 2.618 | **1.364** | 1.121 |
| `arrow_call_loop` | 1.313 | 1.257 | 1.168 |
| `call2_loop` | 1.296 | 1.253 | 1.167 |
| `closure_call_loop` | 1.309 | 1.241 | 1.178 |
| `uri_decode_4byte` | 1.290 | 1.294 | 1.040 |
| `prop_read_mono` | 1.234 | 1.040 | 1.079 |
| `vm_int_sum_large` | 1.248 | 1.104 | 1.104 |
| `global_read_loop` | 1.200 | 1.096 | 1.072 |
| `dense_array_write_read` | 1.175 | 1.233 | 1.179 |
| `array_write` / `typed_array_write` | 1.512 / 1.572 | 1.526 / 1.682 | 1.757 / 1.765（启动主导，见下） |

两个口径不同（P7-20 含启动、未绑核；本次绑核且扣基线，而启动比值本身就有 1.26），所以 0.05–0.20 的位移属正常。**只有 `array_map_callback` 移动了 1.25**，是第二大位移（`prop_read_mono` 0.194）的六倍。另外 `array_write` 与 `typed_array_write` 在本次口径下整进程只有 2.30 M / 2.31 M 指令，与空脚本基线 2.27 M 几乎相同——它们量到的确实几乎全是启动，与 P7-20 第 3 节的判断一致。

## 3. 同层梯子（原始数据）

每次外层迭代的载荷（整进程中位数减同引擎空脚本基线，再除以迭代数）。除两个 `map_original_*` 外全部函数局部化，避免把顶层绑定税折进每一级。

| case | 迭代 | qjs insn | zjs insn | 比 | qjs cyc | zjs cyc | 比 |
|---|---|---|---|---|---|---|---|
| `loop_outer` | 1e5 | 197.8 | 180.3 | 0.911 | 29.9 | 29.3 | 0.980 |
| `loop_nested` | 1e5 | 2256.4 | 2018.6 | 0.895 | 346.1 | 343.1 | 0.991 |
| `elem_get` | 1e5 | 2867.2 | 2670.2 | 0.931 | 445.6 | 454.2 | 1.019 |
| `elem_getset`（预分配数组读写） | 1e5 | 3487.8 | 3671.0 | 1.053 | 516.0 | 623.2 | 1.208 |
| `elem_getset_add` | 1e5 | 3858.5 | 4091.3 | 1.060 | 579.2 | 694.2 | 1.199 |
| `elem_getcall`（调回调、不建数组） | 1e5 | 5902.5 | 6285.6 | 1.065 | 970.2 | 1096.0 | 1.130 |
| `elem_getcallset` | 1e5 | 6522.9 | 7286.6 | 1.117 | 1056.3 | 1254.3 | 1.188 |
| `alloc_only`（只建同长结果数组） | 1e5 | 1505.8 | 2134.4 | 1.417 | 237.0 | 394.4 | 1.664 |
| `alloc_fill` | 1e5 | 7457.7 | 10176.1 | 1.365 | 1110.4 | 1743.6 | 1.570 |
| `alloc_getcallset` | 1e5 | 10122.2 | 11751.7 | 1.161 | 1581.4 | 1943.6 | 1.229 |
| `closure_only`（每轮建一个箭头） | 1e5 | 1820.1 | 4725.7 | **2.596** | 285.6 | 927.7 | **3.248** |
| `map_identity` | 1e5 | 10400.0 | 10570.1 | 1.016 | 1608.1 | 1951.8 | 1.214 |
| `map_pre_arrow` | 1e5 | 10771.7 | 10990.2 | 1.020 | 1683.9 | 2034.2 | 1.208 |
| `map_decl_fn`（预声明函数） | 1e5 | 10764.4 | 10984.4 | 1.020 | 1685.7 | 2051.7 | 1.217 |
| `map_inline_arrow`（内联箭头） | 1e5 | 12096.4 | 13499.5 | 1.116 | 1937.7 | 2612.6 | 1.348 |
| `foreach_pre_arrow` | 1e5 | 5353.5 | 6581.2 | 1.229 | 781.3 | 1347.5 | **1.725** |
| `map_len0` | 1e5 | 2378.4 | 2979.0 | 1.253 | 394.4 | 540.5 | 1.370 |
| `map_len1` | 1e5 | 3232.9 | 3790.8 | 1.173 | 546.6 | 700.7 | 1.282 |
| `map_len100` | 1e4 | 76926.4 | 73004.1 | **0.949** | 11274.6 | 14461.3 | 1.283 |
| `foreach_len0` | 1e5 | 850.0 | 1243.3 | 1.463 | 141.7 | 227.2 | 1.603 |
| `foreach_len1` | 1e5 | 1308.4 | 1789.1 | 1.367 | 207.2 | 343.0 | 1.656 |
| `foreach_len100` | 1e4 | 45881.2 | 54610.8 | 1.190 | 6483.5 | 11327.2 | 1.747 |
| `map_original_toplevel` | 1e4 | 12151.0 | 13624.3 | 1.121 | 1958.6 | 2672.1 | 1.364 |
| `map_original_local` | 1e4 | 12115.0 | 13571.8 | 1.120 | 1938.1 | 2654.7 | 1.370 |

三处要读出来的东西：

1. **`map_pre_arrow` 与 `map_decl_fn` 完全等价**（1.020 / 1.020，cycles 1.208 / 1.217）。「预声明函数替代内联箭头」本身不改变 `map` 的成本，改变的是**是否每轮新建闭包**：`map_inline_arrow` 与它们的差是 253.8 cyc（qjs）/ 578.4 cyc（zjs），这是分解里用的原位值。独立探针 `closure_only` 每轮 285.6 / 927.7 cyc（含约 30 cyc 循环开销），方向与量级一致，但 zjs 侧两个口径相差 1.6 倍；本条线没有查这个差从哪来（写进局部变量 vs 作实参传出，生存期不同），因此只把它当旁证，分解一律用原位值。
2. **`foreach` 的比值（1.725）比 `map`（1.208）差**。这不是矛盾：`map` 在 `forEach` 之上加的那部分工作（结果数组构造 + define）是 zjs 相对更快的部分，稀释了比值。用比值排优先级会把结论指反，绝对差额才不会。
3. **长度 100 时 zjs 指令更少（0.949）**。zjs 的每元素指令斜率是 689–800，qjs 是 735–838；per-element 这条轴上 zjs 已经赢了。

截距/斜率模型（cycles）：

| | 截距（len 0） | 每元素（len 1→10） | 预测 len 10 | 实测 len 10 | 误差 |
|---|---|---|---|---|---|
| qjs `map` | 394.4 | 126.4 | 1658.1 | 1683.9 | −1.5% |
| zjs `map` | 540.5 | 148.2 | 2022.2 | 2034.2 | −0.6% |
| qjs `forEach` | 141.7 | 63.8 | — | 781.3 | — |
| zjs `forEach` | 227.2 | 111.6 | — | 1347.5 | — |

## 4. 动态计数（精确值，非采样）

gdb 断点配不可达 ignore 计数，进程跑到底后 `info breakpoints` 给出精确命中数；同一把尺对准两个引擎，两侧源码都没改。下表是 100 次 `a.map(f)` / `a.forEach(f)`（每次 10 元素）扣掉同二进制跑空脚本后的**每次调用**值。

| 计数项 | qjs（map） | qjs（forEach） | zjs（map） | zjs（forEach） |
|---|---|---|---|---|
| builtin 本体入口 | `js_array_every` 1 | 1 | `qjsArrayIterationModeCall` 1 | 1 |
| **回调调用** | `JS_CallInternal` 12.01 ¹ | 11.01 | `SyncInternalCallSite.call` 10 | 10 |
| **JS 帧建立/返回** | 同上（12.01，含 1 次 builtin、1 次 species getter） | 11.01 | `runActiveInvocationUntilNativeBoundary` 10 | 10 |
| builtin（C 函数）调用 | `js_call_c_function` 2.00 | 1.00 | —（非 C-function 模型） | — |
| **源元素读** | `JS_GetPropertyValue` 10 | 10 | `getDenseArrayElementValue` 10 | 10 |
| **hole check** | `JS_HasProperty` **10** | 10 | `hasValueProperty` **0** | 0 |
| **species / constructor 查找** | `JS_ArraySpeciesGetCtor` 1、`JS_GetPropertyInternal` 4.00 | 0、2.00 | `arrayHasDefaultSpecies` 1、`getOwnProperty` 3.03 | 0、0.03 |
| 结果数组构造 | `js_array_constructor` 1 | 0 | `createArray` 1 | 0 |
| **结果元素 define** | `JS_DefinePropertyValueValue` 10 | 0 | `defineDenseArrayDataPropertyUnchecked` 10 | 0 |
| **结果数组扩容** | `expand_fast_array` 7.01、`js_realloc2` 7.17 | 0.01、0.16 | `ensureArrayBufferCapacity` 10 ²、`appendUninitializedFastArraySlot` 0 | 未测 ²、0 |
| dense→sparse 形状转换 | `convert_fast_array_to_array` **0** | 0 | 无直接计数器；`defineDenseArrayDataPropertyUnchecked` 满额命中 10/次即证明 dense 快腿全程未降级 | — |
| 分配 | `js_def_malloc` 0.08 | 0.08 | `malloc` 0.23、`SmallObjectSlab.addArena` 0.07 | 0.20、0.04 |

¹ map 比 forEach 多的那 1 次 `JS_CallInternal` 是 `Symbol.species` 的 getter（`js_get_this`）——qjs 的 species 路径里有一次真实的函数调用，zjs 的 `arrayHasDefaultSpecies` 用 own-property 探测替代，没有这次调用。

² `ensureArrayBufferCapacity` 是事后补测的单符号运行（`count_map` 命中 1001 次，扣基线后每次 map 调用 10 次），没有对 `forEach` 补测——`forEach` 不建结果数组，该项对它无意义。zjs 每元素都调一次，但它在容量够时立即返回；其增长策略在源码里逐字镜像 qjs 的 `expand_fast_array`（`max(new_len, size*3/2)`；`src/core/object.zig:5122-5159`，注释锚在 `quickjs.c:9530`），所以**两侧的实际 realloc 次数都是 7**（0→1→2→3→4→6→9→10）。这一项两侧机制相同。

计数给出的四条结论，都与 1.2 节的时间分解一致：

- **回调次数两侧都是 10，没有一侧多调。** 差在每次的代价，不在次数。
- **zjs 的快腿确实每次都走到**：`callValueOrBytecodeDispatchAfterInterruptPoll`（通用回退路径）在整个 map/forEach 载荷里净命中 **0** 次，1000 次回调全部由预解析 route 承担。所以 1.3 节那 36.3 cycles/次的附加税**不是回退造成的**，它是这条快腿本身的成本。
- **per-element property machinery 是 zjs 少做事**：qjs 每元素做 `JS_HasProperty` + `JS_GetPropertyValue` 两次查找（`JS_TryGetPropertyInt64`，`quickjs.c:9115-9128`），zjs 走 dense 快腿一次读完、hole check 为 0。qjs 的 define 还要穿 `JS_DefinePropertyValueValue → JS_DefineProperty → JS_CreateProperty → add_fast_array_element` 四层（profile 里三项合计 11.3%），zjs 是一次 dense append。
- **species 侧两侧都不便宜、量级相当**：qjs 2 次属性查找 + 1 次 getter 调用；zjs 3 次 `getOwnProperty`（`original.constructor`、`Array.prototype.constructor`、`Array[Symbol.species]`）加一次按名字取全局 `Array`（profile 里 `arrayConstructorFromGlobal` 2.23%）。净差只有 +60.6 cycles/call。

`map` 的 `perf record` 归属（cycles，≥1.5%）也印证结果数组这条轴的方向：

| qjs | % | zjs | % |
|---|---|---|---|
| `JS_CallInternal` | 36.47 | `SyncInternalCallSite.call` | 21.75 |
| `__js_malloc` | 9.25 | `zjs_vm.runTC` | 12.52 |
| `JS_DefineProperty` | 5.74 | `qjsArrayIterationModeCall` | 10.89 |
| `JS_GetPropertyInternal` | 5.01 | `op_return` | 9.61 |
| `js_array_every` | 4.07 | `opBinary.hnd` | 4.48 |
| `JS_GetOwnPropertyInternal` | 3.70 | `ensureArrayBufferCapacity` | 4.11 |
| `JS_CreateProperty` | 3.56 | `Object.getOwnProperty` | 3.58 |
| `JS_HasProperty` | 3.45 | `op_get_arg_short` | 3.12 |
| `__js_free` | 3.16 | `defineDenseArrayDataPropertyUnchecked` | 2.51 |
| `__js_realloc` | 2.49 | `arrayConstructorFromGlobal` | 2.23 |

qjs 在「define + 扩容 + 分配器」上花掉约 28%（`__js_malloc`+`__js_free`+`__js_realloc`+`expand_fast_array`+三个 define 函数），zjs 对应项合计不到 11%。

## 5. 分配器：与 P7-00 的裁决一致，本条线不重开

P7-00 已判定 `array_map_callback` 不 churn（10 000 次 map 仅 10 个净 arena 事件）。本条线的独立计数给出 `SmallObjectSlab.addArena` 每次 map 调用 0.07、`malloc` 0.23，qjs 侧 `js_def_malloc` 0.08，量级一致，**不构成任何份额**。`alloc_only` 这一级（1.417 insn / 1.664 cyc）看着比值高，但它每次只有 1505.8 / 2134.4 条指令，占整个 map 调用的 14%–19%，且其中 zjs−qjs 差额在完整 `map` 里已经被 species+构造那一项（+60.6 cyc）覆盖。

## 6. 复算与门禁

- 采样：CPU 19（`armv8_pmuv3_1`），事件显式带 PMU 前缀，未出现 `<not counted>` 行。每个 case 6 次 ABBA，qjs/zjs 首位各 3 次，**样本数为偶**；主梯子 28 个 case（含 baseline 与 3 个计数用小 case）、复算与构建实例 B 各 11 个、Pareto 交叉核对 11 个、原案墙钟 1 个，首位计数全部平衡（`first_position_balanced: true`）。
- 独占锁按 case 取放，不整轮霸占；构建取共享锁；gdb 计数与 `perf report` 解析不计时、不取独占锁。
- 28 个 case 在两个引擎上的 stdout **逐字节相同**（采集器每次运行都比对，记录在 `output_match`）。
- `git diff a5bbbe52 -- src/` **为空**。全程未改生产代码，未使用临时插桩：gdb 断点与 `perf` 都在引擎之外，两侧同一把尺。
- 全程未使用 `git stash`。新增文件只在 `tools/perf/array_map/` 与本报告目录下。

## 7. 本条线没有建立的东西

1. **没有实测证明 2.618 来自旧二进制。** 快照那份 zjs 二进制已被覆盖（sha256 不再匹配），而按边界不能新建 worktree、也不能动 `src/`，所以没有重建 `0f726fc0`。2.4 节是代码层证据加逐项排除（未绑核、bistability、顶层绑定、qjs 侧变动都已排除），不是 A/B 实测。**要坐实只需一件事：在别的线里构建 `0f726fc0` 并重跑 `map_original_toplevel`。**
2. **没有解释 IPC 差。** zjs 在 `foreach_pre_arrow` 上 IPC 4.88 对 qjs 6.85，本条线只采了 instructions/cycles，没有采 cache-miss、branch-miss、stall 分解，因此「同样多的指令为什么更慢」没有答案。这是 1.3 节那 36.3 cycles/次 builtin 附加税的直接下一步。
3. **builtin 附加税是跨层推断。** +36.33 是「builtin 斜率减 VM 梯子的读+调」，两个梯子在同一进程层、同一采集器，但不是同一段代码路径。若要变成直接测量，需要一个「builtin 迭代但不回调」的同族对照，而 `Array.prototype` 上不存在这样的方法（`indexOf` 走的是另一条指针扫描快腿，不可比）。
4. **没有拆开闭包分配的 2.6x/3.2x。** `closure_only` 只量到 zjs 每个箭头 927.7 cyc 对 qjs 285.6 cyc，没有归因到 shape/属性/GC 中的哪一部分。它在原案里占 48.1% 的 cycles 差额，是本条线发现的第二大单点，且**与 `map` 无关**——任何在循环里内联写回调的 case 都会付。
5. **没有把 GC 单独扣出来。** `alloc_only`、`closure_only`、`map_*` 各级都含摊薄的 GC 成本，两侧都含，但没有分离。
6. **只重测了 P7-20 top-10 里能取到源码的 10 个。** 其余 65 个 case 是否也受旧二进制影响，本条线没有查。
7. **没有做任何一刀。** 按任务边界停在归因。

## 8. 交给其他线的三件事

- **给 call 线（最大单点）**：`array_map_callback` 剩下的 1.364x 里，70.9% 是 builtin→JS 回调桥，其中约 73% 是 builtin 边界特有的、通用 VM 调用路径上看不到的税；入口在 `exec/call_runtime.zig` 的 `SyncInternalCallSite.call`（noinline）+ 每回调一次 `zjs_vm.runActiveInvocationUntilNativeBoundary`。qjs 的同一位置是 `JS_CallInternal` 直接被 `js_array_every` 调用，没有中间层。
- **给 P7-20 / 门禁口径**：`array_map_callback` 的 2.618 应从 Pareto 第 2 项撤下（现值 1.364 cycles / 1.121 insn；同一段源码 pin 后的 task-clock 差是 **+2.04 ms**，而 P7-20 记的载荷差是 +12.2 ms），排序 A 的第 1 名与排序 B 的第 1 名都要改。更一般的教训是：**process-microbench 的快照必须记录并核验二进制 sha256 与 pin 状态，才能在后续线里被引用**——本次两个条件都在 metadata 里（`affinitySource: unpinned`、`sha256`），是它们让这次排除成为可能。
- **给一条新线（闭包分配）**：`closure_only` 2.596 insn / 3.248 cyc 是本条线撞到的最干净的孤立比值，比任何 map 相关项都高，且完全独立于 array 子系统。
