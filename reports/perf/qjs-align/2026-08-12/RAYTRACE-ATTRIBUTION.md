# RayTrace 差距全面归因 — 2026-08-12 @ `e31af460`

与同日的 `EARLEY-BOYER-ATTRIBUTION.md` 采用同一套协议、同一天、同一对二进制。
对照 QuickJS `04be2460`。**RayTrace 现在是 zoo 最大缺口（0.754）。**

## 0. 头条：与 EarleyBoyer 是两种病

| | EarleyBoyer | **RayTrace** |
|---|---:|---:|
| zoo 分数 | 0.797 | **0.754** |
| fixed-work instructions z/q | 1.1583 | **1.2738** |
| fixed-work cycles z/q | 1.2435 | **1.3225** |
| IPC z/q | 0.9315 | **0.9632** |
| **执行的 opcode 数 z/q** | 0.8807（zjs 少 11.9%） | **1.0013（完全相同）** |
| branch-instructions z/q | 1.3467 | **1.4823** |
| branch-misses z/q | 1.9383 | 1.7960 |
| **cache-misses z/q** | 1.3086 | **2.8924** |

**EarleyBoyer 是 IPC 病**（指令只多 16% 而周期多 24%），**RayTrace 是指令病**
（多执行 27% 的指令，IPC 几乎持平）。RayTrace 执行的字节码与 qjs **逐条相同**
（187.7M vs 187.5M opcode），所以差距 **100% 是单位成本**，与 2026-08-10 的结论一致。

⚠️ **新信号：cache-misses 2.89 倍**（19.67M vs 6.80M，+12.87M）。这在 EarleyBoyer
上只有 1.31x。按符号，zjs 的 miss 有 **16.69% 落在 `op_get_field`** 一个符号上，
其后是 `setOrDefineOwnDataPropertyForPutFieldOwned` 4.99%、`op_get_field2` 4.36%、
`op_call_method` 4.00%、`op_call_constructor` 3.17%。qjs 侧 58.77% 在 `JS_CallInternal`
（含其内联的 get_field 走链）、10.93% 在 `__js_malloc`。
即便按保守的 20 cyc/miss 折算，这 12.87M 额外 miss 也值约 257M cycles ≈ 差距的 25%。

## 1. 测量条件

- `tools/perf/zoo/run_zoo_fixed_pmu.py --benches raytrace --iteration-divisor 16`，
  8 paired samples，ABBA，first-position 4/4，**CPU 19**（Cortex-X925），`armv8_pmuv3_1`
- 定工作量语料 `/tmp/eb12cases/raytrace-fixed-d16.js`（由 `fixed_source()` 生成，
  `doWarmup=false` / `doDeterministic=true` / 迭代数除以 16，两侧执行相同批次）
- profile：4 组 ABBA 交错 `perf record -c 500009`（instructions + cycles 同测），CPU 19；
  IP → `addr2line -f -i` **最外层已解析内联帧**
- 微基准：`perf stat` ABBA 8 samples，CPU 19
- **并行度 = 5**（同期有 4 个 codex 实现任务分别绑在 CPU 5/6/7/8）。
  跨并行度只能比比值，不能比绝对值。

PMU 中位数：

| 计数器 | qjs | zjs | z/q |
|---|---:|---:|---:|
| instructions | 15.549G | 19.806G | 1.2738 |
| cycles | 3.242G | 4.288G | **1.3225** |
| branch-instructions | 2.611G | 3.871G | 1.4823 |
| branch-misses | 6.77M | 12.15M | 1.7960 |
| cache-references | 6.073G | 8.659G | 1.4257 |
| cache-misses | 6.80M | 19.67M | **2.8924** |
| 分数 | 3388 | 2561 | 0.756 |

## 2. 守恒分桶（份额 × PMU 中位数，逐 profile MAD ≤0.33pp）

