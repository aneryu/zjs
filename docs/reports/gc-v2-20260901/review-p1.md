> 注：原始二进制证据在临时 worktree，未入库。

# GC v2 P1 对抗式交叉评审

- 被审对象：`gc/p1-oldspace-20260831@b340faf3`
- 对比基线：`7c067f01`
- 评审方式：只读；未改被审分支，未 commit，未 push
- **Verdict：REJECT**

`b340faf3` 删除了唯一独立的 byte ledger，随后让 `statsSnapshot` 和
`verifyHeapAccounting` 的期望值/实际值都来自同一个 ownership walk。只要某次
owner 挂接遗漏，一个仍已分配、仍标记为 `heap_accounted` 的对象就会同时从比较
两侧消失。父提交/候选提交的同一 mutant 已证明这不是纯思想实验。此外，
terminal `doomed_pending` 下的新统计会计入 block corpse，却漏掉语义等价的
non-block corpse。

## 发现清单（按严重度）

### HIGH / blocking：heap-accounting audit 退化为同源自比较

代码证据：

- `deriveHeapSpaceSnapshot` 枚举 `heapAccountingIterator`：
  `src/core/gc.zig:2545-2563`。
- `verifyHeapAccounting` 虽然另建了局部计数器，但枚举的是同一个 iterator，
  随后又与 `statsSnapshot` 比较；后者仍调用 `deriveHeapSpaceSnapshot`：
  `src/core/gc.zig:5016-5050`、`src/core/gc.zig:5074-5079`、
  `src/core/gc.zig:2566-2571`。
- 该 accounting population 只有普通 object iterator 加两个单对象 callback slot：
  `src/core/gc.zig:3115-3154`。
- 父提交的审计把 ownership walk 与独立维护的
  `old_space.live_bytes + large_space.live_bytes` 对比（`7c067f01`，
  `src/core/gc.zig:5040-5094`）。

Mutant：发布一个已计费的 standalone `Object`，按 condemnation 路径将它从
普通 list detach，但故意漏掉 `doomed_by_kind` 挂接。对象内存仍存在，
`heap_accounted` 仍为真，`verifyIntrusiveList` 也合法。旧 ledger 仍持有它的
bytes，所以能发现 owner edge 丢失；P1 从不完整 walk 同时派生比较两侧，错误地
返回成功。

草稿在 `.scratch/REVIEW_P1_ORPHAN_MUTANT.patch`。我把同一测试分别应用到 detached
base/candidate worktree，并执行：

```text
zig build test-core --summary all -- 'review probe: heap accounting rejects an orphaned accounted standalone header'
```

结果：

```text
base 7c067f01:      1 passed, 0 failed, 465 filtered
candidate b340faf3: 0 passed, 1 failed, 465 filtered
candidate failure: expected error.HeapLiveBytesMismatch, found void
```

这直接否定了 brief 要求的“旧审计能抓住的缺陷，新审计仍能抓住”。
`src/core/gc.zig:5074-5075` 所称 audit walk 独立，仅仅是新建了另一个 iterator
实例；在 population authority 层面并不独立。

合入前必须恢复 audit-only 的独立 ownership/byte oracle（不要求回到 production
hot-path counter），并把 orphaned-accounted mutant 固化成回归测试。一个对象在
header 自身仍合法时丢失全部合法 owner container，审计必须失败。

### MEDIUM：pending/terminal heap-live 口径取决于 carrier 表示

代码证据：

- condemnation 把 block corpse 留在 alloc/doomed bitmap；non-block/standalone
  header 则从普通 list 摘除并转入 `doomed_by_kind`：
  `src/core/gc_trace_stw.zig:1219-1234`、
  `src/core/gc_trace_stw.zig:1235-1255`。
- 普通 object iterator 在非 young-only 模式下仍会产出 allocated/accounted 的
  block cell，包括 doomed cell：`src/core/gc.zig:3037-3072`。
- `HeapAccountingIterator` 不枚举 `doomed_by_kind`，只额外枚举
  `zero_ref_current`/`sweep_current`：`src/core/gc.zig:3115-3154`。
- block corpse callback 明确依赖 block iterator 保持可见；non-block callback
  则只临时暴露当前一个 corpse：`src/core/gc_trace_stw.zig:1422-1443`、
  `src/core/gc_trace_stw.zig:1479-1524`。
- `doomed_pending=true` 时 invariant runner 跳过 heap accounting：
  `src/core/gc_trace_stw.zig:643-650`。
- 但公开的 `JSRuntime.gcStats()` 无条件读取该 census
  （`src/core/runtime.zig:3571-3583`）；CLI terminal 输出也先读取 stats，随后才
  打印 morgue 是否 pending（`src/cli/zjs.zig:401-418`）。

因此，两个逻辑状态相同的“已判死、尚未销毁”对象会得到不同的
`heap_live_bytes`：block object 仍被计入；standalone/list object 立即消失，到
成为 `sweep_current` 时才在 callback 期间短暂重新出现。terminal pending
snapshot 同样漏算 non-block bytes。旧 byte ledger 在 destructor 真正执行前会
持续计入两者。

这暂不破坏 GC trigger policy：runtime 调度仍基于 `MemoryAccount`/`doomed_bytes`，
不是这组 derived stats。但它破坏了公开 API/CLI 的统计口径，也正好在 brief 指定
的状态中留下审计盲区。合入前需要为全部 pending carrier 选择同一语义（全部
accounted corpse 都算，或全部 condemned corpse 都不算），并增加 mixed block +
standalone pending 与 terminal stats 测试。

## 逐攻击面结论

### 1. 三项 audit allowance

