# P7-41：builtin→JS 回调桥是共用税还是 `map` 专属

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码，不提方案
- 起点：`perf/qjs-align-p7-builtin-bridge` @ `18816862`
- 对照引擎：pinned Bellard QuickJS `04be2460`（二进制 sha256 `b76d1542…`，与 P7-20 / P7-40 同一个文件）
- 依据：`P7-40-array-map-decomposition/`
- 数据产物：`P7-41-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/builtin_bridge/`（case 生成器、采集器、gdb 计数器、`perf record` 归属器、分析器）

## 1. 结论

### 1.0 正式裁决（2026-07-30 关闭为 attribution success）

```text
Decision:
    shared builtin-to-bytecode callback bridge tax confirmed

Canonical estimate:
    27.43 cycles/callback on dense, no-result-write Array builtins

Mechanism boundary:
    SyncInternalCallSite.call / native_fence_run path,
    one hit per callback and zero hits in mirrored direct-loop controls

Production action:
    deferred pending phase-level attribution and P7-50 priority comparison
```

结论的正确读法是：

```text
共享固定桥接税 ≈ 27 cycles/callback
+ 各 builtin 自身独立的元素读取 / 写入成本
```

**适用范围（本条线实际证明的边界）**：dense Array builtin、same-runtime 层、同步 bytecode
callback、当前 active-Machine reuse 路径、无 hole / sparse 特殊语义。

**以下均不可外推，本条线没有证明**：

- 并非所有 native→JS 调用都有相同成本；
- TypedArray callback、`find` / `findIndex` 族、跨 realm 未覆盖；
- 那 27 cycles **尚未**精确定位到 native fence 中的某几条指令；
- `SyncInternalCallSite.call + runTC` 占 builtin cycles 的 54.4% **不等于**这 54.4% 都是可删除成本。

目前确认的只是**桥接路径是成本载体**，尚未确认其中哪个阶段构成下一笔 one-cut。因此本条线
**不进入生产改动**，并明确不做：删除 native fence、绕过 `SyncInternalCallSite.call`、
为 Array builtin 加专用 bytecode callback bypass、把 callback 直接塞进当前 VM dispatch、
或按 builtin 名字做 fast path。这些都会重复本战役已多次出现的失误 ——
**热点符号已定，但符号内可消除的机制未定就下刀**。

**下一步（条件性）**：若 P7-50 最终没有更集中的目标，则开 **P7-42：builtin→JS bridge
phase attribution**，只拆这约 27 cycles，用同一个 callback、同样三个实参、相同调用次数，
对比 `direct JS→JS call` 与 `builtin native→JS callback`，逐阶段归因：native fence
enter/exit、active Machine 获取与恢复、root/fence publication、callback argument staging、
bytecode frame admission/setup、`special_return` / native caller publication、
callback result handoff、返回 builtin 的恢复。停止条件同本线：找到每 callback 必经、
解释桥接差距约 ≥40%、可单机制隔离的阶段；否则记为**分散控制税**，不靠猜测下刀。

### 1.1 裁决

**是共用税，不是 `map` 专属。** 六个 Array builtin 全部同向，四个干净量级一致，且**动态调用链逐项完全相同**。

`Array.prototype` 的 5 个迭代型方法（`forEach`/`map`/`filter`/`some`/`every`）在 zjs 里是**同一个函数实例**
`qjsArrayIterationModeCall(false, …)`，`reduce` 是 `qjsArrayReduceCall`；两者都通过同一个
`SyncInternalCallSite` 回调桥。本条线在同层直接循环对照下测到，那座桥每次回调比 zjs 自己的
VM 调用多花 **约 27 cycles**，而 qjs 在同一把尺下**接近零**。

主表（cycles / 每次回调，scaffold-corrected 口径，两个独立复现的中位数）：

| builtin | qjs bridge_tax | zjs bridge_tax | **zjs_specific** | spec 口径 | 每元素结果写 | dense 源读 |
|---|---:|---:|---:|---:|---|---|
| `forEach(noop)` | +5.39 | +30.26 | **+24.87** | +27.77 | 无 | 是 |
| `some(alwaysFalse)` | +3.78 | +33.34 | **+29.55** | +32.43 | 无 | 是 |
| `every(alwaysTrue)` | +3.58 | +29.57 | **+25.99** | +28.91 | 无 | 是 |
| `filter(alwaysFalse)` | −4.26 | +24.62 | **+28.87** | +32.20 | 无（0 次） | 是 |
| `filter(alwaysTrue)` | +7.70 | +9.76 | +2.06 | +5.39 | **有（N 次）** | 是 |
| `map(identity)` | +25.22 | +27.05 | +1.83 | +3.70 | **有（N 次）** | 是 |
| `reduce(returnAcc)` | +2.63 | +58.01 | +55.38 | +58.33 | 无 | **否**（atom+has+get） |

