# 09 — Trace STW / mark queue / incremental / generation

本文件覆盖收集器本体：minor / major / 增量 mark、分段前沿、sticky 分代状态。一次收集怎么走见 [09-gc.md](09-gc.md)。

函数级展开。总图见 [09-gc.md](09-gc.md)。写作规范见 [_spec.md](_spec.md)。

## `gc_generation.zig`

本模块保存 sticky-mark 分代侧表、统计与低收益探测策略，不负责实际遍历和释放对象。`flags.young`、年轻 block 链、年轻非 block 后缀和 extent 表共同描述年轻人口；存活者通过 trace-coupled retirement 或收集关闭流程晋升，不复制对象。`allocated && !marked` / `allocated && marked` 是稳定 sticky 状态下的判定思路，不是 major 清标记、标记途中、未发布或已 condemned 载体上都成立的恒等式。old→young 边按 owner 地址记入 remembered map；构造中被记住的 owner 在发布后也可能变成 young。

`remembered_skip_audit = std.debug.runtime_safety`。I0 是适用 carrier 的 membership cache bit 清零蕴含不在 remembered map；I3 是清 bit 后、清 map 前的短暂不一致窗口。`retirement_window_open` 只在 runtime-safety 构建中是 bool，其它构建为 void；它与收集周期的 retirement 状态不是同一个开关。

`MajorRetirement` 有 clean、tracing、needs_major 三态，初始 clean。tracing 表示 major 已开始退役，needs_major 表示未完成提交、须由 major 修复。`State.minor_retirement` 单独记录 minor 窗口，初始 false；minorsAllowed 只看 major enum，不能单靠它判断调度层是否允许立即启动 minor。remembered 为地址到 void 的 unmanaged 哈希表，不拥有对象；stats 默认零，pause 样本数组初始 empty，丢样本计数为零。

低收益状态初始 low_yield_streak=0、probe_backoff=1、probe_countdown=0。low_yield_limit=3，low_yield_reclaim_percent=10，probe_backoff_max=64：连续低于10%收益触发暂停，回退间隔随低收益探测翻倍；major 调用 decay 时先消耗 countdown，再减 streak，并非每次 major 都恢复一次探测。良好收益复位三项状态。阈值为当前实现常量，不是运行时参数。

Stats 的字段口径如下：

- young_count 是当前年轻载体普查；young_trigger_count 排除 owned storage cells，用于调度。young_publications 仅在 runtime-safety 路径递增，使用 wrapping 加法，不是数学意义的无限单调数。
- remembered_drops 统计登记失败；remembered_clears 统计实际非空 map 的清空。barrier_calls、barrier_young_owner、barrier_old_target 记录分代屏障调用及跳过分支，不能与增量屏障同名统计混为一谈。
- minor_suspensions、minor_collections、minor_reclaimed、minor_promoted、promoted 记录策略/结果。当前 promoted 的写入来自 noteMinorPromotion，不沿用旧注释中“还包含 major survivor census”的说法；minor_promoted 用 young_before 饱和减 reclaimed 估算。reclaimed 的口径受析构计数影响，不能把这些值解释成独立逐对象存活普查。
- remembered_without_young 的实际判据是重扫 owner 前后 collector.work 长度相同；叶子标记、已标记目标等可能不增加 work，因此名字不证明 owner 没有 young child。
- pause_ns_total/max 是 recordMinorPause 的累计/最大值。minor_clear/roots/conservative/remembered/trace/sweep/promote_ns_total 为详细模式下的七段累计；promote 段当前主要包含回收后 hot block 发布和结果记账，不是一遍单独的全量晋升遍历。
- young_at_start_total/max 记录走到对应统计点的 minor 起始普查，不保证覆盖提前失败的尝试。conservative_only_young 来自完整诊断预遍历的保守新增年轻数量，依赖该预遍历的枚举人口与根，不是全部应用引用的独立证明。
- retirement_commits/abandons 合并 major 与 minor 的提交/放弃；不能据它们直接推出 major 次数。统计字段有普通、饱和和 wrapping 加法，不能统称所有计数都饱和或严格单调。

`MinorPauseDistribution` 返回 samples_total、samples_retained、p50_ns/p95_ns/p99_ns/max_ns。samples_total 仅为尝试保留的样本数（成功数加丢弃数），不包括 retain_sample=false 的暂停；分位数和返回的 max_ns 都基于保留样本，可能不同于 Stats.pause_ns_max。无保留样本返回 null，即使累计暂停或丢样本计数非零。State 的样本数组由调用方提供的 allocator 管理，求分布会原地排序。

### `Stats.minorPhaseNsTotal` (`src/core/gc_generation.zig:102`)

- **签名**：`pub fn minorPhaseNsTotal(self: Stats) u64`。
- **作用**：合计 minor 各阶段的累计纳秒。
- **实现**：对 clear、roots、conservative、remembered、trace、sweep、promote 七个计时字段使用 `+|` 饱和求和。
- **所有权 / 错误 / 调用**：只读 Stats；不遍历 remembered set，不分配。

### `State.deinit` (`src/core/gc_generation.zig:174`)

- **签名**：`pub fn deinit(self: *State, allocator: std.mem.Allocator) void`。
- **作用**：释放分代侧表和暂停样本。
- **实现**：依次 deinit minor_pause_samples 与 remembered，再将 State 重置为默认值。
- **所有权 / 错误 / 调用**：必须使用对应 allocator；释放的是侧表，不是 GC 对象。重置后再次销毁空状态不重复释放原存储。

### `State.recordMinorPause` (`src/core/gc_generation.zig:180`)

- **签名**：`pub fn recordMinorPause(self: *State, allocator: std.mem.Allocator, duration_ns: u64, retain_sample: bool) void`。
- **作用**：记录一次 minor 暂停，并可选保留样本。
- **实现**：pause_ns_total 饱和累加，pause_ns_max 取最大值；retain_sample 为 false 时不入数组。append 失败时饱和增加 minor_pause_sample_drops。
- **所有权 / 错误 / 调用**：样本存储归 State；OOM 记丢样本而不抛出，不影响累计值与最大值。

### `State.minorPauseDistribution` (`src/core/gc_generation.zig:189`)

- **签名**：`pub fn minorPauseDistribution(self: *State) ?MinorPauseDistribution`。
- **作用**：从已保留的暂停样本计算分位数。
- **实现**：没有样本返回 null；原地升序堆排序，按 percentileIndex 取 p50/p95/p99，最后元素作 max；samples_total 包含丢弃计数。
- **所有权 / 错误 / 调用**：返回统计值，不转移数组；会改变样本顺序但不分配。分位数只依据成功保留的样本。

### `State.percentileIndex` (`src/core/gc_generation.zig:204`)

- **签名**：`fn percentileIndex(len: usize, percentile: usize) usize`。
- **作用**：把百分位换算成 nearest-rank 数组下标。
- **实现**：计算 `(len * percentile + 99) / 100`，将一基 rank 转为零基并限制到 len-1。
- **所有权 / 错误 / 调用**：调用方保证 len>0；只计算整数。

### `State.rememberOwner` (`src/core/gc_generation.zig:216`)

- **签名**：`pub fn rememberOwner(self: *State, allocator: std.mem.Allocator, owner: *gc.Header) bool`。
- **作用**：登记需要在 minor 重扫的 old owner。
- **实现**：以 owner 地址为 key 插入 remembered；OOM 增加 remembered_drops 并返回 false，成功返回 true。
- **所有权 / 错误 / 调用**：侧表使用传入 allocator，不取得 owner 存储所有权；调用方只能在 true 后发布 membership cache bit。

### `State.rememberedCount` (`src/core/gc_generation.zig:231`)

- **签名**：`pub inline fn rememberedCount(self: *const State) usize`。
- **作用**：读取 remembered 表当前条目数。
- **实现**：返回 `remembered.count()`，不扫描对象。
- **所有权 / 错误 / 调用**：只读，无分配。

### `State.forget` (`src/core/gc_generation.zig:235`)

- **签名**：`pub fn forget(self: *State, header: *const gc.Header) void`。
- **作用**：在对象脱离 registry 时删除 remembered 记录并更新 young 普查。
- **实现**：审计构建断言 retirement 窗口关闭；按 header 地址 remove，再调用 forgetYoungCensus。
- **所有权 / 错误 / 调用**：不销毁 header；移除记录不等同于释放对象。

### `State.forgetUnremembered` (`src/core/gc_generation.zig:253`)

- **签名**：`pub fn forgetUnremembered(self: *State, header: *const gc.Header) void`。
- **作用**：在已证明 owner 不在 remembered 表中时省掉哈希删除。
- **实现**：审计构建检查 retirement 窗口关闭且表中确实无该地址，随后只调用 forgetYoungCensus。
- **所有权 / 错误 / 调用**：调用方须提供 membership cache bit 等不在表中的证明；不释放 header。

### `State.forgetYoungCensus` (`src/core/gc_generation.zig:267`)

- **签名**：`inline fn forgetYoungCensus(self: *State, header: *const gc.Header) void`。
- **作用**：移除一个 young 对象对应的分代计数。
- **实现**：仅 flags.young 为真且 young_count>0 时递减；非 owned storage cell 且 trigger_count>0 时还递减 young_trigger_count。
- **所有权 / 错误 / 调用**：只更新普查，不改 header、不触碰 remembered map。

### `State.openRetirementWindow` (`src/core/gc_generation.zig:281`)

- **签名**：`pub fn openRetirementWindow(self: *State) void`。
- **作用**：在清 carrier cache bit 与清 remembered 表之间打开审计窗口。
- **实现**：未启用 remembered_skip_audit 时直接返回；否则断言尚未打开并置 true。
- **所有权 / 错误 / 调用**：只由 retirement 事务编排方调用；窗口内不允许 forget 观察暂时不一致的状态。

### `State.retireYoungSet` (`src/core/gc_generation.zig:298`)

- **签名**：`pub fn retireYoungSet(self: *State) void`。
- **作用**：清理已经被提升的 young 种群的计数与 remembered 表。
- **实现**：表非空才 clearRetainingCapacity 并增加 remembered_clears；清零两个 young 计数并关闭审计窗口。
- **所有权 / 错误 / 调用**：保留表容量；不遍历 header 去提升对象，也不增加 minor 次数。header/bitmap 的实际提升由收集器完成。

### `State.beginMajorRetirement` (`src/core/gc_generation.zig:317`)

- **签名**：`pub fn beginMajorRetirement(self: *State) void`。
- **作用**：标记 major 已开始执行 retirement。
- **实现**：major_retirement 置 tracing。
- **所有权 / 错误 / 调用**：必须在首次 shade 前调用，因为 shade 就可能提升 block cell。

### `State.commitMajorRetirement` (`src/core/gc_generation.zig:324`)

- **签名**：`pub fn commitMajorRetirement(self: *State) void`。
- **作用**：记录 major retirement 成功完成。
- **实现**：major_retirement 置 clean，retirement_commits 饱和加一。
- **所有权 / 错误 / 调用**：调用方已完成种群与标志对账；此函数只提交状态。

### `State.abandonMajorRetirement` (`src/core/gc_generation.zig:332`)

- **签名**：`pub fn abandonMajorRetirement(self: *State) void`。
- **作用**：关闭未成功提交的 major，并阻止 minor 使用不一致状态。
- **实现**：仅 tracing 状态变为 needs_major，并饱和增加 retirement_abandons。
- **所有权 / 错误 / 调用**：需要后续成功的 major 修复后，minor 才重新允许。

### `State.minorsAllowed` (`src/core/gc_generation.zig:339`)

- **签名**：`pub fn minorsAllowed(self: *const State) bool`。
- **作用**：判断 major retirement 状态是否允许 minor。
- **实现**：仅 major_retirement==clean 返回 true。
- **所有权 / 错误 / 调用**：只检查 major 枚举，不检查 minor_retirement。

### `State.retirementOpen` (`src/core/gc_generation.zig:345`)

- **签名**：`pub inline fn retirementOpen(self: *const State) bool`。
- **作用**：判断任意一种收集的 retirement 事务是否打开。
- **实现**：major 为 tracing 或 minor_retirement 为 true 时返回 true。
- **所有权 / 错误 / 调用**：retireTracedYoung 据此判断是否可进行 trace 耦合的提升。

### `State.beginMinorRetirement` (`src/core/gc_generation.zig:352`)

- **签名**：`pub fn beginMinorRetirement(self: *State) void`。
- **作用**：打开 minor retirement 事务。
- **实现**：minor_retirement 置 true。
- **所有权 / 错误 / 调用**：在 minor 第一次 shade 之前调用。

### `State.commitMinorRetirement` (`src/core/gc_generation.zig:358`)

- **签名**：`pub fn commitMinorRetirement(self: *State) void`。
- **作用**：提交已打开的 minor retirement。
- **实现**：未打开则返回；否则清 minor_retirement，retirement_commits 饱和加一。
- **所有权 / 错误 / 调用**：只提交状态；实际 young 结构的清理必须先完成。

