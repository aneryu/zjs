# Dependency Layering Rules

The binding rules are in `docs/fun_zjs_subtree_architecture.md` sections 4.1–4.3.

## Quick Visual Summary

```
primitives/  diagnostics/
      ^            ^
      |            |
      +------------+
           |
           v
        src/js/  (facade only — never grows zjs internals)
           |
           v
     src/runtime/vm/   <--- 唯一深耦合层 (the ONLY place that deeply understands zjs)
           |
           +---------------------+
           |                     |
           v                     v
   src/runtime/* (scheduler,   src/tooling/*
     modules, api, napi)         (cli, resolver, bundler, ...)
           |
           v
     platform/  (OS specifics)
```

## Key Invariant

No file outside `src/runtime/vm/` (plus the six explicitly listed test/bench/cli
locations) may contain the string `@import("zjs_engine")` or `@import("quickjs_zig_engine")`
or reach into `third_party/zjs/src/engine/*` directly.

An automated guard (wired into `zig build docs-check` / `check-layering`) plus
human code review enforce this.

See the full tables and rationale in the subtree architecture document.
