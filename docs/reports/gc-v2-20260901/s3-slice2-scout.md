> 注：原始二进制证据在临时 worktree，未入库。

# S3 Slice 2 Scout：`Header.next` 借用者普查、迁移设计与验收线草案

Status: **SCOUT COMPLETE — ZERO IMPLEMENTATION**

勘察基点：只读 `main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`。设计权威为
`docs/tracing-gc-header-v2-design.md`（APPROVED r2）。本文没有 checkout 或改动
`gc/s3pre`，没有源码修改、commit 或性能运行。

## 0. 结论先行

1. slice 2 应迁走的真实生命周期拓扑不止 brief 点名的三个：除
   `tmp_obj_list`、`doomed_by_kind`、`cycle_deferred_frees` 外，还有
   `zero_ref_list`、`zero_ref_current`/`sweep_current` 所代表的 active-owner
   窗口，以及 `Registry.deinit` 的三条本地 hold 栈。漏掉任一个，都不能关闭
   teardown 的 owned-allocation 等式，也不能最终删 `Header.next`。
2. obj-prereq 后，普通 `Object` 已不借 `gc_obj_list`：block Object 由 alloc bitmap
   权威，non-block Object 由 `NonBlockObjectAuthority` 权威。但
   `FunctionBytecode`、`VarRef`、`Realm`、`Module`、`Shape` 仍在
   `gc_obj_list`，young 集合仍是该链的后缀。因此本片若只做原 reviewer 六步计划的
   “doomed/deferred/tmp topology”，**不能声称全局 `Header.next` borrower 为零**。
3. 推荐明确 slice 边界：本片翻转 collector/teardown 的 lifecycle topology；
   `gc_obj_list` + young suffix 作为下一片 TraceLive/young authority 的真实消费者。
   本片验收应是“被迁移 borrower allowlist 归零”，而不是 r2 九步表第 6 行中未经
   拆分的“no `Header.next` borrower remains”。若 owner 坚持后一句必须在本片成立，
   就必须把高频 publication/young 读写一起纳入并独立定价；不能把它伪装成冷端搬迁。
4. block doomed 已经是 side bitmap + block link，不需要也不允许按 v3 草稿形状支付
   宽 `CellLifecycle`。本片 block 新成本的合理上界是一个 parked bitplane（1 bit/cell，
   约 0.125 B/cell，另计布局 padding）；4 B/cell generation 预算保持独立，若没有
   block-cell generation handle 的真实消费者，本片不得打开它。
5. extent doomed/parked/current 队列跨 destruction slice，必须用 APPROVED r2 的稳定
   `RecordId { slot, generation }`，不能保存可移动 table entry 指针或裸 body 指针。
   所以本片生产翻转 `lifecycle_state`，且 extent 路径同时成为
   `extent_identity` 的第一个真实消费者；两个组件分别计 footprint/热成本。
6. 历史 destroy/sweep `-5.28pp` 只能是风险预算上下文，不是继承端点。建议预注册
   “候选 destroy/sweep 最多返还 H_PRE 总 cycles 的 `+0.50pp`，且自身 bucket
   ratio `<=1.05`”的双线；splay/EB 各自 cycles(u+k) `<=1.003`，instructions
   `<=1.003`。这些数值须由 driver 在 H_PRE 探针后、候选计时前冻结。

## 1. `Header.next` 全借用者清册

### 1.1 公共物理原语

`TraceHeader.next` 是当前 8 B mutable word（`src/core/gc.zig:1074-1088`）。以下
公共原语直接读写它：

- circular singly-linked FIFO：`IntrusiveHeaderList` 及 init/add/delete/first
  （`src/core/gc.zig:1320-1428`）；tail 存在容器侧，节点仍各带一个 successor。
- membership/invariant：`headerLinked` 与环链校验
  （`src/core/gc.zig:1431-1478`）。
