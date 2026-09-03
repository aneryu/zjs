> 注：原始二进制证据在临时 worktree，未入库。

# gc/a2-envelope-20260831 lane report

日期：2026-08-31
基线：`main@7c067f0101511df2bde8a5432940dc13be853e19`
分支：`gc/a2-envelope-20260831`
结论：**KILLED（partial-refill 候选不落地）**

本 lane 先完成 A2 committed 包络归因，再按桌面上限决定是否实现。四个候选机制中，只有 partial refill 在 RayTrace 上有超过 `3 × 25% = 75%` 的桌面上限，因此只实现了这一条最小候选。它确实大幅改善三个目标负载的 committed/live 和 minflt，但同时违反六负载 instructions 上限与 splay“不劣化”硬线，已按 brief 完整回滚。最终无源码改动、无 commit、无 push；原始证据保存在 `.scratch/`。

## 1. 测量合同与产物身份

- 开工前确认当前提交是 `7c067f01`、工作树干净，再创建本分支。
- ReleaseFast 构建固定在 CPU `0-14`；census、committed/minflt ABBA 与 PMU ABBA 固定在 CPU `19`，持有 `/tmp/zjs-host-heavy.lock` 排他锁。
- committed census 做 4 次，负载顺序正反平衡；候选比较逐负载按 base/candidate/candidate/base 执行。
- PMU 每引擎每负载 2 样本、paired ABBA，事件明确为 `armv8_pmuv3_1/instructions/`；wall-clock 不作证据。
- committed ABBA 前 CPU 19 平均 idle `99.67%`；PMU ABBA 前为 `100.00%`。一次 idle 只有 `93.98%` 的预检被拒绝，未启动子测量。
- 所有测量腿 exit 0、stderr 为空、基准结果行存在。
- 三个二进制配置签名相同：
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

| 产物 | SHA-256 |
|---|---|
| baseline `7c067f01` | `2830841f7d2b2992cec3386cf677fc99dbaf458a4f32e8b7ae6d85f7889ab959` |
| baseline + 临时 envelope census | `4c0d33488c1a2e456abefd9144f18877bb147c272cde01bb27f7e7cb1b06ec67` |
| partial-refill candidate（census off） | `9f0a5f793d39f16c6f659845f4f0ce0111804a645abff2a3aa9f0a9e30e63b6b` |
| Phase 1 汇总 JSON | `9d10b8ea5198750b04e29d7dac89a8c9de46e847dcbf9d7b285f193a378830c7` |
| 六负载 PMU JSON | `09380901888293904184521c48466518ec0eda0de602f247f51926a54a6976cd` |

四个 census fixed-work 输入 SHA-256：DeltaBlue `55a3f692…c48a`、PDF.js `b6328cef…8c94`、RayTrace `c70e5303…e45f`、splay `35ebfb84…e4a7`。PMU JSON 另逐负载记录拼接 fixed-work 的完整 hash、二进制 hash、逐腿计数和输出。

## 2. Phase 1：committed 分解 census

### 2.1 口径

临时 `--gc-stats` census 在 CLI 冷端点枚举 block heap；每个样本断言以下四项精确守恒到 `stats.committed_bytes`：

- `granularity_floor`：逐 class 按 `ceil(live_cells / block_capacity)` 个 64 KiB block 定价；
- `hole_resident`：nonempty block 数超过逐 class 理论最少 block 数的部分；
- `empty_high_water`：其余 classed committed，包括 empty/free、只留 header 页的 decommitted block 与 reserved-uninitialized block；
- `medium_large`：medium superblock 和 large map 单列。

Superblock 状态定义为：32 个 block 全 nonempty 是 dense，0 个 nonempty 是 empty，其余是 partial。空闲年龄档为 active、`<100 ms`（below scan period）、`100 ms..1 s`（scan-to-decommit）、`>=1 s` eligible、decommitted、uninitialized；不存在的档按 0 记录。census 与临时 CLI 输出在 Phase 2 前已从源码移除。

### 2.2 当前基线，不沿用旧文档读数

`docs/pause-baseline-2026-08-29.md` 的 ×7.09/×6.77/×4.74 是历史输入；本 lane 对 `main@7c067f01` 冻结产物重测。四轮中位数如下：

