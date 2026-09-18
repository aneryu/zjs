# 01 — `zjs.native`：宿主函数

> `leaf` / `leafWithState` / `Class` 已从 `src/binding/native.zig` 删除。下文若仍写这些生成器，以源码为准：只剩 `Call` / `Spec` / `Options` / `managed`。内建叶签名仍走 `exec/native_legacy.zig`。

`src/binding/native.zig` 为宿主函数生成 comptime 的 C ABI thunk，并通过 NativeEntry 描述其调用种类、参数签名和目标。

Call 与 argv 是本次调用的借用视图，不能保存到调用结束之后。跨调用保存 JSValue 需要合适的持久根；即使仍在本次调用内，写入宿主堆的数据也不能只依赖 native 栈扫描保活。生成器自身不替任意宿主容器注册根。

---

## 类型

| 名字 | 含义 |
| --- | --- |
| `JSContext` / `JSValue` / `NativeEntry` | binding 门面、core 值、core entry 的别名；Spec.template 和 Call.entry 公开使用 NativeEntry 类型。Call.entry 是 const 指针，但底层 Runtime 的 retire 操作可以改变 entry 状态。 |
| `Exception` | `error{JSException}`：函数已经 `throwValue`/`throwError` 之后应传播的错误。 |
| `Call` | managed 调用的临时记录：ctx 为借用门面，另有 this、argv/argc、entry、可选 func_obj。普通 managed thunk 转发 func_obj；成员 method/getter/setter thunk 显式填 null。 |
| `Spec` | `{ template: NativeEntry }`。生成器产出的 comptime 常量，给 `defineFunction` / `createFunction`。 |
| `Options` | 注册选项：可选 u8 length、state、finalize、with_prototype、realm_global。finalize 注册到 Runtime 的外部宿主函数清理列表，不随函数对象被收立即执行；注册后的失败不必然撤销它。 |
| `ClassOptions` | `global_name`、`realm_global`。 |
| `MemberKind` | `method` / `getter` / `setter`。 |
| `Member` | 原型成员：`name`、`kind`、`spec`。`class_id` 在 `defineClass` 时盖上。 |
| `Class(...).Handle` | `defineClass` 返回的运行时句柄，持 `*const NativeType`。 |

`leaf` / `leafWithState` 只接受下面列出的受支持签名；其他签名编译失败，没有 generic 回退。VM 的 typed-leaf marshal 中，i32 接受 int32 或范围内、无小数且非 -0 的 float64；f64 分两档：`f64 -> void` 与类成员的 SELF_* f64 形状只接受 JS Number（包括 NaN/Infinity），而 `f64 -> f64` / `f64, f64 -> f64` 走 `primitiveF64Arg`，还会把缺失参数与 undefined 读成 NaN、null 读成 0、布尔读成 0/1；bool 只接受布尔值。除上述原始值外不会隐式做 JavaScript 转换（不调用 valueOf/toString）。leaf 的不分配、不重入、不抛约束是宿主必须遵守的调用契约，生成器只检查类型，不能静态证明函数体没有这些行为。

---

## `Call` 助手

### `Call.arg` (`src/binding/native.zig:44`)

- **签名**：`pub inline fn arg(self: *const Call, index: usize) JSValue`。
- **作用**：取第 `index` 个位置参数；越过 `argc` 返回 `undefined`（JS 语义）。
- **实现**：`index < argc` 则 `argv[index]`，否则 `undefinedValue()`。
- **所有权 / 错误 / 调用**：借用操作数窗口，无分配。

### `Call.args` (`src/binding/native.zig:49`)

- **签名**：`pub inline fn args(self: *const Call) []const JSValue`。
- **作用**：整段参数窗口做成切片。
- **实现**：`self.argv[0..self.argc]`。
- **所有权 / 错误 / 调用**：切片只在调用期间有效，且要求 argv 是可用指针。当前 managed getter thunk 把 argv 留为 undefined、argc=0，不能把该分支描述成已提供有效的空参数数组；getter 中可用 argc 或 arg 检查是否有参数，不应依赖 args() 解引用该未初始化指针。

### `Call.state` (`src/binding/native.zig:54`)

- **签名**：`pub inline fn state(self: *const Call, comptime T: type) *T`。
- **作用**：把注册时的 opaque `state` 转成 `*T`。
- **实现**：`@ptrCast(@alignCast(self.entry.state.?))`，不验证实际对象类型；null 或对齐不符违反安全前提，不是可捕获的 JS 错误，不能保证所有构建都安全 panic。
- **所有权 / 错误 / 调用**：借用宿主 state，调用方须保证它与 T 匹配且在使用期间存活。若已注册 finalize，须遵守 Runtime 持有的清理责任，不能在仍可能调用 finalizer 时自行释放同一 state。

