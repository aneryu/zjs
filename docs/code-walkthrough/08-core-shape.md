# 08 — `shape.zig`：隐藏类、FAM、转移表

QuickJS：`JSShapeProperty`/`JSShape`（quickjs.c:968-987），FAM 尺寸 `get_shape_size`（quickjs.c:5121）。zjs FAM 顺序是 **props 在前、桶在后**（qjs 相反）。`Shape` 64 字节 extern，header@0。

## 类型与常量

`initial_prop_size=2`，`initial_hash_size=4`，`initial_shape_hash_bits=4`（16 个 hashed shape 桶）。`no_property_hash=0`。`no_property_index: u26 = maxInt(u26)`（链终止；qjs `hash_next:26`）。

`Property`：`packed struct(u64)` — `hash_next:u26` / `flags:u6` / `atom_id`。`InitialProperty`：创建初始 shape 用的 `{atom_id, flags}`。

`ShapeOwnership`：`shared: u32`。第二个持有者 `markShared` 后永不清除。tracer 管寿命；此字只回答「能否原地改」。

`ShapeTraceListState`：`tagged_previous` 把 GC 链表前驱与冷 `is_hashed` 挤在一个指针宽里（头至少 2 字节对齐，低位可用）。

`ShapeColdState`：`deleted_prop_count: u32`（每次 append 容量决策都读；不把 is_hashed 打进这里，以免热循环多一次 mask）。

Shape 生命周期由 tracer 管理；源码开头那句「Refcounted object shapes」标题已改实。Shape 固定头64字节、对齐8，GC metadata 在头前；属性元数据占满 prop_size 容量，其后才是桶，props() 与 hashBuckets() 都借出可变 slice。

`Shape` 字段：header、trace_list_previous、ownership、hash、prop_hash_mask、prop_size、prop_count、cold_state、registry_hash_next（弱）、proto、identity。其后 FAM。

`Registry`：runtime shape-hash 表（只计 hashed shape，对齐 qjs `shape_hash_count`）。`next_identity` 从 1 起（0 初始化的站点永不命中）。`HashIndexError`：`ShapeHashLinkedButUnflagged` / `ShapeHashCountMismatch`。

转移哈希：`initialHash(proto)` 把 64 位原型指针两半折进种子 1；`transitionHash(seed, atom, flags)` 再折。属性桶：`atom_id & mask`（**不用** shape_hash）。

---

### `propertyCapacityForNeeded` (`src/core/shape.zig:31`)

- **签名**：`pub fn propertyCapacityForNeeded(needed: usize) usize`。
- **作用**：按需求计算从2起的二次幂容量。
- **实现**：needed=0返回0，否则从initial_prop_size倍增至>=needed。
- **所有权 / 错误 / 调用**：不分配、不检查26位属性索引上限，普通usize倍增也无溢出错误返回；调用方须限制需求。不能据此要求对象物理buffer容量永远等于Shape声明容量。

### `famRegionBytes` (`src/core/shape.zig:67`)

- **签名**：`fn famRegionBytes(prop_capacity: usize, bucket_count: usize) usize`。
- **作用**：计算属性记录和桶的尾部字节数。
- **实现**：sizeof(Property)*prop_capacity + sizeof(u32)*bucket_count。
- **所有权 / 错误 / 调用**：实际Property为8字节，桶为4字节；入参是usize，本函数没有checked算术，源码64位安全说明依赖来自u32容量/mask的调用范围。

### `ShapeTraceListState.init` (`src/core/shape.zig:94`)

- **签名**：`pub inline fn init(is_hashed: bool) @This()`。
- **作用**：创建无前驱的链状态并设置hashed位。
- **实现**：tagged_previous=@intFromBool(is_hashed)。
- **所有权 / 错误 / 调用**：不插入hash表或GC链，仅构造字段。

### `ShapeTraceListState.previous` (`src/core/shape.zig:98`)

- **签名**：`pub inline fn previous(self: *const @This()) ?*gc.Header`。
- **作用**：读取去掉标志位的前驱header地址。
- **实现**：清bit0；其余为0返回null，否则ptrFromInt。
- **所有权 / 错误 / 调用**：不验证地址存活或链一致性，不代表强边。

### `ShapeTraceListState.setPrevious` (`src/core/shape.zig:104`)

- **签名**：`pub inline fn setPrevious(self: *@This(), preceding: ?*gc.Header) void`。
- **作用**：更新前驱并保留hashed标志。
- **实现**：可空指针转地址，断言bit0为0，再与旧bit0合并。
- **所有权 / 错误 / 调用**：不修改邻居链接、不验证header kind。

### `ShapeTraceListState.isHashed` (`src/core/shape.zig:110`)

- **签名**：`pub inline fn isHashed(self: *const @This()) bool`。
- **作用**：查询bit0的hash成员标志。
- **实现**：tagged_previous & 1 != 0。
- **所有权 / 错误 / 调用**：仅读标志，不查询实际hash桶。

### `ShapeTraceListState.setHashed` (`src/core/shape.zig:114`)

- **签名**：`pub inline fn setHashed(self: *@This(), value: bool) void`。
- **作用**：修改hash成员标志并保留前驱。
- **实现**：清bit0后OR布尔值。
- **所有权 / 错误 / 调用**：不插入或摘除hash链，也不更新registry计数。

### `initialOwnership` (`src/core/shape.zig:127`)

- **签名**：`inline fn initialOwnership() ShapeOwnership`。
- **作用**：初始化未共享标志。
- **实现**：返回shared=0。
- **所有权 / 错误 / 调用**：hash表成员与shared是不同事实，不把hashed直接当作共享；原先只为与 initialTraceListState 调用形状对称而存在、随即被丢弃的 is_hashed 参数已删除。

### `initialTraceListState` (`src/core/shape.zig:131`)

- **签名**：`inline fn initialTraceListState(is_hashed: bool) ShapeTraceListState`。
- **作用**：初始化前驱/hash标志字段。
- **实现**：委托ShapeTraceListState.init(is_hashed)。
- **所有权 / 错误 / 调用**：前驱初始为空，无链表副作用。

