# 09 — Conservative scan / address registry

本文件覆盖生产根网：native 栈/寄存器 conservative 扫描，以及页基数地址 → 分配物查找。候选字从不被当成 header 解引用。

函数级展开。总图见 [09-gc.md](09-gc.md)。写作规范见 [_spec.md](_spec.md)。

## `src/core/gc_address_registry.zig`

保守候选的地址验证表。classed block cell 和 slab 由已知映射/arena 几何解析，extent 由 block_heap 页索引解析；standalone prefix 的其它分配才进入本表 by_header/pages。先证明地址属于登记人口，再读取 prefix，不将原始候选整数直接解引用成 header。

page_shift/page_size 别名来自 gc_block_heap 的统一页网格。Occupant 保存 [lo,hi) 区间与 ptr 身份；PageBucket 是 occupant 动态数组。VerifyError 包含 AddressIndexMissingPage、AddressIndexOrphanPage、AddressIndexDuplicatePageEntry、AddressIndexRangeMismatch、AddressScanFilterMissing、AddressBoundsMissing。

Table.by_header 保存 standalone 权威项，pages 将区间展开到每个覆盖页，arenas 只登记 slab arena 基址。bounds_lo 初始 maxInt、bounds_hi 初始零，后续只扩不缩；允许陈旧宽窗口。block_heap 为可空借用指针，不由 Table 销毁。scan_filter 是 arena/page 基址按位 OR 的预过滤，block 另有独立过滤位；二者不能互相替代。

removes_since_rehash 的最高两位分别保存 arenas/occupants incomplete 状态，低位是删除预算计数。插入失败不总在同一层自动置位：noteArenaCreated 会设置 arena 标志，standalone insert 的调用方须在错误后 noteFailedInsert。完整性未恢复前，保守解析可能漏根，不能据残缺索引安全 sweep。

ScanFilter 保存 address_bits、block_bits、bounds_lo、bounds_hi 四个扫描期副本，由 rebuildScanFilter 在扫描前生成。扫描回调可改其它 runtime 状态，但不得使这些副本遗漏新加入的解析人口。Sync 是 resyncArenas 的局部补登记上下文；Audit 是空闲 arena block 检查的局部计数，均不是 tracing visitor。

### `Occupant.gcHeader` (`src/core/gc_address_registry.zig:40`)

- **签名**：`pub fn gcHeader(self: Occupant) *gc.Header`。
- **作用**：将登记的整数身份转换为 header 指针。
- **实现**：返回 @ptrFromInt(ptr)。
- **所有权 / 错误 / 调用**：不解引用、不验证范围或存活；返回借用，不转移分配所有权。

### `Table.arenasIncomplete` (`src/core/gc_address_registry.zig:138`)

- **签名**：`pub inline fn arenasIncomplete(self: *const Table) bool`。
- **作用**：查询 slab arena 集合是否标记为不完整。
- **实现**：读取 removes_since_rehash 的最高位。
- **所有权 / 错误 / 调用**：只读状态位，不遍历验证实际集合。

### `Table.setArenasIncomplete` (`src/core/gc_address_registry.zig:142`)

- **签名**：`inline fn setArenasIncomplete(self: *Table, value: bool) void`。
- **作用**：设置或清除 arena 不完整标志。
- **实现**：按 value 对最高位执行 OR 或 AND 取反。
- **所有权 / 错误 / 调用**：保留另一状态位及低位移除计数；不修复缺失 arena。

### `Table.occupantsIncomplete` (`src/core/gc_address_registry.zig:150`)

- **签名**：`pub inline fn occupantsIncomplete(self: *const Table) bool`。
- **作用**：查询 standalone occupant 登记是否标记为不完整。
- **实现**：读取 removes_since_rehash 的次高位。
- **所有权 / 错误 / 调用**：只查询锁存状态，不执行重新登记。

### `Table.setOccupantsIncomplete` (`src/core/gc_address_registry.zig:154`)

- **签名**：`pub inline fn setOccupantsIncomplete(self: *Table, value: bool) void`。
- **作用**：设置或清除 occupant 不完整状态。
- **实现**：按 value 设置或清 removes_since_rehash 次高位。
- **所有权 / 错误 / 调用**：不影响 arena 标志或移除计数；清位本身不是完整性证据。

### `Table.noteArenaCreated` (`src/core/gc_address_registry.zig:171`)

- **签名**：`pub fn noteArenaCreated(self: *Table, allocator: std.mem.Allocator, base: usize) void`。
- **作用**：登记一个 slab arena，使其地址可安全进入几何解析。
- **实现**：arenas.put 失败时置 arenasIncomplete 并返回；成功则向外扩 bounds 到 base..base+arena_size+1。
- **所有权 / 错误 / 调用**：不抛分配错误，但缺失登记会禁止安全 sweep，需调用方处理粘性状态。+1 接纳尾块 one-past-end；不在此刷新 scan_filter。

### `Table.resyncArenas` (`src/core/gc_address_registry.zig:192`)

- **签名**：`pub fn resyncArenas(self: *Table, allocator: std.mem.Allocator, slab: *Slab) bool`。
- **作用**：遍历 slab 补登记缺失 arena。
- **实现**：建立 Sync{table,allocator,ok=true}，slab.forEachArena 调 visit；所有插入成功才清 arenasIncomplete，返回 ok。
- **所有权 / 错误 / 调用**：保留已有登记和成功补入项，不删多余旧项。失败只保留原不完整标志，不主动将原 false 改 true；预期在已标不完整时调用。

### `Table.Sync.visit` (`src/core/gc_address_registry.zig:197`)

- **签名**：`fn visit(ctx: *anyopaque, base: usize) void`。
- **作用**：为 resyncArenas 补入一个缺失 base。
- **实现**：已在 arenas 中则返回；put 失败将局部 ok=false，否则扩展 bounds，末端包括 +1。
- **所有权 / 错误 / 调用**：slab.forEachArena 回调，不是 GC trace visitor；不重新计算已登记 arena 的边界，也不直接修改粘性位。

### `Table.noteArenaReleased` (`src/core/gc_address_registry.zig:217`)

- **签名**：`pub fn noteArenaReleased(self: *Table, base: usize) void`。
- **作用**：撤销已释放 arena 的地址成员资格。
- **实现**：调用 arenas.remove(base)，忽略是否命中。
- **所有权 / 错误 / 调用**：不释放 arena 本身，不缩 bounds，不刷新 scan_filter；旧宽边界/多余过滤位只增加探测，集合才是读内存前的权威。

### `Table.forEachGcObjectInArena` (`src/core/gc_address_registry.zig:233`)

