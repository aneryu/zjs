# 12 — 控制转移（`vm_control.zig`）

文件职责：`op.return` / `return_undef` / `goto*` / `if_true`/`if_false` / `throw` / `throw_error` / `catch` / `gosub` / `ret`。栈 pop 是所有权移动。已处理的 throw 安装或改道 pending exception。热分发在文件外，这里是聚焦 helper。

## 类型

`ThrowResult`：目前仅 `.handled`（catch 已接管）。

`ThrowError`：`SyntaxError` / `ReferenceError` / `TypeError`——只作 `throwError` 的返回 error set（无消息哨兵）。

### `returnTop` (`src/exec/vm_control.zig:31`)

- **签名**：`pub inline fn returnTop(ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue`。
- **作用**：服务 `op.return`：把栈顶当返回值移出（qjs `ret_val = *--sp`，quickjs.c:18266）。
- **实现**：若有 generator 对象则 `completeGeneratorExecution`。`liveValues()` 非空则 `setLen(len-1)` 取原顶，否则 `undefined`。`finishFunctionReturn`。
- **所有权 / 错误 / 调用**：返回值从栈**移走**，帧拆除不再碰它。`DerivedConstructorReturn` / `DerivedThisUninitialized` 可能从 finish 冒出。热 return handler 内联调用。

### `returnUndefined` (`src/exec/vm_control.zig:47`)

- **签名**：`pub inline fn returnUndefined(ctx: *core.JSContext, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue`。
- **作用**：服务 `op.return_undef` / 隐式 return。
- **实现**：同样 complete generator，然后 `finishFunctionReturn(..., undefined)`。
- **所有权 / 错误 / 调用**：不碰操作数栈。同 derived-ctor 错误。

### `finishFunctionReturn` (`src/exec/vm_control.zig:54`)

- **签名**：`pub inline fn finishFunctionReturn(_: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !core.JSValue`。
- **作用**：派生构造器返回约定：对象原样返回；非 undefined 非对象 → 错；undefined 则返回已初始化的 `this`。
- **实现**：非 derived class constructor → 原值。值是对象 → 原值。非 undefined → `DerivedConstructorReturn`。`this` 仍 uninitialized → `DerivedThisUninitialized`。否则借 `frame.this_value`（穿过 var-ref cell）。
- **所有权 / 错误 / 调用**：不 dup this。`ctx` 未用。两个 return helper 的热路径。

### `jump32` (`src/exec/vm_control.zig:62`)

- **签名**：`pub fn jump32(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void`。
- **作用**：服务 `op.goto`：相对 i32 跳转。
- **实现**：`operand_pc = frame.pc`，读 i32，`frame.pc = relativePc(operand_pc, diff)`。操作数偏移相对**操作数起点**（含 opcode 后的立即数位置，与 qjs 一致）。
- **所有权 / 错误 / 调用**：无。热路径常自己算目标；本函数是冷/共享形态。

### `jump16` (`src/exec/vm_control.zig:68`)

- **签名**：`pub fn jump16(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void`。
- **作用**：服务 `op.goto16`。
- **实现**：同 jump32，立即数 i16。
- **所有权 / 错误 / 调用**：只改 `frame.pc`：不碰栈、不分配、不建根、`void` 无 error set；`function` 是 `*const` 借用。位移相对**操作数字节**（`relativePc(operand_pc, diff)`），不是相对下一条指令。唯一调用方是冷表的 `op.goto16` 臂（`src/exec/tailcall_dispatch_colds.zig:355`），那里紧跟一次 `pollInterrupt`——中断轮询在调用方而不在本函数，热路径的对应实现是 `tailcall_dispatch.jump16Target`（`src/exec/tailcall_dispatch.zig:6254`）。

### `jump8` (`src/exec/vm_control.zig:74`)

- **签名**：`pub fn jump8(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void`。
- **作用**：服务 `op.goto8`。
- **实现**：一字节 i8 位移。
- **所有权 / 错误 / 调用**：同 `jump16`：只改 `frame.pc`，不分配、无 error set，位移相对操作数字节。唯一调用方是冷表 `op.goto8` 臂（`src/exec/tailcall_dispatch_colds.zig:361`），中断轮询由调用方补；热路径对应 `jump8Target`（`src/exec/tailcall_dispatch.zig:6232`）。

