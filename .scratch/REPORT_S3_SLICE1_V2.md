# GC v2 S3 第一片 V2 报告：carrier authority audit-only

日期：2026-09-01

性能基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

初版错误形态：`ebea8cb8d70ce9170013941c6af3d7211da71099`

初版报告归档：`d16d498af1b98cea5c3812fc11aefef8f5fbe9a1`

V2 实现归档：`754579dbbcc1cc4c90c922ddbb4dd530005a62b7`

## 结论

**V2 PASS。** Slice 1 的 API 收口、代际/生命周期 checker、确定性测试和两类 mutant 全部保留，但 `CellIdentity`、`ExtentAuthority/ExtentRecord`、generation counter 与全部 lifecycle shadow-write 已整体收进 `builtin.is_test or zjs_ownership_audit` comptime 门。默认 ReleaseFast 不再保存或维护一个零消费者的第二权威；exact API 改由现有 v1 block/address-registry authority 解析，只有 audit 构建验证 generation。

预注册性能硬线也全部通过。2×2 冷构建、每组合 4-pair ABBA、全部 16 个 paired ratios 总中位数：

| workload | instructions | `<=1.002` | cycles | `<=1.002` |
|---|---:|---:|---:|---:|
| splay | **1.001503049** | PASS | **0.996982783** | PASS |
| earley-boyer | **1.000160428** | PASS | **1.001095331** | PASS |

初版 EB cycles `5.413951157`（`+441.4%`）已消失。本轮数字对本返工验收作 PASS；它不提前替代 S3 最终六负载批组合裁决。

## 1. 终审问题与修复边界

初版把 shadow migration 错做成 production 常驻：

- `Superblock` 从 88 扩到 728 bytes；每个启用 cell 另配 16-byte `CellIdentity`；
- 每次 block allocation 写 sequence/state/accounted；
- 每个 non-block carrier 建 56-byte `ExtentRecord` 并维护 exact-start hash；
- publish/retire/free 都做 shadow lifecycle transition；
- shipped ReleaseFast 没有一个真实 generation/state 消费者。

因此初版的高成本不是 header-v2 必付终态价格，而是迁移纪律错误。本返工没有删除正确性资产，也没有伪造空实现；同一套 authority/checker 在 test/ownership-audit 构建继续真实分配、写入和验证，只从零消费者的 production build 中完全消除。

## 2. 单一 comptime 门

`gc_carrier.authority_audit_enabled` 是唯一门：

```text
builtin.is_test or build_options.zjs_ownership_audit
```

`memory.zig` 对它与 P1 independent oracle gate 做 compile-time equality assertion，防止 raw ledger 与 shadow authority 一边开、一边关。

门内保留：

- `ExtentAuthority`、runtime-monotonic u64、`ExtentRecord` hash、reserve/commit/transition/free；
- block u32 incarnation、per-cell u32 reuse sequence、state/accounted 与 non-wrap sealing；
- raw ledger、old/new/independent 三角 parity；
- stale-generation/early-removal mutations 与所有 generation/lifecycle tests。

门外生产形态：

- `MemoryAccount.gc_extent_authority` 为 `void`；
- `Heap.next_block_incarnation`、exhausted flag、`Superblock.block_incarnations/cell_identities` 均为 `void`；
- allocation/publication/retirement/free 调用点均由 `if (comptime ...)` 整体删除，参数准备也不残留；
- `popReservableCell` inline 直接退化为原 `popCell`；free/Pass-A/open/reset/deinit 不读写 identity；
- raw oracle 本来就是 audit-only，保持不变。

新增 production footprint compile assertion：authority 关闭时 `@sizeOf(Superblock) == 88`，防止以后再次静默扩张。

## 3. exact/diagnostic API 保留方式

三套协议和命名均保留：

- conservative all-hits：`forEachTraceCandidateAt`，root soundness 权威；
- diagnostic single-winner：`resolveOneForDiagnostics`/`resolveGcForDiagnostics`，仍禁止承担语义；
- exact：`allocationHandle`/`resolveExact`。

exact 的构建语义现在分开：

| build | authority | generation |
|---|---|---|
| test / ownership-audit | block `incarnation+reuse` 或 extent record | 必须匹配；state/kind/header agreement 全验 |
| production ReleaseFast | 当前 v1 block/address-registry exact membership | handle generation 固定为 0；解析时不验证 generation |

生产 fallback 先由 `address_registry.containsHeader` 做 exact block/slab/standalone membership，再读当前 v1 header 的 kind；不会把 diagnostic greatest-`lo` winner 当 exact identity。

测试构建通常走 rich audit path，因此新增显式 `resolveExactV1ForTest` route assertion：

