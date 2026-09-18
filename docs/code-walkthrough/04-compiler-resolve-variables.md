# 04 — resolve_variables.zig：Stage 3 变量解析与精确活性

Pass A 从只读 Builder 建不可变 LabelId CFG（audit 下），再建立事务性输出、short-form 标签记账、atom 所有权、source 携带和简单 QuickJS 改写。Pass B 把绑定决定与 lowering 交给 `bytecode.binding_rules`。

**输入只读。** 输出 atom 直接沿用输入 ledger 里的 id（本 pass 没有任何 retain/release 调用），所有权随产物 ledger 转移。失败分配都挂在未提交 `ResolvedProduct` 或 scratch 上，调用方 `deinitUncommitted`。

对照：`quickjs.c` `resolve_variables`（约 34200 起）。zjs 用块 CFG 替代线性 `ref_count` 活性。

## 文件级类型

- **`ResolvedProduct`**：S3 输出。`bound_offset` 是**产物**偏移（活代码里走过的标签）或 `unbound`（死区）。`first_reloc` 恒 `no_reloc`。`jump_size` 供 S4 预分配 JumpSlot。
- **`Resolver`**：走输入的游标机：bind/block/atom/source 前沿、pending make_ref 尾改写、audit 下的 `opt_boundaries`。
- **`Error`**：OOM / InvalidBytecode / BytecodeOverflow / NoFunctionDef / NoParentScope / ClosureVarNotFound。
- **`PendingTailRewrite` / `MakeRefFold`**：`scope_make_ref` 折叠：头在 visit 时改写，尾（insert3/perm4/rot3l/nop + put_ref_value）登记到偏移，主循环到达再发射。

---

### `ResolvedProduct.releaseConsumedStreams` (`src/compiler/resolve_variables.zig:72`)

- **签名**：`pub fn releaseConsumedStreams(self: *ResolvedProduct) void`。
- **作用**：S4 走完后释放码/atom/source 流。标签槽留下，因为 S4 还要改 `ref_count`。
- **实现**：free 三张 backing，len/capacity 置 0。幂等。不碰 `label_slots`。atom 是借用 id，没有逐项 release（函数头注释原来写成「released item-wise」，已改实）。
- **所有权 / 错误 / 调用**：S4 `releaseConsumedProduct` 在证明输出 atom 是输入的保留子序列之后调用。`deinitUncommitted` 无论是否跑过这步都正确。

### `ResolvedProduct.deinitUncommitted` (`src/compiler/resolve_variables.zig:91`)

- **签名**：`pub fn deinitUncommitted(self: *ResolvedProduct) void`。
- **作用**：放弃未提交产物：atom backing + 四张表。幂等。对齐 `Builder.deinit`。（函数头注释原来写「item-wise release of the owned atom prefix」，实际没有逐项释放，已改实。）
- **实现**：free code/atom/label/source，清 `jump_size`。
- **所有权 / 错误 / 调用**：`compileFunctionImpl` 的 `defer`；S4 成功 commit 后流已空，本函数仍安全。

### `updateLabel` (`src/compiler/resolve_variables.zig:123`)

- **签名**：`fn updateLabel(product: *ResolvedProduct, label_index: u32, delta: i32) Error!u32`。
- **作用**：qjs `update_label`：改产物 `ref_count`，返回新值。
- **实现**：负 delta 不得把计数打到 0 以下；正 delta 加法溢出 → InvalidBytecode。返回新 `ref_count`。
- **所有权 / 错误 / 调用**：死代码 −1、折叠改目标 +1/−1、动态环境探针 +1。S4 另有同名函数改同一套槽。

### `Resolver.deinitScratch` (`src/compiler/resolve_variables.zig:185`)

- **签名**：`fn deinitScratch(self: *Resolver) void`。
- **作用**：释放 pending 尾改写表；audit 下再释放 `opt_boundaries`。
- **实现**：capacity≠0 才 free。
- **所有权 / 错误 / 调用**：`run` 的 `defer`。不碰 product。

### `Resolver.hasDynamicEnvObjects` (`src/compiler/resolve_variables.zig:208`)

- **签名**：`inline fn hasDynamicEnvObjects(self: *Resolver) Error!bool`。
- **作用**：函数是否已有 with/eval 对象。避免每个标识符重扫作用域/闭包链。
- **实现**：缓存 `has_dynamic_env_objects`。闭包行只在此 pass 增长：若 `closure_var.len` 变了，对新增区间调 `closureVarRangeHasDynamicEnvObjects`。
- **所有权 / 错误 / 调用**：无 FunctionDef → `NoFunctionDef`。vars/eval 槽在此 pass 前固定。

### `Resolver.dynamicEnvProbesPossible` (`src/compiler/resolve_variables.zig:235`)

- **签名**：`inline fn dynamicEnvProbesPossible(self: *const Resolver) bool`。
- **作用**：qjs 只有真正走到 with/var_object/父环境/eval 闭包才会 `var_object_test`。收成每函数谓词：`false` 证明任何 (atom, level) 都不需要探针。
- **实现**：已有动态对象或 `fd.closure_var_may_have_dynamic_env`。缺 FunctionDef 则 true（fail-closed，让完整链仍报 `NoFunctionDef`）。
- **所有权 / 错误 / 调用**：audit 仍跑完整链并断言闸门没压掉该有的探针。

### `Resolver.recordOptimizationBoundary` (`src/compiler/resolve_variables.zig:249`)

- **签名**：`fn recordOptimizationBoundary( self: *Resolver, kind: cfg.OptimizationBoundaryKind, fold_start: u32, consumed_end: u32, replacement_start: u32, replacement_product: u32, ) Error!void`。
- **作用**：audit 记下一次 peephole 跨度（输入坐标 + 发射瞬间的产物偏移）。
- **实现**：非 audit 立即返回。reserve 一行 `OptimizationBoundary`。
- **所有权 / 错误 / 调用**：F3 分类器拿 `replacement_product` 与该处标签的产物偏移比。

### `Resolver.resolveDeferredFoldProduct` (`src/compiler/resolve_variables.zig:282`)

- **签名**：`fn resolveDeferredFoldProduct( self: *Resolver, kind: cfg.OptimizationBoundaryKind, fold_start: u32, replacement_product: u32, ) void`。
- **作用**：补上登记时尚未发射的替换产物偏移（make_ref 尾）。
- **实现**：找 kind+fold_start 且 `replacement_product == unbound` 的行。
- **所有权 / 错误 / 调用**：`emitPendingTailRewrite` 在写之前用当前 `product.code_len`。

