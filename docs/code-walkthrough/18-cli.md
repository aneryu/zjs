# 18 — CLI（`src/cli/zjs.zig`、`cli_process.zig`）

`zjs` / `zjs-profile` / `zjs-size` 共用这一根，全部跟随 `-Doptimize`。

argv 合同见 [18-runtime-cli-abi.md](18-runtime-cli-abi.md)。`zjs.zig` 是单文件：argv、求值、报错、诊断面板都在根里，按段排列。

## 文件级类型

### `CliError` / `Command` / `RuntimeOptions`

在 `zjs.zig`。`CliError = error{Usage}`。`Command` 是一份求值作业：`path`（`-e` 为 `"<eval>"`）、`source`（`?[]const u8`：`-e` 在 parse 时填 argv 文本，含空串；路径命令为 `null`）、`script_args`、`EvalMode`（默认 `.module`）。`-e` / `-s` 钉成 script；普通路径与 `-m` 是 module。`loadSource` 只在 `source == null` 时读盘，不嗅探、不改 `mode`。后面不再按怎么填的分叉。`RuntimeOptions` 收集内存上限、栈、can_block、dump/trace/profile/gc/leak-check，以及最多 16 条 `-I` 路径。`Token` 是词法层（`long` / `short` / `positional` / `end_of_options`）；`option_table` 是唯一的旗标表（长名、可选短字母、要置位的 bool、取值种类）。`main` 只解析 argv；引擎、event loop、求值在 `execute` 里。`EventLoop.install` 会把 `*EventLoop` 挂进 context，所以必须在 `execute` 的栈帧上 install，不能把已 install 的 loop 按值搬走。

### `OpcodeProfileRow`

冷路径诊断结构，在 `zjs.zig`。`writeCounterLine`（`noinline`）是 GC 面板共用的整数行格式化。

### `cli_process.zig`

两个 CLI 根（`zjs` 与 `run-test262`）共享的进程边界：argv 拷进 arena、stderr 打印后 flush，避免 `std.process.exit` 丢掉缓冲。

---

## `cli_process.zig`

### `argsToSlice` (`src/cli/cli_process.zig:9`)

- **签名**：`pub fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8`。
- **作用**：把 `std.process.Args` 收成 arena 拥有的 `[]const []const u8`。
- **实现**：`args.toSlice(arena)` 再 `alloc` 一层指针数组并拷贝。
- **所有权 / 错误 / 调用**：切片与字符串都在 arena。`run_test262.main`（`zjs.main` 直接 `init.minimal.args.toSlice`）。OOM。

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

### `RuntimeOptions.addInclude` (`src/cli/zjs.zig:41`)

- **签名**：`fn addInclude(self: *RuntimeOptions, path: []const u8) !void`。
- **作用**：追加一条 `-I` 预加载路径。
- **实现**：满 16 条 `error.TooManyIncludes`；否则写入 `include_paths[include_count]`。
- **所有权 / 错误 / 调用**：路径切片借用 argv。`applyOption` 把该错误映射成 `Usage`。

### `RuntimeOptions.includes` (`src/cli/zjs.zig:47`)

- **签名**：`fn includes(self: *const RuntimeOptions) []const []const u8`。
- **作用**：已登记 include 的视图。
- **实现**：`include_paths[0..include_count]`。
- **所有权 / 错误 / 调用**：`runIncludeFiles`。

### `parseArgs` (`src/cli/zjs.zig:116`)

- **签名**：`pub fn parseArgs(argv: []const []const u8) CliError!Command`。
- **作用**：把 argv（不含 argv0）收成 `Command`；非法则 `error.Usage`。
- **实现**：先 `tokenize`：`--` 结束选项，`--name` / `--name=value`，单字母短旗标，其余 positional。`lookupOption` 对不上且不是 `-e`/`-m`/`-s`/`-h`/`--help` → Usage。表驱动 `applyOption`：bool 旗标（`--dump=1` 这种粘值 Usage）、取值旗标（缺值或非十进制 Usage）。空 rest、`-h`/`--help` → Usage。`-e`：若 `can_block` 或 `rest.len != 2` → Usage，否则 `path="<eval>"`、`source` 借用 argv（含空串）、`mode=.script`。`-m` / `-s`：至少再跟一个路径，分别钉 `mode=.module` / `.script`，`script_args = rest[1..]`（含路径）。不以 `-` 开头的词当文件路径，`source` 仍为 `null`，`mode` 默认 `.module`，`script_args = rest[0..]`。不读源码、不看扩展名。
- **所有权 / 错误 / 调用**：不分配。`main` catch 后 `printUsage` + `exit(2)`。单测按作业形态、选项词法、Usage 拒绝三类覆盖。

