# Host boundary design

Status: migration in progress, based on the 2026-09-23 working tree. The user
approved removing public `zjs.EventLoop` / `zjs.runtime`. The internal build
module, event scheduling, filesystem policy, print/console, and
btoa/atob/queueMicrotask/gc extraction are implemented. Validation evidence
must be read separately from the remaining target below.

The first extraction preserves both existing module scheduler paths. Source
policy now crosses `core/module_source.zig`; it does not replace file-backed
TLA scheduling with the older HostHooks evaluator. Unifying those evaluators,
extracting the remaining navigator/performance/DOMException compatibility
extensions and CommonJS/Wasm source adaptation, and eliminating the residual
host-specific Runtime fields remain separate work. This is not a claim that
all non-ECMAScript code has left the engine.

## First extraction verification

Validated on Linux with mise-managed Zig 0.16.0, Debug configuration:

- `zig build check` passed; CLI, runner, and profiling artifacts built.
- Host/module focused tests passed 133/133; independent embedding tests
  passed 14/14; executable smoke tests passed 5/5.
- Final `zig build test` exited successfully: 2007/2007 tests passed
  (1949 unified and 58 CLI).
- The focused test262 import.meta/dynamic-import run prepared 963 cases:
  621 passed, 342 feature-skipped, and zero errors.
- Source import inspection found no reverse dependency from the engine
  into `zjs_host`; documentation links and `git diff --check` passed.

The full test run still emitted two `ATOM AUDIT stale edge` diagnostics
from `gc stress deterministic tiny heap preserves live roots`. A direct
run of the unified binary confirmed the emitting test and successful exit;
these diagnostics are unresolved, not evidence of a clean GC audit.
No release/merge aggregate gate or performance claim is made here.

Executable validation also exposed missing allocation-count debits in the
non-audit bitmap reclaim path: Debug programs could reach Runtime teardown
with zero live bytes and nonzero allocation count. The bulk reclaim path
now debits the reclaimed count, and a CLI leak-check smoke regression covers
the executable configuration that unit-test audit accounting does not use.

## Ownership and dependencies

The engine owns JavaScript / TypeScript execution. The bundled host owns
the concrete environment used by the `zjs` CLI and `run-test262`.

```text
zjs CLI --------+----> zjs_host ----> zjs engine
run-test262 ----+                       ^
external embedder ----------------------+
```

`zjs_host` is an internal build module rooted at `src/host/root.zig`, not a
new public package export. Production consumers are the two programs and
their CLI variants; their tests may also import it. Each host module imports
the exact engine module instance used by its consumer, including profiling
and unified-test configurations. It must not recreate engine types through
relative imports of engine source files.

The engine must neither import nor re-export the bundled host. Native
functions, handles, root providers, module-loading contracts, interrupts,
and job/checkpoint entry points remain engine facilities. The host must not
become another owner of Runtime, Realm, module evaluation, or GC semantics.

## Starting state and target

| Area | Starting source and coupling | Target |
| --- | --- | --- |
| Event loop | `src/event_loop.zig`; exported by `src/root.zig` | `src/host/event_loop.zig`; consumers install and drive it explicitly |
| OS event protocol | `HostEventLoop` in `src/core/context.zig` exposes timers, fd handlers, signals, exit codes, and tracing | Concrete operations in host state; engine retains generic native state and rooting contracts |
| Event driving | EventLoop calls back through `exec/call.zig` and `exec/call_runtime.zig` to invoke its own vtable | Host drives its own events and invokes engine checkpoints/calls |
| File modules | `src/exec/module.zig` mixes file reads, path policy, module linking, and evaluation | Host resolves and reads; engine owns graph identity, linking, evaluation, and asynchronous state |
| Dynamic import | File-backed `DynamicImportState` and separate `DynamicImportHostState` paths | One engine scheduler using an injected loading contract |
| Import metadata | `importMetaUrlValue` performs OS realpath lookup | Host supplies metadata policy; engine owns metadata object identity and caching |
| Non-language globals | `standard_globals.zig` and `call.zig` include host globals; performance/DOM extensions also need inventory | Explicit host installers; engine standard-global setup installs language facilities |
| test262 | `src/cli/run_test262_host.zig` owns `$262`, agents, harness helpers, and a timer binding | Keep test262-specific policy there; reuse shared host capabilities |
| CLI and runner policy | Argument parsing, reporting, selection, limits, and process exits in `src/cli/` | Keep with the respective program |
| Embedding API | Runtime, Context, Value, Call, native registration, handles | Remain in engine |

Initial host files: `root.zig`, `event_loop.zig`, `file_module_loader.zig`,
and `globals.zig`. Add smaller capability files only when the actual code
warrants them. Do not create empty capability frameworks.

OS access alone does not make code host policy: engine allocation, native
stack handling, synchronization, and clocks needed by language operations
remain with their engine owners. Likewise, moving `queueMicrotask`'s global
binding must not move Promise jobs or checkpoint semantics out of the engine.

## Approved public migration

Strict target: remove `zjs.EventLoop` and the event-loop alias `zjs.runtime`.
Bundled programs use `@import("zjs_host").EventLoop`. External embedders own
their event source and call the engine's job/call APIs. Update public API
tests and examples to assert this boundary and exercise a custom host.

A compatibility transition would temporarily retain the old exports. That
is a different intermediate target: it cannot satisfy the final rule that
the engine does not depend on the bundled host. Do not add a circular build
dependency or duplicate the implementation to preserve those names.

Default global availability is also observable. Record the existing
non-ECMAScript globals before changing installers, preserve bundled CLI
behavior, and document the minimal embedder environment. Removing engine
defaults must not silently remove the capabilities used by test262 fixtures.

## Ordered implementation

### H1 — Establish the build boundary

