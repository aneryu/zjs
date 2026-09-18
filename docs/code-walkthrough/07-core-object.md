# 07 — 对象模型（`src/core/object.zig`）

本册讲 zjs 的 JS 对象细胞：24字节固定 `Object` 头及可变尾部、flags、class-data 臂、分配/释放、GC header 互转、exotic 钩，以及**住在本文件里**的属性存储入口。payload 结构体定义在 `object_payloads.zig` / `generator_state.zig`，这里 re-export 并提供槽访问器。

权威仍是源码与 ECMA-262。布局数字以 `src/core/object.zig` 的 comptime 断言与 `src/gc-representation-trace-snapshot.txt` 为准；`docs/gc-v2-m-cut-object-layout.md` 是历史规格（`weakref_count` 已退役）。

## 子文档

| 文件 | 覆盖 |
| --- | --- |
| [07-core-object.md](07-core-object.md) | 本页：类型、flags、头布局、臂、尺寸、trace-shape 投影 |
| [07-object-alloc.md](07-object-alloc.md) | `create*`、cell 分配、payload cell、inline payload、array 构造 |
| [07-object-payload.md](07-object-payload.md) | class-data 臂访问器：iterator / collection / buffer / typed array / regexp / bound / proxy / arguments / weak / dense array / promise / generator，以及私有 `*Payload()` |
| [07-object-function.md](07-object-function.md) | 函数/native/realm、rare payload、home object、captures |
| [07-object-gc.md](07-object-gc.md) | 析构、borrowed/weak 清理、trace 子边、cycle 辅助 |
| [07-object-exotic.md](07-object-exotic.md) | 原型、[[Get/Set/Define/Delete]]、ownKeys、seal/freeze、mapped arguments、typed-array 索引 |
| [07-object-autoinit.md](07-object-autoinit.md) | AUTOINIT 物化与 `defineAutoInit*` |
| [07-object-property.md](07-object-property.md) | 属性存储 cell、append/find、dense 字面量、Object.keys 族、String Iterator |

## 文件职责

`object.zig` 是 core 对象模型的主文件（约 11.5k 行）。它：

- 定义 `Object` 的 **24 字节固定头** + class/layout 相关尾。
- 分配/注册/析构对象，并把 class payload 分成 a 类（tracer 拥有的 `.payload` cell，sweep 无析构）、b 类（外部资源）、c 类（弱语义/cursor）。
- 提供各 class 的槽访问器；真正的 payload struct 在 `object_payloads.zig`。
- 提供 shape + `prop_values` 的底层属性入口，以及部分 array/module namespace 等特殊分支。完整 ECMAScript 属性语义还依赖 exec 层：例如本文件 `getProperty` 返回 accessor 的 getter 值而不执行它，`setProperty` 也不调用 setter；不能把这些入口等同于完整 [[Get]] / [[Set]]。
- 实现 tracing 的子边权威 `traceChildEdgesFallible`。

配套：`shape.zig` 隐藏类，`property.zig` 槽与 Flags，`class.zig` class id，`object_gc.zig` 与 collector 的窄缝。

## 类型

### `Error`

`NotExtensible` / `IncompatibleDescriptor` / `ReadOnly` / `AccessorWithoutSetter` / `PrototypeCycle` / `InvalidLength` / `OutOfMemory`。属性抽象操作用这组；读路径另用 `errors.RuntimeError`（含 `ReferenceError` 等）。

### `ExoticMethods`

四个可选函数指针：`get_own_property`、`define_own_property`、`delete_property`、`own_keys`。标准 class 的生产表在 `exoticMethodsForClassId` 目前为空，exotic 行为多半由 class_id 分支完成；测试可通过 `installClassExoticMethods` 注入。

### `ArrayStorageMode`

`dense` / `sparse`。由 `flags.fast_array` 导出，**不是**分配尺寸的判别（尺寸只看 `class_id`）。

### `ObjectFlags`（`packed struct(u32)`，offset 0）

