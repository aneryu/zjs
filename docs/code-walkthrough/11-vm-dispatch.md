# 11 — 尾分发热路径（`tailcall_dispatch.zig`）

每个 opcode 一个 `callconv(.c)` Handler：`(pc, sp, var_buf, vm) -> Outcome`。`pc/sp/var_buf` 走参数寄存器，其余状态在 `*Vm`。handler **不得**在自己的帧上再发非尾调用；热路径把工作做完后 `cont`，冷路径 `publish` + outlined helper + `coldNext`。

折叠回巨型 switch 会把共享帧重新撑大，禁止在没有冻结 binary / 反汇编 / 多构建 PMU 证据时合并。

## 分发契约

- **热表** `dispatch_table`：`buildTable(..., fast=true)`，int/局部/字段快路径是独立函数。
- **冷表** `cold_table`：`buildTable(..., fast=false)`。热 handler 未命中用间接 `cold_table[pc[0]]` 尾调用，阻止 LLVM 把冷 128B 帧内联进热叶子。
- **`cont`**：opcode→opcode，直跳热表。
- **`next`**：驱动入口与入帧；看 `active_dispatch_tbl`（L0 stop 时是冷表）。
- **剖析**：`noteDispatch` 只挂在 `cont`/`next`。`cold_table` 与 property tail **不**包一层，否则会按同一 pc 双计。
- **栈效应**写的是寄存器 `sp`，不是 `stack.top_ptr`。热路径常常不 publish；GC 活窗口仍以 `top_ptr` 为准，立即数压栈可以暂时超前。

## 类型

`Outcome`（u32）：`returned / threw / tail / suspended / reenter / native_returned`。

`TailMode`：`push`（普通 call）、`reuse_chain`（eval-tail 复用物理 Entry 但仍记账）、`reuse_release`（严格 `tail_call`，ES2015 PTC，释放死去帧的 logical charge）。

`Vm`：lean bundle。关键镜像：`code_base`、`var_refs_base`、`prop_sites`（惰性）、`rt`、`active_dispatch_tbl`、`resident_tail_tbl`、`property_tail_tbl`、`catch_target`、`local_fast_blocked`。outcome 载荷骑在 Vm 上而不是返回值里。`EntryState` 给 native→JS 栅栏快照/恢复 per-level 字段。

`Handler`：`*const fn (pc, sp, var_buf, vm) callconv(.c) Outcome`。

`PropertyTailSlot` / `ResidentTailSlot`：属性/字符串加法等间接尾，避免把慢货运进已经很热的叶子。

## 分发摘要

| 路径 | 栈/PC | 下一跳 |
| --- | --- | --- |
| 热叶子（loc/arg/int 算术/立即数/goto） | 只动寄存器 `sp`/`pc` | `cont` → `dispatch_table[npc[0]]` |
| 热未命中 | 原 pc/sp 原样交出 | `@call(.always_tail, cold_table[pc[0]])` |
| 冷 `coldStd` | 先 `publish`，helper 改 `stack.top_ptr` | `coldNext` → `maybeStop` → `active_dispatch_tbl` |
| 冷 `coldGen` | 同上 | 有值 → `.returned`（yield/await）；否则 `coldNext` |
| 同机 call | retreat `PendingCallRegion`，push Entry | `enterEntry` → `next(callee_pc)` |
| `OP_return` 一般（depth>0） | `sp-1` 取结果 | `zjs_op_return_general_tail` → `popAndResume` → `next` 调用者 |
| `OP_return` lean native 边界 | `sp-1` 取结果 | `returnLeanTail` → `.native_returned` |
| `OP_return` depth0 | publish | `.returned` 出 `runDispatchLoop` |
| 严格 `tail_call` | 复用物理 Entry | `Outcome.tail` + `tailCallReuse(.release)`（PTC） |
| eval-tail | 复用 Entry 仍记账 | `tailCallReuse(.chain)` |
| L0 `stop_before_pc` | 全冷表 | 每条 op 经 `maybeStop` |
| native 栅栏返回 | 结果在 `vm.return_value` | `.native_returned` |

剖析只挂在 `cont`/`next`。`tail_hot_layout_aarch64.ld` 把 Handler 收成页对齐岛。

## 函数

### `readInt` (`src/exec/tailcall_dispatch.zig:63`)

- **签名**：`fn readInt(comptime T: type, bytes: [*]const u8) T`。
- **作用**：小端读取立即数（i8/i16/i32/u16）。
- **实现**：单条 `std.mem.readInt(T, bytes[0..@sizeOf(T)], .little)`，把 `bytes` 起始的 `@sizeOf(T)` 字节按小端拼成 `T`。不要求对齐（字节码流里立即数天然不对齐），也不做长度校验——调用方按指令编码自己保证 `pc+1..` 有足够字节。
- **所有权 / 错误 / 调用**：错误：无（越界由调用方的指令长度保证）。所有权：从字节码指针按小端读定宽操作数，不持有任何东西。调用：`src/exec/tailcall_dispatch.zig` 内部 43 处操作数解码（如 `:902` 读 argc），是本文件私有 helper；`std.mem.readInt` 的其他命中与本函数无关。

### `Vm.publishPropSites` (`src/exec/tailcall_dispatch.zig:201`)

- **签名**：`pub inline fn publishPropSites(self: *Vm, function: *const bytecode.FunctionBytecode) void`。
- **作用**：使 `prop_sites` 镜像失效（count=0）；第一次 `propSite` 再惰性装填。
- **实现**：形参 `function` 被 `_ = function` 丢弃，函数体只剩一条 `self.prop_site_count = 0`：不在这里预读 hot extension（一次 load + 判空 + 两次 store，实测每次裸原生回调多 26 insn，W1 债 2），只把镜像标成「未发布」。真正的站点数组装填推迟到第一次 `propSite` 走冷臂，一次不碰属性的激活因此完全不付这份钱。
- **所有权 / 错误 / 调用**：错误：无。所有权：只把 `prop_site_count` 清零——真正的站点数组延迟到第一次 `propSiteCold` 才从 `hotExtensionCanonical` 取（`function` 形参现在未用，`_ = function`）。调用：`src/exec/zjs_vm.zig:711`，本文件 `:416`（`publishPushedEntry`）、`:780`（`enterEntry`）、`:1616`/`:1685`/`:1723`/`:1805`（各返回臂恢复调用方站点）、`:7049`、`:7090`（`reloadAfterPop`/驱动前言重发布 `vm.function`）。

### `Vm.propSite` (`src/exec/tailcall_dispatch.zig:215`)

- **签名**：`pub inline fn propSite(self: *Vm, idx: u8) *bytecode.PropSiteCache`。
- **作用**：按 cache_idx 取 `PropSiteCache`；未发布则冷臂从 hot extension 装填。
- **实现**：热臂两条指令——一次边界比较 `idx < self.prop_site_count`，命中就返回 `&self.prop_sites[idx]`。未发布（count 仍是 0）和索引越过已发布计数（`no_cache_idx` = 255，函数不可能有 256 个站点）两种情况都落到 `propSiteCold`，走 `@branchHint(.cold)` 的冷臂。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回指向 `FunctionBytecode` hot extension 里那张站点表的借用指针（或 `noPropSite()` 哑站点）；站点内容归函数所有，VM 只读写缓存字段。调用：本文件 8 处属性指令，如 `:3966`、`:4116`、`:7296`（都以 `pc[5]` 的 cache_idx 取站点）。

### `Vm.propSiteCold` (`src/exec/tailcall_dispatch.zig:220`)

- **签名**：`inline fn propSiteCold(self: *Vm, idx: u8) *bytecode.PropSiteCache`。
- **作用**：`propSite` 未命中：装填或返回 retired `noPropSite`。
- **实现**：`@branchHint(.cold)` 开头，三段：① `prop_site_count != 0` 说明镜像已发布而 `idx` 越过计数（`no_cache_idx` = 255），直接返回退休的 `noPropSite()`；② 否则镜像未发布，从 `vm.function.hotExtensionCanonical()` 取 `hot.prop_sites`，把数组指针与 `hot.prop_site_count` **内联**搬进 `Vm` 两个寄存器字段（不发调用，属性 handler 因此仍是叶子），再按 `idx` 返回站点或 `noPropSite()`；③ 函数根本没有站点表时把 `prop_sites` 指向 `noPropSiteBase()` 并把计数钉成 256，于是这次激活后续每个索引都在 `propSite` 的热臂命中哑站点，再也不进冷臂。
- **所有权 / 错误 / 调用**：错误：无。所有权：冷路径装载——把函数的 `prop_sites` 数组与计数搬进 `Vm` 寄存器字段；函数没有站点表时把 `prop_sites` 指向 `noPropSiteBase()` 并把计数设成 256，让后续 `propSite` 永远命中哑站点而不再进冷路径。调用：唯一调用方是本文件 `:217`（`propSite` 的 miss 臂）。

### `Vm.publish` (`src/exec/tailcall_dispatch.zig:240`)

- **签名**：`pub inline fn publish(self: *Vm, pc: [*]const u8, sp: [*]JSValue) void`。
- **作用**：把寄存器 pc/sp 写回 `frame.pc`（指向操作数）和 `stack.top_ptr`。
- **实现**：两条存储：`frame.pc = (pc - code_base) + 1`、`stack.setTopPtr(sp)`。`+1` 是刻意的——`pc` 指着 opcode 字节，而冷 handler 要的是操作数游标，与旧巨型 switch 每条臂在进慢路径前的 `reg_ip += 1` 对齐。发布之后堆上的 `Frame`/`Stack` 成为权威，GC 的 `liveValues` 与异常处理才看得到一致状态。
- **所有权 / 错误 / 调用**：错误：无。所有权：把寄存器里的 `pc`/`sp` 写回 `frame.pc` 与 `stack.top_ptr`——这是「让堆上的帧/栈成为权威」的同步点，GC 与异常处理据此看到一致状态。调用：本文件 47 处（如 `:603`、`:619`、`:1923`），`src/core/` 里的同名 `publish` 属别的子系统。

### `Vm.syncSp` (`src/exec/tailcall_dispatch.zig:249`)

- **签名**：`pub inline fn syncSp(self: *Vm, sp: [*]JSValue) void`。
- **作用**：只写回操作数栈顶，供拆帧仍要精确 live 边界时用。
- **实现**：单条 `self.stack.setTopPtr(sp)`。只把寄存器栈顶写回堆上的 `Stack`，`frame.pc` 保持不变——用于只改变栈深度、不需要 pc 保真的返回/拆帧臂。
- **所有权 / 错误 / 调用**：错误：无。所有权：只同步栈顶指针（pc 不动），用于只改变栈深度的返回/调用臂。调用：本文件 18 处，如 `:1756`、`:1868`、`:3625`。

### `Vm.syncPc` (`src/exec/tailcall_dispatch.zig:261`)

- **签名**：`pub inline fn syncPc(self: *Vm, pc: [*]const u8, advance: usize) void`。
- **作用**：只写 `frame.pc`（backtrace / 用户代码 throw 时必须已经是活的）。
- **实现**：一条地址算术加一条存储：`frame.pc = (pc - code_base) + advance`，把寄存器 pc 换算成帧内字节偏移。`advance` 由调用方按「操作数长度 + 1」给，所以写回的是下一条指令的偏移（qjs 的 `sf->cur_pc` 约定）。不碰 `stack.top_ptr`，写完也不会被读回来做分发，是脱离热依赖链的 fire-and-forget 存储。
- **所有权 / 错误 / 调用**：错误：无。所有权：只把 `pc + advance` 换算成帧内偏移写回 `frame.pc`，`advance` 由调用方按指令长度给。调用：本文件 18 处，如 `:901`、`:2323`（停在 argc/cache_idx 操作数上）、`:2972`。

### `Vm.reloadSp` (`src/exec/tailcall_dispatch.zig:266`)

- **签名**：`pub inline fn reloadSp(self: *Vm) [*]JSValue`。
- **作用**：从 Frame/Stack 重载寄存器 `sp`。
- **实现**：单条 `return self.stack.topPtr()`，把堆上 `Stack` 的权威栈顶重新读进寄存器；冷 helper 做过 push/pop/grow 之后用它恢复 `sp`。
- **所有权 / 错误 / 调用**：错误：无。所有权：从堆上的 `Stack` 重新读出栈顶，用于外部改过栈之后恢复寄存器 `sp`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:7124`（返回续延处理后重载）。

### `Vm.fail` (`src/exec/tailcall_dispatch.zig:270`)

- **签名**：`pub inline fn fail(self: *Vm, err: HostError) Outcome`。
- **作用**：写入 `pending_error` 并返回 `.threw`。
- **实现**：两条——把 `err` 存进 `self.pending_error`，返回 `Outcome.threw`。没有分支、没有分配，是整份文件里「Zig error → 哨兵 Outcome」的唯一转换形状。
- **所有权 / 错误 / 调用**：错误：不返回 Zig error——它是「Zig error → 哨兵」的转换点：把 `err` 存进 `vm.pending_error` 并返回 `Outcome.threw`，由 `runDispatchLoop`/上层 unwind 取出 raise。所有权：只存错误码，不持值。调用：本文件 89 处 `catch |e| return vm.fail(e)` 形态的转换点，如 `:542`、`:604`、`:620`。

### `Vm.initResident` (`src/exec/tailcall_dispatch.zig:284`)

- **签名**：`pub fn initResident(self: *Vm, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) void`。
- **作用**：把 ctx/rt/global/output 与两张驻留尾表写入 Machine 内 `Vm`，per-level 字段留待 `runTC`。
- **实现**：依次写 `ctx`、`rt = ctx.runtime`、`global`、`output` 四个跨帧不变的字段，再把 `resident_tail_tbl`/`property_tail_tbl` 指向文件级的 `resident_tail_table`/`property_tail_table`；`prop_sites` 先指向 `noPropSiteBase()` 且计数置 0；其余每帧字段（`machine`/`function`/`frame`/`stack`/`code_base`/`catch_target`/`var_refs_base`/`active_dispatch_tbl`）一律显式写 `undefined`，由 `zjs_vm.runTC`/`publishPushedEntry`/驱动前言补齐。Outcome 载荷也留 `undefined`——每个消费者都在读之前先发布。
- **所有权 / 错误 / 调用**：错误：无。所有权：把常驻 `Vm` 的外部依赖（ctx/rt/global/output）与两张尾表指针钉好，其余每帧字段一律置 `undefined`（由 `enterEntry`/`publishPushedEntry` 填），`prop_sites` 先指向哑站点基址；`Vm` 本身内嵌在 `Machine` 里，不单独分配。调用：唯一调用方 `src/exec/inline_calls.zig:1351`（`Machine.init`）。

### `Vm.retarget` (`src/exec/tailcall_dispatch.zig:314`)

- **签名**：`pub inline fn retarget(self: *Vm, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) void`。
- **作用**：空闲 Vm 改挂到同 runtime 的另一个 context。
- **实现**：断言 `self.rt == ctx.runtime`——驻留的 host invocation 只在同一 runtime 内跨 context 复用——然后改写 `ctx`/`global`/`output` 三个字段。`rt`、两张驻留尾表指针（`resident_tail_tbl`/`property_tail_tbl`）以及 `initResident` 置为 undefined 的那批每层字段（`frame`/`stack`/`code_base`/`catch_target`/`return_*` 等）都不碰：它们由每次进入时重新发布。
- **所有权 / 错误 / 调用**：所有权：只换指针，不转移存储。 错误：无。 调用：唯一调用方 `Machine.retarget`（inline_calls.zig:1369），后者又由 `host_invocation.acquire` 在 `alreadyTargets` 判否时调用。

### `Vm.takeNativeReturnInto` (`src/exec/tailcall_dispatch.zig:330`)

- **签名**：`pub inline fn takeNativeReturnInto(self: *const Vm, out: *JSValue) void`。
- **作用**：把 `return_value` 以两个 64-bit 字搬进 native 结果槽（AArch64 避免 q 寄存器不转发）。
- **实现**：一个 comptime 架构分支。aarch64 走内联 `asm volatile`，把搬运钉死成 `ldp x9, x10, [src]` + `stp x9, x10, [dst]` 两条 64-bit 访问；其余架构走 `storeValueAsIntPair(out, loadValueAsIntPair(&self.return_value))`。钉死的理由：LLVM 会把相邻两次 64-bit 访问重新合并成一次 16 字节 `q` 访问，而本核上 `q` 访问与同字节的 64-bit 访问之间不转发（交接的写侧与读侧各实测约 12 cycle）。驱动返回 `HostError!void`，回程也没有 24 字节 error union 过内存。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 `vm.return_value` 这 16 字节搬给宿主给的 `out`（aarch64 用 `ldp/stp`，其余走 int-pair）；值的所有权随之交给宿主，VM 侧不再清空。调用：`src/exec/call_runtime.zig:531`、`:576`、`:604`——三条 `runSyncInlineRoute*` 在 `boundary.finish()` 之后取回值。

### `Vm.saveEntryState` (`src/exec/tailcall_dispatch.zig:365`)

- **签名**：`pub inline fn saveEntryState(self: *const Vm) EntryState`。
- **作用**：快照 per-level 字段，供 native→JS 栅栏恢复。
- **实现**：把十个 per-level 字段（`function`、`prop_sites`、`prop_site_count`、`frame`、`stack`、`code_base`、`catch_target`、`var_refs_base`、`active_dispatch_tbl`、`local_fast_blocked`）逐个拷进一个按值返回的 `EntryState`。无分支、无调用；常驻 `Vm` 的其余字段（ctx/rt/global/两张尾表）跨栅栏不变，所以不在快照里。
- **所有权 / 错误 / 调用**：错误：无。所有权：把当前帧相关的十个 VM 寄存器字段按值快照进 `EntryState`，指针成员仍指向原有帧/栈/站点表（借用）。调用：唯一调用方 `src/exec/inline_calls.zig:1075`（`NativeBoundaryScope.init` 建围栏时）。

### `Vm.restoreEntryState` (`src/exec/tailcall_dispatch.zig:380`)

- **签名**：`pub inline fn restoreEntryState(self: *Vm, state: *const EntryState) void`。
- **作用**：把栅栏快照写回驻留 Vm。
- **实现**：`saveEntryState` 的逐字段逆写，十个字段一一对应、顺序相同，同样无分支。宿主调用返回后由它把解释状态整体拨回调用前。
- **所有权 / 错误 / 调用**：错误：无。所有权：把快照逐字段写回 `Vm`，恢复宿主调用前的解释状态；不释放任何东西。调用：`src/exec/inline_calls.zig:1120`（`NativeBoundaryScope.deinit` 的异常路径）与 `:1142`（`finish` 的成功路径）。

### `Vm.publishPushedEntry` (`src/exec/tailcall_dispatch.zig:407`)

- **签名**：`pub inline fn publishPushedEntry(self: *Vm, machine: *inline_calls.Machine, entry: *inline_calls.Entry, target: *const inline_calls.InlineTarget) [*]const u8`。
- **作用**：用 pusher 寄存器发布刚 push 的 Entry，返回 callee `code_base` 作 pc0。
- **实现**：先五条 `assert`（`machine.top == entry`、`machine.depth > 0`、`entry.frame.function == target.fb`、capture 基址等于 `target.var_refs` 或长度为 0、`entry.frame.pc == 0`），随后把 pusher 寄存器里现成的事实直接写进 `Vm`：`machine`、`publishPropSites(function)` 作废站点镜像、`frame`/`stack`/`catch_target` 取 Entry 内嵌成员的地址、`local_fast_blocked = false` 与 `active_dispatch_tbl = &dispatch_table`（刚 push 的帧必在 depth>0，不会是 L0 stop 缝），最后写 `function`/`code_base`/`var_refs_base`。`code_base` 走 `byteCodeAssumeMaterialized().ptr`（已解析的 `InlineTarget` 其 FB 必已 finalize/materialize，`byteCode` 的可选探测在此静态成立），并作为新帧 pc0 返回。注释另记：「同 callee 短路」（`function`/`var_refs_base` 已匹配就跳过六条 store）实测更贵（+5 insn / +1 cycle，2026-09-07）已回滚——这些 store 不在入帧依赖链上。
- **所有权 / 错误 / 调用**：错误：无（五条 `assert` 钉死 entry 就是刚 push 的栈顶帧且 pc 为 0）。所有权：把 Entry 内嵌的 frame/stack/catch_target 地址装进 VM 寄存器，`var_refs_base` 取帧的 capture 数组基址，`code_base` 取 `byteCodeAssumeMaterialized().ptr`；返回该 code_base 作为起始 pc。所有指针都借自 Entry，Entry pop 后失效。调用：唯一调用方 `src/exec/zjs_vm.zig:753`。

### `propertyTailHandler` (`src/exec/tailcall_dispatch.zig:503`)

- **签名**：`inline fn propertyTailHandler(vm: *const Vm, comptime slot: PropertyTailSlot) Handler`。
- **作用**：从 `property_tail_tbl[slot]` 取间接属性尾。
- **实现**：`@intFromEnum(slot)` 在 comptime 就定成常量下标，运行期只剩一次 `vm.property_tail_tbl[idx]` 的函数指针 load。走 `Vm` 字段而不是直接引用 `property_tail_table` 符号，是为了把调用点钉成「表载间接跳转」——LLVM 无法去虚拟化，慢臂就不会被内联回已经很热的属性叶子。
- **所有权 / 错误 / 调用**：错误：无。所有权：只从常驻的 `vm.property_tail_tbl` 取函数指针（表是 comptime 构造的 `.rodata`）。调用：本文件 46 处属性慢臂的 `@call(.always_tail, propertyTailHandler(vm, .xxx), ...)`，如 `:3921`、`:3963`、`:4062`。

### `residentTailHandler` (`src/exec/tailcall_dispatch.zig:507`)

- **签名**：`inline fn residentTailHandler(vm: *const Vm, comptime slot: ResidentTailSlot) Handler`。
- **作用**：从 `resident_tail_tbl[slot]` 取驻留尾（如字符串加法）。
- **实现**：与 `propertyTailHandler` 同构，换成三槽的 `vm.resident_tail_tbl`（`add_strings` / `special_arguments` / `if_false8_complex`）；同样靠表载间接阻断内联。
- **所有权 / 错误 / 调用**：错误：无。所有权：同上，取 `vm.resident_tail_tbl` 里的常驻尾臂。调用：本文件 `:3258`（`add_strings`）、`:3685`（`special_arguments`）、`:6320`（`if_false8_complex`）。

### `next` (`src/exec/tailcall_dispatch.zig:520`)

- **签名**：`fn next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：按 `active_dispatch_tbl[pc[0]]` 尾分发；L0 stop 走全冷表。
- **实现**：Debug 断言 pc 未越界；剖析 `noteDispatch`；尾分发 `vm.active_dispatch_tbl[pc[0]]`。普通帧指向无守卫热表；L0 stop 缝指向全冷表，好让每条 op 都经过 `coldNext`/`maybeStop`。
- **所有权 / 错误 / 调用**：错误：本体不产生任何错误——它只做一次 Debug 越界断言、可选的 `noteDispatch` 剖析计数，然后 `@call(.always_tail, vm.active_dispatch_tbl[pc[0]])`。所有权：不持有任何值，pc/sp/var_buf 原样转交。调用：**不是表项**，不由 `dispatch_table`/`cold_table` 进入。它是驱动入口与入帧钩子：`runDispatchLoopPublished` 的主循环以普通调用进入（`:7128`），`enterEntry`（`:801`）、`managedInlineFinish`（`:589`）、`nativeHitNext`（`:595`）以及各返回臂（`:1397`、`:1431`、`:1624` 等，共 17 处）以 `@call(.always_tail, next, …)` 进入。与 `cont` 的唯一差别是它读 `active_dispatch_tbl`（L0 停机 seam 下即 `cold_table`），所以「换表」只能经过这里。

### `maybeStop` (`src/exec/tailcall_dispatch.zig:538`)

