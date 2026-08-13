# D11-JSLEVEL outcome — RayTrace / PdfJS 的 JS 函数级归因

日期：2026-08-13  
基线：`e31af460d94c5c368a243f37afbf15d4cefed392`  
CPU：6，串行并行度 1，不加 `flock`  
生产配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

## 结论先行

1. **RayTrace 找到一个成立且占主导的 JS 函数形态**：`Class.create` 在 438 行返回的匿名构造包装函数，即
   `this.initialize.apply(this, arguments)`。它执行 **2,530,574 次 / d16**、占两侧全部 opcode 的约 **14.6%**。
   将它语义等价地改成六形参直接调用后，普通 Zoo 的 zjs/qjs 分数比在 pad 0/3/7 上分别改善
   **+5.322% / +5.220% / +5.556%**；中位 +5.322%，最坏 pad 仍 +5.220%，通过
   “中位有利且最坏 pad 不回退”。效应 / pad 极差为 **15.84x**。
2. 该包装函数在 d16 fixed-work 消融中解释约 **0.929G cycles** 的 zjs 额外成本，约占同次
   RayTrace fixed-work 总 z-q 赤字 **1.480G cycles 的 62.8%**。真实输入抽取微基准给出较保守的
   **0.493G cycles** 投影；因此可信区间写作 **0.50–0.93G cycles / d16**，而不是取一个伪精确点值。
3. `Vector.dot` 的 fixed-work 与真实输入微基准都显示 zjs 调用边界更贵，但普通 Zoo 三 pad 效果为
   **-0.402% / +0.068% / -0.071%**，中位 -0.071%、最坏回退，**按最终指标否决**。
4. **PdfJS 没有找到成立的单一慢函数。** `FlateStream_getCode` 是最大 opcode 体（19.4%）且抽取微基准
   z/q=1.257，但真实源码消融在三 pad 上使 zjs/qjs **恶化 -1.031% / -0.767% / -0.903%**。
   因而不能把微基准结果冒充宏观归因。
5. PdfJS 两侧总 opcode 几乎相同（z/q=0.9973），最热的长循环函数调用次数又很少。把已有机制单价
   机械套入全部函数只预测约 **92.6M cycles** 赤字，而同一 d16 生产二进制实测约 **230M cycles**；
   尚有约 **137M cycles（约 60%）** 无法由已命名的调用/属性/opcode 边际模型解释。这个残差是本任务
   的重要否定发现：下一步应测数组元素、typed-array/string backing、分配与 GC/lifecycle 的宏观真实路径，
   不能再从一个 JS 函数名直接下刀。

本任务没有产生引擎候选，只有诊断计数器与测量脚本；因此“候选 zjs 二进制 vs 冻结 zjs 基线”的
二进制因果 A/B 不适用。下面的 Zoo 表是 S2 要求的**源码因果消融**：qjs 和三个冻结的生产 zjs
都运行同一份 base/variant 源码，8+8 样本、ABBA。

## 冻结对象与尺子

生产二进制均从 clean `git archive e31af460` 构建，计数器源码不参与定价：

| 谱系 | `-Dzjs_dossier_layout_pad` | SHA-256 |
|---|---:|---|
| zjs-pad0 | 0 | `d1f10bdb1a4f80dc3e9aaa8ced8c07c499d4a3dd188e775dfdd10e2848783812` |
| zjs-pad3 | 3 | `ad768dcfe45d9f975ac0be4eaa2cd4af100111b0beabb68b2735b5c947ff9f2e` |
| zjs-pad7 | 7 | `98e8e5d19d265d6c480f40b16304c31e6e68798842ed829bebc6351751f1cc69` |
| qjs 04be2460 | — | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |

所有 PMU 与 Zoo 运行均 `taskset -c 6`、串行、无 flock。PMU 明确使用 `armv8_pmuv3_1`，每个
base/variant 每引擎 8 样本、ABBA，任何缺失计数、非零退出或错误 stdout 都会使脚本失败。

S1 固定工作量源码 SHA-256：

- RayTrace d16：`ac4d2cc50a5d4a6f8a804ab07ee9628dbb3d18f30b010b85a0ea297617aadfc8`
- PdfJS d16：`1a7ebe21975991190a0e3e57d2682fe340306b8a5b4e403f3b2f5ef302ea5deb`

