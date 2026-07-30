// P7-60 correctness boundary: `!x` must never run valueOf/toString, and its
// result must match for every value representation. Printed as a stable table so
// the two engines can be diffed byte for byte.
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
for (const [name, v] of cases) {
  print(name + " => !x=" + (!v) + " !!x=" + (!!v) + " typeof=" + typeof v);
}
