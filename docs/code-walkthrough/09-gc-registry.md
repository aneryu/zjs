# 09 — Registry 枢纽 / pins / lists / scheduler / diagnostics

本文件覆盖 `gc.zig` 的 Registry（发布、barrier、mark 访问器、pin、调度）以及拆出去的 lists / pins / heap tokens / diagnostics / audit print。

函数级展开。总图见 [09-gc.md](09-gc.md)。写作规范见 [_spec.md](_spec.md)。

## `gc.zig`

Z-GE Registry：发布、barrier、mark 访问器、分代、地址登记、external token、生命周期。字段顺序 load-bearing：mutator 每分配/每 barrier 碰的组在前，`stats` / `space_histogram` 在最后。`hot: HotWords align(64)` 必须 offset 0。

`publishInitialized` 有 fast/cold 两个 comptime 实例：fast 遇到逻辑large、standalone或marking时转cold。该结构用于缩小常见路径，具体尾调用和无调用叶子代码形态需要对应构建的机器码验证。


文件级配置与类型补充（按当前实现）：

- 调度常量：`minor_young_threshold=16384`、`minor_crossing_young_floor=1024`，判断的是不含owned storage的trigger census；stress分支另读完整population。`minor_hot_publish_superblock_budget=8`约束一次minor发布hot blocks所访问的superblock数，不是最多8个对象。`incremental_mark_budget_ns=1000000`是单次mark预算，非完整GC暂停的硬上限；`incremental_assist_interval_bytes=512*1024`用于分配助推节奏。`small_heap_major_headroom_bytes=16384*96=1572864`是小堆major分配余量下限。
- `Policy`默认large阈值8 KiB、native cleanup每片8 jobs、external weight 8、major debt阈值64 MiB；external/RSS软硬限制均null，cgroup两项千分比均0。它保存阈值，具体调度与OS快照判断由对应函数使用；当前结构没有mode字段。
- `Phase`为none/tracer_destroy/deinit；`MajorPhase`为idle/mark_roots/sweep。前者是Registry销毁阶段，后者是对外major阶段表示，不能当同一状态机。`SchedulerPoint`枚举allocation_slow_path/callback_boundary/idle/safepoint/urgent。
- `RequestReason`含manual、allocation_threshold、allocation_debt、external_memory、rss_pressure、collection_failed；urgency仅soon/urgent。`Request`默认pending=false、reason=null、urgency=soon，`PressureRequest`要求明确reason及urgency；是否合并或替换请求由Scheduler实现。
- `ExternalTokenEntry`是id/bytes两个默认0字段；`ExternalMemoryToken`另持Registry指针。`PinEntry`持header与默认0的count；maxInt(usize)被用作construction sentinel，不能据旧注释保证普通pin的饱和加法永远到不了该值。pins模块负责登记与解释。
- `RefKind`/`GcKind`是同一u4枚举，按顺序0..12为object、function_bytecode、var_ref、realm_context、module、shape、string、big_int、property_storage、array_storage、payload、rope、string_buffer；`gc_kind_count=13`。`AllocationCarrier`的两个分类和`representation_kind_catalog`描述允许的载体能力，具体cell/slab/extent路线仍由allocator决定。
- identity、generation、lifecycle等类型和开关转出自gc_carrier；`ResolvedExact`与`ResolvedCurrentMember`目前都只有tracing指针分支，但其解析保证不同。`MarkStack`转出自gc_mark_queue；pins/lists/scheduler/heap/diagnostics等别名不另实现算法。
- 诊断开关是进程模块全局：stress默认false、cadence默认64；minor/atom fatal、verify_minor、verify_major_all、arena_audit默认false，verify_minor_verbose默认roots_diag_enabled。`UnbarrieredStoreSite`有property overwrite、dense append、global lexical replace三个枚举及对应三项命中数组。环境变量解析由每次Registry.init触发，不是进程once初始化，未出现的值可保留此前设置。
- `pause_sample_capacity=128`，不是旧注释所称可容纳约880轮的全部历史。`PauseDistribution`给出samples/p50/p95/p99/max；空样本由诊断API返回null。`GeStats`保存累计集合/失败/释放、外部账、请求、阈值分支和析构计数，以及128项major pause环；不应把累计pause_sample_count等同环中保留项数。`Stats`是诊断快照类型，汇总账本、heap/OS、major阶段、pin/weak/finalizer队列与request状态，字段默认0/false/null不代表快照已采集。
- `HotWords`为extern struct；Registry的hot字段align(64)。编译期保证hot在offset0、phase在HotWords offset0、gate完整落于前64字节且Registry对齐至少64。此前RC热路径的历史性能注释不证明当前JSValue release读取phase；当前屏障通过gate使用此布局。
- Registry组合MemoryAccount借用指针、live lists、block heap、generation/incremental/marking、地址表、可选nonblock Object authority与slab指针、pins、external、morgue和scheduler；尾部是stats/histogram。oracle仅对应审计开关启用，普通构建字段为void。内部保存self相关指针后要求Registry地址稳定；默认字段初始化不替代initLists与serveObjectCells等运行时接线。

### `invariantChecksEnabled` (`src/core/gc.zig:135`)

- **签名**：`pub inline fn invariantChecksEnabled() bool`。
- **作用**：返回当前是否启用昂贵不变量检查。
- **实现**：std.debug.runtime_safety编译期为真则恒true，其它构建读取arena_audit。
- **所有权 / 错误 / 调用**：纯查询，不执行审计，也不在函数内限制调用点。默认arena_audit=false不表示安全构建检查关闭。

### `mCutInjection` (`src/core/gc.zig:156`)

- **签名**：`pub inline fn mCutInjection(comptime mutation: u8) bool`。
- **作用**：测试专用：是否注入指定的 Object 布局删除突变。
- **实现**：非测试构建恒 false。测试里比较全局 `m_cut_inject` 与 comptime `mutation`。
- **所有权 / 错误 / 调用**：只存在于测试二进制。

### `readStressFromEnv` (`src/core/gc.zig:163`)

- **签名**：`fn readStressFromEnv() void`。
- **作用**：读取诊断环境变量并更新模块全局配置。
- **实现**：存在MINOR_AUDIT/ARENA_AUDIT/VERIFY_MINOR变量时按非空且非0启用，fatal单独精确匹配；ATOM_AUDIT只取fatal。VERIFY_MINOR verbose为roots_diag_enabled或文本verbose。MAJOR_ALL仅roots_diag构建读取；测试突变变量仅test读取。STRESS缺失、空或0直接返回；其它文本先将stress_collect置true，再尝试解析i32，只有>1才写cadence。
- **所有权 / 错误 / 调用**：不是幂等重置：缺失变量保留旧全局值，STRESS=0也不清已true的stress_collect；1、负数或解析失败不复位已有cadence。Registry.init调用，不是进程范围once锁；多runtime共享开关，不能写成每个runtime独立配置。

### `Policy.needsProcessMemorySnapshot` (`src/core/gc.zig:390`)

- **签名**：`pub inline fn needsProcessMemorySnapshot(self: Policy) bool`。
- **作用**：判断策略是否需要OS级内存快照输入。
- **实现**：rss_soft_limit或rss_hard_limit非null，或任一cgroup soft/hard ratio非0，则true。
- **所有权 / 错误 / 调用**：不读取OS或检查是否超过限额；external soft/hard仅依赖内部计数，不触发此条件，也不按策略模式名称判断。

### `ExternalMemoryToken.release` (`src/core/gc.zig:403`)

- **签名**：`pub fn release(self: *ExternalMemoryToken) void`。
- **作用**：撤销本token的外部内存登记并使自身失效。
- **实现**：registry为null返回；保存id/bytes后先清registry/id/bytes，再调用registry.releaseExternalToken。
- **所有权 / 错误 / 调用**：只处理登记，不释放外部实际内存。对同一个已清token重复调用无操作；复制token不会自动共享清空状态，登记层如何防重复由releaseExternalToken负责。registry必须仍有效。

### `ExternalMemoryToken.deinit` (`src/core/gc.zig:413`)

- **签名**：`pub fn deinit(self: *ExternalMemoryToken) void`。
- **作用**：以释放外部登记的方式结束token。
- **实现**：调用self.release()。
- **所有权 / 错误 / 调用**：不销毁Registry或宿主buffer，幂等范围与release相同。

### `kindIsBlockCellKind` (`src/core/gc.zig:463`)

- **签名**：`pub inline fn kindIsBlockCellKind(kind: RefKind) bool`。
- **作用**：判断某个kind是否允许block-cell承载。
- **实现**：Object、string、rope、string_buffer、property_storage、array_storage、payload为true，其余六类false。
- **所有权 / 错误 / 调用**：是kind能力分类，不证明具体header实际在block或已分配；实际路由仍需看prefix/成员信息。

### `kindIsPrefixCarrier` (`src/core/gc.zig:477`)

- **签名**：`pub inline fn kindIsPrefixCarrier(kind: RefKind) bool`。
- **作用**：判断body是否从collector handle处开始、无需TraceHeader链字的prefix载体类型。
- **实现**：string、rope、string_buffer、property_storage、array_storage、payload为true，Object及其它kind为false。
- **所有权 / 错误 / 调用**：不等于block-cell分类：Object是block-capable但不属于此集合。prefix载体不应挂入普通非Object intrusive lists；rope另受固定cell布局约束。

### `kindIsOwnedStorageCell` (`src/core/gc.zig:499`)

- **签名**：`pub inline fn kindIsOwnedStorageCell(kind: RefKind) bool`。
- **作用**：分类在minor触发人口中扣除的四种叶子storage载体。
- **实现**：property_storage、array_storage、payload、string_buffer为true，其余false。
- **所有权 / 错误 / 调用**：分类本身不证明运行时只有一个引用，也不执行追踪/回收；这些载体仍计入young_count，只从young_trigger_count排除。

### `kindIsExtentCapable` (`src/core/gc.zig:512`)

- **签名**：`inline fn kindIsExtentCapable(kind: RefKind) bool`。
- **作用**：判断prefix载体是否可采用medium/large extent路由。
- **实现**：string、string_buffer、property_storage、array_storage、payload为true；rope、Object及其它kind为false。
- **所有权 / 错误 / 调用**：能力分类不表示本次分配实际使用extent；rope固定大小走cell，不应把所有prefix载体直接当extent。

### `representationKindDescriptor` (`src/core/gc.zig:548`)

- **签名**：`pub inline fn representationKindDescriptor(kind: RefKind) *const RepresentationKindDescriptor`。
- **作用**：按kind枚举序号取得静态载体目录项。
- **实现**：返回representation_kind_catalog[@intFromEnum(kind)]的const指针；编译期断言目录长度、序号及block分类与谓词一致。
- **所有权 / 错误 / 调用**：借用静态常量，不分配或验证某个具体对象。AllocationCarrier目录是允许类别，不执行分配路由；旧注释“只有普通Object可进block”已不适用。

### `frontierEpochSafe` (`src/core/gc.zig:576`)

- **签名**：`pub inline fn frontierEpochSafe(kind: GcKind) bool`。
- **作用**：判断kind是否允许以稳定裸header指针进入跨切片mark前沿。
- **实现**：除realm_context和shape外，当前其它11个kind均true。
- **所有权 / 错误 / 调用**：只按kind分类，不验证发布、condemned或地址归属。Shape可迁移结构而同步追踪；Realm当前也保留同步路线，false不等同不受tracer管理。

### `ratioPerMille` (`src/core/gc.zig:680`)

- **签名**：`pub fn ratioPerMille(numerator: usize, denominator: usize) usize`。
- **作用**：计算受1000上限约束的整数千分比。
- **实现**：denominator为0返回0；numerator*1000溢出时以maxInt(usize)代替scaled，再整数除法并min(1000)。
- **所有权 / 错误 / 调用**：不分配。乘法饱和发生在除法之前，因此大数时不等同于无限精度的min(1000,numerator*1000/denominator)，不能保证数学比例精确。

Metadata为8字节、8字节对齐的extern struct：size_class在offset0占u16，alloc_info在offset2，flags在offset3，lifetime从offset4占4字节。size_class随分配路线解释为编码大小、slab块索引或block-cell索引，不能单凭字段名当成class号。metadata_prefix_size=8，string_prefix_size沿用该值；相关尺寸、偏移和bit编码有编译期断言。

AllocInfo是packed u8：低5位block_size_idx、bit5 reserved、bit6 heap_accounted、bit7 standalone。block-cell用保留marker识别而非普通slab class；heap_accounted表示发布记账状态，不是mark或分配位图本身。BlockFlags同为packed u8：低4位RefKind（13种，0..12），bit4 young、bit5 finalizing、bit6 needs_finalizer、bit7 reserved。kind并非源码旧注释所说低3位，析构责任也已不在lifetime尾部。

TraceHeaderState为4字节extern布局：u16 mark_epoch、u8 object_shape_summary、u8 TraceHeaderFlags。后者整字节reserved默认0。摘要低7位由Object shape投影使用，非Object应为0；高bit7是remembered membership cache，允许构造中carrier持有。trace_object_shape_summary_mask=0x7F、trace_remembered_mask=0x80，编译期保证不重叠且覆盖整字节。Header epoch初始0表示未标记，condemned_mark_epoch=65535为保留戳；block/extent实际mark另有位图/表项，不应混淆这些epoch来源。

barrier_young_bit与barrier_remembered_bit通过将仅设置对应字段的Metadata bitCast成u64推导，barrier_skip_bits为两者OR；编译期验证各为单bit且不重叠、默认Metadata不带跳过条件。不能把它们硬编码成不考虑字节序的整数移位；该掩码只表达owner事实，不自动执行屏障或维护remembered表。

TraceHeader只有一个8字节next_non_object链字，Header/GCObjectHeader/ObjectHeader都是其别名。真实Object的handle等于body起点，不能访问该别名的链字段；prefix carrier也没有可借用的链字。链sentinel直接使用存储字段且没有Metadata前缀。object_deferred_link_body_offset=8现用于固定Object.shape_ref位置，不表示仍在该位置存放已退役的延迟释放后继。

### `barrierOwnerWord` (`src/core/gc.zig:911`)

- **签名**：`pub inline fn barrierOwnerWord(header: *const Header) u64`。
- **作用**：一次读取header前的metadata作为屏障判定字。
- **实现**：取header.metaConst().*并bitCast为u64。
- **所有权 / 错误 / 调用**：普通对齐读取，不是atomicLoad，不改变状态；输入须为带有效prefix的header，sentinel不能调用。得到的是整8字节布局，不仅kind或young位。

### `TraceHeader.meta` (`src/core/gc.zig:935`)

- **签名**：`pub inline fn meta(self: *TraceHeader) *Metadata`。
- **作用**：借用header前的可变Metadata。
- **实现**：将self地址减metadata_prefix_size并转为*Metadata。
- **所有权 / 错误 / 调用**：不验证映射、kind或发布，不分配；要求真实carrier prefix存在。纯链sentinel没有prefix，不适用。

### `TraceHeader.metaConst` (`src/core/gc.zig:939`)

- **签名**：`pub inline fn metaConst(self: *const TraceHeader) *const Metadata`。
- **作用**：只读借用header前的Metadata。
- **实现**：以self地址减metadata_prefix_size构造const指针。
- **所有权 / 错误 / 调用**：const只约束此指针访问，不提供并发快照或有效性检查。

### `TraceHeader.nextNonObject` (`src/core/gc.zig:945`)

- **签名**：`pub inline fn nextNonObject(self: *const TraceHeader) ?*TraceHeader`。
- **作用**：读取真实非Object list header的后继。
- **实现**：安全构建断言meta.flags.kind!=object，随后返回next_non_object。
- **所有权 / 错误 / 调用**：Object调用不返回null而是前置条件违例；关闭安全检查会把其body首字当链接。prefix载体也不因此成为合法list member，调用方须有真实链字。

### `TraceHeader.setNextNonObject` (`src/core/gc.zig:951`)

- **签名**：`inline fn setNextNonObject(self: *TraceHeader, next: ?*TraceHeader) void`。
- **作用**：更新真实非Object list header的后继。
- **实现**：安全构建断言kind不是object，再赋值next_non_object。
- **所有权 / 错误 / 调用**：不调整前驱、长度或其它成员状态；只适用于合法链载体，不可用于Object或无TraceHeader链字的prefix body。

### `bodyOffsetFromHeader` (`src/core/gc.zig:969`)

- **签名**：`pub inline fn bodyOffsetFromHeader(comptime kind: GcKind) usize`。
- **作用**：返回此编译期kind转换助手规定的header到body偏移。
- **实现**：object为0，所有其它枚举kind均返回sizeOf(TraceHeader)，当前8字节。
- **所有权 / 错误 / 调用**：这是函数实际映射，不可当成所有prefix载体物理布局的统一规则：string/rope/storage等真实handle即body的路径不应套用此助手。它不查看实际对象、prefix或分配路线。

### `bodyAddressFromHeader` (`src/core/gc.zig:991`)

- **签名**：`pub inline fn bodyAddressFromHeader(comptime kind: GcKind, header: *const GCObjectHeader) usize`。
- **作用**：按指定kind的转换规则计算body整数地址。
- **实现**：正常使用bodyOffsetFromHeader；测试mutation 4可将Object偏移改为TraceHeader大小，安全构建检测Object非零偏移并panic；最后header地址加offset。
- **所有权 / 错误 / 调用**：不验证实际header kind或地址有效性，kind由调用方编译期给出。Object正常返回原地址，其它返回加8；不能替代prefix carrier自身的转换协议。

### `headerNeedsFinalizer` (`src/core/gc.zig:1019`)

- **签名**：`pub inline fn headerNeedsFinalizer(h: *const Header) bool`。
- **作用**：读取metadata中的析构责任标志。
- **实现**：直接返回h.metaConst().flags.needs_finalizer。
- **所有权 / 错误 / 调用**：不查询block finalizer bitmap或extent表，不执行析构；不同存储列之间的一致性由发布/标记析构责任等写入路径保证。

### `headerCondemned` (`src/core/gc.zig:1063`)

- **签名**：`pub inline fn headerCondemned(h: *const Header) bool`。
- **作用**：检查header lifetime是否带持久condemnation戳。
- **实现**：monotonic原子读取u16 mark_epoch并比较condemned_mark_epoch=maxInt(u16)。
- **所有权 / 错误 / 调用**：O(1)读prefix，不查doomed链/bitmap缓存，不证明存储仍分配；free cell可能保留旧戳直到复用初始化。

### `stampHeaderCondemned` (`src/core/gc.zig:1070`)

