# GC 简化评审（2026-09-21）

Owner 令：「简化 GC 的实现，也让它更符合 Zig」。形态层（表达方式）已按第 1 节落地；
本文是机制层（语义本身）的评审，按 owner 裁决「允许触及机制，先出评审再动」提交。

语义权威仍是 `docs/gc-invariants.md`；本文只讨论**在不改变可观测行为的前提下，
哪些机制是可以合并或退役的**，以及各自的代价。

## 1. 已落地（形态层，五刀，净 −2,033 行）

| Commit | 内容 | 行数 |
|---|---|---|
| `691b45ea` | 退役 R3 保守根普查（`gc_conservative_diag.zig`）与 `-Dzjs_gc_roots_diag` 构建维度 | −1,376 |
| `1ac9dce1` | 11 个进程级旋钮 → `Forensics` 三字段；顺带修「诊断向被审计的堆记账」 | −140 |
| `c27d24cb` | 手写 formatter → `std.fmt`；`hexPad` → `value_format.hex4` | −609 |
| `ffef7366` | verify/audit 改 comptime 门控（ReleaseFast `zjs` −155,896 B） | +30 |
| `805ccd47` | carrier 六个恒等 gate → 一个 `carrier.audit_enabled`（158 调用点） | +62 |

形态层还剩三项，均为小额且无争议，随后续刀顺带做：`gc.zig` 尾部 18 个
`pub const x = registry_diagnostics.x` 别名墙、13 个编译期阈值常量与 `Policy`
的关系未标注、`gc_block_heap.zig` 中 >200 行的函数若干。

**明确不动**：`gc_visit.zig` 的 14 处 `anytype` 是 comptime visitor 协议，
在 Zig 里是惯用法而非 C 遗留；13 个 `GcKind` 的 `representation_kind_catalog`
是单一事实表，拆开只会变差。

## 2. 现状测绘

15,497 行 / 19 文件。核心机制占 ~11k：

| 文件 | 行 | 角色 |
|---|---|---|
| `gc_block_heap.zig` | 4,156 | block/superblock/extent 分配器，89 个函数 |
| `gc.zig` | 3,952 | Registry：分配、发布、载体判定、根、策略 |
| `gc_trace_stw.zig` | 2,856 | 收集器本体（后 1,100 行是 `Collector`） |
| `gc_address_registry.zig` | 719 | 保守候选的几何索引 |
| `gc_registry_diagnostics.zig` | 812 | 16 个 `verify*` + 统计快照（已 comptime 门控） |
| 其余 9 个 | ~1,400 | generation / incremental / mark_queue / space / visit / lists / pins / heap / carrier |

### 复杂度的真实来源

不是代码风格，是**同一个问题有多个并存的权威**：

- **成员资格有 4 个活结构**：`lists.objects`（侵入链表，非 Object 载体）、
  `nonblock_objects.items`（ArrayList，装不进 block cell 的 Object）、
  block 分配位图、extent 表。
- **外加 3 个死结构**：`morgue.by_kind`（13 条侵入链表）、
  `nonblock_objects.doomed`、block doomed 位图。
- **根有 2 条轨**：精确根（生产只链 container/window frame）+ 保守栈/寄存器扫描。
  后者的存在强制了 `gc_address_registry` 的全部 719 行。
- **销毁有 2 个阶段 × 2 种粒度**：condemn → morgue，slice（带 ns 预算）/ whole。

七个成员资格结构里，每一个都有充分的**局部**理由（见各自文件头注释，
本评审核对过，无一是历史残留）。问题在于它们的**乘积**：任何一次
「这个 header 现在属于谁」的推理要跨七个结构，而 `containsHeader`
（`gc.zig:3848`）确实是逐个问过来的。

## 3. 候选

### M1 — 退役保守扫描（R1）

**删除面**：`gc_conservative.zig` 338 行整删、`gc_address_registry.zig` 719 行
的大部分（它唯一的消费者是保守候选验证）、`Collector.seedConservativeRoots` /
`shadeConservativeCandidate`、每次收集的 `rebuildScanFilter`、
`computeFullReachable` 的保守臂与 `conservative_only_young` 统计、
`GCRootScan` 的 `engine_active`/`declared_only` 二分。估 **−1.2k 行**，
且每次收集省一次全栈扫描 + 每次分配省一次地址索引 insert/remove。

**前置条件**：每个跨分配点持有堆引用的 Zig 局部都必须有精确根。

**关键障碍（已记录，非推测）**：`gc-invariants.md:152` 记的 R1-a/c/d 结论是——
六个可归因窗口里只有一个是真缺根，其余是 LLVM 栈槽残留与 caller 侧
callee-saved spill，**加根修不了**。这条结论说的是「保守扫描多保活了垃圾」，
它不能反过来证明「保守扫描没有在保活真正需要的东西」。要退役必须换工具：
不是动态普查（R3 已证无用，已删），而是**静态审计**——枚举每个可触发收集的
调用点，证明其调用者栈上的每个堆引用都在一个 `ValueRootFrame` 里。

**风险**：最高。一个漏掉的局部 = use-after-free，且只在特定分配历史下出现
（正是 `ZJS_GC_STRESS` 存在的理由）。

