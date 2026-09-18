# 07 — 原型、属性抽象操作与 exotic（`src/core/object.zig`）

原型、extensible、属性读取/写入/定义/删除、ownKeys、seal/freeze，以及 mapped arguments 与 TypedArray 索引的对象层辅助。这里不是完整 ECMAScript 内部方法的独立实现：例如 getProperty 不调用 getter，setProperty 不调用 setter，setPrototype 本身不检查 immutable_prototype；调用方与 exec 层共同提供完整语义。AUTOINIT 物化见 [07-object-autoinit.md](07-object-autoinit.md)；存储机械见 [07-object-property.md](07-object-property.md)。

慢路径集合：`classNeedsSlowPropertyAccess`（array/arguments/module_ns/proxy/typed arrays 等）。普通对象 define 走 `defineOrdinaryOwnProperty` / `definePlainDataPropertyKnownFast`。

---


### `Object.getPrototype` (`src/core/object.zig:7500`)

- **签名**：`pub fn getPrototype(self: *const Object) ?*Object`。
- **作用**：读取 Shape 保存的原型指针。
- **实现**：直接返回 shape_ref.proto。
- **所有权 / 错误 / 调用**：不调用 Proxy/exotic getPrototypeOf，不创建引用或进行可达性检查。

### `Object.setPrototype` (`src/core/object.zig:7504`)

- **签名**：`pub fn setPrototype(self: *Object, rt: *JSRuntime, prototype: ?*Object) Error!void`。
- **作用**：更新普通对象的 Shape 原型。
- **实现**：相同 prototype 立即成功；沿新 prototype 的 getPrototype 链检查 self，遇到返回 PrototypeCycle；之后检查 extensible。prepareUpdate 成功后屏障新的 shape_ref，调用 replacePrototypeAssumePrepared，再清 is_std_array_prototype。
- **所有权 / 错误 / 调用**：不检查 immutable_prototype 标志或 Proxy trap，调用方负责更高层语义；相同原型即使不可扩展也成功。prepareUpdate 可失败，不应描述为无分配操作。

### `Object.setFreshObjectPrototype` (`src/core/object.zig:7528`)

- **签名**：`pub fn setFreshObjectPrototype(self: *Object, rt: *JSRuntime, prototype: ?*Object) Error!void`。
- **作用**：为未暴露且无属性存储的对象换用最终原型的共享 root Shape。
- **实现**：断言 prop_count 零、无 property storage、extensible、prototype!=self；相同原型返回。createObjectRoot 成功后替换 shape、刷新 summary、屏障新 shape，再 dropUnshared 旧 shape 并清标准数组原型标志。
- **所有权 / 错误 / 调用**：不遍历原型链查环；调用方保证 fresh/unexposed 条件。创建失败前不换 shape，不改变已有 class payload。

### `Object.preventExtensions` (`src/core/object.zig:7544`)

- **签名**：`pub fn preventExtensions(self: *Object) void`。
- **作用**：清除 extensible 标志。
- **实现**：直接 flags.extensible=false。
- **所有权 / 错误 / 调用**：不 seal/freeze 属性、不改原型或调用 exotic hook。

### `Object.isExtensible` (`src/core/object.zig:7548`)

- **签名**：`pub fn isExtensible(self: *const Object) bool`。
- **作用**：读取 extensible 标志。
- **实现**：直接返回 flags.extensible。
- **所有权 / 错误 / 调用**：不是 Proxy-aware IsExtensible，不触发用户代码。

### `Object.markImmutablePrototype` (`src/core/object.zig:7552`)

- **签名**：`pub fn markImmutablePrototype(self: *Object) void`。
- **作用**：设置 immutable_prototype 标志。
- **实现**：直接写 true。
- **所有权 / 错误 / 调用**：不修改当前原型或 extensible；实际限制由相关上层操作读取标志实施。

### `Object.hasImmutablePrototype` (`src/core/object.zig:7556`)

- **签名**：`pub fn hasImmutablePrototype(self: *const Object) bool`。
- **作用**：查询 immutable_prototype 标志。
- **实现**：直接返回该布尔位。
- **所有权 / 错误 / 调用**：不推导原型对象本身是否 frozen。

### `Object.getOwnProperty` (`src/core/object.zig:7560`)

- **签名**：`pub fn getOwnProperty(self: *const Object, rt: *JSRuntime, atom_id: atom.Atom) PropertyReadError!?descriptor.Descriptor`。
- **作用**：按内部属性存储取得 own descriptor。
- **实现**：先尝试 exotic get-own hook，返回非空 descriptor 则采用，否则继续。Array length 合成描述符；mapped binding 优先使用 live 值并采用同名 data flags 或默认 w/e/c。普通 shape 属性 deleted 返回 null，auto-init 先 materialize 后建 descriptor；否则直接建；最后查 dense 元素并合成 w/e/c descriptor。
- **所有权 / 错误 / 调用**：不沿原型链或直接执行 accessor getter；const self 在 auto-init/hook 路径可能被修改。初始化/TDZ 错误传播；Proxy 与 typed-array 完整语言语义另有包装，不能把此函数等同于所有对象的规范内部方法。

### `Object.descriptorFromOwnPropertySlot` (`src/core/object.zig:7604`)

- **签名**：`fn descriptorFromOwnPropertySlot(self: *const Object, index: usize) !descriptor.Descriptor`。
- **作用**：从指定属性槽构造 descriptor，并处理 TDZ 和 namespace 可写标志。
- **实现**：读取 flags/slot；var_ref 值为 uninitialized 时 ReferenceError，否则 Descriptor.fromSlot；符合 isModuleNamespaceExportProperty 时将 desc.writable=true。
- **所有权 / 错误 / 调用**：不自行查索引边界或 materialize auto-init；调用方保证槽已适合转成 descriptor。namespace 描述符的 writable 不表示允许普通赋值成功。

