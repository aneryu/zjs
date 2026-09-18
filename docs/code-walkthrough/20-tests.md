# 20 — 测试入口与 Zig 单测（函数级）

本册讲测试**编译根**、共享夹具和中小测试文件。大文件按源码体积拆到 `20-tests-core.md` / `20-tests-parser.md` / `20-tests-exec.md` / `20-tests-builtins.md`。

约定见 [`docs/testing-graph.md`](../testing-graph.md)：Class A 相对导入、Class B `@import("zjs")`、每产物独立 `addOptions`、`helpers.zig` 只能给 Class B。

## 编译根（shell）

这些文件几乎没有业务函数，职责是 attest 配置签名并用 `refAllDecls` 拉进对应测试族。它们**不在** `_inventory.tsv` 里（没有 `fn`），但仍必须讲清楚，否则分片目标对不上。

| Shell | 步骤 | Filter | 类 | 拉入 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `src/core_tests.zig` | `test-core` | `tests.core.` | Class B | `src/tests/core.zig` | core 值/对象/GC/所有权 |
| `src/parser_tests.zig` | `test-parser` | `tests.parser.` | Class B | `src/tests/parser.zig` | 词法+语法+发射 |
| `src/bytecode_tests.zig` | `test-bytecode` | `tests.bytecode.` | Class B | `src/tests/bytecode.zig` | 字节码载体与 pipeline |
| `src/exec_tests.zig` | `test-exec` | `tests.exec.` | Class B | `src/tests/exec.zig` | VM 与执行语义 |
| `src/builtins_tests.zig` | `test-builtins` | `tests.builtins.` | Class B | `src/tests/builtins.zig` | ECMAScript 内建 |
| `src/runtime_tests.zig` | `test-runtime` | `runtime.` | Class A | `src/runtime/root.zig` | 事件循环与宿主运行时（相对导入，禁止 `@import("zjs")`） |
| `src/runner_tests.zig` | `test-runner` | `cli.run_test262` | Class B | `src/cli/run_test262.zig` | test262 runner；attest 字符串与可执行根相同 |
| `src/compiler_tests.zig` | `test-compiler` | `compiler.` | Class A | `src/compiler/root.zig` | 编译器 QCP；`test { _ = @import("compiler/root.zig"); }` |
| `src/embedding_tests.zig` | `test-embedding / check-embedding` | `tests.embedding_examples.` | Class B（公共 `src/root.zig`） | `src/tests/embedding_examples.zig` | **不 attest**：公共模块不导出 `config_signature` |
| `src/leak_census_tests.zig` | `test-leak-census` | 无编译期 filter；运行期 `--repeat 2 --leak-census` | Class B | `src/tests/exec.zig` + `src/tests/builtins.zig` | 同一二进制跑两遍共享层，pass 0 预热、pass 1 开泄漏门 |

每个 Class B shell 的形态都是：`comptime { @import("zjs").config_signature.attest("test-X"); }` 再 `test { std.testing.refAllDecls(...); }`。`src/runtime_tests.zig` 改走 `@import("config_signature.zig").attest("test-runtime")`。`src/embedding_tests.zig` 只有 `refAllDecls`，没有 attest。

这些 `test {` 匿名块本身没有函数名，覆盖核对比的是下面真正的 `fn`。

## `src/all_tests.zig` — 统一套件根

统一测试编译根。Re-export `internal_root` 的全部公开名，再叠一层公共嵌入面镜像。`Object` 是唯一允许类型不一致的例外（公共不透明 facade vs 内部带 `create`）。生产 CLI 编 `internal_root`；`zig build test` 编本文件。

文件头：Unified test root that exposes engine subsystems and imports every test family.

### 函数（清单 2）

### `refAllDeclsRecursive` (`src/all_tests.zig:81`)

- **签名**：`fn refAllDeclsRecursive(comptime Container: type, comptime visited: anytype) void`。
- **作用**：在测试二进制里递归引用容器的全部声明，迫使 comptime 与嵌套测试被实例化；用 `visited` 元组切断类型环。
- **实现**：主体是 `switch` 分发。含循环。关键调用：`refAllDeclsRecursive`、`@setEvalBranchQuota`、`@import`、`std.meta.declarations`、`@field`、`@typeInfo`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `isInternalDeclException` (`src/all_tests.zig:120`)

- **签名**：`fn isInternalDeclException(comptime name: []const u8) bool`。
- **作用**：统一根与 `internal_root` 允许类型不一致的名字表（目前只有 `Object`）。
- **实现**：含循环。关键调用：`isInternalDeclException`、`std.mem.eql`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（2）

### `test "all_tests is a superset of internal_root"` (`src/all_tests.zig:127`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「all_tests is a superset of internal_root」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test` (`src/all_tests.zig:140`)

- **签名**：无参数测试块，返回 `!void`（匿名 `test { ... }`，靠 `refAllDecls` 拉入）。
- **作用**：把统一二进制要包含的全部测试族与子系统拉进来编译。
- **实现**：先 `refAllDeclsRecursive(internal.public_api, .{})` 递归引用公共面，再对各测试族逐个 `std.testing.refAllDecls`：`tests/engine_production.zig`、`tests/oom_cap.zig`、`tests/embedding_examples.zig`、`tests/core.zig`、`tests/bytecode.zig`、`tests/parser.zig`、`tests/exec.zig`、`tests/builtins.zig`、`runtime`；之后是非模块根的相对导入 `tests/abi_layout.zig`、`binding/native_call_plan.zig`、`abi/sdk.zig`、`tests/gc_stress.zig`、`tests/stress.zig`、`cli/zjs.zig`、`cli/run_test262.zig`。stress 层编进同一二进制、运行期按名字前缀选（`--only-prefix tests.stress.` / `--skip-prefix tests.stress.`），省掉第二次 Debug 引擎编译。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

## `src/tests/helpers.zig` — Class B 共享夹具

所有 Class B 测试的共享 harness。历史上是 `exec.zig` 的 `helpers` 命名空间，所以调用点仍写 `helpers.foo`。内部 `@import("zjs")`，Class A 根禁止导入。`compiler/tests.zig` 与 in-tree runtime 测试禁止再导入本文件，否则 `file exists in two modules`。

### 类型

- `Limits`：可选 `memory_bytes` / `stack_bytes` / `gc_threshold_bytes`，给 `TestEngine.initWithOptions`。
- `ExceptionInfo`：持有 `JSValueHandle`；`deinit` 放句柄；`getMessage` 拼 `name: message` 或走 `appendValueString`。
- `EngineOptions`：分配器、可选 `trace_writer`、`Limits`。
- `EvalOptions`：即 `core.context.ContextEvalOptions`。
- `TestEngine`：测试侧 Runtime+Context+EventLoop。`init` 走 `JSRuntime.createWithOptions`、`registerStandardGlobalsBare`、native 栈×4、`JSContext.create`、堆上 `EventLoop.initCore` 并 `install`。`deinit` 排空 job、`cleanupTest262Agents`、清 atomics waiter、销毁 context/runtime。eval 族最终进 `JSContext.borrowCore.eval`；模块图走 `module_graph.evalFileModuleGraph*`。`createExternalHostFunctionValue` 把旧 `(ptr, ExternalCall)` 探针收成 managed `NativeEntry` + `LegacyProbeState`。
- `SharedBaselineVarRef`：共享引擎快照里 VARREF 格子的值/lexical/const/deletable。
- `vm_helpers`：`parseAndRunWithTopLevelChildren` / `parseStmtAndRunWithTopLevelChildren` 在裸 ParseState 上 finalize 再 `runMutableVm`。
- `LegacyProbeState`：`finalize` 调可选 ExternalFinalizer 再 `memory.destroy`；`thunk` 是 NB2 `callconv(.c)`。

进程级共享引擎：`sharedTestEngine()` 用 `page_allocator` 建一次，空 `eval(";")` 后快照全局 shape/属性/VARREF；`endSharedTest` 清异常与 job、还原属性布局（期间关掉 allocation-triggered GC）、跑环回收，leak-census 第二遍对非模块增长执行分配高水位门（容差 8）。`atexit` → `deinitSharedTestEngine`。

### 函数（清单 56）

### `evalTypeScriptChecked` (`src/tests/helpers.zig:23`)

- **签名**：`pub fn evalTypeScriptChecked(engine_instance: *TestEngine, source: []const u8, options: EvalOptions) RuntimeError!core.JSValue`。
- **作用**：所有 TypeScript 执行测试的唯一入口，转给 `TestEngine.evalWithOptions`（语法擦除，不是类型检查）。
- **实现**：Every TypeScript execution test goes through here.。关键调用：`engine_instance.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `registerStandardGlobalsBare` (`src/tests/helpers.zig:31`)

- **签名**：`pub fn registerStandardGlobalsBare(rt: *core.JSRuntime) void`。
- **作用**：给绕过 binding 层、直接 `JSRuntime.create` 的测试安装标准全局；与 installer 容量不变量绑在一起，幂等。
- **实现**：Install the standard + host globals on a bare `core.JSRuntime` global for tests that build a runtime directly (bypassing the binding-layer context create that wires the installer). The deep setup interface keeps the installer callback and its capacity invariant together. Idempotent.。关键调用：`engine.exec.standard_globals.configureRuntime`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `installHostGlobalsBare` (`src/tests/helpers.zig:35`)

- **签名**：`pub fn installHostGlobalsBare(rt: *core.JSRuntime, global: *core.Object) !void`。
- **作用**：先 `configureRuntime`，再 `installHostGlobals` 把宿主 print 等装到给定 global。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`registerStandardGlobalsBare`、`exec_call.installHostGlobals`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `makeFunction` (`src/tests/helpers.zig:41`)

- **签名**：`pub fn makeFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode`。
- **作用**：intern 名字 `exec`，`Bytecode.init` 后 `setCodeAndStackSize`（含 stack_size 计算）；失败 `errdefer deinit`。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`setCodeAndStackSize`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `makeUncheckedFunction` (`src/tests/helpers.zig:49`)

- **签名**：`pub fn makeUncheckedFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode`。
- **作用**：同 `makeFunction` 但不跑 stack_size.compute，只 `setCode`。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`function.setCode`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `setCodeAndStackSize` (`src/tests/helpers.zig:57`)

- **签名**：`pub fn setCodeAndStackSize(function: *engine.bytecode.Bytecode, code: []const u8) !void`。
- **作用**：写入字节码并按 pipeline 计算 `stack_size`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`function.setCode`、`engine.bytecode.pipeline.stack_size.compute`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `runFunction` (`src/tests/helpers.zig:62`)

- **签名**：`pub fn runFunction(rt: *core.JSRuntime, ctx: *core.JSContext, function: *const engine.bytecode.Bytecode) !core.JSValue`。
- **作用**：给裸 Runtime 装标准全局，建 `Vm`，经 `runMutableVm` 跑夹具字节码。
- **实现**：`defer` 释放本次成功路径上的临时资源。关键调用：`registerStandardGlobalsBare`、`engine.exec.Vm.init`、`vm_instance.deinit`、`runMutableVm`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `runMutableVm` (`src/tests/helpers.zig:69`)

- **签名**：`pub fn runMutableVm(vm: *engine.exec.Vm, function: *const engine.bytecode.Bytecode) !core.JSValue`。
- **作用**：把顶层 Bytecode 的 cpool 窗口挂进 `ValueRootFrame`（夹具 Bytecode 在 native 栈上，tracing 扫不到 malloc 数组里的 child FB），再 `LegacyExecutionAdapter` 进 VM。
- **实现**：`defer` 释放本次成功路径上的临时资源。关键调用：`function.cpoolSlice`、`fixture_frame.activate`/`deactivate`、`execution_adapter.init`、`vm.run`。
- **所有权 / 错误 / 调用**：返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `reclaimNow` (`src/tests/helpers.zig:93`)

- **签名**：`pub fn reclaimNow(rt: *core.JSRuntime) void`。
- **作用**：跑 `runObjectCycleRemoval`（declared_only）。测试仍持有的对象必须出现在 root frame，缺根会失败而不是靠 conservative 碰巧活。
- **实现**：Reclaim whatever the test has made unreachable.  The scan is `declared_only` (via `runObjectCycleRemoval`), so anything the test still holds must be named in a `rootValues`/`rootObjects` frame. That is deliberate: it is the precise-scan discipline that makes these tests deterministic, and it is what turns a missing root into a test failure rather than into a conservative-scan accident.。主动触发/轮询 GC，断言存活集。关键调用：`rt.runObjectCycleRemoval`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `objectFromValue` (`src/tests/helpers.zig:97`)

- **签名**：`pub fn objectFromValue(value: core.JSValue) *core.Object`。
- **作用**：从 `JSValue` 取出 `*Object`；测试约定值一定是对象。
- **实现**：关键调用：`objectFromValue`、`core.value_semantics.objectFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectActiveSetStrings` (`src/tests/helpers.zig:101`)

- **签名**：`pub fn expectActiveSetStrings(object: *core.Object, comptime expected: []const []const u8) !void`。
- **作用**：遍历 collection 的 active 槽，按序比对 key 的字符串字节。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`object.collectionEntriesSlot`、`std.testing.expect`、`expectStringValueBytes`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectStringValueBytes` (`src/tests/helpers.zig:112`)

