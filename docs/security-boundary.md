# Security Boundary

Production v1 targets trusted-code embedding. It does not claim hostile-code
sandboxing.

## Supported Assumptions

- JavaScript source is trusted or pre-vetted by the embedder.
- One runtime is used from one thread.
- The embedder owns OS isolation, process limits, filesystem policy, network
  policy, and wall-clock supervision.
- Native host functions are trusted and can compromise the process if written
  incorrectly.

## Engine Controls

The engine exposes memory limits, stack size, GC threshold, and cooperative
interrupt hooks. These controls are required for reliability and runaway-code
mitigation in trusted embeddings.

They are not a complete sandbox because they do not prevent all CPU starvation,
host API misuse, side channels, allocator fragmentation pressure, or bugs in
native host code.

## Out Of Scope For v1

- Running attacker-controlled JavaScript in-process.
- Cross-thread runtime use.
- Capability-secure module loading.
- Browser, Node.js, or Deno permission models.
- Deterministic execution across hosts.
- Hard real-time interruption.

## Required Release Language

Any Production v1 release notes must state:

`zjs` is a production-targeted embeddable JavaScript engine for trusted code.
It is not an in-process sandbox for hostile JavaScript.
