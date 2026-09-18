# 15 — `array_builtin_ops.zig`：Array record 表与过渡实现

`array_builtin_ops.zig` 是 `.array` native-builtin 域的声明表（QuickJS `js_array_funcs` / `js_array_proto_funcs` 对照）。

## 类型

- `RootedValueCopies`：把调用方的 `[]JSValue` 按位复制到新缓冲，再为每个元素做 `ValueRootValue`。只给 GC 稳定地址；`deinit` 释放缓冲，不 free 那些 JSValue。
- `StaticMethod` / `PrototypeMethod` / `ConstructorMethod`：re-export `core.host_function.builtin_method_ids.array`。
- `internal_entries`：comptime 表。push/pop/splice 用专用 handler + 可选 `exec_direct`；其余走 `arrayCall`。
- `ArrayIteratorKind`：key / value / key_value。
- `SearchMode`：first / includes / last（过渡搜索）。
- `SortEntry`：过渡 sort 的 `{value, key}`。
- `BigIntParts`：短/堆 bigint 的符号+limbs 视图。

`methodCall` / `filterEven` 等是过渡字节码与夹具的窄实现（写死谓词、无用户回调），不是 `array_ops.arrayIterationCall` 那条 spec 路径。

### `RootedValueCopies.init` (`src/exec/array_builtin_ops.zig:29`)

- **签名**：`fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies`。
- **作用**：把调用方的值按位复制到自有缓冲，并为每个副本准备一条 `ValueRootValue` 根条目。
- **实现**：先 `memory.alloc` 与 `source` 等长的 `JSValue` 缓冲并 `@memcpy`，再 alloc 等长的 `ValueRootValue` 数组，逐个填 `.value = &values[i]`；两次分配各带 `errdefer` free。本函数只准备根条目，激活 `ValueRootFrame` 是调用方的事。关键调用：`memory.alloc`、`memory.free`、`@memcpy`。
- **所有权 / 错误 / 调用**：两块缓冲由 `rt.memory` 分配，所有权随返回值交给调用方，只能由 `deinit` 释放；`values` 里的 JSValue 只是调用方值的位拷贝，不 retain、也不负责释放。error set 只有分配的 `error.OutOfMemory`，两次 alloc 各带 `errdefer`，失败时不留半块缓冲。本函数只填 `roots` 条目，激活 `ValueRootFrame` 之前对 tracer 不可见；调用方 `constructWithPrototype`（:541）、`concat`（:1243）。

### `RootedValueCopies.deinit` (`src/exec/array_builtin_ops.zig:43`)

- **签名**：`fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void`。
- **作用**：释放本结构持有的两块缓冲；不释放调用方拥有的 JSValue。
- **实现**：依次 `memory.free` `roots` 与 `values`，不碰这些 JSValue，也不 deactivate root frame。
- **所有权 / 错误 / 调用**：只 `rt.memory.free` 两块缓冲；JSValue 本身归调用方，不 release。无 error set。次序有硬约束：必须先 `root_frame.deactivate(rt)` 再 deinit，否则根帧会指向已释放内存——两处调用方（:541、:1243）靠 `defer` 的后进先出兑现这一点。

### `staticMethodId` (`src/exec/array_builtin_ops.zig:53`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：把静态方法名映射成域内 id，供 standard-global 安装与 record 分发。
- **实现**：关键调用：`mem.eql`。
- **所有权 / 错误 / 调用**：无：名字→id 的 comptime 可折叠查表，不分配、无 error set、不碰 GC。生产调用方只有 `exec/standard_globals.zig:301`（安装 `Array` 静态方法时把 id 写进 method 的 native builtin ref），其余命中在 `core/host_function.zig` 的测试块。

### `prototypeMethodId` (`src/exec/array_builtin_ops.zig:61`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把原型方法名映射成域内 id。
- **实现**：关键调用：`mem.eql`。
- **所有权 / 错误 / 调用**：无分配、无 error set。调用方三处，全在 `exec/standard_globals.zig`：`:303`（批量安装 `Array.prototype` 方法 id）、`:3299`（取 `concat` 的 id 造 native ref）、`:3597`（取 `values` 的 id）。

### `arrayEntry` (`src/exec/array_builtin_ops.zig:192`)

- **签名**：`fn arrayEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：给 `Array.from`/`fromAsync`/`isArray`/`of` 以及绝大多数 `Array.prototype` 方法（`map`/`filter`/`sort`/`join`/`slice`/`keys` 等四十余条）批量生成注册表条目；它们共用 `arrayCall` 一个 handler，靠 magic 里的 record id 区分到底是哪个 JS 方法。
- **实现**：整体转发 `arrayEntryWithHandler(name, length, id, &arrayCall)`，不动 `entry.managed`——因此这批方法没有 NMFD 直调臂，一律走 `generic_magic` 的完整 host-call 视图（需要函数对象来区分 Array 与 `%TypedArray%` 的同名 id、读 species 与回调）。
- **所有权 / 错误 / 调用**：comptime-only：返回值按值拷进 `internal_entries`（`:137`-`:190` 的 43 条记录里 39 条由它生成），不分配、无 error set、运行期没有调用方。handler 固定 `&arrayCall`，`entry.managed` 留空——因此这 39 条一律经 `native_legacy.managedGenericMagic` thunk 进入。

### `arrayPushEntry` (`src/exec/array_builtin_ops.zig:196`)

- **签名**：`fn arrayPushEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：`Array.prototype.push` 的注册表条目：除专用 record handler 外还挂一条解释器可直接 `blr` 的 `managed` 函数指针。
- **实现**：先用 `arrayEntryWithHandler(name, length, id, &arrayPushCall)` 造出 generic_magic 条目，再把 `entry.managed` 设成 `&arrayPushDirect`，给 NMFD 的 `exec_direct` 直调臂用（源码注释引用 qjs `js_call_c_function`，quickjs.c:17563：那条 ABI 没有 env 旁路）。关键调用：`arrayEntryWithHandler`。
- **所有权 / 错误 / 调用**：comptime-only，唯一求值点是表里的 `arrayPushEntry("push", ...)`（`:158`）。设了 `entry.managed` 的后果在 `native_legacy.entryFromInternal`（`:172`-`:176`）：有 managed 就直接把它当 `NativeEntry.target`、`needs_env = false`，于是 `arrayPushCall` 那层 generic_magic 包装只在非直调路径上还活着。

### `arrayPopEntry` (`src/exec/array_builtin_ops.zig:205`)

