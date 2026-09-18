# 14b — `property_direct.zig`：无用户代码的属性快探

[`src/exec/property_direct.zig`](../../src/exec/property_direct.zig) 只做 **guarded probe**：在确认 class / shape / flags / atom 种类 / 非 exotic / 非 Proxy 之后，直接读或写 data 槽。命中失败必须落到 `property_ops` / `object_ops` / `vm_property.zig`。返回的 `JSValue` 默认 **borrowed**；名字带 `Owned` 的写路径在槽提交后才消费输入。

本文件 **不是** 完整 IC：每次调用都重新看当前 object。`PropSiteCache` 在别处。

## 类型

`FastOwnDataLookup`：`.value(BorrowedOwnDataLookup)` / `.missing` / `.slow`。`BorrowedOwnDataLookup` 带 `index` 与 borrowed `value`。

`BorrowedProtoDataLookup`：另带 `holder: *Object`（立即原型上的槽）。

`BorrowedGlobalDataLookup` / `WritableGlobalDataStore`：全局对象上的 data 槽与可写视图。

`FastProtoDataLookup`：与 own 相同的三态，值臂是原型 lookup。

`OrdinaryComputedPropertyLookup`（公开）：`.value` / `.getter` / `.proxy` / `.undefined` / `.slow`。给计算属性快路径分类，不调用 getter。

`DataSlot`：`entry: *property.Entry` + `value: *JSValue`，指向 data 臂。

---

### `dataPropertyValueForFastPath` (`src/exec/property_direct.zig:61`)

- **签名**：`pub inline fn dataPropertyValueForFastPath( rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, ) ?core.JSValue`。
- **作用**：普通对象上读公开 data 属性的最快臂：own，否则立即原型一层。
- **实现**：`objectFromValue` 失败 → `null`。`cacheableNamedDataObject` 为假或 atom 为 private → `null`。先 `fastOwnOrdinaryDataPropertyLookupForObject`，`.value` 即返回；否则 `fastImmediatePrototypeDataPropertyLookupForObject`。两层都 miss/slow → `null`。
- **所有权 / 错误 / 调用**：borrowed，不抛。VM 字段读在完整 `[[Get]]` 之前试；`null` 表示必须走慢路径。

### `functionOwnDataPropertyValueForFastPath` (`src/exec/property_direct.zig:82`)

- **签名**：`pub fn functionOwnDataPropertyValueForFastPath(value: core.JSValue, atom_id: core.Atom) ?core.JSValue`。
- **作用**：函数对象上读 own data（跳过 `arguments`/`caller`）。
- **实现**：`functionOwnDataPropertyObject` 得到对象后 `getOwnDataPropertyValue`。
- **所有权 / 错误 / 调用**：borrowed。给函数 `length`/`name` 一类不变 own 数据。

### `functionOwnDataPropertyObject` (`src/exec/property_direct.zig:87`)

- **签名**：`fn functionOwnDataPropertyObject(value: core.JSValue, atom_id: core.Atom) ?*core.Object`。
- **作用**：确认接收者是函数类且键不是 `arguments`/`caller`。
- **实现**：`objectFromValue`；`isFunctionLikeClassId`；排除两个遗留 atom。
- **所有权 / 错误 / 调用**：不分配。`arguments`/`caller` 可能是访问器或严格模式 TypeError，必须慢路径。

### `isFunctionLikeClassId` (`src/exec/property_direct.zig:94`)

- **签名**：`fn isFunctionLikeClassId(class_id: core.ClassId) bool`。
- **作用**：识别可走函数 own-data 快探的 class。
- **实现**：`c_function`、所有 bytecode function class、`bound_function`、`c_function_data`、async resume class、`c_closure`。
- **所有权 / 错误 / 调用**：纯谓词。单测钉死四个 bytecode function class 为真、`object` 为假。

### `cacheableNamedDataObject` (`src/exec/property_direct.zig:116`)

