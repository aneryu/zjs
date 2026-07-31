# P7-30：`new Uint8Array(64)` 的阶段拆解

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码
- 起点：`perf/qjs-align-p7-allocator` @ `2d2376a9`，基线 `a5bbbe52`
- 对照引擎：pinned Bellard QuickJS `04be2460`
- 数据产物：`P7-30-results.json`
- 上游：P7-00 在范围外撞见 `new Uint8Array(64)` 上 zjs 9336M insn / qjs 738M insn，并已证明两侧 arena churn 次数相同

## 裁决

> **单一集中阶段，不是分布式的。GC registration 阶段占 91.3% 的指令差与 94.3% 的时间差。**

具体机制：任何 backing store 超过 32 字节的 ArrayBuffer，在安装 byte storage 时会走
`Object.installByteStorage`（`src/core/object.zig:4432`）→ `JSRuntime.reportExternalAlloc`
（`src/core/runtime.zig:2492`）→ `requestGCForProcessMemoryPressure`（`src/core/runtime.zig:2540`）。
后者**无条件**读 `/proc/self/statm`，再依次探测两个 cgroup 限额文件：

```
openat("/proc/self/statm")                              -> read -> close
openat("/sys/fs/cgroup/memory.max")                     -> ENOENT
openat("/sys/fs/cgroup/memory/memory.limit_in_bytes")   -> ENOENT
```

**每次构造 5 个 syscall。** `strace -c` 在 200 000 次 `new Uint8Array(64)` 上读到
600 009 次 `openat`（其中 400 004 次失败）、200 003 次 `read`、200 005 次 `close`；
即 3.000/1.000/1.000 每次构造。qjs 没有任何对应物：`js_trigger_gc` 只比较两个进程内计数器，
不发 syscall。

而且这份工作在默认配置下是**死的**。`processMemoryRequest`（`src/core/gc.zig:1028`）消费这两个数字的
四道闸门，在默认 `balanced` 模式下全部静态关闭：`rss_soft_limit` / `rss_hard_limit` 是 `null`，
`cgroup_soft_ratio_per_mille` / `cgroup_hard_ratio_per_mille` 是 `0`（`src/core/gc.zig:49-52`）。
只有 `.low_rss` 模式才把两个 cgroup 比率设成 850/950（`src/core/gc.zig:77-78`）。
所以在这台机器、这个模式下，函数**永远返回 null**，5 个 syscall 的结果被完整丢弃。

## 1. 头条数字

8 样本、ABBA 平衡、`taskset -c 19`、独占主机锁，取中位数；200 000 次 `new Uint8Array(64)`。

| 配置 | insn/次 | cyc/次 | L1D 读/次 | L1D 写/次 | ns/次 |
|---|---|---|---|---|---|
| qjs | 3 630.8 | 626.5 | 752.2 | 583.4 | 160.7 |
| zjs（原样） | 46 231.2 | 16 553.8 | 8 773.9 | 5 508.2 | 4 244.8 |
| zjs，探针空转 | 46 817.8 | 16 126.5 | 8 887.5 | 5 586.1 | 4 135.3 |
| zjs，探针关闭 | 7 327.6 | 1 542.4 | 2 144.7 | 1 329.0 | 395.6 |

- zjs/qjs：**12.75× insn、26.40× 时间**。
- 关掉探针后：**2.02× insn、2.46× 时间**。
- 探针单次代价 **39 490 insn / 14 584 cyc / 3 739.7 ns**。
- 占 zjs−qjs 差距：**指令 91.3%，时间 94.3%**。

「探针空转」是同一个 `LD_PRELOAD` shim 只计数不拦截的那一侧，所以 A/B 两侧都带着 shim
本身的开销，shim 不在结论里。空转与原样的差是 +587 insn / −110 ns，即 shim 拦截 60 万次
`openat64` 的自身成本，相对 39 490 可忽略。

## 2. 阶段拆解：哪个阶段在付这笔钱

矩阵每例 200 000 次迭代，循环体包在函数里（顶层 `let` 循环是已知的 zjs-only 慢路径，
会污染归因）。6 样本 ABBA 中位数。「探针/次」由 `LD_PRELOAD` 计数器在两个引擎上用同一把尺读出。

