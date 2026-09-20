# 11 — 尾分发冷表（`tailcall_dispatch_colds.zig`）

本文件**没有**自己的 `linksection` 字面量：每个 handler 经 `dispatch.coldStd` 的 wrapper 进 `.text.zjs.op_handlers` 岛。

`buildTable(s, fast)` 先把 256 槽填成冷 handler（共享 `h_loc`/`h_binary`/… 或一次性 `h(struct{fn b})`），再在 `fast=true` 时用 `dispatch.op_*` 覆盖热 opcode。`fast=false` 的表就是热路径 miss 的间接目标——编译器不能 devirtualize，热叶子才能保持无帧。

清单里大量函数名都是嵌套 `b`：那是 `coldStd`/`h()` 真正执行的 body。标题用 `h_varref.b` / `op.push_i32.b` 区分。包装函数 `h` 把「不看 pc 的 `fn(*Vm) !void`」收成仍接收 pc 的 Handler（忽略 pc）。

冷 handler 的统一栈协议：`coldStd` 先 `vm.publish(pc,sp)`，body 按 `vm.stack`/`vm.frame` 工作（helper 自己维护 top），然后 `coldNext` 从 `frame.pc` 重算 npc。因此下面「栈效应」描述的是 **opcode 语义**，寄存器 `sp` 在 publish 之后不再是权威。

下一跳一律：成功 `coldNext` → 先查 `frame.pc` 是否越过字节码末尾（越过即 `vm.fail(error.InvalidBytecode)`）→ `maybeStop`（只有 L0 且 `stop_before_pc` 非空时才真做事）→ `active_dispatch_tbl[npc[0]]`；body 失败 `vm.fail` → `.threw`。`vm.publish` 写回的 `frame.pc` 已经跨过 opcode 字节，读立即数的 helper 从那里继续推进。

两张表出自同一个 `buildTable`：`cold_table`（`buildTable(specials, false)`，tailcall_dispatch.zig:6918）是快臂 guard-miss 的 `cold_table[pc[0]]` 落点，也是 L0 `stop_before_pc` 时 `active_dispatch_tbl` 指向的整张表；`dispatch_table`（`buildTable(specials, true)`，:7013）在同样的冷槽上再被 fast 段覆盖。因此下面每条的「调用」写的是它在这两张表里实际占哪些槽——两表是本文件 handler 仅有的引用者，没有 dispatch 之外的调用方。

错误协议也分两层：带 `catch_target` 的 `*Vm` 助手先用 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）把可捕获错误交给本帧 catch（裁栈、压异常值、改 `frame.pc`，返回 `.continue_loop`，外壳照常 `coldNext`）；只有没人接的错误才逃到外壳的 `catch |e| return vm.fail(e)`，成为 `vm.pending_error` + `.threw`，由 `runDispatchLoopPublished`（:7133）抛回 `runTC`。所有权侧全族一致：值由 GC 追踪、栈槽即根，去 rc 之后 `push`/`pushOwned` 已经同义（stack.zig:214-236），个别会分配/建 `ValueRootFrame` 的条目在各自段里写明。

`keep[0..11]` 是 fusion 收回的旧 type-test/dup/rot 槽的 coldStd 叶子：它们不进任何 opcode 槽，按源码注释的意图写进 `BuiltTable.keep` 以防 LLVM DCE、好让岛内后续偏移与历史提交一致——但 `keep` 字段并没有运行期读者，`tailcall_dispatch.zig:6918` 与 `:7013` 两处都只取 `.table`。

## 函数

### `h_varref.b` (`src/exec/tailcall_dispatch_colds.zig:44`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_varref` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_locals.varRefVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_locals.varRefVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：全部 18 个 var_ref 槽（get/put/set_var_ref 及其编号变体，装表 :267）；`dispatch_table` 侧：只剩 `op.put_var_ref_check_init` 一槽，其余 17 个在 :988-1007 被 `dispatch.opGetVarRef`/`opPutVarRef`/`opSetVarRef`/`op_put_var_ref_check` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。

### `h_checkedloc.b` (`src/exec/tailcall_dispatch_colds.zig:49`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_checkedloc` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_locals.checkedLocVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_locals.checkedLocVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：get_loc_check/get_loc_checkthis/put_loc_check/set_loc_check/put_loc_check_init/set_loc_uninitialized 六槽（:268）；`dispatch_table` 侧：只剩 `op.get_loc_checkthis`，另五槽在 :855-860 被 `dispatch.opLocCheck`/`op_set_loc_uninitialized`/`op_put_loc_check_init` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。

### `h_loc.b` (`src/exec/tailcall_dispatch_colds.zig:54`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_loc` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_locals.loc`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 助手 `vm_property_locals.loc` 不带 catch_target，错误直接外传。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 全部 18 个 get/put/set_loc 变体 槽（装表本文件 :264）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.opLoc(...)` 覆盖（:831-848）。

### `h_arg.b` (`src/exec/tailcall_dispatch_colds.zig:59`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_arg` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_locals.arg`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 助手 `vm_property_locals.arg` 不带 catch_target，错误直接外传。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 get_arg/put_arg/set_arg 及 put_arg0-3、set_arg0-3 共 11 个 槽（装表本文件 :266）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_get_arg/opArgStore` 覆盖（:868-878）。

### `h_get_arg_short.b` (`src/exec/tailcall_dispatch_colds.zig:64`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_get_arg_short` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`slot_ops.execGetArg`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.get_arg0`-`get_arg3` 四槽 槽（装表本文件 :265）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_get_argN_fast` 覆盖（:869-872）。

### `h_binary.b` (`src/exec/tailcall_dispatch_colds.zig:69`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_binary` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_arith.binaryVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_arith.binaryVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：只剩 add/sub/mul/pow 四槽——同在冷段里，div/mod 于 :293-294 改指 `dispatch.op_div_cold`/`op_mod_cold`，六个位运算/移位于 :298 改指 `dispatch.opLogicCold`（原始装表 :292）；`dispatch_table` 侧：只剩 `op.pow`（qjs OP_pow 同样没有快臂），add/sub/mul 在 :886-888 被 `dispatch.opBinary` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。

