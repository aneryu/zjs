# 05 — 字节码载体

本册讲 `src/bytecode.zig` 与 `src/opcode_logical.zig`：编译期 `FunctionDef` / `Bytecode` 如何收成 GC 管理的 `FunctionBytecode`，以及 opcode 表、栈深、pc2line、finalize。VM 怎么解释这些字节是 11–12 册的事。

权威仍是源码与 ECMA-262。QuickJS 是对照（`quickjs.c` 行号写在注释里）；与 spec 冲突时跟 spec。

## 怎么拆

| 文件 | 内容 |
| --- | --- |
| [05-bytecode.md](05-bytecode.md) | 本页：总图、`Format`/`constant`/`debug`/`module`、CompileContext、dump |
| [05-bytecode-opcodes.md](05-bytecode-opcodes.md) | opcode 元数据、编解码、`opcode_logical.zig` |
| [05-bytecode-function.md](05-bytecode-function.md) | 运行时 `FunctionBytecode`：88 字节核心头、packed FAM、debug 尾、call-facts 尾 |
| [05-bytecode-function-def.md](05-bytecode-function-def.md) | 编译期 `FunctionDef` 与可变 `Bytecode`、`LegacyExecutionAdapter` |
| [05-bytecode-pipeline.md](05-bytecode-pipeline.md) | pc2line、stack-size、finalize / packing |
| [05-bytecode-binding.md](05-bytecode-binding.md) | `binding_rules`：resolve_variables 的规则库 |

## 一次 eval 里它站在哪

```
parser.zig 发射 phase-1 流（temp opcode 占用 178..196）
    → compiler/builder + resolve_variables（binding_rules）+ resolve_labels（short layout）
    → pipeline_finalize.createFunctionBytecode
         子函数递归 → v2 lowering → FunctionLayout → production shell
         → stack_size.compute → pc2line.encode → publishExecutionFlags → GC 发布
    → exec/zjs_vm 跑 FunctionBytecode.byteCode()
```

生产配置 `compiler=v2,layout=short`。`plain` 只是 A/B 诊断。

## 文件级类型（本页相关）

### `opcode.Format` / `format.Operand`

操作数格式标签，对齐 `quickjs-opcode.h` 的 `FMT()`。zjs 多两个：`npop_u8`（`argc:u16` + `cache_idx:u8`，调用族）与 `atom_cache_u8`（`atom:u32` + `cache_idx:u8`，W1 属性站点）。`src/opcode_logical.zig` 有一份字段对字段相同的 `Format`；`bytecode.zig` comptime 断言两者一致。

`format` 命名空间是诊断视图（把 Format 映成 `u8`/`atom`/`label` 列表），生产路径用 `opcode.decode` 的 `OperandLayout`。

### `constant.Pool`

编译期常量池：`[]JSValue` + MemoryAccount。精确 `len+1` 增长。未发布的 BigInt 仍可能是 reserved，deinit 走 `BigInt.destroyIfReservedValue`。

### `debug.Table` / `SourcePosition`

可变 Bytecode 上的 (pc, line, column) 表，filename 是 atom。最终产物不保留这张表，而是编成 pc2line 缓冲放进 `DebugInfo`。

### `module.Record`

编译期模块记录：requests / imports / exports / indirect_exports / star_exports / import_attributes。atom 只登记不在这里做 rc。运行时模块图在 `exec/module.zig`。

### `EntryContract`（packed u8）

进入字节码时钉死、并被 direct eval 继承的四位 grammar 允许位：`new_target_allowed` / `super_call_allowed` / `super_allowed` / `arguments_allowed`。**故意没有** var-env / `arguments` / `this` 的身份——那些以最终 vardef/closure 拓扑为准。对齐 `JSFunctionBytecode` 的四位。

### `CompilePolicy` / `CompileTiming` / `CompileContext`

- `CompilePolicy.runtime_strict`：整棵 FunctionDef 树共享。
- `CompileTiming`：调用方栈上的可选计时，parser/产物都不保留。
- `CompileContext.realm`：借入的 `RealmContext`。每个发布的 FunctionBytecode 自己 retain 一份 `RealmRef`（QuickJS `b->realm = JS_DupContext(ctx)`）。`artifactAllocator` 是 persistent allocator。

