# 18 — CLI（`src/cli/zjs.zig`、`cli_process.zig`、`panic_policy.zig`）

`zjs` / `zjs-dev` / `zjs-profile` / `zjs-size` 共用这一根。comptime `config_signature.attest("zjs CLI")`，并检查 `builtin.mode` 与签名里的 optimize 一致。`pub const panic` 来自 `panic_policy.zig`。

argv 合同见 [18-runtime-cli-abi.md](18-runtime-cli-abi.md)。本文件按函数展开。

## 文件级类型

### `src/cli/panic_policy.zig`（零函数）

`pub const policy`：`ReleaseFast` → `std.debug.simple_panic`（只打消息，不带符号器）；其它模式 → `FullPanic(defaultPanic)`。发行 tarball 是 stripped ReleaseFast，完整 handler 会链上 ELF/DWARF/flate 与两份 `std.sort.block`，约 209 KB 且一帧都解不出。`zjs-dev`、测试、带断言的构建仍打解析后的栈。

### `CliError` / `Command` / `RuntimeOptions` / `EvalCommand` / `FileCommand`

`CliError = error{Usage}`。`Command` 是 `eval` | `file`。`RuntimeOptions` 收集内存上限、栈、can_block、dump/trace/profile/gc/perf/leak-check，以及最多 16 条 `-I` 路径。`EvalCommand` 持源切片（指向 argv，不拥有）；`FileCommand` 持路径、`script_args`（含路径自身）、`EvalMode`。

### `Runtime`（`zjs.zig:29`）

把 `JSRuntime`、`JSContext`、已 install 的 `EventLoop` 捆在一起。`deinit` 按 loop → context → runtime 拆。成功路径默认不调（见 `main`）。

### `PerfJsonTimings` / `OpcodeProfileRow`

冷路径诊断结构。`writeCounterLine`（`noinline`）是 GC 面板共用的整数行格式化，供 `gc_stats_snapshot.py` 解析。

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

### `Runtime.deinit` (`src/cli/zjs.zig:34`)

- **签名**：`pub fn deinit(self: *Runtime) void`。
- **作用**：按依赖顺序拆循环、context、runtime。
- **实现**：`event_loop.deinit` → `context.destroy` → `runtime.destroy`。后者在测试里断言无未释放分配。
- **所有权 / 错误 / 调用**：唯一调用点是 `main` 里 `--leak-check` 的成功路径（早期失败走的是三条各自的 `errdefer rt.destroy()` / `ctx.destroy()` / `event_loop.deinit()`）。默认成功走 `exit(0)`，把拆卸交给 OS，避免 test262 把 `destroy` 断言/回溯误报成超时。

### `RuntimeOptions.addInclude` (`src/cli/zjs.zig:68`)

- **签名**：`fn addInclude(self: *RuntimeOptions, path: []const u8) !void`。
- **作用**：追加一条 `-I` 预加载路径。
- **实现**：满 16 条 `error.TooManyIncludes`；否则写入 `include_paths[include_count]`。
- **所有权 / 错误 / 调用**：路径切片借用 argv。`parseArgs` 把该错误映射成 `Usage`。

### `RuntimeOptions.includes` (`src/cli/zjs.zig:74`)

- **签名**：`fn includes(self: *const RuntimeOptions) []const []const u8`。
- **作用**：已登记 include 的视图。
- **实现**：`include_paths[0..include_count]`。
- **所有权 / 错误 / 调用**：`runIncludeFiles`。

### `parseArgs` (`src/cli/zjs.zig:91`)