- **签名**：`inline fn stampHeaderCondemned(h: *Header) void`。
- **作用**：将header lifetime写成保留的condemnation epoch。
- **实现**：monotonic atomicStore写condemned_mark_epoch。
- **所有权 / 错误 / 调用**：不自行摘live链、设置block doomed位图或执行析构；调用方先建立判死条件并完成相应成员协议。原子写不使整个condemnation过程成为原子事务。

### `assertInitialHeaderLifetime` (`src/core/gc.zig:1074`)

- **签名**：`inline fn assertInitialHeaderLifetime(h: *const Header) void`。
- **作用**：断言新发布前header lifetime符合初始约束。
- **实现**：要求mark_epoch==0且lifetime.flags.reserved==0；kind不是Object时另断言object_shape_summary低7位为0。
- **所有权 / 错误 / 调用**：保留高bit7的remembered lease，构造期间即可由屏障设置；Object低7位可带shape投影。不是要求四字节lifetime全零，也不检查所有alloc_info或BlockFlags位。安全断言不返回可恢复错误。

MetadataSemanticState仅有registry_published和construction_block_object，选择两套不同的prefix检查合同。FailureKind为none/out_of_memory/payload_mark_failed（0/1/2），CollectionError为OutOfMemory/PayloadMarkFailed；CollectionResult保存freed_objects与duration_ns，默认0。InvariantError按列表/分配账/identity/pin/代际/condemned/representation/尾部属性storage/延迟payload根等检查区分错误；一个错误值不保证对应唯一根因。list*与IntrusiveHeaderList等在此只是gc_registry_lists实现的别名，不是另一套链算法。

### `verifyMetadataSemantics` (`src/core/gc.zig:1194`)

- **签名**：`pub fn verifyMetadataSemantics( meta: *const Metadata, expected_kind: GcKind, state: MetadataSemanticState, ) InvariantError!void`。
- **作用**：在不读取body的前提下核对metadata kind、分配类别及指定发布状态约束。
- **实现**：先kind匹配，再按目录拒绝不允许的block marker；block与standalone不可同时成立，standalone必须block_size_idx=0，非block/slab索引须小于slab class_count。registry_published要求heap_accounted、standalone size_class非0、lifetime reserved为0，非Object shape摘要低7位为0。construction_block_object要求Object且block marker、未accounted/非standalone、young/finalizing/BlockFlags.reserved为false，并要求epoch=0、shape低7位=0和lifetime reserved=0。
- **所有权 / 错误 / 调用**：构造分支允许needs_finalizer及remembered高位，已发布分支不在此禁止这些标志或核查mark epoch。AllocInfo.reserved未被本函数检查；也不解析size_class编码值、cell索引、对象布局、真实映射/列表或pin成员。返回首个分类错误，成功仅证明所列prefix条件，不能替代实际carrier/发布审计。

### `Registry.init` (`src/core/gc.zig:1543`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry`。
- **作用**：创建绑定MemoryAccount与Policy的Registry初值。
- **实现**：调用readStressFromEnv更新全局配置，返回memory指针、scheduler.policy及BlockHeap.init；OOM注入配置时block backing用account.backing_allocator，否则page_allocator，其余字段用默认值。
- **所有权 / 错误 / 调用**：不在此绑定自引用sentinel或分配block；最终地址确定后还须initLists。借用account，生命周期须覆盖Registry；不能称此函数创建了完整可发布对象的运行时。

### `Registry.initLists` (`src/core/gc.zig:1558`)

- **签名**：`pub fn initLists(self: *Registry) void`。
- **作用**：在Registry最终地址绑定自引用链状态并刷新屏障门控。
- **实现**：依次refreshBarrierGate、lists.init、morgue.init。
- **所有权 / 错误 / 调用**：应在发布header之前调用；两个init只在未初始化时绑定，不是用于清空活链的重置接口。已绑定结构不能随意按值移动后期待此函数修复所有旧地址。

### `Registry.deinit` (`src/core/gc.zig:1564`)

- **签名**：`pub fn deinit(self: *Registry, rt: anytype) void`。
- **作用**：按依赖顺序拆除Registry仍管理的载体与辅助存储。
- **实现**：先中止/失效cycle envelope、关闭marking并排空前沿，设phase=deinit；销毁pin账中construction shell。先处理nonblock Object并排延迟payload finalizer，再消费普通链：Shape、VarRef和bytecode分别暂存，VarRef先prepare，其余适用kind直接销毁并排延迟finalizer。之后依次销毁bytecode、记账并free VarRef结构、销毁Shape并deinit shape表；调用lists.init、external/pins.deinit、destroyAllStringCarriersForDeinit，再释放nonblock authority、地址/代际/marking表、block heap；按配置核对/释放oracle及carrier账，最后phase=none。
- **所有权 / 错误 / 调用**：依赖JSRuntime此前host-quiescent回收等teardown前置流程，不能单独保证对所有剩余block Object执行析构；block_heap.deinit本身只归还存储。Object与bytecode结构由自身析构释放，不延迟到Shape之后；持有栈只安排资源依赖。此函数无整体self重置，不承诺重复deinit安全；外部token、pin及借用指针在相关存储销毁后不能继续使用。

### `Registry.reportExternalAlloc` (`src/core/gc.zig:1728`)

- **签名**：`pub fn reportExternalAlloc(self: *Registry, bytes: usize) !ExternalMemoryToken`。
- **作用**：登记一笔带token的外部内存并累积GC调度债务。
- **实现**：bytes=0返回默认空token；先external.add取得id，成功后饱和更新external_bytes/peak/alloc_count；bytes*external_weight乘法溢出取maxInt，再饱和加到allocation_debt，返回registry/id/bytes。
- **所有权 / 错误 / 调用**：add失败上抛且不走后续统计；不实际分配宿主buffer，也不在此调用requestGC或做OS内存检查，调用层负责调度。token用于后续对称撤销live账，债务另按major完成重置。

### `Registry.reportExternalAllocUntracked` (`src/core/gc.zig:1748`)

- **签名**：`pub fn reportExternalAllocUntracked(self: *Registry, bytes: usize) void`。
- **作用**：为已由GC payload承载的逻辑外部字节记账，不创建token。
- **实现**：零字节忽略；饱和增加external_bytes、external_untracked_bytes、peak、alloc_count及加权allocation_debt。
- **所有权 / 错误 / 调用**：当前用于inline BufferPayload字节分类，不应让真实离账宿主分配借此绕过token/调度协议；无失败返回，不执行立即pressure检查。

### `Registry.reportExternalFree` (`src/core/gc.zig:1762`)

- **签名**：`pub fn reportExternalFree(self: *Registry, bytes: usize) void`。
- **作用**：直接扣外部live总账的原始兼容接口。
- **实现**：零字节返回，否则external_bytes饱和减bytes并饱和增加free_count。
- **所有权 / 错误 / 调用**：不释放实际内存、不移除token条目，也不扣untracked分项或allocation_debt；tracked调用应release token，避免账目不一致。

### `Registry.reportExternalFreeUntracked` (`src/core/gc.zig:1768`)

- **签名**：`pub fn reportExternalFreeUntracked(self: *Registry, bytes: usize) void`。
- **作用**：扣除untracked逻辑外部字节。
- **实现**：非零时external_bytes和external_untracked_bytes各饱和减bytes，free_count饱和加一。
- **所有权 / 错误 / 调用**：不验证请求是否超过既有账目，饱和减可掩盖过量扣减；不取消token或偿还allocation_debt。

### `Registry.releaseExternalToken` (`src/core/gc.zig:1776`)

- **签名**：`fn releaseExternalToken(self: *Registry, id: u64, bytes: usize) void`。
- **作用**：按token身份与字节数校验释放登记，并更新外部live账。
- **实现**：external.release返回malformed/unknown_id/byte_mismatch时只饱和加invalid_release_count；released为0返回，非零则external_bytes饱和减实际released_bytes，free_count饱和加一。
- **所有权 / 错误 / 调用**：没有错误返回给token；无效释放不会扣live账。释放登记不释放宿主资源，也不减少累计allocation_debt，以保留分配周转产生的调度压力。

### `Registry.externalMemoryRequestReason` (`src/core/gc.zig:1795`)

- **签名**：`pub fn externalMemoryRequestReason(self: Registry) ?RequestReason`。
- **作用**：按外部内存硬限额、分配债务、软限额顺序挑选GC请求原因。
- **实现**：external_hard_limit存在且external_bytes>=limit先返回external_memory；其次debt>=major_debt_threshold返回allocation_debt；最后外部soft达到返回external_memory，否则null。
- **所有权 / 错误 / 调用**：只查询，不锁存请求；阈值为0也按>=比较，不自动代表禁用。debt可优先于软限额。

### `Registry.externalMemoryRequestUrgency` (`src/core/gc.zig:1806`)

- **签名**：`pub fn externalMemoryRequestUrgency(self: Registry) RequestUrgency`。
- **作用**：按外部硬限额判断请求紧急程度。
- **实现**：硬限额存在且external_bytes>=limit返回urgent，否则soon。
- **所有权 / 错误 / 调用**：即使当前没有请求原因也会返回soon；只提供优先级，不判断是否应该请求，不因allocation_debt单独变urgent。

### `Registry.processMemoryRequest` (`src/core/gc.zig:1813`)

- **签名**：`pub fn processMemoryRequest(self: Registry, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest`。
- **作用**：把进程内存输入交给scheduler策略生成可选请求。
- **实现**：返回scheduler.processMemoryRequest(rss_bytes,cgroup_limit_bytes)。
- **所有权 / 错误 / 调用**：不自行读OS、更新输入或requestGC；策略优先级和零值处理由scheduler实现，返回null是无请求。

### `Registry.requestGC` (`src/core/gc.zig:1819`)

- **签名**：`pub fn requestGC(self: *Registry, reason: RequestReason, urgency: RequestUrgency) void`。
- **作用**：统计一次GC请求并交给scheduler合并锁存。
- **实现**：gc_request_count饱和加一，last_request_reason写本次reason，再scheduler.request(reason,urgency)。
- **所有权 / 错误 / 调用**：不立即收集；每次调用都计数，即使scheduler已有更强请求。last_request_reason是最近提交值，不必等于最终锁存reason。

### `Registry.hasPendingMajorRequest` (`src/core/gc.zig:1825`)

- **签名**：`pub fn hasPendingMajorRequest(self: Registry) bool`。
- **作用**：查询scheduler是否锁存major请求。
- **实现**：返回scheduler.hasPendingMajorRequest()。
- **所有权 / 错误 / 调用**：不检查当前是否允许执行、是否有垃圾或major已完成；不消费请求。

### `Registry.resetAllocationDebt` (`src/core/gc.zig:1829`)

- **签名**：`pub fn resetAllocationDebt(self: *Registry) void`。
- **作用**：清除累计分配调度债务。
- **实现**：将stats.allocation_debt置0。
- **所有权 / 错误 / 调用**：不改live字节、token或pending请求，也不自行证明major已支付该债务；上层决定调用时机。

### `Registry.addInitializedWithSize` (`src/core/gc.zig:1833`)

- **签名**：`pub inline fn addInitializedWithSize(self: *Registry, h: *GCObjectHeader, bytes: usize) !void`。
- **作用**：发布已初始化header，并为非block Object预留外部成员容量。
- **实现**：kind为Object且非block时try prepareNonBlockObjectAuthority，随后addInitializedWithSizeNoFail。
- **所有权 / 错误 / 调用**：预留失败不进入发布；本函数不分配或构造对象本体，也不代替其它载体在发布前应完成的准备。

### `Registry.prepareNonBlockObjectAuthority` (`src/core/gc.zig:1844`)

- **签名**：`pub fn prepareNonBlockObjectAuthority(self: *Registry) !void`。
- **作用**：预留非block Object成员记录容量。
- **实现**：要求nonblock_objects非null，否则unreachable；调用authority.prepare(addressRegistryAllocator())并传播失败。
- **所有权 / 错误 / 调用**：不是创建缺失authority的懒初始化函数；prepare只预留，尚未发布header。

### `Registry.addInitializedWithSizeNoFail` (`src/core/gc.zig:1852`)

