# 05 — opcode 元数据与逻辑声明

覆盖 `src/bytecode.zig` 的 `opcode` 命名空间与整个 `src/opcode_logical.zig`。身份主键是 **FORM**（`get_loc0` / `get_loc8` / `get_loc` 是三行），不是 SemanticFamily。

## 物理 id 空间

以 QuickJS `quickjs-opcode.h` / `opcode_info` 为历史基础，当前逻辑指令身份由 `opcode_logical.zig` 定义，物理编码包含 short、fusion 与 `ext0` 冷平面。显式资源操作也通过 carrier/subcode 表达，不能将当前编码表理解成 QuickJS 表末尾仅追加四项：

- **DEF（final）**：0..254 里 claimed 的槽。ledger 现为 claimed=243、reclaimed=12、no_row=1（id 255）、free=13。
- **temp / short overlap**：178..196。phase-1 流是 `enter_scope`…`line_num`；最终流是 `push_minus1`…`set_loc8` 等短指令。两套流必须用对应 view（`sizeOf` vs `sizeOfPhase1`）。
- **lowered-direct**：`to_propkey` 仍以字节 112、`set_name_computed` 以字节 75 出现在 parser/phase-1/S3；**最终流必须拒绝**（final 槽 reclaimed，编码为 `{ext0, tag}`）。
- **`ext0`（244）**：中性冷平面载体。操作数是 `ext0_sub`：ERM `using_*`、demote 的冷指令、late-encoding 驻留，以及 `add_base+hint` 的 add_resource。

`opcode_info` **生成自** `logical.form_decls` + `operandsOf`，不再手写。`CompactInfo` 是生产四字节视图（size, n_pop, n_push, fmt）。

## `src/opcode_logical.zig` 声明源

本模块 **不** import `bytecode.zig`（依赖方向 exec → bytecode → logical）。它拥有：

- `LogicalOpcode`：`enum(u16)`，final form 的值等于物理 id；temp 从 300 起；冷平面从 400 起。
- `form_decls`：format + 常量 pop/push。size = 1 + payload 宽度，不手写。
- `operand_overrides`：格式无法决定 kind 的形式，当前表实有 13 行（源码注释里的「eighteen」已陈旧）。
- `legacy_embedded`：burned-in 连续 run（`get_loc0..3` 等）。
- `dynamic_stack` / `branch_stack`：非常数栈效应。
- `traitsOf`：inline/forward 策略（随 form 走，demote 后扫描器仍看得见）。
- `final_carrier_residents` / `lowered_direct`：C0/C1-1 已关闭窗口的 late-encoding 登记。

`bytecode.zig` 的 comptime join 证明两半描述同一指令集（Format 字段、claimed 双射、宽度和、策略表、fingerprint `0x166cb5a2882d5cd6`）。

## `dyn_env_probe` flags

一个 opcode 覆盖五种动态环境操作。操作数偏移 9 的 flags：`kind:u3` + `is_with`。恰好 10 个合法字节。

## 函数



### `opcode` 命名空间

### `opcode.dyn_env.Flags.encode` (`src/bytecode/opcode.zig:84`)

- **签名**：`pub fn encode(self: Flags) u8`。
- **作用**：把 `ProbeKind` 与 `is_with` 压成 `dyn_env_probe` 第 9 字节的 flags。
- **实现**：低 3 位写 `kind`，bit3 写 `is_with`。保留高位必须为 0，否则 `decode` 拒绝。
- **所有权 / 错误 / 调用**：纯值转换，无分配。唯一生产调用方是 `compiler/resolve_variables.zig:532`（`emitDynamicEnvProbe` 把 flags 写进 `dyn_env_probe` 的第 9 个操作数字节；parser 发的还是 `scope_*`，由这一趟下降）；读回一侧是 stack-size（`bytecode.zig:9852`）与 VM（`exec/vm_property_ref.zig:38`）。


### `opcode.dyn_env.Flags.stackPop` (`src/bytecode/opcode.zig:91`)

- **签名**：`pub fn stackPop(self: Flags) u8`。
- **作用**：fall-through 路径的弹出数。
- **实现**：`put` 弹 2（对象+存值），其余 kind 弹 1（被探测对象）。
- **所有权 / 错误 / 调用**：无错误。与 `branchStackDelta` 一起被 `computeStackSize` 和 comptime 合同 5a 交叉核对。


### `opcode.dyn_env.Flags.stackPush` (`src/bytecode/opcode.zig:98`)

- **签名**：`pub fn stackPush(self: Flags) u8`。
- **作用**：fall-through 路径的压入数。
- **实现**：`put` 压 1，其余 0。
- **所有权 / 错误 / 调用**：纯 switch，按值收 `Flags`，不分配、无 error set。调用方：`decode.stackEffect` 的 `dyn_env_probe` 臂（`bytecode.zig:2447`）与两段 comptime 合同——覆盖检查（`:1194`）和合同 5a 的分支/落空对账（`:1210`）。


### `opcode.dyn_env.Flags.branchStackDelta` (`src/bytecode/opcode.zig:107`)

