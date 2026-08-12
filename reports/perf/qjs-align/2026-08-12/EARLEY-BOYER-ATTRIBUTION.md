# EarleyBoyer 差距全面归因 — 2026-08-12 @ `e31af460`

对照 QuickJS `04be2460`。所有数字来自本次实测，无一项由旧数据投影。

## 0. 头条：EB 已不是 zoo 最大缺口

| | 2026-08-11 `bcac2a54` | 2026-08-11 `4fa7c0b3` | **2026-08-12 `e31af460`** |
|---|---:|---:|---:|
| EarleyBoyer 分数比 | 0.6450 | 0.6629 | **0.797** |
| fixed-work instructions z/q | 1.37385 | — | **1.1583** |
| fixed-work cycles z/q | 1.53545 | — | **1.2435** |
| 超出 cycles | +2.897G | — | **+1.318G** |

**过去 6 个 commit（instanceof 内部方法分派对齐 + 5 刀 GC/对象生命周期）
消掉了 54.5% 的超出 cycles。** zoo geomean 0.8958 → **0.9110**。
EB 现在排第三，前面是 RayTrace 0.754 与 PdfJS 0.777。

zoo 全量（4 samples，parallel-clusters 5-9/15-19）：

```
raytrace 0.754  pdfjs 0.777  earley-boyer 0.797  typescript 0.826  deltablue 0.866
box2d 0.906  richards 0.908  mandreel 0.909  gbemu 0.920  zlib 0.921  splay 0.946
navier-stokes 0.971  crypto 1.057  code-load 1.092  regexp 1.102
throughput geomean 0.9110
```

## 1. 测量条件

- 工具 `tools/perf/zoo/run_zoo_fixed_pmu.py`，`--iteration-divisor 16`，
  固定语料 SHA-256 `258d3bca...`（与 08-11 归因**同一份**，可直接对比）
- 8 paired samples，ABBA，first-position 4/4，CPU 5（Cortex-X925），
  `armv8_pmuv3_1`；无 flock，同期并行度约 2（合同第 6 条 + 并行度声明）
- profile：4 组 ABBA 交错 `perf record -c 500009`（instructions+cycles 同测），
  CPU 6；IP → `addr2line -f -i` **最外层已解析内联帧**（合同第 1 条）
- 微基准：`perf stat` ABBA 8 samples，CPU 19

PMU 中位数（qjs 侧与 08-11 那次差 <0.05%，跨会话可比）：

| 计数器 | qjs | zjs | z/q |
|---|---:|---:|---:|
| instructions | 25.879G | 29.975G | 1.1583 |
| cycles | 5.411G | 6.729G | **1.2435** |
| IPC | 4.7825 | 4.4547 | 0.9315 |
| branch-instructions | 4.437G | 5.975G | **1.3467** |
| branch-misses | 9.03M | 17.51M | **1.9383** |
| cache-references | 10.118G | 13.078G | 1.2925 |
| cache-misses | 78.6M | 102.9M | 1.3086 |

指令与周期同向，layout-lineage 的强制触发条件（合同第 8 条）未触发。
**新信号：分支指令 1.347x 明显高于指令 1.158x** —— zjs 有 20.0% 的指令是分支
（qjs 17.1%），且 branch-miss 近乎翻倍（+8.47M）。按 ~15 cyc/miss 估约
127M cycles ≈ 差距的 10%，分布在 GC/销毁（zjs 19.5% 的 miss vs qjs 18.6%
但基数 2 倍）而非单点。

## 2. 守恒分桶（份额 × PMU 中位数，逐 profile MAD ≤0.45pp）

| 桶 | qjs Mcyc | zjs Mcyc | 超出 | 占比 | 比值 |
|---|---:|---:|---:|---:|---:|
| residual | 160 | 487 | +327 | 24.8% | 3.05 |
| call/frame | 775 | 1072 | +297 | 22.5% | 1.38 |
| other-bytecode | 926 | 1200 | +274 | 20.8% | 1.30 |
| instanceof | 470 | 724 | +254 | 19.3% | 1.54 |
| gc-cycle | 464 | 657 | +193 | 14.7% | 1.42 |
| ctor+publish | 726 | 794 | +68 | 5.1% | 1.09 |
| alloc | 355 | 408 | +53 | 4.0% | 1.15 |
| rc-destroy | 587 | 639 | +52 | 4.0% | 1.09 |
| **property-read** | 947 | 746 | **−201** | −15.3% | **0.79** |
| 合计（采样） | 5410 | 6728 | +1317 | | |
| PMU | 5411 | 6729 | +1318 | | |

