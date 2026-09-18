# 20 — 架构检查、门禁脚本、文档/lint 工具

本册按函数讲 `tools/architecture/*.js`、`tools/gates/*.py`、`tools/docs/*.py`、`tools/lint/*.py`。`tools/perf` 是上百份 bench 夹具，只给目录图，不逐 JS 文件展开。JSON allowlist 在对应检查器里说明。

构建图如何挂这些命令见 [`20-build.md`](20-build.md) 的 `addGates`。

---

## 文件级：`test262.conf` 与 `tests/fixtures/`

这两处不是 Zig 函数，但是测试图的输入。

### `test262.conf`（仓根）

`run-test262` / `test262-check` 的 INI。`[config]`：`nostrict=yes`、`strict=yes`、`mode=default`、`async=yes`、`module=yes`、`verbose=yes`、`harnessdir=test262/harness`、`errorfile=test262_errors.txt`、`testdir=test262/test`。`[features]` 列出引擎声称支持的语言特性（含 `=!tcc` 这类实现限制标记）。还有 `[exclude]` 等段排除已知无关或未实现路径。**禁止为了让门禁变绿而放宽 exclude**（AGENTS.md / GUIDE B.6）。

`zig build test262-check` 把它以 `-c test262.conf -d test262/test` 传给 Fast `run-test262`，要求 stdout 含 `Result: 0/`。

### `tests/fixtures/`

仓内 harness 与覆盖夹具，**不是** test262 子模块：

| 路径 | 用途 |
| --- | --- |
| `tests/fixtures/test262/harness/` | 本地精简 harness（`asyncHelpers.js`、`doneprintHandle.js`），给 runner 单测 / 嵌入夹具，不替代 `test262/harness` |
| `tests/fixtures/test262-overrides/test/` | 覆盖上游 test262 个别用例（TypedArray slice species、BigInt string-nan、Error prototype 等 staging） |

统一套件与 CLI smoke 还读 `tests/perf/`、`.zig-cache/smoke-*` 临时脚本；那些由测试自己写。

---

## `tools/architecture/check_deps.js`

层依赖 + 可达性。checkpoint / merge / production 都跑。Allowlist：`deps-allowlist.json`（边）、`orphan-allowlist.json`（两边都到不了的模块）。

### `toPosix` (`tools/architecture/check_deps.js:10`)

- **签名**：`function toPosix(filePath)` → POSIX 斜杠路径。
- **作用**：Windows 分隔符归一，后面的前缀比较才稳定。
- **实现**：`split(path.sep).join('/')`。
- **所有权 / 错误 / 调用**：纯函数。`normalizeRepoPath` 调用。

### `normalizeRepoPath` (`tools/architecture/check_deps.js:14`)

- **签名**：`function normalizeRepoPath(filePath)`。
- **作用**：变成相对仓根、无 `./` 前缀的 POSIX 路径。
- **实现**：`path.normalize` 再 `toPosix`，剥 `./`。
- **所有权 / 错误 / 调用**：allowlist 条目、`walk` 产出、`resolveImport` 结果都走这里。

### `readAllowlist` (`tools/architecture/check_deps.js:18`)

- **签名**：`function readAllowlist()`。
- **作用**：读 `deps-allowlist.json`，校验每条有非空 `source`/`import`/`reason`/`exit_milestone`，拒绝重复边。
- **实现**：`JSON.parse`；缺字段或重复 `fail`。
- **所有权 / 错误 / 调用**：进程启动时调一次。失败 `exit(1)`。

### `walk` (`tools/architecture/check_deps.js:38`)

- **签名**：`function walk(dir, out)`。
- **作用**：递归收集 `.zig` 相对路径。
- **实现**：`readdirSync` + `stat`；目录递归，文件 `endsWith('.zig')` 则 push。
- **所有权 / 错误 / 调用**：先扫 `src/`；再扫 `tools/`、`tests/` 里含 `@import("zjs")` 的文件（构建图根，不当孤儿）。

### `resolveImport` (`tools/architecture/check_deps.js:50`)

- **签名**：`function resolveImport(source, specifier)`。
- **作用**：解析以 `.zig` 结尾、或以 `./`/`../` 开头的 import；裸模块名（`std`、`zjs`、`build_options`）返回 `null`。
- **实现**：拼 `dirname(source)`；结果必须仍在 `src/` 下。
- **所有权 / 错误 / 调用**：`importsFor`。跨出 `src/` 的工具 import 不进层规则。

### `importsFor` (`tools/architecture/check_deps.js:63`)

- **签名**：`function importsFor(source)`。
- **作用**：列出 `source` 里每个 `@import("…")` 解析到的 `src/` 边。
- **实现**：全局正则 `/@import\("([^"]+)"\)/g`。
- **所有权 / 错误 / 调用**：边检查与可达性 BFS 都用。字符串/注释里的假 import 可能误报，靠 allowlist 消化。

### `allowKey` (`tools/architecture/check_deps.js:75`)

- **签名**：`function allowKey(source, target)`。
- **作用**：边的稳定键 `source -> target`。
- **实现**：模板字符串。
- **所有权 / 错误 / 调用**：allowlist 去重、匹配、过期检测。

### `targetStarts` (`tools/architecture/check_deps.js:79`)

- **签名**：`function targetStarts(target, prefixes)`。
- **作用**：目标等于或位于某前缀下。
- **实现**：`some`。
- **所有权 / 错误 / 调用**：`violationReason`。

### `violationReason` (`tools/architecture/check_deps.js:83`)