- **签名**：`fn arrayPopEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：`Array.prototype.pop` 的注册表条目：handler 换成专用的 `arrayPopCall`，不再进共享 `arrayCall` 的 magic switch。
- **实现**：转发 `arrayEntryWithHandler(name, length, id, &arrayPopCall)`。与 push/splice 不同，这里不设 `entry.managed`，所以 pop 只有专用慢臂、没有直调臂（由测试 `"Array.pop has a dedicated native record handler"` 钉住 handler 身份）。
- **所有权 / 错误 / 调用**：comptime-only，唯一求值点 `:159`。与 push/splice 的差别是不设 `entry.managed`，所以 pop 只有 `managedGenericMagic(&arrayPopCall)` 一条臂，没有 NMFD 直调入口（测试 `:257` 钉住 handler 身份）。

### `arraySpliceEntry` (`src/exec/array_builtin_ops.zig:209`)

- **签名**：`fn arraySpliceEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：`Array.prototype.splice` 的注册表条目：专用 handler `arraySpliceCall` 加解释器直调臂 `arraySpliceDirect`，与 push 同待遇。
- **实现**：在 `arrayEntryWithHandler(name, length, id, &arraySpliceCall)` 之上再把 `entry.managed` 设成 `&arraySpliceDirect`。
- **所有权 / 错误 / 调用**：comptime-only，唯一求值点 `:175`；与 `arrayPushEntry` 同形，`entry.managed = &arraySpliceDirect` 让 splice 也拿到 NMFD 直调臂（测试 `:244` 钉住两个指针身份）。

### `arrayEntryWithHandler` (`src/exec/array_builtin_ops.zig:215`)

- **签名**：`fn arrayEntryWithHandler( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, ) core.host_function.InternalEntry`。
- **作用**：填出 `.array` 域的 `InternalEntry`：`magic = @intCast(id)`、`cproto = .generic_magic`、`native_function = builtin_dispatch.genericMagicFunction(handler)`。
- **实现**：关键调用：`builtin_dispatch.genericMagicFunction`。
- **所有权 / 错误 / 调用**：comptime-only 的结构体字面量，不分配、无 error set；全部调用方就是上面四个 builder（`:193`、`:197`、`:206`、`:210`）。`handler` 被 `genericMagicFunction` 包成 `.generic_magic` 变体存进 `native_function`，真正的取用发生在 `internal_builtins.zig:53` 的 `entryFromInternal`。

### `arrayConstructorEntry` (`src/exec/array_builtin_ops.zig:269`)

- **签名**：`fn arrayConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：`Array` 构造器自身的注册表条目，做成 construct-capable，使 `new Array(...)` 与以函数形式调用的 `Array(...)` 都落到 `arrayCall` 的 construct 分支。
- **实现**：不复用 `arrayEntryWithHandler`，直接字面量填 `InternalEntry`：`magic = @intCast(id)`、`cproto = .constructor_or_func_magic`、`native_function = builtin_dispatch.constructorOrFunctionMagic(&arrayCall)`。按 `internal_entries` 表上的注释，全局 `Array` 构造器对象并不是以这个 native id 安装的（call-as-function 与 species 识别仍走名字 + `arrayBuiltinMarker`），所以这条 record 只在 `builtin_dispatch.callConstructRecord` 拿到显式 ref 时才被走到。
- **所有权 / 错误 / 调用**：comptime-only，唯一求值点是表首行 `:144`；与 `arrayEntryWithHandler` 的差别只在 `cproto = .constructor_or_func_magic`，`native_legacy` 据此把 `NativeEntry.kind` 设成 `.constructor_or_func`，也因此不允许再挂 `managed` 直调臂。

### `arrayPrototypeFromGlobal` (`src/exec/array_builtin_ops.zig:284`)

- **签名**：`fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object`。
- **作用**：从 realm 缓存 `cachedRealmValue(.array_prototype)` 取默认 `Array.prototype`，给 `Array(...)` 以函数形式调用时的构造回退用；缓存未填或不是对象返回 null（调用方改用引擎默认原型）。
- **实现**：薄封装，主体转发到 `global.cachedRealmValue`、`stored.isObject`、`stored.refHeader`、`Object.fromHeader`。
- **所有权 / 错误 / 调用**：返回借用指针：realm 缓存持有那个原型对象，调用方既不 retain 也不得释放；缓存未填或不是对象返回 null（调用方改用引擎默认原型）。无 error set。唯一调用方是 `arrayCall`（`:333`）的 call-as-function 构造回退。注意与 `exec/array_ops.zig:133` 的同名函数不是一回事：那个在缓存落空时还会退一步去查 `global.Array.prototype`。

### `arrayCall` (`src/exec/array_builtin_ops.zig:302`)

- **签名**：`fn arrayCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.array` 域的共享 record handler：把 record id 转给 `builtin_glue.arrayNativeRecord`；construct id 例外。
- **实现**：construct id 走 `constructConstructorWithPrototype`（单数字参数是 length，非法则 RangeError）。其余 `builtin_glue.arrayNativeRecord`；push/pop/splice 不进这个 handler。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：树内没有 Zig 调用方：它只以 `&arrayCall` 的函数指针身份进 39 条 `arrayEntry` 记录和构造器记录，运行期由 `native_legacy.managedGenericMagic`（`native_legacy.zig:94`）thunk 调用，thunk 用 `builtin_dispatch.hostResultToValue` 把返回的 `HostError` 变成 pending JS 异常 + 异常哨兵值。`native_this`/`native_args` 是 VM 栈上的借用（栈帧已是根），返回值 owned。error set：拿不到 native 调用环境或 glue 返回 null → `error.TypeError`；`callableRealm` 失败 → `error.InvalidBuiltinRegistry`；构造臂的 `error.RangeError` 在有 global 时就地换成带 `"invalid array length"` 消息的 JS RangeError，没有 global 才裸抛（由 `materializeRuntimeError` 补默认消息）。

### `arrayPushCall` (`src/exec/array_builtin_ops.zig:363`)

- **签名**：`fn arrayPushCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Array.prototype.push` 的专用 record handler：直调臂 `arrayPushDirect` 未命中（或调用方根本不走直调 ABI）时的完整上下文入口。
- **实现**：`builtin_dispatch.nativeCall` 取原子调用视图，为 null（record 损坏 / 无法识别）即 `error.TypeError`；`callableRealm` 解析调用方 realm 并断言 `realm.realm == host_call.ctx`；随后把 `output`、`realm.global`、`this_value`、`args` 以及 `callerBytecode`/`callerFrame` 一起交给 `builtin_glue.arrayPushNativeRecord`，glue 返回 null 时转 `error.TypeError`。相对共享 `arrayCall`，这里省掉了 magic switch 和重复的函数对象识别，但 proxy / 访问器 / 跨 realm 行为所依赖的 output、global、caller 透传一个不少。
- **所有权 / 错误 / 调用**：同样没有 Zig 调用方：进 `internal_entries` 的 push 记录，只在 NMFD 直调臂不可用（或调用方不走直调 ABI）时经 `managedGenericMagic` thunk 走到，错误由 thunk 的 `hostResultToValue` 转成 JS 异常。this/args 借用，返回值 owned，本函数自身不分配也不建根。error set：无 native 环境或 glue 返回 null → `error.TypeError`；`callableRealm` → `error.InvalidBuiltinRegistry`；其余由 `builtin_glue.arrayPushNativeRecord`（= `array_ops.arrayPushCallImpl`）透传。

### `arrayPushDirect` (`src/exec/array_builtin_ops.zig:383`)

- **签名**：`fn arrayPushDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：NMFD/`exec_direct` C ABI 入口：无 TLS magic mux，失败转 JS 异常值。
- **实现**：`ctx.global` 为空直接把 `error.InvalidBuiltinRegistry` 转成异常值；再从 `vmCallerView(ctx)` 取 output 与 caller function/frame。热臂 `builtin_glue.tryFastArrayPush` 命中就返回 `JSValue.int32(new_len)`（寄存器返回，对齐 qjs `JS_NewInt32`），它自身报错走 `hostErrorToValue`，返回 null（miss/OOM）则落到 `arrayPushDirectHost` 再经 `hostResultToValue`。关键调用：`builtin_dispatch.hostErrorToValue`、`builtin_dispatch.vmCallerView`、`builtin_glue.tryFastArrayPush`、`JSValue.int32`、`builtin_dispatch.hostResultToValue`。错误：error.InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：`callconv(.c)` 直调 ABI，不返回 Zig error：所有失败就地经 `hostErrorToValue` / `hostResultToValue` 挂上 pending 异常并返回异常哨兵 JSValue（`ctx.global` 为空时是 `error.InvalidBuiltinRegistry`）。调用方不是 Zig 代码——`native_legacy.entryFromInternal`（`:172`）把 `entry.managed` 直接当 `NativeEntry.target`，由 VM 的 NMFD/`exec_direct` 臂 `blr` 进来。`argv[0..argc]` 借用调用方的参数窗口，返回值 owned；热臂命中时返回的是立即数 int32，不涉及堆。

