// L3p: like L3, but the prototype already carries same-named data properties,
// which is exactly RayTrace's Vector/Color layout (`Vector.prototype = {x:0,
// y:0, z:0}` while `initialize` assigns this.x/this.y/this.z). Each store must
// therefore resolve an inherited writable data property before creating the
// own one. L3p - L3 isolates that shadowing cost.
var N = 5000000;
function main(n) {
    function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
    Three.prototype = { x: 0.0, y: 0.0, z: 0.0 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Three(1, 2, 3);
        s += p.x;
    }
    return s;
}
print(main(N));