### `Call.runtime` (`src/binding/native.zig:58`)

- **签名**：`pub inline fn runtime(self: *const Call) *core.JSRuntime`。
- **作用**：从 callee realm 取出 runtime。
- **实现**：`self.ctx.core.runtime`。
- **所有权 / 错误 / 调用**：不拥有 runtime。

### `Call.global` (`src/binding/native.zig:63`)

- **签名**：`pub inline fn global(self: *const Call) ?*core.Object`。
- **作用**：callee realm 的全局对象（可能尚未物化则为 null）。
- **实现**：`self.ctx.core.global`。
- **所有权 / 错误 / 调用**：借用。C6：realm 是函数**创建**时所在 realm，未必是调用方 realm。

### `Call.output` (`src/binding/native.zig:69`)

- **签名**：`pub inline fn output(self: *const Call) ?*std.Io.Writer`。
- **作用**：当前 VM 调用的宿主 writer（eval / `callFunction` 传入的 `output`）。
- **实现**：`builtin_dispatch.vmCallerView(self.ctx.core).output`。
- **所有权 / 错误 / 调用**：借用；优先取当前 VM invocation 的 writer，再取活动 native environment，没有环境则返回 null。null 本身只表示没有 writer，此方法不创建 stdout writer，也不执行输出；默认输出由具体消费者决定。

### `Call.throwError` (`src/binding/native.zig:75`)

- **签名**：`pub fn throwError(self: *const Call, name: []const u8, message: []const u8) Exception`。
- **作用**：按 class 名装一个 JS 错误并返回 `error.JSException`，函数必须把这个错误传播出去。
- **实现**：复制借用门面后调用 `ctx.throwError(..., .{}) catch {}`，最后无条件返回 JSException。catch 不仅吞掉成功安装后的 JSException，也吞掉创建错误对象或 stack 失败时的其他错误。
- **所有权 / 错误 / 调用**：成功安装的 pending 值属于 Runtime 共享异常槽，不是 callee 独立异常槽。失败时不能保证请求的错误已被安装；managed thunk 后续如何处理 JSException 还取决于当前 pending 状态。

### `Call.throwTypeError` (`src/binding/native.zig:81`)

- **签名**：`pub fn throwTypeError(self: *const Call, message: []const u8) Exception`。
- **作用**：`TypeError` 快捷方式。
- **实现**：`self.throwError("TypeError", message)`。
- **所有权 / 错误 / 调用**：同 `throwError`。

### `Call.throwRangeError` (`src/binding/native.zig:85`)

- **签名**：`pub fn throwRangeError(self: *const Call, message: []const u8) Exception`。
- **作用**：`RangeError` 快捷方式。
- **实现**：`self.throwError("RangeError", message)`。
- **所有权 / 错误 / 调用**：同 `throwError`。

---

## 生成器：managed / leaf

### `managed` (`src/binding/native.zig:117`)

- **签名**：`pub fn managed(comptime f: anytype) Spec`。
- **作用**：把 `fn (*Call) E!JSValue`（或无 error 的 `JSValue`）收成 managed `Spec`。
- **实现**：检查 `f` 是函数且恰好一个 `*Call` 参数。生成 `Thunk.thunk`。返回 template：`kind=.managed`、`arity=0`、空 flags。`length` 由 `Options` 再填。
- **所有权 / 错误 / 调用**：comptime 生成模板，不在此注册函数或转移 state。arity 默认 0，不根据回调读取多少参数推断 length；createFunction 可用 Options.length 覆盖。entry 由 Runtime 单独分配并加入其列表，不是这里创建的 per-call arena。

### `native.thunk` (`src/binding/native.zig:124`)

- **签名**：`fn thunk( ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object, ) callconv(.c) JSValue`。
- **作用**：VM native 分发的 C ABI 入口：在栈上组 `Call`，调用户 `f`，把 Zig error 映射成 JS 值。
- **实现**：`Call.ctx = JSContext.borrowCore(ctx)`。返回类型是 error union 则 `f(&call) catch embedderErrorToValue`；否则直接 `f(&call)`。
- **所有权 / 错误 / 调用**：借用 ctx 不可 destroy/deinit，Call 及参数窗口不可逃逸。error union 分支调用 embedderErrorToValue：OOM、ProcessExit、Interrupted、Timeout、StackOverflow、UnhandledPromiseRejection 先走引擎专门路径；其他错误在已有 pending 时返回异常哨兵，否则按名字创建错误。JSException 在没有 pending 时也会落入普通名称映射，因此并非无条件表示“已有异常”。非 error-union 分支直接返回 f 的值。

