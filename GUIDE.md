# GUIDE.md — Project Development Guide

Engineering rules and command reference for the Zig JavaScript / TypeScript
engine. Read the sections relevant to the change.

[AGENTS.md](AGENTS.md) defines task execution; [verification-policy](docs/verification-policy.md)
defines verification obligations. ECMA-262 governs JavaScript semantics;
QuickJS comparisons inform diagnosis and performance, not implementation form.

## Part A. Zig Engineering Rules

### A.0 Core Principles

1. Internal code must be Zig-style, not "C with syntax sugar".
2. Ownership must be explicit: whoever allocates, releases.
3. Errors must be explicit: error sets, not implicit error codes.
4. Pointers must converge: prefer slices internally.
5. C ABI exists only at boundary layers.

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
- Document API mappings and ABI assumptions where boundary code relies on them.

### A.5 Zig 0.16.0

- Pin **Zig 0.16.0**. Do not copy old blogs or master-doc patterns.
- Use 0.16.0 I/O (`std.Io`, `main(init: std.process.Init)`). Do not copy
  old `std.io.getStdOut()` or old managed-container examples.
- Keep `@cImport` centralized in `build.zig`.

### A.6 Build System

- `build.zig` owns target / optimize, modules, remaining C, flags,
  `translate-c`, and test / install steps.
- Keep build changes with the module they affect and test the owning target.

### A.7 Style

- Functions `camelCase`, types `TitleCase`, variables `snake_case`.
  4-space indent. Run `zig fmt` on changed Zig files.
- Default bindings to `const`; use `var` when mutation is required.
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
    (e.g. `HostScheduler.traceRoots`).
- Ownership suffixes (`*Owned` / `*Borrowed`) are annotations for
  counter-intuitive cases only; most functions follow the A.2 ownership
  rules without a suffix, so the **absence** of a suffix carries no
  ownership information.
- No unmarked helper duplication. When a helper must be re-implemented in
  another layer (e.g. layering forbids the import), the copy carries a
  `// mirror of <owner>, keep in sync` comment; otherwise reuse or forward
  to the single owner.
- Sort with `std.sort.heap` unless stability is observable. Use
  `std.mem.sort` only when distinguishable equal elements must retain order;
  document that requirement at the call site.
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

## Part B. Validation And Tracking Workflow

### B.1 What To Record

Keep the reproducer, source/configuration identity, command exit status,
relevant output, and unresolved findings with the owning change, issue, or PR.
Record interrupted runs explicitly. Historical results do not validate the
current tree; typo-only fixes need no separate evidence ledger.

### B.2 Durable Decisions

Update the relevant contract when changing object/finalizer or GC rules,
module semantics, public APIs/CLI, or runner behavior. Explain deliberate
QuickJS divergences against the spec. Temporary investigation notes belong
with the task, not in a new project-wide status file.

### B.3 Status Vocabulary

| Status | Meaning |
| --- | --- |
| `open` | Work or failure not yet understood |
| `investigating` | Reproduction or diagnosis underway |
| `in_progress` | Implementation started |
| `blocked` | Named dependency or decision prevents progress |
| `validated` | Relevant regression and command evidence recorded |
| `parked` | Deferred for a named reason |
| `superseded` | Replaced by a newer task, decision, or implementation |
| `out_of_scope` | Outside the agreed task or product boundary |

