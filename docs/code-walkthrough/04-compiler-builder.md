# 04 — builder.zig：Stage 1 发射器

Parser 只往 `Builder` 写：紧凑临时字节码 + 与消费者成比例的旁表。没有 per-instruction 对象 IR。atom 操作数由 ledger **拥有**（一次 retain），直到产物提交或 `deinit`。OOM 后 builder 仍可 `deinit`；后续 pass 看不到半发布状态。

## 文件级类型

- **`SourceSlot`**：`temp_offset` + `line` + `col`。绑的是逻辑事件顺序，不是最终 PC。`line <= 0 or col <= 0` 在 sink 丢掉。
- **`ControlKind`**：`terminal` / `direct_eval`。稀疏 CFG 事件，4 字节 `ControlSlot`（`temp_offset:u31` + kind）。
- **`DetachedSegment`**：从 builder 剪下的尾巴。拥有 code/atoms/relocs/controls/binds/sources；偏移相对段起点。`LabelId` **不**进段——标签是函数全局的。
- **`Snapshot`**：七个标量：`code_len, atom_len, label_len, reloc_len, control_len, source_len, last_opcode_pos`。
- **`Error`**：`OutOfMemory` / `InvalidBytecode` / `BytecodeOverflow`。
- **`Builder.last_opcode_pos`**：qjs `fd->last_opcode_pos`。投机 LHS rewind 与直线活性的唯一目标事实。控制流汇合处置 −1。

`inline_control_capacity = 4`：常见单 return 函数不另分配。

---

### `reserve` (`src/compiler/builder.zig:91`)

- **签名**：`pub inline fn reserve( comptime T: type, mem: *core.memory.MemoryAccount, slice: *[]T, capacity: *usize, used: u32, need: usize, min_cap: usize, ) Error!void`。
- **作用**：在不改已初始化前缀长度的前提下扩 backing。可见 slice 覆盖整块分配，`used` 才是可读长度。
- **实现**：`used + need` 溢出则 OOM。已够 capacity 则返回。否则把 slice 看成字节，进 `reserveSlowBytes`：容量按 `max(required, doubled, min_cap)` 几何增长，拷贝 `used` 个元素，释放旧 backing。热路径只是一次比较，对齐 QuickJS `dbuf_put*`。
- **所有权 / 错误 / 调用**：新 backing 记在 `MemoryAccount`。失败时旧 backing 不动。所有 emit/label/reloc/source 增长都走这里。

### `reserveSlowBytes` (`src/compiler/builder.zig:127`)

- **签名**：`noinline fn reserveSlowBytes( mem: *core.memory.MemoryAccount, slice_bytes: *[]u8, capacity: *usize, used: u32, required: usize, min_cap: usize, elem_size: usize, alignment: std.mem.Alignment, ) Error!void`。
- **作用**：Backing 必须增长时的类型擦除分配/拷贝/释放；热路径 `reserve` 只付一次比较。
- **实现**：断言 `required > capacity.*`。新容量 `max(required, doubled, min_cap)`，翻倍溢出则饱和到 `maxInt(usize)`。`mem.allocElements` 失败 → `OutOfMemory`。`used * elem_size` 溢出同样 OOM。非零 used 则 `@memcpy` 前缀，再把 slice/capacity 换成新块；旧 capacity 非 0 才 `freeAlignedBytes`。分配走已链接的 `allocSlowErased`，不走 `allocAlignedBytes(trigger=true)`。对齐 qjs `dbuf_put*` 只在不够时进 outlined allocator。
- **所有权 / 错误 / 调用**：新 backing 记在 `MemoryAccount`。失败时旧 backing 不动。`reserve` 是唯一调用方。

### `Builder.init` (`src/compiler/builder.zig:205`)

- **签名**：`pub fn init(memory: *core.memory.MemoryAccount, atoms: *core.atom.AtomTable) Builder`。
- **作用**：空 builder：所有 slice 空、len/capacity 0、`last_opcode_pos = -1`。
- **实现**：只填 `memory` 与 `atoms`。
- **所有权 / 错误 / 调用**：不分配。调用方之后必须 `deinit`。

### `Builder.enableControlIndex` (`src/compiler/builder.zig:212`)

- **签名**：`pub fn enableControlIndex(self: *Builder) Error!void`。
- **作用**：在发出第一字节之前打开稀疏控制索引。生产 parser builder 会开；手搓字节流的测试可关，让 `cfg.build` 走全解码回退。
- **实现**：`code_len != 0 or control_len != 0` 则 `InvalidBytecode`，否则 `control_index_enabled = true`。
- **所有权 / 错误 / 调用**：无分配。必须在首次 emit 前调用。

### `Builder.hasControlIndex` (`src/compiler/builder.zig:218`)