**建议**：单独立项，不并入本轮。先做静态审计工具，工具绿了再谈退役。

### M2 — 消灭非 block Object 这一整条路径

**现状**：`nonblock_objects` 是 Object 专用的侧权威，仅服务于
「装不进 block cell（>3760 B）的 Object」。它存在是因为 Object 的 64 B 布局
没有链表指针词，进不了 `lists.objects`（`gc.zig:1909`）。

**候选**：让超大 Object 走 extent 表（它们本来就是 standalone 前缀），
与 string extent 同一条路径。删掉 `NonBlockObjectAuthority`
（`gc_registry_heap.zig` 后半）、`Registry` 上的 optional 字段与其 8 处分支、
`containsHeader` / 三处迭代器 / 条件销毁里的 nonblock 臂。估 **−300~500 行**，
活结构 4→3、死结构 3→2。

**需先验证**：超大 Object 的实际发生率（注释称 "the rare non-block
population"，但没有数字）。若发生率为零或接近零，更彻底的做法是
**让它根本不存在**——给 Object 的分配路径加一个「超过 cell 上限就用 extent」
的分支，而不是加一个成员资格结构。

**风险**：中。extent 表的标记/清扫路径（`extentSetMark`/`sweepExtents`）
目前假设载体是字符串家族，需要确认它对 Object 的 finalizer 与
`needs_finalizer` 语义成立。

### M3 — 影子审计权威（carrier）退役

**现状**：刀 5 后是一个 gate、332 行，外加 `memory.zig` 与
`gc_block_heap.zig` 里 ~156 个 `if (comptime carrier_audit_enabled)` 调用点
与对应的 `if (enabled) T else void` 字段。仅在测试与
`-Dzjs_ownership_audit` 构建里存在。

**它验证什么**：raw 分配与发布之间的 ABA（generation）与 lifecycle 状态机。

**待答问题**：这两个不变量现在是否已被别的东西覆盖？
`condemned_mark_epoch`（`gc.zig:1026`）给了每个 kind O(1) 的死亡判定，
block 位图给了 O(1) 的活成员判定，两者都是 S4-h 之后才有的。
carrier 的 generation 是 S2 时代为「非 block 分配的 ABA」设计的，
而非 block 分配现在只剩 extent 一条路。若 M2 落地，extent 表自身
就是唯一权威，generation 表可能变成第二份同样的事实。

**估**：−400 行（含调用点与 `if (enabled) T else void` 字段展开）。
**风险**：中。代价是测试期取证能力下降——这正是 owner 在本轮开头裁的
「删已结案的，留生产不变量」的边界处，需要单独裁决。

### M4 — 增量销毁的预算机制

**现状**：`destroyCondemnedSlice`(ns 预算) / `destroyCondemnedWhole` /
`destroyDoomedSlice` / `finishPendingDestruction` 四个入口，加
`Morgue.kind_pass` + `cursor` 的跨 slice 续跑状态。

**动机质疑**：这套机制的收益是 p99 停顿。`morgue` 的实际大小分布没有数据
（`gc: doomed` 行有 endpoint 快照，但没有分布）。若典型 morgue 是数十个对象，
slice 机制是纯开销 + 一个跨 slice 可变状态。

**先量后切**：给 `--gc-stats` 加一行 morgue 大小分布，跑 Octane + test262，
再决定。估 **−300 行**（若判定可删）。**风险**：低（可测量可回退）。

### M5 — morgue 的 13 条链表

**现状**：`Morgue.by_kind` 是 13 条侵入链表，为的是让销毁按
objects→realms→modules→bytecode→var_refs→shapes 的顺序各访问一次
（`gc_incremental.zig:178` 有完整理由）。

**评审结论：不动**。理由充分、代价（一次遍历 vs 五次）有记录，
换成数组只是把链表维护换成分配，不是简化。列在这里是为了记录「看过了」。

## 4. 建议刀序

1. **M4 先量**（低风险、可能白赚 300 行）：加 morgue 分布统计 → 跑 → 判决。
2. **M2**（中风险、结构性收益）：先量超大 Object 发生率 → 若接近零，
   走「让它不存在」而非「换个结构装它」。
3. **M3**（需 owner 裁决取证能力的取舍）：等 M2 落地后重新评估，
   因为 M2 会改变 carrier generation 的必要性。
4. **M1 单独立项**：先做静态根审计工具，不在本轮。

每刀一个 commit，验证 = `zig build check` → `zig build test` →
`zig build test-gc-stress`；触及分配/标记热路径的加 ReleaseFast 构建与
Octane ≥0.95 回归门。

## 5. 待 owner 裁决

- **D1**：M3（carrier 影子权威）的取证能力可以放弃吗？它只在测试构建存在，
  代价是下次 GC 出现载体身份缺陷时的取证手段。
- **D2**：M2 若选「让超大 Object 不存在」，需要给 Object 分配路径加一个
  extent 分支——这是**热路径**改动（`Registry.publish`），按
  `refactor-policy.md` 属 HOT 区，需要逐项落地而非一次扫荡。确认走这条？
- **D3**：M1 的静态根审计工具值得单独投入吗？它是退役保守扫描的唯一入口，
  而保守扫描是目前 `gc_address_registry.zig` 719 行存在的全部理由。