- **签名**：`inline fn maybeStop(vm: *Vm, out: *Outcome) bool`。
- **作用**：L0 `stop_before_pc` 夹具停机：到界则把 generator 状态存起来并给出 `.returned`。
- **实现**：只在 `vm.machine.depth == 0` 且 `machine.l0.stop_before_pc` 非 null 时真做事：调 `vm_gen_async.stopBeforePc` 保存 generator 状态；它返回值则把值写进 `vm.return_value`、出参置 `.returned` 并返回 true；返回 null 则返回 false 让 `coldNext` 继续分发；抛错则出参置 `vm.fail(e)` 并返回 true。这是遗留夹具停机边界，规范生成器走的是 `OP_initial_yield`。
- **所有权 / 错误 / 调用**：错误：不返回 Zig error——`stopBeforePc` 的错误经 `vm.fail(e)` 变成 `.threw` 写进出参并返回 true。所有权：只有 `depth == 0` 且 L0 设了 `stop_before_pc` 时才真做事；命中时把 generator 的返回值写进 `vm.return_value` 并把出参置 `.returned`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:557`（`coldNext` 里，冷 helper 之后重新分发之前）。

### `coldNext` (`src/exec/tailcall_dispatch.zig:554`)

- **签名**：`inline fn coldNext(vb: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：冷 helper 之后从 `frame.pc` 重算 npc，经 `maybeStop` 尾分发 `active_dispatch_tbl`。
- **实现**：三步。① 守卫 `vm.frame.pc >= vm.function.byteCode().len` 时 `vm.fail(error.InvalidBytecode)`（夹具/损坏防护，生产字节码已证明没有掉出末尾的可达边）；② `maybeStop(vm, &stop_out)` 命中则原样返回它写的 Outcome；③ 用 `npc = vm.code_base + vm.frame.pc` 重算 pc，并以 `@call(.always_tail, vm.active_dispatch_tbl[npc[0]], .{ npc, vm.stack.topPtr(), vb, vm })` 交出去——`sp` 从 `vm.stack.topPtr()` 重新读而不是复用寄存器值，因为冷 helper 可能 grow 过堆栈把 `stack.values` 重分配；handler 都直接读权威的 `vm.stack.values`，所以不存在旧 base 悬空。
- **所有权 / 错误 / 调用**：错误：**会**直接产生一个错误——`frame.pc` 越过字节码长度时 `vm.fail(error.InvalidBytecode)`；另外 `maybeStop` 里 `stopBeforePc` 的错误也经 `vm.fail` 变成 `.threw` 从这里返回。所有权：不持值，从 `vm.stack.topPtr()` 重新取栈顶（冷 helper 可能让 `stack.values` 重分配，所以不复用寄存器 `sp`）。调用：`inline fn`，不是 Handler、不进任何表。调用方是 `coldStd.h`/`coldGen.h` 两个冷壳，以及本文件另外一百余处冷臂（全文件共 105 个调用点，如 `:580`、`:923`、`:3054`）。

### `managedInlineFinish` (`src/exec/tailcall_dispatch.zig:576`)

- **签名**：`inline fn managedInlineFinish(vm: *Vm, value: JSValue, region_start: [*]JSValue, npc: [*]const u8, vb: [*]JSValue) Outcome`。
- **作用**：内建快路径命中后把结果写回 region 起点并以 `next` 继续；异常走 `vm_native.failure`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_native.failure`、`builtin_dispatch.nativeHostError`、`coldNext`、`next`。
- **所有权 / 错误 / 调用**：错误：不返回 Zig error；被调 native 返回异常值时走 `vm_native.failure` 的 `.caught` 分支回到 `coldNext`，其余情况 `unreachable`。所有权：把托管内联调用的结果就地写回 `region_start[0]`（调用区首槽复用为结果槽），然后尾调下一条指令；L0 带 `stop_before_pc` 时先同步栈顶再走冷路径。调用：本文件 `:2134`、`:2479`、`:2492`。

### `nativeHitNext` (`src/exec/tailcall_dispatch.zig:592`)

- **签名**：`inline fn nativeHitNext(vb: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：native `.hit` 之后跳过 bounds 重读，只做 generator stop 检查后 `next`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`coldNext`、`next`。
- **所有权 / 错误 / 调用**：错误：无。所有权：native 快路径命中后只重新读 `frame.pc`/`stack.topPtr()` 组装寄存器并尾调下一条；同样在 L0 带 stop 点时回落 `coldNext`。调用：本文件 `:2139`、`:2499` 的 `.hit` 臂。

### `coldStd` (`src/exec/tailcall_dispatch.zig:600`)

- **签名**：`pub fn coldStd(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!void) Handler`。
- **作用**：把 `fn(*Vm, pc) !void` 收成 publish→body→coldNext 的 Handler。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：与对应热 handler 相同；先 `publish` 再走 outlined helper，helper 改 `stack.top_ptr`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：工厂本身不产生错误；它约定的 body 类型是 `fn (vm, pc) HostError!void`，产出的壳把这个 `HostError` 用 `catch |e| return vm.fail(e)` 转成 `.threw`，**不会**把 Zig error 继续上抛。所有权：comptime 工厂，返回 `struct { fn h(…) }.h`；不分配、运行期不存在。调用：**不由分发进入**——只在建表时于 `tailcall_dispatch_colds.zig` 被求值（`coldStd` 在 :18 被别名成本地名字，共 119 个实例：26 处直接 `coldStd(...)` + 93 处经该文件 `:129` 的 `h(...)` 包装——`h` 只是把不要 `pc` 的 body 再套一层；`coldPlain`（本文件 `:612`）是它的同义别名）。

### `coldStd.h` (`src/exec/tailcall_dispatch.zig:602`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`coldStd` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：先 `vm.publish(pc, sp)` 再 `body(vm, pc) catch |e| return vm.fail(e)`——Zig error 在这里被吃掉，变成 `vm.pending_error` + `.threw`。所有权：publish 让堆上的 `Frame`/`Stack` 成为权威（helper 会分配、可能触发 GC，寄存器里的 `sp` 不在根集内）；值的所有权全部由 body 里的 `vm_*.zig` helper 管，壳自己不持有。调用：这是**冷表的通用壳**——`tailcall_dispatch_colds.zig` 里约 120 个 opcode 的 `cold_table` 格子都是它的一个实例，`dispatch_table` 里没有快臂覆盖的 opcode 同样用它；由 `next`/`coldNext` 的表载尾调用，或快臂 miss 的 `cold_table[pc[0]]` 进入。

### `coldGen` (`src/exec/tailcall_dispatch.zig:616`)

- **签名**：`pub fn coldGen(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!?JSValue) Handler`。
- **作用**：生成器/await 壳：body 返回值则 `.returned`，否则 `coldNext`。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：与对应热 handler 相同；先 `publish` 再走 outlined helper，helper 改 `stack.top_ptr`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；链出口：`Outcome.returned`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：同 `coldStd`——body 类型是 `fn (vm, pc) HostError!?JSValue`，错误经 `vm.fail(e)` 变成 `.threw`；差别在返回 `?JSValue`：非 null 表示 yield/await 挂起，把值写进 `vm.return_value` 并返回 `.returned` 退出整条链。所有权：挂起时那个 `JSValue` 的所有权从 helper 转给 `vm.return_value`，由驱动交回宿主。调用：comptime 工厂，不由分发进入；在 `tailcall_dispatch.zig:3072`/`:3081`/`:3090`/`:3099` 被求值成 `h_initial_yield`/`h_yield`/`h_yield_star`/`h_await` 四个 handler，再由 `specials` 装进两张表（`tailcall_dispatch_colds.zig:787`-`:791`）。

### `coldGen.h` (`src/exec/tailcall_dispatch.zig:618`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`coldGen` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；链出口：`Outcome.returned`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：`publish` → `body(vm, pc) catch |e| return vm.fail(e)` → 若 body 返回值则 `vm.return_value = value; return .returned`，否则 `coldNext`。所有权：挂起值的所有权转给 `vm.return_value`；其余同 `coldStd.h`。调用：generator/async 五个格子（`initial_yield`/`yield`/`yield_star`/`async_yield_star`/`await`，其中 `async_yield_star` 与 `yield_star` 共用 `h_yield_star`）在两张表里装的就是它的四个实例（`tailcall_dispatch_colds.zig:787`-`:791`）。

### `isEvalCode` (`src/exec/tailcall_dispatch.zig:630`)

- **签名**：`pub inline fn isEvalCode(vm: *Vm) bool`。
- **作用**：仅 L0 报告当前激活是否 eval 代码。
- **实现**：一次 `vm.machine.depth == 0` 判断：是 L0 就读 `machine.l0.is_eval_code`，否则一律 false——内联帧是被调函数体，不可能是 eval 代码体。这组访问器是旧解释器里散落的 `(if depth==0 …)` 守卫收敛成的统一形状。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读——`depth == 0` 时取 L0 记录的 `is_eval_code`，内联帧一律 false（内联调用不可能是 eval 代码体）。调用：`src/exec/tailcall_dispatch_colds.zig:103`（`putVar` 的实参）与本文件 `:644`。

### `evalGlobalVarBindings` (`src/exec/tailcall_dispatch.zig:633`)

- **签名**：`pub inline fn evalGlobalVarBindings(vm: *Vm) bool`。
- **作用**：仅 L0 报告 direct eval 是否把 var 绑到全局。
- **实现**：同构的 d==0 守卫：`depth == 0` 读 `machine.l0.eval_global_var_bindings`，否则 false。
- **所有权 / 错误 / 调用**：错误：无。所有权：同构的 d==0 守卫访问器，只读 `l0.eval_global_var_bindings`。调用：`src/exec/tailcall_dispatch_colds.zig:103`、`:515`、`:1041`（`globalDefinition`/`putVar` 的实参）。

### `directEvalVarsReachGlobal` (`src/exec/tailcall_dispatch.zig:636`)

- **签名**：`pub inline fn directEvalVarsReachGlobal(vm: *Vm) bool`。
- **作用**：仅 L0 报告 direct eval 变量环境是否到达全局。
- **实现**：同构的 d==0 守卫：`depth == 0` 读 `machine.l0.direct_eval_vars_reach_global`，否则 false。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `l0.direct_eval_vars_reach_global`。调用：`src/exec/tailcall_dispatch_colds.zig:716`（`applyEval`）与本文件 `:2996`（`directEval`）。

### `strictUnresolvedGetVar` (`src/exec/tailcall_dispatch.zig:639`)

- **签名**：`pub inline fn strictUnresolvedGetVar(vm: *Vm) bool`。
- **作用**：未解析 get_var 是否按严格模式抛错（非 L0 看 FB strict）。
- **实现**：唯一一个 else 分支不是 false 的守卫：`depth == 0` 读 `machine.l0.strict_unresolved_get_var`；内联帧回落到函数自身的 strict 位 `vm.function.isStrictMode() or vm.function.runtimeStrictMode()`——L0 的 strict 由 eval/脚本上下文决定，内联帧的则写在 FB 里。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读；与前三个不同，内联帧回落到函数自身的 strict 位（`isStrictMode() or runtimeStrictMode()`）而不是 false。调用：`src/exec/tailcall_dispatch_colds.zig:103`。

### `op_invalid` (`src/exec/tailcall_dispatch.zig:648`)

- **签名**：`fn op_invalid(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_invalid 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：栈效应：无——`pc`/`sp`/`var_buf` 三个参数全部 `_ =` 丢弃，既不碰栈也不推进 pc。 下一跳：只有异常出口：直接 `vm.pending_error = error.InvalidBytecode` 后 `return .threw`（不经 `vm.fail`）。
- **所有权 / 错误 / 调用**：错误：**不走 `vm.fail`**，直接写 `vm.pending_error = error.InvalidBytecode` 后 `return .threw`（`vm.fail` 是 `inline`，这里手写同一形状）。所有权：三个参数全部 `_ =` 丢弃，不碰栈。调用：既是 `specials.op_invalid`，也是 `buildTable` 的**默认填充**——`var t: [256]Handler = [_]Handler{s.op_invalid} ** 256`（`tailcall_dispatch_colds.zig:171`），所以每个未装配的 opcode 号（含被隔离回收的 112 `to_propkey`、75 `set_name_computed`）都落在它身上；另外 `BuiltTable.keep` 的 12 个占位槽也是它（:172-176），用来防 LLVM DCE。

### `callSetupRecover` (`src/exec/tailcall_dispatch.zig:675`)

- **签名**：`noinline fn callSetupRecover(vm: *Vm, err: HostError) bool`。
- **作用**：`op.call` 的 `catch |err|` 恢复，与 handler 内 push 共用：先关挂起的 for-of 迭代器，再把 setup 失败（OOM 类）变成调用者帧里可 catch 的 JS 错误。
- **实现**：`closeStackTopForOfIteratorForPendingError`；失败写 `pending_error` 返回 false。`handleCatchableRuntimeError`；失败同样 pending+false。未抓住则 `pending_error=err` 返回 false，抓住返回 true（此时 `frame.pc` 已在 handler，调用方 `coldNext` 再分发）。`noinline` 让冷恢复不碰热路径寄存器。
- **所有权 / 错误 / 调用**：不抛 Zig error；false 时 `pending_error` 已写，调用方 `return .threw`。调用：`pushAndEnter`、`pushApplyForwardEntry`、`pushEmptyLeafMiss`、`pushMovedAndEnter`、leaf miss 族、`driveTailRequest` 的 reuse 失败。

### `constructorSetupRecover` (`src/exec/tailcall_dispatch.zig:695`)

- **签名**：`noinline fn constructorSetupRecover(vm: *Vm, err: HostError) bool`。
- **作用**：构造器 setup 恢复，对齐 `vm_call.constructor`：调用者的构造器操作数区已被消费，只把 pending 异常投递给完好的调用者帧。`OP_call_constructor` 没有隐式 IteratorClose。
- **实现**：只调 `handleCatchableRuntimeError`。抓住返回 true；否则 `pending_error=err` 或二次错误，返回 false。
- **所有权 / 错误 / 调用**：不关迭代器、不 pop 区域。错误经 `pending_error`。调用：`constructorRegionRecover` 之后，以及 `pushDerivedConstructorEntry` / spread 孪生在 `pushDerivedConstructorCall` 失败时。

### `constructorRegionRecover` (`src/exec/tailcall_dispatch.zig:719`)

- **签名**：`noinline fn constructorRegionRecover(vm: *Vm, region_base: usize, err: HostError) bool`。
- **作用**：同机构造器 setup 之前仍拥有完整 `[func, new_target, args...]` 调用者区域时的错误：先按遗留 `vm_call.constructor` 的 pop/defer 释放区域，再走 `constructorSetupRecover`。
- **实现**：`popOwnedStackRegion(vm.stack, region_base)` 然后 `return constructorSetupRecover(vm, err)`。
- **所有权 / 错误 / 调用**：区域槽被 pop 释放。调用：本文件 10 处——derived/spread 构造器进入前的两次 interrupt poll（`:2545`/`:2550`/`:2584`/`:2589`/`:2640`/`:2655`），以及 `op_apply`/`op_call_constructor` 里构造调用本身失败时（`:2310`/`:2710`/`:2759`/`:2775`）。

### `iteratorNextCallSetupRecover` (`src/exec/tailcall_dispatch.zig:728`)

- **签名**：`noinline fn iteratorNextCallSetupRecover(vm: *Vm, depth: u8, err: HostError) bool`。
- **作用**：`IteratorNext` 本身在 IteratorClose-on-abrupt 区之外（qjs `JS_IteratorNext2` 直接传播失败的 `next()`）。同机 setup 失败因此先放弃该深度的 for-of 记录，再尝试调用者 catch，而不是先 close。
- **实现**：`abandonForOfIteratorAtDepth`；失败 pending+false。然后 `handleCatchableRuntimeError`，逻辑同 `callSetupRecover`。
- **所有权 / 错误 / 调用**：abandon 丢掉该深度 iterator 状态但不做 IteratorClose。调用：`pushMovedAndEnter` 的 `.for_of_next`、`pushBorrowedIteratorAndEnter`、`pushBorrowedIteratorMiss`。

### `attachApplyForwardNativeCaller` (`src/exec/tailcall_dispatch.zig:754`)

- **签名**：`noinline fn attachApplyForwardNativeCaller(vm: *Vm, entry: *inline_calls.Entry) void`。
- **作用**：D8-L1：把跳过的 `Function.prototype.apply` 内建挂到 `Entry.native_caller`（所有权同 `Function.prototype.call` 的 fused 臂），backtrace 顺序保持 `target -> apply (native) -> caller`。必须在 `vm.function` 仍是调用者时跑。不插入 InlinedSite ghost，否则 `consumeInlineThenPhysical` 会把 apply 打两遍。
- **实现**：已有 `has_native_caller`、empty/exact-args leaf、`constructor_completion` 则 return。`applyForwardSiteAfterCall(vm.function, frame.pc)` 为 null 则 return。`realmApplyBuiltin` 失败则 return。否则 `entry.native_caller = apply_obj.value()` 且 `has_native_caller=true`。
- **所有权 / 错误 / 调用**：native_caller 借 realm 的 apply 内建对象。错误：无。调用：`pushApplyForwardEntry` 在 `pushMethodCall` 成功后。

### `enterEntry` (`src/exec/tailcall_dispatch.zig:764`)

- **签名**：`inline fn enterEntry(vm: *Vm, entry: *inline_calls.Entry, code_ptr: [*]const u8) Outcome`。
- **作用**：把新 Entry 写成当前层并 `next(callee_pc)`，对齐 qjs 用 alloca 指针入帧。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm.publishPropSites`、`next`（`reloadTop` / `reloadAfterPop` 只在注释里作对照）。
- **所有权 / 错误 / 调用**：错误：不返回 Zig error，返回 `Outcome`（`.threw` 等哨兵）。所有权：把新 Entry 的 frame/stack/catch_target/var_refs 装进 VM 寄存器并 `publishPropSites` 换站点表，然后以 `pc=code_ptr`、`sp=stack.topPtr()`、`vb=frame.locals.ptr` 尾调第一条指令；Entry 仍归 Machine，所有指针都是借用。`local_fast_blocked` 只在 L0 带 stop 点的场景复位。调用：本文件 20 处 push 之后的统一入口，如 `:861`、`:946`、`:1029`。

### `pollRetreatedCallRegion` (`src/exec/tailcall_dispatch.zig:819`)

- **签名**：`inline fn pollRetreatedCallRegion( vm: *Vm, region_start: [*]JSValue, value_count: usize, ) bool`。
- **作用**：调用入口的中断节拍；命中 cadence 才走 publishing poll。
- **实现**：热半只有 qjs 的 cadence tick：`if (!vm.ctx.pollInterruptTick()) return false;`，命中才 `return pollRetreatedCallRegionCold(vm, region_start, value_count)`。返回 true 表示 poll 抛了（`pending_error` 已写），调用方必须 `return .threw`；bool 契约让整个结果留在一个寄存器里（`?Outcome` 会把汇合点重新物化成内存 phi）。
- **所有权 / 错误 / 调用**：错误：不返回 Zig error；中断处理的失败由冷版写进 `vm.pending_error`，本函数只返回 bool（true = 调用方应返回 `.threw`）。所有权：快路径只查 `pollInterruptTick()`；真要处理时冷版需要知道已退到 `region_start` 的那段值（`value_count`）以便正确扫描/清理。调用：本文件 12 处 push 前的中断检查，如 `:853`、`:940`、`:1023`。

### `pollRetreatedCallRegionCold` (`src/exec/tailcall_dispatch.zig:833`)

- **签名**：`noinline fn pollRetreatedCallRegionCold( vm: *Vm, region_start: [*]JSValue, value_count: usize, ) bool`。
- **作用**：调用入口 poll 的冷半：publishing 再 poll，加上区域恢复语义——构造器跑之前不可 catch 的中断把所有权留在调用者，因此失败前把已后撤的 top 还原。
- **实现**：`pollInterrupt` catch：`stack.setTopPtr(region_start + value_count)`，`vm.fail(err)`（写 pending_error），返回 true。成功返回 false。`noinline` 把 throw 机械和 error-union 物化挡在热 call 体之外。bool 契约与热半一致，避免 `?Outcome` 的内存 phi。
- **所有权 / 错误 / 调用**：恢复 top 后调用者 unwind 释放完整区域。true 时调用方必须 `return .threw`。调用：仅 `pollRetreatedCallRegion` 在 cadence tick 命中时。

### `pushAndEnter` (`src/exec/tailcall_dispatch.zig:848`)

- **签名**：`inline fn pushAndEnter(vb: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, region_start: [*]JSValue, argc: u16, comptime layout: inline_calls.RegionLayout) Outcome`。
- **作用**：poll 后 `pushPlainCall`/`pushMethodCall`，成功 `enterEntry`，失败 `callSetupRecover`。
- **实现**：`source_count = argc + 1 + (layout == .method)`；先 `pollRetreatedCallRegion`（中断轮询，失败已把 `.threw` 记进 `vm`），再按 comptime 的 `layout` 选 `machine.pushPlainCall` 或 `pushMethodCall`，成功就 `enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr)` 进入被调者第一条 opcode；`HostError` 交 `callSetupRecover`：接住则 `coldNext(vb, vm)` 在调用方 catch 处继续，接不住返回 `.threw`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——`pushPlainCall`/`pushMethodCall` 的 `HostError` 交给 `callSetupRecover`：能就地 catch 就走 `coldNext` 继续跑，否则错误已写进 `vm.pending_error` 并返回 `.threw`。所有权：调用区（`region_start` 起 `argc + 1 + receiver` 个槽）在进来前已被 `retreatToCallRegion` 登记进 `pending_call_region`，push 成功后这些值归新帧。调用：`src/exec/tailcall_dispatch.zig:2103`（`.plain`）、`:2410`（`.method`）、`:4796`（getter 调用，argc=0）。

### `pushApplyForwardEntry` (`src/exec/tailcall_dispatch.zig:871`)

- **签名**：`noinline fn pushApplyForwardEntry( vm: *Vm, target: *const inline_calls.InlineTarget, region_start: [*]JSValue, argc: u16, ) ApplyForwardEntryResult`。
- **作用**：肥 apply-forward setup。outline 避免 `op_call_method` 和专用 apply-fwd handler 围着 `pushMethodCall` / `attachApplyForwardNativeCaller` 长出 0x4a0 帧。`enterEntry` / `coldNext` 留在 Handler，因为 `@call(.always_tail)` 需要那份签名。
- **实现**：`source_count = argc+2`。`pollRetreatedCallRegion` 真则 `.threw`。`pushMethodCall` catch：`callSetupRecover` 失败 `.threw`，成功 `.handled`（调用方 `coldNext`）。成功则 `attachApplyForwardNativeCaller` 并返回 `.entry`。
- **所有权 / 错误 / 调用**：区域已后撤；失败恢复见 recover。调用：`applyForwardCallMethod`。

### `applyForwardCallMethod` (`src/exec/tailcall_dispatch.zig:892`)

- **签名**：`fn applyForwardCallMethod( pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, ) callconv(.c) Outcome`。
- **作用**：`op.call_method_apply_fwd` 的专用 handler（L1 `fn.apply(this, arguments)` 改写后的站点）：解析 `[receiver, method, args...]` 窗口里的字节码 method，肥 setup 外联在 `pushApplyForwardEntry`，本体只留 `enterEntry` / `coldNext` 这两个必须保持 Handler 签名的尾跳。
- **实现**：`syncPc(pc, 1)` → 读 `argc = readInt(u16, pc+1)` → 校验 `live_bytes` 能装下 `argc + 2` 个槽 → `frame.pc += 3` → `retreatToCallRegionFrom` 把 `[receiver, method, args…]` 从 `sp` 退到 `region_start`；然后从窗口取 receiver/method，**显式检查 `method_obj.class_id == bytecode_function`**（这个站点的特化期守卫不会被重新验证，换成 native/bound/closure 后再去读字节码臂就会越界，所以这里宁可返回 `.threw` 落回权威慢调用），再 `resolveInlineFunctionFromObject` + `bind`，肥 setup 交外联的 `pushApplyForwardEntry`。三条出边：`.entry` → `enterEntry`；`.handled` → `coldNext`；`.threw` → `.threw`。
- **所有权 / 错误 / 调用**：错误：**是本文件里少数几个会在没写 `vm.pending_error` 的情况下 `return .threw` 的 handler**——`live_bytes` 不足（:905）、`method` 不是对象（:911）、类不是 `bytecode_function`（:918）、`resolveInlineFunctionFromObject` 拒绝（:919）四处都是裸 `.threw`；其余错误（`pushMethodCall` 的 `HostError`）在外联的 `pushApplyForwardEntry` 里交给 `callSetupRecover`，接住则 `coldNext`，接不住才写 `pending_error`。所有权：进 handler 前 `retreatToCallRegionFrom` 把 `[receiver, method, args…]` 登记进 `machine.pending_call_region`，`pushMethodCall` 成功后这段窗口归新 Entry。调用：作为 `specials.op_call_method_apply_fwd`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:780` 装表，冷热两张表同一份。 这条 opcode 只出现在被特化改写过的 G-ctor initialize 站点。

### `pushWarmEmptyLeafAndEnter` (`src/exec/tailcall_dispatch.zig:935`)

- **签名**：`inline fn pushWarmEmptyLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome`。
- **作用**：`op_call`/`op_call0` 家族解析出「零参空叶」callee 后的 warm 入帧适配器：先试 arena 上的快构造，miss 才走权威构造器，成功即 `enterEntry` 跳进 callee 第一条指令。
- **实现**：`source_count = 1 + (leaf_this == .receiver)`，`pollRetreatedCallRegion` 命中中断即 `.threw`。先试 `machine.tryPushEmptyLeafCallFast`（栈预算 / Entry chunk / arena carve 三道 miss 都返回 null 并回退已提交预算），null 时转 `pushEmptyLeafMiss` 的三态：`.entry` 取慢路径 Entry、`.threw` 直接返回、`.recovered`（错误已被 `callSetupRecover` 接住）走 `coldNext(vb, vm)`。实参搬运只有两个绑定槽：`.receiver` 形态用 `takeSourceSlot` 把区首接收者移进帧，`.sloppy_global` 借 realm `global.value()`，`.raw_undefined` 保持 undefined；callable 槽同样被移走。`resume_pc`（调用方 post-operand pc）写进 Entry 的 resume 记录，`code_ptr` 是解析 handler 预折好的 callee 首 pc，最后 `enterEntry(vm, entry, code_ptr)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error；快路径 miss 后由 `pushEmptyLeafMiss` 决定 `.threw`（不可恢复）还是 `.recovered`（`callSetupRecover` 接住，走 `coldNext`）。所有权：调用区只有 `[callable]`（`.receiver` 时是 `[receiver, callable]`），两个槽在 finish 时被 `takeSourceSlot` 移进帧；Entry 与 arena 窗口归 Machine。调用：`src/exec/tailcall_dispatch.zig:2003`（`.sloppy_global`）、`:2024`（`.raw_undefined`）、`:2364`（`.receiver`）。

### `pushWarmExactArgsLeafAndEnter` (`src/exec/tailcall_dispatch.zig:952`)

- **签名**：`inline fn pushWarmExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, comptime return_action: inline_calls.ReturnAction, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome`。
- **作用**：`argc == callee.arg_count` 的精确实参叶调用的 warm 入帧适配器——实参窗口就地借用调用方的后撤调用区，不复制。
- **实现**：comptime 断言 `return_action` 只能是 `.next` 或 `.to_boolean`；`source_count = argc + 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`。先 `machine.tryPushExactArgsLeafCallFast`（带 `captures` 与 `resume_pc`），miss 转 `pushExactArgsLeafMiss` 三态（`.recovered` → `coldNext`）。`captures` 借 callable 的闭包数组、实参借调用区，两者都不复制；`return_action != .next` 时在入帧前改写 `entry.return_action`，最后 `enterEntry(vm, entry, code_ptr)`。
- **所有权 / 错误 / 调用**：错误：同上，miss 经 `pushExactArgsLeafMiss` 三态；`comptime` 断言 `return_action` 只能是 `.next` 或 `.to_boolean`。所有权：`argc` 个实参就地借用调用方窗口（不复制），`captures` 借 callable；`return_action != .next` 时在入帧前改写 Entry 的续延。调用：`src/exec/tailcall_dispatch.zig:2082`、`:2401`、`:5885`（内部 method 边界）。

### `pushEmptyLeafMiss` (`src/exec/tailcall_dispatch.zig:976`)

- **签名**：`noinline fn pushEmptyLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue) EmptyLeafMiss`。
- **作用**：热 call0 适配器的 first-use / chunk 切换 / heap / OOM 臂。把完整可失败构造和恢复挡在固定 handler 体外，保住稳态指令足迹。恢复后的尾分发仍在 Handler（`coldNext` 要精确 C ABI 才能 musttail）。
- **实现**：`pushEmptyLeafCall` catch：`callSetupRecover` 失败 `.threw`，成功 `.recovered`；否则 `.entry`。
- **所有权 / 错误 / 调用**：错误经 recover 变成调用者 catch 或 pending。调用：`pushWarmEmptyLeafAndEnter` 在 `tryPushEmptyLeafCallFast` 未命中时。

### `pushWarmOutlineExactArgsLeafAndEnter` (`src/exec/tailcall_dispatch.zig:985`)

- **签名**：`inline fn pushWarmOutlineExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome`。
- **作用**：同一精确实参叶形态的外联版适配器——warm 构造器整体搬进 `warmExactArgsLeafOutline`，handler 体里只留 poll、三态分派与 `enterEntry`。
- **实现**：`source_count = argc + 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`；随后 `switch (warmExactArgsLeafOutline(leaf_this, vm, function, call_facts, captures, region_start, argc, resume_pc))`：`.entry` 入帧、`.threw` 返回、`.recovered` 走 `coldNext`。与 inline 版的唯一差别是构造器位置，没有 `return_action` 改写（专供 `.raw_undefined` 臂）。
- **所有权 / 错误 / 调用**：错误：同族——`warmExactArgsLeafOutline` 返回 `.threw`/`.recovered`/`.entry` 三态，恢复走 `coldNext`。所有权：与 inline 版一致（借用实参窗口 + arena 帧窗口），区别只是把 warm 构造器整体外联，保住 handler 体积。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2084`（`.raw_undefined` 臂）。

### `pushEmptyLeafAndEnter` (`src/exec/tailcall_dispatch.zig:1001`)

- **签名**：`inline fn pushEmptyLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue, code_ptr: [*]const u8) Outcome`。
- **作用**：动态 argc 的 plain 调用与 strict method 臂用的空叶入帧——不做 warm 尝试，一条 bl 进权威构造器。
- **实现**：`source_count = 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`；直接 `machine.pushEmptyLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, region_start)`，`catch |err|` 交 `callSetupRecover`：接不住返回 `.threw`，接住则 `coldNext(vb, vm)`。构造器把调用方已 publish 的 `frame.pc` 当 resume 记录，成功后 `enterEntry(vm, entry, code_ptr)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——直接 `catch |err|` 走 `callSetupRecover`，失败 `.threw`、成功 `coldNext`。所有权：没有 warm 尝试，直接调权威构造器 `pushEmptyLeafCall`；resume pc 取调用方已 publish 的 `frame.pc`。调用：`src/exec/tailcall_dispatch.zig:2005`、`:2026`、`:2378`。

### `pushExactArgsLeafAndEnter` (`src/exec/tailcall_dispatch.zig:1017`)

- **签名**：`inline fn pushExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, comptime return_action: inline_calls.ReturnAction, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, code_ptr: [*]const u8) Outcome`。
- **作用**：精确实参叶的非 warm 版（raw-`this` method 臂等）：直接调权威构造器，省掉一份与 sloppy 臂几乎同码、会 tail-merge 回共享判别头的 warm 体。
- **实现**：comptime 断言 `return_action ∈ {.next, .to_boolean}`；`source_count = argc + 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`。`machine.pushExactArgsLeafCall(leaf_this, global, stack, function, call_facts, captures, region_start, argc)` 的错误经 `callSetupRecover` 转成 `coldNext` 或 `.threw`；`.to_boolean` 时改写 `entry.return_action`，再 `enterEntry(vm, entry, code_ptr)`。实参与 captures 都是借用。
- **所有权 / 错误 / 调用**：错误：同上，`pushExactArgsLeafCall` 的错误经 `callSetupRecover` 转成 `coldNext` 或 `.threw`。所有权：实参窗口借用，`captures` 借用；`return_action != .next`（即 `.to_boolean`）时改写 Entry 续延后再入帧。调用：`src/exec/tailcall_dispatch.zig:2403`、`:5887`。

### `pushWarmCaptureLeafAndEnter` (`src/exec/tailcall_dispatch.zig:1033`)

- **签名**：`inline fn pushWarmCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome`。
- **作用**：带捕获的零参叶（`() => this.x` 这类）在 `op_call0` 上的 warm 入帧适配器，是该形态的枢纽臂。
- **实现**：`source_count = 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`。先 `machine.tryPushCaptureLeafCallFast`（比空叶 warm 版只多两条帧 store：把已解析的 `captures` 绑进 `frame.var_refs`，`ownership.var_refs = .borrowed`），miss 转 `pushCaptureLeafMiss` 三态，`.recovered` 走 `coldNext`；成功 `enterEntry(vm, entry, code_ptr)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，miss 经 `pushCaptureLeafMiss` 的 `.entry`/`.threw`/`.recovered` 三态。所有权：比空叶多一步——把借来的 `captures` 装进帧的 `var_refs`（`.borrowed`）。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2046`（`.raw_undefined` 枢纽臂）。

### `pushWarmOutlineCaptureLeafAndEnter` (`src/exec/tailcall_dispatch.zig:1046`)

- **签名**：`inline fn pushWarmOutlineCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome`。
- **作用**：capture 叶 warm 构造器的外联版适配器（非枢纽的 sloppy plain 孪生臂）。
- **实现**：`source_count = 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`；`switch (warmCaptureLeafOutline(leaf_this, vm, function, call_facts, captures, region_start, resume_pc))` 三态：`.entry` 入帧、`.threw` 返回、`.recovered` `coldNext`。
- **所有权 / 错误 / 调用**：错误：同族三态，由 `warmCaptureLeafOutline` 返回。所有权：同 `pushWarmCaptureLeafAndEnter`，构造器外联。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2048`（`.sloppy_global` 臂）。

### `pushCaptureLeafAndEnter` (`src/exec/tailcall_dispatch.zig:1062`)

- **签名**：`inline fn pushCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, vb: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, code_ptr: [*]const u8) Outcome`。
- **作用**：capture 叶的非 warm 版，服务动态 argc 的 plain 调用与 method receiver 臂。
- **实现**：`source_count = 1 + (leaf_this == .receiver)`，poll 命中即 `.threw`；直接 `machine.pushCaptureLeafCall(leaf_this, global, stack, function, call_facts, captures, region_start)`，`catch |err|` 经 `callSetupRecover` 转 `coldNext` 或 `.threw`，成功 `enterEntry(vm, entry, code_ptr)`。
- **所有权 / 错误 / 调用**：错误：`pushCaptureLeafCall` 的错误经 `callSetupRecover` 转 `coldNext` 或 `.threw`。所有权：无 warm 尝试，直接走权威构造器；`captures` 借用。调用：`src/exec/tailcall_dispatch.zig:2053`、`:2055`、`:2388`。

### `pollCallEntryCold` (`src/exec/tailcall_dispatch.zig:1080`)

- **签名**：`noinline fn pollCallEntryCold(vm: *Vm) bool`。
- **作用**：moved/borrowed 区域入口 poll 的冷半——`pollRetreatedCallRegionCold` 的 K7 兄弟，无区域还原：moved/borrowed 源的所有权在调用者 scoped cleanup（defer free）里，poll throw 只需 publishing 再 poll + pending_error。
- **实现**：`pollInterrupt` catch `vm.fail(err)` 返回 true，否则 false。`noinline` 把 throw 机械及其强迫的 `vm.global` 热路径 load 挡在热入口体外。bool-in-register 契约同 `pollRetreatedCallRegion`。
- **所有权 / 错误 / 调用**：不改 stack top。true 时调用方 `return .threw`。调用：本文件 3 处 tick 命中臂——`pushMovedAndEnter`（`:1109`）、`pushBorrowedIteratorAndEnter`（`:1140`）与 `op_for_of_next` 的 borrowed-iterator warm 臂（`:2927`）。

### `pushMovedAndEnter` (`src/exec/tailcall_dispatch.zig:1092`)

- **签名**：`inline fn pushMovedAndEnter( vb: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, moved_values: []JSValue, return_action: inline_calls.ReturnAction, continuation_payload: u32, comptime interrupt_polled: bool, ) Outcome`。
- **作用**：实参已经搬出调用方操作数布局的同机入帧——proxy `get` 的 `[target, key, receiver]`、for-of 借用迷你记录 miss 后的 `[enum_obj, method]` 都走这里。
- **实现**：`interrupt_polled` 为假时先做 tick-only 中断 poll（`vm.ctx.pollInterruptTick()` 命中才进 `pollCallEntryCold`，后者返回 true 即 `.threw`；moved 源的清理挂在调用方 defer 上，所以不需要区域还原）。随后 `machine.pushMovedCall(vm.global, target, moved_values, .method, return_action, continuation_payload)`——布局固定 `.method`、实参所有权随之转给新帧；`catch |err|` 按续延选恢复：`.for_of_next` 用 `iteratorNextCallSetupRecover(vm, payload, err)`（要关掉半途的迭代器），其余用 `callSetupRecover`，恢复成功 `coldNext`、否则 `.threw`。成功 `enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error；`pushMovedCall` 失败时按续延类型选恢复——`.for_of_next` 用 `iteratorNextCallSetupRecover`（要关掉半途的迭代器），其余用 `callSetupRecover`，恢复成功 `coldNext`、否则 `.threw`。所有权：`moved_values` 的所有权转给新帧（调用方栈上原来的槽已另行处理）；`interrupt_polled` 为假时先做一次 tick-only 中断 poll（冷半在 `pollCallEntryCold`，不需要还原区域，因为 moved 源的清理挂在调用方的 defer 上）。调用：`src/exec/tailcall_dispatch.zig:1148`（借用迭代器 miss 的回落，已 poll 过）与 `:4917`（proxy `get` 陷阱，`[target, key, receiver]` 三值）。

### `pushBorrowedIteratorAndEnter` (`src/exec/tailcall_dispatch.zig:1124`)

