> 注：原始二进制证据在临时 worktree，未入库。

# GC v2 S3 先行件报告：O2-B frontier safety

日期：2026-09-01

基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

分支：`gc/s3pre-frontier-safety-20260901`

实现归档：`3926e4c6edc285f3b8d58c78a95497dcd30bfcf3`（`gc: type and guard mark frontier entries`）

## 结论

**NO-GO，仅死于预注册的 ReleaseFast instructions 硬线。**

O2-B 的七条不变量已逐条机械化，correctness gate、定向测试、最终全测与三类删除突变均通过预期；但是 2 candidate × 2 base 冷构建全组合中，splay/EB 共 8 个 instruction 单元有 3 个超过 `1.001`：

- candidate-a/base-a：earley-boyer `1.001675519`；
- candidate-b/base-a：splay `1.004955397`；
- candidate-b/base-b：splay `1.002024374`。

全部 16 个 paired ratios 的总中位数其实都在线内（splay `1.000123656`、EB `1.000175247`），但冷构建合同要求保留并裁决全部四组合；总中位不能覆盖单组合失败。实现已按 brief 要求留在 archive commit，未 push，等待 driver/交叉评审。

## 七条不变量的实现

### 1. 精确 whitelist

`src/core/gc.zig` 增加中央 `frontierEpochSafe(kind)`：仅 `.object`、`.function_bytecode`、`.var_ref`、`.module` 返回 true。

- comptime 遍历全部 `GcKind`，对精确集合断言；
- 同时断言 whitelist 与当前 `refCountRemoved(kind)` collector-owned 集合完全相等，任一目录未来变化都会在编译期重开 O2；
- runtime 单测再次遍历全部 kind，防止调用侧或构建配置漂移。

### 2. Shape/Realm 同步展开，其他非 tracing kind 禁入

串行 `Collector.shadeExact` 和并行 `Tracer.shadeExact` 都先查中央 whitelist：

- Shape/Realm 保持 mark-claim 后同步 `traceOne/traceHeader`，不进入 private/shared frontier；
- String/BigInt 或未来其他非 tracing kind 到达该路径会立即 panic；
- mutation 1 只删除同步返回，随后由统一入队漏斗在 segment 写入前拒绝 unsafe kind。

### 3. 唯一 checked producer 与入队前置条件

新增 8 字节独立类型 `FrontierSafeHeader`，其原始指针构造器留在 `gc.zig` 模块内。生产调用点只能经 `Registry.frontierSafeHeaderAfterMarkClaim` 获得 token。safety/test 构建在返回 token 前检查：

1. kind 在精确 whitelist；
2. `heap_accounted` 且未 `cycle_visited`，即当前 v1 carrier 已 published、未 condemned；
3. immutable/shared `Metadata` prefix 通过 `verifyMetadataSemantics(..., .registry_published)`；
4. header mark claim 已存在。

这里有一个有意的边界：没有调用整个 `verifyPublishedHeaderRepresentation`。后者还检查 Object 的可变 Shape projection；owner requeue 可以合法发生在 shape slot 已写、projection 尚未提交的事务窗口。第一次定向测试正是在该合法窗口击中 full audit，随后将 admission agreement 收窄到设计要求的 immutable header/prefix agreement，而没有弱化 published/kind/mark 条件。

### 4. marking + live frontier 禁止白名单对象回收/复用

`assertFrontierAllowsReclaimKind` 在 safety 构建检查：

- `major_marking_active` 为 true；
- owner `mark_stack`、shared queue 或 segment pool 的 active segment（覆盖 helper-private stack）任一非空；
- 正要 condemn/raw-free 的 kind 在 whitelist。

同时满足即 panic。检查挂在普通 raw-free 账本入口、三条 list/block condemnation detach 路径和 block doomed snapshot 前。允许在 marking window 分配；禁止的是同 epoch 内白名单地址的 condemn/free，从而不可能把该地址作为新对象复用。

### 5. abort/deinit/finish 的关闭顺序

`closeMarkingAndDrainFrontier` 固定顺序为：

1. 先发布 `major_marking_active=false`；
2. reset owner private stack；
3. reset shared segment chain；
4. 断言 marking 已关且 owner/shared/helper-private active segment 全为零。

`abortIncrementalCycle` 与 `Registry.deinit` 共用该函数。正常 concurrent/final remark 在进入 weak/sweep/condemnation 前也断言 frontier 已排空。S1 已合入的 generation-scoped helper completion handshake 保证 slice 返回时 helper 已把 private segment 交回共享链，所以 abort/deinit 不会与 helper 私栈并发 reset。

