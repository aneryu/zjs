# 登记簿职责审计:block-cell 对象还需要逐对象登记吗?(2026-08-29)

基线 `4c621491`(worktree `/home/aneryu/worktrees/opus-registry-audit`,分支
`gc/opus-registry-audit`)。任务假设是:splay 符号账里 `serveObjectCells`
0.163G + `addInitialized*` 0.167G + `removeGcObjectAfter`+`unlinkObjectWithBytes`
0.161G ≈ **0.49G cycles** 是「纯 trace 登记机械」,对照 JSC 的无逐对象登记设计
可以结构性回收。

**裁决:保守分叉 —— 不实现。理由不是「被阻塞」,而是「已经做完了」。**
block-cell 群体的逐对象登记在更早的 tranche 里就已经全部退役;那 0.49G 的三项
里,一项(0.163G)已在 `03c73f47` 被回收、符号在当前二进制中不存在,另外两项
服务的根本不是登记簿也不是 block-cell 群体。下面是逐机制的证据。

---

## 0. 结论摘要

| 机制 | 对 block cell 的职责 | 可否退 | 依据 |
|---|---|---|---|
| `gc_address_registry` 占用表(`by_header`/`pages`) | **无**。block cell 永不进入 | 已退(历史) | `registerLiveAddress` gc.zig:4122 以 `alloc_info.standalone` 为门;`initGcPrefixBlockCell` memory.zig:1160-1169 使该位恒为 0 |
| `gc_address_registry` 解析侧(`forEachGcObjectAt`/`resolveAny`/`containsHeader`) | 保守候选解析,但**全部走块元数据** | 不可退(是保守扫描本身) | gc_address_registry.zig:700-705 / :731-742 / :773-782 |
| `gc_address_registry` arena 集 + `auditArenas`/`verifyIndex` | 无(服务 slab / standalone / string 群体) | 不在范围 | 见 §1 |
| 侵入式 `gc_obj_list` | **无**。block cell 从不入链 | 已退(历史) | gc.zig:2632 `if (tracked and !isBlockCellHeader(h))` |
| `addInitializedWithSizeNoFail` | 发布位 `heap_accounted`、字节账本、young 位 | **不可退**(见 §3) | gc.zig:2591-2636 |
| `addInitializedShape` | 无(shape 不由块堆服务) | 不在范围 | memory.zig:1204 只路由 `object_kind_tag` |
| `removeGcObjectAfter` | **无**。block cell 的 `next == null`,两条调用路径都在进入前返回 | 已退(历史) | gc.zig:3325 / :2853 的 `headerLinked` 门 |
| `unlinkObjectWithBytes` | 只剩字节账本;链表分支对 block cell 恒不进入 | 不可退(账本) | gc.zig:2842-2855 |
| `serveObjectCells` | 一次性安装两个指针 | **已退**(`03c73f47`) | 见 §4 |

---

## 1. `gc_address_registry.Table` 全部公开 API 与调用点

| API | 定义 | 职责分类 | 服务群体 | block cell 依赖? |
|---|---|---|---|---|
| `noteArenaCreated` | :191 | 保守候选解析(集合维护) | slab arena | 否 |
| `resyncArenas` | :214 | 保守候选解析(完整性恢复) | slab arena | 否 |
| `noteArenaReleased` | :241 | 同上 | slab arena | 否 |
| `auditArenas` | :321 | 检查器 | slab arena | 否 |
| `verifyIndex` | :362 | 检查器 | 占用表 + arena 集;block 仅核对 bounds(:435-447) | 只核对全局 bounds |
| `rebuildScanFilter` | :453 | 保守候选解析(每次扫描重建) | 全部 | 是,但 block 位来自 `heap.scanFilter()`(:464),不来自逐对象登记 |
| `deinit` | :547 | — | — | — |
| `occupantFor` / `rangeForBytes` | :558 / :565 | 记账(区间构造) | standalone / string | 否 |
| `insert` / `insertRange` | :569 / :573 | **逐对象登记** | standalone 前缀分配;shadow 构建下的 string/rope | **否** |
| `remove` / `removePtr` | :618 / :622 | **逐对象注销** | 同上 | **否** |
| `resolve` | :666 | 保守候选解析 | 全部(经 `resolveAny`) | 走 block 臂 |
| `forEachGcObjectAt` | :689 | 保守候选解析(逐字原语) | 全部 | 是,块臂优先且**互斥返回** |
| `resolveAny` | :726 | 保守候选解析(冷路径) | 全部 | 是,块臂在 bounds 检查之前 |
| `containsHeader` | :771 | weak-id 身份 / 检查器谓词 | 全部 | 是,块臂 :773-782 |
| `noteFailedInsert` | :819 | 记账 | standalone / string | 否 |

外部调用点(非 test):`gc_candidate.zig:71`、`gc_conservative.zig:219/229/233/253`、
`active_invocation_trace.zig:74`、`gc_trace_stw.zig:515/524/687/1532`、
`gc.zig:2230/4073/4094/4102/4108/4126/4199/4227/4241/4430/4432/4633/4659`。

### 1.1 关键证据:`insert`/`remove` 的唯一入口都以 `standalone` 为门

```
gc.zig:4114  inline fn registerLiveAddress(...)
gc.zig:4122      if (!header.meta().alloc_info.standalone) { self.markPublishedYoung(header); return; }
gc.zig:4126      self.address_registry.insert(...)

gc.zig:4193  inline fn unregisterLiveAddress(...)
gc.zig:4198      if (header.meta().alloc_info.standalone) self.address_registry.remove(...)
```

`initGcPrefixBlockCell`(memory.zig:1160-1169)把 `alloc_info` 写成
`alloc_info_block_cell`(0x1F,`standalone` 位清零),因此**一个 block cell
在结构上不可能进入占用表**。这不是运行时巧合,是构造保证。

### 1.2 反方向也已被检查器覆盖

`auditLiveObjectsResolve`(gc_trace_stw.zig:1527)用 `objectIterator()` 遍历
**gc_obj_list + 全部 block cell**,对每一个都要求 `containsHeader` 为真;
对 block cell 这条路径只读块元数据(`blockOf` → `cellIndexInterior` →
`cellAllocated` → 前缀 `heap_accounted`)。它由 `verifyCollectorInvariants`
(gc_trace_stw.zig:516)在 `ZJS_GC_ARENA_AUDIT=1` 下每次收集后调用。

本轮实测(见 §6):splay 与 raytrace 在 arena audit 下全绿。splay 一次 fixed-work
运行里 **29 次 major 累计** marked-set 为 16,621,287 个 header,其中
**16,615,467(99.965%)是 block header**(`--gc-stats` `marked-set census`);
`marked-set kinds` 里 `object` 恰好等于 block header 数,即 **splay 的存活对象
100% 是 block cell**。这批全部通过了「只用块元数据必须能解析」的检查。
这是「登记簿对 block cell 已无职责」最直接的经验证据。

---

## 2. `gc_obj_list` 及其全部遍历者

**成员**:`addInitializedWithSizeNoFail` 显式排除 block cell(gc.zig:2632);
`addInitializedShape` 无条件入链(gc.zig:2654),因为 shape 不由块堆服务
——`createInternal` 的路由谓词只认 `T.gc_kind_tag == object_kind_tag`
(memory.zig:1204)。所以现在链上只有 shape / var_ref / function_bytecode /
realm_context / module / **standalone 对象**。

**遍历者**(非 test):

