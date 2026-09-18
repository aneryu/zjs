# 10 — 容器、全局槽、剖析、bulk fill

本分册覆盖 `src/core/` 里不带 Runtime/Context 所有权的小工具：侵入式链表、类型擦除 ArrayList/heap、全局 atom/value 槽、opcode 剖析、以及编译器用的向量填充。`src/core/root.zig` 是零函数文件，文件级职责写在主册 [10-core-runtime.md](10-core-runtime.md)。`bulk_memory.fillByte` 见下文。

---

## `src/core/list.zig` — 无分配侵入式双向链表

QuickJS 用 `struct list_head`（`list.h`）把对象、job、weak 持有者串起来。zjs 的 `List`/`Node` 是同一形状的核心工具：不分配、不追踪 GC、不携带 payload。嵌入者提供 `Node` 并保证链接期间节点存活。启用断言时检查节点是否已有两条链接；调用方仍须保证环的完整性与地址稳定。

### 类型

`Node`：`prev` / `next` 均为 `?*Node`，默认 `null`。两端都非空才算已链接。

`List`：哨兵 `head: Node`。空表时 `head.prev == head.next == &head`。

### `Node.isLinked` (`src/core/list.zig:13`)

- **签名**：`pub fn isLinked(self: Node) bool`。
- **作用**：检查两条链接是否均非null。
- **实现**：返回prev != null and next != null；初始化后的哨兵也返回true。
- **所有权 / 错误 / 调用**：不是成员资格或环完整性验证；半链接节点返回false，不修复状态。

### `List.init` (`src/core/list.zig:21`)

- **签名**：`pub fn init(self: *List) void`。
- **作用**：将哨兵初始化为空环。
- **实现**：prev和next都指向self.head。
- **所有权 / 错误 / 调用**：无分配；已经链接的表不可用它清空并释放节点。初始化后List地址必须稳定，按值复制不会重定位自指针。

### `List.isEmpty` (`src/core/list.zig:26`)

- **签名**：`pub fn isEmpty(self: *const List) bool`。
- **作用**：判断哨兵的后继是否为自身。
- **实现**：只比较head.next和&head。
- **所有权 / 错误 / 调用**：要求已初始化且环有效；未初始化默认值返回false，不代表其中有合法节点。

### `List.add` (`src/core/list.zig:30`)

- **签名**：`pub fn add(self: *List, node: *Node) void`。
- **作用**：把节点插到队头。
- **实现**：以哨兵和当前head.next调用insertBetween。
- **所有权 / 错误 / 调用**：要求表已初始化、节点未链接且地址稳定；不分配、不接管承载结构的释放。

### `List.addTail` (`src/core/list.zig:34`)

- **签名**：`pub fn addTail(self: *List, node: *Node) void`。
- **作用**：把节点插到队尾。
- **实现**：以当前head.prev和哨兵调用insertBetween。
- **所有权 / 错误 / 调用**：与add相同的有效性和生命周期前提；不自行root节点内的GC值。

### `List.remove` (`src/core/list.zig:38`)

- **签名**：`pub fn remove(node: *Node) void`。
- **作用**：从有效双向环摘掉一个节点。
- **实现**：prev或next为null便返回；否则连接两侧邻居，再清空自己的两条链接。
- **所有权 / 错误 / 调用**：对正常未链接节点幂等，但半链接状态会原样保留。不能用于移除表哨兵；不释放节点，也不验证邻居反向链接。

### `List.insertBetween` (`src/core/list.zig:47`)

- **签名**：`fn insertBetween(node: *Node, prev: *Node, next: *Node) void`。
- **作用**：在两个邻居之间接入节点。
- **实现**：assert(!node.isLinked())，随后设置prev.next、node.prev、node.next、next.prev。
- **所有权 / 错误 / 调用**：断言不是完整结构校验，半链接节点也可通过；关闭安全检查时不能依靠它拒绝双插。调用方保证邻居属于有效环、节点未链接。

## `src/core/array_list_erased.zig` — 类型擦除 ArrayList

Zig 0.16 的 `std.ArrayList(T).append` / `toOwnedSlice` 可能随元素类型产生多份实例。本文件把 grow / shrink-to-fit 收成按元素大小擦除的 `noinline` 走步，调用方仍是 typed inline 包装。`u8`/`u64` 站点继续走 std（含 GC pause sample）。**不是** GC `TraceHeader` 列表；用 `remap`/`rawAlloc`/`rawFree` 与元素对齐。

