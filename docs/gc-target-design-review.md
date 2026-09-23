# GC 目标形态评审（2026-09-21）

状态：历史评审与迁移记录。§1–4 是 2026-09-21 实施前的差距快照，
§5 记录后续阶段交付；不能把两者合读为当前实现清单。现行 GC 契约见
[GC invariants](gc-invariants.md)，Runtime 所有权见
[活动设计](runtime-target-design.md)。nursery 的最新阻塞与实施顺序以
[nursery 评估](runtime-nursery-todo.md) 为准。

Owner 给定的目标设计：

> T1 精确 tracing
> T2 年轻代单区 bump + STW copying
> T3 老区不搬的 mark-sweep（碎了再 compact）
> T4 根只有 VM 栈槽、HandleScope 槽和 Persistent
> T5 生产不扫原生栈
> T6 leaf builtin 靠 `Effect.may_alloc=false` 用裸指针，其余跨 GC 进槽
> T7 不增量
> T8 不上 Immix
> T9 堆不当 Allocator

本文按这九条评审现状，给差距、代价与迁移路径。语义权威仍是
`docs/gc-invariants.md`。形态层的五刀（−2,033 行）见第 6 节，与本设计无冲突。

## 1. 逐条差距（实施前快照）

| 条 | 现状 | 差距 |
|---|---|---|
| T1 精确 | 精确根 + **保守栈/寄存器扫描兜底**（`gc_conservative.zig`，生产路径） | 大 |
| T2 copying nursery | **sticky mark bit**：young 原地不动，`allocated && !marked` 即 young，survive 一次 minor 就变 old，无复制/无晋升队列。分配走 block heap size-class cell | **最大：nursery 不存在** |
| T3 老区 mark-sweep 不搬 | 已经是非移动 mark-sweep（block 位图 + extent 表） | 小：只缺 compact |
| T4 根三类 | 根有 **11 类**（见下） | 中 |
| T5 不扫原生栈 | 生产就是靠扫原生栈 | 同 T1 |
| T6 Effect 标注 | **不存在**。`NativeEntry` 无效应字段 | 中：新机制 |
| T7 不增量 | 有增量标记：`gc_incremental.zig` 246 行 + `beginIncrementalCycle`/`incrementalMarkStep`/`finishIncrementalCycle` + SATB 屏障臂 | **纯删除，可立刻做** |
| T8 不上 Immix | block heap 是 block + 分配位图 + size class，**不是** Immix 的 line marking | 已满足 |
| T9 堆不当 Allocator | GC 对象走 `Heap.allocCell` / extent，不经 `std.mem.Allocator`；`MemoryAccount` 的 allocator 门面只服务非 GC 数据（parser、hashmap 等） | 已满足 |

当前根的 11 类（`runtime.zig:2342` `traceRoots`）：value root frames、
`current_exception`、local root slots、persistent root slots、
deferred class payload roots、同 finalizers、job queue、`weakref_kept_alive`、
root providers、string cache、atom roots。

## 2. 比预期有利的三件事

勘察中最重要的发现是**目标设计要的基础设施已经存在**，只是没有在引擎内部使用：

1. **HandleScope / LocalHandle / Persistent 已实现**（`runtime.zig:1009`、`:945`）。
   槽存在 `local_root_slots` / `persistent_root_slots` 两个 `ArrayListUnmanaged(*RootSlot)`
   里——**槽在独立数组中**，正是目标形态。当前引擎内部使用量为 **0**：
   它只服务 embedder API。
2. **VM 栈槽已经是精确根**。`active_invocation_trace` 对 Frame 的
   this/function/args/locals/var_refs 与 Stack 活前缀做精确 walk
   （`value_root_frames_enabled` 恒真）。T4 的第一类根现成。
3. **IC 对移动友好**。`PropSiteCache.guard_key = object.shape_ref.identity`
   （`vm_property_field.zig:1517`）是 shape 的**身份号**而非地址，
   `slot` 是 shape 内槽号。移动不会让站点缓存失效为错误答案。

## 3. 真正的代价：移动式的前置条件

T2 是整个设计的重心，它要求**每一个指向 young 对象的引用都能被枚举并写回**。
逐项核对现状：

