# Limitations

`zjs` has reached its Production v1 Candidate status. It is designed for
semantic convergence, validation work, and production-grade Zig-native embedded
use cases, rather than a broad, general-purpose production JavaScript runtime
such as a full Node.js or Deno competitor.

## Runtime Boundary

- QuickJS remains the semantic reference, but this checkout no longer vendors a
  local `quickjs/` source tree.
- Compatibility is scoped to the active `test262.conf` profile and the
  focused regression tests in this repository.
- `zjs` is not a Node.js, Deno, browser, or drop-in `libquickjs` C API
  replacement.
- The engine-only Production v1 target is trusted-code embedding, not
  hostile-code sandboxing. See [docs/security-boundary.md](docs/security-boundary.md).

## CLI Lifecycle

The CLI intentionally has two lifecycle modes:

- Normal successful CLI execution lets the operating system reclaim process
  memory at exit. This keeps large test262 sweeps from being dominated by
  deinitialization and avoids turning still-maturing cleanup assertions into
  false conformance failures.
- `--leak-check` runs the full engine deinitialization path and enables Zig
  allocator validation. Use it for ownership work and leak investigations.

In-process tests and embedding-style paths should still deinitialize normally
and should not rely on process exit for cleanup.

## GC Limitations

- Reference counts are non-atomic. A runtime and its values are thread-affine.
- The collector is non-moving. Embedders must still treat raw object pointers as
  runtime-owned and must not keep them without a `JSValue.Persistent` handle or
  documented native payload ownership.
- GC safe points are explicit. New VM or host APIs that allocate must root
  temporaries before polling GC.
- Changes that touch weak edges, finalizers, descriptors, or object graphs need
  focused leak/lifetime tests plus the relevant smoke or test262 slice.

## Standard Library and Host APIs

- No Node.js or Deno standard modules are provided.
- There is no QuickJS-style `qjs:std`/`qjs:os` layer; the legacy implementation
  was removed (git history has it). Host capabilities are added through the
  external host-function registry instead.
- There is no stable JavaScript FFI for loading arbitrary C, C++, or Zig
  libraries.
- Host APIs such as Fetch, Streams, WebCrypto, DOM, and browser event-loop
  integration are outside the current core-engine scope.

## Modules

ECMAScript modules and binary module imports (using `import ... with { type: "bytes" }`)
are supported within the local validation boundary. CommonJS `require`,
`node_modules` resolution, package exports/import maps, and hybrid Node-style
module loading are not supported.

## Regular Expressions

Match arrays still eager-copy capture strings (QuickJS `js_sub_string`).

## Proper Tail Calls

- Proper tail calls are **strict-mode only** (per ES2015 14.6) and cover
  plain-call tails: `return f(...)` directly, and calls whose control flow
  provably reaches `return` next (conditional-expression arms and short
  unconditional-jump joins). Those fold to `tail_call` plus a leftover
  `return` stub and reuse the caller frame — compat-table direct and mutual
  recursion (1e6) stay in constant stack, and the reused caller drops off
  `Error.prototype.stack`. This is a deliberate divergence from the pinned
  QuickJS, which grows a frame for every call.
- Sloppy-mode code, method tails (`o.m()` / `this.m()`), constructor
  completions, calls protected by a live `try`, and L0 host entries all
  still grow a logical frame, exactly like QuickJS: deep recursion there
  throws catchable `InternalError: stack overflow`.
- Infinite strict `return f()` therefore does not overflow; a test that
  needs a catchable overflow must use sloppy mode or a non-tail shape
  (`return 1 + f()` or `return this.m()`).
- `tail-call-optimization` remains skipped in `test262.conf` (method-position
  tails are not proper tail calls here). Method-position deep tails are
  guarded by focused Zig fixtures (`tco-member-args.js` is a plain call).

## Performance

The public QuickJS comparison is the bench-v8 composite score in
[docs/perf/bench-v8-status.md](docs/perf/bench-v8-status.md). That headline is composite-score
parity, not every-benchmark parity.

There is no checked performance gate: benchmark, single-script, and
runtime-profile artifacts are all diagnostic. Do not treat external-process
microbench timings as a semantic compatibility signal.

Per-opcode profiling requires the dedicated profiling build
(`zig build zjs-profile`). The default `zjs` binary does not collect opcode
counts and fails closed on `--profile-opcodes`.

## Documentation Scope

Historical phase plans, snapshot ledgers, and one-off audits are not active
documentation. Durable evidence should live with the owning code change, issue,
or PR. Add a new design document only when it describes an ongoing contract
that future code must follow.
