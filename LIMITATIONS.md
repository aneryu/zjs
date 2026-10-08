# Limitations

zjs is a JavaScript / TypeScript engine for trusted-code embedding in Zig.
This page defines product boundaries; dated validation results live in
[STATUS.md](STATUS.md).

## Runtime Boundary

- Compatibility is scoped to [the validation profile](COMPATIBILITY.md) and
  focused regressions. ECMA-262 governs JavaScript semantics; QuickJS is a
  comparison reference, with no vendored `quickjs/` source tree.
- Node.js, Deno, browser APIs, and the `libquickjs` C ABI are outside scope.
- Each runtime and its values belong to one owner thread.

## TypeScript

The parser accepts `.ts`, `.mts`, and `.cts` directly. It erases type-only
syntax and lowers supported runtime constructs: enums, namespaces, parameter
properties, and `import x = A.B` aliases. It does not perform type checking
or replace `tsc`.

JSX (`.tsx`), decorators, auto-accessors (`accessor`), `import x = require()`,
and `export =` are outside scope.

Each file is compiled on its own, without type information (like tsc's
`isolatedModules` with `verbatimModuleSyntax`): an import of a type-only
export must be written `import type` / `import { type T }`. A local
`export { T }` naming an `interface` or `type` alias is dropped.

Namespace and enum members resolve as tsc rewrites them (`N.x`, `E.X`)
across the blocks of one file. Known gaps against tsc's emit:

- Namespaces merge only within one file. A member resolves to `N.x` only
  after its block (or an earlier block) exports it: a function in one block
  cannot call a member exported by a later block of the same namespace, and
  a destructured `export const { a } = ...` member resolves only after its
  declaration.
- Inside a namespace function, a local `var` or function declaration that
  appears after a reference does not shadow a member of the same name for
  that reference.
- A `var` directly in a namespace body is scoped like `let` (tsc scopes it
  to the namespace function): it is not hoisted, so reading it before its
  declaration throws, a second `var` of the name is a redeclaration error,
  and a `var` in a loop head of the namespace is not visible after the loop.
- A namespace that contains only types still creates an empty object.
- Members of an ambient `declare namespace N { ... }` or `declare enum E`
  do not resolve unqualified inside a merged `namespace N` or `enum E`
  block (tsc rewrites them to `N.x` / `E.x`); qualify them.
- tsc decides whether a non-constant enum member gets a reverse mapping
  from its static type; zjs has no types and decides at run time, mapping a
  string value forward only. An `any`-typed member that holds a string
  (`b = getAny()`) therefore lacks the reverse entry tsc emits.
- A direct `eval` inside a namespace function sees an exported `let` or
  `const` member as a local binding holding its initial value; tsc's emit
  has no such binding (`eval("x")` throws a ReferenceError there).
- A parameter property (`constructor(public x)`) is assigned after each
  `super(...)` call in the constructor body itself. A `super()` inside an
  arrow function does not assign it (tsc assigns it before `super()`, which
  throws).
- An arrow function with a return type annotation in the `true` branch of
  a conditional (`c ? (a: number): number => a : f`) must be parenthesized.

JavaScript files, `eval` and `new Function` are parsed with the same
grammar, except where valid JavaScript means something else: there
`f<T>(x)` is two comparisons and a postfix `x!` is a syntax error, as in
JavaScript; only `.ts`, `.mts` and `.cts` files read them as a generic call
and a non-null assertion. Other TypeScript syntax, which is never valid
JavaScript (`<T>expr` assertions, type annotations), is still accepted in
`.js` files.

Detailed parsing rules are in the
[TypeScript parser design](docs/parser-ts-first-class-design.md).

## Implementation Limits

A function may declare at most 65,535 local bindings (including block-scoped
`let`/`const` and `catch` bindings) and 65,535 closure variables; the
top-level declarations and imports of a script or module count as closure
variables. Larger functions fail to compile with
`SyntaxError: implementation limit exceeded`.
A regular expression may have at most 254 capture groups.
A call passes at most 65,534 arguments: a spread call, `apply`,
`Reflect.apply` or `Reflect.construct` with a longer argument list throws
`RangeError: too many arguments in function call`. Pass large arrays as one
argument instead (for example, reduce instead of `Math.max(...values)`).