- **签名**：`pub fn branchStackDelta(self: Flags) i8`。
- **作用**：taken 边相对 fall-through 之后栈高的增量。
- **实现**：`read`/`delete` +1（丢掉对象、压结果）；`get_ref`/`make_ref` +2（对象留在结果下面）；`put` -1（taken 边还要吃掉存值）。
- **所有权 / 错误 / 调用**：无错误。stack-size 的 `.dyn_env_probe` 臂用它 seed 跳转目标。


### `opcode.dyn_env.decode` (`src/bytecode/opcode.zig:119`)

- **签名**：`pub fn decode(byte: u8) ?Flags`。
- **作用**：把 flags 字节解成 `Flags`；非法编码返回 null。
- **实现**：拒绝保留位；kind 只接受 0..4。`is_with` 来自 bit3。恰好 10 个字节可解（5 kind × 2），由 round-trip 单测钉住。
- **所有权 / 错误 / 调用**：无分配。非法字节在 stack-size / decode.stackEffect 变成 `error.InvalidOpcode`。


### `opcode.ext0_sub.add` (`src/bytecode/opcode.zig:517`)

- **签名**：`pub fn add(hint: u8) u8`。
- **作用**：把 DisposalHint 编码成 `ext0` 的 add-resource 子码。
- **实现**：`add_base (64) + hint`。hint 空间对单次编译内部开放。
- **所有权 / 错误 / 调用**：纯算术（`add_base + hint`），不分配、无 error set，不检查 hint 是否溢出 u8。树内唯一调用方是 `parser.zig:8414`（`using`/`await using` 的 `ext0` 发射）；读回一侧是 `isAdd` / `addHint`。


### `opcode.ext0_sub.isAdd` (`src/bytecode/opcode.zig:521`)

- **签名**：`pub fn isAdd(sub: u8) bool`。
- **作用**：判断子码是否落在 add-resource 开区间。
- **实现**：`sub >= add_base`。
- **所有权 / 错误 / 调用**：无错误。artifact validator 用它放行 add 范围。


### `opcode.ext0_sub.addHint` (`src/bytecode/opcode.zig:525`)

- **签名**：`pub fn addHint(sub: u8) u8`。
- **作用**：从 add 子码还原 hint。
- **实现**：`sub - add_base`，调用方须先 `isAdd`。
- **所有权 / 错误 / 调用**：纯算术（`sub - add_base`），不分配、无 error set；调用前必须自己先过 `isAdd`，否则下溢。唯一调用方 `src/exec/using_ops.zig:85`，紧跟在 `:84` 的 `isAdd` 判定之后。


### `opcode.ext0_sub.stackPop` (`src/bytecode/opcode.zig:529`)

- **签名**：`pub fn stackPop(sub: u8) u8`。
- **作用**：`ext0` 子码的弹出数（含 add 范围与全部驻留）。
- **实现**：add 恒弹 2；其余按 `create`/`dispose`/类型测试/排列/冷平面驻留分发，未知子码 0。覆盖全部 256 值（`else => 0`）。
- **所有权 / 错误 / 调用**：无错误。`decode.stackEffect` 的 operand_table 臂调用。


### `opcode.ext0_sub.stackPush` (`src/bytecode/opcode.zig:553`)

- **签名**：`pub fn stackPush(sub: u8) u8`。
- **作用**：`ext0` 子码的压入数。
- **实现**：add 压 0；`create`/`dispose*` 压 1；排列类按宽度压回；`put_super_value` 压 0。未知 0。
- **所有权 / 错误 / 调用**：纯查表，不分配、无 error set；`isAdd` 范围统一返回 0。调用方：`decode.stackEffect` 的 `ext0` 臂（`bytecode.zig:2444`）、`:1175` 的 256 值全覆盖 comptime 合同，以及 `:1283`/`:1296` 的 carrier-resident 行对账。


### `opcode.formForId` (`src/bytecode/opcode.zig:618`)

- **签名**：`fn formForId(comptime id: u8) ?logical.LogicalOpcode`。
- **作用**：comptime：某 final id 是否被 <300 的 `LogicalOpcode` 占用。
- **实现**：扫 enum fields，值 <300 且等于 id 则返回该 form，否则 null。reclaimed 槽没有 enum 成员。
- **所有权 / 错误 / 调用**：仅编译期。生成 `opcode_info` 时决定 claimed vs `unused_N` 死行。


### `opcode.generatedRow` (`src/bytecode/opcode.zig:627`)

- **签名**：`fn generatedRow(comptime form: logical.LogicalOpcode) Info`。
- **作用**：从 `logical.form_decls` + `operandsOf` 生成一条 `Info`。
- **实现**：找到 form 的声明行，把 payload 宽度加到 1 得到 size；name 用 `@tagName`。没有声明行则 `@compileError`。
- **所有权 / 错误 / 调用**：comptime。size 不手写，避免与操作数模板漂移。


### `opcode.finalInfo` (`src/bytecode/opcode.zig:680`)

