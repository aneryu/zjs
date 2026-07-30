# P7-00：SmallObjectSlab arena churn 的泛化性裁决

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码
- 起点：`perf/qjs-align-p7-allocator` @ `a5bbbe52`
- 对照引擎：pinned Bellard QuickJS `04be2460`
- 数据产物：`P7-00-results.json`

## 裁决

> **does not generalise → permanently close**

裁决的确切含义需要写清楚，因为证据是双面的：

- churn 这个**现象**确实会泛化 —— 任何落在「free-arena 列表为空的尺寸类」里的短命分配都会 churn，与 BigInt 无关。
- 但它**同等地泛化到 qjs**。两侧的策略、常量、类映射与后端分配器逐项相同，实测 qjs 的 churn 率与 zjs 相同或更高。
- 因此它**不作为 zjs-vs-qjs 的对齐缺陷泛化**，不授权任何 allocator 层的生产改动线（P7-01 不开）。

唯一真实的 zjs-only 实例是 BigInt 除法，其成因是 scratch 落在了一个没有驻留租户的尺寸类，属于 BigInt 代码的分配拓扑，不是 allocator 层的缺陷。该项的代价已被量化（见第 5 节），按既定边界**未**处理，交由用户裁量。

## 1. 机制：两侧逐项相同

先用代码而不是计时确定机制。

| 项 | qjs | zjs |
|---|---|---|
| arena 大小 | 4096（`quickjs.c:244`） | 4096（`memory.zig` `arena_size`） |
| arena 头 | 40 B | 40 B |
| block 头 | 8 B（源码注释 `/* 8 byte header */`） | 8 B（`alignForward(@sizeOf(BlockHeader)=3, 8)`） |
| 小块上限 | 512 | 512 |
| `block_sizes` 表 | 31 项 | 逐字节相同（comptime 交叉校验） |
| 类映射 | `alignUp(size,8) + sizeof(header)` | `alignForward(size,8) + block_header_size` |
| 每 arena 块数 | `(4096-40)/block_size` | 同式 |
| 空 arena 释放 | `quickjs.c:1626-1630`，`n_used_blocks` 归零即 `list_del` ×2 + `js_free(ar)` | `memory.zig:190-204`，`used_blocks` 归零即 `releaseEmptyArena` |
| 后端分配器 | `js_def_malloc` → glibc `malloc` | `init.gpa` → `std.heap.c_allocator` → glibc `malloc` |

两处需要单独确认的地方：

- **qjs 的 slab 在基准构建里是启用的。** `JS_MALLOC_LARGE_BLOCKS_ONLY` 在源码里出现两次，但取 1 只发生在 `__SANITIZE_ADDRESS__` 下；基准用的是 `-O2 -DNDEBUG`，无 ASAN，所以取 0，slab 生效。若不确认这一条，整份对比都会建立在「qjs 根本不走 slab」的错误前提上。
- **zjs 的后端确实是 glibc。** `init.gpa` 是 Zig 0.16 的隐式程序初始化模块（`std/start.zig:704-713`）：链接 libc 时 `use_debug_allocator` 为假，选中 `std.heap.c_allocator`。`build.zig` 全线 `link_libc = true`，`ldd` 也确认二进制链接 `libc.so.6`。

顺带一个与直觉相反的细节：**zjs 的 arena 构造比 qjs 便宜**。qjs 每个块写两次（`free_next` 与 `block_size_idx`），zjs 只写一次，因为 `block_size_idx` 改在 pop 时打戳。所以即便 churn 次数相同，zjs 的单次 arena 构造成本也不高于 qjs。

## 2. 触发条件：原始表述需要修正

立项时的表述是「slab 在一个尺寸类清空时立刻把 arena 还给后端」。按代码，准确表述是：

> **释放发生在单个 arena 的 `used_blocks` 归零时**（不是整个尺寸类清空）；而 churn 发生在**下一次分配时该类的 free-arena 列表为空**。

这个区别不是措辞问题，它有可观测后果：**一个恰好填满自己所有 arena 的驻留population 会让 free 列表为空，于是照样 churn。** 这一点是实测撞出来的：第一版对照保留 400 个同尺寸对象，类的每 arena 容量恰好是 50，400 = 8×50 正好填满 8 个 arena，对照仍然以 1.0004/次 churn；改成 411 之后降到 0.0004/次。这条已写进结论，因为任何后续设计若假设「有驻留就不会 churn」都会错。