**已满足**
- `traceChildEdges` 的 visitor 收 `*JSValue` / `*?*Object`，可写回。
- 根槽（local/persistent）是 `*RootSlot`，`visitor.value(&slot.value)` 可写回。
- remembered set 是 **by owner** 而非 by slot（`gc_generation.zig:218`）。
  minor 重新 trace owner 时会经过 owner 的每个槽，因此对 copying **兼容**——
  这一点比 by-slot 设计更省事。
- 对象的 payload cell（property_storage / array_storage / payload /
  string_buffer）是 owner 的子边，随 owner 的 trace 一起更新。

**不满足，是具体障碍**
- **`visitor.constValue` 的 13 个根是只读的**（`traceStringCacheRoots`：
  `single_byte_strings`、`percent_hex_strings`、`small_int_strings`、
  `empty_string`、`recent_two_unit_string`、`recent_atom_strings`）。
  这些缓存持有 string 指针且标记为不可写回，移动会留下悬垂。
  改造成可写槽是小工作量，但**必须在 nursery 上线前做完**。
- **引擎内部的 Zig 局部裸指针**。这是全部代价的所在：生产的
  `value_root_link_containers_only` 只链 container/window 帧，标量帧不链，
  兜底的就是保守扫描。91 处 `ValueRootFrame{...}` 字面量、472 处 `activate()`
  是现有覆盖面；316 处可能触发收集的调用点是分母的下界。
- **pin 与移动互斥**。construction pin（未安装 shape 的 generator 壳）
  与 host pin 都要求地址稳定。nursery 里被 pin 的对象必须强制晋升或禁止进
  nursery。

## 4. T6 是关键杠杆，而不是优化

`Effect.may_alloc=false` 不是性能开关，它是**让第 3 节的最后一项变得可做**
的机制。没有它，"所有跨 GC 点的裸指针进槽"是一个对 316+ 调用点的无边界改造；
有了它，改造面收缩成：

1. 给每个 builtin / 引擎内部函数标注 `may_alloc`；
2. 编译期传播：调用了 `may_alloc=true` 的函数，自己也是 `true`；
3. 只有 `may_alloc=true` 的函数体内跨调用存活的堆引用需要进槽。

Zig 能在 comptime 做这件事（把效应做成函数元数据 + 调用点断言），
但**它不能自动找出漏标的地方**——漏标一个 `may_alloc` 就是一个
use-after-free。所以效应标注本身需要一个验证器，见第 5 节。

## 5. 迁移路径

关键的排序洞察：**移动本身就是最好的根验证器**，比任何静态审计都可靠。
from-space 毒化 + `ZJS_GC_STRESS` 下，一个没进槽的裸指针会立刻读到毒字节而崩，
而不是像保守扫描差分那样淹没在 LLVM 栈槽残留的假阳性里（R3 已经证明那条路
走不通，普查已删）。

因此推荐顺序是「让移动先跑起来，用保守扫描当临时安全网」，而不是
「先把根做到 100% 精确，再上移动」：

**P0 — 删增量（T7）✅ 已完成**（`4b54a872` + `743a3a7b`）。实际删除面比估计的大：

- 三个增量入口、poll 驱动的标记/销毁切片、分配 assist 债务、`major_marking_active`
  及其 109 处分支；
- 写屏障的 incremental-update 臂、黑分配（`publishGreyCold`）、atom 表的
  Dijkstra 插入屏障与出生 epoch 戳；
- **共享 mark frontier 整个消失**：`gc_mark_queue.zig` 384 行、`frontierEpochSafe`
  的 kind 分裂、admission 证明与跨 slice 的 drain 路径。STW 下 mutator 不可能在
  shade 与 pop 之间释放对象，这套机制的前提不存在。
- 25 个死 `Stats` 字段与 4 个 `--gc-stats` 面板。

**顺带修了两个真缺陷**（都被增量的延迟掩盖）：value symbol 的 atom 条目在
自己 body 的分配窗口内无根；`promiseReactionRecord` 的测试在裸 Zig 局部里
并排持有四个 symbol。