- **签名**：`pub fn parseArgs(args: []const []const u8) CliError!Command`。
- **作用**：把 argv（不含 argv0）收成 `Command`；非法则 `error.Usage`。
- **实现**：先扫旗标：`--can-block`、`-d/--dump`、`-T/--trace`、`--gc-stats`（顺带 `detailed_reports=true`）、`--gc-gate-settle`（蕴含 gc-stats）、`--gc-block-census`、`--gc-mark-footprint`（另开 `mark_footprint_census`，会动分数，不是尺子）、`--profile-opcodes`、`--perf-json`、`--leak-check`、`--memory-limit`/`--stack-size`（缺值或非十进制 → Usage）、`-I/--include`。未知以 `-` 开头且不是位置参数 → Usage。空 rest、`-h`/`--help` → Usage。`-e`：若 `can_block` 或 `rest.len != 2` → Usage，否则 `eval`。`-m`：至少再跟一个路径，`mode=.module`，`script_args = rest[1..]`（含路径）。不以 `-` 开头的词当文件路径，`script_args = rest[0..]`。
- **所有权 / 错误 / 调用**：不分配。`main` catch 后 `printUsage` + `exit(2)`。单测覆盖 eval/file/module/limits/includes/拒绝退休旗标。

### `runFileModule` (`src/cli/zjs.zig:206`)

- **签名**：`fn runFileModule( ctx: *zjs.JSContext, source_text: []const u8, output: *std.Io.Writer, path: []const u8, io: std.Io, allocator: std.mem.Allocator, max_size: usize, ) !zjs.JSValue`。
- **作用**：文件模块图求值入口。
- **实现**：`runtime_layer.evalFileModuleGraphWithOutput`。
- **所有权 / 错误 / 调用**：`main` 在 detect 为 module 时、`runIncludeFiles` 对 `.mjs`/首 token export/import。

### `main` (`src/cli/zjs.zig:218`)

- **签名**：`pub fn main(init: std.process.Init) !void`。
- **作用**：CLI 全过程：签名查询、解析 argv、造引擎、求值、排 job、报告、按合同退出。
- **实现**：
  1. `setupV2OracleReportExitDump`。
  2. `argsToSlice`。若 `args[1] == --print-config-signature` 则打印签名 return（不造 Runtime）。
  3. `parseArgs` 失败 → usage + `exit(2)`。
  4. eval 用 argv 源；file 用 `readFileAlloc` 上限 64 MiB，失败 `exit(1)`。
  5. `JSRuntime.createWithOptions`（trace writer、memory_limit、默认 gc threshold、stack_size）+ `JSContext.create`；失败 `exit(1)`。
  6. `EventLoop.init` + `install`。`applyRuntimeOptions`。eval/file 都 `setTrackUnhandledRejections(true)`。`--profile-opcodes` 在非 profile 构建上拒并 `exit(2)`；`--perf-json` 可激活 profile 计数。
  7. `host.defineScriptArgs`。`setPreserveUncaughtException(true)`。无条件 `installDynamicImport`（对齐 qjs 始终装 module loader，使 `-e` 与脚本里的 `import()` 也能解析）。
  8. `runIncludeFiles`；`error.ProcessExit` 走 `exitIfRequested`。
  9. eval：`ctx.eval(..., filename="<eval>", discard_script_result)`。file：`detectFileMode` 后模块图或 script eval（filename=路径）。
  10. 返回 exception 哨兵 → stderr + `exit(1)`。
  11. `dynamic_import_state.runJobs`（模块续体 + `drainPendingPromiseJobs` 的宿主臂顺序），flush stdout。
  12. 若有 unhandled rejection / exception：循环 `takePendingRejectionOrException` + `printUnhandledRejectionTo`（**共用一个** stderr writer，避免重定向到普通文件时互相覆盖），`exit(1)`。对齐 `js_std_promise_rejection_check`。
  13. 可选 dump memory / opcode profile / gc 面板 / perf JSON。
  14. `printSmallInlineProbe`。`--leak-check`：先 `dynamic_import_scope.deinit`（idempotent，避免 defer 在 runtime 死后跑），再 `runtime.deinit` 后正常 return。否则 `exit(0)`。
- **所有权 / 错误 / 调用**：源文件缓冲由 gpa 拥有，file 路径 `defer free`；`exit` 会跳过其余 defer。event loop 的 `output` 借用 stdout writer。

### `printUsage` (`src/cli/zjs.zig:482`)

- **签名**：`fn printUsage(io: std.Io) !void`。
- **作用**：把契约写到 stderr。
- **实现**：三行：`zjs [flags] -e <script>`、`zjs [flags] [-m] <file.js>`、`zjs --print-config-signature`。
- **所有权 / 错误 / 调用**：`parseArgs` 失败。随后 `exit(2)`。

