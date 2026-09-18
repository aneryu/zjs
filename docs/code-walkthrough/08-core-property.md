# 08 — `property.zig` 与 `module_auto_init.zig`

属性元数据、对象 shape 槽的存储变体、AUTOINIT intern。`module_auto_init.zig` 是无 Runtime 依赖的 MODULE_NS 叶子契约（零函数）。

QuickJS：`JSShapeProperty` / `JSProperty`（quickjs.c:944-963）、`JS_PROP_TMASK`（quickjs.h:303-307）。本层只许依赖 core/libs。

## `src/core/module_auto_init.zig`（类型）

文件职责：MODULE_NS 延迟导出与 AUTOINIT 槽共享的解析契约。刻意不依赖 Runtime。MODULE_NS 槽自己持有构造 Realm；下面的 owner 是嵌在地址稳定的 module record 里的不可变 Interface。

`AutoInitMaterialization`：`union(enum)`。

- `value: JSValue` — 新拥有的命名空间值。
- `var_ref: *VarRef` — 属性直接保存并追踪的已有 export cell（不表示执行 RC retain）。解析器**从不**快照 VarRef 当前值。

`AutoInitModuleOwner`：存在 AUTOINIT 第二字里的稳定模块 Interface。

- `resolve: *const fn (owner: *const AutoInitModuleOwner, realm_header: *gc.Header, atom_id: atom.Atom) anyerror!AutoInitMaterialization`
- `atom_id` 是正在物化的 namespace export。一个不可变 owner 服务同一模块的全部延迟导出，对齐 qjs `(module, property atom)`，不为每个属性再包一层。

`property.zig` 用 `pub const AutoInitMaterialization` / `AutoInitModuleOwner` 再导出，方便历史 import。

## `property.zig` 类型

`Kind`（`enum(u2)`）：`data` / `accessor` / `var_ref` / `auto_init`。kind 在 shape flags，不在值 cell。顺序对齐 qjs NORMAL/GETSET/VARREF/AUTOINIT。

`Flags`：`packed struct(u6)`，默认w/e/c/deleted全false、kind=data；位0/1/2为w/e/c，3–4为kind，5为deleted。字段为 `writable` / `enumerable` / `configurable` / `kind: Kind` / `deleted`。deleted 对应 qjs `atom == JS_ATOM_NULL`。

`Accessor`：`getter`/`setter` 为 `?*gc.Header`（16B），缺省 null = undefined。

`AutoInitKind`：物化产物种类（native_function、各 namespace、console、empty_array…）。

`ArrayBuiltinMarker` / `TypedArrayBuiltinMarker`：给已物化函数打的内建标记，供 species / 方法快路径。

`AutoInitId`（`enum(u2)`）：`prototype=0` / `module_ns=1` / `prop=2`。塞进 Realm 指针低 2 位。

`RealmAndAutoInitId`：`extern struct { raw: usize }`。Realm 头至少 4 字节对齐。

`AutoInitSlot`：两字 QJS 形 AUTOINIT payload。`opaque_ptr` 为 null（PROTOTYPE）、`*const AutoInitModuleOwner`（MODULE_NS）或 `*const AutoInit`（PROP）。从不指向拥有对象或可变缓存。

`AutoInit`：不可变 PROP 建造事实。Runtime/Realm 所有权在两字槽里，不在这份可共享描述符。含 name/length/kind、host/native id与entry、prototype开关、Array/TypedArray/iterator/collection/disposal标记、prepare_native_function。prepare回调只许给新函数补元数据、不修改或保留拥有AUTOINIT槽的对象，这是回调合同而非类型系统强制。intern浅拷name slice，不拥有一份字符串副本。

`Slot`：按外部 flags 判别的无显式标签 union（`data` / `accessor` / `auto_init` / `var_ref`）。写槽必须配对写 `Flags.kind`。ReleaseFast/Small 下 `@sizeOf(Slot)==16`。

`Entry`：对象侧属性存储，只有 `slot`。atom 与 flags 在 `shape.Property`，下标 1:1。

---

### `Flags.data` (`src/core/property.zig:37`)

- **签名**：`pub fn data(writable: bool, enumerable: bool, configurable: bool) Flags`。
- **作用**：构造 data 属性标志。
- **实现**：复制参数 writable/enumerable/configurable，设置 kind；其余字段使用默认值，deleted=false。
- **所有权 / 错误 / 调用**：只返回标志，不安装 Slot 或验证描述符；accessor 的 writable 默认false，var_ref 并不限于全局词法绑定。