**实测**：GC 源码 17,521 → 14,315 行；ReleaseFast `zjs` 累计 −365,560 字节；
`zig build test`、`test-gc-stress`、`test262-check` 全绿，
`ZJS_GC_STRESS=1` 下 test262 **0/49777**。

**P1 — 根收敛（T4）✅ 已完成**（`922791ac` + `fcf92406`）。
`RootVisitor.constValue` 传的是调用者值的**副本**，移动后无处写回。
string cache 的 13 个根、atom 表的预定义体与年轻 symbol 体改用
`stringSlot`/`stringField`；`PoppedWindow` 用 `mutable` 视图而非借用。
同一个问题在**边**上也存在：`storageCell` 传 header、`stringBody` 传体，
都改成传槽（`CellSlot` 额外携带 bytecode function `home_or_aux` 的 tag 位）。

两处仍是只读并已标注：`Machine.l0` 是 `*const`，其 generator shell 槽要等
nursery 落地时改可变；`ValueRootSlice.borrowed` 窗口（最大population 是
native call 的 argv）由 T6 的 `Effect.may_alloc` 决定——不能分配的 builtin
可以借用，能分配的必须复制进槽。

**P2 — copying nursery（T2）🚧 骨架完成，开关关闭**
（`7487b571` + `ab1ae06b` + `603834d5`）。已落地：

- `gc_nursery.zig`：bump 页、复用表、pin 保留页、线性 walker，带自测；
- 载体身份：`alloc_info` 的**空闲位**（不是 class 值——slab 的 31 个 class
  加 block-cell 判别式把 5 位字段占满了，取 0x1e 会让每个 512 B slab 对象
  读成 nursery 并掉出成员资格，这是实测抓到的）；
- forwarding：复用 `condemned_mark_epoch` 的 tri-state 字段，地址进体首字，
  尺寸存在旁边（首字被占后对象无法自述大小，而页遍历需要每个 cell 的尺寸）；
- 疏散：`visitValue`/`visitObject` 把槽交给 `evacuate`，复制 + 写回 + 转发；
- 晋升的正规分配入口 `allocPromotedObjectCell`（限额、计账、carrier 账本、诊断）；
- pin：ledger pin 是真 pin（generator shell 无 Shape、按地址索引），
  保守扫描的 pin 则让**页**留存而对象照常移动——陈旧的原生字仍读到转发头，
  真缺根则立刻崩，这正是目的。

**当时实测进度（历史记录）**：开关打开时 1,973 个测试 **1,811 通过 / 50 失败 / 107 崩溃**
（首轮是 760 崩溃，两轮记账修复降到 53）。剩余失败集中在一处：
**销毁路径需要为 nursery 载体分流**——`destroyFromHeader` 会退还一条
bump 分配的 cell 从未登记过的 carrier 记录，并试图释放属于页的内存。
这是该阶段记录的下一步。2026-09-23 的探针又复现了默认 off 销毁断言
和 on 路径对象类型断言；现行阻塞见 [nursery 评估](runtime-nursery-todo.md)，
不能据本段旧结果认定剩余失败只有销毁分流。

**P3 — Effect 标注（T6）+ 把 pin 计数打到 0**。按 P2 报出的 pin 热点
逐个改造为槽，`may_alloc` 标注跟着改造走而不是先行普查。

**P4 — 删保守扫描（T1/T5）**。判据是 P3 的 pin 计数在全量 test262 +
Octane + stress 下恒为 0。删 `gc_conservative.zig` 338 行、
`gc_address_registry.zig` 719 行的大部分、`GCRootScan` 二分。

**P5 — 老区 compact（T3）**。最后做，因为它复用 P2 的移动基础设施
（forwarding、根写回），且只在碎片率超阈值时触发。

## 5b. 调试这套东西的方法（实测有效的四件事）

移动式收集器的缺陷有一个共同特征：**症状离病因很远**。一个没更新的边不会当场出错，
它会在几十万次分配之后，以一个无关位置的 corrupt switch value 出现。
下面四件事把定位成本从「一次全量换一个 bug」降到「一次全量换一类 bug」。

