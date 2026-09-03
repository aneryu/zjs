# GC v2 S3 第一片报告：carrier/identity API 与代际权威

日期：2026-09-01

累计性能基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

S3-pre 基点：`2e433633ed3cd8adca026bcdcf8dc9ed56c4d581`

本片实现归档：`ebea8cb8d70ce9170013941c6af3d7211da71099`

设计权威：`docs/tracing-gc-header-v2-design.md` 的 APPROVED r2（O2=B）

## 结论

**本正确性片完成，预注册 correctness、mutant、representation 与 ReleaseFast API 收口门全部通过。** 当前 v1 物理布局仍是权威；新 carrier state/generation 只做 shadow-write、exact 验证与三角审计，没有迁移现有持久 handle 消费者，也没有进入 header v2 物理布局片。

性能按 brief 只记账、不裁决。相对 `main@8aba23bd`（因此包含 S3-pre 的 `+0.16%` 价格），2×2 冷构建、每组合 4-pair ABBA 的总中位数为：splay instructions `1.712527813`、cycles `1.490203761`；earley-boyer instructions `4.035906651`、cycles `5.413951157`。这是一笔很大的真实组合成本，必须交后续片/批组合点处理；本报告不据此作 GO/NO-GO，也不以“正确性片”为由隐藏它。

## 1. 三套 candidate/identity API

### Exact handle

新增 `gc_carrier.AllocationHandle { base, generation }`、`LifecycleState`、`StateMask` 与 `ResolveError`，并由 `Registry` 暴露：

- `allocationHandle(header)`：只为当前 owned allocation 铸造栈内 handle；
- `resolveExact(handle, expected_kind, allowed_states)`：先由 block/extent authority 检查 exact start、generation、state、kind，再允许读取当前 v1 header 作为 agreement witness；
- block cell 通过注册 block + exact cell index 解析；extent 通过 exact-start record 解析。stale generation、interior pointer、wrong kind 均按不同错误拒绝。

本片没有把任何现有持久 handle 消费者迁到它。生产 ReleaseFast 中的新 exact 调用点为零；调用者仅是 ownership audit/checker 与定向测试，符合“先建 authority，不迁移消费者”的片界。

### Conservative all hits

现有 `forEachGcObjectAt` 收口命名为 `forEachTraceCandidateAt`，保留相邻区间 one-past 的多命中语义。生产 root scanner 仍只走这条协议。`gc_candidate.validate` 也用 all-hits 枚举，但只接受 canonical header 与 JSValue payload exact-start 相等的 hit，未把 diagnostic winner 变成语义权威。

确定性相邻 fixture 令 `A.one_past == B.base`，断言 conservative 协议同时发出 A/B 两个 hit。

### Diagnostic single winner

新增 `resolveOneForDiagnostics(addr) -> { winner, hit_count }` 与便利包装 `resolveGcForDiagnostics`。winner 仍按 greatest-`lo` 规则选取，但 API/注释明确禁止 root soundness、shade、free 与 weak identity；旧 test/diagnostic 单值调用已迁移，生产语义调用点为零。同一相邻 fixture 断言 `hit_count == 2` 且 winner 为 B，避免把“单 winner”伪装成完整 hit set。

源码 census 中旧名 `forEachGcObjectAt` 已为零；production root path 只有 `gc_conservative` 的 all-hits 调用。

## 2. 持久 generation 与 lifecycle authority

### Extent

- 每个 runtime 的非块 generation 为从 1 开始的 monotonic `u64`；0 永久无效。
- 在 raw allocator 前 `reserve` generation 和 map capacity；raw allocation/constructor 失败仍烧掉 generation。
- raw allocation 成功后无失败地建立 `constructing` record；publication 转为 `published`，retirement 转为 `doomed`，raw free 前转为 `raw_free_in_progress`，只有 raw free commit 后才删除 record。
- 达到 `maxInt(u64)` 后本次及以后 reservation 均以 `OutOfMemory` 失败，不回绕。

### Block cell

