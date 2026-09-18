# 12 — 算术 / 比较 / 更新（`vm_arith.zig`）

文件职责：二元算术、比较、一元、`~`、后缀 ++/--、`inc_loc`/`dec_loc`/`add_loc`。弹出的操作数在此拥有直到消费或释放；压入的结果带一份 owned 引用。可观察强制转换会再入 JS。int32 / short-BigInt 热路径留在分发层。对应 qjs `js_add_slow`/`js_binary_arith_slow`（quickjs.c:14905–15098）与比较慢路径（20268–20330）。

`Step`：`done` / `continue_loop`。

### `binary` (`src/exec/vm_arith.zig:24`)

- **签名**：`pub fn binary( ctx: *core.JSContext, stack: *stack_mod.Stack, binop: u8, output: ?*std.Io.Writer, global: *core.Object, ) !void`。
- **作用**：服务 `op.add`/`sub`/`mul`/`div`/`mod`/`pow`/`shl`/`sar`/`shr`/`and`/`or`/`xor` 的栈慢路径。
- **实现**：pop rhs, lhs。双 int32 → `fastBinaryInt32`，有结果则 `pushOwnedAssumeCapacity`（两次 pop 保证容量，快腿不跑用户代码，镜像 qjs 直写 `sp[-2]`）。双 short bigint → `shortBigIntBinary`。`add` 且一侧字符串、另一侧非对象 → 直接 `value_ops.binary`（无 ToPrimitive 再入）。其余：`add` 走 `toPrimitiveForAddition`；位运算/数值运算走 `toPrimitiveForNumber`，Symbol → TypeError；其它直接 `value_ops.binary`。慢腿 `pushOwned`（ToPrimitive 可能再入，容量不再保证）。
- **所有权 / 错误 / 调用**：lhs/rhs owned 直到消费。TypeError/OOM。`binaryVm` 与分发冷路径。

### `binaryVm` (`src/exec/vm_arith.zig:74`)

- **签名**：`pub noinline fn binaryVm( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, binop: u8, output: ?*std.Io.Writer, global: *core.Object, ) !Step`。
- **作用**：`binary` 的 catch 包装。
- **实现**：标准 handleCatchable → `.continue_loop` / 上抛 / `.done`。
- **所有权 / 错误 / 调用**：`tailcall_dispatch` 多条算术 miss。

### `compare` (`src/exec/vm_arith.zig:90`)

- **签名**：`pub fn compare( ctx: *core.JSContext, stack: *stack_mod.Stack, cmp: u8, output: ?*std.Io.Writer, global: *core.Object, ) !void`。
- **作用**：服务 `op.lt`/`lte`/`gt`/`gte`/`eq`/`neq`/`strict_eq`/`strict_neq` 的栈形态。
- **实现**：pop rhs, lhs。双 int32 在 switch 里直接比。双 short bigint → `fastCompareShortBigInt`。否则：eq/neq → `looseEqualOp`；strict → `value_ops.strictEqual/strictNotEqual`；关系运算 ToPrimitiveForNumber，Symbol TypeError，再 `value_ops.compare`。
- **所有权 / 错误 / 调用**：结果 boolean owned。`compareVm`。

### `compareVm` (`src/exec/vm_arith.zig:141`)

- **签名**：`pub noinline fn compareVm( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, cmp: u8, output: ?*std.Io.Writer, global: *core.Object, ) !Step`。
- **作用**：比较 opcode 的「发布式」慢路径入口：从真实 `Stack` 上取操作数，并把 `compare` 抛出的可捕获错误就地转成本帧 catch 跳转。
- **实现**：`compare(ctx, stack, cmp, output, global) catch |err|`：调 `call_runtime.handleCatchableRuntimeError`，返回 true（本帧有 catch target，栈已截到 marker、异常值已压栈、`frame.pc` 已挪到 handler）则返回 `.continue_loop`；返回 false 或它自身出错则上抛。正常完成返回 `.done`。与 `compareAt` 不同，这里 `cmp` 是**运行时** `u8`——调用方转发 `pc[0]` 或固定的 `op.eq` / `op.lt`，不需要按族特化。
- **所有权 / 错误 / 调用**：不自己持有操作数（由 `compare` pop 并消费）。调用方全是 `vm.local_fast_blocked`（生成器参数/函数体停点）那条臂：`opCompareCold`（转发 `opc`）、`op_eq_if_false8_cold`（`op.eq`）、`op_cmp_if_false8_cold`（`op.lt`），三处都先 `vm.publish(pc, sp)` 再调用，返回后走 `coldNext` 让 `maybeStop` 有机会挂起。非停点时走寄存器驻留的 `compareAt`，不经本函数。

