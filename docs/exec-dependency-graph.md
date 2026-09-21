# Exec call and import graph

How `src/exec/` is entered, which files own which runtime step, and why a
complete `@import` DAG does not exist. Current file list is the 40 Zig
modules after the 2026-09-21 consolidation. Function-level walkthroughs
stay in [code-walkthrough/11-vm-kernel.md](code-walkthrough/11-vm-kernel.md)
and [13-calls.md](code-walkthrough/13-calls.md). Layering rules:
[architecture.md](architecture.md), [api-boundary.md](api-boundary.md).

Zig allows circular `@import`. **38 of the 40 files form one strongly
connected component.** `frame.zig` and `stack.zig` are the only modules
with no exec-internal outgoing imports. Do not read the compile graph as
a call DAG. The maps below are **runtime control flow** and **role
layers**. `@import` edges are listed only where they explain a hub, a
leaf, or a load-bearing cycle.

## 1. Who enters exec

Host code almost always goes through `src/exec/root.zig` (`exec.foo`).
Direct `@import("exec/….zig")` is limited to a few compile tests.

| Caller | Exec names it uses | Why |
| --- | --- | --- |
| `src/js_context.zig` | `eval_entry`, `zjs_vm`, `call_site`, `call_runtime`, `standard_globals`, `object_ops`, `exception_ops`, `coercion_ops`, `string_ops` | Public `Context`: eval, property get, `callFunction`, drain |
| `src/native.zig` | `builtin_dispatch` | Host `defineFunction` thunks use the same native-call view as builtins |
| `src/event_loop.zig` | `zjs_vm`, `call_runtime`, `atomics_ops`, `object_ops`, `promise_ops` | Timers/fd callbacks, microtasks, Atomics waiter wake |
| `src/root.zig` | `exceptions`, `opcodeName`, `small_inline` | Public error aliases; opcode-profile name provider |
| CLI (`zjs`, `run-test262`) | `module` / `module_graph`, `atomics_ops`, `call_runtime`, `buffer_ops` | File modules, agents, harness helpers |
| In-tree tests | many `exec.*` aliases | Direct domain probes; keep `root.zig` compatibility names |

`src/core/` must not import exec except the historical `exec.exceptions`
re-export comment in `core/errors.zig`. Job queues and Promise object
state stay in core (`jobs.zig`, `promise.zig`); exec *runs* them.

## 2. Role layers (hot-path call direction)

These layers describe who *calls* whom on a normal eval. They are not a
compile DAG: a builtin file in L6 still `@import`s `call_runtime.zig`.

```
L0  host facade     js_context.zig, native.zig, event_loop.zig
L1  exec entries    eval_entry.zig, root.Vm, standard_globals.zig
L2  interpreter     zjs_vm.zig, inline_calls.zig,
                    tailcall_dispatch.zig + tailcall_dispatch_colds.zig
L3  opcode bodies   vm_opcodes.zig, vm_property.zig
L4  call router     call_runtime.zig (unique Call/Construct terminals),
                    call_site.zig, remaining owners in call.zig / construct.zig
L5  object/value    object_ops, array_ops, string_ops, iterator_ops,
                    property_ops, value_ops, exception_ops
L6  domain builtins math, number, date, json, uri, regexp, reflect,
                    collection, buffer, atomics, function, promise,
                    disposable; leftover records in builtin_glue.zig
L7  storage         frame.zig, stack.zig
```

`internal_builtins.zig` is the comptime `NativeBuiltinDomain` table. It
is installed by `standard_globals` onto `JSRuntime.internal_builtins` and
is not on the per-opcode hot path.

## 3. Runtime control flow

### 3.1 Eval (script / module)

```
Context.eval / evalScriptSource
        │
        ▼
 eval_entry.eval*
        │  parser.compile  (outside exec)
        ├─ script  → call.evalGlobalScriptSource
        │              → zjs_vm.runWithCallEnv
        └─ module  → module.preload* / evaluate*
                       → zjs_vm.runWithCallEnv
                       → zjs_vm.drainPendingPromiseJobs
```

`eval_entry` is the public script/module door. Direct eval (`eval` in
strict/sloppy functions) is compiled and run from `eval_entry` /
`call_runtime` while the caller frame is still live.

### 3.2 Interpreter shell

```
zjs_vm.runWithCallEnv
        │  interrupt poll, stack budget, realm switch
        ▼
 inline_calls.Machine  +  frame.Frame  +  stack.Stack
        │  ActiveInvocation on JSRuntime.active_invocation
        ▼
 tailcall_dispatch.runDispatchLoop
        │  (pc, sp, var_buf, *Vm)  always_tail
        ├─ hot table   tailcall_dispatch.zig
        └─ cold table  tailcall_dispatch_colds.zig
                │
                ▼
         vm_opcodes.zig / vm_property.zig
```