### `arrayPushDirectHost` (`src/exec/array_builtin_ops.zig:415`)

- **签名**：`fn arrayPushDirectHost( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：exec_direct 热路径落到带 realm/caller 的 HostError 实现。
- **实现**：关键调用：`builtin_glue.arrayPushNativeRecord`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：私有，唯一调用方是 `arrayPushDirect`（`:404`）；它保留 `HostError` 不自己转异常，留给调用方的 `hostResultToValue` 统一处理。不分配、不建根，值的根由 VM 帧和 glue 里的实现负责。error set：glue 返回 null → `error.TypeError`，其余由 `arrayPushNativeRecord` 透传。

### `arraySpliceCall` (`src/exec/array_builtin_ops.zig:435`)

- **签名**：`fn arraySpliceCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Array.prototype.splice` 的专用 record handler，直调臂 `arraySpliceDirect` 之外的完整上下文入口。
- **实现**：形状与 `arrayPushCall` 相同：`nativeCall` 取调用视图（null → TypeError）→ `callableRealm` + `assert(realm.realm == host_call.ctx)` → `builtin_glue.arraySpliceNativeRecord(ctx, output, realm.global, this_value, args)`，null 结果转 `error.TypeError`。差别在于不透传 `callerBytecode`/`callerFrame`：splice 的 record 体不消费调用方内联缓存提示。
- **所有权 / 错误 / 调用**：与 `arrayPushCall` 同形的记录 handler，无 Zig 调用方，经 `managedGenericMagic` thunk 进入、由 `hostResultToValue` 转异常。差别是 `builtin_glue.arraySpliceNativeRecord` 不收 caller bytecode/frame，所以这条路径不透传内联缓存提示。error set：`error.TypeError`（无 native 环境 / glue 返回 null）、`error.InvalidBuiltinRegistry`（`callableRealm`）与 impl 透传。

### `arraySpliceDirect` (`src/exec/array_builtin_ops.zig:453`)

- **签名**：`fn arraySpliceDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：NMFD/`exec_direct` C ABI 入口：无 TLS magic mux，失败转 JS 异常值。
- **实现**：`ctx.global` 为空先把 `error.InvalidBuiltinRegistry` 转成异常值；从 `vmCallerView(ctx)` 取 output（caller function/frame 取到后被显式丢弃，splice 不需要），再把 `arraySpliceDirectHost` 的结果过 `hostResultToValue`。关键调用：`builtin_dispatch.hostErrorToValue`、`builtin_dispatch.vmCallerView`、`builtin_dispatch.hostResultToValue`、`arraySpliceDirectHost`。错误：error.InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：同 `arrayPushDirect` 的直调 ABI 与异常约定（`ctx.global` 为空 → `error.InvalidBuiltinRegistry` 转哨兵值），但没有 fast-path 热臂，直接 `hostResultToValue(arraySpliceDirectHost(...))`；`vmCallerView` 取出的 caller function/frame 随即被 `_ =` 丢弃，因为 splice glue 不接这两个参数。

### `arraySpliceDirectHost` (`src/exec/array_builtin_ops.zig:478`)

- **签名**：`fn arraySpliceDirectHost( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：exec_direct 热路径落到带 realm/caller 的 HostError 实现。
- **实现**：关键调用：`builtin_glue.arraySpliceNativeRecord`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：私有，唯一调用方 `arraySpliceDirect`（`:469`）；不分配不建根，glue 返回 null → `error.TypeError`，其余透传，异常转换留给调用方。

### `arrayPopCall` (`src/exec/array_builtin_ops.zig:498`)

- **签名**：`fn arrayPopCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Array.prototype.pop` 的专用 record handler，对应 qjs `js_array_pop(..., shift = 0)` 那一支。
- **实现**：`nativeCall` 取调用视图（null → TypeError）→ `callableRealm` + assert → `builtin_glue.arrayPopNativeRecord(ctx, output, realm.global, this_value, callerBytecode, callerFrame)`，null 转 `error.TypeError`。不传 `host_call.args`——pop 不吃参数。按函数头注释，稠密数组快臂与可观测的 length 读写 / 取属性 / delete 慢路径都在被调用的 record 体内，这里只负责进入。
- **所有权 / 错误 / 调用**：pop 唯一的 native 入口（记录里没有 managed 直调臂），无 Zig 调用方，经 `managedGenericMagic` thunk 进入并由 `hostResultToValue` 转异常。this 借用、返回值 owned；error set 为 `error.TypeError`（无 native 环境 / glue 返回 null）、`error.InvalidBuiltinRegistry`（`callableRealm`）与 `arrayPopNativeRecord` 透传。

### `construct` (`src/exec/array_builtin_ops.zig:523`)

- **签名**：`pub fn construct(rt: *core.JSRuntime, values: []const core.JSValue) !core.JSValue`。
- **作用**：分配并初始化对应的 JS 对象或数组。
- **实现**：单行转调 `constructWithPrototype(rt, values, null)`，即用 realm 默认 `Array.prototype`。真正的活在被调方：`RootedValueCopies` 复制并钉住入参、`createArray` + `errdefer destroyFromHeader`、`reserveDenseArrayElements` 预留，再逐个先试 `appendDenseArrayDefineIndex`（dense 快路）、失败才退到 `defineOwnProperty`。
- **所有权 / 错误 / 调用**：返回 owned 数组值，`values` 只借用。error set 全部来自 `constructWithPrototype`（分配 OOM、`defineOwnProperty` 失败），不做任何 JS 异常映射——它是 bare-runtime API，没有 `ctx`。**生产树内无调用方**：只有 `src/tests/exec.zig:7887` 在用；数组字面量 opcode 走的是 `core/array.zig` 的 `constructLiteralWithPrototype`。

### `constructConstructorWithPrototype` (`src/exec/array_builtin_ops.zig:527`)

- **签名**：`pub fn constructConstructorWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：分配并初始化对应的 JS 对象或数组。
- **实现**：QuickJS 坐标：quickjs.c:9447-9455。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。关键调用：`isNumber`、`arrayLengthFromNumber`、`Object.createArray`、`Object.destroyFromHeader`、`object.gcHeader`、`Array`、`set_array_length`、`object.setArrayLength`。错误：error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 数组值；`prototype` 是借用指针（realm 缓存或 new_target 持有）。`new Array(n)` 臂在 `createArray` 之后用 `errdefer core.Object.destroyFromHeader` 回收半成品。error set：非法长度 → `error.RangeError`，由唯一调用方 `arrayCall`（`:336`）翻成带消息的 JS RangeError；其余透传 `constructWithPrototype`。

