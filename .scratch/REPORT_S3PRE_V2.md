# GC v2 S3 先行件 V2 报告：frontier requeue claim-check

日期：2026-09-01

基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

分支：`gc/s3pre-frontier-safety-20260901`

初版实现归档：`3926e4c6edc285f3b8d58c78a95497dcd30bfcf3`

本轮修复归档：`2e433633ed3cd8adca026bcdcf8dc9ed56c4d581`

## 结论

**NO-GO。correctness 与突变门全绿；EB 通过新硬线，但 splay 的全部 64 个 instructions paired ratios 总中位数为 `1.001583092`，超过预注册的 `1.001`。**

| workload | n | instructions 总中位数 | 相对 base | 总 MAD | 95% bootstrap CI | `<=1.001` |
|---|---:|---:|---:|---:|---:|---|
| splay | 64 | **1.001583092** | **+0.158309%** | 0.002790706 | [1.000059942, 1.002954847] | **FAIL** |
| earley-boyer | 64 | 1.000232230 | +0.023223% | 0.000785496 | [0.999896435, 1.000508745] | PASS |

裁决严格按 driver 预注册规则逐 workload 使用全部 4×4 构建组合的 paired-ratio 总中位数。CI 不参与改线；splay cycles 的改善也不抵消 instructions 失败。因此维持 S3-pre **NO-GO**，交 driver 处理。

## 1. requeue 从 claim 执行改为 claim 检查

### 语义结论

合法 requeue 不需要替白色 owner 执行 mark claim：

- owner 仍为白色时，如果它之后可达，正常首次 claim/trace 会看见写入后的边；如果它不可达，则不需要为本轮保留这些边；
- requeue 的必要对象是已经被正常标记、可能已 trace 成黑色的 owner，写屏障才需要把它重新送回 frontier；
- 因此 requeue admission 可以先读 `headerMarked(owner)`：白色直接跳过，已 claim 才调用原有 checked producer 生成 `FrontierSafeHeader`；
- exact-target shading 不变，仍在原路径 `setHeaderMarked(target)` 后类型化入队。

`Registry.frontierSafeHeaderForRequeue` 实现独立 admission 变体，返回 `?FrontierSafeHeader`：

1. ReleaseFast 先做一次 mark **read/check**；未 claim 返回 null；
2. 已 claim 才进入 `frontierSafeHeaderAfterMarkClaim`；其中 whitelist、published、carrier agreement 与 claim assertions 仍只在 safety/test 构建生成；
3. Shape/Realm owner-requeue 与 bulk-owner requeue 两个漏斗均改用该 helper。

相对初版 `3926e4c6`，两处 `setHeaderMarked(owner)` 已全部删除。相对 S1 base `8aba23bd`，requeue 路径没有新增 mark store/RMW；标准 exact-target 路径的 `setHeaderMarked(target)` 是 base 已有行为。ReleaseFast 新增成本只在稀有 requeue 漏斗上保留一次 mark read/branch。

### 确定性测试

`src/tests/core.zig` 新增两个测试，直接钉死“检查而非执行”：

- `frontier requeue admission checks a prior claim without executing one`
  - published 白 owner 经 helper 与真实 bulk-write 漏斗后仍未 marked、queue 为空；
  - 由正常 claim 模拟路径标记后，同一漏斗才能产生类型化 entry；
- `Shape barrier requeues only an owner with a prior mark claim`
  - 白 owner + Shape target 不 claim owner、不 claim Shape、不入队；
  - owner 已 claim 后，同一 Shape barrier 入队 owner token。

没有增加 stats 字段：迭代中的新字段先被现有 `Stats` footprint pin 拒绝，最终复用 `barrier_requeued_owner` 表示到达 Shape/Realm requeue arm 的次数，并在注释中明确白 owner 也计数但不入队。最终生产类型与 footprint 不变。

## 2. correctness 与删除突变

七条 O2-B frontier 不变量、`FrontierSafeHeader` 类型化 queue API、reclaim/close-order checker 均保持初版实现。修复后的精确源码树验证如下：

