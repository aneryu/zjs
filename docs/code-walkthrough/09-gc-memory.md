# 09 — MemoryAccount 与 4 KiB slab

本文件覆盖 `MemoryAccount`（字节账、阈值、GC 前缀写入）和 QuickJS 对齐的 4 KiB `SmallObjectSlab`。生产普通分配器不逐笔触发GC；Object与字符串body/rope使用统一的collectBeforeObjectAllocation边界。

函数级展开。总图见 [09-gc.md](09-gc.md)。写作规范见 [_spec.md](_spec.md)。

## `memory.zig`

运行时内存记账、4 KiB small-object slab、分配入口。`MemoryAccount` 拥有经它做出的每一笔分配，并把字节/分配计数接到 GC registry。调用方必须用同一账户、匹配的类型/对齐/FAM 大小释放。生产GC阈值由collectBeforeObjectAllocation及pollGC检查；字符串body/rope也进入前一边界，不能限定为Object专用。本叶不得依赖 exec/binding。

`SmallObjectSlab`是4 KiB对齐的arena管理器，最大block总尺寸512字节、block header占8字节，所以通常可容纳的非零payload最多504字节。31个class为16..128步长8、144..256步长16、288..512步长32。arena实际申请长度是对齐后的arena header加完整block区，可能小于4096；地址mask只提供候选arena基址，必须先由地址登记集合确认可读，不能直接读取任意mask结果的magic。

slab类型与状态：

- `BlockHeader`为extern布局，u16 `index_or_next`在已分配时保存block索引，在free时保存下一个空闲索引；u8 `block_size_idx`保存class。header整体按8字节对齐占用空间，GC分配在同一空间覆盖Metadata，class字节高位还会承载GC标志。
- `Arena`含magic、all链next/prev、free链free_next/free_prev、class索引、used_blocks/block_count及first_free_block。`free_nil=maxInt(u16)`结束block空闲链，magic为0x5a4a5341。全arena链与可分配arena链独立，每class保留至多一个空spare作为free链头。
- slab保存两组31项arena头、可选arena_backing和ArenaObserver。observer有ctx/on_create/on_release三个字段，管理arena登记而非每次对象分配；void回调不能向分配函数传播登记失败。slab_alloc_prefetch当前为true，pop仅预取本arena内地址。

`MemoryAccount`的三种allocator角色必须分开：`allocator`是当前操作可重定向的接口，`persistent_allocator`供长寿命runtime状态保留，`backing_allocator`是内部实际后备allocator。init将三者设为输入值；账户稳定后activateRuntimeAccounting才把前两者改为持有self指针的accounted facade，内部不能再递归用该facade分配自身。

账户字段保存small_slab及开关、当前allocated_bytes、诊断allocation_count与历史峰值、alloc/free/create/destroy调用计数、可选limit、借用trace_writer及sticky trace_failed、可选profile计数指针、借用cycle_peak_output。`gc_object_cell_heap`借用Registry heap；非block identity/lifecycle表按carrier审计开关存在，否则为void，oracle指针同样有编译期条件。`trigger_gc_fn`接受可空ctx与请求尺寸；独立的`limit_gc_fn`要求非空ctx，用于超过limit时收集重试，不能把NoTrigger解释为禁止这个hook。

编译期配置：`diagnostic_accounting_enabled`仅test或Debug，不是所有runtime_safety构建；`allocation_gc_trigger_enabled`仅test或force_gc。oom coverage、oom injection和force GC分别来自build_options，不能互相等同。identity/lifecycle/oracle开关转自gc_carrier。`malloc_overhead`在Darwin为0，其它平台为8；slab主账是class usable加overhead，standalone按实际请求记账。不同分配路线的limit请求量、物理容量、主账与Registry publication bytes并非一律相同，详见对应函数。

`SlowLayout`携带is_gc、payload_bytes、element_size/count、alignment、standalone_prefix、kind_tag、trigger_gc，供共享冷分配体使用；element_size/count还决定诊断输出。`DestroyLayout`携带payload、对齐/prefix、slab_class、can_block_cell及accounted_block，供固定布局释放使用。两者是内部路线描述，不通过类型擦除自动验证传入指针。`StorageCell`返回prefix起点base、供publication使用的accounted_bytes与is_block_cell标志，调用方取得body须加8。

GC prefix大小来自gc_representation.metadata_size；Object block marker为31，slab合法class索引0..30，standalone位为bit7，class mask为低5位。前缀写入保留cell/slab索引、设置类型并清新生lifetime；它不等于body初始化或Registry发布。`NonBlockObjectPrepare`是可能OutOfMemory的准备回调，在Object未走cell的兼容路线调用。

### `oom_coverage.lock` (`src/core/memory.zig:129`)

- **签名**：`fn lock() void`。
- **作用**：获取进程全局OOM调用点集合的自旋锁。
- **实现**：循环以acquire swap(true)尝试获取；旧值为true则spinLoopHint后重试。
- **所有权 / 错误 / 调用**：无Io依赖，不可重入；不设置超时或公平性保证。锁保护诊断集合，不负责引擎分配同步。

### `oom_coverage.unlock` (`src/core/memory.zig:133`)

- **签名**：`fn unlock() void`。
- **作用**：释放OOM调用点集合锁。
- **实现**：以release顺序store(false)。
- **所有权 / 错误 / 调用**：须由持锁路径调用，函数不检查持锁者身份。

### `oom_coverage.record` (`src/core/memory.zig:137`)

- **签名**：`fn record(site: usize) void`。
- **作用**：向全局集合记录一个分配调用点地址。
- **实现**：lock后defer unlock；使用page_allocator把site写入AutoHashMapUnmanaged，失败被catch丢弃。
- **所有权 / 错误 / 调用**：同一地址去重；OOM可使统计低估且没有失败计数。不走MemoryAccount以免污染引擎计数；函数内部没有coverage-enabled门控，调用方负责。

### `oomCoverageDistinctSiteCount` (`src/core/memory.zig:149`)

- **签名**：`pub fn oomCoverageDistinctSiteCount() usize`。
- **作用**：读取已记录的不同分配调用点数量。
- **实现**：编译期coverage关闭返回0；开启时持锁调用sites.count()。
- **所有权 / 错误 / 调用**：只返回地址去重数量，不给出符号、频率或全源码覆盖率；不能据源码旧注释推定存在reset接口，当前集合为进程全局。

### `SmallObjectSlab.forEachArena` (`src/core/memory.zig:192`)

- **签名**：`pub fn forEachArena(self: *SmallObjectSlab, context: *anyopaque, visit: *const fn (*anyopaque, usize) void) void`。
- **作用**：遍历各size class当前拥有的arena。
- **实现**：逐个arenas链行走，每次先保存arena.next，再把arena基址及context交visit。
- **所有权 / 错误 / 调用**：回调借用slab成员，不转移所有权；不是只访问free_arenas。先取next不等于允许回调任意释放后继或并发修改整个链。

### `SmallObjectSlab.blockSize` (`src/core/memory.zig:250`)

- **签名**：`pub inline fn blockSize(index: usize) usize`。
- **作用**：按slab class索引查询包含block header的总字节数。
- **实现**：返回block_sizes[index]。
- **所有权 / 错误 / 调用**：调用者须保证index<class_count；非可恢复错误接口，不是请求payload大小。

### `SmallObjectSlab.canUse` (`src/core/memory.zig:266`)

- **签名**：`pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool`。
- **作用**：判断请求大小及对齐能否由slab承载。
- **实现**：返回classIndex(byte_count,alignment)!=null。
- **所有权 / 错误 / 调用**：只分类、不分配、不证明某个现有指针归属slab。

### `SmallObjectSlab.setArenaBacking` (`src/core/memory.zig:270`)

- **签名**：`pub fn setArenaBacking(self: *SmallObjectSlab, allocator: std.mem.Allocator) void`。
- **作用**：为尚未拥有arena的slab设置物理后备allocator。
- **实现**：遍历arenas并断言每个head为null，再赋值arena_backing。
- **所有权 / 错误 / 调用**：不迁移已有arena或释放旧backing；调用方须保证空slab以及allocator存活。安全断言关闭不意味着运行中切换合法。

### `SmallObjectSlab.eligibleSize` (`src/core/memory.zig:279`)

- **签名**：`inline fn eligibleSize(byte_count: usize, alignment: std.mem.Alignment) bool`。
- **作用**：只判断slab大小与对齐资格。
- **实现**：alignment大于8字节时false，其余返回totalBlockSize(byte_count)!=null。
- **所有权 / 错误 / 调用**：用于已掌握header class的路径，省去重新算class；不校验具体指针或实际分配类别。

### `SmallObjectSlab.headerClassIndex` (`src/core/memory.zig:288`)

- **签名**：`inline fn headerClassIndex(ptr: [*]u8) usize`。
- **作用**：从非GC或空闲slab block header取得class索引。
- **实现**：blockHeaderFromUser(ptr).block_size_idx直接提升为usize。
- **所有权 / 错误 / 调用**：不mask高位；活GC header该字节含accounted/standalone等位，须用GC专用读法。输入必须精确user起点。

### `SmallObjectSlab.usablePayloadFromClass` (`src/core/memory.zig:293`)

- **签名**：`pub inline fn usablePayloadFromClass(class: usize) usize`。
- **作用**：计算slab class可供用户使用的容量。
- **实现**：返回block_sizes[class]-block_header_size。
- **所有权 / 错误 / 调用**：class须合法；结果是class容量，可能大于原始请求，不能混同逻辑已记账字节。

### `SmallObjectSlab.allocAtIndex` (`src/core/memory.zig:302`)

