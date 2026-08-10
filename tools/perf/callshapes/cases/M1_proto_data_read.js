// M1: data property read that resolves on the prototype, not on the receiver.
// RayTrace reads `info.isHit` / `info.distance` on objects whose initialize
// never assigned them, so the read walks to the prototype every time.
var N = 40000000;
function main(n) {
    function Holder() { this.own = 1; }
    Holder.prototype.inherited = 7;
    var o = new Holder();
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += o.inherited;
    }
    return s;
}
print(main(N));
