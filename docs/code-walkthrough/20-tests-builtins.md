# 20 — ECMAScript 内建可观察语义

`src/tests/builtins.zig` 钉 Array/String/Date/RegExp/Collection/Proxy 等内建，以及 native handler 的 realm 读权限。 源文件 `src/tests/builtins.zig`（6480 行）。

## `src/tests/builtins.zig`

`src/tests/builtins.zig` 钉 Array/String/Date/RegExp/Collection/Proxy 等内建，以及 native handler 的 realm 读权限。

文件头：Exercises built-in objects, native handlers, and observable realm semantics.

类型：唯一的文件级类型是 `EscapedEvalImportHost`（第 1346 行，字段 `expected_referrer: []const u8` 与 `saw_expected_referrer: bool = false`），作为 import 钩子的 `ptr` 上下文记录动态 import 看到的 referrer。此外是少量宿主探针（escaped eval 的 import resolve/load、Set `symmetricDifference` 变异 keys、填满 own-property storage 逼失败）。主体是 236 个 `test` 块：102 个用 `helpers.expectPrints` 比对 `print` 输出，98 个共用 `helpers.sharedTestEngine()` 跑 `assert.*` 脚本并由 `helpers.endSharedTest()` 复位，26 个自建 `helpers.TestEngine.init(std.testing.allocator)`，7 个直接 `core.JSRuntime.create` 手搭对象图；余下 3 个不起引擎，只 `@embedFile` 扫源码或直调 `engine.exec.math_ops.call`。

### 函数（清单 5）

### `escapedEvalImportResolve` (`src/tests/builtins.zig:1351`)

- **签名**：`fn escapedEvalImportResolve( ptr: *anyopaque, specifier: []const u8, referrer: ?[]const u8, allocator: std.mem.Allocator, ) anyerror!helpers.TestEngine.HostHooks.ResolvedModule`。
- **作用**：escaped direct eval 动态 import 的 resolve 钩子：把 `./dep.js` 与 `/fixture/scripts/dep.js` 之外的 specifier 判为 `error.ModuleNotFound`；遇到 `./dep.js` 时把 referrer 与 `EscapedEvalImportHost.expected_referrer` 比对，结果写回 `saw_expected_referrer` 供测试断言 referrer 仍是脚本路径。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.mem.eql`、`allocator.dupe`。显式 `return error.ModuleNotFound`。
- **所有权 / 错误 / 调用**：`specifier`/`path` 用传入的 `Allocator` dupe，所有权交给模块图加载器。以 `.resolveModule` 注册进 `HostHooks`（第 1397 行），返回 `anyerror!helpers.TestEngine.HostHooks.ResolvedModule` 由 `evalFileModuleGraphWithHostHooks` 消费。

### `escapedEvalImportLoad` (`src/tests/builtins.zig:1374`)

- **签名**：`fn escapedEvalImportLoad( _: *anyopaque, resolved: helpers.TestEngine.HostHooks.ResolvedModule, allocator: std.mem.Allocator, ) anyerror!helpers.TestEngine.HostHooks.LoadedModule`。
- **作用**：配套的 load 钩子：只接受已解析到 `/fixture/scripts/dep.js` 的模块，返回固定源码 `export const answer = 42;`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.mem.eql`、`allocator.dupe`。显式 `return error.ModuleNotFound`。
- **所有权 / 错误 / 调用**：`path` 用传入的 `Allocator` dupe，`source` 是静态字面量故 `.owned = false`。以 `.loadModule` 注册进 `HostHooks`（第 1398 行），返回 `anyerror!helpers.TestEngine.HostHooks.LoadedModule` 由 `evalFileModuleGraphWithHostHooks` 消费。

### `symmetricDifferenceMutatingKeysHost` (`src/tests/builtins.zig:5029`)

- **签名**：`fn symmetricDifferenceMutatingKeysHost( ctx: *core.JSContext, callback: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []engine.exec.globals.Slot, ) core.host_function.CallbackError!core.JSValue`。
- **作用**：set-like 的 `keys` 被 `Set.prototype.symmetricDifference` 调用时的宿主入口：丢掉 callback/this，转调 `Impl` 并把它的 Zig 错误映射成 `CallbackError`。
- **实现**：主体是 `switch` 分发。关键调用：`symmetricDifferenceMutatingKeysImpl`、`ctx.hasException`、`engine.exec.builtin_dispatch.nativeFromHostError`。
- **所有权 / 错误 / 调用**：以 `CallbackHost.call` 注册（第 5454 行）交 `collection_ops.methodCallWithCallbackHost` 调用。`Impl` 抛出的错误里，`CallbackError` 成员原样上抛；其余（含未挂异常的 `error.JSException`）先经 `nativeFromHostError` 落成 JS 异常再返回 `error.JSException`。

### `symmetricDifferenceMutatingKeysImpl` (`src/tests/builtins.zig:5056`)

