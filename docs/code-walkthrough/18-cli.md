# 18 — CLI（`src/cli/zjs.zig`、`cli_process.zig`、`panic_policy.zig`）

`zjs` / `zjs-profile` / `zjs-size` 共用这一根，全部跟随 `-Doptimize`。`pub const panic` 来自 `panic_policy.zig`。

argv 合同见 [18-runtime-cli-abi.md](18-runtime-cli-abi.md)。本文件按函数展开。`zjs.zig` 是单文件：argv、求值、报错、诊断面板都在根里，按段排列。

## 文件级类型

### `src/cli/panic_policy.zig`（零函数）

`pub const policy`：`ReleaseFast` → `std.debug.simple_panic`（只打消息，不带符号器）；其它模式 → `FullPanic(defaultPanic)`。发行 tarball 是 stripped ReleaseFast，完整 handler 会链上 ELF/DWARF/flate 与两份 `std.sort.block`，约 209 KB 且一帧都解不出。Debug `zjs`、测试、带断言的构建仍打解析后的栈。

### `CliError` / `Command` / `RuntimeOptions`

在 `zjs.zig`。`CliError = error{Usage}`。`Command` 是一份求值作业：`input`（`Command.Input`：`.eval` / `.file`，唯一的输入形判别）、`path`（`-e` 为 `"<eval>"`）、`source`、`script_args`、`EvalMode`。是否读盘、是否拥有源缓冲、是否做模块探测都从 `input` 派生，不另存副本。`parseArgs` / `loadSource` 填好后，后面不再按 `-e` 与文件分叉。`RuntimeOptions` 收集内存上限、栈、can_block、dump/trace/profile/gc/perf/leak-check，以及最多 16 条 `-I` 路径。

### `Runtime`（`zjs.zig`）

把 `JSRuntime`、`JSContext`、已 install 的 `EventLoop` 捆在一起。`deinit` 按 loop → context → runtime 拆。成功路径默认不调（见 `main`）。`EventLoop.install` 会把 `*EventLoop` 挂进 context，所以必须在 `main` 的栈帧上 install，不能把已 install 的 loop 按值返回。

### `PerfJsonTimings` / `OpcodeProfileRow`

冷路径诊断结构，在 `zjs.zig`。`writeCounterLine`（`noinline`）是 GC 面板共用的整数行格式化。

### `cli_process.zig`

两个 CLI 根（`zjs` 与 `run-test262`）共享的进程边界：argv 拷进 arena、stderr 打印后 flush，避免 `std.process.exit` 丢掉缓冲。

---

## `cli_process.zig`

### `argsToSlice` (`src/cli/cli_process.zig:9`)

- **签名**：`pub fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8`。
- **作用**：把 `std.process.Args` 收成 arena 拥有的 `[]const []const u8`。
- **实现**：`args.toSlice(arena)` 再 `alloc` 一层指针数组并拷贝。
- **所有权 / 错误 / 调用**：切片与字符串都在 arena。`zjs.main`、`run_test262.main`。OOM。

### `printError` (`src/cli/cli_process.zig:18`)

- **签名**：`pub fn printError(io: std.Io, message: []const u8) !void`。
- **作用**：整段消息打到 stderr 并 flush。
- **实现**：`printErrorJoin(io, &.{message})`。
- **所有权 / 错误 / 调用**：usage、读文件失败、引擎 init 失败。

### `printErrorJoin` (`src/cli/cli_process.zig:23`)

- **签名**：`pub fn printErrorJoin(io: std.Io, parts: []const []const u8) !void`。
- **作用**：拼接多段后打 stderr，保证 `exit` 前缓冲落地。
- **实现**：4 KiB 栈缓冲的 `File.stderr().writer`，逐段 `writeAll`，`flush`。
- **所有权 / 错误 / 调用**：所有 CLI 致命路径。写失败向上传（随后通常 `exit`）。

---

## `zjs.zig`：选项与 argv

### `RuntimeOptions.addInclude` (`src/cli/zjs.zig:77`)

- **签名**：`fn addInclude(self: *RuntimeOptions, path: []const u8) !void`。
- **作用**：追加一条 `-I` 预加载路径。
- **实现**：满 16 条 `error.TooManyIncludes`；否则写入 `include_paths[include_count]`。
- **所有权 / 错误 / 调用**：路径切片借用 argv。`parseArgs` 把该错误映射成 `Usage`。

