# 12 — 私有字段（`vm_property_private.zig`）

文件职责：`op.get_private_field` / `op.put_private_field` / `op.define_private_field`。键必须是私有 symbol atom；接收者必须是对象。错误对象的 realm 取自当前函数对象，否则退回调用方 `global`。

`Step` 从 `vm_property` re-export。

### `privateFieldAtom` (`src/exec/vm_property_private.zig:16`)

- **签名**：`fn privateFieldAtom( ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, receiver: core.JSValue, key: core.JSValue, ) !core.Atom`。
- **作用**：把栈上的 receiver/key 收成私有字段 atom，供三条私有 opcode 共用。
- **实现**：`error_global` = 当前函数的 realm global，否则传入的 global。`receiver` 非对象 → TypeError `"not an object"` 后 `unreachable`（throw 已挂 pending）。`key.asSymbolAtom()` 成功则返回；否则 TypeError `"not a symbol"`。
- **所有权 / 错误 / 调用**：不消费 JSValue 所有权（调用方已 pop）。`throwTypeErrorMessage` 挂异常后本函数标 `!Atom` 但实际 `unreachable`。三条公开 handler 调用。

### `getPrivateField` (`src/exec/vm_property_private.zig:36`)

- **签名**：`pub fn getPrivateField( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.get_private_field`：读 `obj[privateKey]`。
- **实现**：pop key，pop obj，`privateFieldAtom`，`object_ops.getValueProperty`，`pushOwned`。
- **所有权 / 错误 / 调用**：key/obj 在 get 中借出；结果 owned。缺失私有字段由 getValueProperty 变成 TypeError。`getPrivateFieldVm` 包装。

### `getPrivateFieldVm` (`src/exec/vm_property_private.zig:51`)

- **签名**：`pub noinline fn getPrivateFieldVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.get_private_field` 的 catch 包装。
- **实现**：`getPrivateField` catch → `handleCatchableRuntimeError` → `.continue_loop` / 上抛；成功 `.done`。
- **所有权 / 错误 / 调用**：分发冷路径入口。

### `putPrivateField` (`src/exec/vm_property_private.zig:67`)

- **签名**：`pub fn putPrivateField( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.put_private_field`：写已存在的私有字段。
- **实现**：pop key，pop value，pop obj；atom 后 `setValueProperty`。不压返回值（赋值表达式的值已在更早的 dup/set 惯例里处理，本 opcode 是纯存储）。
- **所有权 / 错误 / 调用**：value 交给 setter。未定义字段 / 非对象走 TypeError。`putPrivateFieldVm` 包装。

### `putPrivateFieldVm` (`src/exec/vm_property_private.zig:82`)

- **签名**：`pub noinline fn putPrivateFieldVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.put_private_field` 的 catch 包装。
- **实现**：同 get 包装模式。
- **所有权 / 错误 / 调用**：分发冷路径。

### `definePrivateField` (`src/exec/vm_property_private.zig:98`)

- **签名**：`pub fn definePrivateField( ctx: *core.JSContext, _: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, _: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.define_private_field`：在类实例上**新定义**私有数据字段（构造/实例字段初始化）。
- **实现**：pop value，pop key，**peek** obj（对象留在栈上当 receiver）。atom 后 `expectObject`，`defineClassFieldDataProperty`。
- **所有权 / 错误 / 调用**：value 写入字段；obj 仍在栈顶。重复定义由 define 路径 TypeError。`definePrivateFieldVm` 包装。

### `definePrivateFieldVm` (`src/exec/vm_property_private.zig:114`)

- **签名**：`pub noinline fn definePrivateFieldVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.define_private_field` 的 catch 包装。
- **实现**：同前。
- **所有权 / 错误 / 调用**：分发冷路径。

## 覆盖核对

- 清单函数数: 7
- 本文标题覆盖: 7
- 未覆盖: 无
