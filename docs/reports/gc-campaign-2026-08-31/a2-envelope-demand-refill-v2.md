> 注：原始二进制证据在临时 worktree，未入库。

# gc/a2-envelope-20260831 brief 3 report

日期：2026-08-31
基线：`main@7c067f0101511df2bde8a5432940dc13be853e19`
分支：`gc/a2-envelope-20260831`
结论：**KILLED（需求侧 partial-refill 第二版不落地）**

REPORT2 的归因再次得到验证：把 minor 释放出的 partial holes 交回 allocator，能把 PDF.js / RayTrace 的 committed/live 分别改善 55.38% / 94.43%，并修复上一版的 splay 包络劣化。需求侧拉取也确实降低了批量发布版在 EB / splay 上的指令税，但没有跨过钉死的 `≤1.003`：EB `1.003442`、RayTrace `1.004588`、splay `1.005450`。按“任一失败即 KILLED”，候选源码与测试已完整回滚；无 commit、无 push。

## 1. 测量合同与产物身份

- 沿用同一干净分支与 `7c067f01` 基线；开工前 `git status` 无 tracked 变更。
- ReleaseFast 构建固定 CPU `0-14`；测量固定 CPU `19`，持有 `/tmp/zjs-host-heavy.lock` 排他锁。
- committed/live + minflt 逐负载按 base/candidate/candidate/base；PMU 每引擎每负载 2 样本、paired ABBA。
- committed ABBA 有效预检 CPU 19 平均 idle `99.33%`；PMU ABBA 预检 `100.00%`。
- 第一次 committed 预检发现另一个 `zjs-oracle` 占满 CPU 19（平均 idle 0%），runner 在启动任何负载前退出；该进程结束后才重试。污染预检没有混入结果。
- committed 的 16 条腿全部 exit 0、stderr 为空；PMU 事件明确为 `armv8_pmuv3_1/instructions/`，有效 affinity 为 `[19]`。wall-clock 不作证据。
- base 与 candidate 配置签名相同：
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

| 产物 | SHA-256 |
|---|---|
| baseline `7c067f01` | `2830841f7d2b2992cec3386cf677fc99dbaf458a4f32e8b7ae6d85f7889ab959` |
| demand-refill candidate | `47be7b07dac28ac71ae19e5bfd2720db6c20aef48da7c3e41084f3c0e1e890b4` |
| 六负载 PMU JSON | `df44615650232639862199eb65c0ca44e050c34eac5da327234142f04771c778` |

PMU JSON 的 runner `repo` 字段读取的是测量时当前 checkout，因此两个角色都显示 `7c067f01-dirty`；它不是冻结二进制的嵌入身份。实际比较边界由上表两个不同 SHA、显式路径、相同配置签名和 JSON 内逐负载 fixed-work hash 固定。

## 2. 红测试与需求侧设计

### 2.1 红测试

先加入 brief 指定的三态测试，再运行 `zig build test-core`。编译按预期在三个调用点报错：`Heap` 尚无 `retireYoungBlocksAfterMinor`；红证据在 `.scratch/logs/brief3-red-test-core.log`。这证明测试确实先于机制存在。

### 2.2 临时候选机制

候选只改 block 生命周期 handoff，不动 mark / condemn / barrier 语义：

1. `Heap` 增加 per-class `young_retired_blocks` 头和一个全局 parked-blocked 状态；Block 不增字段，复用清除 `flag_young` 后闲置的 `young_link`，所以 pinned Block 仍为 112 bytes。
2. minor 尾部沿 `clearYoungBlocks` 本来就必须走的 young-block 链完成清 flag，并做 O(1) 入队过滤：非空、非 active、`doomed_link == 0`、达到现有 10% hot-reuse 容量线、parked frees 为 0。这里只做 LIFO intrusive push，不调用 `publishHotBlock`，不扫 doomed bitmap，不 rebuild interval。
3. `openBlock` 在 active block 耗尽后先 pop 本 class 的 retired 链；此时才重查 parked 状态、完整 doomed bitmap、既有 hot-reuse 门槛，并 rebuild interval。无资格或最大 interval 小于 K64 的 block 被摘链后回到原有 census-owned / free / hot 生命周期，allocator 继续普通路径。
4. major 开始前撤销尚未消费的 retired 链，防止同一 block 同时进入 major doomed/hot 所有权；这是 major 生命周期清理，不是 minor 发布循环。
5. 没有逐 cell 热路径新增；新增判断只在原有 minor block-retirement walk 或 allocator 换块慢路径。