| 位域 | 含义 |
| --- | --- |
| `extensible` | [[Extensible]] |
| `immutable_prototype` | 不可改原型（模块名空间等） |
| `fast_array` | dense 元素语义（可在构造后重算） |
| `is_html_dda` | HTML document.all |
| `may_have_indexed_properties` | 出现过数组下标键 |
| `length_writable` | Array `.length` 可写 |
| `is_with_environment` | with 环境对象 |
| `is_std_array_prototype` | 本 realm 的 `%Array.prototype%`；一旦下标突变就永久清掉 |
| `has_weak_id` | 进了弱身份表 |
| `has_exotic_methods` | 有 exotic 表 |
| `is_borrowed_reference_holder` | borrowed/weak holder 链表成员 |
| `class_payload_kind` | **实际**挂着的 payload（可与 class 声明不同，ordinary/global 懒挂） |
| `slots2_layout` | 尾随 Entry[2] 的字面量布局；仅 `ids.object` |
| `is_native_object` | embedder NativeObject，臂字是 opaque self |
| `reserved` | u14 填满 32 位 |

TGC S4-e：`weakref_count` 删除，flags 占用 offset 0，于是 `class_id`/`shape_ref`/`prop_values` 偏移不变。

### `DenseArrayStorage`（24B）

`values: [*]JSValue`（`.array_storage` cell 或空哨兵）、`count`（dense 程度）、`capacity`、`length`（JS 可见 `.length`，可 > count 表示尾洞）、padding。mapped arguments 把同一块 memory 读成 `?*VarRef`。

### `ObjectStorage`（extern union，24B）

`payload` / `async_continuation` / `array` / `bytecode_function` / `regexp`。对象**并不**总是分配满 24B：`unionArmBytes(class_id)` 才是细胞里真实拥有的臂宽。

### `Object`（extern struct，`@sizeOf == 24`，**不是**分配大小）

| offset | 字段 |
| ---: | --- |
| −8 | `gc.Metadata`（kind/mark/lifetime/alloc_info；Object 指针是 body 起点，`bodyOffsetFromHeader(.object)==0`） |
| 0 | `flags: ObjectFlags` |
| 4 | `class_id: ClassId` |
| 8 | `shape_ref: *Shape`（parked 尸体链也落在这个字 = `object_deferred_link_body_offset`） |
| 16 | `prop_values: [*]Entry`（常驻；空对象是对齐哨兵；slots2 初始指向 body+24） |
| 24 | **非 slots2**：class-data 臂（8 或 24B；Promise 再加内联 `PromisePayload`） |
| 24 | **slots2**：`Entry[2]`（ReleaseFast 32B），**无** class arm |

### 其他局部类型与返回状态

| 类型（源码位置） | 数据与边界 |
| --- | --- |
| `ObjectVisitSet`（40） / `ObjectGraphError`（41） | 对象地址到 void 的 AutoHashMap；递归诊断遍历可报 allocator error 或 PayloadMarkFailed，不是所有 GC carrier 的通用可达集。 |
| `OwnKeysError`（42） / `PropertyReadError`（43） | 分别为 allocator error 与 errors.RuntimeError 的别名。 |
| `Object.PropertyTemplate`（1496） | 借用 Shape 指针和只读 Entry slice，供创建过程复制；不代表已拥有独立属性存储。 |
| `Object.InlineClassPayloadLayout`（2069） | object/payload offset、object size、allocation size 与 std.mem.Alignment；用于动态 class 内联 payload 的地址和分配计算。 |
| `Object.BorrowedIdentityMatcher`（3014） | single 携一个 identity；runtime_batch 携 runtime 批次的起始下标，匹配委托 borrowedWeakCleanupIdentityMatchesSlice。 |
| `Object.NativeCallTarget`（5234） | native entry 和 realm 的借用组合；具体调用语义见函数分册。 |
| `Object.OwnEnumerable`（7646） | enumerable / not_enumerable / descriptor；descriptor 表示要继续取完整描述符判定。 |
| `Object.PutFieldFast`（9498） | done / slow；slow 是转交慢路径的信号，并非 error union。 |
| `Object.PropertyProbe`（10753） | 属性索引和 Shape.Property 的值副本。 |
| `Object.OwnPropertySlotLookup`（10762） | flags 副本与只读 Entry 指针；对象存储或 shape 改变后不能假定二者仍有效且匹配。 |
| `TypedArrayCanonicalIndex`（11130） | none 是非 canonical numeric key；invalid 是 canonical 但不合法的数值索引；index 保存 u32 候选，仍须检查 view 边界。 |
| `IndexKey`（11350） | 数值 index:u32 与对应 atom_id，供 ownKeys 数值排序。 |
| `EntriesMode`（11377） | keys / values / entries，选择内部 ownEntriesArray 的输出投影。 |