- **签名**：`fn forEachGcObjectInArena( self: *Table, addr: usize, context: *anyopaque, visit: *const fn (*anyopaque, *gc.Header) void, ) usize`。
- **作用**：解析 addr 及 addr-1 所属 slab block，并回调已发布载体。
- **实现**：arena 集为空返回零；每次先按 arena_size 对齐并确认 base 在集合，再 userPtrWithinArena 解析。要求 heap_accounted，同一 user 去重后 visit；addr 非零才尝试前一字节。
- **所有权 / 错误 / 调用**：返回实际回调次数；几何可接纳 size class 尾部 slack，偏向保留。只在集合确认后读 prefix，不把候选字直接当 header。

### `Table.auditArenas` (`src/core/gc_address_registry.zig:272`)

- **签名**：`pub fn auditArenas(self: *Table) usize`。
- **作用**：查找已登记 arena 中错误残留 heap_accounted 的空闲块。
- **实现**：遍历 arenas，对每个 arena 调 Slab.forEachArenaBlock 与 Audit.visit，返回 violations。
- **所有权 / 错误 / 调用**：此实现只检查 free-but-accounted 方向；不会证明每个存活对象都能被解析，也不会发现根本未登记的 arena。函数本身不判断环境变量，是否启用由调用方决定。

### `Table.Audit.visit` (`src/core/gc_address_registry.zig:277`)

- **签名**：`fn visit(ctx: *anyopaque, user: [*]u8, is_free: bool) void`。
- **作用**：累计并有限输出空闲 slab block 的已计账残留。
- **实现**：非 free 或未 heap_accounted 直接返回；否则 violations/free_but_accounted 加一。前 8 次打印 user 地址、kind 和 lifetime word，并递增 reported。
- **所有权 / 错误 / 调用**：仅修改局部 Audit 计数，不修复 prefix；属于 arena block 审计回调。打印失败不改变违规计数。

### `Table.verifyIndex` (`src/core/gc_address_registry.zig:314`)

- **签名**：`pub fn verifyIndex(self: *Table, verify_scan_cache: bool) VerifyError!void`。
- **作用**：交叉验证 standalone 主表、页桶以及可选扫描缓存。
- **实现**：by_header 项须 key==ptr、lo<hi 且被 bounds 包含，每个覆盖页恰好有一个完全相等 occupant。反向检查页桶非空、项确在该页且与主表相等、无重复；核验 arena bounds。verify_scan_cache 时再查页/arena 地址位过滤、classed superblock 与 extent bounds 覆盖。
- **所有权 / 错误 / 调用**：返回六种 VerifyError，不修复表。没有重新扫描 slab 检测漏登记，也不检查实际 header 发布状态；block 的精确成员/filter 完整性另有审计。

### `Table.rebuildScanFilter` (`src/core/gc_address_registry.zig:388`)

- **签名**：`pub fn rebuildScanFilter(self: *Table) ScanFilter`。
- **作用**：从当前登记集合重建地址过滤位并扩展扫描边界。
- **实现**：OR 所有 arena base 与 occupant page base 得 scan_filter；若有 block_heap，读取其 scanFilter，并合并 used_blocks 非零的 superblock 全范围（含 +1）与 extent bounds。返回四标量 ScanFilter。
- **所有权 / 错误 / 调用**：更新 self.scan_filter/bounds；bounds 只扩不缩。每轮扫描前调用，返回副本在该停止世界扫描期间必须覆盖真实人口，新增登记不会自动更新旧副本。

### `Table.forEachGcObjectInBlocks` (`src/core/gc_address_registry.zig:435`)

- **签名**：`fn forEachGcObjectInBlocks( self: *Table, addr: usize, block_filter: usize, context: *anyopaque, visit: *const fn (*anyopaque, *gc.Header) void, ) struct { owns_address: bool, hits: usize }`。
- **作用**：解析 addr 与前一字节的 classed block cell。
- **实现**：无 block_heap 返回不拥有/零命中；blockOfWithFilter 成功即置 owns_address，随后要求 interior cell、alloc bit 和 heap_accounted；同一 user 去重后回调。
- **所有权 / 错误 / 调用**：owns_address 可为 true 而 hits=0，例如映射中的空闲 cell；外层据此停止其它人口解析。不检查 doomed，后续 shading 再处理判死载体。

### `Table.filterRulesOut` (`src/core/gc_address_registry.zig:467`)

- **签名**：`inline fn filterRulesOut(self: *const Table, base: usize) bool`。
- **作用**：用当前 Table 地址过滤位排除不可能存在的页基址。
- **实现**：委托 filterRulesOutBits(scan_filter,base)。
- **所有权 / 错误 / 调用**：只作负向预过滤，不证明命中对象；不使用 block_heap 的独立过滤位。

### `Table.filterRulesOutBits` (`src/core/gc_address_registry.zig:471`)

- **签名**：`inline fn filterRulesOutBits(bits: usize, base: usize) bool`。
- **作用**：判断 base 是否含聚合过滤位之外的置位。
- **实现**：返回 (base & bits)!=base。
- **所有权 / 错误 / 调用**：true 表示在完整过滤位前提下可排除；false 可能是假阳性，必须再查真实集合/几何。

### `Table.deinit` (`src/core/gc_address_registry.zig:475`)

- **签名**：`pub fn deinit(self: *Table, allocator: std.mem.Allocator) void`。
- **作用**：释放地址索引容器并恢复默认 Table。
- **实现**：销毁 arenas；遍历 pages 释放每个 occupants 数组；再销毁 pages/by_header，最后 self.*=.{}。
- **所有权 / 错误 / 调用**：不释放登记的 GC 分配或借用的 block_heap；使用匹配 allocator，合法状态下可重复销毁。

### `Table.occupantFor` (`src/core/gc_address_registry.zig:486`)

- **签名**：`pub fn occupantFor(header: *gc.Header, bytes: usize) Occupant`。
- **作用**：构造包含 prefix 和 one-past-end 地址的 standalone 区间。
- **实现**：ptr=header 地址，lo=ptr-metadata_prefix_size，hi=ptr+bytes+1，查询采用 [lo,hi)。
- **所有权 / 错误 / 调用**：纯值构造，不查真实分配大小；调用方须提供正确 bytes 和有效不溢出地址。bytes 不含前缀，由 lo 单独纳入。

### `Table.insert` (`src/core/gc_address_registry.zig:493`)

- **签名**：`pub fn insert(self: *Table, allocator: std.mem.Allocator, header: *gc.Header, bytes: usize) std.mem.Allocator.Error!void`。
- **作用**：按 header 与分配大小登记 standalone occupant。
- **实现**：occupantFor 构造区间后调用 insertOccupant。
- **所有权 / 错误 / 调用**：返回 allocator 错误，不自动置 occupantsIncomplete；调用方在失败时执行完整性协议。

### `Table.insertOccupant` (`src/core/gc_address_registry.zig:497`)