### `printConfigSignature` (`src/cli/zjs.zig:490`)

- **签名**：`fn printConfigSignature(io: std.Io) !void`。
- **作用**：打印编译期配置签名（QCP-1）。
- **实现**：stdout 一行 `engine.config_signature.signature` 后 flush。
- **所有权 / 错误 / 调用**：`main` 在任何引擎构造之前。`zig build config-signature-check` 消费。

### `commandRuntimeOptions` (`src/cli/zjs.zig:498`)

- **签名**：`fn commandRuntimeOptions(command: Command) RuntimeOptions`。
- **作用**：从 eval/file 抽出选项。
- **实现**：switch 返回对应 `.options`。
- **所有权 / 错误 / 调用**：`main` 多处。

### `commandTracksUnhandledRejections` (`src/cli/zjs.zig:505`)

- **签名**：`fn commandTracksUnhandledRejections(command: Command) bool`。
- **作用**：CLI 是否跟踪未处理 rejection。
- **实现**：eval 与 file 都 `true`。
- **所有权 / 错误 / 调用**：`setTrackUnhandledRejections`。

### `commandScriptArgs` (`src/cli/zjs.zig:511`)

- **签名**：`fn commandScriptArgs(command: Command) []const []const u8`。
- **作用**：给 `scriptArgs` 全局。
- **实现**：eval 空切片；file 为路径+其后参数。
- **所有权 / 错误 / 调用**：`host.defineScriptArgs`。借用 argv。

### `applyRuntimeOptions` (`src/cli/zjs.zig:518`)

- **签名**：`fn applyRuntimeOptions(runtime: *Runtime, options: RuntimeOptions) void`。
- **作用**：把 CLI 选项写进引擎。
- **实现**：`setCanBlock`；可选 `setMemoryLimit`；可选 `setStackSize` + `setStackLimit`。
- **所有权 / 错误 / 调用**：`main` setup。

### `exitIfRequested` (`src/cli/zjs.zig:527`)

- **签名**：`fn exitIfRequested(runtime: *Runtime, output: *std.Io.Writer, err: anyerror) !void`。
- **作用**：脚本里 `std.exit` 一类请求变成进程退出。
- **实现**：仅当 `err == error.ProcessExit` 且 `event_loop.exitCode()` 非空：flush output，`std.process.exit(code)`。否则 return。
- **所有权 / 错误 / 调用**：include / eval 的 catch。

### `runIncludeFiles` (`src/cli/zjs.zig:534`)

- **签名**：`fn runIncludeFiles(runtime: *Runtime, options: RuntimeOptions, output: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator) !void`。
- **作用**：按顺序预求值 `-I` 文件。
- **实现**：每条路径 `readFileAlloc`（64 MiB），`detectFileMode` 后模块图或 script eval（`discard_script_result`）。
- **所有权 / 错误 / 调用**：每文件 defer free。失败让 `main` 走异常打印。主脚本之前执行。

### `parseLimitKBytes` (`src/cli/zjs.zig:553`)

- **签名**：`fn parseLimitKBytes(text: []const u8) !usize`。
- **作用**：把十进制「KB」乘 1024。
- **实现**：空串 `InvalidCharacter`；`parseAsciiInt` 后 `mul`，溢出 `Overflow`。
- **所有权 / 错误 / 调用**：`--memory-limit` / `--stack-size`；`parseArgs` 把任何错误变成 Usage。

### `detectFileMode` (`src/cli/zjs.zig:559`)

- **签名**：`fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: zjs.context.EvalMode) zjs.context.EvalMode`。
- **作用**：决定 script vs module。
- **实现**：显式 `.module` 优先；`.mjs` 后缀；否则 `sourceLooksLikeModule`。
- **所有权 / 错误 / 调用**：`main`、`runIncludeFiles`。

### `sourceLooksLikeModule` (`src/cli/zjs.zig:570`)

