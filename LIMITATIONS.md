# Limitations

zjs is a JavaScript / TypeScript engine for trusted-code embedding in Zig.
This page defines product boundaries; dated validation results live in
[STATUS.md](STATUS.md).

## Runtime Boundary

- Compatibility is scoped to [the validation profile](COMPATIBILITY.md) and
  focused regressions. ECMA-262 governs JavaScript semantics; QuickJS is a
  comparison reference, with no vendored `quickjs/` source tree.
- Node.js, Deno, browser APIs, and the `libquickjs` C ABI are outside scope.
- Each runtime and its values belong to one owner thread.

## TypeScript

The parser accepts `.ts`, `.mts`, and `.cts` directly. It erases type-only
syntax and lowers supported runtime constructs: enums, namespaces, parameter
properties, and `import x = A.B` aliases. It does not perform type checking
or replace `tsc`.

JSX (`.tsx`), decorators, `import x = require()`, and `export =` are outside
scope. Detailed parsing rules are in the
[TypeScript parser design](docs/parser-ts-first-class-design.md).

## Debugging

A Chrome DevTools Protocol inspector/debugger is not implemented. Breakpoints,
stepping, call stacks, and scope inspection remain planned capabilities.

## Security Boundary

Production v1 targets trusted or pre-vetted source, not hostile-code sandboxing.
The embedder owns OS isolation, process/filesystem/network policy, and
wall-clock supervision. Native host functions are trusted code.

Memory limits, stack limits, GC thresholds, and cooperative interrupts improve
reliability. They do not prevent all CPU starvation, host API misuse, side
channels, allocator fragmentation, or native-code bugs.

Out of scope: attacker-controlled JavaScript in-process, cross-thread runtime
use, capability-secure module loading, browser/Node/Deno permission models,
deterministic execution across hosts, and hard real-time interruption.
Release notes must state the trusted-code boundary.

## CLI Lifecycle

- Successful CLI execution normally leaves process-memory reclamation to the
  OS. `--leak-check` performs full engine teardown and allocator validation.
- In-process tests and embedders must deinitialize normally; process exit is
  not their cleanup mechanism.

## GC Limitations

- The tracing collector is non-moving; it does not use heap reference counts.
- Raw object pointers remain runtime-owned. Host values need local handles
  while in use and persistent handles across calls/ticks, or the documented
  native-payload tracing protocol.
- Allocation-capable VM/host paths must root temporaries before GC safe points.
- Weak edges, finalizers, descriptors, and object-graph changes need focused
  lifetime coverage and the verification required for the affected behavior.

See [GC invariants](docs/gc-invariants.md) and the
[public API contract](docs/public-api-contract.md) for ownership details.

## Standard Library and Host APIs

No Node.js/Deno modules, `qjs:std`/`qjs:os`, or stable JavaScript FFI for
arbitrary C/C++/Zig libraries are provided. Host functions supply application
capabilities. Fetch, Streams, WebCrypto, DOM, and browser event-loop integration
are outside the core-engine scope.

## Modules

ECMAScript modules and binary imports (`import ... with { type: "bytes" }`)
are supported within the validation profile. CommonJS `require`, `node_modules`
resolution, package exports/import maps, and hybrid Node-style loading are not.

## Proper Tail Calls

- Strict-mode plain-call tails reuse the caller frame: direct `return f(...)`
  and calls whose control flow reaches `return` through conditional arms or
  short unconditional jumps. The reused caller drops off `Error.prototype.stack`.
  This differs deliberately from pinned QuickJS's frame growth.
- Sloppy code, method tails (`o.m()` / `this.m()`), constructors, live-`try`
  protected calls, and L0 host entries still grow logical frames. Deep recursion
  there throws catchable `InternalError: stack overflow`.
- Infinite strict `return f()` therefore does not overflow. Overflow tests need
  sloppy mode or a non-tail shape such as `return 1 + f()` or `return this.m()`.
- `tail-call-optimization` remains skipped in `test262.conf` because method tails
  are not implemented. Focused Zig fixtures cover the boundary;
  `tco-member-args.js` exercises a plain call.

## Performance

Historical bench-v8 comparisons are available in Git history and apply only
to their recorded configurations. They establish neither per-benchmark parity
nor a performance merge gate. Local measurements are diagnostic.

Per-opcode counts require `zig build zjs-profile`; the default CLI rejects
`--profile-opcodes`. See [GUIDE](GUIDE.md#b8-performance-investigation).