### `tokenize` (`src/cli/zjs.zig:157`)

- **签名**：`fn tokenize(arg: []const u8) Token`。
- **作用**：把一个 argv 词收成 long / short / positional / end_of_options。
- **实现**：`--` → end；`--…` 按第一个 `=` 切开 name/value；恰好 `-x` → short；其余 positional。
- **所有权 / 错误 / 调用**：不分配。`parseArgs`。

### `lookupOption` (`src/cli/zjs.zig:170`)

- **签名**：`fn lookupOption(tok: Token) ?Option`。
- **作用**：按长名或短字母查 `option_table`。
- **实现**：线性扫表。
- **所有权 / 错误 / 调用**：`parseArgs`。对不上则看是不是 command word。

### `applyOption` (`src/cli/zjs.zig:187`)

- **签名**：`fn applyOption(opts: *RuntimeOptions, spec: Option, tok: Token, rest: *[]const []const u8) CliError!void`。
- **作用**：把一行 option 写进 `RuntimeOptions`。
- **实现**：`.take == .none` 时拒绝 `--flag=value`，否则 `applyBools`。取值旗标从 `=` 或下一个词取，再按 memory_limit / stack_size / include 写入。
- **所有权 / 错误 / 调用**：`parseArgs`。缺值、粘在 bool 上、include 满员 → Usage。

### `applyBools` (`src/cli/zjs.zig:211`)

- **签名**：`fn applyBools(opts: *RuntimeOptions, fields: []const std.meta.FieldEnum(RuntimeOptions)) void`。
- **作用**：把表里列出的 bool 字段置 true。
- **实现**：`inline else` 只接受 bool 字段，其它 `unreachable`。
- **所有权 / 错误 / 调用**：`applyOption`。

### `isCommandWord` (`src/cli/zjs.zig:223`)

- **签名**：`fn isCommandWord(arg: []const u8) bool`。
- **作用**：`-e` / `-m` / `-s` / `-h` / `--help` 不是未知旗标，留给后面的命令词。
- **实现**：五路 `eql`。
- **所有权 / 错误 / 调用**：`parseArgs` 在 `lookupOption` 失败时。

### `parseLimitKBytes` (`src/cli/zjs.zig:231`)

- **签名**：`fn parseLimitKBytes(text: []const u8) !usize`。
- **作用**：把十进制「KB」乘 1024。
- **实现**：空串 `InvalidCharacter`；`parseAsciiInt` 后 `mul`，溢出 `Overflow`。
- **所有权 / 错误 / 调用**：`--memory-limit` / `--stack-size`；`applyOption` 把任何错误变成 Usage。

### `printUsage` (`src/cli/zjs.zig:237`)

- **签名**：`fn printUsage(io: std.Io) !void`。
- **作用**：把契约写到 stderr。
- **实现**：两行：`zjs [flags] -e <script>`、`zjs [flags] [-m|-s] <file.js>`。
- **所有权 / 错误 / 调用**：`parseArgs` 失败。随后 `exit(2)`。

---

## `zjs.zig`：进程编排

### `main` (`src/cli/zjs.zig:241`)

- **签名**：`pub fn main(init: std.process.Init) !void`。
- **作用**：解析 argv，然后把作业交给 `execute`。
- **实现**：`init.minimal.args.toSlice`；`parseArgs` 失败 → usage + `exit(2)`；否则 `execute`。
- **所有权 / 错误 / 调用**：argv 在 arena。`execute` 失败向上传。

### `execute` (`src/cli/zjs.zig:250`)

