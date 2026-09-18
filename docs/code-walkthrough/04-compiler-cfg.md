# 04 — cfg.zig：精确块 CFG 与身份 oracle

绑定的 `LabelId` 把临时流切成基本块。生产图只存：块起点、每块一行元数据、平坦 CSR 边、打包可达 bitset。Debug/ReleaseSafe 再跑指令粒度 oracle，证明块/cutoff 分类与字节精确可达一致。`audit_oracles` 在 ReleaseFast 为假，计数类型变成空结构。

## 文件级类型

- **`BindEntry`**：`(input_offset, label_index, dead_skipped)`。与 S3 共用的排序绑定行。构图只读身份与输入偏移。
- **`OptimizationBoundaryKind`**：`make_ref_head/tail`、`dup_branch_fold`、`insert_tail_fold`、`gosub_empty`。
- **`DiffBucket`**：六只违规桶（`boundary_mismatch`…`source_event_mismatch`）。失败消息先报名再写坐标。
- **`OracleReport` / `FanoutCensus` / `AnchorSplitCensus`**：语料累加器；ReleaseFast comptime 抹掉。
- **`TempInstruction`**：`packed struct(u16)`：size + is_temp/has_atom/has_label。
- **`Graph` / `Block`**：`block_starts` 含 0 与 `code_len` 哨兵。`cutoff_offset` 是块内第一条无条件终结。空 gosub（目标处即 `ret`）不建边。
- **`AnchorClass` A–D**：A 必须合并；B 一 PC 多种语义事件（允许）；C 调试锚独立（允许）；D 优化替换锚（要规则）。
- **`SourcePoint`**：行/列对，S3/S4 去重用。

活性：**worklist 从入口块 0 走边**。边来自 LabelId 跳转操作数（块内第一条无条件终结之前），加上非终结块的 fallthrough。`ref_count` 从不决定活性。

---

### `DiffBucket.name` (`src/compiler/cfg.zig:59`)

- **签名**：`pub fn name(self: DiffBucket) []const u8`。
- **作用**：把六只 diff 桶打成 ruling 要求的大写名字。
- **实现**：switch 到 `BOUNDARY_MISMATCH` 等字符串。
- **所有权 / 错误 / 调用**：panic 消息与 `formatOracleReport`。无分配。

### `fanoutCensusSnapshot` (`src/compiler/cfg.zig:181`)

- **签名**：`pub fn fanoutCensusSnapshot() FanoutCensus`。
- **作用**：原子读出全局 `boundary_fanout_census` 的一份拷贝。
- **实现**：每个 u64 字段及两个 histogram 数组 `@atomicLoad(.monotonic)`。
- **所有权 / 错误 / 调用**：`formatIdentityHealth`、root `emitIdentityHealth`。

### `resetFanoutCensus` (`src/compiler/cfg.zig:263`)

- **签名**：`pub fn resetFanoutCensus() void`。
- **作用**：把 fan-out / chain-depth 计数清零。
- **实现**：对应字段 `@atomicStore(0)`。
- **所有权 / 错误 / 调用**：CFG 单测 `defer`。

### `AnchorClass.name` (`src/compiler/cfg.zig:307`)

- **签名**：`pub fn name(self: AnchorClass) []const u8`。
- **作用**：class A/B/C/D 单字母名。
- **实现**：switch `"A"`…`"D"`。
- **所有权 / 错误 / 调用**：`formatAnchorSplit` / exemplar 行。

### `AnchorCase.class` (`src/compiler/cfg.zig:351`)

- **签名**：`pub fn class(self: AnchorCase) AnchorClass`。
- **作用**：把细 case 归到 A–D。
- **实现**：两个 product-split → A；多角色/fold 尾/屏障/三业主 → B；source 共存/一方存活/全退休 → C；fold 无争或争而同意 → D。
- **所有权 / 错误 / 调用**：`anchorClassTotal`、exemplar 格式化。

### `AnchorCase.name` (`src/compiler/cfg.zig:368`)

- **签名**：`pub fn name(self: AnchorCase) []const u8`。
- **作用**：`@tagName` 作 case 标识。
- **实现**：直接 tag 名。
- **所有权 / 错误 / 调用**：split 报告 `cases{…}`。

### `recordAnchorCase` (`src/compiler/cfg.zig:434`)

- **签名**：`fn recordAnchorCase(case: AnchorCase) void`。
- **作用**：给某个 AnchorCase 计数 +1。
- **实现**：`audit_oracles` 关则返回。`censusAdd` 对应槽。
- **所有权 / 错误 / 调用**：`classifyAnchorSplits`。

### `recordAnchorExemplar` (`src/compiler/cfg.zig:444`)

- **签名**：`fn recordAnchorExemplar(exemplar: AnchorExemplar) void`。
- **作用**：每个 (case, fold_kind) 最多留 6 个不同 (line,col) 现场。
- **实现**：已见同坐标则返回；满容量或每 case 满 6 则丢。单线程编译，无排序保证。
- **所有权 / 错误 / 调用**：全局 `anchor_exemplars` 数组。root 打印。

### `resetAnchorSplitCensus` (`src/compiler/cfg.zig:458`)

- **签名**：`pub fn resetAnchorSplitCensus() void`。
- **作用**：清 split 计数并 `anchor_exemplar_len = 0`。
- **实现**：各计数 atomic store 0。`audit_oracles` 关则 no-op。
- **所有权 / 错误 / 调用**：CFG 单测。

### `anchorSplitSnapshot` (`src/compiler/cfg.zig:476`)

- **签名**：`pub fn anchorSplitSnapshot() AnchorSplitCensus`。
- **作用**：原子快照 split 累加器。
- **实现**：ReleaseFast 返回 `{}`。否则 load 全部字段与数组。
- **所有权 / 错误 / 调用**：`formatAnchorSplit`、root。

### `anchorClassTotal` (`src/compiler/cfg.zig:533`)