- **签名**：`inline fn pushBorrowedIteratorAndEnter( vb: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, iterator_record: []JSValue, depth: u8, ) Outcome`。
- **作用**：qjs 内部 `IteratorNext` 的同机入帧：直接借调用方持久迭代器记录里的 `enum_obj` 与 `method` 当调用绑定，调用方栈一个槽都不动。
- **实现**：tick-only 中断 poll（`pollCallEntryCold` 返回 true 即 `.threw`；借用绑定仍挂在挂起的调用方栈上，poll 抛出不需要还原所有权）。`machine.pushBorrowedIteratorNext(vm.global, target, iterator_record, depth)` 出错则 `iteratorNextCallSetupRecover(vm, depth, err)`：失败 `.threw`、成功 `coldNext`。返回 null（准入不过）时把记录的两个值复制进栈上 `var moved = [2]JSValue{...}`，改走 `pushMovedAndEnter(vb, vm, target, &moved, .for_of_next, depth, true)`——`interrupt_polled = true` 保证整条路只 poll 一次。命中则 `enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr)`，续延 `.for_of_next` 会带着 `depth` 回到这里。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error；`pushBorrowedIteratorNext` 的错误经 `iteratorNextCallSetupRecover` 转 `coldNext` 或 `.threw`。所有权：`iterator_record` 的两个槽（enum_obj / method）**借**给子帧，调用方栈原样不动，子帧续延返回这里之前不会释放；准入不过（返回 null）时把两个值复制进栈上 `moved` 数组，改走 `pushMovedAndEnter(..., interrupt_polled = true)`，避免二次 poll。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2944`（for-of 的 `IteratorNext`）。

### `pushForwardedCallEntry` (`src/exec/tailcall_dispatch.zig:1180`)

- **签名**：`noinline fn pushForwardedCallEntry( vm: *Vm, region_start: [*]JSValue, argc: u16, ) ForwardedEntryResult`。
- **作用**：`Function.prototype.call` 窗口改写（设计 §5.4）：操作数 `[f, call, thisArg?, rest...]`，当 `f` 是同 Realm 普通字节码函数时就地改写成 method 布局 `[thisArg, f, args...]`，走 `pushMethodCall` 同一构造器。跳过的 native 记录骑在 `Entry.native_caller`，backtrace 为 `target -> call (native) -> caller`。独立 outline，不把 spread 循环/解析器装进 `op_call_method`。
- **实现**：`resolveForwardedTarget` 失败 `.generic`。`this_arg` 缺省 undefined，`target_argc = argc>=1 ? argc-1 : 0`。把 `region_start[0]=this_arg`、`[1]=target_value`，`copyForwards` 把 rest 下移一槽。`finishForwardedEntry(..., old_total=argc+2)`。对齐 qjs `js_function_call`（quickjs.c:41205 `JS_Call(this_val, argv[0], argc-1, argv+1)`）。
- **所有权 / 错误 / 调用**：就地改写调用者窗口；`.generic` 表示什么都没动。调用：`op_call_method` 的 call 内建快路径。

### `pushForwardedApplyEntry` (`src/exec/tailcall_dispatch.zig:1198`)

- **签名**：`noinline fn pushForwardedApplyEntry( vm: *Vm, sp: [*]JSValue, region_start_in: [*]JSValue, argc: u16, ) ForwardedEntryResult`。
- **作用**：`Function.prototype.apply` 窗口改写：密集 list 铺进窗口。`fastApplyArgs` 只承认 generic 体无需可观察 `[[Get]]` 就能拷的形状；洞、accessor、Proxy、改写过的 `length`、非对象走 `.generic`。
- **实现**：解析目标失败 `.generic`。undefined/null list 按 qjs:41224 当零参。否则 `fastApplyArgs` 失败 `.generic`。`target_argc+2 > old_total` 则 `growForwardedWindow`，失败 `.generic`。改写 `[thisArg, f, ...spread]`，`view.copyTo`。`finishForwardedEntry`。
- **所有权 / 错误 / 调用**：list view 是借来的堆指针，grow 后窗口随 `stack.values` 搬家。调用：`op_call_method` 的 apply 内建快路径。

### `resolveForwardedTarget` (`src/exec/tailcall_dispatch.zig:1226`)

- **签名**：`inline fn resolveForwardedTarget(vm: *Vm, target_value: JSValue) ?inline_calls.ResolvedInlineFunction`。
- **作用**：判定 `call`/`apply` 窗口里的 `target_value` 能否走同机字节码路径，能则返回解析好的 `ResolvedInlineFunction`。
- **实现**：三步守卫：`objectFromValue` 拿不到对象返回 null；`class_id != bytecode_function` 返回 null；否则把对象交给 `inline_calls.resolveInlineFunctionFromObject(vm.global, target_obj)`，由它决定是否可走同机字节码路径（跨 realm、未物化字节码等仍返回 null）。
- **所有权 / 错误 / 调用**：错误：无；不是对象、不是 `bytecode_function` 类、或 `resolveInlineFunctionFromObject` 不接受都返回 null，调用方据此返回 `.generic`。所有权：纯解析，不动窗口。调用：本文件 `:1189`（`Function.prototype.call` 臂）与 `:1209`（`apply` 臂）。

### `growForwardedWindow` (`src/exec/tailcall_dispatch.zig:1237`)

- **签名**：`noinline fn growForwardedWindow(vm: *Vm, sp: [*]JSValue, region_start: [*]JSValue, old_total: usize, new_total: usize) ?[*]JSValue`。
- **作用**：spread 装不下调用者操作数窗时的冷增长（从此走 heap backing，像 `vm_call` 的 spread-constructor 臂）。list view 不受影响。预约失败返回 null——什么都没动，generic apply 体去报 overflow。
- **实现**：用指针差算 `region_base`。`region_base + new_total <= capacity` 则原 `region_start`。否则 `setTopPtr(sp)`，`reserveAdditional(new_total-old_total)` catch null，返回 `stack.values + region_base`。
- **所有权 / 错误 / 调用**：reserve 失败不改语义窗口。调用：仅 `pushForwardedApplyEntry`。

### `finishForwardedEntry` (`src/exec/tailcall_dispatch.zig:1245`)

- **签名**：`inline fn finishForwardedEntry( vm: *Vm, region_start: [*]JSValue, target_argc: usize, old_total: usize, resolved: inline_calls.ResolvedInlineFunction, this_arg: JSValue, target_value: JSValue, native_caller: JSValue, ) ForwardedEntryResult`。
- **作用**：`call` / `apply` 窗口改写的共同收尾：清掉收缩后空出的槽、`frame.pc += 3`、retreat 到调用区并 poll，命中已发布 exact-args leaf 就走 `tryPushForwardedExactArgsLeafFast`，否则 `pushMethodCall` 并把跳过的 native 记录挂上 `Entry.native_caller`。
- **实现**：`new_total = target_argc + 2`；`new_total < old_total` 时把腾空的槽 `@memset` 成 undefined（已发布 top 之上不能留像活根的残值），`vm.frame.pc += 3`，`retreatToCallRegionFrom(&pending_call_region, region_start + new_total, region_start)` 把改写后的窗口登记成调用区，再 `pollRetreatedCallRegion`（真则 `.threw`）。随后是 O1 转发臂：`execution.exact_args_leaf_kind != .none` 且 `target_argc == function.arg_count` 且 `target_argc != 0` 时试 `tryPushForwardedExactArgsLeafFast`（把 `native_caller` 一并交进去），命中就带 `byteCodeAssumeMaterialized().ptr` 返回 `.entry`。否则 `resolved.bind(this_arg, target_value)` 后走 `pushMethodCall`，错误交 `callSetupRecover`（接住 `.handled`，否则 `.threw`）；成功时三条 Debug 断言钉死这不是 leaf/构造器完成帧（leaf 的 resume 记录会覆盖 `native_caller` 槽），再写 `entry.native_caller` 与 `has_native_caller = true`。
- **所有权 / 错误 / 调用**：`native_caller` 的所有权随 Entry；`new_total < old_total` 时空出的槽被写成 undefined，保证已发布 top 之上没有像活根的残值。错误：`pushMethodCall` 失败经 `callSetupRecover`，返回 `.handled` 或 `.threw`。调用：`pushForwardedCallEntry`、`pushForwardedApplyEntry`。

### `completeProxyGetContinuation` (`src/exec/tailcall_dispatch.zig:1306`)

- **签名**：`fn completeProxyGetContinuation(vm: *Vm, result: JSValue, atom_id: core.Atom) HostError!void`。
- **作用**：补完 qjs `js_proxy_get` 中必须发生在字节码 trap 返回**之后**的那部分：调用者栈尾是 `[target, key]`，成功时这两槽收缩成属性结果，失败时先移除再交给调用者的 catch 机制。
- **实现**：用 `core.runtime.rootValues` 把 `result`、`core.runtime.rootAtoms` 把 `atom_id` 显式登记成运行时根（`defer` 只做这两个根帧的 deactivate），因为随后的 `object_ops.validateProxyGetResult` 会跑 `[[GetOwnProperty]]`、可能重入 JS。校验失败：`stack.setLen(region_base)`、清空 rooted_result，再 `call_runtime.handleCatchableRuntimeError`，没被 catch 就把 err 原样返回。成功：`values[region_base] = rooted_result`、上面那槽写 undefined、`setLen(region_base + 1)`。
- **所有权 / 错误 / 调用**：`result` 的所有权在成功时转进调用者栈槽。错误：`HostError`（调用方 `op_post_call_continuation` 以 `vm.fail` 变成 `.threw`）。GC 根：显式的 `rootValues`/`rootAtoms` 根帧，覆盖可重入的校验窗口。调用：`op_post_call_continuation` 的 `.proxy_get` 臂、`driveReturnedContinuation`。

### `op_post_call_continuation` (`src/exec/tailcall_dispatch.zig:1372`)

- **签名**：`fn op_post_call_continuation(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：调用返回后的 continuation 分发器（不是字节码 opcode）：`op_return_slow` 以 `@call(.always_tail)` 进入这里，按 `vm.return_action` 完成 async_complete / proxy_get / to_boolean / for_of_next / native_boundary 的后续，再 `next` 或 `coldNext`。
- **实现**：先 `loadValueAsIntPair(&vm.return_value)` 取回结果并把 `return_value/return_action/return_payload` 三个载荷清回中性值，再按 `action` 分五臂：`.async_complete` 把结果写进 `machine.async_completions.at(payload).value` 后 `completeAsync`（失败走 `callSetupRecover`），promise 压栈；`.proxy_get` 调 `completeProxyGetContinuation`；`.to_boolean` 断言 payload 为 0，用 `coercion_ops.valueTruthy` 折成布尔写 `sp[0]` 并发布 `sp+1`，未被 L0 阻断就 `@call(.always_tail, next, …)`；`.for_of_next` 有一条同链快腿——非 L0 阻断、结果是普通对象（非 Proxy、无 exotic 方法）、栈还有 2 槽余量时，用 `findOwnDataSlotFast` 探 `done`/`value` 两个自有数据槽（`done` 必须是纯 bool 且为 false），命中就以整数对 store 写回 `[value, false]`、`setTopPtr(sp + 2)` 并尾调 `next`；任一条件不满足 `break :fast` 落到 `completeForOfNextContinuation`；`.native_boundary` 把结果写回 `vm.return_value` 并返回 `.native_returned`；`.constructor` 与 `.next` 是 `unreachable`。落地的臂统一以 `coldNext(var_buf, vm)` 收尾。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_return_slow` 以 `@call(.always_tail)` 进入；`driveReturnedContinuation` 在驱动侧做等价的 continuation 处理。

### `completeForOfNextContinuation` (`src/exec/tailcall_dispatch.zig:1442`)

- **签名**：`fn completeForOfNextContinuation(vm: *Vm, result: JSValue, depth: u8) HostError!void`。
- **作用**：for-of 的 `IteratorNext` 返回后的权威收尾：把迭代结果拆成 `value`/`done` 写回调用方窗口，并在本帧能 catch 时就地消化错误。
- **实现**：调 `iterator_ops.finishForOfNextResult`（把迭代结果拆成 value/done 写回调用方窗口）；它抛错时先 `call_runtime.handleCatchableRuntimeError` 看当前帧的 catch 目标能否接住——接住就正常返回（调用方随后 `coldNext` 到 handler），接不住把原 `err` 继续上抛。是本文件里少数**返回 `HostError!void` 而不是 `Outcome`** 的函数，因为它有两个调用点、两种续跑形状。
- **所有权 / 错误 / 调用**：错误：`HostError`——`finishForOfNextResult` 抛出后先交 `handleCatchableRuntimeError` 看本帧能否 catch，接住则正常返回，否则把原错误继续上抛。所有权：结果值由 `finishForOfNextResult` 压回调用方栈；本函数不额外持有。调用：本文件 `:1433`（`op_post_call_continuation` 的 `.for_of_next` 快腿 bail 之后）与 `:7173`（`driveReturnedContinuation` 的统一续延分派）。

### `loadValueAsIntPair` (`src/exec/tailcall_dispatch.zig:1477`)

- **签名**：`inline fn loadValueAsIntPair(slot: *const JSValue) JSValue`。
- **作用**：按两个 64-bit 字搬运 JSValue（避免 AArch64 `q` 访问不转发）。
- **实现**：单条转调 `JSValue.loadSlotAsIntPair(slot)`，把 16 字节槽读成两个 64 位整数字，而不是让 LLVM 合成一次 `ldur q0`。注释里最初写的理由（「`ldp` 不从 64 位半字存储转发」）已被 WP5 forwarding 实测推翻：`ldp` 从 `stp`、从两条独立 `str`、从部分重叠的更老存储都能正常转发（7.0-7.4 cyc）；真正不转发的是 SIMD 存储（`str q`/`str d`，通用寄存器读方要多付 ~4-7 cyc）。所以这里留整数对形式，图的是寄存器**域**和调度，不是转发。
- **所有权 / 错误 / 调用**：错误：无。所有权：按两个 64 位字读出 `JSValue` 副本，不改源槽、不建根。调用：本文件 39 处，如 `:341`（`takeNativeReturnInto`）、`:1376`、`:2338`。

### `loadValueAsSplitPair` (`src/exec/tailcall_dispatch.zig:1495`)

- **签名**：`inline fn loadValueAsSplitPair(slot: *const JSValue) JSValue`。
- **作用**：`loadValueAsIntPair` 的变体：AArch64 上把两个 64-bit 读钉成两条独立 `ldr`，其余架构退回 `JSValue.loadSlotAsIntPair`。
- **实现**：含 comptime 架构开关（只有 `builtin.cpu.arch == .aarch64` 才走内联汇编）。源码注释**推翻**了最初写下的「`ldp` 不从 64-bit 存储转发」理由：WP5 的 forwarding_matrix 实测 `ldp` 从 `stp`、两条独立 `str`、甚至部分重叠的更早存储都同样能转发（7.0-7.4 cyc，纯 `ldr x` 6.9），真正不转发的是 SIMD 存储（`str q`/`str d`）；所以拆开的形式只为调度收益保留，判据是寄存器域而不是转发。
- **所有权 / 错误 / 调用**：错误：无。所有权：与 `loadValueAsIntPair` 同语义，但 aarch64 上用两条独立 `ldr`（而非 `ldp`），以便寄存器分配器把两半分开调度；其余架构退回 `loadSlotAsIntPair`。调用：本文件 `:1879` 与 `:1915`（lean 帧返回臂取结果）。

### `storeValueAsIntPair` (`src/exec/tailcall_dispatch.zig:1518`)

- **签名**：`inline fn storeValueAsIntPair(slot: *JSValue, value: JSValue) void`。
- **作用**：按两个 64-bit 字搬运 JSValue（避免 AArch64 `q` 访问不转发）。
- **实现**：单条转调 `JSValue.storeSlotAsIntPair(slot, value)`，把 `JSValue` 按两个 64 位字写进槽。用它而不是整体赋值，是因为分支汇合后的聚合赋值（例如 get_field 命中臂里的 dup-或-借用 select）会让 LLVM 把值物化到 128 位栈槽再用 q 寄存器往返；拆成两条整数存储则保持值是 SSA 标量，且对下游 handler 的 64 位读是转发友好的——与 qjs 的 `sp[-1] = val` 落成 `stp` 一致。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 `JSValue` 按两个字写进目标槽；写入后该槽成为值的新位置，源槽（若有）由调用方负责。调用：本文件 42 处，如 `:584`（托管内联结果回写）、`:1437`、`:1576`（写 `vm.return_value`）。

### `popAndResume` (`src/exec/tailcall_dispatch.zig:1528`)

- **签名**：`inline fn popAndResume(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm, value: JSValue) Outcome`。
- **作用**：在 handler 内完成「弹掉将死帧 + 把结果交给调用者 + 续跑调用者」：对齐 qjs 的 OP_return + done: 收尾。
- **实现**：用寄存器里的 `vm.frame` 反推将死 Entry（`@fieldParentPtr`，Debug 断言它 == `machine.topEntry()`）。一次掩码测试分出五条臂：`isOrdinaryReturn` → `popOrdinaryFrame` + `reloadAfterPop` + push 结果 + `next`；`isNativeBoundaryReturn` → `popReturnedNativeBoundary` + 两字写 `return_value` + `.native_returned`；`isEmptyLeaf` → 读 resume {pc,sp}（一条 ldp）后扁平重发布调用者并 `next`；`isExactArgsLeaf and stack.len()==0` → 同形状再加 `.to_boolean` 转换与 args 窗口释放；`isForwardedLeaf and stack.len()==0` → 通过 `prev` 重新推导 resume。其余形态把结果写进多出的操作数槽，尾跳导出的 `zjs_op_return_slow_tail`。
- **所有权 / 错误 / 调用**：将死帧的 teardown 由 `Machine.pop*` 负责；结果所有权转交调用者栈。错误：本函数不失败。调用：`op_return_general` / `op_return_undef_general`。

### `op_return_slow` (`src/exec/tailcall_dispatch.zig:1747`)

- **签名**：`fn op_return_slow(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：special / constructor / 一般帧共享的返回收尾体（不是 opcode；`popAndResume` 经导出槽 `zjs_op_return_slow_tail` 尾跳进入）：结果已放在多出的那个操作数槽里，这里按帧形态完成拆帧与投递。
- **实现**：`pc`/`vb` 直接 `_ =` 丢弃；`result_sp = sp - 1` 取回 `popAndResume` 存进 scratch 槽的结果（`loadValueAsIntPair`），`syncSp(result_sp)`，再用 `@fieldParentPtr` 从 `vm.frame` 反推将死 Entry（Debug 断言 == `machine.topEntry()`）。随后四组臂：① `hasSpecialReturn()` 内分 `.async_complete`（写 `async_completions.at(id).value`、`popReturnedFrame` + `reloadAfterPop`、`completeAsync` 失败走 `callSetupRecover`，promise 压栈后 `coldNext`）、`isNativeBoundaryReturn`（`popReturnedNativeBoundary` + 两字写 `return_value` → `.native_returned`）、`isForwardedLeaf() and stack.len() == 0`（与 `popAndResume` 同形的 O3 窄尾声，resume {pc,sp} 经 `prev` 重新推导）；② `completesConstructor()` → `popConstructorReturn(value)` + `reloadAfterPop` + 压栈 + `next`；③ 其余先 `popReturnedFrame()` 拿续延并 `reloadAfterPop`，`continuation.action == .next` 就压栈续跑调用者；④ 带续延的把 `return_value`/`return_action`/`return_payload` 三个载荷发布出去、把续延清回 `.next`，尾调 `op_post_call_continuation`。紧随其后的 `export var zjs_op_return_slow_tail: Handler = op_return_slow;` 就是阻止 LLVM 把这段折回两个返回 handler 的优化屏障。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`popAndResume` 经导出槽 `zjs_op_return_slow_tail` 尾跳进入。

### `returnLeanTail` (`src/exec/tailcall_dispatch.zig:1864`)

- **签名**：`inline fn returnLeanTail(vm: *Vm, dying: *inline_calls.Entry, result_sp: [*]JSValue, value: JSValue) Outcome`。
- **作用**：lean native 边界返回（`inline_calls.LeanFrame`）的完整收尾：`syncSp` → `popReturnedLean` → 两字写 `vm.return_value` → `.native_returned`。
- **实现**：独立成体（而不是骑 `op_return` 的一般体），这样 `op_return` / `op_return_undef` 只需要保留 lean 判定、前言保持为空。
- **所有权 / 错误 / 调用**：结果以两个 64-bit 字交给驱动调用方；本函数不失败。调用：`op_return`、`op_return_undef` 的 `isLeanBoundaryReturn` 臂。

### `op_return_general` (`src/exec/tailcall_dispatch.zig:1874`)

- **签名**：`fn op_return_general(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：`op_return` 的一般体（不是独立 opcode；经导出槽 `zjs_op_return_general_tail` 尾跳进入）：取 `sp-1` 的结果、`syncSp` 后交给 `popAndResume`。
- **实现**：三条语句：`result_sp = sp - 1`、用 `loadValueAsSplitPair` 把结果读成两个独立 `ldr`（而不是合并的 `ldp`，实测那次合并占了整个 handler 三分之一的周期）、`vm.syncSp(result_sp)` 把精确的活跃边界发布出去，然后 `popAndResume(pc, result_sp, vb, vm, value)` 完成拆帧 + 把结果投进调用方窗口 + 恢复调用方。注意它**不** `publish`：qjs 的 OP_return 同样不更新 `sf->cur_pc`，拆帧只需要精确的栈边界。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_return` 经导出槽 `zjs_op_return_general_tail` 尾跳进入。

### `op_return_undef_general` (`src/exec/tailcall_dispatch.zig:1882`)

- **签名**：`fn op_return_undef_general(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：`op_return_undef` 的一般体（经导出槽 `zjs_op_return_undef_general_tail` 尾跳进入）：以 undefined 走 `popAndResume`。
- **实现**：两条语句：`vm.syncSp(sp)`（结果是常量 undefined，不用先弹栈），然后 `popAndResume(pc, sp, vb, vm, JSValue.undefinedValue())`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_return_undef` 经导出槽 `zjs_op_return_undef_general_tail` 尾跳进入。

### `op_return` (`src/exec/tailcall_dispatch.zig:1888`)

- **签名**：`fn op_return(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_return 的尾分发 handler，本体只做三岔判别（depth0 / lean native 边界 / 一般体），真正的拆帧在被尾跳的三条臂里；对齐 qjs check-free 的 `ret_val = *--sp; goto done;`。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`zjs_op_return_depth0_tail`、`zjs_op_return_general_tail`、`returnLeanTail`（`popAndResume` 只在一般体里）。 栈效应：弹出返回值并退出 handler 链。 下一跳：返回续跑：`popAndResume` / `returnLeanTail` 拆帧后 `cont` 调用者或 `.returned`；depth0/非 lean 尾跳 outlined `op_return_*` 臂。
- **所有权 / 错误 / 调用**：错误：本体无失败路径（qjs OP_return 同样是 check-free）；真正可能失败的只有 depth0 分臂 `op_return_depth0`，它 publish 后 `returnTop(...) catch |e| return vm.fail(e)`。所有权：`sp-1` 的结果值被移出操作数窗口交给 `popAndResume`/`returnLeanTail`，不再是栈上的根。三条分臂：depth0 → `zjs_op_return_depth0_tail`；非 lean 边界 → `zjs_op_return_general_tail`；lean native 边界 → `returnLeanTail`（`.native_returned`）。调用：作为 `specials.op_return`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:771` 装表，冷热两张表同一份。 注意它同时装在 `t[op.return_async]`（:773），所以 `return_async` 与 `return` 共用这一份 handler。

### `op_return_depth0` (`src/exec/tailcall_dispatch.zig:1918`)

- **签名**：`fn op_return_depth0(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：`op_return` 的 depth==0 兄弟（经导出槽 `zjs_op_return_depth0_tail` 尾跳进入）：publish 后完成可选 generator 收尾，把值写进 `vm.return_value` 并以 `.returned` 交回驱动。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_control.returnTop`、`publish`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：链出口：`Outcome.returned`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_return` 的 depth==0 臂经 `zjs_op_return_depth0_tail` 尾跳进入。

### `op_return_undef` (`src/exec/tailcall_dispatch.zig:1927`)

- **签名**：`fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_return_undef 的尾分发 handler，与 `op_return` 同形的三岔判别（depth0 / lean native 边界 / 一般体），只是结果固定为 undefined、不从栈上取值。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`inline_calls.Entry`。 栈效应：不弹值，返回 undefined 并退出。 下一跳：返回续跑：`popAndResume` / `returnLeanTail` 拆帧后 `cont` 调用者或 `.returned`；depth0/非 lean 尾跳 outlined `op_return_*` 臂。
- **所有权 / 错误 / 调用**：错误：同 `op_return`，本体无失败路径；depth0 分臂 `op_return_undef_depth0` 才可能 `vm.fail`。所有权：结果是常量 `undefined`，不涉及所有权转移；帧的拆除在 `popAndResume`/`returnLeanTail` 里。调用：作为 `specials.op_return_undef`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:772` 装表，冷热两张表同一份。

### `op_return_undef_depth0` (`src/exec/tailcall_dispatch.zig:1943`)

- **签名**：`fn op_return_undef_depth0(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：`op_return_undef` 的 depth==0 兄弟（经导出槽 `zjs_op_return_undef_depth0_tail` 尾跳进入）：publish 后 `vm_control.returnUndefined`，以 `.returned` 交回驱动。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_control.returnUndefined`、`publish`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：链出口：`Outcome.returned`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_return_undef` 的 depth==0 臂经 `zjs_op_return_undef_depth0_tail` 尾跳进入。

### `opCall` (`src/exec/tailcall_dispatch.zig:1958`)

- **签名**：`fn opCall(comptime argc_source: CallArgcSource) Handler`。
- **作用**：按 `CallArgcSource`（operand / zero / one / two / three）为 OP_call、OP_call0..3 各生成一份 handler，argc 与 pc 前进量在 comptime 定死，语义路径共用。
- **实现**：comptime 参数 `argc_source` 在展开时定死两件事：`argc`（`.operand` 读 `readInt(u16, pc + 1)`，其余是 0/1/2/3 常量）与指令长度 `insn_len`（`call argc:u16 idx:u8` 为 4，烧死元数的 `call0..3 idx:u8` 为 2）。它还控制几条臂是否成形——`comptime argc_source == .zero` 才编 warm 空叶/capture 叶臂，`.one/.two/.three` 才编 O1 exact-args 叶臂（`wire_exact_args_leaf`）；返回的 `struct { fn h(…) }.h` 带 `align(64)` 的 I-cache 钉（定元数实例内含展开的 exact-frame 构造器，体积变化不许推移邻居的前言相位）。 关键调用：`object_ops.objectFromValue`、`inline_calls.resolveInlineFunctionFromObject`。 下一跳（展开出的 handler 内）：内联叶命中 → `next`；同机入帧 → `enterEntry` → `next(callee_pc)`；冷续跑 → `coldNext`；`execCall` 的 `.inline_call` → `Outcome.tail`（`tail_mode = .push`）。
- **所有权 / 错误 / 调用**：错误：工厂本身无 error set；展开出的 handler 不抛 Zig error，helper 的 `HostError` 经 `vm.fail` 写 `vm.pending_error` 并返回 `.threw`。 所有权：comptime 工厂，返回 `struct { fn h(…) }.h`，运行期不存在。 调用：**不由分发进入**——在 `tailcall_dispatch.zig:2247`-`:2251` 被求值五次成 `op_call`/`op_call0..3`，再作为 `specials` 的五个字段在 `tailcall_dispatch_colds.zig:774`-`:778` 装进两张表。

### `opCall.h` (`src/exec/tailcall_dispatch.zig:1964`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opCall` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：`syncPc(pc, insn_len)` 后先校验 `live_bytes` 够 `argc + 1` 个槽（不够就整体落 `execCall`），取 `region_start = sp - (argc + 1)`、`func = region_start[0]`，一次 `objectFromValue` 后按 `class_id` 分两支。① `bytecode_function` 走 `resolveInlineFunctionFromObject`，命中即 `retreatToCallRegionFrom` 登记调用区，然后按 `call_facts.execution` 逐条试叶臂——`argc == 0` 时依次是 `simple_inline_empty_leaf`（sloppy）、`raw_this_inline_empty_leaf`（严格/箭头保留裸 undefined `this`）、`capture_leaf_kind`（O2，raw_this 走 inline warm、sloppy 走 outline warm）；定元数实例再试 `exact_args_leaf_kind` 且 `argc == fb.arg_count`（O1，sloppy inline warm / raw outline warm）；全不命中就 `resolved.bind(undefined, func)` 后 `pushAndEnter(.plain)`。② `c_function` 走 native 臂：`nativeCallTargetAssumeCFunction` 后 `entry.kind == .leaf` 时 `invokeLeafFastEntry` 就地算完并 `next`（K1），否则 `managedInlineEligible` 时 `callManagedFromWindow` + `managedInlineFinish`（K0），都不成才 `vm_native.dispatch`（`.hit` → `nativeHitNext`、`.caught` → `coldNext`、`.miss` 落下去）。③ `async_function` 类尾跳 `zjs_async_call_handlers[argc_source]`。所有 miss 汇到 `setTopPtr(sp)` + `call_runtime.execCall(..., allow_inline = false, &vm.tail_request)`。 下一跳：内联 native 叶命中 → `next`；同机入帧 → `enterEntry` → `next(callee_pc)`；冷续跑 → `coldNext`；`execCall` 的 `.inline_call` → `Outcome.tail`（`tail_mode = .push`）；异常 → `Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 另有一条不写 `pending_error` 的边：操作数窗口不足（`live_bytes` 校验）时直接落到 `execCall`，由它报错。所有权：命中内联时 `retreatToCallRegionFrom` 把 `[callable, args…]` 登记进 `machine.pending_call_region`，push 成功后归新 Entry；miss 时窗口交给 `execCall`（`allow_inline=false`）。`.inline_call` 置 `vm.tail_mode = .push` 后返回 `.tail`，由驱动的 `driveTailRequest` 接手。调用：`opCall` 工厂的五个实例分别装在 `t[op.call]`/`call0`/`call1`/`call2`/`call3`（`tailcall_dispatch_colds.zig:774`-`:778`），冷热两张表同一份。

### `enterNoSuspendAsync` (`src/exec/tailcall_dispatch.zig:2159`)

- **签名**：`inline fn enterNoSuspendAsync(vm: *Vm, vb: [*]JSValue, sp: [*]JSValue, region: [*]JSValue, argc: u16, comptime layout: inline_calls.RegionLayout, resolved: inline_calls.InlineTarget) Outcome`。
- **作用**：no-suspend async 调用的边界搭建：publish 栈顶 → `pollInterrupt` → `async_completions.begin` 取 id → 构造 Promise → retreat 调用区 → `pushAsyncMovedCall`，最后 `enterEntry` 进入被调者首条 opcode。
- **实现**：顺序是「发布 → 轮询 → 领 id → 建 Promise → 退调用区 → 建帧」：`stack.setTopPtr(sp)` → `exception_ops.pollInterrupt` → `machine.async_completions.begin(rt, resolved.callable)` 拿 `id` → `core.promise.constructWithPrototype` 建 Promise 挂进 `boundary.promise` → `layout == .method` 时把 `region[0]` 设成 `target.this_value` → `retreatToCallRegionFrom` 退窗口 → `machine.pushAsyncMovedCall(&target, region[0..argc + (method?2:1)], layout, id)` → `enterEntry`。建 Promise 与 `pushAsyncMovedCall` 失败时先 `store.release(id)` 收回边界记录再走 `callSetupRecover`（此前的 poll/`begin` 失败还没有 id，直接 `callSetupRecover`）；作用域发布先于分配，所以失败时不会重放用户代码。
- **所有权 / 错误 / 调用**：拿到 id 之后的失败先 `store.release(id)` 收回边界记录，再走 `callSetupRecover`（成功则 `coldNext`，否则 `.threw`）。作用域发布先于分配，操作数所有权只在 Promise/边界登记后才转移，失败不会重放用户代码。调用：`opAsyncCall` 展开体与 `op_async_call_method`。

### `opAsyncCall` (`src/exec/tailcall_dispatch.zig:2191`)

- **签名**：`fn opAsyncCall(comptime argc_source: CallArgcSource) Handler`。
- **作用**：按 `CallArgcSource` 为 async 被调者生成五份 handler：async setup 的原生临时量远多于普通调用，把它挡在单独的 tail-handler ABI 后面，普通字节码/native 臂的寄存器分配与栈帧才不会继承这份边界构造器。
- **实现**：comptime 工厂：`argc` 按 `argc_source` 在 comptime 定死（`.operand` 读 `readInt(u16, pc+1)`，其余是 0/1/2/3 常量），窗口 `region = sp - (argc + 1)`；`inline_calls.resolveNoSuspendAsync(ctx, global, region[0])` 命中就走 `enterNoSuspendAsync(.plain)`，否则 `stack.setTopPtr(sp)` 后落 `call_runtime.execCall`（`allow_inline=false`），按结果 `coldNext` 或置 `tail_mode = .push` 返回 `.tail`。pc 不在这里推进——`opCall` 已经推过了。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——`execCall` 的结果以 `Outcome` 返回；`.inline_call` 时置 `vm.tail_mode = .push` 并返回 `.tail`，由分发循环的 `driveTailRequest` 接手。所有权：这是 comptime 工厂，返回内部 `struct { fn h(...) }.h`；产出的 handler **不进 `dispatch_table`**，而是由 `src/exec/tailcall_dispatch.zig:2241` 的导出数组 `zjs_async_call_handlers: [5]Handler` 持有（`.operand`/`.zero`/`.one`/`.two`/`.three` 五个 argc 形态各一格），由 `opCall` 的 `async_function` 臂（`:2144`）尾跳进入。调用区 `[callable, args...]` 在 `enterNoSuspendAsync` 命中时移交给新帧，否则由 `execCall` 处理。调用：工厂本身只在 `:2241`-`:2244` 的导出数组初始化式里被求值五次。

### `h` (`src/exec/tailcall_dispatch.zig:2193`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：`opAsyncCall` 展开出的实际 Handler 体（五个 argc 形态各一份，挂在导出数组 `zjs_async_call_handlers`）。
- **实现**：见 `opAsyncCall` 的展开体：comptime 常量 argc → `region = sp - (argc+1)` → `resolveNoSuspendAsync` 命中走 `enterNoSuspendAsync`，未命中 `setTopPtr` + `execCall` → `.done/.continue_loop` 走 `coldNext`，`.inline_call` 置 `tail_mode = .push` 返回 `.tail`。 栈效应：-(argc+1)+1（callable+args → 结果，或整段移交新帧）。 下一跳：`enterEntry` → `next(callee_pc)` / `coldNext` / `Outcome.tail` / `.threw`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：命中 `resolveNoSuspendAsync` 时交给 `enterNoSuspendAsync`（它会 `async_completions.begin` 领一个 id 并构造 Promise，失败时 `store.release(id)` 回收）；否则窗口交给 `execCall`。调用：**不在任何分发表里**。`opCall` 的字节码/原生臂都不接受 async 被调者时，经导出数组 `zjs_async_call_handlers`（`tailcall_dispatch.zig:2241`，尾跳点在 `:2144`）进来，五个 argc 形态各一份。

### `op_async_call_method` (`src/exec/tailcall_dispatch.zig:2217`)

- **签名**：`fn op_async_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：`call_method` 的 async 被调者臂（不是独立 opcode；`op_call_method` 认出 `async_function` 类后经导出槽 `zjs_async_call_method_tail` 尾跳进入）：命中 no-suspend async 则入帧，否则回 `vm_call.callMethod`。
- **实现**：`argc = readInt(u16, pc+1)`，窗口 `region = sp - (argc + 2)`（`[receiver, callable, args…]`）；`resolveNoSuspendAsync(ctx, global, region[1])` 命中就 `frame.pc += 3` 后走 `enterNoSuspendAsync(.method)`；未命中时**故意不推进 pc**（`callMethod` 要求 pc 仍停在 argc 操作数上），`setTopPtr(sp)` 后落 `vm_call.callMethod`，按结果 `coldNext` / 置 `tail_mode = .push` 返回 `.tail`（`.inline_constructor` 在这条路径上 `unreachable`）。 栈效应：-(argc+2)+1。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_call_method` 认出 `async_function` 类后经 `zjs_async_call_method_tail` 尾跳进入。

### `op_apply` (`src/exec/tailcall_dispatch.zig:2250`)

- **签名**：`fn op_apply(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_apply 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_call.apply`、`call_runtime.resolveSameMachineSpreadConstructor`、`call_runtime.constructValueOrBytecodeWithNewTarget`、`call_runtime.popOwnedStackRegion`、`publish`、`coldNext`、`enterEntry`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；同机入帧：`enterEntry` → `next(callee_pc)`；异常：`Outcome.threw` / `vm.fail`；驱动入帧：`Outcome.tail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`.inline_constructor` 臂是全文件所有权最重的一段——`vm_call.apply` 提交的 `[func, new_target, args…]` 自有事务由 `enterSameMachineSpreadConstructor` 接手；防御臂里 `constructValueOrBytecodeWithNewTarget` 成功后 `popOwnedStackRegion(区域)` 再 `pushOwnedAssumeCapacity(result)`，失败走 `constructorRegionRecover`。调用：作为 `specials.op_apply`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:712` 装表，冷热两张表同一份。

### `op_call_method` (`src/exec/tailcall_dispatch.zig:2319`)

- **签名**：`fn op_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_call_method 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`inline_calls.resolveInlineFunctionFromObject`、`vm_call.resolvedNativeMethodRecordAssumeCFunction`、`builtin_dispatch.invokeLeafFastEntry`、`builtin_dispatch.invokeMethodLeafFastEntry`、`next`、`pushAndEnter`。 栈效应：-(argc+2)+1（receiver+callable+args）。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 另有窗口不足时直接落 `vm_call.callMethod` 的边。所有权：`[receiver, callable, args…]` 命中时经 `retreatToCallRegionFrom` 转给新 Entry，receiver 成为被调者的 `this`；miss 时 `frame.pc` 故意停在操作数上，交给 `callMethod` 自己解码。调用：作为 `specials.op_call_method`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:779` 装表，冷热两张表同一份。 它同时是 `specials.op_tail_call_method`（`tailcall_dispatch.zig:2993` 的 `const op_tail_call_method = op_call_method;`，装表在 :782）。

### `pushDerivedConstructorEntry` (`src/exec/tailcall_dispatch.zig:2533`)

- **签名**：`noinline fn pushDerivedConstructorEntry( vm: *Vm, region_base: usize, region_start: [*]JSValue, func: JSValue, candidate: *const call_runtime.SameMachineConstructorTarget, argc: u16, ) DerivedConstructorEntryResult`。
- **作用**：把 derived-only 帧 setup outline 出去，让已测量的普通构造器 handler 保持寄存器/分支形状。直接 derived 构造没有实例创建阶段，但仍保留 qjs 两次 interrupt poll：`JS_CallConstructorInternal` 入口，然后 `JS_CallInternal` 字节码入口、栈预检之前。
- **实现**：第一次 `pollInterrupt(vm.global)` 失败 → `constructorRegionRecover`，未抓住 `.threw`，抓住 `.handled`。第二次 poll `ctx.global orelse vm.global` 同样。`frame.pc += 2`。`constructor_this = uninitialized()` 写入 `region_start[0]`。`candidate.resolved.bind(uninitialized, func)`。`retreatToCallRegion`。`pushDerivedConstructorCall(..., owned_new_target=null)` catch → `constructorSetupRecover`。成功 `.entry`。
- **所有权 / 错误 / 调用**：poll 失败时区域仍完整，RegionRecover 会 pop。setup 失败区域已消费，只 SetupRecover。调用：`op_call_constructor` 的 derived 臂。

### `pushSpreadDerivedConstructorEntry` (`src/exec/tailcall_dispatch.zig:2572`)

- **签名**：`noinline fn pushSpreadDerivedConstructorEntry( vm: *Vm, region_base: usize, region_start: [*]JSValue, func: JSValue, candidate: *const call_runtime.SameMachineConstructorTarget, argc: u16, ) DerivedConstructorEntryResult`。
- **作用**：derived spread：独立拥有的 `new.target`，进入本适配器前已推进 OP_apply 的操作数。
- **实现**：两次 poll + RegionRecover 同直接 derived。读 `constructor_func=region_start[0]`、`owned_new_target=region_start[1]`。把 `[0]=uninitialized`、`[1]=constructor_func` 改成 method 布局。`pushDerivedConstructorCall(..., owned_new_target)`。失败 SetupRecover。
- **所有权 / 错误 / 调用**：`owned_new_target` 成功时交给帧；失败仍在区域里由 recover pop。调用：`enterSameMachineSpreadConstructor` 在 FB `isDerivedClassConstructor` 时。

### `enterSameMachineSpreadConstructor` (`src/exec/tailcall_dispatch.zig:2614`)

- **签名**：`fn enterSameMachineSpreadConstructor( vm: *Vm, region_base: usize, argc: u16, candidate: *const call_runtime.SameMachineConstructorTarget, ) DerivedConstructorEntryResult`。
- **作用**：从已提交的自有 `[func, new_target, args...]` 操作数事务进入 spread 构造：derived 走 `pushSpreadDerivedConstructorEntry`，否则 poll + `prepareSameMachineConstructorAfterFirstPoll` 后 `pushConstructorCall`，结果以 `DerivedConstructorEntryResult` 交回 `op_apply`（入帧由调用方 `enterEntry` 做）。
- **实现**：`region_start = stack.values + region_base`，取 `func = region_start[0]`、`new_target = region_start[1]`。派生类构造器直接转 `pushSpreadDerivedConstructorEntry`；否则 `exception_ops.pollInterrupt`（JS_CallConstructorInternal 的第一次轮询，早于实例创建与可构造性副作用），再 `prepareSameMachineConstructorAfterFirstPoll`。结果两分：`.completed` → `popOwnedStackRegion` + `pushOwnedAssumeCapacity(result)` 后 `.handled`；`.instance` → 把窗口就地改写成方法布局（`region_start[0] = instance`、`[1] = 原 func`，`new_target` 移进被调者 FrameCold 绑定）、`retreatToCallRegion`、`pushConstructorCall`，返回 `.entry`。
- **所有权 / 错误 / 调用**：`.completed` 时区域被 pop、结果压回栈；`owned_new_target` 成功时交给帧。错误经 `constructorRegionRecover` / `constructorSetupRecover`。调用：`op_apply` 的 `.inline_constructor` 臂。

### `op_call_constructor` (`src/exec/tailcall_dispatch.zig:2688`)

- **签名**：`fn op_call_constructor(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_call_constructor 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`small_inline.findInlinedSite`、`small_inline.applyForwardTakeOk`、`exception_ops.pollInterrupt`、`small_inline.tryFusedConstructor`、`small_inline.windowFits`、`small_inline.probe_prep`、`small_inline.probe_take`、`small_inline.installInlineWindow`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；同机入帧：`enterEntry` → `next(callee_pc)`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`owned_new_target` 与 `[func, new_target, args…]` 区域是自有的；成功 push 后交给新 Entry，失败走 `constructorSetupRecover`/`constructorRegionRecover`（与普通 OP_call 不同，这里**没有**隐含的 IteratorClose 步骤，因为构造器操作数区已被消费）。调用：作为 `specials.op_call_constructor`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:713` 装表，冷热两张表同一份。

### `op_for_of_next` (`src/exec/tailcall_dispatch.zig:2867`)

- **签名**：`fn op_for_of_next(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_for_of_next 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`iterator_ops.forOfIteratorIndex`、`inline_calls.resolveInlineFunction`、`iterator_ops.forOfNextVm`、`publish`、`next`、`tryPushBorrowedIteratorNextFast`、`enterEntry`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；同机入帧：`enterEntry` → `next(callee_pc)`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：迭代器记录 `[iterator, next_method, …]` 借用自调用方窗口；命中借用迭代器快臂时由 `pushBorrowedIteratorNext` 就地建帧（不复制），未命中才 `pushMovedCall` 把两个槽搬进新帧。失败经 `iteratorNextCallSetupRecover` 关闭迭代器。调用：作为 `specials.op_for_of_next`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:753` 装表，冷热两张表同一份。

### `op_tail_call` (`src/exec/tailcall_dispatch.zig:2967`)

- **签名**：`fn op_tail_call(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_tail_call 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`argc = readInt(u16, pc+1)`、`syncPc(pc, 4)`（argc:u16 + cache_idx:u8）、`setTopPtr(sp)`，然后 `call_runtime.execCall(..., is_tail = true, &vm.tail_request)`：`.done/.continue_loop` → `coldNext`；`.inline_call` → 置 `vm.tail_mode = .reuse_release` 返回 `.tail`，由驱动让被调者**复用调用方的物理 Entry** 并释放死去帧的记账（ES2015 PTC，`tail-calls.direct`/`mutual` 一百万层仍是常量栈）。原生/不可内联的被调者由 `execCall` 走完，再由残留的 `return` 桩收尾。 栈效应：-(argc+1)+1。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`execCall(..., is_tail=true, …)`；`.inline_call` 时置 `vm.tail_mode = .reuse_release` 并返回 `.tail`——被调者**复用调用方的物理 Entry** 并释放死去帧的 logical charge（ES2015 PTC）。这是与 `op_call` 唯一的所有权差别。调用：作为 `specials.op_tail_call`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:781` 装表，冷热两张表同一份。 只有严格模式函数体里才会出现这条 opcode（2026-08-18 strict-only PTC 裁决），sloppy 流里永远不会进来。

### `op_eval` (`src/exec/tailcall_dispatch.zig:2991`)

- **签名**：`fn op_eval(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_eval 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_eval_module.directEval`、`publish`、`coldNext`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`；驱动入帧：`Outcome.tail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`.tail_inline` 时把 `request` 存进 `vm.tail_request` 并置 `vm.tail_mode = .reuse_chain`——复用物理 Entry 但**仍然记账**（与 `op_tail_call` 的 `.reuse_release` 相反）。调用：作为 `specials.op_eval`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:783` 装表，冷热两张表同一份。

### `op_drop_fast` (`src/exec/tailcall_dispatch.zig:3030`)

- **签名**：`pub fn op_drop_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_drop 的热 handler（栈顶是 catch marker 时改走 `cold_table`）：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`JSValue.isCatchOffset`、`stack.setTopPtr`、`cont`（`vm_value.drop`/`coldNext` 只在注释里作对照，本体不调用）。 栈效应：寄存器 `sp` 净效应 -1，并且把 `stack.top_ptr` 一起收到 `sp-1`（释放前先缩根窗口），pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：弹栈前先 `vm.stack.setTopPtr(sp-1)` 把 GC 可见窗口缩到不含待释放槽（镜像 `vm_value.drop` 的 pop-before-free），否则 free 触发回收时那个槽还在 `stack.values[0..len]` 里。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:924`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 guard 是栈顶的 `catch_offset` 哨兵（try/finally 尾声），它要改 `vm.catch_target.*`，只能由冷壳 `op_drop` 做；另外 generator 参数/体停机边界时整条 opcode 走冷表，因为 `cont` 会跳过 `maybeStop`。

### `op_drop` (`src/exec/tailcall_dispatch.zig:3046`)

- **签名**：`fn op_drop(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_drop 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_value.drop`、`publish`、`coldNext`。 栈效应：-1 丢栈顶。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：`publish` 后 `vm_value.drop(...) catch |e| return vm.fail(e)`。所有权：弹掉的值由 `vm_value.drop` 释放；`.catch_target` 臂把 finally/catch 哨兵写进 `vm.catch_target.*`（这是它必须留在冷壳里的原因——快臂改不了 `catch_target`）。调用：作为 `specials.op_drop`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:784` 装表，冷热两张表同一份。 但 `dispatch_table` 的这一格随后被 `op_drop_fast` 覆盖（`:924`），所以它实际**只在 `cold_table` 里**，由 `op_drop_fast` 认出 `catch_offset` 哨兵后经 `cold_table[pc[0]]` 进来。

### `op_throw` (`src/exec/tailcall_dispatch.zig:3056`)

- **签名**：`fn op_throw(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_throw 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_control.throwTop`、`publish`、`coldNext`。 栈效应：弹抛出值；命中 catch 则 `coldNext`，否则 `.threw`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：`publish` 后 `vm_control.throwTop(...) catch |e| return vm.fail(e)`；正常路径本身就是抛 JS 异常（不是 Zig error），所以 helper 返回 `.handled` 后仍走 `coldNext` 回到 catch 目标。所有权：栈顶的异常值交给 helper。调用：作为 `specials.op_throw`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:785` 装表，冷热两张表同一份。

### `op_throw_error` (`src/exec/tailcall_dispatch.zig:3062`)

- **签名**：`fn op_throw_error(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_throw_error 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_control.throwErrorVm`、`publish`、`coldNext`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：同 `op_throw`——`throwErrorVm` 构造并抛出引擎自造的 Error 对象（会分配），失败才 `vm.fail`。所有权：新 Error 对象由 helper 建根/抛出，壳不持有。调用：作为 `specials.op_throw_error`（`tailcall_dispatch.zig:6889` 起的 `specials` 字面量）交给 `colds.buildTable`，在 `tailcall_dispatch_colds.zig:786` 装表，冷热两张表同一份。

### `h_initial_yield.b` (`src/exec/tailcall_dispatch.zig:3070`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue`。
- **作用**：`h_initial_yield = coldGen(...)` 的 body 函数（不是 Handler 本身）：跑 `vm_gen_async.initialYield`，`.return_value` 臂把值交回让 `coldGen` 的壳返回 `.returned`，`.none`/`.continue_loop` 返回 null 让壳走 `coldNext`。
- **实现**：`coldGen` 的 body：丢弃 `pc`，调 `vm_gen_async.initialYield`，把 d==0 才有意义的 L0 字段用三元守卫传进去（`machine.depth == 0` 时取 `machine.l0.generator_state` / `l0.stop_on_yield`，否则 null/false），再把结果折成 `?JSValue`：`.none`/`.continue_loop` → null（外壳 `coldNext` 继续跑），`.return_value` → 值（外壳写 `vm.return_value` 并 `.returned` 退出整条链）。 栈效应由 helper 在已发布的 `Stack` 上完成。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `coldGen` 的壳转成 `vm.fail` / `.threw`。 调用：只被 `coldGen` 的 Handler 壳调用（本身不进分发表）。

### `h_yield.b` (`src/exec/tailcall_dispatch.zig:3079`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue`。
- **作用**：`h_yield = coldGen(...)` 的 body 函数（不是 Handler 本身）：跑 `vm_gen_async.yieldValue`，`.return_value` 臂把值交回让 `coldGen` 的壳返回 `.returned`，`.none`/`.continue_loop` 返回 null 让壳走 `coldNext`。
- **实现**：`coldGen` 的 body：丢弃 `pc`，调 `vm_gen_async.yieldValue`，把 d==0 才有意义的 L0 字段用三元守卫传进去（`machine.depth == 0` 时取 `machine.l0.generator_state` / `l0.stop_on_yield`，否则 null/false），再把结果折成 `?JSValue`：`.none`/`.continue_loop` → null（外壳 `coldNext` 继续跑），`.return_value` → 值（外壳写 `vm.return_value` 并 `.returned` 退出整条链）。 栈效应由 helper 在已发布的 `Stack` 上完成。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `coldGen` 的壳转成 `vm.fail` / `.threw`。 调用：只被 `coldGen` 的 Handler 壳调用（本身不进分发表）。

### `h_yield_star.b` (`src/exec/tailcall_dispatch.zig:3088`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue`。
- **作用**：`h_yield_star = coldGen(...)` 的 body 函数（不是 Handler 本身）：跑 `vm_gen_async.yieldStar`，`.return_value` 臂把值交回让 `coldGen` 的壳返回 `.returned`，`.none`/`.continue_loop` 返回 null 让壳走 `coldNext`。
- **实现**：`coldGen` 的 body：丢弃 `pc`，调 `vm_gen_async.yieldStar`，把 d==0 才有意义的 L0 字段用三元守卫传进去（`machine.depth == 0` 时取 `machine.l0.generator_state` / `l0.stop_on_yield`，否则 null/false），再把结果折成 `?JSValue`：`.none`/`.continue_loop` → null（外壳 `coldNext` 继续跑），`.return_value` → 值（外壳写 `vm.return_value` 并 `.returned` 退出整条链）。 栈效应由 helper 在已发布的 `Stack` 上完成。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `coldGen` 的壳转成 `vm.fail` / `.threw`。 调用：只被 `coldGen` 的 Handler 壳调用（本身不进分发表）。

### `h_await.b` (`src/exec/tailcall_dispatch.zig:3097`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue`。
- **作用**：`h_await = coldGen(...)` 的 body 函数（不是 Handler 本身）：跑 `vm_gen_async.awaitValue`，`.return_value` 臂把值交回让 `coldGen` 的壳返回 `.returned`，`.none`/`.continue_loop` 返回 null 让壳走 `coldNext`。
- **实现**：`coldGen` 的 body：丢弃 `pc`，调 `vm_gen_async.awaitValue`，把 d==0 才有意义的 L0 字段用三元守卫传进去（`machine.depth == 0` 时取 `machine.l0.generator_state` / `l0.stop_on_yield`，否则 null/false），再把结果折成 `?JSValue`：`.none`/`.continue_loop` → null（外壳 `coldNext` 继续跑），`.return_value` → 值（外壳写 `vm.return_value` 并 `.returned` 退出整条链）。另外多传一个 `l0.suspend_on_module_await`（模块顶层 await）。 栈效应由 helper 在已发布的 `Stack` 上完成。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `coldGen` 的壳转成 `vm.fail` / `.threw`。 调用：只被 `coldGen` 的 Handler 壳调用（本身不进分发表）。

### `opBinary` (`src/exec/tailcall_dispatch.zig:3144`)

- **签名**：`pub fn opBinary(comptime kind: BinOp) Handler`。
- **作用**：为 add/sub/mul/div/mod/shl/sar/shr/and/or/xor 十一个二元算术 opcode 各产一份 handler（qjs 每个 CASE 各有独立的 both-int 快腿）：both-int32 命中就在寄存器上算完写 `sp[-2]` 并 `cont`，未命中尾跳 `opBinaryFloat(kind)`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`JSValue.asInt32Pair`、`value_ops.numberToValue`、`opBinaryFloat`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂本身无 error set；产出的 handler 也不写 `pending_error`（未命中都是尾跳）。所有权：comptime 工厂，返回 `struct { fn hnd(…) }.hnd`，运行期不存在。调用：**不由分发进入**，只在建表时被求值——`tailcall_dispatch_colds.zig:886`-`:896` 为 add/sub/mul/div/mod/shl/sar/shr/and/or/xor 各产一份装进 `dispatch_table`；另外本文件 `:7398`（`op_push_0_or` → `.bor`）、`:7430`（`op_push_2_sar` → `.sar`）、`:7476`（`op_push_0_shr` → `.shr`）、`:7534`（`op_push_i8_add` → `.add`）在 comptime 取出它的实例做直接尾跳。

### `opBinary.hnd` (`src/exec/tailcall_dispatch.zig:3147`)

- **签名**：`fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opBinary` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`JSValue.asInt32Pair`、`value_ops.numberToValue`、`opBinaryFloat`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 整数对未命中时先 PC-relative 直跳同文件的 `opBinaryFloat(kind)`，那一层再决定是 `resident_tail_tbl` 的字符串加法臂、float 臂，还是 `cold_table[pc[0]]`。所有权：两个整数操作数不带引用计数，结果就地写 `sp[-2]`，无所有权转移。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:886-896`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 每个 `BinOp` 一份独立实例（qjs 的 CASE(OP_add)…CASE(OP_xor) 各自独立标号）。`op.pow` 不在此列，留在冷壳（qjs OP_pow 同样直接落 `js_binary_arith_slow`）。

### `opBinaryFloat` (`src/exec/tailcall_dispatch.zig:3244`)

- **签名**：`fn opBinaryFloat(comptime kind: BinOp) Handler`。
- **作用**：为 `opBinary` 的 both-int32 未命中臂提供内联 float64 腿（对齐 qjs OP_add 的 float 腿）：add 先认双字符串臂，add/sub/mul 双数值时就地算出 `float64` 写 `sp[-2]` 并 `cont`，div/mod 与位运算一律落冷表。
- **实现**：comptime 参数只有 `kind`（`BinOp`），它决定编出哪几条臂：`kind == .add` 才编双字符串判定（命中尾跳 `residentTailHandler(vm, .add_strings)`）；`.add/.sub/.mul` 才编 `value_ops.numberValue` 双取的 float 臂（f64 或 int32 都接受，算完 `JSValue.float64(d)` 写 `sp[-2]` 后 `cont(pc+1, sp-1)`），其余 kind 直接落 `cold_table[pc[0]]`。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` → `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；间接驻留尾：`resident_tail_tbl[.add_strings]`。
- **所有权 / 错误 / 调用**：错误：工厂无 error set；产出的 handler 不写 `pending_error`。所有权：comptime 工厂。调用：**不进任何表**，唯一消费点是 `opBinary` 产出的 handler 在 `asInt32Pair` 未命中时 `@call(.always_tail, opBinaryFloat(kind), …)`（`:3153`）——同文件 PC-relative 直跳，既不过表也不过 `cont`。

### `hnd` (`src/exec/tailcall_dispatch.zig:3246`)

- **签名**：`fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opBinaryFloat` 展开出的实际 Handler 体：不进分发表，由 `opBinary` 的 both-int 未命中臂 `always_tail` 进入。
- **实现**：`kind == .add` 时先看两个操作数是否都是字符串，是就尾跳 `residentTailHandler(vm, .add_strings)`（那一份才 publish、才分配）。随后只有 `.add/.sub/.mul` 编 float 臂：`value_ops.numberValue` 对两个槽各取一次（f64 与 int32 都收），都成功就按 kind 算出 `d`，`JSValue.float64(d)` 写进 `sp[-2]` 再 `cont(pc + 1, sp - 1, …)`；任何一步不成立都 `@call(.always_tail, cold_table[pc[0]], …)`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。
- **所有权 / 错误 / 调用**：错误：本体不写 `pending_error`。三条出边：add 的双字符串臂 `residentTailHandler(vm, .add_strings)`（那一份才 publish 并分配）、双数值臂就地写 `sp[-2]` 后 `cont`、其余 `cold_table[pc[0]]`。所有权：float 结果是非引用计数的裸值，就地覆盖 `sp[-2]` 并弹掉 rhs，无所有权转移；字符串臂把两个操作数的所有权交给 `op_add_strings`（`addStringsOwned` 消费它们）。调用：**不在任何表里**，唯一入口是 `opBinary` 产出的 handler 的 `@call(.always_tail, opBinaryFloat(kind), …)`（`:3153`）。div/mod 与位运算不走这条 float 臂（前者带 qjs 的零/符号/-0 特例，后者要 ToInt32）。

### `op_add_strings` (`src/exec/tailcall_dispatch.zig:3282`)

- **签名**：`fn op_add_strings(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：驻留尾表槽 `resident_tail_tbl[.add_strings]`（不是独立 opcode）：OP_add 两操作数都是字符串时由 `opBinaryFloat` 间接尾调用进入，`addStringsOwned` 拼接后 `cont`。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`value_ops.addStringsOwned`、`call_runtime.handleCatchableRuntimeError`、`publish`、`coldNext`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由对应热 handler 经 `residentTailHandler(vm, .add_strings)` 间接尾调用进入（不在 256 槽分发表里）。

### `cont` (`src/exec/tailcall_dispatch.zig:3306`)

- **签名**：`inline fn cont(npc: [*]const u8, nsp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：热路径直接尾分发下一条 opcode，跳过 `next` 的 Debug 断言。
- **实现**：剖析构建调用 `noteDispatch` 后 `@call(.always_tail, dispatch_table[npc[0]], {npc,nsp,var_buf,vm})`。热 opcode 之间不经过 `next`，避免多一次间接跳与 Debug 断言。
- **所有权 / 错误 / 调用**：错误：无。所有权：不持值。调用：`inline fn`，不是 Handler、不进表；本文件 145 处热臂以它收尾。**关键差别**：它读的是编译期常量 `dispatch_table`，不是 `vm.active_dispatch_tbl`——所以 L0 `stop_before_pc` seam 下不能用 `cont`（那会跳过 `maybeStop`），这也是 `op_drop_fast`、`op_update_loc_cold`、`op_add_loc_cold` 等都要先查 `vm.local_fast_blocked` 的原因。剖析计数 `noteDispatch` 只挂在 `cont` 与 `next`。

### `opLoc` (`src/exec/tailcall_dispatch.zig:3318`)

- **签名**：`pub fn opLoc(comptime kind: LocKind, comptime idx_src: LocIdx) Handler`。
- **作用**：为局部变量访问的 `kind`×`idx_src` 共 18 个变体各产一份 handler（对齐 qjs 的 OP_get_loc0..3 等独立 CASE 标号），局部下标在 comptime 定死，handler 直接 `cont`。
- **实现**：comptime 展开 get/put/set × c0..c3/byte/half 共 18 个独立 Handler（对齐 qjs 各 CASE 标签）。get：`sp[0]=var_buf[idx]; cont(pc+adv, sp+1)`；put 写后 `sp-1`；set 写后 `sp` 不变。局部基址是入帧时的 `var_buf`（= `frame.locals.ptr`），不是每次从 Frame 重载。
- **所有权 / 错误 / 调用**：错误：工厂无 error set；产出的 handler 无失败路径。所有权：comptime 工厂，`kind`×`idx_src` 共 18 个实例。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:831`-`:848` 被求值 18 次装进 `dispatch_table`（get/put/set × loc0-3/loc8/loc）；另外本文件 `:6568`（`op_put_loc8_get_loc8`）与 `:7511`（`tailGetLoc8` 兜底臂）在 comptime 取 `opLoc(.get, .byte)` 实例做直接尾跳。

### `opLoc.h` (`src/exec/tailcall_dispatch.zig:3321`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opLoc` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：`idx` 与 `advance` 都在 comptime 由 `idx_src` 定死（c0-c3 → 常量 0-3、advance 1；`.byte` → `pc[1]`、advance 2；`.half` → `readInt(u16, pc+1)`、advance 3），没有运行期的操作数解码 csel 链（旧的一份 handler 管 18 个变体，实测每条多约 15 insn）。随后按 comptime 的 `kind` 三分：`.get` 写 `sp[0] = var_buf[idx]` 后 `cont(pc+advance, sp+1)`；`.put` 取 `(sp-1)[0]` 写进局部后 `cont(…, sp-1)`；`.set` 同写但不弹。 栈效应：get +1、put -1、set 0。 下一跳：`cont` → `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 `get` 写 `sp[0]` 后 `sp+1`，`put` 从 `sp-1` 取值写 `var_buf[idx]` 后 `sp-1`，`set` 写完不弹。所有权：帧局部槽是 trace-owned 的普通 `ValueSlot`，覆盖不需要 release 尾巴，也不需要写屏障（同一帧内的移动）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:831-848`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 18 个 `kind`×`idx_src` 实例各占一格，qjs 风格的每变体独立标号，运行期不解码操作数。

### `opLocCheck` (`src/exec/tailcall_dispatch.zig:3372`)

- **签名**：`pub fn opLocCheck(comptime kind: LocKind) Handler`。
- **作用**：为 `get_loc_check`/`put_loc_check`/`set_loc_check` 三个 TDZ 受检局部访问 opcode 各产一份 handler（受检编码只有 u16 操作数形态，没有短变体）：槽未初始化就整条落冷壳抛 ReferenceError，否则在寄存器上完成读写并 `cont`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：随 `kind` 而定——get +1、put -1、set 0；pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂，三个实例（get/put/set）。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:855`-`:857` 求值装进 `dispatch_table`（`get_loc_check`/`put_loc_check`/`set_loc_check`）。注意 `get_loc_checkthis` 与 `put_loc_check_init` 不在这里，另有归属。

### `h` (`src/exec/tailcall_dispatch.zig:3375`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opLocCheck` 展开出的实际 Handler 体（get/put/set_loc_check 各一份），挂进 256 槽分发表。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：随 `kind` 而定——get +1、put -1、set 0；pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 这里的 guard 是 TDZ：`var_buf[idx].is(.uninitialized)` 时整条交给冷壳抛 ReferenceError。所有权：`put`/`set` 臂优先走 `trySetInt32FromSlot`（保住目的槽的 tag、只搬 payload），未命中才整值覆盖；都在帧内，无屏障。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:855-857`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_set_loc_uninitialized` (`src/exec/tailcall_dispatch.zig:3409`)

- **签名**：`pub fn op_set_loc_uninitialized(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_set_loc_uninitialized 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：两条：`idx = readInt(u16, pc+1)`、`var_buf[idx] = JSValue.uninitialized()`，然后 `cont(pc+3, sp, var_buf, vm)`。对应 qjs CASE(OP_set_loc_uninitialized) 的 store-then-`JS_FreeValue`——普通槽下那次 free 是 no-op，所以这里只剩一条存储。 栈效应：0，pc 前进 3 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：把 `JSValue.uninitialized()` 写进 `var_buf[idx]`，是纯槽写（qjs CASE(OP_set_loc_uninitialized) 的 store-then-free 序列里 free 对普通槽是 no-op）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:859`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_loc_check_init` (`src/exec/tailcall_dispatch.zig:3420`)

- **签名**：`pub fn op_put_loc_check_init(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_loc_check_init 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：把 `sp-1` 的值写进局部后弹栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:860`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 guard 是 `vm.function.isDerivedClassConstructor()`——派生构造器的 `this` 只能初始化一次，这个检查是可观测的，必须留在冷壳。

### `opGetVarRef` (`src/exec/tailcall_dispatch.zig:3433`)

- **签名**：`pub fn opGetVarRef(comptime idx_src: VarRefIdx) Handler`。
- **作用**：为闭包/全局 var-ref 读取的五个形态（`get_var_ref0..3` 与 u16 的 `get_var_ref`/`get_var_ref_check`）各产一份 handler（对齐 qjs 的独立 CASE 标号），下标与指令长度在 comptime 定死。
- **实现**：comptime 参数 `idx_src` 定死 `idx`（c0-c3 → 常量 0-3；`.half` → `readInt(u16, pc + 1)`）与 `advance`（短形态 1、`.half` 3），并决定是否编 TDZ 探测——只有 `.half` 编（它同时服务 `get_var_ref_check`）。 Debug/Safe 下有不变量断言（`idx < frame.var_refs.len` 的编译期越界契约，以及 `var_refs_base == frame.var_refs.ptr` 的 seam 泄漏探测）。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1。 下一跳：热成功：`cont` → `dispatch_table[npc[0]]`；TDZ 未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂，五个实例（c0-c3、half）。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:988`-`:993` 求值装表；`.half` 一份同时服务 `get_var_ref` 与 `get_var_ref_check`，所以只有它保留 TDZ 探测。

### `opGetVarRef.h` (`src/exec/tailcall_dispatch.zig:3439`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opGetVarRef` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：读链是 `vm.var_refs_base[idx]` 取 cell、再 `cell.pvalue.*` 取值（槽类型已是 `[]*core.VarRef`，所以没有「这个槽是不是 cell」的头部判定；嵌套 cell 检查也已退休——direct eval 的 const 视图改成 pvalue 别名而不是嵌套）。`.half` 实例在取值后加一条 `is(.uninitialized)` 的 TDZ 探测，命中就整条尾跳 `cold_table[pc[0]]`。随后 `sp[0] = v` 并 `cont(pc + advance, sp + 1, …)`。 Debug/Safe 下有两条断言（越界契约 + seam 泄漏探测）。 栈效应：寄存器 `sp` 净效应 +1。 下一跳：热成功：`cont` → `dispatch_table[npc[0]]`；TDZ 未命中：`cold_table[pc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 只有 `.half` 实例保留 `is(.uninitialized)` 的 TDZ 探测（它同时服务 `get_var_ref_check`）；c0-c3 四个短形态按 qjs OP_get_var_ref0..3 完全无 TDZ 检查。所有权：从 `vm.var_refs_base[idx]` 这条 cell 读出 `cell.pvalue.*` 压栈，是借用副本，不 retain。越界不检查——finalize 的 `validateVarRefOperandBounds` 与建帧时的 `captureSlice` 保证 `idx < var_refs.len`，只在 Debug/ReleaseSafe 留断言（另有一条 `var_refs_base == frame.var_refs.ptr` 的 seam 泄漏探测断言）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:988-993`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `opPutVarRef` (`src/exec/tailcall_dispatch.zig:3492`)

- **签名**：`pub fn opPutVarRef(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`put_var_ref0..3` 与 u16 的 `put_var_ref` 共用的一份 handler：把栈顶值写进闭包 cell 并弹栈，对齐 qjs 的 set_value（最终字节码不会把只读绑定送到这里）。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误（越界与非法形态由 emit 侧保证，Debug 断言）。 所有权：把 `sp-1` 的值写进 `cell.pvalue.*`。**有写屏障**——handler 直接写 `cell.pvalue`（没有走 `VarRef.setVarRefValue`），所以必须自己调用 `vm.ctx.runtime.gc.generationalBarrier(&cell.header, …)`：cell 可能在老年代而新值在新生代。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:994-998`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_var_ref_check` (`src/exec/tailcall_dispatch.zig:3531`)

- **签名**：`pub fn op_put_var_ref_check(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_var_ref_check 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`VarRef.pvalue` 直写、`gc.generationalBarrier`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 guard 是 TDZ 探测 `cell.pvalue.*.is(.uninitialized)`；TDZ 抛错、合成边界与 generator 停机形态都落冷壳 `h_varref`（`execPutVarRef`）。 所有权：与 `opPutVarRef` 相同——直写 `cell.pvalue` 并自带 `generationalBarrier`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:1002`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `opSetVarRef` (`src/exec/tailcall_dispatch.zig:3558`)

- **签名**：`pub fn opSetVarRef(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`set_var_ref0..3` 与 u16 的 `set_var_ref` 共用的一份 handler：与 `put_var_ref` 同样写 cell，但保留栈顶值作为赋值表达式的结果（不弹栈）。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`set_*` 形态写完**不弹栈**（值仍留在栈顶），同样直写 `cell.pvalue` 并自带 `generationalBarrier`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:1003-1007`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_i32` (`src/exec/tailcall_dispatch.zig:3585`)

- **签名**：`pub fn op_push_i32(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_i32 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`sp[0] = JSValue.int32(readInt(i32, pc + 1))` 后 `cont(pc + 5, sp + 1, …)`。`align(64)` 的 I-cache 钉（同 `op_return`）让它的入口对齐不随 dispatch 单元里无关的 text 尺寸变化漂移。 栈效应：+1，pc 前进 5 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：把 4 字节立即数装成 `JSValue.int32` 压栈，非引用计数裸值。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:823`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_const` (`src/exec/tailcall_dispatch.zig:3595`)

- **签名**：`pub fn op_push_const(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_const 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 5 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：`constantAt` 返回的是常量池里的借用值，压栈不 retain（qjs OP_push_const 的 `JS_DupValue` 在 zjs 的 trace GC 下不需要）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:826`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 guard 是 `constantAt` 返回 null（畸形/合成字节码）。

### `op_push_const8` (`src/exec/tailcall_dispatch.zig:3602`)

- **签名**：`pub fn op_push_const8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_const8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：同 `op_push_const`，索引是 1 字节。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:827`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `opFclosure` (`src/exec/tailcall_dispatch.zig:3617`)

- **签名**：`pub fn opFclosure(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`fclosure`/`fclosure8` 共用的一份 handler：解码常量池下标、构造字节码函数对象（闭包）并压栈，对齐 qjs 在 CASE 里直接 `*sp++ = js_closure(...)` 的形态。
- **实现**：`wide_index = pc[0] == op.fclosure` 决定 `advance`（5 或 2）与索引宽度（u32 或 u8）；先 `syncPc(pc, advance)` + `syncSp(sp)` 让 pc 与活跃操作数窗口都成为权威（构造会分配、可能触发回收），再 `vm.function.constantAt(index)` 取字节码值（null → `vm.fail(error.InvalidBytecode)`），`object_ops.createBytecodeFunctionObject(ctx, frame, global, bytecode_value)` 构造闭包对象。**结果槽从 `vm.stack.topPtr()` 重新取**（`Stack.reserveAdditional` 可能在构造期间重写 `stack.values`，qjs 的 `*sp++` 因为操作数栈是 alloca 的所以不必），写值后 `cont(pc+advance, result_sp+1, …)`。 栈效应：+1。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：`constantAt` 返回 null 时 `vm.fail(error.InvalidBytecode)`；`createBytecodeFunctionObject` 的 `HostError` 同样经 `vm.fail` 变 `.threw`。 所有权：**会分配**。构造闭包对象前先 `syncPc(pc, advance)`（用户可见的 backtrace 保真）+ `syncSp(sp)`，让活跃操作数窗口留在根集；构造可能触发回收并让 `Stack.reserveAdditional` 重写 `stack.values`，所以结果槽是从 `vm.stack.topPtr()` **重新取**的（`result_sp`），不能复用寄存器 `sp`——这是每个会分配的常驻 handler 都要做的再推导。新对象的所有权移交给那个槽。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:866-867`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 `fclosure` 与 `fclosure8` 共用这一份，宽/窄索引在函数内按 `pc[0]` 分。

### `op_push_atom_value` (`src/exec/tailcall_dispatch.zig:3649`)

- **签名**：`pub fn op_push_atom_value(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_atom_value 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`cont`、`publish`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 5 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：缓存命中臂无错误；miss 臂 `publish` 后 `toStringValue(...) catch |err| return vm.fail(err)`。 所有权：**miss 臂会分配**（`String.createUtf8` 物化 atom 体）。它必须先 `publish`：`Stack.liveValues` 只看到 `stack.top_ptr` 为止，数组字面量是一串连续 push，第九个元素上的 miss 曾经把上面八个还未发布的字符串回收掉（test262 `staging/sm/RegExp/unicode-disallow-extended.js`；TGC S3-c 之前被 atom 表的 `entries[].str` 根掩盖）。缓存命中的那份是借用值，压栈不 retain。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:879`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_special_object` (`src/exec/tailcall_dispatch.zig:3673`)

- **签名**：`pub fn op_special_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_special_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；间接驻留尾：`resident_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。三条出边：`current_function` 子类型直接把 `vm.frame.current_function` 压栈后 `cont`；`arguments`/`mapped_arguments` 转 `residentTailHandler(vm, .special_arguments)`（那一份才分配 arguments 对象）；其余子类型 `cold_table[pc[0]]`。 所有权：THIS_FUNC 臂只是复制帧里已有的函数值，不分配、不 retain。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:880`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_special_arguments` (`src/exec/tailcall_dispatch.zig:3687`)

- **签名**：`fn op_special_arguments(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：驻留尾表槽 `resident_tail_tbl[.special_arguments]`（不是独立 opcode）：OP_special_object 的 arguments / mapped_arguments 子型由 `op_special_object` 间接尾调用进入。
- **实现**：读 `subtype = pc[1]`，`syncPc(pc, 2)` + `syncSp(sp)`（builder 会分配、可能回收，活跃的前置操作数必须留在根集），调 `object_ops.frameArgumentsObjectForSpecialObject(ctx, global, frame, subtype)` 建 arguments / mapped arguments 对象，失败 `vm.fail(err)`；成功把自有对象写进预留的栈槽 `sp[0]` 后 `cont(pc+2, sp+1, …)`——与 `coldStd` 不同，成功路径**没有任何一方重读**那两次发布。 栈效应：+1，pc 前进 2 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由对应热 handler 经 `residentTailHandler(vm, .special_arguments)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_push_this` (`src/exec/tailcall_dispatch.zig:3722`)

- **签名**：`pub fn op_push_this(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_this 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：对象 `this` 直接复制压栈（与模式无关）；严格模式下非对象的 `this` 只要不是 uninitialized，也照样按 qjs `normal_this` 原样压栈；sloppy 下 undefined/null 换成 realm global 的值（不回写帧槽）。真正留在冷壳的只有两类：sloppy 原始值的 ToObject 装箱（要把包装对象缓存进帧槽以保身份），以及 uninitialized（派生构造器 `super()` 之前）的 ReferenceError。（注：`tailcall_dispatch_colds.zig:881` 的行尾注释把「strict non-object」也算作 stay cold，与此处代码不符。） 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:881`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_undefined_fast` (`src/exec/tailcall_dispatch.zig:3754`)

- **签名**：`pub fn op_undefined_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_undefined：把 `undefined` 压上操作数栈（`-> undefined`），是最窄的一类无帧常量推送 handler。
- **实现**：两条指令：`sp[0] = JSValue.undefinedValue()`，然后 `cont(pc + 1, sp + 1, var_buf, vm)` 尾调用下一条 handler。对应 qjs `CASE(OP_undefined)` 的 `*sp++ = JS_UNDEFINED`。无帧、无守卫：文件头的契约注释说明为什么可以这样——`zjs_vm.reserveEntryFrameCapacity` 在分发前已按校验过的 `function.stack_size` 预留容量（zjs_vm.zig:469-480），而 null / undefined / 布尔 / int32 都是不带引用计数的原始值，所以这里只推进寄存器 `sp`、让 GC 看到的 `stack.len()` 暂时偏旧是安全的；参数初始化链被阻塞的帧走全冷表，因此这些无守卫函数体只会在正常帧上跑。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：压一个 `undefined`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:819`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_null_fast` (`src/exec/tailcall_dispatch.zig:3759`)

- **签名**：`pub fn op_null_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_null：把 `null` 压上操作数栈（`-> null`）。
- **实现**：`sp[0] = JSValue.nullValue()` 后 `cont(pc + 1, sp + 1, var_buf, vm)`。这正是 qjs `CASE(OP_null)` 的 `*sp++ = JS_NULL; BREAK;` 形态。无帧、无守卫：文件头的契约注释说明为什么可以这样——`zjs_vm.reserveEntryFrameCapacity` 在分发前已按校验过的 `function.stack_size` 预留容量（zjs_vm.zig:469-480），而 null / undefined / 布尔 / int32 都是不带引用计数的原始值，所以这里只推进寄存器 `sp`、让 GC 看到的 `stack.len()` 暂时偏旧是安全的；参数初始化链被阻塞的帧走全冷表，因此这些无守卫函数体只会在正常帧上跑。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：压一个 `null`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:820`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_false_fast` (`src/exec/tailcall_dispatch.zig:3764`)

- **签名**：`pub fn op_push_false_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_false：把布尔 `false` 压上操作数栈（`-> false`）。
- **实现**：`sp[0] = JSValue.boolean(false)` 后 `cont(pc + 1, sp + 1, var_buf, vm)`；布尔常量在寄存器里成形，不读任何操作数字节。无帧、无守卫：文件头的契约注释说明为什么可以这样——`zjs_vm.reserveEntryFrameCapacity` 在分发前已按校验过的 `function.stack_size` 预留容量（zjs_vm.zig:469-480），而 null / undefined / 布尔 / int32 都是不带引用计数的原始值，所以这里只推进寄存器 `sp`、让 GC 看到的 `stack.len()` 暂时偏旧是安全的；参数初始化链被阻塞的帧走全冷表，因此这些无守卫函数体只会在正常帧上跑。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：压一个 `false`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:821`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_true_fast` (`src/exec/tailcall_dispatch.zig:3769`)

- **签名**：`pub fn op_push_true_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_true：把布尔 `true` 压上操作数栈（`-> true`）。
- **实现**：`sp[0] = JSValue.boolean(true)` 后 `cont(pc + 1, sp + 1, var_buf, vm)`，与 `op_push_false_fast` 只差常量。无帧、无守卫：文件头的契约注释说明为什么可以这样——`zjs_vm.reserveEntryFrameCapacity` 在分发前已按校验过的 `function.stack_size` 预留容量（zjs_vm.zig:469-480），而 null / undefined / 布尔 / int32 都是不带引用计数的原始值，所以这里只推进寄存器 `sp`、让 GC 看到的 `stack.len()` 暂时偏旧是安全的；参数初始化链被阻塞的帧走全冷表，因此这些无守卫函数体只会在正常帧上跑。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：压一个 `true`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:822`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_i16` (`src/exec/tailcall_dispatch.zig:3774`)

- **签名**：`pub fn op_push_i16(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_i16 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`sp[0] = JSValue.int32(readInt(i16, pc + 1))` 后 `cont(pc + 3, sp + 1, …)`。 栈效应：+1，pc 前进 3 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：2 字节立即数装成 int32 压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:824`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_i8` (`src/exec/tailcall_dispatch.zig:3778`)

- **签名**：`pub fn op_push_i8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_i8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])))`（1 字节立即数按有符号扩展）后 `cont(pc + 2, sp + 1, …)`。 栈效应：+1，pc 前进 2 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：1 字节立即数（按 i8 符号扩展）装成 int32 压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:825`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_small` (`src/exec/tailcall_dispatch.zig:3784`)

- **签名**：`pub fn op_push_small(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_minus1 与 OP_push_0..OP_push_7 共用的 handler：把编码在 opcode 编号里的小整数当作 int32 压栈。
- **实现**：九个 opcode 共用一个 handler：`switch (pc[0])` 把 `op.push_minus1`、`op.push_0`..`op.push_7` 映射成对应的 `i32` 常量（`else => unreachable`），`sp[0] = JSValue.int32(value)`，再 `cont(pc + 1, sp + 1, var_buf, vm)`。立即数编码在 opcode 编号里，所以指令只有 1 字节、不读操作数；旁边的 `op_push_i8`/`op_push_i16` 才走 `readInt` 与 2/3 字节步进。函数以 `align(64)` 落位，是显式的 I-cache 钉（见 `op_return`），使它的入口对齐不随分发单元其它文本的体积变化漂移。无帧、无守卫：文件头的契约注释说明为什么可以这样——`zjs_vm.reserveEntryFrameCapacity` 在分发前已按校验过的 `function.stack_size` 预留容量（zjs_vm.zig:469-480），而 null / undefined / 布尔 / int32 都是不带引用计数的原始值，所以这里只推进寄存器 `sp`、让 GC 看到的 `stack.len()` 暂时偏旧是安全的；参数初始化链被阻塞的帧走全冷表，因此这些无守卫函数体只会在正常帧上跑。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：按 `pc[0]` 在 -1..7 之间 comptime 选常量压栈（九个 opcode 共用这一份，`else => unreachable`）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:828`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_arg` (`src/exec/tailcall_dispatch.zig:3810`)

- **签名**：`pub fn op_get_arg(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_arg 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：从 `vm.frame.args.ptr[idx]` 读出借用副本压栈，不 retain；越界只在 Debug 断言（emit 侧保证）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:868`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 保留宽形态常驻的意义是：第五个及以后的形参否则每次读都要 publish 并穿过 `vm_property_locals.arg`/`execGetArg`。

### `getArgShort` (`src/exec/tailcall_dispatch.zig:3818`)

- **签名**：`inline fn getArgShort(comptime index: usize, pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：OP_get_arg0..3 四个热 handler 共用的内联体：读 `frame.args.ptr[index]` 压栈后 `cont(pc + 1, sp + 1, …)`。
- **实现**：`index` 是 comptime 常量，函数体只有 `sp[0] = vm.frame.args.ptr[index]` 与 `cont(pc + 1, sp + 1, …)` 两步——没有操作数解码，也没有越界检查。`op_get_arg0_fast`..`op_get_arg3_fast` 四个 handler 各自 `return getArgShort(n, …)`，强制内联后每个都是独立的两指令叶子。 栈效应：+1，pc 前进 1 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：无；`index` 由调用方钉死为 0-3。所有权：把 `frame.args.ptr[index]` 复制到栈顶（借用语义，不移动源槽），随即 `cont` 尾调下一条。调用：本文件 `:3834`、`:3838`、`:3842`、`:3846`（`get_arg0`-`get_arg3` 四个 handler）。

### `op_get_arg0_fast` (`src/exec/tailcall_dispatch.zig:3830`)

- **签名**：`pub fn op_get_arg0_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_arg0 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`getArgShort(0, …)` 内联后以 `cont(pc + 1, sp + 1, …)` 尾分发。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：转调 `getArgShort(0, …)`，从 `vm.frame.args.ptr[0]` 读借用副本压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:869`）。四个短形态各有独立 handler，既省掉运行期 opcode 解码，也让每条源 opcode 保留自己的终端间接跳转 PC，分支预测器可以各学各的后继分布。

### `op_get_arg1_fast` (`src/exec/tailcall_dispatch.zig:3834`)

- **签名**：`pub fn op_get_arg1_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_arg1 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`getArgShort(1, …)` 内联后以 `cont(pc + 1, sp + 1, …)` 尾分发。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：转调 `getArgShort(1, …)`，从 `vm.frame.args.ptr[1]` 读借用副本压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:870`）。四个短形态各有独立 handler，既省掉运行期 opcode 解码，也让每条源 opcode 保留自己的终端间接跳转 PC，分支预测器可以各学各的后继分布。

### `op_get_arg2_fast` (`src/exec/tailcall_dispatch.zig:3838`)

- **签名**：`pub fn op_get_arg2_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_arg2 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`getArgShort(2, …)` 内联后以 `cont(pc + 1, sp + 1, …)` 尾分发。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：转调 `getArgShort(2, …)`，从 `vm.frame.args.ptr[2]` 读借用副本压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:871`）。四个短形态各有独立 handler，既省掉运行期 opcode 解码，也让每条源 opcode 保留自己的终端间接跳转 PC，分支预测器可以各学各的后继分布。

### `op_get_arg3_fast` (`src/exec/tailcall_dispatch.zig:3842`)

- **签名**：`pub fn op_get_arg3_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_arg3 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`getArgShort(3, …)` 内联后以 `cont(pc + 1, sp + 1, …)` 尾分发。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：转调 `getArgShort(3, …)`，从 `vm.frame.args.ptr[3]` 读借用副本压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:872`）。四个短形态各有独立 handler，既省掉运行期 opcode 解码，也让每条源 opcode 保留自己的终端间接跳转 PC，分支预测器可以各学各的后继分布。

### `opArgStore` (`src/exec/tailcall_dispatch.zig:3854`)

- **签名**：`pub fn opArgStore(comptime kind: ArgStoreKind) Handler`。
- **作用**：为形参写回的两种所有权契约各产一份 handler（`.put` 写完弹栈、`.set` 写完保留栈顶），每份同时覆盖自己的宽形态与四个短形态，下标在函数内按 `pc[0]` 算。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`cont`。 栈效应：put -1、set 0；宽形态 pc 前进 3 字节，短形态 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂，两个实例（`.put`/`.set`）。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:874`-`:878` 求值，覆盖 `put_arg`/`set_arg` 与 `put_arg0..3`/`set_arg0..3` 共 10 格。

### `opArgStore.h` (`src/exec/tailcall_dispatch.zig:3856`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opArgStore` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`cont`。 栈效应：put -1、set 0；宽形态 pc 前进 3 字节，短形态 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：把 `sp-1` 的值写进 `vm.frame.args.ptr[idx]`；`.put` 弹栈、`.set` 不弹。实参数组与帧同寿，覆盖无需 release，也不过写屏障。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:874-878`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_field_primitive` (`src/exec/tailcall_dispatch.zig:3910`)

- **签名**：`fn op_get_field_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_primitive]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.primitivePrototypeDataPropertyValueForFastPath`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_primitive)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_loc0_field` (`src/exec/tailcall_dispatch.zig:3924`)

- **签名**：`pub fn op_get_loc0_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_loc0_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`sp[0] = var_buf[0]` 后把 `pc+1`/`sp+1` 交给 `op_get_field`，局部值是借用副本。 下一跳**不过表**：`@call(.always_tail, `op_get_field`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:950`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc0_field_cold` (`src/exec/tailcall_dispatch.zig:3931`)

- **签名**：`pub fn op_get_loc0_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_loc0_field 的冷臂 handler（全冷表 / L0 stop 用：只做 get_loc0，再 `coldNext` 落到后面的 get_field）：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:799` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc0_field` 覆盖（:950）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 它只做 `get_loc0` 一半——随后 `coldNext` 落到仍在流里的 `get_field`，这样两条 opcode 之间的 `stop_before_pc` 停机点得以保留（这正是融合快臂不能用在停机 seam 上的原因）。

### `op_get_loc2_field` (`src/exec/tailcall_dispatch.zig:3938`)

- **签名**：`pub fn op_get_loc2_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_loc2_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：同 `op_get_loc0_field`，读的是 loc2。 下一跳**不过表**：`@call(.always_tail, `op_get_field`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:951`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc2_field_cold` (`src/exec/tailcall_dispatch.zig:3943`)

- **签名**：`pub fn op_get_loc2_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_loc2_field 的冷臂 handler（同 get_loc0_field 契约）：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:800` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc2_field` 覆盖（:951）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 同样只做 `get_loc2` 一半，再 `coldNext` 到残留的 `get_field`。

### `op_get_field2_call_method` (`src/exec/tailcall_dispatch.zig:3952`)

- **签名**：`pub fn op_get_field2_call_method(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_field2_call_method 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.siteCapturable`、`vm_property_field.getFieldFastSlotOrAbsent`。 栈效应：-(argc+2)+1（receiver+callable+args）。 下一跳：未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。非对象 receiver 转 `propertyTailHandler(vm, .get_field2_primitive)`；W1 站点主/次 guard 都未命中且 `siteCapturable` 成立时转 `.prop_site_capture`，`proto_key != 0` 转 `.prop_site_indirect`；最后 `getFieldFastSlotOrAbsent` 也不成立才落 `cold_table[pc[0]]`。命中（站点槽、次槽、fast-slot 或 absent 写 undefined）后**直接 PC-relative 尾跳 `op_call_method`**（共用它的 empty-leaf / exact-args / simple_inline / nativeMethodFastDispatch 整条链），残留的 B 仍是 `call_method`。 所有权：receiver 留在 `sp-1` 上作为方法调用区的第一个槽，方法值压在它之上。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:955`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_field2_call_method_cold` (`src/exec/tailcall_dispatch.zig:3993`)

- **签名**：`pub fn op_get_field2_call_method_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_field2_call_method 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_field.field`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_field.field`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:804` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_field2_call_method` 覆盖（:955）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 只做 `get_field2` 一半，`coldNext` 到残留的 `call_method`。

### `op_get_field_property_tail` (`src/exec/tailcall_dispatch.zig:3999`)

- **签名**：`fn op_get_field_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_property]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.atomPropertyValueForFastPath`、`builtin_dispatch.nativeAccessorTarget`、`builtin_dispatch.callNativeAccessorTarget`、`call_runtime.handleCatchableRuntimeError`、`coldNext`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_property)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field_after_own_miss_tail` (`src/exec/tailcall_dispatch.zig:4045`)

- **签名**：`fn op_get_field_after_own_miss_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_after_own_miss]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.getFieldFastSlotOrAbsentAfterOwnMiss`、`vm_property_field.ordinaryAccessorGetterAfterOwnMiss`、`builtin_dispatch.nativeAccessorTarget`、`builtin_dispatch.callNativeAccessorTarget`、`call_runtime.handleCatchableRuntimeError`、`vm_property_field.isTypedArrayPayloadAtomForFastPath`、`vm_property_field.typedArrayReceiverForFastPath`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；属性尾：`property_tail_tbl[slot]`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_after_own_miss)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field_absent_tail` (`src/exec/tailcall_dispatch.zig:4095`)

- **签名**：`fn op_get_field_absent_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_absent]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：两条：`(sp - 1)[0] = JSValue.undefinedValue()`（就地覆盖 receiver）、`cont(pc + 6, sp, …)`。之所以值得一条独立的属性尾：内联 shape walk 已经把整条原型链走完且每一环都是「确定不存在」权威，结论就是 `undefined`（qjs GET_FIELD_INLINE）；以前这一格落到外联解析器，会从 receiver 起把同一条链再走一遍、每一层重跑 proxy/exotic/array/class 资格判定。 栈效应：0（覆盖，不增减），pc 前进 6 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_absent)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field_native_getter_tail` (`src/exec/tailcall_dispatch.zig:4109`)

- **签名**：`fn op_get_field_native_getter_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_native_getter]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`builtin_dispatch.nativeAccessorTarget`、`builtin_dispatch.invokeTypedGetterFast`、`vm_native.getterInlineEligible`、`builtin_dispatch.callGetterFromWindow`、`builtin_dispatch.nativeHostError`、`call_runtime.handleCatchableRuntimeError`、`builtin_dispatch.callNativeAccessorTarget`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_native_getter)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_prop_site_indirect_tail` (`src/exec/tailcall_dispatch.zig:4169`)

- **签名**：`fn op_prop_site_indirect_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.prop_site_indirect]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.site_proto`、`vm_property_field.captureFieldSite`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .prop_site_indirect)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_prop_site_capture_tail` (`src/exec/tailcall_dispatch.zig:4222`)

- **签名**：`fn op_prop_site_capture_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.prop_site_capture]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.capturePutSite`、`vm_property_field.captureFieldSite`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .prop_site_capture)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field_typed_property_tail` (`src/exec/tailcall_dispatch.zig:4244`)

- **签名**：`fn op_get_field_typed_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_typed_property]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.typedArrayPropertyValueForFastPath`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_typed_property)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field` (`src/exec/tailcall_dispatch.zig:4269`)

- **签名**：`pub fn op_get_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.siteCapturable`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误——IC 命中直接 `cont`，未命中一律 `@call(.always_tail, propertyTailHandler(vm, .xxx))` 交给 17 张属性尾之一（`get_field_property`/`get_field_absent`/`get_field_cached_getter`/`get_field_native_getter`/`get_field_typed_property`/`prop_site_*` 等），真正的抛出与 publish 都在那些尾里。 所有权：站点 `vm.propSite(pc[5])` 是借用指针（数组归 `FunctionBytecode` 的 hot extension）；读到的属性值覆盖 `sp-1` 的 receiver，receiver 被消费。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:949`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_field2_primitive` (`src/exec/tailcall_dispatch.zig:4347`)

- **签名**：`fn op_get_field2_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field2_primitive]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.primitivePrototypeDataPropertyValueForFastPath`、`string_ops.getFastStringPrimitiveDataProperty`、`syncSp`、`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field2_primitive)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field2` (`src/exec/tailcall_dispatch.zig:4374`)

- **签名**：`pub fn op_get_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_field2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.siteCapturable`、`vm_property_field.getFieldFastSlotOrAbsent`、`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：保留 receiver 的取字段形态（`obj.m()` 的 `[receiver, method]` 布局），原始字符串等原始值的方法解析也在这里；其余落冷壳 `h_field`。属性尾同 `op_get_field`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:957`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_array_el_ta` (`src/exec/tailcall_dispatch.zig:4456`)

- **签名**：`pub fn op_put_array_el_ta(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_put_array_el 的 typed-array 臂（不是独立 opcode；经导出槽 `zjs_op_put_array_el_ta` 尾跳进入）：在寄存器 `pc/sp/var_buf` 上完成写入并尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`cont`。 栈效应：寄存器 `sp` 净效应 sp-3，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_put_array_el` 经导出槽 `zjs_op_put_array_el_ta` 尾跳进入。

### `op_put_array_el` (`src/exec/tailcall_dispatch.zig:4494`)

- **签名**：`pub fn op_put_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_array_el 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValue`、`object_ops.objectFromValueTrustedExpression`、`cont`。 栈效应：寄存器 `sp` 净效应 sp-3，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；dense 写未命中转 `propertyTailHandler(vm, .put_array_el_rest)`，更外层形态由那一份负责。 所有权：**有写屏障**——值移进数组元素槽后走 `gc.generationalBarrier`（老年代数组指向新生代值的跨代边）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:970`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_array_el_cold` (`src/exec/tailcall_dispatch.zig:4567`)

- **签名**：`fn op_put_array_el_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.put_array_el_rest]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValue`、`array_ops.putDenseArrayElementOverwriteOwnedFast`、`array_ops.putDenseArrayElementAppendOwnedFast`、`vm_property_field.fastArrayOwnIntElementSet`、`vm_property_field.putTypedArrayElementFast`、`cont`。 栈效应：寄存器 `sp` 净效应 sp-3，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .put_array_el_rest)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_put_field` (`src/exec/tailcall_dispatch.zig:4660`)

- **签名**：`pub fn op_put_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.siteCapturable`、`vm_property_field.putFieldFastSlot`、`cont`。 栈效应：寄存器 `sp` 净效应 -2，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误，也**不直接走 `cold_table`**——站点未命中且 `siteCapturable` 时转 `propertyTailHandler(vm, .prop_site_capture)`，其余一律以 `propertyTailHandler(vm, .put_field_add)` 收尾，由那一份在 `.slow` 时再回落冷壳（它的 `.slow` 契约是「一点状态都没改」，所以冷壳的 `publish(pc, sp)` 能原样重新覆盖两个操作数）。 所有权：两条直写臂（站点命中的 `propertyEntry(site.slot).slot.data`、`putFieldFastSlot` 返回的槽）都**绕开了 `setOrDefineOwnDataProperty*` 漏斗**，所以各自带一次 `rt.gc.generationalBarrierValue(owner.gcHeader(), (sp-1)[0])`：`node.left = child` 是典型的老指新边，minor 的 sticky 标记会在 owner 处停下——少了它每个大对象图基准都挂。写入消费掉栈上那份引用，随后弹掉两个槽。写臂比读臂**多一个 class 检查**：Shape 不钉 class（空根 shape 按 proto 共享），而常驻的 `putFieldFastSlot` 拒绝 mapped `arguments`（它的具名写必须落到绑定上）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:958`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_field_add_tail` (`src/exec/tailcall_dispatch.zig:4734`)

- **签名**：`fn op_put_field_add_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.put_field_add]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：Debug 下先断言 `pc[0] == op.put_field`。取 `(sp-2)` 的 receiver，非对象直接落 `cold_table[pc[0]]`；否则从活 pc 解出 atom、取 `(sp-1)` 的值，**先 `syncSp(sp - 2)`** 把活栈边界收到两个操作数之下（C_W_E 追加可能触发 GC，不能让它再扫这两槽），再调 `receiver.setOrDefineOwnDataPropertyForPutFieldOwned(rt, atom_id, value)`：`.done` 表示 helper 已消费 value，`cont(pc + 6, sp - 2, …)`；`.slow` 表示**一点状态都没改**、两个操作数的所有权仍在栈上，尾跳 `cold_table[pc[0]]` 由冷壳的 `publish(pc, sp)` 原样重新覆盖（追加/auto_init 的 OOM 也走 `.slow`）。 栈效应：寄存器 `sp` 净效应 -2，pc 前进 6 字节。 下一跳：热成功：`cont` → `dispatch_table[npc[0]]`；`.slow`：`@call(.always_tail, cold_table[pc[0]], …)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .put_field_add)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_array_el_atom_key` (`src/exec/tailcall_dispatch.zig:4753`)

- **签名**：`fn op_get_array_el_atom_key(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_array_el_atom_key]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.existingPropertyKeyValueForFastPath`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_array_el_atom_key)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_property_cached_getter` (`src/exec/tailcall_dispatch.zig:4779`)

- **签名**：`inline fn op_get_property_cached_getter(comptime pc_advance: usize, pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：两个缓存 getter 属性尾槽共用的内联体（comptime `pc_advance`：`get_array_el` 形态 1 字节、字段形态 6 字节）——本身不是 Handler，由 `op_get_array_el_atom_key_getter` / `op_get_field_cached_getter` 调用。
- **实现**：`syncPc(pc, pc_advance)`（`pc_advance` 是 comptime 参数：字段族 6、`get_length` 1）；用 `operand_len` 从已发布的 `stack.values` 取出 `[receiver, getter]` 两个槽（不用寄存器 `sp`，因为下面要建帧）；`inline_calls.resolveInlineTarget` 命中字节码 getter 就 `retreatToCallRegionFrom` 把这两个槽当成零参 `.method` 调用区，交 `pushAndEnter`——accessor 与普通方法调用在 qjs 里本来就是同一条 `JS_CallInternal`，这里同样留在本 Machine 内；`frame.pc` 已经指向属性读之后的那条指令，所以正常返回/抛出都从正确位置续跑。未命中则 `setTopPtr(sp)` 后先试 K3 原生 getter 终端 `builtin_dispatch.tryNativeAccessorCall`（一次原生调用，不过通用调用机器）；它也不接（非原生 accessor）才落权威的 `call_runtime.callValueOrBytecodeRootPreRooted`。这三条路的失败处理相同：`setLen(operand_len - 2)` 收回 `[receiver, getter]` 窗口后 `handleCatchableRuntimeError`，接住 `coldNext`、接不住 `vm.fail`；成功都把值写回 `values[operand_len - 2]`、`setLen(operand_len - 1)` 后 `coldNext`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_get_array_el_atom_key_getter`（pc_advance=1）与 `op_get_field_cached_getter`（pc_advance=6）。

### `op_get_array_el_atom_key_getter` (`src/exec/tailcall_dispatch.zig:4830`)

- **签名**：`fn op_get_array_el_atom_key_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_array_el_atom_key_getter]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：整体就是 `return op_get_property_cached_getter(1, pc, sp, var_buf, vm)`（`get_array_el` 形态的 1 字节 pc 前进）；续跑由那个内联体决定。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_array_el_atom_key_getter)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_field_cached_getter` (`src/exec/tailcall_dispatch.zig:4834`)

- **签名**：`fn op_get_field_cached_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_field_cached_getter]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：整体就是 `return op_get_property_cached_getter(6, pc, sp, var_buf, vm)`（字段形态的 6 字节 pc 前进）；续跑由那个内联体决定。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_field_cached_getter)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_static_cached_proxy` (`src/exec/tailcall_dispatch.zig:4838`)

- **签名**：`fn op_get_static_cached_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_static_cached_proxy]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：`pc_advance` 按 `pc[0] == op.get_length` 在 1 与 6 之间选（W1：字段族是 `atom_cache_u8` 6 字节，`get_length` 1 字节），`syncPc` 后 `setTopPtr(sp)`；先试 `tryInlineProxyTrap`——只接受 handler 上普通数据属性的 `get` 陷阱，命中就把 `[receiver]`/`[receiver,key]` 窗口改写成 `[target,key]` 并在本 Machine 内建帧，不递归起第二个 VM；否则调 `object_ops.getProxyProperty` 走权威查找。抛错时先 `setLen(operand_len - 1)` 收回窗口，再 `handleCatchableRuntimeError`：接住 `coldNext`，接不住 `vm.fail(err)`。成功把值写回 `stack.values[operand_len - 1]` 后 `coldNext`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_static_cached_proxy)` 间接尾调用进入（不在 256 槽分发表里）。

### `tryInlineProxyTrap` (`src/exec/tailcall_dispatch.zig:4873`)

- **签名**：`inline fn tryInlineProxyTrap(comptime computed_key: bool, var_buf: [*]JSValue, vm: *Vm, proxy: *core.Object, atom_id: core.Atom) ?Outcome`。
- **作用**：在不递归起第二个 VM 的前提下进入普通字节码 Proxy `get` 陷阱——只接受 `handler.get` 是普通数据属性这一种形状，其余（accessor / Proxy / exotic 的陷阱查找）留给 `getProxyProperty`，以免那份可观测查找被重复执行。返回 null 表示什么都没做。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`inline_calls.resolveInlineTarget`、`object_ops.proxyTrapKeyValue`、`call_runtime.handleCatchableRuntimeError`、`coldNext`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error；返回 null 表示「什么都没做，走通用属性路径」。所有权：trap 缺省时把目标属性值就地写回 `region_base` 槽并 `setLen` 收区；命中 trap 时把 `{handler, trap, target, key, receiver}` 五个值组成 moved 数组（`[handler, trap]` 是调用绑定，`[target, key, receiver]` 是陷阱的三个实参）交给 `pushMovedAndEnter(…, .proxy_get, atom_id, false)`；同时把调用方窗口的 `region_base` 槽改写成 `target`，非计算键时再补压一个 `key`，好让陷阱返回后的续延看到 `[target, key]`。调用：本文件 `:4848`（静态键）与 `:4926`（计算键）。

### `op_get_array_el_atom_key_proxy` (`src/exec/tailcall_dispatch.zig:4917`)

- **签名**：`fn op_get_array_el_atom_key_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_array_el_atom_key_proxy]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_field.existingPropertyKeyAtomForFastPath`、`object_ops.getProxyProperty`、`call_runtime.handleCatchableRuntimeError`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_array_el_atom_key_proxy)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_get_array_el_ta` (`src/exec/tailcall_dispatch.zig:4959`)