## S1 — 每个 JS 函数的 opcode 普查

### 计数器机制与正控

QuickJS 的函数身份来自 `JSFunctionBytecode.func_name` 和 debug 字段
（`quickjs.c:685-724`）。临时 qjs 副本在 `JS_CallInternal` 选定当前 `b`
（`quickjs.c:17746-17826`）后，于直接 dispatch 的 `SWITCH`（`quickjs.c:17761-17784`）记录
`b × opcode`；补丁保存在 `D11-S1-qjs-quickjs-c.patch` 与 `D11-S1-qjs-qjs-c.patch`。
原始 `/home/aneryu/quickjs/qjs` 未重建、未修改。

zjs 的对应身份在 `FunctionBytecode.func_name`（`src/bytecode.zig:1931-1940`）与 debug accessor
（`src/bytecode.zig:2202-2205,2429-2444`）。仅 profiling build 的 dispatch shim
（`src/exec/tailcall_dispatch.zig:5158-5178`）把 `vm.function × opcode` 记录到诊断表
（`src/exec/vm_profile.zig:19-36`），默认 dispatch table 完全不经过该 shim。

正控脚本调用 `hot` 三次、从不调用 `cold`。两侧均得到 `hot total=12`，精确组成
`get_arg0/add/push_1/return = 3/3/3/3`；`cold` 不出现，overflow=false。证据：
`D11-S1-qjs-counter-smoke.jsonl`、`D11-S1-zjs-counter-smoke.txt`。这证明计数器既能检出已知发生，
也能在声明“不发生”前给出有效负控。

### RayTrace

总 opcode：zjs **190,239,964**，qjs **189,993,039**，z/q=**1.001300**；与既有 RayTrace
总量比独立复现一致。zjs 67 个函数体，qjs 68 个，均 overflow=false。

| JS 函数（源码行） | 调用数 | z opcode / 占比 | q opcode / 占比 | zjs 主要组成（qjs 对应体相同，除注明外） |
|---|---:|---:|---:|---|
| `Class.create` 返回包装体 (438) | 2,530,574 | 27,836,314 / 14.63% | 27,836,314 / 14.65% | `get_loc0` 5.06M；`special_object(arguments)`、`call_method`、`return_undef`、`get_field*` 各 2.53M |
| `Color.initialize` (487) | 951,596 | 25,691,724 / 13.50% | 25,691,724 / 13.52% | `put_field/lnot/get_loc0/if_false8` 各 2.85M |
| `Vector.initialize` (626) | 999,324 | 20,930,856 / 11.00% | 20,930,856 / 11.02% | `put_field/get_loc0/if_false8` 各 3.00M，`goto8` 2.94M |
| `Vector.dot` (654) | 744,648 | 14,892,960 / 7.83% | 14,892,960 / 7.84% | `get_field` 4.47M，`mul` 2.23M，`add` 1.49M |
| `Vector.subtract` (662) | 496,204 | 14,389,916 / 7.56% | 14,389,916 / 7.57% | `get_field` 3.97M，`get_arg*` 3.97M，`call_constructor` 0.50M |
| `Engine.rayTrace` (1112) | 29,032 | 14,221,044 / 7.48% | 14,221,044 / 7.49% | `get_field` 4.68M，`call_method/get_field2` 各 1.23M |
| `Sphere.intersect` (829) | 219,184 | 11,964,832 / 6.29% | 11,964,832 / 6.30% | `get_field` 2.42M，`call_method/get_field2` 各 0.75M |
| `Engine.testIntersection` (1083) | 126,464 | 11,375,528 / 5.98% | 11,375,528 / 5.99% | `get_field` 1.52M，`if_false8` 1.23M，`get_loc2/get_arg1` 各 0.89M |

完整逐函数、逐 opcode 表在 `D11-S1-raytrace-summary.json`；原始两侧 JSONL 为
`D11-S1-zjs-raytrace.jsonl`、`D11-S1-qjs-raytrace.jsonl`。

### PdfJS

总 opcode：zjs **97,197,229**，qjs **97,457,771**，z/q=**0.997327**；zjs 410 个函数体，
qjs 417 个，均 overflow=false。

