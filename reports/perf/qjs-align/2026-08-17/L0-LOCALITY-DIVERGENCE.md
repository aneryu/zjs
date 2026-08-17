# L0-LOCALITY-DIVERGENCE — 堆图局部性：malloc 分配序 vs slab 分类序

日期：2026-08-17。lane：w1:pW。**只析不改。** CPU **15**。数字 **非裁决用**。

用户改令：暂停「qjs 没有的新机制」。本尺仍是 z vs q d-side PMU；结论面改为 **忠实对齐**——若 q 堆图更局部，差在分配序（同生同放）vs 分类序（按 size class 分 arena）。问的是 **对齐 qjs 分配序是否可行、值多少**，不是发明聚簇。

| | |
|---|---|
| 五落后案 | pdfjs / EB / TS / box2d / splay（PARITY-LEDGER 五期） |
| z | `/home/aneryu/zjs/zig-out/bin/zjs` official RF（`repr=tagged`，slab） |
| q | `/home/aneryu/quickjs/qjs`（系统 malloc） |
| 尺 | `/tmp/census/det/{typescript,earley-boyer,splay,pdfjs,box2d}.js` ABBA **n=2** |
| 事件 | `armv8_pmuv3_1/{cycles,instructions,l1d_cache_refill,l2d_cache_refill,dTLB-load-misses,ll_cache_miss_rd}` |
| 补尺 | `dtlb_walk` vs `dTLB-load-misses`（n=1） |
| 原始 | `/tmp/lanes/l0-locality/{pmu.json,dtlb-walk.json}` |
| 不推翻 | **松弛定理** + slab 生态既有裁决。本文件只量化局部性差 |

---

## 0. 结论（忠实对齐）

**q 的堆图并不更局部。** 因此「对齐 qjs 分配序」**不值得做**，也 **不是** 一条能在不动 slab 生态的前提下吃 ≥30M 的忠实刀。

1. **结构差存在，税不存在。** z 按 31 个精确类把同尺寸对象放进 4KB arena；q 的 malloc 按分配时间把同生块排在一起。这是真分歧。但五落后案的 L2/LL/`dtlb_walk` **没有**显示 q 因此更贴。
2. **树图（最该暴露分类序）上 z 不散。** splay L2 MPKI 5.27→5.30（=1.00）；`dtlb_walk` **3.52M vs 3.59M（z/q=0.98）**。
3. **TS checker 图上 z 的 L2/LL 更好。** refill z/q 0.90 / 0.90。
4. **对齐分配序 ≈ 放弃「按类分 arena」。** 要同生同放，就不能把 72B Object 和 32B 字符串拆进两个 freelist。那是换分配器几何，不是在现 slab 上调参。松弛定理管的是 **bin 内就地扩**；本条管的是 **出生序 vs 类序**。两条都动 slab，本尺证明第二条没有局部性债可还。
5. **估值：~0。** 周期缺口对不上 d-side（见 §2）。pdfjs/EB/box2d/splay/TS 已各有封条。

---

## 1. 结构差（不是新机制，是两边已经在做的事）

| | qjs malloc | zjs slab（`memory.zig` `SmallObjectSlab`） |
|---|---|---|
| 键 | **时间**：brk/mmap 上连续 carve，同生块地址相邻 | **尺寸**：16–512 共 31 类，每类自己的 4KB arena + freelist |
| 同生同放 | 一次 `new Pair; new Pair` 倾向落在邻近 | 仅当两块 **同一 size class** 且从同一 arena 弹出 |
| 同生不同类 | 仍可能相邻（malloc 不看尺寸） | **必分家**（Object 一 arena，短 String 另一 arena） |
| 回收后再分配 | libc 可能立刻把刚 free 的洞给下一次（仍近） | 进该类 freelist，下一次同类弹出；**跨类不共享洞** |
| 就地扩 | malloc bin 松弛，小涨可留在原地 | 精确类，涨一档就换块（**松弛定理**：不可移植） |

忠实问题不是「再发明一种聚簇」，而是：要不要让 z 的 **第一次放置** 跟 q 一样按出生序走。

---

## 2. d-side 全套（税存不存在）

判据：堆图更散会漏到 **L2 / LLC / `dtlb_walk`**。L1D 多摸、L2 更好 = 解释器多碰线，不是对象跨页。`dTLB-load-misses` 大比值多半是 L1→L2 TLB，要用 walk 校准。

