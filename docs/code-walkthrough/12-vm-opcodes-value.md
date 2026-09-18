# 12 — 立即数 / 栈洗牌 / typeof（`vm_value.zig`）

文件职责：`push_*`、常量池、`this`、`to_object`、`typeof*`、`lnot`、`drop`/`nip_catch`、栈重排、`is_undefined*`/`is_null`。栈槽 owned；帧绑定与常量池值 push 前 dup。冷适配器对齐 qjs 17879–17910；融合热路径在分发层。

## 类型

`DropResult`：`.value`（普通 drop）或 `.catch_target`（drop 掉了 catch offset，要更新 handler）。

`Step`：`done` / `continue_loop`。

### `pushInt32Operand` (`src/exec/vm_value.zig:29`)

- **签名**：`pub fn pushInt32Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.push_i32`。
- **实现**：读 i32，`pc += 4`，`pushSmallInt`。
- **所有权 / 错误 / 调用**：立即数。热路径常内联。

### `pushBigIntI32Operand` (`src/exec/vm_value.zig:35`)

- **签名**：`pub fn pushBigIntI32Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.push_bigint_i32`。
- **实现**：读 i32 当短 bigint，`pushOwnedAssumeCapacity`。
- **所有权 / 错误 / 调用**：非堆。

### `pushI16Operand` (`src/exec/vm_value.zig:41`)

- **签名**：`pub fn pushI16Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.push_i16`。
- **实现**：读 i16 升 i32 再 push。
- **所有权 / 错误 / 调用**：推的是立即数，不分配、不建根、不需写屏障。签名的 `!void` 是形式上的：`pushSmallInt` 只调 `pushOwnedAssumeCapacity`（`src/exec/stack.zig:232`，Debug 下断言容量、Release 下无检查），容量由进帧时按 `stack_size` 一次性预留，所以这条臂永不返回错误。唯一调用方是冷表 `op.push_i16` 臂（`src/exec/tailcall_dispatch_colds.zig:191`）。

### `pushI8Operand` (`src/exec/vm_value.zig:47`)

- **签名**：`pub fn pushI8Operand(stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.push_i8`。
- **实现**：一字节 i8。
- **所有权 / 错误 / 调用**：同 `pushI16Operand`：立即数、不分配、容量已预留故实际不会出错。唯一调用方冷表 `op.push_i8` 臂（`src/exec/tailcall_dispatch_colds.zig:196`）。

### `pushSmallInt` (`src/exec/vm_value.zig:60`)

- **签名**：`pub fn pushSmallInt(stack: *stack_mod.Stack, value: i32) !void`。
- **作用**：纯 int32 push，服务 `op.push_i32`/`push_i16`/`push_i8` 的操作数解码尾部与 `op.push_minus1` / `push_0`–`push_7`。
- **实现**：单条 `stack.pushOwnedAssumeCapacity(core.JSValue.int32(value))`。qjs 无运行时 push+binop 融合（每个 push opcode 都是独立的 `*sp++ = ...`），所以这里没有任何「按下一条指令决定是否折叠」的分支；旧名 `pushImmediateInt32MaybeFuse` / `pushSmallIntMaybeFuse` 里的 `MaybeFuse` 是历史残留，连同它们只为签名对齐而带的 `function`/`frame` 死参一起已删。
- **所有权 / 错误 / 调用**：错误：无（assumeCapacity，帧入口的 `reserveEntryFrameCapacity` 已保证容量）。所有权：int32 是非引用值，压栈不产生边。调用：同文件 `pushInt32Operand`/`pushI16Operand`/`pushI8Operand`，以及 `src/exec/tailcall_dispatch_colds.zig` 的 push_small 冷臂。

### `pushUndefined` (`src/exec/vm_value.zig:64`)

- **签名**：`pub fn pushUndefined(stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.undefined`。
- **实现**：`pushOwnedAssumeCapacity(undefined)`。
- **所有权 / 错误 / 调用**：立即数。