- **签名**：`fn insertOccupant(self: *Table, allocator: std.mem.Allocator, occupant: Occupant) std.mem.Allocator.Error!void`。
- **作用**：把一个 standalone 区间登记到主表与所有覆盖页。
- **实现**：by_header.getOrPut 命中既有 ptr 就返回，既不更新区间也不校验差异；新项写主表并扩 bounds，再逐页 getOrPut 桶并 append。错误时删除主项，rollbackPages 撤销先前成功页的尾项。
- **所有权 / 错误 / 调用**：失败可保留扩大的 bounds/容量；若新建页桶后 append 失败，该空桶不计入 registered，因此不被 rollbackPages 删除。不能称为完全事务回滚。scan_filter 和 incomplete 位不在此维护。

### `Table.remove` (`src/core/gc_address_registry.zig:525`)

- **签名**：`pub fn remove(self: *Table, allocator: std.mem.Allocator, header: *gc.Header) void`。
- **作用**：按 header 地址删除 standalone 登记。
- **实现**：转整数 identity 后委托 removePtr。
- **所有权 / 错误 / 调用**：不释放 header 本身；不是 arena 或 block cell 的注销入口。

### `Table.removePtr` (`src/core/gc_address_registry.zig:529`)

- **签名**：`fn removePtr(self: *Table, allocator: std.mem.Allocator, identity: usize) void`。
- **作用**：移除一个 standalone 主项及其页桶副本。
- **实现**：fetchRemove 未命中直接返回；命中后逐覆盖页查桶，按 ptr 找首项 swapRemove，空桶释放并删页，最后 compactIfTombstoned。
- **所有权 / 错误 / 调用**：容忍缺页；不修复重复项或错误范围。删除不保序、不缩 bounds、不重建过滤位；allocator 只释放桶存储。

### `Table.compactIfTombstoned` (`src/core/gc_address_registry.zig:557`)

- **签名**：`fn compactIfTombstoned(self: *Table) void`。
- **作用**：按删除预算清理主表和页表的 tombstone。
- **实现**：保留两高状态位，低位删除数加一；budget=by_header.capacity()/4，零或尚未达预算则返回；达标清低计数并 rehash 两张表。
- **所有权 / 错误 / 调用**：不申请新容量，不改变逻辑人口；此处只在成功删除主项后调用，状态位不能被计数重置误清。

### `Table.forEachTraceCandidateAt` (`src/core/gc_address_registry.zig:584`)

- **签名**：`pub fn forEachTraceCandidateAt( self: *Table, addr: usize, scan_filter: ScanFilter, context: *anyopaque, visit: *const fn (*anyopaque, *gc.Header) void, ) usize`。
- **作用**：对一个保守候选地址报告当前索引能够解析的所有相关载体。
- **实现**：先按 ScanFilter bounds 拒绝；classed block arm 若 owns_address 即返回其 hits。随后查 extent inside/one_past_end，有任一候选则仅回调已 heap_accounted 的项并返回。否则当前/前一 arena 页基均被地址位过滤拒绝才退出；再做 arena 双探测，并扫描当前 occupant 页桶中 [lo,hi) 包含 addr 的所有项。
- **所有权 / 错误 / 调用**：依赖不同分配人口的地址区间隔离与完整索引；standalone 桶命中不再读 heap_accounted，登记正确性由发布/释放协议保证。返回回调数，不直接标记、不累计扫描统计。

### `Table.containsHeader` (`src/core/gc_address_registry.zig:653`)

- **签名**：`pub fn containsHeader(self: *const Table, header: *const gc.Header) bool`。
- **作用**：检查精确 header 地址是否属于可解析的登记人口。
- **实现**：block 分支要求 alloc bit、精确 payload 起点和 heap_accounted；extent 分支要求 header-prefix 恰为解析到的 extent base 且已计账；arena 分支要求解析 user 恰等于输入且已计账；最后直接查 by_header。
- **所有权 / 错误 / 调用**：不同于 interior candidate 查询；standalone 最后分支仅信主表，不解引用/重验 heap_accounted，也不判断 GC 可达性。

### `Table.rollbackPages` (`src/core/gc_address_registry.zig:686`)

- **签名**：`fn rollbackPages( self: *Table, allocator: std.mem.Allocator, occupant: Occupant, first_page: usize, registered: usize, ) void`。
- **作用**：撤销一次失败插入中已成功 append 的页副本。
- **实现**：从 first_page 遍历 registered 页；仅当桶尾 ptr 等于目标才 pop；桶空则释放数组并删页。
- **所有权 / 错误 / 调用**：依赖逐页尾插且没有并发修改；不处理发生 append 失败的那一页，不回退 bounds，也不负责删除 by_header（由另一 errdefer 完成）。

### `Table.noteFailedInsert` (`src/core/gc_address_registry.zig:712`)

- **签名**：`pub inline fn noteFailedInsert(self: *Table) void`。
- **作用**：锁存 standalone occupant 登记失败状态。
- **实现**：调用 setOccupantsIncomplete(true)。
- **所有权 / 错误 / 调用**：不抛错误、不重新登记；收集器必须据此避免不完整根索引下 sweep。

### `occupantsEqual` (`src/core/gc_address_registry.zig:717`)

- **签名**：`fn occupantsEqual(a: Occupant, b: Occupant) bool`。
- **作用**：比较两个页登记副本是否完全一致。
- **实现**：同时比较 lo、hi、ptr。
- **所有权 / 错误 / 调用**：纯值比较；相同 ptr 但不同范围不算相等，用于双向索引审计。

## `gc_conservative.zig`

conservative native 根扫描（design §7.2）。实现 ABI：AArch64 Linux/macOS、x86_64 SysV、x86_64 Windows；其余 comptime `@compileError`——不能扫栈的 reclaiming tracer 会释放「只活在机器字里」的对象。

`SpillImage`：AArch64 为 768 字节，31 个 GPR 后有 8 字节 padding，SIMD 从偏移 256 开始；x86_64 为 384 字节，15 个已写 GPR 槽后保留偏移 120 的空槽，XMM 从偏移 128 开始。两者对齐 16；缓冲初始 undefined，汇编不会写 padding。Metrics.candidates 仅累计扫描机器字数。栈高及失败结果按线程缓存；OS 查询不可用时才回退 runtime 的 native_stack_top。

DiagWord 保存 addr/word、sp/high、image_lo/image_hi，默认零且按线程存储。DiagFrame 保存 top 与 pc；最多 diag_max_frames=256 项，表、计数、截断标志和 SP 缓存键也按线程保存。diag_register_words 为 SpillImage 的机器字数，当前 AArch64 为96、x86_64为48。

