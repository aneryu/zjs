# 尸体普查与 Pass-B 定价(2026-08-29)

分支 `gc/opus-corpse-census`,基线 `4c621491`。**§1–§7 只做 census 与定价,不改任何生产机制。**
§8 是快臂放宽的落地(stage-3 的分母),**§9 是 stage-3 本身的落地**——读 §5.3/§6 的形状描述前
先读 §9.1,那里记了落地形状与草图的两处偏离和推翻的两条预测。

任务来源:`docs/tracing-gc-block-drain-hot-reuse-design.md` §5 把 stage-2(私有块免 per-cell
link)标为 conditional,条件是「per-cell allocator linking 占 27.8 cycles/entry 的多少」;
本文给出该条件的答案,并把范围扩到 stage-3(尸体整体不进全局 LIFO)。

---

## 0. 结论摘要

1. **stage-2 基本不值得单独开工。** per-cell free link 写进 `cell[0..4]`,而排水为了拿
   `h.next` 必须加载 `cell[8..]`——**同一条 64 B cache line**。因此 link 写**不产生任何额外
   L2D refill**。它唯一的物理代价是把那条线写脏:实测排水占全程 L2D writeback 的 6.76%
   (8.45 M 次,**0.75 次/尸体**)。是否能兑现成 cycles 未测量,指令侧上界 ≤0.04 G。
2. **stage-3 成立,而且是排水这条线上唯一的大额可认领量**,但它有一个此前没写进设计的前置:
   **「可否位图式结算」的判定必须在 Pass A 做**(那时 line 是热的),Pass B 只结算位图。
   「跳过 park」的正确表述是**「在 Pass A 分类,只把例外 park 起来」**。
3. **stage-3 的可认领比例几乎完全取决于一个独立的小改动:把 `freeCycleDeferredStruct` 的
   trace 快臂从「class_id == 1」放宽到「标准 class 且无 inline payload」。**
   (**该改动已于同日落地,实测复现了下表右列,见 §8。**)
   同一份 census,两种口径差距是数量级的:

   | 负载 | 现行快臂(class 1)可位图结算的 block 尸体 | 放宽到标准 class 后 |
   |---|---:|---:|
   | splay | 68.34% | **99.99%** |
   | earley-boyer | 73.74% | **98.65%** |
   | raytrace | 96.83%(但整块口径 **0 个 run**) | **99.96%** |

4. **排水贵只在 splay。** Pass-B 全族 cycles 占比:splay 4.13%、EB 1.59%、raytrace 0.80%;
   每尸 L2D refill:splay **1.56**、EB 0.48、raytrace 0.16。这正是战役需要的形状——
   splay 是唯一欠账的基准。
5. 排水 0.310 G(splay,实测 3.00% × 10.336 G;设计账 0.314 G / 3.07%,已复现)当中,
   **stage-2 可认领 ≤0.04 G(且大概率 <0.02 G),stage-3 可认领 0.21 G(不放宽快臂)
   或 0.25–0.31 G(放宽快臂后)**;若连带 Pass-B 全族则上界抬到 0.427 G。

---

## 1. 方法

### 1.1 仪器

新增 `src/core/gc_corpse_census.zig`,由**编译期**开关
`-Dzjs_experimental_gc_corpse_census=true` 门控(默认 false,且只在
`-Dzjs_experimental_gc=trace_stw` 下合法)。

为什么必须是 comptime 而不是 `ZJS_GC_ARENA_AUDIT` 那样的运行期 bool:**被测量的量就是排水
循环里的每尸工作**,在那个循环里放一个运行期 flag 测试,测试本身就进了被测量的东西。

采集点在 `drainCycleDeferredFreesBudgeted` 的两个臂里,**在物理释放之前**读取每具尸体的
分类(释放后内存被 poison,读不到了)。分类不建侧表,读的都是排水本来就要碰的状态,外加
census 专用的 `Heap.censusCellFacts`(块 flags / `active[class]` / `allocated_count`)与
`classes.destructionPlan`。

### 1.2 零成本证明(开关关闭时)

同一棵源码树,`-Dzjs_experimental_gc=trace_stw`(census 关)与基线 `4c621491` 的同配置构建:

- `.text` 段大小逐字节相同:**3,447,412 B**(`.text.zjs.op_handlers` 200,720 B、
  `.rodata` 197,288 B 也相同);
- 反汇编指令多重集(归一化全部地址后)**完全相同**。

⚠️ 诚实附注:两者的**函数排布**有差异(132 个 hunk / 386 行位移),来自多出来的 build option
声明改变了匿名符号编号与布局。本仓库有 regexp 的 iTLB「布局彩票」前科(§4n),所以
「指令相同」不等于「布局相同」;**任何 cycles 裁决都必须在同一个二进制上做,不要把 census-off
构建当成基线二进制**。

### 1.3 注入验证(census 确实在被声明的构建里开火)

本仓库两次踩过「以为在跑的代码在目标构建里根本没被分析」。做法:临时给 census 的四个位置各加
一条由 `ZJS_CENSUS_INJECT=<n>` 选中的 `@panic`,一次构建、五次运行:

| 注入点 | 负载 | 结果 |
|---|---|---|
| `note()` block-cell 臂 | inj2.js | **开火** `INJECT-1: block-cell arm of note()` |
| `note()` generic prefix 臂 | inj2.js | **开火** `INJECT-2: generic prefix arm of note()` |
| `flushWord()` 全 trivial 分支 | inj2.js | **未开火** |
| `flushWord()` 全 trivial 分支 | splay.js | **开火** `INJECT-3: flushWord all-trivial branch` |
| `noteRunBoundary()` | inj2.js | **开火** `INJECT-4: noteRunBoundary` |
| 无注入(=0) | inj2.js | 正常输出 `entries_total 1588299` |

第三行是本次验证里最有价值的一格:该分支在 inj2.js 上**本来就不该开火**(该负载
`words_all_trivial = 0`),换成 splay 后立刻开火。这比「随便找个负载让 panic 响一次」更强:
它同时证明了代码被分析、被执行,**并且判据本身是有区分度的**。验证后注入代码已全部撤除
(`grep -c INJECT` = 0),最终二进制重新构建。

### 1.4 测量场

- 编译 `taskset -c 0-14`;测量前 `mpstat -P 15,16,17,18,19 1 2`,core 17 被别的 lane 占满
  (99.5% usr),15/18/19 idle ≈100%。**全部测量绑 core 18。**
- perf 事件一律匹配 `armv8_pmuv3_1/...`(小核 PMU 恒 `<not counted>`)。
- 机器上有其它 lane 活动,**wall-clock 不作任何依据**;本文所有数字都是计数类
  (census 计数、perf 事件计数、perf 事件的 per-symbol 份额)。
- 被 profile 的二进制是 **census 关闭**的 trace 构建(§1.2 证明其 `.text` 等同基线),
  census 数字来自 census 开启的构建;两者分开跑,不混用。

采集命令(可复现):

```
taskset -c 18 perf stat -e armv8_pmuv3_1/cycles/,armv8_pmuv3_1/instructions/,\
armv8_pmuv3_1/l2d_cache_refill/,armv8_pmuv3_1/l2d_cache_wb/ zjs <load>.js
taskset -c 18 perf record -e armv8_pmuv3_1/cycles/          -c 200003 -- zjs <load>.js
taskset -c 18 perf record -e armv8_pmuv3_1/l2d_cache_refill/ -c   2000 -- zjs <load>.js
taskset -c 18 perf record -e armv8_pmuv3_1/l2d_cache_wb/     -c   2000 -- zjs <load>.js
census: taskset -c 18 zjs-census --gc-stats <load>.js   # -Dzjs_experimental_gc_corpse_census=true
```

---

## 2. Pass B 实际做什么(以代码为准)

`drainCycleDeferredFreesBudgeted`(`src/core/object_gc.zig`)的 trace 臂对每具 block-cell
尸体走的链路是:

```
drain 循环
  ldr h.next                        <-- 必须读 cell+8,这一次加载就是 miss 的来源
  读 rt.gc.phase + obj 的 weak state -> 判 husk
  -> Object.freeCycleDeferredStruct                (src/core/object.zig:2451)
       class_id == class.ids.object ?
         是: (has_weak_id ? takeWeakObjectIdentity) ; destroy / destroyWithFam
         否: destructionPlan(class_id)             <-- standard_plans[id] 一次表读
             (has_weak_id ? takeWeakObjectIdentity)
             freeObjectAllocation
             releaseObjectDefinition(class_id)     <-- 标准 id 只是一次 cmp+ret
  -> MemoryAccount.destroy / destroyWithFam        (src/core/memory.zig:1271 / 1425)
       debitAlloc(logical_bytes)                   <-- 注意:普通 = @sizeOf(Object)
                                                       FAM = @sizeOf(Object)+trailing
       noteFreeDiagnostics
  -> Heap.freeSmallCell -> Heap.freeSmall          (src/core/gc_block_heap.zig:685/1665)
       readInt(u16, cell[0..2])   取 cell index
       testBitPlain / clearBitPlain(alloc bitmap)
       pushCell(block, index, cell)                <-- **stage-2 的靶子**:写 cell[0..4]
       allocated_count -= 1
       (allocated_count == 0 ? noteEmptyBlock + 进 free_blocks 生命周期)
```

`pushCell`(`gc_block_heap.zig:1965`)按块是否是 interval allocator 写两条不同的链:
`flag_interval_allocator` 时写 `next_free` 的 returned-cell LIFO,否则写 `free_list`。

### 与设计文档的差异(以代码为准)

1. **设计 §3.1 描述的「block suffix 模式」在 4c621491 上已经实现**
   (`object_gc.zig:648-670`,含 `onBlockPassBComplete` 与 run 边界的 head/count 结算)。
   设计文档读起来像未来工作,代码里已经是现状。此外还有第二个发布点
   `publishCompletedHotBlocks`(在 doomed 事务关闭时全堆扫一遍),设计文档没提。
2. **设计 §5 要求 trace-only 无 link 路线「保留 trailing-allocation byte accounting」——
   census 说明了这条为什么是承重的**:`destroyWithFam` 记 `@sizeOf(Object)+trailing`,
   `destroy` 记 `@sizeOf(Object)`,而 splay 上 **62.3% 的 block 尸体是 FAM 变体**。
   块级 `n × cell_size` 记账会静默改写 RC 分母。
   好消息:三个负载的 `runs_mixed_fam` 与 `words_mixed_fam` **全为 0**——两种逻辑尺寸
   从不共块。所以块级记账算术上成立,**但这是观测不是不变量**,stage-3 必须把它变成
   一条 checker 断言(见 §6)。
3. **设计 §2.2 预测的「generic prefix + block suffix」在 splay 上退化为纯 suffix**
   (generic = 0),而 EB 的 generic 是 **73.58 M 条 = 全部 parked entry 的 42.9%**,
   raytrace 是 2.94 M 条(6.7%)——**且全部是 `var_ref`(kind 2),不是 block cell**。
   两个 stage 都碰不到它们。这给 EB 的 stage-3 收益画了硬上限。
4. `weak_husk` 与 `weak_id` 在三个负载上**恒为 0**,block cell 的 `inline_payload` 也恒为 0
   (inline-payload class 走 `freeAlignedBytes`,根本不是 block cell)。设计 §5 把
   weak-husk 行为列为 stage-2 的义务——它在这三个负载上不花钱,但**不能因此删掉**,
   只是可以确定它不在定价里。

---

## 3. 三负载 census 表

命令见 §1.4。计数在多次运行间有 ≲0.03% 的漂移(保守栈扫描导致的存活集差异),不影响任何结论。

### 3.1 总体分布

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| parked entries 总数 | 11,312,324 | 171,648,739 | 44,176,449 |
| block cell | 11,312,324 (100%) | 98,068,425 (57.1%) | 41,238,357 (93.4%) |
| generic(非块) | 0 | 73,580,314 (42.9%) | 2,938,092 (6.6%) |
| generic 的 kind | — | 全部 `var_ref` | 全部 `var_ref` |
| drain 调用次数 | 2,781 | 34,141 | 14,031 |
| 其中被 4096 预算截断 | 2,744 | 23,867 | 10,522 |

### 3.2 block-cell 尸体:物理释放还需要什么

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| weak husk 保留(不释放 cell) | **0** | **0** | **0** |
| `has_weak_id`(需摘 side table) | **0** | **0** | **0** |
| inline payload(走 freeAlignedBytes) | **0** | **0** | **0** |
| 现行快臂命中(class_id == 1) | 7,732,269 (68.4%) | 72,979,909 (74.4%) | 39,950,791 (96.9%) |
| 走通用 class 臂 | 3,580,055 (31.6%) | 25,088,516 (25.6%) | 1,287,566 (3.1%) |
| trailing FAM(记账尺寸不同) | 7,045,479 (62.3%) | 1 | 0 |
| **写 per-cell free link** | 11,312,324 (100%) | 98,068,425 (100%) | 41,238,357 (100%) |
| ├ 写进 interval `next_free` | 10,814,573 (95.6%) | 48,615,149 (49.6%) | 12,577,729 (30.5%) |
| └ 写进 `free_list` | 497,751 (4.4%) | 49,453,276 (50.4%) | 28,660,628 (69.5%) |
| 块是 allocator-current(必须留活表示) | 1,125 (0.010%) | 1,320,514 (1.35%) | 17,551 (0.043%) |
| 该次释放使块变空 | 22 | 63,276 | 28,454 |

通用 class 臂的 class 分布:

| class | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| 2 `array` | 3,578,656 | 292,512 | 1,797 |
| 5 `string` | — | 199 | — |
| 9 `mapped_arguments` | — | 14,600,201 | 1,284,566 |
| 10 `date` | 1,397 | 2,700 | 599 |
| 13 `bytecode_function` | 2 | 10,192,904 | 2 |
| 18 `for_in_iterator` | — | — | 602 |

**全部是标准 class(id < `ids.init_count` = 69)**,没有一条动态 class。

### 3.3 「可位图式结算」的比例(stage-3 的分母)

判据(trivial)= 物理释放恰好等于 {清 alloc 位, `allocated_count -= 1`, MemoryAccount 记账}:
非 weak husk、无 weak id、走快臂(不查 class 表)、无 inline payload、块非 allocator-current。

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| trivial(现行 class-1 快臂) | 7,731,178 (68.34%) | 72,312,811 (73.74%) | 39,933,484 (96.83%) |
| **trivial_std(快臂放宽到标准 class)** | **11,311,199 (99.990%)** | **96,747,911 (98.65%)** | **41,220,806 (99.957%)** |

`trivial_std` 与 block 总数的差**恰好等于** allocator-current 计数(splay 1,125 /
EB 1,320,514 / raytrace 17,551),因为其余三个否决项都是 0。也就是说
**放宽快臂之后,唯一还挡着 stage-3 的就是「块正在被分配器用着」这一条,而它只占 0.01%–1.35%。**

### 3.4 run / word 拓扑(stage-3 的结算粒度)