### `initialColdState` (`src/core/shape.zig:135`)

- **签名**：`inline fn initialColdState(deleted_prop_count: u32) ShapeColdState`。
- **作用**：初始化删除计数。
- **实现**：返回deleted_prop_count字段等于参数。
- **所有权 / 错误 / 调用**：不验证计数范围或同步属性墓碑。

### `Shape.famBase` (`src/core/shape.zig:224`)

- **签名**：`inline fn famBase(self: *const Shape) [*]u8`。
- **作用**：取得紧随64字节Shape头的尾部起点。
- **实现**：constCast self为字节指针，再加sizeof(Shape)。
- **所有权 / 错误 / 调用**：返回可写借用地址，不分配；const self并不保证底层只读。

### `Shape.bucketCount` (`src/core/shape.zig:229`)

- **签名**：`inline fn bucketCount(self: *const Shape) usize`。
- **作用**：从mask取得桶数。
- **实现**：mask为no_property_hash(0)时返回0，否则usize(mask)+1。
- **所有权 / 错误 / 调用**：不验证mask是否2的幂减1，实际布局由构造器保证。

### `Shape.hashBuckets` (`src/core/shape.zig:233`)

- **签名**：`pub inline fn hashBuckets(self: *const Shape) []u32`。
- **作用**：借用满属性容量之后的桶数组。
- **实现**：桶数0返回空；否则famBase+sizeof(Property)*prop_size处转u32 slice。
- **所有权 / 错误 / 调用**：长度是bucketCount；不依赖prop_count，不验证尾部实际分配，返回可写slice。

### `Shape.props` (`src/core/shape.zig:240`)

- **签名**：`pub inline fn props(self: *const Shape) []Property`。
- **作用**：借用整个属性容量区域。
- **实现**：断言prop_size非0，从famBase构造长度prop_size的Property slice。
- **所有权 / 错误 / 调用**：包含未发布容量部分，不只是prop_count项；调用方须按有效数量限制遍历，也须遵守共享Shape写入协议。

### `Shape.famByteSize` (`src/core/shape.zig:252`)

- **签名**：`pub inline fn famByteSize(self: *const Shape) usize`。
- **作用**：计算本Shape尾部区域字节数。
- **实现**：famRegionBytes(prop_size,bucketCount)。
- **所有权 / 错误 / 调用**：不包含Shape头和metadata prefix；不读allocator。

### `Shape.allocationSize` (`src/core/shape.zig:259`)

- **签名**：`pub inline fn allocationSize(self: *const Shape) usize`。
- **作用**：计算Shape请求的结构与尾部字节数。
- **实现**：sizeof(Shape)+famByteSize。
- **所有权 / 错误 / 调用**：不含8字节metadata prefix，不是slab取整后的记账量。

### `Shape.accountedAllocationSize` (`src/core/shape.zig:267`)

- **签名**：`pub inline fn accountedAllocationSize(self: *const Shape) usize`。
- **作用**：取得实际记账payload字节量。
- **实现**：gcSlabAccountedPayload(self)有值时用其结果，否则allocationSize。
- **所有权 / 错误 / 调用**：依赖合法分配指针；区别于请求字节数，不另计metadata prefix。

### `Shape.markShared` (`src/core/shape.zig:273`)

- **签名**：`pub inline fn markShared(self: *Shape) void`。
- **作用**：设置不可逆的曾共享标志。
- **实现**：ownership.shared=1。
- **所有权 / 错误 / 调用**：不是引用计数加一、不延长GC寿命；此方法不克隆，后续mutation入口据此决定clone。

### `Shape.isShared` (`src/core/shape.zig:277`)

- **签名**：`pub inline fn isShared(self: *const Shape) bool`。
- **作用**：读取共享状态。
- **实现**：shared!=0。
- **所有权 / 错误 / 调用**：不计算当前拥有者个数；曾共享后即使只剩一持有者仍为true。

### `Shape.isHashed` (`src/core/shape.zig:281`)

- **签名**：`pub inline fn isHashed(self: *const Shape) bool`。
- **作用**：读取hash成员标志。
- **实现**：委托trace_list_previous.isHashed。
- **所有权 / 错误 / 调用**：不验证实际bucket成员关系，不等同isShared。

### `Shape.setHashed` (`src/core/shape.zig:285`)

- **签名**：`pub inline fn setHashed(self: *Shape, value: bool) void`。
- **作用**：修改hash成员标志。
- **实现**：委托trace_list_previous.setHashed，保留前驱。
- **所有权 / 错误 / 调用**：仅改位，不更新hash链或计数。

### `Shape.deletedPropCount` (`src/core/shape.zig:289`)

- **签名**：`pub inline fn deletedPropCount(self: *const Shape) u32`。
- **作用**：读取墓碑计数。
- **实现**：返回cold_state.deleted_prop_count。
- **所有权 / 错误 / 调用**：不扫描属性数组核实。

### `Shape.incrementDeletedPropCount` (`src/core/shape.zig:293`)

- **签名**：`inline fn incrementDeletedPropCount(self: *Shape) void`。
- **作用**：增加墓碑计数。
- **实现**：读取旧值，断言old+1小于no_property_index，再写old+1。
- **所有权 / 错误 / 调用**：不实际删除属性或更新identity；计数必须已处于合法范围。

### `Shape.hasPropertyHash` (`src/core/shape.zig:299`)

- **签名**：`pub fn hasPropertyHash(self: *const Shape) bool`。
- **作用**：判断是否声明有属性hash桶。
- **实现**：prop_hash_mask!=0。
- **所有权 / 错误 / 调用**：不检查桶内容或是否登记于Registry Shape hash表；两种hash不是一回事。

### `Shape.firstPropertyIndex` (`src/core/shape.zig:303`)

- **签名**：`pub fn firstPropertyIndex(self: *const Shape, atom_id: atom.Atom) u32`。
- **作用**：取得atom对应桶的链头索引。
- **实现**：无hash返回no_property_index，否则委托AssumeHash版本。
- **所有权 / 错误 / 调用**：不是完整属性查找；桶碰撞时返回项未必具有指定atom。