### `Resolver.streamHasCapacity` (`src/compiler/resolve_variables.zig:299`)

- **签名**：`inline fn streamHasCapacity(capacity: usize, used: u32, need: usize) bool`。
- **作用**：热路径：used+need 是否仍落在已预留 capacity。
- **实现**：无溢出加法，纯比较。
- **所有权 / 错误 / 调用**：`ensureProductStreams`。

### `Resolver.growProductStreams` (`src/compiler/resolve_variables.zig:308`)

- **签名**：`noinline fn growProductStreams( self: *Resolver, code_need: usize, atom_need: usize, source_need: usize, ) Error!void`。
- **作用**：产物 code/atom/source 三张表超出入口预估时的冷增长。
- **实现**：任一 need 超 `maxInt(u32)` 或 `*_len + need` 溢出 → `BytecodeOverflow`。然后按非零 need 分别 `builder.reserve`：code `min_cap=16`，atom `8`，source slot `8`。
- **所有权 / 错误 / 调用**：新块记在 `product.memory`。失败时已增长的表不回滚（调用方随后 `deinitUncommitted`）。`ensureProductStreams` 热比较失败才进来。

### `Resolver.ensureProductStreams` (`src/compiler/resolve_variables.zig:362`)

- **签名**：`inline fn ensureProductStreams( self: *Resolver, code_need: usize, atom_need: usize, source_need: usize, ) Error!void`。
- **作用**：三张产物表一次容量检查；普通拷贝不应经过三次泛型 reserve。
- **实现**：全在 u32 与 capacity 内则返回；否则 `growProductStreams`。
- **所有权 / 错误 / 调用**：超估计的改写仍走增长，保留原 OOM 行为。

### `Resolver.prepareLegacyWrite` (`src/compiler/resolve_variables.zig:383`)

- **签名**：`fn prepareLegacyWrite( self: *Resolver, code_need: usize, atom_need: usize, ) Error!void`。
- **作用**：binding_rules 写出前：预留码/atom，并按 pending source 上界挂上源事件。
- **实现**：code_need=0 则 atom 也必须 0。`attachPendingSourcesAssumeCapacity`。
- **所有权 / 错误 / 调用**：所有 `writeLowered*` / `writeScopeVarAction`。

### `Resolver.finishLegacyWrite` (`src/compiler/resolve_variables.zig:406`)

- **签名**：`fn finishLegacyWrite( self: *Resolver, code_used: usize, atom_used: usize, ) void`。
- **作用**：规则写出器用完的字节计入产物长度。
- **实现**：assert 拟合 u32，`+=`。
- **所有权 / 错误 / 调用**：与 prepare 成对，defer 在 write 之后。

### `Resolver.newProductLabel` (`src/compiler/resolve_variables.zig:417`)

- **签名**：`fn newProductLabel(self: *Resolver) Error!u32`。
- **作用**：S3 新增标签（动态环境 done、模块 body hoist、eval 已定义跳）。
- **实现**：reserve LabelSlot，默认未绑定。
- **所有权 / 错误 / 调用**：必须随后 `bindProductLabel`。下标与输入标签空间连续。

### `Resolver.bindProductLabel` (`src/compiler/resolve_variables.zig:435`)

- **签名**：`fn bindProductLabel(self: *Resolver, label_index: u32) Error!void`。
- **作用**：把产物标签钉在当前 `product.code_len`。
- **实现**：已绑定或 offset 非 unbound → 失败。
- **所有权 / 错误 / 调用**：探针串结束后绑 done；hoist 的 defined_label。

### `Resolver.writeScopeVarAction` (`src/compiler/resolve_variables.zig:444`)

- **签名**：`fn writeScopeVarAction( self: *Resolver, atom_id: core.atom.Atom, action: rules.ScopeVarActionAlias, ) Error!void`。
- **作用**：按 ScopeVarAction 写局部/参数/闭包/全局 opcode（含带 atom 的 throw）。
- **实现**：prepare 后 `rules.writeScopeVarAction`，长度必须精确消耗。
- **所有权 / 错误 / 调用**：make_ref 非折叠、pending 尾 put。atom 需要时进产物 ledger。

### `Resolver.writeResolvedScopeVarPlan` (`src/compiler/resolve_variables.zig:475`)

- **签名**：`fn writeResolvedScopeVarPlan( self: *Resolver, atom_id: core.atom.Atom, plan: rules.ResolvedScopeVarPlanAlias, ) Error!void`。
- **作用**：普通 qjs 作用域解析立刻写选中的 1–3 字节动作，不在调用栈再物化一份 ScopeVarAction。`throw_error` 仍走泛型 writer。
- **实现**：`action_size == operand_size+1`。0/1/2 字节立即数。
- **所有权 / 错误 / 调用**：`lowerScopeVar` 热路径。

### `Resolver.emitDynamicEnvProbe` (`src/compiler/resolve_variables.zig:508`)

- **签名**：`fn emitDynamicEnvProbe( self: *Resolver, atom_id: core.atom.Atom, probe: rules.EvalVarObjectProbeAlias, kind: opcode.dyn_env.ProbeKind, label_done: u32, ) Error!void`。
- **作用**：一条 with/var_object/闭包探针：accessor + `dyn_env_probe`(10 字节：atom + LabelId + flags)。
- **实现**：assert probe 大小 10。写 flags（kind + is_with）。`updateLabel(+1)`，`incrementJumpSize`。
- **所有权 / 错误 / 调用**：S4 `emitDynEnvProbe` 把 LabelId 收成相对位移。

### `Resolver.ensureDynamicEnvLabel` (`src/compiler/resolve_variables.zig:547`)

- **签名**：`fn ensureDynamicEnvLabel( self: *Resolver, label_done: *?u32, ) Error!u32`。
- **作用**：整串探针共用一个 done 标签，第一次真正探针才分配。
- **实现**：已有则返回，否则 `newProductLabel`。
- **所有权 / 错误 / 调用**：避免无探针时的 count/size 预扫描。

### `Resolver.needsDynamicEnvProbes` (`src/compiler/resolve_variables.zig:562`)