### `h_unary.b` (`src/exec/tailcall_dispatch_colds.zig:74`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_unary` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_arith.unaryVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_arith.unaryVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：neg/to_number/inc/dec 四槽（:304）；`dispatch_table` 侧：只剩 `op.to_number`，另三槽在 :904-905 被 `dispatch.op_neg`/`op_inc_dec` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。

### `h_field.b` (`src/exec/tailcall_dispatch_colds.zig:79`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_field` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_field.field`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_field.field` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.get_field`/`get_field2`/`put_field` 三槽 槽（装表本文件 :423）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_get_field/op_get_field2/op_put_field` 覆盖（:949/957/958）。

### `h_get_array_element.b` (`src/exec/tailcall_dispatch_colds.zig:84`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_get_array_element` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_field.getArrayElement`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 助手在 vm_property_field.zig:1070 用 `PoppedWindow(2)` 建 `ValueRootFrame`，把弹出栈的 receiver/key 在可触发 GC 的 intern/查表期间挂成根。 错误：`vm_property_field.getArrayElement` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：get_array_el/get_array_el2/get_array_el3 三槽（:439）；`dispatch_table` 侧：只剩 `op.get_array_el3`，另两槽在 :959/969 被 `dispatch.op_get_array_el`/`op_get_array_el2` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。

### `h_put_array_element.b` (`src/exec/tailcall_dispatch_colds.zig:89`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_put_array_element` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_field.putArrayElementAfterFastMiss`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 助手在 vm_property_field.zig:990 用 `PoppedWindow(3)` 建 `ValueRootFrame` 保护弹出的 target/key/value。 错误：`vm_property_field.putArrayElementAfterFastMiss` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.put_array_el` 一槽 槽（装表本文件 :440）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_put_array_el` 覆盖（:970）。

### `h_get_var.b` (`src/exec/tailcall_dispatch_colds.zig:95`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_get_var` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_globals.getVar`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_globals.getVar` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.get_var`/`get_var_undef` 两槽 槽（装表本文件 :401-402）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_get_var` 覆盖（:983-984）。

### `h_put_var.b` (`src/exec/tailcall_dispatch_colds.zig:104`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_put_var` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_globals.putVar`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_globals.putVar` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.put_var` 一槽（同时是 `dispatch.op_put_var` 的 miss 续行） 槽（装表本文件 :403）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_put_var` 覆盖（:985）。

### `h_dyn_env_probe.b` (`src/exec/tailcall_dispatch_colds.zig:110`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_dyn_env_probe` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_ref.dynEnvProbe`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_ref.dynEnvProbe 的 dynEnvProbeAccess/dynEnvProbeStore 分支` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.dyn_env_probe` 槽（:420，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `h_make_slot_ref.b` (`src/exec/tailcall_dispatch_colds.zig:116`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_make_slot_ref` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_ref.makeSlotRef`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`frame.captureLocal`/`captureArg` 可新建 `VarRef` cell、`ensureVarRefsCapacity` 可扩 var_refs 数组，`atoms.toStringValue` 取键的串值——都可能触发 GC。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 助手不带 catch_target，`InvalidBytecode` 等直接外传。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.make_loc_ref`/`make_arg_ref`/`make_var_ref_ref` 槽（:404，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `h_define_class.b` (`src/exec/tailcall_dispatch_colds.zig:121`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_define_class` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`object_ops.defineClass`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配并建根：`object_ops.defineClass`（object_ops.zig:4125）新建构造器/原型对象，并用 `rootValues` 建 `ValueRootFrame` 护住弹出的类要素。 错误：`object_ops.defineClass` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.define_class`/`define_class_computed` 槽（:483-484，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `h_for_of_start.b` (`src/exec/tailcall_dispatch_colds.zig:126`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`h_for_of_start` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`iterator_ops.forOfStartVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会取迭代器并可能跑用户 `Symbol.iterator`/`next`，期间分配、可再入 JS。 错误：`iterator_ops.forOfStartVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.for_of_start`/`for_await_of_start` 槽（:726-727，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `h_for_of_start.h` (`src/exec/tailcall_dispatch_colds.zig:132`)

- **签名**：`fn h(comptime body: fn (vm: *Vm) HostError!void) Handler`。
- **作用**：本文件的包装器（标题里的 `h_for_of_start.` 前缀只是清单按上一处 `pub const` 起的限定名）：把「不看 `pc` 的 `fn(*Vm) !void`」收成一个仍接收 `pc` 的 `coldStd` Handler。
- **实现**：`return coldStd(struct { fn b(vm, pc) { _ = pc; try body(vm); } }.b)`——comptime 展开，每个 `h(...)` 调用点生成一个独立 Handler 函数。
- **所有权 / 错误 / 调用**：错误：`HostError` 原样从 body 传给 `coldStd` 外壳（它转成 `vm.fail` → `.threw`）。 调用：`buildTable` 在建表时按 opcode 逐个实例化。

### `h_for_of_start.b` (`src/exec/tailcall_dispatch_colds.zig:134`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：包装器 `h` 内部的桥接 body：丢掉 `pc`，转调调用方给的 `fn(*Vm) !void`。
- **实现**：`_ = pc; try body(vm);`——不自己碰栈也不尾分发；publish / `coldNext` 都由外层 `coldStd` 负责。
- **所有权 / 错误 / 调用**：错误：`HostError`；`coldStd` 外壳把它变成 `.threw`。 调用：由 `dispatch_table`/`cold_table`/`cont`/`next` 尾调用进入其外壳。

### `buildTable` (`src/exec/tailcall_dispatch_colds.zig:178`)

