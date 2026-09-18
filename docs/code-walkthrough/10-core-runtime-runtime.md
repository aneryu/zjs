# 10 — JSRuntime、句柄、根、GC 调度

`src/core/runtime.zig`（约 4952 行、清单 304 个函数）是引擎的所有权中枢：atom/class/shape 表、MemoryAccount、job FIFO、realm 列表、延迟 native 清理、persistent/local/weak 句柄。QuickJS 对照 `JSRuntime`（quickjs.c:319-396）。

**单线程所有权**：创建、变异、收集、销毁都在 `owner_thread_id` 线程。跨线程在宿主边界以 `error.WrongRuntimeThread` 拒绝；`assertOwnerThread` 则 panic。显式同步的宿主缝（`host_completion_event`）除外。

core 不得 import exec/parser/binding；标准全局安装、builtin 表、active invocation 走函数指针缝。

句柄契约：出引擎边界必须用 `HandleScope`/`LocalHandle`/`JSValueHandle`/`WeakPersistentValue`，不能让裸 `JSValue` 活过一次调用。

---

## 文件级类型与常量

- `default_stack_size` / `default_native_stack_size` = 1 MiB（qjs `JS_DEFAULT_STACK_SIZE`）。Debug初始native预算为4 MiB，其他构建为1 MiB；这是物理额度配置，不保证各优化级别可容纳完全相同递归层数。
- `default_gc_threshold` = 256 KiB。
- InterruptHandler接受runtime与可选userdata并返回bool。DynamicImportLoader的callback/userdata默认null；Scope借用runtime并保存previous，active默认true。StandardGlobalsInstaller接受runtime/global并返回anyerror!void；默认安装器变量是未同步的进程全局，不能与profile的TLS回调混为一谈。
- `VmStackWindowPolicy`：packed u64，`limit:u62` + `arena_window` + `resident_window`。
- VmStackArena：LIFO值槽存储，首块按需求选择4 KiB或32768槽，其后32768槽，最多64块。JSValue为16字节时分别256槽/512 KiB。Mark保存chunk/used，ActiveCarve保存Mark与window；chunk_count/active/used默认0，chunks默认空片段。窗口地址在有效使用期间稳定，restore不释放backing也不清值。
- RuntimeOptions（别名Options）：trace_writer/memory_limit默认null，gc_threshold默认256 KiB，gc_policy使用gc.Policy默认值，stack_size默认1 MiB，interrupt_handler/context默认null，can_block默认false。声明本身不应用配置。MemoryUsage是无默认值的统计记录：可选memory_limit；allocated_bytes/allocation_count及各自peak；alloc/free/create/destroy_calls；atom/object/shape/module各count与bytes；registered_class_count/class_record_count/class_bytes。各值的统计口径由memoryUsage填充逻辑决定，不可仅由字段名推断可回收大小。
- `GCPollMode`：`normal` / `callback_boundary` / `idle` / `safepoint` / `urgent`。`acceptsMinor`：idle/safepoint/callback_boundary 可用 minor **作为答案**；normal/urgent 不行。`rootScan`：engine 触发 `.engine_active`（保守扫），host 静止 `.declared_only`。
- `GCRootScan`：`engine_active` | `declared_only`。生产 Collector 以 `!scheduler.host_quiescent` 决定是否加入保守扫描，不能说生产始终扫描；测试构建才直接采用 scan 或测试 override 的枚举值决定该分支。
- ValueRootSlice：mutable借用*const []JSValue切片头；borrowed直接借用[]const JSValue；windowed借用values切片头与独立live_len；cells借用VarRef指针切片头，borrowed_cells直接借用指针数组。描述符不拥有backing；windowed按live_len界定活窗口，调用方保证不超过有效存储。
- ValueRootBuffer / CellRootBuffer拥有堆上位拷贝数组，默认空；必须另外用激活的ValueRootFrame引用它们，分配成功本身不等于建立GC根。
- ValueRootValue保存*JSValue；ObjectRootValue保存*?*Object；HeaderRootValue直接保存*gc.Header。AtomRootSlot.single借用*const Atom，list借用*const []Atom切片头；atom ID是整数，不能依赖指针保守扫描恢复它的身份。
- `value_root_frames_enabled = true`；生产 `value_root_link_containers_only`（测试与 `-Dzjs_gc_roots_diag` 链接标量）。
- ValueRootFrame：previous默认null，各描述符数组默认空；激活按配置选择是否挂rt.active_value_roots。生产默认仅slices或atoms描述符存在时链接；headers/values/objects本身不能绕过此条件。测试统计类型不在本次非测试语义审核范围。
- RootTraceError为Allocator.Error与PayloadMarkFailed的并集。RootVisitor借用opaque context，visit_value/visit_object必需，visit_header/visit_atom当前为可选回调且默认null。RootProvider保存context与trace函数，仅是描述；RootSlot.value默认undefined。WeakRootSlot的identity、callback、callback_context默认null，死亡回调接受runtime与可选context。
- ActiveJobRoot当前启用，保存previous/runtime/job三个指针，链头为TLS；追踪按runtime筛选。ActiveInvocationTrace仅定义exec记录的回调前缀，签名可返回RootTraceError，并非类型保证no-fail。trace_atomics_wait_async为进程级可选回调变量，默认null；回调类型自身不保证加锁，具体同步由实现提供。
- JSValueHandle与WeakPersistentValue默认runtime/slot均null；LocalHandle只有必需RootSlot指针；HandleScope记录runtime/start且active默认true。WeakPersistent是WeakPersistentValue的别名。NativePin默认runtime/header均null。这些按值结构不带自动复制/析构协议，复制一个拥有槽或pin的结构不会产生独立所有权。
- NativeCleanupJob保存必需finalizer/opaque ptr。DeferredClassPayloadFinalizer保存必需finalizer；class_id默认invalid、generation/object_identity默认0、mark/payload默认null、payload_kind默认none；它持有回调代次pin，实际释放由run完成。CachedIteratorNextEntry保存Object指针与默认null的可选值；RecentTwoUnitString保存两个u16与String指针，RecentAtomString保存Atom与String指针。root_provider_inline_capacity为1。
- `RuntimeMutationError = error{WrongRuntimeThread}`；`RuntimeCollectionError = gc.CollectionError || RuntimeMutationError`（`pollGCChecked` 等宿主入口的错误集）。
- `JSRuntime.HotExecState`：extern 结构的八个字段依次为 call_depth、stack_size、active_bytecode_stack_bytes、native_stack_limit、native_call_depth、native_stack_top、native_stack_size、current_backtrace_frame；Runtime 的 hot 字段要求 64 字节对齐。调用深度和计划字节码帧字节数由同一 Runtime 的各 Context 共享；字段顺序不等于所有目标平台都会生成特定成对加载指令。
- `RuntimeCompactState`：u8 packed 结构，包含四槽 atom-string 缓存的 u2 替换游标、owns_self_allocation 位和五位 padding。分配归属位用于生命周期记账，不能据此假设 destroy 会自动选择不释放调用方存储。
- `NativeEntryFinalizer`：借用的 opaque ptr 与接受该 ptr 的 void 回调；数据类型本身不规定何时执行或自动拥有 ptr。

`JSRuntime` 的字段分工与存活关系：

- `memory`、`gc`、`atoms`、`classes`、`shapes` 是运行时级账户和登记表；owner_thread_id 用于显式或 checked 线程检查，各读写包装并非都自行检查线程。GC assist 债务、账户基准与 mark-footprint 诊断数据各有独立用途，不能混作活堆大小。
- `active_invocation` 借用当前 exec 调用记录，`host_invocation` 保存驻留宿主调用状态并通过 retire 回调清理。small-inline 字节计数及 destroy/trace-atoms 回调让 core 通过接口接入 exec；opaque 指针本身不会自动成为可扫描根。
- live/constructing Context 链、borrowed holders 与 weak holders 是成员或生命周期登记。构造 Context 已可另行注册 root provider，不能把 constructing 链的存在解释为“尚未参加根处理”。root_providers 使用一个 inline 槽起步；local/persistent 槽、活动帧和 weakref_kept_alive 参与相应根扫描，weak_root_slots 保持弱语义。
- deferred native jobs、payload jobs、预入队 payload roots、reservations 与 active payload job 分开存放；排队长度不能代替所有未完成清理的计数。弱对象身份由地址→id 与 id→对象两表维护，next_weak_id 初始为 1；它们不是强根。slots2_payload_attach_count 记录 payload 附加导致的布局溢出，不是旧侧表容量。
- current_exception 及其 uncatchable/out-of-memory 标志由 Runtime 共享；backtrace_frames 与栈上 current_backtrace_frame 属于不同存储。VM arena、逻辑栈预算和 native guard 也分别维护。host_completion_event 初始 unset，can_block 默认 false；是否检查阻塞许可由具体调用方决定。
- 动态 import、延迟全局物化和标准全局安装通过回调字段接入；标准安装器及预留属性数量在初始化时从进程默认值取入。回调 userdata、活动调用记录等借用存储必须遵守各自的外部生命周期协议。
- 字符串缓存包括三个各 256 槽的 single-byte/percent-hex/small-int 表、empty_string、单项 two-unit 和四项 atom-string 表。performance_time_origin_ms 是时间原点数值，opcode_profile 是借用 profile 指针；不能把相邻旧注释误读为这里还存有预分配 OOM Error 对象。native_entries 与 state finalizers 分开登记，native_entry_epoch 为 u32；internal_builtins 在安装前为空，cached_iterator_next_entries 是另一组缓存描述符及容量。

弱身份编码：对象是 `weak_id << 1`（偶数）；符号是 `(atom << 1) | 1`。

---

## 延迟 stdio 关闭与 loader 作用域

### `DeferredStdFileClose.run` (`src/core/runtime.zig:44`)

- **签名**：`fn run(ptr: *anyopaque) void`。
- **作用**：关闭任务持有的FILE并释放任务结构。
- **实现**：还原opaque job，保存runtime，调用closeStdFileHandle并忽略返回码，再memory.destroy。
- **所有权 / 错误 / 调用**：FILE须仍有效且仅由此任务负责关闭；不传播关闭失败，也不在此检测GC阶段。

### `closeStdFileHandle` (`src/core/runtime.zig:52`)

- **签名**：`pub fn closeStdFileHandle(file: *std.c.FILE, is_popen: bool) c_int`。
- **作用**：按文件来源调用pclose或fclose。
- **实现**：is_popen为真用pclose，否则fclose；仅rc==-1时返回负errno，其余原样返回rc。
- **所有权 / 错误 / 调用**：pclose成功结果仍是其原始返回状态，不在此解码退出码；无Zig错误返回，可能阻塞，不能重复关闭同一FILE。

### `enqueueDeferredStdFileClose` (`src/core/runtime.zig:61`)

- **签名**：`pub fn enqueueDeferredStdFileClose(rt: *JSRuntime, file: *std.c.FILE, is_popen: bool) void`。
- **作用**：尝试排队关闭FILE，并在资源不足时同步关闭。
- **实现**：createRuntime失败立即关闭；成功填job后enqueueDeferredNativeCleanup，入队失败则同步关闭并释放job。
- **所有权 / 错误 / 调用**：所有关闭返回码都被忽略；不能保证finalizer期间绝不I/O，因为OOM回退会同步执行。成功交给队列后调用方不得再次关闭FILE，函数不返回错误。

### `DynamicImportLoaderScope.restore` (`src/core/runtime.zig:112`)

- **签名**：`pub fn restore(self: *DynamicImportLoaderScope) void`。
- **作用**：恢复保存的runtime loader。
- **实现**：active=false立即返回，否则assertOwnerThread、写previous并置active=false。
- **所有权 / 错误 / 调用**：幂等但不检查LIFO嵌套或当前loader身份；错误顺序会覆盖较新设置。runtime与userdata仅借用，scope不可复制成可独立恢复的多个所有者。

### `DynamicImportLoaderScope.deinit` (`src/core/runtime.zig:119`)

- **签名**：`pub fn deinit(self: *DynamicImportLoaderScope) void`。
- **作用**：结束一次loader覆盖作用域。
- **实现**：委托restore。
- **所有权 / 错误 / 调用**：不会释放userdata或runtime；与restore相同的owner线程及LIFO前提。

### `setDefaultStandardGlobalsInstaller` (`src/core/runtime.zig:146`)

- **签名**：`pub fn setDefaultStandardGlobalsInstaller( installer: ?StandardGlobalsInstaller, own_property_capacity: usize, ) void`。
- **作用**：设置进程级默认安装器及属性容量。
- **实现**：直接写两个文件级变量，installer可为null，capacity仍按参数保存。
- **所有权 / 错误 / 调用**：无锁/原子同步，不是TLS；调用方安排初始化时序。已创建runtime字段不会自动更新，相同参数重复调用仅产生相同赋值。

## VmStackWindowPolicy / VmStackArena

### `VmStackWindowPolicy.forLimit` (`src/core/runtime.zig:163`)

- **签名**：`pub fn forLimit(limit: usize) VmStackWindowPolicy`。
- **作用**：把逻辑上限编码到策略字。
- **实现**：将usize limit钳到u62最大并转换，两window标志默认false。
- **所有权 / 错误 / 调用**：不分配或强制执行栈限，resident_window也不设置；无错误返回。

### `VmStackWindowPolicy.arenaForLimit` (`src/core/runtime.zig:167`)

- **签名**：`pub fn arenaForLimit(limit: usize) VmStackWindowPolicy`。
- **作用**：建立启用arena标志的策略字。
- **实现**：先forLimit，再置arena_window=true，resident_window仍false。
- **所有权 / 错误 / 调用**：不分配arena或验证实际容量，只返回配置值。

### `VmStackArena.initDefault` (`src/core/runtime.zig:218`)

- **签名**：`pub fn initDefault(self: *VmStackArena) void`。
- **作用**：把arena重置为无块状态。
- **实现**：先std.mem.zeroes，再将64个chunks槽写成标准空切片。
- **所有权 / 错误 / 调用**：不释放旧块；只能用于未拥有块的存储或deinit释放后。避免模板复制是源码动机，不承诺特定机器码/二进制大小。

### `VmStackArena.mark` (`src/core/runtime.zig:226`)

- **签名**：`pub fn mark(self: *const VmStackArena) Mark`。
- **作用**：取得当前arena水位。
- **实现**：保存active；chunk_count为0时used=0，否则取used[active]。
- **所有权 / 错误 / 调用**：只含下标和已用数，没有arena身份或世代，不自行验证后续restore来源。

### `VmStackArena.carve` (`src/core/runtime.zig:233`)

- **签名**：`pub fn carve(self: *VmStackArena, account: *memory.MemoryAccount, n: usize) ?[]JSValue`。
- **作用**：从arena取得n个未初始化值槽。
- **实现**：n为0返回chunks[0]空前缀；n>32768返回null；当前块足够时推进used，否则carveSlow。
- **所有权 / 错误 / 调用**：null涵盖超大窗口、块额度耗尽或分配错误；是否堆回退由调用方决定。不会初始化/追踪槽中值，不自动执行策略limit，窗口使用结束前不能恢复覆盖其水位。

### `VmStackArena.carveActiveMarked` (`src/core/runtime.zig:254`)

- **签名**：`pub inline fn carveActiveMarked(self: *VmStackArena, n: usize) ?ActiveCarve`。
- **作用**：只从当前块无分配切出窗口并带回原水位。
- **实现**：n=0或无块返回null；实际块剩余不足返回null且不改状态，否则bump used并返回Mark/window。
- **所有权 / 错误 / 调用**：不同于carve，零请求视为miss。只看实际容量，不换块或分配；不保证调用方一定回退，窗口内容未初始化。

### `VmStackArena.carveSlow` (`src/core/runtime.zig:276`)

- **签名**：`noinline fn carveSlow(self: *VmStackArena, account: *memory.MemoryAccount, n: usize) ?[]JSValue`。
- **作用**：切换到下一块，必要时分配backing。
- **实现**：下一下标为首块0或active+1，达到64返回null。新首块请求不超过first_chunk_slots时用4KiB，否则分配32768个JSValue；失败返回null且不发布状态。成功或复用后active改为next，used[next]=n。
- **所有权 / 错误 / 调用**：只由carve在n范围合法时调用；不扫描任意可用块。已分配块复用无需分配，调用方保持LIFO保证该块旧窗口不再活跃。

### `VmStackArena.carveTyped` (`src/core/runtime.zig:298`)

- **签名**：`pub fn carveTyped(self: *VmStackArena, account: *memory.MemoryAccount, comptime T: type, n: usize) ?[]T`。
- **作用**：将n个T的字节需求换算成JSValue槽并借用typed视图。
- **实现**：n=0先返回空切片；对齐大于JSValue返回null；checked乘法及divCeil换算，carve后截取精确字节数再bytesAsSlice。
- **所有权 / 错误 / 调用**：溢出、对齐不支持或carve失败均null；非零请求依赖可作字节切片的有效T。不构造T或登记其引用，不把尾部填充字节作为额外T返回。

### `VmStackArena.restore` (`src/core/runtime.zig:310`)

- **签名**：`pub fn restore(self: *VmStackArena, m: Mark) void`。
- **作用**：将使用水位退回此前保存位置。
- **实现**：无块无操作；将m.chunk之后到当前active的used清0，再active=m.chunk、used[m.chunk]=m.used。
- **所有权 / 错误 / 调用**：不释放块、不清值或执行析构、不校验Mark属于本arena或早于当前水位。只能按有效LIFO协议使用，已恢复区域的窗口不能继续持有。

### `VmStackArena.deinit` (`src/core/runtime.zig:318`)

- **签名**：`pub fn deinit(self: *VmStackArena, account: *memory.MemoryAccount) void`。
- **作用**：释放所有已分配arena块并重置。
- **实现**：遍历chunks[0..chunk_count]，非空逐块account.free，再initDefault。
- **所有权 / 错误 / 调用**：包含当前水位之后保留的块，不逐JS值清理；调用方先结束帧/根引用并使用匹配账户。重置后重复deinit无块可释放。

## GC 轮询模式、根缓冲、ValueRootFrame

### `GCPollMode.acceptsMinor` (`src/core/runtime.zig:384`)

- **签名**：`pub fn acceptsMinor(self: GCPollMode) bool`。
- **作用**：判断该模式是否允许仅以minor收集作为本次结果。
- **实现**：idle/safepoint/callback_boundary返回true，normal/urgent返回false。
- **所有权 / 错误 / 调用**：纯枚举映射，不调度GC。false不等于禁止在完整poll流程中先运行minor；实际触发与后续账户检查由pollGC决定。

### `GCPollMode.rootScan` (`src/core/runtime.zig:399`)

- **签名**：`pub fn rootScan(self: GCPollMode) GCRootScan`。
- **作用**：返回该模式请求的根扫描策略。
- **实现**：normal/safepoint/callback_boundary为engine_active；urgent/idle为declared_only。
- **所有权 / 错误 / 调用**：只是策略值，不保证调用时宿主已经静止。生产仍加入保守扫描；测试配置可兑现declared_only。不能把旧源码注释里的rc引用当作当前GC机制。

### `ValueRootBuffer.initCopy` (`src/core/runtime.zig:438`)

- **签名**：`pub fn initCopy(rt: *JSRuntime, source: []const JSValue) !ValueRootBuffer`。
- **作用**：分配一个JSValue位拷贝数组。
- **实现**：空源返回默认空buffer，否则memory.alloc源长度并逐项赋值。
- **所有权 / 错误 / 调用**：不自动成为根、不深拷贝对象、不retain；需把slice描述符放进已激活frame。分配期间源数组与值由调用方保护，失败无新buffer返回。

### `ValueRootBuffer.deinit` (`src/core/runtime.zig:449`)

- **签名**：`pub fn deinit(self: *ValueRootBuffer, rt: *JSRuntime) void`。
- **作用**：清空buffer并释放其数组存储。
- **实现**：先保存values、字段置空，再非空时memory.free。
- **所有权 / 错误 / 调用**：不逐JS对象释放；使用匹配runtime账户，不可复制buffer后分别free。通常先撤回frame；描述符若仍指向此存活buffer会看到空切片，而非已释放backing。

### `ValueRootBuffer.slice` (`src/core/runtime.zig:455`)

- **签名**：`pub fn slice(self: *ValueRootBuffer) ValueRootSlice`。
- **作用**：构造指向buffer切片头的根描述符。
- **实现**：返回mutable=&self.values。
- **所有权 / 错误 / 调用**：不复制数组或激活根；self及描述符引用的存储必须保持地址稳定，之后values的更新可被遍历看到。

### `CellRootBuffer.initCopy` (`src/core/runtime.zig:467`)

- **签名**：`pub fn initCopy(rt: *JSRuntime, source: []const *var_ref_mod.VarRef) !CellRootBuffer`。
- **作用**：分配并复制VarRef指针数组。
- **实现**：空源返回默认值，非空分配同长度指针切片并逐项赋值。
- **所有权 / 错误 / 调用**：不增加VarRef引用计数、不注册根；需由激活frame持有slice描述符。分配错误传播，源及cell图跨分配由调用方保护。

### `CellRootBuffer.deinit` (`src/core/runtime.zig:474`)

- **签名**：`pub fn deinit(self: *CellRootBuffer, rt: *JSRuntime) void`。
- **作用**：释放cell指针数组存储。
- **实现**：保存cells，字段置空，非空交匹配runtime.memory.free。
- **所有权 / 错误 / 调用**：不销毁每个VarRef；清空后再次调用无数组可释放，复制的其他buffer副本不会自动失效。

### `CellRootBuffer.slice` (`src/core/runtime.zig:480`)

- **签名**：`pub fn slice(self: *CellRootBuffer) ValueRootSlice`。
- **作用**：构造cell切片头的根描述符。
- **实现**：返回cells=&self.cells。
- **所有权 / 错误 / 调用**：只是借用描述，不激活根或延长buffer寿命；持有者后续更新切片头能被tracer读取。

### `ValueRootFrameStats.reset` (`src/core/runtime.zig:540`)

- **签名**：`pub fn reset(self: *@This()) void`。
- **作用**：清测试观察计数。
- **实现**：`self.* = .{}`。
- **所有权 / 错误 / 调用**：仅测试维护 `value_root_frame_stats`。

### `ValueRootFrame.hasNativeWindow` (`src/core/runtime.zig:573`)

- **签名**：`pub inline fn hasNativeWindow(self: *const ValueRootFrame) bool`。
- **作用**：检查是否提供至少一个slice描述符。
- **实现**：返回slices.len!=0。
- **所有权 / 错误 / 调用**：不检查被描述数组是否非空，也不查看values/objects/headers；名字不能解释为已经有非空或已激活的根窗口。

### `ValueRootFrame.hasAtomRoots` (`src/core/runtime.zig:580`)

- **签名**：`pub inline fn hasAtomRoots(self: *const ValueRootFrame) bool`。
- **作用**：检查是否提供atom根描述符。
- **实现**：frames禁用时false，当前启用时返回atoms.len!=0。
- **所有权 / 错误 / 调用**：不检查single原子值或list内容；描述符存在即计入激活策略。

### `ValueRootFrame.activate` (`src/core/runtime.zig:589`)

- **签名**：`pub inline fn activate(self: *ValueRootFrame, rt: *JSRuntime) void`。
- **作用**：按配置把当前地址的frame接到runtime根链头。
- **实现**：当前frames启用；container-only且无slices/atoms时直接返回，否则断言当前头不是self，保存previous并更新头。测试统计另由编译期分支维护。
- **所有权 / 错误 / 调用**：只检查不是当前头，不证明frame不在更深链中；必须正确LIFO及单次激活。headers-only和values/objects-only帧在生产默认也会被跳过。与其他frame混合的标量字段会随已链接frame遍历；存储和frame须保持地址稳定。

### `ValueRootFrame.deactivate` (`src/core/runtime.zig:616`)