| 负载 | committed bytes | live bytes | committed/live | minor / major | terminal pending |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | 9,871,360 | 2,038,592 | 4.842244 | 559 / 29 | 0/4 |
| PDF.js | 22,269,952 | 3,347,368 | 6.652974 | 154 / 7 | 0/4 |
| RayTrace | 85,708,800 | 2,160,216 | 39.676033 | 2620 / 4 | 0/4 |
| splay | 261,095,424 | 182,094,392 | 1.439722 | 6 / 12 | 3/4 |

### 2.3 精确守恒分解

下表使用 Delta/PDF/Ray 第 1 轮和 splay 第 3 轮（该轮 terminal closed）的单个代表快照，避免把各列独立中位数相加造成伪守恒。括号内是该样本 committed 占比；四列逐行精确等于 committed。

| 负载（round） | committed/live | 粒度地板 | hole 驻留 | empty 高水位 | medium/large |
|---|---:|---:|---:|---:|---:|
| DeltaBlue (1) | 4.842244 | 2,162,688 (21.91%) | 2,097,152 (21.24%) | 5,611,520 (56.85%) | 0 |
| PDF.js (1) | 6.653022 | 3,473,408 (15.60%) | 5,832,704 (26.19%) | 12,963,840 (58.21%) | 0 |
| RayTrace (1) | 39.647444 | 2,293,760 (2.68%) | 80,347,136 (93.81%) | 3,006,464 (3.51%) | 0 |
| splay (3) | 1.382007 | 189,726,720 (72.96%) | 30,474,240 (11.72%) | 39,845,888 (15.32%) | 0 |

四轮逐列中位占比的 splay 是 floor 70.04%、hole 16.45%、empty 13.51%；其端点波动明显，因此候选验收使用配对比值，不拿单腿绝对值作结论。

### 2.4 state × class × idle-age 代表矩阵

表中单元格是 block 数；`D`/`P`/`E` 分别是 dense / partial / empty superblock 状态。未列年龄档均为 0，所有负载的 `>=1 s eligible` 都是 0。

| 负载 | state / age | class 48 | class 64 | class 80 | uninitialized |
|---|---|---:|---:|---:|---:|
| DeltaBlue | P / live | 35 | 29 | 1 | 0 |
|  | P / scan-to-decommit | 28 | 30 | 0 | 0 |
|  | P / decommitted | 9 | 1 | 0 | 0 |
|  | P / uninitialized | 0 | 0 | 0 | 27 |
| PDF.js | D / live | 1 | 31 | 0 | 0 |
|  | P / live | 6 | 94 | 10 | 0 |
|  | P / below-scan | 0 | 1 | 0 | 0 |
|  | P / scan-to-decommit | 13 | 174 | 0 | 0 |
|  | P / decommitted | 0 | 12 | 1 | 0 |
|  | P / uninitialized | 0 | 0 | 0 | 9 |
| RayTrace | D / live | 1,087 | 1 | 0 | 0 |
|  | P / live | 170 | 2 | 1 | 0 |
|  | P / below-scan | 10 | 0 | 0 | 0 |
|  | P / decommitted | 45 | 1 | 0 | 0 |
|  | P / uninitialized | 0 | 0 | 0 | 27 |
|  | E / decommitted | 96 | 0 | 0 | 0 |
| splay | D / live | 115 | 698 | 1,523 | 0 |
|  | P / live | 42 | 306 | 676 | 0 |
|  | P / scan-to-decommit | 15 | 139 | 454 | 0 |

四轮 superblock state 中位数（dense / partial / empty）分别为：Delta `0 / 5 / 0`，PDF `1 / 10 / 0`，Ray `34 / 8 / 3`，splay `76.5 / 48.5 / 0`。空 block 的 aged decommit 服务并未失效：端点没有已达到 1 s 仍 committed 的 eligible block；问题主要是 1 s 内高水位和 nonempty block 铺开。

逐 class 的 live 理论最少 / 当前 nonempty block（代表快照）：

| 负载 | class 48 | class 64 | class 80 |
|---|---:|---:|---:|
| DeltaBlue | 19 / 35 | 13 / 29 | 1 / 1 |
| PDF.js | 6 / 7 | 38 / 125 | 9 / 10 |
| RayTrace | **32 / 1,257** | 2 / 3 | 1 / 1 |
| splay | 86 / 157 | 812 / 1,004 | 1,997 / 2,199 |

RayTrace 的 48-byte class 是决定性异常：只需 32 个 block 的 live cells 被铺在 1,257 个 nonempty block 上，直接解释 93.81% hole 份额。