## 3. 现象泛化，但两侧同等

用一个 `LD_PRELOAD` 计数器同时量两侧：两个引擎的 arena 取还都走 glibc，且 arena 分配尺寸在两侧由同一公式 `40 + floor(4056/block_size)*block_size` 决定，恰好只有 12 个取值（3624–4096）。统计这 12 个尺寸的 `malloc` 即等价于统计 arena 创建，**对两个引擎用的是同一把尺，且不需要改任何一侧的源码**。计数器会输出完整直方图，所以「某个载荷分配恰好撞上这 12 个尺寸」这种污染是可见的，而不是被假设掉。

短命 `Uint8Array(k)` 扫描，每尺寸 2000 次，扣除空脚本基线（qjs 38 / zjs 32）：

| 载荷 | qjs 次/迭代 | zjs 次/迭代 |
|---|---|---|
| 8 | 2.0030 | 1.0015 |
| 16–64 | 1.0030 | 1.0015 |
| 72 | 2.0030 | 2.0015 |
| 80 | 1.0030 | 2.0015 |
| 96–480 | 1.0030 | 1.0015–2.0015 |

21 个尺寸全部 churn，**两侧都 churn**；qjs 在多数尺寸上略高，在 8 字节上是 zjs 的两倍。这就是「现象泛化但不构成对齐缺陷」的直接证据。

而普通对象分配在两侧都**不** churn：

| case | 迭代 | qjs 净事件 | zjs 净事件 |
|---|---|---|---|
| `churn_object`（每轮一个 `{a,b}`） | 200 000 | 8 | 3 |
| `churn_map_callback` | 10 000 | 5 | 10 |
| `churn_bigint_div` | 2 000 | 9 | **2007** |

原因是 bootstrap 在那些尺寸类里留下了驻留块，arena 永远不归零。

## 4. 一个被推翻的假设

立项时我把 P7-20 的 Pareto 第一名 `array_map_callback`（10 000 次 `a.map(x => x + 1)`，10 000 个短命结果数组）作为「churn 若泛化，应在此显形」的待验假设交给本条线。

**该假设被推翻。** 实测 10 000 次 map 只产生 10 个净 arena 事件（zjs 0.0010/次，qjs 0.0005/次）。它的 2.618 比值与 allocator churn 无关，归因仍然悬空，退回 array 或 call 线。

## 5. 唯一的 zjs-only 实例：BigInt 除法

zjs 每次除法恰好 1.0002 个 arena 事件，qjs 0.0002。定位到 arena 尺寸 **4040**，即 **80 字节块类**，2002 次分配 / 2002 次释放对应 2000 次除法。

对上源码即为 `src/libs/bigint.zig:742`：

```zig
const u = try allocator.alloc(Limb, na + 1);
```

`na = 8` 时是 9 个 limb = 72 B 载荷，加 8 B 块头 = 80 B，正落在 80 字节类，而该类在 zjs 里没有任何驻留租户。同一函数的另外两个分配不 churn：`v`（`nb` = 4 limb → 40 B 类）与 `q`（`quotient_len` = 5 limb → 48 B 类）都落在有驻留的类里。这解释了为什么速率恰好是 1.0 而不是 3.0。

qjs 的对应缓冲是 `js_bigint_divrem` 里的 `r = js_bigint_new(ctx, na + 2)`，10 个 limb 加 8 B `JSBigInt` 头 = 88 B 载荷 → 96 字节类，而该类在 qjs 里是有驻留的。**两侧都做了同样多的临时分配（qjs 实际是 3 分配 2 释放），差别只在落进了哪个类。**

### 原位对照与代价

不改除法一行代码，只在 JS 层保留 411 个 `Uint8Array(72)`（这是唯一能从 JS 触及 80 字节类的形状；411 刻意不是每 arena 50 块的整数倍），churn 即消失：

| | 除法前 | 除法后 |
|---|---|---|
| zjs 事件/除法 | 1.0002 | 0.0004 |
| qjs 事件/除法 | 0.0002 | 0.0005 |

两侧输出逐字节一致。计时用 8 样本、ABBA 平衡、`taskset -c 19`、独占主机锁，取中位数（200 000 次除法）：

