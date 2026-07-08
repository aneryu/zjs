# GUIDE.md — Project Development Guide

Last updated: 2026-05-27

This guide consolidates the stable engineering rules for this repository: the
C -> Zig 0.16.0 migration specification (formerly `SPEX.md`) and the validation
workflow for the QuickJS convergence effort. Historical plans, ledgers, and
decision logs have been removed from the active tree and remain available in
git history when needed.

`AGENTS.md` remains the operational rulebook (no shortcuts, build commands,
pre-commit checklist). This guide is the engineering rulebook. Current runtime
limitations and compatibility boundaries live in `LIMITATIONS.md` and
`COMPATIBILITY.md`.

---

## Part A. C → Zig 0.16.0 Migration Specification

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

### A.1 Type Mapping (C → Zig)

| C form | Zig recommendation | Notes |
|---|---|---|
| `char* + len` | `[]const u8` | Byte string / view |
| mutable buffer | `[]u8` | Writable slice |
| nullable pointer | `?*T` | May be null |
| non-null pointer | `*T` / `*const T` | Single non-null object |
| `void*` | `*anyopaque` / `?*anyopaque` | C boundary only |
| array pointer + len | `[]T` / `[]const T` | Prefer slices internally |
| C string | `[:0]const u8` / `[*:0]const u8` | NUL-terminated |
| ABI struct | `extern struct` | Guarantees C ABI |
| internal struct | `struct` | Plain Zig struct |
| bit layout struct | `packed struct` | Only when bit-level layout is required |

Hard rules:

- Do not retain `[*c]T` in internal code.
- Do not propagate `void*` internally.
- Do not use raw "pointer + length" as the primary internal interface.
- Convert C pointers to slices as soon as data enters Zig.
- Default to `[]const u8` for string parameters.

Recommended:

```zig
fn parse(input: []const u8) !Result { ... }
fn fill(buf: []u8) void { ... }
fn maybeUse(ptr: ?*Node) void { ... }
```

### A.2 Memory Management (Core)

Zig does not hide allocation. Every function that may allocate must declare
its allocator, ownership, and free responsibility.

**A.2.1 Allocation rule.** Functions that allocate must accept
`allocator: std.mem.Allocator`. Forbidden: secretly picking an allocator,
binding a global allocator inside a library, or returning memory without
documenting the free responsibility.

**A.2.2 Ownership.**

| Return type | Meaning |
|---|---|
| `[]u8` | owned; caller frees with the same allocator |
| `[]const u8` | usually borrowed view; not freeable unless documented otherwise |
| `*T` | lifetime ownership must be documented |
| `?*T` | same; may be null |

**A.2.3 Documentation.** Every allocating or borrow-returning function
documents ownership:

```zig
/// Returns owned memory. Caller must free with the same allocator.
fn buildMessage(allocator: std.mem.Allocator) ![]u8 { ... }

/// Returns a borrowed slice valid during self lifetime.
fn name(self: *const User) []const u8 { ... }
```

**A.2.4 `defer` / `errdefer`.** Bind cleanup immediately after allocation:

```zig
fn makeBuffer(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    @memset(buf, 0);
    return buf;
}
```

Caller side:

```zig
const buf = try makeBuffer(allocator, 4096);
defer allocator.free(buf);
```

**A.2.5 Rules.**

- Every `alloc` must have a planned free path.
- Caller-owned returns must document "caller owns".
- Free with the same allocator that allocated.
- Never return slices/pointers into stack memory.
- Never disguise arena-allocated values as long-lived owned objects.

**A.2.6 Allocator selection.**

| Scenario | Recommended allocator |
|---|---|
| Library code | injected by caller |
| CLI / short-lived flows | arena allocator |
| Bounded temporary buffer | fixed buffer allocator |
| C interop | `std.heap.c_allocator` (when needed) |
| Unit tests | `std.testing.allocator` |

**A.2.7 When emitting code, always state.**

- Where the allocator comes from.
- Who owns the return value.
- Who frees it.
- Whether error paths clean up.

### A.3 Error Handling

Internal Zig code must use `error{...}!T`, not C-style error codes.

**Standard internal form:**

