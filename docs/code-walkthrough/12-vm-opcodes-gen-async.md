# 12 — generator / async（`vm_gen_async.zig`）

文件职责：`op.initial_yield` / `yield` / `yield_star` / `await` 的驻留与恢复。停车把帧与操作数栈 backing 交给 `GeneratorExecutionState`；打开的 VarRef 挂到 generator 所有者；活 VM 视图清掉，保证 resume/teardown 各值只释放一次。形态对齐 qjs 约 20592。

## 类型

`Result`：`none`（继续跑）/ `continue_loop` / `return_value`（把值交回 VM 作为 yield/await 结果）。

`ResumeState`：`throw_on_entry`（恢复时立刻 throw）+ `catch_target`。

`AwaitSuspendMode`：`none` 不挂起；`settled` 遗留同步排空；`raw` 把原值交给 `Promise.resolve(...).then(resume)`（async 函数、async generator、模块 TLA）。

### `reserveGeneratorExecutionStackAdditional` (`src/exec/vm_opcodes.zig:45`)

- **签名**：`inline fn reserveGeneratorExecutionStackAdditional(rt: *core.JSRuntime, stack: *stack_mod.Stack, execution: *core.object.GeneratorExecutionState, additional: usize) !void`。
- **作用**：恢复前保证停车栈还能再压 resume 值。
- **实现**：已有 len+additional 不超过 stackLimit 与 capacity 则返回。否则 `ensureAdditionalWithResidentBacking`（是否 combined FAM）。
- **所有权 / 错误 / 调用**：可能换缓冲。`resumeExecutionStateRaw`。

### `sameSlice` (`src/exec/vm_opcodes.zig:58`)

- **签名**：`fn sameSlice(comptime T: type, left: []T, right: []T) bool`。
- **作用**：两切片是否同一块内存。
- **实现**：len 相等且（空或 ptr 相等）。
- **所有权 / 错误 / 调用**：`residentFrameViewsMatch`。

### `residentFrameViewsMatch` (`src/exec/vm_opcodes.zig:62`)

- **签名**：`fn residentFrameViewsMatch(state: *const core.object.SuspendedExecutionState, frame: *const frame_mod.Frame) bool`。
- **作用**：活帧窗口是否仍是停车描述符里那份 resident 存储。
- **实现**：storage/locals/args/var_refs/open_var_refs 五对 `sameSlice`。
- **所有权 / 错误 / 调用**：匹配则可 descriptor-free 停车。

### `clearLiveExecutionViews` (`src/exec/vm_opcodes.zig:71`)

- **签名**：`fn clearLiveExecutionViews(stack: *stack_mod.Stack, frame: *frame_mod.Frame) void`。
- **作用**：切断 VM 对已移交缓冲的别名，避免双重释放。
- **实现**：`stack.clearBacking`，关 arena/resident 窗；frame 切片置空，storage borrowed，var_refs owned 空。
- **所有权 / 错误 / 调用**：park 两条路径。

### `parkGeneratorExecutionState` (`src/exec/vm_opcodes.zig:92`)

- **签名**：`fn parkGeneratorExecutionState( rt: *core.JSRuntime, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: *core.Object, execution: *core.object.GeneratorExecutionState, pc: usize, catch_target_pc: u32, has_frame: bool, ) void`。
- **作用**：把活切片停车。常见路径**不搬** resident 帧，只改 cur_sp/cur_pc 式描述符（qjs 一份 JSAsyncFunctionState）。
- **实现**：`rememberOwnerForBulkWrite`。已记账的 header：打开 cell `attachOpenOwner` 到 generator。若仍是 resident 且视图匹配：更新 stack 视图与 pc/catch，clear live；旧栈缓冲若换过且非 combined 则只 `free` 字节（不 dec 槽）。否则 `replaceStorageOwned` 走遗留转移；首次从 combined 长出来仍由 execution-state 分配拥有。
- **所有权 / 错误 / 调用**：无错误（标量已在 save 前校验）。`saveGeneratorExecutionState` / `finishExecutionStateRun`。

