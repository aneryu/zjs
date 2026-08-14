# OPT-R7 计划 — grok 第七批：zoo 提纯 case + 微基准定位战役

日期：2026-08-14。制定者：driver。执行者：grok。状态：**定稿，待派发**。
方向来源：用户指示「从 zoo 中总结 case，然后通过 microbenchmark 来定位」。
方法先例：splay 提纯复现 1.373x → case 内二分 → 100% 在构造 → T5 真刀（splay→0.933）。

## 0. 反「微≠宏」宪法（本批命门，违反则证据作废）

「微基准≠宏观」在本项目栽过**六次**，全部栽在通用微基准。本批的免疫机制：

1. **比值不变量**：case 必须复现该基准 fixed-work 的 z/q 比值 **±0.02**。
   从真 zoo 源出发逐步删减，**每一步删减后重测比值**；
   比值漂移的删减步 = 二分信息（被删部分携带机制），记录在案。
2. **宏观回验**：case 内定位的机制，必须回到**真 zoo 源码**做消融对照
   （两引擎同一份改过的源，`/tmp/r3/run_ablation.py` 现成）方可写「已定位」。
3. **三 pad 同号**（0/3/7）才算结论；单 pad 只用于排名。
4. **通用微基准不作证据**（非比值保持还原产出的一律只算灵感）。
5. case 形态纪律：包函数（顶层循环变量污染教训）、fixed-work（时间盒下比 wall 必错，
   自建 case 用 wall/cyc 直比没问题）、单 case 运行 ≥1s。

## 1. Lane 划分（4 lane，按「赤字 × 从未提纯」排序）

| lane | 基准 | 现比值 | CPU | 起点材料与特别任务 |
|---|---|---|---|---|
| **R7-R** | raytrace | 0.777（最差） | 5 | JS 级归因已有（apply 包装已修），但**从未提纯**。调用/帧体制。起点：热函数名单在 `2026-08-12/RAYTRACE-ATTRIBUTION.md`。目标：case 复现 ~1.29x 后二分 |
| **R7-T** | typescript 内层 | 0.830（内层 1.215x） | 6 | ⚠️ 必须提纯**内层 run()**（整进程口径是前端摊销假象，R4-T 教训）。已命名符号：RC destroy/trace、`pushExactSimpleFrame`——case 二分向它们收敛或推翻 |
| **R7-H** | richards | 0.904 | 7 | 从未深归因。纯 OO 调度器（Scheduler/TaskControlBlock），与 deltablue 同体制但形态不同。R4-U 桶表在 `R4/r4-u.md` |
| **R7-Z** | zlib | 0.920 | 8 | compute 体制代表。**双重任务**：①提纯热循环（huffman/inflate 内层）复现 1.073x cyc；②**前端假设判决实验**：小 case（handler 工作集小）若 IPC 差距消失→坐实 I-cache/工作集；若仍在→间接跳本身。两个结果都直接喂 R6-F 的缓解候选选择 |

deltablue（v3 case 已在）与 EB（差分微基准已有）不占 lane；box2d/gbemu/mandreel 等 R7 方法验证后下批。

## 2. 每 lane 四步法

1. **提纯**：zoo 源 → 删减环（每步测比值 ±0.02 门）→ 得到最小比值保持 case
   `/tmp/r7-<lane>/case-pure.js` + 删减日志（每步的比值轨迹——**轨迹本身是产物**）。
2. **case 内二分**：对 case 的构造逐个消融/替换（构造替换法照 splay：换写法不换语义量），
   收敛到 ≤3 个「拿掉即比值塌缩」的构造。
3. **差分定价**：对每个定位构造做成对微变体（有/无），两引擎定价（ABBA ≥8、同核），
   并回真 zoo 源做宏观消融回验（宪法第 2 条）。
4. **机制连接**：映射到引擎机制（zjs `file:line` × qjs:NNNN），按 R5 分类法裁决
   （FAITHFUL-FIXABLE / ARCHITECTURAL / ZJS-ADVANTAGE），FAITHFUL 的给出修复方向与预计值
   （按 PARITY-LEDGER 量纲：单基准 1% = +0.066pp）。

## 3. 契约

继承 R3-R5 全部（src 只读／候选只登记／各自核 ABBA≥8／CPU19 归 driver／
凭据绑 sha256／`bash -c`／VERIFIED-LEDGER 强制对照／已封板清单——
其中「对齐更胖的 qjs CASE」「重开 H3/readfwd/IMPL-TEARDOWN」明令禁止）。
R5 反汇编产物（`R5/`、`/tmp/r5/asm/`）作为机制连接阶段的现成材料。

**与 R6 的关系**：R6-K（两刀实施）**独立照跑**（worktree `worktree-grok-r6-k`，
build 型任务用 CPU 15/16，测量走 AWAIT-MEASURE 由 driver 串行）；
R6-F 前端诊断**并入 R7-Z**（提纯 case 就是判决实验），R6 计划 §2 标记 SUPERSEDED。

## 4. 交付与 driver 验收

- 每 lane：`/tmp/r7-<lane>/REPORT.md`（提纯轨迹表 + 二分记录 + 成对定价 + 宏观回验 + 机制表）
  + `case-pure.js` + 全部变体 + 原始 JSON。
- driver：抽验 ≥2 个 case 比值亲测（CPU19）→ 头部机制复测 → 汇总为 R8 修复批
  （FAITHFUL 项按值组包，向「每项 ≥1.0」推进）。
- 预计每 lane 1-1.5 天，四 lane 并行。

## 5. 结果表（执行后填写）

| lane | case 比值/宏观比值 | 定位构造 | 机制裁决 |
|---|---|---|---|
| （待执行） | | | |
