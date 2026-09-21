# 12 — 字段 / 元素 / PropSiteCache（`vm_property_field.zig`）

文件职责：`op.get_field*` / `put_field` / `get_array_el*` / `put_array_el` / `in` / `instanceof` / `to_propkey` / `set_name*`，以及驻留 handler 的 shape 快路径与 W1 `PropSiteCache`。re-export `fastDenseArrayElementValue` 等自 `vm_property`。

## 类型

`PoppedWindow(n)`：弹出值的 native root 窗（生产 `value_root_link_containers_only` 不链标量 Zig 局部）。`activate`/`deactivate` 挂 `ValueRootFrame`。

`PropertyFastValue`：`borrowed` / `owned` / `getter` / `proxy`——atom 快路径的动作。

`TypedArrayWriteFast`：`not_typed_array` | `handled`。

`PropSiteCache` = `bytecode.PropSiteCache`。状态常量：`site_own` / `site_proto` / `site_native_getter` / `site_mega`。

`CaptureOutcome`：`.settled`（站点已守卫或退休）/ `.deferred`（AUTOINIT 尚未物化，调用方走一次普通路径）。

`FastPrototypeMethodKind`：`regexp` | `collection`。

### `PoppedWindow` (`src/exec/vm_property.zig:24`)

- **签名**：`fn PoppedWindow(comptime n: usize) type`。
- **作用**：给 `get/put_array_el` 冷路径在 intern/GC 前根住已 pop 的值。
- **实现**：返回带 `slots`/`slices`/`frame` 的结构体。
- **所有权 / 错误 / 调用**：栈值拷进 slots；deactivate 摘根。不改变 JS 所有权。

### `PoppedWindow.activate` (`src/exec/vm_property.zig:30`)

- **签名**：`inline fn activate(self: *@This(), rt: *core.JSRuntime, values: [n]core.JSValue) void`。
- **作用**：若 value-root 帧启用，把 n 个值挂到 runtime 根链。
- **实现**：`value_root_frames_enabled` 否则空。`slices[0] = borrowed slots`，`frame.activate`。
- **所有权 / 错误 / 调用**：borrow。putArrayElementAfterFastMiss / getArrayElement。

### `PoppedWindow.deactivate` (`src/exec/vm_property.zig:38`)

- **签名**：`inline fn deactivate(self: *@This(), rt: *core.JSRuntime) void`。
- **作用**：摘根。
- **实现**：`frame.deactivate`。
- **所有权 / 错误 / 调用**：defer。

### `toPropKey` (`src/exec/vm_property.zig:59`)

- **签名**：`pub fn toPropKey( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.to_propkey`：栈顶 ToPropertyKey。
- **实现**：pop，`toPropertyKeyValue`，pushOwned。
- **所有权 / 错误 / 调用**：可再入 toString。`toPropKeyVm`。

### `toPropKeyVm` (`src/exec/vm_property.zig:72`)

- **签名**：`pub noinline fn toPropKeyVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`to_propkey` 的 opcode 入口，把 ToPropertyKey 期间用户 `toString`/`valueOf`/`@@toPrimitive` 抛出的异常转成本帧 catch 跳转。
- **实现**：`toPropKey(ctx, output, global, stack, function, frame) catch |err|` → `call_runtime.handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；正常 `.done`。`toPropKey` 已经 pop 掉原值，出错时该值的所有权已交给 `toPropertyKeyValue`，本包装不补释放。
- **所有权 / 错误 / 调用**：**没有**冷表直接入口——C0 收编后（2026-08-30）直接编码 112 被标为 quarantined_unused，`tailcall_dispatch_colds.zig:272` 明确不给它建表项，让流里的该字节落到 invalid handler；实际执行只经 `using` 载体的二级分发 `using_ops.execVm` 的 `ext0_sub.to_propkey` 分支（`using_ops.zig:105`），那里把 `Step` 原样转发出去。

### `setName` (`src/exec/vm_property.zig:88`)

- **签名**：`pub noinline fn setName( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8, ) !void`。
- **作用**：服务 `op.set_name` / `op.set_name_computed`：给函数对象定义 `name`。
- **实现**：set_name 读 atom，peek 栈顶对象，`functionNameValueFromAtom` + `defineFunctionNameProperty`。computed：栈 `[key, value]`，ToPropertyKey(key)。非对象忽略。
- **所有权 / 错误 / 调用**：不 pop 函数。OOM / ToPropertyKey。

