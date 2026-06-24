# Stack Bytecode VM Status And Evolution Boundary

本文只回答当前 ZJS 是否应该从 stack bytecode interpreter 迁移到 register /
accumulator bytecode。它按当前源码状态描述，不把未来路线写成已完成能力。

## 1. Current Answer

当前不需要把 VM “改成 bytecode interpreter”。

`src/exec/zjs_vm.zig` 已经是 bytecode interpreter：parser/emitter 产出
QuickJS-format bytecode，VM loop 逐 opcode dispatch，并把具体 opcode family
分发到 `src/exec/vm_*.zig`。

当前也不建议重写为 register / accumulator bytecode。理由是：

- 语义兼容、对象模型、GC roots、eval、module、promise 和 exception 行为仍是更高价值的稳定化区域。
- 当前已有 stack-size validation、source location metadata、property IC 和 opcode profiling。
- register / accumulator bytecode 会同时影响 emitter、debug/source metadata、exception unwinding、GC liveness 和未来 JIT lowering。
- 在没有 profiler 证明 dispatch 或 operand-stack traffic 是主要瓶颈前，重写 bytecode 格式收益不清楚。

## 2. Current Implementation

当前 VM 相关入口：

- `src/frontend/zjs_parser.zig`: QuickJS-aligned parser/emitter。
- `src/bytecode/function.zig`: `Bytecode` runtime carrier。
- `src/bytecode/pipeline/`: label/variable resolution、stack-size、pc2line 和 finalize passes。
- `src/exec/zjs_vm.zig`: VM dispatcher。
- `src/exec/frame.zig`: call frame、eval var-ref snapshot 和 root scope。
- `src/exec/stack.zig`: operand stack。
- `src/exec/vm_*.zig`: opcode family shards。
- `src/exec/property_ic.zig`: property inline-cache fast paths。

当前 `Bytecode` 已经携带多类 metadata：

- bytecode bytes
- constants
- atom operands
- argument/local/var-ref metadata
- scopes and module metadata
- `pc2line_buf`
- `source_loc_slots`
- property IC site/slot tables

当前没有单独命名为 `CodeBlock` 的抽象。历史设计文档里的 `CodeBlock` 可以看作
未来可能的封装方向，但当前代码的真实载体是 `bytecode.Bytecode` 和
`core.FunctionBytecode`。

## 3. Already Landed

已落地能力包括：

- stack bytecode interpreter。
- QuickJS-format opcode execution。
- `compute_stack_size` style stack-depth validation in
  `src/bytecode/pipeline/stack_size.zig`。
- `pc2line_buf` and `source_loc_slots` for diagnostics/backtrace location。
- `ValueRootFrame` for explicit host/boundary value-root tracing (VM running
  frames no longer use a per-frame root scope; their operand stack/locals/args/
  var_refs are `FrameSlab`-owned and kept live by refcount-on-push)。
- frame-local ownership teardown through `Frame.deinit` and the `FrameSlab` carve。
- property IC slots attached to `Bytecode`。
- shape/version-guarded own/prototype data-property IC in `property_ic.zig`。
- `core.OpcodeProfile` counters for opcode time/counts, slow paths and IC events。
- VM opcode-family decomposition under `src/exec/vm_*.zig`。
- contiguous VM stack arena (`VmStackArena`) for frame locals/args/operand windows。
- same-loop inline bytecode calls (`src/exec/inline_calls.zig` `Machine`)。
- proper tail calls via inline-frame reuse (`Machine.tailCallReuse`,
  `tail-call-optimization` enabled in `test262.conf`)。

These are current facts. They can be referenced as implementation status.

## 4. Not Current Implementation

The following items are future candidates or design notes only:

- register bytecode VM
- accumulator bytecode VM
- baseline JIT
- call inline cache
- JIT-style formal GC stack maps
- moving copying nursery as the default heap model
- concurrent old-space GC
- uWS/HTTP/WebSocket host runtime boundary
- standalone `CodeBlock` API replacing current `Bytecode`

Documents may discuss these as possible evolution paths, but they should not be
described as current ZJS behavior.

## 5. Stack VM Versus Register/Accumulator

Stack bytecode remains the right current tradeoff:

```text
load local / constant
push intermediate values
execute opcode
pop operands
push result
```

Advantages now:

- emitter stays simpler while QuickJS compatibility is still improving.
- bytecode is compact and close to the existing parser/pipeline model.
- exception and eval behavior can be debugged against current stack state.
- existing stack-size validation remains useful.

Costs to watch:

- more push/pop traffic than a register or accumulator VM.
- more dispatches for expression-heavy code.
- future JIT lowering would need to reconstruct stack data flow.
- precise liveness metadata is harder than with explicit registers.

Accumulator/register bytecode may become worthwhile later if profiling shows the
interpreter loop itself dominates after property IC, object shapes, calls,
strings, arrays, promises and GC are stable.

## 6. Near-Term VM Work

Useful near-term work should stay compatible with the current stack bytecode:

- continue shrinking `src/exec/call_runtime.zig` (originally `shared.zig`) into focused VM/helper modules.
- keep property opcode logic concentrated in `vm_property.zig` and
  `property_ic.zig`.
- improve bytecode validation where `stack_size.zig` is not enough.
- expand source-location coverage for diagnostics.
- use `OpcodeProfile` and perf reports before changing bytecode architecture.
- strengthen root-safety tests around frame teardown, eval var refs, closures,
  generators, async jobs and module evaluation.

## 7. Migration Trigger

Reconsider accumulator/register bytecode only when most of these are true:

- semantic gates are stable enough that emitter-wide rewrites are acceptable.
- property/object/call/array/string/promise hotspots have been addressed.
- profiler data shows dispatch or operand-stack traffic is a top bottleneck.
- bytecode metadata, source locations and exception tables have clear contracts.
- GC liveness/rooting requirements at VM safepoints are explicitly specified.
- there is a concrete JIT or baseline compiler plan that benefits from the new
  bytecode form.

Until then, keep stack bytecode and improve the current interpreter.