守恒精确到 0.1M。

## 3. 机制级明细（跨引擎同一语义边界，按超出排序）

| 机制 | zjs M | qjs M | 超出 M | 占比 | 比值 | 单位成本 z vs q |
|---|---:|---:|---:|---:|---:|---|
| **C `instanceof`（含 @@hasInstance 查找）** | 742.7 | 462.0 | +280.7 | 21.3% | 1.61 | 93.7 vs 58.3 cyc/次 |
| **A 调用/帧机制（call+return+prologue）** | 896.3 | 657.8 | +238.5 | 18.1% | 1.36 | 87.0 vs 63.8 cyc/次调用 |
| **B 闭包 + var_ref + open-binding** | 344.9 | 122.2 | +222.7 | 16.9% | **2.82** | **538.6 vs 190.7 cyc/闭包** |
| **D 环收集 GC** | 656.4 | 464.0 | +192.5 | 14.6% | 1.41 | 104.5 vs 73.9 cyc/对象 |
| **E 构造器 bypass 准入税（qjs 完全没有）** | 181.8 | 0.0 | +181.8 | 13.8% | ∞ | 38.7 vs 0 cyc/次构造 |
| I `if_false8`+`get_var`+`goto8` | 327.1 | 245.9 | +81.3 | 6.2% | 1.33 | 5.8 vs 4.3 cyc/次 |
| G 分配器 + memset | 293.4 | 220.1 | +73.3 | 5.6% | 1.33 | — |
| **F mapped arguments** | 74.2 | 12.6 | +61.6 | 4.7% | **5.87** | 80.9 vs 13.8 cyc/次 |
| H `get_array_el` | 137.5 | 90.2 | +47.2 | 3.6% | 1.52 | 23.3 vs 15.3 cyc/次 |
| K 对象创建外壳 | 159.5 | 120.1 | +39.5 | 3.0% | 1.33 | 25.4 vs 19.1 cyc/对象 |
| J RC 销毁/释放 | 561.1 | 544.2 | +16.9 | 1.3% | 1.03 | 89.7 vs 87.0 cyc/次 |
| M 属性读 | 627.8 | 843.8 | **−216.0** | −16.4% | **0.74** | 22.4 vs 30.1 cyc/次 |
| L 属性发布（新属性写） | 399.0 | 620.5 | **−221.5** | −16.8% | **0.64** | 29.8 vs 46.4 cyc/笔 |
| 已命名合计 | 5401.7 | 4403.3 | +998.5 | **75.8%** | | |

余下 24.2% 分散在 atom interning、剩余 opcode、解析/启动等，无单点。

## 4. 五个第一梯队发现

### 4.1 ⭐ `fclosure`/`fclosure8` 根本没有热 handler（+223M，16.9%）

```zig
// src/exec/tailcall_dispatch_colds.zig:210
t[op.fclosure] = coldStd(struct { ... });
t[op.fclosure8] = t[op.fclosure];
```

**热表与冷表持有同一个 `coldStd` 外壳** —— 与 `lnot`（09f4d457，−1.35%）
和 `is_null`（4fa7c0b3，−1.39%）完全同构的形态，只是从没有人查过它。

实测调用链（`perf --call-graph dwarf` 折叠栈）8 层深：

```
coldStd → buildTable.b → vm_call.closure → pushFunctionClosure
  → createBytecodeFunctionObject → createBytecodeFunctionObjectInternal
  → attachFunctionCaptures → resolveNestedClosureCell
  → Frame.captureLocal/captureArg → open_bindings.Table.acquire
```

qjs `OP_fclosure8` 是 `JS_CallInternal` 内一条
`*sp++ = js_closure(ctx, JS_DupValue(ctx, b->cpool[idx]), var_refs, sf);`。

频次 `fclosure8` = 640,383（合同第 9 条：绝对贡献 = 348 cyc × 640K = 223M）。
EarleyBoyer 是 Scheme→JS 编译产物，闭包是它的骨架，这个机制在
RayTrace/TypeScript 上都不显眼，所以历次战役都没碰到。

