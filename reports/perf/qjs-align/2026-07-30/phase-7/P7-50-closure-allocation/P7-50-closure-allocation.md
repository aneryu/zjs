# P7-50：每轮闭包分配 2.6x/3.2x 的阶段归因

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码，不提方案，不实现
- 起点：`perf/qjs-align-p7-closure` @ `18816862`；`git diff 18816862 -- src/` **为空**
- 对照引擎：pinned Bellard QuickJS `04be2460`（`VERSION` 2026-06-04）
- 层：same-runtime（源码只编译一次，反复调用被保留的 `run()`），parser / compile / 进程启动全部在比较之外
- 数据产物：`P7-50-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/closure_alloc/`（case 生成器、gdb 阶段计数器、矩阵采集器、符号归因、结果装配）
- case 源：`tools/perf/same_runtime/cases/closure_*.js`（生成物，provenance 记在 `cases/README.md`）

## 1. 结论

### 1.1 一句话

**2.6x/3.2x 不是通用闭包分配的比值。** 它只在闭包创建位置受 **NamedEvaluation**
约束时出现 —— 也就是赋值目标是一个 IdentifierReference（`g = (x) => x + 1`，正是 P7-40
`closure_only` 的写法）。此时引擎必须把已经存在于新函数对象上的 `name` 属性**再定义一次**，
而这一次再定义在 zjs 上要 **466.5 cycles**，在 qjs 上只要 **42.9 cycles**。

把赋值目标换成数组元素（`slot[0] = (x) => x + 1`），闭包本身逐字不变 —— 同样的 wrapper、
同样的 captures、同样的 GC 行为、同样的析构 —— 比值立刻掉到 1.87x insn / 2.01x cycles。

| churn，扣 `reuse` 基线，每个闭包 | qjs | zjs-A | zjs-B | 比值 A | 比值 B |
|---|---|---|---|---|---|
| **identifier 目标**（P7-40 写法）insn | 1 629.0 | 4 492.2 | 4 511.2 | **2.758** | **2.769** |
| **identifier 目标** cycles | 258.5 | 898.9 | 891.9 | **3.477** | **3.450** |
| 数组元素目标 insn | 1 325.4 | 2 484.2 | 2 480.2 | 1.874 | 1.871 |
| 数组元素目标 cycles | 215.6 | 432.4 | 434.3 | 2.006 | 2.015 |

即 P7-40 记的 2.596 insn / 3.248 cyc 在本层**完整复现**（2.758 / 3.477，同方向、同量级），
但它测的不是「新建一个闭包」，而是「新建一个闭包 **并且** 重新发布它的 `name`」。

### 1.2 阶段归因与份额

对 3.48x 那个案例（identifier 目标）的 cycles 差额作二分，两段按构造相加恰好等于总额：

| 阶段 | qjs cyc/op | zjs-A cyc/op | 差额 | 占总差额 | zjs-B 份额 |
|---|---|---|---|---|---|
| 通用闭包创建 + 释放 | 215.6 | 432.4 | +216.8 | 33.9% | 34.5% |
| **NamedEvaluation 的那一次 `name` 再定义** | 42.9 | 466.5 | **+423.6** | **66.1%** | **65.5%** |
| 合计 | 258.5 | 898.9 | +640.4 | 100% | 100% |

instructions 同样二分：NamedEvaluation 段占 **59.5% / 59.9%**（+1 704.4 insn/op）。

再往阶段内部走（`perf record` 符号分组，绝对份额、无 call-graph 因此可加）：

| `name` 再定义内部（cyc/op） | qjs | zjs-A | zjs-B | 占该阶段差额 |
|---|---|---|---|---|
| property-publish | 46.6 | 335.0 | 327.9 | **63.3% / 64.4%** |
| allocator | −1.9 | 68.6 | 70.3 | 15.5% / 16.5% |
| wrapper-create | −10.1 | 29.9 | 23.6 | 8.8% / 7.7% |
| vm-dispatch | −0.8 | 22.9 | 18.6 | 5.2% / 4.4% |
| teardown | 4.9 | 16.1 | 14.5 | 2.5% / 2.2% |
| env-cells | 0.0 | 1.1 | 1.2 | 0.2% / 0.3% |
| other/unattributed | −0.2 | 20.6 | 19.1 | 4.6% / 4.4% |

