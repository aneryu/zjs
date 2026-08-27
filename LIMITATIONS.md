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
  hostile-code sandboxing. See the Security Boundary section below.

## Security Boundary

Production v1 targets trusted-code embedding. It does not claim hostile-code
sandboxing.

Supported assumptions:

- JavaScript source is trusted or pre-vetted by the embedder.
- One runtime is used from one thread.
- The embedder owns OS isolation, process limits, filesystem policy, network
  policy, and wall-clock supervision.
- Native host functions are trusted and can compromise the process if written
  incorrectly.

The engine exposes memory limits, stack size, GC threshold, and cooperative
interrupt hooks. These controls are required for reliability and runaway-code
mitigation in trusted embeddings. They are not a complete sandbox because
they do not prevent all CPU starvation, host API misuse, side channels,
allocator fragmentation pressure, or bugs in native host code.

Out of scope for v1: running attacker-controlled JavaScript in-process,
cross-thread runtime use, capability-secure module loading, browser /
Node.js / Deno permission models, deterministic execution across hosts, and
hard real-time interruption.

Any Production v1 release notes must state: `zjs` is a production-targeted
embeddable JavaScript engine for trusted code. It is not an in-process
sandbox for hostile JavaScript.

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

Match-array captures are still eager copies (QuickJS `js_sub_string`), not
zero-copy views. Short latin1 slices (length 2..32) may be interned and
reused; longer slices and UTF-16 still allocate a fresh copy.

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

The public QuickJS comparison is the bench-v8 composite-score ratio in
[docs/perf/bench-v8-status.md](docs/perf/bench-v8-status.md); the current
value and its reference binary are recorded there (the Octane-2.0 reading
has not yet gone through an owner ruling to become the published metric).
The headline is a composite-score ratio, not every-benchmark parity.

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