### `inOrInstanceof` (`src/exec/vm_property.zig:124`)

- **签名**：`pub noinline fn inOrInstanceof( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, ) !Step`。
- **作用**：服务 `op.in` / `op.instanceof`。
- **实现**：转 `call_runtime.inOp` / `instanceofOp`，catch handleCatchable。
- **所有权 / 错误 / 调用**：可再入 HasInstance / HasProperty。

### `field` (`src/exec/vm_property.zig:145`)

- **签名**：`pub noinline fn field( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, ) align(16) !Step`。
- **作用**：`op.get_field` / `get_field_field2` / `get_field2` / `get_field2_call_method` / `put_field` 的冷壳。驻留 handler 已跑过 `getFieldFastSlotOrAbsent`/`putFieldFastSlot`，此处是 miss。
- **实现**：读 atom，`pc += 5`（atom+cache_idx）。get_field：依次试 `dataPropertyValueForFastPath`、`ordinaryDataPropertyValueOrUndefinedForFastPath`、RegExp 原型方法、函数自有 data、collection 原型方法，否则 pop receiver `getValueProperty`。get_field2：不 pop receiver，push 值。put_field：pop value,obj；数组 length 快设；trusted 对象 `setOrDefineOwnDataPropertyForPutFieldOwned`（`.done` 消费 value）；否则 `setValueProperty`。错误先关 for-of 迭代器。
- **所有权 / 错误 / 调用**：分发 `cold_table`。private atom 由 debug 断言排除。

### `fastArrayLengthValue` (`src/exec/vm_property.zig:278`)

- **签名**：`pub inline fn fastArrayLengthValue(value: core.JSValue) ?core.JSValue`。
- **作用**：服务 `op.get_length`：密、非 exotic、非 proxy 数组的 `.length`。
- **实现**：`isArray` 且无 exotic/proxy；len≤i32max → int32 否则 float64。字符串由调用方另一臂处理。
- **所有权 / 错误 / 调用**：立即数。null 走冷 getLength。

### `debugAssertNonPrivateFieldOperandAtom` (`src/exec/vm_property.zig:300`)

- **签名**：`inline fn debugAssertNonPrivateFieldOperandAtom(rt: *const core.JSRuntime, atom_id: core.Atom) void`。
- **作用**：Debug 下断言 get/put_field 操作数绝非 private（parser 把 `#name` 分到 private 族）。
- **实现**：Release 空；Debug `kind != .private`。
- **所有权 / 错误 / 调用**：所有 trusted-atom 快路径。

### `getFieldFastSlotWithExoticOrder` (`src/exec/vm_property.zig:307`)

- **签名**：`inline fn getFieldFastSlotWithExoticOrder( rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, comptime trust_mapped_arguments_probe: bool, comptime trust_non_private_atom: bool, comptime report_absent: bool, absent: *bool, ) ?*const core.JSValue`。
- **作用**：qjs `GET_FIELD_INLINE`（19107）：对象门 → 自有 data 探 → 再 `is_exotic`。返回借用槽指针。
- **实现**：trusted 表达式对象。trusted atom 跳过 `mightBePrivate`。映射 arguments 仅当 atom 可能是 tagged-int 下标才 bail。`report_absent`：在 object/global/NativeObject（无 exotic）或 named 非下标的 Array/Arguments 链上走完则 `absent.*=true`（结果就是 undefined）。碰到 `needsSlowPropertyAccess` 返回 null（交给解析器）。phase 2 无 absent 权威。
- **所有权 / 错误 / 调用**：指针活到下次形状突变。`getFieldFastSlotOrAbsent` / `getFieldFast` / `getLengthFieldFast`。

### `namedAtomUsesOrdinaryWalkOnIndexExotic` (`src/exec/vm_property.zig:440`)

- **签名**：`inline fn namedAtomUsesOrdinaryWalkOnIndexExotic(class_id: core.class.ClassId, atom_id: core.Atom) bool`。
- **作用**：Array/Arguments 对**非下标、非 length** 的名字是普通原型走。
- **实现**：tagged-int 或 length → false；array/arguments/mapped_arguments → true。TypedArray/Proxy/String 不含。
- **所有权 / 错误 / 调用**：快走内部。

