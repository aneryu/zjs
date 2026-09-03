# GC v2 S2/S3 进展总览（2026-09-01）

## 结论先行

截至本页，production main 的系统锚点仍是 S1 `8aba23bd`。S2 的 block-lifecycle
与 growth 收紧都已完成定价，但前者被结构/缺页/包络硬线否决，后者选择保持默认
growth `2.0`；因此 S2 没有新的 production 机制进入 main。S3 已完成 header-v2
设计收口、frontier safety 先行件、carrier authority Slice 1 的三轮实现/评审，以及
Slice 2 和 obj64④ 的字段级 scout；这些仍是 archive/scout 资产，不是 physical layout
切换授权。

本页只汇总归档报告的结论。报告中引用的冻结二进制、PMU JSON、日志和临时仪表没有
入库；每个数字均在相邻的来源报告中出现。

## S1：已合入的计量锚点

S1 最终候选 `8aba23bd` 相对 `7c067f01` 的 quiet-window 终裁四项全过：splay
cycles `0.954208358`，六负载 cycles geomean `0.997932526`，Earley-Boyer
instructions `1.002452616`，其余五负载 instructions 最大值为 PDF.js
`1.000439993`。这些数值逐字来自原始
`/home/aneryu/worktrees/gc-infra/.scratch/REPORT_S1_FINAL_MEASURE.md`；该 S1 报告不在
本批指定的 S2/S3 原文清单内，故本批没有额外复制它。

进入 S2 后的报告也保留了 S1 的代价面：S2b 记录 splay cycles 已约改善 `4.6%`；
S2a 的 S1/pre-S1 对账则记录 splay MaxRSS `1.126913`、PDF.js MaxRSS
`1.250521`、PDF.js minflt `1.251497`、Earley-Boyer MaxRSS `1.136968`。这说明
S1 的吞吐收益成立，但 footprint 债不能从合入结论中抹去。
[来源：S2a](reports/gc-v2-20260901/s2a-block-lifecycle.md)、
[来源：S2b](reports/gc-v2-20260901/s2b-growth-factor.md)。

### S1 的两次 REJECT 教训

1. **Frontier quiescence 不能由瞬时 active 计数推断。** S1a 初版交叉评审指出，helper
   可在已观察 generation、尚未 `active++` 的窗口迟到；owner 只等 `active==0` 会提前
   返回，破坏无锁 `pushSingle` 的互斥前提。后续协议必须是 generation-scoped
   expected/completed 或 arrival/ack，并以两个确定性交错点证明 owner 不提前退出。
   [来源：S1a 交叉评审](reports/gc-v2-20260901/review-s1a.md)。
2. **Accounting checker 不能与被检统计共享同一 ownership walk。** P1 初版让
   `statsSnapshot` 和 `verifyHeapAccounting` 都从同一 iterator 派生；orphaned-accounted
   standalone Object 会同时从 actual/expected 两侧消失。后续 P1/S3 必须保留独立
   raw/lifecycle oracle，并在 `doomed_pending` 下统一 block 与 non-block corpse 口径。
   [来源：P1 交叉评审](reports/gc-v2-20260901/review-p1.md)。

这两次 REJECT 的共同边界是：并发完成、owned-allocation 与统计 expected 都必须有独立
authority；“另跑一次同源 iterator”或“当前没有观察到竞态”都不是证明。

## S2：机制完成，production 收官为不落地

### S2a block lifecycle：KILLED / ARCHIVED

S2a 把 demand refill、empty pacing、decommit 与 tail-superblock return 连成完整状态机，
正确性和最终全测通过；但三条独立硬线失败：PDF.js checker-v2 为 `2.0901×`，
DeltaBlue minflt 为 `2.054748× base`，splay committed/live paired factor 为
`1.209006×`。最终 PMU cycles 没有在这三条否决后继续采样，因此不能把 S2a 写成
cycles pass 或 performance-neutral。实现只归档在 `cf4607f7`。
[来源：S2a 报告](reports/gc-v2-20260901/s2a-block-lifecycle.md)。

### S2b growth：保持 2.0

growth `1.5 / 2.0` 的 splay cycles 为 `1.073327`、六负载 geomean 为
`1.010986`；`1.75 / 2.0` 分别为 `1.030306`、`1.005913`。两者都越过
splay `1.01` 硬线，且与 `2.0` 的差距没有进入 `<0.3%` 内存 tie-break 窗口。
虽然 splay median committed 从 `281 MiB` 降到 `251 MiB` 或 `237 MiB`，代价仍是
cycles `+3.03% / +7.33%`。因此合规结论是保留 production growth `2.0`，不改默认值。
[来源：S2b 报告](reports/gc-v2-20260901/s2b-growth-factor.md)。