- **签名**：`pub fn anchorClassTotal(census: AnchorSplitCensus, class: AnchorClass) u64`。
- **作用**：把属于某一 class 的 case 计数加总。
- **实现**：inline for 枚举字段，`case.class() == class` 则累加。
- **所有权 / 错误 / 调用**：报告行 `A= B= C= D=`。

### `formatAnchorSplit` (`src/compiler/cfg.zig:550`)

- **签名**：`pub fn formatAnchorSplit(buffer: []u8, census: AnchorSplitCensus) []const u8`。
- **作用**：一行 `ZJS-V2-ANCHOR-SPLIT A=… cases{…} folds{…} relax{…} integrity{…}`。A 在前，因为只有 A 改模型。
- **实现**：`Writer.fixed`；capacity 由调用方保证，`catch unreachable`。ReleaseFast 返回 unavailable 字符串。
- **所有权 / 错误 / 调用**：root `emitAnchorSplit`，1024 字节缓冲。

### `formatAnchorExemplar` (`src/compiler/cfg.zig:597`)

- **签名**：`pub fn formatAnchorExemplar(buffer: []u8, exemplar: AnchorExemplar) []const u8`。
- **作用**：一行 exemplar：class/case/行列/op/fanout/roles/owners。
- **实现**：opcode 名来自 `opcode.nameOfPhase1`；`0xff` 当 `<end-of-code>`。other_kind 按 case 选 fold/source/label_group。
- **所有权 / 错误 / 调用**：root 每条未报告 exemplar 打一次。

### `recordRelaxCompaction` (`src/compiler/cfg.zig:637`)

- **签名**：`pub fn recordRelaxCompaction(window_sources: u64, window_labels: u64) void`。
- **作用**：记录一次 `relaxJumps` 压缩：落在被删字节严格内部的 source/label 数。
- **实现**：`relax_compactions += 1` 并累加两个窗口计数。
- **所有权 / 错误 / 调用**：仅 `.short`。S4 `relaxJumps`。

### `recordRelaxCoincidence` (`src/compiler/cfg.zig:644`)

- **签名**：`pub fn recordRelaxCoincidence(before: u64, after: u64, lost: u64, gained: u64) void`。
- **作用**：压缩前后「source 正好落在身份最终地址」的重合变化。
- **实现**：四个计数累加。
- **所有权 / 错误 / 调用**：`reportAnchorCoincidence`。

### `bindLessThan` (`src/compiler/cfg.zig:652`)

- **签名**：`pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool`。
- **作用**：BindEntry 堆排序：先 `input_offset`，再 `label_index`。
- **实现**：两级 `<`。
- **所有权 / 错误 / 调用**：`buildBindIndex`、`sort_erased.heap`。S3/CFG 共用。

### `lowerBoundBindOffset` (`src/compiler/cfg.zig:657`)

- **签名**：`fn lowerBoundBindOffset(binds: []const BindEntry, input_offset: u32) usize`。
- **作用**：第一个 `input_offset >=` 目标的下标。
- **实现**：二分。
- **所有权 / 错误 / 调用**：canonical 查询、alias 扫描。

### `upperBoundBindOffset` (`src/compiler/cfg.zig:670`)

- **签名**：`fn upperBoundBindOffset(binds: []const BindEntry, input_offset: u32) usize`。
- **作用**：第一个 `input_offset >` 目标的下标。
- **实现**：二分 `<=` 则 lo=mid+1。
- **所有权 / 错误 / 调用**：`bindInsideFold`：fold 起点之后、consumed_end 之前的 bind。

### `canonicalBoundaryIdentity` (`src/compiler/cfg.zig:699`)

- **签名**：`pub fn canonicalBoundaryIdentity(binds: []const BindEntry, label_index: u32) ?u32`。
- **作用**：一个语义边界的代表：同一输入偏移上**最低** label 下标。
- **实现**：主排序键是 offset 不是 id，所以先线性找到该 label 的 offset，再 `canonicalIdentityAtOffset`。ruling：`LabelId A != B` 可以，只要 canonical 相同；子系统对 canonical 意见不一才失败。**禁止用最终地址当分类键**。
- **所有权 / 错误 / 调用**：O(binds)。已持有槽的审计走 `canonicalIdentityAtOffset`。

### `canonicalIdentityAtOffset` (`src/compiler/cfg.zig:709`)

- **签名**：`pub fn canonicalIdentityAtOffset(binds: []const BindEntry, input_offset: u32) ?u32`。
- **作用**：给定输入偏移，返回该 alias 组第一个（最低）label。
- **实现**：`lowerBoundBindOffset`；无精确匹配则 null。
- **所有权 / 错误 / 调用**：每条引用 O(log binds)。

### `tempFromHeader` (`src/compiler/cfg.zig:723`)

- **签名**：`fn tempFromHeader(h: opcode.decode.Header) TempInstruction`。
- **作用**：把共享 decode `Header` 收成 CFG 用的 packed 行。
- **实现**：size / isLowered / hasAtom / hasLabel。
- **所有权 / 错误 / 调用**：`tempInstruction` / `phase1Instruction`。

### `tempAtomInstructionSize` (`src/compiler/cfg.zig:732`)

- **签名**：`fn tempAtomInstructionSize(op_id: u8) ?u8`。
- **作用**：临时 atom 族的紧凑宽度（scope_get_var=7，scope_make_ref=11，opt-chain field=6）。
- **实现**：switch；未知返回 null。
- **所有权 / 错误 / 调用**：编 `temp_decode_info` 表。comptime 与 decode 层互证。

### `formatHasAtom` (`src/compiler/cfg.zig:753`)

- **签名**：`fn formatHasAtom(format: opcode.Format) bool`。
- **作用**：该格式是否带 atom 操作数。
- **实现**：`.atom` / `.atom_u8` / `.atom_cache_u8` / `.atom_u16` / `.atom_label_*`。
- **所有权 / 错误 / 调用**：decode 表生成。