RootsDiagCensus 是进程级固定容量普查，global 与 diag_sites 由 GlobalLock 保护；thread_direct/diag_thread_id 按线程，编号来自全局原子计数。统计驻留在静态存储，不增大 JSRuntime，但仍占进程内存并带来诊断执行开销，不能称为零成本。

Source 分 register、距SP向高地址的 <1/<4/<16/<64/≥64KiB 栈槽及 unknown；PtrKind 为 exact/prefix/interior。Key 是128位打包值，含名称/owner/caller下标、class/kind、source/ptr_kind、young/native、offset/slot桶及40位padding。稳定率不是key的一部分，Slot另存count/stable_count/used。

容量与未知值：key表16384槽，stability表65536槽，PC表1024项，名称表512项且每项最多48字节；index_unknown=0xFFF，slot_unknown=0xFFFF。名称、PC命中和稳定计数各有独立数组；by_source/by_ptr_kind/by_kind/by_register保存维度计数，probes/direct/direct_young/transitive记录采样量。dropped_*是登记失败事件数，未对丢弃项去重；truncated_walks按带截断标志的直接命中累计。

StabilityEntry 保存线程、PC/槽号、上次header地址、hits/stable/exact/prefix、kind位集合和最近offset；Record 是一次classify产生的临时记录，含尚待驻留的名称/PC。kind_churn_floor=3、callee_saved_span=160用于likely_residue/likely_spill/candidate_root启发式分类，不能替代源码活性验证。

R3 roots-diag（`-Dzjs_gc_roots_diag`）的扫描记录在诊断构建启用：按 (函数, kind, class, 字来源, 指针形状) 统计「只有 conservative 保住」的对象。诊断工作必须发生在 `scanWords` **之下**，否则降低 `sp` 会扫到生产路径看不到的残字。


### `linux_stack.stackHigh` (`src/core/gc_conservative.zig:86`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：查询当前 Linux 线程的栈地址上界。
- **实现**：pthread_getattr_np 获取属性，成功后 defer pthread_attr_destroy；pthread_attr_getstack 得 base/size，返回 base+size。任一步失败或 base 为空返回 null。
- **所有权 / 错误 / 调用**：属性资源在成功取得后总会销毁；不分配返回缓冲，查询结果由线程缓存保存。

### `stackHigh` (`src/core/gc_conservative.zig:97`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：非 Linux pthread：没有栈高。
- **实现**：恒返回 null，编译期与 linux 臂互斥。
- **所有权 / 错误 / 调用**：不分配、无 error set。**实际不可达**：`threadStackHigh`（`src/core/gc_conservative.zig:154`）用同一个 `comptime linux_pthread` 谓词选臂，谓词为假时根本不会走到 `linux_stack.stackHigh`，这个 stub 只是让 `linux_stack` 在非 Linux 构建上仍是合法类型。

### `darwin_stack.stackHigh` (`src/core/gc_conservative.zig:105`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：查询当前 Darwin 线程向下增长栈的高地址。
- **实现**：调用 pthread_get_stackaddr_np(pthread_self())；空指针返回 null，否则转换成 usize。
- **所有权 / 错误 / 调用**：返回地址值，不拥有栈存储；当前允许的 Darwin 目标为 macOS。

### `stackHigh` (`src/core/gc_conservative.zig:111`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：非 Darwin：没有栈高。
- **实现**：恒返回 null。
- **所有权 / 错误 / 调用**：同上：不分配、无 error set，且与 `threadStackHigh`（`src/core/gc_conservative.zig:156`）的 `comptime darwin_pthread` 分支互斥，任何构建里都不会被调用。

### `windows_limits.stackHigh` (`src/core/gc_conservative.zig:122`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：查询当前 Windows 线程的栈上界。
- **实现**：将 low/high 初始化为零，调用 GetCurrentThreadStackLimits；high 为零返回 null，否则返回 high，low 不参与结果。
- **所有权 / 错误 / 调用**：不分配、不改变栈；只取高界，扫描低界由实际 SP 提供。

### `stackHigh` (`src/core/gc_conservative.zig:129`)

- **签名**：`fn stackHigh() ?usize`。
- **作用**：非 Windows：没有栈高。
- **实现**：恒返回 null。
- **所有权 / 错误 / 调用**：同上：不分配、无 error set，与 `threadStackHigh`（`src/core/gc_conservative.zig:158`）的 `comptime windows_stack` 分支互斥；返回 null 时上层由 `scanHigh` 退回 `rt.hot.native_stack_top`，但这条退路是给真实平台臂拿不到栈高的情形用的。

### `threadStackHigh` (`src/core/gc_conservative.zig:148`)

- **签名**：`fn threadStackHigh() ?usize`。
- **作用**：按线程缓存平台栈高查询结果，包括查询失败。
- **实现**：valid 已置时返回缓存非零值或 null；首次先置 valid，再按平台调用 stackHigh，并把 null 编码为 cached_stack_high=0。
- **所有权 / 错误 / 调用**：threadlocal 缓存不随 runtime 切换重查，失败也不会自动重试；缓存假设线程使用的栈边界保持稳定。

### `scanHigh` (`src/core/gc_conservative.zig:165`)

- **签名**：`fn scanHigh(rt: *const JSRuntime, sp: usize) usize`。
- **作用**：为给定 SP 选择扫描区间的高界。
- **实现**：OS 缓存高界存在且大于 sp 时优先返回；否则尝试 rt.hot.native_stack_top，大于 sp 才用；两者均不可用则返回 sp。
- **所有权 / 错误 / 调用**：不取两个高界的最大值，也不报查询失败；最后一种情况得到空扫描区间。这里不探测页面是否可读。

### `dumpRegisters` (`src/core/gc_conservative.zig:174`)

- **签名**：`fn dumpRegisters(image: *SpillImage) usize`。
- **作用**：把当前寄存器快照写入 SpillImage，并返回 SP。
- **实现**：AArch64 写 x0..x30 与 q0..q31，读取 sp；x86_64 写 rax/rbx/rcx/rdx/rsi/rdi/rbp/r8..r15 与 xmm0..xmm15，读取 rsp。使用 volatile asm 和 memory clobber，目标分支编译期选择。
- **所有权 / 错误 / 调用**：借用调用方缓冲；不是恢复寄存器的上下文切换。AArch64 的 GPR 后 padding 和 x86_64 偏移120的槽不被汇编写入；实际 x86 r8 在偏移56，不是 padding。

### `scanWords` (`src/core/gc_conservative.zig:255`)