- **签名**：`function violationReason(source, target)` → `string|null`。
- **作用**：层规则：返回违规原因或 `null`（合法）。
- **实现**：
  - `internal_root` / `all_tests`：不检查（聚合根）。
  - `src/root.zig`：只许 embedding facade 用的那几个模块。
  - `src/core/`：禁止 binding / builtins / cli / exec / parser / runtime。
  - `src/libs/`：只许 core/libs。
  - `parser.zig`：禁止 binding/builtins/cli/exec/runtime。
  - `bytecode.zig`：禁止 binding/builtins/cli/exec/parser/runtime。
  - `src/exec/`：禁止 binding/builtins/cli/runtime。
  - `src/runtime/`、`src/binding/`：禁止 cli。
  - `src/compiler/`：生产文件禁止 cli/runtime/exec/binding；`compiler/tests.zig` 可 import exec。
- **所有权 / 错误 / 调用**：主循环；命中 allowlist 则记 matched，否则进 violations。

### `fail` (`tools/architecture/check_deps.js:181`)

- **签名**：`function fail(message)`。
- **作用**：打印 `architecture dependency check failed:` 并 `exit(1)`。
- **实现**：`console.error` + `process.exit`。
- **所有权 / 错误 / 调用**：校验失败的唯一出口。

### `readOrphanAllowlist` (`tools/architecture/check_deps.js:240`)

- **签名**：`function readOrphanAllowlist()`。
- **作用**：读孤儿表，每条要 `module`/`reason`/`exit_milestone`。
- **实现**：同 deps allowlist 的字段检查。
- **所有权 / 错误 / 调用**：`checkProductionReachability`。

### `reachableFrom` (`tools/architecture/check_deps.js:254`)

- **签名**：`function reachableFrom(roots, edges)`。
- **作用**：从给定根沿 import 边 BFS。
- **实现**：`Set` + 栈；只走 `edges` 里存在的根。
- **所有权 / 错误 / 调用**：生产根与测试根各跑一次。

### `checkProductionReachability` (`tools/architecture/check_deps.js:270`)

- **签名**：`function checkProductionReachability()`。
- **作用**：模块必须从生产根或测试/工具根可达，否则要孤儿 allowlist；表项过期（又可达或文件没了）也失败。防止 `vm_profile.zig` 那种「静默掉出生产图」。
- **实现**：生产根 = `root`/`internal_root`/`cli/zjs`/`cli/run_test262`。测试根 = `all_tests` + 各 focused shell + `tests/oom.zig` + `smoke_test.zig` + `abi/gen_header.zig` + 若干 `tools/perf/*.zig`。返回 `{production, testOnly, allowedOrphans}`。
- **所有权 / 错误 / 调用**：主脚本在边检查通过后调用。

主脚本还硬拒绝：复活的 `src/builtins/`、`host_function.zig` 里退休 ABI token、`standard_globals.zig` 泛型 constructor registry、`property_direct.zig` 的死 IC facade、`internal_builtins.zig` 丢掉 atomics/performance/promise 的 typed record 表。过期 allowlist 边与未允许违规边一并失败。

---

## `tools/architecture/check_compiler_stage_boundaries.js`

钉两处 `noinline` 阶段边界（QCP-1B 删旧编译器后性能稳定的条件）。`--source-only` 给 checkpoint；带二进制路径时再 `nm`。

### `fail` (`tools/architecture/check_compiler_stage_boundaries.js:37`)

- **签名**：`function fail(message)`。
- **作用**：前缀 `compiler-stage boundary check failed:` 后退出。
- **实现**：`console.error` + `exit(1)`。
- **所有权 / 错误 / 调用**：缺文件、缺声明、`nm` 失败、符号被折进 packed finalizer。

### `stripComments` (`tools/architecture/check_compiler_stage_boundaries.js:42`)

- **签名**：`function stripComments(text)`。
- **作用**：按行剥 `//`，不进字符串，避免注释里的声明冒充源码。
- **实现**：逐字符跟踪 `inString` 与 `\\`。
- **所有权 / 错误 / 调用**：检查 `REQUIRED_PHASE_BOUNDARIES` 两条：`compileFunctionV2ForPackedFinalize`（`src/compiler/root.zig`）、`computeStackSizeForCurrentBytecode`（`src/bytecode.zig`）。

无 argv 则 `fail`（必须 `--source-only` 或二进制路径）。`nm` 输出 0 符号视为真空失败。

---

## `tools/architecture/check_gc_slots.js`

裸堆 GC 引用 lint（tracing-gc-design.md §5.2）。`src/core/**` 与 `src/bytecode.zig` 里存 `JSValue`/`*Object`/`*Shape` 等的字段必须打 `// gc-slot: heap|immutable|weak`，或在**只缩不增**的 `gc-slots-allowlist.json`。`--dump` 打出当前未打标字段 JSON。扫描集原先还有一条「若存在 `src/bytecode/` 目录则递归扫」的分支，仓内只有 `src/bytecode.zig` 没有同名目录，是死分支，已删。

### `toPosix` / `normalizeRepoPath` / `fail` / `walk` (`check_gc_slots.js:31–55`)

与 deps 检查同形。`walk` 跳过名为 `tests` 的子目录。`fail` 前缀 `architecture gc-slot check failed:`。

### `stripLineComment` (`tools/architecture/check_gc_slots.js:57`)

- **签名**：`function stripLineComment(line)` → `{code, comment}`。
- **作用**：在第一个 `//` 切开，后面给 `gc-slot:` 标签用。
- **实现**：`indexOf('//')`。
- **所有权 / 错误 / 调用**：`scanFile` 每行。

### `slotTag` (`tools/architecture/check_gc_slots.js:63`)

- **签名**：`function slotTag(comment, prevComment)`。
- **作用**：识别 `gc-slot: heap|immutable|weak`（本行或上一行注释）。
- **实现**：拼起来正则。
- **所有权 / 错误 / 调用**：已打标字段若仍在 allowlist 则失败（应当从表里拿掉以收缩）。

