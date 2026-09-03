# GC v2 完成对账与转向方案（driver，2026-09-03，DRAFT 等组合重测数字）

状态：**GC v2 完成（2026-09-03 04:00）**。owner 2026-09-03 00:30 裁决「同意」——M、S4a、S4b 收尾合入 + 组合重测对账后宣布 GC v2 完成；S4d 降为可选基建；
block 级 black allocation 仅在上限实验 ≥2pp splay 时立项；之后主力转回 TS 类型导向/AOT（`docs/type-directed-optimization-plan.md`）。

## 1. GC v2 收益账（cycles(u+k)，相对 GC v2 开始前 main；正式=CPU19 串行 ABBA）

| 项 | 六负载 geomean | splay | 状态 |
|---|---:|---:|---|
| S1 无界分段 frontier | 0.998 | 0.954 | 已合入（8aba23bd） |
| slice2-min（zero_ref_list 消灭） | ≈1.000 | ≈1.000 | 已合入（e54c0a0f） |
| M 终态 Object 64B（删 next + 方案 B′ + 物理计账） | **0.9878**（正式 1×1，CPU19，samples 4×2 基线臂） | **0.9743** | GO；EB 0.9825/regexp 0.9826/ray 0.9910/pdfjs 0.9955/deltablue 1.0013 |
| S4a 块回填（位图游标 + minor 判死块准入） | KILLED（90% 准入档 cycles 全线内：EB 0.989/ray 0.995，但 splay maxrss +12.6%、EB committed +28% 违反预注册足迹线） | — | 归档 refs/archive/gc-s4a-driver-20260903；S5 候选（侧置 young 位图 + 留驻上限） |
| S4b 并行标记默认关闭 | 单核 1.000 | 1.000 | 已合入（d944f26d）；场 B 12 样本 workers 0，splay 5核/1核 0.996，env=0 对照 +10.5% |
| S4c growth 重定价 | 1.000（维持 2.0） | — | 关账 |
| **累计（S1×M，正式口径）** | **≈0.986** | **≈0.930** | 对 rc 差分 +20.4pp 还了约一半 |

足迹（S4a 首轮实测，待重做复核）：raytrace committed 76→5.5MB、regexp 20→4MB、EB −22~32%、pdfjs −55%。

## 2. 剩余账目与不做的理由
- marking +7.6pp / alloc 前沿 +3.2pp（splay 差分桶）：唯一有上限计算的刀=block 级 black allocation（`REPORT_BLACKALLOC_UB.md` 待出）；≥2pp 才立项。
- 结构天花板：GC v2 的极限是回到 rc 时代平价（geomean +2~3%），对 zoo composite（0.83 vs qjs）是小块；静态轴（T1 typed 属性）纸面 +15~20% 综合。

## 3. 完成判据（全部满足，2026-09-03）
1. M 正式 1×1 GO（geomean 0.9878、splay 0.9743）；对抗闭合 3/3；全测 2526/0；批门禁两轮 + 整合批一轮 PASS；**已合入 main d944f26d**。
2. S4a：三档准入 Stage 0 完成，KILLED（见 §1）；driver-s4a/.scratch/REPORT_S4A_DRIVER.md。
3. S4b r2：满足（raytrace 1.011±0.008 为 2 样本亲和噪声，driver 裁 GO）；已合入。
4. 组合重测：main 相对 H_PRE0 的差异 = M（S4b 单核零差异），故 M 正式 1×1 即组合读数（driver-m/.scratch/formal/REPORT_M_FORMAL.md）；新共享 Stage 0 基线 shared-h_pre0/main-d944f26d 已冻结。
5. 归档：refs/archive/{gc-s3-slice3a-20260902, gc-s4a-lane-20260902, gc-s4a-driver-20260903, gc-s4b-r1-20260902, gc-s4d-work-budget-20260903}；混合终案 r1-r4 与四轮评审在 gc-minorfb/gc-settle .scratch。

## 4. 转向方案（TS 类型导向 / AOT）
按 `docs/type-directed-optimization-plan.md` v0.8 §6.2：
- **第一步 = T-spike 判决（G1-TYPED）**：spike/perf-t@df356d9e 原型已在（2026-08-26：op254/255 guarded direct-slot、u64/ptr 双臂）；
  P4「GC 合入窗口」随 M 合入解除。派一条 lane 按测量合同做 spike A/B（typed 微基准 + 一个移植循环），driver 亲写杀标与规格。
- 过门 ⇒ PERF-SHAPE-ID（F1）+ PERF-TYPED-IR（F3/F5）+ T1 解释器特化（S3）；未过 ⇒ 解释器级特化搁置，直接评估 N-spike（AOT 原生化）。
- 分工沿用 2026-09-02 规则：driver 出函数级规格与预注册线，codex 实现，Stage 0 快筛先行，正式只裁 GO。