- **签名**：`pub fn expectStringValueBytes(value: core.JSValue, expected: []const u8) !void`。
- **作用**：断言值为 String：latin1 直接比字节，utf16 则逐 unit 等于 Latin-1 码点。
- **实现**：主体是 `switch` 分发。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`value.isString`、`value.asStringBody`、`string.resolveData`、`std.testing.expectEqualStrings`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectPrints` (`src/tests/helpers.zig:126`)

- **签名**：`pub fn expectPrints(source: []const u8, expected: []const u8) !void`。
- **作用**：共享引擎 `evalWithOutput`，结果须 undefined，stdout 精确等于 expected。
- **实现**：热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。复用进程级共享 `TestEngine`。关键调用：`sharedTestEngine`、`endSharedTest`、`std.Io.Writer`、`js.evalWithOutput`、`std.testing.expect`。
- **所有权 / 错误 / 调用**：用进程级共享 `TestEngine`，`defer endSharedTest()` 负责清异常/未处理 rejection、排空 job、还原全局 shape，因此调用方无需自建引擎。返回 `!void`，由测试 `try`/`expectError` 消费。

### `countJob` (`src/tests/helpers.zig:140`)

- **签名**：`pub fn countJob(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：job 探针：忽略参数，`job_counter += 1`，返回 undefined。
- **实现**：关键调用：`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countJobArgs` (`src/tests/helpers.zig:145`)

- **签名**：`pub fn countJobArgs(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue`。
- **作用**：把每个 int32 参数累加进 `job_counter`，返回 argc。
- **实现**：含循环。关键调用：`arg.asInt32`、`core.JSValue.int32`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExceptionInfo.deinit` (`src/tests/helpers.zig:212`)

- **签名**：`pub fn deinit(self: *ExceptionInfo) void`。
- **作用**：释放异常句柄。
- **实现**：关键调用：`deinit`、`self.value.deinit`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExceptionInfo.getMessage` (`src/tests/helpers.zig:216`)

- **签名**：`pub fn getMessage(self: ExceptionInfo, allocator: std.mem.Allocator) ![]const u8`。
- **作用**：从 Error 对象读 name/message 拼串；否则 `appendValueString`。调用方释放返回切片。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`self.value.get`、`value.isObject`、`value.refHeader`、`core.Object.fromHeader`、`getPropertyString`。显式 `return error.InvalidEngineState`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `![]const u8`，由测试 `try`/`expectError` 消费。

### `getPropertyString` (`src/tests/helpers.zig:247`)

- **签名**：`fn getPropertyString(rt: *core.JSRuntime, obj: *core.Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8`。
- **作用**：intern 属性名、`getProperty`，非 String 返回 null，否则 `appendRawString` 后 dupe 到调用方分配器。
- **实现**：热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`rt.internAtom`、`obj.getProperty`、`val.isString`、`std.ArrayList`、`temp_list.deinit`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!?[]const u8`，由测试 `try`/`expectError` 消费。

### `TestEngine.init` (`src/tests/helpers.zig:274`)

- **签名**：`pub fn init(allocator: std.mem.Allocator) !TestEngine`。
- **作用**：默认 options 调 `initWithOptions`。
- **实现**：关键调用：`initWithOptions`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!TestEngine`，由测试 `try`/`expectError` 消费。

### `TestEngine.initWithOptions` (`src/tests/helpers.zig:278`)

- **签名**：`pub fn initWithOptions(options: EngineOptions) !TestEngine`。
- **作用**：创建 Runtime（limit/GC 阈值/栈）、装标准全局、native 栈×4、创建 Context、堆分配 EventLoop 并 install。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`core.JSRuntime.createWithOptions`、`rt.destroy`、`registerStandardGlobalsBare`、`rt.setNativeStackSize`、`core.JSContext.create`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!TestEngine`，由测试 `try`/`expectError` 消费。

### `TestEngine.deinit` (`src/tests/helpers.zig:302`)

- **签名**：`pub fn deinit(self: *TestEngine) void`。
- **作用**：runJobs、EventLoop.deinit、cleanupTest262Agents、cleanupAtomicsWaiters、destroy context/runtime。
- **实现**：关键调用：`deinit`、`zjs.JSContext.borrowCore`、`wrapper.runJobs`、`self.event_loop.deinit`、`self.allocator.destroy`、`@import`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TestEngine.eval` (`src/tests/helpers.zig:314`)

- **签名**：`pub fn eval(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue`。
- **作用**：script 模式 `evalMode`。
- **实现**：关键调用：`self.evalMode`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalModule` (`src/tests/helpers.zig:318`)

- **签名**：`pub fn evalModule(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue`。
- **作用**：module 模式 `evalMode`。
- **实现**：关键调用：`self.evalMode`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalMode` (`src/tests/helpers.zig:322`)

- **签名**：`pub fn evalMode(self: *TestEngine, source_text: []const u8, mode: core.EvalMode) RuntimeError!core.JSValue`。
- **作用**：把 mode 塞进 `evalWithOptions`。
- **实现**：关键调用：`self.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.ensureTest262GlobalsInstalled` (`src/tests/helpers.zig:326`)

- **签名**：`pub fn ensureTest262GlobalsInstalled(self: *TestEngine) !void`。
- **作用**：若尚无 global，经 `contextGlobal` + `installTest262Globals` 装 `$262`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`engine.exec.zjs_vm.contextGlobal`、`@import`、`zjs.JSContext.borrowCore`、`run_test262.installTest262Globals`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalWithOptions` (`src/tests/helpers.zig:335`)

- **签名**：`pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValue`。
- **作用**：确保 test262 全局后 `borrowCore.eval`；`MissingExport`/`AmbiguousExport` 折成 `SyntaxError`。
- **实现**：关键调用：`self.ensureTest262GlobalsInstalled`、`@errorCast`、`zjs.JSContext.borrowCore`、`wrapper.eval`、`std.mem.eql`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.createPersistentValue` (`src/tests/helpers.zig:353`)

- **签名**：`pub fn createPersistentValue(self: *TestEngine, value: core.JSValue) !core.JSValueHandle`。
- **作用**：Runtime 上建 persistent handle。
- **实现**：关键调用：`createPersistentValue`、`self.runtime.createPersistentValue`。
- **所有权 / 错误 / 调用**：返回 `!core.JSValueHandle`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalWithOutput` (`src/tests/helpers.zig:357`)

- **签名**：`pub fn evalWithOutput(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.JSValue`。
- **作用**：带 `output` writer 的 eval。
- **实现**：关键调用：`self.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalFileWithOutputMode` (`src/tests/helpers.zig:361`)

- **签名**：`pub fn evalFileWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8) RuntimeError!core.JSValue`。
- **作用**：指定 mode 与 filename。
- **实现**：关键调用：`self.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalFileWithOutputModeStrict` (`src/tests/helpers.zig:365`)

- **签名**：`pub fn evalFileWithOutputModeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, strict: bool) RuntimeError!core.JSValue`。
- **作用**：parse+runtime 同时严格。
- **实现**：关键调用：`self.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalFileWithOutputModeRuntimeStrict` (`src/tests/helpers.zig:369`)

- **签名**：`pub fn evalFileWithOutputModeRuntimeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, runtime_strict: bool) RuntimeError!core.JSValue`。
- **作用**：只开 runtime strict。
- **实现**：关键调用：`self.evalWithOptions`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalFileModuleGraphWithHostHooks` (`src/tests/helpers.zig:373`)

- **签名**：`pub fn evalFileModuleGraphWithHostHooks( self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, filename: []const u8, host_hooks: module_graph.HostHooks, allocator: std.mem.Allocator, ) !core.JSValue`。
- **作用**：转 `module_graph.evalFileModuleGraphWithHostHooks`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`evalFileModuleGraphWithHostHooks`、`self.ensureTest262GlobalsInstalled`、`module_graph.evalFileModuleGraphWithHostHooks`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.evalFileModuleGraphWithOutput` (`src/tests/helpers.zig:385`)

- **签名**：`pub fn evalFileModuleGraphWithOutput( self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, filename: []const u8, io: std.Io, allocator: std.mem.Allocator, max_source_size: usize, ) !core.JSValue`。
- **作用**：转 `module_graph.evalFileModuleGraphWithOutput`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`evalFileModuleGraphWithOutput`、`self.ensureTest262GlobalsInstalled`、`module_graph.evalFileModuleGraphWithOutput`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.runJobs` (`src/tests/helpers.zig:398`)

- **签名**：`pub fn runJobs(self: *TestEngine) !void`。
- **作用**：`borrowCore.runJobs(null)` 排空 Promise job。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`runJobs`、`zjs.JSContext.borrowCore`、`wrapper.runJobs`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `TestEngine.installLegacyProbeEntry` (`src/tests/helpers.zig:403`)

- **签名**：`pub fn installLegacyProbeEntry(rt: *core.JSRuntime, function_object: *core.Object, ptr: *anyopaque, call: core.host_function.ExternalCallFn) !void`。
- **作用**：堆上 `LegacyProbeState`，register finalizer，alloc NativeEntry，install 到函数对象。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`rt.memory.create`、`rt.memory.destroy`、`rt.registerNativeEntryFinalizer`、`rt.allocNativeEntry`、`core.NativeEntry.code`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `TestEngine.createExternalHostFunctionValue` (`src/tests/helpers.zig:419`)

- **签名**：`pub fn createExternalHostFunctionValue( self: *TestEngine, name: []const u8, length: i32, ptr: *anyopaque, call: core.host_function.ExternalCallFn, finalizer: ?core.host_function.ExternalFinalizer, ) !core.JSValue`。
- **作用**：造 native 函数对象并把 legacy 探针装成 managed NativeEntry。
- **实现**：Test-probe adapter: the legacy `(ptr, ExternalCall)` probe shape is kept for the existing tests, but the function is an ordinary NB2 `NativeEntry` (managed thunk + heap state), not a registry record.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`self.runtime.memory.create`、`self.runtime.memory.destroy`、`self.runtime.registerNativeEntryFinalizer`、`self.runtime.allocNativeEntry`、`core.NativeEntry.code`。
- **所有权 / 错误 / 调用**：失败路径靠 `errdefer` 对称释放。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `TestEngine.defineGlobalExternalHostFunction` (`src/tests/helpers.zig:443`)

- **签名**：`pub fn defineGlobalExternalHostFunction( self: *TestEngine, name: []const u8, length: i32, ptr: *anyopaque, call: core.host_function.ExternalCallFn, finalizer: ?core.host_function.ExternalFinalizer, ) !void`。
- **作用**：在 global 上 defineOwnProperty 上述函数。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`engine.exec.zjs_vm.contextGlobal`、`self.createExternalHostFunctionValue`、`self.runtime.internAtom`、`global_object.defineOwnProperty`、`core.Descriptor.data`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `TestEngine.takeException` (`src/tests/helpers.zig:458`)

- **签名**：`pub fn takeException(self: *TestEngine) core.JSValue`。
- **作用**：取走 pending exception。
- **实现**：关键调用：`self.context.takePendingException`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TestEngine.takeExceptionInfo` (`src/tests/helpers.zig:462`)

- **签名**：`pub fn takeExceptionInfo(self: *TestEngine) !ExceptionInfo`。
- **作用**：包成带 handle 的 `ExceptionInfo`。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`core.JSValueHandle.init`、`self.takeException`。
- **所有权 / 错误 / 调用**：返回 `!ExceptionInfo`，由测试 `try`/`expectError` 消费。

### `moduleResolutionError` (`src/tests/helpers.zig:469`)

- **签名**：`fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError})`。
- **作用**：模块图的 Missing/AmbiguousExport 映射为 SyntaxError，其余原样。
- **实现**：主体是 `switch` 分发。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `sharedTestEngine` (`src/tests/helpers.zig:506`)

- **签名**：`pub fn sharedTestEngine() *TestEngine`。
- **作用**：进程级单例 TestEngine：首次建、空 eval 快照全局、注册 atexit。
- **实现**：首次调用时 `TestEngine.init(std.heap.page_allocator)`，跑一次空 `eval(";")` 逼出 `installHostGlobals`，清掉残留异常/未处理 rejection，然后把 global 的 `shape_ref.prop_count`/`hash`/`deletedPropCount` 与属性槽、VARREF 状态（值/is_lexical/is_const/is_deletable）快照到 `page_allocator` 数组；再 `runObjectCycleRemoval` 并记下 allocation_count/allocated_bytes/modules.count 基线，最后注册 atexit teardown。关键调用：`TestEngine.init`、`eng.eval`、`eng.context.takeException`、`g.propertyEntries`、`g.propFlagsAt`、`eng.runtime.runObjectCycleRemoval`、`registerSharedEngineProcessTeardown`。
- **所有权 / 错误 / 调用**：共享引擎走 `page_allocator`，寿命跨单测。无独立 error set 时失败以断言或 panic 终止测试。

### `registerSharedEngineProcessTeardown` (`src/tests/helpers.zig:567`)

- **签名**：`fn registerSharedEngineProcessTeardown() void`。
- **作用**：一次性 `atexit(sharedEngineProcessTeardown)`。
- **实现**：关键调用：`atexit`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `sharedEngineProcessTeardown` (`src/tests/helpers.zig:573`)

- **签名**：`fn sharedEngineProcessTeardown() callconv(.c) void`。
- **作用**：C 调用约定，转 `deinitSharedTestEngine`。
- **实现**：关键调用：`callconv`、`deinitSharedTestEngine`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。C 调用约定：给 native thunk / atexit 用。

### `deinitSharedTestEngine` (`src/tests/helpers.zig:582`)

- **签名**：`pub fn deinitSharedTestEngine() void`。
- **作用**：释放快照占用的 page_allocator 存储，destroy 宿主主 context/runtime。
- **实现**：取走 `shared_engine_storage` 里的引擎、把全局置 null 后再 `deinit`，避免 teardown 期间其它路径再拿到半死的共享引擎。关键调用：`releaseSharedEngineBaselineSnapshot`、`owned.deinit`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `releaseSharedEngineBaselineSnapshot` (`src/tests/helpers.zig:593`)

- **签名**：`fn releaseSharedEngineBaselineSnapshot() void`。
- **作用**：page_allocator.free 三块快照数组，计数归零。
- **实现**：三个 `if (opt) |slice|` 依次 free 并置 null。关键调用：`std.heap.page_allocator`。原先还带一个从不读的 `*core.JSRuntime` 形参和一圈 `for (baseline_shape_props) |_| {}` 空循环（rc 时代逐项 release 的残骸），两者都已删。
- **所有权 / 错误 / 调用**：共享引擎走 `page_allocator`，寿命跨单测。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `endSharedTest` (`src/tests/helpers.zig:612`)

- **签名**：`pub fn endSharedTest() void`。
- **作用**：复位共享引擎；leak-census 时打印 delta；pass≥1 且模块数未增则分配数不得超过 baseline+8。
- **实现**：关键调用：`resetSharedEngineAfterTest`、`std.debug.print`、`std.math.add`、`std.math.maxInt`、`std.debug.panic`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `resetSharedEngineAfterTest` (`src/tests/helpers.zig:666`)

- **签名**：`fn resetSharedEngineAfterTest(eng: *TestEngine) void`。
- **作用**：清异常/rejection、排空 job、清 atomics waiter、丢掉 lexicals、关 trigger_gc 后按快照重建全局属性与 shape，再环回收。
- **实现**：线性复位序列，其中排空 job 用 `while (true) switch (drainOnePendingJob(...))`（`.empty`/`.exception` 跳出）。属性还原期间把 `memory.trigger_gc_fn/ctx` 暂存置 null 并 `defer` 复原，使 slot 与 shape flags 的多步互换对 GC 原子。主动触发/轮询 GC，断言存活集。关键调用：`eng.context.hasException`、`eng.context.takeException`、`eng.context.hasUnhandledRejection`、`eng.context.takeUnhandledRejection`、`engine.exec.promise_ops.drainOnePendingJob`、`engine.exec.zjs_vm.cleanupAtomicsWaitersForContext`、`global.reserveOwnPropertyCapacity`、`eng.runtime.shapes.restorePropertyLayout`、`eng.runtime.runObjectCycleRemoval`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `vm_helpers.parseAndRunWithTopLevelChildren` (`src/tests/helpers.zig:752`)

- **签名**：`pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue`。
- **作用**：parseExpr + return，finalize，root cpool，跑 VM。
- **实现**：热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.initWithRuntime`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `vm_helpers.parseStmtAndRunWithTopLevelChildren` (`src/tests/helpers.zig:772`)