- **签名**：`pub fn addInitializedWithSizeNoFail(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：进入已准备载体的通用发布流程。
- **实现**：调用publishInitialized(h,bytes,.fast)。
- **所有权 / 错误 / 调用**：void接口不意味着无需前置条件或不可能panic；所有可失败准备须由调用方先完成，carrier状态错误会在发布路径触发panic。

### `Registry.publishInitializedCold` (`src/core/gc.zig:1869`)

- **签名**：`noinline fn publishInitializedCold(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：实例化通用发布逻辑的cold分支。
- **实现**：noinline调用publishInitialized(h,bytes,.cold)。
- **所有权 / 错误 / 调用**：与fast共享同一实现，不是第二套独立协议；是否生成特定尾调用/叶子机器码需编译证据，源码只保证该分派结构。

### `Registry.publicationNeedsColdArm` (`src/core/gc.zig:1879`)

- **签名**：`inline fn publicationNeedsColdArm(self: *const Registry, is_large: bool, standalone: bool) bool`。
- **作用**：判断当前发布是否必须启用cold分支。
- **实现**：is_large或standalone为true返回true；否则incremental.markingActive为true返回true，其余false。
- **所有权 / 错误 / 调用**：只判断三个条件，不检查对象初始化、地址登记或侧表容量。is_large是Registry策略分类，不必等于block_heap的large extent。

### `Registry.publishInitialized` (`src/core/gc.zig:1885`)

- **签名**：`inline fn publishInitialized( self: *Registry, h: *GCObjectHeader, bytes: usize, comptime arm: PublicationArm, ) void`。
- **作用**：建立header发布状态及对应成员/地址/代际记录。
- **实现**：先断言初始lifetime、未finalizing/condemned/accounted，普通非Object非prefix载体还须unlinked。计算逻辑is_large并缓存alloc_info；fast遇cold条件转cold返回。standalone编码bytes到size_class，置heap_accounted；按配置记oracle和carrierPublish（失败panic）。依据kind和block marker分类，非block Object入side authority，其它非block非prefix载体入普通链；registerLiveAddressClassified后observeNewPublication。extent-capable standalone不再重复建普通occupant条目。
- **所有权 / 错误 / 调用**：写accounted发生在后续登记之前，无事务回滚保证；header和bytes须是已准备的真实载体。prefix载体没有可用intrusive链字。函数组织保证cold条件分派，但不凭源码声称特定机器码一定无调用；观察新发布可能涉及标记/代际义务，由对应函数处理。

### `Registry.addInitializedShape` (`src/core/gc.zig:1985`)

- **签名**：`pub fn addInitializedShape(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：执行Shape专用发布，standalone时转通用路径。
- **实现**：断言初始lifetime、未accounted且unlinked；standalone调用通用NoFail并返回。否则置accounted，oracle按is_large=false登记，配置开启时carrierPublish失败panic；linkTail，按cold登记地址，再observeNewPublication。
- **所有权 / 错误 / 调用**：假定调用者确实传Shape且尺寸符合专用逻辑：非standalone分支不运行isLargeAllocation比较，不重新验证kind或所有通用断言。不能因专用入口就自动证明任意自定义large阈值下分类一致。

### `Registry.encodeHeapBytes` (`src/core/gc.zig:2007`)

- **签名**：`fn encodeHeapBytes(bytes: usize) u16`。
- **作用**：把standalone记账字节数编码为u16。
- **实现**：取min(bytes,maxInt(u16))后转换；65535为溢出/回查sentinel。
- **所有权 / 错误 / 调用**：不是压缩精确大尺寸；bytes恰等65535也使用回查值，0原样保留。

### `Registry.storedHeapBytes` (`src/core/gc.zig:2011`)

- **签名**：`fn storedHeapBytes(h: *const GCObjectHeader) ?usize`。
- **作用**：尝试从standalone metadata直接读取记账大小。
- **实现**：非standalone返回null；size_class=0返回0；等于65535返回null；其它返回该值。
- **所有权 / 错误 / 调用**：null表示需按kind重新求大小，不一定是无效header；0与null不同，不验证发布状态。

### `Registry.heapByteSizeFromHeader` (`src/core/gc.zig:2018`)

- **签名**：`pub fn heapByteSizeFromHeader(rt: anytype, h: *const GCObjectHeader) usize`。
- **作用**：取得载体记账尺寸，优先采用可用standalone大小戳。
- **实现**：storedHeapBytes有值立即返回；否则Object/bytecode/Shape/BigInt调用各自尺寸方法，VarRef/Realm/Module用结构大小，string/rope/string_buffer走string尺寸助手；property/array/payload storage按block class总字节或extent.user_bytes扣metadata_prefix_size。
- **所有权 / 错误 / 调用**：不统一等于OS映射容量或语言对象净内容，不做地址有效性/发布检查。裸storage不自描述，须依赖block/extent权威；缺少应存在的extent条目会unreachable。

### `Registry.isLargeAllocation` (`src/core/gc.zig:2059`)

- **签名**：`pub fn isLargeAllocation(self: Registry, bytes: usize) bool`。
- **作用**：按Registry策略阈值判断逻辑large分类。
- **实现**：bytes非0且bytes>=policy.large_object_threshold返回true。
- **所有权 / 错误 / 调用**：不检查实际分配路线；阈值0仍排除零字节。不能等同于block_heap按64KiB阈值选择large映射。

### `Registry.isCycleCandidate` (`src/core/gc.zig:2066`)

- **签名**：`pub fn isCycleCandidate(h: *const GCObjectHeader) bool`。
- **作用**：按当前kind目录判断载体属于tracer候选。
- **实现**：对现有13种kind穷举，全部返回true。
- **所有权 / 错误 / 调用**：不检查是否真的处于引用环、已发布或地址有效；名称保留cycle历史，结果不能视为环检测。

### `Registry.recordHeapFreeWithBytes` (`src/core/gc.zig:2085`)

- **签名**：`fn recordHeapFreeWithBytes(self: *Registry, header: *GCObjectHeader, bytes: usize) void`。
- **作用**：撤销header发布账目及可选生命周期记录。
- **实现**：未heap_accounted或bytes=0直接返回；先assertFrontierAllowsReclaimKind，按bytes计算逻辑large并在oracle配置下recordUnpublish；清heap_accounted，配置开启时carrierTransition(.doomed)失败panic；standalone再清size_class。
- **所有权 / 错误 / 调用**：不实际释放内存、不摘链或清mark，也不直接扣MemoryAccount字节。bytes=0不会清发布位；调用者须给正确记账尺寸。该动作不可因已condemned而省略。

### `Registry.headerIsPinned` (`src/core/gc.zig:2108`)

- **签名**：`pub inline fn headerIsPinned(self: *const Registry, header: *const GCObjectHeader) bool`。
- **作用**：通过pin索引查询header成员身份。
- **实现**：返回pins.contains(header)。
- **所有权 / 错误 / 调用**：不读取header中的pin标志或证明仍存活；成员索引一致性由pin账维护。

### `Registry.pinHeader` (`src/core/gc.zig:2112`)

- **签名**：`pub fn pinHeader(self: *Registry, header: *GCObjectHeader) !void`。
- **作用**：为header增加pin账记录或引用计数。
- **实现**：委托pins.pin(memory,header)，传播错误。
- **所有权 / 错误 / 调用**：可能需要侧表分配；具体计数/构造根契约在pins实现，不直接执行标记或复制对象。

### `Registry.unpinHeader` (`src/core/gc.zig:2116`)

- **签名**：`pub fn unpinHeader(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：撤销一个普通pin引用。
- **实现**：调用pins.unpin(header)。
- **所有权 / 错误 / 调用**：无返回错误，不直接释放对象；构造根与饱和计数的处理由pin账协议决定，不能当作任意header销毁入口。

### `Registry.unlinkObjectWithBytes` (`src/core/gc.zig:2125`)

- **签名**：`pub fn unlinkObjectWithBytes(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：先撤销发布记录，再按载体类型移除必要live成员关系。
- **实现**：recordHeapFreeWithBytes先执行；condemned或非候选则返回。Object分支非block时removeNonBlockObject，block直接返回；其它kind已unlinked或condemned返回，否则removeGcObject。
- **所有权 / 错误 / 调用**：condemned提前退出发生在账目撤销之后。非Object分支可能读取链字，不适用于无TraceHeader链字的string/storage prefix载体，后者走专门unpublish接口。不在此返还cell或执行资源析构。

### `Registry.recordDetachedHeapFreeWithBytes` (`src/core/gc.zig:2150`)

- **签名**：`pub inline fn recordDetachedHeapFreeWithBytes(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：为已condemned且已摘成员的载体执行发布账撤销。
- **实现**：安全构建断言headerCondemned，再调用recordHeapFreeWithBytes。
- **所有权 / 错误 / 调用**：不重复摘链，不把condemned视为已完成记账；不实际释放存储。

### `Registry.createStorageCellPublished` (`src/core/gc.zig:2180`)

- **签名**：`pub fn createStorageCellPublished( self: *Registry, kind_tag: u8, total_bytes: usize, ) ![*]u8`。
- **作用**：分配并发布裸storage cell，返回可填充的body。
- **实现**：try memory.createStorageCell(kind_tag,total_bytes)，body=base+metadata_prefix_size，按cell.accounted_bytes调用addInitializedWithSizeNoFail，再返回body。
- **所有权 / 错误 / 调用**：body内容未初始化，调用方负责在使用前填充及安装owner边；仅适用预期叶子storage种类，不能借此发布尚未初始化的有出边对象。分配失败上抛，发布后的失败不由此回滚。

### `Registry.reclaimDoomedBlock` (`src/core/gc.zig:2219`)

- **签名**：`pub fn reclaimDoomedBlock(self: *Registry, block: *BlockHeapMod.Block) usize`。
- **作用**：在底层批量回收前完成必要逐cell退役记录。
- **实现**：audit_walk由lifecycle_state_enabled决定；它为真或rememberedCount非零时，按doomed word先预取候选，再逐bit对合法index调用unpublishStringCell(block.cell_size-prefix)，audit配置另noteBlockCellBitmapReclaim。之后block_heap.reclaimDoomedCells并返回cell数。
- **所有权 / 错误 / 调用**：调用前须排空finalizer子集并unlink doomed block。没有逐cell分支时可保留已空闲header的旧accounted字节，查询需先看alloc位；Runtime字节在判死时按bitmap_bytes批量扣除，不在这里重复扣。逐cell门控实际看lifecycle，不是泛指所有诊断开关。

### `Registry.destroyStorageCell` (`src/core/gc.zig:2268`)

- **签名**：`pub fn destroyStorageCell(self: *Registry, h: *GCObjectHeader) void`。
- **作用**：按block几何归还一个无需资源握手的prefix storage cell。
- **实现**：断言block marker与kindIsPrefixCarrier，取storageCellBlockTotalBytes，经accountedBodyBytesForRequest求净记账字节，unpublishStringCell后memory.destroyStringCell。
- **所有权 / 错误 / 调用**：此接口自身只做存储/发布/代际清理，不执行atom或其它资源析构；prefix断言集合比真正无析构storage更宽，调用方须证明适用，不能任意把flat string等有责任载体送入。

### `Registry.storageCellBlockTotalBytes` (`src/core/gc.zig:2278`)

- **签名**：`inline fn storageCellBlockTotalBytes(h: *const GCObjectHeader) usize`。
- **作用**：读取已知block cell的class物理尺寸。
- **实现**：header地址减metadata_prefix_size，fromCellTrusted取block，返回cell_size。
- **所有权 / 错误 / 调用**：不检查alloc、归属或kind，要求先证明block路由；结果含prefix，不是原请求长度。

### `Registry.unpublishStringCell` (`src/core/gc.zig:2283`)

- **签名**：`pub fn unpublishStringCell(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：撤销block cell的发布记录和代际owner记录。
- **实现**：断言isBlockCellHeader，recordHeapFreeWithBytes后forgetGenerationalOwner。
- **所有权 / 错误 / 调用**：名字不限定string，批量无析构cell路径也使用；不释放存储或移除extent页索引。

### `Registry.unpublishStringExtent` (`src/core/gc.zig:2289`)

- **签名**：`pub fn unpublishStringExtent(self: *Registry, h: *GCObjectHeader, bytes: usize) void`。
- **作用**：撤销extent载体的发布和代际owner记录。
- **实现**：断言extent-capable kind及standalone，recordHeapFreeWithBytes后forgetGenerationalOwner。
- **所有权 / 错误 / 调用**：不移除medium/large或extent_pages项，随后Heap.free负责归还映射和索引；不走普通intrusive链路径。

GcObjectIterator保存普通链cursor/sentinel、可空heap、young_only/unmarked_only/side_objects模式，以及sb_index/blk_index/cell_index、young_block地址和可空extent key迭代器。blk_index在block阶段结束后复用为side数组索引，heap为空表示block阶段已退役。ObjectIteration有all/dead_block/young/young_block/young_list五种，具体人口见构造函数；“Object”在名称中泛指GC载体，不限JS Object。

HeapAccountingIterator在live之外借用doomed_by_kind桶数组，捕获doomed_objects slice与sweep_current；doomed_kind_index/cursor、doomed_object_index及current_yielded记录各阶段进度。它补充仍有发布账的死亡载体，不建立引用拥有关系或稳定快照。

### `Registry.GcObjectIterator.next` (`src/core/gc.zig:2358`)

- **签名**：`pub fn next(self: *GcObjectIterator) ?*GCObjectHeader`。
- **作用**：按普通链、block、非block Object侧表、extent顺序返回所选header。
- **实现**：链阶段先保存next再返回current，到sentinel停止；block阶段调用nextYoungCell或nextCell，耗尽清heap指针。side阶段从sentinel恢复Registry，每步重读authority.items，按young/unmarked标志过滤；extent阶段依次取主表base，要求heap_accounted并断言extent kind/standalone，耗尽清extents。
- **所有权 / 错误 / 调用**：返回借用而非pin。链阶段依赖成员不变量，不再次检查accounted/young；side不重查accounted且不关闭side_objects，因此后续next仍可重读侧表。extent持有哈希迭代器，不能因side可容忍数组增长就认为所有阶段允许任意分配/删除。

### `Registry.GcObjectIterator.registryFromSentinel` (`src/core/gc.zig:2409`)

- **签名**：`inline fn registryFromSentinel(self: *const GcObjectIterator) *const Registry`。
- **作用**：由固定嵌入位置恢复所属Registry。
- **实现**：依次fieldParentPtr从sentinel到IntrusiveHeaderList，再到Lists.objects，再到Registry.lists，按需alignCast。
- **所有权 / 错误 / 调用**：依赖sentinel确属Registry.lists.objects且Registry未移动，不适用于任意独立sentinel。无查表或所有权转移。

### `Registry.GcObjectIterator.nextInBlock` (`src/core/gc.zig:2415`)

- **签名**：`fn nextInBlock(self: *GcObjectIterator, block: *BlockHeapMod.Block, young_filter: bool) ?*GCObjectHeader`。
- **作用**：按word跳过空位并枚举block内符合过滤条件的cell。
- **实现**：从cell_index读alloc word，unmarked_only时改读deadWord当前heap epoch；右移忽略已处理位，空word推进64，非空取ctz后推进cursor。候选须heap_accounted；young_filter还要求young且!block.isDoomed(index)，随后返回base+prefix。
- **所有权 / 错误 / 调用**：young过滤只查doomed位图，不含doomed_word缓存，依赖收集阶段约束；普通all模式不排除仍accounted的condemned cell。此处只按位图/前缀筛选，不追踪可达性，也不核对具体kind。

### `Registry.GcObjectIterator.nextCell` (`src/core/gc.zig:2453`)

- **签名**：`fn nextCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*GCObjectHeader`。
- **作用**：遍历全部classed superblock的已用block槽。
- **实现**：跳过非classed superblock；逐used_blocks算block基址，magic不符跳过；nextInBlock(block,false)产出则暂停，否则推进block并清cell_index，superblock耗尽再推进。
- **所有权 / 错误 / 调用**：不使用非空block索引，不枚举extent。字段保存进度而非冻结heap快照；要求映射和容器在调用协议下稳定。

### `Registry.GcObjectIterator.nextYoungCell` (`src/core/gc.zig:2479`)

- **签名**：`fn nextYoungCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*GCObjectHeader`。
- **作用**：沿young block链枚举已发布young cell。
- **实现**：young_block>1时转Block并调用nextInBlock(...,true)，产出则返回；block耗尽沿young_link推进并清cell_index，尾哨兵0/1结束。
- **所有权 / 错误 / 调用**：heap参数本身未使用，nextInBlock从self.heap取epoch；不重新检查链地址归属或magic，依赖链完整性。

### `Registry.HeapAccountingIterator.next` (`src/core/gc.zig:2510`)

- **签名**：`pub fn next(self: *HeapAccountingIterator) ?*GCObjectHeader`。
- **作用**：在普通遍历之外补充已摘出的、仍accounted的死亡载体。
- **实现**：先耗尽live；再逐kind morgue桶保存next并筛heap_accounted；随后扫描捕获的doomed_objects slice，最后最多检查一次捕获的sweep_current并仅在accounted时返回。
- **所有权 / 错误 / 调用**：计账人口包含待析构垃圾，不是可达集。没有全局去重，依赖各成员来源互斥；doomed_objects是捕获slice，不能容忍任意重分配或swap移除；链和当前回调槽的有效性也由上层保证。

### `Registry.objectIterator` (`src/core/gc.zig:2545`)

- **签名**：`pub fn objectIterator(self: *const Registry, comptime selection: ObjectIteration) GcObjectIterator`。
- **作用**：按编译期selection构造多阶段载体遍历器。
- **实现**：all从普通链头开始，包含block、非block Object侧表与extent；young从young_head开始，加young block和young side；young_block只走young block；young_list走young链后缀及young side；dead_block只走全部classed block并按unmarked筛选。sentinel始终指向objects链，游标采用默认零值。
- **所有权 / 错误 / 调用**：所有young选项均不含extent，年轻extent需另走young_extents。dead_block不含普通链和side Object。链后缀依赖young_head不变量，不逐项重查young；all不保证排除尚accounted的死亡cell。

### `Registry.heapAccountingIterator` (`src/core/gc.zig:2569`)

- **签名**：`pub fn heapAccountingIterator(self: *const Registry) HeapAccountingIterator`。
- **作用**：构造用于物理生命周期记账的人口遍历器。
- **实现**：live取objectIterator(all)，借用morgue.by_kind；捕获nonblock authority.doomed.items或空slice，以及lists.sweep_current。
- **所有权 / 错误 / 调用**：不分配或复制header存储，捕获当前slice/slot而非自动追踪未来全部变更。此人口用于账目对照，不是再次执行mark证明存活。

### `Registry.blockCellPublicationAllowance` (`src/core/gc.zig:2582`)

- **签名**：`pub fn blockCellPublicationAllowance( context: *const anyopaque, cell_addr: usize, ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind`。
- **作用**：为未发布block cell审计提供构造或终结状态分类。
- **实现**：由cell_addr+prefix取header；pins.isConstructionRoot成立返回marked_construction。否则要求未heap_accounted、finalizing、headerCondemned、kind Object且block marker，满足返回parked_finalizer，其余none。
- **所有权 / 错误 / 调用**：本回调不查询真实deferred/parked栈成员；parked_finalizer只是这些前缀条件的分类。marked_construction的mark检查由BlockHeap验证器随后执行，不由此回调执行。

### `Registry.blockCellAccountingAllowance` (`src/core/gc.zig:2605`)

- **签名**：`pub fn blockCellAccountingAllowance( context: *const anyopaque, cell_addr: usize, ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind`。
- **作用**：给记账审计提供无需当前mark的构造根例外。
- **实现**：构造root成员成立返回unmarked_construction，否则委托blockCellPublicationAllowance。
- **所有权 / 错误 / 调用**：只改变构造根mark要求；parked分类同样依赖前缀状态而非栈成员查询。输入为物理cell基址，context须指向有效Registry。

### `Registry.isBlockCellHeader` (`src/core/gc.zig:2617`)

- **签名**：`pub inline fn isBlockCellHeader(h: *const GCObjectHeader) bool`。
- **作用**：检查metadata低5位是否为block-cell路由marker。
- **实现**：比较alloc_info.block_size_idx与representation.block_cell_size_class。
- **所有权 / 错误 / 调用**：不比较整个alloc_info字节，heap_accounted叠加不改变结果；不验证实际block成员、alloc位或kind，不能将此谓词用于未经解析的任意地址。

### `Registry.unregisterNonBlockObject` (`src/core/gc.zig:2626`)

- **签名**：`fn unregisterNonBlockObject(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：撤销非block Object的独立地址和代际登记。
- **实现**：断言Object且非block；standalone时address_registry.remove，随后forgetGenerationalOwner。
- **所有权 / 错误 / 调用**：不移除nonblock side authority、不清heap_accounted或实际释放；这些是外层remove/condemn/析构的职责。

### `Registry.removeNonBlockObject` (`src/core/gc.zig:2635`)

- **签名**：`fn removeNonBlockObject(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：从live side authority移除非block Object并注销其地址/代际记录。
- **实现**：authority为空或authority.remove失败直接返回；成功才unregisterNonBlockObject。
- **所有权 / 错误 / 调用**：无成员时不会执行后续注销，不能用它代替强制修复不一致状态；不设condemned或撤发布账。

### `Registry.condemnNonBlockObject` (`src/core/gc.zig:2644`)

- **签名**：`pub fn condemnNonBlockObject(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：把live非block Object移到side authority的doomed人口。
- **实现**：先assertFrontierAllowsReclaimKind(Object)，断言kind、非block且未condemned；要求authority存在，condemn后unregisterNonBlockObject，最后stampHeaderCondemned。
- **所有权 / 错误 / 调用**：依赖发布预留的doomed容量，无分配接口；不清heap_accounted或执行析构，后续释放仍需撤账。不是可重复调用的删除函数。

### `Registry.removeGcObject` (`src/core/gc.zig:2658`)

- **签名**：`fn removeGcObject(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：从普通非Object链移除一个已链接header。
- **实现**：断言非Object；headerLinked为false返回；否则listPrevious寻找前驱，再removeGcObjectAfter。
- **所有权 / 错误 / 调用**：寻找前驱可能遍历链，不能称O(1)；依赖真实list载体，prefix载体无链字不适用。

### `Registry.removeGcObjectAfter` (`src/core/gc.zig:2666`)

- **签名**：`fn removeGcObjectAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void`。
- **作用**：用已知前驱完成常数时间摘链及young后缀修正。
- **实现**：断言previous.next==header；记录header是否young_predecessor，先unregisterLiveAddress以保留可读取的后继；需要时将young_predecessor改为previous，young_head为空则前驱置空，最后listDelAfter。
- **所有权 / 错误 / 调用**：前驱须属于正确链且紧邻header。先注销后断链有顺序要求；函数不释放存储或自行撤发布账。

### `Registry.frontierSafeHeaderAfterMarkClaim` (`src/core/gc.zig:2694`)

- **签名**：`pub inline fn frontierSafeHeaderAfterMarkClaim( self: *const Registry, header: *GCObjectHeader, ) *Header`。
- **作用**：在安全构建中检查裸header入mark前沿的条件。
- **实现**：runtime_safety时依次检查frontierEpochSafe、已accounted且未condemned、verifyMetadataSemantics已发布合同、headerMarked；任一失败panic，成功原指针返回。
- **所有权 / 错误 / 调用**：非安全构建直接返回，既不标记也不登记generation；检查的是prefix/mark合同，不执行完整Object shape投影审计或任意地址解析。

### `Registry.frontierSafeHeaderForRequeue` (`src/core/gc.zig:2726`)

- **签名**：`pub inline fn frontierSafeHeaderForRequeue( self: *const Registry, header: *GCObjectHeader, ) ?*Header`。
- **作用**：仅为已标记owner提供重入前沿候选。
- **实现**：headerMarked为false返回null，true则frontierSafeHeaderAfterMarkClaim。
- **所有权 / 错误 / 调用**：这是mark查询而非置mark，不说明对象所有边已经完全遍历；不入队，调用方负责实际requeue。

### `Registry.frontierHasEntriesForSafety` (`src/core/gc.zig:2734`)

- **签名**：`fn frontierHasEntriesForSafety(self: *Registry) bool`。
- **作用**：判断私有/共享或共享池其它活动段是否仍持有前沿。
- **实现**：本地stack.len非零或queue非空返回true，否则检查segmentPool.stats.active_segments是否非零。
- **所有权 / 错误 / 调用**：依赖活动段不为空的池协议，涵盖使用同池的helper stack；不是并发原子快照，不执行drain。

### `Registry.assertFrontierAllowsReclaimKind` (`src/core/gc.zig:2745`)

- **签名**：`pub fn assertFrontierAllowsReclaimKind(self: *Registry, kind: GcKind) void`。
- **作用**：为可进入前沿的kind检查回收时的局部安全条件。
- **实现**：非runtime_safety直接返回；frontierEpochSafe为false也返回；仅当markingActive且frontierHasEntries同时为真时panic。
- **所有权 / 错误 / 调用**：并非分别要求marking关闭和前沿为空：任一条件为false都会通过。Shape/Realm豁免；不要把它等同于更严格的assertFrontierDrainedBeforeReclaim。

### `Registry.assertFrontierDrainedBeforeReclaim` (`src/core/gc.zig:2752`)

- **签名**：`pub fn assertFrontierDrainedBeforeReclaim(self: *Registry) void`。
- **作用**：在安全构建中要求标记已关闭且所有前沿段排空。
- **实现**：markingActive则panic；随后frontierHasEntries则panic。非runtime_safety为空操作。
- **所有权 / 错误 / 调用**：只检查不清状态、不释放段；两个条件分别检查，强于按kind的回收保护。

### `Registry.headerMarked` (`src/core/gc.zig:2760`)

- **签名**：`pub inline fn headerMarked(self: *const Registry, h: *const GCObjectHeader) bool`。
- **作用**：按实际载体路由查询当前mark。
- **实现**：block marker走Block.isMarked，index取metadata.size_class、epoch取block_heap.mark_epoch；extent-capable且standalone走extent表，先断言base存在；其余monotonic读取header lifetime epoch并与marking.header_epoch比较。
- **所有权 / 错误 / 调用**：不检查accounted/alloc/condemned或任意地址有效性，依赖有效typed header。三条路的mark权威不同，不能把非block都描述成header epoch。

### `Registry.headerMarkedKnownNonBlock` (`src/core/gc.zig:2792`)

- **签名**：`pub inline fn headerMarkedKnownNonBlock(self: *const Registry, h: *const GCObjectHeader) bool`。
- **作用**：对已知使用header epoch的类型省略路由查询。
- **实现**：断言不是block marker，直接原子读lifetime.mark_epoch与header_epoch比较。
- **所有权 / 错误 / 调用**：前提比“不是block”更强：extent同样非block但mark在表中，不能调用此快捷接口。常见调用为Shape等固定header epoch载体。

### `Registry.setHeaderMarked` (`src/core/gc.zig:2797`)

- **签名**：`pub inline fn setHeaderMarked(self: *const Registry, h: *GCObjectHeader) void`。
- **作用**：按block、extent或普通header分别写当前mark。
- **实现**：block.setMark(index,heap epoch)；extent-capable standalone则extentSetMark(base,heap epoch)；其它monotonic写header_epoch。
- **所有权 / 错误 / 调用**：不先拒绝未发布或condemned、不入队或遍历边、不执行young退役；Collector.shade等上层负责这些守卫和后续义务。

### `Registry.setNeedsFinalizer` (`src/core/gc.zig:2826`)

- **签名**：`pub fn setNeedsFinalizer(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：写析构责任的header标志及对应侧权威。
- **实现**：先header.flags.needs_finalizer=true；block则设置finalizer bitmap，非block且standalone/extent-capable则设置extent表needs_finalizer；其它只保留header标志。
- **所有权 / 错误 / 调用**：只置位，不运行析构，不验证是否已发布或实际资源存在。standalone本身不足以判extent，须同时kind分类；各步不是回滚事务。

### `Registry.retireTracedYoung` (`src/core/gc.zig:2861`)

- **签名**：`pub inline fn retireTracedYoung(self: *Registry, h: *GCObjectHeader) void`。
- **作用**：在退役窗口内清除已遍历block cell的young位。
- **实现**：generation.retirementOpen为false直接返回；窗口内安全构建断言accounted且未condemned；block marker才清young，其它不改。
- **所有权 / 错误 / 调用**：不检查本函数调用前是否真的遍历完边，调用方负责；不移除young block链、不改young_count/remembered表或mark。非block人口保持原位直到其独立关闭流程。

### `Registry.setHeaderUnmarked` (`src/core/gc.zig:2880`)

- **签名**：`pub inline fn setHeaderUnmarked(self: *const Registry, h: *GCObjectHeader) void`。
- **作用**：清block mark或普通header lifetime epoch。
- **实现**：block marker时clearMark(index,当前heap epoch)；其它路径断言候选后原子写lifetime.mark_epoch=0。
- **所有权 / 错误 / 调用**：没有extent表分支，因此不能用它清除extent的有效mark；extent须走专用清理。也不守护condemned戳，调用方须限定人口/阶段。

### `Registry.advanceHeaderMarkEpoch` (`src/core/gc.zig:2893`)

- **签名**：`pub fn advanceHeaderMarkEpoch(self: *Registry) void`。
- **作用**：推进普通header epoch，回绕前清理live成员的旧戳。
- **实现**：header_epoch<65534时加一；否则沿lists.objects及nonblock authority.items将lifetime epoch清0，再设header_epoch=1。
- **所有权 / 错误 / 调用**：只扫描这两种live人口，不碰block/extent mark或morgue中的condemned戳。正常值不产生0或65535；回绕路径不再是O(1)，依赖live列表完整。

### `Registry.detachCycleCandidate` (`src/core/gc.zig:2915`)

- **签名**：`pub fn detachCycleCandidate(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：从适用live成员结构摘除候选并写condemned戳。
- **实现**：按kind检查frontier回收许可，断言未condemned；Object非block则removeNonBlockObject，block Object不摘链；其它removeGcObject，最后stamp。
- **所有权 / 错误 / 调用**：不清accounted、不释放，不自动入morgue桶；无链字prefix载体不能任意套用非Object分支。非block Object要进入side doomed人口应使用condemnNonBlockObject协议。

### `Registry.detachBlockObjectCandidate` (`src/core/gc.zig:2929`)

- **签名**：`pub inline fn detachBlockObjectCandidate(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：对已由block枚举证明归属的cell写condemned戳。
- **实现**：安全构建检查frontier、未condemned、kindIsBlockCellKind及block marker，其余构建省略这些检查；最后stampHeaderCondemned。
- **所有权 / 错误 / 调用**：名字不限定Object，可用于符合条件的string/storage等block kind。不清alloc/young/accounted、不入doomed链或更新bitmap，块级快照另负责这些事实。

### `Registry.detachCycleCandidateAfter` (`src/core/gc.zig:2942`)

- **签名**：`pub fn detachCycleCandidateAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void`。
- **作用**：以已知前驱摘除普通链候选并判死。
- **实现**：检查frontier、断言未condemned，removeGcObjectAfter(previous,header)，然后stampHeaderCondemned。
- **所有权 / 错误 / 调用**：依赖前驱正确及真实list载体，不释放存储/撤发布账，也不加入morgue。

### `Registry.abortIncrementalCycle` (`src/core/gc.zig:2957`)

- **签名**：`pub fn abortIncrementalCycle(self: *Registry) void`。
- **作用**：丢弃当前增量标记工作并使未完成退役等待major修复。
- **实现**：先abortCycleEnvelope；marking未active则返回；否则closeMarkingAndDrainFrontier、generation.abandonMajorRetirement，并增加cycles_aborted。
- **所有权 / 错误 / 调用**：不恢复已置mark或已清young，也不直接执行完整STW重算；上层后续major负责修复。即使未active，envelope中止仍发生。

### `Registry.closeMarkingAndDrainFrontier` (`src/core/gc.zig:2968`)

- **签名**：`fn closeMarkingAndDrainFrontier(self: *Registry) void`。
- **作用**：关闭标记并丢弃本地/共享前沿记录。
- **实现**：active时setMajorMarkingActive(false)，再stack.reset、queue.reset，最后assertFrontierDrainedBeforeReclaim。
- **所有权 / 错误 / 调用**：这里drain指清空/归还段，不是遍历queued header的边；不释放对象或撤销mark。其它helper私有段须已按协议归还，否则安全断言仍可失败。

### `Registry.noteCycleEnvelopeBaseline` (`src/core/gc.zig:2981`)

- **签名**：`pub fn noteCycleEnvelopeBaseline(self: *Registry, start_bytes: usize, threshold_bytes: usize) void`。
- **作用**：保存下次自动增量周期的已结算起点/阈值并开始峰值跟踪。
- **实现**：非detailed_reports返回；断言envelope未active，若旧baseline有效先endCyclePeakTracking。写next_start/next_threshold及peak=start，baseline_valid取threshold!=0；有效时把peak字段地址交MemoryAccount跟踪。
- **所有权 / 错误 / 调用**：峰值跟踪从baseline时刻开始，不是等begin才开始。threshold=0不建立有效baseline；Registry及peak字段地址须在跟踪期间稳定。

### `Registry.invalidateCycleEnvelopeBaseline` (`src/core/gc.zig:2996`)

- **签名**：`pub fn invalidateCycleEnvelopeBaseline(self: *Registry) void`。
- **作用**：使周期测量基线失效，必要时结束正在跟踪的峰值。
- **实现**：active时end tracking、清active、饱和增加skipped_cycles；否则baseline有效也end tracking；最后清baseline_valid。
- **所有权 / 错误 / 调用**：不清所有历史数值或max tuple，不中止实际GC标记。无active且仅清baseline不增加skipped。

### `Registry.beginCycleEnvelope` (`src/core/gc.zig:3009`)

- **签名**：`pub fn beginCycleEnvelope(self: *Registry, threshold_bytes: usize) void`。
- **作用**：将匹配的已保存基线转为本周期测量状态。
- **实现**：非详细模式返回，断言尚未active；基线无效或阈值不匹配时invalidate并增加skipped后返回。匹配则清baseline_valid，将next_start/threshold写cycle字段，begin_bytes取当前allocated_bytes，active置true。
- **所有权 / 错误 / 调用**：不重置peak、不重新begin tracking，沿用baseline已开启的跟踪；这是记账域峰值，不是OS RSS。阈值匹配是精确整数相等。

### `Registry.abortCycleEnvelope` (`src/core/gc.zig:3026`)

- **签名**：`fn abortCycleEnvelope(self: *Registry) void`。
- **作用**：停止一个active测量周期的峰值跟踪。
- **实现**：非active直接返回，否则endCyclePeakTracking并清active。
- **所有权 / 错误 / 调用**：不增加skipped计数，不清有效但尚未active的baseline，也不丢GC队列。统计中止与实际GC中止由外层组合。

### `Registry.finishCycleEnvelope` (`src/core/gc.zig:3032`)

- **签名**：`pub fn finishCycleEnvelope(self: *Registry) void`。
- **作用**：结算测量周期，并按最大peak/threshold比保留同周期完整tuple。
- **实现**：非active返回；结束跟踪并清active，取start/threshold/begin/peak，断言threshold非0且peak>=threshold。measured_cycles饱和加一；未有max或u128交叉乘法显示新peak/threshold更大时同时替换四个max字段。
- **所有权 / 错误 / 调用**：比值相等不替换；没有把不同周期最大值拼接。只更新诊断，不证明GC达到任何性能阈值，也不调整分配策略。

### `Registry.shadeCellForAtomBarrier` (`src/core/gc.zig:3061`)

- **签名**：`pub fn shadeCellForAtomBarrier(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：为atom屏障的已发布body设置mark并安排前沿工作。
- **实现**：已marked返回；未heap_accounted返回；其余setHeaderMarked后将frontierSafeHeaderAfterMarkClaim结果push队列，忽略push返回值。
- **所有权 / 错误 / 调用**：没有自查markingActive，调用者必须位于有效marking屏障协议。入队失败由queue锁存，调用链后续必须检查，mark不回滚；不增加这里未写入的shaded统计。不接受任意未验证地址。

### `Registry.shadeForIncrementalMark` (`src/core/gc.zig:3070`)

- **签名**：`pub inline fn shadeForIncrementalMark(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void`。
- **作用**：处理强写的新目标，或在特殊类型目标下重扫owner。
- **实现**：测试/详细模式统计calls及各早退；target已marked先返回，owner或target未published也返回。target为Shape/Realm时：owner也为Shape/Realm且target为Shape，直接标记Shape并仅对其非空proto执行未marked时标记、shaded计数与入队；target为Realm则invalidateBarrier。其它owner遇这两类target时统计requeued_owner，再仅为已marked owner取得安全header并入队。普通target直接setHeaderMarked、shaded加一、push安全前沿。
- **所有权 / 错误 / 调用**：不自查markingActive，调用方负责；普通目标分支不要求owner已marked，owner重扫分支才查。requeued_owner计数发生在owner mark检查前，不等于实际入队数。Shape特例是源码中显式proto处理，不是调用完整通用边遍历。push失败锁存在queue，void不代表成功，既有mark不回滚；Shape/Realm不入持久前沿的原因按当前生命周期/迁移协议解释，不沿用已退休RC机制。

### `Registry.shouldTryMinor` (`src/core/gc.zig:3156`)

- **签名**：`pub inline fn shouldTryMinor(self: *const Registry) bool`。
- **作用**：判断常规调度是否值得尝试minor。
- **实现**：phase非none或minorsAllowed为false先拒绝；stress_collect直接返回young_count!=0。普通模式再拒绝minorSuspended及markingActive，最后比较young_trigger_count>=minor_young_threshold。
- **所有权 / 错误 / 调用**：stress使用含owned storage的population并绕过后续suspension/marking/threshold检查，但不绕过前两项。函数不执行收集，也未直接检查待销毁队列；能否实际运行仍由调用路径决定。

### `Registry.shouldTryMinorBeforeMajor` (`src/core/gc.zig:3209`)

- **签名**：`pub inline fn shouldTryMinorBeforeMajor(self: *const Registry) bool`。
- **作用**：在whole-heap阈值已跨越时判定是否先尝试minor。
- **实现**：先检查phase及minorsAllowed；stress返回young_count!=0。普通模式先要求young_trigger_count>=minor_crossing_young_floor，再检查suspension和markingActive，全部通过返回true。
- **所有权 / 错误 / 调用**：与shouldTryMinor使用不同触发下限；stress同样绕过下限与后两项。返回true只是调度候选，不保证minor成功或避免major。

### `Registry.rememberOwnerForBulkWrite` (`src/core/gc.zig:3246`)

- **签名**：`pub inline fn rememberOwnerForBulkWrite(self: *Registry, owner: *GCObjectHeader) void`。
- **作用**：为不能提供精确child的批量写执行owner屏障。
- **实现**：barrierOwnerSkips为true立即返回，否则调用rememberOwnerForBulkWriteSlow。
- **所有权 / 错误 / 调用**：应在批量写协议中使用，后续重扫必须能看到完成后的边。入口本身不检查owner publication，检查在marking慢分支。

### `Registry.rememberOwnerForBulkWriteSlow` (`src/core/gc.zig:3251`)

- **签名**：`fn rememberOwnerForBulkWriteSlow(self: *Registry, owner: *GCObjectHeader) void`。
- **作用**：按当前阶段重排owner扫描或记录代际owner。
- **实现**：markingActive时只对heap_accounted且已marked的owner取得安全前沿并push，然后返回；非marking时young owner返回，其余rememberGenerationalOwner。
- **所有权 / 错误 / 调用**：不解码child；marking队列可重复加入owner，push失败由队列锁存且不回滚。非marking分支无heap_accounted检查。详细统计关闭快速跳过时仍需这里的young检查。

### `Registry.expectedBarrierGate` (`src/core/gc.zig:3275`)

- **签名**：`inline fn expectedBarrierGate(self: *const Registry) u64`。
- **作用**：计算当前屏障允许的owner快速跳过位。
- **实现**：markingActive或detailed_reports为true返回0，否则返回barrier_skip_bits。
- **所有权 / 错误 / 调用**：0使任何owner都不能由位测试跳过，以执行目标shade或诊断统计；不写Registry状态。

### `Registry.refreshBarrierGate` (`src/core/gc.zig:3293`)

- **签名**：`pub fn refreshBarrierGate(self: *Registry) void`。
- **作用**：发布由当前阶段和统计模式决定的门控值。
- **实现**：将expectedBarrierGate结果写入hot.barrier_gate。
- **所有权 / 错误 / 调用**：live Registry改变detailed_reports后也须调用；这是普通赋值，不提供线程间原子同步。

### `Registry.setMajorMarkingActive` (`src/core/gc.zig:3308`)

- **签名**：`pub fn setMajorMarkingActive(self: *Registry, active: bool) void`。
- **作用**：同时更新major标记状态及派生屏障门控。
- **实现**：赋值incremental.major_marking_active后调用refreshBarrierGate。
- **所有权 / 错误 / 调用**：两步构成调用协议上的状态更新，不是硬件原子事务；不启动遍历、清队列或处理generation retirement。

### `Registry.barrierOwnerSkips` (`src/core/gc.zig:3322`)

- **签名**：`pub inline fn barrierOwnerSkips(self: *const Registry, owner: *const GCObjectHeader) bool`。
- **作用**：用owner metadata位与当前门控判断是否跳过屏障。
- **实现**：runtime_safety构建断言hot.barrier_gate==expectedBarrierGate；返回barrierOwnerWord(owner)&hot.barrier_gate!=0。
- **所有权 / 错误 / 调用**：常规门控允许young或remembered owner跳过，marking/详细模式门控为0。实际函数没有旁边C2注释所称的kind断言，也不验证地址或publication；须传合法carrier。

### `Registry.rememberGenerationalOwner` (`src/core/gc.zig:3343`)

- **签名**：`inline fn rememberGenerationalOwner(self: *Registry, owner: *GCObjectHeader) void`。
- **作用**：向权威remembered map登记owner并缓存成员位。
- **实现**：summary的trace_remembered_mask已置则返回；generation.rememberOwner失败也返回；成功后才置summary高位。
- **所有权 / 错误 / 调用**：当前实现不限定Object，不沿用旧注释的Object-only说法。map插入OOM增加remembered_drops，位保持未置；void返回不证明登记成功。调用方负责old-owner等分类。

### `Registry.clearGenerationalRememberedBit` (`src/core/gc.zig:3350`)

- **签名**：`inline fn clearGenerationalRememberedBit(owner: *GCObjectHeader) void`。
- **作用**：清单个owner的remembered缓存位。
- **实现**：对lifetime.object_shape_summary按位与~trace_remembered_mask。
- **所有权 / 错误 / 调用**：保留低七位Shape摘要；不删除map条目，也不更新young census，须配合退役协议。

### `Registry.clearGenerationalRememberedBits` (`src/core/gc.zig:3354`)

- **签名**：`inline fn clearGenerationalRememberedBits(self: *Registry) void`。
- **作用**：清权威remembered map中所有owner的缓存位。
- **实现**：迭代rememberedIterator，将每个地址转header并调用clearGenerationalRememberedBit。
- **所有权 / 错误 / 调用**：不清map、不做地址存活验证；迭代期间map及owner必须有效，短暂位/map不一致受调用方退役窗口约束。

### `Registry.retireGenerationalYoungSet` (`src/core/gc.zig:3367`)

- **签名**：`pub fn retireGenerationalYoungSet(self: *Registry) void`。
- **作用**：成对清remembered缓存与权威map，并归零young计数。
- **实现**：openRetirementWindow后遍历清缓存位，再调用generation.retireYoungSet清map及young_count/young_trigger_count并关闭审计窗口。
- **所有权 / 错误 / 调用**：不逐对象清young标志，不自行追踪或宣称完成minor。该窗口是remembered一致性审计窗口，与major_retirement控制minor admission的状态不同。

### `Registry.forgetGenerationalOwner` (`src/core/gc.zig:3396`)

- **签名**：`pub inline fn forgetGenerationalOwner(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：在detach时移除代际登记并更新young计数。
- **实现**：缓存位未置时调用forgetUnremembered并返回；已置则先清位，再调用generation.forget删除map条目和更新young census。
- **所有权 / 错误 / 调用**：当前代码无Object-only或其它kind分支。未置位路径依赖位清即map不存在的不变量，审计构建在callee验证；不是只清缓存，也不释放对象。

### `Registry.generationalBarrierDetailed` (`src/core/gc.zig:3406`)

- **签名**：`inline fn generationalBarrierDetailed(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void`。
- **作用**：记录非marking目标屏障分类并登记old-to-young owner。
- **实现**：barrier_calls加一；young owner计barrier_young_owner后返回；非young target计barrier_old_target后返回；其余rememberGenerationalOwner。
- **所有权 / 错误 / 调用**：没有publication或marking检查，调用路径负责阶段选择。计数包括被young/old分类提前返回的调用；不代表真实新增map条目数。

### `Registry.auditUnbarrieredStore` (`src/core/gc.zig:3430`)

- **签名**：`pub inline fn auditUnbarrieredStore( self: *Registry, owner: *GCObjectHeader, child: ?*GCObjectHeader, comptime site: UnbarrieredStoreSite, ) void`。
- **作用**：在启用诊断时检查可疑写入是否形成未登记的old-to-young边。
- **实现**：仅runtime_safety或roots_diag_enabled构建保留；minor_audit关闭或child为空返回，否则never_inline调用slow并传编译期site。
- **所有权 / 错误 / 调用**：诊断不会补屏障或修复边；不是所有ReleaseFast都删除，roots_diag_enabled构建仍可保留。

### `Registry.auditUnbarrieredStoreSlow` (`src/core/gc.zig:3442`)

- **签名**：`fn auditUnbarrieredStoreSlow( self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader, site: UnbarrieredStoreSite, ) void`。
- **作用**：报告已发布old owner不在remembered map却引用young target的情况。
- **实现**：owner未accounted、owner young或target非young均返回；遍历权威map发现owner也返回。否则对应site命中数加一，输出site/hit/owner kind与Object class/child kind；该site首次命中dump stack，minor_audit_fatal时panic。
- **所有权 / 错误 / 调用**：不依赖remembered缓存位，不检查target publication、marking阶段或实际槽位内容；owner/target是调用者提供的有效指针。普通模式只报告，不阻止后续执行或修复登记。

### `Registry.generationalBarrier` (`src/core/gc.zig:3481`)

- **签名**：`pub inline fn generationalBarrier(self: *Registry, owner: *GCObjectHeader, child: ?*GCObjectHeader) void`。
- **作用**：执行header形式的强写屏障。
- **实现**：child为空先返回；barrierOwnerSkips为true返回；否则调用generationalBarrierSlow(owner,target)。
- **所有权 / 错误 / 调用**：空child不触发门控安全断言或统计。此函数不执行实际store，调用方承担写入顺序和合法header契约。

### `Registry.generationalBarrierSlow` (`src/core/gc.zig:3494`)

- **签名**：`fn generationalBarrierSlow(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void`。
- **作用**：按major marking或代际阶段处理精确target。
- **实现**：markingActive调用shadeForIncrementalMark并返回；否则detailed_reports调用Detailed分支。常规路径target非young返回，young target调用rememberGenerationalOwner。
- **所有权 / 错误 / 调用**：常规分支依赖入口门控已证明owner old且未remembered，不能视作任意参数独立入口。marking与remembered登记是二选一，不先后都执行。

### `Registry.generationalBarrierValue` (`src/core/gc.zig:3529`)

- **签名**：`pub inline fn generationalBarrierValue(self: *Registry, owner: *GCObjectHeader, child: JSValue) void`。
- **作用**：在需要屏障时才把JSValue转换为GC target。
- **实现**：先barrierOwnerSkips；未跳过才child.cycleMarkHeader，无header返回，否则调用generationalBarrierSlow。
- **所有权 / 错误 / 调用**：与header入口顺序不同：即使primitive也先检查owner门控。只有能解码的GC边才进入慢分支统计；不执行实际store或改变JSValue所有权。

### `Registry.markQueueAllocator` (`src/core/gc.zig:3538`)

- **签名**：`pub inline fn markQueueAllocator() std.mem.Allocator`。
- **作用**：取得标记前沿使用的基础设施allocator。
- **实现**：直接返回addressRegistryAllocator()。
- **所有权 / 错误 / 调用**：独立于JS heap account，避免GC基础设施分配重新进入JS收集漏斗；不是Registry拥有的独立arena。

### `Registry.addressRegistryAllocator` (`src/core/gc.zig:3542`)

- **签名**：`inline fn addressRegistryAllocator() std.mem.Allocator`。
- **作用**：选择GC地址索引等辅助结构的allocator。
- **实现**：返回std.heap.smp_allocator。
- **所有权 / 错误 / 调用**：与JS heap allocator/account独立；不等于每次直接page_allocator系统调用，也不意味着分配不会失败。

### `Registry.serveObjectCells` (`src/core/gc.zig:3571`)

- **签名**：`pub fn serveObjectCells(self: *Registry, account: *memory.MemoryAccount) !void`。
- **作用**：将MemoryAccount和保守地址解析连接到Registry的block heap。
- **实现**：先设置address_registry.block_heap与account.gc_object_cell_heap；oracle构建另设置account.gc_heap_oracle；随后用基础设施allocator创建并清零NonBlockObjectAuthority，保存到nonblock_objects。
- **所有权 / 错误 / 调用**：唯一显式try是authority分配，失败前的指针赋值不回滚。不是slab arena订阅函数；不可当作幂等初始化反复调用，否则可覆盖旧authority。Registry/account须保持约定生命周期和地址稳定。

### `Registry.noteSlabArenaCreated` (`src/core/gc.zig:3588`)

- **签名**：`fn noteSlabArenaCreated(ctx: *anyopaque, base: usize) void`。
- **作用**：把slab的新arena通知地址解析表。
- **实现**：将opaque ctx按对齐转换为Registry指针，调用address_registry.noteArenaCreated(addressRegistryAllocator(),base)。
- **所有权 / 错误 / 调用**：ctx须来自有效Registry；本函数无error返回，注册失败语义由Table记录，不能据void认定成功。

### `Registry.noteSlabArenaReleased` (`src/core/gc.zig:3593`)

- **签名**：`fn noteSlabArenaReleased(ctx: *anyopaque, base: usize) void`。
- **作用**：从保守地址解析的arena登记中移除释放的arena。
- **实现**：将ctx转换为Registry指针并调用address_registry.noteArenaReleased(base)。
- **所有权 / 错误 / 调用**：只是登记生命周期通知，不负责释放slab内存或所有对象的GC记账。

### `Registry.observeSlabArenas` (`src/core/gc.zig:3598`)

- **签名**：`pub fn observeSlabArenas(self: *Registry, slab: *memory.SmallObjectSlab) void`。
- **作用**：登记已有slab arenas并安装后续创建/释放通知。
- **实现**：保存arena_slab指针，先forEachArena调用noteSlabArenaCreated，再覆盖slab.arena_observer为以self为ctx的两个回调。
- **所有权 / 错误 / 调用**：保留slab供失败登记后的重新遍历；不是仅观察未来arena。替换已有observer，需外层保证生命周期与安装期间稳定，不自带并发同步。

### `Registry.registerLiveAddressClassified` (`src/core/gc.zig:3619`)

- **签名**：`inline fn registerLiveAddressClassified( self: *Registry, header: *GCObjectHeader, bytes: usize, tracked: bool, needs_occupant: bool, is_block_cell: bool, comptime arm: PublicationArm, ) void`。
- **作用**：利用发布端已有分类执行地址登记和young发布。
- **实现**：tracked为false直接返回；needs_occupant时insertLiveAddressCold；随后markPublishedYoungClassified(header,is_block_cell,arm)。
- **所有权 / 错误 / 调用**：不重新验证传入分类；地址插入失败仍继续young发布。slab/block通常依赖几何登记而无需每对象occupant，具体选择由调用方提供。

### `Registry.insertLiveAddressCold` (`src/core/gc.zig:3651`)

- **签名**：`noinline fn insertLiveAddressCold(self: *Registry, header: *GCObjectHeader, bytes: usize) void`。
- **作用**：在独立慢路径向地址表加入已发布对象范围。
- **实现**：调用address_registry.insert，catch中调用noteFailedInsert。
- **所有权 / 错误 / 调用**：没有向调用方返回error或回滚publication；失败被显式记录而非保证成功，后续收集必须遵循地址表失效/恢复协议。

### `Registry.noteYoungPublicationCensus` (`src/core/gc.zig:3673`)

- **签名**：`inline fn noteYoungPublicationCensus(self: *Registry, header: *const GCObjectHeader) void`。
- **作用**：增加young population及调度触发计数。
- **实现**：runtime_safety构建young_publications以+%=环绕加一；young_count普通加一，非owned storage kind再令young_trigger_count普通加一。
- **所有权 / 错误 / 调用**：这里只改计数，不设young flag、插入young列表或去重；同一对象重复调用会重复记账。population包含owned storage，触发计数排除它们。

### `Registry.markPublishedYoungClassified` (`src/core/gc.zig:3681`)

- **签名**：`inline fn markPublishedYoungClassified( self: *Registry, header: *GCObjectHeader, is_block_cell: bool, comptime arm: PublicationArm, ) void`。
- **作用**：按carrier分类登记新发布对象的young状态，并处理增量期发布。
- **实现**：fast arm只在runtime_safety断言marker inactive；cold arm在markingActive时先publishGreyCold。非block且extent-capable的对象断言standalone、置young并计数后返回。其它对象置young并计数，断言block分类一致；block调用noteYoungCell返回；非block Object返回；剩余断言非prefix carrier，young_head为空则要求young_predecessor已保存并以header开启suffix。
- **所有权 / 错误 / 调用**：不直接向young_extents追加条目，那属于allocator协议；非block Object由side authority按young位枚举。普通list suffix依赖发布前已保存前驱并完成尾插，不是此函数重新链接对象。即使marking期先发布到mark前沿，后面仍会设置young并计数。

### `Registry.publishGreyCold` (`src/core/gc.zig:3767`)

- **签名**：`noinline fn publishGreyCold(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：在增量期发布普通Object时建立其初始边扫描工作。
- **实现**：仅kind==object时setHeaderMarked，然后将frontierSafeHeaderAfterMarkClaim所得指针push标记队列；其它kind无操作。
- **所有权 / 错误 / 调用**：不是所有新carrier都黑化或入队。其它类型的构造完成后引用安装屏障与根扫描承担可达性协议；此函数不自查markingActive。push失败由队列锁存，mark不回滚，也不增加shaded计数。

### `Registry.unregisterLiveAddress` (`src/core/gc.zig:3789`)

- **签名**：`inline fn unregisterLiveAddress(self: *Registry, header: *GCObjectHeader) void`。
- **作用**：撤销普通list carrier的地址与代际登记，并推进young suffix头。
- **实现**：standalone时从address_registry移除；随后forgetGenerationalOwner。若young_head等于header，读取nextNonObject，后继为objects sentinel则清空head，否则将head移至后继。
- **所有权 / 错误 / 调用**：须在链字仍有效、真正unlink之前调用；不自行移除intrusive链接，也不清heap_accounted或释放内存。此处不更新young_predecessor，完整摘链由外层维护；Object与无链prefix carrier有各自路径。

### `Registry.observeNewPublication` (`src/core/gc.zig:3814`)

- **签名**：`inline fn observeNewPublication(self: *Registry, header: *GCObjectHeader, bytes: usize) void`。
- **作用**：为首次publication记录分配尺寸直方图。
- **实现**：test构建直接按Object的hasSlots2Layout调用recordObject，其它kind调用record；非test仅detailed_reports时调用recordSpacePublicationDetailed。
- **所有权 / 错误 / 调用**：当前函数体只记录histogram，没有旧注释所说的sweep-window更新；不建立地址或mark成员。默认非详细生产模式不记该诊断，重复调用会重复统计。

### `Registry.recordSpacePublicationDetailed` (`src/core/gc.zig:3833`)

- **签名**：`noinline fn recordSpacePublicationDetailed(self: *Registry, header: *GCObjectHeader, bytes: usize) void`。
- **作用**：执行详细模式publication尺寸统计的慢路径。
- **实现**：Object调用space_histogram.recordObject(bytes,hasSlots2Layout)，其余调用record(bytes)。
- **所有权 / 错误 / 调用**：函数内部不查detailed_reports，调用者负责门控；统计使用传入bytes而非重新计算实际分配大小。

### `Registry.addressSetWhole` (`src/core/gc.zig:3850`)

- **签名**：`pub fn addressSetWhole(self: *Registry, rt: anytype) bool`。
- **作用**：恢复保守地址索引的完整性，决定调用方能否依赖它回收。
- **实现**：arenasIncomplete时须有arena_slab且resyncArenas成功，否则false；occupants完整则true。否则遍历objectIterator(.all)，仅为standalone、非extent-capable且by_header缺失的对象，以heapByteSizeFromHeader计算范围并insert；任一失败返回false，全程成功才清occupantsIncomplete并返回true。
- **所有权 / 错误 / 调用**：失败保留已成功补入的记录，不回滚；sticky不完整状态保留以供重试。extent由heap自身索引负责，不能补进occupant形成无法移除的陈旧范围。该函数不自行mark、sweep或阻止回收，false由调用方遵守。

### `Registry.containsHeader` (`src/core/gc.zig:3899`)

- **签名**：`pub fn containsHeader(self: *const Registry, header: *const GCObjectHeader) bool`。
- **作用**：查询地址是否仍由Registry的live或待销毁成员结构持有。
- **实现**：先匹配sweep_current。属于block时验证cell interior索引、allocated位、精确header起点及heap_accounted后直接返回；否则查nonblock doomed数组、morgue各kind桶，再遍历objectIterator(.all)。
- **所有权 / 错误 / 调用**：包含condemned但尚未销毁成员，不能解释为仅语义存活对象。block路径没有generation或kind核对，失败也不继续其它结构；该接口与address_registry.containsHeader的候选解析用途不同。

### `Registry.resolveCurrentMember` (`src/core/gc.zig:3941`)

- **签名**：`pub fn resolveCurrentMember( self: *const Registry, key: CurrentMembershipKey, expected_kind: ?GcKind, ) CarrierResolveError!ResolvedCurrentMember`。
- **作用**：以当前地址成员资格解析header，并可核对kind。
- **实现**：把key.base转为header，address_registry.containsHeader为false返回NotFound；expected_kind不匹配返回KindMismatch；成功返回tracing header。
- **所有权 / 错误 / 调用**：使用地址索引而非Registry.containsHeader的morgue扫描；没有generation、生命周期mask或ABA保护，索引不完整时可能NotFound。返回借用指针，不pin也不延长生命。

### `Registry.allocationHandle` (`src/core/gc.zig:3955`)

- **签名**：`pub fn allocationHandle(self: *const Registry, header: *const GCObjectHeader) ?AllocationHandle`。
- **作用**：在carrier审计构建取得地址对应的generation handle。
- **实现**：编译期断言carrier.authority_audit_enabled，调用memory.carrierGenerationHandle(header地址)。
- **所有权 / 错误 / 调用**：可能null；不创建新身份或pin。生产构建不能把此接口视作始终可调用的通用句柄机制。

### `Registry.resolveExact` (`src/core/gc.zig:3961`)

- **签名**：`pub fn resolveExact( self: *const Registry, handle: AllocationHandle, expected_kind: ?GcKind, allowed_states: CarrierStateMask, ) CarrierResolveError!ResolvedExact`。
- **作用**：在carrier审计构建按身份与允许生命周期解析对象。
- **实现**：编译期要求authority_audit_enabled。以base饱和减prefix探测block；block分支调用resolveExactHandle且不跳过generation校验，额外断言返回generation一致，检查允许block kind、可选expected_kind及published时heap_accounted。非block分支先通过gc_extent_identity.resolve核对handle/可选kind，再gc_extent_lifecycle.resolve核对状态，检查header kind与identity记录一致及published时accounted。返回tracing header。
- **所有权 / 错误 / 调用**：各resolve错误直接传播；额外generation不一致属于panic防线。allowed_states由调用方明确传入，非published状态不要求accounted；不能把成功理解成永远published/live或获得所有权，也不建立pin。非block identity路径不限于GC字符串extent，按memory维护的非block identity authority处理。

## `src/core/gc_audit_print.zig`

GC VERIFY/AUDIT 的内部文本写入工具，不属于公共嵌入 API。Part 是 text([]const u8)、dec(u64)、hex(u64) 三种 tagged union 项，标签/间隔/换行都由调用点显式提供；它不是通用格式语言，也不处理有符号数。

数字转换只用固定栈缓冲。write 接受外部 Writer 并传播错误；print 另负责 stderr 锁、缓冲 flush 并忽略错误。boolText 返回静态文本，hexPad 的返回值借用调用方缓冲，因此缓冲必须保持到实际写完。

### `boolText` (`src/core/gc_audit_print.zig:17`)

- **签名**：`pub inline fn boolText(value: bool) []const u8`。
- **作用**：把 bool 映射为审计文本。
- **实现**：true 返回 "true"，false 返回 "false"。
- **所有权 / 错误 / 调用**：返回静态只读字符串，不分配、不需要释放。

### `hexPad` (`src/core/gc_audit_print.zig:22`)

- **签名**：`pub noinline fn hexPad(value: u64, width: u8, buf: *[16]u8) []const u8`。
- **作用**：在调用方缓冲区格式化至少 width 位的小写十六进制。
- **实现**：断言 width 在 1..16；先 formatHex，已有位数足够则直接返回；否则在有效字符串前填零并返回扩大的后缀。
- **所有权 / 错误 / 调用**：返回借用 buf 的切片，没有 0x 前缀、不截断较宽值。调用方须保证 buf 存活且不被覆盖；不是新分配字符串。

### `print` (`src/core/gc_audit_print.zig:33`)

- **签名**：`pub fn print(parts: []const Part) void`。
- **作用**：以 stderr 锁保护一组 GC 审计文本输出。
- **实现**：使用 64 字节局部缓冲 lockStderr，defer unlockStderr；调用 write，再 flush，两处错误均直接返回。
- **所有权 / 错误 / 调用**：此便利接口故意忽略 I/O 错误，可能只输出前缀；不返回成功保证、不自动加换行。需要错误传播的调用方使用 write。

### `write` (`src/core/gc_audit_print.zig:44`)

- **签名**：`pub noinline fn write(writer: *std.Io.Writer, parts: []const Part) std.Io.Writer.Error!void`。
- **作用**：将 Part 序列写入给定 Writer。
- **实现**：逐项分派 text 原样 writeAll，dec 用 20 字节局部缓冲格式化，hex 用 16 字节缓冲格式化，再 writeAll。
- **所有权 / 错误 / 调用**：传播 Writer.Error；不加锁、不 flush、不附加分隔符或换行。发生错误前的输出不会回滚，数字缓冲只在同步写入期间借用。

### `formatDec` (`src/core/gc_audit_print.zig:56`)

- **签名**：`fn formatDec(value: u64, buf: *[20]u8) []const u8`。
- **作用**：将 u64 写成最短无符号十进制串。
- **实现**：从 buf 尾部倒写 value%10 的数字，再除以 10，至少运行一次，最后返回有效后缀。
- **所有权 / 错误 / 调用**：20 字节可容纳完整 u64；零返回 "0"。借用调用方缓冲，无前导零、无分配。

### `formatHex` (`src/core/gc_audit_print.zig:68`)

- **签名**：`fn formatHex(value: u64, buf: *[16]u8) []const u8`。
- **作用**：将 u64 写成最短小写十六进制串。
- **实现**：从尾部用低四位索引 0123456789abcdef，右移四位，至少写一位，返回有效后缀。
- **所有权 / 错误 / 调用**：16 字节容纳完整 u64；零为 "0"，无 0x 或补零。借用缓冲，不分配。

## `src/core/gc_registry_diagnostics.zig`

Registry 的统计与交叉验证接口，通过别名暴露回 Registry。验证函数读取真实容器、header 与辅助表，失败返回 InvariantError，部分失败会输出 stderr；不会修复被检状态。统计函数则修改对应计数、暂停环和增量状态；recordIncrementalCycleSuccess 还结束 MemoryAccount 的周期峰值跟踪，不能概括成“整个模块只写 stats”。

HeapSpaceSnapshot 的 heap_live_bytes、old_live_bytes、large_object_bytes、old_count、large_count 默认零，按仍计账的载体大小普查。old/large 是 policy.large_object_threshold 的逻辑分类，不是 young/old 代际，也不等同于 block heap 的 64 KiB large 空间边界。

SliceKind 为 u2 枚举 begin、increment、destroy、finish，其 ordinal 索引增量阶段统计数组。暂停环保存单次 STW 样本：同步 major 一次一个，增量 major 每切片一个；minor 有独立分布。周期总 STW 与单次暂停必须分开解释。

本模块没有单一“验证通过即整个 GC 正确”的入口。链表拓扑、metadata 表示、代际计数、construction 根、属性存储、独立 raw 账本分别覆盖不同条件；部分较强对账仅在 test/ownership-audit 编译配置存在。调用方应在结构稳定、owner 线程没有并发修改时检查，不能把诊断函数当成任意内存指针的安全探测器。

### `pauseDistribution` (`src/core/gc_registry_diagnostics.zig:62`)

- **签名**：`pub fn pauseDistribution(self: *const Registry) ?PauseDistribution`。
- **作用**：计算当前保留的 major 暂停样本分位数。
- **实现**：取 min(pause_sample_count,pause_sample_capacity)，无样本返回 null；复制有效环缓冲到栈上，heap sort 升序后按 nearest-rank 取 p50/p95/p99 与窗口最大值。
- **所有权 / 错误 / 调用**：不改变原环。返回 samples 是累计 pause_sample_count，不是窗口长度；增量切片也会加入样本，不必等整个周期完成才能有结果。

### `percentileIndex` (`src/core/gc_registry_diagnostics.zig:82`)

- **签名**：`fn percentileIndex(len: usize, percentile: usize) usize`。
- **作用**：将百分位换成 nearest-rank 的零基下标。
- **实现**：rank=ceil(len*percentile/100)，减一且将零排名截为零，最后最多 len-1。
- **所有权 / 错误 / 调用**：内部调用保证 len>0 且百分位为 50/95/99；没有通用输入验证，len==0 会使 len-1 下溢，乘法也非饱和。

### `deriveHeapSpaceSnapshot` (`src/core/gc_registry_diagnostics.zig:99`)

- **签名**：`fn deriveHeapSpaceSnapshot(self: *const Registry, rt: anytype) HeapSpaceSnapshot`。
- **作用**：从当前仍计账的载体推导逻辑大小分类快照。
- **实现**：遍历 heapAccountingIterator，heapByteSizeFromHeader 取真实分配大小，饱和累加总量；isLargeAllocation 按 policy.large_object_threshold 分成 large 与其余 old 两栏，并饱和计数。
- **所有权 / 错误 / 调用**：old 是非 large 栏名，不表示代际 young=false；人口包含仍计账的 condemned/析构中载体，不能等同于可达对象集。只读，不分配。

### `statsSnapshot` (`src/core/gc_registry_diagnostics.zig:116`)

- **签名**：`pub fn statsSnapshot(self: *const Registry, rt: anytype) Stats`。
- **作用**：组合即时堆普查与累计统计，返回公共 Stats 值快照。
- **实现**：复制 Registry 的标量状态，但堆遍历使用原 self，避免复制体中哨兵地址失配。total_allocated_bytes/heap_live_bytes 和 old/large 字段来自当前普查；peak_allocated_bytes 来自整个 MemoryAccount 的历史高水位。其它项读取 external/token、周期/失败、pin 条目、请求/阶段信息。
- **所有权 / 错误 / 调用**：total_allocated_bytes 不是历史累计分配量，old_allocated_bytes/old_alloc_count 等也是当前分类。pinned_cell_count 为 entries 数，不是所有 pin count 之和。pending 原因/紧急程度仅 pending 时返回；不保证跨线程原子快照。

### `ownerCondemned` (`src/core/gc_registry_diagnostics.zig:171`)

- **签名**：`fn ownerCondemned(header: *const GCObjectHeader) bool`。
- **作用**：查询一个载体是否已被本轮判死。
- **实现**：block cell 从 payload 前 prefix 定位可信 block，求 cellIndexInterior，未找到返回 false，找到查 doomed bit；其它载体调用 headerCondemned。
- **所有权 / 错误 / 调用**：只读判定，不登记新对象。输入须为有效载体；使用 trusted block 定位，不是任意地址安全检查。

### `verifyObjectPropertyStorageLayouts` (`src/core/gc_registry_diagnostics.zig:180`)

- **签名**：`pub fn verifyObjectPropertyStorageLayouts(self: *const Registry, rt: anytype) InvariantError!void`。
- **作用**：核验仍需保持语义布局的 Object 及其属性/元素存储。
- **实现**：遍历 all，跳过非 object 与 ownerCondemned。检查 prop_values 对齐；slots2 仅允许普通 object class 且 class inline_payload_size=0，inline 属性容量须在允许范围；非 slots2 不得 inline。禁止 slots2 payload 与 inline 属性重叠，非零 prop_count 须有存储，prop_count 不得大于 prop_size。外部属性/数组 cell 须 containsHeader 且 kind 分别为 property_storage/array_storage。block Object 还检查 prefix+allocationSize 不超过 cell_size，且两者映射到同一 class。
- **所有权 / 错误 / 调用**：失败返回对应布局错误，不修改 young 或修复对象。数组存储缺失时先打印 owner 诊断而不读取疑似已释放 cell。判死 owner 的 backing 可能已先回收，因此主动跳过。

### `recordFailure` (`src/core/gc_registry_diagnostics.zig:294`)

- **签名**：`pub fn recordFailure(self: *Registry, err: CollectionError) void`。
- **作用**：记录一次收集失败及错误类型。
- **实现**：failed_collections 用普通加法加一；OutOfMemory 映射 out_of_memory，PayloadMarkFailed 映射 payload_mark_failed。
- **所有权 / 错误 / 调用**：不负责中止标记、请求重试或清前沿；错误协议由调用方完成。

### `recordSuccess` (`src/core/gc_registry_diagnostics.zig:302`)

- **签名**：`pub fn recordSuccess(self: *Registry, result: CollectionResult) void`。
- **作用**：记录一次同步 major 完成结果与暂停样本。
- **实现**：清 last_failure，写 last_collection_time_ns；饱和累加 cycle_gc_count、cycle_gc_time_ns、freed_objects，再 recordPauseSample(duration_ns)。
- **所有权 / 错误 / 调用**：不增加 stats.collections，不重置阈值，也不负责结束 scheduler 周期；这些由上层处理。

### `recordMajorSlicePause` (`src/core/gc_registry_diagnostics.zig:318`)

- **签名**：`pub fn recordMajorSlicePause(self: *Registry, ns: u64, kind: SliceKind) void`。
- **作用**：将一次 major 切片暂停计入样本与阶段统计。
- **实现**：recordPauseSample(ns)；cycle_stw_ns 普通加 ns；更新该 SliceKind 的 segment_max_ns，并饱和累加 total_stw_by_kind 与 total_segments_by_kind。
- **所有权 / 错误 / 调用**：不会完成整个周期或增加 major 完成次数。同一次 poll 内阶段拆分可能由调用方进一步校正，本函数按传入 ns 记账。

### `recordIncrementalCycleSuccess` (`src/core/gc_registry_diagnostics.zig:331`)

- **签名**：`pub fn recordIncrementalCycleSuccess(self: *Registry, result: CollectionResult) void`。
- **作用**：结算一个增量 major 的总 STW 与回收数。
- **实现**：先 finishCycleEnvelope 结束峰值跟踪；清失败、饱和递增周期数与 freed_objects。以 cycle_stw_ns 更新 last_collection_time_ns、累计周期时间、last/max_cycle_stw_ns，最后将累计器置零。
- **所有权 / 错误 / 调用**：不把周期总时长再次加入暂停环，切片已经各自采样；不使用 result.duration_ns 作为周期总时长，它仅是完成 poll 的对外暂停。会修改包络状态及 MemoryAccount 峰值跟踪，不只写 stats。

### `recordMinorSuccess` (`src/core/gc_registry_diagnostics.zig:358`)

- **签名**：`pub fn recordMinorSuccess(self: *Registry, result: CollectionResult) void`。
- **作用**：记录 minor 的回收贡献。
- **实现**：清 last_failure，并饱和累加 result.freed_objects。
- **所有权 / 错误 / 调用**：忽略 duration_ns，不改 major 时间、major 次数或暂停环；minor 暂停分布由 generation 模块及调用方记录。

### `recordPauseSample` (`src/core/gc_registry_diagnostics.zig:363`)

- **签名**：`fn recordPauseSample(self: *Registry, duration_ns: u64) void`。
- **作用**：向固定容量暂停环写入一个样本。
- **实现**：写 pause_samples[cursor]，cursor 加一模容量，累计 pause_sample_count 饱和加一。
- **所有权 / 错误 / 调用**：环满后覆盖最老槽；累计数继续增长，不能用 count 直接当当前数组有效长度。

### `verifyIntrusiveList` (`src/core/gc_registry_diagnostics.zig:369`)

- **签名**：`pub fn verifyIntrusiveList(self: *Registry) InvariantError!void`。
- **作用**：验证主链、年轻后缀和非 block Object 成员表。
- **实现**：先验证辅助 doomed 容器，再验证主循环链及 Shape/Realm 前驱。逐节点要求 young 恰为 young_head 起始后缀、前驱游标准确、成员非 Object 且为 GC candidate、reserved 为零、epoch 不超过当前、非 Object Shape summary 低七位为零。最后检查 young 锚存在性，以及非 block live 项为已计账未 condemned 的非 block Object 且无重复。
- **所有权 / 错误 / 调用**：只读，不推进 epoch 或清 young；sticky survivor 的非零标记是合法状态。失败返回具体 InvariantError，不能用来安全解引用任意损坏地址。

### `verifyAuxiliaryIntrusiveLists` (`src/core/gc_registry_diagnostics.zig:437`)

- **签名**：`fn verifyAuxiliaryIntrusiveLists(self: *Registry) InvariantError!void`。
- **作用**：检查 morgue 桶、游标、非 block doomed 项与 pending 标志之间的关系。
- **实现**：逐 kind 验证循环链及 kind，不检查私有表前驱；Object 桶必须为空。非空 cursor 必须出现在某桶。非 block doomed 项要求 object、非 block、已计账且 condemned，并与 live 及前面 doomed 项去重。存在任一 doomed 人口/游标时要求 pending 或 hot.phase==tracer_destroy。
- **所有权 / 错误 / 调用**：不是双向 pending 等价检查：pending=true 而人口暂空不在这里报错；也不核验 cursor 位于 kind_pass 指定桶。无修复写入。

### `verifyConstructionRoots` (`src/core/gc_registry_diagnostics.zig:489`)

- **签名**：`pub fn verifyConstructionRoots(self: *const Registry) InvariantError!void`。
- **作用**：验证 pin 账本中的特殊 construction root。
- **实现**：只遍历 count==construction_pin_count 的条目，要求 pins.isConstructionRoot 成立，再 verifyMetadataSemantics(...,.object,.construction_block_object)。
- **所有权 / 错误 / 调用**：错误为 ConstructionRootStateMismatch 或 metadata 校验错误；普通宿主 pin 不在此检查，由其它审计处理。

### `verifyPublishedHeaderRepresentation` (`src/core/gc_registry_diagnostics.zig:499`)

- **签名**：`fn verifyPublishedHeaderRepresentation( self: *const Registry, header: *const GCObjectHeader, expected_kind: ?GcKind, ) InvariantError!void`。
- **作用**：核验一个已发布 header 的 metadata、记忆缓存及物理载体对应。
- **实现**：按 expected_kind 或实际 kind 验证 registry_published metadata；失败打印原始 prefix 后返回原错误。Object 还要求 Shape summary 匹配；remembered 高位为一必须在 map 中。再比较物理 block 查询与 block discriminator，若为 block 则要求 kind 允许、cell 地址精确、size_class 等于 cell 下标且 alloc bit 已置。
- **所有权 / 错误 / 调用**：不修改 header；这里只验证 bit→map，反向由全局函数完成。expected_kind 同时用于 metadata 期望和诊断 population 标签，不自行证明它属于某个 doomed 桶。

### `verifyRepresentationInvariants` (`src/core/gc_registry_diagnostics.zig:567`)

- **签名**：`pub fn verifyRepresentationInvariants(self: *const Registry) InvariantError!void`。
- **作用**：在稳定边界遍历发布人口并对账 remembered 缓存。
- **实现**：对 objectIterator(all)、每个 morgue kind 桶及非 block doomed 数组分别调用 header 表示验证；随后遍历 remembered map，要求 address_registry.containsHeader 且 remembered 高位为一。
- **所有权 / 错误 / 调用**：验证两种缓存表示在稳定点相符，不修复中间态；应避开清缓存位但尚未清 map 的退役过程。它不替代循环链拓扑验证。

### `verifyGenerationInvariants` (`src/core/gc_registry_diagnostics.zig:604`)

- **签名**：`pub fn verifyGenerationInvariants(self: *Registry) InvariantError!void`。
- **作用**：对账 young 总数、调度触发数与 remembered owner。
- **实现**：先数 objectIterator(young)，再从真实 extent 表补数 young extent，trigger 排除 owned storage cell；与 young_count/young_trigger_count 比较。每个 remembered 地址须仍在 address_registry 且 owner 非 young。
- **所有权 / 错误 / 调用**：计数不符均返回 YoungCountMismatch；失效/young owner 分别返回 RememberedOwnerNotLive/RememberedOwnerYoung。不用可能含重复或旧地址的 young_extents 列表做真值。

### `verifyMajorRetirementCommit` (`src/core/gc_registry_diagnostics.zig:638`)

- **签名**：`pub fn verifyMajorRetirementCommit(self: *Registry) InvariantError!void`。
- **作用**：检查 major 退役事务已关闭且没有仍为 young 的已标记或 pinned survivor。
- **实现**：要求 major_retirement=clean、年轻后缀两游标为空、young_count=0、remembered 空、young_blocks 空、young_extents 长度零。再遍历 all，young 且 marked/pinned 则返回 RetirementYoungSurvivor。
- **所有权 / 错误 / 调用**：其它前置不符返回 RetirementStateMismatch。没有直接检查 young_trigger_count，也不是对所有 extent/header 的独立完整普查；需与代际验证配合。

### `verifyHeapAccounting` (`src/core/gc_registry_diagnostics.zig:661`)

- **签名**：`pub fn verifyHeapAccounting(self: *const Registry, rt: anytype) InvariantError!void`。
- **作用**：交叉验证计账人口、载体索引、pin、外部 token 与可选独立审计账本。
- **实现**：始终核对 extent 页索引、medium 空闲桶，并遍历 heapAccountingIterator：必须已计账且大小非零，pin 索引须有条目，按大小饱和分栏。检查 pin 非零/不重复、construction 合法或普通 pin 在活人口中；token id/bytes 非零且 id 不重复，总 token 字节加 untracked 必须等于 external_bytes。审计开关启用时再校验 extent identity/lifecycle、block generation/lifecycle/accounting cells，逐项比对 raw oracle 的发布、字节、generation、resolveExact，以及三栏总字节；最后反向从 raw/extent/lifecycle/block authority 对账。
- **所有权 / 错误 / 调用**：审计编译开关关闭时不执行独立 oracle 的总字节等价检查，不能把通过结果宣传为全部分配无遗漏的证明。下层 carrier/索引错误多映射为 CarrierOldNewMismatch，accounting cells 错误映射 MissingHeapAllocation；不修改堆或释放资源。

### `BlockAudit.visit` (`src/core/gc_registry_diagnostics.zig:799`)

- **签名**：`fn visit(raw_context: *anyopaque, handle: AllocationHandle, _: CarrierLifecycleState) void`。
- **作用**：把一个 block-owned identity 与独立 raw oracle 对账。
- **实现**：转换 raw_context 为 BlockAudit；按 handle.base 查 raw，缺失写 mismatch=CarrierRawOwnedMismatch，否则 generation 不同写 CarrierGenerationMismatch。
- **所有权 / 错误 / 调用**：供 block_heap.forEachOwnedIdentity 回调，不是 traceChildEdges/RootVisitor。忽略传入 lifecycle state，不抛错、不提前终止遍历；后续不符项可以覆盖 mismatch，成功项不清除旧错误。

### `liveCount` (`src/core/gc_registry_diagnostics.zig:821`)

- **签名**：`pub fn liveCount(self: *const Registry) usize`。
- **作用**：统计 objectIterator(all) 当前能枚举的载体数量。
- **实现**：遍历迭代器，每项普通加一。
- **所有权 / 错误 / 调用**：不是只计 JS Object，也不是可达性普查；block alloc 人口可包含尚未物理释放的 doomed cell，而已摘入 morgue 的非 block 节点不由 all 补入。无热路径常驻计数。

### `liveCountKind` (`src/core/gc_registry_diagnostics.zig:828`)

- **签名**：`pub fn liveCountKind(self: *const Registry, kind: GcKind) usize`。
- **作用**：按 kind 筛选当前 all 迭代人口并计数。
- **实现**：遍历 objectIterator(all)，header.kind 等于输入时普通加一。
- **所有权 / 错误 / 调用**：口径与 liveCount 相同，只多 kind 过滤；不含其余独立 doomed 容器，不应解释为完整 heap-accounting 人口计数。

## `src/core/gc_registry_heap.zig`

Registry 的两个独立侧账本，不保存 allocator；可失败扩容与销毁由调用方传入账户/allocator。

Tokens.entries 保存 ExternalTokenEntry{id,bytes}，entries_capacity 区分有效长度与分配长度，next_id 初始 1。它记录宿主外部内存的压力登记，不接管该内存。Release 是 tagged union：released 携带核销字节数，malformed/unknown_id/byte_mismatch 区分三种无修改的失败。Registry 在此结果基础上维护 external_bytes、峰值、分配债务及无效释放计数。

id 推进会回绕并跳过零，没有存活 id 碰撞检测；正常生命周期不能跨整个 u64 id 空间仍假定绝对唯一。零字节由上层避免入表；(0,0) 专门表示无需登记的 token。

NonBlockObjectAuthority.items 保存 block heap 之外的已发布 Object，doomed 保存已判死但尚待析构的 Object。两者都只是 header 指针数组，Object body 的语义字段不被借作 morgue 链接。prepare 同时预留后续发布与 condemnation 容量；删除不保序，不能对数组位置或发布顺序赋予 JS 可观察语义。

### `Tokens.deinit` (`src/core/gc_registry_heap.zig:34`)

- **签名**：`pub fn deinit(self: *Tokens, account: *memory.MemoryAccount) void`。
- **作用**：释放 token 条目数组并清空逻辑账本。
- **实现**：按 entries_capacity 释放完整 backing，或兼容按 entries 长度释放；随后清 entries 和容量。next_id 保留。
- **所有权 / 错误 / 调用**：不释放宿主外部内存，也不更新 Registry 压力计数；合法状态下可重复调用，使用原 MemoryAccount。

### `Tokens.count` (`src/core/gc_registry_heap.zig:44`)

- **签名**：`pub fn count(self: Tokens) usize`。
- **作用**：读取当前登记 token 数量。
- **实现**：返回 entries.len。
- **所有权 / 错误 / 调用**：只读；不计算字节，也不包含未登记的 external_untracked_bytes 内存。

### `Tokens.totalBytes` (`src/core/gc_registry_heap.zig:48`)

- **签名**：`pub fn totalBytes(self: Tokens) usize`。
- **作用**：汇总当前 token 登记的字节数。
- **实现**：线性遍历 entries，std.math.add 溢出时将累计值设为 maxInt(usize)。
- **所有权 / 错误 / 调用**：饱和总和，无分配；不等于包含 untracked 分类的 Registry.external_bytes。

### `Tokens.add` (`src/core/gc_registry_heap.zig:57`)

- **签名**：`pub fn add(self: *Tokens, account: *memory.MemoryAccount, bytes: usize) !u64`。
- **作用**：追加外部字节登记并返回用于核销的 id。
- **实现**：先 ensureCapacity，再 takeId，写入 {id,bytes} 并扩大有效切片。
- **所有权 / 错误 / 调用**：分配失败上抛且不消耗 id。此底层方法不拒绝 bytes==0；上层须过滤零字节，否则生成的非零 id 无法用 release(id,0) 核销。不获取或拥有外部内存。

### `Tokens.release` (`src/core/gc_registry_heap.zig:76`)

- **签名**：`pub fn release(self: *Tokens, id: u64, bytes: usize) Release`。
- **作用**：按 id 与字节数核销一个登记。
- **实现**：(0,0) 返回 released=0；仅一项为零返回 malformed；找不到 id 返回 unknown_id；字节不符返回 byte_mismatch。匹配则稳定左移后续条目、缩短长度并返回 released=原字节数。
- **所有权 / 错误 / 调用**：错误不修改账本；不缩容量、不调用宿主 free。Registry 根据判定更新计数，真正外部资源释放仍属持有者责任。

### `Tokens.indexOf` (`src/core/gc_registry_heap.zig:96`)

- **签名**：`fn indexOf(self: Tokens, id: u64) ?usize`。
- **作用**：按 id 线性查询登记位置。
- **实现**：从 entries 开始返回首个 id 相等项下标，否则 null。
- **所有权 / 错误 / 调用**：不分配；id 若因极端回绕重复，只返回首项，本函数不检查唯一性。

### `Tokens.takeId` (`src/core/gc_registry_heap.zig:103`)

- **签名**：`fn takeId(self: *Tokens) u64`。
- **作用**：取出并推进非零 id 序列。
- **实现**：保存 next_id，执行 +%=1 回绕递增；若下一值为零则改为 1，返回保存值。
- **所有权 / 错误 / 调用**：初始 next_id=1；不扫描存活条目、不检测碰撞。跨完整 u64 周期会复用旧 id，不能将“永不复用存活 id”作为此实现提供的绝对保证。

### `Tokens.ensureCapacity` (`src/core/gc_registry_heap.zig:110`)

- **签名**：`fn ensureCapacity(self: *Tokens, account: *memory.MemoryAccount, required: usize) !void`。
- **作用**：扩充 token 条目存储。
- **实现**：容量不足时从 8 或现有容量两倍开始倍增到 required；新分配、复制有效项、释放旧 backing 后更新切片/容量。
- **所有权 / 错误 / 调用**：分配失败保留旧条目；成功使旧切片借用失效。容量倍增使用普通乘法；不改变 next_id 或外部压力计数。

### `NonBlockObjectAuthority.prepare` (`src/core/gc_registry_heap.zig:144`)

- **签名**：`pub fn prepare(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) !void`。
- **作用**：为一次非 block Object 发布及其未来 condemnation 预留空间。
- **实现**：items.ensureUnusedCapacity(1)，然后 doomed.ensureTotalCapacity(items.len+doomed.len+1)。
- **所有权 / 错误 / 调用**：第二步失败时 items 容量可能已变，但成员不变；预留完成后 publish/condemn 才可无分配提交。此数组不是 mark frontier，不能套用前沿段的说明。

### `NonBlockObjectAuthority.publish` (`src/core/gc_registry_heap.zig:150`)

- **签名**：`pub fn publish(self: *NonBlockObjectAuthority, header: *GCObjectHeader) void`。
- **作用**：将非 block Object header 加入已发布成员数组。
- **实现**：断言 kind==object 且非 block cell，再 items.appendAssumeCapacity。
- **所有权 / 错误 / 调用**：须先 prepare 并避免重复登记；这里不校验重复或设置 header 的 heap_accounted，发布协议的其它状态由上层维护。

### `NonBlockObjectAuthority.indexOf` (`src/core/gc_registry_heap.zig:156`)

- **签名**：`fn indexOf(self: *const NonBlockObjectAuthority, header: *const GCObjectHeader) ?usize`。
- **作用**：在存活成员数组中查 header 地址。
- **实现**：线性遍历 items，首个相等返回下标，否则 null。
- **所有权 / 错误 / 调用**：不查 doomed，不解引用 header；删除采用 swapRemove，旧下标不稳定。

### `NonBlockObjectAuthority.remove` (`src/core/gc_registry_heap.zig:163`)

- **签名**：`pub fn remove(self: *NonBlockObjectAuthority, header: *const GCObjectHeader) bool`。
- **作用**：从存活成员数组无序移除 header。
- **实现**：indexOf 未命中返回 false；命中 swapRemove 后返回 true。
- **所有权 / 错误 / 调用**：只改变成员关系，不移入 doomed、不释放对象；尾项可能被移到被删位置。

### `NonBlockObjectAuthority.condemn` (`src/core/gc_registry_heap.zig:169`)

- **签名**：`pub fn condemn(self: *NonBlockObjectAuthority, header: *GCObjectHeader) void`。
- **作用**：将一个存活成员移入待析构侧表。
- **实现**：要求 indexOf 命中，否则 unreachable；从 items.swapRemove，再 doomed.appendAssumeCapacity。
- **所有权 / 错误 / 调用**：依赖 prepare 预留的 doomed 容量；不执行析构或写 header condemnation 标记，上层负责完整回收事务。

### `NonBlockObjectAuthority.deinit` (`src/core/gc_registry_heap.zig:177`)

- **签名**：`pub fn deinit(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) void`。
- **作用**：释放两条成员数组并恢复默认空结构。
- **实现**：断言 doomed 已空，分别 deinit items/doomed，最后 self.*=.{}。
- **所有权 / 错误 / 调用**：只释放指针数组，不逐个析构其 header；调用方须已处理对象与 doomed 事务。重置后重复调用安全，需匹配原 allocator。

## `src/core/gc_registry_lists.zig`

Registry 的非 Object 载体侵入式单向循环链表与游标。主 objects 表按发布顺序追加；名称中的 objects 不表示 JS Object：Object 由 block bitmap 或非 block Object 侧表枚举，不加入此链。

IntrusiveHeaderList 由内嵌 Header sentinel 和可空 tail 组成；默认 `.{}` 尚未绑定，listInit 后空表的 successor/tail 均指向自己的 sentinel，所以初始化后结构不可直接搬址。每个节点只有 next_non_object；Shape 和 Realm 可被 mutator 任意摘除，额外在 body 保存前驱，其它节点通常由持有前驱的收集遍历摘除。

Lists.objects 是主表；young_head 与 young_predecessor 定位年轻后缀及其前驱，避免 minor 为每个节点重新找前驱；sweep_current 保存当前已摘链但正在析构的 header，供 ownsObject/containsHeader 在同步析构窗口识别。没有常驻 live 节点数，诊断需要遍历计数。

TraversalOwned 变体用于收集器私有链（例如 morgue），省去 Shape/Realm 前驱维护；必须配对使用，不能与主表任意摘链机制混用。所有操作均只维护链接或游标，不承担节点内存的销毁责任。

### `storedListPrevious` (`src/core/gc_registry_lists.zig:28`)

- **签名**：`inline fn storedListPrevious(h: *const Header) ?*Header`。
- **作用**：读取 Shape 或 Realm body 中保存的前驱加速指针。
- **实现**：按 kind 分派：Shape 从 trace_list_previous.previous() 读取；realm_context 从 traceListPreviousPtrConst 读取；其余返回 null。
- **所有权 / 错误 / 调用**：借用 header 及其所属对象，需真实匹配 kind/body 布局；普通 compact Header 本身没有前驱字段。

### `setStoredListPrevious` (`src/core/gc_registry_lists.zig:42`)

- **签名**：`inline fn setStoredListPrevious(h: *Header, previous: ?*Header) void`。
- **作用**：更新支持任意位置摘链的两类载体前驱。
- **实现**：Shape 调 setPrevious；Realm 写 traceListPreviousPtr；其它 kind 无操作。
- **所有权 / 错误 / 调用**：不修改 successor 链，不分配，不接管前驱内存。

### `listInit` (`src/core/gc_registry_lists.zig:67`)

- **签名**：`pub inline fn listInit(head: *IntrusiveHeaderList) void`。
- **作用**：建立空循环哨兵链表。
- **实现**：令 sentinel.next_non_object 与 tail 都指向 sentinel。
- **所有权 / 错误 / 调用**：结构地址必须已稳定；仅初始化链表两项链接，不释放旧节点。在非空表上调用会断开原有节点，不能用作清理。

### `listEmpty` (`src/core/gc_registry_lists.zig:72`)

- **签名**：`pub inline fn listEmpty(head: *const IntrusiveHeaderList) bool`。
- **作用**：判断已初始化的链表是否为空。
- **实现**：比较 sentinel.next_non_object 与 sentinel 地址是否相同。
- **所有权 / 错误 / 调用**：不检查 tail 或链表完整性；未初始化的默认结构不是合法空表。

### `listAddTail` (`src/core/gc_registry_lists.zig:76`)

- **签名**：`pub inline fn listAddTail(head: *IntrusiveHeaderList, el: *Header) void`。
- **作用**：向公开的非 Object 载体链表尾部追加一个已脱链节点。
- **实现**：断言 kind 非 object 且 next_non_object 为 null；新节点指向 sentinel，旧尾指向新节点，更新 tail，并设置新节点的 Shape/Realm 前驱。
- **所有权 / 错误 / 调用**：表须已初始化；只建立链表成员关系，不分配、不设置 young 或发布账户标记。

### `listAddTailTraversalOwned` (`src/core/gc_registry_lists.zig:90`)

- **签名**：`pub inline fn listAddTailTraversalOwned(head: *IntrusiveHeaderList, el: *Header) void`。
- **作用**：向只由收集器前向遍历摘链的私有表追加节点。
- **实现**：执行与 listAddTail 相同的 successor/tail 拼接，但不维护 Shape/Realm body 前驱。
- **所有权 / 错误 / 调用**：只能用于调用方始终携带前驱的私有表，不能替代主 objects 表的追加操作。节点须非 Object、已脱链。

### `listPrevious` (`src/core/gc_registry_lists.zig:102`)

- **签名**：`pub inline fn listPrevious(head: *IntrusiveHeaderList, el: *Header) *Header`。
- **作用**：取得指定节点的前驱。
- **实现**：Shape/Realm 直接读 body 前驱并断言其 successor 指向 el；其它种类从 sentinel 开始线性扫描，断言不会绕回 sentinel。
- **所有权 / 错误 / 调用**：要求 el 确实属于正确的表；不提供未命中返回值。Shape/Realm 的快速分支不核验该前驱属于参数 head，不能传错表。

### `listDelAfter` (`src/core/gc_registry_lists.zig:122`)

- **签名**：`pub inline fn listDelAfter(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void`。
- **作用**：按已知前驱从主链表中摘除节点，并修复加速前驱。
- **实现**：断言非 Object 且 previous.next==el；previous 接到 el.next；若后继不是 sentinel 则更新其 Shape/Realm 前驱；必要时更新 tail。安全构建清 el 的 body 前驱，所有构建清 el.next。
- **所有权 / 错误 / 调用**：O(1) 摘链，不销毁节点。ReleaseFast 可保留脱链节点的旧 body 前驱，链接权威是 next==null，重挂会覆盖前驱。

### `listDelAfterTraversalOwned` (`src/core/gc_registry_lists.zig:141`)

- **签名**：`pub inline fn listDelAfterTraversalOwned(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void`。
- **作用**：按已知前驱从收集器私有表摘除节点。
- **实现**：拼接 successor，必要时更新 tail，最后清 el.next_non_object；不修复或清除 Shape/Realm body 前驱。
- **所有权 / 错误 / 调用**：要求私有表不存在 mutator 任意摘链；不能用于主 objects 表，否则会留下错误的后继前驱。

### `listFirst` (`src/core/gc_registry_lists.zig:149`)

- **签名**：`pub inline fn listFirst(head: *const IntrusiveHeaderList) ?*Header`。
- **作用**：借用链表首节点，空表返回 null。
- **实现**：读取 sentinel.next_non_object，等于 sentinel 则 null，否则返回该指针。
- **所有权 / 错误 / 调用**：要求初始化后 next 非 null；不摘链，不保护节点免受后续删除。

### `headerLinked` (`src/core/gc_registry_lists.zig:155`)

- **签名**：`pub inline fn headerLinked(header: *const Header) bool`。
- **作用**：判断 header 是否保存非空的非 Object successor。
- **实现**：返回 header.nextNonObject()!=null。
- **所有权 / 错误 / 调用**：这是链接标记查询，不扫描某张表，也不证明节点属于 Registry；只适用于非 Object header，nextNonObject 在安全构建会断言 kind 非 object。

### `verifyCircularHeaderList` (`src/core/gc_registry_lists.zig:159`)

- **签名**：`pub fn verifyCircularHeaderList( head: *IntrusiveHeaderList, expected_kind: ?GcKind, comptime verify_stored_previous: bool, ) InvariantError!usize`。
- **作用**：验证循环链表拓扑、可选 kind 和可选前驱，并计数。
- **实现**：先检查 sentinel.next 与空表 tail；再用快慢指针拒绝不经过 sentinel 的环和空 successor。第二遍检查 expected_kind、可选 Shape/Realm 前驱，累计节点，最后验证尾部 successor 与 tail。
- **所有权 / 错误 / 调用**：拓扑错误返回 CorruptGcList，kind 不符返回 DoomedBucketKindMismatch。只读但会解引用节点；不能把无效地址或任意损坏内存当作可安全验证的输入。

### `Lists.init` (`src/core/gc_registry_lists.zig:234`)

- **签名**：`pub fn init(self: *Lists) void`。
- **作用**：在 Registry 地址稳定后初始化主 objects 链表哨兵。
- **实现**：仅调用 listInit(&objects)。
- **所有权 / 错误 / 调用**：必须早于发布；不重置 young_head、young_predecessor 或 sweep_current。空表重新绑定安全，不是整个 Lists 的任意状态 reset。

### `Lists.stageYoungTailPredecessor` (`src/core/gc_registry_lists.zig:241`)

- **签名**：`pub inline fn stageYoungTailPredecessor(self: *Lists) void`。
- **作用**：在首个 young 节点追加前保存旧尾作为年轻后缀前驱。
- **实现**：仅当 young_head==null 时将 objects.tail 保存到 young_predecessor。
- **所有权 / 错误 / 调用**：应在追加前调用；已有 young 后缀时保留其原前驱，不设置 young_head。

### `Lists.resetYoungSuffix` (`src/core/gc_registry_lists.zig:247`)

- **签名**：`pub inline fn resetYoungSuffix(self: *Lists) void`。
- **作用**：清空年轻后缀的两个游标。
- **实现**：young_head 与 young_predecessor 同时置 null。
- **所有权 / 错误 / 调用**：不摘除链表节点，也不清 header.young；代际状态和节点位的维护由上层完成。

### `Lists.linkTail` (`src/core/gc_registry_lists.zig:253`)

- **签名**：`pub inline fn linkTail(self: *Lists, header: *GCObjectHeader) void`。
- **作用**：在保留年轻后缀前驱信息的同时追加非 Object 载体。
- **实现**：断言 kind 非 object，先 stageYoungTailPredecessor，再 listAddTail。
- **所有权 / 错误 / 调用**：不自动将节点标 young 或设 young_head，发布路径随后完成该步骤；仅管理链表链接。

## `src/core/gc_registry_pins.zig`

Ledger 是 GC pin 的权威：entries 保存 PinEntry{header,count}，entries_capacity 保存真实数组容量；set 是按 header 地址建的成员缓存，覆盖普通宿主 pin 和 construction root。header 已没有单独 pin 位。entries/set 必须同步，但它们不拥有所指 header 的存储；解除最后一个 pin 只使对象重新具备可回收资格。

普通宿主 pin 用正计数；construction_pin_count=maxInt(usize) 是特殊判别值，用来保护已初始化、故意未发布且没有 Shape 的 detached generator shell。普通 pin 不能用 construction-root API 撤销，反之亦然。pin 实现的饱和递增没有额外预留 maxInt-1 上限，因此哨兵分离依赖宿主引用计数不达到该极端值的调用约束，文档不把它描述成运行期检查保证。

Ledger 不保存账户指针：数组由传入 MemoryAccount 分配，set 使用该账户 persistent_allocator；查找/删除无需 allocator，只有扩容和销毁使用账户。构造根先 prepare 预留，再 add 无失败提交，避免在未保护 shell 已取得之后才做可失败扩容。

### `Ledger.deinit` (`src/core/gc_registry_pins.zig:43`)

- **签名**：`pub fn deinit(self: *Ledger, account: *memory.MemoryAccount) void`。
- **作用**：释放 pin 条目数组与成员索引，并恢复空账本。
- **实现**：若 entries_capacity 非零则按完整容量 free 数组，否则兼容释放非空 entries；清 entries/容量，再用 persistent_allocator 销毁 set 并置 empty。
- **所有权 / 错误 / 调用**：不销毁被 pin 的 header。两个存储都重置，因此合法状态下重复调用安全；须使用原分配账户。

### `Ledger.contains` (`src/core/gc_registry_pins.zig:56`)

- **签名**：`pub inline fn contains(self: *const Ledger, header: *const GCObjectHeader) bool`。
- **作用**：通过成员索引查询 header 是否被 pin 或保留为 construction root。
- **实现**：set.count 为零直接 false，否则按 header 地址查 set。
- **所有权 / 错误 / 调用**：不解引用 header、不读已移除的 header pin 位；返回成员关系，不返回 pin 引用数。

### `Ledger.pin` (`src/core/gc_registry_pins.zig:61`)

- **签名**：`pub fn pin(self: *Ledger, account: *memory.MemoryAccount, header: *GCObjectHeader) !void`。
- **作用**：增加宿主对 header 的 pin 计数。
- **实现**：先线性查 entries；已有项断言不是 construction 哨兵并用 +|=1 饱和递增。新项先扩 entries，再 set.put，最后无失败地追加 count=1 条目。
- **所有权 / 错误 / 调用**：扩容或 set 插入错误上抛；set 失败时数组容量可能已增大，但逻辑条目不变。既有计数使用饱和加法，未另设 maxInt-1 上限，不能声称实现绝不触及 construction_pin_count 的数值。

### `Ledger.unpin` (`src/core/gc_registry_pins.zig:78`)

- **签名**：`pub fn unpin(self: *Ledger, header: *GCObjectHeader) void`。
- **作用**：减少一个宿主 pin，最后一个 pin 消失时移除成员关系。
- **实现**：找不到则返回；断言不是 construction 哨兵。count>1 时减一，否则 removeAt 并从 set 删除地址。
- **所有权 / 错误 / 调用**：只解除保护，不立即销毁 header。每个有效 pin 对应一次 unpin；重复 unpin 可能消耗其它持有者的计数。

### `Ledger.indexOf` (`src/core/gc_registry_pins.zig:89`)

- **签名**：`pub fn indexOf(self: *const Ledger, header: *const GCObjectHeader) ?usize`。
- **作用**：线性查找 header 的条目下标。
- **实现**：按 entries 顺序比较 entry.header 与输入指针，首个相等返回下标，否则 null。
- **所有权 / 错误 / 调用**：不分配、不解引用 header；数组扩容或删除后，旧下标不能继续当稳定身份。

### `Ledger.removeAt` (`src/core/gc_registry_pins.zig:96`)

- **签名**：`fn removeAt(self: *Ledger, index: usize) void`。
- **作用**：从条目数组稳定删除一个已知位置。
- **实现**：后面还有元素时 copyForwards 向前移一项，随后切片长度减一。
- **所有权 / 错误 / 调用**：保留剩余条目顺序和容量；不更新 set，不释放 header。内部调用方须验证下标并同步索引。

### `Ledger.ensureCapacity` (`src/core/gc_registry_pins.zig:107`)

- **签名**：`fn ensureCapacity(self: *Ledger, account: *memory.MemoryAccount, required: usize) !void`。
- **作用**：为 entries 预留至少 required 个位置。
- **实现**：容量足够直接返回；否则从 8 或旧容量两倍开始倍增，account.alloc 新数组，复制有效条目、释放旧容量，更新切片和容量。
- **所有权 / 错误 / 调用**：失败保留旧逻辑内容；成功会使旧 entries 借用失效。这里只扩数组，不扩 set；倍增采用普通整数乘法，不是无限尺寸的溢出安全增长器。

### `Ledger.prepareConstructionRoot` (`src/core/gc_registry_pins.zig:125`)

- **签名**：`pub fn prepareConstructionRoot(self: *Ledger, account: *memory.MemoryAccount) !void`。
- **作用**：在获取未发布 shell 前预留一次 construction root 插入所需容量。
- **实现**：先 ensureCapacity(entries.len+1)，再 set.ensureUnusedCapacity(1)。
- **所有权 / 错误 / 调用**：可能失败；第二步失败不回退已扩大的数组容量，但不添加根。成功后调用方须保证预留位置在 addConstructionRoot 前仍可用。

### `Ledger.addConstructionRoot` (`src/core/gc_registry_pins.zig:133`)

- **签名**：`pub fn addConstructionRoot(self: *Ledger, header: *GCObjectHeader) void`。
- **作用**：无分配地为尚未安装 Shape 的 detached generator shell 建立特殊根。
- **实现**：断言 kind 为 object、未 heap_accounted、entries 中无该 header、数组有空位；追加 count=construction_pin_count，再 set.putAssumeCapacity。
- **所有权 / 错误 / 调用**：须先 prepareConstructionRoot；本函数不检查所有 shell 布局条件，完整核验在 isConstructionRoot。只保护生命周期，不等于正常发布或普通宿主 pin。

### `Ledger.removeConstructionRoot` (`src/core/gc_registry_pins.zig:146`)

- **签名**：`pub fn removeConstructionRoot(self: *Ledger, header: *GCObjectHeader) void`。
- **作用**：撤销已知存在的 construction root。
- **实现**：indexOf 未命中为 unreachable；断言哨兵 count，再 removeAt 并从 set 删地址。
- **所有权 / 错误 / 调用**：不是可任意重复调用的释放接口；不释放 shell，调用方负责继续发布或销毁它。

### `Ledger.firstConstructionRoot` (`src/core/gc_registry_pins.zig:154`)

- **签名**：`pub fn firstConstructionRoot(self: *const Ledger) ?*GCObjectHeader`。
- **作用**：寻找首个哨兵计数条目，供 teardown 逐项处理。
- **实现**：顺序扫描 entries，遇 count==construction_pin_count 返回 header，否则 null。
- **所有权 / 错误 / 调用**：返回借用指针；这里只看计数，不执行 isConstructionRoot 的布局验证，也不移除条目。

### `Ledger.isConstructionRoot` (`src/core/gc_registry_pins.zig:161`)

- **签名**：`pub fn isConstructionRoot(self: *const Ledger, header: *const GCObjectHeader) bool`。
- **作用**：验证账本成员确实仍是合法的未发布 generator shell。
- **实现**：要求条目存在且为哨兵 count；metadata 必须未 heap_accounted、非 standalone、是 block cell、kind=object、非 young/finalizing、mark_epoch=0、Shape summary 低七位为零、lifetime.flags.reserved=0；最后要求 Object.isDetachedGeneratorShellForGc()。
- **所有权 / 错误 / 调用**：只读验证，不推进 epoch、不改 young。Shape summary 的 remembered 高位允许为一；shell payload 的写屏障可合法置该位。需 header 指向有效对象，不能用于校验任意地址。

### `Ledger.entryIsConstructionRoot` (`src/core/gc_registry_pins.zig:197`)

- **签名**：`pub fn entryIsConstructionRoot(self: *const Ledger, entry: PinEntry) bool`。
- **作用**：同时核验给定条目计数和账本中的 shell 身份。
- **实现**：先检查传入 entry.count 为哨兵，再 isConstructionRoot(entry.header)。
- **所有权 / 错误 / 调用**：不会只信传入快照；第二步重新查当前账本和 metadata。无分配、无所有权转移。

## `src/core/gc_registry_scheduler.zig`

Scheduler 保存 major 收集策略与一个请求槽。policy 初始为 gc.Policy 默认值；major_phase 初始 idle，major_reason 初始 null，major_request 初始无请求。请求槽最多保留一个合并后的请求，不是 FIFO；活动周期状态与待处理请求相互独立。

MajorPhase 包括 idle、mark_roots、sweep；SchedulerPoint 包括 allocation_slow_path、callback_boundary、idle、safepoint、urgent。Request 保存 pending、可空 reason 和 soon/urgent 紧急程度；压力计算返回不带 pending 字段的 PressureRequest。它们的定义在 gc.zig，本模块使用别名。此处不触碰堆或执行 collector，各方法也不自行验证 runtime 是否处于安全收集边界。

host_quiescent 初始 false，由 runtime teardown 协议设置，声明宿主已释放句柄且没有 mutator frame，可采用精确根扫描。它不由本文件的方法自动推导。major_phase 与 Registry.hot.phase 也是不同状态，不能把本模块的阶段赋值当作实际暂停或析构已完成。

### `Scheduler.processMemoryRequest` (`src/core/gc_registry_scheduler.zig:42`)

- **签名**：`pub fn processMemoryRequest(self: Scheduler, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest`。
- **作用**：根据已采样 RSS 与 cgroup 限额计算内存压力请求。
- **实现**：依次检查 rss_hard_limit、启用且非零 cgroup limit 的 hard 千分比、rss_soft_limit、cgroup soft 千分比；硬线命中返回 rss_pressure/urgent，软线返回 rss_pressure/soon，否则 null。
- **所有权 / 错误 / 调用**：只读计算，不采样 OS、不锁存请求、不收集。比值使用 gc.ratioPerMille，结果最多 1000；ratio 配为 0 表示关闭，optional RSS limit 设 0 则可立即命中。

### `Scheduler.request` (`src/core/gc_registry_scheduler.zig:59`)

- **签名**：`pub fn request(self: *Scheduler, reason: RequestReason, urgency: RequestUrgency) void`。
- **作用**：锁存或加强单个 major 请求。
- **实现**：空槽写 pending/reason/urgency；新 urgent 遇旧非 urgent 时同时替换 urgency/reason。否则旧 reason 为 allocation_threshold 而新 reason 不同时，仅替换 reason；最后补齐空 reason。其余保持原请求。
- **所有权 / 错误 / 调用**：没有请求队列。原因替换不要求同 urgency：旧 urgent threshold 可换成新 soon 请求的原因，但仍保留 urgent。无分配，不直接触发收集。

### `Scheduler.hasPendingMajorRequest` (`src/core/gc_registry_scheduler.zig:86`)

- **签名**：`pub fn hasPendingMajorRequest(self: Scheduler) bool`。
- **作用**：查询请求槽是否有效。
- **实现**：返回 major_request.pending。
- **所有权 / 错误 / 调用**：只读值查询，不依据 major_phase 判断周期是否运行。

### `Scheduler.pendingMajorRequest` (`src/core/gc_registry_scheduler.zig:90`)

- **签名**：`pub fn pendingMajorRequest(self: Scheduler) ?Request`。
- **作用**：返回当前有效请求的快照。
- **实现**：pending 为真返回整个 Request 值，否则 null。
- **所有权 / 错误 / 调用**：不消费、不清槽；返回副本，后续调度变更不会更新它。

### `Scheduler.clearMajorRequest` (`src/core/gc_registry_scheduler.zig:94`)

- **签名**：`pub fn clearMajorRequest(self: *Scheduler) ?Request`。
- **作用**：取走待处理请求并清空槽。
- **实现**：无 pending 返回 null；否则保存旧 Request，将 major_request 置默认值并返回旧值。
- **所有权 / 错误 / 调用**：恢复 pending=false、reason=null、urgency=soon；不改当前 major_phase/reason。

### `Scheduler.pendingAllocationThresholdRequest` (`src/core/gc_registry_scheduler.zig:110`)

- **签名**：`pub fn pendingAllocationThresholdRequest(self: Scheduler) bool`。
- **作用**：查询是否锁存了可以按阈值条件撤销的自调度请求。
- **实现**：要求 pending 存在、reason==allocation_threshold 且 urgency==soon。
- **所有权 / 错误 / 调用**：urgent threshold 不满足。仅检查请求形态，不重新读取当前账户或确认是否仍越界。

### `Scheduler.clearStaleAllocationThresholdRequest` (`src/core/gc_registry_scheduler.zig:115`)

- **签名**：`pub fn clearStaleAllocationThresholdRequest(self: *Scheduler) bool`。
- **作用**：撤销一个 soon allocation_threshold 请求。
- **实现**：无请求或原因/紧急程度不符返回 false；符合则清 major_request 并返回 true。
- **所有权 / 错误 / 调用**：名称中的 stale 由调用方确认；函数自己不检查内存大小，不能不经条件判断就用它取消阈值请求。其它原因和 urgent 请求保留。

### `Scheduler.shouldRunMajorAt` (`src/core/gc_registry_scheduler.zig:122`)

- **签名**：`pub fn shouldRunMajorAt(self: Scheduler, point: SchedulerPoint, over_threshold: bool) bool`。
- **作用**：根据边界类型、越界状态和锁存请求决定是否应运行 major。
- **实现**：point==urgent 或 over_threshold 时直接 true；否则无 pending 为 false；allocation_slow_path/idle 接受任意 pending，callback_boundary/safepoint 只接受 urgent pending。
- **所有权 / 错误 / 调用**：纯策略查询，不消耗请求，不检查 gc_running、morgue 或 major_phase；调用方必须先满足收集安全条件。

### `Scheduler.beginMajorCycle` (`src/core/gc_registry_scheduler.zig:132`)

- **签名**：`pub fn beginMajorCycle(self: *Scheduler, reason: RequestReason) void`。
- **作用**：记录新 major 的初始阶段和原因。
- **实现**：idle 时设 mark_roots 并写 reason；已有活动阶段时不重启，只在 major_reason 为空时补 reason。
- **所有权 / 错误 / 调用**：不清 pending 请求，也不执行根扫描；阶段和实际 collector 操作由上层保持一致。

### `Scheduler.setMajorPhase` (`src/core/gc_registry_scheduler.zig:141`)

- **签名**：`pub fn setMajorPhase(self: *Scheduler, phase: MajorPhase) void`。
- **作用**：更新已开启周期的阶段。
- **实现**：当前 idle 且目标非 idle 时直接忽略；其它情况赋值。
- **所有权 / 错误 / 调用**：不是完整合法转移图校验；可从活动阶段设 idle 而保留 major_reason。应由 beginMajorCycle 开始、finish/abort 收尾。

### `Scheduler.activeMajorReason` (`src/core/gc_registry_scheduler.zig:146`)

- **签名**：`pub fn activeMajorReason(self: Scheduler) ?RequestReason`。
- **作用**：读取当前保存的周期原因。
- **实现**：返回 major_reason。
- **所有权 / 错误 / 调用**：不检查 major_phase，也不读取 pending 请求原因；调用方须区分活动原因和请求槽。

### `Scheduler.abortMajorCycle` (`src/core/gc_registry_scheduler.zig:150`)

- **签名**：`pub fn abortMajorCycle(self: *Scheduler) void`。
- **作用**：清除调度器的活动周期状态。
- **实现**：设 major_phase=idle、major_reason=null。
- **所有权 / 错误 / 调用**：不清 pending 槽，不回滚堆、不重置标记前沿；完整中止由 Registry/runtime 协议完成。

### `Scheduler.finishMajorCycle` (`src/core/gc_registry_scheduler.zig:155`)

- **签名**：`pub fn finishMajorCycle(self: *Scheduler) void`。
- **作用**：将活动周期状态恢复为空闲。
- **实现**：与 abort 一样，仅写 major_phase=idle、major_reason=null。
- **所有权 / 错误 / 调用**：不清请求、不记录收集统计、不释放资源；完成与中止的其它差异由调用方实现。

## 覆盖核对

- 清单函数数: 226（`src/core/gc.zig` 141 + `src/core/gc_audit_print.zig` 6 + `src/core/gc_registry_diagnostics.zig` 23 + `src/core/gc_registry_heap.zig` 14 + `src/core/gc_registry_lists.zig` 16 + `src/core/gc_registry_pins.zig` 13 + `src/core/gc_registry_scheduler.zig` 13）
- 本文标题覆盖: 226
- 未覆盖: 无