- **签名**：`pub inline fn finalInfo(op_id: u8) ?*const Info`。
- **作用**：最终字节码视角的 `Info`：overlap 区解析成 SHORT 行。
- **实现**：id ≥ `op_count` 返回 null；id ≥ `op_temp_start` 则下标 + `op_temp_count`（QuickJS `short_opcode_info`，quickjs.c:21842）。
- **所有权 / 错误 / 调用**：返回静态表指针。VM / dump / sizeOf 热路径。


### `opcode.finalCompactInfo` (`src/bytecode/opcode.zig:691`)

- **签名**：`pub inline fn finalCompactInfo(op_id: u8) ?*const CompactInfo`。
- **作用**：生产热路径用的 4 字节 `CompactInfo`，下标映射与 `finalInfo` 相同。
- **实现**：同样的 short 偏移。QuickJS 非 DUMP 的 `JSOpCode` 也是这四字节。
- **所有权 / 错误 / 调用**：返回指向静态 `compact_opcode_info` 的借用指针（`?*const CompactInfo`），不分配、无 error set；越界返回 null 而不是报错。两个调用点都在 comptime：`bytecode.zig:1705`（构建 `form_row`）与 `:2317`（「reclaimed 槽必须仍有死行」的账本断言）。


### `opcode.phase1Info` (`src/bytecode/opcode.zig:711`)

- **签名**：`fn phase1Info(op_id: u8) ?*const Info`。
- **作用**：phase-1 流视角：overlap 区是 TEMP 行；lowered-direct 仍是真行。
- **实现**：overlap 内直接 `opcode_info[id]`；对 `logical.lowered_direct` 返回表尾附加行；其余走 `finalInfo`。parser 在 phase-1 也会发 overlap 之外的 final 短指令。
- **所有权 / 错误 / 调用**：私有。`sizeOfPhase1` / `formatOfPhase1` / decode 的 lowered 域使用。


### `opcode.sizeOf` (`src/bytecode/opcode.zig:725`)

- **签名**：`pub fn sizeOf(op_id: u8) u8`。
- **作用**：最终字节码一条指令的总长度（含操作数），未占用 id 为 0。
- **实现**：`finalInfo` 的 size，否则 0。
- **所有权 / 错误 / 调用**：只读静态表，不分配、无 error set；未被占用的 id 返回 0（调用方自己判 0）。调用方：`compiler/cfg.zig:786`、`:832`，`compiler/resolve_variables.zig:514`、`:1449` 等 4 处，`exec/call_runtime.zig:4312`，以及最大的一群——`exec/small_inline.zig` 的 12 处扫描/改写站点（`:277`、`:496`、`:613` …）和 `bytecode.zig:4526` 的 atom 保留走查。


### `opcode.sizeOfPhase1` (`src/bytecode/opcode.zig:731`)

- **签名**：`pub fn sizeOfPhase1(op_id: u8) u8`。
- **作用**：phase-1 流的指令长度。
- **实现**：`phase1Info` 的 size。
- **所有权 / 错误 / 调用**：parser 与 resolve_variables 走指令时用。


### `opcode.formatOf` (`src/bytecode/opcode.zig:737`)

- **签名**：`pub fn formatOf(op_id: u8) Format`。
- **作用**：最终视角的 `Format`，缺省 `.none`。
- **实现**：`finalInfo.fmt`。
- **所有权 / 错误 / 调用**：只读静态表，不分配、无 error set；无行时返回 `.none`。生产调用方 `compiler/cfg.zig:788`、`:835`、`:1209` 等，`compiler/resolve_variables.zig:1622`、`:2245`，`parser.zig:7694`、`:7770`；本文件内被 comptime 的 `prop_cache_idx_final` 表（`bytecode.zig:815`）与运行时的 `hasAtomOperandFmt`（`:4540`）消费——per-instruction 的 cache_idx 谓词故意改查表而不是调它。


### `opcode.carriesPropCacheIdx` (`src/bytecode/opcode.zig:763`)

- **签名**：`pub inline fn carriesPropCacheIdx(op_id: u8) bool`。
- **作用**：最终形式是否带 W1 `cache_idx` 尾字节（`atom_cache_u8`）。
- **实现**：查 comptime 填好的 256 元 bool 表，避免热路径走 `phase1Info`。
- **所有权 / 错误 / 调用**：inline。emit 路径每个指令问一次。


### `opcode.carriesPropCacheIdxPhase1` (`src/bytecode/opcode.zig:770`)

- **签名**：`pub inline fn carriesPropCacheIdxPhase1(op_id: u8) bool`。
- **作用**：phase-1 视角的 cache_idx 谓词。
- **实现**：parser 会发 overlap 里的 `get_field_opt_chain`，其 final 名是另一个 opcode，所以必须问 phase-1 表。
- **所有权 / 错误 / 调用**：inline。


### `opcode.formatOfPhase1` (`src/bytecode/opcode.zig:776`)