### `Shape.firstPropertyIndexAssumeHash` (`src/core/shape.zig:308`)

- **签名**：`pub inline fn firstPropertyIndexAssumeHash(self: *const Shape, atom_id: atom.Atom) u32`。
- **作用**：按桶映射直接读取链头。
- **实现**：断言有hash，调用propertyBucketIndex(self.hash,atom_id,mask)，返回hashBuckets()[bucket]。
- **所有权 / 错误 / 调用**：不遍历链、不检查deleted或索引合法性；返回哨兵也属正常情况。

### `Shape.traceChildEdgesFallible` (`src/core/shape.zig:314`)

- **签名**：`pub inline fn traceChildEdgesFallible(self: *Shape, rt: *JSRuntime, visitor: anytype) !void`。
- **作用**：枚举prototype与未删除的属性atom边。
- **实现**：先把真实proto字段地址传可选visitObject；再遍历prop_count项，跳过null_atom或deleted项，逐个atom.callVisitAtom。
- **所有权 / 错误 / 调用**：不追踪registry_hash_next、GC前驱或hash桶为强边；proto可原位更新，atom按值访问不回写。runtime参数未用，回调错误立即停止。

### `Shape.traceChildEdgesFallible.callVisitObject` (`src/core/shape.zig:317`)

- **签名**：`inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void`。
- **作用**：按visitor是否提供visitObject分派。
- **实现**：编译期取visitor本体类型，存在方法时调用；error-union返回值try传播，否则直接调用。
- **所有权 / 错误 / 调用**：缺方法即无操作，不回退其他接口；可空proto如何处理由回调负责。

### `Shape.traceChildEdgesNoFail` (`src/core/shape.zig:341`)

- **签名**：`pub inline fn traceChildEdgesNoFail(self: *Shape, rt: *JSRuntime, visitor: anytype) void`。
- **作用**：供保证不会失败的visitor使用的包装。
- **实现**：调用Fallible版本，catch unreachable。
- **所有权 / 错误 / 调用**：不是吞掉错误继续；调用方必须保证visitor无失败路径，不在此建立GC根。

### `Registry.adoptionBarrier` (`src/core/shape.zig:371`)

- **签名**：`pub inline fn adoptionBarrier(self: *Registry, owner: *Object, target: *Shape) void`。
- **作用**：处理对象采用Shape时的GC屏障。
- **实现**：owner可跳过屏障则返回；未处于增量marking时执行owner到Shape的generationalBarrier，否则委托shadeAdoptedShape。
- **所有权 / 错误 / 调用**：不安装shape_ptr或标shared；调用者仍须处理属性值各自屏障。

### `Registry.shadeAdoptedShape` (`src/core/shape.zig:380`)

- **签名**：`noinline fn shadeAdoptedShape(self: *Registry, owner: *Object, target: *Shape) void`。
- **作用**：在增量标记中同步访问新采用Shape的边。
- **实现**：target已标记、owner/target未heap_accounted或owner未标记时返回；否则先标target，visitor访问prototype和有效atom，最后retireTracedYoung(target)。
- **所有权 / 错误 / 调用**：避免把可能原地迁移或释放的Shape留作稍后扫描任务；无JS存储分配，底层标记前沿失败由GC屏障机制处理，不通过本函数返回error。

### `Registry.Visitor.visitObject` (`src/core/shape.zig:391`)

- **签名**：`pub fn visitObject(vis: *@This(), slot: *?*Object) void`。
- **作用**：处理被采用Shape的prototype边。
- **实现**：slot非空时以owner_header调用shadeForIncrementalMark(prototype.header)。
- **所有权 / 错误 / 调用**：不改proto、不以Shape作为此调用的owner；空槽无操作。

### `Registry.Visitor.visitAtom` (`src/core/shape.zig:396`)

- **签名**：`pub fn visitAtom(vis: *@This(), key: atom.Atom) void`。
- **作用**：处理被采用Shape的属性key。
- **实现**：调用atoms.shadeAtomIfMarking(key)。
- **所有权 / 错误 / 调用**：不写回atom，不保留独立引用计数；是否需标记由atom表处理。

### `Registry.init` (`src/core/shape.zig:409`)

- **签名**：`pub fn init(runtime: *JSRuntime, account: *memory.MemoryAccount, atoms: *atom.AtomTable, gc_registry: *gc.Registry) Registry`。
- **作用**：初始化Shape registry引用及默认状态。
- **实现**：保存runtime/account/atoms/gc_registry指针，其余字段默认。
- **所有权 / 错误 / 调用**：不分配hash桶、不注册Shape；next_identity初始1，bits初始4，count0。

### `Registry.deinit` (`src/core/shape.zig:413`)

- **签名**：`pub fn deinit(self: *Registry) void`。
- **作用**：释放Shape hash桶数组。
- **实现**：先摘buckets、重置bits为4及count为0，再释放非空数组。
- **所有权 / 错误 / 调用**：不遍历销毁Shape、不清各Shape hashed位，不重置next_identity或借用依赖指针；live Shape由GC teardown负责，非独立清空全部Shape的API。

### `Registry.create` (`src/core/shape.zig:425`)

- **签名**：`pub fn create(self: *Registry, proto: ?*Object) !*Shape`。
- **作用**：创建新的已发布根Shape。
- **实现**：直接createShape(proto)。
- **所有权 / 错误 / 调用**：不执行缓存查找；与createObjectRoot的命中复用不同，分配/登记hash失败传播。

### `Registry.publish` (`src/core/shape.zig:431`)

- **签名**：`pub fn publish(self: *Registry, shape_ref: *Shape) void`。
- **作用**：将尚未heap_accounted的Shape登记到GC。
- **实现**：已accounted返回；否则addInitializedShape(header,accountedAllocationSize)。
- **所有权 / 错误 / 调用**：不插入Shape hash表、不验证已初始化字段，也不注册临时根；发布前必须已完成初始化。

### `Registry.createObjectRoot` (`src/core/shape.zig:436`)

