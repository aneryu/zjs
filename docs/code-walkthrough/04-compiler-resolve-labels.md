# 04 — resolve_labels.zig：Stage 4 最终布局

QuickJS `resolve_labels`（quickjs.c:34796）的端口：单次前向走 + 重定位链 + comptime 可选 plain/short。**字节地址只在这里出现。** 输入是 S3 `ResolvedProduct`（操作数仍是 LabelId）。输出安装到 `Bytecode`：code、atom 操作数、pc2line。

`default_layout` 读 `build_options.zjs_compiler_layout`。配置签名钉的是这个声明。`.short` 生产；`.plain` 诊断。

## 文件级类型

- **`LayoutMode`**：`.plain` / `.short`。
- **`FinalReloc`**：S4 自己的链（`addr` 是输出操作数位置，`size` 1/2/4）。S3 的 RelocEntry 已清空。
- **`JumpSlot`**：每条发出的跳转：op/size/pos/label，audit 下还有发射时的 `canonical_identity`。
- **`BindEntry`（本文件）**：产物偏移主键 + `initially_referenced` + `match_barrier`。与 CFG 的输入坐标 BindEntry 不同。
- **`Resolver`**：输出缓冲、addr[]（标签→最终 PC 或 unbound）、jump_slots、融合状态、call/prop site 计数。

顺序：`initScratch` → `walk`（prologue + 指令 + 绑定点解析 reloc）→ `releaseConsumedProduct` → short 则 `relaxJumps` → audit → `validateFinal*` → `commit`。

---

### `bindLessThan` (`src/compiler/resolve_labels.zig:60`)

- **签名**：`fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool`。
- **作用**：S4 绑定表按产物 `bound_offset` 再 `label_index` 排序。
- **实现**：两级 `<`。
- **所有权 / 错误 / 调用**：`initScratch` heap sort。

### `decodeInstruction` (`src/compiler/resolve_labels.zig:75`)

- **签名**：`fn decodeInstruction(code: []const u8, position: u32) Error!Instruction`。
- **作用**：S3 流读者。共享 decode `headerAt(.s3)`。允许 lowered-direct 字节（S4 写者才选最终载体）。
- **实现**：失败变 InvalidBytecode。一条 `form_row` 加载，对齐 qjs 读一行 `opcode_info[op]`。
- **所有权 / 错误 / 调用**：walk / skip / match。最终校验用同一函数看输出（最终域 form 值即物理 id）。

### `opId` (`src/compiler/resolve_labels.zig:89`)

- **签名**：`inline fn opId(form: Form) u8`。
- **作用**：读者→写者缝：form 的最终域值就是物理 id。
- **实现**：`@intFromEnum`。F0c 迁移写者时只 grep 这里。
- **所有权 / 错误 / 调用**：`putShortCode`、jump 选择。

### `formOf` (`src/compiler/resolve_labels.zig:96`)

- **签名**：`inline fn formOf(op_id: u8) Form`。
- **作用**：缝的逆。回收 id 无 tag（invariant 5），assert claimed。
- **实现**：`@enumFromInt`。
- **所有权 / 错误 / 调用**：short 选择器。

### `readU16` (`src/compiler/resolve_labels.zig:126`)

- **签名**：`fn readU16(code: []const u8, position: u32) Error!u16`。
- **作用**：读 opcode 后 2 字节立即数（argc/槽）。
- **实现**：`position+1`。
- **所有权 / 错误 / 调用**：call / get_loc。

### `readU32At` (`src/compiler/resolve_labels.zig:132`)

- **签名**：`fn readU32At(code: []const u8, position: u32, delta: u32) Error!u32`。
- **作用**：读 `position+delta` 处 LE u32（LabelId 或 atom）。
- **实现**：越界失败。
- **所有权 / 错误 / 调用**：jump_label / probe_label / atom。

### `readI32` (`src/compiler/resolve_labels.zig:139`)

- **签名**：`fn readI32(code: []const u8, position: u32) Error!i32`。
- **作用**：读 opcode 后 i32。
- **实现**：push_i32。
- **所有权 / 错误 / 调用**：常数折叠。

### `validateProductMetadata` (`src/compiler/resolve_labels.zig:148`)

- **签名**：`fn validateProductMetadata(product: *const resolve_variables.ResolvedProduct) Error!void`。
- **作用**：走之前的廉价结构预检：slice、source 单调且行列>0、标签 bound 与 offset 一致、`first_reloc == no_reloc`。
- **实现**：每条入口都跑。主循环依赖排序 source 与一致绑定元数据。
- **所有权 / 错误 / 调用**：`runImpl`。

### `updateLabel` (`src/compiler/resolve_labels.zig:178`)

- **签名**：`fn updateLabel( product: *resolve_variables.ResolvedProduct, label_index: u32, delta: i32, ) Error!u32`。
- **作用**：S4 的 qjs `update_label`：折叠/死代码/穿线改 ref_count。
- **实现**：与 S3 同形状，改的是同一套产物槽。
- **所有权 / 错误 / 调用**：`findJumpTarget` 先 −1 再给最终目标 +1。

### `Resolver.deinit` (`src/compiler/resolve_labels.zig:282`)

- **签名**：`fn deinit(self: *Resolver) void`。
- **作用**：释放未提交的输出/reloc/addr/binds/jump_slots。若 `output_atoms_owned` 仍假，atom backing 释放且所有权留在 S3 ledger。
- **实现**：七张表。不安装到 Bytecode。
- **所有权 / 错误 / 调用**：`runImpl` defer。commit 成功后 capacity 已 0。

### `Resolver.releaseConsumedProduct` (`src/compiler/resolve_labels.zig:311`)

- **签名**：`fn releaseConsumedProduct(self: *Resolver) Error!void`。
- **作用**：证明 S4 输出 atom 是 S3 的保留子序列（可丢不可重排/发明），把这些引用从产物 ledger 挪走（置 null_atom），再 `releaseConsumedStreams`。
- **实现**：两遍扫描：先证明子序列，再转移。`output_atoms_owned = true`。错误路径输入 ledger 仍拥有一切。
- **所有权 / 错误 / 调用**：qjs 在 DynBuf 间拷贝 atom id 不改引用计数。必须在 walk 成功之后、commit 之前。