property-publish 与 allocator 是**同一条路径**（再定义触发 shape 克隆，克隆再触发分配），
合起来 78.8% / 80.9% × 66.1% = **总差额的 52.1% / 53.0%**。

**结论：找到了一个集中的阶段，且它满足 ≥40% 的停止条件。** 该阶段是
「对一个**已经存在**的 own data property 作再定义」这条路径 —— 入口是
`core.object.Object.defineOwnProperty`，落点是 `core.object.Object.replaceProperty`。

### 1.3 机制（代码层）

zjs `replaceProperty`（`src/core/object.zig:11369-11398`）在写值之前**无条件**调用
`ensureUniqueShapeForMutation`：

```zig
const next_slot = slotFromDescriptor(&rt.atoms, atom_id, merged);
var next_owned = true;
errdefer if (next_owned) destroyPropertySlot(rt, atom_id, next_flags, next_slot);
try self.ensureUniqueShapeForMutation(rt);          // <- 无条件
const old_slot = self.prop_values[index].slot;
self.prop_values[index] = .{ .slot = next_slot };
next_owned = false;
rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.bits());
```

函数对象的 shape 是 hash-cons 的、被其它活着的函数对象共享（`rc != 1`），所以
`ensureUniqueShapeForMutation` 每次都真的克隆一个 shape。gdb 精确计数证实：identifier 目标
比数组元素目标每个闭包**多** `cloneShape` 1.00、`ensureUniqueShapeForMutation` 1.00、
`destroyShape` 1.00、`Registry.release` 1.00、`allocAlignedBytesNoTrigger` **2.00**、
`freeAlignedBytes` **2.00**。

qjs 在同一位置（`quickjs.c:10549-10558`）是纯写值，shape 更新被
`js_update_property_flags`（`quickjs.c:10302-10312`）的 `flags != (*pprs)->flags` 挡住：

```c
} else {
    if (flags & JS_PROP_HAS_VALUE) {
        JS_FreeValue(ctx, pr->u.value);
        pr->u.value = JS_DupValue(ctx, val);      /* 纯写值，零 shape 工作 */
    }
    if (flags & JS_PROP_HAS_WRITABLE) {
        if (js_update_property_flags(ctx, p, &prs, ...))
```

gdb 计数同样证实：qjs 这一次再定义**只多** `JS_DefinePropertyValue` 1.00 与
`JS_AtomToString` 1.00，`add_property` / `js_new_shape2` / `js_free_shape` / `js_malloc`
四项**全部不变**。`name` 的 flags 两次都是 `JS_PROP_CONFIGURABLE`，所以 qjs 的 gate 命中。

shape 克隆及其分配/释放在该阶段内是 **132.8 / 135.4 cyc/op = 26.9% / 28.5%**，
换算到总差额是 **17.8% / 18.6%** —— 它是阶段内最大的单一机制，但单独还不到 40%；
40% 那一档属于「再定义路径」整体（property-publish 41.9% / 42.2%，含 allocator 则 52.1% / 53.0%）。

### 1.4 这个阶段不是「每个闭包创建都命中」

必须说清边界：NamedEvaluation 只在特定源位置生效 —— 变量声明器与标识符赋值
（`const f = () => …`、`g = function () {}`）、对象字面量属性、class field、`export default`
等。**闭包被直接当实参传出或写进成员表达式时不命中**，`a.map(x => x + 1)` 就属于后者。

所以：
- 对「idiomatic 写法的闭包创建」它是命中的，也是 P7-40 那个 3.48x 的主因；
- 对「回调位置的闭包创建」它不命中，剩下的就是 1.5 节的 2.01x。

它也**完全不是闭包专属**的路径：`replaceProperty` 是通用属性再定义，任何
「覆写一个已存在 own data property 且 flags 不变」的写法都在付同一笔。

### 1.5 去掉 NamedEvaluation 之后：cost is spread

把混淆项摘掉后剩下的 2.01x（+216.8 cyc/op），**没有**单一机制够 40%：