- **签名**：`pub fn hasControlIndex(self: *const Builder) bool`。
- **作用**：CFG 构建选 indexed 快路径还是解码回退。
- **实现**：返回 `control_index_enabled`。
- **所有权 / 错误 / 调用**：`*const` 只读一个 bool，不分配、无 error set。唯一调用方 `cfg.build`（`src/compiler/cfg.zig:1387`）：真时走 indexed 快路径，假时走自校验解码回退。开关本身只能在空 builder 上由 `enableControlIndex`（`src/compiler/builder.zig:211`）置起，否则 `error.InvalidBytecode`。

### `Builder.controlCount` (`src/compiler/builder.zig:222`)

- **签名**：`pub fn controlCount(self: *const Builder) u32`。
- **作用**：稀疏控制事件条数。
- **实现**：返回 `control_len`。
- **所有权 / 错误 / 调用**：`*const` 只读 `control_len`，不分配、无 error set。调用方全在 cfg 的 indexed 臂里当游标上界与耗尽断言：`src/compiler/cfg.zig:1173`、`:1183`、`:1296`，另 `:1349` 用它做「控制事件必须刚好消费完」的收尾检查（不等就是 `error.InvalidBytecode`）。

### `Builder.controlAt` (`src/compiler/builder.zig:226`)

- **签名**：`pub fn controlAt(self: *const Builder, index: u32) ControlSlot`。
- **作用**：按创建序取一条控制事件：前 4 条走 inline 数组，其余走 spill。
- **实现**：`index < control_len` 断言。`< inline_control_capacity` 读 `inline_controls`，否则 `control_spill[index - 4]`。
- **所有权 / 错误 / 调用**：Debug 越界断言。CFG 构建与 rollback 截断用。

### `Builder.ensureControlCapacity` (`src/compiler/builder.zig:233`)

- **签名**：`fn ensureControlCapacity(self: *Builder, additional: usize) Error!void`。
- **作用**：保证还能再追加 `additional` 条控制事件。
- **实现**：所需总数超 `u32` 则 `BytecodeOverflow`。仍落在 4 格 inline 则返回。否则对 spill 调 `reserve(ControlSlot, …, min_cap=4)`。
- **所有权 / 错误 / 调用**：OOM 不改现有行。`recordControl` / `spliceSegment` 调用。

### `Builder.appendControlAssumeCapacity` (`src/compiler/builder.zig:256`)

- **签名**：`fn appendControlAssumeCapacity(self: *Builder, slot: ControlSlot) void`。
- **作用**：容量已够时写入一条控制事件。
- **实现**：inline 或 spill 槽赋值，`control_len += 1`。
- **所有权 / 错误 / 调用**：调用前必须 `ensureControlCapacity`。无 error。

### `Builder.recordControl` (`src/compiler/builder.zig:271`)

- **签名**：`pub fn recordControl(self: *Builder, kind: ControlKind) Error!void`。
- **作用**：parser 刚发出 terminal / direct_eval 后记一条稀疏索引。opcode 字节仍是语义权威。
- **实现**：索引未开则 no-op。`last_opcode_pos < 0` 或偏移非法 / 非严格递增则失败。然后 ensure + append。
- **所有权 / 错误 / 调用**：parser facade 在 emit 之后调用。CFG 用它避开解码无关指令。

### `Builder.deinit` (`src/compiler/builder.zig:291`)

- **签名**：`pub fn deinit(self: *Builder) void`。
- **作用**：按满 capacity 释放所有 backing，并把字段收成空 builder。幂等。
- **实现**：code / atom / label / reloc / control_spill / source 各 `memory.free`（capacity 0 跳过）。atom 前缀不逐项 unretain——TGC S3-c 之后 builder 记的就是借用 id（文件头的 ownership contract 已按此改写），存活由编译期的 `CompileAtomScope` 负责；本函数把 slice 置空、len 清零、`last_opcode_pos = -1`。
- **所有权 / 错误 / 调用**：`releaseConsumedBuilder`、测试 `defer`、失败路径。可连调两次。

### `Builder.newLabel` (`src/compiler/builder.zig:322`)

- **签名**：`pub fn newLabel(self: *Builder) Error!LabelId`。
- **作用**：分配下一个函数局部 `LabelId`，槽为默认未绑定、ref 0、无 reloc。
- **实现**：`label_len == maxInt(u32)` 则 overflow。`reserve(LabelSlot, …, 1, min_cap=8)`，写默认槽，len+1，`@enumFromInt`。
- **所有权 / 错误 / 调用**：每个创建的标签必须后来 `bindLabel`（或 retarget 后绑定到同一点）。parser 的 break/continue/finally/optional-chain 都从这里拿身份。

### `Builder.emitJump` (`src/compiler/builder.zig:343`)

