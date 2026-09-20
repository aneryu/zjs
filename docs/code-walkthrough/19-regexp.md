# 19 — `src/libs/regexp.zig`（LRE）

ECMAScript 正则编译器 + QuickJS `libregexp.c` 风格回溯执行器。上游名字保留：`lre*`、`reParse*`、`reEmit*`、`REOP*`。pattern/输入借用；`Compiled` 拥有字节码；回溯栈先用 16 帧 / 32 undo 的 inline 缓冲。

分层关系、信任契约、`/v` 属性查找见 [19-libs.md](19-libs.md)。本文件不碰 `JSValue`。

## 类型与布局

**flags**（u16，可与 `u`/`v` 互斥）：`global ignore_case multiline dot_all unicode sticky indices named_groups unicode_sets`。

**字节码头 8 字节**：`u16 flags`、`u8 capture_count`、`u8 register_count`、`u32 bytecode_len`。命名捕获紧跟 bytecode：`name\0 scope` 重复。

**opcode** `REOPCodeEnum`：`char/char32`（及 `_i`）、`dot/any/space`、`line_start(_m)`、`goto_/split_*`、`match/lookahead*`、`save_start/end/reset`、`loop*`、`word_boundary*`、`back_reference*`、`range/range32`、`class8`、`scan_until_char8`、`prev`。

**执行**：`CbufType` latin1 / utf16_units / utf16_unicode（`u|v` 才合代理）。执行器只信任本编译器产出的头（Debug 断言）。回溯帧 `REBTFrame{pc_off,cptr,undo_top,typ}`；undo `REUndo{old_value:u32,slot:u16}`。未捕获哨兵 `no_slot_value`，压缩到帧里是 `u32::MAX`。

**CompileError**：OOM / `InvalidPattern` / `Unsupported` / `StackOverflow`（qjs `re_parse_error "stack overflow"`）。

**REStringList**：`/v` 的码点集 + 多码点字符串（`\q`、emoji 序列）。

---

## 输入 / 捕获缓冲 / 执行上下文

### `Input.len` (`src/libs/regexp.zig:71`)

- **签名**：`fn len(self: Input) usize`。
- **作用**：latin1 字节数或 utf16 单元数。
- **实现**：switch。
- **所有权 / 错误 / 调用**：`start_index` 越界检测。模块私有。

### `CaptureSlotBuffer.initDefault` (`src/libs/regexp.zig:101`)

- **签名**：`fn initDefault(self: *CaptureSlotBuffer) void`。
- **作用**：零初始化，避免拷 544 字节 `.rodata` 模板。
- **实现**：`std.mem.zeroes` 再把两个 slice 设成 `&.{}`。
- **所有权 / 错误 / 调用**：四个 exec 入口在 `undefined` 声明后、`init` 之前先调（:477/:500/:597），`deinit` 末尾也复位。

### `CaptureSlotBuffer.init` (`src/libs/regexp.zig:108`)

- **签名**：`fn init(self: *CaptureSlotBuffer, allocator: std.mem.Allocator, count: usize) !void`。
- **作用**：准备 `count` 个 capture/register slot。
- **实现**：`count ≤ 64` 用 `inline_slots`；否则 `allocator.alloc`。
- **所有权 / 错误 / 调用**：OOM。`deinit` 只 free heap 臂。

### `CaptureSlotBuffer.deinit` (`src/libs/regexp.zig:117`)

- **签名**：`fn deinit(self: *CaptureSlotBuffer, allocator: std.mem.Allocator) void`。
- **作用**：释放堆 slot。
- **实现**：`heap_slots.len != 0` 则 free，再 `initDefault`。
- **所有权 / 错误 / 调用**：exec 入口 `defer`。

### `REExecContext.deinit` (`src/libs/regexp.zig:239`)

- **签名**：`fn deinit(self: *REExecContext) void`。
- **作用**：释放溢出的回溯/undo 堆。
- **实现**：指针不等于 static 数组才 `free`。
- **所有权 / 错误 / 调用**：`execCaptureSlotsParsed` defer。

### `REExecContext.pollTimeout` (`src/libs/regexp.zig:250`)

- **签名**：`inline fn pollTimeout(self: *REExecContext) !void`。
- **作用**：每 10000 次机会问宿主是否该停。
- **实现**：无 `check_timeout` 直接返回。计数到 0 调回调，真则 `error.Timeout`。
- **所有权 / 错误 / 调用**：`goto_`、loop、贪心 class8。`regexp_adapter` 接 interrupt handler。

### `REExecContext.btFrameRealloc` (`src/libs/regexp.zig:259`)

- **签名**：`fn btFrameRealloc(self: *REExecContext, n: usize, used: usize) !void`。
- **作用**：回溯帧扩容到至少 n。
- **实现**：`len*3/2`。static → alloc+memcpy；否则 realloc。
- **所有权 / 错误 / 调用**：`checkFrameSpace`。OOM。

### `REExecContext.undoRealloc` (`src/libs/regexp.zig:271`)

- **签名**：`fn undoRealloc(self: *REExecContext, n: usize, used: usize) !void`。
- **作用**：undo 栈扩容。
- **实现**：同帧栈。
- **所有权 / 错误 / 调用**：`checkUndoSpace`。

## 分类表与 canonicalize

### `buildLRECtypeBits` (`src/libs/regexp.zig:296`)

- **签名**：`fn buildLRECtypeBits() [256]u8`。
- **作用**：编译期 ASCII/latin1 ctype：space/digit/upper/lower/under。
- **实现**：space 含 TAB–CR、SP、NBSP。
- **所有权 / 错误 / 调用**：`lreIsSpaceByte` / `lreIsWordByte`。

### `buildLRECanonicalizeLatin1` (`src/libs/regexp.zig:309`)

- **签名**：`fn buildLRECanonicalizeLatin1(comptime is_unicode: bool) [256]u21`。
- **作用**：预计算 0–255 的 `unicode.regexpCanonicalize`。
- **实现**：循环 256。
- **所有权 / 错误 / 调用**：两张表：unicode / 非 unicode。

### `lreCanonicalize` (`src/libs/regexp.zig:318`)

- **签名**：`inline fn lreCanonicalize(code_point: u21, is_unicode: bool) u21`。
- **作用**：ignore-case 折叠。
- **实现**：`<128` 手写（u：A→a；非 u：a→A）；`<256` 查表；否则 `unicode.regexpCanonicalize`。
- **所有权 / 错误 / 调用**：执行器 `_i` opcode、编译器字面量。

### `normalizeStartIndex` (`src/libs/regexp.zig:339`)

- **签名**：`fn normalizeStartIndex(input: Input, cbuf_type: CbufType, start_index: usize) usize`。
- **作用**：`u|v` 的 utf16 若落在代理对低半，退到高半。
- **实现**：其它宽度原样。
- **所有权 / 错误 / 调用**：`execCaptureSlotsParsed`。

### `slotOptional` (`src/libs/regexp.zig:353`)

- **签名**：`fn slotOptional(value: usize) ?usize`。
- **作用**：哨兵 → null。
- **实现**：`== no_slot_value`。
- **所有权 / 错误 / 调用**：`captureSlotValue`、`writeMatch`。

### `captureSlotValue` (`src/libs/regexp.zig:357`)

- **签名**：`pub fn captureSlotValue(value: usize) ?usize`。
- **作用**：公开的 slot 解码。
- **实现**：`slotOptional`。
- **所有权 / 错误 / 调用**：adapter / `indices`。

### `captureCountFromBytecode` (`src/libs/regexp.zig:361`)

- **签名**：`fn captureCountFromBytecode(bytecode: []const u8) usize`。
- **作用**：读头里的捕获数（含整场匹配的 0）。
- **实现**：太短 0；否则 `bytecode[2]`。
- **所有权 / 错误 / 调用**：不校验完整性。

### `registerCountFromBytecode` (`src/libs/regexp.zig:366`)

- **签名**：`fn registerCountFromBytecode(bytecode: []const u8) usize`。
- **作用**：读量化器用的寄存器数。
- **实现**：`bytecode[3]`。
- **所有权 / 错误 / 调用**：`allocCountFromBytecode`。

### `allocCountFromBytecode` (`src/libs/regexp.zig:371`)

- **签名**：`fn allocCountFromBytecode(bytecode: []const u8) usize`。
- **作用**：slot 总数 = `2*captures + registers`。
- **实现**：乘法加法。
- **所有权 / 错误 / 调用**：trusted 路径按这个分配。

### `getFlags` (`src/libs/regexp.zig:375`)

- **签名**：`pub fn getFlags(bytecode: []const u8) u16`。
- **作用**：小端 u16 flags。
- **实现**：`<2` 字节返回 0。
- **所有权 / 错误 / 调用**：named_groups、unicode 宽度。

### `groupNameFromBytecode` (`src/libs/regexp.zig:380`)

- **签名**：`fn groupNameFromBytecode(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8`。
- **作用**：按 1-based 捕获取名字（借字节码尾）。
- **实现**：无 named_groups 或 index 0 null。扫 `name\0xx`。空名 null。
- **所有权 / 错误 / 调用**：返回切片别名 bytecode。

### `groupName` (`src/libs/regexp.zig:398`)

- **签名**：`pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8`。
- **作用**：公开包装。
- **实现**：转私有。
- **所有权 / 错误 / 调用**：`regexp_adapter.groupName`（`src/exec/regexp_adapter.zig:63`）转发；`Compiled.groupName` 是并列的方法版，直接走私有函数。

## `Compiled` 与执行入口

### `Compiled.deinit` (`src/libs/regexp.zig:407`)

- **签名**：`pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void`。
- **作用**：释放字节码。
- **实现**：`free` 后空 slice。
- **所有权 / 错误 / 调用**：未交给 GC payload 的临时编译。

### `Compiled.captureCount` (`src/libs/regexp.zig:412`)

- **签名**：`pub fn captureCount(self: Compiled) usize`。
- **作用**：方法版。
- **实现**：`captureCountFromBytecode(self.bytecode)`。
- **所有权 / 错误 / 调用**：按值接收 `Compiled`，只复制切片头、不取 `bytecode` 的所有权（仍由调用方持有的 `Compiled.deinit` 释放）；只读字节码头部，不分配、无 error。唯一的捕获数入口：调用方 `src/exec/regexp_fastpath.zig:797`、`src/exec/string_ops.zig:1491`（并列的裸切片版 `captureCount` 已删）。

### `Compiled.allocCount` (`src/libs/regexp.zig:416`)

- **签名**：`pub fn allocCount(self: Compiled) usize`。
- **作用**：方法版 slot 数。
- **实现**：转私有。
- **所有权 / 错误 / 调用**：同 `captureCount`：借用字节码、不分配、无 error。唯一的 slot 数入口：调用方 `src/exec/regexp_fastpath.zig:769`、`src/exec/string_ops.zig:1490`。

### `Compiled.groupName` (`src/libs/regexp.zig:420`)

- **签名**：`pub fn groupName(self: Compiled, one_based_capture_index: usize) ?[]const u8`。
- **作用**：方法版组名。
- **实现**：转私有。
- **所有权 / 错误 / 调用**：切片活在 `self.bytecode`。

### `Compiled.flagBits` (`src/libs/regexp.zig:424`)

- **签名**：`pub fn flagBits(self: Compiled) u16`。
- **作用**：flags。
- **实现**：`getFlags`。
- **所有权 / 错误 / 调用**：JS 对象同步 `lastIndex` 行为。

### `compilePatternAndFlags` (`src/libs/regexp.zig:429`)