- **签名**：`pub fn buildTable(s: SpecialHandlers, comptime fast: bool) BuiltTable`。
- **作用**：组装 256 槽冷表，并在 `fast=true` 时用热 handler 覆盖。
- **实现**：先把 256 槽和 `keep` 的 12 槽全填成 `s.op_invalid`（未分配/被隔离的字节一律落到 invalid handler）；再按组填冷 handler：一次性 body 用 `h(...)`/`coldStd(...)` 就地生成（`vm_value.pushInt32Operand`、`vm_value.pushConst`、`vm_regexp.pushLiteral` 等），locals/args/var_refs/checked 这些成组的 opcode 用 `inline for` 指向共享的 `h_loc`/`h_arg`/`h_get_arg_short`/`h_varref`/`h_checkedloc`，带 opcode 立即数的用 `handlerCompare*`/`handlerPost`/`handlerAppend`/`handlerPutVarInit` 工厂（`in`/`post_inc`/`append`/`put_var_init` 原先各有一条把 opcode 立即数传成 `undefined`、随后立刻被工厂结果覆盖的死赋值，已删）；调用/返回/throw/yield/await 这些由主文件传进来的 `SpecialHandlers` 直接装；fusion 收回的旧槽装进 `keep[0..11]`——**这 12 个不是可达分发臂**，没有任何读者 index 它们，对应 opcode 现在走 `using_ops.execVm` 的 `ext0_sub` 二级 switch；真正把 handler 保在 island 里的是这里的 comptime 实例化本身，不是 `BuiltTable.keep` 字段被读。融合 opcode 的 `dispatch.op_*_cold` 也在门之前装，两张表都有（`get_var_field`/`get_loc2_field2`/`get_field_field2` 原先在前段还各赋过一次同样的值，重复的那三条已删）。`if (!fast) return` 之后才用 `dispatch.op_*_fast` 覆盖热 opcode，最后返回 `.{ .table = t, .keep = keep }`。
- **所有权 / 错误 / 调用**：错误：无——全程 comptime 求值的纯建表函数，没有失败路径。 调用：`tailcall_dispatch.zig` 在 comptime 建两张表时各调一次——`buildTable(specials, false)` 出 `cold_table`（兼 `keep`），`buildTable(specials, true).table` 出 `dispatch_table`。

### `op.push_i32.b` (`src/exec/tailcall_dispatch_colds.zig:188`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_i32 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushInt32Operand`。 栈效应：+1 压 int32（4 字节立即数）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_i32` 槽（装表本文件 :179）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_i32` 覆盖（:823）。

### `op.push_bigint_i32.b` (`src/exec/tailcall_dispatch_colds.zig:193`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_bigint_i32 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushBigIntI32Operand`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.push_bigint_i32` 槽（:184，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.push_i16.b` (`src/exec/tailcall_dispatch_colds.zig:198`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_i16 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushI16Operand`。 栈效应：+1 压 int32（2 字节立即数）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_i16` 槽（装表本文件 :189）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_i16` 覆盖（:824）。

### `op.push_i8.b` (`src/exec/tailcall_dispatch_colds.zig:203`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_i8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushI8Operand`。 栈效应：+1 压 int32（1 字节立即数）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_i8` 槽（装表本文件 :194）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_i8` 覆盖（:825）。

### `op.push_const.b` (`src/exec/tailcall_dispatch_colds.zig:208`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：OP_push_const 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushConst`。 栈效应：+1 压常量池项。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 压的是常量池里的借用值（`function.constantAt`），不复制不分配。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 索引越界时助手直接 `error.TypeError`，无本帧 catch。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.push_const` 槽（装表本文件 :199）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_const` 覆盖（:826）。

### `op.push_const8.b` (`src/exec/tailcall_dispatch_colds.zig:213`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：OP_push_const8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushConst8`。 栈效应：+1 压 8 位常量池下标。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 同 `push_const`，压常量池借用值。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.push_const8` 槽（装表本文件 :204）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_const8` 覆盖（:827）。

### `op.private_symbol.b` (`src/exec/tailcall_dispatch_colds.zig:218`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_private_symbol 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushPrivateSymbol`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`stack.reserveAdditional(1)` 可能扩栈，`atoms.newSymbol` 新建 private symbol 并由 `takeSymbolValue` 交出所有权后压栈。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 模板原子缺失时 `error.InvalidAtom`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.private_symbol` 槽（:209，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.regexp.b` (`src/exec/tailcall_dispatch_colds.zig:223`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_regexp 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_regexp.pushLiteral`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`constructCompiledLiteralInRealm` 为该字面量新建 RegExp 对象。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.regexp` 槽（:214，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.fclosure.b` (`src/exec/tailcall_dispatch_colds.zig:228`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：OP_fclosure 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_call.closure`。 栈效应：+1 压闭包函数对象。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`array_ops.pushFunctionClosure` 新建闭包对象并捕获 var_refs（可触发 GC）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.fclosure` 与 `op.fclosure8`（:224 共用同一 Handler） 槽（装表本文件 :219）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.opFclosure` 覆盖（:866-867）。

### `op.undefined.b` (`src/exec/tailcall_dispatch_colds.zig:234`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_undefined 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushUndefined`。 栈效应：+1 压 undefined。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.undefined` 槽（装表本文件 :225）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_undefined_fast` 覆盖（:819）。

### `op.null.b` (`src/exec/tailcall_dispatch_colds.zig:239`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_null 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushNull`。 栈效应：+1 压 null。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.null` 槽（装表本文件 :230）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_null_fast` 覆盖（:820）。

### `op.push_false.b` (`src/exec/tailcall_dispatch_colds.zig:244`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_false 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushBoolean`。 栈效应：+1 压 false。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_false` 槽（装表本文件 :235）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_false_fast` 覆盖（:821）。

### `op.push_true.b` (`src/exec/tailcall_dispatch_colds.zig:249`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_true 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushBoolean`。 栈效应：+1 压 true。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_true` 槽（装表本文件 :240）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_true_fast` 覆盖（:822）。

### `family.push_7.b` (`src/exec/tailcall_dispatch_colds.zig:255`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`inline for` 出来的共享 body，一次给 `OP_push_minus1` 与 `OP_push_0`..`OP_push_7` 九个槽各生成一份（常量 `e.v` 是 comptime 烘焙进去的 -1..7）。
- **实现**：关键调用：`vm_value.pushSmallInt`。 栈效应：+1 压该小整数——`pushSmallInt` 就是一次纯 push（旧名 `pushSmallIntMaybeFuse`/`pushImmediateInt32MaybeFuse` 里的 fuse 从来不成立，vm_value.zig 注释：qjs 无 push+binop 运行期融合），已改名并删掉只为签名对齐的 `function`/`frame` 死参。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_minus1`…`op.push_7` 九槽（:245-251 的 inline for 为每个常量各实例化一份） 槽（装表本文件 :245-251）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_small` 覆盖（:828）。