- **签名**：`fn scanWords( rt: *JSRuntime, lo: usize, hi: usize, scan_filter: AddressRegistry.ScanFilter, metrics: *Metrics, shade: *const fn (*anyopaque, *gc.Header) void, shade_ctx: *anyopaque, ) void`。
- **作用**：逐机器字读取栈区间并通过地址注册表解析候选。
- **实现**：lo 向上对齐 usize，从该位置扫描完整落在 [lo,hi) 的机器字；先一次累加完整字数到 metrics.candidates。诊断构建逐字更新 diag_word，然后 forEachTraceCandidateAt 回调所有匹配载体。
- **所有权 / 错误 / 调用**：metrics 计扫描字数，不是命中数；忽略地址表返回的 hits。源栈区间须有效可读，候选 word 本身不被直接当 header 解引用。本函数没有过滤 string/rope，不能沿用旧 RC 注释声称丢弃它们。

### `spillRegistersAndScan` (`src/core/gc_conservative.zig:285`)

- **签名**：`pub fn spillRegistersAndScan( rt: *JSRuntime, metrics: *Metrics, shade: *const fn (*anyopaque, *gc.Header) void, shade_ctx: *anyopaque, ) void`。
- **作用**：为本次扫描刷新地址过滤副本、保存寄存器并扫描 native 栈。
- **实现**：rebuildScanFilter 后建立局部 SpillImage，dumpRegisters 返回 sp，doNotOptimizeAway 保持转储；scanHigh 得 high。诊断构建记录 sp/image/high 几何，再 scanWords(sp,high)。
- **所有权 / 错误 / 调用**：转储作为栈上内容被扫描，没有单独遍历 image 的第二趟。shade 是无错误返回回调，失败处理须由上层状态协议承担；操作在 owner 线程的稳定收集窗口执行。

### `diagCurrentWord` (`src/core/gc_conservative.zig:335`)

- **签名**：`pub inline fn diagCurrentWord() DiagWord`。
- **作用**：返回本线程最近记录的扫描字及扫描几何快照。
- **实现**：直接按值返回 threadlocal diag_word。
- **所有权 / 错误 / 调用**：本函数不检查诊断开关；扫描端只有 roots_diag_enabled 时才更新它。非诊断构建通常保持零初始化值，不能当作新一次捕获。

### `diagCaptureFrames` (`src/core/gc_conservative.zig:379`)

- **签名**：`fn diagCaptureFrames(w: DiagWord) void`。
- **作用**：沿当前 native 帧指针链构建有界归属表。
- **实现**：清 count/truncated 并记缓存键 w.sp；从 @frameAddress 开始，每步要求 fp 按 usize 对齐、两字记录不越 w.high，读取 next_fp/return_address；要求 next_fp 严格增长且低于 high、返回地址至少4096，再保存 {top=next_fp,pc=return_address}。最多256项。
- **所有权 / 错误 / 调用**：修改线程局部表，不分配；达到256才置 truncated，中途断链不等于容量截断。依赖真实可读帧链及 frame pointer，不是安全探测任意地址的展开器；未做代码地址有效性或完整 unwinding 验证。

### `diagOwnerPcs` (`src/core/gc_conservative.zig:409`)

- **签名**：`fn diagOwnerPcs(w: DiagWord) struct { owner: usize, caller: usize, frame_base: usize }`。
- **作用**：查询当前扫描字所在 native frame 及其调用者的返回地址。
- **实现**：缓存 SP 与 w.sp 不同或 w.high==0 时捕获帧链；对递增 top 二分找首个 top≥w.addr。没有匹配则三个字段均零，否则 owner=该项pc、caller=下一项pc或零、frame_base=该项top。
- **所有权 / 错误 / 调用**：返回 PC 地址值，不解析函数名。缓存只按 SP 判定，没有扫描序号；相同 SP 的后续扫描可能复用旧帧表，因此不能无条件声称每次扫描精确重建。

### `diagRegisterName` (`src/core/gc_conservative.zig:435`)

- **签名**：`fn diagRegisterName(index: usize, buf: []u8) []const u8`。
- **作用**：为转储 image 的机器字槽生成诊断名称。
- **实现**：AArch64 槽0..30为x0..x30，31为pad，其余按两字一个q寄存器输出lo/hi。x86_64 使用固定16项名称表，随后按两字一个xmm输出lo/hi。格式化缓冲不足返回 "?"。
- **所有权 / 错误 / 调用**：动态名称借用 buf，固定名称为静态字符串；不校验 index 上界。现有 x86 名称表把槽7写为pad、槽8..15写为r8..r15，但 dumpRegisters 实际在槽7..14写r8..r15、槽15未写；这些槽的诊断标签不能当作正确物理寄存器身份。

### `StabilityEntry.kindCount` (`src/core/gc_conservative.zig:503`)

- **签名**：`fn kindCount(self: StabilityEntry) usize`。
- **作用**：统计同一诊断位置曾解析到多少种 GC kind。
- **实现**：对 kinds 的 u16 位掩码执行 @popCount。
- **所有权 / 错误 / 调用**：返回种类数，不是命中次数；本函数不修改稳定性历史。

### `diagThreadId` (`src/core/gc_conservative.zig:512`)

- **签名**：`fn diagThreadId() u32`。
- **作用**：为当前线程取得用于区分诊断位置的非零编号。
- **实现**：threadlocal id 为零时，用全局原子计数 fetchAdd(1,.monotonic) 的旧值饱和加一，保存后返回；已分配则复用。
- **所有权 / 错误 / 调用**：不依赖 OS 线程 id，也不重置于 runtime 销毁。没有编号耗尽错误或唯一性回绕检查，不能承诺无限线程生命周期下永久唯一。

### `RootsDiagCensus.offsetBucket` (`src/core/gc_conservative.zig:567`)

- **签名**：`fn offsetBucket(word: usize, header_addr: usize) u8`。
- **作用**：把候选值与 header 的地址差编码为诊断桶。
- **实现**：等于 header 返回0，等于 header-prefix 返回1，其它低于 header 返回255；更高地址按 usize 字宽向下取整，截到32后加2，最大34。
- **所有权 / 错误 / 调用**：在当前64位目标每8字节一桶，≥256字节合并。只比较地址，不验证它确为合法内部指针；header 地址须允许减 prefix。

### `RootsDiagCensus.offsetBucketName` (`src/core/gc_conservative.zig:575`)

- **签名**：`fn offsetBucketName(bucket: u8, buf: []u8) []const u8`。
- **作用**：将偏移桶转成可打印标签。
- **实现**：0为+0，1为-8，255为<hdr，34为>=256；其它以 (bucket-2)*8 格式化 +字节数。
- **所有权 / 错误 / 调用**：格式化失败返回静态问号，动态结果借用 buf；标签表示桶下界，不能还原精确偏移。更高但不足8字节的地址也会显示+0，需结合 ptr_kind 区分。

### `RootsDiagCensus.hashKey` (`src/core/gc_conservative.zig:706`)