- **签名**：`inline fn allocAtIndex(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize, comptime stamp_class: bool) ![*]u8`。
- **作用**：在指定class取一个空闲block，必要时补arena。
- **实现**：free_arenas[index]存在则用它，否则try addArena(backing,index)；随后popFreeBlock(arena,index,stamp_class)。
- **所有权 / 错误 / 调用**：可能因新arena分配失败返回错误。返回未初始化user字节，GC路径可关闭stamp_class但须随后按GC协议初始化prefix；不自行触发GC或更新MemoryAccount。

### `SmallObjectSlab.popFreeBlock` (`src/core/memory.zig:310`)

- **签名**：`inline fn popFreeBlock(self: *SmallObjectSlab, arena: *Arena, index: usize, comptime stamp_class: bool) [*]u8`。
- **作用**：从arena空闲block链取头并转成已分配状态。
- **实现**：读取first_free_block并断言非free_nil，取得header中next，更新链头。启用prefetch时预取下一free block，nil折为本arena第0块并断言范围。将header.index_or_next改存自身索引；stamp_class时写class字节，used_blocks加一，满arena从free链移除，返回userData。
- **所有权 / 错误 / 调用**：不清零用户payload；预取只是提示，不建立分配或可访问性保证。要求arena/class/free链已一致，函数自身无OOM返回。

### `SmallObjectSlab.freeAtIndex` (`src/core/memory.zig:345`)

- **签名**：`inline fn freeAtIndex(self: *SmallObjectSlab, backing: *const std.mem.Allocator, ptr: [*]u8, index: usize) void`。
- **作用**：把一个已分配slab block归还其arena并维护空闲链。
- **实现**：从user取header及已保存block索引，据class大小反算arena；重写class字节以清除GC记账高位，检查索引/class/used。把block接到空闲头，原arena满则加入free_arenas，再used_blocks减一；变空则releaseEmptyArena。
- **所有权 / 错误 / 调用**：不调用对象析构或单独扣MemoryAccount字节，调用方先完成上层协议。index边界断言在读取block_sizes之后，不能当成任意错误输入的安全验证。backing借指针，仅冷释放路径需要allocator值；重复free违反合同。

### `SmallObjectSlab.releaseEmptyArena` (`src/core/memory.zig:390`)

- **签名**：`noinline fn releaseEmptyArena(self: *SmallObjectSlab, backing: *const std.mem.Allocator, index: usize, arena: *Arena) void`。
- **作用**：保留每class的一块空arena，释放额外空arena。
- **实现**：取free_arenas[index]非空head；head就是arena则保留。head仍有已用块时把本arena移到free链头保留；head已空则从all/free两链摘本arena，通知on_release，清magic，再以arenaBacking选择allocator按实际arenaAllocation范围rawFree。
- **所有权 / 错误 / 调用**：调用前须arena已空且在free链。释放的是物理arena，不逐block析构或扣逻辑账户；保留分支仍维持observer登记。不是每次空arena都释放，也不是任意调用都能重建链不变量。

### `SmallObjectSlab.deinit` (`src/core/memory.zig:409`)

- **签名**：`pub fn deinit(self: *SmallObjectSlab, backing: std.mem.Allocator) void`。
- **作用**：释放slab全部arena并复位slab字段。
- **实现**：逐class all-arena链先保存next，再on_release通知、清magic、rawFree对应范围；最后self.*=.{}。
- **所有权 / 错误 / 调用**：不要求used_blocks为0，也不逐对象析构，调用方必须已结束所有payload使用。复位同时清arena_backing和observer，空状态重复deinit无操作。

### `SmallObjectSlab.addArena` (`src/core/memory.zig:425`)

- **签名**：`noinline fn addArena(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) !*Arena`。
- **作用**：分配并初始化指定class的新arena。
- **实现**：以(4096-arena_header_size)/block_size算block_count，申请header加整块区的实际长度并要求4096对齐。初始化arena及所有block的free后继/class字节，接all/free链，最后通知on_create并返回。
- **所有权 / 错误 / 调用**：rawAlloc为null返回OutOfMemory；请求长度可小于4096，不能写成必然申请整4096字节。class字节初始化清GC记账高位，但不清零全部payload；observer为void，登记失败不由本函数回滚或传播。

### `SmallObjectSlab.classIndex` (`src/core/memory.zig:458`)

- **签名**：`inline fn classIndex(byte_count: usize, alignment: std.mem.Alignment) ?usize`。
- **作用**：按payload大小和对齐选择slab class。
- **实现**：对齐大于slab_alignment则null；totalBlockSize失败则null；否则blockSizeIndex得到首个可容纳class。
- **所有权 / 错误 / 调用**：payload不包含block header；函数只分类，不分配。totalBlockSize先做alignForward的算术边界同样适用，不能保证任意usize输入均平稳返回null。

### `SmallObjectSlab.blockSizeIndex` (`src/core/memory.zig:473`)

- **签名**：`inline fn blockSizeIndex(total_size: usize) usize`。
- **作用**：用分段公式将总block尺寸向上取到size class。
- **实现**：断言total_size<=512；<=16返回0，<=128返回(total+7)/8-2，<=256返回(total+15)/16+6，其余返回(total+31)/32+14。编译期对1..512与线性查表逐项交叉验证。
- **所有权 / 错误 / 调用**：参数已含header，不再加8；0也会落第0类但正常totalBlockSize拒绝零payload。范围外违反合同，不返回可恢复错误。

### `SmallObjectSlab.totalBlockSize` (`src/core/memory.zig:501`)

- **签名**：`inline fn totalBlockSize(byte_count: usize) ?usize`。
- **作用**：计算非零payload的8字节对齐尺寸加slab header。
- **实现**：byte_count==0返回null；alignForward到8，再std.math.add加入block_header_size，add溢出或总尺寸>512返回null，否则返回总尺寸。
- **所有权 / 错误 / 调用**：checked add仅覆盖加header，前面的alignForward不是同一catch保护，不能描述为所有超大输入都安全返回null。正常可承载payload上限为504字节。

### `SmallObjectSlab.arenaBlocks` (`src/core/memory.zig:509`)

- **签名**：`inline fn arenaBlocks(arena: *Arena) [*]u8`。
- **作用**：取得arena内第一个block的字节地址。
- **实现**：arena指针转byte pointer后加arena_header_size。
- **所有权 / 错误 / 调用**：仅几何计算，无magic或归属验证，不代表第一个block当前可分配。

### `SmallObjectSlab.userPtrWithinArena` (`src/core/memory.zig:527`)

- **签名**：`pub fn userPtrWithinArena(base: usize, addr: usize) ?[*]u8`。
- **作用**：在已验证的arena中将内部地址映射到所属block的user起点。
- **实现**：读magic不匹配则null；addr早于blocks起点返回null；以arena记录class的block_size除出index，越过block_count返回null，否则返回block起点加block_header_size。
- **所有权 / 错误 / 调用**：base必须先由外层成员集合证明可读；magic检查不能安全探测任意未映射地址。prefix内部地址也映射到同一user；不检查free链、heap_accounted、kind或publication，不能仅凭返回值当成存活GC对象。

### `SmallObjectSlab.forEachArenaBlock` (`src/core/memory.zig:547`)

- **签名**：`pub fn forEachArenaBlock( base: usize, context: *anyopaque, visit: *const fn (ctx: *anyopaque, user: [*]u8, is_free: bool) void, ) void`。
- **作用**：枚举arena每块并按空闲链报告is_free。
- **实现**：magic不符返回；用四个u64收集free链索引，遇nil/越界或guard超过block_count停止，然后遍历所有block并回调user及位图状态。
- **所有权 / 错误 / 调用**：base须有效可读，class/count须符合arena几何；guard防无限遍历而非报告链损坏。未到达的free节点会被当作非free，不能把诊断输出当全面结构验证；回调不得破坏后续遍历依赖的arena。

### `SmallObjectSlab.blockHeaderAt` (`src/core/memory.zig:571`)

- **签名**：`inline fn blockHeaderAt(arena: *Arena, block_idx: u16, block_size: usize) *BlockHeader`。
- **作用**：按arena、块索引和总块尺寸定位header。
- **实现**：arenaBlocks加block_idx*block_size后alignCast并ptrCast。
- **所有权 / 错误 / 调用**：不验证index/count或class一致性；对齐断言不能替代成员验证。

### `SmallObjectSlab.blockHeaderFromUser` (`src/core/memory.zig:575`)

- **签名**：`inline fn blockHeaderFromUser(ptr: [*]u8) *BlockHeader`。
- **作用**：从精确user起点回退到slab block header。
- **实现**：user整数地址减block_header_size并转指针。
- **所有权 / 错误 / 调用**：不验证输入或查arena；内部指针、空指针或非slab内存不满足前置条件。

### `SmallObjectSlab.userData` (`src/core/memory.zig:579`)

- **签名**：`inline fn userData(header: *BlockHeader) [*]u8`。
- **作用**：从block header取得用户区域起点。
- **实现**：header转byte pointer后加block_header_size。
- **所有权 / 错误 / 调用**：不改变分配状态、不初始化字节；GC租户该user地址可作为collector handle，但不是slab prefix地址。

### `SmallObjectSlab.arenaFromBlock` (`src/core/memory.zig:583`)

- **签名**：`inline fn arenaFromBlock(header: *BlockHeader, block_idx: u16, block_size: usize) *Arena`。
- **作用**：用block索引反算所属arena地址。
- **实现**：header地址减block_idx*block_size，再减arena_header_size。
- **所有权 / 错误 / 调用**：依赖header中存储的已分配block索引及正确class；不通过mask或成员表验证，不适合把free后继误作索引。