### `leaf` (`src/binding/native.zig:173`)

- **签名**：`pub fn leaf(comptime f: anytype) Spec`。
- **作用**：无 state 的 typed leaf（K1）。
- **实现**：`leafSpec(f, false)`。
- **所有权 / 错误 / 调用**：纯编译期构造：返回按值的 `Spec`，内含指向编译期生成的 `T.*` thunk 的静态代码指针，没有运行期分配、没有 error set；不支持的签名是 `@compileError`，不会退化成 generic 臂。`Spec` 由 `ctx.defineFunction` 消费（`src/tests/embedding_examples.zig:149`、`tools/perf/native_boundary/zjs_boundary_bench.zig:157`），本文件测试 `src/binding/native.zig:262` 只读 `template`。

### `leafWithState` (`src/binding/native.zig:179`)

- **签名**：`pub fn leafWithState(comptime f: anytype) Spec`。
- **作用**：第一参数是 `*State` 的 leaf：`fn (*T, f64) void` / `fn (*T, i32) i32`。
- **实现**：`leafSpec(f, true)`。state 指针来自 `Options.state`。
- **所有权 / 错误 / 调用**：同 `leaf`：编译期构造、无分配、无 error set。**差异在所有权**：state 指针不由引擎持有或释放，注册时经 `Options.state` 传入，宿主必须保证它活过所有调用（`src/tests/embedding_examples.zig:152` 用栈上计数器、`tools/perf/native_boundary/zjs_boundary_bench.zig:158` 用 `&tick_state`）；引擎只把裸 `*anyopaque` 作为第一个 C 参数传回，既不 retain 也不扫描。

### `leafSpec` (`src/binding/native.zig:183`)

- **签名**：`fn leafSpec(comptime f: anytype, comptime with_state: bool) Spec`。
- **作用**：按 Zig 函数类型挑 `LeafSig`，生成对应 C thunk + `sig`。
- **实现**：校验函数类型；`with_state` 要求第一参数是 pointer。`n = params.len - first`。按 (n, 参数类型, 返回类型) 匹配 `void_to_void` / `i32_to_i32` / `i32_i32_to_i32` / `f64_to_f64` / `f64_f64_to_f64` / `f64_to_void` / `bool_to_bool` 或带 state 的两档。不匹配 `@compileError`。template：`kind=.leaf`、`effect=Effect.leaf`、`arity=n`。
- **所有权 / 错误 / 调用**：模板记录 native_legacy 的签名 id，实际 marshal 在 builtin_dispatch 执行。生成器不提供无 state 签名之外的自动转换，也不验证传入 Options.state 的真实类型、非空性或生命周期。

### `native.t` (`src/binding/native.zig:197`)

- **签名**：`fn t(comptime i: usize) type`。
- **作用**：取「跳过 State 之后」第 i 个参数类型。
- **实现**：`params[first + i].type.?`
- **所有权 / 错误 / 调用**：comptime 匹配用。

### `native.stateOf` (`src/binding/native.zig:204`)

- **签名**：`fn stateOf(raw: *anyopaque) State`。
- **作用**：把 entry 传来的 opaque 转成 `*State`（`State` 已是指针类型）。
- **实现**：`@ptrCast(@alignCast(raw))`。
- **所有权 / 错误 / 调用**：供两个 state thunk 使用；只转换指针，不创建或复制 state。注册值须非空、对齐正确且与原函数第一参数类型一致。

### `native.void_to_void` (`src/binding/native.zig:207`)

- **签名**：`fn void_to_void() callconv(.c) void`。
- **作用**：`fn () void` 的 C 包装。
- **实现**：`f();`
- **所有权 / 错误 / 调用**：leaf，不抛。

### `native.i32_to_i32` (`src/binding/native.zig:210`)

- **签名**：`fn i32_to_i32(a: i32) callconv(.c) i32`。
- **作用**：`fn (i32) i32`。
- **实现**：`return f(a);`
- **所有权 / 错误 / 调用**：无分配、无 error set（leaf 目标不得抛异常）。没有 Zig 侧调用方：它的地址被 `NativeEntry.code` 钉进 `Spec.template.target`，运行时由 `builtin_dispatch.invokeLeafFast` 的 `sig_i32_to_i32` 臂（`src/exec/builtin_dispatch.zig:1175`）通过 C ABI 直接调用；参数已由 VM 做过 canonical int32 marshal（int32 标签，或无小数、落在 int32 范围内且非 -0 的 float64），返回值在那里被 `JSValue.int32` 装箱。

### `native.i32_i32_to_i32` (`src/binding/native.zig:213`)