| 位置 | 用途 | block cell 的对应路径 |
|---|---|---|
| gc.zig:2132 | teardown | 块堆 deinit |
| gc.zig:3046 `objectIterator` | census / verify | 同一迭代器的块阶段(`nextCell`,gc.zig:3006) |
| gc_trace_stw.zig:914 `clearYoungState` | young 位退休 | `youngIterator` + `clearYoungBlocks`(:922-927) |
| gc_trace_stw.zig:1156 | 增量 major condemn | `snapshotAllDoomed`(:1151) |
| gc_trace_stw.zig:2123/2146 | minor condemn | `youngBlockIterator`(:2115/:2133) |
| gc_trace_stw.zig:2233 `sweepUnmarked` | STW sweep | `deadBlockCandidateIterator`(:2226) |
| object_gc.zig:445 | rc 环收集 gc_scan | trace 下不执行 |
| shape.zig:378 | shape teardown | 不适用 |

**每一个链表遍历者都已经有一条块元数据对应路径**,两者互不交叉。规模证据:
splay 一次 fixed-work 运行 29 次 major **累计**的非 block header 只有 5,820 个
(function-bytecode 1,564 + var-ref 1,664 + realm-context 29 + module 0 +
shape 2,563),对 16,615,467 个 block header。

---

## 3. `addInitialized*`:对 block cell 逐条拆解

`addInitializedWithSizeNoFail`(gc.zig:2591)对一个 block-cell 对象实际执行:

| 步骤 | 行 | 职责分类 | 能否由块元数据承担 |
|---|---|---|---|
| 6 条 `std.debug.assert` | :2592-2598 | 检查器 | ReleaseFast 已擦除 |
| `isLargeAllocation` | :2600 | 记账 | 可 comptime 消解(block cell 恒非 large),但只是一次 compare |
| standalone `size_class` 戳记 | :2607 | 记账 | block cell 不进入该分支 |
| `heap_accounted = true` | :2608 | **发布身份** | **不可退**,见下 |
| `old_space.recordAlloc(bytes)` | :2622 | 记账(GC 调度) | 理论可从块占用推导,但账本刻意记**对象尺寸**而非 cell 尺寸(memory.zig:1212-1216),`verifyHeapAccounting` 的期望值也由 `allocationSize` 导出;换算面很大,收益是两条标量指令 |
| `isCycleCandidate` | :2630 | 分类 | 一次 kind 比较 |
| `if (tracked and !isBlockCellHeader(h))` | :2632 | 链表 | **block cell 已排除** |
| `registerLiveAddress` | :2633 | 登记 | 非 standalone 立即返回(:4122) |
| `markPublishedYoung` | :4136 | 分代 | young 位 + `young_count`;`noteYoungCell`(:4178)**已是块粒度**(gc_block_heap.zig:704,一个块只在首个 young cell 时入链) |
| `observeNewPublication` | :4247 | 记账/仪器 | 生产 trace 下 `sweep_model_stats_enabled = false`(gc.zig:62),只剩一次 `detailed_reports` 加载+分支 |

### 3.1 `heap_accounted` 为什么不能由 alloc 位图取代 —— 阻塞职责的精确刻画

块的 alloc 位图回答的是「这个 cell 被发出去了吗」;`heap_accounted` 回答的是
「它已经是一个**已发布**的对象吗」。两者的差集是「cell 已分配、对象仍在构造中」。
保守解析在 `forEachGcObjectInBlocks`(gc_address_registry.zig:522-526)正是分两级问:
先 `cellAllocated`,再 `heap_accounted`。

去掉第二级 = 允许 tracer 把半构造对象当成完整对象遍历。这正是本仓库已经付过学费的
缺陷类(见 pause plan §4i.1 free-cell impersonation、以及 `markPublishedYoung`
注释里记的 test262 core dump)。块元数据里目前**没有**第二个位来承载「已发布」,
而 `heap_accounted` 就在 cell 首个 cache line 的前缀里,和 alloc_info 同一字节 ——
搬到块位图不会更便宜,只会多一次位图寻址。

**因此 `heap_accounted` 是 block-cell 发布路径上唯一真正无法退役的逐对象写,
而它一开始就不是登记簿,是身份位。**

---

## 4. `serveObjectCells`:0.163G 已被 `03c73f47` 回收,符号已不存在

任务简报里的 0.163G 来自主线 `c9c66de3` 的符号账。在那个版本上,
`serveObjectCells`(c9c66de3:src/core/gc.zig:3781)的函数体里内联着两个**匿名闭包**:

```zig
account.gc_cell_alloc_fn = struct { fn call(ctx: *anyopaque, bytes: usize) ?[*]u8 { ... } }.call;
account.gc_cell_free_fn  = struct { fn call(ctx: *anyopaque, cell: [*]u8) void   { ... } }.call;
```

热的是这两个闭包(每次对象分配/释放各一次间接调用),不是 `serveObjectCells`
本身 —— 后者一个 Runtime 只跑一次。perf 把闭包的样本记在外层符号名下。

`03c73f47 gc: devirtualize tracing object cell allocation` 把这对函数指针换成了
`account.gc_object_cell_heap` 直连字段(memory.zig:642、gc.zig:4078)。当前
`4c621491` 的 ReleaseFast trace 二进制里:

```
$ nm -S zig-out/bin/zjs | grep -i serveObject     # 空
$ nm -S zig-out/bin/zjs | grep -i allocCell
0000000001363440 000000000000022c t core.gc_block_heap.Heap.allocCellFixedPtr__anon_59718
```

那笔开销现在以 `allocCellFixedPtr` **0.49%** 与 `freeSmallCell` **0.53%** 出现,
且已是直连调用。**0.163G 这一行必须从战役账本的「在案靶子」里划掉。**

> 教训(与记忆里的「共享冷体符号归因」同类):**一个每 Runtime 只跑一次的
> 函数出现在 profile 前几十名,本身就是归因失败的信号。** 写进账本前应当
> `nm` 核一次符号是否存在、体积是否合理。

---

## 5. 那么现在这些符号的钱花在哪(实测,4c621491)

采集:`taskset -c 17 perf record -e armv8_pmuv3_1/cycles/ -c 262147`,
0 lost samples,39,622 样本;同场 `perf stat` 得 10.056G cycles / 33.80G insn
(与 lane-d 账的 10.216G 同一量级)。绝对值 = share × 10.056G。

| 符号 | share | 绝对 | 它实际在做什么 |
|---|---:|---:|---|
| `addInitializedWithSizeNoFail` | 1.79% | 0.180G | 发布位 + 字节账本 + young;**不含任何登记** |
| `addInitializedShape` | 0.51% | 0.051G | shape 发布 + 入链(shape 不是 block cell) |
| `removeGcObjectAfter` | 0.90% | 0.091G | 见 §5.1 —— 主体是分代 remembered-set 哈希删除 |
| `unlinkObjectWithBytes` | 0.46% | 0.046G | 字节账本 + 三个早退分支 |
| `serveObjectCells` | — | 0 | 符号不存在 |
| 合计 | 3.66% | **0.368G** | 对账里的 0.49G |

### 5.1 `removeGcObjectAfter` 的 55% 不是链表也不是登记簿,是 remembered-set

`removeGcObjectAfter`(gc.zig:3331)在 ReleaseFast 里有 **2148 字节**函数体
(`nm -S`:`0x864`),对一次单向链表 splice 显然过大。逐指令归因
(`perf annotate`)显示热点全在 `unregisterLiveAddress` → `forgetGenerationalOwner`
(gc.zig:3950)→ `generation.forget` 的**无条件哈希表删除**上:

