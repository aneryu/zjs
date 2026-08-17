# Refactor Tax Policy

This repository prices file-level reorganization as a real performance tax.
The three rules below are the policy.

1. Do not start a dedicated refactor campaign whose goal is "split files" or
   "lower complexity." Split a file only as a side effect of a functional
   change that already has to touch it.
2. Any split or move that involves a hot-path file (for example the call
   chain, array/property runtime, or the dispatch core) must pass a 15-item
   zoo A/B before merge: at least 3 layout pads, median with no regression.
3. Pure test-harness and build-graph splits have no layout risk and are
   exempt from rule 2.

## Why

The 0.1.0 CHANGELOG records QCP-1B: shrinking `CompileContext` by one unused
pointer perturbed Zig 0.16 whole-program native layout and caused a crypto
regression, even though bytecode and allocation streams stayed identical.
Benchmark scores in this repository are sensitive to file-level
reorganization. "Maintainability refactors" carry a real performance tax here
and must be priced.