### `compareAt` (`src/exec/vm_arith.zig:173`)

- **签名**：`pub fn compareAt( comptime cmp: u8, ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, lhs: core.JSValue, rhs: core.JSValue, ) !core.JSValue`。
- **作用**：寄存器驻留慢比较（qjs `js_relational_slow` / `js_eq_slow`）：**按值**收两个操作数并**返回**结果，不读 `frame.pc`、不 pop。仅在双方 int32 快路径 miss 后到达。`cmp` 是 comptime，每个调用方只编译自己那一族臂。
- **实现**：关系运算先 `numberValue` 双浮点比较（跳过 ToPrimitive）。short bigint 快路径。eq/neq/strict 同 `compare`。关系运算：双方都非对象则 ToPrimitive 是恒等，直接 `value_ops.compare`（避免 zjs toPrimitive dup）；有对象才 ToPrimitiveForNumber；Symbol TypeError。
- **所有权 / 错误 / 调用**：lhs/rhs **owned**，经 defer/借用强制转换消费。调用方（分发）自己把结果写 `sp[-2]`，仅错误路径才 sync 栈。

### `unary` (`src/exec/vm_arith.zig:236`)

- **签名**：`pub fn unary( ctx: *core.JSContext, stack: *stack_mod.Stack, opcode_id: u8, output: ?*std.Io.Writer, global: *core.Object, ) !void`。
- **作用**：服务 `op.to_number`/`neg`/`inc`/`dec`（及其它走 `value_ops.unary` 的一元）。
- **实现**：pop。int32：to_number 原样；neg/inc/dec 经 f64。short bigint → `shortBigIntUnary`。上述四 opcode 慢路径 ToPrimitiveForNumber。其余直接 `value_ops.unary`。
- **所有权 / 错误 / 调用**：结果 owned。`unaryVm`。

### `unaryVm` (`src/exec/vm_arith.zig:268`)

- **签名**：`pub noinline fn unaryVm( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, opcode_id: u8, output: ?*std.Io.Writer, global: *core.Object, ) !Step`。
- **作用**：一元 opcode 的栈形态慢路径入口，把 `unary` 的可捕获错误转成本帧 catch 跳转。
- **实现**：`unary(ctx, stack, opcode_id, output, global) catch |err|` → `handleCatchableRuntimeError`：true 返回 `.continue_loop`，false 上抛 `err`；正常返回 `.done`。`opcode_id` 为运行时值，由调用方直接透传当前指令字节。
- **所有权 / 错误 / 调用**：`tailcall_dispatch_colds.zig:71` 的 `h_unary = coldStd(...)`，以 `pc[0]` 作 `opcode_id`；`coldStd` 已负责 publish/推进。

### `bitNot` (`src/exec/vm_arith.zig:284`)

- **签名**：`pub fn bitNot( ctx: *core.JSContext, stack: *stack_mod.Stack, output: ?*std.Io.Writer, global: *core.Object, ) !void`。
- **作用**：服务 `op.not`（`~`）。
- **实现**：pop，ToPrimitiveForNumber，`value_ops.unary(..., op.not)`，push。
- **所有权 / 错误 / 调用**：`bitNotVm`。

### `bitNotVm` (`src/exec/vm_arith.zig:296`)

