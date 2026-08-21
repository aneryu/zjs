# Changelog

## Unreleased

Target **0.2.0-dev** (unpublished). Maintainability campaign (2026-08-18):
breaking public-API cleanup is approved for this cycle; hot-path structural
refactors are deferred to `docs/maintainability-backlog.md` and land only
under the refactor-policy gates.

- **Fixed: `new Set`/`Map` bulk filled past a user-overridable adder.** The
  dense fast path calls the adder once per element but advances the iterator's
  cursor only once, at the end, and skips IteratorClose — invisible for the
  builtin `add`/`set`, plainly visible for a subclass's. A `Set` subclass whose
  `add` peeked at the source iterator read a cursor still at 0 (`peek 1` and
  every element, where QuickJS gives `peek 2` and every other one), and a
  subclass whose `add` threw let the error escape without running the
  iterator's `return`. The guard now also requires the adder to be the builtin;
  a subclass falls back to the ordinary IteratorStep/IteratorClose loop, and
  the fast path still triggers for plain `new Set([1,2,3])`.

- **Fixed: a skipped test that leaked was counted twice** in the timing test
  runner. The leak check turned the outcome into a failure but left the skip
  tally standing, so one test reported as `1 skipped; 1 failed`.

- **Collapsed the hand-written parser state snapshots** (−146 lines in
  `parser.zig`). The lexer cursor was saved and restored field by field at 11
  sites even though `takeLexerCursorSnapshot`/`restoreLexerCursorSnapshot`
  already existed and only three sites used them. Two of the 11 —
  the `export default function`/`class` lookaheads — restored six fields
  instead of seven, leaving `got_lf` (the flag automatic-semicolon insertion
  reads) describing the token the lookahead scanned rather than the current
  one; they now restore the full cursor. Separately, entering a class field
  initializer function saved, set and restored the same ten parser fields in
  three byte-identical copies, now `enterFieldInitFunction` /
  `leaveFieldInitFunction`. A class static block displaces four more fields on
  top of those ten and still open-codes them; that difference is documented at
  the type rather than silently unified.

- **One owner for the engine's error surface.** `RuntimeError` and `HostError`
  had three hand-written copies between them, and they had drifted:
  `context.DynamicImportError` was `HostError` spelled out member for member
  (123 = 123, both differences empty), and `host_function.CallbackError` — whose
  own doc comment called itself a mirror — was missing `StringTooLong`,
  `DerivedConstructorReturn` and `DerivedThisUninitialized`. The definitions now
  live in `core/errors.zig`, which core surfaces can name and which
  `exec.exceptions` re-exports.
  *Fixes an undefined-behaviour hazard:* `collection_adapter` bridged the gap
  with `@errorCast`, narrowing whatever `closure.callWithThis` returned down to
  `CallbackError`. That call actually returns `HostError`, so any I/O failure
  raised inside a `Map`/`Set` `forEach` or `groupBy` callback hit an error code
  outside the destination set — a safety panic in Debug, undefined behaviour in
  ReleaseFast. With the set defined correctly the cast is gone entirely.

- **Deleted 246 more unreferenced declarations, tree-wide** (−2,829 lines
  across 64 files). The previous sweep only looked at nine `exec/` files and
  only asked whether a name appears anywhere in the tree. Two corrections
  found the rest: deletion cascades, so the sweep runs to a fixed point
  (four rounds); and a **non-`pub` declaration is only visible in its own
  file**, so counting tree-wide hits lets a same-named declaration elsewhere
  keep a dead one alive. `call.zig`'s private `promiseCombinatorCall` — a
  143-line second implementation of the Promise combinators, with no
  callers — survived the first sweep exactly that way.
  `libs/unicode/data.zig` is excluded: its property tables are referenced by
  comptime name concatenation, which no text scan can see.

- **Deleted 118 unreferenced declarations across nine `exec/` files**
  (−2,087 lines, `.text` −1,596 bytes). Reachability was established by
  deletion rather than by inspection: the tree compiles, and Zig would have
  refused any name that still had a reference. Only top-level declarations
  were touched — struct fields are layout-bearing in this repository and stay.
  Names mentioned only in a doc comment count as referenced and were kept.

- **Fixed: `new Set`/`Map`/`WeakSet`/`WeakMap` indexed an Array argument
  instead of iterating it.** The dense read was selected on `isArray()`
  alone, so an array carrying its own `@@iterator` — or a patched
  `%ArrayIteratorPrototype%.next` — was silently indexed, while spread,
  for-of, `Array.from`, destructuring and `yield*` honoured it in the same
  process. The dense read now happens inside the iterator path, behind the
  same guard `appendSpreadValuesEnumerate` already applied, and reads from
  the iterator's target rather than the source.

- **Fixed: replacing `globalThis.Iterator` detached every builtin iterator
  prototype.** %IteratorPrototype% is a realm intrinsic, but it was resolved
  by walking the writable `Iterator` global and reading `.prototype` — so
  the first thing an Iterator-Helpers polyfill does broke Map, Set, Array and
  String iterators (`[...map.entries()]` threw `TypeError`) and made
  `Array.from(str.matchAll(re))` silently return `[]`. Deleting the binding
  was worse: two copies of the resolver invented two *different* synthetic
  bases, so Map and Array iterators stopped sharing one. It now reads the
  realm's class-prototype table, where the `Iterator` constructor already
  registered it, and the two copies became one.