- **签名**：`pub inline fn deactivate(self: *ValueRootFrame, rt: *JSRuntime) void`。
- **作用**：按当前配置恢复previous根链。
- **实现**：container-only时头不是self便返回；非container诊断构建头不匹配panic，其他模式assert匹配。实际弹出后清previous。
- **所有权 / 错误 / 调用**：生产非头返回既可能是跳过的标量帧，也可能是错误的越序撤回，不能据此保证LIFO已被检测。调用方必须在frame或所指存储失效前正确撤回。

### `ValueRootScope` (`src/core/runtime.zig:647`)

- **签名**：`pub fn ValueRootScope(comptime count: usize) type`。
- **作用**：生成包含标量根描述符和frame的作用域类型。
- **实现**：启用value_root_scalar_scopes_enabled时保存[count]ValueRootValue及默认空frame；否则两个字段均为void。
- **所有权 / 错误 / 调用**：生产默认零大小且操作无效；诊断构建启用。直接默认初始化时storage未定义，必须先填写描述符；类型生成不激活根。

### `ValueRootScope.activate` (`src/core/runtime.zig:659`)

- **签名**：`pub inline fn activate(self: *Self, rt: *JSRuntime) void`。
- **作用**：在最终地址绑定描述符并激活frame。
- **实现**：仅标量scope启用时设置frame.values=&storage，再frame.activate(rt)。
- **所有权 / 错误 / 调用**：禁用时不做操作，不能据调用过activate认定生产标量已有精确根。作用域及被引用槽地址必须稳定。

### `ValueRootScope.deactivate` (`src/core/runtime.zig:666`)

- **签名**：`pub inline fn deactivate(self: *Self, rt: *JSRuntime) void`。
- **作用**：撤回作用域根frame。
- **实现**：启用时frame.deactivate(rt)，禁用时无操作。
- **所有权 / 错误 / 调用**：不释放槽中JS值或对象；启用时遵守LIFO，在引用存储失效前撤回。

### `rootValues` (`src/core/runtime.zig:674`)

- **签名**：`pub inline fn rootValues(slots: anytype) ValueRootScope(slots.len)`。
- **作用**：构造尚未激活的JSValue槽作用域。
- **实现**：标量scope启用时逐项保存传入*JSValue到storage，否则返回空结构。
- **所有权 / 错误 / 调用**：不拷贝值、不retain或自动激活；调用方在最终地址activate，槽后续修改由指针可见。

### `ObjectRootScope` (`src/core/runtime.zig:686`)

- **签名**：`pub fn ObjectRootScope(comptime count: usize) type`。
- **作用**：生成包含标量根描述符和frame的作用域类型。
- **实现**：启用value_root_scalar_scopes_enabled时保存[count]ObjectRootValue及默认空frame；否则两个字段均为void。
- **所有权 / 错误 / 调用**：生产默认零大小且操作无效；诊断构建启用。直接默认初始化时storage未定义，必须先填写描述符；类型生成不激活根。

### `ObjectRootScope.activate` (`src/core/runtime.zig:695`)

- **签名**：`pub inline fn activate(self: *Self, rt: *JSRuntime) void`。
- **作用**：在最终地址绑定描述符并激活frame。
- **实现**：仅标量scope启用时设置frame.objects=&storage，再frame.activate(rt)。
- **所有权 / 错误 / 调用**：禁用时不做操作，不能据调用过activate认定生产标量已有精确根。作用域及被引用槽地址必须稳定。

### `ObjectRootScope.deactivate` (`src/core/runtime.zig:702`)

- **签名**：`pub inline fn deactivate(self: *Self, rt: *JSRuntime) void`。
- **作用**：撤回作用域根frame。
- **实现**：启用时frame.deactivate(rt)，禁用时无操作。
- **所有权 / 错误 / 调用**：不释放槽中JS值或对象；启用时遵守LIFO，在引用存储失效前撤回。

### `rootObjects` (`src/core/runtime.zig:708`)

- **签名**：`pub inline fn rootObjects(slots: anytype) ObjectRootScope(slots.len)`。
- **作用**：构造尚未激活的可选Object槽作用域。
- **实现**：启用时逐项保存*?*Object，禁用时返回空结构。
- **所有权 / 错误 / 调用**：不是直接接受每个Object对象来创建持久根；生产默认省略标量scope，保守根策略另行提供覆盖。

### `AtomRootScope` (`src/core/runtime.zig:734`)

- **签名**：`pub fn AtomRootScope(comptime count: usize) type`。
- **作用**：生成atom根作用域类型。
- **实现**：frames启用时保存[count]AtomRootSlot及ValueRootFrame；不像标量scope，不由container-only配置删去。
- **所有权 / 错误 / 调用**：当前frames恒启用；描述符初始未定义，须先填写。count为0时仍无atom描述符，生产activate可被跳过。

### `AtomRootScope.activate` (`src/core/runtime.zig:745`)

- **签名**：`pub inline fn activate(self: *Self, rt: *JSRuntime) void`。
- **作用**：绑定atom描述符并激活frame。
- **实现**：frames启用时frame.atoms=&storage，再frame.activate。
- **所有权 / 错误 / 调用**：非空atom描述符绕过生产container-only过滤；不复制atom名字，frame与单值/切片头地址须稳定。

### `AtomRootScope.deactivate` (`src/core/runtime.zig:752`)

- **签名**：`pub inline fn deactivate(self: *Self, rt: *JSRuntime) void`。
- **作用**：撤回atom根frame。
- **实现**：frames启用时frame.deactivate。
- **所有权 / 错误 / 调用**：不释放atom或数组，不改变ID值；遵守与激活匹配的LIFO。

### `rootAtoms` (`src/core/runtime.zig:760`)

- **签名**：`pub inline fn rootAtoms(slots: anytype) AtomRootScope(slots.len)`。
- **作用**：构造单atom槽描述符作用域。
- **实现**：frames启用时逐项写single=传入*const Atom或*Atom，否则空结构。
- **所有权 / 错误 / 调用**：返回未激活，不读取当前ID或intern；后续修改通过槽地址被追踪看到。

### `rootAtomList` (`src/core/runtime.zig:771`)

- **签名**：`pub inline fn rootAtomList(list: *const []atom.Atom) AtomRootScope(1)`。
- **作用**：构造一个atom数组切片头描述符。
- **实现**：frames启用时创建AtomRootScope(1)，storage[0].list=list。
- **所有权 / 错误 / 调用**：借用切片头而非固定backing；activate后可随扩容看到新指针和当前长度，但不替调用方管理数组寿命。

### `rootAtomSlots` (`src/core/runtime.zig:781`)

- **签名**：`pub inline fn rootAtomSlots(slots: anytype) AtomRootScope(slots.len)`。
- **作用**：把一组预先构造的atom描述符收进作用域。
- **实现**：frames启用时将slots逐项复制到storage，支持single/list混合。
- **所有权 / 错误 / 调用**：不复制被描述atom数组，也不自动activate；引用的切片头和槽必须有效。

## RootVisitor、ActiveJobRoot

### `RootVisitor.value` (`src/core/runtime.zig:810`)

- **签名**：`pub fn value(self: *RootVisitor, slot: *JSValue) RootTraceError!void`。
- **作用**：通过必需回调访问可写JSValue槽。
- **实现**：调用visit_value(context,slot)，传播RootTraceError。
- **所有权 / 错误 / 调用**：回调可修改原槽，本包装不自行标记、过滤值或回滚修改。

### `RootVisitor.values` (`src/core/runtime.zig:814`)

- **签名**：`pub fn values(self: *RootVisitor, slots: []JSValue) RootTraceError!void`。
- **作用**：逐项访问可变JSValue切片。
- **实现**：顺序调用value(&slot)。
- **所有权 / 错误 / 调用**：首个错误立即终止，已处理槽不回滚；空片段不调用回调。

### `RootVisitor.constValue` (`src/core/runtime.zig:818`)

- **签名**：`pub fn constValue(self: *RootVisitor, stored: JSValue) RootTraceError!void`。
- **作用**：以临时副本访问一个JSValue。
- **实现**：复制stored到局部slot，再value(&slot)。
- **所有权 / 错误 / 调用**：回调写入只作用于副本，不更新调用方原值；回调不得保留临时槽地址。

### `RootVisitor.constValues` (`src/core/runtime.zig:823`)

- **签名**：`pub fn constValues(self: *RootVisitor, stored: []const JSValue) RootTraceError!void`。
- **作用**：以逐值副本访问只读数组。
- **实现**：顺序对每个元素调用constValue。
- **所有权 / 错误 / 调用**：不修改源数组，首个错误即返回；不创建长期根或复制整块backing。

### `RootVisitor.optionalObject` (`src/core/runtime.zig:827`)

- **签名**：`pub fn optionalObject(self: *RootVisitor, slot: *?*Object) RootTraceError!void`。
- **作用**：通过必需回调访问可变可选Object槽。
- **实现**：调用visit_object(context,slot)。
- **所有权 / 错误 / 调用**：即使槽为null也会调用回调，是否跳过由回调决定；原槽可被修改，错误传播。

### `RootVisitor.constOptionalObject` (`src/core/runtime.zig:831`)

- **签名**：`pub fn constOptionalObject(self: *RootVisitor, stored: ?*Object) RootTraceError!void`。
- **作用**：以局部副本访问可选Object指针。
- **实现**：复制stored到slot，再optionalObject(&slot)。
- **所有权 / 错误 / 调用**：null也转发，回调修改不写回源指针；不得保存临时槽地址。

### `RootVisitor.constHeader` (`src/core/runtime.zig:836`)

- **签名**：`pub fn constHeader(self: *RootVisitor, header: *const gc.Header) RootTraceError!void`。
- **作用**：通过可选回调访问直接GC header。
- **实现**：frames启用且visit_header非null时调用，否则无操作。
- **所有权 / 错误 / 调用**：传入const header，不提供可重写指针槽；缺回调不报错，不代表该对象已被标记。

### `RootVisitor.atomRoot` (`src/core/runtime.zig:844`)

- **签名**：`pub fn atomRoot(self: *RootVisitor, id: atom.Atom) RootTraceError!void`。
- **作用**：通过可选回调提交atom ID。
- **实现**：frames启用且visit_atom非null时传context/id，否则无操作。
- **所有权 / 错误 / 调用**：不自动intern或保护atom，实际liveness处理由回调负责；ID按值传递不能改调用方槽。

### `RootVisitor.shapeRoot` (`src/core/runtime.zig:851`)

- **签名**：`pub fn shapeRoot(self: *RootVisitor, stored: *shape.Shape) RootTraceError!void`。
- **作用**：把Shape的header提交给header访问接口。
- **实现**：调用constHeader(&stored.header)。
- **所有权 / 错误 / 调用**：借用指针，不增加根登记或引用数；visit_header缺失时同样无操作。

### `RootVisitor.moduleRoot` (`src/core/runtime.zig:855`)

- **签名**：`pub fn moduleRoot(self: *RootVisitor, stored: *module.ModuleRecord) RootTraceError!void`。
- **作用**：把ModuleRecord的header提交给header访问接口。
- **实现**：调用constHeader(&stored.header)。
- **所有权 / 错误 / 调用**：不直接遍历module子边；可选header回调为空时跳过，错误原样传播。

### `ActiveJobRoot.activate` (`src/core/runtime.zig:880`)

- **签名**：`pub inline fn activate(self: *ActiveJobRoot, rt: *JSRuntime, job: *job_mod.Job) void`。
- **作用**：将出队后仍在执行的Job挂到当前线程根链。
- **实现**：当前启用时检查owner线程、job.runtime匹配及self不是当前头；保存previous/runtime/job并更新TLS头。
- **所有权 / 错误 / 调用**：不复制或执行Job；root节点与job存储必须保持稳定直到deactivate。只断言不是当前头，不证明不存在更深的重复节点；嵌套必须LIFO。

### `ActiveJobRoot.deactivate` (`src/core/runtime.zig:892`)

- **签名**：`pub inline fn deactivate(self: *ActiveJobRoot, rt: *JSRuntime) void`。
- **作用**：从TLS根链摘掉当前活动Job根。
- **实现**：检查owner线程、runtime匹配及self为头，再恢复previous，清previous并将runtime/job置undefined。
- **所有权 / 错误 / 调用**：不执行Job.deinit或返回任务所有权；不能重复撤回。不同runtime嵌套也必须按同一线程链的LIFO处理。

## 句柄：Persistent / Local / Weak / NativePin

### `JSValueHandle.init` (`src/core/runtime.zig:957`)

- **签名**：`pub fn init(runtime: *JSRuntime, value: JSValue) !JSValueHandle`。
- **作用**：为value建立持久根槽。
- **实现**：调用createPersistentRootSlot成功后保存runtime/slot。
- **所有权 / 错误 / 调用**：不深拷贝对象；分配失败不返回有效句柄。此路径不检查owner线程，调用方保证runtime使用纪律。成功后唯一句柄所有者最终take或deinit。

### `JSValueHandle.initDup` (`src/core/runtime.zig:968`)

- **签名**：`pub fn initDup(runtime: *JSRuntime, value: JSValue) !JSValueHandle`。
- **作用**：兼容拼写的持久句柄构造。
- **实现**：直接委托init。
- **所有权 / 错误 / 调用**：无引用计数dup，与init同样创建新根槽。结构的普通位拷贝则不会创建新槽，不能当作独立句柄分别销毁。

### `JSValueHandle.get` (`src/core/runtime.zig:972`)

- **签名**：`pub fn get(self: JSValueHandle) JSValue`。
- **作用**：读取持久槽的值。
- **实现**：slot为空返回undefined，否则返回slot.value。
- **所有权 / 错误 / 调用**：返回位拷贝，不移除根；空句柄与持有undefined无法单凭结果区分。原句柄被销毁后的别名slot不可再访问。

### `JSValueHandle.deinit` (`src/core/runtime.zig:977`)

- **签名**：`pub fn deinit(self: *JSValueHandle) void`。
- **作用**：移除持久根并清空本句柄。
- **实现**：runtime或slot为空则返回；二者存在时先清本字段，再takePersistentRootSlot并丢弃其返回值。
- **所有权 / 错误 / 调用**：释放根槽而非直接销毁JS对象；本句柄正常清空后重复调用无操作，但其他位拷贝不会自动失效。

### `JSValueHandle.destroy` (`src/core/runtime.zig:987`)

- **签名**：`pub fn destroy(self: JSValueHandle, rt: *JSRuntime) void`。
- **作用**：通过按值兼容接口销毁持久根。
- **实现**：runtime存在时断言与rt相同，复制self到局部owned并deinit。
- **所有权 / 错误 / 调用**：原调用方结构没有被清空，其slot随后悬空，不能继续get/deinit；推荐可变句柄deinit。无自动引用计数保护副本。

### `JSValueHandle.take` (`src/core/runtime.zig:994`)

- **签名**：`pub fn take(self: *JSValueHandle) JSValue`。
- **作用**：移出值并撤销持久根。
- **实现**：runtime/slot缺失返回undefined；否则takePersistentRootSlot释放槽，清本字段并返回值。
- **所有权 / 错误 / 调用**：返回值不再由该句柄保护，调用方及时放入其他可达持有者。普通位拷贝的其他句柄仍含过期指针。

### `LocalHandle.get` (`src/core/runtime.zig:1007`)

- **签名**：`pub fn get(self: LocalHandle) JSValue`。
- **作用**：读取scope局部根槽中的值。
- **实现**：直接返回slot.value。
- **所有权 / 错误 / 调用**：不检测scope是否已销毁，无空句柄分支；scope结束后不可使用其LocalHandle副本。

### `LocalHandle.valueSlot` (`src/core/runtime.zig:1011`)

- **签名**：`pub fn valueSlot(self: LocalHandle) *JSValue`。
- **作用**：借用局部根槽的可写值地址。
- **实现**：返回&slot.value。
- **所有权 / 错误 / 调用**：不创建新根或自动写屏障；根槽寿命由scope管理，调用方不得在scope结束后保留地址。

### `HandleScope.enter` (`src/core/runtime.zig:1021`)

- **签名**：`pub fn enter(runtime: *JSRuntime) HandleScope`。
- **作用**：记录当前runtime局部根数组水位。
- **实现**：保存runtime及local_root_slots.len，active默认true。
- **所有权 / 错误 / 调用**：无分配，不创建独立scope栈节点或检查线程；嵌套LIFO由调用方维护。

### `HandleScope.deinit` (`src/core/runtime.zig:1028`)

- **签名**：`pub fn deinit(self: *HandleScope) void`。
- **作用**：清理从进入水位开始的所有局部根。
- **实现**：inactive直接返回；断言start<=当前长度，clearLocalRootSlotsFrom(start)，再active=false。
- **所有权 / 错误 / 调用**：会同时清掉水位之后其他scope创建的槽；断言不是完整LIFO验证。不得复制scope后分别结束，所有对应LocalHandle随之失效。

### `HandleScope.local` (`src/core/runtime.zig:1036`)

- **签名**：`pub fn local(self: *HandleScope, value: JSValue) !LocalHandle`。
- **作用**：在active scope中创建局部根槽。
- **实现**：断言active，调用runtime.createLocalRootSlot并返回slot句柄。
- **所有权 / 错误 / 调用**：分配错误传播；不验证当前scope是否最内层。值按位保存，无JS对象深拷贝，返回句柄只在所属根窗口内有效。

### `HandleScope.localDup` (`src/core/runtime.zig:1045`)

- **签名**：`pub fn localDup(self: *HandleScope, value: JSValue) !LocalHandle`。
- **作用**：以兼容dup拼写创建局部根。
- **实现**：直接委托local。
- **所有权 / 错误 / 调用**：不增加JS引用计数，与local同样创建新的根槽。

### `WeakPersistentValue.init` (`src/core/runtime.zig:1054`)

- **签名**：`pub fn init( runtime: *JSRuntime, value: JSValue, callback: ?WeakPersistentCallback, callback_context: ?*anyopaque, ) !WeakPersistentValue`。
- **作用**：建立弱身份槽并保存可选死亡回调。
- **实现**：weakIdentityFromValue可能登记对象身份；无候选报InvalidWeakTarget。分配WeakRootSlot后retainWeakIdentity，再保存runtime/slot。
- **所有权 / 错误 / 调用**：对象弱身份不retain目标，符号维护弱计数；后续槽分配失败不保证撤回此前建立的对象身份映射。此入口未调用语言级CanBeHeldWeakly过滤，不能直接等同JS WeakRef构造器。

### `WeakPersistentValue.get` (`src/core/runtime.zig:1069`)

- **签名**：`pub fn get(self: WeakPersistentValue) JSValue`。
- **作用**：按弱身份尝试读取目标值。
- **实现**：runtime/slot/identity缺失返回undefined，否则valueFromWeakIdentity。
- **所有权 / 错误 / 调用**：不建立持久根，也不调用keepAliveWeakRefTarget；读到后跨GC保护由调用方负责。符号走symbolValueIfLive，不能把isAlive当作跨GC保证。

### `WeakPersistentValue.isAlive` (`src/core/runtime.zig:1076`)

- **签名**：`pub fn isAlive(self: WeakPersistentValue) bool`。
- **作用**：检查当前弱身份查询是否仍匹配活目标。
- **实现**：空状态false，否则weakIdentityIsCurrentlyLive；对象查身份表，符号检查atom kind为symbol。
- **所有权 / 错误 / 调用**：不执行完整可达性收集、不延长寿命；符号判断与get中的body存活检查不完全相同，不保证之后get必成功。

### `WeakPersistentValue.deinit` (`src/core/runtime.zig:1083`)

- **签名**：`pub fn deinit(self: *WeakPersistentValue) void`。
- **作用**：注销并销毁弱槽。
- **实现**：runtime/slot齐全时先清本句柄，再destroyWeakRootSlot。
- **所有权 / 错误 / 调用**：清弱身份采用notify=false，不调用死亡回调；不销毁目标对象。别名句柄不可随后再次操作旧槽。

### `WeakPersistentValue.destroy` (`src/core/runtime.zig:1091`)

- **签名**：`pub fn destroy(self: WeakPersistentValue, rt: *JSRuntime) void`。
- **作用**：按值兼容接口撤销弱槽。
- **实现**：断言rt与句柄runtime匹配，局部副本deinit。
- **所有权 / 错误 / 调用**：原结构不会清空，之后视为失效；不允许继续get或再次销毁。

### `NativePin.deinit` (`src/core/runtime.zig:1104`)

- **签名**：`pub fn deinit(self: *NativePin) void`。
- **作用**：解除本pin的一次header固定。
- **实现**：runtime/header齐全时先置空本字段，再gc.unpinHeader。
- **所有权 / 错误 / 调用**：不直接销毁header；普通复制不增加pin次数，不能分别unpin。空状态重复清理无操作。

### `pinValueForNative` (`src/core/runtime.zig:1113`)

- **签名**：`pub fn pinValueForNative(runtime: *JSRuntime, value: JSValue) !?NativePin`。
- **作用**：对有GC header的值创建native pin。
- **实现**：依次尝试refHeader、objectHeader，均无则返回null；有则pinHeaderForNative。
- **所有权 / 错误 / 调用**：null表示无可pin的header，不是OOM；pin分配错误传播，不复制值或创建Persistent根槽。

### `pinHeaderForNative` (`src/core/runtime.zig:1118`)

- **签名**：`pub fn pinHeaderForNative(runtime: *JSRuntime, header: *gc.Header) !NativePin`。
- **作用**：为指定GC header登记pin。
- **实现**：先gc.pinHeader，成功返回runtime/header组成的NativePin。
- **所有权 / 错误 / 调用**：可能分配失败；不验证header来自该runtime，调用方保证身份和存活。成功必须最终unpin一次。

### `NativeCleanupJob.run` (`src/core/runtime.zig:1130`)

- **签名**：`pub fn run(self: NativeCleanupJob) void`。
- **作用**：执行一个不透明native清理回调。
- **实现**：调用finalizer(ptr)。
- **所有权 / 错误 / 调用**：不释放Job容器、不清字段或防止重复调用，不验证GC安全阶段；外层队列负责调度、一次性及资源协议。

### `DeferredClassPayloadFinalizer.run` (`src/core/runtime.zig:1144`)

- **签名**：`pub fn run(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime) void`。
- **作用**：调用已保存的class析构器并清理剩余detached payload。
- **实现**：defer释放class/generation回调pin；直接传rt、&object_identity和&payload给finalizer，返回后destroyDetachedClassPayload。
- **所有权 / 错误 / 调用**：payload在回调期间仍留在本Job槽中；活动根发布由外层runDeferredClassPayloadFinalizerJob负责，本方法不自行检查collector阶段或防重入。回调可修改payload，后续清理针对修改后的槽，不能重复run释放同一pin。

### `DeferredClassPayloadFinalizer.traceRoots` (`src/core/runtime.zig:1155`)

