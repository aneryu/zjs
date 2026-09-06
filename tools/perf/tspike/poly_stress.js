// PERF-T-SPIKE polymorphic stress arm (mandatory per ledger §20.2a②):
// one hot site sees two subclass shapes ALTERNATING — a consecutive-fail
// invalidation heuristic never fires here; sliding-window must. The win on
// own_slot.js must not collapse into a loss on this file.
// Wrapped in a function: (a) isolates property-access measurement from
// global-var opcodes; (b) avoids the pre-existing top-level GC segfault
// (reports/defects/2026-08-26-toplevel-ctor-gc-segv.md on main).
function tspikeMain() {
  function A(v) {
    this.v = v;
  }
  A.prototype.get = function () {
    return this.v;
  };
  function B(v) {
    this.v = v;
    this.w = 2;
  }
  B.prototype.get = function () {
    return this.v + this.w;
  };

  var xs = [];
  for (var i = 0; i < 64; i++) xs.push((i & 1) === 0 ? new A(i) : new B(i));

  var acc = 0;
  for (var s = 0; s < 200000; s++) {
    for (var i = 0; i < xs.length; i++) {
      var o = xs[i];
      acc += o.get();
      acc += o.v;
      acc = acc | 0;
    }
  }
  print("tspike-poly checksum " + acc);
}
tspikeMain();
