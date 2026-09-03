> 注：原始二进制证据在临时 worktree，未入库。

# S1a frontier 交叉评审：`gc/frontier-v2-20260831@7df5bbd6`

日期：2026-08-31

角色：交叉 reviewer（对抗式、零实现）

被审对象：`7df5bbd6 gc: replace bounded mark queues with segmented frontier`

实现报告：`/home/aneryu/worktrees/gc-blackalloc/.scratch/REPORT_S1A.md`

## Verdict

**REJECT。**

本裁决独立于 implementer 已记录的 instructions NO-GO。分段 frontier 的所有权转移、OOM 后“不 sweep”、以及 `smp_allocator` 的独立账户方向基本成立；但并行 slice 的退出握手没有证明“本代所有 helper 都已报到并离开”。owner 只等待瞬时 `active == 0`，可以漏过刚收到 `job_gen`、尚未执行 `active.fetchAdd` 的 helper。这个 helper 随后可能在 owner 已进入 final remark、甚至 mutator window 后执行 drain，直接击穿本提交给无锁 `pushSingle` 写下的“不与 helper 重叠”前提。

OOM 攻击没有形成第二个 S1a blocker：frontier 失败后的 `.collection_failed` 请求会转入同步 full collector，而该 collector 使用 `page_allocator` arena，不再使用 segmented frontier，故“8 个 cached segment 反复走到第 9 个失败”的闭环不成立。仅在 page-backed full collector 也持续 OOM 时，普通对象分配边界才会反复吞错并重试；那是既有的全局 OOM 调度风险，不是本提交独有的 invalidation 活锁。

## 发现清单（按严重度）

### Critical — slice 退出可漏过尚未报到的 helper，STW/quiescence 声明不成立

证据：

- worker 看到新 `job_gen` 后，直到 `active.fetchAdd` 才被 owner 计入：`src/core/gc_parallel_mark.zig:174-185`。
- owner 发布 generation 后立即参加 tracing，没有等待每个 helper 对该 generation 的 arrival/ack：`src/core/gc_parallel_mark.zig:340-381`。
- 退出只做 `stop = true`，然后等待瞬时 `active == 0`：`src/core/gc_parallel_mark.zig:384-399`。
- helper 对 `stop` 用 monotonic load：`src/core/gc_parallel_mark.zig:216-223`。
- 新 `pushSingle` 明确依赖“mutator windows/serial slices 不与 helper 重叠”，且直接无锁改 `newest`、segment `len` 和 `item_count`：`src/core/gc_mark_queue.zig:383-406`；并行 steal/donate 则在 mutex 下改同一链：`src/core/gc_mark_queue.zig:449-475`。

允许的时序：

1. owner 写 `stop=false`、推进 `job_gen` 并 broadcast；helper H 醒来/观察到新 generation，但在 `active.fetchAdd` 前被抢占；
2. owner 独自耗尽当前工作或用完预算，写 `stop=true`；此时 `active` 仍为 0，所以 wait 立即结束，`parallelMarkStep` 返回；
3. H 恢复，先 `active++`，再进入 `drainAsWorker`。owner 已经错过这次 0→1；且 H 的 monotonic `stop` load 没有 arrival handshake 保证必须观察到本次 `true`；
4. 若 budget stop 时 shared chain 尚有一段，H 可在 owner 已错过 active wait、但尚未执行最终 `queue.isEmpty()` 前把该段 steal 到自己的 private stack。owner 随后看到“owner stack empty + shared empty”而误报 frontier empty，紧接着进入 `finishIncrementalCycle` 的 final remark/weak/condemn（`src/core/runtime.zig:3279-3295`、`src/core/gc_trace_stw.zig:1193-1229`），H 却仍持有并 trace 那段不可见工作。若 owner 的最终检查先看到 non-empty 而返回未完成，poll 返回后 H 则可与 mutator 及其无锁 `pushSingle` 交错。