- **签名**：`pub fn emitJump(self: *Builder, op_id: u8, label: LabelId) Error!void`。
- **作用**：发一条跳转格式指令，操作数是 `LabelId`，并把头插 RelocEntry、`ref_count += 1`。
- **实现**：外标签 fail-closed。先 `reserveCode(5)` 再 reserve reloc。写 `op_id` + LE u32 下标。reloc `kind=.jump32`，`next = slot.first_reloc`（头插 → 递减下标）。已绑定则 `backward_target = true`。更新 `last_opcode_pos` 与 `code_len`。
- **所有权 / 错误 / 调用**：容量失败时尚未写入。parser `emitterJump` 包装。S4 才把 LabelId 改成相对位移。

### `Builder.bindLabel` (`src/compiler/builder.zig:383`)

- **签名**：`pub fn bindLabel(self: *Builder, label: LabelId) Error!void`。
- **作用**：把标签钉在当前 `code_len`（即将发出的下一条指令处）。
- **实现**：外标签或已 bound → `InvalidBytecode`。`bound_offset = code_len`，`flags.bound = true`。不改 `last_opcode_pos`（那是 `emitterBindLabel` 包装层 / `invalidateLastOpcode` 的事）。
- **所有权 / 错误 / 调用**：双绑 fail-closed。零 ref 也要绑——死标签由 resolve 丢掉。

### `Builder.bindLabelMatchBarrier` (`src/compiler/builder.zig:395`)

- **签名**：`pub fn bindLabelMatchBarrier(self: *Builder, label: LabelId) Error!void`。
- **作用**：绑定并保留顺序匹配屏障（身份版 `OP_label`）。普通绝对 PC 补丁目标用 `bindLabel`，丢光引用后对 S4 透明。
- **实现**：`try bindLabel` 再 `match_barrier = true`。
- **所有权 / 错误 / 调用**：unfolded `scope_make_ref` 尾、需要挡住 peephole 的 parser 点。

### `Builder.retargetLabelRefs` (`src/compiler/builder.zig:417`)

- **签名**：`pub fn retargetLabelRefs(self: *Builder, from: LabelId, to: LabelId) Error!void`。
- **作用**：把 `from` 上所有待引用挪到已绑定的 `to`。身份版 `patchJumpTarget`（qjs switch dispatch 回写 PC）。操作数始终是 LabelId。
- **实现**：`from` 必须未绑定、`to` 必须已绑定、二者不同。先走完整条链校验操作数确实写着 `from` 且 `ref_count == 链长`。再写操作数为 `to`，若 `to.bound_offset < operand` 则标 backward。两条递减链归并成一条递减链（不能拼接，否则 rollback 的「第一个低于 mark 的项」会坏）。`from` 的 ref/reloc 清零，但 **绑定到 `to` 的同一偏移**（每个身份必须结束 bound）。
- **所有权 / 错误 / 调用**：半移动的链不可恢复，所以先校验后突变。生产上经 parser 的 `emitterRetargetLabel` 门面（`src/parser.zig:7671`）进来，两个调用点：`parseSwitchStatement` 的未命中→default 收尾（`:9728`）与 `parseForInOf` 里非法调用目标把入口 goto 改指赋值块（`:10911`）。

### `Builder.firstUnboundLabel` (`src/compiler/builder.zig:496`)

- **签名**：`pub fn firstUnboundLabel(self: *const Builder) ?LabelId`。
- **作用**：按创建序找第一个未绑定标签；用来证明「每个创建的标签最终都 bound」。
- **实现**：线性扫 `flags.bound`。
- **所有权 / 错误 / 调用**：无分配。测试与 debug 断言用。

### `Builder.emitOp` (`src/compiler/builder.zig:504`)

- **签名**：`pub fn emitOp(self: *Builder, op_id: u8) Error!void`。
- **作用**：发一字节纯 opcode。
- **实现**：`reserveCode(1)`，写字节，更新 `last_opcode_pos` 与 `code_len`。
- **所有权 / 错误 / 调用**：不涉及 atom 账本；只往 builder 自己的 `code` 缓冲写一字节并更新 `last_opcode_pos`，缓冲归 `self.memory`、由 `Builder.deinit` 释放。唯一的错误来自 `reserveCode`（`OutOfMemory` / `BytecodeOverflow`），失败时一个字节也没写。parser 侧经 `State.builderEmitOp` 与 emitter 门面进来，`resolve_labels` / `resolve_variables` 的测试夹具也直接用它拼字节流。

### `Builder.emitOpU8` (`src/compiler/builder.zig:514`)

