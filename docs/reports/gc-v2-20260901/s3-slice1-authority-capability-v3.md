> 注：原始二进制证据在临时 worktree，未入库。

# GC v2 S3 第一片 V3 返工报告：authority capability / component gates

日期：2026-09-01

返工基点：`754579dbbcc1cc4c90c922ddbb4dd530005a62b7`

交叉评审：`/home/aneryu/worktrees/gc-settle/.scratch/REVIEW_S3_SLICE1.md`

实现归档：

- `8f8c9a60e24ff1e193ea5d5dac84f8754184623b` `gc: split carrier authority capabilities`
- `9aea68759373365d9b26c028822e6633ca94c6dd` `gc: pin component container footprints`

## 结论

**API/correctness 返工 PASS；快速性能硬线不全绿，因此本 lane 按数值维持 NO-GO，交 driver 裁决。**

HIGH-1/HIGH-2 与 MEDIUM 要求均已落到源码边界：

- v1 查询现为 `CurrentMembershipKey` / `ResolvedCurrentMember` / `resolveCurrentMember`，只表达当前地址成员资格，不携带 generation 或 state mask；
- generation-bearing `allocationHandle` / `resolveExact` 强制接收 comptime `ExactAuthorityCapability`，普通 production build 无法取得 production capability；
- block generation、extent identity、lifecycle state、audit oracle 已拆为四枚独立 production selection/gate 和独立存储；
- 组件类型、`Superblock`、`Heap`、`MemoryAccount` 的实际尺寸 pin 在 gate 开启时仍求值；容器另有字段集合 pin，堵住尾 padding 偷渡；
- reviewer 的 incomplete-index probe、自然同步翻转、production capability 和 padding probe 均已固化为回归测试或实编译负测试。

正确性最终结果为 `2515 passed / 6 skipped / 0 failed`。默认 ReleaseFast 仍为 `Superblock=88 B`、`MemoryAccount=752 B`，无 authority 写函数；抽查热点 mnemonic 与 `754579db` 一致。

但 1×1 冷构建快速 ABBA 的 paired-ratio 中位数为：

| workload | instructions | `<=1.002` | cycles | `<=1.002` |
|---|---:|---:|---:|---:|
| splay | **0.999487869** | PASS | **1.002708905** | **FAIL** |
| earley-boyer | **0.998312626** | PASS | **1.033431548** | **FAIL** |

EB 四条 cycles ratio 全在 `[1.032588301, 1.043883581]`，不能按噪声腿删除。PMU 同时显示 EB branch-miss 中位 `1.154274309`，而 instructions、branch-instructions、cache-misses 均不增加；结合热点指令一致与 `.text` 地址整体挪动，当前证据更符合链接布局/分支预测价格，而不是 authority storage/write 漏入 production。该归因是**形状一致的推断**，不是已完成的单函数因果二分；硬线仍按预注册规则判 FAIL。

## 1. HIGH-1：诚实的 current membership 与强 exact capability

### 1.1 API 拆分

弱协议现在是独立类型和名字：

```text
CurrentMembershipKey { base: usize }
ResolvedCurrentMember
Registry.resolveCurrentMember(key, expected_kind)
```

它只检查现有 v1 `address_registry.containsHeader` 与当前 header kind：

- 无 generation 字段；
- 无 lifecycle state 参数；
- 不承诺 ABA 防护；同地址复用后旧 key 合法地解析到当前 occupant；
- cold address index 不完整时可返回 `NotFound`。

强协议继续使用 `AllocationHandle { base, generation }`，但调用边界变为：

```text
allocationHandle(comptime capability, header)
resolveExact(comptime capability, handle, expected_kind, allowed_states)
```

`auditExactCapability()` 只在 test/ownership-audit 且三项 exact authority 齐全时可取得；`productionExactCapability()` 要求 production selection 已显式启用 block generation、extent identity、lifecycle state。`requireExactCapability` 在两个强 API 内再次校验 token，调用者手写 `.production` 也不能绕过。

实编译 production consumer probe 在默认 ReleaseFast 命中：

```text
error: production exact identity authority is not available
```

证据：`.scratch/s3-slice1-v3-production-capability-negative.log`。