- **签名**：`inline fn cacheableNamedDataObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool`。
- **作用**：该对象+键能否当普通 named data 缓存。
- **实现**：普通 `object` 且非 array/global/proxy → `!hasExoticMethods()`。Proxy 或 exotic → 假。Array 上 `length` 或整数下标 → 假。其他内建 class（非 object、非 global、`class_id < init_count`）→ 假。其余真。
- **所有权 / 错误 / 调用**：不抛。这是快探的总闸。

### `fastImmediatePrototypeDataPropertyLookupForObject` (`src/exec/property_direct.zig:131`)

- **签名**：`fn fastImmediatePrototypeDataPropertyLookupForObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) align(32) FastProtoDataLookup`。
- **作用**：own miss 时只看 **一层** 立即原型的 ordinary data。
- **实现**：own 已是 `.value` 或 `.slow` → 返回 `.slow`（调用方本应先看 own）。own missing 后取 `getPrototype()`；无原型 → `.missing`。holder 不可 cacheable → `.slow`。再对 holder 做 own ordinary lookup。
- **所有权 / 错误 / 调用**：不沿原型链走多步，避免隐藏 getter。`align(32)` 是热路径布局。

### `fastOwnOrdinaryDataPropertyLookupForObject` (`src/exec/property_direct.zig:145`)

- **签名**：`fn fastOwnOrdinaryDataPropertyLookupForObject(object: *core.Object, atom_id: core.Atom) FastOwnDataLookup`。
- **作用**：shape 上找 own 槽：data 返回值，其余 slow，没有则 missing。
- **实现**：`findProperty` miss → `.missing`。`propKindAt`：`.data` 读 `slot.data`；`.var_ref` / `.auto_init` / `.accessor` → `.slow`。
- **所有权 / 错误 / 调用**：borrowed。不物化 auto-init。

### `writableOwnDataPropertyLookup` (`src/exec/property_direct.zig:153`)

- **签名**：`fn writableOwnDataPropertyLookup(object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom) ?BorrowedOwnDataLookup`。
- **作用**：把已有 own lookup 收成可写 data 槽视图。
- **实现**：`writableDataSlotAt`；失败 `null`，成功保留 index 与当前值。
- **所有权 / 错误 / 调用**：单测用它验证 `Private_brand` 替换。

### `setOwnDataPropertyLookup` (`src/exec/property_direct.zig:158`)

- **签名**：`fn setOwnDataPropertyLookup(rt: *core.JSRuntime, object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom, value: core.JSValue) !bool`。
- **作用**：按 lookup.index 写 own data。
- **实现**：转 `setOwnDataPropertyAt`。
- **所有权 / 错误 / 调用**：`false` 表示槽不可写，不是 JS 异常。

### `setOwnDataPropertyAt` (`src/exec/property_direct.zig:162`)

- **签名**：`fn setOwnDataPropertyAt(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) !bool`。
- **作用**：把 `value` 存进指定 index 的可写 data 槽。
- **实现**：`writableDataSlotAt` 失败 → `false`，否则 `slot.value.* = value` 并返回 `true`。原先按 `Private_brand` / `requiresRefCount` 分的两臂在 tracing GC 下逐字同构，已折成一句。
- **所有权 / 错误 / 调用**：调用方保证 `value` 生命周期。`rt` 形参不被读取（已发布对象的就地覆写不需要运行时钩子），保留是为了与本文件其余 `set*At` 写入者同形，函数头注释已写明。

### `ordinaryDataPropertyLookup` (`src/exec/property_direct.zig:172`)

- **签名**：`pub fn ordinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryComputedPropertyLookup`。
- **作用**：沿原型链分类 ordinary data/getter/proxy/undefined，全程不调用户代码。
- **实现**：private → `.slow`。非对象 → `.slow`。循环：有 `proxyTarget` → `.proxy`；`hasExoticMethods` → `.slow`；Array 的 length/下标 → `.slow`；非 object/global 且非 native object → `.slow`。`findProperty` 命中：data → `.value`，accessor → `.getter`（只取 getter 值，不调用），var_ref/auto_init → `.slow`。miss 则下一原型；无原型时 Array 仍 `.slow`，否则 `.undefined`。
- **所有权 / 错误 / 调用**：borrowed。Proxy 接收者返回对象指针给调用方去走 trap。`getProxyProperty` 用它的值臂跳过完整 Get。

