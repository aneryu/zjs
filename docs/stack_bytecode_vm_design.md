# Stack Bytecode VM Status And Evolution Boundary

This note records the live boundary of the stack bytecode VM and answers
whether it should migrate to register / accumulator bytecode. Field-level
QuickJS comparison is in the
[subsystem difference baseline](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md).

## 1. Current Answer

zjs is already a bytecode interpreter:

- `parser.zig` parses and emits QuickJS-aligned stack bytecode;
- `bytecode.zig` performs resolve, stack-size, pc2line, and finalize;
- `zjs_vm.zig` / `tailcall_dispatch.zig` execute opcodes;
- `vm_*.zig` and `vm_property_*` own the concrete opcode families.

There is no evidence supporting a rewrite to a register/accumulator VM.
Known gaps in semantics, call frames, modules, eval, ownership, and generic
dispatch are more specific, and are better closed item-by-item against
QuickJS.

## 2. Current Carriers

Compile-time carriers:

- `FunctionDef`: variables, scopes, child functions, source/debug, and
  emitter state;
- lowered `Bytecode`: the pipeline's mutable code/metadata.

Post-publish production execution carrier:

- canonical GC-managed `FunctionBytecode`;
- 96-byte QuickJS-aligned core header;
- packed constant/var/closure/code data;
- optional 32-byte debug tail;
- zjs-only 8-byte call-facts/script-or-module tail.

Scripts, eval, nested functions, and module roots all execute canonical
`FunctionBytecode`. There is no separate `CodeBlock` and no property IC
slots.

## 3. Frame And Dispatch

Main entry points:

- `src/exec/frame.zig`: `Frame`, `FrameSlab`, and frame-owned windows;
- `src/exec/stack.zig`: operand stack;
- `src/core/runtime.zig`: per-runtime `VmStackArena`;
- `src/exec/inline_calls.zig`: same-loop `Machine` frame push/pop;
- `src/exec/tailcall_dispatch.zig`: threaded/tail-called opcode handlers;
- `src/exec/call_runtime.zig`: call/eval/generator/Atomics shared runtime
  glue.

The tail-call handler split is a current code-generation constraint, not a
file-organization preference: each opcode handler ends in a tail dispatch,
the hot arm completes inside the handler, and cold work that might emit an
ordinary call is outlined into `vm_*.zig` first. Folding those handlers
back into one large switch would grow the shared stack frame again; do not
merge them without a frozen binary, disassembly, and multi-build PMU
evidence.

Ordinary synchronous bytecode frames are preferentially carved from the
runtime arena as `[args | locals | operand | var-ref metadata]`.
Generator/async frames must survive suspend, so they own transferable
resident storage instead of borrowing the arena.

Live values in the VM stay alive via refcount-on-push and deterministic
frame teardown. `ValueRootFrame` is for host/builtin boundaries, not
generic root registration of every VM frame.

## 4. Property Access

There is currently no inline cache:

- `src/core/ic.zig` does not exist;
- `FunctionBytecode` has no site/slot table;
- `zjs_enable_ic` does not exist.

`src/exec/property_ic.zig` is a historical filename; it now holds
non-cached direct shape/property/global fast paths. Every access checks
the current object/shape/property state; the two retained `cached*`
adapters always miss.

## 5. Tail Calls

The VM can execute `tail_call` / `tail_call_method` and can replace an
inline frame with `Machine.tailCallReuse`. That is a bytecode ABI /
internal capability.

The default source compiler and the pinned QuickJS parser both emit
ordinary call+return; they do not automatically lower source into proper
tail calls. `test262.conf` skips `tail-call-optimization`. Documents and
release notes must not claim product-level PTC is enabled.

## 6. zjs-Specific Call Machinery

To shrink the Zig frame/dispatch fixed cost, `FunctionBytecode` and
`Machine` currently also contain:

- simple-inline eligibility;
- empty/exact/padded/capture leaf classification;
- forwarded `Function.prototype.call` leaf;
- narrow leaf frame constructors and return epilogues;
- simple-field constructor body bypass and runtime memo.

These are not a property IC, but several of them also have no pinned
QuickJS counterpart. They are audit subjects under the current
QuickJS-faithful policy and must not keep expanding on microbenchmark
results alone. Keep or delete them only with:

1. a matching QuickJS mechanism;
2. observable / exception / OOM / interrupt / realm boundaries;
3. controlled instructions / allocations / time A/B;
4. focused + checkpoint / production gates.

## 7. Current Capabilities

Landed:

- QuickJS-aligned stack opcode execution;
- stack-depth validation;
- pc2line / source-location diagnostics;
- canonical `FunctionBytecode`;
- same-loop bytecode call frames;
- explicit generator/async resident-frame ownership;
- direct and indirect eval entry;
- catch/finally and pending JS exception propagation;
- four zjs-only explicit-resource-management opcodes.

Opcode profiling (after the D0 fix):

- A profiling build (`zig build zjs-profile` /
  `-Dzjs_enable_opcode_profile=true`) wraps the whole hot dispatch table
  at comptime: every table dispatch is counted and delta-timed through
  `vm_profile.noteDispatch` (a scope cannot span an `always_tail` chain;
  the previous opcode's interval is closed by the next dispatch, and the
  last one by `flushPendingDispatch` before dump). `cold_table` and the
  property tail tables are not wrapped — they redispatch the same pc, and
  wrapping them would double-count.
- The default build's table is entry-for-entry equal to the unwrapped
  table; `--profile-opcodes` fail-closes on a non-profiling binary (exit
  2); `--perf-json` emits `opcode_profile_enabled` explicitly. The
  `perf-runtime-profiles` gate requires a minimum count (not only an
  upper bound); an all-zero profile cannot pass.

Not implemented:

- register / accumulator bytecode;
- baseline JIT;
- call or property inline cache;
- JIT GC stack maps;
- moving nursery;
- concurrent collector;
- a public standalone `CodeBlock` / bytecode serialization API.

## 8. Near-Term Work

Keep stack bytecode. Prioritize:

- decompose call admission, frame publication, return, and RC fixed tax
  against the current pinned qjs;
- audit zjs-only leaf / body-bypass machinery;
- converge the direct-eval binding mechanism;
- strengthen generator / async / module exception and OOM ownership
  tests;
- improve source-location coverage;
- keep shrinking `call_runtime.zig` by ownership domain, without
  forcibly splitting shared state to hit a line-count target.

Re-evaluate the bytecode architecture only when the semantic gates are
stable, hot spots in call / property / array / string have been
converged with qjs mechanisms, and PMU evidence shows operand traffic /
dispatch as the main bottleneck.