### `getFieldFastSlotOrAbsent` (`src/exec/vm_property.zig:457`)

- **签名**：`pub inline fn getFieldFastSlotOrAbsent( rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, absent: *bool, ) ?*const core.JSValue`。
- **作用**：`op.get_field` / `get_field2` 驻留：借用槽；null 时 `absent` 表示链耗尽可合成 undefined。
- **实现**：`getFieldFastSlotWithExoticOrder(..., trust_mapped=true, trust_non_private=true, report_absent=true)`。
- **所有权 / 错误 / 调用**：调用方必须把 absent 置 false。tailcall_dispatch。

### `ordinaryAccessorGetterAfterOwnMiss` (`src/exec/vm_property.zig:482`)

- **签名**：`pub fn ordinaryAccessorGetterAfterOwnMiss(probed_object: *core.Object, atom_id: core.Atom) ?core.JSValue`。
- **作用**：自有 data miss 后，沿普通链找**第一个**访问器的 getter。
- **实现**：exotic 或非 object/global/NativeObject → null。命中非 accessor → null。链尽 null。
- **所有权 / 错误 / 调用**：getter **borrowed**。驻留 accessor 臂。

### `getFieldFastSlotOrAbsentAfterOwnMiss` (`src/exec/vm_property.zig:495`)

- **签名**：`pub inline fn getFieldFastSlotOrAbsentAfterOwnMiss( rt: *core.JSRuntime, probed_object: *core.Object, atom_id: core.Atom, absent: *bool, ) ?*const core.JSValue`。
- **作用**：调用方已证无自有 data/异常槽后的原型后半，避免把原型分类投机进主导的自有命中 handler。
- **实现**：先分类已探对象（object/global / named array / 其它 slow）。再 `findOwnDataSlotFast` 循环；非权威链接到 `getFieldFastSlotAfterNonAuthoritativeLink`。
- **所有权 / 错误 / 调用**：同 absent 约定。

### `getFieldFastSlotAfterNonAuthoritativeLink` (`src/exec/vm_property.zig:551`)

- **签名**：`inline fn getFieldFastSlotAfterNonAuthoritativeLink( first: *core.Object, atom_id: core.Atom, ) ?*const core.JSValue`。
- **作用**：越过非权威链接后的两态走：命中槽或 null（**不**置 absent）。
- **实现**：slow 属性/needsSlow → null；named array 继续；链尽 null。
- **所有权 / 错误 / 调用**：上一函数。

### `getFieldFast` (`src/exec/vm_property.zig:569`)

- **签名**：`pub inline fn getFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.JSValue`。
- **作用**：计算键/通用：返回槽值拷贝，不报告 absent。保留 mapped-args 与 private 探测。
- **实现**：`trust_mapped=false, trust_non_private=false, report_absent=false`。
- **所有权 / 错误 / 调用**：borrowed 值拷贝。`atomPropertyValueForFastPath`。

### `getLengthFieldFast` (`src/exec/vm_property.zig:580`)

- **签名**：`pub inline fn getLengthFieldFast(rt: *core.JSRuntime, receiver: core.JSValue) ?core.JSValue`。
- **作用**：常量 `length` atom 的 GET_FIELD_INLINE 数据命中（可信任 mapped-args，因 length 不是下标）。
- **实现**：`trust_mapped=true, trust_non_private=true, report_absent=false`。
- **所有权 / 错误 / 调用**：`op.get_length` 热臂。

### `primitivePrototypeDataPropertyValueForFastPath` (`src/exec/vm_property.zig:592`)

- **签名**：`pub inline fn primitivePrototypeDataPropertyValueForFastPath( rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, ) ?core.JSValue`。
- **作用**：原语 receiver 走 realm `class_proto` 再普通 data 走（qjs JS_GetPropertyInternal）。
- **实现**：private 可能 → null。原型对象上 `findOwnDataValueFast`，slow/exotic/proxy 停。
- **所有权 / 错误 / 调用**：字符串的 length/下标返回 null（走 exotic）。驻留 get_field 原语臂。

### `primitivePrototypeObjectForFastPath` (`src/exec/vm_property.zig:609`)