### `ordinaryDataPropertyValueOrUndefinedForFastPath` (`src/exec/property_direct.zig:196`)

- **签名**：`pub fn ordinaryDataPropertyValueOrUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue`。
- **作用**：把 lookup 收成「值或 undefined」；getter/proxy/slow 返回 `null`。
- **实现**：switch lookup。`.undefined` 变成 `undefinedValue()`，与「必须慢路径」的 `null` 区分。
- **所有权 / 错误 / 调用**：`getProxyProperty` 读 handler.`get` 与 target 数据时用。

### `declaredGlobalVarDataBorrowedLookup` (`src/exec/property_direct.zig:204`)

- **签名**：`fn declaredGlobalVarDataBorrowedLookup(global: *core.Object, function: *const bytecode.FunctionBytecode, atom_id: core.Atom) ?BorrowedGlobalDataLookup`。
- **作用**：仅当该 atom 是函数的 `global_decl` 闭包变量时，读全局 own data。
- **实现**：扫 `function.closureVar()`，`closureType() == .global_decl` 且 `var_name == atom_id` 才 `globalOwnDataPropertyBorrowedLookup`。
- **所有权 / 错误 / 调用**：避免把偶然同名的全局属性当「已声明 var」写穿。

### `globalOwnDataPropertyBorrowedLookup` (`src/exec/property_direct.zig:212`)

- **签名**：`fn globalOwnDataPropertyBorrowedLookup(global: *core.Object, atom_id: core.Atom) ?BorrowedGlobalDataLookup`。
- **作用**：线性扫全局 shape，找非删除、非访问器的 data 槽。
- **实现**：exotic → `null`。`shapeProps` 上匹配 atom；accessor 或 `kind != .data` → `null`。
- **所有权 / 错误 / 调用**：borrowed。全局对象属性少，线性扫可接受。

### `globalOwnDataPropertyValue` (`src/exec/property_direct.zig:224`)

- **签名**：`pub fn globalOwnDataPropertyValue(global: *core.Object, atom_id: core.Atom) ?core.JSValue`。
- **作用**：公开入口：全局 own data 的 borrowed 值。
- **实现**：lookup 失败 `null`，否则 `lookup.value`。
- **所有权 / 错误 / 调用**：不抛。

### `globalOwnDataPropertyBorrowedAt` (`src/exec/property_direct.zig:229`)

- **签名**：`fn globalOwnDataPropertyBorrowedAt(global: *core.Object, index: usize, atom_id: core.Atom) ?core.JSValue`。
- **作用**：按已解析 index 再确认槽仍是该 atom 的 data。
- **实现**：`dataSlotAt` 后读 `slot.value.*`。
- **所有权 / 错误 / 调用**：shape 变化后 index 失效则 `null`。

### `globalOwnWritableDataPropertyLookup` (`src/exec/property_direct.zig:234`)

- **签名**：`fn globalOwnWritableDataPropertyLookup(global: *core.Object, atom_id: core.Atom) ?WritableGlobalDataStore`。
- **作用**：全局 own data 且 writable 的存储描述。
- **实现**：borrowed lookup + `globalWritableDataPropertyLookupAt`。
- **所有权 / 错误 / 调用**：只读数据返回 `null`（单测覆盖）。

### `globalDataPropertyLookupForFastPath` (`src/exec/property_direct.zig:239`)

- **签名**：`fn globalDataPropertyLookupForFastPath( rt: *core.JSRuntime, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?BorrowedGlobalDataLookup`。
- **作用**：全局读快路径的 lookup 入口。
- **实现**：转 `installableGlobalDataPropertyLookup`。`site_pc` 现被忽略（无 profile IC）。`…NoProfile` 现在是本函数的一行别名。
- **所有权 / 错误 / 调用**：给 `ValueForFastPath` 用。

