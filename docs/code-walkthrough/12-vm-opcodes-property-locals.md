# 12 — 局部 / 参数 / var-ref 槽（`vm_property_locals.zig`）

文件职责：`op.get/put/set_loc*`、`op.get/put/set_arg*`、`op.get/put/set_var_ref*`、TDZ 检查形、`op.close_loc`。真正的槽读写在 `slot_ops`；本文件按 opcode 选索引宽度并处理 TDZ。

### `loc` (`src/exec/vm_property_locals.zig:20`)

- **签名**：`pub noinline fn loc( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, opc: u8, ) !void`。
- **作用**：服务 `get/put/set_loc`、`*_loc8`、`*_loc0`–`*_loc3`。
- **实现**：按 opc 读 u16 / u8 / 隐含索引，转 `slot_ops.execGetLoc` / `execPutLoc` / `execSetLoc`（consume 字节数 2/1/0）。get 走 ctx（可能 TDZ 以外的适配）；put/set 只改槽。
- **所有权 / 错误 / 调用**：`InvalidBytecode` 在 slot_ops。热路径对 loc0/loc8 常内联；本函数是冷总开关。

### `arg` (`src/exec/vm_property_locals.zig:66`)

- **签名**：`pub noinline fn arg( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, opc: u8, ) !void`。
- **作用**：服务 `get/put/set_arg` 与 `*_arg0`–`*_arg3`。
- **实现**：同 loc，转 `execGetArg` / `execPutArg` / `execSetArg`。
- **所有权 / 错误 / 调用**：参数槽可能 alias 映射 arguments。冷路径。

### `checkedLocVm` (`src/exec/vm_property_locals.zig:93`)

- **签名**：`pub noinline fn checkedLocVm( ctx: *core.JSContext, output: ?*std.Io.Writer, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, stack: *stack_mod.Stack, opc: u8, catch_target: *?usize, ) !Step`。
- **作用**：服务带 TDZ/派生 this 检查的 loc opcode：`set_loc_uninitialized`、`get_loc_check`、`get_loc_checkthis`、`put_loc_check`、`set_loc_check`、`put_loc_check_init`。
- **实现**：读 u16 idx，`pc += 2`，越界 `InvalidBytecode`。
  - `set_loc_uninitialized`：`closeLocalBinding` 拆开旧 cell，槽写成 uninitialized（新词法绑定实例）。
  - `get_loc_check`：uninit → 若是派生构造器的 `this` 绑定则 `"this is not initialized"`，否则 TDZ ReferenceError；否则 push 槽。
  - `get_loc_checkthis`：uninit → `DerivedThisUninitialized`（故意不在本 realm 造对象，qjs 在 caller_ctx 造）；否则 push。
  - `put_loc_check`：uninit → TDZ；先 pop 值，再查 `varDefs()[idx].isConst()`，是则 TypeError（值已离栈），否则写入槽。
  - `set_loc_check`：uninit → TDZ；peek 写入（栈顶留下）。
  - `put_loc_check_init`：仅派生 `this` 禁止二次初始化（`"'this' can be initialized only once"`）；其它词法 init 允许覆盖。pop 写入。
- **所有权 / 错误 / 调用**：错误经 handleCatchable。分发冷路径。

### `varRef` (`src/exec/vm_property_locals.zig:184`)

- **签名**：`pub fn varRef( ctx: *core.JSContext, output: ?*std.Io.Writer, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, stack: *stack_mod.Stack, opc: u8, catch_target: *?usize, ) !Step`。
- **作用**：服务 `get/put/set_var_ref*`、`*_check`、`put_var_ref_check_init` 及 0–3 短形。
- **实现**：get 族先 `tryFastDirectVarRefGet`；失败则 `execGetVarRefMaybeTdz`（true 表示 catch 已处理 → `.continue_loop`）。put/set 走 `execPutVarRef` / `execSetVarRef`。pc 不足 → `TypeError`（与历史解码一致）。
- **所有权 / 错误 / 调用**：快路径 push borrowed cell 值。TDZ 经 slot_ops。`varRefVm` 再包一层。

### `varRefVm` (`src/exec/vm_property_locals.zig:240`)

- **签名**：`pub noinline fn varRefVm( ctx: *core.JSContext, output: ?*std.Io.Writer, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, stack: *stack_mod.Stack, opc: u8, catch_target: *?usize, ) !Step`。
- **作用**：`varRef` 的 catch 包装（put 路径可能 TypeError/TDZ）。
- **实现**：`varRef catch handleCatchable`。
- **所有权 / 错误 / 调用**：分发对 get_var_ref0 等冷入口。

### `tryFastDirectVarRefGet` (`src/exec/vm_property_locals.zig:256`)

- **签名**：`fn tryFastDirectVarRefGet(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool`。
- **作用**：非词法全局哨兵且 cell 可读时，直接 push 并前进 pc。
- **实现**：`closureVarIsNonLexicalGlobalSentinel` → false。`varRefReadableBorrowed` 失败 → false。否则 `pc += consume`，`stack.push(value)`，true。
- **所有权 / 错误 / 调用**：push 是 dup 语义。`varRef` 各 get 臂。

### `closeLoc` (`src/exec/vm_property_locals.zig:264`)

- **签名**：`pub noinline fn closeLoc( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.close_loc`：关闭局部绑定（块结束，cell 与槽脱钩）。
- **实现**：读 u16 idx，`pc += 2`，`frame.closeLocalBinding`。
- **所有权 / 错误 / 调用**：cell 变成闭包拥有。可能 OOM（关绑定时分配）。无栈。

## 覆盖核对

- 清单函数数: 7
- 本文标题覆盖: 7
- 未覆盖: 无