### `SmallObjectSlab.arenaAllocation` (`src/core/memory.zig:588`)

- **签名**：`inline fn arenaAllocation(arena: *Arena) []u8`。
- **作用**：重建arena原始后备分配的slice。
- **实现**：按arena.block_size_idx取block尺寸，长度为arena_header_size+block_count*block_size；从arena基址构造slice。
- **所有权 / 错误 / 调用**：长度排除不足一块的尾部，可能小于arena_size；只借用范围，不释放，需与创建时相同allocator及arena_alignment配对。

### `SmallObjectSlab.arenaBacking` (`src/core/memory.zig:594`)

- **签名**：`inline fn arenaBacking(self: *const SmallObjectSlab, fallback: std.mem.Allocator) std.mem.Allocator`。
- **作用**：选择arena物理后备allocator。
- **实现**：arena_backing有值用它，否则返回fallback。
- **所有权 / 错误 / 调用**：只返回allocator副本，不改变配置；释放时必须选到与创建时匹配的allocator。

### `SmallObjectSlab.addArenaList` (`src/core/memory.zig:598`)

- **签名**：`fn addArenaList(self: *SmallObjectSlab, index: usize, arena: *Arena) void`。
- **作用**：将arena插到指定class全部arena链头。
- **实现**：置prev=null、next=旧head，旧head存在则回写prev，最后替换arenas[index]。
- **所有权 / 错误 / 调用**：不修改free链或observer，不验证arena是否已在链；重复插入会破坏合同。

### `SmallObjectSlab.removeArena` (`src/core/memory.zig:605`)

- **签名**：`fn removeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void`。
- **作用**：从指定class全部arena双链中摘除arena。
- **实现**：有prev则连prev.next，无prev则断言当前head并移动head；有next回写next.prev；清本节点next/prev。
- **所有权 / 错误 / 调用**：不释放、不修改free链或发observer通知；成员关系由调用方保证，局部head断言不是完整链审计。

### `SmallObjectSlab.addFreeArena` (`src/core/memory.zig:617`)

- **签名**：`fn addFreeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void`。
- **作用**：把可分配arena加入class空闲链，保留空spare的头部位置。
- **实现**：已有head且其used_blocks为0并非本arena时，将本arena插到head之后并修复双链；其它情况插到free链头。
- **所有权 / 错误 / 调用**：保留空arena优先分配的策略，不扫描全链查重复或统计空arena数；须传尚未在free链的节点。

### `SmallObjectSlab.removeFreeArena` (`src/core/memory.zig:637`)

- **签名**：`fn removeFreeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void`。
- **作用**：从class可分配arena双链中摘节点。
- **实现**：按free_prev或head更新前向链接，再更新后继free_prev，最后清节点free_next/free_prev。
- **所有权 / 错误 / 调用**：不触碰all-arena链、used_blocks或物理存储；调用者必须维持所属class与成员关系正确。

### `MemoryAccount.init` (`src/core/memory.zig:714`)

- **签名**：`pub fn init(allocator: std.mem.Allocator) MemoryAccount`。
- **作用**：创建尚未接入runtime facade的账户值。
- **实现**：allocator/persistent_allocator/backing_allocator均取传入allocator，其它字段用默认值。
- **所有权 / 错误 / 调用**：不分配、不启用slab、无GC回调；返回后还可移动，后续建立self引用前须先放到稳定地址。

### `MemoryAccount.accountedMallocSize` (`src/core/memory.zig:727`)

- **签名**：`pub fn accountedMallocSize(request_bytes: usize, slab_class: ?usize) usize`。
- **作用**：确定给定分配路线的记账尺寸。
- **实现**：有slab_class则取class总大小减block_header_bytes，再加malloc_overhead；无class直接返回request_bytes。
- **所有权 / 错误 / 调用**：不查slab是否启用。Darwin overhead为0，其它平台8，因此slab账并非所有平台都等于class总大小；standalone不再额外加overhead。

### `MemoryAccount.accountedSizeForRequest` (`src/core/memory.zig:736`)

- **签名**：`pub fn accountedSizeForRequest(request_bytes: usize, alignment: std.mem.Alignment) usize`。
- **作用**：估算一个可走slab请求的记账尺寸。
- **实现**：按request_bytes/alignment求SmallObjectSlab.classIndex，再交accountedMallocSize。
- **所有权 / 错误 / 调用**：无self参数，不考虑某账户small_slab_enabled；不能无条件当作所有实际分配的最终账。

### `MemoryAccount.creditAlloc` (`src/core/memory.zig:740`)

- **签名**：`inline fn creditAlloc(self: *MemoryAccount, request_bytes: usize, slab_class: ?usize) void`。
- **作用**：将分配尺寸计入当前字节账并观察cycle peak。
- **实现**：allocated_bytes以+%=增加accountedMallocSize，然后noteCyclePeak。
- **所有权 / 错误 / 调用**：加法按usize环绕，不做limit检查、不增加allocation_count或普通peak；这些由其它入口承担。

### `MemoryAccount.debitAlloc` (`src/core/memory.zig:745`)

- **签名**：`inline fn debitAlloc(self: *MemoryAccount, request_bytes: usize, slab_class: ?usize) void`。
- **作用**：从当前字节账扣除匹配路线的分配尺寸。
- **实现**：allocated_bytes以-%=扣accountedMallocSize。
- **所有权 / 错误 / 调用**：环绕减法不报告重复扣账/下溢；正确尺寸与分配路线由调用者保证。不释放内存或更新诊断计数。

### `MemoryAccount.initWithTrace` (`src/core/memory.zig:749`)

- **签名**：`pub fn initWithTrace(allocator: std.mem.Allocator, writer: *std.Io.Writer) MemoryAccount`。
- **作用**：初始化账户并指定分配日志writer。
- **实现**：三个allocator字段均设为输入allocator，同时保存trace_writer，其余默认。
- **所有权 / 错误 / 调用**：writer是借用，须在使用期有效；本函数不写日志、不拥有/关闭writer，也不自动激活accounting facade。

### `MemoryAccount.activateRuntimeAccounting` (`src/core/memory.zig:757`)

- **签名**：`pub fn activateRuntimeAccounting(self: *MemoryAccount) void`。
- **作用**：让公开current/persistent allocator通过本账户记账。
- **实现**：创建accountedAllocator facade并同时赋给allocator与persistent_allocator。
- **所有权 / 错误 / 调用**：backing_allocator不变，避免内部递归；facade保存self，必须在账户最终稳定地址上调用。之后operation可单独重定向current allocator。

### `MemoryAccount.accountedAllocator` (`src/core/memory.zig:768`)

- **签名**：`pub fn accountedAllocator(self: *MemoryAccount) std.mem.Allocator`。
- **作用**：构造以本账户为context的标准allocator接口。
- **实现**：返回ptr=self、vtable=&accounted_allocator_vtable，表映射alloc/resize/remap/free四函数。
- **所有权 / 错误 / 调用**：不分配、不自动安装到字段；借用账户，不能比账户活得更久或在其搬移后继续使用。

### `MemoryAccount.accountedAllocatorAlloc` (`src/core/memory.zig:782`)

- **签名**：`fn accountedAllocatorAlloc( context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize, ) ?[*]u8`。
- **作用**：将标准allocator分配请求转入账户无普通trigger入口。
- **实现**：忽略传入return_address，转换context，调用allocAlignedBytesNoTrigger；任何返回错误变null，否则返回slice.ptr。
- **所有权 / 错误 / 调用**：仍受账户limit及其collect-and-retry hook影响，NoTrigger不等于保证不会GC；不创建GC carrier。错误细节在标准接口上折叠为null。

### `MemoryAccount.accountedAllocatorResize` (`src/core/memory.zig:796`)

- **签名**：`fn accountedAllocatorResize( context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize, ) bool`。
- **作用**：尝试原地调整非slab标准allocator分配。
- **实现**：长度相同true；slab启用且旧/新任一尺寸可走slab则false。增长先checkAllocation差值，失败false；rawResize失败false，成功recordAccountedResize并true。
- **所有权 / 错误 / 调用**：不退化为分配复制，不修改失败请求的账；即使仍在同一slab class也拒绝不同长度。增长limit检查可能执行GC hook。

### `MemoryAccount.accountedAllocatorRemap` (`src/core/memory.zig:819`)

- **签名**：`fn accountedAllocatorRemap( context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize, ) ?[*]u8`。
- **作用**：尝试由backing直接重映射非slab分配。
- **实现**：长度相同返回原ptr；启用slab且任一尺寸eligible则null；增长检查差值，再rawRemap。成功且诊断启用且地址变化时traceFree旧址/traceAlloc新范围，然后recordAccountedResize并返回新址。
- **所有权 / 错误 / 调用**：失败null且不扣旧账；可能移动，调用方须使用返回地址。不会自行复制fallback；同地址变化长度不生成该对日志。

### `MemoryAccount.accountedAllocatorFree` (`src/core/memory.zig:848`)

- **签名**：`fn accountedAllocatorFree( context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize, ) void`。
- **作用**：将标准allocator释放请求转入账户释放入口。
- **实现**：忽略return_address，context转self，调用freeAlignedBytes(bytes,alignment)。
- **所有权 / 错误 / 调用**：要求匹配账户、长度、对齐及原分配协议；不是任意GC carrier的析构入口。

### `MemoryAccount.recordAccountedResize` (`src/core/memory.zig:859`)