一个 block 的尸体在 Pass B 里构成一段连续 run(设计 §2.2 的隐式聚簇)。

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| run 数 | 36,831 | 195,495 | 42,741 |
| 平均 run 长度 | 307 | 502 | 965 |
| run 内 cell index 非单调 | **0** | **0** | **0** |
| 相邻两 run 同块(见下注) | 14 | 2,025 | 1 |
| run 触及的 alloc 位图 word 数 | 352,098 | 2,700,536 | 658,277 |
| **entries / word 压缩比** | **32.1×** | **36.3×** | **62.6×** |
| 整 run 全 trivial(现行快臂) | 26,637 (72.3%) | 113,664 (58.1%) | **0 (0%)** |
| ↳ 覆盖的 entry | 7,060,149 (62.4%) | 52,835,558 (53.9%) | **0** |
| **整 run 全 trivial_std** | **36,806 (99.93%)** | **190,125 (97.25%)** | **42,091 (98.48%)** |
| ↳ 覆盖的 entry | 11,311,199 (99.99%) | 96,747,911 (98.65%) | 41,220,806 (99.96%) |
| ↳ 需结算的 word | 351,890 | 2,661,365 | 657,588 |
| word 全 trivial(现行快臂) | 226,605 (64.4%) | 1,846,172 (68.4%) | **4,935 (0.75%)** |
| word 全 trivial_std | 351,890 (99.94%) | 2,661,365 (98.5%) | 657,588 (99.90%) |
| `runs_mixed_fam` / `words_mixed_fam` | 0 / 0 | 0 / 0 | 0 / 0 |

注:「相邻两 run 同块」是 census 的粗判据(只比上一 run 的块基址)。它在**跨收集周期**处会
自然开火——上一周期最后一段 run 的块,被复用后成为下一周期第一段 run。splay 的 14 次对
29 次 major 是吻合的。权威判据是 `ZJS_GC_ARENA_AUDIT` 下的
`verifyDeferredFreeRunTopology`,本轮在 splay 上跑过,**绿**。

**raytrace 那一行 0 是本次 census 最重要的一格。** 它的 96.83% 尸体是 trivial,但
**没有一段 run 是整段 trivial**:run 平均 965 条,而 3.1% 的 `mapped_arguments`
均匀夹在中间(每 32 条一条,而一个 word 装 64 条),于是连 word 粒度都只有 0.75% 干净。
**「大多数尸体是 trivial」和「存在整块干净的区域」是两回事**——这正是必须按块/word 而不是按
比例定价的原因,也是「先放宽快臂」从可选优化升级为**前置条件**的原因。

---

## 4. 排水的实测成本结构

全部来自 census-off 的 trace 二进制,core 18。

### 4.1 全程计数

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| cycles | 10.336 G | 97.374 G | 48.475 G |
| instructions | 33.793 G | — | — |
| L2D refill | 246.52 M | 955.49 M | 90.31 M |
| L2D writeback | 124.95 M | 891.48 M | 78.49 M |
| IPC | 3.27 | — | — |

splay 的 10.336 G / 246.52 M 与刷新账(10.216 G / 248.59 M)一致,场没有漂。

### 4.2 per-symbol 份额

| 符号 | splay cyc% | splay L2D% | splay wb% | EB cyc% | EB L2D% | RT cyc% | RT L2D% |
|---|---:|---:|---:|---:|---:|---:|---:|
| `drainCycleDeferredFreesBudgeted` | **3.00** | **5.17** | **6.76** | 0.64 | 3.30 | 0.18 | 1.49 |
| `Object.freeCycleDeferredStruct` | 0.59 | 1.08 | — | 0.57 | 2.53 | 0.27 | 2.23 |
| `Heap.freeSmallCell` | 0.51 | 0.91 | — | 0.38 | 2.36 | 0.35 | 4.22 |
| `MemoryAccount.destroy__anon_113519` | 0.03 | ~0 | — | — | — | — | — |
| **Pass-B 全族** | **4.13** | **7.16** | — | **1.59** | **8.19** | **0.80** | **7.94** |

排水符号本身 3.00% cycles = **0.310 G**,设计账记的是 3.07% / 0.314 G——**独立复现**。

已核实 `MemoryAccount.free__anon_136990`(splay 3.46% cyc / 7.12% L2D)**不在 Pass-B 链上**:
逐条扫过 drain / `freeCycleDeferredStruct` / `freeSmallCell` / 两个 `destroy__anon` 的全部
`bl`/`b` 目标,没有一条指向它(Pass B 只释放整 cell,从不释放 slice)。它属于 Pass A 的
属性/Shape 拆解。

### 4.3 每尸单价

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| parked entries | 11.31 M | 171.65 M | 44.18 M |
| Pass-B 全族 cycles | 0.427 G | 1.548 G | 0.388 G |
| **cycles / entry** | **37.7** | **9.0** | **8.8** |
| Pass-B 全族 L2D refill | 17.65 M | 78.26 M | 7.17 M |
| **L2D refill / entry** | **1.56** | 0.46 | 0.16 |
| 排水符号单独 refill/entry | **1.13** | — | — |
| 排水符号 L2D writeback/entry | **0.75** | — | — |

### 4.4 这回答了设计 §2.3 的未决问题

设计文档写:「刷新的 `perf record` 采的是 cycles 不是 per-symbol L2D refill,所以本设计不
制造一个未采样的份额」,并列了两个**情景**:全程 refill 强度下 0.675 次/尸体;
「每尸一条冷 header line」情景下 11.31 M 次 = 全程的 4.55%。

**实测:排水符号 5.17% = 12.74 M 次 = 1.13 次/尸体;Pass-B 全族 7.16% = 17.65 M = 1.56 次/尸体。**

也就是说现实落在**「每尸至少一条冷线」情景之上**,而不是全程强度情景。
**排水的成本就是「第二次冷触碰每一具尸体」。** Pass A 已经碰过一次(`destroyFromHeader`),
到 Pass B 时那条线已经被挤出去了,LIFO 指针追逐把它再拉一次。

排水符号 0.310 G / 12.74 M refill ≈ 24.4 cycles / refill;以 37.7 cyc/entry 对 1.56
refill/entry 算 24.2 cyc/refill。**两个口径互相闭合,说明排水的 cycles 基本被它自己的
cache refill 解释完了**,不是指令堆积。

⚠️ **一个被丢弃的数字**:`perf record -e instructions` 给排水符号 2.04%(= 61 insn/entry),
但反汇编数出来循环体只有约 16 条(排水符号内),全链路约 70 条。固定周期的 instructions
采样在长延迟 load 后有系统性 skid,**per-symbol 指令份额在这个 stall 密集的循环上不可用**。
本文的定价不使用它;需要指令口径时用反汇编静态计数,并明确标注为结构估计。

---

## 5. 定价

### 5.1 stage-2:私有块免 per-cell link

**可认领量:0.310 G 中的 ≤0.04 G,现实预期 <0.02 G。判定:不值得单独开工。**

理由,按证据强度:

1. **零 refill 收益(实测支撑)。** `pushCell` 写 `cell[0..4]`;排水为了拿 `h.next` 必须读
   `cell[8..16]`;`freeSmallCell` 为了拿 index 必须读 `cell[0..2]`。cell 对齐 ≥16 B,
   三者恒在同一条 64 B line。**这条线的 miss 是排水存在就要付的,不是 link 写引起的。**
   实测 1.13 refill/entry 全部记在排水的取指针上。
2. **指令收益很小,而且在 miss 阴影里。** `pushCell` 展开约 6 条指令(读 `block.flags`、
   一次分支、读旧头、一次 OR、一次 4 B store、一次写回头)。全链路约 70 条,占比 8.6%;
   而排水的 IPC 约 0.6(0.310 G cycles / ~0.19 G 真实指令),删掉与未命中重叠的指令
   收益低于比例。上界 0.310 G × 6/70 = **0.027 G**。
3. **唯一真实的物理效果是脏线。** 排水占全程 L2D writeback 的 6.76%(8.45 M 次,
   0.75 次/尸体 ≈ 540 MB/run)。Pass B 对尸体 cell 的**唯一**写就是这条 link,所以这部分
   写回流量本质上是它的。**能否兑现成 cycles 未测量**——写回通常是 posted、不在关键路径上,
   但它确实占用带宽,而并行 marker 与之竞争。**这是 SCENARIO,不是 MEASUREMENT。**
4. **副产物(实测):splay 上 95.6% 的 link 写是可证明的死存储。** 它们写进
   `flag_interval_allocator` 块的 `next_free` returned-cell 链,而 `openBlock` 调
   `rebuildFreeIntervals` 时把 `next_free` 直接重置为 `free_nil` 并从 alloc 位图重建。
   写了从来不读。EB 是 49.6%、raytrace 是 30.5%。
   **这让 stage-2 在「正确性/整洁度」上有理由,但不改变它的 cycles 定价。**