### `Resolver.initScratch` (`src/compiler/resolve_labels.zig:345`)

- **签名**：`fn initScratch(self: *Resolver, comptime layout: LayoutMode) Error!void`。
- **作用**：分配 addr[]（填 unbound）、排序产物绑定、按 `jump_size` 分配 JumpSlot、按 code_len+prologue 与 source/atom 上界预留输出。
- **实现**：`initially_referenced = slot.ref_count != 0`（屏障看输入拓扑，不看后来被折叠消耗的计数）。`refreshBindFrontier`。
- **所有权 / 错误 / 调用**：失败走 deinit。热走不几何增长 atom/source。

### `Resolver.growOutput` (`src/compiler/resolve_labels.zig:440`)

- **签名**：`noinline fn growOutput(self: *Resolver, need: usize) Error!void`。
- **作用**：输出码 backing 不够时几何增长。
- **实现**：`need > maxInt(u32)` 或 `output_len + need` 溢出 → `BytecodeOverflow`。否则 `builder.reserve(u8, …, min_cap=32)`。
- **所有权 / 错误 / 调用**：新块记在 `Resolver.memory`。失败时旧码不动。`ensureOutput` 热比较失败才进来。

### `Resolver.ensureOutput` (`src/compiler/resolve_labels.zig:455`)

- **签名**：`inline fn ensureOutput(self: *Resolver, need: usize) Error!void`。
- **作用**：输出码容量。
- **实现**：够则返回，否则 noinline grow。
- **所有权 / 错误 / 调用**：每条 append。

### `Resolver.growOutputSources` (`src/compiler/resolve_labels.zig:462`)

- **签名**：`noinline fn growOutputSources(self: *Resolver, need: usize) Error!void`。
- **作用**：pc2line 槽 backing 不够时几何增长。
- **实现**：同 `growOutput` 的 u32 溢出检查，然后 `builder.reserve(SourceLocSlot, …, min_cap=8)`。
- **所有权 / 错误 / 调用**：`ensureOutputSources` 的冷路径。`initScratch` 已按输入 source 条数预留上界；这里是防御未来 peephole 合成事件。

### `Resolver.ensureOutputSources` (`src/compiler/resolve_labels.zig:477`)

- **签名**：`inline fn ensureOutputSources(self: *Resolver, need: usize) Error!void`。
- **作用**：pc2line 槽容量。
- **实现**：同模式。
- **所有权 / 错误 / 调用**：`attachSource`。上界=输入 source 条数。

### `Resolver.appendByte` (`src/compiler/resolve_labels.zig:484`)

- **签名**：`inline fn appendByte(self: *Resolver, value: u8) Error!void`。
- **作用**：写一字节最终码。
- **实现**：ensure 1。
- **所有权 / 错误 / 调用**：所有发射。

### `v4Mask` (`src/compiler/resolve_labels.zig:503`)

- **签名**：`fn v4Mask() u8`。
- **作用**：融合 v4 隔离掩码缓存。
- **实现**：首次 `loadV4Mask`。
- **所有权 / 错误 / 调用**：诊断 `ZJS_FUSE_V4`。

### `loadV4Mask` (`src/compiler/resolve_labels.zig:510`)

- **签名**：`fn loadV4Mask() u8`。
- **作用**：读环境变量：空/`all` 全开，`none` 全关，逗号列表选 `push_0_or`/`sar_get_array_el`/`push_2_sar`/`get_loc8_push_2`。
- **实现**：`getenv`。默认 `v4_all`。
- **所有权 / 错误 / 调用**：仅 short 融合。`get_array_el_push_0` 已删。

### `v4On` (`src/compiler/resolve_labels.zig:526`)

- **签名**：`inline fn v4On(bit: u8) bool`。
- **作用**：该 v4 对是否启用。
- **实现**：掩码与。
- **所有权 / 错误 / 调用**：`noteFusionA`。

### `noteFusionA` (`src/compiler/resolve_labels.zig:542`)

- **签名**：`inline fn noteFusionA(self: *Resolver, opc: u8, pc: u32) void`。
- **作用**：记录刚发出的 A 及合法 B（最多 4 个），供下一条 `maybeFusePrev` O(1) 改写 A 的 opcode 字节。
- **实现**：switch：get_loc0→get_field，lt→if_false8，put_loc8→get_loc8，push_this→put_loc0，get_field2→call_method，get_loc2→get_field/get_field2，等。v4 对按掩码。
- **所有权 / 错误 / 调用**：不回看流。绑定点 `last_bound_output` 会挡住跨 join 融合。

### `maybeFusePrev` (`src/compiler/resolve_labels.zig:632`)

- **签名**：`inline fn maybeFusePrev(self: *Resolver, b: u8) void`。
- **作用**：若当前输出正好接在 last_pc+last_sz，且不是绑定点，且 b 匹配 fuse_b/b2/b3/b4，则把 A 的 opcode 改成融合 id。
- **实现**：只改一个字节；B 的发射者仍写出自己的操作数（或融合处理器吃 leftover）。
- **所有权 / 错误 / 调用**：short only。

### `appendRaw` (`src/compiler/resolve_labels.zig:646`)

- **签名**：`inline fn appendRaw(self: *Resolver, bytes: []const u8) Error!void`。
- **作用**：拷一段字节到输出。
- **实现**：memcpy。
- **所有权 / 错误 / 调用**：`copyDefault` 非短槽臂。

### `appendU16` (`src/compiler/resolve_labels.zig:654`)

- **签名**：`inline fn appendU16(self: *Resolver, value: u16) Error!void`。
- **作用**：LE u16。
- **实现**：ensure 2。
- **所有权 / 错误 / 调用**：宽槽、argc。

### `appendI16` (`src/compiler/resolve_labels.zig:661`)

- **签名**：`inline fn appendI16(self: *Resolver, value: i16) Error!void`。
- **作用**：LE i16（goto16 已解析目标）。
- **实现**：ensure 2。
- **所有权 / 错误 / 调用**：后向/已绑定短跳。

### `appendU32` (`src/compiler/resolve_labels.zig:668`)

- **签名**：`inline fn appendU32(self: *Resolver, value: u32) Error!void`。
- **作用**：LE u32 占位或 atom。
- **实现**：ensure 4。
- **所有权 / 错误 / 调用**：未解析跳转写 0 再 addReloc。