- **签名**：`pub fn compilePatternAndFlags(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !Compiled`。
- **作用**：默认选项编译。
- **实现**：`compilePatternAndFlagsWithOptions(..., .{})`。
- **所有权 / 错误 / 调用**：`regexp_ops` 再导出此名。

### `compilePatternAndFlagsWithOptions` (`src/libs/regexp.zig:433`)

- **签名**：`pub fn compilePatternAndFlagsWithOptions( allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8, options: CompileOptions, ) !Compiled`。
- **作用**：带栈溢出回调。
- **实现**：`compileWithOptions` 包进 `Compiled`。
- **所有权 / 错误 / 调用**：adapter `compileWithRuntime`。

### `compilePatternWithFlagBitsAndOptions` (`src/libs/regexp.zig:442`)

- **签名**：`pub fn compilePatternWithFlagBitsAndOptions( allocator: std.mem.Allocator, pattern: []const u8, re_flags: u16, options: CompileOptions, ) !Compiled`。
- **作用**：flags 已是位图。
- **实现**：`compileWithFlagBitsAndOptions`。
- **所有权 / 错误 / 调用**：跳过字符串 flags 再解析。

### `isSupportedUnicodePropertyExpression` (`src/libs/regexp.zig:451`)

- **签名**：`fn isSupportedUnicodePropertyExpression(name: []const u8) bool`（文件私有）。
- **作用**：LRE 能否实现该 `\p`。
- **实现**：转 `regexp_properties.isSupportedUnicodePropertyExpression`。
- **所有权 / 错误 / 调用**：只有本文件调用，`pub` 已收窄；引擎侧的同名校验走 `core/regexp.zig` → `unicode.isSupportedUnicodePropertyExpression`。





### `execCaptureSlotsSliceTrustedWithOptions` (`src/libs/regexp.zig:514`)

- **签名**：`pub fn execCaptureSlotsSliceTrustedWithOptions( allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions, capture: []usize, ) !ExecResult`。
- **作用**：调用方提供 slot，不造 Match。
- **实现**：trusted `execCaptureSlotsParsed`。
- **所有权 / 错误 / 调用**：adapter 全局循环；`capture` 必须够 `allocCount`。

### `execCaptureSlotsParsed` (`src/libs/regexp.zig:526`)

- **签名**：`fn execCaptureSlotsParsed( allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions, header: REBytecodeHeader, capture: []usize, ) !ExecResult`。
- **作用**：真正启动回溯：选宽度、规范化 start、memset 哨兵、按 `CbufType` 单态 `lreExecBacktrack`。
- **实现**：`start_index > len` → `out_of_range`。checked 拒超大输入（压不进 u32）。`u|v` → utf16_unicode。
- **所有权 / 错误 / 调用**：ctx 用 static 栈；overflow realloc。

### `testMatchTrustedWithOptions` (`src/libs/regexp.zig:595`)

- **签名**：`pub fn testMatchTrustedWithOptions(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions) !bool`。
- **作用**：只要是否匹配。
- **实现**：trusted 执行，`== .match`。
- **所有权 / 错误 / 调用**：经 `regexp_adapter.testOnStringFromIndex` 服务 `RegExp.prototype.test` 快路径（`src/exec/regexp_fastpath.zig:345`）。

## `ExecState`：PC、回溯、读字符

### `ExecState.init` (`src/libs/regexp.zig:622`)

- **签名**：`fn init( s: *REExecContext, capture: [*]usize, bytecode: []const u8, bytecode_end: usize, initial_pc: usize, initial_cptr: usize, ) !ExecState`。
- **作用**：把 ctx/字节码收成热路径状态。
- **实现**：checked 验 `initial_pc ≤ bytecode_end`。指针从 slice 抽出。
- **所有权 / 错误 / 调用**：`BytecodeCorrupt`。

### `ExecState.cbufUtf16` (`src/libs/regexp.zig:655`)

- **签名**：`inline fn cbufUtf16(self: *const ExecState) [*]const u16`。
- **作用**：把 `cbuf` 重解释成 utf16。
- **实现**：`ptrCast alignCast`。latin1 路径不调。
- **所有权 / 错误 / 调用**：所有 utf16 读。

### `ExecState.checkFrameSpace` (`src/libs/regexp.zig:659`)

- **签名**：`inline fn checkFrameSpace(self: *ExecState, n: usize) !void`。
- **作用**：保证还能压 n 帧。
- **实现**：不够则 `btFrameRealloc` 并刷新指针。`@branchHint(.unlikely)`。
- **所有权 / 错误 / 调用**：自身不持有内存：回溯帧栈归 `REExecContext`（`self.s`），首次扩容时 `btFrameRealloc` 从内联 `static_bt_frames` 切到堆并由 context 负责释放；本函数只在扩容后把 `bt_frames`/`bt_end` 重新指向新缓冲。推导 error set 只含 `std.mem.Allocator.Error`，OOM 沿匹配循环上抛。树内唯一调用方 `pushExecState`（`src/libs/regexp.zig:798`）。

### `ExecState.checkUndoSpace` (`src/libs/regexp.zig:672`)

- **签名**：`inline fn checkUndoSpace(self: *ExecState, n: usize) !void`。
- **作用**：undo 容量。
- **实现**：同帧。
- **所有权 / 错误 / 调用**：`save_reset` 可一次要很多。


### `ExecState.pcWithOffset` (`src/libs/regexp.zig:693`)

- **签名**：`inline fn pcWithOffset(self: *const ExecState, offset: i32) ![*]const u8`。
- **作用**：相对跳转。
- **实现**：trusted wrapping 加；checked 防出界。
- **所有权 / 错误 / 调用**：goto/split。

### `ExecState.getU8` (`src/libs/regexp.zig:714`)

- **签名**：`inline fn getU8(self: *ExecState) !u8`。
- **作用**：读 opcode/立即数并前进 PC。
- **实现**：`ensurePc` 1。
- **所有权 / 错误 / 调用**：主循环。

### `ExecState.readU8At` (`src/libs/regexp.zig:721`)

- **签名**：`inline fn readU8At(self: *const ExecState, ptr: [*]const u8) !u8`。
- **作用**：不前进 PC。
- **实现**：`ensurePc`。
- **所有权 / 错误 / 调用**：`save_reset` 两个端点。

### `ExecState.getU16` (`src/libs/regexp.zig:726`)

- **签名**：`inline fn getU16(self: *ExecState) !u16`。
- **作用**：小端 u16。
- **实现**：读 2 字节。
- **所有权 / 错误 / 调用**：`char`、range 个数。

### `ExecState.readU16UncheckedAt` (`src/libs/regexp.zig:733`)

- **签名**：`inline fn readU16UncheckedAt(ptr: [*]const u8) u16`。
- **作用**：二分 range 时已 `ensurePc` 过整块。
- **实现**：`readInt little`。
- **所有权 / 错误 / 调用**：无 self。

### `ExecState.getU32` (`src/libs/regexp.zig:737`)

- **签名**：`inline fn getU32(self: *ExecState) !u32`。
- **作用**：小端 u32。
- **实现**：读 4。
- **所有权 / 错误 / 调用**：`char32`、偏移。

### `ExecState.readU32At` (`src/libs/regexp.zig:744`)

- **签名**：`inline fn readU32At(self: *const ExecState, ptr: [*]const u8) !u32`。
- **作用**：定点 u32。
- **实现**：`ensurePc` 4。
- **所有权 / 错误 / 调用**：`set_i32`/`loop` 操作数。

### `ExecState.readU32UncheckedAt` (`src/libs/regexp.zig:749`)

- **签名**：`inline fn readU32UncheckedAt(ptr: [*]const u8) u32`。
- **作用**：range32 二分。
- **实现**：`readInt`。
- **所有权 / 错误 / 调用**：无 self、不分配、无 error；名字里的 unchecked 是契约：不做 `ensurePc` 边界检查，调用方须自证 `ptr` 后 4 字节在字节码内。调用方只有 range32 二分查找 `src/libs/regexp.zig:1518,1521,1525,1526`。

### `ExecState.getI32` (`src/libs/regexp.zig:753`)

- **签名**：`inline fn getI32(self: *ExecState) !i32`。
- **作用**：有符号偏移。
- **实现**：`@bitCast(getU32)`。
- **所有权 / 错误 / 调用**：goto/split/lookahead。

### `ExecState.compactIndex` (`src/libs/regexp.zig:757`)

- **签名**：`inline fn compactIndex(value: usize) !u32`。
- **作用**：把 PC/cptr 压进帧的 u32。
- **实现**：checked：`>= u32::MAX` corrupt。
- **所有权 / 错误 / 调用**：与 `compact_no_slot_value` 共用上限。

### `ExecState.compactCaptureValue` (`src/libs/regexp.zig:764`)

- **签名**：`inline fn compactCaptureValue(value: usize) !u32`。
- **作用**：slot 值压进 undo；哨兵 → `u32::MAX`。
- **实现**：其它值 `intCast`。
- **所有权 / 错误 / 调用**：`pushUndoAssumeSpace`。

### `ExecState.expandCaptureValue` (`src/libs/regexp.zig:772`)

- **签名**：`inline fn expandCaptureValue(value: u32) usize`。
- **作用**：undo 弹出还原。
- **实现**：`u32::MAX` → `no_slot_value`。
- **所有权 / 错误 / 调用**：`restoreOneUndo`。

### `ExecState.pcOffset` (`src/libs/regexp.zig:776`)

- **签名**：`inline fn pcOffset(self: *const ExecState, pc: [*]const u8) !u32`。
- **作用**：PC → 相对 `bc_base` 的偏移。
- **实现**：`compactIndex(pc - base)`。
- **所有权 / 错误 / 调用**：压帧。

### `ExecState.pcFromOffset` (`src/libs/regexp.zig:783`)

- **签名**：`inline fn pcFromOffset(self: *const ExecState, offset: u32) ![*]const u8`。
- **作用**：偏移 → PC。
- **实现**：checked 比 end。
- **所有权 / 错误 / 调用**：弹帧。

### `ExecState.frameType` (`src/libs/regexp.zig:792`)

- **签名**：`inline fn frameType(frame: REBTFrame) !REExecStateEnum`。
- **作用**：解码 split/lookahead/negative_lookahead。
- **实现**：checked 拒未知 typ。
- **所有权 / 错误 / 调用**：失败路径要跳过 lookahead 帧。

### `ExecState.pushExecState` (`src/libs/regexp.zig:799`)

- **签名**：`inline fn pushExecState(self: *ExecState, pc: [*]const u8, typ: REExecStateEnum) !void`。
- **作用**：压回溯点（另一条路的 PC、当前 cptr、undo 顶）。
- **实现**：`checkFrameSpace(1)`。
- **所有权 / 错误 / 调用**：split、lookahead、贪心 class8 的较短候选。

### `ExecState.saveCapture` (`src/libs/regexp.zig:811`)

- **签名**：`inline fn saveCapture(self: *ExecState, idx: usize, value: usize) !void`。
- **作用**：写 slot 并记 undo。
- **实现**：checked 验 idx；`pushUndo`。
- **所有权 / 错误 / 调用**：`save_start/end`。

### `ExecState.pushUndo` (`src/libs/regexp.zig:818`)

- **签名**：`inline fn pushUndo(self: *ExecState, idx: usize, value: usize) !void`。
- **作用**：确保空间后写 undo。
- **实现**：`checkUndoSpace(1)` + `pushUndoAssumeSpace`。
- **所有权 / 错误 / 调用**：普通保存。

