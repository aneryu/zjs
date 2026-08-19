# GUIDE.md — Project Development Guide

Last updated: 2026-08-17

This guide is the engineering rulebook: Zig style, ownership, errors, and the
validation command ladder. Historical plans and campaign ledgers live in git
history.

`AGENTS.md` is the operational rulebook (no shortcuts, change discipline).
Contribution workflow is in `CONTRIBUTING.md`. Compatibility and product
limits live in `COMPATIBILITY.md` and `LIMITATIONS.md`.

---

## Part A. Zig Engineering Rules

Goals:

- Internal logic written in Zig style: type-safe, explicit memory, explicit
  errors.
- C ABI surface is minimized.
- Maintainable, testable, evolvable.

### A.0 Core Principles

1. Internal code must be Zig-style, not "C with syntax sugar".
2. Ownership must be explicit: whoever allocates, releases.
3. Errors must be explicit: error sets, not implicit error codes.
4. Pointers must converge: prefer slices internally.
5. C ABI exists only at boundary layers.
6. Pin Zig 0.16.0; do not mix old tutorials or master API.

### A.1 Types

- Prefer slices internally (`[]const u8`, `[]T`); convert C pointer+len at
  the boundary. Default string parameters to `[]const u8`.
- Nullable is `?*T`; non-null is `*T` / `*const T`. C strings are
  `[:0]const u8` / `[*:0]const u8`.
- Internal structs are plain `struct`. `extern struct` is C ABI only.
  `packed struct` is only for required bit layout.
- Do not retain `[*c]T` or propagate `void*` / `anyopaque` internally.

### A.2 Memory

- Allocating functions take `allocator: std.mem.Allocator`. No hidden or
  global allocator in library code.
- `[]u8` is owned (caller frees with the same allocator). `[]const u8` is
  usually a borrowed view. `*T` / `?*T` lifetime must be documented.
- Document ownership on every allocating or borrow-returning function.
- Bind `errdefer` / `defer` immediately after allocation. Free with the
  same allocator. Never return stack memory. Never disguise arena values as
  long-lived owned objects.
- Library code: caller-injected allocator. CLI / short-lived flows: arena.
  Tests: `std.testing.allocator`.

### A.3 Errors

- Internal code returns `error{...}!T`, not C error codes or out-params.
- Avoid `anyerror`. Do not use `catch unreachable` without proven safety.
- C error codes exist only at the ABI boundary; they do not flow back into
  Zig.

### A.4 C Interop

- Contain `extern` / `export`, C pointer types, errno-style codes, and
  `anyopaque` in a small boundary layer. Convert all boundary input to Zig
  types immediately.
- `translate-c` is for headers, bootstrap, and ABI understanding only;
  never ship raw output as business code.
- Macro order: constants → `fn` / `inline fn` → comptime / generics →
  manual rewrite.

### A.5 Zig 0.16.0

- Pin **Zig 0.16.0**. Do not copy old blogs or master-doc patterns.
- Use 0.16.0 I/O (`std.Io`, `main(init: std.process.Init)`). Do not copy
  old `std.io.getStdOut()` or old managed-container examples.
- Keep `@cImport` centralized in `build.zig`.

### A.6 Build System

- `build.zig` owns target / optimize, modules, remaining C, flags,
  `translate-c`, and test / install steps.
- Migrate module by module; add tests after each step; do not keep
  transitional C shims longer than needed.

### A.7 Style

- Functions `camelCase`, types `TitleCase`, variables `snake_case`.
  4-space indent. Always `zig fmt .`.
- Documented exemptions from the naming rule (mirror names beat local style):
  - Opcode dispatch handlers named `op_<opcode>` mirror the `bytecode.op`
    table, which itself mirrors upstream QuickJS `OP_*`; keep the literal
    spelling so all three stay grep-linked.
  - Ported C code (`src/libs/number_format.zig` dtoa/libbf) and `export fn`
    C-ABI symbols keep their upstream names.
  - Constants that mirror JavaScript identifiers (the predefined atom table,
    enum tags like `Atomics.compareExchange`) keep the JavaScript spelling.
  - Struct fields that store function pointers follow the function rule
    (`camelCase`), so a vtable field and its wrapper function share one name
    (e.g. `HostEventLoop.VTable.traceRoots`).