文件开头重导出的 payload、generator 状态及 realm 槽类型仍由 object_payloads.zig、generator_state.zig、context.zig 定义；这些别名不是本文件另造的结构。`union_arm_min_bytes/max_bytes` 为 8/24，Object 内的 arm_min_bytes/max_bytes 是同值别名；inline_payload_body_bytes 为 24 字节头加 8 字节窄臂，后接按对齐计算的 embedder payload。slots2 的容量固定为 2，字节数随 property.Entry 的构建布局变化。

### 细胞布局（文字图）

把 `*Object` 当作 0：

```
[-8, 0)     Metadata 8B
[0, 4)      ObjectFlags（整个 u32）
[4, 6)      class_id u16（ClassId）
[6, 8)      对齐填充（shape_ref 要 8 字节对齐；不是 flags 的一部分）
[8, 16)     *Shape
[16, 24)    [*]property.Entry

非 slots2 窄 class（普通 {}、Map、Proxy、native 函数…）：
[24, 32)    payload 指针（8B）          → 物理 body 32B，加 prefix 后进 48B size-class
            计账 body = round_up(prefix+32)-prefix → ReleaseFast 通常 40B

非 slots2 宽 class（Array / arguments / bytecode 函数 / RegExp / String exotic）：
[24, 48)    DenseArrayStorage 或 BytecodeFunctionStorage 或 RegExpPayload（抬到 24B）
            物理 body 48B，+prefix → 56..64 class；计账 56B

slots2 普通对象（对象字面量 1/2 槽）：
[24, 56)    Entry[2]（ReleaseFast 每 Entry 16B）
            物理 body 56B + prefix 8 = 64B cell；无 payload 臂
            若后来 ensureOrdinaryPayload：先把 Entry 拷到 .property_storage cell，
            再把 [24,32) 改成 payload 指针（slots2_layout 位仍在，但 propertyStorageIsInline==false）

内建 Promise：
[24, 32)    payload 指针，指向本 cell 内
[32, 32+sizeof(PromisePayload))  状态与对象同生共死
```

Debug / ReleaseSafe 构建 `trailing_property_bytes==48`（带安全填充），ReleaseFast/Small 才是 32。**禁止按值传递 `Object`**：拷贝只带走 24B 头，臂留在原 cell（`lint_anti_goals.sh` 的 `Object passed by value` 规则）。

### 计账

块内 Object 的 `allocationSize` / `bodyBytes` 返回 **size-class 取整后的 body**（`cell_size - metadata_prefix`），用纯函数 `objectTailBytes(class_id, slots2)` + `accountedBodyBytesForRequest`，**不读块头**。standalone / inline-payload embedder class 按实际 aligned 分配。

### 属性存储

每个对象都有 `prop_values` 指针（qjs `JSObject.prop`）：

- 空：`emptyPropertyStorageBase()` = 对齐非零哨兵，不是 cell。
- slots2 且未 spill：指向 `self+24` 的两个 Entry。
- 否则：`.property_storage` GC cell，增长时 mint 新 cell、拷贝、改指针，旧 cell 交给 sweep。

### payload 分类（TGC S4-c/d）

- **a 类**：`.payload` cell，内容全是 GC 边，sweep 无析构。
- **b 类**：FILE*、ArrayBuffer 外部存储、native FunctionPayload 等，要 finalizer。
- **c 类**：WeakRef/WeakMap/FR/collection cursor/generator 挂起帧，要 finalizer。

`needs_finalizer` 位只上不下。普通 `{}` 死亡只清 alloc bitmap。

### Trace-shape summary（Metadata lifetime 字节）

低 2 位：精确个数 0/1/2，或 `11` overflow。其余 5 位用 base-5 编码两槽的 kind/deleted。bit7 租给 remembered-set。第三次 append 对整字节 `+1` 把 `10` 变成 overflow 哨兵，不碰 bit7。

---

## 文件级与头/臂函数


`FinalizingShapeStorage`是线程局部静态tombstone的存储布局：8字节Metadata（standalone、kind=shape、未accounted），紧接Shape，再接initial_hash_size项bucket和initial_prop_size项Property。编译期断言这三个起点与Shape FAM布局一致。Shape初始化ownership.shared=1、hash mask及capacity，bucket为no_property_index，properties为默认值；它不是旧注释所称的高refcount常量，也没有宿主pin登记。