`addOneErased` / `toOwnedSliceErased` 是真正的 outline 实现，由 `append` / `toOwnedSlice` 调用。

### `ListItem` (`src/core/array_list_erased.zig:13`)

- **签名**：`fn ListItem(comptime ListPtr: type) type`。
- **作用**：在编译期取得列表items的元素类型。
- **实现**：读取指针child，再读取items字段类型的pointer.child。
- **所有权 / 错误 / 调用**：依赖指针与items字段的类型形状，不进行运行时检测；返回类型供两个typed包装使用。

### `append` (`src/core/array_list_erased.zig:19`)

- **签名**：`pub inline fn append( list: anytype, gpa: Allocator, item: ListItem(@TypeOf(list)), ) Allocator.Error!void`。
- **作用**：在列表尾部追加一个按值传入的元素。
- **实现**：编译期断言单对象指针及非零元素大小，按T大小/对齐调用addOneErased，然后向返回位置写入item。
- **所有权 / 错误 / 调用**：传入allocator必须匹配现有backing；成功扩容可能使旧切片/元素指针失效。OOM保留原列表；不调用元素析构或GC屏障，元素引用的生命周期由调用方处理。

### `addOneErased` (`src/core/array_list_erased.zig:47`)

- **签名**：`noinline fn addOneErased( ptr_slot: *[*]u8, len_slot: *usize, cap_slot: *usize, elem_size: usize, alignment: std.mem.Alignment, gpa: Allocator, ) Allocator.Error![*]u8`。
- **作用**：准备一个新元素位置并增加长度。
- **实现**：new_len=len+1；容量不足按growCapacity扩容，取旧len对应字节地址后写入new_len。
- **所有权 / 错误 / 调用**：长度加一依赖有效列表不能占满地址空间的前提；OOM不修改长度。返回未初始化位置供append立即赋值，并非独立GC分配接口。

### `growCapacity` (`src/core/array_list_erased.zig:41`)

- **签名**：`pub fn growCapacity(minimum: usize, elem_size: usize) usize`。
- **作用**：计算带初始余量的增长容量。
- **实现**：assert(elem_size!=0)，init_capacity=max(1,cache_line/elem_size)，返回minimum +| (minimum/2 + init_capacity)。
- **所有权 / 错误 / 调用**：外层为饱和加法，计算依据是请求的minimum而非旧capacity；无分配，结果仍需通过字节大小乘法检查。

### `ensureTotalCapacityPrecise` (`src/core/array_list_erased.zig:73`)

- **签名**：`fn ensureTotalCapacityPrecise( ptr_slot: *[*]u8, used_len: usize, cap_slot: *usize, elem_size: usize, alignment: std.mem.Alignment, gpa: Allocator, new_capacity: usize, ) Allocator.Error!void`。
- **作用**：必要时将元素容量扩到指定值。
- **实现**：已有容量足够则不动；检查旧/新容量乘元素大小，溢出报OOM。有旧块先rawRemap，失败再rawAlloc、复制used_len个元素字节、释放旧块；无旧块直接分配。
- **所有权 / 错误 / 调用**：保留元素对齐和allocator身份；新分配路径写undefined而非零初始化，remap成功路径不执行该填充。失败保留旧块及槽位；不运行元素构造/析构，GC记账取决于传入allocator而非本函数显式操作。

### `toOwnedSlice` (`src/core/array_list_erased.zig:114`)

- **签名**：`pub inline fn toOwnedSlice( list: anytype, gpa: Allocator, ) Allocator.Error![]ListItem(@TypeOf(list))`。
- **作用**：把列表backing转交为长度恰好等于已用元素数的切片。
- **实现**：保存元素数，委托擦除实现后按T对齐还原切片。成功时列表len/cap为0、ptr为undefined。
- **所有权 / 错误 / 调用**：要求非零大小元素及有效allocator匹配；返回切片由调用方使用同一allocator释放。失败保留列表；不深拷贝元素引用，也不释放引用目标。

### `toOwnedSliceErased` (`src/core/array_list_erased.zig:135`)