**建议**:stage-2 不作为独立候选。它应当作为 stage-3 的**内含结果**落地——位图式结算里
根本不存在 per-cell link 这个动作。若 owner 仍想单独验证「写回流量」这一条,验收口径必须是
`l2d_cache_wb` + cycles 的配对 A/B,不能用指令数。

### 5.2 stage-3:trivially-freeable 的尸体不进全局 LIFO

**可认领量(splay):不放宽快臂 0.21 G;放宽快臂后 0.25–0.31 G(排水符号口径),
上界 0.427 G(Pass-B 全族口径)。占 2.949 G 总缺口的 7%–10.5%(全族口径 14.5%)。**

算法:

| 项 | 值 | 类型 |
|---|---:|---|
| 排水符号 cycles(splay) | 0.310 G | MEASURED |
| 可位图结算比例(现行快臂) | 68.34% | MEASURED |
| 可位图结算比例(放宽快臂) | 99.99% | MEASURED |
| 结算成本:352 K 个 word RMW,全在块 header 页(热) | ≲0.005 G | SCENARIO(静态估计) |
| 残留:1,125 条 allocator-current 尸体仍走 LIFO | ≲0.001 G | MEASURED 计数 × 单价 |
| **净可认领(放宽快臂)** | **0.30 G ± 0.05** | **SCENARIO**(见下三条折扣) |

三条折扣,必须在裁决前说清楚:

1. **不是全部 cycles 都能回收。** 排水以 IPC≈0.6 跑,说明有部分未命中被重叠。删掉整个
   循环后,那些原本被重叠的工作不会凭空产生收益。范围下沿取 0.25 G。
2. **Pass A 仍然要碰每一具尸体。** stage-3 删掉的是**第二次**触碰。第一次(destroyFromHeader)
   不动,所以 §4.3 里的「Pass-B 全族」并不是全部可认领——`freeCycleDeferredStruct` 与
   `freeSmallCell` 的部分工作(记账、位图)只是**搬到 Pass A / 块结算**,不是消失。
   稳妥口径用排水符号的 0.310 G,不用 0.427 G。
3. **EB 有硬上限。** EB 的 42.9% parked entry 是 `var_ref`,不是 block cell,stage-3
   一条都碰不到;而且 EB 的 Pass-B 全族本来就只占 1.59% cycles。**stage-3 在 EB 上
   最多值 ~0.9% 的 cycles,raytrace 上 ~0.6%。** 它是一把 splay 专用刀——恰好是战役需要的。

### 5.3 前置条件(设计文档没有的部分)

**stage-3 不是「跳过 park」,是「在 Pass A 分类,只 park 例外」。**

理由是 census 逼出来的:判断一具尸体是否可位图结算,需要读它的 `class_id`、`has_weak_id`、
`weakReferenceCount`——**这些都在尸体自己的 cache line 上**。如果在 Pass B 判,就得把线拉进来,
那正是要省掉的那次 miss;stage-3 就自我抵消了。
而 **Pass A 刚刚跑完 `destroyFromHeader`,那条线是热的**,在那里分类边际成本≈0。

由此得到的实现形状(**草图,不是决定**):

- Pass A 的 `takeDoomedCell` 目前把 remember 位清零。改为:**可位图结算的尸体保留它的位,
  只有需要 park 的例外才清位并 push**。剩下的置位集天然就是「按位图结算」的掩码,零额外存储。
- ⚠️ 但 `hasPendingDoomed()` 目前正是读这张 remember 位图,且
  `onBlockPassBComplete` / `publishHotBlock` / `rebuildFreeIntervals` 都断言它为空。
  改语义会同时改这四处的含义,**需要第二个位图字或一次显式的语义重命名**,不能就地重载。
- **必须先放宽快臂**(§5.4),否则 raytrace 的整块可用率是 0、splay 只有 68%。
- 块级 MemoryAccount 记账要求块内逻辑尺寸一致。census 说三个负载上
  `runs_mixed_fam = words_mixed_fam = 0`,**但这是观测**;stage-3 必须把它变成 arena
  checker 的第 11 条:*一个 block 的全部 cell 逻辑记账尺寸相同*。
- allocator-current 块(0.01%–1.35%)继续走现行 LIFO 路线,设计 §5 的这条限制成立且便宜。

### 5.4 独立的小前置:放宽 trace 快臂

`Object.freeCycleDeferredStruct`(`object.zig:2458-2471`)的 trace 快臂只覆盖
`class_id == class.ids.object`。census 显示落在通用臂的**全部**是标准 class,而对标准 id:

- `Table.destructionPlan` 就是一次 `standard_plans[id]` 表读(`class.zig:534`);
- `Table.releaseObjectDefinition` 对 `id < ids.init_count` 是**一次 cmp + ret**(`class.zig:544`)。

也就是说通用臂本身并不贵——**它的代价不在指令,而在「它让尸体不可位图结算」**:
raytrace 3.1% 的 `mapped_arguments` 把整块可用率从 ~97% 打到 **0**。

放宽后需要携带的条件:`inline_payload_size == 0`(census 实测 block cell 恒满足)与
trailing-FAM 的正确记账尺寸。**这是一把独立的、可单独测试的小刀,并且它是 stage-3 的分母。**

---

## 6. 建议

按优先级:

1. ~~**先做「放宽快臂」**(§5.4)。小、独立、可单独 A/B、并且是 stage-3 的前提。它本身的
   cycles 收益预期接近 0(通用臂就几条指令),所以**验收口径应当是「不回归」+「census 的
   `trivial_std` 变成 `trivial`」**,不要指望它单独出数。~~ **已落地,见 §8。**
   验收如预期:`trivial` 三负载收敛到原 `trivial_std`,指令数 ±0.13% 无信号。
2. ~~**stage-3 GO(建议开工),但按 §5.3 的形状**:Pass A 分类、Pass B 只结算位图、例外仍
   park、allocator-current 块不参与、加第 11 条 checker(块内逻辑尺寸一致)。
   预期 splay −0.25~0.31 G(cycle ratio 1.4058 → 约 1.37),EB/raytrace ≲1%。
   验收必须是安静窗口的 cycles + L2D refill 配对 A/B;**指令数会上升**(块级结算多了位图
   循环),按 §4n 的纪律这不构成否决。~~ **已落地,见 §9。**
   ⚠️ 两处预测被落地推翻:落地形状是「Pass A 分类**并就地结算**」而不是「Pass B 结算位图」
   (§9.1),因此**没有**块级位图循环,**指令数三负载全部下降**(splay −1.31%,§9.5);
   第 11 条 checker(块内逻辑尺寸一致)**不需要了**——逐尸结算按尸体自己的逻辑尺寸记账,
   块内是否混 FAM 不进入正确性。cycles/L2D 仍归 driver 的安静窗口。
3. **stage-2 NO-GO 作为独立候选**,理由见 §5.1;它在 stage-3 里自动消失。
   若 owner 想保留一条「写回流量」的独立实验臂,口径写死为 `l2d_cache_wb`。
4. **EB 的下一个靶不在这条线上**:它 42.9% 的 parked entry 是 `var_ref`,Pass-B 全族只占
   1.59% cycles。谁要动 EB 的 Pass B,靶子是 `var_ref` 的 park 本身,不是块排水。

## 7. 保留物

- `src/core/gc_corpse_census.zig` — census 模块,默认编译期擦除。
- `-Dzjs_experimental_gc_corpse_census`(build.zig / build/config.zig),仅在
  `-Dzjs_experimental_gc=trace_stw` 下合法。
- `Heap.censusCellFacts`(`gc_block_heap.zig`)— census 专用只读取值器。
- `object_gc.censusNoteParked` — 分类点,`if (comptime !corpse_census.enabled) return` 开头。
- `--gc-stats` 末尾的 `gc-census:` 报表。