### `State.abandonMinorRetirement` (`src/core/gc_generation.zig:368`)

- **签名**：`pub fn abandonMinorRetirement(self: *State) void`。
- **作用**：将中断的 minor 标为需要 major 修复。
- **实现**：未打开则返回；否则关闭 minor 窗口，major 状态置 needs_major，retirement_abandons 饱和加一。
- **所有权 / 错误 / 调用**：用于 trace OOM 等中止路径，避免部分提升后继续运行 minor。

### `State.noteMinorYield` (`src/core/gc_generation.zig:401`)

- **签名**：`pub fn noteMinorYield(self: *State, young_before: usize, reclaimed: usize) void`。
- **作用**：根据 minor 回收比例更新收益统计与暂停/探测策略。
- **实现**：young_before 为零直接返回；累加回收和提升数。回收比例至少 10% 时清 streak 并复位 backoff；否则增加 streak，达到 3 次时暂停，探测 backoff 翻倍但上限 64。
- **所有权 / 错误 / 调用**：只改策略与统计，不执行回收；minor_promoted 使用饱和减法 young_before -| reclaimed。

### `State.decayLowYieldStreak` (`src/core/gc_generation.zig:428`)

- **签名**：`pub fn decayLowYieldStreak(self: *State) void`。
- **作用**：在 major 后逐步重新允许一次 minor 探测。
- **实现**：streak 为零不动；countdown>0 时只减 countdown，否则减一次 streak。
- **所有权 / 错误 / 调用**：不会每次 major 都把 streak 清零，避免反复支付三次低收益 minor。

### `State.minorSuspended` (`src/core/gc_generation.zig:437`)

- **签名**：`pub fn minorSuspended(self: *const State) bool`。
- **作用**：判断低收益 minor 是否已达到暂停门槛。
- **实现**：返回 low_yield_streak>=low_yield_limit（3）。
- **所有权 / 错误 / 调用**：只读策略状态。

### `State.noteMinorPromotion` (`src/core/gc_generation.zig:441`)

- **签名**：`pub fn noteMinorPromotion(self: *State, survivors: usize) void`。
- **作用**：记录一次 minor 的提升数与完成次数。
- **实现**：stats.promoted 加 survivors；stats.minor_collections 加一。
- **所有权 / 错误 / 调用**：这里使用普通加法，不是饱和加法；调用方负责提供本轮提升数。

### `State.rememberedIterator` (`src/core/gc_generation.zig:446`)

- **签名**：`pub fn rememberedIterator(self: *const State) std.AutoHashMapUnmanaged(usize, void).KeyIterator`。
- **作用**：取得 remembered owner 地址的迭代器。
- **实现**：返回 remembered.keyIterator()。
- **所有权 / 错误 / 调用**：迭代器借用表；遍历期间不得做导致迭代失效的表变更。

## `src/core/gc_incremental.zig`

本模块保存增量 major 的状态、统计、标记前沿与待析构 morgue；屏障和收集调度的实现分别在 gc.zig、runtime.zig、gc_trace_stw.zig。常见 target-shading 分支给强写的精确新目标上色，不读取 owner 颜色；Shape/Realm 等稀有 owner-requeue 分支会检查 owner 是否已经标黑。因此不能把“从不读取 owner 颜色”推广到所有屏障分支。

State.major_marking_active 是 owner 线程访问的普通 bool。cycle_stw_ns 累计当前周期的各次暂停；last_settled_live_bytes 保存上一 major 的已结算存活估计。envelope_baseline_valid/envelope_active 控制测量是否有效；envelope_next_start_bytes、envelope_next_threshold_bytes 保存下轮基线，envelope_cycle_start_bytes、threshold_bytes、begin_bytes、peak_bytes 保存当前周期的 S/T/起始/峰值账户数据。

Marking 持有 Queue、MarkStack 和 header_epoch。epoch 初始为 1，0 留给新生未标记载体；major 推进非 block 载体 epoch，minor 保留 sticky mark。栈与队列共享段池，由同一个 owner 线程交替使用，没有并行 marker。

Morgue.by_kind 是按 kind 下标组织的循环链表桶，kind_pass/cursor 保存分片析构位置；pending 表示整个 doomed 事务未完成，也可能涉及桶外的 block bitmap、非 block Object 侧表。destroyed 累计当前轮析构计数；bytes 只计 finish 时仍计账的 condemned body，排除已在 bitmap 路径扣账的 cell。assist_credit_bytes 是可用辅助额度，assist_unreconciled_bytes 是尚待实际回收核销的预估。

调度以当前实现为准：pollGC 遇到 pending morgue 时，普通 poll 直接走 destroySlicePoll 并返回，urgent poll 先全部排空；显式全收集也先结束待析构事务。shouldTryMinor 本身没有 morgue 判定，shadeExact 会拒绝 condemned header，但这两点不等于普通 poll 会在析构窗口发起 minor。新 condemnation 还要求旧 morgue 已空；不能据旧注释推断任意直接调用 collectMinor 都安全。

Stats 的所有字段默认零，按以下含义分组：

| 字段 | 含义 |
| --- | --- |
| shaded、barrier_calls、barrier_marked_target、barrier_unpublished_owner、barrier_unpublished_target、barrier_requeued_owner | 屏障次数与出口统计；requeued_owner 计进入分支的次数，包含 white owner 被跳过的情况，不等于实际入队数 |
| cycles_completed、cycles_aborted、increments、forced_finishes | 周期完成/中止、标记切片和因安全阀强制完成次数 |
| last_cycle_stw_ns、max_cycle_stw_ns | 最近完成周期及最大周期的累计 STW 时间，不是单次暂停 |
| total_stw_by_kind、total_segments_by_kind、segment_max_ns | begin/increment/destroy/finish 四类阶段的累计时间、段数、最长段时间；同一次 poll 可包含多个阶段 |
| envelope_measured_cycles、envelope_skipped_cycles | 同域包络统计有效/跳过周期数 |
| envelope_max_start_bytes、envelope_max_threshold_bytes、envelope_max_begin_bytes、envelope_max_peak_bytes | 具有最大 P/T 的同一个已完成周期元组，不是四项各取最大值 |
| doomed_condemned_headers、doomed_destroyed_objects | condemned GC 节点数与公共 freed-object 口径的析构数，后者排除 bytecode |
| phase_begin_clear_ns、phase_begin_precise_seed_ns、phase_begin_conservative_seed_ns、phase_begin_retire_ns | begin 内部阶段累计时间 |
| phase_finish_init_ns、phase_finish_remark_ns、phase_finish_weak_ns、phase_finish_condemn_ns、phase_finish_tail_ns | finish 内部阶段累计时间 |
| phase_finish_conservative_seed_ns | remark 中保守根扫描的子集，不能再与 remark 相加 |
| phase_retired_nonblock_headers、phase_retired_young_blocks、phase_retired_remembered_sets、phase_cleared_nonblock_headers | 清标记/代际退役工作的数量统计 |

### `ratioMillionthsCeil` (`src/core/gc_incremental.zig:89`)

- **签名**：`pub fn ratioMillionthsCeil(numerator: usize, denominator: usize) usize`。
- **作用**：将 numerator/denominator 换算为向上取整的百万分比。
- **实现**：分母为零返回 0；用 u128 计算 numerator*1_000_000，再加 denominator-1 后整除，最后截到 usize 最大值。
- **所有权 / 错误 / 调用**：纯计算；扩宽中间量避免本项目 64 位 usize 的乘法溢出。返回整数百万分比，不是浮点百分数。

### `State.markingActive` (`src/core/gc_incremental.zig:132`)

- **签名**：`pub inline fn markingActive(self: *const State) bool`。
- **作用**：查询是否处于增量 major 标记阶段。
- **实现**：直接返回 major_marking_active 普通 bool。
- **所有权 / 错误 / 调用**：只读、无同步；写屏障的 mutator 路径也会调用，不限于 STW。所有访问由 runtime owner 线程串行执行。

### `Marking.deinit` (`src/core/gc_incremental.zig:160`)

- **签名**：`pub fn deinit(self: *Marking) void`。
- **作用**：释放私有标记栈和共享队列所持有的所有前沿段。
- **实现**：先 stack.deinitStack() 将栈段归还池并清空栈，再 queue.deinit() 归还队列段、释放池缓存并重置队列。header_epoch 不改。
- **所有权 / 错误 / 调用**：在合法生命周期内可重复调用：两项底层 deinit 都重置为空。必须先归还栈段再销毁队列池；Queue 用池首次绑定的 allocator 释放，因此本函数不再接收 allocator 参数（调用方 `Registry.deinit` 也不再传）。

### `Morgue.startAssistCredit` (`src/core/gc_incremental.zig:216`)

- **签名**：`pub fn startAssistCredit(self: *Morgue, estimated_bytes: usize) void`。
- **作用**：开始本轮析构辅助额度的预估计账。
- **实现**：将 assist_credit_bytes 与 assist_unreconciled_bytes 都覆盖为 estimated_bytes。
- **所有权 / 错误 / 调用**：不是累加旧额度；estimated_bytes 表示尚未实际释放、但已预先计入的 condemned body 字节。无分配。

### `Morgue.recordAssistReclaim` (`src/core/gc_incremental.zig:221`)

- **签名**：`pub fn recordAssistReclaim(self: *Morgue, before: usize, after: usize) void`。
- **作用**：将一轮析构的实际账户下降与预发额度对账。
- **实现**：reclaimed=before-|after；先消耗 min(reclaimed,assist_unreconciled_bytes) 的未核销预估，再将超出预估部分饱和加到 assist_credit_bytes。
- **所有权 / 错误 / 调用**：防止预估尸体与实际释放重复授信；before/after 来自同一析构切片账户采样。账户不降时不增加额度。

### `Morgue.consumeAssistDebt` (`src/core/gc_incremental.zig:230`)

- **签名**：`pub fn consumeAssistDebt(self: *Morgue, requested_bytes: *usize) void`。
- **作用**：为一次析构辅助扣除一个 interval 的分配债务与补充额度。
- **实现**：paid=min(requested_bytes,incremental_assist_interval_bytes)；额度饱和减 interval-paid，requested_bytes 指向的计数饱和减 interval。
- **所有权 / 错误 / 调用**：原地更新借用的债务计数；债务先支付，缺口才消耗额度。额度不足也截到零，不返回错误，不自行判断是否应该运行切片。

### `Morgue.clearAssistCredit` (`src/core/gc_incremental.zig:236`)

- **签名**：`pub fn clearAssistCredit(self: *Morgue) void`。
- **作用**：清空辅助额度及未核销预估。
- **实现**：将 assist_credit_bytes 和 assist_unreconciled_bytes 同时置零。
- **所有权 / 错误 / 调用**：不释放 morgue 对象，不改变 pending、bytes 或析构游标。

### `Morgue.init` (`src/core/gc_incremental.zig:243`)

- **签名**：`pub fn init(self: *Morgue) void`。
- **作用**：初始化每个 kind 桶的侵入式循环链表哨兵。
- **实现**：对 by_kind 中每个表头调用 listInit，使哨兵的 next_non_object 指向自身、tail 指回哨兵（单向循环链表加一个 tail 指针，没有 prev 链）。
- **所有权 / 错误 / 调用**：在第一次 condemnation 前、结构地址稳定时调用；只有空桶重复初始化才安全。对非空桶调用会断开条目，也不会清 pending、cursor、bytes 等其它状态。

## `src/core/gc_mark_queue.zig`

分段标记前沿：MarkStack 是私有 LIFO，Queue 是写屏障共享工作表；栈可从队列最老端 steal 整段，然后按段内 LIFO 消费。Queue.pop 则从最新端弹出。因此“Queue”不表示所有接口都遵循逐条 FIFO。

全部操作在 owner 线程串行执行，不加锁。段存储由 Registry 提供的 smp_allocator 分配，在 JS 堆账户之外，避免分配前沿本身递归触发 GC。“无界”指没有固定条目上限，仍受 backing 分配能力限制；失败使本轮标记失效，收集器边界返回错误并由 runtime abort，不能漏掉未入队地址后继续 sweep。

| 类型 / 常量 | 布局和生命周期 |
| --- | --- |
| segment_bytes / cached_segment_limit | 4096 字节一段，池最多缓存 8 个空段 |
| Segment | older/newer 双向链接、len 有效条目数、items 借用 header 指针数组；item_capacity=(4096-3*sizeof(usize))/sizeof(*Header)，entries_per_segment 为别名；编译期断言段大小恰为 4096、容量大于 1 |
| Failure | none、out_of_memory、unqueueable_barrier；保留首个失败直到 reset |
| PoolStats | active/cached/owned_segments 为当前数量，peak_active/peak_owned_segments 为高水位，allocations/frees/allocation_failures 为分配统计 |
| SegmentPool | backing 首次绑定后固定，cached_head 用 older 串空段；stats_data 保存统计，测试专用注入字段不属于生产状态 |
| MarkStack | bottom/top、借用 pool、len 和 segment_count；reset 保留池绑定，deinitStack 清除绑定 |
| Queue | oldest/newest、item_count、failure_state，内嵌 SegmentPool；必须先归还共享池的私有栈段，才能销毁队列与池 |
| Stats | 包含一份 PoolStats；反映整个共享池，不只队列当前段 |