S2 的收官判决不是“footprint 没有杠杆”，而是已测两类杠杆都不能同时满足现行吞吐、
缺页与 endpoint 包络合同。重开必须先有不依赖重复 `MADV_DONTNEED` 的结构降法，或在
新的系统组合锚点上重新预注册；不能继续调同一阈值制造更漂亮的 endpoint。

## S3：分片进度与当前停止线

### 设计与 S3-pre

A1v2 初稿的 8 B immutable header、per-kind carrier 和 block/extent 双载体方向保留，
但对抗评审要求补齐 exact / conservative-all-hits / diagnostic 三协议、持久 generation、
owned-vs-live 状态矩阵、独立 parity oracle、BigInt/Shape/Realm ABI 及 post-S1/S2 重锚。
[来源：A1v2 评审](reports/gc-v2-20260901/review-a1v2.md)。

S3-pre 初版 `3926e4c6` 的 correctness/mutant 全过，但严格冷构建组合中 `3/8`
instructions 单元越过 `1.001`，因此 NO-GO。V2 `2e433633` 把 requeue 从执行 mark
claim 改为检查既有 claim；加倍功率后 Earley-Boyer 通过，splay 的 `64` 个 paired
ratios 总中位仍为 `1.001583092 > 1.001`，继续 NO-GO。两版都只作为归档先行件。
[来源：S3-pre 初版](reports/gc-v2-20260901/s3pre-frontier-safety.md)、
[来源：S3-pre V2](reports/gc-v2-20260901/s3pre-frontier-safety-v2.md)。

### Slice 1：authority 资产保留，production gate 尚未过

Slice 1 初版 `ebea8cb8` 把零消费者 shadow authority 常驻 production，累计结果达到
splay instructions/cycles `1.712527813 / 1.490203761`，Earley-Boyer
`4.035906651 / 5.413951157`。V2 `754579db` 把 authority 收回 test/audit 门，性能回到
splay `1.001503049 / 0.996982783`、Earley-Boyer `1.000160428 / 1.001095331`，
但交叉评审仍 REJECT：同名 `resolveExact` 在 audit 与 production 提供不同保证，且单一
gate 会把 generation、extent identity、lifecycle 与 oracle 一次性 productionize。
[来源：Slice 1 初版](reports/gc-v2-20260901/s3-slice1-carrier-identity.md)、
[来源：Slice 1 V2](reports/gc-v2-20260901/s3-slice1-carrier-authority-v2.md)、
[来源：V2 交叉评审](reports/gc-v2-20260901/review-s3-slice1.md)。

V3 以 capability 拆开 strong exact/current membership，并把四个 production component
gate、footprint pin 与 compile-negative probe 固化。correctness 为 PASS，但快速 ABBA
的 cycles 仍失败：splay `1.002708905`，Earley-Boyer `1.033431548`；后者四个 ratio
都在 `[1.032588301, 1.043883581]`。当前证据更像链接布局/branch predictor 价格，
但未完成单函数因果二分，因此硬线仍判 NO-GO。V3 是下一轮 review 输入，不是 accepted
production authority。
[来源：Slice 1 V3](reports/gc-v2-20260901/s3-slice1-authority-capability-v3.md)。

Slice 1 的教训与 P1 一致：audit-only correctness 资产可以保留，但每个 production
side-authority component 必须和首个真实 consumer 同片翻转、独立 footprint pin、独立
mutation、独立 ABBA；不能预付“未来会用”的常驻写入。

### Slice 2 与 obj64④：只完成设计输入

Slice 2 scout 发现 `Header.next` 的生命周期借用者不止 tmp/doomed/deferred，还包括
zero-ref active owner、deinit hold stacks，以及未在本片建议翻转的 `gc_obj_list`/young
suffix。建议当前片只迁 destruction topology；若验收要求全局 borrower 为零，就必须把
高频 TraceLive/young authority 一并纳入并重新定价。extent queue/cursor 应使用稳定
`RecordId {slot,generation}`；block doom 继续用既有 bitmap/link，仅新增 parked bitplane
候选。开工前仍有两个 stop：driver 必须裁定本片是否包含 `gc_obj_list`/young，并冻结
Pass-A settle 的 raw-free/accounted 解释。
[来源：Slice 2 scout](reports/gc-v2-20260901/s3-slice2-scout.md)。

obj64④ 的物理算术也已重建：当前 ReleaseFast Object body 为 `40 / 56 / 72 B`，加
`8 B` prefix 后落 `48 / 64 / 80 B` class。A1v2 只把当前两个 `8 B` 字压为一个
`8 B HeaderV2`，slots2 raw 因而从 `80 B` 变成 `72 B`，仍落 `80 B` class；要进入
`64 B` 还需再省恰好 `8 B`。首选是 slots2 implicit `prop_values`，备选是仅在 fresh
census 证明极稀少后侧置 class payload，shape side/单项 32-bit 压缩不进入当前 S3。
[来源：obj64 census](reports/gc-v2-20260901/obj64-census.md)。