### `saveGeneratorExecutionState` (`src/exec/vm_opcodes.zig:193`)

- **签名**：`pub noinline fn saveGeneratorExecutionState( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: *core.Object, pc: usize, catch_target: ?usize, ) !void`。
- **作用**：所有 yield/await 的所有权交接缝。noinline 避免每条 handler 复制 reset/swap。
- **实现**：无 execution → TypeError。assert 非 arena 窗、storage/var_refs owned（或 combined/空）。open_var_refs 长度必须等于 `openVarRefCount`。catch 转 u32，过大 `InvalidBytecode`（失败时活状态完好）。然后 park。
- **所有权 / 错误 / 调用**：yield/await/initial/stopBeforePc。

### `resumeExecutionState` (`src/exec/vm_opcodes.zig:219`)

- **签名**：`pub fn resumeExecutionState( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: ?*core.Object, resume_value: ?core.JSValue, ) !ResumeState`。
- **作用**：`zjs_vm` 进入 generator/async 续体时安装停车缓冲。无 generator → 空 ResumeState。
- **实现**：有对象则 `resumeExecutionStateRaw`。
- **所有权 / 错误 / 调用**：普通调用折叠成廉价 null。真正 resume 跨这条边界一次。

### `installSuspendedExecutionStorage` (`src/exec/vm_opcodes.zig:235`)

- **签名**：`inline fn installSuspendedExecutionStorage( stack: *stack_mod.Stack, frame: *frame_mod.Frame, state: *core.object.SuspendedExecutionState, resident_stack: bool, resident_frame: bool, ) void`。
- **作用**：所有易失败的 resume 准备完成后再把停车地址装成非拥有别名（qjs `cur_sp == NULL` 时的 resident 帧）。GC/teardown 看 `running_aliases`。
- **实现**：把 storage/locals/args/var_refs/open 接到 frame；`stack.installBacking`；arena 关；resident 窗按 combined 或 owner 位；`beginRunningAliases`。
- **所有权 / 错误 / 调用**：无分配。`resumeExecutionStateRaw`。

### `finishExecutionStateRun` (`src/exec/vm_opcodes.zig:259`)

- **签名**：`pub fn finishExecutionStateRun(rt: *core.JSRuntime, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object) void`。
- **作用**：完成/出错后清别名。若已经在挂起时重新发表过所有者（`running_aliases` 已假），这是空操作。
- **实现**：无对象或无 execution（模块续体可能先完成）则返回。仍 running 且 resident owner → park（has_frame=false）。否则 `finishRunningAliases`。
- **所有权 / 错误 / 调用**：`zjs_vm` 的 defer。

### `resumeExecutionStateRaw` (`src/exec/vm_opcodes.zig:277`)

- **签名**：`noinline fn resumeExecutionStateRaw( ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: *core.Object, resume_value: ?core.JSValue, ) align(64) !ResumeState`。
- **作用**：真正的 generator 所有权安装，避开通用 `runWithArgsState`。
- **实现**：无 execution → TypeError。`!has_frame`：若 combined 栈则只装栈别名，清 `just_yielded`。escape 契约：`state.pc` 无 provenance，必须 `generatorFunctionBytecode()` 与传入 `function` 是同一份。按 started / yield_star / completion_type / 随后 `if_false` 计算要压的槽数并 reserve。assert 新 Frame 尚无存储。装窗口，catch 取自停车态。未 started 只返回 catch。yield_star：压 `[resume, completion_type]`。completion_type==2：可选压 false 并 `throw_on_entry`。普通 yield 压 resume 值；若后接 `if_false` 再压 `completion_type==1` 的 bool（NEXT vs RETURN）。
- **所有权 / 错误 / 调用**：resume_value 按 assumeCapacity 压入（所有权转入栈）。`InvalidBytecode` 若 open_var_refs 计数不对。

### `completeResumeState` (`src/exec/vm_opcodes.zig:382`)