- **签名**：`pub noinline fn bitNotVm( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, global: *core.Object, ) !Step`。
- **作用**：`~` 的冷路径入口，把 `bitNot` 的可捕获错误转成本帧 catch 跳转。
- **实现**：`bitNot(ctx, stack, output, global) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。无 opcode 参数（`op.not` 是唯一形态）。
- **所有权 / 错误 / 调用**：冷表 `t[op.not]` 的 handler（`tailcall_dispatch_colds.zig:319`）唯一调用。ToPrimitive 可再入 JS，故错误既可能是待决异常也可能是哨兵 error。

### `postUpdate` (`src/exec/vm_arith.zig:311`)

- **签名**：`pub fn postUpdate( ctx: *core.JSContext, stack: *stack_mod.Stack, opcode_id: u8, output: ?*std.Io.Writer, global: *core.Object, ) !void`。
- **作用**：服务 `op.post_inc` / `op.post_dec`：压 `[旧值, 新值]`（随后 put 写回）。
- **实现**：pop old。int32 → add/sub 1，push old 再 push updated。short bigint 类似。慢：ToPrimitiveForNumber，非 bigint 再 ToNumber，unary 得 updated，push numeric_old 与 updated。
- **所有权 / 错误 / 调用**：栈净增 1。`postUpdateVm`。

### `postUpdateVm` (`src/exec/vm_arith.zig:344`)

- **签名**：`pub noinline fn postUpdateVm( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, opcode_id: u8, output: ?*std.Io.Writer, global: *core.Object, ) !Step`。
- **作用**：后缀 `++`/`--` 的冷路径入口，把 `postUpdate` 的可捕获错误转成本帧 catch 跳转。
- **实现**：`postUpdate(ctx, stack, opcode_id, output, global) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。
- **所有权 / 错误 / 调用**：冷表 `post_inc`/`post_dec` 经 `handlerPost(op)` 传入具体 opcode（`tailcall_dispatch_colds.zig:1025`）。同文件 329 行那条更早的 `t[op.post_inc]` 赋值传的是 `undefined`，但紧接着即被 `handlerPost(op.post_inc)` 覆盖，运行时不会到达。

### `updateLocal` (`src/exec/vm_arith.zig:360`)

- **签名**：`pub fn updateLocal( ctx: *core.JSContext, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, opcode_id: u8, output: ?*std.Io.Writer, ) !void`。
- **作用**：服务 `op.inc_loc` / `op.dec_loc`：就地改局部，栈中性。
- **实现**：读 u8 idx，`pc += 1`，越界 `InvalidBytecode`。int32/`fastInt32Add|Sub`；short bigint 映射到 `op.inc`/`dec`；否则 ToPrimitive + unary，写回槽。
- **所有权 / 错误 / 调用**：槽替换。`updateLocalVm`。热路径用 `updateLocalAt`。

### `updateLocalVm` (`src/exec/vm_arith.zig:405`)