`ExoticMethods`的get回调返回可空Descriptor，define/delete返回bool，own_keys返回可能OOM的atom slice；四者默认null。ObjectFlags为u32而非旧注释所称16位，其中class_payload_kind表示实际装载状态；DenseArrayStorage为24字节，含values/count/capacity/length/padding，空values是非解引用哨兵。array的length是可见长度，count是dense范围；普通arguments的可见length仍是own property。ObjectStorage为24字节extern union，但实例尾部可能仅分配8字节臂，不能无条件按整个union读写。

### `finalizingShape` (`src/core/object.zig:88`)

- **签名**：`fn finalizingShape() *shape.Shape`。
- **作用**：借用当前线程的析构期空Shape视图。
- **实现**：返回threadlocal finalizing_shape_storage.value地址。
- **所有权 / 错误 / 调用**：不是每次分配，不归某runtime所有，也不注册进GC列表；只供析构回调观察已清空属性后的对象。源码旧注释的高refcount保护已不符合当前ownership字段，不能据此允许回调修改对象。

### `classHasExoticMethods` (`src/core/object.zig:295`)

- **签名**：`fn classHasExoticMethods(class_id: class.ClassId, definition_has_exotic: bool) bool`。
- **作用**：合并可查询的class exotic表与class定义标志。
- **实现**：exoticMethodsForClassId非null则true，否则返回definition_has_exotic。
- **所有权 / 错误 / 调用**：只决定布尔标记，不安装方法或调用hook；生产标准表为空不等于所有对象无exotic行为。

### `classNeedsSlowPropertyAccess` (`src/core/object.zig:300`)

- **签名**：`fn classNeedsSlowPropertyAccess(class_id: class.ClassId, has_exotic_methods: bool) bool`。
- **作用**：判断class是否需要属性慢访问路径。
- **实现**：has_exotic_methods为true直接true；否则array、arguments/mapped_arguments、module_ns、proxy、所有列出的TypedArray类及dataview为true，其余false。
- **所有权 / 错误 / 调用**：不检查具体属性名或当前fast_array标志，也不检测实际own property；string未列于此switch，不能与indexed storage分类混同。

### `classOwnsIndexedElementStorage` (`src/core/object.zig:339`)

- **签名**：`fn classOwnsIndexedElementStorage(class_id: class.ClassId) bool`。
- **作用**：判断属性添加路径是否要按索引元素语义分类。
- **实现**：仅array、arguments、mapped_arguments、string返回true，其余false。
- **所有权 / 错误 / 调用**：不代表当前实例确实有dense元素，也不是全部具有索引exotic行为的class集合；TypedArray在别的路径处理。

### `exoticMethodsForClassId` (`src/core/object.zig:350`)

- **签名**：`fn exoticMethodsForClassId(class_id: class.ClassId) ?*const ExoticMethods`。
- **作用**：查询标准class的可选exotic表。
- **实现**：test构建且class_id在数组范围内时返回已安装表；其余switch当前统一null。
- **所有权 / 错误 / 调用**：生产没有这里定义的标准class表，不意味着Object方法没有class分支实现的exotic行为。返回借用指针，不复制方法表。

### `ObjectStorage.initPayload` (`src/core/object.zig:398`)

- **签名**：`pub inline fn initPayload(payload: class.Payload) ObjectStorage`。
- **作用**：构造以payload指针为有效臂的ObjectStorage值。
- **实现**：先以默认DenseArrayStorage初始化union，再写payload臂。
- **所有权 / 错误 / 调用**：默认array的count/capacity/length/padding为0，因此尾部字节为0；不是保留先前union内容。返回值不拥有或复制payload，不初始化payload指向的数据。

### `unionArmBytes` (`src/core/object.zig:428`)

- **签名**：`pub fn unionArmBytes(class_id: class.ClassId) usize`。
- **作用**：按class_id确定对象实际class-data臂宽度。
- **实现**：array、arguments、mapped_arguments、string、regexp以及bytecode_function/generator_function/async_function/async_generator_function返回union_arm_max_bytes=24；其它返回min=8。
- **所有权 / 错误 / 调用**：宽度不看fast_array或当前payload_kind；RegExp虽自身臂较小也取24。class通常固定，但promoteToGlobalObjectClass会显式改class，必须满足兼容存储合同。该值只计臂，不含固定头、GC prefix或slots2尾部；分配/释放须共享此分类。

### `Object.objectBodyBytes` (`src/core/object.zig:510`)

