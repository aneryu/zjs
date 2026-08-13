/*
 * Positive control for CALL-BOUNDARY-DIAGNOSIS counter-only builds.
 * It deliberately exercises direct JS -> JS calls, JS -> native calls, and
 * a native Array.prototype.map callback back into bytecode.  Counts are used
 * only to prove detector reachability; this file is never a timing workload.
 */
function leaf(value) {
  return value + 1;
}

var sum = 0;
for (var i = 0; i < 10000; i++) {
  sum = leaf(sum);
  sum += Math.abs(-1);
}

var values = [];
for (var j = 0; j < 1000; j++) values[j] = j;
var mapped = values.map(function callback(value) {
  return leaf(value);
});

print("CALL_BOUNDARY_POSITIVE", sum, mapped.length, mapped[999]);
