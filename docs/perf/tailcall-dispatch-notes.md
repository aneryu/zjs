# tailcall_dispatch: measurement notes moved out of the source

Facts that used to live as comments in `src/exec/tailcall_dispatch.zig` /
`tailcall_dispatch_colds.zig`. The code keeps one-sentence "why"s; the
numbers and the history live here. Each bullet names the function it came
from. Numbers are as measured at the time and are not re-verified.

## Vm, dispatch primitive, cold infrastructure

- `Vm.prop_sites` mirror: reading the property site through `FunctionBytecode.hotExtension()` made `op_get_field`/`op_get_field2` stop being leaves (64-byte frame + four callee-saved stp pairs on every hit).
- `Vm.publishPropSites` is lazy (one store): eager mirror refill cost ~+26 insn per bare native callback crossing.
- `Vm.takeNativeReturnInto` uses pinned 64-bit ldr/str on AArch64: a merged `q` copy does not store-forward against the 64-bit stores of the return arms (~12 cycles per hit each side).
- `Vm.publishPushedEntry`: a same-callee short circuit (skip stores when function/var_refs_base match) was measured and reverted (+5 insn / +1 cycle on call-site microbenches); the stores are off the entry dependency chain.
- `Vm` field slots (`active_dispatch_tbl`, `var_refs_base`, `rt`, `resident_tail_tbl`) were placed in retired slots to keep the measured struct layout unchanged.
- Handler section: source order packs the ~26 hot zlib bodies into ~37 KiB; opcode-numeric order would spread call/ctor/get_field bodies across the page budget. `op_handler_section_tail` exists so new handlers append after the established island.
- `zjs_f_tombstone_keep` + `.space` pads were tuned so nm sizes of get_field (0x35c), get_field2 (0x31c), get_field2_call_method (0x300), put_field (0x104) matched a historical baseline.
- Module doc: splitting the switch dispatcher into per-op handlers collapsed the frame from ~3504 B (sum of per-arm spills, non-coalescing) to the max single handler (~80-150 B).

## Call / return / constructor / for-of / tail_call / drop handlers

- `enterEntry`: entering via the Entry pointer pushCall returned (not reloading `machine.top`) mirrors qjs entering through the alloca result already in a register.
- `pollRetreatedCallRegion` / `pollCallEntryCold`: keeping only the cadence tick in the warm body stopped the publishing poll's `!void` error union from materializing as a rodata constant + merge phi on every call; a `?Outcome` return re-materialized the merge as a memory phi (rodata null + sret + tag load), hence the bool-in-register contract.
- `pushApplyForwardEntry`: outlined because inlining it grew `op_call_method` / the apply-fwd handler to a 0x4a0 frame.
- `pushWarmEmptyLeafAndEnter` etc.: the resume record lets the leaf return restore pc/sp with one `ldp`.
- Second warm inline bodies (raw-this twins of empty-leaf / exact-args / capture-leaf arms) measured +1.3% cycles on closure-two-arg from spilled freight stores and could tail-merge into a shared discrimination head; hence one inline warm body per family, the twin rides one `bl` into an outline constructor.
- `opCall` raw-this empty-leaf arm: folding sloppy and raw modes into one eligibility bit measured +3 insn/call on call-const-zero-arg; the two bits stay separate and the raw test runs only after the sloppy bit misses.
- `opCall` exact-args arm: testing the fused kind byte before the arity comparison (vs a two-byte chain) measured -1.3% insn on call-closure-two-arg.
- `opCall`: a dedicated warm padded-leaf family (`argc < arg_count`) was removed after an Octane census found 3273 hits across fifteen benchmarks (0.0015% of 221.9M calls).
- `opCall`: an `inline_exact` expansion of the exact-simple constructor into op_call1..3 was withdrawn because it put ~200 insn of constructor body into each handler (I-cache).
- `opCall` native leaf arm: the in-handler leaf call beat a call-site cache variant (whose guard needs the same entry load plus a slot chain), so no cache/quickened opcode was added for this shape.
- `op_call_method`: keeping the native record `rec` live across the vm_native.dispatch call grew the handler 0x3f0 -> 0x400 and slid the handler-island tails.
- `op_call_method`: ~85% of method calls are native methods; the shared `objectFromValue` + class_id branch avoids a redundant unpack for them.
- `op_post_call_continuation` for-of fast leg / `op_for_of_next`: whole-value 16-byte loads of the just-written `{value, done}` slots and of the iterator record stalled on store-to-load forwarding (top stall of the for-of profile); integer-pair loads/stores fixed it. The aggregate `done` store lowered to an SVE index + 128-bit store with the same stall on the if_false reload.
- `popAndResume`: deriving the dying Entry from `vm.frame` via @fieldParentPtr lets the teardown-flags load issue in parallel with the `vm.machine` load (was third in vm->machine->top->flags chain). Alias `&machine.top.?.frame == vm.frame` audited with an all-modes equality probe across full test262 + async/generator slices.
- `popAndResume` ordinary arm: one masked test on the teardown byte replaced four per-shape tests on every ordinary return.
- `popAndResume` empty-leaf arm: reading the resume {pc, sp} first starts the dispatch chain (ldp -> opcode ldrb -> handler load -> br) before teardown, replacing the prev->frame.function->code.ptr(+frame.pc) and stack->top_ptr re-derivation.
- `popAndResume` exact-args arm: a runtime len==0 guard on the zero-arg empty-leaf arm measured +0.9 cyc per return, so that family uses the static return-balance proof instead; unbalanced zero-arg bodies (`function k(){ ({}); }`) are refused publication.
- `popAndResume` forwarded-leaf arm duplicated in-handler (not only in `op_return_slow`) so forwarding shapes skip the scratch store, the tail hop and that body's prologue.
- `op_return_slow` exported slot: without the export LLVM folded the slow body back into both return handlers.
- `op_return` align(64): when the exact-args arm grew, without the pin the untouched inline-control loop flapped +2.4% cycles at bit-identical instruction counts between two layouts.
- `op_for_of_next` warm borrowed arm: replaces a noinline constructor `bl`, the depth-accounting shell and an acquireSlot round-trip (qjs equivalent: alloca + seven sf stores).
- `op_tail_call`: a separate generic tailCall* path once sent 7M DB method tails down execCall (rejected rework slowdown); `tail_call_method` must remain an alias of `op_call_method`. Strict-only PTC ruling dated 2026-08-18. Handler placed in the island-tail section so new handlers do not slide the established island.
- `op_drop_fast`: before it, `o = {...}` / `a = [...]` loops routed their trailing `drop` through the 416-byte publishing coldStd shell every iteration (the only hot op still cold in the four literal benchmarks). Cold `vm_value.drop` is GC-safe only because `stack.pop()` shrinks the window before free.
- `op_call_constructor` fused create-this: skips resolve / proto lookup / second poll on a specialized site.