### `op.push_atom_value.b` (`src/exec/tailcall_dispatch_colds.zig:261`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_atom_value 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushAtomValue`。 栈效应：+1 压 atom 字符串。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `atoms.toStringValue` 交出已 intern 的原子串值，不新建字符串。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_atom_value` 槽（装表本文件 :252）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_atom_value` 覆盖（:879）。

### `op.push_empty_string.b` (`src/exec/tailcall_dispatch_colds.zig:266`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_empty_string 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushEmptyString`。 栈效应：+1 压空串。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `runtime.emptyString()` 取 runtime 缓存的空串。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.push_empty_string` 槽（:257，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.set_name.b` (`src/exec/tailcall_dispatch_colds.zig:284`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：OP_set_name 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_field.setName`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `vm_property_field.setName` 在目标函数对象上定义 name 属性，可能扩 shape/存储。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 助手不带 catch_target，错误直接外传给外壳。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.set_name` 槽（:275，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.nip_catch.b` (`src/exec/tailcall_dispatch_colds.zig:291`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_nip_catch 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.nipCatch`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 特别：body 除了改栈，还会把 `nipCatch` 返回的 `.catch_target` 写回 `vm.catch_target.*`（恢复外层 catch 目标）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 栈里找不到 catch 标记时 `error.InvalidBytecode`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.nip_catch` 槽（:282，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.private_in.b` (`src/exec/tailcall_dispatch_colds.zig:316`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_private_in 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.privateInVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`object_ops.privateInVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.private_in` 槽（:312，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.not.b` (`src/exec/tailcall_dispatch_colds.zig:321`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_not 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_arith.bitNotVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_arith.bitNotVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.not` 槽（:317，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.lnot.b` (`src/exec/tailcall_dispatch_colds.zig:326`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_lnot 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.logicalNot`。 栈效应：0 栈顶改布尔。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `logicalNot` 只做真值测试后压布尔。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.lnot` 槽（装表本文件 :322）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_lnot` 覆盖（:943）。

### `op.goto.b` (`src/exec/tailcall_dispatch_colds.zig:346`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_goto 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.jump32`、`exception_ops.pollInterrupt`。 栈效应：0 无条件跳。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.goto` 槽（装表本文件 :347）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_goto` 覆盖（:929）。

### `op.goto16.b` (`src/exec/tailcall_dispatch_colds.zig:352`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_goto16 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.jump16`、`exception_ops.pollInterrupt`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.goto16` 槽（装表本文件 :353）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_goto16` 覆盖（:928）。

### `op.goto8.b` (`src/exec/tailcall_dispatch_colds.zig:358`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_goto8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.jump8`、`exception_ops.pollInterrupt`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.goto8` 槽（装表本文件 :359）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_goto8` 覆盖（:925）。

### `op.if_false.b` (`src/exec/tailcall_dispatch_colds.zig:364`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_if_false 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.branch32`、`exception_ops.pollInterrupt`。 栈效应：-1 条件跳。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.if_false` 槽（装表本文件 :365）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_if_false` 覆盖（:937）。

### `op.if_true.b` (`src/exec/tailcall_dispatch_colds.zig:370`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_if_true 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.branch32`、`exception_ops.pollInterrupt`。 栈效应：-1 条件跳。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.if_true` 槽（:371）——它是唯一没有快臂的条件跳转，fast 段只覆盖了 `if_false`/`if_false8`/`if_true8`，由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.if_false8.b` (`src/exec/tailcall_dispatch_colds.zig:376`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_if_false8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.branch8`、`exception_ops.pollInterrupt`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.if_false8` 槽（装表本文件 :377）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_if_false8` 覆盖（:930）。

### `op.if_true8.b` (`src/exec/tailcall_dispatch_colds.zig:382`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_if_true8 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.branch8`、`exception_ops.pollInterrupt`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 其中 `exception_ops.pollInterrupt` 的中断异常没有本帧 catch，直接成为 `.threw`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.if_true8` 槽（装表本文件 :383）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_if_true8` 覆盖（:933）。

### `op.gosub.b` (`src/exec/tailcall_dispatch_colds.zig:388`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_gosub 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.gosub`。 栈效应：+1——读 4 字节相对偏移，把返回 pc 当 int32 压栈（`OP_ret` 再弹回去），然后跳到目标。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 压的是 int32 返回地址，不分配。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.gosub` 槽（:389，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.ret.b` (`src/exec/tailcall_dispatch_colds.zig:393`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_ret 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.ret`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 弹出 int32 返回地址写回 `frame.pc`，不分配。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 地址非 int32/越界时 `error.InvalidBytecode`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.ret` 槽（:394，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.make_var_ref.b` (`src/exec/tailcall_dispatch_colds.zig:404`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_make_var_ref 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_ref.makeVarRefVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `makeVarRef` 会取 `atoms.toStringValue` 的键值并压两个槽。 错误：`vm_property_ref.makeVarRefVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.make_var_ref` 槽（:405，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.get_ref_value.b` (`src/exec/tailcall_dispatch_colds.zig:409`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_get_ref_value 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_ref.getRefValueVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_ref.getRefValueVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.get_ref_value` 槽（:410，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.put_ref_value.b` (`src/exec/tailcall_dispatch_colds.zig:414`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_put_ref_value 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_ref.putRefValueVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_ref.putRefValueVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.put_ref_value` 槽（:415，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.get_private_field.b` (`src/exec/tailcall_dispatch_colds.zig:423`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_get_private_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_private.getPrivateFieldVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_private.getPrivateFieldVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.get_private_field` 槽（:424，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.put_private_field.b` (`src/exec/tailcall_dispatch_colds.zig:428`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_put_private_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_private.putPrivateFieldVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_private.putPrivateFieldVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.put_private_field` 槽（:429，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.define_private_field.b` (`src/exec/tailcall_dispatch_colds.zig:433`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_define_private_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_private.definePrivateFieldVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 定义私有域会扩对象的私有存储。 错误：`vm_property_private.definePrivateFieldVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.define_private_field` 槽（:434，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.get_super.b` (`src/exec/tailcall_dispatch_colds.zig:440`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_get_super 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.getSuper`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 助手不带 catch_target（`object_ops.getSuper`），错误直接外传。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.get_super` 槽（:441，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.get_super_value.b` (`src/exec/tailcall_dispatch_colds.zig:445`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_get_super_value 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.getSuperValue`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 取 super 属性可跑用户 getter/Proxy，期间分配、可再入 JS。 错误：`object_ops.getSuperValue` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.get_super_value` 槽（:446，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.get_length.b` (`src/exec/tailcall_dispatch_colds.zig:450`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_get_length 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.getLength`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `length` 读取可跑用户 getter/Proxy。 错误：`vm_literal.getLength` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.get_length` 槽（装表本文件 :451）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_get_length` 覆盖（:971）。

