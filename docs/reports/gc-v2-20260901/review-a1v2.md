> 注：原始二进制证据在临时 worktree，未入库。

# A1v2 header 设计稿对抗式评审

- 被审对象：`docs/tracing-gc-header-v2-design.md`，
  `gc/obj-prereq-20260831@21478dd0`
- 实现前置：`gc/obj-prereq-20260831@efd04569`
- 系统基线：`main@7c067f01`
- 方式：设计/源码只读审计；未改被审设计或源码，未跑构建/基准，未 commit、未 push
- **Verdict：NEEDS-REVISION + 修订清单**

8B immutable header、按 kind 分 RC carrier、block/extent 双载体，以及先建 side
authority 再做物理切换，这几个方向没有被本评审推翻；但这份稿子还不适合让 owner
冻结。它把五个“待决项”各选了一个方向，却有四项没有给出可执行协议，第五项只给了
迁移顺序而没有给出可审计的切换边界。更严重的是：候选指针规则会在合法 one-past
重叠处漏标，generation 在 record 删除后没有持续 authority，所谓 shadow parity 没有
独立 oracle；定价仍引用今日已漂移的 marking 份额，并与 systemic design 的 `2~4pp`
目标及 S1a 新 frontier 几何冲突。

以下是 owner review 前的阻断项，不是实现阶段再补注释即可解决的细节。

## 一、阻断发现

### BLOCKER 1：candidate validation 的单一解析规则会漏掉合法 one-past 根

设计 §2 要求从 registry/block 找 owner、验证 bounds 和“exact allocation start”，
然后得到一个 trusted kind（`docs/tracing-gc-header-v2-design.md:49-67`）；§5 又写 page/
radix index 把 interior candidate 映射到“the current extent record”
（`:145-159`）。这没有定义保守扫描所必需的**多命中**语义。

反例：相邻分配 A、B 满足 `A.one_past == B.prefix/start == p`。native word `p`
既是 A 的合法 one-past 指针，也是 B 的 prefix/start 命中。若按单一 greatest-start
或“current extent”返回 B，A 不会被 shade，随后可被 sweep，形成 UAF；返回 A 则又可能
漏掉真正指向 B 的值。当前实现为此把 API 明确拆成两类：

- `resolveAny` 只能返回一个 winner，选 greatest `lo`；
- 保守扫描调用 `forEachGcObjectAt`，同时探测 `addr`/`addr-1` 并访问所有包含该地址的
  allocation；注释明确说明 false retention 是安全方向，漏掉一侧是 UAF
  （`src/core/gc_address_registry.zig:709-759,762-801`）；
- standalone interior fixture 也明确要求任意 body interior 能恢复对象
  （`src/tests/core.zig:3060-3108`）。

“exact allocation start”若意为“从 candidate 推导并验证 exact start”，需要这样写；
若意为 candidate 自身必须等于 start，则与 interior/one-past 合同直接矛盾。修订必须
冻结至少三套 API/语义：

1. exact typed handle：唯一 start，必须验证 identity/generation；
2. conservative raw word：零解引用地 `visitAllCandidates(addr)`，允许 0/1/2 个合法
   命中，覆盖 prefix、body interior、one-past 和跨页 `addr-1`；
3. diagnostic single-winner lookup：只可用于不承担 root soundness 的调用点。

另一个未闭合点是 block 的 trusted kind。当前 block heap 生产路径只有 `.object`，所以
kind 可由 subspace 隐含（`/home/aneryu/worktrees/gc-settle/.scratch/ALLOC_FORENSICS.md:405-407`）；设计列出的 block metadata
只有 size class/bitmap/epoch/generation，没有 kind（设计 `:137-143`），却又允许六个
tracing kind 共用 side state。必须冻结“block 永远 Object-only”或“block/subspace
kind-homogeneous 且 kind 是 metadata 字段”；不能在验证 header 前从 header 反取 kind。

### BLOCKER 2：`(base,generation)` 没有 generation authority，不能证明 ABA-safe

设计说 generation 在 base retired 时递增，queue/weak/diagnostic handle 检查它；随后
又删除 address entry 和 side record，再 raw-free（设计 `:145-175`）。这里少了决定性
的一步：**record 删除后，下一次同地址分配从哪里取得严格更新的 generation？**

若新 extent record 默认从零/一开始，旧 `(base, generation)` 在 allocator 重用地址后
会再次有效。设计也未冻结：