### `formRowIndex` (`src/compiler/cfg.zig:857`)

- **签名**：`fn formRowIndex(op_id: u8, is_temp: bool) u16`。
- **作用**：选 decode 层 form_row：临时走 `lowered_index_table`（300+），否则物理 id。
- **实现**：三元。必须与 decode 映射一致，不能自己重算 temp 算术。
- **所有权 / 错误 / 调用**：`auditInstructionOwnership` 重建 TempInstruction 位。

### `tempInstruction` (`src/compiler/cfg.zig:923`)

- **签名**：`pub fn tempInstruction( code: []const u8, atoms_ledger: []const core.atom.Atom, pc: u32, atom_index: u32, ) Error!TempInstruction`。
- **作用**：混合流解码：atom ledger 把临时 atom opcode 与重叠的最终短 opcode 分开。
- **实现**：`opcode.decode.headerAtParser`，失败变 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：CFG 回退构建、control index 校验、指令级 oracle。

### `phase1Instruction` (`src/compiler/cfg.zig:939`)

- **签名**：`pub inline fn phase1Instruction( code: []const u8, atoms_ledger: []const core.atom.Atom, pc: u32, atom_index: u32, ) Error!TempInstruction`。
- **作用**：parser 拥有的 phase-1 Builder 解码。临时 id 区间**不接受**重叠的最终短 opcode。atom 比较同时授权 S3 消费该 ledger 项。
- **实现**：`headerAtPhase1`。
- **所有权 / 错误 / 调用**：`resolve_variables` 主循环。生产路径唯一合法读者。

### `isUnconditionalTerminal` (`src/compiler/cfg.zig:950`)

- **签名**：`pub fn isUnconditionalTerminal(op_id: u8) bool`。
- **作用**：无条件终结：goto / tail_call / return / throw / ret 等。
- **实现**：switch。**不含** `if_*` / `catch` / `gosub`。
- **所有权 / 错误 / 调用**：块 cutoff、control kind、指令级 oracle 的 fallthrough。

### `isContinuationOp` (`src/compiler/cfg.zig:967`)

- **签名**：`fn isContinuationOp(op_id: u8) bool`。
- **作用**：continuation 会计种群：catch/gosub/ret/yield/await 等。
- **实现**：switch。
- **所有权 / 错误 / 调用**：oracle report `control_continuations`。

### `labelOperandOffset` (`src/compiler/cfg.zig:985`)

- **签名**：`fn labelOperandOffset(instruction: TempInstruction) ?u32`。
- **作用**：标签操作数相对 opcode 的偏移：有 atom 则 5，否则 1。
- **实现**：decode 层证明所有 label 操作数都在 `1 + (hasAtom ? 4 : 0)`。
- **所有权 / 错误 / 调用**：边收集、oracle。

### `validateAndAdvanceAtom` (`src/compiler/cfg.zig:992`)

- **签名**：`fn validateAndAdvanceAtom( input: *const builder.Builder, pc: u32, instruction: TempInstruction, atom_index: *u32, ) Error!void`。
- **作用**：有 atom 则核对编码 u32 与 ledger，并前进游标。
- **实现**：越界或不相等 → `InvalidBytecode`。
- **所有权 / 错误 / 调用**：CFG 解码环。不转移所有权。

### `readLabelIndex` (`src/compiler/cfg.zig:1007`)

- **签名**：`fn readLabelIndex( input: *const builder.Builder, pc: u32, instruction: TempInstruction, operand_offset: u32, ) Error!u32`。
- **作用**：从临时流读 LE LabelId 并检查落在 `label_len` 内。
- **实现**：边界加法溢出 fail-closed。
- **所有权 / 错误 / 调用**：边与 oracle。

### `labelTargetOffset` (`src/compiler/cfg.zig:1025`)

- **签名**：`fn labelTargetOffset(input: *const builder.Builder, label_index: u32) Error!u32`。
- **作用**：已绑定标签的临时流目标偏移。
- **实现**：未绑定 / unbound / 超出 code_len → 失败。
- **所有权 / 错误 / 调用**：每条创建标签必须已绑定，这是构图前置。

### `isEmptyGosub` (`src/compiler/cfg.zig:1036`)

- **签名**：`fn isEmptyGosub(input: *const builder.Builder, op_id: u8, target_offset: u32) bool`。
- **作用**：gosub 目标处就是 `ret` → 空 finally，不建边（S3 会删这条 gosub）。
- **实现**：`op_id == gosub && code[target] == ret`。
- **所有权 / 错误 / 调用**：indexed 与 decode 两条构图路径。

### `Graph.deinit` (`src/compiler/cfg.zig:1060`)

- **签名**：`pub fn deinit(self: *Graph) void`。
- **作用**：释放四张 backing 并清空。
- **实现**：`block_starts` / `blocks` / `edge_storage` / `reachable_words`。
- **所有权 / 错误 / 调用**：S3 `defer graph.deinit()`（仅 audit 构建图时）。

### `Graph.edgesForBlock` (`src/compiler/cfg.zig:1073`)

- **签名**：`pub fn edgesForBlock(self: *const Graph, block_index: usize) []const usize`。
- **作用**：CSR 切片：该块的后继块下标。
- **实现**：`edge_storage[edge_start..edge_end]`，带断言。
- **所有权 / 错误 / 调用**：worklist 可达、oracle。

### `Graph.isReachable` (`src/compiler/cfg.zig:1081`)

- **签名**：`pub fn isReachable(self: *const Graph, block_index: usize) bool`。
- **作用**：入口可达性。
- **实现**：`bitIsSet(reachable_words, block_index)`。
- **所有权 / 错误 / 调用**：S3 死代码、eval 捕获预扫描。

### `bitWordCount` (`src/compiler/cfg.zig:1089`)

- **签名**：`fn bitWordCount(bit_count: usize) Error!usize`。
- **作用**：bitset 需要多少个 `usize` 字。
- **实现**：向上取整；加法溢出 → OOM。
- **所有权 / 错误 / 调用**：图与 oracle 分配。