- singly-linked LIFO：`DeferredFreeStack`
  （`src/core/gc.zig:1481-1517`）。
- `HeaderList` wrapper（`src/core/gc.zig:1561-1595`）目前没有定义外的实例；它是
  dormant compiled dependency，终态仍须删除/替换，不能因“没有 live instance”漏出
  field-removal census。
- allocation 初始化仍显式写 `h.next = null`（`src/core/gc.zig:2683-2692`）。

除上述三个文件 `src/core/gc.zig`、`src/core/gc_trace_stw.zig`、
`src/core/object_gc.zig` 外，main 上其他 `.next` 命中是 payload/arena/普通列表字段，
不是 `TraceHeader.next` borrower。

### 1.2 活跃借用者矩阵

| 借用者 | 当前成员与证据 | 拓扑/顺序合同 | 写频率量级 | 并发与存活期 | slice 2 迁移目标 |
|---|---|---|---|---|---|
| `gc_obj_list` | field：`gc.zig:1912-1918`；publish/link：`3595-3608`；collect/detach：`gc_trace_stw.zig:1266-1297,2444-2479` | allocation-ordered circular singly-linked FIFO；Shape/Realm body 内另存 predecessor accelerator | 每个 non-Object traced extent publish 一次 append，condemn/eager-zero/deinit 一次 detach；allocation-scale hot producer | mutator publication 会写；collector 读取/摘链；跨所有 collection 与 mutator window 长期存在 | **推荐不在本片翻转**。下一片用 extent `state==published` 的 TraceLive iterator；Shape/Realm backlink 同时退场 |
| young suffix over `gc_obj_list` | state：`gc.zig:1920-1928`；iterators：`3421-3485`；publish/detach：`4695-4776`；minor scan：`gc_trace_stw.zig:2336-2352` | 不是第二条链；`young_head` + predecessor 把 allocation-ordered list 的连续后缀解释为 young set | 本身每代只改两个 runtime cursor，但消费/依赖每个成员的 `next`；minor 按 young population 读 | 跨 minor，且在 mutator publication 之间保持；不是 STW-private scratch | **推荐不在本片翻转**。下一片 extent young flag/set + block existing young list；必须与 TraceLive reader 同切 |
| `tmp_obj_list` | field：`gc.zig:1929`；minor/full producers：`gc_trace_stw.zig:2295-2409,2427-2498`；multi-pass destroy：`2679-2824` | mixed-kind circular FIFO；destroy 按 Object→Realm→Module→FB→VarRef/Shape 多趟过滤；语义顺序在 kind pass，不在原 allocation order | 每个本轮 condemned extent 一次 append + 一次 delete；当前算法还可能按 kind 多次读取残余链 | collector STW/private；只在一个 minor/full sweep/destroy 调用内存活，不跨 mutator window | 不再建 tmp 容器；condemn 时直接写 carrier state 并入 per-kind doomed queue，minor/full 共用同一 drain |
| `doomed_by_kind[kind]` | field/init：`gc.zig:2054,2119`；producer：`gc_trace_stw.zig:1250-1313`；census：`1410-1470`；budget drain/cursor：`1577-1646` | per-kind circular FIFO；只从 head drain；`doomed_cursor` 是 sliced resume cursor | 每个 condemned non-block extent 一次 append + 一次 head remove；block cell 不进此链 | condemnation 在 collector 边界；bucket/cursor 跨 destruction slices 和其间 mutator window；finalizer 重入期间仍是 ownership 事实 | extent record `published->doomed`，per-kind `DoomedExtentQueue<RecordId>`；block 保留现有 doomed bitmap + `Block.doomed_link` |
| `cycle_deferred_frees` | contract/count：`gc.zig:1962-1984`；push：`2124-2129`；weak settle：`object_gc.zig:255-349`；budget drain：`399-455`；incremental use：`gc_trace_stw.zig:1648-1679` | singly-linked LIFO；现有 producer 排列形成 generic extent prefix + contiguous block runs；Pass-B 顺序本身无析构语义，但 routing/locality 是成本合同 | 每个没有 Pass-A settle 的 corpse 一次 push + pop；源码历史量级为 raytrace 41M、EB 72M，drain 曾占 destroy stopped time 34%（`gc.zig:1969-1977`） | 跨 pending finalizer/destruction slices，且可跨 mutator window；不是临时 STW 栈 | extent `parked` state + `ParkedExtentStack<RecordId>`；block parked bitplane + block queue，保持 extents-first/block-runs 路由 |
| `zero_ref_list` | field/current slots：`gc.zig:1929-1950`；enqueue/drain：`4808-4869` | circular FIFO；outermost drain 防止 nested release/reentrancy；current slot 临时接管 ownership | 每个进入 eager/RC-zero teardown 的 header 一次 append + head delete；非正常 tracing 主路，但 Shape/Realm/deinit/弱逻辑仍活跃 | 可跨一次嵌套 destructor/release 调用；通常不跨 safepoint，但 callback 可观察 `ownsObject` | per-kind extent teardown queue；entry 为 `RecordId`；active pop 转 `finalizer_current`，`zero_ref_current`/`sweep_current` 统一为 checked active handle |
| `Registry.deinit` local hold stacks | `held_shapes`、`held_var_refs`、`held_function_bytecodes`：`gc.zig:2215-2298` | 三条 local singly-linked LIFO；先拆 Object edges，再按 FB/VarRef/Shape 安全顺序释放 storage | teardown 中每个仍存活的对应 extent 一次 push + pop | 只在 runtime deinit 内，但跨 destructor/drain 调用；没有 mutator，仍不能在不可逆 teardown 后新增 fallible allocation | 复用 extent record 的 mutually-exclusive owner link/state，形成预留容量或侵入 record 的 per-kind teardown queues；不在 corpse header 上串链 |

