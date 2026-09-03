# GC 战役负值归档（2026-08-31）

## 结论先行

本轮从五引擎调研进入三条实现 lane，经一次集中反思后拆成归因 lane 群。
所有进入实现的候选都被预注册线否决；已经成立的局部收益只保留为复活条件，
不改写为可合并结论。本页只汇总已归档报告中的数字，不收临时二进制、JSON 或
日志。

| 候选 | 已成立的局部结果 | 否决点 |
|---|---|---|
| minor 阈值反馈 | EB minor `9,348 → 2,975`，下降 `3.142x` | EB MaxRSS `+51.61%`，DeltaBlue instructions `1.003474×` |
| settle class 扩门 | 无 | 三个目标负载的 class miss 均为 `0` |
| settle active/empty 收窄 | EB active-veto 理想上限约 `0.042%` | 低于 `0.2%` 开工线 |
| 无 RC 属性对象短路 | splay instructions `−0.4705%` | EB `+0.2422%`、RegExp `+0.1560%`，均越过写路径 `+0.1%` 线 |
| partial refill | Delta/PDF/Ray committed/live 改善 `44.30% / 52.79% / 93.98%` | EB/Ray/splay instructions `1.006112× / 1.003781× / 1.008379×` |
| demand-side partial refill v2 | Ray/PDF committed/live `−94.43% / −55.38%`，splay 包络 `−3.91%` | EB/Ray/splay instructions `1.003442× / 1.004588× / 1.005450×` |
| block black allocation v1 | splay instructions `0.928417984×`，publication call 减少 `99.078879%` | splay committed peak `+4.800%`；EB 在 PMU 下 SIGSEGV，无有效 ratio |
| block black allocation 复活线 | Phase A 在 `0894f072` 修复浮动垃圾悬空边洞 | Phase B splay instructions `1.004386706×`、peak `+4.032258%`、overflow `8 → 9` |