- Ownership suffixes (`*Owned` / `*Borrowed`) are annotations for
  counter-intuitive cases only; most functions follow the A.2 ownership
  rules without a suffix, so the **absence** of a suffix carries no
  ownership information.
- No unmarked helper duplication. When a helper must be re-implemented in
  another layer (e.g. layering forbids the import), the copy carries a
  `// mirror of <owner>, keep in sync` comment; otherwise reuse or forward
  to the single owner. An unmarked copy is a defect: the 2026-08-19 audit
  found 17 `objectFromValue` copies silently relying on an inlined-elsewhere
  safety argument.
- Small modules; ABI and business logic do not share a large file.
  Lifetime clarity beats short code.
- Discard unused values with `_ = ...`. Never silently discard errors or
  allocations.

### A.8 Safety Rules (Hard)

**Forbidden.** Stack escapes; implicit error-path leaks; internal `[*c]T`;
unjustified `catch unreachable`; borrowed data disguised as owned; mixed
allocators; version-unverified copy-paste.

**Special care.** Pointer lifetimes; sentinels; ABI alignment; C/Zig
integer widths; mutable shared buffers under concurrency.

**Runtime thread ownership.** A `JSRuntime` is initialized, mutated, collected,
and destroyed on one owner thread. Context construction/publication/release,
class definition growth/unregistration, context-list and prototype-slot
mutation, plugin install/unload, and GC commits all follow that token. Checked
host boundaries reject a foreign caller with `error.WrongRuntimeThread` before
allocation or mutation; infallible internal teardown paths assert the same
precondition. Same-thread callback reentry is supported and must use the normal
generation/reconciliation rules—thread ownership is not a non-reentrancy
guard. No broad Runtime structural lock substitutes for this contract.

Process-global class ID allocation is the exception: it has independent atomic
synchronization so different owner-thread Runtimes can allocate stable IDs
concurrently. A foreign `Atomics.waitAsync` notifier or test262 broadcast may
only publish a mutex-protected, no-allocation completion signal. Promise/Realm
mutation, settlement, cleanup, GC, JavaScript callbacks, and DSO callbacks run
later on the Runtime owner thread, with no waiter/structural mutex held. test262
workers and agents therefore create, use, and destroy their own Runtime inside
the worker thread.

### A.9 Agent Behavior

**A.9.1 Before writing code.**

1. Confirm Zig 0.16.0.
2. Identify the layer being touched: ABI boundary / internal logic / build.
3. Identify what the change involves: allocator, ownership, error set,
   lifetime, API mapping.

**A.9.2 When emitting code, state.**

- Where the allocator comes from.
- Whether the return is owned/borrowed.
- Who frees it.
- The error set.
- Mapping from old C API to new Zig API.
- C ABI assumptions.

**A.9.3 Preferred constructs.** `[]T` / `[]const T`, `error{...}!T`, `defer`,
`errdefer`, `extern struct` (only at ABI boundary), plain `struct`
(internal), `const`-default. **Avoid:** `[*c]T`, `anyerror`, internal
out-params, "make it compile first" no-ownership designs.

**A.9.4 Change strategy.** One module per migration step; format and test
immediately after; "compatibility with old API" is not a long-term goal;
correctness first, then performance.

### A.10 Self-Check Before Commit

- Slices instead of ptr+len where possible; nullable vs non-null distinct;
  `extern struct` only at the C ABI.
- Allocating functions take an allocator; ownership documented; every
  alloc has a free path and `errdefer` on error; no stack escape.
- Explicit error sets; no stray `anyerror`; no internal out-param + error
  code; no unjustified `catch unreachable`.
- `[*c]T` / `anyopaque` stay at the boundary; APIs confirmed for Zig
  0.16.0; `zig fmt .` and the relevant Part B.6 tier.

### A.11 Conclusion

> **At the C boundary it can look like C; internal code must be fully
> Zig-ified.**

Quality bar is not "it compiles":

