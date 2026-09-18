# 12 — 属性共享探针（`vm_property.zig`）

文件职责：字段/全局/局部/var-ref 的**解码与有守卫快路径**，给 `vm_property_*.zig` 和驻留 handler 共用。结果结构标明 borrowed vs owned。代理/强制转换的完整语义在更慢的 owning 模块。comptime 断言：`put_loc0`/`get_loc0`/`undefined`/`drop`/`return_undef`/`return_async` 仍是 1 字节，`get_field` 族仍是 5 字节。

## 类型

`Step`：`done` / `continue_loop`。

`FieldAtom`：`atom` + `next_pc`，给前瞻融合用。

`objectFromValue` = `value_semantics.objectFromValueTrustedExpression`（表达式值，不是 var-ref cell）。

### `decodeFieldAtom` (`src/exec/vm_property.zig:46`)

- **签名**：`pub fn decodeFieldAtom(code: []const u8, pc: usize, expected_op: u8) ?FieldAtom`。
- **作用**：服务 `op.get_field` / `op.get_field2` / `op.put_field` 前瞻：确认 opcode 并读 u32 atom。
- **实现**：`pc+5 > len` 或 `code[pc] != expected_op` → null。否则 atom = 小端 u32 at `pc+1`，`next_pc = pc+5`。comptime 核对这三族 size 为 5。
- **所有权 / 错误 / 调用**：无分配。当前树内无调用方（前瞻融合已在分发层自行解码），只剩 comptime 的 stride 断言仍在守 `get_field` 族的 5 字节假设。

### `globalVarAtom` (`src/exec/vm_property.zig:62`)

- **签名**：`pub fn globalVarAtom(function: *const bytecode.FunctionBytecode, idx: u16) ?core.Atom`。
- **作用**：把 `op.get_var`/`op.put_var` 的 var-ref 索引收成 atom。
- **实现**：先 `closureVar()[idx].var_name`；越界则 `varRefName(idx)`；再越界 null。
- **所有权 / 错误 / 调用**：atom 是字节码表里的 id。`vm_property_globals` 使用。

### `varRefReadableBorrowed` (`src/exec/vm_property.zig:68`)

- **签名**：`pub fn varRefReadableBorrowed(frame: *const frame_mod.Frame, idx: u16) ?core.JSValue`。
- **作用**：直接读闭包 cell 的当前值（borrow），TDZ/已删绑定返回 null。
- **实现**：越界 null。`slot_ops.varRefSlotCell` → `varRefValue()`；`uninitialized` → null。cell 值不再套 cell（direct-eval const 视图 pvalue-alias 目标）。
- **所有权 / 错误 / 调用**：返回值借自 cell，调用方必须 `push`（dup 语义由 Stack.push 处理）而不能当 owned 释放。`tryFastDirectVarRefGet` 使用。

### `fastInstalledGlobalDataValueForAtomAtPc` (`src/exec/vm_property.zig:80`)

- **签名**：`pub fn fastInstalledGlobalDataValueForAtomAtPc( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, site_pc: usize, atom_id: core.Atom, ) ?core.JSValue`。
- **作用**：已安装全局数据属性的 IC 快读，服务 `op.get_var` / `op.get_var_undef`。
- **实现**：`canUseInstalledGlobalDataIc` 失败、帧绑定遮蔽全局、或存在 global lexical → null。否则 `globalDataPropertyValueForFastPath`。
- **所有权 / 错误 / 调用**：borrowed/owned 由 property_direct 约定。无抛错。`getVar` 热腿。

### `hasObjectBinding` (`src/exec/vm_property.zig:96`)

- **签名**：`pub fn hasObjectBinding( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, atom_id: core.Atom, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !bool`。
- **作用**：`[[HasProperty]]` 适配，给 get/put_var 与 with 探测。
- **实现**：直接 `object_ops.hasValueProperty`。
- **所有权 / 错误 / 调用**：可再入（Proxy has trap）。错误上抛。

### `canUseFastGlobalVarLookup` (`src/exec/vm_property.zig:109`)

- **签名**：`pub fn canUseFastGlobalVarLookup( function: *const bytecode.FunctionBytecode, atom_id: core.Atom, frame: *const frame_mod.Frame, ) bool`。
- **作用**：`op.get_var` 能否走全局数据快路径的名字门。
- **实现**：`undefined` / `arguments` atom 拒绝；`frameHasVarRefBinding` 拒绝。
- **所有权 / 错误 / 调用**：无。`getVar` 使用。

### `canUseInstalledGlobalDataIc` (`src/exec/vm_property.zig:119`)

- **签名**：`pub fn canUseInstalledGlobalDataIc( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, atom_id: core.Atom, frame: *const frame_mod.Frame, global: *const core.Object, ) bool`。
- **作用**：比 lookup 门更严：还要排除 `ctx.lexicals` 自有绑定。
- **实现**：同样排除 undefined/arguments 与 var-ref 名；`ctx.lexicals.hasOwnProperty(atom_id)` 则 false。`global` 参数未用（保留签名）。
- **所有权 / 错误 / 调用**：无。IC 安装/命中前。

### `functionFrameBindingShadowsGlobal` (`src/exec/vm_property.zig:135`)

- **签名**：`pub fn functionFrameBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool`。
- **作用**：函数名、动态作用域、或局部/参数是否遮蔽该全局名。
- **实现**：函数名相等；或 `functionHasDynamicScopeBindings`；或 `functionLocalOrArgBindingShadowsGlobal`。
- **所有权 / 错误 / 调用**：`getVar`/`putVar` 快路径守卫。

