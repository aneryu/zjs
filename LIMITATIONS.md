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

## Proper Tail Calls

- Plain `tail_call` sites (including tail-position direct `eval` calls that do
  not resolve to %eval%) run as real tail-call optimization through frame
  reuse: logical call depth stays constant. `test262.conf` enables the
  `tail-call-optimization` feature.
- Tail targets that still take the recursive slow path, where deep tail
  recursion grows the native stack: L0 frames (generator/eval shells),
  arrow / class-constructor / cross-realm callees, and `tail_call_method`.
  Arrow inlining and `tail_call_method` frame reuse are scheduled as R5
  roadmap Phase 7. The class-constructor exclusion is spec-correct: calling a
  class constructor without `new` throws TypeError, so no deep recursion
  exists there.
- Failure shape: the recursive path is protected by the dual depth guard
  (native depth `max(16, stack_limit / 16384)` plus the logical depth limit)
  and throws RangeError when exceeded — it is not a crash. The consequence is
  that spec-legal deep tail recursion in method/arrow position hits RangeError
  early, deviating from PTC's constant-stack semantics.
- Note: test262 has no coverage for deep tail recursion in method/arrow
  position (`tco-member-args.js` actually contains a plain call), so a green
  gate is not evidence for those shapes.

## Performance

Performance is uneven by subsystem. The checked performance gate is a ZJS
self-baseline regression check, and single-script/runtime-profile artifacts are
diagnostic. Do not treat external-process microbench timings as a semantic
compatibility signal.

## Documentation Scope

Historical phase plans, snapshot ledgers, and one-off audits are not active
documentation. Durable evidence should live with the owning code change, issue,
or PR. Add a new design document only when it describes an ongoing contract
that future code must follow.