- 每个新 classed superblock 在 raw mapping 前一次烧掉 32 个 runtime-monotonic nonzero `u32 block_incarnation`；mapping 失败不退号。
- 每个物理 cell 的 `u32 reuse_sequence` 在 reservation 前递增，handle generation 为 `(incarnation << 32) | reuse_sequence`。
- cell sequence 达到最大值后永久封住该 cell，但 allocator 继续检查同 block 的其他 cell；block-incarnation exhaustion 只禁止创建新 block，已存在 block 仍可用。
- block raw-free 丢弃 cell sequence；同地址新 block 必须拿新 incarnation，不保留 per-base tombstone。

allocation rollback、inline class payload、普通 extent、block cell、Pass-A settlement 与最终 raw free 都已接到同一 lifecycle seam。authority record 从不在 raw allocation/active callback 尚存时提前删除。

## 3. old/new/independent 三角 parity

复用 P1 既有 `HeapAccountingOracle`，没有再造同源 expected iterator。它只在 `builtin.is_test` 或显式 `ownership_audit` 中存在，ReleaseFast 完全编译掉；本片将其向下延伸为 raw-allocation ledger，audit ID 使用独立计数器，不复用 carrier generation。

`verifyHeapAccounting` 在原有 old v1 ownership/accounting census 之外执行独立方向：

| 事实 | old source | new source | independent source | 已落方向 |
|---|---|---|---|---|
| raw ownership/bytes | MemoryAccount/raw allocator + 当前 block ownership | extent records + block non-free cell identity | raw seam ledger | raw -> new；extent/block new -> raw；raw base/bytes/generation exact |
| published membership | intrusive list、block allocation、`heap_accounted`、Object vector | `state == published` | raw ledger publication bit + 原 construction-pin/ownership census | old -> new；new/raw published -> old；accounted bytes/generation exact |

checker 在 dereference/sweep 前 fail closed。现阶段 v1 仍是语义权威，新 state 是 shadow；因此 checker 的 expected side 不来自新 iterator 本身。

## 4. 定向测试与 mutants

红测先行：`.scratch/s3-slice1-red.log` 在实现前以缺失 `Registry.allocationHandle` 的编译错误失败。

新增/扩展的确定性覆盖包括：

- standalone inline extent 当前 handle 成功 exact resolve；
- block cell 退役后确定性复用同一 base，旧 generation 报 `GenerationMismatch`、新 handle 成功；interior 与 wrong-kind 分别拒绝；
- adjacent one-past conservative all-hits 与 diagnostic `{ winner, hit_count }` 分离；
- extent `u64` 与 block `u32` exhaustion 均不回绕；封死 cell 后 allocator 使用另一 cell；
- raw/published/lifecycle 三角 checker 继续覆盖 block、standalone、large/inline 与 teardown 路径。

两类 deletion mutant 都通过 `ZJS_GC_CARRIER_INJECT=N` 在完整 unified test 中按名触发，并在危险动作前终止：

| mutant | 预期结果 | 命名证据 |
|---|---|---|
| `1` stale generation | 非零/ABRT | `gc: CARRIER IDENTITY: stale generation accepted`；在 header dereference 前的 post-guard 触发 |
| `2` early record removal | 非零/ABRT | `gc: CARRIER IDENTITY: early record removal while raw allocation remains`；在 callback/raw free 前由独立 ledger 触发 |

原始日志分别为 `.scratch/s3-slice1-inject-stale.log` 与 `.scratch/s3-slice1-inject-early-removal.log`。

## 5. correctness 验证

| gate | 结果 | 证据 |
|---|---|---|
| `zig build check --summary all` | PASS，3/3 steps | `.scratch/s3-slice1-check-final.log` |
| `zig build test-core --summary all` | PASS，479 passed / 6 skipped / 0 failed | `.scratch/s3-slice1-test-core-final.log` |
| mutation 1 | 预期非零，按名 stale-generation panic | `.scratch/s3-slice1-inject-stale.log` |
| mutation 2 | 预期非零，按名 early-removal panic | `.scratch/s3-slice1-inject-early-removal.log` |
| 最终一次 `zig build test --summary all` | PASS，2513 passed / 6 skipped / 0 failed | `.scratch/s3-slice1-final-test.log` |
| `git diff --check` | PASS | 报告提交前复核 |