### `isGcFieldType` (`tools/architecture/check_gc_slots.js:71`)

- **签名**：`function isGcFieldType(typeText)`。
- **作用**：类型是否像堆 GC 引用。
- **实现**：去空白后对 `gcTypeRe`；跳过 `u8`/`FILE`/`anyopaque`/`Atom`/`usize`；带 `Payload` 且不含 `JSValue` 的也不算。
- **所有权 / 错误 / 调用**：`scanFile` 的字段匹配。

### `skipStructName` (`tools/architecture/check_gc_slots.js:78`)

- **签名**：`function skipStructName(name)`。
- **作用**：Options/Error/Lookup/Visit/Callback/Host/`binding_rules` 不扫。
- **实现**：后缀/全名判断。
- **所有权 / 错误 / 调用**：进 struct 栈时打 `skip`。

### `scanFile` (`tools/architecture/check_gc_slots.js:90`)

- **签名**：`function scanFile(relPath)`。
- **作用**：走文件，收集 struct 字段级 GC 槽（跳过函数体）。
- **实现**：`structStack` + `depth` + `fnSkip`（`fn`/`test`/`comptime {` 开始跳到对应深度结束）。字段正则 `name: Type,`。
- **所有权 / 错误 / 调用**：对 core 与 bytecode 每个文件调用；跳过 `gc_slot.zig` / `gc_write_audit.zig`。

### `allowKey` (`tools/architecture/check_gc_slots.js:162`)

- **签名**：`function allowKey(entry)`。
- **作用**：`file::struct::field`。
- **实现**：模板字符串。
- **所有权 / 错误 / 调用**：去重、匹配、过期。

### `readAllowlist` (`tools/architecture/check_gc_slots.js:166`)

- **签名**：`function readAllowlist()`。
- **作用**：读 `{baseline_count, entries}`；条目数不得大于 baseline（只缩不增）。
- **实现**：校验 `file/struct/field/kind/reason`。
- **所有权 / 错误 / 调用**：主脚本。未打标且不在表中 → 失败（最多展示 20 条）；表项对不上现存裸字段 → stale 失败。

---

## `tools/architecture/check_oom_panics.js`

OOM 必须作为可捕获错误传播（eecf6c8），不得变成 `unreachable`/`@panic`。扫 `src/**` 排除 `src/tests/**`。Allowlist 上限 10，目前是 rope flatten 最后手段。

### `toPosix` / `normalizeRepoPath` / `fail` / `walk` (`check_oom_panics.js:39–103`)

同形。`fail` 前缀 `architecture OOM-panic check failed:`。

### `readAllowlist` (`tools/architecture/check_oom_panics.js:54`)

- **签名**：`function readAllowlist()`。
- **作用**：校验 `source/pattern/reason/exit_milestone`，可选 `contains`；`pattern` ∈ `{oom-discard, catch-unreachable-alloc}`；同一 source+pattern 多条必须都带不同 `contains`。
- **实现**：`allowEntryKey` 去重；超 10 条失败。
- **所有权 / 错误 / 调用**：启动时一次。

### `allowKey` (`tools/architecture/check_oom_panics.js:105`)

- **签名**：`function allowKey(source, pattern)` → `source :: pattern`。
- **作用**：无 `contains` 时的键。
- **实现**：模板字符串。
- **所有权 / 错误 / 调用**：`allowEntryKey`、stale 打印。

### `allowEntryKey` (`tools/architecture/check_oom_panics.js:109`)

- **签名**：`function allowEntryKey(entry)`。
- **作用**：一条 allowlist 覆盖**恰好一次** finding 的键。
- **实现**：有 `contains` 则追加 ` :: contains <json>`。
- **所有权 / 错误 / 调用**：去重。

### `entryMatchesFinding` (`tools/architecture/check_oom_panics.js:114`)

- **签名**：`function entryMatchesFinding(entry, finding)`。
- **作用**：source+pattern 相同，且无 `contains` 或原文包含该子串。
- **实现**：布尔。
- **所有权 / 错误 / 调用**：匹配、非唯一、重叠检测。

### `findingsFor` (`tools/architecture/check_oom_panics.js:122`)

- **签名**：`function findingsFor(source)`。
- **作用**：按行出 finding。规则 B：`error.OutOfMemory => unreachable/@panic`，或同行既出现 `OutOfMemory` 又出现 `unreachable`/`@panic(`。规则 C：含分配标记的 `catch unreachable/@panic`。第二条分支原先尾随一个 `&& !line.includes('@panic(')`，正好抵消掉它自己的 `@panic\(` 备选，等价于「只认 unreachable」；单行 `if (... OutOfMemory ...) @panic("...")` 会漏检，该条件已删。
- **实现**：先切掉 `//`；`alloc_marker_re` 认 `memory.`/`allocator.`/`alloc(`/`create(`/`dupe(`/`append(`/`toOwnedSlice`/`realloc`/`OutOfMemory`/`out of memory`（正则带 `i`，大小写不敏感）。
- **所有权 / 错误 / 调用**：主循环。0 匹配 = stale；>1 = nonUnique；多条 allowlist 抢同一 finding = overlapping；0 owner = violation。

---

## `tools/architecture/check_borrowed_atoms.js`

TGC S3-c：裸 atom id 不得跨 safepoint 持有，除非有 root 帧 / `CompileAtomScope` / `pinForHost` / holder 边。静态代理：从短命 token 读出的 id 不得 return、存进长期 `State` 字段、或在同函数 `advance()`/`freeToken()` 之后再读。Allowlist 上限 16。`lexer.zig`/`parser.zig`/`bytecode.zig` 在 `parser.zig` 仍安装 `atom_scope` 的前提下整文件覆盖。