- **Fixed: `Array.of`, `Array.from` and `Array.fromAsync` never ran a Proxy
  constructor's `construct` trap.** IsConstructor had two implementations;
  the one these entries used fell off its last branch with
  `class_id == c_closure`, so every Proxy answered false. The result was
  silent: a plain Array was fabricated and the trap counted zero calls, where
  the pinned QuickJS calls it once and returns the constructor's object. The
  two implementations are now one (−24 lines), and all 31 constructor shapes
  probed — plain/arrow/class/generator/async/method/getter, bound chains,
  builtins, and Proxies of each — agree with QuickJS.

- **Fixed: `Iterator.from` returned the source unwrapped when it should have
  wrapped it.** `Iterator.from` tests %Iterator%-instance-hood on the
  RESOLVED iterator, after `GetIteratorFlattenable`; this tested the SOURCE,
  before resolving, and only the branch where the source had no
  `@@iterator` could produce a wrapper at all. A class that is iterable,
  returns itself from `@@iterator`, and is not an %Iterator% therefore came
  back unwrapped with no iterator helpers on it —
  `Iterator.from(new T()).take(2)` threw `TypeError: not a function` where
  the pinned QuickJS returns the values. Three `sm/Iterator/from/*` test262
  cases left the exclusion list; the suite went 49,775 → 49,778 prepared,
  44,581 → 44,584 passed.

- **Fixed: `Number.prototype.toString(radix)` produced digits that name a
  different double.** For the 30 radices that are not a power of two, the
  digits did not identify the value they came from: 829 of 1,000 random
  doubles at radices 3/5/7/11/36 decoded back to a *neighbouring* double.
  Powers of two (2/4/8/16/32) were always exact, so hex and binary were never
  affected. The cause was a hand-rolled converter generating digits from an
  approximation; it is deleted (−96 lines) and the radix now goes through the
  same faithful `js_dtoa` port radix 10 already used — its wrappers had simply
  hard-coded 10. After: 0 of 2,100 round-trip failures, and byte-identical to
  the pinned QuickJS on all 2,100.

  Routing a non-decimal radix through that port also required fixing a stack
  buffer overflow on the way in: a `[9]u8` bounce buffer sized for the only
  radix that had ever reached it (10, whose `digits_per_limb` is exactly 9).
  Radix 3 writes 20 digits there. Upstream `dtoa.c` uses no temporary at all,
  and now neither does this.
- **`call_runtime.zig` sheds the Atomics, Reflect and iterator-protocol
  domains** (backlog H1, first three batches). Atomics: 1,000 lines and 44 top-level `pub fn`s moved to
  `atomics_ops.zig`, which until now held only an 88-line record table whose
  own doc comment pointed back at `call_runtime` for the method bodies.
  Reflect: eleven decls, interleaved with unrelated ones rather than
  contiguous, moved to `reflect_ops.zig`. Iterator protocol: fifteen decls to
  `iterator_ops.zig`, including `createIteratorResult`, whose four hand-written
  copies were merged earlier the same day. The call-chain file is down from
  7,510 lines / 208 pub fns to **5,811 / 144**. `Error.stack` and dynamic
  `Function` construction are still queued.
- **Merged the byte-identical cross-file duplicates** (−145 lines): 17 groups
  found by a same-name/same-body census, plus `monotonicNanos` (six copies,
  one of them an inlined body in a CLI root that could not reach
  `platform_clock.zig` — now exported through `internal_root`), and a
  `SourcePoint` struct declared identically in two resolver files.
- **One owner for the bare-runtime `ToString` fallback** (`core.value_string`,
  −363 lines). Seven copies of `appendValueString`, seven of its array leg,
  six BigInt cloners, five `appendUtf8CodePoint` wrappers and seven identical
  `AppendStringError` unions were spread across `exec/` and `core/`. Three of
  the four ways they had drifted were accidental and are now unified: float
  formatting (five copies used Zig's `{d}`, which renders `1e20` as `1e20`
  rather than the ECMAScript `100000000000000000000` — latent, since every
  reachable path coerces through a realm-aware `ToString` first), BigInt
  rendering, and string encoding. The fourth is real and survives as a
  comptime `Policy`: callers legitimately disagree about Symbols, primitive
  wrapper objects, and what a value with no `ToString` form becomes, so each
  site keeps exactly its previous behavior.
- **One owner for string-to-UTF-8 appending.** Eight hand-written copies of
  qjs `JS_ToCStringLen2` existed across `exec/` and `core/`, and their comments
  recorded the same defect being repaired independently six times: latin1
  0x80-0xFF must widen to UTF-8 instead of landing raw, and UTF-16 surrogate
  pairs must combine into one 4-byte sequence instead of encoding per unit. Two
  copies still carried an older form. Authority sank to
  `core.string.appendValueUtf8` — core, because two of the copies are core
  files, which cannot import exec. `value_ops.appendRawString` stays as the
  published embedding name and forwards. −99 lines.
