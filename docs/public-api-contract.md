# Public API Contract

This document is the active public Zig API authority for embedders. Keep it in
sync with `src/root.zig` and `src/js_context.zig`. The
name lists in `tests/embedding_examples.zig` are the executable check:
adding or removing an embedder name must update those arrays in the same
commit. They are not a freeze of the API, and they are not the removed
`check_public_api.zig` / `architecture-update-api-snapshot` tool.

`src/root.zig` is the single compile root. Embedders use the names below.
The same module also re-exports engine layers (`core`, `exec`, `parser`,
`JSRuntime`, …) for the CLI and in-tree tests. Cookbook and embedding
examples must stay on the embedder names.

## Public Entry

Embedders import the root module:

```zig
const zjs = @import("zjs");
```

The public names are:

- `zjs.Runtime`, `zjs.Context`, `zjs.Value` (core uses `JSRuntime` /
  `RealmContext` / `JSValue`; `JSContext` remains its compatibility alias);
- `zjs.Call` for a host-function invocation;
- option types nested on their owner: `Runtime.Options`, `Context.Options` /
  `EvalMode` / `EvalOptions` / `EvalTiming` / `FunctionOptions`.

`Context.Options.math_random_seed` optionally fixes the initial state of that
Context's Realm-local `Math.random` generator. If omitted, Realm construction
uses the platform wall clock; zero is remapped to one because the xorshift
generator cannot leave the zero state.

`Runtime.Options.diagnostic_clock` optionally supplies a
`Runtime.DiagnosticClock` (`context`, `nowNanos`) for compile/eval, Context
construction, and GC diagnostic durations. With no hook, duration fields stay
zero; counters still work. The hook returns monotonic nanoseconds on the Runtime
owner thread and may be called during GC. Its borrowed context must outlive the
Runtime; it must not allocate, reenter the engine, or mutate Runtime state.
Elapsed durations saturate at zero if the clock moves backwards. GC scheduling
and Realm random seeding do not use this hook. The bundled CLI installs its
host clock when GC statistics or opcode profiling are requested.

`Context.defineFunction` / `createFunction` take `fn (*Call) E!Value`
directly. `Context.defineScriptArgs` installs the CLI `scriptArgs` global.
`Context.globalObject` returns a `Value`.

Removed wrapper namespaces (no longer compiled or exported): `zjs.host`,
`zjs.context`, `zjs.value`, `zjs.object` (including the opaque `Object` and
`Buffer` borrow helpers), `zjs.module`, `zjs.job`, `zjs.public_api`,
`host.defineArgvGlobals`, `host.evalGlobalScriptSource` /
`evalGlobalScriptValue`, `zjs.CallSite`, `zjs.PropertySite`,
`zjs.native.leaf` / `leafWithState` / `Class`, `zjs.host.NativeBinding`,
`zjs.host.PropName` / `PropNameID`, and `src/binding/binding.zig`.
`JSRuntime` / `JSContext` / `JSValue` are aliases of `Runtime` / `Context` /
`Value` on the same module. Embedders write `Runtime`, `Context`, `Value`,
and `Call`. The bundled host is a separate internal `zjs_host` module.
Value constructors live on `Value`; handles are the types returned by
`Runtime` methods; byte stores are `Value.Bytes.Store`. The CLI and
`run-test262` are the in-tree consumers. Repeated native → JS calls use
`Context.callFunction`; property IC lives only in the VM `PropSiteCache`.

The intended names above are the contract. The embedding snapshot test
lists the current public declarations. Update the list when the surface
changes.

Removed 2026-09-06 (NB2 phase A3, design ruling D8, no adapter): the host
callback family `zjs.host.Call` / `Function` / `Finalizer` /
`FunctionOptions`, `JSContext.defineGlobalFunction` /
`createExternalFunction`, the `zjs.ffi` plugin ABI, and
`zjs.runtime.Plugin` / `PluginInstallOptions` together with the
`src/runtime/plugin.zig` loader. Host functions register through
`Context.defineFunction`.

## Compatibility Rules