### `FlowTailSummary`

parser 流尾 O(1) 摘要（`fd->last_opcode_pos`，quickjs.c:22067/23809）：最后非 line_num opcode、最后非 cleanup opcode、绝对跳转 watermark、tagged parser-label 计数。`valid=false` 表示必须从代码重建。绕过统一发射原语的突变必须置 false。

### `dump` / `pipeline` re-export / 公开别名

`pub const pipeline = .{ pc2line, stack_size, finalize }`。文件末尾把 `FunctionBytecode` / `FunctionDef` / `Bytecode` / `FunctionLayout` / `CallSiteCache` / `PropSiteCache` / `CallFacts` / `LegacyExecutionAdapter` 再导出。`SparseDecodeTestOracle` 只给等价测试，生产 decode 用上面的权威表。

## 函数



### `format`

### `format.Description.immediateSize` (`src/bytecode.zig:2818`)

- **签名**：`pub fn immediateSize(self: Description) usize`。
- **作用**：操作数立即数总字节。
- **实现**：对每个 Operand 累加 `operandSize`。
- **所有权 / 错误 / 调用**：按值收 `Description`（其 `operands` 指向 comptime 静态切片），不分配、无 error set。**生产代码无调用方**：`describe` 的消费者都自己遍历 operands；树内调用点只有 `bytecode.zig:2869`–`:2872` 的本文件测试。


### `format.describe` (`src/bytecode.zig:2825`)

- **签名**：`pub fn describe(fmt: opcode.Format) Description`。
- **作用**：把 `opcode.Format` 映成诊断用 Operand 列表。
- **实现**：大 switch。`npopx` 的 argc 已烧入，只剩 cache_idx 的 u8；`atom_cache_u8` 与 `atom_u8` 都是 atom+u8。
- **所有权 / 错误 / 调用**：dump 的旧路径；生产 decode 用 layout_table。


### `format.operandSize` (`src/bytecode.zig:2858`)

- **签名**：`pub fn operandSize(operand: Operand) usize`。
- **作用**：单个诊断 Operand 的宽度。
- **实现**：u8/i8=1；u16/i16/local/arg/var_ref/npop=2；u32/i32/atom/const/label=4。
- **所有权 / 错误 / 调用**：纯 switch，不分配、无 error set。`format` 私有意义上只有一个调用方 `Description.immediateSize`（`bytecode.zig:2820`）。



### `constant`

### `constant.freeOwnedValue` (`src/bytecode.zig:2882`)

- **签名**：`fn freeOwnedValue(value: JSValue, rt: anytype) void`。
- **作用**：释放尚未发布进 FunctionBytecode 的常量池值。
- **实现**：只对 reserved BigInt 调 `destroyIfReservedValue`；其它 JSValue 的所有权在 tracing GC 下不在这里 rc-free。
- **所有权 / 错误 / 调用**：Pool.deinit / FunctionDef.deinit 调用。


### `constant.Pool.init` (`src/bytecode.zig:2893`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Pool`。
- **作用**：空常量池。
- **实现**：记下 MemoryAccount 与 AtomTable，values 为空切片。
- **所有权 / 错误 / 调用**：不分配，只把 `MemoryAccount` 与 `AtomTable` 两个**借来的**指针装进按值返回的 `Pool`；`values` 起始为空切片，真正的缓冲由 `append`/`appendOwned` 分配、由 `deinit` 释放。无 error set。唯一调用方 `BytecodeImpl.init`（`bytecode.zig:11630`）。


### `constant.Pool.deinit` (`src/bytecode.zig:2897`)

- **签名**：`pub fn deinit(self: *Pool, rt: anytype) void`。
- **作用**：释放池内值与数组。
- **实现**：先把切片摘下，对每项 `freeOwnedValue`，再 `memory.free`。
- **所有权 / 错误 / 调用**：rt 用于 BigInt reserved 销毁。


### `constant.Pool.append` (`src/bytecode.zig:2908`)