- **签名**：`fn i32_i32_to_i32(a: i32, b: i32) callconv(.c) i32`。
- **作用**：`fn (i32, i32) i32`。
- **实现**：`return f(a, b);`
- **所有权 / 错误 / 调用**：同族：无分配、无 error set，仅由 `src/exec/builtin_dispatch.zig:1180` 的 `sig_i32_i32_to_i32` 臂经 C ABI 调用；两个参数都必须通过 canonical int32 marshal（int32 标签，或无小数、在范围内且非 -0 的 float64），否则该臂返回 null 走回退。

### `native.f64_to_f64` (`src/binding/native.zig:216`)

- **签名**：`fn f64_to_f64(a: f64) callconv(.c) f64`。
- **作用**：`fn (f64) f64`。
- **实现**：`return f(a);`
- **所有权 / 错误 / 调用**：同族：无分配、无 error set，由 `src/exec/builtin_dispatch.zig:1159` 的 `sig_f64_to_f64` 臂调用，返回值在那里经 `value_ops.numberToValue` 装箱。

### `native.f64_f64_to_f64` (`src/binding/native.zig:219`)

- **签名**：`fn f64_f64_to_f64(a: f64, b: f64) callconv(.c) f64`。
- **作用**：`fn (f64, f64) f64`。
- **实现**：`return f(a, b);`
- **所有权 / 错误 / 调用**：同族：无分配、无 error set，由 `src/exec/builtin_dispatch.zig:1164` 的 `sig_f64_f64_to_f64` 臂调用。

### `native.f64_to_void` (`src/binding/native.zig:222`)

- **签名**：`fn f64_to_void(a: f64) callconv(.c) void`。
- **作用**：`fn (f64) void`。
- **实现**：`f(a);`
- **所有权 / 错误 / 调用**：同族：无分配、无 error set，由 `src/exec/builtin_dispatch.zig:1186` 的 `sig_f64_to_void` 臂调用，返回值那里固定填 `undefined`。

### `native.bool_to_bool` (`src/binding/native.zig:225`)

- **签名**：`fn bool_to_bool(a: bool) callconv(.c) bool`。
- **作用**：`fn (bool) bool`。
- **实现**：`return f(a);`
- **所有权 / 错误 / 调用**：同族：无分配、无 error set，由 `src/exec/builtin_dispatch.zig:1193` 的 `sig_bool_to_bool` 臂调用；该臂零参或非 bool 直接返回 null。

### `native.state_f64_to_void` (`src/binding/native.zig:228`)

- **签名**：`fn state_f64_to_void(state: *anyopaque, a: f64) callconv(.c) void`。
- **作用**：`fn (*State, f64) void`。
- **实现**：`f(stateOf(state), a)`。
- **所有权 / 错误 / 调用**：`state` 来自 entry。

### `native.state_i32_to_i32` (`src/binding/native.zig:231`)

- **签名**：`fn state_i32_to_i32(state: *anyopaque, a: i32) callconv(.c) i32`。
- **作用**：`fn (*State, i32) i32`。
- **实现**：`return f(stateOf(state), a);`
- **所有权 / 错误 / 调用**：同上。

### `P.add` (`src/binding/native.zig:261`)

- **签名**：`fn add(a: i32, b: i32) i32`。
- **作用**：验证 `leaf` 推断 `sig_i32_i32_to_i32`。
- **实现**：`a +% b`。
- **所有权 / 错误 / 调用**：测试夹具，非引擎代码：`+%` 回绕、不分配、无 error set。只被同文件测试 `src/binding/native.zig:262`/`:264`/`:265` 当作 `leaf` 的推断样本，从不注册进 runtime，因此没有任何调用契约。

### `P.half` (`src/binding/native.zig:264`)

- **签名**：`fn half(x: f64) f64`。
- **作用**：验证 `leaf` 推断 `sig_f64_to_f64`。
- **实现**：`x / 2`。
- **所有权 / 错误 / 调用**：同上：测试夹具，不分配、无 error set，只被 `src/binding/native.zig:263` 用来断言推断出 `sig_f64_to_f64`。

### `Probe.f` (`src/binding/native.zig:276`)

- **签名**：`fn f(call: *Call) error{ JSException, TypeError }!JSValue`。
- **作用**：验证 `managed` 产出 `kind=.managed` 且 `needs_env` 为假。
- **实现**：`argc==0` 则 `error.TypeError`，否则 `call.arg(0)`。
- **所有权 / 错误 / 调用**：仅测试；不真正注册。

---

## `Class`：K2/K3/K4 宿主类

### `Class` (`src/binding/native.zig:326`)