| 通用闭包创建+释放（cyc/op） | qjs | zjs-A | zjs-B | 占差额 A | 占差额 B |
|---|---|---|---|---|---|
| wrapper-create | 45.1 | 137.3 | 138.7 | 40.6% | 41.0% |
| property-publish | 101.0 | 191.6 | 187.4 | 39.9% | 37.8% |
| vm-dispatch | −7.8 | 24.2 | 33.2 | 14.1% | 18.0% |
| teardown | 45.6 | 60.5 | 57.6 | 6.5% | 5.3% |
| env-cells | 0.0 | 8.4 | 7.4 | 3.7% | 3.2% |
| allocator | 43.2 | 25.5 | 24.6 | **−7.8%** | −8.1% |
| other/unattributed | 0.4 | 7.1 | 6.9 | 2.9% | 2.8% |
| 合计 | 227.5 | 454.5 | 455.8 | 100% | 100% |

`wrapper-create` 那 40.6% 是**七个函数的和**（`createBytecodeFunctionObjectInternal`
39.4、`createInternal` 22.9、`createObjectRoot` 22.2、`bytecodeFunctionPrototypeForRealm`
11.0、`createWithFamInternal` 10.3、`vm_call.closure` 14.4、`setFunctionBytecodeValue`…），
不是一个机制；组内最大单符号 `createBytecodeFunctionObjectInternal` 只占总差额的
**17.4%**，整段最大的单符号是 property-publish 组的 `Object.defineOwnProperty`，也只有 **21.4%**。
allocator 一项 zjs **净赢 17.7 cyc/op**（slab carve 对 qjs arena 反超）。

因此这一半的结论是 **cost is spread**，本条线不追。

## 2. 裁决顺序

### 2.1 创建 vs 析构 → **创建**

`retain` 生存期让整段 `run()` 交替做 fill（N 次创建、零释放）与 clear（N 次释放、零创建），
harness 对每个 sample 单独 `clock_gettime`，所以**释放确实落在被计时区之外**。
扣 `reuse` 基线后（ns/op，两个 zjs 构建都列）：

| shape | 创建 qjs | 创建 zA | 创建 zB | 比值 A/B | 析构 qjs | 析构 zA | 析构 zB | 比值 A/B |
|---|---|---|---|---|---|---|---|---|
| `arrow_nocap` | 68.2 | 120.4 | 127.0 | 1.77 / 2.02 | 29.4 | 27.3 | 28.3 | **0.93 / 1.09** |
| `fnexpr_nocap` | 76.0 | 136.5 | 138.1 | 1.80 / 1.77 | 28.4 | 33.5 | 33.9 | 1.18 / 1.17 |
| `arrow_cap1` | 70.2 | 151.9 | 146.7 | 2.16 / 1.95 | 31.9 | 36.0 | 31.8 | 1.13 / 0.95 |
| `fnexpr_cap1` | 93.1 | 154.9 | 141.9 | 1.66 / 1.69 | 37.9 | 37.5 | 31.9 | 0.99 / 0.97 |
| `arrow_cap4` | 89.5 | 173.0 | 160.1 | 1.93 / 1.78 | 35.9 | 39.9 | 33.4 | 1.11 / 0.93 |
| `arrow_loopbind` | 96.5 | 174.5 | 176.5 | 1.81 / 1.83 | 42.6 | 42.8 | 49.0 | 1.00 / 1.14 |
| `arrow_call` | 91.8 | 166.6 | 156.9 | 1.82 / 1.67 | 25.9 | 28.3 | 27.0 | 1.09 / 0.93 |

**析构在 7 个 shape × 2 个构建上全部落在 0.93–1.18 之间**，对 `arrow_nocap` 的差额贡献是
**−4.3%（zjs-A）/ +3.5%（zjs-B）**。`perf record` 的 teardown 分组独立给出 6.5% / 5.3%，
两把尺子方向与量级一致。**gap 不在 release/finalization，下一刀不属于 teardown。**

### 2.2 无捕获 vs 有捕获 → **通用函数对象创建**

churn cycles 差额（每个闭包）：

| shape | 动态 capture slot | 差额 zA | 差额 zB |
|---|---|---|---|
| `arrow_nocap` | 0 | +216.8 | +218.8 |
| `arrow_cap1` | 1 | +258.8 | +246.2 |
| `arrow_cap4` | **4** | +301.4 | +291.7 |