```
 14.89 : 114b178: ldrb  w12, [x24, x9]      // 开放寻址探测
 14.33 : 114b184: b.eq  ...
  8.43 : 114b1ec: tbz   w23, #4, ...
  7.58 : 114b17c: cmp   w10, #0x0
  6.46 : 114b180: ccmp  w12, #0x0, #0x4, ne
  ...   : 114b164: bl    hash.wyhash.Wyhash.hash
```

该区段约占 `removeGcObjectAfter` 自身周期的 **55%**。加上外部符号:

| 符号 | share |
|---|---:|
| `removeGcObjectAfter` 内哈希段(≈55% × 0.90%) | ≈0.50% |
| `hash.wyhash.Wyhash.hash` | 0.25% |
| `HashMapUnmanaged(usize,void,…).getOrPutAssumeCapacityAdapted` | 0.28% |
| `…put` / `…grow` | 0.07% |
| **分代 remembered-owner 映射合计** | **≈1.10% ≈ 0.11G** |

而 `--gc-stats` 报告 splay 的 **remembered owners 最终只有 590 个**,
`remembered-owner` 屏障出口 2,036,698 次。**0.11G cycles 维护一个 590 项的集合。**

`.object` owner 已经有一个成员身份缓存位 `trace_remembered_mask`
(gc.zig:3914-3923),插入侧用它跳过映射;**删除侧 `forget` 没有用它**,
每次都完整哈希+探测。位为 0 ⇒ 不在映射里,这条蕴含在插入侧已经是前提。

**但这条不在本任务范围内,也不由本任务实现**:`trace_remembered_mask` 正是
lane-a/b 在途的「屏障 bit7」契约(含正在建的 bit⇒map coherence 检查器)。
本审计只把它作为发现移交。

### 5.2 `addInitializedWithSizeNoFail` 里一次可消除的重复加载

同一次 annotate 显示该符号 **40.76% 的自身周期**落在单条指令上:

```
  1.13 : 136aa7c: orr   w10, w8, #0x40     // heap_accounted = true
  0.56 : 136aa80: strb  w10, [x22, #2]     // 写回 alloc_info
  ...
  1.13 : 136aaa4: ldrb  w8,  [x22, #2]     // isBlockCellHeader:重新加载同一字节
  2.82 : 136aaa8: mov   w9,  #0x1f
 40.76 : 136aaac: bics  wzr, w9, w8        // <== 这里
  4.09 : 136aab0: b.eq  ...
```

`isBlockCellHeader` 读的是 `block_size_idx`(低 5 位),而中间那次 `strb` 只动
bit6;两者不冲突,值在 `w10` 里本来就有。编译器因为中间隔了
`old_space.recordAlloc` / `recordLargeSpaceAllocCold` 的可能别名而不敢复用。
把 block-cell 判定改为从存储前的字节值算出,可以去掉这次「刚写完就重读」。

**本轮不实现**,理由是它无法在本任务的仪器下验收:每次发布省 1 条 load,
splay 18,409,431 次发布 ⇒ 约 −18M insn / 33.80G = **−0.05%**,低于指令数筛选的
分辨力(本机同负载 spread 0.12%);唯一能判它的是 cycles,而 cycles 裁决按纪律
归 driver 的安静窗口。移交为**已定位、已定量假设、待安静窗口定价**的候选。

---

## 6. 门禁与测量

代码零改动,所以下列全部是**基线 `4c621491` 的状态确认**,不是 A/B。
全部 `set -o pipefail`,退出码显式回显。

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `taskset -c 0-14 zig build test` | **2380 passed / 93 skipped / 0 failed**,rc=0 |
| trace 单测 | `taskset -c 0-14 zig build test -Dzjs_experimental_gc=trace_stw` | **2455 passed / 19 skipped / 0 failed**,rc=0 |
| fixed-work 冒烟 | `bash tools/perf/gate_smoke.sh zig-out/bin/zjs /tmp/gcgap-fixed 17 3` | **all clean**(6 负载 × (3 ordinary + 1 arena-audit/stats)),rc=0 |
| arena audit 负载 | `ZJS_GC_ARENA_AUDIT=1 ./zjs splay.js` / `raytrace.js` | 两者 rc=0,无 panic |
| rc `.text` 逐字节 | — | **不适用**:本轮未修改任何源文件 |

> ⚠️ 两点必须记下来,否则下一个人会重踩:
>
> 1. **任务简报里的 `zig build test -Dzjs_gc=trace_stw` 会被 build.zig 直接拒绝**
>    (build.zig:57-60:「not a supported tracing entry」)。正确入口是
>    `-Dzjs_experimental_gc=trace_stw`。
> 2. **新建的 git worktree 里 `test262/` 是空目录**(它是 submodule),导致
>    `zig build test` 有 2 个 `cli.run_test262.*` 用例以 `FileNotFound` 失败 ——
>    这是**环境失败,不是代码失败**,但一个不核实的人会把它当成基线红。
>    修法:`rmdir test262 && ln -s /home/aneryu/zjs/test262 test262`(提交前撤回)。
>    这次第一轮 rc 测试就是这么红的,补上 corpus 后 0 failed。

### 6.1 三负载指令数基线(供后续 A/B 参照)

`taskset -c 17 perf stat -e armv8_pmuv3_1/instructions/`,测量前
`mpstat -P 15,16,17,18,19 1 2` 五个大核 idle ≥ 99.5%,`pgrep -c -x zig = 0`。

| 负载 | run1 | run2 | spread |
|---|---:|---:|---:|
| splay | 33,801,291,633 | 33,840,375,708 | 0.12% |
| earley-boyer | 478,654,304,056 | 478,256,523,919 | 0.08% |
| raytrace | 243,176,725,043 | 243,716,119,622 | 0.22% |

---

## 7. 移交给 driver 的四条

1. **账本更正(必做)**:`serveObjectCells` 0.163G 应从在案靶子里删除 ——
   它在 `03c73f47` 已被去虚化,符号在当前二进制中不存在。
   `docs/splay-account-2026-08-28.md` 的「纯 trace 登记机械 0.49G」一句需要改写:
   实测三项合计 **0.368G**,且其中没有一分钱是登记簿。
2. **新靶子(约 0.11G,归 lane-a)**:分代 remembered-owner 哈希映射为一个
   590 项的集合花掉 splay 的 ≈1.10%;删除侧 `forget` 没有复用插入侧已有的
   `trace_remembered_mask` 缓存位。与 lane-a/b 在途的屏障 bit7 契约同一块地。
3. **小候选(约 −0.05% insn,需 cycles 定价)**:
   `addInitializedWithSizeNoFail` 里 `heap_accounted` 写回后对同一字节的重读
   (自身周期的 40.76% 落在其后一条指令上)。
4. **「登记簿退役」这条战线本身可以关闭**:block-cell 群体在保守解析、堆枚举、
   记账、身份四个职责上都已经只依赖块元数据。剩余的登记簿(occupant table +
   arena set)服务 standalone / slab / string 群体,它们是块集合过滤器管不到的
   地址空间,按 backlog A4 也还不能退役。

---

## 8. §7 第 2 条(forget 侧 bit7 跳过)的 soundness 审计

2026-08-29,lane-b 在修复 `f469ab96` 的 shape summary 回归时顺带审计。
**结论:成立,但有一处结构性前置必须先改,否则这把刀会变成恒真跳过。**

### 8.1 必须先改的那一处:清位在删表之前