- **签名**：`inline fn needsDynamicEnvProbes( self: *Resolver, atom_id: core.atom.Atom, scope_level: i32, oracle_plan: ?rules.ScopeVarProbePlanAlias, ) Error!bool`。
- **作用**：热路径否定测试：无资格或无动态对象则 false。
- **实现**：audit 下若闸门说不需要但 oracle_plan 非空 → InvalidBytecode。
- **所有权 / 错误 / 调用**：大多数函数永不进入 outlined emitter。

### `Resolver.emitDynamicEnvProbes` (`src/compiler/resolve_variables.zig:584`)

- **签名**：`fn emitDynamicEnvProbes( self: *Resolver, atom_id: core.atom.Atom, scope_level: i32, kind: opcode.dyn_env.ProbeKind, binding: rules.ScopeVarBindingAlias, oracle_plan: ?rules.ScopeVarProbePlanAlias, ) Error!?u32`。
- **作用**：qjs 边走绑定链边发探针。本地 with、var_object、arg_var_object、闭包动态环境。
- **实现**：`resolvedBindingStopsDynamicEnvProbes` 为真则跳过后续。audit 核实际大小/条数与 oracle_plan。返回 done 标签或 null。
- **所有权 / 错误 / 调用**：调用方随后 `bindProductLabel`。

### `Resolver.emitThrowVarRedeclaration` (`src/compiler/resolve_variables.zig:656`)

- **签名**：`fn emitThrowVarRedeclaration( self: *Resolver, atom_id: core.atom.Atom, ) Error!void`。
- **作用**：直接 eval 与词法冲突时，在走指令前发 runtime 再声明检查（qjs:34200-34234）。
- **实现**：`rules.writeThrowVarRedeclaration`，正好 1 个 atom。
- **所有权 / 错误 / 调用**：必须在任何按需 ordinary-global 闭包行之前，以免拓扑被走出来的需求改变。

### `Resolver.writeLoweredScopeDeleteVar` (`src/compiler/resolve_variables.zig:679`)

- **签名**：`fn writeLoweredScopeDeleteVar( self: *Resolver, atom_id: core.atom.Atom, scope_level: i32, ) Error!void`。
- **作用**：`scope_delete_var` → 最终 delete 形式。
- **实现**：5 字节则带 1 atom，否则 0。
- **所有权 / 错误 / 调用**：`binding_rules` 定大小。

### `Resolver.writeLoweredScopeGetRef` (`src/compiler/resolve_variables.zig:706`)

- **签名**：`fn writeLoweredScopeGetRef( self: *Resolver, atom_id: core.atom.Atom, scope_level: i32, ) Error!void`。
- **作用**：`scope_get_ref` lowering，无 atom。
- **实现**：prepare + `writeLoweredScopeGetRef`。
- **所有权 / 错误 / 调用**：引用表达式。

### `Resolver.writeLoweredScopeMakeRef` (`src/compiler/resolve_variables.zig:726`)

- **签名**：`fn writeLoweredScopeMakeRef( self: *Resolver, atom_id: core.atom.Atom, scope_level: i32, ) Error!void`。
- **作用**：未折叠的 `scope_make_ref`：put_lvalue 用的引用描述。
- **实现**：atom 条数由规则给出。
- **所有权 / 错误 / 调用**：折叠失败或全局 put 不能优化时。

### `Resolver.writeLoweredPrivateField` (`src/compiler/resolve_variables.zig:753`)

- **签名**：`fn writeLoweredPrivateField( self: *Resolver, op_id: u8, atom_id: core.atom.Atom, scope_level: i32, resolution: rules.PrivateFieldResolutionAlias, ) Error!void`。
- **作用**：私有字段 get/put/in → 闭包槽或 brand 检查形式。
- **实现**：大小可能失败（`try loweredPrivateFieldSize`）。
- **所有权 / 错误 / 调用**：找不到闭包行是上层 `ClosureVarNotFound`。

### `Resolver.writeEnterScopeRefresh` (`src/compiler/resolve_variables.zig:789`)

- **签名**：`fn writeEnterScopeRefresh(self: *Resolver, scope: i32) Error!void`。
- **作用**：`enter_scope`：按作用域刷新（可能 0 字节，例如无 var 对象可建）。
- **实现**：size 0 则返回。
- **所有权 / 错误 / 调用**：body_scope 时先 `emitBodyHoists`。

### `Resolver.writeLeaveScopeClose` (`src/compiler/resolve_variables.zig:805`)

- **签名**：`fn writeLeaveScopeClose(self: *Resolver, scope: i32) Error!void`。
- **作用**：`leave_scope` 关闭词法环境。
- **实现**：size 0 可省略。
- **所有权 / 错误 / 调用**：eval 捕获必须在此之前标好，否则过早 close。

### `Resolver.emitWideU16` (`src/compiler/resolve_variables.zig:821`)

- **签名**：`fn emitWideU16(self: *Resolver, op_id: u8, value: u16) Error!void`。
- **作用**：合成 3 字节指令。
- **实现**：栈上 `[3]u8` + `emitInstruction`。
- **所有权 / 错误 / 调用**：hoist `put_arg`/`put_loc`。

### `Resolver.emitWideU32` (`src/compiler/resolve_variables.zig:828`)

- **签名**：`fn emitWideU32(self: *Resolver, op_id: u8, value: u32) Error!void`。
- **作用**：合成 5 字节 u32 指令。
- **实现**：`fclosure` 等。
- **所有权 / 错误 / 调用**：hoist。

### `Resolver.emitAtomWide` (`src/compiler/resolve_variables.zig:835`)

- **签名**：`fn emitAtomWide(self: *Resolver, op_id: u8, atom_id: core.atom.Atom) Error!void`。
- **作用**：合成带 atom 的指令；`atom_cache_u8` 带占位 cache 字节。
- **实现**：6 或 5 字节。
- **所有权 / 错误 / 调用**：eval var_object `define_field`/`get_field2`。S4 写真正 cache_idx。

### `Resolver.emitProductJump` (`src/compiler/resolve_variables.zig:849`)

- **签名**：`fn emitProductJump(self: *Resolver, op_id: u8, label_index: u32) Error!void`。
- **作用**：产物上发宽跳转（仍是 LabelId），ref_count+1，jump_size+1。
- **实现**：`emitWideU32` + `updateLabel(+1)`。
- **所有权 / 错误 / 调用**：模块 body `if_false`、eval 已定义跳。S4 才变相对位移。