- **签名**：`pub inline fn createObjectRoot(self: *Registry, proto: ?*Object) !*Shape`。
- **作用**：查找或创建默认根Shape。
- **实现**：调用createObjectRootMaybeReserved(proto,false)。
- **所有权 / 错误 / 调用**：命中复用，miss创建并GC登记；原型存活由调用协议保证。

### `Registry.createObjectRootReserved` (`src/core/shape.zig:442`)

- **签名**：`pub inline fn createObjectRootReserved(self: *Registry, proto: ?*Object) !*Shape`。
- **作用**：查找或预留默认根Shape。
- **实现**：调用createObjectRootMaybeReserved(proto,true)。
- **所有权 / 错误 / 调用**：reserved只决定miss的构造路径，不保证返回的缓存命中一定未发布；调用者仍须满足发布与GC保护协议。

### `Registry.createObjectRootMaybeReserved` (`src/core/shape.zig:448`)

- **签名**：`noinline fn createObjectRootMaybeReserved(self: *Registry, proto: ?*Object, reserved: bool) !*Shape`。
- **作用**：按hash、原型和空属性布局复用根Shape。
- **实现**：遍历initialHash对应链，先比较hash，再proto/prop_count==0；命中markShared并返回，miss按reserved选择构造器。
- **所有权 / 错误 / 调用**：默认根查找不比较prop_size、不主动publish命中；无完整链循环保护。markShared是粘性共享位，不是retain。

### `Registry.createObjectRootWithPropertyCapacity` (`src/core/shape.zig:465`)

- **签名**：`pub fn createObjectRootWithPropertyCapacity(self: *Registry, proto: ?*Object, property_capacity: usize) !*Shape`。
- **作用**：按原型与精确容量复用空根Shape。
- **实现**：容量0委托createObjectRoot；非0遍历hash链，要求hash/proto/prop_count==0/prop_size==property_capacity，命中markShared，miss调用createShapeWithPropertyCapacity。
- **所有权 / 错误 / 调用**：不复用更大容量的root，避免Shape声明的值槽容量超出Object实际buffer；reserved版本仅在miss省略GC发布。

### `Registry.createObjectRootWithPropertyCapacityReserved` (`src/core/shape.zig:482`)

- **签名**：`pub fn createObjectRootWithPropertyCapacityReserved(self: *Registry, proto: ?*Object, property_capacity: usize) !*Shape`。
- **作用**：按原型与精确容量复用空根Shape。
- **实现**：容量0委托createObjectRootReserved；非0遍历hash链，要求hash/proto/prop_count==0/prop_size==property_capacity，命中markShared，miss调用createShapeWithPropertyCapacityReserved。
- **所有权 / 错误 / 调用**：不复用更大容量的root，避免Shape声明的值槽容量超出Object实际buffer；reserved版本仅在miss省略GC发布。

### `Registry.createInitialShape` (`src/core/shape.zig:501`)

- **签名**：`pub fn createInitialShape(self: *Registry, proto: ?*Object, properties: []const InitialProperty) !*Shape`。
- **作用**：创建指定初始属性序列的Shape。
- **实现**：按properties.len计算容量取得root，设置失败dropUnshared；prepareUpdate后依序addProperty，返回最终指针。
- **所有权 / 错误 / 调用**：无需临时Object；输入atom/flags不在本函数验证或去重，prepare/add可能换Shape。失败按当前result清理，不返回部分布局。

### `Registry.createShape` (`src/core/shape.zig:511`)

- **签名**：`fn createShape(self: *Registry, proto: ?*Object) !*Shape`。
- **作用**：分配默认两属性容量、四桶的根Shape。
- **实现**：createWithFamComptime分配，初始化header/proto/mask/size/hash，仅桶填no_property_index；link(shape,true)建立registry登记。返回前addInitializedShape做GC记账。
- **所有权 / 错误 / 调用**：未使用的Property容量不初始化，有效prop_count为0；错误释放分配，link成功后有unlink清理。Shape创建本身不为proto建立显式root frame。

### `Registry.createShapeReserved` (`src/core/shape.zig:537`)

- **签名**：`fn createShapeReserved(self: *Registry, proto: ?*Object) !*Shape`。
- **作用**：分配默认两属性容量、四桶的根Shape。
- **实现**：createWithFamComptime分配，初始化header/proto/mask/size/hash，仅桶填no_property_index；link(shape,true)建立registry登记。不调用addInitializedShape。
- **所有权 / 错误 / 调用**：未使用的Property容量不初始化，有效prop_count为0；错误释放分配，link成功后有unlink清理。Shape创建本身不为proto建立显式root frame。

### `Registry.createShapeWithPropertyCapacity` (`src/core/shape.zig:554`)

- **签名**：`fn createShapeWithPropertyCapacity( self: *Registry, proto: ?*Object, property_capacity: usize, ) !*Shape`。
- **作用**：按非零精确属性容量分配根Shape。
- **实现**：断言容量非0；桶数max(4,nextPowerOfTwo(capacity+1))，分配FAM、写u32容量/mask及hash，填桶，再link(shape,true)。随后addInitializedShape发布。
- **所有权 / 错误 / 调用**：容量使用intCast而非返回范围错误，大小算术也非全checked；调用方保证可表示的容量。失败释放FAM，未使用Property记录不初始化。

### `Registry.createShapeWithPropertyCapacityReserved` (`src/core/shape.zig:580`)

- **签名**：`fn createShapeWithPropertyCapacityReserved( self: *Registry, proto: ?*Object, property_capacity: usize, ) !*Shape`。
- **作用**：按非零精确属性容量分配根Shape。
- **实现**：断言容量非0；桶数max(4,nextPowerOfTwo(capacity+1))，分配FAM、写u32容量/mask及hash，填桶，再link(shape,true)。省略GC发布，由调用者后续publish。
- **所有权 / 错误 / 调用**：容量使用intCast而非返回范围错误，大小算术也非全checked；调用方保证可表示的容量。失败释放FAM，未使用Property记录不初始化。

### `Registry.tryCachedTransition` (`src/core/shape.zig:613`)