### `RuntimeOptions.includes` (`src/cli/zjs.zig:83`)

- **签名**：`pub fn includes(self: *const RuntimeOptions) []const []const u8`。
- **作用**：已登记 include 的视图。
- **实现**：`include_paths[0..include_count]`。
- **所有权 / 错误 / 调用**：`runIncludeFiles`。

### `parseArgs` (`src/cli/zjs.zig:128`)

- **签名**：`pub fn parseArgs(args: []const []const u8) CliError!Command`。
- **作用**：把 argv（不含 argv0）收成 `Command`；非法则 `error.Usage`。
- **实现**：先扫旗标：`--can-block`、`-d/--dump`、`-T/--trace`、`--gc-stats`（顺带 `detailed_reports=true`）、`--gc-gate-settle`（蕴含 gc-stats）、`--gc-block-census`、`--gc-mark-footprint`（另开 `mark_footprint_census`，会动分数，不是尺子）、`--profile-opcodes`、`--perf-json`、`--leak-check`、`--memory-limit`/`--stack-size`（缺值或非十进制 → Usage）、`-I/--include`。未知以 `-` 开头且不是位置参数 → Usage。空 rest、`-h`/`--help` → Usage。`-e`：若 `can_block` 或 `rest.len != 2` → Usage，否则 `input=.eval`、`path="<eval>"`、源借用 argv。`-m`：至少再跟一个路径，`mode=.module`，`script_args = rest[1..]`（含路径）。不以 `-` 开头的词当文件路径，`script_args = rest[0..]`。
- **所有权 / 错误 / 调用**：不分配。`main` catch 后 `printUsage` + `exit(2)`。单测覆盖 eval/file/module/limits/includes/拒绝退休旗标。

### `printUsage` (`src/cli/zjs.zig:212`)

- **签名**：`fn printUsage(io: std.Io) !void`。
- **作用**：把契约写到 stderr。
- **实现**：两行：`zjs [flags] -e <script>`、`zjs [flags] [-m] <file.js>`。
- **所有权 / 错误 / 调用**：`parseArgs` 失败。随后 `exit(2)`。

### `parseLimitKBytes` (`src/cli/zjs.zig:216`)

- **签名**：`fn parseLimitKBytes(text: []const u8) !usize`。
- **作用**：把十进制「KB」乘 1024。
- **实现**：空串 `InvalidCharacter`；`parseAsciiInt` 后 `mul`，溢出 `Overflow`。
- **所有权 / 错误 / 调用**：`--memory-limit` / `--stack-size`；`parseArgs` 把任何错误变成 Usage。

---

## `zjs.zig`：进程编排

### `Runtime.deinit` (`src/cli/zjs.zig:330`)

- **签名**：`pub fn deinit(self: *Runtime) void`。
- **作用**：按依赖顺序拆循环、context、runtime。
- **实现**：`event_loop.deinit` → `context.destroy` → `runtime.destroy`。后者在测试里断言无未释放分配。
- **所有权 / 错误 / 调用**：唯一调用点是 `main` 里 `--leak-check` 的成功路径，以及 `main` 在 install 之后的 `errdefer`。默认成功走 `exit(0)`，把拆卸交给 OS，避免 test262 把 `destroy` 断言/回溯误报成超时。

### `main` (`src/cli/zjs.zig:337`)