- **签名**：`pub fn formatOfPhase1(op_id: u8) Format`。
- **作用**：phase-1 视角的 `Format`。
- **实现**：`phase1Info.fmt`。
- **所有权 / 错误 / 调用**：同 `formatOf` 的 phase-1 视图：只读静态表，不分配、无 error set。调用方 `compiler/cfg.zig:848`、`:2028`，`compiler/resolve_variables.zig:1620`、`:2243`；comptime 侧由 `prop_cache_idx_phase1`（`bytecode.zig:821`）消费。


### `opcode.nameOf` (`src/bytecode/opcode.zig:782`)

- **签名**：`pub fn nameOf(op_id: u8) []const u8`。
- **作用**：最终视角的 opcode 名，未占用为空串。
- **实现**：`finalInfo.name`。
- **所有权 / 错误 / 调用**：dump / 诊断。


### `opcode.nameOfPhase1` (`src/bytecode/opcode.zig:787`)

- **签名**：`pub fn nameOfPhase1(op_id: u8) []const u8`。
- **作用**：phase-1 视角的名字。
- **实现**：`phase1Info.name`。
- **所有权 / 错误 / 调用**：dump / 诊断。


### `opcode.nPopOf` (`src/bytecode/opcode.zig:792`)

- **签名**：`pub fn nPopOf(op_id: u8) u8`。
- **作用**：最终视角常量 pop。
- **实现**：`finalInfo.n_pop`，缺省 0。动态效应另走 `stackEffect`。
- **所有权 / 错误 / 调用**：只读静态表，不分配、无 error set。生产代码不调用它——`decode.stackEffect` 走 `form_row`；树内调用点只有本文件的单测（`bytecode.zig:2711` 把行常量与 `dyn_env` flags 对账、`:2734`/`:2741` 的表值断言）。


### `opcode.nPushOf` (`src/bytecode/opcode.zig:797`)

- **签名**：`pub fn nPushOf(op_id: u8) u8`。
- **作用**：最终视角常量 push。
- **实现**：`finalInfo.n_push`。
- **所有权 / 错误 / 调用**：同 `nPopOf`：只读静态表，不分配、无 error set，生产路径不用；调用点只有本文件单测（`bytecode.zig:2712`、`:2735`、`:2742`）。


### `opcode.physical.isReclaimedName` (`src/bytecode/opcode.zig:830`)

- **签名**：`fn isReclaimedName(name: []const u8) bool`。
- **作用**：行名是否 `unused_<id>`。
- **实现**：前缀比较。
- **所有权 / 错误 / 调用**：只给 `state_table` 编译期分类用。


### `opcode.physical.stateOf` (`src/bytecode/opcode.zig:853`)

- **签名**：`pub inline fn stateOf(op_id: u8) SlotState`。
- **作用**：8-bit id 的槽状态：claimed / reclaimed / no_row。
- **实现**：查 256 元 `state_table`，避免运行时七字节名字比较（CodeLoad -4%）。
- **所有权 / 错误 / 调用**：inline。


### `opcode.physical.Ledger.free` (`src/bytecode/opcode.zig:866`)

- **签名**：`pub fn free(self: Ledger) u16`。
- **作用**：可再分配的 id 数 = reclaimed + no_row。
- **实现**：加法。
- **所有权 / 错误 / 调用**：comptime ledger。


### `opcode.physical.Ledger.total` (`src/bytecode/opcode.zig:870`)

- **签名**：`pub fn total(self: Ledger) u16`。
- **作用**：claimed+reclaimed+no_row，必须为 256。
- **实现**：加法；comptime 断言 total==256。
- **所有权 / 错误 / 调用**：按值收 `Ledger` 的纯加法，不分配、无 error set。只在 comptime 用：`bytecode.zig:953` 断言账本覆盖整个 8 位 id 空间、`:2684` 断言总数没漂到 256 以外。


### `opcode.physical.aliasOf` (`src/bytecode/opcode.zig:970`)

- **签名**：`pub fn aliasOf(op_id: u8) ?@import("opcode_logical.zig").LogicalOpcode`。
- **作用**：可执行别名：direct id 仍解码但编码器已改写 carrier。
- **实现**：扫 `executable_aliases`（当前空：C0/C1-1 窗口已关）。
- **所有权 / 错误 / 调用**：`inline for` 扫 `executable_aliases`（当前为空表），返回按值的可选 form，不分配、无 error set。空表意味着今天它恒返回 null，但函数与表都**保留**：comptime join 的 late-encoding / lowered-direct 两条不变量各遍历一次 `executable_aliases`，decode 指纹哈希又把别名折进 `fingerprint`，删掉会同时改指纹并丢两条不变量——源码注释已写明这一点。另有两处「窗口已关」的单测。


### `opcode.decode.loweredDirectIdOf` (`src/bytecode/opcode.zig:1386`)

- **签名**：`pub fn loweredDirectIdOf(comptime value: u16) ?u8`。
- **作用**：carrier-plane form 的 lowered-direct 物理字节，没有则 null。
- **实现**：comptime 扫 `logical.lowered_direct`。今日：`to_propkey`→112，`set_name_computed`→75。
- **所有权 / 错误 / 调用**：编译期。