数字出处：[minor 阈值反馈报告](reports/gc-campaign-2026-08-31/minor-threshold-feedback.md#预注册验收线逐条对账)、
[settle 候选报告](reports/gc-campaign-2026-08-31/settle-candidates.md#2-候选刀定价与裁决)、
[partial-refill 报告](reports/gc-campaign-2026-08-31/a2-envelope-partial-refill.md#7-预注册验收线逐条对账)、
[demand-refill v2 报告](reports/gc-campaign-2026-08-31/a2-envelope-demand-refill-v2.md#6-预注册验收线逐条对账)、
[block black-allocation v1 报告](reports/gc-campaign-2026-08-31/block-black-allocation.md#预注册验收逐条对账)、
[Phase A 根因报告](reports/gc-campaign-2026-08-31/blackalloc-phase-a-root-cause.md#3-根因命名与机制全链)、
[blackalloc 复活线终局报告](reports/gc-campaign-2026-08-31/blackalloc-revival-final.md#结论)。

## 实现候选逐刀归档

### minor 阈值反馈

- **预注册线：**EB minor 至少下降 `3x`；六负载 instructions 各不高于
  `1.003×`；EB 与 splay MaxRSS 涨幅各不高于 `5%`。
- **死因：**minor 从 `9,348` 降到 `2,975`，`3.142x` 目标成立；但 EB MaxRSS
  从 `63,012 KiB` 升到 `95,536 KiB`，即 `+51.61%`，DeltaBlue instructions
  为 `1.003474×`。扫描中 `64K` 上界仍有 `97,464 KiB`；`32K` 点只有
  `1.94x` 降次且约 `+30%` MaxRSS，因此已测点不存在“至少 `3x` 且至多
  `+5%`”的交集。
- **复活条件：**先解决 safepoint 间 young 批量超调、minor 后整 block 的
  reuse/decommit 生命周期或 nursery 与 major pacing 耦合；不能只继续缩小
  threshold max。

出处：[minor 阈值反馈报告，验收线与风险边界](reports/gc-campaign-2026-08-31/minor-threshold-feedback.md#风险与后续边界)。

### settle class 门槛

- **预注册线：**先普查 class 门外是否存在可结算分母；没有样本就不实现。
- **死因：**splay、EB、PDF.js 的 class miss 都是 `0`；三者 settle attempts
  分别为 `10,311,720 / 98,067,805 / 2,749,693`，现有标准 class 已在门内。
- **复活条件：**只有 class 表或 inline-payload 策略变化后，才重新普查定价。

出处：[settle 候选报告，刀一与遗留边界](reports/gc-campaign-2026-08-31/settle-candidates.md#刀-1扩-settle-class-门槛--killed无可扩分母)。

### settle active/empty block 否决

- **预注册线：**理想收益至少达到 `0.2%`，才支付 allocator 热路径状态转换的
  实现成本。
- **死因：**EB 即使收掉全部 `6.525 M` active veto，按每 corpse `29`
  instructions 定价，也只有 `0.189 G` instructions、约 `0.042%` 整程上限；
  splay active+empty 的理想上限约 `0.00047%`。
- **复活条件：**active block 表示或 allocator handoff 已因其它工作改变时，必须
  重新 census 和定价，不能沿用本轮上限直接开工。

出处：[settle 候选报告，刀三与遗留边界](reports/gc-campaign-2026-08-31/settle-candidates.md#刀-3收窄-activeempty-block-否决--killed命中多但价值上限不够)。

### 无 RC 属性对象免逐槽析构

- **预注册线：**至少一个目标负载改善 `0.2%`，六负载总体均不差于 `+0.3%`，
  且这把刀自己的写路径成本每个负载不超过 `+0.1%`；splay settle miss 还需
  至少下降 `30%`。
- **死因：**splay instructions 改善 `−0.4705%`，但 EB 与 RegExp 分别回归
  `+0.2422% / +0.1560%`，越过独立写成本线；settle miss 中位数还从
  `4,310` 升到 `4,587`，即 `+6.43%`，方向与 `−30%` 要求相反。
- **复活条件：**只有既有写屏障能无额外热路径成本携带 cleanup summary bit 时，
  才值得重开；已经证明的分母与 summary 正确性本身不足以抵消写税。

出处：[settle 候选报告，刀二及预注册对账](reports/gc-campaign-2026-08-31/settle-candidates.md#刀-2无-rc-属性对象免逐槽析构--killed机制成立成本线失败)。

### minor partial refill

- **预注册线：**桌面可支配份额先达到 `75%` 才开工；落地时三个目标负载中至少
  两个的 committed/live 改善达到 `25%`，六负载 instructions 各不高于
  `1.003×`，且 splay 包络不劣化。
- **死因：**DeltaBlue、PDF.js、RayTrace 的 committed/live 分别改善
  `44.30% / 52.79% / 93.98%`，但 EB、RayTrace、splay instructions 分别为
  `1.006112× / 1.003781× / 1.008379×`；splay 配对包络 factor 为 `1.005026`，
  即劣化 `0.50%`。机制命中，但指令税和 splay 包络同时失败。
- **复活条件：**需要避免每次 minor retirement 扫描或发布整批 young blocks，
  同时仍保证 splay 包络不劣化；原验收线保持不变。

出处：[A2 包络与 partial-refill 报告，桌面上限及验收对账](reports/gc-campaign-2026-08-31/a2-envelope-partial-refill.md#7-预注册验收线逐条对账)。

### demand-side partial refill v2

- **预注册线：**三个目标负载中至少两个 committed/live 改善达到 `25%`，目标
  minflt 不高于 baseline 的 `1.2×`，六负载 instructions 各不高于 `1.003×`，
  且 splay committed/live 与 minor/major 不劣化。
- **内存侧：**验收线全部通过；RayTrace、PDF.js committed/live 分别为
  `−94.43% / −55.38%`，splay 包络为 `−3.91%`，minor/major 仍为 `6 / 12`。
- **指令侧：**三项硬失败；EB、RayTrace、splay instructions 分别为
  `1.003442× / 1.004588× / 1.005450×`，均越过 `1.003×`。
- **死亡层：**需求侧拉取消除了上一版的 splay 包络失败，却仍要支付
  minor 候选 block 分类/挂链、allocator demand miss 的资格检查与 interval
  rebuild、major 撤销未消费链这些回填分配内生代价。
- **终局连锁：**owner 原裁决是维持 **KILLED**、等待 black allocation 重定价；
  该重定价现已在 Phase B 失败，复活条件落空，因此 refill-v2 维持 KILLED。

出处：[demand-side partial-refill v2 报告，验收对账](reports/gc-campaign-2026-08-31/a2-envelope-demand-refill-v2.md#6-预注册验收线逐条对账)、
[死亡层与后续边界](reports/gc-campaign-2026-08-31/a2-envelope-demand-refill-v2.md#8-死亡层与后续边界)。

### block 级 black allocation：v1 与复活线终局

- **v1 预注册线：**splay instructions 不高于 `1.000×`，其余负载各不高于
  `1.003×`；splay 与 EB block committed peak 涨幅不超过 `3%`。
- **v1 死因：**splay instructions `0.928417984×`、`publishGreyCold` 调用减少
  `99.078879%` 都成立，但 committed peak 从 `262,144,000 B` 升到
  `274,726,912 B`，即 `+4.800%`。此外 candidate 在 EB 的 `perf stat`
  运行中稳定 SIGSEGV，只有崩溃前的 `173,190,716,581` 条 instructions，不能
  伪造完整 ratio。
- **Phase A 根因：**black-allocation 块级豁免产生了**浮动垃圾悬空边洞**。
  `attachFunctionCaptures` 的历史合法顺序是先发布闭包，再把 capture array 挂上并
  裸填 var_ref；publication skip 撤掉 published-grey queue 的兜底后，黑块保留了
  已死 closure cell，却让未 shade 的 child 同周期被释放，后续保守根扫描再复活
  closure 时踩中悬空边。
- **Phase A 修复：**`shadeBlackAllocationSurvivors@0894f072` 在 finish pause
  内补回“保留 cell 同时保留 child graph”的安全网。它还顺带修复 weak/ephemeron
  把无 mark 的可达黑对象当死物，以及 ex-black 老 cell 缺 sticky mark 两项同根
  风险；两者都是 black-allocation 机制引入的副作用，不是 main 原有 bug。
- **Phase B 终局：**最终 `N=4` pacing 仍被三条硬线否决：splay instructions
  `1.004386706×` 对 `0.96×`，committed peak `+4.032258%` 对 `+3%`，
  mark-queue overflow 最大值 `8 → 9`。v1 的 `0.9284` 有一部分来自正确性洞本身，
  不能作为修复后收益；复活线维持 **KILLED**。
- **归档边界：**`0894f072` 属于实验分支上的 Phase A correctness 成果；本分支
  只归档报告，不带入该源码 commit，也不自行拆分或合并机制。

出处：[v1 PMU 与空间硬线](reports/gc-campaign-2026-08-31/block-black-allocation.md#6-splay--eb-block-committed-峰值涨幅不超过-3--fail)、
[Phase A 根因与修复](reports/gc-campaign-2026-08-31/blackalloc-phase-a-root-cause.md#4-修复)、
[Phase B 验收对账](reports/gc-campaign-2026-08-31/blackalloc-revival-final.md#验收线逐条对账)、
[负值解释与交接](reports/gc-campaign-2026-08-31/blackalloc-revival-final.md#负值解释与交接)。

## 两次账面校准

### 当前提交的 committed/live 实测账

以下为 `main@7c067f01` 冻结产物的四轮中位数，不沿用历史文档读数：

| 负载 | committed bytes | live bytes | committed/live | minor / major | terminal pending |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | `9,871,360` | `2,038,592` | `4.842244×` | `559 / 29` | `0/4` |
| PDF.js | `22,269,952` | `3,347,368` | `6.652974×` | `154 / 7` | `0/4` |
| RayTrace | `85,708,800` | `2,160,216` | `39.676033×` | `2620 / 4` | `0/4` |
| splay | `261,095,424` | `182,094,392` | `1.439722×` | `6 / 12` | `3/4` |

出处：[A2 包络报告，当前基线重测](reports/gc-campaign-2026-08-31/a2-envelope-partial-refill.md#22-当前基线不沿用旧文档读数)。

### 历史 pause-baseline 读数状态

`docs/pause-baseline-2026-08-29.md` 中的历史序列 `7.09× / 6.77× / 4.74×`
只作为旧输入，统一标记为 **stale**；本轮裁决只使用上表当前提交的实测值。
代表快照的四项分解必须逐行守恒到 committed，不能把各列独立中位数相加成
伪守恒。

出处：[A2 包络报告，口径与 stale 说明](reports/gc-campaign-2026-08-31/a2-envelope-partial-refill.md#22-当前基线不沿用旧文档读数)。

## 三项桌面定价关闭

### MU 增长模型

特定模型使用 `MU=0.97`，把 `F` 夹在 `[1.1, 4.0]`。六负载逐 major 先代公式、
再 clamp、最后取中位数，结果全部为 `F=4.0`。Splay 的 `F≥2.0` 条件通过，
但 DeltaBlue、PDF.js、RayTrace 各自的 `F≤1.4` 条件全部失败；AND 判据因此
Reject。这个结论只关闭该公式、该 MU 与该 clamp，不外推到所有自适应增长策略。

出处：[归因与定价报告，MU 模型裁决](reports/gc-campaign-2026-08-31/attribution-and-pricing.md#预注册裁决reject)。

### marking 第二刀

Splay 两腿 narrow marking 份额中位数为 `6.3857%`，按
`S×0.70×0.40` 得整程残余上限 `1.7880%`；EB 对照上限只有 `0.2609%`。
这个总上限不能关闭整个 marking 侧，但已测的 `popPrefetch` 消融中，off/base
cycles 中位数是 `1.002889×`，现有预取只兑现 `0.2889%` 整程 cycles，达不到
一条 `≥1%` 第二刀的规模。若再开刀，必须先取得新的来源证据。

出处：[归因与定价报告，marking 份额与 prefetch 消融](reports/gc-campaign-2026-08-31/attribution-and-pricing.md#任务-1splay-marking-侧不能被桌面关闭但两个候选均不足-1)。

### 并行标记的单核事实

受控合同固定 `CPU 19`，affinity 可见 CPU 数为 `1`；helper 计算因此恒为 `0`。
在这套合同里，bitmap claim 竞争的归因是整程 `0%`、marking `0%`。另开多核
会改变测量拓扑，不能与该组数字混用；本轮据此关闭“单核合同里靠消除 helper
竞争取得收益”的桌面候选。

出处：[归因与定价报告，并行 marker 消融](reports/gc-campaign-2026-08-31/attribution-and-pricing.md#消融-1受控-cpu-19-跑法中不存在-helper-claim-竞争)。

## 终局状态

block black allocation 的 Phase A correctness 根因已闭合，但 Phase B 复活线
KILLED；其重定价失败也使 demand-side partial-refill v2 的等待条件落空，后者
维持 KILLED。本分支只含证据归档，不含任何实验源码。

## 原始报告索引

- [minor 阈值反馈 KILLED 报告](reports/gc-campaign-2026-08-31/minor-threshold-feedback.md)
- [GC 归因与桌面定价报告](reports/gc-campaign-2026-08-31/attribution-and-pricing.md)
- [settle 三刀 KILLED 报告](reports/gc-campaign-2026-08-31/settle-candidates.md)
- [A2 包络与 partial-refill KILLED 报告](reports/gc-campaign-2026-08-31/a2-envelope-partial-refill.md)
- [A2 包络与 demand-side partial-refill v2 KILLED 报告](reports/gc-campaign-2026-08-31/a2-envelope-demand-refill-v2.md)
- [block black-allocation v1 KILLED 报告](reports/gc-campaign-2026-08-31/block-black-allocation.md)
- [block black-allocation Phase A 根因与修复报告](reports/gc-campaign-2026-08-31/blackalloc-phase-a-root-cause.md)
- [block black-allocation 复活线终局报告](reports/gc-campaign-2026-08-31/blackalloc-revival-final.md)