- **签名**：`noinline fn toOwnedSliceErased( ptr_slot: *[*]u8, len_slot: *usize, cap_slot: *usize, elem_size: usize, alignment: std.mem.Alignment, gpa: Allocator, ) Allocator.Error![]u8`。
- **作用**：完成backing缩容和所有权转移。
- **实现**：检查容量与长度的字节乘法。used为0则释放旧块，返回旧切片空前缀；非零先rawRemap，失败再分配、复制、释放。成功将ptr置undefined、len/cap置0。
- **所有权 / 错误 / 调用**：不向rawAlloc/rawRemap传零长度；空切片的指针可能来自已释放块，不能解引用。OOM保留列表及旧内存。内部返回字节切片，外层恢复元素对齐，不能擅用u8对齐释放非字节元素块。

## `src/core/sort_erased.zig` — 类型擦除 heap sort

`std.sort.heap` 的 `siftDown` 可能随元素类型产生多份实例。本文件把比较/交换收成 typed trampoline，walk 共享一份 `noinline heapContext` / `siftDown`。GC 的 `u64` pause-sample 与 registry 诊断堆仍走 std。

文件级 `heapContext` / `siftDown` 是真正的排序走步。

### 类型

`Ctx`：`payload: *anyopaque` + `lessThan` / `swap` 函数指针。

### `heap` (`src/core/sort_erased.zig:16`)

- **签名**：`pub inline fn heap( comptime T: type, items: []T, context: anytype, comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool, ) void`。
- **作用**：按比较器对切片原地执行不稳定堆排序。
- **实现**：栈上Wrapper保存items和context，将typed比较/交换包装成Ctx函数指针并同步调用heapContext。
- **所有权 / 错误 / 调用**：不自行分配，context按值复制；比较器应提供一致排序关系且不得使items存储失效。无可返回的错误通道，不承诺回调无分配；相等项次序不保留。

### `Wrapper.lessThan` (`src/core/sort_erased.zig:26`)

- **签名**：`fn lessThan(payload: *anyopaque, a: usize, b: usize) bool`。
- **作用**：将擦除后的索引比较转为元素比较。
- **实现**：将payload按对齐还原Wrapper，调用lessThanFn(sub_ctx,items[a],items[b])。
- **所有权 / 错误 / 调用**：索引合法性由排序主体保证；context及元素均按函数形参类型传递，不进行克隆或GC保护。

### `Wrapper.swap` (`src/core/sort_erased.zig:31`)

- **签名**：`fn swap(payload: *anyopaque, a: usize, b: usize) void`。
- **作用**：交换两个索引位置的元素值。
- **实现**：用局部tmp和三次赋值交换。
- **所有权 / 错误 / 调用**：无析构或GC屏障；a等于b时也是普通自交换，不分配。

### `heapContext` (`src/core/sort_erased.zig:47`)

- **签名**：`noinline fn heapContext(len: usize, ctx: Ctx) void`。
- **作用**：构建最大堆并逐次把堆顶移到尾部。
- **实现**：从len/2前一个节点逆序siftDown建堆，然后每次swap(0,i-1)并以i-1为排他bound下沉。
- **所有权 / 错误 / 调用**：空输入不调用swap；长度1会自交换一次再空范围下沉。无递归或自有堆分配，借用Ctx仅在调用期间有效。

### `siftDown` (`src/core/sort_erased.zig:63`)

- **签名**：`noinline fn siftDown(target: usize, bound: usize, ctx: Ctx) void`。
- **作用**：将target沿较大孩子方向下沉，维持最大堆。
- **实现**：checked mul计算2*cur，溢出即停止；左孩子为该值+1，超出bound停止。右孩子更大时选右；只有child严格小于cur才停止，否则交换并继续。
- **所有权 / 错误 / 调用**：相等项也会交换，因此不稳定；bound为排他上界。自身无递归/分配，比较与交换由借用回调执行。

## `src/core/bulk_memory.zig` — 向量填充

文件职责：给编译器中大型临时缓冲做整片字节填充。QuickJS 对应路径走平台 `memset`（`js_mallocz`、`compute_stack_size`）。源码显式表达16字节向量赋值与逐字节尾部；是否优于平台memset、最终是否使用向量指令需按实际目标和产物验证。