- **Fixed: Map, Set and String iterator results had no prototype.** ES
  `CreateIterResultObject` (7.4.14) is `OrdinaryObjectCreate(%Object.prototype%)`,
  and the pinned QuickJS agrees, but `new Map().entries().next()` returned a
  null-prototype object — so `.hasOwnProperty` on an iterator result threw
  `TypeError: not a function` and `String(result)` threw. Array, generator,
  arguments, typed-array and RegExp iterators were already correct.

  The cause was duplication: four hand-written copies of
  `CreateIterResultObject` existed alongside the real owner, and two of them
  passed a null prototype. All four are now thin wrappers over
  `createIteratorResult`, each stating its ownership contract (three consume
  the value, the closure one borrows). The Map/Set dispatch arm was also
  discarding a realm it already held — it called the global-less `methodCall`
  where every neighbouring arm calls `methodCallObjectWithGlobal`. Regression
  test pins all eleven builtin iterator producers to the same answer.
- **Binary size: the release artifact went from 31.2 MB to 4.26 MB** (tarball
  7.5 MB → 1.9 MB), with the engine's own machine code down 8.2%
  (4,646,632 → 4,264,592 bytes stripped). Three independent items:
  - **Release tarballs now ship a stripped `zjs`.** 26 MB of the old artifact
    was DWARF that no user reads. `nightly.yml` strips post-link, before the
    configuration-signature check, so the check runs on the bytes that ship
    and `.text` plus the `.text.zjs.op_handlers` island stay byte-identical to
    the binary the gates measured — a `-fstrip` build does not (it moves
    `.text` by 40 bytes). arm64 macOS re-signs, because `strip` invalidates
    the ad-hoc signature. No build step strips by default: `nm`, `addr2line`
    and `perf` attribution all need the symbols.
  - **ReleaseFast CLIs panic with the message only** (−209 KB,
    `src/cli/panic_policy.zig`). The default handler drags in an ELF symbol
    reader, a DWARF line-table reader, a flate decompressor and two 30 KB-class
    sort instantiations to symbolize a trace that a stripped binary cannot
    resolve anyway. Debug and ReleaseSafe keep the full handler, so `zjs-dev`
    and every test artifact still print resolved traces.
  - **Sorting moved off `std.mem.sort` where stability is not observable**
    (−173 KB). `std.mem.sort` is `std.sort.block`, whose in-place merge costs
    ~22 KB of machine code *per element type*; eleven instantiations were
    258 KB. Sixteen call sites moved to `std.sort.heap` (~0.2 KB each); the
    two sites where equal elements are distinguishable and ordered —
    `Array.prototype.sort`'s default string order and the RegExp `v`-flag
    string set — keep the stable sort and now say why. Rule recorded in
    GUIDE A.7.

  Validation: `checkpoint-gate`, `test-exec`, test262 0/49775, and a
  refactor-policy rule-2 bench-v8 A/B against the merge base
  (`20ccc8c1`) — composite Score medians 2717 / 2716, ratio **1.0006**, with
  per-suite deltas mixed in sign (RegExp +3.4%, RayTrace −0.9%), the signature
  of layout noise rather than a semantic effect.
- **Fixed four independent memory leaks** that each tripped the
  `allocation_count == 1` teardown assert in `JSRuntime.deinit`, which had
  blocked running the Debug test262 suite as one process (it aborted after
  roughly 7,000 cases; `docs/borrowed_atom_audit.md` carried a standing
  "run by subtree" workaround). All four were pre-existing and independent:
  - `src/bytecode.zig`: `FunctionDef.deinitInitFailure` did not free
    `v2_builder`, which `initRootEmitter` attaches before the first token is
    lexed — so any lex error on a source's *first* token leaked the builder
    (`eval("@")`, every hashbang test, the Mongolian-vowel-separator test).
  - `src/core/runtime.zig`: teardown's cycle removal sweeps dead weak
    payloads, and a `FinalizationRegistry` whose target died enqueues its
    cleanup callback — re-growing the job queue's backing block *after*
    `job_queue.deinit()` had already run. `clearPendingFinalizationJobs`
    drained the entries but never released the storage.
  - `src/exec/string_builtin_ops.zig`: `stringCharCodeAtDirectHost` freed the
    receiver only when it was not already a string, but the coercion helpers
    dup a string receiver and always return an owned ref.
  - `src/libs/regexp.zig`: `reParseClassAtomOrRange` took ownership of a
    class-escape atom's `CharRange` from `getClassAtom` but dropped it on the
    rejection and rewind legs (`RegExp("[\d-a]","u")`, `RegExp("[a-\d]","")`).

  Verified by executing all 53,572 test262 files under the Debug runner with
  zero `allocation_count` hits. Four unrelated Debug asserts still block a
  whole-set single-process run; they are now enumerated in
  `docs/borrowed_atom_audit.md` §7.3 instead of being folded into one vague
  workaround.
- Fixed `zjs --leak-check` crashing on an otherwise clean run: the dynamic
  import loader scope's `defer` ran after `runtime.deinit()` and touched the
  destroyed runtime. The scope is now restored before teardown (`restore` is
  idempotent, so the defer becomes a no-op).
