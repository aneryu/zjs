# Compatibility and Validation

JavaScript behavior follows ECMA-262. The validated scope is the repository's
`test262.conf`, pinned `test262/` submodule, and focused Zig/CLI tests;
it is not a claim of complete ECMAScript or host-platform support.
TypeScript and host boundaries are listed in [LIMITATIONS.md](LIMITATIONS.md).

## Test262 Gate

Inputs are `test262.conf`, `test262/harness`, `test262/test`, and
`test262_errors.txt`. The known-error file is empty: the configured gate
allows no failures. Dated counts and the corpus pin live in
[STATUS.md](STATUS.md#test262); they do not validate an untested checkout.

Gate timing and commands have one authority:
[verification policy](docs/verification-policy.md), with command details in
[GUIDE Part B.6](GUIDE.md#b6-validation-tiers). Full test262 runs at the merge
batch/CI boundary. Use a focused file or directory for local diagnosis.
The runner writes local reports to `reports/test262-latest/` (gitignored).

## Configured Skips and Excludes

`test262.conf` is the exact selection. Its major exclusions include:

- `intl402/` and related Intl data/API features.
- Temporal, ShadowRealm, decorators, deferred/source-phase imports, and
  the other feature groups marked `=skip`.
- Most staging tests, with selected useful slices re-included and explicit
  exclusions for incompatible SpiderMonkey-specific expectations.
- `tail-call-optimization`; current tail-call scope is documented in
  [Limitations](LIMITATIONS.md#proper-tail-calls).
- `immutable-arraybuffer` and `import-bytes` (owner decision, 2026-10-01).
  zjs does not implement the Immutable ArrayBuffer proposal. The draft and
  the pinned test262 disagree on its element semantics, so zjs follows
  QuickJS, which implements neither feature and skips both. `import-bytes`
  depends on immutable buffers, so it is skipped as well. `type: "bytes"`
  imports still load, over a plain ArrayBuffer. Exit criterion: the
  proposal and test262 agree and the owner re-enables it.

Never broaden skips or excludes to manufacture a pass. A deliberate boundary
change needs a concrete implementation plan, reproducer, spec basis, relevant
reference evidence, and an exit criterion.

## Local Test262 Overrides

The runner checks `tests/fixtures/test262-overrides/` before the selected
submodule file. An override is permitted only for a narrow upstream source
contradiction with another enabled test/harness feature.

Keep the original path selected, do not change `test262_errors.txt`, and
remove the override when upstream is corrected. Overrides must never hide
an engine failure.

## Supported Areas Under Active Validation

The configured profile covers modules, async functions/iteration, BigInt,
typed arrays, Proxy/Reflect, classes/private fields, iterator helpers,
explicit resource management, JSON source context, promise combinators,
Set methods, RegExp indices/modifiers/escape/property escapes, and modern
Array/String/Object/Promise additions listed in `test262.conf`.

[CLI smoke tests](tests/smoke_test.zig) and focused engine regressions cover
host integration and behaviors outside the full test262 selection.

## Comparison With Upstream QuickJS

QuickJS is a differential reference, not the compatibility definition.
When it disagrees with ECMA-262, follow the spec and record the divergence.
Compare equivalent runner configurations before attributing a difference.

The pinned QuickJS profile skips several features selected locally, including
`Atomics.waitAsync`, `arbitrary-module-namespace-names`, `Array.fromAsync`,
`await-dictionary`, `explicit-resource-management`, `import-text`,
`joint-iteration`, `legacy-regexp`, and `nonextensible-applies-to-private`.
Both profiles skip `immutable-arraybuffer` and `import-bytes`.

The local profile also enables `host-gc-required`. Its selected staging cases
cover generator lifetime, WeakMap, detached buffers, dictionary properties,
and `for-in` across explicit GC. Different staging selections make raw
cross-engine pass counts unsuitable as a completeness comparison.

### Known deviations from ECMA-262

- **Parameter environment (FunctionDeclarationInstantiation, §10.2.11).** In a
  function with parameter expressions, a closure created by a default value
  captures the parameter binding, but a body reference to a parameter that the
  body does not redeclare with `var` reads a separate argument slot, so
  `(function (a, f = () => { a = 3; }) { f(); return a; })(1)` returns `1`
  instead of `3`. Any write to an earlier parameter from a later default is
  lost to the body the same way, closure or not: `function f(a, b = a++)
  { return a }` returns `1` for `f(1)`. The body also shares the parameters'
  variable environment, so a direct eval's `var` of a parameter's name does
  not create a new binding: `(function (a, b = 2) { eval("var a"); return a;
  })(3)` returns `3` instead of `undefined`. Inherited from QuickJS; no
  test262 case in the profile covers it.
- **Assignment to a `const` in a function with direct eval (§13.15.2).** In a
  function whose scope contains a direct eval, `x = rhs` where `x` is a
  `const` throws when the reference is created, before `rhs` is evaluated,
  so side effects of `rhs` (including an eval's own early errors) do not
  happen. The thrown error is the one PutValue would throw.
- **Class heritage and computed keys in sloppy code (§11.2.2).** The
  `extends` expression and computed member keys are compiled into the
  enclosing function, so in a sloppy script they run with sloppy runtime
  semantics: an assignment to an undeclared name creates a global and a
  failed property write or delete is silent instead of throwing. Early
  errors in these positions are strict. Inherited from QuickJS.
- **Annex B block functions shadowed by a later lexical declaration
  (B.3.2.1, B.3.2.2).** The var copy of a block function is decided when the
  function is parsed, so a `let`/`const`/`class` of the same name declared
  later in an enclosing scope does not cancel it: at script level
  `{ function b(){} } const b = 3;` throws a ReferenceError, and inside a
  function `{ { function b(){} } let b; }` leaves `b` a function.
- **Annex B block functions in eval code against a global lexical
  (B.3.2.3).** With a global `let b`, `eval("{ function b(){} }")` throws a
  SyntaxError instead of skipping the var copy.
- **Direct eval var conflicts (EvalDeclarationInstantiation, §19.2.1.3).**
  When a direct eval's `var` collides with an enclosing block's lexical
  binding, the eval's other global `var`s are created before the SyntaxError
  is thrown. Inherited from QuickJS.
- **`this` for a call through `with` from direct eval (EvaluateCall,
  §13.3.6.1).** Inside `with (o) { eval("f()") }` a function found on `o` is
  called with the global object as `this` instead of `o`; the same call
  written directly in the `with` block is correct.
- **Legacy RegExp static properties after a subclass match (legacy RegExp
  features, RegExpBuiltinExec).** A match by an instance of a RegExp subclass
  still updates `RegExp.$1`, `RegExp.lastMatch` and the other statics instead
  of invalidating them so that later reads throw a TypeError.
- **Annex B block functions in direct eval inside `catch` (B.3.4).** Inside
  `catch (e)`, `eval("{ function e(){} }")` assigns the function to the catch
  parameter instead of the function's var binding, which stays undefined. A
  top-level `eval("function e(){}")` binds correctly; only the Annex B block
  copy is affected.
- **`arguments` declared by sloppy direct eval (EvalDeclarationInstantiation,
  §19.2.1.3).** `eval('var arguments = 3')`, `eval('function arguments() {}')`
  and `eval('{ function arguments() {} }')` inside a function create a
  separate eval variable instead of reusing the function's `arguments`
  binding, so the function body still sees the arguments object (plain
  assignment `eval('arguments = 3')` works). Inherited from QuickJS; no test262
  case in the profile covers it.
- **Global `let` shadowing an existing global property (GetBindingValue,
  §9.1.1.4.6).** Code that resolved a name to a global object property
  before a later script-level `let`/`const`/`class` of the same name was
  instantiated (a closure from an earlier script, or eval / `new Function`
  code while the global object already has the property) keeps reading the
  property during the lexical binding's TDZ instead of throwing a
  ReferenceError. Inherited from QuickJS.
- **Generic Array methods on typed arrays (LengthOfArrayLike, §7.3.19).**
  `Array.prototype` methods called on a typed array use its intrinsic length
  (0 when detached or out of bounds) instead of `Get(O, "length")`, so an own
  `length` property or a replaced prototype does not change how many elements
  they visit.

## Production v1

The release target is spec-correct trusted-code embedding within the declared
profile and public API. Use the [release checklist](docs/release-checklist.md)
for release evidence and [verification policy](docs/verification-policy.md)
for gate obligations. A failed semantic sub-gate blocks release.