### `ExecState.pushUndoAssumeSpace` (`src/libs/regexp.zig:823`)

- **签名**：`inline fn pushUndoAssumeSpace(self: *ExecState, idx: usize, value: usize) !void`。
- **作用**：已保证空间时写旧值并更新 slot。
- **实现**：idx 必须拟合 u16。
- **所有权 / 错误 / 调用**：`save_reset` 批量。

### `ExecState.saveCaptureCheck` (`src/libs/regexp.zig:835`)

- **签名**：`inline fn saveCaptureCheck(self: *ExecState, idx: usize, value: usize) !void`。
- **作用**：同一回溯层已 undo 过该 slot 则只改值，不再压栈。
- **实现**：从 `undo_len` 扫到 `currentUndoBase`。
- **所有权 / 错误 / 调用**：loop 寄存器反复减 1。

### `ExecState.restoreOneUndo` (`src/libs/regexp.zig:854`)

- **签名**：`inline fn restoreOneUndo(self: *ExecState) !void`。
- **作用**：弹一条 undo。
- **实现**：还原 `capture[slot]`。
- **所有权 / 错误 / 调用**：失败回溯。

### `ExecState.restoreUndoTo` (`src/libs/regexp.zig:867`)

- **签名**：`inline fn restoreUndoTo(self: *ExecState, undo_top: usize) !void`。
- **作用**：恢复到某帧的 undo 顶。
- **实现**：while 弹。
- **所有权 / 错误 / 调用**：`popFrameRestore`。

### `ExecState.currentUndoBase` (`src/libs/regexp.zig:876`)

- **签名**：`inline fn currentUndoBase(self: *const ExecState) usize`。
- **作用**：当前层 undo 起点。
- **实现**：无帧 0，否则顶帧 `undo_top`。
- **所有权 / 错误 / 调用**：`saveCaptureCheck`。

### `ExecState.popFrameRestore` (`src/libs/regexp.zig:880`)

- **签名**：`inline fn popFrameRestore(self: *ExecState) !REBTFrame`。
- **作用**：失败：还原 capture、PC、cptr。
- **实现**：`restoreUndoTo` 再弹。
- **所有权 / 错误 / 调用**：主循环 `dispatch_once` 失败臂。

### `ExecState.popFrameKeepUndo` (`src/libs/regexp.zig:892`)

- **签名**：`inline fn popFrameKeepUndo(self: *ExecState) !REBTFrame`。
- **作用**：lookahead 成功：保留内侧 capture，只恢复 PC/cptr。
- **实现**：不 `restoreUndoTo`。
- **所有权 / 错误 / 调用**：`lookahead_match` 一路弹到 lookahead 帧。

### `ExecState.registerSlot` (`src/libs/regexp.zig:903`)

- **签名**：`inline fn registerSlot(self: *const ExecState, register: usize) usize`。
- **作用**：寄存器在 capture 数组里的下标。
- **实现**：`2*capture_count + register`。
- **所有权 / 错误 / 调用**：loop/`set_i32`。

### `ExecState.readRegisterValue` (`src/libs/regexp.zig:907`)

- **签名**：`inline fn readRegisterValue(self: *const ExecState, register: usize) !usize`。
- **作用**：读寄存器；哨兵在 checked 下 corrupt。
- **实现**：走 `registerSlot`。
- **所有权 / 错误 / 调用**：loop 减一前。

### `ExecState.getCharAtBounded` (`src/libs/regexp.zig:919`)

- **签名**：`inline fn getCharAtBounded(self: *const ExecState, comptime cbuf_type: CbufType, pos: *usize, end: usize) ?u21`。
- **作用**：从 `*pos` 读一码点，不越 `end`。
- **实现**：utf16_unicode 合代理。失败 null（当 corrupt）。
- **所有权 / 错误 / 调用**：只服务正向 backref：utf16_unicode 下的 `back_reference`（:1435）与各宽度的 `back_reference_i`（:1454）；反向由 `getPrevCharAtBounded` 负责。

### `ExecState.getPrevCharAtBounded` (`src/libs/regexp.zig:947`)

- **签名**：`inline fn getPrevCharAtBounded(self: *const ExecState, comptime cbuf_type: CbufType, pos: *usize, start: usize) ?u21`。
- **作用**：向后读一码点。
- **实现**：低代理则并高代理。
- **所有权 / 错误 / 调用**：lookbehind backref。

### `ExecState.getCharUnchecked` (`src/libs/regexp.zig:974`)

- **签名**：`inline fn getCharUnchecked(self: *ExecState, comptime cbuf_type: CbufType) u21`。
- **作用**：热路径前进一码点。调用方已保证 `cptr < end`。
- **实现**：unicode 合代理并 `cptr+=1/2`。
- **所有权 / 错误 / 调用**：几乎所有消费字符的 opcode。

### `ExecState.peekChar` (`src/libs/regexp.zig:992`)

- **签名**：`inline fn peekChar(self: *const ExecState, comptime cbuf_type: CbufType) ?u21`。
- **作用**：不前进。
- **实现**：越界 null。
- **所有权 / 错误 / 调用**：`$`、word boundary。

### `ExecState.peekPrevChar` (`src/libs/regexp.zig:1009`)

- **签名**：`inline fn peekPrevChar(self: *const ExecState, comptime cbuf_type: CbufType) ?u21`。
- **作用**：看前一个码点。
- **实现**：`cptr==0` null。
- **所有权 / 错误 / 调用**：`^`、word boundary。

### `ExecState.prevChar` (`src/libs/regexp.zig:1027`)

- **签名**：`inline fn prevChar(self: *ExecState, comptime cbuf_type: CbufType) !void`。
- **作用**：`prev` opcode：退一码点。
- **实现**：unicode 退一对代理。`cptr==0` corrupt。
- **所有权 / 错误 / 调用**：lookbehind 包着 atom。

### `ExecState.scanUntilChar8` (`src/libs/regexp.zig:1046`)

- **签名**：`inline fn scanUntilChar8(self: *ExecState, comptime cbuf_type: CbufType, needle: u8) bool`。
- **作用**：非 sticky 前缀加速：从下一位置找 byte。
- **实现**：latin1 `indexOfScalar`；utf16 线性比单元。
- **所有权 / 错误 / 调用**：`patchSearchLiteralPrefix` 把 `.any` 换成它。

### `ExecState.scanGreedyClass8` (`src/libs/regexp.zig:1070`)

- **签名**：`inline fn scanGreedyClass8( self: *ExecState, comptime cbuf_type: CbufType, bitmap: [*]const u8, inverted: bool, min: u8, continuation_pc: [*]const u8, ) !bool`。
- **作用**：贪心 `*`/`+` 的 class8：尽量吃，每过 min 压一个较短候选。
- **实现**：不匹配则回退；`pollTimeout`。
- **所有权 / 错误 / 调用**：`tryFoldGreedyClass8Loop` 的 opcode。

### `ExecState.matchRawForward` (`src/libs/regexp.zig:1108`)

- **签名**：`inline fn matchRawForward(self: *ExecState, comptime cbuf_type: CbufType, start: usize, end: usize) bool`。
- **作用**：按代码单元 memcmp 前向 backref（非 unicode）。
- **实现**：长度不够 false。
- **所有权 / 错误 / 调用**：`back_reference` latin1/utf16_units。

### `ExecState.matchRawBackward` (`src/libs/regexp.zig:1126`)

- **签名**：`inline fn matchRawBackward(self: *ExecState, comptime cbuf_type: CbufType, start: usize, end: usize) bool`。
- **作用**：单元 memcmp 后向。
- **实现**：`cptr < len` false。
- **所有权 / 错误 / 调用**：`backward_back_reference`。

## 回溯主循环与头

### `lreExecBacktrack` (`src/libs/regexp.zig:1143`)

- **签名**：`fn lreExecBacktrack( comptime cbuf_type: CbufType, ctx: *REExecContext, capture: [*]usize, bytecode: []const u8, bytecode_end: usize, initial_pc: usize, initial_cptr: usize, ) !bool`。
- **作用**：opcode 解释器。true 匹配。
- **实现**：`main` 循环读 opcode。失败进 `dispatch_once` 外：弹帧直到非 lookahead，再继续。要点：`match` 成功返回；`lookahead_match` 弹到 lookahead 且 **keep undo**；`negative_lookahead_match` restore 后当失败。`char*` 比较（可 canonicalize）。split 压另一条。lookahead 压帧继续。`^$` 看行终止符。`class8` 16 字节位图。`range/range32` 二分闭区间。backref 按捕获槽；unicode 走码点，否则 memcmp；`_i` 两边 canonicalize。word boundary 对 ≥256 只在 ignore-case unicode 认 U+017F/U+212A。loop 系列减寄存器，可选 `check_advance` 防零宽死循环。
- **所有权 / 错误 / 调用**：`Timeout`/`BytecodeCorrupt`。trusted 用 `@enumFromInt`。


### `parseHeader` (`src/libs/regexp.zig:1598`)

- **签名**：`fn parseHeader(bytecode: []const u8) !REBytecodeHeader`。
- **作用**：checked 读头。
- **实现**：长度不足或 `header+bytecode_len` 越界 → corrupt。
- **所有权 / 错误 / 调用**：checked exec。

### `parseHeaderTrusted` (`src/libs/regexp.zig:1610`)

- **签名**：`fn parseHeaderTrusted(bytecode: []const u8) REBytecodeHeader`。
- **作用**：assert 后读头。
- **实现**：`debug.assert` 长度。
- **所有权 / 错误 / 调用**：本编译器产出。


### `decodeOp` (`src/libs/regexp.zig:1629`)

- **签名**：`inline fn decodeOp(byte: u8) ?REOPCodeEnum`。
- **作用**：拒未知 opcode。
- **实现**：`> loop_not_class8_g` null。
- **所有权 / 错误 / 调用**：checked 主循环；编译器 fold 时也用。

### `isLineTerminator` (`src/libs/regexp.zig:1634`)

- **签名**：`inline fn isLineTerminator(code_point: u21) bool`。
- **作用**：`.`/`^$` 的行终止。
- **实现**：LF/CR/LS/PS。
- **所有权 / 错误 / 调用**：纯谓词，不分配、无 error。调用方是主循环的 `line_start_m`（:1226）、`line_end_m`（:1233）与 `dot`（:1239）；与 `unicode.isEcmaLineTerminatorCodePoint` 是平行的本地副本。

### `lreIsSpaceByte` (`src/libs/regexp.zig:1638`)

- **签名**：`inline fn lreIsSpaceByte(byte: u8) bool`。
- **作用**：latin1 space 位。
- **实现**：`lre_ctype_bits & space`。
- **所有权 / 错误 / 调用**：`lreIsSpace`。

### `lreIsSpace` (`src/libs/regexp.zig:1642`)

- **签名**：`inline fn lreIsSpace(code_point: u21) bool`。
- **作用**：`\s`。
- **实现**：`<256` ctype；否则 `isEcmaWhitespaceOrLineTerminatorCodePoint`。
- **所有权 / 错误 / 调用**：space opcode。

### `isHiSurrogate` (`src/libs/regexp.zig:1647`)

- **签名**：`inline fn isHiSurrogate(code_unit: u21) bool`。
- **作用**：高代理。
- **实现**：`>>10 == 0xD800>>10`。
- **所有权 / 错误 / 调用**：执行与编译。

### `isLoSurrogate` (`src/libs/regexp.zig:1651`)