### `globalDataPropertyValueForFastPath` (`src/exec/property_direct.zig:249`)

- **签名**：`pub fn globalDataPropertyValueForFastPath( rt: *core.JSRuntime, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?core.JSValue`。
- **作用**：VM 全局读快路径：声明 var 或 own data。
- **实现**：lookup 后返回 borrowed 值。
- **所有权 / 错误 / 调用**：`null` 时 opcode 走完整全局 Get。

### `globalDataPropertyLookupForFastPathNoProfile` (`src/exec/property_direct.zig:263`)

- **签名**：`const globalDataPropertyLookupForFastPathNoProfile = globalDataPropertyLookupForFastPath;`。
- **作用**：站点 profile 搬出本文件后两套 lookup 已完全同体，这里保留第二个名字，让两个 `globalDataPropertyValueForFastPath*` 入口仍可区分。
- **实现**：无独立函数体（一行别名，原先逐字重复的实现已删）。
- **所有权 / 错误 / 调用**：完全等同被别名者。

### `globalDataPropertyValueForFastPathNoProfile` (`src/exec/property_direct.zig:265`)

- **签名**：`pub fn globalDataPropertyValueForFastPathNoProfile( rt: *core.JSRuntime, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?core.JSValue`。
- **作用**：无 profile 的全局读快路径值。
- **实现**：lookup → value。
- **所有权 / 错误 / 调用**：同 `ForFastPath`。

### `globalWritableDataStoreIndexForFastPath` (`src/exec/property_direct.zig:276`)

- **签名**：`fn globalWritableDataStoreIndexForFastPath( rt: *core.JSRuntime, lexicals: ?*core.Object, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?usize`。
- **作用**：可写全局槽的 index，供调用方自己写。
- **实现**：`globalWritableDataStoreLookupForFastPath` 的 `.index`。
- **所有权 / 错误 / 调用**：词法环境已有同名绑定则 `null`（不能写穿全局）。

### `globalWritableDataStoreLookupForFastPath` (`src/exec/property_direct.zig:288`)

- **签名**：`fn globalWritableDataStoreLookupForFastPath( rt: *core.JSRuntime, lexicals: ?*core.Object, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?WritableGlobalDataStore`。
- **作用**：解析「可以把这个名字当全局可写 data 写」的槽。
- **实现**：忽略 `rt`/`site_pc`。`lexicals.hasOwnProperty(atom_id)` → `null`。优先 `declaredGlobalVarDataBorrowedLookup`，否则任意全局 own data；再要求 writable。
- **所有权 / 错误 / 调用**：shadow 在词法对象上时快路径拒绝，避免跳过 TDZ/const。

### `setGlobalWritableDataStoreForFastPathOwned` (`src/exec/property_direct.zig:308`)

- **签名**：`pub fn setGlobalWritableDataStoreForFastPathOwned( rt: *core.JSRuntime, lexicals: ?*core.Object, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, new_value: core.JSValue, ) bool`。
- **作用**：owned 语义的全局可写 data 快写。
- **实现**：lookup 失败 `false`；否则 `setGlobalOwnWritableDataPropertyAtOwned`。
- **所有权 / 错误 / 调用**：`true` 表示已接收 `new_value`；`false` 时调用方仍拥有该值。

### `setGlobalWritableDataStoreLookupOwned` (`src/exec/property_direct.zig:321`)

- **签名**：`fn setGlobalWritableDataStoreLookupOwned( rt: *core.JSRuntime, global: *core.Object, lookup: WritableGlobalDataStore, atom_id: core.Atom, new_value: core.JSValue, ) bool`。
- **作用**：已有 `WritableGlobalDataStore` 时的 owned 写。
- **实现**：转 `setGlobalOwnWritableDataPropertyAtOwned`。
- **所有权 / 错误 / 调用**：单测覆盖。

