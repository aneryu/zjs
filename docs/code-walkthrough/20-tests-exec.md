# 20 — VM / 调用 / 模块 / Promise

`tests/exec.zig` 是最大的行为钉：求值、调用约定、尾调用、模块图、Promise job、中断与原生栅栏。517 个 test 里 220 例各自 `helpers.TestEngine.init` 起独立引擎、176 例走共享 `sharedTestEngine`、62 例裸 `JSRuntime.create`，其余 59 例不自建引擎（58 例 `helpers.expectPrints` 比对输出，1 例只断言纯 Zig helper）。 源文件 `tests/exec.zig`（22343 行）。

## `tests/exec.zig`

`tests/exec.zig` 是最大的行为钉：求值、调用约定、尾调用、模块图、Promise job、中断与原生栅栏。517 个 test 里 220 例各自 `helpers.TestEngine.init` 起独立引擎、176 例走共享 `sharedTestEngine`、62 例裸 `JSRuntime.create`，其余 59 例不自建引擎（58 例 `helpers.expectPrints` 比对输出，1 例只断言纯 Zig helper）。

文件头：Exercises VM execution, calls, jobs, control flow, and runtime semantics.

类型：中断/OOM 臂（`InterruptTestState`、`TailSetupOomArm`、`InterruptOomArm`）、宿主错误探针、`NativeFenceProbe`（同步 native 再入与 cleanup 顺序）、模块图 fixture loader、栈窗口 visit 断言。测试体以独立 `helpers.TestEngine.init` 为主，共享 `sharedTestEngine` 次之。

### 函数（清单 60）

### `InterruptTestState.run` (`tests/exec.zig:230`)