## Census 分岔判据

### C2-P0 pinability

- 对象级 direct pin 只占 young block-object live 的 `0.00064%--0.0633%`，因此
  **C2 object-only nursery 有条件 GO**：下一步应是 young-only allocator shadow 加
  object-level self-forward/pin 计数，不直接写完整 evacuator。
- whole-block pin 把 direct pin 放大 `205--383×`；Earley-Boyer weighted loss
  `24.24%`、minor loss `24.66%`、p95 `54.72%`，因此 **whole-block pin NO-GO**。
- exact overlap 在已完成负载间从 RegExp `8.21%` 到 PDF.js `89.17%`、splay
  `90.70%--93.48%`；Earley-Boyer exact 腿 `900 s` 超时。数据支持定向 C1 frame/handle
  migration，但不足以裁成全局 C1 或 pin ABI。

[来源：C2-P0 census](reports/gc-v2-20260901/c2p0-pinability-census.md)。

### S3 physical switch

S3 只有在实际 accepted `H_PRE` 上重新统计 slots2 population、payload coexistence、spill、
weakref、48/64/80 class、frontier 与 structural lines，才能冻结 obj64 方案和硬线。历史
`20.18M -> 12.14M (-40%)` 与 L1D refill `-9.2%` 只保留为方向假设；S1 已改变 frontier
拓扑，不能继承绝对端点。最终需要同时报告 `H_S3/H_PRE` 的物理切换增量和
`H_S3/H_S2` 的组合价值。
[来源：obj64 重锚建议](reports/gc-v2-20260901/obj64-census.md)。

## 归档索引与来源映射

本批指定的 `14` 份来源全部存在，未跳过：

| 归档文件 | 临时来源文件 |
|---|---|
| [S2a block lifecycle](reports/gc-v2-20260901/s2a-block-lifecycle.md) | `gc-settle/.scratch/REPORT_S2A.md` |
| [S2b growth](reports/gc-v2-20260901/s2b-growth-factor.md) | `gc-settle/.scratch/REPORT_S2B.md` |
| [C2-P0 census](reports/gc-v2-20260901/c2p0-pinability-census.md) | `gc-settle/.scratch/REPORT_C2P0.md` |
| [S3-pre](reports/gc-v2-20260901/s3pre-frontier-safety.md) | `gc-blackalloc/.scratch/REPORT_S3PRE.md` |
| [S3-pre V2](reports/gc-v2-20260901/s3pre-frontier-safety-v2.md) | `gc-blackalloc/.scratch/REPORT_S3PRE_V2.md` |
| [Slice 1](reports/gc-v2-20260901/s3-slice1-carrier-identity.md) | `gc-blackalloc/.scratch/REPORT_S3_SLICE1.md` |
| [Slice 1 V2](reports/gc-v2-20260901/s3-slice1-carrier-authority-v2.md) | `gc-blackalloc/.scratch/REPORT_S3_SLICE1_V2.md` |
| [Slice 1 V3](reports/gc-v2-20260901/s3-slice1-authority-capability-v3.md) | `gc-blackalloc/.scratch/REPORT_S3_SLICE1_V3.md` |
| [Slice 2 scout](reports/gc-v2-20260901/s3-slice2-scout.md) | `gc-minorfb/.scratch/SLICE2_SCOUT.md` |
| [A1v2 review](reports/gc-v2-20260901/review-a1v2.md) | `gc-minorfb/.scratch/REVIEW_A1V2.md` |
| [P1 review](reports/gc-v2-20260901/review-p1.md) | `gc-minorfb/.scratch/REVIEW_P1.md` |
| [Slice 1 review](reports/gc-v2-20260901/review-s3-slice1.md) | `gc-settle/.scratch/REVIEW_S3_SLICE1.md` |
| [S1a review](reports/gc-v2-20260901/review-s1a.md) | `gc-settle/.scratch/REVIEW_S1A.md` |
| [obj64 census](reports/gc-v2-20260901/obj64-census.md) | `gc-infra/.scratch/OBJ64_CENSUS.md` |

## 当前边界

- main 锚点：S1 `8aba23bd`。
- S2：KILLED/保持默认，没有新的 production commit。
- S3：S3-pre、Slice 1 实现均为 archive/review 输入；Slice 2 与 obj64④ 为零实现设计输入。
- 未授权 HeaderV2 physical switch、obj64 default switch、C2 evacuator、pin ABI 或 push。