**无捕获形态已经背了 `cap1` 差额的 83.8% / 88.9%。** 第一个 slot（含 capture 数组那一次分配）
+42.0 / +27.4 cyc，之后**每个 slot 只有 +14.2 / +15.2 cyc**。`fnexpr` 侧同形
（`fnexpr_nocap` +199.4 → `fnexpr_cap1` +229.2）。

按判据：**cost 是通用函数对象创建**（wrapper 分配、字段初始化、shape/prototype 发布、
GC 发布、拆除），不是 closure environment / VarRef / capture-slot 物化。**不要动捕获路径。**

### 2.3 arrow vs function expression → **没有 arrow 专属惩罚**

| churn，每个闭包 | insn qjs | insn zjs-A | 比值 | cyc 差额 zA |
|---|---|---|---|---|
| `arrow_nocap` | 1 325.4 | 2 484.2 | 1.874 | +216.8 |
| `fnexpr_nocap` | 1 686.1 | 2 688.1 | 1.594 | **+199.4** |

zjs 侧 arrow **比** function expression **便宜**（432.4 vs 468.8 cyc/op）。arrow 的**比值**更差
纯粹因为 qjs 的 function expression 更贵：gdb 计数显示 qjs 对 `fnexpr` 多一次 `add_property`
（`prototype` autoinit）与一次 `js_realloc`（prop_size 2→4），zjs 只多一次
`Registry.release`、`allocated_bytes` 反而**不变**（两侧都 128.0 B）。

**绝对差额上 arrow 比 fnexpr 小 17.4 / 21.0 cyc。** 结论不能记在 lexical `this` /
`arguments` / `new.target` 或任何 arrow 专属 class init 上，**也不能反向推广到所有闭包**。

### 2.4 retain vs churn → 不作为 teardown 减法

两个生存期的 per-op 阶段计数在**除 arena 补给之外的每一项上逐字相同**（第 4 节），
但 churn 比 retain 的 fill+clear 之和便宜，**两侧都如此**：
qjs 55.4 vs 97.6 ns/op，zjs 110.9 vs 147.7 ns/op。这是驻留集与 slot 局部性
（retain 每轮走 20 000 个 slot ≈ 2.5 MB 闭包 + 160 KB 数组；churn 复用同一个 slot），
加上 retain 独有的 0.036–0.054 次/op arena 补给。**因此 retain 减 churn 不是 teardown 成本**，
本报告不作这个减法；创建/析构的拆分一律取 retain 内部的 fill vs clear（拓扑相同）。

### 2.5 第三类：per-iteration lexical binding（**不得推广**）

`arrow_loopbind` 闭合 `for (let i …)` 的每轮绑定，是矩阵里**唯一语义更重**的 shape：

- 每个闭包多一个 cell 的创建与销毁（zjs `VarRef.destroyFromHeader` **1.000/op**，
  qjs `free_var_ref` **2.000/op**、`js_malloc` 从 3 升到 **4**），live bytes 从 128.0 B 升到 184.0 B。
- churn cycles 差额 +312.2 / +321.2，比 `arrow_cap1` 多 **+53.5 / +75.0 cyc**。
- 它也是**唯一**析构侧出现真实缺口的 shape（zjs-B 析构比值 1.14，其余 shape ≤1.18 但方向不定）。

**这是关于「新鲜词法绑定」的发现，不是关于闭包创建的发现**，不得并入 2.2 的通用结论。

### 2.6 create-and-call → 分配与调用**相加**

`arrow_call` 在创建后立刻调用一次。调用腿（`arrow_call` − `arrow_nocap`）：
zjs 165.1 / 162.0 cyc，qjs 89.0 cyc，比值 **1.854 / 1.820**。与 P7-40 记的 VM 调用比值同档，
说明两笔成本**基本相加**，没有互相隐藏。

## 3. 八 case 矩阵

`N = 20 000` 次内层迭代，`--warmup 8`，`reuse` 基线已扣除，`bytes/op` 与
`function alloc/op`、`env-cell alloc/op` 来自独立仪器（第 4/5 节）。
下表 churn 生存期（创建 + 上一个闭包的释放）：