### `setGlobalDataPropertyLookup` (`src/exec/property_direct.zig:331`)

- **签名**：`fn setGlobalDataPropertyLookup( rt: *core.JSRuntime, global: *core.Object, lookup: BorrowedGlobalDataLookup, atom_id: core.Atom, new_value: core.JSValue, ) bool`。
- **作用**：已有 borrowed lookup 的全局写（非 Owned 名字，实现仍走同一写函数）。
- **实现**：`setGlobalOwnWritableDataPropertyAt`。
- **所有权 / 错误 / 调用**：只读槽返回 `false` 且不写。

### `installableGlobalDataPropertyLookup` (`src/exec/property_direct.zig:341`)

- **签名**：`fn installableGlobalDataPropertyLookup( rt: *core.JSRuntime, global: *core.Object, function: *const bytecode.FunctionBytecode, site_pc: usize, atom_id: core.Atom, ) ?BorrowedGlobalDataLookup`。
- **作用**：全局读：先声明 var，再任意 own data。
- **实现**：`rt`/`site_pc` 形参不被读取（站点 profile 已不在本文件）。`declaredGlobalVarDataBorrowedLookup` 优先。
- **所有权 / 错误 / 调用**：两套 ForFastPath lookup 的共同实现。

### `setGlobalOwnWritableDataPropertyAt` (`src/exec/property_direct.zig:356`)

- **签名**：`fn setGlobalOwnWritableDataPropertyAt(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool`。
- **作用**：按 index 写全局可写 data，并打分代屏障。
- **实现**：`writableDataSlotAt` 失败 → `false`。`slot.entry.slot = .{ .data = new_value }`，然后 `rt.gc.generationalBarrier(global.gcHeader(), new_value.cycleMarkHeader())`。
- **所有权 / 错误 / 调用**：注释：更新已有全局 var 是堆存储，全局长寿，新值是 minor 看不见的 old-to-young 边。

### `setGlobalOwnWritableDataPropertyAtOwned` (`src/exec/property_direct.zig:368`)

- **签名**：`const setGlobalOwnWritableDataPropertyAtOwned = setGlobalOwnWritableDataPropertyAt;`。
- **作用**：`Owned` 是 rc 时代的遗名——tracing GC 下调用方没有引用要交出，它就是借用版写入者本身。
- **实现**：无独立函数体（一行别名，原先逐字重复的实现已删）。
- **所有权 / 错误 / 调用**：完全等同被别名者（写槽 + generational barrier）。

### `writableDataSlotAt` (`src/exec/property_direct.zig:370`)

- **签名**：`fn writableDataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot`。
- **作用**：确认 index 处是该 atom 的 **可写** data 槽。
- **实现**：`dataSlotAt` 后检查 `propFlagsAt(index).writable`。
- **所有权 / 错误 / 调用**：只读 / accessor 返回 `null`。

### `globalWritableDataPropertyLookupAt` (`src/exec/property_direct.zig:376`)

- **签名**：`fn globalWritableDataPropertyLookupAt(global: *core.Object, index: usize, atom_id: core.Atom) ?WritableGlobalDataStore`。
- **作用**：把可写槽收成 `WritableGlobalDataStore`。
- **实现**：`writableDataSlotAt` → `{ .index, .value = slot.value.* }`。
- **所有权 / 错误 / 调用**：值 borrowed。

### `dataSlotAt` (`src/exec/property_direct.zig:381`)

- **签名**：`fn dataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot`。
- **作用**：底层槽校验：非 exotic、index 在范围内、atom 匹配、未删除、kind 为 data。
- **实现**：失败任一条件 → `null`。成功返回 `{ .entry, .value = &entry.slot.data }`。
- **所有权 / 错误 / 调用**：所有快写/快读的最后一道守卫。

## 覆盖核对

- 清单函数数: 30
- 本文标题覆盖: 32（含 2 条清单外的内嵌辅助函数标题）
- 未覆盖: 无
