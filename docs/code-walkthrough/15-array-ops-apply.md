# 15 — `array_ops.zig`：apply 参数、join、canonical TypedArray、编解码

从 codec/isTypedArrayPrototypeMethod 到文件末尾。`fastApplyArgs` 与 `materializeArgsFromArrayLike` 是 `Function.prototype.apply` / 类数组参数的两条路径：前者零观察，后者完整 [[Get]]。

### `uint8ArrayCodecCall` (`src/exec/array_ops.zig:5681`)

- **签名**：`pub fn uint8ArrayCodecCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, name: []const u8, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：Uint8Array 的 hex/base64 选项解析或编解码。
- **实现**：按 `name` 匹配六个入口：`fromHex` / `fromBase64`（静态，把字符串解码成新 Uint8Array）、`toHex` / `toBase64`（receiver 必须是 Uint8Array，编码成字符串）、`setFromHex` / `setFromBase64`（写进 receiver 的字节窗口，先 `typedArrayRejectImmutableBuffer`，返回 `{read, written}`）。名字都对不上返回 `null` 让上层继续级联。选项对象的 `check_options_object` 时机严格照 qjs：`fromBase64` 在字符串检查之后（quickjs.c:59571）、`toBase64` 在 receiver 检查之后（quickjs.c:59484）、`setFromBase64` 在 receiver 与字符串检查之后（quickjs.c:59690），都早于任何选项 Get。关键调用：`mem.eql`、`uint8ArrayStringBytes`、`JSValue.undefinedValue`、`bytes.deinit`、`decodeHexBytes`、`decoded.deinit`、`createUint8ArrayFromBytes`、`uint8ArrayCheckOptionsObject`。
- **所有权 / 错误 / 调用**：返回 owned 值（新 Uint8Array 或字符串或 `{read, written}` 结果对象），或 null 表示名字不匹配。每条臂的临时字节缓冲（`uint8ArrayStringBytes` 的输入拷贝、`decode*Bytes` / `encode*Bytes` 的输出 `std.ArrayList(u8)`）都用 `ctx.runtime.memory.allocator` 且 `defer deinit`；`uint8ArrayViewBytes` 拿到的是**借用**的 buffer 字节切片，setFrom* 直接写进去。可观察次序按 qjs 固定：receiver / 字符串检查 → `uint8ArrayCheckOptionsObject` → 逐个 option 的 Get。error set：receiver 不是 Uint8Array、options 不是对象、option 值不在名字表里 → `error.TypeError`；immutable buffer → `error.TypeError`；编码非法 → `error.SyntaxError`；OOM。唯一调用方 `exec/buffer_ops.zig:262`。

### `uint8ArrayCheckOptionsObject` (`src/exec/array_ops.zig:5767`)

- **签名**：`fn uint8ArrayCheckOptionsObject(options: core.JSValue) !void`。
- **作用**：Uint8Array 的 hex/base64 选项解析或编解码。
- **实现**：两行——`options.is(.undefined_value)` 直接放行，否则 `!options.is(.object)` 就 `error.TypeError`。对应 qjs 的 GetOptionsObject（quickjs.c:59376）：只做「是 undefined 或对象」这一道闸，不读任何属性、不建默认选项对象。
- **所有权 / 错误 / 调用**：无分配、无调用方之外的副作用；`options` 借用。error set 只有 `error.TypeError`（options 既不是 undefined 也不是对象），消息由上层记录边界补。它对应 qjs 的 GetOptionsObject 步骤，**位置本身是契约**：必须在 receiver/字符串检查之后、任何 option 的 Get 之前。调用方 `uint8ArrayCodecCall` 三处（`:5707` fromBase64、`:5726` toBase64、`:5752` setFromBase64）；hex 系不带 options，不调它。

### `expectUint8ArrayObject` (`src/exec/array_ops.zig:5772`)

- **签名**：`pub fn expectUint8ArrayObject(value: core.JSValue) !*core.Object`。
- **作用**：codec 方法的 receiver 校验：必须是 TypedArray 且 kind 为 2（`Uint8Array`），否则 TypeError。
- **实现**：`expectObject` 失败一律转成 `error.TypeError`，再查 `isTypedArrayObject` 与 `typedArrayKind() == 2`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回借用的 `*core.Object`（调用方不得释放）；不分配、不跑用户代码。类检查是「是 TypedArray 且 `typedArrayKind() == 2`」即恰好 Uint8Array，其余一律裸 `error.TypeError`。调用方 `uint8ArrayCodecCall` 四处（`:5715`、`:5722`、`:5735`、`:5744`）与 `exec/module.zig:1332`（模块 source phase 的字节读取）。

### `uint8ArrayBase64Alphabet` (`src/exec/array_ops.zig:5789`)

- **签名**：`pub fn uint8ArrayBase64Alphabet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, options: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !Uint8ArrayBase64Alphabet`。
- **作用**：读选项对象的 `alphabet`：查 `base64` / `base64url` 表，缺省 `base64`，不认识的名字 TypeError。
- **实现**：关键调用：`uint8ArrayBase64NamedOption`、`@enumFromInt`。
- **所有权 / 错误 / 调用**：返回枚举值，不分配。会 Get `options.alphabet` 并把结果 ToString（用户 getter 与 `toString` 都可见）。error set：值不在 `base64` / `base64url` 名字表里 → `error.TypeError`，属性读与 ToString 透传；`options` 不是对象时给默认 `.base64` 而不报错。调用方 `uint8ArrayCodecCall` 三处（`:5708`、`:5727`、`:5753`）。

### `uint8ArrayBase64LastChunkHandling` (`src/exec/array_ops.zig:5811`)

- **签名**：`pub fn uint8ArrayBase64LastChunkHandling( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, options: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !Uint8ArrayBase64LastChunkHandling`。
- **作用**：读选项对象的 `lastChunkHandling`：查 `loose` / `strict` / `stop-before-partial` 表，缺省 `loose`，不认识的名字 TypeError。
- **实现**：关键调用：`uint8ArrayBase64NamedOption`、`@enumFromInt`。
- **所有权 / 错误 / 调用**：与 `uint8ArrayBase64Alphabet` 同形，只是键换成 `lastChunkHandling`、默认值是 `.loose`、表里有三项（含带连字符的 `stop-before-partial`）。error set 同上。调用方 `uint8ArrayCodecCall` 两处（`:5709` fromBase64、`:5754` setFromBase64）——toBase64 不读这个选项。

### `uint8ArrayBase64NamedOption` (`src/exec/array_ops.zig:5836`)

- **签名**：`noinline fn uint8ArrayBase64NamedOption( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, options: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, key: core.Atom, default_id: u32, table: []const core.host_function.name_id.Entry, ) !u32`。
- **作用**：Uint8Array base64 选项对象上按 atom 读命名选项，ToString 后查表；非对象或缺省返回 `default_id`。
- **实现**：`options` 非 object → 直接 `default_id`。Get `key`；`undefined` 同样回默认。`uint8ArrayStringBytes` 把值打成 UTF-8，`name_id.lookup` 未命中 → `error.TypeError`。`alphabet` 与 `lastChunkHandling` 共用本 leftover；comptime 身份只有 atom / default / table。不折叠 `omitPadding`（那条是 truthy 布尔，不是表匹配）。
- **所有权 / 错误 / 调用**：`noinline` 的共享实现；`text` 是 `uint8ArrayStringBytes` 分配的临时字节缓冲，`defer text.deinit` 释放，返回的只是表里的 `u32` id（无所有权）。`options` 借用。error set：`name_id.lookup` 未命中 → `error.TypeError`，属性 Get 与 ToString 透传。调用方就是上面两个 pub 包装（`:5800`、`:5822`）。

### `uint8ArrayOmitPadding` (`src/exec/array_ops.zig:5855`)

- **签名**：`pub fn uint8ArrayOmitPadding( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, options: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：读选项对象的 `omitPadding`：非对象直接 false，否则 Get 后按 ToBoolean（不是查表，所以没有并进 `uint8ArrayBase64NamedOption`）。
- **实现**：关键调用：`options.isObject`、`getValueProperty`、`valueTruthy`。
- **所有权 / 错误 / 调用**：返回 bool，不分配；`options` 不是对象直接 false。走 `valueTruthy` 而不是名字表——因此 `omitPadding: "false"` 是**真**。error set：只有属性 Get 的透传（用户 getter）。唯一调用方 `uint8ArrayCodecCall` 的 toBase64 臂（`:5728`）。

### `createUint8ArrayFromBytes` (`src/exec/array_ops.zig:5869`)

- **签名**：`pub fn createUint8ArrayFromBytes(rt: *core.JSRuntime, global: *core.Object, bytes: []const u8) !core.JSValue`。
- **作用**：用一段字节新建一条 `Uint8Array`（自带等长 ArrayBuffer），原型取 global 所属 realm 的 `%Uint8Array.prototype%`。
- **实现**：realm / `%ArrayBuffer.prototype%` / `%Uint8Array.prototype%` 任一取不到即 `error.InvalidBuiltinRegistry`；buffer 建好后 `@memcpy` 拷贝字节，再 `typedArrayConstructFullBufferOwned(element_size = 1, kind = 2)` 铺满视图。关键调用：`rt.contextForGlobal`、`ctx.classPrototypeObject`、`typed_array.arrayBufferConstructLength`、`property_ops.expectObject`、`@memcpy`、`buffer.byteStorage`、`typed_array.typedArrayConstructFullBufferOwned`。错误：error.InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：返回 owned 的 Uint8Array 值：新建的 ArrayBuffer 的所有权随即由 `typedArrayConstructFullBufferOwned` 转给这个视图；`bytes` 只是输入，函数自己 `@memcpy` 一份。error set：`global` 没有对应 `JSContext`、realm 没装 `%ArrayBuffer.prototype%` 或 `%Uint8Array.prototype%` → `error.InvalidBuiltinRegistry`；分配 OOM。调用方 `uint8ArrayCodecCall` 的 fromHex/fromBase64 两臂（`:5699`、`:5712`）与嵌入 API `src/root.zig:270`（`Buffer.createUint8ArrayFromBytes`）。

### `uint8ArrayViewBytes` (`src/exec/array_ops.zig:5879`)

- **签名**：`pub fn uint8ArrayViewBytes(rt: *core.JSRuntime, object: *core.Object) ![]u8`。
- **作用**：取该 Uint8Array 视图当前对应的可写字节切片（按 `typedArrayLength` 与 `typedArrayByteOffset` 从 backing buffer 上切），buffer 已 detach 则 TypeError。
- **实现**：关键调用：`object.typedArrayLength`、`atomicsBufferObject`、`buffer.arrayBufferDetached`、`object.typedArrayByteOffset`、`buffer.byteStorage`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回**借用**的可写字节切片，指向 buffer 的 `byteStorage()`——它在下一次分配 / detach / resize 之后即失效，调用方（codec 各臂）都是立刻用完。不分配。error set：buffer 已 detach → `error.TypeError`，`typedArrayLength` 与 `atomicsBufferObject` 的透传。调用方 `uint8ArrayCodecCall` 四处（`:5716`、`:5729`、`:5739`、`:5755`）。

### `uint8ArrayCodecResult` (`src/exec/array_ops.zig:5887`)

- **签名**：`pub fn uint8ArrayCodecResult(rt: *core.JSRuntime, read: usize, written: usize) !core.JSValue`。
- **作用**：造 `setFromHex` / `setFromBase64` 的返回对象 `{read, written}`（null 原型的普通对象）。
- **实现**：对象分配后 `errdefer destroyFromHeader`，失败不泄漏。关键调用：`Object.create`、`Object.destroyFromHeader`、`object.gcHeader`、`defineValueProperty`、`JSValue.int32`、`object.value`。
- **所有权 / 错误 / 调用**：返回 owned 的新 `{read, written}` 普通对象（无原型：`Object.create(rt, object, null)`），失败由 `errdefer destroyFromHeader` 回收。两个计数以 int32 立即数写成数据属性。error set：分配 OOM 与 `defineValueProperty` 透传。调用方 `uint8ArrayCodecCall` 的 setFromHex / setFromBase64 两臂（`:5741`、`:5757`）。

### `isTypedArrayPrototypeMethod` (`src/exec/array_ops.zig:5895`)

- **签名**：`pub fn isTypedArrayPrototypeMethod(rt: *core.JSRuntime, function_object: *core.Object) bool`。
- **作用**：判断一个函数对象是不是 `%TypedArray%.prototype` 上的方法——整册用它（而不是 receiver 的类）来分 Array 域与 TypedArray 域的同名方法。
- **实现**：`rt` 未使用；只看 `typedArrayBuiltinMarker() == .prototype_method`。
- **所有权 / 错误 / 调用**：无：一行读函数对象上的 `typedArrayBuiltinMarker`，不分配、无 error set、`rt` 参数未用。它是全文件区分「`%TypedArray%.prototype.x`」与「`Array.prototype.x` 打在 TypedArray 上」的唯一依据——前者对非 TypedArray receiver 报 `error.TypeError`，后者返回 null 或降级。调用方 20 余处，遍布本文件的 `*Call` 与 `exec/string_ops.zig:2946`、`:3333`。

### `typedArrayStaticMethodId` (`src/exec/array_ops.zig:5900`)

- **签名**：`pub fn typedArrayStaticMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?i32`。
- **作用**：把函数对象解析成 TypedArray 静态方法 id：`.static_from → 1`、`.static_of → 2`，其余 null（`arrayFromCall` / `arrayOfCall` 就靠这个把 `%TypedArray%.from`/`of` 分出去）。
- **实现**：`rt` 未使用；对 `typedArrayBuiltinMarker()` 做 `switch`。关键调用：`function_object.typedArrayBuiltinMarker`。
- **所有权 / 错误 / 调用**：无：读同一个 marker，把 `.static_from` / `.static_of` 映射成 1 / 2，其余 null；不分配、无 error set、`rt` 参数未用。调用方两处：`arrayFromCall`（`:3692`）与 `arrayOfCall`（`:4570`），用来把 `%TypedArray%.from` / `.of` 从 Array 静态实现里岔出去。

### `putDenseArrayElementFast` (`src/exec/array_ops.zig:5920`)

- **签名**：`pub noinline fn putDenseArrayElementFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayElementFastResult`。
- **作用**：`OP_put_array_el` 的 dense 覆盖/追加快窗口：下标已在 count 内则 dup 写入，正好追加则 `appendDenseArrayIndex`。
- **实现**：非 Array → `.miss`。key 先 `asInt32`，失败再 `numberValue`（NaN / 非有限 / 非整数 / 越界 → miss）。先 `setFastArrayElementDup`；失败且 `index ≤ max_int_atom` 才 `appendDenseArrayIndex`，OOM 返回 `.out_of_memory`。往空洞或稀疏尾巴写会 miss，回到通用 `[[Set]]`。C ABI 把三态放进寄存器，避免 Zig error-union sret。窗口内唯一会分配的是 dense-buffer 增长。
- **所有权 / 错误 / 调用**：`callconv(.c)` 的三态返回（`.miss` / `.handled` / `.out_of_memory`），**不返回 Zig error**——唯一会失败的是 dense 缓冲扩容，它被翻成 `.out_of_memory` 由调用方处理。`value` 按借用传入：`setFastArrayElementDup` 与 `appendDenseArrayIndex` 各自内部做 dup/写屏障，所以 `.handled` 之后调用方栈上的那份仍然归调用方。调用方 `exec/vm_property.zig:1007`、`:1042`（`OP_put_array_el` 的两个入口），miss 时回落通用属性写。

### `putDenseArrayElementOverwriteOwnedFast` (`src/exec/array_ops.zig:5953`)

- **签名**：`pub noinline fn putDenseArrayElementOverwriteOwnedFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayOverwriteFastResult`。
- **作用**：resident `OP_put_array_el` 的消费式覆盖/预留容量追加：把栈顶 owned value 直接搬进 dense slot，对齐 qjs 同一 Array/int/count 分类。
- **实现**：只接受 Array + int32 下标。`setFastArrayElementOwnedDuringActiveBytecode` 成功 → `.handled`。否则要求 fast array、`index == fastArrayCount()`、`length_writable`、无 exotic、`canExtendFastArray`。`shape.prop_count != 0` 或容量不够 → `.append_candidate`。容量内：直接写 slot、`auditUnbarrieredStore`、`setFastArrayCountAssumeCapacity`、必要时抬 length、`markIndexedProperties`。
- **所有权 / 错误 / 调用**：同样是 `callconv(.c)` 三态，但语义是**消费型**：`.handled` 表示已经把栈上那个 owned 值移进 dense 槽（调用方不得再 drop），`.miss` 与 `.append_candidate` 则完全没碰它。in-capacity 追加这条臂绕过了带记忆点的 append 接口，所以显式调 `rt.gc.auditUnbarrieredStore(..., .dense_array_in_capacity_append)` 记账。无 Zig error（需要分配的情况一律退成 `.append_candidate`）。调用方 `exec/tailcall_dispatch.zig:4607`（常驻 `OP_put_array_el` handler）与三处测试。

### `putDenseArrayElementAppendOwnedFast` (`src/exec/array_ops.zig:5981`)

- **签名**：`pub noinline fn putDenseArrayElementAppendOwnedFast(rt: *core.JSRuntime, object_value: core.JSValue, key: core.JSValue, value: core.JSValue) callconv(.c) DenseArrayElementFastResult`。
- **作用**：已证明是 Array/int 候选后的追加余量：边界再校验一遍，false/OOM 不碰 owned 栈值。
- **实现**：非 Array / 非 int32 / 越界 / `index > max_int_atom` → `.miss`。`appendDenseArrayIndexOwned`：成功 `.handled`，OOM `.out_of_memory`，否则 miss。
- **所有权 / 错误 / 调用**：`callconv(.c)` 三态；`.handled` 接管 owned 值，`.miss` 与 `.out_of_memory` 时调用方仍拥有栈上那份（`appendDenseArrayIndexOwned` 只在成功时才接管）。这是上一函数 `.append_candidate` 的后续：它在公共边界**重新校验一遍**对象与键，因为两次调用之间可能跑过分配。唯一调用方 `exec/tailcall_dispatch.zig:4615`。

### `argsFromArray` (`src/exec/array_ops.zig:5997`)

- **签名**：`pub fn argsFromArray(rt: *core.JSRuntime, array_value: core.JSValue) ![]core.JSValue`。
- **作用**：CreateListFromArrayLike：快照参数列表并根住。
- **实现**：receiver 必须是数组（否则 TypeError）；`arrayLength() > max_apply_arguments`（65534，qjs build_arg_list 的上限，quickjs.c:41173）即 RangeError；长度 0 返回空切片。分配一块等长缓冲后用 `ValueSliceRoot` 把「已填充前缀」登记为精确根，逐个 `getProperty` 填充并同步推进根切片；失败时 `errdefer` 把已填槽位清成 `undefined` 并释放缓冲。含循环：按 length 或迭代器步进处理元素。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 的 `[]core.JSValue`——**由调用方 `rt.memory.free`**（`eval_ops.zig:361`、`vm_call.zig:705`、`:770` 都这么做），长度 0 时返回空切片（不分配，free 空切片是空操作）。填充期间用 `ValueSliceRoot` 把**已填部分**（`args[0..initialized]`）挂成根，错误路径由 `errdefer` 先清空已填槽再 free 缓冲。error set：receiver 不是数组 → `error.TypeError`；长度超 `max_apply_arguments`（65534，qjs `JS_MAX_LOCAL_VARS`）→ `error.RangeError`；`getProperty` 与 OOM 透传。

### `ValueSliceRoot.init` (`src/exec/array_ops.zig:6031`)

- **签名**：`pub fn init(self: *ValueSliceRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void`。
- **作用**：把一个**正在生长**的 `[]JSValue`（通过指针，`.mutable` 切片）登记成精确根，调用方每填一个元素就可以扩展该切片。
- **实现**：记下 rt、填 `slices[0] = .{ .mutable = values }`、建帧并 `activate`。
- **所有权 / 错误 / 调用**：把调用方的 `*[]core.JSValue` 以 `.mutable` 形式登记进 `ValueRootFrame` 并激活——**登记的是切片变量本身**，所以调用方在填充过程中扩展 `rooted_args = values[0..initialized]` 就能让 tracer 立刻看到新元素，这正是「只把已初始化部分暴露给 GC」的实现方式。不分配、无 error set；`self` 必须活到 `deinit`（都是调用方栈上的局部）。调用方 16 处，跨七个文件：本文件 `argsFromArray`（`:6011`）、`materializeArgsFromArrayLike`（`:6276`）、`typedArraySetCall`（`:1193`），以及 `exec/reflect_ops.zig`、`exec/string_ops.zig`、`exec/call.zig`、`exec/call_runtime.zig`、`exec/vm_opcodes.zig`、`exec/eval_entry.zig`（多为经文件顶部别名）。

### `ValueSliceRoot.deinit` (`src/exec/array_ops.zig:6040`)

- **签名**：`pub fn deinit(self: *ValueSliceRoot) void`。
- **作用**：把根帧摘下来（不释放任何缓冲，也不碰那些 JSValue）；未 init 过（`rt == null`）时是 no-op，可重复调用。
- **实现**：`frame.deactivate(rt)` 后把 `rt` 置回 null。
- **所有权 / 错误 / 调用**：只 `frame.deactivate(rt)` 并把 `rt` 清成 null（重复调用是空操作）；不释放被登记的缓冲——那归调用方。无 error set。调用方与 `init` 一一成对（同为 16 处），一律写成 `defer`（结构体字段形式的两处由宿主结构的 `deinit` 转调）。

### `OwnedArrayLikeArgs.deinit` (`src/exec/array_ops.zig:6059`)

- **签名**：`pub fn deinit(self: *OwnedArrayLikeArgs) void`。
- **作用**：释放参数快照的 backing：先把每个槽写成 `undefined`（放弃这些值的所有权），再按 backing 种类 `arena` 回退水位 / `heap` free / `empty` 什么都不做，最后把自身清零。
- **实现**：`rt == null` 时直接返回（空实例可安全 deinit）。含循环：按 length 或迭代器步进处理元素。关键调用：`JSValue.undefinedValue`、`vm_stack.restore`、`memory.free`。
- **所有权 / 错误 / 调用**：三态释放：`.empty` 什么都不做，`.arena` 用 `vm_stack.restore(arena_mark)` 回退 VM 栈 arena（**不是 free**），`.heap` 才 `rt.memory.free`；释放前把每个槽写成 undefined 以断开 GC 边。之后 `self.* = .{}` 归零，所以重复 deinit 安全。无 error set。调用方是 `reflect_ops.zig:587`、`call_runtime.zig:1667` 等拿到 `OwnedArrayLikeArgs` 的地方（一律 `defer`）。⚠️ arena 是严格 LIFO：调用方必须按取得的反序 deinit。

### `OwnedArrayLikeArgs.takeHeap` (`src/exec/array_ops.zig:6072`)

- **签名**：`fn takeHeap(self: *OwnedArrayLikeArgs) []core.JSValue`。
- **作用**：把堆（或空）backing 的切片所有权交出去并清空自身，之后调用方负责释放；断言 storage 不是 `.arena`（arena 窗口不能逃出 LIFO 水位）。
- **实现**：`debug.assert(storage == .empty or storage == .heap)`，取出 `values` 后 `self.* = .{}`。
- **所有权 / 错误 / 调用**：把缓冲的所有权交出去并把结构体归零（此后 deinit 是空操作），返回的切片由调用方 `rt.memory.free`。`assert(storage == .empty or storage == .heap)`——**arena 存储不允许 take**，所以唯一调用方 `argsFromArrayLike`（`:6123`）在 materialize 时传 `prefer_arena = false`。无 error set。

### `argsFromArrayLike` (`src/exec/array_ops.zig:6080`)

- **签名**：`pub fn argsFromArrayLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, array_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) ![]core.JSValue`。
- **作用**：CreateListFromArrayLike 的堆版本：快照参数列表并把缓冲所有权交给调用方。
- **实现**：`materializeArgsFromArrayLike(prefer_arena = false)` 后 `takeHeap()`，因此返回的切片一定是堆分配（或空），由调用方 free。关键调用：`materializeArgsFromArrayLike`、`owned.takeHeap`。
- **所有权 / 错误 / 调用**：返回 owned 的 `[]core.JSValue`，由调用方 `rt.memory.free`（`exec/reflect_ops.zig:542` 与 `exec/call_runtime.zig:3517` 都 `defer` 释放）。它强制走堆存储（`prefer_arena = false`）正是为了能把缓冲交出去。所有权与 error set 其余部分见 `materializeArgsFromArrayLike`。

### `FastApplyArgs.len` (`src/exec/array_ops.zig:6120`)

- **签名**：`pub inline fn len(self: FastApplyArgs) usize`。
- **作用**：返回 apply 参数视图的长度。
- **实现**：按联合 tag 取 `values.len` 或 `cells.len`。
- **所有权 / 错误 / 调用**：无：`inline`，只按 union tag 读一个切片长度，不分配、无 error；两个臂（`.values` 是 `[]const JSValue`、`.cells` 是闭包 cell 指针数组）都是借用视图，返回长度不牵涉任何所有权。唯一调用方 `exec/tailcall_dispatch.zig:1219`，用它算出 `target_argc` 再决定要不要 `growForwardedWindow` 扩栈窗口。

### `FastApplyArgs.copyTo` (`src/exec/array_ops.zig:6128`)

- **签名**：`pub inline fn copyTo(self: FastApplyArgs, dest: []core.JSValue) void`。
- **作用**：把 apply 参数视图拷进 dest（values memcpy 或解 varref）。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`@memcpy`。
- **所有权 / 错误 / 调用**：`inline`，无返回值；`dest` 必须与源等长且不重叠（注释里的前置条件，未运行期断言）。`.values` 臂整块 `@memcpy`，`.cells` 臂逐个解引用 var-ref 的 `pvalue`——`cell.?` 的非空由 `fullyBoundMappedArgumentsVarRefs` 保证。不分配、无 error set。使用点在 `exec/tailcall_dispatch.zig` 的 apply 快臂（配合 `fastApplyArgs`）。

### `fastApplyArgs` (`src/exec/array_ops.zig:6138`)

- **签名**：`pub fn fastApplyArgs(array_value: core.JSValue) ?FastApplyArgs`。
- **作用**：无观察 [[Get]] 的三条 bulk 臂：dense 且 count==length 的 fast Array；unmapped arguments 且 own length 等于 dense count；fully-bound mapped arguments（后者给的是 `.cells`，取值要解 var-ref）。
- **实现**：先排除 Proxy / exotic 接收者。三条臂与 `materializeArgsFromArrayLike` 的 bulk 臂同一套准入。洞、改写过的 `length`（只认未改写的 int32 形态）、长度超过 `max_apply_arguments`（65534）、非对象一律返回 null，调用方回到可观察路径。返回的切片是**借用**：下一次分配或元素写入就可能失效。
- **所有权 / 错误 / 调用**：返回的 `FastApplyArgs` 里两个变体**都是借用视图**：`.values` 直接指向对象的 dense 存储或 unmapped arguments 的槽，`.cells` 指向 mapped arguments 的 var-ref 数组——文档注释写明「valid until the next allocation or element write」，调用方必须在任何分配之前 `copyTo` 出去。不分配、无 error set、不跑用户代码（proxy/exotic、洞、被改写的 `length`、超 65534 一律 null，让调用方走可观察路径）。唯一调用方 `exec/tailcall_dispatch.zig:1218`。

### `argumentsLengthSlotMatches` (`src/exec/array_ops.zig:6161`)

- **签名**：`fn argumentsLengthSlotMatches(object: *core.Object, count: usize) bool`。
- **作用**：bulk 臂对 arguments 对象的 `length` 校验：只接受**未被改写的 int32** own data 槽且数值正好等于 dense count（`arguments.length = "2"` 这类一律退回通用路径），同时挡掉超过 65534 的。
- **实现**：关键调用：`object_ops.probePublicNamedDataPropertyFromObject`、`slot.asInt32`。
- **所有权 / 错误 / 调用**：无：只读谓词，走 `probePublicNamedDataPropertyFromObject` 的 own 数据槽探针，不跑 getter、不分配、无 error set。它刻意只认**未被改写的 int32 形式**（`arguments.length = "2"` 这类返回 false，退回通用 `[[Get]]` + ToLength 路径）。唯一调用方 `fastApplyArgs`（`:6175`、`:6179`）。

### `ownedArgsFromArrayLike` (`src/exec/array_ops.zig:6169`)

- **签名**：`pub fn ownedArgsFromArrayLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, array_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !OwnedArrayLikeArgs`。
- **作用**：CreateListFromArrayLike 的 arena 版本：`prefer_arena = true`，优先从 VM 栈 arena 切窗口，返回的 `OwnedArrayLikeArgs` 必须由调用方 `deinit`（LIFO）。
- **实现**：关键调用：`materializeArgsFromArrayLike`。
- **所有权 / 错误 / 调用**：薄包装：`prefer_arena = true` 转发 `materializeArgsFromArrayLike`。返回的 `OwnedArrayLikeArgs` 里缓冲可能在 VM 栈 arena 上，因此调用方**必须 `defer owned.deinit()`**、且不能 `takeHeap`。调用方 `exec/reflect_ops.zig:587`（Reflect.apply/construct）与 `exec/call_runtime.zig:1667`（apply 的通用臂）。

### `materializeArgsFromArrayLike` (`src/exec/array_ops.zig:6188`)

- **签名**：`fn materializeArgsFromArrayLike( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, array_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, prefer_arena: bool, ) !OwnedArrayLikeArgs`。
- **作用**：CreateListFromArrayLike 的统一实现：快照参数列表到 arena 或堆缓冲，填充期间全程精确根。
- **实现**：非对象即 TypeError。长度来源：dense fast Array（非 Proxy、无 exotic、storage 为 dense）直接读 own `arrayLength()`（不可观察）；否则先试 own data 槽探针，miss 才走完整 `[[Get]] length` + ToLength。长度超过 `max_apply_arguments`（65534，qjs `JS_MAX_LOCAL_VARS`，quickjs.c:41173-41177）抛 RangeError「too many arguments in function call (only 65534 allowed)」；长度 0 返回空实例。backing 按 `prefer_arena` 选 arena 窗口或堆。填充分三条：dense 数组元素整段复制、unmapped arguments 的 dense 值（`len == count` 才算，quickjs.c:41185）、fully-bound mapped arguments 逐个解 var-ref；都不满足才逐下标 `[[Get]]`。每填一个就推进 `ValueSliceRoot` 的根切片。含循环：按 length 或迭代器步进处理元素。关键调用：`objectFromValue`、`object.isArray`、`object.proxyTarget`、`object.hasExoticMethods`、`object.isFastArray`、`object.arrayElementStorageMode`、`object.arrayLength`、`probe`。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：私有实现；返回值持有缓冲的所有权（arena 或堆，由 `prefer_arena` 与 arena 是否有空间决定，`deinit` 按 `storage` 分派）。填充期间 `ValueSliceRoot` 只暴露已初始化前缀，失败时 `errdefer` 先清槽再按存储类型回退 arena / free 堆。可观察性是这里的重点：dense 数组与 unmapped/mapped arguments 三条 bulk 臂**完全不跑 `[[Get]]`**（对齐 qjs `build_arg_list`），其余源逐个 `getValueProperty` 且每个索引 atom `defer key.deinit`。error set：源不是对象 → `error.TypeError`；长度 > 65534 → 先 `throwRangeErrorMessage("too many arguments in function call (only 65534 allowed)")` 再返回 `error.RangeError`；ToLength、getter、OOM 透传。调用方 `argsFromArrayLike`（`:6114`）与 `ownedArgsFromArrayLike`（`:6203`）。

### `arrayIteratorMethodRecord` (`src/exec/array_ops.zig:6311`)

- **签名**：`pub fn arrayIteratorMethodRecord(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, method_id: u32) !?core.JSValue`。
- **作用**：`keys` / `values` / `entries` 的 record 实现：造一个 `%ArrayIteratorPrototype%` 下的 array iterator 对象（kind 1/2/3），目标是装箱后的 receiver。
- **实现**：method_id 不是这三个之一返回 `null`；nullish receiver 抛 TypeError，primitive 装箱后仍不是对象也返回 `null`。TypedArray 域的同名方法额外要求 TypedArray this 并查 detached/OOB。迭代器对象分配后 `errdefer destroyFromHeader`，随后写 target/index=0/kind 三个槽。关键调用：`receiver.isNull`、`receiver.isUndefined`、`receiver.isObject`、`primitiveObjectForAccess`、`property_ops.expectObject`、`isTypedArrayPrototypeMethod`、`object.isTypedArrayObject`、`object.typedArrayDetached`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 array-iterator 对象，或 null（method id 不是 keys/values/entries，或 receiver 转对象后取不到对象）；失败由 `errdefer destroyFromHeader` 回收。target 的 GC 边由 `setOptionalValueSlot` 写入（带屏障），原型取自 realm 的 %ArrayIteratorPrototype%。error set：receiver 为 null/undefined → `error.TypeError`；`%TypedArray%` 版打在非 TypedArray / detached / 越界上 → `error.TypeError`；`arrayIteratorPrototypeFromContext` 的注册表错误透传。唯一调用方 `arrayPrototypeNativeRecord`（`:271`）——与 `array_builtin_ops.arrayIterator` 那条过渡实现不同，这条产出的才是带 `next` 的真迭代器。

### `arrayIteratorNextFast` (`src/exec/array_ops.zig:6337`)

- **签名**：`pub fn arrayIteratorNextFast(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object) !?core.JSValue`。
- **作用**：callee 确实是内建 Array Iterator 的 `next` 时直接走 `iterator_ops.arrayIteratorNext`，否则返回 `null` 让通用调用接手（用户覆写过就不会命中）。
- **实现**：薄封装，主体转发到 `function_object.isArrayIteratorNextFunction`、`iterator_ops.arrayIteratorNext`。
- **所有权 / 错误 / 调用**：返回 owned 的 iter-result 值，或 null 表示「这个函数对象不是 `%ArrayIteratorPrototype%.next`」让调用方走通用调用。身份判定用 `isArrayIteratorNextFunction` 的对象标记，不比名字。错误全部由 `iterator_ops.arrayIteratorNext` 透传。唯一调用方 `exec/call_runtime.zig:1194`。

### `arrayPrototypeValuesFromGlobal` (`src/exec/array_ops.zig:6342`)

- **签名**：`pub fn arrayPrototypeValuesFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue`。
- **作用**：取当前 realm 的 `Array.prototype.values` 函数（`%ArrayProto_values%`），优先命中 realm 缓存 `.array_prototype_values`，否则回到 `Array.prototype` 上读 `values`；连 `Array.prototype` 都没有时返回 `null`。
- **实现**：薄封装，主体转发到 `global.cachedRealmValue`、`arrayPrototypeFromGlobal`、`atom.predefinedId`、`prototype.getProperty`。
- **所有权 / 错误 / 调用**：返回 owned 的 `Array.prototype.values` 函数值，或 null（realm 缓存未填且原型链上没有该属性）。优先读 realm 缓存 `cachedRealmValue(.array_prototype_values)`——那是借用的缓存值；回退路径走 `prototype.getProperty`，**会看到用户改写过的 `values`**。error set：`getProperty` 透传。唯一调用方 `exec/object_ops.zig:2291`（`%Array%` 的 `Symbol.iterator` 解析）。

### `createArrayFromArgs` (`src/exec/array_ops.zig:6349`)

- **签名**：`pub fn createArrayFromArgs(rt: *core.JSRuntime, global: *core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：把一串参数值打成一个新的普通数组（realm 默认原型），元素按 define 而非 Set 语义写入。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`ValueRootBuffer.initCopy`、`rooted_args_buffer.deinit`、`rooted_args_buffer.slice`、`root_frame.activate`、`root_frame.deactivate`、`Object.createArray`、`arrayPrototypeFromGlobal`、`Object.destroyFromHeader`。
- **所有权 / 错误 / 调用**：返回 owned 的新数组；`args` 借用，元素由 `appendDenseArrayDefineIndex` / `defineOwnProperty` 接管。GC：先用 `ValueRootBuffer.initCopy` 把参数拷进一块自有缓冲并整条 `.slice()` 挂 `ValueRootFrame`（`defer` 里 deinit），因为随后的 `createArray` / `reserveDenseArrayElements` / define 都可能触发 GC（测试 `:6420` 用阈值 0 钉住）；建到一半失败由 `errdefer destroyFromHeader` 回收。error set：分配 OOM 与 define 透传。调用方 `exec/object_ops.zig:4826`、`:4855`（Reflect / proxy trap 的参数数组）。

### `arrayLengthAssignmentValue` (`src/exec/array_ops.zig:6409`)

- **签名**：`pub fn arrayLengthAssignmentValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`arr.length = v` 赋值前的数值强制：spec ArraySetLength 会把 `v` **转两次** Number（一次给新 length，一次给描述符的 value），这个可观察的双重强制在这里复现。
- **实现**：只有 receiver 是数组、atom 是 `length` 且 `v` 还不是 number 时才动作，否则原样返回。两轮都是 ToPrimitive(number) + ToNumber，第一轮结果丢弃、返回第二轮的值；`caller_function` / `caller_frame` 未使用。关键调用：`object.isArray`、`value.isNumber`、`toPrimitiveForNumber`、`value_ops.toNumberValue`。
- **所有权 / 错误 / 调用**：返回 owned 的强制转换结果，或**原样返回**入参（不是数组、不是 `length` 键、或已经是数字时直接透传，不做任何转换）。⚠️ 它刻意跑**两遍** ToPrimitive + ToNumber：spec 要求 `ToUint32(v)` 与 `ToNumber(v)` 各求一次值，用户的 `valueOf` 因此被调用两次，第一次的结果被 `_ =` 丢弃。`caller_function` / `caller_frame` 收下即丢弃。error set：强制转换透传（BigInt 的 `error.TypeError` 等）。调用方 `exec/object_ops.zig:1122`、`:2917`、`:2969` 与 `exec/reflect_ops.zig:492`。

### `typedArrayReflectSetReceiverOwn` (`src/exec/array_ops.zig:6428`)

- **签名**：`pub fn typedArrayReflectSetReceiverOwn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, receiver_object: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：`Reflect.set` 里 receiver 与 target 不同时的 OrdinarySetWithOwnDescriptor 收尾：在 **receiver** 上创建或更新自有数据属性，返回是否成功。
- **实现**：receiver 是 Proxy → 走 `proxyDefineValueForReflectSet` 并返回 true。receiver 是 TypedArray 且 key 是 canonical numeric index → 交 `typedArrayDefineOwnPropertyVm`。否则：已有 own 属性时，访问器或不可写返回 false，其余用只带 value 的描述符更新；没有 own 属性则 define 一个可写/可枚举/可配置的新属性。`ReadOnly`/`NotExtensible`/`IncompatibleDescriptor` 都被翻成返回 false，`InvalidLength` 翻成 `error.RangeError`。错误：error.ReadOnly、error.NotExtensible、error.IncompatibleDescriptor、error.InvalidLength、error.RangeError。
- **所有权 / 错误 / 调用**：返回 bool 而不是抛：**结构性失败一律折成 `false`**（访问器、不可写、`ReadOnly` / `NotExtensible` / `IncompatibleDescriptor`），对应 spec `CreateDataProperty` 的返回值语义；只有 `error.InvalidLength` 被翻成 `error.RangeError`，其余错误原样上抛。proxy receiver 转 `proxyDefineValueForReflectSet` 后直接 true。`value` 借用，写入后由 receiver 持有。调用方 `exec/reflect_ops.zig:470` 与本文件 `typedArrayPrototypeSet`（`:6555`）。

### `typedArrayPrototypeSet` (`src/exec/array_ops.zig:6478`)

- **签名**：`pub fn typedArrayPrototypeSet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, receiver_object: *core.Object, prototype: ?*core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?bool`。
- **作用**：`[[Set]]` 沿原型链走到某个 TypedArray 时的 exotic 接管：整数索引写入永远落在**那条 TypedArray 上**（而不是 receiver），越界写被静默吞掉。
- **实现**：沿 `prototype` 链逐级找 TypedArray；key 不是 canonical numeric index 立刻返回 `null` 交回普通 `[[Set]]`。`.invalid`（如 `"-0"`、`"1.5"`）只在 receiver 就是该对象时跑一次值强制然后返回 true（写丢弃）。`.index`：receiver 就是该对象时先强制值（可能 detach/resize），随后下标失效返回 true（静默成功）、buffer immutable 返回 false，否则写入；receiver 不是该对象时，下标失效返回 true，否则转 `typedArrayReflectSetReceiverOwn` 在 receiver 上建自有属性。链走完没遇到 TypedArray 返回 `null`。含循环：沿原型链逐级。关键调用：`object.getPrototype`、`object.isTypedArrayObject`、`object.typedArrayCanonicalNumericIndex`、`sameObjectIdentity`、`object.value`、`coerceTypedArrayElementInput`、`typed_array.typedArrayCoerceElementValue`、`coerceTypedArrayElementForSet`。
- **所有权 / 错误 / 调用**：返回 `?bool`：null = 原型链上没有 TypedArray 参与，调用方继续走普通 `[[Set]]`；true/false 是 spec 的 `[[Set]]` 结果。`value` 借用；receiver 就是那个 TypedArray 时直接写元素（先 `coerceTypedArrayElementForSet` 跑 ToPrimitive，再复检索引有效性——强制转换可能 detach，所以**越界时返回 true 而不是报错**，immutable buffer 才返回 false），否则转 `typedArrayReflectSetReceiverOwn` 在 receiver 自己身上定义。error set：强制转换与底层写入透传。调用方 `exec/object_ops.zig:2951`、`exec/reflect_ops.zig:476`、`exec/call_runtime.zig:4703`。

### `arrayJoinCall` (`src/exec/array_ops.zig:6528`)

- **签名**：`pub fn arrayJoinCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：入口检查 native 栈溢出（自引用 `a.push(a); a.join()`）。
- **实现**：入口检查 native 栈溢出（自引用 `a.push(a); a.join()`）。非 TA 先试 `fastDensePrimitiveArrayJoin`；洞/null/undefined 贡献空串。否则按 length 取元素再 ToString，中间插分隔符。含循环：按 length 或迭代器步进处理元素。对不上这个 builtin 时返回 `null`，让上层继续级联。错误：error.StackOverflow、error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的字符串值，或 null（receiver 转对象后取不到对象）。两个 `std.ArrayList(u8)`（分隔符与结果字节）用 `ctx.runtime.memory.allocator` 且 `defer deinit`；每个索引 atom `defer key.deinit`。**入口的 `checkNativeStackOverflow` 是自引用数组（`a.push(a); a.join()`）的唯一防线**：join → 元素 ToString → join 全程在 native 帧里递归，越界即 `error.StackOverflow`（上层变 InternalError "stack overflow"，与 qjs 一致）。error set：receiver 为 null/undefined、`%TypedArray%.prototype.join` 打在非 TypedArray 上 → `error.TypeError`；ToString 与属性读的用户代码透传。调用方 `arrayPrototypeNativeRecord`（`:257`）与 `exec/call_runtime.zig:1263`。

### `fastDensePrimitiveArrayJoin` (`src/exec/array_ops.zig:6588`)

- **签名**：`pub fn fastDensePrimitiveArrayJoin( rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`join` 的零观察快路径：dense、无自有命名属性、元素全是原始值的普通数组直接拼字节。
- **实现**：准入：是 Array、无 exotic 方法、storage 为 dense、`shape_ref.prop_count == 0`、`length <= elements.len`；分隔符只接受缺省（`,`）或字符串参数，别的（会触发 ToString）返回 `null`。循环中任一元素不是 `canFastJoinPrimitive` 认可的原始值（即遇到对象/symbol）立刻放弃返回 `null`，回到通用 join；`undefined`/`null` 贡献空串。含循环：按 length 或迭代器步进处理元素。关键调用：`object.isArray`、`object.hasExoticMethods`、`object.arrayElementStorageMode`、`object.arrayLength`、`object.arrayElements`、`separator.deinit`、`isUndefined`。
- **所有权 / 错误 / 调用**：返回 owned 的字符串值，或 null 表示「有任何一个元素/分隔符不是可直接拼接的原始值」——**中途返回 null 时已经拼了一半的 `bytes` 由 `defer deinit` 释放，调用方从头走通用 join**，不会产生半个结果。两个 ArrayList 都是本地缓冲。准入条件：dense 数组、无 exotic、`shape_ref.prop_count == 0`（没有额外命名属性）、分隔符缺省或是字符串。error set：只有分配 OOM 与 `appendValueString`（这里只处理原始值，不跑用户 `toString`）。唯一调用方 `arrayJoinCall`（`:6595`）。

### `canFastJoinPrimitive` (`src/exec/array_ops.zig:6622`)

- **签名**：`pub fn canFastJoinPrimitive(value: core.JSValue) bool`。
- **作用**：判断元素能否在 join 快路径里直接字符串化：undefined / null / string / number / bool / bigint 为真——对象（会调 toString）和 symbol（该抛 TypeError）为假。
- **实现**：关键调用：`value.isUndefined`、`value.isNull`、`value.isString`、`value.isNumber`、`value.isBool`、`value.isBigInt`。
- **所有权 / 错误 / 调用**：无：纯 tag 谓词（undefined / null / string / number / bool / bigint 放行，对象一律 false），不分配、无 error set、不跑用户代码——它的存在就是为了保证快路上不会触发 `toString`。唯一调用方 `fastDensePrimitiveArrayJoin`（`:6659`）。

### `objectEntryArrayValue` (`src/exec/array_ops.zig:6631`)

- **签名**：`pub fn objectEntryArrayValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：造 `Object.entries(obj)` 结果里的一个 `[key, value]` 二元组：读一次属性值，再包成两元素稠密数组。
- **实现**：三个局部 `JSValue`（value / entry_value / key_value）先进 `ValueRootFrame` 钉住，因为下面每一步都可能触发分配或用户回调（getter）。顺序是：`getValueProperty` 取属性值（透传 output/global/caller_function/caller_frame，所以访问器与 proxy trap 能正常执行）→ `Object.createArray` 用 `arrayPrototypeFromGlobal` 取的 realm 原型建空数组 → `atoms.toStringValue` 把 atom 键转成字符串值 → 按 qjs `js_create_array`（quickjs.c:9601）的做法，`createArrayStorageSlice(rt, 2)` 一次分配好稠密存储、直接写入两槽、`adoptDenseArrayElementsAssumingEmpty` 接管，并置 `flags.may_have_indexed_properties`；刻意不走两次 `atomFromUInt32 + Descriptor + defineOwnProperty`。
- **所有权 / 错误 / 调用**：返回的 `JSValue` 由调用方拥有。GC：三个局部值经 root frame 暴露给 tracer；元素切片是 TGC S4-b 的 `.array_storage` cell，`adoptDenseArrayElementsAssumingEmpty` 之后归 entry 对象所有。唯一调用方是 `object_ops.zig:3169` 的 `.entries` 分支（`Object.entries` 的枚举循环）。

### `typedArrayValidateConstructArgsPreAllocate` (`src/exec/array_ops.zig:6736`)

- **签名**：`pub fn typedArrayValidateConstructArgsPreAllocate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, ) !void`。
- **作用**：TypedArray 构造前先把参数的数值强制跑一遍（用户 `valueOf` 的副作用与 RangeError 必须发生在分配之前），只做校验不返回值。
- **实现**：无参直接返回。首参非对象 → 当长度过一次 `typedArrayConstructToIndex`。首参是对象但不是 ArrayBuffer/SharedArrayBuffer → 什么都不做。是 buffer 时，对非 undefined 的 `args[1]`（byteOffset）与 `args[2]`（length）各强制一次。关键调用：`first.isObject`、`typedArrayConstructToIndex`、`objectFromValue`、`isUndefined`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：无返回值、不分配；把 TypedArray 构造参数里的**索引强制转换预先跑一遍**（结果全部 `_ =` 丢弃），目的只是让用户 `valueOf` 的副作用与异常发生在真正分配之前。error set：`typedArrayConstructToIndex` 的 `error.TypeError` / `error.RangeError` 与用户代码透传。唯一调用方 `exec/reflect_ops.zig:552`（`Reflect.construct` 打到 TypedArray 构造器时）。

### `arrayLengthDefineValue` (`src/exec/array_ops.zig:6758`)

- **签名**：`pub fn arrayLengthDefineValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：`Object.defineProperty(arr, "length", {value})` 的取值：与赋值路径一样做**两轮** ToPrimitive(number) + ToNumber（spec ArraySetLength 的可观察双重强制），返回第二轮结果。
- **实现**：关键调用：`toPrimitiveForNumber`、`value_ops.toNumberValue`。
- **所有权 / 错误 / 调用**：返回 owned 的数字值；与 `arrayLengthAssignmentValue` 同样**跑两遍** ToPrimitive + ToNumber（第一遍结果丢弃），对应 `ArraySetLength` 里 `ToUint32` 与 `ToNumber` 各求一次值的可观察要求。不分配额外缓冲。error set：强制转换透传。唯一调用方 `exec/object_ops.zig:3500`（`defineOwnProperty` 打到数组 `length` 时）。

### `typedArrayCanonicalGet` (`src/exec/array_ops.zig:6770`)

- **签名**：`pub fn typedArrayCanonicalGet(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.JSValue`。
- **作用**：TypedArray 的 `[[Get]]` exotic 臂：key 不是 canonical numeric index 时返回 `null`（回到普通属性查找）；是但不合法（`"-0"`、`"1.5"`、越界）给 `undefined`；合法下标读元素。
- **实现**：`.none → null`、`.invalid → undefined`、`.index → typedArrayGetIndex`（越界由它内部给 `undefined`）。关键调用：`object.typedArrayCanonicalNumericIndex`、`JSValue.undefinedValue`、`typed_array.typedArrayGetIndex`。
- **所有权 / 错误 / 调用**：返回 owned 的元素值、undefined，或 null 表示「这个键不是 canonical 数值索引」让调用方继续普通属性查找。注意 `.invalid`（是数值形式但不是 canonical，如 `"-0"` / `"1.5"`）返回 undefined 而不是 null——TypedArray 上这类键恒为 undefined。不分配。error set：`typedArrayCanonicalNumericIndex` 与 `typedArrayGetIndex` 的 detached 错误透传。调用方 `exec/object_ops.zig:2512`、`:3594`、`:3635`。

### `typedArrayCanonicalOwnDescriptor` (`src/exec/array_ops.zig:6778`)

- **签名**：`pub fn typedArrayCanonicalOwnDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor`。
- **作用**：TypedArray 的 `[[GetOwnProperty]]` exotic 臂：界内 canonical numeric index 返回「可写/可枚举/可配置」的数据描述符；非 TypedArray、非 canonical、`.invalid`、越界都返回 `null`（由普通级联判成不存在）。
- **实现**：关键调用：`object.isTypedArrayObject`、`object.typedArrayCanonicalNumericIndex`、`object.typedArrayLength`、`typed_array.typedArrayGetIndex`、`Descriptor.data`。
- **所有权 / 错误 / 调用**：返回 `?core.Descriptor`（值是 owned 的元素值，描述符本身按值返回、不需释放），null 表示「不是 TypedArray、不是 canonical 索引，或索引越界」——三种都让调用方回落普通 own 属性查找。不分配。error set：canonical 判定与 `typedArrayLength` / `typedArrayGetIndex` 的透传。唯一调用方 `exec/object_ops.zig:4569`。

### `typedArrayCanonicalIndexExists` (`src/exec/array_ops.zig:6800`)

- **签名**：`pub fn typedArrayCanonicalIndexExists(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool`。
- **作用**：`typedArrayCanonicalOwnDescriptor` 的「只问在不在」版本：给 `[[HasProperty]]` / desc==NULL 的探针回答某个规范数字索引是否落在 TypedArray 界内，不去物化元素值。
- **实现**：非 TypedArray 直接 `null`。`typedArrayCanonicalNumericIndex` 给 `.none`（不是规范数字索引）或 `.invalid`（是数字形状但不规范，如 `"-0"`、`"1.5"`）也返回 `null`；只有 `.index` 臂再读一次 `typedArrayLength` 并比界，界内返回 `true`、越界返回 `null`。与描述符版 `typedArrayCanonicalOwnDescriptor` 的差别就是**不物化元素值**——对应 qjs `desc == NULL` 的 fast-array 探针路径（quickjs.c:8869-8882）。
- **所有权 / 错误 / 调用**：存在性版的 `typedArrayCanonicalOwnDescriptor`：**不物化元素值**，只返回 `index < length`。null 的含义与描述符版严格一致（不是 TypedArray / `.none` / `.invalid` / 越界），让调用方走同一条回落级联。不分配。error set：canonical 判定与 `typedArrayLength` 透传。唯一调用方 `exec/object_ops.zig:4626`。

### `coerceTypedArrayElementInput` (`src/exec/array_ops.zig:6813`)

- **签名**：`pub fn coerceTypedArrayElementInput( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：写 TypedArray 元素前的第一步：对象先 ToPrimitive(number)（用户 `valueOf` 的副作用在这里发生，可能 detach 视图），原始值原样返回。
- **实现**：关键调用：`value.isObject`、`toPrimitiveForNumber`。
- **所有权 / 错误 / 调用**：返回 owned 的原始值（对象走 `toPrimitiveForNumber`，会跑用户 `valueOf` / `Symbol.toPrimitive`；非对象原样返回借用值）。**只做 ToPrimitive，不做元素类型转换**——那是 `typedArrayCoerceElementValue` 的事。error set：ToPrimitive 透传。调用方 `typedArrayPrototypeSet`（`:6541`）、`coerceTypedArrayElementForSet`（`:6876`）、`typedArrayDefineOwnPropertyVm`（`:6907`）、`exec/reflect_ops.zig:455`。

### `coerceTypedArrayElementForSet` (`src/exec/array_ops.zig:6825`)

- **签名**：`pub fn coerceTypedArrayElementForSet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, value: core.JSValue, ) !core.JSValue`。
- **作用**：在 `coerceTypedArrayElementInput` 之上再按目标视图的元素类别跑一次 `typedArrayCoerceElementValue`（BigInt 视图与 Number 视图混写在这里抛 TypeError），返回 ToPrimitive 后的值。
- **实现**：关键调用：`coerceTypedArrayElementInput`、`typed_array.typedArrayCoerceElementValue`。
- **所有权 / 错误 / 调用**：返回 owned 的原始值，并**额外跑一遍 `typedArrayCoerceElementValue`**——它按视图的元素类检查 BigInt/Number 匹配（不匹配即 `error.TypeError`），但返回的仍是转换前的原始值，真正的写入在调用方。这就是「越界写也要先报类型错」的顺序保障。error set：ToPrimitive 与元素类检查的 `error.TypeError`。调用方 `typedArrayPrototypeSet`（`:6548`）、`typedArrayCanonicalSet`（`:6933`）、`exec/reflect_ops.zig:462`。

### `typedArrayDefineOwnPropertyVm` (`src/exec/array_ops.zig:6837`)

- **签名**：`pub fn typedArrayDefineOwnPropertyVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, atom_id: core.Atom, desc: core.Descriptor, ) !?bool`。
- **作用**：TypedArray 的 `[[DefineOwnProperty]]` exotic 臂，返回 `?bool`：`null` = 这个 key 不归 TypedArray 管（回普通 define），`false` = 拒绝，`true` = 成功。
- **实现**：非 TypedArray → `null`；`.none` → `null`；`.invalid` → `false`。合法下标下：访问器描述符、显式 `configurable: false`、`enumerable: false`、`writable: false` 一律 `false`；下标失效 `false`。带 value 时先查 immutable buffer（`false`），强制值后**重查一次**下标（强制可能 detach/resize：失效则返回 `true` 静默成功）与 immutable，再 `typedArraySetElement`。关键调用：`object.isTypedArrayObject`、`object.typedArrayCanonicalNumericIndex`、`object.typedArrayIndexValid`、`object.typedArrayImmutableBuffer`、`coerceTypedArrayElementInput`、`typed_array.typedArraySetElement`。
- **所有权 / 错误 / 调用**：返回 `?bool`：null = 不是 TypedArray 或键不是 canonical 数值索引（调用方走普通 define），false = 拒绝，true = 完成。`desc.value` 借用。次序契约：先拒掉 accessor 与任何非默认的 configurable/enumerable/writable，再判索引有效，然后**强制转换（可能跑用户代码并 detach/resize）之后重新检查索引与 immutable**——此时索引失效返回 true（静默成功），immutable 返回 false。error set：强制转换与写入透传。调用方 `exec/object_ops.zig:3076` 与本文件 `typedArrayReflectSetReceiverOwn`（`:6494`）。

### `typedArrayCanonicalSet` (`src/exec/array_ops.zig:6873`)

- **签名**：`pub fn typedArrayCanonicalSet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, atom_id: core.Atom, value: core.JSValue, ) !bool`。
- **作用**：receiver 就是该 TypedArray 时的 `[[Set]]` 整数索引臂：`.none` 返回 false（不归它管），`.invalid` 仍跑一次值强制再返回 true（写被丢弃），合法下标强制后写入。
- **实现**：`.index` 臂里强制可能 detach/resize，所以写前重查 `typedArrayIndexValid`（失效即返回 true 静默成功）与 immutable buffer（返回 false）。关键调用：`object.typedArrayCanonicalNumericIndex`、`coerceTypedArrayElementInput`、`typed_array.typedArrayCoerceElementValue`、`coerceTypedArrayElementForSet`、`object.typedArrayIndexValid`、`object.typedArrayImmutableBuffer`、`typed_array.typedArraySetElement`。
- **所有权 / 错误 / 调用**：返回 bool：false 表示「这个键不归 TypedArray 管」（`.none`，调用方继续普通 `[[Set]]`）**或**「immutable buffer 拒绝写入」——两种 false 语义在这里是混在一起的，调用方 `exec/object_ops.zig:1124`、`:2912` 都按「没处理」继续走。`.invalid` 键只跑一次类型检查就返回 true（写入被丢弃）。强制转换后索引失效同样返回 true。error set：强制转换与写入透传。

### `typedArrayCanonicalHas` (`src/exec/array_ops.zig:6898`)

- **签名**：`pub fn typedArrayCanonicalHas(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?bool`。
- **作用**：TypedArray 的 `[[HasProperty]]` exotic 臂：`null` = 不归它管（走原型链），`.invalid` = false，合法 key 返回 `index < length`。注意这个函数不返回 error——内部的可失败调用 `catch return false`。
- **实现**：关键调用：`object.isTypedArrayObject`、`object.typedArrayCanonicalNumericIndex`、`object.typedArrayLength`。
- **所有权 / 错误 / 调用**：返回 `?bool`，**不是 error union**：canonical 判定与 `typedArrayLength` 的失败都被 `catch return false` 吞掉（detached 视图因此表现为「没有这个索引」）。null 表示不是 TypedArray 或 `.none`，让调用方继续查原型链。不分配。调用方 `exec/object_ops.zig:3761`、`:3779`、`:3789`。

### `typedArrayCanonicalDelete` (`src/exec/array_ops.zig:6910`)

- **签名**：`pub fn typedArrayCanonicalDelete(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool`。
- **作用**：TypedArray 的 `[[Delete]]` exotic 臂：`null` = 不归它管（走普通删除），`.invalid` 与越界下标返回 true（delete 视为成功），界内下标返回 false（不能删）。
- **实现**：长度读取失败时按 true 处理（`catch return true`）。关键调用：`object.isTypedArrayObject`、`object.typedArrayCanonicalNumericIndex`、`object.typedArrayLength`。
- **所有权 / 错误 / 调用**：返回 `?bool`；null = 不是 TypedArray 或 `.none`（走普通 delete）。语义：`.invalid` 键返回 true（删除「成功」），canonical 索引越界返回 true、在界内返回 false（不可删）；`typedArrayLength` 失败被 `catch return true`。不分配，只有 canonical 判定可能上抛。唯一调用方 `exec/vm_property.zig:466`。

### `decodeHexBytes` (`src/exec/array_ops.zig:6924`)

- **签名**：`pub fn decodeHexBytes(rt: *core.JSRuntime, source: []const u8, reject_odd: bool) !std.ArrayList(u8)`。
- **作用**：把 hex 字符串解码成新的字节列表（`Uint8Array.fromHex`）；`reject_odd` 为真时奇数长度直接 `error.SyntaxError`。
- **实现**：两两取字符，任一不是十六进制数字即 `error.SyntaxError`。含循环：按 length 或迭代器步进处理元素。关键调用：`out.deinit`、`hexNibble`、`out.append`。错误：error.SyntaxError。
- **所有权 / 错误 / 调用**：返回 owned 的 `std.ArrayList(u8)`——**调用方必须 `deinit`**（`uint8ArrayCodecCall` 的 fromHex 臂 `:5697` 用 `defer`）；失败路径由本函数的 `errdefer out.deinit` 兜底。`source` 借用。error set：`reject_odd` 时长度为奇数、或出现非十六进制字符 → `error.SyntaxError`；分配 OOM。⚠️ 循环条件是 `index + 1 < source.len`，所以 `reject_odd = false` 时末尾多出的单个字符被静默丢弃。

### `decodeHexInto` (`src/exec/array_ops.zig:6937`)

- **签名**：`pub fn decodeHexInto(source: []const u8, target: []u8) !Uint8ArrayCodecProgress`。
- **作用**：把 hex 字符串解进现成的字节窗口（`setFromHex`），返回读了多少字符 / 写了多少字节；目标写满就停。
- **实现**：逐对解析，非法字符 `error.SyntaxError`。含循环：按 length 或迭代器步进处理元素。关键调用：`hexNibble`。错误：error.SyntaxError。
- **所有权 / 错误 / 调用**：就地写进调用方给的 `target` 借用切片（那是 Uint8Array 的 buffer 字节），不分配、不返回缓冲；返回读/写计数供 `uint8ArrayCodecResult` 打包。目标写满即停（`written < target.len`），剩余源字节不算错。error set：源长度为奇数或非十六进制字符 → `error.SyntaxError`。唯一调用方 `uint8ArrayCodecCall` 的 setFromHex 臂（`:5740`）。

### `encodeHexBytes` (`src/exec/array_ops.zig:6951`)

- **签名**：`pub fn encodeHexBytes(rt: *core.JSRuntime, bytes: []const u8) !std.ArrayList(u8)`。
- **作用**：把字节编码成**小写** hex 字符串缓冲（`toHex`）。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`out.deinit`、`out.append`、`unicode_lib.asciiLowerHexDigitChar`。
- **所有权 / 错误 / 调用**：返回 owned 的 `std.ArrayList(u8)`，调用方 `deinit`（`:5717` 的 `defer`）；`errdefer out.deinit` 覆盖中途 OOM。`bytes` 借用（来自 `uint8ArrayViewBytes` 的 buffer 视图）。error set：只有分配 OOM——编码不会失败。唯一调用方 `uint8ArrayCodecCall` 的 toHex 臂（`:5717`）。

### `hexNibble` (`src/exec/array_ops.zig:6961`)

- **签名**：`pub fn hexNibble(byte: u8) ?u8`。
- **作用**：把一个 ASCII 十六进制字符转成 0-15，不是十六进制数字返回 null。
- **实现**：薄封装，主体转发到 `unicode_lib.asciiHexDigitValueByte`。
- **所有权 / 错误 / 调用**：无：一行转发 `unicode_lib.asciiHexDigitValueByte`，返回 `?u8`（null = 不是十六进制字符），不分配、无 error set。调用方 `decodeHexBytes`（`:6974`、`:6975`）与 `decodeHexInto`（`:6986`、`:6987`）——注意 `lexer.zig` 与 `regexp_fastpath.zig` 里的同名函数是各自文件的私有实现，不是这一个。

### `decodeBase64Bytes` (`src/exec/array_ops.zig:6970`)

- **签名**：`pub fn decodeBase64Bytes( rt: *core.JSRuntime, source: []const u8, alphabet: Uint8ArrayBase64Alphabet, last_chunk_handling: Uint8ArrayBase64LastChunkHandling, ) !std.ArrayList(u8)`。
- **作用**：把 base64 字符串解码成新的字节列表（`Uint8Array.fromBase64`）。
- **实现**：建好输出列表后转 `decodeBase64Internal(out = &list, target = null)`；失败由 `errdefer` 释放列表。关键调用：`out.deinit`、`decodeBase64Internal`。
- **所有权 / 错误 / 调用**：返回 owned 的 `std.ArrayList(u8)`，调用方 `deinit`（`:5710` 的 `defer`）；`errdefer out.deinit` 覆盖内部失败。真正的解码全在 `decodeBase64Internal`（这里传 `out` 非空、`target` 为空，即「往列表里追加」模式），它的 progress 返回值被 `_ =` 丢弃。error set：非法字符 / 非法结尾 → `error.SyntaxError`，OOM。唯一调用方 `uint8ArrayCodecCall` 的 fromBase64 臂。

### `decodeBase64Into` (`src/exec/array_ops.zig:6982`)

- **签名**：`pub fn decodeBase64Into( rt: *core.JSRuntime, source: []const u8, alphabet: Uint8ArrayBase64Alphabet, last_chunk_handling: Uint8ArrayBase64LastChunkHandling, target: []u8, ) !Uint8ArrayCodecProgress`。
- **作用**：把 base64 字符串解进现成的字节窗口（`setFromBase64`），返回 `{read, written}`。
- **实现**：转 `decodeBase64Internal(out = null, target = 目标切片)`。关键调用：`decodeBase64Internal`。
- **所有权 / 错误 / 调用**：不分配：把 `target`（借用的 buffer 字节切片）交给 `decodeBase64Internal` 的「就地写」模式，返回读/写计数。空目标直接返回 `{0, 0}`。error set 与 `decodeBase64Internal` 相同（`error.SyntaxError`）。唯一调用方 `uint8ArrayCodecCall` 的 setFromBase64 臂（`:5756`）。

### `decodeBase64Internal` (`src/exec/array_ops.zig:6993`)

- **签名**：`pub fn decodeBase64Internal( rt: *core.JSRuntime, source: []const u8, alphabet: Uint8ArrayBase64Alphabet, last_chunk_handling: Uint8ArrayBase64LastChunkHandling, out: ?*std.ArrayList(u8), target: ?[]u8, ) !Uint8ArrayCodecProgress`。
- **作用**：base64 解码的共用主体：`out` 非空则追加到列表，`target` 非空则写进固定窗口（写满即停），返回读/写进度。
- **实现**：跳过 ASCII 空白，按 4 字符一块经 `decodeBase64Chunk` 解出 1-3 字节；非法字符或不合法的收尾块按 `last_chunk_handling` 抛 `error.SyntaxError`。含循环：按 length 或迭代器步进处理元素。关键调用：`unicode_lib.isAsciiWhitespaceByte`、`base64Value`、`decodeBase64Chunk`、`@memcpy`、`list.appendSlice`。错误：error.SyntaxError。
- **所有权 / 错误 / 调用**：两种模式二选一：`out` 非空则往调用方的 ArrayList 里 `appendSlice`（可能 OOM），`target` 非空则写进借用切片且写满即停并返回**已完整消费的读位置**（`last_read`，不是 `read_pos`——部分块不计入）。自身不分配。带 padding 的块被延后到循环外处理（`pending_padded_chunk`），且其后再出现任何非空白字符即 `error.SyntaxError`。error set：非法字符、padding 后有数据、块结构非法 → `error.SyntaxError`；`out` 模式的 OOM。调用方 `decodeBase64Bytes`（`:7022`）与 `decodeBase64Into`（`:7034`）。

### `decodeBase64Chunk` (`src/exec/array_ops.zig:7064`)

- **签名**：`pub fn decodeBase64Chunk( chunk: [4]u8, chunk_len: usize, alphabet: Uint8ArrayBase64Alphabet, last_chunk_handling: Uint8ArrayBase64LastChunkHandling, is_final: bool, ) !Base64Chunk`。
- **作用**：解一块最多 4 字符的 base64：返回该块产出的字节与是否应当停止，收尾不足 4 字符时按 `last_chunk_handling`（`loose` / `strict` / `stop-before-partial`）决定接受、报错还是停在部分块之前。
- **实现**：每个字符经 `base64Value` 查表（`base64` 与 `base64url` 两套 62/63 字符），非法即 `error.SyntaxError`；`strict` 还会校验尾部填充位必须为 0。含循环：按 length 或迭代器步进处理元素。关键调用：`base64Value`。错误：error.SyntaxError。
- **所有权 / 错误 / 调用**：纯值函数：返回栈上的 `Base64Chunk`（最多 3 字节），不分配、不碰 GC。`last_chunk_handling` 决定末块策略——`.stop_before_partial` 把残块变成 `len = 0` 的空结果（调用方据此停在上一个完整块），`.strict` 要求 padding 位为零且不接受无 padding 的残块，`.loose` 只在结构非法时报错。error set：全部是 `error.SyntaxError`。调用方 `decodeBase64Internal`（`:7062` 完整块、`:7096` 末块）。

### `encodeBase64Bytes` (`src/exec/array_ops.zig:7121`)

- **签名**：`pub fn encodeBase64Bytes(rt: *core.JSRuntime, bytes: []const u8, alphabet: Uint8ArrayBase64Alphabet, omit_padding: bool) !std.ArrayList(u8)`。
- **作用**：把字节编码成 base64 缓冲（`toBase64`）：字母表按 `alphabet` 选 `+/` 或 `-_`，`omit_padding` 为真时不补 `=`。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`out.deinit`、`out.append`。
- **所有权 / 错误 / 调用**：返回 owned 的 `std.ArrayList(u8)`，调用方 `deinit`（`:5730` 的 `defer`）；`errdefer out.deinit` 覆盖中途 OOM。`table` 是两张 comptime 字符串字面量之一（静态只读，不分配）。error set：只有 OOM——编码不会失败。唯一调用方 `uint8ArrayCodecCall` 的 toBase64 臂（`:5730`）。

### `base64Value` (`src/exec/array_ops.zig:7147`)

- **签名**：`pub fn base64Value(byte: u8, alphabet: Uint8ArrayBase64Alphabet) ?u8`。
- **作用**：把一个 base64 字符转成 0-63 的值，不属于该字母表则返回 null。
- **实现**：`A-Z → 0..25`、`a-z → 26..51`、`0-9 → 52..61`；`base64` 认 `+`/`/`，`base64url` 认 `-`/`_`，都是 62/63。
- **所有权 / 错误 / 调用**：无：纯字符分类，不分配、无 error——非法字符用返回 `null` 表示，由调用方转成 `error.SyntaxError`。调用方全在本文件的 base64 解码路径：`:7058` 的合法性预扫，以及 `:7137`–`:7161` 四字符组解码里的 7 处。

### `lengthIndexValue` (`src/exec/array_ops.zig:7165`)

- **签名**：`pub fn lengthIndexValue(index: usize) core.JSValue`。
- **作用**：把一个长度/下标装成 JSValue：能放进 i32 就用 int32 标签，否则退成 float64（数组长度可到 2^32−1，超出 i32 范围）。
- **实现**：薄封装，主体转发到 `math.maxInt`、`JSValue.int32`、`JSValue.float64`、`floatFromInt`。
- **所有权 / 错误 / 调用**：无：纯值转换，返回 int32 或 float64 **立即数**（`JSValue.float64` 是 tag+位模式，不分堆），不分配、无 error set、不碰 GC。它是本文件所有「长度/索引变成 JSValue」的统一出口，调用方遍布 array_ops 与 `exec/string_ops.zig`（`:3006`、`:3018`、`:3041`、`:3072` 等）。

### `LengthIndexAtom.deinit` (`src/exec/array_ops.zig:7184`)

- **签名**：`pub fn deinit(self: LengthIndexAtom, rt: *core.JSRuntime) void`。
- **作用**：释放 `propertyAtomFromLengthIndex` 的 atom：只有 `owned`（下标超过 `max_int_atom`、必须从十进制字节 intern 出来的那种）才 `unpinForHost`；tagged-int 下标是 no-op。
- **实现**：薄封装，主体转发到 `atoms.unpinForHost`。
- **所有权 / 错误 / 调用**：配对释放 `propertyAtomFromLengthIndex` 拿到的 atom：`owned` 为真（索引 > 2^31，键是从十进制字节 intern 出来的）时 `rt.atoms.unpinForHost`，否则空操作。无 error set。**调用契约**：`propertyAtomFromLengthIndex` 的每个调用点都要配一个 `defer key.deinit(rt)`——本文件约 30 处这样写；已知的两处例外在 `fromAsyncArrayLikeStep`（`:4210`）与 `fromAsyncDefineElement`（`:4229`），大索引下会漏掉一次 unpin。

## 覆盖核对

- 清单函数数（本文件分到）: 61（`src/exec/array_ops.zig` 全文件 231）
- 本文标题覆盖: 61
- 未覆盖: 无