| gate | 结果 | 证据 |
|---|---|---|
| `zig build check --summary all` | PASS，3/3 steps | `.scratch/s3pre-v2-zig-build-check-exact.log` |
| `zig build test-core --summary all` | PASS，476 passed / 6 skipped / 0 failed | `.scratch/s3pre-v2-test-core-final.log` |
| mutation 1 | 预期非零；`unsafe kind entered frontier` | `.scratch/s3pre-v2-inject-1.log` |
| mutation 2 | 预期非零；`unpublished header entered frontier` | `.scratch/s3pre-v2-inject-2.log` |
| mutation 3 | 预期非零；`reclaim began with live frontier` | `.scratch/s3pre-v2-inject-3.log` |
| 最终一次 `zig build test --summary all` | PASS，2508 passed / 6 skipped / 0 failed | `.scratch/s3pre-v2-zig-build-test-exact.log` |
| `git diff --check` | PASS | 报告提交前复核 |

三个 mutation selector 和 panic 名称未改，修复后均仍按名触发并在危险动作前终止。按 `docs/verification-policy.md`，本 change 没有重复运行 merge-batch 才需要的 test262、gate_smoke 或 arena audit。

## 3. 加倍功率 ReleaseFast 复测合同

- base：`8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`；candidate：`2e433633ed3cd8adca026bcdcf8dc9ed56c4d581`。
- candidate/base 各 4 个冷构建；每份使用独立 local/global Zig cache，按 base/candidate 交替构建，编译绑定 CPU0-14。
- 8 个构建全部 `4/4 steps succeeded`；配置签名完全一致：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- 正式运行使用 CPU19、`/tmp/zjs-host-heavy.lock`、`armv8_pmuv3_1`、`tools/perf/bench_v8/run_fixed_pmu.py`。
- 锁内 preflight 为 CPU19 99.60% idle；16 个有效组合均为 `samplesPerEnginePerBench=4`、paired ABBA、`firstPositionBalanced=true`、effective affinity `[19]`。
- 全 4×4 构建组合；每组合 splay + earley-boyer；每 workload 每组合 4 个 paired ratios，共 64 个。
- 每组合另有 1 秒全机 Zig monitor；16 份有效 monitor 都是 0 字节。

runner 的 `binaries.qjs.repo` 从二进制所在的外层 candidate worktree 推断，因此不作为 base provenance。base 的来源由 detached worktree `.scratch/s3pre-v2-perf-2e433633/base-src` 的 `rev-parse=8aba23bd...`、独立构建目录/日志与下列哈希共同固定。

### 冷构建账本

| binary | commit | bytes | SHA-256 |
|---|---|---:|---|
| base-a | `8aba23bd` | 29042472 | `995a32a9aafe0a4a96d57b58bf4838e05c5fd950756e18c0b4b43160be911c34` |
| base-b | `8aba23bd` | 29042472 | `b370eba5c2724b0c60cf2cdbde2ceabd810dbc9f4de5ef4659e9dfd1aec1ac3f` |
| base-c | `8aba23bd` | 29098784 | `093d7d8cf3e95d930d94a55f0a00bee060526bbdeb49dbdf731cc31dab37ed7f` |
| base-d | `8aba23bd` | 29098784 | `913dcadfed3d237ce9ea2ce8f7a89cb35dedbea33ba3b041deebdca250a8e9bd` |
| candidate-a | `2e433633` | 29101720 | `6761e8368341cbadd6123f4d4f5ffa3e214f0828de10ce523a3d66593d9c8767` |
| candidate-b | `2e433633` | 29045376 | `f50649d205cf0749bfb9cbe33913963b01cd02152a0d30c95e2f693b01e963c4` |
| candidate-c | `2e433633` | 29045376 | `69700e1eff11884e479130325b99ad07c4fd62de35cdbea44293171632e43e51` |
| candidate-d | `2e433633` | 29101720 | `0021cf67bdd9b011f549f7eebe8feefac81b7355c9560a956be36cde13f63f55` |

语料 source SHA-256：

