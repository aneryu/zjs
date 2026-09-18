# 12 — 对象 / 数组字面量（`vm_literal.zig`）

文件职责：`op.object`/`object_slots2`、`define_field`、`array_from`、`set_proto`、`define_array_el`、`append`、`copy_data_properties`、`special_object`、`get_length`、`rest`。弹出值本地拥有；成功插入或 push 转移；守卫快探 borrow-until-commit。对应 qjs 17961、19269、16814、18017。

`Step`：`done` / `continue_loop`。

### `object` (`src/exec/vm_literal.zig:26`)

- **签名**：`pub noinline fn object( ctx: *core.JSContext, stack: *stack_mod.Stack, global: *core.Object, ) !void`。
- **作用**：服务 `op.object`：造裸 `{}` 并压栈。
- **实现**：`Object.create(object class, Object.prototype)`，`pushOwned`。
- **所有权 / 错误 / 调用**：结果 owned。OOM。热路径用 `newPlainObjectValue`。

### `objectReserved2` (`src/exec/vm_literal.zig:36`)

- **签名**：`pub noinline fn objectReserved2( ctx: *core.JSContext, stack: *stack_mod.Stack, global: *core.Object, ) !void`。
- **作用**：服务 `op.object_slots2`：预留 2 个 named 槽的字面量对象。
- **实现**：`createPlainObjectReserved2`。
- **所有权 / 错误 / 调用**：同 object。

### `newPlainObjectValue` (`src/exec/vm_literal.zig:55`)

- **签名**：`pub inline fn newPlainObjectValue(ctx: *core.JSContext, global: *core.Object) !core.JSValue`。
- **作用**：无帧的 `op.object` 快路径：返回 owned 对象给 handler 压到寄存器 sp（qjs `*sp++ = JS_NewObject`）。不跑用户代码、不记 backtrace，只有 OOM。
- **实现**：同 `object` 体，去掉 `pushOwned`。
- **所有权 / 错误 / 调用**：调用方 push。驻留 handler。

### `newPlainObjectReserved2Value` (`src/exec/vm_literal.zig:60`)

- **签名**：`pub inline fn newPlainObjectReserved2Value(ctx: *core.JSContext, global: *core.Object) !core.JSValue`。
- **作用**：`object_slots2` 的无帧对应。
- **实现**：`createPlainObjectReserved2`。
- **所有权 / 错误 / 调用**：**会分配**并把新对象**以 owned 形式返回**：值留在寄存器里，由调用方负责落进栈槽，本函数不 push、不建根，所以从 `createPlainObjectReserved2` 返回到调用方存栈这段窗口内不能再触发分配。唯一的失败是 OOM，以 Zig error 上传，不写 pending exception（对象创建不跑用户代码、不抓 backtrace）。唯一调用方 `op_object_slots2`（`src/exec/tailcall_dispatch.zig:5187`）：`catch` 后尾调冷表重做，由冷壳统一报错。

### `defineFieldFast` (`src/exec/vm_literal.zig:95`)

- **签名**：`pub inline fn defineFieldFast(rt: *core.JSRuntime, obj: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool`。
- **作用**：服务 `op.define_field` 快腿：普通可扩展非数组非 exotic 非 proxy 对象上的纯数据定义。任意值形状（含 refcounted）都走同一 define，qjs 也无值形态门。
- **实现**：Debug 断言 atom 非 private（parser 已把私有名分到 private 族）。trusted 表达式对象；class 必须 object；无 exotic/proxy/array；可扩展。`definePlainDataPropertyKnownFast` 失败 → false。成功 true，value **消费进槽**；false 时不消费，冷壳用原栈所有权重跑。
- **所有权 / 错误 / 调用**：失败 borrow-until-commit。驻留 handler；false 则 `defineField`。

### `arrayFrom` (`src/exec/vm_literal.zig:112`)

- **签名**：`pub noinline fn arrayFrom( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, global: *core.Object, ) !void`。
- **作用**：服务 `op.array_from`：从栈弹出 argc 个元素造字面量数组。
- **实现**：读 u16 argc，`pc += 2`。≤8 用栈缓冲，否则 heap alloc。逆序 pop。`constructLiteralWithPrototype(Array.prototype)`，push。
- **所有权 / 错误 / 调用**：元素转入数组。defer free 大缓冲。OOM。

### `defineField` (`src/exec/vm_literal.zig:136`)

- **签名**：`pub noinline fn defineField( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.define_field` 冷壳（快路径 miss：数组、proxy、非扩展、setter、堆值）。
- **实现**：读 u32 atom，`pc += 4`；private atom → `InvalidBytecode`。pop value，peek obj。非 refcount 值可再走 definePlainData。否则 root value+obj。数组 `length` 且可写且无 shape 属性：int32 长度 truncate。数组下标 → `defineDenseArrayDataProperty`。空 shape 普通对象 `defineOwnPropertyAssumingNew`。其余 `createDataPropertyOrThrow`。
- **所有权 / 错误 / 调用**：value 成功进属性。错误 handleCatchable。分发。

### `setProto` (`src/exec/vm_literal.zig:211`)

- **签名**：`pub noinline fn setProto( ctx: *core.JSContext, stack: *stack_mod.Stack, ) !void`。
- **作用**：服务对象字面量 `__proto__` / `set_proto`：改栈顶对象的原型。
- **实现**：pop proto，peek obj。null → 原型 null；对象 → 设该对象；其它忽略（与 qjs 字面量惯例一致）。
- **所有权 / 错误 / 调用**：proto 消费。`expectObject` TypeError。

### `defineArrayEl` (`src/exec/vm_literal.zig:225`)