- **签名**：`pub fn append(self: *Pool, value: JSValue) !u32`。
- **作用**：追加一个 JSValue，返回下标。
- **实现**：每次 `alloc(len+1)`+memcpy+free 旧缓冲（编译期池，不是热路径）。
- **所有权 / 错误 / 调用**：`error.OutOfMemory`。


### `constant.Pool.appendOwned` (`src/bytecode.zig:2919`)

- **签名**：`pub fn appendOwned(self: *Pool, value: JSValue) !u32`。
- **作用**：所有权语义上的追加；实现与 `append` 相同。
- **实现**：同样的精确增长。
- **所有权 / 错误 / 调用**：调用方把值的所有权交给池。


### `constant.Pool.get` (`src/bytecode.zig:2930`)

- **签名**：`pub fn get(self: Pool, index: usize) ?JSValue`。
- **作用**：按下标取常量，越界 null。
- **实现**：长度检查。
- **所有权 / 错误 / 调用**：边界检查后按值返回 `JSValue`——**借用，不转移所有权**，调用方不得 release。不分配、无 error set，越界返回 null。调用方 `BytecodeImpl.constantAt`（`bytecode.zig:11678`），再由 VM/测试读取。



### `debug`

### `debug.Table.init` (`src/bytecode.zig:2953`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom) Table`。
- **作用**：空 pc 源位置表，记下 filename atom。
- **实现**：`noteHolderStore(filename)`。
- **所有权 / 错误 / 调用**：atom 由 table 持有直到 deinit。


### `debug.Table.deinit` (`src/bytecode.zig:2961`)

- **签名**：`pub fn deinit(self: *Table) void`。
- **作用**：释放 positions 数组，清空 filename。
- **实现**：filename 置 null_atom；free positions。
- **所有权 / 错误 / 调用**：不释放 atom 表本身。


### `debug.Table.add` (`src/bytecode.zig:2968`)

- **签名**：`pub fn add(self: *Table, position: SourcePosition) !void`。
- **作用**：追加一个 SourcePosition。
- **实现**：精确扩容 alloc(len+1)。
- **所有权 / 错误 / 调用**：**每次追加都重新分配**整条 `positions`（alloc 新的 → memcpy → free 旧的，走 `self.memory`），失败返回 `error.OutOfMemory`；缓冲归 `Table`，由 `deinit` 释放。`SourcePosition` 里没有 atom，不涉及引用计数。树内**无生产调用方**：唯一造出 `Table` 的入口 `BytecodeImpl.ensureDebug`（`bytecode.zig:11981`）本身也只被 `src/tests/bytecode.zig:134` 调用。


### `debug.Table.lineForPc` (`src/bytecode.zig:2978`)

- **签名**：`pub fn lineForPc(self: Table, pc: u32) ?u32`。
- **作用**：找 ≤pc 的最近行号。
- **实现**：正向遍历整张表，保留 `pc <= 目标` 且 pc 最大的一项。
- **所有权 / 错误 / 调用**：没有则 null。



### `module`

### `module.Record.init` (`src/bytecode.zig:3043`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Record`。
- **作用**：空模块记录。
- **实现**：只存 account/atoms。
- **所有权 / 错误 / 调用**：不分配，只装借来的 `MemoryAccount` 与 `AtomTable` 指针；六条列表都从空切片起步，由各 `add*` 经 `module.append` 分配、由 `deinit` 释放。无 error set。唯一调用方 `BytecodeImpl.ensureModule`（`bytecode.zig:11977`）。


### `module.Record.deinit` (`src/bytecode.zig:3047`)

- **签名**：`pub fn deinit(self: *Record) void`。
- **作用**：释放六张表。
- **实现**：先摘指针再按表 free。atom 本身不在这里减持。
- **所有权 / 错误 / 调用**：释放六条列表的缓冲（走 `self.memory`）并清空字段；无 error set。注意里面那四个空 `for` 循环是**故意的 no-op**：记录里的 atom 是借来的 id，不做 release。唯一调用方 `BytecodeImpl.deinit`（`bytecode.zig:11654`）。


