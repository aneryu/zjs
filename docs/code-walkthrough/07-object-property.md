# 07 — 属性存储、dense 字面量、查找与迭代器工厂（`src/core/object.zig`）

`prop_values` 指针机械、`.property_storage` cell、shape 转移、`appendPreparedPropertyEntry*`、find 快路径、dense 元素 define/append、`Object.keys/values/entries`、String Iterator 工厂。

append 契约：容量不足 mint 新 cell（旧的交给 sweep）；值先写入 over-hang 下标再 commit shape；atom 由调用方或本函数的 atom root frame 保住。`named_put_no_index` 单态去掉 `atomIsArrayIndex`（OP_put_field 普通 miss）。

---


### `Object.isAccessorOrAccessorPlaceholderAt` (`src/core/object.zig:7873`)

- **签名**：`fn isAccessorOrAccessorPlaceholderAt(self: *const Object, index: usize) bool`。
- **作用**：判断指定属性是否是未删除 accessor。
- **实现**：读取 flags，返回 !deleted && kind==accessor。
- **所有权 / 错误 / 调用**：名称虽含 placeholder，但 auto-init 不算 accessor；不分配、调用 getter 或物化属性。

### `Object.defineOwnDataValueAssumingNew` (`src/core/object.zig:8212`)

- **签名**：`pub fn defineOwnDataValueAssumingNew( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue, flags: property.Flags, ) !void`。
- **作用**：用预设非索引 atom 向新属性槽安装 data 值。
- **实现**：断言无 exotic methods、extensible、flags.kind==data，再 appendPreparedPropertyEntryImpl(true,true,atom,flags,data_value)。
- **所有权 / 错误 / 调用**：不查重复项；调用方保证 atom 在分配窗口独立保活、不是索引及对象布局适用。当前无源码注释所述 RC dup/free。

### `Object.reserveOwnPropertyCapacityAssumingPlain` (`src/core/object.zig:8463`)

- **签名**：`pub fn reserveOwnPropertyCapacityAssumingPlain(self: *Object, rt: *JSRuntime, needed: usize) !void`。
- **作用**：为批量安装预留属性存储和 Shape hash 容量。
- **实现**：断言适用 plain storage 等条件；存储与 Shape 预留均已足够则返回，否则 ensureUniqueShapeForMutation、ensurePropertyCapacity、reservePropertyHash，最后屏障当前 shape。
- **所有权 / 错误 / 调用**：不增加属性数；多个可失败步骤不构成整体事务，后续失败可能保留前面克隆或扩容结果。supportsPlainNamedPropertyStorage 不只允许 class==object。

### `Object.appendModuleAutoInitProperty` (`src/core/object.zig:8621`)

- **签名**：`fn appendModuleAutoInitProperty( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, realm: *context_mod.RealmContext, owner: *const property.AutoInitModuleOwner, ) !void`。
- **作用**：用稳定模块 owner 与 realm 构造并追加 auto-init 槽。
- **实现**：断言 realm.runtime==rt、plain named storage、extensible；retainModule(realm.header,owner) 后 appendPreparedPropertyEntry，改 flags.kind 为 auto_init。
- **所有权 / 错误 / 调用**：此 helper 自身不检查 module_ns class 或重复 key；不复制 owner，也不执行 resolver。

### `Object.canExtendFastArray` (`src/core/object.zig:8945`)

- **签名**：`pub fn canExtendFastArray(self: *const Object) bool`。
- **作用**：检查无需走原型索引路径时的扩展条件。
- **实现**：不可扩展 false；直接 prototype 为 null 则 true，否则读取 prototype.is_std_array_prototype。
- **所有权 / 错误 / 调用**：本函数不检查 self 是 Array、fast 模式、length 可写或 count==length；调用方须另外证明这些条件。

### `Object.appendDenseArrayIndex` (`src/core/object.zig:8951`)