### 1.3 obj-prereq 后的精确人口

`NonBlockObjectAuthority` 的合同明确写着：block Object 由 block allocation bitmap
枚举；non-block Object 由 no-fail side vector 枚举；**every other traced kind remains
on `gc_obj_list`**（`src/core/gc.zig:1519-1528`）。分配/链接处又断言
`kind != .object` 才能进入 `gc_obj_list`（`gc.zig:3595-3608`）。因此当前余额恰为：

```text
gc_obj_list = FunctionBytecode + VarRef + Realm + Module + Shape
Object       = block alloc bitmap + NonBlockObjectAuthority
young        = gc_obj_list young suffix + filtered non-block Object vector
               + block young-block list
```

block 的 young topology 是 `Block.young_link`，doom topology 是
`Block.doomed_link` + reused remember bitmap（`gc_block_heap.zig:191-218,420-484,
832-865,1084-1085`）；二者都不是 `Header.next` borrower。这是负向清册结论：slice 2
不得再为 block doom 创建一份 per-cell intrusive successor。

### 1.4 非 borrower 但必须联动退出的 bridge

`NonBlockObjectAuthority` 本身不写 `Header.next`，却是当前 standalone Object 的
published/ownership bridge。APPROVED r2 §5.4 要求：只有它与 extent
`state==published && kind==Object` 双向相等，并且 independent raw ledger 对所有
non-live owned state 也相等，才能删除它。生命周期 authority 本片转 production 时，
应把它纳入 parity/exit 计划；不能只搬 list borrower、留下第二份永久所有权事实。

## 2. 迁移设计草案

### 2.1 side authority 形状

#### Extent

采用 r2 已批准的 non-moving extent record storage 与
`RecordId { slot, generation }`。每个 record 至少承载：

```text
state: constructing | published | doomed | finalizer_current | husk |
       parked | rollback_pending | raw_free_in_progress | absent
kind / raw_bytes / accounted_bytes / generation
owner_next: ?RecordId       // 仅在 mutually-exclusive owner queue 中复用
queue_class: none | doomed | parked | zero_ref | deinit_hold
```

