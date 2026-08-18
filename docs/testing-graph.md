# Testing Graph

How compile roots, scoped test targets, and validation steps fit together.
The executable build graph in `build/` is the authority; this document
describes the conventions that graph encodes.

## Compile-root chain

Three roots, each a superset of the one above it:

| Root | Role |
|---|---|
| `src/root.zig` | Public embedder facade. Does not export `config_signature`. |
| `src/internal_root.zig` | Engine + CLI surface. Adds binding `Object`, `Descriptor`, `Atom`, `config_signature`. |
| `src/all_tests.zig` | Unified suite. Re-exports every `internal_root` name and overlays public-surface mirrors. |

`all_tests` asserts at runtime that every public declaration on
`internal_root` is reachable on `all_tests` and identical, except for an
explicit exception table. The only exception today is `Object`: the public
type is an opaque facade, the internal type has `create`.

The production `zjs` / `run-test262` artifacts compile against
`internal_root`. The unified `test` step compiles against `all_tests`.
`test-embedding` is the one artifact that compiles the public `src/root.zig`
module as `zjs`.

## Two shell classes

A test artifact's *root source file* decides how it may import the engine.
Mixing the two styles is a `file exists in two modules` compile error.

### Class A: relative-path roots

The root already spans the engine subtree by relative import
(`runtime/root.zig`, `compiler_v2/root.zig`). It must **not** `@import("zjs")`.
Attest with the relative spelling:

```zig
comptime {
    @import("config_signature.zig").attest("test-runtime");
}
```

Today: `src/runtime_tests.zig`, `src/compiler_v2_tests.zig`.

### Class B: `zjs`-module roots

The root pulls the engine only through the `zjs` module. It must **not**
relative-import any engine file. Attest with:

```zig
comptime {
    @import("zjs").config_signature.attest("test-exec");
}
```

Thin shells live under `src/` so relative imports cannot walk out of the
module root. Today: `src/core_tests.zig`, `src/parser_tests.zig`,
`src/bytecode_tests.zig`, `src/exec_tests.zig`, `src/builtins_tests.zig`,
`src/runner_tests.zig`, and `src/embedding_tests.zig` (see attest exception
below).

### Independent options (rule C)

Every engine-bearing module gets its own `addOptions` object. Reusing one
options object across a Debug artifact and a ReleaseFast artifact is how a
test binary would attest the wrong `optimize` field.

### `helpers.zig` (rule D)

`src/tests/helpers.zig` `@import("zjs")` internally. Only Class-B roots may
consume it. Class-A roots (`compiler_v2/tests.zig`, in-tree runtime tests)
must never import it.

## Attest matrix

| Artifact | How it attests | Notes |
|---|---|---|
| `zjs` / `zjs-profile` / `zjs-dev` | `src/cli/zjs.zig` → `engine.config_signature.attest("zjs CLI")` | |
| `run-test262` / `run-test262-dev` | `src/cli/run_test262.zig` attests `"run-test262 / test-runner"` | |
| unified `test` | `all_tests` attests `"unified-tests (src/all_tests.zig)"` | Follows `-Doptimize` |
| scoped Class-B shells | `@import("zjs").config_signature.attest("test-X")` | Debug-pinned |
| scoped Class-A shells | `@import("config_signature.zig").attest("test-X")` | Debug-pinned |
| `test-runner` shell | attests the same string as `run_test262.zig` | Two attestations of one value are harmless |
| `test-embedding` | **does not attest** | Public module does not export `config_signature`; same choice as the plugin fixtures |
| `test-oom` | `tests/oom.zig` attests `"oom-tests"` | |

## Filter naming

Each scoped target is `src/<area>_tests.zig` × a trailing-dot filter:

| Target | Root | Filter |
|---|---|---|
| `test-core` | `src/core_tests.zig` | `tests.core.` |
| `test-parser` | `src/parser_tests.zig` | `tests.parser.` |
| `test-bytecode` | `src/bytecode_tests.zig` | `tests.bytecode.` |
| `test-exec` | `src/exec_tests.zig` | `tests.exec.` |
| `test-builtins` | `src/builtins_tests.zig` | `tests.builtins.` |
| `test-runtime` | `src/runtime_tests.zig` | `runtime.` |
| `test-runner` | `src/runner_tests.zig` | `cli.run_test262.` |
| `test-compiler-v2` | `src/compiler_v2_tests.zig` | `compiler_v2.` |
| `test-embedding` | `src/embedding_tests.zig` | `tests.embedding_examples.` |

The trailing dot is the namespace boundary. `test-embedding` uses an
independent Debug `zjs` module rooted at `src/root.zig` and hangs on
`engine-production-gate`, not checkpoint.

## Step naming

| Suffix | Meaning | Examples |
|---|---|---|
| `-gate` | Aggregate validation gate | `quick-gate`, `checkpoint-gate`, `engine-production-gate` |
| `-check` | Single check | `config-signature-check`, `test262-check`, `perf-self-check` |
| (none) | Build or run | `zjs`, `test`, `smoke`, `test-core` |

### Deprecated aliases

Removed next release. Each alias `dependOn`s the new step.

| Old | New |
|---|---|
| `quick-check` | `quick-gate` |
| `checkpoint-check` | `checkpoint-gate` |
| `test262-gate` | `test262-check` |