- **签名**：`inline fn primitivePrototypeObjectForFastPath( rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, ) ?*core.Object`。
- **作用**：按 tag 取 String/Number/Boolean/BigInt/Symbol.prototype。
- **实现**：`cachedRealmValue`。字符串+length/tagged-int → null。
- **所有权 / 错误 / 调用**：只做 tag 判读 + 读 realm 缓存槽，不分配、不建根、无 error set；返回的 `*core.Object` 是**借用**的 realm intrinsic prototype，其存活由 `global` 持有，调用方不 retain 也不释放。文件私有，两处调用：`src/exec/vm_property.zig:603`（数据属性快路径）与 `:810`（带 getter/proxy 分类的快路径），两处都先过 `rt.atoms.mightBePrivate` 才进来。

### `typedArrayAccessorMethodId` (`src/exec/vm_property.zig:640`)

- **签名**：`inline fn typedArrayAccessorMethodId(atom_id: core.Atom) ?u32`。
- **作用**：length/byteLength/byteOffset → TypedArrayAccessorMethod id。
- **实现**：三原子对照。
- **所有权 / 错误 / 调用**：TA 快路径。

### `isTypedArrayPayloadAtomForFastPath` (`src/exec/vm_property.zig:648`)

- **签名**：`pub inline fn isTypedArrayPayloadAtomForFastPath(atom_id: core.Atom) bool`。
- **作用**：驻留 handler 在普通 accessor miss 后是否探 TA payload。
- **实现**：三原子。
- **所有权 / 错误 / 调用**：避免每次普通 miss 都走大分类器。

### `typedArrayNativeAccessorIdMatches` (`src/exec/vm_property.zig:652`)

- **签名**：`inline fn typedArrayNativeAccessorIdMatches(encoded_id: i32, expected_id: u32) bool`。
- **作用**：getter 的 native id 是否为 buffer 域期望方法。
- **实现**：`decodeNativeBuiltinId`，domain==buffer。
- **所有权 / 错误 / 调用**：识别未篡改的内建 getter。

### `typedArrayIntrinsicNamedValue` (`src/exec/vm_property.zig:657`)

- **签名**：`inline fn typedArrayIntrinsicNamedValue( rt: *core.JSRuntime, receiver: *core.Object, atom_id: core.Atom, ) ?PropertyFastValue`。
- **作用**：不调用 getter，直接读 live length/byteLength/byteOffset。
- **实现**：`typedArrayLength` 等，`.owned` 装箱。失败 null。
- **所有权 / 错误 / 调用**：brand 检查针对**原** receiver。

### `typedArrayShapePropertyForFastPath` (`src/exec/vm_property.zig:677`)

- **签名**：`inline fn typedArrayShapePropertyForFastPath( rt: *core.JSRuntime, receiver: *core.Object, holder: *core.Object, index: usize, atom_id: core.Atom, expected_id: u32, ) ?PropertyFastValue`。
- **作用**：holder 形状槽：data borrowed；accessor 若是内建 id 则 intrinsic，否则 `.getter`；auto_init/var_ref null。
- **实现**：`propKindAt` switch。
- **所有权 / 错误 / 调用**：返回值的所有权由 `PropertyFastValue` 的 tag 自己说明：`.borrowed` 是 holder 属性槽里的原值（借用，调用方不得当 owned 消费），`.getter` 是借用的 getter 函数值，而 `.owned` 只可能来自 `typedArrayIntrinsicNamedValue`——那是现算的立即数（`lengthIndexValue`），不占堆。不分配、无 error set；`typedArrayLength` 等的 `error.TypeError`（detach/无 payload）在 `src/exec/vm_property.zig:667`/`:671`/`:675` 被 `catch return null` 吞成「快路径不接」，由慢路径重走。文件私有，调用方 `src/exec/vm_property.zig:722`（原型链 holder）与 `:740`（自有属性）。

### `typedArrayPrototypeNamedPropertyForFastPath` (`src/exec/vm_property.zig:701`)

- **签名**：`noinline fn typedArrayPrototypeNamedPropertyForFastPath( rt: *core.JSRuntime, receiver: *core.Object, atom_id: core.Atom, expected_id: u32, ) ?PropertyFastValue`。
- **作用**：从 receiver 原型走 named TA 属性；链尽 `.borrowed undefined`；碰到 proxy → `.proxy`。
- **实现**：`findPropertyIndexTrusted`（qjs force-inlined find_own_property）。slow/exotic 停。
- **所有权 / 错误 / 调用**：outlined。`typedArrayNamedPropertyForFastPath`。