- **Gate and test audit (2026-08-19).** Reviewed every gate and test target
  for things that could be dropped or were over-built, then closed the two
  gaps the audit found.

  Removed:
  - The **NaN-boxed 8-byte JSValue representation** and everything that
    served it: `-Dzjs_nan_boxing`, the `NanBox` encoding namespace, the
    `test-altrepr` nested build, and the per-representation branches through
    `core/value.zig`, `exec/inline_calls.zig`, `exec/tailcall_dispatch.zig`
    and `core/jobs.zig`. No shipped platform used it (every release target is
    64-bit and ships `repr=tagged`), its A/B value was disproved in
    2026-08-07, and its guard had been a known-red gate since 2026-08-18 — a
    permanently-failing gate teaches nothing. `JSValue` is now unconditionally
    16 bytes. The `repr` component stays in the configuration signature, now
    derived from `@sizeOf(JSValue)`, so recorded signatures keep their meaning
    and the signature string is unchanged.
  - The **`perf-self-check` / `perf-self-update-baseline`** self-baseline gate,
    its checked-in baselines under `reports/perf/baseline/`, and
    `tools/perf/write_env.js`. Performance verdicts now come from bench-v8
    (published metric, and the rule-2 instrument) and the zoo (attribution).
  - The test262 runner's **`--regression-baseline`** flag and its per-directory
    comparison machinery: dead code with no caller anywhere, whose only tests
    tested itself, and which — when enabled — *suppressed* the zero-failure
    gate it was meant to strengthen.
  - The deprecated aliases `quick-check`, `checkpoint-check`, `test262-gate`,
    `test-compiler-v2`, and `-Dzjs_v2_layout`, as promised for this release.

  Added:
  - `test262-check` now runs **on every pull request** (linux-arm64). It is a
    zero-failure gate, so this is the sharpest semantic-regression signal
    available; previously a regression could live on `main` for up to a day
    until the nightly caught it.
  - `test -Dzjs_ownership_audit=true` now runs **nightly**, and a failing
    nightly opens or updates a tracking issue. That tier used to depend on a
    developer remembering to run it, which is exactly how the representation
    guard rotted unnoticed.
  - `test-oom` joins it too — but running it first revealed the target had
    been failing on `main` for a long time, unnoticed precisely because
    nothing ran it. Four independent pre-existing defects, all fixed:
    - **The native-call seam could claim an exception nobody installed.** It
      reports failure by returning the exception sentinel, and `nativeIsExc`
      asserts sentinel implies a pending exception — but when the heap was
      exhausted, building the Error object failed, `nativeFromHostError`
      swallowed that with `catch {}`, and the sentinel went out anyway,
      tripping the assert. `materializeRuntimeError` now falls back to the
      Realm's preallocated out-of-memory value, the same allocation-free path
      VM catch delivery and `throwInterrupted` already use.
    - **An uncaught out-of-memory reached the embedder as `error.JSException`.**
      Allocation failure is deliberately catchable (it becomes
      `InternalError: out of memory`), so the seam collapsed the original
      `error.OutOfMemory` into the generic JS-exception error and the other
      half of the contract — "paths without a JS catch handler still surface
      `error.OutOfMemory` to the embedder" — was not held. The runtime now
      carries `current_exception_out_of_memory` alongside the existing
      `current_exception_uncatchable` flag, and the embedder-facing
      `binding.JSContext` entry points restore `error.OutOfMemory` when the
      exception was never consumed by JavaScript.

      The restore happens **only** at that boundary. Widening the error inside
      the engine was tried and reverted: it changed control flow everywhere
      that treats `error.OutOfMemory` as a pre-user-code allocation failure —
      the pending exception stopped matching itself and was rebuilt (losing its
      stack), promise jobs re-queued on it, and module and async-generator
      paths turned it into a hard error instead of a rejection.
    - **`error.OutOfMemory` was missing from `errorNameForRuntimeError`**, even
      though `runtimeErrorInfo` maps it to `InternalError`. Because of the gap
      `pendingExceptionMatchesError` did not recognize an already-pending
      out-of-memory exception, so a second materialization cleared it and built
      a replacement — allocating on an exhausted heap and discarding the
      original error's stack.
    - **The for-of iterator-close path dropped exception flags.** It takes the
      pending exception, closes iterators (which can run user code), then
      re-throws the same value; `takeException`/`throwValue` reset the flags in
      between. Uncatchable interrupts already dodged this by returning early —
      out-of-memory cannot, so the flag is now carried across the round trip.

  Retained deliberately: `-Dzjs_force_gc` (demoted from an expected gate to a
  diagnostic instrument) and `JSValue.abi_encoding_revision` (fixed at 1;
  removing it would churn the plugin ABI fingerprint for no gain).

  The engine deletion was verified machine-code-identical under the
  identity gate. That verification also corrected the gate's own protocol:
  sampling three incremental rebuilds per source showed that *both* the
  changed and unchanged trees reach the same two images in arbitrary order,
  so a single build is not a verdict. `reports/identity/baseline.json` now
  records the admissible image **set** rather than one hash per build
  protocol, and `docs/refactor-policy.md` requires set membership.