### `bitIsSet` (`src/compiler/cfg.zig:1095`)

- **签名**：`fn bitIsSet(words: []const usize, bit_index: usize) bool`。
- **作用**：读一位。
- **实现**：字内移位。
- **所有权 / 错误 / 调用**：不分配、无 error set，也**不做边界检查**：`bit_index` 越界就是 slice 越界 panic，位图长度由 `bitWordCount`（`src/compiler/cfg.zig:1089`）在分配点保证。位图内存归 `Graph`（`Graph.deinit` 在 `src/compiler/cfg.zig:1060` 释放 `reachable_words`）或归临时 scratch。调用方十余处，主要是可达性传播（`src/compiler/cfg.zig:1363`、`:1519`）、活跃度（`:1547`、`:1642`）与 offset 分类普查（`:2205`、`:2217`）。

### `setBit` (`src/compiler/cfg.zig:1100`)

- **签名**：`fn setBit(words: []usize, bit_index: usize) void`。
- **作用**：置一位。
- **实现**：`|=`。
- **所有权 / 错误 / 调用**：同 `bitIsSet`：`[]usize` 借用参数，函数不拥有也不释放，不分配、无 error set、不做边界检查。调用方与读侧成对：`src/compiler/cfg.zig:1358`/`:1365`、`:1514`/`:1521`、`:2206`/`:2718` 等。

### `findBlockStart` (`src/compiler/cfg.zig:1105`)

- **签名**：`fn findBlockStart(block_starts: []const u32, target_offset: u32) ?usize`。
- **作用**：精确匹配块起点下标。
- **实现**：二分；找不到 null。
- **所有权 / 错误 / 调用**：跳转目标必须落在某个 bind/入口/末尾哨兵。

### `appendEdge` (`src/compiler/cfg.zig:1119`)

- **签名**：`fn appendEdge(graph: *Graph, target_block: usize) Error!void`。
- **作用**：CSR 追加一条边。容量在构图前按 `reloc_len + block_count-1` 预留。
- **实现**：满则 `InvalidBytecode`（容量估错即流损坏）。
- **所有权 / 错误 / 调用**：跳转边与 fallthrough。

### `validateBindIndex` (`src/compiler/cfg.zig:1125`)

- **签名**：`fn validateBindIndex(input: *const builder.Builder, binds: []const BindEntry) Error!void`。
- **作用**：binds 必须覆盖每个 bound 槽，按 (offset, label_index) 严格递增，且 offset 等于槽的 `bound_offset`。
- **实现**：计数 + 单调扫描。
- **所有权 / 错误 / 调用**：`build` 入口；同时证明 `canonicalBoundaryIdentity` 与 `canonicalIdentityAtOffset` 一致。

### `indexedControlKind` (`src/compiler/cfg.zig:1151`)

- **签名**：`fn indexedControlKind(op_id: u8) ?builder.ControlKind`。
- **作用**：哪些 opcode 该进稀疏控制索引：eval/apply_eval → direct_eval；非 goto 的无条件终结 → terminal。
- **实现**：goto 有 reloc，不进 control 表。
- **所有权 / 错误 / 调用**：`validateControlIndex`。

### `validateControlIndex` (`src/compiler/cfg.zig:1160`)

- **签名**：`fn validateControlIndex(input: *const builder.Builder) Error!void`。
- **作用**：Debug/ReleaseSafe：稀疏索引必须正好是全解码会找到的非 reloc 控制事件。
- **实现**：走 `tempInstruction`，遇 indexed kind 则与 `controlAt` 比 offset/kind。结束时 pc/atom/control 游标必须耗尽。
- **所有权 / 错误 / 调用**：ReleaseFast 信任索引，不再跑这遍。

### `relocOpcodeOffset` (`src/compiler/cfg.zig:1189`)

- **签名**：`fn relocOpcodeOffset( input: *const builder.Builder, entry: labels.RelocEntry, ) Error!u32`。
- **作用**：从操作数偏移回到 opcode：jump32 减 1，aux32 减 5。
- **实现**：下溢或越过 code_len 失败。
- **所有权 / 错误 / 调用**：indexed 构图按 opcode 偏移与 control 事件归并。

### `indexedRelocOpcodeValid` (`src/compiler/cfg.zig:1205`)

- **签名**：`fn indexedRelocOpcodeValid(op_id: u8, kind: labels.RelocKind) bool`。
- **作用**：reloc 种类与 opcode 是否匹配。
- **实现**：jump32 ∈ {if_false, if_true, goto, catch, gosub}；aux32 ∈ scope_make_ref 或 atom_label 格式。
- **所有权 / 错误 / 调用**：indexed 构图 fail-closed。

### `buildFromControlIndex` (`src/compiler/cfg.zig:1220`)

- **签名**：`fn buildFromControlIndex( memory: *core.memory.MemoryAccount, input: *const builder.Builder, binds: []const BindEntry, ) Error!Graph`。
- **作用**：生产构图：绑定标签切块，RelocEntry 给显式边，稀疏 control 只补 terminal/eval。普通指令不必解码。
- **实现**：去重后的 bind 偏移 + 0 + code_len 成 `block_starts`。每块归并 reloc/control 事件：direct_eval 置 `has_eval_instruction`；第一条 terminal 记 cutoff；合法 reloc 在未 cutoff 且非空 gosub 时加边；goto 同时当 terminal。无 terminal 则 fallthrough 下一块。最后 worklist 从 0 标可达。
- **所有权 / 错误 / 调用**：`errdefer graph.deinit`。worklist 用完即 free。

### `build` (`src/compiler/cfg.zig:1374`)

