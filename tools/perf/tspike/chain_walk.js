// PERF-T-SPIKE re-test workload A: dependent property chain.
//
// The first round's own_slot.js was a physics loop whose serial float
// dependency chain hid the property access completely (controlled demo:
// probe and slot forms cost the SAME cycles once a ~13-cycle FP chain runs
// alongside). This workload puts property access ON the critical path: each
// load決定 the next load's address, so nothing can be overlapped. That is the
// pointer-chasing shape of pdfjs/typescript object-graph code, which is what
// the policy's "property-dense" case was meant to model.
function tspikeMain() {
  function Node(id) {
    this.id = id;
    this.a = 0;
    this.b = 0;
    this.next = null;
  }

  var n = 512;
  var nodes = [];
  for (var i = 0; i < n; i++) nodes.push(new Node(i));
  for (var i = 0; i < n; i++) {
    nodes[i].next = nodes[(i * 37 + 11) % n];
    nodes[i].a = (i * 3) % n;
    nodes[i].b = (i * 5) % n;
  }

  var acc = 0;
  var cur = nodes[0];
  for (var s = 0; s < 3000000; s++) {
    // Every read feeds the next: pure dependent chain, no ILP to hide it.
    cur = cur.next;
    acc = (acc + cur.a) | 0;
    cur = cur.next;
    acc = (acc + cur.b) | 0;
  }
  print("tspike-chain checksum " + acc + " " + cur.id);
}
tspikeMain();
