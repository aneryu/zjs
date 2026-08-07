// Isolate PURE SHIFT cost. Both variants do the SAME number of splice calls with
// the SAME (del=0, ins=1) shape, so allocation/representation paths match.
// Only difference: WHERE. head-insert shifts the whole array, tail-insert shifts nothing.
// difference / total-shifted-elements = per-shifted-element cost.
var MODE = scriptArgs[1];
var L0 = 1000, ITERS = 2000;
var a = [];
for (var i = 0; i < L0; i++) a.push(i);
if (MODE === "head") { for (var k = 0; k < ITERS; k++) a.splice(0, 0, k); }
else                 { for (var k = 0; k < ITERS; k++) a.splice(a.length, 0, k); }
print(MODE + " len=" + a.length + " head=" + a[0] + " tail=" + a[a.length-1]);