### `toPosix` / `normalizeRepoPath` / `fail` (`check_borrowed_atoms.js:153–164`)

同形。失败前缀 `architecture borrowed-atom check failed:`。

### `allowKey` (`tools/architecture/check_borrowed_atoms.js:166`)

- **签名**：`function allowKey(source, pattern)`。
- **作用**：`source :: pattern`。
- **实现**：模板字符串。
- **所有权 / 错误 / 调用**：`allowEntryKey`。

### `allowEntryKey` (`tools/architecture/check_borrowed_atoms.js:170`)

- **签名**：`function allowEntryKey(entry)`。
- **作用**：可加 ` :: fn name` 与 ` :: contains …`。
- **实现**：可选选择器拼接。
- **所有权 / 错误 / 调用**：去重；多条同一 source+pattern 必须带 `fn` 或 `contains`。

### `readAllowlist` (`tools/architecture/check_borrowed_atoms.js:177`)

- **签名**：`function readAllowlist()`。
- **作用**：校验四字段 + 可选 `fn`/`contains`；pattern ∈ `{borrowed-return, borrowed-state-store, borrowed-use-after-release, owned-escape-state-store}`。
- **实现**：超 16 条失败。
- **所有权 / 错误 / 调用**：启动时；witness 检查之后。

### `walk` (`tools/architecture/check_borrowed_atoms.js:217`)

- **签名**：`function walk(dir, out)`。
- **作用**：收集 `src/**/*.zig`，`readdir` 排序以稳定输出。
- **实现**：递归。
- **所有权 / 错误 / 调用**：`walk` 本身不过滤；`src/tests/` 由主循环跳过。

### `stripCode` (`tools/architecture/check_borrowed_atoms.js:232`)

- **签名**：`function stripCode(rawLine)`。
- **作用**：去掉注释与字符串内容（字符串位置留空格），整行 `\\` 多行字符串丢弃，避免假阳性。
- **实现**：状态机：`inString`/`inChar`/`//`。
- **所有权 / 错误 / 调用**：`analyzeFile` 映射每一行。

### `isValuePosition` (`tools/architecture/check_borrowed_atoms.js:269`)

- **签名**：`function isValuePosition(text, index)`。
- **作用**：匹配处是表达式的值还是 callee 实参。实参位置的读（如 `atomNameEquals(..., tok.payload.ident.atom, …)`）不算借用；`@as` 等 builtin 透明外穿。
- **实现**：向左扫括号深度；碰到 `(` 看 callee 名。
- **所有权 / 错误 / 调用**：`borrowedReadsIn`、`helperCallsIn`、`referencesLocalValue`。

### `isIdentityComparisonOperand` (`tools/architecture/check_borrowed_atoms.js:289`)

- **签名**：`function isIdentityComparisonOperand(text, start, end)`。
- **作用**：紧邻 `==`/`!=` 的读产生 bool，不保留 id。
- **实现**：看前后 trim 后的运算符。
- **所有权 / 错误 / 调用**：`borrowedReadsIn` 过滤。

### `borrowedReadsIn` (`tools/architecture/check_borrowed_atoms.js:295`)

- **签名**：`function borrowedReadsIn(text, stats?)`。
- **作用**：找 `.payload.<field>.atom` 且处于值位置、非身份比较。
- **实现**：`borrowed_read_re`；可选累加 `stats.reads` / `borrowingReads`。
- **所有权 / 错误 / 调用**：绑定、return、store 分析。

### `helperCallsIn` (`tools/architecture/check_borrowed_atoms.js:310`)

- **签名**：`function helperCallsIn(text, helpers)`。
- **作用**：同文件「返回借用 atom」的 helper 在值位置的调用。
- **实现**：为每个 helper 名编译 `\bname\s*\(`。
- **所有权 / 错误 / 调用**：helper 集合由 `analyzeFile` 不动点求出。

### `referencesLocal` (`tools/architecture/check_borrowed_atoms.js:324`)

- **签名**：`function referencesLocal(text, name)`。
- **作用**：任意提及（含实参）。规则 C 的「释放后再读」用这个。
- **实现**：负向 lookbehind 词边界。
- **所有权 / 错误 / 调用**：规则 C、规则 D 的 defer-freed 局部。

### `referencesLocalValue` (`tools/architecture/check_borrowed_atoms.js:330`)

- **签名**：`function referencesLocalValue(text, name)`。
- **作用**：局部作为值出现（`dup(name)` 不算）。
- **实现**：全局匹配 + `isValuePosition`。
- **所有权 / 错误 / 调用**：污点传播、规则 A/B。

### `isIdentityPreserving` (`tools/architecture/check_borrowed_atoms.js:343`)

- **签名**：`function isIdentityPreserving(text)`。
- **作用**：RHS 是否仍是同一个 id（比较/布尔运算在括号外则切断）。
- **实现**：剥掉最外层以外的 `()`/`[]` 后测 `==`/`and`/`or` 等。
- **所有权 / 错误 / 调用**：声明绑定的污点。

### `statementsOf` (`tools/architecture/check_borrowed_atoms.js:357`)

- **签名**：`function statementsOf(codeLines, startLine, endLine)`。
- **作用**：把函数体切成逻辑语句（`;{}` 结束，`()`/`[]` 可跨行）。
- **实现**：缓冲 + 深度。
- **所有权 / 错误 / 调用**：`analyzeFunction`。

### `braceDelta` (`tools/architecture/check_borrowed_atoms.js:381`)

- **签名**：`function braceDelta(line)`。
- **作用**：一行 `{` 减 `}`。
- **实现**：`match` 计数。
- **所有权 / 错误 / 调用**：`functionsOf`、`deferBlockLines`。