### `op.object.b` (`src/exec/tailcall_dispatch_colds.zig:457`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.object`。 栈效应：+1 空对象。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`core.Object.create` 新建 `{}`（唯一失败模式是 OOM），可触发 GC。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.object` 槽（装表本文件 :458）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_object` 覆盖（:978）。

### `op.object_slots2.b` (`src/exec/tailcall_dispatch_colds.zig:462`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_object_slots2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.objectReserved2`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：`createPlainObjectReserved2` 新建带两个预留槽的对象。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.object_slots2` 槽（装表本文件 :463）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_object_slots2` 覆盖（:979）。

### `op.array_from.b` (`src/exec/tailcall_dispatch_colds.zig:467`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_array_from 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.arrayFrom`。 栈效应：把 n 个栈值收成数组（净 -n+1）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配两次：argc>8 时用 `rt.memory.alloc(JSValue, argc)` 开局部缓冲（`defer free`，确实在函数内释放），再 `constructLiteralWithPrototype` 建 dense 数组。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.array_from` 槽（装表本文件 :468）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_array_from` 覆盖（:981）。

### `op.define_field.b` (`src/exec/tailcall_dispatch_colds.zig:472`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_define_field 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.defineField`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `vm_literal.defineField` 用 `rootValues` 建 `ValueRootFrame` 护住弹出的值，属性定义可扩 shape/存储。 错误：`vm_literal.defineField` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.define_field` 槽（装表本文件 :473）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_define_field` 覆盖（:980）。

### `op.set_home_object.b` (`src/exec/tailcall_dispatch_colds.zig:477`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_set_home_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.setHomeObject`。 栈效应：0——只读栈顶两槽（方法对象、home 对象），两者都是对象时给方法装 home object，不压不弹。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 `object_ops.setHomeObject` 不带 catch_target，错误直接外传。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.set_home_object` 槽（:478，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.define_array_el.b` (`src/exec/tailcall_dispatch_colds.zig:484`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_define_array_el 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.defineArrayEl`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `vm_literal.defineArrayEl` 用 `rootValues` 把弹出的 value/index/array 三值挂成 `ValueRootFrame`（vm_literal.zig:241），期间可跑 `toPropertyKey`/定义属性并触发 GC。 错误：`vm_literal.defineArrayEl` 先自捕（经 vm_literal.zig:421 的 `handleLiteralRuntimeError` 转手）——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.define_array_el` 槽（:485，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.define_method.b` (`src/exec/tailcall_dispatch_colds.zig:489`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_define_method 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.defineMethod`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 在目标对象上定义方法，可扩 shape/存储。 错误：`object_ops.defineMethod` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.define_method` 槽（:490，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.define_method_computed.b` (`src/exec/tailcall_dispatch_colds.zig:494`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_define_method_computed 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.defineMethodComputed`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 计算键会跑 `toPropertyKey`（可再入用户代码）。 错误：`object_ops.defineMethodComputed` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.define_method_computed` 槽（:495，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.copy_data_properties.b` (`src/exec/tailcall_dispatch_colds.zig:500`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_copy_data_properties 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.copyDataProperties`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 这是全族里所有权最重的一条：body 自己读 mask 字节并 `vm.frame.pc += 1`（family 里唯一在 body 内推进 pc 的），`vm_literal.copyDataProperties` 再建一个三值 `ValueRootFrame`（vm_literal.zig:310）、每个拷贝值另建一个 `ValueRootFrame`（:387-390），并分配 `objectRestOwnKeys` 键表（`defer freeKeys`）与 `copy_flags` 布尔缓冲（`defer free`）；拷贝循环会跑用户 getter/Proxy trap，可再入 JS 并触发 GC。 错误：`vm_literal.copyDataProperties` 先自捕（经 vm_literal.zig:421 的 `handleLiteralRuntimeError` 转手）——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.copy_data_properties` 槽（:506，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.special_object.b` (`src/exec/tailcall_dispatch_colds.zig:508`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_special_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.specialObject`。 栈效应：吃掉 1 字节子码后 +1——按子码压 arguments 对象（0/1）、`current_function`（2）、`new.target`（3）、home object、`import.meta` 或新建的 var object，未知子码压 undefined。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：subtype 0/1 建 arguments 对象、import_meta 建 `import.meta`、var_object 建新对象；THIS_FUNC/new.target/home_object 只借用帧里的值。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.special_object` 槽（装表本文件 :519）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_special_object（只接 THIS_FUNC dup）` 覆盖（:880）。

### `op.ext0.b` (`src/exec/tailcall_dispatch_colds.zig:513`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_ext0 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`using_ops.execVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `using_ops.execVm` 是 ext0 载体的子分发，按载体字节再派给各 `*Vm` 助手（那些助手自带本帧 catch）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.ext0` 槽（装表本文件 :524）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_using` 覆盖（:956）。

### `op.rest.b` (`src/exec/tailcall_dispatch_colds.zig:518`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_rest 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_literal.rest`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：先 `stack.reserveAdditional(1)` 再 `constructLiteralWithPrototype` 把实参切片拷进一个新 dense 数组（注释明确要求分配与压栈之间不得再分配）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.rest` 槽（:529，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.typeof.b` (`src/exec/tailcall_dispatch_colds.zig:525`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_typeof 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.typeOf`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `typeOf` 压的是预定义原子的已 intern 串值（qjs 的 `JS_AtomToString` dup），不新建字符串。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.typeof` 槽（:536，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `keep[0].b` (`src/exec/tailcall_dispatch_colds.zig:535`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[0]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.typeOfIsUndefined`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[1].b` (`src/exec/tailcall_dispatch_colds.zig:540`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[1]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.typeOfIsFunction`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.is_undefined_or_null.b` (`src/exec/tailcall_dispatch_colds.zig:545`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_is_undefined_or_null 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.isUndefinedOrNull`。 栈效应：0——弹出栈顶，压回 `value.is(.undefined_value) or value.is(.null_value)` 的布尔。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.is_undefined_or_null` 槽（:557，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `keep[2].b` (`src/exec/tailcall_dispatch_colds.zig:550`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[2]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.isUndefined`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.is_null.b` (`src/exec/tailcall_dispatch_colds.zig:555`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_is_null 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.isNull`。 栈效应：0 栈顶改布尔。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.is_null` 槽（装表本文件 :568）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_is_null` 覆盖（:944）。