- Do not remove a public symbol without a migration note and release decision.
- Do not add public aliases that imply a different ownership model.
- Do not add a second compile root. Layer re-exports on `src/root.zig` are
  for in-tree hosts; they are not a second embedder contract.
- Additive aliases are allowed when they preserve layout, ownership, and
  semantics.
- New public helper families should have cookbook or production tests when they
  carry ownership, allocation, or runtime policy.

Current public spellings matter. String and byte views are nested on
`zjs.Value` (`Value.String`, `Value.Bytes`). Root spellings such as
`zjs.JSBytes` are intentionally not part of the current contract.

## Known surface deviations

These names are on the public module today and are recorded rather than
hidden:

- `zjs.RuntimeMemoryUsage` is a root export. Embedders read it from
  `Runtime.memoryUsage()`. It reports heap-budget bytes, optional allocation diagnostics, the byte length of
  live dynamic atom names, and class registration counts. It does not
  estimate object, shape, or module sizes from a count times a fixed width.
- `zjs.GCStats` and `zjs.GCDetailedStats` are root exports.
  `Runtime.gcStats()` reads maintained counters only: it does not walk the
  heap. `Runtime.gcDetailedStats()` adds one heap census. Heap live bytes and
  external token bytes stay separate. Ordinary `weak_ref_count` counts
  host weak-root slots; the detailed snapshot also counts
  weak-collection and FinalizationRegistry cells.
- `zjs.JSRuntime` / `JSContext` / `JSValue` are aliases of `Runtime` /
  `Context` / `Value`. `zjs.core`, `zjs.exec`, `zjs.parser`, and `zjs.native`
  are in-tree layer re-exports.
- `zjs.opcode_profile_build_enabled` reports whether the binary was built
  with per-opcode profiling. The CLI uses it to fail closed on
  `--profile-opcodes`.
- `Context.core` is a Zig field on the public facade (fields cannot be
  hidden). Cookbook and embedding examples must not use it.
- `Call.entry` / `Call.func_obj` / `Call.global()` still mention engine
  types (`NativeEntry`, `*Object`). Embedders use `arg` / `args` / `state`
  / `throwTypeError` only.

`Value` currently publishes internal helpers that are not part of the
embedding contract (the value-representation decoders such as `catchTarget`
and `refHeader`). That leak is known debt (backlog H9). Cookbook and
embedding examples must not call those internal names.

`Runtime` is the core `JSRuntime` struct and still publishes engine-internal
methods. Additions or removals on that type require an explicit
public-contract update.

## Runtime And Context

`Runtime.create(your_allocator, .{})` creates an owned,
stable-address Runtime. The allocator is a required first argument, separate
from `Runtime.Options`; there is no default. Its backing state must remain
valid until `destroy()` returns.
Release the Runtime with `destroy()`. Runtime has no public in-place
initialization or copied ownership state.

The engine's call-budget, native-stack guard, and active-backtrace fields are
internal `JSRuntime` state. They are direct fields; the former
`Runtime.hot.<field>` paths have moved to `Runtime.<field>`, and no old nested
container or binary layout is retained. `native_stack_size` is the configured
byte budget below the captured `native_stack_top`; the derived
`native_stack_limit` is the lower address bound. Zero disables that bound. The
operating system owns each thread's call stack; Runtime records its base and
configured budget but does not allocate the stack. Embedders should configure
limits through `stackSize` / `setStackSize` and `nativeStackSize` /
`setNativeStackSize`.

Ordinary native storage uses the selected allocator directly in production.
GC cells use the GC-owned slab, nursery, block and extent routes; prefixed
cells must be released through their matching engine helpers. Parser scratch
belongs to its compile arena. No allocator context is reverse-cast to discover
an owner: operand stacks and reserved BigInts name their Runtime explicitly.
Debug/test instrumentation records allocation counters and supports failure
injection; it is not a production native-memory limit or a second heap budget.