### `pushNull` (`src/exec/vm_value.zig:68`)

- **签名**：`pub fn pushNull(stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.null`。
- **实现**：null 立即数。
- **所有权 / 错误 / 调用**：立即值、不分配、非 GC 边、无写屏障；`!void` 形式化，`pushOwnedAssumeCapacity` 不会失败。唯一调用方冷表 `op.null` 臂（`src/exec/tailcall_dispatch_colds.zig:232`）。

### `pushBoolean` (`src/exec/vm_value.zig:72`)

- **签名**：`pub fn pushBoolean(stack: *stack_mod.Stack, value: bool) !void`。
- **作用**：服务 `op.push_true` / `op.push_false`。
- **实现**：boolean 立即数。
- **所有权 / 错误 / 调用**：同族：立即值、不分配、实际不出错。两个调用点共用它：冷表 `op.push_false`（`src/exec/tailcall_dispatch_colds.zig:237`）与 `op.push_true`（`:242`），`value` 由调用方写死。

### `pushConst` (`src/exec/vm_value.zig:76`)

- **签名**：`pub noinline fn pushConst(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8) !void`。
- **作用**：服务 `op.push_const`。
- **实现**：u32 索引，`constantAt` 失败 TypeError，`pushAssumeCapacity`（常量池值 dup）。opc 未用。
- **所有权 / 错误 / 调用**：池条目被 dup 到栈。

### `pushConst8` (`src/exec/vm_value.zig:84`)

- **签名**：`pub noinline fn pushConst8(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, opc: u8) !void`。
- **作用**：服务 `op.push_const8`。
- **实现**：1 字节索引。
- **所有权 / 错误 / 调用**：**与前面几个不同**：推的是常量池里的值，用的是 `pushAssumeCapacity`（非 Owned 拼写），语义上是**借用** cpool 槽——该值由 `FunctionBytecode` 的 cpool 持有并保活，这里不 retain。有真实 error：索引越界时 `constantAt` 返回 null，直接 `error.TypeError`（不是 JS 异常，由上层 VM 转）。唯一调用方冷表 `op.push_const8` 臂（`src/exec/tailcall_dispatch_colds.zig:206`），注意那里把 `pc[0]` 当 `opc` 传进来而函数体 `_ = opc` 丢弃它。

### `pushAtomValue` (`src/exec/vm_value.zig:92`)

- **签名**：`pub fn pushAtomValue(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.push_atom_value`：atom → interned 字符串。
- **实现**：u32 atom，`atoms.toStringValue`，pushOwnedAssumeCapacity。
- **所有权 / 错误 / 调用**：字符串 owned（intern dup）。OOM。

### `pushPrivateSymbol` (`src/exec/vm_value.zig:99`)

- **签名**：`pub noinline fn pushPrivateSymbol(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void`。
- **作用**：服务 `op.private_symbol`：每次执行 mint 新的 `.private` symbol（不是复用模板 atom）。
- **实现**：读模板 atom，取名，`reserveAdditional(1)` **先于** `newSymbol`+`takeSymbolValue`，避免栈失败留下幽灵 atom。pushOwnedAssumeCapacity。
- **所有权 / 错误 / 调用**：新 symbol owned。测试覆盖栈失败/分配失败不保留瞬时 atom。

### `pushEmptyString` (`src/exec/vm_value.zig:111`)

- **签名**：`pub noinline fn pushEmptyString(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.push_empty_string`。
- **实现**：`rt.emptyString().value()`。
- **所有权 / 错误 / 调用**：intern dup。

### `pushThis` (`src/exec/vm_value.zig:116`)

- **签名**：`pub fn pushThis(stack: *stack_mod.Stack, this_value: core.JSValue) !void`。
- **作用**：服务 `op.push_this` 的纯压栈（已物化的 this）。
- **实现**：`adapterValueBorrow`；uninitialized → ReferenceError；`pushAssumeCapacity`。
- **所有权 / 错误 / 调用**：dup this。`pushThisVm`。