- **七个 rung 全部同向为正**（7/7）。
- 前四个（无每元素结果写、走 dense 快腿）落在 **+24.87 … +29.55**，中位 **+27.43**，极差 4.68 = 中位的 17%。
- 其中**三个完全不建结果数组**（`forEach`/`some`/`every`）都显著为正，满足「至少一个无结果数组的 builtin 也要出现」这一条。

### 1.2 剩下三个 rung 的离散度已被定量解释，不是三笔不同的账

表面上极差是 +1.83 … +55.38（30 倍）。这个离散度**不是**「桥税只在某些 builtin 上存在」，而是两条
**已独立量出的每元素轴**叠加在同一个共用常数上：

- **每元素结果写轴（−25 cycles）**。`map` 与 `filter(alwaysTrue)` 的对照循环用 `out[j] = …`
  （bytecode Set），builtin 用 Define。两条独立配对给出同一个位移：
  `filter(alwaysTrue) − filter(alwaysFalse) = −26.81`（同一个 builtin、同一个对照形状，唯一差别是
  谓词让写发生 N 次还是 0 次），`map − forEach = −23.05`。P7-40 已量到 zjs 的 dense define 比 qjs
  的四层 define 链便宜，同时 zjs 的 bytecode Set 比 qjs 贵，两个效应同向压低残差。
- **reduce 源读轴（+28 cycles）**。zjs 的 `reduce` 元素读**没有 dense 快腿**：
  `propertyAtomFromLengthIndex` + `hasValueProperty` + `getValueProperty`
  （`src/exec/array_ops.zig:2027-2032`）。动态计数直接坐实：`reduce` 的 `hole_check` 是
  **1.000/回调**，而迭代族是 **0.000**；qjs 两族都是 `JS_HasProperty` 1.000/回调。这条不对称全部落进
  `reduce` 的残差里。`reduce` 残差比干净中位高 **+27.95**。

单常数加两轴的模型在七个 rung 上闭合：

| rung | 共用桥 | + 结果写轴 | + reduce 源读轴 | 预测 | 实测 |
|---|---:|---:|---:|---:|---:|
| `forEach`/`some`/`every`/`filter(false)` | +27.4 | — | — | +27.4 | +24.9 … +29.6 |
| `map`、`filter(true)` | +27.4 | −25.0 | — | +2.4 | +1.83、+2.06 |
| `reduce` | +27.4 | — | +28.0 | +55.4 | +55.38 |

### 1.3 三条独立旁证，全部指向 native frame → JS bytecode 这一段

1. **换 native 回调，zjs 的赤字整体消失。** 同一个 `map`、同一个数组：
   `map(cb_ident)`（JS bytecode 回调）qjs 108.32 / zjs 139.50 cyc/回调（zjs +31.18）；
   `map(Math.abs)`（native 回调）qjs 99.75 / zjs **95.55**（zjs **−4.20，反超**）。
   把回调从 JS 换成 native，zjs 每次省 43.95 cycles，qjs 只省 8.57 —— 差额 35.4，与实测桥税同量级。
   **builtin 的迭代、species、结果数组都没变，变的只有被调用方是不是 bytecode。**
2. **`thisArg` 不是原因。** `forEach(cb, host)` 对 `forEach(cb)`：qjs −0.198、zjs +0.258 cyc/回调
   （`zjs_specific` **+0.456**；instructions 侧 +0.369 / +0.351，`zjs_specific` −0.018）。
   `this` / native-caller 转发这一段两侧都几乎免费。
3. **`perf record` 的减法归属。** 同一个回调、同一个元素读，builtin 与镜像对照各录一次（cycles，≥0.4%）：

| | qjs builtin | | zjs builtin | | qjs 对照 | | zjs 对照 | |
|---|---|---:|---|---:|---|---:|---|---:|
| 1 | `JS_CallInternal` | 64.93 | `SyncInternalCallSite.call` | **35.02** | `JS_CallInternal` | 99.83 | `opCall…h` | 25.87 |
| 2 | `js_array_every` | 8.30 | `op_return_undef` | 29.70 | — | | `op_return_undef` | 25.21 |
| 3 | `JS_GetOwnPropertyInternal` | 7.13 | `zjs_vm.runTC` | **19.34** | — | | `opLocCheckWithInt32SlotMove…h` | 14.20 |
| 4 | `JS_HasProperty` | 7.02 | `qjsArrayIterationModeCall` | 13.35 | — | | `op_get_array_el` | 8.57 |
| 5 | `JS_TryGetPropertyInt64` | 5.96 | | | — | | `op_if_false8` | 7.06 |

`SyncInternalCallSite.call` + `runTC` 合计 **54.4%** 的 builtin cycles，在对照 profile 里是 **0%**。
qjs 侧的对照更极端：**一个 `JS_CallInternal` 吃掉 99.83%** —— 因为 qjs 的解释器用 C 递归实现调用，
builtin 回调与 `OP_call` 是**同一个函数的同一次进入**，所以它没有桥可言。