- **签名**：`fn sourceLooksLikeModule(source: []const u8) bool`。
- **作用**：对齐 qjs `JS_DetectModule`（quickjs.c:23792）：shebang 后**只看第一个 token**。
- **实现**：`skipShebang` 后 `simple_token.next`。`import` 且下一 token 不是 `.`/`(` → 模块；`export` → 模块；其它（含 `import()`、`import.meta`、靠后的 export）→ 脚本（后者在 script 模式是 SyntaxError，与 qjs 一致）。
- **所有权 / 错误 / 调用**：`detectFileMode`。单测钉首 token / shebang / 晚 export。

### `skipShebang` (`src/cli/zjs.zig:584`)

- **签名**：`fn skipShebang(source: []const u8, pos: *usize) void`。
- **作用**：对齐 qjs `skip_shebang`（quickjs.c:23761）。
- **实现**：`#!` 则扫到 `\n`/`\r`，写回 `pos`。
- **所有权 / 错误 / 调用**：`sourceLooksLikeModule`。无 shebang 不改 pos（调用方从 0 开始）。

---

## 诊断打印

### `dumpMemoryUsage` (`src/cli/zjs.zig:592`)

- **签名**：`fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *Runtime) !void`。
- **作用**：`-d` 出口内存表。
- **实现**：`dumpMemorySnapshot(output, runtime.runtime.memoryUsage())`。
- **所有权 / 错误 / 调用**：`main` 在 job 排水之后。写失败向上。

### `dumpMemorySnapshot` (`src/cli/zjs.zig:596`)

- **签名**：`fn dumpMemorySnapshot(output: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage) !void`。
- **作用**：固定列宽打印 limit / atoms / objects / shapes / modules / classes。
- **实现**：limit 缺省打 `0`。行格式 `{s:<22} {d:>5} {d:>8}`。单测钉宽度与字段。
- **所有权 / 错误 / 调用**：`dumpMemoryUsage`、单测。

### `dumpPerfJson` (`src/cli/zjs.zig:628`)

- **签名**：`fn dumpPerfJson(io: std.Io, command: Command, runtime: *Runtime, perf_profile: ?*const zjs.OpcodeProfile, timings: PerfJsonTimings) !void`。
- **作用**：`--perf-json` 把计时、内存、可选 opcode/IC 打到 **stderr**。
- **实现**：对象：`file`、metrics、`opcode_profile_enabled`、有 profile 则 opcode_profile + ic。flush。
- **所有权 / 错误 / 调用**：不污染脚本 stdout。`main`。

### `dumpPerfJsonMetrics` (`src/cli/zjs.zig:649`)

- **签名**：`fn dumpPerfJsonMetrics(stderr: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage, timings: PerfJsonTimings) !void`。
- **作用**：JSON 计时与 memory 子对象。
- **实现**：`writeCounterLine` 串 `total_ns`…`jobs_ns` 与 allocation 计数。`finalize_ns` 恒 `null`，`parse_ns_includes_finalize: true`（解析阶段含 finalize）。
- **所有权 / 错误 / 调用**：不分配。唯一调用方 `dumpPerfJson`；本文件的单测「zjs perf JSON metrics preserve populated fields」（`src/cli/zjs.zig:1934`）逐字段钉住它的输出并验证写失败。

### `dumpPerfJsonOpcodeProfile` (`src/cli/zjs.zig:672`)

