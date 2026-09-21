# 14g — `slot_ops.zig`：帧局部、参数、var-ref 槽

[`src/exec/property_ops.zig`](../../src/exec/property_ops.zig) 给 VM 与 call runtime 共用：`get/put/set_loc`、`get/put/set_arg`、`get/put/set_var_ref`，以及 `VarRef` 单元格的边界视图。槽类型已翻成「每个 `frame.var_refs[i]` 都是活 cell」（对照 qjs `JSVarRef **var_refs`）。

`execPutLoc` / `replaceAdapterRefCounted` 的 `noinline` 属性已计入当前清单。

别名：`ensureVarRefsCapacity`、`globalLexicalValueForGlobal`、`handleCatchableRuntimeError`、`throwTdzReferenceError`、`throwTypeErrorMessage`。

---

### `execGetLoc` (`src/exec/property_ops.zig:26`)

- **签名**：`pub fn execGetLoc( _: *core.JSContext, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：`get_loc` / `get_loc8` / `get_loc0..3` 共用：把 local 推进操作数栈。
- **实现**：`frame.pc += consume`。无运行时越界：`resolve_variables` 只发 `idx < var_count`，`frame.locals` 正好这么长（与 qjs 裸 `var_buf[idx]` 相同的信任编译器模型）。`pushOwnedAssumeCapacity` 跳过 `reserveAdditional`，镜像 `*sp++`。忽略 `opc`。
- **所有权 / 错误 / 调用**：owned 推栈。栈已在 `reserveEntryFrameCapacity` 预留。

### `execPutLoc` (`src/exec/property_ops.zig:45`)

- **签名**：`pub noinline fn execPutLoc( frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：弹出栈顶写入 local（消费型 put）。
- **实现**：`pc += consume`；`stack.pop()` 进 `frame.locals[idx]`。
- **所有权 / 错误 / 调用**：弹出的值所有权交给槽。`noinline` 让 put 不占 get 热 I-cache。该函数已纳入清单。

### `execSetLoc` (`src/exec/property_ops.zig:59`)

- **签名**：`pub fn execSetLoc( frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：把栈顶 **借** 进 local，操作数留在栈上。
- **实现**：`peekBorrowed()` 失败 → `error.StackUnderflow`。槽取恰好一份保留引用。
- **所有权 / 错误 / 调用**：非消费。与 `set_arg` 同一所有权契约。

### `execGetArg` (`src/exec/property_ops.zig:75`)

- **签名**：`pub fn execGetArg( _: *core.JSContext, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：读参数；越界得到 `undefined`。
- **实现**：`idx >= frame.args.len` → `pushOwned(undefined)`。否则把 `frame.args[idx]` owned 推栈。
- **所有权 / 错误 / 调用**：与 loc 不同：参数窗口可能短于访问下标（缺省参数 / 实际 argc）。

### `execPutArg` (`src/exec/property_ops.zig:93`)

- **签名**：`pub fn execPutArg( frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：弹出栈顶写入参数槽。
- **实现**：越界 → `error.InvalidBytecode`。否则 pop 进 `frame.args[idx]`。
- **所有权 / 错误 / 调用**：编译器不应发出越界 put_arg。

### `execSetArg` (`src/exec/property_ops.zig:107`)

- **签名**：`pub fn execSetArg( frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：非消费写参数。
- **实现**：越界 InvalidBytecode；`peekBorrowed` 失败 StackUnderflow。
- **所有权 / 错误 / 调用**：同 `execSetLoc`。

### `execGetVarRefMaybeTdz` (`src/exec/property_ops.zig:122`)

- **签名**：`pub fn execGetVarRefMaybeTdz( ctx: *core.JSContext, output: ?*std.Io.Writer, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, catch_target: *?usize, global: *core.Object, ) !bool`。
- **作用**：`get_var_ref` / check：读闭包 cell，处理全局词法、非词法全局哨兵、TDZ、已删 eval 绑定。
- **实现**：
  1. `pc += consume`；`idx >= var_refs.len` 则 `ensureVarRefsCapacity`。
  2. 若有 var-ref 名且 **真是** `global_decl`（qjs `JS_CLOSURE_GLOBAL_DECL`）：`globalLexicalValueForGlobal`；未初始化 → TDZ，可 catch 则返回 `true`。
  3. 同名的 `.ref`/`.local` **不得** 走这条，否则外层 `let` 会盖住捕获的 per-iteration TDZ 槽。
  4. `closureVarIsNonLexicalGlobalSentinel` → `global.getProperty(atom_id)`。
  5. 否则 `varRefSlotCell` → `varRefValue()`。未初始化：可删 cell → 普通 `ReferenceError`（qjs `remove_global_object_property` 停在 UNINITIALIZED）；名字是 `this_` → `"this is not initialized"`（派生类 `this`，仍在 callee realm 可 catch）；否则 TDZ。
  6. 正常值 `stack.push`。返回 `false` 表示未转入 catch。
- **所有权 / 错误 / 调用**：对照 `OP_get_var_ref_check`（`quickjs.c:18630`）。`true` = 已处理 catch 并改 pc。

### `execPutVarRef` (`src/exec/property_ops.zig:192`)

- **签名**：`pub fn execPutVarRef( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：弹出栈顶写入 var-ref cell；区分 init/check、const、function name。
- **实现**：扩容；pop。`put_var_ref_check_init`：当前 **不是** uninitialized → `"this is not initialized"`。`put_var_ref_check`：uninitialized → TDZ。function-name 槽：严格模式 TypeError，非严格吞写。const 且非 init opcode → `"invalid assignment to const variable"`。写入前若 `value` 本身是 cell，先 `adapterValueBorrow` 解开，禁止 cell 嵌套。`cell.setVarRefValue`。
- **所有权 / 错误 / 调用**：对照 `OP_put_var_ref`（`quickjs.c:18638`）。raw-slot 臂已随类型翻转删除。

### `isVarRefInitOpcode` (`src/exec/property_ops.zig:242`)

- **签名**：`pub fn isVarRefInitOpcode(opc: u8) bool`。
- **作用**：该 opcode 是否允许对 const cell 做初始化写。
- **实现**：`put_var_ref`、`put_var_ref_check_init`、`put_var_ref0..3`。
- **所有权 / 错误 / 调用**：给 `constVarRefWriteAllowed`。

### `constVarRefWriteAllowed` (`src/exec/property_ops.zig:251`)

- **签名**：`pub fn constVarRefWriteAllowed(cell: *core.VarRef, opc: u8) bool`。
- **作用**：const 槽这次写是否合法。
- **实现**：忽略 `cell`，只看 `isVarRefInitOpcode(opc)`。
- **所有权 / 错误 / 调用**：初始化允许，之后的赋值不允许。

### `execSetVarRef` (`src/exec/property_ops.zig:256`)

- **签名**：`pub fn execSetVarRef( ctx: *core.JSContext, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8, opc: u8, ) !void`。
- **作用**：非消费写 var-ref（栈顶留下）。
- **实现**：扩容；`stack.peek()`；`replaceVarRefValueOwned`。忽略 `opc`。
- **所有权 / 错误 / 调用**：StackUnderflow。不在这里做 TDZ/const 检查（由对应 check opcode 做）。

### `adapterValueBorrow` (`src/exec/property_ops.zig:271`)

- **签名**：`pub fn adapterValueBorrow(slot: core.JSValue) callconv(.c) core.JSValue`。
- **作用**：若槽是 cell，解一层得到纯值；否则原样返回。
- **实现**：`varRefCellFromValue` 失败则返回 `slot`。Debug 断言内层值不再是 cell。direct-eval const view 现已 pvalue-alias 目标，一次 unwrap 即可（qjs `*var_ref->pvalue`，`quickjs.c:18627`）。
- **所有权 / 错误 / 调用**：borrowed。`callconv(.c)` 给边界。

### `adapterValueIsUninitialized` (`src/exec/property_ops.zig:284`)

- **签名**：`pub fn adapterValueIsUninitialized(slot: core.JSValue) bool`。
- **作用**：解 cell 后是否仍是 uninitialized。
- **实现**：`adapterValueBorrow(slot).is(.uninitialized)`。
- **所有权 / 错误 / 调用**：`getSuperValue` 用它测派生 `this` TDZ。

### `adapterIsDeletedEvalBinding` (`src/exec/property_ops.zig:292`)

- **签名**：`pub fn adapterIsDeletedEvalBinding(slot: core.JSValue) bool`。
- **作用**：识别「可删 eval 绑定已被删」：deletable cell 停在 UNINITIALIZED，不是 TDZ。
- **实现**：不是 cell → 假；`varRefIsDeletableSlot` 为假 → 假；再看值是否 uninitialized。对照 `quickjs.c:9289-9309`。
- **所有权 / 错误 / 调用**：TDZ cell 不可删，不会被误判。

### `replaceAdapterOwned` (`src/exec/property_ops.zig:301`)

- **签名**：`pub inline fn replaceAdapterOwned(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void`。
- **作用**：替换 Adapter 槽；两侧都可以是 VarRef 句柄，保持 write-through。禁止用于 frame locals/args。
- **实现**：两侧都不是 `isTracerOwned` 则直接赋值；否则 `replaceAdapterRefCounted`。
- **所有权 / 错误 / 调用**：冷边界。locals 有自己的 put/set。

### `replaceAdapterRefCounted` (`src/exec/property_ops.zig:309`)

- **签名**：`noinline fn replaceAdapterRefCounted(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void`。
- **作用**：`replaceAdapterOwned` 的堆值臂：解开入站 cell，写穿已有 cell 或替换裸槽。
- **实现**：入站是 cell → borrow。出站是 cell → `setVarRefValue`；否则 `slot.* = assigned`。
- **所有权 / 错误 / 调用**：该函数已纳入清单。

### `varRefCellFromValue` (`src/exec/property_ops.zig:321`)

- **签名**：`pub fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef`。
- **作用**：`JSValue` → `*VarRef`。
- **实现**：`core.VarRef.fromValue(value)`。
- **所有权 / 错误 / 调用**：所有 cell 边界的漏斗。

### `varRefSlotCell` (`src/exec/property_ops.zig:336`)

- **签名**：`pub inline fn varRefSlotCell(frame: *const frame_mod.Frame, idx: usize) *core.VarRef`。
- **作用**：`frame.var_refs[idx]` 的唯一元素读漏斗。
- **实现**：直接下标。类型保证是活 cell（phase D，对照 `quickjs.c:17277` / `17844`）。
- **所有权 / 错误 / 调用**：调用方保证 idx 合法或已 `ensureVarRefsCapacity`。

### `varRefSlot` (`src/exec/property_ops.zig:342`)

- **签名**：`pub inline fn varRefSlot(frame: *const frame_mod.Frame, idx: usize) core.JSValue`。
- **作用**：槽的 JSValue 视图（cell 的 value view，不是再 chase）。
- **实现**：`frame.var_refs[idx].valueRef()`。borrowed，需要所有权时 dup。
- **所有权 / 错误 / 调用**：给 eval 名表、属性 cell 等 JSValue 域。

### `storeVarRefSlot` (`src/exec/property_ops.zig:352`)

- **签名**：`pub inline fn storeVarRefSlot(frame: *frame_mod.Frame, idx: usize, slot: core.JSValue) void`。
- **作用**：槽 **重绑**（换 cell），不是 write-through。
- **实现**：`varRefCellFromValue(slot) orelse unreachable`。调用方负责两边 refcount。
- **所有权 / 错误 / 调用**：仅全局-decl PASS2 手术与 module prologue fill。

### `replaceVarRefValueOwned` (`src/exec/property_ops.zig:360`)

- **签名**：`pub inline fn replaceVarRefValueOwned(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, value: core.JSValue) void`。
- **作用**：write-through 写入 cell 的值（`set_value(var_refs[idx]->pvalue)`）。
- **实现**：入站 cell 先 unwrap，再 `setVarRefValue`。
- **所有权 / 错误 / 调用**：`execSetVarRef` 与 Adapter 替换共用解嵌套规则。

## 覆盖核对

- 清单函数数: 21
- 本文标题覆盖: 21
- 未覆盖: 无