These describe implementation progress. For ticket triage, use `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, or `wontfix` separately.

### B.4 Classification Vocabulary

Use an existing label when it fits; a reference difference alone is not proof
of a spec violation.

| Label | Meaning |
| --- | --- |
| `semantic_gap` | Behavior violates the applicable language specification |
| `quickjs_parity_gap` | Difference from pinned QuickJS requiring classification |
| `object_model_gap` | Incorrect object, class, payload, exotic, or property behavior |
| `cycle_gc_gap` | Incomplete tracing, cycle collection, finalization, or weak edges |
| `module_semantics_gap` | Incorrect parse, link, resolve, namespace, or evaluation behavior |
| `parser_gap` | Incorrect lexer/parser acceptance |
| `emitter_gap` | Incorrect bytecode or metadata after parsing |
| `opcode_gap` | Missing or incorrect VM operation |
| `builtin_gap` | Builtin behavior or descriptors violate the spec |
| `lifetime_bug` | Rooting, use-after-free, leak, or double-free |
| `runner_bug` | Incorrect runner, smoke, comparison, or CLI tooling |
| `docs_tracking_gap` | Missing or incorrect documentation/evidence |
| `interrupted_validation` | Incomplete command; no passing verdict |

### B.5 Workflow

Follow [AGENTS.md](AGENTS.md): reproduce, identify the owner, fix the mechanism,
add focused coverage, validate, and report the result. For JavaScript semantics,
compare the focused probe with pinned QuickJS and resolve disagreements against
ECMA-262. TypeScript behavior follows the supported scope in
[LIMITATIONS.md](LIMITATIONS.md) and the parser contract.

### B.6 Validation Tiers

[Verification policy](docs/verification-policy.md) determines which checks are
required. This section explains the instruments; it adds no gates.

**Inner loop.** Default builds use Debug:

```sh
zig build check
mise run test-fast -- 'test-name substring'
```

`test-fast` uses the unified test root and compile-time `--test-filter`.
Missing, empty, or unmatched filters fail. Use fully qualified substrings
such as `tests.exec.` or `src.compiler.tests.`; titles containing `:` are
unreliable filters. Changing the filter requires a new compile. Do not add
separate subsystem compile roots. `zig build test -Dtest-filter=<substring>`
is another filtered diagnostic selection.

For a CLI reproducer, build with `zig build zjs`. For a test262 reproducer,
build its separate runner first, then select the relevant directory (`-d`)
or file (`-f`); an old executable under `zig-out/bin` is not fresh evidence:

```sh
zig build run-test262
./zig-out/bin/run-test262 -c test262.conf -d test262/test/built-ins/RegExp
```

**Per-change close-out.** After implementation stabilizes:

```sh
zig build test
git diff --check
```

`test` runs the engine suite (`test_root.zig`) and CLI tests
(`src/cli/tests.zig`). Full tests strip DWARF by default; use
`-Dtest-strip=false` for symbolic full-suite failure stacks. Filtered tests
and `test-fast` keep DWARF. The build/test seed defaults to `0`; CLI `--seed`
is unnecessary. Use `-Dzjs_test_seed=<u32>` for explicit randomized runs.
Preserve exit status when piping output.

**Aggregate checks.** Invoke gates through mise so they use the configured
build worker count. Select the aggregate required by the policy; do not run
its subsets again as prerequisites.

| Command | Coverage / use |
| --- | --- |
| `mise run quick-gate` | CLI/runtime smoke beyond the focused test; no test262 runner |
| `mise run checkpoint-gate` | Debug suite, GC-stress rerun, CLI smoke, sema-only public-root embedding check |
| `mise run batch-gate` | Debug checkpoint, then ReleaseFast test262; once per merge batch |
| `mise run batch-gate-profile` | Batch gate plus ReleaseFast CLI/profile smoke |
| `mise run production-gate` | ReleaseFast suite, smoke, embedding tests, and test262 for release |

Debug results do not replace production validation. Full test262 is a
zero-failure batch/CI gate, not a per-edit loop. Local results are written to
`reports/test262-latest/`; do not stage generated reports unintentionally.

**Diagnostics.** Use the tool matching the changed invariant or failure;
consult the policy and [release checklist](docs/release-checklist.md) for
required release coverage.

| Command | Purpose |
| --- | --- |
| `zig build test -Doptimize=ReleaseSafe --summary all` | Optimized code with safety checks |
| `zig build test-oom --summary all` | Allocation-failure injection and cleanup |
| `zig build test-leak-census --summary all` | Allocation-leak census |
| `zig build test -Dzjs_ownership_audit=true --summary all` | Borrowed-atom ownership audit |
| `zig build test -Dzjs_force_gc=true` | GC-timing diagnosis; not a gate |

ReleaseSafe, OOM, leak-census, and ownership-audit checks also run in nightly
CI. Targeted local runs provide feedback on the corresponding changes.
Performance and size tools are diagnostic; retired gates are listed only in
the verification policy.

### B.7 Durable Lessons

- Standard globals are engine bootstrap using native records and function
  lists. Preserve this layer boundary; do not add a generic descriptor
  registry to hide engine operations.
- Partial stack-pop cleanup and post-pop call cleanup need distinct lifetime
  states. Builtin results must remain reachable through VM call cleanup.
- Constructor/prototype cycles require real traced edges. Follow
  [GC invariants](docs/gc-invariants.md) and public handle rules, not historical
  reference-counting conventions.
- Check runner selection before changing engine semantics for an excluded
  case. Isolate broad failures to the smallest reproducer.

- Worktrees share Git refs and the stash stack. Transfer work with named commits
  or patches; keep concurrent edits and build outputs isolated.
- Hot-path moves and type-layout changes can alter native code generation even
  when bytecode is unchanged. Split by ownership or dependency, not line count.

Other contracts: [documentation index](docs/README.md).

### B.8 Performance Investigation

Performance tools are diagnostic, not additional merge gates. For a claim,
record source revision and dirty state, build configuration, immutable binary
hashes, host/compiler, workload, output checksum, measurement window, raw
samples, and process exit status. Do not measure a binary another build can
replace; record affinity and PMU selection when used.

Compare equal work under controlled conditions. Include startup, parsing,
warmup, and teardown only when they belong to the claim. Shared-resource
interference can invalidate attribution. Fewer instructions, smaller code,
or a faster microbenchmark alone do not prove a workload-level speedup.
Count event frequency and inspect call/address context before assigning cost
to a symbol. Historical results and inconclusive runs are not current passes.