### `op.dup.b` (`src/exec/tailcall_dispatch_colds.zig:562`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：OP_dup 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.dup`。 栈效应：+1 复制栈顶。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.dup` 槽（装表本文件 :575）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_dup` 覆盖（:911）。

### `op.swap.b` (`src/exec/tailcall_dispatch_colds.zig:567`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_swap 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.swap`。 栈效应：0 交换栈顶两槽。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.swap` 槽（装表本文件 :580）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_swap` 覆盖（:919）。

### `op.nip.b` (`src/exec/tailcall_dispatch_colds.zig:572`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_nip 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.nip`。 栈效应：-1 丢掉次顶。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.nip` 槽（:585，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `keep[11].b` (`src/exec/tailcall_dispatch_colds.zig:577`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[11]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.dup1`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[6].b` (`src/exec/tailcall_dispatch_colds.zig:582`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[6]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.dup2`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[10].b` (`src/exec/tailcall_dispatch_colds.zig:587`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[10]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.dup3`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.insert2.b` (`src/exec/tailcall_dispatch_colds.zig:592`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_insert2 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.insert2`。 栈效应：0 把栈顶插入到 -2。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.insert2` 槽（装表本文件 :605）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_insert2` 覆盖（:916）。

### `op.insert3.b` (`src/exec/tailcall_dispatch_colds.zig:597`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_insert3 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.insert3`。 栈效应：0 把栈顶插入到 -3。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.insert3` 槽（装表本文件 :610）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_insert3` 覆盖（:917）。

### `keep[3].b` (`src/exec/tailcall_dispatch_colds.zig:602`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[3]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.insert4`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.rot3l.b` (`src/exec/tailcall_dispatch_colds.zig:607`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_rot3l 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.rot3l`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.rot3l` 槽（:620，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `keep[8].b` (`src/exec/tailcall_dispatch_colds.zig:612`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[8]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.rot3r`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[9].b` (`src/exec/tailcall_dispatch_colds.zig:617`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[9]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.rot4l`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[4].b` (`src/exec/tailcall_dispatch_colds.zig:622`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[4]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.rot5l`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.perm3.b` (`src/exec/tailcall_dispatch_colds.zig:627`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_perm3 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.perm3`。 栈效应：0 三槽置换。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.perm3` 槽（装表本文件 :640）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_perm3` 覆盖（:918）。

### `op.perm4.b` (`src/exec/tailcall_dispatch_colds.zig:632`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_perm4 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.perm4`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.perm4` 槽（:645，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `keep[5].b` (`src/exec/tailcall_dispatch_colds.zig:637`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[5]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.perm5`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `keep[7].b` (`src/exec/tailcall_dispatch_colds.zig:642`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：`keep[7]` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_value.swap2`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：族内外壳协议（`vm.fail` → `.threw`）在这里从不兑现——见下：没有分发进得来。 调用：**无**——不占任何 opcode 槽，只写进 `BuiltTable.keep`；而 `keep` 没有运行期读者（tailcall_dispatch.zig:6917-6918、7013 都只取 `.table`），既不被分发也不被数据引用，留着只为岛内偏移与历史提交对齐。

### `op.catch.b` (`src/exec/tailcall_dispatch_colds.zig:649`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_catch 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_control.catchTarget`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 特别：body 通过 `vm_control.catchTarget` 写 `vm.catch_target.*`（新目标）并把旧目标作为 `catchOffset` 标记压栈。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.catch` 槽（:662，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.check_ctor.b` (`src/exec/tailcall_dispatch_colds.zig:654`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_check_ctor 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_call.checkCtorVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_call.checkCtorVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.check_ctor` 槽（:667，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.init_ctor.b` (`src/exec/tailcall_dispatch_colds.zig:659`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_init_ctor 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_call.initCtorVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_call.initCtorVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.init_ctor` 槽（:672，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.check_brand.b` (`src/exec/tailcall_dispatch_colds.zig:664`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_check_brand 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.checkBrandVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`object_ops.checkBrandVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.check_brand` 槽（:677，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.add_brand.b` (`src/exec/tailcall_dispatch_colds.zig:669`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_add_brand 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`object_ops.addBrandVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 加 brand 会在对象上装私有品牌槽。 错误：`object_ops.addBrandVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.add_brand` 槽（:682，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.close_loc.b` (`src/exec/tailcall_dispatch_colds.zig:674`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_close_loc 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_locals.closeLoc`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `closeLoc` 只是把 local 的 open binding 关进已存在的 `VarRef` cell（`open_bindings.Table.close`，值搬家，不新分配）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.close_loc` 槽（:687，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.nop.b` (`src/exec/tailcall_dispatch_colds.zig:679`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_nop 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无——body 是空的（`_ = vm`），除外壳的 publish/coldNext 外什么都不做。 错误：实际不会失败——body 声明了 `HostError!void` 但里面只有 `_ = vm;`，没有任何 `try`，外壳的 `vm.fail` 路径在这里到不了。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.nop` 槽（:692，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.push_this.b` (`src/exec/tailcall_dispatch_colds.zig:684`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_push_this 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_value.pushThisVm`。 栈效应：+1 压 this。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `pushThisVm` 在 sloppy 模式下可能把 `this` 装箱（`materializeFrameThisBinding`，可分配）。 错误：`vm_value.pushThisVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），只装在 `cold_table` 的 `op.push_this` 槽（装表本文件 :697）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_push_this` 覆盖（:881）。