- **签名**：`inline fn isLoSurrogate(code_unit: u21) bool`。
- **作用**：低代理。
- **实现**：`0xDC00` 段。
- **所有权 / 错误 / 调用**：不分配、无 error。本文件内 11 处调用：执行器侧的代理对前后瞻（`src/libs/regexp.zig:335,936,963,982,1000,1018,1037`）与编译器侧的 `\u` 代理对合并（`:1978,1992,3444,3468`），配合 `isHiSurrogate`/`fromSurrogate` 合成码点。

### `fromSurrogate` (`src/libs/regexp.zig:1655`)

- **签名**：`inline fn fromSurrogate(high: u16, low: u16) u21`。
- **作用**：合成码点。
- **实现**：`0x10000 + 0x400*(hi-D800)+(lo-DC00)`。
- **所有权 / 错误 / 调用**：utf16_unicode。

### `decodeWtf8Surrogate` (`src/libs/regexp.zig:1664`)

- **签名**：`fn decodeWtf8Surrogate(bytes: []const u8, index: usize) ?DecodedWtf8`。
- **作用**：把 CESU-8/WTF-8 的 `ED A0..BF 80..BF` 当代理码点读出（`std.unicode.utf8Decode` 会拒）。
- **实现**：三字节；失败 null。
- **所有权 / 错误 / 调用**：`readGroupNameLiteralCodePoint` 与 `REParseState.readUtf8CodePoint` 各调一次；对应 qjs:libregexp.c:1648-1656 让非 `u` 的 `new RegExp` 源里的 CESU-8 半个代理能解出来。

## 修饰符组与 `/v` 字符串集

### `ModifierGroup.applyFlag` (`src/libs/regexp.zig:1709`)

- **签名**：`fn applyFlag(self: ModifierGroup, current: bool, flag: u8) bool`。
- **作用**：`(?ims-ims:…)` 对 i/m/s 的覆盖。
- **实现**：add 真、remove 假、否则 current。
- **所有权 / 错误 / 调用**：`parseGroup`。

### `parseModifierGroup` (`src/libs/regexp.zig:1717`)

- **签名**：`fn parseModifierGroup(pattern: []const u8, start: usize) CompileError!?ModifierGroup`。
- **作用**：认 `(?ims-ims:`。
- **实现**：非 `(?` 或首字符不像修饰符 → null。重复同一 flag 或又加又减 → InvalidPattern。要有 `:`。
- **所有权 / 错误 / 调用**：返回 `body_start`。

### `startsWithAt` (`src/libs/regexp.zig:1750`)

- **签名**：`fn startsWithAt(haystack: []const u8, index: usize, needle: []const u8) bool`。
- **作用**：从 index 比前缀。
- **实现**：长度 + `eql`。
- **所有权 / 错误 / 调用**：唯一调用方是 `parseModifierGroup` 判 `(?` 前缀（`src/libs/regexp.zig:1716`）。

### `isRegExpModifierFlag` (`src/libs/regexp.zig:1754`)

- **签名**：`fn isRegExpModifierFlag(byte: u8) bool`。
- **作用**：i/m/s。
- **实现**：三值。
- **所有权 / 错误 / 调用**：不分配、无 error；文件私有。调用方只有 modifier 组 `(?i-m:…)` 的解析 `src/libs/regexp.zig:1720,1725,1733`。

### `modifierFlagSlot` (`src/libs/regexp.zig:1758`)

- **签名**：`fn modifierFlagSlot(byte: u8) usize`。
- **作用**：i→0 m→1 s→2。
- **实现**：switch；其它 unreachable。
- **所有权 / 错误 / 调用**：调用方已过滤。

### `REStringList.init` (`src/libs/regexp.zig:1781`)

- **签名**：`fn init(allocator: std.mem.Allocator) REStringList`。
- **作用**：空 class set。
- **实现**：空 CharRange + 空 strings。
- **所有权 / 错误 / 调用**：必须 deinit。

### `REStringList.deinit` (`src/libs/regexp.zig:1785`)

- **签名**：`fn deinit(self: *REStringList) void`。
- **作用**：释放每条字符串和区间。
- **实现**：逐条 `free`。
- **所有权 / 错误 / 调用**：`/v` 解析 defer。

### `REStringList.containsString` (`src/libs/regexp.zig:1791`)

- **签名**：`fn containsString(self: *const REStringList, needle: []const u21) bool`。
- **作用**：去重查询。
- **实现**：线性 `eql`。
- **所有权 / 错误 / 调用**：add/union。

### `REStringList.addOwnedString` (`src/libs/regexp.zig:1799`)

- **签名**：`fn addOwnedString(self: *REStringList, s: []u21) !void`。
- **作用**：接管切片；已存在则 free。
- **实现**：`contains` 则释放。
- **所有权 / 错误 / 调用**：`\q`。

### `REStringList.unionWith` (`src/libs/regexp.zig:1807`)

- **签名**：`fn unionWith(self: *REStringList, other: *const REStringList) !void`。
- **作用**：并码点与字符串。
- **实现**：`ranges.addSet`；缺的字符串 dupe。
- **所有权 / 错误 / 调用**：ClassUnion。

### `REStringList.intersectWith` (`src/libs/regexp.zig:1817`)

- **签名**：`fn intersectWith(self: *REStringList, other: *REStringList) !void`。
- **作用**：交。
- **实现**：区间交；字符串只留两边都有的。
- **所有权 / 错误 / 调用**：`&&`。

### `REStringList.subtract` (`src/libs/regexp.zig:1831`)

- **签名**：`fn subtract(self: *REStringList, other: *REStringList) !void`。
- **作用**：差。
- **实现**：区间差；丢掉 other 里有的字符串。
- **所有权 / 错误 / 调用**：`--`。

## 编译入口与 flags

### `compile` (`src/libs/regexp.zig:1853`)

- **签名**：`pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) CompileError![]u8`。
- **作用**：返回裸字节码切片。
- **实现**：`compileWithOptions(..., .{})`。
- **所有权 / 错误 / 调用**：调用方 free。`Compiled` 包装更常用。

### `compileWithOptions` (`src/libs/regexp.zig:1857`)

- **签名**：`pub fn compileWithOptions( allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8, options: CompileOptions, ) CompileError![]u8`。
- **作用**：解析 flags 字符串再编译。
- **实现**：`parseFlagBits` + `compileWithFlagBitsAndOptions`。
- **所有权 / 错误 / 调用**：重复 flag / `u`+`v` → InvalidPattern。

### `compileWithFlagBitsAndOptions` (`src/libs/regexp.zig:1866`)

- **签名**：`pub fn compileWithFlagBitsAndOptions( allocator: std.mem.Allocator, pattern: []const u8, re_flags: u16, options: CompileOptions, ) CompileError![]u8`。
- **作用**：编译核心。
- **实现**：建 `REParseState`。`emitHeader`。非 sticky 发射 `split + any + goto -11` 搜索前缀。`save_start 0`、`reParseDisjunction`、必须吃完 pattern、`save_end 0`、`match`。`patchSearchLiteralPrefix`（首原子是 `char` 且 ≤0xff 则换成 `scan_until_char8`）。`patchHeader` 写 flags/captures/registers/len，附加组名。
- **所有权 / 错误 / 调用**：`errdefer` 释放 byte_code；组名 defer。栈溢出回调来自 options。

### `parseFlagBits` (`src/libs/regexp.zig:1906`)

- **签名**：`pub fn parseFlagBits(flag_bytes: []const u8) CompileError!u16`。
- **作用**：`gimsuyvd` → 位图。
- **实现**：`seen[256]` 拒重复。未知字符非法。`u` 与 `v` 同时出现非法。
- **所有权 / 错误 / 调用**：`d` 只记 indices，引擎层再实现。

### `parseGroupNameAt` (`src/libs/regexp.zig:1944`)

- **签名**：`fn parseGroupNameAt(pattern: []const u8, index: *usize) CompileError![]const u8`。
- **作用**：读到 `>` 的组名。
- **实现**：首码点 `isRegExpGroupNameStart`，其余 Continue。
- **所有权 / 错误 / 调用**：切片借 pattern。

### `groupNamesEqual` (`src/libs/regexp.zig:1962`)

- **签名**：`fn groupNamesEqual(lhs: []const u8, rhs: []const u8) bool`。
- **作用**：按码点比组名（代理转义与字面等价）。
- **实现**：两边 `readGroupNameCodePoint`。
- **所有权 / 错误 / 调用**：decode 失败当不等。

### `readGroupNameCodePoint` (`src/libs/regexp.zig:1973`)

- **签名**：`fn readGroupNameCodePoint(pattern: []const u8, index: *usize) CompileError!u21`。
- **作用**：组名里一个码点，含 `\u` 与 WTF-8 代理对。
- **实现**：`\\` 走 unicode escape 并可合并代理；否则字面。超 `10FFFF` 非法。
- **所有权 / 错误 / 调用**：qjs 无条件合并随后的低代理。

### `readGroupNameLiteralCodePoint` (`src/libs/regexp.zig:2002`)

- **签名**：`fn readGroupNameLiteralCodePoint(pattern: []const u8, index: *usize) CompileError!u21`。
- **作用**：字面 UTF-8/WTF-8。
- **实现**：先 `decodeWtf8Surrogate`，再 `utf8Decode`。
- **所有权 / 错误 / 调用**：非法 UTF-8 → InvalidPattern。

### `readUnicodeEscapeCodePoint` (`src/libs/regexp.zig:2017`)

- **签名**：`fn readUnicodeEscapeCodePoint(pattern: []const u8, index: *usize) CompileError!u21`。
- **作用**：`\uXXXX` 或 `\u{...}`。
- **实现**：要 `\\u`。花括号可变长 hex，拒空和溢出。
- **所有权 / 错误 / 调用**：只借 `pattern`、不分配；唯一调用方是 `readGroupNameCodePoint`（`src/libs/regexp.zig:1974,1977`），pattern 正文里的 `\u` 另走 `parseEscape`（:2479）。

### `isRegExpGroupNameStart` (`src/libs/regexp.zig:2045`)

- **签名**：`fn isRegExpGroupNameStart(cp: u21) bool`（文件私有）。
- **作用**：组名首字符。
- **实现**：`$` `_` ASCII 字母；非法表 false；`>0x7F` 真。
- **所有权 / 错误 / 调用**：调用方只有本文件的 `parseGroupNameAt`（:1949）与 `isRegExpGroupNameContinue`（:2053），`pub` 已收窄。

### `isRegExpGroupNameContinue` (`src/libs/regexp.zig:2052`)

- **签名**：`fn isRegExpGroupNameContinue(cp: u21) bool`（文件私有）。
- **作用**：组名后续。
- **实现**：非法表 false；U+104A4 特准；Start 或 ASCII 数字或 U+1D7DA。
- **所有权 / 错误 / 调用**：不分配、无 error；只读 comptime 表。唯一调用方是本文件的组名扫描 `src/libs/regexp.zig:1950`，`pub` 已收窄。

### `isInvalidRegExpGroupNameStart` (`src/libs/regexp.zig:2061`)

- **签名**：`fn isInvalidRegExpGroupNameStart(cp: u21) bool`。
- **作用**：明确排除的码点（代理、若干 emoji、10FFFF）。
- **实现**：switch + surrogate。
- **所有权 / 错误 / 调用**：纯谓词、无 error；唯一调用方 `isRegExpGroupNameStart`（:2046）。表本身对齐 qjs 的排除集。

### `isInvalidRegExpGroupNameContinue` (`src/libs/regexp.zig:2069`)