### 1.4 IPC：指令没多多少，周期多了

| case | qjs insn/回调 | zjs insn/回调 | 比 | qjs cyc/回调 | zjs cyc/回调 | 比 | qjs IPC | zjs IPC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `forEach` builtin | 442.84 | 532.40 | 1.202 | 60.09 | 101.21 | **1.684** | 7.37 | **5.26** |
| `forEach` 对照 | 566.23 | 609.98 | 1.077 | 84.88 | 98.24 | 1.157 | 6.67 | 6.21 |
| `some` builtin | 478.10 | 563.56 | 1.179 | 65.81 | 109.19 | **1.659** | 7.26 | **5.16** |
| `some` 对照 | 588.76 | 622.52 | 1.057 | 92.23 | 103.18 | 1.119 | 6.38 | 6.03 |
| `every` builtin | 474.99 | 560.68 | 1.180 | 65.43 | 106.54 | **1.628** | 7.26 | **5.26** |
| `every` 对照 | 591.75 | 625.52 | 1.057 | 92.06 | 104.26 | 1.133 | 6.43 | 6.00 |
| `map` builtin | 761.90 | 740.04 | **0.971** | 108.32 | 139.50 | 1.288 | 7.03 | 5.30 |

两侧 IPC 差在**对照里只有 0.4-0.5**，在 **builtin 里扩到 2.0-2.1**。`map` 更极端：zjs 指令**更少**
（0.971）而 cycles 多 28.8%。与 P7-40 §1.4 同向：这一段的差**不是**「zjs 跑了更多指令」。
本条线没有采 stall / miss 事件，所以仍然没有解释 IPC 差从哪来（§7）。

### 1.5 与 P7-40 的 +36.33 / +1.38 的关系

同向、同量级，本条线的值系统性低约 25%：

| | qjs | zjs | zjs−qjs |
|---|---:|---:|---:|
| P7-40（`map`、LEN=10、内联箭头、VM 梯子口径） | +1.38 | +36.33 | +34.94 |
| P7-41（干净四 rung 中位、LEN=100、预声明函数、镜像对照口径） | +3.58 … +5.39 | +24.6 … +33.3 | **+27.43** |

差异有三个已知来源：LEN 10 → 100 稀释了每调用常数；回调体与 arity 不同；估计量不同
（P7-40 减的是一条分解过的 VM 梯子，本条线减的是同层镜像对照）。**两个数都不是「桥的绝对成本」**，
因为两者都把 VM 的元素读成本记在 builtin 账上。可以坐实的是：**P7-40 的 73% 归因方向正确，
而且这笔税不属于 `map`。**

### 1.6 通用性门槛的逐条对账，以及两个否定裁决为何都不成立

按裁决顺序（per-builtin bridge_tax → 跨 builtin 离散度 → 共用动态链 → 4/6 门槛）：

| 门槛条 | 结果 |
|---|---|
| ≥ 4/6 同向 | **6/6**（七个 rung 全部为正；`filter` 的两个变体都为正） |
| 每回调量级相近 | **4/6**：`forEach` +24.87、`some` +29.55、`every` +25.99、`filter` +28.87，落在中位 ±17% 内 |
| 动态调用链相同 | **6/6 逐项相同**：八个阶段各 1.000/回调、十一个阶段各 0.000，对照里全为 0（§3） |
| 至少一个无结果数组的 builtin 也出现 | **3 个**：`forEach`、`some`、`every` |

`filter` 取 `alwaysFalse` 变体作它的代表值，理由是可检验的而不是选择性的：两个变体是**同一个 builtin、
同一个对照形状**，唯一差别是谓词让每元素结果写发生 N 次还是 0 次，所以 `alwaysFalse` 是这个 builtin
未被写轴污染的读数，`alwaysTrue` 是「桥 + 写轴」。两个值都列在主表里。

**否定裁决一「只有 `map`/`filter` 显著 → 与结果数组或每元素 define 绑定，不通用」不成立。**
事实恰好相反：`map` 与 `filter(alwaysTrue)` 是**唯一两个不显著**的 rung（+1.83 / +2.06），
而三个完全不建结果数组、不做任何 define 的 rung 是显著的（+24.87 / +29.55 / +25.99）。
若这笔税绑定在结果数组上，`forEach`/`some`/`every` 应当读到 0。

**否定裁决二「builtin 减直接循环接近零 → P7-40 的 +36 是模型误差或别的阶段」不成立。**
干净四 rung 的 `zjs_specific` 是 +24.9 … +29.6 cyc/回调，两次独立复现极差 ≤ 0.58，
远离零；同一把尺下 qjs 读到 −4.26 … +5.39（估计量自校准，见 §2.5）。
方向与量级都复现了 P7-40 的 +36.33 / +1.38（§1.5）。