### `Resolver.emitBodyHoists` (`src/compiler/resolve_variables.zig:859`)

- **签名**：`fn emitBodyHoists(self: *Resolver) Error!void`。
- **作用**：qjs `instantiate_hoisted_definitions`（34398-34409）：参数/var 函数闭包、模块 `push_this; if_false body`、eval 全局 var 目标。
- **实现**：`.closure` → fclosure+put_var_ref；`.var_object` 有 cpool 则 define_field，否则 get_field2 + is_undefined + if_false 已定义标签（重复 `var x` 保旧值）；`.global` 无码；`.unresolved` 失败。模块则 `return_undef` 后绑 body。
- **所有权 / 错误 / 调用**：`enter_scope` 且 scope==body_scope。所有分支操作数保持 LabelId。

### `Resolver.registerPendingTailRewrite` (`src/compiler/resolve_variables.zig:922`)

- **签名**：`fn registerPendingTailRewrite( self: *Resolver, input_offset: u32, emit_dup: bool, put_action: rules.ScopeVarActionAlias, ) Error!void`。
- **作用**：登记 make_ref 折叠尾，禁止同一未消费偏移登记两次。
- **实现**：reserve PendingTailRewrite。
- **所有权 / 错误 / 调用**：主循环 `pendingTailRewriteAt` 命中才发射。

### `Resolver.pendingTailRewriteAt` (`src/compiler/resolve_variables.zig:951`)

- **签名**：`fn pendingTailRewriteAt(self: *Resolver, input_pos: u32) Error!?usize`。
- **作用**：当前输入 pc 是否有未消费尾改写。
- **实现**：未消费项 `input_offset < pos` → 流损坏。
- **所有权 / 错误 / 调用**：主循环在解码前查询。

### `Resolver.emitPendingTailRewrite` (`src/compiler/resolve_variables.zig:960`)

- **签名**：`fn emitPendingTailRewrite( self: *Resolver, rewrite_index: usize, ) Error!u32`。
- **作用**：把 insert3/perm4/rot3l/nop + put_ref_value 收成可选 dup + put_action。
- **实现**：校验两字节形态。`resolveDeferredFoldProduct`。吸收 put 上的 source。返回 tail_end。
- **所有权 / 错误 / 调用**：atom 用 `null_atom` 调 writeScopeVarAction（put 已是槽形式）。

### `Resolver.ensureAllPendingTailsConsumed` (`src/compiler/resolve_variables.zig:989`)

- **签名**：`fn ensureAllPendingTailsConsumed(self: *const Resolver) Error!void`。
- **作用**：走完后不得剩未消费尾。
- **实现**：任一 `!consumed` → InvalidBytecode。
- **所有权 / 错误 / 调用**：主循环出口。

### `Resolver.incrementJumpSize` (`src/compiler/resolve_variables.zig:995`)

- **签名**：`fn incrementJumpSize(self: *Resolver) Error!void`。
- **作用**：S4 JumpSlot 上界 +1。
- **实现**：u32 溢出 → BytecodeOverflow。
- **所有权 / 错误 / 调用**：每条保留的跳转/探针。

### `Resolver.refreshSourceFrontier` (`src/compiler/resolve_variables.zig:1000`)

- **签名**：`inline fn refreshSourceFrontier(self: *Resolver) void`。
- **作用**：`next_source_offset` = 下一 source 的 temp_offset 或 maxInt。
- **实现**：并 `refreshSideFrontier`。
- **所有权 / 错误 / 调用**：吸收 source 后。

### `Resolver.absorbSourcesThrough` (`src/compiler/resolve_variables.zig:1008`)

- **签名**：`fn absorbSourcesThrough(self: *Resolver, input_pos: u32) void`。
- **作用**：把 `temp_offset <= input_pos` 的 source 标为 pending（推进 `source_cursor`，尚未挂到产物）。
- **实现**：`next_source_offset > pos` 则返回。
- **所有权 / 错误 / 调用**：真正挂载发生在下次 emit 的 `attachPendingSourcesAssumeCapacity`。

### `Resolver.pendingSourceUpperBound` (`src/compiler/resolve_variables.zig:1017`)

- **签名**：`fn pendingSourceUpperBound(self: *const Resolver) Error!u32`。
- **作用**：尚未挂上的 source 条数上界。
- **实现**：`source_attach_cursor > source_cursor` 损坏。
- **所有权 / 错误 / 调用**：reserve source 槽。

### `Resolver.attachPendingSourcesAssumeCapacity` (`src/compiler/resolve_variables.zig:1029`)

- **签名**：`inline fn attachPendingSourcesAssumeCapacity(self: *Resolver) void`。
- **作用**：把 pending source 挂到当前产物 `code_len`。一条内联；多条走 slow：同一输入偏移只留最后一次变迁。
- **实现**：不同输入偏移即使 outline 到同一输出指令也保持独立。
- **所有权 / 错误 / 调用**：容量已由 ensure 证明。

### `Resolver.attachPendingSourcesSlowAssumeCapacity` (`src/compiler/resolve_variables.zig:1044`)

- **签名**：`noinline fn attachPendingSourcesSlowAssumeCapacity(self: *Resolver) void`。
- **作用**：多条 pending source：同一输入偏移只留最后一次变迁，再挂到当前产物 `code_len`。
- **实现**：循环 `source_attach_cursor .. source_cursor`。下一条仍是同一 `temp_offset` 则 skip（同偏移同 Stage-4 重定位身份，只最后一次权威）。否则写 `{temp_offset=product.code_len, line, col}`，`source_len += 1`。不同输入偏移即使 outline 到同一输出指令也保持独立。
- **所有权 / 错误 / 调用**：无 error。容量已由 `ensureProductStreams` 证明。`attachPendingSourcesAssumeCapacity` 在 pending≠1 时进来。

### `Resolver.emitInstruction` (`src/compiler/resolve_variables.zig:1062`)

- **签名**：`fn emitInstruction( self: *Resolver, bytes: []const u8, atom_id: ?core.atom.Atom, ) Error!void`。
- **作用**：把合成/改写字节写入产物，可选带 atom，并挂 pending source。
- **实现**：有 atom 则校验 bytes[1..5]。完整防御性校验；普通拷贝用下面的 validated copy。
- **所有权 / 错误 / 调用**：折叠后的 5 字节跳转、opt-chain 改写。