- **签名**：`pub fn completeResumeState( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, state: ResumeState, resume_value: ?core.JSValue, ) !?usize`。
- **作用**：若 resume 带着 throw，把值变成 pending 并走 catch。
- **实现**：非 throw_on_entry → 原 catch_target。否则 `throwValue`，`closeIteratorForPendingError`，handleCatchable；抓不住则 `JSException`。
- **所有权 / 错误 / 调用**：`zjs_vm` 在 dispatch 前。返回更新后的 catch_target。

### `handleAwaitError` (`src/exec/vm_opcodes.zig:403`)

- **签名**：`fn handleAwaitError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, err: HostError, ) HostError!bool`。
- **作用**：await 失败时先关 for-of 迭代器再 catch。
- **实现**：`closeIteratorForPendingError` + handleCatchable。
- **所有权 / 错误 / 调用**：`awaitValue`。

### `stopBeforePc` (`src/exec/vm_opcodes.zig:417`)

- **签名**：`pub fn stopBeforePc( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object, catch_target: ?usize, stop_before_pc: ?usize, ) !?core.JSValue`。
- **作用**：入口停车边界（`stop_before_pc`）：普通 async 函数与空字节码 fixture 没有 `OP_initial_yield`，就把已初始化好的帧停在 pc 0 等 promise 驱动启动（`call_runtime` 按 `functionKind() == .async` / 空码流置位）。pc 命中边界则停车并返回 undefined。
- **实现**：无目标或 pc 不匹配 → null。有 generator → `parkGeneratorStartBoundary`。返回 `undefined`。
- **所有权 / 错误 / 调用**：`zjs_vm` 入口一次，之后由 `coldNext` 的 `maybeStop` 在 `depth == 0` 时复查。

### `parkGeneratorStartBoundary` (`src/exec/vm_opcodes.zig:433`)

- **签名**：`fn parkGeneratorStartBoundary( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: *core.Object, pc: usize, catch_target: ?usize, ) !void`。
- **作用**：`op.initial_yield` 边界：关参数环境 ref，但 started/just_yielded 保持 false（不是用户可见 yield）。
- **实现**：未 started 则 `closeParameterEnvironmentVarRefs`。save。`suspend_kind = none`。
- **所有权 / 错误 / 调用**：qjs 在 OP_initial_yield 关参数环境但仍保留 arg_buf。zjs 共用一张 open-ref 表，只关参数项。

### `initialYield` (`src/exec/vm_opcodes.zig:451`)

- **签名**：`pub fn initialYield( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object, catch_target: ?usize, stop_on_yield: bool, ) !Result`。
- **作用**：服务 `op.initial_yield`。
- **实现**：`stop_on_yield`（真 generator 驱动）→ 停车，返回 undefined。否则只是 push undefined（非挂起解释）。
- **所有权 / 错误 / 调用**：分发；`stop_on_yield` 仅 L0 generator。

### `yieldValue` (`src/exec/vm_opcodes.zig:469`)

- **签名**：`pub noinline fn yieldValue( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object, catch_target: ?usize, stop_on_yield: bool, ) !Result`。
- **作用**：服务 `op.yield`。
- **实现**：pop value。stop_on_yield：save，`suspend_kind=yield`，started/just_yielded=true，`return_value=value`。否则 push undefined 继续。
- **所有权 / 错误 / 调用**：yield 值所有权交给调用方（async_generator / VM 返回）。

### `yieldStar` (`src/exec/vm_opcodes.zig:493`)

- **签名**：`pub noinline fn yieldStar( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: ?*core.Object, stop_on_yield: bool, catch_target: *?usize, ) !Result`。
- **作用**：服务 `op.yield_star` / `op.async_yield_star` 的 catch 包装。
- **实现**：`yieldStarRaw` catch handleCatchable → `.continue_loop`。
- **所有权 / 错误 / 调用**：分发。

### `yieldStarRaw` (`src/exec/vm_opcodes.zig:512`)