三态定向测试分别覆盖：

- partial young block 只挂 retired 链、不进 hot pool；
- active block 耗尽后 demand-pop 并复用原 partial block；
- 已挂链 block 在 parked frees 再次非零时被 demand-pop 拒绝、摘链并走普通新块路径。

## 3. 正确性迭代证据

- 红：`zig build test-core` 因三个缺失 API 调用而失败，符合预期。
- 候选 `zig build check`：exit 0。
- 候选最终 `zig build test-core`：**462 passed / 6 skipped / 0 failed**；三条新测试均实际执行。
- `git diff --check`：PASS。
- 候选在性能硬线失败后未再支付候选全量测试；第 7 节明确区分候选证据与回滚最终树证据。

## 4. committed/live 与 minflt ABBA

factor 口径与 REPORT2 相同：两组相邻 candidate/base committed/live 比值的中位数；改善为 `1 - factor`。minflt 也取 paired factor。

| 负载 | base ×ratio 两腿 | candidate ×ratio 两腿 | paired factor | 改善 | minflt factor |
|---|---|---|---:|---:|---:|
| DeltaBlue | 4.842244 / 4.842244 | 3.840000 / 3.840000 | 0.793021 | 20.70% | 0.671261 |
| PDF.js | 6.653022 / 6.729111 | 2.985708 / 2.985651 | 0.446233 | **55.38%** | 0.854982 |
| RayTrace | 39.747783 / 39.734534 | 2.213833 / 2.213339 | 0.055700 | **94.43%** | 0.120187 |
| splay | 1.517609 / 1.424931 | 1.431706 / 1.394073 | **0.960870** | **3.91%** | 1.004769 |

结果解释：

- 验收只需目标负载 2/3 改善 ≥25%；PDF.js 与 RayTrace 过线，DeltaBlue 的 20.70% 不计作通过项。
- 三个目标 minflt 分别为 base 的 0.671× / 0.855× / 0.120×，全部低于 1.2×。
- splay 两条 candidate 都 terminal closed，minor/major 都是 `6 / 12`；base 第一腿 pending、第二腿 closed。即使只取唯一双方 closed 的反向配对，factor 仍为 `0.978344`（改善 2.17%），所以 splay 包络与次数线通过。
- demand-pop 命中并非纸面机制：RayTrace baseline hot reopen 为 19，两条 candidate 为 37,235 / 37,639；PDF.js 由约 157–173 增至 2,529；DeltaBlue 由 270 增至 10,435。splay reopen 仍在约 12.4k–12.6k，未出现上一版的包络反向。

## 5. 六负载 instructions ABBA

JSON 保留 runner 命名：`zjs` 是 candidate，`qjs` 是 baseline，因此 ratio 为 candidate/base。阈值严格是 `≤1.003`，目标是 `≤1.001`。

| 负载 | instructions ratio | Δ | paired-ratio MAD | `≤1.003` |
|---|---:|---:|---:|---|
| DeltaBlue | 1.000863 | +0.0863% | 0.000154 | PASS |
| Earley-Boyer | **1.003442** | **+0.3442%** | 0.001641 | **FAIL** |
| PDF.js | 0.999615 | −0.0385% | 0.000400 | PASS |
| RayTrace | **1.004588** | **+0.4588%** | 0.000515 | **FAIL** |
| RegExp | 0.999643 | −0.0357% | 0.000130 | PASS |
| splay | **1.005450** | **+0.5450%** | 0.007917 | **FAIL** |

逐配对：

- EB：`1.001800 / 1.005083`，中位数超过硬线 0.0442 个百分点；不能把小越线解释成通过。
- RayTrace：`1.004073 / 1.005104`，两个配对都明确越线，是不依赖单腿的硬失败。
- splay：`0.997533 / 1.013366`，波动较大但预注册口径仍以 paired median 裁决，结果失败。