现行 `Registry.forgetGenerationalOwner`(gc.zig:3959)是:

```
clearGenerationalRememberedBit(header);   // 先清 bit7
self.generation.forget(header);           // 再无条件 remove
```

若照字面把「先查 `trace_remembered_mask` 再决定 remove」放进
`gc_generation.zig` 的 `forget`,它读到的位**永远是刚被上一行清掉的 0**,
于是跳过恒真、映射项永不删除 —— 从「白花哈希删除」直接变成悬垂地址。
刀必须把两步**融合**:由 `forget`(或 `forgetGenerationalOwner`)一次
读位、按位决定 remove、再清位;不能保留现有顺序。

### 8.2 跳过成立所需的全部不变量

刀依赖的核心命题是 **I0:对 `kind == .object` 的 header,bit7 清 ⇒ 不在
`remembered` 映射中。** 支撑它的是下面五条:

- **I1(kind 旁路)**:非 `.object` owner 由
  `rememberGenerationalOwner`(gc.zig:3922)的 else 分支入表,**从不置位**。
  因此跳过必须以 `flags.kind == .object` 为门,和现有
  `clearGenerationalRememberedBit` 的门完全一致。该字节与 `forget` 已经读的
  `flags.young` 同在元数据里,门是免费的。
- **I2(置位时机)**:置位只发生在 `rememberGenerationalOwner`,且**在
  `rememberOwner` 返回 true 之后**。`remembered.put` OOM 时返回 false、
  位保持清、映射也没有项 —— 这正是 I0 要的方向,分配失败不会制造
  bit=0/map=1。
- **I3(清位时机)**:清位只有两个生产入口 ——
  `clearGenerationalRememberedBit`(单个,kind 门)与
  `clearGenerationalRememberedBits`(全表迭代)。后者只被
  `retireGenerationalYoungSet` 调用,紧接着就是
  `generation.retireYoungSet()` 的 `clearRetainingCapacity`。两者之间存在
  一个「位已清、映射未清」的窗口,**其安全性依赖于这是一次不可打断的
  STW 事务**:窗口内没有 mutator、没有 free、因而没有 `forget` 能观察到它。
  这条从「注释里的一句话」升格为**刀的显式前置**。
- **I4(整字节清零的三处)**:`object_shape_summary` 有三处整字节写 0,
  它们会连 bit7 一起抹掉,必须证明发生时对象已不在映射里:
  1. `resetHeaderLifetimeForPublication`(gc.zig:1176,`lifetime.trace = .{}`)
     —— 发布前,新地址;
  2. `setHeaderWeakHusk`(gc.zig:1170)—— 前置断言
     `!alloc_info.heap_accounted`,且调用点(object.zig:2434、
     object_gc.zig:583)都在 `unregisterObjectWithBytes` **之后**,
     即已经过 `unregisterLiveAddress` → `forgetGenerationalOwner`;
  3. `finishGeneratorShell` 的失败路径(object.zig:732)—— 该 shell 的
     `registerObjectWithBytes` 刚刚失败,从未进过映射。
  这是一条**顺序依赖**:任何把 husk 标记提到注销之前的改动都会静默
  破坏 I0。
- **I5(地址复用)**:映射以 `@intFromPtr(header)` 为键,block cell 会复用
  地址。若某次 `forget` 因位为 0 而跳过、而该地址其实在表里,下一个落在
  同一 cell 的对象就会继承一个幽灵项。I0 成立时不会发生;不成立时的
  表现是审计器的 `RememberedOwnerNotLive` / `RememberedOwnerMissingCache`。

### 8.3 已有的机器检查

I0 的**反方向已经被审计器逐对象强制**:
`verifyPublishedHeaderRepresentation` 的 `RememberedCacheWithoutOwner`
(bit=1/map=0)与 `verifyRepresentationInvariants` 尾部的
`RememberedOwnerMissingCache`(map=1/bit=0,kind 门为 object)在**每个收集
边界**上双向对账;`src/tests/core.zig` 的
「representation audit cross-checks the remembered object cache and map」
用真实屏障建立合法态后向两个方向各注入一次。也就是说 I0 不是纸面承诺,
它是现役的、双向的、有负面测试的不变量 —— 这是这把刀最强的准入证据。

### 8.4 不属于跳过范围的两件事

- `forget` 还负责 `young_count` 的递减(依据 `flags.young`,与映射无关)
  以及 `mutation_stats_enabled` 下的 `remembered_owners` 回写。**跳过只能
  裹住 `remembered.remove` 一行**,不能从函数头 early-return。
- `remembered_owners` 在跳过时不需要回写:跳过意味着 count 没变。

---

## 9. forget 跳过已落地 —— 机制成立,但**打空了**(2026-08-29)

基线 `23c65ef8`,分支 `gc/opus-forgetskip`。

**一句话结论:§8 授权的那把刀(以 `kind == .object` 为门的 bit7 跳过)在实现、
验证、门禁四关全过,但它在 splay / raytrace / earley-boyer 上的执行次数是
`0`。§5.1 定位的那 0.11G cycles 根本不由 `.object` 载体支付。**
真正付钱的是 `.shape` 和 `.var_ref`,它们**没有**成员缓存位。

### 9.1 落地的机制(融合一步)

`src/core/gc.zig:3985` `Registry.forgetGenerationalOwner`:

```zig
inline fn forgetGenerationalOwner(self: *Registry, header: *GCObjectHeader) void {
    if (header.metaConst().flags.kind == .object) {
        const summary = &header.meta().lifetime.trace.object_shape_summary;
        if (summary.* & trace_remembered_mask == 0) {
            self.generation.forgetUnremembered(header);
            return;
        }
        summary.* &= ~trace_remembered_mask;
    }
    self.generation.forget(header);
}
```

读位 / 删表 / 清位在同一个函数体内按这个顺序完成,§8.1 的结构性陷阱
(先清位、后按位判断 ⇒ 跳过恒真 ⇒ 映射项永不删除)**在实现层面不再可能写出来**。

`src/core/gc_generation.zig`:

- `forget`(:230)保留原语义(无条件 `remove` + young 普查 + `remembered_owners`
  回写),供有位、非 object、以及测试注入使用。
- `forgetUnremembered`(:247)= `forget` 减去映射删除。**只裹住 `remembered.remove`
  一行**(§8.4),young 普查照做;`remembered_owners` 不回写(count 没变)。
- `forgetYoungCensus`(:262)= 两条路径共享的 young 普查,保证「跳过」不会退化成
  函数头 early-return。
- `openRetirementWindow`(:271)/ `retirement_window_open` 字段 = I3 的机器闩。

### 9.2 I0–I5 逐条如何被守住