### `fillByte` (`src/core/bulk_memory.zig:8`)

- **签名**：`pub noinline fn fillByte(bytes: []u8, value: u8) void`。
- **作用**：用同一个字节值填满整个可写切片。
- **实现**：将value splat到16字节向量，以align(1)指针逐块赋值，剩余不足16字节逐字节写入。
- **所有权 / 错误 / 调用**：无需16字节地址对齐，不越过切片尾；空片段不写。无分配，无错误返回；具体机器指令由编译器与目标决定，不保证某条SIMD指令或固定性能。

## `src/core/global_slots.zig` — 调用方拥有的全局风格槽

给 realm/runtime 结构里「名字 atom + JSValue」数组提供按名/按 atom 访问。表本身不在本文件分配，也不自动注册为GC根。读返回槽里的位拷贝；替换直接写入新值，不接管查找名。镜像 QuickJS 全局变量格（`JSVarRef` / global var table）但不拥有表。只依赖 core。

### 类型

`Slot`：`name: atom.Atom`，`value: JSValue`。

### `getByName` (`src/core/global_slots.zig:20`)

- **签名**：`pub fn getByName(rt: *runtime.JSRuntime, slots: []const Slot, name: []const u8) !value.JSValue`。
- **作用**：按名字查询调用方持有的槽数组。
- **实现**：先rt.internAtom(name)，再以所得atom调用getByAtom。
- **所有权 / 错误 / 调用**：查找也可能新建atom及分配失败；不修改槽数组。返回JSValue位拷贝，不retain或自动注册根；槽名、槽值和返回值跨GC的可达性由上层负责。

### `getByAtom` (`src/core/global_slots.zig:27`)

- **签名**：`pub fn getByAtom(slots: []const Slot, atom_id: atom.Atom) value.JSValue`。
- **作用**：按atom身份线性查找第一个匹配槽。
- **实现**：比较slot.name == atom_id，命中返回slot.value，否则返回undefinedValue。
- **所有权 / 错误 / 调用**：不检查atom是否存活或属于同一runtime，也不intern。缺失与槽内本来为undefined不可区分；重复名字只读第一项，无分配。

### `setExistingByName` (`src/core/global_slots.zig:34`)

- **签名**：`pub fn setExistingByName(rt: *runtime.JSRuntime, slots: []Slot, name: []const u8, next_value: value.JSValue) !void`。
- **作用**：按名字替换第一个已存在槽的值。
- **实现**：intern名字后逐项扫描，命中直接把 next_value 位拷贝进槽并返回（旧的 `const duplicated` 中转已删）；未命中报TypeError，不创建槽。
- **所有权 / 错误 / 调用**：intern失败或未命中不改槽，但查找可改变atom表。没有retain/free、根注册或写屏障；调用方保护输入在intern期间以及写入后所需的存活窗口。TypeError在此不附消息。

## `src/core/profile.zig` — 线程局部 opcode / 引擎操作计数

可选诊断。调用方拥有 `OpcodeProfile`；`activate` 只把借用指针挂到当前线程并返回旧指针，便于词法恢复。256 项数组对齐字节 opcode 空间，是诊断 ABI/布局，不是 GC 状态。无 QuickJS 对应物。core 不能 import parser/exec。

### 类型与线程局部

- `max_opcode_count = 256`
- `OpcodeNameProvider = *const fn (u8) []const u8`
- `threadlocal opcode_name_provider`、`threadlocal active_profile`
- `OpcodeProfile` 字段：`count`/`nanos`/`slow_count`/`ic_*` 各 256；`ext0_sub_count` 有256项，为carrier子tag另记次数，当前VM在ext0分发时使用pc[1]索引；标量为value_dup_count、value_free_count、prop_lookup_count、global_lookup_count、alloc_count、call_frame_count，均默认0。pending_op默认no_pending_op=0xffff，pending_start_ns默认0；保留结算接口，但当前VM计数入口不打开时间区间。所有计数数组默认0，无原子同步

### `OpcodeProfile.recordOpcode` (`src/core/profile.zig:42`)

