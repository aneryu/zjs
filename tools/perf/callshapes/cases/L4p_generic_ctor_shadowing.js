// L4p: L4 plus same-named prototype data properties -- RayTrace's exact
// Vector/Color layout. L4p - L4 is the cost of a store that shadows an
// inherited writable data property, measured with both halves on the generic
// constructor route.
var N = 5000000;
function main(n) {
    function Three(a, b, c) { var t = a; this.x = t; this.y = b; this.z = c; }
    Three.prototype = { x: 0.0, y: 0.0, z: 0.0 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Three(1, 2, 3);
        s += p.x;
    }
    return s;
}
print(main(N));