### `appendI32` (`src/compiler/resolve_labels.zig:675`)

- **签名**：`inline fn appendI32(self: *Resolver, value: i32) Error!void`。
- **作用**：LE i32 相对位移或 push_i32。
- **实现**：ensure 4。
- **所有权 / 错误 / 调用**：已绑定宽跳。

### `appendOutputAtom` (`src/compiler/resolve_labels.zig:682`)

- **签名**：`fn appendOutputAtom(self: *Resolver, atom_id: core.atom.Atom) Error!void`。
- **作用**：把借入的 S3 atom id 记进输出 ledger（不 retain）。
- **实现**：len 不得超过预留 capacity。
- **所有权 / 错误 / 调用**：keep=true 的消费。

### `consumeAtomsRange` (`src/compiler/resolve_labels.zig:691`)

- **签名**：`fn consumeAtomsRange( self: *Resolver, start: u32, end: u32, keep_atom_position: ?u32, ) Error!void`。
- **作用**：peephole 跳过的区间：前进 atom 游标，可选保留其中一个位置的 atom。
- **实现**：逐指令 decode；编码必须等于 ledger。
- **所有权 / 错误 / 调用**：被删尾巴。普通单指令用 `consumeInstructionAtom` 以免非 atom opcode 二次解码。

### `consumeInstructionAtom` (`src/compiler/resolve_labels.zig:729`)

- **签名**：`fn consumeInstructionAtom( self: *Resolver, position: u32, instruction: Instruction, keep: bool, ) Error!void`。
- **作用**：主循环已解码的指令：有 atom 则匹配 ledger，keep 则 appendOutputAtom。
- **实现**：无 atom 立即返回。
- **所有权 / 错误 / 调用**：qjs 的 atom 就在那条指令上，不必重扫。

### `absorbSources` (`src/compiler/resolve_labels.zig:745`)

- **签名**：`fn absorbSources(self: *Resolver, limit: u32) void`。
- **作用**：推进 source_cursor 到 `temp_offset < limit`。
- **实现**：不挂输出；`attachSource` 才发布。
- **所有权 / 错误 / 调用**：每条指令前 `absorbSources(position+1)` 吃落在本指令上的事件。

### `absorbSourcesAtEnd` (`src/compiler/resolve_labels.zig:753`)

- **签名**：`fn absorbSourcesAtEnd(self: *Resolver) void`。
- **作用**：流末：`temp_offset <= code_len` 的尾事件。
- **实现**：含等于 code_len。
- **所有权 / 错误 / 调用**：walk 结束。随后游标必须耗尽。

### `hasInputSourceAt` (`src/compiler/resolve_labels.zig:761`)

- **签名**：`fn hasInputSourceAt(self: *const Resolver, input_pos: u32) bool`。
- **作用**：该产物偏移是否有 source（挡住某些折叠，对齐 qjs 行号字节）。
- **实现**：二分。
- **所有权 / 错误 / 调用**：`isSwitchDispatchBridgeAt`、`deadSwitchTrampolineCanReachLabel`、`findJumpTarget` 的 drop 串。

### `attachSource` (`src/compiler/resolve_labels.zig:780`)

- **签名**：`inline fn attachSource(self: *Resolver) Error!void`。
- **作用**：qjs `add_pc2line_info`（34547）。把已吸收事件挂到当前 `output_len`。连续相等行列去重。
- **实现**：一条内联；多条 `attachSourceSlow`。peephole 跨多指令时仍把变迁挂在替换指令 PC。
- **所有权 / 错误 / 调用**：每条实际发出的指令前。

### `Resolver.attachSourceSlow` (`src/compiler/resolve_labels.zig:812`)

- **签名**：`noinline fn attachSourceSlow(self: *Resolver) Error!void`。
- **作用**：peephole 跨多条指令时，把已吸收的一串 source 事件挂到当前 `output_len`。
- **实现**：断言 pending≠0，一次 `ensureOutputSources(pending_count)`。循环 `source_attach_cursor .. source_cursor`：相等行列跳过（`last_attached_source.eql`），否则写 `{pc=output_len, line, col}` 并更新 last。
- **所有权 / 错误 / 调用**：不发明新 source 事件。`attachSource` 单条内联，多条才进来。容量失败 → `BytecodeOverflow` / OOM。

### `attachInputSourceRangeAt` (`src/compiler/resolve_labels.zig:839`)

- **签名**：`fn attachInputSourceRangeAt( self: *Resolver, start: u32, end: u32, output_pc: u32, ) Error!void`。
- **作用**：把已消费的输入 source 子区间挂到**稍后**的输出 PC。typeof-string 折叠：被吃掉的 push_atom_value 的源映到替换测试之后；其后 compare/branch 标记向后映因而不发布。对齐 legacy 有序契约，不物化旧 PC。
- **实现**：输出必须单调。相等行列 skip。
- **所有权 / 错误 / 调用**：walkLateArm 的 typeof 折叠两处（`strict_eq`/`eq` 臂与 `if_false` 臂）。

### `lowerBoundBind` (`src/compiler/resolve_labels.zig:870`)

- **签名**：`fn lowerBoundBind(self: *const Resolver, position: u32) usize`。
- **作用**：绑定表按 `bound_offset` 的下界。
- **实现**：二分。
- **所有权 / 错误 / 调用**：`hasBindInRange`、switch 谓词。

### `hasBindInRange` (`src/compiler/resolve_labels.zig:883`)

- **签名**：`fn hasBindInRange(self: *const Resolver, start: u32, end: u32) bool`。
- **作用**：候选范围内有「顺序匹配屏障」则拒绝 peephole。绝对 PC 补丁目标丢光引用后透明；显式 parser-label 与「曾经被引用过」的相位-2 目标即使 ref 现为 0 仍挡。
- **实现**：读 `initially_referenced || match_barrier`，**不看** `dead_skipped`。
- **所有权 / 错误 / 调用**：`matchSeq` / `matchReturnAfter`。qjs 的 OP_label 字节。

### `readIndex` (`src/compiler/resolve_labels.zig:904`)