## 2. 工作负载与两条验收约束

### 2.1 统一形状

预建 dense 整数数组（`[1..100]`，字面量、无洞）、**预声明且不捕获**的回调（只读自己的形参，
所以不会每轮新建闭包 —— P7-40 发现内联箭头的闭包分配是另一笔占 48% 的、与 `map` 无关的账）、
固定长度、强制走完全程、第一轮除专门变体外**不传 `thisArg`**。所有绑定函数局部化，避免把 P7-20
记录的顶层词法绑定税折进每一级。谓词的选择让回调恰好跑 `LEN` 次：`some` 用 always-false、
`every` 用 always-true，两者都不短路。

### 2.2 约束一：对照必须逐字复现回调 ABI —— 已实测

由回调**自己**在两个引擎上核对它被交到手里的东西，一次经 builtin、一次经镜像对照
（`tools/perf/builtin_bridge/cases/verify_*.js`，不计时）。字段为
`calls / bad_argc / bad_receiver_array / bad_index / bad_value / this_is_globalThis`：

| case | qjs | zjs |
|---|---|---|
| `map` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `forEach` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `filter(false)` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `filter(true)` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `some` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `every` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |
| `reduce` | builtin=100/0/0/0/0/100 control=100/0/0/0/0/100 | 同 |

即：`arguments.length` 与 builtin 一致（迭代族 3、`reduce` 4）、第三/第四个实参**是同一个源数组对象**、
index 等于调用序号、value 等于 `a[index]`、**`this` 在 builtin 与直接循环下同样 100/100 次
`=== globalThis`**（脚本非严格模式，两条路径传的都是 undefined，被调用方同样替换为全局对象）。
七个 case 两个引擎逐字节同输出。

**死存储守卫。** `c_map` 的 sink 是 `out.length`（无论回调返回什么都是 100），所以另加一对
checksum 双胞胎 `b_map_sum` / `c_map_sum`，把结果数组每个元素求和后打印，两个引擎都打印 `5050`
—— 每次回调的返回值都可证地到达了输出。builtin 减对照的差额（cycles/回调）：

| | qjs | zjs | zjs_specific |
|---|---:|---:|---:|
| `map` 原口径（sink=`length`） | −4.632 | −0.932 | **+3.700**（两次复现 3.646 / 3.754） |
| `map` checksum 口径 | −5.342 | −4.884 | +0.458（两次复现 2.691 / −1.774） |

两个口径都远离干净 rung 的 +27，与 §1.2 的结果写轴解释一致；**没有任何一侧在消除写入**
（打印 5050 就是直接证据，且求和循环本身在 builtin 与对照两侧各花约 49-54 cyc/回调，量级相同）。
一处诚实标注：`c_map_sum` 的 zjs 侧在两次复现间位移 **2.6%**（191.75 → 196.85 cyc/回调），
是整个 corpus 里唯一超过 0.6% 的 case（它每轮分配一个 100 元素数组再全量读回，分配相位最重），
所以 checksum 口径的 `zjs_specific` 本身带 ±2 cycles 的不确定度。主表不使用这一对。

### 2.3 约束二：回调次数动态实测，两侧一致

§2.2 的 `calls` 列就是动态实测值：七个 case、两个引擎，builtin 与对照**全部 100 = LEN**。
没有任何 case 出现两侧次数不同，因此七个 rung 全部有资格进入每回调归一化。
引擎内部计数独立印证：zjs `SyncInternalCallSite.call` 恰好 1.000/回调（§3），
qjs 的 `JS_CallInternal` 在对照里恰好 1.000/回调、在 builtin 里 1.000 加上每次 builtin 调用的
C-function 帧与 species getter。

### 2.4 一处对照缺陷及其修正（第一轮 → 第二轮）

第一轮 `c_every` 写成 `if (!cb_true(…))`。测出来 `every` 的 `zjs_specific` 只有 +10.29，
与 `some` 的 +32.37 不符 —— 而两个 **builtin** 在两侧都几乎相同
（`b_some` / `b_every`：qjs 65.81 / 65.43，zjs 109.19 / 106.54）。用一个专门探针定位到病根是那个 `!`：

| 探针（一个 `!` 作用在可变局部上，分支两侧都不跳） | qjs | zjs | zjs−qjs |
|---|---:|---:|---:|
| `lnot` 每元素 instructions | 17.998 | 91.067 | **+73.07** |
| `lnot` 每元素 cycles | 3.061 | 18.165 | **+15.11** |