池接管段分配的释放责任，栈/队列只在各自持段期间管理其使用权；items 中的 header 仅为借用，任何 reset/deinit 都不替 GC 释放对象。测试辅助函数不在本次逐项解释范围内，保留已有索引。

### `SegmentPool.ensureBacking` (`src/core/gc_mark_queue.zig:69`)

- **签名**：`fn ensureBacking(self: *SegmentPool, allocator: std.mem.Allocator) void`。
- **作用**：在池尚未绑定时记录 backing allocator。
- **实现**：仅当 backing==null 时赋值。
- **所有权 / 错误 / 调用**：不分配、不预留容量；后续传入不同 allocator 也不会更换原绑定。

### `SegmentPool.acquire` (`src/core/gc_mark_queue.zig:73`)

- **签名**：`pub fn acquire(self: *SegmentPool) ?*Segment`。
- **作用**：取得一个空白活跃段，优先复用缓存。
- **实现**：缓存非空则摘 cached_head、更新 cached/active 与峰值并重置段；否则用 backing.create(Segment)，成功后更新 allocations、owned、active 与峰值。未绑定或分配失败均增加 allocation_failures 并返回 null。
- **所有权 / 错误 / 调用**：调用方取得段的使用权，最终必须 release；失败不返回半初始化段。测试故障注入只影响实际 backing 分配，不阻止命中缓存。

### `SegmentPool.release` (`src/core/gc_mark_queue.zig:117`)

- **签名**：`pub fn release(self: *SegmentPool, segment: *Segment) void`。
- **作用**：将活跃段归还最多 8 段的缓存，超额则释放。
- **实现**：重置段并断言 active 非零，active 减一；缓存未满则用 older 头插，否则 owned 减一、frees 加一并由绑定 allocator.destroy。
- **所有权 / 错误 / 调用**：调用方交回段使用权，禁止重复归还。只处理段存储，不释放 items 曾指向的 GC header。

### `SegmentPool.stats` (`src/core/gc_mark_queue.zig:133`)

- **签名**：`pub fn stats(self: *const SegmentPool) PoolStats`。
- **作用**：获取池计数的值快照。
- **实现**：返回 stats_data。
- **所有权 / 错误 / 调用**：无借用内部计数字段、无重置、无分配。

### `SegmentPool.failBackingAllocationsForTest` (`src/core/gc_mark_queue.zig:137`)

- **签名**：`pub fn failBackingAllocationsForTest(self: *SegmentPool, count: usize) void`。
- **作用**：测试专用：让接下来 count 次真实 backing 取段失败。
- **实现**：非测试构建走 `@compileError("test-only helper")`；测试构建把 count 写入 test_fail_backing_allocations。
- **所有权 / 错误 / 调用**：只设置计数，不分配也不释放段。acquire 每命中一次就把计数减一并增加 allocation_failures；命中缓存的取段不受影响，因此注入次数不等于 push 失败次数。

### `SegmentPool.deinit` (`src/core/gc_mark_queue.zig:142`)

- **签名**：`pub fn deinit(self: *SegmentPool) void`。
- **作用**：销毁所有缓存段并恢复默认空池。
- **实现**：摘下 cached_head，沿 older 逐段用 backing allocator.destroy，最后 self.*=.{}。
- **所有权 / 错误 / 调用**：只遍历缓存，不回收仍被栈/队列占用的活跃段；调用前必须归还它们。重置后可重复销毁，但统计也被清空。

### `MarkStack.ensure` (`src/core/gc_mark_queue.zig:167`)

- **签名**：`pub fn ensure(self: *MarkStack, pool: *SegmentPool) void`。
- **作用**：为私有栈绑定段池。
- **实现**：未绑定时保存 pool；已有绑定则断言是同一个 pool。
- **所有权 / 错误 / 调用**：不分配；pool 指针是借用，栈不能比池活得更久，绑定后不能把包含它的 Queue 随意搬址。

### `MarkStack.reset` (`src/core/gc_mark_queue.zig:171`)

- **签名**：`pub fn reset(self: *MarkStack) void`。
- **作用**：清空私有栈并将全部段归还池。
- **实现**：若未绑定池则重置整个栈；否则从 bottom 沿 newer 遍历 release，清 bottom/top/len/segment_count，保留 pool 绑定。
- **所有权 / 错误 / 调用**：不释放 GC header；池可能缓存或释放归还的段，因此不保证保留全部 backing。

### `MarkStack.deinitStack` (`src/core/gc_mark_queue.zig:188`)

- **签名**：`pub fn deinitStack(self: *MarkStack) void`。
- **作用**：结束私有栈生命周期。
- **实现**：先 reset 归还段，再 self.*=.{}，连同 pool 绑定一起清除。
- **所有权 / 错误 / 调用**：必须先于段池 deinit；合法状态下重复调用安全。

### `MarkStack.push` (`src/core/gc_mark_queue.zig:193`)

- **签名**：`pub inline fn push(self: *MarkStack, header: *gc.Header) bool`。
- **作用**：将一个 header 指针压入私有 LIFO。
- **实现**：顶段不存在或已满时 acquire 新段并接在 top；成功后写 items、递增段长和栈 len。
- **所有权 / 错误 / 调用**：未绑定或取段失败返回 false，已有内容保留；此函数不写 Queue.failure_state，调用方必须传播失败。保存借用指针，不接管 header 内存。

### `MarkStack.pop` (`src/core/gc_mark_queue.zig:209`)

- **签名**：`pub inline fn pop(self: *MarkStack) ?*gc.Header`。
- **作用**：从栈顶取出最近压入的 header。
- **实现**：无 top 返回 null；否则递减段长与 len，读取末项；段变空时 releaseEmptyTop。
- **所有权 / 错误 / 调用**：返回借用 header；释放的是空前沿段，不是 header。

### `MarkStack.popPrefetch` (`src/core/gc_mark_queue.zig:220`)

- **签名**：`pub inline fn popPrefetch(self: *MarkStack) ?*gc.Header`。
- **作用**：弹出栈顶，并预取下一待处理 header。
- **实现**：与 pop 相同；递减后若本段仍有条目则预取其末项，否则预取 older 段末项；最后归还空顶段。
- **所有权 / 错误 / 调用**：预取使用 read/data、locality=3，不改变遍历顺序。目标是待标记 header，并非所谓尸体。

### `MarkStack.releaseEmptyTop` (`src/core/gc_mark_queue.zig:236`)

- **签名**：`fn releaseEmptyTop(self: *MarkStack, segment: *Segment) void`。
- **作用**：摘除并归还已经弹空的顶段。
- **实现**：断言参数就是 top；top 改为 older，清新 top.newer 或 bottom，segment_count 减一并 pool.release。
- **所有权 / 错误 / 调用**：内部调用方保证段为空且 len 已更新；本函数不再次扣减条目数。

### `MarkStack.adoptAsTop` (`src/core/gc_mark_queue.zig:246`)

- **签名**：`fn adoptAsTop(self: *MarkStack, segment: *Segment) void`。
- **作用**：把一整段工作接入私有栈顶。
- **实现**：断言段已脱链且非空；链接到旧 top，必要时设置 bottom，累加 len 与 segment_count。
- **所有权 / 错误 / 调用**：段使用权移入栈，不复制 items、不分配；调用方须保证该段来自栈绑定的池，本函数不验证池归属。

### `Queue.ensureCapacity` (`src/core/gc_mark_queue.zig:270`)

- **签名**：`pub fn ensureCapacity(self: *Queue, allocator: std.mem.Allocator) void`。
- **作用**：为共享工作队列绑定分配器。
- **实现**：委托 pool.ensureBacking(allocator)。
- **所有权 / 错误 / 调用**：名称并不意味着预分配：此处不取得任何段，也不保证后续 push 成功。Registry 提供 JS 堆账户之外的 backing。

### `Queue.segmentPool` (`src/core/gc_mark_queue.zig:274`)

- **签名**：`pub fn segmentPool(self: *Queue) *SegmentPool`。
- **作用**：借用队列内嵌段池。
- **实现**：返回 &self.pool。
- **所有权 / 错误 / 调用**：不创建新池；指针必须在 Queue 地址稳定且存活期间使用。

### `Queue.failBackingAllocationsForTest` (`src/core/gc_mark_queue.zig:278`)

- **签名**：`pub fn failBackingAllocationsForTest(self: *Queue, count: usize) void`。
- **作用**：测试专用：把取段失败注入转发给队列内嵌的段池。
- **实现**：非测试构建走 `@compileError("test-only helper")`；测试构建委托 self.pool.failBackingAllocationsForTest(count)。
- **所有权 / 错误 / 调用**：不改动队列条目、item_count 或 failure_state；注入的失败要等到 push 取不到段时才由 noteOutOfMemory 记成 out_of_memory。

### `Queue.deinit` (`src/core/gc_mark_queue.zig:285`)

- **签名**：`pub fn deinit(self: *Queue) void`。
- **作用**：释放队列与它持有的池缓存，恢复默认状态。
- **实现**：reset 归还队列段，pool.deinit 销毁缓存，最后 self.*=.{}。
- **所有权 / 错误 / 调用**：实际释放使用池首次绑定的 allocator，所以签名不带 allocator 参数。共享池的私有栈须先 deinitStack；满足此前提时重复销毁安全。

### `Queue.reset` (`src/core/gc_mark_queue.zig:291`)

- **签名**：`pub fn reset(self: *Queue) void`。
- **作用**：清空队列工作和失败状态，保留可复用段池。
- **实现**：先清 oldest/newest/item_count/failure_state，再从旧 oldest 沿 newer 逐段归还池。
- **所有权 / 错误 / 调用**：不触碰私有栈里的段，不释放 header；缓存超限的段会实际释放，不是只清逻辑长度。

### `Queue.len` (`src/core/gc_mark_queue.zig:304`)

- **签名**：`pub fn len(self: *const Queue) usize`。
- **作用**：查询仍在共享队列中的 header 条目数。
- **实现**：返回 item_count。
- **所有权 / 错误 / 调用**：不含已 steal 到私有栈的条目，也不是池活跃段数。

### `Queue.isEmpty` (`src/core/gc_mark_queue.zig:308`)

- **签名**：`pub fn isEmpty(self: *const Queue) bool`。
- **作用**：判断共享队列是否没有条目。
- **实现**：返回 item_count==0。
- **所有权 / 错误 / 调用**：空队列仍可能保留缓存、失败状态或有私有栈工作；不能单独据此判定标记完成。

### `Queue.stats` (`src/core/gc_mark_queue.zig:312`)

- **签名**：`pub fn stats(self: *const Queue) Stats`。
- **作用**：取得共享段池统计。
- **实现**：返回 Stats{.pool=pool.stats()} 值快照。
- **所有权 / 错误 / 调用**：池统计包括共享同一池的私有栈段，不只当前队列。

### `Queue.failure` (`src/core/gc_mark_queue.zig:316`)

- **签名**：`pub fn failure(self: *const Queue) Failure`。
- **作用**：读取本轮记录的首个前沿失败原因。
- **实现**：返回 failure_state。
- **所有权 / 错误 / 调用**：查询不清除失败；reset/deinit 才清除，队列后来成功 push 也不会清除。

### `Queue.invalidateBarrier` (`src/core/gc_mark_queue.zig:320`)

- **签名**：`pub fn invalidateBarrier(self: *Queue) void`。
- **作用**：将不能安全入队的屏障标为本轮失败。
- **实现**：仅当 failure_state==none 时写 unqueueable_barrier。
- **所有权 / 错误 / 调用**：保留已记录的首个失败，不丢弃已有工作；收集器边界负责停止本轮并避免 sweep。

### `Queue.noteOutOfMemory` (`src/core/gc_mark_queue.zig:324`)

- **签名**：`fn noteOutOfMemory(self: *Queue) void`。
- **作用**：记录前沿取段失败。
- **实现**：仅在 failure_state==none 时写 out_of_memory。
- **所有权 / 错误 / 调用**：不覆盖先前的 unqueueable_barrier，也不抛 Zig error；通过 failure 查询传播到标记边界。

### `Queue.push` (`src/core/gc_mark_queue.zig:329`)

- **签名**：`pub noinline fn push(self: *Queue, header: *gc.Header) bool`。
- **作用**：在共享队列最新端追加一个 header。
- **实现**：newest 有空位则直接追加；否则 acquire 新段，填首项后 appendNewest。取段失败时 noteOutOfMemory 并返回 false，成功递增 item_count。
- **所有权 / 错误 / 调用**：保存借用 header，不接管其内存。即使已有失败也可继续追加，成功不撤销失败；调用方/收集器必须检查本轮 failure。