- **签名**：`pub fn appendDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：按普通赋值的快速条件在 dense count 位置追加。
- **实现**：要求 Array、index==count、length 可写、无 exotic、dense、canExtendFastArray；若有 shape 属性则拒绝同 atom 命中。appendInitializedFastArrayValue 后 length 取至少 index+1，标记 indexed properties，返回 true。
- **所有权 / 错误 / 调用**：不要求 count==length，允许填入尾部 hole 范围的 count 位置。true 表示已安装，false 表示回退，分配错误传播；atom 必须对应 index。原先的 appendDenseArrayIndexMode 中转层与 `comptime take_ownership` 已删除（两支都是 new_value，没有 RC 差异）。

### `Object.appendDenseArrayIndexOwned` (`src/core/object.zig:8972`)

- **签名**：`pub const appendDenseArrayIndexOwned = appendDenseArrayIndex;`。
- **作用**：QuickJS 消费式 OP_put_array_el 存储沿用的第二个名字。
- **实现**：就是 appendDenseArrayIndex 本身的别名，不是转发函数。
- **所有权 / 错误 / 调用**：tracing GC 下追加既不 retain 也不 release，所谓 owned/borrowed 两支曾是逐字相同的函数体，现已合并为同一实现。

### `Object.appendFastArrayPushValues` (`src/core/object.zig:8978`)

- **签名**：`pub fn appendFastArrayPushValues(self: *Object, rt: *JSRuntime, values: []const JSValue) !void`。
- **作用**：在上层已证明 push 条件时批量追加元素。
- **实现**：values.len 转 u32，与 count 相加；必要时扩容，依次写元素并逐项屏障，更新 count，必要时扩 length，非空则 markIndexedProperties。
- **所有权 / 错误 / 调用**：本函数不重验 class/fast/extensible/原型/length writable/整数上限，调用方必须保证。输入在扩容时保持可达且借用有效；不执行一般 Set 或命名属性探测。

### `Object.initDenseArrayIndexZeroAssumingEmpty` (`src/core/object.zig:8995`)

- **签名**：`pub fn initDenseArrayIndexZeroAssumingEmpty(self: *Object, rt: *JSRuntime, new_value: JSValue) !void`。
- **作用**：为无 backing 的空 dense 存储初始化第零项。
- **实现**：断言 Array、count 零、length 可写、extensible、elements 空、capacity 零；追加已初始化值，length 至少置 1，再标 indexed properties。
- **所有权 / 错误 / 调用**：不要求原 length 为零，不查询原型或同名属性；调用方负责受控初始化语义和分配窗口的输入存活。

### `Object.appendDenseArrayLiteralIndex` (`src/core/object.zig:9008`)

- **签名**：`pub fn appendDenseArrayLiteralIndex(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool`。
- **作用**：用 index 派生 atom 后走 dense define 追加。
- **实现**：调用 appendDenseArrayDefineIndex(rt,index,atomFromUInt32(index),new_value)。
- **所有权 / 错误 / 调用**：不是任意位置替换；继承 index==count 等限制及 false 回退约定。

### `Object.appendDenseArrayDefineIndex` (`src/core/object.zig:9015`)

- **签名**：`pub fn appendDenseArrayDefineIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：以新自有 data 属性语义在 dense count 位置追加。
- **实现**：要求 Array、index==count、length 可写、dense、extensible；shape 非空时用 trusted probe 拒绝同 atom。追加值，必要时扩 length，再 markIndexedProperties。
- **所有权 / 错误 / 调用**：不检查 canExtendFastArray 或 inherited setter，也没有显式 hasExoticMethods 拒绝；适用条件由上层保证。index 与 atom 对应关系未验证；原 appendDenseArrayDefineIndexMode 中转层与 `comptime take_ownership` 已删除。

### `Object.appendDenseArrayDefineIndexOwned` (`src/core/object.zig:9031`)

- **签名**：`pub const appendDenseArrayDefineIndexOwned = appendDenseArrayDefineIndex;`。
- **作用**：QuickJS 消费式 JS_DefinePropertyValue 契约沿用的第二个名字。
- **实现**：就是 appendDenseArrayDefineIndex 本身的别名，不是转发函数。
- **所有权 / 错误 / 调用**：tracing GC 移除了这对名字所代表的 retain/release，两个函数体已逐字相同，现合并为同一实现。

### `Object.initDenseArrayLiteralValuesAssumingEmpty` (`src/core/object.zig:9033`)

- **签名**：`pub fn initDenseArrayLiteralValuesAssumingEmpty(self: *Object, rt: *JSRuntime, values: []const JSValue) !bool`。
- **作用**：尝试把元素序列填入初始空 dense Array。
- **实现**：要求 Array、length 可写、extensible、count/length/shape.prop_count 均零、dense、输入长度不超 max_array_length，否则 false。扩容后先设置 count/length，再逐项写入、批量屏障；非空标 indexed，返回 true。
- **所有权 / 错误 / 调用**：不要求 capacity 原为零；无原型索引检查，适用于 literal 自有属性创建。发布 count 后到填值完成的区间不能由调用方插入可触发扫描的操作；分配错误传播。

### `Object.initDenseArrayLiteralValuesOwnedTrusted` (`src/core/object.zig:9062`)

- **签名**：`pub fn initDenseArrayLiteralValuesOwnedTrusted(self: *Object, rt: *JSRuntime, values: []const JSValue) !void`。
- **作用**：在已证明初始状态的 Array 上批量填入 literal 值。
- **实现**：将 sibling 的初始状态条件改为断言；空输入直接返回，否则扩容、设置 count/length、memcpy 元素、批量屏障并 markIndexedProperties。
- **所有权 / 错误 / 调用**：不运行时返回 false，也不执行 RC retain/free；输入和对象必须在容量分配期间可达。失败发生在值填入之前，后续步骤不返回错误。

### `Object.barrierInitializedDenseArrayValues` (`src/core/object.zig:9079`)

- **签名**：`inline fn barrierInitializedDenseArrayValues(self: *Object, rt: *JSRuntime, values: []const JSValue) void`。
- **作用**：按 owner 当前 GC 状态决定是否处理整个已初始化元素范围。
- **实现**：barrierOwnerSkips(header) 为 true 直接返回，否则调用 Slow。
- **所有权 / 错误 / 调用**：不写元素；是否可跳过由 GC helper 决定，不能仅凭对象新建或数组为空来省略。

### `Object.barrierInitializedDenseArrayValuesSlow` (`src/core/object.zig:9087`)

- **签名**：`noinline fn barrierInitializedDenseArrayValuesSlow(self: *Object, rt: *JSRuntime, values: []const JSValue) void`。
- **作用**：为已填入的每个值执行 owner 屏障。
- **实现**：逐项 rt.gc.generationalBarrierValue(self.gcHeader(),item)。
- **所有权 / 错误 / 调用**：不修改 count/length 或分配元素存储；primitive 与 GC carrier 的差异交给 barrierValue。

### `Object.reserveDenseArrayElements` (`src/core/object.zig:9091`)

- **签名**：`pub fn reserveDenseArrayElements(self: *Object, rt: *JSRuntime, needed: u32) !void`。
- **作用**：为 Array 请求元素容量。
- **实现**：非 Array 无操作，否则 ensureArrayElementCapacity(needed)。
- **所有权 / 错误 / 调用**：不追加元素或显式改变 length；底层容量 helper 的分配错误传播，不检查原型或扩展语义。

### `Object.defineDenseArrayDataProperty` (`src/core/object.zig:9096`)

- **签名**：`pub fn defineDenseArrayDataProperty(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool`。
- **作用**：尝试覆盖 dense 元素，或在完全 dense 的尾部追加。
- **实现**：拒绝非 Array、exotic、非 dense、同 atom shape 属性以及 index>count。index==count 时要求 extensible、必要的 length writable，并且 index==length，随后扩容/增加 count/length。最后写值、屏障、markIndexedProperties，返回 true。
- **所有权 / 错误 / 调用**：已有 index<count 的覆盖不要求 extensible/length writable；追加不接受 count<length 的尾洞，这是与 appendDenseArrayDefineIndex 不同的边界。false 需上层回退。

### `Object.markIndexedProperties` (`src/core/object.zig:9129`)

- **签名**：`pub fn markIndexedProperties(self: *Object, _: *JSRuntime) void`。
- **作用**：设置对象可能拥有索引属性的保守摘要位。
- **实现**：仅 flags.may_have_indexed_properties=true，rt 未使用。
- **所有权 / 错误 / 调用**：不执行 GC 屏障，也不直接使 realm 的标准数组原型 guard 失效。

### `Object.invalidateStandardArrayPrototypeForTaggedIndexMutation` (`src/core/object.zig:9137`)

- **签名**：`fn invalidateStandardArrayPrototypeForTaggedIndexMutation(self: *Object, rt: *JSRuntime) void`。
- **作用**：使受索引变更影响的标准原型 guard 失效。
- **实现**：self 已标 is_std_array_prototype 则清该位；否则若 immutable_prototype 则调用 runtime.invalidateStandardArrayPrototypeForObjectPrototype(self)。
- **所有权 / 错误 / 调用**：本函数不检查 atom 是否 tagged index，调用位置须已确定；两分支为互斥 if/else if。

### `Object.publishStandardArrayPrototype` (`src/core/object.zig:9145`)

- **签名**：`pub fn publishStandardArrayPrototype(self: *Object) void`。
- **作用**：把已确认无索引属性的 Array 标为标准原型。
- **实现**：断言 isArray 且 !may_have_indexed_properties，再置 is_std_array_prototype=true。
- **所有权 / 错误 / 调用**：不扫描实际属性、不注册 realm 或设置 immutable_prototype，前提由构造流程保证。

### `Object.isStandardArrayPrototype` (`src/core/object.zig:9151`)

- **签名**：`pub fn isStandardArrayPrototype(self: *const Object) bool`。
- **作用**：查询标准数组原型标志。
- **实现**：直接返回 flags.is_std_array_prototype。
- **所有权 / 错误 / 调用**：不验证 realm 身份或重新扫描索引属性。

### `Object.canDefineDenseArrayDataPropertiesUnchecked` (`src/core/object.zig:9155`)

- **签名**：`pub fn canDefineDenseArrayDataPropertiesUnchecked(self: *const Object) bool`。
- **作用**：检查 unchecked dense 定义使用的结构条件。
- **实现**：要求 Array、无 exotic methods、dense/fast_array、extensible、shape.prop_count==0。
- **所有权 / 错误 / 调用**：不检查 index、count/length 关系或 length writable；返回 true 不能证明任意索引写入都会生效。

### `Object.defineDenseArrayDataPropertyUnchecked` (`src/core/object.zig:9164`)

- **签名**：`pub fn defineDenseArrayDataPropertyUnchecked(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !void`。
- **作用**：在预先验证的 dense Array 中覆盖或连续追加值。
- **实现**：断言 canDefine 条件及 index<length 或 length writable。index>count 直接无操作返回；index==count 时扩容并增加 count/必要的 length。最后写值、屏障并 markIndexedProperties。
- **所有权 / 错误 / 调用**：返回 !void，成功返回也可能是 index>count 的无操作；允许在 count<length 时追加 count 位置，不同于完全 dense 限制的 sibling。调用方须保持输入存活。

### `Object.truncateArrayElements` (`src/core/object.zig:9997`)

- **签名**：`pub fn truncateArrayElements(self: *Object, _: *JSRuntime, new_len: u32) void`。
- **作用**：截短 fast Array 的有效 dense count。
- **实现**：非 Array 或非 fast 返回；count 置为 min(new_len,count)。
- **所有权 / 错误 / 调用**：不清尾槽、不改逻辑 length/capacity、不 free backing；退出 `[0,count)` 的尾槽保留旧值但不再被 tracer 读。rt 未使用。（旧实现用 `while (count > len) count -= 1;` 逐项递减，是元素释放随 TGC 移除后留下的空壳，已折叠成一次赋值。）

### `Object.convertDenseArrayElementsToSparseProperties` (`src/core/object.zig:10003`)

- **签名**：`pub fn convertDenseArrayElementsToSparseProperties(self: *Object, rt: *JSRuntime) !void`。
- **作用**：将有效 dense 元素转成普通索引属性。
- **实现**：非 fast 返回；保存 arm.length，遍历当前元素，跳过同 atom 的已有 shape 项，其余 addProperty 为 w/e/c 全 true。全部成功后 count=0，解除 backing capacity/fast 模式，恢复保存的 length，清标准数组原型标志。
- **所有权 / 错误 / 调用**：只物化 [0,count)，尾洞保持缺失；旧 cell 交 GC。中途失败保留 fast backing 和已加的 sparse 项，不是全事务回滚。调用方保证该 arm 表示 JSValue 元素。

### `Object.denseArrayElement` (`src/core/object.zig:10024`)

- **签名**：`fn denseArrayElement(self: *const Object, atom_id: atom.Atom) ?JSValue`。
- **作用**：按 tagged-int atom 读取 dense 元素。
- **实现**：要求 fast_array、atom.isTaggedInt，转 index 后要求 index<count，返回 values[index]，否则 null。
- **所有权 / 错误 / 调用**：不解析普通字符串 atom、不查 class 或原型，也不执行 getter/RC dup。

### `Object.hasDenseArrayElement` (`src/core/object.zig:10032`)

- **签名**：`fn hasDenseArrayElement(self: *const Object, index: u32) bool`。
- **作用**：查询索引是否落在 fast dense extent。
- **实现**：直接返回 isFastArrayIndexInBounds(index)。
- **所有权 / 错误 / 调用**：沿用 fast flag/count 条件，不独立检查 class。

### `Object.setDenseArrayElement` (`src/core/object.zig:10036`)

- **签名**：`fn setDenseArrayElement(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool`。
- **作用**：尝试覆盖现有 dense 元素并标记索引摘要。
- **实现**：非 fast 返回 false；setFastArrayElementDup 失败也 false，成功则 markIndexedProperties 并 true。
- **所有权 / 错误 / 调用**：不追加、不改 length 或检查继承 setter；当前自身无实际 error 分支，值屏障由被调用 setter 完成。

### `Object.ensureArrayElementCapacity` (`src/core/object.zig:10043`)

- **签名**：`fn ensureArrayElementCapacity(self: *Object, rt: *JSRuntime, needed_len: usize) !void`。
- **作用**：转发 dense backing 容量请求。
- **实现**：try ensureArrayBufferCapacity(rt,needed_len)。
- **所有权 / 错误 / 调用**：不设置元素、count/length 或 fast flag；沿用底层分配与错误合同。

### `Object.leaveFastArrayMode` (`src/core/object.zig:10049`)

- **签名**：`fn leaveFastArrayMode(self: *Object) void`。
- **作用**：把 Array 标为 sparse 模式。
- **实现**：非 Array 返回；直接 fast_array=false。旧名 updateArrayStorageMode 带一个完全被忽略的 `index` 参数，已连同参数一起改名删除。
- **所有权 / 错误 / 调用**：不释放/迁移 backing 或重新计算密度，调用方须先保持布局与追踪合同。

### `Object.recomputeArrayStorageMode` (`src/core/object.zig:10054`)

- **签名**：`fn recomputeArrayStorageMode(self: *Object, rt: *JSRuntime) void`。
- **作用**：按 arm 容量和 live shape 索引重新设置 Array fast 标志。
- **实现**：非 Array 返回；先置 fast_array=(capacity>=count)，再扫描未 deleted 的 shape 属性，任一可解析为 array index 则 leaveFastArrayMode 清 fast。
- **所有权 / 错误 / 调用**：不迁移元素或分配存储，不验证 hole/length；零 capacity/count 也满足初始 fast 条件。

### `Object.barrierPropertySlot` (`src/core/object.zig:10071`)

- **签名**：`inline fn barrierPropertySlot(self: *Object, rt: *JSRuntime, flags: property.Flags, slot: property.Slot) void`。
- **作用**：对已发布属性槽中的直接引用执行 owner 屏障。
- **实现**：deleted 直接返回；data 屏障 cycleMarkHeader，accessor 对非空 getter/setter header 分别屏障，VarRef 屏障 cell.header，auto_init 无操作。
- **所有权 / 错误 / 调用**：不屏障 Shape，也不在此处理 auto-init realm 边；不能依据 helper 名称推断所有 slot kind 都会产生屏障。

### `Object.addProperty` (`src/core/object.zig:10084`)

- **签名**：`inline fn addProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：把 descriptor 转为 flags/slot 后追加属性。
- **实现**：slotFromDescriptor(desc)，再 appendPreparedPropertyEntry(rt,atom,flagsFromDescriptor(desc),slot)。
- **所有权 / 错误 / 调用**：不查重复或执行完整 descriptor 兼容性校验，调用者选择正确入口；追加可能分配失败。

### `Object.definePlainDataPropertyKnownFast` (`src/core/object.zig:10127`)

- **签名**：`pub noinline fn definePlainDataPropertyKnownFast(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue) !void`。
- **作用**：为已证明普通对象的 literal 属性写入提供受配置控制的根保护。
- **实现**：value_root_frames_enabled 时分别 rootObjects(self) 与 rootValues(data_value)，覆盖 Mut 调用；否则直接委托。
- **所有权 / 错误 / 调用**：对象 class/extensible/无 exotic 等由调用方证明，本包装不重验。atom 须独立由执行字节码保活；此处保护数据值不等于无条件启用根帧。

### `Object.definePlainDataPropertyKnownFastMut` (`src/core/object.zig:10152`)

- **签名**：`inline fn definePlainDataPropertyKnownFastMut(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue) !void`。
- **作用**：按 trusted own lookup 更新或追加 literal data 属性。
- **实现**：命中构造 w/e/c 全 true descriptor，先物化 auto-init、检查兼容性、replaceProperty；未命中 appendPreparedPropertyEntryImpl(true,false)，直接传 data 槽。
- **所有权 / 错误 / 调用**：命中失败可能已经物化旧 placeholder；不能把所有失败描述为对象完全不变。新值发布按 replace/append 各自提交协议，未命中依赖外部 atom 根。

### `Object.appendPreparedPropertyEntry` (`src/core/object.zig:10182`)

- **签名**：`pub fn appendPreparedPropertyEntry(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void`。
- **作用**：以默认根和索引处理协议追加预构造属性槽。
- **实现**：调用 Impl(false,false)。
- **所有权 / 错误 / 调用**：不承诺已有独立 atom 根，所以内部建立 atom root；不跳过索引分类。调用方仍负责新属性及 flags/slot 匹配前提。

### `Object.appendPreparedPropertyEntryImpl` (`src/core/object.zig:10199`)

- **签名**：`inline fn appendPreparedPropertyEntryImpl(self: *Object, comptime caller_holds_atom_ref: bool, comptime named_put_no_index: bool, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void`。
- **作用**：选择 atom 保活方式并转发到属性追加流程。
- **实现**：caller_holds_atom_ref=false 时建立 rootAtoms 帧覆盖 Rooted 调用，否则直接调用；named_put_no_index 原样转发。
- **所有权 / 错误 / 调用**：true 仅在调用方已保证整个分配窗口 atom 可达时使用；不为 slot 的所有引用类型建立根，不执行 RC dup/free。

### `Object.appendPreparedPropertyEntryRooted` (`src/core/object.zig:10218`)

- **签名**：`inline fn appendPreparedPropertyEntryRooted(comptime named_put_no_index: bool, self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void`。
- **作用**：按配置保护 holder 和 data 值，进入追加工作函数。
- **实现**：value_root_frames_enabled 时建立 holder root 与 in_flight value root；data 使用 slot.data，其他 kind 的 in_flight 为 undefined，live_slot 对 data 重建后传 Work。关闭配置时直接传原 slot。
- **所有权 / 错误 / 调用**：accessor/VarRef/auto-init 的引用没有通过此 data-value frame 全部保护，须由调用方及其他根合同保证；不将 Rooted 名称理解为所有构建引用无条件被 rooted。

### `Object.appendPreparedPropertyEntryWork` (`src/core/object.zig:10248`)

- **签名**：`inline fn appendPreparedPropertyEntryWork(comptime named_put_no_index: bool, self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void`。
- **作用**：暂存新属性值，再提交 Shape 和 tracing summary。
- **实现**：非 named 路径先对 tagged index 失效化标准原型 guard，并独立判断完整 ArrayIndex。保存旧 count/storage/capacity，必要时分配 property_storage cell、复制 live 项、安装并 remember owner。写入 old_len 的暂存槽并屏障，设置 indexed 摘要；索引或缓存未命中走 adoptShapeForNewProperty，否则使用 cached transition 并屏障 Shape。提交成功后 commitTraceShapeAppend，关闭回滚。
- **所有权 / 错误 / 调用**：Shape 提交前新增槽不在已发布 count/summary 内。失败清空暂存槽、恢复 indexed 摘要；若增长则恢复旧 storage，slots2 spill 还先复制原 live 项回 inline tail，新 cell 留给 GC。标准原型 guard 的提前失效和屏障状态不回滚。成功的 Shape 提交后没有可失败步骤，必须同步发布 summary。

### `Object.shapeNeedsMutationCopy` (`src/core/object.zig:10370`)

- **签名**：`fn shapeNeedsMutationCopy(self: *const Object) bool`。
- **作用**：查询 Shape 是否需要写时复制。
- **实现**：直接 shape_ref.isShared()。
- **所有权 / 错误 / 调用**：不基于属性数、GC 颜色或引用计数估计是否独占。

### `Object.ensureUniqueShapeForMutation` (`src/core/object.zig:10374`)

- **签名**：`fn ensureUniqueShapeForMutation(self: *Object, rt: *JSRuntime) !void`。
- **作用**：在共享 Shape 上执行写时复制。
- **实现**：不 shared 返回；否则 cloneForMutation 成功后替换 shape_ref，并执行 Object 到新 Shape 的屏障。
- **所有权 / 错误 / 调用**：克隆失败前不换指针；此函数不增加/删除属性，也不重建属性存储。

### `Object.adoptShapeForNewProperty` (`src/core/object.zig:10383`)

- **签名**：`fn adoptShapeForNewProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: u6, property_capacity: usize, is_array_index: bool) !void`。
- **作用**：采用新增属性后的 Shape 并记录 owner 屏障。
- **实现**：索引属性先 ensureUniqueShapeForMutation，再 shapes.addProperty，adoptionBarrier 后返回；named 属性走 transitionPropertyUncached，随后 adoptionBarrier。
- **所有权 / 错误 / 调用**：调用方已做缓存命中探测和 atom 保活；本函数不再建 atom 根，不提交 property trace summary。索引路径可能先克隆后在追加阶段失败。

### `Object.ensurePropertyCapacity` (`src/core/object.zig:10413`)

- **签名**：`fn ensurePropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void`。
- **作用**：扩大外置属性 cell 并预留 Shape 的属性容量。
- **实现**：needed<=当前声明容量则返回；新容量取 propertyCapacityForNeeded 与当前 shape.prop_size 的较大者。创建 cell、复制 live entries、立即安装并 remember owner，再 reserveProperties，成功后屏障 Shape。
- **所有权 / 错误 / 调用**：reserveProperties 失败不恢复旧 cell，对象可保留比 Shape 声明更宽的 backing；旧 cell 由 GC 回收。先安装避免新 cell 在后续分配窗口无 owner，不初始化容量余量。

### `Object.propertyStorageCapacity` (`src/core/object.zig:10448`)

- **签名**：`fn propertyStorageCapacity(self: *const Object) usize`。
- **作用**：读取对象当前可用的声明属性容量。
- **实现**：hasPropertyStorage 时返回 shape_ref.prop_size，否则 0。
- **所有权 / 错误 / 调用**：不是查询 GC cell 实际分配大小；失败扩容后物理 backing 可能更宽。

### `Object.emptyPropertyStorageBase` (`src/core/object.zig:10452`)

- **签名**：`inline fn emptyPropertyStorageBase() [*]property.Entry`。
- **作用**：返回空属性存储 sentinel。
- **实现**：将 @alignOf(property.Entry) 转为 Entry 多项指针。
- **所有权 / 错误 / 调用**：不是分配或可解引用的有效 Entry，零长 slice/空状态只能按其合同使用。

### `Object.trailingPropertyStorageBase` (`src/core/object.zig:10466`)

- **签名**：`pub inline fn trailingPropertyStorageBase(self: *const Object) [*]property.Entry`。
- **作用**：计算 slots2 内联属性尾区地址。
- **实现**：断言 hasSlots2Layout，然后返回 self 地址加 slots2_property_storage_offset（@sizeOf(Object)）。
- **所有权 / 错误 / 调用**：当前实现会读取布局 flag，不是源码旧注释所称完全不读字段的纯地址计算；返回原始尾区，不保证仍为当前存储。

### `Object.createPropertyStorageCell` (`src/core/object.zig:10483`)

- **签名**：`pub fn createPropertyStorageCell(rt: *JSRuntime, capacity: usize) ![*]property.Entry`。
- **作用**：分配发布未初始化的外置 property_storage GC cell。
- **实现**：断言 capacity 非零；checked 乘加计算 Entry 字节与 metadata 总量，溢出 OutOfMemory。先 requestGCForAllocation(payload_bytes)，再 createStorageCellPublished(property_storage_kind_tag,total)，返回 body 指针。
- **所有权 / 错误 / 调用**：压力调用在新 cell 创建前，不能依据旧注释称其绝不收集。新 cell 发布后到 owner 安装须保持无额外收集窗口；调用方初始化 live 前缀，不用 memory.free 直接释放。

### `Object.propertyStorageCellHeader` (`src/core/object.zig:10508`)

- **签名**：`pub inline fn propertyStorageCellHeader(ptr: [*]property.Entry) *gc.GCObjectHeader`。
- **作用**：把外置 Entry backing 指针解释为 GC header。
- **实现**：直接 alignCast/ptrCast。
- **所有权 / 错误 / 调用**：不检查注册或 kind；只适用于真实 external cell，sentinel 与 inline tail 均不适用。

### `Object.propertyStoragePointerIsExternal` (`src/core/object.zig:10512`)

- **签名**：`pub inline fn propertyStoragePointerIsExternal(self: *const Object, ptr: [*]property.Entry) bool`。
- **作用**：按 sentinel 与 inline tail 判断指针表示。
- **实现**：ptr 非 empty sentinel，且非 slots2 或不等于该对象 tail，则 true。
- **所有权 / 错误 / 调用**：不查 GC 注册表、地址合法性或实际分配大小；依赖对象存储指针合同。

### `Object.setPropertyStorageExternal` (`src/core/object.zig:10519`)

- **签名**：`pub inline fn setPropertyStorageExternal(self: *Object, ptr: [*]property.Entry) void`。
- **作用**：安装属性存储指针。
- **实现**：断言对齐且非 empty sentinel，再 prop_values=ptr。
- **所有权 / 错误 / 调用**：没有额外 external 位，不执行屏障、复制或释放旧存储，也不验证 ptr 确属 GC cell。

### `Object.setPropertyStorageInline` (`src/core/object.zig:10525`)

- **签名**：`pub inline fn setPropertyStorageInline(self: *Object) void`。
- **作用**：把 prop_values 指回 slots2 尾区。
- **实现**：断言 slots2，赋 trailingPropertyStorageBase。
- **所有权 / 错误 / 调用**：不复制 live entries 或修复 payload 重叠，调用方必须先准备尾区。

### `Object.setPropertyStorageEmptyForDestroy` (`src/core/object.zig:10530`)

- **签名**：`inline fn setPropertyStorageEmptyForDestroy(self: *Object) void`。
- **作用**：为析构设置无 live 属性的存储指针表示。
- **实现**：slots2 指回 tail，其他布局设 empty sentinel。
- **所有权 / 错误 / 调用**：不清 shape count、复制尾区或释放原 cell；仅作为外层销毁流程的一步。

### `Object.restorePropertyStorage` (`src/core/object.zig:10537`)

- **签名**：`inline fn restorePropertyStorage(self: *Object, ptr: [*]property.Entry) void`。
- **作用**：恢复保存的 prop_values 指针。
- **实现**：直接赋值 ptr。
- **所有权 / 错误 / 调用**：无校验、复制、屏障或容量同步；回滚调用方须先恢复 slots2 尾区内容。

### `Object.propertyStorageBase` (`src/core/object.zig:10543`)

- **签名**：`pub inline fn propertyStorageBase(self: *const Object) [*]property.Entry`。
- **作用**：借用当前非空表示的属性存储基址。
- **实现**：断言 hasPropertyStorage，返回 prop_values。
- **所有权 / 错误 / 调用**：不保证任意索引已初始化；self const 仍返回可变 Entry 指针。

### `Object.propertyEntry` (`src/core/object.zig:10548`)

- **签名**：`pub inline fn propertyEntry(self: *const Object, index: usize) *property.Entry`。
- **作用**：借用指定位置的属性 Entry。
- **实现**：返回 &propertyStorageBase()[index]。
- **所有权 / 错误 / 调用**：没有 index<count/capacity 检查；追加流程也用于尚未提交的 old_count 位置，调用方保证边界与初始化。

### `Object.propertyStorageEntries` (`src/core/object.zig:10552`)

- **签名**：`pub inline fn propertyStorageEntries(self: *const Object, capacity: usize) []property.Entry`。
- **作用**：按指定长度借用 resident backing。
- **实现**：返回 prop_values[0..capacity]。
- **所有权 / 错误 / 调用**：参数长度由调用方保证，不查询物理容量或已初始化范围，返回可变 slice。

### `Object.trailingPropertyStorageEntries` (`src/core/object.zig:10559`)

- **签名**：`pub inline fn trailingPropertyStorageEntries(self: *const Object) []property.Entry`。
- **作用**：借用 slots2 原始两项尾区。
- **实现**：断言 slots2，从 trailingPropertyStorageBase 取 trailing_property_capacity 项。
- **所有权 / 错误 / 调用**：不保证它仍是 live 当前 backing；外置存储/payload 挂接状态下内容可能另有用途，调用方须遵守回迁协议。

### `Object.propertyEntries` (`src/core/object.zig:10570`)

- **签名**：`pub inline fn propertyEntries(self: *const Object) []property.Entry`。
- **作用**：借用 Shape 已发布数量的属性 Entry 前缀。
- **实现**：返回 prop_values[0..shape_ref.prop_count]。
- **所有权 / 错误 / 调用**：含 tombstone，排除追加时位于 prop_count 的暂存项及容量余量；const self 仍提供可变元素，不自动执行屏障。

### `Object.replaceProperty` (`src/core/object.zig:10574`)

- **签名**：`fn replaceProperty(self: *Object, rt: *JSRuntime, index: usize, desc: descriptor.Descriptor) !void`。
- **作用**：合并 descriptor 并替换属性，必要时保持 VarRef 别名。
- **实现**：先 mergeDescriptor/flagsFromDescriptor。旧 VarRef 且 merged 为 data 时保留 cell，flags 仍为 var_ref；有 flags 变化先准备独占 Shape，再写 cell、同步 is_const 与 flags。其他情况构造 next_slot、按需准备 Shape；global 的 VarRef 转 accessor 时将旧 cell 置 uninitialized 并清 lexical/const，再安装槽、屏障、更新 flags、prune。
- **所有权 / 错误 / 调用**：不在此调用 isCompatible，调用方须先验证。VarRef-data 分支不替换 cell、不同步 is_deletable，也不执行最后的 prune；无 RC retain/release。Shape 准备失败前不提交这些字段更新。

### `Object.propAtomAt` (`src/core/object.zig:10619`)

- **签名**：`pub inline fn propAtomAt(self: *const Object, index: usize) atom.Atom`。
- **作用**：读取指定 Shape 属性的 atom。
- **实现**：返回 shape_ref.props()[index].atom_id。
- **所有权 / 错误 / 调用**：不是按 key 搜索；调用方保证索引合法，返回 atom 不独立建立根。

### `Object.propFlagsAt` (`src/core/object.zig:10624`)

- **签名**：`pub inline fn propFlagsAt(self: *const Object, index: usize) property.Flags`。
- **作用**：读取并解码指定 Shape 属性 flags。
- **实现**：Flags.fromBits(shape_ref.props()[index].flags)。
- **所有权 / 错误 / 调用**：不验证槽 union 内容匹配，调用方保证索引及布局。

### `Object.propKindAt` (`src/core/object.zig:10639`)

- **签名**：`pub inline fn propKindAt(self: *const Object, index: usize) property.Kind`。
- **作用**：读取 Shape 指定的属性槽类型。
- **实现**：返回 propFlagsAt(index).kind。
- **所有权 / 错误 / 调用**：槽本身是无标签 union，不能凭字段内容推断 kind；这里不排除 deleted。

### `Object.asDataAt` (`src/core/object.zig:10645`)

- **签名**：`pub inline fn asDataAt(self: *const Object, index: usize) ?JSValue`。
- **作用**：读取 live data 槽的值。
- **实现**：flags.deleted 或 kind 非 data 返回 null，否则 propertyEntry(index).slot.data。
- **所有权 / 错误 / 调用**：不物化 auto-init、不读 VarRef 或调用 getter；输入 index 必须有效，无 RC dup。

### `Object.replaceOwnDataPropertyValueAtAssumingShapeOwned` (`src/core/object.zig:10655`)

- **签名**：`pub inline fn replaceOwnDataPropertyValueAtAssumingShapeOwned(self: *Object, rt: *JSRuntime, index: usize, new_value: JSValue) void`。
- **作用**：直接替换已知 live data 槽值。
- **实现**：断言 index<prop_count、未 deleted、kind data，写 slot.data=new_value。
- **所有权 / 错误 / 调用**：rt 未使用，没有 GC 屏障、writable 检查或 Shape 独占检查；调用方负责受控模板初始化与存活合同。

### `Object.asAccessorAt` (`src/core/object.zig:10665`)

- **签名**：`pub inline fn asAccessorAt(self: *const Object, index: usize) ?property.Accessor`。
- **作用**：按值读取 live accessor 记录。
- **实现**：deleted 或 kind 非 accessor 返回 null，否则返回 slot.accessor。
- **所有权 / 错误 / 调用**：不调用 getter/setter，也不建立根；index 有效性由调用方保证。

### `Object.asVarRefAt` (`src/core/object.zig:10672`)

- **签名**：`pub inline fn asVarRefAt(self: *const Object, index: usize) ?*var_ref_mod.VarRef`。
- **作用**：借用 live var_ref 槽的 cell。
- **实现**：deleted 或 kind 非 var_ref 返回 null，否则返回 slot.var_ref。
- **所有权 / 错误 / 调用**：不读取 cell 值或执行 TDZ 检查，不 retain cell。

### `Object.isAutoInitAt` (`src/core/object.zig:10678`)

- **签名**：`pub inline fn isAutoInitAt(self: *const Object, index: usize) bool`。
- **作用**：查询指定属性 flags 的 auto-init 判定。
- **实现**：委托 propFlagsAt(index).isAutoInit()。
- **所有权 / 错误 / 调用**：不调用 builder 或检查 realm/descriptor 指针；index 由调用方保证。

### `Object.replaceOwnPropertyWithVarRefCell` (`src/core/object.zig:10688`)

- **签名**：`pub fn replaceOwnPropertyWithVarRefCell( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, index: usize, next_flags: property.Flags, cell: *var_ref_mod.VarRef, ) !void`。
- **作用**：把指定现有属性替换成声明使用的 VarRef cell。
- **实现**：拒绝越界、atom 不匹配、旧 deleted/auto-init 或新 flags 非 live var_ref。ensureUniqueShapeForMutation 后，旧 data 值写入 supplied cell；设 cell 非 lexical、const=!writable、deletable=configurable，再安装 cell、屏障、更新 flags、prune。
- **所有权 / 错误 / 调用**：旧槽非 data 时不复制其值到 cell；不进行一般 descriptor 兼容性检查。当前不执行源码旧注释中的引用计数变化，成功通过 GC 边共享 cell。

### `Object.setEntryKindAndSlot` (`src/core/object.zig:10732`)

- **签名**：`fn setEntryKindAndSlot( self: *Object, rt: *JSRuntime, index: usize, next_flags: property.Flags, next_slot: property.Slot, ) void`。
- **作用**：成对更新属性槽、GC 屏障和 Shape flags。
- **实现**：先写 next_slot，再 barrierPropertySlot，最后 updateShapePropertyFlags。
- **所有权 / 错误 / 调用**：不分配、不验证 index/flags-slot 匹配或主动克隆 Shape；调用者必须事先确保可安全修改 Shape。

### `Object.shapeProps` (`src/core/object.zig:10761`)

- **签名**：`pub inline fn shapeProps(self: *const Object) []const shape.Property`。
- **作用**：借用 Shape 已发布属性元数据前缀。
- **实现**：返回 shape_ref.props()[0..shape_ref.prop_count]。
- **所有权 / 错误 / 调用**：包含 deleted 条目，排除未提交的追加位置；不按 property backing 物理容量重新计算范围。

### `Object.findPropertyProbeTrusted` (`src/core/object.zig:10765`)

- **签名**：`fn findPropertyProbeTrusted(self: *const Object, atom_id: atom.Atom) ?PropertyProbe`。
- **作用**：沿 Shape hash 链返回匹配索引与属性元数据副本。
- **实现**：断言有 hash，逐项读取 hash_next，atom 匹配返回 PropertyProbe{index,prop}，链结束 null。
- **所有权 / 错误 / 调用**：只有循环内 `index < prop_count` 的索引范围断言，没有运行时步数上限或环检测；调用方保证 hash 链有效且无环。返回不单独过滤 deleted，依赖删除时维护 hash。（函数开头那条自比自的恒真断言 `prop_count <= self.shape_ref.prop_count` 已删除。）

### `Object.findOwnPropertySlotTrusted` (`src/core/object.zig:10780`)

- **签名**：`pub inline fn findOwnPropertySlotTrusted(self: *const Object, atom_id: atom.Atom) ?OwnPropertySlotLookup`。
- **作用**：一次 trusted probe 取得 flags 与对应 Entry 地址。
- **实现**：findPropertyProbeTrusted 命中则解码 prop.flags，并返回 propertyEntry(index)，否则 null。
- **所有权 / 错误 / 调用**：OwnPropertySlotLookup 持有 flags 副本和只读 Entry 借用；不保证未来 shape/storage 变动后仍一致，不调用 getter。

### `Object.findOwnDataValueFast` (`src/core/object.zig:10794`)

- **签名**：`pub inline fn findOwnDataValueFast(self: *const Object, atom_id: atom.Atom, slow: *bool) ?JSValue`。
- **作用**：快速查找 own data 值并标记非 data 命中。
- **实现**：沿 hash 链找 atom；命中 kind 非 data 则 slow=true 且 null，data 返回槽值；未命中 null。
- **所有权 / 错误 / 调用**：不把 slow 重置为 false，调用者须初始化。无链边界/循环检查或显式 deleted 判断，不解析 dense/合成属性。

### `Object.findOwnDataSlotFast` (`src/core/object.zig:10825`)

- **签名**：`pub inline fn findOwnDataSlotFast(self: *const Object, atom_id: atom.Atom, slow: *bool) ?*const JSValue`。
- **作用**：快速查找 own data 槽的只读地址。
- **实现**：使用 firstPropertyIndexAssumeHash 遍历，命中时直接检验 packed kind 位；非 data 置 slow=true 并 null，data 返回地址，miss null。
- **所有权 / 错误 / 调用**：不重置 slow，不读取 deleted 位，依赖 tombstone 从 hash 解绑；槽借用受 storage 替换影响。

### `Object.findWritableOwnDataSlotFast` (`src/core/object.zig:10867`)

- **签名**：`pub inline fn findWritableOwnDataSlotFast(self: *Object, atom_id: atom.Atom, slow: *bool) ?*JSValue`。
- **作用**：快速查找 own writable data 槽的可变地址。
- **实现**：trusted hash 链命中后检查 flags & 0b011001 == 1；不满足置 slow=true/null，否则返回 data 地址；miss null。
- **所有权 / 错误 / 调用**：调用方初始化 slow 并保证 hash/receiver 合同。返回指针不执行写屏障、setter 或 Array length 逻辑，裸写须自行处理。

### `Object.findPropertyIndexTrusted` (`src/core/object.zig:10893`)

- **签名**：`pub inline fn findPropertyIndexTrusted(self: *const Object, atom_id: atom.Atom) ?usize`。
- **作用**：从 trusted hash probe 返回索引。
- **实现**：委托 findPropertyProbeTrusted，命中取 index，否则 null。
- **所有权 / 错误 / 调用**：不保留元数据副本，不新增边界/环检查，调用方保证 Shape 结构。

### `Object.findProperty` (`src/core/object.zig:10898`)

- **签名**：`pub fn findProperty(self: *const Object, atom_id: atom.Atom) ?usize`。
- **作用**：以运行时步数/范围限制查找 Shape 属性索引。
- **实现**：断言有 hash；最多走 prop_count 步，遇到越界索引终止；检查 prop.atom_id，命中返回 index，否则 null。
- **所有权 / 错误 / 调用**：不报告坏链错误，也不显式测试 deleted；只限制本次遍历，不验证整个 Shape。不是 dense/原型/Proxy 查询。

### `flagsFromDescriptor` (`src/core/object.zig:11040`)

- **签名**：`fn flagsFromDescriptor(desc: descriptor.Descriptor) property.Flags`。
- **作用**：把 descriptor 类型与可选布尔字段转为存储 flags。
- **实现**：generic 产生 writable=false 的 data flags；data 的 writable/enumerable/configurable 缺省 false；accessor 使用 accessorFlags，enumerable/configurable 缺省 false。
- **所有权 / 错误 / 调用**：不合并旧 flags 或校验 descriptor 合法性；修改已有属性须先 merge。

### `slotFromDescriptor` (`src/core/object.zig:11048`)

- **签名**：`fn slotFromDescriptor(desc: descriptor.Descriptor) property.Slot`。
- **作用**：把 descriptor 转为属性槽。
- **实现**：generic 为 undefined data，data 直接取 desc.value，accessor 由 fromBorrowedValues(getter,setter) 构造。
- **所有权 / 错误 / 调用**：不根据 value_present 保留旧值，不分配或执行 setter；输入应已按新建/合并协议准备。

### `arrayLengthValue` (`src/core/object.zig:11265`)

- **签名**：`fn arrayLengthValue(length: u32) JSValue`。
- **作用**：把 u32 Array length 编码为 JS 数值。
- **实现**：不超过 i32 最大值用 int32，否则用 float64。
- **所有权 / 错误 / 调用**：不分配、不改变数组；所有 u32 长度均可由 f64 精确表示。

### `arrayLengthFromValue` (`src/core/object.zig:11272`)

- **签名**：`fn arrayLengthFromValue(rt: *JSRuntime, value: JSValue) !?u32`。
- **作用**：将受支持值转为可接受的 u32 Array length。
- **实现**：先 arrayLengthNumber；null、NaN、非有限、负数、超过 max_array_length 或非整数均返回 null，合法值转 u32。
- **所有权 / 错误 / 调用**：不直接抛 InvalidLength，由调用方解释 null；分配/字符串扁平化错误传播。不是完整可执行用户转换代码的 ToNumber。

### `arrayLengthNumber` (`src/core/object.zig:11281`)

- **签名**：`fn arrayLengthNumber(rt: *JSRuntime, value: JSValue) !?f64`。
- **作用**：执行内部有限类型集合的长度数值转换。
- **实现**：int/float 原数值、bool 0/1、null 0；undefined/symbol/bigint 返回 null；字符串调用字符串 helper。Object 仅支持 string wrapper 的 data、number/boolean wrapper 的递归 primitive，其余 null。
- **所有权 / 错误 / 调用**：不调用 valueOf、toString 或 Symbol.toPrimitive；不适用于独立替代完整 JS 类型转换。

### `arrayLengthStringNumber` (`src/core/object.zig:11303`)

- **签名**：`fn arrayLengthStringNumber(rt: *JSRuntime, value: JSValue) !f64`。
- **作用**：按内部 ASCII 路径解析长度字符串数值。
- **实现**：取 String body（恒为扁平）；分配临时字节表，任一 code unit>127 返回 NaN；只 trim 空格/tab/CR/LF，空为 0，处理 ±Infinity，0x/0X 用 u64 十六进制解析，其余 parseFloat；解析失败 NaN。
- **所有权 / 错误 / 调用**：不等于完整 ECMAScript StringNumericLiteral，Unicode 空白被拒绝，十六进制限制 u64。临时数组 defer 释放，分配/flatten 错误传播。

### `varRefCellFromValue` (`src/core/object.zig:11325`)

- **签名**：`fn varRefCellFromValue(value: JSValue) ?*var_ref_mod.VarRef`。
- **作用**：从值中识别 VarRef cell。
- **实现**：直接委托 VarRef.fromValue。
- **所有权 / 错误 / 调用**：不读取 cell 内容或建立根，不创建绑定。

### `appendAtom` (`src/core/object.zig:11329`)

- **签名**：`fn appendAtom(rt: *JSRuntime, keys: *[]atom.Atom, atom_id: atom.Atom) OwnKeysError!void`。
- **作用**：为 key 数组追加一个 atom id。
- **实现**：allocRuntime(len+1)，复制旧项并写新 atom，替换 keys slice 后释放非空旧数组。
- **所有权 / 错误 / 调用**：每次精确重新分配，没有 capacity 增长策略；OOM 前旧 slice 保持有效。只复制 atom id，不建立持久根，调用方保护跨分配窗口的 atom。

### `hasPropertyIndexKeys` (`src/core/object.zig:11344`)

- **签名**：`fn hasPropertyIndexKeys(self: *const Object, rt: *JSRuntime) bool`。
- **作用**：判断 shape 是否包含未由 dense extent 覆盖的 live 索引属性。
- **实现**：遍历 shapeProps，跳过 deleted；arrayIndexFromAtom 成功且 !hasDenseArrayElement(index) 则 true，末尾 false。
- **所有权 / 错误 / 调用**：不要求 enumerable，不检查 mapped binding 表或全部对象语义。

### `indexKeyLessThan` (`src/core/object.zig:11353`)

- **签名**：`fn indexKeyLessThan(_: void, lhs: IndexKey, rhs: IndexKey) bool`。
- **作用**：按数值索引比较 IndexKey。
- **实现**：返回 lhs.index<rhs.index，context 未用。
- **所有权 / 错误 / 调用**：不比较 atom id，相等索引排序等价；去重由上层 ownKeys 另行处理。

### `ownEntriesExpectObject` (`src/core/object.zig:11372`)

- **签名**：`fn ownEntriesExpectObject(value: JSValue) !*Object`。
- **作用**：为内部 entries 构建器取得 Object 输入。
- **实现**：要求 refHeader 非空且 value.isObject，否则 TypeError，再 Object.fromHeader。
- **所有权 / 错误 / 调用**：不执行 ToObject，不自动装箱 primitive。

### `entriesAtomToStringValue` (`src/core/object.zig:11378`)

- **签名**：`fn entriesAtomToStringValue(rt: *JSRuntime, atom_id: atom.Atom) !JSValue`。
- **作用**：将属性 atom 转换为字符串值。
- **实现**：委托 rt.atoms.toStringValue(rt,atom_id)。
- **所有权 / 错误 / 调用**：分配/转换错误传播，不在此筛选 symbol 或私有 key。

### `entryArrayValue` (`src/core/object.zig:11382`)

- **签名**：`fn entryArrayValue(rt: *JSRuntime, key: atom.Atom, value: JSValue, prototype: ?*Object) !JSValue`。
- **作用**：构造 [key字符串,value] 两项数组。
- **实现**：先激活列有 value、key 字符串槽与新数组槽的 rootValues 帧；createArray 后写入数组根槽并设置失败 destroy（errdefer 同时把根槽清回 undefined），atom 转字符串写入 key 根槽，再创建容量 2 的 array_storage cell，写两项并 adopt，标 indexed properties 后返回。
- **所有权 / 错误 / 调用**：原型直接取参数，不自行解析 realm。新数组与 key 字符串都要跨 createArrayStorageSlice 这次分配，因此三者都在显式根帧内（此前 key_value 与新数组都是裸局部，无根，注释却声称有）。prototype 与调用方传入 value 的存活仍遵循外围协议。

### `ownEntriesArray` (`src/core/object.zig:11410`)

- **签名**：`pub fn ownEntriesArray(rt: *JSRuntime, value: JSValue, mode: EntriesMode, prototype: ?*Object) !JSValue`。
- **作用**：为内部 bare-runtime 路径生成 keys/values/entries 数组。
- **实现**：rootValues 包住输入、输出和当前元素；要求 Object 输入，ownKeys 后 defer free；创建带给定 prototype 的结果数组，错误时销毁并清输出根。遍历 key，跳过公开 symbol、缺 descriptor 和不可枚举项；keys 转字符串，values 用 getProperty，entries 构造二元数组，再逐项 defineOwnProperty 为 w/e/c 全 true。
- **所有权 / 错误 / 调用**：不 ToObject 装箱；getProperty accessor 返回 getter 值而非执行 getter，完整 JS 可观察语义由上层适用路径决定。这里没有为 owned_keys 单独注册跨循环 atom-list 根；ownKeys 内部根在返回时已撤销。先收集 key，再逐项重读 descriptor，失败不返回部分结果。

### `stringIteratorPrimitiveValue` (`src/core/object.zig:11462`)

- **签名**：`fn stringIteratorPrimitiveValue(value: JSValue) !JSValue`。
- **作用**：取 string 或 String wrapper 的内部值。
- **实现**：string 输入直接返回；其他输入必须有 refHeader、为 Object 且 class_id 为 string，再取非空 objectData，否则 TypeError。
- **所有权 / 错误 / 调用**：不调用 ToString/ToPrimitive，也不重新检查 wrapper 内部值是否确为 string；返回借用值，不独立分配或建立根。

### `defineStringIteratorToStringTag` (`src/core/object.zig:11471`)

- **签名**：`fn defineStringIteratorToStringTag(rt: *JSRuntime, object: *Object, tag_name: []const u8) !void`。
- **作用**：定义迭代器对象的 @@toStringTag 数据属性。
- **实现**：查询预定义 symbol atom；缺失报 TypeError。以 createUtf8 分配 tag 字符串，defineOwnProperty 安装 writable=false、enumerable=false、configurable=true 的数据属性。
- **所有权 / 错误 / 调用**：字符串创建及属性定义失败传播；本体没有单独注册临时字符串或 object 的 rootValues 帧。

### `stringIteratorPrototype` (`src/core/object.zig:11477`)

- **签名**：`fn stringIteratorPrototype(ctx: *context_mod.RealmContext, tag_name: []const u8) !*Object`。
- **作用**：每次新建 Iterator 基础对象和 String Iterator 专用原型。
- **实现**：由 ctx.runtime 创建 null prototype 的 base，标记 Iterator；再创建继承 base 的 specific，标记 tag_name。nativeFunction(ctx,"next",0) 创建 next，验证为 Object 并设置 string.iterator_next native id/record；将 next 定义为可写、不可枚举、可配置属性。
- **所有权 / 错误 / 调用**：不查询或复用 realm 原型缓存；next 构造明确使用传入 ctx，不能称为与 realm 无关。specific 建成前失败直接 destroy base；建成后关闭 base_raw_owned，仅对 specific 设置错误销毁，不能宣称所有分配均逐一立即回滚。本体没有单独显式根帧。

### `stringIterator` (`src/core/object.zig:11496`)

- **签名**：`pub fn stringIterator(ctx: *context_mod.RealmContext, receiver: JSValue) !JSValue`。
- **作用**：为 string/String wrapper 接收者创建 String Iterator 实例。
- **实现**：为 receiver、target、prototype_value、object_value 声明并 activate 根帧；抽取 target，新建原型链，再创建 string_iterator，安装带屏障的 target 槽，index=0 后返回对象值。next 的执行体由 native record 分派至 exec。
- **所有权 / 错误 / 调用**：不查询接收者的 @@iterator，也不执行通用字符串转换；每次新建原型链。显式根中 prototype_value 在构造 helper 返回后才赋值，不能据此认定 helper 的全部中间对象均显式 rooted。实例创建后的失败路径清除 object_value，剩余回收按 GC 协议处理；defer 撤销根帧。

## 覆盖核对

- 清单函数数（本文件分到）: 94（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 96（含 2 条清单外的内嵌辅助函数标题）
- 未覆盖: 无