1. **主动扫描，不要等崩溃**。`auditNoEdgesIntoNursery` 在页回收前遍历老区，
   报告任何还指向 nursery 的指针，并打印 owner 与 target 的完整状态
   （young / remembered / marked / epoch / class）。自引用指针那个缺陷
   （slots2 的 `prop_values` 指向对象自身尾部）就是它一次报出来的。
   ⚠️只检查**活**的 owner：未标记的对象是垃圾，它的边无需更新，否则全是误报。
2. **毒化 from-space**。疏散后把 body（首字之后）填 `0xDE`。不毒化时，husk 还留着
   旧字段值，持有裸指针的代码会继续「正常工作」一段时间再在别处崩；
   毒化后它崩在使用现场，栈直接指向缺根的那一行。
3. **调低收集阈值制造压力**，不要靠运气。把 `collection_trigger_bytes` 从
   4×page 降到 4 KiB，单个测试就能触发上百次 minor，原本只在全量里偶发的问题
   变成秒级稳定复现。
4. **按栈顶分组，不要按崩溃类型分组**。`panic: reached unreachable` 出现 34 次
   不代表 34 个缺陷；把每个失败的**第一个** zjs 源码帧提取出来聚类，
   44 个失败落到 6 个位置，其中 3 个位置对应 3 个结构性原因。

⚠️同样重要的是**不要**做的事：把全量测试当调试器。一轮 8-9 分钟只能换一个根因，
而上面四件事让同样的一轮换一类。

## 6. 收益的诚实估计

**不是行数**。粗算：删 −2,300（增量 + 保守扫描 + address registry + young 旧机制），
增 +900（nursery、compact、effect、handle 改造），净 −1,400 行，
叠加已落地的 −2,033，GC 约到 12k 行。

**真正的收益是两个数字**：

- **成员资格权威 7 → 3**。现状活 4（`lists.objects` / `nonblock_objects.items` /
  block 位图 / extent 表）+ 死 3（`morgue.by_kind` 13 链表 /
  `nonblock_objects.doomed` / block doomed 位图）。目标形态是
  nursery 区间 + 老区位图 + extent 表，死集合随 STW copying 消失
  （nursery 不需要死名单，没复制走的就是死的）。
  `containsHeader` 从逐个问七个结构变成两次范围判断。
- **根 11 类 → 3 类**，且每类都可写回。

次要收益：young 分配从 size-class cell 查表变成 bump 指针；
minor 从"标记 + 清扫 + 晋升 + 退休事务"变成"复制存活者"，
死对象零成本（这正是 2026-08 splay 账里 rc 的即时释放所拥有、
而 sticky mark 拿不到的那部分）。

## 7. 风险与不做的事

- **这不是整理，是重写**。P2 单独就大于此前五刀的总和。建议按 P0→P5
  分批合入 main，每批独立绿门，而不是长活分支。
- **T8（不上 Immix）意味着老区保持现状**：block + 位图 + size class。
  现有 4,156 行的 `gc_block_heap.zig` 主体保留，不在本设计的删除面内。
- **性能不能假设更好**。copying nursery 的分配更快、死对象更便宜，
  但多一次复制；Octane ≥0.95 回归门按 `perf-line-closed` 裁决仍然有效，
  P2 合入前必须过。

## 8. 已定的三个选择

Owner 令「不要太保守，大刀阔斧」，以下三项按评审自行裁定，不再等批复；
认为选错了直接推翻即可。

- **P0 立刻做**，不作为提案。删增量无依赖、纯删除、−600 行，
  且让后续每一步少一个推理维度。
- **保守扫描在 P2/P3 期间降级为 pinning 网，不直接删**。扫到的候选从
  「标记为活」变成「钉住不许移动」并计数，计数即是 P3 的判决仪表。
  这是 Chrome 走过的迁移路线。替代方案（先做完精确根再上移动）被否：
  它让 P3 没有仪表，只能靠静态审计，而 R3 已经证明那条路不可靠。
- **`Effect.may_alloc` 标注引擎内部函数，不只标 builtin**。只标 builtin
  覆盖不到 VM 内部的分配点，而那正是裸指针最密的地方。侵入性由
  comptime 传播吸收：叶子标注，调用者推导。