- **签名**：`fn readIndex(self: *const Resolver, position: u32) Error!u16`。
- **作用**：读槽/argc 索引，宽度来自 Header。
- **实现**：1 或 2 字节。
- **所有权 / 错误 / 调用**：pattern 的 idx 约束。

### `matchReturnAfter` (`src/compiler/resolve_labels.zig:916`)

- **签名**：`fn matchReturnAfter(self: *const Resolver, start: u32) Error!?u32`。
- **作用**：qjs `code_match(OP_return)`（34947）：跳过 line_num，要求 return。call 与 return 之间的活标签挡住。
- **实现**：`hasBindInRange`。
- **所有权 / 错误 / 调用**：`call_method` 无条件折 `tail_call_method`。try/finally 已把 return 改成 gosub，对不上。

### `matchTailReturnAfterStrict` (`src/compiler/resolve_labels.zig:942`)

- **签名**：`fn matchTailReturnAfterStrict(self: *const Resolver, start: u32) Error!?u32`。
- **作用**：严格函数 PTC：plain `call` 后面控制流可证到达 `return`（直落或最多 8 个 goto）。改写保留匹配指令（tail_call + 幸存 return stub），范围内跳转目标仍有效。
- **实现**：sloppy **从不**走此匹配器（栈语义对齐 QuickJS 每调用一帧）。条件表达式臂汇合到共享 bound return，binds 不拒绝。
- **所有权 / 错误 / 调用**：LIMITATIONS.md Proper Tail Calls。zjs 严格 plain tail 复用调用者帧，相对 pinned QuickJS 的分叉。

### `matchSeq` (`src/compiler/resolve_labels.zig:974`)

- **签名**：`fn matchSeq( self: *const Resolver, start: u32, tokens: []const PatternToken, ) Error!?SeqMatch`。
- **作用**：qjs `code_match`（33881）。source 已在旁表。范围内任何屏障 bind 拒绝，如同 OP_label。
- **实现**：最多 8 token；每 token 一组可选 form + 可选 idx。返回 end 与前两个 token 的指令位置（操作数由调用方按 `operand_off` 偏移读）。
- **所有权 / 错误 / 调用**：put-get 折叠、typeof、nullish、dup-put-drop 等。

### `addReloc` (`src/compiler/resolve_labels.zig:1019`)

- **签名**：`fn addReloc(self: *Resolver, label_index: u32, addr_value: u32, size: u8) Error!void`。
- **作用**：给尚未发出目标的标签挂一条最终 reloc（头插）。
- **实现**：`reloc_len == no_reloc` 溢出。`slot.first_reloc` 现为 S4 链。
- **所有权 / 错误 / 调用**：前向跳转。绑定点 `processBindsAt` 走链 `writeRelative`。

### `writeRelative` (`src/compiler/resolve_labels.zig:1041`)

- **签名**：`fn writeRelative(self: *Resolver, operand_pos: u32, size: u8, diff: i64) Error!void`。
- **作用**：把相对位移写入已发出的操作数。
- **实现**：size 1/2/4；超出该宽度 → InvalidBytecode 或 BytecodeOverflow（i32）。
- **所有权 / 错误 / 调用**：绑定解析与 `relaxJumps` 补丁。

### `retireSpannedDeadBinds` (`src/compiler/resolve_labels.zig:1082`)

- **签名**：`fn retireSpannedDeadBinds(self: *Resolver, position: u32) Error!void`。
- **作用**：peephole 跨过的紧凑 bind 若已无引用，当作 skipDeadCode 消费。活的或已解析的内部目标 fail-closed。
- **实现**：`bound_offset < position` 且 ref/reloc/addr/barrier 全空才 skip。`skipDeadCode` 若发现 cursor 落后于 start 也失败。
- **所有权 / 错误 / 调用**：`processBindsAtCold` 先跑。

### `refreshBindFrontier` (`src/compiler/resolve_labels.zig:1102`)

- **签名**：`inline fn refreshBindFrontier(self: *Resolver) void`。
- **作用**：`next_bind_offset` 或 maxInt。
- **实现**：对齐 S3 前沿。
- **所有权 / 错误 / 调用**：无身份的指令只付一次比较。

### `processBindsAt` (`src/compiler/resolve_labels.zig:1116`)

- **签名**：`inline fn processBindsAt(self: *Resolver, position: u32) Error!void`。
- **作用**：qjs OP_label（34911-34939）。`position < next_bind_offset` 证明后面两个循环都是空的。
- **实现**：命中则 `processBindsAtCold`：retire spanned；等于 position 的未 skip 标签 `addr = output_len`，走 reloc 链写相对位移，清空 first_reloc。
- **所有权 / 错误 / 调用**：每条指令前与 code_len。重复绑定同一 label 的 addr 失败。

### `processBindsAtCold` (`src/compiler/resolve_labels.zig:1121`)

- **签名**：`noinline fn processBindsAtCold(self: *Resolver, position: u32) Error!void`。
- **作用**：`processBindsAt` 的冷半边：消费 `bound_offset == position` 的身份表项，把标签绑到当前 `output_len` 并冲 reloc 链。
- **实现**：先 `retireSpannedDeadBinds(position)`。然后 while `bind_cursor` 未尽且当前 bind 的 `bound_offset == position`：cursor++；`dead_skipped` 则 continue；`label_index` 越界或 `addr` 已非 `unbound` → `InvalidBytecode`（重复绑定）。否则 `addr[label_index] = output_len`，记 `last_bound_output`。沿 `slot.first_reloc` 走：每条 `writeRelative(reloc.addr, size, output_len - reloc.addr)`，`walked`/`reloc_index` 越界同样 fail-closed。写完把 `first_reloc` 清成 `no_reloc`。最后 `refreshBindFrontier`。
- **所有权 / 错误 / 调用**：只改 Resolver 的 addr/reloc/cursor；错误是 `InvalidBytecode`（坏码）或 `writeRelative` 的溢出。热路径 `processBindsAt` 在 `position < next_bind_offset` 时整段跳过。

### `appendJumpSlot` (`src/compiler/resolve_labels.zig:1153`)