| 桶 | qjs Mcyc | zjs Mcyc | 超出 | 占比 | 比值 |
|---|---:|---:|---:|---:|---:|
| **constructor** | 62 | 313 | **+251** | **24.0%** | 5.05 |
| **apply/arguments** | 81 | 330 | **+249** | **23.8%** | 4.06 |
| other-bytecode | 430 | 581 | +152 | 14.5% | 1.35 |
| **method/native-call** | 148 | 291 | **+143** | **13.7%** | 1.96 |
| call/frame | 389 | 510 | +121 | 11.6% | 1.31 |
| residual | 46 | 146 | +100 | 9.6% | 3.17 |
| property-write | 349 | 410 | +61 | 5.8% | 1.17 |
| alloc | 361 | 388 | +27 | 2.6% | 1.08 |
| **property-read** | 862 | 839 | **−24** | −2.3% | 0.97 |
| **rc-destroy** | 507 | 461 | **−45** | −4.3% | 0.91 |
| 合计（采样） | 3235 | 4269 | +1034 | | |
| PMU | 3242 | 4288 | +1046 | | |

⚠️ **`constructor` 的 5.05x 被桶边界放大了**：qjs 的构造帧序幕/尾声与所有调用共用
`JS_CallInternal` 的 17749-17871 / 20700-20718，落在 `call/frame` 桶；zjs 的
`pushConstructorCall` / `popConstructorReturn` **就是**那个帧，落在 `constructor` 桶。
正确的读法是把三个调用类桶合起来：

```
constructor + method/native-call + call/frame
   qjs  62 + 148 + 389 =  599M
   zjs 313 + 291 + 510 = 1114M
   超出 +515M = 差距的 49.2%，比值 1.86x
```

**加上 apply/arguments 的 +249M，调用机制与实参物化合计占 RayTrace 差距的 73%。**

## 3. 机制级明细（按 census/16 的事件频次摊单位成本）

RayTrace 事件频次（`reports/perf/qjs-align/2026-08-10/raytrace-opcode-census-d1.json` ÷16）：
`get_field` 29.94M、`get_field2` 5.96M、`call_method` 5.96M、`call_constructor` 2.50M、
`special_object` 2.50M、`put_field` 8.84M、`return`+`return_undef` 8.06M。

| 机制 | zjs M | qjs M | 超出 M | 占比 | 比值 | 单位成本 z vs q |
|---|---:|---:|---:|---:|---:|---|
| **方法调用 + native 边界** | 406.7 | 148.8 | +257.9 | 24.7% | **2.73** | 68.2 vs 25.0 cyc/次 `call_method` |
| **apply + arguments** | 336.3 | 83.6 | +252.7 | 24.2% | **4.02** | 134.7 vs 33.5 cyc/次 `special_object` |
| **构造器 + 构造帧** | 314.4 | 62.4 | +252.0 | 24.1% | **5.04**※ | 125.9 vs 25.0 cyc/次构造 |
| **return + 帧拆除** | 209.9 | 79.5 | +130.4 | 12.5% | **2.64** | 26.0 vs 9.9 cyc/次返回 |
| 属性写 `put_field` | 398.4 | 344.2 | +54.2 | 5.2% | 1.16 | 45.1 vs 39.0 cyc/次写 |
| 分配器 | 366.3 | 360.6 | +5.7 | 0.5% | 1.02 | — |
| **属性读** | 819.3 | 846.8 | **−27.5** | −2.6% | **0.97** | 22.8 vs 23.6 cyc/次读 |
| **RC 销毁/释放** | 434.3 | 507.9 | **−73.6** | −7.0% | **0.86** | — |
| var_ref / 闭包 | 0.0 | 36.7 | −36.7 | −3.5% | — | RayTrace 几乎不建闭包 |
| 已命名合计 | 3285.6 | 2470.5 | +815.1 | **77.9%** | | |

※ 见 §2 的桶边界说明，构造器的真实比值应按合并后的 1.86x 读。

## 4. 受控微基准（净 ctrl 后每次操作 cycles，8 samples ABBA，CPU 19）

| shape | zjs | qjs | z/q |
|---|---:|---:|---:|
| **`G_raytrace_ctor`** | 1049.7 | 701.9 | **1.50** |
| `C2_apply_array_hoisted` | 231.3 | 157.0 | 1.47 |
| **`D_apply_arguments`** | 594.4 | 410.9 | **1.45** |
| `A_direct_call` | 59.1 | 41.0 | 1.44 |
| `E4_arguments_fourarg` | 499.0 | 346.9 | 1.44 |
| `C_apply_array_literal` | 346.5 | 253.5 | 1.37 |
| `B_method_call` | 76.1 | 56.7 | 1.34 |
| `E0_arguments_zeroarg` | 223.9 | 171.7 | 1.30 |
| `I_proto_method` | 131.2 | 110.7 | 1.19 |
| `ctrl`（空循环，原始比值） | — | — | **0.781** |

