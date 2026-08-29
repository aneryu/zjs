# Tracing GC 设计 backlog 现状(2026-08-28)

这里记录设计文档 backlog 的当前裁决。lane 上有机制不等于主线 gate
已通过;已量出的 FAIL 继续明记,避免后来人重做已关闭实验。

## A. 已解除阻塞的设计项

**A1. §4.5 target object header — IN PROGRESS(lane-b)。** 目标仍是无 `rc`
字段的 8 字节不可变 header,以及 tracing side metadata。compact-header
tranche 与它的重新定价还在 lane-b,未进主线,表示层/性能 gate 未
claim。现有 block-cell carrier 已能服务 GC 节点,所以 A1 不再是 A2
的测量前提。✅ lane-b 尖端 `f469ab96`(shape-summary 追加契约改写)的
`ObjectShapeSummaryMismatch` 已结案:该 commit 不是一把刀,而是对已在
主线的追加写入器的**回归**——它把容量判据换成了恒真条件,第一次追加
就把摘要打成 overflow,快臂对任何带属性的对象全部失效。审计器是规范,
无法与之配对(配对只能靠放宽到失明),故弃刀。写入器已撤销为与
`f469ab96^` 逐字节相同,并补上两个直接覆盖两个增量写入器的用例
(见 `gc/opus-laneb-red`)。rc/trace 双变体单测与主线合并后双变体均绿,
rc ReleaseFast `.text` 与合并基逐字节相同。A1 的其余部分(compact-header
tranche 的重新定价)仍在 lane-b。

**A2. Stage 4 allocator fragmentation / committed-memory envelope — DONE,
FAIL。** block cell 服务 GC 节点后,“必须等 §4.5”的 deferred 前提已
失效。Stage 4 表现在有两行独立证据:六个 fixed-work 都未达原始
block `committed/live < 1.3`;同记账域的 collector `P/T < 36/35` 在
raytrace 和 regexp 上失败,六个负载 forced finish 均为零。splay 的 152
superblock 进一步拆为约 41 dense-live + 85 partially-full-hole + 26
empty-high-water;其中 85 是保留 bump 顺序的已定价代价。

**A3. Stage 5 evidence gate — DONE, FAIL / NOT CLAIMED。** 五行复审已写入
Stage 5 表。old-to-young 删除探针和实测 minor pause 分布 PASS;
young-list 渐近伸缩性、真正的 false-conservative-promotion 判定器、
及所要求的内存放大包络 FAIL。机制已在,但 gate 不 claim。

**A4. §2.2 / §7.1 precise-root completeness — IN PROGRESS(lane-a)。** 多个
dequeue/evaluation/module/public-call 具体根缺口已关闭,full-trace verifier
正被收窄到单次 collection 边界,但 root completeness 仍未 claim。生产的
保守捕获只暴露 `conservative_on = !host_quiescent`,无法判定某个留任
word 属于哪类语义根,因此还不能逐类退役保守扫描。

## B. 被推迟或证据降级的项

**B1. mutator-concurrent payload enumeration — DEFERRED;旧阻塞句写错。** worker
侧 child enumeration 已存在:`gc_parallel_mark.zig` 的 helper 在 mutator 停止
的 slice 内并行调用权威 `traceHeaderEdges` / `traceChildEdges`。这是 parallel
STW,不是 mutator-concurrent enumeration,因而不需要 concurrent payload
snapshot 或 `mutator_only` bailout。真正不存在的是 worker 与 mutator 同时
遍历可变 payload。driver 的 CPU 秒证据也已将其降级:并发不消除额外
工作,该未来 tranche 主要买 pause,不解当前 throughput 差距。

**B2. §6.1 trace classes — 原三分法搁置。** lane-e 的静态核查用当前
parallel-STW 真正需要的契约取代 `atomic_slots` / `snapshot` /
`mutator_only`:工作线程仅亲和于冻结的 STW slice、不从 worker 回调
embedder,并用编译期布局/边枚举契约守住 trace authority。只有当
mutator-concurrent payload enumeration 被重新提升优先级时,才重开 snapshot
class;它们不被“没有 worker 枚举”阻塞,因为后者已在运行。

**B3. Stage 7 production default — BLOCKED。** experimental opt-in 与回滚已有,
但 correctness/root 签字及声明的内存 gate 未绿。最新已裁决
`gc_heavy_six` 为 1.0973;除 splay 外五个的 geomean 已是 1.0258,而
splay 单项 1.537。整体仍超出 1.05 margin,且不能靠把 mark 工作移到
另一个核解决。

## C. 实现核实项

- **§8.7 mutator-only lazy sweep — AUDITED, OWNER-CLOSED (lane-d)。** 历史
  `fresh -> active -> needs_sweep -> sweeping -> swept -> active` 五态图没有成为
  物理 block authority，保留为 test/shadow oracle。规范现以 production 实际
  机制为准：doomed-slice 预算化惰性销毁、`doomed_pending` transaction gate、
  物理 block 稳定两态 `active/swept`，并把 `active -> swept` 直接边升格为
  设计边。详见 `tracing-gc-pause-plan.md` §4e.1。
- **§9.4 native/plugin finalization callback reentry — IN PROGRESS
  (lane-c)。** plugin ABI 允许 callback reentry;归属的 lifecycle/state-machine 审计
  与证据仍在 lane-c,此行保持开放。
- **§10 buffer external pressure — VERIFIED。** 超过 inline 上限的普通
  ArrayBuffer backing 同时是真实 `MemoryAccount` 分配和 external token;
  inline bytes 在已记账 payload 内,用 untracked 逻辑 ledger。SharedArrayBuffer
  store 与 embedder-adopted backing 不进 `MemoryAccount`,但有 tracked token;
  TypedArray/DataView view 不重复记 backing。tracked 分配累加
  `byte_length * external_weight` debt,到 debt/live limit 时排 major,不改写
  `malloc_gc_threshold`。token release、inline release、普通 detach/replace/destroy
  以及最后一个 shared-store owner 都对称减 live external bytes;debt 则有意
  保留到一次 completed major 清零。

  可证伪探针把普通堆阈值锁为 `maxInt`:7 个有根的 1 MiB SharedArrayBuffer
  产生 56 MiB weighted debt 且不请求 GC;第 8 个达到默认 64 MiB debt
  阈值,排入 `allocation_debt`,一次 poll 在 8 个 store 全部存活时完成一次
  major;最终释放后 external bytes 和 token 都为零。该探针在当前主线
  RC 与 experimental-trace `test-core` 都已通过。

  FNABI 的默认价在内部已实现:所有 in-tree 堆外 buffer 都用 token 跟踪,
  并按真实 backing `byte_length` 计价(可增长 shared store 因为一次性提交
  全 capacity,按 `maxByteLength` 价)。没有 in-tree buffer backing 漏价。
  但完整公开 FNABI 仅 **partial conformance**:`JSBytes.Store` 没有独立的
  必填 price/override 字段,总是从 `bytes.len` 派生。若冻结 ABI 要求调用者
  即使接受默认值也必须显式带该字段,Adapter surface 仍需补齐。

## FNABI 侧欠账(lane-f §10 核实发现,2026-08-28)

公开 \`JSBytes.Store\` 无独立必填 price/override 字段,只按 \`bytes.len\` 计价。
内部默认 byte_length 与 FNABI v0.7 M0D 裁决(外部内存计价必填,默认 byte_length)
的**默认值**一致、无 in-tree 漏价,但若冻结 ABI 要求显式字段则为 partial
conformance。归 FNABI 实现线处理,不在 GC 战役范围。
