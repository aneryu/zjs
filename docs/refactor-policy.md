# Refactor Tax Policy

This repository prices file-level reorganization of hot-path code as a real
layout tax. That lesson stands. The mandatory measurement protocol that used
to price it does not.

> **Owner ruling 2026-09-18.** Rule 2's bench-v8 A/B, the identity-set
> protocol, and the Stage 0 / size-screen / field-lock instruments are
> retired with the measurement and ablation policy. Hot-path work lands
> under the ordinary validation ladder in
> [verification-policy.md](verification-policy.md).

1. Maintainability refactors proceed by risk zone. COLD-zone work — docs,
   build graph, test harnesses, tools, dead-asset removal, and files outside
   the hot path — may proceed freely under the normal validation ladder.
   HOT-zone work (the call chain, array/property runtime, the dispatch core,
   `src/parser.zig`, `src/bytecode.zig`, `src/core/object.zig`) is still
   tracked in [backlog.md](backlog.md) and should land item by item, not as
   an unpriced sweep.
2. A split, move, or rename that involves a hot-path file is a layout risk.
   The 0.1.0 CHANGELOG records QCP-1B: shrinking `CompileContext` by one
   unused pointer perturbed Zig 0.16 whole-program native layout and caused
   a crypto regression, even though bytecode and allocation streams stayed
   identical. There is no remaining pre-registered score or `.text`-set
   gate; `zig build test` and the merge batch are the merge authority.
3. Pure test-harness and build-graph splits have no layout risk.

Local `perf stat` remains available as a diagnostic. It does not
adjudicate merges.