- **签名**：`pub fn emitOpU8(self: *Builder, op_id: u8, val: u8) Error!void`。
- **作用**：opcode + u8 立即数（紧凑临时编码）。
- **实现**：2 字节。
- **所有权 / 错误 / 调用**：写进 builder 自己的 `code` 缓冲，该缓冲由 `self.memory`（runtime 的 memory 账户）拥有，`Builder.deinit` 释放，本函数不移交所有权。error set 是 `builder.Error`：`reserveCode` 增长失败给 `error.OutOfMemory`，超过 u32 码长给 `error.BytecodeOverflow`；两者都不是 JS 异常，由 `parser.mapBuilderError`（`src/parser.zig:7448`）翻成 parser 的 `OutOfMemory` / `BytecodeOverflow`。调用方：`src/parser.zig:3644`（`builderEmitOpU8`）、`src/parser.zig:7552`（emitter vtable），以及测试 `src/tests/bytecode.zig:313`。

### `Builder.emitOpU16` (`src/compiler/builder.zig:526`)

- **签名**：`pub fn emitOpU16(self: *Builder, op_id: u8, val: u16) Error!void`。
- **作用**：opcode + LE u16（槽索引、scope 等）。
- **实现**：3 字节。
- **所有权 / 错误 / 调用**：不涉及 atom；三字节写进 `code` 缓冲（归 `self.memory`），失败只来自 `reserveCode`，且失败时未写任何字节。S3 仍可能原样拷这些宽形式，S4 short 再压窄。parser 侧入口是 `State.builderEmitOpU16` 与 `emitterOpU16`，`enter_scope` 也走它。

### `Builder.emitCallOp` (`src/compiler/builder.zig:540`)

- **签名**：`pub fn emitCallOp(self: *Builder, op_id: u8, argc: u16) Error!void`。
- **作用**：可变 arity 调用：`argc:u16` + 占位 `cache_idx:u8`。
- **实现**：4 字节，index 字节写 0。S4 写真正的 call-site 索引。
- **所有权 / 错误 / 调用**：不涉及 atom；四字节（op + argc:u16 + cache_idx 占位）与最终形式等宽，避免 S4 再插字节，占位字节由 `resolve_labels` 覆盖。错误只来自 `reserveCode`。两个生产调用点：`emitterCallOp`（`src/parser.zig:7568`）与类字段初始化调用的手写发射（`:15060`）。

### `Builder.emitOpU32` (`src/compiler/builder.zig:553`)

- **签名**：`pub fn emitOpU32(self: *Builder, op_id: u8, val: u32) Error!void`。
- **作用**：opcode + LE u32。
- **实现**：5 字节。
- **所有权 / 错误 / 调用**：不涉及 atom：五字节写 `code`，立即数按小端 u32 原样存（常量表下标、`set_class_name` 的距离等非 atom 的 32 位值）。错误只来自 `reserveCode`。生产上由 parser 的 `Emitter.opU32` 门面使用，另有 `resolve_*` 的测试夹具直接调用。

### `Builder.emitOpI32` (`src/compiler/builder.zig:565`)

- **签名**：`pub fn emitOpI32(self: *Builder, op_id: u8, val: i32) Error!void`。
- **作用**：opcode + LE i32。
- **实现**：5 字节。
- **所有权 / 错误 / 调用**：与 `emitOpU32` 同形，只是按 i32 写（`push_i32` 等带符号立即数）；不涉及 atom，错误只来自 `reserveCode`。唯一生产调用点 `State.builderEmitOpI32`。

### `Builder.emitAtomOpOwned` (`src/compiler/builder.zig:578`)

- **签名**：`pub fn emitAtomOpOwned(self: *Builder, op_id: u8, atom_id: core.atom.Atom) Error!void`。
- **作用**：带 atom 的 opcode；调用方的一次 retain **无条件**转入 ledger（容量失败也吃掉 retain）。
- **实现**：`opcode.carriesPropCacheIdxPhase1(op_id)` 为真的 `atom_cache_u8` 族（`get_field`/`get_field2`/`put_field` 等）在 phase-1 带占位 cache 字节（6 字节），否则 5 字节。先 reserve code 再 reserve atom 槽，失败直接 return err（atom 已由契约视为被 sink 消费）。写入 opcode、atom u32、可选 `no_cache_idx`。
- **所有权 / 错误 / 调用**：**owned-atom sink**：`atom_id` 的那一份所有权无条件转进 builder 的 `atom_operands` 账本（源码注释写明：即便两次容量预留中的任何一次失败，sink 也算消费掉了调用方的 retain），此后由 `Builder.deinit` 或产物提交负责。atom 同时以小端 u32 写进 code，属性站点家族（`get_field` / `get_field2` / `put_field`，`opcode.carriesPropCacheIdxPhase1`）多一个 `no_cache_idx` 占位字节，使指令宽度与最终形式一致。错误：`reserveCode` 与 atom 账本增长的 `OutOfMemory` / `BytecodeOverflow`。反向转移是 `takeTrailingAtomOpcodeOwned` / `takeLastAtomOwned`。parser 侧入口 `State.emitAtomOp`（`src/parser.zig:3664`）与 `emitterOpAtom`（`:7524`）。