### `module.Record.addRequest` (`src/bytecode.zig:3074`)

- **签名**：`pub fn addRequest(self: *Record, module_name: atom.Atom) !u32`。
- **作用**：登记一条 import 请求，返回下标。
- **实现**：append Request。
- **所有权 / 错误 / 调用**：经 `module.append` 用 `reallocElements` 增长 `requests`，缓冲归 `Record`；`module_name` 只复制 atom id，不 retain。失败返回 `error.OutOfMemory`（计数溢出也折成它）。调用方 `parser.zig:15401`（`addModuleRequestFromCurrentString`），它把错误重映射进 parser 的 `Error`。


### `module.Record.addImport` (`src/bytecode.zig:3081`)

- **签名**：`pub fn addImport( self: *Record, request_index: u32, import_name: atom.Atom, local_name: atom.Atom, var_idx: u16, is_namespace: bool, ) !void`。
- **作用**：登记一条 import 绑定（含闭包下标与 namespace 标志）。
- **实现**：append Import。
- **所有权 / 错误 / 调用**：同上增长 `imports`；`import_name`/`local_name` 只复制 id，不 retain。`error.OutOfMemory`。调用方 `parser.zig:15363`（`addModuleImportBinding`）。注意 `exec/module.zig` 里同名的 `pending.addImport` 是运行时模块记录的另一套 API，不是本函数。


### `module.Record.addExport` (`src/bytecode.zig:3100`)

- **签名**：`pub fn addExport(self: *Record, export_name: atom.Atom, local_name: atom.Atom) !void`。
- **作用**：登记本地 export。
- **实现**：append Export，`var_idx` 稍后由 finalize 填。
- **所有权 / 错误 / 调用**：增长 `exports`，两个 atom 只复制 id；`var_idx` 留给模块根 finalizer 回填。`error.OutOfMemory`。调用方 `parser.zig:15322`（`addModuleExportName`）。


### `module.Record.addIndirectExport` (`src/bytecode.zig:3109`)

- **签名**：`pub fn addIndirectExport( self: *Record, request_index: u32, export_name: atom.Atom, import_name: atom.Atom, is_namespace: bool, ) !void`。
- **作用**：登记 re-export。
- **实现**：append IndirectExport。
- **所有权 / 错误 / 调用**：增长 `indirect_exports`，atom 只复制 id。`error.OutOfMemory`。调用方 `parser.zig:15388`（`addModuleIndirectExport`）。


### `module.Record.addStarExport` (`src/bytecode.zig:3126`)

- **签名**：`pub fn addStarExport(self: *Record, request_index: u32, export_name: atom.Atom) !void`。
- **作用**：登记 `export *`。
- **实现**：append StarExport。
- **所有权 / 错误 / 调用**：增长 `star_exports`，atom 只复制 id。`error.OutOfMemory`。调用方 `parser.zig:15395`（`addModuleStarExport`）。


### `module.Record.addImportAttribute` (`src/bytecode.zig:3134`)

- **签名**：`pub fn addImportAttribute(self: *Record, request_index: u32, key: atom.Atom, value: atom.Atom) !void`。
- **作用**：登记 import attribute。
- **实现**：append ImportAttribute。
- **所有权 / 错误 / 调用**：增长 `import_attributes`，key/value 两个 atom 都只复制 id。`error.OutOfMemory`。调用方 `parser.zig:15338`（`addModuleImportAttribute`）。


### `module.append` (`src/bytecode.zig:3145`)

- **签名**：`inline fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void`。
- **作用**：把一项精确追加到模块记录切片。
- **实现**：`len+1` 溢出当 OOM，随后 `MemoryAccount.reallocElements` 扩到 `len+1` 并在尾部写入新项。
- **所有权 / 错误 / 调用**：Record 的 add* 全部走它。



### `CompileContext`

### `CompileContext.artifactAllocator` (`src/bytecode.zig:3203`)

- **签名**：`pub inline fn artifactAllocator(self: CompileContext) @import("std").mem.Allocator`。
- **作用**：发布产物用的持久分配器。
- **实现**：`realm.runtime.memory.persistent_allocator`。
- **所有权 / 错误 / 调用**：CompileContext 本身不拥有 realm。