- **签名**：`pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue`。
- **作用**：按 script eval 发射（completion capture，不是 direct-eval 声明放置），parse 到 EOF，finalize 后跑。
- **实现**：含循环（`while` 解析到 `TOK_EOF`）。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.initWithRuntime`、`state.beginProgramEmission`、`state.enableReturnCompletion`、`parser_core.parseStatementOrDecl`、`state.finalizeEvalReturn`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `appendWeakCollectionEntry` (`src/tests/helpers.zig:804`)

- **签名**：`pub fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void`。
- **作用**：对象键转 `key.value()` 再插入。
- **实现**：关键调用：`appendWeakCollectionEntryForValue`、`key.value`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `appendWeakCollectionEntryForValue` (`src/tests/helpers.zig:811`)

- **签名**：`pub fn appendWeakCollectionEntryForValue(rt: *core.JSRuntime, collection: *core.Object, key: core.JSValue, value: core.JSValue) !void`。
- **作用**：weakIdentityFromValue、retain、ensure 容量、写条目；holder 注册可回滚。
- **实现**：Same insertion, for weak keys that are not objects (symbols). The weak collection stores an identity, not a pointer, so the object entry point is just this one with `key.value()` already applied.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`core.Object.weakIdentityFromValue`、`rt.retainWeakIdentity`、`rt.releaseWeakIdentity`、`collection.weakCollectionEntriesSlot`、`rt.borrowedReferenceHolderRegistered`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `finishGcCycles` (`src/tests/helpers.zig:835`)

- **签名**：`pub fn finishGcCycles(rt: anytype) void`。
- **作用**：轮询 `pollGC(.safepoint)` 直到增量标记与 morgue 都空，上限 1e5。
- **实现**：Drive an open incremental major cycle to completion. Threshold-triggered collections under the tracer begin a cycle and finish it at a later poll; tests that assert on freed counts after a crossing call this to reach the poll where the result lands.。含循环。主动触发/轮询 GC，断言存活集。关键调用：`rt.gc.incremental.markingActive`、`std.debug.assert`、`rt.pollGC`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `createTailOpcodeFixture` (`src/tests/helpers.zig:846`)

- **签名**：`pub fn createTailOpcodeFixture( js: *TestEngine, name_bytes: []const u8, code: []const u8, stack_size: u16, ) !core.JSValue`。
- **作用**：`FunctionBytecode.createFixture` + publish，再 `createRootBytecodeFunctionObject`；exec 与 stress 共用。
- **实现**：Publishes a hand-assembled bytecode function fixture on the runtime and returns a rooted function object for it. Shared by the exec suite and the stress tier raw tail-call test.。热路径用 `try` 传播分配/引擎错误。关键调用：`js.runtime.internAtom`、`zjs.bytecode.FunctionBytecode.createFixture`、`fb.publishFixtureNoFail`、`engine.exec.zjs_vm.contextGlobal`、`zjs.exec.object_ops.createRootBytecodeFunctionObject`。
- **所有权 / 错误 / 调用**：返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `LegacyProbeState.finalize` (`src/tests/helpers.zig:881`)

- **签名**：`pub fn finalize(raw: *anyopaque) void`。
- **作用**：可选 ExternalFinalizer，然后 destroy 自身。
- **实现**：关键调用：`self.runtime.memory.destroy`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `LegacyProbeState.thunk` (`src/tests/helpers.zig:887`)

- **签名**：`pub fn thunk( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：C ABI：调 legacy ExternalCall，宿主 error → JS 值。
- **实现**：关键调用：`callconv`、`engine.exec.builtin_dispatch.hostErrorToValue`、`self.call`、`engine.exec.builtin_dispatch.vmCallerView`、`engine.exec.builtin_dispatch.embedderErrorToValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。C 调用约定：给 native thunk / atexit 用。

### `scratchDirForProcess` (`src/tests/helpers.zig:911`)

- **签名**：`pub fn scratchDirForProcess(comptime base: []const u8) []const u8`。
- **作用**：目录名带 pid，避免 merge-gate 下 Debug 与 gc-stress 分片抢同一 scratch。
- **实现**：A scratch directory name unique to this test process: the merge gate runs the Debug and gc-stress shards concurrently, and two processes deleting/creating one fixed directory race each other.。关键调用：`std.fmt.bufPrint`、`std.os.linux`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

## `src/tests/abi_layout.zig` — FNABI 布局金钉

四条保证：golden size/offset、无隐式 padding、checked-in C header 与 schema 字节相同、`@cImport` 往返。另外把 ABI 侧 `JSValue` 钉在 `src/core/value.zig` 的 16 字节 tagged 现实。

文件头：FNABI golden layout tests (FN-M0I acceptance, design §33).  Four guarantees, each mechanized:   1. Golden numbers — every public ABI struct's size and per-field offsets      are pinned to explicit constants; any layout drift fails here first.   2. No implicit padding — fields are provably contiguous through the tail      (design §11.4: compiler-inserted padding positions must be explicit      reservedN fields).   3. Header freshness — the checked-in src/abi/fun_native_abi.h is      byte-identical to what the schema renders.   4. C/Zig round-trip — the generated header is compiled back via @cImport      and every struct's size/alignment/field offsets must match the Zig      schema, so a wrong C spelling cannot survive CI. Plus the Value ABI binding: the ABI-side JSValue mirror is pinned to src/core/value.zig reality (16-byte extern tagged, abi_encoding_revision).

### 函数（清单 3）

### `expectNoImplicitPadding` (`src/tests/abi_layout.zig:22`)

- **签名**：`fn expectNoImplicitPadding(comptime T: type) !void`。
- **作用**：逐字段断言 `@offsetOf` 等于前面字段 `@sizeOf` 的累加值，最后断言累加值等于 `@sizeOf(T)`——即结构体从头到尾没有编译器插入的隐式 padding（design §11.4 要求 padding 必须写成显式 reservedN 字段）。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`@typeInfo`、`std.testing.expectEqual`、`@offsetOf`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectGolden` (`src/tests/abi_layout.zig:31`)

- **签名**：`fn expectGolden(comptime T: type, comptime size: usize, comptime offsets: []const usize) !void`。
- **作用**：golden 断言：`@sizeOf(T)` 等于给定 size，且每个字段的 `@offsetOf` 等于 offsets 表对应项；字段数与偏移表长度不等时 comptime `std.debug.assert` 直接失败。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`、`@typeInfo`、`std.debug.assert`、`@offsetOf`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectSameLayoutAsC` (`src/tests/abi_layout.zig:40`)

- **签名**：`fn expectSameLayoutAsC(comptime Z: type, comptime C: type) !void`。
- **作用**：C/Zig 往返断言：Zig 侧类型 Z 与 `@cImport` 生成头得到的 C 类型 C，size、align 以及每个同名字段的 `@offsetOf` 必须全等。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`expectSameLayoutAsC`、`std.testing.expectEqual`、`@alignOf`、`@typeInfo`、`@offsetOf`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### 测试块（7）

### `test "FNABI golden layouts (sizes and field offsets)"` (`src/tests/abi_layout.zig:48`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FNABI golden layouts (sizes and field offsets)」。
- **实现**：六次 `expectGolden` 钉死 `ZjsJSValue`(16, {0,8})、`FunUtf8RefV1`(16)、`FunFunctionDescriptorV1`(24)、`FunExportDescriptorV1`(48)、`FunPluginDescriptorV1`(120)、`FunPluginInitContextV1`(40) 的 size 与全部字段偏移。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "FNABI structs contain no implicit padding (design §11.4)"` (`src/tests/abi_layout.zig:57`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FNABI structs contain no implicit padding (design §11.4)」。
- **实现**：`inline for (abi.public_structs)` 逐个过 `expectNoImplicitPadding`，任何隐式 padding 都会在这里红。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "checked-in C header matches the schema (regenerate: zig run src/abi/gen_header.zig)"` (`src/tests/abi_layout.zig:63`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「checked-in C header matches the schema (regenerate: zig run src/abi/gen_header.zig)」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "C/Zig layout round-trip through the generated header"` (`src/tests/abi_layout.zig:67`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C/Zig layout round-trip through the generated header」。
- **实现**：对六个公共 ABI 结构各调一次 `expectSameLayoutAsC`，把 Zig schema 与 `@cImport("abi/fun_native_abi.h")` 得到的 C 声明对齐，C 端拼写写错活不过 CI。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "C header constants match the schema tables"` (`src/tests/abi_layout.zig:76`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C header constants match the schema tables」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "signature ids are dense, unique, and start at 1 (0 reserved)"` (`src/tests/abi_layout.zig:89`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「signature ids are dense, unique, and start at 1 (0 reserved)」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Value ABI: the ABI mirror is pinned to src/core/value.zig reality (design §11.3)"` (`src/tests/abi_layout.zig:98`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Value ABI: the ABI mirror is pinned to src/core/value.zig reality (design §11.3)」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

## `src/tests/smoke_test.zig` — CLI smoke

`smoke` 打 ReleaseFast `zjs`+`zjs-profile`；`smoke-dev` 只打 Debug `zjs-dev` 且关掉 profile 合同。路径来自 `build_options.zjs_executable_path`。

文件头：Runs executable smoke tests for CLI behavior and profiling artifacts.

### 函数（清单 4）

### `resolvedZjsProfilePath` (`src/tests/smoke_test.zig:17`)

- **签名**：`fn resolvedZjsProfilePath(buf: *[1024]u8) []const u8`。
- **作用**：解析 profiling 二进制路径：先按 `build_options.zjs_profile_executable_path` 在 cwd 试开，开得了就用原路径，打不开则退回 `../../<path>`（测试 cwd 在 zig-cache 子目录时的相对位移），bufPrint 失败也退回原路径。
- **实现**：关键调用：`std.Io.Dir`、`openFile`、`file.close`、`std.fmt.bufPrint`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `resolvedZjsPath` (`src/tests/smoke_test.zig:27`)

- **签名**：`fn resolvedZjsPath(buf: *[1024]u8) []const u8`。
- **作用**：同上，解析普通 CLI 二进制 `build_options.zjs_executable_path`：cwd 打得开用原路径，否则加 `../../` 前缀。
- **实现**：关键调用：`std.Io.Dir`、`openFile`、`file.close`、`std.fmt.bufPrint`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `perfOpcodeCount` (`src/tests/smoke_test.zig:37`)

- **签名**：`fn perfOpcodeCount(stderr: []const u8) !u64`。
- **作用**：从 `--perf-json` 写到 stderr 的 JSON 里抠出 `"opcodes_executed": ` 后面的十进制数字；找不到键或键后没有数字都返回 `error.MissingOpcodeCount`。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`perfOpcodeCount`、`std.mem.indexOf`、`std.ascii.isDigit`、`std.fmt.parseInt`。显式 `return error.MissingOpcodeCount`。
- **所有权 / 错误 / 调用**：返回 `!u64`，由测试 `try`/`expectError` 消费。

### `parseBlockCensusRow` (`src/tests/smoke_test.zig:476`)

- **签名**：`fn parseBlockCensusRow(text: []const u8) ![14]u64`。
- **作用**：把一行 `gc: block census` 数据按空格 tokenize 解析成恰好 14 个 `u64`：多于 14 列在循环里 `expect(index < fields.len)` 红，少于 14 列在末尾 `expectEqual(fields.len, index)` 红。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`parseBlockCensusRow`、`std.mem.tokenizeScalar`、`tokens.next`、`std.testing.expect`、`std.fmt.parseInt`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `![14]u64`，由测试 `try`/`expectError` 消费。

### 测试块（4）

### `test "zjs CLI behavior"` (`src/tests/smoke_test.zig:46`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「zjs CLI behavior」。
- **实现**：拉起已安装的 `zjs`/`zjs-profile` 子进程，断言 exit / stdout / stderr。断言 42 处 `std.testing.expect*`。约 42 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：子进程 stdout/stderr 由 `std.testing.allocator` 释放；不持有引擎堆。

### `test "prepared method calls capture callee before argument side effects"` (`src/tests/smoke_test.zig:325`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prepared method calls capture callee before argument side effects」。
- **实现**：拉起已安装的 `zjs`/`zjs-profile` 子进程，断言 exit / stdout / stderr。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：子进程 stdout/stderr 由 `std.testing.allocator` 释放；不持有引擎堆。

### `test "CLI top-level range fast paths collapse completion-store loops"` (`src/tests/smoke_test.zig:354`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「CLI top-level range fast paths collapse completion-store loops」。
- **实现**：部分配置下 `return error.SkipZigTest`。拉起已安装的 `zjs`/`zjs-profile` 子进程，断言 exit / stdout / stderr。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：子进程 stdout/stderr 由 `std.testing.allocator` 释放；不持有引擎堆。

### `test "CLI nonempty block census rows reconcile with totals"` (`src/tests/smoke_test.zig:488`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「CLI nonempty block census rows reconcile with totals」。
- **实现**：拉起已安装的 `zjs`/`zjs-profile` 子进程，断言 exit / stdout / stderr。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：子进程 stdout/stderr 由 `std.testing.allocator` 释放；不持有引擎堆。

## `src/tests/stress.zig` — 长时 stress 层

不进每改动的 `zig build test` 分片（`--skip-prefix tests.stress.`），由 `test-stress` / merge-gate / production-gate 以 `--only-prefix` 跑。

文件头：Long-running stress tier: deep-recursion stack exhaustion and randomized bigint kernel sweeps. These were the five slowest tests in the tree (~47s of a ~53s unified run, 2026-08-29) and are separated so checkpoint-gate and the per-change `zig build test` close-out (see docs/verification-policy.md) keep fast feedback. Coverage is unchanged at the outer tiers: the engine-production gate, primary-platform CI, and the per-merge-batch gate run this file through `test-stress`; the ReleaseSafe phase close should invoke `zig build test test-stress -Doptimize=ReleaseSafe`.

### 函数（清单 1）

### `referenceSubMul` (`src/tests/stress.zig:180`)

- **签名**：`fn referenceSubMul( numerator: []engine.libs.bigint.Limb, divisor: []const engine.libs.bigint.Limb, qhat: engine.libs.bigint.Limb, ) bool`。
- **作用**：Independent reference for `subMulAt`, written from the definition rather than from the kernel's formulation: compute `numerator - divisor * qhat` with an explicit per-limb signed borrow in `i128`, which shares no arithmetic shape with the fused wrapping chain under test.。
- **实现**：Independent reference for `subMulAt`, written from the definition rather than from the kernel's formulation: compute `numerator - divisor * qhat` with an explicit per-limb signed borrow in `i128`, which shares no arithmetic shape with the fused wrapping chain under test.。含循环。关键调用：`referenceSubMul`、`std.math.maxInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（5）

### `test "raw tail call opcodes share the bounded tail-chain stack contract"` (`src/tests/stress.zig:19`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「raw tail call opcodes share the bounded tail-chain stack contract」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function __w2InvokeRaw(fn) { return 1 + fn(); } function __w2ExpectRaw(label, fn) {     try { __w2InvokeRaw(fn); print(label + ":missing"); `。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "sloppy tail recursion still overflows like QuickJS"` (`src/tests/stress.zig:87`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「sloppy tail recursion still overflows like QuickJS」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function f(n) { if (n <= 0) return 0; return f(n - 1); } var threw = false; try { f(200000); } catch (e) {   threw = e instanceof InternalEr`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument abrupt teardown releases supplied args and pads exactly once"` (`src/tests/stress.zig:102`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「missing-argument abrupt teardown releases supplied args and pads exactly once」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function padThrow(a, b) { return a.x + null.missing + String(b); } function strictPadThrow(a, b) { "use strict"; return a.x + null.missing +`；`exercisePaddedLeafThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict arrow tails stay constant while method recursion exhausts the logical stack budget"` (`src/tests/stress.zig:143`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict arrow tails stay constant while method recursion exhausts the logical stack budget」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`"use strict"; function expectStackOverflow(run) {   try {     run();     print("missing overflow");   } catch (error) {     print(error.name`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部就是 `sharedTestEngine()` + `defer endSharedTest()`（`src/tests/helpers.zig:126-136`），所以本例跑在进程级共享 Runtime 上：异常/未处理 rejection 的清理、job 排空、全局 shape 还原都由 `endSharedTest`（helpers.zig:615）负责；输出不符即测试失败。

### `test "fused multiply-subtract matches the reference limb for limb"` (`src/tests/stress.zig:207`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fused multiply-subtract matches the reference limb for limb」。
- **实现**：两段扫描：先对 nb∈[2,33) × 7 种 limb 花样 × 7 个 qhat（0/1/2/255/maxInt/maxInt-1/1<<63）穷举，再做 500,000 次随机宽度 2..16、divisor 顶 limb 置最高位的随机 sweep；每次都把同一输入分别喂给 `bigint.subMulAt` 与 `referenceSubMul`，比对返回的下溢标志与整条 limb 切片。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

## `src/tests/gc_stress.zig` — 确定性 GC 压力

与 `test-gc-stress`（环境变量加压跑统一套件）不同：本文件是手写的小堆/弱表/终结器/字节码常量池环。

文件头：zjs engine test layer; governed by docs/README.md testing policy and zjs embedding contract.

### 函数（清单 2）

### `dropGcPtr` (`src/tests/gc_stress.zig:13`)

- **签名**：`fn dropGcPtr(ptr: anytype) void`。
- **作用**：把指针指向的内存整块清零（`@memset(std.mem.asBytes(ptr), 0)`）：这些测试要把栈上的 `*Object` / `*JSContext` 局部彻底抹掉，否则保守栈扫描会把已经该死的对象继续当活根，`liveCount` 断言就不确定了。
- **实现**：关键调用：`@memset`、`std.mem.asBytes`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `bindObjectRoots` (`src/tests/gc_stress.zig:17`)

- **签名**：`fn bindObjectRoots(slots: []?*core.Object, roots: []core.runtime.ObjectRootValue) void`。
- **作用**：把 `[]?*core.Object` 槽数组逐个绑进等长的 `ObjectRootValue` 数组（`root.* = .{ .object = slot }`），随后交给 `ValueRootFrame{ .objects = ... }` 做精确扫描；测试把某个槽置 null 就等于放掉那个根。
- **实现**：含循环。关键调用：`bindObjectRoots`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（6）

### `test "gc stress deterministic tiny heap preserves live roots"` (`src/tests/gc_stress.zig:21`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress deterministic tiny heap preserves live roots。
- **实现**：强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc stress deterministic object cycles are reclaimed"` (`src/tests/gc_stress.zig:71`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress deterministic object cycles are reclaimed。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc stress weak map preserved key keeps value alive"` (`src/tests/gc_stress.zig:116`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress weak map preserved key keeps value alive。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc stress weak map dead cyclic keys clear values"` (`src/tests/gc_stress.zig:171`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress weak map dead cyclic keys clear values。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc stress finalization registry dead target queues pending job"` (`src/tests/gc_stress.zig:228`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress finalization registry dead target queues pending job。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "gc stress function bytecode constant pool object cycles are reclaimed"` (`src/tests/gc_stress.zig:286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 GC：stress function bytecode constant pool object cycles are reclaimed。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

## `src/tests/oom_cap.zig` — 8MB cap 可捕获 OOM

进统一套件。钉 eecf6c8：硬上限下 JS `catch` 看到 `InternalError`，同一 context 还能继续 eval；耗尽堆投递 OOM 时 backing allocator 零分配。

文件头：8MB memory-cap OOM behaviour fixtures (engine production gate).  Pins the catchable-OOM contract from eecf6c8 at the embedding surface:   - under a hard 8MB runtime cap, unbounded JS growth OOMs into a JS     `catch` as InternalError (QuickJS-aligned mapping), the process stays     alive, and the same context keeps evaluating afterwards;   - delivering the OOM exception to a JS catch handler while the heap is     fully exhausted performs zero allocations (preallocated OOM error +     `tryCatchInFrame` zero-allocation delivery), asserted with a counting     backing allocator so even paths that bypass the MemoryAccount limit     would be caught.  Sub-second tests: they run inside the regular `zig build test` unified suite (referenced from src/all_tests.zig) and as a focused binary wired into the `engine-production-gate` step in build.zig.

### 函数（清单 8）

### `expectStringValue` (`src/tests/oom_cap.zig:25`)

- **签名**：`fn expectStringValue(value: core.JSValue, expected: []const u8) !void`。
- **作用**：断言 `JSValue` 是字符串且字节等于 expected（`eqlBytes`）；三种不符（非 string / 取不到 body / 字节不等）都返回 `error.TestUnexpectedResult`。
- **实现**：关键调用：`expectStringValue`、`value.isString`、`value.asStringBody`、`string_value.eqlBytes`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `CountingAllocator.allocator` (`src/tests/oom_cap.zig:99`)

- **签名**：`fn allocator(self: *CountingAllocator) std.mem.Allocator`。
- **作用**：把 `CountingAllocator` 包成 `std.mem.Allocator`：`ptr` 指向自身，vtable 挂本结构的 alloc/resize/remap/free。
- **实现**：返回 `.{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } }`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CountingAllocator.alloc` (`src/tests/oom_cap.zig:106`)

- **签名**：`fn alloc(c: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8`。
- **作用**：计数型 alloc：每次进来 `attempt_count += 1`，转 `backing.rawAlloc`，成功再 `success_count += 1`——「耗尽堆投递 OOM 零分配」这条钉子就是数这个计数。
- **实现**：关键调用：`self.backing.rawAlloc`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CountingAllocator.resize` (`src/tests/oom_cap.zig:114`)

- **签名**：`fn resize(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool`。
- **作用**：原样转 `backing.rawResize`（原地扩缩不算新分配，故不计数）。
- **实现**：关键调用：`self.backing.rawResize`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CountingAllocator.remap` (`src/tests/oom_cap.zig:119`)

- **签名**：`fn remap(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8`。
- **作用**：原样转 `backing.rawRemap`，同样不计数。
- **实现**：关键调用：`self.backing.rawRemap`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CountingAllocator.free` (`src/tests/oom_cap.zig:124`)

- **签名**：`fn free(c: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void`。
- **作用**：原样转 `backing.rawFree`。
- **实现**：关键调用：`self.backing.rawFree`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExhaustState.exhaust` (`src/tests/oom_cap.zig:136`)

- **签名**：`fn exhaust(call: *zjs.native.Call) core.JSValue`。
- **作用**：JS 侧 `__exhaust()` 的 managed 原生实现：先记下当前 `counting.success_count` 作为窗口起点，再 `memory.setLimit(memory.allocated_bytes)` 把堆冻死，使之后每一笔记账分配都失败。
- **实现**：关键调用：`call.state`、`self.rt.memory.setLimit`、`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ExhaustState.report` (`src/tests/oom_cap.zig:144`)

- **签名**：`fn report(call: *zjs.native.Call) core.JSValue`。
- **作用**：JS 侧 `__report()`：把 `success_count - snapshot` 记进 `window_allocations`（即 `__exhaust`..`__report` 窗口内真正打到 backing allocator 的分配数），并 `setLimit(null)` 解冻堆。
- **实现**：关键调用：`call.state`、`self.rt.memory.setLimit`、`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（2）

### `test "engine production: 8MB cap OOM reaches JS catch as InternalError and the context stays usable"` (`src/tests/oom_cap.zig:31`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产引擎边界：engine production: 8MB cap OOM reaches JS catch as InternalError and the context stays usable。
- **实现**：`core.JSRuntime.createWithOptions(std.testing.allocator, .{ .memory_limit = 8MB })` + `JSContext.create`，经 `BindingContext.borrowCore` eval（不经 TestEngine）。脚本/输入：`var oomName = ""; var oomCaught = false; var n = 65536; var s = ""; try {   for (;;) { n *= 2; s = "x".repeat(n); } } catch (e) {   // zjs m`；`var arrName = ""; try {   var a = [];   for (;;) { a.push("y".repeat(65536)); } } catch (e) {   arrName = e.name;   a = null; } arrName`。两段之间还夹一次 `6 * 7` 与末尾 `"alive"`，证明同一 context OOM 之后仍可用。约 1 个 Zig expect、0 个 JS `assert.*`（其余断言走 `expectStringValue`）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "engine production: exhausted-heap OOM delivery to JS catch allocates nothing"` (`src/tests/oom_cap.zig:152`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产引擎边界：engine production: exhausted-heap OOM delivery to JS catch allocates nothing。
- **实现**：用 `CountingAllocator` 包住 `std.testing.allocator` 再 `core.JSRuntime.createWithOptions(counting.allocator(), .{})`（不经 TestEngine，无预设 cap），`defineFunction` 装上 `__exhaust`/`__report` 两个 managed 原生探针。先在正常内存下编好 `probe()`（phase 2 不再解析），再 eval `probe()`：窗口内 catch 到的必须是预分配的 `InternalError`，且 `window_allocations` 必须是 0。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

## `src/tests/engine_production.zig` — 生产嵌入边界

公共 API 拼写、直接拥有 Runtime/Context、中断、宿主函数终结器、字节存储、资源限制。

文件头：Exercises production engine boundaries, resource limits, and host integration.

### 函数（清单 6）

### `InterruptState.stop` (`src/tests/engine_production.zig:9`)

- **签名**：`fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool`。
- **作用**：中断回调探针：把 `ctx` 还原成 `*InterruptState`，`hits += 1` 记一次轮询，返回 `true` 要求引擎中止执行。
- **实现**：`@ptrCast(@alignCast(ctx.?))` 后自增 `hits` 并 `return true`；runtime 参数用 `_` 丢弃。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `HostFunctionState.call` (`src/tests/engine_production.zig:19`)

- **签名**：`fn call(c: *zjs.native.Call) zjs.JSValue`。
- **作用**：managed 原生函数探针：从 `Call` 上取回 `HostFunctionState`，把它的 `value` 以 int32 返回（测试据此确认 state 指针被正确带到调用点）。
- **实现**：关键调用：`zjs.JSValue.int32`、`c.state`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `HostFinalizerState.call` (`src/tests/engine_production.zig:27`)

- **签名**：`fn call(c: *zjs.native.Call) zjs.JSValue`。
- **作用**：只返回 undefined 的空壳原生函数体；它存在只是为了让测试能造出一个带 finalizer 的宿主函数对象。
- **实现**：关键调用：`zjs.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `HostFinalizerState.finalize` (`src/tests/engine_production.zig:32`)

- **签名**：`fn finalize(ptr: *anyopaque) void`。
- **作用**：宿主函数的 finalizer 探针：把 `ptr` 还原成 `*HostFinalizerState` 并 `calls += 1`；分配失败用例据此断言「函数没造出来时 finalizer 一次都不能跑」。
- **实现**：`@ptrCast(@alignCast(ptr))` 后 `self.calls += 1`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `BytesStoreState.deinit` (`src/tests/engine_production.zig:42`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：字节存储的宿主回收回调：`calls += 1` 记一次释放，并把 backing 切片还给测试分配器；用来观察 owned/shared store 的 deinit 时机（GC 收到才跑）。
- **实现**：关键调用：`deinit`、`self.allocator.free`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `S3HostDefineMajorProbe.trigger` (`src/tests/engine_production.zig:1001`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：挂在 `memory.trigger_gc_fn` 上的分配钩子：`active` 时先把 `trigger_gc_fn/ctx` 暂时摘掉（防重入）并 `defer` 复原，跑一次 `tryRunObjectCycleRemovalWithValueRoots(null, .engine_active)`，若 `gc.block_heap.mark_epoch` 变了就 `majors += 1`——即在 host 侧 define 的中途强插一次 major。
- **实现**：`defer` 释放本次成功路径上的临时资源。关键调用：`self.rt.tryRunObjectCycleRemovalWithValueRoots`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（36）

### `test "production public API contract exposes Zig-native embedding spellings"` (`src/tests/engine_production.zig:49`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：public API contract exposes Zig-native embedding spellings。
- **实现**：断言 19 处 `std.testing.expect*`。约 19 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "production embedding can own JSRuntime and JSContext directly"` (`src/tests/engine_production.zig:71`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can own JSRuntime and JSContext directly。
- **实现**：宿主自己持有 `zjs.JSRuntime`/`zjs.JSContext` 的存储，用 `rt.init(allocator, .{})` / `ctx.init(&rt, .{})` + `defer deinit()`（不是 create/destroy，也不经 TestEngine）。脚本/输入：`1 + 1`；`({ answer: 42 })`，末尾还 `globalObject()` 断言 `isGlobal()`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding API applies limits and releases eval handles"` (`src/tests/engine_production.zig:90`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding API applies limits and releases eval handles。
- **实现**：`zjs.JSRuntime.createWithOptions(.{ .stack_size = 128*1024, .gc_threshold = 32*1024 })` + `JSContext.create`（不经 TestEngine），先用 `rt.stackSize()`/`rt.gcThreshold()` 回读这两个上限。脚本/输入：`print(1 + 2);`，输出写进 64 字节 `std.Io.Writer.fixed`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can configure context policy through public methods"` (`src/tests/engine_production.zig:111`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can configure context policy through public methods。
- **实现**：`JSRuntime.createWithOptions(.{ .stack_size = 96*1024 })` + `JSContext.createWithOptions(.{ .track_unhandled_rejections = false })`（不经 TestEngine），然后逐项 set/读回：stackLimit 96K→64K、tracksUnhandledRejections false→true、preservesUncaughtException false→true。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production default host surface stays minimal"` (`src/tests/engine_production.zig:135`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：default host surface stays minimal。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`print(1); console.log(2); print(typeof std, typeof os, typeof setTimeout); try { std; } catch (e) { print(e.name); } try { os; } catch (e) {`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production event loop does not add product runtime globals"` (`src/tests/engine_production.zig:159`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：event loop does not add product runtime globals。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`print(1); console.log(2); print(typeof std, typeof os, typeof setTimeout, typeof setInterval, typeof clearTimeout, typeof clearInterval);`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can install external host functions"` (`src/tests/engine_production.zig:185`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can install external host functions。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`hostValue()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can create external host function values"` (`src/tests/engine_production.zig:199`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can create external host function values。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`var prototypeDescriptor = Object.getOwnPropertyDescriptor(HostCtor, "prototype"); var constructorDescriptor = Object.getOwnPropertyDescripto`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can create objects and define data properties"` (`src/tests/engine_production.zig:239`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can create objects and define data properties。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can inspect own property descriptors by JS key"` (`src/tests/engine_production.zig:253`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can inspect own property descriptors by JS key。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。脚本/输入：`(() => {   const key = Symbol("embedded");   const object = {};   Object.defineProperty(object, key, {     value: 17,     writable: false,  `；`Object.create({ inherited: 1 })`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can create strings and convert values to owned utf8"` (`src/tests/engine_production.zig:304`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can create strings and convert values to owned utf8。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`({ toString() { return 'semantic-\u00e9'; } })`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can convert values to numbers"` (`src/tests/engine_production.zig:322`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can convert values to numbers。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`({ valueOf() { return 12.75; } })`；`({ toString() { return 'not-a-number'; } })`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can inspect callable and constructor values"` (`src/tests/engine_production.zig:340`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can inspect callable and constructor values。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`(function NamedForEmbedding() {})`；`(() => {})`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can call JavaScript functions"` (`src/tests/engine_production.zig:363`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can call JavaScript functions。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。脚本/输入：`(function addToBase(a, b) { return this.base + a + b; })`；`(function fail() { throw new TypeError('call failed'); })`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can compare values with SameValue semantics"` (`src/tests/engine_production.zig:387`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can compare values with SameValue semantics。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`'same-value-string'`；`'same-' + 'value-string'`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can inspect arrays and indexed values"` (`src/tests/engine_production.zig:403`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can inspect arrays and indexed values。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。脚本/输入：`[1, 2, 3]`；`new Proxy([4], {})`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can inspect runtime memory usage without internal modules"` (`src/tests/engine_production.zig:429`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can inspect runtime memory usage without internal modules。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding roots host-held values with public handles"` (`src/tests/engine_production.zig:439`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding roots host-held values with public handles。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`({ answer: 42 })`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can expose owned and shared byte stores"` (`src/tests/engine_production.zig:469`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can expose owned and shared byte stores。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 22 处 `std.testing.expect*`。约 22 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production runtime can detach array buffers through public runtime API"` (`src/tests/engine_production.zig:538`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：runtime can detach array buffers through public runtime API。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.Detached`。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can retain and rewrap shared array buffers"` (`src/tests/engine_production.zig:576`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can retain and rewrap shared array buffers。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding lifecycle deinitializes repeated script and module evals"` (`src/tests/engine_production.zig:614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding lifecycle deinitializes repeated script and module evals。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`let values = []; for (let i = 0; i < 8; i++) values.push({ i }); values.map(v => v.i).join(",");`；`const value = await Promise.resolve(42); export { value };`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production module import.meta identity survives methods and nested closures"` (`src/tests/engine_production.zig:637`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：module import.meta identity survives methods and nested closures。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`const rootMeta = import.meta; class Holder {   read() { return import.meta; } } function nested() {   const arrow = () => import.meta;   ret`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding memory limit reports allocation failure without leaking"` (`src/tests/engine_production.zig:662`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding memory limit reports allocation failure without leaking。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`({ payload: new Array(32).fill('x') });`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding public API allocation failures keep host ownership intact"` (`src/tests/engine_production.zig:675`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding public API allocation failures keep host ownership intact。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。先 `runObjectCycleRemoval()` 再把 `setMemoryLimit` 钉到当前 `allocated_bytes`（否则限额处的应急回收可能腾出空间，测试就变成在断言「此刻恰好没垃圾」）。随后四个公共 API（`createPersistentValue`/`createString`/`createFunction`/`arrayBuffer`）必须各自返回 `error.OutOfMemory`，且 persistent/local root 计数、finalizer 调用数、store 的 bytes 长度都不变。脚本/输入：`({ answer: 42 })`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding interrupt handler aborts unbounded execution"` (`src/tests/engine_production.zig:748`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding interrupt handler aborts unbounded execution。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.Interrupted`。脚本/输入：`while (true) {}`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding interrupt handler aborts conditional-only backedge"` (`src/tests/engine_production.zig:763`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding interrupt handler aborts conditional-only backedge。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.Interrupted`。脚本/输入：`do {} while (true);`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding interrupt handler aborts a recursion-only call loop"` (`src/tests/engine_production.zig:780`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding interrupt handler aborts a recursion-only call loop。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。脚本/输入：`function recurse() { return 1 + recurse(); } recurse();`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding takeException captures exception snapshot without leaking"` (`src/tests/engine_production.zig:800`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding takeException captures exception snapshot without leaking。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`throw new Error('test exception snapshot');`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can create and throw named errors"` (`src/tests/engine_production.zig:814`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can create and throw named errors。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can match pending exceptions by error name"` (`src/tests/engine_production.zig:839`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can match pending exceptions by error name。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`throw new TypeError('expected type');`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can create independent realms"` (`src/tests/engine_production.zig:863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can create independent realms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`Array`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding can eval script source in explicit function realms"` (`src/tests/engine_production.zig:903`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding can eval script source in explicit function realms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding getProperty follows JavaScript accessors"` (`src/tests/engine_production.zig:940`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding getProperty follows JavaScript accessors。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`let hits = 0; ({   get stack() {     hits += 1;     return "semantic stack";   },   get hits() {     return hits;   } })`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production embedding getProperty reports accessor exceptions"` (`src/tests/engine_production.zig:969`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：embedding getProperty reports accessor exceptions。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。脚本/输入：`({   get stack() {     throw new Error("stack getter failed");   } })`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3: a host-defined property name stays reachable across a major taken mid-define"` (`src/tests/engine_production.zig:1019`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: a host-defined property name stays reachable across a major taken mid-define」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。先 `globalObject()` 把标准全局的 atom 流量排除在外，再把 `S3HostDefineMajorProbe` 挂上 `memory.trigger_gc_fn` 并 `probe.active = true`，让 `defineDataProperty("zjsS3HostDefinedPropertyName")` 中途真的吃到一次 major；事后要求 `probe.majors > 0`、`atoms.atom_audit_stale_edge == 0`，并能把值读回来。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

## `src/tests/embedding_examples.zig` — 嵌入 cookbook 可编译可跑

`test-embedding` 的真正测试体；统一套件也 `refAllDecls` 进来，所以 checkpoint 只需要 sema-only `check-embedding`。

文件头：Validates public embedding examples against the shipped API.

### 函数（清单 24）

### `HostState.call` (`src/tests/embedding_examples.zig:8`)

- **签名**：`fn call(c: *zjs.native.Call) zjs.JSValue`。
- **作用**：cookbook 宿主函数体：从 `Call` 取回 `HostState` 并把它的 `value` 作为 int32 返回，证明 `.state` 指针原样送到调用点。
- **实现**：关键调用：`zjs.JSValue.int32`、`c.state`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `BytesState.deinit` (`src/tests/embedding_examples.zig:17`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：owned 字节存储的宿主回收回调：`calls += 1` 记一次，并把 backing 切片还给测试分配器——测试据此观察「GC 收到 ArrayBuffer 时才跑 deinit」。
- **实现**：关键调用：`self.allocator.free`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `InterruptBudget.stop` (`src/tests/embedding_examples.zig:27`)

- **签名**：`fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool`。
- **作用**：带预算的中断回调：`budget` 为 0 时返回 true（中断），否则扣 1 并返回 false（放行），用来精确控制第几次轮询才中止。
- **实现**：`@ptrCast(@alignCast(ctx.?))` 取回自身；`if (self.budget == 0) return true;` 否则 `self.budget -= 1; return false;`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `LeafExample.add` (`src/tests/embedding_examples.zig:111`)

- **签名**：`fn add(a: i32, b: i32) i32`。
- **作用**：typed leaf 示例目标：两个 i32 的 wrapping 加法（`a +% b`）。它看不到 JSValue、不分配也不抛错，marshal 与 tag 检查由 VM 在调用点完成。
- **实现**：单行 `return a +% b;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `LeafExample.half` (`src/tests/embedding_examples.zig:115`)

- **签名**：`fn half(x: f64) f64`。
- **作用**：f64 版 typed leaf 示例目标：`x / 2`，验证 double 臂与 int32 臂走同一条 leaf 通道。
- **实现**：单行 `return x / 2;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `TickState.tick` (`src/tests/embedding_examples.zig:124`)

- **签名**：`fn tick(self: *TickState, i: i32) i32`。
- **作用**：带宿主状态的 typed leaf（`leafWithState`）：`ticks += 1` 记调用次数，返回 `i +% self.step`；测试用它确认 state 在 leaf 臂上同样可写。
- **实现**：关键调用：`tick`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ContractHost.call` (`src/tests/embedding_examples.zig:175`)

- **签名**：`fn call(c: *zjs.native.Call) anyerror!zjs.JSValue`。
- **作用**：NB2 managed 宿主函数的合同样本：累计 `calls`、记录 `this` 是否对象、参数不足或非 int32 返回 `error.TypeError`、首参为负返回 `error.RangeError`，正常则返回 `factor * (a + b)`。
- **实现**：关键调用：`c.state`、`c.this.isObject`、`c.arg`、`asInt32`、`zjs.JSValue.int32`。显式 `return error.TypeError` / `error.RangeError`。
- **所有权 / 错误 / 调用**：返回 `anyerror!zjs.JSValue`，由测试 `try`/`expectError` 消费。

### `ContractHost.finalize` (`src/tests/embedding_examples.zig:186`)

- **签名**：`fn finalize(ptr: *anyopaque) void`。
- **作用**：NativeEntry 的 finalizer：把宿主侧 `finalized` 标志置真。测试据此钉「记录归 Runtime 不归 Context」——destroy context 时还没跑，destroy runtime 时才跑。
- **实现**：`@ptrCast(@alignCast(ptr))` 取回自身后 `self.finalized.* = true;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CallSiteHost.call` (`src/tests/embedding_examples.zig:201`)

- **签名**：`fn call(c: *zjs.native.Call) anyerror!zjs.JSValue`。
- **作用**：嵌套用例的宿主函数：拿常驻 `CallSite` 对第 0 个参数做一次 `call1`，把结果累进 `sum` 并原样返回——即 JS → 宿主 → 同一个 site → JS 的往返。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`c.state`、`self.site.call1`、`c.arg`、`result.asInt32`。显式 `return error.TypeError`。
- **所有权 / 错误 / 调用**：返回 `anyerror!zjs.JSValue`，由测试 `try`/`expectError` 消费。

### `Payload.read` (`src/tests/embedding_examples.zig:507`)

- **签名**：`fn read(self: *@This()) i32`。
- **作用**：`NativeBinding.JSObject` 的内联 payload 读取方法（注册为 JS 侧 `read`），返回宿主结构里的 `value`。
- **实现**：单行 `return self.value;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `liveRealmCount` (`src/tests/embedding_examples.zig:589`)

- **签名**：`fn liveRealmCount(rt: *zjs.JSRuntime) usize`。
- **作用**：沿 `rt.firstContext()` 的 `runtime_next` 链数出当前还活着的 realm/context 数——context destroy 与跨 realm 原型窃取的用例用它判断链表是否还挂着。
- **实现**：含循环。关键调用：`rt.firstContext`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `stealArrayPrototype` (`src/tests/embedding_examples.zig:596`)

- **签名**：`fn stealArrayPrototype(ctx_from: *zjs.JSContext, ctx_into: *zjs.JSContext) !zjs.JSValue`。
- **作用**：制造跨 realm 引用：从 `ctx_from` eval 出 `Array.prototype`，写成 `ctx_into` 全局上的 `stolenProto` 属性并返回它，用来把两个 realm 的对象图缠在一起。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`stealArrayPrototype`、`ctx_from.eval`、`ctx_into.eval`、`ctx_into.defineDataProperty`。
- **所有权 / 错误 / 调用**：返回 `!zjs.JSValue`，由测试 `try`/`expectError` 消费。

### `WorldState.create` (`src/tests/embedding_examples.zig:689`)

- **签名**：`fn create(call: *zjs.native.Call) error{ OutOfMemory, TypeError }!*WorldState`。
- **作用**：native class 的构造回调：用 `std.testing.allocator` 堆分配一个 `WorldState`，有参数时按 int32 设 `stride`；参数不是 int32 就先 `destroy` 再返回 `error.TypeError`（不泄漏半成品）。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`create`、`std.testing.allocator`、`call.arg`、`asInt32`。显式 `return error.TypeError`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `error{ OutOfMemory, TypeError }!*WorldState`，由测试 `try`/`expectError` 消费。

### `WorldState.destroy` (`src/tests/embedding_examples.zig:699`)

- **签名**：`fn destroy(self: *WorldState) void`。
- **作用**：native class 的 finalizer：`finalized += 1`（类级计数，测试据此判断 GC 与 teardown 各回收了几个实例），然后把宿主结构还给测试分配器。
- **实现**：关键调用：`destroy`、`std.testing.allocator`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。无独立 error set 时失败以断言或 panic 终止测试。

### `WorldState.step` (`src/tests/embedding_examples.zig:704`)

- **签名**：`fn step(self: *WorldState, dt: i32) i32`。
- **作用**：K2 typed 方法：`steps += 1` 后返回 `dt + self.stride`；参数与返回值都是 i32，走 leaf 臂，不见 JSValue。
- **实现**：`self.steps += 1; return dt + self.stride;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `WorldState.query` (`src/tests/embedding_examples.zig:709`)

- **签名**：`fn query(self: *WorldState, call: *zjs.native.Call) error{TypeError}!zjs.JSValue`。
- **作用**：K2 managed 方法：拿到 `Call` 视图，argc 为 0 返回 `error.TypeError`（映射成 JS TypeError），否则 `steps += 1` 并把第 0 个参数原样回传。
- **实现**：关键调用：`call.arg`。显式 `return error.TypeError`。
- **所有权 / 错误 / 调用**：返回 `error{TypeError}!zjs.JSValue`，由测试 `try`/`expectError` 消费。

### `WorldState.time` (`src/tests/embedding_examples.zig:715`)

- **签名**：`fn time(self: *WorldState) f64`。
- **作用**：K3 typed getter：返回 `time_ms`（固定 1.5），供 `w.time` 与 PropertySite 缓存读取。
- **实现**：单行 `return self.time_ms;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `WorldState.getGravity` (`src/tests/embedding_examples.zig:719`)

- **签名**：`fn getGravity(self: *WorldState) f64`。
- **作用**：K3 typed getter：返回 `gravity` 字段。
- **实现**：单行 `return self.gravity;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `WorldState.setGravity` (`src/tests/embedding_examples.zig:723`)

- **签名**：`fn setGravity(self: *WorldState, g: f64) void`。
- **作用**：K3 typed setter：把 f64 写进 `gravity`；JS 侧写入非 number 时 marshal 在调用点抛 TypeError，setter 本身见不到。
- **实现**：单行 `self.gravity = g;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `WorldState.label` (`src/tests/embedding_examples.zig:727`)

- **签名**：`fn label(self: *WorldState, call: *zjs.native.Call) !zjs.JSValue`。
- **作用**：managed getter 样本：忽略 self，用 `call.ctx.createString("world")` 现造一个 JS 字符串返回——证明 getter 也能拿 `Call` 视图并分配。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`call.ctx.createString`。
- **所有权 / 错误 / 调用**：返回 `!zjs.JSValue`，由测试 `try`/`expectError` 消费。

### `evalBool` (`src/tests/embedding_examples.zig:744`)

- **签名**：`fn evalBool(ctx: *zjs.JSContext, source: []const u8) !bool`。
- **作用**：eval 一段源码并要求结果是布尔：异常值转 `error.JSException`，非布尔转 `error.NotABoolean`；native class 用例的大部分断言都写成 JS 表达式经由它回传。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`evalBool`、`ctx.eval`、`result.isException`、`result.asBool`。显式 `return error.JSException`。
- **所有权 / 错误 / 调用**：返回 `!bool`，由测试 `try`/`expectError` 消费。

### `NamespaceType` (`src/tests/embedding_examples.zig:867`)

- **签名**：`fn NamespaceType(comptime namespace: anytype) type`。
- **作用**：把「传进来的是类型本身」与「传进来的是命名空间实例」统一成一个类型：`.type` 直接返回该值，否则返回 `@TypeOf(namespace)`。
- **实现**：主体是 `switch` 分发。关键调用：`@typeInfo`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectPublicDeclSnapshot` (`src/tests/embedding_examples.zig:874`)

- **签名**：`fn expectPublicDeclSnapshot( comptime label: []const u8, comptime namespace: anytype, comptime expected: []const []const u8, ) !void`。
- **作用**：公共面名单比对：expected 里缺的名字逐条打印并计 missing，命名空间里多出来的逐条打印并计 extra；有任一不为 0 就把实际名单整个打出来并返回 `error.TestExpectedEqual`，最后再断言声明总数等于 expected 长度。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`expectPublicDeclSnapshot`、`@setEvalBranchQuota`、`@typeInfo`、`NamespaceType`、`std.debug.print`、`std.mem.eql`。显式 `return error.TestExpectedEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### 测试块（21）

### `test "embedding cookbook basic script eval example compiles and runs"` (`src/tests/embedding_examples.zig:35`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook basic script eval example compiles and runs。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`let x = 1 + 2; x;`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook eval with output example compiles and runs"` (`src/tests/embedding_examples.zig:48`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook eval with output example compiles and runs。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`print('ok');`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook host-held values example compiles and roots correctly"` (`src/tests/embedding_examples.zig:67`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook host-held values example compiles and roots correctly。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`({ answer: 42 })`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook host function example compiles and runs"` (`src/tests/embedding_examples.zig:91`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook host function example compiles and runs。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`hostValue()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook typed leaf example compiles and runs"` (`src/tests/embedding_examples.zig:130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook typed leaf example compiles and runs。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`var name = "none"; try { add("1", 2); } catch (e) { name = e.name; } name;`；`add(40, 2)`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook CallSite example resolves once and calls repeatedly"` (`src/tests/embedding_examples.zig:209`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook CallSite example resolves once and calls repeatedly。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。脚本/输入：`(function (x) { return x + 1; })`；`var s = 0; for (var k = 0; k < 10; k++) s += viaSite(k); s`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook PropertySite reads and writes one field through a shape-guarded cache"` (`src/tests/embedding_examples.zig:260`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook PropertySite reads and writes one field through a shape-guarded cache。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。脚本/输入：`({ x: 1, field: 3 })`；`function P() {} P.prototype.field = 5; var p = new P();`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding external host function contract covers args, this, errors, and finalizer"` (`src/tests/embedding_examples.zig:362`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：external host function contract covers args, this, errors, and finalizer。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`var caught = "none"; try { hostCombine(-1, 0); } catch (e) {   caught = (e instanceof RangeError) ? e.name : "wrong-class"; } caught;`；`typeof hostCombine === 'function' && hostCombine.name === 'hostCombine' && hostCombine.length === 2`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook strings and bytes examples compile and run"` (`src/tests/embedding_examples.zig:420`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook strings and bytes examples compile and run。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。走公共的显式回收接口 `rt.runObjectCycleRemoval()`（这是公共嵌入编译目标，不能 import 依赖 `zjs.core` 的 test helpers），回收前 `bytes_state.calls` 必须是 0、回收后必须是 1。脚本/输入：`({ toString() { return 'path'; } })`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook construction with limits example compiles and runs"` (`src/tests/embedding_examples.zig:459`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook construction with limits example compiles and runs。
- **实现**：`JSRuntime.createWithOptions` 设 `stack_size` 512 KiB、`gc_threshold` 2 MiB，再 `setMemoryLimit(64 MiB)`，然后读回 `stackSize()` / `gcThreshold()` / `memoryUsage().memory_limit` 三项（不注入 OOM）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook interrupts example compiles and aborts runaway code"` (`src/tests/embedding_examples.zig:473`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook interrupts example compiles and aborts runaway code。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.Interrupted`。脚本/输入：`while (true) {}`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook module eval example compiles and runs"` (`src/tests/embedding_examples.zig:488`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook module eval example compiles and runs。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`const value = await Promise.resolve(42); export { value };`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding public NativeBinding failed realm install leaves binding absent"` (`src/tests/embedding_examples.zig:502`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：public NativeBinding failed realm install leaves binding absent。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.NotInstalled`。设置 runtime 内存上限以注入 OOM。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding public API core signatures stay source-compatible"` (`src/tests/embedding_examples.zig:555`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：public API core signatures stay source-compatible。
- **实现**：不建任何 Runtime/Context：把九个公共入口（`JSRuntime.create`/`createWithOptions`、`JSContext.create`/`createWithOptions`、`defineFunction`、`createFunction`、`eval`、`arrayBuffer`、`toOwnedUtf8`）赋值给写死的函数类型常量，签名一变即编译失败；再断言 `zjs.value.Bytes.Store == zjs.JSValue.Bytes.Store`、`object.Object` 是 opaque，以及（仅当 `zjs` 是公共 facade、无 `config_signature` 时）`JSBytes`/`JSString`/`PropNameID`/`binding` 四个名字缺席。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding destroy of one context keeps auto_init-bearing objects from that realm alive"` (`src/tests/embedding_examples.zig:603`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：destroy of one context keeps auto_init-bearing objects from that realm alive。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。`stealArrayPrototype(ctx_b → ctx_a)` 制造跨 realm 引用后 destroy ctx_b：`liveRealmCount` 在 destroy 前、destroy 后、`runObjectCycleRemoval()` 后都必须是 2，且 `contextForGlobal(b_global)` 仍非 null。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding newest-first context destroy with cross-realm Array.prototype still tears down"` (`src/tests/embedding_examples.zig:622`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：newest-first context destroy with cross-realm Array.prototype still tears down。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。`stealArrayPrototype(ctx_b → ctx_a)` 后按「新的先销毁」顺序 `ctx_b.destroy()` → `ctx_a.destroy()` → `rt.destroy()`；无显式 expect，测试体本身就是断言——拆解顺序出错会在 destroy 路径上崩或被测试分配器报泄漏（成功路径用 `errdefer` 而非 `defer`，正因为对象是手工按序销毁的）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding oldest-first context destroy with cross-realm Array.prototype still tears down"` (`src/tests/embedding_examples.zig:638`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：oldest-first context destroy with cross-realm Array.prototype still tears down。
- **实现**：同上的镜像：`stealArrayPrototype(ctx_b → ctx_a)` 后按「老的先销毁」顺序 `ctx_a.destroy()` → `ctx_b.destroy()` → `rt.destroy()`，同样无显式 expect。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding createRealm leftover is collected without JSContext.destroy on the child"` (`src/tests/embedding_examples.zig:654`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：createRealm leftover is collected without JSContext.destroy on the child。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。`ctx.createRealm()` 后把子 realm 的 `Array.prototype` 挂到主 realm 全局，`liveRealmCount` 在 `runObjectCycleRemoval()` 前后都是 2；子 context 不调用 `JSContext.destroy`，只 destroy 主 context 与 runtime。脚本/输入：`globalThis`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding cookbook native class covers create, unwrap, methods, accessors, constructor, dispose and finalizer"` (`src/tests/embedding_examples.zig:750`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：cookbook native class covers create, unwrap, methods, accessors, constructor, dispose and finalizer。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。绝大多数断言是 `evalBool` 回传的 JS 表达式：K2 typed/managed 方法、K3 getter/setter、原型属性形状与不可枚举、外来 receiver 抛 TypeError、`new World` / 无 `new` / 子类化、dispose 后再调用抛错。GC 侧用 `rt.runObjectCycleRemoval()` 让不可达实例走 finalizer（`WorldState.finalized` 从 ≤1 变成 1），最后 destroy context+runtime 再断言总计 3 个实例被终结。断言 36 处 `std.testing.expect*`。约 36 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "embedding native class accessor descriptors keep identity across reads"` (`src/tests/embedding_examples.zig:832`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住嵌入面：native class accessor descriptors keep identity across reads。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "public API surface snapshot matches the checked-in name lists"` (`src/tests/embedding_examples.zig:1047`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「public API surface snapshot matches the checked-in name lists」。
- **实现**：`zjs` 若带 `config_signature`（即统一套件里的内部根）直接 return，只在 `test-embedding` 的公共 facade 下生效。对 `zjs` 及 `value`/`host`/`object`/`context`/`module`/`job`/`runtime` 八个命名空间各跑一次 `expectPublicDeclSnapshot`（失败只记 flag，末尾统一 `error.TestExpectedEqual`，一轮就能看全所有差异），再钉住两个已知宽面的声明数：`JSValue` 80、`JSRuntime` 162。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

## `src/tests/oom.zig` — `test-oom` 注入语料

独立产物，`oom_injection=true`。语料每条都是 init→eval→deinit，交给 `checkAllAllocationFailures`；另有 fail-at-N 恢复金丝雀。夜间 CI，不进 checkpoint。

文件头：OOM injection suite (`zig build test-oom`).  Rebirth of the retired `test-oom` command (removed in 65e22be because the old shape cost O(allocation sites x full unit suite)). The new shape is a small embedded JS corpus where every snippet is wrapped as an "init runtime+context -> eval -> deinit" function and handed to `std.testing.checkAllAllocationFailures`, which:   - counts the allocations of a clean run,   - re-runs the snippet once per allocation index with that allocation     forced to fail (sticky failure: all later allocations fail too),   - requires each failing run to surface `error.OutOfMemory` to the     embedder with allocated == freed (no leaks on any failure path).  On top of that, a representative subset gets a recovery canary sweep (hand-rolled single-shot fail-at-N allocator): after one injected failure the engine must either succeed or surface the failure as a catchable result, and the SAME runtime must then evaluate a canary script correctly - pinning the "OOM is catchable and the engine stays consistent afterwards" contract from eecf6c8.  Cost note: each snippet sweep re-runs full runtime+context bootstrap per allocation index, so this is an instrumentation tier command (nightly), not part of `zig build test`.

### 函数（清单 28）

### `expectValue` (`src/tests/oom.zig:521`)

- **签名**：`fn expectValue(value: core.JSValue, expect: Expect) !void`。
- **作用**：按语料条目的 `Expect` 判完成值：`.any` 不做断言（模块完成值是 undefined），`.string` 转给 `expectStringValue` 比字节。
- **实现**：主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。关键调用：`expectStringValue`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectStringValue` (`src/tests/oom.zig:528`)

- **签名**：`fn expectStringValue(value: core.JSValue, expected: []const u8) !void`。
- **作用**：断言完成值是字符串且字节等于 expected；非 string、取不到 body、字节不等都返回 `error.TestUnexpectedResult`。原先的 `rt` 形参入口即 `_ = rt;`，已连同 `expectValue` 的同款形参从签名与全部调用点删除，两处形状现与 `oom_cap.zig:25` 的同名函数一致。
- **实现**：关键调用：`value.isString`、`value.asStringBody`、`string_value.eqlBytes`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `ensureStandardGlobalsInstaller` (`src/tests/oom.zig:543`)

- **签名**：`fn ensureStandardGlobalsInstaller() void`。
- **作用**：Register the builtins standard-globals installer as the process-global default so every `core.JSRuntime.create` below copies it into the new runtime's `install_standard_globals_cb`. Phase 6b-3 STEP 7B routed global installation through that callback, which the binding-layer `JSContext.create` wires up; this suite drives the core API directly, so it must register the installer itself or the first `contextGlobal` fails with `error.InvalidBuiltinRegistry` (a non-OOM error that derails the sweep). Mirrors `installHostGlobalsBare` in the exec test tree. Idempotent and allocation-free, so it is safe to call before each injected attempt.。
- **实现**：Register the builtins standard-globals installer as the process-global default so every `core.JSRuntime.create` below copies it into the new runtime's `install_standard_globals_cb`. Phase 6b-3 STEP 7B routed global installation through that callback, which the binding-layer `JSContext.create` wires up; this suite drives the core API directly, so it must register the installer itself or the first `contextGlobal` fails with `error.InvalidBuiltinRegistry` (a non-OOM error that derails the sweep). Mirrors `installHostGlobalsBare` in the exec test tree. Idempotent and allocation-free, so it is safe to call before each injected attempt.。关键调用：`zjs.exec.standard_globals.registerStandardGlobalsDefault`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `runSnippet` (`src/tests/oom.zig:551`)

- **签名**：`fn runSnippet(allocator: std.mem.Allocator, snippet: Snippet) !void`。
- **作用**：One full engine lifecycle around a corpus snippet. Shaped for `std.testing.checkAllAllocationFailures`: every allocation flows through `allocator`, OOM propagates out as `error.OutOfMemory`, and all paths (success or failure) release everything they allocated.。
- **实现**：One full engine lifecycle around a corpus snippet. Shaped for `std.testing.checkAllAllocationFailures`: every allocation flows through `allocator`, OOM propagates out as `error.OutOfMemory`, and all paths (success or failure) release everything they allocated.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配（rt/ctx 两级 owned 标志 + atomics waiter 清理）。按 `snippet.drain_jobs` / `collect_cycles` 决定是否排空 job、跑一次环回收。本函数自身不调 `checkAllAllocationFailures`，而是作为它的被测函数被逐个分配点重放；末尾 `stickyFailureTailProbe` 把被吞掉的 sticky 失败翻回 `error.OutOfMemory`。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`ensureStandardGlobalsInstaller`、`core.JSRuntime.create`、`rt.destroy`、`core.JSContext.create`、`ctx.destroy`。显式 `return error.OutOfMemory`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `stickyFailureTailProbe` (`src/tests/oom.zig:612`)

- **签名**：`fn stickyFailureTailProbe(allocator: std.mem.Allocator) !void`。
- **作用**：Some engine paths degrade gracefully when an allocation fails (e.g. the teardown GC symbol-root scan skips its precise pass), so a sticky injected failure near the end of a run can be absorbed and the run still succeeds. `checkAllAllocationFailures` would report that as SwallowedOutOfMemoryError even though it is deliberate behaviour. This probe performs one final allocation through the (still failing) injector: if a sticky failure was absorbed earlier, the probe converts the run into a plain `error.OutOfMemory` outcome, keeping the sweep's leak accounting in force. Value-corrupting swallows are still caught: `expectValue` runs before the probe.。
- **实现**：Some engine paths degrade gracefully when an allocation fails (e.g. the teardown GC symbol-root scan skips its precise pass), so a sticky injected failure near the end of a run can be absorbed and the run still succeeds. `checkAllAllocationFailures` would report that as SwallowedOutOfMemoryError even though it is deliberate behaviour. This probe performs one final allocation through the (still failing) injector: if a sticky failure was absorbed earlier, the probe converts the run into a plain `error.OutOfMemory` outcome, keeping the sweep's leak accounting in force. Value-corrupting swallows are still caught: `expectValue` runs before the probe.。热路径用 `try` 传播分配/引擎错误。关键调用：`allocator.alloc`、`allocator.free`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!void`，由测试 `try`/`expectError` 消费。

### `runParseOnly` (`src/tests/oom.zig:620`)

- **签名**：`fn runParseOnly(allocator: std.mem.Allocator, source: []const u8) !void`。
- **作用**：Pure parse lifecycle: realm + lexer + parser + bytecode pipeline, no execution. Uses a syntax-dense source so the sweep covers the parser allocation clusters and every root/child RealmRef publication rollback.。
- **实现**：Pure parse lifecycle: realm + lexer + parser + bytecode pipeline, no execution. Uses a syntax-dense source so the sweep covers the parser allocation clusters and every root/child RealmRef publication rollback.。含循环。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`core.JSRuntime.create`、`rt.destroy`、`core.RealmContext.create`、`realm.destroy`、`parser.compile`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `resolveGraphModule` (`src/tests/oom.zig:685`)

- **签名**：`fn resolveGraphModule( ptr: *anyopaque, specifier: []const u8, referrer: ?[]const u8, allocator: std.mem.Allocator, ) anyerror!module_graph.HostHooks.ResolvedModule`。
- **作用**：ESM 图夹具的 `resolveModule` 钩子：只认 `./dep.js` 与 `/oom-fixture/dep.js`，其余返回 `error.ModuleNotFound`；命中时把 specifier 与固定 path 各 dupe 一份（specifier 的 dupe 带 `errdefer` 回滚），kind 固定 `.esm`。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。关键调用：`std.mem.eql`、`allocator.dupe`、`allocator.free`。显式 `return error.ModuleNotFound`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `anyerror!module_graph.HostHooks.ResolvedModule`，由测试 `try`/`expectError` 消费。

### `loadGraphModule` (`src/tests/oom.zig:705`)

- **签名**：`fn loadGraphModule( ptr: *anyopaque, resolved: module_graph.HostHooks.ResolvedModule, allocator: std.mem.Allocator, ) anyerror!module_graph.HostHooks.LoadedModule`。
- **作用**：ESM 图夹具的 `loadModule` 钩子：path 不是 `/oom-fixture/dep.js` 就 `error.ModuleNotFound`；命中时回一段进程内常量源码（`owned = false`，只有 path 是 dupe 出来的）。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.mem.eql`、`allocator.dupe`。显式 `return error.ModuleNotFound`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `anyerror!module_graph.HostHooks.LoadedModule`，由测试 `try`/`expectError` 消费。

### `runEsmGraphLink` (`src/tests/oom.zig:722`)

- **签名**：`fn runEsmGraphLink(allocator: std.mem.Allocator) !void`。
- **作用**：ESM link lifecycle: two in-memory modules resolved through host hooks, exercising module records, link, instantiate, and evaluation order.。
- **实现**：ESM link lifecycle: two in-memory modules resolved through host hooks, exercising module records, link, instantiate, and evaluation order.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`runEsmGraphLink`、`ensureStandardGlobalsInstaller`、`core.JSRuntime.create`、`rt.destroy`、`core.JSContext.create`、`ctx.destroy`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `OneShotFailingAllocator.allocator` (`src/tests/oom.zig:821`)

- **签名**：`fn allocator(self: *OneShotFailingAllocator) std.mem.Allocator`。
- **作用**：把单发失败注入器包成 `std.mem.Allocator`：`ptr` 指向自身，vtable 挂本结构的 alloc/resize/remap/free。
- **实现**：返回 `.{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } }`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.takeInjectionSlot` (`src/tests/oom.zig:837`)

- **签名**：`fn takeInjectionSlot(self: *OneShotFailingAllocator) bool`。
- **作用**：One step of the shared injection index. Both the allocator vtable and the block-cell hook consume it, which is what puts "the N-th cell allocation fails" into the same `fail_index` space as "the N-th allocator call fails" instead of a second sweep dimension.。
- **实现**：One step of the shared injection index. Both the allocator vtable and the block-cell hook consume it, which is what puts "the N-th cell allocation fails" into the same `fail_index` space as "the N-th allocator call fails" instead of a second sweep dimension.。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.shouldFailCell` (`src/tests/oom.zig:850`)

- **签名**：`fn shouldFailCell(ctx: *anyopaque) bool`。
- **作用**：Block-cell refusal. Charges nothing to the byte/call ledger: no backing allocation happens, so `expectBalanced` stays a statement about the backing allocator and the `oom_cap` "OOM delivery allocates nothing" invariant is untouched. Single-shot like the allocator arm, so the engine has a working heap again while it unwinds.。
- **实现**：Block-cell refusal. Charges nothing to the byte/call ledger: no backing allocation happens, so `expectBalanced` stays a statement about the backing allocator and the `oom_cap` "OOM delivery allocates nothing" invariant is untouched. Single-shot like the allocator arm, so the engine has a working heap again while it unwinds.。关键调用：`self.takeInjectionSlot`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.armCellInjection` (`src/tests/oom.zig:855`)

- **签名**：`fn armCellInjection(self: *OneShotFailingAllocator) void`。
- **作用**：把 `core.gc_block_heap.cell_failure_injector` 指向本注入器（`shouldFail = shouldFailCell`），从而让 block heap 的 cell 分配也落进同一条 `fail_index` 索引空间。
- **实现**：`core.gc_block_heap.cell_failure_injector = .{ .context = self, .shouldFail = shouldFailCell };`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.disarmCellInjection` (`src/tests/oom.zig:862`)

- **签名**：`fn disarmCellInjection() void`。
- **作用**：把全局 `cell_failure_injector` 置回 null；每个 arm 点都配一条 `defer` 调它，免得注入器泄到下一个用例。
- **实现**：`core.gc_block_heap.cell_failure_injector = null;`（无参数，静态函数）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.alloc` (`src/tests/oom.zig:866`)

- **签名**：`fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8`。
- **作用**：vtable 的 alloc 臂：先 `takeInjectionSlot()`，轮到注入就返回 null（单发 OOM）；否则转 `backing.rawAlloc` 并把 len/次数记进 `allocated_bytes`/`alloc_calls` 账本。
- **实现**：关键调用：`self.takeInjectionSlot`、`self.backing.rawAlloc`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.resize` (`src/tests/oom.zig:878`)

- **签名**：`fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool`。
- **作用**：转发 `backing.rawResize` 且不注入（原地扩容失败时引擎会退回 alloc+copy，注入点已在 `alloc` 上），成功则按增减把差额记进 `allocated_bytes`/`freed_bytes`。
- **实现**：关键调用：`self.backing.rawResize`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.remap` (`src/tests/oom.zig:889`)

- **签名**：`fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8`。
- **作用**：转发 `backing.rawRemap`，同样不注入，按新旧长度差更新字节账本。
- **实现**：关键调用：`self.backing.rawRemap`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.free` (`src/tests/oom.zig:900`)

- **签名**：`fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void`。
- **作用**：`freed_bytes += memory.len`、`free_calls += 1` 后转 `backing.rawFree`——两个计数器就是 `expectBalanced` 的另一半。
- **实现**：关键调用：`self.backing.rawFree`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `OneShotFailingAllocator.expectBalanced` (`src/tests/oom.zig:907`)

- **签名**：`fn expectBalanced(self: *const OneShotFailingAllocator) !void`。
- **作用**：显式收支平衡断言：`allocated_bytes == freed_bytes` 且 `alloc_calls == free_calls`。每个注入尝试都要过一遍，等于把 `std.testing.allocator` 的泄漏检查在这条自造路径上重做一次。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `runRecoveryAttempt` (`src/tests/oom.zig:923`)

- **签名**：`fn runRecoveryAttempt(injector: *OneShotFailingAllocator, snippet: Snippet) !void`。
- **作用**：One recovery attempt under a single injected failure at `fail_index`. Contract being pinned:   - the injected failure either stays invisible (soft path), surfaces as     `error.OutOfMemory` to the embedder, or lands in a JS-visible     exception (`error.JSException` with a pending exception value);   - afterwards the SAME runtime evaluates the canary script with the     correct result;   - teardown releases every byte (explicit alloc/free balance).。
- **实现**：One recovery attempt under a single injected failure at `fail_index`. Contract being pinned:   - the injected failure either stays invisible (soft path), surfaces as     `error.OutOfMemory` to the embedder, or lands in a JS-visible     exception (`error.JSException` with a pending exception value);   - afterwards the SAME runtime evaluates the canary script with the     correct result;   - teardown releases every byte (explicit alloc/free balance).。主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。主动触发/轮询 GC，断言存活集。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`injector.armCellInjection`、`OneShotFailingAllocator.disarmCellInjection`、`ensureStandardGlobalsInstaller`、`core.JSRuntime.create`、`injector.allocator`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `recoveryCanarySweep` (`src/tests/oom.zig:990`)

- **签名**：`fn recoveryCanarySweep(snippet: Snippet) !void`。
- **作用**：Sweeps single-shot failure indices over a snippet: every index in the dense prefix, then a fixed stride (the full per-index sweep is already covered by checkAllAllocationFailures; the canary axis only needs representative spread).。
- **实现**：Sweeps single-shot failure indices over a snippet: every index in the dense prefix, then a fixed stride (the full per-index sweep is already covered by checkAllAllocationFailures; the canary axis only needs representative spread).。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`runRecoveryAttempt`、`std.debug.print`、`injector.expectBalanced`、`std.testing.expect`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectIntrinsicBootstrapCleared` (`src/tests/oom.zig:1016`)

- **签名**：`fn expectIntrinsicBootstrapCleared(ctx: *core.JSContext) !void`。
- **作用**：断言一次失败的 realm intrinsic bootstrap 把 context 彻底退回空白态：`global`/`preallocated_oom_error`/两个 cached proto/四个 shape 全为 null，`eval_function` 与 `native_error_prototypes`、`cached_values`、前 `init_count` 个 `class_prototypes` 全是 null 值——只有这样重试才是干净重来。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`ctx.eval_function.isNull`、`value.isNull`、`@min`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `runContextGlobalRetryAttempt` (`src/tests/oom.zig:1065`)

- **签名**：`fn runContextGlobalRetryAttempt(fail_index: usize) !bool`。
- **作用**：一次「第 fail_index 个分配失败」的 realm bootstrap 重试尝试：bootstrap/teardown 期间 `disarmed`，只在 `contextGlobal(ctx)` 这一小段开注入；失败时要求 context 仍 live、intrinsic 状态已清空（`expectIntrinsicBootstrapCleared`）、紧接着的第二次 `contextGlobal` 必须成功，最后跑 arguments/RegExp/Array 原型身份的 canary 并 `expectBalanced`。返回是否真的注入过（供调用方决定是否继续扫）。
- **实现**：主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`runContextGlobalRetryAttempt`、`injector.armCellInjection`、`OneShotFailingAllocator.disarmCellInjection`、`ensureStandardGlobalsInstaller`、`core.JSRuntime.create`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!bool`，由测试 `try`/`expectError` 消费。

### `runBindingContextConstructionRetryAttempt` (`src/tests/oom.zig:1125`)

- **签名**：`fn runBindingContextConstructionRetryAttempt(fail_index: usize) !bool`。
- **作用**：一次 binding-Realm 构造回滚/重试尝试：先建一个 anchor context（让新 Realm 的发布必须扩容那个一项的 root-provider 数组，把最后的可失败提交也纳入注入面），只在 `BindingContext.create(rt)` 这段开注入。OOM 时跑一次环回收并断言未发布的图整个退役——`constructing_context_head/tail` 为 null、`firstContext()` 仍是 anchor、`root_providers.len` 仍是 1、`native_entries` 没增长——然后重试必须成功，最后 canary + `expectBalanced`。返回是否真的注入过。
- **实现**：主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。主动触发/轮询 GC，断言存活集。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`runBindingContextConstructionRetryAttempt`、`injector.armCellInjection`、`OneShotFailingAllocator.disarmCellInjection`、`ensureStandardGlobalsInstaller`、`core.JSRuntime.create`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!bool`，由测试 `try`/`expectError` 消费。

### `corpusSnippetNamed` (`src/tests/oom.zig:1326`)

- **签名**：`fn corpusSnippetNamed(name: []const u8) Snippet`。
- **作用**：按名字在 `corpus` 数组里线性找语料条目并返回；名字不存在直接 `unreachable`（名单写死在同一文件里，写错就是编码错误）。
- **实现**：含循环。关键调用：`corpusSnippetNamed`、`std.mem.eql`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CellOnlyInjector.shouldFail` (`src/tests/oom.zig:1395`)

- **签名**：`fn shouldFail(ctx: *anyopaque) bool`。
- **作用**：只管 block-cell 的单发拒绝钩子：每次被问就 `questions += 1`，只有轮到 `fail_at` 且还没 `fired` 时返回 true 并置 `fired`。与 `OneShotFailingAllocator` 分开正是为了能点名某一次 cell 分配。
- **实现**：取 `questions` 当索引并自增；`if (self.fired or index != self.fail_at) return false;` 否则 `self.fired = true; return true;`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `CellOnlyInjector.arm` (`src/tests/oom.zig:1404`)

- **签名**：`fn arm(self: *CellOnlyInjector) void`。
- **作用**：把 `core.gc_block_heap.cell_failure_injector` 指向本结构（`shouldFail` 为上面的函数）；解除仍复用 `OneShotFailingAllocator.disarmCellInjection`。
- **实现**：`core.gc_block_heap.cell_failure_injector = .{ .context = self, .shouldFail = shouldFail };`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `runLookaheadRestoreAttempt` (`src/tests/oom.zig:1495`)

- **签名**：`fn runLookaheadRestoreAttempt(injector: *OneShotFailingAllocator, fail_index: usize) !void`。
- **作用**：One module compile with a single allocation failure injected `fail_index` allocations into the parse. Runtime and realm bootstrap run disarmed on purpose: they dominate the index space and are already swept by the corpus tests, while the window that matters here is the compile itself.  Contract: a valid module under one injected failure either compiles or reports `error.OutOfMemory` (`compile` propagates OOM instead of routing it into the syntax-error guard). A `syntax_error` result therefore means some lookahead helper returned with the lexer left mid-token.。
- **实现**：One module compile with a single allocation failure injected `fail_index` allocations into the parse. Runtime and realm bootstrap run disarmed on purpose: they dominate the index space and are already swept by the corpus tests, while the window that matters here is the compile itself.  Contract: a valid module under one injected failure either compiles or reports `error.OutOfMemory` (`compile` propagates OOM instead of routing it into the syntax-error guard). A `syntax_error` result therefore means some lookahead helper returned with the lexer left mid-token.。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`runLookaheadRestoreAttempt`、`injector.armCellInjection`、`OneShotFailingAllocator.disarmCellInjection`、`core.JSRuntime.create`、`injector.allocator`、`rt.destroy`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### 测试块（22）

### `test "oom corpus: pure parse"` (`src/tests/oom.zig:768`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom corpus: pure parse。
- **实现**：先用可靠内存跑一遍 `runParseOnly(parse_only_source)` 预热进程级懒初始化（否则 `checkAllAllocationFailures` 会判 NondeterministicMemoryUsage），再把同一函数交给 `std.testing.checkAllAllocationFailures` 逐个分配点注入。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom corpus: eval snippets"` (`src/tests/oom.zig:776`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom corpus: eval snippets。
- **实现**：遍历整个 `corpus`：每条先 `runSnippet` 预热并验完成值（失败时打印条目名），再 `std.testing.checkAllAllocationFailures(runSnippet, .{snippet})` 做穷尽注入扫描（失败同样打印条目名）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom corpus: esm graph link"` (`src/tests/oom.zig:791`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom corpus: esm graph link。
- **实现**：先 `runEsmGraphLink` 预热跑通两模块图，再交给 `std.testing.checkAllAllocationFailures` 穷尽注入。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: ordinary GLOBAL selector retries auto-init"` (`src/tests/oom.zig:1033`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: ordinary GLOBAL selector retries auto-init。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "oom recovery canary: same Realm intrinsic bootstrap retry"` (`src/tests/oom.zig:1119`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: same Realm intrinsic bootstrap retry。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: binding Realm construction rollback and retry"` (`src/tests/oom.zig:1195`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: binding Realm construction rollback and retry。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: FunctionBytecode combined main FAM allocation"` (`src/tests/oom.zig:1201`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: FunctionBytecode combined main FAM allocation。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。设置 runtime 内存上限以注入 OOM。断言 26 处 `std.testing.expect*`。约 26 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "oom recovery canary: arithmetic snippet"` (`src/tests/oom.zig:1333`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: arithmetic snippet。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("arith-numbers"))`：对该语料做 dense 前 64 + 步长 23 的单发 fail-at-N 扫描，每次都要求引擎恢复并跑通 canary、收支平衡。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: root and nested closure construction"` (`src/tests/oom.zig:1337`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: root and nested closure construction。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("calls-closures"))`：单发 fail-at-N 扫描根函数与嵌套闭包构造路径。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: native callback map through Reflect.apply"` (`src/tests/oom.zig:1341`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: native callback map through Reflect.apply。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-map-reflect-apply"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: nested Map and Set callbacks"` (`src/tests/oom.zig:1345`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: nested Map and Set callbacks。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-map-set"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: accessor Proxy and primitive coercion callbacks"` (`src/tests/oom.zig:1349`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: accessor Proxy and primitive coercion callbacks。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-property-proxy-coercion"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: JSON reviver replacer and toJSON callbacks"` (`src/tests/oom.zig:1353`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: JSON reviver replacer and toJSON callbacks。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-json"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: String Iterator helper and DisposableStack callbacks"` (`src/tests/oom.zig:1357`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: String Iterator helper and DisposableStack callbacks。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-string-iterator-dispose"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: Promise executor callback"` (`src/tests/oom.zig:1361`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: Promise executor callback。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("native-callback-promise-executor"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: repeated private class identity"` (`src/tests/oom.zig:1365`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: repeated private class identity。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("private-class-fresh-identity"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: rope concat+flatten snippet"` (`src/tests/oom.zig:1369`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: rope concat+flatten snippet。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("rope-concat-flatten"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: promise jobs snippet"` (`src/tests/oom.zig:1373`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: promise jobs snippet。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("promise-jobs"))`（该语料开 `drain_jobs`，微任务队列也在注入面内）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom recovery canary: generator return through shared finalizer"` (`src/tests/oom.zig:1377`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom recovery canary: generator return through shared finalizer。
- **实现**：`recoveryCanarySweep(corpusSnippetNamed("generator-return-shared-finalizer"))`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom cell injection: the hook is reached and a refusal is honoured"` (`src/tests/oom.zig:1417`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom cell injection: the hook is reached and a refusal is honoured。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "oom parser canary: export name lookahead restores the lexer position"` (`src/tests/oom.zig:1533`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom parser canary: export name lookahead restores the lexer position。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "oom coverage report"` (`src/tests/oom.zig:1570`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：oom coverage report。
- **实现**：仅当 `core.memory.oom_coverage_enabled`（`-Dzjs_oom_coverage=true`）时打印 `oomCoverageDistinctSiteCount()`，否则 comptime 直接 return；放在文件最后一条，计数才覆盖整套。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

## `src/tests/bytecode.zig` — 字节码载体与 finalize

常量池所有权、label 解析、FunctionBytecode fixture、OOM 生命周期。

文件头：Exercises bytecode carriers, label resolution, and constant-pool ownership.

### 函数（清单 6）

### `attachV2Builder` (`src/tests/bytecode.zig:248`)

- **签名**：`fn attachV2Builder(fd: *function_def.FunctionDef) !*compiler.Builder`。
- **作用**：Give a hand-built FunctionDef the compact producer finalization requires. There is one compiler and one lowering input: a FunctionDef with no attached Builder is rejected by `prepareCurrentBeforeChildren`, so every fixture that reaches the finalizer must emit through this. The Builder is owned by the FunctionDef and released by `fd.deinit`.。
- **实现**：Give a hand-built FunctionDef the compact producer finalization requires. There is one compiler and one lowering input: a FunctionDef with no attached Builder is rejected by `prepareCurrentBeforeChildren`, so every fixture that reaches the finalizer must emit through this. The Builder is owned by the FunctionDef and released by `fd.deinit`.。热路径用 `try` 传播分配/引擎错误。关键调用：`fd.memory.create`、`compiler.Builder.init`。
- **所有权 / 错误 / 调用**：返回 `!*compiler.Builder`，由测试 `try`/`expectError` 消费。

### `emitTestBody` (`src/tests/bytecode.zig:265`)

- **签名**：`fn emitTestBody( fd: *function_def.FunctionDef, code: []const u8, atoms: []const core.Atom, ) !void`。
- **作用**：Replay a literal instruction sequence into `fd`'s v2 Builder. This is the V2-equivalent of the `fd.appendByteCode` fixtures the deleted legacy pipeline accepted: the same instructions, delivered through the only producer the compiler reads. Atom operands are taken from `atoms` in stream order and retained by the builder.  Label-bearing operands are deliberately unsupported: in the producer they are LabelId identities, not addresses, so a fixture that needs one emits it directly with `emitJump` / `emitScopeRefOpOwned`.。
- **实现**：Replay a literal instruction sequence into `fd`'s v2 Builder. This is the V2-equivalent of the `fd.appendByteCode` fixtures the deleted legacy pipeline accepted: the same instructions, delivered through the only producer the compiler reads. Atom operands are taken from `atoms` in stream order and retained by the builder.  Label-bearing operands are deliberately unsupported: in the producer they are LabelId identities, not addresses, so a fixture that needs one emits it directly with `emitJump` / `emitScopeRefOpOwned`.。主体是 `switch` 分发。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`attachV2Builder`、`opcode.sizeOfPhase1`、`opcode.formatOfPhase1`、`b.emitOp`、`b.emitOpU8`。显式 `return error.InvalidBytecode`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `createTestFunctionBytecode` (`src/tests/bytecode.zig:343`)

- **签名**：`fn createTestFunctionBytecode( fd: *function_def.FunctionDef, rt: *core.JSRuntime, ) ![]bytecode.FunctionBytecode`。
- **作用**：Hand-built FunctionDefs in this suite bypass Parser.State, which normally creates scope zero. Give those fixtures the same mandatory root scope before exercising the production finalizer.。
- **实现**：Hand-built FunctionDefs in this suite bypass Parser.State, which normally creates scope zero. Give those fixtures the same mandatory root scope before exercising the production finalizer.。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`fd.appendScope`、`core.RealmContext.create`、`realm.destroy`、`pipeline.finalize.createFunctionBytecode`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `![]bytecode.FunctionBytecode`，由测试 `try`/`expectError` 消费。

### `finalizeMutableWithTestRealm` (`src/tests/bytecode.zig:989`)

- **签名**：`fn finalizeMutableWithTestRealm( function: *bytecode.Bytecode, fd: *function_def.FunctionDef, rt: *core.JSRuntime, ) !void`。
- **作用**：给手搓的 `FunctionDef` 配一个一次性 `RealmContext` 再跑生产 finalize：`RealmContext.create(rt)` + `defer realm.destroy()`，然后 `pipeline.finalize.runWithFunctionDefRuntime(function, fd, .{ .realm = realm })`——测试因此不必自己建 JSContext 就能走完整条 lowering。
- **实现**：热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`finalizeMutableWithTestRealm`、`core.RealmContext.create`、`realm.destroy`、`pipeline.finalize.runWithFunctionDefRuntime`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `populateFunctionDefForFinalizeFailure` (`src/tests/bytecode.zig:2834`)

- **签名**：`fn populateFunctionDefForFinalizeFailure( fd: *function_def.FunctionDef, name: atom_module.Atom, arg_name: atom_module.Atom, captured_name: atom_module.Atom, ) !void`。
- **作用**：把一个手搓 `FunctionDef` 填成 finalize OOM 扫描要的形状：经 v2 Builder 发 `push_atom_value(name)`（并在其后第 5 字节的指令边界加一条 source marker，因为 source-loc 条目不接受指令中间的 pc）、`drop`/`get_var 0`/`drop`/`return_undef`，再加一个 cpool int32(99)、一个参数、一个 const 变量、一个 lexical const 闭包变量，最后 `replaceSourceText`——即每类 owner（atom/cpool/arg/var/closure/source text）各占一份。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`attachV2Builder`、`b.emitAtomOpOwned`、`b.addSourceMarker`、`b.emitOp`、`b.emitOpU16`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `runFunctionBytecodeFinalizeOomLifecycle` (`src/tests/bytecode.zig:2864`)

- **签名**：`fn runFunctionBytecodeFinalizeOomLifecycle(allocator: std.mem.Allocator) !void`。
- **作用**：一次完整的 finalize 生命周期，供 `checkAllAllocationFailures` 按分配点重放：建 Runtime + RealmContext、intern 三个 atom、填 `FunctionDef`（含 scope 0）、`pipeline.finalize.createFunctionBytecode`，要求产物带 source text，然后按 fd → realm → runtime 的顺序显式拆掉；任一步失败都由 `errdefer` 的 owned 标志对称回滚，保证每个注入点都是 allocated == freed。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`runFunctionBytecodeFinalizeOomLifecycle`、`core.JSRuntime.create`、`rt.destroy`、`core.RealmContext.create`、`realm.destroy`、`rt.internAtom`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### 测试块（69）

### `test "constant pool retains and releases values"` (`src/tests/bytecode.zig:13`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constant pool retains and releases values」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constant pool appendOwned transfers refcounted values"` (`src/tests/bytecode.zig:28`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constant pool appendOwned transfers refcounted values」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constant pool retains owned unique symbol atoms until release"` (`src/tests/bytecode.zig:40`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constant pool retains owned unique symbol atoms until release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constant pool appendOwned retains unique symbol atoms until release"` (`src/tests/bytecode.zig:70`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constant pool appendOwned retains unique symbol atoms until release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode owns code constants and module metadata"` (`src/tests/bytecode.zig:100`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode owns code constants and module metadata」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "script or module metadata owns each bytecode transfer"` (`src/tests/bytecode.zig:134`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「script or module metadata owns each bytecode transfer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode setCode owns exactly the visible code bytes"` (`src/tests/bytecode.zig:172`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode setCode owns exactly the visible code bytes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode appendCode preserves eval-looking atom operand bytes as data"` (`src/tests/bytecode.zig:192`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode appendCode preserves eval-looking atom operand bytes as data」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode module record add failure releases duplicated atom references"` (`src/tests/bytecode.zig:210`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode module record add failure releases duplicated atom references」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。强制 major / 环回收后比对 `liveCount` 或对象身份。设置 runtime 内存上限以注入 OOM。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "createFunctionBytecode rejects a cross-runtime compile context before moving owners"` (`src/tests/bytecode.zig:356`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createFunctionBytecode rejects a cross-runtime compile context before moving owners」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionBytecode uses the exact QJS base and optional inline tails"` (`src/tests/bytecode.zig:384`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionBytecode uses the exact QJS base and optional inline tails」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 36 处 `std.testing.expect*`。约 36 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionLayout matches the QJS-order core pack"` (`src/tests/bytecode.zig:474`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionLayout matches the QJS-order core pack」。
- **实现**：断言 25 处 `std.testing.expect*`。约 25 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "FunctionLayout has no padding between QJS core segments or after extension-free code"` (`src/tests/bytecode.zig:538`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionLayout has no padding between QJS core segments or after extension-free code」。
- **实现**：断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "FunctionLayout places the exact hot tail at every code-end residue"` (`src/tests/bytecode.zig:602`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionLayout places the exact hot tail at every code-end residue」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionLayout rejects every checked size overflow class"` (`src/tests/bytecode.zig:664`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionLayout rejects every checked size overflow class」。
- **实现**：用 `expectError` 钉失败路径。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "CallFacts is one 16-bit execution snapshot"` (`src/tests/bytecode.zig:684`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「CallFacts is one 16-bit execution snapshot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionBytecode raw flag bytes and packed nullable pointers are canonical"` (`src/tests/bytecode.zig:737`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionBytecode raw flag bytes and packed nullable pointers are canonical」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 21 处 `std.testing.expect*`。约 21 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "packed FunctionBytecode zero-count pointers stay null beside non-empty segments"` (`src/tests/bytecode.zig:796`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「packed FunctionBytecode zero-count pointers stay null beside non-empty segments」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "non-empty W1c5 fixture does not force the optional extension"` (`src/tests/bytecode.zig:829`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：non-empty W1c5 fixture does not force the optional extension。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionBytecode FAM builder zeroes a reused slab payload without touching metadata"` (`src/tests/bytecode.zig:858`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionBytecode FAM builder zeroes a reused slab payload without touching metadata」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 22 处 `std.testing.expect*`。约 22 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "published no-debug no-extension FunctionBytecode uses the deferred zero-FAM free path"` (`src/tests/bytecode.zig:941`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「published no-debug no-extension FunctionBytecode uses the deferred zero-FAM free path」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "published packed FunctionBytecode preserves its exact FAM size through deferred free"` (`src/tests/bytecode.zig:960`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「published packed FunctionBytecode preserves its exact FAM size through deferred free」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: init/deinit"` (`src/tests/bytecode.zig:999`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: init/deinit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef appendByteCode does not infer direct eval from atom operand bytes"` (`src/tests/bytecode.zig:1020`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：FunctionDef appendByteCode does not infer direct eval from atom operand bytes。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: cpool transfers refcounted owned values"` (`src/tests/bytecode.zig:1040`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: cpool transfers refcounted owned values」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: cpool retains unique symbol atoms until release"` (`src/tests/bytecode.zig:1053`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: cpool retains unique symbol atoms until release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: cpool appendOwned retains unique symbol atoms until release"` (`src/tests/bytecode.zig:1085`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: cpool appendOwned retains unique symbol atoms until release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: add var"` (`src/tests/bytecode.zig:1117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: add var」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: add scope"` (`src/tests/bytecode.zig:1140`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: add scope」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef final scope proof reseals late arguments links and rejects cycles"` (`src/tests/bytecode.zig:1156`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef final scope proof reseals late arguments links and rejects cycles」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidScope`。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "compiler-v2 run rejects cyclic scope links before trusted lookup"` (`src/tests/bytecode.zig:1195`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「compiler-v2 run rejects cyclic scope links before trusted lookup」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "compiler-v2 parent miss proves corrupt and cyclic synthetic ancestors"` (`src/tests/bytecode.zig:1225`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「compiler-v2 parent miss proves corrupt and cyclic synthetic ancestors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: closure_var"` (`src/tests/bytecode.zig:1274`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: closure_var」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef: LabelSlot and JumpSlot"` (`src/tests/bytecode.zig:1297`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionDef: LabelSlot and JumpSlot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "resolve_labels converges for a large branch topology"` (`src/tests/bytecode.zig:1331`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resolve_labels converges for a large branch topology」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalize: runs the full v2 lowering pipeline"` (`src/tests/bytecode.zig:1367`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalize: runs the full v2 lowering pipeline」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parent finalization failure releases its published child realm owner"` (`src/tests/bytecode.zig:1408`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parent finalization failure releases its published child realm owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parent finalization moves an existing child FunctionBytecode cpool owner without rc churn"` (`src/tests/bytecode.zig:1458`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parent finalization moves an existing child FunctionBytecode cpool owner without rc churn」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "stack_size accepts nested gosub return PCs"` (`src/tests/bytecode.zig:1511`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack_size accepts nested gosub return PCs」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "stack_size rejects ret without a gosub return PC"` (`src/tests/bytecode.zig:1528`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack_size rejects ret without a gosub return PC」。
- **实现**：断言错误 `error.StackUnderflow`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "createFunctionBytecode: moves final owners from FunctionDef without refcount churn"` (`src/tests/bytecode.zig:1535`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createFunctionBytecode: moves final owners from FunctionDef without refcount churn」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 66 处 `std.testing.expect*`。约 66 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "finalize rejects a same-count mismatched inline atom owner before transfer"` (`src/tests/bytecode.zig:1693`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「finalize rejects a same-count mismatched inline atom owner before transfer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBytecode`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "FunctionDef source replacement preserves the prior NUL owner across OOM and retry"` (`src/tests/bytecode.zig:1721`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：FunctionDef source replacement preserves the prior NUL owner across OOM and retry。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "abrupt FunctionBytecode finalization leaves the same runtime reusable"` (`src/tests/bytecode.zig:1750`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「abrupt FunctionBytecode finalization leaves the same runtime reusable」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。设置 runtime 内存上限以注入 OOM。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "final bytecode vardefs are compact arguments plus locals"` (`src/tests/bytecode.zig:1788`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「final bytecode vardefs are compact arguments plus locals」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "final variable metadata matches pinned QuickJS physical ABI"` (`src/tests/bytecode.zig:1824`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「final variable metadata matches pinned QuickJS physical ABI」。
- **实现**：断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "legacy execution adapter delegates synthetic var-ref name mirrors"` (`src/tests/bytecode.zig:1877`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「legacy execution adapter delegates synthetic var-ref name mirrors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 25 处 `std.testing.expect*`。约 25 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode separates strict and sloppy simple inline eligibility"` (`src/tests/bytecode.zig:1948`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode separates strict and sloppy simple inline eligibility」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 35 处 `std.testing.expect*`。约 35 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode publishes exact-args leaf bytes by mode and geometry"` (`src/tests/bytecode.zig:2074`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode publishes exact-args leaf bytes by mode and geometry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function bytecode publishes capture leaf kind by mode and geometry"` (`src/tests/bytecode.zig:2155`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function bytecode publishes capture leaf kind by mode and geometry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "stack_size compute reports the return-balance proof"` (`src/tests/bytecode.zig:2261`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack_size compute reports the return-balance proof」。
- **实现**：断言错误 `error.ReachableFalloff`。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "stack_size scratch stays on stack through 256 positions and falls back at 257"` (`src/tests/bytecode.zig:2325`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack_size scratch stays on stack through 256 positions and falls back at 257」。
- **实现**：用 `expectError` 钉失败路径。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "stack_size allocation-free LIFO handles multiple pending successors"` (`src/tests/bytecode.zig:2352`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack_size allocation-free LIFO handles multiple pending successors」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "stack verifier rejects reachable end edges"` (`src/tests/bytecode.zig:2374`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stack verifier rejects reachable end edges」。
- **实现**：断言错误 `error.ReachableFalloff`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "zero-arg empty leaf publication requires the return-balance proof"` (`src/tests/bytecode.zig:2383`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「zero-arg empty leaf publication requires the return-balance proof」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval reserves identity for visible function-scope locals and arguments"` (`src/tests/bytecode.zig:2479`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval reserves identity for visible function-scope locals and arguments」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "surviving local references reserve compact open VarRef storage"` (`src/tests/bytecode.zig:2521`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「surviving local references reserve compact open VarRef storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "sloppy function-name references lower to an uncaptured dummy object property"` (`src/tests/bytecode.zig:2559`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「sloppy function-name references lower to an uncaptured dummy object property」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "surviving argument references lower to make_arg_ref and reserve storage"` (`src/tests/bytecode.zig:2612`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「surviving argument references lower to make_arg_ref and reserve storage」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct Bytecode retains compact open VarRef frame sizing"` (`src/tests/bytecode.zig:2656`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct Bytecode retains compact open VarRef frame sizing」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "mapped frames use the exact compile-time open-binding count for every frame kind"` (`src/tests/bytecode.zig:2692`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped frames use the exact compile-time open-binding count for every frame kind」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "createFunctionBytecode: final declaration metadata lives only in ClosureVar"` (`src/tests/bytecode.zig:2725`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createFunctionBytecode: final declaration metadata lives only in ClosureVar」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "createFunctionBytecode accounts large finalized payload in large space"` (`src/tests/bytecode.zig:2767`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createFunctionBytecode accounts large finalized payload in large space」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "private class identity has no bytecode side metadata carrier"` (`src/tests/bytecode.zig:2902`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「private class identity has no bytecode side metadata carrier」。
- **实现**：断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "createFunctionBytecode exhaustively rolls back every precommit allocation failure"` (`src/tests/bytecode.zig:2914`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createFunctionBytecode exhaustively rolls back every precommit allocation failure」。
- **实现**：先用可靠内存跑一遍 `runFunctionBytecodeFinalizeOomLifecycle` 预热，再 `std.testing.checkAllAllocationFailures` 对同一函数逐个分配点注入失败，要求每次都以 `error.OutOfMemory` 出栈且无泄漏（precommit 阶段的所有 owner 必须整体回滚）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "installCodeWithCapacity/installAtomOperandsWithCapacity account the full backing across replacement and deinit"` (`src/tests/bytecode.zig:2923`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「installCodeWithCapacity/installAtomOperandsWithCapacity account the full backing across replacement and deinit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "capacity-carry install with zero used length still owns and frees the backing"` (`src/tests/bytecode.zig:2970`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「capacity-carry install with zero used length still owns and frees the backing」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "phase-3 exact-fit replacement frees the carried capacity once and releases atom refs once"` (`src/tests/bytecode.zig:2998`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「phase-3 exact-fit replacement frees the carried capacity once and releases atom refs once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "four-ledger phase-boundary ownership accounting compile-only"` (`src/tests/bytecode.zig:3050`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「four-ledger phase-boundary ownership accounting compile-only」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

大文件目录：

- [`20-tests-core.md`](20-tests-core.md) — `src/tests/core.zig`
- [`20-tests-parser.md`](20-tests-parser.md) — `src/tests/parser.zig`
- [`20-tests-exec.md`](20-tests-exec.md) — `src/tests/exec.zig`
- [`20-tests-builtins.md`](20-tests-builtins.md) — `src/tests/builtins.zig`

## 覆盖核对

- 清单函数数: 140
- 本文标题覆盖: 314
- 未覆盖: 无