- **签名**：`fn symmetricDifferenceMutatingKeysImpl( rt: *core.JSRuntime, args: []const core.JSValue, globals: []engine.exec.globals.Slot, ) !core.JSValue`。
- **作用**：真正的变异体：非零参（即 `has`）直接返回 `false`；零参的 `keys` 调用里先从 globals 取 `baseSet`，对它做两次 add（"b"、"c"，method id 4）与两次 delete（"b"、"d"，method id 6）制造接收者变异，再新建数组返回迭代序列 `["x", "b", "c", "c"]`。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`core.JSValue.boolean`、`engine.exec.globals.getByName`、`core.string.String.createUtf8`、`value`、`engine.exec.collection_ops.methodCall`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer core.Object.destroyFromHeader` 对称释放新建数组。返回 `!core.JSValue`，由 `symmetricDifferenceMutatingKeysHost` 捕获并映射成 `CallbackError`。

### `fillOwnPropertyStorageForFailure` (`src/tests/builtins.zig:6394`)

- **签名**：`fn fillOwnPropertyStorageForFailure(rt: *core.JSRuntime, object: *core.Object) !void`。
- **作用**：把对象的 own-property 存储填到 shape 容量上限（依次定义 `fill_0`、`fill_1`…），让下一次属性写入必须扩容，从而在内存上限下逼出可控的 `error.OutOfMemory`；超过 512 轮仍未填满就报 `error.TestUnexpectedResult`。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`object.shape_ref.props`、`std.fmt.bufPrint`、`rt.internAtom`、`object.defineOwnProperty`、`core.Descriptor.data`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：属性写在调用方传入的 `object` 上，生命周期归该测试自建并 `destroy` 的 Runtime。返回 `!void`，唯一调用方是第 5508 行的 host map 回滚测试，用 `try` 消费。

### 测试块（236）

### `test "native handler realm readers have an explicit observable or synthetic authority"` (`src/tests/builtins.zig:14`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：handler realm readers have an explicit observable or synthetic authority。
- **实现**：不起引擎，用 `@embedFile` 读 14 个 `src/exec/*_ops.zig` 源文件，每个文件在表里声明允许的合成全局读次数（`synthetic_global_reads` 与 `synthetic_globals_reads`，如 string 5 次、math/date/collection 2 次、atomics/promise/function/reflect 0 次）。循环里先断言源码出现 `callableRealm(host_call)`，再用 `std.mem.count` 数 `host_call.globals` 与 `host_call.global` 前缀、相减得到单数形式的读数并逐一 `expectEqual`；读数非零的文件还必须出现 `host_call.func_obj`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "dense array writer readers retain their semantic guard class"` (`src/tests/builtins.zig:51`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array writer readers retain their semantic guard class」。
- **实现**：不起引擎，用 `@embedFile` 读 9 个源文件（`core/object.zig`、`core/runtime.zig`、`core/array.zig` 与 `exec/` 下 array_builtin/array/json/object/string/vm_literal），以一张 23 行 `Reader` 表把每个 dense 写入口按 `WriterClass` 六类（own_overwrite / create_data_property / prewalk_set / already_walked_set / qjs_bulk_set / zjs_bulk_set）登记，循环里对每条调用串做 `std.mem.count` 精确计数（两条故意钉 0，防已删的无守卫写法复活）。表后再单独钉 `if (!self.canExtendFastArray())` 只 1 处、`is_std_array_prototype` 在 object.zig 存在、`any_prototype_may_have_indexed_properties` 在 runtime.zig 不存在。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Engine eval executes allocator-backed wide Math min max calls"` (`src/tests/builtins.zig:130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval executes allocator-backed wide Math min max calls」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(Math.min(9, 8, 7, 6, 5, 4)); print(Math.max(4, 5, 6, 7, 8, 9)); print(Math.abs()); print(Math.abs(undefined)); print(Math.abs(null)); `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "bare Math scalar fallback shares qjs edge semantics"` (`src/tests/builtins.zig:141`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bare Math scalar fallback shares qjs edge semantics」。
- **实现**：不起引擎，直调 `engine.exec.math_ops.call(id, args)` 的裸标量入口：id 4（round(-0.1) 保留负零）、id 6（pow(-1, +∞) 为 NaN）、id 7/8（min(0, -0) 得 -0、max(-0, 0) 不得负零）、id 9（random 需要 per-runtime 状态，这条 fallback 直接 `error.TypeError`）。断言错误 `error.TypeError`。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Math min max induction range fast path preserves observable method lookup"` (`src/tests/builtins.zig:166`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Math min max induction range fast path preserves observable method lookup」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let minSum = 0; for (let i = 0; i < 1000; i++) minSum += Math.min(i, 50); print(minSum); let maxSum = 0; for (let i = -3; i < 1000; i++) max`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "induction int32 sum range fast path preserves safe number results"` (`src/tests/builtins.zig:187`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「induction int32 sum range fast path preserves safe number results」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let sum = 0; for (let i = 0; i < 60000; i++) sum += i; print(sum); let large = 0; for (let i = 0; i < 1000000; i++) large += i; print(large,`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "latin1 string literal append range fast path preserves fallbacks"` (`src/tests/builtins.zig:201`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「latin1 string literal append range fast path preserves fallbacks」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let s = "a"; for (let i = 0; i < 5; i++) s += "xy"; print(s); let skipped = "z"; for (let i = 3; i < 1; i++) skipped += "x"; print(skipped);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "latin1 string literal append range fast path collapses loop opcodes"` (`src/tests/builtins.zig:219`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「latin1 string literal append range fast path collapses loop opcodes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let s = ""; for (let i = 0; i < 2000; i++) s += "x"; print(s.length);`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "latin1 string literal append range fast path accepts i8 loop limits"` (`src/tests/builtins.zig:240`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「latin1 string literal append range fast path accepts i8 loop limits」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let s = ""; for (let i = 0; i < 50; i++) s += "x"; print(s.length);`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "host output Number static literal fast path materializes lazy constructor"` (`src/tests/builtins.zig:261`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host output Number static literal fast path materializes lazy constructor」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`print(Number.parseInt("12345", 10));`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "empty script eval uses root entry without user call opcodes"` (`src/tests/builtins.zig:281`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「empty script eval uses root entry without user call opcodes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "short BigInt induction sum range fast path preserves exact results"` (`src/tests/builtins.zig:298`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「short BigInt induction sum range fast path preserves exact results」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let x = 0n; for (let i = 0n; i < 10000n; i++) x += i; print(x, typeof x); let y = 10n; for (let i = -3n; i < 4n; i++) y += i; print(y); let `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "simple numeric bytecode call range fast path preserves side effect fallback"` (`src/tests/builtins.zig:315`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「simple numeric bytecode call range fast path preserves side effect fallback」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function add(a, b) { return a + b; } let direct = 0; for (let i = 0; i < 1000; i++) direct += add(i, 1); print(direct); function make(x) { r`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "invariant int32 property and dense array range fast path preserves observable reads"` (`src/tests/builtins.zig:341`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「invariant int32 property and dense array range fast path preserves observable reads」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let own = { a: 1, b: 2 }; let ownSum = 0; for (let i = 0; i < 1000; i++) ownSum += own.a; print(ownSum); let proto = { a: 7 }; let child = O`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense array modulo field range fast path preserves observable reads"` (`src/tests/builtins.zig:372`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array modulo field range fast path preserves observable reads」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const a = { x: 1, y: 0 }; const b = { y: 0, x: 2 }; const c = { z: 0, x: 3 }; const arr = [a, b, c]; let s = 0; for (let i = 0; i < 1000; i+`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense array length indexed sum range fast path preserves observable reads"` (`src/tests/builtins.zig:395`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array length indexed sum range fast path preserves observable reads」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const direct = []; for (let i = 0; i < 1000; i++) direct[i] = i; let directSum = 0; for (let i = 0; i < direct.length; i++) directSum += dir`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array named property simple set cache observes prototype changes"` (`src/tests/builtins.zig:416`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array named property simple set cache observes prototype changes」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let first = [1]; first.a = 1; print(first.a); let setterCount = 0; Object.defineProperty(Array.prototype, "a", {   set: function(v) { setter`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array.prototype.push fast path observes inherited indexed setter"` (`src/tests/builtins.zig:437`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array.prototype.push fast path observes inherited indexed setter」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let seen = 0; Object.defineProperty(Array.prototype, "2", {   set: function(v) { seen = v; },   configurable: true }); let array = [1, 2]; l`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array dense writers distinguish own Set holes and CreateDataProperty"` (`src/tests/builtins.zig:455`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array dense writers distinguish own Set holes and CreateDataProperty」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     function hasOwn(object, key) {         return Object.prototype.hasOwnProperty.call(object, key);     }     var payload = `。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "push splice fill and unshift preserve prototype and payload semantics"` (`src/tests/builtins.zig:517`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「push splice fill and unshift preserve prototype and payload semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     function hasOwn(object, key) {         return Object.prototype.hasOwnProperty.call(object, key);     }     function run(o`。约 1 个 Zig expect、17 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array indexed setter guards follow the receiver realm"` (`src/tests/builtins.zig:580`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array indexed setter guards follow the receiver realm」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     function hasOwn(object, key) {         return Object.prototype.hasOwnProperty.call(object, key);     }     var other = $2`；`[10]`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array dense append guard distinguishes custom proxy and null prototypes"` (`src/tests/builtins.zig:636`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array dense append guard distinguishes custom proxy and null prototypes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     function hasOwn(object, key) {         return Object.prototype.hasOwnProperty.call(object, key);     }     var customPayl`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "standard Array prototype guard publication and invalidation are realm local"` (`src/tests/builtins.zig:686`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standard Array prototype guard publication and invalidation are realm local」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.__arrayGuardOther = $262.createRealm().global; globalThis.__arrayGuardPrototypeMutation = $262.createRealm().global; globalThis._`；`__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Object.prototype, "2147483648", { value: 1, configurable: true }); delete __arrayG`。约 20 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Array.prototype.push field2 fast path preserves observable guards"` (`src/tests/builtins.zig:815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array.prototype.push field2 fast path preserves observable guards」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let fast = []; for (let i = 0; i < 8; i++) fast.push(i); print(fast.length, fast[0], fast[7]); print(eval("let completion=[]; for (let i=0; `；`let completion=[]; for (let i=0; i<4; i++) completion.push(i);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "RegExp literal test range fast path preserves observable guards"` (`src/tests/builtins.zig:846`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp literal test range fast path preserves observable guards」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let c = 0; for (let i = 0; i < 8; i++) if (/a+b/.test("aaab")) c++; print(c); let miss = 0; for (let i = 0; i < 8; i++) if (/z+/.test("aaab"`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "sparse array literal fast paths preserve holes and length semantics"` (`src/tests/builtins.zig:870`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「sparse array literal fast paths preserve holes and length semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`"use strict"; let a = [1, , 3]; print(a.length, 0 in a, 1 in a, 2 in a, a[1] === undefined); let b = [, ,]; print(b.length, 0 in b, 1 in b);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "sparse array literal length add range fast path collapses loop opcodes"` (`src/tests/builtins.zig:891`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「sparse array literal length add range fast path collapses loop opcodes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "collection constructors iterate their array argument, not index it"` (`src/tests/builtins.zig:926`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「collection constructors iterate their array argument, not index it」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const a = [1, 2, 3]; a[Symbol.iterator] = function* () { yield 9; yield 8; }; print(JSON.stringify([...new Set(a)])); const pairs = [[1, "a"`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "collection constructors do not bulk fill past an overridable adder"` (`src/tests/builtins.zig:969`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「collection constructors do not bulk fill past an overridable adder」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const it = [1, 2, 3][Symbol.iterator](); let peeked = null; const seen = []; class Peeker extends Set {   add(v) {     seen.push(v);     if `。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "builtin iterator prototypes survive replacing globalThis.Iterator"` (`src/tests/builtins.zig:1015`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「builtin iterator prototypes survive replacing globalThis.Iterator」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const saved = globalThis.Iterator; const grandparent = (it) => Object.getPrototypeOf(Object.getPrototypeOf(it)); globalThis.Iterator = { pro`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array.of and Array.from run a Proxy constructor's construct trap"` (`src/tests/builtins.zig:1048`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array.of and Array.from run a Proxy constructor's construct trap」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function probe(run) {   let hits = 0;   const P = new Proxy(function C() { this.tag = "t"; }, {     construct(t, a, nt) { hits++; return Ref`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array.of and Array.from set factory result length with throw semantics"` (`src/tests/builtins.zig:1072`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array.of and Array.from set factory result length with throw semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.throws(TypeError, function() { Array.of.call(Uint8Array); }); assert.throws(TypeError, function() { Array.of.call(Uint8Array, 1); });`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array.from rejects invalid typed array element definitions"` (`src/tests/builtins.zig:1100`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array.from rejects invalid typed array element definitions」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.throws(TypeError, function() {   Array.from.call(Uint8Array, new Set([1, 2])); }); assert.compareArray(Array.of(1, 2), [1, 2]); asser`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Number.prototype.toString(radix) digits identify the double"` (`src/tests/builtins.zig:1119`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Number.prototype.toString(radix) digits identify the double」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print((2 ** 53).toString(3)); print((1 / 3).toString(7)); print((0.1).toString(3)); print((12345.6789).toString(36)); print((1e21).toString(`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "IteratorStep reads done and value off any result object, without class dispatch"` (`src/tests/builtins.zig:1154`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「IteratorStep reads done and value off any result object, without class dispatch」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function iterOf(make) {   return { [Symbol.iterator]() { let n = 0; return { next() {     if (n >= 3) return { done: true, value: undefined `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "every builtin iterator result inherits from Object.prototype"` (`src/tests/builtins.zig:1177`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「every builtin iterator result inherits from Object.prototype」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const iterators = [   [1].values(), [1].keys(), [1].entries(),   new Map([[1, 2]]).entries(), new Map([[1, 2]]).keys(), new Set([1]).values(`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array for-of fast path preserves iterator observability"` (`src/tests/builtins.zig:1204`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array for-of fast path preserves iterator observability」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let s = 0; for (let x of [1, 2, 3]) s += x; print(s); let a = [1, , 3]; Object.prototype[1] = 9; let inherited = 0; for (let x of a) inherit`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense array indexed append range preserves ordinary set guards"` (`src/tests/builtins.zig:1229`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense array indexed append range preserves ordinary set guards」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let fast = []; for (let i = 0; i < 8; i++) fast[i] = i; let sum = 0; for (let i = 0; i < fast.length; i++) sum += fast[i]; print(fast.length`；`let completionArray=[]; for (let i=0; i<4; i++) completionArray[i]=i;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array map simple callback range preserves closed induction and completion"` (`src/tests/builtins.zig:1294`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array map simple callback range preserves closed induction and completion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const a = [1,2,3,4,5,6,7,8,9,10]; let out; for (let i = 0; i < 100; i++) out = a.map(x => x + 1); print(out.length, out[0], out[9]); print(e`；`const e=[1,2]; let r; for (let j=0; j<4; j++) r=e.map(x=>x+1);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "global var induction add range preserves completion"` (`src/tests/builtins.zig:1305`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「global var induction add range preserves completion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var sum = 0; for (var i = 0; i < 1000; i++) sum += i; print(sum, i); print(eval("var evalSum=0; for (var j=0; j<4; j++) evalSum += j;")); pr`；`var evalSum=0; for (var j=0; j<4; j++) evalSum += j;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "global write induction range preserves strict writable semantics"` (`src/tests/builtins.zig:1315`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「global write induction range preserves strict writable semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`"use strict"; var g = -1; for (let i = 0; i < 1000; i++) g = i; print(g); var skipped = 7; for (let j = 5; j < 5; j++) skipped = j; print(sk`；`var eg = -1; for (let i = 0; i < 4; i++) eg = i;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "short BigInt induction add range preserves completion"` (`src/tests/builtins.zig:1336`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「short BigInt induction add range preserves completion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let x = 0n; for (let i = 0n; i < 4n; i++) x += i; print(x); print(eval("let y=0n; for (let j=0n; j<4n; j++) y += j;")); print(eval("let z=0n`；`let y=0n; for (let j=0n; j<4n; j++) y += j;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "escaped direct eval function keeps script referrer for dynamic import"` (`src/tests/builtins.zig:1389`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「escaped direct eval function keeps script referrer for dynamic import」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`eval("(function load(){ return import('./dep.js'); })")`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "escaped direct eval function keeps eval stack filename"` (`src/tests/builtins.zig:1425`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「escaped direct eval function keeps eval stack filename」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function evalThrower(){ throw new Error('boom'); })`。约 2 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval executes simple direct eval strings"` (`src/tests/builtins.zig:1450`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval executes simple direct eval strings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const x = 1; console.log(eval("x + 1")); console.log(eval("2 + 2"));`；`x + 1`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine script parse errors are never converted to source-shaped completions"` (`src/tests/builtins.zig:1458`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Engine script parse errors are never converted to source-shaped completions。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.SyntaxError`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "direct and indirect eval regexp literals share the generic parser semantics"` (`src/tests/builtins.zig:1468`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct and indirect eval regexp literals share the generic parser semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function checkPair(exact, terminated) {   assert.sameValue(exact.source, terminated.source);   assert.sameValue(exact.flags, terminated.flag`；`/a/gi`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "direct eval expression completion does not depend on a source terminator"` (`src/tests/builtins.zig:1491`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：direct eval expression completion does not depend on a source terminator。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function probe() {   assert.sameValue(eval('"value"'), eval('"value";'));   assert.sameValue(eval("this"), eval("this;")); } probe.call({ ma`；`this`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "test262 frontmatter comments do not change engine strict mode"` (`src/tests/builtins.zig:1519`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 test262 runner / harness：test262 frontmatter comments do not change engine strict mode。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`/*--- flags: [onlyStrict] ---*/ function acceptsEval(eval) { return eval; } print(acceptsEval(1));`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval executes declaration-only side effects"` (`src/tests/builtins.zig:1537`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval executes declaration-only side effects」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`delete globalThis.evalDeclOnlyVar; delete globalThis.evalDeclOnlyFunc; const indirectEval = (0, eval); print(indirectEval("var evalDeclOnlyV`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine direct eval follows resolved intrinsic eval binding"` (`src/tests/builtins.zig:1557`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval follows resolved intrinsic eval binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var a = 9; function directArg(eval, s) {   var a = 1;   return eval(s); } function directVar(f, s) {   var eval = f;   var a = 1;   return e`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parenthesized eval preserves only grouping directness"` (`src/tests/builtins.zig:1599`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parenthesized eval preserves only grouping directness」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var t = "global"; function group() {   var t = "local";   return (eval)("t"); } function comma() {   var t = "local";   return (1, eval)("t"`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval assignment reference timing follows ECMAScript"` (`src/tests/builtins.zig:1640`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval assignment reference timing follows ECMAScript」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function testAssignment() {   var x = 0;   var innerX = (function() {     x = (eval("var x;"), 1);     return x;   })();   print(innerX, x);`；`var x;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine strict unresolved assignment captures the reference before the RHS"` (`src/tests/builtins.zig:1676`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine strict unresolved assignment captures the reference before the RHS」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`"use strict"; try {   strictUnresolvedTarget = (this.strictUnresolvedTarget = 5);   print("stored", strictUnresolvedTarget); } catch (e) {  `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine grouped direct eval preserves assignment reference timing"` (`src/tests/builtins.zig:1692`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine grouped direct eval preserves assignment reference timing」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function testGroupedAssignment() {   var x = "outer";   var innerX = (function() {     x = ((eval)("var x = 1; 0"), 2);     return x;   })()`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine assignment RHS regexp and division preserve eval reference timing"` (`src/tests/builtins.zig:1709`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine assignment RHS regexp and division preserve eval reference timing」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var r; r = /\S+/g; print(r.test("a")); var out; out = "a".replace(/\S+/g, "test262"); print(out); var match; match = "abc".match(/(?<word>\w`；`var x = 2; 2`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval inherits caller scope through nested direct eval"` (`src/tests/builtins.zig:1734`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval inherits caller scope through nested direct eval」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var condition = 0; var evaluated = eval("while (condition < 5) eval(\"condition++\");"); print(condition, evaluated);`；`while (condition < 5) eval("condition++");`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine strict direct eval updates visible parameter refs"` (`src/tests/builtins.zig:1742`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine strict direct eval updates visible parameter refs」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function assign(code, p) {   "use strict";   eval(code);   return p; } print(assign("p = 2", 17)); function read(code, p) {   "use strict"; `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval captures outer names only mentioned in eval source"` (`src/tests/builtins.zig:1771`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval captures outer names only mentioned in eval source」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function outer(a) {   let x = 3;   var y = 4;   return function() {     return eval("a + x + y");   }; } print(outer(2)());`；`a + x + y`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval prefers an inner lexical declared before a later outer shadow"` (`src/tests/builtins.zig:1784`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval prefers an inner lexical declared before a later outer shadow」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function outer() {   let target;   { let x = 1; target = function() { return eval("x"); }; }   let x = 2;   return target(); } print(outer()`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine closure prefers an inner lexical declared before a later outer shadow"` (`src/tests/builtins.zig:1796`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine closure prefers an inner lexical declared before a later outer shadow」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function outer() {   let target;   { let x = 1; target = function() { return x; }; }   let x = 2;   return target(); } print(outer());`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval closures bind visible caller metadata"` (`src/tests/builtins.zig:1808`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval closures bind visible caller metadata」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function localLexical() {   let x = 1;   const y = 2;   var read = eval("(function(){ return x + y; })");   x = 10;   return read(); } funct`；`(function(){ return x + y; })`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval only exposes lexicals visible at call site"` (`src/tests/builtins.zig:1854`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval only exposes lexicals visible at call site」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function afterBlock() {   { let hidden = 1; }   return eval("typeof hidden"); } function siblingBlock() {   { let a = 1; }   { let b = 2; re`；`typeof hidden`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval executes control-flow smoke fixtures"` (`src/tests/builtins.zig:1884`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval executes control-flow smoke fixtures」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let sum = 0; for (let i = 0; i < 5; i++) sum += i; print(sum); let i = 0; while (i < 3) { i++; } print(i); function classify(n) {   if (n < `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval private names require lexical class scope"` (`src/tests/builtins.zig:1908`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval private names require lexical class scope」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function evil() { return eval("this.#x"); } class C {   #x = 7;   good() { return eval("this.#x"); }   bad(fn) { return fn.call(this); } } v`；`this.#x`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval boxes primitive with objects and catches nullish with"` (`src/tests/builtins.zig:1926`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval boxes primitive with objects and catches nullish with」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var foo = 1; with (2) { foo = 42; } print(foo); with (true) { foo = 43; } print(foo); with ("str") { foo = length; } print(foo); try { with `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval assigns through with object references"` (`src/tests/builtins.zig:1940`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval assigns through with object references」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var obj = { test262id: 1 }; with (obj) { test262id = 2; } print(obj.test262id); try { print(test262id); } catch (e) { print(e.name); } var c`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine dynamic environment nested with resolves outer object"` (`src/tests/builtins.zig:1967`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine dynamic environment nested with resolves outer object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var nestedWithValue = "global"; var outer = { nestedWithValue: "outer" }; var inner = {}; with (outer) {   with (inner) {     print(nestedWi`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine dynamic environment direct eval inside with resolves active object"` (`src/tests/builtins.zig:1980`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine dynamic environment direct eval inside with resolves active object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var evalWithValue = "global"; function readEvalWithValue() {   var evalWithValue = "local";   var object = { evalWithValue: "with" };   with`；`evalWithValue`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine ordered dynamic environment closure tracks nested with objects"` (`src/tests/builtins.zig:1994`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine ordered dynamic environment closure tracks nested with objects」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeOrderedWithState() {   var outer = { orderedWithValue: "outer" };   var inner = { orderedWithValue: "inner" };   var read;   wi`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine ordered dynamic environment eval closure tracks nested with objects"` (`src/tests/builtins.zig:2016`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine ordered dynamic environment eval closure tracks nested with objects」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var outer = { orderedEvalWithValue: "outer" }; var inner = { orderedEvalWithValue: "inner" }; function makeOrderedEvalWithReader() {   with `；`(function() { return orderedEvalWithValue; })`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval keeps internal completion slots out of with objects"` (`src/tests/builtins.zig:2036`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval keeps internal completion slots out of with objects」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var withTarget = { value: 1 }; with (withTarget) { print(eval("value")); } print(Object.keys(withTarget).join(","), withTarget["<ret>"]); va`；`value`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine ordered dynamic environment later eval captures earlier eval var"` (`src/tests/builtins.zig:2057`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine ordered dynamic environment later eval captures earlier eval var」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeEarlierEvalVarReader() {   eval("var earlierEvalValue = 'earlier';");   return eval("(function() { return earlierEvalValue; })"`；`var earlierEvalValue = 'earlier';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine ordered dynamic environment eval var shadows captured outer lexical"` (`src/tests/builtins.zig:2068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine ordered dynamic environment eval var shadows captured outer lexical」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function grand() {   let x = "grand";   return function parent() {     var child = function() { return x; };     eval("var x = 'eval';");   `；`var x = 'eval';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter dynamic environment ordinary closure prefers body eval var"` (`src/tests/builtins.zig:2082`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter dynamic environment ordinary closure prefers body eval var」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeBodyEvalOrdinaryReader(_ = eval("var x = 'arg';")) {   eval("var x = 'body';");   var read = function() { return x; };   return`；`var x = 'arg';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter dynamic environment eval closure prefers body eval var"` (`src/tests/builtins.zig:2094`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter dynamic environment eval closure prefers body eval var」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeBodyEvalDirectReader(_ = eval("var x = 'arg';")) {   eval("var x = 'body';");   return eval("(function() { return x; })"); } va`；`var x = 'arg';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter dynamic environment closures retain argument eval var"` (`src/tests/builtins.zig:2105`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter dynamic environment closures retain argument eval var」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeArgumentEvalReaders(_ = eval("var x = 'arg';")) {   var ordinary = function() { return x; };   var direct = eval("(function() {`；`var x = 'arg';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter dynamic environment delete removes argument eval var"` (`src/tests/builtins.zig:2117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter dynamic environment delete removes argument eval var」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function deleteArgumentEvalVar(   _ = eval("var x = 'arg'; print(delete x, typeof x);") ) {   print(typeof x); } deleteArgumentEvalVar(); pr`；`var x = 'arg'; print(delete x, typeof x);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine dynamic environment eval var object yields to nearer lexical closure"` (`src/tests/builtins.zig:2129`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine dynamic environment eval var object yields to nearer lexical closure」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function makeEscapingReader() {   eval("var evalShadowValue = 'eval';");   print(evalShadowValue);   return (function() {     let evalShadow`；`var evalShadowValue = 'eval';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine nested direct eval forwards named function bindings as ordinary variables"` (`src/tests/builtins.zig:2144`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine nested direct eval forwards named function bindings as ordinary variables」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var sloppyRef = function SloppyName() {   return function() {     eval("SloppyName = 1");     return SloppyName;   }; }; print(sloppyRef()()`；`SloppyName = 1`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine dynamic environment nested no-op eval preserves function binding"` (`src/tests/builtins.zig:2173`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine dynamic environment nested no-op eval preserves function binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function readRetainedEvalFunction() {   eval("function retainedEvalFunction() { return 'retained'; } eval('');");   return retainedEvalFunct`；`function retainedEvalFunction() { return 'retained'; } eval('');`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval after with uses global var binding"` (`src/tests/builtins.zig:2183`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval after with uses global var binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var fast = 1; var object = { fast: 10 }; var seenWith = 0; with (object) {   fast = fast + 1;   seenWith = fast; } var seenAfterWith = globa`；`fast = fast + 2; var evalMade = 7; evalResult = fast + globalThis.evalMade;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval var preserves readonly global property"` (`src/tests/builtins.zig:2199`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval var preserves readonly global property」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`Object.defineProperty(globalThis, "roEvalVar", { value: 1, writable: false, configurable: false }); eval('var roEvalVar; roEvalVar = 2; prin`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval updates top-level lexical bindings"` (`src/tests/builtins.zig:2207`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval updates top-level lexical bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let evalTopLevelLexical; eval("evalTopLevelLexical = 1; print(evalTopLevelLexical);"); print(evalTopLevelLexical, globalThis.evalTopLevelLex`；`evalTopLevelLexical = 1; print(evalTopLevelLexical);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval var bindings stay in caller function scope"` (`src/tests/builtins.zig:2220`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval var bindings stay in caller function scope」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var x = "outside"; (function() {   eval('var x = "inside";');   print("ordinary", x, globalThis.x); }()); print("ordinaryAfter", x);  var pa`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval catch bindings do not escape their scopes"` (`src/tests/builtins.zig:2241`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval catch bindings do not escape their scopes」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(eval("try { throw 1; } catch (caughtSimple) {} typeof caughtSimple")); print(eval("try { throw [1]; } catch ([caughtPattern]) {} typeo`；`try { throw 1; } catch (caughtSimple) {} typeof caughtSimple`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval function targeting a catch binding does not create a fallback var binding"` (`src/tests/builtins.zig:2255`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Engine direct eval function targeting a catch binding does not create a fallback var binding。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function scenario() {   try { throw 1; } catch (caughtFunction) {     eval("function caughtFunction(){ return 2; }");     print("inside", ca`；`function caughtFunction(){ return 2; }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval catch var stops at the first same-name catch binding"` (`src/tests/builtins.zig:2268`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval catch var stops at the first same-name catch binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var x = "global-x"; var log = ""; function g() {   try { throw 8; } catch (x) {     eval("var x = 42;");     log += x;   }   x = "g";   log `；`var x = 42;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval catch var creation is idempotent and checks outer lexicals"` (`src/tests/builtins.zig:2285`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval catch var creation is idempotent and checks outer lexicals」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function preserveCatchEvalVar() {   try { throw 1; } catch (x) { eval("var x = 2"); }   x = 7;   try { throw 2; } catch (x) { eval("var x = `；`var x = 2`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval var-object initialization preserves existing bindings"` (`src/tests/builtins.zig:2304`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval var-object initialization preserves existing bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function scenario() {   eval("var dynamicEvalVar = 1");   print(dynamicEvalVar);   eval("var dynamicEvalVar");   print(dynamicEvalVar); } sc`；`var dynamicEvalVar = 1`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine Annex B var copy does not use global function declaration validation"` (`src/tests/builtins.zig:2316`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Engine Annex B var copy does not use global function declaration validation。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`(0, eval)('Object.defineProperty(globalThis, "annexFalseDescriptor", { value: 9, writable: false, enumerable: false, configurable: false })'`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine strict eval declarations stay inside the eval environment"` (`src/tests/builtins.zig:2325`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine strict eval declarations stay inside the eval environment」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`eval('"use strict"; var strictGlobalVar = 1;'); print(typeof strictGlobalVar); (0, eval)('"use strict"; var strictIndirectVar = 1;'); print(`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine indirect eval lexical declarations stay in each eval environment"` (`src/tests/builtins.zig:2342`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine indirect eval lexical declarations stay in each eval environment」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print((0, eval)('let isolatedIndirectLet = 1; class IsolatedIndirectClass {}; isolatedIndirectLet + (typeof IsolatedIndirectClass === "funct`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval ignores popped shadows when capturing outer bindings"` (`src/tests/builtins.zig:2351`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval ignores popped shadows when capturing outer bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function outer() {   let x = "outer";   return function() {     var values = [];     { let x = "inner"; values.push(eval("x")); }     values`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval closures preserve dynamic scope instances"` (`src/tests/builtins.zig:2366`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval closures preserve dynamic scope instances」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var iterationReaders = []; for (let iterationValue = 0; iterationValue < 3; iterationValue++) {   iterationReaders.push(eval("() => iteratio`；`() => iterationValue`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval selects the nearest private environment"` (`src/tests/builtins.zig:2383`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval selects the nearest private environment」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`class OuterPrivateEnvironment {   #value = 1;   readNested() {     class InnerPrivateEnvironment {       #value = 2;       read() { return e`；`this.#value`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval var hoist in parameter initializer uses arg var object"` (`src/tests/builtins.zig:2399`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval var hoist in parameter initializer uses arg var object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var paramEvalVar = "global"; function scenario(   _ = eval("var paramEvalVar = 'eval';"),   later = paramEvalVar ) {   print("later", later)`；`var paramEvalVar = 'eval';`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval function hoist in parameter initializer uses arg var object"` (`src/tests/builtins.zig:2416`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval function hoist in parameter initializer uses arg var object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var paramEvalFn = "global"; function scenario(   _ = eval("function paramEvalFn() { return 'eval'; }"),   later = paramEvalFn() ) {   print(`；`function paramEvalFn() { return 'eval'; }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter eval seed orders lexical parameter before arg var object"` (`src/tests/builtins.zig:2433`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter eval seed orders lexical parameter before arg var object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var orderedParameter = "global"; var bodyRan = false; function scenario(   _ = eval("var orderedParameter;"),   orderedParameter ) {   bodyR`；`var orderedParameter;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine sloppy direct eval var closures survive and reuse redeclare binding"` (`src/tests/builtins.zig:2448`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine sloppy direct eval var closures survive and reuse redeclare binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var readEvalVar, writeEvalVar; function scenario() {   eval('var hoistedEvalVar = 1; readEvalVar = function() { return hoistedEvalVar; }; wr`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine nested direct eval reuses caller eval var object"` (`src/tests/builtins.zig:2463`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine nested direct eval reuses caller eval var object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function f() {   eval("var x = 1; eval('var y = 2; print(\"inner\", y); y = 3'); print(\"outer\", y)");   print("body", typeof x, y); } f();`；`var x = 1; eval('var y = 2; print("inner", y); y = 3'); print("outer", y)`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine nested direct eval inherits private name environment"` (`src/tests/builtins.zig:2480`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine nested direct eval inherits private name environment」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`class NestedPrivateEval {   #value = 42;   read() { return eval("eval('this.#value')"); } } print(new NestedPrivateEval().read());`；`eval('this.#value')`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter initializer closures capture the parameter environment"` (`src/tests/builtins.zig:2490`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter initializer closures capture the parameter environment」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function split(a, b = () => a) { var a = 2; return [b(), a].join(","); } function update(a, b = (a = 7, () => a)) { return b(); } function f`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine global eval nested Annex B declarations stay function local"` (`src/tests/builtins.zig:2501`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine global eval nested Annex B declarations stay function local」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`eval("function outerAnnexB(){ { function leakedAnnexB(){} } }"); outerAnnexB(); print(typeof globalThis.leakedAnnexB); var preservedAnnexB =`；`function outerAnnexB(){ { function leakedAnnexB(){} } }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine with object arguments property shadows implicit arguments"` (`src/tests/builtins.zig:2513`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine with object arguments property shadows implicit arguments」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function withArguments() {   with ({ arguments: "object" }) return arguments; } print(withArguments(5));`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval in parameter initializer observes parameter TDZ"` (`src/tests/builtins.zig:2522`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval in parameter initializer observes parameter TDZ」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function later(a = eval("b"), b = 1) {} function self(a = eval("a")) {} try { later(); } catch (error) { print(error.name); } try { self(); `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter initializer TDZ uses the real parameter bindings"` (`src/tests/builtins.zig:2531`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter initializer TDZ uses the real parameter bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function later(a = b, b = 1) {} function self(a = a) {} try { later(); } catch (error) { print(error.name); } try { self(); } catch (error) `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine async parameter grammar parses await only as an expression"` (`src/tests/builtins.zig:2540`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine async parameter grammar parses await only as an expression」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`async function propertyName(a = ({ await: 1 }).await) { return a; } async function nestedFunction(a = async () => await 1) { return a; } ass`；`async function invalid(a = await 1) {}`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine Dynamic Function preserves typed array subclass source"` (`src/tests/builtins.zig:2567`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine Dynamic Function preserves typed array subclass source」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let dynamicBodyEffects = 0; const X = Function("dynamicBodyEffects++; return class X extends Uint8Array {}")(); const value = new X(2); asse`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval callback passed to assert.throws keeps eval var scope"` (`src/tests/builtins.zig:2586`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval callback passed to assert.throws keeps eval var scope」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function scenario() {   eval("var evalAssertVar = 42; var callback = function() { if (eval('evalAssertVar') !== 42) throw new RangeError('ba`；`var evalAssertVar = 42; var callback = function() { if (eval('evalAssertVar') !== 42) throw new RangeError('bad value'); throw new TypeError`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine generator created by direct eval keeps eval var scope across resume"` (`src/tests/builtins.zig:2602`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine generator created by direct eval keeps eval var scope across resume」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function scenario() {   eval("var evalGenVar = 3; var make = function*() { yield evalGenVar; evalGenVar += 4; yield eval('evalGenVar'); retu`；`var evalGenVar = 3; var make = function*() { yield evalGenVar; evalGenVar += 4; yield eval('evalGenVar'); return evalGenVar; };`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine sloppy direct eval deleted var can be redeclared"` (`src/tests/builtins.zig:2630`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine sloppy direct eval deleted var can be redeclared」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function deleteScenario() {   eval('var deletedEvalVar = 1;');   print("made", deletedEvalVar);   print("delete", delete deletedEvalVar);   `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval declaration forms share the variable object"` (`src/tests/builtins.zig:2645`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval declaration forms share the variable object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`globalThis.evalDestructFallback = "global"; function destructScenario() {   eval("var { evalDestructFallback } = { evalDestructFallback: 1 }`；`var { evalDestructFallback } = { evalDestructFallback: 1 }; globalThis.readDestructFallback = () => evalDestructFallback`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine parameter and body eval variable objects stay distinct"` (`src/tests/builtins.zig:2674`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine parameter and body eval variable objects stay distinct」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function splitEvalEnvironments(   _ = eval("var splitEvalValue = 1; function readParameterEvalValue() { return splitEvalValue; }"),   readPa`；`var splitEvalValue = 1; function readParameterEvalValue() { return splitEvalValue; }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine sloppy direct eval function declarations conflict with body lexicals"` (`src/tests/builtins.zig:2688`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine sloppy direct eval function declarations conflict with body lexicals」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function check(source) {   try {     eval(source);     print("no error");   } catch (e) {     print(e.name);   } } check("function directEva`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine Annex B eval function hoist respects enclosing lexical bindings"` (`src/tests/builtins.zig:2706`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine Annex B eval function hoist respects enclosing lexical bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`eval("{ let blockedAnnexB = 1; { function blockedAnnexB() {} } }"); print(typeof blockedAnnexB); eval("{ function allowedAnnexB() { return 1`；`{ let blockedAnnexB = 1; { function blockedAnnexB() {} } }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine sloppy direct eval function hoist uses var object binding"` (`src/tests/builtins.zig:2724`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine sloppy direct eval function hoist uses var object binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var directEvalFn = "global"; function scenario() {   eval("function directEvalFn(){ return 'first'; } function directEvalFn(){ return 'secon`；`function directEvalFn(){ return 'first'; } function directEvalFn(){ return 'second'; }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval var refs do not shadow global callees"` (`src/tests/builtins.zig:2737`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval var refs do not shadow global callees」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function testcase() {   var x = "local";   eval("var y = 'evalvar'; print('after var', y);");   print("done"); } testcase();`；`var y = 'evalvar'; print('after var', y);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine function global data IC preserves binding guards"` (`src/tests/builtins.zig:2750`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine function global data IC preserves binding guards」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`globalThis.__zjsGlobalDataIcRead = 1; function __zjsGlobalDataIcReadFn() { return __zjsGlobalDataIcRead; } assert.sameValue(__zjsGlobalDataI`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine top-level var probes preserve QuickJS global object semantics"` (`src/tests/builtins.zig:2815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine top-level var probes preserve QuickJS global object semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var reflectedVar = 1; print("desc", Object.getOwnPropertyDescriptor(globalThis, "reflectedVar").writable, Object.getOwnPropertyDescriptor(gl`；`var blockedVarProbe;`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine global function declarations publish through construction-time VarRef cells"` (`src/tests/builtins.zig:2858`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine global function declarations publish through construction-time VarRef cells」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionData", { value: 1, writable: false, enumerable: false, configurable: true })'); (`；`Object.defineProperty(globalThis, "__qjsScriptFunction", { value: 1, writable: false, enumerable: false, configurable: true });`。约 0 个 Zig expect、16 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine top-level var probes preserve cross-realm global identity"` (`src/tests/builtins.zig:2899`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine top-level var probes preserve cross-realm global identity」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var otherRealm = $262.createRealm();     var other = otherRealm.global;     other.eval("var realmVarProbe = 1; realmVarPr`；`var realmVarProbe = 1; realmVarProbe = 2;`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine createRealm owns independent intrinsics with realm-local instanceof"` (`src/tests/builtins.zig:2928`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine createRealm owns independent intrinsics with realm-local instanceof」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var realm = $262.createRealm(); var other = realm.global; assert.sameValue(other.Array === Array, false); assert.sameValue([] instanceof Arr`；`[] instanceof Array`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "cross-realm construction uses class prototype state without observable realm keys"` (`src/tests/builtins.zig:2944`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cross-realm construction uses class prototype state without observable realm keys」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var R = $262.createRealm().global;     function realmKeys(value) {         return Object.getOwnPropertyNames(value).filte`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Object RegExp and TypedArray use their C function Realm state"` (`src/tests/builtins.zig:2994`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object RegExp and TypedArray use their C function Realm state」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var R = $262.createRealm().global;     assert.sameValue(Object.getPrototypeOf(R.Object("x")), R.String.prototype);     as`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine cross-realm eval keeps global lexical declarations per realm"` (`src/tests/builtins.zig:3029`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine cross-realm eval keeps global lexical declarations per realm」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let crossRealmLexicalProbe = 1; var other = $262.createRealm().global; other.eval("var crossRealmLexicalProbe = 2;"); assert.sameValue(cross`；`var crossRealmLexicalProbe = 2;`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "native builtin records use callee realm for errors and created objects"` (`src/tests/builtins.zig:3044`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：builtin records use callee realm for errors and created objects。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     var obj = {};     var wrapped = other.Object.create(obj);     assert.throws(Ty`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "collection callback adapter materializes errors in its explicit realm"` (`src/tests/builtins.zig:3067`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「collection callback adapter materializes errors in its explicit realm」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constructor static prototype and accessor handlers keep their callee realm"` (`src/tests/builtins.zig:3097`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constructor static prototype and accessor handlers keep their callee realm」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     try {         new other.Array(1.5);         throw new Test262Error("expected f`；`[1].values()`。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "bound and proxy wrappers defer realm switching to the final target"` (`src/tests/builtins.zig:3166`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bound and proxy wrappers defer realm switching to the final target」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     other.eval("globalThis.realmFunction = function () { return Array; }");     va`；`globalThis.realmFunction = function () { return Array; }`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array species compares exact realm intrinsics without skipping wrapper gets"` (`src/tests/builtins.zig:3199`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array species compares exact realm intrinsics without skipping wrapper gets」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     other.eval("globalThis.NamedArray = function Array(length) { this.length = len`；`globalThis.NamedArray = function Array(length) { this.length = length; };`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array species does not confuse a foreign native named Array with the intrinsic"` (`src/tests/builtins.zig:3281`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Array species does not confuse a foreign native named Array with the intrinsic。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`globalThis.__arraySpeciesRealmHandle = $262.createRealm(); globalThis.__arraySpeciesForeignGlobal = __arraySpeciesRealmHandle.global; global`；`var input = [1, 2]; input.constructor = __arraySpeciesNamedNative; var output = input.map(function (value) { return value; }); assert.sameVa`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray iterator methods accept cross-realm typed array receivers"` (`src/tests/builtins.zig:3321`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypedArray iterator methods accept cross-realm typed array receivers」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     var local = new Uint8Array([42, 36]);     var remote = new other.Uint8Array([4`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray iterator methods reject proxy-wrapped shared typed array receivers"` (`src/tests/builtins.zig:3340`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypedArray iterator methods reject proxy-wrapped shared typed array receivers」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function (global) {     const {Object, Reflect, SharedArrayBuffer, WeakMap} = global;     const {apply: Reflect_apply, construct: Reflect_c`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval assigns missing with references through outer scope"` (`src/tests/builtins.zig:3384`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval assigns missing with references through outer scope」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var obj = {}; with (obj) { missingWithTarget = "global"; } print(missingWithTarget); print(obj.missingWithTarget);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval resolves var initializer targets through with before RHS"` (`src/tests/builtins.zig:3393`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval resolves var initializer targets through with before RHS」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var obj = { test262id: 1 }; with (obj) {   var test262id = delete obj.test262id; } print(obj.test262id); print(test262id);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval hoists top-level block var declarations to global object"` (`src/tests/builtins.zig:3404`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval hoists top-level block var declarations to global object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var obj = {}; var readFoo = function() { return foo; }; with (obj) { var foo = "global"; } print(foo); print(readFoo()); print(obj.foo);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval keeps function var declarations local under captured with"` (`src/tests/builtins.zig:3415`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval keeps function var declarations local under captured with」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var obj = { value: "outer" }; with (obj) {   var f = function() {     var value = "local";     print(value);   };   f(); } print(obj.value);`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval resets if-statement completion like QuickJS"` (`src/tests/builtins.zig:3429`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval resets if-statement completion like QuickJS」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(eval("1; if (true) { }")); print(eval("2; if (true) { 3; }")); print(eval("2; if (false) { 3; }")); print(eval("2; if (false) { 3; } e`；`1; if (true) { }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval resets switch completion and falls through cases"` (`src/tests/builtins.zig:3445`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval resets switch completion and falls through cases」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(eval("1; switch (0) { case 1: 2; }")); print(eval("1; switch (1) { case 1: }")); print(eval("1; switch ('a') { case 'a': 2; default: 3`；`1; switch (0) { case 1: 2; }`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "host print call keeps aliasing and override semantics"` (`src/tests/builtins.zig:3458`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host print call keeps aliasing and override semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print("a", 1, true); var p = print; p("b"); print = function(value) { return "override:" + value; }; print("c");`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray array-like construction does not replay coercions after fast path bailout"` (`src/tests/builtins.zig:3470`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：TypedArray array-like construction does not replay coercions after fast path bailout。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var calls = 0; var value = {   valueOf: function() {     calls++;     return 7;   } }; var source = {}; source.length = 2; source[0] = value`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray defineProperty value conversion may detach buffer"` (`src/tests/builtins.zig:3496`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypedArray defineProperty value conversion may detach buffer」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var ta = new Int8Array([17]); assert.sameValue(Reflect.defineProperty(ta, 0, {     value: {         valueOf: function() {             ta.buf`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray and species accessors follow inherited QuickJS shape"` (`src/tests/builtins.zig:3527`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypedArray and species accessors follow inherited QuickJS shape」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var typedDesc = Object.getOwnPropertyDescriptor(TypedArray, Symbol.species); assert.sameValue(typedDesc.set, undefined); assert.sameValue(ty`。约 1 个 Zig expect、16 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Well-known symbol method aliases share lazy native identity"` (`src/tests/builtins.zig:3558`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Well-known symbol method aliases share lazy native identity」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(Array.prototype[Symbol.iterator], Array.prototype.values); assert.sameValue(Array.prototype[Symbol.iterator].name, "values"`。约 1 个 Zig expect、17 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "functionPrototypeFromGlobal alias preserves Function.prototype identity"` (`src/tests/builtins.zig:3590`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「functionPrototypeFromGlobal alias preserves Function.prototype identity」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(Object.getPrototypeOf(function () {}), Function.prototype); assert.sameValue(Object.getPrototypeOf(Function), Function.prot`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Date/Function prototype auto-init install preserves toPrimitive and hasInstance descriptors"` (`src/tests/builtins.zig:3607`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Date/Function prototype auto-init install preserves toPrimitive and hasInstance descriptors」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var dateDesc = Object.getOwnPropertyDescriptor(Date.prototype, Symbol.toPrimitive); assert.sameValue(typeof dateDesc.value, "function"); ass`。约 1 个 Zig expect、13 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Lazy standard native accessors preserve descriptors and receiver markers"` (`src/tests/builtins.zig:3634`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Lazy standard native accessors preserve descriptors and receiver markers」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var symbolDesc = Object.getOwnPropertyDescriptor(Symbol.prototype, "description"); assert.sameValue(typeof symbolDesc.get, "function"); asse`。约 1 个 Zig expect、31 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Map and Set size live on prototype getter rather than instances"` (`src/tests/builtins.zig:3684`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Map and Set size live on prototype getter rather than instances」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const mapDescriptor = Object.getOwnPropertyDescriptor(Map.prototype, "size"); assert.sameValue(typeof mapDescriptor.get, "function"); assert`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "typed array instances keep concrete class identity"` (`src/tests/builtins.zig:3712`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array instances keep concrete class identity」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var int32 = new Int32Array(new ArrayBuffer(16)); assert.sameValue(Object.getPrototypeOf(int32), Int32Array.prototype); assert.sameValue(Obje`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "RegExp lazy native accessors preserve descriptor and mutation semantics"` (`src/tests/builtins.zig:3734`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp lazy native accessors preserve descriptor and mutation semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var sourceDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "source"); assert.sameValue(typeof sourceDesc.get, "function"); assert.sa`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Buffer and TypedArray lazy native accessors preserve descriptor semantics"` (`src/tests/builtins.zig:3776`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Buffer and TypedArray lazy native accessors preserve descriptor semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var buffer = new ArrayBuffer(8); var byteLengthDesc = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength"); assert.sameValue`。约 1 个 Zig expect、22 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "standard constructors publish final prototype graphs and eager metadata"` (`src/tests/builtins.zig:3825`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standard constructors publish final prototype graphs and eager metadata」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function assertDataDescriptor(object, key, value, writable, enumerable, configurable) {     var descriptor = Object.getOwnPropertyDescriptor`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "DOMException participates in builtin construction protocols"` (`src/tests/builtins.zig:3866`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「DOMException participates in builtin construction protocols」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var direct = new DOMException("m", "n"); assert.sameValue(direct.name, "n"); assert.sameValue(direct.message, "m"); assert.sameValue(direct `。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Function apply CreateListFromArrayLike observes array indexed gets"` (`src/tests/builtins.zig:3898`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Function apply CreateListFromArrayLike observes array indexed gets」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function capture() {     return Array.prototype.join.call(arguments, ","); }  var ownCalls = 0; var ownAccessor = []; Object.defineProperty(`。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "String.fromCodePoint through apply follows CreateListFromArrayLike"` (`src/tests/builtins.zig:3964`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String.fromCodePoint through apply follows CreateListFromArrayLike」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(String.fromCodePoint.apply(null, { length: 2, 0: 65, 1: 66 }), "AB"); assert.sameValue(String.fromCodePoint.apply(null, [0x`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Function and Reflect apply preserve target classes and argument shapes"` (`src/tests/builtins.zig:4016`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Function and Reflect apply preserve target classes and argument shapes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function signature() {     return arguments.length + ":" + arguments[0] + ":"         + arguments[arguments.length - 1]; } var counts = [0, `；`    "(function foreign(value) { return this.base + value; })" ); assert.sameValue(foreign.apply({ base: 40 }, [2]), 42); async function asyn`。约 1 个 Zig expect、25 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise constructor resolve and reject functions inherit Function.prototype"` (`src/tests/builtins.zig:4138`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise constructor resolve and reject functions inherit Function.prototype」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var resolveFunction; var rejectFunction; new Promise(function(resolve, reject) {     resolveFunction = resolve;     rejectFunction = reject;`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "C function data callbacks are callable but not constructors"` (`src/tests/builtins.zig:4156`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C function data callbacks are callable but not constructors」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var resolveFunction; var rejectFunction; new Promise(function(resolve, reject) {     resolveFunction = resolve;     rejectFunction = reject;`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise resolving functions keep internal state off user properties"` (`src/tests/builtins.zig:4188`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise resolving functions keep internal state off user properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var savedResolve; var savedReject; var promise = new Promise(function(resolve, reject) {     savedResolve = resolve;     savedReject = rejec`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise self-resolution rejects with the caller realm TypeError"` (`src/tests/builtins.zig:4227`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise self-resolution rejects with the caller realm TypeError」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var resolveFunction; var promise = new Promise(function(resolve) {     resolveFunction = resolve; }); promise.then(undefined, function(reaso`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "cross-realm promise resolving data function keeps caller realm"` (`src/tests/builtins.zig:4240`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cross-realm promise resolving data function keeps caller realm」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     var other = $262.createRealm().global;     other.eval(         "globalThis.promise = new Promise(function(resolve) { " + `；`        "globalThis.promise = new Promise(function(resolve) { " +         "globalThis.resolvePromise = resolve; });"     );     try {       `。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.resolve rejects self-resolution from custom capability"` (`src/tests/builtins.zig:4269`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.resolve rejects self-resolution from custom capability」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var resolve; var reject; var promise = new Promise(function(_resolve, _reject) {     resolve = _resolve;     reject = _reject; }); function `。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.resolve returns an identity match before constructor validation"` (`src/tests/builtins.zig:4293`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.resolve returns an identity match before constructor validation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var receiver = {}; var constructorGets = 0; var promise = Promise.resolve(1); Object.defineProperty(promise, "constructor", {     configurab`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise capability executor keeps internal slot off user properties"` (`src/tests/builtins.zig:4343`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise capability executor keeps internal slot off user properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function C(executor) {     assert.sameValue(typeof executor, "function");     assert.sameValue("__zjs_promise_capability_slot" in executor, `。约 3 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.all preserves a resolve abrupt completion across IteratorClose"` (`src/tests/builtins.zig:4372`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.all preserves a resolve abrupt completion across IteratorClose」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var resolveError = new Test262Error("resolve-error"); var returnCalls = 0; var iterable = {   [Symbol.iterator]: function() {     return {  `。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise.all next abrupt completion does not close the iterator"` (`src/tests/builtins.zig:4406`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Promise.all next abrupt completion does not close the iterator。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var nextError = new Test262Error("next-error"); var returnCalls = 0; var iterable = {   [Symbol.iterator]: function() {     return {       n`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise.all preserves a then abrupt completion across IteratorClose"` (`src/tests/builtins.zig:4437`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.all preserves a then abrupt completion across IteratorClose」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var thenError = new Test262Error("then-error"); var returnCalls = 0; var iterable = {   [Symbol.iterator]: function() {     return {       n`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise combinator element callbacks inherit Function.prototype"` (`src/tests/builtins.zig:4473`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise combinator element callbacks inherit Function.prototype」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var resolveElementFunction; var rejectElementFunction; var resolveThenable = {     then: function(fulfill) {         resolveElementFunction `。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise combinator callbacks keep internal state off user properties"` (`src/tests/builtins.zig:4503`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise combinator callbacks keep internal state off user properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var saved; var p0 = new Promise(function() {}); p0.then = function(onFulfilled, onRejected) {     saved = onFulfilled;     return Promise.pr`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "pending Promise.then reactions run after deferred settlement"` (`src/tests/builtins.zig:4558`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pending Promise.then reactions run after deferred settlement」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var resolve; var p = new Promise(function(r) { resolve = r; }); var q = p.then(function(v) { print("first", v); return v + "!"; }); p.then(f`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "settled Promise.then reactions run as deferred jobs"` (`src/tests/builtins.zig:4595`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「settled Promise.then reactions run as deferred jobs」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Promise.resolve("ok")     .then(function(v) { print("then", v); return v + "!"; })     .then(function(v) { print("chain", v); }); Promise.re`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.finally callbacks keep internal state off user properties"` (`src/tests/builtins.zig:4619`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.finally callbacks keep internal state off user properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var savedFulfill; var savedReject; var cleanupCount = 0; var p = new Promise(function() {}); p.then = function(onFulfilled, onRejected) {   `。约 3 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.allSettled reject element callback is alreadyCalled guarded"` (`src/tests/builtins.zig:4660`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.allSettled reject element callback is alreadyCalled guarded」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let rejectCallCount = 0; let returnValue = {}; let error = new Test262Error(); function Constructor(executor) {     function reject(value) {`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.all accepts string iterables through the built-in Promise path"` (`src/tests/builtins.zig:4696`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.all accepts string iterables through the built-in Promise path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Promise.all("ab").then(v => {     print(v.length);     print(v[0]);     print(v[1]); }); print("after");`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.race accepts Set iterables through the built-in Promise path"` (`src/tests/builtins.zig:4716`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.race accepts Set iterables through the built-in Promise path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Promise.race(new Set([1, 2])).then(v => print(v)); print("after");`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.allSettled accepts Set iterables through the built-in Promise path"` (`src/tests/builtins.zig:4732`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.allSettled accepts Set iterables through the built-in Promise path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Promise.allSettled(new Set([1, 2])).then(v => {     print(v.length);     print(v[0].status);     print(v[0].value);     print(v[1].status); `。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise keyed combinators preserve enumerable own keys"` (`src/tests/builtins.zig:4754`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise keyed combinators preserve enumerable own keys」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`print(Promise.allKeyed.length); print(Promise.allSettledKeyed.name); var resolveFirst; var sym = Symbol("s"); var input = {     first: new P`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Promise.any accepts Set iterables through the built-in Promise path"` (`src/tests/builtins.zig:4799`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise.any accepts Set iterables through the built-in Promise path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Promise.any(new Set([1, 2])).then(v => print(v), e => print(e.name)); print("after");`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Object.defineProperty returns retained target object"` (`src/tests/builtins.zig:4815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object.defineProperty returns retained target object」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const proto = Map.prototype; const returned = Object.defineProperty(proto, "sentinel", { value: 7, writable: true, configurable: true }); pr`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Object constructor record preserves call and construct semantics"` (`src/tests/builtins.zig:4827`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object constructor record preserves call and construct semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const value = { marker: 1 }; assert.sameValue(Object.prototype.hasOwnProperty("Object"), false); assert.sameValue(Object(value), value); ass`。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "property compaction preserves enumeration order across interleaved deletes"` (`src/tests/builtins.zig:4865`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「property compaction preserves enumeration order across interleaved deletes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const object = {}; for (let i = 0; i < 16; i++) object["p" + i] = i * 10; for (let i = 0; i < 16; i += 2) delete object["p" + i]; assert.sam`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "shared engine baseline restore survives compacting global deletes"` (`src/tests/builtins.zig:4886`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared engine baseline restore survives compacting global deletes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const root = globalThis; const names = Object.getOwnPropertyNames(root); const descriptor = Object.getOwnPropertyDescriptor; for (const name`；`assert.sameValue(typeof Object, "function"); assert.sameValue(typeof Array, "function"); assert.sameValue(typeof globalThis, "object"); asse`。约 2 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "native cproto distinguishes construct-only and callable constructors"` (`src/tests/builtins.zig:4912`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：cproto distinguishes construct-only and callable constructors。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`assert.throws(TypeError, function() { Map(); }); assert.throws(TypeError, function() { Set(); }); assert.throws(TypeError, function() { Weak`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "WeakMap and WeakSet accept non-registered symbols as weak keys"` (`src/tests/builtins.zig:4931`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「WeakMap and WeakSet accept non-registered symbols as weak keys」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const key = Symbol("weak"); const other = Symbol("weak"); const map = new WeakMap([[key, 1]]); assert.sameValue(map.get(key), 1); assert.sam`。约 1 个 Zig expect、13 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "host WeakMap mutation closure rejects registered symbol keys"` (`src/tests/builtins.zig:4958`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host WeakMap mutation closure rejects registered symbol keys」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：只建裸 `core.JSRuntime`（不建 Context），其上的对象图随 `defer rt.destroy()` 一并回收；用 `std.testing.allocator` 查泄漏。

### `test "host WeakMap mutation closure links entries into existing weak index"` (`src/tests/builtins.zig:4985`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host WeakMap mutation closure links entries into existing weak index」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：只建裸 `core.JSRuntime`（不建 Context），其上的对象图随 `defer rt.destroy()` 一并回收；用 `std.testing.allocator` 查泄漏。

### `test "Set combinator results use the realm intrinsic prototype after global mutation"` (`src/tests/builtins.zig:5086`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set combinator results use the realm intrinsic prototype after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicSet = Set; function checkSetCombinators() {   var left = new IntrinsicSet([1, 2]);   var right = new IntrinsicSet([2, 3]);   va`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Map.groupBy result uses the realm intrinsic prototype after global mutation"` (`src/tests/builtins.zig:5119`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Map.groupBy result uses the realm intrinsic prototype after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicMap = Map; function checkGroupBy() {   var grouped = IntrinsicMap.groupBy([1, 2, 3, 4], function(value) {     return value % 2 `。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "RegExp call and String RegExpCreate use the realm intrinsic after global mutation"` (`src/tests/builtins.zig:5147`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp call and String RegExpCreate use the realm intrinsic after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicRegExp = RegExp; function checkRegExpCreate() {   var called = IntrinsicRegExp("abc", "i");   assert.sameValue(Object.getProtot`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Uint8Array.fromHex/fromBase64 use realm intrinsic prototypes after global mutation"` (`src/tests/builtins.zig:5181`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Uint8Array.fromHex/fromBase64 use realm intrinsic prototypes after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicUint8Array = Uint8Array; var IntrinsicArrayBuffer = ArrayBuffer; function checkCodecs() {   var hex = IntrinsicUint8Array.fromH`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Uint8Array fromBase64/toBase64 named options preserve alphabet and lastChunkHandling"` (`src/tests/builtins.zig:5216`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Uint8Array fromBase64/toBase64 named options preserve alphabet and lastChunkHandling」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var def = Uint8Array.fromBase64("YQ=="); assert.sameValue(def.length, 1); assert.sameValue(def[0], 0x61); var url = Uint8Array.fromBase64("Y`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "native Error Reflect.construct fallback uses the realm intrinsic after global mutation"` (`src/tests/builtins.zig:5236`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：Error Reflect.construct fallback uses the realm intrinsic after global mutation。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function Fake() {} Fake.prototype = 1; function checkNativeError(intrinsic, expectedName) {   var thrown = Reflect.construct(intrinsic, ["ms`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error.prototype.stack setter still recognizes the intrinsic after global mutation"` (`src/tests/builtins.zig:5275`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error.prototype.stack setter still recognizes the intrinsic after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicError = Error; var proto = IntrinsicError.prototype; function expectSetterRejects() {   var threw = false;   try {     proto.st`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "DisposableStack.move and dispose keep realm intrinsic prototypes after global mutation"` (`src/tests/builtins.zig:5309`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「DisposableStack.move and dispose keep realm intrinsic prototypes after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicDisposableStack = DisposableStack; var IntrinsicAsyncDisposableStack = AsyncDisposableStack; var IntrinsicSuppressedError = Sup`。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "JSON.parse uses realm intrinsic Object/Array prototypes after global mutation"` (`src/tests/builtins.zig:5358`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「JSON.parse uses realm intrinsic Object/Array prototypes after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicObject = Object; var IntrinsicArray = Array; var getProto = Object.getPrototypeOf; function checkJson() {   var parsed = JSON.p`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypedArray Reflect.construct fallback uses the realm intrinsic after global mutation"` (`src/tests/builtins.zig:5390`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypedArray Reflect.construct fallback uses the realm intrinsic after global mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var IntrinsicUint8Array = Uint8Array; function Fake() {} Fake.prototype = 1; function checkTypedArray() {   var view = Reflect.construct(Int`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Set.prototype.symmetricDifference tracks receiver mutations from a set-like keys call"` (`src/tests/builtins.zig:5416`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.symmetricDifference tracks receiver mutations from a set-like keys call」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "host map closure releases appended value when entry allocation fails"` (`src/tests/builtins.zig:5463`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host map closure releases appended value when entry allocation fails」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：只建裸 `core.JSRuntime`（不建 Context），其上的对象图随 `defer rt.destroy()` 一并回收；用 `std.testing.allocator` 查泄漏。

### `test "host map closure rolls back appended entry when size update fails"` (`src/tests/builtins.zig:5499`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host map closure rolls back appended entry when size update fails」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：只建裸 `core.JSRuntime`（不建 Context），其上的对象图随 `defer rt.destroy()` 一并回收；用 `std.testing.allocator` 查泄漏。

### `test "Set.prototype.isDisjointFrom propagates IteratorClose errors on early false"` (`src/tests/builtins.zig:5545`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.isDisjointFrom propagates IteratorClose errors on early false」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var closeError = new Test262Error("close-disjoint"); var returnCalls = 0; var other = {   size: 1,   has: function() { return false; },   ke`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Set.prototype.isSupersetOf propagates IteratorClose errors on early false"` (`src/tests/builtins.zig:5574`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.isSupersetOf propagates IteratorClose errors on early false」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var closeError = new Test262Error("close-superset"); var returnCalls = 0; var other = {   size: 0,   has: function() { return true; },   key`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Set relation IteratorClose rejects a non-object return result"` (`src/tests/builtins.zig:5603`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set relation IteratorClose rejects a non-object return result」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var returnCalls = 0; var other = {   size: 1,   has: function() { return false; },   keys: function() {     return {       next: function() `。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Set relation next abrupt completion does not close the iterator"` (`src/tests/builtins.zig:5628`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Set relation next abrupt completion does not close the iterator。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var nextError = new Test262Error("next-error"); var returnCalls = 0; var other = {   size: 1,   has: function() { return false; },   keys: f`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Set.prototype.union uses GetSetRecord order for set-like classes"` (`src/tests/builtins.zig:5661`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.union uses GetSetRecord order for set-like classes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var observedOrder = []; function observableIterator() {   var values = ["a", "b", "c"];   var index = 0;   return {     get next() {       o`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Set.prototype.intersection consumes set-like keys as a direct iterator"` (`src/tests/builtins.zig:5749`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.intersection consumes set-like keys as a direct iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var log = []; var keysIterator = {}; Object.defineProperty(keysIterator, Symbol.iterator, {   get: function() {     log.push("get @@iterator`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Set union methods copy receiver after reading set-like keys next"` (`src/tests/builtins.zig:5789`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set union methods copy receiver after reading set-like keys next」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function setLikeThatReplaces(set) {   return {     size: 0,     has: function() {       throw new Test262Error("set-like has should not be c`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Set.prototype.difference has branch ignores entries appended by receiver mutation"` (`src/tests/builtins.zig:5822`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Set.prototype.difference has branch ignores entries appended by receiver mutation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var seen = []; var set = new Set([1, 2, 3, 4]); var setLike = {   size: 100,   has: function(value) {     seen.push(value);     if (seen.len`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "URI globals use observable string coercion and reject malformed UTF-8"` (`src/tests/builtins.zig:5852`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「URI globals use observable string coercion and reject malformed UTF-8」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var object = {   valueOf: function() { return "^"; },   toString: function() { return " "; } }; assert.sameValue(encodeURI(object), "%20"); `。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "URI four byte decode range preserves globals and completion"` (`src/tests/builtins.zig:5878`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「URI four byte decode range preserves globals and completion」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function decimalToPercentHexString(n) {   var hex = "0123456789ABCDEF";   return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf]; } var count = 0; `。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "URI decodeUriUnits walks latin1 and utf16 widths"` (`src/tests/builtins.zig:5928`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「URI decodeUriUnits walks latin1 and utf16 widths」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(decodeURI(String.fromCharCode(0xA0) + "%41"), String.fromCharCode(0xA0, 0x41)); assert.sameValue(decodeURI(String.fromCharC`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "ArrayBuffer construct args share maxByteLength walk"` (`src/tests/builtins.zig:5956`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ArrayBuffer construct args share maxByteLength walk」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var ab = new ArrayBuffer(8, { maxByteLength: 16 }); assert.sameValue(ab.byteLength, 8); assert.sameValue(ab.maxByteLength, 16); assert.sameV`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval builds frozen tagged template objects with raw arrays"` (`src/tests/builtins.zig:5984`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval builds frozen tagged template objects with raw arrays」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`` var captured; (function(strings, value) {   captured = strings;   assert.sameValue(value, 1); })`head${1}tail`; assert.sameValue(captured[0] ``。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval applies tagged template before new invocation"` (`src/tests/builtins.zig:6009`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval applies tagged template before new invocation」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function Constructor(value) {   print(value); } var tag = function(strings) {   print(strings[0]);   return Constructor; }; var first = new `。约 0 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval permits invalid escapes only in tagged template cooked values"` (`src/tests/builtins.zig:6025`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval permits invalid escapes only in tagged template cooked values」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`` (function(strings) {   assert.sameValue(strings[0], undefined);   assert.sameValue(strings.raw[0], "\\xg"); })`\xg`; (function(strings, valu ``。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval closures inherit direct eval function declarations"` (`src/tests/builtins.zig:6045`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval closures inherit direct eval function declarations」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let objs = []; function tag(templateObject) {   objs.push(templateObject); } for (let a = 0; a < 2; a++) {   eval("(function(){ for (let b =`；`` (function(){ for (let b = 0; b < 2; b++) { tag`${a}${b}`; } })(); ``。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "destructured parameter default class keeps initialized parameter bindings"` (`src/tests/builtins.zig:6061`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「destructured parameter default class keeps initialized parameter bindings」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let f = ([cls = class {}, named = class Named {}]) => {   assert.sameValue(cls.name, "cls");   assert.sameValue(named.name, "Named"); }; f([`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "top-level lexical destructuring reuses its predeclared global cells"` (`src/tests/builtins.zig:6076`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「top-level lexical destructuring reuses its predeclared global cells」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let { first } = { first: 1 }; const [second] = [2]; assert.sameValue(first, 1); assert.sameValue(second, 2);`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "for-of var destructuring predeclares generic binding patterns"` (`src/tests/builtins.zig:6090`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-of var destructuring predeclares generic binding patterns」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var seen = 0; for (var [first = 23] of [[undefined]]) seen += first; for (var { value: second } of [{ value: 19 }]) seen += second; assert.s`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "block function closures keep the current lexical binding cells"` (`src/tests/builtins.zig:6104`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「block function closures keep the current lexical binding cells」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function outer() {   {     let z = 4;     const v = 6;     function read() { return z + v; }     assert.sameValue(read(), 10);   } } outer()`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "nested assignment patterns preserve yield identifier and expression grammar"` (`src/tests/builtins.zig:6123`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested assignment patterns preserve yield identifier and expression grammar」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var yield = "key"; var direct = {}; [[direct[yield]]] = [[22]]; assert.sameValue(direct.key, 22); var suspended = {}; var iterator = (functi`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class field initializers inherit QuickJS arguments grammar"` (`src/tests/builtins.zig:6145`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class field initializers inherit QuickJS arguments grammar」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`for (const source of [   "class C { static value = arguments; }",   "class C { static value = () => arguments; }",   "class C { value = argu`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "captured derived this binding can only be initialized once"` (`src/tests/builtins.zig:6166`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「captured derived this binding can only be initialized once」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let callSuperAgain; class Base {} class Derived extends Base {   constructor() {     super();     callSuperAgain = () => super();   } } new `。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class name binding is in TDZ throughout its heritage expression"` (`src/tests/builtins.zig:6186`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class name binding is in TDZ throughout its heritage expression」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`for (const source of [   "class Inner extends Inner {}",   "class Inner extends (Inner) {}",   "var Outer = class Inner extends Inner {}", ]`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class computed names observe the class name TDZ"` (`src/tests/builtins.zig:6203`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class computed names observe the class name TDZ」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function expectComputedNameTdz(run) {   var threw = false;   try { run(); } catch (e) { threw = e instanceof ReferenceError; }   assert.same`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array and String iterator prototypes inherit @@iterator from Iterator.prototype"` (`src/tests/builtins.zig:6223`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array and String iterator prototypes inherit @@iterator from Iterator.prototype」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function expectIteratorChain(iterator) {   var proto1 = Object.getPrototypeOf(iterator);   var proto2 = Object.getPrototypeOf(proto1);   ass`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Object.assign writes through a proxy set trap"` (`src/tests/builtins.zig:6243`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object.assign writes through a proxy set trap」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var set = []; var p = new Proxy({}, { set: function (o, k, v) { set.push(k); o[k] = v; return true; }}); Object.assign(p, { foo: 1, bar: 2 }`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "String match and search Get a proxy matcher then ToPrimitive"` (`src/tests/builtins.zig:6257`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String match and search Get a proxy matcher then ToPrimitive」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function expectWellKnownThenToPrimitive(run, wellKnown) {   var get = [];   var proxied = {};   proxied[Symbol.toPrimitive] = Function();   `。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class static blocks use their installed receiver as the super home object"` (`src/tests/builtins.zig:6279`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class static blocks use their installed receiver as the super home object」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function Parent() {} Parent.inherited = 42; let observed; class Child extends Parent {   static { observed = super.inherited; } } assert.sam`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "body function declarations reuse same-name parameter bindings"` (`src/tests/builtins.zig:6296`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「body function declarations reuse same-name parameter bindings」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function declarationWins(x) {   assert.sameValue(typeof x, "function");   assert.sameValue(x(), 42);   function x() { return 42; } } declara`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "parameter-expression and body environments classify body functions by recorded scope"` (`src/tests/builtins.zig:6317`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parameter-expression and body environments classify body functions by recorded scope」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const f = (p = eval("var arguments = 'parameter'"), read = () => arguments) => {   function arguments() { return "body"; }   assert.sameValu`；`var arguments = 'parameter'`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "eval source conversion combines valid UTF-16 surrogate pairs"` (`src/tests/builtins.zig:6333`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：source conversion combines valid UTF-16 surrogate pairs。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`` const rawUnicodePattern = eval(`/\uD83D\uDC38/u`); assert.sameValue(rawUnicodePattern.test("\u{1F438}"), true); ``。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "invalid opcode reports invalid bytecode without context exception"` (`src/tests/builtins.zig:6345`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「invalid opcode reports invalid bytecode without context exception」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBytecode`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module top-level await works in object computed property names"` (`src/tests/builtins.zig:6358`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module top-level await works in object computed property names」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let o = { [await 9]: 9 }; assert.sameValue(o[await 9], 9); assert.sameValue(o[String(await 9)], 9);`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "module top-level await works in class computed fields inside try"` (`src/tests/builtins.zig:6371`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module top-level await works in class computed fields inside try」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`try {   let C = class {     [await 9] = 9;     static [await 9] = 9;   };   let c = new C();   assert.sameValue(c[await 9], 9);   assert.sam`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Math.min/max and hasOwnProperty exec_direct arms keep the qjs semantics on the miss legs"` (`src/tests/builtins.zig:6405`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Math.min/max and hasOwnProperty exec_direct arms keep the qjs semantics on the miss legs」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var max = Math.max, min = Math.min; print(max(1, 7, 3), min(1, 7, 3), max(4), min(4), max(), min()); print(max(1.5, 2, 0.25), min(1.5, 2, 0.`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部同样取 `helpers.sharedTestEngine()` 并 `defer endSharedTest()`，共享 Runtime 因此被清异常与未处理 rejection、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

## 覆盖核对

- 清单函数数: 5
- 本文标题覆盖: 241
- 未覆盖: 无