| case | function alloc/op | env-cell alloc/op | bytes/op（q → zjs） | insn/op（q → zA / zB） | cycles/op（q → zA / zB） | ns/op（q → zA / zB） |
|---|---|---|---|---|---|---|
| `reuse-precreated` | 0 | 0 | 0.00 → 0.00 | 基线 | 基线 | 基线 |
| `arrow-no-capture` | 1 | 0 | 113.4 → 128.0 | 1 325.4 → 2 484.2 / 2 480.2 | 215.6 → 432.4 / 434.3 | 55.4 → 110.9 / 110.8 |
| `function-no-capture` | 1 | 0 | 129.5 → 128.0 | 1 686.1 → 2 688.1 / 2 675.3 | 269.4 → 468.8 / 467.1 | 70.3 → 120.7 / 120.0 |
| `arrow-capture-outer` | 1 | 0（cell 复用） | 129.8 → 136.0 | 1 544.6 → 2 851.1 / 2 849.1 | 242.7 → 501.5 / 488.9 | 61.9 → 126.7 / 124.4 |
| `function-capture-outer` | 1 | 0（cell 复用） | 145.9 → 136.0 | 1 908.7 → 3 033.8 / 3 039.7 | 298.8 → 528.1 / 524.9 | 76.7 → 136.1 / 134.6 |
| `arrow-capture-4` | 1 | 0（4 slot 复用同 4 cell） | 153.9 → 160.0 | 1 807.3 → 3 291.9 / 3 274.5 | 289.7 → 591.2 / 581.4 | 74.8 → 145.7 / 144.6 |
| `arrow-loop-binding` ⚠️**语义更重** | 1 | **1** | 186.3 → 184.0 | 1 666.5 → 3 218.5 / 3 219.9 | 262.5 → 574.7 / 583.7 | 68.8 → 147.7 / 149.9 |
| `arrow-create-and-call` | 1 | 0 | 113.4 → 128.0 | 1 799.1 → 3 190.6 / 3 182.2 | 304.6 → 597.5 / 596.4 | 79.2 → 147.7 / 149.6 |

retain 生存期的 insn/cycles 全量在 `P7-50-results.json` 的 `matrix` 里；它的 cycles 有
最高 10.8% 的构建间散度（第 6 节），所以正文一律引 churn。

**语义探针**：`closure_identity_probe` 在 zjs-A / zjs-B / qjs 上全部通过，checksum
三方逐字相同（`6000128`）。它对每个 shape 建 64 个闭包并两两比对 identity、逐个校验捕获值、
校验 own property 不串、校验 arrow 无 `prototype` 而 function expression 的 `prototype`
互不相同；任一条不成立 `run()` 就抛，harness 会当致命错误报出。**所以「没有引擎把闭包
提到循环外或缓存复用」是实测的，不是假设的。**

## 4. 动态计数（每个闭包）

仪器：gdb 断点 + 不可达 ignore count，程序跑到底，`info breakpoints` 报精确命中数。
per-op 值取**同一 case 两个内层规模的差**（`N = 100` 与 `N = 1 100`，除以 1 000），
所以 realm bootstrap、parse、模块级初始化与一次 `run()` 的固定部分**精确抵消**。

**仪器先验证再取零**：正对照 `arrow_nocap` 给出 `js_closure` = 1.0000/op、
`createBytecodeFunctionObjectInternal` = 1.0000/op；负对照 `reuse` 全部为 0，且
`N=100` 与 `N=1 100` 两次的**原始计数逐字相同**。

`retain` 的 create 相（`--iterations 1 --warmup 0`，只跑一次 fill）：