- **签名**：`pub fn main(init: std.process.Init) !void`。
- **作用**：CLI 全过程：解析 argv、造引擎、求值、排 job、报告、按合同退出。
- **实现**：
  1. `argsToSlice`。
  2. `parseArgs` 失败 → usage + `exit(2)`。选项只取一次。
  3. `loadSource`：`.eval` 已有 argv 源；`.file` 走 `readFileAlloc` 上限 64 MiB，失败 `exit(1)`。
  4. `JSRuntime.create` + `JSContext.create`，在 `main` 栈上捆成 `Runtime` 并 `event_loop.install`。`configureRuntime`。eval/file 都 `setTrackUnhandledRejections(true)`。
  5. `--profile-opcodes` 在非 profile 构建上拒并 `exit(2)`；`--perf-json` 可激活 profile 计数。`host.defineScriptArgs`。`setPreserveUncaughtException(true)`。无条件 `installDynamicImport`（对齐 qjs 始终装 module loader，使 `-e` 与脚本里的 `import()` 也能解析）。
  6. `runIncludeFiles`；失败走 `failEvaluation`。
  7. `--bytecode-fingerprint`：只接受 file，编译不跑，打印指纹后 `return`。
  8. `evalSource`（路径、模式、`Command.detectModule()` 都来自 `Command`）。失败走 `failEvaluation`（`!noreturn`，catch 臂不需要 `unreachable`）。
  9. 返回 exception 哨兵 → stderr + `exit(1)`。
  10. `dynamic_import_state.runJobs`（模块续体 + `drainPendingPromiseJobs` 的宿主臂顺序），flush stdout。
  11. 若有 unhandled rejection / exception：`reportUnhandledRejections`（**共用一个** stderr writer），`exit(1)`。对齐 `js_std_promise_rejection_check`。
  12. `dumpRequested`：可选 dump memory / opcode profile / gc 面板 / perf JSON。
  13. `printSmallInlineProbe`。`--leak-check`：先 `dynamic_import_scope.deinit`（idempotent，避免 defer 在 runtime 死后跑），再 `runtime.deinit` 后正常 return。否则 `exit(0)`。
- **所有权 / 错误 / 调用**：源文件缓冲由 gpa 拥有，file 路径 `defer free`；`exit` 会跳过其余 defer。event loop 的 `output` 借用 stdout writer。

### `Command.detectModule` (`src/cli/zjs.zig:45`)

- **签名**：`fn detectModule(self: Command) bool`。
- **作用**：文件（含 `-m`）按 qjs `JS_DetectModule` 探测 script/module；`-e` 永远是 script。
- **实现**：`input == .file`。
- **所有权 / 错误 / 调用**：`main` 传给 `evalSource`。

### `Command.deinitSource` (`src/cli/zjs.zig:49`)

- **签名**：`fn deinitSource(self: Command, allocator: std.mem.Allocator) void`。
- **作用**：释放 `loadSource` 为文件分配的源缓冲。
- **实现**：`input == .file` 时 `allocator.free(source)`。`-e` 的源借用 argv，不释放。
- **所有权 / 错误 / 调用**：`main` 的 `defer`，在 `loadSource` 之后登记。`exit` 会跳过。

### `loadSource` (`src/cli/zjs.zig:498`)

- **签名**：`fn loadSource(command: *Command, allocator: std.mem.Allocator, io: std.Io, read_source_ns: *u64) !void`。
- **作用**：若还没有源文本，按 `command.path` 读盘并记下耗时。
- **实现**：`input == .eval` 则源已在 argv 上，直接返回（不比较路径字符串，名为 `<eval>` 的文件照常读盘）。否则 `readFileAlloc`（`max_source_size`）写入 `command.source`；失败打路径+errorName 后 `exit(1)`。
- **所有权 / 错误 / 调用**：文件缓冲由 gpa 拥有，`Command.deinitSource` 释放。

### `configureRuntime` (`src/cli/zjs.zig:509`)

- **签名**：`fn configureRuntime(runtime, script_args, runtime_options, opcode_profile, io) !void`。
- **作用**：把 CLI 选项写进已造好的引擎：GC 开关、profile、`scriptArgs`、保留未捕获异常。
- **实现**：`applyRuntimeOptions`；`setTrackUnhandledRejections(true)`。`--profile-opcodes` 在非 profile 构建 `exit(2)`，否则 `setOpcodeProfile`。仅 `--perf-json` 时 `activateOpcodeProfile`。`defineScriptArgs` 失败 `exit(1)`。`setPreserveUncaughtException(true)`。
- **所有权 / 错误 / 调用**：`main` setup。`opcode_profile` 必须活过求值。

### `applyRuntimeOptions` (`src/cli/zjs.zig:534`)

- **签名**：`fn applyRuntimeOptions(runtime: *Runtime, runtime_options: RuntimeOptions) void`。
- **作用**：把 CLI 选项写进引擎。
- **实现**：写 `detailed_reports` / `mark_footprint_census` 后 `gc.refreshBarrierGate`；`setCanBlock`；可选 `setMemoryLimit`；可选 `setStackSize` + `setStackLimit`。
- **所有权 / 错误 / 调用**：`configureRuntime`。