### `opcode.decode.nameEncodedOperand` (`src/bytecode/opcode.zig:1492`)

- **签名**：`fn nameEncodedOperand(name: []const u8) ?i33`。
- **作用**：从 opcode 名抽出 burned-in 立即数（`get_loc2`→2，`push_minus1`→-1）。
- **实现**：特判 `push_minus1`；再在 `_loc`/`_arg`/`push_`/`call`/`_var_ref` 后读十进制。名字不编码则 null。
- **所有权 / 错误 / 调用**：comptime 与 layout_table 交叉核对，防止 legacy_embedded 写错 base_value。


### `opcode.decode.FormRow.isClaimed` (`src/bytecode/opcode.zig:1549`)

- **签名**：`pub inline fn isClaimed(self: FormRow) bool`。
- **作用**：flags 的 claimed 位。
- **实现**：bit 测试。
- **所有权 / 错误 / 调用**：headerAt 拒绝未占用 id。


### `opcode.decode.FormRow.isDynamic` (`src/bytecode/opcode.zig:1552`)

- **签名**：`pub inline fn isDynamic(self: FormRow) bool`。
- **作用**：该 form 的栈效应是否动态。
- **实现**：bit 测试。
- **所有权 / 错误 / 调用**：stackEffect 快路径。


### `opcode.decode.FormRow.hasAtom` (`src/bytecode/opcode.zig:1555`)

- **签名**：`pub inline fn hasAtom(self: FormRow) bool`。
- **作用**：是否有 atom 操作数（且在 payload 偏移 0）。
- **实现**：atom_bit。
- **所有权 / 错误 / 调用**：parser 域的 ledger 消歧直接测这一位（`headerAtParser` 写 `trow.flags & FormRow.atom_bit`，`bytecode.zig:1894`），访问器本身的调用方是 `compiler/cfg.zig` 的 comptime 对账（`:890`、`:898`、`:910`）与 `:1610` 的 `TempInstruction` 重建。


### `opcode.decode.FormRow.hasLabel` (`src/bytecode/opcode.zig:1558`)

- **签名**：`pub inline fn hasLabel(self: FormRow) bool`。
- **作用**：是否有 label 操作数。
- **实现**：label_bit。
- **所有权 / 错误 / 调用**：唯一调用方 `compiler/cfg.zig:1611`（用同一行重建 `TempInstruction.has_label`）；label_bit 的「整类拒绝」用途走的是 `Header.hasLabel`（`resolve_labels.zig:372`）。


### `opcode.decode.domainRowFor` (`src/bytecode/opcode.zig:1652`)

- **签名**：`fn domainRowFor(index: u16, reject: bool) DomainRow`。
- **作用**：把 FormRow 收成 DomainRow；reject 或未 claimed 则 size=0。
- **实现**：size 0 是拒绝哨兵。
- **所有权 / 错误 / 调用**：生成 phase1/parser 物理-id 表。


### `opcode.decode.headerAtParser` (`src/bytecode/opcode.zig:1746`)

- **签名**：`pub inline fn headerAtParser( code: []const u8, atoms_ledger: []const u32, pc: u32, atom_index: u32, ) Error!Header`。
- **作用**：parser 混合流解码：overlap 字节可能是 temp 也可能是已选短指令，用 atom ledger 消歧。
- **实现**：先看 `parser_temp_row`：带 atom 的 temp 必须在 ledger 游标命中自己的 atom 才算 temp，否则落到 `final_parser_row`；无 atom 的 temp 直接采用。label/line_num 在此域是 side-table，算 `InvalidOpcode`。越界 `BytecodeOverflow`。
- **所有权 / 错误 / 调用**：不分配。Builder/CFG 走混合流时用，签名比 `headerAt` 多 ledger。


### `opcode.decode.headerAtPhase1` (`src/bytecode/opcode.zig:1789`)

- **签名**：`pub inline fn headerAtPhase1( code: []const u8, atoms_ledger: []const u32, pc: u32, atom_index: u32, ) Error!Header`。
- **作用**：严格 phase-1：overlap 永远是 temp；带 atom 的指令必须匹配 ledger 游标。
- **实现**：`phase1_row[code[pc]]`；size 0 或截断 → InvalidOpcode；atom 位再读 pc+1 的 u32 与 ledger 比较。
- **所有权 / 错误 / 调用**：匹配成功即授权调用方消费该 ledger 项。


### `opcode.decode.shortSelectionOf` (`src/bytecode/opcode.zig:1824`)

- **签名**：`pub fn shortSelectionOf(comptime wide: logical.LogicalOpcode) ShortSelection`。
- **作用**：comptime：某 wide form 的缩短阶梯（burned 0..3 与 u8 变体）。
- **实现**：同 SemanticFamily、同尾操作数、只收窄化/烧入前导槽的 final form。两套 byte 变体会 compileError。
- **所有权 / 错误 / 调用**：resolve_labels 容量预计算与发射共用 `short_selection_table`。