### `Queue.steal` (`src/core/gc_mark_queue.zig:350`)

- **签名**：`pub fn steal(self: *Queue, local: *MarkStack) bool`。
- **作用**：把队列最老的一整段工作移交私有栈。
- **实现**：空队列返回 false；否则摘 oldest、修复两端、清段链接，item_count 减去段长，然后 local.adoptAsTop，返回 true。
- **所有权 / 错误 / 调用**：O(1) 转移段使用权，不逐条复制。调用方须把 local 绑定到本队列池；通常在栈空时调用，方法本身不要求 local 为空。

### `Queue.pop` (`src/core/gc_mark_queue.zig:363`)

- **签名**：`pub fn pop(self: *Queue) ?*gc.Header`。
- **作用**：从最新段末端弹出一条工作。
- **实现**：无 newest 返回 null；递减段长和 item_count 后读取末项；段空则摘链并 pool.release。
- **所有权 / 错误 / 调用**：这是最新端 LIFO 弹出，不是 FIFO；steal 则优先最老段。返回借用 header，不释放它。

### `Queue.appendNewest` (`src/core/gc_mark_queue.zig:378`)

- **签名**：`fn appendNewest(self: *Queue, segment: *Segment) void`。
- **作用**：把脱链段链接到队列最新端。
- **实现**：断言 older/newer 都为 null；设置 older、旧尾 newer、必要时 oldest，最后更新 newest。
- **所有权 / 错误 / 调用**：只链接，不修改 item_count；调用方负责填段和计数，禁止将仍属于其它链表的段直接加入。

## `gc_trace_stw.zig`

收集器：非移动、分代、增量标记、每步 STW。强边走 `traceChildEdges*`；弱集合项在普通强边遍历中跳过，ephemeron 阶段只在 holder 和 key 都已标记时处理 value。可失败的标记入口把错误返回调用方，已有标记和队列变化不自动回滚；是否中止、何时重试由上层编排。诊断快照分配、弱清理及析构等路径有各自的失败合同，见对应函数。

`Collector` 是一轮收集的栈上状态：`shade_to_queue` 区分增量（灰进分段队列）和同步 STW（`work` ArrayList）。`storageCell` 是叶子 shade：storage kind 无出边，不走前沿往返。


本节 CollectError 为 allocator 错误加 PayloadMarkFailed。模块级 last_report 默认空报告，由相应收集入口发布，不是每个增量切片的独立报告。Report 保存 swept、ephemeron_rounds/ephemeron_values_shaded、conservative.Metrics、详细模式的 marked_conservative_extra、census_ns 和 skipped_sweep_incomplete_arenas；这些是报告/控制流数据，不等价于一次完整正确性证明。

MarkStorageComponent 分 base、shape、property_slots、dense_elements、trace_payload、payload_backing；MarkTraceClass 分 ordinary_object、fast_array、bytecode_function、exotic_object、non_object，两者各有枚举长度常量。MarkStorageAggregate 为 allocation_touches/allocated_bytes/touched_cache_lines，均默认零。

MarkFootprint 固定 cache_line_bytes=64、inline_limits={1,2,4}。major_censuses/marked_headers/block_headers及by_kind/by_trace_class保存普查次数；storage按组件、storage_by_trace_class按当前active_trace_class（默认non_object）记账。inline_*五组数组分别表示eligible、外部字节、外部缓存行、已有direct内联、tail后来扩为external；inline_ordinary_*是普通对象子集。统计不全局去重，共享组件可随不同owner反复贡献，行数是结构范围估计，不是硬件事件。

### `checkFrontierFailure` (`src/core/gc_trace_stw.zig:40`)

- **签名**：`fn checkFrontierFailure(queue: *const gc.mark_queue.Queue) CollectError!void`。
- **作用**：将标记队列保存的失败状态转换为收集错误。
- **实现**：none成功返回；out_of_memory返回OutOfMemory；unqueueable_barrier返回PayloadMarkFailed。
- **所有权 / 错误 / 调用**：不清失败、不排空队列；调用方负责中止流程，不能忽略失败继续sweep。

### `popSegmentedFrontier` (`src/core/gc_trace_stw.zig:48`)

- **签名**：`fn popSegmentedFrontier( stack: *gc.MarkStack, queue: *gc.mark_queue.Queue, comptime prefetch: bool, ) ?*gc.Header`。
- **作用**：从私有栈取下一项，必要时接收共享队列整段。
- **实现**：根据编译期prefetch选择popPrefetch或pop；有项立即返回，否则queue.steal(stack)，成功后重试，队列也空才返回null。
- **所有权 / 错误 / 调用**：不分配新段、不检查failure；null只表示两处当前无工作。stack须已绑定共享队列池，返回借用header。

### `traceHeaderEdges` (`src/core/gc_trace_stw.zig:63`)

- **签名**：`pub fn traceHeaderEdges(rt: *JSRuntime, visitor: anytype, header: *gc.Header) CollectError!void`。
- **作用**：按载体kind枚举一个header持有的强边。
- **实现**：block非Object要求prefix carrier，rope走traceRopeEdges，其它为叶子；block/nonblock Object合流调用Object.traceChildEdgesFallible。非block bytecode访问realm、常量池并traceFunctionBytecodeAtoms；var_ref访问value；shape/module调用可失败边遍历；realm调用NoFail遍历；rope单独遍历，string/big_int及各裸storage返回。
- **所有权 / 错误 / 调用**：visitor按各路径提供所需方法，错误由可失败遍历上抛；无释放或pin。不能沿用“block仅服务Object”或“payload尚不存在”的旧注释。这里只枚举边，不自行处理weak不动点。

### `sweepAtomTable` (`src/core/gc_trace_stw.zig:150`)

- **签名**：`fn sweepAtomTable(rt: *JSRuntime) void`。
- **作用**：按当前block heap epoch清扫atom表。
- **实现**：读取rt.gc.block_heap.mark_epoch，调用rt.atoms.sweepDead(rt,epoch)。
- **所有权 / 错误 / 调用**：修改atom表；major必须在标记结论仍有效的同一暂停中调用，不能推迟到mutator恢复后的析构切片结束。具体保留判据由sweepDead实现。

### `traceFunctionBytecodeAtoms` (`src/core/gc_trace_stw.zig:163`)

- **签名**：`fn traceFunctionBytecodeAtoms(rt: *JSRuntime, fb: *FunctionBytecode, visitor: anytype) CollectError!void`。
- **作用**：将字节码持有的atom及可选small-inline状态交给visitor。
- **实现**：visitor类型（指针取child）没有visitAtom时编译期直接返回。否则按funcName、filenameAtom、scriptOrModule、allVarDefs、closureVar及atomOperandIterator逐项callVisitAtom；再通过可选small_inline_trace_atoms hook和Bridge处理隐藏状态。
- **所有权 / 错误 / 调用**：前半try传播错误；hook接口无错误返回，Bridge记失败，hook结束后统一返回OutOfMemory。没有hook则完成前面枚举后返回，不意味着跳过整个字节码atom集。

### `Bridge.visit` (`src/core/gc_trace_stw.zig:180`)

- **签名**：`fn visit(ctx: *anyopaque, id: atom_mod.Atom) void`。
- **作用**：将无错误返回的small-inline atom回调桥接到可失败visitor。
- **实现**：从ctx取Bridge，callVisitAtom(self.vis,id)，失败只置failed=true。
- **所有权 / 错误 / 调用**：不抛错、不停止hook继续回调，也不保存原始错误；外层统一映射为OutOfMemory。不是普通对象强边visit回调。

### `MarkFootprint.cacheLines` (`src/core/gc_trace_stw.zig:277`)

- **签名**：`fn cacheLines(address: usize, bytes: usize) usize`。
- **作用**：计算连续字节范围跨越的64字节缓存行数量。
- **实现**：bytes为零返回0；末地址用address+|(bytes-1)饱和计算，再算末行号-首行号+1。
- **所有权 / 错误 / 调用**：纯结构估计，不读取内存，不是硬件cache miss或唯一行数；不同调用的重叠范围会各计一次。

### `MarkFootprint.noteMarkedHeader` (`src/core/gc_trace_stw.zig:283`)

- **签名**：`pub fn noteMarkedHeader(self: *MarkFootprint, header: *gc.Header) void`。
- **作用**：累计一次最终标记header普查项。
- **实现**：marked_headers饱和加一；rope/string_buffer折入string的by_kind，其它kind保持原项；block cell另外递增block_headers。
- **所有权 / 错误 / 调用**：不设置mark、不验证header已标记，也不去重；调用方保证普查人口和次数。不能把by_kind的string行理解为仅flat string。

### `MarkFootprint.beginTraceClass` (`src/core/gc_trace_stw.zig:301`)

- **签名**：`pub fn beginTraceClass(self: *MarkFootprint, class: MarkTraceClass) void`。
- **作用**：开始按一个对象追踪类别记账。
- **实现**：by_trace_class对应项饱和加一，并覆盖active_trace_class。
- **所有权 / 错误 / 调用**：是状态设置与计数，不是保存/恢复栈；后续noteAllocation使用最近设置类别，嵌套调用须由调用方协调。

### `MarkFootprint.noteAllocation` (`src/core/gc_trace_stw.zig:306`)

- **签名**：`pub fn noteAllocation( self: *MarkFootprint, component: MarkStorageComponent, allocation_bytes: usize, touched_address: usize, touched_bytes: usize, ) void`。
- **作用**：将一次组件触及计入组件和当前追踪类别两张统计表。
- **实现**：allocation_bytes或touched_bytes为零则忽略；否则两处均饱和增加allocation_touches、完整allocation_bytes，以及cacheLines(touched_address,touched_bytes)。
- **所有权 / 错误 / 调用**：不按分配地址全局去重；共享Shape可随多个owner重复贡献。allocated_bytes描述完整容量，cache行描述本次触及范围，不能混成已实际读取字节。

### `MarkFootprint.noteInlinePropertyCandidate` (`src/core/gc_trace_stw.zig:324`)

- **签名**：`pub fn noteInlinePropertyCandidate( self: *MarkFootprint, live_properties: usize, allocation_bytes: usize, allocation_address: usize, touched_bytes: usize, has_trailing_allocation: bool, storage_is_inline: bool, ) void`。
- **作用**：评估当前属性存储对1/2/4槽内联上限的结构候选统计。
- **实现**：live_properties/allocation_bytes/touched_bytes任一零则忽略；断言inline必有trailing allocation。对每个能容纳live_properties的上限递增eligible；已有inline计direct，否则计真实外部字节/行，有tail另计grown_external。ordinary_object再同步专用分栏。
- **所有权 / 错误 / 调用**：一个对象可同时计入多个上限，是嵌套候选集，不可相加当总对象数。仅统计潜在容量条件，不证明改造可行或性能收益，不改变分配布局。

VerifyReachability 分 precise/conservative_only。FullReachable.entries 是 header整数地址到该分类的哈希表，allocator 保存释放表的分配器；它是与当前收集同机制的诊断对照，不是独立ECMA语义证明，也不能发现双方都未枚举的未知边。

本文件的 detailed_reports 与 mark_footprint_census 都是默认false的模块全局开关；前者控制详细普查，后者单独控制最终标记存储普查。last_census_ns保存最近一轮累计普查计时，last_finish_remark_raw_ns保存详细模式下未扣普查的remark时长见证。报告扣时不返还mutator时间，普查本身还可能留下保守扫描可见的地址残留；不能声称这些开关完全不改变收集行为。全局数据也不是每runtime各一份。

### `FullReachable.deinit` (`src/core/gc_trace_stw.zig:414`)

- **签名**：`fn deinit(self: *FullReachable) void`。
- **作用**：释放诊断可达集的哈希表存储。
- **实现**：entries.deinit(allocator) 后 self.*=undefined。
- **所有权 / 错误 / 调用**：不释放表中地址指向的对象；不是重置为空，销毁后不可重复调用或读取。

### `computeFullReachable` (`src/core/gc_trace_stw.zig:440`)

- **签名**：`fn computeFullReachable(rt: *JSRuntime, scan: runtime_mod.GCRootScan) !FullReachable`。
- **作用**：关闭代际捷径，计算精确根与保守根额外可达集，供诊断对照。
- **实现**：保存入口heap epoch及all人口已标记header，暂时关闭增量marking并defer恢复该开关。创建probe并冻结atom stamps，clearMarks后seedRoots/drain/ephemeron，把当前标记项登记precise；按scan配置追加保守扫描，再drain/ephemeron，新增项登记conservative_only，并更新诊断计数。成功末尾再次clearMarks、重标saved项并restampTraceEpoch后返回表。
- **所有权 / 错误 / 调用**：返回表由调用方deinit；不运行processWeak。恢复的是成功路径上的标记集合/atom epoch关系，不把epoch数值退回入口。中途try失败会释放临时资源并恢复marking开关，但末尾标记恢复没有defer保证，因此错误不是对原mark状态的事务回滚。诊断统计也可能已经改变。

