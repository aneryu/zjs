# 01 — `src/root.zig`：公共门面

CLI 与仓内测试 `@import("zjs")` 的模块。主要入口：`JSRuntime` / `JSContext` / `JSValue`、`zjs.native`（仅 `managed`）、`zjs.value`、`zjs.object`、`zjs.host`、`zjs.context` / `module` / `job`、`zjs.runtime`。多数类型从 `js_context.zig` / `native.zig` / core 再导出；本文件同时实现字节借用描述符、若干对象构造与属性助手，以及有预算的 job 排空循环。

`core` / `exec` / `internal` 不作为这里的公开命名空间导出，但部分类型通过别名公开，不能据此声称整个类型图不含 core 类型。句柄公开拼写是 `zjs.value.Scope/Local/Persistent/Weak`，不是根上的 `JSValueHandle`。`object.Object` 是 **opaque**，不能通过该类型直接调用 core 的 `Object.create`。`CallSite` / `PropertySite` / `NativeBinding` / `PropName` 已从本文件删除。

---

## 类型与 re-export

| 名字 | 含义 |
| --- | --- |
| `runtime` | `event_loop.zig`：宿主事件循环（`EventLoop` / `runUntilIdle`）。 |
| `JSRuntime` / `JSContext` / `JSValue` | `JSContext` 来自 `js_context.zig`；其余来自 core。 |
| `GCStats` / `GCPauseDistribution` / `RuntimeOptions` / `RuntimeMemoryUsage` / `OpcodeProfile` | 统计与选项。 |
| `default_stack_size` / `default_gc_threshold` | 默认限额。 |
| `opcode_profile_build_enabled` | `-Dzjs_enable_opcode_profile`。CLI 在 false 时对 `--profile-opcodes` fail-close。 |
| `native` | `src/native.zig`。 |
| `value` | 值构造 + 句柄/String/Bytes 别名。 |
| `host` | `NativeBinding`=`binding`、`NativeObject`=`object.Object`、`PropName`=`PropNameID`，以及 CLI 形全局助手。 |
| `object.Object` | `opaque {}`。内部用 ptrCast 接到 core Object。 |
| `object.MemoryAccount` / `SharedArrayBufferRef` / `String` | core 类型的窄口。 |
| `object.OwnDataProperty` | `forEachOwnDataProperty` 的访问记录：`name` / `value` / `enumerable`。 |
| `object.Buffer.BorrowKind` | `array_buffer` / `typed_array` / `data_view`。 |
| `object.Buffer.Borrow` | 零拷贝借用描述符：`ptr`/`mut_ptr`/`len`/`kind`/`byte_offset`/`shared`；仅当 mut_ptr 非 null 时可写。 |
| `object.Buffer.ReadonlyBorrow` | 无 `mut_ptr`、无 `sliceMut` 的只读借阅（类型级保证）。 |
| `object.Buffer.BorrowGuard` | `view_pin` + `buffer_pin`（TypedArray 还要 pin 背后的 ArrayBuffer）。 |
| `context.Options` 等 | 从 core 再导出的选项类型。`FunctionCallOptions` 在这里用 opaque Object 表示 `realm_global`。 |
| `module.Key` / `Source` / `Host` / `ResolveResult` / `LoadResult` | `module_graph.HostHooks` 的别名。 |
| `job.DrainOptions` / `DrainResult` | `budget`；`jobs_drained` + `has_more`。 |

---

## 剖析与 `zjs.value`

### `activateOpcodeProfile` (`src/root.zig:33`)