### 1.2 reviewer incomplete-index probe

live standalone 回归测试现在确定性执行以下交错：

1. standalone 已 publish，audit strong authority 可 mint handle 并 `resolveExact`；
2. 人工保持 cold current-membership index 不完整；
3. 对同一 live header 调用 `resolveCurrentMember` 必须得到 `error.NotFound`；
4. replay/rebuild 后 current membership 恢复。

这把 reviewer 的临时 probe 固化在 `src/tests/core.zig`，明确证明两种 API 的定义域不同，不再把 v1 fallback 冒充 strong exact。

### 1.3 production 合同不由 `builtin.is_test` rich 分支代测

测试直接调用无 build-mode 分支的 `resolveCurrentMember`：

- stale reuse：旧 `CurrentMembershipKey` 解析到同地址 replacement；同时 strong audit handle 拒绝旧 generation；
- state：人工把 replacement 转为 `.doomed` 后 current membership 仍成功；同时 published-only strong resolve 返回 `StateMismatch`；
- interior address：current membership 返回 `NotFound`；
- signature introspection：key 大小必须恰为一个 `usize`，method 恰为 `self + key + expected_kind` 三参，类型系统中没有 generation/state 槽位。

因此测试 binary 虽同时拥有 rich audit authority，production current-membership 合同仍由独立 API 的同一实现直接执行，而不是 `if (builtin.is_test)` 的另一分支。

## 2. HIGH-2：四组件 gate、storage 与 capability dependency

`ProductionAuthoritySelection` 有四枚互不派生的 production bit，当前全部为 false：

| component | gate | 独立 storage / write domain | 当前 production consumer |
|---|---|---|---|
| block generation | `block_generation_enabled` | block incarnation + `[]u32` cell generation | 无 |
| extent identity | `extent_identity_enabled` | generation counter + `ExtentIdentityAuthority` hash | 无 |
| lifecycle state | `lifecycle_state_enabled` | block `CellLifecycle` + `ExtentLifecycleAuthority` | 无 |
| audit oracle | `audit_oracle_enabled` | independent `HeapAccountingOracle.raw` ledger | 无 |

`block_tracking_enabled` / `extent_tracking_enabled` 只用于共享 raw-allocation seam 的最小外层路由；实际 reserve/commit/publish/transition/free 仍分别受所需 component gate 控制。strong exact 的 capability 明确绑定它实际读取的 generation + extent identity + lifecycle 三组件；当前 production 没有该 capability，也没有 migrated consumer。

production selected bits 与 `production_approved` 分开。任何组件若只翻 selected 而未在消费片预注册 approved/budget，会在存储出现前 compile error。reviewer 的“自然同步全翻”实编译 mutant 现命中第一项：

```text
error: unpriced carrier authority production component: block_generation
```

永久测试 `synchronized production authority flip is rejected before storage appears` 同时固定 `.all()` 的首个 violation；实编译证据为 `.scratch/s3-slice1-v3-sync-flip-negative.log`。

## 3. footprint pins 与 padding 边界

所有 pin 均为无 `!enabled` 保护的 unconditional comptime assertion，因此 test/audit 的 enabled shape 和未来 production enabled shape 都会检查实际尺寸。

| 组件/容器 | 冻结预算 |
|---|---:|
| block generation cell | 4 B / physical cell |
| generation-enabled `Superblock` descriptor 增量 | 640 B（128 B incarnations + 512 B slices） |
| generation-enabled `Heap` 增量 | 8 B |
| block `CellLifecycle` | 16 B / physical cell |
| lifecycle-enabled `Superblock` descriptor 增量 | 512 B |
| `ExtentIdentityRecord` | 48 B |
| `ExtentIdentityAuthority` | Debug 40 B / ReleaseFast 32 B |
| `ExtentLifecycleRecord` | 16 B |
| `ExtentLifecycleAuthority` | Debug 24 B / ReleaseFast 16 B |
| `HeapAccountingOracle` | Debug 56 B / ReleaseFast 48 B |
| production base `Superblock` | 88 B |
| production base `Heap` | ReleaseFast 496 B / safety-enabled 520 B |
| production tracing base `MemoryAccount` | 752 B |
| audit/test tracing `MemoryAccount` | 824 B |