最终 full test 后未修改生产源码或测试；后续只做 ReleaseFast 构建/测量、只读核对和本报告。依 `docs/verification-policy.md`，本 change 没有重复运行 merge-batch 才要求的 test262、gate_smoke 或 arena audit。

## 6. representation 与 ReleaseFast 反汇编

相对本片直接基点 `2e433633`：

- `src/gc-representation-trace-snapshot.txt` 与 `src/gc_representation.zig` 均无 diff；snapshot SHA-256 为 `0100325b...938fbc88cf`；
- 物理 `Block` 仍为 112 bytes，metadata prefix/header/cell geometry 均未改变；
- ReleaseFast `core.gc_trace_stw.Collector.seedConservativeRoots` 在 base/candidate 都是 504 条指令（`0x7e0` bytes），完整 mnemonic 序列 SHA-256 都是 `a401136b...5391eb`，逐条相同；差异只有因 side metadata 扩大 owner structs 导致的字段 immediate offset 和链接地址；
- exact 与 diagnostic API 没有现有 ReleaseFast semantic consumer，因此没有可被“包装改写”加重的旧热调用点；它们的真实 lookup 成本只在 checker/test 或未来明确迁移的消费者发生。

原始 disassembly 位于 `.scratch/s3-slice1-disasm/`。这满足“API 收口本身零新增现有热路径工作”；下一节单列 authority 的真实新增成本。

## 7. authority footprint 与真实执行成本

ReleaseFast DWARF/布局核对显示：

- `Superblock` side descriptor 从 88 增至 728 bytes（每 superblock `+640`）：32 个 `u32` incarnations 共 128 bytes，32 个 identity slices 共 512 bytes；64 KiB `Block` 本体不变。
- `CellIdentity` 为 16 bytes/已启用物理 cell：4-byte reuse sequence、1-byte lifecycle state、8-byte accounted bytes 及 padding。设计冻结的纯 generation 下限是 4 bytes/cell；其余是本片 published/owned parity 的 state/accounting side authority，不应藏成免费元数据。
- `ExtentRecord` 为 56 bytes/owned non-block allocation，另有 exact-start hash table 容量/探测成本。
- candidate ReleaseFast 二进制为 29,224,584 bytes，base 为 29,042,432 bytes，增加 182,152 bytes。
- audit-only raw ledger 在 shipped ReleaseFast 中完全编译掉；下列测量因此定价的是 production generation/state authority 与其分配/查表/写入成本，不是测试 oracle。

可直接从代码确认的新增执行是：每个 block cell reservation 的 identity lookup/sequence/state/accounted 写入、每个 non-block carrier 的 extent reservation/map record/lifecycle transition，以及 teardown 删除。测量中 EB 的 candidate instructions 在不同冷进程间大幅变化，而 base 稳定；额外 side allocations/地址布局改变保守根保留量是一个与现象相符但尚未由专门计数器证明的解释，故这里只列为后续归因假设，不冒充已证死因。

## 8. 2×2 冷构建 ABBA 性能记账（不裁决）

### 合同与 provenance

- base：`main@8aba23bd`；candidate：`ebea8cb8`。该口径有意包含 S3-pre，按 driver 裁决结算累计价格。
- candidate/base 各 2 个独立 local/global cache 的冷 ReleaseFast 构建；4 个构建均 `4/4 steps succeeded`。
- 配置签名完全一致：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- 正式运行使用 `/tmp/zjs-host-heavy.lock`、CPU19、effective affinity `[19]`、`armv8_pmuv3_1`、`run_fixed_pmu.py`；preflight 的 CPU19 两秒均 100% idle。
- 全 2×2 构建组合；每组合 splay + earley-boyer；每 workload 4 个 paired ABBA ratios，`firstPositionBalanced=true`。四份 1 秒全机 Zig monitor 均为 0 bytes。
- 每 workload 的总口径是全部 16 个 paired ratios 的中位数；低于 1 才代表 candidate 工作更少。本片没有性能硬线，以下数字不作 merge 裁决。

runner 的 `binaries.qjs.repo` 会从二进制外层 candidate worktree 推断，不能证明 base commit；base provenance 由 detached base worktree `rev-parse=8aba23bd...`、独立构建目录/日志与二进制哈希固定。