- generation 是 per-base tombstone、allocator slot counter，还是全局 monotonic id；
- 位宽、wrap/exhaustion 规则及 runtime teardown 后的 identity 边界；
- block 被释放/重建、cell index 重用时 per-cell generation 存在哪里、何时递增；
- 哪些 handle 真会跨 reuse window，哪些只活在禁止 sweep/reuse 的 collection epoch。

至少应选择并写死一种持久 authority。例如全局 `u64 allocation_id` 可避免永久保留
per-address tombstone，但需要定义不 wrap；若坚持 per-base generation，就必须给 tombstone
的持有者、回收规则和内存上界。block cell generation 同样需要 side-array/packed field
的明确字节成本，不能只写“block metadata owns it”。

还要避免过度承诺：裸 conservative word 不携带 generation。旧裸地址在 reuse 后可能
保守地留住新 occupant，这是 conservative GC 允许的 false retention；generation 只能
保护携带 identity 的 queue/weak/diagnostic handle，不能把 raw scan 描述成 ABA-free。

### BLOCKER 3：side record 的生命周期没有形成“全部存储 authority”

设计的 `constructing -> published -> doomed -> removed -> raw-free` 顺序方向正确
（设计 `:161-179`），但又规定“only published entries participate in exact/
conservative enumeration”。这里把两个不同集合混在一个“enumeration”词里：

- **trace-live population**：published 且可被新 root shade；
- **owned-allocation population**：raw storage 尚未释放，包括 constructing、published、
  doomed、weak husk、parked/deferred corpse、当前 finalizer callback 和 rollback。

当前 `efd04569` vector 只覆盖 live non-block Object，设计自己也承认 doomed list、
`tmp_obj_list` 和 deferred-free stack 仍借 `Header.next`
（设计 `:190-221`；`src/core/gc.zig:1513-1548,1551-1591`）。condemnation 后，block
corpse 仍由 bitmap 可见，而 non-block corpse 被从 live vector 摘除并进入按 kind 的
doomed carrier；两者已在今日 P1 审计中表现出不同统计/审计可见性
（`.scratch/REVIEW_P1.md:62-93`）。

终态 extent record 可以同时解决这件事，但稿子没有明确：record 在 `doomed` 状态仍由
哪个**总 authority**枚举；weak husk 恢复 published 时 identity 是否不变；current
callback 与 pass-B deferred free 如何引用它；orphan record/header 怎样被查出；runtime
teardown 和 construction rollback 是否走同一审计。必须提供两个显式 iterator 及状态
矩阵，且规定：

```text
raw allocated == constructing + published + doomed/parked/current + rollback-pending
trace-live     == published and shadeable
raw free       only after every side handle and address membership is retired
```

没有这张等式，standalone authority 只是把 live vector 换成 live record，不是闭合的
ownership authority。

### HIGH：shadow parity 没有独立来源，会重演 P1 的同源自比较

迁移 §7 只写“dual-read/shadow checks must prove allocation, kind, mark, generation,
address lookup, and teardown parity”（设计 `:223-243`），没有说明每个事实的 old
authority、new authority 和第三方 oracle。今日 P1 已用 mutant 证明：两个 iterator
实例只要来自同一 population authority，漏挂一个仍已分配对象时两侧会一起消失，audit
仍报绿（`.scratch/REVIEW_P1.md:17-60`）。

这对 A1v2 更危险：若 publication call site 同时漏写旧 list/vector 与新 extent record，
“old vs new”也会一起漏。owner 批准前应补一张 parity 表，至少包含：

| fact | old authority | new authority | 独立审计 / 必须注入的 mutant |
|---|---|---|---|
| raw allocation/bytes | allocator/MemoryAccount allocation ledger | block/extent records | orphan allocated storage，双向查缺/查多 |
| published membership | list + block bitmap + Object vector | carrier live state | 漏一次 publish/unpublish；旧新任一侧缺失均 fail |
| kind/extent | allocator route + size/class facts | descriptor kind/bounds | wrong kind、truncated/overlong extent、邻接 overlap |
| mark/young/remembered | 当前 header/bitmap | side state | 单边 bit flip，双向比较 |
| identity | 当前 allocation address/lifetime window | generation handle | retire/reuse 后投递 stale queue/weak handle |
| teardown | doomed/deferred/current carriers + raw allocator | record state machine | 漏挂 doomed、double retire、先删 record 后 callback |

此外，迁移期 checker 必须分别检查 `old -> new` 和 `new -> old`，物理切换后保留一个不以
extent record 自身为 expected population 的 permanent audit。否则 compatibility reader
一删，shadow 也跟着失去发现 orphan 的能力。

## 二、五个未冻结项逐项结论