- **签名**：`fn isInvalidRegExpGroupNameContinue(cp: u21) bool`（文件私有）。
- **作用**：Continue 排除表（比 Start 少 U+104A4/1D7DA）。
- **实现**：switch。
- **所有权 / 错误 / 调用**：纯谓词、无 error；唯一调用方是 `isRegExpGroupNameContinue`（:2051），`pub` 已收窄。

## `REParseState` 解析

### `REParseState.lreCheckStackOverflow` (`src/libs/regexp.zig:2099`)

- **签名**：`fn lreCheckStackOverflow(self: *const REParseState, alloca_size: usize) bool`。
- **作用**：递归入口问宿主。null 回调 = 永不溢出（fuzz 对齐 qjs 返回 0）。
- **实现**：调 `check_stack_overflow`。
- **所有权 / 错误 / 调用**：`reParseDisjunction`、`reParseNestedClass`。

### `REParseState.atomResult` (`src/libs/regexp.zig:2104`)

- **签名**：`fn atomResult(self: *const REParseState, start: usize, quantifiable: bool) Atom`。
- **作用**：记下 atom 起点和量化前捕获数。
- **实现**：填 struct。
- **所有权 / 错误 / 调用**：escape 等。

### `REParseState.putGroupName` (`src/libs/regexp.zig:2115`)

- **签名**：`fn putGroupName(self: *REParseState, maybe_name: ?[]const u8) CompileError!void`。
- **作用**：追加 `name\0 scope`；匿名写两个 0。
- **实现**：有名则 `has_named_captures=1`。
- **所有权 / 错误 / 调用**：`name` 只借用来做一次拷贝；字节进 `self.group_names`（`ArrayList(u8)`，用 `self.allocator`，随 `REParseState` 一起释放，最终作为组名区拼进编译产物）。`CompileError` 在这里只可能取到 `error.OutOfMemory`，沿 `compilePatternWithFlagBits…` 上抛，由 `src/exec/regexp_ops.zig:568` 的 `else => |other| return other` 原样传给 JS 层。唯一调用方 `src/libs/regexp.zig:2409`（捕获组登记）。

### `REParseState.isDuplicateGroupName` (`src/libs/regexp.zig:2127`)

- **签名**：`fn isDuplicateGroupName(self: *const REParseState, name: []const u8, scope: u8) bool`。
- **作用**：同 scope 重名。
- **实现**：扫 group_names。
- **所有权 / 错误 / 调用**：`|` 会 `group_name_scope +%= 1` 允许同名不同支。

### `REParseState.findGroupName` (`src/libs/regexp.zig:2138`)

- **签名**：`fn findGroupName(self: *REParseState, name: []const u8, emit_group_index: bool) CompileError!u16`。
- **作用**：已定义的同名捕获个数；可选把下标写进字节码。
- **实现**：扫表。
- **所有权 / 错误 / 调用**：`\k<name>`。

### `REParseState.reParseCaptures` (`src/libs/regexp.zig:2154`)

- **签名**：`fn reParseCaptures(self: *REParseState, capture_name: ?[]const u8, emit_group_index: bool) CompileError!CaptureParseResult`。
- **作用**：粗扫 pattern 数捕获 / 找前向引用名。跳过 class 与 `(?:`/`(?=`/`(?!`。
- **实现**：遇 `(` 且非断言则 `capture_index++`，封顶 255。
- **所有权 / 错误 / 调用**：`reCountCaptures`、前向 `\k`。

### `REParseState.reCountCaptures` (`src/libs/regexp.zig:2204`)

- **签名**：`fn reCountCaptures(self: *REParseState) CompileError!u16`。
- **作用**：缓存总捕获数。
- **实现**：`total_capture_count < 0` 才扫。
- **所有权 / 错误 / 调用**：`\1` 是否当 backref。

### `REParseState.reHasNamedCaptures` (`src/libs/regexp.zig:2213`)

- **签名**：`fn reHasNamedCaptures(self: *REParseState) CompileError!bool`。
- **作用**：pattern 是否有 `(?<name>`。
- **实现**：必要时 `reCountCaptures`。
- **所有权 / 错误 / 调用**：非 unicode `\k` 合法性。

### `REParseState.emitHeader` (`src/libs/regexp.zig:2220`)

- **签名**：`fn emitHeader(self: *REParseState) !void`。
- **作用**：先占 8 字节零。
- **实现**：`appendNTimes(0, 8)`。
- **所有权 / 错误 / 调用**：编译开头。

### `REParseState.patchHeader` (`src/libs/regexp.zig:2224`)

- **签名**：`fn patchHeader(self: *REParseState) !void`。
- **作用**：回填头并追加组名；`reComputeRegisterCount` **重写** loop 寄存器编号。
- **实现**：有实质组名则 `flags |= named_groups`。
- **所有权 / 错误 / 调用**：寄存器 >255 → Unsupported。

### `REParseState.patchSearchLiteralPrefix` (`src/libs/regexp.zig:2236`)

- **签名**：`fn patchSearchLiteralPrefix(self: *REParseState) void`。
- **作用**：非 sticky 且模式以 `char ≤0xff` 开头时，把扫描 `.any` 换成 `scan_until_char8`。
- **实现**：核对 11 字节前缀形态，失败静默。
- **所有权 / 错误 / 调用**：不分配、无 error：只在 `self.byte_code.items` 上原地重写 2 个字节（`prelude+5` 的 opcode 换成 `scan_until_char8`、`prelude+6` 写 needle）；`prelude+7` 的 `-11` 偏移在守卫里已断言过且指令宽度不变，因此不再重写（原先那条按原值写回的 `writeInt` 已删），形态不匹配就静默返回。唯一调用方是编译收尾 `src/libs/regexp.zig:1898`。

### `REParseState.reParseDisjunction` (`src/libs/regexp.zig:2263`)

- **签名**：`fn reParseDisjunction(self: *REParseState, terminator: ?u8, is_backward_dir: bool) CompileError!void`。
- **作用**：`alt (| alt)*`。qjs:2410 每层栈检查。
- **实现**：先 alternative；每个 `|` 在 start 插入 `split_next_first`，支尾 `goto`，`group_name_scope++`。terminator 必须出现。
- **所有权 / 错误 / 调用**：栈溢出 SyntaxError。

### `REParseState.reParseAlternative` (`src/libs/regexp.zig:2286`)

- **签名**：`fn reParseAlternative(self: *REParseState, terminator: ?u8, is_backward_dir: bool) CompileError!void`。
- **作用**：一串 term。
- **实现**：`)` 单独出现非法。lookbehind 时每个 term `moveTermToStart` 倒序。
- **所有权 / 错误 / 调用**：空 alternative 合法。

### `REParseState.reParseTerm` (`src/libs/regexp.zig:2302`)

- **签名**：`fn reParseTerm(self: *REParseState, is_backward_dir: bool) CompileError!Atom`。
- **作用**：一个 atom（不含量词）。
- **实现**：`^$` 按 multiline 选 opcode，不可量化。`.` 按 dotall。孤立量词非法。`{` 在 unicode 或像量词时非法，否则当字面。`(`/`[`/`\\` 分流。`]` `}` 非 unicode 当字面。其它读码点；非 unicode 非 BMP 拆代理对（量化落在低代理 atom）。
- **所有权 / 错误 / 调用**：随后 `parseQuantifier`。

### `REParseState.parseGroup` (`src/libs/regexp.zig:2351`)

- **签名**：`fn parseGroup(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom`。
- **作用**：`(` 组。
- **实现**：`(?:` 非捕获。修饰符组临时改 i/m/s。`(?=)/(?!)` 前瞻，unicode 下不可量化。`(?<=)/(?<!)` lookbehind 强制 backward。`(?<name>` 命名捕获。其它 `?` → Unsupported。普通 `(` 捕获。
- **所有权 / 错误 / 调用**：lookahead 的 offset 回填。

### `REParseState.parseCaptureGroup` (`src/libs/regexp.zig:2407`)

- **签名**：`fn parseCaptureGroup(self: *REParseState, start: usize, maybe_name: ?[]const u8, is_backward_dir: bool) CompileError!Atom`。
- **作用**：分配捕获编号、写 save、解析到 `)`。
- **实现**：255 个封顶。backward 时先 save_end 再 save_start。
- **所有权 / 错误 / 调用**：重名 InvalidPattern。

### `REParseState.parseEscape` (`src/libs/regexp.zig:2423`)

- **签名**：`fn parseEscape(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom`。
- **作用**：`\\` 转义。
- **实现**：`b/B` 词边界（unicode+i 用 `_i`）。`s/S` space opcode。`dDwW` 建成 CharRange 再 emit range。`1-9` 合法 backref 否则非 u 遗留八进制。`0` unicode 后禁 digit。`x`/`u` 失败时非 u 当字面。`c` 控制字符。`fnrtv`。`p/P`：非 u 当字面；`/v` 先试字符串属性；否则 `parseUnicodePropertyEscape`，i 与 invert 顺序见 19-libs。`k` 命名引用，可前向 `reParseCaptures`。语法转义；非 u 允许其它。
- **所有权 / 错误 / 调用**：临时 CharRange defer。

### `REParseState.reParseCharClass` (`src/libs/regexp.zig:2618`)

- **签名**：`fn reParseCharClass(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom`。
- **作用**：`[…]`。
- **实现**：`/v` → `reParseNestedClass` + `reEmitStringList`。否则 `^` 求补，循环 `reParseClassAtomOrRange` 直到 `]`。
- **所有权 / 错误 / 调用**：未闭合 InvalidPattern。

### `REParseState.atMatch` (`src/libs/regexp.zig:2650`)

- **签名**：`fn atMatch(self: *const REParseState, needle: []const u8) bool`。
- **作用**：当前位置是否 needle。
- **实现**：`eql`。
- **所有权 / 错误 / 调用**：`&&` `--` `\q`。

### `REParseState.reParseNestedClass` (`src/libs/regexp.zig:2662`)

- **签名**：`fn reParseNestedClass(self: *REParseState) CompileError!REStringList`。
- **作用**：`/v` ClassSetExpression。qjs:1390 栈检查。
- **实现**：可选 `^`。空 `[]`。第一操作数后：`--` 链差、`&&` 链交、否则并。同层不能混算子。range 不能当差/交的左操作数。求补时若有字符串 → InvalidPattern。
- **所有权 / 错误 / 调用**：调用方拥有返回集。

### `REParseState.reParseClassSetOperand` (`src/libs/regexp.zig:2735`)

- **签名**：`fn reParseClassSetOperand(self: *REParseState, allow_range: bool) CompileError!REStringListOperandResult`。
- **作用**：一个操作数或 ClassSetRange。
- **实现**：嵌套 `[`、`\q`、字符串 `\p`、保留标点错误。否则 `getClassAtom`；`allow_range` 且 `-` 不是 `--`/结尾则成 range。
- **所有权 / 错误 / 调用**：`was_range` 约束算子。

### `REParseState.parseClassStringDisjunction` (`src/libs/regexp.zig:2791`)

- **签名**：`fn parseClassStringDisjunction(self: *REParseState) CompileError!REStringList`。
- **作用**：`\q{alt|alt}`。
- **实现**：单码点进 ranges，更长（含空）进 strings。i 则 canonicalize。
- **所有权 / 错误 / 调用**：非 code_point atom 非法。

### `REParseState.reEmitStringList` (`src/libs/regexp.zig:2834`)