### `opcode.decode.selectJumpForm` (`src/bytecode/opcode.zig:1912`)

- **签名**：`pub inline fn selectJumpForm( wide: logical.LogicalOpcode, rung: enum { narrow, medium }, ) ?logical.LogicalOpcode`。
- **作用**：跳转放松：同一 family 的 1 字节或 2 字节 label 形式。
- **实现**：查 `jump_selection_table`。goto 有 goto8/goto16；条件跳转通常只有 byte 档。
- **所有权 / 错误 / 调用**：inline。


### `opcode.decode.selectPushIntForm` (`src/bytecode/opcode.zig:1943`)

- **签名**：`pub inline fn selectPushIntForm(value: i32) ?logical.LogicalOpcode`。
- **作用**：小整数 push：值为 -1..7 时选 burned 形式。
- **实现**：越界 null；否则 `push_int_selection[value+1]`。取代 `push_0+value` 的 id 算术。
- **所有权 / 错误 / 调用**：inline。


### `opcode.decode.finalEncodingOf` (`src/bytecode/opcode.zig:1989`)

- **签名**：`pub fn finalEncodingOf(comptime form: logical.LogicalOpcode) Encoding`。
- **作用**：最终写手的唯一答案：direct id 还是 `{carrier, tag}`。
- **实现**：在 `final_carrier_residents` 里的 form 永远回答 carrier（即使 direct id 仍可解码）。≥300 的 form compileError。
- **所有权 / 错误 / 调用**：comptime per form，容量侧与发射侧不得各写一套。


### `opcode.decode.selectSlotShortForm` (`src/bytecode/opcode.zig:2023`)

- **签名**：`pub inline fn selectSlotShortForm( wide: logical.LogicalOpcode, idx: u16, ) ?logical.LogicalOpcode`。
- **作用**：槽/argc 缩短：idx<4 用 burned，<256 用 byte，否则保持 wide。
- **实现**：查 `short_selection_table`。
- **所有权 / 错误 / 调用**：inline。与 `sizeOfForm` 组成合同 3 的单一计划。


### `opcode.decode.sizeOfForm` (`src/bytecode/opcode.zig:2040`)

- **签名**：`pub inline fn sizeOfForm(comptime form: logical.LogicalOpcode) u8`。
- **作用**：静态已知 form 的指令总长。
- **实现**：读 `form_row`；size 0 compileError。
- **所有权 / 错误 / 调用**：运行时匹配器用它算 next_pc。


### `opcode.decode.operandOffsetOf` (`src/bytecode/opcode.zig:2057`)

- **签名**：`pub inline fn operandOffsetOf( comptime form: logical.LogicalOpcode, comptime index: usize, comptime T: type, ) u8`。
- **作用**：操作数相对 opcode 字节的偏移，并核对 T 的宽度。
- **实现**：`1 + slot.offset`；burned 或宽度不符 compileError。生成码等于手写 `pc+1`/`pc+5`。
- **所有权 / 错误 / 调用**：全 comptime：不分配，宽度不符/操作数被烧录进 id 都是 `@compileError`。调用方 `compiler/resolve_labels.zig:270`、`:272`、`:282`，用来把 `goto` / `dyn_env_probe` 的 label 偏移从声明里导出来而不是写死。


### `opcode.decode.layoutOf` (`src/bytecode/opcode.zig:2082`)

- **签名**：`pub fn layoutOf(form: logical.LogicalOpcode) *const OperandLayout`。
- **作用**：返回 form 的 `OperandLayout` 指针。
- **实现**：`&layout_table[id].?`。carrier 驻留若无 lowered 行会 panic/unreachable。
- **所有权 / 错误 / 调用**：返回指向 comptime `layout_table` 的借用指针，不分配、无 error set；表项为 null 时是 `.?` unreachable（调用方必须先确认 form 有行）。调用方 `Header.layout`（`bytecode.zig:2299`），间接服务 `operandAt`、`targetOfLabel`、`validateKnownInstruction`、`printOperandsFromLayout`。


### `opcode.decode.Header.hasAtom` (`src/bytecode/opcode.zig:2107`)

- **签名**：`pub inline fn hasAtom(self: Header) bool`。
- **作用**：Header 是否带 atom。
- **实现**：flags & atom_bit。
- **所有权 / 错误 / 调用**：8 字节 Header 的访问器。


### `opcode.decode.Header.hasLabel` (`src/bytecode/opcode.zig:2110`)

- **签名**：`pub inline fn hasLabel(self: Header) bool`。
- **作用**：Header 是否带 label。
- **实现**：label_bit。
- **所有权 / 错误 / 调用**：读 Header 自带的 flags 字节，不分配、无 error set、不二次查表。调用方 `compiler/resolve_labels.zig:372`（拒绝未承认的 label 族）与 `compiler/cfg.zig:728`（`tempFromHeader`）。


### `opcode.decode.Header.isLowered` (`src/bytecode/opcode.zig:2116`)

