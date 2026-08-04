// FINAL SWITCH -- L3 emission workload (JavaScript).
//
// This file exists to be COMPILED, and it must actually run so the collector
// sees a non-zero v2_construct_emitted. Gate A's first L3 attempt pointed the
// collector at `--print-config-signature`, which compiles nothing and reported
// `v2_construct_emitted=0 legacy_in_v2_unallowed=0` -- a vacuous zero that
// reads exactly like a pass. Keep this file broad and keep it executing.
//
// Breadth matters more than depth here: the gate asks "did any production
// construct fall back to legacy emission", so every construct family that
// ships should appear at least once.

// --- declarations, scopes, control flow ------------------------------------
let counter = 0;
const limit = 8;
var legacyVar = 1;

for (let i = 0; i < limit; i++) {
  counter += i;
}
for (const key in { a: 1, b: 2 }) counter += key.length;
for (const value of [1, 2, 3]) counter += value;

let guard = 0;
while (guard < 3) guard++;
do { guard--; } while (guard > 0);

outer: for (let i = 0; i < 3; i++) {
  inner: while (true) { continue outer; }
}

switch (counter % 3) {
  case 0: legacyVar = 10; break;
  case 1: legacyVar = 11; break;
  default: legacyVar = 12;
}

try { throw new Error("probe"); }
catch (error) { legacyVar += error.message.length; }
finally { legacyVar += 1; }

// --- functions in every shape ----------------------------------------------
function declared(a, b = 2, ...rest) { return a + b + rest.length; }
const expr = function named(v) { return v; };
const arrow = (v) => v + 1;
function* gen() { yield 1; yield* [2, 3]; }
async function task() { return await Promise.resolve(1); }
async function* stream() { yield await Promise.resolve(1); }

// --- classes ---------------------------------------------------------------
const computedKey = "computed";
class Base {
  method() { return 1; }
  static staticMethod() { return 2; }
}
class Derived extends Base {
  #field = 1;
  static #staticField = 2;
  [computedKey] = 3;
  constructor() { super(); }
  #privateMethod() { return this.#field; }
  static #privateStatic() { return Derived.#staticField; }
  get item() { return this.#privateMethod(); }
  set item(v) { this.#field = v; }
  static { this.ready = true; }
}

// --- destructuring, spread, literals ---------------------------------------
const [first = 1, , ...tail] = [undefined, 2, 3];
const source = { a: { b: 4 }, c: 5, d: 6 };
const { a: { b = 1 } = {}, c: renamed = 2, ...others } = source;
const spreadArray = [0, ...tail];
const spreadObject = { base: 1, ...others };
const objectLiteral = {
  __proto__: null,
  first,
  method(v) { return v; },
  get value() { return 1; },
  set value(v) { this.saved = v; },
  [computedKey]: 2,
};

// --- expressions -----------------------------------------------------------
const name = "world";
const template = `hello ${name} ${1 + 1}`;
function tag(strings, value) { return strings[0] + value; }
const tagged = tag`value ${1}`;
const optional = objectLiteral?.value;
const optionalIndex = objectLiteral?.[computedKey];
const optionalCall = objectLiteral.method?.(1);
let nullish = null;
nullish ??= 2;
let anded = 1; anded &&= 3;
let ored = 0; ored ||= 4;
const typed = typeof nullish;
const voided = void 0;
const deleted = delete spreadObject.base;
const pattern = /a+b?/gi;
const big = 12345678901234567890n;
function factory() { return new.target; }

// --- explicit resource management ------------------------------------------
function disposes() {
  using resource = { [Symbol.dispose]() { counter += 1; } };
  return resource;
}

// --- keep everything live so nothing is dead-stripped ----------------------
const total =
  counter + legacyVar + limit + first + b + renamed +
  spreadArray.length + Object.keys(spreadObject).length +
  template.length + tagged.length +
  declared(1) + expr(1) + arrow(1) +
  [...gen()].length +
  new Derived().method() + Base.staticMethod() + Number(Derived.ready) +
  (optional ?? 0) + (optionalIndex ?? 0) + (optionalCall ?? 0) +
  nullish + anded + ored + typed.length + Number(voided === undefined) +
  Number(deleted) + Number(pattern.test("aab")) + Number(big > 0n) +
  Number(factory() === undefined) + Number(disposes() !== null);

if (!(total > 0)) throw new Error("l3 workload did not execute");
task();
stream();