### `branch32` (`src/exec/vm_control.zig:80`)

- **签名**：`pub fn branch32(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void`。
- **作用**：服务 `op.if_true` / `op.if_false`（32 位位移）。
- **实现**：读 i32，`pc += 4`（先过操作数）。pop 值；bool 快路径否则 `isTruthy`。条件与 `branch_if_true` 相符则 `pc = relativePc(operand_pc, diff)`。
- **所有权 / 错误 / 调用**：pop 消费条件值。`StackUnderflow`。`ctx` 未用。`if_true` 传 true，`if_false` 传 false。

### `branch8` (`src/exec/vm_control.zig:91`)

- **签名**：`pub fn branch8(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void`。
- **作用**：服务 `op.if_true8` / `op.if_false8`。
- **实现**：同 branch32，1 字节位移，`pc += 1`。
- **所有权 / 错误 / 调用**：与 `branch32` 同一契约：`stack.pop()` 取走条件值（栈槽的所有权随之交出，本函数不再引用它），不分配、不建根。error set 只来自 `stack.pop()` 的下溢；`isTruthy` 不可失败、不跑用户代码，所以这条臂不会产生 JS 异常。`ctx` 参数被 `_` 忽略。调用方是冷表的两个臂 `op.if_false8` / `op.if_true8`（`src/exec/tailcall_dispatch_colds.zig:379`、`:385`），中断轮询同样在调用方。

### `throwTop` (`src/exec/vm_control.zig:102`)

- **签名**：`pub noinline fn throwTop( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, ) !ThrowResult`。
- **作用**：服务 `op.throw`：把栈顶变成异常，能 catch 则跳转。
- **实现**：pop value。`closeStackTopForOfIteratorForPendingError`（for-of 展开）。`reserveAdditional(1)`。若 `catch_target` 空，尝试 `popCatchMarker` 恢复。有 target：再 pop 一层 marker 作为新的外层 target，把 value 压回栈（catch 子句读它），`frame.pc = target`，返回 `.handled`。无 target：`ctx.throwValue` + `error.JSException`。
- **所有权 / 错误 / 调用**：value 要么进 catch 栈，要么进 pending exception。可能 `JSException`。分发 throw handler。

### `throwError` (`src/exec/vm_control.zig:129`)

- **签名**：`pub fn throwError(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) ThrowError`。
- **作用**：服务 `op.throw_error` 的**无消息**哨兵解码（给需要 typed error 但不造对象的路径）。
- **实现**：`error_type = code[pc+4]`，`pc += 5`。1→SyntaxError；2/3/5→ReferenceError；其余 TypeError。
- **所有权 / 错误 / 调用**：不造 Error 对象。当前树内无调用方：`op.throw_error` 一律走带消息的 `throwErrorVm`。

### `createAtomError` (`src/exec/vm_control.zig:139`)

- **签名**：`fn createAtomError( ctx: *core.JSContext, global: *core.Object, error_name: []const u8, atom_id: u32, prefix: []const u8, suffix: []const u8, ) !core.JSValue`。
- **作用**：拼 `prefix + atomName + suffix` 的命名 Error。
- **实现**：atom 名缺省 `"lexical variable"`。长度溢出 → OOM。`allocRuntime` 临时缓冲，`createNamedError`，defer free 缓冲。
- **所有权 / 错误 / 调用**：返回 owned Error 对象。OOM。仅 `createThrowErrorValue`。

### `createThrowErrorValue` (`src/exec/vm_control.zig:158`)

- **签名**：`fn createThrowErrorValue(ctx: *core.JSContext, global: *core.Object, atom_id: u32, error_type: u8) !core.JSValue`。
- **作用**：按 `op.throw_error` 的 type 字节造 Error 对象。
- **实现**：0 只读 `TypeError`；1 重声明 `SyntaxError`；2 TDZ `ReferenceError`；3 super 引用；4 iterator 无 throw；5 非法赋值目标；未知 → InternalError。
- **所有权 / 错误 / 调用**：owned。`throwErrorVm`。

### `deliverPendingThrow` (`src/exec/vm_control.zig:174`)

- **签名**：`fn deliverPendingThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, comptime err: anytype, ) !ThrowResult`。
- **作用**：pending exception 已挂上后，用 typed sentinel 找 catch。
- **实现**：`handleCatchableRuntimeError` 成功 → `.handled`；否则 `return err`。
- **所有权 / 错误 / 调用**：`throwErrorVm` 各 type 臂。