### `typedArrayNamedPropertyForFastPath` (`src/exec/vm_property.zig:726`)

- **签名**：`noinline fn typedArrayNamedPropertyForFastPath( rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, ) ?PropertyFastValue`。
- **作用**：自有再原型的 TA named 分类。
- **实现**：无 accessor id → null。自有 trusted 索引否则原型函数。
- **所有权 / 错误 / 调用**：`typedArrayPropertyValueForFastPath`。

### `typedArrayReceiverForFastPath` (`src/exec/vm_property.zig:746`)

- **签名**：`pub inline fn typedArrayReceiverForFastPath(receiver: core.JSValue) ?*core.Object`。
- **作用**：class_id 在 uint8c..float64 连续区间才当 TA 实例。
- **实现**：objectFromValue + 区间。
- **所有权 / 错误 / 调用**：驻留 miss 路由。

### `typedArrayPropertyValueForFastPath` (`src/exec/vm_property.zig:756`)

- **签名**：`pub inline fn typedArrayPropertyValueForFastPath( rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, ) ?PropertyFastValue`。
- **作用**：故意从 `atomPropertyValueForFastPath` 拆出，以免普通 accessor/Proxy 读改变驻留形态。
- **实现**：private 可能 → null；否则 named 分类。
- **所有权 / 错误 / 调用**：分发 TA 臂。

### `getLengthActionForFastPath` (`src/exec/vm_property.zig:771`)

- **签名**：`pub inline fn getLengthActionForFastPath(rt: *core.JSRuntime, receiver: core.JSValue) ?PropertyFastValue`。
- **作用**：`length` 在数据 helper miss 后：qjs 仍先看自有 accessor 再 `is_exotic`（用户 length getter、映射 arguments）。
- **实现**：`findProperty` switch data/getter；TA 走原型 intrinsic（brand 用原 receiver）；proxy 标记；slow 停。
- **所有权 / 错误 / 调用**：`op.get_length` 第二臂。

### `primitivePrototypePropertyForFastPath` (`src/exec/vm_property.zig:799`)

- **签名**：`inline fn primitivePrototypePropertyForFastPath( rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, ) ?PropertyFastValue`。
- **作用**：原语上的完整动作（data/getter/proxy），不只 data。
- **实现**：同原型走，`findProperty`。
- **所有权 / 错误 / 调用**：`atomPropertyValueForFastPath` 非对象。

### `atomPropertyValueForFastPath` (`src/exec/vm_property.zig:826`)

- **签名**：`pub inline fn atomPropertyValueForFastPath( rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, ) ?PropertyFastValue`。
- **作用**：静态与计算属性共用的 atom 键快路径。普通接收者给完整 data/getter/Proxy/missing；class exotic 与原语下标仍走解析器。
- **实现**：object/array/global/NativeObject → `ordinaryDataPropertyLookup`。其它对象 `getFieldFast` 当 borrowed。非对象走 primitive prototype property。
- **所有权 / 错误 / 调用**：data/getter **borrowed**，调用方在释放 receiver 前必须 dup。

### `existingPropertyKeyValueForFastPath` (`src/exec/vm_property.zig:855`)

- **签名**：`pub inline fn existingPropertyKeyValueForFastPath( rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue, key: core.JSValue, ) ?PropertyFastValue`。
- **作用**：计算属性：已有 symbol/string 的弱 atom，无 ToPropertyKey 再入。
- **实现**：`existingPropertyKeyAtomForFastPath`。字符串且是数组下标则试 dense/string/TA 元素（`.owned`）。否则 atom 路径。
- **所有权 / 错误 / 调用**：不能再入所以借 atom 安全。`op.get_array_el` 热。

### `existingPropertyKeyAtomForFastPath` (`src/exec/vm_property.zig:879`)

- **签名**：`pub inline fn existingPropertyKeyAtomForFastPath(value: core.JSValue) ?core.Atom`。
- **作用**：qjs `JS_ValueToAtom` 对已有 symbol 先于通用转换。
- **实现**：`asSymbolAtom` 或 `stringAtomId`。
- **所有权 / 错误 / 调用**：id 借自仍活的 key；会再入的调用方必须先 retain。