Prerequisite: the approved public migration above.

Files: `build/config.zig`, `build/artifacts.zig`, `build/tests.zig`,
`src/root.zig`, `test_root.zig`, CLI roots, and public API documentation/tests.

Create a host module factory parameterized by an engine module instance.
Inject host only into consumers and test adapters. Keep the allocator probe
engine-only. Preserve the unified test root and its nonempty-filter guard;
host tests must be explicitly collected, not lost across a named module.

Acceptance: CLI/profile/runner compile with matching engine types; an
engine-only embedding compile requires no host import; public export checks
match the selected contract.

### H2 — Move event scheduling and preserve lifecycle

Prerequisite: H1.

Files: `src/event_loop.zig` to `src/host/event_loop.zig`, CLI roots,
`tests/harness/test_engine.zig`, event-loop tests, and embedding examples.

Move the existing implementation and its regression coverage. Make the
host loop drive its own timer/fd/signal methods directly. Keep temporary
engine adapters only until their consumers migrate in H5. Preserve existing
ordering, error propagation, timer cancellation, and callback rooting.

Acceptance: event-loop tests cover pending host events versus `Context.runJobs`,
exceptions, cancellation, and GC during a one-shot callback after dequeue.
Installation publishes a stable address; teardown removes roots and callbacks
before releasing the retained Realm.

### H3 — Unify module scheduling before changing file policy

Prerequisite: H1; independent of the physical event-loop move.

Files: `src/exec/module.zig`, module-loader contracts as needed, and focused
module tests in `tests/exec.zig`.

Audit both current loading paths before convergence. The file-backed state
owns or borrows continuation/waiter lists, roots them, propagates import
attributes, and participates in the Runtime checkpoint. Replacing it with
the existing HostHooks path without preserving these properties is unsafe.
Use one engine-owned scheduler with explicit loading callbacks and source
ownership. Preserve namespace/cache identity, error mapping, cycles, live
bindings, and static/dynamic import sharing.

Acceptance: custom in-memory loading works without filesystem access;
dynamic import from scripts, nested import, TLA success/rejection, repeated
imports, attributes, and GC while suspended retain their existing semantics.

### H4 — Extract the file loader and import metadata policy

Prerequisite: H3.

Files: `src/host/file_module_loader.zig`, `src/exec/module.zig`, CLI/runner
setup, and module fixtures.

Move path normalization/resolution, file reads and limits, file URL policy,
and extension/attribute loading choices into the host implementation.
Both programs install the same loader with their own I/O, allocator, and
limits. Engine module records and synthetic export initialization stay with
the engine. Keep loader errors and owned buffers explicit at the boundary.

Acceptance: engine module code no longer reads files or calls realpath;
relative/static/dynamic imports, JSON/text handling, missing files, metadata,
and source-size failures pass focused fixtures. Verify both bundled programs.

### H5 — Extract global installation and remove OS protocol from core

Prerequisites: H2 and H4.

Files: `src/host/globals.zig`, `src/exec/standard_globals.zig`,
`src/exec/call.zig`, `src/exec/call_runtime.zig`, native dispatch tables,
`src/core/context.zig`, `src/js_context.zig`, and test262 host bindings.

Inventory non-language globals and their lazy materialization/dispatch
owners, including output, base64, queueMicrotask, gc, performance, navigator,
and DOMException. Transfer concrete host APIs through native registration;
reuse engine conversion/call primitives rather than copying their semantics.
Give CLI, test262, and tests explicit installation choices without coupling
shared host code to test262 policy. Migrate timer bindings and root ownership,
then delete the OS-specific Context vtable and now-unused exec forwarding.

Acceptance: minimal engine globals have no bundled host capabilities;
installed profiles preserve names, descriptors, conversions, realm behavior,
and exceptions. Promise jobs still work without host installation. Test262
agent runtimes each install their own state on their owner thread.

### H6 — Close the dependency boundary and validate

Prerequisites: H1–H5.

Files: affected source/tests, `docs/architecture.md`,
`docs/public-api-contract.md`, `docs/embedding-cookbook.md`, and build graph.

Remove transitional aliases and unused dispatch entries. Review actual
imports and public exports; do not infer isolation from directory names or
binary size. Update documentation to the implemented contract, keeping this
design marked incomplete until all acceptance criteria have evidence.

Validation follows [verification policy](verification-policy.md): mise-managed
Zig 0.16.0 formatting and `zig build check` during implementation; focused
tests through the unified root; relevant runner/module fixtures; one final
`zig build test`. Also compile the independent embedding root and affected
CLI/profile/runner artifacts. Aggregate gates apply at a merge/release
boundary, not automatically to each extraction step.

## Adversarial lifecycle review

- Publish host state only after it has a stable address. Do not return or
  move an installed by-value loop/loader whose userdata points into itself.
- Keep callback values, continuations, import waiters, and synthetic source
  buffers rooted/owned for their full asynchronous lifetime. A retained
  Realm does not by itself root arbitrary JSValues in host containers.
- Define teardown in reverse dependency order: detach callbacks/scopes,
  release host roots/state and agents, then release Context and Runtime.
  Validate error exits as well as successful runs.
- Nested host calls and loader reentry must preserve checkpoint guards and
  restore prior callback state. Scope depth and uncatchable/OOM classification
  must not change when the outer driver moves.
- An agent worker owns its Runtime; foreign threads only publish supported
  completion signals. Do not share a mutable loop/loader among workers.
- Preserve process-wide signal behavior during the move; per-loop bookkeeping
  does not establish ownership of OS signal disposition. Any behavioral fix
  needs separate reproduction and regression evidence.
- Keep engine-only embedding tests separate from host-enabled integration
  setup so a harness that always installs host cannot hide a dependency leak.