### `functionHasDynamicScopeBindings` (`src/exec/vm_property.zig:142`)

- **签名**：`fn functionHasDynamicScopeBindings(function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame) bool`。
- **作用**：有 var-ref 名表或活着的 `frame.var_refs` 即视为动态作用域。
- **实现**：非 legacy 且 `frame.var_refs` 非空时才 assert `var_refs.len == closureVar().len`。返回 `varRefNamesLen()!=0 or var_refs.len!=0`。
- **所有权 / 错误 / 调用**：纯读 `*const` 借用的 function/frame，不分配、不建根、无 error set；Debug 下的 `assert` 是不变量检查，不构成错误路径。文件私有，唯一调用方 `functionFrameBindingShadowsGlobal`（`src/exec/vm_property.zig:137`），后者再服务全局属性快路径 `src/exec/vm_property.zig:89` 与 `src/exec/vm_property_globals.zig:380`。返回 true 表示「放弃全局快路径」，是保守方向。

### `functionLocalOrArgBindingShadowsGlobal` (`src/exec/vm_property.zig:149`)

- **签名**：`fn functionLocalOrArgBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool`。
- **作用**：参数/局部 var_name 是否等于 atom。
- **实现**：遍历 `argVarDefs` 与 `varDefs` 的 min(len, 帧切片)，`atomIdOrNameEql`。
- **所有权 / 错误 / 调用**：只读借用的 vardef 表与帧切片，不分配、无 error set；`atomIdOrNameEql` 在 atom 未 intern 时退化成按名字比，也不分配。用 `@min(defs.len, frame.…len)` 截断而不是断言相等，因此帧比声明短时尾部声明不参与遮蔽判断——这是保守的**漏判**方向（可能误走全局快路径），与上一个谓词的保守方向相反。文件私有，唯一调用方 `src/exec/vm_property.zig:138`。

### `canFuseGlobalDataWrite` (`src/exec/vm_property.zig:161`)

- **签名**：`pub fn canFuseGlobalDataWrite( function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom, ) bool`。
- **作用**：`op.put_var` 能否融合写全局数据槽。
- **实现**：排除 undefined/arguments；排除帧 var-ref 同名。
- **所有权 / 错误 / 调用**：`canUseFastGlobalVarWrite` 使用。

### `frameHasVarRefBinding` (`src/exec/vm_property.zig:171`)

- **签名**：`pub fn frameHasVarRefBinding(function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool`。
- **作用**：当前帧 var-ref 名表是否包含该 atom。
- **实现**：`min(var_refs.len, varRefNamesLen())` 线性扫。
- **所有权 / 错误 / 调用**：多个全局快路径门。

### `fastDenseArrayElementValue` (`src/exec/vm_property.zig:181`)

- **签名**：`pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue`。
- **作用**：服务 `op.get_array_el` 族：密数组 / 未映射 arguments 的 int 下标快读（quickjs.c:9047 旁路）。
- **实现**：key 非负 int32；trusted object；`fastArrayElementDup(index)`。映射 arguments 的 var-ref 单元**不**走这里。
- **所有权 / 错误 / 调用**：返回 owned dup。miss → null。`vm_property_field` re-export。无抛错。

### `fastMappedArgumentsElementValue` (`src/exec/vm_property.zig:201`)

- **签名**：`pub noinline fn fastMappedArgumentsElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue`。
- **作用**：服务 `op.get_array_el`：映射 arguments 的 cell 解引用读（qjs `JS_CLASS_MAPPED_ARGUMENTS` 臂）。
- **实现**：非负 int32；`mappedArgumentsElementDup`。故意不并进密数组读者（六个调用方，并进去会拖累从不读元素的纯调用基准）。
- **所有权 / 错误 / 调用**：owned dup。仅 get_array_el 冷/热 handler。

### `fastArrayOwnIntElementValue` (`src/exec/vm_property.zig:221`)

- **签名**：`pub fn fastArrayOwnIntElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue`。
- **作用**：稀疏/慢数组的自有整数元素读（密路径 miss 之后）。qjs 把 `idx >= count` 转到 int-atom `JS_GetPropertyInternal`。
- **实现**：非负 int32；`isArray()`；`getOwnDataPropertyValue(atomFromUInt32)`。洞/访问器/仅原型 → null。
- **所有权 / 错误 / 调用**：data 值的约定与 getOwn 相同。`isArray` 门避免映射 arguments。

### `fastArrayOwnIntElementSet` (`src/exec/vm_property.zig:241`)

- **签名**：`pub fn fastArrayOwnIntElementSet(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue, new_value: core.JSValue) !bool`。
- **作用**：稀疏数组自有可写数据元素覆盖，服务 `op.put_array_el`。
- **实现**：同样的 int/array 门；`setOwnWritableDataProperty`。缺失/不可写/访问器/module_ns → false，走完整 Set。
- **所有权 / 错误 / 调用**：`new_value` **borrowed**；helper 在槽内 dup。调用方释放自己的操作数引用。可能 OOM。

### `readInt` (`src/exec/vm_property.zig:251`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：`decodeFieldAtom` 读 u32 atom。
- **实现**：小端 `std.mem.readInt`。
- **所有权 / 错误 / 调用**：纯读借用的字节码切片，不分配、无 error set，定长由调用点 `[0..4]` 保证。文件私有，树内唯一调用点是 `src/exec/vm_property.zig:57` 的 `decodeFieldAtom`。

## 覆盖核对

- 清单函数数: 17
- 本文标题覆盖: 17
- 未覆盖: 无