- **签名**：`pub inline fn objectBodyBytes(class_id: class.ClassId, slots2_layout: bool) usize`。
- **作用**：计算对象物理body请求尺寸。
- **实现**：sizeOf(Object)+objectTailBytes(class_id,slots2_layout)。
- **所有权 / 错误 / 调用**：不含8字节Metadata，也不是block class舍入后的账；固定头本身不能当完整对象分配尺寸。

### `Object.prospectiveAccountedBodyBytes` (`src/core/object.zig:516`)

- **签名**：`inline fn prospectiveAccountedBodyBytes(physical_body_bytes: usize) usize`。
- **作用**：按block class规则估算body记账容量。
- **实现**：以prefix+physical_body_bytes调用accountedBodyBytesForRequest，null时回退原physical_body_bytes。
- **所有权 / 错误 / 调用**：不读取实际header或heap，不证明此对象已走block；调用者负责选择路线。

### `Object.bodyBytes` (`src/core/object.zig:523`)

- **签名**：`pub inline fn bodyBytes(self: *const Object) usize`。
- **作用**：查询当前对象按路线计算的body记账尺寸。
- **实现**：以class_id和hasSlots2Layout计算objectBodyBytes，再accountedBodyBytesForPhysical。
- **所有权 / 错误 / 调用**：block路线可能大于物理请求；不含独立property storage或外部payload的全部递归占用。

### `Object.accountedBodyBytesForPhysical` (`src/core/object.zig:530`)

- **签名**：`inline fn accountedBodyBytesForPhysical(self: *const Object, non_block_bytes: usize) usize`。
- **作用**：按当前prefix路线决定是否对body容量舍入。
- **实现**：非block header直接返回non_block_bytes；block返回prospectiveAccountedBodyBytes。
- **所有权 / 错误 / 调用**：依赖有效Metadata分类，不验证真实block成员；普通slab也返回传入尺寸，不在此加malloc_overhead。

### `Object.gcHeader` (`src/core/object.zig:535`)

- **签名**：`pub inline fn gcHeader(self: *Object) *gc.Header`。
- **作用**：取得Object的collector handle。
- **实现**：直接ptrCast self。
- **所有权 / 错误 / 调用**：Object body与handle同址，不分配、不retain、不建立pin；不能按TraceHeader链字读Object头。

### `Object.gcHeaderConst` (`src/core/object.zig:539`)

- **签名**：`pub inline fn gcHeaderConst(self: *const Object) *const gc.Header`。
- **作用**：取得只读Object collector handle。
- **实现**：直接ptrCast const self。
- **所有权 / 错误 / 调用**：借用原地址，不查Metadata或生命周期。

### `Object.fromHeader` (`src/core/object.zig:543`)

- **签名**：`pub inline fn fromHeader(header: *gc.Header) *Object`。
- **作用**：按Object合同把collector handle转换为可变Object。
- **实现**：runtime_safety时断言kind为Object且body offset为0，然后bodyAddressFromHeader并ptrFromInt。
- **所有权 / 错误 / 调用**：输入须已有效，kind检查会读prefix，不能用来安全探测任意地址；不验证accounted或generation。

### `Object.fromHeaderConst` (`src/core/object.zig:551`)

- **签名**：`pub inline fn fromHeaderConst(header: *const gc.Header) *const Object`。
- **作用**：把合法Object collector handle转换为只读Object。
- **实现**：安全构建核对kind与0偏移，再bodyAddressFromHeader构造const指针。
- **所有权 / 错误 / 调用**：与可变版本同样依赖有效前缀和外层成员验证；不延长生命周期。

### `Object.objectTailBytes` (`src/core/object.zig:564`)

- **签名**：`pub inline fn objectTailBytes(class_id: class.ClassId, slots2_layout: bool) usize`。
- **作用**：按class和布局计算固定头后的实际存储。
- **实现**：slots2时断言class是普通Object并只返回trailing_property_bytes；其它返回unionArmBytes，加上仅内建Promise需要的PromisePayload大小。
- **所有权 / 错误 / 调用**：slots2没有另加payload arm；内建Promise状态inline，自定义promise payload类不自动获得这段尾部。class与布局须与创建/销毁一致。

### `prepareNonBlockObjectAllocation` (`src/core/object.zig:601`)

- **签名**：`noinline fn prepareNonBlockObjectAllocation(context: *anyopaque) std.mem.Allocator.Error!void`。
- **作用**：为Object的非block兼容路线预备成员权威容量。
- **实现**：context转换为JSRuntime，try rt.gc.prepareNonBlockObjectAuthority()。
- **所有权 / 错误 / 调用**：错误传播；不分配Object、不发布，runtime须已建立相应authority。