### `verifyFullCondemnation` (`src/core/gc_trace_stw.zig:537`)

- **签名**：`fn verifyFullCondemnation(rt: *JSRuntime, reachable: *const FullReachable) CollectError!void`。
- **作用**：比较当前将判死的人口与新鲜诊断可达集。
- **实现**：遍历all，跳过当前marked或pinned；其余在reachable中出现者按precise/conservative_only累计，最多打印8个详情，再打印总量。precise不符非零返回PayloadMarkFailed，只有conservative不符则正常返回。
- **所有权 / 错误 / 调用**：不修改弱引用或对象存储，也不实际condemn。保守扫描帧差异会改变残留根，因此单独报告而不直接判失败；两类计数在本函数局部，不保存到长期计数器。

### `censusTimed` (`src/core/gc_trace_stw.zig:641`)

- **签名**：`inline fn censusTimed() bool`。
- **作用**：判断任一普查开关是否要求计时。
- **实现**：返回detailed_reports or mark_footprint_census。
- **所有权 / 错误 / 调用**：只读全局开关；两类普查相互独立。

### `censusStart` (`src/core/gc_trace_stw.zig:645`)

- **签名**：`inline fn censusStart() u64`。
- **作用**：按普查开关取得开始时间。
- **实现**：censusTimed为真返回profile.nowNanos，否则返回0。
- **所有权 / 错误 / 调用**：不重置last_census_ns；调用方负责一轮收集的累计器初始化。

### `censusEnd` (`src/core/gc_trace_stw.zig:649`)

- **签名**：`inline fn censusEnd(started: u64) void`。
- **作用**：将一段普查耗时计入全局累计器。
- **实现**：当前censusTimed为false则返回；否则读取now，仅now>started时向last_census_ns饱和加差值。
- **所有权 / 错误 / 调用**：重新读取当前开关，调用期间不应切换；仅记账，不补偿实际耗时或普查引起的保守根变化。

### `requireInvariant` (`src/core/gc_trace_stw.zig:655`)

- **签名**：`fn requireInvariant(result: anyerror!void, audit: []const u8, panic_message: []const u8) void`。
- **作用**：把不变量检查错误转成带诊断输出的panic。
- **实现**：成功无操作；失败打印audit标签和错误名，再以panic_message执行@panic。
- **所有权 / 错误 / 调用**：不把错误返回给调用方，也不修复状态；诊断写入失败不会阻止panic。

### `verifyCollectorInvariants` (`src/core/gc_trace_stw.zig:668`)

- **签名**：`fn verifyCollectorInvariants( rt: *JSRuntime, verify_scan_cache: bool, require_retirement_commit: bool, ) void`。
- **作用**：在调用方指定的稳定边界执行组合GC审计。
- **实现**：先auditArenas与auditLiveObjectsResolve，任一违规打印并panic；再依次校验地址索引、Shape哈希、construction根、表示、延迟payload根、属性存储、侵入链、block heap及发布例外、代际状态；按参数可检查major退役提交，最后核验堆计账。
- **所有权 / 错误 / 调用**：函数本身没有总开关或错误返回，启用时机由调用方决定。verify_scan_cache只控制地址索引的缓存检查，require_retirement_commit只控制退役检查；其它审计仍执行。失败终止，不是可捕获的CollectionError。

### `recordFinalMarkFootprint` (`src/core/gc_trace_stw.zig:728`)

- **签名**：`fn recordFinalMarkFootprint(rt: *JSRuntime) void`。
- **作用**：在弱处理和判死前累计本轮最终标记人口的存储普查。
- **实现**：仅mark_footprint_census启用时计时执行；major_censuses加一，遍历all只处理headerMarked。先noteMarkedHeader；Object调用recordTraceStorageFootprint，其它设non_object并以header-prefix及prefix+heapByteSizeFromHeader记base全范围。
- **所有权 / 错误 / 调用**：不清既有统计，跨轮累计；不另加仅pinned但未marked项。普查时间记到last_census_ns以便报告扣除，但真实暂停仍包含这一遍历。

### `collectCycles` (`src/core/gc_trace_stw.zig:757`)

- **签名**：`pub fn collectCycles(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize`。
- **作用**：执行一次同步major，并结束或放弃代际退役事务。
- **实现**：清last_census_ns、collections加一，创建collector；beginMajorRetirement后run，错误errdefer标记abandoned。成功run后clearYoungState；若报告因地址集合不完整跳过sweep，则abandon并请求collection_failed/soon，否则commit。随后衰减minor低收益历史、写last_report，按开关执行组合审计并返回swept。
- **所有权 / 错误 / 调用**：Collector总由defer销毁；collections在init前已加一，不能仅据此当成功数。跳过sweep可正常返回0且安排重试，不等于已完成回收；事务abandon不是恢复所有旧mark/young位。阈值与公共major统计由runtime上层结算。

### `collectMinor` (`src/core/gc_trace_stw.zig:810`)

- **签名**：`pub fn collectMinor(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!?usize`。
- **作用**：在允许的退役状态下，对年轻代执行同步标记与回收。
- **实现**：minorsAllowed=false返回null，young_count=0返回0。创建minor collector，可选完整可达诊断失败只打印并继续；在clearYoungMarks/seedRoots前beginMinorRetirement。精确根、可选保守根、remembered owner强制遍历后drain/ephemeron。地址集合不完整时不sweep，批量提升并closeYoungGeneration后返回0；否则sweepUnmarkedYoung，记录收益、发布完成的hot block片段，按young_before-|reclaimed记提升并返回reclaimed。
- **所有权 / 错误 / 调用**：可失败路径abandonMinorRetirement，释放临时collector/可达表；诊断setup失败不自动中止minor。remembered_without_young只看work长度是否增长，不是独立证明没有young边。详细模式分段计时；本函数不自行更新runtime的collection/pause总统计或major阈值。

### `promoteYoungSurvivorsInBulk` (`src/core/gc_trace_stw.zig:977`)

- **签名**：`fn promoteYoungSurvivorsInBulk(rt: *JSRuntime) void`。
- **作用**：将年轻迭代人口的header.young批量清除。
- **实现**：遍历objectIterator(.young)，逐个设flags.young=false。
- **所有权 / 错误 / 调用**：不复制对象、不清容器或提交事务；该迭代器不包括extent人口，extent由closeYoungGeneration单独退役。主要用于诊断路径与不sweep的补救分支。

### `closeYoungGeneration` (`src/core/gc_trace_stw.zig:991`)

- **签名**：`fn closeYoungGeneration(rt: *JSRuntime) void`。
- **作用**：关闭minor当前年轻代，在析构新发布前建立下一代的空状态。
- **实现**：按顺序retireYoungExtents、clearYoungBlocks、retireYoungSymbolBodies、resetYoungSuffix、retireGenerationalYoungSet，最后commitMinorRetirement。
- **所有权 / 错误 / 调用**：不逐个清普通header.young，须由前面的trace/condemn或bulk promotion完成。调用位置在判死和析构之间，析构产生的新发布属于下一代，不应再被本次清零吞掉。

### `clearYoungState` (`src/core/gc_trace_stw.zig:1015`)

- **签名**：`fn clearYoungState(rt: *JSRuntime) void`。
- **作用**：在major结束后清理仍登记为young的各人口及容器。
- **实现**：遍历young_list（主链后缀加非block Object）清young，再遍历young_block清young；清young block链，退役extent与atom年轻symbol body，清后缀游标并retireGenerationalYoungSet。
- **所有权 / 错误 / 调用**：实际是前向迭代，不能沿用旧注释称为向后遍历尾链。处理包括sweep期间新发布的young，不全堆逐header扫描；本函数不commitMajorRetirement，由major调用者按是否真正sweep决定。

### `beginIncrementalCycle` (`src/core/gc_trace_stw.zig:1044`)

- **签名**：`pub fn beginIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!void`。
- **作用**：建立增量major的标记前沿并发布marking-active状态。
- **实现**：断言未active，绑定队列allocator与私有栈池并清空两者；collector设shade_to_queue。先beginMajorRetirement，再clearMarks、播种精确/可选保守根并checkFrontierFailure，记录阶段时间；清young block链和代际集合计数，最后setMajorMarkingActive(true)。
- **所有权 / 错误 / 调用**：错误时清栈/队列并abandon退役事务，不恢复旧mark。ensureCapacity只绑定allocator，不预分配全部容量。非block年轻后缀保留到finish处理；active只在所有播种步骤成功后发布。

### `incrementalMarkStep` (`src/core/gc_trace_stw.zig:1102`)

- **签名**：`pub fn incrementalMarkStep(rt: *JSRuntime, budget_ns: u64) CollectError!bool`。
- **作用**：在当前增量周期推进一段前沿，返回是否已可进入remark。
- **实现**：断言active，创建declared_only collector并设shade_to_queue；drainSegmentedFrontier(budget_ns,true,false)，成功后increments加一，返回stack.len==0且queue.isEmpty。
- **所有权 / 错误 / 调用**：true不是周期已完成，也不表示weak处理/析构已发生。预算为软限制：每64个header检查时间，单个trace不被打断；maxInt(u64)不计时。错误上抛由runtime中止，失败切片不增加increments。

### `finishIncrementalCycle` (`src/core/gc_trace_stw.zig:1117`)

- **签名**：`pub fn finishIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize`。
- **作用**：完成remark与弱处理，建立待析构人口并关闭major退役事务。
- **实现**：断言active、collections加一；创建collector并重置普查计时。重新播种根、drain普通和barrier前沿、ephemeron，按开关做footprint/完整可达对照。关闭marking并断言前沿已清后processWeak；若地址集合不完整，abandon、请求重试、记录跳过sweep并返回0。否则要求旧morgue空：snapshotAllDoomed并扣bitmap字节，当场sweepExtents，condemnListSweep；计算仍计账doomed字节，初始化morgue游标/额度/pending与settled估计，同暂停sweepAtomTable。最后记阶段时间、clearYoungState、commit退役、衰减低收益历史、写last_report并可选审计，返回condemned。
- **所有权 / 错误 / 调用**：返回数是判死口径，不等于已析构对象数；大部分析构留给后续切片，但extent此时已释放、atom表也已修改。bitmap已扣字节不重复计入morgue.bytes。错误路径本函数不自行完整abort；weak处理在addressSetWhole检查前，返回0不能理解为完全无副作用。周期最终结果由runtime析构完成入口结算。

待析构顺序表 doomed_phase_kinds 当前列出 object、realm_context、module、function_bytecode、var_ref、big_int 六项；不能按旧注释称作“五趟”。destroy_clock_cadence=256 是析构时钟检查节奏，不是硬暂停上限。

DoomedStateSnapshot 保存 pending、nonempty_buckets、bucket_headers、cursor_present、doomed_blocks、deferred_finalizers、active_finalizer，分别反映容器与插件清理状态。SamePauseSink 无字段；FinishCondemnSink 的 doomed_bytes 默认零。CondemnedSliceResult 为 destroyed 与 morgue_empty，后者报告切片遍历是否结束，不能仅由本切片销毁数推断。

### `morgueIsEmpty` (`src/core/gc_trace_stw.zig:1305`)

- **签名**：`fn morgueIsEmpty(rt: *const JSRuntime) bool`。
- **作用**：判断各待析构表示是否全部为空。
- **实现**：依次检查morgue.cursor、block_heap.doomed_blocks、非block Object doomed数组以及所有kind桶；任一非空返回false，否则true。
- **所有权 / 错误 / 调用**：不检查pending、kind_pass、bytes/credit或延迟插件finalizer队列；因此它是结构人口判定，不是整个runtime所有清理工作完成。

### `doomedStateSnapshot` (`src/core/gc_trace_stw.zig:1332`)

- **签名**：`pub fn doomedStateSnapshot(rt: *const JSRuntime) DoomedStateSnapshot`。
- **作用**：从实际待析构容器生成只读状态快照。
- **实现**：非block doomed数组非空算一个bucket，数组长度计入bucket_headers；再数所有非空kind桶与链表节点，遍历doomed block链（link≤1结束）。另读取pending/cursor、延迟finalizer队列长度及active finalizer。
- **所有权 / 错误 / 调用**：doomed_blocks是block数，不是cell数；bucket_headers不含block位图中的对象。无分配，不修复损坏链，需稳定有效容器。

### `auditDeferredPayloadRootsBeforeBlockPublication` (`src/core/gc_trace_stw.zig:1371`)

- **签名**：`fn auditDeferredPayloadRootsBeforeBlockPublication(rt: *JSRuntime) void`。
- **作用**：在block重新可分配前验证延迟payload根仍存活。
- **实现**：invariantChecksEnabled为false直接返回；否则verifyDeferredClassPayloadRootLiveness结果交requireInvariant。
- **所有权 / 错误 / 调用**：失败输出诊断并panic，不返回CollectionError；本函数不执行block发布，必须由每个发布调用点在正确位置调用。

### `auditDoomedExitInvariant` (`src/core/gc_trace_stw.zig:1381`)