- **签名**：`pub fn Class(comptime spec: anytype) type`。
- **作用**：从 comptime 描述生成一个类类型：`Self`、可选 constructor/finalize、methods/getters/setters 表、process-global class id。
- **实现**：要求 name 和 Self 字段，生成 class_id_slot、finalize_fn、成员表和 constructor_spec。生成类型本身不注册或安装属性；defineClass 才把成员装入 realm。方法为可写/可配置、不可枚举数据属性；accessor 没有 writable 属性。
- **所有权 / 错误 / 调用**：`JSContext.defineClass` 每 runtime 注册一次类型、每 realm 装一次原型。class id 跨 runtime 复用。

### `Class.classId` (`src/binding/native.zig:343`)

- **签名**：`pub fn classId() error{ClassIdExhausted}!core.ClassId`。
- **作用**：取出或分配这个 comptime 类的 process-global class id（qjs `JS_NewClassID` 槽）。
- **实现**：`class_id_slot.getOrAllocate()`。
- **所有权 / 错误 / 调用**：id 耗尽 → `ClassIdExhausted`。`defineClass` 先拿 id。

### `Class.unwrap` (`src/binding/native.zig:349`)

- **签名**：`pub fn unwrap(val: JSValue) ?*Self`。
- **作用**：class_id 检查 + 固定偏移 load `self`；外邦对象、已 dispose、类从未 define 则 null。
- **实现**：`native_object.unwrap(val, class_id_slot.value)` 再 ptrCast。
- **所有权 / 错误 / 调用**：不拥有或 pin Self，也不检查 Runtime 归属，不解开 Proxy。相同 class id 可用于多个 Runtime，因此跨 Runtime 的同类实例也可能被解包；取得指针不延长实例或宿主对象寿命。

### `native.thunk` (`src/binding/native.zig:355`)

- **签名**：`fn thunk(raw: *anyopaque) callconv(.c) void`。
- **作用**：把 C finalize 接到用户 `spec.finalize(*Self)`。
- **实现**：`spec.finalize(@ptrCast(@alignCast(raw)))`。
- **所有权 / 错误 / 调用**：sweep / runtime teardown 时由 native object 最终器跑。`Handle.dispose` 之后不会再为该实例跑。

### `Class.constructThunk` (`src/binding/native.zig:377`)

- **签名**：`fn constructThunk( ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object, ) callconv(.c) JSValue`。
- **作用**：K4 构造入口；借用传入 this 对象的原型，调用宿主 constructor 后另外创建 NativeObject 返回，不是把 payload 安装回原 this 对象。
- **实现**：`entry.state` 是 `*const NativeType`。`this` 不是对象 → TypeError「cannot be invoked without 'new'」。没有 `.constructor` → TypeError「not constructible from JS」。组 `Call`（`borrowCore`），调 `spec.constructor(&call)`（error union 走 `embedderErrorToValue`）。`native_object.create(runtime, native_type, instance.getPrototype(), self_ptr)`；失败则若有 finalize 先跑再把错误映射成 JS 值。成功返回 `obj.value()`。
- **所有权 / 错误 / 调用**：只检查 this 是对象，不独立检查 new 调用标志，不能仅凭错误消息声称拒绝所有非 new 调用。宿主 constructor 已返回指针而包装失败时，仅在配置了 finalize 的情况下调用它；没有 finalize 时此路径不会自动释放宿主资源。constructor 自身返回错误时，错误前分配的资源由宿主函数负责清理。

### `Class.memberTable` (`src/binding/native.zig:410`)

- **签名**：`fn memberTable(comptime kind: MemberKind, comptime table: anytype) []const Member`。
- **作用**：把 `.{ .step = fn, ... }` 这种 struct 收成 `[]const Member`，并按 kind 调 `methodSpec` / `getterSpec` / `setterSpec`。
- **实现**：扫 struct fields，填 `name=field.name`。`const frozen = out; return &frozen;` 钉成 comptime 切片。
- **所有权 / 错误 / 调用**：类类型的 `methods`/`getters`/`setters` 常量。

### `Handle.classId` (`src/binding/native.zig:433`)

- **签名**：`pub inline fn classId(self: Handle) core.ClassId`。
- **作用**：从已注册的 `NativeType` 读 class id。
- **实现**：`self.native_type.class_id`。
- **所有权 / 错误 / 调用**：Handle 借用 NativeType，必须在其注册 Runtime 仍存活时使用；读取 class id 不延长 NativeType 生命周期。

### `Handle.create` (`src/binding/native.zig:440`)