- **签名**：`pub inline fn tryCachedTransition(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6, property_capacity: usize) bool`。
- **作用**：采用已有的单属性追加Shape。
- **实现**：查找缓存，miss直接false；hit标cached共享，先写shape_ptr，再dropUnshared(parent)，返回true。
- **所有权 / 错误 / 调用**：不安装对象值槽或调用adoptionBarrier，调用方负责；没有RC retain/release。miss不改Shape指针。

### `Registry.transitionPropertyUncached` (`src/core/shape.zig:630`)

- **签名**：`pub fn transitionPropertyUncached(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6, property_capacity: usize) !void`。
- **作用**：在缓存未命中后执行属性追加转移。
- **实现**：shared parent先按调用方property_capacity clone为hashed child，append后以parent hash生成新hash并rehash，最后安装child。unshared parent先reservePropertyAppend一次预留所需属性与桶，再append；仅当前Shape hashed时更新转移hash及rehash。
- **所有权 / 错误 / 调用**：共享分支要求容量>=parent.prop_count+1，不取max(parent.prop_size,capacity)；clone后append仍用try且本函数无child errdefer，不能泛称每步失败都立即销毁所有临时对象。独有分支reserve可能换地址，成功后append预留应无额外增长。外层负责值数组及屏障。

### `Registry.findHashedShapeProperty` (`src/core/shape.zig:674`)

- **签名**：`inline fn findHashedShapeProperty(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6, property_capacity: usize) ?*Shape`。
- **作用**：寻找与parent追加一个属性完全匹配的缓存Shape。
- **实现**：parent非hashed返回null；按transitionHash遍历候选，核对hash/proto/prop_count=n+1/精确prop_size，逐个比较父布局atom/flags及末项atom/flags。
- **所有权 / 错误 / 调用**：不标shared、不修改指针或比较hash_next；deleted槽也按原atom/flags比较。不执行全链损坏/循环防护。

### `Registry.cloneForMutation` (`src/core/shape.zig:700`)

- **签名**：`pub fn cloneForMutation(self: *Registry, source: *Shape) !*Shape`。
- **作用**：复制同原型同声明容量的非hashed Shape。
- **实现**：调用cloneShape(source,source.proto,source.prop_size,false)。
- **所有权 / 错误 / 调用**：不替换调用者指针或释放source，不复制Object值数组；新Shape按clone机制初始化和登记。

### `Registry.prepareUpdate` (`src/core/shape.zig:705`)

- **签名**：`pub fn prepareUpdate(self: *Registry, shape_ptr: **Shape) !void`。
- **作用**：确保后续一般修改使用未共享、非hashed的Shape。
- **实现**：hashed且未shared时摘hash链、清hashed、减count、刷新identity；未shared且未hashed时只刷新identity；shared时cloneForMutation并安装clone。
- **所有权 / 错误 / 调用**：即使尚未做属性修改也会失效旧identity。共享旧Shape留给GC，本函数不执行具体修改；clone失败不安装新指针。

### `Registry.replacePrototypeAssumePrepared` (`src/core/shape.zig:726`)

- **签名**：`pub fn replacePrototypeAssumePrepared(self: *Registry, shape: *Shape, proto: ?*Object) ?*Object`。
- **作用**：替换预先准备好的Shape原型并更新identity/hash。
- **实现**：断言非hashed；相同proto直接null。否则保存旧值、写新proto/identity，对非空新proto做Shape到Object屏障，从新proto与全部有效范围属性重算hash，再rehash，返回旧proto。
- **所有权 / 错误 / 调用**：没有显式shared断言，但调用合同要求已prepare；不检查原型环/extensible/immutable。返回null既可能无变化也可能旧proto为null，不能单靠返回值判定是否修改。

### `Registry.relocateShape` (`src/core/shape.zig:764`)

- **签名**：`fn relocateShape(self: *Registry, shape_ptr: **Shape, new_prop_size: u32, new_bucket_count: usize) !void`。
- **作用**：以新分配替换未共享Shape的FAM布局。
- **实现**：断言未shared，保存旧尺寸；唯一fallible步骤是createWithFam。新头保留proto/hash/identity/有效计数，初始化全部属性容量并复制有效项；桶数相同直接复制，否则重建跳过null atom的链。摘旧hash/GC登记，登记新Shape并恢复hashed链，直接 destroyWithFam 释放旧raw分配（旧属性atom无需清理，原先那圈空的 `for (old.props()) |_| {}` 已删），最后写shape_ptr。
- **所有权 / 错误 / 调用**：成功迁移保留逻辑identity，不逐atom/原型retain释放；调用方保证新容量容得下有效属性且只有允许修复的拥有指针。分配失败旧指针不变；没有复制Object值存储或重写任意外部裸借用。

### `Registry.addProperty` (`src/core/shape.zig:838`)

- **签名**：`pub inline fn addProperty(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6) !void`。
- **作用**：追加属性元数据并更新转移hash。
- **实现**：appendProperty可能迁移Shape，随后从最新指针取得旧hash，transitionHash后rehash。
- **所有权 / 错误 / 调用**：不验证重复atom、不安装对应Object值槽、不自行clone shared；调用者须准备正确拥有状态。

### `Registry.markPropertyDeleted` (`src/core/shape.zig:846`)

- **签名**：`pub fn markPropertyDeleted(self: *Registry, shape: *Shape, index: usize, flags: u6) void`。
- **作用**：从属性桶链摘除指定属性并留下墓碑。
- **实现**：断言index有效且atom非null；遍历对应桶，修链头或前项next，找不到则unreachable。置hash_next哨兵、flags为传入值、atom=null，增deleted计数并刷新identity。
- **所有权 / 错误 / 调用**：不是Flags.asDeleted调用：传入flags正确性由调用方保证。无容量缩减、不更新prop_count或Shape转移hash、不释放值槽，也不自行prepare/clone；要求现有桶链一致。

### `Registry.compactProperties` (`src/core/shape.zig:886`)

