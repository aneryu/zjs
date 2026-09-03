# GC v2 终局切换 driver 审核（2026-09-02）

状态：**APPROVED（owner 2026-09-02「同意 M」）——终态 M 一刀落地；M-O1/M-O2/M-O3 三项改约批准；不做 v1/v2 双布局回滚开关、不做中间归因臂、不留 shadow/兼容 API（回滚靠 git）。r3/r4 混合终案与四轮对抗评审归档为参考设计。**

审核对象：`HYBRID_FINAL_CUT_R3.md` + `HYBRID_FINAL_CUT_R4.md`（gc-minorfb/.scratch）、四轮对抗评审
`XREVIEW_POSTMORTEM.md`/`XREVIEW_HYBRID_R2..R4.md`（gc-settle/.scratch）。源码基点 `main@e30f49e8`。
本审核由 driver 亲自对源码核验，不复用 codex 结论作为前提。

## 0. 一句话结论

r3+r4 经四轮对抗已在**自身前提下**收敛（余一个窄 BLOCKER：deinit 期需关 construction gate 而非只关
publication gate，一条规则可闭）。但它的七锚点里有五个（H_CORPSE/H_CLASS/H_V1_PUBLISHED/H_V1_HOT/
H_V2_80_HOT）都是为了兑现 A1v2 的一条**合同**——「Object header 8B 不可变、全部动态位侧置」——而
obj64 的密度收益（+24.97% cells/block）**完全不依赖这条合同**。把合同当公理，是四轮循环里没人质疑的
前提。

## 1. 源码核验事实（driver 亲验）

| # | 事实 | 证据 |
|---|---|---|
| F1 | 现役 GC 前缀 `Metadata` 已是 **8B、无 rc、可变**：`size_class u16 + alloc_info u8 + flags u8(kind/mark/young/finalizing/pinned/cycle_visited) + lifetime u32(mark_epoch/shape_summary/remembered)`。 | gc.zig:1009-1017 及 comptime 断言 |
| F2 | Object cell = `Metadata(8) @-8` + `TraceHeader.next(8) @0` + body。**块 Object 不在 gc_obj_list**（`kind != .object` 才入链），young 用 `Block.young_link`+header young 位，doom 用 doomed bitmap+`Block.doomed_link`。 | gc.zig:3595-3608；SLICE2_SCOUT §借用者清册 26-41 行；gc_block_heap.zig:248-253 |
| F3 | 块 Object 对 `next` 的**唯一**借用者是 `cycle_deferred_frees`（parked 尸体 LIFO），只在判死后 push/pop。 | object_gc.zig:273,425,445；gc.zig:3578-3580 |
| F4 | HeaderV2 = `type_tag/size_class/static_flags/trace_class u8×4 + layout_extra u32`；OBJ64_CENSUS 明记「把动态状态塞入 HeaderV2 违反 O1 immutability，不列为备选」——不可变是合同选择，设计文档 §1 未给机制级理由。 | header-v2-design §1 58-73 行；OBJ64_CENSUS 88/167 行 |
| F5 | obj64 方案 A 的 8B 缺口来源：`Header.next` 消失给 8B（72 raw 仍落 80 class），再由 implicit prop_values 给 8B → 64B class。**Metadata 8B 在两种路径下都保留**。 | OBJ64_CENSUS 9-11、93-105 行 |
| F6 | r4 给 `Block.high_water` 定价 112→120→128B/块；但 `cell_size u32/cell_count u32` 可缩 u16（cell 上限 <64KiB），零增长即可容纳 u32。r4 漏了这条。 | gc_block_heap.zig:230-286（无对齐洞，comptime 断言 112） |

## 2. 对 r3+r4 的审核意见

- **技术闭合度**：高。六步事务、set-first 信任、两遍法 deinit、高低水位线、credit 独占、无条件 cap 都成立。
  codex 四轮残留（1b 期 construction admission）可用「`phase==.deinit` 期任何 GC 物理分配为 fatal 不变量」
  一条闭合。