- **签名**：`fn execute(init: std.process.Init, command: *Command) !void`。
- **作用**：造引擎、求值、排 job、报告、按合同退出。
- **实现**：
  1. `loadSource`：`source` 已在则跳过（`-e`）；否则 `readFileAlloc` 上限 64 MiB，失败 `exit(1)`。不改 `command.mode`。返回值是 gpa 拥有的文件缓冲（`-e` 为 `null`），`defer free`。
  2. 用已经填好的 `command.source` / `path` / `mode` / `script_args`。
  3. `Runtime.create` + `Context.create`，再在 `execute` 栈上 `EventLoop.init` / `install`。`configureRuntime`。
  4. `--profile-opcodes` 在非 profile 构建上拒并 `exit(2)`。`Context.defineScriptArgs`。`setPreserveUncaughtException(true)`。无条件 `installDynamicImport`（对齐 qjs 始终装 module loader，使 `-e` 与脚本里的 `import()` 也能解析）。
  5. `runIncludeFiles`；失败走 `failEvaluation`。
  6. `--bytecode-fingerprint`：只接受 `loadSource` 读出来的文件（`owned_source != null`），编译不跑，用已写好的 `command.mode` 打印指纹后 `return`。
  7. `evalSource`（路径与已填好的 `mode`）。失败走 `failEvaluation`（`!noreturn`，catch 臂不需要 `unreachable`）。
  8. 返回 exception 哨兵 → stderr + `exit(1)`。
  9. `dynamic_import_state.runJobs`（模块续体 + `drainPendingPromiseJobs` 的宿主臂顺序），flush stdout。
  10. 若有 unhandled rejection / exception：`reportUnhandledRejections`（**共用一个** stderr writer），`exit(1)`。对齐 `js_std_promise_rejection_check`。
  11. `dumpRequested`：可选 dump memory / opcode profile / gc 面板。
  12. `printSmallInlineProbe`。`--leak-check`：先 `dynamic_import_scope.deinit`（idempotent，避免 defer 在 runtime 死后跑），再按 loop → context → runtime 拆后正常 return。否则 `exit(0)`。默认成功走 `exit(0)`，把拆卸交给 OS，避免 test262 把 `destroy` 断言/回溯误报成超时。
- **所有权 / 错误 / 调用**：`loadSource` 读盘得到的缓冲由 gpa 拥有，`execute` `defer free`；`-e` 的源借用 argv。`exit` 会跳过其余 defer。event loop 的 `output` 借用 stdout writer。`errdefer` 覆盖 create/install 失败。

### `loadSource` (`src/cli/zjs.zig:378`)

- **签名**：`fn loadSource(command: *Command, allocator: std.mem.Allocator, io: std.Io) !?[]const u8`。
- **作用**：若还没有源文本，按 `command.path` 读盘。不改 `command.mode`。
- **实现**：`source != null` 则已是 `-e` 的 argv 文本，返回 `null`（不比较路径字符串，名为 `<eval>` 的文件照常读盘）。否则 `readFileAlloc`（`max_source_size`）写入 `command.source`；失败打路径+errorName 后 `exit(1)`。
- **所有权 / 错误 / 调用**：读盘缓冲由 gpa 拥有，返回给 `execute` `defer free`。`-e` 借用 argv，不分配。单测钉 `-e "export …"` 保持 script。

### `configureRuntime` (`src/cli/zjs.zig:388`)

- **签名**：`fn configureRuntime(rt: *zjs.Runtime, ctx: *zjs.Context, script_args, runtime_options, opcode_profile, io) !void`。
- **作用**：把 CLI 选项写进已造好的引擎：GC 开关、profile、`scriptArgs`、保留未捕获异常。
- **实现**：`applyRuntimeOptions`；`setTrackUnhandledRejections(true)`。`--profile-opcodes` 在非 profile 构建 `exit(2)`，否则 `setOpcodeProfile`。`defineScriptArgs` 失败 `exit(1)`。`setPreserveUncaughtException(true)`。
- **所有权 / 错误 / 调用**：`execute` setup。`opcode_profile` 必须活过求值。

### `applyRuntimeOptions` (`src/cli/zjs.zig:412`)

- **签名**：`fn applyRuntimeOptions(rt: *zjs.Runtime, ctx: *zjs.Context, runtime_options: RuntimeOptions) void`。
- **作用**：把 CLI 选项写进引擎。
- **实现**：写 `detailed_reports` / `mark_footprint_census` 后 `gc.refreshBarrierGate`；`setCanBlock`；可选 `setMemoryLimit`；可选 `setStackSize` + `setStackLimit`。
- **所有权 / 错误 / 调用**：`configureRuntime`。