### `putFieldFastSlot` (`src/exec/vm_property.zig:906`)

- **签名**：`pub inline fn putFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*core.JSValue`。
- **作用**：`op.put_field` 热窗（19188）：可变的自有可写 data 槽地址，供驻留 handler 自己 swap-then-free。
- **实现**：trusted 对象；非 private；mapped arguments bail（槽可能是过期镜像）。`findWritableOwnDataSlotFast`。miss 不走原型（写窗只认自有命中）。
- **所有权 / 错误 / 调用**：指针立刻消费。

### `replaceTopBorrowed` (`src/exec/vm_property.zig:921`)

- **签名**：`inline fn replaceTopBorrowed( _: *core.JSRuntime, stack: *stack_mod.Stack, index: usize, _: core.JSValue, new_value: core.JSValue, ) void`。
- **作用**：get_field 用 borrowed 结果覆盖 receiver 槽。
- **实现**：`stack.values[index] = new_value`（dup 语义由调用约定：new_value 已是需发表的拷贝或立即数）。
- **所有权 / 错误 / 调用**：`field` 快命中。rt/old 未用。

### `replaceTopOwned` (`src/exec/vm_property.zig:931`)

- **签名**：`inline fn replaceTopOwned( _: *core.JSRuntime, stack: *stack_mod.Stack, index: usize, _: core.JSValue, new_value: core.JSValue, ) void`。
- **作用**：覆盖为 owned 方法值。
- **实现**：同样直接存。
- **所有权 / 错误 / 调用**：RegExp/collection 方法。

### `setArrayLengthForPutFieldFastPath` (`src/exec/vm_property.zig:941`)

- **签名**：`fn setArrayLengthForPutFieldFastPath( rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue, ) bool`。
- **作用**：`obj.length = n` 快设（可写密数组，无需删的高位 shape 下标）。
- **实现**：atom 必须 length；非负 int32；密且 shrink 时 shape 无 ≥new_len 的下标；truncate；增长只改 length（尾洞，qjs 9447）。
- **所有权 / 错误 / 调用**：true 则 value 视为已消费（立即数）。`field` put。

### `putArrayElementAfterFastMiss` (`src/exec/vm_property.zig:974`)

- **签名**：`pub inline fn putArrayElementAfterFastMiss( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.put_array_el` 在驻留已跑完 Array/slow Array/TA 类开关之后的继续（qjs put_array_el_slow_path → JS_SetPropertyValue）。
- **实现**：pop value,key,obj，`PoppedWindow(3)`。int+object miss 跳过重复 TA/dense 探，直接 `atomFromUInt32` Set。否则 TA/dense 再试。key 先 ToPropertyKey（副作用在 nullish TypeError 之前）。再 Set。
- **所有权 / 错误 / 调用**：handleCatchable。分发。

### `getArrayElement` (`src/exec/vm_property.zig:1052`)

- **签名**：`pub noinline fn getArrayElement( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, opc: u8, ) !Step`。
- **作用**：服务 `op.get_array_el` / `get_array_el2` / `get_array_el3` 冷路径。
- **实现**：el：pop key,obj，窗根；nullish TypeError；**先** mapped arguments；已有 atom 则 retain 后 getValueProperty；再 dense/string/TA；否则 ToPropertyKeyAtom。el2：不 pop，用值覆盖 key 槽。el3：dense/string/TA 三条快路径直接 `pushOwned` 值（key 槽不动）；慢路径先把 key 槽换成 ToPropertyKey 的结果再 push 值。
- **所有权 / 错误 / 调用**：el2/el3 保持 obj。分发 miss。

### `readTypedArrayIndexFast` (`src/exec/vm_property.zig:1195`)

- **签名**：`pub noinline fn readTypedArrayIndexFast( object: *const core.Object, class_id: core.class.ClassId, index: u32, ) core.JSValue`。
- **作用**：TA `obj[int]` 读；返回非 optional JSValue（避免巨大 optional-unwrap 帧）。
- **实现**：`typedArrayPayloadFast`；`index >= live_length`（detach 发 live_length=0）→ undefined；`decodeNumericElementByClass`。
- **所有权 / 错误 / 调用**：立即数/装箱。热 get_array_el。

### `fastTypedArrayElementValue` (`src/exec/vm_property.zig:1210`)