`memoryUsage().heap_bytes` reports the maintained published-heap budget.
`allocation_tracking_enabled` distinguishes available native/mixed allocation
diagnostics from unavailable counters (zero in builds without instrumentation).
Heap bytes and external pressure are separate quantities. Cycle
peak diagnostics now use the same heap-budget domain as the GC threshold.

`Runtime` owns allocator-backed engine state, atom tables, GC state, public
handle scopes, memory limits, interrupt hooks, opcode-profiling state, the
native-entry arena (see Native Functions), and runtime cleanup. The collector,
atom table, class table, and shape registry are separate, address-stable
allocations owned through Runtime pointers. They are created before Runtime
assembly with explicit allocation and subsystem dependencies; only GC is
activated against the completed Runtime. Class registration and shape-cell
operations receive Runtime explicitly. RootSet derives inline storage views
on access and needs no address binding. Class and atom tables remain alive
through managed-heap finalization; the collector remains alive through native
cleanup. Instrumented allocation totals include all five owner allocations.
Temporary parser/compiler atom tables retain value-based `init/deinit`.
`Runtime.diagnostics` owns allocation counters and the test-only allocation
limit used for failure injection.
`Runtime.setMemoryLimit` / `memoryUsage().memory_limit` cap the JS heap
budget (published non-nursery cells). They do not cap ordinary native
allocations or external token bytes. A charge that does not fit
collects at most once, then rechecks the current limit (including changes made by reentrant cleanup) and fails if it still does not fit. Ordinary
native allocation does not collect. `Runtime.gcThreshold` is the
collector's growth bar for that same budget. The profiling
types are public, but per-opcode counts are populated only in profiling
builds (`zig build zjs-profile` / `-Dzjs_enable_opcode_profile=true`);
default builds fail closed on `--profile-opcodes`.

The creation option `gc_threshold` is the initial threshold. `gcThreshold()`
returns the current dynamic threshold, including adjustments made while
creating a Context. `forceGC` propagates collection errors; silent collection
is restricted to internal teardown and test fixtures.

`stack_size` / `setStackSize` bound active VM frame bytes. The separate
`native_stack_size` / `setNativeStackSize` bound how many bytes below
the current thread-stack base execution may descend; zero disables that
address bound. Existing depth safeguards remain in place. Setting the native
stack budget while idle refreshes the base; setting it during execution
preserves the active entry's base.

`terminateExecution` can be called from another thread while the caller keeps
the Runtime alive. Execution observes the atomic request at interrupt polls;
it does not interrupt blocking host code. `cancelTerminateExecution` requires
the owner thread and an idle Runtime. Requests ordered after its atomic reset
remain pending. A checkpoint observing termination discards its remaining jobs;
recovery does not revive them. Live finalization reservations remain valid.

`Runtime.runMicrotasks()` drains only ECMAScript jobs. Without an exception
handler, an ordinary job exception returns `JSException`, leaves its value in
the Runtime and preserves the tail. A handler receives a borrowed, precisely
rooted value; success continues draining. Handler failure returns to the host
and preserves the tail. Handler reentry returns `MicrotaskReentry`; ordinary
nested checkpoints are no-ops. OOM and termination retain their error classes.
`Context.runJobs` and the bundled host's `EventLoop.drain` propagate these
failures. The host dispatches timer, I/O, signal and Atomics completions.

`microtask_policy` defaults to `auto`: successful outermost execution returns
run a checkpoint. `explicit` requires the host to call it. With `scoped`,
`enterMicrotaskScope()` returns a token whose fallible `finish()` drains at
the outermost scope exit. Tokens must finish in LIFO order, including when
the scope body fails. An open scope prevents premature checkpoints. WeakRef
kept-alive values clear when the checkpoint completes, not between jobs.

Internal engine hooks are fixed when the Runtime is created. Context bootstrap
names its Realm explicitly; it never adopts the first empty Context. Dynamic
class registration returns a Runtime-owned binding; numeric ids are local,
failed reservations are not reused, and definitions remain until teardown.
Native object creation and unwrap reject bindings and objects from other
Runtimes. Bindings cannot outlive their owning Runtime.

`Context` owns a realm and exposes public helpers for:

- script and module eval;
- global object access (`globalObject` returns a `Value`);
- host function creation and installation (`createFunction` /
  `defineFunction`, taking `fn (*Call) E!Value`);
- the CLI `scriptArgs` global (`defineScriptArgs`);
- property get/set and own descriptor inspection;
- function calls (`callFunction`);
- string conversion;
- ArrayBuffer and byte-store creation;
- throwing and formatting exceptions.

Values returned to the host are plain `JSValue`s. Under the tracing collector
there is no release call: a value is alive while it is reachable from a
rooted place, and the host's own native stack (locals, argument arrays,
`callFunction` arguments) is such a place through the conservative stack
scan. Values that the host stores in heap memory or keeps across calls must
go into a documented handle (see Values And Handles).

### Context host ownership

`Context.destroy` (and the facade's `destroy` / `deinit`) releases
**the caller's host reference**, matching QuickJS `JS_FreeContext`. It does
not destroy a realm by itself. Auto-init property slots, native-function
`RealmRef`s, function bytecode, jobs, and realm-record payloads hold their
own retains; those keep the realm allocated until they drop.

Who owns that host reference:

- `Context.create` returns it to the caller. Destroy
  that returned context exactly once.
- `Context.createRealm` (and `$262.createRealm()`) transfers the child's
  create reference onto the realm-record `Value`. Free that value. Do not
  call `Context.destroy` on the child.
- `Call.ctx` is a non-owning facade for the callee's realm. It is valid for
  the duration of the call only; never `destroy` / `deinit` it and never
  store it.

`Runtime.contextForGlobal`, `firstContext`, and the `context_head` list are
lookups, not ownership transfers. Do not walk `context_head` or resolve a
global to a context and `destroy` it unless that pointer is the host
reference you created and still own. A second host `destroy` (the createRealm
child, or `destroy` twice on a `create` realm) undercounts remaining realm
edges. Cycle GC then hits `gcDecrefChildInline` (`rc > 0`) on `visitRealm`.

`RealmRef.retain` / `deinit` is the explicit extra host-reference pair
(`JS_DupContext` / `JS_FreeContext`). Use that when you need another owner,
not `contextForGlobal` plus `destroy`.

Some low-level runtime helper APIs still accept the public context's `.core`
field while the adapter layer is being completed. Do not add new public
core-typed APIs without documenting the migration shape.

## Values And Handles

`Value` is the public value representation and remains a small tagged value.
Its layout is not promised as a long-term binary-stable plugin ABI.

Callback `this` and argument values are borrowed for the duration of the call.
Host state that keeps JavaScript values across callbacks, ticks, or object
lifetimes must use one of the documented handle types:

```zig
rt.enterHandleScope()           // HandleScope
scope.localDup(value)           // LocalHandle
rt.createPersistentValue(value) // persistent handle
```

Do not store raw `JSValue` fields in long-lived host state unless they are
protected by a persistent handle or another documented public root.

The rooting rules of the native boundary (design contract C2) are:

- a `JSValue` that lives in native stack memory -- a local, a stack array
  passed as `args`, a value returned from `eval` / `callFunction` /
  `CallSite.call` and held in a local -- is covered by the conservative
  native-stack scan for as long as it is there;
- a `JSValue` array that the host keeps in **heap** memory is not scanned.
  Pin every element in a `Persistent`, or keep the values in a JS Array that
  is itself pinned by one `Persistent`, before the host can trigger GC
  (any call into the engine can);
- cross-call retention (a callback stored for later, a cached object, host
  object state) uses `Persistent` (or `Weak` when the host must not keep the
  object alive).

## Ownership verbs

Public lifetime methods use three verbs:

- `deinit` destroys the receiver. Use it for handle scopes, persistent
  handles, weak handles, and native pins.
- `take` transfers ownership out of the receiver. A persistent handle's
  `take` removes the persistent root and returns the rooted `JSValue`.
- `release` decrements a reference count or drops a borrowed pin. Keep this
  spelling on `JSValue.Bytes.Store`.

`HandleScope.deinit` is idempotent: an early `scope.deinit()` before a
`defer scope.deinit()` is the supported way to close a scope early.

A persistent handle's `destroy(rt)` is a by-value compatibility wrapper. It
asserts that `rt` matches the handle's runtime, then drops the root. Prefer
`deinit` on a mutable handle. It is not a transfer (`take`) and is not
equivalent to `deinit` as a method signature.

`NativePin` exposes only `deinit`. The previous `NativePin.release`
self-destruct spelling is gone.

## Strings, Bytes, And Property Names

`Value.String` is a JavaScript string view. Tag checks, contiguous
latin1/utf16 unit views, callback-scoped UTF-8 borrows, and owned UTF-8
conversion are distinct operations. The legacy `asString()` does not run
ECMAScript `ToString`, but it may materialize a rope, allocate and collect;
exhausted OOM retries panic. Keep the source rooted while acquiring and using
this borrowed view. `Value.String.fromFlatValue` is the allocation-free flat
projection. Use `Context.toOwnedUtf8` for owned text without implicit rope
materialization; internal fallible materialization uses rooted
`core.string.ensureFlat` inputs and outputs.

`Value.Bytes` is the public byte view for ArrayBuffer and typed-array
backing memory. `Value.Bytes.Store` supports owned and shared stores with
explicit deinit/release semantics. Borrowed byte slices are callback-local; keep
a JS value rooted and reacquire the view, or copy the bytes, when data must
survive across callbacks or ticks.

## Native Functions

A native function is a plain Zig function wrapped at comptime into a
`callconv(.c)` thunk; the thunk is the `target` of one immutable
`NativeEntry`, and the VM dispatches an embedder function exactly like a
builtin (see [API boundary](api-boundary.md)). There is no
registry lookup, per-call arena, handle scope, or marshalling framework on
the call path. `src/js_context.zig` builds that thunk; embedders do not import
it.

```zig
_ = try ctx.defineFunction("hostCombine", Combiner.call, .{
    .length = 2,
    .state = @ptrCast(&state),
    .finalize = Combiner.finalize,
});

fn call(c: *zjs.Call) anyerror!zjs.Value {
    const self = c.state(Combiner);
    return zjs.Value.int32(self.factor * (c.arg(0).as(.int) orelse return error.TypeError));
}
```

`Context.createFunction(name, fn, options)` creates the function object
in the context's realm (or `options.realm_global`) and returns it;
`Context.defineFunction(name, fn, options)` additionally installs it on
that realm's global as a writable, non-enumerable, configurable data
property. Both take `Context.FunctionOptions`:

- `length`: JS `length`. Defaults to `0` for managed functions;
- `state`: opaque pointer handed back as `Call.state(T)`;
- `finalize`: `fn (*anyopaque) void`, run once with `state` when the
  **runtime** is destroyed (not when a context is destroyed, not when the
  function object is collected). Requires `state`;
- `with_prototype`: also create a `prototype` object whose `constructor`
  points back to the function;
- `realm_global`: optional `Value` for the realm to create the function in.

Leaf signatures (`leaf` / `leafWithState`) and `native.Class` are engine
private. They are not part of the public embedder surface.

### Managed calls

`Call` is built on the C stack by the thunk and never outlives
the call. It carries `ctx` (non-owning realm facade), `this`, `argv` /
`argc`, plus the helpers `arg(i)` (`undefined` past `argc`), `args()`,
`state(T)`, `runtime()`, `output()` (the host writer of the current
invocation, if any), and `throwError(name, message)` / `throwTypeError` /
`throwRangeError`, which install the JS exception and return
`error.JSException`.

Error mapping at the seam (`builtin_dispatch.embedderErrorToValue`): a
function returning `Value` cannot fail; a function returning `E!Value`
may return any error set. `error.JSException` means "already thrown" and
propagates the pending exception. `OutOfMemory`, `Interrupted`, `Timeout`,
`StackOverflow`, `ProcessExit` and `UnhandledPromiseRejection` are engine
sentinels and are materialized by the engine. `TypeError`, `RangeError`,
`SyntaxError`, `ReferenceError`, `EvalError` and `URIError` become an error
of that class with an empty message; any other error name becomes
`Error: <name>`. If an exception is already pending when a non-sentinel
error is returned, the pending exception wins. A native function must never
unwind through the VM in any other way.

Managed calls are visible in `Error().stack` as `at name (native)`
(contract C7). A native call does not poll the interrupt handler by itself
(C8); JS loops and function entries do.

### Ownership and lifetimes

- `state` is embedder-owned and must stay valid until the runtime is
  destroyed (or, without `finalize`, until the last call has returned and
  the function can no longer be reached from JS). `finalize` is the
  ownership hand-off for `state`; it runs on the runtime thread during
  `Runtime.destroy` (destroying a context or collecting the function
  object does not run it). If `state` references
  runtime-owned JavaScript values, it must own public handles and release
  them before the runtime is destroyed.
- Each registration allocates one `NativeEntry` in the runtime's entry arena.
  Entries are immutable and are never freed before the runtime dies
  (contract C9); the function objects that reference them are ordinary
  GC-managed objects.
- `Call.ctx` is the realm the function was created in (contract C6), which
  may differ from the realm of the caller.
- Arguments are the VM's operand window and stay alive for the duration of
  the call; values the function creates are covered by the conservative
  stack scan while they live in locals; only cross-call retention needs a
  `Persistent` (contract C2, see Values And Handles).
- Entries and function objects are bound to their runtime; call them only
  on the runtime's thread (contract C10).

## Native -> JS Calls

`Context.callFunction(callee, args, .{ .this_value, .output, .realm_global })`
is the one-shot form: the callee, receiver, and `args` are borrowed for the
duration of the call, and the result is returned as a plain `Value`. A
thrown JS exception surfaces as `error.JSException` with the exception
pending on the context (`takePendingException`,
`pendingExceptionMatchesErrorName`); an out-of-memory exception surfaces as
`error.OutOfMemory`. Host -> JS -> native -> JS recursion uses the
C stack and is bounded by the runtime's native stack limit.

`CallSite` and `PropertySite` are not public. Repeated host → JS calls use
`callFunction`; repeated property access uses `getProperty` / `defineDataProperty`.

## Host-Side Property Access

`Context.getProperty(obj, "field")` interns the name and walks the object
on every call.

## Event Loop

Removed by the approved 2026-09-23 host split: `zjs.EventLoop` and the
`zjs.runtime` alias. Embedders own their event sources, retain cross-call
values through handles, invoke callbacks through `Context.callFunction`, and
drive engine jobs through `Context.runJobs` / Runtime checkpoints.

The bundled CLI and test262 runner explicitly import the internal
`zjs_host.EventLoop`. The engine has no dependency on that module. A narrow
internal `HostScheduler` contract lets synchronous evaluation request host
progress without knowing about timers, descriptors, or signals.

The engine no longer installs `print`, `console`, `btoa`, `atob`,
`queueMicrotask`, or `gc`. Bundled hosts install these explicitly; embedders
register the functions they need through `Context.defineFunction`. This
change does not remove Promise jobs or the engine's GC API. Remaining
compatibility extensions are tracked in [host boundary design](host-boundary-design.md).

File source acquisition and file URL policy live in `src/host/`; graph
linking, TLA continuations, and import Promise settlement remain in
`src/exec/module.zig`. A bare engine Context has no filesystem loader.

## Evidence

The current public API contract is covered by:

- `docs/embedding-cookbook.md`;
- `tests/embedding_examples.zig`, including the embedder-name checks and the
  native function contract test (arguments, receiver, error mapping,
  finalizer timing);
- public API contract and production failure-path tests in
  `tests/core.zig` and `tests/public_api.zig`.


The dynamic-import host drain obeys Runtime checkpoint reentry and scope
boundaries. Internal TLA scheduling retains its continuation/job interleaving,
but each engine job uses the shared termination and exception-reporting
boundary. An exception handler that leaves a pending OOM or uncatchable
exception preserves that failure classification for the host.