- Lifetimes are clear.
- Memory behavior is derivable.
- Error paths are complete.
- APIs are consistent and composable.
- Boundary and internal layers have clear roles.

Self-test for migrated Zig:

1. Who allocates?
2. Who frees?
3. How does failure clean up?
4. Who owns the return value?
5. Is this a Zig interface or a C-compat interface?
6. Is it still written in C-style thinking?

If these questions cannot be answered at a glance, the migration is not yet
good enough.

---

## Part B. Validation And Tracking Workflow

This part defines how implementation work is validated now that the historical
QuickJS convergence docs have been removed from the active tree. Keep durable
evidence in the code, tests, commit message, issue, or PR that owns the change.

### B.1 What To Record

Record validation evidence when any of the following occurs:

- An implementation attempt starts or finishes.
- A validation command produces evidence that should guide later work.
- `run-test262` reports a new, changed, or fixed result.
- A crash, panic, stack overflow, allocator leak, OOM bug, or
  use-after-free is observed.
- Zig behavior differs from QuickJS reference behavior for an in-scope feature.
- A broad validation run is interrupted and could later be mistaken for
  final evidence.
- A blocker, dependency, or carried semantic debt is discovered.

Do not add ledger entries for typo-only edits fixed before validation unless
they expose a reusable process or implementation risk.

### B.2 Durable Decisions

Durable choices that change how later code should be written or reviewed need
an explicit note in the owning change, issue, PR, or a newly requested design
document:

- Object payload, class id, exotic behavior, or finalizer contracts.
- GC graph traversal, cycle detection, finalization, or weak edge policy.
- Module record, import/export resolution, linking, or evaluation semantics.
- Public CLI, runner, or validation contracts.
- Intentional divergence from QuickJS reference behavior with an explicit
  rationale.

Routine bug notes, temporary findings, and command output belong with the
owning change, not in broad status ledgers.

### B.3 Status Vocabulary

- `open` - work or failure exists and is not fully understood.
- `investigating` - reproduction or QuickJS comparison is in progress.
- `in_progress` - implementation work has started.
- `blocked` - cannot proceed without a named dependency or decision.
- `validated` - change has focused regression evidence and relevant command
  evidence.
- `parked` - intentionally deferred with a named reason.
- `superseded` - replaced by a newer task, decision, or implementation.
- `out_of_scope` - confirmed outside the selected QuickJS core scope.

### B.4 Classification Vocabulary

- `quickjs_parity_gap` - Zig differs from QuickJS reference behavior.
- `object_model_gap` - object/class/payload/exotic/property behavior is
  missing or structurally wrong.
- `cycle_gc_gap` - ownership, tracing, cycle removal, finalization, or weak
  edge behavior is incomplete.
- `module_semantics_gap` - module parse, link, resolve, namespace, or
  evaluation behavior is incomplete.
- `parser_gap` - lexer/parser accepts or rejects incorrectly.
- `emitter_gap` - parser succeeds but bytecode or metadata is wrong.
- `opcode_gap` - VM opcode handler is missing or semantically wrong.
- `builtin_gap` - builtin behavior or descriptors differ from QuickJS.
- `lifetime_bug` - ownership, refcount, use-after-free, leak, or double-free.
- `runner_bug` - `run-test262`, smoke, compare, or CLI tooling is wrong.
- `docs_tracking_gap` - process failed to record status, evidence, or
  handoff.
- `interrupted_validation` - command did not complete and is not proof.

### B.5 Workflow

1. Capture the exact command, script, or test slice before changing code.
2. Compare semantic questions against QuickJS reference behavior.
3. Identify both the QuickJS owner and the Zig owner for the behavior.
4. Make the smallest responsible subsystem change.
5. Add or update focused regression coverage before broad validation.
6. Run the relevant build, smoke, slice, or comparison command.
7. Record evidence with the owning code change, including interrupted or
   partial runs.
8. Promote only durable architecture choices to a reviewed design note or PR
   explanation.
9. Mark work `validated` only after regression evidence and command evidence
   are both recorded.

### B.6 Validation Tiers