### `constructWithPrototype` (`src/exec/array_builtin_ops.zig:541`)

- **签名**：`pub fn constructWithPrototype(rt: *core.JSRuntime, values: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：分配并初始化对应的 JS 对象或数组。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`RootedValueCopies.init`、`rooted.deinit`、`root_frame.activate`、`root_frame.deactivate`、`Object.createArray`、`Object.destroyFromHeader`、`object.gcHeader`、`object.reserveDenseArrayElements`。
- **所有权 / 错误 / 调用**：返回 owned 数组值，`values` 借用。GC：先用 `RootedValueCopies` 把元素拷一份并挂 `ValueRootFrame`，保证 `createArray` / `reserveDenseArrayElements` / `defineOwnProperty` 触发 GC 时元素仍是根，`defer` 次序保证先 deactivate 再释放缓冲；建到一半失败由 `errdefer destroyFromHeader` 销毁数组。调用方：`construct`（`:524`）、`constructConstructorWithPrototype`（`:538`），以及 `src/tests/exec.zig:7960`。

### `arrayLengthFromNumber` (`src/exec/array_builtin_ops.zig:569`)

- **签名**：`fn arrayLengthFromNumber(value: core.JSValue) ?u32`。
- **作用**：把 `new Array(n)` 那个唯一的数字实参折算成合法数组 length；不是合法 length（该抛 RangeError 的那些）就返回 null。
- **实现**：先 `asInt32` 取整数、否则 `asFloat64`，都不是数字返回 null；然后四道拒绝：非有限、NaN（`isFinite` 已覆盖，这条是冗余防御）、落在 `[0, core_array.max_array_length]` 之外、`@trunc` 后与原值不等（带小数）。全过才 `@intFromFloat` 返回 u32。
- **所有权 / 错误 / 调用**：无分配、无 GC 根。唯一调用方 `constructConstructorWithPrototype` 把 null 转成 `error.RangeError`，再由 `arrayCall` 的 construct 分支换成带消息的 `"invalid array length"` RangeError。

### `join` (`src/exec/array_builtin_ops.zig:584`)

- **签名**：`pub fn join(rt: *core.JSRuntime, array_value: core.JSValue, separator_value: core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `join`。
- **实现**：`expectObject` 取对象后，先把分隔符 `appendValueString` 铺进一条 `ArrayList(u8)`，再按 `object.arrayLength()` 逐个 `getProperty(atomFromUInt32(index))`：非首项先补分隔符，元素是 `undefined` 或 `null` 时只留空位（与 spec 一致），其余 `appendValueString` 追加，最后 `createStringValue` 出一个 String 值。注意这是过渡实现：长度只读一次 `arrayLength()`（不是每轮重读 `length` 属性），也不走 ToObject / ToLength 与循环引用保护——spec 路径在 `array_ops.arrayJoinCall`。
- **所有权 / 错误 / 调用**：返回新建 String 的 owned 值；两个 `std.ArrayList(u8)` 用 `rt.memory.allocator` 且 `defer deinit`，是本文件里少数真有局部缓冲的函数。error set：`expectObject` 的 `error.TypeError`、ToString 的 `AppendStringError` 与 OOM；无 `ctx`，不做 JS 异常映射。**全树无调用方**（`rg` 只命中本处定义）：spec 路径的 join 在 `array_ops.arrayJoinCall`，这条过渡实现已经悬空。

### `methodCall` (`src/exec/array_builtin_ops.zig:604`)

- **签名**：`pub fn methodCall(rt: *core.JSRuntime, receiver: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：按 method id 分发到本文件的过渡或完整实现。
- **实现**：单行转调 `methodCallWithRealm(null, rt, receiver, method, args)`——realm 传 null，所以三个要新建迭代器对象的 method 在这条入口上拿不到 %ArrayIteratorPrototype% 的最终身份，那些要走 `methodCallInRealm`。分发表本身（`method` 是整数 id，不是 atom）在 `methodCallWithRealm`。
- **所有权 / 错误 / 调用**：返回 owned 值，`receiver`/`args` 借用。error set 见 `methodCallWithRealm`（`error.TypeError` / `error.InvalidBuiltinRegistry`），bare-runtime API 不映射 JS 异常。**生产树内无调用方**：只有 `src/tests/core.zig:3383`、`src/tests/core.zig:4560`（method 20 = 迭代器 next）与本文件测试 `:722` 在用。

### `methodCallInRealm` (`src/exec/array_builtin_ops.zig:612`)

- **签名**：`pub fn methodCallInRealm(realm: *core.RealmContext, receiver: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：按 method id 分发到本文件的过渡或完整实现。
- **实现**：薄封装，主体转发到 `methodCallWithRealm`。
- **所有权 / 错误 / 调用**：同 `methodCall` 的所有权与错误约定，只是把 `realm` 传下去让 17-19 臂能拿到最终的 %ArrayIteratorPrototype%；`realm` 是借用指针。唯一调用方是本文件测试 `:723`。

### `methodCallWithRealm` (`src/exec/array_builtin_ops.zig:616`)

- **签名**：`fn methodCallWithRealm(realm: ?*core.RealmContext, rt: *core.JSRuntime, receiver: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：过渡字节码/夹具用的窄实现：filterEven/reduceSum 等写死谓词，不是完整 spec 回调。
- **实现**：过渡字节码/夹具用的窄实现：filterEven/reduceSum 等写死谓词，不是完整 spec 回调。keys/values/entries 需要 RealmContext 才能拿到 `%ArrayIteratorPrototype%`。按 id/mode `switch` 分发到具体叶子。错误：error.TypeError、error.InvalidBuiltinRegistry。
- **所有权 / 错误 / 调用**：私有分发器，调用方 `methodCall`（`:605`）与 `methodCallInRealm`（`:613`）；`realm` 借用，返回值 owned 且由各叶子方法产生，本函数自身不分配。error set：参数个数不符或未知 id → `error.TypeError`；17-19 臂缺 realm → `error.InvalidBuiltinRegistry`。注意 13（push）/15（concat）/16（sort）三臂没有 `args.len` 前置检查，由叶子自己容错。

### `arrayIterator` (`src/exec/array_builtin_ops.zig:695`)

- **签名**：`fn arrayIterator(realm: *core.RealmContext, receiver: core.JSValue, kind: ArrayIteratorKind) !core.JSValue`。
- **作用**：过渡 record id 17/18/19 的实现体，即 `Array.prototype.values`/`keys`/`entries`（receiver 也可以是 arguments 对象或 TypedArray）：按 kind 造一个 %ArrayIterator% 实例。
- **实现**：先 `expectArrayIteratorTarget` 校验 receiver 是数组 / `arguments` / `mapped_arguments` / TypedArray，否则 TypeError。再从 `realm.class_prototypes[core.class.ids.array_iterator]` 取该 realm 已定稿的 %ArrayIteratorPrototype%；槽越界或不是对象一律 `error.InvalidBuiltinRegistry`——这就是无 realm 的 `methodCall` 走这三个 id 必然失败、必须改用 `methodCallInRealm` 的原因。随后 `Object.create` 出 `array_iterator` 类实例（失败路径 `errdefer destroyFromHeader`），写三个内部槽：target 槽 = receiver、index 槽 = 0、kind 槽 = `@intFromEnum(kind)`。
- **所有权 / 错误 / 调用**：返回 owned 的迭代器对象；`errdefer destroyFromHeader` 回收半成品。`receiver` 的 GC 边由 `setOptionalValueSlot` 写入（带屏障），此后由迭代器对象持有。error set：receiver 不是 array/arguments/TypedArray → `error.TypeError`（`expectArrayIteratorTarget`）；realm 的 `class_prototypes[array_iterator]` 未填或不是对象 → `error.InvalidBuiltinRegistry`。唯一调用方是 `methodCallWithRealm` 的 17/18/19 臂；产出的对象不带 `next` 方法，与 `iterator_ops` 的真迭代器不同（测试 `:727` 钉住）。

### `arrayIteratorNext` (`src/exec/array_builtin_ops.zig:730`)

- **签名**：`fn arrayIteratorNext(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue`。
- **作用**：过渡 record id 20，即数组迭代器的 `next()`：推进游标并产出 `{ value, done }` 结果对象。
- **实现**：receiver 必须是 `class_id == core.class.ids.array_iterator` 的对象，否则 TypeError。target 槽已为 null（迭代已耗尽）时直接回 `{ undefined, true }`。否则每次调用都用 `arrayIteratorTargetLength` 重新读一次长度（所以迭代过程中的扩缩容可见），`index >= length` 时先造好 done 结果、再 `clearOptionalValueSlot` 放掉对 target 的引用，此后永远 done。未越界则先把 index 槽自增，再按槽里存的 kind 调 `arrayIteratorValue` 取值，包成 `{ value, false }`。
- **所有权 / 错误 / 调用**：返回 owned 的 iter-result 对象；耗尽时 `clearOptionalValueSlot` 主动放掉 target 边，之后再 next 走 `done` 快路。`receiver` 借用。error set：不是 `array_iterator` 类 → `error.TypeError`，其余由 `expectArrayIteratorTarget` / 属性读取透传。唯一调用方是 `methodCallWithRealm` 的 20 臂。

### `arrayIteratorValue` (`src/exec/array_builtin_ops.zig:748`)

- **签名**：`fn arrayIteratorValue(rt: *core.JSRuntime, target: *core.Object, index: u32, kind: ArrayIteratorKind) !core.JSValue`。
- **作用**：按迭代器 kind 把一个下标变成 `next().value`：keys 给下标、values 给元素、entries 给 `[下标, 元素]` 二元组。
- **实现**：`switch (kind)` 三臂。`.key`：直接 `JSValue.int32(index)`，不碰 target。`.value`：TypedArray（`buffer_ops.isTypedArrayObject`）走 `buffer_ops.typedArrayGetIndex` 直读元素，其余走 `target.getProperty(atomFromUInt32(index))` 的常规带原型链查找。`.key_value`：先 `Object.createArray`（`errdefer destroyFromHeader`），用同一套 TypedArray / 普通对象分支取出元素，再把下标与元素 `defineOwnProperty` 成 0、1 号可写可枚举可配置的数据属性。
- **所有权 / 错误 / 调用**：返回 owned 值：`.key` 是立即数，`.value` 走 `typedArrayGetIndex` / `getProperty`，`.key_value` 新建 pair 数组（失败 `errdefer destroyFromHeader`）并把 index 与元素 `defineOwnProperty` 进去。`target` 借用。唯一调用方 `arrayIteratorNext`（`:744`）；pair 建好后到写入前的 `getProperty` 窗口没有显式根帧，靠保守栈扫描兜底（对照本文件 `reverse`/`sort` 对 JSValue 局部显式建 `ValueRootFrame`）。

### `iteratorResult` (`src/exec/array_builtin_ops.zig:766`)

- **签名**：`fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue`。
- **作用**：过渡数组迭代器用的 `CreateIterResultObject` 包装。
- **实现**：转发 `iterator_ops.createIteratorResult(rt, null, value, done)`；这条 record 臂不带 realm handle，`global == null` 意味着结果对象没有原型（真正的数组迭代器走 `iterator_ops.arrayIteratorNext`，那条带原型）。
- **所有权 / 错误 / 调用**：薄转发 `iterator_ops.createIteratorResult(rt, null, value, done)`：`null` realm 意味着结果对象没有原型；返回 owned，`value` 的所有权转给结果对象的 `value` 属性，创建期间由 `createIteratorResult` 负责建根（测试 `:770` 用 GC 阈值 0 钉住这一点）。error set：OOM / 属性定义失败。调用方 `arrayIteratorNext`（`:733`、`:737`、`:745`）。

### `filterEven` (`src/exec/array_builtin_ops.zig:922`)

- **签名**：`fn filterEven(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：过渡夹具用的写死谓词实现，不是用户回调路径。
- **实现**：对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`Object.createArray`、`Object.destroyFromHeader`、`out.gcHeader`、`array.arrayLength`、`array.getProperty`、`atom.atomFromUInt32`、`item.asInt32`。
- **所有权 / 错误 / 调用**：过渡夹具实现（谓词写死为偶数，无用户回调）。返回 owned 的新数组，失败由 `errdefer destroyFromHeader` 回收；元素从源数组读出后由 `defineOwnProperty` 接管。error set：`expectArray` 的 `error.TypeError` 与读写属性的 OOM。唯一调用方是 `methodCallWithRealm` 的 1 臂。

### `reduceSum` (`src/exec/array_builtin_ops.zig:940`)

- **签名**：`fn reduceSum(_: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：过渡夹具用的写死谓词实现，不是用户回调路径。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`array.arrayLength`、`array.getProperty`、`atom.atomFromUInt32`、`item.asInt32`、`JSValue.int32`。
- **所有权 / 错误 / 调用**：返回立即数 int32，不分配、不建根（`rt` 参数未用，整数溢出按 Zig 默认 panic 语义）。error set：`expectArray` 的 `error.TypeError` 与 `getProperty` 透传。唯一调用方是 `methodCallWithRealm` 的 2 臂。

### `someEven` (`src/exec/array_builtin_ops.zig:951`)

- **签名**：`fn someEven(_: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：过渡夹具用的写死谓词实现，不是用户回调路径。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`array.arrayLength`、`array.getProperty`、`atom.atomFromUInt32`、`item.asInt32`、`@mod`、`JSValue.boolean`。
- **所有权 / 错误 / 调用**：返回 boolean 立即数，不分配不建根。error set：`expectArray` 的 `error.TypeError` 与 `getProperty` 透传。唯一调用方是 `methodCallWithRealm` 的 4 臂。

### `everyPositive` (`src/exec/array_builtin_ops.zig:962`)

- **签名**：`fn everyPositive(_: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：过渡夹具用的写死谓词实现，不是用户回调路径。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`array.arrayLength`、`array.getProperty`、`atom.atomFromUInt32`、`item.asInt32`、`JSValue.boolean`。
- **所有权 / 错误 / 调用**：返回 boolean 立即数，不分配不建根；非 int32 元素按 0 处理因而判负。error set：`expectArray` 的 `error.TypeError` 与 `getProperty` 透传。唯一调用方是 `methodCallWithRealm` 的 5 臂。

### `indexSearch` (`src/exec/array_builtin_ops.zig:979`)

- **签名**：`fn indexSearch(rt: *core.JSRuntime, value: core.JSValue, needle: core.JSValue, mode: SearchMode) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `indexSearch`。
- **实现**：按 id/mode `switch` 分发到具体叶子。含循环：按 length 或迭代器步进处理元素。关键调用：`value.isString`、`stringSearchValue`、`expectArray`、`array.arrayElements`、`array.arrayLength`、`valuesEqual`、`JSValue.boolean`、`JSValue.int32`。
- **所有权 / 错误 / 调用**：返回立即数（int32 或 boolean），不分配不建根；`needle` 借用，字符串 receiver 整个转交 `stringSearchValue`。error set：既不是字符串也不是数组 → `error.TypeError`，其余 `getProperty` 透传。唯一调用方是 `methodCallWithRealm` 的 6/7/8 臂。

### `stringSearchValue` (`src/exec/array_builtin_ops.zig:1021`)

- **签名**：`fn stringSearchValue(rt: *core.JSRuntime, value: core.JSValue, needle: core.JSValue, mode: SearchMode) !core.JSValue`。
- **作用**：String 内建、索引或 ToString 相关操作。
- **实现**：按 id/mode `switch` 分发到具体叶子。关键调用：`haystack.deinit`、`string.appendValueUtf8`、`query.deinit`、`appendValueString`、`mem.indexOf`、`JSValue.boolean`、`JSValue.int32`。
- **所有权 / 错误 / 调用**：两个 `std.ArrayList(u8)` 是真正的局部缓冲，`rt.memory.allocator` 分配并 `defer deinit`；返回立即数，不新建堆值。error set：ToString 的 `AppendStringError` 与 OOM。唯一调用方 `indexSearch`（`:980`）。

### `at` (`src/exec/array_builtin_ops.zig:1035`)

- **签名**：`fn at(_: *core.JSRuntime, array_value: core.JSValue, index_value: core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `at`。
- **实现**：关键调用：`expectArray`、`index_value.asInt32`、`array.arrayLength`、`JSValue.undefinedValue`、`array.getProperty`、`atom.atomFromUInt32`。
- **所有权 / 错误 / 调用**：返回 `getProperty` 的 owned 值或 undefined 立即数，不分配。error set：`expectArray` 的 `error.TypeError` 与 `getProperty` 透传；非 int32 的 `index_value` 一律当 0，不做 ToInteger。唯一调用方是 `methodCallWithRealm` 的 9 臂。

### `slice` (`src/exec/array_builtin_ops.zig:1043`)

- **签名**：`fn slice(rt: *core.JSRuntime, array_value: core.JSValue, start_value: core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `slice`。
- **实现**：对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`start_value.asInt32`、`array.arrayLength`、`Object.createArray`、`Object.destroyFromHeader`、`out.gcHeader`、`array.getProperty`、`atom.atomFromUInt32`。
- **所有权 / 错误 / 调用**：返回 owned 的新数组，失败 `errdefer destroyFromHeader`；元素读出后由 `defineOwnProperty` 接管。error set：`expectArray` 的 `error.TypeError` 与 OOM。唯一调用方是 `methodCallWithRealm` 的 10 臂。

### `splice` (`src/exec/array_builtin_ops.zig:1060`)

- **签名**：`fn splice(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `splice`。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`asInt32`、`runtime.rootValues`、`root_frame.activate`、`root_frame.deactivate`、`Object.createArray`、`Object.destroyFromHeader`、`removed.gcHeader`。
- **所有权 / 错误 / 调用**：过渡窄实现：固定吃 4 个参数（start / deleteCount / 两个插入值），靠 `methodCallWithRealm` 的 `args.len != 4` 前置检查保证不越界。GC：`insert_a` / `insert_b` 用 `core.runtime.rootValues` 显式建根，因为 `defineOwnProperty` 可能触发 GC；返回 owned 的 removed 数组，失败 `errdefer destroyFromHeader`。error set：`expectArray` 的 `error.TypeError` 与 OOM。唯一调用方是 11 臂。

### `push` (`src/exec/array_builtin_ops.zig:1084`)

- **签名**：`fn push(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `push`。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`expectArray`、`array.defineOwnProperty`、`atom.atomFromUInt32`、`array.arrayLength`、`Descriptor.data`、`JSValue.int32`。
- **所有权 / 错误 / 调用**：返回新长度的立即数；`args` 借用，元素由 `defineOwnProperty` 接管。error set：`expectArray` 的 `error.TypeError` 与 OOM。唯一调用方是 `methodCallWithRealm` 的 13 臂（该臂不校验 `args.len`，空参就是空操作）。

### `pop` (`src/exec/array_builtin_ops.zig:1092`)

- **签名**：`fn pop(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `pop`。
- **实现**：关键调用：`expectArray`、`array.arrayLength`、`JSValue.undefinedValue`、`atom.atomFromUInt32`、`array.getProperty`、`array.deleteProperty`、`array.defineOwnProperty`、`Descriptor.data`。
- **所有权 / 错误 / 调用**：返回被摘下元素的 owned 值（空数组时是 undefined 立即数）；`deleteProperty` 的返回值被 `_ =` 丢弃，随后重定义 `length`。error set：`expectArray` 的 `error.TypeError`、`getProperty` 与 `defineOwnProperty` 透传。唯一调用方是 `methodCallWithRealm` 的 14 臂。

### `rewriteReversedPair` (`src/exec/array_builtin_ops.zig:1103`)

- **签名**：`fn rewriteReversedPair( rt: *core.JSRuntime, array: *core.Object, lower_key: core.atom.Atom, upper_key: core.atom.Atom, lower_value: core.JSValue, upper_value: core.JSValue, ) !void`。
- **作用**：把反转/排序后的条目写回数组下标。
- **实现**：关键调用：`array.deleteProperty`、`upper_value.isUndefined`、`array.defineOwnProperty`、`Descriptor.data`、`lower_value.isUndefined`。
- **所有权 / 错误 / 调用**：无返回值；`array` 与两个 value 参数都是借用，写回时由 `defineOwnProperty` 接管所有权，undefined 被当作洞而不写回。`deleteProperty` 的返回值丢弃。error set：`defineOwnProperty` 的 OOM。唯一调用方 `reverse` 的两条臂（`:1146`、`:1148`）。

### `reverse` (`src/exec/array_builtin_ops.zig:1123`)

- **签名**：`fn reverse(rt: *core.JSRuntime, array_value: core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `reverse`。
- **实现**：`expectArray` 取数组，长度 ≤ 1 直接原样返回。之后 `lower` 从 0、`upper` 从 `arrayLength() - 1` 相向收拢，每轮 `getProperty` 读出两端的值，再交给 `rewriteReversedPair` 做「删两端再按对调后的键 define 回去」（`undefined` 一侧只删不写，保留洞）。`value_root_frames_enabled` 为真时每对交换额外开一个 `ValueRootFrame`（`.borrowed` 切片）罩住「delete 已经断边、define 还没写回」的窗口——CLI STW 不把标量 Zig 局部当根；开关关时直接调 `rewriteReversedPair`。对应 qjs `js_array_reverse` 的索引属性交换形状（quickjs.c:42497-42547）。
- **所有权 / 错误 / 调用**：返回的是**传入的同一个** `array_value`（原地反转，不新建对象，调用方原有的所有权不变）。GC：`value_root_frames_enabled` 时每对交换都开一个 `ValueRootFrame`（`.borrowed` 切片）罩住「delete 已经断边、define 还没写回」的窗口；关掉该开关时直接调 `rewriteReversedPair`。error set：`expectArray` 的 `error.TypeError` 与 OOM。唯一调用方是 `methodCallWithRealm` 的 12 臂。

### `sort` (`src/exec/array_builtin_ops.zig:1162`)

- **签名**：`fn sort(rt: *core.JSRuntime, array_value: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：Array 内建表/过渡实现里的 `sort`（只有默认字符串序这一条窄路径）。
- **实现**：首个参数只要不是 `undefined`（即传了比较器）立刻 `error.TypeError`——这条过渡路径只做默认字符串序。按 `arrayLength()` 逐个 `getProperty`，`undefined` 元素跳过（按 spec 丢到末尾）；其余 `appendValueString` 转成字符串后 `dupe` 出独立 `key` 存进 `entries`（`key_owned` + `errdefer` 补住 append 失败的窗口）。排序用 `std.mem.sort` 而不是全树常用的 `std.sort.heap`：ES2019 要求稳定，键相等的不同元素必须保持原相对次序，注释同时记下用 heap 的理由是躲开 block sort 每个元素类型 ~22 KB 的体积。写回按 `value_root_frames_enabled` 选 `rewriteSortedArrayRooted`（先把 `entries` 里的值复制进一块 native 窗口挂根，因为 ArrayList 缓冲不是保守扫描根）或直接 `rewriteSortedArray`（先把 `[0, length)` 全 delete 再按新次序 define）。对照 qjs `js_array_sort` 的默认字符串序分支（quickjs.c:43017-43144）。
- **所有权 / 错误 / 调用**：返回传入的 `array_value` 本身（原地排序）。`entries` 每项的 `key` 是 `rt.memory.allocator.dupe` 出来的独立缓冲，由函数出口的 `defer` 循环统一 free，`key_owned` + `errdefer` 补住 append 失败的窗口；`value` 只是借用的位拷贝。error set：传了非 undefined 的比较器 → `error.TypeError`（这条过渡路径只做默认字符串序），其余是 ToString 的 `AppendStringError` 与 OOM。唯一调用方是 `methodCallWithRealm` 的 16 臂。

### `SortEntry.lessThan` (`src/exec/array_builtin_ops.zig:1197`)

- **签名**：`fn lessThan(_: void, lhs: SortEntry, rhs: SortEntry) bool`。
- **作用**：比较器：用于稳定/堆排序的严格弱序。
- **实现**：薄封装，主体转发到 `mem.lessThan`。
- **所有权 / 错误 / 调用**：无：`std.mem.sort` 的比较闭包，纯 `mem.lessThan` 字节序，不分配、无 error set、不碰 GC；唯一使用点是 `sort`（`:1196`）传给 `std.mem.sort` 的 comptime 结构体。

### `rewriteSortedArray` (`src/exec/array_builtin_ops.zig:1214`)

- **签名**：`fn rewriteSortedArray(rt: *core.JSRuntime, array: *core.Object, entries: []const SortEntry) !void`。
- **作用**：把反转/排序后的条目写回数组下标。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`array.arrayLength`、`array.deleteProperty`、`atom.atomFromUInt32`、`array.defineOwnProperty`、`Descriptor.data`。
- **所有权 / 错误 / 调用**：无返回值；先删掉 `[0, arrayLength)` 的全部索引再按序重定义，`entries` 借用、其 `value` 由 `defineOwnProperty` 接管，`key` 缓冲不碰（仍归 `sort` 的 defer 释放）。error set：`defineOwnProperty` 的 OOM，delete 的返回值丢弃。调用方 `sort`（`:1210`，关根帧开关时）与 `rewriteSortedArrayRooted`（`:1237`）。

### `rewriteSortedArrayRooted` (`src/exec/array_builtin_ops.zig:1224`)

- **签名**：`fn rewriteSortedArrayRooted(rt: *core.JSRuntime, array: *core.Object, entries: []const SortEntry) !void`。
- **作用**：把反转/排序后的条目写回数组下标。
- **实现**：跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。含循环：按 length 或迭代器步进处理元素。关键调用：`memory.free`、`memory.alloc`、`entries_frame.activate`、`entries_frame.deactivate`、`rewriteSortedArray`。
- **所有权 / 错误 / 调用**：额外 `rt.memory.alloc` 一块 `[]JSValue` 把 entries 的值摊平成 `ValueRootFrame` 的 `.borrowed` 切片（`defer` free + deactivate），因为 `std.ArrayList` 的缓冲不是保守扫描根；entries 为空时既不分配也不激活。error set：只有这次分配的 OOM，之后透传 `rewriteSortedArray`。唯一调用方 `sort`（`:1206`，`value_root_frames_enabled` 为真时）。

### `concat` (`src/exec/array_builtin_ops.zig:1243`)

- **签名**：`fn concat(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：concat 展开或追加一个值。
- **实现**：先建根再建对象：`RootedValueCopies.init` 复制一份 args 并用一个 `ValueRootFrame` 罩住，receiver 另用 `rootValues` 单独挂根，两组 `defer` 的次序保证根帧先 deactivate、缓冲后 free。随后 `createArray(rt, null)` + `errdefer destroyFromHeader`，用 `next_index` 游标依次把 receiver 与每个参数交给 `concatAppend`：值是 Array 时按 `arrayLength()` 逐项 `getProperty` 展开一层（`undefined` 项只推进游标、不 define，保留洞），否则整个值作为一项 define 进去。最后把 `length` define 成 `next_index`（可写、不可枚举、不可配置）。对照 qjs `js_array_concat`（quickjs.c:41684-41739）；这条过渡实现只认 `isArray()`，不查 `Symbol.isConcatSpreadable`，也不走 ArraySpeciesCreate。
- **所有权 / 错误 / 调用**：返回 owned 的新数组，失败 `errdefer destroyFromHeader`；receiver 与 args 分别用 `rootValues` 和 `RootedValueCopies` 建根，`defer` 次序保证两个根帧先 deactivate、缓冲后 free。元素读出后由 `defineOwnProperty` 接管。error set：`getProperty` / `defineOwnProperty` 的透传与 OOM。唯一调用方是 `methodCallWithRealm` 的 15 臂（测试 `:887` 钉住 GC 阈值 0 下参数不被回收）。

### `concatAppend` (`src/exec/array_builtin_ops.zig:1269`)

- **签名**：`fn concatAppend(rt: *core.JSRuntime, out: *core.Object, next_index: *u32, value: core.JSValue) !void`。
- **作用**：concat 展开或追加一个值。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`value.isObject`、`value.refHeader`、`Object.fromHeader`、`object.isArray`、`object.arrayLength`、`object.getProperty`、`atom.atomFromUInt32`、`item.isUndefined`。
- **所有权 / 错误 / 调用**：无返回值；`out` 与 `value` 借用，元素由 `defineOwnProperty` 接管。`next_index` 是输入输出参数——数组实参里的洞（undefined）不写出但**照样推进计数**，这正是最终 `length` 的来源。error set：`getProperty` / `defineOwnProperty` 的透传与 OOM。调用方 `concat`（`:1261`、`:1263`）。

### `expectArrayIteratorTarget` (`src/exec/array_builtin_ops.zig:1297`)

- **签名**：`fn expectArrayIteratorTarget(value: core.JSValue) !*core.Object`。
- **作用**：把 JSValue 收成对象/数组；失败 TypeError。
- **实现**：薄封装，主体转发到 `expectObject`、`object.isArray`、`buffer_ops.isTypedArrayObject`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回借用的 `*core.Object`（调用方不得释放）。接受 array、`arguments`、`mapped_arguments` 与 TypedArray 四类，其余 `error.TypeError`；不分配、不建根。调用方 `arrayIterator`（`:697`）与 `arrayIteratorNext`（`:734`）。

### `arrayIteratorTargetLength` (`src/exec/array_builtin_ops.zig:1303`)

- **签名**：`fn arrayIteratorTargetLength(rt: *core.JSRuntime, object: *core.Object) !u32`。
- **作用**：给数组迭代器算出本次 `next()` 的长度上界；三类合法 target 各有各的读法。
- **实现**：数组直接读 `object.arrayLength()`；TypedArray 走 `buffer_ops.typedArrayLength`，其错误（例如 buffer 已 detach）被 `catch 0` 吞成长度 0，于是迭代立即报 done 而不是抛异常；其余情形（`arguments` / `mapped_arguments`）读普通 `length` 属性，`asInt32` 失败时按 0 处理。
- **所有权 / 错误 / 调用**：不分配、不建根，返回纯数字。TypedArray 的长度错误被 `catch 0` 吞掉（detached buffer 因此表现为长度 0），一般对象读 `length` 属性、非 int32 一律当 0。error set：只剩 `getProperty` 透传。唯一调用方 `arrayIteratorNext`（`:735`）。

### `createStringValue` (`src/exec/array_builtin_ops.zig:1310`)

- **签名**：`fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：用 UTF-8 字节建一个 JS 字符串值。
- **实现**：薄封装，主体转发到 `String.createUtf8`、`str.value`。
- **所有权 / 错误 / 调用**：返回新建 String 的 owned 值；`bytes` 只是输入，`String.createUtf8` 自己拷贝，调用方的缓冲仍归调用方（`join` 里是 `defer deinit` 的 ArrayList）。error set：OOM。唯一调用方 `join`（`:599`）。

### `valuesEqual` (`src/exec/array_builtin_ops.zig:1315`)

- **签名**：`fn valuesEqual(a: core.JSValue, b: core.JSValue) bool`。
- **作用**：Array 内建表/过渡实现里的 `valuesEqual`。
- **实现**：关键调用：`a.isBigInt`、`b.isBigInt`、`compareBigIntValues`、`a.asInt32`、`b.asInt32`、`a.asBool`、`b.asBool`、`a.isNull`。
- **所有权 / 错误 / 调用**：无：纯比较，不分配、无 error set、不碰 GC；BigInt 与字符串分别转给 `compareBigIntValues` / `compareStringValues`，两者返回 null（不可比）时一律判为不相等。唯一调用方 `indexSearch`（`:988`、`:1009`）。

### `compareBigIntValues` (`src/exec/array_builtin_ops.zig:1333`)

- **签名**：`fn compareBigIntValues(a: core.JSValue, b: core.JSValue) ?std.math.Order`。
- **作用**：bigint/字符串比较，给过渡 sort/equals。
- **实现**：关键调用：`bigIntParts`、`bignum.compareParts`。
- **所有权 / 错误 / 调用**：两个 `[2]Limb` scratch 在本函数栈上，`bigIntParts` 返回的 `limbs` 可能指向它们、也可能借用堆 `BigInt` 的 limbs——出了本函数一律不得再持有。不分配、无 error set，任一侧不是 BigInt 就返回 null。唯一调用方 `valuesEqual`（`:1317`）。

### `bigIntParts` (`src/exec/array_builtin_ops.zig:1346`)

- **签名**：`fn bigIntParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntParts`。
- **作用**：bigint/字符串比较，给过渡 sort/equals。
- **实现**：含循环：按 length 或迭代器步进处理元素。关键调用：`value.asShortBigInt`、`@truncate`、`@bitSizeOf`、`value.isBigInt`、`value.refHeader`、`@alignCast`、`@fieldParentPtr`、`big.negative`。
- **所有权 / 错误 / 调用**：返回的 `limbs` 全是借用：短 BigInt 写进调用方给的 `scratch`（生命周期＝调用方栈帧），堆 BigInt 直接指向 `BigInt.limbs()`（生命周期＝那个 BigInt）。不分配、无 error set，非 BigInt 返回 null。唯一调用方 `compareBigIntValues`（`:1336`、`:1337`）。

### `compareStringValues` (`src/exec/array_builtin_ops.zig:1369`)

- **签名**：`fn compareStringValues(a: core.JSValue, b: core.JSValue) ?i32`。
- **作用**：bigint/字符串比较，给过渡 sort/equals。
- **实现**：薄封装，主体转发到 `string.compareStringValues`。
- **所有权 / 错误 / 调用**：薄转发 `core.string.compareStringValues(a, b, false)`（末位 false = 不做大小写折叠）；不分配、无 error set，返回 `?i32`，null 表示不可比（调用方按「不相等」处理）。唯一调用方 `valuesEqual`（`:1328`）。

### `appendValueString` (`src/exec/array_builtin_ops.zig:1374`)

- **签名**：`fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void`。
- **作用**：把数组字符串化所需的元素表示追加到字节缓冲。
- **实现**：调用 `core.value_string.appendValueString`，使用默认选项 `.{}`。
- **所有权 / 错误 / 调用**：借用输入值并修改调用方缓冲；返回 AppendStringError!void，转换和分配失败向上传播。

## 覆盖核对

- 清单函数数: 58
- 本文标题覆盖: 58
- 未覆盖: 无
