# S4d：work-based GC 切片预算（driver 设计，2026-09-02）

状态：规格冻结；交 codex 实现。基点：M 终态合入后的 main（实现可先基于 gc/m-cut-driver-20260902）。

## 1. 事实与动机
- 增量 major 的两类切片都按 **wall-clock ns** 预算：`incrementalMarkStep(rt, budget_ns)` 每 64 个 header 读一次 `nowNanos`
  （gc_trace_stw.zig:1170-1173），`destroyDoomedSlice(rt, budget_ns)` 同型（:1557/:1642）；预算来自 `Registry.policy`
  （callback 300µs / idle 2ms / allocation_slow_path，按 profile 变体 100µs~5ms，gc.zig:525-578，`sliceBudgetNs` :2687）。
- 后果（2026-09-01/02 实测）：同一二进制两次运行的 mark steps/destroy slices/minor+major 次数分叉；场 A 同 SHA 自比 cycles 单腿漂
  +2.85%、minor STW −10.7%；争用下 insn 也漂 +0.47%（wall 预算→切片数→指令数）。这既毁测量，也让行为不可复现。
- 引擎先例：V8 增量标记按 **bytes marked** 配额（`StepSizeInBytes`，wall 只作辅助上限）；JSC 的 constraint/visit 也按工作量。

## 2. 设计
1. `policy` 的三档预算改为**工作单位**：`mark_units`（traced header 数）与 `destroy_units`（析构 corpse 数），wall-clock 保留为
   **安全上限**（`safety_ns = 4 × 原 ns 预算`，只在单位工作异常昂贵时截断，正常永不触发；命中计入 stats.safety_cap_hits 且
   Stage 0 报告必须为 0）。
2. 默认换算（由现役速率钉死，实现时用 `--gc-stats` 实测校准并写入注释）：mark ≈ 50ns/header → callback 300µs ≈ **6,000 units**、
   idle 2ms ≈ **40,000**、allocation_slow_path 按其 ns 同比；destroy ≈ 150ns/corpse → callback ≈ **2,000**、idle ≈ **13,000**。
   变体 profile（gc.zig:563-578）按同比例换算。
3. `incrementalMarkStep`：`since_clock` 计数改为与 `mark_units` 比较，删除每 64 个的 `nowNanos` 读（只在 `since_clock % 4096 == 0`
   时读安全上限）；`destroyDoomedSlice` 同理。parallel 路径 `parallelMarkStep(rt, pool, budget)` 改传 units（各 helper 各自计数）。
4. env 覆盖：`ZJS_GC_SLICE_UNITS=<mark>,<destroy>`（诊断），`ZJS_GC_SLICE_WALL=1` 恢复旧 wall 行为（**仅 A/B 对照用，不作为长期开关**，
   S4d 合入后一周内删除并记入 policy）。

## 3. 预注册验收
- **确定性**：同一二进制、同一 fixed-work，两次运行的 `--gc-stats` 中 major/minor 次数、mark increments、destroy slices **逐负载完全相等**
  （六负载 12 腿）。这是本刀的主验收线。
- 性能：Stage 0 六负载 insn/cycles ≤+0.5%（单位换算得当应≈1.000）；splay/EB major pause p50/p99 ≤ base×1.2（切片粒度改变的容忍）。
- 测量学：场 A 同 SHA 自比 samples 2 的 cycles 逐腿离散 < 0.5%（对比 stage0 工具报告的 +2.85%）。
- 生命周期七指标对 base ±10%（major/minor 次数因预算等价应 ±3%）。

## 4. 测试
单测：units 用尽即返回且不读时钟（mock 时钟断言调用次数 ≤ 上限检查频率）；safety cap 在单位极慢时截断；parallel 各 helper 计数汇总；
env 解析。mutant：删除 units 比较（切片永不返回）被 safety cap + stats 抓；safety 命中计数非零在 Stage 0 报告为红。
