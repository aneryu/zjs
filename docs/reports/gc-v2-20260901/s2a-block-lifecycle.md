> 注：原始二进制证据在临时 worktree，未入库。

# GC v2 S2a：块生命周期 v2 归档报告

## 结论

**KILLED / ARCHIVED。** 候选实现和回归测试已按 driver 终审授权归档为
`gc/s2a-block-lifecycle-20260901@cf4607f7`；没有 push。

需求侧 refill、empty pacing、decommit 和 tail-superblock 归还已经连成一个可验证的
状态机，最终 `zig build test` 全绿。但预注册性能线机械失败：

- checker-v2 的三个绝对目标只有 DeltaBlue `1.8877×`、RayTrace `1.7695×`
  通过，PDF.js 仍为 **`2.0901×`**；
- 为把小 heap 压到这个水平，DeltaBlue 累计 decommit/recommit
  `47,493,120 / 45,834,240 B`，minflt 变成 **`2.054748× base`**；
- splay committed/live paired factor 为 **`1.209006×`**，虽然 minor/major 次数
  都保持 `6 / 11`。

三条都是冻结硬线，任一条已足够否决。继续加强同一 decommit 刀只会沿已经实测失败的
缺页交换面追 PDF 的剩余 `0.0901`，不再调参。

## 1. 基点与归档边界

- 分支：`gc/s2a-block-lifecycle-20260901`
- HEAD/基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`
- archive commit：`cf4607f758084cde94e0ea16ec1403def0232849`
- 最终性能候选：`.scratch/bin/zjs-s2a-i`
  - SHA-256：`2673334fab908c7efafc9b7de9603b43c2bd86c5001044e1dfd280b373463842`
- S1 基线：`.scratch/bin/zjs-s1-8aba23bd`
  - SHA-256：`9b7c8b2b751f24e188d60974d8a409eb4a0bba6310e3c47c4f0ea98e6c693503`
- 两臂配置均为：
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`
- tracked diff 只有：
  - `src/core/gc_block_heap.zig`
  - `src/core/gc_trace_stw.zig`
  - `src/tests/core.zig`

`.scratch/` 中同时保留了被淘汰的中间二进制、原始腿和分析脚本；报告不把中间候选
数据冒充最终候选门禁。

## 2. 实现的状态机

### 2.1 active → retired-young → refillable

- minor 尾部沿既有 young-block 链退役；`Block.young_link` 在清掉
  `flag_young` 后复用为每 size class 的 `young_retired_blocks` 链，Block header
  仍钉在 112 B。
- 退役只做 O(1) intrusive push。allocator 在 active block miss 时才 pop、重验
  parked/doomed/active/容量资格并按 alloc bitmap 重建 interval。
- major 或全局 deferred-destruction transaction 打开时，
  `young_retired_blocked` 会撤回所有 refill ownership；只有全局 Pass B 清空后再允许
  publication。最后一格的 Pass-A settlement 本来就被
  `canSettleDoomedCellInPassA` 否决，所以 pending 析构期间不会提前形成可复用 empty
  block。
- block 若在 retired 链上变空，会先摘链，再进入唯一的 empty/free owner；没有双重
  list ownership。

### 2.2 refillable → empty → decommit

- young-listed empty block 在 minor/major 的一次退役 pass 中转入 empty pool，避免
  final-cell free 对 singly-linked young list 做 O(n) 查找。
- settled collection tail 先退休 empty active block；100 ms wall-clock throttle 限制
  free-list 扫描频率，1 s idle 线保留 aged decommit。
- speculative arm 只在 heap-wide empty-block density `>= 1/3` 时打开，每 class 留一块
  committed locality reserve。这个门不命名负载：splay 的实测低-density basin 不进
  speculative arm，Delta/PDF 的高水位会进入。
- refault feedback：大 heap（至少 6 个 superblock）发生 recommit 后暂停 speculative
  arm；只有 initialized high-water 再增长至少一个 superblock 且至少 25% 才重开，
  把 EB 的稳定工作集 oscillation 从“随 collection 次数”改成“随高水位增长”。小 heap
  为了对抗 2 MiB checker floor 允许受 100 ms throttle 限制的 retry；最终正是这条
  在 Delta 上被 minflt 硬线否决。

### 2.3 decommit → superblock return