| JS 函数（源码行） | 调用数 | z opcode / 占比 | q opcode / 占比 | zjs 主要组成 |
|---|---:|---:|---:|---|
| `FlateStream_getCode` (28035) | 199,548 | 18,889,818 / 19.43% | 18,889,818 / 19.38% | `get_loc8` 3.38M，`put_loc8` 1.19M，`get_field/get_array_el` 各约 0.80M |
| `Type1Parser_extractFontProgram` (17347) | 18 | 11,255,172 / 11.58% | 11,255,462 / 11.55% | `dup/push_atom_value/strict_eq/if_false8` 各 1.28–1.43M |
| `decrypt` (17048) | 928 | 7,648,384 / 7.87% | 7,647,456 / 7.85% | `get_loc8` 1.43M，`add/push_1/push_i8/get_loc0` 各 0.48M；z `return` 对 q `tail_call` 形成 928-op 差 |
| `generateHuffmanTable` (28062) | 60 | 6,755,310 / 6.95% | 6,755,310 / 6.93% | `get_loc8` 1.72M，`get_loc2` 0.71M，`if_false8` 0.55M |
| `DecodeStream_ensureBuffer` (27741) | 170 | 6,362,734 / 6.55% | 6,362,734 / 6.53% | `get_loc8` 1.59M，`if_false8/lt/goto8/get_loc1` 各约 0.53M |
| base64 decoder body (558) | 18 | 5,734,826 / 5.90% | 5,734,826 / 5.88% | `get_arg0/get_loc1` 各 0.42M，`add/and` 各 0.32M |
| `FlateStream_readBlock` (28100) | 22 | 4,970,914 / 5.11% | 4,970,914 / 5.10% | `get_loc8` 1.69M，`if_false8` 0.42M，`lt/goto8/put_loc8/put_array_el` 各约 0.23M |
| PDF data builder body (586) | 1 | 3,660,404 / 3.77% | 3,660,404 / 3.76% | `call_method/get_field2` 各 0.41M，`get_var` 0.26M |

完整表在 `D11-S1-pdfjs-summary.json`；原始 JSONL 为 `D11-S1-zjs-pdfjs.jsonl` 与
`D11-S1-qjs-pdfjs.jsonl`。

## S2 — 真实成本：消融与真实输入微基准

### 输入不是编造的

- RayTrace d16 实际 render 38 次。首个 render 的构造参数个数直方图为
  `{0:11913, 1:1, 2:3331, 3:51346, 5:2, 6:1}`；因此六形参 direct variant 覆盖实际最大值。
  `Vector.dot` 首个 render 实际发生 19,596 次，每 64 次采一个，共 307 个真实六分量样本。
- PdfJS d16 实际 run 2 次；首个 run 的 `getCode` 发生 99,774 次，每 256 次采一个，共 390 个
  `[maxLen, codeSize, codeBuf, bytesPos, next4bytes, codes.length, index, code, codeVal]` 状态快照。
- 证据原文：`D11-S2-raytrace-input-capture.txt`、`D11-S2-pdfjs-input-capture.txt`。

三个抽取脚本在 qjs 与三个 zjs 上的 checksum 均完全相同：
`D11_WRAPPER 3499584`、`D11_DOT 12218168.373026293`、`D11_GETCODE 194940928`。
包装体微基准保留了真实参数个数与对象 key/shape；对象字段值用零占位，因为包装体本身从不读取字段值，
这是该微基准的明确限制。

### 因果 Zoo A/B（最终裁决）

每格为“variant 相对 base 后，zjs/qjs 分数比的变化”；高为好。

| 消融 | pad0 | pad3 | pad7 | 中位 / 极差 | 效应÷极差 | 裁决 |
|---|---:|---:|---:|---:|---:|---|
| Ray 包装体：`apply(arguments)` → 六形参 direct | +5.322% | +5.220% | +5.556% | **+5.322% / 0.336 pp** | **15.84x** | **成立**：中位有利，最坏 pad +5.220% |
| Ray `Vector.dot`：9 个调用点内联同一算术 | -0.402% | +0.068% | -0.071% | -0.071% / 0.470 pp | 0.15x | **否决**：中位不利且最坏回退 |
| Pdf `getCode`：3 个调用点内联同一状态机 | -1.031% | -0.767% | -0.903% | **-0.903% / 0.264 pp** | 3.42x（方向不利） | **否决**：所有 pad 都恶化 |