门禁:

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `zig build test` | **2380 passed / 0 failed** |
| trace 单测 | `zig build test -Dzjs_experimental_gc=trace_stw` | **2455 passed / 0 failed** |
| trace + census 单测 | 同上 `-Dzjs_experimental_gc_corpse_census=true` | **2455 passed / 0 failed** |

⚠️ 两点记录:
- `-Dzjs_gc=trace_stw` 会被 build.zig 显式拒绝(它要求走
  `-Dzjs_experimental_gc=trace_stw`),本轮用的是后者。
- 新建 worktree 的 `test262` 子模块是空的,会让两个 `cli.run_test262` 测试以
  `FileNotFound` 失败。**已确认基线 `4c621491` 在同一空 worktree 里失败完全相同的两条**,
  是环境不是代码;测量时把该目录指向已 checkout 的副本后两门全绿。

---

## 8. 快臂放宽已落地(2026-08-29,分支 `gc/opus-fastarm`,基线 `4ac3253f`)

§6 建议 1 已执行。这是 stage-3 的前置,**不是**一把出 cycles 的刀。

### 8.1 改了什么

`Object.freeCycleDeferredStruct`(`src/core/object.zig`)的 trace-only 快臂判据从
`class_id == class.ids.object` 改为新的 `Object.passBFastArmEligible`:

```zig
pub inline fn passBFastArmEligible(rt: *const JSRuntime, class_id: class.ClassId) bool {
    if (class_id == class.ids.object) return true;
    if (class_id >= class.ids.init_count) return false;
    return rt.classes.standardPlan(class_id).inline_payload_size == 0;
}
```

三行分别对应三件被核实过的事:

1. **class 1 保持零读。** `Object` 由 `Table.init` 注册一次,`registerAtom` 对已注册 id 返回
   `DuplicateClass`,`unregisterDynamicOwned` 又拒绝 `id < init_count`——所以它的
   `inline_payload_size == 0` 是封闭的,不需要查表。raytrace 96.9% 的块尸体走这条,**它的
   指令序列一条没变**。
2. **动态 id(≥ 69)仍走通用臂。** 它们持有 definition pin,`releaseObjectDefinition` 必须把
   `live_object_pins` 减掉。这条是**载重的**,见 §8.4 的注入 3。
3. **其余标准 id 读一次 `standard_plans[id]`,检查无 inline payload。**
   ⚠️ 这一条是 census 没覆盖到的一个真实缺口:**`standard_classes` 只登记到
   `ids.generator`(49),id 50–68(proxy / promise / async_* / weak_ref /
   finalization_registry / dom_exception / call_site / raw_json / std_file /
   disposable_stack / global_object)在表里是「未注册的标准 id」**,`Table.register` 对它们
   **不会**返回 `DuplicateClass`。也就是说嵌入方原则上可以把一个带 inline payload 的定义注册
   到标准 id 上,而 inline payload 对象的分配基址在 Object **之前**——纯按 `class_id <
   init_count` 判定的快臂会拿错地址调 `destroy`。所以判据保留了这次表读。
   **这次表读不是新增成本**:它正是下面通用臂本来就要做的那次 `destructionPlan`;
   放宽后这些 id 反而少了 `destructionPlan` 的空值/范围分支和 `releaseObjectDefinition`
   调用,**指令严格更少**。

**FAM 记账保真**:快臂体是 `freeObjectAllocation` 去掉 inline-payload 分支后的逐字副本——
`hasTrailingPropertyAllocation()` 为真时仍走 `destroyWithFam(Object, self,
trailing_property_bytes)`,记 `@sizeOf(Object)+trailing`,为假时 `destroy(Object, self)`。
splay 62.3% 的尸体带 FAM,记账字节数一字未动(census 的 `trailing_fam` 计数前后一致:
7,043,715 → 7,043,589,差值在 ≲0.03% 的存活集漂移内)。

配套改动:
- `object_gc.censusNoteParked` 的 `fast_class` 改为**调用 `passBFastArmEligible` 本身**,
  而不是复述判据。于是 `block_trivial`(按真实分支)与 `block_trivial_std`(按
  「标准 class 且无 inline payload」独立复述)成为**互相校验的两个口径**,不再是
  「现状 vs 假设」。
- `.remove_cycles` 的排除保持原样:快臂整体在 `if (comptime gc.trace_stw_enabled)` 里,
  rc 构建根本不生成它(见 §8.5 的逐字节证据)。Pass A 的
  `destroyFromHeader` 快臂(`object.zig:2187`,带 `phase != .remove_cycles`)**一字未动**——
  那是另一件事(它跳过的是 payload 拆解,不能按 class 放宽)。

### 8.2 census 前后对比

同一台机、core 18、`-Dzjs_experimental_gc_corpse_census=true` 的 ReleaseFast 构建,
命令同 §1.4。base = `4ac3253f`,new = 本改动。

| 负载 | 口径 | block 尸体 | trivial | 整 run 全 trivial | trivial run 覆盖的 entry | word 全 trivial |
|---|---|---:|---:|---:|---:|---:|
| splay | base | 11,309,495 | 7,729,235 (**68.34%**) | 26,625/36,837 (72.28%) | 62.41% | 226,445/352,015 (64.33%) |
| splay | **new** | 11,309,293 | 11,308,224 (**99.99%**) | 36,818/36,843 (**99.93%**) | **99.99%** | 351,627/351,826 (**99.94%**) |
| earley-boyer | base | 98,085,467 | 72,310,295 (**73.72%**) | 113,954/195,879 (58.18%) | 53.83% | 1,850,154/2,705,503 (68.38%) |
| earley-boyer | **new** | 98,092,651 | 96,749,501 (**98.63%**) | 190,723/196,085 (**97.27%**) | **98.63%** | 2,668,964/2,708,795 (**98.53%**) |
| raytrace | base | 41,238,357 | 39,933,481 (**96.84%**) | **0/42,741 (0%)** | **0%** | 4,939/658,277 (**0.75%**) |
| raytrace | **new** | 41,238,357 | 41,220,803 (**99.96%**) | 42,091/42,741 (**98.48%**) | **99.96%** | 657,589/658,277 (**99.90%**) |

三条判定:

1. **`block_generic_class` 三个负载全部归零。** 每一具块尸体现在都走快臂——这直接证明
   census §3.2 的「落进通用臂的全部是标准 class」在放宽后不留残余。
2. **`trivial == trivial_std`,三个负载逐条相等。** 两个独立口径合流,是「判据覆盖了它声称
   覆盖的集合」的证据,不是同义反复(一个来自代码分支,一个来自 census 自己的公式)。
3. **命中 §3.3 的预测。** 预测 splay 99.990% / EB 98.65% / raytrace 99.957%,
   实测 99.99% / 98.63% / 99.96%,差值在计数漂移内。raytrace 的整 run 干净率
   **0% → 98.48%**,§3.4 标为「本次 census 最重要的一格」的那格已经翻过来。

剩下的 0.01%–1.37% 全部是 `block_allocator_current`(splay 1,069 / EB 1,343,150 /
raytrace 17,554),与 §3.3 的结论一致:**放宽之后唯一还挡着 stage-3 的就是「块正在被分配器
用着」**。

### 8.3 门禁与 A/B

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `zig build test` | **2380 passed / 93 skipped / 0 failed** |
| trace 单测 | `zig build test -Dzjs_experimental_gc=trace_stw` | **2455 passed / 19 skipped / 0 failed** |
| trace + census 单测 | 同上 `-Dzjs_experimental_gc_corpse_census=true` | **2455 passed / 19 skipped / 0 failed** |
| fixed-work smoke | `tools/perf/gate_smoke.sh <trace bin> /tmp/gcgap-fixed 18 3` | **all clean**(6 负载 × 3 普通 + 1 arena-audit) |