- 全空 tail classed superblock 只有在每个 initialized block 都已 decommitted、仍在
  free list 且没有 young/doomed/hot ownership 时才能归还。
- 归还同时删除 `classed_blocks` 精确索引、重建 bloom filter、修正 committed 与
  decommitted retirement 账；至少保留一个 classed superblock locality floor。
- `Stats` 增加 `retired_decommitted_bytes` 与 `superblock_releases`，64 位大小显式钉为
  184 B；`currentDecommittedBytes` 排除已经随 mapping 一起退休的页。
- 最终设计删除了早期调参用的 per-class initialized-count side authority；density 直接
  用既有 exact block set 数量和 `Superblock.page_bits` 非空索引，避免为收 S1 footprint
  债再留下一个常驻数组。

## 3. 正确性与测试

新增/扩展的定向用例实际覆盖：

1. minor retirement 后 partial young block 可在 demand miss 被拉回；
2. retired block 变空时从 refill 链转入 empty pool；
3. open destruction transaction 撤回 refill ownership；
4. 真实 runtime 的 minor → retired → demand refill 全链，并在三个边界调用独立
   `verifyHeapAccounting`；P1 oracle 没有 refill credit/debit 特例；
5. active-empty retirement、density decommit、100 ms throttle；
6. 低于 1/3 density 时不 speculative decommit；
7. refault suspension 只有跨过 material high-water growth 才 rearm；
8. 完整 decommit 的 tail superblock 被归还；
9. aged decommit/recommit 与统计闭合。

验证结果：

- red 证据：实现前新增测试因缺少 `retireYoungBlocksAfterMinor` /
  `superblock_releases` 编译失败；
- `zig build check`：PASS（最终源码）；
- `zig build test-core --summary all`：`479 passed / 6 skipped / 0 failed`；
- `git diff --check`：PASS；
- 首次 `zig build test --summary all`：`2509 passed / 6 skipped / 2 failed`，两处都为
  empty `test262/` 导致的 `FileNotFound`；
- 按 `docs/verification-policy.md` 的 linked-worktree 环境条款运行
  `mise run worktree-init`，只创建不入提交的 corpus symlink；
- 最终 `zig build test --summary all`：**`2511 passed / 6 skipped / 0 failed`**，
  9/9 steps succeeded。完整日志：`.scratch/s2a-final-zig-build-test.log`，SHA-256
  `9b6ba86504c681b4abac912c56146e16c648786b993a2ff0aa9e0c687970388d`。

## 4. 最终性能 screen

### 4.1 合同

- CPU19 + `/tmp/zjs-host-heavy.lock`；测量开始/结束三秒 idle 分别为
  `99.67% / 100.00%`；开始前无 `zig` / `zjs`。
- 每负载顺序 base/candidate/candidate/base；ratio 是 candidate/base 相邻配对后取
  中位数；20 条腿全部 exit 0、stderr 为空。
- checker-v2 权威口径为
  `committed / max(live, 2,097,152)`，不是把 2 MiB 加到 live。早期分析脚本曾误写成
  加法，已在裁决前纠正；错误口径没有用于通过判定。
- 原始目录：`.scratch/raw/s2a-pilot-small-retry/`；runner：
  `.scratch/run-s2a-pilot2.sh`。

### 4.2 committed/live、minflt、maxrss

| 负载 | candidate checker-v2 | raw C/L paired factor | minflt factor | maxrss factor |
|---|---:|---:|---:|---:|
| DeltaBlue | `1.8877× / 1.8877×` | `0.342931` | **`2.054748`** | `0.800456` |
| Earley-Boyer | `1.5825× / 1.5730×` | `0.582206` | `0.947213` | `0.663594` |
| PDF.js | **`2.0901× / 2.0901×`** | `0.271216` | `0.948849` | `0.857718` |
| RayTrace | `1.7695× / 1.7695×` | `0.085909` | `0.120207` | `0.174831` |
| splay | `2.9484× / 2.9447×` | **`1.209006`** | `0.990745` | `0.991056` |

splay 两个 paired C/L ratio 分别为 `1.238279 / 1.179733`，不是单腿翻线；四腿
minor/major 都是 `6 / 11`。四腿也都 terminal pending，base/candidate 对称，因此不能
把 C/L 失败归咎于只发生在一臂的 retirement 状态。