### `functionsOf` (`tools/architecture/check_borrowed_atoms.js:385`)

- **签名**：`function functionsOf(codeLines)`。
- **作用**：按缩进匹配 `fn name(` 的起止行。单行 `fn foo() void {}` 当场闭合。
- **实现**：`open` 栈；`} ` 且缩进 ≤ 栈顶则 pop。
- **所有权 / 错误 / 调用**：`analyzeFile`。

### `stateReceivers` (`tools/architecture/check_borrowed_atoms.js:416`)

- **签名**：`function stateReceivers(codeLines, fn)`。
- **作用**：本函数绑定到 `*State` 的参数名（`s`/`self`），避免邻接 struct 的 `self.atom =` 误报。
- **实现**：签名区最多 16 行，直到 `{`。
- **所有权 / 错误 / 调用**：规则 B/D。

### `deferBlockLines` (`tools/architecture/check_borrowed_atoms.js:432`)

- **签名**：`function deferBlockLines(codeLines, startLine, endLine)`。
- **作用**：标记 `defer`/`errdefer { }` 内的行——那里的 `freeToken` 不是行内释放点。
- **实现**：`braceDelta` 跟踪 `active`。
- **所有权 / 错误 / 调用**：`analyzeFunction` 跳过这些行。

### `atomFieldNames` (`tools/architecture/check_borrowed_atoms.js:462`)

- **签名**：`function atomFieldNames(codeLines, fns)`。
- **作用**：struct 作用域的 `Atom`/`?Atom` 字段名（跳过函数体，避免把参数当字段）。
- **实现**：先标 `inFunction`，再匹配字段。
- **所有权 / 错误 / 调用**：规则 B/D 的 store 目标。

### `hasMarkerAbove` (`tools/architecture/check_borrowed_atoms.js:476`)

- **签名**：`function hasMarkerAbove(rawLines, lineIndex)`。
- **作用**：上一非空行是否 `// borrowed-atom: <非空理由>`。
- **实现**：只看紧邻上一非空行。
- **所有权 / 错误 / 调用**：合法化出口；规则 C 还接受借用行上的标记。

### `analyzeFile` (`tools/architecture/check_borrowed_atoms.js:487`)

- **签名**：`function analyzeFile(source, state)`。
- **作用**：对一个文件：不动点发现返回借用的 helper，再扫逃逸。
- **实现**：`fileCovered` = compile-scope 源或 `src/compiler/`。Pass A `helperScanOnly`；Pass B 正式 finding。helper 名写入 `state.helpersByFile`。
- **所有权 / 错误 / 调用**：主循环；`--list` 打印 finding 与 helper。

### `analyzeFunction` (`tools/architecture/check_borrowed_atoms.js:519`)

- **签名**：`function analyzeFunction(fn, rawLines, codeLines, fields, helpers, options)`。
- **作用**：单函数的污点与四条规则。
- **实现**：
  1. 签名行不参与「函数名 `…Owned` 就算生产了 owner」。
  2. `ownership_producer_re`（intern/newSymbol/noteHolderStore/`…Owned(`）+ 名字以 `Owned` 结尾 → 转发借用的规则 A 豁免；**token payload 直接 return 永不豁免**（ada949be）。
  3. `coverage_producer_re` 或文件级覆盖 → 无 finding。
  4. 绑定污点、规则 A return、规则 B/D store、规则 C 释放后使用。
  5. 同一借用点多种逃逸按 `pattern_priority` 只报最重的。
- **所有权 / 错误 / 调用**：`analyzeFile`。`helperScanOnly` 只回 `returnsBorrowed`。

### `entryMatchesFinding` (`tools/architecture/check_borrowed_atoms.js:692`)

- **签名**：`function entryMatchesFinding(entry, finding)`。
- **作用**：source+pattern，可选 `fn`/`contains`。
- **实现**：布尔。
- **所有权 / 错误 / 调用**：与 OOM 检查相同的 stale/nonUnique/overlapping/violation 收尾。

主脚本先验证 `compile_scope_witness`（`src/parser.zig` 仍有 `atom_scope: …CompileAtomScope` 与 `self.atom_scope.activate()`），再扫文件。

Allowlist JSON：`borrowed-atoms-allowlist.json`。

---

## `tools/gates/watch.py`

去抖、按次持锁的有限构建。空闲放锁；磁盘缓存可复用，内存增量编译器不能。默认监视 `src`/`build`/`tests`/`tools`/`policies`/`build.zig`/`build.zig.zon`/`mise.toml`/`test262.conf`。忽略 `.git` / `.zig-cache` / `zig-out` / `.scratch` / `__pycache__` / `node_modules` / `test262` / `.venv`。

### `snapshot` (`tools/gates/watch.py:24`)

- **签名**：`def snapshot(paths)`。
- **作用**：`(ino, size, mtime_ns, ctime_ns)` 图，用于发现增删、原子保存、同尺寸编辑。
- **实现**：目录 `os.walk` 并过滤 `IGNORED`；`FileNotFoundError` 跳过（编辑器替换文件）。
- **所有权 / 错误 / 调用**：`watch` 每轮一次；另在抢到锁、启动构建前再取一次作为冻结基线。函数自身不碰锁。

### `group_is_running` (`tools/gates/watch.py:45`)

- **签名**：`def group_is_running(pgid)`。
- **作用**：进程组是否还有非僵尸成员。僵尸不占测量 CPU，但等 PID 1 收尸会挂。
- **实现**：读 `/proc/*/stat` 的 pgid 与状态，排除 `Z`/`X`。
- **所有权 / 错误 / 调用**：`stop_group` 循环。Linux only。

### `stop_group` (`tools/gates/watch.py:60`)