- **签名**：`fn reEmitStringList(self: *REParseState, set: *REStringList, is_backward_dir: bool) CompileError!void`。
- **作用**：先最长字符串（heap 排序只比长度），再码点集，空串隐式。
- **实现**：`split_next_first` 链；backward 倒着 emit 字符。
- **所有权 / 错误 / 调用**：无字符串则只 `reEmitRange`。

### `REParseState.longerFirst` (`src/libs/regexp.zig:2849`)

- **签名**：`fn longerFirst(_: void, lhs: []u21, rhs: []u21) bool`。
- **作用**：heap sort 比较器：更长的先。
- **实现**：`lhs.len > rhs.len`。等长相对序不可观察。
- **所有权 / 错误 / 调用**：`sort_erased.heap`。

### `REParseState.reParseClassAtomOrRange` (`src/libs/regexp.zig:2899`)

- **签名**：`fn reParseClassAtomOrRange(self: *REParseState, body_start: usize) CompileError!CharRange`。
- **作用**：非 `/v`（及 `/v` 并集里的字符）的 atom 或 `a-z`。
- **实现**：`/v` 检查保留字节/双标点。`-` 后不是 code_point：unicode 非法；非 u 回退成两个 atom。
- **所有权 / 错误 / 调用**：丢弃未用的 ranges 所有权。

### `REParseState.getClassAtom` (`src/libs/regexp.zig:2950`)

- **签名**：`fn getClassAtom(self: *REParseState) CompileError!REClassAtom`。
- **作用**：class 里一个原子。
- **实现**：`dDsSwW` → ranges。unicode `\0` 后禁 digit。`\b` = U+0008。`\c` 控制或非 u 退化成 `\\`+`c`。`\p` 走 `parseUnicodePropertyEscapeWithOrdering`。`x`/`u` 失败非 u 当字面。非 BMP 非 u 拆成两个代理区间。
- **所有权 / 错误 / 调用**：`.ranges` 臂调用方必须 deinit。

### `REParseState.parseQuantifier` (`src/libs/regexp.zig:3074`)

- **签名**：`fn parseQuantifier(self: *REParseState, atom: Atom) CompileError!void`。
- **作用**：`*+?{n,m}` 及 lazy `?`。
- **实现**：不可量化 atom 加量词非法。`{` 无数字非 u 当不是量词。分析 atom 是否零宽/是否需要 `save_reset`。贪心无上界的 class8 试 fold。否则 `wrapGenericQuantifier`。
- **所有权 / 错误 / 调用**：min>max 非法。

### `REParseState.tryFoldGreedyClass8Loop` (`src/libs/regexp.zig:3140`)

- **签名**：`fn tryFoldGreedyClass8Loop(self: *REParseState, atom_start: usize, min: u8) !bool`。
- **作用**：把单独的 `class8`/`not_class8` 改成 `loop_*_g`。
- **实现**：长度必须恰好 1+16。插入 min 字节。
- **所有权 / 错误 / 调用**：失败 false 走通用量化。

### `REParseState.wrapGenericQuantifier` (`src/libs/regexp.zig:3151`)

- **签名**：`fn wrapGenericQuantifier(self: *REParseState, atom_start: usize, min: u32, max: u32, greedy: bool, need_check_advance: bool) CompileError!void`。
- **作用**：插入 split/loop/set_i32/check_advance。
- **实现**：`max==0` 删 atom。`min==0` 的 `?`/`*` 用 split（可选 set_char_pos+check_advance 防零宽）。有限 max 用 loop_split。`min==max` 用 `loop`。寄存器编号事后 `reComputeRegisterCount` 重写。
- **所有权 / 错误 / 调用**：`insertBytes` OOM。

### `REParseState.parseDecimalEscape` (`src/libs/regexp.zig:3230`)

- **签名**：`fn parseDecimalEscape(self: *REParseState) CompileError!u32`。
- **作用**：吃 `\\` 后的十进制（backref）。
- **实现**：`parseDigits(false)` 不饱和。
- **所有权 / 错误 / 调用**：溢出 InvalidPattern。

### `REParseState.parseLegacyDecimalEscape` (`src/libs/regexp.zig:3236`)

- **签名**：`fn parseLegacyDecimalEscape(self: *REParseState) CompileError!u21`。
- **作用**：非 u 遗留八进制/数字。
- **实现**：`>7` 当单字符；`≤3` 可吃最多 3 个八进制 digit。
- **所有权 / 错误 / 调用**：无效 backref 回退。

### `REParseState.parseLegacyOctalAfterZero` (`src/libs/regexp.zig:3259`)

- **签名**：`fn parseLegacyOctalAfterZero(self: *REParseState) CompileError!u21`。
- **作用**：`\0` 后再吃最多 2 个八进制。
- **实现**：循环。
- **所有权 / 错误 / 调用**：unicode 路径不会到这里若后面是 digit。

### `REParseState.parseLegacyClassDecimalEscape` (`src/libs/regexp.zig:3271`)

- **签名**：`fn parseLegacyClassDecimalEscape(self: *REParseState) CompileError!u21`。
- **作用**：class 里 `\0`–`\377` 风格，值 >0xFF 停。
- **实现**：最多 3 个八进制。
- **所有权 / 错误 / 调用**：`getClassAtom`。

### `REParseState.parseGroupName` (`src/libs/regexp.zig:3296`)

- **签名**：`fn parseGroupName(self: *REParseState) CompileError![]const u8`。
- **作用**：从 `buf_ptr` 读组名。
- **实现**：`parseGroupNameAt`。
- **所有权 / 错误 / 调用**：`(?<` / `\k<`。

### `REParseState.parseStringPropertyEscape` (`src/libs/regexp.zig:3305`)

- **签名**：`fn parseStringPropertyEscape(self: *REParseState) CompileError!?REStringList`。
- **作用**：若 `\p{seq}` 是 property of strings 则消费并返回集；`\P` 非法。其它属性返回 null 且不前进。
- **实现**：扫到 `}`；`isSequencePropertyName`。
- **所有权 / 错误 / 调用**：`/v` 的 `\p` 与 class operand。

### `REParseState.buildStringPropertyStringList` (`src/libs/regexp.zig:3320`)

- **签名**：`fn buildStringPropertyStringList(self: *REParseState, property_name: []const u8) CompileError!?REStringList`。
- **作用**：回调展开序列。
- **实现**：`addSequenceProperty`；`InvalidProperty` 标 unreachable（名字已验证）。i 则 `ranges.regexpCanonicalize(true)`。
- **所有权 / 错误 / 调用**：返回值是 **owned** `REStringList`（含用 `self.allocator` 分配的 ranges 与逐条 `dupe` 的序列），调用方负责 `deinit`；函数内用 `errdefer set.deinit()` 保证失败不漏，属性名未命中时先 `set.deinit()` 再返回 `null`。`CompileError` 实际只可能是 `error.OutOfMemory`（`InvalidProperty` 被 `unreachable` 挡掉，名字已先验）。唯一调用方 `src/libs/regexp.zig:3310`，就地 `.?` 解包。

### `REParseState.addSequenceToStringList` (`src/libs/regexp.zig:3339`)

- **签名**：`fn addSequenceToStringList(ctx: *REStringListBuildContext, sequence: []const u21) std.mem.Allocator.Error!void`。
- **作用**：长度 1 进区间，否则 dupe 进 strings（i 则逐码点 canonicalize）。
- **实现**：重复字符串 free。
- **所有权 / 错误 / 调用**：`addSequenceProperty` 的 callback。

### `REParseState.parseUnicodePropertyEscapeWithOrdering` (`src/libs/regexp.zig:3358`)

- **签名**：`fn parseUnicodePropertyEscapeWithOrdering(self: *REParseState, inverted: bool) CompileError!CharRange`。
- **作用**：`/u` vs `/v` 的 i+求补顺序。
- **实现**：`/v`+i 先 canonicalize 再 invert；`/u`+i 先 invert 再 canonicalize。
- **所有权 / 错误 / 调用**：class 里的 `\p`。

### `REParseState.parseUnicodePropertyEscape` (`src/libs/regexp.zig:3371`)

- **签名**：`fn parseUnicodePropertyEscape(self: *REParseState) CompileError!CharRange`。
- **作用**：读 `\p{Name}` 正文并 `addUnicodeProperty`。
- **实现**：名字须 word 或 `=`，出现别的字节才是 `Unsupported`。空名非法。未知属性走 `addUnicodeProperty`，`InvalidProperty` 映成 `InvalidPattern`。
- **所有权 / 错误 / 调用**：不在这里 invert。

### `REParseState.parseDigits` (`src/libs/regexp.zig:3392`)

- **签名**：`fn parseDigits(self: *REParseState, allow_overflow: bool) CompileError!u32`。
- **作用**：十进制，可选饱和到 `int32_max`。
- **实现**：无 digit 非法。
- **所有权 / 错误 / 调用**：量词允许溢出；backref 不允许。

### `REParseState.parseFixedHexEscape` (`src/libs/regexp.zig:3407`)

- **签名**：`fn parseFixedHexEscape(self: *REParseState, digit_count: usize) CompileError!u21`。
- **作用**：吃 `\\x`/`\\u` 后固定位数。
- **实现**：先 `buf_ptr += 2`。
- **所有权 / 错误 / 调用**：`\xHH`、`\uXXXX`。

### `REParseState.parseUnicodeEscape` (`src/libs/regexp.zig:3419`)

- **签名**：`fn parseUnicodeEscape(self: *REParseState) CompileError!u21`。
- **作用**：`\u{…}`（仅 unicode）或 `\uXXXX`。
- **实现**：花括号可变长，拒 >10FFFF。
- **所有权 / 错误 / 调用**：`isBracedUnicodeEscape`。

### `REParseState.isBracedUnicodeEscape` (`src/libs/regexp.zig:3439`)

- **签名**：`fn isBracedUnicodeEscape(self: *const REParseState) bool`。
- **作用**：unicode 模式且 `\u{`。
- **实现**：看 `buf_ptr+2`。
- **所有权 / 错误 / 调用**：非 u 永不花括号。

### `REParseState.combineEscapedSurrogatePair` (`src/libs/regexp.zig:3443`)

- **签名**：`fn combineEscapedSurrogatePair(self: *REParseState, first: u21) CompileError!u21`。
- **作用**：unicode 下 `\uD800\uDC00` 合成。
- **实现**：不是高代理、不是 `\u`、或是花括号 → 原样。低代理失败则回退指针。
- **所有权 / 错误 / 调用**：pattern 与 class。

### `REParseState.readPatternCodePoint` (`src/libs/regexp.zig:3456`)

- **签名**：`fn readPatternCodePoint(self: *REParseState) CompileError!u21`。
- **作用**：pattern 里一个非语法码点。
- **实现**：ASCII 语法字节非法。
- **所有权 / 错误 / 调用**：`reParseTerm` else。

### `REParseState.readClassCodePoint` (`src/libs/regexp.zig:3463`)

- **签名**：`fn readClassCodePoint(self: *REParseState) CompileError!u21`。
- **作用**：class 字面码点；unicode 合并代理对。
- **实现**：第二码点失败则回退当单独高代理。
- **所有权 / 错误 / 调用**：`getClassAtom` 非 `\\`。

### `REParseState.readUtf8CodePoint` (`src/libs/regexp.zig:3480`)

- **签名**：`fn readUtf8CodePoint(self: *REParseState) CompileError!u21`。
- **作用**：UTF-8 或 WTF-8 代理。
- **实现**：`<0x80` 单字节；`decodeWtf8Surrogate`；否则 `utf8Decode`。
- **所有权 / 错误 / 调用**：pattern/class 共用。