Use the cheapest tier that proves the changed surface, then escalate before
handoff or release. Do not weaken skips, excludes, or assertions to make any
tier pass.

**Inner loop.** Start each focused edit with the narrowest changed-area target
or direct reproducer. For example, replace `core` below with the matching
subsystem:

```bash
zig build test-core --summary all
git diff --check
```

Also run the focused Zig test filter, JS fixture, or `run-test262 -d` / `-f`
slice that directly reproduces the changed behavior. The explicit `test-core`,
`test-parser`, `test-bytecode`, `test-compiler`, `test-exec`, `test-builtins`,
`test-runtime`, and `test-runner` targets apply compile-time namespace filters
and fail if the selection becomes empty.

After a coherent edit, run `mise run quick-gate` for Debug CLI integration
coverage. For several consecutive edits that all need CLI smoke feedback,
`mise run quick-watch` keeps the compiler resident; stop the watcher before
escalating to a broader gate. `quick-gate` intentionally does not compile the
separate test262 runner.

`build.zig` pins the Zig 0.16 build/test seed to `0` so the compile graph
stays cacheable. CLI `--seed` is not required. Pass `-Dzjs_test_seed=<u32>`
for an explicit randomized validation run.

**Checkpoint.** Use this before handing off a non-trivial code-bearing change:

```bash
mise run checkpoint-gate
```

This includes the unified Debug suite, Debug CLI smoke, and source-side
architecture checks. It does not compile ReleaseFast `zjs`; the
compiler-stage `nm` check stays on the production gate. Add the relevant focused
test262 directory or file set; do not run `quick-gate` first because
checkpoint already supersedes it.

**Phase close / release.** Use this only for final confirmation, release
evidence, or CI gates:

```bash
zig build engine-production-gate --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```

Run `zig build test-altrepr --summary all` when value representation
semantics changed, `zig build test-oom --summary all` when allocator/OOM
behavior changed, `zig build test -Dzjs_force_gc=true` when GC timing changed,
`zig build test -Dzjs_ownership_audit=true` when atom ownership changed, and
the performance gate when runtime-sensitive performance changed. Do not treat
these as checkpoint prerequisites.

### B.7 Durable Lessons

These rules remain active even though the historical detailed records have
been retired:

- Standard ECMAScript globals are engine bootstrap, not a separate builtins or
  intrinsics layer. Match QuickJS with hand-written standard-global installation,
  QJS-style function-list tables, and native function payloads carrying cproto /
  magic / function-pointer dispatch. Do not introduce a generic descriptor
  registry or facade to hide engine operations.
- Start from a reproducing validation command, then repair from its output.
- Interrupted or partial sweeps are not final validation evidence.
- Broad green gates do not prove semantic completeness when parser, emitter,
  or VM paths contain source-shaped shortcuts.
- Runner behavior must be checked against `test262.conf` before changing engine
  semantics for excluded files.
- Faithful QuickJS rewrite work favors source-aligned behavior over local
  micro-optimizations.
- When a broad suite crashes, isolate the smallest file or subdirectory
  before editing semantics.
- Partial stack-pop cleanup and post-pop call cleanup need separate
  ownership states.
- Standard builtin graphs contain real cycles; descriptor-faithful
  constructor/prototype links belong behind real cycle GC.
- Builtins that return existing objects must return retained values because
  VM call cleanup cannot distinguish borrowed and owned returns.

### B.8 Process Anti-Patterns

- Reporting interrupted command output as final validation.
- Marking work `validated` without a regression test.
- Hiding failures with broader excludes, weakened tests, or
  `catch unreachable`.
- Adding fixture-shaped recognition in parser, emitter, or VM paths to make
  gates green.
- Skipping or rewriting failing tests instead of fixing the cause.
- Treating "compiles + smoke green" as semantic completeness.

### B.9 Cross-References

- Operational rules: `AGENTS.md`.
- Contribution workflow: `CONTRIBUTING.md`.
- Compatibility boundary: `COMPATIBILITY.md`.
- Runtime limitations: `LIMITATIONS.md`.
- Test262 compatibility boundary: `test262.conf` and `test262/`.
- Fixture snapshots: `tests/fixtures/`.