### `failEvaluation` (`src/cli/zjs.zig:548`)

- **签名**：`fn failEvaluation(runtime: *Runtime, output: *std.Io.Writer, io: std.Io, err: anyerror) !noreturn`。
- **作用**：include/eval 失败的统一出口：`ProcessExit`、异常、否则 error 名。
- **实现**：`exitIfRequested`。有 exception 先 flush stdout。`printEvaluationError` + `exit(1)`。
- **所有权 / 错误 / 调用**：打印失败会把 error 传回 `main`；其余路径都 `exit`，返回类型 `!noreturn` 让编译器证明这一点，调用处直接 `catch |err| try failEvaluation(...)`。

### `exitIfRequested` (`src/cli/zjs.zig:555`)

- **签名**：`fn exitIfRequested(runtime: *Runtime, output: *std.Io.Writer, err: anyerror) !void`。
- **作用**：脚本里 `std.exit` 一类请求变成进程退出。
- **实现**：仅当 `err == error.ProcessExit` 且 `event_loop.exitCode()` 非空：flush output，`std.process.exit(code)`。否则 return。
- **所有权 / 错误 / 调用**：`failEvaluation`。

---

## 求值与模块探测

### `evalScript` (`src/cli/zjs.zig:564`)

- **签名**：`pub fn evalScript(ctx, source_text, output, filename, timing: ?*EvalTiming) !zjs.JSValue`。
- **作用**：按 CLI 合同跑一段 script：`discard_script_result`，非 strict。
- **实现**：`ctx.eval` 固定 `.mode = .script`，`parse_strict`/`runtime_strict` 为 false。
- **所有权 / 错误 / 调用**：`-e`、`evalPath` 的 script 臂、`-I` 的 script 文件。

### `evalSource` (`src/cli/zjs.zig:582`)

- **签名**：`fn evalSource(ctx, source_text, output, path, explicit_mode, detect_module, io, allocator, timing) !zjs.JSValue`。
- **作用**：按路径和模式跑 script 或模块图。`-e` 与文件共用。
- **实现**：`detect_module` 时走 `detectFileMode`；module 则 `runFileModule`，否则 `evalScript`。`-e` 把 `detect_module=false`，永远当 script。
- **所有权 / 错误 / 调用**：`main` 与 `runIncludeFiles`。

### `runFileModule` (`src/cli/zjs.zig:600`)

- **签名**：`fn runFileModule(ctx, source_text, output, path, io, allocator, max_size) !zjs.JSValue`。
- **作用**：文件模块图求值入口。
- **实现**：`engine.exec.module_graph.evalFileModuleGraphWithOutput`。
- **所有权 / 错误 / 调用**：`evalPath` 在 detect 为 module 时。

### `runIncludeFiles` (`src/cli/zjs.zig:621`)

- **签名**：`pub fn runIncludeFiles(ctx, runtime_options, output, io, allocator) !void`。
- **作用**：按顺序预求值 `-I` 文件。
- **实现**：每条路径 `readFileAlloc`（64 MiB），`evalPath(..., .script, timing=null)`。
- **所有权 / 错误 / 调用**：每文件 defer free。失败让 `main` 走 `failEvaluation`。主脚本之前执行。

### `printBytecodeFingerprint` (`src/cli/zjs.zig:639`)

- **签名**：`pub fn printBytecodeFingerprint(output, ctx, source_text, path, mode, verbose) !void`。
- **作用**：编译但不跑，打印 FunctionBytecode 树的稳定指纹（parser identity gate）。
- **实现**：`parser.compile`；语法错误/无产物打对应行。成功则 Wyhash 扫整棵 cpool 树，打 `{hash} functions=N path`。verbose 再打每函数的 code hex。
- **所有权 / 错误 / 调用**：`compiled.deinit`。只接受 file 命令；`-e` 在 `main` 里先拒。

### `fingerprintFunctionBytecode` (`src/cli/zjs.zig:675`)

- **签名**：`fn fingerprintFunctionBytecode(hasher, fb, function_count, verbose) void`。
- **作用**：把一个 FunctionBytecode 及其 cpool 子函数喂进 hasher。
- **实现**：code 长度+字节、标量字段、cpool：子 fb 递归；tracer-owned 哈希 tag（字符串再哈希内容，不哈希地址）；其它 bitcast u64。
- **所有权 / 错误 / 调用**：verbose 写失败吞掉（`catch {}`），以免诊断打印破坏 hasher 路径。