An ArrayBuffer (and so a typed array's backing store) holds at most
2,147,483,647 bytes, as in QuickJS: a larger `byteLength`, `maxByteLength`,
`transfer` length or typed-array size throws
`RangeError: invalid array buffer length`. Backing stores are not counted
against `--memory-limit` / `Runtime.setMemoryLimit`, which covers the JS heap.

The parser recurses on the native stack within the runtime's native stack
budget (`Runtime.setNativeStackSize`; 4 MiB by default in release builds,
scaled ×4 in Debug and ×2 in ReleaseSafe for their larger frames so the
nesting depth stays about the same, and never beyond the current thread's
own stack less 256 KiB). Under the default, source nested about 2,900
parentheses or array literals deep, or about 800 function literals deep,
fails with `SyntaxError: stack overflow`. The CLI's `--stack-size` sets the
VM stack; `--native-stack-size kbytes` sets this native budget (clamped to
the thread's `RLIMIT_STACK`); for all three size flags, and
`--memory-limit`, 0 means no limit. Independently of `--stack-size`,
JavaScript calls nest at most 8,192 deep (the interpreter's frame pool), so
raising the VM stack past about 256 KiB does not deepen plain recursion. A builtin that calls back into JavaScript
(`map`, `sort` comparators, `replace` callbacks, getters, proxy traps) and
async-function and generator resumption also recurse natively: about 900
levels of recursion through `Array.prototype.map` and about 1,100 nested
awaits fit the default. `JSON.parse` and `JSON.stringify` recurse within
the same budget (roughly 5,700-6,900 array levels under the ReleaseFast
default);
deeper valid input throws `InternalError: stack overflow`.

## Language Deviations

In a function with parameter expressions (defaults or destructuring), a
parameter the body does not redeclare with `var` should be one binding shared
by the body and closures created in the parameter list
(FunctionDeclarationInstantiation step 28). zjs, like QuickJS, gives the body
its own argument slot initialized from the parameter binding once the
parameter list has run. Assignments made while the parameter list runs are
therefore visible to the body (`function f(a, b = (a = 9)) { return a }`
returns 9), but later writes are not shared: a parameter-list closure that
assigns the parameter after the body starts, or reads it after the body
assigned it, sees the other copy
(`function f(a, g = () => a) { a = 3; return g() }` returns the original
argument, not 3).

A sloppy direct `eval` that declares `arguments` (`eval("var arguments = 5")`,
`eval("function arguments() {}")`) inside a function should reuse the
function's `arguments` binding (EvalDeclarationInstantiation). zjs, like
QuickJS, gives the eval code its own binding: afterwards the function still
sees its arguments object (`typeof arguments` is `"object"`, not
`"number"`). Assigning `arguments = 5` in the eval does update the
function's binding.

## Debugging

A Chrome DevTools Protocol inspector/debugger is not implemented. Breakpoints,
stepping, call stacks, and scope inspection remain planned capabilities.

## Security Boundary

Production v1 targets trusted or pre-vetted source, not hostile-code sandboxing.
The embedder owns OS isolation, process/filesystem/network policy, and
wall-clock supervision. Native host functions are trusted code.

Memory limits, stack limits, GC thresholds, and cooperative interrupts improve
reliability. They do not prevent all CPU starvation, host API misuse, side
channels, allocator fragmentation, or native-code bugs.

Out of scope: attacker-controlled JavaScript in-process, cross-thread runtime
use, capability-secure module loading, browser/Node/Deno permission models,
deterministic execution across hosts, and hard real-time interruption.
Release notes must state the trusted-code boundary.

## CLI Lifecycle

- Successful CLI execution normally leaves process-memory reclamation to the
  OS. `--leak-check` performs full engine teardown and allocator validation.
- In-process tests and embedders must deinitialize normally; process exit is
  not their cleanup mechanism.

## GC Limitations

- The tracing collector is non-moving; it does not use heap reference counts.
- Raw object pointers remain runtime-owned. Host values need local handles
  while in use and persistent handles across calls/ticks, or the documented
  native-payload tracing protocol.
- Allocation-capable VM/host paths must root temporaries before GC safe points.
- Weak edges, finalizers, descriptors, and object-graph changes need focused
  lifetime coverage and the verification required for the affected behavior.

See [GC invariants](docs/gc-invariants.md) and the
[public API contract](docs/public-api-contract.md) for ownership details.

## Standard Library and Host APIs

No Node.js/Deno modules, `qjs:std`/`qjs:os`, or stable JavaScript FFI for
arbitrary C/C++/Zig libraries are provided. Host functions supply application
capabilities. An embedded Context has only the ECMAScript globals (plus the
non-standard `InternalError` and `TypedArray`); the CLI's `print`, `console`, `btoa`/`atob`,
`queueMicrotask`, `gc`, `navigator`, `performance`, and `DOMException` come
from the bundled host and are not installed for embedders. Fetch, Streams, WebCrypto, DOM, and browser event-loop integration
are outside the core-engine scope.

## Modules

ECMAScript modules are supported within the validation profile. Binary
imports (`import ... with { type: "bytes" }`) load as a `Uint8Array` over a
plain, mutable ArrayBuffer: Immutable ArrayBuffer (`transferToImmutable`,
`sliceToImmutable`, `immutable`) is not implemented, as in QuickJS. CommonJS `require`, `node_modules`
resolution, package exports/import maps, and hybrid Node-style loading are not.

The CLI file loader resolves a specifier without a leading `./`, `../` or `/`
verbatim, relative to the working directory, without normalizing it (as
QuickJS does). It accepts the local `file:` URLs it reports as
`import.meta.url`, percent-decoded. A query or fragment is ignored, so it
names the same module instance, and a `file:` URL with a remote host is not
found.

## Proper Tail Calls

- Strict-mode plain-call tails reuse the caller frame: direct `return f(...)`
  and calls whose control flow reaches `return` through conditional arms or
  short unconditional jumps. The reused caller drops off `Error.prototype.stack`.
  This differs deliberately from pinned QuickJS's frame growth.
- Sloppy code, method tails (`o.m()` / `this.m()`), constructors, live-`try`
  protected calls, and L0 host entries still grow logical frames. Deep recursion
  there throws catchable `InternalError: stack overflow`.
- Infinite strict `return f()` therefore does not overflow. Overflow tests need
  sloppy mode or a non-tail shape such as `return 1 + f()` or `return this.m()`.
- `tail-call-optimization` remains skipped in `test262.conf` because method tails
  are not implemented. Focused Zig fixtures cover the boundary;
  `tco-member-args.js` exercises a plain call.

## Performance

Historical bench-v8 comparisons are available in Git history and apply only
to their recorded configurations. They establish neither per-benchmark parity
nor a performance merge gate. Local measurements are diagnostic.

Per-opcode counts require `zig build zjs-profile`; the default CLI rejects
`--profile-opcodes`. See [GUIDE](GUIDE.md#b8-performance-investigation).