- **签名**：`pub fn op_get_array_el_ta(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_array_el 的 typed-array 臂（不是独立 opcode；经导出槽 `zjs_op_get_array_el_ta` 尾跳进入）：在寄存器 `pc/sp/var_buf` 上完成读取并尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_get_array_el` 经导出槽 `zjs_op_get_array_el_ta` 尾跳进入。

### `op_get_array_el` (`src/exec/tailcall_dispatch.zig:4990`)

- **签名**：`pub fn op_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_array_el 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.fastDenseArrayElementValue`、`vm_property_field.fastArrayOwnIntElementValue`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。dense 整数下标命中就地读；atom key 形态转 `.get_array_el_atom_key` / `…_getter` / `…_proxy` 三张属性尾；其余 `cold_table[pc[0]]` 落 `h_get_array_element`。 所有权：元素值是借用副本，覆盖 `sp-2` 并弹掉 key。转属性尾前会把 holder 写进 `vm.property_holder` 作为跨 handler 的传参。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:959`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_array_el2` (`src/exec/tailcall_dispatch.zig:5062`)

- **签名**：`pub fn op_get_array_el2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_array_el2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.fastDenseArrayElementValue`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：保留 receiver 的孪生形态——dense 命中时结果**替换 key**（`[obj, key] → [obj, value]`），receiver 留在 `sp-2` 上，好让 `obj[i](...)` 直接接 `call_method`，栈效应 0。key 必然是 TAG_INT（`fastDenseArrayElementValue` 要求 `asInt32`），不需要 free。own-int / typed / atom-key 三类都留在冷壳 `h_get_array_element`：那些 helper 是非叶（`bl`），内联进来会让 dense 命中背上共享前言。qjs 的 CASE 同样只内联 ARRAY+INT+在界这一条臂。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:969`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_length` (`src/exec/tailcall_dispatch.zig:5083`)