`Superblock` 固定 7 个字段，`MemoryAccount` 固定 27 个字段。这样新增 `u8` 即使落入既有尾 padding，也先撞字段集合断言。两个实编译负测试分别命中：

```text
error: Superblock field set changed
error: MemoryAccount field set changed
```

证据：

- `.scratch/s3-slice1-v3-padding-negative.log`
- `.scratch/s3-slice1-v3-memory-padding-negative.log`

补 pin 时，最终全测还实际覆盖了非 test Debug runtime-plugin 形态：该形态 `Heap=520 B`，说明预算按 `std.debug.runtime_safety` 而不是误按 `builtin.is_test` 区分。`test-runtime` 76/76 通过。

## 4. mutation 证据边界

两枚既有 named mutation 均继续按名触发：

- `ZJS_GC_CARRIER_INJECT=1`：预期 ABRT，`gc: CARRIER IDENTITY: stale generation accepted`；
- `ZJS_GC_CARRIER_INJECT=2`：预期 ABRT，`gc: CARRIER IDENTITY: early record removal while raw allocation remains`。

本报告只签字：它们覆盖**当前 test/ownership-audit authority 和 checker 的形态**。它们不覆盖未来 compact 4-B production generation、未来 production extent map 或未来 lifecycle representation。每个组件在真实 consumer slice 翻 production 时，必须针对当时真实 storage/write/read path 另做 deletion/transition mutant，不能继承本轮签字。

同步翻转、production capability 与 padding probes 是 compile-boundary 证据，也不替代未来组件性能定价。

## 5. correctness 验证账本

| gate | 结果 | 证据 |
|---|---|---|
| `zig build check --summary all` | PASS，3/3 | `.scratch/s3-slice1-v3-check-final-v3.log` |
| `zig build test-core --summary all` | PASS，480 passed / 6 skipped / 0 failed | `.scratch/s3-slice1-v3-test-core-after-memory-pin.log` |
| `zig build test-runtime --summary all` | PASS，76 passed / 0 failed，含 plugin fixtures | `.scratch/s3-slice1-v3-test-runtime-after-pin.log` |
| carrier mutant 1 | 预期非零，按名 stale-generation panic | `.scratch/s3-slice1-v3-inject-stale.log` |
| carrier mutant 2 | 预期非零，按名 early-removal panic | `.scratch/s3-slice1-v3-inject-early-removal.log` |
| 同步 production flip | 预期 compile fail，unpriced component | `.scratch/s3-slice1-v3-sync-flip-negative.log` |
| production strong consumer | 预期 compile fail，capability unavailable | `.scratch/s3-slice1-v3-production-capability-negative.log` |
| `Superblock` u8 padding | 预期 compile fail，field set | `.scratch/s3-slice1-v3-padding-negative.log` |
| `MemoryAccount` u8 padding | 预期 compile fail，field set | `.scratch/s3-slice1-v3-memory-padding-negative.log` |
| 最终 `zig build test --summary all` | PASS，2515 passed / 6 skipped / 0 failed；9/9 | `.scratch/s3-slice1-v3-final-test-v3.log` |
| `git diff --check` | PASS | 报告提交前复核 |

按 `docs/verification-policy.md`，本 change 未重复 merge-batch-only 的 test262 / gate_smoke / arena audit。

## 6. production DCE / disassembly

最终冷 candidate：

```text
commit: 9aea68759373365d9b26c028822e6633ca94c6dd
signature: zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
bytes: 29071440
sha256: 790d975e94225cdaf53cbfec2c413303835d27c01bee8f616cba78733c2cc6bd
```

冻结 base：

```text
commit: 754579dbbcc1cc4c90c922ddbb4dd530005a62b7
bytes: 29070184
sha256: 94d2950ac8424d6ea879e014269755c4f241fe54374d565c93d91ba188594b2f
```

production DWARF 与 symbol census：