- **签名**：`fn recordAccountedResize(self: *MemoryAccount, old_len: usize, new_len: usize) void`。
- **作用**：按已成功resize的长度差更新账与峰值。
- **实现**：增长普通加差值，缩小普通减差值；noteCyclePeak，诊断构建另updatePeak。
- **所有权 / 错误 / 调用**：不同于credit/debit的显式环绕运算；不改变allocation_count、alloc/free调用计数，也不执行实际resize或limit检查。

### `MemoryAccount.alloc` (`src/core/memory.zig:870`)

- **签名**：`pub inline fn alloc(self: *MemoryAccount, comptime T: type, count: usize) ![]T`。
- **作用**：按类型和数量分配owned slice。
- **实现**：调用allocInternal(T,count,true)。
- **所有权 / 错误 / 调用**：返回字节未初始化；调用者通过同账户free释放，GC类型另遵守单对象及发布协议。true只允许普通trigger路径，生产是否触发仍受编译期allocation_gc_trigger_enabled控制。

### `MemoryAccount.allocElements` (`src/core/memory.zig:879`)

- **签名**：`pub fn allocElements( self: *MemoryAccount, count: usize, elem_size: usize, alignment: std.mem.Alignment, ) ![]u8`。
- **作用**：按运行时元素尺寸分配非GC字节范围。
- **实现**：coverage启用先记录调用点；count为0返回空slice；checked mul溢出OutOfMemory。构造is_gc=false、prefix0、kind0、trigger_gc=true的SlowLayout调用allocSlowErased，返回payload范围。
- **所有权 / 错误 / 调用**：使用给定alignment并以freeAlignedBytes配对；不构造GC prefix，不初始化元素。只显式检查count==0，不能把elem_size==0也描述成同一早退。

### `MemoryAccount.reallocElements` (`src/core/memory.zig:905`)

- **签名**：`pub noinline fn reallocElements( self: *MemoryAccount, old_ptr: [*]u8, old_count: usize, new_count: usize, elem_size: usize, alignment: std.mem.Alignment, ) ![]u8`。
- **作用**：为精确长度元素缓冲区分配更大的替代范围。
- **实现**：断言new_count>old_count；先allocElements，再checked mul算旧有效字节，非零则memcpy，old_count非零则freeAlignedBytes旧范围，返回新slice。
- **所有权 / 错误 / 调用**：新分配失败保留旧buf；只支持增长，不尝试原地resize。旧乘法在分配之后且无errdefer释放新buf，但合法增长与成功新乘法下旧乘法不应溢出；不可把此实现描述为任意无效参数都事务回滚。

### `MemoryAccount.allocNoTrigger` (`src/core/memory.zig:923`)

- **签名**：`pub inline fn allocNoTrigger(self: *MemoryAccount, comptime T: type, count: usize) ![]T`。
- **作用**：按类型分配并跳过普通allocation trigger。
- **实现**：调用allocInternal(T,count,false)。
- **所有权 / 错误 / 调用**：所有权与alloc一致；仍可执行limit检查的collect-and-retry，调用者不得据NoTrigger推断不可能发生GC。

### `MemoryAccount.slabPopHot` (`src/core/memory.zig:931`)

- **签名**：`inline fn slabPopHot(self: *MemoryAccount, index: usize, comptime stamp_class: bool) ?[*]u8`。
- **作用**：只从已有可分配arena取slab block。
- **实现**：free_arenas[index]为空返回null，否则调用popFreeBlock并传stamp_class。
- **所有权 / 错误 / 调用**：不创建arena、不独立检查small_slab_enabled，也不记MemoryAccount账；null供调用者进入慢路径。

### `MemoryAccount.noteAllocDiagnostics` (`src/core/memory.zig:936`)

- **签名**：`inline fn noteAllocDiagnostics( self: *MemoryAccount, comptime is_create: bool, element_size: usize, count: usize, address: usize, ) void`。
- **作用**：按诊断开关记录一次成功分配。
- **实现**：diagnostic_accounting_enabled时allocation_count加一，按is_create增加create_calls或alloc_calls，updatePeak；可选profile计数饱和加一，再traceAlloc。
- **所有权 / 错误 / 调用**：关闭时编译消除；不增加allocated_bytes、不执行GC，调用者先完成实际分配及字节入账。trace失败不使分配失败。

### `MemoryAccount.noteFreeDiagnostics` (`src/core/memory.zig:956`)

- **签名**：`inline fn noteFreeDiagnostics(self: *MemoryAccount, comptime is_destroy: bool) void`。
- **作用**：按诊断开关记录一次释放事件。
- **实现**：启用时allocation_count减一，按is_destroy增加destroy_calls或free_calls。
- **所有权 / 错误 / 调用**：不调用traceFree、不扣allocated_bytes或释放实际内存；关闭时无操作，不能把allocation_count当所有生产模式下实时维护的数。

### `MemoryAccount.allocInternal` (`src/core/memory.zig:967`)

- **签名**：`fn allocInternal(self: *MemoryAccount, comptime T: type, count: usize, comptime trigger_gc: bool) ![]T`。
- **作用**：按类型及数量执行带slab快速路径的分配。
- **实现**：coverage记录后count==0返回空；struct声明gc_kind_tag视为GC并断言count==1。GC按sizeOf(T)/gcAlignment编译期分类；非GC checked乘法算payload并按类型对齐分类。启用slab且eligible时先检查请求字节limit、按trigger_gc调用触发器，再slabPopHot；GC初始化prefix，非GC在pop写class，随后creditAlloc及诊断并返回slice。无可用arena或不eligible进入Slow。
- **所有权 / 错误 / 调用**：不初始化payload或发布GC对象，也不走create的Object block-cell专用路径。热路径失败转slow会再次检查limit/调用trigger，不能保证一次顶层请求只触发一次回调；limit按请求字节而实际slab记账按class，二者不必相等。

### `MemoryAccount.allocInternalSlow` (`src/core/memory.zig:1036`)

- **签名**：`inline fn allocInternalSlow(self: *MemoryAccount, comptime T: type, count: usize, comptime trigger_gc: bool) ![]T`。
- **作用**：把类型化alloc的冷路径参数转成SlowLayout。
- **实现**：GC类型断言count==1，checked乘法算payload；填入is_gc、element_size、count、GC或类型对齐、standalone prefix、kind及trigger，调用allocSlowErased(...,false)，对齐转换为[]T。
- **所有权 / 错误 / 调用**：is_create=false意味着不走该慢函数的create专属extent审计commit。自身不重复count==0早退，依赖外层入口合同。

### `MemoryAccount.allocSlowErased` (`src/core/memory.zig:1058`)

- **签名**：`noinline fn allocSlowErased(self: *MemoryAccount, l: SlowLayout, comptime is_create: bool) ![*]u8`。
- **作用**：共享类型擦除的slab refill和standalone分配实现。
- **实现**：先按payload/alignment及small_slab_enabled选class；GC仅非slab路线加standalone_prefix，计算bytes后检查limit并按trigger调用GC。is_create且extent_tracking启用时为GC预留审计记录，再rawAllocForGc或rawAlloc。GC初始化prefix，creditAlloc；有reservation则commitGcExtent，最后记诊断并返回body地址。
- **所有权 / 错误 / 调用**：reserve在物理分配之前，物理失败可留下审计容量/已消耗generation，但未commit新对象；不保证内部诊断状态完全回滚。prefix+payload是普通加法。commit是身份/lifecycle审计记录，不等于Registry publication或设置heap_accounted。body未初始化。

### `MemoryAccount.free` (`src/core/memory.zig:1093`)

- **签名**：`pub inline fn free(self: *MemoryAccount, comptime T: type, slice: []T) void`。
- **作用**：释放与typed alloc对应的slice。
- **实现**：长度0无操作；GC类型走freeGc；普通类型以sizeOf(T)*%len计算字节，交freeAlignedBytes及类型对齐。
- **所有权 / 错误 / 调用**：依赖原始成功分配的长度/类型，因此释放端环绕乘法不是输入验证。只释放存储，不递归析构元素；GC对象的Registry摘链/撤账须由上层完成。

### `MemoryAccount.freeGc` (`src/core/memory.zig:1107`)

- **签名**：`fn freeGc(self: *MemoryAccount, comptime T: type, slice: []T) void`。
- **作用**：释放单个typed alloc路线的GC载体存储。
- **实现**：诊断时先traceFree，断言len==1。编译期slab eligible且账户启用slab时断言prefix分类一致，按class扣账并记free诊断，freeAtIndex；否则按gcPrefixSize+payload扣账，回退base并以gcAlignment调用backing.rawFree。
- **所有权 / 错误 / 调用**：不处理create的block-cell或extent审计生命周期路线，不自动unpublish；不能作为任意GC header通用释放器。slab启用状态及分配协议必须与创建时一致。

### `MemoryAccount.remap` (`src/core/memory.zig:1135`)

- **签名**：`pub fn remap(self: *MemoryAccount, comptime T: type, slice: []T, new_count: usize) !?[]T`。
- **作用**：尝试由backing重映射普通typed缓冲区。
- **实现**：旧slice空返回null；new_count为0则free并返回空slice。checked乘法算新旧字节，相等返回同址新长度；增长先checkAllocation，再拒绝启用slab且新旧任一eligible的路线。rawRemap失败null；成功按差额更新账和cycle peak，诊断下移动才写free/alloc日志，并updatePeak，返回新slice。
- **所有权 / 错误 / 调用**：增长limit检查在slab拒绝之前，故返回null也可能已经运行limit GC hook。没有GC prefix/identity处理，不能用于带gc_kind_tag的载体扩容。null表示调用方需要其它策略，函数不自动分配复制。