- **签名**：`pub fn traceRoots(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：通过保存的PayloadMark回调枚举payload边。
- **实现**：payload为空或mark缺失直接返回。构造局部adaptor/两类visitor回调，执行mark后若err有值则返回。
- **所有权 / 错误 / 调用**：visitor失败只记录错误，不中止mark；后续失败会覆盖此前错误，最终返回最后一次记录的错误，不是首个。不自动注册Job根，opaque identity指向保存的数值字段而非可解引用Object。

### `DeferredClassPayloadFinalizer.PayloadTraceAdaptor.visitValue` (`src/core/runtime.zig:1162`)

- **签名**：`pub fn visitValue(context: *anyopaque, value_ptr: *anyopaque) void`。
- **作用**：将opaque值槽转交RootVisitor。
- **实现**：还原adaptor及*JSValue，调用value；失败写adaptor.err。
- **所有权 / 错误 / 调用**：void回调不能直接返回错误，因此mark可继续枚举；不检查已有err、不回滚修改，不可保存局部adaptor供异步使用。

### `DeferredClassPayloadFinalizer.PayloadTraceAdaptor.visitObject` (`src/core/runtime.zig:1170`)

- **签名**：`pub fn visitObject(context: *anyopaque, object_ptr: *anyopaque) void`。
- **作用**：将opaque可选对象槽转交RootVisitor。
- **实现**：还原*?*Object并调用optionalObject，失败覆盖adaptor.err。
- **所有权 / 错误 / 调用**：传入的是槽地址，不是Object本身；与value适配相同，错误不停止mark，回调须同步完成。

## JSRuntime 构造 / 线程 / 析构

### `JSRuntime.init` (`src/core/runtime.zig:1539`)

- **签名**：`pub fn init(self: *JSRuntime, allocator: std.mem.Allocator, options: RuntimeOptions) !void`。
- **作用**：初始化调用方提供的runtime存储。
- **实现**：按trace_writer选择MemoryAccount构造，再initWithAccount(account,options,false)。
- **所有权 / 错误 / 调用**：不拥有self分配；初始化后内部账户/registry互相借用字段地址，runtime不可按值移动。失败对象未完全初始化，不能假定可直接运行完整deinit。

### `JSRuntime.create` (`src/core/runtime.zig:1548`)

- **签名**：`pub fn create(allocator: std.mem.Allocator) !*JSRuntime`。
- **作用**：以默认选项分配并初始化runtime。
- **实现**：委托createWithOptions(allocator,.{})。
- **所有权 / 错误 / 调用**：返回拥有self分配的runtime，最终由destroy释放；不是只构造配置或自动创建realm。

### `JSRuntime.createWithOptions` (`src/core/runtime.zig:1553`)

- **签名**：`pub fn createWithOptions(allocator: std.mem.Allocator, options: RuntimeOptions) !*JSRuntime`。
- **作用**：通过新账户分配runtime并初始化。
- **实现**：按trace_writer创建account，account.create(JSRuntime)，失败清理该分配；initWithAccount传owns_self_allocation=true。
- **所有权 / 错误 / 调用**：self分配发生在initWithAccount应用memory_limit之前，不能宣称构造最初分配已受该limit检查。初始化错误传播，外层errdefer只负责self存储，不代替各子系统自己的失败清理。

### `JSRuntime.initWithAccount` (`src/core/runtime.zig:1564`)

- **签名**：`fn initWithAccount(rt: *JSRuntime, account: memory.MemoryAccount, options: RuntimeOptions, owns_self_allocation: bool) !void`。
- **作用**：在最终地址建立runtime各子系统和初始状态。
- **实现**：记录owner线程、复制账户/所有权标志并绑定allocator facade；关闭GC触发钩子后应用limit，初始化GC链/观察器/对象heap、atom owner、class及shape。清空根/队列/弱身份/清理/缓存/回溯等，复制默认安装器与options，建立栈策略及native栈基准，最后启用slab与分配/限额GC钩子。
- **所有权 / 错误 / 调用**：地址稳定是必要条件。可失败调用为serveObjectCells和classes.initInPlace；本函数仅在class初始化成功后设classes.deinit errdefer，没有完整runtime回滚defer，不能由此声称所有前序资源统一回收。不会创建realm、安装标准global或开启TLS profile。

### `JSRuntime.setOpcodeProfile` (`src/core/runtime.zig:1704`)

- **签名**：`pub fn setOpcodeProfile(self: *JSRuntime, opcode_profile: ?*profile.OpcodeProfile) void`。
- **作用**：设置runtime剖析指针及分配计数字段链接。
- **实现**：保存opcode_profile，并将memory.profile_alloc_count设为&prof.alloc_count或null。
- **所有权 / 错误 / 调用**：借用profile，须保持存活；不切换profile模块TLS、不flush pending或清计数，不检查owner线程。

### `JSRuntime.isOwnerThread` (`src/core/runtime.zig:1709`)

- **签名**：`pub fn isOwnerThread(self: *const JSRuntime) bool`。
- **作用**：比较当前线程与初始化时记录的owner。
- **实现**：owner_thread_id == std.Thread.getCurrentId()。
- **所有权 / 错误 / 调用**：只检查身份，不加锁、不迁移runtime，不证明调用处于可重入安全边界。

### `JSRuntime.requireOwnerThread` (`src/core/runtime.zig:1713`)

- **签名**：`pub fn requireOwnerThread(self: *const JSRuntime) RuntimeMutationError!void`。
- **作用**：以错误返回形式验证owner线程。
- **实现**：isOwnerThread为false则WrongRuntimeThread，否则成功。
- **所有权 / 错误 / 调用**：不改变状态、不获得锁；调用方必须实际调用才有此边界保护。

### `JSRuntime.assertOwnerThread` (`src/core/runtime.zig:1717`)

- **签名**：`pub fn assertOwnerThread(self: *const JSRuntime) void`。
- **作用**：以panic形式强制owner线程。
- **实现**：不匹配时直接@panic固定消息。
- **所有权 / 错误 / 调用**：不是std.debug.assert，因此不能假定ReleaseFast会删除此检查；不返回可捕获的RuntimeMutationError。

### `JSRuntime.deinit` (`src/core/runtime.zig:1721`)

- **签名**：`pub fn deinit(self: *JSRuntime) void`。
- **作用**：按依赖顺序拆除runtime资源，保留self存储。
- **实现**：先检查owner/执行空闲，退役host invocation、释放VM栈和回溯、清异常/kept-alive及队列缓存。清外部host函数并多次drain native/class清理；检查句柄，进行两次quiescent收集与最终化任务清理，再次释放Job backing。随后清atom字符串缓存、检查host realm引用、gc.deinit及其产生的清理任务，最后拆弱映射/AutoInit/shape/class/atom、各容器容量和slab。
- **所有权 / 错误 / 调用**：并非一次free所有字段：可执行宿主finalizer，必须遵守其重入协议。不会替用户关闭未结束句柄；重复deinit不受支持。自有self分配时最终账户应仅剩自身，否则应无未释放分配，这些尾部校验为debug断言。

### `JSRuntime.destroy` (`src/core/runtime.zig:1864`)

- **签名**：`pub fn destroy(self: *JSRuntime) void`。
- **作用**：拆除runtime并释放自身分配。
- **实现**：assertOwnerThread后deinit，复制memory账户到局部，再account.destroy(JSRuntime,self)，最后断言账户无剩余分配。
- **所有权 / 错误 / 调用**：必须用于create/createWithOptions返回的自有分配；不会按owns_self_allocation跳过free。调用方栈上或外部分配后init的runtime应使用deinit，不得调用destroy。

### `JSRuntime.tryDestroy` (`src/core/runtime.zig:1874`)

- **签名**：`pub fn tryDestroy(self: *JSRuntime) RuntimeMutationError!void`。
- **作用**：检查线程后执行完整destroy。
- **实现**：requireOwnerThread成功才destroy。
- **所有权 / 错误 / 调用**：仅将错线程转换为WrongRuntimeThread且不改状态；未结束执行/句柄等仍可能panic，不是全面安全回收或可重试事务。

## Runtime 分配器与对象登记

这些入口走 `MemoryAccount.*NoTrigger`，自己做阈值检查。qjs 的 `js_malloc_rt` 不做检查，单一站点是 `JS_NewObjectFromShape` 的 `js_trigger_gc`（quickjs.c:5619）。

### `JSRuntime.allocRuntime` (`src/core/runtime.zig:1888`)

- **签名**：`pub inline fn allocRuntime(self: *JSRuntime, comptime T: type, count: usize) ![]T`。
- **作用**：通过账户分配count个T。
- **实现**：仅编译期开启runtime_allocation_requests_gc且count非0时，计算字节数并requestGCForAllocation；乘法溢出以usize最大作为请求估值。随后allocNoTrigger。
- **所有权 / 错误 / 调用**：生产默认触发开关关闭，不能宣称每次此分配都先GC；估值饱和不等于分配一定成功，实际错误由账户返回。返回存储未由本函数初始化或注册根。

### `JSRuntime.freeRuntime` (`src/core/runtime.zig:1898`)

- **签名**：`pub inline fn freeRuntime(self: *JSRuntime, comptime T: type, slice: []T) void`。
- **作用**：归还账户分配的类型化切片。
- **实现**：直接memory.free(T,slice)。
- **所有权 / 错误 / 调用**：不执行元素析构或GC图摘链；需要匹配账户及原分配范围。

### `JSRuntime.remapRuntime` (`src/core/runtime.zig:1902`)

- **签名**：`pub inline fn remapRuntime(self: *JSRuntime, comptime T: type, slice: []T, new_count: usize) !?[]T`。
- **作用**：尝试调整切片分配并返回可选新切片。
- **实现**：触发开关开启且增长时用新旧字节估值的饱和差requestGCForAllocation，再memory.remap。
- **所有权 / 错误 / 调用**：null表示remap未完成，不在此自动alloc/copy/free回退；错误传播。成功地址可能改变，调用方使用返回值并维护根描述符，收缩不产生此处增长请求。

### `JSRuntime.createRuntime` (`src/core/runtime.zig:1913`)

- **签名**：`pub inline fn createRuntime(self: *JSRuntime, comptime T: type) !*T`。
- **作用**：分配一个T的原始存储。
- **实现**：触发开关启用时requestGCForAllocation(sizeof(T))，随后memory.createNoTrigger。
- **所有权 / 错误 / 调用**：不调用T构造器、填默认值或登记GC；NoTrigger只描述底层这一路触发选择，不是整个账户绝不可能执行限额处理的保证。

### `JSRuntime.destroyRuntime` (`src/core/runtime.zig:1918`)

- **签名**：`pub inline fn destroyRuntime(self: *JSRuntime, comptime T: type, ptr: *T) void`。
- **作用**：归还一个T的账户存储。
- **实现**：直接memory.destroy(T,ptr)。
- **所有权 / 错误 / 调用**：不调用T.deinit或销毁子资源，也不替调用方摘GC登记；必须先完成对应生命周期清理。

### `JSRuntime.allocRuntimeAlignedBytes` (`src/core/runtime.zig:1922`)

- **签名**：`pub inline fn allocRuntimeAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8`。
- **作用**：按显式对齐分配字节存储。
- **实现**：触发开关启用且byte_count非0时requestGCForAllocation，再allocAlignedBytesNoTrigger。
- **所有权 / 错误 / 调用**：返回未初始化字节，不注册根；使用匹配alignment及账户释放，分配错误传播。

### `JSRuntime.freeRuntimeAlignedBytes` (`src/core/runtime.zig:1929`)

- **签名**：`pub inline fn freeRuntimeAlignedBytes(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void`。
- **作用**：按原对齐归还字节分配。
- **实现**：调用memory.freeAlignedBytes(bytes,alignment)。
- **所有权 / 错误 / 调用**：不推断原对齐或清理字节中的对象；调用方提供正确分配信息。

### `JSRuntime.registerObject` (`src/core/runtime.zig:1933`)

- **签名**：`pub fn registerObject(self: *JSRuntime, object: *Object) !void`。
- **作用**：把已初始化对象登记到 GC，并记录其分配大小。
- **实现**：先以 `assertOwnerThread` 检查线程，再计算 `object.allocationSize(self)` 并调用 `registerObjectWithBytes`；本包装不重新检查收集阈值。
- **所有权 / 错误 / 调用**：登记不等于创建强根。非块对象登记可能准备额外容量并返回分配错误；调用方负责尚未成功登记的对象。已知大小的创建路径可直接使用 WithBytes。

### `JSRuntime.registerObjectWithBytes` (`src/core/runtime.zig:1960`)

- **签名**：`pub inline fn registerObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) !void`。
- **作用**：调用方已算好 `object_size` 的登记（createInternal 热路径）。
- **实现**：调用 `std.debug.assert(self.isOwnerThread())`，然后 `gc.addInitializedWithSize`。断言关闭不代表带副作用的线程查询必然被消除；这里没有包住查询的 comptime 分支。
- **所有权 / 错误 / 调用**：调用方提供准确的分配大小及完整初始化的对象。非块对象先准备登记容量，成功后才执行不可失败的发布；它并非始终无分配的链表操作。

### `JSRuntime.unregisterObjectWithBytes` (`src/core/runtime.zig:1985`)

- **签名**：`pub fn unregisterObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) void`。
- **作用**：GC 链表摘除 + 字节记账。`destroyFromHeader` 已算 size。弱/借用表在 teardown 顶部已摘。
- **实现**：仅在 runtime_safety 开启时查询并断言线程；Debug 还检查弱/借用登记已撤销。已 condemned 则调用 `recordDetachedHeapFreeWithBytes` 扣除记账，否则调用 `unlinkObjectWithBytes` 撤销相应登记并扣账。
- **所有权 / 错误 / 调用**：对象销毁路径提供准确大小，并事先摘除弱/借用侧表。本函数不释放对象存储，也不执行 payload 析构；不可因已摘链而重复调用扣账。

### `JSRuntime.registerWeakReferenceHolder` (`src/core/runtime.zig:2014`)

- **签名**：`pub fn registerWeakReferenceHolder(self: *JSRuntime, object: *Object) void`。
- **作用**：无分配地把弱能力 payload 链进 Runtime 侵入式表，对齐 qjs `weakref_list`。GC 弱遍历期间 emptiness 变化不得改表。
- **实现**：经 `weakReferenceHolderLink` 接到 tail，`registered=true`，`markNeedsFinalizer`（死亡必须 unlink，TGC S4-d c 类）。
- **所有权 / 错误 / 调用**：要求对象属于弱引用持有者类、具有未链接且未登记的 payload link；这些前提以断言检查，不提供重复登记的幂等保证。该表不因此成为保持对象存活的强根。

### `JSRuntime.unregisterWeakReferenceHolder` (`src/core/runtime.zig:2036`)

- **签名**：`pub fn unregisterWeakReferenceHolder(self: *JSRuntime, object: *Object) void`。
- **作用**：从表摘下。
- **实现**：非该类、无 link 或未登记时返回，否则修复前后节点及首尾指针，并清空自身 previous/next/registered。
- **所有权 / 错误 / 调用**：不释放对象或 payload；有效对象上的重复撤销可直接返回，但不能用于已经释放的对象。

### `JSRuntime.registerBorrowedReferenceHolder` (`src/core/runtime.zig:2062`)

- **签名**：`pub fn registerBorrowedReferenceHolder(self: *JSRuntime, object: *Object) !void`。
- **作用**：把对象记入借用引用侧表（realm/weak 指针寿命记账）。不给对象加 exotic，不毒 shape 快路径。
- **实现**：已登记返回。`appendRuntimeObject`，写 index 与 flag，`markNeedsFinalizer`。
- **所有权 / 错误 / 调用**：侧表扩容可能失败；成功追加后才写对象的 index/flag 并标记需要终结。已有 flag 时直接返回，不验证是否属于这个 Runtime；调用方必须保证归属正确。此登记不增加强根。

### `JSRuntime.borrowedReferenceHolderRegistered` (`src/core/runtime.zig:2077`)

- **签名**：`pub fn borrowedReferenceHolderRegistered(self: *const JSRuntime, object: *Object) bool`。
- **作用**：读对象 flag。
- **实现**：忽略 self，返回 `flags.is_borrowed_reference_holder`。
- **所有权 / 错误 / 调用**：不搜索当前 Runtime 的表，因此返回 true 不能证明对象已登记在 self 中。

### `JSRuntime.unregisterBorrowedReferenceHolder` (`src/core/runtime.zig:2082`)

- **签名**：`pub fn unregisterBorrowedReferenceHolder(self: *JSRuntime, object: *Object) void`。
- **作用**：侧表移除。
- **实现**：无 flag 则返回；缓存 index 必须在范围内且对应同一对象才可直接删除，否则线性搜索后调用 `removeBorrowedReferenceHolderAt`。
- **所有权 / 错误 / 调用**：搜索不到直接返回，不清对象 flag/index，不修复归属不一致。正常删除不释放对象，且不保持表内顺序。

### `JSRuntime.removeBorrowedReferenceHolderAt` (`src/core/runtime.zig:2101`)

- **签名**：`fn removeBorrowedReferenceHolderAt(self: *JSRuntime, index: usize) void`。
- **作用**：swap-remove 侧表项。
- **实现**：断言 index 有效；若非末项，把末项移来并更新其 index；缩短有效切片，清被删对象的 index/flag。
- **所有权 / 错误 / 调用**：不缩减容量、不清底层末槽、不释放被删对象。调用方不可依赖稳定顺序或删除前的索引。

---

## Realm 列表、prototype 容量、根 provider

### `JSRuntime.linkContext` (`src/core/runtime.zig:2115`)

- **签名**：`pub fn linkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void`。
- **作用**：接到 live `context_head` 尾。纯 membership。
- **实现**：显式检查 owner 线程，断言 ctx.runtime 与 self 相同且前后指针为空，再接到 tail。
- **所有权 / 错误 / 调用**：由 `publishLive` 调用，仅修改成员链，不创建 GC 强根或更改 Context 状态。空前后指针不能识别已经是唯一节点的重复登记，调用方必须保证只链接一次。

### `JSRuntime.linkConstructingContext` (`src/core/runtime.zig:2128`)

- **签名**：`pub fn linkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void`。
- **作用**：接到 constructing 成员列表，使未发布的 realm 与 live 枚举分开。
- **实现**：显式检查 owner 线程，断言 Runtime 归属及空 construction 前后指针，再进行尾插。
- **所有权 / 错误 / 调用**：`initConstructing` 另行注册 root provider，故不能将“不在 live 列表”理解为“不参与根处理”。本函数不注册 provider、不改变状态；也不保证重复链接安全。

### `JSRuntime.unlinkConstructingContext` (`src/core/runtime.zig:2141`)

- **签名**：`pub fn unlinkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void`。
- **作用**：从 constructing 列表摘下。
- **实现**：显式检查 owner 线程；前后指针都为空且不是表头时返回，否则修复邻居与首尾，最后清空自身 construction 前后指针。
- **所有权 / 错误 / 调用**：`publishLive` / teardown 使用；不释放 Context、不撤销 root provider，也不更改状态。不是搜索验证归属，调用方须使用正确 Runtime。

### `JSRuntime.unlinkContext` (`src/core/runtime.zig:2160`)

- **签名**：`pub fn unlinkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void`。
- **作用**：从 live 列表摘下。
- **实现**：显式检查 owner 线程；runtime 前后指针都为空且不是表头时返回，否则修复邻居与首尾，再清空自身 runtime 前后指针。
- **所有权 / 错误 / 调用**：`deinitResources` 使用；只摘成员链，不释放 Context 或撤销其 root provider。要求正确 Runtime 归属。

### `JSRuntime.firstContext` (`src/core/runtime.zig:2179`)

- **签名**：`pub fn firstContext(self: *const JSRuntime) ?*context_mod.JSContext`。
- **作用**：live 列表头。
- **实现**：`context_head`。
- **所有权 / 错误 / 调用**：返回借用指针，不保活、不检查线程；空表返回 null，不枚举 constructing 列表。

### `JSRuntime.assertNoHostRealmRefsForTeardown` (`src/core/runtime.zig:2183`)

- **签名**：`fn assertNoHostRealmRefsForTeardown(self: *JSRuntime) void`。
- **作用**：在安全构建检查realm宿主create-ref已消费。
- **实现**：runtime_safety关闭直接返回，否则分别遍历live与constructing链，断言每个ctx.host_api_release_consumed。
- **所有权 / 错误 / 调用**：不消费引用或释放realm；ReleaseFast等关闭安全检查的模式不执行此审计，但宿主生命周期前提仍须满足。

### `JSRuntime.contextForGlobal` (`src/core/runtime.zig:2195`)

- **签名**：`pub fn contextForGlobal(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext`。
- **作用**：按全局对象找**已发表** realm。
- **实现**：沿 `context_head` 的 runtime_next 顺序比较 ctx.global 与参数的指针身份，返回首个匹配项，找不到返回 null。
- **所有权 / 错误 / 调用**：返回借用 Context，不保活、不检查线程；不包含 constructing，也不验证参数是否属于当前 Runtime。

### `JSRuntime.contextForGlobalIncludingConstructing` (`src/core/runtime.zig:2205`)

- **签名**：`pub fn contextForGlobalIncludingConstructing(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext`。
- **作用**：bootstrap 解析器，含未发表 realm。
- **实现**：优先返回 `contextForGlobal` 的 live 匹配，否则沿 construction_next 查找首个 global 指针相同的 Context，两边都没有则返回 null。
- **所有权 / 错误 / 调用**：bootstrap 使用的借用查询，不发布 Context 或创建根；普通 live 枚举使用不包含 constructing 的版本。

### `JSRuntime.invalidateStandardArrayPrototypeForObjectPrototype` (`src/core/runtime.zig:2218`)

- **签名**：`pub fn invalidateStandardArrayPrototypeForObjectPrototype(self: *JSRuntime, object_prototype: *Object) void`。
- **作用**：使缓存了指定 Object 原型的 realm 的标准 Array 原型标记失效。
- **实现**：显式检查 owner 线程，遍历 live 与 constructing 两条列表，对每个 Context 调用 `invalidateContextStandardArrayPrototype`。
- **所有权 / 错误 / 调用**：整数属性变更路径决定何时调用；本函数不自行检查属性键或 immutable 条件。所有匹配 realm 都会处理，无关 realm 不变；不清缓存或修改原型链。

### `JSRuntime.invalidateContextStandardArrayPrototype` (`src/core/runtime.zig:2230`)

- **签名**：`fn invalidateContextStandardArrayPrototype(ctx: *context_mod.JSContext, object_prototype: *Object) void`。
- **作用**：若 ctx 的 object_prototype 缓存就是该对象，清 array prototype 的 `is_std_array_prototype`。
- **实现**：object_prototype 缓存缺失或对象身份不匹配则返回；匹配后若 array_prototype 缓存存在，将其对象的 `is_std_array_prototype` 设为 false。
- **所有权 / 错误 / 调用**：缓存类型是内部不变量，`Object.expect` 失败走 unreachable，而非返回可恢复类型错误。只清标记，不释放任何对象。

### `JSRuntime.initialArrayShapeForPrototype` (`src/core/runtime.zig:2242`)

- **签名**：`pub fn initialArrayShapeForPrototype(self: *const JSRuntime, prototype: ?*const Object) ?*shape.Shape`。
- **作用**：找以该 prototype 为 proto 的 realm 初始 array shape。
- **实现**：先扫 live、再扫 constructing；跳过没有 array_shape 的 Context，按初始 shape 的 proto 与参数相等返回首个匹配，找不到返回 null。参数 null 也按相等规则参与匹配。
- **所有权 / 错误 / 调用**：返回借用 Shape，不创建、不复制、不保活；只比较原型身份，不检查标准 Array 原型标记。

### `JSRuntime.ensureContextClassPrototypeCapacity` (`src/core/runtime.zig:2259`)

- **签名**：`pub fn ensureContextClassPrototypeCapacity(self: *JSRuntime, class_id: class.ClassId) !void`。
- **作用**：为现有 live 和 constructing Context 确保指定 class id 的 prototype 槽可用；本函数不发布 class id 或设置 prototype 值。
- **实现**：先 `requireOwnerThread`，依次遍历两条列表；每次先保存下一节点的 RealmRef，再调用当前 Context 的 `ensureClassPrototypeSlot`，然后推进。
- **所有权 / 错误 / 调用**：可能返回 WrongRuntimeThread 或分配错误；后续节点失败不会回滚已扩大的前序 Context 槽数组。当前 RealmRef.retain 只包装指针，并非增加引用计数、pin 或自动登记根，不能据其名称推断保活保证。

### `JSRuntime.nextRetainableClassPrototypeContext` (`src/core/runtime.zig:2289`)

- **签名**：`fn nextRetainableClassPrototypeContext( self: *JSRuntime, start: ?*context_mod.JSContext, comptime list: ClassPrototypeContextList, ) context_mod.RealmRef`。
- **作用**：为清理 class prototype 选择下一个可处理 Context。
- **实现**：按 comptime list 选择 runtime_next 或 construction_next；仅当 GC phase 为 tracer_destroy 且当前 header 已 condemned 时跳过，否则返回包装当前指针的 RealmRef；走到末尾返回空值。
- **所有权 / 错误 / 调用**：被跳过节点的结构和链接在该遍历阶段仍须有效，其资源清理由销毁流程负责。当前实现没有 trial RC 判定或 retain 增计数，其他 GC 阶段也不会按 condemned 标记过滤。

### `JSRuntime.clearContextClassPrototype` (`src/core/runtime.zig:2318`)

- **签名**：`pub fn clearContextClassPrototype(self: *JSRuntime, class_id: class.ClassId) void`。
- **作用**：清空 live 与 constructing Context 中指定 class id 的 prototype 槽，供 class 注销流程使用。
- **实现**：显式检查 owner 线程；通过 `nextRetainableClassPrototypeContext` 选择当前及下一节点，再调用 `clearClassPrototype`。tracer_destroy 阶段跳过 condemned Context。
- **所有权 / 错误 / 调用**：越出某个 Context 已有槽范围时该 Context 无操作；已有槽置 null，不缩减容量、不直接销毁 prototype 对象，也不自行注销 class 定义或卸载插件。

### `JSRuntime.registerRootProvider` (`src/core/runtime.zig:2341`)

- **签名**：`pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void`。
- **作用**：登记精确根提供器；相同 (context,trace) 幂等。
- **实现**：先显式检查 owner 线程，再扫描 context 指针和 trace 回调同时相等的条目；已有则返回，否则 `appendRootProvider`。
- **所有权 / 错误 / 调用**：扩容可能失败；只保存 provider 描述符，不复制或拥有其 context，不立即执行 trace。调用方保证 context 和回调在登记期间有效。同一 context 配不同 trace 是不同登记；重复登记不累加撤销次数。

### `JSRuntime.registerRootProviderChecked` (`src/core/runtime.zig:2349`)

- **签名**：`pub fn registerRootProviderChecked(self: *JSRuntime, provider: RootProvider) !void`。
- **作用**：错线程时返回错误的登记入口；普通版本的错线程检查会 panic。
- **实现**：`requireOwnerThread` + `registerRootProvider`。
- **所有权 / 错误 / 调用**：WrongRuntimeThread / OOM。

### `JSRuntime.rootProvidersUsingInline` (`src/core/runtime.zig:2354`)

- **签名**：`fn rootProvidersUsingInline(self: *const JSRuntime) bool`。
- **作用**：是否仍用 inline 单槽。
- **实现**：比较 root_providers.ptr 与自身 root_providers_inline 首地址，不通过长度判断；空表也可能使用 inline。
- **所有权 / 错误 / 调用**：grow/unregister 决定 free。

### `JSRuntime.appendRootProvider` (`src/core/runtime.zig:2358`)

- **签名**：`fn appendRootProvider(self: *JSRuntime, provider: RootProvider) !void`。
- **作用**：容量不够则从 inline 1 或 ×2 堆分配，再追加。
- **实现**：满时分配新数组、复制有效条目，切换切片和容量后释放旧堆数组；不释放 inline 存储。随后扩有效长度并写入 provider。
- **所有权 / 错误 / 调用**：分配失败保留原表；成功扩容会使指向旧表元素的借用失效。本私有函数不去重、不检查线程、不调用 provider 回调。

### `JSRuntime.unregisterRootProvider` (`src/core/runtime.zig:2376`)

- **签名**：`pub fn unregisterRootProvider(self: *JSRuntime, provider: RootProvider) void`。
- **作用**：按 (context,trace) 移除；空表回到 inline。
- **实现**：显式检查 owner 线程，找首个 context 和 trace 同时相等的项；找不到返回。向前移动后续项保留顺序；变空时恢复 inline 空切片及其容量，并释放原堆数组。
- **所有权 / 错误 / 调用**：不调用 provider 的析构或 trace，不释放其 context；剩余非空时不缩减容量。重复撤销可无操作，但调用方应在 context 或回调失效前撤销登记。

---

## 根扫描

### `JSRuntime.traceRoots` (`src/core/runtime.zig:2403`)

- **签名**：`pub fn traceRoots(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：描 Runtime 的声明根：value-root 链、current_exception、local/persistent 槽、deferred payload 根与 finalizer、active deferred job、job_queue、weakref kept-alive、root providers、字符串缓存、atom 根。
- **实现**：按上述次序调用 visitor 和 provider；任一步返回错误即停止，已经访问的项不回滚。弱槽不作为强根扫描；deferred payload roots 扫描的是其 payload 边。
- **所有权 / 错误 / 调用**：roots 参数决定扫描哪条帧链，不自动替换为 active_value_roots；TLS 活动 job、active invocation 及 Atomics adapter 由 `traceActiveRoots` 补充。本函数不加锁、不检查 owner 线程，也不自行运行收集器。

### `JSRuntime.traceAtomRoots` (`src/core/runtime.zig:2433`)

- **签名**：`fn traceAtomRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：TGC S3 §2.2 根 I/J：backtrace 帧的 function_name/filename，以及 class 表的 class_name。
- **实现**：value_root_frames_enabled 关闭或 visitor 未提供 visit_atom 时返回；当前源码该开关恒为 true。先遍历 backtrace_frames 的 function_name/filename，再遍历所有 class records 的 class_name。
- **所有权 / 错误 / 调用**：按值传递 atom id，不修改表、增加引用或释放 id；visitor 错误传播并终止后续扫描。

### `JSRuntime.traceStringCacheRoots` (`src/core/runtime.zig:2447`)

- **签名**：`fn traceStringCacheRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：把 Runtime 缓存中的字符串及 AtomTable 声明的根交给 visitor。
- **实现**：依次扫描 single-byte、percent-hex、small-int、empty、recent two-unit、recent atom 六类非空缓存，以字符串 JSValue 的副本调用 constValue，最后调用 `atoms.traceRoots`。
- **所有权 / 错误 / 调用**：constValue 的局部副本修改不会写回缓存；不清缓存、不分配字符串、不增减引用。遇到 visitor 错误立即传播。

### `JSRuntime.traceActiveRoots` (`src/core/runtime.zig:2465`)

- **签名**：`pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：扫描 Runtime 声明根及当前执行显式发布的活动根；收集器的 pin、保守栈扫描等其他根入口不由本函数涵盖。
- **实现**：当前 value_root_frames_enabled 恒为 true：先 `traceRoots(active_value_roots)`，再沿 TLS ActiveJobRoot 链扫描 runtime 相同的 job，然后扫描 active_invocation，最后调用已安装的 Atomics trace adapter。源码保留的关闭分支只调用 `traceRoots(null)`。
- **所有权 / 错误 / 调用**：active_invocation 必须以有效 ActiveInvocationTrace 头开头，adapter 自行实现同步与取根协议；本包装不加 mutex。任一步失败立即传播，不继续剩余入口。

### `JSRuntime.verifyDeferredClassPayloadRootLiveness` (`src/core/runtime.zig:2491`)

- **签名**：`pub fn verifyDeferredClassPayloadRootLiveness(self: *JSRuntime) gc.InvariantError!void`。
- **作用**：审计 deferred plugin payload 的临时根：每条边必须仍是活的、非 doomed 分配。映射块内指针不够——publisher 可能在 doomed 事务仍开时让释放 cell 可再分配。
- **实现**：构造只提供 value/object/header 回调的 Audit visitor，依次扫描 deferred_class_payload_roots 的 payload 边、排队 finalizer 及活动 finalizer；检查 containsHeader、finalizing，以及块内 cellAllocated/isDoomed。不提供 atom 回调，也不审计整个 Runtime 根集。
- **所有权 / 错误 / 调用**：收集器调用点以 `gc.invariantChecksEnabled` 控制是否执行，本函数内部没有该开关。首个 header 检查失败记在 audit.failure，但遍历继续；任一 trace 自身报错立即映射为 DeferredPayloadRootNotLive，否则遍历后返回记录的 NotLive 或 Doomed。只审计，不修复或保活对象。

### `JSRuntime.Audit.checkHeader` (`src/core/runtime.zig:2496`)

- **签名**：`fn checkHeader(audit: *@This(), header: *const gc.Header) void`。
- **作用**：一条 header 的活/doom 检查。
- **实现**：已有 failure 则返回；不在 GC 登记中报 NotLive，finalizing 报 Doomed。减去 metadata_prefix_size 定位 cell 地址；若属于 block，则无有效 cell index 或未分配报 NotLive，已分配但 doomed 报 Doomed；非 block 不执行 cell 检查。
- **所有权 / 错误 / 调用**：只记录第一次失败，不返回 error、不修改 header 或 GC 状态；不证明对象可达，仅检查这些存活条件。

### `JSRuntime.Audit.visitValue` (`src/core/runtime.zig:2520`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *JSValue) RootTraceError!void`。
- **作用**：值边 → checkHeader。
- **实现**：`cycleMarkHeader()` 非空则检查。
- **所有权 / 错误 / 调用**：没有 cycleMarkHeader 的值跳过；不改写槽，也不直接返回检查错误，失败保存在 audit.failure。

### `JSRuntime.Audit.visitObject` (`src/core/runtime.zig:2525`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*Object) RootTraceError!void`。
- **作用**：对象边。
- **实现**：有对象则 check 其 header。
- **所有权 / 错误 / 调用**：null 槽跳过；不改写对象槽，检查失败仅记录到 audit.failure。

### `JSRuntime.Audit.visitHeader` (`src/core/runtime.zig:2530`)

- **签名**：`fn visitHeader(context: *anyopaque, header: *const gc.Header) RootTraceError!void`。
- **作用**：直接 header 边。
- **实现**：checkHeader。
- **所有权 / 错误 / 调用**：不递归遍历 header 的子边，不直接抛出检查错误；失败记录到 audit.failure。

### `JSRuntime.traceValueRootFrameChain` (`src/core/runtime.zig:2558`)

- **签名**：`pub fn traceValueRootFrameChain( self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor, ) RootTraceError!void`。
- **作用**：公开名的帧链扫描。
- **实现**：`traceValueRootFrames`。
- **所有权 / 错误 / 调用**：收集器也使用该入口；只扫描显式传入的链，不包含 Runtime 的其他根，不激活或撤销帧。错误原样传播。

### `JSRuntime.traceValueRootFrames` (`src/core/runtime.zig:2566`)

- **签名**：`fn traceValueRootFrames(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void`。
- **作用**：沿 previous 走：objects、headers、values、atoms（single 与 list 现长）、slices 五臂（mutable/borrowed/windowed/cells/borrowed_cells）。
- **实现**：每帧按 objects、headers、values、atoms、slices 的顺序扫描再走 previous；headers/atoms 受 value_root_frames_enabled 控制，atoms 还要求 visit_atom 存在。mutable、atom list 和 cells 扫描时读取切片头；windowed 从底层指针扫描到当时的 live_len，不以切片 len 截断。self 未使用。
- **所有权 / 错误 / 调用**：调用方保证链无环、借用描述符有效、windowed 的存储已初始化且容量足够。mutable 值槽允许 visitor 写回；borrowed 值及两种 cell 分支均传值副本，修改不写回 VarRef。错误立即传播，不回滚已执行回调。

---

## 句柄槽、弱身份、WeakRef [[KeptAlive]]

### `JSRuntime.createPersistentRootSlot` (`src/core/runtime.zig:2611`)

- **签名**：`fn createPersistentRootSlot(self: *JSRuntime, value: JSValue) !*RootSlot`。
- **作用**：persistent 数组上新建槽。
- **实现**：`createRootSlot(..., persistent_*)`。
- **所有权 / 错误 / 调用**：JSValueHandle.init 使用；分配独立槽并登记强根，值本身不深拷贝。错误由 createRootSlot 传播；此包装不检查 owner 线程。

### `JSRuntime.createLocalRootSlot` (`src/core/runtime.zig:2615`)

- **签名**：`fn createLocalRootSlot(self: *JSRuntime, value: JSValue) !*RootSlot`。
- **作用**：local 数组上新建槽。
- **实现**：`createRootSlot(..., local_*)`。
- **所有权 / 错误 / 调用**：HandleScope.local 使用；槽由 scope 的水位清理协议管理，本函数不检查是否存在活动 scope，也不检查 owner 线程。分配错误传播。

### `JSRuntime.createWeakRootSlot` (`src/core/runtime.zig:2619`)

- **签名**：`fn createWeakRootSlot( self: *JSRuntime, identity: usize, callback: ?WeakPersistentCallback, callback_context: ?*anyopaque, ) !*WeakRootSlot`。
- **作用**：分配保存 identity、callback 和 callback_context 的弱槽，并追加到 weak_root_slots。
- **实现**：保存并暂时清空 memory.trigger_gc_fn/ctx；创建槽并初始化，再追加槽指针。追加失败销毁新槽；无论成功失败都恢复原 trigger 两字段。
- **所有权 / 错误 / 调用**：WeakPersistentValue.init 使用；本函数不 retain identity、不检查目标存活、不执行 callback。callback_context 为借用；只暂停该账户的分配触发回调，不是全局禁止 GC 或并发互斥。

### `JSRuntime.createRootSlot` (`src/core/runtime.zig:2645`)

- **签名**：`fn createRootSlot(self: *JSRuntime, value: JSValue, slots: *[]*RootSlot, capacity: *usize) !*RootSlot`。
- **作用**：分配独立 RootSlot，并登记到调用方指定的槽数组。
- **实现**：保存并暂时清空账户 trigger_gc_fn/ctx，创建 value 为 undefined 的槽，成功追加指针后才写入传入值；创建或追加失败时恢复 trigger，追加失败另销毁新槽。
- **所有权 / 错误 / 调用**：用于 local/persistent 强根；失败不消费、销毁或自动保护传入 JSValue。成功后由对应槽生命周期负责撤根及释放槽存储，不是深拷贝堆值。

### `JSRuntime.destroyWeakRootSlot` (`src/core/runtime.zig:2663`)

- **签名**：`fn destroyWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot) void`。
- **作用**：从表移除、清身份（不回调）、destroy 槽。
- **实现**：先 removeWeakRootSlot，再 clearWeakRootSlot(slot, false)，随后将槽重置为空结构并归还槽存储。
- **所有权 / 错误 / 调用**：WeakPersistentValue.deinit 使用；目标已死、identity 已空的槽仍须销毁。不会通知 callback；槽指针及其所有副本随之失效，不允许重复销毁。

### `JSRuntime.removeWeakRootSlot` (`src/core/runtime.zig:2670`)

- **签名**：`fn removeWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot) void`。
- **作用**：指针相等从数组摘下；空则 free backing。
- **实现**：线性查找相同槽指针，找不到走 unreachable；向前移动后续指针保留顺序，缩短有效长度；变空时先清数组和容量再释放全部 backing。
- **所有权 / 错误 / 调用**：只撤销登记，不清 identity、不通知 callback、不释放槽本身。非空时保留容量；调用方必须提供本 Runtime 中已登记的槽。

### `JSRuntime.takePersistentRootSlot` (`src/core/runtime.zig:2691`)

- **签名**：`fn takePersistentRootSlot(self: *JSRuntime, slot: *RootSlot) JSValue`。
- **作用**：摘 persistent 槽并返回其中的值。
- **实现**：remove，读 value，槽写 undefined，destroy 槽。
- **所有权 / 错误 / 调用**：Handle deinit/take 使用；返回值已失去该持久根的保护，需由调用方的其他根或可追踪边承接。释放的是 RootSlot，不是返回值所指的堆对象；旧槽指针失效。

### `JSRuntime.removePersistentRootSlot` (`src/core/runtime.zig:2699`)

- **签名**：`fn removePersistentRootSlot(self: *JSRuntime, slot: *RootSlot) void`。
- **作用**：从 persistent 数组摘指针。
- **实现**：按槽指针线性找首个匹配，缺失走 unreachable；向前搬移后续指针并缩短切片，保持顺序。仅当变空时重置数组/容量并释放 backing。
- **所有权 / 错误 / 调用**：takePersistentRootSlot 使用；此步骤不清值、不释放槽，槽中值不再由 persistent 数组扫描。重复删除或跨 Runtime 删除违反前提。

### `JSRuntime.assertNoOutstandingValueHandles` (`src/core/runtime.zig:2723`)

- **签名**：`fn assertNoOutstandingValueHandles(self: *const JSRuntime) void`。
- **作用**：拒绝销毁仍有公共句柄的runtime。
- **实现**：local/persistent/weak三根槽数组任一非空即显式panic。
- **所有权 / 错误 / 调用**：即使弱目标已死亡，未销毁的弱槽仍算未结束句柄。检查不清理句柄，ReleaseFast也保留显式panic；不检查全部可能的RootProvider或NativePin。

### `JSRuntime.assertIdleForTeardown` (`src/core/runtime.zig:2735`)

- **签名**：`fn assertIdleForTeardown(self: *const JSRuntime) void`。
- **作用**：拒绝在执行或栈根仍活跃时拆runtime。
- **实现**：扫描TLS活动Job根是否属于self，并检查call/native深度、活字节码栈字节、活回溯、native call/invocation/value roots和错误栈格式化标志；任一成立panic。
- **所有权 / 错误 / 调用**：不要求所有runtime的TLS Job链为空，只拒self关联。未创建槽的空HandleScope没有登记在此，因此不是所有借用对象的通用存活证明。显式panic在各优化模式保留。

### `JSRuntime.clearWeakRootSlot` (`src/core/runtime.zig:2757`)

- **签名**：`pub fn clearWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot, notify: bool) void`。
- **作用**：丢掉身份；可选跑 callback。
- **实现**：identity 为空直接返回；否则先 clearWeakIdentitySlot，将身份置 null 并释放身份记账，再在 notify=true 且 callback 存在时同步调用 callback(rt, callback_context)。
- **所有权 / 错误 / 调用**：不摘槽、不释放槽、不清 callback 字段。同一身份清空后重复调用不会再通知；回调看到的槽身份已经为空。显式销毁弱句柄使用 notify=false。

### `JSRuntime.sweepDeadWeakPersistentSlots` (`src/core/runtime.zig:2765`)

- **签名**：`pub fn sweepDeadWeakPersistentSlots(self: *JSRuntime, live_context: anytype) void`。
- **作用**：按收集器提供的 `isWeakIdentityAlive` 清死弱持久槽并回调。
- **实现**：直接遍历 weak_root_slots，跳过空 identity；live_context.isWeakIdentityAlive 返回 false 时 clearWeakRootSlot(slot, true)。
- **所有权 / 错误 / 调用**：依赖调用方提供的存活判定，不自行检查标记位；清空目标不会删除句柄槽。通知在遍历中同步执行，没有队列或数组快照，不能据此推断回调任意增删弱槽也安全。

### `JSRuntime.clearWeakPersistentIdentity` (`src/core/runtime.zig:2774`)

- **签名**：`pub fn clearWeakPersistentIdentity(self: *JSRuntime, identity: usize, notify: bool) void`。
- **作用**：清所有指向该身份的弱持久槽。
- **实现**：直接遍历 weak_root_slots，跳过空身份；每个 identity 相等的槽都调用 clearWeakRootSlot，转发 notify。
- **所有权 / 错误 / 调用**：不自行判定该身份是否死亡，也不从对象身份映射删除目标；只清匹配槽。通知为遍历中的同步调用，没有为回调增删槽提供快照保护。

### `JSRuntime.keepAliveWeakRefTarget` (`src/core/runtime.zig:2783`)

- **签名**：`pub fn keepAliveWeakRefTarget(self: *JSRuntime, value: JSValue) void`。
- **作用**：将传入值追加到 Runtime 的 WeakRef 保活集合，由根扫描保持其可达；本函数不验证值是否为合法 WeakRef 目标。
- **实现**：容量从 4 起倍增；扩容失败直接返回，原集合不变。成功时复制旧值、切换 backing 并释放旧数组，再追加值；不去重。
- **所有权 / 错误 / 调用**：当前实现没有 RC 模式的空操作分支。返回类型为 void，调用方无法通过返回值区分追加成功或分配失败；失败时没有建立新的保活条目。集合由 job 边界清理，不在任意 safepoint 清除。

### `JSRuntime.clearWeakRefKeptAlive` (`src/core/runtime.zig:2800`)

- **签名**：`pub fn clearWeakRefKeptAlive(self: *JSRuntime) void`。
- **作用**：job 结束清 [[KeptAlive]]。
- **实现**：保存旧切片与容量，先将集合重置为空、容量归零，再按旧容量释放 backing；没有逐值析构。
- **所有权 / 错误 / 调用**：exec job 边界及 Runtime.deinit 使用；不检查当前是否确实到 job 末尾，调用时机由上层保证。不直接销毁目标，只撤销该集合提供的保活边。

### `JSRuntime.retainWeakIdentity` (`src/core/runtime.zig:2813`)

- **签名**：`pub fn retainWeakIdentity(self: *JSRuntime, identity: usize) void`。
- **作用**：TGC S4-e：对象身份不计数；只有符号身份走 `atoms.retainSymbolWeakRef`。
- **实现**：偶数身份直接返回；奇数取 identity >> 1，超出 Atom 整数范围也返回，否则调用 atoms.retainSymbolWeakRef。
- **所有权 / 错误 / 调用**：维护符号 atom 条目的弱引用记账，不建立目标强根；对象身份不增加计数或验证映射。WeakPersistentValue.init 等调用方负责与 release 配对。

### `JSRuntime.releaseWeakIdentity` (`src/core/runtime.zig:2822`)

- **签名**：`pub fn releaseWeakIdentity(self: *JSRuntime, identity: usize) void`。
- **作用**：对象身份 no-op；符号 `releaseSymbolWeakRef`。
- **实现**：偶数直接返回；奇数解码 atom id，超出 Atom 范围则返回，否则调用 atoms.releaseSymbolWeakRef。
- **所有权 / 错误 / 调用**：不从对象身份映射删除对象，也不清调用方保存的 identity。符号条目的弱引用计数及回收由 AtomTable 处理。

### `JSRuntime.clearWeakIdentitySlot` (`src/core/runtime.zig:2829`)

- **签名**：`pub fn clearWeakIdentitySlot(self: *JSRuntime, slot: *?usize) void`。
- **作用**：取出身份、置 null、release。
- **实现**：空槽直接返回；先取出身份并将槽置 null，再调用 releaseWeakIdentity。
- **所有权 / 错误 / 调用**：弱槽与弱集合条目使用；重复清空可无操作。本函数不释放槽存储、不通知弱回调，也不直接撤销对象身份映射。

### `JSRuntime.weakIdentityIsCurrentlyLive` (`src/core/runtime.zig:2835`)

- **签名**：`fn weakIdentityIsCurrentlyLive(self: *JSRuntime, identity: usize) bool`。
- **作用**：符号看 atom kind；对象看 id 表。
- **实现**：奇数解码的 atom id 超范围则 false，否则只检查 atoms.kind == .symbol；偶数检查 liveObjectFromWeakIdentity 是否非空。
- **所有权 / 错误 / 调用**：WeakPersistentValue.isAlive 使用；符号分支没有检查 body 是否存在，故不能将 true 等同于 valueFromWeakIdentity 必定返回符号。查询不保活目标。

### `JSRuntime.valueFromWeakIdentity` (`src/core/runtime.zig:2844`)

- **签名**：`fn valueFromWeakIdentity(self: *JSRuntime, identity: usize) JSValue`。
- **作用**：身份仍活则物化 JSValue，否则 undefined。
- **实现**：奇数解码超范围或 atom kind 非 symbol 时返回 undefined，否则调用 symbolValueIfLive，body 不存活时也返回 undefined；偶数通过映射得到对象再返回 object.value()，未命中则 undefined。
- **所有权 / 错误 / 调用**：WeakPersistentValue.get 使用；不创建缺失的符号 body、不登记强根或加入 WeakRef 保活集合，返回的是当前可取得值的副本。

### `JSRuntime.liveObjectFromWeakIdentity` (`src/core/runtime.zig:2865`)

- **签名**：`pub fn liveObjectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object`。
- **作用**：通过弱身份映射取得对象；当前生命周期协议由对象销毁时撤销映射，不再保留已清空资源的弱对象外壳。
- **实现**：`objectFromWeakIdentity`。
- **所有权 / 错误 / 调用**：返回借用对象指针，不增加强根；依赖销毁时及时撤销映射的不变量，本函数不额外检查 GC 标记、finalizing 或 condemned 状态。

### `JSRuntime.objectFromWeakIdentity` (`src/core/runtime.zig:2869`)

- **签名**：`fn objectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object`。
- **作用**：查 `weak_id_objects`。
- **实现**：奇数 null；`get(identity >> 1)`。
- **所有权 / 错误 / 调用**：不将偶数 identity 当作地址解引用，只查询解码 id 对应的 map；未命中返回 null。哈希查找不是对任意输入作最坏情况常数时间保证。

### `JSRuntime.registerWeakObjectIdentity` (`src/core/runtime.zig:2876`)

- **签名**：`pub fn registerWeakObjectIdentity(self: *JSRuntime, object: *Object) !usize`。
- **作用**：返回编码身份 `weak_id<<1`；首次为对象分配单调递增 id。
- **实现**：以 GC header 地址清低位作为地址表的键；已有 has_weak_id 时查表返回编码 id，flag 与表不一致走 unreachable。首次登记依次写地址→id、id→对象两表；第二次写入失败删除第一条映射。两表成功后才递增 next_weak_id、置 flag、markNeedsFinalizer 并返回 id << 1。
- **所有权 / 错误 / 调用**：可能分配失败；回滚映射不代表回退 map 已扩大的容量。不建立对象强根；finalizer 标记确保销毁流程能交回身份。没有 id 耗尽的可恢复错误或回绕重用协议，不应描述为无限唯一 id 分配器。

### `JSRuntime.peekWeakObjectIdentity` (`src/core/runtime.zig:2907`)

- **签名**：`pub fn peekWeakObjectIdentity(self: *const JSRuntime, object: *const Object) ?usize`。
- **作用**：已登记则返回编码身份，不创建。
- **实现**：无 flag 或表 miss → null。
- **所有权 / 错误 / 调用**：不分配、不修改 flag、不验证反向映射、不保持对象存活；要求传入仍有效的对象指针。

### `JSRuntime.takeWeakObjectIdentity` (`src/core/runtime.zig:2916`)

- **签名**：`pub fn takeWeakObjectIdentity(self: *JSRuntime, object: *Object) ?usize`。
- **作用**：对象销毁时从表摘下身份，供传播到弱槽。
- **实现**：无 flag 返回 null；有 flag 时先清 flag，再按地址查 id。查不到返回 null；查到后删除双向映射并返回 id << 1。
- **所有权 / 错误 / 调用**：销毁流程随后可用返回值传播弱目标死亡；本函数不清弱槽或触发回调，不释放对象、不递减 next_weak_id，也不清 needs-finalizer 标记。

### `JSRuntime.clearLocalRootSlotsFrom` (`src/core/runtime.zig:2926`)

- **签名**：`fn clearLocalRootSlotsFrom(self: *JSRuntime, start: usize) void`。
- **作用**：HandleScope 退出：从末尾 destroy 到 start。
- **实现**：断言 start 不大于当前长度，逆序将 [start,len) 各槽值置 undefined 并释放槽；再截短数组。结果为空时重置数组/容量并释放 backing，否则保留容量。
- **所有权 / 错误 / 调用**：HandleScope.deinit 使用；对应 LocalHandle 随槽释放失效，不逐个销毁 JS 堆值。start 只是水位，没有验证 scope 身份或完整 LIFO 顺序。

### `JSRuntime.enterHandleScope` (`src/core/runtime.zig:2944`)

- **签名**：`pub fn enterHandleScope(self: *JSRuntime) HandleScope`。
- **作用**：Runtime 方法包装 `HandleScope.enter`。
- **实现**：直接返回 HandleScope.enter(self)，保存当前 local_root_slots 长度作为退出水位。
- **所有权 / 错误 / 调用**：不分配根槽、不复制已有值，也不把 scope 对象登记进独立活动链；调用方须让 scope 地址和 Runtime 生命周期满足使用要求，并按嵌套顺序退出。

### `JSRuntime.localRootCountForTest` (`src/core/runtime.zig:2948`)

- **签名**：`pub fn localRootCountForTest(self: JSRuntime) usize`。
- **作用**：测试观察 local 槽数。
- **实现**：非 test 编译错误。
- **所有权 / 错误 / 调用**：只读 `local_root_slots.len`，不分配、不改根表、无 error set；`self: JSRuntime` 按值声明（Zig 对这么大的结构实际按 const 指针传）。非 test 构建是 `@compileError`，所以它不在生产二进制里。调用方全是单测：`src/tests/engine_production.zig:451`、`:459`、`:685` 等 5 处，以及 `src/tests/core.zig:10334` 等 4 处，共 9 处。

### `JSRuntime.weakRootCountForTest` (`src/core/runtime.zig:2953`)

- **签名**：`pub fn weakRootCountForTest(self: JSRuntime) usize`。
- **作用**：弱槽数。
- **实现**：test-only。
- **所有权 / 错误 / 调用**：同族：只读 `weak_root_slots.len`，不分配、无 error set，非 test 构建 `@compileError`。唯一调用方 `src/tests/core.zig:10428`。注意它数的是**槽位数**，被清空的弱槽是否还占位由 `WeakPersistent` 的回收策略决定，不等同于存活弱引用数。

### `JSRuntime.persistentRootCountForTest` (`src/core/runtime.zig:2958`)

- **签名**：`pub fn persistentRootCountForTest(self: JSRuntime) usize`。
- **作用**：persistent 槽数。
- **实现**：test-only。
- **所有权 / 错误 / 调用**：同族：只读 `persistent_root_slots.len`，不分配、无 error set，非 test 构建 `@compileError`。调用方散布在各处单测，如 `src/core/runtime.zig:4870`（本文件的根表测试）、`src/binding/binding.zig:905`（binding 的 persistent 泄漏断言）、`src/root.zig:973`、`src/tests/engine_production.zig:452`、`src/tests/core.zig:10335` 等。

---

## 符号、句柄工厂、NativeEntry

### `JSRuntime.symbolValue` (`src/core/runtime.zig:2963`)

- **签名**：`pub fn symbolValue(self: *JSRuntime, atom_id: atom.Atom) !JSValue`。
- **作用**：从 atom 物化符号值（可共享）。
- **实现**：转发 atoms.symbolValue(self, atom_id)，确保对应 symbol body 存在，再返回引用该 body 的 JSValue。
- **所有权 / 错误 / 调用**：可能分配失败；不是任意 atom 到符号的无条件转换，合法性由 AtomTable 检查。返回值不自动登记强根，也不复制已有 symbol body。

### `JSRuntime.takeSymbolValue` (`src/core/runtime.zig:2967`)

- **签名**：`pub fn takeSymbolValue(self: *JSRuntime, atom_id: atom.Atom) !JSValue`。
- **作用**：为符号创建路径取得 JSValue；当前不具有“独占 body”语义。
- **实现**：转发 atoms.takeSymbolValue；当前与 symbolValue 一样，确保 body 存在并返回对应符号值。
- **所有权 / 错误 / 调用**：名字保留调用意图，但不摘除 atom 条目、不转移独占 body、不减少旧式 ID 引用计数。错误传播，返回值需由调用方保持可达。

### `JSRuntime.newSymbolValue` (`src/core/runtime.zig:2971`)

- **签名**：`pub fn newSymbolValue(self: *JSRuntime, description: ?[]const u8) !JSValue`。
- **作用**：从可选描述字节创建新的非注册符号；不是 JavaScript 参数转换入口。
- **实现**：description 非 null 时调用 newValueSymbol，否则 newValueSymbolNoDescription，再调用 takeSymbolValue。
- **所有权 / 错误 / 调用**：null 与空字节描述不同；相同描述仍创建不同身份。任一步错误传播；本包装没有在第二步失败时显式撤销第一步 atom 创建的回滚逻辑，不应承诺整个操作无副作用失败。

### `JSRuntime.globalSymbolValue` (`src/core/runtime.zig:2979`)

- **签名**：`pub fn globalSymbolValue(self: *JSRuntime, key: []const u8) !JSValue`。
- **作用**：`Symbol.for(key)`。
- **实现**：`internRegisteredValueSymbol` + `symbolValue`。
- **所有权 / 错误 / 调用**：注册表属于当前 Runtime 的 AtomTable，同一 Runtime 内相同 key 复用注册身份，不是跨 Runtime 共享表。参数已经是字节串；注册或 body 物化错误传播，本包装不回滚已成功登记的 key。

### `JSRuntime.createValueHandle` (`src/core/runtime.zig:2984`)

- **签名**：`pub fn createValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle`。
- **作用**：创建保存该值的持久强根句柄。
- **实现**：调用 JSValueHandle.initDup；当前 initDup 直接调用 init，两者创建槽的行为相同。
- **所有权 / 错误 / 调用**：复制的是 JSValue，不深拷贝对象或增加旧式 RC。分配错误传播；成功句柄须在 Runtime 销毁前 deinit，普通结构体复制不产生独立槽。

### `JSRuntime.takeValueHandle` (`src/core/runtime.zig:2988`)

- **签名**：`pub fn takeValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle`。
- **作用**：以 take 命名提供持久强根句柄工厂。
- **实现**：调用 JSValueHandle.init，新建独立 RootSlot 存储传入值；当前与 createValueHandle 的槽创建行为相同。
- **所有权 / 错误 / 调用**：参数按值传入，不清空调用方变量；失败不销毁传入值，成功不意味着对象只能由此句柄引用。调用方负责句柄关闭及值的可达性。

### `JSRuntime.createPersistentValue` (`src/core/runtime.zig:2992`)

- **签名**：`pub fn createPersistentValue(self: *JSRuntime, value: JSValue) !JSValueHandle`。
- **作用**：`createValueHandle` 别名。
- **实现**：转发。
- **所有权 / 错误 / 调用**：沿用 createValueHandle 的分配错误与关闭协议，不额外创建第二个槽或复制目标对象。

### `JSRuntime.createWeakPersistentValue` (`src/core/runtime.zig:2996`)

- **签名**：`pub fn createWeakPersistentValue( self: *JSRuntime, value: JSValue, callback: ?WeakPersistentCallback, callback_context: ?*anyopaque, ) !WeakPersistentValue`。
- **作用**：创建带可选死亡通知的弱持久句柄，不建立目标强根。
- **实现**：将 value、callback、callback_context 原样传给 WeakPersistentValue.init，由其取得弱身份、维护身份记账并创建弱槽。
- **所有权 / 错误 / 调用**：InvalidWeakTarget 或分配错误传播；弱目标接受规则由底层身份转换决定，不能直接等同于语言级 CanBeHeldWeakly。callback_context 为借用，槽仍须显式关闭，目标死亡不会自动释放句柄。

### `JSRuntime.allocNativeEntry` (`src/core/runtime.zig:3007`)

- **签名**：`pub fn allocNativeEntry(self: *JSRuntime, template: native_entry.NativeEntry) !*const native_entry.NativeEntry`。
- **作用**：为宿主 NativeEntry 模板分配地址稳定的独立记录，并纳入 Runtime 清理数组。
- **实现**：create 后按值复制 template，再追加记录指针到 native_entries；追加失败通过 errdefer 释放新记录。
- **所有权 / 错误 / 调用**：模板内指针不会深拷贝，不自动登记 state finalizer。返回 const 指针，但 retireNativeEntry 会内部修改 kind；记录在 clearExternalHostFunctions 时释放，调用方不得提前释放或在清理后继续引用。

### `JSRuntime.registerNativeEntryFinalizer` (`src/core/runtime.zig:3015`)

- **签名**：`pub fn registerNativeEntryFinalizer(self: *JSRuntime, ptr: *anyopaque, finalize: *const fn (*anyopaque) void) !void`。
- **作用**：登记 entry `state` 指针的 teardown 回调。
- **实现**：将 ptr/finalize 对追加到 native_entry_finalizers，不去重、不关联或验证某个 NativeEntry。
- **所有权 / 错误 / 调用**：追加可能失败，失败时不执行 finalize。登记本身不检查线程，也不接管 ptr 的存储类型；调用方保证它在清理回调前有效，并避免重复登记导致重复释放。执行时机由 clearExternalHostFunctions 和延迟清理流程决定。

### `JSRuntime.retireNativeEntry` (`src/core/runtime.zig:3021`)

- **签名**：`pub fn retireNativeEntry(self: *JSRuntime, entry: *const native_entry.NativeEntry) void`。
- **作用**：原地 tombstone：仍持有函数对象的调用得 TypeError；不释放。
- **实现**：constCast 后将 kind 设为 retired，并使 native_entry_epoch 环绕加一。重复调用仍递增 epoch；本函数不直接抛出 TypeError，错误由后续调用分发处理。
- **所有权 / 错误 / 调用**：不释放 entry 或 state、不执行 finalizer、不验证 entry 是否属于 self；要求传入仍有效且底层可写的记录。

### `JSRuntime.internalBuiltinRecord` (`src/core/runtime.zig:3032`)

- **签名**：`pub fn internalBuiltinRecord(self: *const JSRuntime, domain_index: usize, id: u32) ?*const native_entry.NativeEntry`。
- **作用**：按 domain 和域内 id 查询内部 builtin 记录，不使用字符串或哈希查找。
- **实现**：domain 越界返回 null，否则调用 EntryTable.get：id 在 dense 范围内时直接索引，retired 项返回 null；超出 dense 范围则线性查找 sparse 的同 id 项，未命中返回 null。不能概括为固定两次数组读取。
- **所有权 / 错误 / 调用**：exec 分发使用；返回借用指针，不创建记录或保活其外部状态。dense 分支过滤 retired，sparse 命中直接返回记录；空表返回 null。表内容由标准全局安装流程建立。

### `JSRuntime.clearExternalHostFunctions` (`src/core/runtime.zig:3037`)

- **签名**：`pub fn clearExternalHostFunctions(self: *JSRuntime) void`。
- **作用**：teardown：entry state finalizer 进延迟清理（enqueue 失败则同步跑），destroy 每个 NativeEntry。
- **实现**：先取出并清空 finalizer 数组，每项尝试入延迟清理队列，失败则当场调用 finalize；释放该数组 backing。随后取出并清空 native_entries，逐个释放记录，再释放其 backing。
- **所有权 / 错误 / 调用**：Runtime.deinit 使用；队列中的回调可能在 entry 存储释放后执行，因此回调所需 state 必须独立有效。本函数不先逐项 retire、不递增 epoch，也不保证返回时所有 state finalizer 已执行。同步回调新登记的 finalizer 不在已取出的旧数组中。

---

## 收集：STW major、pollGC、增量标记、销毁切片

### `JSRuntime.runObjectCycleRemoval` (`src/core/runtime.zig:3055`)

- **签名**：`pub fn runObjectCycleRemoval(self: *JSRuntime) usize`。
- **作用**：请求一次显式全堆收集，返回底层结果的 freed_objects，不等于保证所有不可达资源已释放。
- **实现**：显式检查 owner 线程，调用 runObjectCycleRemovalWithValueRoots(null)，不提供额外帧链。
- **所有权 / 错误 / 调用**：底层失败被转换为 0；0 也可能表示跳过收集或没有释放对象，不能用它判定收集成功。现有 Runtime 根仍参与扫描。

### `JSRuntime.runObjectCycleRemovalWithValueRoots` (`src/core/runtime.zig:3060`)

- **签名**：`pub fn runObjectCycleRemovalWithValueRoots(self: *JSRuntime, roots: ?*const ValueRootFrame) usize`。
- **作用**：带额外帧链的显式全堆收集入口，向底层传入 declared_only 扫描策略。
- **实现**：`tryRun...(.declared_only) catch 0`，返回 `freed_objects`。
- **所有权 / 错误 / 调用**：显式检查 owner 线程。生产收集器另以 scheduler.host_quiescent 决定是否保守扫描，故 declared_only 本身不保证只扫描精确根；调用方仍须满足根和执行边界契约。错误被吞为 0，不表示成功。

### `JSRuntime.tryRunObjectCycleRemoval` (`src/core/runtime.zig:3070`)

- **签名**：`pub fn tryRunObjectCycleRemoval(self: *JSRuntime) gc.CollectionError!gc.CollectionResult`。
- **作用**：可失败的显式收集。
- **实现**：roots=null，`.declared_only`。
- **所有权 / 错误 / 调用**：传播 OutOfMemory / PayloadMarkFailed；底层拒绝重入时仍可能成功返回空结果，因此无错误不证明实际完成了一轮收集。错线程由底层显式 panic，不属于返回错误集。

### `JSRuntime.tryRunObjectCycleRemovalWithValueRoots` (`src/core/runtime.zig:3074`)

- **签名**：`pub fn tryRunObjectCycleRemovalWithValueRoots( self: *JSRuntime, roots: ?*const ValueRootFrame, scan: GCRootScan, ) gc.CollectionError!gc.CollectionResult`。
- **作用**：在允许收集的边界启动新的 STW major，而非简单完成现有增量标记周期。
- **实现**：检查 owner；活动 deferred payload finalizer 存在时直接返回空结果，否则先排空可安全执行的延迟 finalizer。非 gc_running 时完成 pending 销毁并结算，再中止增量标记。若仍 gc_running 或 GC phase 非 none 则返回空结果。通过检查后设置运行标志、采样账户峰值、开始 major 并调用 collectCycles(self, roots, scan)。成功记录 freed_objects 与扣除 census 时间后的非负时长，结束调度周期、重设阈值并尝试释放空闲块页。
- **所有权 / 错误 / 调用**：收集失败记录错误、中止调度周期并请求 collection_failed/soon 后返回错误；不回滚此前已完成的延迟清理或销毁。提前返回不会自行登记新的收集请求。返回统计只对应这次 collectCycles，不汇总前置销毁及页释放；gc_running 通过 defer 恢复。扫描策略仍受生产收集器的 host_quiescent 条件影响。

### `JSRuntime.pollGC` (`src/core/runtime.zig:3155`)

- **签名**：`pub fn pollGC( self: *JSRuntime, roots: ?*const ValueRootFrame, mode: GCPollMode, ) gc.CollectionError!gc.CollectionResult`。
- **作用**：调度器入口：销毁切片、增量标记、可选 minor、再决定是否开 major。
- **实现**：
  1. active deferred finalizer → 空。先 drain payload finalizer。
  2. morgue.pending 且非 gc_running、phase 为 none：urgent 一次 finish 并结算后继续；否则返回 `destroySlicePoll`。
  3. incremental marking 且非 gc_running、phase 为 none：urgent 则 abort 周期并继续；否则返回 `incrementalMarkPoll(roots, mode)`。
  4. 阈值跨越 = `allocated_bytes > threshold` **或** pending allocation_threshold 请求（多数跨越在分配边界记下，poll 时账户还差这一笔）。
  5. minor：跨越时要求 pollScansConservatively 且 shouldTryMinorBeforeMajor；否则要求 acceptsMinor 且 shouldTryMinor。非 gc_running 时尝试 collectMinor(self, roots, mode.rootScan())，错误按 null 处理并继续。成功即记 minor 次数、停顿并尝试释放空闲页；freed>0 才记释放统计。跨越时重读账户，已不超阈值便清陈旧 threshold 请求，且无其他 major 请求才返回 minor 结果；仍超则继续。未跨越时 freed>0 直接返回，否则继续。
  6. 若正在 GC 或 phase 非 none，返回空结果；否则映射 scheduler point，normal/idle/urgent 还检查进程内存压力。调度器拒绝 major 时返回空结果。允许时取出并清除 pending major request；无请求，或请求原因为 allocation_threshold 且非 urgent，视作自主节奏收集。
  7. 非 urgent 的自主节奏路径启动增量周期，记录 begin 切片并返回空结果；其他路径启动 STW major。两条新 major 路径传给底层的额外 roots 都是 null，而不是本函数参数 roots。
- **所有权 / 错误 / 调用**：显式检查 owner；minor 不重设 major 阈值。启动增量失败会中止周期、记录错误并请求重试。单次 poll 可先做 minor 再走 major，但返回值不汇总各阶段释放数和时长；返回空结果也可能已做工作。额外 roots 仅在直接传给 minor 或已有增量周期的分支中使用，调用方不能依赖它在所有分支自动成为根。

### `JSRuntime.incrementalMarkPoll` (`src/core/runtime.zig:3422`)

- **签名**：`fn incrementalMarkPoll( self: *JSRuntime, roots: ?*const ValueRootFrame, mode: GCPollMode, ) gc.CollectionError!gc.CollectionResult`。
- **作用**：推进已开始的增量标记；frontier 清空后执行最终 remark 与待销毁对象登记，必要时同一调用完成销毁。
- **实现**：设置 gc_running 并先执行一个 incremental_mark_budget_ns 标记步骤。forced 条件是 allocated_bytes 严格大于 threshold + (threshold >> 1)，加法溢出按 usize 最大值处理。forced 且首步未清空 frontier 时递增 forced_finishes，并以最大预算循环到清空。frontier 未空则记录 increment 停顿并返回空结果；已空则 finishIncrementalCycle(self, roots, mode.rootScan())，forced 时立即完成 pending 销毁。若 morgue 已空则结算返回，否则按扣除待销毁字节的账户重设阈值并返回空结果。
- **所有权 / 错误 / 调用**：步骤或 finish 失败时中止增量周期、记录错误并请求 collection_failed/soon。所有退出都恢复 gc_running、刷新 assist 账户基准并饱和扣除一个 assist interval。完成标记的最后一次停顿作为一个样本，另按 increment/finish 分摊耗时并扣除 census；forced_finishes 不统计“首步已清空、随后强制销毁”的情况。预算不是整次调用的硬耗时上限，最终 remark 或强制完成可越过普通切片预算。

### `JSRuntime.resetGCThresholdExcludingDoomed` (`src/core/runtime.zig:3543`)

- **签名**：`fn resetGCThresholdExcludingDoomed(self: *JSRuntime) void`。
- **作用**：在待销毁对象尚占账户空间时，按预计扣除这些字节后的账户计算下一阈值。
- **实现**：settled = allocated_bytes -| morgue.bytes，饱和减法避免下溢；暂时将账户改为 settled，调用 resetGCThreshold 后恢复原 allocated_bytes。
- **所有权 / 错误 / 调用**：没有实际释放字节，也不把 allocated_bytes 当作精确可达活字节。只恢复这个账户字段，resetGCThreshold 对阈值、债务等状态的修改仍保留；销毁完成后再按实际账户重算。此流程依赖 Runtime 的单线程执行前提。

### `JSRuntime.destroySlicePoll` (`src/core/runtime.zig:3555`)

- **签名**：`fn destroySlicePoll(self: *JSRuntime) gc.CollectionError!gc.CollectionResult`。
- **作用**：推进一次带预算的待销毁对象清理；最后一片完成后交付周期结果。
- **实现**：设置 gc_running，生产预算使用 incremental_mark_budget_ns（当前 1 毫秒）。调用 destroyDoomedSlice，按前后账户记录 assist reclaim，记录非负 destroy 切片时长；morgue 未空返回空结果，已空则 finishDoomedCompletion(slice)。
- **所有权 / 错误 / 调用**：退出时恢复 gc_running、刷新 assist 账户并消费销毁辅助债务。忽略底层当片返回的释放数量，由累计 morgue.destroyed 在结束时结算。函数签名保留 CollectionError，但当前函数体没有返回该错误的路径；预算由底层在工作边界检查，不是可抢占的硬实时限制。

### `JSRuntime.finishDoomedCompletion` (`src/core/runtime.zig:3580`)

- **签名**：`fn finishDoomedCompletion(self: *JSRuntime, last_slice_ns: u64) gc.CollectionResult`。
- **作用**：morgue 空：交付 CollectionResult、reset 阈值、decommit 空闲页。
- **实现**：断言 morgue 不再 pending 并调用 auditDoomedExitInvariant；结果取累计 morgue.destroyed 和传入 last_slice_ns。随后清零 destroyed、清 assist credit、记录增量周期成功、重设阈值并尝试释放空闲块页。
- **所有权 / 错误 / 调用**：freed_objects 是整个待销毁批次累计数，duration_ns 却只是调用方传入的最后一片时长，并非周期总耗时；显式完成路径可能传 0。页释放发生在结果构造后，不计入该时长。本函数自身不执行剩余对象销毁，调用前必须已完成。

### `JSRuntime.pollGCChecked` (`src/core/runtime.zig:3598`)

- **签名**：`pub fn pollGCChecked( self: *JSRuntime, roots: ?*const ValueRootFrame, mode: GCPollMode, ) RuntimeCollectionError!gc.CollectionResult`。
- **作用**：宿主版 pollGC，错误集含 WrongRuntimeThread。
- **实现**：`requireOwnerThread` + `pollGC`。
- **所有权 / 错误 / 调用**：错线程在 poll 前返回 WrongRuntimeThread；正确线程沿用 pollGC 的错误、空结果及分支语义，不保证本次已完成 major。

### `JSRuntime.gcSafepoint` (`src/core/runtime.zig:3607`)

- **签名**：`pub fn gcSafepoint(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult`。
- **作用**：`.safepoint` poll（解释器 cadence、young budget）。
- **实现**：`pollGC(..., .safepoint)`。
- **所有权 / 错误 / 调用**：转发 roots 并传播错误，沿用 pollGC 对不同分支的根处理；不保证每次 safepoint 都执行收集。

### `JSRuntime.afterCallbackBoundaryGC` (`src/core/runtime.zig:3611`)

- **签名**：`pub fn afterCallbackBoundaryGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult`。
- **作用**：回调返回后的 poll + 预算 native/payload 清理。
- **实现**：先 try pollGC(..., callback_boundary)，成功后依次调用 native cleanup 与 class payload finalizer 的预算执行器，两者各使用 native_cleanup_slice_jobs 作为预算，再返回原 poll 结果。
- **所有权 / 错误 / 调用**：poll 失败则不执行后面两项；两类预算不是共用一个总数上限。返回结果不包含随后清理的任务数或耗时，各清理器自己的安全条件仍适用。

### `JSRuntime.beforeEventLoopIdleGC` (`src/core/runtime.zig:3618`)

- **签名**：`pub fn beforeEventLoopIdleGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult`。
- **作用**：事件循环空闲：`.idle` poll + 同样预算清理。
- **实现**：先 try pollGC(..., idle)，成功后依次执行 native cleanup 和 class payload finalizer，各给 native_cleanup_slice_jobs 预算，最后返回原 poll 结果。
- **所有权 / 错误 / 调用**：不自行设置 host_quiescent 或证明宿主已静止；idle 的 rootScan 为 declared_only，但生产收集器是否保守扫描另受 host_quiescent 控制。poll 失败跳过后续清理，返回统计不包含清理工作。

### `JSRuntime.forceGC` (`src/core/runtime.zig:3625`)

- **签名**：`pub fn forceGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult`。
- **作用**：host 紧急收集。
- **实现**：`requestGC(.manual, .urgent)` + `pollGC(.urgent)`。
- **所有权 / 错误 / 调用**：显式检查 owner。允许收集时 urgent 路径完成 pending 销毁、中止现有标记再走 STW；重入保护或活动 deferred finalizer 仍可使 poll 返回空结果，请求保持待处理，故不是无条件同步完成保证。

### `JSRuntime.forceMajorGC` (`src/core/runtime.zig:3631`)

- **签名**：`pub fn forceMajorGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult`。
- **作用**：`forceGC` 别名。
- **实现**：转发。
- **所有权 / 错误 / 调用**：嵌入。

### `JSRuntime.requestGCForTest` (`src/core/runtime.zig:3635`)

- **签名**：`pub fn requestGCForTest(self: *JSRuntime) void`。
- **作用**：排队 `.manual/.soon`，不立刻跑。
- **实现**：test-only。
- **所有权 / 错误 / 调用**：调度测试。

### `JSRuntime.pollScansConservatively` (`src/core/runtime.zig:3654`)

- **签名**：`fn pollScansConservatively(self: *const JSRuntime, mode: GCPollMode) bool`。
- **作用**：为阈值跨越时是否先尝试 minor 提供扫描策略条件。
- **实现**：生产构建返回 mode.rootScan() == engine_active；测试构建还允许测试 override 优先。
- **所有权 / 错误 / 调用**：只检查策略枚举，不检查实际 native frame 或 host_quiescent。生产 Collector 的 conservative_on 另由 host_quiescent 决定，所以本函数名不能解释为对实际保守扫描是否执行的完整查询。

### `JSRuntime.forcePreciseRootScanForTest` (`src/core/runtime.zig:3665`)

- **签名**：`pub fn forcePreciseRootScanForTest(self: *JSRuntime) void`。
- **作用**：声明本测试把可收集引用都放在 ValueRootFrame 或 dropGcPtr 擦过，engine-trigger 也可精确扫。
- **实现**：`test_root_scan_override = .declared_only`。
- **所有权 / 错误 / 调用**：必须在把控制交还持有 native 局部的代码前 `restoreDefaultRootScanForTest`。

### `JSRuntime.restoreDefaultRootScanForTest` (`src/core/runtime.zig:3675`)

- **签名**：`pub fn restoreDefaultRootScanForTest(self: *JSRuntime) void`。
- **作用**：关闭精确扫窗口。
- **实现**：override=null。
- **所有权 / 错误 / 调用**：test-only。

### `JSRuntime.gcPendingForTest` (`src/core/runtime.zig:3680`)

- **签名**：`pub fn gcPendingForTest(self: JSRuntime) bool`。
- **作用**：是否有 pending major 请求。
- **实现**：`gc.hasPendingMajorRequest()`。
- **所有权 / 错误 / 调用**：test-only。

### `JSRuntime.gcLastRequestReasonForTest` (`src/core/runtime.zig:3685`)

- **签名**：`pub fn gcLastRequestReasonForTest(self: JSRuntime) ?gc.RequestReason`。
- **作用**：上次请求原因。
- **实现**：`gc.stats.last_request_reason`。
- **所有权 / 错误 / 调用**：test-only。

---

## 阈值、内存限制、外部内存、进程压力

### `JSRuntime.setGCThreshold` (`src/core/runtime.zig:3690`)

- **签名**：`pub fn setGCThreshold(self: *JSRuntime, threshold: usize) void`。
- **作用**：写 malloc GC 阈值并作废周期 envelope 基线。
- **实现**：`invalidateCycleEnvelopeBaseline` + 字段。
- **所有权 / 错误 / 调用**：直接接受任意 usize，包括 0 或低于当前账户的值；不立即收集、不排队请求、不重设 allocation debt，也不检查 owner 线程。后续收集完成时自动阈值规则可覆盖该值。

### `JSRuntime.gcThreshold` (`src/core/runtime.zig:3695`)

- **签名**：`pub fn gcThreshold(self: JSRuntime) usize`。
- **作用**：读阈值。
- **实现**：`malloc_gc_threshold`。
- **所有权 / 错误 / 调用**：只读 `malloc_gc_threshold`，不分配、无 error set。与 `setGCThreshold`（`src/core/runtime.zig:3691`，会顺带 `invalidateCycleEnvelopeBaseline`）成对，典型用法是「存旧值 → 临时改 → `defer` 还原」：`src/binding/context.zig:92` 跨 intrinsic bootstrap 保住嵌入方设的阈值，`src/core/promise.zig:78`（根覆盖单测）与 `src/exec/call.zig:608` 等大量 GC 根测试则临时把阈值压到 0 以强制每次分配都触发收集。

### `JSRuntime.setMemoryLimit` (`src/core/runtime.zig:3699`)

- **签名**：`pub fn setMemoryLimit(self: *JSRuntime, limit: ?usize) void`。
- **作用**：设置 MemoryAccount 后续分配检查使用的可选上限。
- **实现**：调用 memory.setLimit，只替换 limit 字段；null 取消该限制，0 是有效的零上限。
- **所有权 / 错误 / 调用**：不是进程 RSS 限制，也不覆盖所有账户外内存。降到当前用量以下不会当场释放内存或报错；后续分配由账户检查，可能调用已安装的超限前收集回调。此函数不自行收集或检查线程。

### `JSRuntime.suppressLimitCollectionForTest` (`src/core/runtime.zig:3714`)

- **签名**：`pub fn suppressLimitCollectionForTest(self: *JSRuntime, suppressed: bool) void`。
- **作用**：测试注入分配失败时关掉「超限先收集」——生产语义是「这么多 **live**」，收集一字节就会让预期失败变成成功。
- **实现**：`limit_gc_fn = null` 或恢复 `collectBeforeLimitRejection`。
- **所有权 / 错误 / 调用**：test-only。

### `JSRuntime.memoryLimit` (`src/core/runtime.zig:3719`)

- **签名**：`pub fn memoryLimit(self: JSRuntime) ?usize`。
- **作用**：读上限。
- **实现**：`memory.getLimit()`。
- **所有权 / 错误 / 调用**：转发 `memory.getLimit()`，只读、不分配、无 error set；`null` 表示不设限。树内唯一调用方是 `src/core/runtime.zig:3745`，把它填进 `MemoryUsage.memory_limit` 快照；其余是嵌入 API 面。

### `JSRuntime.memoryUsage` (`src/core/runtime.zig:3723`)

- **签名**：`pub fn memoryUsage(self: *const JSRuntime) MemoryUsage`。
- **作用**：汇总账户计数、当前 atom/class 表及 GC 登记数量；各类字节字段并非完整堆内存普查。
- **实现**：atom_count 为 predefined_count 加 isLive 动态条目数，atom_bytes 仅累加这些动态条目的描述字节长度。object/shape/module 数量来自 liveCountKind；object_bytes 以普通对象体大小乘对象数，shape/module 字节分别按结构大小乘数量。registered_class_count 只数已注册记录，class_record_count 和 class_bytes 则包括 records 切片全部槽。
- **所有权 / 错误 / 调用**：不先执行 GC，所以登记数量不是重新追踪得到的可达数量。类型字节估算不覆盖所有尾部、payload、属性数组或分配器开销，不能相加充当 allocated_bytes 或 RSS。只读查询，无锁或 owner 检查，依赖调用方的 Runtime 访问纪律。

### `JSRuntime.reportExternalAlloc` (`src/core/runtime.zig:3767`)

- **签名**：`pub fn reportExternalAlloc(self: *JSRuntime, bytes: usize) !gc.ExternalMemoryToken`。
- **作用**：嵌入者把账户外缓冲区算进 GC 压力，拿 token。
- **实现**：先 gc.reportExternalAlloc 创建登记并累计外部字节及加权债务；若达到外部压力条件则 requestGC，随后检查进程内存压力。token.release 会先清空自身字段，同一个 token 变量重复 release 无操作；复制 token 后重复释放同一登记则可能记录 invalid release。
- **所有权 / 错误 / 调用**：这里只登记已由宿主负责的内存，不分配该缓冲区或立即收集；登记可能失败。成功的非空 token 须在 Runtime 有效期间 release；release 只撤账，不释放宿主缓冲区。bytes=0 返回空 token，但 Runtime 包装仍执行后续压力检查；不能把零字节调用视为完全无副作用。

### `JSRuntime.reportExternalAllocUntracked` (`src/core/runtime.zig:3779`)

- **签名**：`pub fn reportExternalAllocUntracked(self: *JSRuntime, bytes: usize) void`。
- **作用**：已在 MemoryAccount 的 inline buffer 分类。不做压力检查。
- **实现**：转发 gc.reportExternalAllocUntracked；非零字节饱和累加 external_bytes、external_untracked_bytes、分配次数和加权 allocation debt，并更新外部峰值。
- **所有权 / 错误 / 调用**：不生成 token、不分配缓冲区或马上检查压力；账户外嵌入者应使用带 token 的路径。应与 Untracked free 配对，零字节不改变记账。

### `JSRuntime.reportExternalFreeUntracked` (`src/core/runtime.zig:3783`)

- **签名**：`pub fn reportExternalFreeUntracked(self: *JSRuntime, bytes: usize) void`。
- **作用**：untracked 减账。
- **实现**：转发 GC；非零时饱和扣除 external_bytes 和 external_untracked_bytes，并增加释放次数。
- **所有权 / 错误 / 调用**：与 Untracked alloc 配对；不实际释放存储、不撤销 tracked token，也不冲销累计 allocation debt。没有独立 token 校验释放身份。

### `JSRuntime.externalMemoryBytes` (`src/core/runtime.zig:3787`)

- **签名**：`pub fn externalMemoryBytes(self: JSRuntime) usize`。
- **作用**：读取外部分类的当前记账字节，包含 tracked 与 untracked。
- **实现**：`gc.stats.external_bytes`。
- **所有权 / 错误 / 调用**：只读 `gc.stats.external_bytes`，不分配、不触发回收、无 error set。这是**记账值**不是所有权：字节本身在宿主堆里，由 `reportExternal*` 家族加减，引擎不持有也不释放。别与 `allocationDebtBytes`（`src/core/runtime.zig:3798`）混淆，后者是带 `external_weight` 的加权债。调用方都是记账测试：本文件 `src/core/runtime.zig:4891` 起 5 处，另有 `src/tests/core.zig:4902` 起若干处，全树共 18 处。

### `JSRuntime.allocationDebtBytes` (`src/core/runtime.zig:3791`)

- **签名**：`pub fn allocationDebtBytes(self: JSRuntime) usize`。
- **作用**：加权分配债（可因 `external_weight` 大于自上次 major 以来的外部字节）。
- **实现**：`gc.stats.allocation_debt`。
- **所有权 / 错误 / 调用**：历史 API 名；这是调度债务，不是仍存活或仍未释放的外部内存。外部 free 不冲销已发生的分配债，不能用此值反推泄漏大小。

### `JSRuntime.gcPauseDistribution` (`src/core/runtime.zig:3802`)

- **签名**：`pub fn gcPauseDistribution(self: *const JSRuntime) ?gc.PauseDistribution`。
- **作用**：查询收集器保留的停顿样本窗口的百分位；没有样本时返回 null，不以“完成收集数”为判断条件。
- **实现**：转发 gc.pauseDistribution，将至多 pause_sample_capacity 个样本复制到栈数组排序，按 nearest-rank 取 p50/p95/p99 和窗口最大值。
- **所有权 / 错误 / 调用**：不修改原样本顺序、不进行堆分配。结果 samples 是累计 pause_sample_count，可大于参与本次排序的窗口样本数；这些百分位并非所有历史停顿的分布，也不包含单独记账的 minor 分布。

### `JSRuntime.gcStats` (`src/core/runtime.zig:3806`)

- **签名**：`pub fn gcStats(self: *const JSRuntime) gc.Stats`。
- **作用**：收集器计数 + 弱引用数 + finalization/deferred 队列 + RSS/cgroup。
- **实现**：先取 statsSnapshot，再填弱引用计数；finalizer_queue_length 与 pending_finalization_job_count 都取 job_queue 中 finalization job 数。另填两类 deferred 队列长度与已执行计数，最后调用 currentRssBytes 和 cgroupLimitBytes。
- **所有权 / 错误 / 调用**：该查询始终尝试进程采样，不受压力策略的 needsProcessMemorySnapshot 门控；Linux 上读取 proc/cgroup 文件，失败值为 0。队列长度不等于所有待终结对象数，也不包括已经取出正在执行的项。会遍历相关对象和表，无锁，不能视为常数成本或并发原子快照。

### `JSRuntime.ownsObject` (`src/core/runtime.zig:3821`)

- **签名**：`pub fn ownsObject(self: *const JSRuntime, object: *const Object) bool`。
- **作用**：对象 header 是否在本 GC registry。
- **实现**：`gc.containsHeader`。
- **所有权 / 错误 / 调用**：仅查询登记归属，不增加强根、不证明 JavaScript 可达性。要求传入有效对象指针，不是安全探测任意或已释放地址的接口。

### `JSRuntime.requestGCForProcessMemoryPressure` (`src/core/runtime.zig:3839`)

- **签名**：`inline fn requestGCForProcessMemoryPressure(self: *JSRuntime) void`。
- **作用**：策略需要进程快照时才进入 RSS/cgroup 采样路径，并可能排队收集请求。
- **实现**：`needsProcessMemorySnapshot` 假则返回，否则 outlined `requestGCForProcessMemoryPressureSlow`。
- **所有权 / 错误 / 调用**：`reportExternalAlloc`、部分 poll 模式。

### `JSRuntime.requestGCForProcessMemoryPressureSlow` (`src/core/runtime.zig:3844`)

- **签名**：`noinline fn requestGCForProcessMemoryPressureSlow(self: *JSRuntime) void`。
- **作用**：采样进程内存并将策略判定转为 GC 请求。
- **实现**：获取 currentRssBytes 与 cgroupLimitBytes，传给 gc.processMemoryRequest；有返回值才调用 requestGC(reason, urgency)。Linux 上至多尝试打开三个路径，v2 限制成功解析后不再尝试 v1。
- **所有权 / 错误 / 调用**：外层按策略门控，本函数内部不重复门控。只请求而不执行收集；文件读取或解析失败不会向调用方返回错误，RSS/限制以 0 表示未取得值。

### `JSRuntime.weakReferenceCount` (`src/core/runtime.zig:3852`)

- **签名**：`fn weakReferenceCount(self: *const JSRuntime) usize`。
- **作用**：弱持久槽 + 堆上弱集合条目 + FinalizationRegistry cells。
- **实现**：只计 identity 非空的 weak_root_slots；再遍历 GC objectIterator(all) 中 object 类节点，饱和加上 weakCollectionEntries().len 和 finalizationRegistryCells().len。
- **所有权 / 错误 / 调用**：gcStats 使用；这是一组槽和条目长度之和，不是不同弱目标的去重数，也不是重新验证每个目标存活后的数量。已清 identity 的持久弱槽不计，遍历成本随登记对象和槽数量增长。

### `JSRuntime.currentRssBytes` (`src/core/runtime.zig:3868`)

- **签名**：`fn currentRssBytes() usize`。
- **作用**：读 `/proc/self/statm` 第二字段 × page。
- **实现**：Linux 上以 128 字节缓冲读取 statm，跳过第一字段，将第二字段解析为 resident pages，再乘 std.heap.pageSize()；乘法溢出返回 usize 最大值。
- **所有权 / 错误 / 调用**：非 Linux、读失败、字段不足或解析失败均返回 0。值是整个进程的 RSS，不是当前 Runtime 独占内存；0 不能区分不支持与采样失败。

### `JSRuntime.cgroupLimitBytes` (`src/core/runtime.zig:3878`)

- **签名**：`fn cgroupLimitBytes() usize`。
- **作用**：cgroup v2 `memory.max` 或 v1 `memory.limit_in_bytes`。
- **实现**：Linux 上先读固定 v2 路径并解析首 token；读不到或无法解析（包括 max）则尝试固定 v1 路径；任一路成功解析即返回，全部失败或非 Linux 返回 0。
- **所有权 / 错误 / 调用**：不解析 /proc/self/cgroup 或递归查找实际子组路径，不综合祖先限制，也不转换 v1 的大数无限制哨兵。v2 为 max 不代表立刻返回 0，仍可能返回 v1 解析值。

### `JSRuntime.readLinuxFile` (`src/core/runtime.zig:3890`)

- **签名**：`fn readLinuxFile(path: []const u8, buf: []u8) ?[]const u8`。
- **作用**：openat+read 小文件。
- **实现**：Linux 上只读 openat，成功后 defer close；执行一次 read 并返回 buf[0..len]。open/read 失败或非 Linux 返回 null，关闭错误忽略。
- **所有权 / 错误 / 调用**：返回借用调用方缓冲区的切片，无额外分配；不循环读完整文件，不检测截断，也不补零终止符。空文件可成功返回空切片。

### `JSRuntime.firstToken` (`src/core/runtime.zig:3900`)

- **签名**：`fn firstToken(contents: []const u8) []const u8`。
- **作用**：空白分隔第一个 token。
- **实现**：按空格、tab、CR、LF 分隔，返回首个非空 token，无 token 返回空字符串。
- **所有权 / 错误 / 调用**：返回借用输入的切片，不分配；不将任意 Unicode 空白视为分隔符。

### `JSRuntime.parseUnsignedToken` (`src/core/runtime.zig:3905`)

- **签名**：`fn parseUnsignedToken(token: []const u8) ?usize`。
- **作用**：解析无符号；空或 `"max"` → null。
- **实现**：精确匹配空串或小写 max 时返回 null，否则调用 parseAsciiInt(usize, token, 10)，将非法格式或溢出错误转为 null。
- **所有权 / 错误 / 调用**：不自行分词、去空白或识别单位；合法的数值 0 返回可选值 0，与 null 不同。RSS/cgroup 调用方决定失败回退。

### `JSRuntime.prospectiveAllocationTotal` (`src/core/runtime.zig:3910`)

- **签名**：`inline fn prospectiveAllocationTotal(self: *const JSRuntime, size: usize) usize`。
- **作用**：`allocated_bytes +| size`。
- **实现**：饱和加。
- **所有权 / 错误 / 调用**：只计算当前账户加请求大小的预计值，溢出饱和到 usize 最大值；不分配、不记账、不检查内存上限，也不预估底层分配器的额外开销。

### `JSRuntime.requestGCForAllocationTotal` (`src/core/runtime.zig:3919`)

- **签名**：`inline fn requestGCForAllocationTotal(self: *JSRuntime, size: usize) usize`。
- **作用**：排队分配阈值请求并返回用于决策的 prospective total，避免对象构造二次加载账户。
- **实现**：GC 正在运行或 phase 非 none 时只返回预计总量。force_gc_on_allocation 启用时，trigger 为空则只计算；否则 forceGC(null)，忽略错误，恢复原阈值，再读取账户计算预计总量。普通路径仅在饱和相加的预计总量严格大于阈值时排队 allocation_threshold/soon，并返回该总量。
- **所有权 / 错误 / 调用**：普通路径只请求，不收集；force-GC 路径只恢复阈值，不回滚收集产生的其他状态。size=0 也可能在账户已超阈值时请求 GC。返回值不是分配成功、内存额度预留或此后账户不变的保证。

### `JSRuntime.requestGCForAllocation` (`src/core/runtime.zig:3953`)

- **签名**：`pub inline fn requestGCForAllocation(self: *JSRuntime, size: usize) void`。
- **作用**：丢弃返回值的包装。
- **实现**：`_ = requestGCForAllocationTotal`。
- **所有权 / 错误 / 调用**：不分配内存、不验证 owner 线程；沿用底层请求或诊断 force-GC 分支，不能把所有构建中的调用都解释为纯排队。

### `JSRuntime.collectBeforeObjectAllocation` (`src/core/runtime.zig:3962`)

- **签名**：`pub fn collectBeforeObjectAllocation(self: *JSRuntime, size: usize) align(64) void`。
- **作用**：在对象分配前提供延迟 payload 回调及 GC 调度的安全边界，不保证每次都执行或完成收集。
- **实现**：仅当 payload finalizer 队列非空、gc_running=false、phase=none 且未在 draining 时进入冷路径先 drain；其余情况直接进入 AfterFinalizerCheck。
- **所有权 / 错误 / 调用**：本函数不分配对象，不返回收集错误；调用方仍须保护分配前持有的对象并处理后续分配失败。align(64) 指函数代码对齐，不是对象分配对齐或缓存性能保证。

### `JSRuntime.collectBeforeObjectAllocationAfterDeferredDrain` (`src/core/runtime.zig:3982`)

- **签名**：`noinline fn collectBeforeObjectAllocationAfterDeferredDrain(self: *JSRuntime, size: usize) void`。
- **作用**：对象分配边界上回调投递的冷续体。drain 后再做阈值决策，但跳过「队列是否就绪」测试：回调在 `draining_...` 置位期间可能又入队，同一边界递归 drain 被禁止。
- **实现**：`drainDeferredClassPayloadFinalizersAtSafeBoundary()`，然后 `collectBeforeObjectAllocationAfterFinalizerCheck(size)`。tracer_destroy 内禁止 plugin 回调；collector 变 idle 后的第一次对象分配边界才 drain。回调里的分配会重入 `collectBeforeObjectAllocation`，此时 `draining_deferred_class_payload_finalizers` 已置，只允许排队下一轮 GC，不能再 drain。
- **所有权 / 错误 / 调用**：由外层满足队列和执行状态条件后调用；本续体不再次检查队列，不承诺清空回调执行期间新增的全部任务。没有错误返回值，不表示回调或后续收集必定完成。

### `JSRuntime.collectBeforeObjectAllocationAfterFinalizerCheck` (`src/core/runtime.zig:3994`)

- **签名**：`inline fn collectBeforeObjectAllocationAfterFinalizerCheck(self: *JSRuntime, size: usize) void`。
- **作用**：按预计分配总量与辅助债务，决定是否在本次分配边界 poll GC。
- **实现**：先 requestGCForAllocationTotal；预计值小于或等于阈值时只尝试清陈旧 allocation_threshold 请求。GC 运行中或 phase 非 none 则返回；无 morgue 且无 major 请求也返回。周期已开时饱和累加 size 到辅助债务：债务达到 interval 即可推进，否则仅当待销毁期间账户增长达到 interval 且债务加回收信用也达到 interval 时推进。新周期则清辅助债务并立即进入 poll。
- **所有权 / 错误 / 调用**：账户增长仅在 morgue pending 时参与信用判断；未满足条件时请求仍待处理。该字节节奏限制的是辅助推进频率，不承诺一个宿主操作的总停顿上限；poll 错误由下一层忽略。

### `JSRuntime.pollGCBeforeObjectAllocation` (`src/core/runtime.zig:3990`)

- **签名**：`noinline fn pollGCBeforeObjectAllocation(self: *JSRuntime) void`。
- **作用**：将对象分配边界的 GC poll 放在独立 noinline 函数中。
- **实现**：调用 pollGC(null, normal)，忽略 CollectionResult 及返回错误。
- **所有权 / 错误 / 调用**：用于已开周期满足推进条件，以及待处理请求开启新周期的路径；不是只有“已有周期且债够”才调用。返回 void 不证明收集成功，也不提供额外根链；不对具体机器码栈帧或寄存器保存作保证。

### `JSRuntime.triggerGCOnAllocation` (`src/core/runtime.zig:4039`)

- **签名**：`fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void`。
- **作用**：MemoryAccount 的 trigger 回调。
- **实现**：cast 后 `requestGCForAllocation`。
- **所有权 / 错误 / 调用**：Runtime 初始化时安装；ctx 虽声明可选，实际必须是有效、对齐且稳定的 JSRuntime 地址，函数不处理 null。通常只排队阈值请求，诊断 force-GC 分支可能运行收集。

### `JSRuntime.collectBeforeLimitRejection` (`src/core/runtime.zig:4051`)

- **签名**：`fn collectBeforeLimitRejection(ctx: *anyopaque) void`。
- **作用**：账户即将因内存上限拒绝分配时，尝试通过全堆收集回收空间。
- **实现**：`tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch return`。
- **所有权 / 错误 / 调用**：memory.limit_gc_fn 使用；错误被忽略，重入或活动 finalizer 可能使底层不收集。此回调不重试实际分配，不报告回收成功，由账户随后重新判断限制。engine_active 表达扫描策略，实际生产扫描仍受 host_quiescent 控制。

### `JSRuntime.resetGCThreshold` (`src/core/runtime.zig:4056`)

- **签名**：`fn resetGCThreshold(self: *JSRuntime) void`。
- **作用**：依据当前 allocated_bytes 重设 major 分配阈值，不将该账户数视为精确可达活集大小。
- **实现**：阈值为 max(2×allocated_bytes, allocated_bytes + small_heap_major_headroom_bytes)，两项加法溢出均饱和到 usize 最大值。floor 严格更大时计 floor hit，否则（包括相等）计 growth hit；仅在 morgue 不 pending 时记录周期基线，最后清 allocation debt。
- **所有权 / 错误 / 调用**：STW major、销毁结算及扣除待销毁字节的临时账户路径使用；minor 成功路径不调用。只设置调度状态，不分配或释放内存，不设置 MemoryAccount.limit，也不保证进程 RSS 被限制在某个倍数内。

---

## 字符串缓存、栈护栏、atom/class、中断、动态 import、标准全局

### `JSRuntime.singleByteString` (`src/core/runtime.zig:4116`)

- **签名**：`pub inline fn singleByteString(self: *JSRuntime, byte: u8) !*string.String`。
- **作用**：latin1 单码元共享串，懒创建，槽即根，借用无需 retain。
- **实现**：命中返回；否则 outlined `createSingleByteString`。
- **所有权 / 错误 / 调用**：miss 时可能分配失败；参数 u8 只能表示 0..255，本接口没有处理更大码元的分支。返回借用 String，由有效的 Runtime 缓存根保持，不增加每调用方引用计数。

### `JSRuntime.createSingleByteString` (`src/core/runtime.zig:4122`)

- **签名**：`noinline fn createSingleByteString(self: *JSRuntime, byte: u8) !*string.String`。
- **作用**：为 singleByteString 的未填充槽创建 Latin1 单码元字符串。
- **实现**：`String.createLatin1(self, &.{byte})`，写入 `single_byte_strings[byte]`，返回该体。槽本身是根，体活过每一次借用；TGC S1–S3 删掉 RC 后调用方不再 retain。
- **所有权 / 错误 / 调用**：外层在槽为空时调用；创建失败不写槽，后续请求可以重试，因此不能说每码元至多执行一次。成功后的缓存根保活不等于调用方独立拥有，返回 JSValue 不需要旧式 RC dup，但缓存清理或 Runtime 销毁后不能继续依赖这个根。

### `JSRuntime.cachedSingleByteString` (`src/core/runtime.zig:4129`)

- **签名**：`pub inline fn cachedSingleByteString(self: *JSRuntime, byte: u8) ?*string.String`。
- **作用**：非分配探测。
- **实现**：读槽。
- **所有权 / 错误 / 调用**：不分配或填充槽；null 仅表示缓存未填充，不表示码元无效。返回借用指针，生命周期与对应缓存一致。

### `JSRuntime.emptyString` (`src/core/runtime.zig:4133`)

- **签名**：`pub fn emptyString(self: *JSRuntime) !*string.String`。
- **作用**：不可变空串懒缓存。
- **实现**：命中直接返回；miss 时 createAscii("")，成功后才写 empty_string。
- **所有权 / 错误 / 调用**：创建错误传播且缓存保持原状，允许重试；返回借用体，缓存参与根扫描，不为调用方建立独立根。

### `JSRuntime.recentTwoUnitString` (`src/core/runtime.zig:4143`)

- **签名**：`pub fn recentTwoUnitString(self: *JSRuntime, first: u16, second: u16) !*string.String`。
- **作用**：单条最近两码元串缓存。URI 循环里 `fromCharCode(H,L)` 与 decode 共享。
- **实现**：键匹配返回；否则 `createUtf16Pair` 覆盖槽。
- **所有权 / 错误 / 调用**：创建失败保留旧缓存；成功覆盖槽后旧字符串失去此缓存根，但不会在这里直接析构。调用方若继续使用旧值，应由其他根或可追踪边保持可达；位拷贝 JSValue 本身不登记根。键是两个 UTF-16 码元，不限定为合法代理对。

### `JSRuntime.recentAtomString` (`src/core/runtime.zig:4159`)

- **签名**：`pub fn recentAtomString(self: *JSRuntime, atom_id: atom.Atom, bytes: []const u8) !*string.String`。
- **作用**：四路 atom→string 物化缓存。
- **实现**：扫 4 槽；miss 则 `createUtf8`，`atoms.cacheString`，round-robin 写入 `compact_state.recent_atom_string_next`。
- **所有权 / 错误 / 调用**：命中只比较 atom_id，不核对 bytes，因此调用方须提供与身份一致的文本。创建失败不推进替换位置；成功淘汰旧槽后旧值不再由该槽保活，可能仍有 AtomTable 或其他根。cacheString 的弱回指和条件缓存不等于总会建立 atom 强根；返回值不是独立 root。

### `JSRuntime.smallIntString` (`src/core/runtime.zig:4181`)

- **签名**：`pub fn smallIntString(self: *JSRuntime, value: u8) !*string.String`。
- **作用**：`"0"`..`"255"` 懒缓存。
- **实现**：按 u8 值查缓存；miss 时在 4 字节栈缓冲中打印十进制，再 createLatin1，成功后写槽。不生成百分号或十六进制文本。
- **所有权 / 错误 / 调用**：分配错误传播，失败不填槽；缓冲足以容纳 0..255，格式化失败视为 unreachable。返回借用体，保活依赖缓存根，不存在“初始 RC 引用”的转移。

### `JSRuntime.percentHexString` (`src/core/runtime.zig:4192`)

- **签名**：`pub fn percentHexString(self: *JSRuntime, value: u8) !*string.String`。
- **作用**：`%00`..`%FF` 大写三字节串。
- **实现**：命中直接返回；miss 时构造 '%' 加高低半字节的大写十六进制字符，createAscii 后填槽。
- **所有权 / 错误 / 调用**：只编码一个 byte，不处理完整 URI 或 Unicode 字符；分配错误传播且不填槽。返回借用字符串，缓存负责声明根。

### `JSRuntime.setStackSize` (`src/core/runtime.zig:4204`)

- **签名**：`pub fn setStackSize(self: *JSRuntime, size: usize) void`。
- **作用**：逻辑 JS 栈预算，并重算 arena 策略字。
- **实现**：`hot.stack_size` + `vm_stack_arena_policy = arenaForLimit(size)`。
- **所有权 / 错误 / 调用**：Runtime 范围的逻辑栈预算，与 native 栈限制独立；不会分配、缩减或清空现有 arena，也不即时检查当前调用深度。arenaForLimit 对策略字中的 limit 另有位宽裁剪，hot.stack_size 保存原始 size。

### `JSRuntime.stackSize` (`src/core/runtime.zig:4209`)

- **签名**：`pub fn stackSize(self: JSRuntime) usize`。
- **作用**：读逻辑栈预算。
- **实现**：`hot.stack_size`。
- **所有权 / 错误 / 调用**：只读 `hot.stack_size`，不分配、无 error set。写侧 `setStackSize`（`src/core/runtime.zig:4210`）还会重算 `vm_stack_arena_policy`，所以别绕过它直接写字段。调用方是所有需要开嵌套 VM 栈的地方：`src/exec/call_runtime.zig:3393`、`src/exec/call.zig:2518`、`src/exec/promise_ops.zig:2647` 等十余处，以及 `core.JSContext.stackLimit`（`src/core/context.zig:586`）的转发。

### `JSRuntime.setNativeStackSize` (`src/core/runtime.zig:4213`)

- **签名**：`pub fn setNativeStackSize(self: *JSRuntime, size: usize) void`。
- **作用**：改 native 递归预算并重算 limit。
- **实现**：写 size，`updateNativeStackTop`。
- **所有权 / 错误 / 调用**：0 关闭此软件 guard，不改变操作系统实际栈大小。非零设置也会用当前调用帧重新确定基准，并非仅调整旧基准的预算；不验证调用线程。

### `JSRuntime.updateNativeStackTop` (`src/core/runtime.zig:4224`)

- **签名**：`pub fn updateNativeStackTop(self: *JSRuntime) void`。
- **作用**：以当前帧指针为递归基，推导下限。qjs `JS_UpdateStackTop` + `update_stack_limit`（quickjs.c:2841-2860）。必须在将跑代码的线程的最外 JS 入口调用（worker 的 C 栈不同）。
- **实现**：`native_stack_top = @frameAddress()`；size=0 则 limit=0，否则 `top -| size`。
- **所有权 / 错误 / 调用**：应在实际执行线程的最外层 JS 入口更新；函数不验证这一前提。饱和相减若得到 0，也使 guard 不会报越界；不分配或扩展 native 栈。

### `JSRuntime.checkNativeStackOverflow` (`src/core/runtime.zig:4246`)

- **签名**：`pub inline fn checkNativeStackOverflow(self: *const JSRuntime, alloca_size: usize) bool`。
- **作用**：再消耗 `alloca_size` 是否越过 native 限。直译 qjs `js_check_stack_overflow`：`sp = frame - alloca; sp < limit`。栈向下长。limit=0 时无指针低于 0，同一无符号比较即为「无限制」，不必额外分支（parser 每 token 都走）。
- **实现**：`(@frameAddress() -| alloca_size) < native_stack_limit`。
- **所有权 / 错误 / 调用**：只返回 bool，不抛异常、不移动栈指针、不分配 alloca_size 字节；如何报错由调用方决定。相等不算越界，limit=0 时恒 false。检测依赖向下增长的栈及正确基准，不能代替操作系统 guard page。

### `JSRuntime.internAtom` (`src/core/runtime.zig:4251`)

- **签名**：`pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom`。
- **作用**：intern 字符串 atom。
- **实现**：`atoms.internString`。
- **所有权 / 错误 / 调用**：OOM。`global_slots.getByName`。

### `JSRuntime.newClassId` (`src/core/runtime.zig:4255`)

- **签名**：`pub fn newClassId(self: *JSRuntime, requested: class.ClassId) (error{ClassIdExhausted} || RuntimeMutationError)!class.ClassId`。
- **作用**：动态 class id。requested 非 invalid 则原样返回（调用方自选 id）。
- **实现**：`requireOwnerThread`；否则 `class.allocateDynamicClassId()`（进程级，有自己的同步）。
- **所有权 / 错误 / 调用**：即使 requested 非 invalid，也先检查线程。返回指定 id 不验证冲突、保留范围或是否已注册；自动分配可能 ClassIdExhausted。只取得 id，不登记 class 定义或扩充 Context prototype 槽。

### `JSRuntime.setInterruptHandler` (`src/core/runtime.zig:4261`)

- **签名**：`pub fn setInterruptHandler(self: *JSRuntime, handler: ?*const fn (*JSRuntime, ?*anyopaque) bool, context: ?*anyopaque) void`。
- **作用**：安装/清除中断回调。不改各 realm 的 `interrupt_counter`。
- **实现**：两字段。
- **所有权 / 错误 / 调用**：只保存回调和借用 context，不立即执行、释放旧 context 或检查线程；handler=null 时仍保存传入 context。正常轮询将 true 解释为中断请求，执行时机由调用方决定。

### `JSRuntime.getDynamicImportLoader` (`src/core/runtime.zig:4266`)

- **签名**：`pub fn getDynamicImportLoader(self: *const JSRuntime) DynamicImportLoader`。
- **作用**：读当前 loader。
- **实现**：返回结构（函数指针+userdata）。
- **所有权 / 错误 / 调用**：返回描述符副本，不调用加载器或延长 userdata 生命周期；替换当前加载器也不会修改已经取得的副本。

### `JSRuntime.installDynamicImportLoader` (`src/core/runtime.zig:4270`)

- **签名**：`pub fn installDynamicImportLoader(self: *JSRuntime, next: DynamicImportLoader) DynamicImportLoaderScope`。
- **作用**：替换 loader 并返回可 restore 的作用域。
- **实现**：assert owner，保存 previous。
- **所有权 / 错误 / 调用**：不销毁旧加载器、不拥有新旧 userdata。返回 scope 用于恢复 previous；必须在 Runtime 有效期间按嵌套顺序恢复，scope 幂等标记不验证 LIFO，也不防止按值复制 scope 导致重复恢复。

### `JSRuntime.standardGlobalOwnPropertyCapacity` (`src/core/runtime.zig:4284`)

- **签名**：`pub fn standardGlobalOwnPropertyCapacity(self: *const JSRuntime) usize`。
- **作用**：读取安装器配置的全局 own-property 预留数量；本函数不实际预留存储。
- **实现**：字段。
- **所有权 / 错误 / 调用**：供创建全局对象时规划容量；返回 0 不能单独证明安装器不存在。installStandardGlobals 是否可调用取决于 callback 字段及 Context 条件，不以此数值判断。

### `JSRuntime.installStandardGlobals` (`src/core/runtime.zig:4297`)

- **签名**：`pub fn installStandardGlobals(self: *JSRuntime, global: *Object) errors.RuntimeError!void`。
- **作用**：经 exec 注册的安装器把标准全局建到 `global` 上，并接线 `internal_builtins` / `materialize_builtin_namespace_cb`。
- **实现**：无 callback 返回 InvalidBuiltinRegistry。先在 live/constructing 中查 global 身份；若未归属，只从 live 列表选第一个 global=null 的 Context，将对象提升为全局类、写 ctx.global 并 ensureGlobalPayload。无候选则失败。准备成功或原已归属时调用 installer；anyerror 通过 @errorCast 收窄为 RuntimeError。
- **所有权 / 错误 / 调用**：ensureGlobalPayload 失败时清候选 Context 的 intrinsic bootstrap 与 global；installer 失败时仅对本次新认领的 Context 做该清理，原已归属 Context 不由本包装回滚。不会还原 global 已改变的类、属性或安装器全部副作用，不能称为完整事务。回调错误须属于声明的 RuntimeError，@errorCast 不是任意错误的安全映射。

### `JSRuntime.hasInterruptHandler` (`src/core/runtime.zig:4325`)

- **签名**：`pub fn hasInterruptHandler(self: JSRuntime) bool`。
- **作用**：是否安装了 handler。
- **实现**：`interrupt_handler != null`。
- **所有权 / 错误 / 调用**：cadence 仍跑，即使没有 handler。

### `JSRuntime.runInterruptHandler` (`src/core/runtime.zig:4329`)

- **签名**：`pub fn runInterruptHandler(self: *JSRuntime) bool`。
- **作用**：调 handler；无则 false。
- **实现**：`handler(self, interrupt_context)`。
- **所有权 / 错误 / 调用**：同步转发 handler 的 bool，不自行抛异常、停止 VM 或重设中断计数器，也不检查线程或重入。正常 pollInterruptSlow 路径由上层解释中断请求。

### `JSRuntime.setCanBlock` (`src/core/runtime.zig:4334`)

- **签名**：`pub fn setCanBlock(self: *JSRuntime, can_block: bool) void`。
- **作用**：设置供阻塞操作调用方查询的 can_block 标志。
- **实现**：字段。
- **所有权 / 错误 / 调用**：不停止或取消已经发生的阻塞；Runtime 的 waitForHostCompletion 包装本身不检查此标志，是否允许等待由调用者控制。

### `JSRuntime.canBlock` (`src/core/runtime.zig:4338`)

- **签名**：`pub fn canBlock(self: JSRuntime) bool`。
- **作用**：读上项。
- **实现**：字段。
- **所有权 / 错误 / 调用**：Atomics.wait。

### `JSRuntime.signalHostCompletion` (`src/core/runtime.zig:4342`)

- **签名**：`pub fn signalHostCompletion(self: *JSRuntime, io: std.Io) void`。
- **作用**：设置宿主完成事件以唤醒等待方；信号本身不携带任务或 JS 状态。
- **实现**：`host_completion_event.set(io)`。
- **所有权 / 错误 / 调用**：事件操作交给传入的 std.Io；此包装不执行完成回调、转移 JS 对象或检查 owner。生产者状态发布与消费者 reset 须采用匹配的同步协议，不能仅凭一次 set 推断具体任务已消费。

### `JSRuntime.resetHostCompletionSignal` (`src/core/runtime.zig:4346`)

- **签名**：`pub fn resetHostCompletionSignal(self: *JSRuntime) void`。
- **作用**：清唤醒。
- **实现**：`event.reset()`。
- **所有权 / 错误 / 调用**：这里只 reset 事件，不加 mutex 或验证线程，也不清任务队列；调用方必须协调状态检查与 reset，避免丢失并发完成通知。

### `JSRuntime.waitForHostCompletion` (`src/core/runtime.zig:4350`)

- **签名**：`pub fn waitForHostCompletion(self: *JSRuntime, io: std.Io) void`。
- **作用**：不可取消地等信号。
- **实现**：`waitUncancelable`。
- **所有权 / 错误 / 调用**：包装不检查 can_block 或 owner，不消费任务、不自动 reset 信号。返回表示事件等待完成，具体完成状态仍由上层读取。

### `JSRuntime.waitForHostCompletionUntil` (`src/core/runtime.zig:4354`)

- **签名**：`pub fn waitForHostCompletionUntil(self: *JSRuntime, io: std.Io, deadline: std.Io.Timestamp) bool`。
- **作用**：限时等；超时/取消返回 false。
- **实现**：将 deadline 标为 awake 时钟的绝对期限传给 waitTimeout，Timeout 或 Canceled 均返回 false，其余成功返回 true。
- **所有权 / 错误 / 调用**：不区分超时与取消；true 表示事件等待成功，不保证某个任务完成或已消费。与无限等待版本一样，不检查 can_block、不自动 reset，也不执行 JS。

---

## Finalization job 与延迟 native / class-payload 清理

Job FIFO 上的 finalization 是 JS 可观察的 FinalizationRegistry 回调。延迟 native 清理是宿主/插件析构，必须在 collector 空闲后跑。

### `JSRuntime.enqueueFinalizationJobForRealm` (`src/core/runtime.zig:4361`)

- **签名**：`pub fn enqueueFinalizationJobForRealm(self: *JSRuntime, realm: *context_mod.JSContext, callback: JSValue, held_value: JSValue) !void`。
- **作用**：可能分配地入队 FinalizationRegistry 清理。
- **实现**：assert 同 runtime，`job_queue.enqueueFinalization`。
- **所有权 / 错误 / 调用**：扩容错误传播；这里只入队，不执行或验证 callback 可调用性。realm 归属以 debug.assert 检查；入队成功后的 job 持有边由队列根扫描负责，失败不会产生已排队任务。

### `JSRuntime.enqueueFinalizationJobReserved` (`src/core/runtime.zig:4368`)

- **签名**：`pub fn enqueueFinalizationJobReserved( self: *JSRuntime, realm: *context_mod.JSContext, callback: JSValue, held_value: JSValue, ) void`。
- **作用**：对着注册时 reserved 的槽提交，无分配。
- **实现**：`enqueueReserved(Job.initFinalization(...))`。
- **所有权 / 错误 / 调用**：要求之前已有未消费的容量预留，本次消耗一个 reservation；预留不是固定 FIFO 位置，任务在调用时追加。realm 归属以断言检查，函数不运行 callback 或自行创建预留。

### `JSRuntime.clearPendingFinalizationJobs` (`src/core/runtime.zig:4378`)

- **签名**：`pub fn clearPendingFinalizationJobs(self: *JSRuntime) void`。
- **作用**：丢掉所有 finalization 条目（teardown，不再跑 JS 回调）。
- **实现**：`firstIndexOfKind(.finalization)` + `takeAt` + deinit。
- **所有权 / 错误 / 调用**：清除排队的 finalization job，不影响其他种类 job，也不撤销已取出正在执行的任务；不会调用这些 JS callback。反复查找和移动队列元素，不能视为固定成本操作。

### `JSRuntime.pendingFinalizationJobCountForTest` (`src/core/runtime.zig:4385`)

- **签名**：`pub fn pendingFinalizationJobCountForTest(self: JSRuntime) usize`。
- **作用**：finalization 条目数。
- **实现**：`countKind(.finalization)`。
- **所有权 / 错误 / 调用**：test-only。

### `JSRuntime.enqueueDeferredNativeCleanup` (`src/core/runtime.zig:4390`)

- **签名**：`pub fn enqueueDeferredNativeCleanup(self: *JSRuntime, finalizer: host_function.ExternalFinalizer, ptr: *anyopaque) !void`。
- **作用**：排队宿主 finalizer。
- **实现**：ensure 容量，追加 NativeCleanupJob。
- **所有权 / 错误 / 调用**：扩容失败不入队、不执行 finalizer；调用方负责失败路径的资源处理。成功后仅保存回调和 ptr，不复制其资源、不去重、不检查线程或 GC 阶段。

### `JSRuntime.enqueueDeferredClassPayloadFinalizer` (`src/core/runtime.zig:4400`)

- **签名**：`pub fn enqueueDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) !bool`。
- **作用**：未预留槽时排队 class payload finalizer。无 destruction plan 或 pin 失败返回 false。
- **实现**：ensure 容量含 reserved，pin callbacks，填 job。
- **所有权 / 错误 / 调用**：true 才表示任务已保存并 pin 对应代际回调；false 不清理传入 payload，也不消费 reservation。pin 失败发生在扩容之后，false 仍可能留下扩大的容量；分配错误传播。object_identity 是记录的数值，不是被此函数保活的对象指针。

### `JSRuntime.reserveDeferredClassPayloadFinalizerSlot` (`src/core/runtime.zig:4418`)

- **签名**：`pub fn reserveDeferredClassPayloadFinalizerSlot(self: *JSRuntime) !void`。
- **作用**：同时预留 finalizer 队列容量及入队前 payload-root 登记容量，使之后的队列存储无需再分配；不保证回调代际 pin 一定成功。
- **实现**：先确保 queued + reserved + 1 的 finalizer 容量，再确保 reserved + 1 的 root 容量，均成功后饱和递增 reserved。第二步失败只通过 errdefer 尝试释放空 finalizer buffer，不完整回滚所有容量变化。
- **所有权 / 错误 / 调用**：不发布 payload 根、不 pin class 回调、不绑定具体对象。成功 reservation 必须由释放或 reserved 入队路径消费；payload 初始化完成后另行 registerReservedDeferredClassPayloadRoot。

### `JSRuntime.releaseDeferredClassPayloadFinalizerSlot` (`src/core/runtime.zig:4430`)

- **签名**：`pub fn releaseDeferredClassPayloadFinalizerSlot(self: *JSRuntime) void`。
- **作用**：放弃 reservation。
- **实现**：reserved -= 1，尝试释放空 buffer。
- **所有权 / 错误 / 调用**：要求存在未消费 reservation，不自行搜索或撤销对应 payload root，不执行析构；调用方须先处理相应根生命周期，不能重复释放。

### `JSRuntime.registerReservedDeferredClassPayloadRoot` (`src/core/runtime.zig:4440`)

- **签名**：`pub fn registerReservedDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void`。
- **作用**：payload 初始化后把 wrapper 的声明边当根，直到 queued job 接管。
- **实现**：断言 reserved 与容量，追加到 `deferred_class_payload_roots`。
- **所有权 / 错误 / 调用**：不分配、不消费 reservation、不去重或验证 payload 初始化状态；调用方负责满足这些前提。登记供 traceClassPayloadRootEdges 扫描 payload 边，不把 wrapper 本身变成不可回收的强根。

### `JSRuntime.unregisterDeferredClassPayloadRoot` (`src/core/runtime.zig:4451`)

- **签名**：`pub fn unregisterDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void`。
- **作用**：queued 节点已拷走 payload/mark 后结束预入队根寿命。
- **实现**：swap-remove。找不到 unreachable。
- **所有权 / 错误 / 调用**：只移除首个匹配 root，不消费 reservation、不释放 wrapper/payload 或 unpin 回调；不保持数组顺序。队列接管时调用方须先建立替代根，避免提前撤掉唯一保护。

### `JSRuntime.enqueueReservedDeferredClassPayloadFinalizer` (`src/core/runtime.zig:4466`)

- **签名**：`pub fn enqueueReservedDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, generation: u64, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) bool`。
- **作用**：消耗 reservation，无分配入队。pin 失败返回 false（仍消耗 reserved）。
- **实现**：reserved -= 1；pin callbacks；写槽。
- **所有权 / 错误 / 调用**：false 也已经消费一个 reservation，且不会执行 payload 清理；调用方负责失败处理及原 root 的撤销。成功 job 保存回调与 payload 副本并持有代际 pin，本函数不自动 unregister 原 root。

### `JSRuntime.hasDeferredNativeCleanups` (`src/core/runtime.zig:4489`)

- **签名**：`pub fn hasDeferredNativeCleanups(self: *const JSRuntime) bool`。
- **作用**：是否有 native 或 class-payload 延迟工作。
- **实现**：两队列长度。
- **所有权 / 错误 / 调用**：只看排队长度，不包括已取出正在执行的 job、未消费 reservation 或预入队 payload roots；返回 false 不等于全部清理生命周期已经结束。

### `JSRuntime.hasPendingDeferredClassPayloadFinalizers` (`src/core/runtime.zig:4493`)

- **签名**：`pub fn hasPendingDeferredClassPayloadFinalizers(self: JSRuntime) bool`。
- **作用**：队列或正在跑的 active job。
- **实现**：len 或 active 非空。
- **所有权 / 错误 / 调用**：包含活动 payload finalizer，但不计 native cleanup、预留槽或预入队 roots；不同于 hasDeferredNativeCleanups 的范围。

### `JSRuntime.isActiveDeferredClassPayloadFinalizerCallback` (`src/core/runtime.zig:4498`)

- **签名**：`pub fn isActiveDeferredClassPayloadFinalizerCallback(self: *const JSRuntime, object_identity: *anyopaque) bool`。
- **作用**：该指针是否就是当前正在跑的 job 的 identity 槽（重入识别）。
- **实现**：与 `&active.object_identity` 比较。
- **所有权 / 错误 / 调用**：比较的是活动 job 中 identity 字段的地址，不是该字段保存的原对象地址或 identity 数值；无活动 job 返回 false，不解引用传入指针。

### `JSRuntime.runDeferredNativeCleanupBudgeted` (`src/core/runtime.zig:4503`)

- **签名**：`pub fn runDeferredNativeCleanupBudgeted(self: *JSRuntime, max_jobs: usize) usize`。
- **作用**：最多跑 max 个 native cleanup。重入返回 0。
- **实现**：FIFO memmove 摘头，`job.run()`，计数。空则释放 buffer。
- **所有权 / 错误 / 调用**：max_jobs=0 或本队列正在 draining 时返回 0。先摘头再同步回调，回调新增任务可在剩余预算内继续执行；预算是任务数，不是耗时上限。此函数本身不检查 owner、gc_running 或 phase，安全调用边界由上层负责；返回数是本轮实际执行数。

### `JSRuntime.runDeferredClassPayloadFinalizerBudgeted` (`src/core/runtime.zig:4525`)

- **签名**：`pub fn runDeferredClassPayloadFinalizerBudgeted(self: *JSRuntime, max_jobs: usize) usize`。
- **作用**：预算跑 payload finalizer。
- **实现**：摘头到局部 `job`，`runDeferredClassPayloadFinalizerJob`（先发表 active）。
- **所有权 / 错误 / 调用**：max_jobs=0 或本队列重入则返回 0；FIFO 摘头后发布局部活动 job，回调新入队任务可在剩余数量预算内执行。完成后饱和增加运行计数并尝试释放空 buffer；本包装不检查 GC 阶段，预算不限制单个回调耗时。

### `JSRuntime.drainDeferredNativeCleanups` (`src/core/runtime.zig:4547`)

- **签名**：`pub fn drainDeferredNativeCleanups(self: *JSRuntime) void`。
- **作用**：反复以最大任务数预算执行 native 队列，直到执行器返回 0。
- **实现**：while budgeted(maxInt) ≠ 0。
- **所有权 / 错误 / 调用**：正在 draining 时重入会直接停止，不能据返回 void 判定队列必空；若回调不断追加任务，可能持续执行。没有 GC 阶段或 owner 检查，不提供时间上限。

### `JSRuntime.drainDeferredClassPayloadFinalizers` (`src/core/runtime.zig:4552`)

- **签名**：`pub fn drainDeferredClassPayloadFinalizers(self: *JSRuntime) void`。
- **作用**：反复以最大任务数预算执行 payload finalizer 队列，直到执行器返回 0。
- **实现**：同 while。
- **所有权 / 错误 / 调用**：安全边界及 teardown 调用；本函数自身不验证 GC 空闲。重入可返回而仍有排队任务，回调持续入队则不能保证有限时间内结束。

### `JSRuntime.drainDeferredClassPayloadFinalizersAtSafeBoundary` (`src/core/runtime.zig:4562`)

- **签名**：`inline fn drainDeferredClassPayloadFinalizersAtSafeBoundary(self: *JSRuntime) void`。
- **作用**：仅在 collector 回到 idle 后交付用户回调，避免把 queued payload 和停着的 morgue 带进新 mark 周期。
- **实现**：空/gc_running/phase≠none/已 draining 则返回，否则 `drainDeferredClassPayloadFinalizers`。
- **所有权 / 错误 / 调用**：pollGC、tryRun、对象分配边界。回调重入被 active-job 拒绝，其 GC 请求保持 pending。

### `JSRuntime.runDeferredClassPayloadFinalizerJob` (`src/core/runtime.zig:4569`)

- **签名**：`fn runDeferredClassPayloadFinalizerJob(self: *JSRuntime, job: *DeferredClassPayloadFinalizer) void`。
- **作用**：发表 active 槽再 `job.run`。
- **实现**：assert active==null；defer 清。
- **所有权 / 错误 / 调用**：活动指针借用调用方的 job 存储，job.run 期间须保持稳定；该槽供根扫描及重入识别使用。函数只断言不存在另一个活动 job，不检查 collector 空闲，也不自行从队列移除或释放 job 存储。

### `JSRuntime.pendingDeferredNativeCleanupCountForTest` (`src/core/runtime.zig:4576`)

- **签名**：`pub fn pendingDeferredNativeCleanupCountForTest(self: JSRuntime) usize`。
- **作用**：native 队列长度。
- **实现**：test-only。
- **所有权 / 错误 / 调用**：只读队列长度，不分配、不排空队列、无 error set，非 test 构建 `@compileError`。队列里的条目仍归 runtime 所有（由 `ensureDeferredNativeCleanupCapacity` 分配的缓冲），本函数不取走也不释放。调用方：`src/tests/core.zig:7359`、`:7366`、`:7373` 等，用来断言延迟清理被逐个排掉。

### `JSRuntime.pendingDeferredClassPayloadFinalizerCountForTest` (`src/core/runtime.zig:4581`)

- **签名**：`pub fn pendingDeferredClassPayloadFinalizerCountForTest(self: JSRuntime) usize`。
- **作用**：payload finalizer 队列长度（不含 active）。
- **实现**：test-only。
- **所有权 / 错误 / 调用**：同族：只读 `deferred_class_payload_finalizers.len`，不分配、无 error set，非 test 构建 `@compileError`。读数**不含正在运行的那一条**——`active_deferred_class_payload_finalizer` 在 `src/core/runtime.zig:4578` 的 `defer` 里才清空，所以 finalizer 执行期间总数会比队列长度多一。调用方：`src/tests/core.zig:3913`、`:3945`、`:3972` 等。

### `JSRuntime.ensureDeferredNativeCleanupCapacity` (`src/core/runtime.zig:4586`)

- **签名**：`fn ensureDeferredNativeCleanupCapacity(self: *JSRuntime, min_capacity: usize) !void`。
- **作用**：确保 native cleanup 数组至少有 min_capacity 个存储位置，不增加有效任务数。
- **实现**：已有容量足够则返回，否则从 8 或旧容量两倍起继续倍增；分配、复制有效项，切换切片和容量后释放旧 backing。
- **所有权 / 错误 / 调用**：分配失败保留原数组；成功增长使旧数组元素地址失效，但不执行或复制回调所指资源。倍增算术没有转为可恢复的溢出错误，不能承诺任意 usize 请求都只返回 OOM。

### `JSRuntime.releaseEmptyDeferredNativeCleanupBuffer` (`src/core/runtime.zig:4602`)

- **签名**：`fn releaseEmptyDeferredNativeCleanupBuffer(self: *JSRuntime) void`。
- **作用**：len=0 时释放 backing。
- **实现**：非空直接返回；空且容量为 0 时规范为空切片，否则先重置数组和容量再释放完整 backing。
- **所有权 / 错误 / 调用**：不执行任务或释放任务 ptr；只释放已经没有有效项的数组存储。

### `JSRuntime.ensureDeferredClassPayloadFinalizerCapacity` (`src/core/runtime.zig:4614`)

- **签名**：`fn ensureDeferredClassPayloadFinalizerCapacity(self: *JSRuntime, min_capacity: usize) !void`。
- **作用**：payload finalizer 数组增长。
- **实现**：容量足够直接返回；否则从 8 或旧容量两倍起增长至至少 min_capacity，复制有效 job，保留原 len，替换 backing 后释放旧数组。
- **所有权 / 错误 / 调用**：不增加 reservation、不 pin 回调、不执行 payload 清理。分配失败保留原表，成功增长使借用旧元素的地址失效；容量倍增未提供可恢复溢出处理。

### `JSRuntime.ensureDeferredClassPayloadRootCapacity` (`src/core/runtime.zig:4630`)

- **签名**：`fn ensureDeferredClassPayloadRootCapacity(self: *JSRuntime, min_capacity: usize) !void`。
- **作用**：预入队 payload 根数组增长。
- **实现**：容量不足时从 8 或旧容量两倍起倍增；分配对象指针数组，复制有效指针并保留 len，再释放旧 backing。
- **所有权 / 错误 / 调用**：reserve 路径使用；只准备存储，不发布根、不复制或保活指向的对象。分配失败保留原数组，倍增无可恢复溢出检查。

### `JSRuntime.releaseEmptyDeferredClassPayloadFinalizerBuffer` (`src/core/runtime.zig:4644`)

- **签名**：`fn releaseEmptyDeferredClassPayloadFinalizerBuffer(self: *JSRuntime) void`。
- **作用**：队列空 **且** 无 reservation 才释放。
- **实现**：队列非空或 reserved 非零时返回；否则规范为空数组，原容量非零时先清容量再释放 backing。
- **所有权 / 错误 / 调用**：不运行 job、不释放代际 pin；已有 reservation 会保留空队列的存储。只处理排队数组，不操作已取出的活动 job。

### `JSRuntime.releaseEmptyDeferredClassPayloadRootBuffer` (`src/core/runtime.zig:4657`)

- **签名**：`fn releaseEmptyDeferredClassPayloadRootBuffer(self: *JSRuntime) void`。
- **作用**：根数组同样：空且无 reservation 才 free。
- **实现**：roots 非空或 reserved 非零时返回；否则重置为空切片与零容量，并释放原对象指针数组。
- **所有权 / 错误 / 调用**：unregister/release slot 使用；不析构数组曾指向的 wrapper 或 payload，也不消费 reservation。

---

## 借用弱清理身份窗、辅助 append、随机种子

sweep 弱集合时，borrowed 指针可能指向正在被清的身份。窗口内列出这些身份，避免 use-after-free 式的再注册。

### `JSRuntime.beginBorrowedWeakCleanup` (`src/core/runtime.zig:4670`)

- **签名**：`pub fn beginBorrowedWeakCleanup(self: *JSRuntime) void`。
- **作用**：打开清理窗，清空身份集/切片但保留 capacity。
- **实现**：assert !active；set.clearRetainingCapacity；len=0。
- **所有权 / 错误 / 调用**：断言禁止重复 begin，但不实现嵌套窗口栈；不 retain/release 身份或清理目标对象。旧数组字节可以仍在 backing 中，只是有效长度归零。

### `JSRuntime.endBorrowedWeakCleanup` (`src/core/runtime.zig:4680`)

- **签名**：`pub fn endBorrowedWeakCleanup(self: *JSRuntime) void`。
- **作用**：关窗，清集，len=0。
- **实现**：active=false。
- **所有权 / 错误 / 调用**：与 begin 配对；不断言原 active 为真，重复 end 可清空状态。保留集合和数组容量，不销毁对象或释放身份引用。

### `JSRuntime.borrowedWeakCleanupActive` (`src/core/runtime.zig:4689`)

- **签名**：`pub fn borrowedWeakCleanupActive(self: *const JSRuntime) bool`。
- **作用**：是否在窗内。
- **实现**：字段。
- **所有权 / 错误 / 调用**：弱操作。

### `JSRuntime.borrowedWeakCleanupIdentityCount` (`src/core/runtime.zig:4693`)

- **签名**：`pub fn borrowedWeakCleanupIdentityCount(self: *const JSRuntime) usize`。
- **作用**：读取身份记录数组的有效长度，不是去重身份数。
- **实现**：切片 len。
- **所有权 / 错误 / 调用**：可作为后续符号身份匹配的起始水位；不检查 active，重复入队也累加长度。

### `JSRuntime.enqueueBorrowedWeakCleanupIdentity` (`src/core/runtime.zig:4697`)

- **签名**：`pub fn enqueueBorrowedWeakCleanupIdentity(self: *JSRuntime, identity: usize) !void`。
- **作用**：追加弱清理身份记录；偶数身份同时进入哈希集合，奇数身份只存数组。
- **实现**：先确保数组容量，再对偶数 identity 执行 set.put，成功后扩有效长度并写入 identity。
- **所有权 / 错误 / 调用**：不检查 active、不拒绝 0、不对数组去重、不 retain 身份。set 写入失败时有效数组长度不变，但前一步已扩大的容量保留。重复偶数在集合中仍是一键，在数组中可有多项。

### `JSRuntime.borrowedWeakCleanupIdentityMatches` (`src/core/runtime.zig:4707`)

- **签名**：`pub fn borrowedWeakCleanupIdentityMatches(self: *const JSRuntime, identity: usize) bool`。
- **作用**：身份是否在本窗。
- **实现**：0 假；偶 `set.contains`；奇从尾扫描切片。
- **所有权 / 错误 / 调用**：不检查 active 或实际目标存活；即便 0 被入队也不匹配。偶数查询依赖集合，奇数是从尾到头的线性相等比较。

### `JSRuntime.borrowedWeakCleanupIdentityMatchesSlice` (`src/core/runtime.zig:4720`)

- **签名**：`pub inline fn borrowedWeakCleanupIdentityMatchesSlice(self: *const JSRuntime, start_index: usize, identity: usize) bool`。
- **作用**：只看 `start_index` 之后新入队的符号身份（对象仍走 set）。
- **实现**：0 返回 false；偶数查询完整集合并忽略 start_index；奇数逆序扫描 [start_index,len)。start_index >= len 时奇数直接返回 false。
- **所有权 / 错误 / 调用**：符号范围包含 start_index 位置，不是严格大于该索引。对对象不是局部切片查询，也不验证水位有效性或窗口 active 状态。

### `JSRuntime.clearBorrowedWeakCleanupIdentities` (`src/core/runtime.zig:4733`)

- **签名**：`pub fn clearBorrowedWeakCleanupIdentities(self: *JSRuntime) void`。
- **作用**：teardown：释放身份数组，清 set，关窗。
- **实现**：保存数组完整容量切片，清集合但保留其容量，清空数组/容量并置 active=false，最后释放旧数组 backing。
- **所有权 / 错误 / 调用**：只释放身份数组，不释放哈希集合 backing 或身份目标；集合自身由 Runtime.deinit 另行 deinit。不同于 begin/end，这里不会保留数组容量。

### `JSRuntime.ensureBorrowedWeakCleanupIdentityCapacity` (`src/core/runtime.zig:4742`)

- **签名**：`fn ensureBorrowedWeakCleanupIdentityCapacity(self: *JSRuntime, min_capacity: usize) !void`。
- **作用**：16 起倍增。
- **实现**：容量够则返回；不足时从 16 或旧容量两倍起增长，分配 usize 数组、复制有效项、保留 len，切换存储后释放旧 backing。
- **所有权 / 错误 / 调用**：不修改哈希集合或 active 状态。分配失败保留旧数组，成功使借用旧数组的切片失效；容量倍增算术没有可恢复溢出处理。

### `settlePendingDestructionForGateStats` (`src/core/runtime.zig:4765`)

- **签名**：`pub fn settlePendingDestructionForGateStats(rt: *JSRuntime) void`。
- **作用**：CLI drain 完 jobs 后的门禁结算：不新开收集、不藏开着的标记周期，只完成不可逆销毁事务，让门禁把 morgue 退出不变式与自然终点分开断言。模块函数而非方法，以免扩大公共嵌入 API。
- **实现**：assert owner、idle、!gc_running、phase none、无 active finalizer。无 morgue 则只 audit。否则 `finishPendingDestruction` + `finishDoomedCompletion(0)`。
- **所有权 / 错误 / 调用**：test262/gate。

### `appendRuntimeObject` (`src/core/runtime.zig:4782`)

- **签名**：`fn appendRuntimeObject(account: *memory.MemoryAccount, slice: *[]*Object, capacity: *usize, item: *Object) !void`。
- **作用**：`[]*Object` 增长（borrowed holders），初始 cap 64。
- **实现**：len 等于 capacity 时分配初始 64 或两倍容量，复制有效指针、替换切片并释放旧 backing，随后扩 len 并追加 item。
- **所有权 / 错误 / 调用**：分配失败保留旧数组，不消费 item；不复制、保活或释放对象，也不去重。调用方须保证 len<=capacity、分配账户匹配；倍增未提供可恢复溢出处理。

### `appendRuntimeRootSlot` (`src/core/runtime.zig:4799`)

- **签名**：`fn appendRuntimeRootSlot(account: *memory.MemoryAccount, slice: *[]*RootSlot, capacity: *usize, item: *RootSlot) !void`。
- **作用**：local/persistent 槽指针数组，初始 4。
- **实现**：满时分配初始 4 或两倍容量，复制有效槽指针并释放旧 backing，再将 item 追加到有效切片。
- **所有权 / 错误 / 调用**：createRootSlot 使用；本函数不初始化或销毁 RootSlot。失败保留数组且由调用方清理尚未登记的槽；数组增长不移动槽本身，但使借用旧指针数组的切片失效。

### `appendRuntimeWeakRootSlot` (`src/core/runtime.zig:4816`)

- **签名**：`fn appendRuntimeWeakRootSlot(account: *memory.MemoryAccount, slice: *[]*WeakRootSlot, capacity: *usize, item: *WeakRootSlot) !void`。
- **作用**：弱槽指针数组，初始 4。
- **实现**：满时分配初始 4 或两倍容量，复制有效弱槽指针，替换 backing 并释放旧数组，再追加 item。
- **所有权 / 错误 / 调用**：createWeakRootSlot 使用；不 retain 弱身份、不建立目标强根、不执行 callback。分配失败不消费 item，成功扩容只搬移指针数组；容量算术依赖有效且可表示的请求大小。

### `newRealmRandomSeed` (`src/core/runtime.zig:4943`)

- **签名**：`pub fn newRealmRandomSeed() u64`。
- **作用**：`Math.random` 种子：墙钟微秒（qjs `js_random_init`，quickjs.c:47373，gettimeofday）。0 则 1。
- **实现**：`@bitCast(platform_clock.realtimeMicros())`。
- **所有权 / 错误 / 调用**：JSContext.initConstructing 用其初始化各自的 random_state。相同微秒可得到相同种子，不保证跨 realm 唯一，也不是密码学随机源；负的 i64 时间按位解释为 u64，不取绝对值。0 才替换为 1。

## 覆盖核对

- 清单函数数: 303
- 本文标题覆盖: 303
- 未覆盖标题: 无。以上是函数标题清单核对，不等于全部非测试代码的语义准确性证明；类型、字段、调用前提及跨模块行为仍需逐项对照源码。