### `Object.isModuleNamespaceExportProperty` (`src/core/object.zig:7619`)

- **签名**：`inline fn isModuleNamespaceExportProperty(self: *const Object, flags: property.Flags) bool`。
- **作用**：根据 class 与 flags 识别 namespace export 形式。
- **实现**：要求 module_ns、未删除、writable、enumerable、不可配置且非 accessor。
- **所有权 / 错误 / 调用**：仅测试这些 flags，不验证 atom/export 表或 VarRef 身份，也不是所有 module_ns 属性一概 true。

### `Object.ownPropertyEnumerableKind` (`src/core/object.zig:7642`)

- **签名**：`pub fn ownPropertyEnumerableKind(self: *const Object, rt: *const JSRuntime, atom_id: atom.Atom) OwnEnumerable`。
- **作用**：返回 cheap enumerable 结果或要求 descriptor 回退。
- **实现**：有 get-own hook 或 typed-array 对象则 descriptor；Array length 为 not_enumerable；shape 命中读 enumerable，之后 mapped binding/dense 元素为 enumerable，其余 not_enumerable。
- **所有权 / 错误 / 调用**：OwnEnumerable 三态中 descriptor 表示需完整探测，不是属性缺失。不 materialize auto-init 或读取 VarRef 值，shape 命中分支也不单独检查 deleted。

### `Object.hasOwnProperty` (`src/core/object.zig:7667`)

- **签名**：`pub fn hasOwnProperty(self: *const Object, atom_id: atom.Atom) bool`。
- **作用**：执行轻量 own 存储存在查询。
- **实现**：findProperty、denseArrayElement 或 mappedArgumentsTaggedBindingIndex 任一命中即 true。
- **所有权 / 错误 / 调用**：不合成 Array length、不处理 hook/Proxy 或 TDZ，也不支持需要 runtime 的全部字符串索引识别；完整存在语义需使用相应更高层接口。

### `Object.existsOwnProperty` (`src/core/object.zig:7685`)

- **签名**：`pub fn existsOwnProperty(self: *const Object, rt: *JSRuntime, atom_id: atom.Atom) !bool`。
- **作用**：执行内部 existence-only own 查询。
- **实现**：hook 返回描述符则 true；Array length 为 true；shape 命中后 deleted 为 false、uninitialized var_ref 抛 ReferenceError，其他为 true且不 materialize auto-init；再查 dense/mapped binding，否则 false。
- **所有权 / 错误 / 调用**：避免普通 descriptor 构造，但 hook 仍可能构造 descriptor。typed-array canonical index/Proxy 由 proxyAware 包装处理，不沿原型链。

### `Object.ownPropertyEnumerable` (`src/core/object.zig:7722`)

- **签名**：`pub fn ownPropertyEnumerable(self: *const Object, atom_id: atom.Atom) ?bool`。
- **作用**：读取普通 own 属性的 enumerable 位或缺失。
- **实现**：Array length 返回 false；shape 命中直接读 flags.enumerable；dense 或 tagged mapped binding 为 true；都无则 null。
- **所有权 / 错误 / 调用**：不调用 hook、materialize auto-init 或读 VarRef 值，适用非 proxy/exotic 的上层已确认路径；不做额外 deleted 检查。

### `Object.hasProperty` (`src/core/object.zig:7737`)

- **签名**：`pub fn hasProperty(self: *const Object, atom_id: atom.Atom) bool`。
- **作用**：沿普通原型链执行轻量属性存在查询。
- **实现**：记录 profile lookup；hasOwnProperty 命中返回 true，否则有 prototype 则递归 proto.hasProperty，末端 false。
- **所有权 / 错误 / 调用**：继承 hasOwnProperty 的范围限制，不是完整 Proxy-aware HasProperty，也不包含循环链检测或 TDZ 检查。

### `Object.getProperty` (`src/core/object.zig:7747`)

- **签名**：`pub fn getProperty(self: *const Object, atom_id: atom.Atom) PropertyReadError!JSValue`。
- **作用**：按普通存储与原型链读取属性表示。
- **实现**：记录 profile lookup；Array length 合成值，tagged mapped binding 优先读 live 值；shape 命中按 kind 返回 data、accessor.getterValue、materializeAutoInit 或 VarRef 值（uninitialized 抛 ReferenceError）。其后查 dense 元素、递归 prototype，最终 undefined。
- **所有权 / 错误 / 调用**：accessor 分支返回 getter 本身，不调用 getter；不是完整 JS Get/Proxy-aware 路径。auto-init 可能分配和修改 const self，错误传播，不转换为 undefined。

### `Object.getOwnDataPropertyValue` (`src/core/object.zig:8246`)

- **签名**：`pub fn getOwnDataPropertyValue(self: *const Object, atom_id: atom.Atom) ?JSValue`。
- **作用**：读取 shape 自有 data 属性的值。
- **实现**：getOwnDataPropertyLookup 命中返回 lookup.value，否则 null。
- **所有权 / 错误 / 调用**：不 materialize auto-init、调用 getter、读 VarRef 或查原型；不合成 dense 元素/Array length。

### `Object.getOwnDataObjectBorrowed` (`src/core/object.zig:8251`)