相对 REPORT2 的 minor 尾部批量发布版，需求侧版确实把 EB 从 `1.006112` 降到 `1.003442`、splay 从 `1.008379` 降到 `1.005450`、Delta 从 `1.001185` 降到 `1.000863`；但 RayTrace 从 `1.003781` 升到 `1.004588`。这证明支付位置调整有效，却不足以满足原验收线。

## 6. 预注册验收线逐条对账

| # | 验收线 | 实测 | 裁决 |
|---:|---|---|---|
| 1 | 三目标中 ≥2 个 committed/live 改善 ≥25% | Delta 20.70%、PDF 55.38%、Ray 94.43%；2/3 | **PASS** |
| 2 | 六负载 instructions 各 ≤1.003 | EB 1.003442、Ray 1.004588、splay 1.005450 | **FAIL** |
| 3 | 目标 minflt ≤ base×1.2 | 0.671× / 0.855× / 0.120× | **PASS** |
| 4 | splay committed/live 与 minor/major 不劣化 | factor 0.960870；minor/major 6/12 不变 | **PASS** |
| 5 | 全量测试绿 + 挂链/拉取/拒绝测试 | 候选 check、test-core 与三态测试通过；性能失败后候选未跑全量。回滚最终树全量 2490/6/0。 | **候选未取得落地证据；最终树 PASS** |

第 2 条是必要条件且失败，最终只能 **KILLED / 不合并**；没有调整 1.003，也没有用目标 1.001 或 wall-clock 替换裁决口径。

## 7. 回滚与最终树验证

- 候选的 Heap 字段、retirement/pop/major-withdraw 逻辑、collector 调用点和三条测试全部用反向 patch 移除。
- 回滚后源码 `git diff` 为空。
- 按 `docs/verification-policy.md` 临时将空 `test262/` 替换为 `/home/aneryu/zjs/test262` symlink，执行带 pipefail 的 `taskset -c 0-14 zig build test`：**2490 passed / 6 skipped / 0 failed / 0 filtered**，exit 0。
- 测试后移除 symlink、恢复空目录；最终 `git status --short --branch` 仅显示分支头。
- 未运行 test262 / gate_smoke / arena audit；现行 policy 将它们归 driver merge-batch gate，而本候选已回滚。
- 无 commit，无 push。

## 8. 死亡层与后续边界

本版不再死于 splay committed 包络，说明“需求侧拉取”解决了上一版支付位置的一部分问题；它最终死在 **retired-block 生命周期的剩余 instructions 价格**：minor 仍需为每个候选 block 做 O(1) 分类/挂链，allocator demand miss 才做完整资格检查与 interval rebuild，major 还必须撤销未消费链。现有数据没有把三部分进一步拆成独立 PMU，因此不把余量武断归给其中一项。

RayTrace 同时给出最清楚的边界：94.43% 内存改善伴随稳定的约 +0.46% instructions，两个配对都越线。若再重开，必须先找到能减少 demand-pop / interval reconstruction 次数或把已有 allocator ownership 索引免费复用的机制；继续移动同一批 intrusive bookkeeping，或只凭 EB 的 0.044 个百分点越线争取容差，都不符合本 lane 的验收纪律。

## 9. 证据索引

- brief：`.scratch/BRIEF3.md`
- 红测试：`.scratch/logs/brief3-red-test-core.log`
- candidate check：`.scratch/logs/brief3-candidate-check-final.log`
- candidate targeted：`.scratch/logs/brief3-candidate-test-core-final.log`
- committed/minflt runner：`.scratch/run-demand-refill-abba.sh`
- committed/minflt 原始腿：`.scratch/raw/envelope/demand-refill-abba/`
- 六负载 PMU JSON：`.scratch/raw/envelope/demand-refill-instructions-six.json`
- PMU 控制台与 host 预检：`.scratch/logs/demand-refill-instructions-six.log`、`.scratch/raw/envelope/demand-refill-pmu/`
- 最终全量测试：`.scratch/logs/brief3-final-zig-build-test.log`
- 冻结候选：`.scratch/bin/zjs-demand-refill`