### `detectFileMode` (`src/cli/zjs.zig:726`)

- **签名**：`pub fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: zjs.context.EvalMode) zjs.context.EvalMode`。
- **作用**：决定 script vs module。
- **实现**：显式 `.module` 优先；`.mjs` 后缀；否则 `sourceLooksLikeModule`。
- **所有权 / 错误 / 调用**：`evalPath`、fingerprint。

### `sourceLooksLikeModule` (`src/cli/zjs.zig:737`)

- **签名**：`fn sourceLooksLikeModule(source: []const u8) bool`。
- **作用**：对齐 qjs `JS_DetectModule`（quickjs.c:23792）：shebang 后**只看第一个 token**。
- **实现**：`skipShebang` 后 `simple_token.next`。`import` 且下一 token 不是 `.`/`(` → 模块；`export` → 模块；其它（含 `import()`、`import.meta`、靠后的 export）→ 脚本（后者在 script 模式是 SyntaxError，与 qjs 一致）。
- **所有权 / 错误 / 调用**：`detectFileMode`。单测钉首 token / shebang / 晚 export。

### `skipShebang` (`src/cli/zjs.zig:751`)

- **签名**：`fn skipShebang(source: []const u8, pos: *usize) void`。
- **作用**：对齐 qjs `skip_shebang`（quickjs.c:23761）。
- **实现**：`#!` 则扫到 `\n`/`\r`，写回 `pos`。
- **所有权 / 错误 / 调用**：`sourceLooksLikeModule`。无 shebang 不改 pos（调用方从 0 开始）。

---

## 异常报告

### `printEvaluationError` (`src/cli/zjs.zig:790`)

- **签名**：`pub fn printEvaluationError(io: std.Io, ctx: *zjs.JSContext, rt: *zjs.JSRuntime, err: anyerror) !void`。
- **作用**：求值失败时打异常或 Zig error 名。
- **实现**：有 exception/rejection 则 `printExceptionValue`；否则 `zjs: evaluation failed: {errorName}`。
- **所有权 / 错误 / 调用**：`failEvaluation`。`exit(1)` 之前。

### `printExceptionValue` (`src/cli/zjs.zig:803`)

- **签名**：`fn printExceptionValue(stderr: *std.Io.Writer, ctx: *zjs.JSContext, rt: *zjs.JSRuntime, value: zjs.JSValue) !bool`。
- **作用**：对象异常打 `formatException` + 可选 stack。
- **实现**：非对象返回 false。空 header 打 `Error\n`。`formatExceptionStack` 若在取栈时又抛，clear 后当无栈。flush。
- **所有权 / 错误 / 调用**：header/stack 用 runtime allocator，defer free。

### `printUnhandledRejectionTo` (`src/cli/zjs.zig:836`)

- **签名**：`pub fn printUnhandledRejectionTo(stderr: *std.Io.Writer, ctx: *zjs.JSContext, rt: *zjs.JSRuntime, value: zjs.JSValue) !void`。
- **作用**：一条「Possibly unhandled promise rejection:」报告。
- **实现**：int/bool/undefined/null/string/object 分支；对象走 `printExceptionValue`。循环必须复用同一 writer。
- **所有权 / 错误 / 调用**：对齐 qjs `js_std_promise_rejection_check`。

### `reportUnhandledRejections` (`src/cli/zjs.zig:860`)

- **签名**：`pub fn reportUnhandledRejections(io: std.Io, ctx: *zjs.JSContext, rt: *zjs.JSRuntime) !void`。
- **作用**：按拒绝顺序把仍未处理的 rejection 全部打到 stderr。
- **实现**：一个 stderr writer，循环 `takePendingException` + `printUnhandledRejectionTo`，直到没有 unhandled rejection。
- **所有权 / 错误 / 调用**：`main` 在 job 排水之后。随后 `exit(1)`。

---

## 诊断打印

### `dumpMemoryUsage` (`src/cli/zjs.zig:871`)