- **签名**：`pub fn create(self: Handle, ctx: *JSContext, self_ptr: *Self) !JSValue`。
- **作用**：在 `ctx` 的 realm 里把 `self_ptr` 包成实例（`[[Prototype]]` = 该 realm 的 class prototype）。对象拥有 `self_ptr`：finalize 在 sweep/teardown 跑。
- **实现**：取 `classPrototypeObject`，没有 → `error.ClassNotInstalled`。`native_object.create(...)`。
- **所有权 / 错误 / 调用**：成功后实例保存 self_ptr，配置的 finalizer 才承担后续清理；未配置 finalizer 时不会凭空释放宿主资源。失败时不调用 finalizer，self_ptr 仍由调用方处理，这与 constructThunk 的包装失败路径不同。Handle 应与 ctx 使用同一注册 Runtime；包装本身不验证 NativeType.owner。

### `Handle.unwrap` (`src/binding/native.zig:446`)

- **签名**：`pub inline fn unwrap(_: Handle, val: JSValue) ?*Self`。
- **作用**：句柄上的 unwrap，忽略 self。
- **实现**：`return Cls.unwrap(val);`
- **所有权 / 错误 / 调用**：同 `Class.unwrap`。

### `Handle.dispose` (`src/binding/native.zig:452`)

- **签名**：`pub fn dispose(_: Handle, val: JSValue) ?*Self`。
- **作用**：从匹配 class 的实例移走宿主指针并返回；后续需要 live Self 的成员调用失败，实例的普通 JS 属性仍存在。
- **实现**：非对象或 class_id 不符 → null；`obj.takeNativeSelf()`。
- **所有权 / 错误 / 调用**：不调用 finalizer、不释放对象或宿主指针；清理责任交回宿主。已 dispose 再调用返回 null，之后 GC finalizer 跳过空 payload。忽略 Handle 的 native_type，不验证 Runtime 归属，也不解开 Proxy。

### `Handle.prototype` (`src/binding/native.zig:459`)

- **签名**：`pub fn prototype(self: Handle, ctx: *JSContext) ?*core.Object`。
- **作用**：该 realm 的 class prototype。
- **实现**：`ctx.core.classPrototypeObject(self.native_type.class_id)`。
- **所有权 / 错误 / 调用**：按 class id 查询传入 context 的表，未安装或槽不是对象时返回 null；不要求该 context 就是首次 defineClass 的 realm。借用结果，不分配、不安装原型、不增加根。

---

## 成员 spec 生成

### `selfParamCheck` (`src/binding/native.zig:466`)

- **签名**：`fn selfParamCheck(comptime Self: type, comptime F: type, comptime what: []const u8) void`。
- **作用**：编译期断言成员函数第一参数是 `*Self`。
- **实现**：非 fn 或 params 空或类型不是 `*Self` → `@compileError`，消息带 `what`（method/getter/setter）。
- **所有权 / 错误 / 调用**：只检查函数形状及第一个参数的精确类型，不能证明接收者指针生命周期、函数体效果或其余参数/返回类型都合法；其余约束由各生成分支检查。

### `selfOf` (`src/binding/native.zig:473`)

- **签名**：`inline fn selfOf(comptime Self: type, raw: *anyopaque) *Self`。
- **作用**：opaque payload → `*Self`。
- **实现**：`@ptrCast(@alignCast(raw))`。
- **所有权 / 错误 / 调用**：只转换指针，不检查实际 payload 类型或存活状态；依赖分派前的 class/live-self 检查及宿主按正确类型包装的约定。

### `methodSpec` (`src/binding/native.zig:479`)

- **签名**：`pub fn methodSpec(comptime Self: type, comptime f: anytype) Spec`。
- **作用**：K2 方法：`fn (*Self, *Call) E!JSValue` → `method_managed`；typed `SELF_*` 形状 → `method_leaf`。
- **实现**：`n==1 && params[1]==*Call` 则生成 managed thunk（组 `Call`，`func_obj=null`，error union 走 `embedderErrorToValue`）。否则按 SELF_* 表匹配，`effect=leaf`，`arity=n`。不匹配 compile error。
- **所有权 / 错误 / 调用**：支持的 typed 形状是 Self→f64/i32/void、Self+f64→void、Self+f64+f64→void、Self+i32→i32/void；不是接受任意 SELF_* 签名。managed 方法 arity=0，typed 方法按 Self 之外参数计数；VM 在调用前检查 receiver。

### `native.thunk` (`src/binding/native.zig:488`)