- standalone registry exact start 成功，即使 generation 是 `maxInt(u64)`；
- block replacement exact start 成功，即使携带旧 generation；
- block interior `base+8` 由 v1 exact authority 拒绝。

这证明 shipped fallback 的真实代码路径，而不是只证明 audit path。

## 4. 后续片纪律（预注册）

1. **零消费者不得先开 production shadow-write。** checker、mutation 与 parity 可以长期 audit-only；不能以“未来会用”为由预付生产存储/写入。
2. **authority 的每一部分只在真实消费者迁移的同一片翻转 production：**
   - generation storage 随第一个持久 generation handle consumer；
   - extent exact map 随第一个需要跨复用 exact extent identity 的 consumer；
   - lifecycle state 随第一个从 v1 topology 切到 owned-state reader 的 consumer；
   - teardown/publication transition 随对应 reader authority switch，不能只写不读。
3. **每次翻转单独定价。** 一个片只为其新 consumer 所需的最小 authority 付费，必须有 before/after footprint、ReleaseFast disassembly 和目标负载 ABBA；不得把多项翻转捆成无法归因的总账。
4. **冻结终态上限：production block generation 成本最多 4 bytes/physical cell，加一枚 u32 incarnation/block。** 初版 16 bytes/cell 的 state+accounted struct 不是允许的终态。状态若需生产化，必须另用批准的 compact bitplane/side representation，并在它自己的消费片定价，不得侵占 4B generation 预算。
5. 每个 production switch 都保留 audit triangle 作为 independent expected side；不能让新 authority 同时成为 reported 与 expected population。

## 5. correctness 与 mutation 证据

| gate | 结果 | 证据 |
|---|---|---|
| `zig build check --summary all` | PASS，3/3 steps | `.scratch/s3-slice1-v2-check.log` |
| `zig build test-core --summary all` | PASS，479 passed / 6 skipped / 0 failed | `.scratch/s3-slice1-v2-test-core.log` |
| mutant 1，`ZJS_GC_CARRIER_INJECT=1 zig build test` | 预期非零；`stale generation accepted` | `.scratch/s3-slice1-v2-inject-stale.log` |
| mutant 2，`ZJS_GC_CARRIER_INJECT=2 zig build test` | 预期非零；`early record removal while raw allocation remains` | `.scratch/s3-slice1-v2-inject-early-removal.log` |
| 最终一次无注入 `zig build test --summary all` | PASS，2513 passed / 6 skipped / 0 failed；9/9 steps | `.scratch/s3-slice1-v2-final-test.log` |
| representation snapshot | 相对 `d16d498a` 无 diff | 命令返回 0 |
| `git diff --check` | PASS | 报告提交前复核 |

mutant 在 `zig build test` 的 `builtin.is_test=true` 门内触发，分别命中原 checker 名称；没有依靠 production 假路径或其他 guard 代打。依 verification policy，本 change 未重复运行 batch-only test262/gate_smoke/arena audit。

## 6. ReleaseFast 消除证据

真实 production signature：