| 未冻结项 | 设计所选方向 | 对抗结论 | owner 前必须补齐 |
|---|---|---|---|
| BigInt RC carrier | payload-4 独立 i32 prefix | **未闭合。** 方向可行，但只冻结了热 RC 地址，没有冻结物理 allocation/free ABI。当前 `BigInt` 仍以 `gc.Header` 为 body offset 0、size 48/align 8，普通及 FAM 都走通用 GC allocation，zero-ref 慢路把 payload cast 成 `gc.Header` 后分派（`src/core/bigint.zig:40-80,137-206,366-375`；`src/core/value.zig:683-704`）。 | 明确旧 body header 删除还是替换；8-byte aligned payload 前的 4B RC 与 padding/raw base；ordinary/FAM 总字节和尾部 offset；descriptor 预留/发布；zero-ref destroy/free route；OOM rollback；candidate 是否忽略 RC-only BigInt。注意“4B RC”不自动等于只付 4B allocation prefix。 |
| Shape/Realm body RC | body count 成为稳定 ABI | **部分闭合。** Shape 的 `rc==1` uniqueness 合同清楚；Realm 仅说“host/destroy authority”不够。当前 host create-ref 通过 root provider shade Realm，`RealmRef` count 与 traced heap edge 配对，context list 明确不是 root（`src/core/context.zig:906-934,971-1074,1427-1459`；`src/core/gc_trace_stw.zig:1961-1968`）。“count 不是 liveness”不能省略这座桥。 | 分别写出 retain/release、trace edge/root-provider、zero transition 与 collector reclaim 的状态机；冻结 v2 header/body offset；说明 Shape/Realm 是否可进入 block，若否则一律 extent；count/tag mismatch 和 finalizing access 的失败规则。 |
| non-block side key/lifetime | `(base,generation)` extent record | **未闭合，见 BLOCKER 2/3。** 键形式合理，generation 的持久来源、wrap、handle census、全状态 owner 都缺。 | persistent generation authority；完整 handle 清册；live/owned 双集合；address-index rebuild 失败时的 exact fallback；weak/finalizer/pass-B/raw-free 顺序和 checker。 |
| standalone authority | `efd04569` vector 过渡到 extent records | **桥接现状描述准确，终态未闭合。** vector 只证明 published standalone Object 不依赖 live list，不证明 doomed/rollback/other kinds/allocator orphan 的完备 authority。 | 把 transition bridge 的退出条件写成可检验的双向 population 等式；所有非块 kind、所有非-live-but-owned 状态纳入；保留独立 audit。 |
| A1 + obj64④ 顺序 | side parity 后同一次物理 cut | **方向合理，工程边界未闭合。** 避免对 Object 做两次最终 layout rewrite 是对的，但“atomically update allocator geometry、validation、offset、metadata、snapshot”把太多语义放入一个不可归因、难 bisect 的大提交。 | 区分兼容布局下的 carrier/API、per-kind state migration、临时 topology 搬迁和最终 layout switch；前几步可逐提交验证，最后只做一个小的 no-mixed-layout switch。定义 rollback 构建/开关、每步 snapshot 状态及旧 reader 删除点。 |

所以“五项已 resolved”（设计 `:43-47`）目前是不成立的。准确状态应是：五项给出了
**preferred direction**；BigInt、Realm、generation/lifetime、total authority 与 cut
transaction 仍待协议化。

## 三、今日新证据推翻了现有定价闭合

### 1. `1.79% marking-only upper bound` 已不是同一当前事实

设计继续引用 `6.3857% * 70% * 40% = 1.79%`，并据此支持
`-0.3%~-1.5%`（设计 `:249-261`）。但今日同一 `main@7c067f01` 对 frozen RC 的差分
重新得到：trace/rc cycles `1.203755`，trace marking 占 trace 总 cycles **11.00%**，
marking 净差 **+7.64pp**；另有 kernel/minflt **+9.04pp**、alloc front **+3.21pp**
（`/home/aneryu/worktrees/gc-blackalloc/.scratch/DIFFERENTIAL_REPORT.md:7-33,109-137`）。systemic design 也已经据此把 P-A2 的桌面
回收写成 **2~4pp**（`main:docs/gc-v2-systemic-design.md:14-26`）。

这不是说 A1v2 可以把 7.64pp 全拿走，也不能把 flat-profile 11% 与旧窄 timer 直接相减；
恰恰相反，它证明旧 `6.3857%` 已不能继续充当“当前上限”而不做口径 reconciliation。
机械套同一 70%/40% 到 11% 会得到约 **3.08% of trace cycles**，已经接近旧上限两倍，
但这仍只是敏感性算术，不是新承诺。设计必须解释两种 marking 定义各覆盖什么，并在
同一 post-S1/S2 binary 上重采后再给区间。

