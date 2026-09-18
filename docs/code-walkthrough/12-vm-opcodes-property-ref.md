# 12 — with / 引用 opcode（`vm_property_ref.zig`）

文件职责：`op.dyn_env_probe`（合并旧 with_*/eval 变量对象族）、`make_loc_ref`/`make_arg_ref`/`make_var_ref_ref`/`make_var_ref`、`get_ref_value`/`put_ref_value`、`delete`/`delete_var`。

### `dynEnvProbe` (`src/exec/vm_property_ref.zig:29`)

- **签名**：`pub noinline fn dynEnvProbe( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.dyn_env_probe`：测栈顶对象是否提供操作数 atom 的绑定，若有则执行 flags 指定的操作并跳到标签。
- **实现**：`dyn_env.decode(code[pc+8])` 失败 → `InvalidBytecode`。`.put` → `dynEnvProbeStore`；其余 → `dynEnvProbeAccess`。
- **所有权 / 错误 / 调用**：9 字节指令（atom u32 + diff i32 + flags）。分发冷路径。

### `dynEnvProbeAccess` (`src/exec/vm_property_ref.zig:46`)

- **签名**：`fn dynEnvProbeAccess( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, flags: bytecode.opcode.dyn_env.Flags, ) !Step`。
- **作用**：probe 的读/删/make_ref/get_ref 臂。
- **实现**：读 atom、diff，`pc += 9`。peek 对象；非对象则 pop 并 `.continue_loop`（试下一层 env）。`hasPropertyForWith`；with 且有绑定则查 `@@unscopables`。无绑定或被挡：pop，`.continue_loop`。read/get_ref 再 has 一次（严格 read 且消失 → ReferenceError）。然后：
  - `.read`：get 或 undefined，pop 对象，push 值，跳转。
  - `.delete`：非 with 时若自有可删 VARREF，记下 cell；`deleteProperty`；成功则 cell 置 uninitialized。严格模式删失败 → TypeError。push bool，跳转。
  - `.get_ref`：push 值但**留**对象（引用对），跳转。
  - `.make_ref`：push atom 的字符串键（对象已在栈上），跳转。
  - `.put`：unreachable（走 store）。
  跳转：`pc = operand_pc+4 + diff`（相对 diff 操作数位置）。
- **所有权 / 错误 / 调用**：可再入 has/get/unscopables。catch 经 handleCatchable。

### `makeSlotRef` (`src/exec/vm_property_ref.zig:149`)

- **签名**：`pub noinline fn makeSlotRef( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8, ) !void`。
- **作用**：服务 `op.make_loc_ref` / `make_arg_ref` / `make_var_ref_ref`：把槽收成 `[cell, key]` 引用对。
- **实现**：atom u32 + idx u16，`pc += 6`。loc → `captureLocal`；arg → `captureArg`；var_ref → `ensureVarRefsCapacity` 后取 `var_refs[idx]`。push cell 的 `valueRef()`，再 push atom 字符串。
- **所有权 / 错误 / 调用**：cell 引用 owned 在栈上。`InvalidBytecode` 越界。

### `makeVarRef` (`src/exec/vm_property_ref.zig:181`)

- **签名**：`pub fn makeVarRef( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.make_var_ref`：全局标识符引用（qjs `JS_GetGlobalVarRef`）。
- **实现**：读 atom，`pc += 4`。先查 `existingGlobalLexicalEnv`：未删条目若 TDZ → `throwTdzReferenceError`；只读 → TypeError const；否则对象侧是 env。否则 `hasObjectBinding` 于 global，没有则对象侧是 `undefined`（解析失败的引用）。push 对象 + atom 字符串。
- **所有权 / 错误 / 调用**：TDZ/const 在**造引用时**就检查。`makeVarRefVm` 包装。

### `makeVarRefVm` (`src/exec/vm_property_ref.zig:222`)

- **签名**：`pub noinline fn makeVarRefVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.make_var_ref` 的 catch 包装。
- **实现**：标准 *Vm 模式。
- **所有权 / 错误 / 调用**：分发。

### `getRefValue` (`src/exec/vm_property_ref.zig:238`)

- **签名**：`pub fn getRefValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.get_ref_value`：读 `[obj, key]` 引用，**留下**引用对并再 push 值。
- **实现**：需要 ≥2 槽。obj 是 undefined：先 ToPropertyKey(key) 再 `throwReferenceErrorNotDefined`（qjs 19499，先解析 atom）。obj 是 cell：borrow 值，uninit → ReferenceError，push。否则 ToPropertyKey，has 失败：严格 → ReferenceError，松散 push undefined。否则 getValueProperty。
- **所有权 / 错误 / 调用**：不 pop 引用对。`getRefValueVm`。

### `getRefValueVm` (`src/exec/vm_property_ref.zig:277`)

