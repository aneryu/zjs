# GC v2 系统性优化设计 v0.1

Status: **DONE（2026-09-03）— S1/M 合入、S4a/S4b/S4c/S4d 裁决归档，见 gc-v2-completion-and-pivot-2026-09-03.md；后续由 tracing-gc-completion-plan.md 接管**
前置：docs/gc-architecture-review-2026-08-31.md（账目与选项）；本文是 owner「要整体系统性优化，不要局部单点」裁决（2026-08-31）的执行设计。证据：DIFFERENTIAL_REPORT / ALLOC_FORENSICS / CONSERVATIVE_RETIREMENT / WALK_ATTRIBUTION / REPORT5（refill 含内核复审）。

## 0. 系统性主张

八把单点刀死于「对现有结构的局部最优定价」：每把刀的对称成本/包络反弹都来自它试图单独移动一个与其他部件咬合的零件。v2 的主张是把五个互相咬合的子系统**按一个目标态一次设计、分期迁移**，使各期验收线互为松绑：

- 足迹下降（P-B）同时改善 alloc 局部性与缺页率（P-C 的 cycles 兑现依赖它）；
- 表示密度（P-A2）同时改善 marking 墙与足迹；
- frontier 修复（P-A1）消掉的全堆重扫本身就是足迹敏感路径。

## 1. 账与靶（splay trace vs 冻结 rc = +20.4pp cycles，全部已命名）

| 靶 | pp | v2 支柱 | 桌面可回收预期 |
|---|---:|---|---:|
| mark frontier 溢出全堆重扫 | +4.84 | P-A1 | ~4.5（机制消灭） |
| marking 内存墙（净） | +7.64 | P-A2 | 2~4 |
| kernel/缺页足迹税 | +9.04 | P-B | 4~7 |
| alloc front | +3.21 | P-C（~1pp 义务）+P-B（局部性） | 1~2 |
| barrier | +1.07 | P-A2 顺带 | 0~0.5 |
| condemnation/poll/gate | +0.4 净 | **P-D 明确不动**（gate 对 rc 净赢、零空转） | 0 |
| 死亡侧 | −7.9 | 已是赢项，保护不倒退 | — |

合计桌面预期：**12~17pp**，即 splay 从 1.204 收向 **1.03~1.08**。这是筛选值不是承诺；分期各有预注册线。

## 2. 五支柱

### P-A 标记基础设施 v2
**A1（第一刀，小而确定）：无界分段 frontier。** 65,536 固定 MarkStack + 65,536 固定 MPMC 环 + overflow 全堆重扫 → JSC/V8 式可增长分段 worklist（4KB 段链 + donation 保留、段整体转移），溢出降级路径彻底删除。验收：splay overflow 次数归零、走堆桶 pp 消失、并行标记 donation 语义不回退。
**A2（大刀，已有入口）：表示层切换。** A1v2 设计稿（docs/tracing-gc-header-v2-design.md，已 DRAFT）+ obj64 S2 合并为一次迁移：单 8B 不可变 header + side metadata + 64B 线轴（跨 class 掉一条 demand line）。0B 已被法医否决，8B 目标维持。入口件已落：非块靶测 + ①退链表（gc/obj-prereq-20260831）。

### P-B 堆生命周期 v2（refill 按 owner 裁决并入此处，不单独落地）
块状态机一次设计：分配 → active → minor 退役（O(1) 挂 young-retired 链）→ **需求侧回流**（换块慢路径 pop，含资格检查）→ empty → decommit/释放 pacing → superblock 归还。refill-v2 的实测背书：cycles(u+k) 净 −0.32%、五负载 maxrss 0.19~0.86×、Ray committed/live −94%。同期重定价 growth 2.0（新货币下 1.75/2.0 A/B）与 A2 gate 机制群。splay 包络劣化 5.25% 是本支柱设计内必须消化的已知项（与 pacing/growth 联动解，不再是单刀的孤立死因）。

### P-C 簿记合同 v2
法医 P1/P2/P4 统一：逐对象急切（alloc 位图/计数/字节账/发布位）→ 按块/interval 边界惰性 + JSC 式 no-safepoint/no-escape construction scope。~1pp 直接义务 + 给 P-A/P-B 提供更干净的权威（位图物化点与块状态机边界天然重合——这是「合同一起改比分开改便宜」的具体理由）。P6/P8（count/index 删除）维持 NO-GO。

### P-D 明确保护区（防「优化」倒退）
分配前 gate（对 rc 净赢）、poll 调度（零空转）、位图 condemnation（+0.13pp）、死亡侧全链（−7.9pp 赢项）、mark 预取。任何 v2 改动不得使这些桶劣化超过噪声。

### P-E 分代/移动分岔（设计内的显式决策门）
C2-P0 pinability census（1-2 lane-week）作为 S3 末的门：P-A/P-B 兑现后重测差分，若 splay 仍 >1.08 且 census pin 率低 → 开 C2 young-space copying（22-32 lw）；否则归档。C1 全精确（14-22 lw）仅在多平台/ABI 需求出现时重议。

## 3. 分期与门禁（货币：cycles(u+k) + committed/minflt + insn 对照列）

| 期 | 内容 | 预注册线（开工前细化钉死） | 依赖 |
|---|---|---|---|
| S0 | 方法论修正入 policy；批合并在案分支（infra/docs/obj-prereq） | batch-gate 绿 | — |
| S1 | P-A1 frontier + P-C 的 P1 小刀 | splay overflow=0；splay cycles(u+k) 改善 ≥3pp；六负载 geomean ≤1.000；全测绿 | S0 |
| S2 | P-B 块生命周期（refill 重实现 + pacing + growth 重定价一批） | 六负载 cycles(u+k) geomean ≤1.000 且 splay 单项 ≤1.000；A2 committed/live ≥3 负载 <2.0；splay 包络不劣于基线 | S1（新货币基线） |
| S3 | P-A2+P-C 主体：表示层切换 + 簿记合同（A1v2 过审后） | A1v2 文档内的预注册线（splay 标记线 −40%/L1D −9.2% 判别器）+ 表示 snapshot 逐行 rationale | A1v2 owner 过审 |
| S4 | 差分重测 → P-E census 决策门 | 新差分表；census pin 率报告 | S1-S3 |

每期批门禁沿用现行 policy（batch-gate + bisect），cycles 终裁安静窗口。

**裁决原则（owner 2026-08-31 追加）**：分期验收线只裁「该期是否入 main」；被线拦下的局部机制**不丢弃**——实现以 archive commit 形式保留在各自分支（含可复原 diff 与冻结二进制），S4 整体差分重测时按**组合收益**重新裁决（局部劣化若被其他支柱的收益覆盖，可在整体口径下翻案）。已有先例：refill-v2（REPORT5 翻案候选）、minorfb 候选（8e49a9fe）、blackalloc pacing（309bc0e3）。

## 4. owner 决策点

1. 本设计方向与分期批准；
2. A1v2 设计稿过审（S3 的门）；
3. S2 中 growth 重定价的裁决权保留给 owner（splay 敏感历史）；
4. S4 census 结果出来后的 P-E 裁决。