- **签名**：`pub fn fastTypedArrayElementValue(obj: core.JSValue, key: core.JSValue) ?core.JSValue`。
- **作用**：未分类 class 时的 TA 元素读。
- **实现**：对象+非负 int32+numeric TA class → `readTypedArrayIndexFast`。
- **所有权 / 错误 / 调用**：已分类调用方应直接 readTypedArrayIndexFast。

### `putTypedArrayElementFast` (`src/exec/vm_property.zig:1236`)

- **签名**：`pub fn putTypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !TypedArrayWriteFast`。
- **作用**：qjs JS_SetPropertyValue TA 臂：先转换（可再入 valueOf 并 DETACH）再 bounds 复查；OOB 静默成功。
- **实现**：非 TA/负下标/对象值/BigInt/Symbol → `.not_typed_array`（抛错转换必须在有效性检查前，慢路径 convert-first）。kind 1–10；immutable backing → `.handled`。整数 kind + int32：无用户代码，直接写。否则 `writeNumericElement` 进 scratch，再复查 live_length，`storeElementBytes`。
- **所有权 / 错误 / 调用**：转换 TypeError 上抛。BigInt64 走慢。put_array_el。

### `storeElementBytes` (`src/exec/vm_property.zig:1302`)

- **签名**：`inline fn storeElementBytes(dst: []u8, scratch: *const [8]u8, width: u32) void`。
- **作用**：comptime 宽度的直接存，避免 runtime-length memcpyFast（gbemu VRAM）。
- **实现**：switch 1/2/4/8，else memcpy。
- **所有权 / 错误 / 调用**：`putTypedArrayElementFast`。

### `fastPrototypeMethodValue` (`src/exec/vm_property.zig:1318`)

- **签名**：`noinline fn fastPrototypeMethodValue( rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom, kind: FastPrototypeMethodKind, ) ?core.JSValue`。
- **作用**：自有无该名 + 原型自有 data 且 native id 匹配 → 方法值（RegExp test/exec，或 collection 表）。
- **实现**：name 字符串；regexp 限 class regexp；collection 用 class+name 查 id。`hasOwnProperty` 则 null。
- **所有权 / 错误 / 调用**：返回 borrowed 方法对象值，调用方 replaceTopOwned。

### `fastRegExpPrototypeMethodValue` (`src/exec/vm_property.zig:1354`)

- **签名**：`inline fn fastRegExpPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue`。
- **作用**：`re.test` / `re.exec` 未覆盖时。
- **实现**：kind `.regexp`。
- **所有权 / 错误 / 调用**：`field` get。

### `fastCollectionPrototypeMethodValue` (`src/exec/vm_property.zig:1358`)

- **签名**：`inline fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue`。
- **作用**：Map/Set/Weak* 原型方法。
- **实现**：kind `.collection`。
- **所有权 / 错误 / 调用**：`field` get。

### `fastStringIndexValue` (`src/exec/vm_property.zig:1362`)

- **签名**：`fn fastStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue) ?core.JSValue`。
- **作用**：字符串 `s[i]` 单字节缓存。
- **实现**：string+int、范围内、unit<0x100 → `cachedSingleByteString`。
- **所有权 / 错误 / 调用**：owned intern。宽字符 null 走慢。

### `stackValueFromTop` (`src/exec/vm_property.zig:1376`)

- **签名**：`fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue`。
- **作用**：borrow 距顶 offset 的槽。
- **实现**：underflow 检查。
- **所有权 / 错误 / 调用**：get_array_el2/3、setName。

### `noPropSite` (`src/exec/vm_property.zig:1415`)

- **签名**：`pub inline fn noPropSite() *PropSiteCache`。
- **作用**：无 cache_idx / 无站点数组时的退休哨兵。
- **实现**：`&no_prop_sites[0]`，state 已是 mega，guard_key 0 永不匹配 identity（从 1 起）。
- **所有权 / 错误 / 调用**：`Vm` 解析函数时。

### `noPropSiteBase` (`src/exec/vm_property.zig:1419`)

- **签名**：`pub inline fn noPropSiteBase() [*]PropSiteCache`。
- **作用**：256 项同一哨兵的基址，热路径按 cache_idx 读无需 null 测。
- **实现**：`&no_prop_sites`。
- **所有权 / 错误 / 调用**：`Vm.prop_sites`。