### `op.delete_var.b` (`src/exec/tailcall_dispatch_colds.zig:689`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_delete_var 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_ref.deleteVar`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 `vm_property_ref.deleteVar` 不带 catch_target，错误直接外传。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.delete_var` 槽（:702，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.delete.b` (`src/exec/tailcall_dispatch_colds.zig:694`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_delete 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_property_ref.deletePropertyVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 delete 可跑 Proxy deleteProperty trap，再入 JS。 错误：`vm_property_ref.deletePropertyVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.delete` 槽（:707，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.apply_eval.b` (`src/exec/tailcall_dispatch_colds.zig:701`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_apply_eval 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_eval_module.applyEval`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 直接 eval 会编译并执行新函数体：分配 FunctionBytecode/帧、递归再入 VM（`eval_ops.execApplyEval`，其中自带本帧 catch）。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.apply_eval` 槽（:714，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.import.b` (`src/exec/tailcall_dispatch_colds.zig:706`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_import 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`vm_eval_module.dynamicImport`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 会分配：新建 Promise 并挂模块加载续行。 错误：body 的 `HostError` 由外壳 `catch |e| return vm.fail(e)`（tailcall_dispatch.zig:600-608）写进 `vm.pending_error` 并返回 `.threw`，驱动循环 `runDispatchLoopPublished`（:7133）再把它抛回 `runTC`。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.import` 槽（:719，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.for_in_start.b` (`src/exec/tailcall_dispatch_colds.zig:715`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_for_in_start 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.forInStartVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 for-in 不走迭代协议：`forof_ops.createForInIterator`（forof_ops.zig:59）新建一个 `for_in_iterator` 内部对象并快照目标的自有字符串键，不调用用户 `next`/`return`；对象/原型侧的 Proxy trap 可再入 JS，键快照的分配可触发 GC。 错误：`iterator_ops.forInStartVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.for_in_start` 槽（:728，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.iterator_next.b` (`src/exec/tailcall_dispatch_colds.zig:720`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_iterator_next 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.iteratorNextVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 迭代器操作会跑用户 `next`/`return` 方法并新建 result 对象：分配、可再入 JS、可触发 GC。 错误：`iterator_ops.iteratorNextVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.iterator_next` 槽（:733，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.iterator_check_object.b` (`src/exec/tailcall_dispatch_colds.zig:725`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_iterator_check_object 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.iteratorCheckObjectVm`。 栈效应：0——只 peek 栈顶，不是对象就抛 TypeError（可被 `handleCatchableRuntimeError` 就地捕获）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`iterator_ops.iteratorCheckObjectVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.iterator_check_object` 槽（:738，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.iterator_get_value_done.b` (`src/exec/tailcall_dispatch_colds.zig:730`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_iterator_get_value_done 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.iteratorGetValueDoneVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 本条不调迭代器方法、也不新建 result 对象：`iteratorGetValueDone`（iterator_ops.zig:398）只从栈上的 result 对象读 `done`/`value` 两个属性（用户 getter/Proxy 可再入 JS、可触发 GC），把 catch 标记换成 async 标记后压回 value 与 done 布尔。 错误：`iterator_ops.iteratorGetValueDoneVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.iterator_get_value_done` 槽（:743，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.iterator_call.b` (`src/exec/tailcall_dispatch_colds.zig:735`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_iterator_call 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.iteratorCallVm`。 栈效应：读 1 字节 flags（bit0 选 `throw`/`return`，bit1 决定是否带实参），要求栈上至少 4 槽；迭代器没有该方法时压 `true`（+1）；否则调用后把栈顶实参换成结果再压 `false`（净 +1）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 迭代器操作会跑用户 `next`/`return` 方法并新建 result 对象：分配、可再入 JS、可触发 GC。 错误：`iterator_ops.iteratorCallVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.iterator_call` 槽（:748，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.for_await_of_next.b` (`src/exec/tailcall_dispatch_colds.zig:741`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_for_await_of_next 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.forAwaitOfNextVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 迭代器操作会跑用户 `next`/`return` 方法并新建 result 对象：分配、可再入 JS、可触发 GC。 错误：`iterator_ops.forAwaitOfNextVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.for_await_of_next` 槽（:754，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.for_in_next.b` (`src/exec/tailcall_dispatch_colds.zig:746`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_for_in_next 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.forInNextVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 for-in 不走迭代协议：`iterator_ops.forInNext`（iterator_ops.zig:844）按快照逐个吐键，一段用完就沿原型链取下一段快照（`forInSnapshotOwnStringKeys`），不调用用户 `next`/`return`；`objectGetPrototypeOfValue`/`proxyAwareExistsOwnProperty` 会跑 Proxy trap，可再入 JS，快照数组与原子表的分配可触发 GC。 错误：`iterator_ops.forInNextVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.for_in_next` 槽（:759，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `op.iterator_close.b` (`src/exec/tailcall_dispatch_colds.zig:751`)

