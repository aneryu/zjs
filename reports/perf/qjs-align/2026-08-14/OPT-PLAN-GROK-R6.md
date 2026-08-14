# OPT-R6 计划 — grok 第六批：两刀组包实施 + 前端微架构诊断

日期：2026-08-14。制定者：driver。执行者：grok。状态：**定稿，待派发**。
目标框架：**每项 ≥1.0**（PARITY-LEDGER 宪法）。

## 0. 输入（R5 的双向产出）

R5 逐 opcode 机器码对照给出**两个体制（regime）**的清晰图景：

- **体制一（call/frame 型：deltablue/richards/raytrace/TS）**：指令超出集中在调用/帧机器，
  14 个 vm.* 字段中 12 个 ARCHITECTURAL，**2 条 FAITHFUL-FIXABLE 已登记**（本批实施）。
- **体制二（compute 型：zlib/mandreel/box2d/gbemu）**：zjs **指令更少**
  （zlib insn 0.933，driver CPU19 亲验）而 **IPC 0.870、brmiss 1.241**——
  差距是分派结构的前端微架构（256-way 间接 br 的 I-cache/BTB），**机制未最终命名**（本批诊断）。

## 1. Lane R6-K「两刀组包实施」（CPU 5-6；**本批唯一写 src/ 的 lane**）

实施 MECHANISM-REGISTRY 已登记的两条 FAITHFUL 候选，各一独立 commit：

1. **`leaf-call-frame-zero`**：`op_call*` / `op_call_method` 的 leaf/exact 形态克隆，
   去 96B+0x220 帧，只 resolve + `enterEntry` + `br`。镜像 qjs `CASE(OP_call*)` 在
   `bl JS_CallInternal` 之前的零帧形状（qjs:18175-18192，`label_OP_call0` 0x254ec）。
   ⚠️ 帧生命周期红线：ReleaseSafe 必验（teardown.simple 事故先例）；
   克隆臂的选择判据（何时可走 leaf）必须与 qjs 语义完全一致，不得引入新语义门。
2. **`get-array-el-frame-zero`**：outline 零 RC 快数组路径，热臂 frame-zero
   （现状：`bl destroyZeroRef` 令整个 handler 无条件开 0x50 帧）。
   ⚠️ 臂序就是性能：outline 后冷臂 br 位置照 R5 反汇编样张校对，勿令热臂变胖。

契约：worktree `worktree-grok-r6-k`，分支 `grok/opt-r6-k`；一改动一 commit；
`zig build test` + ReleaseSafe + `lint_anti_goals.sh`=0 + difftest 抽面
（Error.stack/异常面在改动路径上取样 ≥3 例）；完成后打 `AWAIT-MEASURE`。

**验收（driver）**：canonical test262-gate 亲跑；**组包 3-pad zoo**（0/3/7 × 8 samples）
逐基准 lineage 判读——重点 deltablue/richards/raytrace/pdfjs 方向 + 四资产不回退；
按 MECHANISM-REGISTRY 组包规则第 4 条，包通过后再做组件归因（微基准 + 区域 PMU）。
预期：两条合计 0.2-0.4pp（诚实：可能低于 0.278 MDE，包裁决以三 pad 同号为准）。

## 2. Lane R6-F「前端微架构诊断」（CPU 7；诊断，src 只读）

把体制二的「IPC/brmiss 税」命名到机制并给出忠实域内的缓解候选：

1. **事件分解**：zlib/mandreel/gbemu/box2d 两侧采
   `stall_frontend / stall_backend / L1I miss / iTLB miss / BTB(br_mis_pred + br_indirect 类)`
   （事件名先 `perf list` 探明本机 armv8_pmuv3_1 的可用集；⚠️ run_zoo_fixed_pmu 硬编码表
   采不了 stall——直接 perf stat 裸采，双 PMU 过滤 `<not counted>`）。
   判据：前端停顿差 ≈ 周期差 ⇒ I-cache/BTB 坐实；否则重新归因。
2. **形态定位**：间接 br 目标分布——zjs 256-way 每 handler 一函数 vs qjs 单函数
   computed-goto。测 zjs 热 handler 的地址跨度（`zjs-dispatch-table.json` 已有表），
   对照 qjs 同热 opcode 的 arm 地址跨度；量化「热工作集跨了多少 I-cache 行/页」。
3. **缓解候选（只登记）**，全部在「不改变逻辑执行模型的布局/代码生成」许可域内：
   a. **热 handler 刻意聚簇**（按 zoo 全套频次把 top-N handler 排进连续地址；
      与已封板的「pad 彩票」不同——那是随机布局方差，这是工程化布局，
      align(64) 钉群先例在案）；
   b. 热 handler 瘦身以缩热工作集（冷臂 outline 更彻底——与 R6-K 第 2 刀同族）；
   c. 若 BTB 主导：减少间接跳目标数（短 opcode 家族合并 handler 入口——须逐条过忠实性）。
   每个候选给出预计收益的量化依据（工作集字节数 × miss 代价），**不实施**。

## 3. 不做

- 改热体去「对齐」更胖的 qjs CASE（R5 结论：热体是 ZJS-ADVANTAGE）。
- 重开 H3/readfwd/String capacity/IMPL-TEARDOWN/14-store 无主 stall。
- B 类机制（内联/IC/融合）——PARKED 维持。

## 4. 结果表（执行后填写）

| lane | 状态 | 结果 |
|---|---|---|
| （待执行） | | |