```zig
const ParseError = error{ InvalidInput, Overflow };

fn parse(input: []const u8) ParseError!Result {
    if (input.len == 0) return error.InvalidInput;
    if (input.len > std.math.maxInt(i32)) return error.Overflow;
    return .{ .value = @intCast(input.len) };
}
```

**Hard rules.**

- Internal functions return explicit `error{...}!T`.
- Avoid `anyerror`; declare specific error sets.
- Do not use return-code + out-param style internally.
- Do not use `catch unreachable` without justification.

**Forbidden internal pattern.** `fn parse(input: []const u8, out: *Result) c_int`
is allowed only at C ABI boundaries.

**C boundary adapter:**

```zig
fn mapError(err: ParseError) c_int {
    return switch (err) {
        error.InvalidInput => -1,
        error.Overflow => -2,
    };
}

export fn parse_c(ptr: ?[*]const u8, len: usize, out: ?*Result) c_int {
    const p = ptr orelse return -1;
    const o = out orelse return -1;
    o.* = parseZig(p[0..len]) catch |err| return mapError(err);
    return 0;
}
```

Summary: explicit error sets internally; error codes only at C boundary;
C-style error handling does not flow back into Zig.

### A.4 C Interop

The migration goal is not "half-C/half-Zig everywhere" — it is to *contain*
the C ABI at a small number of boundary files.

**Recommended layout:**

```text
src/
  core.zig        # Pure Zig business logic
  memory.zig      # allocator / lifetime logic
  c_api.zig       # extern / export / C ABI adapters
  main.zig        # Executable entry
```

**Boundary layer (`c_api.zig`) owns:** `extern`, `export`, C pointer types,
C error codes, `void*` / `anyopaque`, ABI-compatible structs.

**Internal layers own:** slices, allocators, error sets, normal Zig
structs/enums/unions, resource lifetimes.

**Hard rules.**

- `[*c]T`, `void*`, errno-style codes stay at the boundary only.
- All boundary input is converted to Zig types as soon as it enters internal code.

**`translate-c` rules.** Use only for: importing headers, bootstrap, ABI
understanding. Never use raw `translate-c` output as final business code; review
macros, integer types, pointers, ABI, alignment, and any `[*c]T` it produces.

**Macro migration priority.**

1. Constant macros → `const`.
2. Simple function-like macros → `fn` or `inline fn`.
3. Type-related macros → `comptime` parameters or generic functions.
4. Complex macros that cannot be safely mapped → manual rewrite, no
   automatic translation.

**ABI struct rules.**

- Public-to-C structs use `extern struct`.
- Internal structs use plain `struct`.
- `packed struct` only when strict bit layout is required.
- Don't make every struct `extern` to "look like C".

### A.5 Zig 0.16.0 Specifics

The biggest migration risk is mixing in old version examples or master API.

**A.5.1 Version pinning.**

- Target: **Zig 0.16.0**.
- All API usage matches 0.16.0.
- Do not copy old blogs/issues/answers verbatim.
- Do not paste master-doc patterns into stable code.

**A.5.2 I/O model.** Use 0.16.0-style I/O; avoid old `std.io` patterns:

```zig
pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "hello world!\n");
}
```

- Avoid old `std.io.getStdOut().writer()` unless verified compatible.
- Functions needing I/O should accept it from `main(init: std.process.Init)`
  rather than rely on global I/O.

**A.5.3 `@cImport`.** Manage `translate-c` centrally in `build.zig`. Do not
scatter `@cImport` across business files.

**A.5.4 Containers.** 0.16.0 standard containers trend toward unmanaged /
explicit allocator forms. Verify the current API before use; do not copy old
`ArrayList` / map / queue examples.

### A.6 Build System (`build.zig`)

For non-trivial migrations, treat `build.zig` as project infrastructure.

**Responsibilities:** target / optimize, Zig modules, existing C sources,
include paths, compile flags / macros, libc / system library linkage,
`translate-c`, test/run/install steps.

**Migration phases.**

| Phase | Goal |
|---|---|
| 1 | Zig build owns the build, C sources still present. |
| 2 | Replace C files with Zig module by module. |
| 3 | Internal APIs Zig-ified, boundary layer shrinks. |
| 4 | Remove transitional C shims and `translate-c` artifacts. |