- **签名**：`pub fn op_get_length(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_length 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.fastArrayLengthValue`、`object_ops.objectFromValueTrustedExpression`、`vm_property_field.getLengthFieldFast`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；accessor / Proxy / typed-array payload 三类载荷转 `propertyTailHandler(vm, .get_length_property)` 等驻留动作尾。 所有权：内联数据读，长度值就地覆盖 `sp-1`。注意它是 1 字节 opcode（没有 `atom_cache_u8` 的 6 字节形态），`op_get_static_cached_proxy` 因此要按 `pc[0] == op.get_length` 决定 `pc_advance`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:971`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_length_property_tail` (`src/exec/tailcall_dispatch.zig:5132`)

- **签名**：`fn op_get_length_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：属性尾表槽 `property_tail_tbl[.get_length_property]` 的 handler（不是独立 opcode）：属性快路径守卫未命中后由 `propertyTailHandler` 间接尾调用进入，在寄存器 `pc/sp/var_buf` 上完成这一臂并尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_property_field.getLengthActionForFastPath`、`vm_property_field.atomPropertyValueForFastPath`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；属性尾：`property_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由属性快路径经 `propertyTailHandler(vm, .get_length_property)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_object` (`src/exec/tailcall_dispatch.zig:5170`)

- **签名**：`pub fn op_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_literal.newPlainObjectValue`、`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误——`newPlainObjectValue` 失败（OOM）时 `catch` 直接 `cold_table[pc[0]]` 交给冷壳 `h_object` 重跑，不走 `vm.fail`。 所有权：**会分配**，所以先 `syncSp(sp)` 把已求值的操作数纳入根窗口；新对象移交 `sp[0]`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:978`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_object_slots2` (`src/exec/tailcall_dispatch.zig:5182`)