- Reinstated **refactor-policy rule 2** (suspended 2026-08-19 for the
  maintainability campaign, which has closed) with bench-v8 as the measuring
  instrument in place of the 15-item zoo: it is the metric the project
  publishes, and its serial protocol costs about an hour per item against the
  zoo's half day — the cost that drove the gate into suspension. The
  comparison runner grew an explicit `--baseline` A/B mode that names the
  reference role in its output and JSON artifact, so a refactor A/B cannot
  later be misread as a QuickJS comparison.
- Switched the public performance metric to **bench-v8** (the V8 benchmark
  suite version 7 — the suite upstream QuickJS publishes its scores with)
  and vendored it unmodified under `tools/perf/bench_v8/suite/` (from the
  V8 repository at tag 7.9.317; BSD license headers retained). Added the
  pinned ABBA-interleaved comparison runner
  (`tools/perf/bench_v8/run_benchv8_compare.py`), a `perf-bench-v8`
  diagnostic build step, and `docs/perf/bench-v8-status.md` as the
  authoritative score page. The 15-benchmark zoo suite remains an internal
  diagnostic; its last baseline is preserved in `docs/perf/zoo-status.md`.

### 0.2.0 breaking public API

- Renamed the compiler directory `src/compiler_v2/` → `src/compiler/` (owner
  ruling 2026-08-19, reversing the earlier "ruled out" backlog entry). The
  build step `test-compiler-v2` → `test-compiler` and the option
  `-Dzjs_v2_layout` → `-Dzjs_compiler_layout`; both old names remain as
  deprecated aliases until the next release. The attested configuration
  signature string (`zjs-config-v2:compiler=v2,...`) is intentionally
  unchanged: "v2" is the compiler's published identity, not the directory
  name. Verified by the tightened identity-gate protocol: pre- and
  post-rename sources each produce the identical stripped-image set across
  both known build-bistability attractors (incremental-converged
  `e93b69e8`, cold-cache `5df9578f`), so the rename provably changes no
  machine code or data in either build mode.
- Removed the `zjs.host.NativeBinding` `Storage.inlineValue` constant alias.
  It was visually a sibling of the function `Storage.externalPtr(...)` while
  actually being a constant for the enum tag `.inline_value`. Migration: use
  the enum literal `.inline_value` directly.
- Named the parser's dual emission streams (backlog H13): the builder-stream
  State veneers dropped their `v2` prefix for `builder*` (`builderEmitOp`,
  `activeBuilder`, …), the parser-error facade free functions dropped the
  cryptic `v2F` prefix for `emitter*` (`emitterOp`, `emitterBindLabel`, … —
  the `F` meant "parser-error-typed Facade"), ~30 `v2_*` locals/fields
  dropped the prefix, and the dual-stream unions now tag their arms
  `temp`/`builder`. The compiler-contract F-5/F-6 dead code (never-assigned
  finally-label twin, four `*NoFinallyCapture` emitters,
  `emitForwardJump*`/`patchForwardJump`; −78 lines) is deleted. The
  identity gate first caught the deletion shifting `.text` by −432 bytes
  (a struct-field deletion is a layout payload — the QCP-1B class); it
  landed under the 2026-08-19 owner ruling that temporarily suspends the
  zoo A/B requirement, with the layout effect measured and recorded. The
  contract was also corrected where its description disagreed with the
  code (the fixup lists have live assertion guards and stay).
  `FunctionDef.v2_builder` keeps its name pending H10.
- Removed the historical `qjs*` function prefix entirely (527 unique names;
  owner ruling: mirroring quickjs.c is a transitional state, not the
  project's identity — names describe function, not provenance; alignment
  evidence stays in `// quickjs.c:N` comments and commit messages). 488
  names stripped mechanically after a collision pre-scan; the 39 collision
  cases were resolved individually: context-layer entry points gained a
  `Call` suffix (`arrayBufferResizeCall`, `dataViewGetCall`, …), five
  proved to be duplicates or dead forwards and were merged or deleted
  (including a byte-identical double `freeValueList` in one file), and two
  same-name/different-meaning pairs were disambiguated on both sides
  (`iteratorCloseValue` vs the opcode pair; `descriptorFromObject` /
  `descriptorFromObjectBare`).
- Deduplication pass (backlog H4/H5, landed under the zoo-gate suspension):
  every call site of the 17 `objectFromValue` copies that skipped the
  VarRef-cell `kind` re-check was classified — no live bug; the authority
  (checked, trusted-expression, and `expectObject` variants) sank to
  `core.value_semantics`, and the copies became forwards or explicit
  Trusted calls with the safety argument now named at each site. Deleted
  the 15 pure-forwarding `qjsIteratorZip*`/`qjsIteratorHelper*` shells in
  `call_runtime.zig` (zero external callers) and merged the
  `functionPrototypeFromGlobal` / `numberValue` duplicate implementations.
  GUIDE A.7 now requires a `mirror of <owner>, keep in sync` comment on any
  layering-forced helper copy.