- **签名**：`pub fn compactProperties(self: *Registry, object: *Object) !void`。
- **作用**：移除属性墓碑并同步压缩Shape和对象值存储。
- **实现**：要求旧Shape未shared、未hashed且有墓碑；live_count=count-deleted，容量取至少2的二次幂，桶数按容量缩小。先分配新Shape，必要时分配property_storage cell；仅slots2、无payload且容量<=2可回到inline尾槽。保存旧值slice，按旧顺序复制atom非null项及对应Entry，重建桶、清deleted并取新identity。最后替换GC登记、对象Shape/摘要及值存储，执行相应屏障，释放旧Shape。
- **所有权 / 错误 / 调用**：筛选依据是atom非null，依赖deleted计数和墓碑一致；不会重排剩余属性相对顺序。所有fallible分配在复制/提交前完成，失败释放新Shape；旧外部值cell不手还。带payload的slots2不能复用与payload重叠的尾部。不执行getter或逐值RC释放。

### `Registry.updatePropertyFlags` (`src/core/shape.zig:999`)

- **签名**：`pub fn updatePropertyFlags(self: *Registry, shape: *Shape, index: usize, flags: u6) void`。
- **作用**：修改一项flags并失效布局identity。
- **实现**：断言index<count，相同flags返回，否则写新flags并freshIdentity。
- **所有权 / 错误 / 调用**：不同步Slot活动臂、不更新转移hash或墓碑计数、不clone共享Shape；调用方必须先prepare并保持所有元数据一致。

### `Registry.restorePropertyLayout` (`src/core/shape.zig:1008`)

- **签名**：`pub fn restorePropertyLayout(self: *Registry, shape_ptr: **Shape, baseline_props: []const Property, baseline_hash: u32, baseline_deleted_count: usize) !void`。
- **作用**：以给定属性基线重建未共享Shape。
- **实现**：断言未shared；保留至少旧容量并倍增到容纳baseline，桶兼顾baseline长度、deleted数和容量。新Shape保留proto/hashed，采用baseline hash/count/deleted、新identity；复制flags/atom（非null经noteHolderStore）并重建桶。切换hash与GC登记、释放旧Shape，最后写shape_ptr。
- **所有权 / 错误 / 调用**：只恢复Shape，不恢复Object值数组、prototype或旧identity；调用方负责提供匹配基线/值布局与可存活atom。分配失败旧指针不变；noteHolderStore 不是 RC dup，也没有对应的 atom 释放动作（原先那条空的 freePropertyAtoms errdefer 与旧 atom 清理空循环都已删）。

### `Registry.reserveProperties` (`src/core/shape.zig:1078`)

- **签名**：`pub fn reserveProperties(self: *Registry, shape_ptr: **Shape, needed: usize) !void`。
- **作用**：在需要时增加Shape属性容量并同步扩桶。
- **实现**：needed<=prop_size直接返回；否则从当前prop_size倍增，以lockstepBucketCount计算桶数并relocateShape。
- **所有权 / 错误 / 调用**：增长前提是当前容量非零：本方法不像reservePropertyAppend那样为0设置初始值。只扩Shape，不分配Object值数组；倍增/intCast不返回范围错误，迁移要求未共享。

### `Registry.reservePropertyAppend` (`src/core/shape.zig:1093`)

- **签名**：`fn reservePropertyAppend(self: *Registry, shape_ptr: **Shape, requested_property_capacity: usize) !void`。
- **作用**：把一次追加所需属性容量与桶容量合并预留。
- **实现**：post_count=count+1，需求为max(requested,post_count)；属性容量从现有容量或2倍增，桶至少覆盖属性容量且达到post_count+deleted。两种尺寸不变返回，否则只relocate一次。
- **所有权 / 错误 / 调用**：不增加prop_count或写属性；一次分配失败不迁移旧Shape，避免属性扩容成功后第二次桶分配失败。依赖有效的容量/计数范围和未共享拥有协议。

### `Registry.reservePropertyHash` (`src/core/shape.zig:1109`)

- **签名**：`pub fn reservePropertyHash(self: *Registry, shape_ptr: **Shape, needed: usize) !void`。
- **作用**：为给定属性数量预留包含墓碑余量的桶。
- **实现**：minimum=needed+deleted；已有hash且minimum<=mask+1时返回，否则rebuildPropertyHash(max(4,nextPowerOfTwo(minimum+1)))。
- **所有权 / 错误 / 调用**：不同时检查needed<=prop_size，不增加属性容量或修改值数组；实际重建可迁移Shape，不能把此接口当作全部存储已预留的证明。

### `Registry.hasReservedOwnPropertyCapacity` (`src/core/shape.zig:1116`)

- **签名**：`pub fn hasReservedOwnPropertyCapacity(self: *Registry, shape: *const Shape, needed: usize) bool`。
- **作用**：检查声明属性容量和桶容量是否均足够。
- **实现**：needed>prop_size返回false，否则要求有hash且needed+deleted<=mask+1。
- **所有权 / 错误 / 调用**：不检查Object实际值buffer、Shape共享状态或将来GC分配，不预留资源；runtime registry参数未使用。

### `Registry.dropUnshared` (`src/core/shape.zig:1136`)

- **签名**：`pub fn dropUnshared(self: *Registry, shape: *Shape) void`。
- **作用**：在允许立即释放时销毁未共享Shape。
- **实现**：shared、GC deinit阶段或header已condemned均返回；否则destroyShape。
- **所有权 / 错误 / 调用**：不减引用计数，不把shared重新判成独占；未发布reserved Shape也可经此路径释放，前提是调用者确实放弃唯一拥有权。

### `Registry.destroyFromHeader` (`src/core/shape.zig:1143`)

- **签名**：`pub fn destroyFromHeader(self: *Registry, header: *gc.Header) void`。
- **作用**：从header取得Shape并销毁。
- **实现**：fieldParentPtr后调用destroyShape。
- **所有权 / 错误 / 调用**：不执行dropUnshared的shared/deinit/condemned保护，collector必须保证销毁时机合法。

### `Registry.destroyShape` (`src/core/shape.zig:1148`)