`perf record` 给出机制：zjs 的 `every` 对照 profile 里 `exec.vm_value.logicalNot` 占 **9.02%**
（一个 out-of-line 辅助函数；op 表里没有 `op_lnot` 快 handler），qjs 侧没有对应项。
这是一笔与本条线无关的 zjs 侧真实分歧，此处只作为对照工件处理：第二轮把 `every` 的主对照换成
无取反的 `if (cb_true(…)) { continue; } hit = 0; break;`。改完后 `c2_every`（92.06 / 104.26）
与 `c_some`（92.23 / 103.18）几乎逐字相等，`every` 的残差从 +10.29 回到 +25.99。
第一轮的 `c_every` 保留在 corpus 与 JSON 里，工件不藏。

### 2.5 两个估计量

```
load(case)          = median(整进程) − median(同引擎空脚本)
bridge_tax_spec     = (load(builtin) − load(mirrored control)) / callback_count
intercept(case)     = load(len-0 双胞胎) / iterations            # 每次 builtin 调用
slope(case)         = (load(case)/iterations − intercept) / LEN  # 每元素
bridge_tax_slope    = slope(builtin) − slope(control)
bridge_tax_scaffold_corrected
                    = slope(builtin) − (slope(control) − slope(bare inner loop))
zjs_specific        = bridge_tax(zjs) − bridge_tax(qjs)
```

`spec` 是任务给定的形式；`slope` 用长度 0 双胞胎扣掉每调用常数（species 查找、结果数组构造、
builtin 入口）；`scaffold_corrected` 再把 bytecode 循环脚手架（计数器、边界比较、回跳）加回去，
因为 builtin 那一侧的对应物是 C 循环 —— 这是与 P7-40 口径可比的那一个，也是主表用的口径。
脚手架单独量出来是 qjs **31.12** / zjs **29.20** cyc/元素，两侧几乎相等，所以三个口径的
`zjs_specific` 相差只有 1.9-3.6 cycles（主表最后两列可见）。**结论不依赖口径选择。**

`bridge_tax(qjs)` 同时是估计量的**自校准**：动态计数证明 qjs 的 builtin 回调与它自己的 VM 调用是
同一次 `JS_CallInternal`（§3），所以 qjs 那一列量的就是估计量自身的残余偏置。干净四 rung 上它是
**−4.26 … +5.39**，接近零；`map` 上它是 **+25.22**，这本身就证明 `map` 那一格被结果写轴污染了
（污染在 qjs 单侧就有 +21 cycles），而不是证明桥在 `map` 上消失了。

## 3. 动态调用链：七个 rung 逐项相同，对照里逐项为零

gdb 断点配不可达 ignore 计数（`ignore N 2e9`），进程跑到底后 `info breakpoints` 给精确命中数；
同一把尺对准两个引擎，两侧源码都没改。被 LLVM inline 掉、没有符号的桥阶段用 **gdb 行号表**取
（`inline fn` 的每份内联副本都还带行记录，gdb 报一个 `<MULTIPLE>` 断点并给出跨副本合计）。
Zig 的 `__anon_NNNNN` 后缀每次构建都会变，所以符号名一律用正则从本二进制的符号表现场解析
（P7-40 是硬编码的，那些编号已经变了）。

下表是每次回调值（100 次 builtin 调用 × 100 元素，扣同二进制空脚本基线），`c` 列是该 builtin 的镜像对照：

| zjs 计数项 | `map`/c | `forEach`/c | `filter(f)`/c | `filter(t)`/c | `reduce`/c | `some`/c | `every`/c |
|---|---|---|---|---|---|---|---|
| builtin 本体入口（每次调用） | 1/0 | 1/0 | 1/0 | 1/0 | 1/0 ¹ | 1/0 | 1/0 |
| **JS 回调派发** `SyncInternalCallSite.call` | **1.000**/0 | **1.000**/0 | **1.000**/0 | **1.000**/0 | **1.000**/0 | **1.000**/0 | **1.000**/0 |
| native fence 建域 `NativeBoundaryScope.init` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **native caller 发布** `NativeBoundaryScope.push` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **native fence 进入** `runActiveInvocationUntilNativeBoundary` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **VM 重入** `zjs_vm.runTC` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| 返回时 special 判定 `hasSpecialReturn()` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **`special_return` native-boundary 臂** | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **native fence 释放** `NativeBoundaryScope.finish` | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 | 1.000/0 |
| **new-Machine** `runWithCallEnvAfterInterruptPoll` | **0**/0 | **0**/0 | **0**/0 | **0**/0 | **0**/0 | **0**/0 | **0**/0 |
| 通用回退 `callValueOrBytecodeDispatchAfterInterruptPoll` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| fence 错误路径 `NativeBoundaryScope.deinit` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| native caller 释放 `Entry.releaseNativeCaller` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| owned/moved 实参路线（三个） | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| 慢腿 boundary push（两个）+ `setupNativeBoundarySimpleEntry` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| 帧建立 `FrameSlab.carve` / `allocHeap` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| `op_return` / `op_return_undef`（回调体本身） | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| dense 源元素读 `getDenseArrayElementValue` | 1/0 | 1/0 | 1/0 | 1/0 | 1/0 | 1/0 | 1/0 |
| **hole check** `hasValueProperty` | 0/0 | 0/0 | 0/0 | 0/0 | **1.000**/0 | 0/0 | 0/0 |
| 结果 define `defineDenseArrayDataPropertyUnchecked` | 1/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |

¹ `reduce` 走 `qjsArrayReduceCall`，其余六个走同一个 `qjsArrayIterationModeCall__anon_85061`。

**八个阶段在七个 rung 上都恰好 1.000/回调，十一个阶段恰好 0.000，而全部对照的这十九项都是 0。**
`op_return` / `op_return_undef` 在 builtin 与对照里同为 1/1（回调体逐字相同），
所以差额不在「返回族被多走了」。这不是「几笔不同的成本恰好同号」——它是同一条链。

同一把尺量 qjs（每次回调）：

| qjs 计数项 | builtin | 对照 |
|---|---:|---:|
| `js_array_every` / `js_array_reduce` | 0.010（= 每次调用 1） | 0 |
| **`JS_CallInternal`** | **1.010 – 1.020** ² | **1.000** |
| `js_call_c_function` | 0.010 – 0.020 | 0 – 0.010 |
| `JS_TryGetPropertyInt64` / `JS_GetPropertyValue` / `JS_HasProperty` | 1.000 各 | 0 |
| `JS_DefinePropertyValueValue` | 1.000（`map`/`filter(t)`） | 0 |
| `expand_fast_array` | 0.130（`map`/`filter(t)`） | 0.130 |

² 超出 1.000 的部分是每次 builtin 调用的 C-function 帧与（`map`/`filter`）species getter，不是每元素项。

**这一行就是 qjs 为什么没有桥税**：它的 builtin 回调和它的 VM 调用是**同一个 `JS_CallInternal`**，
计数相同、符号相同（`perf record` 里对照 profile 99.83% 都在这一个符号上）。zjs 的对应位置要
建 native fence 域、发布 native caller、**重新进入一次 `runTC`**、在返回时走 `special_return`
的 native-boundary 臂、再释放 fence —— 八个阶段，每次回调一遍。

顺带排除的两件事：**回退不是原因**（`callValueOrBytecodeDispatchAfterInterruptPoll` 净命中 0，
一百万次回调全部由预解析 route 承担），**Machine 不是每次新建的**
（`runWithCallEnvAfterInterruptPoll` 净命中 0，活动 Machine 每次都被复用）。

## 4. 同层原始数据

每次回调载荷（整进程中位数减同引擎空脚本基线，除以 1e6 次回调）。LEN=100、外层 1e4 轮。

| case | qjs insn | zjs insn | 比 | qjs cyc | zjs cyc | 比 |
|---|---:|---:|---:|---:|---:|---:|
| `b_map` | 761.90 | 740.04 | 0.971 | 108.32 | 139.50 | 1.288 |
| `c_map` | 742.59 | 850.14 | 1.145 | 112.95 | 140.43 | 1.243 |
| `b_foreach` | 442.84 | 532.40 | 1.202 | 60.09 | 101.21 | 1.684 |
| `c_foreach` | 566.23 | 609.98 | 1.077 | 84.88 | 98.24 | 1.157 |
| `b_filter_false` | 491.70 | 582.98 | 1.186 | 68.24 | 112.28 | 1.645 |
| `c_filter_false` | 649.88 | 682.30 | 1.050 | 101.02 | 112.86 | 1.117 |
| `b_filter_true` | 805.00 | 841.92 | 1.046 | 116.14 | 148.57 | 1.279 |
| `c_filter_true` | 913.63 | 996.15 | 1.090 | 136.99 | 164.03 | 1.197 |
| `b_reduce` | 470.83 | 872.24 | **1.853** | 65.88 | 161.55 | **2.452** |
| `c_reduce` | 622.76 | 762.56 | 1.224 | 93.51 | 130.86 | 1.399 |
| `b_some` | 478.10 | 563.56 | 1.179 | 65.81 | 109.19 | 1.659 |
| `c_some` | 588.76 | 622.52 | 1.057 | 92.23 | 103.18 | 1.119 |
| `b_every` | 474.99 | 560.68 | 1.180 | 65.43 | 106.54 | 1.628 |
| `c_every`（第一轮，含 `!`） | 609.76 | 716.61 | 1.175 | 95.98 | 126.56 | 1.319 |
| `c2_every`（第二轮，无取反） | 591.75 | 625.52 | 1.057 | 92.06 | 104.26 | 1.133 |
| `b_map_native`（`Math.abs`） | 681.62 | 548.06 | **0.804** | 99.75 | 95.55 | **0.958** |
| `c_map_native` | 801.70 | 973.42 | 1.214 | 130.25 | 167.98 | 1.290 |
| `b_foreach_thisarg` | 443.21 | 532.75 | 1.202 | 59.89 | 101.47 | 1.694 |
| `b_map_sum`（checksum） | 1074.00 | 1047.48 | 0.975 | 157.10 | 189.42 | 1.206 |
| `c_map_sum`（checksum） | 1054.05 | 1150.36 | 1.091 | 162.44 | 194.30 | 1.196 |