### `Flags.accessorFlags` (`src/core/property.zig:46`)

- **签名**：`pub fn accessorFlags(enumerable: bool, configurable: bool) Flags`。
- **作用**：构造 accessor 属性标志。
- **实现**：复制参数 enumerable/configurable，设置 kind；其余字段使用默认值，deleted=false。
- **所有权 / 错误 / 调用**：只返回标志，不安装 Slot 或验证描述符；accessor 的 writable 默认false，var_ref 并不限于全局词法绑定。

### `Flags.varRef` (`src/core/property.zig:54`)

- **签名**：`pub fn varRef(writable: bool, enumerable: bool, configurable: bool) Flags`。
- **作用**：构造 var_ref 属性标志。
- **实现**：复制参数 writable/enumerable/configurable，设置 kind；其余字段使用默认值，deleted=false。
- **所有权 / 错误 / 调用**：只返回标志，不安装 Slot 或验证描述符；accessor 的 writable 默认false，var_ref 并不限于全局词法绑定。

### `Flags.withKind` (`src/core/property.zig:64`)

- **签名**：`pub fn withKind(self: Flags, kind: Kind) Flags`。
- **作用**：改变种类并恢复非删除状态。
- **实现**：复制 self，改 kind 并清 deleted，保留 w/e/c。
- **所有权 / 错误 / 调用**：不转换值槽；调用方必须同步 Slot 的活动臂。

### `Flags.asDeleted` (`src/core/property.zig:71`)

- **签名**：`pub fn asDeleted(self: Flags) Flags`。
- **作用**：构造删除墓碑标志。
- **实现**：复制后 kind=data、writable=false、deleted=true，保留 enumerable/configurable。
- **所有权 / 错误 / 调用**：不清 atom 或值槽、不修改 Shape；这些动作属于拥有者。

### `Flags.isAccessor` (`src/core/property.zig:79`)

- **签名**：`pub fn isAccessor(self: Flags) bool`。
- **作用**：判断是否为未删除的 accessor 属性。
- **实现**：!deleted 且 kind 匹配。
- **所有权 / 错误 / 调用**：不读取槽、不执行访问器或物化。

### `Flags.isVarRef` (`src/core/property.zig:83`)

- **签名**：`pub fn isVarRef(self: Flags) bool`。
- **作用**：判断是否为未删除的 var_ref 属性。
- **实现**：!deleted 且 kind 匹配。
- **所有权 / 错误 / 调用**：不读取槽、不执行访问器或物化。

### `Flags.isAutoInit` (`src/core/property.zig:87`)

- **签名**：`pub fn isAutoInit(self: Flags) bool`。
- **作用**：判断是否为未删除的 auto_init 属性。
- **实现**：!deleted 且 kind 匹配。
- **所有权 / 错误 / 调用**：不读取槽、不执行访问器或物化。

### `Flags.bits` (`src/core/property.zig:91`)

- **签名**：`pub fn bits(self: Flags) u6`。
- **作用**：将六位标志编码为u6。
- **实现**：bitCast self。
- **所有权 / 错误 / 调用**：位0/1/2为w/e/c、3–4为kind、5为deleted；无分配。

### `Flags.fromBits` (`src/core/property.zig:95`)

- **签名**：`pub fn fromBits(bits_value: u6) Flags`。
- **作用**：从u6还原标志。
- **实现**：bitCast bits_value。
- **所有权 / 错误 / 调用**：不验证属性语义，所有六位组合都可表示。

### `Accessor.fromBorrowedValues` (`src/core/property.zig:109`)

- **签名**：`pub fn fromBorrowedValues(getter_value: JSValue, setter_value: JSValue) Accessor`。
- **作用**：将getter/setter值转换为紧凑header指针对。
- **实现**：分别调用 accessorHeaderFromValue；undefined变null，其他值要求Object。
- **所有权 / 错误 / 调用**：不检查 callable、不retain或建立根；合法访问器语义由调用方验证。

### `Accessor.getterValue` (`src/core/property.zig:116`)

- **签名**：`pub fn getterValue(self: Accessor) JSValue`。
- **作用**：读取 getter 的JSValue表示。
- **实现**：委托 valueFromAccessorHeader，null返回undefined，否则object-tag值。
- **所有权 / 错误 / 调用**：不调用函数，不独立保活或验证header种类。