- **签名**：`pub fn build( memory: *core.memory.MemoryAccount, input: *const builder.Builder, binds: []const BindEntry, ) Error!Graph`。
- **作用**：从只读 Builder 建精确块 CFG。
- **实现**：校验 slice 长度与 bind 索引。有 control index：audit 时先 `validateControlIndex`，再 `buildFromControlIndex`。否则全解码：`tempInstruction` 走每条指令，收集 label 边、terminal cutoff、eval 标志，worklist 同样从 0。
- **所有权 / 错误 / 调用**：S3 仅在 `audit_oracles` 下构建并 `auditInstructionOwnership`。ReleaseFast 生产路径 **不** 建图——S3 用 bind 侧表 + ref_count 透明性走死代码（见 `deadBoundaryAt` 非 oracle 臂）。

### `enqueueAuditOffset` (`src/compiler/cfg.zig:1534`)

- **签名**：`fn enqueueAuditOffset( nodes: []const AuditInstruction, live_words: []usize, worklist: []u32, worklist_len: *usize, target: u32, ) Error!void`。
- **作用**：指令级 oracle：把一个指令起点（或 code_len 哨兵）标活并入队。
- **实现**：目标必须是指令起点（size!=0，除非正是哨兵）。已活则返回。
- **所有权 / 错误 / 调用**：`auditInstructionOwnership` worklist。

### `auditInstructionOwnership` (`src/compiler/cfg.zig:1557`)

- **签名**：`pub fn auditInstructionOwnership( memory: *core.memory.MemoryAccount, input: *const builder.Builder, graph: *const Graph, ) Error!void`。
- **作用**：Debug/ReleaseSafe 证明义务：指令粒度可达 ≡ 块可达 ∧ 第一条终结之前。
- **实现**：先填每 pc 的 size/is_temp。从 0 走：有 label 则入队目标（空 gosub 除外），非 goto 再入队 next；无 label 且非无条件终结则入队 next。再扫每条指令，与 `graph.isReachable && pc <= cutoff` 比较，分歧则 `OWNERSHIP_MISMATCH` panic。
- **所有权 / 错误 / 调用**：ReleaseFast 不引用。scratch 三块 alloc + defer free。

### `validateBoundaryAuditInput` (`src/compiler/cfg.zig:1663`)

- **签名**：`fn validateBoundaryAuditInput( input: *const builder.Builder, graph: *const Graph, binds: []const BindEntry, product_labels: []const labels.LabelSlot, ) Error!void`。
- **作用**：边界唯一性审计的前置：slice 一致、binds 合法、source 单调、图以 0 开头以 code_len 结尾且起点递增。
- **实现**：失败 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：`auditBoundaryUniqueness` 入口。

### `resolveDivergenceOrigin` (`src/compiler/cfg.zig:1706`)

- **签名**：`fn resolveDivergenceOrigin( input: *const builder.Builder, graph: *const Graph, binds: []const BindEntry, pc: u32, ) Error!DivergenceOrigin`。
- **作用**：给违规点找最近块、块起点标签、最近 source，供 panic 引用「真实构造」。
- **实现**：二分块起点（`<= pc` 的最后一块），该起点的 bind，source 上界。
- **所有权 / 错误 / 调用**：`boundaryViolation`。

### `formatDivergenceOrigin` (`src/compiler/cfg.zig:1754`)

- **签名**：`fn formatDivergenceOrigin(buffer: []u8, origin: DivergenceOrigin) []const u8`。
- **作用**：`block=N label=… source=…` 片段。
- **实现**：四臂：有无 label × 有无 source。
- **所有权 / 错误 / 调用**：panic 消息尾。

### `writeReportIdentity` (`src/compiler/cfg.zig:1798`)

- **签名**：`fn writeReportIdentity(writer: *std.Io.Writer, identity: ReportIdentity) void`。
- **作用**：写 `kind#index@offset` 或 `kind@offset`。
- **实现**：`index` 可选。
- **所有权 / 错误 / 调用**：`panicBoundaryUniquenessViolation`。

### `panicBoundaryUniquenessViolation` (`src/compiler/cfg.zig:1807`)

- **签名**：`fn panicBoundaryUniquenessViolation( bucket: DiffBucket, category: []const u8, role: BoundaryRole, op_id: u8, semantic_key: []const u8, identities: [2]ReportIdentity, origin: DivergenceOrigin, ) noreturn`。
- **作用**：先 `recordDiffBucket` 再 panic。消息以 bucket 名为先，不以偏移为主键。
- **实现**：拼 2048 字节消息。
- **所有权 / 错误 / 调用**：所有边界违规出口。

### `boundaryViolation` (`src/compiler/cfg.zig:1833`)

- **签名**：`fn boundaryViolation( bucket: DiffBucket, input: *const builder.Builder, graph: *const Graph, binds: []const BindEntry, category: []const u8, role: BoundaryRole, construct_offset: u32, semantic_key: []const u8, identities: [2]ReportIdentity, ) Error!void`。
- **作用**：解析 origin 后 noreturn panic。返回类型是 Error 以便 `try` 链，实际不会返回。
- **实现**：offset 处 opcode，越界用 `0xff`。
- **所有权 / 错误 / 调用**：`auditBoundaryUniqueness` 各检查臂。

### `aliasGroupSplit` (`src/compiler/cfg.zig:1868`)

- **签名**：`fn aliasGroupSplit( group: []const BindEntry, product_labels: []const labels.LabelSlot, ) ?AliasGroupSplit`。
- **作用**：同一输入偏移的幸存身份若产物偏移不同 → 分裂。
- **实现**：扫 bound 槽，第二个不同 `bound_offset` 即返回。
- **所有权 / 错误 / 调用**：审计每组；null 表示一致或全退休。

### `duplicateReplacementOwner` (`src/compiler/cfg.zig:1900`)

- **签名**：`fn duplicateReplacementOwner( opt_bounds: []const OptimizationBoundary, ) ?DuplicateReplacementOwner`。
- **作用**：两个 fold 声称同一 `replacement_start`。
- **实现**：要求已按 replacement_start 排序；相邻相等即命中。
- **所有权 / 错误 / 调用**：审计。