- **Finalizer current：** `zero_ref_current`/`sweep_current` 的补入会去重，且要求
  `heap_accounted`（`src/core/gc.zig:3120-3137`）。未发现这两个 slot 本身能伪装
  泄漏；问题是它们不能构成完备 population authority，`doomed_by_kind` 与任意
  orphan header 都不在其中，导致上述两项发现。
- **Construction root：** 放行要求 sentinel pin count，并精确匹配 unpublished
  block-cell/object/detached-generator 状态（`src/core/gc.zig:3157-3217`、
  `src/core/gc.zig:3220-3257`）；collector-boundary 版本还要求当前 mark
  （`src/core/gc_block_heap.zig:1530-1569`、
  `src/core/gc_block_heap.zig:1610-1623`）。未发现能把普通漏发布对象伪装成合法
  construction shell 的宽泛 wildcard。
- **Young membership 拆分：** accounting-only checker 不再查此项，但
  collector-boundary `verifyPublishedCellsAllowing` 仍启用检查，并在 generation
  verifier 前运行（`src/core/gc_block_heap.zig:1572-1591`、
  `src/core/gc_block_heap.zig:1625-1644`、
  `src/core/gc_trace_stw.zig:616-635`）。未发现独立 bypass；但直接调用
  `verifyHeapAccounting` 已不再具备 young-list 完整性覆盖，注释不应把它描述成
  全局 coverage。

结论：construction 与 young-list 的作用域收窄可以成立，但不能弥补独立 owner
oracle 的阻断级丢失。

### 2. `deriveHeapSpaceSnapshot` carrier 与分类覆盖

- ordinary list 覆盖六种 cycle-candidate，block phase 覆盖 classed-block
  `Object`（`src/core/gc.zig:2777-2804`、`src/core/gc.zig:2994-3101`）。
  `heapByteSizeFromHeader` 为 object、function bytecode、var ref、realm、module、
  shape 都提供 size derivation，并处理 standalone size stamp/fallback：
  `src/core/gc.zig:2811-2837`。
- fixed-size object 只有在受支持时才进入 classed block，否则回退 slab/standalone
  （`src/core/memory.zig:1285-1335`）；variable medium/large request 被
  `allocCell` 拒绝时也会回退（`src/core/memory.zig:1450-1489`）。未找到生产 GC
  object 通过 block-heap medium/large superblock 而绕开 iterator 的路径。
- publication 从 `policy.large_object_threshold` 写入 `large` stamp；census 与
  verifier 用同一 policy 重算（`src/core/gc.zig:2688-2735`、
  `src/core/gc.zig:2840-2842`、`src/core/gc.zig:5040-5043`）。全源 writer 复核未
  找到 init 后修改该字段的生产路径，当前不存在 drift window；但 immutable
  只是约定，并未由类型系统强制。

结论：正常 live carrier 覆盖完整；pending/off-owner 覆盖不完整，见发现项。

### 3. 删除 `SpaceAccount` 的读者清册

独立 `git grep` 覆盖 source、build file、tests、tools、binding/root API 与 docs，
未发现 `SpaceAccount`、`old_space`、`large_space`、`recordLargeSpace*` 的活跃编译
读者。公开 `GCStats` 字段仍保留并被 CLI/tests/tools 消费，只是改由 census
填充（`src/core/gc.zig:1787-1795`、`src/core/gc.zig:2566-2585`、
`src/cli/zjs.zig:1164-1169`、`tools/perf/gc_stats_snapshot.py:210-225`）。

两份带日期的设计文档仍把已删除实现描述为当前事实：
`docs/alloc-front-2026-08-29.md:69-73`，以及
`docs/registry-role-audit-2026-08-29.md:126`、`:251`。它们是文档漂移，不是隐藏
build reader；P1 重做后应更新或明确标为 superseded。

### 4. `unlinkObjectWithBytes` 合并位清理

`recordHeapFreeWithBytes` 只通过命名 bitfield 清 `large`、`heap_accounted` 与
standalone size stamp（`src/core/gc.zig:2848-2856`）。外层 unlink 仍执行原有
cycle/list/generation/address-registry 路径（`src/core/gc.zig:2924-2955`、
`src/core/gc.zig:3434-3487`、`src/core/gc.zig:4536-4560`）。未发现合并写会破坏
pin、kind、generation、remembered 或 external-token 状态；此攻击面无 finding。

### 5. S1a 与 `doomed_pending` 合成风险

`git merge-tree 7c067f01 gc/frontier-v2-20260831 b340faf3` 报告三个
“changed in both” path，但没有文本 conflict marker。这不等于语义批准：S1a 的
报告本身为 NO-GO/archive-only，因此当前没有可批准的合入候选。如果其 marking
改动复活，必须把合成后的 `objectIterator`/condemnation population 再次对照上述
独立 oracle 复审。本报告的 P1 pending-stat 缺陷在不合入 S1a 时已经存在。

## 验证记录

- 已读 brief、implementer report、verification policy、相关现行源代码/测试、
  公开 CLI/runtime 路径、docs/tools 读者，以及 S1a report。
- `git diff --check 7c067f01..b340faf3`：通过。
- 删除读者清册：无活跃编译读者；残留 dated docs 如上。
- base/candidate focused mutant：base 通过，candidate 失败，输出如上。
- 第一次探索命令使用了错误的 test-runner filter 语法并返回 `InvalidArgs`；已明确
  排除，不作为证据。
- 未重跑 full suite：这是只读评审；implementer 的 full-gate 结果不能否定定向
  audit mutant，而该 A/B 证据已足够作出 REJECT。