Hot handlers mutate the four dispatch registers and tail-call `next`.
Anything that can throw or allocate must `Vm.publish` first so outlined
helpers see `frame.pc` / `stack.top_ptr`.

Same-machine bytecode→bytecode calls (`OP_call` fast shape, strict
`OP_tail_call`) stay in this loop via `inline_calls` push/pop. They do
not recurse into `runWithCallEnv`.

### 3.3 `[[Call]]`

```
OP_call / OP_call_method / OP_tail_call
        │
        ▼
 call_runtime.execCall / vm_opcodes call helpers
        │
        ├─ inline-eligible bytecode  → Machine.push*Entry  (stay in L2)
        └─ callValueOrBytecodeRoot*
                ├─ FunctionBytecode value     → runWithCallEnv
                ├─ bytecode function object   → same
                ├─ Proxy                      → object_ops.callProxyApply
                ├─ NativeEntry / bound / host → builtin_dispatch
                │                                 or call.zig host ID / record
                │                                 Object [[Call]] → objectConstructorValue
                └─ other                      → TypeError "not a function"
```

Host → JS (`Context.callFunction`, builtin callbacks) skips the opcode:

```
call_site.CallSite.init    resolve class, inline eligibility, Realm
        │
        ▼
CallSite.call
        ├─ bytecode + matching Machine → inline_calls native_boundary Entry
        ├─ idle embedder stack         → resident HostInvocation, then same
        └─ generic                     → callValueOrBytecodeDispatch*
```

### 3.4 Native builtin and host function

```
standard_globals.install*
        │
        ▼
 JSRuntime.internal_builtins  ←  internal_builtins.table
        │                       (one EntryTable per NativeBuiltinDomain)
        ▼
 callNativeCallableObject / vm_opcodes native arm
        │
        ▼
 builtin_dispatch.nativeCall + domain handler in *ops.zig
        │  may re-enter JS
        ├─ call_site / call_runtime     (callback, thenables)
        └─ object_ops / array_ops / …   (algorithms)
```

Host functions registered with `Context.defineFunction` are the same
`NativeEntry` shape. `src/native.zig` builds the thunk; dispatch is
`builtin_dispatch`, not a second registry.

### 3.5 `[[Construct]]`

```
OP_call_constructor / new F(...)
        │
        ▼
 call_runtime.constructValueOrBytecodeWithNewTarget
        ├─ Proxy trap / bound           → object_ops / recursion
        ├─ ordinary bytecode function   → create instance, runWithCallEnv
        │                                 (same-Machine fast path when eligible)
        ├─ TypedArray metadata          → typedArrayConstructVm
        │                                 (TypedArray source copy:
        │                                  constructTypedArrayTypedArrayInput)
        ├─ Date/String/RegExp/Array/Promise/collection/Error/…
                                  → NativeEntry construct record or domain *ops
        ├─ Number/Boolean/WeakRef/FR/Iterator/Proxy name arms
                                  → unique helpers (no empty-object fallback)
        └─ illegal                      → TypeError "not a constructor"
```

### 3.6 Jobs, promises, Atomics wait

```
promise_ops  (then / resolve / settle)
        │
        ▼
 core.jobs enqueue
        │
        ▼
 zjs_vm.drainPendingPromiseJobs  ←  Context / EventLoop
        │
        ├─ call_runtime.callValueOrBytecodeRoot   (reaction)
        └─ atomics_ops waiter wake                (shared-buffer wait)
```

Promise *object* fields live in `src/core/promise.zig`. Exec owns
abstract operations, async functions/generators, and `using` disposal
(`disposable_ops.zig`, opcode bodies in `vm_opcodes.zig`).

## 4. Hubs and leaves

Internal `@import` in-degree (how many exec files import this file).
High in-degree means “almost every path already sees this module”; it
is not a ranking of runtime cost.

| File | In | Out | Role |
| --- | ---: | ---: | --- |
| `exception_ops.zig` | 35 | 9 | Throw helpers, Error objects, stack capture |
| `object_ops.zig` | 30 | 21 | Property/proxy/function-object algorithms |
| `frame.zig` | 28 | 0 | `Frame` / slab / open VarRefs |
| `builtin_dispatch.zig` | 27 | 4 | NativeCall view, thunk adapters |
| `value_ops.zig` | 27 | 7 | ToNumber/ToString/ToLength, bigint kernels |
| `call_runtime.zig` | 26 | 23 | Call/construct/eval/generator router |
| `array_ops.zig` | 23 | 18 | Array / TypedArray algorithms |
| `property_ops.zig` | 20 | 5 | Key conversion, slot get/set, direct shape paths |
| `string_ops.zig` | 18 | 13 | String + RegExp-string integration |
| `stack.zig` | 17 | 0 | Operand stack |
| `iterator_ops.zig` | 16 | 13 | Iterator protocol, for-in/of, helpers |
| `promise_ops.zig` | 15 | 18 | Promise AO, async function/generator |