- **签名**：`fn dumpPerfJsonOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：非零 opcode 行的 JSON 数组。
- **实现**：收 `OpcodeProfileRow`，按 nanos/count/opcode 排。profile 构建里 nanos/dups/allocations 等打 `"not instrumented"`。
- **所有权 / 错误 / 调用**：`ensureOpcodeProfileNames` 先激活一次以填名字表。

### `dumpPerfJsonIc` (`src/cli/zjs.zig:732`)

- **签名**：`fn dumpPerfJsonIc(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：IC hit/miss/invalidate/promote 汇总与 per-opcode 数组。
- **实现**：profile 构建输出字符串占位；否则 `writeJsonU64Array`。
- **所有权 / 错误 / 调用**：`dumpPerfJson`。`OpcodeProfile` 的 `ic_hit` / `ic_miss` / `ic_invalidate` / `ic_promote_*` 数组在引擎里没有写点，所以非 profile 构建下这些数也恒为 0。

### `writeJsonU64Array` (`src/cli/zjs.zig:767`)

- **签名**：`fn writeJsonU64Array(output: *std.Io.Writer, values: *const [zjs.OpcodeProfile.opcode_count]u64) !void`。
- **作用**：打 JSON 数组。
- **实现**：`[` 逗号分隔 `{d}` `]`。
- **所有权 / 错误 / 调用**：IC 五个数组。

### `commandPerfFile` (`src/cli/zjs.zig:776`)

- **签名**：`fn commandPerfFile(command: Command) []const u8`。
- **作用**：perf JSON 的 `file` 字段。
- **实现**：eval → `"<eval>"`；file → 路径。
- **所有权 / 错误 / 调用**：借用。

### `writeJsonString` (`src/cli/zjs.zig:783`)

- **签名**：`fn writeJsonString(output: *std.Io.Writer, bytes: []const u8) !void`。
- **作用**：JSON 字符串转义。
- **实现**：`"` `\` `\n\r\t`；`<0x20` 用 `\u00XX`；其余原样。
- **所有权 / 错误 / 调用**：文件名、opcode 名。

### `dumpGcSpaceStats` (`src/cli/zjs.zig:813`)

- **签名**：`fn dumpGcSpaceStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：分配直方图 p50/p95/p99、small 覆盖、large 计数。
- **实现**：读 `space_histogram`。只打印有写点的字段。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcBlockCensus` (`src/cli/zjs.zig:837`)

- **签名**：`fn dumpGcBlockCensus(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：TGC S4-f：每 size-class 的 block 占用。纯退出时 walk，不在分配热路径。
- **实现**：`censusBlocks()`，列 blocks/cells/allocated/occ_x1000/empty/lt10/lt50/ge50/young/decommitted/active/hot/free，再打 total。
- **所有权 / 错误 / 调用**：`--gc-block-census`（蕴含 gc-stats）。

### `writeCounterLine` (`src/cli/zjs.zig:898`)

- **签名**：`noinline fn writeCounterLine(writer: *std.Io.Writer, parts: []const struct { []const u8, u64 }, suffix: []const u8) !void`。
- **作用**：GC 面板共用的整数行格式化：把 `(label, u64)` 片段串成一行再加后缀，供 `gc_stats_snapshot.py` 解析。
- **实现**：对 `parts` 逐段 `writer.print("{s}{d}", .{label, value})`，再 `writeAll(suffix)`。outlined 是为了在冷诊断行之间共享格式化，同时让每条调用点的 label/value/suffix 仍显式写出。
- **所有权 / 错误 / 调用**：不分配。写失败上抛。`dumpGcBlockCensus` / `dumpGcGenerationStats` / `writeDoomedStateLine` 等。

### `dumpGcGenerationStats` (`src/cli/zjs.zig:906`)

- **签名**：`fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *engine.core.gc.Registry) !void`。
- **作用**：分代计数、minor 暂停分位、barrier、增量 major。行形冻结给 `gc_stats_snapshot.py`。
- **实现**：多行 `writeCounterLine`。`remembered without young` 是写屏障过火的观察点。`verify_minor` 关则打 unavailable。
- **所有权 / 错误 / 调用**：`--gc-stats`。单测钉填充快照。

### `dumpGcBlockHeapStats` (`src/cli/zjs.zig:1035`)

- **签名**：`fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：superblock 提交/热复用/decommit/trim、析构计数。
- **实现**：`plain-object destructor calls` 必须为 0（无 payload 的普通对象不该进析构）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcPhaseTotals` (`src/cli/zjs.zig:1095`)

- **签名**：`fn dumpGcPhaseTotals(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void`。
- **作用**：增量 STW 子阶段 ns 与 begin/finish 对账残差。
- **实现**：八字段主行保持给解析器；finish-init/tail 在对账行。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcMarkFootprint` (`src/cli/zjs.zig:1136`)

- **签名**：`fn dumpGcMarkFootprint(writer: *std.Io.Writer, rt: *const engine.core.JSRuntime) !void`。
- **作用**：`--gc-mark-footprint` 的 marked-set/storage 普查。未开普查时明确说没跑，避免全 0 被读成「什么都没标」。
- **实现**：按 GcKind、MarkTraceClass、MarkStorageComponent、inline 上限槽打印。string 含 rope。storage = property+array+payload。
- **所有权 / 错误 / 调用**：开普查会在每次 final remark 走整堆，Splay 分数会动。

### `dumpGcStats` (`src/cli/zjs.zig:1221`)

- **签名**：`fn dumpGcStats(writer: *std.Io.Writer, stats: zjs.GCStats, registry: *const engine.core.gc.Registry) !void`。
- **作用**：收集次数、释放对象、live/peak、external 计价、weak/finalizer 队列。
- **实现**：external 与 allocation_debt 分行，避免把 pacing 计数当 live。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpAtomAuditStats` (`src/cli/zjs.zig:1262`)

- **签名**：`fn dumpAtomAuditStats(writer: *std.Io.Writer, rt: *const zjs.JSRuntime) !void`。
- **作用**：TGC S3 atom 边审计。
- **实现**：`stale-edge` 必须 0；`shell-edge` 合法（WeakRef shell）。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpGcDoomedState` (`src/cli/zjs.zig:1270`)

- **签名**：`fn dumpGcDoomedState(writer: *std.Io.Writer, layer: []const u8, rt: *const zjs.JSRuntime) !void`。
- **作用**：打印 doomed 队列快照，layer 为 `"endpoint"` 或 `"settled"`。
- **实现**：`doomedStateSnapshot` + `writeDoomedStateLine`。
- **所有权 / 错误 / 调用**：`--gc-gate-settle` 在 settle 前后各打一次。

### `writeDoomedStateLine` (`src/cli/zjs.zig:1274`)

- **签名**：`fn writeDoomedStateLine( writer: *std.Io.Writer, layer: []const u8, state: engine.core.gc_trace_stw.DoomedStateSnapshot, ) !void`。
- **作用**：固定字段顺序的 doomed 行。
- **实现**：bool 打 true/false，计数经 `writeCounterLine`。单测钉混合 bool 与写失败。
- **所有权 / 错误 / 调用**：`dumpGcDoomedState`。

### `dumpGcPauses` (`src/cli/zjs.zig:1306`)

- **签名**：`fn dumpGcPauses(writer: *std.Io.Writer, distribution: ?zjs.GCPauseDistribution) !void`。
- **作用**：只报 **major** 暂停分位。空分布打 `major pauses none`，绝不打全 0。
- **实现**：minors 另有 generation 行。混在一起会让 p50 变成 minor。
- **所有权 / 错误 / 调用**：`--gc-stats`。

### `dumpOpcodeProfile` (`src/cli/zjs.zig:1322`)

- **签名**：`fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void`。
- **作用**：人类可读 opcode 表（默认前 40；`ZJS_PROFILE_ALL=1` 打全部执行过的）。
- **实现**：排序同 JSON。额外打印 `using` 子形式（D12：禁止聚合成一行）和 SemanticFamily rollup（生成聚合，不替代 per-form）。
- **所有权 / 错误 / 调用**：`--profile-opcodes`。`getenv` 读 `ZJS_PROFILE_ALL`。

### `setupV2OracleReportExitDump` (`src/cli/zjs.zig:1432`)

- **签名**：`fn setupV2OracleReportExitDump(environ_map: *std.process.Environ.Map) void`。
- **作用**：若编译开了 oracle report 且环境变量 `ZJS_V2_ORACLE_REPORT` 非空非 `"0"`，注册 `atexit`。
- **实现**：comptime 关掉则空。`atexit(writeV2OracleReportAtExit)`。
- **所有权 / 错误 / 调用**：`main` 最先。atexit 返回值忽略。

### `writeV2OracleReportAtExit` (`src/cli/zjs.zig:1439`)

- **签名**：`fn writeV2OracleReportAtExit() callconv(.c) void`。
- **作用**：进程退出时打编译器 oracle 报告。
- **实现**：1 KiB 栈缓冲 `formatOracleReport`；空则回；否则 `debug.print`。
- **所有权 / 错误 / 调用**：C atexit。不分配。

### `opcodeProfileRowLessThan` (`src/cli/zjs.zig:1447`)

- **签名**：`fn opcodeProfileRowLessThan(_: void, lhs: OpcodeProfileRow, rhs: OpcodeProfileRow) bool`。
- **作用**：按 nanos 降序、count 降序、opcode 升序。
- **实现**：三键比较。
- **所有权 / 错误 / 调用**：heap sort 回调。

### `ensureOpcodeProfileNames` (`src/cli/zjs.zig:1453`)

- **签名**：`fn ensureOpcodeProfileNames() void`。
- **作用**：激活一次 opcode 名字表（即使当前没挂 profile）。
- **实现**：`activateOpcodeProfile(null)` 再恢复 previous。
- **所有权 / 错误 / 调用**：dump 前。

### `takePendingRejectionOrException` (`src/cli/zjs.zig:1458`)

- **签名**：`fn takePendingRejectionOrException(runtime: *Runtime) zjs.JSValue`。
- **作用**：取出下一条待报的异常/rejection。
- **实现**：`context.takePendingException()`（rejection 也走这条队列）。
- **所有权 / 错误 / 调用**：调用方拥有返回值，打印后不再根上。

### `printEvaluationError` (`src/cli/zjs.zig:1462`)

- **签名**：`fn printEvaluationError(io: std.Io, runtime: *Runtime, err: anyerror) !void`。
- **作用**：求值失败时打异常或 Zig error 名。
- **实现**：有 exception/rejection 则 `printExceptionValue`；否则 `zjs: evaluation failed: {errorName}`。
- **所有权 / 错误 / 调用**：include/eval catch。`exit(1)` 之前。

### `printExceptionValue` (`src/cli/zjs.zig:1475`)

- **签名**：`fn printExceptionValue(stderr: *std.Io.Writer, runtime: *Runtime, value: zjs.JSValue) !bool`。
- **作用**：对象异常打 `formatException` + 可选 stack。
- **实现**：非对象返回 false。空 header 打 `Error\n`。`formatExceptionStack` 若在取栈时又抛，clear 后当无栈。flush。
- **所有权 / 错误 / 调用**：header/stack 用 runtime allocator，defer free。

### `printUnhandledRejectionTo` (`src/cli/zjs.zig:1509`)

- **签名**：`fn printUnhandledRejectionTo(stderr: *std.Io.Writer, runtime: *Runtime, value: zjs.JSValue) !void`。
- **作用**：一条「Possibly unhandled promise rejection:」报告。
- **实现**：int/bool/undefined/null/string/object 分支；对象走 `printExceptionValue`。循环必须复用同一 writer。
- **所有权 / 错误 / 调用**：对齐 qjs `js_std_promise_rejection_check`。

### `printTypeErrorNotFunction` (`src/cli/zjs.zig:1530`)

- **签名**：`fn printTypeErrorNotFunction(io: std.Io, command: Command) !void`。
- **作用**：eval 返回 `error.TypeError` 且 context 无异常时的固定文案（对照 qjs 某条报错形）。
- **实现**：`TypeError: not a function\n    at <anonymous> ({path}:7:20)\n\n`。
- **所有权 / 错误 / 调用**：仅这条冷路径。path 为文件或 `"<eval>"`。

### `initOpcodeProfile` (`src/cli/zjs.zig:2024`)

- **签名**：`fn initOpcodeProfile(profile: *zjs.OpcodeProfile) void`。
- **作用**：零初始化 profile，避免 18 KiB `.rodata` 的 `OpcodeProfile{}` 拷贝。
- **实现**：`zeroes` 后把 `pending_op` 设回 `no_pending_op` 哨兵。
- **所有权 / 错误 / 调用**：`main` 栈上 profile。单测 `expectEqualDeep(OpcodeProfile{}, profile)`。

---

## 覆盖核对

- 清单函数数: 53（`src/cli/cli_process.zig` 3 + `src/cli/zjs.zig` 50）
- 本文标题覆盖: 53
- 未覆盖: 无