### `MemoryAccount.allocAlignedBytesNoTrigger` (`src/core/memory.zig:1172`)

- **签名**：`pub fn allocAlignedBytesNoTrigger(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![]u8`。
- **作用**：按指定对齐分配普通字节slice，关闭普通trigger。
- **实现**：委托allocAlignedBytesInternal(byte_count,alignment,false)。
- **所有权 / 错误 / 调用**：仍有limit GC hook，不承诺完全无收集；以同账户freeAlignedBytes和匹配alignment释放。

### `MemoryAccount.allocAlignedBytesInternal` (`src/core/memory.zig:1176`)

- **签名**：`fn allocAlignedBytesInternal(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment, comptime trigger_gc: bool) ![]u8`。
- **作用**：执行普通对齐字节分配的slab热路径。
- **实现**：coverage记录后零长度返回空；先checkAllocation请求字节、按trigger调用触发器。rawSlabClass有值时checked add计算按class记账后的next值，slabPopHot成功则写账、cycle peak及诊断并返回请求长度；否则Slow。
- **所有权 / 错误 / 调用**：checked add防账户加法溢出，但limit检查用请求尺寸而非class记账尺寸。返回长度不含slab多余容量；回退slow会重复limit/trigger调用，payload未初始化。

### `MemoryAccount.allocAlignedBytesSlow` (`src/core/memory.zig:1200`)

- **签名**：`noinline fn allocAlignedBytesSlow(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment, comptime trigger_gc: bool) ![]u8`。
- **作用**：完成对齐字节请求的arena refill或backing分配。
- **实现**：再次checkAllocation及可选trigger；rawSlabClass决定accounted大小，checked add成功后rawAlloc，随后写allocated_bytes、cycle peak和分配诊断，返回请求长度。
- **所有权 / 错误 / 调用**：实际分配失败不写新字节账；上游已执行的GC回调/诊断不回滚。此函数没有零长度早退，正常依赖外层过滤。

### `MemoryAccount.freeAlignedBytes` (`src/core/memory.zig:1216`)

- **签名**：`pub noinline fn freeAlignedBytes(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void`。
- **作用**：按原尺寸与对齐释放普通字节分配并扣账。
- **实现**：零长度返回；诊断下traceFree并更新allocation_count/free_calls。slab启用且eligible时读header class并断言与尺寸分类一致，按class扣账后freeAtIndex；其余按bytes.len扣账并backing.rawFree。
- **所有权 / 错误 / 调用**：只用于匹配普通字节分配，活GC的class字节含标志不能套用裸headerClassIndex。大小/对齐/账户或slab状态不匹配不是可恢复错误，也不会调用对象析构。

### `MemoryAccount.create` (`src/core/memory.zig:1235`)

- **签名**：`pub inline fn create(self: *MemoryAccount, comptime T: type) !*T`。
- **作用**：分配一个未初始化的T实例。
- **实现**：调用createInternal(T,0,true,null,null)。
- **所有权 / 错误 / 调用**：与同账户destroy配对；GC类型的body初始化和Registry发布仍由上层负责，create不是构造完成或publication证明。

### `MemoryAccount.createNoTrigger` (`src/core/memory.zig:1241`)

- **签名**：`pub inline fn createNoTrigger(self: *MemoryAccount, comptime T: type) !*T`。
- **作用**：分配一个T并关闭普通allocation trigger。
- **实现**：调用createInternal(T,0,false,null,null)。
- **所有权 / 错误 / 调用**：不关闭limit hook；其余存储所有权与create相同。

### `MemoryAccount.createObjectConstFamNoTrigger` (`src/core/memory.zig:1249`)

- **签名**：`pub inline fn createObjectConstFamNoTrigger( self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize, prepare_context: *anyopaque, comptime prepare: NonBlockObjectPrepare, ) !*T`。
- **作用**：为Object及编译期尾部尺寸分配存储，并提供非block路线准备回调。
- **实现**：编译期断言T.gc_kind_tag为Object，调用createInternal(T,fam_bytes,false,prepare_context,prepare)。
- **所有权 / 错误 / 调用**：prepare用于未成功走block的兼容路径，不是每次分配都调用；fam尺寸须与销毁协议一致。普通trigger关闭仍不排除limit GC。

### `MemoryAccount.gcPrefixSize` (`src/core/memory.zig:1269`)

- **签名**：`inline fn gcPrefixSize(comptime T: type) usize`。
- **作用**：计算standalone GC body前应预留的总对齐空间。
- **实现**：编译期将8字节gc_prefix_size向alignOf(T)上取整。
- **所有权 / 错误 / 调用**：对齐<=8时为8，过对齐类型可能更大；实际Metadata仍在body-8，多出的leading padding不属于Metadata。

### `MemoryAccount.gcAlignment` (`src/core/memory.zig:1273`)

- **签名**：`inline fn gcAlignment(comptime T: type) std.mem.Alignment`。
- **作用**：取得GC存储所需的至少8字节对齐。
- **实现**：编译期若alignOf(T)>8返回类型对齐，否则返回8。
- **所有权 / 错误 / 调用**：不分配或验证现有指针；与gcPrefixSize共同保持body及Metadata对齐。

### `MemoryAccount.gcSlabClassIndex` (`src/core/memory.zig:1277`)

- **签名**：`inline fn gcSlabClassIndex(self: *const MemoryAccount, payload_bytes: usize, alignment: std.mem.Alignment) ?usize`。
- **作用**：在账户启用slab时分类GC payload尺寸。
- **实现**：未启用返回null，否则调用SmallObjectSlab.classIndex(payload_bytes,alignment)。
- **所有权 / 错误 / 调用**：参数是payload而非含standalone prefix尺寸；只分类，null不一定是错误，可走standalone。

### `MemoryAccount.rawAllocForGc` (`src/core/memory.zig:1282`)

- **签名**：`inline fn rawAllocForGc(self: *MemoryAccount, bytes: usize, alignment: std.mem.Alignment, slab_index: ?usize) ![*]u8`。
- **作用**：按预先确定的slab分类取得GC原始内存。
- **实现**：有slab_index则allocAtIndex(backing,index,false)，否则backing.rawAlloc(bytes,alignment)或OutOfMemory。
- **所有权 / 错误 / 调用**：信任传入class，不重新查small_slab_enabled或尺寸。slab pop不写class字节，调用者须紧接GC prefix初始化；不入账、不发布。

### `MemoryAccount.prepareGcRawAudit` (`src/core/memory.zig:1287`)

- **签名**：`fn prepareGcRawAudit(self: *MemoryAccount) !void`。
- **作用**：为可选heap oracle后续raw allocation记录预留容量。
- **实现**：仅oracle编译开关启用且gc_heap_oracle非null时调用oracle.prepareRawAlloc(page_allocator)。
- **所有权 / 错误 / 调用**：可能传播OOM；不登记具体对象、不分配JS payload，关闭或无oracle时无操作。

### `MemoryAccount.reserveGcExtent` (`src/core/memory.zig:1293`)

- **签名**：`pub fn reserveGcExtent(self: *MemoryAccount) !gc_carrier.ExtentReservation`。
- **作用**：预留非block GC审计身份及生命周期记录所需资源。
- **实现**：编译期要求extent_tracking；先prepareGcRawAudit，再按lifecycle开关prepare表容量；identity启用则reserve generation，否则返回generation=0。
- **所有权 / 错误 / 调用**：这些表用page_allocator。失败可留下已扩容的诊断表；reservation不是已发布对象，也不意味着物理分配成功。extent在此指非block审计权威，不限于字符串medium/large extent。

### `MemoryAccount.commitGcExtent` (`src/core/memory.zig:1305`)

- **签名**：`pub fn commitGcExtent( self: *MemoryAccount, reservation: gc_carrier.ExtentReservation, base: usize, raw_base: usize, payload_bytes: usize, raw_bytes: usize, accounted_bytes: usize, kind: u8, ) void`。
- **作用**：提交已准备的非block carrier身份、初始生命周期及raw账影子记录。
- **实现**：identity启用时提交base/raw_base/payload/raw尺寸/generation/kind；lifecycle启用时commit(base)；oracle存在时recordRawAlloc，使用传入accounted_bytes。
- **所有权 / 错误 / 调用**：依赖此前reserve及准确尺寸，没有error返回不等于无需合同。不会设置GC heap_accounted或加入Registry列表，也不直接修改MemoryAccount字节账。

### `MemoryAccount.recordBlockGcAllocation` (`src/core/memory.zig:1340`)

- **签名**：`fn recordBlockGcAllocation(self: *MemoryAccount, base: usize, payload_bytes: usize) void`。
- **作用**：记录Object block-cell分配的oracle影子账。
- **实现**：oracle开关关闭直接返回；否则要求heap存在，按generation开关取得handle generation或0，取得rawBytesForCell；oracle非null时记录base、base-8、raw尺寸、传入accounted payload与Object kind。
- **所有权 / 错误 / 调用**：要求真实已分配block cell；相关查询null为unreachable。即使oracle指针为空，启用构建仍先执行heap查询；不发布对象或扣增主账。

### `MemoryAccount.carrierGenerationHandle` (`src/core/memory.zig:1359`)

- **签名**：`pub fn carrierGenerationHandle(self: *const MemoryAccount, base: usize) ?gc_carrier.AllocationHandle`。
- **作用**：查询block或非block carrier的当前generation handle。
- **实现**：编译期要求block_generation与extent_identity；有heap且generationHandle命中则返回，否则查询gc_extent_identity.handle(base)。
- **所有权 / 错误 / 调用**：可能null，不创建身份、不校验expected kind/生命周期、不pin；base是精确body/handle地址。