同时，header/obj64 可能影响 allocation locality、committed footprint 和 minor faults；
因此 marking-only cap 最多是一个分桶判别器，不能作为**整个 representation candidate**
的收益上限。反过来，`-16B -> -1.52%` 来自跨 size class 的旧试验，而单独 `-8B`
不跨 class，仍只能当方向性斜率，不能与新 marking 数相互“证明一致”。

### 2. S3 基线和判别器必须后移到真实组合点

systemic design 把 S2 定义成依赖 S1 的新货币基线，再在 S3 合入 A2/P-C
（`main:docs/gc-v2-systemic-design.md:46-58`）。header 稿却只要求 candidate 对
“immediate predecessor”，同时继续钉旧的 `20.18M -> 12.14M` marking structural
lines 和 L1D `-9.2%`（设计 `:263-294`），没有要求 predecessor 必须是 owner 接受的
S1+S2 composition。

今日 S1a 的事实是：它因 earley-boyer instructions `1.003013249 > 1.003` 而 NO-GO，
但移除了 overflow whole-heap rescan，splay cycles 改善 `4.36%~6.16%`，并按 owner
原则保留到 S4 组合重测（`/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S1A.md:8-35,94-138`）。因此：

- 如果最终 S1 不含该机制，A1v2 不能把旧 “frontier 将落地” 当已兑现前提；
- 如果它以组合形式复活，mark visit 次数、顺序、rescan 路径和 cache footprint 已改变，
  旧 `20.18M/12.14M` 绝对数不再是稳定判别器；
- S2 又会改变 block 生命周期、committed/live 与 minflt，旧 L1D/refill 端点同样不能
  跨基线沿用。

应保留“结构线/refill 必须按预测方向移动”的机制门，但绝对端点必须在最终被接受的
post-S1/S2 anchor 上重新预注册。性能 verdict 至少分开报告：

1. A1v2 相对 immediate predecessor 的增量；
2. S3 组合相对 post-S2 anchor 的总变化；
3. 六负载 `cycles(u+k)` geomean/splay 单项与 instructions guard；
4. committed/live、minflt 和 marking/refill structural counters；
5. 同源码、同配置、同工作量、同二进制 identity。

现稿只写 splay/earley instructions 和 splay quiet cycles，低于 systemic design 已冻结的
六负载 `cycles(u+k) + committed/minflt + instructions` 货币。

## 四、与 frontier v2 / P1 的未声明合成依赖

### frontier v2：generation 要么让 entry 翻倍，要么需要明确 epoch 豁免

S1a 的 4 KiB segment 是 24B header + **509 个 `*gc.Header`**；所有 private/shared
push/pop、donation/steal 都以裸 8B header pointer 为 entry
（`gc/frontier-v2-20260831:src/core/gc_mark_queue.zig:20-38,193-304,319-473`；
`/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S1A.md:28-35`）。A1v2 又要求“cached or queued cell reference must carry or
validate reuse generation”（设计 `:137-143`），并要求 non-block queued work 检查
generation（`:145-159`）。两者不能同时不付价：

- 若 mark frontier entry 变成 16B identity handle，4 KiB capacity 从 509 降到约 254；
  同样峰值 item 数下 splay 的 429 段/1.76 MiB 会接近翻倍，donation/steal/admission
  几何也全部失效，现有 S1a 性能证据不能继承；
- 若 frontier 继续存裸 pointer，设计必须冻结其安全证明：marking cycle 活跃期间禁止
  sweep/raw-free/reuse，queue 全部 drain/abort 后才允许 retirement，故 mark frontier
  是 generation-check 规则的显式 epoch-local 例外。当前 S1a 源码正是依靠“collector
  不在自己的 mutator windows 内 free”而省掉 pop validation。

这是实现形状和定价都会改变的 owner 决策，不能留给 coder 临场解释。

### P1：extent record 不能同时当统计事实和审计 expected

`gc/p1-oldspace-20260831@b340faf3` 已因同源 accounting audit 被本评审 REJECT；因此
systemic design 的 “S1 = frontier + P1” 当前没有可继承的已验收 accounting 口径。
A1v2 若让 extent records 派生 heap bytes/stats，可以成立；但 audit expected 必须来自
独立 raw allocation/ownership oracle，不能再从相同 record iterator 求一次 expected、
再求一次 actual。并且 pending stats 必须统一 block/non-block doomed 口径。设计 §7
现在完全没有声明这项组合约束。

## 五、工程分期判断