- Disambiguated the remaining cross-file same-name traps:
  `tailcall_dispatch.run` → `runDispatchLoop` (vs the outer `zjs_vm.run`),
  `string_builtin_ops.iteratorNext` → `stringIteratorNext` (vs the
  iterator-protocol `iterator_ops.iteratorNext`), `vm_property`'s
  `fastInt32Add/Sub/Mul` → `checkedInt32Add/Sub/Mul` (overflow-intrinsic
  strategy, vs `vm_arith`'s deliberately widening `fastInt32*`), and the
  TDZ throw stragglers → `throwTdzReferenceError` /
  `throwGlobalTdzReferenceError`. Documented the throw-helper patterns,
  the `*ForFastPath` (ingredient) vs `*Fast` (fast variant) distinction,
  and the `X_ops` / `X_builtin_ops` split rule in `docs/architecture.md`.
- Renamed `src/exec/property_ic.zig` → `property_direct.zig`: the inline
  cache it was named after is long deleted; the file holds non-cached
  direct property fast paths. Deleted the always-false
  `cachedSetObjectDataPropertyForPutFastPath` zombie (zero callers; its
  "ABI stability" comment was stale). Disambiguated the H12 same-name
  traps: `call.zig`'s global-slot property walk is now
  `getValuePropertyViaGlobalSlots` (the full-semantics
  `object_ops.getValueProperty` is unchanged), and `object_ops`'s
  by-name define is now `defineDataPropertyByName` (the by-atom
  `property_ops.defineDataProperty` is unchanged). Documented the exec
  naming conventions (`vm_X` vs `X_ops` split, `Vm` suffix, `qjs*` prefix
  caveat, ownership-suffix policy) in `docs/architecture.md` and GUIDE A.7.
- Renamed `src/exec/vm_exception_ops.zig` → `exception_ops.zig` (all ~40
  importers already aliased it as `exception_ops`), unified the nine
  inverted `X_vm` import aliases onto their `vm_X` file names, renamed the
  cryptic `td` alias to `dispatch` in the cold-handler table, unified
  `module_exec` → `module_mod`, removed the duplicate `exec.eval` re-export
  (`exec.eval_entry` remains), and deleted the orphan 17-line
  `src/exec/iterator.zig` (no callers). Verified with the batch-tier
  identity gate.
- Refactor policy: added the identity-gate baseline registry
  (`reports/identity/baseline.json`) and the batch tier for mechanical
  rename campaigns (one identity closure per batch; per-change gating stays
  for hot-path structural changes).
- Naming-consistency pass (2026-08-19), verified change-free on both
  build-bistability attractors (stripped-image identity): unified the
  misleading `src/exec/` import aliases onto their file names (`class_vm` →
  `object_ops`, `collection_vm` → `array_ops`, `iter_vm` → `iterator_ops`,
  `date_vm` → `date_ops`, `weak_ref` → `builtin_glue`, `symbol_builtin` →
  `primitive_ops`, `buffer_builtin` → `buffer_ops`, `function_bytecode` →
  `bytecode`) and dropped the duplicate `object_ops` import in
  `tailcall_dispatch.zig` (backlog H3). Renamed `construct.zig`'s local
  `isErrorConstructorName` wrapper to `isConstructErrorObjectName` — it
  forwards a *different* predicate (no `SuppressedError`) than the
  identically named `vm_exception_ops` function (backlog H12 hazard).
  Fixed the remaining GUIDE A.7 style violations: `cur_func` → `curFunc`
  (parser), `h_*` comptime handler factories → `handler*` (dispatch colds),
  `unicode_script` → `unicodeScript` (regexp properties). GUIDE A.7 now
  documents the intentional mirror-name exemptions (`op_<opcode>` handlers,
  ported dtoa C ABI names, JavaScript-identifier constants, camelCase
  function-pointer vtable fields).
- Removed empty public shells with no in-tree users:
  `zjs.object.Builder`, `zjs.object.Template`, the `zjs.compile` namespace
  (`SourceKind` / `Options` / `Cache`), and the `zjs.error` namespace
  (`Info` / `Kind` / `Span`). Migration: delete those names; they had no
  producers.
- Removed dual handle aliases. `zjs.value.Ref` → `zjs.value.Persistent`;
  `zjs.value.WeakRef` → `zjs.value.Weak`; `zjs.host.NativeClass` →
  `zjs.host.NativeBinding.JSObject`.
- Ownership verbs: `JSValue.Persistent.release()` (transfer) is now
  `take()`. `HandleScope.exit()` is gone; use `deinit()` (idempotent, so
  an early close is another `deinit()`). `NativePin.release()` is gone;
  use `deinit()`. `Persistent.destroy(rt)` remains as a by-value
  compatibility wrapper. `Store` / `BorrowGuard` / `PropName.release`
  are unchanged.
- `dumpSmallInlineProbe` is no longer a public root export. The CLI probe
  is internal `printSmallInlineProbe`.
- `PropNameID.getProperty` now returns `GetPropertyError` instead of
  `DynamicImportError`. The error members are the same.
- Binding `string.zig` / `bytes.zig` forwarding shells are folded into
  `binding/root.zig`. Public `JSString` / `JSBytes` names are unchanged.
- `build.zig.zon` version is `0.2.0-dev`.
- Embedding tests now carry a same-file public-name list (not a freeze, not
  the removed `check_public_api.zig` tool). Adding or removing a public
  name must update that list in the same commit.

- Strict-mode functions now perform proper tail calls (ES2015 14.6): plain
  `return f(...)` tails — including conditional-expression arms and
  unconditional-jump joins — reuse the caller frame, so deep strict
  direct/mutual recursion (1e6) runs in constant stack and the reused
  caller drops off `Error.prototype.stack`. This is a deliberate,
  documented divergence from the pinned QuickJS. Sloppy code, method
  tails, `try`-protected calls, and eval-tails keep QuickJS-aligned
  frame growth and overflow behavior. See LIMITATIONS.md.
- Architecture `check_deps.js` now enforces compiler_v2 layering and scans
  `tools/` / `tests/` files that import the `zjs` module. The duplicate
  core-does-not-import-runtime Zig test is gone; the JS linter is the authority.
- Renamed `quick-check` → `quick-gate`, `checkpoint-check` → `checkpoint-gate`,
  and `test262-gate` → `test262-check`. Old names remain as deprecated aliases
  until the next release. See `docs/testing-graph.md`.
- Package `build.zig.zon` now ships COMPATIBILITY/LIMITATIONS/CONTRIBUTING/
  STATUS and `test262.conf`. mise pins node 24 and bun 1. Linux CI jobs
  install Node (checkpoint and production-gate invoke it via the build graph).
- Unified tests now compile through `internal_root` and assert they are a
  declared superset of it (Object is the only type fork). The previously
  dormant internal Object-identity test is collected (+2 unified tests).
- Scoped test targets now share one `src/<area>_tests.zig` shell ×
  `tests.<area>.` filter convention. Test names gained a `tests.` prefix
  (e.g. `core.test.foo` → `tests.core.test.foo`); counts are unchanged.
  New `test-embedding` target compiles the public `zjs` module.
- Extracted the shared exec/builtins test harness to `src/tests/helpers.zig`.
  `test-builtins` no longer compiles `src/tests/exec.zig`.
- Split `build.zig` into `build/{config,profiles,artifacts,tests,perf,gates}.zig`.
  Option order, step names, and the shipped `zjs` binary are unchanged.
- Refactor policy updated: maintainability work proceeds by risk zone;
  mechanical identity gates (binary-identical / .text-identical) may
  substitute for the zoo A/B where machine code provably does not change.
- Trimmed remaining local report write-outs: disconnected opcode-profile
  snapshots and `reports/test262-latest/` are gitignored. Dated `qjs-align`
  dumps stay in git history; new dated dirs keep markdown notes.
- Removed the public API symbol snapshot. The declaration surface is not
  frozen yet; `docs/public-api-contract.md` and the embedding tests remain
  the contract. `architecture-update-api-snapshot` and
  `tools/architecture/check_public_api.zig` are gone.
- Dropped the named `architecture-check` step. Checkpoint still runs the
  source lints (deps, OOM-panic, borrowed-atom, compiler-stage
  declarations) inline. The production gate adds the ReleaseFast `nm`
  check that those stage-boundary symbols remain independent.
- Dropped legacy-pipeline eradication (`check_legacy_pipelines_gone.js`).
  The remaining gate is `check_compiler_stage_boundaries.js`.
- Narrowed the OOM-panic lint to OutOfMemory-discard and
  catch-unreachable-on-alloc. The remaining allowlist entry is the
  rope-flatten last resort.
- Dropped redundant CLI `--seed 0` from live build commands and docs.
  `build.zig` already pins `graph.random_seed` to `0`.
- Removed `config-drift-gate`, `test262-smoke`, `final-switch-selftest`,
  and `tools/final-switch/`. Compile-time `attest()` and
  `config-signature-check` remain.
- Split validation docs so ReleaseSafe, `test-oom`, `test-altrepr`,
  force-GC, and ownership-audit are phase-close or change-triggered, not
  checkpoint or per-commit gates.
- Documentation terminal-state cleanup (2026-08-19): README/STATUS now carry
  the clean-field zoo headline (1.0304, `main@0c32a71c`) instead of the
  contaminated r3 numbers; stale claims fixed (per-opcode profiling works on
  `zjs-profile`; strict-mode PTC is landed); `qcp1_switch_decision.md`
  condensed to its close-out rulings (§0.1.6/§8/§8.5/§9 preserved);
  `borrowed_atom_audit.md` trimmed to the ownership contract and governance
  protocol; the 2026-07-27 subsystem baseline gained an errata header;
  `docs/README.md` reorganized by audience; `docs/agents/` merged 4 files
  into 2; the same-runtime verifier README moved to
  `tools/perf/same_runtime/VERIFIER.md`.

## 0.1.0 - 2026-08-17

First real release, replacing 0.1.0-alpha.1 and 0.1.0-alpha.2. The checked
test262 profile reports zero failures (44,581 pass). The 15-item javascript-zoo
geomean is 1.0141 vs QuickJS. Trusted-code embedding positioning is unchanged:
`zjs` is not an in-process sandbox for hostile JavaScript.

- Completed QCP-1B: removed the legacy Phase 1/2/3 compiler, dual comparator,
  and `-Dzjs_compiler` option. Deletion bisection traced the former crypto
  regression to shrinking `CompileContext` by one unused pointer, which
  perturbed Zig 0.16 whole-program native layout despite identical bytecode and
  allocation streams. The same-sized reserved word was used only as a control;
  the shipped fix restores explicit non-inlined boundaries around V2 lowering
  and the stack-size walk. The no-padding deletion candidate measures 1.0061x
  on the 15-item Zoo A/B. The diagnosis and amended verdict are in
  `docs/qcp1_switch_decision.md` §9.
- Fixed Array sort writeback when an indexed setter mutates a successor
  element, Error.prototype.stack setter edge cases, and TypedArray
  DefineOwnProperty detach-during-conversion semantics.
- Removed the historical C QuickJS performance comparison workflow and
  `perf-compare`; the checked performance gate is the ZJS self-baseline.
- Added a `run_runtime_profile.js` helper and `zig build perf-uri-profile`
  shortcut for checked single-script `--perf-json` artifacts that stay separate
  from multi-case microbench reports.
- Extended checked runtime-profile artifacts with opcode summary rows and added
  opcode-specific runtime diff metrics such as `opcode_count:get_var_ref0`.
- Added deterministic opcode-count ceilings to checked runtime-profile runs so
  focused hot-path fusions fail loudly when their opcode reductions disappear.
- Added `diff_runtime_profile.js` so single-script runtime profiles can be
  compared with explicit timing/allocation regression and improvement gates.
- Added an empty checked-local int32 for-loop range skip for loops whose body is
  only the induction update, reducing the `empty_loop` profile from 60007
  opcodes to 7 while preserving interrupt fallback.
- Added a dense array indexed append fast path for simple int32 multiply/mask
  element expressions while preserving inherited indexed setter fallback.
- Added a var-local int32 arithmetic-store fast path for microbench-style loop
  bodies without changing loop condition or post-update semantics.
- Added narrow `String.fromCharCode` and `Math.min`/`Math.max` method-call fast
  paths that keep object coercion and monkey-patched methods on the generic
  call path.
- Added local, closure, and global simple-numeric bytecode call add-store fast
  paths for tight `acc += fn(i, c)` loops while preserving non-simple function
  side effects.
- Tightened the URI 4-byte decode comparison fast path to use a borrowed
  native-method guard instead of transient method value dup/free churn.
- Shortened the percent-hex simple string add-store path used by URI decode
  fixtures by avoiding the transient helper result value before global writeback.
- Added a guarded `make_var_ref` assignment fusion for `global = string +
  percentHex(int)` loops so reference setup and `put_ref_value` are skipped when
  all participating bindings are ordinary global data properties.
- Added matching global-string and literal-prefix declaration initializer
  fusions for `var next = prefix + percentHex(int)` and `var next = "%F0%A0" +
  percentHex(int)`, eliminating the URI 4-byte profile's remaining
  `get_var_ref0` executions.
- Added a backward-goto global int32 condition fusion that replays the target
  loop condition directly at the backedge when it is an ordinary global data
  comparison, reducing the URI 4-byte profile's `get_var` executions by 66576.
- Extended the URI strict-equality branch-count fusion to ordinary global data
  `count++`, reducing the URI 4-byte profile's `if_false8` executions from
  65536 to 1 and its `get_var` executions by another 65535.
- Refreshed active documentation to match the current build steps, test262
  boundary, ZJS self-baseline performance gate, and tracked active reports.
- Removed the completed Production v1 roadmap from the active docs; public API,
  compatibility, and release-checklist docs are the current authorities.
- Merged the small Compatibility v1 summary into `COMPATIBILITY.md` so the
  compatibility boundary has one active source of truth.
- Removed old one-off test262 slice and QuickJS comparison report directories
  from `reports/`; the active gate report remains `reports/test262-latest/`.
- Removed the future-oriented Bun/uWS GC design note from the active docs; the
  current GC boundary remains documented in `README.md` and `LIMITATIONS.md`.
- Removed the unused opcode-alignment report snapshot from `reports/`.
- Removed historical phase/ledger documents from the active tree:
  `docs/gc-memory-lifecycle-candidates.md`, `docs/perf/roadmap.md`, and
  `reports/perf/baseline/phase-a-baseline.md`.

## 0.1.0-alpha.2 - 2026-05-22

- Added an explicit `--leak-check` CLI strategy to cleanly execute engine deinitialization (`runtime.deinit()`) and perform GPA memory validation on demand.
- Created `LIMITATIONS.md` providing architectural transparency regarding garbage collection circular references, FFI, CommonJS vs ESM, and standard library support.
- Created `COMPATIBILITY.md` detailing the active test262 test suite configuration, skipped features/categories, and recently added progressive ES2024+ features.
- Refactored `README.md` first-screen positioning text and added references to compatibility and limitation docs.

## 0.1.0-alpha.1 - 2026-05-20

- Reached a clean active local test262 gate: 0 errors and an empty
  `test262_errors.txt`.
- Improved WeakMap, WeakSet, WeakRef, and FinalizationRegistry handling for
  non-registered Symbol weak keys and targets.
- Fixed strict script top-level `this`, bound function `toString`, TypedArray
  descriptor behavior, BigInt typed array 64-bit wrapping, Array species
  creation, Annex B direct eval function behavior, and multiple RegExp
  Unicode/property escape paths.
- Added focused Zig regression coverage for the compatibility fixes above.
- Added public release metadata and package manifest paths.