### `dump`

### `dump.dumpFunctionBytecode` (`src/bytecode.zig:12271`)

- **签名**：`pub fn dumpFunctionBytecode( writer: *std.Io.Writer, fb: *const function_bytecode.FunctionBytecode, atoms: *atom.AtomTable, opts: Options, ) !void`。
- **作用**：反汇编已发布 FunctionBytecode。
- **实现**：转 dumpArtifact：名字、计数、再 decode-first 打指令。
- **所有权 / 错误 / 调用**：atoms 由 Runtime 提供。


### `dump.dumpArtifact` (`src/bytecode.zig:12280`)

- **签名**：`fn dumpArtifact( writer: *std.Io.Writer, atoms: *atom.AtomTable, name: atom.Atom, arg_count: u16, var_count: u16, stack_size: u16, code: []const u8, constant_count: usize, opts: Options, ) !void`。
- **作用**：打印头与指令。解码失败则按单原始字节继续（必须能渲染损坏流）。
- **实现**：成功路径用 layout 打操作数，含 burned-in。
- **所有权 / 错误 / 调用**：writer 错误上抛。


### `dump.printOperandsFromLayout` (`src/bytecode.zig:12344`)

- **签名**：`fn printOperandsFromLayout( writer: *std.Io.Writer, atoms: *atom.AtomTable, h: opcode.decode.Header, code: []const u8, ) !void`。
- **作用**：按槽打印：atom 查名字，label 打 `L#`，其余按十进制。注意 `.sub_opcode` 臂里那段「`dyn_env_probe` 打 kind/with」的特判今天不可达——`dyn_env_probe` 的 fmt 是 `atom_label_u8`，第三槽 kind 是 `.flags` 而非 `.sub_opcode`，所以 flags 字节走 else 打原始数字；带 `.sub_opcode` 槽的只有 `ext0`。
- **实现**：截断写 `<trunc>` 后返回。
- **所有权 / 错误 / 调用**：不分配，只从 `Header.layout()` 借来的布局逐槽读 `code` 并写进调用方的 writer；错误只有 writer 自己的错误向上传。`dump` 私有，唯一调用方 `dumpArtifact`（`bytecode.zig:12331`）。



### `SparseDecodeTestOracle`

### `SparseDecodeTestOracle.layoutsEqual` (`src/bytecode.zig:12419`)

- **签名**：`fn layoutsEqual(a: OperandLayout, b: OperandLayout) bool`。
- **作用**：等价测试：只比较已初始化前缀。
- **实现**：len/atom_slot/var_ref_slot 与 slots[0..len]。
- **所有权 / 错误 / 调用**：历史稀疏表 vs 权威表。


### `SparseDecodeTestOracle.layoutOf` (`src/bytecode.zig:12450`)

- **签名**：`fn layoutOf(form: logical.LogicalOpcode) *const OperandLayout`。
- **作用**：经去重池取 layout 指针。
- **实现**：indices[form] → rows。
- **所有权 / 错误 / 调用**：测试。


### `SparseDecodeTestOracle.dynamicShape` (`src/bytecode.zig:12464`)

- **签名**：`fn dynamicShape(form: logical.LogicalOpcode) ?logical.DynamicStack.Shape`。
- **作用**：查 dynamic_stack 下标表。
- **实现**：512 槽，无则 null。
- **所有权 / 错误 / 调用**：测试。


## 覆盖核对

- 清单函数数（本文件分组）: 29（`src/bytecode.zig` 全文件 538）
- 本文标题覆盖: 29
- 全册清单函数数 (`src/bytecode.zig` 538 + `src/opcode_logical.zig` 7): 545
- 全册标题覆盖: 545
- 未覆盖: 无

全册（`05-*.md`）合计应覆盖清单中 `src/bytecode.zig` + `src/opcode_logical.zig` 的每一行。核对：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
    --docs 'docs/code-walkthrough/05-*.md' \
    src/bytecode.zig src/opcode_logical.zig
```
