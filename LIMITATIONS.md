# Limitations

`zjs` has reached its Production v1 Candidate status. It is designed for
semantic convergence, validation work, and production-grade embedded use cases, rather than a broad, general-purpose production JavaScript runtime (such as a full Node.js/Deno competitor).

## Runtime Boundary

- QuickJS remains the semantic reference, but this checkout no longer vendors a
  local `quickjs/` source tree.
- Compatibility is scoped to the active `test262.conf` profile and the
  focused regression tests in this repository.
- `zjs` is not a Node.js, Deno, browser, or general-purpose production QuickJS replacement.
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
  runtime-owned and must not keep them without a `PersistentValue` or documented
  native payload ownership.
- GC safe points are explicit. New VM or host APIs that allocate must root
  temporaries before polling GC.
- Changes that touch weak edges, finalizers, descriptors, or object graphs need
  focused leak/lifetime tests plus the relevant smoke or test262 slice.

## Standard Library and Host APIs

- No Node.js or Deno standard modules are provided.
- QuickJS-style `qjs:std` and `qjs:os` support exists only where the current
  engine and tests require it.
- There is no stable JavaScript FFI for loading arbitrary C, C++, or Zig
  libraries.
- Host APIs such as Fetch, Streams, WebCrypto, DOM, and browser event-loop
  integration are outside the current core-engine scope.

## Modules

ECMAScript modules are supported within the local validation boundary. CommonJS
`require`, `node_modules` resolution, package exports/import maps, and hybrid
Node-style module loading are not supported.

## Performance

The checked-in microbench reports are historical artifacts from the previous C
QuickJS comparison toolchain.

Performance is uneven by subsystem:

- Wins in that report include global read loops, cached RegExp tests,
  array-map callbacks, and string-keyed Map workloads.
- Slower areas in that report include dense array write/read, integer sums,
  monomorphic and prototype property reads, URI decoding, and some function
  call loops.

Do not infer production performance from the external-process microbench alone;
it includes startup cost and is meant for local regression tracking.

## Documentation Scope

Historical phase plans, snapshot ledgers, and one-off audits are not active
documentation. Durable evidence should live with the owning code change, issue,
or PR. Add a new design document only when it describes an ongoing contract
that future code must follow.