原始 8 样本 ABBA、每次 score/stdout/order 均在 `D11-S2-source-zoo.json`。base/variant 都通过基准自身
正确性校验。包装体普通 Zoo 的中位分数示例：qjs `3401 → 4724`；zjs-pad0 `2576 → 3768.5`。

这里两侧减少的是相同动态 JS 调用点与相同函数体工作：

- 包装体 direct variant 仍调用相同 `initialize`，只删除 `arguments` 对象物化、`apply` native 边界与
  匿名包装帧。目标初始化函数不观察 `arguments.length`，额外未用形参是 `undefined`，基准 checksum 不变。
- dot variant 在全部 9 个真实调用点保持 `x*w.x + y*w.y + z*w.z` 的运算与属性读取次序。
- getCode variant 用独立改名局部变量在全部 3 个调用点复制同一 bit-buffer 状态转移与异常条件。

### fixed-work PMU（机制证据，不作裁决）

表中 delta = base cycles − variant cycles；越大表示消融删除的成本越大。

| 消融 | qjs delta | zjs delta（pad0 / 3 / 7） | z/q delta（pad0 / 3 / 7） | 绝对 z 额外 cycles（pad 中位 − q） |
|---|---:|---:|---:|---:|
| Ray 包装体 | 907,634,697 | 1,802,258,123 / 1,837,801,475 / 1,836,450,964 | 1.986 / 2.025 / 2.023 | **928,816,267** |
| Ray dot | 86,063,444 | 131,118,746 / 134,207,034 / 144,120,883 | 1.524 / 1.559 / 1.675 | 48,143,590 |
| Pdf getCode | 30,271,615 | 33,177,599 / 27,862,047 / 27,619,737 | 1.096 / 0.920 / 0.912 | -2,409,568（跨 1 且 layout-sensitive） |

指令 delta 也不是噪声幻觉：包装体 z/q 为 1.910–1.913；dot 的 z delta 442–455M 对 q 244M；
getCode 的 z delta 142.8–143.4M 对 q 87.0M。cycles 仍表现布局离散，故最终按上表 Zoo 否掉 dot/getCode。
原始数据：`D11-S2-ablation-pmu.json`。

### 真实输入抽取微基准（第二种互证）

| 函数形态 | 动态调用数 | q delta cycles | z pad 中位 delta | z/q | 每调用 z 额外 | 投影到 d16 |
|---|---:|---:|---:|---:|---:|---:|
| 包装体 apply → direct | 4,262,016 | 1,265,161,839 | 2,095,107,113 | **1.6560** | 194.7 | **492.8M** |
| `Vector.dot` call → inline | 1,257,472 | 123,669,390 | 164,942,206 | **1.3337** | 32.8 | 24.4M（宏观消融为 48.1M） |
| `getCode` call → inline | 1,597,440 | 148,014,837 | 186,021,566 | **1.2568** | 23.8 | 4.75M |

三 pad cycles 比值极差分别约 0.0276、0.0395、0.0309。原始数据：
`D11-S2-wrapper-micro-pmu.json`、`D11-S2-micro-v2-pmu.json`。
`D11-S2-ablation-pmu.json` 中早期两个顶层全局变量微基准因改变 lookup 形态而被拒绝，不进入任何结论；
表中只使用修正为 `run()` 局部作用域的 v2 数据。

## S3 — 慢函数连回引擎机制

### 已成立的 RayTrace 包装体

QuickJS 的路径是：

1. `OP_special_object` 在 `quickjs.c:17966-17979` 构造 mapped `arguments`；
2. `OP_call_method` 在 `quickjs.c:18220-18236` 进入 `JS_CallInternal`；
3. `JS_CallInternal` 在 `quickjs.c:17746-17870` 分配并初始化 JS 栈帧；返回再释放调用区。

zjs 对应路径是 `op_special_arguments`（`src/exec/tailcall_dispatch.zig:2807-2818`）、
`op_call_method`（`src/exec/tailcall_dispatch.zig:1584-1625`）、`Machine.pushCall`
（`src/exec/inline_calls.zig:3118-3130`）与 `op_return_undef`
（`src/exec/tailcall_dispatch.zig:1332-1339`）。这不是“zjs 出线函数对 qjs 符号”的采样比较，
而是两个引擎运行同一源码的受控减法。