- **签名**：`fn destroyShape(self: *Registry, shape: *Shape) void`。
- **作用**：摘除GC与hash登记并释放Shape分配。
- **实现**：优先取slab accounted payload，否则按当前FAM计算；unlinkObjectWithBytes后unlink hash，最后destroyWithFam。
- **所有权 / 错误 / 调用**：没有旧注释所称逐atom或proto释放（那圈空的属性遍历已删）；不销毁Object的值数组。不检查shared或使用者，原始分配释放后指针失效。

### `Registry.cloneShape` (`src/core/shape.zig:1163`)

- **签名**：`fn cloneShape( self: *Registry, source: *Shape, proto: ?*Object, needed: usize, hashed: bool, ) !*Shape`。
- **作用**：分配并登记包含相同属性元数据的新Shape。
- **实现**：容量max(2,needed)转u32，桶与容量同步；新头复制source hash/count/deleted，proto取参数。初始化全部属性容量，非null atom经noteHolderStore复制，重建桶，再link(hashed)分配新identity并addInitializedShape。
- **所有权 / 错误 / 调用**：不拷贝Object值数组，不自动按新proto重算hash；调用者须提供足够容纳source.prop_count的needed及正确hash后续处理。错误只释放新FAM（属性atom无需回滚，原先那条空的 freePropertyAtoms errdefer 已删）；noteHolderStore不等价RC dup。

### `Registry.appendProperty` (`src/core/shape.zig:1219`)

- **签名**：`inline fn appendProperty(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6) !void`。
- **作用**：预留后写一项属性元数据并加入桶链。
- **实现**：先reservePropertyAppend，随后noteHolderStore(atom)，在当前count写flags/atom/链哨兵，count+1并freshIdentity；断言含deleted余量能容纳，最后linkPropertyHash。
- **所有权 / 错误 / 调用**：不查重复、不检查flags语义或写Object值槽；原子性依赖外层先准备值存储及拥有状态。唯一try位于预留阶段，不更新Shape转移hash（包装层负责）。

### `Registry.rebuildPropertyHash` (`src/core/shape.zig:1247`)

- **签名**：`fn rebuildPropertyHash(self: *Registry, shape_ptr: **Shape, bucket_count: usize) !void`。
- **作用**：保持属性容量并迁移至指定桶数。
- **实现**：断言bucket_count是2的幂，调用relocateShape(shape_ptr,原prop_size,bucket_count)。
- **所有权 / 错误 / 调用**：迁移要求未shared；不原地重建，可能分配失败，不自动证明请求桶数足以满足其他负载合同。

### `Registry.linkPropertyHash` (`src/core/shape.zig:1254`)

- **签名**：`fn linkPropertyHash(self: *Registry, shape: *Shape, index: usize) void`。
- **作用**：把属性索引插入对应桶链头。
- **实现**：断言有hash、index<count、atom非null；计算桶，prop.hash_next接旧桶头，再更新桶头为index。
- **所有权 / 错误 / 调用**：无分配或重复链接防护；不检查deleted标志，26位转换依赖合法索引范围，不更新identity/hash/count。

### `Registry.freshIdentity` (`src/core/shape.zig:1267`)

- **签名**：`pub inline fn freshIdentity(self: *Registry) u64`。
- **作用**：取出并递增registry布局序号。
- **实现**：保存next_identity，执行普通+1，再返回旧值。
- **所有权 / 错误 / 调用**：初始1，运行范围内不复用；没有wrap恢复或显式溢出错误接口，也不单独写任何Shape。

### `Registry.link` (`src/core/shape.zig:1273`)

- **签名**：`inline fn link(self: *Registry, shape: *Shape, hashed: bool) !void`。
- **作用**：为新Shape分配identity并按需插入hash登记。
- **实现**：先freshIdentity；hashed时检查空表或预期负载超过1/2，必要时ensureShapeHashCapacity(1)，再设hashed、插桶并count+1；非hashed仅清标志。
- **所有权 / 错误 / 调用**：不登记GC链，调用者随后publish；容量分配失败仍已消耗identity，序号不会回退。

### `Registry.unlink` (`src/core/shape.zig:1303`)

- **签名**：`fn unlink(self: *Registry, shape: *Shape) void`。
- **作用**：摘除当前标记为hashed的Shape。
- **实现**：hashed时removeShapeHash、清标志，断言count非零再count-1；否则无操作。
- **所有权 / 错误 / 调用**：不销毁Shape或从GC链摘除；依赖标志/计数与真实成员一致。

### `Registry.ensureShapeHashCapacity` (`src/core/shape.zig:1312`)

- **签名**：`noinline fn ensureShapeHashCapacity(self: *Registry, additional: usize) !void`。
- **作用**：初始化或单次扩展Shape hash桶表。
- **实现**：空表先按1<<bits分配并清null；若2*(count+additional)<=桶数返回，bits==32也返回。否则仅扩一倍，遍历旧桶重链到新桶，安装新表/bits并释放旧数组。
- **所有权 / 错误 / 调用**：不是循环扩容到任意additional都满足负载；一般调用additional=1。首次表创建成功后第二次分配失败会保留已创建空表，不是全部回滚。扩表只重排弱hash链，不改Shape identity/GC登记。

### `Registry.firstShapeWithHash` (`src/core/shape.zig:1347`)

- **签名**：`fn firstShapeWithHash(self: *Registry, hash: u32) ?*Shape`。
- **作用**：读取hash映射桶的链头。
- **实现**：无桶返回null，否则取hashIndex(hash,bits)对应头。
- **所有权 / 错误 / 调用**：没有验证头节点hash等于输入；调用方遍历时仍须逐个比较。

### `Registry.insertShapeHash` (`src/core/shape.zig:1352`)

- **签名**：`fn insertShapeHash(self: *Registry, shape: *Shape) void`。
- **作用**：将Shape插入其hash对应桶头。
- **实现**：断言表非空，shape.next接旧头，再写桶头。
- **所有权 / 错误 / 调用**：不设hashed、不增count、不查重或分配；这些由上层link维护。

### `Registry.removeShapeHash` (`src/core/shape.zig:1360`)