Leaves (no exec-internal outgoing `@import`): `frame.zig`, `stack.zig`.
They still import `core`.

`call_runtime.zig` is the widest *outgoing* hub (23 exec imports). New
call-shaped helpers belong there or in the domain `*_ops.zig` that already
owns the algorithm — not in a new satellite.

## 5. Domain files and the native table

`internal_builtins.zig` indexes `internal_entries` from:

| Domain | File |
| --- | --- |
| array | `array_ops.zig` |
| object | `object_ops.zig` |
| string | `string_ops.zig` |
| iterator | `iterator_ops.zig` |
| promise | `promise_ops.zig` |
| collection | `collection_ops.zig` |
| reflect | `reflect_ops.zig` |
| regexp | `regexp_ops.zig` |
| buffer | `buffer_ops.zig` |
| atomics | `atomics_ops.zig` |
| date | `date_ops.zig` |
| json | `json_ops.zig` |
| math | `math_ops.zig` |
| number | `number_ops.zig` |
| uri | `uri_ops.zig` |
| function | `function_ops.zig` |
| error_object | `exception_ops.zig` |
| primitive | `value_ops.zig` |
| weak_ref / leftovers | `builtin_glue.zig` |
| performance | `builtin_glue.zig` (`performance_internal_entries`) |

`standard_globals.zig` installs constructors, prototypes, and method
tables onto the realm and points `JSRuntime.internal_builtins` at that
comptime table.

## 6. Load-bearing cycles

Zig is fine with these. They are not bugs to “fix” with another file
split.

| Cycle | Why it exists |
| --- | --- |
| `tailcall_dispatch` ↔ `tailcall_dispatch_colds` | Hot table vs cold table; colds call `dispatch.Handler` / `Vm` |
| `inline_calls` ↔ `tailcall_dispatch` ↔ `zjs_vm` | Machine owns the loop; the loop pushes Machine entries; `runWithCallEnv` builds the Machine |
| `call_runtime` ↔ `object_ops` ↔ `array_ops` ↔ `string_ops` ↔ `iterator_ops` ↔ `promise_ops` | Call routing and builtin algorithms re-enter each other (Proxy, species, thenables, iterators) |
| `module.zig` → `exec/root.zig` | Dynamic import uses the exec namespace (`exec.promise_ops`, `exec.exceptions`, …) instead of listing every domain |

`root.zig` re-exports every domain for embedders and tests. Compatibility
aliases (`array_builtin_ops`, `exceptions`, `module_graph`,
`collection_adapter`, `closure`, …) point at the merged owner. They are
not extra runtime layers.

## 7. Where to put new code

| Change | File |
| --- | --- |
| New opcode hot/cold handler | `tailcall_dispatch.zig` / `_colds.zig`, body in `vm_opcodes.zig` or `vm_property.zig` |
| New `[[Call]]` / `[[Construct]]` route | `call_runtime.zig` unique terminal. `call.zig` / `construct.zig` keep remaining owners (host globals, Bound create, `objectConstructorValue`, TypedArray copy primitive); do not add a second generic classifier |
| New standard method | `internal_entries` in the domain `*_ops.zig`, row in `internal_builtins.zig`, install in `standard_globals.zig` |
| New throw helper | `exception_ops.zig` (`throw<Kind>Message` / `throw<Reason><Kind>`) |
| New host→JS entry | `call_site.zig` (do not add a second CallSite) |
| Frame/stack storage | `frame.zig` / `stack.zig` only |

Do not add a new exec file to break an `@import` cycle. That is how the
pre-merge satellite graph grew. If a name must stay short for tests, add
an alias on `exec/root.zig`.

## 8. File roster (40)

Interpreter: `root.zig`, `zjs_vm.zig`, `frame.zig`, `stack.zig`,
`inline_calls.zig`, `small_inline.zig`, `tailcall_dispatch.zig`,
`tailcall_dispatch_colds.zig`, `vm_opcodes.zig`, `vm_property.zig`.

Call / eval / module: `eval_entry.zig`, `call_runtime.zig`, `call.zig`,
`construct.zig`, `call_site.zig`, `module.zig`.

Object / value: `object_ops.zig`, `property_ops.zig`, `array_ops.zig`,
`string_ops.zig`, `iterator_ops.zig`, `value_ops.zig`,
`exception_ops.zig`.

Domains: `promise_ops.zig`, `function_ops.zig`, `collection_ops.zig`,
`reflect_ops.zig`, `regexp_ops.zig`, `buffer_ops.zig`, `atomics_ops.zig`,
`date_ops.zig`, `json_ops.zig`, `math_ops.zig`, `number_ops.zig`,
`uri_ops.zig`, `disposable_ops.zig`, `builtin_glue.zig`.

Bootstrap: `standard_globals.zig`, `internal_builtins.zig`,
`builtin_dispatch.zig`.