| 引擎 | case | insn/除法 | cyc/除法 | ns/除法 |
|---|---|---|---|---|
| qjs | `bigint_div_long` | 1654.8 | 347.4 | 89.1 |
| qjs | `bigint_div_resident` | 1663.0 | 349.7 | 89.7 |
| zjs | `bigint_div_long` | 3259.9 | 721.6 | 185.1 |
| zjs | `bigint_div_resident` | 2426.3 | 574.5 | 147.3 |

- **zjs 去掉 churn 后每次除法省 833.7 insn / 147.1 cyc / 37.7 ns。**
- qjs 侧同一 JS 改动的影响是 −8.2 insn / −0.6 ns，落在噪声内 —— 说明对照本身没有改变除法成本，省下的确实是 churn。
- zjs−qjs 每次除法差从 **96.0 ns 收到 57.6 ns**，即 **churn 占整个 BigInt 除法差距的 39.9%**。

一处必须说明的口径差异：用 typed-array 的 A/B 在 qjs 上算出的单事件成本是 1323 insn / 265 cyc / 67.9 ns，而原位 BigInt 口径是 834 insn / 147 cyc / 37.7 ns。单次事件成本依赖缓存状态，两者不冲突；**应当引用的是原位数字 37.7 ns**，前者只用于说明数量级。

## 6. 为什么裁决是「permanently close」而不是开 P7-01

三条理由，缺一不可：

1. **allocator 层没有可对齐的缺陷。** 策略、常量、类映射、每 arena 块数、后端分配器逐项与 qjs 相同，arena 构造还更便宜。任何针对 slab 的改动（例如每类保留一个 arena）都是**主动偏离 qjs**，而 `memory.zig:195-199` 已经把这个选择记成了忠实决定：保留 reserve 会让运行时逻辑字节归零后仍持有物理页。本战役的尺子是 qjs。
2. **实测两侧同等 churn**，且 qjs 在多个尺寸上更高。不存在「zjs 比 qjs 多付」的一般性事实。
3. **唯一的 zjs-only 实例在 BigInt 代码里**，不在 allocator 里。

## 7. 交出去的东西，以及本线没有做的事

**一个真实、已量化、但按边界无处可去的结果**：zjs 每次 8×4 除法为 `u = alloc(Limb, na+1)` 付 37.7 ns，占该形状 zjs−qjs 差距的 39.9%。P6-04 收口时把 `bigint_div_8x4` 的残差记为「SmallObjectSlab arena churn」，按本条线的证据这个归因**不准确**：churn 机制是两侧共享的，zjs-only 的部分是那次 scratch 分配落在了空类，属于分配拓扑。

按用户既定边界，后续项**不得重新进入 BigInt 线**，因此本条线**没有**改动 `divRemAbsNormalizedLong`，也没有提出方案。是否重开由用户裁量。若要处理，可选方向（未验证、未测量、仅供裁量）是让 `u` 与 `q` 共用一块（P6-04d2c 已因 allocator 行为被永久关闭）、或改变 `u` 的长度使其落入有驻留的类 —— 后者是靠尺寸类布局的巧合取胜，脆弱且不忠实，本线不推荐。

**本线未做**：

- 未测量 churn 在真实 Octane / microbench 负载下的总量。扫描证明了机制的普遍性，但没有回答「现实脚本里有多少分配落在空类」。
- 未解释 typed-array 工作负载上 zjs 相对 qjs 的巨大差距（`ta_churn` zjs 9336M insn vs qjs 738M insn，12.6×）。这在测量中撞见但完全不属于本线范围，且与 churn 无关（两侧 churn 次数相同）。**这是一个远大于本线全部内容的信号，应当单独立项。**
- zjs 侧的 typed-array churn/resident A/B 被混淆（resident 侧 insn 更多但 cycle 更少，符号不一致），因此本报告**不引用**任何来自该 A/B 的 zjs 单事件成本；BigInt 原位对照没有这个问题，qjs 对照证实了这一点。

## 8. 门禁与洁净性

- `git diff a5bbbe52 -- src/` 为空 —— 全程未改生产代码，也未使用临时插桩：`LD_PRELOAD` 计数器在两个引擎之外，两侧用同一把尺。
- 新增文件仅在 `tools/perf/allocator/`（计数器源码与工作负载）与本报告目录下。
- 全程未使用 `git stash`。
- 构建取共享锁，全部正式计时取独占锁并 pin CPU 19；计数运行不计时，未占用独占锁。