### `failEvaluation` (`src/cli/zjs.zig:426`)

- **签名**：`fn failEvaluation(ctx: *zjs.Context, rt: *zjs.Runtime, event_loop: *zjs.EventLoop, output: *std.Io.Writer, io: std.Io, err: anyerror) !noreturn`。
- **作用**：include/eval 失败的统一出口：`ProcessExit`、异常、否则 error 名。
- **实现**：`exitIfRequested`。有 exception 先 flush stdout。`printEvaluationError` + `exit(1)`。
- **所有权 / 错误 / 调用**：打印失败会把 error 传回 `execute`；其余路径都 `exit`，返回类型 `!noreturn` 让编译器证明这一点，调用处直接 `catch |err| try failEvaluation(...)`。

### `exitIfRequested` (`src/cli/zjs.zig:440`)

- **签名**：`fn exitIfRequested(event_loop: *zjs.EventLoop, output: *std.Io.Writer, err: anyerror) !void`。
- **作用**：脚本里 `std.exit` 一类请求变成进程退出。
- **实现**：仅当 `err == error.ProcessExit` 且 `event_loop.exitCode()` 非空：flush output，`std.process.exit(code)`。否则 return。
- **所有权 / 错误 / 调用**：`failEvaluation`。

---

## 求值

### `evalScript` (`src/cli/zjs.zig:449`)

- **签名**：`fn evalScript(ctx, source_text, output, filename) !zjs.Value`。
- **作用**：按 CLI 合同跑一段 script：`discard_script_result`，非 strict。
- **实现**：`ctx.eval` 固定 `.mode = .script`，`parse_strict`/`runtime_strict` 为 false。
- **所有权 / 错误 / 调用**：`evalSource` 的 script 臂（`-e` 与 `-s`）。

### `evalSource` (`src/cli/zjs.zig:465`)

- **签名**：`fn evalSource(ctx, source_text, output, path, mode, io, allocator) !zjs.Value`。
- **作用**：按已经填好的模式跑 script 或模块图。`-e` 与文件共用。
- **实现**：`.module` 则 `runFileModule`，否则 `evalScript`。`mode` 来自 `Command`（文件默认 module；`-e`/`-s` 为 script）。
- **所有权 / 错误 / 调用**：`execute` 与 `runIncludeFiles`。

### `runFileModule` (`src/cli/zjs.zig:480`)

- **签名**：`fn runFileModule(ctx, source_text, output, path, io, allocator, max_size) !zjs.Value`。
- **作用**：文件模块图求值入口。
- **实现**：`zjs.exec.module_graph.evalFileModuleGraphWithOutput`。
- **所有权 / 错误 / 调用**：`evalSource` 在 `mode == .module` 时。

### `runIncludeFiles` (`src/cli/zjs.zig:501`)

- **签名**：`pub fn runIncludeFiles(ctx, runtime_options, output, io, allocator) !void`。
- **作用**：按顺序预求值 `-I` 文件。
- **实现**：每条路径 `readFileAlloc`（64 MiB），一律按 module `evalSource`。
- **所有权 / 错误 / 调用**：每文件 defer free。失败让 `execute` 走 `failEvaluation`。主脚本之前执行。

### `printBytecodeFingerprint` (`src/cli/zjs.zig:519`)

- **签名**：`pub fn printBytecodeFingerprint(output, ctx, source_text, path, mode, verbose) !void`。
- **作用**：编译但不跑，打印 FunctionBytecode 树的稳定指纹（parser identity gate）。
- **实现**：`parser.compile`；语法错误/无产物打对应行。成功则 Wyhash 扫整棵 cpool 树，打 `{hash} functions=N path`。verbose 再打每函数的 code hex。
- **所有权 / 错误 / 调用**：`compiled.deinit`。`execute` 在 `owned_source == null`（`-e`）时先拒。

### `fingerprintFunctionBytecode` (`src/cli/zjs.zig:555`)

