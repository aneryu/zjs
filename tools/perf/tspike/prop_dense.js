// PERF-T-SPIKE re-test workload B: property-dominated, integer-only.
//
// Same intent as own_slot.js (many own-slot reads per iteration) but with the
// float math removed: integer accumulation only, so the loop's ILP budget is
// not spent on a serial FP chain that hides the access. Reads outnumber
// writes ~4:1, matching the access mix the policy's kill row is about.
function tspikeMain() {
  function Rec(i) {
    this.f0 = i;
    this.f1 = i + 1;
    this.f2 = i + 2;
    this.f3 = i + 3;
    this.f4 = i + 4;
    this.f5 = i + 5;
    this.f6 = i + 6;
    this.f7 = i + 7;
  }

  var recs = [];
  for (var i = 0; i < 64; i++) recs.push(new Rec(i));

  var acc = 0;
  for (var s = 0; s < 400000; s++) {
    for (var i = 0; i < recs.length; i++) {
      var r = recs[i];
      acc = (acc + r.f0 + r.f3 + r.f5 + r.f7) | 0;
      acc = (acc + r.f1 + r.f2 + r.f4 + r.f6) | 0;
    }
  }
  print("tspike-dense checksum " + acc);
}
tspikeMain();