| 不变量 | 守护方式 | 位置 |
|---|---|---|
| **I0**(kind==.object ∧ bit7=0 ⇒ 不在映射) | `runtime_safety` 下**每次 detach** 在决策点断言 `!remembered.contains(header)`。不等收集边界的审计器事后报悬垂地址。 | `gc_generation.zig:254` |
| **I1**(非 object owner 入表但从不置位) | 跳过以 `flags.kind == .object` 为门;该字节与 `forget` 已读的 `flags.young` 同在 `BlockFlags`,门免费。 | `gc.zig:3986` |
| **I2**(置位只在 `rememberOwner` 成功后) | 未改动,注释入正文;I0 断言是它的下游检查器(破 I2 ⇒ map=1/bit=0 ⇒ 跳过路径的 `contains` 开火)。 | `gc.zig:3930-3939` |
| **I3**(位清、表未清的 STW 窗口) | **从注释升格为机器闩**:`retireGenerationalYoungSet` 开窗 → `clearGenerationalRememberedBits` → `retireYoungSet` 关窗;窗口内任何 `forget`/`forgetUnremembered` 断言开火。ReleaseFast 下两半都编译为空。 | `gc.zig:3960-3969`、`gc_generation.zig:231/250/271` |
| **I4**(三处整字节写 0 的顺序依赖) | `setHeaderWeakHusk` 在整字节清零**之前**断言 bit7 已清 —— 把 husk 标记提到注销之前会当场开火,而不是静默留下 bit=0/map=1。另两处(`resetHeaderLifetimeForPublication`、`finishGeneratorShell` 失败路径)不加断言:它们运行时 lifetime 字尚未初始化,断言会读到未定义字节。 | `gc.zig:1174` |
| **I5**(地址复用造幽灵项) | I0 的每次 detach 断言就是 I5 的上游拦截:幽灵项只能由「该删没删」产生,而那正是 I0 断言的开火条件。收集边界的 `RememberedOwnerNotLive` 保持为第二道网。 | 同 I0 |

新增回归测试 `forget fuses the remembered map removal with its own cache bit`
(`src/tests/core.zig:7519`):经真实屏障建立合法态 → 一次
`forgetGenerationalOwnerForTest` 之后**两种表示都必须消失** → 经生产屏障复原 →
再验「跳过路径仍然做 young 普查」。

### 9.3 注入验证(全部在 `trace_stw` Debug 构建下)

| 注入 | 期望开火的守卫 | 实际 |
|---|---|---|
| 恢复 §8.1 的旧顺序(`forgetGenerationalOwner` 开头加回 `clearGenerationalRememberedBit`) | I0 断言 | ✅ `panic: reached unreachable code` @ `gc_generation.zig:254 in forgetUnremembered`,由新回归测试触发 |
| 在 `clearGenerationalRememberedBits` 与 `retireYoungSet` 之间插一次 detach(位仍置) | I3 闩(full 路径) | ✅ @ `gc_generation.zig:231 in forget` |
| 同上,但挑一个 bit7 已清的对象 | I3 闩(skip 路径) | ✅ @ `gc_generation.zig:250 in forgetUnremembered` |
| husk 标记时对象仍被记住(`object_gc.zig:583` 前置位) | I4 顺序钉 | ✅ @ `gc.zig:1174 in setHeaderWeakHusk` |

> ⚠️ 三条方法学记录:
> 1. **第一次注入(不置位,破 I2)开火的是别人**——四个既有测试直接断言位必置,
>    在我的断言之前红。「触发了别的守卫」≠「你的守卫有效」,换成 §8.1 的旧顺序
>    才隔离出 I0 断言。
> 2. **旧顺序注入在改测试前是全绿的**:2457 passed / 0 failed。整个套件里**没有
>    一个用例会 detach 一个被记住的 owner**,所以 I0 断言当时零覆盖。新回归测试
>    正是为造出这个状态而写的。
> 3. **I4 在 `object.zig:2434` 的注入不开火,在 `object_gc.zig:583` 才开火**:
>    trace_stw 套件只走后一个 husk 入口。把 `setHeaderWeakHusk` 直接上提到注销
>    之前**不能**用来验证本断言 —— 那会先撞既有的 `!heap_accounted` 断言。

### 9.4 门禁

| 门 | 结果 |
|---|---|
| rc `zig build test` | 2380 passed / 96 skipped / **0 failed**(skip 比基线 +1 = 新用例在 rc 下 `SkipZigTest`) |
| trace `zig build test -Dzjs_experimental_gc=trace_stw` | 2458 passed / 19 skipped / **0 failed** |
| `tools/perf/gate_smoke.sh <trace ReleaseFast> /tmp/gcgap-fixed 18 3` | **all clean**(3 ordinary + 1 arena-audit/stats × 6 负载) |
| `ZJS_GC_ARENA_AUDIT=1` splay / raytrace / earley-boyer | 三者 rc=0,无 panic(双向审计器在其中) |
| rc ReleaseFast `.text` sha256 | `ea290b3d…f10faf2e`,**与 base 23c65ef8 逐字节相同** |

**分代机制在 rc 构建的可达性:不可达。** `gc.zig:107`
`generation_enabled = trace_stw_enabled`,`forgetGenerationalOwner` 的唯一调用点
(`unregisterLiveAddress`,`gc.zig:4209`)在 `if (comptime generation_enabled)` 里,
rc 下整条路径不被分析。`.text` 逐字节相同是这条判定的机器证据。

> ⚠️ 取 `.text` 时踩到一次坑:**同源码的两次 ReleaseFast 构建给出不同 `.text`**
> (3,580,592 vs 3,579,912 字节)。`nm -S` 逐符号 diff 显示差异全在
> `compiler.resolve_variables.*` / `bytecode.*` 等与 GC 无关的符号上,是 codegen
> 不确定性。判据取「候选构建两次都复现 base 的 sha」,而不是单次比较。

### 9.5 ⚠️ 靶子打空了:执行次数普查

在 `forgetGenerationalOwner` 入口按 `flags.kind` 插桩(临时构建,未提交),
fixed-work 负载,ReleaseFast + trace_stw:

| 负载 | detach 总数(截样) | `.object` | `.shape`(5) | `.var_ref`(2) | 走跳过路径 |
|---|---:|---:|---:|---:|---:|
| splay | 4,000,000 | **0** | 4,000,000 | 0 | **0** |
| raytrace | 48,000,000 | **0** | 45,132,159 | 2,867,841 | **0** |
| earley-boyer | 156,000,000 | **0** | 82,419,680 | 73,580,311 | **0** |

**三个负载上 `.object` 的 detach 次数是 0。** block cell 对象由位图清扫回收,
不走 `gc_obj_list` 的 `removeGcObjectAfter`;走这条路的是 list 载体
——`.shape` 和 `.var_ref`。它们由 `rememberGenerationalOwner` 的 **else 分支**
入表,按 I1 **从不置位**,所以 `kind == .object` 这道门把跳过判成了死代码。

指令数 A/B(交错三轮,`taskset -c 18`,`pmuv3_1/instructions`,中位数)与之一致:

| 负载 | base 中位数 | 候选中位数 | Δ | 臂内极差(base/cand) |
|---|---:|---:|---:|---:|
| splay | 33,797,551,281 | 33,768,044,025 | **−0.09%** | 0.29% / 0.04% |
| raytrace | 242,863,833,581 | 243,186,682,120 | **+0.13%** | 0.09% / 0.07% |
| earley-boyer | 478,346,855,469 | 478,560,421,511 | **+0.11%** | 0.10% / 0.26% |

三个方向都在臂内极差以内 = **零效应**,与「跳过执行 0 次」互相印证。

### 9.6 天花板定价:这条线值 splay −1.11% 指令

为给 driver 定价,另建一个**故意不 sound 的**实验构建(`forget` 完全不做
`remembered.remove`,只做 young 普查),同一交错三轮口径:

| 负载 | base 中位数 | 天花板中位数 | Δ | 臂内极差(base/ceil) |
|---|---:|---:|---:|---:|
| splay | 33,797,551,281 | 33,420,943,487 | **−1.11%** | 0.22% / 0.10% |
| earley-boyer | 478,346,855,469 | 475,619,910,435 | **−0.57%** | 0.07% / 0.15% |
| raytrace | 242,863,833,581 | 242,097,751,422 | **−0.32%** | 0.09% / 0.23% |