- **签名**：`pub fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *zjs.JSRuntime) !void`。
- **作用**：`-d` 出口内存表。
- **实现**：`dumpMemorySnapshot(output, runtime.memoryUsage())`。
- **所有权 / 错误 / 调用**：`dumpRequested`。写失败向上。

### `dumpMemorySnapshot` (`src/cli/zjs.zig:875`)

- **签名**：`fn dumpMemorySnapshot(output: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage) !void`。
- **作用**：固定列宽打印 limit / atoms / objects / shapes / modules / classes。
- **实现**：limit 缺省打 `0`。行格式 `{s:<22} {d:>5} {d:>8}`。单测钉宽度与字段。
- **所有权 / 错误 / 调用**：`dumpMemoryUsage`、单测。

### `dumpRequested` (`src/cli/zjs.zig:907`)

- **签名**：`fn dumpRequested(stdout, io, path, runtime, runtime_options, opcode_profile, timings) !void`。
- **作用**：按旗标顺序打出口面板，顺序与历史 `main` 合同相同。
- **实现**：`dump_memory` →（profile 构建且 `--profile-opcodes`）opcode 表 → `gc_stats` 则 `dumpGcPanels` → `perf_json` 打 stderr。前三项各 flush stdout。
- **所有权 / 错误 / 调用**：`main` 在 job 排水且无未处理 rejection 之后。

### `dumpGcPanels` (`src/cli/zjs.zig:937`)

- **签名**：`fn dumpGcPanels(writer, runtime, runtime_options) !void`。
- **作用**：`--gc-stats` 整组面板，含 gate-settle 的 endpoint/settled doomed 行。
- **实现**：可选 settle 前 doomed → stats / atom audit / major pauses / space / block heap → 可选 block census → mark footprint / phase totals / generation → 可选 conservative diag → 收尾 doomed。
- **所有权 / 错误 / 调用**：行顺序是面板合同，解析器按行消费。

### `dumpPerfJson` (`src/cli/zjs.zig:963`)

- **签名**：`fn dumpPerfJson(io: std.Io, path: []const u8, runtime: *zjs.JSRuntime, perf_profile: ?*const zjs.OpcodeProfile, timings: PerfJsonTimings) !void`。
- **作用**：`--perf-json` 把计时、内存、可选 opcode profile 打到 **stderr**。
- **实现**：对象：`file`、metrics、`opcode_profile_enabled`、有 profile 则 opcode_profile。flush。IC 段已删：`OpcodeProfile` 的 `ic_*` 五个数组在引擎里没有任何写点，输出的永远是占位串或 0。
- **所有权 / 错误 / 调用**：不污染脚本 stdout。`dumpRequested`。

### `dumpPerfJsonMetrics` (`src/cli/zjs.zig:982`)

- **签名**：`fn dumpPerfJsonMetrics(stderr: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage, timings: PerfJsonTimings) !void`。
- **作用**：JSON 计时与 memory 子对象。
- **实现**：`writeCounterLine` 串 `total_ns`…`jobs_ns` 与 allocation 计数。`finalize_ns` 恒 `null`，`parse_ns_includes_finalize: true`（解析阶段含 finalize）。
- **所有权 / 错误 / 调用**：不分配。唯一调用方 `dumpPerfJson`；单测「zjs perf JSON metrics preserve populated fields」逐字段钉住输出并验证写失败。

### `dumpPerfJsonOpcodeProfile` (`src/cli/zjs.zig:1021`)

- **签名**：`fn dumpPerfJsonOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：非零 opcode 行的 JSON 数组。
- **实现**：收 `OpcodeProfileRow`，按 nanos/count/opcode 排。`measured_ns` / `value_dups` / `global_lookups` / `call_frames` 与每行的 `nanos`/`avg_ns`/`slow` 在 profile 构建里打 `"not instrumented"`——这些字段在那条路径上没有写点（tail-call 派发器只调 `noteDispatch` 计数，不能跨 `always_tail` 计时）。`allocations` 不在此列：`JSRuntime.setOpcodeProfile` 把分配器的计数器指向 `alloc_count`，所以它在任何构建下都是真数字，现在无条件打印。
- **所有权 / 错误 / 调用**：`ensureOpcodeProfileNames` 先激活一次以填名字表。分支条件是本文件的具名常量 `profile_counters_uninstrumented`。

### `writeJsonString` (`src/cli/zjs.zig:1070`)

- **签名**：`fn writeJsonString(output: *std.Io.Writer, bytes: []const u8) !void`。
- **作用**：JSON 字符串转义。
- **实现**：`"` `\` `\n\r\t`；`<0x20` 用 `\u00XX`；其余原样。
- **所有权 / 错误 / 调用**：文件名、opcode 名。

