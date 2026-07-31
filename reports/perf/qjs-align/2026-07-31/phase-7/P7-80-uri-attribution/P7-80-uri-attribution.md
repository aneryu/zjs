# P7-80：string/URI decode 归因（Phase 7 收口线）

- 日期：2026-07-31
- 基线：**`89fa82d5`**（P7-70 合并提交）　对照：pinned qjs **`04be2460`**（VERSION 2026-06-04）
- 性质：**纯归因，不落生产改动**。`git diff 89fa82d5 -- src/` 无输出。
- 数据产物：本目录 11 份；原始录制在 `.zig-cache/perf/p7-80/`

## 裁决（决策树分支 A）

```text
Decision:
    benchmark name is misleading;
    URI decode is not the dominant cost;
    residual string-construction cost is distributed;
    no one-cut.
```

分支判据逐条对照：

| 判据 | 实测 | 结论 |
|---|---|---|
| decode 是否主因（≥40%） | `decodeURI` 占周期差 **24.7%**（时间口径 28.6%） | 否，排除分支 D |
| fusion 是否命中 | 每次 decode 命中，miss 率 **0.8%**（且落在空脚本地板噪声内） | 命中，排除分支 C |
| 字符串构造半边是否有单一集中机制（≥40%） | 最大单项是外层 concat **21.4%**；下标读 + `"%XX"` 构造 23.0% | 否，排除分支 B |
| 最大单项 | **24.7%**（decode 本身） | <40%，落分支 A |

**收口表**（`p780_L3_full` ≡ `uri_decode_4byte`，65536 次内层迭代，PMU 计数模式，
两个构建实例对各自 8 次 ABBA 采样取中位后取均值）：

| 阶段 | cycles/迭代 qjs | cycles/迭代 zjs | **Δcycles/迭代** | 占 zjs−qjs 差 | Δinstructions/迭代 |
|---|---:|---:|---:|---:|---:|
| 循环骨架 + 整数算术（每一根横梁都在） | 208.4 | 236.6 | +28.3 | **11.2%** | +41.7 |
| string indexing 与 `"%XX"` 构造 | 259.2 | 317.4 | +58.2 | **23.0%** | **−152.6** |
| 多出来的那次 concat（9+3） | 78.2 | 132.4 | +54.2 | **21.4%** | +151.2 |
| URI decode / fusion | 153.9 | 216.3 | +62.4 | **24.7%** | +160.7 |
| `fromCharCode` + 字符串比较 | 135.0 | 176.8 | +41.8 | **16.5%** | **−48.3** |
| 未归因 | — | — | +7.8 | **3.1%** | — |
| **全 case** | **832.7** | **1085.4** | **+252.7** | 100% | +196.7 |

分解误差 3.1%，在允许的 10–15% 之内。**`fromCharCode` 与字符串比较未能干净分开**：
用 `p780_L2s_fromcharcode` 单独加 `fromCharCode` 得到的时间差是 +1.059 ms，
与 `L3−L1`（+1.738）、`L2−L1`（+1.163）相减得到 −0.484 ms 的负残差，说明这三根横梁的
消费语句（`.length`/`&1`）互相重叠、无法再分。按合同要求如实声明：**这一格只解析到
「`fromCharCode` + 比较」这个组，不再往下切。**

三条支撑结论：

1. **case 名字是误导的。** decode 占 24.7%（周期）/ 28.6%（时间），
   字符串构造那一半（下标读 + `"%XX"` + 外层 concat）合计 **44.4%**（周期）/ 46.7%（时间），
   是 decode 的 1.8 倍。这是 `array_map_callback` 教训的第二次出现，登记在案。
2. **fusion 命中，而且它只是四条 zjs-only 缓存里的一条。** 这个 case 已经被 zjs 专门
   缓存了四次（单字节字符串缓存、`"%"+digit` 缓存、`"%X"+digit` 永久缓存、12 字节
   四字节转义探针 + 两单元结果缓存），**仍然慢 1.29x**。