## 3. 四个机制的桌面上限

数字是“理想消掉该机制可支配字节”后的 committed 改善百分比和结果 ×ratio；均用四轮中位统计。

| 机制 | DeltaBlue | PDF.js | RayTrace | splay | 75% 开工线 |
|---|---:|---:|---:|---:|---|
| (a) empty-SB release pacing | 0.00% → 4.842 | 0.00% → 6.653 | 0.46% → 39.494 | 0.00% → 1.440 | **桌面否决** |
| (b) partial refill | 21.24% → 3.814 | 26.19% → 4.910 | **93.81% → 2.454** | 16.45% → 1.203 | **进入 Phase 2** |
| (c) whole-block/SB aged decommit | 56.85% → 2.090 | 58.21% → 2.780 | 3.51% → 38.255 | 13.51% → 1.245 | **桌面否决** |
| (d) empty free-list sorting | 36.27% → 3.086 | 52.92% → 3.133 | 2.13% → 38.832 | 13.20% → 1.250 | **桌面否决** |

因此只允许实现 (b)。这里的 75% 是开工筛选，不是最终 `≥2/3` 负载改善 25% 的验收线；两条线均未放宽。

## 4. Phase 2：partial-refill 归因与临时候选

### 4.1 源码归因

minor Pass B 完成一个 block 后会调用 `onBlockPassBComplete` → `publishHotBlock`，但此时该 block 仍带 `flag_young`；`publishHotBlock` 明确拒绝 young block。minor 随后只在 `collectMinor` 尾部调用 `clearYoungBlocks` 清 flag/link，没有重试发布。于是 minor 制造的 partial holes 会一直搁浅，直到以后 major 的 whole-heap publication 才可能重新进入 allocator。

动态证据与此一致：RayTrace 基线有 2,620 次 minor，却只有 19 次 hot publish / reopen；候选把它提升到约 37.9k publish / reopen，同时把 class-48 铺开显著收回。这个机制是 block 生命周期 handoff，不改变 mark/condemn/barrier 语义。

### 4.2 最小候选

候选把 minor 尾部的“只清 young block list”替换为一次 block-granular retirement：

- 清除 `flag_young` 与 young link 后，只有全局 parked frees 已为 0 才调用现有 `publishHotBlock`；
- 非零 parked count 时只清理，不把仍处于两阶段析构事务的 block 交给 allocator；
- 每 young block 一次，不增加逐 cell 热路径；
- 新增针对性测试覆盖 parked frees 非零时拒绝发布、清零后发布 partial block。

候选 `zig build check` 通过；`zig build test-core` 为 **460 passed / 6 skipped / 0 failed**，新增测试实际执行。候选源码和测试在性能硬失败后均已移除。

## 5. committed/live 与 minflt ABBA

ratio factor 是每组相邻 base/candidate 的 candidate committed/live ÷ base committed/live，再取两组中位数；改善为 `1 - factor`。minflt 同样用配对 factor，越低越好。

| 负载 | base ×ratio 两腿 | candidate ×ratio 两腿 | paired factor | 改善 | minflt factor |
|---|---|---|---:|---:|---:|
| DeltaBlue | 4.842244 / 4.842244 | 2.697215 / 2.697215 | 0.557018 | **44.30%** | 0.707070 |
| PDF.js | 5.782318 / 5.782318 | 2.529564 / 2.930532 | 0.472137 | **52.79%** | 0.840875 |
| RayTrace | 39.735712 / 39.735712 | 2.457621 / 2.328833 | 0.060229 | **93.98%** | 0.121336 |
| splay | 1.514912 / 1.467426 | 1.452861 / 1.542284 | **1.005026** | **−0.50%** | 0.992997 |

三个目标负载全部超过 25%，minflt 全部远低于 `base × 1.2`。但 splay 配对中位数劣化 0.50%。更严格地排除 candidate 第 1 条 `terminal doomed_pending=true` 的腿后，剩余完整配对仍是 `1.051013`，即 **+5.10% 劣化**，所以不能以 pending 或噪声为由放宽“不劣化”线。四条 splay 腿的 completed minor/major 都是 `6 / 12`，次数本身没有劣化。

## 6. 六负载 instructions ABBA

JSON 中角色名沿用 runner 的 `zjs/qjs`；本轮 `zjs` 是 candidate，`qjs` 是 baseline，因此 ratio 正是 candidate / baseline。每项为 paired ratio median；MAD 也是 ratio 单位。