- **签名**：`pub inline fn isLowered(self: Header) bool`。
- **作用**：是否 compiler-only（enum ≥300）。
- **实现**：`@intFromEnum(form) >= 300`。
- **所有权 / 错误 / 调用**：纯比较（form 值 ≥300），不分配、无 error set。唯一调用方 `compiler/cfg.zig:726`（`tempFromHeader` 填 `is_temp`）。


### `opcode.decode.Header.indexWidth` (`src/bytecode/opcode.zig:2120`)

- **签名**：`pub inline fn indexWidth(self: Header) u8`。
- **作用**：前导索引宽度。
- **实现**：与 FormRow 相同移位。
- **所有权 / 错误 / 调用**：从 flags 位段取 0/1/2，不分配、无 error set；返回 0 时调用方报 `error.InvalidBytecode`。调用方 `compiler/resolve_labels.zig:1156`（`readIndex`）、`:1252`（模式匹配复用同一个已解码 Header）。


### `opcode.decode.Header.payload_pc` (`src/bytecode/opcode.zig:2124`)

- **签名**：`pub inline fn payload_pc(self: Header) u32`。
- **作用**：第一条操作数字节的 pc。
- **实现**：`instruction_pc + 1`。
- **所有权 / 错误 / 调用**：一次加法，不分配、无 error set；不做 pc 越界检查（由 `headerAt` 保证）。调用方 `operandAt`（`bytecode.zig:2390`）与 `targetOfLabel`（`:2466`）。


### `opcode.decode.Header.next_pc` (`src/bytecode/opcode.zig:2128`)

- **签名**：`pub inline fn next_pc(self: Header) u32`。
- **作用**：下一条指令 pc。
- **实现**：`instruction_pc + size`。
- **所有权 / 错误 / 调用**：一次加法，不分配、无 error set。调用方 `pipeline_stack_size.compute`（`bytecode.zig:9829`）、`scanSmallInlineEligible`（`:12126`）、`classifyAsyncExecution`（`:12156`）、`dump.dumpArtifact`（`:12328`）。


### `opcode.decode.Header.layout` (`src/bytecode/opcode.zig:2138`)

- **签名**：`pub inline fn layout(self: Header) *const OperandLayout`。
- **作用**：操作数布局。
- **实现**：`layoutOf(form)`。
- **所有权 / 错误 / 调用**：转发给 `layoutOf`，返回借用指针，不分配、无 error set。调用方 `operandAt`（`bytecode.zig:2387`）、`targetOfLabel`（`:2461`）、`pipeline_stack_size.validateKnownInstruction`（`:9709`）、`dump.printOperandsFromLayout`（`:12350`）。


### `opcode.decode.headerAt` (`src/bytecode/opcode.zig:2191`)

- **签名**：`pub fn headerAt(comptime domain: Domain, code: []const u8, pc: u32) Error!Header`。
- **作用**：按 Domain 解码一条指令：final / s3 / lowered。
- **实现**：pc 越界 Overflow；id≥op_count InvalidOpcode。先用物理 id 查 index 表（lowered 把 overlap 映到 300+，并把 112/75 映到 carrier-plane form），再读 `form_row` 的 claimed/size，最后 `@enumFromInt`。reclaimed id 没有 enum 标签，必须先查表。
- **所有权 / 错误 / 调用**：`Error = InvalidOpcode | BytecodeOverflow`。stack-size、validator、dump、inline 扫描共用。


### `opcode.decode.operandAt` (`src/bytecode/opcode.zig:2226`)

- **签名**：`pub fn operandAt(h: Header, code: []const u8, index: usize, comptime T: type) Error!T`。
- **作用**：读第 index 个操作数；burned 槽还原声明值。
- **实现**：越界 InvalidOpcode；无 offset 则 `@intCast(fixed)`；否则按 width 小端读 u8/i8/u16/i16/u32/i32。
- **所有权 / 错误 / 调用**：调用方给 T。


### `opcode.decode.dynamicShape` (`src/bytecode/opcode.zig:2257`)

- **签名**：`fn dynamicShape(form: logical.LogicalOpcode) ?logical.DynamicStack.Shape`。
- **作用**：form 的动态栈形状，常数则 null。
- **实现**：查 `dynamic_by_form[id]`。
- **所有权 / 错误 / 调用**：comptime 表的一次下标读，不分配、无 error set。`decode` 私有，唯一调用方 `bytecode.zig:2428`（`stackEffect` 的动态臂）；`SparseDecodeTestOracle.dynamicShape`（`:12464`）是拿来对账的另一份同名实现，不是调用方。


### `opcode.decode.stackEffect` (`src/bytecode/opcode.zig:2265`)

- **签名**：`pub fn stackEffect(h: Header, code: []const u8) Error!StackEffect`。
- **作用**：fall-through 栈效应。动态 form 求声明表达式。
- **实现**：非 dynamic 直接用 FormRow pop/push。affine：`base + scale * operand`。operand_table：`ext0` 走 `ext0_sub.stackPop/Push`，`dyn_env_probe` 先 decode flags。
- **所有权 / 错误 / 调用**：非法 flags → InvalidOpcode。