### `Resolver.consumeInputAtom` (`src/compiler/resolve_variables.zig:1102`)

- **签名**：`fn consumeInputAtom( self: *Resolver, _: u32, instruction: TempInstruction, ) Error!?core.atom.Atom`。
- **作用**：前进 atom 游标。`phase1Instruction` 已证明 ledger 匹配，生产路径不再重载 u32。
- **实现**：无 atom 返回 null。Debug assert 游标与 size。
- **所有权 / 错误 / 调用**：返回的 id 是输入 ledger 的拷贝；产物侧再 retain/记录。

### `Resolver.emitValidatedCopyNoAtom` (`src/compiler/resolve_variables.zig:1126`)

- **签名**：`fn emitValidatedCopyNoAtom( self: *Resolver, input_pos: u32, byte_count: u8, ) Error!void`。
- **作用**：qjs `no_change`：把已解码的无 atom 指令直接追加到 bc_out。
- **实现**：memcpy + 挂 source。加法已由 ensure 证明。
- **所有权 / 错误 / 调用**：热路径。

### `Resolver.emitValidatedCopyAtom` (`src/compiler/resolve_variables.zig:1150`)

- **签名**：`fn emitValidatedCopyAtom( self: *Resolver, input_pos: u32, byte_count: u8, atom_id: core.atom.Atom, ) Error!void`。
- **作用**：带 atom 的拷贝：phase1 已证操作数==ledger，不再第三次比较。
- **实现**：memcpy + 产物 ledger 记 atom_id。
- **所有权 / 错误 / 调用**：产物 ledger 记下同一个 id（不额外 retain），与输入 ledger 并列，直到 S4 `releaseConsumedProduct` 把保留子序列移走。

### `Resolver.copyInputInstruction` (`src/compiler/resolve_variables.zig:1172`)

- **签名**：`fn copyInputInstruction( self: *Resolver, input_pos: u32, instruction: TempInstruction, atom_id: ?core.atom.Atom, ) Error!void`。
- **作用**：按 has_atom 分发 validated copy。
- **实现**：有 atom 必须 non-null。
- **所有权 / 错误 / 调用**：switch 默认臂、goto/if/catch 保留。

### `Resolver.validateLabelIndex` (`src/compiler/resolve_variables.zig:1186`)

- **签名**：`fn validateLabelIndex(self: *const Resolver, label_index: u32) Error!void`。
- **作用**：下标 < 输入 `label_len`。
- **实现**：否则 InvalidBytecode。
- **所有权 / 错误 / 调用**：读 LabelId 操作数。

### `Resolver.labelAt` (`src/compiler/resolve_variables.zig:1190`)

- **签名**：`fn labelAt(self: *const Resolver, input_pos: u32, operand_delta: u32) Error!u32`。
- **作用**：从 `pos+delta` 读 LE u32 LabelId。
- **实现**：越界失败。
- **所有权 / 错误 / 调用**：jump 操作数 delta=1；aux/scope_make_ref delta=5。

### `Resolver.passBindsAt` (`src/compiler/resolve_variables.zig:1200`)

- **签名**：`fn passBindsAt(self: *Resolver, input_pos: u32) Error!void`。
- **作用**：把当前输入偏移上未 dead_skipped 的标签绑到产物 `code_len`。
- **实现**：`next_bind_offset < pos` 损坏（漏绑）。推进 bind_cursor 并 refresh。
- **所有权 / 错误 / 调用**：qjs 遇到 OP_label 的对应物。死边界已在 `deadBoundaryAt` 标 skipped。

### `Resolver.refreshBindFrontier` (`src/compiler/resolve_variables.zig:1219`)

- **签名**：`inline fn refreshBindFrontier(self: *Resolver) void`。
- **作用**：下一绑定偏移或 maxInt。
- **实现**：并 refreshSideFrontier。
- **所有权 / 错误 / 调用**：只改 `self` 上的两个游标字段（`next_bind_offset` 与经 `refreshSideFrontier` 派生的 `next_side_offset`），读的是借用的 `self.binds` 切片，不分配、无 error set。调用方全在本文件：绑定推进后 `src/compiler/resolve_variables.zig:1214`、`:1297`、`:1325`。

### `Resolver.refreshSideFrontier` (`src/compiler/resolve_variables.zig:1227`)

- **签名**：`inline fn refreshSideFrontier(self: *Resolver) void`。
- **作用**：`next_side_offset = min(bind, source)`。
- **实现**：无绑定/无 source 时该侧已是 maxInt。
- **所有权 / 错误 / 调用**：热路径：`pos < next_side_offset` 则完全不碰身份表。

### `Resolver.passSideEventsThrough` (`src/compiler/resolve_variables.zig:1231`)

- **签名**：`inline fn passSideEventsThrough(self: *Resolver, input_pos: u32) Error!void`。
- **作用**：到达下一侧表事件时才 pass binds + absorb sources。
- **实现**：前沿比较。
- **所有权 / 错误 / 调用**：每条指令前与流末。

### `Resolver.hasLiveMatchBarrierAt` (`src/compiler/resolve_variables.zig:1237`)

- **签名**：`fn hasLiveMatchBarrierAt(self: *const Resolver, input_pos: u32) bool`。
- **作用**：该偏移是否有未 skipped 且 `match_barrier` 的标签。
- **实现**：`firstBindAtOrAfter` 扫组。
- **所有权 / 错误 / 调用**：`nop` 保留：qjs 擦 nop，但 put_lvalue 的 OP_label 边界上 nop 要活下来。v2 无 label 字节，屏障即保留信号。

### `Resolver.blockAt` (`src/compiler/resolve_variables.zig:1250`)

- **签名**：`fn blockAt(self: *Resolver, input_pos: u32) Error!usize`。
- **作用**：单调推进 `block_cursor` 找到包含该 pc 的块。
- **实现**：audit 构图后使用。
- **所有权 / 错误 / 调用**：`deadBoundaryAt` oracle 臂。

### `Resolver.deadBoundaryAt` (`src/compiler/resolve_variables.zig:1270`)