Strategy: get a stable Zig build first, migrate module by module, add tests
after each migration, layer changes (types → lifetime → errors → API tidy).

### A.7 Style

**Naming.**

- Functions: `camelCase`.
- Types: `TitleCase`.
- Variables: `snake_case`.
- Constants: readable per context; avoid blanket all-caps.
- Don't mechanically prefix private fields with underscores.

**Formatting.**

- 4-space indentation.
- Braces on the same line.
- Multi-element lists: one element per line with trailing commas.
- Always run `zig fmt .`.

**Code organization.**

- Small modules with clear responsibilities.
- ABI and business logic do not share a large file.
- Don't sacrifice Zig readability to "look like the original C".
- Lifetime clarity beats short code.

**Return values.** Zig forces non-`void` values to be used. Discard
explicitly:

```zig
_ = someValue;
```

Never silently discard error returns, allocation results, or container
operation results.

### A.8 Safety Rules (Hard)

**Strictly forbidden.**

- Returning stack memory references.
- Returning slices into local arrays.
- Implicitly leaking error-path resources.
- Propagating `[*c]T` in internal code.
- Using `catch unreachable` without proven safety.
- Disguising borrowed data as owned.
- Mixing allocators across alloc/free.
- Copying Zig examples without confirming the version.

**Special care.**

- Pointer lifetimes.
- Sentinel-terminated data.
- ABI alignment and field layout.
- Integer width differences between C and Zig.
- Mutable shared buffers under concurrency.

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

**Types & interfaces.**

- [ ] ptr+len converted to slices where possible?
- [ ] nullable / non-null distinguished correctly?
- [ ] C ABI structs marked `extern struct`?
- [ ] Internal structs avoid unnecessary `extern`?

**Memory & lifetime.**

- [ ] Allocating functions accept allocator?
- [ ] Return ownership documented?
- [ ] Every alloc has a free path?
- [ ] Error paths use `errdefer`?
- [ ] No stack memory escaped?

**Error handling.**

- [ ] Explicit error sets used?
- [ ] No stray `anyerror`?
- [ ] No internal out-param + error code?
- [ ] No unjustified `catch unreachable`?

**C interop.**

- [ ] `[*c]T` only at boundary?
- [ ] No `void*` / `anyopaque` leak into internals?
- [ ] `translate-c` results reviewed manually?
- [ ] Macros rewritten safely?

**Version & stdlib.**

- [ ] APIs confirmed for Zig 0.16.0?
- [ ] No old `std.io` usage?
- [ ] No outdated container examples?

**Toolchain.**

- [ ] `zig fmt .` ran?
- [ ] Debug tests pass?

```bash
zig fmt .
zig build quick-check --summary all
zig build test --summary all
# 阶段收口档位 / phase-close tier:
# zig build test-oom --summary all (OOM 注入门禁：corpus×注入+恢复金丝雀 / OOM injection gate: corpus x injection + recovery canaries)
```

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

**Inner loop.** Use this while optimizing or fixing a focused issue:

```bash
zig build zjs --summary all
zig build quick-check --summary all
zig build test262-smoke --summary all
git diff --check
```

Also run the focused Zig test filter, JS fixture, or `run-test262 -d` / `-f`
slice that directly reproduces the changed behavior.

**Checkpoint.** Use this before handing off a non-trivial code-bearing change:

```bash
zig build checkpoint-check --summary all
```

Add the relevant focused test262 directory or file set. Run the full Debug suite
separately when shared runtime/core semantics changed and the focused evidence
does not cover the blast radius.

**Phase close / release.** Use this only for final confirmation, release
evidence, or CI gates:

```bash
zig build engine-production-gate --summary all
zig build test -Doptimize=ReleaseSafe --summary all
```

Run `zig build test-altrepr --summary all` when value representation semantics
changed, `zig build test-oom --summary all` when allocator/OOM behavior changed,
and the performance gate when runtime-sensitive performance changed.

### B.7 Durable Lessons

These rules remain active even though the historical detailed records have
been retired:

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
- Compatibility boundary: `COMPATIBILITY.md`.
- Runtime limitations: `LIMITATIONS.md`.
- Test262 compatibility boundary: `test262.conf` and `test262/`.
- Fixture snapshots: `tests/fixtures/`.