⚠️ `gate_smoke.sh` 是**只对 trace 构建成立的门**:它要求 `--gc-stats` 里恰好一行
retirement,rc 构建没有。**基线 rc 二进制在同一条命令下失败完全相同的一条**
(`deltablue: expected exactly one retirement line, found 0`),是门的适用范围不是回归。

指令数 A/B(core 18,`armv8_pmuv3_1/instructions`,三轮 base/new 交错,取中位数):

| 负载 | base 中位 | new 中位 | Δ | 臂内极差 |
|---|---:|---:|---:|---:|
| splay | 33.832 G | 33.790 G | **−0.125%** | 0.20% / 0.16% |
| earley-boyer | 478.298 G | 478.164 G | **−0.028%** | 0.16% / 0.03% |
| raytrace | 243.105 G | 243.315 G | **+0.086%** | 0.23% / 0.12% |

全部在 ±0.13% 内,且**小于或等于同臂内的极差**——没有信号,符合 §5.4「本身的 cycles 收益
预期接近 0」。按 §4n 纪律,cycles/wall-clock 在有其它 lane 的机器上不作裁决,本轮不报。

### 8.4 注入验证(三条,全部开火)

新判据与新断言都是「不该发生的事」,所以只能靠注入证明它们在**目标构建形态**下真的被分析、
被执行、且有区分度。做法与 §1.3 同:一次构建、`ZJS_FASTARM_INJECT=<n>` 选中注入点、
在 `zig build test -Dzjs_experimental_gc=trace_stw` 下跑。

| 注入 | 内容 | 结果 |
|---|---|---|
| 1 | 快臂内 `class_id != ids.object` 时 `@panic` | **开火** `INJECT-1: widened arm reached for a non-object standard class` |
| 2 | 快臂内 `hasTrailingPropertyAllocation() and class_id == ids.object` 时 `@panic` | **开火** `INJECT-2: trailing-FAM assert site is live` |
| 3 | 把判据里的 `class_id >= init_count` 排除去掉(动态 id 也走快臂) | **开火**——`Table.deinit` 的 `assert(!state.isPinned())`,即漏掉 `releaseObjectDefinition` 造成的 live-object pin 泄漏 |

注入 1 证明**放宽后的分支真的被非 class-1 的标准类走到了**(否则这把刀是死代码);
注入 2 证明新加的 FAM 断言点在 runtime_safety 构建里是活的(单测就是这个形态);
注入 3 是最有价值的一格:它**不是我写的 panic**,而是引擎自己既有的不变量在预测的位置开火,
证明「动态 id 必须留在通用臂」这条不是保守而是载重的。三条验证后注入代码全部撤除
(`grep -c INJECT src/core/object.zig` = 0),最终二进制重新构建。

### 8.5 rc 未被触碰的逐字节证据

改动全在 `if (comptime gc.trace_stw_enabled)` 内(`passBFastArmEligible` 只被该块与 census
调用,Zig 惰性分析在 rc 构建里根本不分析它)。同源码树的 rc ReleaseFast 构建
(`zig build zjs`,不带 `-Dzjs_experimental_gc`)与基线 `4ac3253f` 对比,`objcopy` 提段后
sha256:

| 段 | 大小 | base sha256(前 12) | new sha256(前 12) |
|---|---:|---|---|
| `.text` | 3,352,660 B | `4ae2685705e8` | `4ae2685705e8` |
| `.text.zjs.op_handlers` | 167,712 B | `ffb152c4d098` | `ffb152c4d098` |
| `.rodata` | 187,096 B | `9c93a5c0d7c7` | `9c93a5c0d7c7` |
| `.data.rel.ro` | 102,128 B | `3e76ab5979d5` | `3e76ab5979d5` |

`readelf -S` 逐段对比:**只有 `.debug_pubnames` / `.debug_pubtypes` / `.debug_line` /
`.comment` / `.symtab` / `.shstrtab` / `.strtab` 的偏移变化**(源码行号位移),没有一个代码或
数据段改变。**rc 侧零改动已证。**

trace 侧 `.text` 从 3,448,572 B 降到 3,447,412 B(−1,160 B);
`freeCycleDeferredStruct` 符号自身 0x184 → 0x188(+4 B),净减来自通用臂的
`freeObjectAllocation` 内联收缩。

### 8.6 没有发现的例外

census 说「落进通用臂的全部是标准 class」是**观测**,本轮把它当假设去证伪,结果是:
**没有找到任何「标准 class 其实不 trivial」的实例**——三负载的 `block_generic_class` 全部归零、
`block_inline_payload` 保持 0、三门全绿、arena-audit 全绿。

但**找到了一个 census 没看见的结构性例外通道**,已写进 §8.1 第 3 条:标准 id 50–68 是表里
未注册的槽位,`Table.register` 不会拒绝它们,因此「标准 class ⇒ 无 inline payload」在
类型上不是不变量。判据保留 `standard_plans[id]` 那次读就是为它。**stage-3 若想把判据压成
纯范围比较,必须先在 `registerAtom` 上把这条变成硬拒绝**——那是一个会改动 rc 可达代码与公开
API 错误集的独立决定,本刀不做。

---

## 9. stage-3 落地(2026-08-29,分支 `gc/opus-stage3`,基线 `9dc9994e`)

§6 建议 2 已执行。三个 commit:

| commit | 内容 |
|---|---|
| `2ffac1df` | Pass-A 结算主体 + `flag_bitmap_canonical` + 逐块审计 + 计数器 |
| `9b115cce` | 计数器从 `gc_concurrent.Stats` 搬进 `block_heap.Stats`(rc 侧零改动) |
| `7b647bca` | 逐块审计的门从 `arena_audit` 改成 `invariantChecksEnabled()` |

### 9.1 与 §5.3 草图的偏离(先说这个)

§5.3 写的形状是「Pass A 分类,**Pass B 对这些尸体按块位图算术结算**」。
落地形状是 **「Pass A 分类**并**就地结算**」——Pass B 对它们完全不存在。三条理由:

1. **位图掩码没有便宜的载体。** §5.3 自己点名了「不能复用 remember 位图」(会改
   `hasPendingDoomed()` 与三处断言的语义)。剩下的选项是给每个 block 加第四张位图
   (改 `blockGeometry` = 堆布局变更)或加一条待结算块链表。而**结算本身**——清一位、
   `allocated_count -= 1`、记一次账——在 Pass A 里做的边际成本就是块头那条**已经热的**线上
   的一次 RMW。为一次 L1 命中的 RMW 建一套新状态,买的是 §5.2 定价表里 ≲0.005 G 的那一项。
2. **发布事件的次序。** 若 trivial 尸体不进 LIFO 而结算留给 Pass B,`onBlockPassBComplete`
   会在一个块的 trivial 部分**尚未结算**时因它的例外尸体而开火,把 `allocated_count`
   还不规范的块发布出去。要修就得把 Pass B 改成按块驱动——正是任务书要求「diff 足迹压到最小」
   的那段代码。
3. **FAM 记账的前提整条消失。** §5.3 要求把 `runs_mixed_fam == 0` 变成 checker 第 11 条。
   逐尸结算读的是尸体自己的 `hasTrailingPropertyAllocation()`,记的是
   `@sizeOf(Object)+trailing`,**块内逻辑尺寸是否一致根本不进入正确性**。
   实测 `pass_a_settled_fam` splay = 7,040,720(占 62.3%),EB/raytrace = 0——与
   §3.2 的 `trailing_fam` 分布逐条吻合,这是「按尸体计价」的正面证据。
   **一条本来要靠观测支撑的前提被设计掉了,比给它加检查器更好。**

第二处偏离:**`onBlockPassBComplete` 对全 trivial 的块不再开火**(splay 的
`deferred_block_runs_completed` 36,881 → 67),因为那些块在 Pass B 里没有任何 parked entry。
它们改由事务关闭时的 `publishCompletedHotBlocks` 发布。两个发布点的**调用位置一字未动**,
变的是哪个块从哪一个走。任务书点名担心的是 K=64 代谢环退化,所以这条不是论证而是实测:

| 负载 | hot published base→new | hot reopened base→new |
|---|---|---|
| splay | 35,756 → 35,748(−0.02%) | 26,511 → 26,489(−0.08%) |
| earley-boyer | 95,390 → 97,394(**+2.1%**) | 47,956 → 49,014(**+2.2%**) |
| raytrace | 13,634 → 13,483(−1.1%) | 13,634 → 13,483(−1.1%) |

热复用没有退化。合理:stage-3 之后 Pass B 在 splay 上从 2,780 次排水调用(2,743 次被预算截断)
降到 37 次 0 截断,**事务关闭本身大幅提前**,所以「晚发布」的直觉方向是反的。

### 9.2 机制:尸体从 doomed 到结算的路径

判定点在 `Object` 的两个 park 出口(`object.zig`),两处都调用同一个
`object_gc.trySettleTracerBlockCorpse`:

* `destroyPlainObjectFast` 的 `if (two_pass)`——class 1 快臂,判据里
  `class_is_settleable` 恒 true(该臂的入口守卫已经保证 class 1 / 无 weak 状态);
* `destroyFromHeaderSlow` 的 `if (phaseIsTwoPassTeardown or .deinit)`——通用臂,
  `class_is_settleable = destroying_class_id < ids.init_count and !has_inline_payload`,
  两个值都来自这条路径**本来就加载过**的 `destructionPlan`。

判据(全部否决项):

| 否决 | 理由 |
|---|---|
| `phase != .tracer_destroy` | rc 的 `.remove_cycles` 与 `.deinit` 保持既有 park 路径 |
| 非标准 class / 有 inline payload | 动态 id 欠一次 `releaseObjectDefinition` 的 pin;inline payload 的分配基址在 Object **之前** |
| 非 block cell | slab/standalone 分配不走 `freeSmallCell` |
| `weakReferenceCount() != 0` 或 `has_weak_id` | Pass B 会保留 husk / 摘 side table(三负载实测恒 0) |
| 块是 `active[size_class]` | mutator 在销毁切片之间从它分配,必须维护活的空闲表示 |
| `allocated_count == 1` | 这一具会清空块;空块生命周期留在 Pass B 已证明的路径上 |

状态表(一具 block 尸体):

| 状态 | 载体 | alloc 位 | `heap_accounted` | 谁能看见它 | 合法后继 |
|---|---|:--:|:--:|---|---|
| doomed(Pass A 前) | 块 doomed 位图(`remember`) | 1 | 1 | `containsHeader` / 保守扫描 / young 迭代器(按 doomed 位屏蔽) | 资源已剥离 |
| 资源已剥离 | — | 1 | **0** | 无(两级判据 alloc∧accounted 都要真) | **已结算未挂链** 或 parked |
| **已结算未挂链**(新) | 无载体;块带 `flag_bitmap_canonical` | **0** | 0 | 无 | 区间重建 |
| parked(例外) | 全局 LIFO | 1 | 0 | `verifyDeferredFreeRunTopology` 精确成员 | Pass B 物理释放 / weak husk |
| Pass B 已释放 | 块 `free_list`/`next_free` | 0 | 0 | 分配器 | 分配 |
| 区间重建后 | `bump..interval_end` + `free_list` | 0 | 0 | 分配器 | 分配 |

**「已结算未挂链」不会破坏全局两遍规则**,因为可复用的唯一入口是
`rebuildFreeIntervals` 从 alloc 位图重建区间,而它只在 `openBlock` 里对**已被发布门放行**
的块运行;发布只能来自 `onBlockPassBComplete`(排水期,Pass A 全局完成之后)或
`publishCompletedHotBlocks`(事务关闭)。doomed 块在 Pass A 期间进不了 hot 表
(`publishHotBlock` 见 `hasPendingDoomed()` 直接返回),也进不了 `free_blocks`
(清空那一具被否决了)。尸体的字节一个没动——`pushCell` 才会覆写头 4 字节,而结算不写链。

**为什么早清 alloc 位是不可观测的**:块 cell 的三条解析路径
(`Table.resolveInBlockCell` / `Table.containsHeader` / `forEachGcObjectInBlocks`)与
`GcObjectIterator.nextInBlock` **都要求 alloc 位 ∧ `heap_accounted`**,而
`heap_accounted` 在 Pass A 的 `unregisterObjectWithBytes → recordHeapFreeWithBytes`
里就已经清零。所以对一具已被 Pass A 处理过的尸体,alloc 位早清只是让位图扫描少一位,
没有任何读者的答案改变。

`flag_bitmap_canonical`(占用已死的 `flag_epoch_transition` 位,该位自
`ensureMarkEpoch` 原子化重写后再没被读写过)声明「本块的空洞只有 alloc 位图记录」。
`Heap.verify` 对它与 hot-unprepared 同等处理:跳过空闲链**完整性**走查,其余全部照跑。
`rebuildFreeIntervals` / `resetBlock` / 空块转换清除该位。

### 9.3 检查器清单与注入验证

除注入 4 外全部在 `zig build test -Dzjs_experimental_gc=trace_stw`(必要时叠
`ZJS_GC_ARENA_AUDIT=1`)下**实测开火**。一次构建,`ZJS_S3_INJECT=<n>` 选点,验证后
注入代码全部撤除(`grep -c s3_inject src/` = 0)。

| # | 注入 | 被验证的检查器 | 结果 |
|---|---|---|---|
| 1 | 结算时不做 `allocated_count -= 1` | `Heap.verify` 的 `AllocCountMismatch` | **开火** `gc: BLOCK HEAP AUDIT: AllocCountMismatch` |
| 2 | 同一具尸体结算两次 | 结算入口 `assert(testBitPlain(alloc, index))` | **开火**(`std.debug.assert(testBitPlain(block.bitmaps().alloc, index))`) |
| 3 | 去掉 `canSettleDoomedCellInPassA` 否决 | 结算入口 `assert(canSettle…)` | **开火** |
| 4 | 强制 `class_is_settleable` 为真(动态 id / inline payload 也结算) | `assert(passBFastArmEligible)` | **未开火**——见下 |
| 5 | 结算时不设 `flag_bitmap_canonical` | `Heap.verify` 空闲链完整性 | **开火** `incomplete free chain … walked=0 expected=704` |
| 6 | 既结算又 park | `verifyDeferredFreeRunTopology` 的 `cellAllocated` | **开火** `DEFERRED RUN AUDIT: DeferredBlockCellInvariant` |
| 7 | 既不结算也不 park(泄漏) | `verifyPublishedCellsAllowing` | **开火** `BLOCK CELL PUBLICATION AUDIT: AllocatedCellUnpublished` |
| 8 | Pass A 收尾块时 `allocated_count +%= 1` | **新增**的逐块审计 | **开火** `gc: PASS-A SETTLEMENT AUDIT: AllocCountMismatch block=0x… allocated_count=4` |
| 9 | 把 `assert(passBFastArmEligible)` 取反 | 该断言点在目标构建里是活的 | **开火** |
| 10 | 把 `assert(payload_bytes == allocationSize)` 取反 | 该断言点是活的 | **开火** |

三点必须说清楚:

* **注入 1、5、6、7 验的是既有检查器**,它们此前对「结算」这个状态无话可说,现在是
  stage-3 三种失效模式(漏减 / 漏声明位图权威 / 双重释放 / 泄漏)的唯一守卫。
  把它们当成新检查器逐条注入,是因为「它恰好也能抓到新缺陷」必须被证明而不是被假设。
* **注入 4 未开火,不算通过。** 它要求一具**动态 class 的 block cell 尸体在
  `.tracer_destroy` 里死亡**,整个套件里没有这样的对象(inline-payload class 根本不是
  block cell,已被 `isBlockCellHeader` 挡掉)。所以「动态 id 必须留在 park 路径」这条的
  载重证据是 §8.4 注入 3(同一判据、同一理由,当时由引擎自己的
  `Table.deinit` pin 断言开火),加上注入 9 证明本刀的子集断言点是活的。
  **记录为覆盖缺口,不记录为通过。**