### 6. queue API 类型收口

`gc_mark_queue.Segment.items`、`MarkStack.push/pop`、`Queue.push/pushSingle/pop` 全部改为 `FrontierSafeHeader`；segment 仍是 4096 B、item 仍是 8 B，509-entry geometry 不变。pop/prefetch/trace consumer 才显式 `.header()` 解包。源码普查确认 production 中不存在接受裸 `*Header` 的单项 private/shared push 旁路；整段 donate/steal 转移的 storage 本身也是该类型。

单元测试里的 synthetic queue storage probe 使用明确命名的 test-only `@enumFromInt` helper；它不创建 Runtime、不解引用 header，也不在 production 路径出现。

### 7. 三类删除突变

test binary 通过运行时 selector `ZJS_GC_FRONTIER_INJECT=N` 选择 mutation；三个模式使用同一份 safety binary，而不是为每种 mutation 编译不同逻辑。

| mutation | 删除的保护 | 命中的本 lane guard | 危险动作前停止证据 |
|---|---|---|---|
| 1 | Shape/Realm 同步展开返回 | `unsafe kind entered frontier` | checked producer；尚未写 segment，也未从 queue pop/deref |
| 2 | Object 构造完成前禁止入队 | `unpublished header entered frontier` | publication/registration 前；rollback 尚未能产生可复用 queued cell |
| 3 | live frontier 时禁止开始 free/reuse | `reclaim began with live frontier` | `incrementalMarkStep` 的 sweep/reuse 边界；未进入 condemnation |

命令与原始证据：

```text
ZJS_GC_FRONTIER_INJECT=1 zig build test --summary all
ZJS_GC_FRONTIER_INJECT=2 zig build test --summary all
ZJS_GC_FRONTIER_INJECT=3 zig build test --summary all
```

对应 `.scratch/s3pre-inject-final-{1,2,3}.log`，三次均为预期非零退出，panic 名称与上表逐字一致。

## Correctness 验证

先加类型/whitelist 红测，原树按预期编译失败：`core.gc has no member frontierEpochSafe`，证据 `.scratch/s3pre-red-typed-admission.log`。

最终源码（提交前后无源码变化）的验证：

| gate | 结果 | 证据 |
|---|---|---|
| `zig build check --summary all` | PASS，3/3 steps | `.scratch/s3pre-zig-build-check-final2.log` |
| `zig build test-core --summary all` | PASS，474 passed / 6 skipped / 0 failed | `.scratch/s3pre-test-core-2.log` |
| `zig build test-exec --summary all` | PASS，506 passed / 0 skipped / 0 failed | `.scratch/s3pre-test-exec-final.log` |
| 最终一次成功的 `zig build test --summary all` | PASS，2506 passed / 6 skipped / 0 failed | `.scratch/s3pre-zig-build-test-final-green.log` |
| `git diff --check` | PASS | 提交前与报告收尾均执行 |

新 reclaim checker 在前两次全测中还发现了两份镜像 Promise fixture 的真实测试所有权违规：测试将 GC threshold 设为 0、打开 incremental mark 后，绕过 tracer 直接 `destroyFromHeader` 一个可能仍在 frontier 的 state。分别位于 `src/exec/call.zig` 与 `src/exec/promise_ops.zig`。修复不是跳过 checker，而是在测试专用直析构前调用 `abortIncrementalCycle()`，先关 epoch 并排干 entry；失败证据保留在 `.scratch/s3pre-zig-build-test-final{,2}.log`。

按 `docs/verification-policy.md`，本 lane 没有重复执行 test262、gate_smoke 或 arena audit；它们属于 merge-batch gate。

## ReleaseFast 性能合同

- base commit：`8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`；candidate commit：`3926e4c6edc285f3b8d58c78a95497dcd30bfcf3`。
- candidate/base 各两个独立 cold local cache + cold global cache 构建；编译绑定 CPU0-14，四份构建均成功。
- 配置签名四份一致：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- 正式运行 CPU19 + `/tmp/zjs-host-heavy.lock`；起始 5 秒 landing window 为 100% idle。
- `tools/perf/bench_v8/run_fixed_pmu.py`，splay + earley-boyer，4 samples/arm/combination，paired ABBA；instructions 与 cycles 同腿采集。
- 每组合 JSON 均证明 `firstPositionBalanced=true`、effective affinity `[19]`；额外 1 秒整机 Zig monitor 的四份 contamination log 均为 0 字节。

二进制 SHA-256：