| 阶段组合 | case | 探针/次 | qjs insn | zjs insn | 探针关 insn | 探针代价 |
|---|---|---|---|---|---|---|
| 只有循环 | `noop` | 0 | 286 | 272 | 273 | 0 |
| 全构造，内联存储 | `ta0` | 0 | 3 708 | 4 612 | 4 617 | 0 |
| 全构造，内联存储 | `ta8` | 0 | 3 625 | 4 709 | 4 712 | 0 |
| 全构造，内联存储 | `ta32` | 0 | 3 631 | 4 751 | 4 749 | 0 |
| 全构造，**出线存储** | `ta33` | 1.0000 | 3 632 | 46 229 | 7 276 | 38 953 |
| 全构造，出线存储 | `ta40` | 1.0000 | 3 638 | 46 237 | 7 285 | 38 952 |
| 全构造，出线存储 | `ta64` | 1.0000 | 3 631 | 46 281 | 7 333 | 38 948 |
| 全构造，出线存储 | `ta512` | 1.0001 | 3 887 | 47 247 | 8 294 | 38 954 |
| 只有 buffer，内联 | `ab32` | 0 | 2 868 | 3 129 | 3 137 | 0 |
| 只有 buffer，出线 | `ab64` | 1.0000 | 2 867 | 44 656 | 5 713 | 38 943 |
| 只有 view + 元数据 | `taview` | 0 | 1 814 | 4 657 | 4 657 | 0 |
| 只有 zero fill | `tafill` | 0 | 1 238 | 5 295 | 5 296 | 0 |
| 普通类构造 | `classnew` | 0 | 1 858 | 3 775 | 3 770 | 0 |

三件事同时被这张表钉死：

1. **触发条件是 backing store 出线，不是「typed array」。** `ta32` 零探针、`ta33` 一次探针，
   边界正是 `BufferPayload.inline_storage_capacity = 32`（`src/core/object.zig:468`）。
   ≤32 字节走 `installInlineByteStorage`，用的是 `reportExternalAllocUntracked`，不探针
   （`src/core/object.zig:4448`）；>32 走 `installByteStorage`，探针。
2. **和 view 无关。** `ab64`（只造 ArrayBuffer）同样付 38 943；`taview`（在已存在的 buffer 上造 view）
   零探针。
3. **和 fill、和构造器/原型/species 查找无关。** `tafill` 与 `classnew` 都是零探针，
   它们的 zjs/qjs 比值（4.28× 与 2.03×）在探针开关下纹丝不动。

**探针代价与尺寸无关**：33 到 512 字节一律 38 943–38 954 insn。这本身就是「代价在 syscall 不在数据」的
独立证据——如果差在拷贝或清零，它会随尺寸变化。

### 每次操作的分配与字节

| case | zjs glibc malloc/次 | zjs 字节/次 | qjs glibc malloc/次 | qjs 字节/次 | qjs libc memset 字节/次 |
|---|---|---|---|---|---|
| `ta32` | 1.0011 | 4 075.7 | 1.0004 | 4 073.1 | 32.1 |
| `ta64` | 1.0011 | 4 075.7 | 1.0004 | 4 073.1 | 64.1 |
| `ta512` | 2.0011 | 4 587.7 | 2.0004 | 4 593.1 | 512.1 |
| `ab64` | 0.0011 | 3.6 | 1.0004 | 4 073.1 | 64.1 |
| `taview` | 2.0011 | 8 147.7 | 0.0004 | 1.2 | 0.1 |

`ta64` 上两侧的 glibc 流量在小数点后三位内相同（那 ~4 074 字节就是 P7-00 已裁决为两侧共享的
slab arena churn）。`ab64` 一行值得单独看：**zjs 在这里一次 glibc 分配都不做**，却照样付 38 943 insn
探针，这是探针与分配器完全解耦的天然对照。

zjs 在任何尺寸上都读到 **0 次 libc `memset` 调用**——它的清零被编译成内联代码，计数器看不见。
所以 zjs 的 memset 字节数是仪器下界而不是「没有清零」，qjs 那一列才是真数（`ta64` 上 64.1 B/次，
即每次构造一次 64 字节的 libc `memset`）。这条限制在结论里没有被使用。

## 3. 关键对照：把两侧都摁在 churn ≈ 0