效应比臂内极差大 5–11 倍,是真的。**这条线还在,只是门开错了地方。**

### 9.7 要开对门需要什么(未实现,需 owner/driver 授权)

remember 侧同样插桩(else 分支按 kind 计数):

| 负载 | `.shape` 入表次数 | `.var_ref` 入表次数 |
|---|---:|---:|
| splay | **0** | 0 |
| raytrace | **0** | 1 |
| earley-boyer | **0** | 6,900,001 |

- **`.shape` 在三个负载上从不进入 remembered 映射**,却贡献 splay 100% /
  raytrace 94% / EB 53% 的 detach ⇒ splay 那 −1.11% 几乎全部是 shape 的空哈希。
- **`.var_ref` 会进表**(EB 690 万次)⇒ 它不能无条件跳过,必须有自己的缓存位。

自然的解法是把 bit7 从「Object 专用」升级为**全载体成员缓存**:
`TraceHeaderState.object_shape_summary` 的注释已经写明
「Non-Object carriers keep the whole byte zero」,bit7 对它们是空闲的。
但这**不在 §8 审计范围内**,而且已经查出四处硬阻塞:

1. **`.big_int` 必须排除,否则是灾难性别名。** `LifetimeWord` 是
   `union { rc: i32, trace: TraceHeaderState }`,而 `object_shape_summary` 在
   `TraceHeaderState` 的 offset 2 = i32 的第 3 个字节。trace_stw 下**只有
   big_int 仍用 `rc`**(`resetHeaderLifetimeForPublication` 对它特判)。给 big_int
   置 bit7 = `rc += 0x800000`。门必须写成 `kind != .big_int`,不是「非 object」。
2. **三处现役检查器强制「非 object ⇒ byte6 == 0」**,放开缓存位必须同步放宽:
   `assertInitialHeaderLifetime`(`gc.zig:1213`)、
   `verifyMetadataSemantics` 的 `.registry_published` 臂(`gc.zig:1673`)、
   循环/标记审计的 `InvalidHeaderState`(`gc.zig:4509`)。
3. **两个双向一致性审计器都以 `kind == .object` 为门**,必须同步扩到全载体,
   否则新缓存位对 `RememberedCacheWithoutOwner`(`gc.zig:4626`)/
   `RememberedOwnerMissingCache`(`gc.zig:4678`)**不可见** —— 这正是本轮
   §8.3「最强准入证据」会失效的地方。
4. **`clearGenerationalRememberedBits` 的 kind 门也要一起改**,否则批量清位漏掉
   非 object 居民,I3 窗口关闭后 bit=1/map=0 常驻。

做完 1–4 之后,`forgetGenerationalOwner` 的门从 `== .object` 改成 `!= .big_int`,
其余一行不动 —— 本轮落地的融合一步与三条机器检查就是为这个改动准备的地基。

**本轮不做**:它需要一份新的 soundness 审计(byte6 的所有权重划分),
而 §8 的授权明确限定在 `.object`。

---

## 10. byte6 所有权重划分审计 + 修正刀落地(2026-08-29)

基线 `f4ea32f1`,分支 `gc/opus-byte6`,worktree `/home/aneryu/worktrees/opus-byte6`。

**一句话结论:§9.7 的四处阻塞全部可解,审计放行全部六个 `gc_obj_list`
载体(不是 `!= .big_int`,是更精确也同样便宜的 `<= .shape`);另查出**第五处
阻塞**(`forgetUnremembered` 自己的 kind 断言)和**两处 §8.4 从未列出的整字节
写入者**。刀已落地,四门全绿,splay 指令 **−0.98%**,实现同基线天花板的
**83%**。**

### 10.1 门不是 `!= .big_int`,是「eligible」= 六个 list 载体

审计把两个排除项的**理由**分开看,发现它们是两件不同的事:

| 排除 | 理由 | 若放进来会怎样 |
|---|---|---|
| `.big_int` | 唯一在 trace 下仍用 `LifetimeWord.rc` 的 kind。byte6 = 该 `i32` 的第 3 字节 | 置位 = `rc += 0x800000`(§9.7 已定位) |
| **`.string`** | **根本没有 `Metadata` 前缀**(`PrefixModel.string_rc`,裸 4 字节计数) | `header.meta().lifetime` **不指向它的内存**——越界读写,不是语义错 |

`!= .big_int` 只挡住第一件。剩下的六个 kind(`object` / `function_bytecode` /
`var_ref` / `realm_context` / `module` / `shape`)恰好是:

- `RefKind` 枚举值 0..5 的**连续区间** ⇒ 门是**一次无符号比较**,与 `!= .big_int`
  同价、与被它替换的 `== .object` 同价;
- `refKindDescriptor(kind).cycle_candidate` **完全相同的集合**;
- 也就是 `gc_obj_list` 载体集,而这**恰好是能到达 remember/forget 两端的全集**
  ——remember 侧只经屏障(owner 只可能是 Object/VarRef/Module/Realm/Shape,
  见 §10.3),forget 侧只经 `removeGcObjectAfter`(只走 list 成员)。

所以谓词写成 `traceRememberedCacheEligible(kind) = @intFromEnum(kind) <= 5`,
并用 comptime 断言把三条重合关系钉住(逐 kind 枚举 + `cycle_candidate` 等价 +
`prefix == .metadata`)。**两个排除项因此不是「禁止但可能发生」,而是不可达。**

### 10.2 逐 kind 判决表

问题:①bit7 置位后有没有现役读者会误读?②有没有「仍在映射中」时抹掉 bit7 的
整字节写?③入表/离表时机是否闭环?

| kind | 前缀 | 能当 owner? | 会 detach? | ① 误读者 | ② 整字节写(仍在表时) | ③ 闭环 | 判决 |
|---|---|---|---|---|---|---|---|
| `.object` | metadata | 是 | 否(块位图清扫,§9.5) | 无(Object 自己 mask 低 7 位) | I4 三处 + 本轮新查两处,全部在注销后或发布前 | 是 | **已在(§8)** |
| `.function_bytecode` | metadata | **否**(无屏障点) | 是 | 无 | 仅分配器初始化 | 平凡(位恒 0 ⇒ 跳过恒对) | **放行** |
| `.var_ref` | metadata | **是**(`var_ref.zig:187/199/224`;EB 690 万次入表) | 是(EB 7,358 万) | 无 | 仅分配器初始化 | 是 | **放行** |
| `.realm_context` | metadata | 是(`context.zig:731/760`、`collection_ops.zig:708`) | 是 | 无 | 仅分配器初始化;**rc 在 body**(`traceRefCountPtr` = `self + off`) | 是 | **放行** |
| `.module` | metadata | 是(`module.zig:619/669/687/894`) | 是 | 无 | 仅分配器初始化 | 是,但见 §10.5 | **放行** |
| `.shape` | metadata | 是(`shape.zig:708` 换 proto) | 是(splay 100% / raytrace 94% / EB 53%) | 无 | 仅分配器初始化;**rc 在 body**(`ownership.trace_ref_count`) | 是 | **放行(splay 的钱在这)** |
| `.string` | **string_rc** | 否 | 否 | — | — | — | **排除(无前缀)** |
| `.big_int` | metadata | 否 | 是 | `prefixRefCount` 整 `i32` 读写 | `value.zig` 九处 `hdr.rc ±= 1` + `gc.zig` 两处 | — | **排除(别名)** |