### `Builder.emitAtomOpU8Owned` (`src/compiler/builder.zig:617`)

- **签名**：`pub fn emitAtomOpU8Owned(self: *Builder, op_id: u8, atom_id: core.atom.Atom, val: u8) Error!void`。
- **作用**：`define_class`/`define_method` 临时编码：op + atom + u8。owned-atom sink。
- **实现**：6 字节；容量失败同样消费 retain。
- **所有权 / 错误 / 调用**：同 `emitAtomOpOwned` 的 owned-atom 契约（retain 无条件转进账本），只是固定 6 字节 `op + atom(4) + u8`，没有 cache_idx 分叉。错误同为两次 reserve 的 `OutOfMemory` / `BytecodeOverflow`。生产调用点 `State.emitAtomOpU8`（`src/parser.zig:3668`），服务 `define_class` / `define_method` 这类带旗标的指令。

### `Builder.emitAtomOpU16Owned` (`src/compiler/builder.zig:647`)

- **签名**：`pub fn emitAtomOpU16Owned(self: *Builder, op_id: u8, atom_id: core.atom.Atom, val: u16) Error!void`。
- **作用**：`scope_get_var` 族：op + atom + scope u16。owned-atom sink。
- **实现**：7 字节。
- **所有权 / 错误 / 调用**：owned-atom 契约同上，固定 7 字节 `op + atom(4) + scope(2)`，是 `scope_get_var` 家族的 phase-1 编码，S3 的 `lowerScopeVar` 就读这 7 字节。错误只来自两次 reserve。生产上经 parser 的 `Emitter.opAtomU16` 门面发出，`resolve_variables` 的测试夹具也大量直接构造。

### `Builder.emitScopeRefOpOwned` (`src/compiler/builder.zig:681`)

- **签名**：`pub fn emitScopeRefOpOwned( self: *Builder, op_id: u8, atom_id: core.atom.Atom, label: LabelId, scope: u16, ) Error!void`。
- **作用**：`scope_make_ref`：op + atom(4) + LabelId(4) + scope(2)，11 字节。辅标签 reloc `kind=.aux32` 在 opcode+5。qjs `update_label(fd, label, 1)`。
- **实现**：外标签 **先** fail-closed（注释写「消费 atom retain」——当前实现在校验失败时尚未写入 ledger，调用方仍须把非法标签当错误路径处理）。三路 reserve 后写字节，头插 aux reloc，已绑定则 backward。
- **所有权 / 错误 / 调用**：**三份资源一次性预留**（code 11 字节、一条 RelocEntry、一格 atom 账本），任一失败即整条不发出；但与其它 owned-atom sink 一样，atom 的 retain 视为已被消费。非法 `label` 在三次 reserve 之前就 fail-closed。reloc 的 `kind` 是 `.aux32`、`operand_offset = opcode_offset + 5`，`ref_count += 1`（对齐 qjs `update_label(fd, label, 1)`），目标已绑定时标 `backward_target`。唯一生产调用点 `emitterScopeRefOp`（`src/parser.zig:7535`），用于 `getLValue` 的 with-scope 分支；`putLValue` 随后把这个 aux 身份 `bindLabel`。

### `Builder.takeLastAtomOwned` (`src/compiler/builder.zig:746`)

- **签名**：`pub fn takeLastAtomOwned(self: *Builder) Error!core.atom.Atom`。
- **作用**：把最新 ledger atom 所有权交回调用方（owned sink 的逆）。
- **实现**：空 ledger → `InvalidBytecode`。`atom_len -= 1`，返回该槽。
- **所有权 / 错误 / 调用**：**反向所有权转移**：把账本最末一个 atom 的那份 retain 交回调用方（只把 `atom_len` 减一，不 release、不清槽位），空账本时 `error.InvalidBytecode` fail-closed。树内唯一调用方是 `rewriteTrailingAtomOpAsPlain`（`src/compiler/builder.zig:854`，把 `set_name` 改写成 `set_name_computed` 时丢掉原 atom），其余是本文件的单测；`getLValue` 的 getter rewind 走的是另一个更严格的 `takeTrailingAtomOpcodeOwned`。

### `Builder.takeTrailingAtomOpcodeOwned` (`src/compiler/builder.zig:755`)