- **签名**：`pub fn op_object_slots2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_object_slots2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_literal.newPlainObjectReserved2Value`、`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：同 `op_object`，OOM 落 `cold_table[pc[0]]`。 所有权：**会分配**，先 `syncSp`；解析器已证明最终 Shape 只有一两个唯一静态命名属性，所以直接预留两槽的尾随属性区（computed/spread 或更大的字面量不会走到这条 opcode）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:979`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_define_field` (`src/exec/tailcall_dispatch.zig:5203`)

- **签名**：`pub fn op_define_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_define_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`vm_literal.defineFieldFast`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 5 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；`defineFieldFast` 返回 false 时**值没有被消费**（borrow-until-commit 契约），冷壳重跑时栈上的所有权是完整的。 所有权：命中臂把值 move 进属性槽后弹栈（对象作为字面量的 running receiver 留在栈上）；先 `syncSp` 是因为 define 可能分配。数组、私有 atom、Proxy、不可扩展对象、setter（一切能捕获 backtrace 或跑用户代码的情形）全落冷壳。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:980`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_array_from` (`src/exec/tailcall_dispatch.zig:5227`)

- **签名**：`pub fn op_array_from(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_array_from 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：把 n 个栈值收成数组（净 -n+1）。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；realm 尚未装好 `ctx.array_shape`、或 `constructLiteralOwnedDenseFromShape` OOM，都 `cold_table[pc[0]]` 交冷壳（值原封不动留在栈上）。 所有权：**会分配**且元素是 **move** 语义——`(sp-argc)[0..argc]` 整段搬进 dense 存储（无 dup、无补偿 free，与 qjs 的 `u.array.u.values[i] = tab[i]` 一致），数组替换整个窗口，净栈效应 `-argc+1`。分配前 `syncSp(sp)` 让已求值元素留在根集。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:981`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `opCompare` (`src/exec/tailcall_dispatch.zig:5263`)

- **签名**：`pub fn opCompare(comptime opc: u8) Handler`。
- **作用**：为 lt/lte/gt/gte/eq/neq/strict_eq/strict_neq 八个比较 opcode 各产一份 handler（qjs 每个 CASE 独立、int 快腿上没有运行期谓词选择）：双 int32 命中就 cmp+cset 写 `sp[-2]`，关系类未命中在 handler 内再试 float64/int，等值类则尾跳 `zjs_cmp_*_mixed`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂，八个实例。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:901` 对 lt/lte/gt/gte/eq/neq/strict_eq/strict_neq 各求值一次装进 `dispatch_table`。

### `opCompare.h` (`src/exec/tailcall_dispatch.zig:5266`)

- **签名**：`fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opCompare` 展开出的实际 Handler 体，挂进 256 槽分发表。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 双整数未命中时先在 handler 内做 float64/int 转换（qjs OP_CMP 的同款），仍不成才 `cold_table[pc[0]]`。所有权：结果是布尔裸值，就地写 `sp[-2]` 并弹 rhs。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:901`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 `opc` 是 comptime 常量，所以谓词 `switch` 全部折掉，编译出的就是 qjs 的「一次 `asInt32Pair` 折 tag + 一次 cmp + 一次 cset」。

### `opCompareEq` (`src/exec/tailcall_dispatch.zig:5330`)

- **签名**：`fn opCompareEq(comptime opc: u8) Handler`。
- **作用**：eq 家族「需要真帧」的那一半（会触发 release/`bl` 阶梯的形态）的 handler 工厂，落在 handler-tail 区段，由 `opCompareEqFast` 的 last-ref 臂经导出符号跳入。
- **实现**：comptime 参数只有 `opc`：`strict = (opc == strict_eq or strict_neq)`、`inv = (opc == neq or strict_neq)` 都在 comptime 折掉，谓词不在运行期选。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`value_ops.isHTMLDDA`、`cont`（`value_ops.valuesEqual` 只在注释里作语义对照）。 栈效应：-1（两个操作数 → 一个布尔写进 `sp[-2]`），同时 `setTopPtr(sp-1)`，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂（函数本身**没有** `noinline` 标注——源码注释里说的「noinline sibling」靠的是导出符号：同文件可内联的 `always_tail` 会把 release/`bl` 阶梯折回 int 叶子、把叶子的帧重新撑到 0x70，而 `export fn` 边界折不动）。调用：**产出的 handler 不进任何表**——只由 `compareEqFramedExport` 映成的四个导出符号 `zjs_cmp_*_framed`（`:5540` 起）取到，跳入点是 `opCompareEqFast` 的两条 last-ref 臂（`:5447`/`:5450`），而不是 int 叶子本身。

### `hnd` (`src/exec/tailcall_dispatch.zig:5332`)

- **签名**：`fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：`opCompareEq` 展开出的实际 Handler 体：不进分发表，经导出符号 `zjs_cmp_*_framed` 尾跳进入。
- **实现**：comptime 参数只有 `opc`：`strict = (opc == strict_eq or strict_neq)`、`inv = (opc == neq or strict_neq)` 都在 comptime 折掉，谓词不在运行期选。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`value_ops.isHTMLDDA`、`cont`（`value_ops.valuesEqual` 只在注释里作语义对照）。 栈效应：-1（两个操作数 → 一个布尔写进 `sp[-2]`），同时 `setTopPtr(sp-1)`，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不写 `pending_error`；剩余形态走 `cold_table[pc[0]]`。所有权：eq 家族的九条臂在寄存器上完成，结果写 `sp[-2]`。调用：**不在任何表里**，经 `compareEqFramedExport` 的四个导出符号 `zjs_cmp_*_framed`（本体在 `:5540` 起）进入，跳入点是 `opCompareEqFast` 的两条 last-ref 臂（`:5447`/`:5450`）。

### `opCompareEqFast` (`src/exec/tailcall_dispatch.zig:5427`)

- **签名**：`fn opCompareEqFast(comptime opc: u8) Handler`。
- **作用**：eq 家族混合类型形态的 handler 工厂（字符串×字符串等不必建帧的臂在这里就地算完 `cont`）：由 int 叶经 `zjs_cmp_*_mixed` 跳入，需要 release 阶梯的 last-ref 形态再转 `zjs_cmp_*_framed`，都不成才 `cold_table[pc[0]]`。
- **实现**：comptime 参数只有 `opc`：`strict = (opc == strict_eq or strict_neq)`、`inv = (opc == neq or strict_neq)` 都在 comptime 折掉，谓词不在运行期选。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：-1（两个操作数 → 一个布尔写进 `sp[-2]`），同时 `setTopPtr(sp-1)`，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：工厂无 error set。所有权：comptime 工厂。调用：**产出的 handler 不进任何表**——经 `compareEqExport` 映成的四个导出符号 `zjs_cmp_*_mixed`（`:5527` 起）转跳进来；`op_eq_if_false8` 的剩余臂也直接跳 `zjs_cmp_eq_mixed`（`:6420`），所以这一族 handler 绝不能去 `switch (pc[0])`（那个 opcode 不是 `op.eq`）。

### `hnd` (`src/exec/tailcall_dispatch.zig:5429`)

- **签名**：`fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：`opCompareEqFast` 展开出的实际 Handler 体：不进分发表，经导出符号 `zjs_cmp_*_mixed` 尾跳进入。
- **实现**：comptime 参数只有 `opc`：`strict = (opc == strict_eq or strict_neq)`、`inv = (opc == neq or strict_neq)` 都在 comptime 折掉，谓词不在运行期选。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：-1（两个操作数 → 一个布尔写进 `sp[-2]`），同时 `setTopPtr(sp-1)`，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不写 `pending_error`；未覆盖形态 `cold_table[pc[0]]`。所有权：结果写 `sp[-2]` 后弹 rhs。调用：**不在任何表里**，经 `zjs_cmp_eq_mixed`/`zjs_cmp_neq_mixed`/`zjs_cmp_strict_eq_mixed`/`zjs_cmp_strict_neq_mixed` 四个导出符号进入（`:5527` 起），调用方是 `opCompare` 的 int 叶与 `op_eq_if_false8` 的剩余臂。

### `compareEqExport` (`src/exec/tailcall_dispatch.zig:5505`)

- **签名**：`fn compareEqExport(comptime opc: u8) Handler`。
- **作用**：把 comptime opcode 映射到对应的 `zjs_cmp_*_mixed` 导出符号，好让 int 叶用 PC-relative `b` 尾跳而不去 load 驻留表。
- **实现**：comptime `switch (opc)`，把 `op.eq`/`op.neq`/`op.strict_eq`/`op.strict_neq` 映成 `&zjs_cmp_eq_mixed` 等四个 `export fn` 的地址，其余 opcode 是 `unreachable`。运行期不存在这个函数：它在 comptime 求值成一个符号地址，调用点因而能发 PC-relative `b` 而不是先 load 驻留表。四个 export 本体（`:5527` 起）各自 `@call(.always_tail, opCompareEqFast(opc), …)`，所以它们**不看** `pc[0]`——`eq_if_false8` 的剩余臂直接跳 `zjs_cmp_eq_mixed` 时正需要这一点。
- **所有权 / 错误 / 调用**：错误：无；非四个比较 opcode 之一是 `unreachable`。所有权：只返回 `.rodata` 里四个导出 handler（`zjs_cmp_*_mixed`）之一的函数指针。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:5291`（混合类型比较的尾跳）。

### `compareEqFramedExport` (`src/exec/tailcall_dispatch.zig:5515`)

- **签名**：`fn compareEqFramedExport(comptime opc: u8) Handler`。
- **作用**：`compareEqExport` 的带帧孪生：映射到 `zjs_cmp_*_framed` 四个导出符号。
- **实现**：与 `compareEqExport` 同构的 comptime `switch`，目标换成 `zjs_cmp_eq_framed` 等四个带帧导出符号（比较慢臂需要真帧时用）。
- **所有权 / 错误 / 调用**：错误：无；同样 `unreachable` 兜底。所有权：返回四个 framed 版导出 handler 之一的指针。调用：本文件 `:5447`、`:5450`（需要建帧的比较慢臂）。

### `zjs_cmp_eq_mixed` (`src/exec/tailcall_dispatch.zig:5525`)

- **签名**：`export fn zjs_cmp_eq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：ELF 可见的混合类型 `==` 入口，让 int 叶能 PC-relative `always_tail` `b`（硬门 #9）而不 load `resident_tail_tbl`。`eq_if_false8` 残留直接跳这里，不得再 switch `pc[0]`。
- **实现**：`@call(.always_tail, opCompareEqFast(op.eq), ...)`。`export`+`callconv(.c)` 与 Handler 相同；`noinline` 会破坏 `always_tail`。
- **所有权 / 错误 / 调用**：错误由 `opCompareEqFast` 写成 `.threw`。调用：`compareEqExport(op.eq)`、`op_eq_if_false8` 残留。

### `zjs_cmp_neq_mixed` (`src/exec/tailcall_dispatch.zig:5528`)

- **签名**：`export fn zjs_cmp_neq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：混合类型 `!=` 的 ELF 可见尾跳入口。
- **实现**：`always_tail` 进 `opCompareEqFast(op.neq)`。
- **所有权 / 错误 / 调用**：同 `zjs_cmp_eq_mixed`。调用：`compareEqExport(op.neq)`。

### `zjs_cmp_strict_eq_mixed` (`src/exec/tailcall_dispatch.zig:5531`)

- **签名**：`export fn zjs_cmp_strict_eq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：混合类型 `===` 的 ELF 可见尾跳入口。
- **实现**：`always_tail` 进 `opCompareEqFast(op.strict_eq)`。
- **所有权 / 错误 / 调用**：同 `zjs_cmp_eq_mixed`。调用：`compareEqExport(op.strict_eq)`。

### `zjs_cmp_strict_neq_mixed` (`src/exec/tailcall_dispatch.zig:5534`)

- **签名**：`export fn zjs_cmp_strict_neq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：混合类型 `!==` 的 ELF 可见尾跳入口。
- **实现**：`always_tail` 进 `opCompareEqFast(op.strict_neq)`。
- **所有权 / 错误 / 调用**：同 `zjs_cmp_eq_mixed`。调用：`compareEqExport(op.strict_neq)`。

### `zjs_cmp_eq_framed` (`src/exec/tailcall_dispatch.zig:5538`)

- **签名**：`export fn zjs_cmp_eq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：带帧/慢路径的 `==` 导出入口（非 Fast 守卫叶）。
- **实现**：`always_tail` 进 `opCompareEq(op.eq)`。
- **所有权 / 错误 / 调用**：同 mixed 族。调用：`compareEqFramedExport(op.eq)`。

### `zjs_cmp_neq_framed` (`src/exec/tailcall_dispatch.zig:5541`)

- **签名**：`export fn zjs_cmp_neq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：带帧/慢路径的 `!=` 导出入口。
- **实现**：`always_tail` 进 `opCompareEq(op.neq)`。
- **所有权 / 错误 / 调用**：同 mixed 族。调用：`compareEqFramedExport(op.neq)`。

### `zjs_cmp_strict_eq_framed` (`src/exec/tailcall_dispatch.zig:5544`)

- **签名**：`export fn zjs_cmp_strict_eq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：带帧/慢路径的 `===` 导出入口。
- **实现**：`always_tail` 进 `opCompareEq(op.strict_eq)`。
- **所有权 / 错误 / 调用**：同 mixed 族。调用：`compareEqFramedExport(op.strict_eq)`。

### `zjs_cmp_strict_neq_framed` (`src/exec/tailcall_dispatch.zig:5547`)

- **签名**：`export fn zjs_cmp_strict_neq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome`。
- **作用**：带帧/慢路径的 `!==` 导出入口。
- **实现**：`always_tail` 进 `opCompareEq(op.strict_neq)`。
- **所有权 / 错误 / 调用**：同 mixed 族。调用：`compareEqFramedExport(op.strict_neq)`。

### `op_mod_cold` (`src/exec/tailcall_dispatch.zig:5556`)

- **签名**：`pub fn op_mod_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_mod 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先是一条**不发布**的寄存器内快腿：`local_fast_blocked` 为假、且两个操作数 `value_ops.numberValue` 都成立时，直接 `(sp-2)[0] = JSValue.float64(@rem(lhs, rhs))` 后 `cont(pc + 1, sp - 1, …)`（对齐 qjs `js_binary_arith_slow` 先试 both-number 调 fmod、早于 ToNumeric/BigInt 分类的次序）。只有这条腿不成立（或处在 L0 停机 seam）才 `publish(pc, sp)` 并落 `vm_arith.binaryVm`，再 `coldNext`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` → `dispatch_table[npc[0]]`；冷续跑：`coldNext`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：qjs `js_binary_arith_slow` 的 mod 慢臂；操作数可能跑用户 `valueOf`，所以先 publish。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:294` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `opBinary(.mod)` 覆盖（:890）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_div_cold` (`src/exec/tailcall_dispatch.zig:5579`)

- **签名**：`pub fn op_div_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_div 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：与 `op_mod_cold` 同样的两段式：`local_fast_blocked` 为假且两个操作数都能 `numberValue` 时，就地 `(sp-2)[0] = JSValue.float64(lhs / rhs)` 后 `cont(pc + 1, sp - 1, …)`——裸 float64、不做 int 规范化（规范化只在 both-int 腿上，而那条已被 `opBinary` 截走，所以冷路径至少有一个 float 操作数）；否则 `publish(pc, sp)` + `vm_arith.binaryVm` + `coldNext`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont`；冷续跑：`coldNext`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：qjs 的 div 慢臂，带零/符号/-0 特例与规范化商；这也是 div/mod 被排除在 `opBinaryFloat` 之外的原因。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:293` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `opBinary(.div)` 覆盖（:889）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `logicOperandInt32` (`src/exec/tailcall_dispatch.zig:5603`)

- **签名**：`inline fn logicOperandInt32(v: JSValue) ?i32`。
- **作用**：位运算/移位冷臂的操作数归一：int32 原样、bool 转 0/1、float64 走 `toUint32Number` 再按位重解释，其余（BigInt/字符串/对象/symbol）返回 null 交给发布式冷壳。
- **实现**：三个纯测试按 qjs `JS_ToNumericFree` 的「全函数、无副作用」tag 顺序排：`asInt32` 直接返回；`asBool` 返回 `@intFromBool`；`asFloat64` 走 `coercion_ops.toUint32Number(d)` 再 `@bitCast` 成 i32（与 `value_ops.toInt32` 收尾用的是同一套模 2³² 回绕，所以快臂结果与冷壳逐位相同）。其余 tag 一律 null：字符串要解析、对象要跑用户 `valueOf`/`toString`、symbol 必须抛、BigInt 走 bigint 臂（或 `>>>` 的 TypeError）。
- **所有权 / 错误 / 调用**：错误：无；不是 int32/bool/float64 返回 null，调用方退回通用逻辑运算。所有权：纯取值转换，float 走 `toUint32Number` 再 `@bitCast`。调用：本文件 `:5640`、`:5641`（位运算取两个操作数）。

### `opLogicCold` (`src/exec/tailcall_dispatch.zig:5636`)

- **签名**：`pub fn opLogicCold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：shl/sar/shr/and/or/xor 六条位运算/移位共用的**冷表** handler：int/bool/float64 三个 tag 在寄存器上直接算完并 `cont`（qjs `js_binary_logic_slow`/`js_shr_slow` 的就地语义），其余 tag 才 publish 并落 `vm_arith.binaryVm`。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.binaryVm`、`cont`、`publish`、`coldNext`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：六条位运算/移位的共用冷臂，按 qjs `js_binary_logic_slow`/`js_shr_slow` 的 move 语义**就地**改写 `sp[-2]`：不 pop、不 dup、不按操作数挂 free defer。int/bool/float 三个 tag 由 `logicOperandInt32` 纯函数式转换（无分配、不跑用户代码），所以这几条臂不 publish；字符串/对象/symbol/BigInt 仍回落到会 publish 的 `h_binary`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:298` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `opBinary(.shl)` 等六份覆盖（:891-896）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `opCompareCold` (`src/exec/tailcall_dispatch.zig:5687`)

- **签名**：`pub fn opCompareCold(comptime opc: u8) Handler`。
- **作用**：为八个比较 opcode 各生成一份**冷表** handler（谓词 comptime 定死，qjs 的 OP_CMP/OP_CMP_EQ 也是各自独立 CASE 直接点名 `js_relational_slow`/`js_eq_slow`）：非双 int32 的 float/对象/loose-eq 形态在这里寄存器驻留地跑完再 `cont`。
- **实现**：产出的 `hnd` 分两条：L0 停机 seam（`local_fast_blocked`）才 `publish(pc, sp)` + `vm_arith.compareVm` + `coldNext`；否则 `syncPc(pc, 1)`（backtrace 保真）+ `syncSp(sp)`（把未发布的操作数纳入根集）后直接 `vm_arith.compareAt(opc, …)`，成功写 `sp[-2]` 并 `cont(pc + 1, sp - 1, …)`，抛错才 `publish(pc, sp - 2)`（`compareAt` 已释放两个操作数）+ `handleCatchableRuntimeError`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont`；冷续跑：`coldNext`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：工厂无 error set；产出的 handler 用 `vm.fail` 把 helper 错误转成 `.threw`。所有权：comptime 工厂，八个实例。调用：**不由分发进入**，在 `tailcall_dispatch_colds.zig:303` 对八个比较 opcode 各求值一次，装的是 `cold_table` 那一格（`dispatch_table` 的同格随后被 `opCompare(o)` 覆盖，:901）。刻意走「表载间接」而不是从快臂直接尾跳：直路由会扰动 int32 快路径的 codegen。

### `hnd` (`src/exec/tailcall_dispatch.zig:5689`)

- **签名**：`fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`opCompareCold` 展开出的实际 Handler 体（八个比较 opcode 各一份），挂进冷表 `cold_table`。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.compareVm`、`vm_arith.compareAt`、`call_runtime.handleCatchableRuntimeError`、`publish`、`syncPc`、`syncSp`、`coldNext`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 但正常的慢路径**不**经 `publish`：`local_fast_blocked` 为假时它 `syncPc`/`syncSp` 后寄存器驻留地跑完比较再 `cont`；只有 generator 参数/体停机边界那条臂才 publish + `compareVm` + `coldNext`。所有权：两个操作数可能是字符串/对象，转换会跑用户 `valueOf`/`toString`，所以先 `syncPc`（backtrace 保真）+ `syncSp`（把已压栈但未发布的值纳入根集）。调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:303` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `opCompare(o)` 覆盖（:901）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_instanceof_lookup_error` (`src/exec/tailcall_dispatch.zig:5723`)

- **签名**：`fn op_instanceof_lookup_error( pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm, ) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`op_instanceof` 家族的 @@hasInstance 查找失败尾（不是 opcode，由 `op_instanceof_published` 以 `always_tail` 进入）：pop 掉自有区域后把错误投给调用者 catch。
- **实现**：`sp` 被 `_ =` 丢弃（权威是已发布的 `Stack`）：取出 `vm.pending_error`，`popOwnedStackRegion(stack, stack.len() - 2)` 收回 instanceof 的两个操作数槽，再 `handleCatchableRuntimeError`——接住走 `coldNext`，接不住 `vm.fail(err)`（`handleCatchableRuntimeError` 自身再抛则 `vm.fail(e2)`）。它存在的意义是让 `op_instanceof` 的成功臂不必背通用冷壳的 pop/defer/push 与 `coldNext` 再推导。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_instanceof_published` 以 `@call(.always_tail)` 进入。

### `transformInternalCallResult` (`src/exec/tailcall_dispatch.zig:5740`)

- **签名**：`inline fn transformInternalCallResult( comptime return_action: inline_calls.ReturnAction, result: JSValue, ) JSValue`。
- **作用**：按 comptime `return_action` 转换内部 method 调用的结果：`.to_boolean` 时非 bool 结果过 `coercion_ops.valueTruthy` 变成布尔，`.next` 原样返回（comptime 断言只有这两种）。
- **实现**：comptime 参数 `return_action` 先被断言只能是 `.next` 或 `.to_boolean`；`.to_boolean` 分支里已经是 bool 的结果原样返回，否则 `JSValue.boolean(coercion_ops.valueTruthy(result))`；`.next` 分支整支在 comptime 折掉，只剩恒等返回。函数是 `inline`，运行期不存在独立函数体。
- **所有权 / 错误 / 调用**：错误：无。所有权：`.to_boolean` 形态把非 bool 结果经 `valueTruthy` 折成布尔（新值，无所有权负担），`.next` 原样返回。调用：本文件 `:5829`（native 慢臂）与 `:5903`（内联 method 余下臂）。

### `recoverOwnedInternalCallRegion` (`src/exec/tailcall_dispatch.zig:5753`)

- **签名**：`noinline fn recoverOwnedInternalCallRegion( vm: *Vm, region_base: usize, err: HostError, ) InternalMethodDispatch`。
- **作用**：内部 method 调用（instanceof / @@hasInstance 等）在仍拥有 `[receiver, callable, args...]` 区域时的错误：pop 区域，尝试调用者 catch。
- **实现**：`popOwnedStackRegion`。`handleCatchableRuntimeError` catch 写 pending 返回 `.threw`。抓住 `.caught`，否则 `pending_error=err` 返回 `.threw`。永不返回 `.completed`。
- **所有权 / 错误 / 调用**：区域被 pop。调用：`dispatchInternalNativeMethod` 的 poll 失败、Slow 的 native 失败、`internalMethodRemainderHandler` 的 generic call 失败、`completeOrdinaryInstanceof` / `completeInstanceofSlow`。

### `dispatchInternalNativeMethod` (`src/exec/tailcall_dispatch.zig:5777`)

- **签名**：`noinline fn dispatchInternalNativeMethod( comptime return_action: inline_calls.ReturnAction, comptime argc: u16, vm: *Vm, method_object: *core.Object, record: *const core.NativeEntry, region_base: usize, ) InternalMethodDispatch`。
- **作用**：内部 method-call 缝的 native 适配器。调用方提供标准 owned method 区域。宽调用环境和 error union 放在 outline 里，保住驻留 opcode 用的单枚举 ABI。exec_direct 命中（EB: Function[@@hasInstance]）走已有薄终端，不得与 env-path 冷臂共享帧（那份 union 曾把 FastDispatch 从 0x1c0 撑到 0x1d0）。
- **实现**：断言 `return_action` 是 `.next` 或 `.to_boolean`。`stack.len() != region_base+argc+2` 则 `pending_error=InvalidBytecode` 返回 `.threw`。读 receiver 与 args。`pollInterrupt` catch `recoverOwnedInternalCallRegion`。然后 `dispatchInternalNativeMethodSlow`。
- **所有权 / 错误 / 调用**：成功路径由 Slow pop 区域并 push 结果。调用：`op_instanceof` 等内部 method 快路径在解析到 NativeEntry 时。

### `dispatchInternalNativeMethodSlow` (`src/exec/tailcall_dispatch.zig:5803`)

- **签名**：`noinline fn dispatchInternalNativeMethodSlow( comptime return_action: inline_calls.ReturnAction, comptime argc: u16, vm: *Vm, method_object: *core.Object, record: *const core.NativeEntry, region_base: usize, receiver: JSValue, args: []const JSValue, ) InternalMethodDispatch`。
- **作用**：无 exec_direct 的 miss/冷臂：原 `callResolvedNativeMethod` + ToBoolean 包装。`noinline` 负荷：NativeCallEnvironment 的 store 不得撑大 exec_direct 壳。
- **实现**：`_ = argc`。`callResolvedNativeMethod` catch recover。`transformInternalCallResult`（`.to_boolean` 时非 bool 走 `valueTruthy`）。`popOwnedStackRegion` + `pushOwnedAssumeCapacity(result)`，返回 `.completed`。
- **所有权 / 错误 / 调用**：结果 owned 压回栈。调用：仅 `dispatchInternalNativeMethod`。

### `pushInternalMethodAndEnter` (`src/exec/tailcall_dispatch.zig:5836`)

- **签名**：`inline fn pushInternalMethodAndEnter( comptime return_action: inline_calls.ReturnAction, comptime argc: u16, var_buf: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, region_start: [*]JSValue, ) Outcome`。
- **作用**：内部 method 调用（源已经在标准 `[receiver, callable, args...]` 后撤区里）的入帧适配器：帧构造完全复用普通方法调用，只额外钉一个非 `.next` 的续延来做调用后语义处理（如 `.to_boolean`）。
- **实现**：comptime 断言 `return_action != .next`；`source_count = argc + 2`，`pollRetreatedCallRegion` 命中即 `.threw`。`machine.pushMethodCall(vm.global, vm.stack, target, region_start, argc)` 的错误经 `callSetupRecover` 转成 `coldNext(var_buf, vm)` 或 `.threw`；成功后写 `entry.return_action = return_action`，再 `enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr)`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——`pushMethodCall` 的错误经 `callSetupRecover` 转 `coldNext` 或 `.threw`。所有权：调用区是标准 `[receiver, callable, args...]`（`source_count = argc + 2`），push 成功后归新帧；入帧前把 Entry 的 `return_action` 改成 comptime 给定的值（断言不是 `.next`，因为这条路专供需要后处理的内部调用，如 `.to_boolean`）。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:5890`（`internalMethodRemainderHandler` 生成体内）。