### `Accessor.setterValue` (`src/core/property.zig:120`)

- **签名**：`pub fn setterValue(self: Accessor) JSValue`。
- **作用**：读取 setter 的JSValue表示。
- **实现**：委托 valueFromAccessorHeader，null返回undefined，否则object-tag值。
- **所有权 / 错误 / 调用**：不调用函数，不独立保活或验证header种类。

### `Accessor.getterIsUndefined` (`src/core/property.zig:124`)

- **签名**：`pub fn getterIsUndefined(self: Accessor) bool`。
- **作用**：判断 getter 是否缺失。
- **实现**：检查对应指针==null。
- **所有权 / 错误 / 调用**：不查询对象属性或执行调用。

### `Accessor.setterIsUndefined` (`src/core/property.zig:128`)

- **签名**：`pub fn setterIsUndefined(self: Accessor) bool`。
- **作用**：判断 setter 是否缺失。
- **实现**：检查对应指针==null。
- **所有权 / 错误 / 调用**：不查询对象属性或执行调用。

### `Accessor.syncGetterFromVisitedValue` (`src/core/property.zig:136`)

- **签名**：`pub fn syncGetterFromVisitedValue(self: *Accessor, value: JSValue) void`。
- **作用**：回写visitor更新后的 getter 值。
- **实现**：将 accessorHeaderFromValue(value) 写入对应字段。
- **所有权 / 错误 / 调用**：要求Object或undefined；不执行callable验证、分配或owner屏障。

### `Accessor.syncSetterFromVisitedValue` (`src/core/property.zig:140`)

- **签名**：`pub fn syncSetterFromVisitedValue(self: *Accessor, value: JSValue) void`。
- **作用**：回写visitor更新后的 setter 值。
- **实现**：将 accessorHeaderFromValue(value) 写入对应字段。
- **所有权 / 错误 / 调用**：要求Object或undefined；不执行callable验证、分配或owner屏障。

### `accessorHeaderFromValue` (`src/core/property.zig:145`)

- **签名**：`fn accessorHeaderFromValue(value: JSValue) ?*gc.Header`。
- **作用**：把Object/undefined值转为可空header。
- **实现**：undefined返回null，否则断言isObject，再取非空refHeader。
- **所有权 / 错误 / 调用**：内部调用前提，不是通用可调用性检查；其他输入不保证返回可恢复错误。

### `valueFromAccessorHeader` (`src/core/property.zig:151`)

- **签名**：`fn valueFromAccessorHeader(header: ?*gc.Header) JSValue`。
- **作用**：把可空header转成访问器值。
- **实现**：非空用JSValue.object，空用undefinedValue。
- **所有权 / 错误 / 调用**：不检查header GC kind或存活，不复制对象。

### `RealmAndAutoInitId.retain` (`src/core/property.zig:201`)

- **签名**：`pub fn retain(realm_header: *gc.Header, init_id: AutoInitId) RealmAndAutoInitId`。
- **作用**：把realm header和分派id打包进一字。
- **实现**：断言header kind为realm_context且地址低两位为0，返回address OR enum id。
- **所有权 / 错误 / 调用**：名称retain不代表RC计数；不注册根或屏障，拥有者须追踪此边。

### `RealmAndAutoInitId.id` (`src/core/property.zig:208`)

- **签名**：`pub fn id(self: RealmAndAutoInitId) AutoInitId`。
- **作用**：解码低两位AUTOINIT id。
- **实现**：断言raw非0，再enumFromInt(raw&3)。
- **所有权 / 错误 / 调用**：值3没有枚举项，不是合法id；不验证高位确有realm地址。

### `RealmAndAutoInitId.realmHeader` (`src/core/property.zig:213`)

- **签名**：`pub fn realmHeader(self: RealmAndAutoInitId) ?*gc.Header`。
- **作用**：从打包字恢复可空realm header。
- **实现**：去掉低两位；剩余地址0返回null，否则ptrFromInt。
- **所有权 / 错误 / 调用**：不检查GC kind、分配登记或地址存活。

### `RealmAndAutoInitId.syncRealmHeader` (`src/core/property.zig:218`)

- **签名**：`pub fn syncRealmHeader(self: *RealmAndAutoInitId, realm_header: *gc.Header) void`。
- **作用**：保持id并更新realm地址。
- **实现**：检查新header kind/对齐，先读取原id，再写新地址与原id。
- **所有权 / 错误 / 调用**：原raw必须含合法id；新header不可空，不做RC或额外屏障。