即使 H 恰好看到 `stop=true` 而不 trace，也只能说明该次调度幸运，不能使 owner 的“all helpers quiescent”证明成立。`active` 是在 wake 之后由 worker 自报的瞬时 occupancy，不是 owner 在发布 generation 前建立的待完成计数。

旧基线在 `7c067f01:src/core/gc_parallel_mark.zig:181-183,342-350,385-386` 有同样的 arrival 缺口，因此这不是 segmented chain 新造的逻辑；但 S1a 不能据此宣称新协议等价即安全，而且新实现把 queue 的 mutator append 从 MPMC 变成依赖 quiescence 的无锁写，使继承缺口获得了直接的数据竞争/链损坏后果。

阻塞修复边界：每个 generation 必须有 owner 预先建立的 expected/completed 或 arrival/ack 协议；owner 在返回前等待所有 `pool.count` helper 对该 generation 完成一次 ack，而不是等待瞬时 active 变为 0。需要确定性测试把 helper 卡在“已见 generation、尚未 arrival”以及“arrival 后、读取 stop 前”两个点，证明 owner 不会提前返回。

### Medium（继承风险）— 双 allocator 都持续 OOM 时，分配边界会反复重试 full GC

证据：

- segment acquire 失败只 latch `out_of_memory`，地址不入队：`src/core/gc_mark_queue.zig:88-130,375-425`；marker boundary 将 latch 映射成 error：`src/core/gc_trace_stw.zig:40-45,1121-1175`。
- incremental caller 正确 abort、记失败并重挂 `.collection_failed/.soon`：`src/core/runtime.zig:3233-3255,3285-3295`。
- abort 清空 private/shared frontier，不 sweep，并把 retirement 置为 abandoned：`src/core/gc.zig:3775-3794`；`needs_major` 明确关闭 minors：`src/core/gc_generation.zig:125-135,325-336`。
- `.collection_failed` 不是 self-paced threshold 请求，因此下一次 poll 走同步 full STW：`src/core/runtime.zig:3168-3193`。
- 该同步路径是 `collectCycles` → `Collector.run`；`shade_to_queue` 保持默认 false，worklist 是 `page_allocator` backing 的 arena，而不是 segmented queue：`src/core/gc_trace_stw.zig:709-743,1683-1705,1883-1943`。因此一次 `smp_allocator` segment failure 会切到另一条可回收路径，不会再次卡在同一个 segment-cache 水位。
- 只有同步 trace 自己也 OOM 时才仍重挂 `.collection_failed`：`src/core/runtime.zig:3006-3015`。
- 普通对象分配入口把 `pollGC` 的错误无条件吞掉：`src/core/runtime.zig:3755-3760`；cycle 已关闭时 pending request 不受 assist-debt 节流，每次边界立即 poll：`src/core/runtime.zig:3784-3795`。

因此 brief 中最危险的思想实验——“第一次 frontier OOM 后，reset 留 8 段；下一轮仍在第 9 段失败；永远不 sweep”——被调用图否证。下一轮不是 segmented incremental trace，而是 page-backed synchronous trace；它成功时会完成 major、重新开放 minors 并回收。

残余风险是：若 system pressure 同时让 page-backed synchronous worklist OOM，而对象仍可从已经 committed 的 slab/block 容量发布，分配边界会吞掉 full-GC error、保留 failure request，并在下一边界立即再做一次失败 full trace；minor 此时也因 `needs_major` 关闭。这个循环真实存在，但 baseline 的 synchronous collector OOM 已走同一个 `runtime.zig:3006-3015,3755-3760` 调度，S1a 没有新造它。显式 host/safepoint API 会把 error 返回给调用者，所以也不是所有入口吞错。