### `pushThisVm` (`src/exec/vm_value.zig:122`)

- **签名**：`pub noinline fn pushThisVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：`op.push_this` 冷路径：先 `materializeFrameThisBinding`（可能 TypeError），再 pushThis。
- **实现**：两处 catch 走 handleCatchable。
- **所有权 / 错误 / 调用**：分发 miss（严格/派生 this）。

### `toObject` (`src/exec/vm_value.zig:146`)

- **签名**：`pub fn toObject(ctx: *core.JSContext, global: *core.Object, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.ext0` + `ext0_sub.to_object` 的 ToObject。
- **实现**：pop；已是对象则原样；否则 `primitiveObjectForAccess`。assumeCapacity push。
- **所有权 / 错误 / 调用**：null/undefined TypeError。`toObjectVm`。

### `toObjectVm` (`src/exec/vm_value.zig:155`)

- **签名**：`pub noinline fn toObjectVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：catch 包装，TypeError 单独走 handleCatchable。
- **实现**：switch TypeError / else。
- **所有权 / 错误 / 调用**：分发。

### `typeOf` (`src/exec/vm_value.zig:173`)

- **签名**：`pub noinline fn typeOf(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.typeof`。qjs 返回预定义 atom 再 `JS_AtomToString`（intern dup，非新分配）。
- **实现**：HTMLDDA 与 undefined → `"undefined"`；null → `"object"`；bool/bigint/number/string/symbol 各原子；bytecode 函数、c_function、async resume、c_closure、bound、可调用 proxy → `"function"`；否则 `"object"`。
- **所有权 / 错误 / 调用**：intern 字符串 owned。

### `typeOfIsUndefined` (`src/exec/vm_value.zig:201`)

- **签名**：`pub noinline fn typeOfIsUndefined(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：服务融合/比较：`typeof x === "undefined"`（含 HTMLDDA）。
- **实现**：pop，push bool。
- **所有权 / 错误 / 调用**：立即数。

### `typeOfIsFunction` (`src/exec/vm_value.zig:206`)

- **签名**：`pub noinline fn typeOfIsFunction(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：`typeof x === "function"`，与 `typeOf` 同一可调用集合。
- **实现**：排除 HTMLDDA。
- **所有权 / 错误 / 调用**：分发仍可能走此外壳。

### `logicalNot` (`src/exec/vm_value.zig:219`)

- **签名**：`pub noinline fn logicalNot(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.lnot`（`!`）。
- **实现**：pop，`!isTruthy`，push bool。
- **所有权 / 错误 / 调用**：无 ToBoolean 再入（对象恒真）。

### `drop` (`src/exec/vm_value.zig:224`)

- **签名**：`pub noinline fn drop(_: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult`。
- **作用**：服务 `op.drop`。普通值丢掉；catch offset 要更新 handler；iterator catch marker 当普通值。
- **实现**：pop。iterator marker → `.value`。catchOffset==0 → `.value`；否则 `.catch_target`。
- **所有权 / 错误 / 调用**：分发按结果写 `vm.catch_target`。pop 先于 free（热路径注释）。

### `nipCatch` (`src/exec/vm_value.zig:239`)

- **签名**：`pub noinline fn nipCatch(_: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult`。
- **作用**：服务 `op.nip_catch`：保留栈顶返回值，往下丢直到 catch offset。
- **实现**：pop ret。循环 pop 直到 catchOffset；marker 或 0 → `.value`，否则更新 target。把 ret 压回。无 marker → `InvalidBytecode`。
- **所有权 / 错误 / 调用**：finally 完成后。

### `dup` (`src/exec/vm_value.zig:260`)

- **签名**：`pub fn dup(ctx: *core.JSContext, stack: *stack_mod.Stack, opc: u8) !void`。
- **作用**：服务 `op.dup`。
- **实现**：peekBorrowed，`pushAssumeCapacity`（dup）。ctx/opc 未用。
- **所有权 / 错误 / 调用**：`StackUnderflow`。

### `swap` (`src/exec/vm_value.zig:267`)

- **签名**：`pub fn swap(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.swap`：`[a,b] → [b,a]`。
- **实现**：require 2，pop 两次再反序 pushOwnedAssumeCapacity。
- **所有权 / 错误 / 调用**：所有权移动。

### `nip` (`src/exec/vm_value.zig:276`)

- **签名**：`pub fn nip(_: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.nip`：丢次顶，留顶。
- **实现**：pop top，pop 丢弃，push top。
- **所有权 / 错误 / 调用**：次顶释放。

### `dup2` (`src/exec/vm_value.zig:283`)

- **签名**：`pub fn dup2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`[a,b] → [a,b,a,b]`。
- **实现**：pop b,a，push a,b（assume dup），再 owned a,b。
- **所有权 / 错误 / 调用**：净 +2。

### `dup1` (`src/exec/vm_value.zig:294`)

- **签名**：`pub fn dup1(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`[a,b] → [a,a,b]`。
- **实现**：pop b,a，push a（dup）、owned a、owned b。
- **所有权 / 错误 / 调用**：旧一字节 id 18 已被融合 opcode `get_loc8_push_i8` 收走，`dup1` 现以 `op.ext0` + `ext0_sub.dup1` 发射与分发（parser 仍在用）。

### `dup3` (`src/exec/vm_value.zig:304`)

- **签名**：`pub fn dup3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：复制顶三槽。
- **实现**：require 3，pop cba，push 三份 assume + 三份 owned。
- **所有权 / 错误 / 调用**：测试验证 underflow 不改栈。

### `insert2` (`src/exec/vm_value.zig:318`)

- **签名**：`pub fn insert2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`[a,b] → [b,a,b]`。
- **实现**：pop b,a，push b（dup）、owned a、owned b。
- **所有权 / 错误 / 调用**：栈洗牌族。

### `insert3` (`src/exec/vm_value.zig:328`)

- **签名**：`pub fn insert3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：把顶插入到深度 3。
- **实现**：`[a,b,c] → [c,a,b,c]`。
- **所有权 / 错误 / 调用**：只搬运栈槽，不分配、不 retain：`pushOwnedAssumeCapacity` 与 `pushAssumeCapacity` 在去 rc 之后是同一段代码（`src/exec/stack.zig:226` / `:232`），`Owned` 后缀现在只是文档性的。error set 只有 `requireStackLen`（`src/exec/vm_value.zig:489`）的 `error.StackUnderflow`，且**先检查后动栈**，这正是 `src/exec/vm_value.zig:624` 那条测试断言的不变量。pop 与 push 之间值只活在 Zig 局部里，但中间不分配，且保守栈扫描覆盖这些局部。`ctx` 被 `_` 丢弃。唯一调用方冷表 `op.insert3` 臂（`src/exec/tailcall_dispatch_colds.zig:612`）。

### `insert4` (`src/exec/vm_value.zig:340`)

- **签名**：`pub fn insert4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：顶插入深度 4。
- **实现**：`[a,b,c,d] → [d,a,b,c,d]`。
- **所有权 / 错误 / 调用**：underflow 测试。

### `rot3l` (`src/exec/vm_value.zig:354`)

- **签名**：`pub fn rot3l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.rot3l`：`[a,b,c] → [b,c,a]`。
- **实现**：pop cba，push b,c,a。
- **所有权 / 错误 / 调用**：所有权移动。

### `rot3r` (`src/exec/vm_value.zig:365`)

- **签名**：`pub fn rot3r(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`[a,b,c] → [c,a,b]`。
- **实现**：push c,a,b。
- **所有权 / 错误 / 调用**：旧一字节 id 30 归 `get_loc8_push_1`，现以 `op.ext0` + `ext0_sub.rot3r` 发射与分发。

### `rot4l` (`src/exec/vm_value.zig:376`)

- **签名**：`pub fn rot4l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：四槽左旋。
- **实现**：`[a,b,c,d] → [b,c,d,a]`。
- **所有权 / 错误 / 调用**：同族：纯搬运、不分配、不 retain，唯一错误是先检查的 `error.StackUnderflow`。`rot4l` 已无一字节 id（旧 id 31 归 `get_var_ref0_get_loc8`），唯一可达分发是 `op.ext0` + `ext0_sub.rot4l`，在 `using_ops.execVm` 的二级 switch 里（`src/exec/using_ops.zig:163`）；`src/exec/tailcall_dispatch_colds.zig:632` 那处写的是 `keep[9]`，是为保持冷表代码布局而保活的实例，不是可达的 opcode 臂。

### `rot5l` (`src/exec/vm_value.zig:389`)

- **签名**：`pub fn rot5l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：五槽左旋。
- **实现**：`[a,b,c,d,e] → [b,c,d,e,a]`。
- **所有权 / 错误 / 调用**：同族：纯搬运、不分配、先检查深度。同样只以 `op.ext0` + `ext0_sub.rot5l` 分发（`src/exec/using_ops.zig:143`）；`src/exec/tailcall_dispatch_colds.zig:637` 是 `keep[4]` 的布局保活实例，不可达。

### `perm3` (`src/exec/vm_value.zig:404`)

- **签名**：`pub fn perm3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.perm3`：`[a,b,c] → [b,a,c]`。
- **实现**：push b,a,c。
- **所有权 / 错误 / 调用**：同族：纯搬运、不分配、先检查深度（`error.StackUnderflow`），`ctx` 丢弃。唯一调用方冷表 `op.perm3` 臂（`src/exec/tailcall_dispatch_colds.zig:642`）。

### `perm4` (`src/exec/vm_value.zig:415`)

- **签名**：`pub fn perm4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.perm4`。
- **实现**：`[a,b,c,d] → [c,a,b,d]`。
- **所有权 / 错误 / 调用**：同族：纯搬运、不分配、先检查深度。唯一调用方冷表 `op.perm4` 臂（`src/exec/tailcall_dispatch_colds.zig:647`）。

### `perm5` (`src/exec/vm_value.zig:428`)

- **签名**：`pub fn perm5(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：五槽置换。
- **实现**：`[a,b,c,d,e] → [d,a,b,c,e]`。
- **所有权 / 错误 / 调用**：同族：纯搬运、不分配、先检查深度。只以 `op.ext0` + `ext0_sub.perm5` 分发（`src/exec/using_ops.zig:147`）；`src/exec/tailcall_dispatch_colds.zig:652` 是 `keep[5]` 的布局保活实例，不可达。

### `swap2` (`src/exec/vm_value.zig:443`)

- **签名**：`pub fn swap2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：交换两对：`[a,b,c,d] → [c,d,a,b]`。
- **实现**：require 4。
- **所有权 / 错误 / 调用**：旧一字节 id 28 归 `push_0_shr`，现以 `op.ext0` + `ext0_sub.swap2` 发射与分发。

### `isUndefinedOrNull` (`src/exec/vm_value.zig:456`)

- **签名**：`pub noinline fn isUndefinedOrNull(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.is_undefined_or_null`。
- **实现**：pop，push bool。
- **所有权 / 错误 / 调用**：热路径常内联。

### `isUndefined` (`src/exec/vm_value.zig:461`)

- **签名**：`pub noinline fn isUndefined(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：`=== undefined`（不含 null/HTMLDDA）。
- **实现**：`value.isUndefined()`。
- **所有权 / 错误 / 调用**：原一字节 id 240 已回收，现以 `op.ext0` + `ext0_sub.is_undefined` 发射与分发。

### `isNull` (`src/exec/vm_value.zig:466`)

- **签名**：`pub noinline fn isNull(_: *core.JSRuntime, stack: *stack_mod.Stack) !void`。
- **作用**：服务 `op.is_null`。
- **实现**：`isNull()`。
- **所有权 / 错误 / 调用**：`op.is_null` 仍是一字节 id 241，由冷表直接分发。

### `adapterValueBorrow` (`src/exec/vm_value.zig:471`)

- **签名**：`fn adapterValueBorrow(slot: core.JSValue) core.JSValue`。
- **作用**：解 VarRef cell 读 this。
- **实现**：Debug 断言不套 cell。
- **所有权 / 错误 / 调用**：`pushThis`。

### `requireStackLen` (`src/exec/vm_value.zig:480`)

- **签名**：`fn requireStackLen(stack: *const stack_mod.Stack, required: usize) !void`。
- **作用**：洗牌前深度检查，失败不改栈。
- **实现**：`< required` → `StackUnderflow`。
- **所有权 / 错误 / 调用**：所有 rearrange。

### `expectStackInt32s` (`src/exec/vm_value.zig:484`)

- **签名**：`fn expectStackInt32s(stack: *const stack_mod.Stack, expected: []const i32) !void`。
- **作用**：测试辅助：栈恰好是这些 int32。
- **实现**：`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：测试辅助，只读：不改栈、不分配，error set 来自 `std.testing`。它按 `stack.values[index]` 从缓冲**底部**索引（不是相对栈顶），所以只对从空栈起搭起来的夹具成立。唯一调用方是 `src/exec/vm_value.zig:624` 那条深度校验测试（3 次）。

### `varRefCellFromValue` (`src/exec/vm_value.zig:491`)

- **签名**：`fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef`。
- **作用**：`VarRef.fromValue` 薄包装。
- **实现**：一行。
- **所有权 / 错误 / 调用**：adapterValueBorrow。

### `functionObjectFromValue` (`src/exec/vm_value.zig:495`)

- **签名**：`fn functionObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：是否字节码函数类（含 generator/async 函数对象）。
- **实现**：对象 + `isBytecodeFunctionClass`。
- **所有权 / 错误 / 调用**：typeof。测试覆盖四个 class id。

### `callableObjectFromValue` (`src/exec/vm_value.zig:505`)

- **签名**：`fn callableObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：native/host/bound/closure/async-resume 可调用对象。
- **实现**：c_function、c_function_data、async resume 类、c_closure、bound_function。
- **所有权 / 错误 / 调用**：typeof。

### `proxyTargetIsCallable` (`src/exec/vm_value.zig:517`)

- **签名**：`fn proxyTargetIsCallable(value: core.JSValue) bool`。
- **作用**：代理链是否指向可调用目标（递归）。
- **实现**：`proxyTarget` 再 bytecode/function/callable/再 proxy。
- **所有权 / 错误 / 调用**：typeof；环由引擎 proxy 不变量约束。

### `readInt` (`src/exec/vm_value.zig:523`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：读立即数/atom/常量索引。
- **实现**：小端。
- **所有权 / 错误 / 调用**：纯读借用的字节码切片，不分配、无 error set，定长由调用点 `[0..N]` 切片保证。文件私有，调用方：`src/exec/vm_value.zig:30`/`:36`/`:42`（立即数）、`:87`（常量索引）、`:102`（atom）、`:109`（private symbol 模板 atom）。

### `countLivePrivateAtomsNamed` (`src/exec/vm_value.zig:527`)

- **签名**：`fn countLivePrivateAtomsNamed(rt: *core.JSRuntime, expected_name: []const u8) usize`。
- **作用**：测试：数仍活着的同名 private atom。
- **实现**：扫 `atoms.entries` 动态 id。
- **所有权 / 错误 / 调用**：private symbol 测试。

### `function object lookup recognizes every bytecode function class` (`src/exec/vm_value.zig:538`)

- **签名**：`test "..."`
- **作用**：四个字节码函数 class 都被 `functionObjectFromValue` 认作函数；普通对象不是。
- **实现**：create 各 class，expectEqual。
- **所有权 / 错误 / 调用**：单测 Runtime。

### `push private symbol creates a fresh runtime atom per execution` (`src/exec/vm_value.zig:557`)

- **签名**：`test "..."`
- **作用**：两次 `pushPrivateSymbol` 产生不同 atom，且非模板；GC 后瞬时 atom 消失，模板仍在直到显式释放。
- **实现**：root 模板 atom（非 GC 的 Bytecode 操作数），两次执行，cycle removal。
- **所有权 / 错误 / 调用**：这条测试本身就是在验根：模板 atom 存在非 GC 的 `Bytecode` 操作数数组里，靠 `core.runtime.rootAtoms` 声明根 + `activate`/`deactivate` 才能活过 major（TGC S3-c）；两个新 atom 只被栈上的 symbol 值持有，`stack.pop()` 之后失去引用，`runObjectCycleRemoval` 即回收，而模板要等 `deactivate` 后才消失。夹具的释放序是 `stack.deinit` → `function.deinit` → `ctx.destroy` → `rt.destroy`（全部 `defer`），另用 `template_atom_released` 标志避免 deactivate 两次。

### `stack rearrange opcodes validate depth before mutating stack` (`src/exec/vm_value.zig:615`)

- **签名**：`test "..."`
- **作用**：`dup3`/`insert4`/`swap2` 在深度不足时 `StackUnderflow` 且栈不变。
- **实现**：`expectStackInt32s`。
- **所有权 / 错误 / 调用**：验证的是重排族的错误契约：`dup3`/`insert4`/`swap2` 在深度不足时返回 `error.StackUnderflow` **且栈内容一字不改**——即 `requireStackLen` 必须在任何 `pop` 之前。不涉及分配与根；`ctx` 只为凑签名。

### `push private symbol stack failure does not retain transient private atom` (`src/exec/vm_value.zig:636`)

- **签名**：`test "..."`
- **作用**：capacity 0 时 `StackOverflow`，allocated_bytes 不变，活 private atom 仍为 1（仅模板）。
- **实现**：先校准回收槽，再 push。
- **所有权 / 错误 / 调用**：验证失败路径不泄漏：容量 0 的栈让 `pushPrivateSymbol` 在 `stack.reserveAdditional(1)` 处就以 `error.StackOverflow` 退出（`src/exec/vm_value.zig:112`，在 `newSymbol` 之前），所以既没多分配字节也没多出 private atom。断言用 `rt.memory.allocated_bytes` 前后相等 + 活 private atom 恒为 1（只剩模板）；校准用的那个额外 symbol 必须先 `runObjectCycleRemoval` 回收，因为去 rc 后 `free` 不再即时退休 atom 表项。

### `push private symbol releases fresh atom on allocation failure` (`src/exec/vm_value.zig:680`)

- **签名**：`test "..."`
- **作用**：`newSymbol` 成功但 `takeSymbolValue` OOM 时不泄漏 atom；随后完整成功。
- **实现**：`setMemoryLimit` 两档。
- **所有权 / 错误 / 调用**：验证中途 OOM 的清理：用 `setMemoryLimit` 卡两档——低档连 `newSymbol` 都不让过，高档放过 `newSymbol` 但卡死 `takeSymbolValue` 的 symbol 体分配；两次都要求 `allocated_bytes` 回到起点、活 private atom 仍为 1，即新建的 atom 在失败路径上被退掉而不是挂着。`defer rt.setMemoryLimit(null)` 保证限额不泄漏到同进程后续测试。

## 覆盖核对

- 清单函数数: 52
- 本文标题覆盖: 57（含 5 条清单外的内嵌辅助函数标题）
- 未覆盖: 无
