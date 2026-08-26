// PERF-T-SPIKE primary workload: property-dense own-slot access
// (box2d/pdfjs access shape). Fixed work, deterministic checksum.
// Policy: policies/spikes/perf-t-spike-v1.json — primary metric is the
// paired fixed-work time ratio on THIS file, own-slot form.
// Wrapped in a function: (a) isolates property-access measurement from
// global-var opcodes; (b) avoids the pre-existing top-level GC segfault
// (reports/defects/2026-08-26-toplevel-ctor-gc-segv.md on main).
function tspikeMain() {
  function Body(x, y, vx, vy, mass) {
    this.x = x;
    this.y = y;
    this.vx = vx;
    this.vy = vy;
    this.mass = mass;
  }

  var bodies = [];
  for (var i = 0; i < 64; i++) {
    bodies.push(new Body(i * 0.5, 10 + (i % 9), 0.1 + (i % 5) * 0.01, -0.2, 1 + (i % 7)));
  }

  function step(dt) {
    var e = 0;
    for (var i = 0; i < bodies.length; i++) {
      var b = bodies[i];
      b.vy = b.vy - 9.8 * dt;
      b.x = b.x + b.vx * dt;
      b.y = b.y + b.vy * dt;
      if (b.y < 0) {
        b.y = -b.y;
        b.vy = -b.vy * 0.9;
      }
      e += b.mass * (b.vx * b.vx + b.vy * b.vy);
    }
    return e;
  }

  var acc = 0;
  for (var s = 0; s < 120000; s++) acc += step(0.016);
  print("tspike-own checksum " + acc.toFixed(3));
}
tspikeMain();