现有测试只对独立 `Queue` 注入 0-byte allocator 并检查 latch（`src/tests/core.zig:16506-16518`），没有跑 runtime abort→request→synchronous recovery。建议补 runtime 级 fault seam，至少证明一次 segment OOM 后 full fallback 实际完成、retirement 回到 clean；全局双 OOM 的 backoff/terminal propagation 可作为独立 scheduler debt，不据此扩大本提交的 REJECT 理由。

### Low — 源码删除完整，但 active GC 设计/验证合同仍宣称 overflow-rescan

生产源码中 `hasOverflowed`、`clearOverflow`、旧 capacity、marked-object recovery walk 和 CLI overflow 项均已删除；`drainBarrierQueue` 现在只 steal segment 并在 failure latch 上返回：`src/core/gc_trace_stw.zig:2061-2077`。`publishGreyCold` 仍正确通过 `pushSingle` 入 frontier，失败由 queue latch 使周期失效：`src/core/gc.zig:4469-4492`。

但 active 文档仍把已删除机制写成当前合同：

- `docs/tracing-gc-design.md:1055-1062`：ring full → `mark_overflow` → intrusive overflow registry/rescan；
- `docs/tracing-gc-design.md:2120-2148`：bounded queue、one-past-capacity、wraparound 仍列为已落地 gate；
- `docs/tracing-gc-design.md:2238-2245`：validation matrix 仍要求 ring overflow/allocator overflow；
- `docs/tracing-gc-pause-plan.md:463-482,817-830`：persistent 65536 ring 与 overflow remark 仍作为现行叙述。

这不是隐藏的 runtime consumer，却会让后续 review/test 依照不存在的安全网。尤其 blackalloc 的 `.scratch/REPORT2.md` 把“splay mark-queue overflow 不升”作为一条验收线；S1a 后该指标不再可观测，S4 组合不能把“面板没有 overflow 行”等同于通过，必须预注册新的 frontier pressure/failure 指标。

## 六个攻击面的逐项结论

### 1. 并行终止协议

**局部 frontier exhaustion 逻辑可证明，generation quiescence 不可证明。**

对 brief 指定的时序：helper A pop 空并把 busy 减一；helper B 若还持有 private segment，它仍计在 busy 中，因此 owner 不能在 shared empty 时以 busy==0 终止。B 普通 donation 在 busy 身份仍有效时、于 queue mutex 内完成（`src/core/gc_parallel_mark.zig:213-244`、`src/core/gc_mark_queue.zig:449-457`）。budget/stop 路径确实先 busy--、后 donation，但 worker 直到 donation 完成后才 `active--`（`src/core/gc_parallel_mark.zig:241-245,183-185`），若所有 helper 已经报到，owner 的 active wait 足以保住 frontier。

shared-chain empty 比旧 ring 的两个 atomic position snapshot 更容易审计：它在 queue mutex 内读取精确 `item_count`（`src/core/gc_mark_queue.zig:348-355`）。因此 `busy + shared-empty` 对“已经进入 drain 的 tracer”不弱于旧协议。失败在协议外沿：`active` 没有覆盖迟到 arrival，见 Critical finding。

### 2. donation / steal 与互斥成本

**语义通过，未发现地址丢失；热 top 保留落实。**

- private stack 从 `bottom` 取最老 segment；普通 donation 以 `allow_last=false` 拒绝交出唯一/热 top：`src/core/gc_mark_queue.zig:263-275`。
- `donateHalf` 只搬 `segment_count/2` 个最老整段：`src/core/gc_parallel_mark.zig:62-73`；owner 首次 feed 同样不拿最后一段：`src/core/gc_parallel_mark.zig:333-338`。
- thief 把 shared oldest 整段 adopt 为自己的 top 并继续 LIFO：`src/core/gc_mark_queue.zig:277-285,460-475`。这是“旧宽子树交给别的 lane、当前热路径留本 lane”，保留了旧“捐老一半”的 DFS 局部性，粒度从 pointer range 变成 segment。
- mutator barrier/publication 的单项 `pushSingle` 不取 shared-chain mutex；普通情况下只是 segment 尾部三次标量更新，每 509 项才进 pool acquire：`src/core/gc_mark_queue.zig:383-406`。parallel `push`、donate、steal 才取 queue mutex：`src/core/gc_mark_queue.zig:409-475`。serial collector 从 shared chain 每段 steal 一次，段内都在 private stack 上 pop：`src/core/gc_trace_stw.zig:48-56`。所以不存在“marking 期每个 mutator barrier 都碰 queue mutex”的成本。