- **签名**：`fn removeShapeHash(self: *Registry, shape: *Shape) void`。
- **作用**：从hash登记中移除Shape。
- **实现**：先按shape当前hash尝试移除，失败再扫描全部桶。
- **所有权 / 错误 / 调用**：支持节点仍挂在旧hash桶的情形；本方法不清hashed标志或递减count，上层unlink负责。

### `Registry.rehashShape` (`src/core/shape.zig:1368`)

- **签名**：`fn rehashShape(self: *Registry, shape: *Shape, old_hash: u32) void`。
- **作用**：把已hashed的Shape从旧hash桶迁到新桶。
- **实现**：hash未变或非hashed直接返回；按old_hash移除，失败全表扫描，然后插入当前hash桶。
- **所有权 / 错误 / 调用**：无分配，不更新count或identity；调用前应已写新hash，维护的是registry链而非属性桶。

### `Registry.delistCondemnedShape` (`src/core/shape.zig:1406`)

- **签名**：`pub fn delistCondemnedShape(self: *Registry, header: *gc.Header) void`。
- **作用**：让待销毁Shape不再能被转移缓存命中。
- **实现**：由header取Shape，调用unlink并断言非hashed。
- **所有权 / 错误 / 调用**：不释放结构或修改condemned状态；须由collector在正确阶段调用。正常路径只扫描所属桶，不是严格O(1)，陈旧hash可触发全表回退。

### `Registry.verifyHashIndex` (`src/core/shape.zig:1433`)

- **签名**：`pub fn verifyHashIndex(self: *const Registry) HashIndexError!void`。
- **作用**：检查已链接节点的hashed标志与计数一致性。
- **实现**：遍历全部桶，遇未hashed节点报LinkedButUnflagged；累计数超过count立即报CountMismatch以约束循环；结束时总数不同同样报错。
- **所有权 / 错误 / 调用**：不验证节点位于正确hash桶、唯一性或所有未链接Shape的标志；不是完整GC存活校验。对环的步数上限依赖记录的count。

### `Registry.removeShapeHashEverywhere` (`src/core/shape.zig:1448`)

- **签名**：`fn removeShapeHashEverywhere(self: *Registry, shape: *Shape) void`。
- **作用**：在所有桶中按指针查找并摘除Shape。
- **实现**：空表返回；每桶沿next找目标，修前驱链接、清目标next，命中后只退出该桶的内循环。
- **所有权 / 错误 / 调用**：不更新count/hashed；非重复成员是正常不变量，不应把此函数看作可修复任意重复链或循环损坏。

### `Registry.removeShapeHashFromBucket` (`src/core/shape.zig:1463`)

- **签名**：`fn removeShapeHashFromBucket(self: *Registry, shape: *Shape, hash: u32) bool`。
- **作用**：在指定hash的桶内移除目标指针。
- **实现**：空表false；沿链接找到相同指针后接到其next、清目标next并true，未找到false。
- **所有权 / 错误 / 调用**：不核对candidate.hash，不更新count/hashed，无循环防护；hash可为迁移前的旧值。

### `nextPowerOfTwo` (`src/core/shape.zig:1479`)

- **签名**：`fn nextPowerOfTwo(value: usize) usize`。
- **作用**：取得不小于输入的二次幂。
- **实现**：从1倍增直到>=value。
- **所有权 / 错误 / 调用**：0也返回1；无溢出检测或error返回，调用者限制输入。

### `lockstepBucketCount` (`src/core/shape.zig:1492`)

- **签名**：`fn lockstepBucketCount(current_bucket_count: usize, new_prop_size: usize) usize`。
- **作用**：从已有桶数或4起扩到覆盖属性容量。
- **实现**：hash_size=max(current,4)，持续倍增至>=new_prop_size。
- **所有权 / 错误 / 调用**：不主动舍入任意非二次幂current，不加入deleted余量，依赖输入不变量与上层追加预留。

### `initialHash` (`src/core/shape.zig:1498`)

- **签名**：`pub fn initialHash(proto: ?*Object) u32`。
- **作用**：由原型地址计算根Shape hash。
- **实现**：null视作地址0，将u64地址低32位、高32位依次与种子1做shapeHash。
- **所有权 / 错误 / 调用**：依赖对象身份地址，不读取原型属性；hash碰撞必须进一步比较proto/布局。

### `transitionHash` (`src/core/shape.zig:1509`)

- **签名**：`pub fn transitionHash(seed: u32, atom_id: atom.Atom, flags: u6) u32`。
- **作用**：把属性atom及六位flags折入转移hash。
- **实现**：shapeHash(shapeHash(seed,atom_id),flags)。
- **所有权 / 错误 / 调用**：不读取属性值或验证flags，不保证无碰撞。

### `hashIndex` (`src/core/shape.zig:1513`)

- **签名**：`pub fn hashIndex(hash: u32, bits: u6) u32`。
- **作用**：取32位hash的高bits位作为registry桶索引。
- **实现**：断言1<=bits<=32，右移32-bits。
- **所有权 / 错误 / 调用**：不是低位mask；bits=32返回完整hash，调用方保证桶表尺寸匹配。

### `propertyBucketIndex` (`src/core/shape.zig:1519`)

- **签名**：`pub inline fn propertyBucketIndex(shape_hash: u32, atom_id: atom.Atom, mask: u32) usize`。
- **作用**：按atom低位取得Shape内部属性桶。
- **实现**：断言mask非0且mask+1为二次幂，返回atom_id&mask，忽略shape_hash。
- **所有权 / 错误 / 调用**：不同于registry hashIndex；只计算桶，不查找atom或验证链。

### `shapeHash` (`src/core/shape.zig:1526`)

- **签名**：`pub fn shapeHash(seed: u32, value: u32) u32`。
- **作用**：计算可环绕的32位hash混合。
- **实现**：(seed +% value) *% 0x9e370001。
- **所有权 / 错误 / 调用**：显式模2^32加乘，不是加密hash或唯一identity。

## 覆盖核对

- 清单函数数: 89
- 本文标题覆盖: 89
- 未覆盖: 无
