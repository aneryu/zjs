// PERF-T-SPIKE secondary workload: method-read-dense proto-slot access
// (richards/deltablue access shape): the hot loads are method reads that
// walk the prototype chain. Fixed work, deterministic checksum.
// Wrapped in a function: (a) isolates property-access measurement from
// global-var opcodes; (b) avoids the pre-existing top-level GC segfault
// (reports/defects/2026-08-26-toplevel-ctor-gc-segv.md on main).
function tspikeMain() {
  function Task(id, pri) {
    this.id = id;
    this.pri = pri;
    this.work = 0;
  }
  Task.prototype.run = function () {
    this.work = (this.work + 1) | 0;
    return this.pri;
  };
  Task.prototype.priority = function () {
    return this.pri + (this.work & 3);
  };
  Task.prototype.idle = function () {
    return (this.id & 1) === 0;
  };

  var tasks = [];
  for (var i = 0; i < 48; i++) tasks.push(new Task(i, i % 11));

  var acc = 0;
  for (var s = 0; s < 300000; s++) {
    for (var i = 0; i < tasks.length; i++) {
      var t = tasks[i];
      acc += t.run();
      acc += t.priority();
      if (t.idle()) acc = (acc + 1) | 0;
    }
    acc = acc | 0;
  }
  print("tspike-proto checksum " + acc);
}
tspikeMain();