- **签名**：`pub noinline fn defineArrayEl( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.define_array_el`：`arr[index] = value` 定义，index 留在栈上给后续 append。
- **实现**：pop value, index，peek array。三值 root。ToPropertyKey(index)，`createDataPropertyOrThrow`，再 `push(index)`。
- **所有权 / 错误 / 调用**：`handleLiteralRuntimeError`。index 仍 owned 在栈。

### `appendSpreadValues` (`src/exec/vm_literal.zig:255`)

- **签名**：`pub fn appendSpreadValues( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, opc: u8, ) !void`。
- **作用**：服务 `op.append`（spread 进数组）。`opc` 未用。
- **实现**：pop iterable, index，peek array。`appendSpreadValuesEnumerate`：解析 `@@iterator`，仅当 Array 迭代协议未被篡改才密拷（qjs `js_append_enumerate` 16814）。push 新 int32 下标。
- **所有权 / 错误 / 调用**：iterable 消费。可再入 iterator。`appendSpreadValuesVm`。

### `appendSpreadValuesVm` (`src/exec/vm_literal.zig:276`)

- **签名**：`pub noinline fn appendSpreadValuesVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, opc: u8, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`op.append` 的 opcode 入口，把 spread 枚举过程中的可捕获错误转成本帧 catch 跳转。
- **实现**：`appendSpreadValues(ctx, output, global, stack, opc) catch |err|` → `call_runtime.handleCatchableRuntimeError`：true 返回 `.continue_loop`（栈已截到 catch marker、异常已压栈、`frame.pc` 指向 handler），false 上抛；正常返回 `.done`。`appendSpreadValues` 会走完整迭代协议（用户 `@@iterator` / `next` / getter 都可能再入 JS 并抛），所以这里兜的多半是待决异常而非哨兵。
- **所有权 / 错误 / 调用**：`opc` 只是原样透传给 `appendSpreadValues`（它 `_ = opc` 丢弃）。调用点是冷表 `t[op.append]`，最终生效的是 `handlerAppend(op.append)`（`tailcall_dispatch_colds.zig:1033`，`coldStd` 包装）；更早那条传 `undefined` 的 `h(...)` 赋值（502 行）随后被覆盖，运行时不会到达。

### `copyDataProperties` (`src/exec/vm_literal.zig:292`)

- **签名**：`pub noinline fn copyDataProperties( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, mask: u8, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.copy_data_properties`（对象 spread / rest）。mask 编码 target/source/exclusion 相对栈顶的偏移。
- **实现**：按 mask 借三槽并 root。非对象 source **直接 done**（`{...5}` 无属性，qjs 16912；不是只跳过 null/undefined）。exclusion null/undefined → 无排除。`objectRestOwnKeys`。普通源（非 proxy/TA/module_ns）：先快照 enumerability（无用户 getter），再 get+define。exotic：每键 gopd 与 get 交错（Proxy trap 顺序）。
- **所有权 / 错误 / 调用**：不 pop 三槽（调用方随后 drop）。`handleLiteralRuntimeError`。keys defer `freeKeys`。

### `handleLiteralRuntimeError` (`src/exec/vm_literal.zig:421`)

- **签名**：`fn handleLiteralRuntimeError( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, err: anytype, ) !Step`。
- **作用**：字面量路径的统一 catch。
- **实现**：handleCatchable → `.continue_loop` 或 `return err`。
- **所有权 / 错误 / 调用**：defineArrayEl / copyDataProperties。

### `specialObject` (`src/exec/vm_literal.zig:434`)

- **签名**：`pub noinline fn specialObject( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, global: *core.Object, ) !void`。
- **作用**：服务 `op.special_object`：arguments / new.target / home object / import.meta / var object。
- **实现**：读 1 字节 subtype，`pc += 1`。0/1 → `frameArgumentsObjectForSpecialObject`；2 当前函数；3 `new.target`；`home_object` → 函数 home 或 undefined；`import_meta`；`var_object` 空对象；未知 undefined。
- **所有权 / 错误 / 调用**：arguments/import.meta owned 新对象；函数/new.target push 已有引用。

### `getLength` (`src/exec/vm_literal.zig:470`)

- **签名**：`pub noinline fn getLength( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：服务 `op.get_length` 冷路径：`[[Get]] length`。
- **实现**：pop value，`getValueProperty(..., length)`，push。热路径在 field 快读。
- **所有权 / 错误 / 调用**：handleCatchable。分发 miss。

### `rest` (`src/exec/vm_literal.zig:488`)

- **签名**：`pub noinline fn rest( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：服务 `op.rest`：从 `first_arg_idx` 起拷实际参数成密数组（qjs `js_create_array`/`JS_NewArray`，原型是 realm Array.prototype）。
- **实现**：读 u16，`pc += 2`。`reserveAdditional(1)` 后再构造，避免结果与发表之间的分配。`constructLiteralWithPrototype(args[start..end])`，`pushOwnedAssumeCapacity`。
- **所有权 / 错误 / 调用**：新数组 owned。OOM。

### `stackValueFromTop` (`src/exec/vm_literal.zig:512`)

- **签名**：`fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue`。
- **作用**：按距栈顶的偏移 **borrow** 槽（copy_data_properties mask）。
- **实现**：越界 `StackUnderflow`。返回 `values[len-1-offset]`。
- **所有权 / 错误 / 调用**：borrow，不 pop。

### `readInt` (`src/exec/vm_literal.zig:518`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：读 argc / atom / rest 索引。
- **实现**：小端。
- **所有权 / 错误 / 调用**：纯读借用的字节码切片，不分配、无 error set，定长由调用点切片保证。文件私有，调用方：`src/exec/vm_literal.zig:119`（argc）、`:145`（atom）、`:494`（rest 起始参数索引）。

## 覆盖核对

- 清单函数数: 18
- 本文标题覆盖: 18
- 未覆盖: 无