3. **这是 case B 不是 case A。** 全 case 指令只多 4.0%，周期多 30.3%，IPC 5.98 → 4.77。
   两格甚至是**指令更少而周期更多**：`"%XX"` 构造 −152.6 条指令 / +58.2 周期，
   `fromCharCode` + 比较 −48.3 条指令 / +41.8 周期。缓存真的削掉了工作量，时间还是回不来。

### 关于本报告的篇幅

收窄指令（「Phase 1 出裁决即收线，不要机械跑完四个阶段」）到达时，Phase 2–4 的采集
**已经完成**。已采到的、已验证的数据不销毁，但全部降级到 §6 作为**支撑证据**，
它们**不改变上面的裁决**，也不构成对 string 子系统的扩展研究。§1–§5 是收口所需的全部内容。

## 1. 测量装置

新增 `tools/compare/p780_uri_cases.js`（29 个诊断 case，`--suite p780-uri`），走既有
`run_microbench.js` 与 `validate_measurement_artifact.js`，产物自带 provenance 且
fail-closed。**没有另写采样器。**

阶梯顶端的 `p780_L3_full` / `p780_L3c_full` 逐字复制历史源码，`sourceSha256` 与
`uri_decode_4byte` / `uri_component_decode_4byte` **完全相同**
（`2b84f8b0…` / `0d931f0e…`），所以「阶梯顶端就是 P7-70 头条 case」是可核验的，不是声称。

| 项 | 值 |
|---|---|
| kernel / arch | `6.17.0-1014-nvidia` / aarch64 |
| 绑核 | CPU 19，`--formal --cpu 19`，collector 与每个被测子进程有效 affinity 精确为 `{19}` |
| PMU | `armv8_pmuv3_1`（type 11，cpus `5-9,15-19`）；所有事件写全限定名，不可能解析到 `<not counted>` |
| zig / bun / perf | 0.16.0 / 1.3.13 / 6.17.9 |
| 采样 | iters=8（偶数），warmup=4，ABBA per-sample，首位平衡 |
| 锁 | 正式采样 `flock -x`，构建与 gdb `flock -s` |
| zjs 表示 | 16-byte payload+tag（`zjs_nan_boxing=false`，aarch64 默认） |

**两侧各两个独立冷缓存构建，四种组合全部报告：**

| 身份 | sha256 | size | .text |
|---|---|---:|---:|
| `zjs-A` | `b4258dfc…` | 29563992 | 3855804 |
| `zjs-B` | `7fca97a8…` | 29563992 | 3855804 |
| `qjs-A` | `b76d1542…` | 5139280 | 725228 |
| `qjs-B` | `5e331bf9…` | 5139288 | 725228 |

`zjs-A` 与 `zjs-B` **不是逐字节相同**（size 与 `.text` 相同但 sha256 不同），
所以本轮**没有免费噪声尺**，只能靠四组合离散度自证。四个组合的 suite paired geomean 为
1.2326 / 1.2345 / 1.2344 / 1.2360，**极差 0.0034（0.28%）**；四个产物
`validate_measurement_artifact.js --formal` 全部 `complete: true`。
另有一整轮独立的 23-case 前置采样（`p780-*` 产物，另一个测量代次），
`p780_L3_full` 的 paired median 为 1.293/1.287/1.289/1.290，与本轮
1.291/1.289/1.288/1.290 逐格一致。

## 2. 复现头条

| case | qjs | zjs | 绝对差 | paired median（四组合） |
|---|---:|---:|---:|---|
| `p780_L3_full` ≡ `uri_decode_4byte` | 14.046 ms | 18.112 ms | **+4.066 ms** | 1.291 / 1.289 / 1.288 / 1.290 |
| `p780_L3c_full` ≡ `uri_component_decode_4byte` | 14.057 ms | 18.130 ms | +4.073 ms | 1.288 / 1.289 / 1.287 / 1.295 |