- **签名**：`pub fn auditDoomedExitInvariant(rt: *const JSRuntime) void`。
- **作用**：核验关闭morgue时没有遗留待析构人口。
- **实现**：审计关闭则无操作；先核验延迟payload根，即使pending仍真也执行。pending真则返回，否则morgueIsEmpty必须成立，不成立panic。
- **所有权 / 错误 / 调用**：不要求延迟finalizer队列为空，也不推断pending真时一定有人口；验证的是关闭方向的合同。

### `assertMorgueEmptyBeforeCondemnation` (`src/core/gc_trace_stw.zig:1390`)

- **签名**：`fn assertMorgueEmptyBeforeCondemnation(rt: *const JSRuntime) void`。
- **作用**：断言新判死事务开始前旧morgue已关闭且无残留。
- **实现**：两个std.debug.assert分别检查!pending与morgueIsEmpty。
- **所有权 / 错误 / 调用**：属于断言而非可恢复错误校验，不清任何旧状态；不能用于替代调用方先完成旧析构。

### `condemnIntoBucket` (`src/core/gc_trace_stw.zig:1401`)

- **签名**：`inline fn condemnIntoBucket(rt: *JSRuntime, header: *gc.Header) void`。
- **作用**：把已脱链的非Object判死载体加入对应kind桶。
- **实现**：读取kind并断言不是object，用listAddTailTraversalOwned追加到by_kind[kind]。
- **所有权 / 错误 / 调用**：不负责先脱主链、不设置pending、不析构；调用方保证节点已脱链。Object由block位图或非block侧表管理，不能放此桶。

### `condemnListSweep` (`src/core/gc_trace_stw.zig:1438`)

- **签名**：`fn condemnListSweep(rt: *JSRuntime, sink: anytype, young_only: bool) usize`。
- **作用**：对主链范围与非block Object侧表判死，并清除存活者young位。
- **实现**：young_only选择年轻后缀及保存的前驱，否则从主表sentinel开始。marked或pinned者清young并前进；死节点先sink.note，再detachCycleCandidateAfter并condemnIntoBucket，前驱不动。侧表逐下标遍历，minor过滤非young，存活者清young；死项sink.note后condemnNonBlockObject，swap-remove后不递增下标。
- **所有权 / 错误 / 调用**：返回判死header数，不包含block位图/extent处理。保留survivor sticky mark；sink是无错误回调，整函数不返回错误。主链年轻后缀必须有效，错误前驱为unreachable；不自行重置后缀游标或pending。

### `SamePauseSink.note` (`src/core/gc_trace_stw.zig:1505`)

- **签名**：`fn note(_: *const @This(), _: *JSRuntime, _: *gc.Header) void`。
- **作用**：为同暂停判死提供无需额外工作的sink接口。
- **实现**：函数体为空，忽略self/runtime/header。
- **所有权 / 错误 / 调用**：不执行析构；仅表示判死遍历不需要额外的字节普查或提前Shape摘索引工作，真正销毁在共同析构路径。

### `FinishCondemnSink.note` (`src/core/gc_trace_stw.zig:1515`)

- **签名**：`fn note(self: *@This(), rt: *JSRuntime, header: *gc.Header) void`。
- **作用**：记录增量finish仍待析构的字节，并提前摘除判死Shape索引。
- **实现**：doomed_bytes饱和累加heapByteSizeFromHeader；kind为shape时rt.shapes.delistCondemnedShape。
- **所有权 / 错误 / 调用**：在节点真正脱链前调用；不释放body。Shape索引必须在mutator恢复前移除，避免活对象重新采用已判死Shape。

### `destroyCondemnedSlice` (`src/core/gc_trace_stw.zig:1567`)

- **签名**：`fn destroyCondemnedSlice(rt: *JSRuntime, budget_ns: u64, sweep_string_extents: bool) CondemnedSliceResult`。
- **作用**：按统一顺序推进待析构人口，并保留预算中断后的恢复位置。
- **实现**：保存hot.phase，设tracer_destroy且defer恢复。先处理doomed block：只对takeDoomedFinalizerCell返回项执行Object或string/rope/string_buffer析构；随后先摘block doomed链再reclaimDoomedBlock，按开关检查alloc计数。可选全表sweepExtents。之后按kind_pass处理非block Object doomed数组，再realm/module/bytecode/var_ref/big_int，最后Shape桶；桶首摘链后设置sweep_current，适用kind先unlink计账再析构，清current。每256次显式析构/桶节点访问检查时间，超时保存适当cursor返回false，阶段遍历结束返回true。
- **所有权 / 错误 / 调用**：预算不是硬截止，block位图回收与可选extent sweep不按cell预算；单个析构不能中断。destroyed包含helper报告的回收数，bytecode桶明确不计，已finalizing的Shape跳过实际析构却仍进入计数。非block Object用pop顺序，列表从首节点消费。没有统一parked struct第二遍，不能照抄旧注释称每次free都被延后；morgue_empty只是遍历完成，不表示插件任务已清。

### `destroyCondemnedWhole` (`src/core/gc_trace_stw.zig:1745`)

- **签名**：`fn destroyCondemnedWhole(rt: *JSRuntime, sweep_string_extents: bool) usize`。
- **作用**：从初始kind游标同步耗尽共同析构路径。
- **实现**：kind_pass置0、cursor置null，调用destroyCondemnedSlice(maxInt(u64),sweep_string_extents)，断言morgue_empty并返回destroyed。
- **所有权 / 错误 / 调用**：不维护morgue.pending、累计destroyed或增量周期完成计数。max预算使时限通常不触发，但底层仍按cadence读时钟，并非完全无计时指令。

### `destroyDoomedSlice` (`src/core/gc_trace_stw.zig:1760`)

- **签名**：`pub fn destroyDoomedSlice(rt: *JSRuntime, budget_ns: u64) usize`。
- **作用**：推进一次增量析构，并在所有前置清理完成时关闭事务。
- **实现**：断言pending，调用共同析构且不全表sweep extent；普通累加morgue.destroyed，饱和累加doomed_destroyed_objects。容器未空则返回本片数。容器空且无待处理deferred payload finalizer时，审计根、publishCompletedHotBlocks、清pending/cursor、cycles_completed加一；最后做退出审计。
- **所有权 / 错误 / 调用**：有延迟finalizer时即使本片morgue_empty也保持pending，方法不执行这些回调。返回本片计数而非累计；atom sweep已在finish暂停执行，不在这里延后重做。

### `finishPendingDestruction` (`src/core/gc_trace_stw.zig:1793`)

- **签名**：`pub fn finishPendingDestruction(rt: *JSRuntime) void`。
- **作用**：同步推进不可回滚的待析构事务直至关闭。
- **实现**：while pending调用destroyDoomedSlice(maxInt)。有延迟payload任务则断言hot.phase==none，保存gc_running并暂置false，drainDeferredClassPayloadFinalizers后恢复；循环重试关闭事务，退出再审计。
- **所有权 / 错误 / 调用**：回调在共同析构返回并恢复phase后执行；active-job保护由runtime实现，临时gc_running=false不是允许任意重入收集。没有错误返回，完成意味着pending关闭，不代表此期间没有产生新的下一轮GC请求。

### `remarkBarrierQueueForTest` (`src/core/gc_trace_stw.zig:1818`)

- **签名**：`pub fn remarkBarrierQueueForTest(rt: *JSRuntime) CollectError!usize`。
- **作用**：测试专用：按最终 remark 的方式排空增量屏障队列，返回遍历到的灰色条目数。
- **实现**：非测试构建走 `@compileError("test-only helper")`；否则把私有栈绑定到 marking.queue 的段池，建 `.declared_only` collector（defer deinit），返回 drainBarrierQueue 的结果。
- **所有权 / 错误 / 调用**：只供构造 mutator 交错的测试使用，不是写屏障热路径；不设置或清除 marking active，也不做弱处理与判死。错误沿 CollectError 上抛，已写的标记与队列变动不回滚。

### `auditLiveObjectsResolve` (`src/core/gc_trace_stw.zig:1835`)

- **签名**：`fn auditLiveObjectsResolve(rt: *JSRuntime) usize`。
- **作用**：检查all迭代人口的精确header是否能由地址注册表确认。
- **实现**：遍历objectIterator(.all)，containsHeader失败则missing加一，最多输出8个地址/kind；返回总missing。
- **所有权 / 错误 / 调用**：与auditArenas的free-but-accounted检查互补。只核验枚举到的人口，不能发现同时漏出迭代器与地址表的分配；不修改登记。

Collector 持有借用rt/extra_roots、page_allocator支持的临时arena及work header数组，err锁存可失败visitor状态，report/exact_mark_count保存本轮诊断。conservative_on在init决定；shade_to_queue默认false，开启后将前沿放入Registry持久队列；minor_mode默认false，用于年轻symbol根等minor逻辑；atom_stamps_frozen默认false，诊断探测时阻止atom边改写正式周期戳。临时Collector与跨切片的Registry.marking不是同一份工作存储。

### `Collector.init` (`src/core/gc_trace_stw.zig:1881`)

- **签名**：`fn init(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) std.mem.Allocator.Error!Collector`。
- **作用**：建立一轮收集的临时状态并选择是否扫描保守根。
- **实现**：ArenaAllocator以page_allocator为backing，work为空，保存rt/extra_roots。生产构建conservative_on=!host_quiescent，不由scan参数关闭；测试构建以test_root_scan_override或scan是否engine_active决定。
- **所有权 / 错误 / 调用**：当前函数没有实际可失败分配，虽签名保留allocator error set；arena首次使用才申请内存。临时空间不经runtime MemoryAccount，不能把所有collector分配都记作JS堆压力。

### `Collector.deinit` (`src/core/gc_trace_stw.zig:1906`)

- **签名**：`fn deinit(self: *Collector) void`。
- **作用**：释放本轮collector arena的临时存储。
- **实现**：调用self.arena.deinit()。
- **所有权 / 错误 / 调用**：work backing随arena释放，不单独free header；没有把Collector重置为空，不能在销毁后复用旧work切片或承诺重复销毁。

### `Collector.allocator` (`src/core/gc_trace_stw.zig:1910`)

- **签名**：`fn allocator(self: *Collector) std.mem.Allocator`。
- **作用**：取得本轮arena的分配器接口。
- **实现**：返回self.arena.allocator()。
- **所有权 / 错误 / 调用**：借用arena状态，接口不能跨Collector销毁使用；不是persistent或JS堆账户allocator。

### `Collector.run` (`src/core/gc_trace_stw.zig:1914`)

- **签名**：`fn run(self: *Collector) CollectError!usize`。
- **作用**：按同步major顺序完成标记、弱处理与可选回收。
- **实现**：clearMarks，seedRoots并drain；详细模式记精确count。保守扫描启用则seedConservativeRoots/drain，再按详细模式记录两次count差。随后ephemeronFixedPoint、最终footprint、processWeak；地址集合不完整则置skipped并返回0，否则sweepUnmarked。
- **所有权 / 错误 / 调用**：弱处理已在地址完整性判定前发生，跳过sweep不等于无副作用。marked_conservative_extra的差值在最后ephemeron闭包前计算，不能等同完整保守传递闭包。失败try上抛，由外层收尾事务。

### `Collector.clearMarks` (`src/core/gc_trace_stw.zig:1955`)

- **签名**：`fn clearMarks(self: *Collector) void`。
- **作用**：为全堆标记建立新epoch。
- **实现**：block_heap.beginMajor()后advanceHeaderMarkEpoch()。
- **所有权 / 错误 / 调用**：不是逐个header将位写零，也不重置collector.work/report；epoch推进及其溢出处理由底层负责，调用方须协调前沿与代际事务。

### `Collector.clearYoungMarks` (`src/core/gc_trace_stw.zig:1968`)

- **签名**：`inline fn clearYoungMarks(self: *Collector) void`。
- **作用**：清除本轮minor所使用的young人口标记。
- **实现**：遍历young_list并setHeaderUnmarked，再clearYoungBlockMarksStw和clearYoungExtentMarksStw。
- **所有权 / 错误 / 调用**：不会调用全堆beginMajor或advanceHeaderMarkEpoch；block与extent有专用批处理。此操作不完成提升、不清young人口或记忆集合。

### `Collector.countMarked` (`src/core/gc_trace_stw.zig:1977`)

- **签名**：`fn countMarked(self: *Collector) usize`。
- **作用**：统计all迭代人口中当前已标记项。
- **实现**：遍历objectIterator(.all)，headerMarked为真则普通加一。
- **所有权 / 错误 / 调用**：只读冷普查，返回次数而非字节；all人口不是独立raw分配全集，普查调用本身可留下保守栈残留。

### `Collector.countMarkedYoung` (`src/core/gc_trace_stw.zig:1986`)