- **签名**：`fn yieldStarRaw( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: ?*core.Object, stop_on_yield: bool, catch_target: ?usize, ) !Result`。
- **作用**：`yield*` 体。展开 lowering（下一字节是 `dup`）与迭代器循环两种。
- **实现**：`opcode_pc = pc-1`。expanded：pop result_object，stop 则 save 在 **当前 pc**（即紧随的 `dup` 字节处），标 yield_star_suspended，返回该对象；否则（无 generator 或不 stop）压 `[undefined, 0]`。非展开：已存 iterator 则复用并可能 pop next_arg；否则 pop iterable → `iteratorForValue`。`iteratorStepResult`。done：清 stored iterator，push value，`.continue_loop`。否则 stop 则存 iterator、save 在 **opcode_pc**（下次再进 yield_star），返回 step.result；非 stop 压 undefined。
- **所有权 / 错误 / 调用**：iterator 活在 generator payload。可再入 next。

### `awaitValue` (`src/exec/vm_opcodes.zig:590`)

- **签名**：`pub noinline fn awaitValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: ?*core.Object, suspend_on_module_await: bool, stop_on_yield: bool, catch_target: *?usize, ) HostError!Result`。
- **作用**：服务 `op.await`。
- **实现**：`awaitValueRaw` catch `handleAwaitError`。
- **所有权 / 错误 / 调用**：分发。`suspend_on_module_await` / `stop_on_yield` 来自 L0。

### `awaitValueRaw` (`src/exec/vm_opcodes.zig:610`)

- **签名**：`fn awaitValueRaw( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, generator: ?*core.Object, suspend_on_module_await: bool, stop_on_yield: bool, catch_target: ?usize, ) HostError!Result`。
- **作用**：await 体：raw 挂起 vs thenable vs Promise 结算。
- **实现**：`awaitSuspendMode`。pop awaited。`.raw`：`suspendAwaitValue`（true）或把值压回 continue。非 Promise 对象：`awaitThenableValue` 或原值；`.settled` 才 suspend。Promise：`settlePendingPromiseReaction`；settled 且未完成则 `drainPendingPromiseJobs`；仍 pending 则 `awaitPendingPromise`。rejected → throw。否则 suspend 或 push 结果。
- **所有权 / 错误 / 调用**：Promise 结果借自内部槽再 push。

### `suspendAwaitValue` (`src/exec/vm_opcodes.zig:662`)

- **签名**：`fn suspendAwaitValue( ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object, suspend_on_await: bool, value: core.JSValue, catch_target: ?usize, ) !?Result`。
- **作用**：把 await 变成 generator 挂起。
- **实现**：开关关或无 generator → null。save，`suspend_kind=await_op`，started/just_yielded，`return_value=value`。
- **所有权 / 错误 / 调用**：value 交给上层 Promise 反应。

### `awaitSuspendMode` (`src/exec/vm_opcodes.zig:680`)

- **签名**：`fn awaitSuspendMode(function: *const bytecode.FunctionBytecode, suspend_on_module_await: bool, stop_on_yield: bool) AwaitSuspendMode`。
- **作用**：选 raw / none。
- **实现**：模块或 async 函数且 `suspend_on_module_await` → raw。async 且 `stop_on_yield`（async generator 体）→ raw。否则 none。
- **所有权 / 错误 / 调用**：队列机在 `async_generator.zig` 经 promise 反应恢复。

### `closeIteratorForPendingError` (`src/exec/vm_opcodes.zig:691`)

- **签名**：`fn closeIteratorForPendingError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：unwind 时关掉栈顶 for-of 迭代器；**for-await-of** 在 `iterator_get_value_done` 前的 await 拒绝**不得**从 unwind 关（qjs 16713 关掉 catch offset；只有 AsyncFromSyncIterator 反应关）。
- **实现**：下一 opcode 是 `iterator_get_value_done` 则返回。否则 `closeStackTopForOfIteratorForPendingError`。
- **所有权 / 错误 / 调用**：completeResumeState / handleAwaitError。

## 覆盖核对

- 清单函数数: 23
- 本文标题覆盖: 23
- 未覆盖: 无