- **签名**：`fn run(_: *core.JSRuntime, userdata: ?*anyopaque) bool`。
- **作用**：测试夹具/探针 `InterruptTestState.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：由 `userdata` `@ptrCast(@alignCast(...))` 还原状态体，`self.hits += 1` 记下本次中断回调被调用，返回 `self.stop`：为 `true` 时引擎按「请求中断」处理。无分配、无错误路径。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `TailSetupOomArm.call` (`tests/exec.zig:241`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `TailSetupOomArm.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：每次调用先 `self.calls += 1`；仅当 `self.exhaust` 为真时把 runtime 内存上限压到 `rt.memory.allocated_bytes` 并置 `rt.suppressLimitCollectionForTest(true)`，随后返回 `undefined`。**刻意不用 `defer` 还原**：本臂运行在必须失败的那次分配所在的调用里，出臂即还原会在失败发生前重新武装收集器，还会覆盖外层测试自己的抑制；该标志是 per-Runtime 的，随 fixture 一起消亡。关键调用：`rt.suppressLimitCollectionForTest`、`rt.setMemoryLimit`、`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `HostBacktraceErrorProbe.call` (`tests/exec.zig:261`)

- **签名**：`fn call(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `HostBacktraceErrorProbe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：函数体只有一行：两个参数都丢弃，无条件 `return error.TypeError`，用来把宿主侧 Zig 错误映射成 JS 异常并钉住其 backtrace。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `ExternalNamedErrorProbe.call` (`tests/exec.zig:267`)

- **签名**：`fn call(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `ExternalNamedErrorProbe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：函数体只有一行：两个参数都丢弃，无条件 `return error.HostProbeFailure`——一个不在引擎错误集里的自定义名字，用来钉外部错误名的透传。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `NativeRecordStackProbe.call` (`tests/exec.zig:279`)

- **签名**：`fn call(ctx: *core.JSContext, _: core.JSValue, _: []const core.JSValue) core.errors.HostError!core.JSValue`。
- **作用**：测试夹具/探针 `NativeRecordStackProbe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用的是结构体级 `var`（`callable`/`calls`/`recurse`）而非实例状态：每次进入 `calls += 1`；当 `recurse` 为假或 `calls >= 256` 时返回 `core.JSValue.int32(7)` 收束递归，否则 `engine.exec.call.callValue(ctx, null, callable, &.{})` 无参回调 JS，制造 native↔JS 交替的深栈。同结构体里 `record` 由 `engine.exec.native_legacy.genericEntry(&call, 0)` 包成 `core.NativeEntry`。
- **所有权 / 错误 / 调用**：返回 `core.errors.HostError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `InterruptOomArm.call` (`tests/exec.zig:290`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `InterruptOomArm.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：每次调用先 `self.calls += 1`；仅当 `self.exhaust` 为真时先把 `invocation.realm.interrupt_counter` 置 1 触发中断，再把 runtime 内存上限压到 `rt.memory.allocated_bytes` 并置 `rt.suppressLimitCollectionForTest(true)`，随后返回 `undefined`。**刻意不用 `defer` 还原**：本臂运行在必须失败的那次分配所在的调用里，出臂即还原会在失败发生前重新武装收集器，还会覆盖外层测试自己的抑制；该标志是 per-Runtime 的，随 fixture 一起消亡。关键调用：`rt.suppressLimitCollectionForTest`、`rt.setMemoryLimit`、`core.JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `NativeFenceProbe.invoke` (`tests/exec.zig:314`)

- **签名**：`fn invoke(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `NativeFenceProbe.invoke`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.invoke_calls += 1`，先把 `cleanup_ran` 置 false，再 `defer self.cleanup_ran = true` —— 这个 `defer` 不是释放资源，而是标记「本次 native 帧已退出」，供 `cleanupObserved` 观察顺序。无参数时 `return error.TypeError`；`invocation.realm.global` 为空时 `return error.InvalidBuiltinRegistry`；否则以 global 为 this、`invocation.args[0]` 为被调者、`args[1..]` 为实参，走 `engine.exec.call_runtime.callValueOrBytecodeSyncInternal` 同步再入。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `NativeFenceProbe.cleanupObserved` (`tests/exec.zig:333`)

- **签名**：`fn cleanupObserved(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `NativeFenceProbe.cleanupObserved`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：还原探针指针后返回 `core.JSValue.boolean(self.cleanup_ran)`，把「上一次 `invoke` 的 native 帧是否已经退出」暴露给 JS 断言。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `crossRealmNativeProbe` (`tests/exec.zig:3241`)

- **签名**：`fn crossRealmNativeProbe(ptr: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `crossRealmNativeProbe`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：从 `ptr` 还原 `*CrossRealmNativeProbe`；`call.realm.global` 为空即 `return error.InvalidBuiltinRegistry`。把本次进入时看到的 realm/global 记进 `probe.seen_realm`/`seen_global`，然后 `try call.realm.runtime.internAtom("__native_realm_mutation")` 并在该 global 上 `defineOwnProperty` 一个可写/可枚举/可配置的数据属性（`core.Descriptor.data(core.JSValue.int32(1), true, true, true)`），证明写到的是被调 realm 的 global；最后无条件 `return error.TypeError`，让调用方同时观察跨 realm 的异常归属。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `localIndexNamed` (`tests/exec.zig:3256`)

- **签名**：`fn localIndexNamed(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, name: []const u8) ?usize`。
- **作用**：测试夹具/探针 `localIndexNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：线性扫 `function.varDefs()`：对每个 vardef 用 `rt.atoms.name(vd.var_name)` 取回名字字节（原子无名字则 `continue`），`std.mem.eql` 与 `name` 相等就返回该下标；扫完返回 `null`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `derivedThisLocalIndex` (`tests/exec.zig:3264`)

- **签名**：`fn derivedThisLocalIndex(function: *const bytecode.FunctionBytecode) ?usize`。
- **作用**：测试夹具/探针 `derivedThisLocalIndex`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：线性扫 `function.varDefs()`，返回第一个 `vd.var_name == core.atom.ids.this_` 的下标——即派生构造器里那个被物化成本地的 `this` 槽；没有则 `null`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `globalFunctionBytecode` (`tests/exec.zig:3271`)

- **签名**：`fn globalFunctionBytecode(js: *helpers.TestEngine, name: []const u8) !*const bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `globalFunctionBytecode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`engine.exec.zjs_vm.contextGlobal(js.context)` 取 global，`js.runtime.internAtom(name)` 取键，`global.getProperty` 读出函数值，`property_ops.expectObject` 断言是对象；`function_object.functionBytecode()` 为空则 `return error.InvalidFunctionBytecode`，再用 `engine.exec.call_runtime.functionBytecodeFromValue` 把存储值转成 `*const bytecode.FunctionBytecode`，转不出同样落 `error.InvalidFunctionBytecode`。
- **所有权 / 错误 / 调用**：返回 `!*const bytecode.FunctionBytecode`，由测试 `try`/`expectError` 消费。

### `fixtureFlagsFromFunction` (`tests/exec.zig:3280`)

- **签名**：`fn fixtureFlagsFromFunction(function: *const bytecode.FunctionBytecode) bytecode.FunctionBytecode.Flags`。
- **作用**：测试夹具/探针 `fixtureFlagsFromFunction`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：纯拷贝：逐字段把源函数的 12 个属性读进一个新的 `bytecode.FunctionBytecode.Flags`——`isStrictMode`、`runtimeStrictMode`、`hasPrototype`、`hasSimpleParameterList`、`isDerivedClassConstructor`、`needHomeObject`、`functionKind`、`newTargetAllowed`、`superCallAllowed`、`superAllowed`、`argumentsAllowed`、`isDirectOrIndirectEval`，好让人造 fixture 与真函数同形。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `createOversizedLeafFixture` (`tests/exec.zig:3297`)

- **签名**：`fn createOversizedLeafFixture( rt: *core.JSRuntime, source: *const bytecode.FunctionBytecode, ) !*bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `createOversizedLeafFixture`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`bytecode.FunctionBytecode.createFixture(rt, ...)` 造一个空函数：realm 取自 `source.realmContext()`，flags 取自 `fixtureFlagsFromFunction(source)`，而 `stack_size` 直接钉成 `core.VmStackArena.chunk_slots`——正好等于一个 VM 栈 chunk，这就是「oversized leaf」的来源；建好后 `fixture.setExecutionFlags(source.executionFlags())` 同步执行标志并返回。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!*bytecode.FunctionBytecode`，由测试 `try`/`expectError` 消费。

### `finalOpcodeCount` (`tests/exec.zig:3310`)

- **签名**：`fn finalOpcodeCount(code: []const u8, wanted: u8) !usize`。
- **作用**：测试夹具/探针 `finalOpcodeCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按 `bytecode.opcode.sizeOf(op_id)` 从 `pc = 0` 步进解码整段字节码；`size == 0` 或 `pc + size > code.len` 说明解码走飞，`return error.InvalidFunctionBytecode`；每遇到 `op_id == wanted` 计数加一，扫完返回计数。
- **所有权 / 错误 / 调用**：返回 `!usize`，由测试 `try`/`expectError` 消费。

### `finalSetVarRefStats` (`tests/exec.zig:3328`)

- **签名**：`fn finalSetVarRefStats(code: []const u8) !SetVarRefStats`。
- **作用**：测试夹具/探针 `finalSetVarRefStats`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：同样按 `bytecode.opcode.sizeOf` 步进（`size == 0` 或越界 → `error.InvalidFunctionBytecode`），识别两种写闭包槽的形态：`op.set_var_ref` 的操作数用 `std.mem.readInt(u16, code[pc+1..][0..2], .little)` 读出，`op.set_var_ref0..set_var_ref3` 这四个短形则用 `op_id - op.set_var_ref0` 当下标。命中就 `stats.count += 1`，并只在第一次记下 `stats.first_idx`。
- **所有权 / 错误 / 调用**：返回 `!SetVarRefStats`，由测试 `try`/`expectError` 消费。

### `hasTailEvalReturn` (`tests/exec.zig:3350`)

- **签名**：`fn hasTailEvalReturn(function: *const bytecode.FunctionBytecode) bool`。
- **作用**：测试夹具/探针 `hasTailEvalReturn`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：扫 `function.byteCode()`：按 `bytecode.opcode.sizeOf` 步进，只要某条 `op.eval` 或 `op.apply_eval` 的下一条字节正好是 `op.@"return"`，就返回 true。解码异常（`size == 0` 或越界）不报错，直接返回 false——它只是个「有没有尾位 eval 返回」的探针。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectSingleDerivedThisClosureCapture` (`tests/exec.zig:3368`)

- **签名**：`fn expectSingleDerivedThisClosureCapture(function: *const bytecode.FunctionBytecode) !void`。
- **作用**：测试夹具/探针 `expectSingleDerivedThisClosureCapture`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `derivedThisLocalIndex(function)` 定位 this 本地（没有则 `error.InvalidFunctionBytecode`），断言该 vardef `isCaptured()`、`function.openVarRefCount() == 1`、`this_vardef.var_ref_idx == 0`，并用 `finalOpcodeCount(function.byteCode(), op.close_loc)` 断言没有 `close_loc`。随后遍历 `function.cpoolSlice()`，用 `engine.exec.call_runtime.functionBytecodeFromValue` 取出子函数，统计有多少个子函数以 `.local` 方式捕获了 `core.atom.ids.this_` 且 `var_idx` 等于该下标——必须恰好 1 个；再断言这个闭包 `functionKind() == .normal`、`!hasPrototype()`，且它自身的 `closureVar()` 里对 this 的捕获恰好一条、类型 `.local`、`var_idx` 一致。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `JobQueueRootProvider.trace` (`tests/exec.zig:6049`)

- **签名**：`fn trace(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `JobQueueRootProvider.trace`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：从 `context` 还原 `*JobQueueRootProvider`，`try self.queue.traceRoots(visitor)` 把 job 队列里持有的值交给根访问者——这是测试把一个裸 `engine.core.jobs.Queue` 挂进 GC 根集的唯一动作。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `JobQueueRootProvider.provider` (`tests/exec.zig:6054`)

- **签名**：`fn provider(self: *@This()) core.runtime.RootProvider`。
- **作用**：测试夹具/探针 `JobQueueRootProvider.provider`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把自身包成 `core.runtime.RootProvider`：`return .{ .context = self, .trace = trace }`，供 runtime 注册根提供者时使用。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `expectEvalCycleReclaimed` (`tests/exec.zig:9543`)

- **签名**：`fn expectEvalCycleReclaimed(js: *helpers.TestEngine, warmup_source: []const u8, cycle_source: []const u8) !void`。
- **作用**：测试夹具/探针 `expectEvalCycleReclaimed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `js.runtime.setGCThreshold(std.math.maxInt(usize))` 把自动 GC 关死（`defer` 还原旧阈值），避免热身与观测之间插入非预期回收。`js.eval(warmup_source)` + `js.runJobs()` 预热后跑一次 `js.runtime.runObjectCycleRemoval()`，以 `js.runtime.gc.liveCount()` 取基线。再 eval `cycle_source` 并排空 job，断言存活数确实涨了、`runObjectCycleRemoval() > 0`（这一轮真回收到东西）、回收后存活数**精确**回到基线，且再跑一次环回收返回 0（幂等、无残留）。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `ImportProbe.run` (`tests/exec.zig:11737`)

- **签名**：`fn run( _: *core.JSContext, _: ?*std.Io.Writer, _: *const engine.core.jobs.DynamicImportPayload, ) core.errors.RuntimeError!core.JSValue`。
- **作用**：测试夹具/探针 `ImportProbe.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：结构体级 `var attempts` 计数：`attempts += 1`，第一次调用 `return error.OutOfMemory` 模拟 job 分配失败，其后返回 `core.JSValue.undefinedValue()`，让测试检查失败的 dynamic import job 是否保住了原来的 FIFO 位置并被重试。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.errors.RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `ImportProbe.run` (`tests/exec.zig:11789`)

- **签名**：`fn run( ctx: *core.JSContext, _: ?*std.Io.Writer, _: *const engine.core.jobs.DynamicImportPayload, ) core.errors.RuntimeError!core.JSValue`。
- **作用**：测试夹具/探针 `ImportProbe.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只做记录：把本次运行时看到的 realm 与其 global 存进结构体级 `var seen_realm`/`seen_global`，再返回 `core.JSValue.undefinedValue()`——用来钉 dynamic import job 在哪个 `core.JSContext` 上执行。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.errors.RuntimeError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `LoaderProbe.load` (`tests/exec.zig:11835`)

- **签名**：`fn load( userdata: ?*anyopaque, ctx: *core.JSContext, _: ?*std.Io.Writer, _: *core.Object, _: []const u8, _: []const u8, ) core.context.DynamicImportError!core.JSValue`。
- **作用**：测试夹具/探针 `LoaderProbe.load`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`userdata` 为空即 `return error.ModuleNotFound`；`ctx.runtime.internAtom("w1e-enqueue-realm-record")` 失败映射成 `error.OutOfMemory`。随后 `core.module.PendingDefinition.init(&ctx.runtime.memory, &ctx.runtime.atoms)` 建一个待定义模块（`defer pending.deinit(ctx.runtime)` 收尾），`ctx.modules.prepareFreshTarget(name, &pending)` 在**当前** realm 的注册表里插记录。最后记录三件事：`saw_expected_realm = ctx == self.expected`、`active_registry_has_record`（当前 realm 能 `find` 到）、`facade_registry_has_record`（facade realm 能否 find 到——期望为否），再返回 undefined。
- **所有权 / 错误 / 调用**：返回 `core.context.DynamicImportError!core.JSValue`，由测试 `try`/`expectError` 消费。

### `ActiveProbe.run` (`tests/exec.zig:18104`)

- **签名**：`fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool`。
- **作用**：测试夹具/探针 `ActiveProbe.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：中断回调形态的存活探针：`self.hits += 1`，记下 `saw_empty_queue = rt.job_queue.jobs.len == 0`（回调发生时 job 队列是否已空），再 `_ = rt.runObjectCycleRemoval()` 主动跑一遍环回收，并用 `self.reclaimed = !rt.ownsObject(self.canary)` 快照 canary 是否已被回收；返回 false 表示不真的中断执行。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.run` (`tests/exec.zig:18204`)

- **签名**：`fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool`。
- **作用**：测试夹具/探针 `Probe.run`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.calls += 1` 后立刻 `_ = rt.runObjectCycleRemoval()`，再用 `self.reclaimed_canary = !rt.ownsObject(self.canary)` **当场**快照 canary 是否被回收——源码注释特意说明：await 后续的分配可能复用这块地址，事后再查 `ownsObject(pointer)` 就证明不了身份。返回 false 不中断执行。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。无独立 error set 时失败以断言或 panic 终止测试。

### `retainedModuleExportCell` (`tests/exec.zig:19670`)

- **签名**：`fn retainedModuleExportCell( record: *const core.module.ModuleRecord, export_name: core.Atom, ) ?*core.VarRef`。
- **作用**：测试夹具/探针 `retainedModuleExportCell`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：遍历 `record.exports` 找 `entry.export_name` 等于给定原子的那一项，用其下标调 `record.retainedExportCellValue(@intCast(index))`；该值为空说明这个导出没有保留 cell，直接返回 `null`，否则 `core.VarRef.fromValue(value)` 转成 `*core.VarRef`。找不到同名导出也返回 `null`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PromiseResult.get` (`tests/exec.zig:19906`)

- **签名**：`fn get(value: core.JSValue) !core.JSValue`。
- **作用**：测试夹具/探针 `PromiseResult.get`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`property_ops.expectObject(value)` 断言是对象后：promise 若处于 rejected（`promise.promiseIsRejected()`）直接 `return error.TestUnexpectedResult`；否则取 `promise.promiseResult()`，为空同样落 `error.TestUnexpectedResult`。即「必须是已兑现的 promise，并把兑现值取出来」。
- **所有权 / 错误 / 调用**：返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `ArmableOneShotAllocator.allocator` (`tests/exec.zig:20011`)

- **签名**：`fn allocator(self: *@This()) std.mem.Allocator`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.allocator`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把自身包成 `std.mem.Allocator`：`.ptr = self`，vtable 指向同结构体的 `alloc`/`resize`/`remap`/`free` 四个函数。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.arm` (`tests/exec.zig:20018`)

- **签名**：`fn arm(self: *@This()) void`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.arm`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.armed = true` 并把 `self.induced` 清回 false——武装成「下一次 `alloc` 失败一次」。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.disarm` (`tests/exec.zig:20023`)

- **签名**：`fn disarm(self: *@This()) void`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.disarm`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：只把 `self.armed = false`；`induced` 保留，便于测试事后确认那一次失败确实被注入过。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.alloc` (`tests/exec.zig:20027`)

- **签名**：`fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.alloc`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：唯一注入点：`self.armed and !self.induced` 时置 `induced = true` 并返回 `null`（一次性 OOM），此后即使仍 armed 也照常转发 `self.backing.rawAlloc(len, alignment, ret_addr)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.resize` (`tests/exec.zig:20036`)

- **签名**：`fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.resize`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：不注入失败，原样转发 `self.backing.rawResize(memory, alignment, new_len, ret_addr)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.remap` (`tests/exec.zig:20041`)

- **签名**：`fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.remap`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：不注入失败，原样转发 `self.backing.rawRemap(memory, alignment, new_len, ret_addr)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ArmableOneShotAllocator.free` (`tests/exec.zig:20046`)

- **签名**：`fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void`。
- **作用**：测试夹具/探针 `ArmableOneShotAllocator.free`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：原样转发 `self.backing.rawFree(memory, alignment, ret_addr)`，不做记账。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `HostFixture.findBySpecifierOrPath` (`tests/exec.zig:20252`)

- **签名**：`fn findBySpecifierOrPath(self: HostFixture, specifier: []const u8) ?HostFixtureModule`。
- **作用**：测试夹具/探针 `HostFixture.findBySpecifierOrPath`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：线性扫 `self.modules`，只要 `std.mem.eql` 命中 `module.specifier` **或** `module.path` 之一就返回该 fixture 模块；扫完返回 `null`。解析阶段用它，所以规范化前后的名字都能命中。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `HostFixture.findByPath` (`tests/exec.zig:20259`)

- **签名**：`fn findByPath(self: HostFixture, path: []const u8) ?HostFixtureModule`。
- **作用**：测试夹具/探针 `HostFixture.findByPath`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：线性扫 `self.modules`，只按 `module.path` 用 `std.mem.eql` 精确匹配；加载阶段用它——此时 specifier 已被解析成唯一路径，只认路径。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectRejectedPromiseNamedError` (`tests/exec.zig:20267`)

- **签名**：`fn expectRejectedPromiseNamedError( js: *helpers.TestEngine, promise_value: core.JSValue, expected_name: []const u8, expected_message: []const u8, ) !void`。
- **作用**：测试夹具/探针 `expectRejectedPromiseNamedError`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`core.Object.expect(promise_value)` 后断言 `promise.promiseIsRejected()`，并 `core.promise.markHandled(js.context, promise)` 消掉未处理拒绝的告警；取 `promise.promiseResult()`（为空则 `error.TestUnexpectedResult`），再 `core.Object.expect` 拿到 reason 对象，`internAtom("name")`/`internAtom("message")` 读出两个属性，用 `helpers.expectStringValueBytes` 分别与 `expected_name`/`expected_message` 逐字节比对。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `hostHooks` (`tests/exec.zig:20286`)

- **签名**：`fn hostHooks(host: *const HostFixture) helpers.TestEngine.HostHooks`。
- **作用**：测试夹具/探针 `hostHooks`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 `*const HostFixture` 包成 `helpers.TestEngine.HostHooks`：`.ptr = @constCast(host)`（hooks 的回调签名要 `*anyopaque`，故去 const），`resolveModule`/`loadModule` 分别指向 `resolveFixtureModule`/`loadFixtureModule`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `resolveFixtureModule` (`tests/exec.zig:20294`)

- **签名**：`fn resolveFixtureModule( ptr: *anyopaque, specifier: []const u8, referrer: ?[]const u8, allocator: std.mem.Allocator, ) anyerror!helpers.TestEngine.HostHooks.ResolvedModule`。
- **作用**：测试夹具/探针 `resolveFixtureModule`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：忽略 `referrer`；从 `ptr` 还原 fixture，`host.resolve_calls` 非空则计一次调用，`host.findBySpecifierOrPath(specifier)` 找不到就 `return error.ModuleNotFound`。命中后用传入的 `allocator.dupe` 复制 specifier 与 path（所有权交给调用方），连同 `module.kind` 一起返回 `ResolvedModule`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `anyerror!helpers.TestEngine.HostHooks.ResolvedModule`，由测试 `try`/`expectError` 消费。

### `loadFixtureModule` (`tests/exec.zig:20311`)

- **签名**：`fn loadFixtureModule( ptr: *anyopaque, resolved: helpers.TestEngine.HostHooks.ResolvedModule, allocator: std.mem.Allocator, ) anyerror!helpers.TestEngine.HostHooks.LoadedModule`。
- **作用**：测试夹具/探针 `loadFixtureModule`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：从 `ptr` 还原 fixture，`host.load_calls` 非空则计一次调用，`host.findByPath(resolved.path)` 找不到就 `return error.ModuleNotFound`。返回的 `LoadedModule` 里 `source` 直接指向 fixture 里的静态源码且 `.owned = false`（调用方不得释放），只有 `path` 用 `allocator.dupe` 复制。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `anyerror!helpers.TestEngine.HostHooks.LoadedModule`，由测试 `try`/`expectError` 消费。

### `ReflectActiveRootSymbolProbe.trigger` (`tests/exec.zig:20370`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `ReflectActiveRootSymbolProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：挂在分配点上的 GC 触发器：进来先把 `self.rt.memory.trigger_gc_fn`/`trigger_gc_ctx` 存起来并清空（`defer` 原样还原），防止本次回收内部的分配再次递归触发自己。随后 `_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}`——按源码注释，分配点回收属于「引擎帧活着」的触发，必须用保守扫描（`.engine_active`）让原生手里正在构造的中间态存活，与生产 `pollGC(.normal)` 行为一致；错误直接吞掉。最后 `self.saw_symbol = self.rt.atoms.name(self.atom_id) != null` 记录那个 symbol 原子是否熬过这轮回收。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `reflectTestSetArrayIndex` (`tests/exec.zig:20390`)

- **签名**：`fn reflectTestSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void`。
- **作用**：测试夹具/探针 `reflectTestSetArrayIndex`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true))` 按数字原子写一个可写/可枚举/可配置的数据属性，然后手工维护长度：`array.arrayLength() <= index` 时 `array.setArrayLength(index + 1)`。绕开常规 set 路径直接铺数组内容。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!void`，由测试 `try`/`expectError` 消费。

### `ActiveInvocationRootProbe.call` (`tests/exec.zig:21975`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `ActiveInvocationRootProbe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：宿主函数里当场检查根扫描：先断言 `rt.active_invocation != null`，`inline_calls.activeInvocation(rt)` 取不到则 `error.TestUnexpectedResult`。用 `std.AutoHashMap(usize, void)`（`defer seen.deinit()`）当访问集合，把内嵌的 `Recorder` 包成 `core.runtime.RootVisitor` 后 `try rt.traceActiveRoots(&visitor)`，再 `assertLiveWindowsVisited(active, &seen, &live_local)` 逐窗口核对，`self.saw_live_local = live_local != null`。第二段是反向证明：取 `active.machine.currentLevel().stack` 的**未使用**容量 `backingValues()[stack.len()..]`，把 `unused[0]` 临时换成一个新建的 orphan 对象（`defer` 还原原值），清空 seen 重扫一遍；若 orphan 出现在 seen 里就置 `unused_capacity_leaked`。最后返回 `core.JSValue.boolean(self.saw_live_local and !self.unused_capacity_leaked)`。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `ActiveInvocationRootProbe.Recorder.visitValue` (`tests/exec.zig:21987`)

- **签名**：`fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `ActiveInvocationRootProbe.Recorder.visitValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：访问者的值回调：`slot.cycleMarkHeader()` 取不到（非 GC 值）就跳过；取到则做一次合法性体检——地址 `< 4096` 或未按 `@alignOf(core.gc.Header)` 对齐即视为坏指针，用 `return error.OutOfMemory` 报错（`RootTraceError` 里只有这一个可用错误）；正常则 `recorder.seen.put(addr, {})` 记入访问集合。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `ActiveInvocationRootProbe.Recorder.visitObject` (`tests/exec.zig:21996`)

- **签名**：`fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void`。
- **作用**：测试夹具/探针 `ActiveInvocationRootProbe.Recorder.visitObject`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：访问者的对象回调：`slot.*` 为空直接返回，否则把 `@intFromPtr(object.gcHeader())` 放进 `recorder.seen`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `core.runtime.RootTraceError!void`，由测试 `try`/`expectError` 消费。

### `assertLiveWindowsVisited` (`tests/exec.zig:22038`)

- **签名**：`fn assertLiveWindowsVisited( active: *inline_calls.ActiveInvocation, seen: *std.AutoHashMap(usize, void), live_local: *?*core.gc.Header, ) !void`。
- **作用**：测试夹具/探针 `assertLiveWindowsVisited`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：沿 `invocation.previous` 走完整条 active invocation 链，对每一条：先核对 L0 内联层（`machine.l0.level.frame` 与 `stack.liveValues()`），再沿 `machine.top` 的 `prev` 链逐个 Entry 核对 `&current_entry.frame` 与 `current_entry.stack.liveValues()`；仅当该 Entry 的 `teardown.has_native_caller` 或 `teardown.constructor_completion` 为真时，才额外要求 `native_caller` 也被访问过（否则那个槽本来就不是根）。核对动作转给 `expectFrameVisited`/`expectValueVisitedSlice`/`expectValueVisited`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectFrameVisited` (`tests/exec.zig:22060`)

- **签名**：`fn expectFrameVisited( frame: *frame_mod.Frame, seen: *std.AutoHashMap(usize, void), live_local: *?*core.gc.Header, ) !void`。
- **作用**：测试夹具/探针 `expectFrameVisited`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：逐槽核对一个帧的根覆盖：`this_value`、`current_function`、`args`、`locals` 全部必须在 seen 里；顺手在 `live_local.*` 还为空时，从 `frame.locals` 里挑第一个有 `cycleMarkHeader()` 的槽记下来，作为「确实存在一个活的堆本地」的证据。冷区 `frame.cold` 存在时，`new_target` 只在 `frame.ownership.new_target != .aliases_function`（即不是与 current_function 共用一个槽）时才单独要求访问，`cold.original_args` 整段要求访问。最后把 `frame.var_refs` 与 `frame.open_var_refs`（后者可空，空的跳过）各自 `cell.valueRef()` 取出的值也逐个核对。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectValueVisitedSlice` (`tests/exec.zig:22094`)

- **签名**：`fn expectValueVisitedSlice(values: []core.JSValue, seen: *std.AutoHashMap(usize, void)) !void`。
- **作用**：测试夹具/探针 `expectValueVisitedSlice`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：对切片里每个值调用 `expectValueVisited`，全部必须已被访问。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectValueVisited` (`tests/exec.zig:22098`)

- **签名**：`fn expectValueVisited(value: *core.JSValue, seen: *std.AutoHashMap(usize, void)) !void`。
- **作用**：测试夹具/探针 `expectValueVisited`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`value.cycleMarkHeader()` 为空（立即数/非 GC 值）就直接放行；否则 `try std.testing.expect(seen.contains(@intFromPtr(header)))`——该堆值必须出现在访问集合里。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `S3MajorAtEveryAllocationProbe.trigger` (`tests/exec.zig:22329`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：测试夹具/探针 `S3MajorAtEveryAllocationProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.active` 为假直接返回（未武装的阶段不回收）。武装时先存下 `rt.memory.trigger_gc_fn`/`trigger_gc_ctx` 并清空（`defer` 还原），防止回收内部的分配递归触发自己；记下 `self.rt.gc.block_heap.mark_epoch`，`_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}` 强制在这次分配点做一次带保守栈扫描的回收，回来后 mark_epoch 变了说明真跑了一轮 major，`self.majors += 1`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.trigger` (`tests/exec.zig:22473`)

- **签名**：`fn trigger(context: ?*anyopaque, _: usize) void`。
- **作用**：测试夹具/探针 `Probe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.armed` 为假直接返回；否则用 `self.armed = false` + `defer self.armed = true` 的自锁避免回收内部的分配重入本函数。`self.majors += 1` 后 `_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}` 强制一轮回收，再遍历 `self.ids` 数 `self.rt.atoms.cachedString(id) != null` 的个数 `cached`：一旦比历史峰值 `peak_cached` 小就置 `regressed`（说明缓存字符串在某轮之后又掉了），随后 `peak_cached = @max(peak_cached, cached)`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `PublishRootProbe.trigger` (`tests/exec.zig:22537`)

- **签名**：`fn trigger(context: ?*anyopaque, _: usize) void`。
- **作用**：测试夹具/探针 `PublishRootProbe.trigger`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：同样用 `armed = false` + `defer armed = true` 自锁防重入；`majors += 1` 后 `_ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}`。观测单个原子：`cachedString(self.id)` 还在就置 `seen = true`；若之前见过、这次不见了，则置 `regressed`——即结构体文档说的「先见到、后来又没了」才算回归。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `runUnderPublishProbe` (`tests/exec.zig:22556`)

- **签名**：`fn runUnderPublishProbe( rt: *core.JSRuntime, ctx: *core.JSContext, function: *const bytecode.Bytecode, probe: *PublishRootProbe, ) !core.JSValue`。
- **作用**：在「关掉保守原生栈兜底 + 每次分配都强制 major」的条件下运行 `function`，使得只有精确的操作数栈根才能让被测对象活下来；先在未武装状态热身一次，因为装宿主全局的过程本身不是可回收安全的、也与被测内容无关。
- **实现**：先 `helpers.registerStandardGlobalsBare(rt)`，再在**未武装**状态跑一段 `makeFunction(rt, &.{ op.push_i32, 1, 0, 0, 0, op.@"return" })` 的热身函数（`defer warmup.deinit(rt)`）并断言结果为 1。然后存下 `rt.memory.trigger_gc_fn`/`trigger_gc_ctx`，`rt.forcePreciseRootScanForTest()` 关掉保守栈扫描，把触发器换成 `PublishRootProbe.trigger` 并 `probe.armed = true`；`engine.exec.Vm.init(ctx)`（`defer vm.deinit()`）后 `helpers.runMutableVm(&vm, function)` 执行被测字节码。收尾按序解除：`probe.armed = false`、还原两个触发器字段、`rt.restoreDefaultRootScanForTest()`，最后返回 outcome。注意收尾不是 `defer`，出错路径由 `try` 直接冒泡（热身阶段的失败发生在改动 runtime 状态之前）。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime，或由 `endSharedTest` 复位。返回 `!core.JSValue`，由测试 `try`/`expectError` 消费。

### `Probe.call` (`tests/exec.zig:22942`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `Probe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：在宿主函数里观测 async 完成记录：`inline_calls.activeInvocation(rt)` 取不到即 `error.TestUnexpectedResult`；取 `active.machine.async_completions`，断言 `store.count != 0`，取最后一格 `store.at(store.count - 1)` 并断言 `slot.promise.is(.object)`。按 `slot.value.is(.undefined_value)` 分流计数：仍在运行记 `self.running`，已完成记 `self.completing`。随后记下 `rt.gc.stats.cycle_gc_count`，`try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only)` 跑一轮**只认声明根**（不保守扫原生栈）的回收，并断言计数确实涨了（这轮 major 真跑了），最后返回 undefined。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `Probe.call` (`tests/exec.zig:23011`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `Probe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.calls += 1` 后取 `inline_calls.activeInvocation(rt)`（取不到 → `error.TestUnexpectedResult`），断言 `active.machine.async_completions.count == 1`，且第 0 格的 `slot.value.is(.object)`——源码注释点明此时被调者帧已经弹出。接着 `core.Object.expect(slot.promise)` 取出 promise，用 `engine.exec.promise_ops.promiseReactionRecord` 造一条全 undefined 的反应记录并 `appendPromiseReaction` 挂上去。最后 `rt.suppressLimitCollectionForTest(true)` + `rt.setMemoryLimit(0)` 武装 OOM：注释说明 getter 帧拆除会把已记账字节还回来，所以上限取 0 才能保证紧随其后的结算分配仍然失败。返回 undefined。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `Probe.call` (`tests/exec.zig:23188`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `Probe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.calls += 1` 后先 `try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only)` 跑一轮只认声明根的回收，再 `rt.suppressLimitCollectionForTest(true)` + `rt.setMemoryLimit(0)` 武装后续分配必失败，返回 `core.JSValue.int32(42)` 当作 body 的结果值。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `Probe.call` (`tests/exec.zig:23238`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `Probe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.calls += 1` 后 `suppressLimitCollectionForTest(true)` + `setMemoryLimit(0)`：只武装 OOM，不触发回收，让下一次分配（保留反应阶段）失败；返回 undefined。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### `Probe.tail` (`tests/exec.zig:23245`)

- **签名**：`fn tail(_: *core.JSContext, _: []const core.JSValue) core.JSValue`。
- **作用**：测试夹具/探针 `Probe.tail`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：原生尾函数形态的空壳：忽略 ctx 与参数，直接返回 `core.JSValue.undefinedValue()`，只为给测试提供一个可注册的 tail 入口。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Probe.call` (`tests/exec.zig:23344`)

- **签名**：`fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue`。
- **作用**：测试夹具/探针 `Probe.call`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`self.calls += 1` 后 `suppressLimitCollectionForTest(true)` + `setMemoryLimit(0)` 武装 OOM，返回 undefined——被 await 恢复后的函数体调用，用来检验恢复体不会因分配失败而被重放。
- **所有权 / 错误 / 调用**：返回 `anyerror!core.JSValue`，由测试 `try`/`expectError` 消费。

### 测试块（576）

### `test "dense parameter arrays rest keeps contiguous storage and independent values"` (`tests/exec.zig:54`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays rest keeps contiguous storage and independent values」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function collect(first, ...rest) { return rest; } const marker = { value: 37 }; const a = collect(0, marker, undefined, 9); const b = collec`。约 4 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense parameter arrays spread keeps contiguous storage for array and custom iterator"` (`tests/exec.zig:78`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays spread keeps contiguous storage for array and custom iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense parameter arrays spread retains CreateDataProperty constraints"` (`tests/exec.zig:96`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays spread retains CreateDataProperty constraints」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.TypeError`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense parameter arrays spread reserves one backing cell for a known dense range"` (`tests/exec.zig:120`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays spread reserves one backing cell for a known dense range」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense parameter arrays spread reserve OOM preserves iterator progress and retries"` (`tests/exec.zig:136`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：dense parameter arrays spread reserve OOM preserves iterator progress and retries。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dense parameter arrays spread observes iterator methods getters and abrupt completion"` (`tests/exec.zig:160`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense parameter arrays spread observes iterator methods getters and abrupt completion」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let reads = 0, calls = 0; const it = { get next() {   reads++;   return function() {     assert.sameValue(this, it);     const value = ++cal`。约 0 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "eval lazily materializes a bare core context global before root closure construction"` (`tests/exec.zig:339`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：lazily materializes a bare core context global before root closure construction。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`'lazy-global-ok'`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object_slots2 literal allocation preserves data and accessor semantics"` (`tests/exec.zig:353`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object_slots2 literal allocation preserves data and accessor semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var stored = 0; var pair = { a: 3, b: 4 }; var accessor = {   get x() { return stored; },   set x(value) { stored = value; } }; accessor.x =`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fused cmp_if_false8 interrupt poll stays uncatchable in a for loop"` (`tests/exec.zig:371`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fused cmp_if_false8 interrupt poll stays uncatchable in a for loop」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__fuse_n = 0; globalThis.__fuse_spin = function () {     for (var i = 0; i < 1000000000; i++) {         __fuse_n = i;     }     r`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "interrupt budget survives Machine replacement and bypasses catch markers"` (`tests/exec.zig:415`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「interrupt budget survives Machine replacement and bypasses catch markers」。
- **实现**：部分配置下 `return error.SkipZigTest`。独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`try {     for (let i = 0; i < 1; i++) {}     globalThis.__w2_interrupt_state = 1; } catch (_) {     globalThis.__w2_interrupt_state = 2; } f`；`globalThis.__w2_interrupt_state = 0;`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "interrupt remains uncatchable when error construction runs out of memory"` (`tests/exec.zig:467`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「interrupt remains uncatchable when error construction runs out of memory」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.__w2_interrupt_oom_caught = false; globalThis.__w2_interrupt_oom = function (spin) {     try {         __w2ArmInterruptOom();    `。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "uncatchable interrupt skips outer inline for-of close and catch"` (`tests/exec.zig:559`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「uncatchable interrupt skips outer inline for-of close and catch」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__w2_iterator_closed = false; globalThis.__w2_outer_caught = false; globalThis.__w2_spin = function () { while (true) {} }; globa`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "synchronous native fence reuses one Machine and restores native cleanup order"` (`tests/exec.zig:625`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous native fence reuses one Machine and restores native cleanup order」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var fenceOrder = []; function fenceHelper(value) {     if (value < 0) throw new Error("negative");     return value + 1; } function catchesI`。约 12 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "synchronous native reentry crosses Entry chunk boundaries exactly"` (`tests/exec.zig:716`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous native reentry crosses Entry chunk boundaries exactly」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__nativeFenceDepth = function nativeFenceDepth(depth) {     if (depth === 0) return 0;     return __nativeFenceInvoke(__nativeFen`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "synchronous native fence restores every budget after interrupt"` (`tests/exec.zig:777`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous native fence restores every budget after interrupt」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__nativeFenceInterruptCaught = false; function nativeFenceInterruptCallback(spin) {     while (spin) {} } globalThis.__nativeFenc`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Function and Reflect apply opt into the active Machine explicitly"` (`tests/exec.zig:856`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Function and Reflect apply opt into the active Machine explicitly」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function nativeApplyHelper(value) {     return value + 1; } function nativeApplyCallback(value) {     return nativeApplyHelper(value); } fun`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "synchronous apply fallbacks restore the outer active invocation"` (`tests/exec.zig:906`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「synchronous apply fallbacks restore the outer active invocation」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var nativeApplyOther = $262.createRealm().global; var nativeApplyForeign = nativeApplyOther.eval(     "(function nativeApplyForeign(value) {`；`    "(function nativeApplyForeign(value) { return value + 1; })" ); function nativeApplyLocal(value) {     return value; } globalThis.__nati`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "ordinary spread calls enter eligible bytecode targets on the current Machine"` (`tests/exec.zig:950`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary spread calls enter eligible bytecode targets on the current Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var spreadOther = $262.createRealm().global; var spreadForeign = spreadOther.eval(     "(function spreadForeign(value) { return value + 18; `；`    "(function spreadForeign(value) { return value + 18; })" ); function spreadPlain(value) {     return value + 1; } var spreadReceiver = {`。约 5 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "publish-time simple-ctor gate keeps prototype-miss and non-simple fallbacks"` (`tests/exec.zig:1006`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「publish-time simple-ctor gate keeps prototype-miss and non-simple fallbacks」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function S(a) { this.a = a; } const before = new S(1); const before_proto_hit = Object.getPrototypeOf(before) === S.prototype; S.prototype =`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "constructor allocation profile reserves capacity without skipping the body"` (`tests/exec.zig:1034`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constructor allocation profile reserves capacity without skipping the body」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Vec(x, y, z) { this.x = x; this.y = y; this.z = z; } function Quad(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; } `。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "constructor return fusion and abrupt teardown each release the fallback exactly once"` (`tests/exec.zig:1078`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constructor return fusion and abrupt teardown each release the fallback exactly once」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Keep(v) { this.v = v; return 42; } function Override(v) { this.v = v; return { v: v + 1 }; } function Abrupt(v) { this.v = v; throw`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "constructor spread preserves new target on the current Machine"` (`tests/exec.zig:1116`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constructor spread preserves new target on the current Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let spreadConstructorNewTarget; function SpreadOrdinary(value) {     this.value = value;     this.trace = new Error("ordinary spread constru`；`    "(function SpreadConstructorForeign(value) {" +         "var adjusted = value + 1; this.value = adjusted - 1;" +     "})" ); globalThis.`。约 11 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Array and TypedArray synchronous callback cohort stays on one Machine"` (`tests/exec.zig:1236`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array and TypedArray synchronous callback cohort stays on one Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function arrayCohortHelper(value) {     return value + 1; } function arrayCohortCallback(value) {     if (value === 2) {         try {      `。约 6 个 Zig expect、30 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Map and Set synchronous callback cohort stays on one Machine"` (`tests/exec.zig:1353`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Map and Set synchronous callback cohort stays on one Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`function collectionCohortHelper(value) {     return value + 1; } function collectionCohortCallback(value) {     "use strict";     if (value `。约 19 个 Zig expect、26 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "accessors Proxy traps and primitive coercion stay on the active Machine"` (`tests/exec.zig:1552`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「accessors Proxy traps and primitive coercion stay on the active Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`function propertyCohortHelper(value) {     return value + 1; } var propertyCohortStorage = 0; var propertyCohortTrace; var propertyCohortOrd`；`    "Object.defineProperty({}, 'value', {" +     "get: function propertyForeignGetter() { return 20; }})" ); var propertyLocalObject = Objec`。约 24 个 Zig expect、35 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "JSON synchronous callback cohort stays on one Machine"` (`tests/exec.zig:1894`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「JSON synchronous callback cohort stays on one Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`function jsonCohortHelper(value) {     return value + 1; } var jsonCohortTrace; var jsonCohortOrder = []; globalThis.__jsonCallbackCohortOut`；`    "(function jsonForeignReviver(key, value) { return value; })" ); globalThis.__jsonCallbackForeignOuter = function () {     return JSON.p`。约 24 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "string regexp iterator helpers and DisposableStack stay on one Machine"` (`tests/exec.zig:2092`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「string regexp iterator helpers and DisposableStack stay on one Machine」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`function cohortFiveHelper(value) {     return value + 1; } function cohortFiveIterator(values, closeOrder) {     var index = 0;     var iter`；`    "(function cohortFiveForeignReplacer() { return 'a'; })" ); globalThis.__cohortFiveForeignOuter = function () {     return "x".replace("`。约 22 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise executor reuses the active Machine while reactions remain roots"` (`tests/exec.zig:2348`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise executor reuses the active Machine while reactions remain roots」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function promiseExecutorHelper(value) {     return value + 1; } function promiseExecutorResolveHelper(resolve, value) {     return resolve(p`；`    "(function promiseExecutorForeign(resolve) { resolve(20); })" ); globalThis.__promiseExecutorForeignOuter = function () {     new Promis`。约 32 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "nested calls and generator resumes share one Realm interrupt cadence"` (`tests/exec.zig:2595`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested calls and generator resumes share one Realm interrupt cadence」。
- **实现**：部分配置下 `return error.SkipZigTest`。独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__w2_inner = function () { return 7; }; globalThis.__w2_outer = function () { return __w2_inner(); }; globalThis.__w2_numeric_bra`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "initial async resume rejects with the caller-Realm interrupt exception"` (`tests/exec.zig:2757`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「initial async resume rejects with the caller-Realm interrupt exception」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__w2_async_interrupt = async function () { return 17; };`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "cross-Realm interrupt polls charge caller entry and callee body separately"` (`tests/exec.zig:2831`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cross-Realm interrupt polls charge caller entry and callee body separately」。
- **实现**：部分配置下 `return error.SkipZigTest`。独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__w2_body_ran = false; globalThis.__w2_foreign = function () {     globalThis.__w2_body_ran = true;     while (true) {} }; global`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "tail-frame reuse charges planned stack bytes and fully restores both budgets"` (`tests/exec.zig:2971`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「tail-frame reuse charges planned stack bytes and fully restores both budgets」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__w2SmallLinks = 0; globalThis.__w2LargeLinks = 0; function __w2Small(eval) {     __w2SmallLinks++;     return eval(eval); } func`；`try { __w2Small(__w2Small); } catch (e) { print("small-1:" + e.name + ":" + e.message); } const firstSmallLinks = __w2SmallLinks; __w2SmallL`。约 8 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "raw tail call opcodes share the bounded tail-chain stack contract"` (`tests/exec.zig:3033`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：手写 `current_function`+`call` / `tail_call_method` 在 128KiB 栈上溢出后恢复三条预算计数。
- **实现**：独立 `helpers.TestEngine.init`，`setNativeStackSize(128 * 1024)`，`createTailOpcodeFixture` 装两条 raw 函数。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "tail target setup OOM remains catchable in the retiring caller"` (`tests/exec.zig:3070`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：tail target setup OOM remains catchable in the retiring caller。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.__w2TailSetupBodyRuns = 0; globalThis.__w2TailSetupOomName = "InternalError"; globalThis.__w2TailSetupOomMessage = "out of memory`。约 32 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "js_function_set_properties publishes configurable length then name"` (`tests/exec.zig:3407`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「js_function_set_properties publishes configurable length then name」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function namedPair(a, b) { return a; } var dlen = Object.getOwnPropertyDescriptor(namedPair, "length"); var dname = Object.getOwnPropertyDes`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "get_var_ref reuses the open cell on a second capture of the same local"` (`tests/exec.zig:3428`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「get_var_ref reuses the open cell on a second capture of the same local」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "js_closure2 attach roots captures through the function object"` (`tests/exec.zig:3460`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「js_closure2 attach roots captures through the function object」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。把 GC 阈值压到 0（`defer` 还原旧阈值）后跑一次 `runObjectCycleRemoval`，再重新调用闭包并断言结果仍是 33。脚本/输入：`function __r11_make(n) {   var a = n, b = n + 1, c = n + 2;   function inner() {     function deeper() { return a + b + c; }     return deep`；`globalThis.__r11_out = globalThis.__r11_fn()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "var-ref growth promotes borrowed captures to owned cells"` (`tests/exec.zig:3490`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「var-ref growth promotes borrowed captures to owned cells」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "global declaration construction rebinds duplicate carriers one slot at a time"` (`tests/exec.zig:3515`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「global declaration construction rebinds duplicate carriers one slot at a time」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary global closure selector preserves QuickJS cell waterfall and owner metadata"` (`tests/exec.zig:3572`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary global closure selector preserves QuickJS cell waterfall and owner metadata」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__selectorAccessorReads = 0; Object.defineProperty(globalThis, "__selectorAccessor", {     configurable: true,     get: function `；`assert.sameValue(__selectorAccessorReads, 0);`。约 11 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "hidden uninitialized globals compact at the QuickJS sawtooth bound"` (`tests/exec.zig:3645`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「hidden uninitialized globals compact at the QuickJS sawtooth bound」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "W1 two own layouts keep the VM property site active"` (`tests/exec.zig:3700`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1 two own layouts keep the VM property site active」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function readTwo(o) { return o.field; } var a = { field: 3, x: 1 }; var b = { y: 2, field: 5 }; var total = 0; for (var i = 0; i < 64; i++) `；`var getterCalls = 0; Object.defineProperty(b, "field", { get: function () { getterCalls++; return 7; }, configurable: true }); assert.sameVa`。约 11 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "W1 property sites stay correct across every shape mutation that invalidates them"` (`tests/exec.zig:3757`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1 property sites stay correct across every shape mutation that invalidates them」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`// --- own arm: delete must be observed (markPropertyDeleted) --- function readA(o) { return o.a; } var own = { a: 1, b: 2 }; for (var i = 0`。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "W1 native-getter sites re-resolve the accessor out of the guarded slot"` (`tests/exec.zig:3857`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1 native-getter sites re-resolve the accessor out of the guarded slot」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function readFlags(r) { return r.flags; } var re = /ab/gi; for (var i = 0; i < 200; i++) readFlags(re); assert.sameValue(readFlags(re), "gi"`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "runtime-strict script still constructs its global function declaration"` (`tests/exec.zig:3890`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime-strict script still constructs its global function declaration」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "var-ref growth rejects an owned composite frame slab"` (`tests/exec.zig:3905`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「var-ref growth rejects an owned composite frame slab」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBytecode`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "local growth rejects an owned composite frame slab"` (`tests/exec.zig:3932`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「local growth rejects an owned composite frame slab」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBytecode`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arg aliases reject missing open-ref storage without cellifying the slot"` (`tests/exec.zig:3957`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arg aliases reject missing open-ref storage without cellifying the slot」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "local growth rejects moving storage after an open binding is published"` (`tests/exec.zig:4020`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「local growth rejects moving storage after an open binding is published」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidBytecode`。设置 runtime 内存上限以注入 OOM。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "call-binding OOM leaves input references with the caller"` (`tests/exec.zig:4050`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：call-binding OOM leaves input references with the caller。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "original-args cold-state OOM does not retain copied references"` (`tests/exec.zig:4079`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：original-args cold-state OOM does not retain copied references。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "strict generator resident frame supports qjs argument counts beyond u16 storage"` (`tests/exec.zig:4111`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict generator resident frame supports qjs argument counts beyond u16 storage」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function* manyArgs() {     "use strict";     return arguments.length; } assert.sameValue(manyArgs.apply(null, Array(40000)).next().value, 40`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "a dynamic function outlives its teardown when its object held the last bytecode reference"` (`tests/exec.zig:4130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「a dynamic function outlives its teardown when its object held the last bytecode reference」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let total = 0; for (let i = 0; i < 8; i += 1) {     total += Function("var a = 2; var g = function () { return a; }; return g();")(); } prin`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "string leftover ToIntegerOrInfinity matches value_ops including bigint TypeError"` (`tests/exec.zig:4152`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「string leftover ToIntegerOrInfinity matches value_ops including bigint TypeError」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`print("ab".repeat(2)); print("hello".slice(1.9, 4)); print("hello".indexOf("l", true)); try { "ab".repeat(1n); print("no throw"); } catch (e`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "vm executes push constants arithmetic comparisons and return"` (`tests/exec.zig:4168`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「vm executes push constants arithmetic comparisons and return」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Engine executes both paths of a threaded with atom-label destructuring probe"` (`tests/exec.zig:4186`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine executes both paths of a threaded with atom-label destructuring probe」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function withThread(obj, y) {   with (obj) { [x] = y; }   return obj.x; } var threadedTotal = withThread({ x: 0, y: [4] }, [9]) * 10 +   wit`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "signed bigint-i32 neg preserves inline and generic BigInt semantics"` (`tests/exec.zig:4203`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「signed bigint-i32 neg preserves inline and generic BigInt semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(-(0n), 0n); assert.sameValue(-1n, -1n); assert.sameValue(-(1n), -1n); assert.sameValue(-(2147483647n), -2147483647n); asser`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "heap bigint multiplication still compacts a short-representable product"` (`tests/exec.zig:4221`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「heap bigint multiplication still compacts a short-representable product」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(3000000000n * 3000000000n, 9000000000000000000n); assert.sameValue(String(3000000000n * 3000000000n), "9000000000000000000"`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "numeric discarded immediates preserve comma control and completion semantics"` (`tests/exec.zig:4250`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「numeric discarded immediates preserve comma control and completion semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function numericDiscardTail() { (1); } function numericDiscardComma(value) { return (1, value); } function numericDiscardControl(flag) { if `；`-2147483648`。约 3 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "vm executes stack constants source locations and return_undef"` (`tests/exec.zig:4284`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「vm executes stack constants source locations and return_undef」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "frame setLocal handles self-assignment without dropping object"` (`tests/exec.zig:4300`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「frame setLocal handles self-assignment without dropping object」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "lookupFrameVarRef tolerates synthetic var-ref name mirrors"` (`tests/exec.zig:4320`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「lookupFrameVarRef tolerates synthetic var-ref name mirrors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "derived constructor without nested this references has no owner cell"` (`tests/exec.zig:4346`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「derived constructor without nested this references has no owner cell」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__derivedNoCapture = class DerivedNoCapture extends Object {   constructor() { super(); } }; new globalThis.__derivedNoCapture();`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "derived constructor arrow creates exactly one owner this cell"` (`tests/exec.zig:4365`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「derived constructor arrow creates exactly one owner this cell」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__derivedArrowCapture = class DerivedArrowCapture extends Object {   constructor() { const read = () => this; super(); if (read()`。Zig 侧无 expect，全部断言压在一句 `try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedArrowCapture"))` 上：取回构造器字节码，验证 this 本地恰好被一个子闭包按 `.local` 捕获、`openVarRefCount() == 1`、无 `close_loc`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "derived constructor parameter default arrow captures this by binding identity"` (`tests/exec.zig:4379`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「derived constructor parameter default arrow captures this by binding identity」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__derivedParameterArrow = class DerivedParameterArrow extends Object {   constructor({ read = () => this } = {}) { super(); if (read`。箭头函数写在**参数默认值**里而非函数体里，JS 侧 `read() !== this` 即 `throw`；Zig 侧同样只有一句 `try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedParameterArrow"))`，要求捕获仍然只产生一个 owner cell。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "direct eval captures derived this while indirect eval does not"` (`tests/exec.zig:4393`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：direct eval captures derived this while indirect eval does not。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__derivedDirectEval = class DerivedDirectEval extends Object {   constructor() { super(); if (eval("this") !== this) throw new Er`；`this`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "class entry and construction use bytecode gates without a class behavior flag"` (`tests/exec.zig:4442`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class entry and construction use bytecode gates without a class behavior flag」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let ordinaryNewTarget = null; function Ordinary(value) {   ordinaryNewTarget = new.target;   this.value = value;   return 7; } const receive`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "ordinary constructor Machine completion preserves bindings eval recursion and abrupt teardown"` (`tests/exec.zig:4509`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary constructor Machine completion preserves bindings eval recursion and abrupt teardown」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let observed; let evalThis; let evalNewTarget; function Ordinary(value, mode) {   const arrow = () => [this, new.target, arguments[0]];   ob`；`evalThis = this; evalNewTarget = new.target`。约 4 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "derived constructor Machine completion preserves inherited new target and teardown"` (`tests/exec.zig:4572`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「derived constructor Machine completion preserves inherited new target and teardown」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let baseNewTarget; function OrdinaryBase(value) { this.value = value; } class Base {   constructor(value, mode) {     baseNewTarget = new.ta`。约 4 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Reflect.construct keeps a fresh prototype getter result alive through instance allocation"` (`tests/exec.zig:4654`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Reflect.construct keeps a fresh prototype getter result alive through instance allocation」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let prototypeGets = 0; let receiverIsNewTarget = true; function Target() {} let NewTarget; NewTarget = new Proxy(function () {}, {   get(tar`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Proxy wrapping a class named Array never enters the native Array construct record"` (`tests/exec.zig:4683`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Proxy wrapping a class named Array never enters the native Array construct record。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let caught; try {   new (new Proxy(class Array {     constructor() { throw 1; }   }, {}))(); } catch (error) {   caught = error; } assert.sa`。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Proxy native constructor forwarding resolves new target prototype before coercion"` (`tests/exec.zig:4711`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Proxy native constructor forwarding resolves new target prototype before coercion」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let order = 0; let prototypeGets = 0; let forwardedPrototype; const ErrorProxy = new Proxy(Error, {   get(target, key, receiver) {     asser`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "default derived constructor follows the live constructor prototype"` (`tests/exec.zig:4744`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「default derived constructor follows the live constructor prototype」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let oldBaseCalls = 0; let seenNewTarget; class OldBase {   constructor() {     oldBaseCalls++;     this.kind = "old";   } } class NewBase { `。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "class constructor opcode errors preserve QuickJS messages and realms"` (`tests/exec.zig:4780`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class constructor opcode errors preserve QuickJS messages and realms」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const other = $262.createRealm().global; other.eval("globalThis.ForeignBase = class ForeignBase {}; globalThis.ForeignDerived = class Foreig`；`globalThis.ForeignBase = class ForeignBase {}; globalThis.ForeignDerived = class ForeignDerived extends ForeignBase {}; globalThis.ForeignBa`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "direct spread and arrow super follow the live derived constructor prototype"` (`tests/exec.zig:4817`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct spread and arrow super follow the live derived constructor prototype」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let directNewTarget; let spreadNewTarget; let arrowDirectNewTarget; let arrowSpreadNewTarget; class OldBase {} class NewBase {   constructor`。约 0 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "super call paths reject null live parents and do not authorize ordinary class calls"` (`tests/exec.zig:4866`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「super call paths reject null live parents and do not authorize ordinary class calls」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function capture(thunk) {   try { thunk(); } catch (error) { return error; }   throw new Error("expected constructor error"); } function exp`。约 0 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "bound function call skips zero-length combined args allocation"` (`tests/exec.zig:4984`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bound function call skips zero-length combined args allocation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constant pool execution retains returned constants"` (`tests/exec.zig:5004`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constant pool execution retains returned constants」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "property ops use shared object semantics"` (`tests/exec.zig:5022`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「property ops use shared object semantics」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "value ops own primitive VM semantics"` (`tests/exec.zig:5047`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「value ops own primitive VM semantics」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.TypeError`。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "closure helper stores closure state outside the VM"` (`tests/exec.zig:5115`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「closure helper stores closure state outside the VM」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "resident set_var_ref preserves assignment results and refcounted self-assignment"` (`tests/exec.zig:5146`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident set_var_ref preserves assignment results and refcounted self-assignment」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function __buildResidentSetVarRefProbes() {   var shortTarget = 0;   globalThis.__residentSetVarRefShort = function (next) {     return shor`。约 7 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "resident stack permutations preserve assignment values and ownership"` (`tests/exec.zig:5211`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident stack permutations preserve assignment values and ownership」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__residentInsert2 = function (object, value) {   return object.field = value; }; globalThis.__residentInsert3 = function (object,`。约 4 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "mapped arguments named field skips binding alias; computed index stays aliased"` (`tests/exec.zig:5260`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments named field skips binding alias; computed index stays aliased」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function f(a) {   assert.sameValue(arguments[0], 7);   assert.sameValue(arguments.foo, undefined);   arguments.foo = 1;   assert.sameValue(a`。约 0 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "mapped arguments rest-style 0-formal length and index (sc_list)"` (`tests/exec.zig:5280`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments rest-style 0-formal length and index (sc_list)」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function sc_list() {   var a = arguments;   assert.sameValue(a.length, 2);   assert.sameValue(a[0], "x");   assert.sameValue(a[1], 9);   a[0`。约 0 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "typed array integer get uses class-id arm and qjs tag shape"` (`tests/exec.zig:5312`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array integer get uses class-id arm and qjs tag shape」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const u8 = new Uint8Array([255, 1]); assert.sameValue(u8[0], 255); assert.sameValue(u8[1], 1); assert.sameValue(u8[2], undefined); assert.sa`。约 0 个 Zig expect、13 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "typed array prototype chain get reads canonical numeric indices"` (`tests/exec.zig:5345`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array prototype chain get reads canonical numeric indices」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const ta = new Uint8Array([7, 8]); const o = Object.create(ta); assert.sameValue(o[0], 7); assert.sameValue(o["0"], 7); assert.sameValue(o[1`。约 0 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "typed array integer put uses class-id arm"` (`tests/exec.zig:5368`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array integer put uses class-id arm」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const u8 = new Uint8Array(3); assert.sameValue(u8[0] = 255, 255); assert.sameValue(u8[0], 255); assert.sameValue(u8[1] = -1, -1); assert.sam`。约 0 个 Zig expect、16 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "typed array int32 store fast arm preserves conversion and assignment semantics"` (`tests/exec.zig:5400`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array int32 store fast arm preserves conversion and assignment semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__typedIntStore = function (array, index, value) {   return array[index] = value; }; const i8 = new Int8Array(1); assert.sameValu`。约 2 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "checked local replacement preserves int fast moves and refcounted fallbacks"` (`tests/exec.zig:5448`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「checked local replacement preserves int fast moves and refcounted fallbacks」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an expression helper emits an explicit return after a bytecode call"` (`tests/exec.zig:5467`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an expression helper emits an explicit return after a bytecode call」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "top-level function declarations use wide closure operands past 255 constants"` (`tests/exec.zig:5731`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「top-level function declarations use wide closure operands past 255 constants」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function expressions execute wide closure operands past 255 constants"` (`tests/exec.zig:5750`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function expressions execute wide closure operands past 255 constants」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "call subsystem installs and invokes host globals"` (`tests/exec.zig:5778`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「call subsystem installs and invokes host globals」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.JSException`。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "native builtin record dispatch is independent from dispatch-name strings"` (`tests/exec.zig:5863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：builtin record dispatch is independent from dispatch-name strings。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode calls execute directly from the shared function bytecode"` (`tests/exec.zig:5924`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode calls execute directly from the shared function bytecode」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function directFunctionBytecode(value) {     return value + 1; } undefined;`；`assert.sameValue(directFunctionBytecode(3), 4); Promise.resolve(4)     .then(function(value) {         var holder = { method: directFunction`。约 6 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Math cproto dispatch preserves observable ToNumber semantics"` (`tests/exec.zig:5985`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Math cproto dispatch preserves observable ToNumber semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var log = ""; var lhs = { valueOf() { log += "l"; return -3; } }; var rhs = { valueOf() { log += "r"; return 4; } }; print(Math.abs(lhs)); p`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "local add_loc retains string snapshots after accumulator tail removal"` (`tests/exec.zig:6005`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「local add_loc retains string snapshots after accumulator tail removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function build() {   var text = "";   for (var i = 0; i < 4096; i++) text += "ab";   return text; } function verifySnapshot() {   var text =`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "add_loc string+object goes through slow add after toPrimitive (qjs OP_add_loc)"` (`tests/exec.zig:6059`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「add_loc string+object goes through slow add after toPrimitive (qjs OP_add_loc)」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function f(){   var s = "abc";   var stash = null;   s = s + "d";   var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };  `。测试头注释给出对照：qjs:19766-19767 要求两个操作数都已是 `JS_TAG_STRING` 才做就地拼接，对象 RHS 必须走 `js_add_slow`，否则 `toString` 里重新赋值累加器会改到一条陈旧的 rope。期望输出九行，核心是每种写法（`+`、`+=`、`valueOf`、`Symbol.toPrimitive`、长串等）都得到 `s=abcdQ stash=abcd` 这类结果，其中 `s_len=9002 s_is_ZZZ=false stash_len=9001` 一行专钉长字符串路径。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部就是 `sharedTestEngine()` + `defer endSharedTest()`（`src/tests/helpers.zig:126-136`），所以本例同样跑在进程级共享 Runtime 上：`endSharedTest`（helpers.zig:615）经 `resetSharedEngineAfterTest`（669-694）清异常与未处理 rejection、排空 job 队列、还原全局 lexical 与 shape；泄漏门只在 `current_pass != 0`（census 第二遍）开火。失败以 `error.Test*` 冒泡。

### `test "checked lexical string accumulation keeps rope depth bounded"` (`tests/exec.zig:6159`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「checked lexical string accumulation keeps rope depth bounded」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function build() {   let text = "";   let snapshot;   for (var i = 0; i < 8192; i++) {     if (i === 4096) snapshot = text;     text += "ab"`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "computed reads with cached string atoms preserve exotic and prototype semantics"` (`tests/exec.zig:6197`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed reads with cached string atoms preserve exotic and prototype semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const proto = { get hot() { return 7; } }; const object = Object.create(proto); assert.sameValue(object["hot"], 7); let trapCalls = 0; const`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "native dispatch metadata is internal and ignores user properties"` (`tests/exec.zig:6245`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：dispatch metadata is internal and ignores user properties。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var f = Object.prototype.isPrototypeOf; print("__zjs_native_name" in f); print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === u`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "scope resolver skips popped lexical shadow for destructured parameter"` (`tests/exec.zig:6271`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「scope resolver skips popped lexical shadow for destructured parameter」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function f({ comment, items }) {   { let comment = null; }   for (let i = 0; i < items.length; ++i) {     let comment = "inner";   }   retur`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "__zjs-prefixed user properties are ordinary own properties"` (`tests/exec.zig:6289`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「__zjs-prefixed user properties are ordinary own properties」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var o = {}; o.__zjs_user = 1; Object.defineProperty(o, "__zjs_non_enum", { value: 2, enumerable: false, configurable: true }); print(Object.`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "array species fast path markers are internal"` (`tests/exec.zig:6311`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array species fast path markers are internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get; print("__zjs_array_constructor" in Array); print(Object.getOwnPrope`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "auto-init builtin markers are internal and ignore user properties"` (`tests/exec.zig:6337`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「auto-init builtin markers are internal and ignore user properties」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function check(fn, marker, run) {   print(marker in fn);   print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);   fn[marker] = `。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "immutable prototype marker is internal"` (`tests/exec.zig:6451`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「immutable prototype marker is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`print("__zjs_immutable_prototype" in Object.prototype); print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype")`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "builtin dispatch function markers are internal"` (`tests/exec.zig:6471`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「builtin dispatch function markers are internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function check(fn, marker, run) {   print(marker in fn);   print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);   fn[marker] = `。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "proxy revocation target is internal"` (`tests/exec.zig:6512`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「proxy revocation target is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var r = Proxy.revocable({ x: 1 }, {}); var revoke = r.revoke; print("__zjs_revoke_proxy" in revoke); print(Object.getOwnPropertyDescriptor(r`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "regexp accessor realm TypeError constructor is internal"` (`tests/exec.zig:6553`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp accessor realm TypeError constructor is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get; print("__zjs_realm_TypeError" in getter); print(Object.getOwnP`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "throw type error intrinsic marker is internal"` (`tests/exec.zig:6587`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「throw type error intrinsic marker is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`"use strict"; print("__zjs_throw_type_error_intrinsic" in globalThis); print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_e`；`globalThis.__thrower_probe = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "async generator prototype method marker is internal"` (`tests/exec.zig:6639`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async generator prototype method marker is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function* g() {} var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype); var next = AsyncGeneratorPrototype.next; print("__z`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator instances inherit shared prototype methods"` (`tests/exec.zig:6661`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator instances inherit shared prototype methods」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* syncGenerator() { yield 1; } var syncA = syncGenerator(); var syncB = syncGenerator(); var GeneratorPrototype = Object.getPrototyp`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator object uses the prototype selected after parameter initialization"` (`tests/exec.zig:6759`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator object uses the prototype selected after parameter initialization」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var GeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype); var syncPrototype = Object.create(GeneratorPrototype); function* `。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "closure-env var_ref hitting rc zero during remove_cycles stays a batch no-op"` (`tests/exec.zig:6776`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「closure-env var_ref hitting rc zero during remove_cycles stays a batch no-op」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "parked generator open cell death path reclaims cell and generator together"` (`tests/exec.zig:6814`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parked generator open cell death path reclaims cell and generator together」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "cycle drain frees leftover-rc rings under repeated forceGC"` (`tests/exec.zig:6859`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cycle drain frees leftover-rc rings under repeated forceGC」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "major tracing keeps a heap BigInt reachable through an object"` (`tests/exec.zig:6894`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「major tracing keeps a heap BigInt reachable through an object」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var live = { x: 0x10000000000000000n }; $262.gc(); assert.sameValue(live.x === 0x10000000000000000n, true);`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator continuation keeps its FunctionBytecode alive after every source binding is dropped"` (`tests/exec.zig:6905`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator continuation keeps its FunctionBytecode alive after every source binding is dropped」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* escapeAuditGen() { var a = 10; yield a; yield a + 1; } async function escapeAuditAsync(x) { return (await x) + 5; } var it = escap`；`assert.sameValue(escapeAuditAsyncResult, 105);`。约 2 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "initial_yield keeps sync generators in suspended-start after parameter initialization"` (`tests/exec.zig:6935`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「initial_yield keeps sync generators in suspended-start after parameter initialization」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const initialYieldEvents = []; function* initialYieldGenerator(   factory = (initialYieldEvents.push("param"), function* () { yield 1; }) ) `。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "initial_yield keeps async generators in suspended-start"` (`tests/exec.zig:6968`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「initial_yield keeps async generators in suspended-start」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const asyncInitialYieldEvents = []; async function* asyncInitialYieldGenerator(   value = (asyncInitialYieldEvents.push("param"), 3) ) {   a`。参数默认值里 push "param"、函数体里 push "body"，靠事件序列区分「创建时只跑参数、body 要等第一次 next」。期望输出四行：`create param` / `next 3 false param,body` / `return 9 true param,body,param` / `throw 11 param,body,param,param`——即 `return`/`throw` 进入的是**新**实例的 suspended-start 状态，只补跑参数不跑 body。
- **所有权 / 错误 / 调用**：`helpers.expectPrints` 内部就是 `sharedTestEngine()` + `defer endSharedTest()`（`src/tests/helpers.zig:126-136`），所以本例同样跑在进程级共享 Runtime 上：`endSharedTest`（helpers.zig:615）经 `resetSharedEngineAfterTest`（669-694）清异常与未处理 rejection、排空 job 队列、还原全局 lexical 与 shape；泄漏门只在 `current_pass != 0`（census 第二遍）开火。失败以 `error.Test*` 冒泡。

### `test "initial_yield executes exported generator bytecode in module mode"` (`tests/exec.zig:6998`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「initial_yield executes exported generator bytecode in module mode」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const moduleInitialYieldEvents = []; export function* moduleInitialYieldGenerator(   value = (moduleInitialYieldEvents.push("param"), 4) ) {`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "generator completion resumes keep the original function home object"` (`tests/exec.zig:7021`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator completion resumes keep the original function home object」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`class Base {   get marker() { return 41; } } class Derived extends Base {   *viaReturn() {     try { yield 0; }     finally { yield super.ma`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "resident generator resumes preserve nested catch and finally targets"` (`tests/exec.zig:7068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident generator resumes preserve nested catch and finally targets」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function* afterNested() {   try {     yield 1;     try { yield 2; throw 3; } catch (error) { yield error; }     yield 4;   } finally { yield`。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "surviving var references keep resident local slots bare"` (`tests/exec.zig:7134`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「surviving var references keep resident local slots bare」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* referenceStorage(scope) {   var target;   with (scope) { target = 41; }   yield target;   target += 1;   return target; } globalTh`；`const step = __referenceStorage.next(); assert.sameValue(step.value, 42); assert.sameValue(step.done, true);`。约 7 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "direct eval captures only bindings visible at its call scope"` (`tests/exec.zig:7179`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval captures only bindings visible at its call scope」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* scopedEvalStorage() {   { let sibling = 10; globalThis.__siblingValue = sibling; }   var visible = 1;   { let active = 2; eval("vi`；`visible = active`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "suspended generators retain one resident execution owner across resumes"` (`tests/exec.zig:7210`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「suspended generators retain one resident execution owner across resumes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* residentGenerator(argument) {   let local = { local: true };   try {     yield local;     yield argument;   } catch (error) {     `；`let finalStep = __residentGenerator.next(); assert.sameValue(finalStep.value, undefined); assert.sameValue(finalStep.done, true);`。约 15 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "completed generators eagerly release their resident execution state"` (`tests/exec.zig:7265`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「completed generators eagerly release their resident execution state」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function make(captured) {   return function* generator(argument) { yield captured; return argument; }; } const generator = make({ captured: `。约 8 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "iterator helper method marker is internal"` (`tests/exec.zig:7317`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「iterator helper method marker is internal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function printLayout(label, helper) {   var proto = Object.getPrototypeOf(helper);   print(label);   print(Object.prototype.toString.call(he`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Iterator.from follows QuickJS wrapper selection"` (`tests/exec.zig:7365`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Iterator.from follows QuickJS wrapper selection」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var count = 0; var iterable = {   [Symbol.iterator]: function() { return this; },   get next() {     count++;     return function() { return`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "number native builtin records cover static and prototype dispatch"` (`tests/exec.zig:7431`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「number native builtin records cover static and prototype dispatch」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "string static native builtin records ignore dispatch names"` (`tests/exec.zig:7551`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「string static native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "string prototype native builtin records ignore dispatch names"` (`tests/exec.zig:7594`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「string prototype native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "String case conversion records preserve coercion and Unicode semantics"` (`tests/exec.zig:7640`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String case conversion records preserve coercion and Unicode semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var hints = []; var receiver = {}; receiver[Symbol.toPrimitive] = function(hint) {     hints.push(hint);     return "aßΣ"; }; assert.sameVal`。约 2 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "date static native builtin records ignore dispatch names"` (`tests/exec.zig:7676`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「date static native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "date constructor native builtin records ignore dispatch names"` (`tests/exec.zig:7718`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「date constructor native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "constructValue AggregateError releases copied errors array owner"` (`tests/exec.zig:7774`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「constructValue AggregateError releases copied errors array owner」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "date prototype native builtin records ignore dispatch names"` (`tests/exec.zig:7813`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「date prototype native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array static native builtin records ignore dispatch names"` (`tests/exec.zig:7858`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array static native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "array prototype native builtin records ignore dispatch names"` (`tests/exec.zig:7919`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array prototype native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "collection native builtin records ignore dispatch names"` (`tests/exec.zig:7999`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「collection native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "buffer native builtin records ignore dispatch names"` (`tests/exec.zig:8092`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「buffer native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "typed array accessor native builtin records ignore dispatch names"` (`tests/exec.zig:8217`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「typed array accessor native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp static native builtin records ignore dispatch names"` (`tests/exec.zig:8291`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp static native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp prototype native builtin records ignore dispatch names"` (`tests/exec.zig:8336`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp prototype native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp symbol native builtin records ignore dispatch names"` (`tests/exec.zig:8426`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp symbol native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "regexp accessor native builtin records ignore dispatch names"` (`tests/exec.zig:8538`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp accessor native builtin records ignore dispatch names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "vm host native builtin records dispatch by id before name fallback"` (`tests/exec.zig:8605`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「vm host native builtin records dispatch by id before name fallback」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "vm collection constructors use registered prototype methods"` (`tests/exec.zig:8644`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「vm collection constructors use registered prototype methods」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "qjs alignment X-08 eval var writable false syncs VARREF is_const"` (`tests/exec.zig:8802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「qjs alignment X-08 eval var writable false syncs VARREF is_const」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(0,eval)("var ev = 1;"); Object.defineProperty(globalThis, "ev", {writable:false}); print("desc.writable = " + Object.getOwnPropertyDescript`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "qjs alignment X-09 VARREF to GETSET detaches the stale cell"` (`tests/exec.zig:8832`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「qjs alignment X-09 VARREF to GETSET detaches the stale cell」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(0,eval)("var ev = 1;"); ev = 7; Object.defineProperty(globalThis, "ev", {get:function(){return 42;}, configurable:true}); print("bare ev = `。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "instanceof resident dispatch preserves GetMethod and result coercion semantics"` (`tests/exec.zig:8962`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「instanceof resident dispatch preserves GetMethod and result coercion semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const candidate = { marker: 7 }; function Truthy() {} Object.defineProperty(Truthy, Symbol.hasInstance, {   value: function(value) { return `。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "default Function hasInstance uses Ordinary; other native records still Call"` (`tests/exec.zig:9078`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「default Function hasInstance uses Ordinary; other native records still Call」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function C() {} const instance = new C(); assert.sameValue(instance instanceof C, true); assert.sameValue(1 instanceof C, false); assert.sam`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "local reference-tail lowering preserves binding semantics"` (`tests/exec.zig:9117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「local reference-tail lowering preserves binding semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function compoundAssignment() {   var x = 1;   function rhs() { x = 10; return 2; }   x += rhs();   return x; } assert.sameValue(compoundAss`；`x = 5; 2`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "qjs alignment const local writes throw from resolved bytecode"` (`tests/exec.zig:9161`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「qjs alignment const local writes throw from resolved bytecode」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function beforeDeclaration() { x = 1; const x = 2; } let beforeCaught = false; let beforeMessage = ""; try { beforeDeclaration(); } catch (e`。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "qjs alignment named function self-binding ignores every sloppy write form"` (`tests/exec.zig:9205`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「qjs alignment named function self-binding ignores every sloppy write form」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let direct = (function named() {   let original = named;   named += 1;   named++;   ++named;   [named] = [0];   ({ value: named } = { value:`；`named = 0; named += 1; named++; ++named;`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "shared test engine reset rebuilds global shape hash buckets"` (`tests/exec.zig:9339`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「shared test engine reset rebuilds global shape hash buckets」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.JSException`。脚本/输入：`"use strict"; print(this === globalThis);`；`assert.sameValue(1 + 1, 2, 'sum');`。约 4 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval strips TypeScript source kind before execution"` (`tests/exec.zig:9360`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval strips TypeScript source kind before execution」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval strips TypeScript method annotations"` (`tests/exec.zig:9374`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval strips TypeScript method annotations」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves as and satisfies runtime property names in TypeScript files"` (`tests/exec.zig:9387`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves as and satisfies runtime property names in TypeScript files」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval supports TypeScript parameter properties"` (`tests/exec.zig:9398`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval supports TypeScript parameter properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval strips TypeScript automatically for ts filenames"` (`tests/exec.zig:9412`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval strips TypeScript automatically for ts filenames」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "CallSite metadata is internal"` (`tests/exec.zig:9423`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「CallSite metadata is internal」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Error.prepareStackTrace = function(err, sites) {     var site = sites[0];     assert.sameValue("__zjs_callsite" in site, false);     assert.`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "pc2line stack locations match QuickJS return and throw matrix"` (`tests/exec.zig:9462`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pc2line stack locations match QuickJS return and throw matrix」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function outer() {   return inner(); } function inner() {   throw new Error("x"); } var captured; try { outer(); } catch (error) { captured `。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "X-89 sloppy and method tails keep the caller like QuickJS; strict tail_call reuses"` (`tests/exec.zig:9482`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「X-89 sloppy and method tails keep the caller like QuickJS; strict tail_call reuses」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function outer() { return inner(); } function inner() { throw new Error("x"); } var captured; try { outer(); } catch (error) { captured = er`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict plain tail_call recursion stays in constant stack"` (`tests/exec.zig:9507`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict plain tail_call recursion stays in constant stack」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`"use strict"; function f(n) { if (n <= 0) return "foo"; return f(n - 1); } assert.sameValue(f(20000), "foo"); function even(n) { return n <=`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "X-89 frame disasm: return call and method emit tail opcodes"` (`tests/exec.zig:9523`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「X-89 frame disasm: return call and method emit tail opcodes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function tailPlain(x) { "use strict"; return g(x); } function sloppyPlain(x) { return g(x); } function tailMethod(o, x) { return o.m(x); } f`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "pc2line malformed transition reports zero location instead of header fallback"` (`tests/exec.zig:9577`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pc2line malformed transition reports zero location instead of header fallback」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function malformedLocationTarget(value) {     return value + 1; }`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error stack uses object method runtime names"` (`tests/exec.zig:9604`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack uses object method runtime names」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var object = {     return() {         return new Error("x").stack;     } }; var stack = object.return(); assert.sameValue(stack.indexOf("at `。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "native builtin errors capture a native callsite"` (`tests/exec.zig:9621`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：builtin errors capture a native callsite。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var defaultStack; try {     [].map(null); } catch (error) {     defaultStack = error.stack; } assert.sameValue(defaultStack.indexOf("    at `。约 1 个 Zig expect、45 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "external host errors capture the native host callsite"` (`tests/exec.zig:9767`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「external host errors capture the native host callsite」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function captureHostBacktrace() {     try {         hostBacktraceProbe();     } catch (error) {         return String(error.stack);     } } `。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "native record calls preflight the native stack and recover"` (`tests/exec.zig:9810`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：record calls preflight the native stack and recover。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let nativeStackResult = "missing"; try {     nativeEntryRecurse(); } catch (error) {     nativeStackResult = error.name + ":" + error.messag`；`assert.sameValue(nativeEntryRecurse(), 7);`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "external C function preflight uses caller realm and callback errors use callee realm"` (`tests/exec.zig:9848`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「external C function preflight uses caller realm and callback errors use callee realm」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Error stack preserves construction frames across delayed access"` (`tests/exec.zig:9933`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack preserves construction frames across delayed access」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function makeError() {     return new Error("x"); } var err = makeError(); assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "eval SyntaxError carries construction stack"` (`tests/exec.zig:9954`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：SyntaxError carries construction stack。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function evalThrower() {     try { eval("]"); } catch (e) { return e; }     return null; } var evalErr = evalThrower(); assert.sameValue(eva`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TypeError thrown via message helper carries stack exactly once"` (`tests/exec.zig:9977`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TypeError thrown via message helper carries stack exactly once」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function typeThrower() {     try { (0)(); } catch (e) { return e; }     return null; } var typeErr = typeThrower(); assert.sameValue(typeErr`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error prepareStackTrace formats captured frames lazily"` (`tests/exec.zig:10001`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error prepareStackTrace formats captured frames lazily」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var calls = 0; Error.prepareStackTrace = function() {     calls++;     return "early"; }; function makeError() {     return new Error("x"); `。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error stack setter rejects non-string stack values"` (`tests/exec.zig:10031`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack setter rejects non-string stack values」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var err = new Error("x"); assert.throws(TypeError, function() {     err.stack = 123; }); assert.throws(TypeError, function() {     Object.ge`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error stack copied accessor setter writes without recursion"` (`tests/exec.zig:10049`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack copied accessor setter writes without recursion」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var err = new Error("x"); Object.defineProperty(err, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack")); assert.throws(Type`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error stack copied accessor setter writes through proxy without recursion"` (`tests/exec.zig:10068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack copied accessor setter writes through proxy without recursion」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var proxy = new Proxy(new Error("x"), {}); Object.defineProperty(proxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error stack reentrant formatting is capped to captured frames"` (`tests/exec.zig:10084`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error stack reentrant formatting is capped to captured frames」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var previousLimit = Error.stackTraceLimit; Error.stackTraceLimit = 1; var calls = 0; Error.prepareStackTrace = function(error, sites) {     `。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Array fill respects proxy prototypes"` (`tests/exec.zig:10110`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Array fill respects proxy prototypes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var calls = []; var array = new Array(3); Object.setPrototypeOf(array, new Proxy(Array.prototype, {     set: function(target, key, value, re`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Error.prepareStackTrace exceptions produce null stack"` (`tests/exec.zig:10130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Error.prepareStackTrace exceptions produce null stack」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`Error.prepareStackTrace = function() {     throw new TypeError("prep"); }; assert.sameValue(new Error("x").stack, null); Error.prepareStackT`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine runtime-strict file eval matches QuickJS CLI script surface"` (`tests/exec.zig:10144`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine runtime-strict file eval matches QuickJS CLI script surface」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var evalCreated = 5; capture = function(){ return evalCreated; };`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "runtime-strict eval overrides parse-time mapped arguments subtype"` (`tests/exec.zig:10174`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime-strict eval overrides parse-time mapped arguments subtype」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval exit leaves closed var-ref cycles for explicit collection"` (`tests/exec.zig:10267`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval exit leaves closed var-ref cycles for explicit collection」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`{     let self = function() { return self; }; }`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise result cycle is released by runtime cycle removal"` (`tests/exec.zig:10304`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise result cycle is released by runtime cycle removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。主体是一句 `try expectEvalCycleReclaimed(&js, warmup, cycle)`：热身脚本 `(() => { let resolve; new Promise(r => { resolve = r; }); resolve({}); })()` 不成环，观测脚本把 promise 自己塞进兑现值 `const result = { promise }; resolve(result)` 造出 `PromisePayload.result` 的自环（注释钉 object.zig:8661-8665）。helper 负责关阈值、取基线、断言环被 `runObjectCycleRemoval` 精确回收且幂等。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise reaction cycle is released by runtime cycle removal"` (`tests/exec.zig:10316`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise reaction cycle is released by runtime cycle removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。`try expectEvalCycleReclaimed(&js, ...)`：热身 `new Promise(() => {}).then(() => {})` 不成环；观测 `const promise = new Promise(() => {}); promise.then(() => promise)` 让反应处理器闭包回指 promise，成环落在 `PromisePayload` 的 reaction 字段/链表上（注释钉 object.zig:8661-8665）。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "proxy revoke FunctionRare cycle is released by runtime cycle removal"` (`tests/exec.zig:10328`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「proxy revoke FunctionRare cycle is released by runtime cycle removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。`try expectEvalCycleReclaimed(&js, ...)`：热身 `Proxy.revocable({}, {})` 不成环；观测 `const target = {}; const pair = Proxy.revocable(target, {}); target.revoke = pair.revoke;` 把 revoke 函数挂回 target，环经 `FunctionRarePayload.proxy_revoke_target`（注释钉 object.zig:8561-8573）。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise finally FunctionRare cycle is released by runtime cycle removal"` (`tests/exec.zig:10340`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise finally FunctionRare cycle is released by runtime cycle removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。`try expectEvalCycleReclaimed(&js, ...)`：热身 `new Promise(() => {}).finally(() => {})` 不成环；观测 `const promise = new Promise(() => {}); promise.finally(() => promise)` 让 finally 回调闭包回指 promise，环经 `FunctionRarePayload.promise_finally_callback`（注释钉 object.zig:8561-8573）。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "DisposableStack resource self-cycle is released by runtime cycle removal"` (`tests/exec.zig:10352`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「DisposableStack resource self-cycle is released by runtime cycle removal」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。`try expectEvalCycleReclaimed(&js, ...)`：热身 `stack.adopt({}, () => {})` 收养一个无关对象；观测 `stack.adopt(stack, () => {})` 让 stack 收养自己，环经 `DisposableStackPayload` 的资源 value/method 边（注释钉 object.zig:8596-8603）。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module import-meta and eval-exception cycles are released by runtime cycle removal"` (`tests/exec.zig:10364`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module import-meta and eval-exception cycles are released by runtime cycle removal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "disposable stack extras leftover runtime metadata preserves dispose aliases and disposed"` (`tests/exec.zig:10465`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「disposable stack extras leftover runtime metadata preserves dispose aliases and disposed」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(DisposableStack.prototype[Symbol.toStringTag], "DisposableStack"); assert.sameValue(AsyncDisposableStack.prototype[Symbol.t`。约 1 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "buffer constructor extras leftover runtime tables preserve ArrayBuffer SharedArrayBuffer and DataView"` (`tests/exec.zig:10496`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「buffer constructor extras leftover runtime tables preserve ArrayBuffer SharedArrayBuffer and DataView」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(ArrayBuffer[Symbol.species], ArrayBuffer); assert.sameValue(SharedArrayBuffer[Symbol.species], SharedArrayBuffer); assert.s`。约 1 个 Zig expect、23 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "iterator step leftover post-next decode preserves for-of and helper results"` (`tests/exec.zig:10533`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「iterator step leftover post-next decode preserves for-of and helper results」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var events = []; var step = 0; var custom = {   [Symbol.iterator]() { return this; },   next() {     if (step++ === 0) {       return {     `。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class field initializer leftover runtime static preserves instance static private and computed fields"` (`tests/exec.zig:10583`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class field initializer leftover runtime static preserves instance static private and computed fields」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var key = "comp"; class C {   inst;   instInit = 1;   #priv;   #privInit = 2;   static st;   static stInit = 3;   static #spriv;   static #s`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover instance-computed public field initializer through shared emit"` (`tests/exec.zig:10626`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover instance-computed public field initializer through shared emit」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var key = "comp"; class C {   [key];   [key + "Init"] = 7;   named = 1;   static [key + "S"] = 8; } var o = new C(); assert.sameValue(o.comp`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover do while parse through one runtime flag"` (`tests/exec.zig:10660`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover do while parse through one runtime flag」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var n = 0; while (n < 3) n += 1; assert.sameValue(n, 3); var d = 0; do { d += 1; } while (d < 3); assert.sameValue(d, 3); var once = 0; do {`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover error stack at-line format through one runtime kind"` (`tests/exec.zig:10695`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover error stack at-line format through one runtime kind」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function makeError() {     return new Error("x"); } var captured = makeError().stack; assert.sameValue(typeof captured, "string"); assert.sa`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover array-from array-like through one runtime destination"` (`tests/exec.zig:10750`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover array-from array-like through one runtime destination」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.compareArray(Array.from([1, 2, 3]), [1, 2, 3]); assert.compareArray(Array.from([1, 2, 3], function(x) { return x + 1; }), [2, 3, 4]);`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover proxy set trap through one runtime kind"` (`tests/exec.zig:10775`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover proxy set trap through one runtime kind」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`"use strict"; var set = []; var p = new Proxy({}, { set: function (o, k, v) { set.push(k); o[k] = v; return true; }}); p.foo = 1; assert.sam`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover proxy extensible trap through one runtime kind"` (`tests/exec.zig:10804`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover proxy extensible trap through one runtime kind」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`"use strict"; var seen = []; var p = new Proxy({}, {   isExtensible: function (t) { seen.push("is"); return Object.isExtensible(t); } }); as`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover proxy has trap through one outlined walk"` (`tests/exec.zig:10854`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover proxy has trap through one outlined walk」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var seen = []; var target = { foo: 1 }; var p = new Proxy(target, {   has: function (t, k) { seen.push(k); return Reflect.has(t, k); } }); a`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover proxy getPrototypeOf through one outlined walk"` (`tests/exec.zig:10891`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover proxy getPrototypeOf through one outlined walk」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var proto = { marker: 1 }; var target = Object.create(proto); var seen = []; var p = new Proxy(target, {   getPrototypeOf: function (t) { se`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Object.isExtensible builtin through outlined extensible op"` (`tests/exec.zig:10929`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Object.isExtensible builtin through outlined extensible op」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(Object.isExtensible(1), false); assert.sameValue(Object.isExtensible(undefined), false); assert.sameValue(Reflect.isExtensi`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Object.getOwnPropertyNames through outlined enumerable own properties"` (`tests/exec.zig:10962`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Object.getOwnPropertyNames through outlined enumerable own properties」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var o = Object.defineProperty({ a: 1, b: 2 }, "hidden", { value: 9, enumerable: false }); var s = Symbol("s"); o[s] = 3; assert.sameValue(Ob`。约 1 个 Zig expect、13 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.shift index-move through outlined arrayMoveIndex"` (`tests/exec.zig:10995`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.shift index-move through outlined arrayMoveIndex」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var a = [1, , 3, 4]; assert.sameValue(a.shift(), 1); assert.sameValue(a + "", ",3,4"); assert.sameValue(a.hasOwnProperty("0"), false); asser`。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.slice present-index through outlined arrayCopyPresentIndex"` (`tests/exec.zig:11031`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.slice present-index through outlined arrayCopyPresentIndex」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var a = [1, , 3, 4]; var sliced = a.slice(0, 3); assert.sameValue(sliced + "", "1,,3"); assert.sameValue(sliced.hasOwnProperty("1"), false);`。约 1 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover integer binary through live bitwise and number arms"` (`tests/exec.zig:11062`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover integer binary through live bitwise and number arms」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(2 + 3, 5); assert.sameValue(8 - 3, 5); assert.sameValue(4 * 5, 20); assert.sameValue(10 / 2, 5); assert.sameValue(10 % 3, 1`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.map generic get through one runtime tail"` (`tests/exec.zig:11090`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.map generic get through one runtime tail」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue([1, 2, 3].map(function(v) { return v + 1; }) + "", "2,3,4"); var seen = []; assert.sameValue([1, , 3].map(function(v, i) { `。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.toReversed get-define through outlined arrayCopyIndex"` (`tests/exec.zig:11114`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.toReversed get-define through outlined arrayCopyIndex」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var rev = [1, , 3].toReversed(); assert.sameValue(rev + "", "3,,1"); assert.sameValue(rev.hasOwnProperty("1"), true); assert.sameValue(rev[1`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.sort generic set through one runtime tail"` (`tests/exec.zig:11139`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.sort generic set through one runtime tail」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var dense = [3, 1, 2]; assert.sameValue(dense.sort() + "", "1,2,3"); var already = [1, 2, 3]; assert.sameValue(already.sort() + "", "1,2,3")`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.fill generic set through one runtime tail"` (`tests/exec.zig:11170`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.fill generic set through one runtime tail」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var dense = [1, 2, 3, 4]; assert.sameValue(dense.fill(9, 1, 3) + "", "1,9,9,4"); var holey = new Array(5); assert.sameValue(holey.fill(7, 2,`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.indexOf direction through one runtime walk"` (`tests/exec.zig:11196`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.indexOf direction through one runtime walk」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue([1, 2, 3, 2].indexOf(2), 1); assert.sameValue([1, 2, 3, 2].lastIndexOf(2), 3); assert.sameValue([1, 2, 3].indexOf(9), -1); `。约 1 个 Zig expect、18 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover Array.reduce direction through one runtime walk"` (`tests/exec.zig:11224`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover Array.reduce direction through one runtime walk」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue([1, 2, 3].reduce(function(a, v) { return a + v; }, 0), 6); assert.sameValue([1, 2, 3].reduceRight(function(a, v) { return a`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "leftover iterator wrap next return through one runtime kind"` (`tests/exec.zig:11251`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leftover iterator wrap next return through one runtime kind」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var sealed = Object.preventExtensions({   next: function() { return { done: false, value: 3 }; },   return: function() { return { done: true`。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "stamped native data-method leftover runtime stamp preserves async generator and iterator helpers"` (`tests/exec.zig:11279`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stamped native data-method leftover runtime stamp preserves async generator and iterator helpers」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`async function* g() { yield 1; return 2; } var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype); assert.sameValue(AsyncGenerator`。约 1 个 Zig expect、19 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "fast prototype method leftover runtime domain preserves regexp and collection lookups"` (`tests/exec.zig:11312`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fast prototype method leftover runtime domain preserves regexp and collection lookups」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var re = /a/; assert.sameValue(re.test, RegExp.prototype.test); assert.sameValue(re.exec, RegExp.prototype.exec); assert.sameValue(re.test("`。约 1 个 Zig expect、25 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "data view extras leftover optional species preserves accessors and omits species"` (`tests/exec.zig:11364`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「data view extras leftover optional species preserves accessors and omits species」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(Object.getOwnPropertyDescriptor(DataView, Symbol.species), undefined); assert.sameValue(ArrayBuffer[Symbol.species], ArrayB`。约 1 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "defineNativeDataMethod leftover optional native id preserves iterator methods"` (`tests/exec.zig:11392`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「defineNativeDataMethod leftover optional native id preserves iterator methods」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue([1].values().next().value, 1); assert.sameValue("ab"[Symbol.iterator]().next().value, "a"); function* g() { yield 7; } var `。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "createStringValue leftover noinline preserves empty flags and ascii strings"` (`tests/exec.zig:11414`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「createStringValue leftover noinline preserves empty flags and ascii strings」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(/abc/.flags, ""); assert.sameValue(/abc/.source, "abc"); assert.sameValue("".bold(), "<b></b>"); assert.sameValue("é".big()`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval TypeError with evaluated arguments does not double free constants"` (`tests/exec.zig:11427`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：Engine eval TypeError with evaluated arguments does not double free constants。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.TypeError`。脚本/输入：`const obj = {}; obj.missing("a", "a");`；`RegExp.test("a", "a");`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "vm call handler accepts allocator-backed argument lists"` (`tests/exec.zig:11440`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「vm call handler accepts allocator-backed argument lists」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "Engine API eval and job queue are wired"` (`tests/exec.zig:11492`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine API eval and job queue are wired」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.SyntaxError`。脚本/输入：`1; 2`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "job queue enqueue propagates allocator failure"` (`tests/exec.zig:11541`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「job queue enqueue propagates allocator failure」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.OutOfMemory`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "prepared Promise reactions reserve storage without claiming FIFO order"` (`tests/exec.zig:11555`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prepared Promise reactions reserve storage without claiming FIFO order」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "waitAsync completions enter one typed cross-realm FIFO after facade release"` (`tests/exec.zig:11601`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「waitAsync completions enter one typed cross-realm FIFO after facade release」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "public property key coercion accepts a Symbol.toPrimitive key"` (`tests/exec.zig:11663`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「public property key coercion accepts a Symbol.toPrimitive key」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入：`({ [Symbol.toPrimitive]() { return 'missing'; } })`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "waitAsync completion OOM stays at FIFO head for same-runtime retry"` (`tests/exec.zig:11682`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：waitAsync completion OOM stays at FIFO head for same-runtime retry。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。设置 runtime 内存上限以注入 OOM。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "dynamic import job OOM retains its FIFO position for retry"` (`tests/exec.zig:11729`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：dynamic import job OOM retains its FIFO position for retry。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。用 `expectError` 钉失败路径。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dynamic import job keeps its enqueue Realm after creator facade release"` (`tests/exec.zig:11776`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic import job keeps its enqueue Realm after creator facade release」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "dynamic import loader mutates only the enqueue Realm registry after public owner release"` (`tests/exec.zig:11818`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic import loader mutates only the enqueue Realm registry after public owner release」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "thenable job reservation OOM leaves resolving function retryable"` (`tests/exec.zig:11884`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：thenable job reservation OOM leaves resolving function retryable。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "published Promise resolution survives resolver collection through typed FIFO owner"` (`tests/exec.zig:11939`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「published Promise resolution survives resolver collection through typed FIFO owner」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。设置 runtime 内存上限以注入 OOM。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Promise reaction retains callable Proxy classification after revocation"` (`tests/exec.zig:11993`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Promise reaction retains callable Proxy classification after revocation」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var __revokedPromiseReaction = "pending"; var __wakePromiseReaction; var __parentPromiseReaction = new Promise(function (resolve) { __wakePr`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `TypeError`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "job queue keeps symbol arguments rooted until release"` (`tests/exec.zig:12018`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「job queue keeps symbol arguments rooted until release」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "job queue symbol roots preserve weak map values"` (`tests/exec.zig:12044`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「job queue symbol roots preserve weak map values」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary script entry points do not run full-heap cycle collection on exit"` (`tests/exec.zig:12087`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary script entry points do not run full-heap cycle collection on exit」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__evalExitClosure = (function () {   let value = 40;   return eval("() => ++value"); })();`；`assert.sameValue(globalThis.__evalExitClosure(), 41); delete globalThis.__evalExitClosure;`。约 7 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "IC-R1: delete then get_field is undefined after a prior hit"` (`tests/exec.zig:12149`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「IC-R1: delete then get_field is undefined after a prior hit」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function read(o) { return o.x; } var o = { x: 1 }; var a = read(o); var d = delete o.x; var b = read(o); o.x = 2; var c = read(o); print([a,`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "IC-P1: OrdinarySet forwards to a Proxy proto [[Set]] trap"` (`tests/exec.zig:12162`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「IC-P1: OrdinarySet forwards to a Proxy proto [[Set]] trap」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var called = false; var recv; var p = new Proxy({}, { set: function (t, k, v, r) { called = true; recv = r; return true; } }); var o = Objec`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "String.prototype.match invokes a custom matcher before coercing the receiver"` (`tests/exec.zig:12177`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String.prototype.match invokes a custom matcher before coercing the receiver」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var log = []; var receiver = { toString: function () { log.push("toString"); return "abc"; } }; var matcher = {}; matcher[Symbol.match] = fu`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp Symbol.split preserves captures returned by custom exec"` (`tests/exec.zig:12188`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp Symbol.split preserves captures returned by custom exec」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var log = []; var capture = { toString: function () { log.push("coerced"); return "capture"; } }; function Splitter() { this.lastIndex = 0; `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp Symbol.split propagates invalid species exec TypeError"` (`tests/exec.zig:12206`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp Symbol.split propagates invalid species exec TypeError」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var regexp = /,/; function Splitter() { return { exec: 1, lastIndex: 0 }; } regexp.constructor = { [Symbol.species]: Splitter }; try { "a,b"`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp Symbol.split appends sticky flag without narrowing wide species flags"` (`tests/exec.zig:12215`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp Symbol.split appends sticky flag without narrowing wide species flags」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var seen; function Splitter(pattern, flags) { seen = flags; return /,/y; } var regexp = /,/; Object.defineProperty(regexp, "flags", { get: f`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "flagless RegExp flags accessor reuses the runtime empty string"` (`tests/exec.zig:12228`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「flagless RegExp flags accessor reuses the runtime empty string」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RegExp exec result template preserves metadata groups and indices"` (`tests/exec.zig:12242`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp exec result template preserves metadata groups and indices」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var plain = /a/.exec("ba"); print([plain.length, plain[0], plain.index, plain.input, plain.groups === undefined].join("|")); var named = /(?`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp compiler stack overflow is a catchable SyntaxError"` (`tests/exec.zig:12252`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp compiler stack overflow is a catchable SyntaxError」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`try { new RegExp("(?:".repeat(40000)); print("no throw"); } catch(e) { print(e.name + ":" + e.message); } try { new RegExp("[".repeat(4000)+`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp accepts literal astral group names in non-unicode mode"` (`tests/exec.zig:12264`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp accepts literal astral group names in non-unicode mode」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var nm = String.fromCharCode(0xD801,0xDC00); ["", "u", "v"].forEach(function(fl){   try { var r = new RegExp("(?<"+nm+">x)", fl); print("fla`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp literals reuse parse-time bytecode and the intrinsic realm shape"` (`tests/exec.zig:12276`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp literals reuse parse-time bytecode and the intrinsic realm shape」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var IntrinsicRegExp = RegExp; var intrinsicPrototype = RegExp.prototype; function make() { return /(?<letter>a)/dgi; } var first = make(); v`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp legacy statics preserve the realm snapshot across constructor replacement"` (`tests/exec.zig:12300`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp legacy statics preserve the realm snapshot across constructor replacement」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var IntrinsicRegExp = RegExp; var noCapture = /x/; var captured = /(a)/; /(a)(b)?/.exec("zabq"); print([IntrinsicRegExp.input, IntrinsicRegE`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "regexp split and global match arrays use the realm Array prototype"` (`tests/exec.zig:12323`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「regexp split and global match arrays use the realm Array prototype」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(Object.getPrototypeOf("a".split(/x/)) === Array.prototype); print(Object.getPrototypeOf("a".split(/x/, 0)) === Array.prototype); print`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "RegExp Symbol.split uses the realm intrinsic default species"` (`tests/exec.zig:12331`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp Symbol.split uses the realm intrinsic default species」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var IntrinsicRegExp = RegExp; var split = IntrinsicRegExp.prototype[Symbol.split]; var rx = /,/; Object.defineProperty(rx, "constructor", { `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves global lexical write fast path semantics"` (`tests/exec.zig:12344`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves global lexical write fast path semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let g = 0; g = 1; function setGlobal() { g = g + 2; } setGlobal(); print(g); const c = 1; try { c = 2; } catch (e) { print(e.name, c); } let`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine nested functions retain ancestor with environments during finalization"` (`tests/exec.zig:12362`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine nested functions retain ancestor with environments during finalization」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var outer = 1; var environment = { outer: "initial" }; with (environment) {   (function () { outer = "updated"; })(); } assert.sameValue(out`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves selected with references during updates"` (`tests/exec.zig:12379`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves selected with references during updates」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function updateDeletedProperty() {   var x = 0;   var scope = { get x() { delete this.x; return 2; } };   with (scope) { x *= 3; }   print(s`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "with compound assignment rechecks proxy binding before get and set"` (`tests/exec.zig:12402`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「with compound assignment rechecks proxy binding before get and set」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var log = []; var target = { p: 0 }; var proxy = new Proxy(target, {   has: function(t, key) { log.push("has:" + String(key)); return Reflec`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine destructuring snapshots with binding references before property reads"` (`tests/exec.zig:12418`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine destructuring snapshots with binding references before property reads」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var log = []; var sourceKey = { toString: function() { log.push('sourceKey'); return 'p'; } }; var source = { get p() { log.push('get source`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine with destructuring assignment reaches const fallback at runtime"` (`tests/exec.zig:12450`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine with destructuring assignment reaches const fallback at runtime」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fallback() {   const x = 0;   with ({}) ({ x } = { x: 1 }); } let caught = false; try { fallback(); } catch (error) { caught = erro`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval assignments capture the target before dynamic var insertion"` (`tests/exec.zig:12476`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval assignments capture the target before dynamic var insertion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function simpleAssignment() {   var x = 0;   var inner = (function() {     x = (eval("var x;"), 1);     return x;   })();   print(inner, x);`；`var x;`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine arrow eval assignments capture the target before dynamic var insertion"` (`tests/exec.zig:12517`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine arrow eval assignments capture the target before dynamic var insertion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function outer() {   var x = 0;   var simple = () => { x = (eval("var x;"), 1); return x; };   print(simple(), x);   x = 3;   var compound =`；`var x;`。约 0 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval captures the caller arguments binding"` (`tests/exec.zig:12551`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval captures the caller arguments binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function direct(value) { return eval("arguments[0]"); } function throughArrow(value) { return (() => eval("arguments[0]"))(); } function rep`；`arguments[0]`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine arguments writes prefer the current function binding over outer lexical bindings"` (`tests/exec.zig:12602`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine arguments writes prefer the current function binding over outer lexical bindings」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let arguments = 'outer'; function ordinary() {   arguments = 'ordinary';   return arguments; } function parameterDefault(value = (arguments `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine direct eval shares top-level lexical cells across nested closures"` (`tests/exec.zig:12633`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine direct eval shares top-level lexical cells across nested closures」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let x = 500; function direct() { return eval("x"); } function write() { eval("x = 501"); } var nested = eval("() => eval('x')"); var env = {`；`x = 501`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine constructor parameter defaults use the initialized this binding"` (`tests/exec.zig:12671`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine constructor parameter defaults use the initialized this binding」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`class A {   #x = 'hello';   constructor(value = this.#x) { this.value = value; } } var a = new A(); print(a.value); class B extends A {   co`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine heritage closures retain the initialized inner class-name binding"` (`tests/exec.zig:12690`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine heritage closures retain the initialized inner class-name binding」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var expressionProbe; var expressionClass = class InnerExpression extends (   expressionProbe = function () { return InnerExpression; }, Obje`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine inferred class names precede static initialization across named-evaluation sites"` (`tests/exec.zig:12714`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine inferred class names precede static initialization across named-evaluation sites」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {   let Assigned;   Assigned = class { static { this.observedName = this.name; } };   assert.sameValue(Assigned.name, "Assigned`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval balances refcounts for refcounted duplicate-key object literals"` (`tests/exec.zig:12789`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval balances refcounts for refcounted duplicate-key object literals」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__dupLitO1 = { m: 1 }; globalThis.__dupLitO2 = { m: 2 };`；`let __dupLitLast = null; for (let i = 0; i < 16; i++) {   __dupLitLast = { a: __dupLitO1, a: __dupLitO2, keep: __dupLitO1 }; } const __dupLi`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval routes host output through global function calls"` (`tests/exec.zig:12827`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval routes host output through global function calls」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print(1); console.log("x"); const out = print; out(2 + 3, typeof out); const logger = console.log; logger("ok"); const c = console; c.log("a`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "using early exit before await using keeps sync disposal synchronous"` (`tests/exec.zig:12840`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「using early exit before await using keeps sync disposal synchronous」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function plainBlockForUsingOpcodeCheck() { { let value = 1; return value; } } let sameTurn = true; async function disposeBeforeAwaitUsing() `。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves local numeric add host output semantics"` (`tests/exec.zig:12876`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves local numeric add host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let a = 1; let b = 2; print(a + b); let max = 2147483647; print(max + 1); let oldPrint = print; print = function(x) { globalThis.seen = "cus`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "get_array_el2 dense indexed call keeps the receiver"` (`tests/exec.zig:12891`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「get_array_el2 dense indexed call keeps the receiver」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var seen; function rec(x) { seen = this; return x + 1; } var a = [rec, rec]; function idxcall(arr, i, x) { return arr[i](x); } assert.sameVa`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "get_array_el dense direct arm preserves hits and indexed fallback"` (`tests/exec.zig:12908`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「get_array_el dense direct arm preserves hits and indexed fallback」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function read(a, i) { return a[i]; } var a = [{ value: 7 }, 11]; assert.sameValue(read(a, 0).value, 7); assert.sameValue(read(a, 1), 11); as`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "int32 add sub mul overflow stays a number on the generic binary"` (`tests/exec.zig:12924`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「int32 add sub mul overflow stays a number on the generic binary」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function add1(a, b) { return a + b; } function sub1(a, b) { return a - b; } function mul1(a, b) { return a * b; } assert.sameValue(add1(2147`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval preserves collection read host output semantics"` (`tests/exec.zig:12941`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves collection read host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let map = new Map(); map.set("a", 1); print(map.get("a")); print(map.has("a")); let key = {}; let weak = new WeakMap(); weak.set(key, 2); pr`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "runtime teardown preserves closure capture metadata until objects are destroyed"` (`tests/exec.zig:12969`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime teardown preserves closure capture metadata until objects are destroyed」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function assert(value) { if (value !== true) throw 1; } var calls = 0; var originalSet = WeakMap.prototype.set; WeakMap.prototype.set = func`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "cycle teardown preserves restored strong counts for weakly referenced keys"` (`tests/exec.zig:12991`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「cycle teardown preserves restored strong counts for weakly referenced keys」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var first = {}; var second = {}; var results = []; var originalSet = WeakMap.prototype.set; WeakMap.prototype.set = function(key, value) {  `。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval preserves regexp UTF-16 test host output semantics"` (`tests/exec.zig:13013`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves regexp UTF-16 test host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let re = new RegExp("\u00e9+", ""); print(re.test("\u00e9\u00e9")); print(re.test("\u0100\u00e9")); print(re.test("\u0100")); let oldTest = `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval prepared RegExp call observes same-site property changes"` (`tests/exec.zig:13041`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval prepared RegExp call observes same-site property changes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let re = /a+b/; function hit(input) { return re.test(input); } print(hit("aaab")); RegExp.prototype.test = function(input) { return "patched`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval preserves dense array join host output semantics"` (`tests/exec.zig:13063`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves dense array join host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let tab = [3, 1, 2]; tab.sort(); print(tab.join(",")); let oldJoin = Array.prototype.join; Array.prototype.join = function(separator) { retu`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves dense array pop host output semantics"` (`tests/exec.zig:13081`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves dense array pop host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let tab = [1, 2]; print(tab.pop()); print(tab.length); let oldPop = Array.prototype.pop; Array.prototype.pop = function() { return "custom:"`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves ordinary array pop fast path semantics"` (`tests/exec.zig:13101`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves ordinary array pop fast path semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let a = [1, 2, 3]; let x = a.pop(); print(x, a.length, a.join(",")); let extra = [1, 2]; print(extra.pop(0), extra.length, extra.join(","));`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "empty native array pop fast arm preserves observable length writes"` (`tests/exec.zig:13126`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「empty native array pop fast arm preserves observable length writes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var frozen = Object.freeze([]); var frozenError; try { frozen.pop(); } catch (error) { frozenError = error; } assert.sameValue(frozenError.n`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array pop length write removes elements added by the last-element getter"` (`tests/exec.zig:13172`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array pop length write removes elements added by the last-element getter」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var array = []; array.length = 1; Object.defineProperty(array, "0", {     configurable: true,     get: function() {         array[5] = 9;   `。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array pop reports read-only length after deleting a configurable last element"` (`tests/exec.zig:13195`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array pop reports read-only length after deleting a configurable last element」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var array = [7]; Object.defineProperty(array, "length", { writable: false }); var thrown; try { array.pop(); } catch (error) { thrown = erro`。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves simple closure call host output semantics"` (`tests/exec.zig:13213`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves simple closure call host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function counter() { let n = 0; return function () { n++; return n; }; } let next = counter(); print(next()); print(next()); let oldPrint = `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves one-shot array literal host output semantics"` (`tests/exec.zig:13227`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves one-shot array literal host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function lengthOnly() {   let tab = [1, 2];   print(tab.length); } print(lengthOnly() === undefined); function valueAndLength() {   let tab `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves one-shot array named property host output semantics"` (`tests/exec.zig:13250`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves one-shot array named property host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let tab = [1]; tab.a = 9; print(tab.a); let oldPrint = print; print = function(x) { oldPrint("custom:" + x); }; let tab2 = [1]; tab2.a = 8; `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves typed array constructor length host output semantics"` (`tests/exec.zig:13274`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves typed array constructor length host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function lengthOnly() {   let tab = new Int32Array(new ArrayBuffer(16));   print(tab.length); } print(lengthOnly() === undefined); let oldPr`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves Int32Array indexed read fast path semantics"` (`tests/exec.zig:13295`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves Int32Array indexed read fast path semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let a = new Int32Array(2); a[0] = 7; a[1] = -3; print(a[0], a[1], a[2]); Object.prototype[0] = 9; let b = new Int32Array(0); print(b[0]); de`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "strict plain calls preserve this arguments eval captures and backtraces"` (`tests/exec.zig:13338`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict plain calls preserve this arguments eval captures and backtraces」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function strictZero() {     "use strict";     assert.sameValue(this, undefined);     return arguments.length; } assert.sameValue(strictZero(`；`var hidden = 1`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict arguments preserve qjs intrinsic metadata and dense element semantics"` (`tests/exec.zig:13380`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict arguments preserve qjs intrinsic metadata and dense element semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const savedValues = Array.prototype.values; Array.prototype.values = function patchedValues() { throw new Error("observable lookup"); }; try`。约 1 个 Zig expect、33 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "mapped arguments use var-ref indexed storage and detach on descriptor changes"` (`tests/exec.zig:13445`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mapped arguments use var-ref indexed storage and detach on descriptor changes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function mapped(first, second) {     const args = arguments;     first = 5;     assert.sameValue(args[0], 5);     args[1] = 7;     assert.sa`。约 1 个 Zig expect、32 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "apply resolves arguments length and preserves observable fallback"` (`tests/exec.zig:13532`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「apply resolves arguments length and preserves observable fallback」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function signature() {     return arguments.length + ":" + arguments[0] + ":" + arguments[arguments.length - 1]; } function mapped(first, se`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "resident generators preserve mapped arguments parameter aliases"` (`tests/exec.zig:13577`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident generators preserve mapped arguments parameter aliases」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function* mappedGenerator(first, second, third, missing) {     arguments[0] = 32;     arguments[1] = 54;     arguments[2] = 333;     yield f`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "implicit arguments resolution preserves mapped aliases"` (`tests/exec.zig:13601`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「implicit arguments resolution preserves mapped aliases」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function annexRead(value) {   { function arguments() {} }   return arguments[0]; } function annexAliasFromArguments(value) {   { function ar`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "body function named arguments does not create a synthetic lexical collision"` (`tests/exec.zig:13646`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：body function named arguments does not create a synthetic lexical collision。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function bodyCollision() { return typeof arguments; function arguments() {} } print(bodyCollision());`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "resident mapped arguments share one open bare arg slot"` (`tests/exec.zig:13653`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident mapped arguments share one open bare arg slot」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* mappedArgStorage(first) {   globalThis.__mappedArgArguments = arguments;   yield first;   first += 1;   yield first; } globalThis.`；`const step = __mappedArgGenerator.next(); assert.sameValue(step.value, 42); assert.sameValue(step.done, false);`。约 9 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generic arg opcodes preserve mapped aliases in a bare resident slot"` (`tests/exec.zig:13702`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generic arg opcodes preserve mapped aliases in a bare resident slot」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* genericArgStorage(a, b, c, d, fifth) {   globalThis.__genericArgArguments = arguments;   arguments[4] = 50;   yield fifth;   fifth`；`let step = __genericArgGenerator.next(); assert.sameValue(step.value, 51); assert.sameValue(step.done, false); step = __genericArgGenerator.`。约 3 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator mapped arguments closures and direct eval share one alias across resumes"` (`tests/exec.zig:13744`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator mapped arguments closures and direct eval share one alias across resumes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* aliasedGenerator(argument) {   globalThis.__aliasedArguments = arguments;   globalThis.__aliasedRead = function() { return argumen`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "async mapped arguments and closures retain one alias across await"` (`tests/exec.zig:13780`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async mapped arguments and closures retain one alias across await」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function mappedAsync(argument) {   const read = function() { return argument; };   arguments[0] = 55;   print('before', read());   con`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "escaped generator arg aliases retain resident backing across cycle collection"` (`tests/exec.zig:13809`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「escaped generator arg aliases retain resident backing across cycle collection」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`var __argCycleHolder; function* argCycle(argument) {   const self = __argCycleHolder;   globalThis.__argCycleArguments = arguments;   global`；`assert.sameValue(__argCycleRead(), 41); __argCycleArguments[0] = 52; assert.sameValue(__argCycleRead(), 52); __argCycleWrite(63); assert.sam`。约 8 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator completion closes escaped arg aliases before releasing resident backing"` (`tests/exec.zig:13857`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator completion closes escaped arg aliases before releasing resident backing」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function* completingArgAlias(argument) {   globalThis.__completedArgArguments = arguments;   globalThis.__completedArgRead = function() { re`；`const step = __completedArgGenerator.next(); assert.sameValue(step.value, 41); assert.sameValue(step.done, true);`。约 4 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "get_length preserves qjs own-property-before-exotic ordering and actions"` (`tests/exec.zig:13898`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「get_length preserves qjs own-property-before-exotic ordering and actions」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const own = { length: 3 }; assert.sameValue(own.length, 3); const inherited = Object.create({ length: 4 }); assert.sameValue(inherited.lengt`。约 1 个 Zig expect、46 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument plain calls preserve parameter and arguments ownership"` (`tests/exec.zig:14060`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「missing-argument plain calls preserve parameter and arguments ownership」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function sloppyMissing(first, second) {     assert.sameValue(arguments.length, 0);     assert.sameValue(arguments.hasOwnProperty("0"), false`；`value`。约 1 个 Zig expect、24 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "inline calls release lazily materialized arguments state"` (`tests/exec.zig:14129`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline calls release lazily materialized arguments state」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function readArguments(value) {     return arguments.length + value; } assert.sameValue(readArguments(1), 2);`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "inline empty leaf abrupt teardown releases pending operands"` (`tests/exec.zig:14156`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline empty leaf abrupt teardown releases pending operands」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function throwWithPendingOperand() {     return {} + null.missing; } function exerciseEmptyLeafThrow() {     for (let i = 0; i < 256; i++) {`；`exerciseEmptyLeafThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "exact-args leaf abrupt teardown releases borrowed args exactly once"` (`tests/exec.zig:14180`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「exact-args leaf abrupt teardown releases borrowed args exactly once」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function leafThrow(a, b) {     return a.x + null.missing + b.x; } function strictLeafThrow(a, b) {     "use strict";     return a.x + null.m`；`exerciseExactArgsLeafThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument abrupt teardown releases supplied args and pads exactly once"` (`tests/exec.zig:13306`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：`argc < arg_count` 时传入的 refcounted 前缀只释放一次，pad 的 undefined 是 no-op；覆盖 plain/strict/method。
- **实现**：256 次四臂抛错，两轮 `liveCount` 对照。不含默认预算深展开。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。

### `test "leaf returns with leftover operands route through general teardown"` (`tests/exec.zig:14218`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「leaf returns with leftover operands route through general teardown」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function exactArgsLeftover(a) { ({ x: a }); } function switchLeftover(a) {     switch (a) { case 1: return { x: 9 }; } } function exerciseLe`；`exerciseLeafLeftovers()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument calls read undefined across every entry arm"` (`tests/exec.zig:14253`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「missing-argument calls read undefined across every entry arm」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.__padOne = function (value) { return value === undefined ? 1 : 0; }; globalThis.__padTwo = function (first, second) {     return `；`exercisePaddedLeafOutcomes()`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument calls on leaf-excluded shapes keep generic-path outcomes"` (`tests/exec.zig:14359`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「missing-argument calls on leaf-excluded shapes keep generic-path outcomes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.__exArguments = function (a, b) { return arguments.length; }; globalThis.__exDefault = function (a, b = 9) { return String(a) + "`；`exercisePaddedExclusions()`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "missing-argument leftover-carrying returns route through general teardown"` (`tests/exec.zig:14409`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「missing-argument leftover-carrying returns route through general teardown」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function padLeftover(a, b) { ({ x: a, y: b }); } function padSwitchLeftover(a, b) {     switch (a) { case 1: return { x: String(b) }; } } fu`；`exercisePaddedLeafLeftovers()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "zero-arg leaf leftover bodies are refused publication and balance rc"` (`tests/exec.zig:14441`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「zero-arg leaf leftover bodies are refused publication and balance rc」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.__zeroTrailingDrop = function () { ({ z: 1 }); }; globalThis.__zeroSwitchLeftover = function () { switch ({ x: 7 }) { default: re`；`exerciseZeroArgLeftovers()`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "capture leaf abrupt teardown releases operands and keeps borrowed cells"` (`tests/exec.zig:14514`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「capture leaf abrupt teardown releases operands and keeps borrowed cells」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`const capThrowState = (function () {     const held = { x: 1 };     return {         plain: function () { return held.x + null.missing; },  `；`exerciseCaptureLeafThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "capture leaf returns with leftover operands route through general teardown"` (`tests/exec.zig:14555`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「capture leaf returns with leftover operands route through general teardown」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`const capSwitchLeftover = (function () {     const held = { x: 7 };     return function () { switch (held) { case held: return held.x; } }; `；`exerciseCaptureLeafLeftovers()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "capture leaf shares live cells with its closure across calls"` (`tests/exec.zig:14593`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「capture leaf shares live cells with its closure across calls」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const counterPair = (function () {     let n = 0;     return { bump: () => ++n, read: function () { return n; } }; })(); counterPair.bump();`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "inline empty leaf warm constructor preserves miss fallback and ownership"` (`tests/exec.zig:14625`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline empty leaf warm constructor preserves miss fallback and ownership」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.__warmEmptyLeaf = function () { return 1; };`。约 19 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "forwarded leaf call semantics keep exclusions on the authoritative path"` (`tests/exec.zig:14726`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「forwarded leaf call semantics keep exclusions on the authoritative path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fwdOne() { return 1; } function fwdStrict() { "use strict"; return this === undefined ? 10 : 0; } const fwdArrow = () => 100; funct`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "forwarded leaf abrupt completion balances and keeps the native frame"` (`tests/exec.zig:14756`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「forwarded leaf abrupt completion balances and keeps the native frame」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function fwdThrower() { return (void 0).missing; } function exerciseForwardedThrow() {     for (let i = 0; i < 256; i++) {         let hit =`；`exerciseForwardedThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "forwarded leaf returns with leftover operands route through general teardown"` (`tests/exec.zig:14796`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「forwarded leaf returns with leftover operands route through general teardown」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function fwdTrailingDrop() { ({ z: 1 }); } function fwdSwitchLeftover() { switch ({ x: 7 }) { default: return 5; } } function exerciseForwar`；`exerciseForwardedLeftovers()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "method call empty leaf binds receiver as this and balances refcounts"` (`tests/exec.zig:14828`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「method call empty leaf binds receiver as this and balances refcounts」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`Object.defineProperty(String.prototype, "__leafThis", {     value: function () { return this; },     configurable: true, }); function exerci`；`exerciseMethodEmptyLeaf()`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "method call empty leaf abrupt teardown releases receiver"` (`tests/exec.zig:14862`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「method call empty leaf abrupt teardown releases receiver」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function exerciseMethodEmptyLeafThrow() {     for (let i = 0; i < 256; i++) {         const recv = { boom() { return null.missing; } };     `；`exerciseMethodEmptyLeafThrow()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "method empty leaf warm constructor moves receiver ownership"` (`tests/exec.zig:14884`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「method empty leaf warm constructor moves receiver ownership」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.__warmMethodLeafRecv = { m() { return 1; } };`。约 20 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict empty leaf preserves undefined this across call forms"` (`tests/exec.zig:14985`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict empty leaf preserves undefined this across call forms」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`function strictLeafThis() {     "use strict";     return this; } function strictOuterFactory() {     "use strict";     function nestedStrict`；`exerciseStrictLeafThis()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict method empty leaf passes primitive receiver uncoerced"` (`tests/exec.zig:15027`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict method empty leaf passes primitive receiver uncoerced」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`Object.defineProperty(String.prototype, "__strictLeafThis", {     value: function () { "use strict"; return this; },     configurable: true,`；`exerciseStrictMethodLeaf()`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "strict empty leaf frame preserves undefined this and borrowed ownership"` (`tests/exec.zig:15064`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict empty leaf frame preserves undefined this and borrowed ownership」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`globalThis.__strictWarmLeaf = function () { "use strict"; return 1; };`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "inline call teardown releases every escaped storage shape"` (`tests/exec.zig:15130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline call teardown releases every escaped storage shape」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "inline operand Stack keeps limit and ownership flags in one word"` (`tests/exec.zig:15212`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inline operand Stack keeps limit and ownership flags in one word」。
- **实现**：不建任何 Runtime，纯 `@sizeOf` 布局钉：`engine.exec.stack.Stack` = 40、`inline_calls.Machine.ArgsSource` = 16、`engine.exec.frame.Frame` = 152、`inline_calls.Entry` = 256。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：不分配、不持有任何运行时对象；Frame/Entry 尺寸是布局敏感项（见 inline_calls.zig 的 Entry pin 与 docs/refactor-policy.md 的 QCP-1B 注记），改动布局后此测试先红。

### `test "ordinary root bytecode call carves one operand window"` (`tests/exec.zig:15222`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary root bytecode call carves one operand window」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "method calls preserve receiver arguments eval captures and abrupt ownership"` (`tests/exec.zig:15258`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「method calls preserve receiver arguments eval captures and abrupt ownership」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const receiver = { value: 4 }; receiver.sloppy = function sloppy(first, second) {     assert.sameValue(this, receiver);     assert.sameValue`；`this`。约 1 个 Zig expect、30 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "primitive prototype lookup preserves raw receiver and exotic prototype semantics"` (`tests/exec.zig:15352`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「primitive prototype lookup preserves raw receiver and exotic prototype semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const dataKey = "__zjs_primitive_data_probe__"; const inheritedKey = "__zjs_primitive_inherited_probe__"; const strictGetterKey = "__zjs_pri`。约 1 个 Zig expect、23 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "computed named reads preserve prototype accessors proxies and operand ownership"` (`tests/exec.zig:15462`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed named reads preserve prototype accessors proxies and operand ownership」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const dataKey = "__zjs_computed_data_probe__"; const getterKey = "__zjs_computed_getter_probe__"; const emptyGetterKey = "__zjs_computed_emp`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "computed integer write misses preserve generic set semantics"` (`tests/exec.zig:15530`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed integer write misses preserve generic set semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const own = { 0: 1 }; own[0] = 2; assert.sameValue(own[0], 2); const negativeKey = -1; own[negativeKey] = 3; assert.sameValue(own["-1"], 3);`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "dense write leaf consumes reserved appends only inside the qjs capacity window"` (`tests/exec.zig:15600`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dense write leaf consumes reserved appends only inside the qjs capacity window」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "static named getter and proxy fast paths preserve receivers throws and invariants"` (`tests/exec.zig:15654`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「static named getter and proxy fast paths preserve receivers throws and invariants」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const prototype = {}; let getterReceiver; let getterCount = 0; Object.defineProperty(prototype, "__zjs_static_getter_probe__", {     get() {`。约 1 个 Zig expect、14 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "proxy bytecode get continuation does not require spare operand capacity"` (`tests/exec.zig:15757`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：proxy bytecode get continuation does not require spare operand capacity。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function readX(object) { return object.x; } const proxy = new Proxy({ x: 1 }, {     get(target, key, receiver) {         return Reflect.get(`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "for-of bytecode next continuation preserves result and abrupt semantics"` (`tests/exec.zig:15774`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-of bytecode next continuation preserves result and abrupt semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let events = []; let step = 0; function tailStep() {     if (step++ === 0) {         return {             get done() { events.push("done:fal`。约 1 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "IteratorNext bound proxy and native throws do not close the iterator"` (`tests/exec.zig:15903`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「IteratorNext bound proxy and native throws do not close the iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let closeCalls = 0; function throwingNext() { throw 1; } const nextMethods = [     throwingNext.bind(null),     new Proxy(throwingNext, { ap`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "destructuring abrupt completion closes every live outer iterator"` (`tests/exec.zig:15928`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「destructuring abrupt completion closes every live outer iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function run(value, body) {     const events = [];     const iterator = {         [Symbol.iterator]() { return this; },         next() { eve`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array destructuring rest roots direct symbol values while creating its result"` (`tests/exec.zig:15956`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array destructuring rest roots direct symbol values while creating its result」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const symbol = Symbol("gc-destructuring-rest-symbol"); const source = [symbol]; const [...rest] = source; assert.sameValue(rest.length, 1); `。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "computed object-rest keys perform observable ToPropertyKey once"` (`tests/exec.zig:15975`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed object-rest keys perform observable ToPropertyKey once」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let conversions = 0; const key = {   [Symbol.toPrimitive](hint) {     conversions++;     assert.sameValue(hint, "string");     return "kept"`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "object destructuring does not turn its source into a with environment"` (`tests/exec.zig:15998`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：object destructuring does not turn its source into a with environment。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function(global) {   "use strict";   const { Object } = global;   global.__destructuringFollowup = Object.freeze([1]); })(globalThis); asse`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "object destructuring ToObject uses the current realm primitive prototypes"` (`tests/exec.zig:16014`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object destructuring ToObject uses the current realm primitive prototypes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const { __proto__: numberPrototype } = 42; const { __proto__: stringPrototype } = "value"; const { __proto__: booleanPrototype } = true; con`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "for-in-of generic lvalues use QuickJS bottom-stack evaluation order"` (`tests/exec.zig:16033`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-in-of generic lvalues use QuickJS bottom-stack evaluation order」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let events = []; let target = { length: 0 }; function targetBase() { events.push("base"); return target; } function targetKey() { events.pus`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "computed proxy bytecode trap continuations preserve nested calls throws and invariants"` (`tests/exec.zig:16082`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed proxy bytecode trap continuations preserve nested calls throws and invariants」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const key = ["__zjs_computed_", "proxy_probe__"].join(""); const symbolKey = Symbol("computed proxy probe"); const symbolOwn = {}; Object.de`。约 1 个 Zig expect、40 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "native tail calls preserve iterator and proxy continuation success and throws"` (`tests/exec.zig:16308`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：tail calls preserve iterator and proxy continuation success and throws。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let nextIndex = 0; const nativeResultIterator = {     results: [         { value: 43, done: false },         { done: true },     ],     [Sym`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "return conditional followed by newline comma keeps the comma expression"` (`tests/exec.zig:16377`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「return conditional followed by newline comma keeps the comma expression」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function choose(condition) {   return condition ? 1 : 2   , 42; } assert.sameValue(choose(true), 42); assert.sameValue(choose(false), 42);`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Phase 7: inlined arrow keeps lexical this and ignores any receiver"` (`tests/exec.zig:16392`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Phase 7: inlined arrow keeps lexical this and ignores any receiver」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const lex = { tag: "LEX" }; function make() { return () => this.tag; } const bound = make.call(lex); print(bound()); print(bound.call()); co`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "arrow direct eval reads captured this and new.target"` (`tests/exec.zig:16412`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow direct eval reads captured this and new.target」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function Replacement() {} function Factory() {     const expectedThis = this;     return () => [eval("this") === expectedThis, eval("new.tar`；`this`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "direct eval inherits QuickJS entry capabilities and var environment"` (`tests/exec.zig:16432`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval inherits QuickJS entry capabilities and var environment」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.SyntaxError`。脚本/输入：`class Base { constructor(value) { this.value = value; } } class Derived extends Base { constructor() { eval("super(7)"); } } assert.sameValu`；`class Parent { method() {} } class Child extends Parent {   method() { function nested() { return super.method(); } } }`。约 2 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "class field direct eval keeps QuickJS field initializer capabilities"` (`tests/exec.zig:16466`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class field direct eval keeps QuickJS field initializer capabilities」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`class FieldBase { get value() { return 41; } } class FieldDerived extends FieldBase { field = eval("super.value + 1"); } assert.sameValue(ne`；`super.value + 1`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "public instance fields initialize once in constructor order on every path"` (`tests/exec.zig:16482`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「public instance fields initialize once in constructor order on every path」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const events = []; const counts = {}; function mark(label, value) {   events.push(label);   counts[label] = (counts[label] || 0) + 1;   retu`。约 1 个 Zig expect、22 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "arrow super property call keeps the enclosing method receiver"` (`tests/exec.zig:16600`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow super property call keeps the enclosing method receiver」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let derivedInstance; class Base {     method() {         assert.sameValue(this, derivedInstance);         return 42;     } } class Derived e`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "super property assignment respects strictness when inherited descriptors reject writes"` (`tests/exec.zig:16632`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「super property assignment respects strictness when inherited descriptors reject writes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const superSetBase = {}; Object.defineProperty(superSetBase, "lockedData", {     value: 1,     writable: false,     configurable: true, }); `。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "bytecode constructability follows canonical function shape"` (`tests/exec.zig:16676`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode constructability follows canonical function shape」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function Ordinary(length) { this.length = length; } const arrow = () => {}; function* generator() {} async function asyncFunction() {} async`。约 1 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "forwarded call releases ignored arrow thisArg"` (`tests/exec.zig:16704`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「forwarded call releases ignored arrow thisArg」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.strictArrowForCall = (function () {     "use strict";     return () => 0; })(); strictArrowForCall.call({ marker: 0 });`；`for (let i = 0; i < 256; i++) {     strictArrowForCall.call({ marker: i }); }`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "function inherited data lookup preserves own and exotic semantics"` (`tests/exec.zig:16739`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function inherited data lookup preserves own and exotic semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function target() {} var intrinsicCall = Function.prototype.call; assert.sameValue(target.call, intrinsicCall); assert.sameValue(target.bind`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "function caller and arguments restrictions follow immutable function shape"` (`tests/exec.zig:16794`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function caller and arguments restrictions follow immutable function shape」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function assertForbidden(fn) {   assert.throws(TypeError, function() { return fn.caller; });   assert.throws(TypeError, function() { return `。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval releases arrow destructuring iterator closures cleanly"` (`tests/exec.zig:16872`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval releases arrow destructuring iterator closures cleanly」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var doneCallCount = 0; var iter = {}; iter[Symbol.iterator] = function() {   return {     next: function() { return { value: null, done: fal`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine eval preserves one-shot object missing field host output semantics"` (`tests/exec.zig:16895`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves one-shot object missing field host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let obj = { a: 1 }; print(obj.b === undefined); let obj2 = { a: 1 }; print(obj2.a === undefined); let oldPrint = print; print = function(x) `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves local string substring host output semantics"` (`tests/exec.zig:16914`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves local string substring host output semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let s = "abcdef"; print(s.substring(4, 1)); print(s.substring(2)); print(s.substring()); let oldSubstring = String.prototype.substring; Stri`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "String prim_self leaf arms (lane K) agree with the legacy bodies on every miss shape"` (`tests/exec.zig:16929`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String prim_self leaf arms (lane K) agree with the legacy bodies on every miss shape」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const s = "abcdefgh"; print(s.charCodeAt(2), s.charAt(2), s.at(2), s.codePointAt(2)); print(s.charCodeAt(8), JSON.stringify(s.charAt(8)), s.`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "String index-read native records preserve primitive fast paths and observable coercion"` (`tests/exec.zig:16970`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「String index-read native records preserve primitive fast paths and observable coercion」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let log = ""; const receiver = { toString() { log += "s"; return "A😀Z"; } }; const index = { valueOf() { log += "i"; return 1; } }; print(St`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "mod cold handler preserves fmod and ToNumeric fallbacks"` (`tests/exec.zig:16992`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「mod cold handler preserves fmod and ToNumeric fallbacks」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const out = []; const show = value => Object.is(value, -0) ? "-0" : String(value); for (const pair of [[5.5, 2], [5, 2.5], [-4, 2], [4, -2],`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine eval preserves resolve-label peephole semantics"` (`tests/exec.zig:17020`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine eval preserves resolve-label peephole semantics」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function probe(v, u) {   let x = 0;   let y;   y = (x = v);   const z = x && y && 9;   function fn() {}   function early() { return; print("`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "resident is_null preserves qjs true and refcounted false legs"` (`tests/exec.zig:17039`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「resident is_null preserves qjs true and refcounted false legs」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const values = [null, undefined, false, true, 0, 1, 1.5, "", Symbol("s"), 1n, {}, [], function() {}]; for (let i = 0; i < values.length; i++`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "Engine generator return keeps finally rethrow control marker"` (`tests/exec.zig:17056`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine generator return keeps finally rethrow control marker」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var obj = { foo: "not modified" }; function* g() {   try { obj.foo = yield; }   finally { return 1; } } var iter = g(); iter.next(); var res`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "generator return runs nested finally before closing its for-of iterator"` (`tests/exec.zig:17077`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator return runs nested finally before closing its for-of iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const events = []; let step = 0; const iterator = {   [Symbol.iterator]() { return this; },   next() { return step++ === 0 ? { value: 1, don`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "return cleanup restores outer catch targets before finally and IteratorClose throws"` (`tests/exec.zig:17111`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「return cleanup restores outer catch targets before finally and IteratorClose throws」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let finallyCount = 0; function catchReturnFinallyThrow() {   try {     throw "try";   } catch (error) {     return "catch";   } finally {   `。约 1 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "generator return crosses catch markers before closing its for-of iterator"` (`tests/exec.zig:17170`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator return crosses catch markers before closing its for-of iterator」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const events = []; let step = 0; const iterator = {   [Symbol.iterator]() { return this; },   next() { return { value: ++step, done: false }`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "generator return closes an inner for-of iterator before its enclosing finally"` (`tests/exec.zig:17210`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator return closes an inner for-of iterator before its enclosing finally」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const events = []; let step = 0; const iterator = {   [Symbol.iterator]() { return this; },   next() { return { value: ++step, done: false }`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "destructuring rest parameter defaults use the parameter environment"` (`tests/exec.zig:17259`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「destructuring rest parameter defaults use the parameter environment」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`let binding = "outer"; function value(...[get = () => binding]) {   var binding = "body";   return get(); } assert.sameValue(value(), "outer`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "caught destructuring error preserves IteratorClose output"` (`tests/exec.zig:17280`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「caught destructuring error preserves IteratorClose output」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const iterator = {   [Symbol.iterator]() { return this; },   next() { return { value: undefined, done: false }; },   return() { print("CLOSE`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "generator parameter eval cells close before body resume"` (`tests/exec.zig:17292`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator parameter eval cells close before body resume」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var x = 'outside'; var first, second, body; function* g(   _ = (eval('var x = "inside";'), first = function() { return x; }),   __ = second `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "generator return executes an add_loc-terminated shared finally before completing"` (`tests/exec.zig:17311`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator return executes an add_loc-terminated shared finally before completing」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function* g() {   var s = 0;   try { yield 1; } finally { s += 1; }   s += 100;   yield s; } var it = g(); var first = it.next(); var second`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "generator default argument stores release refcounted stack values"` (`tests/exec.zig:17332`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator default argument stores release refcounted stack values」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var f = function*(x = arguments[2], y = arguments[3], z) {}; f(undefined, undefined, 'third', 'fourth').next();`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "spread super brands derived instances before class field initializers"` (`tests/exec.zig:17344`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「spread super brands derived instances before class field initializers」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(function () {   class A { constructor(a, b) { this.s = (a | 0) + (b | 0); } }   class B extends A {     #m() { return this.s + 7; }     v =`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "computed class keys close over runtime private field identity"` (`tests/exec.zig:17368`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed class keys close over runtime private field identity」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let probe; class Box {   #value;   [probe = (candidate => #value in candidate)] = 0; } const box = new Box(); assert.sameValue(probe(box), t`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "nested same-name private fields isolate repeated class evaluations"` (`tests/exec.zig:17386`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested same-name private fields isolate repeated class evaluations」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function makePair(outerInitial, innerInitial) {   let outerProbe;   class Outer {     #value = outerInitial;     [outerProbe = (candidate =>`。约 1 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "private fields isolate class evaluations and preserve lexical call and eval semantics"` (`tests/exec.zig:17430`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「private fields isolate class evaluations and preserve lexical call and eval semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__execPrivateFieldRegression = (function () {   function makePrivateBox(instanceInitial, staticInitial) {     return class Privat`；`(function ({ First, Second, first, second }) {   assert.sameValue(     First.hasInstance(first),     true,     "first factory evaluation rec`。约 0 个 Zig expect、22 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "private method brands use lexical initializers on every constructor path"` (`tests/exec.zig:17556`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「private method brands use lexical initializers on every constructor path」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`class ExplicitBase {   #method() { return 1; }   constructor() {}   read() { return this.#method(); }   hasBrand() { return #method in this;`。约 1 个 Zig expect、8 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "private methods and accessors preserve brands captures and readonly semantics"` (`tests/exec.zig:17614`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「private methods and accessors preserve brands captures and readonly semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__execPrivateMethodAccessorRegression = (function () {   function makePrivateMembers(instanceInitial, staticInitial) {     return`；`(function ({ First, Second, first, second }) {   assert.sameValue(First.hasInstanceMethod(first), true, "instance private method #in on owne`。约 0 个 Zig expect、42 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "started generator resumes preserve unmapped arguments from parked locals"` (`tests/exec.zig:17833`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「started generator resumes preserve unmapped arguments from parked locals」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function* strictGenerator(value) {   "use strict";   const first = arguments;   value = 17;   yield;   const shorthand = { arguments };   as`；`arguments`。约 1 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "array named proto field uses ordinary lookup; length and index stay exotic"` (`tests/exec.zig:17888`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「array named proto field uses ordinary lookup; length and index stay exotic」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const a = [7]; assert.sameValue(a.push, Array.prototype.push); assert.sameValue(a.noSuchNamed, undefined); assert.sameValue(a.length, 1); as`。约 1 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "iterator results use ordinary transitions without a sixth realm shape"` (`tests/exec.zig:17909`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「iterator results use ordinary transitions without a sixth realm shape」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "bytecode closures reuse the final function-prototype shape"` (`tests/exec.zig:17933`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode closures reuse the final function-prototype shape」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "escaped closure keeps its compile realm after facade destruction"` (`tests/exec.zig:17956`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「escaped closure keeps its compile realm after facade destruction」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "standard constructors publish realm class prototype slots"` (`tests/exec.zig:17998`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「standard constructors publish realm class prototype slots」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "FunctionRealm query separates owned carriers from caller-semantics classes"` (`tests/exec.zig:18033`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FunctionRealm query separates owned carriers from caller-semantics classes」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.TypeError`。脚本/输入：`(function () {     var other = $262.createRealm().global;     other.eval("globalThis.bytecodeCarrier = function () {};");     var data = Pro`；`globalThis.bytecodeCarrier = function () {};`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "async resume callbacks remain callable and nonconstructible to all consumers"` (`tests/exec.zig:18076`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async resume callbacks remain callable and nonconstructible to all consumers」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`assert.sameValue(typeof internalResumeCallback, 'function'); assert.sameValue(Object.prototype.toString.call(internalResumeCallback), '[obje`。约 0 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await queues a direct resume and retains suspended values"` (`tests/exec.zig:18098`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fulfilled await queues a direct resume and retains suspended values」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.resumeCount = 0; globalThis.awaitProbe = async function (value) {     const result = await value;     resumeCount++;     return r`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await checks state after the constructor getter settles its input"` (`tests/exec.zig:18170`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fulfilled await checks state after the constructor getter settles its input」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let release; globalThis.getterReads = 0; const input = new Promise(resolve => { release = resolve; }); Object.defineProperty(input, 'constru`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await roots its continuation through constructor getter GC"` (`tests/exec.zig:18199`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fulfilled await roots its continuation through constructor getter GC」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.awaitInput = Promise.resolve(Symbol('constructor-root')); Object.defineProperty(awaitInput, 'constructor', {get() { return Promis`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "pending and rejected await retain both callbacks and execute rejection recovery"` (`tests/exec.zig:18261`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「pending and rejected await retain both callbacks and execute rejection recovery」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.input = new Promise(() => {}); globalThis.awaitProbe = async function () {     try { return await input; } catch (reason) { retur`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "async direct settlement preserves adoption self resolution and once guards"` (`tests/exec.zig:18301`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async direct settlement preserves adoption self resolution and once guards」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`let reads = 0, calls = 0, phase = 'sync'; const adopted = (async () => ({ get then() {     reads++;     return function (resolve, reject) { `；`assert.sameValue(directSettlementDone, true);`。约 0 个 Zig expect、12 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "async resume callbacks preserve thenable metadata microtasks and realms"` (`tests/exec.zig:18345`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async resume callbacks preserve thenable metadata microtasks and realms」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function check(v, m) { if (!v) throw Error(m); } const events = []; const originalThen = Promise.prototype.then; let release; const pending `；`assert.sameValue(globalThis.__asyncCallbackDone, true);`。约 0 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator async and wrapper noncarriers derive cross-realm state across GC"` (`tests/exec.zig:18402`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator async and wrapper noncarriers derive cross-realm state across GC」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。强制 major / 环回收后比对 `liveCount` 或对象身份。脚本/输入：`globalThis.__w1b3eOther = $262.createRealm().global; __w1b3eOther.eval("globalThis.w1b3eSync = function* () { yield globalThis; return globa`；`var __w1b3eLocalGeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype); var __w1b3eLocalNext = __w1b3eLocalGeneratorPrototype`。约 8 个 Zig expect、15 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "FinalizationRegistry cleanup job keeps registry realm before invoking callback realm"` (`tests/exec.zig:18493`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「FinalizationRegistry cleanup job keeps registry realm before invoking callback realm」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "event-loop caller reaches external C function with one callee realm view"` (`tests/exec.zig:18569`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「event-loop caller reaches external C function with one callee realm view」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     globalThis.__calleeRealm = $262.createRealm().global;     globalThis.__callerRealm = $262.createRealm().global; })();`；`globalThis.__eventLoopWrapper = function () {     globalThis.__caller_body_ran = true;     try {         __escapedNative();     } catch (err`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "true C function without its RealmRef fails the final-arm invariant"` (`tests/exec.zig:18646`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「true C function without its RealmRef fails the final-arm invariant」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。用 `expectError` 钉失败路径。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "legacy output writer failure is a catchable named Error"` (`tests/exec.zig:18672`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「legacy output writer failure is a catchable named Error」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `Error:WriteFailed`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "native host error sentinel always has a pending named JS exception"` (`tests/exec.zig:18698`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：host error sentinel always has a pending named JS exception。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "generator creation avoids a second payload copy of rooted input slices"` (`tests/exec.zig:18719`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator creation avoids a second payload copy of rooted input slices」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.__argumentGenerator = function* () {};`；`globalThis.__captureGenerator = (function () { var captured = {}; return function* () { yield captured; }; })();`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Engine generator return propagates an explicit finally throw"` (`tests/exec.zig:18839`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine generator return propagates an explicit finally throw」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var syncError = new Error('sync'); function* syncGenerator() {   try { yield 1; } finally { throw syncError; } } var syncIterator = syncGene`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "async generator return awaits for-await iterator close before completing"` (`tests/exec.zig:18871`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async generator return awaits for-await iterator close before completing」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var closeCalls = 0; var awaitCalls = 0; var iterable = {}; iterable[Symbol.asyncIterator] = function() {   return {     next: function() { r`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "async generator return closes an inner iterator before its enclosing finally"` (`tests/exec.zig:18899`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async generator return closes an inner iterator before its enclosing finally」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`const events = []; const iterable = {   [Symbol.asyncIterator]() {     return {       next() { return Promise.resolve({ value: 1, done: fals`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "async generator return awaits its value once before a yielding finalizer"` (`tests/exec.zig:18926`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async generator return awaits its value once before a yielding finalizer」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`let awaitCount = 0; const returned = { then(resolve) { awaitCount++; resolve(7); } }; async function* values() {   try { yield 1; }   finall`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "Engine runJobs preserves pending JS exceptions for callers"` (`tests/exec.zig:18968`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Engine runJobs preserves pending JS exceptions for callers」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var __zjs_timer_throw = function() { throw new Error('timer boom'); };`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "external host arbitrary errors retain their Zig error name"` (`tests/exec.zig:18987`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「external host arbitrary errors retain their Zig error name」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`try { hostNamedError(); } catch (error) { globalThis.__hostNamedError = error.name + ':' + error.message; }`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `Error:HostProbeFailure`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "dynamic import failures preserve unsupported not-found and host I/O mappings"` (`tests/exec.zig:19008`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic import failures preserve unsupported not-found and host I/O mappings」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "static module read failures are named JS exceptions"` (`tests/exec.zig:19077`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「static module read failures are named JS exceptions」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "stalled module host progress is a named InternalError"` (`tests/exec.zig:19112`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「stalled module host progress is a named InternalError」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "host module graph syntax diagnostics do not write to program output"` (`tests/exec.zig:19139`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host module graph syntax diagnostics do not write to program output」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "host commonjs wrapper passes directory dirname"` (`tests/exec.zig:19169`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host commonjs wrapper passes directory dirname」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module graph evaluates block var declarations as module bindings"` (`tests/exec.zig:19205`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module graph evaluates block var declarations as module bindings」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module evaluation does not skip a body-leading function expression"` (`tests/exec.zig:19231`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：module evaluation does not skip a body-leading function expression。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module evaluation does not mistake a body-leading this branch for a hoist prologue"` (`tests/exec.zig:19252`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：module evaluation does not mistake a body-leading this branch for a hoist prologue。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module cycles initialize wide function declaration closures before evaluation"` (`tests/exec.zig:19274`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module cycles initialize wide function declaration closures before evaluation」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module cycles do not hoist a body-leading named function expression"` (`tests/exec.zig:19331`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module cycles do not hoist a body-leading named function expression」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "W1e: module namespace exposes sorted immutable live export properties"` (`tests/exec.zig:19378`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1e: module namespace exposes sorted immutable live export properties」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、17 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module namespace has and super set preserve uninitialized export semantics"` (`tests/exec.zig:19446`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module namespace has and super set preserve uninitialized export semantics」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "W1e: named aliases and namespace reexports share live canonical bindings"` (`tests/exec.zig:19502`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1e: named aliases and namespace reexports share live canonical bindings」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "W1e: missing indirect export precedes bad import wiring"` (`tests/exec.zig:19559`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1e: missing indirect export precedes bad import wiring」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "W1e: one host source load spans declaration body TLA resume and dynamic import"` (`tests/exec.zig:19611`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1e: one host source load spans declaration body TLA resume and dynamic import」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、9 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "same module specifier keeps record cells namespace import meta and error state per Realm"` (`tests/exec.zig:19682`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「same module specifier keeps record cells namespace import meta and error state per Realm」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1; export let value = 11; export function realmFunction() { return value; } export cons`；`globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1; export let value = 22; export function realmFunction() { return value; } export cons`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "context module eval does not rerun evaluated or errored records"` (`tests/exec.zig:19749`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：context module eval does not rerun evaluated or errored records。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。用 `expectError` 钉失败路径。脚本/输入：`globalThis.__contextEvaluatedRuns =   (globalThis.__contextEvaluatedRuns || 0) + 1; export const value = 1;`；`globalThis.__contextEvaluatedRuns += 100; export const value = 2;`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "context module eval resumes TLA from its reaction FIFO position"` (`tests/exec.zig:19804`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「context module eval resumes TLA from its reaction FIFO position」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`const actual = []; let resolveAwaited; const awaited = new Promise(resolve => resolveAwaited = resolve); awaited.then(() => actual.push("bef`；`assert.sameValue(   globalThis.__contextTlaResult,   "before,module:42,after|tla rejection" );`。约 0 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "Runtime loader keeps same-path TLA continuations and waiters in parent and child Realms"` (`tests/exec.zig:19839`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Runtime loader keeps same-path TLA continuations and waiters in parent and child Realms」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 19 处 `std.testing.expect*`。约 19 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module top-level await resumes in Promise reaction FIFO order"` (`tests/exec.zig:19936`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module top-level await resumes in Promise reaction FIFO order」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module await reaction keeps its position on the awaited Promise"` (`tests/exec.zig:19974`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module await reaction keeps its position on the awaited Promise」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "module TLA continuation OOM retains FIFO node for retry"` (`tests/exec.zig:20005`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：module TLA continuation OOM retains FIFO node for retry。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.OutOfMemory`。脚本/输入：`globalThis.__paRetry = import("./a.mjs"); globalThis.__pbRetry = import("./b.mjs");`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "async module dependency does not preempt an independent sibling"` (`tests/exec.zig:20148`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：async module dependency does not preempt an independent sibling。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "import bytes module creates immutable ArrayBuffer backing store"` (`tests/exec.zig:20204`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「import bytes module creates immutable ArrayBuffer backing store」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "host global bootstrap installs and tears down builtin plus host domains"` (`tests/exec.zig:20332`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「host global bootstrap installs and tears down builtin plus host domains」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。再 `JSContext.create`、`Object.create` 建 global 并 `ensureRealmPayload`，最后 `helpers.installHostGlobalsBare(rt, global)` 装 builtin + host 两域。无显式断言：装/拆不对称由 `defer ctx.destroy()` / `defer rt.destroy()` 之后的测试分配器泄漏检查暴露。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "engine eval host globals and throw intrinsic tear down cleanly"` (`tests/exec.zig:20344`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「engine eval host globals and throw intrinsic tear down cleanly」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "reflect construct roots argument list while resolving prototype"` (`tests/exec.zig:20395`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「reflect construct roots argument list while resolving prototype」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "short conditional branches preserve immediate and full ToBoolean semantics"` (`tests/exec.zig:20466`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「short conditional branches preserve immediate and full ToBoolean semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function choose(value) { if (value) return 1; return 0; } function orValue(value) { return value || 9; } function andValue(value) { return v`。约 1 个 Zig expect、16 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "if-throw fall-off form returns undefined (if_false8 branch-to-end)"` (`tests/exec.zig:20494`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「if-throw fall-off form returns undefined (if_false8 branch-to-end)」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fallOffIfThrow(x) { if (x) throw 1; } assert.sameValue(fallOffIfThrow(false), undefined); var threw = false; try { fallOffIfThrow(t`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "if-return fall-off form returns undefined on the fall-through leg"` (`tests/exec.zig:20508`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「if-return fall-off form returns undefined on the fall-through leg」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fallOffIfReturn(x) { if (x) return 1; } assert.sameValue(fallOffIfReturn(true), 1); assert.sameValue(fallOffIfReturn(false), undefi`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "else-return goto-to-end form returns undefined on the taken if leg"` (`tests/exec.zig:20520`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「else-return goto-to-end form returns undefined on the taken if leg」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fallOffElseReturn(x) { if (x) { 1; } else return 2; } assert.sameValue(fallOffElseReturn(true), undefined); assert.sameValue(fallOf`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "nested-block branch-to-end survives trailing scope cleanup lowering"` (`tests/exec.zig:20532`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested-block branch-to-end survives trailing scope cleanup lowering」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function fallOffNestedBlock(c) { { let x; if (c) throw 1; } } assert.sameValue(fallOffNestedBlock(false), undefined); function fallOffCaptur`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "arrow block body branch-to-end returns undefined"` (`tests/exec.zig:20549`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow block body branch-to-end returns undefined」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`var fallOffArrow = (x) => { if (x) throw 3; }; assert.sameValue(fallOffArrow(false), undefined); var fallOffArrowReturn = (x) => { if (x) re`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "generator branch-to-end completes with undefined value"` (`tests/exec.zig:20563`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generator branch-to-end completes with undefined value」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function* fallOffGen(x) { if (x) throw 4; yield 1; } var it = fallOffGen(false); assert.sameValue(it.next().value, 1); var r = it.next(); as`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "eval and script completion end in an explicit value return"` (`tests/exec.zig:20582`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：and script completion end in an explicit value return。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(eval("if (false) throw 5;"), undefined); assert.sameValue(eval("1 + 2"), 3); assert.sameValue(eval("{ let x; if (false) thr`；`if (false) throw 5;`。约 3 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "eval preserves completion through nested shared finalizers"` (`tests/exec.zig:20603`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：preserves completion through nested shared finalizers。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`assert.sameValue(eval("1; try { 2; } finally { 3; }"), 2); assert.sameValue(eval("1; try { try { 2; } finally { 3; } } finally { 4; }"), 2);`；`1; try { 2; } finally { 3; }`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "module top-level branch-to-end gets a terminator (no fall-off)"` (`tests/exec.zig:20615`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module top-level branch-to-end gets a terminator (no fall-off)」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`if (false) throw 9;`。无 Zig 断言：判定全在 `evalModule` 的脚本里，条件不成立就 `throw`，异常经 eval 冒泡成测试失败。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "W1d: module import.meta identity survives methods and nested closures"` (`tests/exec.zig:20624`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1d: module import.meta identity survives methods and nested closures」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`const rootMeta = import.meta; class Holder {   read() { return import.meta; } } function nested() {   const arrow = () => import.meta;   ret`。无 Zig 断言：判定全在 `evalModule` 的脚本里，三处 `import.meta` 身份不等就 `throw new Error("import.meta identity escaped its module")`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "module function declaration cells do not leak onto the global object"` (`tests/exec.zig:20646`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module function declaration cells do not leak onto the global object」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function __moduleLocalHoist() {} export function __moduleExportHoist() {} export default function __moduleDefaultHoist() {}`；`assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleLocalHoist"), false); assert.sameValue(Object.prototype.hasOwnPro`。约 0 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "call consumers derive receiver and direct-eval provenance from the final opcode"` (`tests/exec.zig:20663`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「call consumers derive receiver and direct-eval provenance from the final opcode」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言错误 `error.SyntaxError`。脚本/输入：`(function () {   const __call_consumer_local = 17;   const holder = { get() { return eval; } };   assert.sameValue(holder.get()("typeof __ca`；`const optionalWithScope = { method() { return this; } }; with (optionalWithScope) method?.();`。约 2 个 Zig expect、11 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "optional chains use one unbounded shared label and preserve closed-chain calls"` (`tests/exec.zig:20716`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「optional chains use one unbounded shared label and preserve closed-chain calls」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "direct eval inside a module function forwards module live bindings"` (`tests/exec.zig:20740`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval inside a module function forwards module live bindings」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`export let moduleDirectEvalBinding = 37; export function readModuleBindingByEval() {   return eval("moduleDirectEvalBinding"); } assert.same`；`moduleDirectEvalBinding`。约 0 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "dynamic global put keeps cell and global-object legs semantically separate"` (`tests/exec.zig:20753`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic global put keeps cell and global-object legs semantically separate」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "get_var uninitialized-cell inline global-object leg preserves the cold waterfall semantics"` (`tests/exec.zig:20863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「get_var uninitialized-cell inline global-object leg preserves the cold waterfall semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`globalThis.__q1 = (function () {   var out = [];   function readUndef() { return undefined; }   var hot = 0;   for (var i = 0; i < 3000; i++`；`var undefined=9`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "named function expression self-binding materializes lazily with pinned QuickJS semantics"` (`tests/exec.zig:20930`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「named function expression self-binding materializes lazily with pinned QuickJS semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`globalThis.__q2 = (function () {   var out = [];   var f = function rec(){ return rec; };   out.push(f() === f);                            `。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "K2 warm leaf miss retreat keeps call accounting balanced across chunk and carve misses"` (`tests/exec.zig:21010`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「K2 warm leaf miss retreat keeps call accounting balanced across chunk and carve misses」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "latin1 high bytes survive raw-string byte bridges (qjs JS_ToCStringLen2 mirror)"` (`tests/exec.zig:21068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「latin1 high bytes survive raw-string byte bridges (qjs JS_ToCStringLen2 mirror)」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(function () {     var out = [];     var f = function () {};     Object.defineProperty(f, "name", { value: "é" });     out.push(f.bind(null)`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `true,true,true,true,true,true,true,true,true,true,true`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "ToNumber latin1 high bytes are code points not UTF-8 whitespace"` (`tests/exec.zig:21115`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ToNumber latin1 high bytes are code points not UTF-8 whitespace」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`var s = String.fromCharCode(0xE2,0x80,0x80) + "1"; print("len="+s.length+" cc="+s.charCodeAt(0)+","+s.charCodeAt(1)+","+s.charCodeAt(2)+","+`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "JSON.rawJSON latin1 payload survives the simple stringify byte buffer"` (`tests/exec.zig:21181`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「JSON.rawJSON latin1 payload survives the simple stringify byte buffer」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`[     JSON.stringify(JSON.rawJSON('"é"')) === '"é"',     JSON.stringify({ x: JSON.rawJSON('"é"') }, null, 1) === '{\n "x": "é"\n}', ].join("`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `true,true`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "native function toString keeps non-ASCII identifier names (qjs js_function_toString)"` (`tests/exec.zig:21196`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住原生/内建：function toString keeps non-ASCII identifier names (qjs js_function_toString)。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`(function () {     Object.defineProperty(Math.max, "name", { value: "ém", configurable: true });     return Math.max.toString() === "functio`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "switch dispatch trampoline shapes keep their identity and semantics"` (`tests/exec.zig:21212`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「switch dispatch trampoline shapes keep their identity and semantics」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`(function () {     function run(f) {         var parts = [];         var inputs = [1, 2, 3, 9];         for (var i = 0; i < inputs.length; i`。断言不走 `std.testing.expect*`，而是 `helpers.expectStringValueBytes` 比对求值结果字符串 `ab,b,b,b|b,b,b,b|ab,b,b,b|x,x,x,x|b,b,b,b|abc,bc,c,bc|z,z,z,z|ya,y,y,y|3|qd,qd,q,qd|a,b,,b|rw|e,e,e,e|a,,,|L,L,L,L|na,n,n,n`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "top-level direct eval does not break private-name eval resolution"` (`tests/exec.zig:21350`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：top-level direct eval does not break private-name eval resolution。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`class C {   #f = 1;   get #g(){ return 2; }   #p(){ return 3; }   read(){ return eval("this.#f"); }   getg(){ return eval("this.#g"); }   ca`；`this.#f`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "switch fallthrough after while-family tails reaches the next case"` (`tests/exec.zig:21378`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「switch fallthrough after while-family tails reaches the next case」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`function run(body){   var r=[];   switch(0){     case 0: body();     case 1: r.push("b"); break;     default: r.push("d");   }   return r.jo`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "small-function-inlining: sc_Pair constructor is eligible and arguments ctor is not"` (`tests/exec.zig:21414`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: sc_Pair constructor is eligible and arguments ctor is not」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function sc_Pair(car, cdr) { this.car = car; this.cdr = cdr; } function usesArgs() { return arguments[0]; } function big(a,b,c,d,e) { this.a`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: setter throw stack is setter, ctor, caller"` (`tests/exec.zig:21440`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: setter throw stack is setter, ctor, caller」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C(v) { this.x = v; } function outer(v) { return new C(v); } var i; for (i = 0; i < 16; i++) outer(i); Object.defineProperty(C.proto`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: redefinition takes the new function"` (`tests/exec.zig:21465`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: redefinition takes the new function」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function m1() { return 1; } function m2() { return 2; } var o = { m: m1 }; function outer(obj) { return obj.m(); } var i, last; for (i = 0; `。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: new C field write is visible"` (`tests/exec.zig:21481`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: new C field write is visible」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { this.x = 1; } function outer() { return new C(); } var i, o; for (i = 0; i < 16; i++) o = outer(); assert.sameValue(o.x, 1);`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: polymorphic site is not specialized"` (`tests/exec.zig:21494`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: polymorphic site is not specialized」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function A(v) { this.v = v; } function B(v) { this.v = v + 1; } function outer(C, v) { return new C(v); } var i, last; for (i = 0; i < 20; i`。约 3 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: R-2 getter on callee is invoked once per new"` (`tests/exec.zig:21525`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: R-2 getter on callee is invoked once per new」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var n = 0; function RealC(v) { this.x = v; } Object.defineProperty(globalThis, "C", {   get: function () { n += 1; return RealC; },   config`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: inner throw stack and caller catch"` (`tests/exec.zig:21545`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: inner throw stack and caller catch」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function inner() { throw new Error("x"); } function outer() { return inner(); } var i; for (i = 0; i < 16; i++) { try { outer(); } catch (e)`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: primitive ctor return keeps instance"` (`tests/exec.zig:21564`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: primitive ctor return keeps instance」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { this.x = 1; return 0; } function outer() { return new C(); } var i, o; for (i = 0; i < 16; i++) o = outer(); assert.sameValue`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: Reflect.construct with foreign NewTarget is not expanded"` (`tests/exec.zig:21578`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: Reflect.construct with foreign NewTarget is not expanded」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C(v) { this.x = v; } function NT() {} NT.prototype = { mark: 1 }; function outer(v) { return Reflect.construct(C, [v], NT); } var i`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: derived class constructor is not eligible"` (`tests/exec.zig:21594`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: derived class constructor is not eligible」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`class B {} class D extends B { constructor(v) { super(); this.x = v; } } globalThis.__d = D;`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: next-entry specialize is installed on the caller"` (`tests/exec.zig:21608`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: next-entry specialize is installed on the caller」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Three(a, b, c) { this.x = a; this.y = b; this.z = c; } function batch(n) {   var i, s = 0, p;   for (i = 0; i < n; i++) { p = new T`。约 4 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: spec copy keeps simple_inline bits after extra TAKE locals"` (`tests/exec.zig:21633`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: spec copy keeps simple_inline bits after extra TAKE locals」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C(v) { this.x = v; } function outer(v) { return new C(v); } globalThis.__outer = outer; var i, last; for (i = 0; i < 16; i++) last `。约 13 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: sibling constructor sites both specialize"` (`tests/exec.zig:21667`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: sibling constructor sites both specialize」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Pair(a, b) { this.x = a; this.y = b; } function both(a, b) {   var p = new Pair(a, b);   var q = new Pair(b, a);   return p.x + q.x`。约 3 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: proto replacement after specialize is observed"` (`tests/exec.zig:21693`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: proto replacement after specialize is observed」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C(v) { this.x = v; } function outer(v) { return new C(v); } var i, o; for (i = 0; i < 16; i++) o = outer(i); C.prototype = { mark: `。约 1 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: call_constructor callers keep published frame geometry"` (`tests/exec.zig:21713`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: call_constructor callers keep published frame geometry」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C(v) { this.x = v; } function outer(v) { return new C(v); } globalThis.__outer = outer;`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: leftover-operand bodies are not small-inline eligible"` (`tests/exec.zig:21731`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: leftover-operand bodies are not small-inline eligible」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function leftoverDrop() { ({ z: 1 }); } function leftoverSwitch() { switch ({ x: 7 }) { default: return 5; } } function leftoverCtor() { ({ `。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: leftover ctor is not specialized and does not overflow"` (`tests/exec.zig:21755`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：small-function-inlining: leftover ctor is not specialized and does not overflow。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { ({ z: 1 }); } function outer() { return new C(); } var i, last; for (i = 0; i < 256; i++) last = outer(); assert.sameValue(ty`。约 3 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: extra ctor args do not overwrite callee fields"` (`tests/exec.zig:21779`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: extra ctor args do not overwrite callee fields」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Pair(a, b) { this.x = a; this.y = b; } function outer() { return new Pair(1, 2, { leak: 1 }); } var i, last; for (i = 0; i < 16; i+`。约 3 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining: monomorphic method is expanded"` (`tests/exec.zig:21802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining: monomorphic method is expanded」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function Box(v) { this.v = v; } Box.prototype.inc = function () { return this.v + 1; }; function outer(b) { return b.inc(); } var i, last, b`。约 1 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: apply-arguments ctor specializes"` (`tests/exec.zig:21816`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining L1: apply-arguments ctor specializes」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function K() { this.initialize.apply(this, arguments); } K.prototype.initialize = function (a, b) { this.a = a; this.b = b; }; function oute`。约 5 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: next-entry take does not leak initialize return"` (`tests/exec.zig:21842`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：small-function-inlining L1: next-entry take does not leak initialize return。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function K() { this.initialize.apply(this, arguments); } K.prototype.initialize = function (a, b) { this.a = a; this.b = b; }; function batc`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: forwarded argc is the site argc"` (`tests/exec.zig:21859`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining L1: forwarded argc is the site argc」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function K() { this.initialize.apply(this, arguments); } K.prototype.initialize = function () { this.n = arguments.length; }; function outer`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: Error.stack is initialize, apply native, ctor"` (`tests/exec.zig:21874`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining L1: Error.stack is initialize, apply native, ctor」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { this.initialize.apply(this, arguments); } C.prototype.initialize = function init(a) { this.a = a; throw new Error("boom"); };`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: own apply misses take"` (`tests/exec.zig:21897`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining L1: own apply misses take」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { this.initialize.apply(this, arguments); } C.prototype.initialize = function (a) { this.a = a; this.via = "init"; }; function `。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "small-function-inlining L1: replaced Function.prototype.apply misses take"` (`tests/exec.zig:21916`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「small-function-inlining L1: replaced Function.prototype.apply misses take」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function C() { this.initialize.apply(this, arguments); } C.prototype.initialize = function (a) { this.a = a; }; function outer(v) { return n`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "flat string strict-eq matches content across distinct objects"` (`tests/exec.zig:21941`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「flat string strict-eq matches content across distinct objects」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function check(cond) { if (!cond) throw new Error("streq"); } var lit = "k0"; var made = "k" + 0; var other = "k32"; var empty_a = ""; var e`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "active invocation Adapter traces live VM windows and not unused stack capacity"` (`tests/exec.zig:22103`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「active invocation Adapter traces live VM windows and not unused stack capacity」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function holdHidden() {     const hidden = { marker: 1 };     const ok = activeInvocationProbe();     return [ok, hidden]; } holdHidden();`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "C0: final artifacts carry the carrier encoding and no direct to_propkey"` (`tests/exec.zig:22136`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C0: final artifacts carry the carrier encoding and no direct to_propkey」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function c0ComputedKey(k){ return { [k]: 1 }; }`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "C0: a throw inside key coercion attributes the frame to the carrier's source pc"` (`tests/exec.zig:22211`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C0: a throw inside key coercion attributes the frame to the carrier's source pc」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function maker(bad){   return { [bad]: 1 }; } var boom = { [Symbol.toPrimitive]: function(){ throw new Error("bt"); } }; var captured; try {`。约 1 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "C0 closed: the carrier encoding executes and the quarantined direct id is rejected"` (`tests/exec.zig:22228`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C0 closed: the carrier encoding executes and the quarantined direct id is rejected」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。用 `expectError` 钉失败路径。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "C0/D7: an unknown carrier tag is rejected by the artifact proof and by dispatch"` (`tests/exec.zig:22252`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C0/D7: an unknown carrier tag is rejected by the artifact proof and by dispatch」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言错误 `error.InvalidFinalArtifact`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "C1-1: computed-name function naming rides the carrier encoding"` (`tests/exec.zig:22273`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「C1-1: computed-name function naming rides the carrier encoding」。
- **实现**：取 `helpers.sharedTestEngine()`，`defer endSharedTest()` 复位全局与泄漏门。脚本/输入：`function mk(k){ return { [k]: function(){} }; } assert.sameValue(mk("nm").nm.name, "nm"); assert.sameValue(mk("a" + "b").ab.name, "ab"); var`。约 4 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：共享 Runtime 由 `endSharedTest` 清异常、排空 job、还原全局 shape；泄漏门在 census 第二遍开火。失败以 `error.Test*` 冒泡。

### `test "TGC S3: JSON.parse object keys stay reachable across majors taken mid-parse"` (`tests/exec.zig:22347`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3: JSON.parse object keys stay reachable across majors taken mid-parse」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-c: operand-stack strings stay rooted while a later push materializes its atom"` (`tests/exec.zig:22406`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-c: operand-stack strings stay rooted while a later push materializes its atom」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-d: an inline call's argument region stays rooted while the callee frame is pushed"` (`tests/exec.zig:22586`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-d: an inline call's argument region stays rooted while the callee frame is pushed」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-d: op_put_array_el's cold arm publishes before the dense grow allocates"` (`tests/exec.zig:22662`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-d: op_put_array_el's cold arm publishes before the dense grow allocates」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "TGC S3-d: the string-primitive get_field2 arm publishes before the auto-init resolver allocates"` (`tests/exec.zig:22716`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TGC S3-d: the string-primitive get_field2 arm publishes before the auto-init resolver allocates」。
- **实现**：部分配置下 `return error.SkipZigTest`。直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。强制 major / 环回收后比对 `liveCount` 或对象身份。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "an unresolved binding names its identifier in the ReferenceError message (qjs JS_ThrowReferenceErrorNotDefined)"` (`tests/exec.zig:22764`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「an unresolved binding names its identifier in the ReferenceError message (qjs JS_ThrowReferenceErrorNotDefined)」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`try { zjsUndeclaredRead; } catch (e) { print(e.name + ": " + e.message + " " + (e instanceof ReferenceError)); } try { zjsUndeclaredCall(); `。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "print / console.log dump objects like QuickJS JS_PrintValue (qjs-generated expectations, 36 shapes)"` (`tests/exec.zig:22787`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「print / console.log dump objects like QuickJS JS_PrintValue (qjs-generated expectations, 36 shapes)」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`(function () { print({ a: 1, b: "s", c: null, d: undefined, e: true, f: 1.5, g: -0, h: NaN, i: 1e21, j: 123n, k: -Infinity }); print([ 1, 2,`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

### `test "no-suspend async uses a same-Machine completion boundary"` (`tests/exec.zig:22876`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「no-suspend async uses a same-Machine completion boundary」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function leaf(x) { return x + 1; } var result = leaf(41); assert.sameValue(result instanceof Promise, true); assert.sameValue(Object.p`。约 1 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "no-suspend async preserves parameter exceptions finally aliases and nested boundaries"` (`tests/exec.zig:22890`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「no-suspend async preserves parameter exceptions finally aliases and nested boundaries」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`function fail(x) { throw x; } async function parameters(a = 1, f = () => a) { var a = 2; return [f(), a]; } async function bad(x = fail('par`；`assert.sameValue(e2BoundaryDone, true);`。约 1 个 Zig expect、10 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "no-suspend async leaves suspension eval host-observed cadence and wrappers on fallback"` (`tests/exec.zig:22919`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「no-suspend async leaves suspension eval host-observed cadence and wrappers on fallback」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function suspended() { await 0; return 1; } async function dynamic() { return eval('2'); } async function leaf() { return 3; } suspend`；`leaf();`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "no-suspend async completion roots survive declared-only GC before and after frame pop"` (`tests/exec.zig:22938`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「no-suspend async completion roots survive declared-only GC before and after frame pop」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function nested() { return 8; } async function work() {     __e2BoundaryGC();     return { marker: 'alive', get then() {         __e2B`；`assert.sameValue(e2RootsDone, true);`。约 6 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "no-suspend async final code policy includes hidden suspension and excludes nested bodies"` (`tests/exec.zig:22982`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「no-suspend async final code policy includes hidden suspension and excludes nested bodies」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`async function e2Plain() { return 1; } async function e2Nested() { return async function () { await 0; }; } async function e2ForAwait(xs) { `。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "no-suspend async transfers post-body OOM to FIFO without replay"` (`tests/exec.zig:23008`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：no-suspend async transfers post-body OOM to FIFO without replay。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`var e2OomPromise, e2OomBodyCount = 0, e2OomGetterCount = 0; async function e2OomWork() {     e2OomBodyCount++;     return {marker: 42, get t`；`assert.sameValue(e2OomBodyCount, 1); assert.sameValue(e2OomGetterCount, 1); e2OomPromise.then(v => { assert.sameValue(v.marker, 42); globalT`。约 8 个 Zig expect、4 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap intrinsic then preserves independent results and pending handlers"` (`tests/exec.zig:23068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap intrinsic then preserves independent results and pending handlers」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var wake, pending = new Promise(r => { wake = r; }); var first = pending.then(v => { globalThis.pcapFirst = v; return v + 1; }); var second `；`assert.sameValue(pcapFirst, 41); assert.sameValue(pcapSecond, 8);`。约 3 个 Zig expect、5 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap species observation keeps custom capability handshake"` (`tests/exec.zig:23088`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap species observation keeps custom capability handshake」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var pcapLog = [], marker = {}, source = Promise.resolve(3); function C(executor) {     pcapLog.push('construct');     executor(v => pcapLog.`；`assert.sameValue(pcapLog.join(','), 'constructor,species,construct,handler,resolve:7');`。约 2 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap intrinsic prototype survives species replacing global Promise"` (`tests/exec.zig:23112`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap intrinsic prototype survives species replacing global Promise」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var originalPromise = Promise, pcapSpeciesGets = 0, pcapResult; var source = originalPromise.resolve(9); source.constructor = {get [Symbol.s`；`assert.sameValue(pcapResult, 9);`。约 2 个 Zig expect、3 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap thenable resolution identity thrower and FIFO preserve single observation"` (`tests/exec.zig:23135`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap thenable resolution identity thrower and FIFO preserve single observation」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var pcapOrder = [], pcapGetter = 0, pcapThen = 0, pcapSelf, pcapThrower; var p = Promise.resolve(1), self; self = p.then(() => self); self.c`；`assert.sameValue(pcapOrder.join(','), 'handler,peer,then,result'); assert.sameValue(pcapGetter, 1); assert.sameValue(pcapThen, 1); assert.sa`。约 2 个 Zig expect、7 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap foreign species falls back and delayed foreign settlement keeps self error realm"` (`tests/exec.zig:23161`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap foreign species falls back and delayed foreign settlement keeps self error realm」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var pcapForeign = $262.createRealm(); var source = Promise.resolve(1); source.constructor = {[Symbol.species]: pcapForeign.global.Promise}; `；`assert.sameValue(pcapRealmOK, true);`。约 2 个 Zig expect、2 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap post-handler and post-getter OOM retain FIFO completion without replay"` (`tests/exec.zig:23185`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 OOM 契约：P-Cap post-handler and post-getter OOM retain FIFO completion without replay。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`var pcapBodyCalls = 0, pcapGetterCalls = 0, pcapFinal, pcapChild; function primitive() { pcapBodyCalls++; return __pcapArmOOM(); } function `。约 8 个 Zig expect、6 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "P-Cap retries reserved reaction phase before then getter without replaying handler"` (`tests/exec.zig:23235`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「P-Cap retries reserved reaction phase before then getter without replaying handler」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。断言错误 `error.OutOfMemory`。设置 runtime 内存上限以注入 OOM。脚本/输入：`var pcapReserveGetter = 0, pcapReserveChild; var pcapReserveObject = {marker: 73, get then() { pcapReserveGetter++; return null; }}; functio`；`assert.sameValue(pcapReserveGetter, 1);`。约 9 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await preserves FIFO and bypasses an overridden then"` (`tests/exec.zig:23292`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fulfilled await preserves FIFO and bypasses an overridden then」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`var directOrder = [], directThen = Promise.prototype.then; Promise.prototype.then = function () { throw new Error('observable then'); }; asy`；`if (directOrder.join(',') !== 'start,sync,first,then,second') throw new Error(directOrder);`。无 Zig 断言：第二次 eval 的那行 `if`/`throw` 就是判定——覆写 `Promise.prototype.then` 后 await 仍走内部 FIFO，顺序必须是 start,sync,first,then,second。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await preserves the registration and body realms"` (`tests/exec.zig:23312`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「fulfilled await preserves the registration and body realms」。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。脚本/输入：`globalThis.foreignDirect = async function () { await 0; return new Error('foreign'); };`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "fulfilled await does not replay a resumed body after allocation failure"` (`tests/exec.zig:23341`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：fulfilled await does not replay a resumed body after allocation failure。
- **实现**：独立 `helpers.TestEngine.init(std.testing.allocator)`，`defer deinit`。设置 runtime 内存上限以注入 OOM。脚本/输入：`globalThis.directFail = async function () { await 0; directResumeOOM(); return {marker: 42}; };`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：`TestEngine.deinit` 排空 job、清 atomics waiter、销毁 context/runtime。测试分配器查泄漏。

### `test "print writes top-level strings raw including latin1 high bytes"` (`tests/exec.zig:23380`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「print writes top-level strings raw including latin1 high bytes」。
- **实现**：经 `helpers.expectPrints` 对比 `print` 输出。脚本/输入：`print("ascii", String.fromCharCode(0xC9), { s: String.fromCharCode(0xC9) });`。
- **所有权 / 错误 / 调用**：`helpers.expectPrints`（helpers.zig:126）内部就是 `sharedTestEngine()` + `defer endSharedTest()`，因此本例同样跑在进程级共享 Runtime 上，不是独立引擎。`endSharedTest`（helpers.zig:615）先经 `resetSharedEngineAfterTest`（669）清 context 上的异常与未处理 rejection、排空 job 队列、清 atomics waiter、还原全局 lexical 绑定，再做分配计数对账；泄漏门只在 `zjs_test_runner_current_pass != 0` 且模块表未增长时开火。失败以 `error.Test*` 冒泡。

## 覆盖核对

- 清单函数数: 60
- 本文标题覆盖: 576
- 未覆盖: 无