- `DoomedExtentQueue[kind]`：FIFO，head/tail 存在 collector 侧；保持 per-kind destroy
  顺序和 budget resume，`doomed_cursor` 改为 `?RecordId`。
- `ParkedExtentStack`：LIFO；preserve generic-extent-first drain。若未来测量证明 FIFO
  更好，必须另做顺序不敏感测试与定价，不能在本片顺手改。
- `zero_ref`/deinit hold：复用同一 `owner_next`，因为合法状态下一个 allocation
  同时只能属于一个 owner queue；checker 必须验证 queue_class 与 state 双向一致。
- record/generation/index capacity 在 raw allocation observable 前 reserve；进入 doomed
  后的所有 append/transition 都是 no-fail。跨 slice 的 cursor/handle 一律 resolve
  `RecordId` 并核 generation，不缓存 hash-table value pointer。

#### Block Object cells

- `doomed`：继续使用现有 condemnation bitmap 与 `Block.doomed_link`。这是已工作的
  side authority；本片做的是把它正式解释为 lifecycle state 并接入统一 Owned iterator，
  不是复制它。
- Pass-A settle 成功：cell 直接走 `doomed -> raw_free_in_progress -> absent`，清 alloc
  bit/debit 后不得留任何 exact cell handle。block 仍处于 reuse quarantine，允许尚未处理
  sibling 读取未覆写 bytes；这个许可属于 block transaction，不把已 free cell重新算作
  owned。
- 不能 settle 的 corpse：置 parked bit，再加入 block-level parked queue；Pass B 按 bit
  words drain。可在 doom drain 已完成后复用 `Block.doomed_link` 作为 lifecycle link，
  但代码/API 名称必须反映 phase exclusivity，checker 证明两种 membership 不并存。
- weak husk 与 active current 若不能由已有弱表/scalar handle 完整表达，再增加独立 bitplane；
  不能退回 per-cell Zig enum/struct。

### 2.2 `tmp` 与 incremental 两条路合一

当前 non-incremental 路径先把 dead extent 搬到 mixed `tmp_obj_list`，再按 kind 多趟
拆；incremental 路径已经直接建 `doomed_by_kind`。迁移后两条路应共享一个 primitive：

```text
condemn(record/cell):
    published -> doomed              // callback/body mutation之前
    unlink from TraceLive authority
    enqueue exact owning carrier once
```

full/minor 的 `tmp_obj_list` 消失，destroy 直接按 per-kind queues 执行现有 kind order。
`residual_kinds` 优化仍可由非空 queue bitmap O(1) 给出，不能重新对 73.6M EB VarRef
残余做空 pass（当前注释与量级在 `gc_trace_stw.zig:2719-2728`）。

### 2.3 authority component gate

按 slice1 v3 的 component-gate 纪律，本片建议生产组合为：

| component | production | 原因/依赖 |
|---|---:|---|
| `lifecycle_state_enabled` | **ON** | doomed/parked/current readers 真正切到新状态/queues |
| `extent_identity_enabled` | **ON（extent）** | 跨 destruction slices 的 queue/cursor 首次真实消费 stable `RecordId` + generation |
| `block_generation_enabled` | **OFF** | block doom/parked 以 bitmap + block link 服务，不保存跨 raw reuse 的 cell handle |
| `audit_oracle_enabled` | tests / ownership-audit only | expected 仍来自最低 raw alloc/free seam，禁止进 production 热成本或与 new iterator 同源 |

依赖要在编译期表达：extent queue 需要 lifecycle + extent identity；block queue 只需要
lifecycle；不得重新用一个 aggregate “all side authority” 开关掩盖组件。v3 正在返工且不在
main，implementer 必须基于 driver 最终接受的 v3 commit 重注册名字/size，不得把 scout
中的预期接口当已合并事实。