P7-70 记录的是 +4.047 ms / 1.285 与 +4.129 ms / 1.295。复现无异议。
两个 case 在每一根横梁上都在 0.02 ms 内重合，**下文所有拆解对 component 变体同样成立**，
不再分列。

## 3. 第一问：decode 本身占多少

加性阶梯，每一根横梁只增加一条语句；循环嵌套与 `index`/`L`/`H` 整数算术在**每一根**
横梁上都在（包括骨架），所以不会出现在任何一个差里。

| 阶段 | 表达式 | qjs ms | zjs ms | gap ms | ns/迭代 | 占 4.066 ms |
|---|---|---:|---:|---:|---:|---:|
| 循环骨架 + 整数算术 | `L0` | 3.586 | 4.014 | +0.427 | 6.5 | 10.5% |
| 字符串构造（整体） | `L1 − L0` | 5.614 | 7.515 | +1.901 | 29.0 | **46.7%** |
| `decodeURI` | `L2 − L1` | 2.611 | 3.773 | +1.163 | 17.7 | **28.6%** |
| `String.fromCharCode` + `===` | `L3 − L2` | 2.235 | 2.810 | +0.576 | 8.8 | 14.2% |
| 合计 | | | | +4.067 | 62.0 | 100.0% |
| 实测全 case | `L3` | 14.046 | 18.112 | +4.066 | 62.1 | — |

四项之和 4.067 对实测 4.066，加性残差 0.001 ms（0.02%）。每一根横梁的 gap 在四种
构建组合之间的极差 ≤0.125 ms。

**答案：decode 占 28.6%（时间）/ 24.7%（周期），不是主因。字符串构造是它的 1.6–1.8 倍。**

## 4. 第二问：字符串构造半边有没有单一集中机制

| 子项 | 表达式 | gap ms | ns/迭代 | Δcyc/迭代 | 占总 gap（周期口径） |
|---|---|---:|---:|---:|---:|
| 函数调用 + 常量字符串 | `B0 − L0` | +0.327 | 5.0 | — | — |
| 两次字符串下标读 | `B1 − B0` | +0.231 | 3.5 | — | — |
| 两次短 concat `"%"+c+c` | `B2 − B1` | +0.389 | 5.9 | — | — |
| 以上三项合计 | `B2 − L0` | +0.947 | 14.5 | **+58.2** | **23.0%** |
| 外层 9+3 concat | `B3 − L0` | +0.891 | 13.6 | **+54.2** | **21.4%** |
| 子项之和 | | +1.838 | 28.0 | +112.4 | 44.4% |
| 独立实测 | `L1 − L0` | +1.901 | 29.0 | +120.2 | 47.6% |

子项之和 1.838 ms / 112.4 cyc 对独立实测 1.901 ms / 120.2 cyc，差 3.3% / 6.5%。
`B3` 的操作数是两个 hoisted 常量，而 `L1` 里左操作数是刚构造出来的 9 字符串、
右操作数是缓存命中的 `"%XX"`，这个差就是它，已如实标注。

**答案：没有。** 最大单项是外层 concat 的 21.4%，其次是「下标读 + `"%XX"` 构造」这一组
的 23.0%，两者都远低于 40%；把三次 concat 合并也只有 31.5%（时间口径），
再往上合就变成 P7-42 明令禁止的「打包成一个大字符串优化」。

一个必须说明的形状：**`"%XX"` 构造这一组 zjs 少执行 152.6 条指令，却多花 58.2 个周期。**
`exec/value_ops.zig` 的 `percentHexConcat` 把 `"%" + hexdigit` 与 `"%X" + hexdigit`
分别短路到 `recentTwoUnitString` 和永久的 `percentHexString[256]`，正好是
`decimalToPercentHexString` 的形状。`p780_B2x_nonhex` 用 `G..V` 字母表复制同一语句形状
让它 bail：**qjs 侧差 +0.2 ns（等于没差，证明控制是干净的），zjs 侧差 +13.9 ns/迭代**
（+390 指令 / +51 周期）。所以这一格不存在「补一条快路径」的空间——快路径已经在了，
而且已经把指令数压到 qjs 以下。