P7-00 建立了这个手法，也记下了它的陷阱：**恰好填满自己所有 arena 的驻留 population 会让类的
free 列表为空，于是照样 churn。** 本线撞上了这个陷阱的第二种形态——P7-00 用的 411 个驻留
**只对 zjs 有效**：

| 驻留数 K | zjs arena/次 | qjs arena/次 |
|---|---|---|
| 400 | 1.0019 | 0.0018 |
| 405 | 0.0019 | 0.0019 |
| **411**（P7-00 值） | **0.0019** | **1.0019** |
| 420 | 1.0019 | 1.0019 |
| 430 | 0.0020 | 0.0019 |
| **440**（本线取值） | **0.0020** | **0.0019** |
| 450–600 | 0.0020–0.0023 | 0.0019–0.0022 |

用 411 直接引用计时会让 qjs 侧仍在 churn，这正是 P7-00 §7 记录的「zjs 侧 typed-array A/B 被混淆」
所在的那类风险。本线改用 **K = 440**，并对**每一个** `_r` case 逐个复核：两侧都落在
0.0002–0.0005 arena 事件/次。以下数字全部在这个已验证的对照下取得。

| case（churn ≈ 0） | qjs insn | zjs insn | 探针关 insn | qjs ns | zjs ns | 探针关 ns |
|---|---|---|---|---|---|---|
| `ta0_r` | 2 397 | 3 329 | 3 329 | 97.7 | 161.9 | 162.1 |
| `ta32_r` | 2 323 | 3 468 | 3 469 | 91.8 | 161.2 | 161.0 |
| `ta33_r` | 2 323 | 48 117 | 9 080 | 91.8 | 4 112.7 | 452.1 |
| `ta64_r` | 2 322 | 48 176 | 9 135 | 93.7 | 4 196.8 | 457.4 |
| `ta512_r` | 2 579 | 49 169 | 10 128 | 100.2 | 4 108.9 | 527.3 |
| `ab32_r` | 1 730 | 2 850 | 2 851 | 72.9 | 135.9 | 136.1 |
| `ab64_r` | 1 730 | 47 553 | 8 515 | 73.6 | 4 021.5 | 427.9 |
| `taview_r` | 1 645 | 2 507 | 2 507 | 65.0 | 110.6 | 109.9 |

**分配器被完全排除。** 在 `ta64_r` 上，两侧 arena 事件都是 ~0.000x/次，而 zjs/qjs 的指令比
**从 12.75× 升到 20.75×**（时间比 26.4× → 44.8×）。也就是说，去掉 churn 让两侧都变快，但让
qjs 变快得多；差距不但没缩小，反而扩大。探针在这个对照下仍占差距的
**85.1%（指令）/ 91.3%（时间）**。

顺带记录一个未解释的次生现象：把探针关掉之后，440 个驻留对象让 **zjs 每次操作贵了约 1 800 insn**
（`ta64` 7 333 → `ta64_r` 9 135），而让 **qjs 便宜了约 1 309 insn**（3 631 → 2 322）。
这与 P7-00 §7 记录的「resident 侧 insn 更多但 cycle 更少」是同一现象的更干净版本，本线未追。

## 4. 探针内部：两半各占多少

同一把 shim 支持只拦一半。两半在本机上都不改变引擎的决策（两个 cgroup 文件不存在，
消费 rss 的闸门全关），所以两次半拦截都是保语义的。`ta64`，6 样本 ABBA 中位数：

| 配置 | insn/次 | cyc/次 | ns/次 |
|---|---|---|---|
| 探针全开 | 46 815.1 | 17 122.4 | 4 390.6 |
| 只关 `/proc/self/statm` | 25 574.7 | 8 833.2 | 2 265.1 |
| 只关两个 cgroup open | 28 590.9 | 9 151.2 | 2 346.6 |
| 全关 | 7 340.7 | 1 546.0 | 396.5 |

- `/proc/self/statm` 的 open+read+close：**21 240 insn / 8 289 cyc / 2 125.6 ns**
- 两次**必然失败**的 cgroup open：**18 224 insn / 7 971 cyc / 2 044.0 ns**
- 两半之和 39 465 insn，整体 39 474 insn，**可加性误差 0.03%**。