### `siteCapturable` (`src/exec/vm_property.zig:1429`)

- **签名**：`pub inline fn siteCapturable(site: *const PropSiteCache) bool`。
- **作用**：guard miss 可否覆盖条目。mega 后永不离开。
- **实现**：`state != site_mega`。miss_budget 次覆盖后退休（Hermes 覆盖而非永久锁；永久锁在 poly_stress -9.8%）。
- **所有权 / 错误 / 调用**：驻留 miss 腿。

### `retireSite` (`src/exec/vm_property.zig:1433`)

- **签名**：`fn retireSite(site: *PropSiteCache) CaptureOutcome`。
- **作用**：置 mega，清 keys，`.settled`。
- **实现**：写 state/guard/proto/secondary=0。
- **所有权 / 错误 / 调用**：capture 失败臂。

### `noteSiteMiss` (`src/exec/vm_property.zig:1442`)

- **签名**：`fn noteSiteMiss(site: *PropSiteCache) bool`。
- **作用**：记一次覆盖；已 mega 或超预算则 false。
- **实现**：非 empty 时 misses++ 或 retire。
- **所有权 / 错误 / 调用**：capture 入口。

### `slotIndexOf` (`src/exec/vm_property.zig:1454`)

- **签名**：`inline fn slotIndexOf(holder: *const core.Object, slot: *const core.JSValue) ?u16`。
- **作用**：槽指针相对 `prop_values` 的 u16 索引；形状允许 u32，缓存只收 u16。
- **实现**：`cast(u16, (addr-base)/sizeof(Entry))`。
- **所有权 / 错误 / 调用**：不可表示则走普通走。

### `siteCacheableReceiverClass` (`src/exec/vm_property.zig:1471`)

- **签名**：`inline fn siteCacheableReceiverClass(object: *const core.Object) bool`。
- **作用**：哪些 class 的自有探对 named atom 权威，因而可缓存原型链。Shape 不钉 class，原型/native-getter 臂每次仍核 class_id。
- **实现**：`!needsSlowPropertyAccess()`（宽于早期 object/global/NativeObject，否则 `f.call` 第一次就 mega）。
- **所有权 / 错误 / 调用**：`captureFieldSite`。

### `isNativeGetterValue` (`src/exec/vm_property.zig:1501`)

- **签名**：`fn isNativeGetterValue(accessor: core.JSValue) bool`。
- **作用**：K3 native getter 准入。只缓存 accessor **槽**，不缓存解析出的 NativeEntry（defineProperty 可换 getter 而不改形状）。
- **实现**：c_function + `nativeCallTarget().entry.kind == .getter`。
- **所有权 / 错误 / 调用**：capture native_getter 臂。

### `captureFieldSite` (`src/exec/vm_property.zig:1520`)

- **签名**：`pub noinline fn captureFieldSite(site: *PropSiteCache, object: *core.Object, atom_id: core.Atom, allow_native_getter: bool) CaptureOutcome`。
- **作用**：读族（get_field/get_field2/融合）的唯一捕获核。只从 guard miss 到达，noinline 保持命中臂叶子。
- **实现**：自有 data → `.own`（可保留 secondary 上一形状，避免两形状交替直到退休）。slow 自有 → retire。接收者 class 不可缓存 → retire。原型自有 data → `.proto`。原型 slow：native getter → `.native_getter`；**auto_init** 且未超预算 → `.deferred`（`Function.prototype.call` 等第一次访问才物化；若此处 retire 会永久锁死几乎所有原型方法站点）。
- **所有权 / 错误 / 调用**：不保留指针，只 identity。`tailcall_dispatch` miss。

### `capturePutSite` (`src/exec/vm_property.zig:1596`)

- **签名**：`pub noinline fn capturePutSite(site: *PropSiteCache, object: *core.Object, atom_id: core.Atom) void`。
- **作用**：`put_field` 捕获：仅可写自有 data。可写与 data-kind 在形状 flags 里，identity 足以证明直写合法。
- **实现**：mapped arguments retire。`findWritableOwnDataSlotFast` 成功 → `.own`，否则 retire。
- **所有权 / 错误 / 调用**：分发 put miss。

## 覆盖核对

- 清单函数数: 59
- 本文标题覆盖: 59
- 未覆盖: 无