- **签名**：`fn deadBoundaryAt(self: *Resolver, input_pos: u32) Error!bool`。
- **作用**：精确 CFG 死边界 + 保留 qjs ref_count 记账给 S4 short-form。死块丢掉起点全部 bind；可达边界只把零引用（且非 match_barrier）标 skipped。
- **实现**：非 audit：有活 ref 则 true（继续作为活标签处理零 ref 透明化）；全零则 skip 整组返回 false（死，继续 skipDeadCode）。audit：用 `graph.isReachable`；可达同透明化返回 true；不可达 skip 整组返回 false。
- **所有权 / 错误 / 调用**：`skipDeadCode` 每步先问。返回 true 表示「这里是活入口，停止 skip」。

### `Resolver.firstBindAtOrAfter` (`src/compiler/resolve_variables.zig:1331`)

- **签名**：`fn firstBindAtOrAfter(self: *const Resolver, input_pos: u32) usize`。
- **作用**：绑定表二分下界。
- **实现**：不依赖 bind_cursor。
- **所有权 / 错误 / 调用**：范围查询、屏障。

### `Resolver.hasBindInRange` (`src/compiler/resolve_variables.zig:1344`)

- **签名**：`fn hasBindInRange( self: *const Resolver, start: u32, end: u32, transparent_start_binds: bool, ) bool`。
- **作用**：`[start, end)` 是否有 bind。可选把恰好在 start 的 bind 当透明（v2 bind 表示概念 OP_label **之后**）。
- **实现**：`firstBindAtOrAfter`。
- **所有权 / 错误 / 调用**：peephole 匹配器：有 bind 则拒绝，如同 qjs 遇到 OP_label。

### `Resolver.planMakeRefFold` (`src/compiler/resolve_variables.zig:1360`)

- **签名**：`fn planMakeRefFold( self: *Resolver, position_next: u32, atom_id: core.atom.Atom, scope_operand: rules.ScopeOperandAlias, aux_label: u32, binding: rules.ScopeVarBindingAlias, ) Error!?MakeRefFold`。
- **作用**：qjs:32770-32831。只决定 v2 尾结构能否折成直接 get/put；两种变量形式来自 binding planner。
- **实现**：已有动态探针计划则不折。aux 必须已绑定，尾在 next 之后且为 (insert3|perm4|rot3l|nop)+put_ref_value。全局还要 `canOptimizeGlobalRefPutTail`。get/put action 不得带 atom 或 drop/throw。`reads_value` = next 是 get_ref_value；`emit_dup` = insert3。
- **所有权 / 错误 / 调用**：aux 的 parser 关联从不是运行时跳转。

### `Resolver.matchBranchDrop` (`src/compiler/resolve_variables.zig:1441`)

- **签名**：`fn matchBranchDrop( self: *Resolver, start: u32, expected_op: ?u8, transparent_start_binds: bool, ) Error!?BranchDropMatch`。
- **作用**：匹配 `if_true/if_false` + `drop`。
- **实现**：分支必须 5 字节。范围内有 bind 则 null。
- **所有权 / 错误 / 调用**：dup 折叠第一步。

### `Resolver.matchDupBranchDrop` (`src/compiler/resolve_variables.zig:1467`)

- **签名**：`fn matchDupBranchDrop( self: *Resolver, start: u32, expected_branch: u8, transparent_start_binds: bool, ) Error!?BranchDropMatch`。
- **作用**：匹配 `dup` + 同方向 branch+drop（链式 dup-if-drop）。
- **实现**：内层 `matchBranchDrop(..., true)` 让目标标签透明。
- **所有权 / 错误 / 调用**：最多追 20 跳，无语义深度限制，只限制搜索。

### `Resolver.matchBareBranch` (`src/compiler/resolve_variables.zig:1486`)

- **签名**：`fn matchBareBranch( self: *Resolver, start: u32, expected_branch: u8, transparent_start_binds: bool, ) Error!?BareBranchMatch`。
- **作用**：匹配无 drop 的裸分支（链尾）。
- **实现**：5 字节 + bind 检查。
- **所有权 / 错误 / 调用**：成功则把 dup-if-drop 收成直接跳向最终标签。

### `Resolver.hasSourceTransitionAt` (`src/compiler/resolve_variables.zig:1514`)

- **签名**：`fn hasSourceTransitionAt(self: *const Resolver, input_pos: u32) bool`。
- **作用**：该偏移是否有**有效**源变迁（行列相对前一条变了）。legacy `emitSourcePos` 抑制未变偏移，所以重复 marker 不是障碍。
- **实现**：二分到该偏移，与 previous SourcePoint 比 `eql`。
- **所有权 / 错误 / 调用**：`matchInsertTail`：内部偏移上的变迁挡住 insert3 折叠。

### `Resolver.matchInsertTail` (`src/compiler/resolve_variables.zig:1550`)

- **签名**：`fn matchInsertTail(self: *Resolver, start: u32) Error!?InsertTailMatch`。
- **作用**：`insert3 ; put_array_el|put_ref_value ; drop` → 只留中间 put。
- **实现**：source 变迁或 bind 则 null。
- **所有权 / 错误 / 调用**：qjs:34343-34358。

### `Resolver.getLabelPos` (`src/compiler/resolve_variables.zig:1567`)

- **签名**：`fn getLabelPos(self: *Resolver, initial_label: u32) Error!u32`。
- **作用**：qjs:34161-34182。跟随 goto 最多 20 次得到绑定位置。v2 bind 已表示 OP_label 之后，返回位置上的 bind 透明。
- **实现**：未绑定失败。非 goto 或到 code_len 停止。
- **所有权 / 错误 / 调用**：dup 折叠追链。

### `Resolver.skipDeadCode` (`src/compiler/resolve_variables.zig:1591`)

- **签名**：`fn skipDeadCode(self: *Resolver, start: u32) Error!u32`。
- **作用**：qjs:34111-34159。吞不可达指令直到活边界。跳转/aux 标签 `updateLabel(-1)`，atom 游标仍前进（死代码的 atom 不进产物）。
- **实现**：每步 `deadBoundaryAt`；true 则返回该位置。吸收 source（不挂产物）。scope_make_ref 与 atom_label 格式也 −1。
- **所有权 / 错误 / 调用**：goto/return/throw/ret/tail_call 之后。死区标签保持 unbound。

### `Resolver.lowerScopeVar` (`src/compiler/resolve_variables.zig:1637`)