- **签名**：`pub fn getOwnDataObjectBorrowed(self: *const Object, atom_id: atom.Atom) ?*Object`。
- **作用**：借用 shape 自有 data 属性中的 Object。
- **实现**：有 exotic methods 返回 null；findProperty 命中后 asDataAt，非 live data 返回 null，再 objectFromValue 判定 Object。
- **所有权 / 错误 / 调用**：不物化占位符或建立根；返回借用指针，属性后续变化不延长其存活。

### `Object.getOwnConstructorPrototypeObject` (`src/core/object.zig:8268`)

- **签名**：`pub fn getOwnConstructorPrototypeObject(self: *Object, _: *JSRuntime) !?*Object`。
- **作用**：查询构造器自有 prototype Object，必要时物化延迟槽。
- **实现**：有 exotic methods、找不到属性或已 deleted 则 null；data 直接继续、auto_init 调用 materializeAutoInit，其他 kind 返回 null。最后再次 asDataAt 并 objectFromValue。
- **所有权 / 错误 / 调用**：忽略传入 rt，物化使用槽保存的 realm；不走原型链、不调用 getter。若物化得到 VarRef 而非 data，最终仍返回 null 交上层回退。

### `Object.getOwnDataPropertyLookup` (`src/core/object.zig:8284`)

- **签名**：`pub fn getOwnDataPropertyLookup(self: *const Object, atom_id: atom.Atom) ?DataPropertyLookup`。
- **作用**：查询 shape 自有 live data 属性的索引和值。
- **实现**：拒绝 exotic methods；findProperty 命中后 asDataAt，成功返回 DataPropertyLookup{index,value}，否则 null。
- **所有权 / 错误 / 调用**：不验证 shape 缓存未来仍有效，不处理 dense/合成属性或访问器，不建立根。

### `Object.getOwnDataPropertyValueAt` (`src/core/object.zig:8293`)

- **签名**：`pub fn getOwnDataPropertyValueAt(self: *const Object, index: usize, atom_id: atom.Atom) ?JSValue`。
- **作用**：用已知索引和 atom 复核后读取 data 值。
- **实现**：exotic 或 index>=shapeProps.len 返回 null；读取该 property，要求 atom 相同、未 deleted、kind data，再返回对应 entry.data。
- **所有权 / 错误 / 调用**：不搜索其他索引或 materialize，供缓存位置的防御性读取；失败用 optional null 表示，不等同于 JS null。

### `Object.getDenseArrayElementValue` (`src/core/object.zig:8301`)

- **签名**：`pub fn getDenseArrayElementValue(self: *const Object, index: u32) ?JSValue`。
- **作用**：尝试借用 dense extent 内的元素值。
- **实现**：直接委托 fastArrayElementDup(index)。
- **所有权 / 错误 / 调用**：沿用 fast_array/count 检查，不自行验证 Array class、查原型或执行 RC dup。

### `Object.defineOwnProperty` (`src/core/object.zig:8305`)