## 5. Phase 1 最小交付：每迭代事件计数与 fusion 命中

**方法：gdb 断点命中计数，缩小到 256 次内层迭代，减空脚本地板；不改任何源码、
不编入任何计数器、不改变被测二进制。** 每个计数点先在「该事件已知存在」的场景上证明
能检出，再信任它的零（measurement-contracts §5）。

| 事件（每次内层迭代） | qjs | zjs | 证据 |
|---|---:|---:|---|
| string index 次数 | 2 | 2 | qjs `js_new_string8_len` **2.098**（每次下标读建一个单字符串）；zjs 0 次分配（`single_byte_strings` 缓存命中） |
| concatenation 次数 | 3 | 3 | qjs `JS_ConcatStringInPlace` **3.047**（其中 1 次成功）+ `JS_ConcatString1` **2.031**；zjs `concatFlatStringBodiesOwned` **3.047** |
| decode 调用次数 | **1.000** | **1.000** | qjs `js_global_decodeURI`；zjs `exec.uri_ops.decodeAsciiBytes` |
| `fromCharCode` 次数 | **1.000** | **1.000** | qjs `js_string_fromCharCode`；zjs 经 `recentTwoUnitString` 命中，0 次分配 |
| 字符串相等次数 | 1 | 1 | 源码层每迭代一次；**未单独插桩**，见 §7 |
| URI fusion admission | — | **1.000** | 每一次 decode 都到达探针 |
| URI fusion hit | — | **0.992** | `createUtf8`（通用路径唯一出口）**0.008/迭代** |
| URI fusion miss | — | **0.008** | 该值落在空脚本地板噪声内（17 对 15 次） |
| 结果缓存 hit / miss | — | 1 hit / 2 miss | `recentTwoUnitString` **3.016/迭代** |

**fusion 命中的双向验证。** `probe_miss` 控制用 `"%E4%B8%AD%41"`——同样 12 字节输入、
同样 2 个宽输出单元，只是首字节 `0xE4 < 0xf0` 使探针必然 bail：

| 计数点 | reduced 全负载 /迭代 | `probe_hit` 256 次调用 | `probe_miss` 256 次调用 | 空脚本 |
|---|---:|---:|---:|---:|
| `exec.uri_ops.decodeAsciiBytes` | **1.000** | 256 | 256 | 0 |
| `core.string.String.createUtf8` | **0.008** | 16 | **272** | 15 |
| `core.runtime.JSRuntime.recentTwoUnitString` | **3.016** | 256 | **0** | 0 |

`probe_miss` 把 `createUtf8` 顶到 257 次（1.00/调用）、把 `recentTwoUnitString` 压到 0；
同一个断点在 reduced 全负载上读到 0.008/迭代。**所以「探针每次命中」这个零是可信的。**

`recentTwoUnitString` 每迭代 3.016 次，正对应三个调用点：`percentHexConcat("%", digit)`、
decode 探针结果 `(H, L)`、`String.fromCharCode(H, L)`。前两次 miss（各分配一个两单元
字符串），第三次 hit——**decode 与 `fromCharCode` 拿到同一个 `*String` 指针，`===`
因此是指针比较**。fusion 确实在工作。

fusion 值多少（行为学控制，不靠 profile）：

| 情形 | zjs vs qjs |
|---|---|
| 形态命中 + 结果缓存命中（`dec_esc1`，常量输入） | **1.00x，完全平价** |
| 形态命中 + 结果缓存 miss（`dec_esc1_vary`，本 case 所处档位） | 1.24x，+8.2 ns/调用 |
| 形态 bail、输入/输出形态完全相同（`dec_3b1`） | **1.86x，+31.2 ns/调用** |