| 阶段 | qjs 符号 | /op | zjs 符号 | /op |
|---|---|---|---|---|
| bytecode 函数对象分配 | `JS_NewObjectFromShape` | 1.000 | `core.object.Object.create` | 1.000 |
| 闭包构造入口 | `js_closure` / `js_closure2` | 1.000 | `createBytecodeFunctionObjectInternal` | 1.000 |
| FunctionBytecode 挂接 | （`js_closure2` 内联） | — | `Object.setFunctionBytecodeValue` | 1.000 |
| prototype 解析 | `find_hashed_shape_proto` | 1.000 | `bytecodeFunctionPrototypeForRealm` | 1.000 |
| root shape 取用 | （同上） | — | `shape.Registry.createObjectRoot` | 1.000 |
| shape 分配 | `js_new_shape2` | **1.000** | `Registry.transitionPropertyUncached` | 1.000 |
| 属性发布 | `JS_DefinePropertyValue` | 2.000 | `Object.defineOwnProperty` | 2.000 |
| shape 迁移 | `add_property` / `add_shape_property` | 2.000 / 1.000 | `Object.adoptShapeForNewProperty` | 1.000 |
| shape 迁移缓存查找 | `find_hashed_shape_prop` | 2.000 | （`tryCachedTransition` 内联） | — |
| shape 释放 | `js_free_shape` | 1.000 | `Registry.destroyShape` | 1.000 |
| name 字符串 | `JS_AtomToString` | 1.000 | `functionNameValueFromAtom` | 1.000 |
| capture 数组 | `js_mallocz` | 0 / **1.000**（有捕获） | `attachFunctionCaptures` | 1.000（无捕获时早退） |
| capture slot 解析 | `get_var_ref` | 0 / 1 / **4** | （`resolveNestedClosureCell` 内联） | — |
| 对象/属性数组分配 | `js_malloc` | **2.999**（loopbind 3.999） | （slab carve 内联；arena 补给 0.036/op） | — |
| **GC** | `JS_RunGC` | **0.001** | `JSRuntime.pollGC` | **0.000** |

`retain` 的 release 相（iterations=2 减 iterations=1）：

| 阶段 | qjs | /op | zjs | /op |
|---|---|---|---|---|
| wrapper finalize | `js_bytecode_function_finalizer` | 1.000 | `Object.destroyFromHeader` | 1.000 |
| zero-ref 排空 | `__JS_FreeValueRT` | 1.000 | `gc.destroyZeroRef` / `destroyZeroRefNow` | 1.000 |
| GC 链解挂 | `free_gc_object` | 1.000 | `gc.Registry.endDecrefPhase` | 1.000 |
| shape 释放 | `js_free_shape` | 1.000 | `Registry.release` | 1.000 |
| cell 释放 | `free_var_ref` | 0 / 1 / **4** / loopbind 2 | `VarRef.destroyFromHeader` | 仅 loopbind 1.000 |

**关键读数：阶段计数两侧几乎逐项对齐。** zjs 没有多出一个 wrapper 分配、多一次 GC 注册、
多一层 cell、或多一次 shape 分配 —— 差距全在**阶段内部的成本**，这就是为什么本条线必须
上符号级归因（第 1.2/1.5 节）而不能停在计数上。

### 4.1 拓扑等价性检查（协调方约束 1）

先踩到一个真陷阱并修掉：最初的 churn 用裸标识符 `g = <expr>` 作 slot，于是它**多付一次
NamedEvaluation 的 `name` 再定义**（qjs 多 1 `JS_DefinePropertyValue` + 1 `JS_AtomToString`；
zjs 多 1 `defineOwnProperty` + 1 `functionNameValueFromAtom` + 1 `cloneShape` +
1 `ensureUniqueShapeForMutation` + 1 `destroyShape` + 1 `Registry.release`）。
两个生存期因此**拓扑不同**，retain−churn 的减法当时是无效的。修法是让两个生存期都经数组元素
赋值（member expression 目标不触发 NamedEvaluation），并把这个混淆项单独立成
`identtarget_*` case —— 它正是 1.1 节那 3.48x 的来源。

等价化之后的实测：

- **每一项 per-op 阶段计数在两个生存期上逐字相同**，唯一例外是分配器 arena 层：
  `SmallObjectSlab.addArena` / `releaseEmptyArena` / `malloc` 在 retain 是 0.036–0.054/op、
  在 churn 是 **0.000/op**（qjs 侧同构：`js_def_malloc` 0.027–0.046 vs 0.000）。
- **GC cadence 两侧、两个生存期全部为零**（`JS_RunGC` 0.001/op，`pollGC` 0.000/op），
  所以「驻留集正好填满 arena 从而偷偷改变分配器行为」这一类事故在 GC 维度上不存在。
- slot 增长维度：retain 的 slots 数组在模块级就被 `null` 填满 N 个，计时环内不再增长
  （无 `expand`/`append` 类命中）。

因此本报告**只**在 retain 内部（fill vs clear，拓扑完全相同）作创建/析构的拆分，
**不**把 retain−churn 当 teardown 成本；arena 补给率的那点差异记在 2.4 节。