| 负载 | instructions ratio | Δ | paired-ratio MAD | ≤1.003 |
|---|---:|---:|---:|---|
| DeltaBlue | 1.001185 | +0.1185% | 0.000047 | PASS |
| Earley-Boyer | **1.006112** | **+0.6112%** | 0.000464 | **FAIL** |
| PDF.js | 0.999865 | −0.0135% | 0.000188 | PASS |
| RayTrace | **1.003781** | **+0.3781%** | 0.000378 | **FAIL** |
| RegExp | 0.999938 | −0.0062% | 0.000012 | PASS |
| splay | **1.008379** | **+0.8379%** | 0.007436 | **FAIL** |

Earley-Boyer 两个 paired ratio 都越线（1.005648 / 1.006576），RayTrace 两个也都越线（1.003403 / 1.004158）；不是单腿翻线。目标 `≤1.001` 更未达到。

## 7. 预注册验收线逐条对账

| # | 验收线 | 实测 | 裁决 |
|---:|---|---|---|
| 1 | 三个目标负载中至少 2 个 committed/live 改善 ≥25% | Delta 44.30%、PDF 52.79%、Ray 93.98%，3/3 | **PASS** |
| 2 | 六负载 instructions 各 ≤1.003 | EB 1.006112、Ray 1.003781、splay 1.008379 | **FAIL** |
| 3 | 目标负载 minflt ≤ base×1.2 | Delta 0.707×、PDF 0.841×、Ray 0.121× | **PASS** |
| 4 | splay committed/live 与 minor/major 不劣化 | ratio factor 1.005026；minor/major 仍 6/12 | **FAIL（包络）** |
| 5 | 全量测试绿；新机制有针对性测试 | 候选 check + test-core 通过；候选在两条性能硬失败后未再支付全量测试。回滚最终树全量测试 2490 passed / 6 skipped / 0 failed。 | **候选未取得落地证据；最终树 PASS** |

必要条件 2、4 独立失败，按“任一验收线失败即 KILLED 回滚”只能判定 **KILLED / 不合并**。

## 8. 最终验证与工作树

- 按 `docs/verification-policy.md` 先把空 `test262/` 临时替换为 `/home/aneryu/zjs/test262` symlink，执行 `set -o pipefail; taskset -c 0-14 zig build test | tee ...`：**2490 passed / 6 skipped / 0 failed / 0 filtered**，退出码 0。
- 测试后移除临时 symlink、恢复空目录；`git status --short --branch` 仅显示分支头，无 tracked 变更。
- `git diff --check` 通过。
- 按现行 verification policy，test262 / gate_smoke / arena audit 属于 driver merge-batch gate；本候选已回滚，不运行这些批门禁。
- 没有 commit，没有 push。

## 9. 结论与后续边界

1. A2 的主因不是单一 empty-SB 释放慢：Delta/PDF 的端点账以 `<1 s` empty 高水位为主，Ray 则是 minor 后 partial holes 没有及时回到 allocator，二者机制不同。
2. partial-refill 的归因和内存收益已经成立，失败点是可见的指令税与 splay 包络，而不是实现没命中。当前不应复制或合并这个候选。
3. (a)/(c)/(d) 都未达到 75% 开工线，保持桌面否决。若未来 allocator 生命周期因别的 lane 改变，应先重跑 census 重新定价，不沿用本次上限。
4. 若以后重开 partial refill，需要一种不在每次 minor retirement 扫描/发布整批 young blocks、且能保证 splay 包络不劣化的机制；验收线仍应原样保留。

## 10. 证据索引

- Phase 1 原始 census：`.scratch/raw/envelope/base/`
- Phase 1 机器汇总：`.scratch/raw/envelope/base-summary.json`
- census / ABBA runner：`.scratch/run-envelope-census.sh`、`.scratch/run-refill-abba.sh`
- committed/live + minflt ABBA：`.scratch/raw/envelope/refill-abba/`
- 六负载 instructions ABBA：`.scratch/raw/envelope/refill-instructions-six.json`
- PMU 控制台与 host 预检：`.scratch/logs/refill-instructions-six.log`、`.scratch/raw/envelope/refill-pmu/`
- 最终全量测试：`.scratch/logs/final-zig-build-test.log`
- 冻结二进制：`.scratch/bin/zjs-base`、`.scratch/bin/zjs-envelope-census`、`.scratch/bin/zjs-partial-refill`