### 2.4 4 B/cell 预算与独立 footprint pin

APPROVED generation 预算是 `u32 reuse_sequence` 每 physical cell + `u32
block_incarnation` 每 block，即 **4 B/cell generation**。lifecycle 不得挪用或隐藏在这
4 B 中：

- 本片 block 新增上限：1 个 parked bitplane，
  `ceil(cell_count/64)*8` bytes/block，约 0.125 B/cell；doom 复用现有 bitmap，0 新增。
- header-v2 完整 lifecycle 若后续需要 3 个 bitplanes，终态上限建议冻结为
  0.375 B/cell；超过即重审。slice 2 不预付未消费的 plane。
- extent record 的 `state`、generation、queue link 与 table slack 按 exact bytes/owned
  extent 单独报，不摊薄到 block cell。

独立 footprint pins 必须同时存在：

1. compile-time pin 每个 size class 的 bitmap count/offset、`cells_offset`、cell_count、
   `@sizeOf(Block)==112`（除非本片明确提交并定价 header change）；
2. pin component 组合下 `Superblock` field count/size，证明 generation OFF 时没有
   `u32[cell_count]`，lifecycle ON 时只有预注册 bitplane；
3. pin extent record size/alignment、`RecordId`/queue link size、Registry/table fixed bytes；
4. runtime 报 `owned_cells`、parked bitmap committed bytes、owned extents、record
   committed/capacity bytes，实测必须等于公式加 allocator rounding，不能只给 RSS；
5. binary/symbol/callsite census 证明 only named component production，audit oracle 没进
   release hot path；同一构建分别给 generation、lifecycle、index footprint，不报总差掩盖。

### 2.5 slice 内切换顺序与 rollback

建议一个 slice 内仍保持可 review 的小提交/紧 change：

1. 在 accepted slice1-v3 上补 compact state/queue representation、compile-time pins 和
   audit-only fixtures；尚无 production shadow 写。
2. 同一 change 内接入 no-fail reservation、producer state transition 与真实 reader，打开
   lifecycle；extent queue 同时打开 extent identity。禁止留下“只写不读”的 production
   side table 等待以后收费。
3. 先切 incremental `doomed_by_kind`，再让 full/minor `tmp` 共用；切
   current/zero-ref/deinit hold，最后切 deferred Pass-B。每步跑 old/new/raw parity。
4. compatibility `Header.next` topology 在 audit/safety 构建保留为 shadow，生产真实成本
   必须明确记录是否 dual-write。稳定后 production 不再写被迁借用者；rollback 是按组件
   恢复旧 reader 的可构建 binary，不是运行中改权威。
5. 本片 static allowlist 只允许 `gc_obj_list`/young、共同 helper、allocation init 与
   audit shadow 触碰 `Header.next`。下一片翻转 TraceLive/young 后 allowlist 才归零。

## 3. 预注册验收线草案

### 3.1 anchor 与测量合同

历史数字不能直接成为门。开工前由 driver 登记：

```text
H_S2   = accepted post-S1/S2 anchor
H_PRE  = accepted slice1-v3 与本片直接前驱的实际 commit
H_S2C  = slice2 candidate
config/compiler/layout, binary absolute path + SHA-256
workload/fixed-work hashes, exit/stdout/completed-work contract
component matrix and exact expected footprint formula
```

任一 identity 变化就废弃探针。implementer 目标负载按 verification policy 做 ABBA；安静
same-core cycles/L2D 终裁由 driver 合并批执行。并行 screen 不能代替边界终裁。

### 3.2 correctness/authority 硬线

- old/new/raw 四向检查：old→new、new→old、raw→owned、owned→raw；accounted bytes 与
  raw bytes 分别 exact，不用同一 iterator 跑两遍充作 expected。