- **签名**：`fn lowerScopeVar( self: *Resolver, position: u32, op_id: u8, atom_id: core.atom.Atom, ) Error!void`。
- **作用**：`scope_get/put_var*` → 解析计划、可选探针、写 1–3 字节动作。
- **实现**：`resolveScopeVarPlan`。audit 再跑 `planScopeVarLowering` 比 action。闸门 `dynamicEnvProbesPossible`；需要则 `emitDynamicEnvProbes` 后绑 done。
- **所有权 / 错误 / 调用**：qjs:34263-34269。

### `Resolver.lowerScopeRef` (`src/compiler/resolve_variables.zig:1705`)

- **签名**：`fn lowerScopeRef( self: *Resolver, position: u32, op_id: u8, atom_id: core.atom.Atom, ) Error!void`。
- **作用**：`scope_delete_var` / `scope_get_ref`：拓扑 + 探针 + 专用 writer。
- **实现**：probe_kind delete 或 get_ref。其它 op_id 失败。
- **所有权 / 错误 / 调用**：与 lowerScopeVar 同一闸门。

### `Resolver.lowerScopeMakeRef` (`src/compiler/resolve_variables.zig:1768`)

- **签名**：`fn lowerScopeMakeRef( self: *Resolver, position: u32, position_next: u32, atom_id: core.atom.Atom, ) Error!u32`。
- **作用**：qjs:34277+。aux 标签 `updateLabel(-1)`（从不是运行时跳）。尝试折叠；否则 markReferenceTaken + 探针 + writeLoweredScopeMakeRef。
- **实现**：折叠：登记尾，可选在 next 发 get_action（reads_value），audit 记 head/tail 边界。返回新 position_next。
- **所有权 / 错误 / 调用**：返回值替换主循环的 next，以便跳过已消费的 get_ref_value。

### `Resolver.lowerPrivateField` (`src/compiler/resolve_variables.zig:1877`)

- **签名**：`fn lowerPrivateField( self: *Resolver, position: u32, op_id: u8, atom_id: core.atom.Atom, ) Error!void`。
- **作用**：解析私有字段拓扑并写出最终形式。
- **实现**：`resolvePrivateBindingTopology`；`resolvePrivateField` 空 → `ClosureVarNotFound`。
- **所有权 / 错误 / 调用**：get/put/in 四个 temp opcode。

### `Resolver.run` (`src/compiler/resolve_variables.zig:1904`)

- **签名**：`fn run(self: *Resolver) Error!void`。
- **作用**：S3 主循环：再声明检查，然后逐指令 lowering。
- **实现**：先 global_vars 词法冲突 throw。循环：`passSideEventsThrough`；pending 尾；`phase1Instruction` + consume atom。switch：空 gosub 删除；终结拷贝后 `skipDeadCode`；if/catch 计 jump；dup 折叠；insert3 折叠；nop 仅屏障保留；set_class_name 擦除；set_name 仅非 null atom；opt-chain 改 get_field/get_array_el；eval/apply_eval 标捕获并重写 scope head；scope_* 进 lower*；enter/leave_scope；默认拷贝，atom_label 仍校验标签。结束耗尽 bind/atom/source 游标。
- **所有权 / 错误 / 调用**：`pub run` 构造 Resolver 后调用。对照 qjs 各 case 行号见源码注释。

### `validateInput` (`src/compiler/resolve_variables.zig:2268`)

- **签名**：`fn validateInput(input: *const builder.Builder) Error!void`。
- **作用**：slice 长度、source 单调、bound 与 unbound 一致。
- **实现**：不解码指令（那是走的时候 phase1 的事）。
- **所有权 / 错误 / 调用**：`pub run` 最先。

### `initializeLabels` (`src/compiler/resolve_variables.zig:2297`)

- **签名**：`fn initializeLabels(product: *ResolvedProduct, input: *const builder.Builder) Error!void`。
- **作用**：拷贝输入标签：产物 offset=unbound，继承 ref_count / backward_target / match_barrier，清空 reloc。
- **实现**：一次 reserve 全部。
- **所有权 / 错误 / 调用**：活路径 `passBindsAt` 再填 offset。

### `preallocateProductStreams` (`src/compiler/resolve_variables.zig:2326`)

- **签名**：`fn preallocateProductStreams( product: *ResolvedProduct, input: *const builder.Builder, ) Error!void`。
- **作用**：按输入大小预留三张表，热路径只走 capacity 成功支。探针/hoist 仍可再增长。
- **实现**：min_cap 16/8/8。
- **所有权 / 错误 / 调用**：对齐 qjs 预尺寸 DynBuf。

### `buildBindIndex` (`src/compiler/resolve_variables.zig:2365`)

- **签名**：`fn buildBindIndex( memory: *core.memory.MemoryAccount, input: *const builder.Builder, ) Error![]BindEntry`。
- **作用**：所有 bound 槽 → 排序 BindEntry。
- **实现**：`sort_erased.heap(..., cfg.bindLessThan)`。零绑定返回空 slice（不 alloc）。
- **所有权 / 错误 / 调用**：`pub run` `defer free`。CFG 与走共享。

### `markReachableEvalCaptures` (`src/compiler/resolve_variables.zig:2393`)

- **签名**：`fn markReachableEvalCaptures( input: *const builder.Builder, graph: *const cfg.Graph, fd: *bytecode.function_def.FunctionDef, ) Error!void`。
- **作用**：在输出走可能 `leave_scope` 之前，把可达 eval/apply_eval 的捕获标上。qjs 在走到 opcode 时标（34247）；zjs 精确 CFG 预扫，与字节顺序无关。
- **实现**：phase1 走流，块可达且未过 cutoff 才 `markEvalCapturedVariables`。
- **所有权 / 错误 / 调用**：仅 audit 且 `graph.has_eval_instruction`。不用 `fd.has_eval_call`（合成 Builder 可无 parser 元数据）。

### `run` (`src/compiler/resolve_variables.zig:2462`)

- **签名**：`pub fn run( function: *bytecode.Bytecode, fd: *bytecode.function_def.FunctionDef, ) Error!ResolvedProduct`。
- **作用**：对 `fd.builder` 做精确块-CFG resolve。入口公共 API。
- **实现**：无 builder / memory/atoms 不一致 → 失败。`validateInput`；`JSContext.initWithFunctionDef` + `proveScopeLinksForResolution` + `resolveEvalGlobalVarTargets`。bind 索引；audit 下 `cfg.build` + `auditInstructionOwnership` + 条件 eval 预扫。初始化产物与 Resolver（含 `functionHasDynamicEnvObjects`）。`resolver.run`。audit 下 `auditBoundaryUniqueness`。
- **所有权 / 错误 / 调用**：`errdefer product.deinitUncommitted`。Builder **仍由调用方持有**直到 root `releaseConsumedBuilder`。注释：QCP-1 精确作用域加速器推迟，链表回退是与遗留管道共享的语义路径。