- **签名**：`fn fingerprintFunctionBytecode(hasher, fb, function_count, verbose) void`。
- **作用**：把一个 FunctionBytecode 及其 cpool 子函数喂进 hasher。
- **实现**：code 长度+字节、标量字段、cpool：子 fb 递归；tracer-owned 哈希 tag（字符串再哈希内容，不哈希地址）；其它 bitcast u64。
- **所有权 / 错误 / 调用**：verbose 写失败吞掉（`catch {}`），以免诊断打印破坏 hasher 路径。

---

## 异常报告

### `printEvaluationError` (`src/cli/zjs.zig:606`)

- **签名**：`fn printEvaluationError(io: std.Io, ctx: *zjs.Context, rt: *zjs.Runtime, err: anyerror) !void`。
- **作用**：求值失败时打异常或 Zig error 名。
- **实现**：有 exception/rejection 则 `printExceptionValue`；否则 `zjs: evaluation failed: {errorName}`。
- **所有权 / 错误 / 调用**：`failEvaluation`。`exit(1)` 之前。

### `printExceptionValue` (`src/cli/zjs.zig:619`)

- **签名**：`fn printExceptionValue(stderr: *std.Io.Writer, ctx: *zjs.Context, rt: *zjs.Runtime, value: zjs.Value) !bool`。
- **作用**：对象异常打 `formatException` + 可选 stack。
- **实现**：非对象返回 false。空 header 打 `Error\n`。`formatExceptionStack` 若在取栈时又抛，clear 后当无栈。flush。
- **所有权 / 错误 / 调用**：header/stack 用 runtime allocator，defer free。

### `printUnhandledRejectionTo` (`src/cli/zjs.zig:652`)

- **签名**：`fn printUnhandledRejectionTo(stderr: *std.Io.Writer, ctx: *zjs.Context, rt: *zjs.Runtime, value: zjs.Value) !void`。
- **作用**：一条「Possibly unhandled promise rejection:」报告。
- **实现**：int/bool/undefined/null/string/object 分支；对象走 `printExceptionValue`。循环必须复用同一 writer。
- **所有权 / 错误 / 调用**：对齐 qjs `js_std_promise_rejection_check`。

### `reportUnhandledRejections` (`src/cli/zjs.zig:676`)

- **签名**：`fn reportUnhandledRejections(io: std.Io, ctx: *zjs.Context, rt: *zjs.Runtime) !void`。
- **作用**：按拒绝顺序把仍未处理的 rejection 全部打到 stderr。
- **实现**：一个 stderr writer，循环 `takePendingException` + `printUnhandledRejectionTo`，直到没有 unhandled rejection。
- **所有权 / 错误 / 调用**：`execute` 在 job 排水之后。随后 `exit(1)`。

---

## 诊断打印

### `dumpMemoryUsage` (`src/cli/zjs.zig:687`)

- **签名**：`fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *zjs.Runtime) !void`。
- **作用**：`-d` 出口内存表。
- **实现**：`dumpMemorySnapshot(output, runtime.memoryUsage())`。
- **所有权 / 错误 / 调用**：`dumpRequested`。写失败向上。

### `dumpMemorySnapshot` (`src/cli/zjs.zig:691`)

- **签名**：`fn dumpMemorySnapshot(output: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage) !void`。
- **作用**：固定列宽打印 limit / atoms / objects / shapes / modules / classes。
- **实现**：limit 缺省打 `0`。行格式 `{s:<22} {d:>5} {d:>8}`。单测钉宽度与字段。
- **所有权 / 错误 / 调用**：`dumpMemoryUsage`、单测。

### `dumpRequested` (`src/cli/zjs.zig:712`)

- **签名**：`fn dumpRequested(stdout, runtime, runtime_options, opcode_profile) !void`。
- **作用**：按旗标顺序打出口面板，顺序与历史 `main` 合同相同。
- **实现**：`dump_memory` →（profile 构建且 `--profile-opcodes`）opcode 表 → `gc_stats` 则 `dumpGcPanels`。各项 flush stdout。
- **所有权 / 错误 / 调用**：`execute` 在 job 排水且无未处理 rejection 之后。

### `dumpGcPanels` (`src/cli/zjs.zig:733`)