### `Object.allocCell` (`src/core/object.zig:575`)

- **签名**：`inline fn allocCell(rt: *JSRuntime, class_id: class.ClassId, comptime has_trailing: bool) !*Object`。
- **作用**：按运行时class申请尚未初始化的Object存储。
- **实现**：createObjectWithFamNoTrigger(Object,objectTailBytes(...),rt,prepareNonBlockObjectAllocation)。
- **所有权 / 错误 / 调用**：可能OOM，尚未填写class/shape/属性；NoTrigger不排除memory limit hook，非block回退准备由memory分配流程调用。

### `Object.allocCellConst` (`src/core/object.zig:588`)

- **签名**：`inline fn allocCellConst( rt: *JSRuntime, comptime class_id: class.ClassId, comptime has_trailing: bool, ) !*Object`。
- **作用**：按编译期class和布局申请Object。
- **实现**：调用createObjectConstFamNoTrigger，尾部尺寸编译期计算，传相同rt及prepare回调。
- **所有权 / 错误 / 调用**：与allocCell的初始化/所有权合同相同；编译期路线便于固定class分配，不保证一定成功走block。

### `Object.freeRawCellConst` (`src/core/object.zig:606`)

- **签名**：`inline fn freeRawCellConst( rt: *JSRuntime, self: *Object, comptime class_id: class.ClassId, comptime has_trailing: bool, ) void`。
- **作用**：按编译期分配布局归还Object原始存储。
- **实现**：memory.destroyConstFam(Object,objectTailBytes(class_id,has_trailing),self)。
- **所有权 / 错误 / 调用**：供构造回滚等路径，不依赖未初始化的Object flags；传入class/布局须匹配，不自动清理已建立的资源。

### `Object.freeRawCell` (`src/core/object.zig:618`)

- **签名**：`inline fn freeRawCell(rt: *JSRuntime, self: *Object, class_id: class.ClassId, comptime has_trailing: bool) void`。
- **作用**：按调用方保存的class及布局归还原始Object存储。
- **实现**：调用memory.destroyWithFam(Object,self,objectTailBytes(...))。
- **所有权 / 错误 / 调用**：不从尚未初始化的head推断布局；不是完整Object析构或GC unpublication。

### `Object.armBase` (`src/core/object.zig:624`)

- **签名**：`inline fn armBase(self: *const Object) usize`。
- **作用**：取得非slots2对象class-data尾部起点。
- **实现**：断言非slots2，返回self地址+sizeOf(Object)，即body+24。
- **所有权 / 错误 / 调用**：slots2同位置属于Entry[2]，不能用于payload arm；不分配或验证实际尾部容量。

### `Object.assertArmReadable` (`src/core/object.zig:641`)

- **签名**：`inline fn assertArmReadable(self: *const Object, comptime T: type) void`。
- **作用**：在安全构建核对class臂宽度能否容纳指定类型。
- **实现**：非runtime_safety返回；其余断言unionArmBytes(class_id)>=sizeOf(T)。
- **所有权 / 错误 / 调用**：只检查宽度，不查实际active arm、kind、成员资格或是否Object被按值复制；不能当类型安全转换证明。

### `Object.payloadArm` (`src/core/object.zig:648`)

- **签名**：`pub inline fn payloadArm(self: *const Object) *class.Payload`。
- **作用**：借用非slots2对象class-data首指针槽。
- **实现**：断言非slots2，以armBase转为*class.Payload。
- **所有权 / 错误 / 调用**：即使self是const也返回可变槽；不证明当前有效臂确为payload，调用方负责class/payload状态。

### `Object.asyncResumeArm` (`src/core/object.zig:653`)

- **签名**：`fn asyncResumeArm(self: *const Object) *?*Object`。
- **作用**：取得async resume类的continuation指针槽。
- **实现**：断言class.isAsyncFunctionResumeClass、payload_kind为none及非slots2，再armBase转换。
- **所有权 / 错误 / 调用**：借用可变槽，不执行屏障；断言是调用合同而非任意对象的可失败查询。

### `Object.asyncResumeContinuation` (`src/core/object.zig:660`)

- **签名**：`pub fn asyncResumeContinuation(self: *const Object) ?*Object`。
- **作用**：读取async resume对象当前continuation。
- **实现**：返回asyncResumeArm().*。
- **所有权 / 错误 / 调用**：可能null，继承arm类型前提；不增加引用或pin。