- **签名**：`pub fn takeTrailingAtomOpcodeOwned( self: *Builder, opcode_offset: u32, expected_opcode: u8, expected_atom: core.atom.Atom, ) Error!core.atom.Atom`。
- **作用**：qjs `get_lvalue`：校验后一次性收回尾部 atom opcode 并截断。无分配事务。
- **实现**：要求 `last_opcode_pos` 正好是该偏移、opcode/atom/ledger 一致、尾部无 reloc、无更靠后的 bind。然后 `atom_len-1`，丢掉 `temp_offset > opcode_offset` 的 source 与 `>=` 的 control，`code_len = opcode_offset`，`last_opcode_pos = -1`。
- **所有权 / 错误 / 调用**：**反向 owned-atom 转移 + 尾部截断的单一事务**：先把七项前置条件全部验完（`last_opcode_pos` 必须正指向该 opcode、code 尾形、code 里的 atom 与账本末位都等于 `expected_atom`、最后一条 reloc 的操作数不跨越边界、没有任何已绑定标签落在边界之后），任一不符返回 `error.InvalidBytecode` 且**状态一字节不改**。通过后才依次：`atom_len -= 1`（retain 交回调用方）、丢掉边界之后的 source 槽与控制事件、把 `code_len` 截回 `opcode_offset`、`last_opcode_pos = -1`。唯一生产调用方是 parser 的 `getLValue`（`src/parser.zig` 里 `scope_get_var` / `get_field` / `scope_get_private_field` 三条臂），它把取回的 atom 存进 `LValue.name`。

### `Builder.replaceAtomOperand` (`src/compiler/builder.zig:804`)

- **签名**：`pub fn replaceAtomOperand( self: *Builder, opcode_offset: u32, atom_index: u32, expected_opcode: u8, expected_atom: core.atom.Atom, replacement: core.atom.Atom, ) Error!void`。
- **作用**：原地换一个已拥有的 atom（推断名）。`replacement` 借入：校验后 retain 再放旧 owner，之后不能失败。
- **实现**：校验 opcode/编码 atom/ledger 三者一致。写 `atom_operands[index] = replacement` 和操作数字节。当前实现把 `replacement` 直接写入（调用方已 retain）。
- **所有权 / 错误 / 调用**：**就地替换，不改长度**：调用方必须同时给出发射时记下的 `opcode_offset` 与 `atom_index`，两边都要与 `expected_atom` 对得上，否则 `error.InvalidBytecode` 且字节不动。`replacement` 是借用进来的 atom id（源码注释里「retains it before releasing the previous owner」是 TGC S3-c 之前的措辞，现在两侧都只是 id），验证通过之后的写入不可能失败。生产用途是推断函数名：`setObjectName` 把 `set_name` 的 `null_atom` 占位或 `define_class` 的空串占位换成真名（`src/parser.zig:13619` / `:13629`）。

### `Builder.rewriteTrailingAtomOpAsPlain` (`src/compiler/builder.zig:836`)

- **签名**：`pub fn rewriteTrailingAtomOpAsPlain( self: *Builder, expected_opcode: u8, expected_atom: core.atom.Atom, replacement_opcode: u8, ) Error!void`。
- **作用**：把尾部 5 字节 atom opcode 收成 1 字节纯 opcode，保留起点的 source。qjs 截断 `OP_set_name(NULL)` 再发 `OP_set_name_computed`。
- **实现**：校验 last opcode 正好 5 字节且 atom 匹配。`truncateLastOpcodePreserveSources` + `takeLastAtomOwned`，再写 replacement 并把 `code_len` 收成 offset+1。
- **所有权 / 错误 / 调用**：先验后改：`last_opcode_pos`、尾部必须正好是 5 字节的该指令、code 与账本里的 atom 都等于 `expected_atom`，任一不符 `error.InvalidBytecode` 且不动状态。通过后 `truncateLastOpcodePreserveSources` 保住这条指令起点上的源事件，再 `takeLastAtomOwned` 把账本末位的 owner 取回并**丢弃**（`_ = removed`——这条路径上的 atom 恒为 `null_atom` 占位，没有需要 release 的东西），最后就地把 opcode 换成一字节形式并把 `code_len` 收成 `opcode_offset + 1`。因为复用原有的 5 字节容量，整个改写不分配。唯一生产调用方 `setObjectNameComputed`（`src/parser.zig:13659`），即 `set_name(NULL)` → `set_name_computed`。

### `Builder.addSourceMarker` (`src/compiler/builder.zig:862`)

- **签名**：`pub fn addSourceMarker(self: *Builder, line: i32, col: i32) Error!void`。
- **作用**：在当前 `code_len` 记一条 pc2line 事件。
- **实现**：`line/col <= 0` 直接返回。Debug 断言单调。`reserve(SourceSlot)` 后追加。
- **所有权 / 错误 / 调用**：唯一的分配是 `source_slots` 的增长（归 `self.memory`、`Builder.deinit` 释放），失败即 `error.OutOfMemory`。`line <= 0 or col <= 0` 是**静默丢弃**而非错误——这正是文件头说的「sink 丢掉」。槽记的是 `temp_offset = code_len`（下一条即将发出的指令），S4 才把它映到输出 PC；本函数不动 `last_opcode_pos`，所以在源标记与指令之间不会打断 `getLValue` 的尾指令识别。Debug 下断言源槽偏移单调不减。