- **签名**：`fn b(vm: *Vm) HostError!void`。
- **作用**：OP_iterator_close 的尾分发 handler：在寄存器 `pc/sp/var_buf` 上执行该 opcode，并以尾调用进入下一条。
- **实现**：关键调用：`iterator_ops.iteratorCloseVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 迭代器操作会跑用户 `next`/`return` 方法并新建 result 对象：分配、可再入 JS、可触发 GC。 错误：`iterator_ops.iteratorCloseVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `h()`（本文件 :129-136，把不看 pc 的 body 包给 `coldStd`），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.iterator_close` 槽（:764，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `handlerComparePlaceholder` (`src/exec/tailcall_dispatch_colds.zig:1013`)

- **签名**：`fn handlerComparePlaceholder(comptime o: u8) Handler`。
- **作用**：冷表工厂 `handlerComparePlaceholder`：把共享 helper 收成带 opcode 立即数的 `coldStd` Handler。
- **实现**：`return coldStd(struct { fn b(vm, pc) { _ = pc; _ = try vm_property_field.inOrInstanceof(..., o); } }.b)`——`o` 是 comptime opcode 实参（`op.in` / `op.instanceof`），每个调用点展开出一个独立 Handler 函数，body 不读 `pc`。
- **所有权 / 错误 / 调用**：错误：无——comptime 工厂本身没有失败路径，只把 `o` 烘焙进 body 后返回 `coldStd(...)` 的 Handler；运行期错误由它生成的 body 与外壳承担。 调用：本文件的 `buildTable`，按每个需要 opcode 立即数的槽实例化一次。

### `handlerComparePlaceholder.b` (`src/exec/tailcall_dispatch_colds.zig:1015`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`handlerComparePlaceholder` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_field.inOrInstanceof`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_property_field.inOrInstanceof` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc）。`cold_table` 侧：`op.in`（:310）与 `op.instanceof`（:311）两槽；`dispatch_table` 侧：只剩 `op.in`，`op.instanceof` 在 :986 被 `dispatch.op_instanceof` 覆盖。冷表那份既是快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用目标，也是 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常执行体。这一版把 opcode 当 comptime 实参传进去，取代了 :305 那条把它传成 `undefined` 的死赋值。

### `handlerPost` (`src/exec/tailcall_dispatch_colds.zig:1021`)

- **签名**：`fn handlerPost(comptime o: u8) Handler`。
- **作用**：冷表工厂 `handlerPost`：把共享 helper 收成带 opcode 立即数的 `coldStd` Handler。
- **实现**：`return coldStd(struct { fn b(vm, pc) { _ = pc; _ = try vm_arith.postUpdateVm(..., o, ...); } }.b)`——`o` 是 comptime opcode 实参（`op.post_inc` / `op.post_dec`），每个调用点展开出一个独立 Handler 函数，body 不读 `pc`。
- **所有权 / 错误 / 调用**：错误：无——comptime 工厂本身没有失败路径，只把 `o` 烘焙进 body 后返回 `coldStd(...)` 的 Handler；运行期错误由它生成的 body 与外壳承担。 调用：本文件的 `buildTable`，按每个需要 opcode 立即数的槽实例化一次。

### `handlerPost.b` (`src/exec/tailcall_dispatch_colds.zig:1015`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`handlerPost` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_arith.postUpdateVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 错误：`vm_arith.postUpdateVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），只装在 `cold_table` 的 `op.post_inc`/`op.post_dec` 两槽 槽（装表本文件 :332-333）——由快臂 guard-miss 的 `cold_table[pc[0]]` 尾调用、或 L0 `stop_before_pc` 令 `active_dispatch_tbl`=`cold_table` 时的正常分发进入；`dispatch_table` 同槽已被 `dispatch.op_post_inc_dec` 覆盖（:910）。

### `handlerAppend` (`src/exec/tailcall_dispatch_colds.zig:1029`)

- **签名**：`fn handlerAppend(comptime o: u8) Handler`。
- **作用**：冷表工厂 `handlerAppend`：把共享 helper 收成带 opcode 立即数的 `coldStd` Handler。
- **实现**：`return coldStd(struct { fn b(vm, pc) { _ = pc; _ = try vm_literal.appendSpreadValuesVm(..., o, ...); } }.b)`——`o` 是 comptime opcode 实参（只有 `op.append` 一个调用点），body 不读 `pc`。
- **所有权 / 错误 / 调用**：错误：无——comptime 工厂本身没有失败路径，只把 `o` 烘焙进 body 后返回 `coldStd(...)` 的 Handler；运行期错误由它生成的 body 与外壳承担。 调用：本文件的 `buildTable`，按每个需要 opcode 立即数的槽实例化一次。

### `handlerAppend.b` (`src/exec/tailcall_dispatch_colds.zig:1015`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`handlerAppend` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_literal.appendSpreadValuesVm`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `appendSpreadValuesVm` 展开 spread 源，会跑迭代协议并向目标数组追加（分配、可再入）。 错误：`vm_literal.appendSpreadValuesVm` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.append` 槽（:505，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。

### `handlerPutVarInit` (`src/exec/tailcall_dispatch_colds.zig:1037`)

- **签名**：`fn handlerPutVarInit(comptime o: u8) Handler`。
- **作用**：冷表工厂 `handlerPutVarInit`：把共享 helper 收成带 opcode 立即数的 `coldStd` Handler。
- **实现**：`return coldStd(struct { fn b(vm, pc) { _ = pc; _ = try vm_property_globals.globalDefinition(..., dispatch.evalGlobalVarBindings(vm), o); } }.b)`——`o` 是 comptime opcode 实参（只有 `op.put_var_init` 一个调用点），body 不读 `pc`。
- **所有权 / 错误 / 调用**：错误：无——comptime 工厂本身没有失败路径，只把 `o` 烘焙进 body 后返回 `coldStd(...)` 的 Handler；运行期错误由它生成的 body 与外壳承担。 调用：本文件的 `buildTable`，按每个需要 opcode 立即数的槽实例化一次。

### `handlerPutVarInit.b` (`src/exec/tailcall_dispatch_colds.zig:1023`)

- **签名**：`fn b(vm: *Vm, pc: [*]const u8) HostError!void`。
- **作用**：`handlerPutVarInit` 的冷 body：`coldStd`/`h()` 先 publish，再跑本函数，然后 `coldNext`。
- **实现**：关键调用：`vm_property_globals.globalDefinition`。 栈效应：helper 按该 opcode 改 `stack.top_ptr`（冷路径权威是 publish 后的 Stack，不是寄存器 sp）。 下一跳：本函数是 `coldStd`/`h()` 的 body，不自己尾分发；外壳成功则 `coldNext`（`maybeStop` 后 `active_dispatch_tbl[npc[0]]`），失败 `vm.fail` → `.threw`。
- **所有权 / 错误 / 调用**：所有权：无新所有权——值由 GC 追踪、VM 栈槽本身就是根，去 rc 后 `push`/`pushOwned` 已同义（stack.zig:214-236），body 不 retain/release。 `globalDefinition` 在全局对象/词法环境上建绑定，可扩存储。 错误：`vm_property_globals.globalDefinition` 先自捕——可捕获错误交 `call_runtime.handleCatchableRuntimeError`（call_runtime.zig:139）：本帧有 catch 目标就裁栈到 catch 标记、压异常值、改写 `frame.pc` 并返回 `.continue_loop`（外壳照常 `coldNext`，等于没出错）；无人接的才逃到外壳 `vm.fail` → `.threw`（`vm.pending_error` 经 :7133 抛回 `runTC`）。 调用：外壳是 `coldStd`（body 直接收 pc），同一份装进 `dispatch_table` 与 `cold_table` 的 `op.put_var_init` 槽（:518，fast 段未覆盖），由 `next`/`cont` 的表尾调用进入；两表（tailcall_dispatch.zig:6918/7013）是它仅有的引用者，无 dispatch 之外的调用方。
## 覆盖核对

- 清单函数数: 121
- 本文标题覆盖: 121
- 未覆盖: 无