### `Object.setAsyncResumeContinuation` (`src/core/object.zig:664`)

- **签名**：`pub fn setAsyncResumeContinuation(self: *Object, rt: *JSRuntime, continuation: ?*Object) void`。
- **作用**：更新continuation强边并执行对应写屏障。
- **实现**：先赋asyncResumeArm槽；非null时对owner与stored的header调用generationalBarrier。
- **所有权 / 错误 / 调用**：置null不调用屏障；不手动销毁旧continuation，也不获取宿主pin，GC处理可达性。

### `Object.arrayArm` (`src/core/object.zig:669`)

- **签名**：`pub inline fn arrayArm(self: *const Object) *DenseArrayStorage`。
- **作用**：借用足够宽的class-data作为DenseArrayStorage。
- **实现**：assertArmReadable后armBase转为*DenseArrayStorage。
- **所有权 / 错误 / 调用**：只验证宽度和非slots2，未证明当前class/flags具有dense语义；返回可变借用。

### `Object.bytecodeArm` (`src/core/object.zig:674`)

- **签名**：`pub inline fn bytecodeArm(self: *const Object) *BytecodeFunctionStorage`。
- **作用**：借用class-data作为BytecodeFunctionStorage。
- **实现**：检查臂宽度，再从armBase转换。
- **所有权 / 错误 / 调用**：不是按class检查bytecode函数的可失败接口，调用者先保证语义类型及初始化。

### `Object.regexpArm` (`src/core/object.zig:679`)

- **签名**：`pub inline fn regexpArm(self: *const Object) *RegExpPayload`。
- **作用**：借用class-data作为inline RegExpPayload。
- **实现**：检查臂足够容纳RegExpPayload，再从armBase转换。
- **所有权 / 错误 / 调用**：不自动验证regexp class或初始化状态，不能用于任意同宽类。

### `Object.initArmPayload` (`src/core/object.zig:691`)

- **签名**：`inline fn initArmPayload(self: *Object, payload: class.Payload) void`。
- **作用**：初始化新对象的payload臂及实际拥有的剩余臂字节。
- **实现**：断言非slots2；unionArmBytes超过8时只将后续arm-8字节清零，最后写payloadArm首字。
- **所有权 / 错误 / 调用**：不会清整个24字节union以免窄臂越界，也不会初始化Promise额外尾部或payload内容；用于新对象，不负责替换旧payload的资源清理/屏障。

### `Object.traceShapeSummary` (`src/core/object.zig:737`)

- **签名**：`pub inline fn traceShapeSummary(self: *const Object) u8`。
- **作用**：读取不含remembered位的Shape追踪摘要。
- **实现**：返回Metadata.lifetime.object_shape_summary按0x7f掩码的低七位。
- **所有权 / 错误 / 调用**：借用现有前缀，不读Shape、不刷新摘要；正确性依赖各属性更新路径同步维护。

### `Object.traceShapeSummaryIsExact` (`src/core/object.zig:741`)

- **签名**：`pub inline fn traceShapeSummaryIsExact(summary: u8) bool`。
- **作用**：检查摘要count是否仍可精确表示0至2个槽。
- **实现**：判断summary低两位不等于3。
- **所有权 / 错误 / 调用**：不验证高位payload编码或与Shape一致；传入原始含remembered的字节也仅看低两位。

### `Object.traceShapeSummaryCount` (`src/core/object.zig:745`)

- **签名**：`pub inline fn traceShapeSummaryCount(summary: u8) usize`。
- **作用**：从精确摘要读已用属性槽数量。
- **实现**：断言IsExact，再返回低两位。
- **所有权 / 错误 / 调用**：返回0..2，包含已删除槽占用的位置，不是活属性枚举数量。overflow输入违反前提，安全检查关闭时不能当有效count使用。

### `Object.traceShapeSummaryFlagsAt` (`src/core/object.zig:750`)

- **签名**：`pub inline fn traceShapeSummaryFlagsAt(summary: u8, index: usize) property.Flags`。
- **作用**：从精确摘要解码指定槽的追踪类型或deleted状态。
- **实现**：先mask低七位，断言exact及index<count；payload右移2，slot0取模5、slot1除5。状态4返回仅deleted位的Flags，其它按kind位移3构造Flags。
- **所有权 / 错误 / 调用**：不恢复writable/enumerable/configurable；deleted槽原kind不保留。适用于源码维护的有效编码，不是任意u8摘要的验证器。