- **签名**：`def stop_group(proc)`。
- **作用**：SIGTERM → 短等 → SIGKILL，并等到组内孙进程也停，**然后**才放锁。
- **实现**：`killpg`；`wait`；轮询 `group_is_running`。
- **所有权 / 错误 / 调用**：超时、信号、`finally`。失败的 driver 若先于子进程退出，这里仍能杀掉后代。

### `watch` (`tools/gates/watch.py:81`)

- **签名**：`def watch(command, paths, lock_path, interval, debounce, build_timeout, lock_timeout)`。
- **作用**：主循环：启动先建一次；变更后去抖；非阻塞抢 `/tmp/zjs-host-heavy.lock`；超时抛 `TimeoutError`；SIGINT/TERM 可中断等锁。
- **实现**：`fcntl.LOCK_EX|LOCK_NB`；`Popen(..., start_new_session=True)`；构建中的编辑留到下一轮。驻留 flag `--watch`/`--webui`/`--fuzz` 由 `main` 拒绝（驻留模式会占锁）。
- **所有权 / 错误 / 调用**：`main`。返回 0；OS/锁超时由 `main` 打成退出码 1。

### `main` (`tools/gates/watch.py:144`)

- **签名**：`def main()`。
- **作用**：CLI：`--path` 可重复、`--lock`、`--interval` 默认 0.5、`--debounce` 0.2、`--build-timeout`/`--lock-timeout` 1200。命令在 `--` 之后。
- **实现**：`argparse`；校验正数；调用 `watch`。
- **所有权 / 错误 / 调用**：`mise run watch` / `quick-watch`。缺命令或驻留 flag → 退出 2。

---

## `tools/gates/timeline.py`

无头甘特：跑一条命令，采样进程树，打印每进程 start/dur。替代 `zig build --time-report`（要 web UI），并且能给 Run 步计时。

### `ps_snapshot` (`tools/gates/timeline.py:23`)

- **签名**：`def ps_snapshot()`。
- **作用**：`{pid: (ppid, args)}`。
- **实现**：`ps -eo pid,ppid,args --no-headers`。
- **所有权 / 错误 / 调用**：主循环每 `--interval`（默认 0.5s）。

### `descendants` (`tools/gates/timeline.py:35`)

- **签名**：`def descendants(rows, root)`。
- **作用**：root 的子孙 pid 集合。
- **实现**：邻接表 DFS。
- **所有权 / 错误 / 调用**：每次采样。

### `label` (`tools/gates/timeline.py:47`)

- **签名**：`def label(args)`。
- **作用**：缩短 argv：cache hash、`zig-out`、zig 路径折叠；识别 `zig build-exe|build-lib|test|build-obj … --name` 与 `-fno-emit-bin` / `-OReleaseFast`。
- **实现**：三条 `re.sub` 折路径；命中编译器驱动则回 `zig <kind> <name>`（`-fno-emit-bin` 加 `(sema-only)`、`-OReleaseFast` 加 ` RF`）；否则 `zig build …` 归为 `zig build (runner)`；再长于 110 字符截断成 107 字符 + `...`。
- **所有权 / 错误 / 调用**：pid 首次出现时固定标签。

### `main` (`tools/gates/timeline.py:69`)

- **签名**：`def main()`。
- **作用**：`Popen` 用户命令，采样至结束，按 start 排序打印；默认丢掉 `< --min`（1s）的短帮手。退出码与子进程相同。
- **实现**：`--all` 保留全部行。每个进程一行、按 start 排序；相同 label 的分片**故意**不折成 range——分片各自的 start/dur 分布正是这张甘特要回答的「是否真并行」（原注释说要折叠，与实现不符，已改写）。
- **所有权 / 错误 / 调用**：`mise run gate-timeline -- <step>`。

---

## `tools/gates` 测试脚本

### `GateSmokeEntryTests` (`tools/gates/test_gate_smoke_entry.py:13`)

- **签名**：`class GateSmokeEntryTests(unittest.TestCase)`。
- **作用**：用**已经编好**的真 `zjs` 在隔离 scratch 里跑 `gate_smoke.sh`。
- **实现**：`setUp` 拷脚本与二进制、把二进制 mtime 打到 1970、造假 `src/new.zig` 让「默认入口」认为产物过期。用例：默认/空路径拒过期产物；显式产物跑 ordinary+audit；并行列表（不是占位 CPU 4095）上探测；坏 `ZJS_GATE_PARALLEL_CPUS` 在 stats probe 前失败；`true` 当产物被 stats probe 拒；夹具 `throw` → `FAIL fixture ordinary run`。
- **所有权 / 错误 / 调用**：需要 `ZJS_GATE_TEST_BINARY` 或 `zig-out/bin/zjs`。超时 30s。

辅助：`setUp`、`run_gate`、以及上列 `test_*` 方法。

### `eventually` (`tools/gates/test_watch.py:17`)

- **签名**：`def eventually(check, timeout=5)`。
- **作用**：轮询直到谓词真，否则 `AssertionError`。
- **实现**：20ms sleep。
- **所有权 / 错误 / 调用**：`WatchTest`。

### `WatchTest` (`tools/gates/test_watch.py:26`)

- **签名**：`class WatchTest(unittest.TestCase)`。
- **作用**：编排回归（故意不测 Zig）：空闲放锁、构建中编辑会再跑、失败等下次编辑、信号/超时先杀孙再放锁、等锁有界且可中断、默认路径不含 `reports`/`.scratch`/`test262`、拒绝 `zig build --watch`。
- **实现**：stub `driver.py`；真的 `watch.py`。`lock_available` 用 `LOCK_SH|LOCK_NB`。
- **所有权 / 错误 / 调用**：独立 unittest，不进 `zig build test`。