- **签名**：`fn countMarkedYoung(self: *Collector) usize`。
- **作用**：统计young迭代人口中已标记项。
- **实现**：遍历objectIterator(.young)，按headerMarked计数。
- **所有权 / 错误 / 调用**：该迭代器不含extent表人口，因此不能称为所有年轻分配的完整marked数量；没有额外补扫extent，不修改mark或young。

### `Collector.shadeExact` (`src/core/gc_trace_stw.zig:1998`)

- **签名**：`fn shadeExact(self: *Collector, header: *gc.Header) void`。
- **作用**：标记一条已具备有效typed header契约的强引用并安排其边遍历。
- **实现**：已有err、已marked、未heap_accounted或headerCondemned均返回；否则先setHeaderMarked（全函数只此一次）。shade_to_queue时，非frontierEpochSafe只允许Shape/Realm并直接同步traceHeader（错误锁存）；其它先转frontierSafeHeaderAfterMarkClaim，优先私有stack.push，失败再queue.push，两者均失败锁存OOM。同步模式append到arena work，失败锁存错误。
- **所有权 / 错误 / 调用**：void接口通过self.err传播失败；mark在入队前已写，失败不撤销，因此调用方不得忽略err继续sweep。不进行任意地址验证，保守候选须先解析。它不直接按minor_mode过滤old，而依赖已有标记等机制。

### `Collector.visitValue` (`src/core/gc_trace_stw.zig:2063`)

- **签名**：`pub fn visitValue(self: *Collector, val: *JSValue) void`。
- **作用**：枚举一个JSValue中的GC载体引用。
- **实现**：cycleMarkHeader返回header时调用shadeExact，否则无操作。
- **所有权 / 错误 / 调用**：不修改slot值，不复制/释放JSValue；错误记录在collector.err。具体可追踪tag由cycleMarkHeader定义。

### `Collector.visitObject` (`src/core/gc_trace_stw.zig:2067`)

- **签名**：`pub fn visitObject(self: *Collector, obj_ptr: *?*Object) void`。
- **作用**：访问一个可空Object槽的强引用。
- **实现**：解引用obj_ptr，非空则取gcHeader并shadeExact。
- **所有权 / 错误 / 调用**：不重写对象指针或获取宿主pin，空槽无操作。

### `Collector.visitShape` (`src/core/gc_trace_stw.zig:2071`)

- **签名**：`pub fn visitShape(self: *Collector, shape_ref: *shape.Shape) void`。
- **作用**：访问Shape引用并先检查已知非block标记。
- **实现**：headerMarkedKnownNonBlock为真直接返回，否则shadeExact(&shape_ref.header)。
- **所有权 / 错误 / 调用**：要求有效Shape引用；快速检查不枚举Shape边，首次标记的后续处理由shadeExact模式决定。

### `Collector.visitRealm` (`src/core/gc_trace_stw.zig:2076`)

- **签名**：`pub fn visitRealm(self: *Collector, ctx_ptr: *?*context_mod.RealmContext) void`。
- **作用**：访问可空RealmContext槽。
- **实现**：非空ctx调用shadeExact(&ctx.header)。
- **所有权 / 错误 / 调用**：不修改槽或增减Realm拥有关系，空槽忽略。

### `Collector.visitModule` (`src/core/gc_trace_stw.zig:2080`)

- **签名**：`pub fn visitModule(self: *Collector, record: *module_mod.ModuleRecord) void`。
- **作用**：访问ModuleRecord强引用。
- **实现**：调用shadeExact(&record.header)。
- **所有权 / 错误 / 调用**：record为非空有效借用，函数不注册module或改变module状态。

### `Collector.storageCell` (`src/core/gc_trace_stw.zig:2102`)

- **签名**：`pub fn storageCell(self: *Collector, header: *gc.Header) void`。
- **作用**：对无出边的owned storage cell执行叶子标记与代际退役。
- **实现**：按err、marked、未发布、condemned顺序跳过；安全构建断言kindIsOwnedStorageCell和frontierEpochSafe；setHeaderMarked后直接retireTracedYoung。
- **所有权 / 错误 / 调用**：不入队、不分配、不读取storage内容。只适用于叶子storage种类，不能替代有出边对象遍历；extent标记由Registry路由，退役由相应机制处理。

### `Collector.visitAtom` (`src/core/gc_trace_stw.zig:2126`)

- **签名**：`pub fn visitAtom(self: *Collector, id: atom_mod.Atom) void`。
- **作用**：处理atom id强边，并按atom种类保留需要的body。
- **实现**：atom_stamps_frozen时调用atomEdgeBodyWithoutStamp并shade返回body；否则用当前block epoch调用markAtomAtEpoch，再shade可选body。
- **所有权 / 错误 / 调用**：冻结模式仍可能标记body，但不改atom表epoch。string atom的可丢弃缓存不因id边自动保活；这里不释放atom，不把id当header地址。

### `Collector.visitWeakCollectionEntry` (`src/core/gc_trace_stw.zig:2139`)

- **签名**：`pub fn visitWeakCollectionEntry(self: *Collector, entry: *object_payloads.WeakCollectionEntry) void`。
- **作用**：在强边遍历阶段忽略弱集合项。
- **实现**：显式忽略self与entry，函数体不执行标记。
- **所有权 / 错误 / 调用**：这是弱语义的必要分工，值的保留由ephemeronFixedPoint在table/key条件满足时处理；不是删除entry。

### `Collector.visitFinalizationCell` (`src/core/gc_trace_stw.zig:2144`)

- **签名**：`pub fn visitFinalizationCell(self: *Collector, entry: *object_payloads.FinalizationRegistryCell) void`。
- **作用**：按FinalizationRegistry cell状态保留held_value强边。
- **实现**：仅entry.keepsHeldValuesAlive()为真时visitValue(&held_value)。
- **所有权 / 错误 / 调用**：不在此标记target或unregister token，不执行清理回调，也不改变cell状态；精确条件由keepsHeldValuesAlive定义。

### `Collector.seedRoots` (`src/core/gc_trace_stw.zig:2148`)

- **签名**：`fn seedRoots(self: *Collector) CollectError!void`。
- **作用**：将pin、运行时精确根及额外值根接入本轮标记。
- **实现**：逐项处理pins：construction root直接setHeaderMarked并traceDetachedGeneratorShellEdges，仅heap_accounted时retireTracedYoung；其它调用shadeExact。检查err后构造RootVisitor并traceActiveRoots；minor_mode额外traceYoungSymbolBodies；extra_roots存在则traceValueRootFrameChain。
- **所有权 / 错误 / 调用**：context成员链不在这里自动成为强根。构造中shell不能按普通Object读取未初始化Shape；未发布shell不执行年轻代退役。每步失败向上传播，已写标记不回滚，visitor/adaptor只在本次同步调用中借用。

### `Collector.Adaptor.visitValue` (`src/core/gc_trace_stw.zig:2182`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *JSValue) runtime_mod.RootTraceError!void`。
- **作用**：把RootVisitor的值槽回调接到Collector并传播锁存错误。
- **实现**：对context作对齐检查和指针转换，调用collector.visitValue(slot)，随后检查collector.err并返回其中错误。
- **所有权 / 错误 / 调用**：借用adaptor和槽，不改写值或取得拥有权；用于seedRoots中的RootVisitor。

### `Collector.Adaptor.visitObject` (`src/core/gc_trace_stw.zig:2188`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*Object) runtime_mod.RootTraceError!void`。
- **作用**：把RootVisitor的可空对象槽回调接到Collector。
- **实现**：还原Adaptor指针，调用collector.visitObject(slot)，再将collector.err转换为RootTraceError返回。
- **所有权 / 错误 / 调用**：空对象由visitObject处理；不改写槽、不获取pin。

### `Collector.Adaptor.visitHeader` (`src/core/gc_trace_stw.zig:2194`)

- **签名**：`fn visitHeader(context: *anyopaque, header: *const gc.Header) runtime_mod.RootTraceError!void`。
- **作用**：把精确header根交给标记器。
- **实现**：还原Adaptor，对header执行constCast后调用shadeExact，再检查并返回collector.err。
- **所有权 / 错误 / 调用**：constCast允许更新GC标记，不转移header存储所有权；输入须为有效精确header，不是任意候选地址。

### `Collector.Adaptor.visitAtom` (`src/core/gc_trace_stw.zig:2200`)

- **签名**：`fn visitAtom(context: *anyopaque, id: atom_mod.Atom) runtime_mod.RootTraceError!void`。
- **作用**：把atom根交给Collector并暴露标记错误。
- **实现**：还原Adaptor，调用collector.visitAtom(id)，随后返回可选collector.err。
- **所有权 / 错误 / 调用**：atom的stamp/body处理由visitAtom及atom_stamps_frozen决定；本回调不释放atom。

### `Collector.shadeConservativeCandidate` (`src/core/gc_trace_stw.zig:2227`)

- **签名**：`fn shadeConservativeCandidate(context: *anyopaque, header: *gc.Header) void`。
- **作用**：对保守扫描已解析出的header执行标记回调。
- **实现**：已有err则退出；拒绝地址小于4096或不满足Header对齐的候选，其余调用shadeExact。
- **所有权 / 错误 / 调用**：低地址与对齐检查不是地址有效性的完整验证，候选解析由扫描器负责。void回调通过collector.err锁存错误，不获得存储拥有权。

### `Collector.recordConservativeCandidate` (`src/core/gc_trace_stw.zig:2239`)

- **签名**：`fn recordConservativeCandidate(context: *anyopaque, header: *gc.Header) void`。
- **作用**：标记保守候选，并在诊断启用时记录本次直接新增的mark。
- **实现**：使用与shadeConservativeCandidate相同的err/低地址/对齐过滤，保存was_marked后shadeExact；编译期开启roots_diag且标记由未设置变为设置时，以diagCurrentWord调用noteDirect。
- **所有权 / 错误 / 调用**：用于computeFullReachable的保守阶段；记录的是mark变化，不保证排队或后续遍历成功，也不包含间接子节点。错误仍留在collector.err。

### `Collector.seedConservativeRoots` (`src/core/gc_trace_stw.zig:2253`)

- **签名**：`fn seedConservativeRoots(self: *Collector) CollectError!void`。
- **作用**：扫描寄存器与栈中的保守根并接入标记器。
- **实现**：调用spillRegistersAndScan，传入runtime、report.conservative、shadeConservativeCandidate及self上下文；扫描返回后检查collector.err。
- **所有权 / 错误 / 调用**：扫描统计写入本轮report，标记失败向上返回；是否调用这条路径由上层决定，此函数不自行判断scan_conservative。

### `Collector.drainBarrierQueue` (`src/core/gc_trace_stw.zig:2266`)

- **签名**：`fn drainBarrierQueue(self: *Collector) CollectError!usize`。
- **作用**：排空标记屏障积累的分段前沿及其同步work。
- **实现**：调用drainSegmentedFrontier(maxInt(u64), false, true)：不设时间预算、不预取，每个前沿header后排空普通work。
- **所有权 / 错误 / 调用**：返回分段前沿处理的header数，不包含嵌套drain处理的work项；这是收集器排空入口，不是属性写屏障热路径回调。失败向上传播，不通过全堆重扫掩盖。

### `Collector.drainSegmentedFrontier` (`src/core/gc_trace_stw.zig:2284`)

- **签名**：`fn drainSegmentedFrontier( self: *Collector, budget_ns: u64, comptime prefetch: bool, comptime drain_work: bool, ) CollectError!usize`。
- **作用**：遍历分段前沿直到为空或软预算检查触发。
- **实现**：先checkFrontierFailure；从stack/queue取header，traced加一并traceHeader，检查self.err，可选drain普通work，再查队列失败。每64项检查elapsed≥budget；budget=maxInt(u64)时不读预算时钟。返回已处理header数。
- **所有权 / 错误 / 调用**：budget=0也可能处理64项，少于64项会直接排空；不保证暂停不超过预算。prefetch/drain_work均编译期参数。错误保留已有标记/队列变动，不是事务回滚。

### `Collector.drain` (`src/core/gc_trace_stw.zig:2312`)

- **签名**：`fn drain(self: *Collector) CollectError!void`。
- **作用**：以LIFO顺序排空同步标记work列表。
- **实现**：反复work.pop，逐项try traceHeader，并在每次成功返回后再次检查self.err；遍历新增的work也继续处理。
- **所有权 / 错误 / 调用**：不排空分段队列，不设置时间预算。失败时当前项已经弹出，已有标记和未处理work不回滚；空work时不单独检查既有err。

### `Collector.traceHeader` (`src/core/gc_trace_stw.zig:2319`)

- **签名**：`fn traceHeader(self: *Collector, header: *gc.Header) CollectError!void`。
- **作用**：遍历一个已进入标记流程的header的强边，成功后执行年轻代退役。
- **实现**：先try traceHeaderEdges，再检查self.err；两者成功才调用retireTracedYoung(header)。
- **所有权 / 错误 / 调用**：退役绑定到边已处理，而不是仅仅设置mark；遍历失败不执行退役。不释放header，也不自行获取mark。

### `Collector.traceRememberedOwner` (`src/core/gc_trace_stw.zig:2351`)

