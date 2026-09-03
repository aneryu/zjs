> 注：原始二进制证据在临时 worktree，未入库。

# S3-pre + Slice 1 V2 交叉评审

日期：2026-09-01

评审对象：`gc/s3pre-frontier-safety-20260901@754579dbbcc1cc4c90c922ddbb4dd530005a62b7`

累计基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

输入报告：

- `/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S3_SLICE1_V2.md`
- `/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S3PRE_V2.md`
- `/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S3_SLICE1.md`

## Verdict

**REJECT。**

默认 ReleaseFast 的 comptime 消除结论可以独立复现：当前 production 没有 carrier authority 实例/写入，也没有在抽查热点中留下参数准备。但 exact API 仍以同一强类型、同一强名字向 test/audit 和 production 提供两种不同保证；后续片只要新增消费者，就可能在测试中得到 generation/state 保证、在 shipped build 中静默退化为 ABA-unsafe 的 v1 membership。与此同时，当前唯一 gate 把 generation、extent map、lifecycle、raw ledger 绑成一束；报告 §4 的逐组件翻转纪律没有源码级约束，两个 compile assertion 也允许最自然的“同步开 production”绕过。以上两项均是进入后续 consumer slice 前必须修的 HIGH finding。

## 发现清单

### [HIGH] `resolveExact` 的类型/名字没有区分强 exact 与 production v1 fallback，未来消费者会在测试中静默拿到更强保证

设计权威 `docs/tracing-gc-header-v2-design.md:134-170` 把 `AllocationHandle { base, generation }`、`allowed_states` 和 generation/state 检查定义为 `resolveExact` 的协议，并明确 queue/weak/teardown 只能传窄 state mask。实现却在 `src/core/gc.zig:5656-5707` 使用同一个 `AllocationHandle`、同一个 `ResolvedExact` 和同一个 `resolveExact`：

- test/ownership-audit 走 generation + lifecycle authority；
- production 生成 `generation = 0`，并把 `generation`、`allowed_states` 两个实参全部忽略，直接调用 `resolveExactV1`。

这不是文档注释可以补足的差异：类型系统没有 weak/strong tag，没有 capability，也没有让 production consumer 编译失败的边界。未来持久消费者若保存 handle，普通测试会走强分支并拒绝 ABA；同一源码在 shipped build 会把旧地址解析为同地址的新 allocation。现有测试已经展示这个差异：`src/tests/core.zig:17070-17117` 中 rich path 拒绝旧 generation，而 `resolveExactV1ForTest` 接受同一旧 generation 指向的 replacement。

production fallback 的定义域也比 audit authority 窄。`allocationHandle` 的注释承诺为当前 published allocation 铸造 handle，但 production 只问 `address_registry.containsHeader`；`src/tests/core.zig:3179-3188` 已有 live standalone 在 address-index OOM/incomplete 窗口暂时不在 `by_header`、随后由 side authority replay 的合法状态。reviewer 在该窗口临时加入如下 probe：audit `allocationHandle` 必须成功，同时 `resolveExactV1ForTest(audit_handle, .object)` 必须返回 `error.NotFound`。`test-core` 以 `479 passed / 6 skipped / 0 failed` 通过，实证同一个 live allocation 在测试默认 API 与 shipped fallback 间行为不同。

影响：后续 consumer migration 不能靠 code review 记住“这次要同时翻 production authority”；当前 API 会让测试覆盖的保证强于发布保证，stale handle、state-mask 误用和 transient index hole 都可能静默进入 production。

要求：把协议拆成显式不同的类型/API。v1 current-membership key 不应携带 generation/state 参数，也不应叫强 `resolveExact`；generation-bearing handle/resolve 应只在 production authority 真正可用时暴露，或要求显式 capability，使未翻 authority 的 production consumer 编译失败。production 配置还必须直接跑 consumer 的 stale-reuse、state-mask 与 incomplete-index 测试，不能由 `builtin.is_test` rich branch 代测。