### `test_release_contract.main` (`tools/gates/test_release_contract.py:11`)

- **签名**：`def main()`。
- **作用**：从 `nightly.yml` 抽出 Linux/macOS 两段「读 sidecar、跑 `--print-config-signature`」shell，对 **strip 后的真 zjs** 跑通；然后 sidecar 过期、CLI `exit 7` 但仍打印签名、缺 sidecar，都必须失败。
- **实现**：临时目录拷二进制；`strip`；`bash -e -c`。
- **所有权 / 错误 / 调用**：需要已安装的 `zig-out/bin/zjs` 与 sidecar。

### `test_size_experiment.run` / `main` (`tools/gates/test_size_experiment.py:13–23`)

- **签名**：`def run(binary, *args) -> str`；`def main()`。
- **作用**：不重新编译。生产签名必须含 `optimize=ReleaseFast` 且等于 sidecar；`zjs-size` 必须是同一签名只换 optimize 段；两颗二进制对同一 JS 烟测输出 `[2,4,6]`。
- **实现**：`subprocess.run(..., check=True)`；stderr 非空即失败。
- **所有权 / 错误 / 调用**：先 `zig build zjs zjs-size -Doptimize=ReleaseSmall`。

### `test_test_fast.run` / `main` (`tools/gates/test_test_fast.py:11–28`)

- **签名**：`def run(*args)`；`def main()`。
- **作用**：真的 `zig build test-fast`：两个真实测试名必须都绿且 runner 路径是**同一**产物；空/缺/未匹配/`--list` 必须失败。
- **实现**：`timeout 1200 flock … taskset … zig build test-fast -j32 --verbose`，从 verbose 行解析 `--require-tests` 前的二进制路径。
- **所有权 / 错误 / 调用**：持 host 锁，走编译池。

---

## `tools/docs/render_roadmap.py`

从 `docs/roadmap/work-items.yaml` 生成 `docs/roadmap.md` 里三块 `<!-- BEGIN GENERATED -->`。

### `load` (`tools/docs/render_roadmap.py:29`)

- **签名**：`def load()`。
- **作用**：YAML 加载 registry。需要 PyYAML。
- **实现**：`yaml.safe_load`。
- **所有权 / 错误 / 调用**：`main`。

### `group_of` (`tools/docs/render_roadmap.py:35`)

- **签名**：`def group_of(item_id)`。
- **作用**：按 id 前缀分到治理/gates/性能/GC/序列化/fun 面/运行时；前缀都不匹配则返回模块级常量 `OTHER_GROUP`（「其他」）。
- **实现**：`GROUPS` 元组 + `OTHER_GROUP` 兜底。
- **所有权 / 错误 / 调用**：`render_id_list`。

### `fmt_activation` (`tools/docs/render_roadmap.py:42`)

- **签名**：`def fmt_activation(act)`。
- **作用**：把 `{any|all: [{item, verdict?, …}]}` 打成 `A=go | B.done` 这类字符串。
- **实现**：`verdict` / `verdict_not` / `state` / `condition`。
- **所有权 / 错误 / 调用**：DAG 段的 activation 列表。

### `render_id_list` / `render_dag` / `render_status` (`tools/docs/render_roadmap.py:59–85`)

- **签名**：`def render_id_list(items)` 等，返回 markdown fence 字符串。
- **作用**：三块生成正文。
- **实现**：按组/依赖/state 顺序。`render_id_list` 遍历 `GROUPS` 的组名**再加** `OTHER_GROUP`：原先只遍历 `GROUPS`，未登记前缀的 item 会被静默吞掉（`roadmap_lint` 只核对 roadmap.md 正文，查不到这个漏项）。
- **所有权 / 错误 / 调用**：`main` 经 `replace_section`。

### `replace_section` (`tools/docs/render_roadmap.py:104`)

- **签名**：`def replace_section(text, name, body)`。
- **作用**：替换 `BEGIN/END GENERATED: name` 之间。缺标记 `SystemExit`。
- **实现**：`re.S` 非贪婪。
- **所有权 / 错误 / 调用**：`main` 三次。

### `main` (`tools/docs/render_roadmap.py:113`)

- **签名**：`def main()`。
- **作用**：`--check`（默认）段落后退 1；`--write` 就地改。
- **实现**：读 roadmap.md，三替换，比较。
- **所有权 / 错误 / 调用**：`roadmap_lint` 子进程也跑 `--check`。

---

## `tools/docs/roadmap_lint.py`

roadmap 治理：schema、WIP 限额、DAG、激活条件、禁语、生成段新鲜。

### `load_registry` (`tools/docs/roadmap_lint.py:48`)

- **签名**：`def load_registry()`。
- **作用**：读 YAML；缺 PyYAML 退出 2。
- **实现**：`yaml.safe_load`。
- **所有权 / 错误 / 调用**：`main`。

### `check_activation` (`tools/docs/roadmap_lint.py:58`)

- **签名**：`def check_activation(it, idset, by_id, errors)`。
- **作用**：activation 必须是单键 `{any|all: […]}`；每个条目要有 `item` 且该 id 存在；`verdict`/`verdict_not` 只能打在 gate 且属于其 `verdicts`；`state` 必须在 `STATES` 内。
- **实现**：向 `errors` append。
- **所有权 / 错误 / 调用**：每条 item。

### `main` (`tools/docs/roadmap_lint.py:85`)