最终候选的六负载 PMU runner 曾在 exclusive lock 后排队，但前序 lane 正在执行长矩阵；
在上述三条硬失败成立后取消了尚未采样的等待 wrapper（exit 130，样本数 0）。因此本报告
不声称最终候选通过 cycles gate。较早、不同 pacing 候选的 PMU 原始数据仍在
`.scratch/raw/s2a-final-hysteresis/`，只记录探索方向，不用于最终验收。

## 5. S1 新增内存债务结算

按 driver 追加的 S1 终裁诊断列，把本轮 candidate/S1 factor 乘回 S1/pre-S1 factor：

| 账目 | S1 / pre-S1 | S2a / S1 | S2a / pre-S1 | 结论 |
|---|---:|---:|---:|---|
| splay maxrss | `1.126913` | `0.991056` | **`1.116834`** | 仍回归 `+11.68%` |
| PDF.js maxrss | `1.250521` | `0.857718` | **`1.072594`** | 仍回归 `+7.26%` |
| PDF.js minflt | `1.251497` | `0.948849` | **`1.187482`** | 仍回归 `+18.75%` |
| EB maxrss | `1.136968` | `0.663594` | `0.754485` | 已收回，净改善 `24.55%` |

所以新账也没有整体收完：EB 的 frontier/side-authority footprint 被 refill 收益覆盖，但
splay peak RSS 基本不动，PDF 的 RSS/minflt 仍高于 pre-S1。即便忽略绝对 C/L 与 Delta
minflt 两条失败，这笔追加账也不能表述为“已偿清”。

## 6. 预注册验收逐条对账

| # | 验收线 | 结果 | 裁决 |
|---:|---|---|---|
| 1 | `zig build test` + 每个转移定向测试 + P1 oracle | 2511/6/0；九类转移测试；真实 minor/refill oracle 三边界对拍 | **PASS** |
| 2 | 六负载 cycles(u+k) geomean `<=1.000` 且 splay `<=1.000` | 最终候选未采样；此前不同 pacing 候选不能代替 | **NOT ESTABLISHED** |
| 3 | Delta/PDF/Ray checker-v2 全部 `<2.0` | `1.8877 / 2.0901 / 1.7695`，2/3 | **FAIL** |
| 4 | splay C/L 与 minor/major factor `<=1.0` | C/L `1.209006`；minor/major `1.0 / 1.0` | **FAIL** |
| 5 | Delta/PDF/Ray minflt `<=base` | `2.054748 / 0.948849 / 0.120207` | **FAIL** |
| 6 | settled batch-gate 至少两轮 | 性能硬失败后未运行；且 verification policy 将昂贵 batch gate 归 driver 合并批 | **NOT RUN / 无合并资格** |

整体裁决不依赖未测的 gate 2：gate 3、4、5 已各自独立触发 archive 条款。

## 7. 死因层与后续边界

1. **不是状态机正确性死因。** ownership、P1 账本、pending transaction、empty/decommit
   和 mapping return 都有独立 checker/测试，最终全量测试绿。
2. **第一层硬死因是 decommit/refault 交换。** 大 heap feedback 能抑制 EB storm；但
   checker 的 2 MiB floor 迫使小 heap retry。它把 Delta 压到 `1.8877×` 的同时制造
   约 45.8 MiB recommit，minflt 直接翻倍。
3. **第二层是 PDF 剩余 floor。** 付出上述 retry 后仍只有 `2.0901×`，继续加刀必然沿
   已失败的缺页方向，而不是免费收益。
4. **第三层是 splay endpoint 包络。** density gate 成功让 splay decommit/recommit 为
   `0 / 0`，minor/major 不变，但 C/L 两个配对都劣于 1；不能以 live-at-exit 噪声事后
   删除硬线。
5. **S1 footprint 债只部分偿还。** EB 收回，PDF 与 splay 未收回，见第 5 节。

若未来重开，必须先获得一种不靠重复 `MADV_DONTNEED` 的 committed 降法（例如经独立
设计评审的页级实际 recommit authority 或对象布局/packing 变化），并重新预注册其热路
税与 oracle；不能继续放宽 density threshold、缩短 throttle 或用 terminal-only trim
制造好看的 endpoint。
