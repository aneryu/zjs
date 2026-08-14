# OPT-R9 计划 — grok 第九批：raytrace 攻坚 + bypass 三阶段收束

日期：2026-08-14。制定者：driver。状态：**用户已裁决 (c) 分阶段路线，可派发**。
目标：raytrace 0.777 → ≥1.0（+1.7pp），并**零代价闭合 bypass 治理矛盾**。

## 0. 已裁决路线（用户批准，2026-08-14）

**Phase 1（本批 lane R9-N/R9-G）**：faithful 攻坚——bypass 不动不扩，
把 G/N0 形在真帧路径上对齐 qjs 成本。判据：**N3g 1.161 → ≤1.05**。
**Phase 2（Phase 1 达标后，driver）**：bypass 价值重估——`simple_ctor_bypass_enabled`
comptime 开关一行切换，跑「开 vs 关」zoo A/B；若增益缩到噪声内，
**执行 08-11 删除裁定，治理矛盾零代价闭合**。
**Phase 3（仅当 Phase 1 打不穿）**：真帧地板证实架构性时，「扩大 bypass」作为
诚实 fallback，与路径 B 一起作**政策**裁决（偏离账本+等价证明），不做单点例外。

**前置基线（R9-V 立即执行）**：现在就跑一次「bypass 关」的 zoo 全套，
刷新过时的 290-330M 删除定价，作为 Phase 2 的对照基线。

## 1. Lane R9-N「构造真帧成本对齐」（CPU 5）

靶：**N0 空 new 1.553（+92 cyc）**——真帧构造的每次固定开销。
方法：R8-C 的 N0 case 秒级载具 + R5-C 反汇编样张，逐指令对照 qjs `OP_call_constructor`
→ `JS_CallConstructorInternal` 路径（自行定位行号），把 +92 分解到
帧建/参数/proto 取/`new.target`/返回值判定/帧拆各段，逐段 FAITHFUL 瘦身。
**⚠️ 设计约束（R6-K pad0 教训）：原地瘦身现有 handler/路径，禁止克隆新 handler**
——R6-K 的 leaf-call 克隆刀 pad0 全线回退（deltablue −7.4%），与体制二结论一致：
handler 越多，256-way 分派的 I-cache 越糟。R6-K 终判（pads 3/7）出来前不吸收其改动；
若确认拒收，其 worktree 反汇编仍可作参照。
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

- **立即：bypass-off 基线**——`simple_ctor_bypass_enabled=false` 构建一次，
  zoo 全套单 pad 对照现 HEAD，刷新 bypass 的当前真实价值（Phase 2 对照基线）；
- R6-K zoo 3-pad 判读（在途，pad0 已 0.9833 预警）→ 合入/拒收终判；
- R9-N/R9-G 每出一刀：raytrace 单基准 16 samples 快验 → 批末组包 3-pad 全套
  逐基准 lineage 判读；四资产 + N3 反超（0.871）不许回退；
- Phase 1 达标（N3g ≤1.05）后执行 Phase 2 重估与（若达标）删除流程。

## 4. 契约

R6-K 同款（唯一写 src 的批次约束：一改动一 commit、ReleaseSafe 必验
【帧生命周期红线】、lint=0、difftest 语义面抽样、AWAIT-MEASURE 协议、
worktree `worktree-grok-r9-{n,g}`、分支 `grok/opt-r9-*`）。
⛔ 不碰：N3 bypass 本体、布局/padding（SEQUENCED-LAST）、B 类机制（PARKED）。

## 5. R9 之后的队列（复盘 §2 的体制排序）

R10 = EB 命名桶开刀（闭包/var_ref +223M、GC 环收集 +193M，从未动过）；
R11 = TS 的 RC destroy/trace + `pushExactSimpleFrame`；
最后 = 布局工程批（get-arg 热段、热 handler 聚簇）＋（若仍需）B 裁决重启。

## 6. 结果表（2026-08-14 Phase 1 收口）

| 靶 | 基线 | 两刀后 | 门 | 判 |
|---|---|---|---|---|
| N0 | 1.545 | 1.425 | ≤1.1 | 未过 |
| N3g | 1.156 | 1.107 | ≤1.05 | 接近未过 |
| G | 1.422 | 1.383 | ≤1.2 | 未过 |
| N3 | 0.877 | 0.867 | 不回退 | 过 |

两刀（`grok/opt-r9-n` @ a2653171，未克隆 handler，test-exec 436/436）：
① 3205fe0c 准入 same() 去 outline SameValue（zjs-only 税删除，N0 ~4%）；
② a2653171 热路径先探 own `.prototype` data slot。**driver 验收在途**（gate + 3-pad zoo）。

**⭐ G 段分解（本批最重要的战略数据）**：
`initialize.apply(this,arguments)` 1.42 → 直调 `initialize(a,b)` 1.31 → 字段写进 ctor 体 **0.97**。
⇒ apply 机器只值 ~0.11；**ctor 体内多一层方法调用值 ~0.34**——弥散调用常数在单 case 中的具象化。
faithful 手段到此为止（再往下=省略 arguments 对象=形态特判，已禁）。R9-G 空手收场是诚实结论。

**bypass-off（case 级）**：关掉只伤 N3 形（0.87→1.17），G/N0 纹丝不动——
**bypass 从来没有在帮 raytrace**；删除的 zoo 代价集中在 simple-ctor 重度基准（EB/splay/crypto）。

**Phase 1 判定：未打穿（N3g 1.107 > 1.05，不假装通过）。** 后续见 R10 §0 与总判读。

**两刀合入终判（driver，3-pad zoo）**：geomean **+0.27/+0.18/+0.20%** 三 pad 同号正向；
raytrace +2.26/—/+1.17；无基准三 pad 同号回退；资产无损；gate 0/49775（worktree+main 复核）。
②号刀 diff 核证=own `.prototype` data 槽内联快探（同语义读、首构造走全 helper、exotic 退避、
全构造器一致）。**已合入 main**。case 基线随之更新（N0 1.425 等），R10 的 delete-only
对照线须在 rebase 后重测。
