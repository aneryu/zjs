# OPT-R9 计划 — grok 第九批：raytrace 攻坚（条件计划，待 bypass 裁决）

日期：2026-08-14。制定者：driver。状态：**定稿；§0 裁决后即可派发**。
目标：raytrace 0.777 → ≥1.0（+1.7pp，「每项 ≥1.0」下最大且唯一已全解释的项）。

## 0. 前置裁决（用户）：bypass 三选项

现状：`constructSimpleFieldConstructor` 仍在生产（`call_runtime.zig:2288`），
N3 三字段 new 靠它 0.871 反超；08-11「必须删」裁定从未执行；R8-C1 提议扩大它。

| 选项 | 内容 | 后果 |
|---|---|---|
| **(a) 执行删除** | 落实 08-11 原裁定 | EB/RT 立即恶化 ~300M（当年定价）；忠实性完备；raytrace 攻坚只剩 faithful 路 |
| **(b) 正式改判＋扩大** | 承认 bypass 为已登记偏离，实施 R8-C1（G 形/N0 形打上） | +1.7pp 上限最快兑现；但推翻「不开例外口子」，须建偏离账本（同 B 的治理配套） |
| **(c) faithful 攻坚（默认推荐）** | bypass 维持现状不扩大；把 G/N0 形在**真帧路径**上对齐 qjs 成本 | 无治理成本；上限略低于 (b)（G 1.419→N3g 1.161 的 apply 段 + N0 +92 的帧段都有 qjs 参照）；若打穿即证明「不需要 bypass 也能追平」，反过来为 (a) 铺路 |

**driver 建议 (c) 先行**：R9 按 (c) 设计；若 R9 后 raytrace 仍距 1.0 显著，(b) 再议。

## 1. Lane R9-N「构造真帧成本对齐」（CPU 5）

靶：**N0 空 new 1.553（+92 cyc）**——真帧构造的每次固定开销。
方法：R8-C 的 N0 case 秒级载具 + R5-C 反汇编样张，逐指令对照 qjs `OP_call_constructor`
→ `JS_CallConstructorInternal` 路径（自行定位行号），把 +92 分解到
帧建/参数/proto 取/`new.target`/返回值判定/帧拆各段，逐段 FAITHFUL 瘦身。
**吸收 R6-K leaf-call 刀的验收结论**（若 zoo 通过合入，N0 基线先更新再开工）。
验收：N0 case 比值 → ≤1.1；N3g（真帧 3 字段）1.161 同步收敛；N3 bypass 路径不许碰。

## 2. Lane R9-G「G 形 apply 转发成本对齐」（CPU 6）

靶：G 1.419 与 N3g 1.161 之间的 **apply/arguments 段**（≈R7-R2）。
G 形 = ctor 体只有 `this.initialize.apply(this, arguments)`。
方法：C_G_apply_ctor.js 载具；对照 qjs 同形（qjs 跑同一 JS 的机器路径：
mapped arguments 建/`build_arg_list`/apply 展开/嵌套调用），
zjs 侧逐段定价（arguments 对象建、逐元素搬运、二次帧）。
已知历史：`build_arg_list` length 前缀已对齐（fb680e41）、mapped 臂三 class 已对齐
（2e5657f4）——**先量残余在哪一段再动手**（合同第 9 条）。
验收：G case → ≤1.2；raytrace 单基准 driver 复测；deltablue/richards 方向观察。

## 3. Lane R9-V「宏观验证与回归守护」（driver；CPU 19）

- R6-K zoo 3-pad 判读（在途）→ 合入决策；
- R9-N/R9-G 每出一刀：raytrace 单基准 16 samples 快验 → 批末组包 3-pad 全套
  逐基准 lineage 判读；四资产 + N3 反超（0.871）不许回退。

## 4. 契约

R6-K 同款（唯一写 src 的批次约束：一改动一 commit、ReleaseSafe 必验
【帧生命周期红线】、lint=0、difftest 语义面抽样、AWAIT-MEASURE 协议、
worktree `worktree-grok-r9-{n,g}`、分支 `grok/opt-r9-*`）。
⛔ 不碰：N3 bypass 本体、布局/padding（SEQUENCED-LAST）、B 类机制（PARKED）。

## 5. R9 之后的队列（复盘 §2 的体制排序）

R10 = EB 命名桶开刀（闭包/var_ref +223M、GC 环收集 +193M，从未动过）；
R11 = TS 的 RC destroy/trace + `pushExactSimpleFrame`；
最后 = 布局工程批（get-arg 热段、热 handler 聚簇）＋（若仍需）B 裁决重启。

## 6. 结果表（执行后填写）

| lane | 状态 | 实测 |
|---|---|---|
| （待裁决/执行） | | |