- **签名**：`fn appendJumpSlot( self: *Resolver, op_id: u8, size: u8, operand_pos: u32, label_index: u32, ) Error!u32`。
- **作用**：登记一条最终跳转供 relax 与审计。
- **实现**：audit 下立刻记 canonical_identity（发射时的边界代表）。超过 jump_size 失败。
- **所有权 / 错误 / 调用**：`emitHasLabel` / `emitDynEnvProbe`。pos 随后可能改成真正操作数位置。

### `labelsShareBindOffset` (`src/compiler/resolve_labels.zig:1183`)

- **签名**：`fn labelsShareBindOffset(self: *const Resolver, left: u32, right: u32) Error!bool`。
- **作用**：两 LabelId 绑在同一临时偏移 = 同一程序点。qjs `code_has_label` 比编号，因为它把 dispatch 回补到单一 default；v2 禁止补 PC，switch 用两个 id 共绑。
- **实现**：都 bound 且 offset 相等。
- **所有权 / 错误 / 调用**：`codeHasLabel` 的后继 goto 情况。

### `isSwitchDispatchBridgeAt` (`src/compiler/resolve_labels.zig:1222`)

- **签名**：`fn isSwitchDispatchBridgeAt(self: *const Resolver, position: u32) Error!bool`。
- **作用**：身份版 switch default 桥：无源、后向 `goto DEFAULT_BODY`、只经本 walk 已消费的无匹配 dispatch 绑定进入。必须对 qjs:34968 next-label 检查隐身，否则 `if_false NO_MATCH; goto BREAK` 会被 invert 错。
- **实现**：三特征都收窄。去掉任一条会让大量 bench 回退。epilogue 已改用 `retargetLabelRefs`，本谓词留下当折叠抑制器（去掉只会加宽折叠）。
- **所有权 / 错误 / 调用**：goto 臂。

### `codeHasLabel` (`src/compiler/resolve_labels.zig:1245`)

- **签名**：`fn codeHasLabel(self: *const Resolver, position: u32, label_index: u32) Error!bool`。
- **作用**：qjs:34633。旁表 bind 替换相邻 OP_label；紧随的 goto 仍按字节看（共绑 offset）。
- **实现**：槽 offset==position，或该处 goto 的目标与 label 共绑。
- **所有权 / 错误 / 调用**：goto 变成 fallthrough。

### `deadSwitchTrampolineCanReachLabel` (`src/compiler/resolve_labels.zig:1271`)

- **签名**：`fn deadSwitchTrampolineCanReachLabel( self: *const Resolver, start: u32, label_index: u32, ) Error!bool`。
- **作用**：从后方看同一窄形状：`goto TARGET` 后只有现已无引用的 dispatch 蹦床。不推广到任意死区间（legacy 故意保留某些 goto，尤其常数假 eval 汇合）。带 parser source 的循环回边必须留 CFG 边。
- **实现**：start 无 source；start 处是一条目标在前方的后向 goto，其结束位置正好等于 slot.bound_offset 且那里 `codeHasLabel`；中间未 skip 的 bind 必须全部零引用且无 match_barrier。
- **所有权 / 错误 / 调用**：`handleGoto`。单测直接构造该形状。

### `findJumpTarget` (`src/compiler/resolve_labels.zig:1321`)

- **签名**：`fn findJumpTarget( self: *Resolver, label0: u32, out_op: *Form, ) Error!u32`。
- **作用**：qjs:34661。先 −1 原边，沿 goto 最多 10 跳；drop 串后若是 return_undef 则记录该 form。环则恢复原边。最后给最终标签 +1。
- **实现**：故意没有 line 输出参数（qjs 唯一 goto 调用方也不应用捕获的行）。drop 后 source 挡住穿 return（v2 显式 `hasInputSourceAt`）。
- **所有权 / 错误 / 调用**：goto 穿线、折叠分支目标。

### `findFoldedBranchTarget` (`src/compiler/resolve_labels.zig:1386`)

- **签名**：`fn findFoldedBranchTarget(self: *Resolver, label_index: u32) Error!u32`。
- **作用**：生产者 peephole 吃掉的条件边，走同一套 `find_jump_target` 引用计数事务。
- **实现**：忽略 out_op。
- **所有权 / 错误 / 调用**：nullish/typeof 折叠在死代码可达性决定之前。

### `skipDeadCode` (`src/compiler/resolve_labels.zig:1393`)

- **签名**：`fn skipDeadCode(self: *Resolver, start: u32) Error!u32`。
- **作用**：qjs:34112。吞不可达 S3 指令，原子/源从旁表消费，死标签保持 unresolved。
- **实现**：活 bind（ref>0）整组留下并返回；否则整组 dead_skipped。jump/probe −1 ref。bind_cursor 不得落后于 start。
- **所有权 / 错误 / 调用**：goto 发出后、return 折叠后。

### `putShortCodeSize` (`src/compiler/resolve_labels.zig:1466`)

- **签名**：`fn putShortCodeSize(comptime layout: LayoutMode, op_id: u8, idx: u16) u32`。
- **作用**：容量与发射用同一选择器，大小来自 form_row，没有第二架梯子。
- **实现**：short 且有短形式则短 size，否则宽 size。
- **所有权 / 错误 / 调用**：prologue 精确预留。

### `specialObjectSize` (`src/compiler/resolve_labels.zig:1478`)

- **签名**：`fn specialObjectSize(comptime layout: LayoutMode, slot: i32) Error!u32`。
- **作用**：`special_object` + put_loc 短/宽 的字节数。
- **实现**：2 + putShortCodeSize(put_loc, slot)。
- **所有权 / 错误 / 调用**：`functionPrologueSize`。

### `functionPrologueSize` (`src/compiler/resolve_labels.zig:1486`)

- **签名**：`fn functionPrologueSize(self: *const Resolver, comptime layout: LayoutMode) Error!u32`。
- **作用**：与 `emitFunctionPrologue` 同一布局决策的精确字节数。
- **实现**：home_object / this_active_func / new_target / this（派生 ctor 3 字节 set_loc_uninitialized）/ arguments / func_var / var_object / arg_var_object。
- **所有权 / 错误 / 调用**：无 fd 返回 0。参数捕获故意不在此（zjs finalization）。

### `putShortCode` (`src/compiler/resolve_labels.zig:1518`)