- **签名**：`pub fn recordOpcode(self: *OpcodeProfile, opcode: u8, elapsed_nanos: u64) void`。
- **作用**：记录一次opcode及给定时间增量。
- **实现**：count[opcode]与nanos[opcode]分别饱和相加。
- **所有权 / 错误 / 调用**：不读取时钟，不设置pending字段；时间来自调用方。计数不是原子操作，共享profile需要外部同步。

### `OpcodeProfile.noteDispatch` (`src/core/profile.zig:50`)

- **签名**：`pub fn noteDispatch(self: *OpcodeProfile, opcode: u8) void`。
- **作用**：只记录一次opcode分发。
- **实现**：count[opcode]饱和加1，不访问nanos。
- **所有权 / 错误 / 调用**：已有nanos保持原值，不会清零；当前VM分发调用该入口计次数，不在这里打开待计时间区间。

### `OpcodeProfile.noteCarrierSub` (`src/core/profile.zig:54`)

- **签名**：`pub fn noteCarrierSub(self: *OpcodeProfile, sub: u8) void`。
- **作用**：记录一个carrier子tag的次数。
- **实现**：ext0_sub_count[sub]饱和加1。
- **所有权 / 错误 / 调用**：数组为256项，所有u8索引均有效；不验证该tag是否已定义，也不增加物理opcode计数，外层分别调用。

### `OpcodeProfile.flushPendingDispatch` (`src/core/profile.zig:59`)

- **签名**：`pub fn flushPendingDispatch(self: *OpcodeProfile) void`。
- **作用**：结算调用方留下的一个待计时间区间。
- **实现**：pending_op为ffff直接返回；否则以nowNanos()-|pending_start_ns调用recordOpcode，再将pending_op置ffff。
- **所有权 / 错误 / 调用**：该操作同时增加count和nanos，不能将同一分发重复计数。有效pending_op必须可转u8；不清pending_start_ns。当前VM的noteDispatch不设置pending，因此通常无待结算区间。

### `OpcodeProfile.recordAlloc` (`src/core/profile.zig:65`)

- **签名**：`pub fn recordAlloc(self: *OpcodeProfile) void`。
- **作用**：显式增加分配事件计数。
- **实现**：alloc_count饱和加1。
- **所有权 / 错误 / 调用**：不执行分配或测量字节数；runtime另可将memory.profile_alloc_count指向该字段，由分配账户直接计数。

### `OpcodeProfile.recordValueDup` (`src/core/profile.zig:69`)

- **签名**：`pub fn recordValueDup(self: *OpcodeProfile) void`。
- **作用**：显式增加名为dup的诊断计数。
- **实现**：value_dup_count饱和加1。
- **所有权 / 错误 / 调用**：本方法不复制值、不retain；次数取决于插桩调用，不能证明当前GC采用引用计数。

### `OpcodeProfile.recordValueFree` (`src/core/profile.zig:73`)

- **签名**：`pub fn recordValueFree(self: *OpcodeProfile) void`。
- **作用**：显式增加名为free的诊断计数。
- **实现**：value_free_count饱和加1。
- **所有权 / 错误 / 调用**：不释放值；本文件无同名模块级转发，计数依赖外层显式调用。

### `OpcodeProfile.recordPropLookup` (`src/core/profile.zig:77`)

- **签名**：`pub fn recordPropLookup(self: *OpcodeProfile, is_global: bool) void`。
- **作用**：记录属性查找并可同时归为全局查找。
- **实现**：prop_lookup_count饱和加1，is_global时global_lookup_count也饱和加1。
- **所有权 / 错误 / 调用**：不执行查找，两类计数存在重叠，不能简单相加视为互斥事件总数。

### `OpcodeProfile.recordGlobalLookup` (`src/core/profile.zig:82`)

- **签名**：`pub fn recordGlobalLookup(self: *OpcodeProfile) void`。
- **作用**：单独增加全局查找计数。
- **实现**：global_lookup_count饱和加1，不动prop_lookup_count。
- **所有权 / 错误 / 调用**：不执行查找，也不核实是否已经由recordPropLookup计过。

### `OpcodeProfile.opcodeName` (`src/core/profile.zig:86`)

- **签名**：`pub fn opcodeName(opcode: u8) []const u8`。
- **作用**：查询当前线程安装的opcode名字提供器。
- **实现**：provider非null则调用并返回其切片，否则返回静态unknown字符串。
- **所有权 / 错误 / 调用**：无self参数；返回切片不复制，寿命由provider保证，接口并不强制为静态字符串。没有错误返回通道。