- **签名**：`pub noinline fn updateLocalVm( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, catch_target: *?usize, opcode_id: u8, output: ?*std.Io.Writer, ) !Step`。
- **作用**：`inc_loc`/`dec_loc` 的发布式慢路径入口，把 `updateLocal` 的可捕获错误转成本帧 catch 跳转。
- **实现**：`updateLocal(ctx, function, global, frame, opcode_id, output) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。因为 `updateLocal` 自己从 `frame.pc` 读局部索引字节并 `pc += 1`，调用方必须先 publish，令 `frame.pc` 正指向操作数字节。
- **所有权 / 错误 / 调用**：只在 `op_update_loc_cold` 的 `vm.local_fast_blocked` 臂被调（`tailcall_dispatch.zig:6622`）：先 `vm.publish(pc, sp)`，返回后 `coldNext`。非停点时走寄存器驻留的 `updateLocalAt`（槽指针，不动 `frame.pc`）。

### `updateLocalAt` (`src/exec/vm_arith.zig:429`)

- **签名**：`pub fn updateLocalAt( ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, slot: *core.JSValue, opcode_id: u8, ) !void`。
- **作用**：寄存器驻留的 inc_loc/dec_loc 慢路径：拿槽指针，不读 `frame.pc`、不碰栈。
- **实现**：同 `updateLocal` 再参数化，外加 float64 快路径（`d ± 1` 不 renormalize 成 int32，镜像 `js_unary_arith_slow`）。对象/堆 bigint：先拷贝再 ToPrimitive，避免 valueOf 释放累加器。
- **所有权 / 错误 / 调用**：原地写 `slot.*`。分发热 handler。

### `addLocal` (`src/exec/vm_arith.zig:487`)

- **签名**：`pub fn addLocal( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, output: ?*std.Io.Writer, ) !void`。
- **作用**：服务 `op.add_loc`：`local += pop()`。
- **实现**：读 idx。pop rhs。lhs 已是字符串 → outlined `addLocalString`。双 int32/`fastInt32Add`；双 short bigint。慢：`toPrimitiveForAdditionFree`（消费，镜像 `JS_ToPrimitiveFree`）。两数则 int+int 走 `numberToValue`（可回 int32），有 float 则裸 `float64` 不 renormalize。其余 `value_ops.binary(add)`。
- **所有权 / 错误 / 调用**：rhs 所有权转入。`addLocalVm`。热路径用 `addLocalAt`。

### `addLocalString` (`src/exec/vm_arith.zig:571`)

- **签名**：`noinline fn addLocalString( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, frame: *frame_mod.Frame, idx: u16, rhs: core.JSValue, ) !void`。
- **作用**：`addLocal` 的字符串累加臂，outlined 以免污染热数值路径的 spill。
- **实现**：rhs 已是字符串 → `value_ops.binary`。否则 ToPrimitiveFree rhs 再加。qjs 19766：双方都已是 STRING 才原地；对象走 slow。
- **所有权 / 错误 / 调用**：rhs 在此消费。调用方不 free。

### `addLocalVm` (`src/exec/vm_arith.zig:595`)

- **签名**：`pub noinline fn addLocalVm( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, global: *core.Object, frame: *frame_mod.Frame, catch_target: *?usize, output: ?*std.Io.Writer, ) !Step`。
- **作用**：`add_loc` 的发布式慢路径入口，把 `addLocal` 的可捕获错误转成本帧 catch 跳转。
- **实现**：`addLocal(ctx, stack, function, global, frame, output) catch |err|` → `handleCatchableRuntimeError`：true → `.continue_loop`，false → 上抛；否则 `.done`。`addLocal` 自己读 `frame.pc` 上的局部索引并 `stack.pop()` 取 rhs，所以 pc 与 sp 都必须已 publish。
- **所有权 / 错误 / 调用**：唯一调用点是 `op_add_loc_cold` 的 `vm.local_fast_blocked` 臂（`tailcall_dispatch.zig:6689`），用于生成器参数/函数体停点，返回后 `coldNext` 触发 `maybeStop`。常规冷路径把 `addLocal` 的函数体直接内联进 `op_add_loc_cold`，绕开本函数这层 noinline 边界。

### `addLocalAt` (`src/exec/vm_arith.zig:628`)

- **签名**：`pub fn addLocalAt( ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, slot: *core.JSValue, rhs: core.JSValue, ) !void`。
- **作用**：qjs `js_add_loc_slow(ctx, pv, sp)` 的忠实对应：槽指针 + 已拥有的 rhs，不读 pc、不 `stack.pop()`。
- **实现**：字节级同 `addLocal`，参数换成 `(slot, rhs)`。字符串 → `addLocalStringAt`。错误路径释放 rhs（或派生 primitive），调用方已把 sp 同步，catch 不会双释放。
- **所有权 / 错误 / 调用**：rhs owned。分发热 `op.add_loc`。

### `addLocalStringAt` (`src/exec/vm_arith.zig:677`)

- **签名**：`noinline fn addLocalStringAt( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, slot: *core.JSValue, rhs: core.JSValue, ) !void`。
- **作用**：`addLocalString` 的槽指针版。
- **实现**：同字符串臂，写 `slot.*`。
- **所有权 / 错误 / 调用**：rhs 消费。

### `fastBinaryInt32` (`src/exec/vm_arith.zig:699`)

- **签名**：`pub fn fastBinaryInt32(binop: u8, lhs: i32, rhs: i32) ?core.JSValue`。
- **作用**：双 int32 的算术/位运算快路径。
- **实现**：add/sub 走 widen；mul 处理 -0 与溢出；div 用 f64 相除后经 `numberToValue` 规格化（整除结果仍回 int32）；mod 特殊 0/-1/-0；移位 mask 31；`shr` 按 u32 再 `numberToValue`；and/or/xor 保持 int32。未知 opcode → null。
- **所有权 / 错误 / 调用**：立即数结果。唯一调用方是本文件的 `binary`（分发层的 int32 热臂自己内联同一形状）。

### `fastInt32Add` (`src/exec/vm_arith.zig:716`)

- **签名**：`pub fn fastInt32Add(lhs: i32, rhs: i32) core.JSValue`。
- **作用**：int64 加宽 + 范围检查（避免 `@addWithOverflow` 的 flag spill）。
- **实现**：`r: i64 = lhs+rhs`；截断等于则 int32，否则 `numberToValue(f64)`。
- **所有权 / 错误 / 调用**：无错误。add / inc / add_loc。

### `fastInt32Sub` (`src/exec/vm_arith.zig:726`)

- **签名**：`pub fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue`。
- **作用**：对称的减法。
- **实现**：同 add。
- **所有权 / 错误 / 调用**：sub / dec。

### `fastInt32Mul` (`src/exec/vm_arith.zig:733`)

- **签名**：`fn fastInt32Mul(lhs: i32, rhs: i32) core.JSValue`。
- **作用**：int32 乘，保留 IEEE -0。
- **实现**：`0 * 负数` → `-0.0`。`mulWithOverflow` 成功则 int32，否则 f64 乘。
- **所有权 / 错误 / 调用**：`fastBinaryInt32`。

### `fastInt32Mod` (`src/exec/vm_arith.zig:740`)

- **签名**：`fn fastInt32Mod(lhs: i32, rhs: i32) core.JSValue`。
- **作用**：int32 `%`，含 NaN 与 -0。
- **实现**：rhs=0 → NaN；rhs=-1 → 负 lhs 得 -0 否则 0；`@rem` 结果 0 且 lhs<0 → -0。
- **所有权 / 错误 / 调用**：`fastBinaryInt32`。

### `fastCompareShortBigInt` (`src/exec/vm_arith.zig:748`)

- **签名**：`fn fastCompareShortBigInt(cmp: u8, lhs: i64, rhs: i64) ?bool`。
- **作用**：短 bigint 的关系/相等。
- **实现**：switch 六种比较 + eq/neq/strict 变体；未知 null。
- **所有权 / 错误 / 调用**：`compare` / `compareAt`。

### `isBitwiseBinaryOp` (`src/exec/vm_arith.zig:760`)

- **签名**：`fn isBitwiseBinaryOp(binop: u8) bool`。
- **作用**：是否需要 ToNumeric 的位运算。
- **实现**：shl/sar/shr/and/or/xor。
- **所有权 / 错误 / 调用**：`binary` 慢腿。

### `isNumericBinaryOp` (`src/exec/vm_arith.zig:765`)

- **签名**：`fn isNumericBinaryOp(binop: u8) bool`。
- **作用**：是否数值二元（非 add）。
- **实现**：sub/mul/div/mod/pow。
- **所有权 / 错误 / 调用**：`binary`。

### `looseEqualOp` (`src/exec/vm_arith.zig:770`)

- **签名**：`fn looseEqualOp( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, lhs: core.JSValue, rhs: core.JSValue, depth: u8, ) !bool`。
- **作用**：ECMA `==`（含 HTMLDDA），服务 `op.eq`/`op.neq`。
- **实现**：depth>8 → TypeError（循环 ToPrimitive）。同类型 → strictEqual。null/undefined 互等；HTMLDDA 与 null/undefined。Number↔String ToNumber；BigInt↔String parse（失败 false）；Bool 转 0/1 递归；BigInt↔Number `bigIntEqualsNumber`；对象↔原语 ToPrimitiveForAddition 递归。
- **所有权 / 错误 / 调用**：ToPrimitive 可再入。临时 bigint `defer deinit`。

### `sameLooseEqualityType` (`src/exec/vm_arith.zig:832`)

- **签名**：`fn sameLooseEqualityType(lhs: core.JSValue, rhs: core.JSValue) bool`。
- **作用**：`==` 的「已是同一语言类型」门。
- **实现**：number/string/bool/bigint/symbol/object/function_bytecode 成对，否则 `tagOf` 相等。
- **所有权 / 错误 / 调用**：`looseEqualOp`。

### `isLoosePrimitiveForObject` (`src/exec/vm_arith.zig:843`)

- **签名**：`fn isLoosePrimitiveForObject(value: core.JSValue) bool`。
- **作用**：对象对侧是否该 ToPrimitive。
- **实现**：number|string|bigint|symbol（不含 bool；bool 已在更早臂处理）。
- **所有权 / 错误 / 调用**：`looseEqualOp`。

### `looseEqualSameNumberTypes` (`src/exec/vm_arith.zig:847`)

- **签名**：`fn looseEqualSameNumberTypes(lhs: core.JSValue, rhs: core.JSValue) bool`。
- **作用**：两数 `==`（NaN 不相等）。
- **实现**：`numberValue`，任一侧 NaN → false，否则 `==`。
- **所有权 / 错误 / 调用**：`looseEqualOp`。

## 覆盖核对

- 清单函数数: 31
- 本文标题覆盖: 31
- 未覆盖: 无