- **签名**：`pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：给剖析器装 opcode 名提供者并激活缓冲区。
- **实现**：`zjs_core.profile.setOpcodeNameProvider(zjs_exec.opcodeName)`，再 `zjs_core.profile.activate`。
- **所有权 / 错误 / 调用**：返回此前的线程局部活动 profile，供调用方恢复；不拥有、清零或释放 profile，不修改 Runtime 的 profile 字段。此包装不检查 opcode_profile_build_enabled，激活指针本身不会给未编入计数的产物补上采样。

### `value.undefinedValue` (`src/root.zig:47`)

- **签名**：`pub fn undefinedValue() Value`。
- **作用**：JS `undefined`。
- **实现**：`Value.undefinedValue()`。
- **所有权 / 错误 / 调用**：立即数，无堆。

### `value.nullValue` (`src/root.zig:51`)

- **签名**：`pub fn nullValue() Value`。
- **作用**：JS `null`。
- **实现**：`Value.nullValue()`。
- **所有权 / 错误 / 调用**：立即数。

### `value.boolean` (`src/root.zig:55`)

- **签名**：`pub fn boolean(v: bool) Value`。
- **作用**：JS boolean。
- **实现**：`Value.boolean(v)`。
- **所有权 / 错误 / 调用**：立即数。

### `value.int32` (`src/root.zig:59`)

- **签名**：`pub fn int32(v: i32) Value`。
- **作用**：int32 立即数。
- **实现**：`Value.int32(v)`。
- **所有权 / 错误 / 调用**：无堆。

### `value.float64` (`src/root.zig:63`)

- **签名**：`pub fn float64(v: f64) Value`。
- **作用**：float64 值。
- **实现**：`Value.float64(v)`。
- **所有权 / 错误 / 调用**：tag 立即数。

### `value.numberFromU64` (`src/root.zig:67`)

- **签名**：`pub fn numberFromU64(v: u64) Value`。
- **作用**：无符号 64 位收成 JS Number：能进 i32 用 int32，否则 float64（大整数会丢精度）。
- **实现**：`v <= maxInt(i32)` 则 int32。
- **所有权 / 错误 / 调用**：无分配；i32 范围外转换为 f64，超过安全整数范围可能舍入，但并非所有大整数都不可精确表示。需要全 u64 范围逐值精确时用 bigIntFromU64。

### `value.numberFromI64` (`src/root.zig:74`)

- **签名**：`pub fn numberFromI64(v: i64) Value`。
- **作用**：有符号 64 位收成 Number；超出 i32 走 float64。
- **实现**：范围内 int32，否则 `@floatFromInt`。
- **所有权 / 错误 / 调用**：无分配，不以溢出报错；i32 范围外仍可能精确，但不能保证整个 i64 范围。bigIntFromI64 提供精确整数表示。

### `value.bigIntFromI64` (`src/root.zig:84`)

- **签名**：`pub fn bigIntFromI64(runtime_ptr: *JSRuntime, v: i64) !Value`。
- **作用**：精确 JS BigInt。短范围走 inline short bigint，否则堆对象。
- **实现**：`value_ops.createBigIntI128(runtime_ptr, v)`（i64 拓宽到 i128）。
- **所有权 / 错误 / 调用**：短 BigInt 无分配，超出短范围才创建堆 BigInt，分配错误传播。包装不登记持久根；调用方须遵守 Runtime 线程和返回堆值的保活协议。

### `value.bigIntFromU64` (`src/root.zig:91`)

- **签名**：`pub fn bigIntFromU64(runtime_ptr: *JSRuntime, v: u64) !Value`。
- **作用**：u64→BigInt。u64::MAX 仍进 i128，不能经 i64 拓宽（会截最高位）。
- **实现**：`createBigIntI128(runtime_ptr, @as(i128, v))`。
- **所有权 / 错误 / 调用**：全 u64 范围到 i128 的拓宽无损；是否堆分配由 shortBigIntFits 决定，不仅是是否超过 i64::MAX。错误传播，返回堆值不自动取得持久句柄。

### `value.createString` (`src/root.zig:95`)

- **签名**：`pub fn createString(runtime_ptr: *JSRuntime, bytes: []const u8) !Value`。
- **作用**：从字节造 JS 字符串。
- **实现**：`value_ops.createStringValue`。
- **所有权 / 错误 / 调用**：空输入复用 Runtime 空串；非空内容按底层 ASCII/UTF-8 路径创建，不把任意文本统一 intern。输入仅在调用期间借用，返回字符串可能分配失败，且不自动登记宿主持久根。

### `value.appendRawString` (`src/root.zig:99`)

- **签名**：`pub fn appendRawString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void`。
- **作用**：将字符串内容编码为 UTF-8 字节追加；孤立代理项采用 WTF-8，不是直接复制内部 Latin1/UTF-16 原始单元。
- **实现**：转发 value_ops.appendRawString → core.string.appendValueUtf8；取 asStringBody，无 body 直接返回，否则按 body 的 Latin1 或 UTF-16 表示编码（String 恒为 flat，没有展平步骤）。此路径没有先以 isString 拒绝非字符串，asStringBody 支持的符号 body 也可能进入编码。
- **所有权 / 错误 / 调用**：不做用户级 ToString；追加所用 allocator 是 runtime.memory.allocator，已有 out backing 须与之匹配。失败可能留下已追加的前缀，不提供事务回滚。

### `value.appendString` (`src/root.zig:103`)

- **签名**：`pub fn appendString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void`。
- **作用**：使用无 realm 的值格式化助手追加文本，不是完整的 JavaScript ToString 转换。
- **实现**：value_ops.appendValueString 使用 core.value_string 的 symbol=describe 策略；符号输出 Symbol(描述)，普通对象输出类别标签，数组按内部属性访问逐元素拼接。不会调用用户定义的 toString/valueOf。
- **所有权 / 错误 / 调用**：out 使用 Runtime allocator；错误传播，已追加前缀不回滚。不能用这条接口推断 realm-aware 转换的用户回调或异常语义。

### `value.toOwnedString` (`src/root.zig:107`)

- **签名**：`pub fn toOwnedString(runtime_ptr: *JSRuntime, v: Value) ![]u8`。
- **作用**：取得独立文本字节切片：字符串走 UTF-8/WTF-8 编码，其他值走上述无 realm 格式化。
- **实现**：临时 ArrayList；`errdefer deinit`；`toOwnedSlice(runtime allocator)`。
- **所有权 / 错误 / 调用**：失败释放临时 buffer；成功切片由调用方用同一 Runtime allocator 释放。不是零终止字符串，可含 NUL 或 WTF-8 孤立代理编码；不保证是仅含 Unicode 标量的严格 UTF-8。

### `value.toIntegerOrInfinity` (`src/root.zig:118`)

- **签名**：`pub fn toIntegerOrInfinity(runtime_ptr: *JSRuntime, v: Value) !f64`。
- **作用**：转发同名 bare-runtime 数值转换助手；当前行为不能等同于完整 ToIntegerOrInfinity 抽象操作。
- **实现**：底层数值直接返回，BigInt 报 TypeError，布尔转 0/1，null 转 0，undefined 返回 NaN；其他值先无 realm 格式化，再 parseJsNumber。没有对小数截断，也没有把 NaN 归零。
- **所有权 / 错误 / 调用**：例如输入数值 1.5 仍返回 1.5。可能分配并返回错误，不执行完整对象 ToPrimitive；调用方不能仅依据函数名假设返回值一定是整数或无穷。

### `value.isTruthy` (`src/root.zig:122`)

- **签名**：`pub fn isTruthy(v: Value) bool`。
- **作用**：JS ToBoolean。
- **实现**：`value_ops.isTruthy(v)`。
- **所有权 / 错误 / 调用**：按值收 `Value`，不 retain、不建根、不分配；无 error set（ToBoolean 对任何值都有定义，不会触发 valueOf）。树内没有生产调用方——引擎内部直接调 `zjs_exec.value_ops.isTruthy`（如 `src/tests/exec.zig:5113`），这层只是嵌入面；`src/tests/embedding_examples.zig:968` 把它当公共 API 名单快照里的一项。

---

## `zjs.host`：CLI 形全局与 eval

### `host.defineScriptArgs` (`src/root.zig:135`)

- **签名**：`pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void`。
- **作用**：在 global 上定义 `scriptArgs` 字符串数组。
- **实现**：`object.defineStringArrayGlobal(ctx, "scriptArgs", args)`。空切片安装延迟初始化的空数组属性；非空切片先创建数组、逐项创建字符串并设置 length，再定义全局属性。数组原型优先取 realm 缓存，缺失时查找全局 `Array.prototype`。
- **所有权 / 错误 / 调用**：全局属性和数组元素使用 writable/enumerable/configurable 数据属性。获取全局对象、分配及属性定义的错误向上传播；覆盖已有属性仍受底层属性定义规则约束。

### `host.defineArgvGlobals` (`src/root.zig:139`)

- **签名**：`pub fn defineArgvGlobals(ctx: *JSContext, argv0: []const u8, exec_argv: []const []const u8) !void`。
- **作用**：定义 `argv0` 字符串和 `execArgv` 数组。
- **实现**：先定义 `argv0`，成功后才定义 `execArgv`；后一步失败不会撤销已经写入的 `argv0`。
- **所有权 / 错误 / 调用**：输入字节仅在调用期间借用，保存的是引擎创建的字符串。获取全局对象、分配和属性定义均可能失败。

### `host.evalGlobalScriptSource` (`src/root.zig:146`)

- **签名**：`pub fn evalGlobalScriptSource( ctx: *JSContext, output: ?*std.Io.Writer, global: *object.Object, source: []const u8, filename: []const u8, ) !value.Value`。
- **作用**：在指定 global 上当脚本求值源文（CLI 形）。
- **实现**：opaque → core 后 `evalGlobalScriptSourceCore`。
- **所有权 / 错误 / 调用**：执行层在 `ctx` 所属 runtime 中按 `global` 查找对应 context（也包括正在构造的 context），找不到返回 `InvalidBuiltinRegistry`；不要求 `global == ctx` 的全局对象。以 script 模式编译并返回 completion value，语法错误和执行错误向上传播。接口本身不会为返回值建立持久根。

### `host.evalGlobalScriptValue` (`src/root.zig:156`)

- **签名**：`pub fn evalGlobalScriptValue( ctx: *JSContext, output: ?*std.Io.Writer, global: *object.Object, source_value: value.Value, filename: []const u8, ) !value.Value`。
- **作用**：源文已是 JS 字符串时的同一条 eval。
- **实现**：非字符串 TypeError；`toOwnedString` + defer free；转 `evalGlobalScriptSource`。
- **所有权 / 错误 / 调用**：只接受字符串值，不对其他值调用 JavaScript 字符串转换。临时 UTF-8/WTF-8 字节使用 runtime allocator，求值成功或失败后均释放；转换分配和求值错误向上传播。

### `host.evalGlobalScriptSourceCore` (`src/root.zig:169`)

- **签名**：`fn evalGlobalScriptSourceCore( ctx: *JSContext, output: ?*std.Io.Writer, global: *CoreObject, source: []const u8, filename: []const u8, ) !value.Value`。
- **作用**：真正转发到 exec。
- **实现**：`zjs_exec.call.evalGlobalScriptSource(ctx.core, ...)`。
- **所有权 / 错误 / 调用**：内部转发，不另建 realm。执行层在最外层调用刷新 native stack top，按目标 global 的 realm 编译、创建根函数并使用临时 VM 栈运行；必要时切换和恢复词法环境，恢复操作本身也可能失败。

---

## `zjs.object`：opaque 对象与属性

内部指针转换和值解码把 opaque 对象接到 core。这些转换不复制对象，也不注册 GC 根；指针必须指向仍然有效的对应对象。

### `object.fromCore` (`src/root.zig:186`)

- **签名**：`fn fromCore(obj: *CoreObject) *Object`。
- **作用**：core → opaque。
- **实现**：`@ptrCast`。
- **所有权 / 错误 / 调用**：同一地址。

### `object.toCore` (`src/root.zig:190`)

- **签名**：`fn toCore(obj: *Object) *CoreObject`。
- **作用**：opaque → core。
- **实现**：`@ptrCast(@alignCast)`。
- **所有权 / 错误 / 调用**：供 object 方法转发使用；对齐转换不验证 runtime 归属或对象是否仍然存活。

### `object.optionalToCore` (`src/root.zig:194`)

- **签名**：`fn optionalToCore(obj: ?*Object) ?*CoreObject`。
- **作用**：可选指针转换。
- **实现**：null 保持 null。
- **所有权 / 错误 / 调用**：prototype 参数。

### `object.coreFromValue` (`src/root.zig:198`)

- **签名**：`fn coreFromValue(v: value.Value) ?*CoreObject`。
- **作用**：值若是 object 堆 tag 则取出。
- **实现**：`isObject` + `refHeader` + kind==`.object` + `Object.fromHeader`。
- **所有权 / 错误 / 调用**：非对象/非 object-kind（例如 bytecode）→ null。

### `object.toValue` (`src/root.zig:205`)

- **签名**：`pub fn toValue(obj: *Object) value.Value`。
- **作用**：对象 → JSValue（不 dup）。
- **实现**：`toCore(obj).value()`。
- **所有权 / 错误 / 调用**：返回指向同一对象的值，不是可写槽的引用，也不自动建立持久根。

### `object.arrayLength` (`src/root.zig:209`)

- **签名**：`pub fn arrayLength(obj: *Object) u32`。
- **作用**：读数组 length 槽。
- **实现**：`toCore(obj).arrayLength()`。
- **所有权 / 错误 / 调用**：不走 `[[Get]]`，非数组返回 0，不读取普通对象同名的 `length` 属性。

### `object.promiseResult` (`src/root.zig:213`)

- **签名**：`pub fn promiseResult(obj: *Object) ?value.Value`。
- **作用**：Promise 的 result 槽（fulfilled/rejected 值）。
- **实现**：core `promiseResult()`。
- **所有权 / 错误 / 调用**：无 Promise payload 时返回 null；有 payload 时直接返回其可选 result，不运行任务或等待完成，也不为结果建立持久根。

### `object.promiseIsRejected` (`src/root.zig:217`)

- **签名**：`pub fn promiseIsRejected(obj: *Object) bool`。
- **作用**：Promise 是否 rejected。
- **实现**：读取 Promise payload 的 `is_rejected`；无该 payload 时返回 false。
- **所有权 / 错误 / 调用**：无分配，不运行 Promise reaction。

### `object.forEachOwnDataProperty` (`src/root.zig:227`)

- **签名**：`pub fn forEachOwnDataProperty( rt: *JSRuntime, obj: *Object, visitor_context: anytype, comptime visitor: anytype, ) !void`。
- **作用**：按 shape 存储顺序访问其中已物化、可取得 atom 名称的数据属性；不是完整的 JavaScript 自有属性枚举。
- **实现**：并行走 `shapeProps()[i]`（flags+atom）和 `propertyEntry(i).slot`（值）。`Flags.fromBits`；`atom` 经 `rt.atoms.name` 拿字节（没有名字则 skip）。visitor 收到 `OwnDataProperty`。
- **所有权 / 错误 / 调用**：不筛除 non-enumerable 属性，而是在结果中携带 enumerable 标志。不会遍历独立存储的密集数组元素；整数编码的 atom 因 `atoms.name` 返回 null 而跳过，其他非 `.data` 槽也跳过。名称借用 atom 表字节，值按值传递但不注册根。visitor 的首个错误终止遍历，已执行的回调不回滚；实现持有 shape 切片且不制作快照，不能据此假定回调中改变对象属性布局是安全的。

---

## `object.Buffer`：TypedArray / ArrayBuffer

### `Buffer.isTypedArrayObject` (`src/root.zig:256`)

- **签名**：`pub fn isTypedArrayObject(obj: *Object) bool`。
- **作用**：检查是否具有已关联 buffer、元素宽度非零的 TypedArray payload。
- **实现**：转发 `buffer_ops.isTypedArrayObject`，底层检查 payload、`buffer != null` 和 `element_size != 0`；不检查 backing 是否 detached 或视图是否越界。
- **所有权 / 错误 / 调用**：只读 payload 字段，不分配、无 error set。`obj` 是借用指针，本函数既不 pin 也不建根，调用方要自己保证它在 GC 下存活。树内无调用方（纯嵌入 API）；`src/root.zig:569` 是字面重复的对象级同名包装。

### `Buffer.typedArrayByteLength` (`src/root.zig:260`)

- **签名**：`pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize`。
- **作用**：读取 TypedArray 当前缓存的有效字节长度。
- **实现**：`buffer_ops.typedArrayByteLength` → core 的 `typedArrayLength`，取 `payload.live_length` 再乘元素宽度。缺少 payload、buffer、backing payload 或元素宽度为零时返回 TypeError；此调用不单独检查 detach。
- **所有权 / 错误 / 调用**：底层忽略 rt，不据此验证 runtime 归属。长度依赖存储变更时维护的视图缓存，不能把成功返回当作借用字节仍然有效的证明。

### `Buffer.ownedBytesFromObject` (`src/root.zig:264`)

- **签名**：`pub fn ownedBytesFromObject(rt: *JSRuntime, obj: *Object) ![]u8`。
- **作用**：把对象的字节视图 **dupe** 一份给宿主。
- **实现**：`Bytes.fromObject`，失败经 `bufferViewError` 收成 TypeError；`allocator.dupe`。
- **所有权 / 错误 / 调用**：支持 ArrayBuffer、SharedArrayBuffer、TypedArray 和 DataView；视图仅复制其当前窗口，不复制整个 backing buffer。成功返回独立切片，调用者用 `rt.memory.allocator.free` 释放；复制分配可能失败。detach、越界等视图错误统一变成 TypeError。复制共享存储不提供并发一致性快照保证。

### `Buffer.createUint8ArrayFromBytes` (`src/root.zig:269`)

- **签名**：`pub fn createUint8ArrayFromBytes(rt: *JSRuntime, global: *Object, bytes: []const u8) !value.Value`。
- **作用**：拷贝字节造 Uint8Array。
- **实现**：按 global 查找已发布的 context，并从其 class prototype 表取 ArrayBuffer 和 Uint8Array 原型；创建定长 buffer、复制输入，再创建覆盖整个 buffer 的 Uint8Array。
- **所有权 / 错误 / 调用**：输入只在调用期间借用，成功后修改输入不影响新数组。找不到 context 或所需原型时返回 `InvalidBuiltinRegistry`；分配及构造错误向上传播。此路径不读取全局同名构造器的 `prototype` 属性。

### `Buffer.createUint8ArrayFromOwnedBytes` (`src/root.zig:274`)

- **签名**：`pub fn createUint8ArrayFromOwnedBytes(rt: *JSRuntime, global: *Object, bytes: []u8) !value.Value`。
- **作用**：**接管** runtime allocator 分配的字节，成功或失败都不再由调用方 free。
- **实现**：`errdefer` 在仍 owned 时 `rt.memory.free`。len > i32::MAX → RangeError。取 ArrayBuffer.prototype，`arrayBufferConstructLength`，`installByteStorage` 后 `bytes_owned=false`，再 `typedArrayConstructFullBufferOwned` 造 Uint8Array。
- **所有权 / 错误 / 调用**：`bytes` 必须来自 `rt.memory`，包括其内存记账约定，不能只因 allocator 相同就传入未经该接口分配的切片。安装存储前失败由 `errdefer` 释放；安装成功后字节归 buffer 管理，后续创建视图失败也不交还调用方。与复制版本不同，这里按全局构造器属性查找原型，属性查找和存储安装都可能失败。

### `Buffer.bufferViewError` (`src/root.zig:291`)

- **签名**：`fn bufferViewError(err: value.Bytes.Error) anyerror`。
- **作用**：Bytes 错误收成公共 TypeError。
- **实现**：TypeError/Detached/OutOfBounds/InvalidStore/ReadOnly 一律 `error.TypeError`。
- **所有权 / 错误 / 调用**：borrow/ownedBytes 入口。

### `Borrow.slice` (`src/root.zig:319`)

- **签名**：`pub fn slice(self: Borrow) []const u8`。
- **作用**：只读视图。
- **实现**：`self.ptr[0..self.len]`。
- **所有权 / 错误 / 调用**：只切出已记录的指针和长度，不重新验证 backing。源对象和存储必须保持有效；经过可能 detach/resize 的操作后，应重新获取借用描述符。

### `Borrow.sliceMut` (`src/root.zig:325`)

- **签名**：`pub fn sliceMut(self: Borrow) error{ReadOnly}![]u8`。
- **作用**：可写视图；不可变 ArrayBuffer → `error.ReadOnly`。
- **实现**：`mut_ptr orelse return error.ReadOnly`。
- **所有权 / 错误 / 调用**：只检查已保存的 `mut_ptr`，不重新验证 detach/resize。有效借用上的写入直接修改 backing；共享存储的读写同步需另行处理，此接口没有原子操作或锁。

### `Borrow.isMutable` (`src/root.zig:332`)

- **签名**：`pub fn isMutable(self: Borrow) bool`。
- **作用**：是否带可写指针。
- **实现**：`mut_ptr != null`。
- **所有权 / 错误 / 调用**：读 `Borrow` 值里的一个字段，不分配、无 error set，也不改变借用的生命周期：`Borrow` 本身是对活 backing store 的零拷贝借用且**不带 pin**，防 GC 释放要另外经 `pinForBorrow`（`src/root.zig:458`）拿 `BorrowGuard`（`src/root.zig:375`）。树内调用方只有本文件的借用测试（`src/root.zig:831`、`:930`）。

### `Borrow.isShared` (`src/root.zig:337`)

- **签名**：`pub fn isShared(self: Borrow) bool`。
- **作用**：背后是否 SharedArrayBuffer。
- **实现**：`self.shared`。
- **所有权 / 错误 / 调用**：同上：读 `shared` 字段，不分配、无 error set，不影响借用寿命。字段由构造借用时一次性填好，之后不随 buffer 状态变化（detach 不会翻转它）。树内调用方只有本文件的借用测试（`src/root.zig:832`）。

### `ReadonlyBorrow.slice` (`src/root.zig:358`)

- **签名**：`pub fn slice(self: ReadonlyBorrow) []const u8`。
- **作用**：只读视图。类型上没有 `sliceMut`/`mut_ptr`。
- **实现**：`ptr[0..len]`。
- **所有权 / 错误 / 调用**：与 Borrow 同一寿命约定。

### `ReadonlyBorrow.isShared` (`src/root.zig:363`)

- **签名**：`pub fn isShared(self: ReadonlyBorrow) bool`。
- **作用**：是否 SAB。
- **实现**：`self.shared`。
- **所有权 / 错误 / 调用**：同 `Borrow.isShared`：读字段，不分配、无 error set。`ReadonlyBorrow` 在类型层就没有 `mut_ptr` / `sliceMut`，所以这个谓词不构成任何写权限的判据。树内调用方只有本文件的只读借用测试（`src/root.zig:950`）。

### `BorrowGuard.release` (`src/root.zig:381`)

- **签名**：`pub fn release(self: *BorrowGuard) void`。
- **作用**：放下 view/buffer NativePin，幂等。
- **实现**：各 pin `deinit`，字段置 null。
- **所有权 / 错误 / 调用**：同一个 guard 实例可重复释放；不要复制有活跃 pin 的 guard 后分别释放。借阅作用域结束须调用，释放后不再提供 GC 保护。pin 不阻止 JS detach/resize。

### `Buffer.borrowKind` (`src/root.zig:391`)

- **签名**：`fn borrowKind(core_obj: *CoreObject) !BorrowKind`。
- **作用**：按 class 分类；其它对象 TypeError。
- **实现**：array_buffer/shared_array_buffer → `.array_buffer`；dataview → `.data_view`；TypedArray → `.typed_array`。
- **所有权 / 错误 / 调用**：`borrowBytes`。

### `Buffer.backingBufferCore` (`src/root.zig:403`)

- **签名**：`fn backingBufferCore(core_obj: *CoreObject) ?*CoreObject`。
- **作用**：字节实际所在的 ArrayBuffer/SAB 对象（TypedArray/DataView 要跟进去）。
- **实现**：自己就是 buffer 则返回 self；否则 `typedArrayBuffer()` → `coreFromValue`。
- **所有权 / 错误 / 调用**：pin/detach/backingArrayBufferValue。

### `Buffer.borrowBytes` (`src/root.zig:417`)

- **签名**：`pub fn borrowBytes(rt: *JSRuntime, obj: *Object) !Borrow`。
- **作用**：B3 零拷贝借阅，直接指向 live backing，不 dupe。detach 入口拒绝（TypeError）。
- **实现**：忽略 rt。`borrowKind` + `Bytes.fromObject`；array_buffer 的 byte_offset=0，view 用 `typedArrayByteOffset()`；拷 ptr/mut_ptr/len/shared。
- **所有权 / 错误 / 调用**：自身不 pin、不分配、不验证 runtime 归属；可用 `pinForBorrow` 保证借用期间对象存活。TypedArray/DataView 的长度按当前窗口派生，越界及 detach 等错误转换成 TypeError。可能重入 JS 后需用 `checkStillValid` 取得新的描述符。

### `Buffer.borrowBytesReadonly` (`src/root.zig:442`)

- **签名**：`pub fn borrowBytesReadonly(rt: *JSRuntime, obj: *Object) !ReadonlyBorrow`。
- **作用**：只读零拷贝：丢掉 mut_ptr。
- **实现**：`borrowBytes` 再填 ReadonlyBorrow 字段。
- **所有权 / 错误 / 调用**：与完整借用采用同一寿命约定。此返回类型不暴露可写指针或 `sliceMut`，但只读视图不冻结 backing，其他持有者仍可能改变其内容。

### `Buffer.pinForBorrow` (`src/root.zig:458`)

- **签名**：`pub fn pinForBorrow(rt: *JSRuntime, obj: *Object) !BorrowGuard`。
- **作用**：pin 视图对象；若字节在另一 ArrayBuffer 上再 pin 那一个。
- **实现**：`pinHeaderForNative` 两次；`errdefer guard.release()`。backing==self 不重复 pin。
- **所有权 / 错误 / 调用**：第二次 pin 失败时释放第一次 pin；成功后调用方须 `release()`。这里只固定对象存活，不校验它是否可借用、是否 detached 或越界，也不阻止 detach/resize；普通对象也可被此接口 pin。

### `Buffer.backingArrayBufferValue` (`src/root.zig:481`)

- **签名**：`pub fn backingArrayBufferValue(obj: *Object) ?value.Value`。
- **作用**：给宿主 detach/resize/检查真正的字节主人。非 buffer 对象 null。
- **实现**：`backingBufferCore` → `.value()`，**不 dup**。
- **所有权 / 错误 / 调用**：返回指向同一 backing 对象的值，不是可写槽引用，不注册 GC 根，也不检查 detached 状态。

### `Buffer.detachBackingBuffer` (`src/root.zig:492`)

- **签名**：`pub fn detachBackingBuffer(rt: *JSRuntime, obj: *Object) void`。
- **作用**：对可解析出的 backing buffer 调用 detach；没有 backing 时直接返回。
- **实现**：`backing.detachByteStorage(rt)`：若 payload 持有共享存储则直接返回；否则释放存储并标记 detached，此后公开借用接口返回 TypeError。
- **所有权 / 错误 / 调用**：不是 JavaScript 层 detach 操作的完整验证入口；此包装不检查 immutable 等限制。已有 pin 不阻止非共享 backing 的 detach，旧借用指针随之失效。

### `Buffer.checkStillValid` (`src/root.zig:506`)

- **签名**：`pub fn checkStillValid(rt: *JSRuntime, obj: *Object) !Borrow`。
- **作用**：重新派生 Borrow；已 detach 或窗口越界时返回 TypeError。resize 后读取当前指针和长度，并不保证原窗口仍可借用。
- **实现**：直接 `borrowBytes`。
- **所有权 / 错误 / 调用**：必须传入原来的源对象并使用返回的新描述符；它不接收旧 Borrow，不比较新旧指针，也不修复已复制出去的旧切片。调用期间仍须保证对象存活。

---

## 对象构造、谓词、属性写

### `object.createPlain` (`src/root.zig:511`)

- **签名**：`pub fn createPlain(rt: *JSRuntime) !*Object`。
- **作用**：创建原型为 null 的普通对象，不自动关联 realm 的 Object.prototype。
- **实现**：`Object.create(rt, class.ids.object, null)`。
- **所有权 / 错误 / 调用**：分配失败向上传播；返回 GC 管理的对象指针，不自动建立宿主持久根。

### `object.createError` (`src/root.zig:515`)

- **签名**：`pub fn createError(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：Error 对象，可选原型。
- **实现**：`class.ids.error_`。
- **所有权 / 错误 / 调用**：只创建指定 class 和原型的对象，不设置 message 或 stack；分配错误向上传播。原型为 null 时不自动寻找 Error.prototype。

### `object.createArray` (`src/root.zig:519`)

- **签名**：`pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：造 Array。
- **实现**：`Object.createArray`，可复用与指定原型匹配的初始 shape，否则创建 Array 并设置 fast-array 标志。
- **所有权 / 错误 / 调用**：返回空数组，原型由参数决定，null 不替换成 Array.prototype；分配错误向上传播。

### `object.createArrayValue` (`src/root.zig:523`)

- **签名**：`pub fn createArrayValue(rt: *JSRuntime, prototype: ?*Object) !value.Value`。
- **作用**：Array 的 JSValue。
- **实现**：`toValue(try createArray(...))`。
- **所有权 / 错误 / 调用**：**会分配**：`CoreObject.createArray` 在 GC 堆上新建 Array 对象，OOM 以 Zig error 向上传，这一层不写 pending exception、不转成 JS 异常。返回的 `Value` 既没 retain 也没 pin，宿主必须在下一次可能触发 GC 的操作前保住它（栈上副本靠保守栈扫描兜底）。树内无调用方，纯嵌入 API。

### `object.createArrayBuffer` (`src/root.zig:527`)

- **签名**：`pub fn createArrayBuffer(rt: *JSRuntime, prototype: ?*Object) !*Object`。
- **作用**：空 ArrayBuffer 对象（还没装 backing）。
- **实现**：`class.ids.array_buffer`。
- **所有权 / 错误 / 调用**：随后 `installByteStorage` 或 Buffer 助手。

### `object.fromValue` (`src/root.zig:531`)

- **签名**：`pub fn fromValue(v: value.Value) ?*Object`。
- **作用**：JSValue → opaque Object。
- **实现**：`coreFromValue` 再 `fromCore`。
- **所有权 / 错误 / 调用**：非对象 null。

### `object.isCallableValue` (`src/root.zig:535`)

- **签名**：`pub fn isCallableValue(v: value.Value) bool`。
- **作用**：识别列出的函数 class：c_function、c_function_data、async resume、bytecode 函数、c_closure 和 bound_function。
- **实现**：取出对象后比 class_id / `isAsyncFunctionResumeClass` / `isBytecodeFunctionClass`。
- **所有权 / 错误 / 调用**：无分配，不追踪 Proxy target，也不查询自定义 class 的调用钩子。因此不能把它当作覆盖所有对象的 JavaScript `IsCallable` 实现。

### `object.isPromiseObject` (`src/root.zig:545`)

- **签名**：`pub fn isPromiseObject(obj: *Object) bool`。
- **作用**：class 是否 promise。
- **实现**：`class_id == promise`。
- **所有权 / 错误 / 调用**：不走 Thenable。

### `object.isPromiseValue` (`src/root.zig:549`)

- **签名**：`pub fn isPromiseValue(v: value.Value) bool`。
- **作用**：值是否 Promise 对象。
- **实现**：`fromValue` + `isPromiseObject`。
- **所有权 / 错误 / 调用**：不分配、不建根、无 error set；非对象值在 `fromValue` 处直接返回 false，不解引用。只比 `class_id == promise`，因此 Proxy 包着的 promise 与 thenable 都报 false。树内无调用方。

### `object.isArray` (`src/root.zig:561`)

- **签名**：`pub fn isArray(v: value.Value) bool`。
- **作用**：`Array.isArray` 品牌（跟 Proxy 到终极 target）。普通对象、array-like、TypedArray 都是 false。revoked proxy 在这里当非数组（要 spec 的 TypeError 需另查）。
- **实现**：`core.array.isArrayValue(v) catch false`，无分配；除 revoked proxy 的 TypeError 外，Proxy 链超过核心深度限制产生的 StackOverflow 也被转换为 false。
- **所有权 / 错误 / 调用**：与 `JSContext.isArray`（可失败）不同。

### `object.isArrayBufferObject` (`src/root.zig:565`)

- **签名**：`pub fn isArrayBufferObject(obj: *Object) bool`。
- **作用**：是否 ArrayBuffer class（不含 SAB）。
- **实现**：`class_id == array_buffer`。
- **所有权 / 错误 / 调用**：只读 `class_id`，不分配、无 error set；不跟 proxy、不含 SharedArrayBuffer。树内无调用方——`src/core/bytes_view.zig:51`/`:229` 用的是 `bytes_view` 自己的同名私有谓词（`src/core/bytes_view.zig:233`），不是这一个。

### `object.isTypedArrayObject` (`src/root.zig:569`)

- **签名**：`pub fn isTypedArrayObject(obj: *Object) bool`。
- **作用**：对象级 TypedArray 谓词（与 Buffer 同名包装）。
- **实现**：`buffer_ops.isTypedArrayObject(toCore(obj))`。
- **所有权 / 错误 / 调用**：与 `Buffer.isTypedArrayObject`（`src/root.zig:256`）逐字相同：只读 payload 字段，不分配、无 error set，不 pin `obj`。两个拼写都是嵌入面，树内无调用方。

### `object.typedArrayByteLength` (`src/root.zig:573`)

- **签名**：`pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize`。
- **作用**：对象级字节长度。
- **实现**：同 Buffer 版本。
- **所有权 / 错误 / 调用**：不分配、不建根。error set 来自 `core.object.typedArrayLength`（`src/core/object.zig:11105`）：payload 缺失 / `element_size == 0` / `buffer == null` / `backing_payload == null` 一律 `error.TypeError`（detach 后走的就是这条），这层不把它变成 JS 异常，直接以 Zig error 交给嵌入方。树内无调用方；引擎内部直接用 `core.object.typedArrayByteLength`（`src/exec/array_ops.zig:1118`、`src/exec/vm_property_field.zig:671`）。

### `object.arrayBufferConstructLength` (`src/root.zig:577`)

- **签名**：`pub fn arrayBufferConstructLength(rt: *JSRuntime, len: usize, proto: ?*Object) !value.Value`。
- **作用**：按字节长度构造定长、非共享 ArrayBuffer；原型使用参数，不自动查询 realm。
- **实现**：`buffer_ops.arrayBufferConstructLength(rt, len, null, proto)`。
- **所有权 / 错误 / 调用**：字节初始化为零，长度超过 i32 最大值时返回 RangeError；分配或存储安装错误向上传播。传入的 max-byte-length 固定为 null，因此不创建可 resize 的 buffer。

### `object.typedArrayConstructFullBufferOwned` (`src/root.zig:581`)

- **签名**：`pub fn typedArrayConstructFullBufferOwned( rt: *JSRuntime, element_size: usize, kind: u8, buffer_value: value.Value, buffer: *Object, prototype: ?*Object, ) !value.Value`。
- **作用**：以偏移 0 创建覆盖整个已有定长 buffer 的 TypedArray 视图，不复制 backing 字节。
- **实现**：`buffer_ops.typedArrayConstructFullBufferOwned`，element_size `@intCast`。
- **所有权 / 错误 / 调用**：调用方应保证 `buffer_value` 与 `buffer` 指向同一有效 buffer，并提供匹配的 kind/element_size；包装不校验二者身份或 kind 与宽度的对应关系。element_size 必须可转换为 u32，超界不是可捕获的 RangeError。底层对零宽度、detached 或可 resize 的 buffer 返回 TypeError，对长度不能整除宽度或元素数超过 u32 返回 RangeError，分配错误向上传播。

### `object.atomFromUInt32` (`src/root.zig:592`)

- **签名**：`fn atomFromUInt32(index: u32) zjs_core.Atom`。
- **作用**：数组下标 atom，不 intern 字符串。
- **实现**：`atom.atomFromUInt32`。
- **所有权 / 错误 / 调用**：仅支持 `index <= atom.max_int_atom`（2³¹−1）；底层使用断言而非可捕获错误。它不是覆盖全部 u32 索引的转换，高位索引须走其他 atom 构造路径。

### `object.getProperty` (`src/root.zig:596`)

- **签名**：`pub fn getProperty(rt: *JSRuntime, obj: *Object, name: []const u8) !value.Value`。
- **作用**：按名字查询核心属性存储，每次先 intern 名称；不是执行层的完整 JavaScript `[[Get]]`。
- **实现**：`internAtom` + core `getProperty`。
- **所有权 / 错误 / 调用**：核心路径可沿原型链查找，缺失返回 undefined；auto-init 属性可能物化并失败，未初始化的 var-ref 返回 ReferenceError。accessor 槽返回其 getter 值，不执行 getter；此接口不进行执行层的 Proxy get 分派。名称 intern 也可能分配失败。

### `object.getOwnIndexPropertyValue` (`src/root.zig:601`)

- **签名**：`pub fn getOwnIndexPropertyValue(rt: *JSRuntime, obj: *Object, index: u32) !?value.Value`。
- **作用**：own 索引数据值；没有或无 value_present → null。
- **实现**：`getOwnProperty` + `desc.value_present`。
- **所有权 / 错误 / 调用**：不沿原型链查找，也不调用 accessor getter；底层可能使用 class 的 get-own-property hook 或物化 auto-init。存在且值为 undefined 的数据属性返回非 null 的 undefined，与属性不存在不同。index 须满足 tagged-int atom 的 2³¹−1 上限。

### `object.defineValueProperty` (`src/root.zig:609`)

- **签名**：`pub fn defineValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void`。
- **作用**：W/E/C 全 true 的数据属性。
- **实现**：`Descriptor.data(v, true, true, true)`。
- **所有权 / 错误 / 调用**：先 intern 名，再定义自有属性；不是赋值操作，不调用已有 setter。名称分配和底层属性定义错误向上传播，已有属性仍受描述符兼容性约束。

### `object.defineHiddenValueProperty` (`src/root.zig:614`)

- **签名**：`pub fn defineHiddenValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void`。
- **作用**：W/E/C 全 false。
- **实现**：`Descriptor.data(v, false, false, false)`。
- **所有权 / 错误 / 调用**：这是普通命名属性，仍能被直接读取或通过自有属性反射发现；“hidden”不表示引擎内部槽。属性定义及 intern 错误向上传播。

### `object.defineAccessorProperty` (`src/root.zig:619`)

- **签名**：`pub fn defineAccessorProperty( rt: *JSRuntime, obj: *Object, name: []const u8, getter: value.Value, setter: value.Value, ) !void`。
- **作用**：enumerable+configurable accessor。
- **实现**：`Descriptor.accessor(getter, setter, true, true)`。
- **所有权 / 错误 / 调用**：将 getter/setter 值交给底层描述符定义，包装本身不调用它们，也不进行 JavaScript ToPropertyDescriptor 转换。缺省 getter/setter 使用 undefined；名称 intern 和定义错误向上传播。

### `object.defineStringProperty` (`src/root.zig:630`)

- **签名**：`pub fn defineStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void`。
- **作用**：造字符串再 defineValueProperty。
- **实现**：`value.createString`。
- **所有权 / 错误 / 调用**：**两处分配**：`value.createString` 造 GC 字符串，`defineValueProperty` 里的 `rt.internAtom(name)` 可能新建 atom；两者都可能 OOM，以 Zig error 上传，不写 pending exception。中途失败时刚造出的字符串不显式释放，交给 GC 回收。属性按 writable/enumerable/configurable 全 true 定义。唯一树内调用方是 `host.defineArgvGlobals`（`src/root.zig:142`），给全局装 `argv0`。

### `object.defineHiddenStringProperty` (`src/root.zig:635`)

- **签名**：`pub fn defineHiddenStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void`。
- **作用**：隐藏字符串属性。
- **实现**：createString + defineHiddenValueProperty。
- **所有权 / 错误 / 调用**：所有权/错误同 `defineStringProperty`（造字符串 + intern atom，均可 OOM，失败对象交给 GC），差别只在走 `defineHiddenValueProperty`，三个属性位全 false。树内无调用方。

### `object.defineIntProperty` (`src/root.zig:640`)

- **签名**：`pub fn defineIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void`。
- **作用**：u16 → int32 可见属性。
- **实现**：`defineValueProperty(..., int32(v))`。
- **所有权 / 错误 / 调用**：`value.int32` 是立即数不分配；唯一的分配与失败点是 `defineValueProperty` 里的 `rt.internAtom(name)` 与 `defineOwnProperty` 的形状/存储增长，OOM 以 Zig error 上传。注意它与 `src/exec/closure.zig:270`、`src/exec/string_builtin_ops.zig:2215` 的同名私有函数不是一个东西，那两个才是引擎内部在用的；本函数树内无调用方。

### `object.defineHiddenIntProperty` (`src/root.zig:644`)

- **签名**：`pub fn defineHiddenIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void`。
- **作用**：隐藏 u16。
- **实现**：hidden + int32。
- **所有权 / 错误 / 调用**：同上：不分配值，失败点在 intern atom 与 `defineOwnProperty`，OOM 以 Zig error 上传；属性三个位全 false。树内无调用方。

### `object.defineStringArrayGlobal` (`src/root.zig:648`)

- **签名**：`pub fn defineStringArrayGlobal(ctx: *JSContext, name: []const u8, items: []const []const u8) !void`。
- **作用**：在 global 上定义字符串数组属性。
- **实现**：空 items → `defineEmptyArrayGlobal`（auto-init）。否则取 Array.prototype（cached 或 constructor 查找），`createArrayWithOwnPropertyCapacity`，按下标 define 字符串，`setArrayLength`，再 define 到 global。
- **所有权 / 错误 / 调用**：供 `scriptArgs` / `execArgv` 使用。非空路径在新数组构造完后才写入全局属性；输入字节只在调用期间借用。索引使用受 2³¹−1 上限约束的 tagged-int atom，长度也需能转换为 u32，不能据参数为 usize 就认定接受任意长度。

### `object.cachedArrayPrototype` (`src/root.zig:668`)

- **签名**：`fn cachedArrayPrototype(rt: *JSRuntime, global: *Object) ?*Object`。
- **作用**：realm 缓存的 Array.prototype。
- **实现**：`cachedRealmValue(.array_prototype)` → `coreFromValue`。
- **所有权 / 错误 / 调用**：找不到对应 context（包括构造中的 context）、缓存为空或缓存值不是对象时返回 null；不主动物化原型，调用方可再查构造器。

### `object.defineEmptyArrayGlobal` (`src/root.zig:673`)

- **签名**：`fn defineEmptyArrayGlobal(ctx: *JSContext, name: []const u8) !void`。
- **作用**：将全局属性定义为延迟创建空数组的 auto-init 槽，绑定当前 global 的 realm。
- **实现**：`defineEmptyArrayAutoInitProperty`，flags 全 true，holder 是 global。
- **所有权 / 错误 / 调用**：覆盖已有槽前检查 configurable，否则返回 IncompatibleDescriptor。底层要求 holder 具有普通可扩展的命名属性存储；realm 槽创建、shape 准备和属性分配可能失败。此处不预先创建数组。

### `object.constructorPrototypeObject` (`src/root.zig:681`)

- **签名**：`pub fn constructorPrototypeObject(rt: *JSRuntime, global: *Object, name: []const u8) !?*Object`。
- **作用**：`global[name].prototype` 对象。
- **实现**：intern 名 + `constructorPrototypeObjectByAtom`。
- **所有权 / 错误 / 调用**：公共入口用字节名。

### `object.constructorPrototypeObjectByAtom` (`src/root.zig:690`)

- **签名**：`fn constructorPrototypeObjectByAtom(_: *JSRuntime, global: *Object, key: zjs_core.Atom) !?*Object`。
- **作用**：已有 atom 的同一查找（标准构造器免 intern）。
- **实现**：`global.getProperty(key)` → 取 `prototype` → `fromValue`。忽略 rt。
- **所有权 / 错误 / 调用**：内部助手；构造器值或 prototype 不是对象时返回 null，不验证构造器是否 callable。两次查找都采用 core `getProperty`，可沿原型链并物化 auto-init，但不会执行 accessor getter；查找错误直接传播。

### `object.appendArrayValue` (`src/root.zig:697`)

- **签名**：`pub fn appendArrayValue(rt: *JSRuntime, array: *Object, v: value.Value) !void`。
- **作用**：读取核心 array length，并在该索引定义 W/E/C 全 true 的数据属性。
- **实现**：`defineOwnProperty(atomFromUInt32(arrayLength()), Descriptor.data(v, true, true, true))`。
- **所有权 / 错误 / 调用**：依赖底层定义操作维护数组 length，不再手工加一；受 length 可写性、属性兼容性和分配错误约束。包装没有 Array 品牌检查，非数组的核心 arrayLength 为 0，因此会尝试定义索引 0。当前 length 必须在 tagged-int atom 的 2³¹−1 上限内。

---

## `zjs.context` / `module` / `job`

### `context.globalObject` (`src/root.zig:1007`)

- **签名**：`pub fn globalObject(ctx: *JSContext) !*object.Object`。
- **作用**：公共 opaque 版全局对象。
- **实现**：`object.fromCore(try ctx.globalObject())`。
- **所有权 / 错误 / 调用**：binding 先确保标准全局注册，再调用 VM 的 context-global 获取/物化路径；可能分配并失败。转换只改变指针类型，不新建第二个全局对象，也不建立持久根。

### `context.callFunction` (`src/root.zig:1011`)

- **签名**：`pub fn callFunction( ctx: *JSContext, callee: value.Value, args: []const value.Value, options: @This().FunctionCallOptions, ) !value.Value`。
- **作用**：把 opaque `realm_global` 转成 core 再调门面 `callFunction`。
- **实现**：原样转发 this_value/output，并用 `optionalToCore` 转换 realm_global。未提供 this_value 时底层使用 undefined；未指定 global 时底层获取 context 的全局对象。
- **所有权 / 错误 / 调用**：通过 binding 的一次性 CallSite 路径调用，执行和全局物化错误向上传播。此包装不复制 args、不保存可复用 CallSite，也不自动为宿主堆中保存的 callee、receiver 或参数数组建立根；调用方须满足宿主值的存活约定。

### `module.evalFileGraphWithHost` (`src/root.zig:1033`)

- **签名**：`pub fn evalFileGraphWithHost( ctx: *JSContext, source_text: []const u8, output: *std.Io.Writer, filename: []const u8, host_hooks: Host, allocator: std.mem.Allocator, ) !value.Value`。
- **作用**：按宿主 resolve/load 钩子求值文件模块图。
- **实现**：`module_graph.evalFileModuleGraphWithHostHooks(ctx.runtimePtr(), ctx.core, ...)`。
- **所有权 / 错误 / 调用**：host_hooks 的 resolve/load 由宿主提供，allocator 用于图遍历及临时列表等分配。执行层预加载并链接模块，标记根模块的 import.meta.main，按依赖顺序启动求值并处理异步 continuation；调用期间临时安装 dynamic-import loader，退出时恢复，返回前还会排空相关 jobs。加载、链接、执行或 job 错误可使整个调用失败，已发生的模块副作用不回滚；这不是只编译模块的接口。

### `job.drain` (`src/root.zig:1054`)

- **签名**：`pub fn drain(ctx: *JSContext, options: DrainOptions) !DrainResult`。
- **作用**：按条数预算处理 runtime 的 job FIFO（包括普通宿主 job 和 Promise 相关 job），成功返回处理数量和当前队列是否仍非空。
- **实现**：budget 默认为 usize 最大值；0 时只查队列，不物化全局或处理到期 Atomics waiter。非零时先获取 global，再循环 `drainOnePendingJob`：empty 停、success 计数、exception 返回 JSException，其他错误直接传播。每次处理使用 job 入队时保存的 realm；单步入口还会处理到期 Atomics waiter，因此可产生额外待处理任务。
- **所有权 / 错误 / 调用**：预算是成功处理的 job 条数，不是时间或内存限额；新入队任务也可能在本轮执行。失败时没有部分 DrainResult，此前副作用不回滚；部分可重试的内部 OOM 路径会把当前条目放回队首。has_more 只看实际 job_queue，不包含尚未到期的等待、宿主事件循环或 deferred cleanup，不能据 false 判定整个 runtime 空闲。此接口传入 null output。

### `job.hasPending` (`src/root.zig:1076`)

- **签名**：`fn hasPending(ctx: *zjs_core.JSContext) bool`。
- **作用**：队列是否还有 job。
- **实现**：`ctx.runtime.job_queue.hasJobs()`。
- **所有权 / 错误 / 调用**：只查询与 context 关联的 runtime 队列，不限于该 context 的 job；不执行任务或刷新到期等待者。

### `TestJob.append` (`src/root.zig:1089`)

- **签名**：`fn append(core_ctx: *zjs_core.JSContext, args: []const zjs_core.JSValue) zjs_core.JSValue`。
- **作用**：budget 测试：把 ordinal 追加到观察数组。
- **实现**：`appendDenseArrayDefineIndex`；失败 throw int 哨兵。
- **所有权 / 错误 / 调用**：`enqueueFunc`。

### `TestJob.fail` (`src/root.zig:1129`)

- **签名**：`fn fail(core_ctx: *zjs_core.JSContext, _: []const zjs_core.JSValue) zjs_core.JSValue`。
- **作用**：drain 在第一异常停下。
- **实现**：`throwValue(int32(73))`。
- **所有权 / 错误 / 调用**：队列里后面还有 succeed。

### `TestJob.succeed` (`src/root.zig:1133`)

- **签名**：`fn succeed(_: *zjs_core.JSContext, _: []const zjs_core.JSValue) zjs_core.JSValue`。
- **作用**：异常之后仍留在队列的尾巴。
- **实现**：返回 undefined。
- **所有权 / 错误 / 调用**：第二次 drain 跑它。

### `Probe.run` (`src/root.zig:1163`)

- **签名**：`fn run(core_ctx: *zjs_core.JSContext, _: []const zjs_core.JSValue) zjs_core.JSValue`。
- **作用**：证明 job 在入队 Realm 执行，即使宿主门面已 destroy。
- **实现**：`seen = core_ctx`。
- **所有权 / 错误 / 调用**：队列 entry 持 RealmRef。