## Hot handlers: arithmetic, locals, fields, array elements

- opBinary: the former single fused 11-op handler had a 0x1e0 non-coalescing frame, merged results through memory (`ldr q0/str q0`), and fmod forced lr + 4 callee-saved pairs onto every int add — 44 insn/op vs qjs 22; per-op split fixed it.
- opLoc: the one-handler-for-18-variants runtime operand decode cost ~15 insn/op.
- opLocCheck: without a resident handler, checked loc ops routed to the 192-byte-frame `checkedLocVm` cold path (self% #1 in four benchmarks).
- opGetVarRef: nested-cell guard (#7) and pre-typed cell header load (#4) were deleted once var_refs became typed cells and the direct-eval const view aliased pvalue.
- op_push_atom_value: the unrooted push-run bug reproduced on test262 staging/sm/RegExp/unicode-disallow-extended.js (miss on the ninth element collected the eight strings above top_ptr); previously hidden by the atom table's `entries[].str` root.
- op_get_arg0..3: a per-function `.text.zjs.tail_hot.0110` pin placed get_arg0 ~1 MB from the zlib hot set (269 pages); all handlers now share one section.
- op_get_field (W1): keeping prototype + native-getter guards inline gave a 96-byte frame plus five callee-saved `stp` pairs, +10.7% fixed-work instructions on Richards (T-spike fairness rule 1 failure).
- op_get_field: sending every direct-prototype hit through an indirect tail reduced instructions but lost more IPC than it saved, so one prototype link stays resident.
- op_prop_site_indirect_tail: adding a `.deferred` arm cost every indirect hit ~6 instructions (embedding corpus `world.step` 208→214, `world.time` 143→149).
- op_put_array_el: address-taking slow legs inline cost a 144-byte frame, six callee-saved `stp` pairs and two operand spills on the hot arm.
- op_put_array_el miss pad (.space 0x100): short-form get_var_ref0..3 dropping TDZ (~0x80) and this handler dropping sign+exotic (~0x10) slid the field cluster −0x100; the pad on the rest miss keeps the dense hit at 8 jumps.
- op_put_array_el_cold: 72% of pdfjs puts are typed-array writes; the inline isArray check removed ~2.27M no-op noinline probe calls.
- op_put_field_add_tail: the previous cold route paid coldStd publish, two stack.pop()s, a bytecode re-decode and a repeat own-probe per new-property write.
- op_get_array_el_ta: a `blk`/`switch` result per kind allocated a 16-byte slot each and grew the frame to 0x100; a single JSValue home fixed it.
- op_get_array_el: wrapping the class dispatch in `key.is(.int)` made LLVM fold the ARRAY arm into the typed-array bitmask miss (the navier dense-[i] tax).
- op_get_array_el pad (.space 0x20): removing the release tail shrank the handler 0x280→0x1d0; pad kept put_field/get_field2 addresses (body-shrink slide was the TS +13M cyc class); tuned 0x90→0x20 after the mapped-arguments arm consumed the rest.
- get_field2/get_field tombstones (.space 0x140/0x100/0x138/0x8): sized so nm sizes match a historical main (get_field 0x35c, get_field2 0x31c, get_field2_call_method 0x300, put_field 0x104).

## Hot handlers: compare, logic, globals, internal methods, outline constructors, tables

- op_object / op_define_field：走 coldStd 冷壳时每个字面量 op 付约 224 字节的 publish+spill 帧。
- opCompare：共享 op_compare handler 用运行时谓词选择链，实测约 30 insn/compare（qjs 17）；按 opcode 生成后回到 int 快路径。
- opCompareEq：可内联的直接 tail 让释放梯子折回 int 叶、重新长出 0x70 帧；op_compare_cold 直连曾让 `s=s+i` 循环 +37 insn/iter。
- opCompareEq bool/bool 臂：留给冷壳实测 +11.5 insn/op，是唯一探测链 miss 成本高于收益的形态（eq 第二大形态）。
- opLogicCold：新增前单个非 int32 操作数走 binaryVm 423 insn（qjs 205）；六个逐 op 副本各 906–937 B，合成一个共享 handler。
- dispatchInternalNativeMethod：exec_direct 命中与 env 路径冷臂共帧曾让 FastDispatch 帧 0x1c0→0x1d0。
- tryFastDefaultInstanceof：isCallableValue/getOwnDataObjectBorrowed 的 findProperty 外调是残余约 160 insn。
- op_lnot：冷路线 91.0 insn / 22.2 cyc（qjs 18 / 3.7，RayTrace 归因，操作数分布 74.6% immediate / 25.4% object）；直连冷壳变体曾扰动邻近 codegen。
- op_add_loc_cold：跨 noinline addLocalVm 边界时 int+float 29.7% idle cycles。
- getVarGlobalOwnDataInline：Flags.fromBits 内联长出栈帧，+2 sp insn/读；外联探测 bl 在全局变量循环 +5.4% cyc。
- op_put_var：冷壳每次全局写建 128 字节帧、保存 7 寄存器；内联 store+release 后命中腿仍残留 48 字节帧（寄存器分配结果，非结构地板）。
- pushExactArgsLeafMiss 等外联体放在 handler 簇之后：插在簇中曾让无关 inline-control 循环 +2.4% cycles（insn 逐位相同，BTB/fetch 别名）。
- warmExactArgsLeafOutline / warmCaptureLeafOutline：第二个内联 warm 体让 closure-two-arg +1.3% cyc（freight 溢出存储）。
- op_eq_if_false8：非 int 形态经 eq_if_false8_cold/compareAt 曾是 richards +579M insn。
- dispatch_table：256 项 profiledHandler 包装移动了 handler 岛，破坏 op_return musttail ABI（zlib 上 sp 到达为 0，VmStackArena.restore SIGSEGV）。
- op_get_var：var_refs_base 镜像把依赖链从 5 级 load 降到 4 级。
- op_get_var/op_put_var：`var_refs_base == frame.var_refs.ptr` 断言在 Debug 与 ReleaseSafe 都活，作为 seam 泄漏探测器。

## Driver and cold table

- runDispatchLoopPublished: outlining the `.returned`/`.tail` arms removed ~25 prologue instructions (LLVM-hoisted stack-address materialization) paid by every builtin callback / embedder entry.
- tailGetLoc8: leftover `get_loc8_push_2` was ≈95M of 106M `get_var_ref0_get_loc8` entries, hence tested first.
- tailPush2: fused leftovers live at opcode ≤ `get_loc8_push_2` (32); raw `push_0..7` are 179–186.
- op_handler_section_tail: source order inside the main handler section is not LLVM-stable; the tail section was introduced in the wave-22 island rework.
- colds buildTable HOT overrides: the coldStd publish shell carried a ~128B frame (224-byte body); object/array-literal ops paid it every iteration before their fast overrides.
- colds `keep[]`: opcode slots 240/242/243 (type tests) were reclaimed by fusion v3; the parked leaves kept island offsets identical to the pre-fusion binary (ICF folds the pair).
- colds op_lnot override: qjs reaches the non-inline tags through an out-of-line JS_ToBoolFree `bl` as well.