| 案 | cyc z/q | insn z/q | L1D refill（MPKI z/q） | L2D refill（MPKI z/q） | dTLB-lm z/q | LL miss rd z/q | 读 |
|---|---:|---:|---:|---:|---:|---:|---|
| **TS** | 1.040 | 1.042 | 1.060（**1.017**） | **0.896（0.860）** | 1.113 | **0.897** | q **不**更贴；z L2/LL 更好 |
| **EB** | 1.240 | 1.141 | 1.429（1.253） | **0.945（0.829）** | 1.829 | 1.747 | L1D 多、L2 更好。AST 不在 DRAM 散 |
| **splay** | 1.039 | 1.044 | 1.121（1.074） | **1.050（1.006）** | 1.136 | 1.243 | 分类序最该输的树：L2 持平 |
| **pdfjs** | 1.245 | 1.074 | 1.318（1.228） | 1.136（1.058） | 2.302 | 1.638 | L2 几乎平；缺口是壳 |
| **box2d** | 1.036 | **0.962** | 1.190（1.237） | 1.365（1.420） | 1.701 | 2.846 | insn 更少；BIN-IPC。LL Δ 0.23M |

`dtlb_walk`（真 page walk）：

| 案 | q | z | z/q |
|---|---:|---:|---:|
| EB | 1.04M | 1.32M | 1.27 |
| pdfjs | 85k | 148k | 1.74 |
| box2d | 7.6k | 18k | 2.39（绝对量可忽略） |
| **splay** | 3.59M | **3.52M** | **0.98** |

周期缺口能被 d-side 解释的上限（L1D 补 L2≈10 cyc，L2≈25，LL≈150，walk≈80）相对缺口：TS **对不上**（L2/LL 还在帮 z）；EB 最多贴 ~26% 且 L2 帮 z；splay 纸面能贴但 L2 MPKI=1、walk 更少；pdfjs **&lt;10%**；box2d 与 BIN-IPC 同向。

**结论：q 堆图没有可度量的局部性优势。** 不做 GDB 指针取样（没有「q 更近」的税可定位）。

绝对量与分见 `/tmp/lanes/l0-locality/pmu.json`。

---

## 3. 「对齐 qjs 分配序」可不可行、值多少

### 若要字面对齐（同生同放）

必须让 **不同 size class 的第一次放置** 落在相邻地址。现 slab 做不到：弹出点在各类自己的 arena。可行形只有：

| 形 | 是不是「对齐 q」 | 动不动 slab 生态 |
|---|---|---|
| 首次分配走一条 bump/混类 arena，free 仍回各类 freelist | 出生序像 malloc | **是**（第二套放置几何；reuse 仍按类，活图会逐渐类化） |
| 整段改成 libc malloc | 最像 q | **推翻 slab**（旧裁决） |
| 只把「常一起摸」的两三个类绑同一 arena | 近似同生 | 新分类器，且本尺显示绑了也没税可灭 |
| 类内按分配时间排序 freelist | 只整理同类 | 不解决跨类分家；splay 节点本就同类 |

字面同生同放 **不可在「不动 slab 生态」下做完**。能做的子集（类内排序）打不中跨类分家，而跨类分家才是和 malloc 的真正分歧。

### 值多少

本尺：**~0 cyc。** 最敏感的三张图：

- splay 树：walk z≤q，L2 MPKI 持平 → 分类序没有让树更散
- TS checker：L2/LL z 更好
- EB AST：多的是 L1D、少的是 L2 → 不是节点跨页

没有 ≥30M 的「对齐分配序」忠实刀。

### 松弛定理边界（不推翻）

| | 松弛定理 | 本条 |
|---|---|---|
| 对象 | **已有块就地变大**（malloc bin slack） | **第一落点按时间还是按类** |
| 既有裁决 | slab 精确类，不可移植 bin 就地扩 | **维持** |
| 本尺 | 不重开 P6-B | 只说：分类序相对分配序 **没有** 可度量的局部性债 |

两件事都碰 slab，但债不同。本尺证明分配序债不成立；就地扩的债仍按松弛定理封死。

---

## 4. 封条

**L0 局部性分歧：有结构差、无对齐价值。**

- 不立项「对齐 malloc 分配序」。
- 不立项生命期分区 / 按位点分 slab（那是已暂停的新机制面）。
- 不重开松弛定理。
- 五落后项继续走各自封条（壳 / L1I / call-return / BIN-IPC / ⑦）。

---

## References

- `src/core/memory.zig` `SmallObjectSlab`（4KB arena，31 类，≤512B）
- PARITY-LEDGER：松弛定理；五期五落后；七期改令前的分层（本文件按改令改结论面）
- `/tmp/lanes/l0-locality/pmu.json`、`dtlb-walk.json`
