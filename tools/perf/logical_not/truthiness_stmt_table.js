// P7-61 correctness boundary, statement contexts. Companion to
// `truthiness_table.js` (which covers `!x` / `!!x` as expressions): the same 33
// shapes, now driven through the three statement forms that also emit OP_lnot —
// `if (!x)`, `while (!x)` and `for (; !x; )`. Neither engine folds negation in
// branch context (P7-60 §2.1), so each of these really does execute the opcode.
//
// Printed as a stable table so zjs (default), zjs -Dzjs_nan_boxing=true and the
// pinned qjs can be diffed byte for byte.
const trap = { valueOf() { throw new Error("valueOf ran"); },
               toString() { throw new Error("toString ran"); } };
const heapBig = 123456789012345678901234567890n;
const rope = "x".repeat(70000) + "y".repeat(70000);
const emptyRope = "".concat("");
const cases = [
  ["undefined", undefined], ["null", null],
  ["false", false], ["true", true],
  ["int 0", 0], ["int 1", 1], ["int -1", -1],
  ["float +0", 0.0], ["float -0", -0.0], ["float NaN", NaN],
  ["float 1.5", 1.5], ["float Infinity", Infinity],
  ["short bigint 0n", 0n], ["short bigint 7n", 7n], ["short bigint -7n", -7n],
  ["heap bigint", heapBig], ["heap bigint neg", -heapBig],
  ["string empty", ""], ["string 'a'", "a"], ["string '0'", "0"],
  ["string rope", rope], ["string emptyRope", emptyRope],
  ["object {}", {}], ["object []", []], ["object new Number(0)", new Number(0)],
  ["object new Boolean(false)", new Boolean(false)],
  ["object trap valueOf", trap],
  ["function", function () {}], ["arrow", () => {}],
  ["symbol", Symbol("s")],
  ["Date(0)", new Date(0)], ["RegExp", /a/],
  ["Proxy of {}", new Proxy({}, {})],
];

// `if (!x)`: one OP_lnot, result consumed by the branch.
function viaIf(v) {
  if (!v) return "then";
  return "else";
}

// `while (!v)`: the operand is re-read every iteration, so the loop both
// executes OP_lnot and proves the result is stable (a falsy value would spin).
function viaWhile(v) {
  let guard = 0;
  let entered = 0;
  while (!v) {
    entered = entered + 1;
    if (++guard >= 3) break;
  }
  return entered;
}

// `for (; !v; )`: same condition position, different statement.
function viaFor(v) {
  let guard = 0;
  let entered = 0;
  for (; !v; ) {
    entered = entered + 1;
    if (++guard >= 3) break;
  }
  return entered;
}

for (const [name, v] of cases) {
  print(name +
        " => if=" + viaIf(v) +
        " while=" + viaWhile(v) +
        " for=" + viaFor(v) +
        " not=" + (!v) +
        " notnot=" + (!!v));
}
