// PERF-T-SPIKE untyped control: dynamic-shape objects (field add/delete),
// string building, and arithmetic — nothing here is specializable, so the
// spike build must run this within the 1.005 geomean cap of the baseline
// build (policy maximum_regression, ratified 2026-08-26).
// Wrapped in a function: (a) isolates property-access measurement from
// global-var opcodes; (b) avoids the pre-existing top-level GC segfault
// (reports/defects/2026-08-26-toplevel-ctor-gc-segv.md on main).
function tspikeMain() {
  var acc = 0;
  var key = "k";
  for (var s = 0; s < 60000; s++) {
    var o = { a: s };
    o[key + (s & 3)] = s * 2;
    o.b = s + 1;
    if ((s & 7) === 0) delete o.a;
    var t = 0;
    for (var k in o) t += o[k];
    acc += t & 1023;
    var str = "v" + (s & 255);
    if (str.length === 2) acc += 1;
    acc = acc | 0;
  }
  print("tspike-untyped checksum " + acc);
}
tspikeMain();