- **签名**：`fn hashKey(key: Key) usize`。
- **作用**：为128位诊断 key 生成开放寻址起始散列值。
- **实现**：将高低64位异或折叠，乘黄金比例常数（回绕乘法），取最高12位。
- **所有权 / 错误 / 调用**：结果范围0..4095；当前 slots_len 为16384，不能据表长推断散列直接覆盖全部起始槽，其余由插入探测处理。无分配。

### `RootsDiagCensus.currentFunction` (`src/core/gc_conservative.zig:712`)

- **签名**：`fn currentFunction(rt: *const JSRuntime) struct { name: []const u8, native: bool }`。
- **作用**：取得当前回溯帧所报告的 JS 函数名和 native 标记。
- **实现**：有 current_backtrace_frame 且 resolver(data,0) 成功时，非零 function_name 从 atoms.name 借用名称，失败或零 id 用 <anonymous>；无帧/快照则返回空名与 false。
- **所有权 / 错误 / 调用**：不是解析 native owner_pc；返回名称可能借用 runtime atom 存储，后续 internName 才复制。

### `RootsDiagCensus.internName` (`src/core/gc_conservative.zig:725`)

- **签名**：`fn internName(self: *RootsDiagCensus, name: []const u8) u12`。
- **作用**：将函数名的有限前缀驻留到固定名称表。
- **实现**：空名返回 index_unknown；截取最多48字节，线性比较已用项；命中复用，否则有容量时复制并分配下标。512项已满时 dropped_names 加一并返回 unknown。
- **所有权 / 错误 / 调用**：同前48字节的不同长名称会合并，截断可能跨 UTF-8 字符；dropped_names 是失败登记次数，不是去重后不同名称数。无堆分配。

### `RootsDiagCensus.internPcSilent` (`src/core/gc_conservative.zig:742`)

- **签名**：`fn internPcSilent(self: *RootsDiagCensus, pc: usize) u12`。
- **作用**：驻留非零返回地址，不累计该PC的命中数。
- **实现**：零返回 unknown；线性查已有PC，未命中且未满1024项时写入并初始化 pc_counts=0；满表则 dropped_pcs 加一返回 unknown。
- **所有权 / 错误 / 调用**：Silent 只指不增加 owner 命中数，仍会修改表与溢出计数。重复未登记PC会重复增加 dropped_pcs。

### `RootsDiagCensus.internPc` (`src/core/gc_conservative.zig:758`)

- **签名**：`fn internPc(self: *RootsDiagCensus, pc: usize) u12`。
- **作用**：驻留 owner PC 并记录一次命中。
- **实现**：调用 internPcSilent；返回有效下标时 pc_counts[index] 加一。
- **所有权 / 错误 / 调用**：零或容量溢出不增加PC命中数；调用者PC用 Silent 路径，避免与 owner 排名混计。

### `RootsDiagCensus.classify` (`src/core/gc_conservative.zig:764`)

- **签名**：`fn classify(rt: *const JSRuntime, header: *const gc.Header, w: DiagWord) Record`。
- **作用**：把一个直接保守根命中转为诊断 Record。
- **实现**：比较候选 word 与 header/prefix 得 exact、prefix，否则统称 interior。image 范围内归 register 并算槽号；低于 sp 归 unknown；其余按距sp的1/4/16/64KiB分桶，并查询owner/caller PC及截断的frame槽偏移。读取kind/young，Object 才取class_id；当前JS函数名/native另由currentFunction取得。
- **所有权 / 错误 / 调用**：不做地址解析或存活判定，header 须已验证；interior 也可能包含其它低于header或one-past-end形态，offset桶补充区分。名称和PC下标先设unknown，apply再驻留。truncated读线程旧标志，不能据每个Record将其解释为一轮新扫描。

### `RootsDiagCensus.noteSite` (`src/core/gc_conservative.zig:839`)

- **签名**：`fn noteSite(self: *RootsDiagCensus, record: Record, pc_index: u12) bool`。
- **作用**：累计同一线程、owner PC、frame槽的地址稳定性。
- **实现**：缺owner或未知槽则unlocated加一。否则按PC/槽/线程id散列并线性探测65536项：新项记首次命中；旧项将当前header地址与last_header比较，更新hits/stable/exact/prefix/kinds和最后offset。满表dropped_sites加一返回false。
- **所有权 / 错误 / 调用**：稳定仅指相邻命中的地址相同，不验证分配generation，也不保证中间每轮扫描都命中；地址复用可误显稳定。不同线程分开记录；该方法本身不加锁，依赖外部同步。

### `RootsDiagCensus.entryVerdict` (`src/core/gc_conservative.zig:896`)

- **签名**：`fn entryVerdict(entry: StabilityEntry) Verdict`。
- **作用**：按统计特征给槽位生成启发式分类。
- **实现**：非exact命中过半、hits≥4且stable_hits*10>hits*9时likely_residue；否则kindCount≥3也为likely_residue；再看exact+prefix过半且槽距frame base≤160字节，则likely_spill；其余candidate_root。
- **所有权 / 错误 / 调用**：顺序有优先级，90%为严格大于。不是类型或活性证明，kind变化/地址稳定都可能受复用和归属误差影响；返回分类不改变GC根或对象状态。普通计数乘法没有饱和保护。

### `RootsDiagCensus.apply` (`src/core/gc_conservative.zig:931`)

- **签名**：`fn apply(self: *RootsDiagCensus, record: Record) void`。
- **作用**：把一个已分类直接命中合并进各维度计数和固定key表。
- **实现**：先增加direct/young/truncated、寄存器/source/ptr_kind/kind计数；驻留名称、owner和caller PC，更新位置稳定性及owner稳定计数。随后线性探测slots，新key写count=1，旧key增加count/stable_count；满表dropped_keys加一。
- **所有权 / 错误 / 调用**：即使key表满，前面维度和位置计数已更新，不回滚。dropped_keys是失败合并次数，不保证不同key数；truncated_walks实际按带该标志的命中累加，不是按扫描去重。自身不加锁。

### `RootsDiagCensus.nameAt` (`src/core/gc_conservative.zig:968`)

- **签名**：`fn nameAt(self: *const RootsDiagCensus, index: u12) []const u8`。
- **作用**：按诊断名称下标借用存储文本。
- **实现**：unknown或超出names_used返回<no frame>，否则返回names对应有效长度切片。
- **所有权 / 错误 / 调用**：借用census内部数组，不能跨重置保留；该标签也用于名称表溢出，并不只表示实际缺少帧。

### `RootsDiagCensus.percent` (`src/core/gc_conservative.zig:973`)

- **签名**：`fn percent(part: usize, whole: usize) usize`。
- **作用**：计算截断到整数的百分比。
- **实现**：whole为零返回0，否则part*100/whole。
- **所有权 / 错误 / 调用**：普通乘法无溢出保护、不将结果截到100；输入应为合法统计口径。