## 5. bytes/op 与 capture slope

`retain` 的 `--iterations 1`（收尾在 fill，N 个闭包活着）减 `--iterations 2`（收尾在 clear，零个活着），
除以 N，得到**一个驻留闭包的精确 live bytes**：

| shape | 动态 capture slot | qjs B/op | zjs-A B/op | zjs-B B/op | 比值 |
|---|---|---|---|---|---|
| `arrow_nocap` | 0 | 113.38 | 128.00 | 128.00 | 1.129 |
| `fnexpr_nocap` | 0 | 129.54 | 128.00 | 128.00 | **0.988** |
| `arrow_cap1` | 1 | 129.76 | 136.00 | 136.00 | 1.048 |
| `fnexpr_cap1` | 1 | 145.92 | 136.00 | 136.00 | **0.932** |
| `arrow_cap4` | **4** | 153.93 | 160.01 | 160.01 | 1.040 |
| `arrow_loopbind` | 1 + 1 新 cell | 186.27 | 184.00 | 184.00 | **0.988** |
| `arrow_call` | 0 | 113.38 | 128.00 | 128.00 | 1.129 |

**内存足迹不是 gap**：最差 1.129x，三个 shape 上 zjs 反而更省。

**capture slope 按动态 slot 数而非源变量数**（协调方约束 2）。两条独立读数一致：

- qjs `get_var_ref` = 0 / 1 / **4.000** / loopbind 1.000（release 侧 `free_var_ref` 同数），
  即 `arrow-capture-4` **确实**物化了 4 个 slot，编译器没有合并、丢弃或常量化；
- zjs live bytes：`cap1` − `nocap` = **+8.0 B**（1 个指针），`cap4` − `cap1` = **+24.0 B**
  （3 个指针），`cap4` − `nocap` = +32.0 B = 4 × 8 B。qjs 侧 `cap4` − `cap1` = +24.17 B，同构。

三类必须分开，本报告全程分开：**无捕获**（slot 0）、**捕获既有外层绑定**（slot 1/4，
cell 在一次 `run()` 内被复用，`js_mallocz` 只分配那一个 capture 指针数组）、
**每轮新鲜词法绑定**（slot 1 且**每轮**新建并销毁一个 cell）。

## 6. 测量学

- **层**：same-runtime。源码编译一次，`run()` 被反复调用；每个 sample 由 harness 内部
  `clock_gettime` 单独计时。insn/cycles 用**两个 iteration 计数的整进程 `perf stat` 之差**
  （12 与 52，都取偶数），因此进程启动、runtime/context 创建、parse、compile **精确抵消**，
  不需要「空脚本基线」这种估计量。
- **ABBA 与偶数样本**：sample index 偶数跑 `qjs->zjs`、奇数跑 `zjs->qjs`，与
  `run_same_runtime.js` 逐字同构；`--wall-samples 6`（偶数）、`--wall-iterations 40`（偶数）、
  `--pmu-lo/hi 12/52`（偶数），retain 的 delta 因此含等量 fill 与 clear。
- **pin**：全部 `taskset -c 19`；正式计时与 `perf` 全程持 `flock -x /tmp/zjs-host-heavy.lock`。
- **两个 PMU**：CPU 19 在 `armv8_pmuv3_1`，采集器显式识别 sysfs 里包含该 CPU 的设备并
  **丢弃** `armv8_pmuv3_0` 的 `<not counted>` 行，不做求和。
- **每侧两个冷缓存构建，全组合报告**：zjs 两次构建**字节不同**
  （`2ddbc16a…` / `f2e58958…`）—— **这是真的 bistability 场景，不是免费噪声尺**；
  qjs 两次构建**字节相同**（`0ad62282…`），所以 qjs 侧只有一个实例。
- **构建间散度**：instructions 全矩阵最差 **0.91%**，中位 0.20%。cycles 分裂得很清楚 ——
  **churn 最差 2.54%**，**retain 最差 10.77%**（`arrow_cap4`：843.8 vs 757.6 cyc/op，
  而同一对的 instructions 只差 0.24%）。指令数几乎相同而 cycles 差一位数百分点，
  说明 retain 的散度来自内存系统（2.5 MB 驻留闭包 + 数组遍历随二进制布局漂移），
  不是代码量。**因此正文所有 headline 数字取自 churn**，retain 只用于创建/析构拆分
  （那里两个构建的定性结论一致：析构比值 0.93–1.18）。