### `optimizationBoundaryLessThan` (`src/compiler/cfg.zig:1913`)

- **签名**：`fn optimizationBoundaryLessThan( _: void, lhs: OptimizationBoundary, rhs: OptimizationBoundary, ) bool`。
- **作用**：fold 边界排序：replacement_start、fold_start、consumed_end、kind。
- **实现**：四级 `<`。
- **所有权 / 错误 / 调用**：审计前 `sort_erased.heap`。

### `bindInsideFold` (`src/compiler/cfg.zig:1930`)

- **签名**：`fn bindInsideFold( binds: []const BindEntry, boundary: OptimizationBoundary, ) ?BindInsideFold`。
- **作用**：fold 消耗区间内部（严格在 fold_start 之后、consumed_end 之前）若还有 bind → 非法。
- **实现**：`upperBoundBindOffset(fold_start)`。
- **所有权 / 错误 / 调用**：peephole 不得把标签包进被删跨度。

### `referenceToRetiredAlias` (`src/compiler/cfg.zig:1950`)

- **签名**：`fn referenceToRetiredAlias( binds: []const BindEntry, product_labels: []const labels.LabelSlot, label_index: u32, input_offset: u32, ) ?RetiredAliasSplit`。
- **作用**：活引用点名一个已退休的 alias，而同边界还有幸存兄弟 → 分裂。
- **实现**：该 label 未 bound；同 offset 找 bound 兄弟。调用方给 `input_offset` 以免 O(binds) 扫。
- **所有权 / 错误 / 调用**：引用走审计。

### `survivingSibling` (`src/compiler/cfg.zig:1977`)

- **签名**：`fn survivingSibling( group: []const BindEntry, product_labels: []const labels.LabelSlot, label_index: u32, ) ?u32`。
- **作用**：同组里另一个仍 bound 的身份。
- **实现**：线性扫。
- **所有权 / 错误 / 调用**：退休身份仍带 ref 时的违规消息。

### `isInstructionStart` (`src/compiler/cfg.zig:1993`)

- **签名**：`fn isInstructionStart(starts_words: []const usize, code_len: u32, offset: u32) bool`。
- **作用**：offset 是否指令起点或 code_len 哨兵。
- **实现**：bitset。
- **所有权 / 错误 / 调用**：claim 解析。

### `blockContainingOffset` (`src/compiler/cfg.zig:1997`)

- **签名**：`fn blockContainingOffset(graph: *const Graph, offset: u32) ?usize`。
- **作用**：包含该偏移的块（起点 `<= offset` 的最后一块）。
- **实现**：二分。
- **所有权 / 错误 / 调用**：引用指令是否 live。

### `referencingInstructionIsLive` (`src/compiler/cfg.zig:2013`)

- **签名**：`fn referencingInstructionIsLive(graph: *const Graph, pc: u32) Error!bool`。
- **作用**：发出该引用的指令是否在 cutoff 前的可达块里。
- **实现**：`isReachable && (!has_terminal || pc <= cutoff)`。
- **所有权 / 错误 / 调用**：审计活引用。

### `roleForLabelOperand` (`src/compiler/cfg.zig:2022`)

- **签名**：`fn roleForLabelOperand(op_id: u8, instruction: TempInstruction) BoundaryRole`。
- **作用**：按 opcode 给引用角色：catch→exception_landing，gosub→cleanup_subroutine，scope_make_ref/atom_label→aux，其余 jump_target。
- **实现**：switch + format。
- **所有权 / 错误 / 调用**：role_mask 并入边界，供 class B 多角色。

### `referenceChainDepth` (`src/compiler/cfg.zig:2053`)

- **签名**：`fn referenceChainDepth( binds: []const BindEntry, product_labels: []const labels.LabelSlot, label_index: u32, input_offset: u32, ) u32`。
- **作用**：一条标签引用从操作数到语义边界的 hop 数：operand→LabelId（1），非 canonical 再 +1，+1 到 bound offset，S3 保留该边界再 +1 到产物偏移。
- **实现**：不扫 binds 找行（调用方给 offset），O(log) 取 canonical。
- **所有权 / 错误 / 调用**：fan-out census。S4 另计 `final_address_hops`，不混进这张直方图。

### `censusAdd` (`src/compiler/cfg.zig:2077`)

- **签名**：`fn censusAdd(counter: *u64, amount: u64) void`。
- **作用**：单调原子加。
- **实现**：`@atomicRmw(.Add)`。
- **所有权 / 错误 / 调用**：所有 census。

### `reportAdd` (`src/compiler/cfg.zig:2081`)

- **签名**：`fn reportAdd(comptime field: []const u8, amount: u64) void`。
- **作用**：给 `oracle_report` 的具名字段加。
- **实现**：`censusAdd(&@field(oracle_report, field))`。ReleaseFast no-op。
- **所有权 / 错误 / 调用**：claim 会计。

### `recordDiffBucket` (`src/compiler/cfg.zig:2086`)

- **签名**：`pub fn recordDiffBucket(bucket: DiffBucket) void`。
- **作用**：六只桶之一 +1。
- **实现**：`buckets[@intFromEnum]`。
- **所有权 / 错误 / 调用**：每次 oracle panic 之前。

### `oracleReportSnapshot` (`src/compiler/cfg.zig:2091`)

- **签名**：`pub fn oracleReportSnapshot() OracleReport`。
- **作用**：原子快照 oracle 报告。
- **实现**：逐字段 load。ReleaseFast `{}`。
- **所有权 / 错误 / 调用**：`formatOracleReport`。

### `resetOracleReport` (`src/compiler/cfg.zig:2137`)

- **签名**：`pub fn resetOracleReport() void`。
- **作用**：清全部 oracle 计数。
- **实现**：atomic store 0。
- **所有权 / 错误 / 调用**：CFG 单测。

### `BoundaryReportAccounting.claim` (`src/compiler/cfg.zig:2193`)