上述无锁结论以 helper quiescence 为前提；Critical finding 正是该前提当前没有 handshake 证明。

### 3. OOM invalidation 状态机

**安全性通过；frontier-specific 活锁假设被否证，保留一个继承的全局 OOM 风险。**

所有生产 marker boundary 都检查 failure：begin seeding、serial/parallel increment、final barrier drain 会传播 `OutOfMemory`/`PayloadMarkFailed`（`src/core/gc_trace_stw.zig:40-45,1080-1084,1121-1175,2064-2077`）；同步 `collectCycles` 的 error 在 sweep 前上抛（`src/core/gc_trace_stw.zig:709-743`）。runtime 的 incremental begin/step/finish 和 synchronous major 均有 abort/record/request 处理（`src/core/runtime.zig:3006-3015,3197-3206,3233-3255,3285-3295`）。测试专用 `collectConcurrentMajor` 也有 frontier/marking errdefer（`src/core/gc_trace_stw.zig:907-957`）。没有找到 failure 后进入 sweep 的调用者。

abort 留下的 mark 不授权 sweep；下一次 full collection 以 epoch advance 重新定义 marks（`src/core/gc_trace_stw.zig:1840-1847`）。young 半退役通过 `needs_major` 关 minor，直到成功 major commit。因此 memory safety 方向是保守的。关键反证是 recovery full collector 的 worklist 来自 `page_allocator` arena、`shade_to_queue=false`（`src/core/gc_trace_stw.zig:1683-1705,1883-1943`），不会重走失败的 segment acquire；一次仅限 smp frontier 的 OOM 有实际回收出口。只有 page-backed full trace 也持续失败时才落入 Medium finding 的既有 allocation-boundary 重试循环。

### 4. STW 内 `smp_allocator` 与 8 段 cache

**未发现 reentrancy/lock-order blocker。**

- frontier backing 明确复用独立于 JS `MemoryAccount` 的 registry allocator，最终是 `std.heap.smp_allocator`：`src/core/gc.zig:4269-4287`。因此 segment allocation 不会走 `collectBeforeObjectAllocation`，没有 GC 自递归。
- 仓内已有同类先例：trace runtime 的 slab arena backing 也是 `std.heap.smp_allocator`（`src/core/memory.zig:1599-1605`）；同步 STW collector 本来就用 `page_allocator` backing 的 arena 并传播 OOM（`src/core/gc_trace_stw.zig:1698-1705`）。所以“STW 内绝不碰 allocator”不是现有合同。
- `SegmentPool` 在调用 backing `create/destroy` 前释放自身 pthread mutex，queue 路径也不持 queue mutex跨 allocator 调用：`src/core/gc_mark_queue.zig:88-149,409-446,499-518`。没有 pool→smp→GC 或 queue→pool→queue 的锁环。
- Zig 0.16 的 `$ZIG_LIB_DIR/std/heap/SmpAllocator.zig:1-24,58-97` 明确是多线程 singleton，并以 per-thread mutex/跨槽轮转保护；这里没有发现从其内部回调 runtime 的路径。它不是可任意递归调用的 allocator，但当前 GC 入口都发生在先前 allocator call 已返回之后。
- cache 是 per-runtime、非 thread-local；head/stats 全由 pool mutex 保护，helper/owner 可跨线程归还。上限 8 段即 32 KiB（`src/core/gc_mark_queue.zig:20-21,73-80,133-149`）。teardown 先 join helper 再 `gc.deinit`/pool deinit（`src/core/runtime.zig:1740-1745`、`src/core/gc.zig:2251-2252`），没有线程归属悬空。