### `Builder.snapshot` (`src/compiler/builder.zig:886`)

- **签名**：`pub fn snapshot(self: *const Builder) Snapshot`。
- **作用**：记下六张表长度 + `last_opcode_pos`，供 rollback/detach。
- **实现**：拷七个标量。
- **所有权 / 错误 / 调用**：契约：若可能 rollback 一个边界 bind，必须 **在 bind 之前** snapshot（边界 bind 与预 snapshot bind 无法区分）。

### `Builder.rollback` (`src/compiler/builder.zig:902`)

- **签名**：`pub fn rollback(self: *Builder, snap: Snapshot) void`。
- **作用**：回到 snapshot：截断 code/labels/relocs/control/source，atom_len 回到 snap（超出部分不再被 ledger 视为已初始化）。
- **实现**：Debug 断言 snap 之后创建的标签其链全在 `reloc_len` 之后。对幸存标签：弹出 `head >= snap.reloc_len` 的 reloc 并 `ref_count--`。`bound_offset > snap.code_len` 的解绑；**等于** `snap.code_len` 的 bind 保留。`backward_target` 不清。
- **所有权 / 错误 / 调用**：无 error set（纯截断）。生产上有两类用法：绝大多数是 `errdefer v2b.rollback(snapshot)` 的 OOM 中止路径（`src/parser.zig` 里近二十处，`emitOptionalChainTest` 的 `:6117` 也属此类，它还顺带还原出参 `optional_chain_label`），以及**唯一一处刻意的中途回滚**——`parseClassElement` 在解析完显式构造器后 `rollback(ctor_snap)` 撤掉那条普通 `fclosure` 表达式（`:13907`），改由 `define_class` 经 cpool 下标引用子函数。atom 侧只把 `atom_len` 截回快照长度，不逐个 release（编译期 atom 由 `CompileAtomScope` 作根，失败时整棵产物被放弃）。

### `Builder.truncateLastOpcodePreserveSources` (`src/compiler/builder.zig:957`)

- **签名**：`pub fn truncateLastOpcodePreserveSources(self: *Builder, new_code_len: u32) Error!void`。
- **作用**：去掉尾 opcode，保留所有物理上在它之前发出的 source（`temp_offset == new_code_len` 的留下，描述即将写在同一边界的替换）。也接受无 source 的 opcode。
- **实现**：与上类似，但 source 用 `> new_code_len` 才丢（注意不是 `>=`）。
- **所有权 / 错误 / 调用**：三项前置校验（新长度必须正等于 `last_opcode_pos`、最后一条 reloc 不跨边界、无已绑定标签在边界之后）全部返回 `error.InvalidBytecode`；**不要求边界上有源槽**，且只丢 `temp_offset > new_code_len` 的槽——正好等于边界的那些留下来描述随后写在同一位置的替换指令。不碰 atom 账本。生产调用方三处：`getLValue` 撤掉 `get_array_el` / `get_super_value` 一字节 getter（`src/parser.zig:4442` / `:4450`）、可选链 delete 重写（`:5131`），以及本文件内的 `rewriteTrailingAtomOpAsPlain`（`src/compiler/builder.zig:853`）。

### `Builder.detachTail` (`src/compiler/builder.zig:1000`)

- **签名**：`pub fn detachTail(self: *Builder, mark: Snapshot) Error!DetachedSegment`。
- **作用**：把 `mark` 之后发出的尾巴剪成段。`mark` 必须在段内任何 emit/bind **之前** 拍。
- **实现**：校验长度与 reloc/source/control 落在段内。统计 `bound_offset > mark.code_len` 的 bind（等于 mark 的留下，同 rollback 边界规则）。**先分配**全部段 backing（OOM 则 builder 原样）。拷字节并把偏移改成段相对。unchain reloc、`ref_count--`。内部 bind 解绑并记入 `seg.binds`。builder 截回 mark，`last_opcode_pos = -1`。`label_len` **不动**。
- **所有权 / 错误 / 调用**：atom 所有权移出 ledger，不释放。调用方 `defer discardSegment`。消费者：classic-for update、class deferred-runtime。

### `Builder.spliceSegment` (`src/compiler/builder.zig:1141`)