①栏的依据:byte6 的**全部**语义读者都在 `object.zig`,receiver 是 `*Object`
(`traceShapeSummary*` / `storeTraceShapeSummary` / `commitTraceShapeAppend` /
`traceShapeSummaryMatches`),按构造只能作用在 `.object` 头上;`gc_trace_stw.zig`
与 `gc_marker.zig` **一次都没有**碰过这个字节,标记器只经 Object 的访问器到达它。
剩下的读者全是检查器(§10.4)。

③栏的依据:六个 list 载体的每条销毁路径都汇入 `unlinkObjectWithBytes` 或
`detachCycleCandidate{,After}`,两者都到 `removeGcObject{,After}` →
`unregisterLiveAddress` → `forgetGenerationalOwner`。条件收割的对象在
`detachCycleCandidateAfter` 时就已 forget 过,`unlinkObjectWithBytes` 的
`cycle_visited` 早退因此不是漏洞而是去重。`.var_ref` 具体走
`destroyVarRefNow`(`gc.zig:5023`),`.shape` 走 `shapes.destroyFromHeader` /
`shape.zig:782/925/1008/1097` 的替换路径,都在这条汇流里。

### 10.3 owner 侧的全集(遍历全部 76 个屏障调用点)

`generationalBarrier{,Value}` / `rememberOwnerForBulkWrite` 的 owner 参数,
按定义位置逐个核过,只有五种 kind:`.object`(绝大多数)、`.var_ref`
(`var_ref.zig`、`tailcall_dispatch.zig` 的 cell)、`.module`、`.realm_context`、
`.shape`。**`.function_bytecode` / `.string` / `.big_int` 一个调用点都没有。**
所以放行 `.function_bytecode` 是纯粹的「反正位恒 0」——它只是让门保持一次比较。

### 10.4 ②栏:整字节写入者的完整清单(§8.4 的三处实为**五处**)

§8.4 列了三处 `object_shape_summary` 整字节写 0。本轮做了一次不按字段名搜索的
普查(找整 `lifetime` 写、找 `lifetime.rc` 别名写、找 `meta + 4` 裸偏移写、
找整 `Metadata` 结构体存),又查出两处:

| # | 位置 | 形态 | kind | 是否危险 |
|---|---|---|---|---|
| 1 | `resetHeaderLifetimeForPublication`(`gc.zig`) | `lifetime.trace = .{}` | 非 big_int | 否——唯一调用者 `addWithSize` **在生产代码里没有调用点**(只有一个测试用) |
| 2 | `setHeaderWeakHusk` | 整字节 = 0 | `.object`(有断言) | 否——I4 顺序钉已在 §9.2 装好 |
| 3 | `finishGeneratorShell` 失败路径 | 整字节 = 0 | `.object` | 否——`registerObjectWithBytes` 刚失败,从未入表 |
| **4(新)** | **`object.zig:1790` `initInlineClassPayloadGcPrefix`** | **裸 `-8` 指针 + 整 `Metadata` 结构体存** | `.object` | 否——发布**之前**跑(`object.zig:1568` 早于 1572 的 `refreshTraceShapeSummary`),但**这个顺序没有任何代码强制** |
| **5(新)** | **`object.zig:85` `FinalizingShapeStorage` TLS** | 整 `Metadata` 字面量 | **`.shape`** | 否——该 tombstone 从不入 `gc_obj_list`、从不经 Registry API,故 forget 永不看它;万一入表,`RememberedOwnerNotLive` 是既有第二道网 |

另有一处值得记下来但不构成阻塞:**`gc_block_heap.zig:897 writeIntervalNode`
把 cell 索引写进空闲 cell 的 4..8 字节**,是生产代码里唯一往 byte6 写
**非零非计数**数据的地方。它只作用于空闲 cell,重新分配时
`initGcPrefixBlockCell` 会整字清零;所有「非 object ⇒ byte6==0」检查器都只遍历
存活种群,碰不到它。**但这意味着这类检查器永远不能被改成扫全堆。**

> ⚠️ 方法学:§8.4 的「三处」是按字段名 `object_shape_summary` 搜出来的,
> 第 4、5 两处**都不出现在那次搜索里**(一个是裸 `-8` + 整结构体存,一个是
> 结构体字面量默认值)。**要证明「没有别的整字节写者」,不能搜字段名,
> 必须搜承载它的每一种表达式形态。**

### 10.5 第五处阻塞:`forgetUnremembered` 自己的 kind 断言

§9.7 列了四处。实际上第五处在 `gc_generation.zig`:

```zig
pub fn forgetUnremembered(self: *State, header: *const gc.Header) void {
    std.debug.assert(header.metaConst().flags.kind == .object);   // <== 第五处
```

它不在 `gc.zig`,不含 `object_shape_summary` 字样,所以两轮 grep 都没扫到——
是编译后跑测试当场炸出来的。

### 10.6 一处**审计放行时才浮出来的现役异常**:module 先记后发布

放开门之后,`assertInitialHeaderLifetime`(§9.7 阻塞 2 的第一条)当场开火,
kind = **module**,summary = `0x80`,alloc_info = `0x80`(standalone、未 accounted)。
追下去是 `module.Registry.prepareFreshTarget`:

```zig
self.gc_registry.rememberOwnerForBulkWrite(&record.header);      // 先记
self.gc_registry.addInitializedWithSizeNoFail(&record.header, …); // 后发布
```

一个**尚未发布**的头 `flags.young == false`,屏障因此把它判成 old owner 并入表。
这是**既有行为**(map 项在改动前就已经产生,只是没有 bit 可看),不是本刀造成的;
但它说明「bit7 只能在发布后出现」这个假设是错的。

处理:把 `assertInitialHeaderLifetime` 的该行放宽为**只查低 7 位**——与另外两处
检查器同一形态。bit=1/map=1 在那一刻是**自洽**的,I0 要的就是自洽,它只是不
「initial」。**这条异常本身移交 driver**:它同时意味着一个刚发布的 young 头会短暂
出现在 remembered 映射里(`verifyGenerationInvariants` 的 `RememberedOwnerYoung`
条件),修法是把 `rememberOwnerForBulkWrite` 挪到发布之后——届时 owner 是 young,
屏障本就该早退,这次 remember 从语义上讲是多余的。**本轮不动,因为它改的是
module 语义不是 GC 表示。**

### 10.7 四(五)处阻塞的解除方式

| # | 阻塞 | 解除 |
|---|---|---|
| 1 | `.big_int` 别名 | 门 = `traceRememberedCacheEligible`(§10.1),连 `.string` 一起挡掉 |
| 2a | `assertInitialHeaderLifetime` 强制非 object ⇒ byte6==0 | 放宽为 `& trace_object_shape_summary_mask == 0`(理由见 §10.6) |
| 2b | `verifyMetadataSemantics` `.registry_published` 臂 | 按 kind 计算许可掩码:eligible ⇒ 只许 bit7,ineligible ⇒ 整字节仍须 0 |
| 2c | `verifyIntrusiveList` 的 `InvalidHeaderState` | 同上;list 成员全是 eligible,故只查低 7 位 |
| 3 | 两个双向审计器以 `kind == .object` 为门 | `RememberedCacheWithoutOwner` **移出** `.object` 臂、独立按 eligible 判;`RememberedOwnerMissingCache` 的门改 eligible。§8.3 的「最强准入证据」因此**跟着扩到新载体**,而不是被绕过 |
| 4 | `clearGenerationalRememberedBits` 的 kind 门 | `clearGenerationalRememberedBit` 改 eligible |
| **5** | `forgetUnremembered` 的 kind 断言(§10.5) | 改 eligible |