### `AutoInitSlot.retainOpaque` (`src/core/property.zig:234`)

- **签名**：`fn retainOpaque(realm_header: *gc.Header, init_id: AutoInitId, opaque_ptr: ?*const anyopaque) AutoInitSlot`。
- **作用**：构造两字AUTOINIT槽。
- **实现**：用RealmAndAutoInitId.retain打包realm/id，保存opaque_ptr。
- **所有权 / 错误 / 调用**：不复制opaque内容、分配或检查其动态类型；指针稳定性由调用协议保证。

### `AutoInitSlot.retainPrototype` (`src/core/property.zig:241`)

- **签名**：`pub fn retainPrototype(realm_header: *gc.Header) AutoInitSlot`。
- **作用**：构造prototype物化槽。
- **实现**：retainOpaque(realm,prototype,null)。
- **所有权 / 错误 / 调用**：不创建prototype；仅保存realm追踪边。

### `AutoInitSlot.retainProp` (`src/core/property.zig:245`)

- **签名**：`pub fn retainProp(realm_header: *gc.Header, stored_descriptor: *const AutoInit) AutoInitSlot`。
- **作用**：构造共享PROP描述符槽。
- **实现**：retainOpaque(realm,prop,stored_descriptor转opaque)。
- **所有权 / 错误 / 调用**：不intern或复制descriptor；调用者必须已提供存活期合适的稳定记录。

### `AutoInitSlot.retainModule` (`src/core/property.zig:249`)

- **签名**：`pub fn retainModule(realm_header: *gc.Header, owner: *const AutoInitModuleOwner) AutoInitSlot`。
- **作用**：构造模块namespace延迟导出槽。
- **实现**：retainOpaque(realm,module_ns,owner转opaque)。
- **所有权 / 错误 / 调用**：不调用resolve，不创建独立每属性owner；模块owner必须保持地址稳定且存活。

### `AutoInitSlot.descriptor` (`src/core/property.zig:253`)

- **签名**：`pub fn descriptor(self: AutoInitSlot) ?*const AutoInit`。
- **作用**：借用PROP描述符。
- **实现**：id非prop返回null，opaque为空返回null，否则alignCast/ptrCast为AutoInit。
- **所有权 / 错误 / 调用**：不验证record内容或runtime归属，非法打包id仍违反id()前提。

### `AutoInitSlot.moduleOwner` (`src/core/property.zig:259`)

- **签名**：`pub fn moduleOwner(self: AutoInitSlot) ?*const AutoInitModuleOwner`。
- **作用**：借用MODULE_NS解析owner。
- **实现**：id非module_ns或opaque为空返回null，否则对齐转换指针类型。
- **所有权 / 错误 / 调用**：不执行resolver或保活模块；类型正确性由构造路径保证。

### `AutoInit.eql` (`src/core/property.zig:297`)

- **签名**：`fn eql(self: AutoInit, other: AutoInit) bool`。
- **作用**：比较两份PROP builder事实是否相同。
- **实现**：name按字节内容比较，其余全部字段逐项相等，包括native_entry与prepare回调指针身份。
- **所有权 / 错误 / 调用**：不比较name地址或realm；不调用回调，不把不同函数指针的行为等价当作相等。

### `internAutoInit` (`src/core/property.zig:355`)

- **签名**：`pub fn internAutoInit(rt: *JSRuntime, info: AutoInit) !*const AutoInit`。
- **作用**：在runtime中线性查找或登记稳定描述符。
- **实现**：遍历auto_init_descriptors，eql命中复用；否则createRuntime(AutoInit)、浅拷info，以persistent_allocator追加索引。追加失败destroy新记录。
- **所有权 / 错误 / 调用**：仅记录地址稳定，name slice没有复制，其字节须由调用方保证足够长的寿命；callback和entry亦仅借用。不能把浅拷说成深度拥有所有描述符输入。

### `autoInit` (`src/core/property.zig:369`)

- **签名**：`pub fn autoInit(ref: anytype) *const AutoInit`。
- **作用**：从PROP槽取得非空描述符。
- **实现**：仅接受类型恰为AutoInitSlot的输入；descriptor为空unreachable，其他编译期类型compileError。
- **所有权 / 错误 / 调用**：不物化属性、不intern；不接受指向槽的指针作为同义输入。

## 覆盖核对

- 清单函数数: 32
- 本文标题覆盖: 32
- 未覆盖: 无