- **签名**：`pub fn defineOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：分派普通/特殊对象的 own 属性定义。
- **实现**：入口先对 descriptor 的 value/getter/setter 执行屏障。无需慢属性访问则 defineOrdinaryOwnProperty 返回；慢路径仅 shape 未命中才调用 exotic define hook。随后处理 module namespace、mapped descriptor、Array length；Array index 必要时 dense 转 sparse，再普通定义，成功后扩 length/更新模式；其余普通定义后更新 mapped binding。
- **所有权 / 错误 / 调用**：exotic hook false 报 IncompatibleDescriptor。Array length 不可写时越界索引先报 ReadOnly；dense 转换可在后续定义失败前已经完成，不承诺整个操作事务回滚。具体 descriptor 校验由分派的 helper 完成。

### `Object.defineOwnPropertyAssumingNew` (`src/core/object.zig:8377`)

- **签名**：`pub fn defineOwnPropertyAssumingNew(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：省略重复查询，向已确认可用的 named storage 添加新属性。
- **实现**：断言无 exotic、supportsPlainNamedPropertyStorage、非 mapped_arguments、extensible；先屏障 descriptor 三个值，再 addProperty。
- **所有权 / 错误 / 调用**：不检测属性已存在；断言是实际支持的 storage 条件，不宜简化成只允许 class==object。调用方负责保证 fresh 属性及绕过慢路径仍正确。

### `Object.defineOwnDataPropertyAssumingNewFromRootedAtom` (`src/core/object.zig:8403`)

- **签名**：`pub fn defineOwnDataPropertyAssumingNewFromRootedAtom( self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue, ) !void`。
- **作用**：用已独立保活的 atom 添加新的 w/e/c data 属性。
- **实现**：断言无 exotic、支持 plain named storage、非 mapped_arguments 且 extensible；调用 appendPreparedPropertyEntryImpl(true,false)，安装 data 值和全 true 的三个描述符位。
- **所有权 / 错误 / 调用**：第一个 true 省略内部 atom 根，第二个 false 不承诺非索引；调用方须保证独立 atom 根、新属性以及绕过完整 define 分派仍正确，不查重。

### `Object.defineOwnNonIndexPropertyAssumingNew` (`src/core/object.zig:8428`)

- **签名**：`pub fn defineOwnNonIndexPropertyAssumingNew(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：在已知新且非索引的 key 上添加属性。
- **实现**：断言无 exotic、不是 Array length、arrayIndexFromAtom 为 null、非 mapped_arguments、extensible，再 addProperty。
- **所有权 / 错误 / 调用**：支持新 Array 的命名元数据；不查重，不执行 Array 索引/length 语义。此包装未像 defineOwnProperty 入口那样显式屏障 descriptor 三值，安装协议由 add 路径负责。

### `Object.defineJsonParseDataProperty` (`src/core/object.zig:8437`)

- **签名**：`pub fn defineJsonParseDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void`。
- **作用**：为 JSON 构建对象创建或覆盖 data 属性。
- **实现**：断言普通 object、plain storage、无 exotic、extensible；命中旧属性则 ensureUniqueShapeForMutation，直接写 data 并屏障值，将 flags 重置为 w/e/c 全 true，再 prune 空 borrowed holder；未命中走 addProperty。
- **所有权 / 错误 / 调用**：专用于受控 JSON 对象，不执行一般不可配置属性兼容性检查。重复 key 覆盖而不追加位置；形状准备可能失败或改变 shape，输入存活由调用方保证。

### `Object.setProperty` (`src/core/object.zig:9190`)

- **签名**：`pub fn setProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void`。
- **作用**：执行内部普通存储赋值与部分原型检查。
- **实现**：module_ns 直接 ReadOnly；Array length 要求可写，fast 模式解析长度后截短元素并写 length，解析无结果报 InvalidLength，非 fast 委托 defineArrayLength。自有属性：accessor 仅检查 setter 是否存在后返回；不可写报错；VarRef 委托 cell setter；data 直接写并屏障/audit；auto-init 准备 Shape 后改 data。未命中先尝试 dense 写，再沿原型找到首个 shape 属性检查 setter/可写性，最后 defineOwnDataPropertyForSetKnownNoOwn。
- **所有权 / 错误 / 调用**：此函数不调用 accessor setter：自有 setter 存在时直接返回，继承 setter 存在时通过检查后仍到自有属性定义。因此不能描述为完整 JS [[Set]]，访问器执行由更高层负责。auto-init data 赋值丢弃默认 builder；错误传播，非全事务操作。

### `Object.setOwnWritableDataProperty` (`src/core/object.zig:9287`)

- **签名**：`pub fn setOwnWritableDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：尝试更新自有可写 data、VarRef 或 auto-init 槽。
- **实现**：拒绝 module_ns，trusted probe 未命中或 deleted/不可写则 false；accessor false，VarRef 写 cell 并 true，auto-init 准备 Shape 改 data 后 prune。data 的旧/新值均无需引用处理且 atom 非 Private_brand 时直接赋值；其他 data 写后屏障并 prune。
- **所有权 / 错误 / 调用**：函数名称中的 Data 也包含上述 VarRef/auto-init 分支；不调用 setter、查原型或创建缺失属性。立即数分支无屏障（`!isTracerOwned()`）。

### `Object.setOwnDataPropertyAtForLexicalSyncOwned` (`src/core/object.zig:9332`)

- **签名**：`pub inline fn setOwnDataPropertyAtForLexicalSyncOwned(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：按缓存位置同步自有 data 槽，允许初始化未初始化的只读槽。
- **实现**：拒绝 exotic、越界、atom 不匹配、deleted、非 data；不可写且旧值非 uninitialized 则 false，Private_brand 也 false；否则写 new_value 并屏障，true。
- **所有权 / 错误 / 调用**：不会查找其他索引、改 flags 或声明绑定；不可写槽的首次初始化是明确例外。当前没有实际 error 分支或 RC 操作。

### `Object.setOrDefineOwnDataPropertyForSimpleSet` (`src/core/object.zig:9346`)

- **签名**：`pub fn setOrDefineOwnDataPropertyForSimpleSet(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：尝试写自有可写槽，缺失时尝试简单 named 属性创建。
- **实现**：入口先屏障 new_value；module_ns 返回 false。own 命中拒绝 accessor、deleted、不可写；非 Private_brand 下 primitive data 直接赋值，VarRef 写 cell，auto-init 准备 Shape 并改 data 后 prune。其余落到直接 data 写入、屏障与 prune；own miss 委托 defineNewOwnDataPropertyForSimpleSetKnownNoOwn。
- **所有权 / 错误 / 调用**：入口屏障可能在返回 false 前更新 GC 状态。Private_brand 跳过特殊 VarRef/auto-init 分支，调用方须保证其适用槽形态；本函数不执行 getter/setter，也不承诺所有 receiver 的完整 Set 语义。

### `Object.defineOwnDataPropertyForSetKnownNoOwn` (`src/core/object.zig:9400`)

- **签名**：`fn defineOwnDataPropertyForSetKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void`。
- **作用**：在已确认没有自有属性时定义全 w/e/c data 属性。
- **实现**：构造 descriptor；exotic define hook 若存在则调用，false 报 IncompatibleDescriptor。随后 module namespace helper、Array length、Array index 分派；index 必要时检查 length writable、dense 转 sparse、普通 known-no-own 定义、扩 length/更新模式。其余普通定义后更新 mapped binding。
- **所有权 / 错误 / 调用**：不再查自有属性或检查原型 setter，由调用者先处理；转存储模式及后续定义不是整体回滚事务。

### `Object.defineNewOwnDataPropertyForSimpleSetKnownNoOwn` (`src/core/object.zig:9431`)

- **签名**：`fn defineNewOwnDataPropertyForSimpleSetKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool`。
- **作用**：在严格过滤的 named own miss 上创建普通 data 属性。
- **实现**：拒绝 exotic/proxyTarget/global/with-environment、不可扩展、module_ns/mapped_arguments/typed-array、Array length、tagged-int key，以及具有 indexed storage 的 class 的字符串索引。原型链拒绝 exotic/proxy/typed-array；首个同名属性必须 live writable data 才停止并允许创建。最终 addProperty(w/e/c 全 true)，返回 true。
- **所有权 / 错误 / 调用**：false 表示需要完整 resolver，不代表最终赋值失败；不调用 setter或物化原型 placeholder。不验证 own miss 前提；分配错误直接传播。

### `Object.setOrDefineOwnDataPropertyForPutFieldOwned` (`src/core/object.zig:9520`)

- **签名**：`pub fn setOrDefineOwnDataPropertyForPutFieldOwned(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) align(16) PutFieldFast`。
- **作用**：为已保活字节码 atom 提供单次 own probe 的 put_field 快速写入。
- **实现**：入口屏障后拒绝 needsSlowPropertyAccess/proxyTarget/with。trusted own 命中时 writable live data 直接替换，VarRef 写 cell，auto-init 准备 Shape 后改 data，accessor/只读返回 slow；Shape 错误也 slow。own miss 拒绝索引形式和 global，按 trusted 原型 hash 链先查属性：首个 live writable data 停止；未命中才做 exotic/Proxy 拒绝。原型走完后检查 extensible，用 appendPreparedPropertyEntryImpl(true,true) 追加 w/e/c data，错误转 slow，成功 done。
- **所有权 / 错误 / 调用**：PutFieldFast 为 done/slow 的非 error-union；slow 要交完整 resolver 处理，不等价于已报 OOM。入口屏障可更新 GC 状态，失败追加也可能留下准备的容量等内部状态，因此“完全没有状态变化”不宜泛化。调用方须保证 atom 在整个分配窗口独立保活和 trusted hash 合同；当前 Owned 不执行 RC 操作。

### `Object.defineModuleNamespaceProperty` (`src/core/object.zig:9652`)

- **签名**：`fn defineModuleNamespaceProperty(self: *Object, atom_id: atom.Atom, desc: descriptor.Descriptor) !bool`。
- **作用**：验证 namespace export 的兼容重定义，不写入新值。
- **实现**：非 namespace、无同名属性或不符合 export flags 返回 false。auto-init 先物化并重新检查 flags，再取当前 descriptor；拒绝 accessor/configurable=true/enumerable=false/writable=false，显式 value 非 SameValue 则 ReadOnly，其他 true。
- **所有权 / 错误 / 调用**：物化与 TDZ 错误优先于输入 descriptor 不兼容；返回 true 表示已处理且无需写入，false 交普通定义路径。物化副作用不回滚。

### `Object.deleteOrdinaryPropertyAt` (`src/core/object.zig:9681`)

- **签名**：`fn deleteOrdinaryPropertyAt(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, index: usize) bool`。
- **作用**：将可配置 shape 属性变为 tombstone 并处理绑定。
- **实现**：不可配置 false；prepareUpdate 错误也 false。屏障 Shape 后保存旧 slot，将 entry 置 undefined data、标 deleted 并同步 summary。mapped arguments 清绑定；global 的 live VarRef 旧 cell 置 uninitialized，并清 lexical/const。prune 后若 deleted>=8 且>=prop_count/2 尝试 compact，错误忽略，最终 true。
- **所有权 / 错误 / 调用**：false 无法区分不可配置与准备 OOM。已提交删除后的 compact 失败仍成功，保留 tombstone；不执行 RC 析构或保证立刻缩存储。

### `Object.deleteProperty` (`src/core/object.zig:9729`)

- **签名**：`pub fn deleteProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom) bool`。
- **作用**：按内部 exotic、shape、mapped 和 dense 路径删除自有属性。
- **实现**：有 delete hook 直接返回结果；Array length false；shape 命中委托普通删除，mapped binding 命中解除并 true。dense 索引存在则先转 sparse，转换失败 false，成功后查 shape 再删除；其余 true。
- **所有权 / 错误 / 调用**：不检查原型、不缩 Array length；dense 转换成功后删除失败可留下 sparse 表示。没有此处旧注释所称的 RC zero-ref cascade，完整 Proxy 语义由更高层处理。

### `Object.ownKeys` (`src/core/object.zig:9764`)

- **签名**：`pub fn ownKeys(self: *const Object, rt: *JSRuntime) OwnKeysError![]atom.Atom`。
- **作用**：生成内部 own key 列表：数值索引、字符串、公开 symbol。
- **实现**：有 own_keys hook 则直接委托。否则用 rootAtomList 保护增长中的结果；无 shape 索引/mapped 时先输出 dense 序号，否则汇集 mapped 非空绑定、dense、shape 索引并按数值排序去重。Array 再加入 length；随后 shape 顺序输出非索引非公开symbol非private项，最后公开symbol。
- **所有权 / 错误 / 调用**：跳过 deleted，但不按 enumerable 过滤或物化属性；private keys 不输出。错误时 freeKeys 已建结果，临时排序表 defer 释放；成功 slice 由调用方 freeKeys，返回后该局部 root 帧已解除。

### `Object.freeKeys` (`src/core/object.zig:9844`)

- **签名**：`pub fn freeKeys(rt: *JSRuntime, keys: []atom.Atom) void`。
- **作用**：释放 own key 列表的 runtime 数组分配。
- **实现**：keys 非空时 memory.free(atom.Atom,keys)，空列表无操作。
- **所有权 / 错误 / 调用**：不逐项执行 atom release，也不撤销调用方自己建立的 root frame。

### `Object.seal` (`src/core/object.zig:9848`)

- **签名**：`pub fn seal(self: *Object, rt: *JSRuntime) !void`。
- **作用**：把当前对象变为不可扩展并清除自有属性 configurable。
- **实现**：fast 且 count 非零先 dense 转 sparse，再物化全部 mapped arguments 属性；置 extensible=false，ensureUniqueShapeForMutation 后逐项跳过 deleted/已不可配置项，其余改 configurable=false。
- **所有权 / 错误 / 调用**：不改 data writable 或 Array length_writable，不物化所有 auto-init。后续 Shape 准备失败时 extensible 已为 false，前面的存储转换也不回滚；不是完整 exotic integrity-level dispatcher。

### `Object.freeze` (`src/core/object.zig:9867`)

- **签名**：`pub fn freeze(self: *Object, rt: *JSRuntime) !void`。
- **作用**：在 seal 基础上禁止数据属性写入并断开 mapped 绑定。
- **实现**：先 seal；namespace 若存在符合 export flags 的属性报 IncompatibleDescriptor。其余 detachAllMappedArgumentsBindings，清 live 非 accessor 属性 writable，Array 另清 length_writable。
- **所有权 / 错误 / 调用**：namespace 拒绝发生在 seal 后，不能承诺失败完全无变化；不调用 accessor setter、深冻结子对象或物化所有 placeholder。

### `Object.defineOrdinaryOwnProperty` (`src/core/object.zig:9888`)

- **签名**：`fn defineOrdinaryOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：更新现有普通属性，或把特殊存储物化后定义。
- **实现**：shape 命中先 materialize auto-init，再 isCompatible 检查、replaceProperty。未命中时 mapped arguments 先物化并重查；拥有 indexed storage 的 class 若命中 dense 元素则转 sparse、重新定位并兼容检查/替换。最后确无属性时检查 extensible，否则 NotExtensible，然后 addProperty。
- **所有权 / 错误 / 调用**：物化/转换发生在兼容性拒绝之前，错误不回滚这些前置变化；已有属性不要求 extensible，缺失属性才需。

### `Object.defineOrdinaryOwnPropertyKnownNoOwn` (`src/core/object.zig:9923`)

- **签名**：`fn defineOrdinaryOwnPropertyKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：在调用方已确认 own miss 时添加普通属性。
- **实现**：atom 可解析为 index 且落在 arrayElements 有效范围时先转 sparse；随后检查 extensible，不可扩展 NotExtensible，否则 addProperty。
- **所有权 / 错误 / 调用**：不重新查重、检查 descriptor 兼容性或处理 mapped binding；转换成功后出现错误不回滚存储模式。

### `Object.defineArrayLength` (`src/core/object.zig:9935`)

- **签名**：`fn defineArrayLength(self: *Object, rt: *JSRuntime, desc: descriptor.Descriptor) !void`。
- **作用**：按 length descriptor 更新 Array 长度和可写标志。
- **实现**：拒绝 accessor；有 value 时先解析长度，无结果 InvalidLength，再拒绝 configurable/enumerable true。无 value 只允许合法 writable 变化。有值时检查不可写旧 length 的兼容性；缩短时逆序扫描 shape 属性，删除所有索引>=目标。删除失败则设置 length=index+1、截短 dense、重算模式，可按 desc 清 writable，返回 IncompatibleDescriptor。成功则截短 count、写 length，再应用可选 writable。
- **所有权 / 错误 / 调用**：扫描顺序是 shape 条目逆序，不是这里显式数值排序；先前删除不会回滚。增长只产生尾洞，不填元素；正常成功路径不重新 dense 化，失败回退路径仍调用 recomputeArrayStorageMode。

### `Object.updateMappedArgumentsBinding` (`src/core/object.zig:10914`)

- **签名**：`fn updateMappedArgumentsBinding(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void`。
- **作用**：在属性定义后同步或解除 mapped argument 别名。
- **实现**：非 mapped class、非索引、越界或空 cell 返回；accessor 直接解除绑定。data 且显式 value 时先写 cell，再在 writable 显式 false 时解除绑定。
- **所有权 / 错误 / 调用**：不是重新创建映射；写值先于解除，现有形参 cell 保留更新后的值。generic descriptor 不走这些 data 专用分支。

### `Object.prepareMappedArgumentsDescriptorForDefine` (`src/core/object.zig:10935`)

- **签名**：`fn prepareMappedArgumentsDescriptorForDefine(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: *descriptor.Descriptor) !void`。
- **作用**：为只设 writable=false 的 mapped data descriptor 补上当前值。
- **实现**：只接受 mapped class、data、未提供 value、显式 writable=false；解析索引并读 live binding，存在则写 desc.value 和 value_present=true。
- **所有权 / 错误 / 调用**：不解除映射或写 cell；让后续断开绑定时普通属性保留当前形参值，当前实现无实际 error 分支。

### `Object.setMappedArgumentsBindingValue` (`src/core/object.zig:10945`)

- **签名**：`fn setMappedArgumentsBindingValue(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !void`。
- **作用**：写入已知有效索引的 mapped cell。
- **实现**：取 argumentsVarRefsMut()[index]，空 cell 返回，非空调用 cell.setVarRefValue。
- **所有权 / 错误 / 调用**：不检查 index 是否越界，调用方保证；不替换 cell 指针或普通 shape 属性，当前本层无实际 error 分支。

### `Object.deleteMappedArgumentsBinding` (`src/core/object.zig:10952`)

- **签名**：`fn deleteMappedArgumentsBinding(self: *Object, index: u32) void`。
- **作用**：解除一个已知有效下标的映射。
- **实现**：取可变 refs，原项 null 则返回，否则置 null。
- **所有权 / 错误 / 调用**：不检查边界、不删除普通属性、不清 cell 的值或显式释放 cell。

### `Object.mappedArgumentsBindingValue` (`src/core/object.zig:10959`)

- **签名**：`fn mappedArgumentsBindingValue(self: *const Object, index: u32) ?JSValue`。
- **作用**：读取 mapped cell 的当前值。
- **实现**：refs 越界或项 null 返回 null，否则 cell.varRefValue()。
- **所有权 / 错误 / 调用**：不物化 shape 属性、验证 TDZ 或建立根；uninitialized 可以作为返回值。

### `Object.mappedArgumentsBindingIndexFromAtom` (`src/core/object.zig:10967`)

- **签名**：`fn mappedArgumentsBindingIndexFromAtom(self: *const Object, rt: *const JSRuntime, atom_id: atom.Atom) ?u32`。
- **作用**：从一般数组索引 atom 查询 live mapping 下标。
- **实现**：非 mapped class 返回 null；arrayIndexFromAtom 失败也 null；hasMappedArgumentsBinding 成功返回 index。
- **所有权 / 错误 / 调用**：支持 runtime atom 表解析的字符串索引，不创建映射。

### `Object.mappedArgumentsTaggedBindingIndex` (`src/core/object.zig:10973`)

- **签名**：`fn mappedArgumentsTaggedBindingIndex(self: *const Object, atom_id: atom.Atom) ?u32`。
- **作用**：从 tagged-int atom 查询 live mapping。
- **实现**：要求 mapped class 且 tagged int，转 index 后检查 hasMappedArgumentsBinding。
- **所有权 / 错误 / 调用**：不解析普通字符串 atom，未命中不代表一般 property 缺失。

### `Object.hasMappedArgumentsBinding` (`src/core/object.zig:10979`)

- **签名**：`fn hasMappedArgumentsBinding(self: *const Object, index: u32) bool`。
- **作用**：判断映射表下标是否存在非空 cell。
- **实现**：index<refs.len 且 refs[index]!=null。
- **所有权 / 错误 / 调用**：不读取 cell 值或检查未初始化状态；非 mapped 对象的空 refs 自然返回 false。

### `Object.detachAllMappedArgumentsBindings` (`src/core/object.zig:11000`)

- **签名**：`fn detachAllMappedArgumentsBindings(self: *Object) void`。
- **作用**：清空 mapped arguments 的所有非空映射项。
- **实现**：非 mapped class 返回；遍历 refs，对非空项调用 deleteMappedArgumentsBinding。
- **所有权 / 错误 / 调用**：不先物化值、不清普通属性或 cell 内容；需要值快照的调用方必须先完成物化。

### `isTypedArrayObjectForSetFastPath` (`src/core/object.zig:11056`)

- **签名**：`fn isTypedArrayObjectForSetFastPath(object: *const Object) bool`。
- **作用**：转发 typed-array 存储判定。
- **实现**：返回 isTypedArrayObject(object)。
- **所有权 / 错误 / 调用**：不另检查 detached/越界/immutable。

### `isTypedArrayObject` (`src/core/object.zig:11073`)

- **签名**：`pub fn isTypedArrayObject(object: *const Object) bool`。
- **作用**：按 payload 字段识别 typed-array 实例存储。
- **实现**：无 typedArrayPayloadFast 为 false，否则 buffer 非空且 element_size 非零。
- **所有权 / 错误 / 调用**：不直接匹配 class，也不要求 backing_payload 存在或目标未 detached。

### `typedArrayOutOfBounds` (`src/core/object.zig:11078`)

- **签名**：`pub fn typedArrayOutOfBounds(object: *Object) !bool`。
- **作用**：用当前 backing 可见字节范围判断 view 越界。
- **实现**：缺 payload/backing 报 TypeError；offset>bytes.len 为 true；固定长度 checked 乘 element_size，溢出 true，否则比较是否超出剩余字节；动态长度在 offset 合法时 false。
- **所有权 / 错误 / 调用**：不自行判断 detached，也不要求 buffer 非空/element_size 非零；与其他 helper 的验证范围不同。

### `typedArrayDetached` (`src/core/object.zig:11089`)

- **签名**：`pub fn typedArrayDetached(object: *Object) !bool`。
- **作用**：读取 view backing 的 detached 状态。
- **实现**：缺 payload/backing 报 TypeError，否则 backing.detached。
- **所有权 / 错误 / 调用**：不计算越界或检查 element_size。

### `typedArrayLength` (`src/core/object.zig:11095`)

- **签名**：`pub fn typedArrayLength(rt: *JSRuntime, object: *Object) !u32`。
- **作用**：返回 view 缓存的 live_length。
- **实现**：要求 payload、element_size 非零、buffer 和 backing 非空，否则 TypeError；返回 live_length，rt 未使用。
- **所有权 / 错误 / 调用**：不重新按 bytes/offset 计算，依赖 backing 变化时维护 live state；不在此单独抛 detached 错误。

### `typedArrayByteLength` (`src/core/object.zig:11102`)

- **签名**：`pub fn typedArrayByteLength(rt: *JSRuntime, object: *Object) !usize`。
- **作用**：按缓存元素数计算 view 字节数。
- **实现**：try typedArrayLength 后乘 object.typedArrayElementSize。
- **所有权 / 错误 / 调用**：普通 usize 乘法，不另做 checked overflow 或 detached/越界查询；依赖 view 布局不变量。

### `typedArrayEffectiveByteOffset` (`src/core/object.zig:11107`)

- **签名**：`pub fn typedArrayEffectiveByteOffset(object: *Object) !usize`。
- **作用**：查询对外有效的 view offset。
- **实现**：typedArrayDetached 为 true 返回 0；否则 typedArrayOutOfBounds 为 true 返回 0；都否返回存储 byte_offset。
- **所有权 / 错误 / 调用**：缺 payload/backing 的错误传播，检查顺序先 detached 后越界。

### `typedArrayIndexValid` (`src/core/object.zig:11113`)

- **签名**：`pub fn typedArrayIndexValid(rt: *JSRuntime, object: *Object, index: u32) !bool`。
- **作用**：比较下标与缓存 live_length。
- **实现**：要求 payload、非零 element_size、非空 buffer/backing，否则 TypeError；返回 index<live_length，rt 未使用。
- **所有权 / 错误 / 调用**：不重新扫描 backing，也不校验 canonical numeric string；依赖缓存已随 detach/resize 更新。

### `typedArrayCanonicalNumericIndex` (`src/core/object.zig:11126`)

- **签名**：`pub fn typedArrayCanonicalNumericIndex(rt: *JSRuntime, atom_id: atom.Atom) !TypedArrayCanonicalIndex`。
- **作用**：将 atom 分类为非 canonical、canonical 但非法索引或 u32 索引。
- **实现**：先 arrayIndexFromAtom 命中直接 index；否则仅 string 且有非空名字继续，-0 为 invalid。`value_format.parseJsNumber(name)` 做 ToNumber，再按 JS 数字格式回印，文本不同为 none（CanonicalNumericIndexString）；canonical 但非有限/非整数/负数/超过 u32 为 invalid，其余 index。
- **所有权 / 错误 / 调用**：TypedArrayCanonicalIndex 的 invalid 与 none 不同：前者不能当普通命名属性。允许 u32 最大值作为数值候选，实际边界由 view 长度检查；当前函数无实际 error 返回分支。

### `typedArrayBackedByResizableBuffer` (`src/core/object.zig:11150`)

- **签名**：`pub fn typedArrayBackedByResizableBuffer(object: *Object) bool`。
- **作用**：判断 view backing 是否声明 max_byte_length。
- **实现**：先 isTypedArrayObject，缺 payload/backing false，否则 max_byte_length!=null。
- **所有权 / 错误 / 调用**：不判断是否还能增长、已 detached 或当前越界；包含具备该字段的 shared backing。

### `arrayBufferIsImmutable` (`src/core/object.zig:11157`)

- **签名**：`pub fn arrayBufferIsImmutable(rt: *JSRuntime, object: *Object) bool`。
- **作用**：读取 buffer immutable 标志。
- **实现**：忽略 rt，委托 arrayBufferImmutable。
- **所有权 / 错误 / 调用**：无 buffer payload 时底层返回 false，不做类型异常校验。

### `markArrayBufferImmutable` (`src/core/object.zig:11162`)

- **签名**：`pub fn markArrayBufferImmutable(rt: *JSRuntime, object: *Object) !void`。
- **作用**：设置 buffer immutable 标志。
- **实现**：忽略 rt，通过 arrayBufferImmutableSlot 写 true。
- **所有权 / 错误 / 调用**：要求 buffer payload 存在，不设置其他 flags 或改变 bytes；虽返回 !void，当前无实际 error 分支。

### `typedArrayImmutableBuffer` (`src/core/object.zig:11167`)

- **签名**：`pub fn typedArrayImmutableBuffer(rt: *JSRuntime, object: *Object) !bool`。
- **作用**：读取 view backing 的 immutable 标志。
- **实现**：缺 typed-array payload/backing 报 TypeError，否则 backing.immutable；rt 未使用。
- **所有权 / 错误 / 调用**：不同时校验 detached/范围/element_size。

### `typedArrayRejectImmutableBuffer` (`src/core/object.zig:11174`)

- **签名**：`pub fn typedArrayRejectImmutableBuffer(rt: *JSRuntime, object: *Object) !void`。
- **作用**：拒绝指向 immutable backing 的 view 操作。
- **实现**：typedArrayImmutableBuffer 为 true 则 TypeError，否则成功；查询错误也传播。
- **所有权 / 错误 / 调用**：不修改对象，也不能替代其他 view 类型、边界或 detach 校验。

### `isCompatible` (`src/core/object.zig:11178`)

- **签名**：`fn isCompatible(current_flags: property.Flags, current_slot: property.Slot, desc: descriptor.Descriptor) bool`。
- **作用**：判断 descriptor 与现有属性 flags/slot 是否兼容。
- **实现**：当前 configurable 直接 true；否则拒绝 configurable=true、enumerable 改变。generic 到此 true；其余要求 accessor 分类相同，非 accessor 且不可写时拒绝 writable=true/显式不同 SameValue；accessor 显式 getter/setter 必须分别 SameValue。
- **所有权 / 错误 / 调用**：不执行 getter 或 TDZ 检查；VarRef 比较读取 cell 值，auto-init 在不可写值比较分支视作 undefined，因此正常调用方须先物化。不是完整输入 descriptor 语法验证。

### `mergeDescriptor` (`src/core/object.zig:11206`)

- **签名**：`fn mergeDescriptor(current_flags: property.Flags, current_slot: property.Slot, desc: descriptor.Descriptor) descriptor.Descriptor`。
- **作用**：把局部 descriptor 与当前属性内容合并成完整描述符。
- **实现**：generic 保留 data/VarRef 当前值和 writable，或 accessor getter/setter，只覆盖显式 e/c；旧 auto-init 则原样返回输入。data 按 value_present 取新值或当前 data/cell 值，缺 writable 在旧 accessor 时为 false，否则沿用；accessor 缺 getter/setter 仅在旧 accessor 时沿用。e/c 缺省均继承旧 flags。
- **所有权 / 错误 / 调用**：不校验兼容性或执行 TDZ/getter；VarRef 合并为 data 描述符，但 replaceProperty 决定是否保留 cell。auto-init 应由调用方预先物化。

## 覆盖核对

- 清单函数数（本文件分到）: 69（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 69
- 未覆盖: 无