### `dumpGcSpaceStats` (`src/cli/zjs.zig:1100`)

- **签名**：`fn dumpGcSpaceStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：分配直方图 p50/p95/p99、small 覆盖、large 计数。
- **实现**：读 `space_histogram`。只打印有写点的字段。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcBlockCensus` (`src/cli/zjs.zig:1124`)

- **签名**：`fn dumpGcBlockCensus(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：TGC S4-f：每 size-class 的 block 占用。纯退出时 walk，不在分配热路径。
- **实现**：`censusBlocks()`，列 blocks/cells/allocated/occ_x1000/empty/lt10/lt50/ge50/young/decommitted/active/hot/free，再打 total。
- **所有权 / 错误 / 调用**：`--gc-block-census`（蕴含 gc-stats）。

### `writeCounterLine` (`src/cli/zjs.zig:1185`)

- **签名**：`noinline fn writeCounterLine(writer: *std.Io.Writer, parts: []const struct { []const u8, u64 }, suffix: []const u8) !void`。
- **作用**：GC 面板共用的整数行格式化：把 `(label, u64)` 片段串成一行再加后缀。
- **实现**：对 `parts` 逐段 `writer.print("{s}{d}", .{label, value})`，再 `writeAll(suffix)`。outlined 是为了在冷诊断行之间共享格式化，同时让每条调用点的 label/value/suffix 仍显式写出。
- **所有权 / 错误 / 调用**：不分配。写失败上抛。`dumpGcBlockCensus` / `dumpGcGenerationStats` / `writeDoomedStateLine` 等。

### `dumpGcGenerationStats` (`src/cli/zjs.zig:1193`)

- **签名**：`fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *engine.core.gc.Registry) !void`。
- **作用**：分代计数、minor 暂停分位、barrier、增量 major。
- **实现**：多行 `writeCounterLine`。`remembered without young` 是写屏障过火的观察点。`verify_minor` 关则打 unavailable。
- **所有权 / 错误 / 调用**：`--gc-stats`。单测钉填充快照。

### `dumpGcBlockHeapStats` (`src/cli/zjs.zig:1320`)

- **签名**：`fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：superblock 提交/热复用/decommit/trim、析构计数。
- **实现**：`plain-object destructor calls` 必须为 0（无 payload 的普通对象不该进析构）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcPhaseTotals` (`src/cli/zjs.zig:1379`)

- **签名**：`fn dumpGcPhaseTotals(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：增量 STW 子阶段 ns 与 begin/finish 对账残差。
- **实现**：八字段主行保持给解析器；finish-init/tail 在对账行。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcMarkFootprint` (`src/cli/zjs.zig:1419`)

- **签名**：`fn dumpGcMarkFootprint(writer: *std.Io.Writer, rt: *const engine.core.JSRuntime) !void`。
- **作用**：`--gc-mark-footprint` 的 marked-set/storage 普查。未开普查时明确说没跑，避免全 0 被读成「什么都没标」。
- **实现**：按 GcKind、MarkTraceClass、MarkStorageComponent、inline 上限槽打印。string 含 rope。storage = property+array+payload。
- **所有权 / 错误 / 调用**：开普查会在每次 final remark 走整堆，Splay 分数会动。

### `dumpGcStats` (`src/cli/zjs.zig:1504`)

- **签名**：`fn dumpGcStats(writer: *std.Io.Writer, stats: zjs.GCStats, registry: *const engine.core.gc.Registry) !void`。
- **作用**：收集次数、释放对象、live/peak、external 计价、weak/finalizer 队列。
- **实现**：external 与 allocation_debt 分行，避免把 pacing 计数当 live。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpAtomAuditStats` (`src/cli/zjs.zig:1545`)

- **签名**：`fn dumpAtomAuditStats(writer: *std.Io.Writer, rt: *const zjs.JSRuntime) !void`。
- **作用**：TGC S3 atom 边审计。
- **实现**：`stale-edge` 必须 0；`shell-edge` 合法（WeakRef shell）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcDoomedState` (`src/cli/zjs.zig:1553`)

- **签名**：`fn dumpGcDoomedState(writer: *std.Io.Writer, layer: []const u8, rt: *const zjs.JSRuntime) !void`。
- **作用**：打印 doomed 队列快照，layer 为 `"endpoint"` 或 `"settled"`。
- **实现**：`doomedStateSnapshot` + `writeDoomedStateLine`。
- **所有权 / 错误 / 调用**：`--gc-gate-settle` 在 settle 前后各打一次。

### `writeDoomedStateLine` (`src/cli/zjs.zig:1557`)

- **签名**：`fn writeDoomedStateLine(writer, layer, state: engine.core.gc_trace_stw.DoomedStateSnapshot) !void`。
- **作用**：固定字段顺序的 doomed 行。
- **实现**：bool 打 true/false，计数经 `writeCounterLine`。单测钉混合 bool 与写失败。
- **所有权 / 错误 / 调用**：`dumpGcDoomedState`。

### `dumpGcPauses` (`src/cli/zjs.zig:1589`)

- **签名**：`fn dumpGcPauses(writer: *std.Io.Writer, distribution: ?zjs.GCPauseDistribution) !void`。
- **作用**：只报 **major** 暂停分位。空分布打 `major pauses none`，绝不打全 0。
- **实现**：minors 另有 generation 行。混在一起会让 p50 变成 minor。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpOpcodeProfile` (`src/cli/zjs.zig:1605`)

- **签名**：`fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：人类可读 opcode 表（默认前 40；`ZJS_PROFILE_ALL=1` 打全部执行过的）。
- **实现**：排序同 JSON。`not instrumented` 的判定与 `dumpPerfJsonOpcodeProfile` 共用 `profile_counters_uninstrumented`；`allocations` 无条件打真值。额外打印 `using` 子形式（D12：禁止聚合成一行）和 SemanticFamily rollup（生成聚合，不替代 per-form）。
- **所有权 / 错误 / 调用**：`--profile-opcodes`。`getenv` 读 `ZJS_PROFILE_ALL`。

### `sortedOpcodeProfileRows` (`src/cli/zjs.zig:1693`)

- **签名**：`fn sortedOpcodeProfileRows(profile, rows) []OpcodeProfileRow`。
- **作用**：把非零 opcode 收成行并按时间/次数/opcode 排序。
- **实现**：填充调用方提供的 `rows` 缓冲，`sort_erased.heap` + `opcodeProfileRowLessThan`。返回切片别名该缓冲。
- **所有权 / 错误 / 调用**：不分配。`dumpOpcodeProfile` / `dumpPerfJsonOpcodeProfile`。

### `opcodeProfileRowLessThan` (`src/cli/zjs.zig:1709`)

- **签名**：`fn opcodeProfileRowLessThan(_: void, lhs: OpcodeProfileRow, rhs: OpcodeProfileRow) bool`。
- **作用**：按 nanos 降序、count 降序、opcode 升序。
- **实现**：三键比较。
- **所有权 / 错误 / 调用**：heap sort 回调。

### `ensureOpcodeProfileNames` (`src/cli/zjs.zig:1715`)

- **签名**：`fn ensureOpcodeProfileNames() void`。
- **作用**：激活一次 opcode 名字表（即使当前没挂 profile）。
- **实现**：`activateOpcodeProfile(null)` 再恢复 previous。
- **所有权 / 错误 / 调用**：dump 前。

### `initOpcodeProfile` (`src/cli/zjs.zig:2081`)

- **签名**：`pub fn initOpcodeProfile(profile: *zjs.OpcodeProfile) void`。
- **作用**：零初始化 profile，避免 18 KiB `.rodata` 的 `OpcodeProfile{}` 拷贝。
- **实现**：`zeroes` 后把 `pending_op` 设回 `no_pending_op` 哨兵。
- **所有权 / 错误 / 调用**：`main` 栈上 profile。单测 `expectEqualDeep(OpcodeProfile{}, profile)`。

---

## 覆盖核对

- 清单函数数: 55（`src/cli/cli_process.zig` 3 + `src/cli/zjs.zig` 52）
- 本文标题覆盖: 55
- 未覆盖: 无
- 零函数文件: `src/cli/panic_policy.zig`