### `MemoryAccount.carrierTransition` (`src/core/memory.zig:1367`)

- **签名**：`pub fn carrierTransition(self: *MemoryAccount, base: usize, state: gc_carrier.LifecycleState) gc_carrier.ResolveError!void`。
- **作用**：为当前地址对应carrier设置生命周期状态。
- **实现**：编译期要求lifecycle；heap.containsAllocatedCell(base,8)时transitionCell，否则extent lifecycle.transition。
- **所有权 / 错误 / 调用**：错误传播；地址查询没有generation参数，不能作为stale handle防护。只维护审计生命周期，不执行对应物理动作。

### `MemoryAccount.carrierPublish` (`src/core/memory.zig:1377`)

- **签名**：`pub fn carrierPublish(self: *MemoryAccount, base: usize, accounted_bytes: usize) gc_carrier.ResolveError!void`。
- **作用**：记录carrier的published状态及记账尺寸。
- **实现**：编译期要求lifecycle；按containsAllocatedCell路由heap.publishCell或extent lifecycle.publish。
- **所有权 / 错误 / 调用**：不替代Registry publication：不初始化body、写heap_accounted、建地址索引或入队；上层负责组合协议及错误处理。

### `MemoryAccount.beginGcRawFree` (`src/core/memory.zig:1387`)

- **签名**：`pub fn beginGcRawFree(self: *MemoryAccount, base: usize) void`。
- **作用**：把审计生命周期转为raw_free_in_progress。
- **实现**：编译期要求block或extent tracking；lifecycle启用时carrierTransition，错误转panic。
- **所有权 / 错误 / 调用**：不释放存储或删除身份，不清Registry成员；若仅oracle追踪无lifecycle则没有此状态写入。

### `MemoryAccount.finishExtentGcRawFree` (`src/core/memory.zig:1398`)

- **签名**：`pub fn finishExtentGcRawFree(self: *MemoryAccount, base: usize) void`。
- **作用**：完成非block raw free的审计记录撤销。
- **实现**：编译期开关要求extent tracking；按开关依次finishRawFree生命周期表、identity表，任一错误panic；最后可选oracle.recordRawFree。
- **所有权 / 错误 / 调用**：在物理释放协议的末端调用，不自行rawFree。部分审计撤销后panic不回滚；不得在仍需用identity证明释放前过早删除。

### `MemoryAccount.finishBlockGcRawFree` (`src/core/memory.zig:1413`)

- **签名**：`pub fn finishBlockGcRawFree(self: *MemoryAccount, base: usize) void`。
- **作用**：完成block cell释放的oracle记账。
- **实现**：编译期要求block tracking；oracle开关且指针存在时recordRawFree(base)。
- **所有权 / 错误 / 调用**：不清block allocation bitmap或显式改lifecycle，不能独立完成cell释放；其它状态由block heap操作维护。

### `MemoryAccount.deinitGcCarrier` (`src/core/memory.zig:1420`)

- **签名**：`pub fn deinitGcCarrier(self: *MemoryAccount) void`。
- **作用**：销毁账户的非block审计表并解除oracle借用。
- **实现**：按开关以page_allocator deinit identity和lifecycle表，oracle启用时置gc_heap_oracle=null。
- **所有权 / 错误 / 调用**：不释放GC payload、block heap或oracle本体，不复位全部MemoryAccount字段；须在上层对象清理协议完成后调用。

### `MemoryAccount.gcAllocInfoByte` (`src/core/memory.zig:1448`)

- **签名**：`inline fn gcAllocInfoByte(ptr: *const anyopaque) u8`。
- **作用**：读取GC handle前prefix的alloc_info原始字节。
- **实现**：从ptr-8+2读取u8。
- **所有权 / 错误 / 调用**：不mask、不验证ptr；可包含class、accounted与standalone位，调用方必须按具体路线解释。

### `MemoryAccount.initGcPrefixBlockCell` (`src/core/memory.zig:1460`)

- **签名**：`inline fn initGcPrefixBlockCell(comptime T: type, meta: [*]u8) void`。
- **作用**：初始化block-cell GC prefix并保留cell索引。
- **实现**：编译期断言kind tag在低nibble内；以little-endian u16写byte2的block marker和byte3的kind，再将offset4的4字节lifetime写0。
- **所有权 / 错误 / 调用**：bytes0..2由block allocator写入的cell index保持不变；不初始化body、不置young/accounted/finalizer，kind范围检查不等同目录中允许的有效枚举检查。

### `MemoryAccount.initGcPrefix` (`src/core/memory.zig:1471`)

- **签名**：`inline fn initGcPrefix(comptime T: type, meta: [*]u8, slab_class: ?usize) void`。
- **作用**：按类型kind初始化slab或standalone GC Metadata。
- **实现**：编译期检查T.gc_kind_tag<=kind_mask，然后调用initGcPrefixTagged。
- **所有权 / 错误 / 调用**：meta必须指向body-8且满足lifetime写入对齐；不分配、入账或发布。

### `MemoryAccount.initGcPrefixTagged` (`src/core/memory.zig:1480`)

- **签名**：`inline fn initGcPrefixTagged(kind_tag: u8, meta: [*]u8, slab_class: ?usize) void`。
- **作用**：按运行时kind及slab分类写新生GC前缀。
- **实现**：断言kind<=kind_mask；standalone时将bytes0..2写0，slab时保留该索引字并断言class<=class_mask。以little-endian u16写alloc_info/class或standalone位及kind；offset4 lifetime全部置0。
- **所有权 / 错误 / 调用**：重写会清accounted/young/finalizing/finalizer及remembered状态，只能用于新分配初始化；class检查是掩码范围而非完整slab class合法性证明，kind检查同理。body不初始化，单独调用不会成为published对象。

### `MemoryAccount.createInternal` (`src/core/memory.zig:1496`)

- **签名**：`fn createInternal( self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize, comptime trigger_gc: bool, prepare_context: ?*anyopaque, comptime prepare_nonblock: ?NonBlockObjectPrepare, ) !*T`。
- **作用**：为单个实例及编译期尾部存储选择Object cell、slab或standalone路线。
- **实现**：编译期判GC类型并计算payload。仅Object且尺寸可进cell、heap存在时检查按cell class计账的limit，可选trigger并预备审计，尝试allocCellFixedPtr；成功写block prefix、入账/审计/诊断后返回。未走block的Object先调用可选prepare_nonblock。slab eligible且启用时检查payload limit/trigger，为GC reserve审计，pop后初始化prefix及记账/commit；无空闲arena或其它情况createInternalSlow。
- **所有权 / 错误 / 调用**：block返回null会回退，但limit检查、prepare audit或prepare callback错误直接传播；不是所有失败都吞掉。body未初始化，未Registry发布。slab miss可重复reserve/trigger，不保证回调恰一次。

### `MemoryAccount.createInternalSlow` (`src/core/memory.zig:1578`)

- **签名**：`inline fn createInternalSlow(self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize, comptime trigger_gc: bool) !*T`。
- **作用**：将固定类型与编译期尾部尺寸交共享create冷路径。
- **实现**：形成SlowLayout：payload=sizeOf(T)+fam_bytes、element_size=payload、count=1、GC或类型对齐、相应prefix/kind/trigger；allocSlowErased(...,true)后转换为*T。
- **所有权 / 错误 / 调用**：不重试Object cell或调用prepare_nonblock，依赖外层先完成回退准备。true选择create诊断及条件审计路径，不表示对象已初始化。

### `MemoryAccount.destroy` (`src/core/memory.zig:1594`)

- **签名**：`pub inline fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void`。
- **作用**：释放与无尾部create配对的存储。
- **实现**：委托destroyConstFam(T,0,ptr)。
- **所有权 / 错误 / 调用**：名字不意味着调用T.deinit或遍历字段；资源清理及GC unpublication由上层完成。

### `MemoryAccount.destroyConstFam` (`src/core/memory.zig:1603`)

- **签名**：`pub inline fn destroyConstFam(self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize, ptr: *T) void`。
- **作用**：为编译期尾部尺寸生成销毁路线参数。
- **实现**：计算GC分类、payload、对齐、standalone prefix、slab class，以及Object是否可进cell和相应accounted_block，调用destroyErased。
- **所有权 / 错误 / 调用**：尺寸与创建时须匹配；该wrapper不读取live容量字段，不自动确认ptr属于哪次分配，也不调用类型析构。

### `MemoryAccount.destroyErased` (`src/core/memory.zig:1636`)

- **签名**：`noinline fn destroyErased(self: *MemoryAccount, ptr: [*]u8, l: DestroyLayout) void`。
- **作用**：执行固定布局创建所对应的物理释放和账户扣账。
- **实现**：诊断先traceFree。can_block_cell且alloc_info整字节恰等block marker、heap存在时begin审计free、按accounted_block扣账、记destroy诊断、freeSmallCell并finish。否则有slab_class且slab启用时核对GC分类，按需begin审计，class扣账/freeAtIndex/finish；其余按prefix+payload扣账、回退base、按需审计并backing.rawFree。
- **所有权 / 错误 / 调用**：block分支是整字节相等，不是仅mask低位，依赖上层已撤销heap_accounted等状态。不是通用header释放器；GC publication/链与资源须先清理，传错DestroyLayout可能走错allocator。

### `MemoryAccount.createWithFam` (`src/core/memory.zig:1682`)