单项拆分：`attachFunctionCaptures` 126 cyc/闭包、
`createBytecodeFunctionObjectInternal`+`defineFunctionNameProperty`+
`functionNameValueFromAtom` 合计 94 cyc/闭包，qjs `js_closure`+`js_closure2`
合计 63 cyc。

**独立的可控差分微基准确认**（`CL1` 每轮建一个捕获一个 local 的闭包，
`CL0` 同一循环但复用一个已有函数；差分 = 一次闭包创建+销毁）：

| | insn/闭包 | cyc/闭包 |
|---|---:|---:|
| zjs | 3565.0 | **614.8** |
| qjs | 2190.8 | **339.6** |
| z/q | 1.627 | **1.810** |

两条互不依赖的路线给出的绝对超出是 275 cyc（微基准）与 348 cyc（宏观分桶），
乘 640,383 次 = **176M–223M cycles，即 EB 差距的 13%–17%**。

### 4.2 ⭐⭐ 构造器 bypass 的准入税是纯 zjs-only 成本（+182M，13.8%）

`constructSimpleFieldConstructor` 每次构造要先付两笔 QuickJS 完全没有的钱：

| 准入项 | Mcyc | cyc/次构造 | qjs 对应 |
|---|---:|---:|---|
| `resolveSameMachineConstructor` 里的 `JSValue.sameValue` | 52.9 | 11.2 | 无 |
| `prototypeChainBlocksSimpleFieldStore` 原型链扫描 | 128.9 | 27.4 | 无 |

`sameValue` 还是一个**未内联的通用 SameValue**（处理 NaN/±0/BigInt/字符串比较），
而这里两个操作数必定都是对象，语义上等价于指针比较。

按 08-11 预注册的删除代价（99.64–109.31 cyc × 4,704,170），删掉 bypass 后
构造器桶净增 469–514M、扣回这 182M 准入税，**净恶化约 +290~330M
（总比 1.2435 → 约 1.30）**。这与用户 08-11 的裁决一致：账面会变差，
但暴露出真正该修的东西——**zjs 跳过整个九-opcode 函数体+一个帧，
每次构造仍要 194 cyc，qjs 跑完整体+帧约 150 cyc**。

微基准佐证 bypass 造成的形态失真依然存在：

```
F_simple_ctor      cyc z/q 0.978   ← 走 bypass，反超
L3_ctor_threeprops        0.893   ← 走 bypass，反超
L0_ctor_noprops           1.553   ← 无字段写，不合格，真实价
L4_generic_ctor           1.200   ← 通用路径，真实价
```

### 4.3 `instanceof` 现在两侧都很贵，zjs 只剩 1.05x（订正 08-11 的 23.1%）

用嵌套 `if` 差分（`if(A) if(A) if(A)` 减 `if(A)`，两侧周边 opcode 完全抵消）
消除算术慢路后定价：

| | insn/次 | cyc/次 |
|---|---:|---:|
| zjs `instanceof` − `strict_neq` | 486.2 | **82.4** |
| qjs `instanceof` − `strict_neq` | 470.2 | **78.3** |
| z/q | 1.034 | **1.053** |

⚠️ **08-11 报的「instanceof 独占 23.1%、3.44x」有分桶不对称**：
zjs 的 `@@hasInstance` 查找内联在 `op_instanceof` 里被算进 instanceof 桶，
qjs 的同一次查找走 `JS_GetPropertyInternal` 被算进 property-read 桶
（EB 里 7.93M / 18.58M 次 `get_prop_internal` = 42.7% 是 hasInstance 查找），
而 qjs 那次 C 函数调用的 `JS_CallInternal` prologue 又被算进了 direct-call 桶。
本表两侧都按同一语义边界重算，比值从 3.44x 降到 1.61x，
其中微基准可控差分给出的机制真值是 **1.053x**。

真正的事实是：**两个引擎都在 `x instanceof C` 上花 ~80 cyc**
（qjs：泛型 `JS_GetProperty(@@hasInstance)` 走原型链 → `JS_CallFree` 起一个
C 函数帧 → `JS_OrdinaryIsInstanceOf` 再读一次 `.prototype` 再走链）。
EB 里它占 zjs 全程 **11.0%**、qjs 全程 **8.5%**。忠实对齐做到头也只剩
~4 cyc/次 = 32M = 2.4% 可拿。