“A1 与 obj64④ 共享最终 physical cut”可以保留，但不应等价于一个大语义提交。安全
分片应是：

1. 当前布局下定义 carrier/identity API，并为每个事实建立 old/new/independent 三角
   checker；
2. 引入持久 generation authority 和 extent state machine，先迁 non-block kind；
3. 搬走 doomed/deferred/tmp topology，并通过 live/owned 两套 population mutant；
4. 冻结 BigInt/Shape/Realm ABI，完成 allocator/free/candidate route；
5. 在双表示构建中逐 kind shadow，再做一个小的 global layout switch，保证任一 binary
   内没有 mixed public ABI；
6. 只有独立 parity、rollback binary 和新基线性能合同全绿，才删旧 reader/field。

这仍然只做一次最终 Object layout rewrite，满足设计原意；同时让回归可 bisect、性能账
可归因、切换可回滚。现稿的 step 5 一次更新 allocator geometry、candidate validation、
body recovery、metadata 和 snapshot，风险没有被“atomic”一词消除。

## 六、必须完成的修订清单

1. 重写 candidate validation 为 exact / conservative-all-hits / diagnostic 三套协议，
   加入邻接 `A.one-past == B.start`、跨页、interior、wrong-kind、unpublished/doomed
   反例；冻结 block trusted-kind authority。
2. 定义 generation 的持久 owner、位宽/wrap、block/cell reuse、runtime teardown 规则，
   并列出所有跨 reuse handle；明确 raw conservative word 与 epoch-local frontier 的例外。
3. 把 extent lifecycle 改成 trace-live 与 owned-allocation 两套显式 population/state matrix，
   覆盖 constructing、published、doomed、weak husk、parked/deferred/current、rollback、
   raw-free。
4. 增加 old/new/independent parity 表、双向 checker 和至少 orphan publish、wrong extent/
   kind、stale generation、漏 doomed、early record removal 五类 mutant；旧字段删除后保留
   permanent independent ownership audit。
5. 给 BigInt 写完整物理 ABI；给 Shape/Realm 写 count-to-root/edge/reclaim 状态机；逐 kind
   明确 block vs extent、allocation/free、candidate 和 FAM/offset 规则。
6. 明确 frontier entry 是否携 generation；若携带，重做 segment geometry/峰值/门禁；
   若不携带，冻结 no-reuse epoch proof。
7. 承认 P1 当前 REJECT，不把其 derived census 当新 authority；统一 pending block/
   non-block stats 口径。
8. 删除或标记失效的 `1.79% current upper bound` 与旧绝对 line/refill 端点；在 owner
   接受的 post-S1/S2 anchor 上重新预注册 incremental + combined 两层价格，使用 systemic
   design 的六负载 `cycles(u+k) + committed/minflt + instructions` 货币。
9. 将“combined physical cut”拆成可验证的语义 staging + 小 switch commit，写清每步
   snapshot、rollback 和 compatibility reader 删除条件。

以上第 1~9 项完成前，不建议 owner 批准 §10 的六个 checklist 项；可以批准的只有
“继续沿 8B/side-carrier 方向完善设计”，不能批准具体 ABI 或开工 physical cut。

## 七、给 owner 读稿时最该盯的三个点

1. **候选指针是否真的 sound：** 让作者现场走完
   `A.one-past == B.start`，并说明为什么一次 scan 会同时 shade A/B；再问 generation
   到底保护哪些 handle、由谁跨 record deletion 持有。
2. **谁审计 authority 自己：** 要求画出 raw allocated、trace-live、doomed/current/
   deferred、raw-free 的集合等式，并指出一个不从 extent record/list/vector 派生的
   orphan oracle。答“再跑一个 iterator”不算独立。
3. **价格属于哪棵树：** 要求把 `1.79%`、systemic `2~4pp`、今日 marking `+7.64pp`
   和 S1a 的 509-pointer frontier 放到同一个 post-S1/S2 baseline 上；在这之前，
   `-0.3%~-1.5%` 与 `20.18M -> 12.14M` 都只能是已漂移历史假设，不能作为 S3 gate。

## 验证记录

- 已读 brief、目标设计、HEADER_SURVEY、main systemic design、ALLOC_FORENSICS、今日
  DIFFERENTIAL_REPORT、S1a report、P1 对抗评审，以及相关当前源码/fixtures。
- 复核了当前 conservative multi-hit、standalone interior/replay、BigInt/FAM、Realm
  root-provider/RealmRef、non-block live vector、doomed/deferred carrier 与 S1a 4 KiB
  frontier 实现。
- 本任务是零实现设计评审；按 brief 未运行构建、测试或性能测量。