```text
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

ReleaseFast DWARF 与 symbol audit：

- `Superblock` 为 **88 bytes**（初版 728）；物理 `Block` 仍为 112 bytes；
- DWARF 不再生成 `CellIdentity`/`ExtentRecord` production instance；
- `nm -C` 中 `reserveGcExtent`、`commitGcExtent`、`carrierPublish`、`carrierTransition`、`reserveCellIdentity`、`identityFor` 全部无符号；
- representation snapshot 与 `gc_representation.zig` 无 diff。

base/candidate ReleaseFast 指令数抽查：

| function | base | candidate | 结论 |
|---|---:|---:|---|
| `Heap.allocCellFixedPtr<Object>` | 139 | 139 | 零新增；等长调度重排 |
| `Heap.freeSmallCell` | 67 | 67 | mnemonic 序列相同 |
| `Collector.seedConservativeRoots` | 504 | 504 | mnemonic 序列相同 |
| `Registry.addInitializedShape` | 96 | 96 | mnemonic 序列相同 |
| `Registry.addInitializedWithSizeNoFail` | 86 | 86 | mnemonic 序列相同 |
| `Object.createInternal` | 812 | 812 | 零新增；等长调度重排 |

原始 disassembly 位于 `.scratch/s3-slice1-v2-perf/disasm/`。

## 7. 2×2 冷构建 ABBA 合同

- base：`main@8aba23bd`；candidate：`754579db`，因此仍包含 driver 要求折入结算的 S3-pre。
- candidate/base 各 2 个全新冷构建；每份独立 local/global Zig cache，candidate/base 交替，编译绑定 CPU0-14；4 份均 `4/4 steps succeeded`。
- 正式运行使用 `/tmp/zjs-host-heavy.lock`、CPU19、effective affinity `[19]`、`armv8_pmuv3_1`、`run_fixed_pmu.py`。
- preflight CPU19 连续两秒 100% idle；四组合均 4-pair ABBA、`firstPositionBalanced=true`；四份 1 秒全机 Zig monitor 均 0 bytes。
- 每 workload/metric 的裁决值为全部四构建组合 16 个 paired ratios 的总中位数；instructions 和 cycles 各自必须 `<=1.002`，不互相抵消。

runner 的 `binaries.qjs.repo` 仍会从二进制外层 candidate worktree 推断，因此 base provenance 由 detached worktree `rev-parse=8aba23bd...`、独立构建日志和哈希固定。

### 冷构建账本

| binary | commit | bytes | SHA-256 |
|---|---|---:|---|
| candidate-a | `754579db` | 29069864 | `a612708b822157afed903b2622902d7b0f8b95d9e5e2728a54a7b64c9f5eb4c4` |
| candidate-b | `754579db` | 29120360 | `3393fb2e903310b0b608ae372c4ecdcfc531c20cfde6d748cbb436a8625566fc` |
| base-a | `8aba23bd` | 29098760 | `2983e709d5a7db7181a6b6716c395c7a6566f48e9fe4f5371c0ccad2e2e3a790` |
| base-b | `8aba23bd` | 29098760 | `2230cf049301bd3c2dd310c8e0b75a533eff23f58e17d8339be032a0760c1200` |

语料 SHA-256 与前次相同：`base.js=216612c2...232733`、`splay.js=f9a6a60d...123f7`、`earley-boyer.js=8dd28a50...dab347`；assembled fixed-work 为 splay `e9a794ca...f36fe7`、EB `b7cb20cb...c93f9`。

### 四组合单元中位数

每格为该组合 4 个 paired ratios 的中位数（MAD）。单元用于展示构建离散，不逐格裁决。

| candidate/base | splay insn | splay cycles | EB insn | EB cycles |
|---|---:|---:|---:|---:|
| a/a | 1.000246049 (0.002202260) | 0.995795485 (0.000768058) | 0.999953586 (0.000342150) | 1.002970704 (0.002085157) |
| a/b | 1.005609986 (0.001648250) | 1.009651446 (0.008029672) | 1.000332692 (0.000384546) | 1.000974023 (0.001616055) |
| b/a | 1.001085126 (0.002642475) | 1.000411273 (0.003564184) | 0.999734198 (0.000736613) | 0.999545296 (0.003125310) |
| b/b | 0.998911502 (0.002591547) | 0.995256736 (0.002943606) | 1.000612249 (0.000667507) | 1.000468250 (0.000753297) |

### 全部 16-pair 总结果

| workload | metric | 总中位数 | 相对 base | MAD | range | 硬线 |
|---|---|---:|---:|---:|---:|---:|
| splay | instructions | **1.001503049** | +0.150305% | 0.003194067 | [0.991890245, 1.010918166] | PASS |
| splay | cycles | **0.996982783** | -0.301722% | 0.004901996 | [0.989829461, 1.019557640] | PASS |
| earley-boyer | instructions | **1.000160428** | +0.016043% | 0.000658208 | [0.998040689, 1.003282236] | PASS |
| earley-boyer | cycles | **1.001095331** | +0.109533% | 0.001851365 | [0.990643907, 1.011688353] | PASS |

原始 JSON、逐腿日志、构建日志与 monitor 位于 `.scratch/s3-slice1-v2-perf/`。

## 8. 初版 +441% 病理归因注记

已证范围：

- 初版 production authority 开启、raw audit ledger 关闭时就出现 EB instructions `4.0359`、cycles `5.4140`；因此 P1 independent raw ledger 不是必要死因。
- 本返工只把 block identity storage/write、extent hash 与 lifecycle transition 从 production 移回 audit 门，API/测试/frontier 资产不删；EB 随即回到 `1.00016/1.00110`。故**错误的 production shadow authority 组合**是已证因果边界。
- 初版 base EB 稳定约 451–452B instructions，而 candidate 冷腿从约 770B 到 3.185T；固定的每分配写成本无法单独解释这种跨进程倍数离散。side allocation/hash 改变地址布局并放大 conservative floating retention 与重复 GC 工作，是最符合现象的子机制。

未证范围：本返工按终审要求整体关门，没有单独二分 `CellIdentity`、extent hash 和 lifecycle stores；因此不能宣称三者中某一个已被独立定罪。最终真实 consumer 切换时必须按第 4 节逐项翻转、用 allocation/collection counters 区分固定 hash 成本与保守保留放大。

本 lane 到此停止并保持 idle，等待 driver 终审。