- **指令与 cycles 不同向的地方**：`fnexpr` 系列 insn 比值 1.55–1.59 而 cycles 比值
  1.74–1.77；`arrow_nocap` churn insn 1.874 而 cycles 2.006。两者都测了，两者都报。

## 7. 没有建立的事

1. **PMU 的 fill/clear 拆分不可用，已弃用。** 用相邻 iteration 计数差去隔离**单个** sample
   （i=12/13/14）时，一个 sample 的 ~12 M cycles 落在 ~350 M cycles 的整进程上，噪声压过信号，
   算出来出现负值（`arrow_call` fill −3.8 cyc/op、`arrow_loopbind` clear −34.6 cyc/op）。
   数据保留在 `raw/matrix.json` 的 `pmu_split` 里但**未采用**。创建/析构的拆分因此靠
   wall-clock 逐 sample 计时 + `perf record` 的 teardown 分组两把独立尺子，
   **没有 per-phase 的指令数**。
2. **zjs 的每对象分配计数没有测到。** slab carve 是内联的，只测到未内联的分配入口
   （`allocAlignedBytesNoTrigger`）与 arena 补给率，加上精确的 bytes/op。qjs 侧测到了
   （`js_malloc` 2.999–3.999/op）。两侧的分配**计数**因此不可直接相比，只有 bytes/op 可比。
3. **zjs 侧没有直接的 capture-slot 计数器**：`resolveNestedClosureCell` 被内联，
   slot 数由 qjs 的 `get_var_ref` 加 zjs 的 bytes/op 差分交叉确认（第 5 节），
   不是 zjs 自己的计数器读出来的。
4. **没有解释 1.5 节那 2.01x 里的 IPC 成分。** 只采了 instructions/cycles，
   没采 cache-miss / branch-miss / stall 分解。
5. **没有验证那一刀安全或有收益。** 本条线不实现、不 A/B、不跑门禁。
   「`replaceProperty` 在 flags 不变时跳过 shape 克隆」是从 qjs `js_update_property_flags`
   读出来的**结构对照**，不是实测过的改动 —— 特别地，`ensureUniqueShapeForMutation`
   在 var_ref 分支（`replaceProperty` 前半段）仍然是必需的，`updatePropertyFlags`
   与 relocation 的交互没有审。
6. **没有测 NamedEvaluation 的其它源位置**（对象字面量属性、class field、`export default`、
   默认值）。结论只在「标识符赋值目标」这一种写法上实测过；把它推广到全部 NamedEvaluation
   位置是代码层推断。
7. **没有把 P7-40 的 `map_inline_arrow` 重新分解。** `a.map(x => x + 1)` 的箭头在**实参位置**，
   不触发 NamedEvaluation，所以 P7-40 记在它头上的 48.1% 闭包分配份额对应的是本报告
   1.5 节那 2.01x，而不是 3.48x。这一条改的是 P7-40 的**解释**，不是它的数字，本条线没有重跑 `map`。

## 8. 给下游的一句话

- **给下一刀**：`core.object.Object.replaceProperty` 无条件的
  `ensureUniqueShapeForMutation` 是唯一集中、单机制、且有 qjs 直接对照
  （`js_update_property_flags`，`quickjs.c:10302-10312`）的候选。它在 3.48x 那个案例里占
  cycles 差额的 17.8%，所在的「已存在属性再定义」整条路径占 **52.1%**。
  它**不是闭包专属**的，因此收益面比闭包大得多。
- **给 P7-20 / 任何引用 2.6x/3.2x 的地方**：这个比值必须重新标注为
  **「NamedEvaluation 位置的闭包创建」**，不能写成「闭包分配」。
  去掉该混淆项后的通用闭包创建是 1.87x insn / 2.01x cycles，且 **cost is spread**。
- **不要做的事**：不要动捕获/VarRef 路径（2.2 节，每 slot 只有 14 cyc 的差额）；
  不要做 arrow 专属处理（2.3 节，zjs 的 arrow 本来就比 function expression 便宜）；
  不要在 teardown 上动刀（2.1 节，析构 0.93–1.18x 已经平价）。