### 4.4 mapped arguments 5.87x（+62M，4.7%）

`special_object` 916,895 次：zjs 80.9 cyc（`createArgumentsObject` 39.3M +
`mappedArgumentsElementDup` 15.0M + `op_special_arguments` 19.8M）
vs qjs `js_build_mapped_arguments` 13.8 cyc。EB 用它实现 `sc_list`
（`res = new sc_Pair(arguments[i], res)`）。

### 4.5 环收集 GC 1.41x（+193M，14.6%）

zjs `destroyRuntimeCyclesWithValueRoots` 258.9M + `traceChildren` 295.3M +
`drainCycleDeferredFrees` 92.2M = 656.4M；qjs `mark_children` 196.2M +
`gc_decref*` 117.3M + `gc_free_cycles` 55.7M + `gc_scan*` 69.7M +
`js_bytecode_function_mark` 25.0M = 464.0M。
⚠️ 这与「GC 是 zjs 优势（265M vs 682M）」不矛盾：那条是**独立 GC 子路径**
的测量，这里的桶按外层内联归属把 RC 环判定/遍历也算进来了。
分支预测失败在这个桶上是 zjs 的 2 倍。

## 5. zjs 已经反超的地方（不要动）

| | zjs | qjs | 说明 |
|---|---:|---:|---|
| 属性读 | 22.4 cyc/次 | 30.1 | −216M；微基准 `H1_prop_read` 0.778、`M1_proto_data_read` 0.808 |
| 新属性发布 | 29.8 cyc/笔 | 46.4 | −221M（T7 add-tail + put_field 单走道的累计成果） |
| 解释器空循环 | — | — | `ctrl` cyc z/q **0.778** |
| `is_null` | 5.7 cyc | 5.8 | 已平（08-11 那刀落地） |
| `get_field` | 22.0 cyc | 21.8 | 已平 |
| `get_var_ref` | 5.45 | 5.47 | 已平 |

## 6. 建议的下一步排序（按绝对贡献，合同第 9 条）

| # | 目标 | 上限 | 形态是否已知有效 |
|---|---|---:|---|
| 1 | `fclosure`/`fclosure8` 热 handler + 压平 capture 链 | 223M (16.9%) | ✅ `lnot`/`is_null` 两次先例 |
| 2 | 删构造器 bypass，改为让通用构造路径变快 | 账面 −290M 但解锁真问题 | ⚖️ 用户 08-11 已裁决必删 |
| 3 | 调用/帧机制（87.0 vs 63.8 cyc/次调用） | 239M (18.1%) | ⚠️ 已被多轮战役压过，边际递减 |
| 4 | 环收集 GC 遍历 + 其分支预测 | 193M (14.6%) | 🆕 |
| 5 | mapped arguments（5.87x） | 62M (4.7%) | ✅ 有 qjs `build_arg_list` 快臂先例 |
| 6 | `get_array_el`（1.52x） | 47M (3.6%) | 🆕 |
| 7 | `instanceof` 残余 | 32M (2.4%) | ❌ 已近平价，不建议 |

## 7. 产物

- `zoo-full-baseline-e31af460.json` — 全量 zoo 绝对基线
- `eb-fixed-pmu-e31af460.json` — 定工作量 PMU（8 samples ABBA）
- `eb12-ipf-s{1..4}-{z,q}.json` — 8 份 profile 的 IP→最外层内联帧解码
- `eb12-micro-Ny.csv` — instanceof 嵌套 if 差分定价
- `eb12-micro-ctor.csv` — 构造/属性 12 形态微基准

## 8. 本次订正的历史结论

1. **「instanceof 独占 23.1% / 3.44x」不成立**——分桶不对称，两侧按同一
   语义边界重算是 1.61x，可控差分是 1.053x。
2. **「property-read 是 zjs 优势 −0.438G insn」被夸大**——qjs 的
   property-read 桶里混进了 7.93M 次 `@@hasInstance` 查找。
   （反超是真的，幅度不是那个数。）
3. **per-opcode 归因必须包含 qjs 的共享标签尾**：只按 `CASE(OP_is_null)`
   的 7 行取范围会读出 qjs 0.80 cyc / zjs 7.12x 的假差距，
   把共享的 `set_true`/`free_and_set_false` 标签算进来后两侧都是 5.7 cyc。
   这是合同第 1 条在 qjs 侧的变体。