| binary | source commit | SHA-256 |
|---|---|---|
| base-a | `8aba23bd` | `9425e7b9df6e33b4a34be7fc0f4e0cdaa383a6ce421b88b2be7af68278c49544` |
| base-b | `8aba23bd` | `1391dfb215bc0ff300de12a1bc3ff9d831a05712b4338ba9a5dd310a53634ae8` |
| candidate-a | `3926e4c6` | `47cca0a2fe3876a23ce11a09100f4eb02a116345354e79295429a76fd44bc45f` |
| candidate-b | `3926e4c6` | `1387df50e0af5de1a10fe640aa47c59dd61ffc0d37bcccb2bf4d043cbcf2c29a` |

固定语料 source SHA-256：`base.js=216612c2...2733`、`splay.js=f9a6a60d...123f7`、`earley-boyer.js=8dd28a50...347`。runner 组装出的 fixed-work SHA 分别为 splay `e9a794ca...6fe7`、EB `b7cb20cb...93f9`，均记录在每份 JSON。

### Instructions paired-ratio 中位数

比值为 candidate/base，括号内为同组合 4 个 paired ratios 的 MAD；硬线为每 workload、每构建组合 `<=1.001`。

| candidate/base | splay | EB | 判定 |
|---|---:|---:|---|
| candidate-a/base-a | 0.999085608 (0.001382247) | **1.001675519** (0.000706995) | FAIL：EB |
| candidate-a/base-b | 0.999002591 (0.001224487) | 0.999610027 (0.000321994) | PASS |
| candidate-b/base-a | **1.004955397** (0.003445351) | 1.000175247 (0.000398266) | FAIL：splay |
| candidate-b/base-b | **1.002024374** (0.001712507) | 1.000795051 (0.000868315) | FAIL：splay |

结果：5/8 单元 PASS，3/8 FAIL，因此 S3-pre **NO-GO**。噪声不构成豁免；即使三个失败幅度都不大于约 1.15 个自身 MAD，预注册硬线仍按数值执行。

作为非裁决背景，把四组合共 16 个 paired ratios 合并后：

| workload | 总中位数 | 总 MAD | range |
|---|---:|---:|---:|
| splay | 1.000123656 | 0.003389282 | 0.992525851–1.010522180 |
| earley-boyer | 1.000175247 | 0.000891870 | 0.999217815–1.002590730 |

这说明方向中心在线内、构建/运行离散跨线；它不能覆盖上表的严格组合失败。

### 运行时代价说明

`FrontierSafeHeader` 仍为 8 B，类型包装/解包内联；published/header/mark/reclaim checker 全在 `std.debug.runtime_safety` comptime 门内，ReleaseFast 不生成这些检查。

完整机制并非声称绝对零运行时变化：Shape/Realm target 导致 owner requeue，以及 bulk-owner 在 marking window requeue 时，现在先补齐 `setHeaderMarked(owner)`，因为 typed admission 必须证明 mark claim，不能把旧的“未 claim 也可重入队”旁路伪装成已证明安全。上述 ABBA 对完整实现定价；本次失败因此必须保留，不能只以类型擦除为由忽略。

### 作废样本

第一次 candidate-b/base-b 运行期间，另一 lane 未持 host lock 启动 `zig build check`。1 秒 monitor 捕获重叠，整组作废并完整保留为：

- `.scratch/s3pre-perf-3926e4c6/DISCARDED-concurrent-zig-candidate-b_over_base-b.json`
- `.scratch/s3pre-perf-3926e4c6/DISCARDED-concurrent-zig-candidate-b_over_base-b.log`
- `.scratch/s3pre-perf-3926e4c6/DISCARDED-concurrent-zig-candidate-b_over_base-b.zig-contamination.log`

上表只使用清场后完整重跑的四份 `candidate-*_over_base-*.json`，没有从作废组补腿或挑样本。

## 交叉评审注意点

1. 请重点复核 immutable header agreement 与 Object mutable Shape projection 的边界；full representation audit 不能安全地放在 owner requeue 的 store/projection 中间窗口。
2. 请复核 `frontierHasEntriesForSafety` 对 helper-private stack 的证明依赖：active segment 由共享 pool 计数，空 private segment 会立即 release；S1 generation completion 则保证 slice 返回前 helper 已 spill/release。
3. 性能死因是构建组合离散下的严格硬线，不是 correctness 缺口。若 owner 选择后续提高测量功率或修改裁决聚合器，应另行预注册；本报告不自行放宽。

本 lane 至此停止，保持 idle，等待 driver/交叉评审。