- **签名**：`fn dumpGcPanels(writer, runtime, runtime_options) !void`。
- **作用**：`--gc-stats` 整组面板，含 gate-settle 的 endpoint/settled doomed 行。
- **实现**：可选 settle 前 doomed → stats / atom audit / major pauses / space / block heap → 可选 block census → mark footprint / phase totals / generation → 可选 conservative diag → 收尾 doomed。
- **所有权 / 错误 / 调用**：行顺序是面板合同，解析器按行消费。

### `dumpGcSpaceStats` (`src/cli/zjs.zig:784`)

- **签名**：`fn dumpGcSpaceStats(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void`。
- **作用**：分配直方图 p50/p95/p99、small 覆盖、large 计数。
- **实现**：读 `space_histogram`。只打印有写点的字段。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcBlockCensus` (`src/cli/zjs.zig:808`)

- **签名**：`fn dumpGcBlockCensus(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void`。
- **作用**：TGC S4-f：每 size-class 的 block 占用。纯退出时 walk，不在分配热路径。
- **实现**：`censusBlocks()`，列 blocks/cells/allocated/occ_x1000/empty/lt10/lt50/ge50/young/decommitted/active/hot/free，再打 total。
- **所有权 / 错误 / 调用**：`--gc-block-census`（蕴含 gc-stats）。

### `writeCounterLine` (`src/cli/zjs.zig:869`)

- **签名**：`noinline fn writeCounterLine(writer: *std.Io.Writer, parts: []const struct { []const u8, u64 }, suffix: []const u8) !void`。
- **作用**：GC 面板共用的整数行格式化：把 `(label, u64)` 片段串成一行再加后缀。
- **实现**：对 `parts` 逐段 `writer.print("{s}{d}", .{label, value})`，再 `writeAll(suffix)`。outlined 是为了在冷诊断行之间共享格式化，同时让每条调用点的 label/value/suffix 仍显式写出。
- **所有权 / 错误 / 调用**：不分配。写失败上抛。`dumpGcBlockCensus` / `dumpGcGenerationStats` / `writeDoomedStateLine` 等。

### `dumpGcGenerationStats` (`src/cli/zjs.zig:877`)

- **签名**：`fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *zjs.core.gc.Registry) !void`。
- **作用**：分代计数、minor 暂停分位、barrier、增量 major。
- **实现**：多行 `writeCounterLine`。`remembered without young` 是写屏障过火的观察点。`verify_minor` 关则打 unavailable。
- **所有权 / 错误 / 调用**：`--gc-stats`。单测钉填充快照。

### `dumpGcBlockHeapStats` (`src/cli/zjs.zig:1004`)

- **签名**：`fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void`。
- **作用**：superblock 提交/热复用/decommit/trim、析构计数。
- **实现**：`plain-object destructor calls` 必须为 0（无 payload 的普通对象不该进析构）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcPhaseTotals` (`src/cli/zjs.zig:1063`)

- **签名**：`fn dumpGcPhaseTotals(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void`。
- **作用**：增量 STW 子阶段 ns 与 begin/finish 对账残差。
- **实现**：八字段主行保持给解析器；finish-init/tail 在对账行。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcMarkFootprint` (`src/cli/zjs.zig:1103`)

- **签名**：`fn dumpGcMarkFootprint(writer: *std.Io.Writer, rt: *const zjs.core.JSRuntime) !void`。
- **作用**：`--gc-mark-footprint` 的 marked-set/storage 普查。未开普查时明确说没跑，避免全 0 被读成「什么都没标」。
- **实现**：按 GcKind、MarkTraceClass、MarkStorageComponent、inline 上限槽打印。string 含 rope。storage = property+array+payload。
- **所有权 / 错误 / 调用**：开普查会在每次 final remark 走整堆，Splay 分数会动。

### `dumpGcStats` (`src/cli/zjs.zig:1188`)

- **签名**：`fn dumpGcStats(writer: *std.Io.Writer, stats: zjs.GCStats, registry: *const zjs.core.gc.Registry) !void`。
- **作用**：收集次数、释放对象、live/peak、external 计价、weak/finalizer 队列。
- **实现**：external 与 allocation_debt 分行，避免把 pacing 计数当 live。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpAtomAuditStats` (`src/cli/zjs.zig:1229`)