### `RootsDiagCensus.slotName` (`src/core/gc_conservative.zig:978`)

- **签名**：`fn slotName(bucket: u16, buf: []u8) []const u8`。
- **作用**：格式化frame槽相对偏移。
- **实现**：slot_unknown返回n/a；否则输出fp-后接bucket*sizeof(usize)，缓冲不足返回问号。
- **所有权 / 错误 / 调用**：动态结果借用buf；这是分桶偏移，不恢复原始精确字节地址。

### `RootsDiagCensus.mergeSite` (`src/core/gc_conservative.zig:985`)

- **签名**：`fn mergeSite(pc: usize, slot_bucket: u16) StabilityEntry`。
- **作用**：将多个线程上相同PC和槽号的统计合并为报告项。
- **实现**：扫描全局diag_sites，匹配used/pc/slot；累加hits、stable、exact、prefix并OR kinds，offset_bucket和pc_index取遍历中最后一个匹配值。
- **所有权 / 错误 / 调用**：last_header和thread_id保留默认零，无跨线程地址比较；offset不是按时间或频次选出的代表值。即使没有匹配也返回used=true的零计数结构。

### `RootsDiagCensus.siteCountFor` (`src/core/gc_conservative.zig:1001`)

- **签名**：`fn siteCountFor(pc: usize) usize`。
- **作用**：统计某PC下去重后的槽号数量。
- **实现**：逐项扫描diag_sites，对匹配项再检查前面是否已有同PC/槽号，首次出现才计数。
- **所有权 / 错误 / 调用**：合并不同线程；没有分配，最坏二次扫描开销，供冷诊断报告使用。

### `RootsDiagCensus.writeTopSites` (`src/core/gc_conservative.zig:1019`)

- **签名**：`fn writeTopSites(writer: *std.Io.Writer, pc: usize, limit: usize) !void`。
- **作用**：输出一个owner PC最常命中的合并槽位。
- **实现**：反复扫描diag_sites，跳过已输出槽号，mergeSite跨线程合并并选hits最多者；最多min(limit,8)行。输出槽偏移、最后offset桶、命中/稳定率、exact/prefix、kind数和合并后verdict。
- **所有权 / 错误 / 调用**：不重排全局表；并列时保留先遇项。传播writer错误，无内部锁，调用方须防并发修改；合并后分类可能不同于各线程先分类的汇总。

### `RootsDiagCensus.reportVerdicts` (`src/core/gc_conservative.zig:1055`)

- **签名**：`fn reportVerdicts(self: *const RootsDiagCensus, writer: *std.Io.Writer) !void`。
- **作用**：按各线程位置的启发式分类汇总整体及owner PC排名。
- **实现**：遍历diag_sites，对每项entryVerdict后按hits累加overall；有效pc_index再计对应PC。按每PC三类总和降序，最多30项，遇零总数停止。dominant取最多的一类，同计数按枚举顺序先者。
- **所有权 / 错误 / 调用**：整体located含PC驻留失败的位置，PC排名不含它们；unlocated另报，丢弃位置不自动补入located。与合并槽明细的分类顺序不同。只报告推测，不认定真实缺根。

### `RootsDiagCensus.Sorter.frameTotal` (`src/core/gc_conservative.zig:1088`)

- **签名**：`fn frameTotal(row: [verdict_count]usize) usize`。
- **作用**：求一个owner frame三种verdict的命中总数。
- **实现**：返回row[0]+row[1]+row[2]。
- **所有权 / 错误 / 调用**：普通整数求和，不饱和、不修改输入。

### `RootsDiagCensus.Sorter.more` (`src/core/gc_conservative.zig:1091`)

- **签名**：`fn more(all: *const [pc_table_len][verdict_count]usize, a: usize, b: usize) bool`。
- **作用**：按verdict总命中数为frame下标提供降序比较。
- **实现**：frameTotal(all[a])>frameTotal(all[b])。
- **所有权 / 错误 / 调用**：只比较数值，不增加并列次序规则；返回false不代表两个下标相同。

### `RootsDiagCensus.writeOwnerPc` (`src/core/gc_conservative.zig:1126`)

- **签名**：`fn writeOwnerPc(writer: *std.Io.Writer, pc: usize) !void`。
- **作用**：将一个返回地址交给调试符号解析输出。
- **实现**：pc为零打印<no frame>；否则构造单地址StackTrace并writeStackTrace(no_color)，失败时尝试打印原始十六进制地址。
- **所有权 / 错误 / 调用**：符号解析失败被fallback吸收，fallback的writer错误仍上抛；前一次输出可能已部分写入，不回滚。

### `RootsDiagCensus.report` (`src/core/gc_conservative.zig:1141`)

- **签名**：`pub fn report(self: *const RootsDiagCensus, writer: *std.Io.Writer) !void`。
- **作用**：输出进程级根诊断计数、排名和verdict。
- **实现**：先写总计、source/ptr_kind/kind分栏及非零寄存器计数；PC命中数排序输出最多30项，每项附最多3个合并槽及符号信息。随后reportVerdicts；再按已用key槽count排序输出最多30行，附名称、kind/class、来源、偏移、稳定率和owner/caller。
- **所有权 / 错误 / 调用**：排序的是局部下标数组，不修改表；没有内部加锁或flush，错误上抛且可能留下部分报告。PC表也驻留caller，owner排名可能含零命中PC。报告仅展示top子集，不等于完整明细。

### `RootsDiagCensus.moreHits` (`src/core/gc_conservative.zig:1180`)

- **签名**：`fn moreHits(c: *const [pc_table_len]usize, a: usize, b: usize) bool`。
- **作用**：为局部排名下标提供降序比较。
- **实现**：比较c[a]>c[b]，按owner PC命中数降序排列PC下标。
- **所有权 / 错误 / 调用**：不移动原始计数表；并列时不额外比较名称或地址。

### `RootsDiagCensus.moreHits` (`src/core/gc_conservative.zig:1212`)

- **签名**：`fn moreHits(all: *const [slots_len]Slot, a: u32, b: u32) bool`。
- **作用**：为局部排名下标提供降序比较。
- **实现**：比较all[a].count>all[b].count，按完整诊断key命中数降序排列槽下标。
- **所有权 / 错误 / 调用**：不移动原始计数表；并列时不额外比较名称或地址。

### `GlobalLock.lock` (`src/core/gc_conservative.zig:1260`)

- **签名**：`fn lock(self: *GlobalLock) void`。
- **作用**：取得进程诊断表的自旋锁。
- **实现**：以cmpxchgWeak(false,true,.acquire,.monotonic)循环争用，失败执行spinLoopHint。
- **所有权 / 错误 / 调用**：无递归/公平性/超时保证；同线程持锁后重入会自旋。用于保护global与diag_sites，不保护其它runtime状态。