- **整体收益审核（owner 原则「裁决看整体收益」）**：
  - 收益侧：密度 +24.97%（与路径 M 相同）；HotState/published 分裂/高水位/token 没有任何一项对准 O1 足迹税
    (+9.04pp)、O2 marking(+7.64pp) 或 O3 走堆——r1 自己给 HotState 的桌面数是 **成本上限 0.70%/0.35%**、
    cycles 警戒线 2.7cyc/mutation，不是收益。
  - 成本侧：C_CORPSE 生产 guard 非零（EB 下界 0.07-0.17%）、population-split **无界碎片风险**（owner 需签字
    承担）、high_water +16B/块、token/credit/oracle 三套新机制、五 kind 三族死亡事务 + 12+ mutant。
  - 家族前科：side-authority 迁移三连败（slice1 +441%、slice2 +20.7%、slice3a +17.4%），r3/r4 通过「五 kind
    保留侵入链」躲开了五 kind 的税，但把同一形状的机制（side published/hot state）搬到了 Object 上——Object
    publication 是 splay 12M/EB 98M 量级的最热面。
- **结论**：r3+r4 是「在不可变合同下的最优解」，但不可变合同本身不承重。不应再投入 r5。

## 3. 路径 M：最小切换（driver 推荐）

**定义**：只对 Object 做两步，`Metadata` 与五 kind 一字不动。

- **M1 去 `next`**：`Object` 结构删除首字段 `header: GCObjectHeader`；Object 指针即 body 起点，
  `Metadata` 仍在 -8。parked 尸体链改写 **判死后的 body 首字**（今天 `next` 就在 Object 偏移 0——
  存储位置与 store 数完全相同，只是活对象期间该字归 scalar word 所有）。这正是尸体终案的
  first-word union，且与 qjs `free_next` 同款；`Metadata` 完整保留为尸体 witness（conservative 命中 parked
  尸体的分类路径 gc.zig:2194/4478 不变）。
- **M2 方案 A**：slots2 implicit `prop_values`，72→64B，落 64 class。spill 判别位用 `Metadata.flags`
  空位或 scalar word 高位（OBJ64_CENSUS §3.1 已列）。
- **不做**：HeaderV2 类型、published/owned 分裂、high_water、ConstructionRootToken、HotState 平面、
  population-split arena、reservation credit、五 kind 任何事务改动。S1 已入库的 carrier/capability/
  代际权威继续 audit-only。

**收益上限**：密度与 r3/r4 相同（+203 cells/block，24.97%）；M1 每 Object 发布少 1 store（splay ≈0.04%
insn，方向为正）；M2 inline 槽访问由指针 load 变常量偏移。足迹税（O1 桶 +9.04pp）是密度直接对准的账。

**工程钉（实现前普查，均为机械项）**：
1. parked 后 body 首字读者普查：weak-husk/finalizer-current 窗口若仍读 `weakref_count`，尸体链改用偏移 8
   （dead shape_ref 字）——两者都在 64B 体内，不影响密度。
2. header→body 偏移按 kind comptime 化（Object 0 / 五 kind 8）：gc.zig/memory.zig 无基于
   `@sizeOf(TraceHeader)` 的通用 body 算术（仅 1132 行断言），`&obj.header` 站点由编译器强制普查。
3. `FrontierSafeHeader`/O2-B 不变：frontier 持有的仍是「-8 为 Metadata」的同一种句柄。
4. 归因矩阵两臂：`H_PRE0 → H_M1（去 next，80 class 不变）→ H_CUT（方案 A，64 class）`，每臂沿用现行
   批门禁+ABBA；M1 臂预期 ≈1.000，红即停。

## 4. 需要 owner 裁决的合同变更（替代 H-O1~H-O5）

- **M-O1**：撤回 A1v2-O1「六 kind 8B 不可变 HeaderV2」在本 horizon 的实施；`Metadata` 维持为唯一 8B 可变
  前缀。HeaderV2/侧置动态位保留为未来独立提案（须自带定价）。
- **M-O2**：尸体终案对 Object 的 first-word union 落点改为 **body 偏移 0（或 8）**，`Metadata` 为尸体
  witness；五 kind 维持现状（现状已满足 union 合同，slice2 结论）。
- **M-O3**：A1v2-O4「同 binary 不混 layout」补注：per-kind comptime body 偏移不构成同一分配的混合布局。
- 不变：O2-B frontier、O3 heap_live_bytes 语义、O5 数值线重注册规则。

否决 M 的唯一充分理由是：owner 认为「不可变 header + 侧置动态状态」本身是 GC v2 的目标而非手段。
若是，则回到 r3+r4 补 r5（construction gate）后走 H-O1~H-O5。