* 注入 8/9/10 是**存活性**注入(Zig 惰性分析陷阱),不是不变量注入:它们只证明
  「这段代码在这个构建形态里真的被分析、被执行到」。1/2/3/5/6/7 才是不变量注入。

### 9.4 census 对照

同一台机、core 19、`-Dzjs_experimental_gc_corpse_census=true` 的 ReleaseFast 构建。
`pass_a_settled` 是新增计数器,`entries_total` 是仍然 park 的。

| 负载 | base block 尸体 | base trivial | new `pass_a_settled` | new 仍 park 的 block entry | new = allocator_current + becomes_empty | 闭合差 |
|---|---:|---:|---:|---:|---|---:|
| splay | 11,309,495 | 11,308,375 | **11,303,793** | 1,157 | 1,115 + 42 = 1,157 ✓ | −0.040% |
| earley-boyer | 98,082,050 | 96,748,678 | **96,728,594** | 1,352,832 | 1,289,921 + 62,913 = 1,352,834 ✓ | −0.0006% |
| raytrace | 41,238,357 | 41,220,809 | **41,194,161** | 44,403 | 15,783 + 28,620 = 44,403 ✓ | +0.0005% |

三条读法:

1. **`settled + 仍 park` 与 base 的 block 尸体总数逐负载闭合**(EB/raytrace 到 0.001%,
   splay 到 0.04%,均在 §3 记的存活集漂移量级内)。既没有尸体丢失,也没有重复计数。
2. **剩下 park 的恰好是两条否决项之和**,EB 与 raytrace 逐条相等(差 2 与 0)。
   也就是说 §3.3 的「放宽快臂之后唯一还挡着 stage-3 的就是 allocator-current」现在多了
   一条**我自己引入的**否决(会清空块的那一具),而它在账上是可见、可计数、可核对的。
3. `pass_a_settled_fam` splay 7,040,720 / EB 0 / raytrace 0,与 §3.2 `trailing_fam`
   的 7,045,479 / 1 / 0 同构 —— 记账按尸体走,不是按 cell_size 走。

排水侧:splay `drain_calls` 2,780 → **37**,其中被 4096 预算截断 2,743 → **0**;
raytrace 14,031 → 3,510(截断 10,522 → 0);EB 34,145 → 19,449(截断 23,875 → 9,178,
剩下的全是 §3.1 那 73.58 M 条 `var_ref` 通用前缀——stage-3 一条也碰不到,与 §5.2 折扣 3 一致)。

### 9.5 指令数 A/B

core 19,`armv8_pmuv3_1/instructions`,base/new 交错三轮取中位数。

| 负载 | base 中位 | new 中位 | Δ | base 臂内极差 | new 臂内极差 |
|---|---:|---:|---:|---:|---:|
| splay | 33.788 G | 33.345 G | **−1.314%** | 0.091% | 0.125% |
| earley-boyer | 477.950 G | 475.161 G | **−0.584%** | 0.025% | 0.278% |
| raytrace | 243.109 G | 242.130 G | **−0.403%** | 0.063% | 0.196% |

**三条全部下降,且远大于臂内极差。** §6 建议 2 曾预测「指令数会上升(块级结算多了位图
循环)」——那是对 §5.3 那个形状的预测;落地形状里位图循环不存在,消失的是 LIFO 推入/弹出、
`pushCell`、以及排水循环本身。

结构核对(每具尸体省下的指令 × 结算数):
splay 0.443 G / 11.30 M = **39 条/尸**,EB 2.789 G / 96.73 M = **29 条/尸**,
raytrace 0.979 G / 41.19 M = **24 条/尸**。同一量级、按「排水链路约 70 条」(§4.4)
的比例是合理的:splay 的尸体多带 FAM 与更长的 park 链,EB/raytrace 走的是更短的快臂。

**cycles / L2D refill 不在本节。** 机器上有其它 lane,按 §4n 纪律 wall-clock 与 cycles
不作裁决,留给 driver 的安静窗口。本刀声称的是:指令方向为负、机制账目闭合、门禁全绿。

### 9.6 门禁

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `zig build test` | **2380 passed / 93 skipped / 0 failed** |
| trace 单测 | `zig build test -Dzjs_experimental_gc=trace_stw` | **2455 passed / 19 skipped / 0 failed** |
| fixed-work smoke | `tools/perf/gate_smoke.sh /tmp/s3bin/zjs-trace-new /tmp/gcgap-fixed 19 3` | **all clean**(6 负载 × 3 普通 + 1 arena-audit/stats) |
| arena audit splay | `ZJS_GC_ARENA_AUDIT=1 … splay.js` | **exit 0,零诊断** |
| arena audit earley-boyer | 同上 | **exit 0,零诊断** |

⚠️ `gate_smoke.sh` 必须显式传 trace 二进制:裸调会拿 `zig-out` 里现成的那个,而
本轮 `zig-out` 里最后一次构建可能是 rc。

### 9.7 rc 侧未被触碰的证据(以及第一版怎么错的)

第一版把计数器加进 `gc_concurrent.Stats`、把 `--gc-stats` 的 morgue 行加宽,rc ReleaseFast
`.text` 从 3,579,912 B 变成 **3,580,592 B**。教训直白:**trace-only 的判据是「谁分析它」
而不是「谁用它」——`gc_concurrent.Stats` 在 rc 的 Registry 里照样实例化。**
计数器改挂 `block_heap.Stats`(整个模块受 `block_heap_enabled == trace_stw_enabled` 门控),
打印挂在既有的、本来就在 comptime 门控块里的 block-heap 统计行上。

复核(`objcopy --only-section` + sha256,base = `9dc9994e`):

| 段 | 大小 base / new | sha256 一致? |
|---|---|---|
| `.text` | 3,579,912 / 3,579,912 | 否(见下) |
| `.text.zjs.op_handlers` | 257,496 / 257,496 | **是**(`99c35e433c01a9fb`) |
| `.rodata` | 298,872 / 298,872 | 否(见下) |
| `.data.rel.ro` | 159,920 / 159,920 | 否 |

**尺寸逐段相同;`.text` 的反汇编在地址归一化后逐条指令完全相同**(`objdump -d --section=.text`
去掉地址与符号名后 `cmp` 只差文件名那一行)。`.rodata` 的 619 个差异字节**逐个核过,
全部落在 `__anon_N` 类型名字符串内部**(如 `__anon_200551` → `__anon_200555`),
其余段的 sha 差异是指向这些位移了的字符串的地址。这正是 §1.2 记过的匿名符号编号位移,
不是代码差异。**没有做到 sha 逐字节相同,报为「指令等价 + 尺寸相同」而不是「相同」。**

### 9.8 遗留

* **stage-2 已随 stage-3 消失**(§5.1 的建议):被结算的尸体从不写 per-cell free link。
  splay 上 95.6% 「可证明的死存储」现在真的不写了;写回流量的独立验证(`l2d_cache_wb`)
  归 driver 的安静窗口。
* **EB 的下一个靶仍不在这条线上**:它 73.58 M 条 `var_ref` 通用前缀一条没动,
  与 §5.2 折扣 3、§6 建议 4 一致。
* **allocator-current 仍是最大剩余否决**(EB 1.29 M 具 = 1.3%)。让它也能结算需要
  「私有块的活空闲表示」这条设计决定,属于 lane-f 的 hot/cold 归属范围,不在本刀。
* **会清空块的那一具尸体**留在 park 路径(splay 42 / EB 62,913 / raytrace 28,620)。
  这是我为了不把空块生命周期搬进 Pass A 而付的价;如果 driver 想收掉,前置是把
  `noteEmptyBlock`/`free_blocks` 的转换做成事务感知的。
* 注入 4 的覆盖缺口(§9.3)。