- **签名**：`fn traceRememberedOwner(self: *Collector, header: *gc.Header) CollectError!void`。
- **作用**：强制遍历remembered owner的边，不据此认定owner本身存活。
- **实现**：Object若是detached generator shell，只traceDetachedGeneratorShellEdges，捕获错误写入self.err，检查后返回；其它直接try traceHeaderEdges并检查self.err。
- **所有权 / 错误 / 调用**：不调用traceHeader、不设置owner的mark，也不retireTracedYoung。构造时记录的owner在发布后可能是young；只有真正经标记前沿证明存活的路径才负责退役。

### `Collector.ephemeronFixedPoint` (`src/core/gc_trace_stw.zig:2377`)

- **签名**：`fn ephemeronFixedPoint(self: *Collector) CollectError!void`。
- **作用**：在弱集合holder与key都存活时保留value，并迭代至没有新的候选value需要处理。
- **实现**：每轮遍历weak_reference_holder_head，仅处理已marked holder的collection payload；keyIsMarked为真、value有cycleMarkHeader且child尚未marked时调用shadeExact，并增加ephemeron_values_shaded。检查err，drain同步work，增加ephemeron_rounds；计数与轮前相等时结束。
- **所有权 / 错误 / 调用**：至少执行一轮，包括最终无新增轮。values_shaded是调用shadeExact的次数，未发布或condemned等被拒候选不一定获得mark，因此不能当作成功新增mark数。函数依赖正常弱项/发布不变量，不单独保证异常候选下收敛；错误上抛，已有标记不回滚。

### `Collector.processWeak` (`src/core/gc_trace_stw.zig:2403`)

- **签名**：`fn processWeak(self: *Collector) void`。
- **作用**：按标记结果清除宿主弱根，并清理存活holder的弱引用内容。
- **实现**：先遍历weak_root_slots，对非空且keyIsMarked为假的identity调用clearWeakRootSlot(slot,true)；然后沿holder链保存next，仅对已marked holder调用sweepHolder。局部finalization_enqueue_blocked初始化为false并传入。
- **所有权 / 错误 / 调用**：clearWeakRootSlot先清空并释放弱identity，再可能同步调用宿主通知回调；不是纯只读检查。此函数不返回错误；未marked holder留给后续销毁路径。当前sweepHolder只读blocked标志，正常调用不会把它改为true。

### `Collector.sweepHolder` (`src/core/gc_trace_stw.zig:2422`)

- **签名**：`fn sweepHolder(self: *Collector, holder: *Object, finalization_enqueue_blocked: *bool) void`。
- **作用**：清理一个存活holder的WeakRef、弱集合和FinalizationRegistry内容。
- **实现**：WeakRef死target清空identity；弱集合稳定压缩保留key仍marked的entry，死key releaseWeakIdentity，发生删除才缩短slice并clearCollectionIndex。FinalizationRegistry先清除死亡unregister token；无target或target仍marked的cell保留；死target且已queued的cell跳过；active变pending_enqueue，blocked时保留，否则先将原槽state写为queued，再enqueueFinalizationCleanup，最后将局部cell置queued并destroy。压缩cells后pruneBorrowedReferenceHolderIfEmpty。
- **所有权 / 错误 / 调用**：删除弱集合项不逐项释放JSValue，也不在这里缩减存储容量。cell.destroy释放弱identity；queued状态避免重复释放已消费的job预留。先写原槽tombstone用于防止重入重复消费预留；cleanup回调仅入job队列，不在此执行。正常enqueue使用预留槽；无预留的teardown回退可能吞掉分配错误，所以void返回不等于任务一定入队。

### `Collector.stampYoungBlockCorpses` (`src/core/gc_trace_stw.zig:2505`)

- **签名**：`fn stampYoungBlockCorpses(self: *Collector) void`。
- **作用**：按年轻block的doomed位图给死亡cell登记condemnation。
- **实现**：遍历young_blocks并提前保存young_link；逐word枚举置位bit，越过cell_count则停止该word；由cellBase加metadata_prefix_size得到header。未heap_accounted、已condemned或pinned均跳过，其余detachBlockObjectCandidate。
- **所有权 / 错误 / 调用**：依赖此前snapshotYoungDoomed生成死亡位图，不在这里重新检查marked或young，也不访问存活位对应header；不销毁或返还cell、不调整字节账。正确性依赖old及pinned cell的mark不变量。

### `Collector.sweepUnmarkedYoung` (`src/core/gc_trace_stw.zig:2528`)

- **签名**：`fn sweepUnmarkedYoung(self: *Collector, full_reachable: ?*const FullReachable) usize`。
- **作用**：执行minor的死亡候选核查、condemnation及同步回收，并在析构前关闭本轮年轻代。
- **实现**：full_reachable存在或minor_audit开启时先收集未marked且未pinned的young_block与young_list指针；append失败直接返回0。否则snapshotYoungDoomed并debitBlockBytes、stampYoungBlockCorpses，再condemnListSweep(young_only=true)。可选full trace对账只对precise违规触发verify_minor_fatal；minor_audit另行auditCondemnedYoung。诊断快照分支随后按block/非block/其它kind登记死亡对象并snapshot/debit。切换tracer_destroy后先sweepYoungExtents，断言young_publications未变化；诊断分支bulk promote survivors，再closeYoungGeneration，最后destroyCondemnedWhole(false)。
- **所有权 / 错误 / 调用**：返回extent与同步销毁路径合计的reclaimed计数，不能解释为所有死亡header的精确数量；具体计数受析构辅助函数口径影响。生产路径不分配候选快照，诊断分支的OOM没有错误返回而是0。extent先清理，代际先关闭，后续析构中新发布的对象属于下一年轻代；survivor保留mark。phase通过defer恢复；候选对账快照不包含extent人口，不能把它说成全部young载体的独立验证。

### `Collector.sweepUnmarked` (`src/core/gc_trace_stw.zig:2708`)

- **签名**：`fn sweepUnmarked(self: *Collector) usize`。
- **作用**：对完整标记后未存活载体登记死亡并同步执行销毁。
- **实现**：遍历dead_block；pinned header仅清young并跳过，其余detachBlockObjectCandidate。snapshotAllDoomed并debitBlockBytes，condemnListSweep(false)处理非block人口；resetYoungSuffix后切换tracer_destroy，destroyCondemnedWhole(true)，随后sweepAtomTable。无pending deferred class payload finalizer才publishCompletedHotBlocks。
- **所有权 / 错误 / 调用**：phase由defer恢复。返回销毁辅助函数的garbage_count，不包括atom表清理计数，也不是单纯按未marked header数计算。block存储发布与析构完成分开，仍有延迟payload finalizer时不能立即发布；pin的保活还依赖此前根标记。

### `Collector.auditCondemnedYoung` (`src/core/gc_trace_stw.zig:2759`)

- **签名**：`fn auditCondemnedYoung(self: *Collector, doomed_items: []const *gc.Header) void`。
- **作用**：诊断非候选owner是否声明了指向本轮young死亡候选的边。
- **实现**：objectIterator(.all)遍历header，线性排除doomed_items中成员；记录owner kind/young并扫描remembered表判断membership，再按Object、Shape、VarRef、FunctionBytecode、Realm、Module分派Audit visitor。bytecode这里只查realm与cpool；其它kind不遍历。
- **所有权 / 错误 / 调用**：并未要求owner marked，old或不在候选集不等于已被本轮证明存活。共享声明边枚举，漏声明边、native槽、atom边和FinalizationRegistry held_value不在这套检查的完整覆盖内；fallible遍历错误被catch丢弃。无输出只说明已走到的边没有命中传入候选集，不能证明全图安全；启用minor_audit_fatal时命中panic。

### `Collector.Audit.hit` (`src/core/gc_trace_stw.zig:2768`)

- **签名**：`fn hit(a: *@This(), h: ?*gc.Header) void`。
- **作用**：检查一个可空child是否属于传入死亡候选集，命中时打印owner与child诊断。
- **实现**：空header退出；线性查doomed指针相等。仅child实际为Object时读取class/payload。owner为Object时进一步搜索promise、dense、ordinary、intrinsic capability、iterator cache和属性槽，为where与atom提供提示；打印细节和通用边信息，minor_audit_fatal时panic，否则返回。
- **所有权 / 错误 / 调用**：where是启发式标签，多处匹配会覆盖前值，不是完整边路径或唯一来源；同一边多次访问可重复报告。不会标记child、修复屏障或移除死亡候选；读取对象布局依赖调用时header/payload有效。

### `Collector.Audit.visitValue` (`src/core/gc_trace_stw.zig:2892`)

- **签名**：`pub fn visitValue(a: *@This(), val: *JSValue) void`。
- **作用**：检查JSValue所指载体是否在死亡候选中。
- **实现**：将val.cycleMarkHeader()交给hit，非GC值产生null并被忽略。
- **所有权 / 错误 / 调用**：不改写值、不设置mark；只做诊断。

### `Collector.Audit.visitObject` (`src/core/gc_trace_stw.zig:2895`)

- **签名**：`pub fn visitObject(a: *@This(), obj_ptr: *?*Object) void`。
- **作用**：检查可空Object槽的目标。
- **实现**：槽非空时取gcHeader并hit，空槽无操作。
- **所有权 / 错误 / 调用**：借用槽和对象，不保活或修改它们。

### `Collector.Audit.visitShape` (`src/core/gc_trace_stw.zig:2898`)

- **签名**：`pub fn visitShape(a: *@This(), sh: *shape.Shape) void`。
- **作用**：检查Shape强边是否指向死亡候选。
- **实现**：调用hit(&sh.header)。
- **所有权 / 错误 / 调用**：不递归遍历Shape，Shape自己的边在外层owner遍历中另行检查。

### `Collector.Audit.visitRealm` (`src/core/gc_trace_stw.zig:2901`)

- **签名**：`pub fn visitRealm(a: *@This(), ctx_ptr: *?*context_mod.RealmContext) void`。
- **作用**：检查可空RealmContext槽的目标。
- **实现**：非空时hit(&c.header)。
- **所有权 / 错误 / 调用**：不改槽或Realm拥有关系，空槽忽略。

### `Collector.Audit.visitModule` (`src/core/gc_trace_stw.zig:2904`)

- **签名**：`pub fn visitModule(a: *@This(), record: *module_mod.ModuleRecord) void`。
- **作用**：检查ModuleRecord边的目标。
- **实现**：调用hit(&record.header)。
- **所有权 / 错误 / 调用**：只比较候选并可能报告，不执行模块代码或遍历其子边。

### `Collector.Audit.storageCell` (`src/core/gc_trace_stw.zig:2907`)

- **签名**：`pub fn storageCell(a: *@This(), header: *gc.Header) void`。
- **作用**：将owned storage cell边纳入死亡候选检查。
- **实现**：直接hit(header)。
- **所有权 / 错误 / 调用**：此处不设置叶子mark或执行退役，区别于Collector.storageCell。

### `Collector.Audit.visitWeakCollectionEntry` (`src/core/gc_trace_stw.zig:2910`)

- **签名**：`pub fn visitWeakCollectionEntry(_: *@This(), _: *object_payloads.WeakCollectionEntry) void`。
- **作用**：在这套诊断visitor中忽略弱集合项。
- **实现**：空函数体，两个参数均不使用。
- **所有权 / 错误 / 调用**：不检查key或value，也不执行ephemeron条件推导；不能据此审计弱集合保活闭包。

### `Collector.Audit.visitFinalizationCell` (`src/core/gc_trace_stw.zig:2911`)

- **签名**：`pub fn visitFinalizationCell(_: *@This(), _: *object_payloads.FinalizationRegistryCell) void`。
- **作用**：在这套诊断visitor中忽略FinalizationRegistry cell。
- **实现**：空函数体，不读取cell状态和held_value。
- **所有权 / 错误 / 调用**：包括正常Collector会保活的held_value也未在此检查，这是该诊断的覆盖限制，不代表held_value是弱引用。

### `keyIsMarked` (`src/core/gc_trace_stw.zig:2972`)

- **签名**：`fn keyIsMarked(rt: *const JSRuntime, identity: usize) bool`。
- **作用**：将弱identity解析为仍存在的对象或symbol body，查询本轮mark。
- **实现**：低位为1表示symbol：右移取atom id，越过Atom范围、kind不是symbol、无live body均false，其余headerMarked。低位为0则liveObjectFromWeakIdentity解析对象，失败false，成功查询gcHeader标记。
- **所有权 / 错误 / 调用**：不是对identity数值做裸指针解引用，也不因为弱引用持有identity就保活对象；只查询，不设置mark或增加弱引用计数。

## 覆盖核对

- 清单函数数: 153（`src/core/gc_generation.zig` 25 + `src/core/gc_incremental.zig` 8 + `src/core/gc_mark_queue.zig` 29 + `src/core/gc_trace_stw.zig` 91）
- 本文标题覆盖: 153
- 未覆盖: 无