## 6. 收窄指令到达前已采集的支撑证据

以下三组数据在收窄指令到达时已经采完并通过校验，**不改变 §0 的裁决**，
列出以免销毁已验证的证据；它们不是本线要求的交付物。

### 6.1 分配拓扑（gdb 计数，同一次 reduced 负载）

| 事件 | qjs /迭代 | zjs /迭代 |
|---|---:|---:|
| 分配器入口 | `__js_malloc` **6.594** | `allocAlignedBytesNoTrigger` **3.371** |
| 释放 | `__js_free` **6.598** | `freeAlignedBytes` **3.027** |
| 字符串对象构造 | `js_alloc_string` 6.141 | 3（2×`recentTwoUnitString` miss + 1×`createLatin1Concat`） |
| realloc | `js_realloc2` 2.109 | 0 |
| rope 构造 / flatten | 0 | 0 |

**zjs 每次迭代分配 3.37 次、qjs 6.59 次，zjs 少一半，仍慢 1.29x。**
两侧 rope 阈值一致（qjs `JS_STRING_ROPE_SHORT_LEN` 512 / `SHORT2_LEN` 8192，
`quickjs.c:216-218`；zjs `String.rope_short_len` / `rope_short2_len` 同值），
9+3=12 远在阈值内，两侧都不建 rope，实测 rope 构造与 flatten 均为 0。
`JS_ConcatStringInPlace`（`quickjs.c:4671`）三次调用只成功一次（`("%X") + c`，
左操作数 rc==1 且 `js_malloc_usable_size` 有余量）。按 P7-00 的登记，分配器 size-class
效应是两侧共担、不是 zjs 独有税，此处**不重新审判分配器**；上表只用来否定
「差额来自分配次数」这一假设，而它确实被否定了。

### 6.2 IPC 三角（`p780_L3_full`，每次内层迭代）

| 指标 | qjs | zjs | 差 |
|---|---:|---:|---:|
| instructions | 4978.5 | 5175.2 | **+196.7（+4.0%）** |
| cycles | 832.7 | 1085.4 | **+252.7（+30.3%）** |
| IPC | **5.98** | **4.77** | −20% |
| `stall_backend` | 213.8 | 329.2 | +115.4（占周期差 46%） |
| `stall_backend_mem` | 4.29 | 5.73 | **+1.45（占后端阻塞差 1.3%）** |
| `stall_frontend` | 23.7 | 63.1 | +39.4（16%） |
| `mem_access` | 1640.5 | 2432.9 | **1.48x** |
| `l1d_cache_refill` | 0.296 | 0.418 | +0.12 |
| `ll_cache_miss_rd` | 0.0855 | 0.1903 | +0.10 |
| `br_mis_pred_retired` | 0.902 | 1.345 | +0.44 |

**case B**，而且后端阻塞里只有 1.3% 是内存——与 P7-41/P7-42 的桥接税是同一个签名。
最刺眼的一格是 `mem_access` 1.48x：指令只多 4%，访存操作多 48%。而
`p780_L0_skeleton`（纯整数循环，全程不碰字符串）已经是 **1.37x**，
`p780_dec_base`（只读 `.length`）也是 1.37x —— **这不是 URI 特性，是 zjs 的全局表示特性**，
不属于本线。

### 6.3 symbol 归因（`perf record -c 10007`，固定计数 period，10007 为素数、
与内层周期 qjs 833 / zjs 1085 互质；每侧 3 次记录；只按 symbol 聚合，无裸 `file:line`）

qjs 的 `JS_CallInternal` 是把 property 读、concat 分派、JS→JS 调用全部内联进去的单体，
zjs 把同样的工作拆在三组 symbol 里，**所以只有合并桶可比**：