包装体每次固定执行一条 `special_object(arguments)`、一条 `call_method`、一次包装帧 return，并触发
下游 initialize 调用。按题面机制单价仅作组成解释：2.531M 次 apply/arguments 贡献约 256.1M 的
z-q 差，method/native 桶约 109.3M，固定帧约 46.1M；这些项与 0.49–0.93G 的受控实测同方向，
差额来自真实初始化/构造链的边界交互，故不把单价模型当作绝对计时器。

### RayTrace 前 8 个机制候选（仅排序假说）

下表把 S1 频次乘题面已有单价。`method/native` 与 constructor 是放大的桶边界，只可用来挑下一项
消融，不能宣称函数已被真实定价。

| 排名 | JS 函数 | 模型 z 额外 cycles | 主导项 | 结论 |
|---:|---|---:|---|---|
| 1 | 包装体 (438) | 442.2M | apply 256.1M、method 109.3M、frame 46.1M | **已由两种 S2 + Zoo 证明**；实测 0.50–0.93G |
| 2 | `IntersectionInfo.initialize` | 61.8M | constructor 45.7M、frame 8.2M、return 7.3M | 未做独立消融，候选 |
| 3 | `Vector.subtract` | 60.2M | constructor 50.1M、frame 9.0M、return 8.0M | 未做独立消融，候选 |
| 4 | `Sphere.intersect` | 59.7M | method 32.3M、constructor 22.1M、frame 4.0M | 未做独立消融，候选 |
| 5 | `Engine.rayTrace` | 58.7M | method 53.1M、constructor 11.7M | 未做独立消融，候选 |
| 6 | `Vector.initialize` | 45.9M | write 18.3M、frame 18.2M、return 16.1M | 属性/opcode 赢项会抵消；未证明慢 |
| 7 | `Color.initialize` | 41.5M | write 17.4M、frame 17.3M、return 15.3M | 同上 |
| 8 | `Vector.normalize` | 41.4M | constructor 24.9M、method 10.7M、frame 4.5M | 未做独立消融，候选 |

`Vector.dot` 不在该模型前列却由微基准测出每调用 32.8 cycles 额外成本；这与题面 +18.2 cycles/call
和 return 拆除较贵同方向。但它在最终 Zoo 不成立，说明不能从 fixed-work 函数成本直接推导吞吐分数。

### PdfJS：组成解释不了分数

PdfJS 最大的五个 opcode 体中，除 `getCode` 199,548 次外，其余调用数仅 18、928、60、170；它们
主要是 `get_loc*`、分支、整数运算和数组元素访问。已知“每 opcode zjs 赢 15%”与近乎相同的总 opcode
数本应预测 zjs 有利，但实际基线普通 Zoo 约 0.77、d16 cycles 约 1.332G 对 qjs 1.102G。

单价模型给出的 PdfJS 前部候选是 PDF data builder（16.1M）、`Type1Font_wrap`（10.9M）、
`FlateStream_readBlock`（7.0M）、`stringToArray`（6.7M）、`fontLoaderBind`（5.9M）、
`arrayToString`（5.8M）、base64 body（4.5M）、`isSeparator`（4.5M）。但这些数字大量来自把
`call_method` 乘 native-boundary 上界，**不是逐函数真实 z/q**。本轮唯一受控定价的 `getCode` 又被 Zoo
明确反证。因此 PdfJS 的诚实结论是“尚未命名的宏观机制”，而不是强行选一个函数。

## S4 — 按绝对 cycles 排序与建议

| 顺序 | 项目 | 绝对 z 额外 cycles / d16 | 最终 Zoo 估计 | 形态范围 |
|---:|---|---:|---|---|
| 1 | Ray `apply(arguments)` 构造包装体 | **0.50–0.93G** | Ray 比值 ×1.0522–1.0556；0.754 → **约 0.794**（0.793–0.796） | **跨基准形态**：mapped arguments + apply/native + JS frame，不是 Ray 特有 API |
| 2 | Ray `Vector.dot` 调用边界 | fixed macro 48.1M；微投影 24.4M | **0：Zoo 否决**，三 pad 中位 -0.071% | 跨基准普通小 JS 调用形态，但该基准内无可兑现分数 |
| 3 | Pdf `getCode` 调用边界 | 微投影 4.75M；宏观 delta 跨过 1 | **负：-0.903% 中位**，不能作为赤字 | Pdf/flate 特有状态机；抽取结果不能外推 |
| — | PdfJS 未命名残差 | 约 **137M** 的模型残差 | 未决，不给乐观分数 | 更像跨长循环的 element/backing/lifecycle 机制，需新实验 |