### `OpcodeProfile.totalOpcodeCount` (`src/core/profile.zig:91`)

- **签名**：`pub fn totalOpcodeCount(self: OpcodeProfile) u64`。
- **作用**：汇总物理opcode次数数组。
- **实现**：遍历256项count，以饱和加法求和。
- **所有权 / 错误 / 调用**：不包含ext0_sub_count，避免重复累计carrier子计数；按值读取，不清空或flush pending。

### `OpcodeProfile.totalOpcodeNanos` (`src/core/profile.zig:97`)

- **签名**：`pub fn totalOpcodeNanos(self: OpcodeProfile) u64`。
- **作用**：汇总已写入的opcode纳秒数组。
- **实现**：遍历256项nanos，以饱和加法求和。
- **所有权 / 错误 / 调用**：不读取当前时钟或flush pending；计次数路径不自动生成时间数据，零不能说明执行没有耗时。

### `setOpcodeNameProvider` (`src/core/profile.zig:105`)

- **签名**：`pub fn setOpcodeNameProvider(provider: ?OpcodeNameProvider) void`。
- **作用**：设置或清除当前线程的名字提供器。
- **实现**：直接写threadlocal opcode_name_provider。
- **所有权 / 错误 / 调用**：不返回旧回调，也不影响其它线程；null使opcodeName返回unknown。

### `activate` (`src/core/profile.zig:111`)

- **签名**：`pub fn activate(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：替换当前线程的剖析目标并返回旧指针。
- **实现**：保存active_profile，写入profile后返回旧值；null可停用TLS转发。
- **所有权 / 错误 / 调用**：只借用指针，不清计数、不flush pending、不设置Runtime.opcode_profile或内存账户。嵌套作用域由调用方保存并恢复旧值，profile须保持存活。

### `active` (`src/core/profile.zig:117`)

- **签名**：`pub fn active() ?*OpcodeProfile`。
- **作用**：读取当前线程的剖析目标。
- **实现**：直接返回active_profile。
- **所有权 / 错误 / 调用**：返回借用可变指针，不创建快照或延长寿命；TLS指针本身不使被指向profile自动线程安全。

### `recordValueDup` (`src/core/profile.zig:121`)

- **签名**：`pub fn recordValueDup() void`。
- **作用**：向当前线程目标转发一次dup诊断事件。
- **实现**：active_profile非null则调用其recordValueDup，否则空操作。
- **所有权 / 错误 / 调用**：不做值操作，不访问Runtime.opcode_profile；依赖TLS显式activate。

### `recordPropLookup` (`src/core/profile.zig:125`)

- **签名**：`pub fn recordPropLookup(is_global: bool) void`。
- **作用**：向当前线程目标转发属性查找事件。
- **实现**：active_profile非null则传递is_global到方法版，否则空操作。
- **所有权 / 错误 / 调用**：不执行查找；与方法版是不同函数身份，不能靠同名正文视为相互覆盖。

### `recordGlobalLookup` (`src/core/profile.zig:129`)

- **签名**：`pub fn recordGlobalLookup() void`。
- **作用**：向当前线程目标转发全局查找事件。
- **实现**：active_profile非null则调用方法版，否则空操作。
- **所有权 / 错误 / 调用**：只改目标诊断计数，不执行查找或GC操作。

### `nowNanos` (`src/core/profile.zig:133`)

- **签名**：`pub fn nowNanos() u64`。
- **作用**：取得平台单调时钟的纳秒读数。
- **实现**：委托platform_clock.monotonicNanos，该实现读取awake时钟并将非正结果钳为0。
- **所有权 / 错误 / 调用**：不是Unix时间戳，无错误返回；剖析差值使用饱和减避免负时间绕回。读取时钟成本不属于纯内存计数。

## 覆盖核对

- 清单函数数: 42（`src/core/array_list_erased.zig` 7 + `src/core/bulk_memory.zig` 1 + `src/core/global_slots.zig` 3 + `src/core/list.zig` 7 + `src/core/profile.zig` 19 + `src/core/sort_erased.zig` 5）
- 本文标题覆盖: 42
- 未覆盖: 无