长度 0 截距（每次 builtin 调用 / 每轮外层迭代，外层 1e5 轮）：

| case | qjs insn | zjs insn | 比 | qjs cyc | zjs cyc | 比 |
|---|---:|---:|---:|---:|---:|---:|
| `b0_map` | 2420.07 | 3014.72 | 1.246 | 400.61 | 548.89 | 1.370 |
| `c0_map` | 1752.67 | 2358.72 | 1.346 | 279.46 | 440.67 | 1.577 |
| `b0_foreach` | 844.65 | 1241.71 | 1.470 | 142.27 | 232.81 | 1.636 |
| `c0_foreach` | 329.37 | 300.52 | 0.912 | 53.62 | 54.90 | 1.024 |
| `b0_filter_false` | 2421.87 | 2995.59 | 1.237 | 397.87 | 544.23 | 1.368 |
| `c0_filter_false` | 888.27 | 1017.14 | 1.145 | 143.70 | 156.95 | 1.092 |
| `b0_filter_true` | 2426.72 | 2997.95 | 1.235 | 395.52 | 542.61 | 1.372 |
| `c0_filter_true` | 888.33 | 1016.97 | 1.145 | 142.90 | 157.77 | 1.104 |
| `b0_reduce` | 848.48 | 1319.62 | 1.555 | 141.58 | 237.45 | 1.677 |
| `c0_reduce` | 378.54 | 348.90 | 0.922 | 61.31 | 62.94 | 1.027 |
| `b0_some` | 862.54 | 1254.92 | 1.455 | 147.27 | 236.35 | 1.605 |
| `c0_some` | 378.77 | 348.89 | 0.921 | 60.90 | 62.07 | 1.019 |
| `b0_every` | 854.63 | 1266.27 | 1.482 | 146.84 | 239.47 | 1.631 |
| `c20_every` | 378.73 | 348.65 | 0.921 | 61.42 | 61.87 | 1.007 |
| `s0_loop`（裸循环脚手架） | 286.27 | 262.69 | 0.918 | 47.67 | 49.07 | 1.029 |

两处要读出来的东西：

1. **零长度 builtin 调用 zjs 全线 1.37-1.68x。** 六个 `b0_*` 是「进 builtin、查 species、
   建结果数组、一次不回调就出来」的纯每调用常数，zjs 在这条轴上也落后，但它被 slope 口径
   完整扣掉了，没有混进桥税。
2. **对照的长度 0 截距两侧基本相等**（`c0_*` 比值 0.92-1.15），所以 slope 减法没有引入新的偏置。

## 5. 复算与门禁

- 采样：CPU 19（`armv8_pmuv3_1`），事件显式带 PMU 前缀，未出现 `<not counted>` 行。
  每个 case **8 次 ABBA**（qjs/zjs 首位各 4 次，**样本数为偶**），首位计数平衡
  （`first_position_balanced: true`，两次复现各 160/160）。独占锁按 case 取放，不整轮霸占。
- **两次冷缓存构建，zjs 侧逐字节相同**（`.zig-cache` 删净后重建，两个实例 sha256 都是
  `77178af4…`）。因此本树上没有构建 bistability 可言；用来当噪声尺的是**两次独立的完整计时扫描**
  （同二进制、A2 / A3）。头条列 `zjs_specific_bridge_tax_scaffold_corrected` 的两次复现极差
  ≤ **0.58 cyc/回调**（`filter_false`），其余六个 rung ≤ 0.43，`some` 只有 0.006。
  单 case 层面唯一例外是 `c_map_sum`（zjs 侧 2.6%，见 §2.2），它不参与主表。
  第一轮（A1，`c_every` 含 `!`、无 scaffold/lnot/checksum 探针）也在同一把尺下采过，
  未变动的六个 rung 与 A2/A3 的 spec 口径值最大只差 **1.52 cyc/回调**（`filter_true`，
  其余五个 ≤ 0.86），相当于第三次复现；它的作用是暴露 §2.4 的对照工件。
- 40 个计时 case 在两个引擎上的 stdout **逐字节相同**（`output_match_all_cases: true`）。
  7 个 verify case 也逐字节相同。
- **`git diff 18816862 -- src/` 为空。** 全程未改生产代码，未使用临时插桩：gdb 符号断点、
  gdb **行号表**断点与 `perf` 都在引擎之外，两侧同一把尺。新增文件只在
  `tools/perf/builtin_bridge/` 与本报告目录下。