⚠️ **净-ctrl 法的偏置**：zjs 的空循环现在比 qjs 快 22%（`ctrl` 0.781），所以从 zjs
一侧减掉的基线更小，**所有 shape 的「净 ctrl」比值都被系统性抬高**。因此这批数字
不能直接与 2026-08-08 那次（当时 ctrl 0.83）逐条比较；只能在本批内部横向排序。
按原始比值排序结论不变：`G_raytrace_ctor` 1.477 仍是最差形态。

`G_raytrace_ctor` 是复合形态（已登记：G = E + D + F + I 的叠加），修 E/D 即修 G。

## 5. 与 EarleyBoyer 的交叉结论

| | EarleyBoyer | RayTrace |
|---|---|---|
| 病灶 | IPC（0.932） | 指令数（1.274） |
| 第一杠杆 | `fclosure` 无常驻 handler +223M | 调用机制合计 +515M |
| 第二杠杆 | 构造 bypass 准入税 +182M | apply/arguments +249M |
| 闭包 | 骨架（640K 次） | 几乎为零 |
| 构造器 | 被 bypass 掩盖（+68M） | **裸露的通用路径（+251M）** |
| 属性读 | zjs 反超 −216M | zjs 略胜 −24M |
| GC/销毁 | zjs 落后 +193M | zjs 反超 −45M |
| cache-misses | 1.31x | **2.89x** |

⭐ **最重要的交叉发现**：**RayTrace 的构造器走的正是被 EarleyBoyer 的
`constructSimpleFieldConstructor` bypass 掩盖掉的那条通用路径。**
在 EB 上这条路径被绕开、只暴露 +68M；在 RayTrace 上它裸露着，是 +251M。
所以「让通用构造路径追平 qjs」这件事**同时是 RayTrace 的头号杠杆和
EarleyBoyer 删 bypass 的前提** —— 一件事，两个基准。

## 6. 建议排序

| # | 目标 | RayTrace 上限 | 同时惠及 |
|---|---|---:|---|
| 1 | 通用构造路径 + 构造帧（`G_raytrace_ctor` 1.50x） | ~250M (24%) | EarleyBoyer 删 bypass 的前提 |
| 2 | apply/arguments 物化（4.02x，134.7 vs 33.5 cyc/次） | ~253M (24%) | EarleyBoyer +62M |
| 3 | 方法调用 + native 边界（2.73x，68.2 vs 25.0 cyc/次） | ~258M (25%) | 全部含方法调用的基准 |
| 4 | `return` + 帧拆除（2.64x，26.0 vs 9.9 cyc/次） | ~130M (12%) | 全局 |
| 5 | cache-miss 2.89x 的根因（对象/属性布局） | 未定价 | 全局，但需先独立定位 |

## 7. 产物

- `rt-fixed-pmu-e31af460.json` — 定工作量 PMU（8 samples ABBA，CPU 19）
- `rt12-ipf-s{1..4}-{z,q}.json` — 8 份 profile 的 IP→最外层内联帧解码
- `rt12-micro.csv` — 10 个调用形态的受控微基准
- 语料 `/tmp/eb12cases/raytrace-fixed-d16.js`

## 8. 与 2026-08-10 RayTrace 归因的对照

08-10 在 0.565 分时的结论是：差距 100% 是单位成本（IPC 0.98 / opcode 数 1.0013x），
call 机制 2.76x 占 36.3%、读 1.51x、写 2.09x、arguments+apply 3.56x。

今天在 0.754 分时复测：**opcode 数 1.0013x 一模一样**（同一个数字，独立复现），
**读已经从 1.51x 变成 0.97x 反超**、**写从 2.09x 收到 1.16x**，
call 机制仍在（合并后 1.86x）、**apply/arguments 从 3.56x 到 4.02x 基本没动**。
即：这一年打下来的是属性读写，调用机制与 apply/arguments 原地未动，
于是它们的相对占比从 36.3% 涨到了 73%。