- **签名**：`def main() -> int`。
- **作用**：schema_version=2；roadmap.md 版本头一致；`roadmap_status` ∈ candidate|approved；id 不重复；每条要有 `authority` 且其 `file` 在仓内存在；状态/类型/wip_slot 枚举；gate 要 verdicts；spike 要冻结的 acceptance_policy（BASE-G0 done 之后）；硬依赖 DAG 无环；now/ready 不得有未完成前置；blocked 必须有未完成前置或 activation；gated 必须有 activation；WIP：decision≤1、implementation≤2、measurement≤1；id 与 roadmap.md 双向引用；禁语表（历史引用有 ALLOWLIST 计数）；最后跑 `render_roadmap.py --check`。
- **实现**：DFS 着色检环。
- **所有权 / 错误 / 调用**：仓根 `python3 tools/docs/roadmap_lint.py`。

---

## `tools/lint/raw_access_gate.py`

F0d：冻结字节码流上的裸访问（opcode-design.md 10.5）。状态扫描不是 diff 扫描。解释器 handler（`tailcall_dispatch*.zig`）不扫——执行 `pc[0]` 是它们的工作。

扫描集：`src/bytecode.zig`、`compiler/resolve_labels.zig`、`resolve_variables.zig`、`cfg.zig`、`exec/small_inline.zig`、`exec/vm_property.zig`。

规则：R1 `emitByte/appendByte(op.X)`；R2 `== op.X` / `op.X =>`；R3 `readInt(..., code[`。

### `scan` (`tools/lint/raw_access_gate.py:56`)

- **签名**：`def scan()`。
- **作用**：去注释后按规则计数 `{file: {rule: n}}`。
- **实现**：`re.sub(r"//[^\n]*", "", text)`。
- **所有权 / 错误 / 调用**：`main`。

### `main` (`tools/lint/raw_access_gate.py:68`)

- **签名**：`def main()`。
- **作用**：与 `raw_access_allowlist.json` 比：增加失败（退出 1）；减少（或条目已归零）打印 `note:` 以便同 commit 收紧。`--update-baseline` 重写表：既有条目的 `reason`/`removal` 原样保留，新条目填 `TODO`，计数归零的条目删掉。
- **实现**：键 `file:rule`。
- **所有权 / 错误 / 调用**：挂在 `mise.toml` 的 `[tasks.lint-raw-access]`（`mise run lint-raw-access`）这个**手动**任务上——既**不**进 `build.zig` 的任何 gate 步骤，也不属于任何默认 lint 目标：它是全树状态扫描 + 手工基线，基线一旦漂移就会挡住所有合并，而这个工具的价值恰恰是报告漂移。今天它就是红的（`compiler/resolve_labels.zig` 的 R1/R2 高于允许数、`exec/vm_property.zig` 低于允许数），重新定基线是要评审的决定，不是机械动作——docstring 已如实写明。docstring 还写「用法错误退出 2」，但实现只返回 0（干净）/ 1（增加）。

---

## `tools/perf` 目录图（不逐夹具）

性能与 GC 仪器。构建图只挂其中一小部分（见 `20-build.md` 的 `addPerfSteps` / `macro-check` / `gate-smoke`）。测量合同：[`docs/perf/measurement-contracts.md`](../perf/measurement-contracts.md)。

| 路径 | 角色 |
| --- | --- |
| `gate_smoke.sh` + `gate_smoke_check.py` | merge-gate 的 fixed-work smoke（普通 run + arena-audit stats run） |
| `bench_v8/` | vendored Octane/V8 suite；`run_local.py` 诊断；`check_completes.py` 完成性门；`run_fixed_pmu.py` / `run_benchv8_compare.py` 测量机对比 |
| `gc_stats_snapshot.py` / `gc_shape_snapshot.py` | Stage 0 GC 快照与 shape 钉。`SCHEMA_VERSION` 现为 **10**：`--gc-stats` 停印 deferred-block-run 与 parked-drain 三行后，`blockHeap.deferredBlockRuns` / `doomed.parkedEntriesDrained` / `doomed.parkedDrainSlices` 登记进 `SCHEMA_REMOVED_LEAVES[10]`，冻结基线里的旧值不再被评分，也不会被当成「候选丢了一行」报错 |
| `stage0_screen.py` / `measure_fields.py` / `measurement_pinning.py` | 场锁、CPU pin、Stage 0 快筛。`METRICS` 里的 `blockHeap.deferredBlockRuns`（deterministic 硬线）随该行退役一并删除 |
| `classify_build_state.py` / `compare_symbol_disassembly.py` | 构建状态与符号反汇编 diff |
| `run_runtime_profile.js` | `perf-*-profile` 的 runner |
| `same_runtime/` | compile-once/execute-many；zjs 与 pinned qjs harness |
| `direct/` | 绕过 CLI 的 core/bigint 微基准 |
| `native_boundary/` | 公共嵌入面 JS↔native |
| `jetstream3/` | 诊断 shell（`perf-jetstream-shell`） |
| `allocator/` `typedarray/` `array_map/` `builtin_bridge/` `callshapes/` `closure_alloc/` `codeload/` `compile_first/` `logical_not/` `property/` `process_memory/` `layout_lineage/` `redefine_census/` | 专题消融语料（大量 `.js`，不在本册展开） |
| `verify/` | 上述 Python 的单元测试 |

不要把这里的分数门禁化；CI 只跑完成性（macro-check）和 crash smoke（gate-smoke）。

旁路：`tools/timing_test_runner.zig` 是统一套件的 test runner（分片、`--skip-prefix`、leak-census）；`tools/gc/representation_snapshot.zig` 是 `gc-representation-snapshot` 步骤。二者属工具树，函数级讲解分别落在测试 runner / GC 表示册，不在本册重复。

---

## 覆盖核对

- 清单函数数: 0（tools 不在 `_inventory.tsv`）
- 本文函数标题：architecture 五份 JS 的全部 `function`、gates/docs/lint 的全部 `def`/`class`
- 未覆盖: 无（`tools/perf` 按任务只做目录图）