若只作反事实上界，把 Ray 包装体追平而其余 14 项完全不变，则题面全 Zoo geomean 0.9110 约变为
**0.9142（0.9141–0.9143）**。这是 `1.0522–1.0556` 的十五项几何平均折算，不是候选 A/B，也不含
跨 benchmark 联动，所以不确定度至少包括 pad 区间、微/宏 cycles 的 0.43G 分歧及 Zoo 重复运行相位。

建议按以下顺序继续：

1. 针对 QuickJS 已有的 mapped-arguments / `Function.prototype.apply` / 普通 JS frame 机制做统一对齐，
   以 `quickjs.c:16215`、`17966-17979`、`18220-18236` 为机制锚；**不要**为 Ray 包装体加特化或 bypass。
2. 下一次 Ray 消融优先 `Vector.subtract` / `IntersectionInfo.initialize`，因为它们在绝对模型中高，
   但必须再次以普通 Zoo 多 pad 裁决。
3. PdfJS 暂停“按函数名猜”。先在真实 PdfJS 路径按当前函数聚合 `get_array_el/put_array_el` 的 slow arm、
   typed-array/string backing 与 allocation/GC 事件频次；再对能解释约 137M residual 的机制做源码消融。

## 出线口计数器证据

- Ray 包装体两侧都精确执行 2,530,574 次 `special_object`、2,530,574 次 `call_method`、
  2,530,574 次 `return_undef`；消融删除的正是这些事件，未借用侵入式计数器的时间。
- `Vector.dot` 两侧调用 744,648 次且各执行 14,892,960 opcode；fixed-work 命中但 Zoo 未出线，已否决。
- Pdf `getCode` 两侧调用 199,548 次且各执行 18,889,818 opcode；计数器确认宏观确实走到该函数，
  所以 Zoo 反向结果不是“微基准测了不存在的函数”，而是隔离成本不能代表总体吞吐。
- qjs/zjs 计数器正控、总量守恒、overflow=false；所有单位成本均来自未修改生产二进制。

## 门禁原文

| 命令 | 结果 | 原始日志 |
|---|---|---|
| `zig build test-exec --seed 0 --summary all` | **PASS**：416 passed | `D11-gate-test-exec.txt` |
| `zig build test-bytecode --seed 0 --summary all` | **PASS**：69 passed | `D11-gate-test-bytecode.txt` |
| `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` | **非绿（语料阻塞）**：编译成功；2162 passed、1 skipped、2 `FileNotFound` | `D11-gate-test-releasesafe.txt` |
| `bash tools/perf/lint_anti_goals.sh` | **PASS，exit 0** | `D11-gate-lint-anti-goals.txt` |
| `git diff --check` | **PASS，exit 0** | `D11-gate-diff-check.txt` |

ReleaseSafe 的两项失败原文为：

```text
FAIL: cli.run_test262.test.embedded Debug runner executes a representative test262 harness within its native stack budget (FileNotFound)
FAIL: cli.run_test262.test.test262 typed array iterator staging source parses after installing globals (FileNotFound)
```

`git submodule status test262` 为 `-4249661388e5d3f92a85186213da140a6481490f test262`，且所需 typed-array
fixture 不存在，见 `D11-gate-test262-presence.txt`。按任务契约，本 worktree 无 test262 语料，canonical gate
由 driver 在 main 运行；本任务未修改 `test262.conf`、`test262_errors.txt` 或任何既有 report/docs 文件，
也没有把这两个 FileNotFound 伪报成通过。

## 产物索引

- S1 完整表：`D11-S1-raytrace-summary.json`、`D11-S1-pdfjs-summary.json`
- S1 原始计数：`D11-S1-{zjs,qjs}-{raytrace,pdfjs}.jsonl`
- S2 PMU：`D11-S2-ablation-pmu.json`、`D11-S2-micro-v2-pmu.json`、`D11-S2-wrapper-micro-pmu.json`
- S2 普通 Zoo：`D11-S2-source-zoo.json`
- S2 真实输入：`D11-S2-raytrace-input-capture.txt`、`D11-S2-pdfjs-input-capture.txt`
- 可审计工具：`tools/perf/jslevel/`