- `base.js`: `216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733`
- `splay.js`: `f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7`
- `earley-boyer.js`: `8dd28a505f7e705642f86816232b012fd3c770ec8afc9f719ce89ce772dab347`
- assembled fixed-work：splay `e9a794cab2e318f7ff4509d079f7172b819e4689c2399188c9e54559e8f36fe7`；EB `b7cb20cb6e9c2fc3ef59bda0951761e9a3c19d4fef9f4be054194de9d32c93f9`。

## 4. 16 组合结果

下表为 instructions candidate/base ratio；每格是该组合 4 个 paired ratios 的中位数（MAD）。这些单元用于展示构建离散，**不逐格裁决**；新规则只裁决表后 64-pair 总中位数。

| candidate/base | splay | earley-boyer |
|---|---:|---:|
| a/a | 1.003962872 (0.005608628) | 1.000831289 (0.000574278) |
| a/b | 0.999076692 (0.002021483) | 1.000316535 (0.000691142) |
| a/c | 1.002973624 (0.001282653) | 0.999974314 (0.000540118) |
| a/d | 1.002622558 (0.001345617) | 1.000308857 (0.000680469) |
| b/a | 1.003380352 (0.002643507) | 1.000577813 (0.000330817) |
| b/b | 1.005571958 (0.004165186) | 0.999447453 (0.000569319) |
| b/c | 1.000532602 (0.001589047) | 0.999898513 (0.000461678) |
| b/d | 1.002988100 (0.002001963) | 1.001277425 (0.000095638) |
| c/a | 1.005479095 (0.004720851) | 0.999533235 (0.000442627) |
| c/b | 1.002208802 (0.002308156) | 1.000091305 (0.000215417) |
| c/c | 1.006740043 (0.002792823) | 0.999672093 (0.000453593) |
| c/d | 1.000908492 (0.002631903) | 1.000489241 (0.001397708) |
| d/a | 1.004621044 (0.004390571) | 0.999644085 (0.000081459) |
| d/b | 0.997835021 (0.001862605) | 1.000163411 (0.000700675) |
| d/c | 0.996350163 (0.002017808) | 1.000775672 (0.001590391) |
| d/d | 0.999448132 (0.001071126) | 1.000788657 (0.000693048) |

splay 的组合中位数横跨 `0.996350163–1.006740043`，EB 横跨 `0.999447453–1.001277425`，继续显示构建离散显著；但预注册聚合后 splay 中心仍高于线，不能改判。

### Bootstrap 方法

在查看矩阵结果前固定：每个 workload 独立地对全部 64 个 instructions paired ratios 有放回重采样；100,000 次；PRNG seed `5333`；每次取样中位数；报告 percentile 2.5%/97.5%（线性分位插值）。裁决只用原始 64-pair 总中位数。

同腿采集的 cycles 仅作诊断：

| workload | cycles 总中位数 | 相对 base | 总 MAD | 95% 同法 bootstrap CI |
|---|---:|---:|---:|---:|
| splay | 0.998761679 | -0.123832% | 0.005054277 | [0.996431241, 1.002092775] |
| earley-boyer | 1.003540797 | +0.354080% | 0.003025347 | [1.002642676, 1.005021877] |

cycles 不属于本轮预注册硬线，也不用于抵消 splay instructions NO-GO。

## 5. 污染处置与原始证据

首个 a/a 组合有两次完整运行被 1 秒 monitor 捕获到外部 Zig：

1. `gc-settle` 的 `zig build check`；
2. 随后的 `zig build test --summary all`。

两次均整组作废，没有补腿或挑样本，raw JSON、runner log、monitor log 保存在 `.scratch/s3pre-v2-perf-2e433633/discarded/`。外部 Zig 清空后，a/a 从头第三次运行才进入有效矩阵。16 个有效 JSON、runner logs 与空 monitor 位于 `.scratch/s3pre-v2-perf-2e433633/results/`；8 个构建日志位于同目录根部。

旧 `.scratch/REPORT_S3PRE.md` 的初版 NO-GO 被本报告取代；初版与本轮实现均留 archive commit，未 push。本 lane 到此停止并保持 idle，等待 driver 裁决。