- `Superblock=88 B`、`MemoryAccount=752 B`；
- 无 `reserveGcExtent`、`commitGcExtent`、`carrierPublish`、`carrierTransition`、`reserveCellIdentity`、`identityFor` production symbol；
- `zjs -e 'print(6 * 7)'` 输出 `42`；
- 最后 footprint-pin commit 只改变 DWARF/符号信息：最终 candidate 与 ABBA 实测 candidate 经 `objcopy --strip-all` 后逐字节相同，二者 SHA-256 均为 `004199f16932672d0b60c26814c9469abd7b2cd7c8b89be51173d6e627fc7d02`，`.text` SHA 亦相同。

相对 `754579db` 的热点 mnemonic 抽查：

| function | base | candidate | 结论 |
|---|---:|---:|---|
| `Heap.freeSmallCell` | 67 | 67 | mnemonic/hash 相同 |
| `Collector.seedConservativeRoots` | 504 | 504 | mnemonic/hash 相同 |
| `Registry.addInitializedShape` | 96 | 96 | mnemonic/hash 相同 |
| `Registry.addInitializedWithSizeNoFail` | 86 | 86 | mnemonic/hash 相同 |
| `Object.createInternal` | 812 | 812 | mnemonic/hash 相同 |
| 3 个 `allocCellFixedPtr` 实例 | 139 | 139 | mnemonic/hash 相同 |

证据：`.scratch/s3-slice1-v3-perf/disasm/targeted-summary.tsv`。全 `.text` 不是字节同一：candidate 小 644 B，部分符号地址发生移动；这正是下一节 branch predictor 形状的可能来源，不能把“抽查热点同一”扩写为“全二进制同一”。

## 7. 1×1 冷构建快速 ABBA

合同：

- base/candidate 各一个独立 local/global Zig cache 冷构建，均 4/4 succeeded；
- host lock `/tmp/zjs-host-heavy.lock`，CPU19，fixed PMU，ABBA first-position balanced；
- preflight CPU19 两秒平均 99.5% idle；并发 Zig monitor 为 0 bytes；
- splay + earley-boyer，各 4 paired legs；每 metric 以 4 个 paired ratios 的中位数裁 `<=1.002`；不删腿、不用 instructions 抵消 cycles。

| workload | metric | paired-ratio median | MAD | range | verdict |
|---|---|---:|---:|---:|---:|
| splay | instructions | **0.999487869** | 0.000640599 | [0.991603231, 1.000758713] | PASS |
| splay | cycles | **1.002708905** | 0.001301113 | [1.000515368, 1.004104429] | **FAIL** |
| earley-boyer | instructions | **0.998312626** | 0.000244013 | [0.997945764, 1.001917754] | PASS |
| earley-boyer | cycles | **1.033431548** | 0.000593142 | [1.032588301, 1.043883581] | **FAIL** |

EB 辅助 PMU paired-ratio 中位数：

| metric | ratio |
|---|---:|
| branch-instructions | 0.996894372 |
| branch-misses | **1.154274309** |
| cache-references | 0.998232459 |
| cache-misses | 0.965804365 |
| wall | 1.033592369 |

原始逐腿、JSON、preflight、monitor 与冷构建日志均位于 `.scratch/s3-slice1-v3-perf/`。最终 pin commit 的 stripped runtime image 与实测 candidate byte-identical，因此该 ABBA 对最终实现有效；没有拿旧运行映像代替新代码。

## 8. 后续片纪律

1. 四枚 `production_authority` bit 当前保持 false；checker/oracle 可 audit-only 常驻，但零消费者不得提前 productionize。
2. 某组件只在首个真实 consumer 迁移的同一片进入 `production_approved` 与 selected gate；consumer 必须持有与其 read-set 对应的 comptime capability/专用 API。
3. 每次只为该 consumer 的最小 authority 翻转和定价；若现有 broad `resolveExact` 的 dependency 过宽，应先拆更窄 capability/API，不得为方便把无关 component 一起打开。
4. 每次翻转重新验证 enabled footprint pin、生产 symbol/call surface、真实 mutation 与 ABBA；本轮 audit mutant 不继承为 production 证明。
5. 终态 block generation 预算继续冻结为 4 B/physical cell；lifecycle 与 extent 各用自己的预注册预算，不得借 generation 预算隐藏。

本 lane 到此停止并保持 idle，等待 driver 对 correctness 资产与快速性能 FAIL 的终审。