- **签名**：`fn putShortCode( self: *Resolver, comptime layout: LayoutMode, op_id: u8, idx: u16, ) Error!void`。
- **作用**：qjs:34737 + zjs call0..3 以外的槽缩短。call/tail_call 禁止走这里（payload 是 cache id 不是槽）。
- **实现**：短形式：maybeFusePrev、append opcode、size==2 再 append idx 字节、noteFusionA。否则 opcode+u16。
- **所有权 / 错误 / 调用**：prologue 与 copyDefault 槽族。

### `nextCallSiteIndex` (`src/compiler/resolve_labels.zig:1609`)

- **签名**：`fn nextCallSiteIndex(self: *Resolver) u8`。
- **作用**：按发射序分配 call cache_idx；满 255 后用 no_cache。
- **实现**：`call_sites_emitted++`。
- **所有权 / 错误 / 调用**：FunctionBytecode 得到 `min(sites,255)` 槽。

### `callSiteCount` (`src/compiler/resolve_labels.zig:1619`)

- **签名**：`fn callSiteCount(self: *const Resolver) u16`。
- **作用**：commit 时写入 `function.call_site_count`。
- **实现**：min(emitted, 255)。
- **所有权 / 错误 / 调用**：`*const` 只读计数，不分配、无 error set。唯一调用方是 commit（`src/compiler/resolve_labels.zig:3679`）写 `function.call_site_count`——这个数决定 FunctionBytecode 分配多少 W1 call-site 缓存槽，所以饱和到 255 意味着多出来的站点共用 `no_cache_idx` 而不是越界。注意 `src/tests/parser.zig:3508` 的 `child.callSiteCount()` 是 FunctionBytecode 上的同名读数（`src/bytecode.zig:4331`），不是本函数。

### `nextPropSiteIndex` (`src/compiler/resolve_labels.zig:1557`)

- **签名**：`fn nextPropSiteIndex(self: *Resolver) u8`。
- **作用**：W1 属性站点 cache_idx，同样 0..254 / 255=no_cache。
- **实现**：`prop_sites_emitted++`。
- **所有权 / 错误 / 调用**：get_field/get_field2/put_field 及拥有 atom 的融合形式。融合只改已走过本臂的 opcode 字节，站点不双计。

### `propSiteCount` (`src/compiler/resolve_labels.zig:1567`)

- **签名**：`fn propSiteCount(self: *const Resolver) u16`。
- **作用**：commit 写 `function.prop_site_count`。
- **实现**：min(emitted, 255)。
- **所有权 / 错误 / 调用**：同上：`*const` 只读、不分配、无 error set；唯一调用方 commit（`src/compiler/resolve_labels.zig:3680`）写 `function.prop_site_count`，决定 W1 属性缓存槽数，饱和值 255 即 `PropSiteCache.no_cache_idx`。

### `putCallCode` (`src/compiler/resolve_labels.zig:1574`)

- **签名**：`fn putCallCode( self: *Resolver, comptime layout: LayoutMode, op_id: u8, argc: u16, ) Error!void`。
- **作用**：plain-call 族最终写者。短 `call0..3` 只带 cache 字节；宽形式 argc:u16 + idx:u8。
- **实现**：assert call 或 tail_call。`selectSlotShortForm` 用 argc 选短形式。
- **所有权 / 错误 / 调用**：TCO 折叠与 copyDefault `.call`。

### `pushShortInt` (`src/compiler/resolve_labels.zig:1592`)

- **签名**：`fn pushShortInt( self: *Resolver, comptime layout: LayoutMode, value: i32, ) Error!void`。
- **作用**：qjs:34715。plain 一律 push_i32。short 走 `selectPushIntForm`（含 zjs `push_minus1`），否则 i8/i16/i32。
- **实现**：push_0/2 记 fusion A；push_i8 可与 add 融合。
- **所有权 / 错误 / 调用**：walk 的 push_i32 臂。

### `checkedSlotIndex` (`src/compiler/resolve_labels.zig:1630`)

- **签名**：`fn checkedSlotIndex(value: i32) Error!u16`。
- **作用**：fd 里的 i32 槽下标收成 u16。
- **实现**：<0 或 >maxInt(u16) 失败。
- **所有权 / 错误 / 调用**：prologue。

### `emitSpecialObject` (`src/compiler/resolve_labels.zig:1636`)

- **签名**：`fn emitSpecialObject( self: *Resolver, comptime layout: LayoutMode, subtype: u8, slot: i32, ) Error!void`。
- **作用**：`special_object` + put_loc 到给定槽。
- **实现**：subtype 字节 + putShortCode。
- **所有权 / 错误 / 调用**：home_object / current_function / new_target / var_object。

### `emitFunctionPrologue` (`src/compiler/resolve_labels.zig:1649`)

- **签名**：`fn emitFunctionPrologue(self: *Resolver, comptime layout: LayoutMode) Error!void`。
- **作用**：qjs:34833-34896，对齐 legacy emitFunctionPrologue。无 fd 则返回。
- **实现**：派生 ctor：`set_loc_uninitialized`+u16（无短形式）。否则 `push_this` + put_loc（可融 push_this_put_loc0）。arguments：strict 或非简单形参用 unmapped subtype。
- **所有权 / 错误 / 调用**：walk 第一条。参数捕获不在此。

### `shortJumpOp` (`src/compiler/resolve_labels.zig:1707`)

- **签名**：`fn shortJumpOp(op_id: u8) Error!u8`。
- **作用**：宽条件/goto → 窄 8 位形式。
- **实现**：`selectJumpForm(..., .narrow)`。comptime 断言 if_* 没有 16 位档。
- **所有权 / 错误 / 调用**：`emitHasLabel`、`relaxJumps`。

### `emitHasLabel` (`src/compiler/resolve_labels.zig:1713`)

- **签名**：`fn emitHasLabel( self: *Resolver, comptime layout: LayoutMode, input_position: u32, initial_next: u32, op_id: u8, label_index: u32, ) Error!u32`。
- **作用**：发出一条带标签的跳转。goto 先 skipDeadCode。short 下按估计/已知 diff 选 goto8/if_*8/goto16 或宽 5 字节。
- **实现**：未绑定目标：占位 0 + addReloc。已绑定：立即写相对。前向估计 `bound_offset - input_position - 1`：<128 选 if_false8/if_true8/goto8，<32768 且是 goto 选 goto16。if_false8 可与前一条 lt/eq 融合。返回 position_next。
- **所有权 / 错误 / 调用**：未 bound 且 addr unbound → 损坏。