`forgetGenerationalOwner` / `rememberGenerationalOwner` 各改一行门,**函数体一行
不动**——§9.1 那次融合与 §9.2 的 I0–I5 机器闩就是为这一步准备的地基。

### 10.8 注入验证(全部在 `trace_stw` Debug 构建下,目标构建形态)

| 注入 | 期望开火的守卫 | 实际 |
|---|---|---|
| `clearGenerationalRememberedBit` 的门退回 `!= .object`(阻塞 4 复原) | 扩宽后的 `RememberedCacheWithoutOwner` | ✅ `panic: GC representation invariant violated` @ `gc.zig:4757 in verifyPublishedHeaderRepresentation`(注入构建多一行,现址 `gc.zig:4756`) |
| `rememberGenerationalOwner` 的门退回 `== .object`,forget 侧保持扩宽 ⇒ 非 object 载体 map=1/bit=0 | **I0 逐次 detach 断言** | ✅ `reached unreachable` @ `gc_generation.zig:260 in forgetUnremembered`(经 `gc.zig:4074 in forgetGenerationalOwner`) |
| `addInitializedShape` 入口给 shape 置**低 7 位**的一位 | 放宽后仍在的 `assertInitialHeaderLifetime` 低 7 位半 | ✅ `reached unreachable` @ `gc.zig:1260` |
| 已并入回归测试的四条:非 object 载体上 bit=1/map=0、map=1/bit=0、低 7 位污染 → `RepresentationPrefixFieldMismatch`、同一污染 → `InvalidHeaderState` | 四个扩宽后的检查器 | ✅ 全部以 `expectError` 常驻(新用例,见下) |

新增/改写的回归测试:

- **新增** `representation audit cross-checks the remembered cache on a non-object carrier`:
  用 **VarRef**(真正付 detach 的那个载体)经真实屏障建立合法态,再向
  `RememberedCacheWithoutOwner` / `RememberedOwnerMissingCache` 两个方向各注入一次,
  外加低 7 位污染的两条(表示审计 + list 审计),最后验融合 detach 一次清两个表示。
  §8.3 的准入证据**至此对新载体也成立**,而不是只对一个从不走这条路的 kind 成立。
- **改写** `non-object remembered owners retain the map fallback across consecutive minors`
  → `... use the byte-6 cache and re-arm across consecutive minors`。旧用例逐字断言
  「VarRef 的 byte6 恒为 0」——它编码的正是被本刀推翻的契约。新版断言 VarRef **会**
  带 bit7、且退休后**必须**被清掉;**第二轮循环是真正的判据**:漏清就会让第二次
  屏障因陈旧位早退、映射空转、minor 当场收掉活着的 child。

> ⚠️ 第一次注入(`clearGenerationalRememberedBit` 退回窄门)开火的是**审计器**
> 而不是 I0 断言——因为退休窗口清位漏掉非 object 居民,留下的是 bit=1/map=0,
> 而 I0 管的是反方向。两条注入合起来才把两个方向都证到,单跑任何一条都会
> 得到「我的守卫有效」的假结论。

### 10.9 门禁

| 门 | 结果 |
|---|---|
| rc `zig build test` | **2381 passed / 97 skipped / 0 failed** |
| trace `zig build test -Dzjs_experimental_gc=trace_stw` | **2460 passed / 19 skipped / 0 failed** |
| `tools/perf/gate_smoke.sh <trace ReleaseFast> /tmp/gcgap-fixed 17 3` | **all clean**(6 负载 ×(3 ordinary + 1 arena-audit/stats)) |
| `ZJS_GC_ARENA_AUDIT=1` splay / earley-boyer | 均 rc=0,无 panic(两个扩宽后的双向审计器在其中) |
| rc ReleaseFast `.text` sha256 | 候选两次构建均 `4ae26857…`(3,352,660 B)= **base 第一次构建逐字节相同** |

**rc 可达性:不可达。** `generation_enabled == trace_stw_enabled`;本轮改到的
每一处都在 `if (comptime trace_stw_enabled)` / `if (comptime generation_enabled)`
之内,或者是 comptime 谓词/注释/测试。

> ⚠️ §9.4 记的坑再现且更严重:**base 自己两次 ReleaseFast 构建的 `.text` 就不同**
> (`4ae26857…` 3,352,660 B vs `3babaeee…` 3,353,280 B)。所以「与 base 逐字节相同」
> 这个判据只能取「**候选两次都复现 base 的某次 sha**」;本轮候选两次完全一致
> 且命中 base 的第一次,是这个口径下能拿到的最强结果。

### 10.10 指令数:与**同基线**天花板对账

`taskset -c 19`(mpstat 五大核确认 15/17/18/19 idle ≥ 99.5%,16 被另一 agent 占),
`armv8_pmuv3_1/instructions`,**交错三轮且逐轮换臂序**(base→cand / cand→base /
base→cand),取中位数。

| 负载 | base 中位数 | 候选中位数 | **Δ** | 臂内极差(base/cand) |
|---|---:|---:|---:|---:|
| splay | 33,145,943,966 | 32,820,899,847 | **−0.98%** | 0.33% / 0.02% |
| earley-boyer | 474,561,171,955 | 471,148,728,230 | **−0.72%** | 0.08% / 0.24% |
| raytrace | 241,420,806,940 | 239,828,478,258 | **−0.66%** | 0.30% / 0.37% |

对着 §9.6 的天花板读,EB(−0.72 vs −0.57)和 raytrace(−0.66 vs −0.32)**都超了
天花板**。这是不可能的,所以先别报——**回去在本基线上重测天花板**(同样的
不 sound 构建:`forget` 完全不做 `remembered.remove`,从 `f4ea32f1` 起改):

| 负载 | 本基线天花板 | 候选实现的比例 | §9.6 天花板(基线 `23c65ef8`) |
|---|---:|---:|---:|
| splay | **−1.18%** | **83%** | −1.11% |
| earley-boyer | **−0.67%** | **107%**(臂内极差 0.20–0.24% ⇒ 与 100% 不可分辨) | −0.57% |
| raytrace | **−0.67%** | **98%** | −0.32% |

**「超天花板」是基线漂移的假象,不是真效应。** raytrace 的这条线在
`23c65ef8` 上值 −0.32%,在 `f4ea32f1` 上值 −0.67%,翻了一倍。这是记忆里
「跨会话对比不可做刀级归因」的又一次实例,换了件衣服:**一个在别的 base 上
测的天花板,不是这个 base 的天花板。**

差距的诚实解读:splay 剩下的 17% 正是简报预判的「跳过仍要读位」——每次 detach
仍付一次字节加载 + 掩码 + 分支,只是不再付 Wyhash + 开放寻址探测。EB/raytrace
已在测量分辨力内打满。

### 10.11 移交

1. **§10.6 的 module 先记后发布**:`prepareFreshTarget` 把
   `rememberOwnerForBulkWrite` 挪到 `addInitializedWithSizeNoFail` 之后。改的是
   module 语义,不在本轮范围。
2. **§10.4 第 4 处的顺序无人强制**:`initInlineClassPayloadGcPrefix` 整
   `Metadata` 覆盖必须早于任何 summary/remember 写,今天成立但没有断言。
3. **§10.4 的 `writeIntervalNode`**:空闲 block cell 的 byte6 携带非零索引残留 ⇒
   任何把「非 object ⇒ byte6==0」检查器改成扫全堆的想法都会当场假红。