- **签名**：`pub fn spliceSegment(self: *Builder, seg: *DetachedSegment) Error!void`。
- **作用**：在当前位置接回段，只把偏移加上新基址。LabelId 操作数不改写。
- **实现**：校验 reloc 严格递增、标签下标合法、bind 目标未绑定、control/source 单调。先 reserve 全部目的容量。拷 code/atoms，重绑 binds，平移 source/control，reloc 头插回链并可能标 backward。成功则 `freeSegmentBackings`（段被消费）。失败则段原样、仍归调用方。`invalidateLastOpcode`。
- **所有权 / 错误 / 调用**：atom 所有权回到 ledger。空段仍会使 last opcode 失效。

### `Builder.discardSegment` (`src/compiler/builder.zig:1276`)

- **签名**：`pub fn discardSegment(self: *Builder, seg: *DetachedSegment) void`。
- **作用**：不会 splice 的段（错误路径）：释放 backing。幂等。
- **实现**：`freeSegmentBackings`。
- **所有权 / 错误 / 调用**：parser 每个 detach 都配 `defer discardSegment`。只释放 backing，不逐项 unretain 段里的 atom（与 `deinit` 同一契约，由 AtomTable 生命周期覆盖）。

### `Builder.invalidateLastOpcode` (`src/compiler/builder.zig:1282`)

- **签名**：`pub fn invalidateLastOpcode(self: *Builder) void`。
- **作用**：控制流汇合：忘掉 last opcode，禁止 peephole 跨 join（qjs 在 label 处 `last_opcode_pos = -1`）。
- **实现**：`last_opcode_pos = -1`。
- **所有权 / 错误 / 调用**：一行赋值，不分配、无 error set、不改任何长度。它是「禁止 peephole 跨控制流汇合」的唯一开关，所以所有会制造汇合的地方都要调：`spliceSegment` 成功路径（`src/compiler/builder.zig:1339`）、parser 的 `emitterBindLabel` 与逗号表达式收尾等十余处（`src/parser.zig:3520` / `:3694` / `:3703` / `:3770` …）。

### `Builder.freeSegmentBackings` (`src/compiler/builder.zig:1286`)

- **签名**：`fn freeSegmentBackings(self: *Builder, seg: *DetachedSegment) void`。
- **作用**：释放段六张 backing 并把 `seg.* = .{}`。
- **实现**：len!=0 才 free。
- **所有权 / 错误 / 调用**：splice 成功与 discard 共用。

### `Builder.reserveCode` (`src/compiler/builder.zig:1296`)

- **签名**：`inline fn reserveCode(self: *Builder, need: usize) Error!void`。
- **作用**：为即将写入的 `need` 字节扩 code backing。
- **实现**：`code_len + need` 超 u32 → `BytecodeOverflow`。`reserve(u8, …, min_cap=16)`。
- **所有权 / 错误 / 调用**：`inline`，是所有 code 写入的唯一入口：先用 u64 算 `code_len + need`，超过 `maxInt(u32)` 直接 `error.BytecodeOverflow`（compact 流的硬上限），否则转 `reserve(u8, …, min_cap = 16)`，增长失败 `error.OutOfMemory`；两种失败都保证一个字节也没写。缓冲归 `self.memory`、`Builder.deinit` 释放。调用点是每个 `emit*`（1/2/3/4/5/6/7/11 字节各一处）与 `spliceSegment`。

### `expectRelocChain` (`src/compiler/builder.zig:1318`)

- **签名**：`fn expectRelocChain( b: *const Builder, label: LabelId, expected_offsets: []const u32, expected_kinds: []const labels.RelocKind, ) !void`。
- **作用**：测试：断言一条标签的 reloc 链与期望偏移/kind 一致，且下标严格递减、操作数写着该 LabelId。
- **实现**：`ref_count == 期望长度`，沿 `first_reloc` 走，每步 `reloc_index < previous_index`。
- **所有权 / 错误 / 调用**：builder 单测。`testing.expect` 失败即测挂。

### `s2g4OomScript` (`src/compiler/builder.zig:1793`)

- **签名**：`fn s2g4OomScript(allocator: std.mem.Allocator) !void`。
- **作用**：OOM 扫描脚本：构造带 jump/atom/scope-ref/source 的段，detach 后再 emit 一段，splice 回去，证明分配失败时仍可 cleanup。
- **实现**：intern 一个 atom，绑 `label_c`，发 u32/atom 立即数，snapshot，再发多条 jump、`emitScopeRefOpOwned`、atom ops、bind `label_b`、8 条 source，detach，再 40 条 interim op + jump/atom/source，splice，断言长度与 bind。
- **所有权 / 错误 / 调用**：`checkAllAllocationFailures` 驱动。`defer discardSegment` + `defer b.deinit()`。

---

## 覆盖核对

- 清单函数数: 43
- 本文标题覆盖: 43
- 未覆盖: 无