### `putFamily` (`src/compiler/resolve_labels.zig:1819`)

- **签名**：`fn putFamily(form: Form) ?SlotFamily`。
- **作用**：put_loc/arg/var_ref/put_loc_check 对应的 get/put/set 三元组。
- **实现**：switch。
- **所有权 / 错误 / 调用**：dup-put-get / put-get 折叠。

### `isShortSlotFamily` (`src/compiler/resolve_labels.zig:1837`)

- **签名**：`fn isShortSlotFamily(form: Form) bool`。
- **作用**：copyDefault 是否走 putShortCode。
- **实现**：loc/arg/var_ref 的 get/put/set。
- **所有权 / 错误 / 调用**：check 族不在此（走 copy 或 putFamily 折叠）。

### `copyDefault` (`src/compiler/resolve_labels.zig:1844`)

- **签名**：`fn copyDefault( self: *Resolver, comptime layout: LayoutMode, position: u32, instruction: Instruction, ) Error!void`。
- **作用**：默认发射：call→putCallCode，短槽→putShortCode，否则 memcpy 并填 cache_idx，short 下 noteFusionA / maybeFusePrev。
- **实现**：call_method 族 output[pc+3]；atom_cache_u8 族 output[pc+5]。
- **所有权 / 错误 / 调用**：keep atom。

### `emitRawInstruction` (`src/compiler/resolve_labels.zig:1896`)

- **签名**：`fn emitRawInstruction( self: *Resolver, position: u32, instruction: Instruction, ) Error!void`。
- **作用**：不缩短、不融合，原样拷贝。
- **实现**：attachSource + appendRaw + consume atom。
- **所有权 / 错误 / 调用**：必须保持宽形式的指令。

### `emitFinalCarrier` (`src/compiler/resolve_labels.zig:1914`)

- **签名**：`fn emitFinalCarrier( self: *Resolver, position: u32, instruction: Instruction, comptime form: Form, ) Error!void`。
- **作用**：C0 合同 3：降低流携带 form 的直接 id 直到这里；唯一选择最终编码的点，来自 `finalEncodingOf`（carrier+tag）。
- **实现**：两字节。无容量侧孪生可漂移。
- **所有权 / 错误 / 调用**：walkLateArm 的 lowered-direct 居民。

### `handleGoto` (`src/compiler/resolve_labels.zig:1927`)

- **签名**：`fn handleGoto( self: *Resolver, comptime layout: LayoutMode, input_position: u32, initial_next: u32, initial_label: u32, ) Error!u32`。
- **作用**：goto：穿线到最终标签；下一指令已是该标签则变成 fallthrough；目标是 return/throw 则直接发终结；死 switch 蹦床则 skip 到 live 边界。
- **实现**：`findJumpTarget`。否则 `emitHasLabel(goto)`。
- **所有权 / 错误 / 调用**：常数测试真分支也复用。

### `handleConstantTest` (`src/compiler/resolve_labels.zig:1964`)

- **签名**：`fn handleConstantTest( self: *Resolver, comptime layout: LayoutMode, input_position: u32, value: bool, match: SeqMatch, ) Error!u32`。
- **作用**：`push_true/false` + if_* → 条件成立当 goto，否则删边 −1 ref。
- **实现**：`value == (branch == if_true)` 决定。
- **所有权 / 错误 / 调用**：吸收 match 区间 source。

### `emitDynEnvProbe` (`src/compiler/resolve_labels.zig:1986`)

- **签名**：`fn emitDynEnvProbe( self: *Resolver, position: u32, position_next: u32, op_id: u8, ) Error!void`。
- **作用**：qjs:35099 atom_label 族（现统一 dyn_env_probe）：穿线 done 标签，写 atom + 相对/reloc + kind 字节。
- **实现**：`findJumpTarget` 探针标签。操作数在 atom 之后。
- **所有权 / 错误 / 调用**：keep 该指令 atom。

### `walk` (`src/compiler/resolve_labels.zig:2028`)

- **签名**：`fn walk(self: *Resolver, comptime layout: LayoutMode) Error!void`。
- **作用**：S4 主前向走：prologue，然后逐 S3 指令。
- **实现**：每步 processBindsAt、absorbSources(pos+1)、decode。call/call_method 匹配 return→tail_*（严格 plain call 才 PTC；方法尾仍 push）。其余早期臂：goto、gosub/catch、if_true/if_false（穿线、反转、两臂共落一点折成 drop）、dyn_env_probe、drop+return_undef、null/undefined/push_true/push_false/push_i32/push_bigint_i32 的常数与比较折叠、push_const/fclosure 短形式、get_field→get_length、push_atom_value、to_propkey/set_name_computed 的 final carrier。其它进 `walkLateArm`。结束 processBindsAt(code_len)、吸收尾 source、游标耗尽、所有 first_reloc 必须空（前向 reloc 已在绑定点写完）。
- **所有权 / 错误 / 调用**：`runImpl`。tail_call 留下随后 return 作共享 stub（H3）。

### `walkLateArm` (`src/compiler/resolve_labels.zig:2507`)

- **签名**：`fn walkLateArm( self: *Resolver, comptime layout: LayoutMode, position: u32, instruction: Instruction, position_next: *u32, ) Error!void`。
- **作用**：冷/长模式：insert2+put_field+drop 折成 put_field、dup+put_* 折成 set_*、get_loc 的 inc_loc/dec_loc/add_loc 族、get_arg/get_var_ref 槽缩短、put_* 家族的 put/set 折叠、post_inc/post_dec 的 store 折叠、typeof 对 `undefined`/`function` 的 ext0 测试，其余落 copyDefault。
- **实现**：源码按 qjs 行号分臂（35352 起至 35587）。typeof 折叠用 `attachInputSourceRangeAt` 保持 legacy 源顺序。
- **所有权 / 错误 / 调用**：`matchSeq` 内的 `hasBindInRange` 屏障挡住跨屏障 bind 的折叠；被吃掉区间的 atom 由 `consumeAtomsRange` 消费。

