# GUIDE.md — Project Development Guide

Last updated: 2026-04-27

This guide consolidates the stable engineering rules for this repository: the
C → Zig 0.16.0 migration specification (formerly `SPEX.md`) and the durable
error workflow / reusable lessons from `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md`.
Active error records, open questions, and project status remain in:

- `docs/quickjs-redesign/TRACKING.md` — current phase board, validation log,
  decisions, risks, handoff notes.
- `docs/quickjs-redesign/ARCHITECTURE_REPAIR_PLAN.md` — architecture repair
  queue and follow-up status.
- `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md` — active error index and
  detailed records (`EAL-*`).

`AGENTS.md` remains the operational rulebook (no shortcuts, build commands,
pre-commit checklist). This guide is the engineering rulebook.

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
- [ ] ReleaseSafe tests pass?

```bash
zig fmt .
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
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

## Part B. Error Workflow And Lessons

This part captures the durable workflow and reusable lessons distilled from
the project's error ledger. Active records (open / parked / investigating)
remain in `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md`.

### B.1 When To Create An Error Record

Create a record when any of the following occurs:

- A validation command fails after implementation work has started.
- `run-test262` reports a new, changed, or fixed result vs. the known-error
  baseline.
- A crash, panic, stack overflow, allocator leak, OOM bug, or
  use-after-free is observed.
- Zig behavior differs from local QuickJS for an in-scope feature.
- A broad validation run is interrupted and could later be mistaken for
  final evidence.
- A failure reveals a reusable implementation, source-mapping, or test
  strategy lesson.
- A planned `out_of_scope` result needs explicit justification.

Do not create a full record for a typo or trivial local edit fixed before
validation. If the same mistake recurs, capture a learning record.

### B.2 Record IDs And Location

- IDs use `EAL-YYYYMMDD-NNN`.
- Long entries live under `docs/quickjs-redesign/errors/` and are linked from
  the index in `ERRORS_AND_LEARNINGS.md`.
- Short entries may live inline in the index.
- Use `docs/quickjs-redesign/templates/error-record.md` for detailed records.

### B.3 Status Vocabulary

- `open` — failure exists, not fully understood.
- `investigating` — reproduction or QuickJS comparison in progress.
- `fixed` — code changed, final validation evidence missing.
- `validated` — fix has regression test and validation evidence.
- `parked` — intentionally deferred to a named phase or dependency.
- `duplicate` — covered by another record.
- `out_of_scope` — outside selected QuickJS core scope.

### B.4 Classification Vocabulary

- `quickjs_parity_gap` — Zig differs from local QuickJS behavior.
- `zig_lifetime_bug` — ownership / refcount / use-after-free / double-free.
- `allocator_leak` — leak or accounting mismatch.
- `parser_gap` — lexer/parser accepts or rejects incorrectly.
- `emitter_gap` — parser succeeds but bytecode/metadata is wrong.
- `opcode_gap` — VM opcode handler missing or semantically wrong.
- `builtin_gap` — builtin behavior or descriptors differ from QuickJS.
- `runner_bug` — `run-test262`, smoke, compare, or CLI tooling wrong.
- `test_baseline_issue` — config, exclude, harness, known-error, oracle.
- `build_wiring` — build graph, module import, stale path issue.
- `docs_tracking_gap` — process failed to record status / evidence /
  handoff.
- `interrupted_validation` — command did not complete; not proof.
- `out_of_scope` — confirmed outside selected scope.

### B.5 Workflow

1. Capture exact symptom and command.
2. Classify failure and assign severity.
3. Compare against local QuickJS for semantic issues.
4. Identify QuickJS source owner and Zig owner.
5. Fix the smallest responsible subsystem.
6. Add or update focused regression tests before broad validation.
7. Update the relevant phase checklist and matrix row.
8. Add validation evidence to `TRACKING.md`.
9. Close the record only after regression test and gate evidence are
   recorded.
10. Promote reusable lessons into the Learning Log below.

### B.6 Learning Log

These are durable rules distilled from past error records. New lessons should
be appended here once promoted from `ERRORS_AND_LEARNINGS.md`.

| ID | Source | Lesson | Applies to | Enforcement |
|---|---|---|---|---|
| LRN-001 | prior validation work | Start from a reproducing validation command, then repair from its output. | bugfixes, parity work, test262 work | README update rules and error workflow |
| LRN-002 | prior interrupted runs | Interrupted or partial sweeps are not final validation evidence. | smoke, compare, test262 | validation log and `interrupted_validation` classification |
| LRN-003 | EAL-20260426-003 | Broad green gates are not semantic-completion proof when parser or VM paths recognize source text, test metadata, or fixture-only shapes. | parser, emitter, VM, test262 validation | Architecture repair guardrails and `parse_path` tracking |
| LRN-004 | prior run-test262 work | Runner behavior must be checked against `quickjs/run-test262.c` and `quickjs/test262.conf` before changing engine semantics for excluded files. | Phase 8 and test262 triage | test262 parity matrix |
| LRN-005 | prior parity work | Faithful QuickJS rewrite requires source-aligned behavior, not micro-optimizations dressed as parity. | all implementation phases | source mapping and matrix exit criteria |
| LRN-006 | prior runner perf work | Shared harness caches can add lock contention; prefer worker-local state unless evidence proves sharing is safe. | Phase 8 worker execution | test262 runner parity matrix |
| LRN-007 | prior broad-suite crashes | When a broad suite crashes, isolate the smallest file or subdirectory before editing semantics. | test262 triage, builtins, VM | error workflow reproduction step |
| LRN-008 | EAL-20260427-004 | Partial stack-pop cleanup must be disarmed before later fallible dispatch; otherwise normal cleanup and error cleanup can release the same values. | VM calls, constructors, variadic helpers | argument cleanup regression tests |
| LRN-009 | EAL-20260427-005 | Do not carry forward stale full-test262 claims after parser shortcut removal; rerun focused slices and record failures as blockers. | tracking, semantic queues, test262 validation | validation log + open EAL record |
| LRN-010 | EAL-20260427-006 | Standard builtin graphs contain real cycles; do not install descriptor-faithful back-links as retained refcount edges until cycle GC owns them. | builtin registry, object graph ownership, GC | WQ-014 graph/cycle regression before `prototype.constructor` restoration |
| LRN-011 | EAL-20260427-007 | Builtins that return an existing object must return a retained value; borrowed returns are indistinguishable from owned values to VM call cleanup. | object builtins, collection prototypes, host call dispatch | retained-return regression tests for object-returning builtins |

### B.7 Reusable Conclusions From Past Errors

These are condensed root-cause patterns. The full records live in
`ERRORS_AND_LEARNINGS.md`.

- **Smoke runner before output semantics (EAL-20260424-002).** Wiring a
  validation harness against a partially built engine is fine, but the first
  red gate is signal — do not soften the harness to make it pass; complete
  the underlying semantics. Phase 8 ran a real comparator that initially
  failed 45/45 because `print` did not exist; Phase 9 closed the gap by
  routing host output through normal global lookup and generic call.
- **Parser and VM fixture shortcuts (EAL-20260426-003).** Source-string
  recognizers, test262 metadata pre-compilers, and fixture-shaped opcodes
  let local gates pass without semantic correctness. Replace them with
  token/parser-driven early errors and lowering. Move builtin/domain
  semantics out of VM shortcut opcodes into shared object/property/call/
  builtin paths. Track narrow remaining work explicitly in follow-up
  queues, never as alternate successful parser paths.
- **Call argument cleanup double-free (EAL-20260427-004).** Stack-pop
  partial cleanup and post-pop call cleanup need separate ownership states.
  When later dispatch can return an error, disarm the partial-fill
  `errdefer` before normal argument-slice cleanup.
- **Test262 validation claims outpacing semantics (EAL-20260427-005).** Do
  not carry forward broad full-suite green claims after architectural
  changes (especially parser shortcut removal). Rerun focused slices and
  record failures as blockers in TRACKING.
- **Constructor/prototype back-links (EAL-20260427-006).** Standard JS
  builtin graphs contain real cycles. Adding descriptor-faithful retained
  back-links before cycle-GC owns them creates teardown-time leaks. Park
  this work behind the cycle-removal queue.
- **Borrowed-return double-free (EAL-20260427-007).** Builtins that return
  existing objects (e.g., `Object.defineProperty` returning the target) must
  return retained values. VM call cleanup cannot tell borrowed and owned
  apart, so a borrowed return becomes a free of a still-live object.

### B.8 Process Anti-Patterns

- Reporting interrupted command output as final validation.
- Marking a record `validated` without a regression test.
- Hiding failures with broader excludes, weakened tests, or
  `catch unreachable`.
- Adding fixture-shaped recognition (parser pattern matching, VM marker
  opcodes) to make gates green.
- Skipping or rewriting failing tests instead of fixing the cause.
- Treating "compiles + smoke green" as semantic completeness.

### B.9 Cross-References

- Operational rules: `AGENTS.md`.
- Architecture contract: `QUICKJS_REDESIGN_PLAN.md`.
- Active phase + validation log: `docs/quickjs-redesign/TRACKING.md`.
- Active error records: `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md`.
- Architecture repair queue: `docs/quickjs-redesign/ARCHITECTURE_REPAIR_PLAN.md`.
- Phase history (completed): `docs/quickjs-redesign/PHASES_HISTORY.md`.
- Coverage matrices: `docs/quickjs-redesign/matrices/`.
- Error record template: `docs/quickjs-redesign/templates/error-record.md`.