值得写进记录的一条：**两个从来没成功过的 open 几乎和真正读 procfs 一样贵。** 它们各自要在
`/sys/fs/cgroup` 下走一次完整的失败路径解析。任何将来处理这件事的人，如果只想着缓存 RSS
而留下 cgroup 探测，只能拿回一半。

## 5. 作用域：这不是只有微基准会碰到

`LD_PRELOAD` 计数器在整程范围内数探针次数。以下工作负载**每次操作 0 次探针**（只有 bootstrap 的 1 次）：
`noop` / `ta0` / `ta8` / `ta32` / `ab32` / `taview` / `tafill` / `classnew`、40 万次带存活尾巴的对象分配、
40 万次字符串拼接、20 万次 `JSON.parse`，以及 P7-00 留下的 `churn_object.js`、
`churn_map_callback.js`、`churn_bigint_div.js`。`pollGC` 里那条
`.allocation_slow_path / .idle / .urgent` 也会调探针（`src/core/runtime.zig:2357`），
但在试过的所有负载里都没有触发过。

Octane 派生的宏基准整程探针次数：

| bench | 探针次数（整程） |
|---|---|
| gbemu | 15 959 |
| pdfjs | 686 |
| splay | 15 |
| box2d | 9 |
| mandreel | 5 |
| navier-stokes | 4 |
| crypto | 2 |
| raytrace | 2 |

gbemu 用的是 Octane 的时间预算式 harness，指令总数不是定量工作，分数才是指标。
4 样本 ABBA、`taskset -c 19`、独占锁：

| 配置 | 分数 | 中位数 |
|---|---|---|
| 探针开 | 10 015 / 10 092 / 10 082 / 10 053 | 10 067.5 |
| 探针关 | 10 899 / 10 944 / 10 890 / 10 926 | 10 912.5 |
| qjs | 13 027 / 13 053 | 13 040 |

**关掉探针让 gbemu 分数涨 8.39%，zjs/qjs 从 0.772 到 0.837。** 这是一个真实宏基准上的位移，
不是微基准伪影。其余 Octane 项探针次数是个位到三位数，不会有可测影响。

## 6. 探针拿掉之后剩下的 2.0×：是分散的

必须明确说清楚：**探针解释的是差距的大头，不是全部。** `ta64` 上探针关闭后 zjs 仍是 qjs 的
2.02× 指令 / 2.46× 时间。这部分残差**不集中**，按阶段拆开是：

| 阶段 | zjs/qjs（探针关闭后） |
|---|---|
| 空循环 `noop` | 0.95× |
| 普通类构造 `classnew` | 2.03× |
| 只有 view 包装 + 元数据 `taview` | 2.57× |
| 只有 zero fill `tafill` | 4.28× |
| buffer + 内联 32B + fill `ab32` | 1.09× |
| buffer + 出线 64B + fill `ab64` | 1.99× |
| 全构造，内联存储 `ta32` | 1.31× |
| 全构造，出线存储 `ta64` | 2.02× |

在 zjs 内部（探针关闭）可以再切两刀：`ta64` − `ab64` = 1 620 insn 是 view 包装与视图元数据；
`ab64` − `ab32` = 2 576 insn 是把 64 字节从内联挪到出线的全部代价（分配 + external-memory token
记账，已扣掉探针）。qjs 在同一刀上是 2 867 − 2 868 = −1 insn，因为它无论多小都出线分配。
换句话说 zjs 的 ≤32 字节内联存储快路径是真便宜（`ab32` 1.09×），代价全在越过 32 字节那一刻。

一个未归因的 zjs-only 现象：`new Uint8Array(existingBuffer)` 在 zjs 上每次操作做
**2.0 次 glibc malloc、2.0 次 arena 事件**，qjs 是 0.0004。加上驻留对照后 zjs 降到 0.0013，
说明它落在没有驻留租户的尺寸类——和 P7-00 的 BigInt 实例同型。本线没有定位它。

## 7. 仪器与陷阱