### `REParseState.looksLikeQuantifier` (`src/libs/regexp.zig:3499`)

- **签名**：`fn looksLikeQuantifier(self: *const REParseState, start: usize) bool`。
- **作用**：`{digits(,digits)?}` 形态。
- **实现**：不消费。
- **所有权 / 错误 / 调用**：非 u 的 `{` 是否当字面。

### `REParseState.reEmitChar` (`src/libs/regexp.zig:3512`)

- **签名**：`fn reEmitChar(self: *REParseState, cp: u21) !void`。
- **作用**：`char`/`char32`（及 `_i`）。
- **实现**：`≤0xffff` 用 u16。
- **所有权 / 错误 / 调用**：忽略大小写由 `ignore_case` 选 opcode。

### `REParseState.emitCharacterAtom` (`src/libs/regexp.zig:3520`)

- **签名**：`fn emitCharacterAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void`。
- **作用**：lookbehind 时前后加 `prev`。
- **实现**：`prev` + char + `prev`。
- **所有权 / 错误 / 调用**：方向包装。

### `REParseState.emitCanonicalChar` (`src/libs/regexp.zig:3526`)

- **签名**：`fn emitCanonicalChar(self: *REParseState, cp: u21, is_backward_dir: bool) !void`。
- **作用**：先 `canonicalizeLiteral` 再发射。
- **实现**：一行。
- **所有权 / 错误 / 调用**：大多数字面。

### `REParseState.emitDirectional` (`src/libs/regexp.zig:3530`)

- **签名**：`fn emitDirectional(self: *REParseState, op: REOPCodeEnum, is_backward_dir: bool) !void`。
- **作用**：给无立即数 opcode 加 prev 包装。
- **实现**：dot/any/space。
- **所有权 / 错误 / 调用**：自己不分配，字节都写进 `self.byte_code`（`REParseState` 持有、随之释放）；推导 error set 是 `std.mem.Allocator.Error`，OOM 上抛。调用方 `src/libs/regexp.zig:2315`（`.` / dotall）与 `:2436`（`\s`/`\S`）。

### `REParseState.emitDirectionalRange` (`src/libs/regexp.zig:3536`)

- **签名**：`fn emitDirectionalRange(self: *REParseState, ranges: *CharRange, is_backward_dir: bool) !void`。
- **作用**：range 的方向包装。
- **实现**：`reEmitRange`。
- **所有权 / 错误 / 调用**：class、`\d`。

### `REParseState.emitNonUnicodeSurrogatePairAtom` (`src/libs/regexp.zig:3542`)

- **签名**：`fn emitNonUnicodeSurrogatePairAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void`。
- **作用**：非 u 把非 BMP 拆成两个 UTF-16 atom。
- **实现**：backward 先低后高。
- **所有权 / 错误 / 调用**：class 区间用 `addNonUnicodeSurrogatePair` 而不是它。

### `REParseState.emitNonUnicodeCodePointAtom` (`src/libs/regexp.zig:3555`)

- **签名**：`fn emitNonUnicodeCodePointAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void`。
- **作用**：非 u 码点发射。
- **实现**：`>FFFF` 拆对，否则 canonicalize。
- **所有权 / 错误 / 调用**：非法 `\c` 后续。

### `REParseState.emitInvalidControlEscape` (`src/libs/regexp.zig:3564`)

- **签名**：`fn emitInvalidControlEscape(self: *REParseState, is_backward_dir: bool) CompileError!void`。
- **作用**：非 u 的坏 `\c` 当成 `\\` `c` 再可选下一码点。
- **实现**：`buf_ptr += 2`。
- **所有权 / 错误 / 调用**：unicode 不会走。

### `REParseState.emitNonUnicodeSurrogatePairTerms` (`src/libs/regexp.zig:3575`)

- **签名**：`fn emitNonUnicodeSurrogatePairTerms(self: *REParseState, cp: u21, is_backward_dir: bool) !usize`。
- **作用**：拆对并返回量词该绑的起点：前进时先发 high 再发 low，返回 low 的起点（量词只绑低代理）；后退时先发 low 再发 high，返回的是这两个 atom 的共同起点。
- **实现**：量化只绑最后一个单元，对齐 JS 非 u 代理对。
- **所有权 / 错误 / 调用**：`reParseTerm` / parseEscape 高码点。

### `REParseState.reEmitRange` (`src/libs/regexp.zig:3591`)

- **签名**：`fn reEmitRange(self: *REParseState, ranges: *CharRange) !void`。
- **作用**：选 class8 / not_class8 / range / range32。
- **实现**：空集 → 不可能的 `char32 0xffffffff`。非 i 且全 <128 用 16 字节位图；覆盖 `[128, sentinel)` 的补集用 `not_class8`。否则按 lastHi 选 16/32，hi 写成闭区间。
- **所有权 / 错误 / 调用**：normalize 先。

### `REParseState.reEmitClass8` (`src/libs/regexp.zig:3634`)

- **签名**：`fn reEmitClass8(self: *REParseState, op: REOPCodeEnum, bitmap: *const [class8_bitmap_len]u8) !void`。
- **作用**：opcode + 16 字节。
- **实现**：`appendSlice`。
- **所有权 / 错误 / 调用**：`bitmap` 只读借用、拷进 `self.byte_code`（`REParseState` 持有）；error set 为 `std.mem.Allocator.Error`，OOM 上抛给编译入口。调用方 `src/libs/regexp.zig:3594,3598`（`class8` / `not_class8`）。

### `REParseState.backReferenceOp` (`src/libs/regexp.zig:3639`)

- **签名**：`fn backReferenceOp(self: *const REParseState, is_backward_dir: bool) REOPCodeEnum`。
- **作用**：选四个 backref opcode 之一。
- **实现**：方向 × ignore_case。
- **所有权 / 错误 / 调用**：`\1` `\k`。

### `REParseState.emitBackReference` (`src/libs/regexp.zig:3644`)

- **签名**：`fn emitBackReference(self: *REParseState, is_backward_dir: bool, capture_indexes: []const u8) !void`。
- **作用**：`op count idx…`（同名可多个）。
- **实现**：count 0 或 >255 Unsupported。
- **所有权 / 错误 / 调用**：执行器试每个 idx 直到一段已捕获。

### `REParseState.reEmitOp` (`src/libs/regexp.zig:3650`)

- **签名**：`fn reEmitOp(self: *REParseState, op: REOPCodeEnum) !void`。
- **作用**：写一字节 opcode。
- **实现**：`opByte`。
- **所有权 / 错误 / 调用**：所有发射的底层。

### `REParseState.reEmitOpU8` (`src/libs/regexp.zig:3654`)

- **签名**：`fn reEmitOpU8(self: *REParseState, op: REOPCodeEnum, value: u8) !void`。
- **作用**：op + u8。
- **实现**：save/check_advance。
- **所有权 / 错误 / 调用**：写进 `self.byte_code`，不额外分配；推导 error set 是 `std.mem.Allocator.Error`（`append` 可能 OOM），不是无 error。调用方 `src/libs/regexp.zig:1893,1896`（外层 save 对）、`:2410,2412`（捕获组）、`:2578,3167,3641` 等 7 处。

### `REParseState.reEmitOpU16` (`src/libs/regexp.zig:3659`)

- **签名**：`fn reEmitOpU16(self: *REParseState, op: REOPCodeEnum, value: u16) !void`。
- **作用**：op + u16。
- **实现**：char、range n。
- **所有权 / 错误 / 调用**：写进 `self.byte_code`，不额外分配；error set 为 `std.mem.Allocator.Error`。调用方 `src/libs/regexp.zig:3509`（`char`/`char_i`）、`:3609,3617`（`range32`/`range` 的条数）。

### `REParseState.reEmitOpU32` (`src/libs/regexp.zig:3664`)

- **签名**：`fn reEmitOpU32(self: *REParseState, op: REOPCodeEnum, value: u32) !void`。
- **作用**：op + u32。
- **实现**：char32。
- **所有权 / 错误 / 调用**：写进 `self.byte_code`，不额外分配；error set 为 `std.mem.Allocator.Error`。调用方 `src/libs/regexp.zig:3511`（`char32`）、`:3589`（全集哨兵）、`:3672`（`reEmitOpI32` 转发）。

### `REParseState.reEmitOpU32At` (`src/libs/regexp.zig:3669`)

- **签名**：`fn reEmitOpU32At(self: *REParseState, op: REOPCodeEnum, value: u32) !usize`。
- **作用**：发射并返回立即数位置以便回填。
- **实现**：append 后返回 pos。
- **所有权 / 错误 / 调用**：split/goto/lookahead。

### `REParseState.reEmitOpI32` (`src/libs/regexp.zig:3676`)

- **签名**：`fn reEmitOpI32(self: *REParseState, op: REOPCodeEnum, value: i32) !void`。
- **作用**：有符号立即数。
- **实现**：`bitCast` 到 u32。
- **所有权 / 错误 / 调用**：搜索前缀的 split/goto。

### `REParseState.reEmitGoto` (`src/libs/regexp.zig:3680`)

- **签名**：`fn reEmitGoto(self: *REParseState, op: REOPCodeEnum, target: usize) !void`。
- **作用**：相对 `operand_end` 的偏移。
- **实现**：`destination - (pos+4)`。
- **所有权 / 错误 / 调用**：量化回跳。

### `REParseState.reEmitGotoU8` (`src/libs/regexp.zig:3689`)

- **签名**：`fn reEmitGotoU8(self: *REParseState, op: REOPCodeEnum, reg: u8, target: usize) !void`。
- **作用**：`loop`：寄存器占位 + 偏移。
- **实现**：reg 事后重写。
- **所有权 / 错误 / 调用**：`min==max`。

### `REParseState.reEmitGotoU8U32` (`src/libs/regexp.zig:3699`)

- **签名**：`fn reEmitGotoU8U32(self: *REParseState, op: REOPCodeEnum, reg: u8, limit: u32, target: usize) !void`。
- **作用**：loop_split：reg、limit、偏移。
- **实现**：10 字节定长。
- **所有权 / 错误 / 调用**：`loopSplitOp`。

### `REParseState.reInsertSaveReset` (`src/libs/regexp.zig:3710`)

- **签名**：`fn reInsertSaveReset(self: *REParseState, index: usize, first: u8, last: u8) !void`。
- **作用**：在 atom 前插入 `save_reset first last`，量化 0 次时清捕获。
- **实现**：`insertBytes(3)`。
- **所有权 / 错误 / 调用**：`need_capture_init` 或 `min==0`。

### `REParseState.appendU16` (`src/libs/regexp.zig:3717`)

- **签名**：`fn appendU16(self: *REParseState, value: u16) !void`。
- **作用**：小端两字节。
- **实现**：栈 buf。
- **所有权 / 错误 / 调用**：`buf` 是栈上临时量，真正的字节进 `self.byte_code`（`REParseState` 的 allocator 持有）；error set 为 `std.mem.Allocator.Error`（`appendSlice` OOM），不是无 error。调用方 `src/libs/regexp.zig:3623,3624`（range 端点）与 `reEmitOpU16`（:3656）。

### `REParseState.appendU32` (`src/libs/regexp.zig:3723`)

- **签名**：`fn appendU32(self: *REParseState, value: u32) !void`。
- **作用**：小端四字节。
- **实现**：栈 buf。
- **所有权 / 错误 / 调用**：同 `appendU16`：栈 buf + `self.byte_code` 追加，error set 为 `std.mem.Allocator.Error`。调用方 `src/libs/regexp.zig:3613,3614`（range32 端点）以及 `reEmitOpU32`/`reEmitGoto`/`reEmitOpU32At` 等跳转发射（:3661,3667,3681,3691,3697,3702）。