- **签名**：`pub inline fn createWithFam(self: *MemoryAccount, comptime T: type, fam_bytes: usize) !*T`。
- **作用**：分配GC结构体及运行时尺寸的连续尾部存储。
- **实现**：调用createWithFamInternal(T,fam_bytes,true,null,null)。
- **所有权 / 错误 / 调用**：要求类型声明gc_kind_tag；尾部未初始化，起点在T之后，调用者须保证内部布局/对齐。释放使用匹配fam尺寸和destroyWithFam；不自动发布。

### `MemoryAccount.createWithFamComptime` (`src/core/memory.zig:1688`)

- **签名**：`pub inline fn createWithFamComptime(self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize) !*T`。
- **作用**：为编译期尾部尺寸执行GC slab/standalone分配。
- **实现**：编译期要求gc_kind_tag并计算payload及对齐，coverage记录。slab class可用且启用时check limit、条件trigger、reserve审计、pop、init prefix、入账/commit/诊断；其它及pop miss交createWithFamInternalSlow(...,true)。
- **所有权 / 错误 / 调用**：此入口没有Object block-cell专用分支，也无prepare_nonblock回调，不能视作createObjectConstFamNoTrigger的同义接口。body与尾部仍需初始化。

### `MemoryAccount.createObjectWithFamNoTrigger` (`src/core/memory.zig:1720`)

- **签名**：`pub inline fn createObjectWithFamNoTrigger( self: *MemoryAccount, comptime T: type, fam_bytes: usize, prepare_context: *anyopaque, comptime prepare: NonBlockObjectPrepare, ) !*T`。
- **作用**：创建Object及运行时尾部存储并提供非block准备。
- **实现**：编译期断言Object kind，调用createWithFamInternal(T,fam_bytes,false,prepare_context,prepare)。
- **所有权 / 错误 / 调用**：关闭普通trigger，不关闭limit collect hook；prepare只在未成功走block路线后使用。

### `MemoryAccount.createWithFamInternal` (`src/core/memory.zig:1731`)

- **签名**：`fn createWithFamInternal( self: *MemoryAccount, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool, prepare_context: ?*anyopaque, comptime prepare_nonblock: ?NonBlockObjectPrepare, ) !*T`。
- **作用**：为运行时GC尾部尺寸选择Object cell或兼容分配路线。
- **实现**：checked add计算T+fam。Object且heap存在时计算prospective accounted，check limit/可选trigger/prepare audit；heap.allocCell的error catch为null以便回退。成功写prefix并入账/诊断/审计；未成功时Object调用可选prepare。随后按slab资格check/trigger/reserve/pop/init/credit/commit，miss或不适用交Slow。
- **所有权 / 错误 / 调用**：allocCell错误可回退，但之前的check/prepare错误不回退。prefix+payload和accounted辅助查询仍有普通算术/非null合同，不能概括为任意usize都有完整OOM保护。结果未构造、未发布。

### `MemoryAccount.createWithFamInternalSlow` (`src/core/memory.zig:1806`)

- **签名**：`inline fn createWithFamInternalSlow(self: *MemoryAccount, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool) !*T`。
- **作用**：为运行时尾部GC对象执行共享create慢分配。
- **实现**：编译期要求gc_kind_tag，checked add计算payload；SlowLayout固定is_gc=true、count=1及GC对齐/prefix/kind，保留trigger，调用allocSlowErased(...,true)。
- **所有权 / 错误 / 调用**：不再尝试cell或执行非block准备回调。失败传播，成功仅拥有未初始化存储。

### `MemoryAccount.gcSlabAccountedPayload` (`src/core/memory.zig:1825`)

- **签名**：`pub fn gcSlabAccountedPayload(ptr: *const anyopaque) ?usize`。
- **作用**：从GC slab prefix取得可用payload容量。
- **实现**：读alloc_info，低位是block marker或standalone位设置则null；否则用低位class调用usablePayloadFromClass。
- **所有权 / 错误 / 调用**：名称含Accounted但返回的是class减header的可用容量，不包含malloc_overhead，也不是原请求大小；不查slab启用、地址归属或publication。

### `MemoryAccount.destroyWithFam` (`src/core/memory.zig:1837`)

- **签名**：`pub fn destroyWithFam(self: *MemoryAccount, comptime T: type, ptr: *T, fam_bytes: usize) void`。
- **作用**：按prefix路线释放运行时尾部GC存储。
- **实现**：读kind类型、payload及alloc_info。Object且低位block marker、heap存在时重算class accounted，审计begin、扣账、freeSmallCell及finish。其它非standalone由header低位class直接扣账/freeAtIndex；standalone按gcPrefixSize+payload回退base并rawFree；各路线按开关记录诊断/审计。
- **所有权 / 错误 / 调用**：与destroyErased不同，block判定只mask低位。fam尺寸对block扣账和standalone实际free都须匹配；slab扣账按header class，不重算class。自身不撤销Registry或清理body资源，payload加法不是checked add。

### `MemoryAccount.createStringCell` (`src/core/memory.zig:1897`)

- **签名**：`pub fn createStringCell(self: *MemoryAccount, kind_tag: u8, total_bytes: usize) !?[*]u8`。
- **作用**：为字符串族或storage kind取得小class GC cell。
- **实现**：断言kind在mask范围内，记录coverage；尺寸不可进cell或heap缺失返回null。计算accounted并check limit、prepare audit，try heap.allocCell；null返回null，错误传播。保留cell index，写marker/kind及零lifetime，入账、审计/诊断并返回prefix起点。
- **所有权 / 错误 / 调用**：这里没有普通trigger，limit仍可GC；调用方初始化body并发布。OOM由try传播，不像Object FAM分支catch后回退。返回地址是prefix而非body；当前recordBlockGcAllocation辅助的oracle kind固定Object，不可把该影子记录描述为自动保留本函数kind_tag。

### `MemoryAccount.destroyStringCell` (`src/core/memory.zig:1918`)

- **签名**：`pub fn destroyStringCell(self: *MemoryAccount, payload: *const anyopaque, total_bytes: usize) void`。
- **作用**：释放字符串族或storage的classed cell并扣账。
- **实现**：要求heap，按total_bytes计算accounted；诊断trace body地址，按开关begin raw free，扣账并noteFreeDiagnostics(true)，freeSmallCell(payload-8)，finish block审计。
- **所有权 / 错误 / 调用**：payload为body，total_bytes含prefix且须匹配原class。创建用alloc诊断，释放实际记destroy_calls，不应写成对称free_calls。不执行字符串/storage的上层unpublish或资源清理。

### `MemoryAccount.createStringExtent` (`src/core/memory.zig:1942`)

- **签名**：`pub fn createStringExtent(self: *MemoryAccount, total_bytes: usize) ![]u8`。
- **作用**：按字符串kind申请非cell GC extent存储。
- **实现**：调用createExtent(string_kind_tag,total_bytes)。
- **所有权 / 错误 / 调用**：total_bytes含Metadata，返回slice从prefix起；具体尺寸路由/错误由createExtent处理，调用者再初始化并发布body。

### `MemoryAccount.createExtent` (`src/core/memory.zig:1949`)

- **签名**：`pub fn createExtent(self: *MemoryAccount, kind_tag: u8, total_bytes: usize) ![]u8`。
- **作用**：为超出cell尺寸的prefix carrier申请heap extent。
- **实现**：coverage记录，断言尺寸不可进cell；heap缺失OutOfMemory。checkAllocation(total)，条件reserve审计，再heap.alloc。写standalone prefix、kind和零lifetime，按total入主账；审计commit传body/payload及raw total，诊断按payload记录，返回prefix起始slice。
- **所有权 / 错误 / 调用**：不调用普通trigger；kind范围断言在实际分配后，不是入口参数验证。主账包含8字节prefix，commit的accounted_bytes参数则是payload，不能混同这两个值；body仍需初始化/发布。

### `MemoryAccount.destroyStringExtent` (`src/core/memory.zig:1984`)

- **签名**：`pub fn destroyStringExtent(self: *MemoryAccount, payload: *const anyopaque, total_bytes: usize) void`。
- **作用**：释放已撤销Registry登记的prefix extent并扣主账。
- **实现**：要求heap；按开关traceFree/body审计begin，debitAlloc(total_bytes,null)、destroy诊断，heap.free(body-8)，审计finish。
- **所有权 / 错误 / 调用**：可用于对应extent协议，名字不自动核对string kind。total须与创建账匹配；heap按base释放而主账按传入total扣，不验证二者一致，不代替unpublish。

### `MemoryAccount.createStorageCell` (`src/core/memory.zig:2010`)

- **签名**：`pub fn createStorageCell(self: *MemoryAccount, kind_tag: u8, total_bytes: usize) !StorageCell`。
- **作用**：统一选择storage carrier的cell或extent路线。
- **实现**：try createStringCell，成功返回base、按class计算的accounted body及is_block_cell=true；返回null则try createExtent，返回其base、total-8及false。
- **所有权 / 错误 / 调用**：createStringCell的错误直接传播，并非所有cell失败都会试extent。返回base是prefix起点，accounted_bytes供Registry publication，extent值不含prefix而MemoryAccount主账含prefix。

### `MemoryAccount.noteBlockCellBitmapReclaim` (`src/core/memory.zig:2033`)

- **签名**：`pub fn noteBlockCellBitmapReclaim(self: *MemoryAccount, payload: *const anyopaque) void`。
- **作用**：为bitmap回收的单个cell补诊断和审计事件。
- **实现**：诊断traceFree，按block tracking执行beginGcRawFree，noteFreeDiagnostics(true)，再finishBlockGcRawFree。
- **所有权 / 错误 / 调用**：不扣字节账、不清alloc bitmap、不释放内存；字节已由condemnation批量debitBlockBytes扣除，物理回收由heap负责。