- **签名**：`fn claim( self: *@This(), category: BoundaryClaimCategory, offset: u32, binds: []const BindEntry, starts_words: []const usize, code_len: u32, ) void`。
- **作用**：记一次「遗留边界声称」：分类计数、每类 distinct offset、缺锚 missing、builder distinct。
- **实现**：instruction 类不置 semantic bit。resolved = 指令起点或该偏移有 canonical 身份。
- **所有权 / 错误 / 调用**：仅 `audit_oracles` 下该类型有存储。

### `censusMax` (`src/compiler/cfg.zig:2224`)

- **签名**：`fn censusMax(counter: *u64, value: u64) void`。
- **作用**：原子 max。
- **实现**：`@atomicRmw(.Max)`。
- **所有权 / 错误 / 调用**：max_fanout / max_chain_depth。

### `recordFanout` (`src/compiler/cfg.zig:2228`)

- **签名**：`fn recordFanout(group_len: usize) void`。
- **作用**：一个语义边界：identities += fanout，>1 则 coalesced，histogram 桶 i 计 fanout=i+1（末桶 ≥8）。
- **实现**：断言 group_len≠0。
- **所有权 / 错误 / 调用**：每组 binds。

### `recordChainDepth` (`src/compiler/cfg.zig:2239`)

- **签名**：`fn recordChainDepth(depth: u32) void`。
- **作用**：一条引用的 hop 直方图。
- **实现**：samples/total/max + 桶。
- **所有权 / 错误 / 调用**：每个活标签操作数。

### `recordFinalSourceCensus` (`src/compiler/cfg.zig:2250`)

- **签名**：`pub fn recordFinalSourceCensus(total: u64, on_identity: u64, between_identities: u64) void`。
- **作用**：S4 最终源事件：落在身份地址 vs 落在身份之间。
- **实现**：断言 total = 二者之和。
- **所有权 / 错误 / 调用**：`auditFinalBoundaryIdentity`。

### `recordFinalBoundaryHops` (`src/compiler/cfg.zig:2262`)

- **签名**：`pub fn recordFinalBoundaryHops(group_count: u64) void`。
- **作用**：每个活的产物坐标 alias 组恰好一条 `boundary → final address`。
- **实现**：不折进 chain-depth 直方图，以免把均值拉低。
- **所有权 / 错误 / 调用**：S4 审计。

### `fixedPointHundred` (`src/compiler/cfg.zig:2267`)

- **签名**：`fn fixedPointHundred(total: u64, count: u64) u64`。
- **作用**：均值 ×100 的定点。
- **实现**：count=0 → 0；`total*100/count`。
- **所有权 / 错误 / 调用**：health 行 mean。

### `histogramP95Index` (`src/compiler/cfg.zig:2273`)

- **签名**：`fn histogramP95Index(buckets: [8]u64) ?usize`。
- **作用**：累计达到 95% 的桶下标。
- **实现**：空则 null。
- **所有权 / 错误 / 调用**：`writeHistogramP95`。

### `writeHistogramP95` (`src/compiler/cfg.zig:2286`)

- **签名**：`fn writeHistogramP95( writer: *std.Io.Writer, buckets: [8]u64, base_one: bool, ) void`。
- **作用**：打印 p95：末桶 `8+`，否则下标（fan-out 桶 base_one 所以值=index+1）。
- **实现**：无样本打 `0`。
- **所有权 / 错误 / 调用**：health 行。

### `formatIdentityHealth` (`src/compiler/cfg.zig:2313`)

- **签名**：`pub fn formatIdentityHealth(buffer: []u8, census: FanoutCensus) []const u8`。
- **作用**：一行 identity kinds/fan-out/chain/final-source/unanchored。
- **实现**：mean 用定点百倍。`chain` 是输入坐标引用；`+final-hop` 是 S4 每组一条。
- **所有权 / 错误 / 调用**：root，512 字节缓冲。

### `formatOracleReport` (`src/compiler/cfg.zig:2351`)

- **签名**：`pub fn formatOracleReport(buffer: []u8, report: OracleReport) []const u8`。
- **作用**：ruling 报告块：Summary 再 Diff buckets。从不打裸 `PASS`，从不以指令偏移当键。
- **实现**：atom 平衡 = unbalanced==0 且 create==transfer+release。ReleaseFast unavailable 字符串。
- **所有权 / 错误 / 调用**：`compiler.formatOracleReport`。

### `boundaryProductOffset` (`src/compiler/cfg.zig:2412`)

- **签名**：`fn boundaryProductOffset( binds: []const BindEntry, product_labels: []const labels.LabelSlot, input_offset: u32, ) ?u32`。
- **作用**：该输入边界解析到的产物偏移：组内第一个仍 bound 的身份。`aliasGroupSplit` 已证幸存者一致。全退休则 null。
- **实现**：从 lowerBound 扫。
- **所有权 / 错误 / 调用**：class A 的 product 比较。

### `boundaryFirstLabel` (`src/compiler/cfg.zig:2427`)

- **签名**：`fn boundaryFirstLabel(binds: []const BindEntry, input_offset: u32) u32`。
- **作用**：该偏移第一标签，没有则 `unbound`。
- **实现**：lowerBound 精确匹配。
- **所有权 / 错误 / 调用**：exemplar `label_index`。

### `nearestSourceSite` (`src/compiler/cfg.zig:2442`)

- **签名**：`fn nearestSourceSite(sources: []const builder.SourceSlot, offset: u32) SourceSite`。
- **作用**：`temp_offset <= offset` 的最后一条 parser marker，给无自身 marker 的边界引用源。
- **实现**：二分上界 −1。
- **所有权 / 错误 / 调用**：exemplar 行列。

### `opAt` (`src/compiler/cfg.zig:2454`)

- **签名**：`fn opAt(input: *const builder.Builder, offset: u32) u8`。
- **作用**：该偏移 opcode，越界 `0xff`。
- **实现**：三元。
- **所有权 / 错误 / 调用**：exemplar `op_id`。