### `REParseState.insertBytes` (`src/libs/regexp.zig:3729`)

- **签名**：`fn insertBytes(self: *REParseState, index: usize, count: usize) !void`。
- **作用**：在 index 腾出 count 零字节。
- **实现**：先 append 再 `copyBackwards`。
- **所有权 / 错误 / 调用**：split/量化。

### `REParseState.moveTermToStart` (`src/libs/regexp.zig:3739`)

- **签名**：`fn moveTermToStart(self: *REParseState, start: usize, term_start: usize, term_end: usize) !void`。
- **作用**：lookbehind 把刚解析的 term 挪到 alternative 开头。
- **实现**：dupe 出 term，把它前面的 `[start, term_start)` 整块后移 `term_len`，再把 term 拷回 `start`。
- **所有权 / 错误 / 调用**：临时 dupe defer free。

## class8 与分析

### `class8Mask` (`src/libs/regexp.zig:3755`)

- **签名**：`inline fn class8Mask(byte: u8) u8`。
- **作用**：`1 << (byte&7)`。
- **实现**：一行。
- **所有权 / 错误 / 调用**：位图。

### `class8BitmapContains` (`src/libs/regexp.zig:3759`)

- **签名**：`inline fn class8BitmapContains(bitmap: [*]const u8, byte: u8) bool`。
- **作用**：测 bit。
- **实现**：`bitmap[byte>>3] & mask`。
- **所有权 / 错误 / 调用**：执行器。

### `class8CodePointMatches` (`src/libs/regexp.zig:3763`)

- **签名**：`inline fn class8CodePointMatches(bitmap: [*]const u8, code_point: u21) bool`。
- **作用**：`≥128` false。
- **实现**：再 `class8BitmapContains`。
- **所有权 / 错误 / 调用**：class8 / 贪心循环。

### `setClass8BitmapBit` (`src/libs/regexp.zig:3768`)

- **签名**：`inline fn setClass8BitmapBit(bitmap: *[class8_bitmap_len]u8, byte: u8) void`。
- **作用**：置位。
- **实现**：`|=`。
- **所有权 / 错误 / 调用**：建图。

### `buildClass8IncludedBitmap` (`src/libs/regexp.zig:3772`)

- **签名**：`fn buildClass8IncludedBitmap(ranges: *const CharRange) ?[class8_bitmap_len]u8`。
- **作用**：全部 hi≤128 才能建包含图。
- **实现**：越界 null。
- **所有权 / 错误 / 调用**：`reEmitRange`。

### `buildClass8ExcludedBitmap` (`src/libs/regexp.zig:3786`)

- **签名**：`fn buildClass8ExcludedBitmap(ranges: *const CharRange) ?[class8_bitmap_len]u8`。
- **作用**：若集合含 `[128, sentinel)`，把 **不在** 0–127 的点放进 not_class8 图。
- **实现**：先 `rangesContainTailFrom(128)`。
- **所有权 / 错误 / 调用**：`[^a]` 这类。

### `rangesContainTailFrom` (`src/libs/regexp.zig:3798`)

- **签名**：`fn rangesContainTailFrom(ranges: *const CharRange, start: u32) bool`。
- **作用**：是否有区间 `lo≤start` 且 `hi==sentinel`。
- **实现**：线性。
- **所有权 / 错误 / 调用**：补集 class8。

### `rangesContainCodePoint` (`src/libs/regexp.zig:3808`)

- **签名**：`fn rangesContainCodePoint(ranges: *const CharRange, cp: u32) bool`。
- **作用**：有序区间成员。
- **实现**：`cp < lo` 可提前 false。
- **所有权 / 错误 / 调用**：排除位图。

### `addAtomToCharRange` (`src/libs/regexp.zig:3818`)

- **签名**：`fn addAtomToCharRange(ranges: *CharRange, atom: REClassAtom, ignore_case: bool, is_unicode: bool) CompileError!void`。
- **作用**：code_point（可折叠）或吞并 owned ranges。
- **实现**：`.ranges` defer deinit 源。
- **所有权 / 错误 / 调用**：class atom。

### `addInclusiveRange` (`src/libs/regexp.zig:3834`)

- **签名**：`fn addInclusiveRange(ranges: *CharRange, lo: u21, hi_inclusive: u21) CompileError!void`。
- **作用**：闭区间转半开。
- **实现**：`hi<lo` 非法；`hi==10FFFF` 用 `+1` 到 0x110000。
- **所有权 / 错误 / 调用**：`ranges` 由调用方持有，本函数只往里追加；`CompileError` 有两支：`hi_inclusive < lo` 返回 `error.InvalidPattern`（在 `src/exec/regexp_ops.zig:569` 转成 `error.SyntaxError`），`addInterval` 的 `error.OutOfMemory` 原样上抛。调用方 `src/libs/regexp.zig:2773,2937`（`a-z` 区间）、`:3840,3841`（非 Unicode 模式的代理对拆分）等 8 处。

### `addNonUnicodeSurrogatePair` (`src/libs/regexp.zig:3843`)

- **签名**：`fn addNonUnicodeSurrogatePair(ranges: *CharRange, cp: u21) CompileError!void`。
- **作用**：非 u class 把非 BMP 加成两个代理码元。
- **实现**：高、低各一单点区间。
- **所有权 / 错误 / 调用**：`getClassAtom`。

### `addClassEscape` (`src/libs/regexp.zig:3849`)

- **签名**：`fn addClassEscape(ranges: *CharRange, escaped: u8) CompileError!void`。
- **作用**：`\d\s\w` 及大写求补。
- **实现**：digit / ECMA 空白表 / ASCII word。
- **所有权 / 错误 / 调用**：其它 escaped unreachable。

### `addUnicodeProperty` (`src/libs/regexp.zig:3872`)

- **签名**：`fn addUnicodeProperty(ranges: *CharRange, name: []const u8) CompileError!void`。
- **作用**：展开 `\p` 到 ranges。
- **实现**：`propertyRangePoints(..., inverted=false)`；InvalidProperty→InvalidPattern。
- **所有权 / 错误 / 调用**：临时 CharRange defer addSet。

### `reNeedCheckAdvAndCaptureInit` (`src/libs/regexp.zig:3888`)

- **签名**：`fn reNeedCheckAdvAndCaptureInit(code: []const u8) CompileError!AtomAnalysis`。
- **作用**：量化前分析 atom：是否可能零宽（要 check_advance）、是否有 backref（要 save_reset）。
- **实现**：扫 opcode。消费字符的 op 清 `need_check_advance`。未知/复杂 op 置 capture_init 并停。
- **所有权 / 错误 / 调用**：定长表 `opFixedSize`。

### `reComputeRegisterCount` (`src/libs/regexp.zig:3933`)

- **签名**：`fn reComputeRegisterCount(code: []u8) CompileError!u8`。
- **作用**：线性扫，给 `set_i32`/`set_char_pos`/`loop*`/`check_advance` 分配栈机寄存器并 **写回** 立即数。
- **实现**：虚拟 stack_size：`set_i32`/`set_char_pos` 各压一个并写回编号，`check_advance`/`loop`/`loop_split_*` 弹 1，`loop_check_adv_split_*` 弹 2。stack_size >255 Unsupported。
- **所有权 / 错误 / 调用**：`patchHeader`。原地改 bytecode。

### `opFixedSize` (`src/libs/regexp.zig:3982`)

- **签名**：`fn opFixedSize(op: REOPCodeEnum) ?usize`。
- **作用**：不含变长尾的固定长度；invalid null。
- **实现**：switch。range 基 3，调用方再加 n×4/8；backref 基 2 再加 count。
- **所有权 / 错误 / 调用**：分析与寄存器分配。

### `loopSplitOp` (`src/libs/regexp.zig:4000`)

- **签名**：`fn loopSplitOp(greedy: bool, need_check_advance: bool) REOPCodeEnum`。
- **作用**：选四个 loop_split 之一。
- **实现**：贪心用 goto_first。
- **所有权 / 错误 / 调用**：量化。

### `canonicalizeLiteral` (`src/libs/regexp.zig:4007`)

- **签名**：`fn canonicalizeLiteral(cp: u21, ignore_case: bool, is_unicode: bool) u21`。
- **作用**：非 i 原样。
- **实现**：`lreCanonicalize`。
- **所有权 / 错误 / 调用**：`emitCanonicalChar`。

### `opByte` (`src/libs/regexp.zig:4014`)

- **签名**：`fn opByte(op: REOPCodeEnum) u8`。
- **作用**：枚举 → 字节。
- **实现**：`@intFromEnum`。
- **所有权 / 错误 / 调用**：发射。

### `isRegexSyntax` (`src/libs/regexp.zig:4018`)

- **签名**：`fn isRegexSyntax(byte: u8) bool`。
- **作用**：pattern 里必须转义的 ASCII。
- **实现**：`^$\\.*+?()[{|`（无 `]` `}`）。
- **所有权 / 错误 / 调用**：`readPatternCodePoint`。

### `isSyntaxEscape` (`src/libs/regexp.zig:4025`)

- **签名**：`fn isSyntaxEscape(byte: u8) bool`。
- **作用**：`\X` 当作字面 X 的语法字符（含 `]` `}`）。
- **实现**：switch。
- **所有权 / 错误 / 调用**：parseEscape else、getClassAtom。

### `isUnicodeSetsReservedClassByte` (`src/libs/regexp.zig:4032`)

- **签名**：`fn isUnicodeSetsReservedClassByte(byte: u8, hyphen_is_reserved: bool) bool`。
- **作用**：`/v` class 里单独出现非法的字符。
- **实现**：`()[{}/|`；`-` 看参数。
- **所有权 / 错误 / 调用**：class 开头的 `-` 或 `]-` 不是 range 时保留。

### `isUnicodeSetsReservedDoublePunctuator` (`src/libs/regexp.zig:4040`)

- **签名**：`fn isUnicodeSetsReservedDoublePunctuator(first: u8, second: u8) bool`（文件私有）。
- **作用**：`&&` `!!` `##` … 在 `/v` class 里非法（`--` 由解析器当算子）。
- **实现**：须相等，再认一批标点（不含 `-`）。
- **所有权 / 错误 / 调用**：纯谓词、无 error；调用方只有本文件的 `reParseClassSetOperand`（:2744）与 `reParseClassAtomOrRange`（:2900），`pub` 已收窄。

### `fromHex` (`src/libs/regexp.zig:4050`)

- **签名**：`inline fn fromHex(byte: u8) ?u21`。
- **作用**：hex nibble。
- **实现**：0-9A-Fa-f。
- **所有权 / 错误 / 调用**：`\x` `\u`。

### `isDigit` (`src/libs/regexp.zig:4057`)

- **签名**：`inline fn isDigit(byte: u8) bool`。
- **作用**：`0-9`。
- **实现**：范围。
- **所有权 / 错误 / 调用**：量词、遗留八进制。

### `lreIsWordByte` (`src/libs/regexp.zig:4061`)

- **签名**：`inline fn lreIsWordByte(byte: u8) bool`。
- **作用**：`\w` ASCII：字母数字下划线。
- **实现**：ctype upper|lower|under|digit。
- **所有权 / 错误 / 调用**：word boundary；属性名扫描也用。

## 覆盖核对

- 清单函数数: 217
- 本文标题覆盖: 217
- 未覆盖: 无