### `internalMethodRemainderHandler` (`src/exec/tailcall_dispatch.zig:5859`)

- **签名**：`fn internalMethodRemainderHandler( comptime return_action: inline_calls.ReturnAction, comptime argc: u16, ) Handler`。
- **作用**：按 `return_action` / `argc` 生成一份内部 method-call 的深层余下 Handler；每个实例保持精确 `Handler` ABI 以便 musttail。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`inline_calls.ReturnAction`、`object_ops.objectFromValue`、`inline_calls.resolveInlineFunctionFromObject`、`call_runtime.callValueOrBytecodeRoot`、`call_runtime.popOwnedStackRegion`、`next`、`coldNext`、`cont`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，生成的 handler 以 `Outcome` 返回。所有权：comptime 工厂，返回 `struct { fn hnd(...) }.hnd`，每个实例保持精确 `Handler` ABI（`align(16)`、`linksection(op_handler_section)`、`callconv(.c)`）以便 musttail；当前唯一实例化在 `src/exec/tailcall_dispatch.zig:5916` 赋给文件级 `to_boolean_one`，再由 `InternalMethodBoundary.toBooleanOne()` 取出，而不是进 `dispatch_table`。生成体内 `retreatToCallRegion` 把调用区登记进 `pending_call_region` 后按叶形态选 push 路径。调用：工厂本身只在 `:5916` 被调用一次。

### `hnd` (`src/exec/tailcall_dispatch.zig:5865`)

- **签名**：`fn hnd(resume_pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：`internalMethodRemainderHandler` 展开出的实际 Handler 体：内部 method 调用返回后的余下工作，不进分发表。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`object_ops.objectFromValue`、`inline_calls.resolveInlineFunctionFromObject`、`call_runtime.callValueOrBytecodeRoot`、`call_runtime.popOwnedStackRegion`、`coldNext`、`cont`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）。
- **所有权 / 错误 / 调用**：错误：调用建立失败时交 `callSetupRecover`（接住则 `coldNext`，否则 `.threw`）。所有权：`[receiver, method, args…]` 区域是自有的，`popOwnedStackRegion` 负责回收；`entry.return_action` 记下 `.to_boolean` 这类结果动作，`transformInternalCallResult` 在返回时把结果折成布尔。调用：**不在任何分发表里**。当前唯一实例 `(.to_boolean, argc=1)` 存在文件级 `var to_boolean_one`（`:5916`），由 `InternalMethodBoundary.toBooleanOne()` 经 `*volatile` 读出，`op_instanceof` 的自定义 `@@hasInstance` 臂（`:6081`）尾跳进来。

### `InternalMethodBoundary.toBooleanOne` (`src/exec/tailcall_dispatch.zig:5916`)

- **签名**：`inline fn toBooleanOne() Handler`。
- **作用**：通过 `volatile` Handler 槽读出 `(.to_boolean, argc=1)` 那份余下 handler——这样 Zig 0.16 不会把这个私有 handler 折回它唯一的驻留调用者（会让那条 opcode 膨胀数 KiB）。
- **实现**：取文件级 `var to_boolean_one`（初值是 comptime 的 `internalMethodRemainderHandler(.to_boolean, 1)`）的地址，转成 `*volatile Handler` 再解引用。volatile 强制这次 load 留在运行期，Zig 0.16 因此无法把那份私有 handler 常量折回它唯一的驻留调用者——直接折回会把那条 opcode 撑大好几 KiB。代价只是一次 `.data` 读，换来的仍是无栈 musttail ABI，且不必导出符号。
- **所有权 / 错误 / 调用**：错误：无。所有权：通过 `*volatile Handler` 读取文件级变量 `to_boolean_one`，volatile 是为了阻止编译器把工厂产出的 handler 常量折叠/内联回调用点（保住独立的 musttail 目标）。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:6081`（`instanceof` 的内部 method 边界尾跳）。

### `completeOrdinaryInstanceof` (`src/exec/tailcall_dispatch.zig:5927`)

- **签名**：`noinline fn completeOrdinaryInstanceof(vm: *Vm) InternalMethodDispatch`。
- **作用**：qjs:16005-16017 `js_operator_instanceof` 在成功 `JS_IsInstanceOf` 后的尾声：释放两操作数，把 bool 写到 `sp[-2]`。Get 已解析到默认 `Function.prototype[@@hasInstance]`（qjs:41379-41383 `js_function_hasInstance` → `JS_OrdinaryIsInstanceOf`）时跳过 generic native Call，直接 Ordinary。
- **实现**：`region_base = len-2`，lhs/rhs 为两槽。`ordinaryHasInstance(ctx, output, global, rhs, lhs, function, frame)` catch recover。pop 区域，`pushOwnedAssumeCapacity(boolean(result))`，`.completed`。
- **所有权 / 错误 / 调用**：两操作数 pop 释放，bool 新压栈。调用：`op_instanceof` 在 default hasInstance 命中时。

### `completeInstanceofSlow` (`src/exec/tailcall_dispatch.zig:5949`)

- **签名**：`noinline fn completeInstanceofSlow(vm: *Vm, has_instance: JSValue) InternalMethodDispatch`。
- **作用**：权威慢完成：null-method 遗留臂、原语 RHS 拒绝、以及栈上没有多余槽的罕见情况。
- **实现**：同样读 lhs/rhs。`instanceofValueWithMethod(..., has_instance)` catch recover。pop 区域，push boolean，`.completed`。
- **所有权 / 错误 / 调用**：`has_instance` 由调用方传入（可能是自定义 @@hasInstance）。调用：`op_instanceof` 快路径未命中时。

### `tryFastDefaultInstanceof` (`src/exec/tailcall_dispatch.zig:5971`)