### `GlobalLock.unlock` (`src/core/gc_conservative.zig:1266`)

- **签名**：`fn unlock(self: *GlobalLock) void`。
- **作用**：释放进程诊断锁。
- **实现**：held.store(false,.release)。
- **所有权 / 错误 / 调用**：调用方须持有锁；不检查线程身份，也不清诊断数据。

### `diagThreadDirect` (`src/core/gc_conservative.zig:1277`)

- **签名**：`pub inline fn diagThreadDirect() usize`。
- **作用**：查询本线程累计直接保守根命中数。
- **实现**：roots_diag_enabled时返回thread_direct，否则编译期返回零。
- **所有权 / 错误 / 调用**：不是单次probe数，调用方用前后差值；不需要全局锁，因为计数为threadlocal。

### `noteDirect` (`src/core/gc_conservative.zig:1283`)

- **签名**：`pub fn noteDirect(rt: *const JSRuntime, header: *const gc.Header, w: DiagWord) void`。
- **作用**：将调用方已确认的直接保守根加入诊断。
- **实现**：禁用诊断时直接返回；否则先classify并递增thread_direct，再持global_mutex调用global.apply，defer解锁。
- **所有权 / 错误 / 调用**：本函数不检查header在shade前后是否改变标记，直接根身份由调用方保证。归类在锁外执行，名称在本次调用内驻留；不会实际shade或pin对象。

### `noteProbe` (`src/core/gc_conservative.zig:1295`)

- **签名**：`pub fn noteProbe(conservative_only: usize, direct: usize) void`。
- **作用**：结束一次诊断probe并累计间接保留量。
- **实现**：禁用诊断时返回；持锁递增probes，transitive增加conservative_only-|direct。
- **所有权 / 错误 / 调用**：参数为本轮数量，饱和减避免负数；不再增加global.direct（由noteDirect负责），普通累计加法并不饱和。

### `reportGlobal` (`src/core/gc_conservative.zig:1304`)

- **签名**：`pub fn reportGlobal(writer: *std.Io.Writer) !void`。
- **作用**：在全局锁内输出整个进程的根诊断报告。
- **实现**：禁用诊断时无输出；否则持锁写标题和global.report，defer解锁。
- **所有权 / 错误 / 调用**：writer错误上抛，错误时也解锁；报告包含符号解析期间一直持锁，会阻塞其它线程的诊断记账。无需runtime仍存活，但不自动flush。

### `diagVerdictForHeader` (`src/core/gc_conservative.zig:1317`)

- **签名**：`fn diagVerdictForHeader(header_addr: usize) ?RootsDiagCensus.Verdict`。
- **作用**：找出最近一次解析到给定 header 地址的 (frame, slot) 站点，并返回它的启发式 verdict。
- **实现**：非诊断构建 comptime 返回 null；否则取 global_mutex（defer 解锁），线性扫描 diag_sites，在 used 且 last_header 等于 header_addr 的项里取 hits 最多者；一个都没有返回 null，否则返回 entryVerdict(entry)。
- **所有权 / 错误 / 调用**：不拥有也不解引用 header，只比较地址。last_header 只保留站点最近一次命中，所以地址复用会让旧站点认领新对象；供测试用地址当作站点句柄（每个测试各自分配对象），不是生产查询接口。

### `diagCensusSnapshot` (`src/core/gc_conservative.zig:1334`)

- **签名**：`fn diagCensusSnapshot() RootsDiagCensus`。
- **作用**：在全局锁内按值复制进程级普查表，供测试做前后差值。
- **实现**：取 global_mutex（defer 解锁），返回 global 的值拷贝。
- **所有权 / 错误 / 调用**：拷贝包含 slots/names/各维度计数，但不含单独放在 `.bss` 的 diag_sites 站点表；快照之后的更新不会反映到副本。只在诊断构建有意义。

### `shade.f` (`src/core/gc_conservative.zig:1345`)

- **签名**：`fn f(_: *anyopaque, _: *gc.Header) void`。
- **作用**：单元测试里传给 spillRegistersAndScan 的空 shade 回调。
- **实现**：函数体为空，两个参数都被忽略。
- **所有权 / 错误 / 调用**：不标记、不入队、不拥有 header；该测试只据此断言 metrics.candidates 非零，即扫描区间非空。

### `Probe.shade` (`src/core/gc_conservative.zig:1379`)

- **签名**：`fn shade(context: *anyopaque, header: *gc.Header) void`。
- **作用**：R3 普查测试的 shade 回调：只为预期的 target header 记一次 direct 命中。
- **实现**：`@ptrCast` 回该测试的 Probe；`header != self.target` 直接返回，否则 `noteDirect(self.rt, header, diagCurrentWord())`。
- **所有权 / 错误 / 调用**：不真正标记或 pin 对象，也不拥有 header；由 spillRegistersAndScan 在解析每个候选字时调用，归类用的是当时的 diag_word。

### `diagRescanFixedSlot` (`src/core/gc_conservative.zig:1432`)

- **签名**：`noinline fn diagRescanFixedSlot(rt: *JSRuntime, slot: *[1]usize, count: usize) void`。
- **作用**：从保持 `slot` 存活的帧跑 `count` 次保守扫描，只记录「字本身来自 `slot`」的命中。站点表以返回地址 + 槽相对 `fp` 的距离为键，两者必须跨迭代相同，稳定率才有意义。
- **实现**：本地 `Probe`：`shade` 读 `diagCurrentWord()`，`w.addr != slot` 的地址则丢弃，命中才 `noteDirect`。循环 `count` 次：`doNotOptimizeAway(slot)`、`spillRegistersAndScan(..., Probe.shade, &probe)`、再 `doNotOptimizeAway`。`noinline` 与循环都是负荷：禁止编译器把指针副本散到别的栈槽。
- **所有权 / 错误 / 调用**：不拥有 header。仅 `gc.roots_diag_enabled` 测试（R1-a/R1-b 残渣判定）。

### `Probe.shade` (`src/core/gc_conservative.zig:1437`)

- **签名**：`fn shade(context: *anyopaque, header: *gc.Header) void`。
- **作用**：`diagRescanFixedSlot` 的过滤 shade：只在当前扫描字等于固定槽地址时记一次 direct 命中。
- **实现**：`@ptrCast` 回 `Probe`，`diagCurrentWord().addr != self.slot` 则 return，否则 `noteDirect(rt, header, w)`。
- **所有权 / 错误 / 调用**：不拥有 header 存储；收集器在 owner 线程 STW 窗口调用；mutator 不得并发。


## 覆盖核对

- 清单函数数: 82（`src/core/gc_address_registry.zig` 29 + `src/core/gc_conservative.zig` 53）
- 本文标题覆盖: 82
- 未覆盖: 无
