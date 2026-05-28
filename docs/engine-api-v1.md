# Engine API v1 Contract

This document defines the target public Zig API for the embeddable engine
surface. It is a contract for Production v1 stabilization, not a claim that all
items are complete today.

## Scope

- The API is Zig-only.
- One `Engine` owns one runtime, one context, and one job queue.
- The supported thread model is one thread per runtime. Sharing an `Engine`,
  `Runtime`, `Context`, or `ValueHandle` across threads is outside the v1
  contract.
- The JavaScript semantic reference is QuickJS behavior, validated through the
  repository-local `test262.conf` profile and focused regressions.

## Public Types

- `Engine`: owned embedding handle. Call `deinit` exactly once.
- `EngineOptions`: construction options. It currently carries the allocator,
  optional allocation trace writer, and resource limits.
- `Limits`: memory, stack, and GC-threshold controls.
- `EvalOptions`: eval mode, filename, output writer, strictness, and timing.
- `ValueHandle`: owned `Value` wrapper. Call `deinit` or `release`.
- `EvalResult`: alias for `ValueHandle`.
- `EngineError`: alias for the runtime error set exposed by the engine.
- `ExceptionInfo`: owned exception snapshot wrapper. Call `deinit`.

## Ownership Rules

- `Engine.init`, `Engine.initWithTrace`, and `Engine.initWithOptions` return an
  owned engine.
- `Engine.eval`, `Engine.evalModule`, and lower-level eval methods return an
  owned `core.Value`; callers must free it with the engine runtime.
- `Engine.evalHandle`, `Engine.evalModuleHandle`, and
  `Engine.evalHandleWithOptions` return a `ValueHandle` that frees through the
  originating runtime.
- `Engine.takeExceptionInfo` returns an owned exception value wrapper.
- Values and handles must not outlive their engine.

## Resource Controls

`Limits.memory_bytes` maps to `Runtime.setMemoryLimit`. `Limits.stack_bytes`
maps to `Runtime.setStackSize`. `Limits.gc_threshold_bytes` maps to
`Runtime.setGCThreshold`.

`Engine.setLimits` is intentionally small and synchronous. It does not promise
preemption, sandboxing, wall-clock timeouts, or thread-safe mutation.

## Evaluation

Production v1 keeps the existing eval family but prefers `EvalOptions` for new
embedding code. `EvalOptions.mode` selects script or module parsing.
`EvalOptions.filename` controls diagnostic/module naming. `EvalOptions.output`
is the host print target for QuickJS-compatible helper output.

Script-mode eval returns `undefined` after executing and draining pending
promise jobs, matching the current CLI-oriented surface. Module eval returns
the module completion value when one is kept by the evaluator.

## Stability Rules

- Public API removals require a compatibility note and migration path.
- Public error-set changes require a release-note entry.
- New ownership-bearing return values should use `ValueHandle` or document the
  exact free path.
- Host API expansion must not depend on Node.js, Deno, browser APIs, or process
  globals unless a separate runtime layer owns that contract.