- `OwnedAllocation = Constructing + Published + Doomed + FinalizerCurrent + Husk +
  Parked + RollbackPending + RawFreeInProgress`；`TraceLive` 只含 published tracing kinds。
- condemnation 在 callback/body mutation 前进入 doomed；finalizer current、parked、
  husk 在实际 free/debit 前始终 owned accounted。mixed block/non-block pending stats exact。
- every queue member resolves current generation and legal state；every doomed/parked/current
  state belongs to exactly one expected carrier/active handle。cursor 清空与 bucket 清空双向。
- fixed deterministic workload 下 kind destroy order、destructor count、Pass-A-settled count、
  deferred count、weak-husk outcome 与 H_PRE exact；不得以总 heap bytes 相等掩盖顺序漂移。
- static census：被迁移 borrower 的 production direct `Header.next` reader/writer 为 0；
  剩余命中必须逐项在 `gc_obj_list`/young/compatibility allowlist 中。若验收写“所有 borrower
  为 0”，则本片必须扩 scope 并完成 TraceLive/young 翻转，否则直接 NOT-ESTABLISHED。
- implementer：迭代 `zig build check`、定向测试/一次多注入点、收尾一次
  `zig build test`；test262/gate_smoke/arena audit 只在 driver merge batch 跑一次，遵守
  `docs/verification-policy.md`。

### 3.3 必须开火的 mutants

1. **missing doomed / block**：清/漏 block doom state，但 alloc/raw-ledger 仍在；下一
   boundary 必须报 owned/raw 或 accounting mismatch，sweep 不得继续。
2. **missing doomed / extent**：从 published authority 摘除，却跳过
   `state=doomed`/queue；raw ledger 仍命名 storage，必须以与 block 同类 invariant 失败。
3. **queue/state skew**：分别注入 “state doomed 但不 enqueue” 与 “enqueue 但仍
   published”；两个方向都要有独立 checker 开火，不能被 count 偶合盖住。
4. **missing parked**：Pass A 没有 settle、finalizer/struct 尚在，却漏 parked bit/entry；
   raw/active-handle audit 在下一 callback/继续 slice 前失败。
5. **early record removal**：finalizer_current、parked handle 或 raw allocation 尚在时删
   extent/cell owned record；必须在 callback continuation/raw reuse 前失败。
6. **stale resume handle**：保留 `doomed_cursor`/parked RecordId，retire/reuse slot 后继续；
   old generation 必须拒绝，新 generation 可解析，不能 dereference stale body。
7. **shadow deletion**：只从 old 或只从 new 删除 entry，证明 old↔new 两方向各自开火。

前两项是 r2 mandatory “missing doomed ownership”的 block/non-block 双变体；mutant test
必须用 route counter/assertion 证明实际进入目标 carrier 与注入点，不能靠普通 workload
推测覆盖。

### 3.4 footprint 硬线

- block generation：本片增量 `0 B/cell`；若非零即 component leak/FAIL。
- block lifecycle：本片 `<= ceil(cell_count/64)*8 bytes/block`，也即至多 1 bit/cell
  加预注册 padding；doom bitmap不得重复收费。
- extent：record/link/table 的每项 exact formula 在 H_PRE probe 后冻结；实测 capacity/
  committed bytes 不得超过公式 + allocator size-class rounding。禁止只用平均 bytes/对象
  掩盖 table slack。
- maxrss/minflt 是独立 guard；阈值由 H_PRE probe 冻结，不能用 side-byte 公式替代，也
  不能让 EB 改善抵消 splay/PDF 单项失败。

### 3.5 性能硬线建议

现有历史 differential 曾见 destroy/sweep 相对旧 RC 总 cycles 改善 `-5.28pp`；它只
说明该桶是已有赢项、值得保护，不是 r2 可继承价格。建议在新 H_PRE 上重新生成 bucket
后冻结：