- 全程未使用 `git stash`。构建取共享锁；gdb 计数与 `perf report` 解析不计时；
  `perf stat` 与 `perf record` 取独占锁并 `taskset -c 19`。

## 6. 交给其他线的三件事

- **给 call 线（唯一大头）**：`Array.prototype` 的 6 个回调型方法共用一条桥，每次回调比 zjs
  自己的 VM 调用多 **约 27 cycles**（qjs 同位置约 0）。入口是
  `exec/call_runtime.zig:749` `SyncInternalCallSite.call`（noinline），链条是
  `NativeBoundaryScope.init` → `.push` → `Machine.tryPushNativeBoundary*Fast`（inline，快腿全程命中）
  → `zjs_vm.runActiveInvocationUntilNativeBoundary` → 一次 `runTC` 进入
  → `tailcall_dispatch.zig:1197-1199` 的 `special_return` native-boundary 返回臂
  → `NativeBoundaryScope.finish`。qjs 的同一位置是 `js_array_every` 直接调 `JS_Call`→`JS_CallInternal`，
  **与它的 `OP_call` 是同一个函数的同一次进入，没有中间层**。
  按每回调 27 cycles 计，`forEach` 这类最干净的形态 zjs 现在是 **1.68x**（60.09 → 101.21 cyc/回调）。
- **给 array 线（`reduce`）**：zjs 的 `reduce` / `reduceRight` 元素读没有 dense 快腿
  （`src/exec/array_ops.zig:2027-2032` 与 `:2004-2009`），每元素多付 atom 构造 + `hasValueProperty`，
  实测 **+28 cycles/元素**，令 `b_reduce` 达到 **2.452x cycles / 1.853x instructions** —— 本条线
  撞到的最高单项比值，且与桥无关。迭代族（`:1761-1770`）已有的 dense 分支就是现成的对照写法。
- **给 VM 线（`!`）**：一个作用在可变局部上的逻辑取反，zjs 每元素 **91.13 insn / 18.66 cyc**，
  qjs **17.96 / 3.07**。`perf record` 归属到 `exec.vm_value.logicalNot`（out-of-line 辅助，
  op 表里没有对应快 handler）。这是本条线为了修对照工件而顺手量出来的，完全独立于 array 子系统。

## 7. 本条线没有建立的东西

1. **没有把那 27 cycles 拆到八个阶段里的哪几个。** 计数证明八个阶段每次回调各走一遍、
   `perf record` 证明 `SyncInternalCallSite.call` + `runTC` 占 builtin cycles 的 54.4%
   而对照里是 0%，但**没有**给出「fence 建域/发布 x cycles、`runTC` 重入 y cycles、
   `special_return` 臂 z cycles」这样的分解。要做需要 per-阶段的地址级采样或受控删阶段实验，
   后者会改 `src/`，超出本条线边界。
2. **没有解释 IPC 差。** builtin 里两侧 IPC 差 2.0-2.1、对照里只有 0.4-0.5，本条线只采了
   instructions / cycles / task-clock，没有采 cache-miss、branch-miss、stall 分解。
   这与 P7-40 §7.2 是同一笔未偿债务。
3. **`reduce` 的 +55 没有被完整分解。** 已定性并用计数坐实「源读没有 dense 快腿」这一条，
   也量出 arity 4 的对照本身两侧就差（`c_reduce` 1.399x 对 `c_foreach` 1.157x），
   但没有把 +28 的超额拆成「atom 构造 / `hasValueProperty` / 4 实参 ABI」三份。
4. **结果写轴的 −25 是配对差值，不是独立探针。** 它由两条独立配对
   （`filter(true)−filter(false)`、`map−forEach`）互相印证到 3.8 cycles 以内，
   但没有一个「只写不回调」的 builtin 同族对照可用来直接量它。
5. **`thisArg` 只测了 `forEach` 一个。** 按任务边界第一轮不外推到其他 builtin。
6. **native 回调对照换掉的是被调用方种类，不是桥的某一个阶段。** `map(Math.abs)` 证明的是
   「这笔税只在被调用方是 bytecode 时支付」，它并没有把 native 被调用方自己的帧建立成本与
   桥的八个阶段分开，因此不能当作「桥 = 43.95 cycles」的读数。
7. **没有测 sparse / holey 数组、非数组 receiver、TypedArray 族、`find*` 族。**
   `find*` 走同一个 `qjsArrayIterationModeCall` 的 `find_family = true` 实例，
   本条线没有采它。
8. **没有覆盖第二个 realm / 跨 realm 回调。** 路由的 `machine.ctx != ctx` 早退分支
   （`call_runtime.zig:500-505`）在本 corpus 里从未触发。
9. **没有做任何一刀。** 按任务边界停在裁决。