### [HIGH] 单一 authority gate 会把所有 shadow 组件一起 productionize，§4 的逐项定价纪律可被一次同步翻转绕过

`gc_carrier.authority_audit_enabled` 当前同时控制：

- block incarnation、每 cell 的完整 16-byte `CellIdentity`；
- extent `AutoHashMap`、u64 generation reservation；
- lifecycle/accounted writes 与 publish/retire/free transition；
- `MemoryAccount` 的 raw ledger（equality assertion 又要求它与 carrier gate 同开同关）。

因此报告 §4 所说的 “generation storage / extent exact map / lifecycle / transitions 各随自己的 consumer 翻转并单独定价” 并不是当前代码的可表达状态。后续片若仅为了第一个 generation consumer 把这个唯一 gate 扩到 production，会默认带回初版的全部 728-byte `Superblock`、extent hash、lifecycle/accounted writes；若同时按 equality assertion 更新 oracle gate，两个 compile assertion 都通过。

reviewer 用默认 `zjs_gc=trace_stw` 模拟这条自然翻转：把 carrier gate 和 oracle gate 都追加 `zjs_gc == trace_stw`。ReleaseFast 构建成功，且 DWARF/符号显示：

| 项 | 原 `754579db` production | 同步翻转 mutant |
|---|---:|---:|
| `Superblock` | 88 B | 728 B |
| `Heap` | 496 B | 504 B |
| `MemoryAccount` | 752 B | 792 B |
| authority 写函数 | 无 | `reserveGcExtent`、`commitGcExtent`、`carrierPublish`、`carrierTransition` 等重新出现 |

原因很直接：`src/core/gc_block_heap.zig:197-204` 的 footprint assertion 仅在 `!carrier_authority_enabled` 时执行；生产翻 gate 的那一刻正好把 pin 关掉。`src/core/memory.zig:28-32` 只验证两枚总 gate 相等，不验证组件边界。

要求：在进入任何 production consumer slice 前先拆 component gate/storage：至少 block generation、extent identity、lifecycle state/transition、audit oracle 分离；consumer 与所需 authority 用 capability/compile-time dependency 绑定。每个 production 形态要有不因开 gate 而失效的独立 footprint pin 和预注册硬线，不能只要求“附 ABBA”却没有 pass/fail 边界。

### [MEDIUM] 两个 compile assertion 能抓既定大漂移，但拦截力小于报告所暗示的“防止静默扩张”

实际正/反 mutant：

1. 只把 carrier gate 翻到 production、oracle gate 不动：`src/core/memory.zig:30` 按预期 compile error，说明 equality assertion 能抓这两枚已知 gate 的非对称漂移。
2. 给 production `Superblock` 增加 `u64` 字段：`src/core/gc_block_heap.zig:203` 按预期 compile error，说明 size pin 能抓 88 -> 96 这类外显增长。
3. 给同一 `Superblock` 增加 `u8 production_shadow_state_probe`：ReleaseFast 构建成功；DWARF 仍为 88 B，新字段落在 offset 85 的尾部 padding。即 pin 只守总尺寸，不守字段集合/写集合。
4. `Heap`、`MemoryAccount`、side allocation 和热点写没有同类 pin；上一 finding 的同步翻转已实证它们可增长且两个 assertion 全绿。

所以这两个 assertion 是有用的局部回归哨兵，但不能作为 §4 discipline 的 enforcement，也不能证明 “production 无新增 authority write”。后者仍需源码 census + 反汇编，并应在未来变成按组件的结构/符号/调用面约束。

### [MEDIUM] 两个 carrier mutant 真实覆盖当前 audit checker，但不覆盖未来 production authority 的实现形态

独立复跑结果真实、按名触发：