### `relaxJumps` (`src/compiler/resolve_labels.zig:2874`)

- **签名**：`fn relaxJumps(self: *Resolver) Error!void`。
- **作用**：qjs:35599-35673 有界跳转再压缩。故意保留 QuickJS 的二次尾巴移动。
- **实现**：对每条 JumpSlot，若 diff 现进 i8/i16，改 opcode、memmove 尾巴、`output_len -= delta`，平移 addr[]、后续 jump.pos、source.pc（谓词都是 `> jump.pos`）。if_false8 还可把前一条 lt/eq 收成 cmp/eq_if_false8。有压缩则重写所有相对操作数。audit 计窗口内 source/label。
- **所有权 / 错误 / 调用**：仅 `.short`。两数组独立平移，唯一分歧来源是事件落在被删字节严格内部。

### `isLabelAddress` (`src/compiler/resolve_labels.zig:2974`)

- **签名**：`fn isLabelAddress(self: *const Resolver, pc: u32) bool`。
- **作用**：该输出 PC 是否某标签最终地址（挡住 relax 时跨标签融合 lt→cmp_if_false8）。
- **实现**：线性扫 addr[]。
- **所有权 / 错误 / 调用**：`relaxJumps` 内。

### `validateFinalSources` (`src/compiler/resolve_labels.zig:2981`)

- **签名**：`fn validateFinalSources(self: *const Resolver) Error!void`。
- **作用**：输出 source.pc < output_len 且非递减。
- **实现**：packed 路径保留这步（源在融合码校验之前被消费）。
- **所有权 / 错误 / 调用**：`validateFinalOutput` 或 packed 分支。

### `installSourceLocsNoFail` (`src/compiler/resolve_labels.zig:2993`)

- **签名**：`fn installSourceLocsNoFail( self: *Resolver, function: *bytecode.Bytecode, owned: []SourceLocSlot, owned_capacity: usize, ) void`。
- **作用**：无分配替换 `function.source_loc_slots`，释放旧 backing。
- **实现**：断言 owned.len≤capacity。
- **所有权 / 错误 / 调用**：commit 最后一步，不可能失败。

### `commit` (`src/compiler/resolve_labels.zig:3012`)

- **签名**：`fn commit(self: *Resolver) void`。
- **作用**：唯一所有权转移点。全部无分配、无失败，故无半安装可逃逸。
- **实现**：写 call/prop site 计数；`installCodeWithCapacity` / `installAtomOperandsWithCapacity` / `installSourceLocsNoFail`。resolver 字段掏空以免 defer deinit 双释。
- **所有权 / 错误 / 调用**：`output_atoms_owned` 清回 false：atom 现归 Bytecode。

### `run` (`src/compiler/resolve_labels.zig:3042`)

- **签名**：`pub fn run( comptime layout: LayoutMode, function: *bytecode.Bytecode, fd: ?*const bytecode.function_def.FunctionDef, product: *resolve_variables.ResolvedProduct, ) Error!void`。
- **作用**：S3 产物上的最终发射：product 的 label-slot ref_count 与 first_reloc 头按 qjs 方式就地改写；所有可失败的输出工作在 `Bytecode` 的单次无分配所有权转移提交点之前完成。
- **实现**：核对 function/fd/product 共用 memory/atoms → `validateProductMetadata` → 建 `Resolver`（`initScratch(layout)`）→ `walk(layout)` → `releaseConsumedProduct` → `.short` 布局时 `relaxJumps` → `validateFinalSources`（码/atom/var-ref 的证明留给 packed finalizer 的一次融合遍历，源槽在那之前已被消费所以在这里证）→ `commit`。
- **所有权 / 错误 / 调用**：`compileFunction`、S4 单测。

### `ResolveLabelsTestHarness.init` (`src/compiler/resolve_labels.zig:3090`)

- **签名**：`fn init(harness: *ResolveLabelsTestHarness, allocator: std.mem.Allocator) !void`。
- **作用**：S4 单测：runtime + Bytecode + FunctionDef + Builder。
- **实现**：同 S3 harness 形状。
- **所有权 / 错误 / 调用**：先 `resolve_variables.run` 再本文件 `run`。

### `ResolveLabelsTestHarness.deinit` (`src/compiler/resolve_labels.zig:3111`)

- **签名**：`fn deinit(harness: *ResolveLabelsTestHarness) void`。
- **作用**：fd / function / runtime。
- **实现**：FunctionDef.deinit 拆 builder。
- **所有权 / 错误 / 调用**：defer。

### `ResolveLabelsTestHarness.input` (`src/compiler/resolve_labels.zig:3117`)

- **签名**：`fn input(harness: *ResolveLabelsTestHarness) *builder.Builder`。
- **作用**：phase-1 发射。
- **实现**：unwrap builder。
- **所有权 / 错误 / 调用**：测试夹具：返回**借用**指针，`Builder` 本体由 harness 的 `fd.builder` 持有并在 `init`（`src/compiler/resolve_labels.zig:3808`）用 `rt.memory.create` 分配、在 `fd.deinit` 里释放，调用方不得 destroy。`.?` 是断言：phase-1 builder 未安装就 panic，没有 error set。

### `ResolveLabelsTestHarness.resolve` (`src/compiler/resolve_labels.zig:3121`)

- **签名**：`fn resolve(harness: *ResolveLabelsTestHarness) !resolve_variables.ResolvedProduct`。
- **作用**：只跑 S3，测试再手调 S4 `run(.short/.plain, …)`。
- **实现**：`resolve_variables.run`。
- **所有权 / 错误 / 调用**：调用方 defer product。

### `resolveLabelsOomScript` (`src/compiler/resolve_labels.zig:4299`)

- **签名**：`fn resolveLabelsOomScript(allocator: std.mem.Allocator) !void`。
- **作用**：OOM 扫描：goto、30 条 push_i32、atom get_field、绑定，S3+S4 必须事务性。
- **实现**：`checkAllAllocationFailures`。失败不得安装半个 Bytecode 码流。
- **所有权 / 错误 / 调用**：atom intern 与 builder 增长都走传入 allocator。

---

## 覆盖核对

- 清单函数数: 109
- 本文标题覆盖: 109
- 未覆盖: 无