### `MemoryAccount.debitBlockBytes` (`src/core/memory.zig:2048`)

- **签名**：`pub inline fn debitBlockBytes(self: *MemoryAccount, bytes: usize) void`。
- **作用**：一次扣除bitmap路线已判死cell的合计账。
- **实现**：bytes==0返回，否则debitAlloc(bytes,null)。
- **所有权 / 错误 / 调用**：传入量必须排除另走逐对象析构扣账的cell，且以accounted body为单位；函数不自己枚举/验证死集，不改变allocation_count。

### `MemoryAccount.hasOutstandingAllocations` (`src/core/memory.zig:2053`)

- **签名**：`pub fn hasOutstandingAllocations(self: MemoryAccount) bool`。
- **作用**：查询当前账是否仍非空。
- **实现**：诊断构建检查allocated_bytes或allocation_count任一非0；其它构建只检查allocated_bytes。
- **所有权 / 错误 / 调用**：这是账本查询，不扫描物理heap，也不证明所有外部资源均已释放。

### `MemoryAccount.enableSmallObjectSlab` (`src/core/memory.zig:2060`)

- **签名**：`pub fn enableSmallObjectSlab(self: *MemoryAccount) void`。
- **作用**：启用后续eligible分配的slab路由。
- **实现**：将small_slab_enabled置true。
- **所有权 / 错误 / 调用**：不分配arena或检查当前已有分配；必须在相关普通分配开始前配置，以免释放端按新路由误认旧backing指针。

### `MemoryAccount.useIndependentSmallObjectSlabArenaBacking` (`src/core/memory.zig:2079`)

- **签名**：`pub fn useIndependentSmallObjectSlabArenaBacking(self: *MemoryAccount) void`。
- **作用**：为slab arena配置独立物理allocator。
- **实现**：oom_injection_enabled时直接返回，否则small_slab.setArenaBacking(std.heap.smp_allocator)。
- **所有权 / 错误 / 调用**：不是page_allocator；setArenaBacking要求slab尚无arena。OOM注入模式沿用backing使物理分配可注入，逻辑payload账仍由账户维护。

### `MemoryAccount.deinitSmallObjectSlab` (`src/core/memory.zig:2084`)

- **签名**：`pub fn deinitSmallObjectSlab(self: *MemoryAccount) void`。
- **作用**：释放所有slab arenas并关闭slab路由。
- **实现**：small_slab.deinit(backing_allocator)，再small_slab_enabled=false。
- **所有权 / 错误 / 调用**：不逐payload析构或清MemoryAccount字节账，必须由外层先结束对象生命周期；slab deinit还会清observer/backing配置。

### `MemoryAccount.setLimit` (`src/core/memory.zig:2089`)

- **签名**：`pub fn setLimit(self: *MemoryAccount, limit: ?usize) void`。
- **作用**：保存可选账户分配上限。
- **实现**：直接赋值self.limit。
- **所有权 / 错误 / 调用**：不立即收集或拒绝当前超限状态，不回收已有分配；null关闭此limit检查。

### `MemoryAccount.getLimit` (`src/core/memory.zig:2093`)

- **签名**：`pub fn getLimit(self: MemoryAccount) ?usize`。
- **作用**：读取当前配置的可选分配上限。
- **实现**：返回self.limit。
- **所有权 / 错误 / 调用**：按值查询，不计算剩余可分配字节或实际物理限制。

### `MemoryAccount.checkAllocation` (`src/core/memory.zig:2097`)

- **签名**：`fn checkAllocation(self: *MemoryAccount, bytes: usize) !void`。
- **作用**：检查一次增量请求能否满足配置limit，必要时收集后重查。
- **实现**：limit为null直接成功；checked add当前账+bytes溢出OutOfMemory，<=limit成功。超过时要求limit_gc_fn和ctx，调用一次hook，再checked add并与之前捕获的limit比较，仍超则OutOfMemory。
- **所有权 / 错误 / 调用**：检查不预留容量、不入账；无limit时也不在这里检查加法溢出。hook后沿用调用前limit值；有GC副作用且不回滚，成功不保证后续backing分配成功。

### `MemoryAccount.triggerGCBeforeAllocation` (`src/core/memory.zig:2111`)

- **签名**：`inline fn triggerGCBeforeAllocation(self: *MemoryAccount, byte_count: usize) void`。
- **作用**：在编译期允许的模式调用普通分配触发钩子。
- **实现**：allocation_gc_trigger_enabled关闭时消除；否则trigger_gc_fn存在则传trigger_gc_ctx及byte_count调用。
- **所有权 / 错误 / 调用**：本函数不检查heap阈值、不自行收集，也不要求ctx非null；实际行为由hook决定，普通生产模式关闭该逐分配路径。

### `MemoryAccount.samplePeakAtCollection` (`src/core/memory.zig:2134`)

- **签名**：`pub fn samplePeakAtCollection(self: *MemoryAccount) void`。
- **作用**：在收集边界采样历史账户峰值。
- **实现**：调用updatePeak。
- **所有权 / 错误 / 调用**：与按分配跟踪cycle peak不同；生产边界采样可能错过两次采样间已释放的最高点。

### `MemoryAccount.updatePeak` (`src/core/memory.zig:2138`)

- **签名**：`fn updatePeak(self: *MemoryAccount) void`。
- **作用**：将当前字节及诊断分配数合入历史最大值。
- **实现**：两个peak字段分别max旧值和当前allocated_bytes/allocation_count。
- **所有权 / 错误 / 调用**：不读取OS RSS，不遍历分配；非诊断模式allocation_count未逐次维护时不能将其peak理解为实际对象峰值。

### `MemoryAccount.beginCyclePeakTracking` (`src/core/memory.zig:2145`)

- **签名**：`pub fn beginCyclePeakTracking(self: *MemoryAccount, output: *usize) void`。
- **作用**：安装一个借用的cycle峰值输出指针。
- **实现**：断言cycle_peak_output为空，先以当前allocated_bytes覆写output，再保存指针。
- **所有权 / 错误 / 调用**：输出须保持有效稳定直到end；会覆盖调用方原值，不支持嵌套窗口，也不负责自动结束。

### `MemoryAccount.endCyclePeakTracking` (`src/core/memory.zig:2151`)

- **签名**：`pub fn endCyclePeakTracking(self: *MemoryAccount) void`。
- **作用**：解除cycle峰值输出借用。
- **实现**：cycle_peak_output=null。
- **所有权 / 错误 / 调用**：保留输出中最后值；无active窗口时也可调用，不释放output。

### `MemoryAccount.noteCyclePeak` (`src/core/memory.zig:2155`)

- **签名**：`inline fn noteCyclePeak(self: *MemoryAccount) void`。
- **作用**：在账更新后维护已安装的cycle峰值。
- **实现**：output非null时写max(output当前值,allocated_bytes)。
- **所有权 / 错误 / 调用**：无输出时无操作；只反映MemoryAccount域，不等于RSS、提交页峰值或一次完整GC耗时。

### `MemoryAccount.rawSlabClass` (`src/core/memory.zig:2170`)

- **签名**：`inline fn rawSlabClass(self: *const MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ?usize`。
- **作用**：按当前slab开关分类普通字节请求。
- **实现**：启用时返回SmallObjectSlab.classIndex(byte_count,alignment)，否则null。
- **所有权 / 错误 / 调用**：仅分类，不分配、不验证已有指针。

### `MemoryAccount.rawAlloc` (`src/core/memory.zig:2177`)

- **签名**：`inline fn rawAlloc(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![*]u8`。
- **作用**：为普通非GC字节请求分配物理存储。
- **实现**：启用slab且class匹配时allocAtIndex(backing,index,true)；其余backing.rawAlloc，null转OutOfMemory。
- **所有权 / 错误 / 调用**：不检查limit、不入账或触发GC；slab会写raw class，返回payload未初始化。须由上层组合记账及配对释放。

### `MemoryAccount.rawFree` (`src/core/memory.zig:2186`)

- **签名**：`inline fn rawFree(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void`。
- **作用**：按当前路由释放普通非GC物理存储。
- **实现**：启用slab且eligible时读header class并断言与请求分类一致，freeAtIndex；其余backing.rawFree。
- **所有权 / 错误 / 调用**：不扣账/计诊断、不析构；要求匹配原始账户、size/alignment及路由配置，不能用于带GC标志的prefix。

### `MemoryAccount.traceAlloc` (`src/core/memory.zig:2200`)

- **签名**：`fn traceAlloc(self: *MemoryAccount, element_size: usize, count: usize, address: usize) void`。
- **作用**：向可选writer输出一条分配日志。
- **实现**：writer缺失或trace_failed返回；计算element_size*count，写A、字节数和十六进制地址；写失败仅置trace_failed。
- **所有权 / 错误 / 调用**：不传播writer错误、不flush；普通乘法依赖有效尺寸。首次写错误使后续分配和释放日志都静默停止，不影响实际分配成功。

### `MemoryAccount.traceFree` (`src/core/memory.zig:2209`)

- **签名**：`fn traceFree(self: *MemoryAccount, address: usize) void`。
- **作用**：向可选writer输出一条释放地址日志。
- **实现**：writer缺失或trace_failed返回；写F及十六进制地址，错误置trace_failed。
- **所有权 / 错误 / 调用**：日志不证明内存已释放；函数本身不free、不flush或关闭writer，失败不向调用者返回错误。

## 覆盖核对

- 清单函数数: 123
- 本文标题覆盖: 123
- 未覆盖: 无
