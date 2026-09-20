# 04 — temp_stream.zig：两路 resolve 的共用词汇

`resolve_variables` 与 `resolve_labels` 都在 parser 发射的紧凑临时流上工作。它们共用的三样东西放在这里：bind 索引的行类型与排序、phase-1 指令视图的解码入口、以及源码点。这个文件不做任何分析；2026-09-20 之前它叫 `cfg.zig`，还装着 Debug/ReleaseSafe 专用的精确块 CFG 与边界唯一性 oracle，那一层已整体退役（见 [compiler-contract.md](../compiler-contract.md) §5）。

## 文件级类型

- **`Error`**：`OutOfMemory` / `InvalidBytecode`。
- **`BindEntry`**：`input_offset`（临时流里的 bind 位置）+ `label_index` + `dead_skipped`（resolver 记账）。
- **`TempInstruction`**：`packed struct(u16)`：`size` + `is_temp` / `has_atom` / `has_label` 三位。
- **`SourcePoint`**：`line` + `col`，两路 resolve 用它去重源码事件。

### `bindLessThan` (`src/compiler/temp_stream.zig:25`)

- **签名**：`pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool`。
- **作用**：bind 索引的排序键：先按 `input_offset`，再按 `label_index`，所以同一位置的 alias 组连续且代表元是最小 label。
- **所有权 / 错误 / 调用**：纯比较。`resolve_variables.buildBindIndex` 的堆排序用它。

### `phase1Instruction` (`src/compiler/temp_stream.zig:43`)

- **签名**：`pub inline fn phase1Instruction( code: []const u8, atoms_ledger: []const core.atom.Atom, pc: u32, atom_index: u32, ) Error!TempInstruction`。
- **作用**：按 phase-1 视图解码一条临时流指令：temp/short 重叠区的 id 一律按 temp 形式解释。
- **实现**：`opcode.decode.headerAtPhase1` 一次查表，失败折成 `InvalidBytecode`；atom 比对既证明 phase-1 解释成立，也授权调用方直接消费对应的 ledger 项。
- **所有权 / 错误 / 调用**：不分配。`resolve_variables` 的主走查与 `skipDeadCode` 用它。

### `SourcePoint.eql` (`src/compiler/temp_stream.zig:64`)

- **签名**：`pub fn eql(self: SourcePoint, other: SourcePoint) bool`。
- **作用**：同一行列即同一源码事件。
- **所有权 / 错误 / 调用**：纯比较。两路 resolve 的源码去重用它。