### `opcode.decode.targetOfLabel` (`src/bytecode/opcode.zig:2300`)

- **签名**：`pub fn targetOfLabel(h: Header, code: []const u8, index: usize) Error!u32`。
- **作用**：把 label 操作数解成绝对目标 pc。
- **实现**：基址是该操作数自己的地址（payload_pc+offset），加有符号差。目标<0 或 >len → Overflow。
- **所有权 / 错误 / 调用**：取代每个手写站点重复的相对跳转算术。


### `opcode.decode.matchesFormAt` (`src/bytecode/opcode.zig:2314`)

- **签名**：`pub inline fn matchesFormAt(code: []const u8, pc: u32, form: logical.LogicalOpcode) bool`。
- **作用**：热路径：一条字节比较是否 direct form。
- **实现**：form≥300 或 pc 越界为 false；否则 `code[pc]==id`。不走结构化 decode。
- **所有权 / 错误 / 调用**：inline。



### `src/opcode_logical.zig`

### `planeOf` (`src/opcode_logical.zig:384`)

- **签名**：`pub fn planeOf(form: LogicalOpcode) Plane`。
- **作用**：逻辑形式住在 main 平面还是 `ext0` 子空间。
- **实现**：enum<400 → `.main`；否则 `{ .sub = .{ .carrier = .ext0, .slot = raw-400 } }`。
- **所有权 / 错误 / 调用**：`src/opcode_logical.zig` 不 import bytecode.zig。


### `familyOf` (`src/opcode_logical.zig:603`)

- **签名**：`pub fn familyOf(form: LogicalOpcode) SemanticFamily`。
- **作用**：派生的 SemanticFamily 汇总，不是身份键。
- **实现**：大 switch：`get_loc0`/`get_loc8`/`get_loc` 同 family；所有 `using_*` 归 `ext0_sub`。频率不对称（push_const vs push_const8）所以不能当主键。
- **所有权 / 错误 / 调用**：缩短选择与 profile 用 family，定价仍按 form。


### `operandTemplate` (`src/opcode_logical.zig:1010`)

- **签名**：`pub fn operandTemplate(fmt: Format) ?[]const Operand`。
- **作用**：大多数 Format 的操作数种类由格式本身决定。
- **实现**：none_* 是 burned；loc/arg/var_ref/const/label/atom/npop 族给出 payload 宽度。`u8`/`u16`/`u32` 返回 null，必须走 `operand_overrides`（`ext0` 的 sub-opcode vs `special_object` 的 flags）。
- **所有权 / 错误 / 调用**：bytecode.zig 的 join 断言每 form 恰好一种来源。


### `operandsOf` (`src/opcode_logical.zig:1105`)

- **签名**：`pub fn operandsOf(form: LogicalOpcode, fmt: Format) []const Operand`。
- **作用**：某 form 的最终操作数列表。
- **实现**：先扫 `operand_overrides`；否则 `operandTemplate(fmt)`；再没有则 panic（不变量 5）。
- **所有权 / 错误 / 调用**：生成 opcode_info 与 layout_table。


### `subForm` (`src/opcode_logical.zig:1258`)

- **签名**：`pub fn subForm(tag: u8) ?LogicalOpcode`。
- **作用**：carrier 标签对应的驻留逻辑形式；无人认领则 null。
- **实现**：comptime 稠密 256 表：400+ enum 放进 `raw-400`，再并入 `final_carrier_residents`。冲突 compileError。
- **所有权 / 错误 / 调用**：扫描器问驻留而不是问物理 id，避免 demote 后变瞎。


### `traitsOf` (`src/opcode_logical.zig:1284`)

- **签名**：`pub fn traitsOf(form: LogicalOpcode) Traits`。
- **作用**：该形式的 small-inline / apply-forward 策略。
- **实现**：两套 switch：eval/fclosure/yield/super/private/class/dyn_env/make_*_ref/gosub/catch/tail_call 与 `using_put_super_value` 禁止 inline；apply/eval/rest/dyn_env/fclosure 禁止 forward；其余 allowed。
- **所有权 / 错误 / 调用**：与 bytecode.zig 里手写拒绝表 comptime 逐 form 相等。


### `asyncSuspension` (`src/opcode_logical.zig:1624`)

- **签名**：`pub fn asyncSuspension(form: LogicalOpcode) AsyncSuspension`。
- **作用**：该形式会不会挂起当前帧。
- **实现**：`await`/`yield*`/`for_await_of_*`/`using_dispose*` → possible；`eval`/`apply_eval`/`ext0`/`invalid` → unknown；其余显式 none。新 form 必须审查。
- **所有权 / 错误 / 调用**：`classifyAsyncExecution` 整段扫描用。


## 覆盖核对

- 清单函数数（本文件分组）: 67（`src/bytecode.zig` 60 + `src/opcode_logical.zig` 7）
- 本文标题覆盖: 67
- 未覆盖: 无