- H_S2C destroy/sweep cycles 相对 H_PRE 增量 `<= +0.50 percentage points of H_PRE
  total cycles`；同时该 bucket 自身 ratio `<=1.05`。任一失败即 rollback。这个建议大致
  保留历史赢项的九成，但最终数值须 owner/driver 在候选 timing 前批准。
- implementer target loads：splay 与 EB 的 cycles(user+kernel) **各自** `<=1.003`，
  instructions **各自** `<=1.003`；2×2 独立 cold build，balanced ABBA，even pairs，
  固定核/host lock，保留所有 leg。
- driver batch：六固定负载 cycles(u+k) geomean `<=1.000`，且 splay single item
  `<=1.000`；instructions 为独立 sentinel。任何单独硬失败不能由另一负载的 win 抵消。
- structural counters 必须同时对账：每 condemned allocation 恰好一次 state transition、
  queue push/pop；queue visits/corpse 不高于 H_PRE；EB 不恢复跨 73.6M VarRef 的空 kind
  pass；Pass-A settle eligibility 与 settled count exact 不退。

正确但性能中性也不自动获准合并；按 r2 §9 需要 owner explicit ruling。

## 4. 组合风险与停线条件

### R1 — P1 冷端 owned-accounted 不能随 old bucket 一起消失（HIGH）

current main 的 `HeapAccountingIterator` 显式枚举 live list、non-block Object、block、
`doomed_by_kind` 与 current slots（`gc.zig:3259-3335`），而
`HeapAccountingOracle` 在最低 allocation/free seam 独立维护（`gc.zig:428-473`）。迁移
顺序必须是：新 Owned iterator 先覆盖 doomed/parked/current → old/new/raw exact →
stats reader 才切 → old buckets 最后删。`doomed_pending=true` 时不得跳过 invariant，
不得在只是离开 TraceLive 时 debit。否则会复活 P1 曾修掉的 orphan blind spot。

### R2 — checker-v2 settled terminal 必须随 carrier 原子改写（HIGH）

当前 `DoomedStateSnapshot` 把 bucket、block doom、parked frees、finalizers 与 cursor 合成
pending endpoint（`gc_trace_stw.zig:1410-1470`）；`doomed_pending` 只在完整 drain 后清
（`1648-1679`）。迁移后 endpoint 必须由 state/queues 双向推出，仍满足：

```text
pending == any(doomed, finalizer_current, parked, active cursor/handle)
!pending => all terminal containers empty and no active teardown handle
```

不能只把 `doomed_by_kind.count` 换成一个 side count；mixed block/non-block terminal test
以及“cursor 存在但 bucket 空”的异常都必须保留。

### R3 — S2a 状态机是 archive，不是可 cherry-pick 基础（HIGH）

S2a 报告的 correctness 线虽绿，但性能终裁没有建立/失败：六负载 cycles 未采样，checker
Delta/PDF/Ray 为 `1.8877 / 2.0901 / 1.7695`（PDF 失败），splay C/L
`1.209006` 失败，minflt 也有失败（`/home/aneryu/worktrees/gc-settle/.scratch/
REPORT_S2A.md:162-173`）。main 当前有意用 doom bitmap/list，而非历史五态 block
state machine（`gc_block_heap.zig:200-208`）。本片不得 cherry-pick S2a 的
decommit/refault、pacing 或宽 state enum，也不得引用它的 correctness 绿替代本片 gates。

### R4 — Pass-A settle 与 O3 的“actual raw free”定义（HIGH）

`settleDoomedCellInPassA` 在 Pass A 清 alloc bit/allocated_count，但保留 corpse bytes，
直到全局 Pass A 完成才 rebuild allocator view（`gc_block_heap.zig:775-796`）。为同时保住
stage-3 destroy 赢项和 O3 owned-accounted 语义，实施前必须冻结：**alloc-bit clear +
MemoryAccount debit 是该 cell 的 logical raw-free commit**；此后 cell absent，任何 exact
handle 必须删除；block-level reuse quarantine 仅允许 sibling destructor 读未覆写字节，
不把该 cell 重新加入 OwnedAllocation。若 owner 不接受这个 raw-free 定义，就必须延后
debit/alloc clear 到 Pass B，并重新定价 destroy 回归；不能让 account 与 state 各说一套。