### `classifyAnchorSplits` (`src/compiler/cfg.zig:2471`)

- **签名**：`fn classifyAnchorSplits( input: *const builder.Builder, binds: []const BindEntry, product_labels: []const labels.LabelSlot, product_sources: []const builder.SourceSlot, opt_bounds: []const OptimizationBoundary, role_masks: []const u8, ) void`。
- **作用**：F3：每个争用/无锚位置归入 A–D，而不是只计数。可证伪臂是**产物偏移比较**。
- **实现**：种群 S：绑定位上的 source，用 product slot i ≡ input slot i（行列对齐计数违规）。比较 attached vs `boundaryProductOffset` → C 四臂或 A split。种群 F：fold replacement，无标签则 D uncontested；同意则 D contested_agree；分开则 A fold split。再扫多角色、fold 区尾、屏障、三业主 → B。
- **所有权 / 错误 / 调用**：`auditBoundaryUniqueness` 引用走完之后（role_mask 已齐）。

### `hasSourceEventAt` (`src/compiler/cfg.zig:2648`)

- **签名**：`fn hasSourceEventAt(sources: []const builder.SourceSlot, offset: u32) bool`。
- **作用**：该偏移是否有 source 槽。
- **实现**：二分精确匹配。
- **所有权 / 错误 / 调用**：三业主 B。

### `boundaryFanoutAt` (`src/compiler/cfg.zig:2658`)

- **签名**：`fn boundaryFanoutAt(binds: []const BindEntry, input_offset: u32) u32`。
- **作用**：该偏移身份个数。
- **实现**：从 lowerBound 计数。
- **所有权 / 错误 / 调用**：exemplar fanout。

### `boundaryRoleMask` (`src/compiler/cfg.zig:2667`)

- **签名**：`fn boundaryRoleMask( binds: []const BindEntry, role_masks: []const u8, input_offset: u32, ) u8`。
- **作用**：该边界所有身份的角色位或。
- **实现**：扫组。
- **所有权 / 错误 / 调用**：class B 多角色、exemplar。

### `auditBoundaryUniqueness` (`src/compiler/cfg.zig:2683`)

- **签名**：`pub fn auditBoundaryUniqueness( memory: *core.memory.MemoryAccount, input: *const builder.Builder, graph: *const Graph, binds: []const BindEntry, product_labels: []const labels.LabelSlot, product_sources: []const builder.SourceSlot, opt_bounds: []const OptimizationBoundary, ) Error!void`。
- **作用**：Debug/ReleaseSafe 输入坐标证明：一个语义边界可以有同偏移 alias，但 resolver 与每条活引用必须保留一个稳定 canonical。
- **实现**：校验输入；bitset 标指令起点。每组：`recordFanout`；`aliasGroupSplit` 失败则 BOUNDARY_MISMATCH；退休身份仍有 ref/reloc → BINDING_MISMATCH，可达块上退休的 `match_barrier` 也 BINDING_MISMATCH。bind / source / fold 三点都必须是指令起点（否则 BOUNDARY_MISMATCH / SOURCE_EVENT_MISMATCH），fold 区间须 `fold_start <= replacement_start <= consumed_end <= code_len`。fold：排序后重复 `replacement_start`、bind 落在消耗区间内部。活引用走一遍指令流：`recordChainDepth`、目标无 bound 身份 → BINDING_MISMATCH（`jump_target_identity_unbound`）、活引用指向已退休 alias 且同边界有幸存兄弟 → BINDING_MISMATCH；同时做 BoundaryReportAccounting claim（instruction/control_flow/optimization/debug）与 atom 所有权 transfer/release 记账。最后 `classifyAnchorSplits`。
- **所有权 / 错误 / 调用**：S3 `run` 成功走完后。scratch bitset defer free。

### `AnchorSplitFixture.init` (`src/compiler/cfg.zig:3414`)

- **签名**：`fn init(self: *AnchorSplitFixture) !void`。
- **作用**：分类测试夹具：if_false 跳到偏移 6 的绑定，带 source marker。
- **实现**：建 runtime、builder、一条条件跳 + return_undef + bind + marker + return_undef，`cfg.build`。
- **所有权 / 错误 / 调用**：测试必须 `defer deinit`。

### `AnchorSplitFixture.deinit` (`src/compiler/cfg.zig:3432`)

- **签名**：`fn deinit(self: *AnchorSplitFixture) void`。
- **作用**：释放图、builder、runtime。
- **实现**：反向所有权顺序。
- **所有权 / 错误 / 调用**：测试夹具的释放序，按 `init`（`src/compiler/cfg.zig:3414`）的反序走：先 `graph.deinit()` 把四块 `memory.free`（`src/compiler/cfg.zig:1060`）还给 runtime 的 memory 账户，再 `input.deinit()` 还 builder 缓冲，最后 `rt.destroy()` 关掉持有该账户的 runtime——顺序不能反，否则账户先没了。`void`、不返回错误；调用方是两条 anchor-split 测试的 `defer`（`src/compiler/cfg.zig:3452`、`:3507`）。

### `AnchorSplitFixture.boundary` (`src/compiler/cfg.zig:3438`)

- **签名**：`fn boundary(self: *const AnchorSplitFixture) u32`。
- **作用**：夹具唯一绑定的输入偏移。
- **实现**：`binds[0].input_offset`。
- **所有权 / 错误 / 调用**：class A 测试把 source/fold 的产物偏移故意写偏。

### `SourcePoint.eql` (`src/compiler/cfg.zig:3804`)

- **签名**：`pub fn eql(self: SourcePoint, other: SourcePoint) bool`。
- **作用**：行/列都相等才算同一源点。
- **实现**：`line` 与 `col` 比较。
- **所有权 / 错误 / 调用**：S3 同偏移多 marker 去重、S4 `attachSource` 连续相等坐标去重。

---

## 覆盖核对

- 清单函数数: 96
- 本文标题覆盖: 96
- 未覆盖: 无