- **签名**：`inline fn tryFastDefaultInstanceof(lhs: JSValue, ctor: *core.Object, vm: *Vm) ?bool`。
- **作用**：`instanceof` 的寄存器内快路径：确认构造器上的 `Symbol.hasInstance` 仍是 realm 默认的 `Function.prototype[@@hasInstance]` 后，直接做 Ordinary 原型链走查，返回 true/false 即结论；返回 null 表示判不了，交给已发布的 remainder 去 Call。
- **实现**：先排除 Proxy 与 bound function；然后按 qjs GetProperty 在函数上的形状找 `Symbol.hasInstance`：一次 `findOwnDataSlotFast` 自有哈希探测，miss 且没有 exotic 方法就**只跳一层原型**再探一次（qjs 8210-8294 同样是 own miss + 一个 `p->shape->proto` hop + 命中 Function.prototype），任何 `slow` 标记或自定义/中间层的 `@@hasInstance` 都返回 null 交给已发布的余下 handler 去 Call。拿到方法后要求它是 `c_function` 且 `recordIsDefaultHasInstance`；再 `isFunctionLikeClass` + 取 `prototype` 自有槽，最后从 `lhs` 起沿原型链线性走（遇到 Proxy 返回 null，找到 `proto` 返回 true，走到头返回 false）。没有通用探测循环、没有 `isCallableValue`/`getOwnDataObjectBorrowed`——那些 `findProperty` 外调就是被砍掉的约 160 insn。
- **所有权 / 错误 / 调用**：错误：无；返回 null 表示「判不了，走通用 `instanceof`」，返回 false/true 才是结论。所有权：只读——Proxy/bound function 直接放弃；沿构造器自身与其原型找 `Symbol.hasInstance` 的自有数据槽（`findOwnDataSlotFast`，`slow` 置位即放弃），确认它仍是默认内建 `recordIsDefaultHasInstance`，再走 `prototype` 原型链比较。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:6095`。

### `op_instanceof_published` (`src/exec/tailcall_dispatch.zig:6017`)

- **签名**：`fn op_instanceof_published( pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm, ) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：`op_instanceof` 的已发布慢臂（不是独立 opcode，由 `op_instanceof` 以 `always_tail` 进入）：publish 后按 @@hasInstance 解析走 default / 自定义 method 路径。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`object_ops.objectFromValue`、`object_ops.probePublicNamedDataPropertyFromObject`、`call_runtime.instanceofMethodSlow`、`vm_call.resolvedNativeMethodRecord`、`function_ops.isDefaultHasInstanceRecord`、`publish`、`cont`、`coldNext`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_instanceof` 以 `@call(.always_tail)` 进入。

### `op_instanceof` (`src/exec/tailcall_dispatch.zig:6082`)

- **签名**：`pub fn op_instanceof(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_instanceof 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先查 `vm.local_fast_blocked`（停机 seam）→ `cold_table[pc[0]]`；否则 `loadValueAsIntPair` 取 rhs，`objectFromValue` 拿不到对象就尾跳 `op_instanceof_published`；拿到就交 `tryFastDefaultInstanceof((sp-2)[0], rhs_object, vm)`——命中（true/false）时把布尔写进 `sp[-2]`、`setTopPtr(sp-1)` 后 `cont(pc+1, …)`，返回 null（Proxy / bound function / 自定义或中间层 `@@hasInstance` / 任何慢探测）同样尾跳 `op_instanceof_published`。 对应 qjs OP_instanceof（quickjs.c:20412-20417）的 `JS_IsInstanceOf` + 就地 free/replace；默认 `Function.prototype[@@hasInstance]` 那条走查对「自有数据 `.prototype` 的普通对象」不会抛，所以快臂连 `sf->cur_pc` 的发布都不需要——只有可能抛或必须 Call 非默认方法时才跳到已发布的 remainder。 栈效应：-1（两个操作数 → 一个布尔）。 下一跳：`cont` / `op_instanceof_published` / `cold_table[pc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。三条出边：`vm.local_fast_blocked` → `cold_table[pc[0]]`；rhs 不是对象、或 `tryFastDefaultInstanceof` 返回 null → 直接 PC-relative 尾跳 `op_instanceof_published`（真正用到 `InternalMethodBoundary.toBooleanOne()` 的是那一份，`:6081`）；其余就地完成。 所有权：快臂只借用 `sp[-2]`/`sp[-1]`，结果布尔就地写 `sp[-2]` 并把 `top_ptr` 收到 `sp-1`，不分配、不建根。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:986`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入。

### `op_neg` (`src/exec/tailcall_dispatch.zig:6108`)

- **签名**：`pub fn op_neg(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_neg 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：整数/布尔/null/float 就地取反写回；需要 ToNumeric 的操作数（会跑用户代码）留给冷壳，与 qjs CASE(OP_neg) 的分工一致。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:904`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_inc_dec` (`src/exec/tailcall_dispatch.zig:6137`)

- **签名**：`pub fn op_inc_dec(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_inc / OP_dec 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：`inc`/`dec` 共用一份，int32 就地 ±1；溢出与非整数落冷壳。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:905`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_post_inc_dec` (`src/exec/tailcall_dispatch.zig:6154`)

- **签名**：`pub fn op_post_inc_dec(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_post_inc / OP_post_dec 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：`post_inc`/`post_dec` 共用一份，int32 快臂把旧值留在栈上、新值写回。每个 `let` 计数循环每轮都执行它（受检左值在 resolve_labels 的 plain-loc 融合之外，与 qjs 相同）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:910`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_dup` (`src/exec/tailcall_dispatch.zig:6166`)

- **签名**：`pub fn op_dup(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_dup：把栈顶再压一份（`v -> v v`），对应 qjs `CASE(OP_dup)`。
- **实现**：`const v = (sp - 1)[0]; sp[0] = v;` 再 `cont(pc + 1, sp + 1, var_buf, vm)`——一读一写，整 16 字节 JSValue 原样复制，函数体里没有任何 retain/dup 调用。注释给出的是与 qjs 的对照：`CASE(OP_dup)`（quickjs.c:18038-18041）只调一次 `JS_DupValue`，而 refcount-tag 判断在 `JS_DupValue` 体内（quickjs.h:707-713）；把 duplicate 闸提到调用方只会逼这个 handler 先物化一个选择临时值再存。函数以 `align(32)` 落位。
- **所有权 / 错误 / 调用**：所有权：新栈顶与原栈顶指向同一个值，没有额外持有者要登记。 错误：无，本 handler 不会抛。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:911`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；`cold_table` 的同一格是另一份 `coldStd` 冷壳（:575）。

### `op_insert2` (`src/exec/tailcall_dispatch.zig:6180`)

- **签名**：`pub fn op_insert2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_insert2：把栈顶值再插一份到它下面那个值的下方（`obj value -> value obj value`），赋值类表达式用它保住结果值。
- **实现**：实现 `obj value -> value obj value`（quickjs.c:18058-18063）。先把栈顶 `value = (sp - 1)[0]` 读进寄存器，然后三条就地 store：`sp[0] = value`（新栈顶）、`(sp - 1)[0] = (sp - 2)[0]`（obj 上移一格）、`(sp - 2)[0] = value`（新的最底一份拷贝）；最后 `cont(pc + 1, sp + 1, var_buf, vm)`，栈深 +1、pc +1。没有临时数组，也不释放任何值：只有被复制的 `value` 多出一份，其余槽都是纯搬移。
- **所有权 / 错误 / 调用**：所有权：只有 `value` 被复制一次，其它槽是移动；内存操作数栈全程保持权威。 错误：无。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:916`，在 `if (!fast) return`（:818）之后）；`cold_table` 的同一格是另一份冷壳（:605）。

### `op_insert3` (`src/exec/tailcall_dispatch.zig:6191`)

- **签名**：`pub fn op_insert3(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_insert3：把栈顶值再插一份到 obj/key 两格之下（`obj key value -> value obj key value`），计算成员赋值用它保住结果值。
- **实现**：实现 `obj key value -> value obj key value`（quickjs.c:18064-18070）。读出栈顶 `value` 后四条就地 store：`sp[0] = value`、`(sp - 1)[0] = (sp - 2)[0]`、`(sp - 2)[0] = (sp - 3)[0]`、`(sp - 3)[0] = value`，即 obj/key 各上移一格、`value` 同时占住新栈顶与新底；然后 `cont(pc + 1, sp + 1, var_buf, vm)`，栈深 +1、pc +1。与 `op_insert2` 同理，只有被复制的 `value` 多一个持有者。
- **所有权 / 错误 / 调用**：所有权：只有 `value` 被复制一次，obj/key 是纯移动。 错误：无。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:917`，在 `if (!fast) return`（:818）之后）；`cold_table` 的同一格是另一份冷壳（:610）。

### `op_perm3` (`src/exec/tailcall_dispatch.zig:6203`)

- **签名**：`pub fn op_perm3(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_perm3 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：用 `loadValueAsIntPair`/`storeValueAsIntPair` 做两槽轮转：`old = sp[-2]`、`object = sp[-3]`，回写 `sp[-2] = object`、`sp[-3] = old`，然后 `cont(pc+1, sp, …)`。刻意不用整值赋值——AArch64 上那会让 LLVM 用 q 寄存器并把一个临时溢出到原生栈；走整数对 helper 则保住逐位相同、各自独立的 SSA 值，后端可以合并最终的 mov 但不留栈临时。 栈效应：0，pc 前进 1 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：`obj old value -> old obj value` 的两槽互换（qjs OP_perm3），栈深与引用计数都不变；刻意用 `loadValueAsIntPair`/`storeValueAsIntPair` 而不是整值赋值，否则 AArch64 上会用 q 寄存器并溢出一个临时。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:918`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_swap` (`src/exec/tailcall_dispatch.zig:6216`)

- **签名**：`pub fn op_swap(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_swap 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：三条语句的经典交换：`tmp = sp[-2]`、`sp[-2] = sp[-1]`、`sp[-1] = tmp`，然后 `cont(pc+1, sp, …)`。 栈效应：0，pc 前进 1 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：`sp[-2]` 与 `sp[-1]` 互换，纯移动。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:919`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `jump8Target` (`src/exec/tailcall_dispatch.zig:6230`)

- **签名**：`inline fn jump8Target(pc: [*]const u8, vm: *Vm) [*]const u8`。
- **作用**：解码跳转立即数并返回目标 pc（`jump8Target`）。
- **实现**：先把操作数字节换算成帧内偏移 `operand_pc = (pc + 1) - vm.code_base`，再把 `pc[1]` 按 `i8` 解释成位移相加，返回 `vm.code_base + 结果`。位移基准是**操作数字节**而不是下一条指令（沿用旧 `operand_pc = reg_ip - code.ptr` 约定，与 qjs 一致）。无边界检查：跳转目标的合法性由 finalize 的可达性检查与跳转感知的 epilogue 保证。
- **所有权 / 错误 / 调用**：错误：无（目标合法性由字节码校验保证）。所有权：纯地址算术——以操作数字节的偏移为基准加上 i8 位移，返回 `vm.code_base` 内的新 pc。调用：本文件 `:6249`、`:6296`、`:6331`、`:6339`、`:6350`（goto8 / if_false8 / if_true8 等短跳）。

### `op_goto8` (`src/exec/tailcall_dispatch.zig:6237`)

- **签名**：`pub fn op_goto8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_goto8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：0，栈完全不动；pc 换成 `jump8Target(pc, vm)`。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：不动栈；`jump8Target` 算出目标 pc 后 `cont`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:925`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 guard 是 `vm.ctx.pollInterruptTick()`：中断 cadence 命中才经 `cold_table` 重跑这条 opcode，由冷壳做发布式轮询（冷臂的第二次递减落在 ≤0，仍会触发 reset + handler）。

### `jump16Target` (`src/exec/tailcall_dispatch.zig:6252`)

- **签名**：`inline fn jump16Target(pc: [*]const u8, vm: *Vm) [*]const u8`。
- **作用**：解码跳转立即数并返回目标 pc（`jump16Target`）。
- **实现**：与 `jump8Target` 同构，位移改成 `readInt(i16, pc + 1)`；基准同样是操作数字节（对应 `vm_control.jump16` / qjs OP_goto16）。
- **所有权 / 错误 / 调用**：错误：无。所有权：同构，位移用 `readInt(i16, pc + 1)`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:6267`（`goto16`）。

### `op_goto16` (`src/exec/tailcall_dispatch.zig:6262`)

- **签名**：`pub fn op_goto16(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_goto16 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：0，栈完全不动；pc 换成 `jump16Target(pc, vm)`。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：同 `op_goto8`，位移 2 字节。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:928`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_goto` (`src/exec/tailcall_dispatch.zig:6271`)

- **签名**：`pub fn op_goto(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_goto 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：0 无条件跳。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：同 `op_goto8`，位移 4 字节（复用 `jump32Target`）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:929`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_if_false8` (`src/exec/tailcall_dispatch.zig:6286`)

- **签名**：`pub fn op_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_if_false8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表；间接驻留尾：`resident_tail_tbl[slot]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。四条出边：布尔/整数立即数臂就地判定后 `cont`；普通对象走 qjs `JS_ToBoolFree` 的对象腿；中断 cadence 命中 → `cold_table[pc[0]]`；其余形态 → `residentTailHandler(vm, .if_false8_complex)`。 所有权：被消费的值可能持有对象/rope/堆 BigInt，所以在释放前先把 `stack.top_ptr` 缩到 `sp-1`；pc 与新 sp 留在寄存器里，`op_if_false8_complex` 因而永远不进 `coldNext`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:930`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_if_false8_complex` (`src/exec/tailcall_dispatch.zig:6321`)

- **签名**：`fn op_if_false8_complex(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：驻留尾表槽 `resident_tail_tbl[.if_false8_complex]`（不是独立 opcode）：OP_if_false8 的操作数不是立即布尔时由 `op_if_false8` 间接尾调用进入，`toBoolean` 后 `cont` 到目标或下一条。
- **实现**：`value = (sp-1)[0]` → `core.value_semantics.toBoolean(value)` → `nsp = sp - 1` → `vm.stack.setTopPtr(nsp)`；然后按真假 `cont(jump8Target(pc, vm), nsp, …)` 或 `cont(pc + 2, nsp, …)`。只发布栈顶、不发布 pc：被消费的值可能持有对象/rope/堆 BigInt，析构需要一个更短的 GC 根窗口，而 pc 与下一个 sp 全程留在寄存器里——**本体永远不进 `coldNext`**。中断轮询在调用方 `op_if_false8` 里已经做过。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：由对应热 handler 经 `residentTailHandler(vm, .if_false8_complex)` 间接尾调用进入（不在 256 槽分发表里）。

### `op_if_true8` (`src/exec/tailcall_dispatch.zig:6332`)

- **签名**：`pub fn op_if_true8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_if_true8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：同 `op_if_false8` 的立即数/对象臂，判定取反；其余形态与 HTMLDDA 落冷壳。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:933`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `jump32Target` (`src/exec/tailcall_dispatch.zig:6357`)

- **签名**：`inline fn jump32Target(pc: [*]const u8, vm: *Vm) [*]const u8`。
- **作用**：解码跳转立即数并返回目标 pc（`jump32Target`）。
- **实现**：与 `jump8Target` 同构，位移是 `readInt(i32, pc + 1)`，对应 qjs OP_if_false 的 `pc += (int32_t)get_u32(pc - 4) - 4`——同样以操作数字节为基准，与冷壳 branch32 的 `relativePc(operand_pc, diff)` 约定一致。
- **所有权 / 错误 / 调用**：错误：无。所有权：同构，位移是 i32。调用：本文件 `:6276`（`goto`）与 `:6378`（`if_false` 的长跳臂）。

### `op_if_false` (`src/exec/tailcall_dispatch.zig:6371`)

- **签名**：`pub fn op_if_false(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_if_false 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`next`、`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 5 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：长形态（4 字节标号）的同体，走 `jump32Target`；float/string/HTMLDDA 与 cadence 命中落冷壳 `branch32`。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:937`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_cmp_if_false8` (`src/exec/tailcall_dispatch.zig:6395`)

- **签名**：`pub fn op_cmp_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_cmp_if_false8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：本体 -1（比较结果写 `sp[-2]`、弹掉 rhs），随后 `op_if_false8` 再消费掉那个布尔，融合对整体净 -2。 下一跳：未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；双整数与双数值臂都**直接 PC-relative 尾跳 `op_if_false8`**（残留的 B 还在流里，所以轮询和跳转都由那一份做），其余落 `cold_table[pc[0]]`。 所有权：比较结果布尔写 `sp[-2]`、弹掉 rhs 后把新 `sp` 交给 `op_if_false8`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:931`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_eq_if_false8` (`src/exec/tailcall_dispatch.zig:6417`)

- **签名**：`pub fn op_eq_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_eq_if_false8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：本体 -1（比较结果写 `sp[-2]`、弹掉 rhs），随后 `op_if_false8` 再消费掉那个布尔，融合对整体净 -2。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。双整数命中 → 直接尾跳 `op_if_false8`；**其余全部形态直接尾跳导出符号 `zjs_cmp_eq_mixed`**（它再 `always_tail` 进 `opCompareEqFast(.eq)`；需要 release 阶梯的 last-ref 形态才继续转 `zjs_cmp_eq_framed` → `opCompareEq(.eq)` 的九臂体——与非融合 `eq` 走的是同一条链），而不是走 `cold_table` 或 `eq_if_false8_cold`——后者是 wave-21 richards +579M 的税。 所有权：结果布尔写 `sp[-2]` 并弹 rhs。这一族绝不能共用 `pc[0]` 的 switch：残留 opcode 不是 `op.eq`，会被误路由。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:932`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_eq_if_false8_cold` (`src/exec/tailcall_dispatch.zig:6424`)

- **签名**：`pub fn op_eq_if_false8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_eq_if_false8 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.compareVm`、`vm_arith.compareAt`、`call_runtime.handleCatchableRuntimeError`、`publish`、`coldNext`。 栈效应：与对应热 handler 相同；先 `publish` 再走 outlined helper，helper 改 `stack.top_ptr`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 但只有 `vm.local_fast_blocked` 那条臂 publish + `compareVm` + `coldNext`；正常慢臂 `syncPc` + `syncSp` 后寄存器驻留地跑完再 `cont`。所有权：操作数转换可能跑用户代码，`syncSp` 保证已压栈未发布的值在根集里。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:806` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_eq_if_false8` 覆盖（:932）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_cmp_if_false8_cold` (`src/exec/tailcall_dispatch.zig:6446`)

- **签名**：`pub fn op_cmp_if_false8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_cmp_if_false8 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.compareVm`、`vm_arith.compareAt`、`call_runtime.handleCatchableRuntimeError`、`publish`、`coldNext`。 栈效应：与对应热 handler 相同；先 `publish` 再走 outlined helper，helper 改 `stack.top_ptr`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 同 `op_eq_if_false8_cold` 的两臂结构（停机 seam publish / 正常臂寄存器驻留）。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:805` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_cmp_if_false8` 覆盖（:931）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_is_null` (`src/exec/tailcall_dispatch.zig:6480`)

- **签名**：`pub fn op_is_null(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_is_null 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`value = (sp-1)[0]`，`is(.null_value)` 真假两臂都只是把 `sp[-1]` 原地覆盖成布尔再 `cont(pc+1, sp, …)`——写成两条分支而不是一次 `JSValue.boolean(v.is(.null_value))`，是为了让拥有值那条路上「先覆盖（值随即不再是根）→ 在不变的 sp 上钉活跃窗口 → 释放」的次序显式成立。无中断轮询（qjs 的 CASE 没有，原来的冷 helper 也没有）。 栈效应：0，pc 前进 1 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：把 `sp[-1]` 原地覆盖成布尔——非拥有值只需一次覆盖；拥有值也是先覆盖（它随即不再是根），再在不变的 `sp` 上做活跃窗口钉定，与 `op_lnot` 的对象臂同一套根窗口次序。无中断轮询（qjs 的 CASE 也没有）。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:944`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_lnot` (`src/exec/tailcall_dispatch.zig:6519`)

- **签名**：`pub fn op_lnot(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_lnot 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 1 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：立即数臂按 qjs 的同一次无符号 tag 比较判定并就地覆盖；对象臂取 `JS_ToBoolFree` 的对象腿，释放前同样先缩 `top_ptr`。其余 tag 落冷壳。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:943`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_update_loc` (`src/exec/tailcall_dispatch.zig:6540`)

- **签名**：`pub fn op_update_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_inc_loc / OP_dec_loc 的热 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：int32 局部就地 ±1，栈中性。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:945/948`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 guard 未命中（float/BigInt/对象计数器）经 `cold_table[pc[0]]` 落到专用的 `op_update_loc_cold`，刻意走表载间接而不是直跳——直路由会扰动 int32 快路径的 codegen。`inc_loc` 与 `dec_loc` 共用这一份。

### `op_put_loc8_get_loc8` (`src/exec/tailcall_dispatch.zig:6564`)

- **签名**：`pub fn op_put_loc8_get_loc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_loc8_get_loc8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：写路径，put 多为 -1，set 多为 0。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体没有失败路径，不写 `vm.pending_error` 也不返回 `.threw`。 所有权：`var_buf[pc[1]] = (sp-1)[0]`，帧局部是 trace-owned，覆盖没有 release 尾巴。 下一跳不走表：直接 `@call(.always_tail, opLoc(.get, .byte), …)` 进入残留的 `get_loc8`（B 仍留在字节码流里，所以它看见的还是自己的 opcode）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:946`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_put_loc8_get_loc8_cold` (`src/exec/tailcall_dispatch.zig:6571`)

- **签名**：`pub fn op_put_loc8_get_loc8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_loc8_get_loc8 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：写路径，put 多为 -1，set 多为 0。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:807` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_put_loc8_get_loc8` 覆盖（:946）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 只做 `put_loc8` 一半，再 `coldNext` 到残留的 `get_loc8`。

### `op_push_this_put_loc0` (`src/exec/tailcall_dispatch.zig:6579`)

- **签名**：`pub fn op_push_this_put_loc0(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_this_put_loc0 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：`storeThisInLoc0` 把 `this`（或 sloppy 的 realm global）写进 loc0，省掉临时 JSValue 溢出；返回 false 的形态（strict 未初始化 / sloppy 需装箱的原始值）落冷壳。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:947`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `storeThisInLoc0` (`src/exec/tailcall_dispatch.zig:6586`)

- **签名**：`inline fn storeThisInLoc0(var_buf: [*]JSValue, vm: *Vm) bool`。
- **作用**：把 `frame.this_value` 按 push_this 的分臂写进 loc0：对象直接写、sloppy 的 undefined/null 换成 realm global、strict 的非 uninitialized 原样写；其余返回 false 交冷路径。
- **实现**：读 `vm.frame.this_value` 后三段分支：① 是对象——直接写 `var_buf[0]` 返回 true（最热臂，不查 strict）；② strict（`isStrictMode() or runtimeStrictMode()`）——uninitialized 返回 false（派生类构造器里 `super()` 之前的 TDZ），其余原样写入；③ sloppy 的 undefined/null——写 `vm.global.value()`。落到函数尾的只剩 sloppy 的原始值（需要 ToObject 装箱），返回 false 交冷路径。
- **所有权 / 错误 / 调用**：错误：无，返回 false 表示这条快路径不适用（strict 且 `this` 未初始化、或 sloppy 下 `this` 是需要装箱的原始值），调用方回落冷路径。所有权：把 `frame.this_value`（或 sloppy 的 `global.value()`）复制进 `var_buf[0]`，即 loc0；不移动源。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:6581`。

### `op_push_this_put_loc0_cold` (`src/exec/tailcall_dispatch.zig:6604`)

- **签名**：`pub fn op_push_this_put_loc0_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_push_this_put_loc0 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_value.pushThisVm`、`publish`、`coldNext`。 栈效应：+1。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_value.pushThisVm`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:808` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_push_this_put_loc0` 覆盖（:947）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 它走完整的 `pushThisVm`（含 ToObject 装箱与 strict 未初始化的抛错），不是只做一半。

### `op_update_loc_cold` (`src/exec/tailcall_dispatch.zig:6618`)

- **签名**：`pub fn op_update_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_inc_loc / OP_dec_loc 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.updateLocalVm`、`vm_arith.updateLocalAt`、`call_runtime.handleCatchableRuntimeError`、`publish`、`coldNext`、`cont`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 两条臂：`local_fast_blocked` 时 publish + `updateLocalVm` + `coldNext`（保证 `maybeStop` 在这条 opcode 正好停在 `stop_before_pc` 时能触发）；正常臂 `syncPc(pc, 2)` + `syncSp(sp)` 后直接对 `&var_buf[idx]` 调 `updateLocalAt`，成功 `cont`，失败先 `publish(pc + 1, sp)` 再 `handleCatchableRuntimeError`——接住走 `coldNext`，接不住 `vm.fail(err)`。 所有权：ToNumeric 会跑用户 `valueOf`/`toString`（可分配），inc/dec 本身栈中性但窗口陈旧，所以仍要 `syncSp` 把未发布的值纳入根集；`syncPc` 是 backtrace 保真。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:337/338` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_update_loc` 覆盖（:945/948）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 `inc_loc` 与 `dec_loc` 两格都是它。

### `op_add_loc` (`src/exec/tailcall_dispatch.zig:6638`)

- **签名**：`pub fn op_add_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_add_loc 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`cont`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；两条数值臂之外（int+float 混合、字符串、对象、BigInt）**直接 PC-relative 尾跳 `op_add_loc_cold`**，不经 `cold_table[pc[0]]`。 所有权：int32 溢出时就地换成 float64，两个操作数都是非引用计数裸值，所以局部槽是裸覆盖、弹掉的 rhs 也不用 free。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:982`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_add_loc_cold` (`src/exec/tailcall_dispatch.zig:6680`)

- **签名**：`pub fn op_add_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_add_loc 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.addLocalVm`、`vm_arith.addLocalAt`、`call_runtime.handleCatchableRuntimeError`、`coldNext`、`cont`、`publish`、`syncPc`、`syncSp`。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 2 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 与 `op_update_loc_cold` 同构的两臂结构。 所有权：正常臂把局部槽指针 `&var_buf[idx]` 与 rhs **值**直接交给 `addLocalAt`（qjs 的 `js_add_loc_slow(ctx, pv, sp)`），helper 既不重读 `frame.pc` 取操作数也不 pop 栈，所以热路径上没有 publish→重读→`coldNext` 的 `frame.pc` 内存往返。它**不是**数值快臂：int+float 与 string/object/BigInt 跑的是同一份完整 `addLocal`，只是少了一次 `addLocalVm` 的外联调用边界（实测 int+float 曾有 29.7% 空闲周期卡在那里）。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:342` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_add_loc` 覆盖（:982）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `getVarGlobalOwnDataInline` (`src/exec/tailcall_dispatch.zig:6747`)

- **签名**：`inline fn getVarGlobalOwnDataInline(vm: *Vm, idx: u16) ?JSValue`。
- **作用**：`op_get_var` 及 get_var_field 冷臂共用的「全局对象自有数据属性」内联探针：未初始化 cell 时替代整条 `vm_property_globals.getVar` waterfall 的命中腿。
- **实现**：`op_get_var` 的 uninitialized 臂内联探针：非 lexical 且函数不是 runtime-strict 时，在 realm global 上做纯自有 shape 哈希探测（原子相等 + 未删除位 + kind==data 的裸位测试），命中返回该槽的数据值，其余一律返回 null 交给冷 waterfall。Debug 断言 `idx < function.closureVar().len`。强制内联：外联一次 `bl` 会给整个 handler 加前言、连命中腿一起付。
- **所有权 / 错误 / 调用**：错误：无；非词法且非 strict、global 无 exotic 方法、且在 shape 链上找到普通数据槽才返回值，其余一律 null 回落冷路径。所有权：返回全局对象属性槽里值的副本（借用语义，不改属性）；遍历带 `steps < prop_count` 的上限防环。调用：本文件 `:6818`（`op_get_var` 的 uninitialized 臂）与 `:7374`（`op_get_var_field_cold`）。

### `op_get_var` (`src/exec/tailcall_dispatch.zig:6780`)

- **签名**：`pub fn op_get_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_get_var 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`getVarGlobalOwnDataInline`、`cont`（未命中改走 `cold_table[pc[0]]` 里的 `vm_property_globals.getVar`）。 栈效应：寄存器 `sp` 净效应 +1，pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；guard 未命中原样把 `pc`/`sp` 交给 `@call(.always_tail, cold_table[pc[0]])`，由那份冷壳 publish + helper + `vm.fail` 负责抛。 所有权：命中臂从 var-ref cell 或全局对象自有数据槽读出借用副本压栈。 调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:983/984`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。 `get_var` 与 `get_var_undef` 共用这一份。

### `op_put_var` (`src/exec/tailcall_dispatch.zig:6844`)

- **签名**：`pub fn op_put_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome`。
- **作用**：OP_put_var 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`core.VarRef.setVarRefValue`、`cont`（未命中改走 `cold_table[pc[0]]` 里的 `vm_property_globals.putVar`）。 栈效应：寄存器 `sp` 净效应 -1，pc 前进 3 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误；四条 guard（越界、TDZ/已删绑定、const 槽、间接 var-ref、函数名槽）任一不满足就 `cold_table[pc[0]]` 交给 `h_put_var`。 所有权：**命中臂发生所有权转移**——`setVarRefValue`（强制 `always_inline`）把 `sp-1` 的值移进 cell 并释放被顶掉的旧值，与冷臂的 `stack.pop()` 语义一致，不做 dup。这条释放可能跑原生 finalizer，但不会抛、不会分配、不会重入 VM，所以这一臂**不 publish**；`sp-1` 以下的死槽也不会被重读（唯一会读陈旧 `top_ptr` 的是 catch unwinder，而这一臂没有抛出边）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:985`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `pushExactArgsLeafMiss` (`src/exec/tailcall_dispatch.zig:6924`)

- **签名**：`noinline fn pushExactArgsLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16) align(32) EmptyLeafMiss`。
- **作用**：`pushEmptyLeafMiss` 的 exact-args 孪生。放在 handler 簇之后，避免插在中间平移后续 handler 地址（BTB/fetch 别名，bit-identical 指令下 inline-control 循环 +2.4% cycles）。
- **实现**：`pushExactArgsLeafCall` catch：`callSetupRecover` 失败 `.threw`，成功 `.recovered`；否则 `.entry`。
- **所有权 / 错误 / 调用**：同 `pushEmptyLeafMiss`。调用：`pushWarmExactArgsLeafAndEnter` 在 `tryPushExactArgsLeafCallFast` 未命中时。

### `warmExactArgsLeafOutline` (`src/exec/tailcall_dispatch.zig:6940`)

- **签名**：`noinline fn warmExactArgsLeafOutline(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8) EmptyLeafMiss`。
- **作用**：raw-`this` plain 臂的 outline 热 exact-args 构造器。固定 arity handler 只保留一份内联热体（已建立的 sloppy pivot：add(a,b)、fib）；再内联 raw 孪生会把邻近 exact simple 构造器重新登记（closure-two-arg +1.3% cyc）。一次 bl 仍删掉 InlineTarget 货运和三层构造链。
- **实现**：`tryPushExactArgsLeafCallFast` 命中则 `.entry`。否则 `pushExactArgsLeafCall` catch recover。
- **所有权 / 错误 / 调用**：同 miss 族。调用：`pushWarmOutlineExactArgsLeafAndEnter`。

### `pushCaptureLeafMiss` (`src/exec/tailcall_dispatch.zig:6955`)

- **签名**：`noinline fn pushCaptureLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue) EmptyLeafMiss`。
- **作用**：capture-leaf 版 `pushEmptyLeafMiss`。同样放在簇后，避免平移 handler 地址。
- **实现**：`pushCaptureLeafCall` catch recover，否则 `.entry`。
- **所有权 / 错误 / 调用**：同空叶 miss。调用：`pushWarmCaptureLeafAndEnter` 快路径未命中时。

### `warmCaptureLeafOutline` (`src/exec/tailcall_dispatch.zig:6970`)

- **签名**：`noinline fn warmCaptureLeafOutline(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8) EmptyLeafMiss`。
- **作用**：sloppy plain 臂的 outline 热 capture-leaf 构造器。零参 handler 只新内联一份热体（raw-`this` pivot：`() => this.x`）；再内联 sloppy 孪生会重登记邻近热体（O1 测量：第二份内联体 +1.3% cyc）。
- **实现**：`tryPushCaptureLeafCallFast` 命中 `.entry`，否则 `pushCaptureLeafCall` catch recover。
- **所有权 / 错误 / 调用**：同 miss 族。调用：`pushWarmOutlineCaptureLeafAndEnter`。

### `pushBorrowedIteratorMiss` (`src/exec/tailcall_dispatch.zig:6990`)

- **签名**：`noinline fn pushBorrowedIteratorMiss(vm: *Vm, resolved: *const inline_calls.ResolvedInlineFunction, receiver: JSValue, method: JSValue, iterator_record: []JSValue, depth: u8) EmptyLeafMiss`。
- **作用**：borrowed-iterator 热 miss 的权威回退（first-use Entry、chunk 切换、heap、OOM、stack overflow）。分发臂已付调用者 Realm interrupt poll。热门意味着 `pushBorrowedIteratorNext` 会再证的 borrowed-simple 资格，其 moved fallback（null）在此不可达；仍保留权威 dup/move 臂，资格漂移时失败安全而不是跑未证明的帧形。
- **实现**：`resolved.bind(receiver, method)`。`pushBorrowedIteratorNext` catch `iteratorNextCallSetupRecover`。若返回 null：把 iterator_record 两槽拷到 `moved[2]`，`pushMovedCall(..., .method, .for_of_next, depth)` catch 同样 recover。
- **所有权 / 错误 / 调用**：borrowed 失败才 dup 进 moved 区。调用：`op_for_of_next` 的 `tryPushBorrowedIteratorNextFast` miss。

### `reloadTop` (`src/exec/tailcall_dispatch.zig:7044`)

- **签名**：`inline fn reloadTop(vm: *Vm, pc: *[*]const u8, sp: *[*]JSValue, var_buf: *[*]JSValue) void`。
- **作用**：从 Machine 当前层重载 pc/sp/var_buf 与分发表，供 Outcome 循环再入。
- **实现**：`machine.loadCurrentLevel` 把 frame/stack/catch_target 三个指针取回，然后逐项重建寄存器镜像：`var_refs_base = frame.var_refs.ptr`、`function = frame.function`、`publishPropSites(function)`（只把站点镜像失效）、`code_base = function.byteCode().ptr`；`local_fast_blocked = (machine.depth == 0 and machine.l0.stop_before_pc != null)`，据此把 `active_dispatch_tbl` 指向 `cold_table` 或 `dispatch_table`；最后 `pc = code_base + frame.pc`、`sp = stack.topPtr()`、`var_buf = frame.locals.ptr`。**刻意没有 `frame.pc += 1`**：旧的 `reloadInlineTopFrame` 读掉并消费了 resume opcode，而这里的 handler 自己读 `pc[0]`，所以 pc 必须正指着那条 resume 指令。
- **所有权 / 错误 / 调用**：错误：无。所有权：把当前层（Machine 顶层或 L0）的帧/栈/catch 指针重新装进 VM 寄存器，顺带换站点表、`code_base` 与分发表，并把 `pc`/`sp`/`var_buf` 三个出参重算——所有指针都借自 Entry/L0。调用：本文件 `:7139`、`:7161`（分发循环每次从续延回来时）。

### `reloadAfterPop` (`src/exec/tailcall_dispatch.zig:7062`)

- **签名**：`inline fn reloadAfterPop( vm: *Vm, caller_entry: ?*inline_calls.Entry, pc: *[*]const u8, sp: *[*]JSValue, var_buf: *[*]JSValue, ) void`。
- **作用**：拆帧后用 `Entry.prev`（或 L0）重载，避免按 depth 索引。
- **实现**：Debug/Safe 下有不变量断言。 关键调用：`vm.publishPropSites`；`caller_entry` 非空走 Entry 臂，null 走 L0 臂（只有 L0 的 stop 缝会把 `local_fast_blocked` / `active_dispatch_tbl` 重新置成冷表）。
- **所有权 / 错误 / 调用**：错误：无。所有权：pop 之后的定向恢复——`caller_entry` 非空时指向那个 Entry 的内嵌字段，为空时回到 `machine.l0.level`（并在 L0 带 `stop_before_pc` 时切到 `cold_table`）；同样重算 `pc`/`sp`/`var_buf`。调用：本文件 8 处返回臂，如 `:1561`、`:1627`、`:1770`、`:1836`。

### `runDispatchLoop` (`src/exec/tailcall_dispatch.zig:7104`)

- **签名**：`pub fn runDispatchLoop(vm: *Vm) HostError!void`。
- **作用**：Outcome 驱动循环：从当前 pc 尾分发直到返回/抛错/挂起。
- **实现**：发布 `var_refs_base`、按 L0 `stop_before_pc` 选择 `dispatch_table` 或 `cold_table`，再 `runDispatchLoopPublished`。循环：`next` 的 Outcome——`.returned` 在 depth==0 退出，否则 `driveReturnedContinuation`；`.threw` 抛 `pending_error`；`.tail` 走 `driveTailRequest`（push 或 `tailCallReuse`）；`.suspended`/`.native_returned` 退出；然后 `reloadTop` 再入。
- **所有权 / 错误 / 调用**：错误：`HostError`——由 `runDispatchLoopPublished` 上抛（即 `vm.pending_error` 的内容）。所有权：只装配三个寄存器字段（`var_refs_base`、`local_fast_blocked`、`active_dispatch_tbl`）后转调已发布版本；帧与栈都归 Machine。调用：唯一调用方 `src/exec/zjs_vm.zig:716`。

### `runDispatchLoopPublished` (`src/exec/tailcall_dispatch.zig:7115`)

- **签名**：`pub inline fn runDispatchLoopPublished(vm: *Vm, entry_pc: [*]const u8) HostError!void`。
- **作用**：prologue 事实已发布时的循环入口（native-boundary 刚 push 的 Entry）。
- **实现**：Debug 断言两张驻留尾表、`var_refs_base`、`local_fast_blocked` 与 `entry_pc` 都已按契约发布。随后 `pc/sp/var_buf` 取自寄存器，`while (true)` 里只留 Outcome switch：`.returned`（depth==0 直接返回，否则 `driveReturnedContinuation`，true 表示 native 边界）、`.threw` 返回 `pending_error`、`.tail` → `driveTailRequest`、`.suspended` / `.native_returned` 返回、`.reenter` 为 `unreachable`（冷被调者在 `vm_call.call` 里就完成了）；每轮末尾 `reloadTop` 再入。 关键调用：`next`、`driveReturnedContinuation`、`driveTailRequest`、`reloadTop`。
- **所有权 / 错误 / 调用**：错误：`HostError`——`.threw` 时 `return vm.pending_error`（哨兵转回 Zig error 的地方），`driveReturnedContinuation`/`driveTailRequest` 的错误直接 `try` 上抛。所有权：循环体自身不持有值；`.returned` 在 depth 为 0 时结束、否则驱动续延，`.tail` 走尾调用请求，`.suspended`/`.native_returned` 直接返回，`.reenter` 是 `unreachable`。每轮末 `reloadTop` 重新同步寄存器。调用：`src/exec/zjs_vm.zig:754`（宿主发布好入口 pc 后）与本文件 `:7110`。

### `driveReturnedContinuation` (`src/exec/tailcall_dispatch.zig:7146`)

- **签名**：`noinline fn driveReturnedContinuation(vm: *Vm) HostError!bool`。
- **作用**：depth>0 的 `.returned`：拆帧并跑 post-call continuation。true 表示 `.native_boundary`（值留在 `vm.return_value` 给驱动调用方）；false 则恢复调用者层。outline 避免 continuation 记录、IteratorClose、catch 恢复把每个驱动入口的 prologue 撑大约 25 条指令。
- **实现**：`popReturn(vm.return_value)`。`.next` 断言 payload==0 返回 false。`.native_boundary` 则 `storeValueAsIntPair` 返回 true。其余先 `reloadTop` 把调用者层发布出去，清空 `return_value`。`.async_complete`：`completeAsync` catch `callSetupRecover`，成功 push promise。`.proxy_get`：`completeProxyGetContinuation` + `takeAtom`。`.for_of_next`：`completeForOfNextContinuation` + `takeForOfDepth`。`.to_boolean`：`valueTruthy` 成 bool 压栈。`.native_boundary`/`.constructor`/`.next` 在此 `unreachable`。
- **所有权 / 错误 / 调用**：`popReturn` 接管 result。错误：`HostError` 经 recover 或直接传播。调用：`runDispatchLoopPublished` 的 `.returned` 且 depth>0。

### `driveTailRequest` (`src/exec/tailcall_dispatch.zig:7188`)

- **签名**：`noinline fn driveTailRequest(vm: *Vm) HostError!void`。
- **作用**：`.tail`：进入请求的帧（push，或 eval-tail / PTC 复用）。返回时 Machine 当前层就是要恢复的帧；尾调用者抓住的错误在返回前投递给该调用者。
- **实现**：就地读 `vm.tail_request`，不拷贝 target。先 `pollInterrupt`（qjs 在 JS_CallInternal 入口、栈守卫和调用者帧改写之前）。按 `tail_mode` 决定 reuse：`.push` 永不 reuse；`.reuse_chain`（eval-tail）除了「depth>0 且当前帧是 constructor 完成或 `.async_complete`」这一种情况以外都 reuse（源码写成 `!(depth > 0 and (completesConstructor or async_complete))`）；`.reuse_release`（严格 PTC）还要求无活 catch、有真实 machine 帧。reuse 则 `tailCallReuse(..., .release|.chain)` catch：`callSetupRecover` 成功 return，否则 `pending_error`。非 reuse：`stack.setLen(region_base)`，`pushCall` catch：`closeStackTopForOfIteratorForPendingError`，`handleCatchableRuntimeError` 抓住则 return，否则传播 err。
- **所有权 / 错误 / 调用**：reuse 失败时尾调用者仍是 current，其 catch 看见错误（对齐 qjs OP_tail_call）。错误：`HostError`。调用：`runDispatchLoopPublished` 的 `.tail`。

### `op_using` (`src/exec/tailcall_dispatch.zig:7250`)

- **签名**：`pub fn op_using(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_ext0 的热 handler：按子码 `pc[1]` 直接 `always_tail` 进三个类型测试尾叶（is_undefined / typeof_is_undefined / typeof_is_function），其余 ext0 子码走冷表。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：视 ext0 子码；类型测试 0（改写栈顶布尔）。 下一跳：未命中：`@call(.always_tail, cold_table[pc[0]], …)` 进全冷表。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。`op.ext0`（244）按 `pc[1]` 的 sub 字节三分：`is_undefined`/`typeof_is_undefined`/`typeof_is_function` 各自 PC-relative 直跳对应尾叶，ERM（真正的 `using`/`await using`）子码落 `cold_table[pc[0]]` 的冷 using 壳。 所有权：本体不碰栈。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:956`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_using_is_undefined` (`src/exec/tailcall_dispatch.zig:7261`)

- **签名**：`pub fn op_using_is_undefined(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_ext0 `is_undefined` 子码的尾叶（由 `op_using` 尾跳进入）：改写栈顶布尔后 `cont`。
- **实现**：`value = (sp-1)[0]`，`is(.undefined_value)` 真假两臂各自把 `sp[-1]` 覆盖成布尔再 `cont(pc + 2, sp, …)`（`ext0` 是两字节：opcode + sub）。 栈效应：0，pc 前进 2 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_using` 按 ext0 子码 `@call(.always_tail)` 进入。

### `op_using_typeof_is_undefined` (`src/exec/tailcall_dispatch.zig:7271`)

- **签名**：`pub fn op_using_typeof_is_undefined(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_ext0 `typeof_is_undefined` 子码的尾叶（由 `op_using` 尾跳进入）。
- **实现**：`yes = value.is(.undefined_value) or value_ops.isHTMLDDA(value)`——`typeof x === "undefined"` 必须把 document.all 这类 HTMLDDA 也算进去；把结果覆盖 `sp[-1]` 后 `cont(pc + 2, sp, …)`。 栈效应：0，pc 前进 2 字节。 下一跳：`cont`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_using` 按 ext0 子码 `@call(.always_tail)` 进入。

### `op_using_typeof_is_function` (`src/exec/tailcall_dispatch.zig:7278`)

- **签名**：`pub fn op_using_typeof_is_function(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_ext0 `typeof_is_function` 子码的尾叶（由 `op_using` 尾跳进入）：publish 后跑 `vm_value.typeOfIsFunction`，再 `coldNext`。
- **实现**：`publish(pc, sp)` 之后**再手动 `vm.frame.pc += 1` 跳过 sub 字节**（publish 只把 `frame.pc` 停在 sub 上，这样 `coldNext` 才从下一条 opcode 续跑，与 `using_ops.execVm` 一致），然后 `vm_value.typeOfIsFunction(vm.ctx.runtime, vm.stack) catch |e| return vm.fail(e)`，最后 `coldNext(var_buf, vm)`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error，写 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 调用：`op_using` 按 ext0 子码 `@call(.always_tail)` 进入。

### `op_get_field_field2` (`src/exec/tailcall_dispatch.zig:7288`)

- **签名**：`pub fn op_get_field_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_field_field2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 关键调用：`object_ops.objectFromValueTrustedExpression`、`vm_property_field.siteCapturable`、`vm_property_field.getFieldFastSlotOrAbsent`、`vm_property_field.ordinaryAccessorGetterAfterOwnMiss`、`builtin_dispatch.nativeAccessorTarget`、`builtin_dispatch.callNativeAccessorTarget`、`call_runtime.handleCatchableRuntimeError`、`vm_property_field.isTypedArrayPayloadAtomForFastPath`。 栈效应：寄存器 `sp` 净效应 0，pc 前进 6 字节。 下一跳：热成功：`cont` / `next` 尾分发到 `dispatch_table[npc[0]]`；冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；属性尾：`property_tail_tbl[slot]`；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：`vm.fail` 用于该 handler 自己的失败边；属性未命中转 `propertyTailHandler`。 所有权：`get_field` 的结果留在栈上直接喂给融合的 `get_field2` 段（保留 receiver 形态）。 下一跳：命中臂在函数内部继续做第二次取字段，未命中转属性尾或 `coldNext`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:953`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_field_field2_cold` (`src/exec/tailcall_dispatch.zig:7347`)

- **签名**：`pub fn op_get_field_field2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_field_field2 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_field.field`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_field.field`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:567/802` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_field_field2` 覆盖（:953）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_get_var_field` (`src/exec/tailcall_dispatch.zig:7354`)

- **签名**：`pub fn op_get_var_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_var_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：从 var-ref cell 读借用副本压栈；cell 未初始化时**直接 PC-relative 尾跳 `op_get_var_field_cold`**（`:7361`，不经 `cold_table`），命中时直跳 `op_get_field`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:954`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_var_field_cold` (`src/exec/tailcall_dispatch.zig:7371`)

- **签名**：`pub fn op_get_var_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_var_field 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_globals.getVar`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：先试内联的全局对象自有数据探针 `getVarGlobalOwnDataInline`，命中就压值并**直接尾跳 `op_get_field`**（不经表）；未命中才 `publish` + `vm_property_globals.getVar(...) catch |e| return vm.fail(e)` + `coldNext`。 所有权：探针命中的值是全局属性槽的借用副本。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:555/803` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_var_field` 覆盖（:954）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 除表载路径外，`op_get_var_field` 在 cell 未初始化时还会直接 PC-relative 尾跳进来（`:7361`）。

### `op_get_loc2_field2` (`src/exec/tailcall_dispatch.zig:7383`)

- **签名**：`pub fn op_get_loc2_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc2_field2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`sp[0] = var_buf[2]` 后交给 `op_get_field2`（保留 receiver 的取字段形态）。 下一跳**不过表**：`@call(.always_tail, `op_get_field2`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:952`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc2_field2_cold` (`src/exec/tailcall_dispatch.zig:7388`)

- **签名**：`pub fn op_get_loc2_field2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc2_field2 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:556/801` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc2_field2` 覆盖（:952）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_push_0_or` (`src/exec/tailcall_dispatch.zig:7395`)

- **签名**：`pub fn op_push_0_or(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_0_or 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：+1。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：压一个 int32 `0` 后把 `pc+1`/`sp+1` 交给 `opBinary(.bor)` 的实例。 下一跳**不过表**：`@call(.always_tail, `opBinary(.bor)`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:960`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_0_or_cold` (`src/exec/tailcall_dispatch.zig:7404`)

- **签名**：`pub fn op_push_0_or_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_0_or 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：+1。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）。
- **所有权 / 错误 / 调用**：错误：本体不产生错误——它 `publish` 后自己压 int32 `0`、`setTopPtr(sp+1)`，然后 `coldNext`（唯一的错误边是 `coldNext` 自己的 `InvalidBytecode`）。 所有权：立即数是非引用计数裸值。这里**没有**额外的 `frame.pc += 1`：`push_0_or` 是 1 字节（`.fmt = .none`）、残留的 `or` 就在 `pc+1`，而 `publish` 写回的 `frame.pc`（「操作数游标」）已经等于 `pc+1`，再 `+1` 会跳过 `or`、把压进去的 `0` 永久留在操作数栈上。原来多写的那一条已删（同族 1 字节的 `op_push_0_shr_cold` 从来就没有它；2 字节的 `op_push_i8_add_cold` 才需要，它要跨过自己的 `i8` 操作数）。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:809` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_push_0_or` 覆盖（:960）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_sar_get_array_el` (`src/exec/tailcall_dispatch.zig:7412`)

- **签名**：`pub fn op_sar_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_sar_get_array_el 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：-1（对象+下标 → 值）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：双整数 `sar` 就地写 `sp[-2]` 后弹 rhs，再直跳 `op_get_array_el`；整数对未命中时**直接 PC-relative 尾跳 `op_sar_get_array_el_cold`**，不经 `cold_table[pc[0]]`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:961`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_sar_get_array_el_cold` (`src/exec/tailcall_dispatch.zig:7419`)

- **签名**：`pub fn op_sar_get_array_el_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_sar_get_array_el 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_arith.binaryVm`、`publish`、`coldNext`。 栈效应：与对应热 handler 相同；先 `publish` 再走 outlined helper，helper 改 `stack.top_ptr`。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_arith.binaryVm`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:810` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_sar_get_array_el` 覆盖（:961）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 除表载路径外，快臂在整数对未命中时会**直接**尾跳进来（`:7412`）。

### `op_push_2_sar` (`src/exec/tailcall_dispatch.zig:7428`)

- **签名**：`pub fn op_push_2_sar(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_2_sar 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：+1。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：压 int32 `2` 后按 `pc[1]` 二选一：残留字节若已被再融合成 `sar_get_array_el` 就尾跳 `op_sar_get_array_el`（绝不能拿融合后的 `pc[0]` 去进原始 `sar`，否则 B-miss 会经 `cold_table[fused]` 把 A 再付一遍），否则尾跳 `opBinary(.sar)` 的实例。 下一跳**不过表**：`@call(.always_tail, 残留 `sar` 的 handler, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:962`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_2_sar_cold` (`src/exec/tailcall_dispatch.zig:7437`)

- **签名**：`pub fn op_push_2_sar_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_2_sar 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：+1。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）。
- **所有权 / 错误 / 调用**：错误：本体不产生错误（publish + 压 int32 `2` + `coldNext`）。所有权：同 `op_push_0_or_cold`——同样是 1 字节 opcode，同样删掉了会跳过残留 `sar` 的那条 `frame.pc += 1`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:811` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_push_2_sar` 覆盖（:962）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `tailPush2` (`src/exec/tailcall_dispatch.zig:7452`)

- **签名**：`inline fn tailPush2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：超指令 `get_loc8_push_*` 的后半分发：按 `pc[2]` 这一字节把后续那条 push 系 opcode 直接 `always_tail` 到对应 handler（`op_push_small` / `op_push_2_sar` / `op_push_0_shr` / `op_push_0_or`），pc 已前进 2 字节。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯尾跳分派——按 `pc[2]` 的后继 opcode 选融合 handler（`push_2_sar`/`push_0_shr`/`push_0_or`），否则回 `op_push_small`；不碰栈所有权。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:7464`。

### `op_get_loc8_push_2` (`src/exec/tailcall_dispatch.zig:7465`)

- **签名**：`pub fn op_get_loc8_push_2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：`sp[0] = var_buf[pc[1]]` 之后 `tailPush2(pc, sp + 1, …)`，由后者按第二个字节 `b` 尾跳 `op_push_small` / `op_push_2_sar` / `op_push_0_shr` / `op_push_0_or`。 栈效应：+1（读 loc8）后由被尾跳的 handler 继续。 下一跳：`@call(.always_tail, …)` 到具名 Handler。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`sp[0] = var_buf[pc[1]]` 后交给 `tailPush2`，由它按残留字节再选 `push_2_sar`/`push_0_shr`/`push_0_or`/`op_push_small`。 下一跳**不过表**：`@call(.always_tail, `tailPush2`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:963`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc8_push_2_cold` (`src/exec/tailcall_dispatch.zig:7470`)

- **签名**：`pub fn op_get_loc8_push_2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_2 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:812` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc8_push_2` 覆盖（:963）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 只做 `get_loc8` 一半，`coldNext` 到残留的 `push_2`。

### `op_push_0_shr` (`src/exec/tailcall_dispatch.zig:7477`)

- **签名**：`pub fn op_push_0_shr(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_0_shr 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：+1。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：压 int32 `0` 后交给 `opBinary(.shr)` 的实例。 下一跳**不过表**：`@call(.always_tail, `opBinary(.shr)`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:964`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_0_shr_cold` (`src/exec/tailcall_dispatch.zig:7482`)

- **签名**：`pub fn op_push_0_shr_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_0_shr 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：+1。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）。
- **所有权 / 错误 / 调用**：错误：本体不产生错误（publish + 压 int32 `0` + `setTopPtr(sp+1)` + `coldNext`）。注意它**没有** `frame.pc += 1`，而编码完全同构的 `op_push_0_or_cold`/`op_push_2_sar_cold` 有——见报告的源码侧疑点。所有权：立即数裸值。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:813` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_push_0_shr` 覆盖（:964）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_get_loc8_push_1` (`src/exec/tailcall_dispatch.zig:7490`)

- **签名**：`pub fn op_get_loc8_push_1(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_1 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`sp[0] = var_buf[pc[1]]` 后交给 `op_push_small`。 下一跳**不过表**：`@call(.always_tail, `op_push_small`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:965`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc8_push_1_cold` (`src/exec/tailcall_dispatch.zig:7495`)

- **签名**：`pub fn op_get_loc8_push_1_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_1 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:814` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc8_push_1` 覆盖（:965）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `tailGetLoc8` (`src/exec/tailcall_dispatch.zig:7504`)

- **签名**：`inline fn tailGetLoc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome`。
- **作用**：剩余 `get_loc8` 的分发口：按 `pc[0]` 选已融合的 `op_get_loc8_push_2` / `push_1` / `push_i8`，都不是则退回 `opLoc(.get, .byte)`。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。
- **所有权 / 错误 / 调用**：错误：无。所有权：同族的融合分派——按 `pc[0]` 选 `get_loc8_push_2`（标记为 likely）、`get_loc8_push_1`、`get_loc8_push_i8`，否则回通用 `opLoc(.get, .byte)`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:7522`。

### `op_get_var_ref0_get_loc8` (`src/exec/tailcall_dispatch.zig:7518`)

- **签名**：`pub fn op_get_var_ref0_get_loc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_var_ref0_get_loc8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：Debug/Safe 下有不变量断言。 以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：读 `var_refs_base[0]` 这条 cell 的值压栈（借用副本）；cell 未初始化时**直接尾跳 `op_get_var_ref0_get_loc8_cold`**，否则进 `tailGetLoc8`——它按残留字节再选 `get_loc8_push_2`（约 106M 次里 95M）/`push_1`/`push_i8`/`opLoc(.get, .byte)`，热臂只花一次比较。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:966`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_var_ref0_get_loc8_cold` (`src/exec/tailcall_dispatch.zig:7528`)

- **签名**：`pub fn op_get_var_ref0_get_loc8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_var_ref0_get_loc8 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.varRefVm`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.varRefVm`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:815` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_var_ref0_get_loc8` 覆盖（:966）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。 除表载路径外，快臂在 cell 未初始化时直接尾跳进来（`:7520`）。

### `op_push_i8_add` (`src/exec/tailcall_dispatch.zig:7535`)

- **签名**：`pub fn op_push_i8_add(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_i8_add 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：-1（pop2 push1）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：按 i8 压立即数后交给 `opBinary(.add)` 的实例。 下一跳**不过表**：`@call(.always_tail, `opBinary(.add)`, …)` 是同文件 PC-relative 直跳，残留的 B 仍留在字节码流里，所以 B 看到的还是它自己的 opcode（throw/pc/冷路径因此都正确）。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:967`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_push_i8_add_cold` (`src/exec/tailcall_dispatch.zig:7540`)

- **签名**：`pub fn op_push_i8_add_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_push_i8_add 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`publish`、`coldNext`。 栈效应：+1。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）。
- **所有权 / 错误 / 调用**：错误：本体不产生错误（publish + 按 i8 压立即数 + `setTopPtr` + `frame.pc += 1` + `coldNext`）。所有权：立即数裸值。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:816` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_push_i8_add` 覆盖（:967）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。

### `op_get_loc8_push_i8` (`src/exec/tailcall_dispatch.zig:7549`)

- **签名**：`pub fn op_get_loc8_push_i8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_i8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：以 `@call(.always_tail, …)` 保持 Handler 四寄存器 ABI，本帧不再普通 `bl`。 栈效应：+1 压 int32（1 字节立即数）。 下一跳：尾跳到具名 Handler / 表槽。
- **所有权 / 错误 / 调用**：错误：本体不产生错误。所有权：`sp[0] = var_buf[pc[1]]` 后按 `pc[2]` 二分：残留已被融合成 `push_i8_add` 就直跳那一份，否则直跳 `op_push_i8`。调用：只装在 `dispatch_table`（`tailcall_dispatch_colds.zig:968`，在 `if (!fast) return`（:818）之后），经 `cont`/`next` 的表载尾调用进入；L0 `stop_before_pc` 期间 `active_dispatch_tbl` 是 `cold_table`，本 handler 不会被选中。

### `op_get_loc8_push_i8_cold` (`src/exec/tailcall_dispatch.zig:7556`)

- **签名**：`pub fn op_get_loc8_push_i8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome`。
- **作用**：OP_get_loc8_push_i8 的冷臂 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：先 `publish(pc,sp)` 把寄存器写回 Frame/Stack，outlined helper 才能看见活窗口。 关键调用：`vm_property_locals.loc`、`publish`、`coldNext`。 栈效应：读路径，通常 +1 或 0（视是否保留接收者）。 下一跳：冷续跑：`coldNext`（`maybeStop` 后走 `active_dispatch_tbl`）；异常：`Outcome.threw` / `vm.fail`。
- **所有权 / 错误 / 调用**：错误：不抛 Zig error——helper 的 `HostError` 经 `vm.fail(e)` 写进 `vm.pending_error` 并返回 `.threw`，由 `runDispatchLoop` raise。 所有权：`publish(pc, sp)` 之后堆上的 `Frame`/`Stack` 成为权威，值的所有权全归 `vm_property_locals.loc`。 调用：只装在 `cold_table`——`tailcall_dispatch_colds.zig:817` 在 `if (!fast) return`（:818）之前赋值，`dispatch_table` 的同一格随后被 `op_get_loc8_push_i8` 覆盖（:968）。进入路径是快臂 miss 的 `cold_table[pc[0]]` 间接尾调用，以及 L0 停机 seam 下 `next`/`coldNext` 直接选中。
## 覆盖核对

- 清单函数数: 288
- 本文标题覆盖: 288
- 未覆盖: 无