风险仅是 STW 内一次新的 slab map 可能拉长 pause，以及全进程 singleton 的跨 runtime 争用；这是延迟/资源包络问题，不是本次读码能成立的重入死锁。

### 5. overflow 删除面与 blackalloc 依赖

**active source/CLI 删除完整；设计合同与跨 lane 验收账未完成迁移。**

代码搜索未发现 GC 侧 `hasOverflowed`/`clearOverflow`/旧 queue capacity 消费者。CLI 已改报 active/cached/peak-owned/allocation-failures（`src/cli/zjs.zig:899-910`），不再伪装 overflow-rescan。`GcObjectIterator` 仍被 sweep、census、audit 等合法阶段使用；`drainBarrierQueue` 已不再用它做 overflow recovery。

悬空的是文档和 S4 组合验收定义，见 Low finding。另有一处低风险文字漂移：`gc_marker.Worker` 仍称自己“never allocates”（`src/core/gc_marker.zig:1-7`），而新 `queue.pop()` 在弹空段时可能经 pool cache 满分支调用 backing `destroy`（`src/core/gc_mark_queue.zig:499-518,133-149`）；它没有生产 caller，但该约束文字应与新资源行为对齐。

### 6. 与 P1 `gc/p1-oldspace-20260831@b340faf3` 合成

**无文本冲突，冷 census 语义与 frontier 正交；不消除本 review 的并发 blocker。**

对两个 exact commits 执行 `git merge-tree --write-tree 7df5bbd6 b340faf3`，无 conflict，生成临时 tree `c73d655134567ad5d5618c6230b362461a93da95`；`git diff --check 7df5bbd6 <tree>` 通过。两边虽都修改 `src/core/gc.zig`、`src/core/gc_trace_stw.zig`、`src/tests/core.zig`，改动 hunk 可自动合成。

P1 的 `deriveHeapSpaceSnapshot` 枚举 `heapAccountingIterator`，按 `heap_accounted` 与实际 allocation size 计数，不读取 mark bit，也不把“当前 frontier 已 trace 的部分”当 live population：`gc/p1-oldspace-20260831:src/core/gc.zig:2537-2564,3115-3145`。S1a segment 只转移 header 地址，不改 alloc bitmap/GC object list；所以 cycle tracing 中间态下，P1 census 仍得到“当前逻辑已分配 population”，而不是半个 reachable set。collector 内 pre/post-sweep census 又只在 detailed report 下运行，并位于 sweep 边界：`gc/p1-oldspace-20260831:src/core/gc_trace_stw.zig:1732-1787`。

组合后的并发前提仍是 runtime owner 独占 heap/list mutation、parallel helper 仅在 STW slice 内活动。S1a 的迟到-helper 缺口破坏这个前提；P1 census 本身没有新增 race，但也不能为错误的 quiescence 提供隔离。因此合成结论是“mechanically clean、semantically conditional”，必须先修 Critical finding 再进入组合门禁。

## 最小复审门槛

1. generation-scoped helper arrival/completion handshake；两个人工卡点的确定性 interleaving test，证明 owner 不提前返回。
2. runtime-level frontier allocator fault injection，覆盖 incremental failure → abort → allocation-boundary synchronous full fallback；证明 fallback 实际完成并把 retirement 恢复为 clean，同时把“双 allocator 都失败”的调度债单列。
3. 更新 active GC design/validation matrix，并为 S4 重新定义 blackalloc 的 frontier pressure gate；不能用“overflow 项消失”判通过。
4. 修复后至少执行 `zig build check`、相关并发/OOM targeted tests，以及按 verification policy 的一次最终 `zig build test`。本次 reviewer 未修改被审分支、未 commit、未 push。