### 冷构建账本

| binary | commit | bytes | SHA-256 |
|---|---|---:|---|
| candidate-a | `ebea8cb8` | 29224584 | `af219c8b25224f693c8d7fa450e3c4d969a4a6db3ceea84d272ff7833ccd6212` |
| candidate-b | `ebea8cb8` | 29224584 | `e14a7145f7a62e3c196f991087303b68e96e9ec9b1387a4b02845c6c5399cdbf` |
| base-a | `8aba23bd` | 29042432 | `8467a226b8d2436b9ca09e4991202da4f33cd93e0e60d6af2a664c0195be5af6` |
| base-b | `8aba23bd` | 29042432 | `95f3fe143792de72ba415a2731421b17e32a3c35b184827c1797a3a3cdb9a41e` |

语料 SHA-256：`base.js=216612c2...232733`、`splay.js=f9a6a60d...123f7`、`earley-boyer.js=8dd28a50...dab347`；assembled fixed-work 为 splay `e9a794ca...f36fe7`、EB `b7cb20cb...c93f9`。

### 四组合结果

每格为该组合 4 个 instructions paired ratios 的中位数（MAD）；同腿 cycles 中位数列在后两列。

| candidate/base | splay insn | EB insn | splay cycles | EB cycles |
|---|---:|---:|---:|---:|
| a/a | 1.620217714 (0.087414378) | 3.657468672 (1.038936788) | 1.410521093 | 4.858638381 |
| a/b | 1.666147554 (0.067754447) | 2.098555313 (0.391647414) | 1.437946475 | 2.389423905 |
| b/a | 1.727723341 (0.014780667) | 5.585122629 (1.272792665) | 1.511209074 | 7.374598901 |
| b/b | 1.753736784 (0.044927660) | 4.107272821 (0.083796201) | 1.520160659 | 5.475079613 |

### 全部 paired ratios 总中位数

| workload | metric | n | 总中位数 | 相对 base | 总 MAD | range |
|---|---|---:|---:|---:|---:|---:|
| splay | instructions | 16 | **1.712527813** | **+71.252781%** | 0.083133657 | [1.530190055, 1.870442312] |
| splay | cycles | 16 | **1.490203761** | **+49.020376%** | 0.061057086 | [1.325096490, 1.629970157] |
| splay | wall | 16 | 1.489590827 | +48.959083% | 0.048993143 | [1.337586799, 1.620077378] |
| earley-boyer | instructions | 16 | **4.035906651** | **+303.590665%** | 1.121869665 | [1.703625132, 7.057563726] |
| earley-boyer | cycles | 16 | **5.413951157** | **+441.395116%** | 1.746407663 | [1.758696573, 9.154543532] |
| earley-boyer | wall | 16 | 5.411241303 | +441.124130% | 1.738499750 | [1.758300021, 9.146268227] |

base EB 每腿约 451–452B instructions；candidate 腿从约 770B 到 3.185T，故这不是单纯频率或 wall-time 噪声，而是候选执行工作量显著增加且对冷进程布局敏感。原始 JSON、逐腿 runner logs、空 monitor 与构建日志均保存在 `.scratch/s3-slice1-perf/`。

再次明确：brief 将本片定义为 correctness slice，并预注册本轮性能“报告不裁决”；因此报告不把上述价格偷换成单片 NO-GO，也不尝试用任何其他指标抵消。它是后续片归因与六负载批组合线必须消费的账。

## 9. 明确未做事项

- 没有修改 metadata prefix/header/Block 物理 representation，没有建立 v2 page/radix index。
- 没有迁移 weak/diagnostic/teardown 等现有持久 handle consumer；exact handle 仍是新 authority 的窄验证面。
- 没有切换 mark/young/remembered/kind/size/teardown 的语义 reader；v1 继续权威。
- 五类 mandatory mutants 中本片只交付 brief 指定的 stale generation 与 early record removal；其余随对应分片落地。
- 没有运行 batch-only expensive gates，也没有 push。

本 lane 到此停止并保持 idle，等待交叉评审与 driver 对高额组合成本的后续归因指令。