- **签名**：`fn dumpAtomAuditStats(writer: *std.Io.Writer, rt: *const zjs.Runtime) !void`。
- **作用**：TGC S3 atom 边审计。
- **实现**：`stale-edge` 必须 0；`shell-edge` 合法（WeakRef shell）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcDoomedState` (`src/cli/zjs.zig:1237`)

- **签名**：`fn dumpGcDoomedState(writer: *std.Io.Writer, layer: []const u8, rt: *const zjs.Runtime) !void`。
- **作用**：打印 doomed 队列快照，layer 为 `"endpoint"` 或 `"settled"`。
- **实现**：`doomedStateSnapshot` + `writeDoomedStateLine`。
- **所有权 / 错误 / 调用**：`--gc-gate-settle` 在 settle 前后各打一次。

### `writeDoomedStateLine` (`src/cli/zjs.zig:1241`)

- **签名**：`fn writeDoomedStateLine(writer, layer, state: zjs.core.gc_trace_stw.DoomedStateSnapshot) !void`。
- **作用**：固定字段顺序的 doomed 行。
- **实现**：bool 打 true/false，计数经 `writeCounterLine`。单测钉混合 bool。
- **所有权 / 错误 / 调用**：`dumpGcDoomedState`。

### `dumpGcPauses` (`src/cli/zjs.zig:1273`)

- **签名**：`fn dumpGcPauses(writer: *std.Io.Writer, distribution: ?zjs.GCPauseDistribution) !void`。
- **作用**：只报 **major** 暂停分位。空分布打 `major pauses none`，绝不打全 0。
- **实现**：minors 另有 generation 行。混在一起会让 p50 变成 minor。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpOpcodeProfile` (`src/cli/zjs.zig:1289`)

- **签名**：`fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：人类可读 opcode 表（默认前 40；`ZJS_PROFILE_ALL=1` 打全部执行过的）。
- **实现**：`not instrumented` 的判定用 `profile_counters_uninstrumented`；`allocations` 无条件打真值。额外打印 `using` 子形式（D12：禁止聚合成一行）和 SemanticFamily rollup（生成聚合，不替代 per-form）。
- **所有权 / 错误 / 调用**：`--profile-opcodes`。`getenv` 读 `ZJS_PROFILE_ALL`。

### `sortedOpcodeProfileRows` (`src/cli/zjs.zig:1377`)

- **签名**：`fn sortedOpcodeProfileRows(profile, rows) []OpcodeProfileRow`。
- **作用**：把非零 opcode 收成行并按时间/次数/opcode 排序。
- **实现**：填充调用方提供的 `rows` 缓冲，`sort_erased.heap` + `opcodeProfileRowLessThan`。返回切片别名该缓冲。
- **所有权 / 错误 / 调用**：不分配。`dumpOpcodeProfile`。

### `opcodeProfileRowLessThan` (`src/cli/zjs.zig:1393`)

- **签名**：`fn opcodeProfileRowLessThan(_: void, lhs: OpcodeProfileRow, rhs: OpcodeProfileRow) bool`。
- **作用**：按 nanos 降序、count 降序、opcode 升序。
- **实现**：三键比较。
- **所有权 / 错误 / 调用**：heap sort 回调。

### `ensureOpcodeProfileNames` (`src/cli/zjs.zig:1399`)

- **签名**：`fn ensureOpcodeProfileNames() void`。
- **作用**：激活一次 opcode 名字表（即使当前没挂 profile）。
- **实现**：`activateOpcodeProfile(null)` 再恢复 previous。
- **所有权 / 错误 / 调用**：dump 前。

### `initOpcodeProfile` (`src/cli/zjs.zig:1407`)

- **签名**：`pub fn initOpcodeProfile(profile: *zjs.OpcodeProfile) void`。
- **作用**：零初始化 profile，避免 18 KiB `.rodata` 的 `OpcodeProfile{}` 拷贝。
- **实现**：`zeroes` 后把 `pending_op` 设回 `no_pending_op` 哨兵。
- **所有权 / 错误 / 调用**：`execute` 栈上 profile。单测 `expectEqualDeep(OpcodeProfile{}, profile)`。

---

## 覆盖核对

- 清单函数数: 51（`src/cli/cli_process.zig` 3 + `src/cli/zjs.zig` 48）
- 本文标题覆盖: 51
- 未覆盖: 无