- **签名**：`fn thunk(ctx: *core.JSContext, raw_self: *anyopaque, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：managed 方法的 C 入口。
- **实现**：`f(selfOf(Self, raw_self), &call)`，error union 映射。
- **所有权 / 错误 / 调用**：raw_self 由 VM 解包；Call.func_obj 明确为 null，ctx 是借用门面，argv 仍仅限本次调用。error union 使用 embedderErrorToValue，普通返回直接传回 JSValue。

### `native.t` (`src/binding/native.zig:507`)

- **签名**：`fn t(comptime i: usize) type`。
- **作用**：方法在 `*Self` 之后的第 i 个参数类型。
- **实现**：`params[1 + i].type.?`
- **所有权 / 错误 / 调用**：leaf 形状匹配。

### `native.self_to_f64` (`src/binding/native.zig:512`)

- **签名**：`fn self_to_f64(raw: *anyopaque) callconv(.c) f64`。
- **作用**：`fn (*Self) f64`。
- **实现**：`f(selfOf(Self, raw))`。
- **所有权 / 错误 / 调用**：leaf。

### `native.self_f64_to_void` (`src/binding/native.zig:515`)

- **签名**：`fn self_f64_to_void(raw: *anyopaque, a: f64) callconv(.c) void`。
- **作用**：`fn (*Self, f64) void`。
- **实现**：`f(selfOf(...), a)`。
- **所有权 / 错误 / 调用**：leaf。

### `native.self_f64_f64_to_void` (`src/binding/native.zig:518`)

- **签名**：`fn self_f64_f64_to_void(raw: *anyopaque, a: f64, b: f64) callconv(.c) void`。
- **作用**：`fn (*Self, f64, f64) void`。
- **实现**：`f(..., a, b)`。
- **所有权 / 错误 / 调用**：leaf。

### `native.self_i32_to_i32` (`src/binding/native.zig:521`)

- **签名**：`fn self_i32_to_i32(raw: *anyopaque, a: i32) callconv(.c) i32`。
- **作用**：`fn (*Self, i32) i32`。
- **实现**：`return f(...)`。
- **所有权 / 错误 / 调用**：leaf。

### `native.self_to_i32` (`src/binding/native.zig:524`)

- **签名**：`fn self_to_i32(raw: *anyopaque) callconv(.c) i32`。
- **作用**：`fn (*Self) i32`。
- **实现**：`return f(selfOf(Self, raw));`
- **所有权 / 错误 / 调用**：leaf。

### `native.self_i32_to_void` (`src/binding/native.zig:527`)

- **签名**：`fn self_i32_to_void(raw: *anyopaque, a: i32) callconv(.c) void`。
- **作用**：`fn (*Self, i32) void`。
- **实现**：`f(..., a)`。
- **所有权 / 错误 / 调用**：leaf。

### `native.self_to_void` (`src/binding/native.zig:530`)

- **签名**：`fn self_to_void(raw: *anyopaque) callconv(.c) void`。
- **作用**：`fn (*Self) void`。
- **实现**：`f(selfOf(Self, raw));`
- **所有权 / 错误 / 调用**：leaf。

### `getterSpec` (`src/binding/native.zig:555`)

- **签名**：`pub fn getterSpec(comptime Self: type, comptime f: anytype) Spec`。
- **作用**：K3 getter。typed `fn (*Self) f64|i32` 走 VM typed 臂（class 检查 + unwrap + boxing 在 VM，无 backtrace/preflight）；其它走 managed thunk（含 `fn (*Self, *Call)` 和 `fn (*Self) bool`）。
- **实现**：单参数且返回 f64/i32 → leaf template，`kind=.getter`，对应 `sig_self_to_f64/i32`。否则生成三参数 thunk：`nativeReceiverSelfOrThrow`，再按签名调 `f` 或 box。
- **所有权 / 错误 / 调用**：f64/i32 模板有非零 sig 和 leaf effect；bool 与 *Call 形式使用 sig=0 的 thunk，并非同一 typed leaf 路径。接收者不匹配时不调用 f；异常构造是否成功仍受底层错误处理影响。

### `native.self_to_f64` (`src/binding/native.zig:567`)

- **签名**：`fn self_to_f64(raw: *anyopaque) callconv(.c) f64`。
- **作用**：typed getter `fn (*Self) f64` 的 VM 直调目标。
- **实现**：`return f(selfOf(Self, raw));`
- **所有权 / 错误 / 调用**：PropertySite `.native_getter` 臂也可 `invokeTypedGetterFast` 到这类 entry。

### `native.self_to_i32` (`src/binding/native.zig:570`)

- **签名**：`fn self_to_i32(raw: *anyopaque) callconv(.c) i32`。
- **作用**：typed getter `fn (*Self) i32`。
- **实现**：`return f(selfOf(Self, raw));`
- **所有权 / 错误 / 调用**：同 f64 档。

### `native.thunk` (`src/binding/native.zig:583`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：非 typed（或 bool）getter 的 C 入口。
- **实现**：unwrap 失败返回 exception。*Call 分支使用 argc=0、argv=undefined、func_obj=null；bool 返回装箱。函数体还列出 f64/i32 装箱分支，但这些正常签名在生成器前面已选择独立 typed 目标。其他签名编译失败。
- **所有权 / 错误 / 调用**：accessor C 入口没有 argv 参数；managed getter 可使用 arg(i) 得到 undefined，但不应将未初始化 argv 当有效空数组传出。传给宿主的 Self 与 Call 都不因本 thunk 增加跨调用所有权。

### `setterSpec` (`src/binding/native.zig:617`)

- **签名**：`pub fn setterSpec(comptime Self: type, comptime f: anytype) Spec`。
- **作用**：K3 setter。typed `fn (*Self, f64|i32) void` 由 VM canonical marshal；managed `fn (*Self, *Call) E!void` 用 `call.arg(0)`。
- **实现**：必须恰好 2 参数。f64/i32+void → leaf template `kind=.setter` `arity=1`。否则 thunk：unwrap，`*Call` 则单元素 argv；f64/i32/bool 在 thunk 里 `marshal*` / `asBool`，失败 TypeError sentinel。
- **所有权 / 错误 / 调用**：bool setter 使用 sig=0 的 thunk，不属于 f64/i32 typed 分支；所有 setter arity=1。参数不匹配时不调用宿主函数，不做 JS ToNumber/ToBoolean；成功返回 undefined，managed 的错误经 embedderErrorToValue 映射。

### `native.self_f64_to_void` (`src/binding/native.zig:628`)

- **签名**：`fn self_f64_to_void(raw: *anyopaque, a: f64) callconv(.c) void`。
- **作用**：typed setter `fn (*Self, f64) void`。
- **实现**：`f(selfOf(Self, raw), a)`。
- **所有权 / 错误 / 调用**：VM 已 marshal。

### `native.self_i32_to_void` (`src/binding/native.zig:631`)

- **签名**：`fn self_i32_to_void(raw: *anyopaque, a: i32) callconv(.c) void`。
- **作用**：typed setter `fn (*Self, i32) void`。
- **实现**：`f(selfOf(Self, raw), a)`。
- **所有权 / 错误 / 调用**：同上。

### `native.thunk` (`src/binding/native.zig:645`)

- **签名**：`fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue`。
- **作用**：managed / bool setter 入口。
- **实现**：见 `setterSpec`。`argv` 是栈上单元素数组，Call 期间有效。
- **所有权 / 错误 / 调用**：返回 `undefined` 或 exception 哨兵。

### `State.step` (`src/binding/native.zig:689`)

- **签名**：`fn step(self: *@This(), dt: i32) i32`。
- **作用**：证明 typed 方法归为 `method_leaf` + `sig_self_i32_to_i32`。
- **实现**：`self.n += 1; return dt + 1;`
- **所有权 / 错误 / 调用**：`Class` 成员表测试。

### `State.query` (`src/binding/native.zig:693`)

- **签名**：`fn query(self: *@This(), call: *Call) JSValue`。
- **作用**：证明 managed 方法归为 `method_managed`。
- **实现**：返回 `call.arg(0)`。
- **所有权 / 错误 / 调用**：测试夹具。返回 `call.arg(0)` 是**借用**值，不 retain 也不建根；本测试只检查 `Class` 成员表把它归类为 `method_managed`，从不真正进 VM 调用它，所以 managed 方法本该有的异常/根协议在这里没有被行使。

### `State.time` (`src/binding/native.zig:697`)

- **签名**：`fn time(self: *@This()) f64`。
- **作用**：证明 getter 归为 `kind=.getter`。
- **实现**：`@floatFromInt(self.n)`。
- **所有权 / 错误 / 调用**：测试夹具：只读 `self.n`，不分配、无 error set。`self` 是 `Class` 的 payload 指针，由测试自己持有；这里只用于断言成员分类为 `kind=.getter`。

### `State.setTime` (`src/binding/native.zig:700`)

- **签名**：`fn setTime(self: *@This(), t: f64) void`。
- **作用**：证明 setter 归为 `kind=.setter`，名字 `"time"`。
- **实现**：`self.n = @intFromFloat(t)`。
- **所有权 / 错误 / 调用**：测试夹具：只写 `self.n`，不分配、无 error set；`@intFromFloat` 对 NaN/越界输入是未定义行为，但真实 setter 路径会先做 f64 标签检查。仅用于断言成员分类为 `kind=.setter`、名字 `"time"`。