### `ResolveTestHarness.init` (`src/compiler/resolve_variables.zig:2546`)

- **签名**：`fn init(harness: *ResolveTestHarness, allocator: std.mem.Allocator) !void`。
- **作用**：S3 单测：runtime + Bytecode + FunctionDef + 堆上 Builder。
- **实现**：create Builder 填 `fd.builder`。
- **所有权 / 错误 / 调用**：栈上 `undefined` 再 init。

### `ResolveTestHarness.deinit` (`src/compiler/resolve_variables.zig:2571`)

- **签名**：`fn deinit(harness: *ResolveTestHarness) void`。
- **作用**：fd/function/runtime。FunctionDef.deinit 会拆 builder。
- **实现**：反向顺序。
- **所有权 / 错误 / 调用**：测试 defer。

### `ResolveTestHarness.deinitInput` (`src/compiler/resolve_variables.zig:2577`)

- **签名**：`fn deinitInput(harness: *ResolveTestHarness) void`。
- **作用**：只拆输入 Builder（OOM/所有权测试在 resolve 之后证明输入未变或 atom 已释放）。
- **实现**：null 指针，deinit，destroy。
- **所有权 / 错误 / 调用**：`expectOwnedAtomRelease`。

### `ResolveTestHarness.input` (`src/compiler/resolve_variables.zig:2585`)

- **签名**：`fn input(harness: *ResolveTestHarness) *builder.Builder`。
- **作用**：测试发射入口。
- **实现**：unwrap `builder`。
- **所有权 / 错误 / 调用**：测试夹具：返回**借用**指针；`Builder` 的所有权在 `fd.builder`，由 harness 的 `deinitInput`（`src/compiler/resolve_variables.zig:2574` 起）先 `input_builder.deinit()` 再 `rt.memory.destroy` 释放（`deinit` 路径则由 `fd.deinit` 做同样两步），调用方不得代劳。`.?` 是断言不是错误路径。

### `ResolveTestHarness.resolve` (`src/compiler/resolve_variables.zig:2589`)

- **签名**：`fn resolve(harness: *ResolveTestHarness) Error!ResolvedProduct`。
- **作用**：对 harness 跑 `pub run`。
- **实现**：直接转调。
- **所有权 / 错误 / 调用**：调用方 `defer product.deinitUncommitted`。

### `expectProductCode` (`src/compiler/resolve_variables.zig:2594`)

- **签名**：`fn expectProductCode(product: *const ResolvedProduct, expected: []const u8) !void`。
- **作用**：产物码精确等于期望字节。
- **实现**：len + `expectEqualSlices`。
- **所有权 / 错误 / 调用**：S3 形态单测。

### `expectProductLabel` (`src/compiler/resolve_variables.zig:2599`)

- **签名**：`fn expectProductLabel( product: *const ResolvedProduct, label: labels.LabelId, ref_count: u32, bound_offset: u32, ) !void`。
- **作用**：产物标签 ref/offset/bound 标志，且 `first_reloc == no_reloc`。
- **实现**：`bound_offset != unbound` 必须与 `flags.bound` 一致。
- **所有权 / 错误 / 调用**：死标签测 unbound。

### `TestInputSnapshot.init` (`src/compiler/resolve_variables.zig:2625`)

- **签名**：`fn init(input: *const builder.Builder) !TestInputSnapshot`。
- **作用**：深拷贝输入流，证明 resolve 只读。
- **实现**：dupe code/atoms/labels/relocs/sources。
- **所有权 / 错误 / 调用**：testing allocator。

### `TestInputSnapshot.deinit` (`src/compiler/resolve_variables.zig:2663`)

- **签名**：`fn deinit(self: *TestInputSnapshot) void`。
- **作用**：释放五份拷贝。
- **实现**：`self.* = undefined`。
- **所有权 / 错误 / 调用**：defer。

### `TestInputSnapshot.expectUnchanged` (`src/compiler/resolve_variables.zig:2672`)

- **签名**：`fn expectUnchanged(self: *const TestInputSnapshot, input: *const builder.Builder) !void`。
- **作用**：resolve 后 Builder 字节/槽/reloc/source/last_opcode_pos 与快照逐字段相等。
- **实现**：len + slices + label 字段 + reloc/source deep。
- **所有权 / 错误 / 调用**：OOM 与只读契约测试。

### `expectOwnedAtomRelease` (`src/compiler/resolve_variables.zig:2700`)

- **签名**：`fn expectOwnedAtomRelease( harness: *ResolveTestHarness, product: *ResolvedProduct, atom_id: core.atom.Atom, ) !void`。
- **作用**：产物与输入 ledger 都只持有给定 atom，然后 deinit 两边。
- **实现**：逐项 equal，再 `deinitUncommitted` + `deinitInput`。
- **所有权 / 错误 / 调用**：atom 平衡单测。

### `expectOomInputUnchanged` (`src/compiler/resolve_variables.zig:3728`)

- **签名**：`fn expectOomInputUnchanged( input: *const builder.Builder, code_len: u32, atom_len: u32, source_len: u32, first_ref_count: u32, second_ref_count: u32, ) !void`。
- **作用**：OOM 后输入长度与前两个标签 ref_count 仍是失败前的值。
- **实现**：五项 equal（code/atom/source 三个长度 + 前两个标签 ref_count）。
- **所有权 / 错误 / 调用**：`resolveVariablesOomScript`。

### `resolveVariablesOomScript` (`src/compiler/resolve_variables.zig:3743`)

- **签名**：`fn resolveVariablesOomScript(allocator: std.mem.Allocator) !void`。
- **作用**：OOM 扫描：10 个活 atom、一条 if_false 到活标签、其后死 atom 与死标签，resolve 必须事务性，失败时输入不变。
- **实现**：emit 活路径 + return_undef + 死路径 bind，`checkAllAllocationFailures` 包装。
- **所有权 / 错误 / 调用**：分配失败不得留下半个产物或改 Builder。

---

## 覆盖核对

- 清单函数数: 91
- 本文标题覆盖: 91
- 未覆盖: 无