### R5 — remember bitmap 的 phase alias（HIGH）

当前第三 bitmap 在 final mark 后改作 doom bitmap（`gc_block_heap.zig:420-484`）。新
lifecycle API 必须保留“morgue open 时不启动下一轮 collection/remember update”的 phase
排他；不能同时向外宣称同一 bits 是 remembered 与 doomed authority。checker 要在状态
边界验证 alias，而不是只看最终全零。

### R6 — finalizer/reentrancy 与 record stability（HIGH）

`doomed_by_kind`、deferred stack 和 current slots 会跨 callback、plugin finalizer 和
incremental slice。vector/hash rehash 不能让 active cursor 失效；只准 stable record slab
+ generation-checked `RecordId`。队列 capacity 必须在 irreversible condemnation 前保证，
OOM 不能发生在 corpse 已从 TraceLive 摘除后。

### R7 — 顺序/吞吐隐形回归（MEDIUM）

destroy kind order 是语义合同；Pass-B 单对象顺序不是，但 generic prefix/block contiguous
runs 是已优化 routing。把所有 parked entry 混进一个 16 B handle vector 会同时破坏
8 B frontier Option B 的容量收益类比，并在 41M/72M 量级付显著写带宽。本片必须保留
per-carrier compact queue，不能以“cold path”免价。

### R8 — slice 命名与 r2 九步表冲突（MEDIUM / driver decision）

原 reviewer 六步分片的 step 3 只承诺搬 doomed/deferred/tmp；APPROVED r2 九步表第 6 行
又把 standalone vector、TraceLive/Owned iterators 与“no Header.next borrower”并入。
本 scout 推荐拆开：

- Slice 2a（本包）：lifecycle topology + Owned teardown authority；
- Slice 2b/3：extent published/young authority、`gc_obj_list`/young suffix 与
  `NonBlockObjectAuthority` 退出。

若 driver 不拆，必须把 2b 的 allocation-hot cost、young correctness、Shape/Realm
backlink ABI 和 all-borrower static gate 全部加进同一开工包，不能沿用本文仅针对 destroy
路径的 X 与 splay/EB 线。

## 5. 可直接交给 implementer 的开工前 checklist

- [ ] driver 指定 accepted slice1-v3 commit，并记录 H_S2/H_PRE/component matrix。
- [ ] owner/driver 裁决 R4 logical raw-free 定义与 R8 slice 边界。
- [ ] 逐 borrower 建 direct-reader/writer allowlist；确认 `HeaderList` dormant residue也在删表。
- [ ] 冻结 extent record/RecordId/queue link exact layout；证明 no-fail reserve。
- [ ] 冻结 block 仅一个 parked bitplane、generation OFF、doom bitmap复用的 footprint pins。
- [ ] 先写七类 mutant，记录每个 route counter/assertion 与期望 error。
- [ ] 冻结 H_PRE destroy bucket、splay/EB ABBA 和 maxrss/minflt guard 后才写生产消费者。
- [ ] 每个 reader switch 保留独立 raw oracle；任何 parity mismatch 必须在 sweep/callback
  continuation 前硬失败。
- [ ] 实现收尾按 verification policy 跑 targeted + 一次 `zig build test`；本 scout 本身
  不执行实现 gate。

最终判断：**GO 进入实现准备，但有两个前置 stop**——driver 必须明确本片是否包含
`gc_obj_list`/young 翻转，并冻结 Pass-A settle 的 raw-free/accounted 解释。没有这两项，
“no borrower”与 O3 都无法闭合；不得开 production switch。