- **`tools/perf/typedarray/probe_block.c`**：拦截 `openat` 与 `openat64`，对三条探针路径计数并可选地
  直接返回 `-ENOENT`（不发 syscall）。
  忠实性论证：本机两个 cgroup 文件不存在，且默认 `balanced` 模式下消费 rss/cgroup 的四道闸门全关，
  因此 `processMemoryRequest(0, 0)` 与未改动引擎得到的是**同一个决策**（不请求 GC）。
  这是「假如探针免费」的保语义对照，不是行为改动。
  **陷阱**：zjs 链接的是 glibc 的 `openat64` 而不是 `openat`（`nm -D zjs` 显示 `U openat64@GLIBC_2.17`）。
  第一版只拦 `openat`，计数器安静地读到全 0，并且第一次 A/B 计时里 `env PROBE_BLOCK_PASSIVE=`
  把空串也当成了「开」——两个错误叠加起来一度给出「拦截无效」的假结论。两处都已修正，
  报告里的每个拦截配置都带自证计数。
- **`tools/perf/typedarray/alloc_counter.c`**：malloc/calloc/realloc/free 的次数与字节，外加 libc `memset`。
  已声明的限制：只有真正走到 libc 的 `memset` 可见。
- **`tools/perf/allocator/arena_counter.c`**：直接复用 P7-00 的 arena 计数器，未修改。
- **PMU**：CPU 19 在 `armv8_pmuv3_1`。事件全部显式写在该 PMU 上，`armv8_pmuv3_0` 的
  `<not counted>` 行从不打开也从不解析。`L1-dcache-stores` 在这颗片子上是 `<not supported>`，
  而 `L1-dcache-loads` 实际别名到合并的 `l1d_cache`；读写拆分改用原始事件
  `0x40 L1D_CACHE_RD` 与 `0x41 L1D_CACHE_WR`，使用前已核对二者之和等于 `L1-dcache-loads`。
- **构建双稳态不进入本报告的任何 A/B**：探针 A/B 两侧是**同一个二进制**
  （sha256 `79000b07…`，`build.zig` 里 `zjs` 步骤硬编码 ReleaseFast），只差 `LD_PRELOAD`。
  没有任何一侧需要重新编译，所以布局彩票在结构上不可能进入。跨引擎对比（zjs vs qjs）本来就是
  两个不同二进制，与既往各线同口径。
- 所有采样样本数为偶数（矩阵 6，头条 8，gbemu 4），ABBA 平衡，取中位数。

## 8. 本线没有建立的东西

- **没有解释探针拿掉后剩下的 2.0×。** 它是分散的（见第 6 节），不构成第二个集中阶段。
- **没有解释 `taview` 上 zjs 的 2.0 次 malloc / 2.0 次 arena 事件。**
- **没有解释驻留 population 让 zjs 变贵、让 qjs 变便宜的反向效应**（探针关闭后 +1 802 vs −1 309 insn/次）。
- **没有动态测量引擎内部的对象创建数。** ReleaseFast 构建把 `--perf-json` 的 memory 计数器全报 0，
  要拿到真数就得改 `src/`，Phase 1 禁止。因此「对象创建数」一栏只有 glibc 分配次数与字节这一层
  可观测量，没有引擎内部计数。
- **没有测出 zjs 的 memset 字节数**（内联，计数器不可见）；qjs 那一列是真数。
- **没有测在 cgroup v2 真实存在的宿主上探针的代价。** 那里 `memory.max` 会打开成功并真的被读，
  代价与本机不同，方向未知。
- **没有证明 `pollGC` 那条探针路径永不触发**，只测到它在试过的所有负载里都是 0。
- **没有设计、没有提出、也没有实现任何修法。** `git diff a5bbbe52 -- src/` 为空。

## 9. 门禁与洁净性

- `git diff a5bbbe52 -- src/` 输出 0 字节 —— 全程未改生产代码。
- 未使用任何临时插桩：三把尺全部是 `LD_PRELOAD` 层的外部仪器，两个引擎共用同一把。
- 新增文件只在 `tools/perf/typedarray/`（case 生成器、三个 shim 源码、perf 驱动、计数驱动）
  与本报告目录下。`.so` 未提交。
- 全程未使用 `git stash`。
- 构建：本线未编译任何东西，使用的是 P7-00 已产出的同一个 `zig-out/bin/zjs`。
  计数运行不占锁；全部 `perf stat` 取独占锁并 `taskset -c 19`，锁窗口按批次尽量短。
