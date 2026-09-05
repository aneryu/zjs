# S4a：位图游标分配 + minor 判死块回填（driver 设计，2026-09-02）

状态：**HISTORICAL / 已完成（2026-09-06）**——GC v2 S4a 已实现并合入 main；本文留作规格与设计推理记录。
（注意：本文的 S4a 属 **GC v2** 分期，与 tracing-gc 完成计划的 S4-a 不是同一件事。）
原状态：规格冻结；实现基点 = `gc/m-cut-20260902` 终态（M 合入 main 后 rebase）。

## 1. 事实与账目
- M 首轮意外实测（minor 判死块进 hot-reuse 门）：**raytrace committed 76.2→5.5 MB（C/L 28.8×→2.2×）、minflt 64.7k→8.5k；
  regexp 20→4 MB；EB committed −22%；且 decommit 反而更少（ray 166→9.4 MB）**——O1 足迹税桶（差分 +9.04pp 第一大项）
  的直接兑现，也是 S2a 没拿到的收益。
- 代价机制（driver perf 符号差分）：EB +13% 样本里 `findCellState` +2,876、`openBlock` +1,580（≥70%）。根因不在位图扫描
  （`findCellState` 已是 ctz word 级），而在**重开的物化**：`openBlock` 从 hot 表取块→`rebuildFreeIntervals` 逐孔洞写
  interval node 到 cell 内存（每孔一次冷行写）→ 若 `max_interval < hot_reuse_min_interval_cells` 整块**丢弃重来**
  （白做一次 O(holes)）；`beginMajor` 的 `withdrawHotBlocks` 再把全部 hot 块各 rebuild 一遍。minor 判死块碎片化严重
  （死 young 与活 old 交错），孔洞多而小 → 反复 rebuild+拒绝。
- R-B 把 minor 判死块隔离在门外恢复了 base 节奏，但也放弃了上述足迹收益。S4a 的目标：**把收益拿回来，把 O(holes) 物化去掉。**

## 2. 设计：interval 分配器 → 位图游标分配器
1. `flag_interval_allocator` 块不再物化 interval node。新增块字段复用现有 `bump/interval_end`：
   `bump` = 游标 cell 索引；`interval_end` 弃用（保留字段不改布局）。分配：
   ```
   popCellBitmap(block):
     word = bump/64; bit = bump%64
     w = ~alloc[word] & (all << bit)            // 当前字剩余空位（尾字裁剪）
     while w == 0: word += 1; if word == words: return null; w = ~alloc[word]（尾字裁剪）
     idx = word*64 + ctz(w); bump = idx+1; return idx
   ```
   每次分配 ≈ 1 load（位图字，L1 热）+ and + ctz + 加法；空字跳过是 O(words)。alloc 位由现有 reserve 路径置位（不变）。
   `next_free` returned-cell 链（构造失败退回）保留现状。
2. **重开 = O(1)**：`openBlock` 取 hot 块只做 `bump=0; flags` 切换（不扫描、不写 cell）；`hot_reuse_min_interval_cells`
   判定删除（游标分配对碎片不敏感）；`hasHotReuseCapacity`（空闲 ≥10%）保留为唯一准入。
3. **withdrawHotBlocks = O(blocks)**：只清 hot 标志/游标，不 rebuild。
4. `rebuildFreeIntervals`/`findCellState`/`writeIntervalNode`/`free_poison` interval 表示删除；`flag_bitmap_canonical`
   的语义（位图是唯一空闲权威）成为所有非 fresh 块的常态——正是 pass-A settle 已经承诺的。
5. minor 判死块准入 hot-reuse：`recordDoomedBlock(origin=.minor)` 恢复 `publishHotBlock`（撤销 R-B 的隔离），但**不**清
   `active[]`（活动块继续 bump，避免每次 minor 打断分配局部性）；major 臂不变。
6. 与 M 终态的接口：Object 尸体链在 body+8、doomed 位图、`snapshotYoungDoomed` 均不变；本刀只改 gc_block_heap.zig 的
   分配/重开/撤回三处与 R-B 的一行门控。

## 3. 上限与预注册
- 每分配增量：位图游标 vs interval bump ≈ +2~3 insn，仅作用于回填分配（EB hot reuse published 1.43M / 98M 发布=1.5%）
  → EB insn 上限 +0.005%，可忽略；重开/撤回从 O(holes×reopen) 降到 O(1)/O(blocks)。
- 预注册（Stage 0 → 正式 1×1，基线 = M 合入后的 main）：
  - 硬线：六负载 cycles(u+k) ≤ 1.003；insn ≤ +0.5%（Stage 0）。
  - 收益线：raytrace committed ≤ 0.30×、minflt ≤ 0.30×；regexp committed ≤ 0.40×；EB committed ≤ 0.85×；splay maxrss ≤ 1.00×。
  - 生命周期：minor 次数/pass-A settled/deferred runs ±10%；hot reuse published 预期大幅上升（显式列为预期变化）。
  - 反汇编：`popCellBitmap` 内联后热路径 ≤ 8 insn；`openBlock` hot 臂无循环。
- 若 Stage 0 任一负载 cycles >+2% 或 insn >+0.5% → 符号差分归因；若热点仍在分配路径 → 判 KILLED 归档。

## 4. 测试
- 单测：位图游标分配遍历所有空位一次且不重复（随机 alloc 位图 fuzz）；尾字裁剪；returned-cell 链优先；重开后游标从 0；
  withdraw 不改位图；minor 判死块准入但 active 不清。
- mutant：(a) 游标跨字漏跳空字→分配到已占位 cell 被 verifier 抓；(b) 重开忘清 hot 标志→双入 hot 表被断言抓。
- settled 两轮、arena-audit、test262 照常。