- **签名**：`pub noinline fn getRefValueVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.get_ref_value` 的 opcode 入口，把 `getRefValue` 的 ReferenceError / TypeError 等可捕获错误转成本帧 catch 跳转。
- **实现**：`getRefValue(ctx, output, global, stack, function, frame) catch |err|` → `call_runtime.handleCatchableRuntimeError`：返回 true 则 `.continue_loop`（栈已截到 catch marker、异常已压栈、`frame.pc` 指向 handler），false 则上抛；正常返回 `.done`。需要兜的错误包括 undefined base 的 not-defined ReferenceError、TDZ cell 的 `error.ReferenceError`、ToPropertyKey/getter 再入 JS 抛出的待决异常，以及栈不足的 `error.StackUnderflow`（后者不在运行时错误表中，会直接上抛）。
- **所有权 / 错误 / 调用**：本函数不碰栈；`getRefValue` 只 push 不 pop（引用对留在栈上给后续 `put_ref_value`）。唯一调用点是冷表 `t[op.get_ref_value]`（`tailcall_dispatch_colds.zig:412`），`h(...)` 丢弃 `Step`，冷路径统一在 `frame.pc` 处重新分发。

### `putRefValue` (`src/exec/vm_property_ref.zig:293`)

- **签名**：`pub fn putRefValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.put_ref_value`：写引用并拆掉三槽 `[obj, key, value]`。
- **实现**：pop value, key, obj。obj undefined：严格 → 先 key atom 再 not-defined；松散则 obj=global。cell：function-name 槽松散忽略、严格 TypeError const；const 槽 TypeError；否则 `replaceAdapterOwned`。否则 ToPropertyKey，严格且无绑定 → ReferenceError；`setValueProperty`。
- **所有权 / 错误 / 调用**：value 写入目标。`putRefValueVm`。

### `putRefValueVm` (`src/exec/vm_property_ref.zig:342`)

- **签名**：`pub noinline fn putRefValueVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.put_ref_value` 的 opcode 入口，把 `putRefValue` 的赋值错误转成本帧 catch 跳转。
- **实现**：`putRefValue(ctx, output, global, stack, function, frame) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。典型错误面是严格模式下的 not-defined ReferenceError、const / function-name 槽的 `"invalid assignment to const variable"` TypeError，以及 setter 再入 JS 抛出的待决异常。
- **所有权 / 错误 / 调用**：`putRefValue` 已在进入分支前 pop 掉三槽 `[obj, key, value]`，所以出错时这三个值的所有权已经不在栈上；catch 缝只负责把栈截回 marker，本包装不做额外释放。唯一调用点是冷表 `t[op.put_ref_value]`（`tailcall_dispatch_colds.zig:417`），`Step` 同样被丢弃。

### `dynEnvProbeStore` (`src/exec/vm_property_ref.zig:358`)

- **签名**：`fn dynEnvProbeStore( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, is_with: bool, ) !Step`。
- **作用**：`dyn_env_probe` 的 put 臂。
- **实现**：读 atom/diff，`pc += 9`。pop obj；undefined → `.continue_loop`。has + 可选 unscopables；失败 continue。再 has：严格且消失 → ReferenceError。pop value，`setValueProperty`，跳转。
- **所有权 / 错误 / 调用**：obj 已 pop（与 access 臂不同）。value 写入。

### `deleteVar` (`src/exec/vm_property_ref.zig:408`)

- **签名**：`pub noinline fn deleteVar( ctx: *core.JSContext, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.delete_var`（qjs `JS_DeleteGlobalVar`）。
- **实现**：读 atom，`pc += 4`。声明式全局（lexical has）不可删 → false。对象环境有属性则 `deleteProperty`；没有当成功 true。push bool。
- **所有权 / 错误 / 调用**：删成功会把捕获的 VARREF 停在 uninitialized（在 Object.deleteProperty 内）。无 catch 包装（不抛用户可见错，除 OOM）。

### `deletePropertyVm` (`src/exec/vm_property_ref.zig:429`)

- **签名**：`pub noinline fn deletePropertyVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.delete`（`delete obj[key]`）。
- **实现**：pop prop, obj。**先** `toPropertyKeyAtom`（qjs 16072，key 副作用在 base 检查前）。null/undefined 基 → TypeError。非对象基 → `primitiveObjectForAccess` 包装后再删（字符串 exotic 的下标/length 报 false，严格抛）。Proxy 走 `deleteValueProperty`；数组 `length` 不可删；typed array 走 `typedArrayCanonicalDelete`；否则 `deleteProperty`。失败且严格 → TypeError。push bool。
- **所有权 / 错误 / 调用**：分发冷路径。

## 覆盖核对

- 清单函数数: 12
- 本文标题覆盖: 12
- 未覆盖: 无