| 合并桶 | qjs cyc/迭代 | zjs cyc/迭代 | 差 |
|---|---:|---:|---:|
| VM dispatch + call machinery + property read | 417.6 | 710.3 | **+292.7** |
| 整条 string/URI 机制（concat + URI decode + allocator + string 构造 + fromCharCode + libc mem） | 321.4 | 215.7 | **−105.7** |
| value free + other | 91.8 | 156.8 | +65.0 |
| 合计 | 830.8 | 1082.8 | +252.0 |

合计 830.8 / 1082.8 对 PMU 计数模式的 832.7 / 1085.4，偏差 0.24%。
URI decode 本体单桶是 37.5 → 40.3（+2.8 cycles），基本平价。

§3–§4 的语句层拆分与本节的机制层拆分**不矛盾，是互补的**：语句层问「删掉哪条源码语句
差额会消失」，机制层问「周期实际落在哪个引擎机制里」。字符串构造语句携带 44–47% 的差额，
但那些周期落在执行这些语句的 dispatch / call / property 机制里，不落在 concat 与
allocator 本身。**这也意味着 P7-70 的「`string/URI` 是绝对成本最大子系统（10.267 ms）」
不应再驱动排序**：构成那 10.267 ms 主体的两个 case，机制层的 string/URI 部分是净赢。

## 7. 本条线没有建立的东西

1. **`fromCharCode` 与字符串比较没有分开。** 尝试用 `p780_L2s_fromcharcode` 分离得到
   −0.484 ms 的负残差（三根横梁的消费语句重叠），因此这一格只解析到组。
2. **字符串相等次数没有单独插桩**，是从源码结构推的（每迭代一次）；两侧的相等实现
   （zjs 指针比较 vs qjs `js_string_memcmp`）未量化。
3. **没有构建原生 C1 / C2 控制**，按收窄指令也不该构建。§6 的每调用/每字节回归
   （`P7-80-results.json` 的 `perCallVersusPerByteRegression`）是较弱的替代物：
   它**无法把「结果字符串对象的构造与发布」与「builtin 调用入口 + 输入分类」再分开**。
4. **`L0` 骨架的 +28.3 cyc/迭代（11.2%）未归因。** 它属于 control / binding 方向。
   同一现象在 `mem_access` 1.37x 上也出现，同样未归因。
5. **`stall_frontend`（占周期差 16%）没有 symbol 级分解；`other` 桶两侧各约 10–13% 未归因。**
6. **symbol 桶的跨引擎边界不完全对齐**（qjs 单体内联），因此逐桶绝对周期是指示性的，
   只有 §6.3 的三个合并桶达到仲裁强度。
7. **两个构建不是逐字节相同，本轮没有免费噪声尺。** 四组合极差 0.28%（geomean）与
   ≤0.125 ms（逐横梁 gap）是本轮全部的噪声证据。
8. **`decodeURIComponent` 只测了顶端横梁与一个控制**，没有单独建阶梯（`L3c` 与 `L3`
   在 0.02 ms 内重合，据此外推）。
9. **`p780_dec_plain12` 揭示的 zjs-only 无转义早退是行为分歧，本线只登记不裁决。**
   zjs 的 `uri_ops.call` 在 `stringDataContainsPercent` 为假时直接 `string_value.dup()`
   返回同一个字符串（zjs 27.0 ns/调用），而 qjs `js_global_decodeURI`
   （`quickjs.c:54755`）无条件走 `string_buffer` 重建整串（72.4 ns/调用）。
   对不可变字符串不可观测，但确实不是 qjs 的机制，属于忠实性问题，留给对齐审计。
10. **四条 zjs-only 缓存（`single_byte_strings`、`percentHexConcat` 的两条、12 字节探针 +
    `recentTwoUnitString`）的忠实性未裁决。** 本线只量化它们的价值（合计足以把
    `dec_3b1` 的 1.86x 拉到 `dec_esc1` 的 1.00x），不判断它们是否该存在。
11. **没有跑 test262。** `src/` 全程未改（`git diff 89fa82d5 -- src/` 无输出），
    本轮唯一改动是 `tools/compare/` 下的诊断语料与一处 suite 注册。