### `Object.traceShapeSlotState` (`src/core/object.zig:764`)

- **签名**：`inline fn traceShapeSlotState(flags: property.Flags) u8`。
- **作用**：将完整属性Flags压缩为五种追踪状态。
- **实现**：deleted优先返回4，否则返回kind枚举值0..3。
- **所有权 / 错误 / 调用**：忽略W/E/C和其它非追踪信息；deleted覆盖原kind。

### `Object.shapeSummaryFor` (`src/core/object.zig:771`)

- **签名**：`fn shapeSummaryFor(shape_ref: *const shape.Shape) u8`。
- **作用**：从Shape描述符计算精确或overflow摘要。
- **实现**：prop_count>2直接返回3；否则读取前0至2个Property flags，按slot0+5*slot1编码payload，左移2并合入count。
- **所有权 / 错误 / 调用**：count取prop_count而非非deleted属性数；只读Shape，不含remembered、不改Object。flags的W/E/C不会进入摘要。

### `Object.storeTraceShapeSummary` (`src/core/object.zig:782`)

- **签名**：`inline fn storeTraceShapeSummary(self: *Object, summary: u8) void`。
- **作用**：写入Shape摘要并保留GC remembered lease。
- **实现**：断言summary不含低七位之外的位；保存原字节bit7并与summary合并写回。
- **所有权 / 错误 / 调用**：普通读改写，非原子并发同步；调用者须传合法摘要，断言只约束位宽不验证编码。

### `Object.refreshTraceShapeSummary` (`src/core/object.zig:792`)

- **签名**：`pub inline fn refreshTraceShapeSummary(self: *Object) void`。
- **作用**：从当前Shape完整重建Object摘要。
- **实现**：shapeSummaryFor(self.shape_ref)后storeTraceShapeSummary。
- **所有权 / 错误 / 调用**：保留remembered位，可能从overflow恢复为exact；不修改Shape或property值，也不执行写屏障。

### `Object.traceShapeSummaryMatches` (`src/core/object.zig:796`)

- **签名**：`pub fn traceShapeSummaryMatches(self: *const Object) bool`。
- **作用**：核对缓存摘要是否与当前Shape追踪布局一致。
- **实现**：读取并mask stored，重算expected。expected overflow时只检查stored也非exact；其它情况要求整个低七位相等。
- **所有权 / 错误 / 调用**：overflow payload是don’t-care，不要求等于裸3；不核对remembered map、属性值或完整描述符W/E/C。

### `Object.commitTraceShapeAppend` (`src/core/object.zig:809`)

- **签名**：`inline fn commitTraceShapeAppend(self: *Object, old_len: usize, flags: property.Flags) void`。
- **作用**：在属性追加后增量更新追踪摘要。
- **实现**：old_len>2无操作，==2将完整字节环绕加1使count变overflow并保留payload。old_len<2时断言旧摘要exact且count相符；新槽为live data状态0时字节加1，其余以base5追加状态并store新摘要。
- **所有权 / 错误 / 调用**：不实际追加Shape/Entry。字节增量保留bit7依赖合法已有编码和old_len合同；第三次追加保留的payload不再有语义，不应要求overflow摘要必为3。

### `Object.syncTraceShapePropertyFlags` (`src/core/object.zig:845`)

- **签名**：`inline fn syncTraceShapePropertyFlags(self: *Object, index: usize, flags: property.Flags) void`。
- **作用**：同步精确摘要中某槽的追踪状态变更。
- **实现**：旧摘要overflow立即返回；exact时断言index<count，拆base5状态，替换指定槽，保持count并store。
- **所有权 / 错误 / 调用**：保留remembered，忽略W/E/C变更；不写Shape，调用方负责先更新权威描述符。

### `Object.updateShapePropertyFlags` (`src/core/object.zig:862`)

- **签名**：`inline fn updateShapePropertyFlags(self: *Object, rt: *JSRuntime, index: usize, flags: property.Flags) void`。
- **作用**：同时更新Shape描述符Flags与Object追踪摘要。
- **实现**：先rt.shapes.updatePropertyFlags(shape_ref,index,flags.bits())，再syncTraceShapePropertyFlags。
- **所有权 / 错误 / 调用**：不更新属性值或调用GC target屏障；没有error返回，索引和Shape修改协议由调用者保证。

## 覆盖核对

- 清单函数数（本文件分到）: 43（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 43
- 未覆盖: 无