- `ZJS_GC_CARRIER_INJECT=1 zig build test-core`：非零/`ABRT`，命中 `gc: CARRIER IDENTITY: stale generation accepted`，栈落在 `resolveExact` 和 stale block-cell generation 测试。
- `ZJS_GC_CARRIER_INJECT=2 zig build test-core`：非零/`ABRT`，命中 `gc: CARRIER IDENTITY: early record removal while raw allocation remains`，栈落在 `beginGcRawFree`，发生于实际 Shape relocation/free。

但 injection 1 只删除 audit `CellIdentity` 路径的 generation comparison；当前 production v1 route 不走这个点，而且专门测试证明它会接受 stale generation。injection 2 删除的是 audit `ExtentAuthority.AutoHashMap` record，并依赖同为 test/audit-only 的 `HeapAccountingOracle` 报警。报告 §4 已冻结未来 block generation 为 compact 4 B/cell，extent/state 也要求各自重新定价；这些未来 production representation 尚不存在，两个 mutant 自然不可能证明它们。

因此 `REPORT_S3_SLICE1_V2.md:114` 的证据边界应收窄为“当前 audit authority/checker 的 mutation coverage 成立”。未来每个 production switch 必须在其真实 production gate/representation 上另做 deletion mutant；不能继承本轮 mutant 作为 production 语义签字。

## 默认 production 消除复核（无 finding）

在 exact detached `754579db` 与 exact detached `8aba23bd` 上分别冷构建默认 ReleaseFast。candidate 签名为：

```text
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

独立 census/反汇编结果：

- 所有 reserve/commit/publish/transition/free 调用点本身均位于 `if (comptime carrier_authority_enabled)` 内；不是只在 callee 里 early-return，参数表达式也在门内。
- `nm -C` 无 `reserveGcExtent`、`commitGcExtent`、`carrierPublish`、`carrierTransition`、`reserveCellIdentity`、`identityFor`；DWARF 无 `CellIdentity`、`ExtentRecord`、`ExtentAuthority`、raw-oracle production instance。
- candidate DWARF：`Superblock=88`、`Block=112`、`Heap=496`、`MemoryAccount=752`。
- `freeSmallCell` 为 67 条、抽查 `allocCellFixedPtr<Object>` 为 139 条，base/candidate 指令字逐字节相同；`seedConservativeRoots` 504 条、`addInitializedShape` 96 条、`addInitializedWithSizeNoFail` 86 条、`Object.createInternal` 812 条，尺寸与 base 相同。`seedConservativeRoots` 的差异为累计 S3-pre 导致的 call relocation，不是 authority 参数准备。
- candidate binary 可执行，`zjs -e 'print(6 * 7)'` 输出 `42`。

所以攻击面 (1) 对当前默认 production 的结论是 **PASS**；REJECT 来自 API contract 与未来翻转边界，不是否认这次 DCE。

## 验证账本

| 验证 | 结果 |
|---|---|
| `git diff --check 8aba23bd..754579db` | PASS |
| base/candidate `zig build zjs -Doptimize=ReleaseFast` | PASS / PASS |
| reviewer incomplete-index probe + `zig build test-core --summary all` | 479 passed / 6 skipped / 0 failed |
| carrier inject 1，`zig build test-core` | 预期失败，按名 stale-generation panic |
| carrier inject 2，`zig build test-core` | 预期失败，按名 early-removal panic |
| asymmetric-gate mutant | 预期 compile error，equality assertion 命中 |
| `u64` Superblock mutant | 预期 compile error，88-B pin 命中 |
| `u8` padding mutant | 构建成功，88-B pin 漏过 |
| synchronized production-flip mutant | 构建成功，两个 assertion 均漏过，authority 成本全部回归 |

原始 reviewer 构建/二进制位于 `.scratch/review-s3-slice1-raw/`；所有临时 source/test mutant 均只在 detached `.scratch/review-s3-slice1-src` 执行并已恢复，精确目标 worktree 最终无 tracked diff。按 `docs/verification-policy.md`，本次是只读交叉评审，没有重复 merge-batch 的 test262/gate_smoke/arena-audit，也没有修改或提交 production 源码。