### `throwErrorVm` (`src/exec/vm_control.zig:187`)

- **签名**：`pub noinline fn throwErrorVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !ThrowResult`。
- **作用**：服务 `op.throw_error`：造带消息的 Error，挂 pending，再按 type 送 catch。
- **实现**：读 u32 atom + type 字节，`pc += 5`。`createThrowErrorValue` + `throwValue`。0/4 TypeError；1 SyntaxError；2/3/5 ReferenceError；else JSException。inline-call 展开用 sentinel 在外层帧找 catch，`pendingExceptionMatchesError` 再移交这个 Error 对象。
- **所有权 / 错误 / 调用**：Error 进 pending。分发冷路径。

### `catchTarget` (`src/exec/vm_control.zig:212`)

- **签名**：`pub noinline fn catchTarget(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, catch_target: *?usize) !void`。
- **作用**：服务 `op.catch`：安装新的 catch PC，把旧 offset 压栈。
- **实现**：读 i32 diff，`pc += 4`。旧 target 转 i32（无则 -1），新 target = `relativePc`，压 `JSValue.catchOffset(previous)`。
- **所有权 / 错误 / 调用**：栈上 catch offset 是立即数 tag，非堆。`StackOverflow` 可能。

### `gosub` (`src/exec/vm_control.zig:221`)

- **签名**：`pub fn gosub(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.gosub`：把返回 PC 压栈后相对跳转（finally 子程序）。
- **实现**：读 i32；`return_pc = pc+4`，超过 i32 最大值 → `InvalidBytecode`。压 `int32(return_pc)`，`pc = relativePc`。
- **所有权 / 错误 / 调用**：返回地址是 int32 立即数。`ret` 配对。

### `ret` (`src/exec/vm_control.zig:230`)

- **签名**：`pub fn ret(_: *core.JSContext, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.ret`：从栈弹出 gosub 返回地址。
- **实现**：pop；必须是非负 int32 且 `< bytecode.len`，否则 `InvalidBytecode`。`frame.pc = pc`。
- **所有权 / 错误 / 调用**：消费返回地址槽。`ctx` 未用。

### `relativePc` (`src/exec/vm_control.zig:239`)

- **签名**：`fn relativePc(operand_pc: usize, diff: anytype) usize`。
- **作用**：操作数起点 + 有符号位移。
- **实现**：i64 加法再 `@intCast`。
- **所有权 / 错误 / 调用**：溢出在 `@intCast` 调试时会崩。所有跳转 helper。

### `adapterValueBorrow` (`src/exec/vm_control.zig:243`)

- **签名**：`fn adapterValueBorrow(slot: core.JSValue) core.JSValue`。
- **作用**：若槽是 VarRef cell 则借出其值，供 derived `this` 检查。
- **实现**：`VarRef.fromValue`；Debug 断言值不再套 cell。
- **所有权 / 错误 / 调用**：borrow。`finishFunctionReturn`。

### `varRefCellFromValue` (`src/exec/vm_control.zig:252`)

- **签名**：`fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef`。
- **作用**：薄包装 `VarRef.fromValue`。
- **实现**：一行转发。
- **所有权 / 错误 / 调用**：只做 tag 判读，返回的是**借用** `*core.VarRef`（指向 GC 堆里的 cell），不 retain、不建根，也不分配；无 error set，非 VarRef 值返回 null。文件私有，两处调用：`src/exec/vm_control.zig:244` 解一层 cell，`:247` 是 Debug 断言「解出来的值不会再是一层 cell」——即不存在 VarRef 套 VarRef。

### `readInt` (`src/exec/vm_control.zig:256`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：小端读跳转立即数。
- **实现**：`std.mem.readInt`。
- **所有权 / 错误 / 调用**：纯读借用的字节码切片，不分配、无 error set；定长由调用点的 `[0..N]` 切片保证。文件私有，调用方是本文件的跳转/分支立即数解码：`src/exec/vm_control.zig:64`、`:70`、`:82`、`:214`、`:223`。注意 `:196` 读 atom 时直接用了 `std.mem.readInt` 而没走这个包装。

## 覆盖核对

- 清单函数数: 21
- 本文标题覆盖: 21
- 未覆盖: 无
